#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKFLOWS="$ROOT/.github/workflows"
RUNNER="$ROOT/tests/run-all.sh"
PACKAGE="$ROOT/package.json"
MANIFEST="$ROOT/tests/profiles/promptfoo-local-only.v1.json"
LIVE_EVALS="live-evals.yml"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

workflow_matches() {
  local pattern="$1"
  grep -RniE --include='*.yml' --include='*.yaml' --exclude="$LIVE_EVALS" "$pattern" "$WORKFLOWS" 2>/dev/null || true
}

FORBIDDEN='promptfoo|live-evals|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|CODEX_AUTH|OPENAI_API_KEY|GOOGLE_API_KEY|AZURE_OPENAI_API_KEY|session-control:(selfcheck|contract|upgrade|live|concurrency|adversarial|release)|evals/|npm[[:space:]]+(run|exec)|npx|pnpm|yarn'
MATCHES="$(workflow_matches "$FORBIDDEN")"
if [ -z "$MATCHES" ]; then
  check "Every workflow except $LIVE_EVALS stays free of Promptfoo, eval suites, the live-eval scripts and model credentials" PASS
else
  check "Every workflow except $LIVE_EVALS stays free of Promptfoo, eval suites, the live-eval scripts and model credentials" FAIL
  printf '%s\n' "$MATCHES" | sed 's/^/    /'
fi

FINDINGS="$(mktemp)" || exit 2
SHAPE_JS="$(mktemp)" || exit 2
MUTANTS="$(mktemp -d)" || exit 2
trap 'rm -rf "$FINDINGS" "$SHAPE_JS" "$MUTANTS"' EXIT

if node - "$WORKFLOWS" "$LIVE_EVALS" >"$FINDINGS" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [root, live] = process.argv.slice(2);
const bad = [];
for (const name of fs.readdirSync(root).filter((entry) => /\.ya?ml$/.test(entry)).sort()) {
  const text = fs.readFileSync(path.join(root, name), 'utf8');
  if (name === live) {
    for (const line of text.split(/\r?\n/)) {
      if (/\bsecrets\b/.test(line)
        && !/^ {10}(CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY): \$\{\{ secrets\.\1 \}\}$/.test(line)) {
        bad.push(`${name}: ${line.trim()}`);
      }
    }
    continue;
  }
  const rest = text.replace(/\$\{\{\s*secrets\.(?:GITHUB_TOKEN|IMMUTABLE_RELEASES_ADMIN_TOKEN)\s*\}\}/g, '');
  if (/\bsecrets\b/.test(rest)) bad.push(`${name}: a secret other than GITHUB_TOKEN or IMMUTABLE_RELEASES_ADMIN_TOKEN`);
}
process.stdout.write(bad.join('\n'));
process.exit(bad.length ? 1 : 0);
NODE
then
  check "Actions secrets stay with repository and release administration, and $LIVE_EVALS reads only the two Claude credentials as step env" PASS
else
  check "Actions secrets stay with repository and release administration, and $LIVE_EVALS reads only the two Claude credentials as step env" FAIL
  sed 's/^/    /' "$FINDINGS"
  echo
fi

