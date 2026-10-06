'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const YAML = require('yaml');

const ROOT = path.resolve(__dirname, '..', '..');
const WORKFLOWS = path.join(ROOT, '.github', 'workflows');
const RELEASE = YAML.parse(fs.readFileSync(path.join(WORKFLOWS, 'release.yml'), 'utf8'));
const EXPRESSION = /\$\{\{([\s\S]*?)\}\}/g;
const CONTEXT_REFERENCE = /(?<![\w.-])(inputs|env|github|needs)(?![\w-])(?:\s*\.\s*([A-Za-z_][\w-]*))?/gi;
const TRUSTED_GITHUB_MEMBERS = new Set(['sha', 'event_name', 'repository', 'server_url']);
const INPUT_VARIABLES = {
  SKIP_REASON: '${{ inputs.skip_reason }}',
  SKIP_TEST_GATE: '${{ inputs.skip_test_gate }}',
  VERSION_TYPE: '${{ inputs.version_type }}',
};
const VALIDATE = 'Validate test-gate skip request';
const PUBLISH_GATE = 'Deterministic exact-main-SHA gate';
const PUBLISH_PLAN_GATE = 'Decide the exact-main-SHA gate';
const PUBLISH_DECISION = 'COMMIT_MSG="$(git log -1 --format=%B HEAD)"';
const PREPARE_EVIDENCE = 'if [ "$SKIP_TEST_GATE" = "true" ] && [ "$SUITE_RESULT" = skipped ] && [ -n "${SKIP_REASON//[[:space:]]/}" ]; then';
const PUBLISH_EVIDENCE = 'if [ "$GATE_DECISION" = skipped ] && [ "$SUITE_RESULT" = skipped ] && [ -n "${GATE_REASON//[[:space:]]/}" ]; then';
const RELEASE_SUBJECT = 'chore(release): bump version to 9.9.9';
const EXPECTED_SHA = 'f'.repeat(40);
const HOSTILE = 'it\'s "quoted" `touch backtick-ran` $(touch dollar-ran) ${HOME} $HOME;  exit 7\t* \\ 100%';
const MARKERS = ['backtick-ran', 'dollar-ran'];

function workflowSteps(document) {
  return Object.entries(document.jobs || {}).flatMap(([job, body]) =>
    (body.steps || []).map((step) => ({ job, step })));
}

function dispatcherControlled(expression) {
  return [...expression.matchAll(CONTEXT_REFERENCE)].some(([, context, member]) =>
    context.toLowerCase() !== 'github' || !(member && TRUSTED_GITHUB_MEMBERS.has(member.toLowerCase())));
}

function untrustedExpansions(document) {
  const found = [];
  for (const { job, step } of workflowSteps(document)) {
    for (const [match, expression] of String(step.run ?? '').matchAll(EXPRESSION)) {
      if (dispatcherControlled(expression)) found.push({ job, step: step.name ?? step.uses, match });
    }
  }
  return found;
}

function stepIndex(job, name) {
  return (RELEASE.jobs?.[job]?.steps || []).findIndex((step) => step.name === name);
}

function stepNamed(job, name) {
  const matches = (RELEASE.jobs?.[job]?.steps || []).filter((step) => step.name === name);
  assert.strictEqual(matches.length, 1, `${job} carries exactly one "${name}" step`);
  return matches[0];
}

function render(template, context) {
  return String(template).replace(EXPRESSION, (match, expression) => {
    const key = expression.trim();
    assert.ok(Object.hasOwn(context, key), `the test supplies no value for ${match}`);
    return String(context[key]);
  });
}

function hermeticEnv(extra = {}) {
  const env = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (name.startsWith('GIT_') || name.startsWith('GITHUB_') || Object.hasOwn(INPUT_VARIABLES, name)) continue;
    env[name] = value;
  }
  return { ...env, ...extra };
}

