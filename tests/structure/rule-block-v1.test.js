// Unit contract for hooks/lib/rule-block-v1.js — the ONE hardened reader both
// rule-injecting hooks now call.
//
// Every refusal in this module used to be asserted by `grep -qF` against two
// hand-copies and by a cross-carrier equality check between them. That proves the
// copies agree with each other; it never proved any of them right, and it could
// not reach a branch at all. These cases execute them.
//
// Driven from tests/structure/test-best-solution-first.sh, because tests/run-all.sh
// discovers only test-*.sh — a *.test.js with no driver is never executed.

'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const mod = require(path.join(__dirname, '..', '..', 'hooks', 'lib', 'rule-block-v1.js'));
const OPEN = '<!-- zensu:probe -->';
const CLOSE = '<!-- /zensu:probe -->';
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-rule-block-'));
const write = (dir, text) => {
  const f = path.join(dir, 'rule.md');
  fs.writeFileSync(f, text);
  return f;
};
const doc = (body) => `intro\n\n${OPEN}\n> ${body}\n${CLOSE}\n\ntrailer\n`;

test('the shipped happy path yields the block with its blockquote marker stripped', () => {
  const dir = tmp();
  const out = mod.readRuleBlock(write(dir, doc('Offer the best long-term solution first.')), OPEN, CLOSE);
  assert.equal(out.block, 'Offer the best long-term solution first.');
  assert.equal(out.reason, null);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a DUPLICATE open marker no longer disables the injection — the first pair wins', () => {
  // This is the finding, not a refactor: the previous rule refused whenever a
  // second OPEN appeared anywhere in the file, which made append-only access a
  // silent kill switch. On the evidence-discipline carrier that directive is
  // documented as not switchable off, and one duplicated marker line turned it off.
  const dir = tmp();
  const text = `${doc('shipped rule')}\n${OPEN}\n> appended rule\n${CLOSE}\n`;
  const out = mod.readRuleBlock(write(dir, text), OPEN, CLOSE);
  assert.equal(out.block, 'shipped rule', 'the SHIPPED block stays authoritative');
  // And a marker merely quoted inside a fence does not displace it either.
  const fenced = `${doc('shipped rule')}\n\`\`\`\n${OPEN}\n\`\`\`\n`;
  assert.equal(mod.readRuleBlock(write(dir, fenced), OPEN, CLOSE).block, 'shipped rule');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a CRLF checkout parses', () => {
  // Not a live defect — the repo pins `* text=auto eol=lf`, so every git checkout
  // including the clone `claude plugin install` performs yields LF. It is one
  // character, and it removes a silent-kill class from any install arriving by
  // another route.
  const dir = tmp();
  const out = mod.readRuleBlock(write(dir, doc('crlf rule').replace(/\n/g, '\r\n')), OPEN, CLOSE);
  assert.equal(out.block, 'crlf rule');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('every marker-shape refusal is reached and named', () => {
  const dir = tmp();
  const cases = [
    ['no marker at all\n', mod.REASONS.NO_OPEN],
    [`${OPEN}\n> body\nnot the close marker\n`, mod.REASONS.NO_CLOSE],
    [`${OPEN}\n${CLOSE}\n`, mod.REASONS.NO_CLOSE],
    [`${OPEN}\n> \n${CLOSE}\n`, mod.REASONS.EMPTY],
    [doc('x'.repeat(mod.MAX_BLOCK + 1)), mod.REASONS.BLOCK_TOO_LARGE],
  ];
  for (const [text, reason] of cases) {
    const out = mod.readRuleBlock(write(dir, text), OPEN, CLOSE);
    assert.equal(out.block, null, reason);
    assert.equal(out.reason, reason);
  }
  // The boundary is inclusive on the accepted side, so the cap is the cap.
  assert.equal(mod.readRuleBlock(write(dir, doc('x'.repeat(mod.MAX_BLOCK))), OPEN, CLOSE).block.length,
    mod.MAX_BLOCK);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('an absent path, a directory and an oversized file are refused, not read', () => {
  const dir = tmp();
  assert.equal(mod.readRuleBlock(path.join(dir, 'nope.md'), OPEN, CLOSE).reason, mod.REASONS.UNREADABLE);
  assert.equal(mod.readRuleBlock(dir, OPEN, CLOSE).reason, mod.REASONS.NOT_A_FILE);
  const big = path.join(dir, 'big.md');
  fs.writeFileSync(big, 'x'.repeat(mod.MAX_FILE + 1));
  assert.equal(mod.readRuleBlock(big, OPEN, CLOSE).reason, mod.REASONS.TOO_LARGE);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a symlinked rule file is refused by the open itself, not by a pre-check', {
  skip: process.platform === 'win32' ? 'symlink semantics differ' : false,
}, () => {
  // The hooks also pre-check with `[ ! -L ]`, but that check and the read are two
  // syscalls apart. This asserts the MODULE refuses on its own, which is what the
  // shell pre-check cannot prove.
  const dir = tmp();
  const real = write(dir, doc('real rule'));
  const link = path.join(dir, 'link.md');
  fs.symlinkSync(real, link);
  const out = mod.readRuleBlock(link, OPEN, CLOSE);
  assert.equal(out.block, null);
  assert.ok(out.reason === mod.REASONS.UNREADABLE || out.reason === mod.REASONS.NOT_A_FILE, out.reason);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a FIFO cannot block the read', {
  skip: process.platform === 'win32' ? 'no mkfifo' : false,
}, () => {
  // The type check runs AFTER the open, so it cannot protect the open itself: on
  // POSIX `open(fifo, O_RDONLY)` blocks until a writer arrives. O_NONBLOCK is what
  // makes it return, and this case would hang rather than fail without it.
  const dir = tmp();
  const fifo = path.join(dir, 'rule.md');
  let made = false;
  try { execFileSync('mkfifo', [fifo], { stdio: 'ignore' }); made = true; } catch (_) { /* no mkfifo */ }
  if (made) {
    const out = mod.readRuleBlock(fifo, OPEN, CLOSE);
    assert.equal(out.block, null);
    assert.equal(out.reason, mod.REASONS.NOT_A_FILE);
  }
  fs.rmSync(dir, { recursive: true, force: true });
});

test('the platform flag helpers stay gated rather than truthy-coerced', () => {
  // A bare `O_NOFOLLOW || 0` accepts a flag that is DEFINED but unsupported, where
  // openSync throws and the rule silently never injects.
  const noFollow = mod.platformNoFollow();
  assert.equal(Number.isInteger(noFollow), true);
  if (process.platform === 'win32') assert.equal(noFollow, 0);
  assert.equal(Number.isInteger(mod.platformNonBlock()), true);
});

test('extractBlock is total over a non-string, so a caller cannot make it throw', () => {
  for (const bad of [null, undefined, 42, {}, []]) {
    assert.equal(mod.extractBlock(bad, OPEN, CLOSE).reason, mod.REASONS.UNREADABLE);
  }
});

test('MAX_BLOCK has ONE definition and both carriers reach it through this module', () => {
  // The number used to be declared three times — twice in shell heredocs and once
  // as a shell variable in a suite — bound only by a cross-carrier equality check.
  const root = path.join(__dirname, '..', '..');
  for (const hook of ['user-prompt-best-solution-first.sh', 'session-start-evidence-discipline.sh']) {
    const src = fs.readFileSync(path.join(root, 'hooks', hook), 'utf8');
    assert.equal(/MAX_BLOCK\s*=\s*\d/.test(src), false, `${hook} redeclares MAX_BLOCK`);
    assert.ok(src.includes('rule-block-v1.js'), `${hook} does not load the shared reader`);
    assert.ok(src.includes('readRuleBlock'), `${hook} does not call the shared reader`);
  }
});