cat > "$SHAPE_JS" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const bad = [];
let text = '';
try {
  text = fs.readFileSync(file, 'utf8');
} catch (error) {
  process.stdout.write(`cannot read the live-eval workflow: ${error.code}`);
  process.exit(1);
}
const lines = text.split(/\r?\n/);
const block = (key) => {
  const start = lines.indexOf(`${key}:`);
  if (start < 0) return null;
  let end = lines.findIndex((line, index) => index > start && /^\S/.test(line));
  if (end < 0) end = lines.length;
  return lines.slice(start + 1, end).filter((line) => line.trim());
};
const on = block('on');
const triggers = on ? on.filter((line) => /^ {2}\S/.test(line)).map((line) => line.trim().replace(/:.*$/, '')) : [];
if (JSON.stringify(triggers) !== JSON.stringify(['schedule', 'workflow_dispatch'])) {
  bad.push(`triggers must be exactly schedule and workflow_dispatch, found: ${triggers.join(', ') || 'none'}`);
}
const permissions = block('permissions');
if (JSON.stringify(permissions) !== JSON.stringify(['  contents: read'])) {
  bad.push('the top-level permissions must be exactly contents: read');
}
if (lines.some((line) => /^\s+permissions:/.test(line))) bad.push('no job or step may widen the permissions');
if (text.includes('tests/run-all.sh')) bad.push('the live-eval workflow must not run tests/run-all.sh');
const installs = text.split('run: bash .github/scripts/live-evals-install-claude-code.sh\n').length - 1;
if (installs !== 1) bad.push(`the newest Claude Code must be installed once by the canary installer, found ${installs}`);
const [header, ...steps] = text.split(/\n(?= {6}- )/);
if (/\bsecrets\b/.test(header)) bad.push('no secret may be declared above the first step');
if (!/\n {4}environment: live-evals\n/.test(header)) bad.push('the job must run in the live-evals environment');
if (!/\n {10}node-version: 22\n/.test(text)) bad.push('Node must be 22, the engine floor of Claude Code');
const dependencyInstalls = text.match(/\bnpm\s+(?:ci|install|i|add)\b[^\n]*/g) || [];
if (dependencyInstalls.length !== 1 || dependencyInstalls[0] !== 'npm ci --ignore-scripts') {
  bad.push('dependencies must be installed once with npm ci --ignore-scripts');
}
for (const step of steps) {
  if (!/\bsecrets\./.test(step)) continue;
  if (!/\n {8}run: bash \.github\/scripts\/live-evals\.sh (?:probe|run|scrub)\n/.test(`${step}\n`) || /\buses:/.test(step)) {
    bad.push(`a step other than the probe, the run or the scrub reads a secret: ${step.trim().split('\n')[0]}`);
  }
}
const scrubAt = steps.findIndex((step) => /\n {8}id: scrub\n/.test(`${step}\n`));
const scrub = scrubAt < 0 ? '' : `${steps[scrubAt]}\n`;
if (!/\n {8}if: always\(\)\n/.test(scrub) || !/\n {8}run: bash \.github\/scripts\/live-evals\.sh scrub\n/.test(scrub)) {
  bad.push('a step with id scrub must always run live-evals.sh scrub');
}
const uploads = steps.flatMap((step, index) => (/\n {8}uses: actions\/upload-artifact@/.test(`${step}\n`) ? [[`${step}\n`, index]] : []));
if (uploads.length !== 1) {
  bad.push(`the results must be uploaded by exactly one step, found ${uploads.length}`);
} else {
  const [upload, uploadAt] = uploads[0];
  if (scrubAt < 0 || uploadAt < scrubAt
    || !upload.includes("\n        if: always() && steps.scrub.outputs.scrubbed == 'true'\n")
    || !upload.includes('\n          path: ${{ runner.temp }}/live-evals-upload/\n')) {
    bad.push('the upload must follow the scrub, run only when it wrote scrubbed=true, and read only the staged upload directory');
  }
}
process.stdout.write(bad.join('\n'));
process.exit(bad.length ? 1 : 0);
NODE

SHAPE_LABEL="$LIVE_EVALS runs on schedule and dispatch only in the live-evals environment, keeps a read-only token, installs its dependencies on Node 22 without their install scripts, installs the newest Claude Code once, gives the credentials only to its probe, run and scrub steps, and uploads only what the scrub staged"
if node "$SHAPE_JS" "$WORKFLOWS/$LIVE_EVALS" >"$FINDINGS"; then
  check "$SHAPE_LABEL" PASS
else
  check "$SHAPE_LABEL" FAIL
  sed 's/^/    /' "$FINDINGS"
  echo
fi

