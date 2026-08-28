'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const LIB = path.join(__dirname, '..', '..', 'hooks', 'lib');
const allow = require(path.join(LIB, 'reviewer-spawn-allow-v1.js'));
const denial = require(path.join(LIB, 'reviewer-spawn-denial-v1.js'));
const principal = require(path.join(LIB, 'claude-principal-v1.js'));

function spawnPayload(subagentType, toolName) {
  return JSON.stringify({
    tool_name: toolName || 'Agent',
    tool_input: { subagent_type: subagentType, prompt: 'review this' },
  });
}

test('the confined set carries exactly the five read-only reviewers', () => {
  assert.deepStrictEqual(allow.CONFINED_REVIEWER_AGENTS.slice().sort(), [
    'zensu:code-reviewer',
    'zensu:plan-review-worker',
    'zensu:pr-review-worker',
    'zensu:review-aspect',
    'zensu:review-judge',
  ]);
});

test('no reviewer identity is re-spelled in the module body, in any quoting style', () => {
  const source = fs.readFileSync(path.join(LIB, 'reviewer-spawn-allow-v1.js'), 'utf8');
  const body = source.split('\n').filter((line) => !/^\s*\/\//.test(line)).join('\n');
  for (const agent of allow.CONFINED_REVIEWER_AGENTS) {
    for (const quote of ["'", '"', '`']) {
      assert.strictEqual(
        body.includes(quote + agent + quote),
        false,
        agent + ' must be derived from claude-principal-v1.js, not spelled here (' + quote + ')',
      );
    }
  }
  assert.ok(allow.CONFINED_REVIEWER_AGENTS.includes(denial.REVIEWER_SUBAGENT_TYPE));
});

// The confined set has ONE owner plus one PRE-EXISTING hand-copy, named here rather than
// quietly skipped: review-evidence-lease-v1.js spells the two evidence-worker identities for
// its own lease binding. That copy predates this feature and is not the grant's definition —
// but a scan that silently excluded it could not tell a known copy from a new rival one. Any
// OTHER file under hooks/ spelling a member is a second definition of the set and fails.
test('the confined set has exactly one owner and one named pre-existing copy under hooks/', () => {
  const hooksDir = path.join(__dirname, '..', '..', 'hooks');
  const owner = path.join(hooksDir, 'lib', 'claude-principal-v1.js');
  const KNOWN_COPY = 'review-evidence-lease-v1.js';
  const knownCopyPath = path.join(hooksDir, 'lib', KNOWN_COPY);
  assert.ok(fs.existsSync(knownCopyPath), 'the named pre-existing copy must still exist');
  // zensu:code-reviewer alone lives in many files by design — CLAUDE.md instructs a grep
  // before renaming it. The four OTHER members are what this scan bounds: a second
  // hardcoded copy of them anywhere under hooks/ would be a rival definition of the set.
  const scoped = allow.CONFINED_REVIEWER_AGENTS
    .filter((a) => a !== denial.REVIEWER_SUBAGENT_TYPE);
  assert.ok(scoped.length >= 4);
  const offenders = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      if (!/\.(js|sh)$/.test(entry.name)) continue;
      if (full === owner || full === knownCopyPath) continue;
      const text = fs.readFileSync(full, 'utf8');
      const code = text.split('\n')
        .filter((l) => !/^\s*(\/\/|#)/.test(l))
        .join('\n');
      for (const agent of scoped) {
        for (const quote of ["'", '"', '`']) {
          if (code.includes(quote + agent + quote)) offenders.push(entry.name + ':' + agent);
        }
      }
    }
  };
  walk(hooksDir);
  assert.deepStrictEqual(offenders, [], 'the confined set must have one definition under hooks/');
});

test('the set is exactly the plugin-scoped confined principals', () => {
  const expected = [
    ...principal.REVIEWER_TYPES,
    ...principal.EVIDENCE_WORKER_TYPES,
  ].filter((name) => name.startsWith(allow.PLUGIN_SCOPE)).sort();
  assert.deepStrictEqual(allow.CONFINED_REVIEWER_AGENTS.slice(), expected);
  assert.ok(expected.length > 0);
});

test('bare agent names are never granted, only the plugin-scoped spellings', () => {
  const bare = [...principal.REVIEWER_TYPES].filter((n) => !n.startsWith(allow.PLUGIN_SCOPE));
  assert.ok(bare.length > 0, 'the principal module still carries bare fixture names');
  for (const name of bare) {
    assert.strictEqual(allow.isConfinedReviewer(name), false);
    assert.strictEqual(allow.decide(spawnPayload(name)), '');
  }
});

test('every PLM identity is excluded', () => {
  for (const name of principal.PLM_TYPES) {
    assert.strictEqual(allow.isConfinedReviewer(name), false);
    assert.strictEqual(allow.decide(spawnPayload(name)), '');
  }
});

test('the spawn tool names are shared with the denial module', () => {
  assert.strictEqual(allow.SPAWN_TOOL_NAMES, denial.SPAWN_TOOL_NAMES);
});

test('every confined reviewer is granted through both spawn tool names', () => {
  for (const agent of allow.CONFINED_REVIEWER_AGENTS) {
    for (const tool of allow.SPAWN_TOOL_NAMES) {
      const rendered = allow.decide(spawnPayload(agent, tool));
      const parsed = JSON.parse(rendered);
      assert.strictEqual(parsed.hookSpecificOutput.hookEventName, 'PreToolUse');
      assert.strictEqual(parsed.hookSpecificOutput.permissionDecision, 'allow');
      assert.ok(parsed.hookSpecificOutput.permissionDecisionReason.includes(agent));
      assert.ok(
        parsed.hookSpecificOutput.permissionDecisionReason
          .includes('hooks.reviewerSpawnAutoAllow'),
        'the reason names the config key that turns the grant off',
      );
      assert.strictEqual(rendered.endsWith('\n'), true);
      assert.strictEqual(rendered.trimEnd().split('\n').length, 1);
    }
  }
});

test('an unconfined subagent type is silent, never denied', () => {
  for (const agent of ['zensu:zensu-plm', 'general-purpose', 'Explore', '', 'zensu:code-reviewer ']) {
    assert.strictEqual(allow.decide(spawnPayload(agent)), '');
  }
});

test('a non-string subagent type is silent', () => {
  for (const value of [null, 42, true, ['zensu:code-reviewer'], { name: 'zensu:code-reviewer' }]) {
    const payload = JSON.stringify({ tool_name: 'Agent', tool_input: { subagent_type: value } });
    assert.strictEqual(allow.decide(payload), '');
  }
});

test('a tool outside the spawn set is silent even for a confined reviewer', () => {
  for (const tool of ['Bash', 'Edit', 'Write', 'Read', 'agent', 'TASK', '']) {
    const payload = JSON.stringify({
      tool_name: tool,
      tool_input: { subagent_type: 'zensu:code-reviewer' },
    });
    assert.strictEqual(allow.decide(payload), '');
  }
});

test('a malformed or hostile payload is silent, never a grant and never a throw', () => {
  const cases = [
    '',
    'not json',
    '[]',
    'null',
    '"zensu:code-reviewer"',
    '{"tool_name":"Agent"}',
    '{"tool_name":"Agent","tool_input":null}',
    '{"tool_name":"Agent","tool_input":[]}',
    '{"tool_name":"Agent","tool_input":"zensu:code-reviewer"}',
  ];
  for (const raw of cases) {
    assert.strictEqual(allow.decide(raw), '', 'silent for ' + JSON.stringify(raw));
  }
});

test('an oversized payload is refused rather than parsed', () => {
  const filler = 'x'.repeat(allow.MAX_PAYLOAD_BYTES);
  const payload = JSON.stringify({
    tool_name: 'Agent',
    tool_input: { subagent_type: 'zensu:code-reviewer', prompt: filler },
  });
  assert.ok(Buffer.byteLength(payload, 'utf8') > allow.MAX_PAYLOAD_BYTES);
  assert.strictEqual(allow.decide(payload), '');
});

test('the verdict names which condition failed', () => {
  assert.strictEqual(allow.allowVerdict(null).reason, allow.REFUSALS.UNREADABLE);
  assert.strictEqual(
    allow.allowVerdict({ tool_name: 'Bash', tool_input: {} }).reason,
    allow.REFUSALS.NOT_A_SPAWN,
  );
  const notConfined = allow.allowVerdict({
    tool_name: 'Agent',
    tool_input: { subagent_type: 'general-purpose' },
  });
  assert.strictEqual(notConfined.reason, allow.REFUSALS.NOT_CONFINED);
  assert.strictEqual(notConfined.subagentType, 'general-purpose');
});

test('renderDecision never emits a deny or an ask', () => {
  for (const verdict of [
    null,
    { allow: false, subagentType: 'zensu:code-reviewer' },
    { allow: 'true', subagentType: 'zensu:code-reviewer' },
    { allow: 1, subagentType: 'zensu:code-reviewer' },
  ]) {
    assert.strictEqual(allow.renderDecision(verdict), '');
  }
  const granted = allow.renderDecision({ allow: true, subagentType: 'zensu:code-reviewer' });
  assert.strictEqual(granted.includes('"deny"'), false);
  assert.strictEqual(granted.includes('"ask"'), false);
});

test('the measured host build is cross-checked against the module header', () => {
  const source = fs.readFileSync(path.join(LIB, 'reviewer-spawn-allow-v1.js'), 'utf8');
  const header = source.slice(0, source.indexOf("'use strict'"));
  assert.ok(
    header.includes('build (' + allow.ALLOW_BYPASS_SOURCE_BUILD + ')'),
    'the header must name the build the bypass was measured against',
  );
  assert.match(allow.ALLOW_BYPASS_SOURCE_BUILD, /^\d+\.\d+\.\d+$/);
});

test('the header records the three host limits that bound the grant', () => {
  const source = fs.readFileSync(path.join(LIB, 'reviewer-spawn-allow-v1.js'), 'utf8');
  const header = source.slice(0, source.indexOf("'use strict'"));
  assert.ok(header.includes('permissions.deny'), 'limit 1: a deny rule still overrides');
  assert.ok(header.includes('deny > ask > allow'), 'limit 2: another hook can outrank');
  assert.ok(header.includes('requireCanUseTool'), 'limit 3: canUseTool forces the pipeline');
});

test('every confined agent is frontmatter-restricted to the read trio', () => {
  const agentsDir = path.join(__dirname, '..', '..', 'agents');
  for (const agent of allow.CONFINED_REVIEWER_AGENTS) {
    const file = path.join(agentsDir, agent.replace(/^zensu:/, '') + '.md');
    const text = fs.readFileSync(file, 'utf8');
    const frontmatter = text.split('---')[1] || '';
    const tools = /^tools:\s*(.+)$/m.exec(frontmatter);
    assert.ok(tools, agent + ' must declare a tools: line');
    const declared = tools[1].split(',').map((s) => s.trim()).sort();
    assert.deepStrictEqual(
      declared,
      ['Glob', 'Grep', 'Read'],
      agent + ' must be confined to the read trio before it may be granted',
    );
  }
});

test('the read-trio invariant is enforced at decision time, not only at build time', () => {
  const os = require('node:os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'revallow-fm-'));
  const write = (stem, tools) => fs.writeFileSync(
    path.join(dir, stem + '.md'),
    '---\nname: ' + stem + '\ntools: ' + tools + '\n---\nbody\n',
  );
  write('good', 'Read, Grep, Glob');
  write('armed', 'Read, Grep, Glob, Bash');
  write('untooled', 'Read, Grep');
  fs.writeFileSync(path.join(dir, 'nofrontmatter.md'), 'no frontmatter here\n');

  const kept = allow.confinedByFrontmatter(dir, [
    'zensu:good', 'zensu:armed', 'zensu:untooled', 'zensu:nofrontmatter', 'zensu:absent',
  ]);

  assert.deepStrictEqual(kept, ['zensu:good'],
    'only an agent whose frontmatter declares exactly the read trio may be granted');
});

test('the module derives its agents directory from its own location, not the environment', () => {
  const source = fs.readFileSync(path.join(LIB, 'reviewer-spawn-allow-v1.js'), 'utf8');
  const body = source.slice(source.indexOf("'use strict'"));
  assert.ok(/__dirname/.test(body),
    'the agents directory must be derived from __dirname');
  assert.ok(!/process\.env/.test(body),
    'the decider must read no environment at all — that is what keeps the hook at four conditions');
});
