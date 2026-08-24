// rule-block-v1.js — the ONE hardened reader for a marker-delimited rule block.
//
// Two hooks inject a rule they read out of `docs/`: the evidence-discipline
// carrier at SessionStart and the best-solution-first carrier at
// UserPromptSubmit/SubagentStart. Both read a fixed path under the executing
// plugin root, both harden the open the same way, and both bound the block by
// the same number — and until this module they did it in three hand-copies (two
// hooks plus a shell variable in the suite), policed by a cross-carrier equality
// check. An equality check is not a definition: it proves the copies agree, not
// that they are right, and it cannot be driven from a unit layer at all. Every
// refusal below was source-pinned by `grep -qF` and executed by nothing.
//
// So the seam is taken here rather than argued about again. The hooks keep their
// own shell guards (plugin-root identity, the `-f` / `! -L` pre-check, the config
// gate) — those are per-carrier policy. What is shared is the read and the parse.
//
// Fail-silent by contract: every refusal returns `{ block: null, reason }` and
// never throws, because a hook that cannot read its rule must not block a prompt
// or a spawn. `reason` exists for the unit layer and for a diagnostic caller; no
// hook prints it.

'use strict';

const fs = require('fs');

// The block is injected on EVERY prompt and at EVERY spawn, so its size is a
// per-turn multiplier. One definition, because raising it means re-arguing the
// bound on the unswitchable carrier too rather than following the louder one.
const MAX_BLOCK = 4000;
const MAX_FILE = 1048576;

const REASONS = Object.freeze({
  NOT_A_FILE: 'not-a-file',
  SWAPPED: 'swapped',
  TOO_LARGE: 'file-too-large',
  SHORT_READ: 'short-read',
  UNREADABLE: 'unreadable',
  NO_OPEN: 'no-open-marker',
  NO_CLOSE: 'no-close-marker',
  EMPTY: 'empty-block',
  BLOCK_TOO_LARGE: 'block-too-large',
});

// Platform-gated exactly as `platformNoFollow()` in hooks/lib/plan-payload-v1.js:
// a bare `O_NOFOLLOW || 0` accepts a flag that is DEFINED but unsupported, where
// openSync throws and the rule silently never injects.
function platformNoFollow() {
  return process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW
    : 0;
}

function platformNonBlock() {
  return Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
}

// lstat → O_NOFOLLOW open → fstat dev/ino. What that sequence closes is ONE
// window: the final path component being swapped between the shell pre-check and
// the read. It is worth stating what it does NOT close, because an earlier
// wording of this comment said "this closes it" and a reader took that as
// covering all three:
//   - the file's CONTENT. Nothing checks it, so the inode's bytes at read time
//     were never approved by anything; the guard is about identity, not trust.
//   - INTERMEDIATE path components. O_NOFOLLOW binds the last component only, so
//     a symlinked `docs/` directory is still followed. The hooks' shell guard has
//     the same limit.
//   - INODE REUSE. dev+ino can be recycled after an unlink, so a delete-and-
//     recreate that lands on the same inode number compares equal.
// The remaining exposure is bounded by who can write the installed plugin tree,
// which is the operator — see the hooks' own headers for the failure classes.
//
// Deliberate divergence from the plan-payload reference: no `nlink === 1`
// requirement. There it defends a CALLER-NAMED path, where a hard link is how an
// attacker reaches a file the symlink check refuses. Here the path is fixed under
// the executing plugin root, so an attacker who can plant a hard link can equally
// rewrite the file — the check would buy nothing and would silently disable the
// rule on any install that materializes files by hard link (`cp -al`,
// content-addressed stores).
function readRuleFile(rulePath) {
  let pre;
  try { pre = fs.lstatSync(rulePath); } catch (_) { return { text: null, reason: REASONS.UNREADABLE }; }
  if (!pre.isFile()) return { text: null, reason: REASONS.NOT_A_FILE };
  let fd;
  try {
    fd = fs.openSync(rulePath, fs.constants.O_RDONLY | platformNoFollow() | platformNonBlock());
  } catch (_) {
    return { text: null, reason: REASONS.UNREADABLE };
  }
  try {
    const post = fs.fstatSync(fd);
    if (!post.isFile() || post.dev !== pre.dev || post.ino !== pre.ino) {
      return { text: null, reason: REASONS.SWAPPED };
    }
    if (post.size > MAX_FILE) return { text: null, reason: REASONS.TOO_LARGE };
    // Bounded by the size fstat already reported, so a file that GROWS between the
    // two calls cannot be read past what was measured.
    const buf = Buffer.alloc(post.size);
    let filled = 0;
    while (filled < post.size) {
      const chunk = fs.readSync(fd, buf, filled, post.size - filled, filled);
      if (chunk < 1) break;
      filled += chunk;
    }
    // A short read would truncate the file before the marker block and drop the
    // injection while looking exactly like a correct refusal. Refuse explicitly.
    if (filled !== post.size) return { text: null, reason: REASONS.SHORT_READ };
    return { text: buf.toString('utf8'), reason: null };
  } catch (_) {
    return { text: null, reason: REASONS.UNREADABLE };
  } finally {
    // A throwing close must not replace a successful read: without this the outer
    // catch swallows it and the injection is dropped after the bytes were in.
    try { fs.closeSync(fd); } catch (_) { /* the read result is what matters */ }
  }
}

// The FIRST OPEN..CLOSE pair wins; a later duplicate marker is ignored.
//
// The previous rule refused whenever a second OPEN appeared anywhere in the file,
// which turned append-only access into a silent kill switch: one duplicated
// marker line — inside a code fence, in an appended example, in a merged section
// that merely quotes the marker — permanently disabled the injection, and on the
// evidence-discipline carrier that is the correctness rule documented as
// unswitchable. Taking the first pair keeps the shipped block authoritative: an
// appender cannot displace it, because their block is later in the file.
//
// `\r` is stripped, so a CRLF checkout parses. The repo pins `* text=auto eol=lf`
// so every git checkout — including the clone `claude plugin install` performs —
// yields LF, which is why this was not a live defect; it is one character, and it
// removes a silent-kill class from an install that arrives by any other route.
function extractBlock(text, open, close) {
  if (typeof text !== 'string') return { block: null, reason: REASONS.UNREADABLE };
  const lines = text.split('\n').map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l));
  const at = lines.indexOf(open);
  if (at < 0) return { block: null, reason: REASONS.NO_OPEN };
  if (lines[at + 2] !== close) return { block: null, reason: REASONS.NO_CLOSE };
  const block = String(lines[at + 1] || '').replace(/^>\s*/, '').trim();
  if (!block) return { block: null, reason: REASONS.EMPTY };
  if (block.length > MAX_BLOCK) return { block: null, reason: REASONS.BLOCK_TOO_LARGE };
  return { block, reason: null };
}

function readRuleBlock(rulePath, open, close) {
  const read = readRuleFile(rulePath);
  if (read.text === null) return { block: null, reason: read.reason };
  return extractBlock(read.text, open, close);
}

module.exports = {
  MAX_BLOCK,
  MAX_FILE,
  REASONS,
  platformNoFollow,
  platformNonBlock,
  readRuleFile,
  extractBlock,
  readRuleBlock,
};