MUTANT_BAD=""
MUTANT_N=0
if node - "$WORKFLOWS/$LIVE_EVALS" "$MUTANTS" >"$FINDINGS" 2>&1 <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [file, dir] = process.argv.slice(2);
const text = fs.readFileSync(file, 'utf8');
const swap = (from, to) => (source) => {
  if (source.split(from).length !== 2) throw new Error(`the mutant anchor is not unique: ${from.trim().split('\n')[0]}`);
  return source.split(from).join(to);
};
const mutants = [
  ['header-secret', 'no secret may be declared above the first step', swap('    timeout-minutes: 150\n', '    timeout-minutes: 150\n    services:\n      cache:\n        image: redis\n        env:\n          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}\n')],
  ['pull-request-trigger', 'triggers must be exactly schedule and workflow_dispatch', swap('  workflow_dispatch:\n', '  pull_request:\n  workflow_dispatch:\n')],
  ['write-token', 'the top-level permissions must be exactly contents: read', swap('permissions:\n  contents: read\n', 'permissions:\n  contents: write\n')],
  ['job-permissions', 'no job or step may widen the permissions', swap('    runs-on: ubuntu-latest\n', '    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n')],
  ['no-environment', 'the job must run in the live-evals environment', swap('    environment: live-evals\n', '')],
  ['node-20', 'Node must be 22', swap('node-version: 22\n', 'node-version: 20\n')],
  ['install-scripts', 'dependencies must be installed once with npm ci --ignore-scripts', swap('npm ci --ignore-scripts\n', 'npm ci\n')],
  ['ungated-upload', 'the upload must follow the scrub', swap("if: always() && steps.scrub.outputs.scrubbed == 'true'\n", 'if: always()\n')],
  ['raw-upload', 'the upload must follow the scrub', swap('path: ${{ runner.temp }}/live-evals-upload/\n', 'path: ${{ runner.temp }}/live-evals/\n')],
  ['run-all', 'must not run tests/run-all.sh', (source) => `${source}      - run: bash tests/run-all.sh --ci\n`],
  ['secret-on-npm-ci', 'a step other than the probe, the run or the scrub reads a secret', swap('      - run: npm ci --ignore-scripts\n', '      - run: npm ci --ignore-scripts\n        env:\n          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}\n')],
  ['no-scrub', 'a step with id scrub must always run live-evals.sh scrub', swap('        run: bash .github/scripts/live-evals.sh scrub\n', '        run: "true"\n')],
];
const rows = [];
for (const [name, want, mutate] of mutants) {
  const target = path.join(dir, `${name}.yml`);
  fs.writeFileSync(target, mutate(text));
  rows.push(`${name} ${target} ${want}`);
}
process.stdout.write(`${rows.join('\n')}\n`);
NODE
then
  while read -r name target want; do
    [ -n "$name" ] || continue
    MUTANT_N=$((MUTANT_N + 1))
    if node "$SHAPE_JS" "$target" >"$MUTANTS/out.txt" 2>&1 < /dev/null || ! grep -qF "$want" "$MUTANTS/out.txt"; then
      MUTANT_BAD="$MUTANT_BAD $name"
    fi
  done < "$FINDINGS"
else
  MUTANT_BAD=" (the mutants could not be built: $(tr '\n' ' ' < "$FINDINGS"))"
fi
if [ -z "$MUTANT_BAD" ] && [ "$MUTANT_N" = 12 ]; then
  check "Each of the $MUTANT_N planted weakenings of $LIVE_EVALS fails its shape check with its own reason" PASS
else
  check "The $LIVE_EVALS shape check passes or misnames a planted weakening:$MUTANT_BAD (built $MUTANT_N of 12)" FAIL
fi

if [ ! -e "$WORKFLOWS/session-control-nightly.yml" ] \
  && [ ! -e "$WORKFLOWS/pretool-eval-nightly.yml" ] \
  && [ ! -e "$WORKFLOWS/evals.yml" ]; then
  check "The retired per-suite Promptfoo workflows stay absent" PASS
else
  check "The retired per-suite Promptfoo workflows stay absent" FAIL
fi

if node - "$WORKFLOWS" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
for (const name of fs.readdirSync(root).filter((entry) => /\.ya?ml$/.test(entry))) {
  for (const line of fs.readFileSync(path.join(root, name), 'utf8').split(/\r?\n/)) {
    const invokesRunner = /tests\/run-all\.sh/.test(line)
      || /\bnpm\s+(?:test|run-script)\b/.test(line);
    // A trailing `--shard=I/N` is permitted and nothing else is: the point of this
    // check is that Actions never selects a Promptfoo mode, not that the command
    // takes no arguments. The shard value is quoted because it expands a shell
    // arithmetic expression containing spaces.
    if (invokesRunner
        && !/^(?:-\s*)?(?:run:\s*)?bash tests\/run-all\.sh --ci(?: "--shard=[^"]+")?$/.test(line.trim())) {
      process.exit(1);
    }
  }
}
NODE
then
  check "Every Actions full-suite invocation selects the non-Promptfoo CI mode" PASS
else
  check "Every Actions full-suite invocation selects the non-Promptfoo CI mode" FAIL
fi

if grep -Fq -- '--ci' "$RUNNER" \
  && grep -Fq 'Promptfoo suites are local-only' "$RUNNER" \
  && grep -Fq 'promptfoo-local-only.v1.json' "$RUNNER" \
  && grep -Fq 'promptfoo-local-only.v1.json' "$ROOT/tests/run-windows-safety-shard.js"; then
  check "The deterministic runner exposes an explicit local-only CI mode" PASS
else
  check "The deterministic runner exposes an explicit local-only CI mode" FAIL
fi

if node - "$ROOT" "$MANIFEST" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [root, file] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const actual = fs.readdirSync(path.join(root, 'tests', 'structure'))
  .filter((name) => /^test-.*\.sh$/.test(name)).sort();