function withDir(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dispatch-inputs-'));
  try {
    return fn(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function runStep(step, context, cwd, extra = {}) {
  return withDir((dir) => {
    const script = path.join(dir, 'step.sh');
    fs.writeFileSync(script, render(step.run, context));
    const stepEnv = Object.fromEntries(
      Object.entries(step.env || {}).map(([name, value]) => [name, render(value, context)]),
    );
    return spawnSync('bash', ['-e', script], {
      cwd,
      env: hermeticEnv({ ...stepEnv, ...extra }),
      encoding: 'utf8',
    });
  });
}

function cut(run, opening) {
  const lines = run.split('\n');
  const start = lines.findIndex((line) => line.startsWith(opening));
  const end = lines.findIndex((line, index) => index > start && line === 'fi');
  assert.ok(start !== -1 && end !== -1, `the block opening with ${opening} is found`);
  return lines.slice(start, end + 1);
}

function decide(step, opening, context, cwd, extra = {}) {
  return runStep({
    env: step.env,
    run: ['set -euo pipefail', ...cut(step.run, opening), 'printf \'%s\\n%s\' "$GATE" "$GATE_REASON"'].join('\n'),
  }, context, cwd, extra);
}

function outcome(result) {
  const lines = result.stdout.split('\n');
  return { gate: lines.at(-2), reason: lines.at(-1), annotations: lines.slice(0, -2) };
}

function git(cwd, ...args) {
  const result = spawnSync('git', args, { cwd, env: hermeticEnv(), encoding: 'utf8' });
  assert.strictEqual(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
  return result.stdout;
}

function repository(base) {
  const repo = path.join(base, 'repo');
  fs.mkdirSync(repo);
  git(repo, 'init', '-q');
  for (const [key, value] of [
    ['user.email', 't@example.invalid'],
    ['user.name', 'tester'],
    ['commit.gpgsign', 'false'],
    ['tag.gpgsign', 'false'],
    ['core.autocrlf', 'false'],
    ['core.hooksPath', path.join(base, 'no-hooks')],
  ]) {
    git(repo, 'config', key, value);
  }
  return repo;
}

function committed(base, ...paragraphs) {
  const repo = repository(base);
  git(repo, 'commit', '-q', '--allow-empty', ...paragraphs.flatMap((paragraph) => ['-m', paragraph]));
  return repo;
}

function publishDecision(repo, context) {
  return decide(stepNamed('publish-plan', PUBLISH_PLAN_GATE), PUBLISH_DECISION, context, repo);
}

function publishEvidence(cwd, gate, reason, suiteResult) {
  return decide(stepNamed('publish', PUBLISH_GATE), PUBLISH_EVIDENCE, {
    'needs.publish-plan.outputs.gate': gate,
    'needs.publish-plan.outputs.gate_reason': reason,
    'needs.publish-suite.result': suiteResult,
    'github.sha': EXPECTED_SHA,
  }, cwd);
}

function releaseCandidate(base) {
  const repo = repository(base);
  const output = path.join(base, 'github-output');
  const files = ['.claude-plugin/plugin.json', '.claude-plugin/marketplace.json', 'README.md', 'CHANGELOG.md'];
  fs.mkdirSync(path.join(repo, '.claude-plugin'));
  for (const file of files) fs.writeFileSync(path.join(repo, file), 'before\n');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'initial');
  for (const file of files) fs.writeFileSync(path.join(repo, file), 'after\n');
  fs.writeFileSync(output, '');
  return { repo, output };
}

function createReleaseCommit({ repo, output }, skipTestGate, skipReason) {
  return runStep(stepNamed('prepare-commit', 'Create release commit'), {
    'inputs.skip_test_gate': skipTestGate,
    'inputs.skip_reason': skipReason,
    'steps.ver.outputs.version': '9.9.9',
    'steps.ver.outputs.tag': 'v9.9.9',
  }, repo, { GITHUB_OUTPUT: output });
}

function evidenceDecision(cwd, skipTestGate, skipReason, suiteResult) {
  return decide(
    stepNamed('prepare', 'Record deterministic exact-commit runtime evidence'),
    PREPARE_EVIDENCE,
    {
      'inputs.skip_test_gate': skipTestGate,
      'inputs.skip_reason': skipReason,
      'needs.prepare-suite.result': suiteResult,
    },
    cwd,
    { EXPECTED_SHA },
  );
}

function executed(cwd) {
  return MARKERS.filter((marker) => fs.existsSync(path.join(cwd, marker)));
}

function validate(reason) {
  return withDir((cwd) => {
    const result = runStep(stepNamed('prepare-commit', VALIDATE), { 'inputs.skip_reason': reason }, cwd);
    return { ...result, executed: executed(cwd) };
  });
}

test('no workflow run block expands a dispatcher-controlled expression', () => {
  const files = fs.readdirSync(WORKFLOWS).filter((name) => /\.ya?ml$/.test(name)).sort();
  assert.ok(files.includes('release.yml'));
  const offenders = files.flatMap((file) =>
    untrustedExpansions(YAML.parse(fs.readFileSync(path.join(WORKFLOWS, file), 'utf8')))
      .map(({ job, step, match }) => `${file} ${job} "${step}": ${match}`));
  const releaseExpansions = workflowSteps(RELEASE)
    .flatMap(({ step }) => [...String(step.run ?? '').matchAll(EXPRESSION)]).length;
  assert.ok(releaseExpansions > 0, 'the scan reaches the expressions release.yml does expand');
  assert.deepStrictEqual(offenders, []);
});

test('the run-block scan flags every dispatcher-controlled expression family and no trusted one', () => {
  const flagged = [
    '${{ inputs.skip_reason }}',
    "${{ inputs['skip_reason'] }}",
    '${{ github.event.inputs.skip_reason }}',
    '${{ github.event.head_commit.message }}',
    '${{ toJSON(inputs) }}',
    '${{ env.SKIP_REASON }}',
    "${{ env['SKIP_REASON'] }}",
    '${{ toJson(env) }}',
    '${{ github.ref }}',
    '${{ github.ref_name }}',
    '${{ github.head_ref }}',
    '${{ github.base_ref }}',
    '${{ github.workflow_ref }}',
    "${{ github['ref'] }}",
    "${{ github['head_ref'] }}",
    "${{ github['event']['head_commit']['message'] }}",
    "${{ github['sha'] }}",
    '${{ toJSON(github) }}',
    '${{ INPUTS.skip_reason }}',
    '${{ GitHub.head_ref }}',
    '${{ github.repository_owner }}',
    '${{ github.sha || github.head_ref }}',
    '${{ needs.publish-plan.outputs.gate_reason }}',
    "${{ needs['publish-plan'].outputs.gate }}",
    '${{ needs.prepare-suite.result }}',
    '${{ toJSON(needs) }}',
    '${{ NEEDS.prepare-commit.outputs.sha }}',
  ];
  const trusted = [
    '${{ github.sha }}',
    '${{ github.event_name }}',
    '${{ github.repository }}',
    '${{ github.server_url }}',
    '${{ GITHUB.SHA }}',
    '${{ steps.github.outputs.sha }}',
    '${{ steps.env.outputs.value }}',
    '${{ steps.needs.outputs.value }}',
    '${{ steps.build-github.outputs.inputs }}',
    '${{ steps.build-needs.outputs.sha }}',
    "${{ github.event_name == 'workflow_dispatch' }}",
    '${{ steps.ver.outputs.version }}',
    '${{ runner.temp }}',
    '${{ matrix.shard }}',
  ];
  const document = {
    jobs: {
      synthetic: {
        steps: [
          { name: 'mixed', run: [...flagged, ...trusted].map((expression) => `echo "${expression}"`).join('\n') },
          { name: 'mapped', env: { SKIP_REASON: '${{ inputs.skip_reason }}' }, run: 'echo "$SKIP_REASON"' },
        ],
      },
    },
  };
  assert.deepStrictEqual(untrustedExpansions(document).map(({ match }) => match), flagged);
});

test('every release step that reads a dispatch input variable maps it from that input', () => {
  const readers = Object.fromEntries(Object.keys(INPUT_VARIABLES).map((name) => [name, []]));
  for (const { job, step } of workflowSteps(RELEASE)) {
    for (const [name, source] of Object.entries(INPUT_VARIABLES)) {
      if (!new RegExp(`\\$\\{?${name}\\b`).test(String(step.run ?? ''))) continue;
      assert.strictEqual(step.env?.[name], source, `${job} "${step.name}" maps ${name} from ${source}`);
      readers[name].push(`${job}/${step.name}`);
    }
  }
  assert.deepStrictEqual(readers, {
    SKIP_REASON: [
      'prepare-commit/Validate test-gate skip request',
      'prepare-commit/Create release commit',
      'prepare/Record deterministic exact-commit runtime evidence',
      'publish-plan/Validate test-gate skip request',
      'publish-plan/Decide the exact-main-SHA gate',
    ],
    SKIP_TEST_GATE: [
      'prepare-commit/Create release commit',
      'prepare/Record deterministic exact-commit runtime evidence',
      'publish-plan/Decide the exact-main-SHA gate',
    ],
    VERSION_TYPE: ['prepare-commit/Compute next version'],
  });
});

test('prepare and publish validate a skip request identically before consuming the reason', () => {
  const prepare = stepNamed('prepare-commit', VALIDATE);
  assert.deepStrictEqual(stepNamed('publish-plan', VALIDATE), prepare);
  assert.strictEqual(prepare.if, '${{ inputs.skip_test_gate }}');
  assert.ok(stepIndex('prepare-commit', VALIDATE) < stepIndex('prepare-commit', 'Create release commit'));
  assert.ok(stepIndex('publish-plan', VALIDATE) < stepIndex('publish-plan', PUBLISH_PLAN_GATE));
});

test('a hostile single-line skip reason is accepted verbatim and never executed', () => {
  const result = validate(HOSTILE);
  assert.strictEqual(result.status, 0, result.stdout + result.stderr);
  assert.deepStrictEqual(result.executed, []);
  assert.ok(
    result.stdout.split('\n').includes(`::warning::Test gate will be SKIPPED for this release. Reason: ${HOSTILE}`),
    result.stdout,
  );
});

test('an empty or whitespace-only skip reason is refused', () => {
  for (const reason of ['', ' \t ']) {
    const result = validate(reason);
    assert.strictEqual(result.status, 1, JSON.stringify(reason));
    assert.match(result.stdout, /^::error::skip_test_gate requires a non-empty skip_reason$/m);
    assert.doesNotMatch(result.stdout, /::warning::/);
  }
});

test('a skip reason that spans more than one line is refused without being executed', () => {
  for (const reason of [
    'first line\nsecond line',
    'first line\rsecond line',
    'one line\n',
    '$(touch dollar-ran)\n`touch backtick-ran`',
  ]) {
    const result = validate(reason);
    assert.strictEqual(result.status, 1, JSON.stringify(reason));
    assert.match(result.stdout, /^::error::skip_reason must be a single line$/m);
    assert.doesNotMatch(result.stdout, /::warning::/);
    assert.deepStrictEqual(result.executed, []);
  }
});

test('a skip reason that starts or ends with whitespace is refused', () => {
  for (const reason of ['  padded', 'padded  ', '\tpadded', 'padded\t']) {
    const result = validate(reason);
    assert.strictEqual(result.status, 1, JSON.stringify(reason));
    assert.match(result.stdout, /^::error::skip_reason must not start or end with whitespace$/m);
    assert.doesNotMatch(result.stdout, /::warning::/);
  }
});

test('an ordinary release commit carries no skip trailer and the push-triggered publish gate runs the suite', () => {
  withDir((base) => {
    const candidate = releaseCandidate(base);
    const commit = createReleaseCommit(candidate, 'false', '');
    assert.strictEqual(commit.status, 0, commit.stdout + commit.stderr);
    assert.strictEqual(git(candidate.repo, 'log', '-1', '--format=%B').trim(), RELEASE_SUBJECT);

    const decision = publishDecision(candidate.repo, {
      'github.event_name': 'push',
      'inputs.skip_test_gate': '',
      'inputs.skip_reason': '',
    });
    assert.strictEqual(decision.status, 0, decision.stdout + decision.stderr);
    assert.deepStrictEqual(outcome(decision), { gate: 'passed', reason: '', annotations: [] });
  });
});

test('a push-triggered publish runs the gate unless the skip trailer reads skipped', () => {
  for (const paragraphs of [['Release-Test-Gate-Reason: stray reason'], ['Release-Test-Gate: passed', 'Release-Test-Gate-Reason: stray reason']]) {
    withDir((base) => {
      const repo = committed(base, RELEASE_SUBJECT, ...paragraphs);
      const decision = publishDecision(repo, {
        'github.event_name': 'push',
        'inputs.skip_test_gate': '',
        'inputs.skip_reason': '',
      });
      assert.strictEqual(decision.status, 0, JSON.stringify(paragraphs) + decision.stdout + decision.stderr);
      assert.deepStrictEqual(outcome(decision), { gate: 'passed', reason: '', annotations: [] });
    });
  }
});

test('the release commit carries a hostile reason verbatim and the push-triggered publish gate reads it back', () => {
  withDir((base) => {
    const candidate = releaseCandidate(base);
    const { repo } = candidate;
    const commit = createReleaseCommit(candidate, 'true', HOSTILE);
    assert.strictEqual(commit.status, 0, commit.stdout + commit.stderr);
    assert.deepStrictEqual(executed(repo), []);
    const message = git(repo, 'log', '-1', '--format=%B');
    assert.ok(message.split('\n').includes(`Release-Test-Gate-Reason: ${HOSTILE}`), message);

    const decision = publishDecision(repo, {
      'github.event_name': 'push',
      'inputs.skip_test_gate': '',
      'inputs.skip_reason': '',
    });
    assert.strictEqual(decision.status, 0, decision.stdout + decision.stderr);
    assert.deepStrictEqual(outcome(decision), { gate: 'skipped', reason: HOSTILE, annotations: [] });
    assert.deepStrictEqual(executed(repo), []);
  });
});

test('a publish dispatch over a commit without the skip trailer skips with the dispatched reason or runs the gate', () => {
  withDir((base) => {
    const repo = committed(base, RELEASE_SUBJECT);
    const skipped = publishDecision(repo, {
      'github.event_name': 'workflow_dispatch',
      'inputs.skip_test_gate': 'true',
      'inputs.skip_reason': HOSTILE,
    });
    assert.strictEqual(skipped.status, 0, skipped.stdout + skipped.stderr);
    assert.deepStrictEqual(outcome(skipped), { gate: 'skipped', reason: HOSTILE, annotations: [] });
    const gated = publishDecision(repo, {
      'github.event_name': 'workflow_dispatch',
      'inputs.skip_test_gate': 'false',
      'inputs.skip_reason': HOSTILE,
    });
    assert.strictEqual(gated.status, 0, gated.stdout + gated.stderr);
    assert.deepStrictEqual(outcome(gated), { gate: 'passed', reason: '', annotations: [] });
    assert.deepStrictEqual(executed(repo), []);
  });
});

test('a release trailer outranks a different dispatched reason and says so', () => {
  withDir((base) => {
    const repo = committed(base, RELEASE_SUBJECT, 'Release-Test-Gate: skipped', 'Release-Test-Gate-Reason: reviewed reason');
    const decision = publishDecision(repo, {
      'github.event_name': 'workflow_dispatch',
      'inputs.skip_test_gate': 'true',
      'inputs.skip_reason': 'dispatched reason',
    });
    assert.strictEqual(decision.status, 0, decision.stdout + decision.stderr);
    assert.deepStrictEqual(outcome(decision), {
      gate: 'skipped',
      reason: 'reviewed reason',
      annotations: ["::notice::the release commit's Release-Test-Gate-Reason is recorded instead of the dispatched skip_reason"],
    });
    const same = publishDecision(repo, {
      'github.event_name': 'workflow_dispatch',
      'inputs.skip_test_gate': 'true',
      'inputs.skip_reason': 'reviewed reason',
    });
    assert.strictEqual(same.status, 0, same.stdout + same.stderr);
    assert.deepStrictEqual(outcome(same), { gate: 'skipped', reason: 'reviewed reason', annotations: [] });
  });
});

const REASONLESS_TRAILERS = [['Release-Test-Gate: skipped'], ['Release-Test-Gate: skipped', 'Release-Test-Gate-Reason:']];

test('a push-triggered release trailer without a reason is refused', () => {
  for (const paragraphs of REASONLESS_TRAILERS) {
    withDir((base) => {
      const repo = committed(base, RELEASE_SUBJECT, ...paragraphs);
      const decision = publishDecision(repo, {
        'github.event_name': 'push',
        'inputs.skip_test_gate': '',
        'inputs.skip_reason': '',
      });
      assert.strictEqual(decision.status, 1, JSON.stringify(paragraphs) + decision.stdout + decision.stderr);
      assert.match(decision.stdout, /^::error::the release commit skips the test gate without a Release-Test-Gate-Reason$/m);
    });
  }
});

test('a publish dispatch over a release trailer without a reason lets the dispatch decide', () => {
  const notice = "::notice::the release commit's Release-Test-Gate trailer carries no Release-Test-Gate-Reason, so this dispatch decides the gate";
  for (const paragraphs of REASONLESS_TRAILERS) {
    withDir((base) => {
      const repo = committed(base, RELEASE_SUBJECT, ...paragraphs);
      const skipped = publishDecision(repo, {
        'github.event_name': 'workflow_dispatch',
        'inputs.skip_test_gate': 'true',
        'inputs.skip_reason': HOSTILE,
      });
      assert.strictEqual(skipped.status, 0, JSON.stringify(paragraphs) + skipped.stdout + skipped.stderr);
      assert.deepStrictEqual(outcome(skipped), { gate: 'skipped', reason: HOSTILE, annotations: [notice] });
      const gated = publishDecision(repo, {
        'github.event_name': 'workflow_dispatch',
        'inputs.skip_test_gate': 'false',
        'inputs.skip_reason': '',
      });
      assert.strictEqual(gated.status, 0, JSON.stringify(paragraphs) + gated.stdout + gated.stderr);
      assert.deepStrictEqual(outcome(gated), { gate: 'passed', reason: '', annotations: [notice] });
      assert.deepStrictEqual(executed(repo), []);
    });
  }
});

test('the prepare evidence step records a hostile reason verbatim when the gate is skipped', () => {
  withDir((cwd) => {
    const result = evidenceDecision(cwd, 'true', HOSTILE, 'skipped');
    assert.strictEqual(result.status, 0, result.stdout + result.stderr);
    assert.deepStrictEqual(outcome(result), {
      gate: 'skipped',
      reason: HOSTILE,
      annotations: [`::warning::Deterministic release gate SKIPPED — the suite did not run against ${EXPECTED_SHA}. Reason: ${HOSTILE}`],
    });
    assert.deepStrictEqual(executed(cwd), []);
  });
});

test('the prepare evidence step records passed only after every suite shard succeeded', () => {
  withDir((cwd) => {
    const result = evidenceDecision(cwd, 'false', '', 'success');
    assert.strictEqual(result.status, 0, result.stdout + result.stderr);
    assert.deepStrictEqual(outcome(result), { gate: 'passed', reason: '', annotations: [] });
  });
});

test('the prepare evidence step refuses a gate the suite result contradicts', () => {
  for (const [skipTestGate, reason, suiteResult] of [
    ['false', HOSTILE, 'failure'],
    ['false', HOSTILE, 'cancelled'],
    ['false', HOSTILE, 'skipped'],
    ['false', HOSTILE, ''],
    ['true', HOSTILE, 'success'],
    ['true', HOSTILE, 'failure'],
    ['true', '', 'skipped'],
    ['true', ' \t ', 'skipped'],
  ]) {
    withDir((cwd) => {
      const result = evidenceDecision(cwd, skipTestGate, reason, suiteResult);
      assert.strictEqual(result.status, 1, `${skipTestGate}/${suiteResult}: ${result.stdout}${result.stderr}`);
      assert.match(result.stdout, /^::error::the release suite result \(.*\) does not match the gate decision/m);
      assert.doesNotMatch(result.stdout, /::warning::/);
      assert.deepStrictEqual(executed(cwd), []);
    });
  }
});

test('the publish evidence step records passed only after every suite shard succeeded', () => {
  withDir((cwd) => {
    const result = publishEvidence(cwd, 'run', '', 'success');
    assert.strictEqual(result.status, 0, result.stdout + result.stderr);
    assert.deepStrictEqual(outcome(result), { gate: 'passed', reason: '', annotations: [] });
  });
});

test('the publish evidence step records the planned reason verbatim when the gate is skipped', () => {
  withDir((cwd) => {
    const result = publishEvidence(cwd, 'skipped', HOSTILE, 'skipped');
    assert.strictEqual(result.status, 0, result.stdout + result.stderr);
    assert.deepStrictEqual(outcome(result), {
      gate: 'skipped',
      reason: HOSTILE,
      annotations: [`::warning::Deterministic publish gate SKIPPED — the suite did not run against ${EXPECTED_SHA}. Reason: ${HOSTILE}`],
    });
    assert.deepStrictEqual(executed(cwd), []);
  });
});

test('the publish evidence step refuses a gate the suite result contradicts', () => {
  for (const [gate, reason, suiteResult] of [
    ['run', '', 'failure'],
    ['run', '', 'cancelled'],
    ['run', '', 'skipped'],
    ['skipped', HOSTILE, 'success'],
    ['skipped', HOSTILE, 'failure'],
    ['skipped', '', 'skipped'],
    ['skipped', ' \t ', 'skipped'],
    ['passed', '', 'success'],
    ['', '', 'success'],
  ]) {
    withDir((cwd) => {
      const result = publishEvidence(cwd, gate, reason, suiteResult);
      assert.strictEqual(result.status, 1, `${gate}/${suiteResult}: ${result.stdout}${result.stderr}`);
      assert.match(result.stdout, /^::error::the publish suite result \(.*\) does not match the planned gate/m);
      assert.doesNotMatch(result.stdout, /::warning::/);
      assert.deepStrictEqual(executed(cwd), []);
    });
  }
});

test('the publish plan hands the gate and its reason on as one output line each', () => {
  for (const [paragraphs, expected] of [
    [[], 'gate=run\ngate_reason=\n'],
    [['Release-Test-Gate: skipped', `Release-Test-Gate-Reason: ${HOSTILE}`], `gate=skipped\ngate_reason=${HOSTILE}\n`],
  ]) {
    withDir((base) => {
      const repo = committed(base, RELEASE_SUBJECT, ...paragraphs);
      const output = path.join(base, 'github-output');
      fs.writeFileSync(output, '');
      const result = runStep(stepNamed('publish-plan', PUBLISH_PLAN_GATE), {
        'github.sha': git(repo, 'rev-parse', 'HEAD').trim(),
        'github.event_name': 'push',
        'inputs.skip_test_gate': '',
        'inputs.skip_reason': '',
      }, repo, { GITHUB_OUTPUT: output });
      assert.strictEqual(result.status, 0, JSON.stringify(paragraphs) + result.stdout + result.stderr);
      assert.strictEqual(fs.readFileSync(output, 'utf8'), expected);
      assert.deepStrictEqual(executed(repo), []);
    });
  }
});

test('the publish main-only guard compares the runner ref without expanding it', () => {
  const guard = stepNamed('publish-plan', 'Reject a publish dispatch outside main');
  withDir((cwd) => {
    const main = runStep(guard, {}, cwd, { GITHUB_REF: 'refs/heads/main' });
    assert.strictEqual(main.status, 0, main.stdout + main.stderr);
    const hostile = runStep(guard, {}, cwd, { GITHUB_REF: 'refs/heads/x$(touch dollar-ran)`touch backtick-ran`' });
    assert.strictEqual(hostile.status, 1, hostile.stdout + hostile.stderr);
    assert.match(hostile.stdout, /^::error::publish mode may only be dispatched on main$/m);
    assert.deepStrictEqual(executed(cwd), []);
  });
});

test('the version computation still resolves version_type', () => {
  withDir((base) => {
    const repo = repository(base);
    const output = path.join(base, 'github-output');
    git(repo, 'commit', '-q', '--allow-empty', '-m', 'initial');
    git(repo, 'tag', 'v1.9.3');
    git(repo, 'tag', 'v1.10.0');
    for (const [type, version] of [['major', '2.0.0'], ['minor', '1.11.0'], ['patch', '1.10.1']]) {
      fs.writeFileSync(output, '');
      const result = runStep(stepNamed('prepare-commit', 'Compute next version'), {
        'inputs.version_type': type,
      }, repo, { GITHUB_OUTPUT: output });
      assert.strictEqual(result.status, 0, result.stdout + result.stderr);
      assert.strictEqual(fs.readFileSync(output, 'utf8'), `version=${version}\ntag=v${version}\n`);
    }
  });
});