const local = [
  'test-claude-promptfoo-wrapper.sh',
  'test-promptfoo-concurrency.sh',
  'test-promptfoo-context-nudge-reaction.sh',
  'test-promptfoo-reset-review-limit.sh',
  'test-promptfoo-session-upgrade.sh',
  'test-promptfoo-verify-feature.sh',
  'test-promptfoo-zen-mode.sh',
];
const classified = [...value.ciStructureTests, ...value.localStructureTests];
const offline = value.ciOfflineSuites.map(
  ({ path: suitePath, ciArgs, needsNodeDeps }) => [suitePath, ciArgs, needsNodeDeps],
);
const expectedOffline = [
  ['evals/config-gate/run-eval.sh', ['--self-check'], false],
  ['evals/session-control/run-self-check.sh', ['--ci'], true],
  ['evals/tdd-review-chain/run-self-check.sh', [], false],
  ['evals/reset-review-limit/run-self-check.sh', ['--ci'], true],
  ['evals/tdd-manager-pretool/run-eval.sh', ['--self-check', '--skip-nested'], false],
];
process.exit(value.schemaVersion === 1
  && JSON.stringify(value.localStructureTests) === JSON.stringify(local)
  && JSON.stringify([...new Set(classified)].sort()) === JSON.stringify(actual)
  && classified.length === new Set(classified).size
  && JSON.stringify(offline) === JSON.stringify(expectedOffline) ? 0 : 1);
NODE
then
  check "One canonical allowlist classifies every structure and offline suite" PASS
else
  check "One canonical allowlist classifies every structure and offline suite" FAIL
fi

if grep -Fq 'OFFLINE_LINES="$(offline_inventory)" || exit 2' "$RUNNER" \
  && grep -Fq 'done <<< "$OFFLINE_LINES"' "$RUNNER" \
  && grep -Fq 'if [ "$MODE" != "--ci" ]; then' "$ROOT/evals/session-control/run-self-check.sh" \
  && grep -Fq 'if [ "$MODE" != "--ci" ]; then' "$ROOT/evals/reset-review-limit/run-self-check.sh" \
  && grep -Fq 'enforce-upgrade-coverage.js" --ci' "$ROOT/evals/session-control/run-self-check.sh" \
  && grep -Fq "file !== 'evals/session-control/tests/upgrade-provider-selftest.js'" \
    "$ROOT/evals/session-control/tests/enforce-upgrade-coverage.js"; then
  check "CI retains deterministic eval coverage without launching Promptfoo" PASS
else
  check "CI retains deterministic eval coverage without launching Promptfoo" FAIL
fi

# `gate` became a variable when `skip_test_gate` was added, so the value is no
# longer a literal `"passed"` — a skipped release must be able to say so. The pin
# still exists for the same reason it always did: prepare and publish must emit
# ONE schema, so a reader of the evidence artifact never has to know which job
# wrote it. Both halves are counted, because the conditional addendum carries the
# skip reason and drifting it alone would split the schema just as effectively.
EVIDENCE_SHAPE='{schema:"zensu-deterministic-release-evidence-v1", gate:$gate, source_git_revision:$source_git_revision, runtime_digest:$runtime_digest, plugin_version:$plugin_version}'
EVIDENCE_SKIP_SHAPE='+ (if $gate == "skipped" then {gate_skip_reason:$gate_skip_reason} else {} end)'
# Counted into variables so the FAIL message can name WHICH half drifted; the
# negative pin closes the other direction, where a "simplification" back to a
# hardcoded gate:"passed" would make every skipped release claim it was verified.
EVIDENCE_N="$(grep -Fc "$EVIDENCE_SHAPE" "$WORKFLOWS/release.yml")"
EVIDENCE_SKIP_N="$(grep -Fc "$EVIDENCE_SKIP_SHAPE" "$WORKFLOWS/release.yml")"
if [ "$EVIDENCE_N" -eq 2 ] && [ "$EVIDENCE_SKIP_N" -eq 2 ] \
  && ! grep -Fq 'gate:"passed"' "$WORKFLOWS/release.yml"; then
  check "Prepare and publish emit the same deterministic release evidence schema" PASS
else
  check "Prepare and publish emit the same deterministic release evidence schema (shape=$EVIDENCE_N/2 skip-branch=$EVIDENCE_SKIP_N/2)" FAIL
fi

if jq -e '.devDependencies.promptfoo | type == "string"' "$PACKAGE" >/dev/null 2>&1 \
  && [ -f "$ROOT/evals/session-control/run-eval.sh" ] \
  && [ -f "$ROOT/evals/session-control/promptfooconfig-live.yaml" ] \
  && grep -Fq 'session-control:release' "$PACKAGE"; then
  check "Promptfoo release and live suites remain available for local execution" PASS
else
  check "Promptfoo release and live suites remain available for local execution" FAIL
fi

printf '%s\n' '----' "test-promptfoo-local-only: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
