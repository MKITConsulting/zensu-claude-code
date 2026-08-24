#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// The write-anchor comparison below is the GATE's comparison, so it calls the
// gate's own predicate instead of re-encoding it. `within` and `msysToDrive` are
// module-scope exports of hooks/lib/bash-source-write-parse.js; taking the seam
// is what removed a sixth hand-copy of the containment rule AND supplied the
// MSYS drive normalization this file previously had no equivalent of.
//
// A FAILED load must not silently change the verdict, so there is no fallback
// copy: `GATE` stays null and `writeAnchor` reports `rejected:gate-unavailable`,
// which every renderer already presents as unknown-assume-denied. The plugin
// layout is fixed relative to this script, and a skill script that cannot see
// its own plugin has bigger problems than this line.
const GATE = (() => {
  try {
    const here = path.dirname(fileURLToPath(import.meta.url));
    const require_ = createRequire(import.meta.url);
    return require_(path.join(here, '..', '..', '..', 'hooks', 'lib', 'bash-source-write-parse.js'));
  } catch { return null; }
})();
const IS_WINDOWS = process.platform === 'win32';

const HOME = os.homedir();
const PROJECTS = path.join(HOME, '.claude', 'projects');
const SESSIONS = path.join(HOME, '.claude', 'sessions');
const HANDOFFS = path.join(HOME, '.claude', 'handoffs');
// Records that could not be read at all. Counted rather than swallowed: a
// silently short answer is indistinguishable from an idle machine, and the
// skill's own docs route "no sessions found" to a different cause.
let SKIPPED = 0;
// Set from argv before any command runs. `skippedNote()` must consult a
// module-scope flag rather than `opts`: parseArgs can call fail() -> flush()
// while `const opts` is still in its temporal dead zone.
let JSON_MODE = false;
const FULL_READ_LIMIT = 8 * 1024 * 1024;
const HEAD_BYTES = 256 * 1024;
const TAIL_BYTES = 768 * 1024;

function parseArgs(argv) {
  const out = { _: [], days: 21, prompts: 12, json: false, all: false, live: false, git: true, repo: null, force: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--all') out.all = true;
    else if (a === '--force') out.force = true;
    else if (a === '--live') out.live = true;
    else if (a === '--no-git') out.git = false;
    // Both operands are validated. An unvalidated `--prompts` was the worse of
    // the two: `Number("--json")` is NaN, `Math.max(1, NaN)` is NaN, and
    // `slice(-NaN)` is `slice(0)` — the ENTIRE prompt history, with the
    // "(N earlier omitted)" self-report suppressed by the same NaN. The mistake
    // ran towards maximum disclosure and reported nothing.
    else if (a === '--days') out.days = numericOperand(a, argv[++i]);
    else if (a === '--prompts') out.prompts = numericOperand(a, argv[++i]);
    else if (a === '--repo') out.repo = argv[++i];
    else if (a.startsWith('--')) fail(`unknown flag: ${a}`);
    else out._.push(a);
  }
  return out;
}

function numericOperand(flag, raw) {
  const n = Number(raw);
  if (raw === undefined || raw === '' || !Number.isFinite(n)) fail(`${flag} needs a number (got ${raw === undefined ? 'nothing' : `"${raw}"`})`);
  return n;
}

function fail(msg, code = 1) {
  flush();
  process.stderr.write(`session-trail: ${msg}\n`);
  process.exit(code);
}

function git(cwd, args) {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

function dirExists(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function normSlug(s) {
  return s.replace(/[^A-Za-z0-9]/g, '-');
}

function repoContext(startDir) {
  if (!dirExists(startDir)) return null;
  const common = git(startDir, ['rev-parse', '--git-common-dir']);
  if (!common) return null;
  const abs = path.isAbsolute(common) ? common : path.resolve(startDir, common);
  const root = path.basename(abs) === '.git' ? path.dirname(abs) : abs;
  const worktrees = new Set([root]);
  const listed = git(startDir, ['worktree', 'list', '--porcelain']) || '';
  for (const line of listed.split('\n')) {
    if (line.startsWith('worktree ')) worktrees.add(line.slice(9).trim());
  }
  return { root, name: path.basename(root), worktrees };
}

// Strip a trailing separator, but never turn a filesystem ROOT into something
// else: on win32 `C:\` would become `C:`, a drive-RELATIVE spelling that
// `path.relative` then resolves against that drive's current directory instead of
// its root. `path.parse().root` is the portable test; a length check only ever
// covered POSIX `/`.
// Platform-selected, because the two hosts disagree about what a separator IS. On
// win32 both `\` and `/` end a path; on POSIX only `/` does, and a backslash is an
// ordinary character in a directory name. Stripping it there is not a cosmetic
// over-reach — it rewrote the anchor: `…/foo\` canonicalized to `…/foo`, which no
// longer contains its own nested worktree `…/foo\/wt`, so a covered worktree
// rendered as `denied here` from a deterministic input.
const TRAILING_SEP = process.platform === 'win32' ? /[\\/]+$/ : /\/+$/;

function trimDir(p) {
  return path.parse(p).root === p ? p : p.replace(TRAILING_SEP, '');
}

// BOTH operands, canonicalized TOGETHER and in ONE namespace. Two things were
// wrong with doing it per-operand:
//
// The MSYS half. Under Git Bash an exported variable arrives as `D:\a\proj`
// while a path read from a session record is still spelled `/d/a/proj`, and
// `path.isAbsolute` answers "is rooted" rather than "is fully qualified" — so
// the POSIX spelling passes the admission guard and `path.resolve` then splices
// it under whatever drive `process.cwd()` sits on. That is the same
// current-directory derivation `writeAnchor` refuses to make, arriving one call
// further down. `msysToDrive` is the gate's own normalizer and bridges it.
//
// The realpath half. `realpathSync` keeps the LEXICAL spelling for a path that
// does not exist, so canonicalizing each side on its own put the two in
// DIFFERENT namespaces whenever exactly one existed — precisely the `!! MISSING`
// worktree case. On a host where the anchor's spelling differs from its realpath
// (macOS /tmp -> /private/tmp, a symlinked home, a symlinked worktrees
// directory) a genuinely nested worktree then compared as an escape. Either both
// sides are real or neither is: one failure drops BOTH back to lexical.
function canonicalPair(a, b) {
  const absA = path.resolve(GATE ? GATE.msysToDrive(a, IS_WINDOWS) : a);
  const absB = path.resolve(GATE ? GATE.msysToDrive(b, IS_WINDOWS) : b);
  let realA = absA;
  let realB = absB;
  let bothReal = true;
  try { realA = fs.realpathSync.native(absA); } catch { bothReal = false; }
  try { realB = fs.realpathSync.native(absB); } catch { bothReal = false; }
  return bothReal ? [trimDir(realA), trimDir(realB)] : [trimDir(absA), trimDir(absB)];
}

// The Bash source-write gate compares every write target against the session's
// IMMUTABLE Session Control project root — hooks/lib/claude-hook-session-v1.js
// exports it as ZENSU_PROJECT_ROOT and hooks/pre-bash-source-write-gate.sh hands
// that value to the parser as CLAUDE_PROJECT_DIR. It is minted at SessionStart
// and never moves, so a takeover into ANOTHER worktree can edit and run tests
// but cannot commit: rules (B) and (C) refuse every source write and every
// working-tree git verb whose target escapes that root. Nothing re-anchors a
// session, so the constraint has to be reported BEFORE the first edit rather
// than discovered as a deny afterwards.
//
// The comparison is CONTAINMENT, never equality, because that is the test the
// gate performs: `within(projectRoot, p)` in hooks/lib/bash-source-write-parse.js,
// applied by rule (B) to a write target and by rule (C) to the addressed
// repository. A worktree NESTED inside the anchor is therefore writable — which
// is the layout this repo mandates (`git worktree add .claude/worktrees/<name>`),
// so an equality test would report the ordinary case as denied. The `..` test is
// anchored on a separator and on the exact `..`, because a bare startsWith("..")
// also rejects a legitimately nested `..bak`. This is NOT a hand-copy: `within`
// is a module-scope export of the parser and is CALLED here, so the two cannot
// drift, and the MSYS drive normalization the gate applies to the same
// comparison (`msysToDrive`) arrives with it rather than being omitted.
//
// Three narrowings, stated rather than hidden. Rule (C) also exempts a target
// under a temp root (`isTemp`), so a worktree in `/tmp` is writable while this
// reports it covered=false. Only that FIRST one errs toward warning, which is the
// safe direction for a line whose remedy is "start a session over there". The
// other two err toward `allowed`, and that is why the split is written down.
// Rule (A) can still deny an in-anchor raw shell overwrite of tracked source,
// which this never reports — and it fires on an IN-ANCHOR target, precisely where
// this answers `allowed`. The third is the same direction:
// it canonicalizes BOTH sides through `realpathSync`, while the gate realpaths only
// its comparison roots and resolves a `cd` operand LEXICALLY. A target whose
// literal spelling escapes the anchor but whose realpath lands inside therefore
// reads covered=true here and denies at the gate. Reporting it is the honest
// remedy; matching it would mean giving up symlink tolerance everywhere else.
//
// The caller root is read ONLY from the environment. It is deliberately not
// derived from `process.cwd()`: the gate's anchor is the SessionStart cwd, so a
// git toplevel of the current directory measures the wrong subject twice over —
// after a `cd` into the target it reports the target itself (rendering the very
// takeover being diagnosed as writable), and for a session started in a
// subdirectory it reports the repo root rather than that subdirectory. Both
// produce a confident "allowed" for writes the gate refuses. `--repo` is not a
// source either: that flag selects which repo to scan, not where this session is
// anchored.
//
// Which is also why a channel is usable only when it carries an ABSOLUTE path,
// and why the value that wins is carried VERBATIM — and why the TARGET operand
// carries the same admission rather than a bare truthiness test. That half is not
// symmetry: `canonicalPair` begins with `path.resolve`, so a relative recorded
// worktree is completed from the current directory just as a relative channel
// value would be, reintroducing the same derivation on the other side of the same
// comparison, where the structural pin that proves it absent from the caller side
// does not look. Both halves close a way back
// to the same defect. A RELATIVE value reaches `canonicalPair`, whose first
// statement is `path.resolve` — so the current-directory derivation this
// function refuses to make would be reintroduced one call further down, where
// the structural pin (W3b extracts this function's body and greps it) cannot
// see it. A relative value is therefore passed over rather than repaired, and
// the next channel gets its turn. And `.trim()` still decides PRESENCE — a
// whitespace-only value falls through as before — but it must not rewrite what
// is compared: a leading or trailing space is legal in a POSIX directory name
// and the gate receives the untrimmed value, so trimming would compare a
// different directory than the one that will actually be judged, erring toward
// `allowed`.
//
// Neither channel is AUTHENTICATED, and the shape that matters is the INVERSE of
// the one an earlier revision of this paragraph modelled. A per-command
// `ZENSU_PROJECT_ROOT=` prefix is NOT the hazard: that name is a protected
// Session Control binding — `CONTROL_BINDINGS` in bash-source-write-parse.js —
// and pre-bash-source-write-gate.sh denies the rebind ahead of both escape
// hatches and ahead of the `bashWriteGate` enable check, with no opt-out. What is
// unauthenticated is the ORDINARY case: this script runs as a plain subprocess,
// so whatever environment its parent handed it is what gets compared, and a stale
// or hand-set value produces a confident answer about a root the gate never saw.
// No privilege is gained either way; the line is only as trustworthy as that
// environment, which is why SKILL.md keeps "the authoritative check is yours" as
// the operative instruction.
//
// The fail-safe direction is DENIED. When no channel resolves, `covered` is null
// and every renderer presents it as unknown-assume-denied — answering "writable"
// off a measurement that was never taken is the one wrong answer. In an ordinary
// subprocess neither variable is normally present, so `unknown` is the expected
// reading and the routing advice below it is what carries the value.
function writeAnchor(targetWt) {
  // Absolute-only, and the winner is carried verbatim — see the header above for
  // why each half is load-bearing. The rationale lives THERE rather than here
  // because W3b extracts this body and greps it, so naming the rejected
  // derivation inside the function would trip the pin that proves it is absent.
  //
  // A channel that was PRESENT but unusable is reported as `rejected:<name>`, never
  // collapsed into `unknown`. The two states look identical to a reader otherwise,
  // and they call for opposite actions: `unknown` means nothing was set, while
  // `rejected` means the operator set something the comparison cannot use. Both
  // still yield `covered: null` — the distinction is provenance, not verdict.
  const candidates = [
    ['env:ZENSU_PROJECT_ROOT', process.env.ZENSU_PROJECT_ROOT],
    ['env:CLAUDE_PROJECT_DIR', process.env.CLAUDE_PROJECT_DIR]
  ];
  const present = ([, v]) => Boolean(v) && String(v).trim() !== '';
  const fromEnv = candidates.find(([, v]) => present([, v]) && path.isAbsolute(String(v)));
  // KNOWN LIMIT, stated rather than implied: `rejected` reaches the reader only when
  // NO channel resolved, because `source` is its single consumer and a winner takes
  // precedence there. So `ZENSU_PROJECT_ROOT` set to a relative path while an
  // absolute `CLAUDE_PROJECT_DIR` resolves is reported as the ordinary weak-channel
  // case, and the operator is not told the authoritative variable they set was
  // refused. Surfacing it needs a second return field and a render line; that is a
  // shape change, and `W11_REL_FALLBACK` pins the current answer.
  const rejected = candidates.find((c) => present(c) && !path.isAbsolute(String(c[1])));
  const callerRoot = fromEnv ? String(fromEnv[1]) : null;
  const source = fromEnv ? fromEnv[0] : (rejected ? `rejected:${rejected[0]}` : 'unknown');
  // Absolute-only on the TARGET side too — see the header for why, and note that
  // the rationale has to live THERE: W3b greps this body for the name of the
  // rejected derivation, so spelling it here trips the pin that proves it absent.
  const targetRoot = (targetWt && path.isAbsolute(String(targetWt))) ? String(targetWt) : null;
  if (!callerRoot || !targetRoot) return { callerRoot, targetRoot: targetWt || null, covered: null, source };
  // No local fallback when the gate module did not load. A hand-rolled copy here
  // is exactly what this seam removed, and answering off a weaker rule than the
  // gate's would be a confident verdict measured with the wrong instrument.
  if (!GATE) return { callerRoot, targetRoot, covered: null, source: 'rejected:gate-unavailable' };
  const [callerCanon, targetCanon] = canonicalPair(callerRoot, targetRoot);
  const contained = GATE.within(callerCanon, targetCanon);
  // The two channels are NOT equally authoritative, and only one direction of the
  // weaker one is sound. `claude-hook-session-v1.js` reads CLAUDE_PROJECT_DIR only
  // as the last resort when no Session Control record exists — its own header says
  // "The mutable payload cwd is never a project authority" — while the record's
  // `projectRoot` is what it exports as ZENSU_PROJECT_ROOT, and THAT is the value
  // the gate compares. For a session started in a subdirectory the ambient variable
  // is the WIDER root. Containment in a wider root does not imply containment in the
  // narrower one, so `allowed` off this channel is unsound; NON-containment in the
  // wider root does imply it, so `denied here` stays sound. Downgrade exactly the
  // unsound half — discarding the true answer as well would cost a real diagnosis to
  // remove a false one. The downgrade travels in `covered`, not only in the render,
  // so a `--json` consumer reading that field alone is not misled either; `source`
  // and `callerRoot` still report what was measured, which keeps it auditable.
  const covered = (contained && source === 'env:CLAUDE_PROJECT_DIR') ? null : contained;
  return { callerRoot, targetRoot, covered, source };
}

// Rendered as its own block rather than folded into the TAKEOVER advice, because
// it is a SECOND and independent hazard attached to the same go/no-go: the
// verdict measures whether a human is still typing in that window, this measures
// whether this session may write there at all. Both roots are bounded like every
// other path in this renderer, through `flatPath` — the newline that would
// fabricate a line directly under a verdict is removed, and the spelling is left
// otherwise EXACT because SKILL.md flow 3 tells the reader to compare this root
// against the WORKTREE line above it.
function writesLines(w) {
  // `allowed` carries its own caveat, because the header above enumerates three
  // narrowings and TWO of them err in exactly this direction: rule (A) can still
  // refuse an in-anchor raw shell overwrite of tracked source, and this helper
  // realpaths BOTH sides while the gate realpaths only its comparison roots and
  // resolves a `cd` operand lexically. Leaving this branch as one bare sentence
  // applied the design's fail-safe to the `null` case and dropped it on the only
  // case that can send a reader confidently into a deny.
  if (w.covered === true) {
    return [
      'WRITES   allowed — the target worktree is inside this session\'s anchor.',
      '         Necessary, not sufficient: rule (A) can still refuse a raw shell',
      '         overwrite of tracked source, and a spelling that reaches the anchor',
      '         only through a symlink is judged outside by the gate\'s own test.'
    ];
  }
  const target = flatPath(w.targetRoot) || '(unknown)';
  // Name the reason rather than echoing `source`, which is the literal string
  // "unknown" in the case this branch exists for — "was not measured (unknown)"
  // tells a reader nothing they can act on. The reason is computed INSIDE the
  // branch that renders it, so the head and the reason cannot disagree.
  //
  // Each arm keys on the condition that actually produced the null, never on a
  // proxy for it: an earlier spelling keyed the missing-target arm on `callerRoot`
  // being truthy, which stopped being equivalent the moment a second way to reach
  // null existed. The arms in order: no recorded worktree (defensive only —
  // `buildIndex` skips a row with no cwd and falls back to it otherwise, so `r.wt`
  // is never falsy and no behavioral fixture can reach it; do not write one), then
  // the weak channel, then the ordinary no-channel case. The weak-channel arm MUST
  // name the variable: a reader who exported it deserves to learn why a value that
  // was present did not settle the question, instead of reading this as the plain
  // "nothing was set" answer.
  // One literal for both the test and the slice. Testing `rejected:` while slicing
  // `rejected:env:` works only while every channel label starts `env:`; a future
  // `rejected:file:X` would satisfy the guard and then lose four characters of its
  // own name, naming a variable that does not exist.
  const REJECTED_PREFIX = 'rejected:env:';
  // Bounded at its definition even though `source` is minted from a closed set of
  // module literals. It reaches a rendered line, and the roster that scans this
  // function has to account for every carrier here — accounting for it as "safe by
  // provenance" would be one more claim to keep true across a change to
  // `writeAnchor`; one `flatPath` call is cheaper than that promise.
  const rejectedChannel = String(w.source || '').startsWith(REJECTED_PREFIX)
    ? flatPath(String(w.source).slice(REJECTED_PREFIX.length))
    : null;
  const why = !w.targetRoot
    ? 'the target session has no recorded worktree'
    : rejectedChannel
      ? `${rejectedChannel} is set but is not an absolute path, so it cannot anchor the comparison`
      : w.source === 'env:CLAUDE_PROJECT_DIR'
        ? 'CLAUDE_PROJECT_DIR is this host\'s wider project directory, not the immutable root the gate compares, so containment in it settles nothing'
        : 'no ZENSU_PROJECT_ROOT or CLAUDE_PROJECT_DIR in this process — the ordinary case';
  // The deny head must not call a CLAUDE_PROJECT_DIR value "this session's anchor":
  // `writeAnchor` disclaims exactly that two dozen lines above, and this line is a
  // disclosure surface SKILL.md points the reader at.
  //
  // It must ALSO not assert that the immutable root lies inside that value. The
  // asymmetry argument — non-containment in the wider root implies non-containment
  // in the narrower one — needs ZENSU_PROJECT_ROOT to be CONTAINED BY
  // CLAUDE_PROJECT_DIR, and nothing enforces that. `claude-session-control-v1.js`
  // mints the record root once from the SessionStart cwd and REUSES it on every
  // later resume/compact, whose reported cwd its own comment says "may report a
  // descendant or external detached-worktree cwd" — so for a resumed session the
  // two can be arbitrary siblings and the implication fails in both directions.
  // The deny is KEPT, because it is the one diagnosis this channel buys and its
  // failure direction is conservative, but the head now ATTRIBUTES instead of
  // concluding: a strong hint measured off the weaker channel, not a verdict about
  // a containment relation the code never took.
  const head = w.covered === false
    ? (w.source === 'env:CLAUDE_PROJECT_DIR'
      ? `WRITES   denied here (hint) — this session's CLAUDE_PROJECT_DIR is ${flatPath(w.callerRoot)}, which does not contain that worktree. That is not the immutable root the gate compares, so treat this as a strong hint rather than a verdict.`
      : `WRITES   denied here — this session is anchored to ${flatPath(w.callerRoot)}, which does not contain that worktree.`)
    : `WRITES   unknown — this session's anchor was not measured (${why}); assume denied and check yourself.`;
  return [
    head,
    `         Bash git and source writes into ${target} are refused by the Zensu`,
    '         source-write gate (rules B/C) unless that path is INSIDE this session\'s',
    '         anchor. Edits and tests still work either way; a takeover that must',
    '         COMMIT needs a session whose own anchor contains that worktree.'
  ];
}

// The shared control class, defined once so `flatPath` and `briefShellArg` cannot
// drift apart — a lockstep the suite also pins by DERIVING one from the other.
// TAB is deliberately excluded: it is ordinary in a path and moves no cursor.
// Consumed by `flatPath`, `briefPath`, `briefShellArg` and `instanceId` — extend
// this roster when a consumer is added; an enumeration that silently omits one is
// the failure this file kept paying for.
// The range excludes TAB (\u0009) and NOTHING ELSE — an earlier spelling wrote it
// as \u0000-\u0008 plus \u000b-\u001f, which silently also dropped LF (\u000a) out
// of the class and un-did the whole bound. W8/W8b caught it in one run.
// `\p{Cf}` is part of the class, not an extra pass: U+202A-U+202E and
// U+2066-U+2069 reorder a rendered line, U+200B-U+200F and U+FEFF advance nothing
// at all, and every one of them can make a path READ as a different path on the
// line SKILL.md makes authoritative. They are neutralized to a space like every
// other member, so the tampering is visible rather than silently dropped.
// `\p{Mn}`/`\p{Me}` are deliberately NOT here, and the split is the whole point
// of this class: a combining mark is an ordinary character in a real filename
// (`cafe\u0301` is how macOS spells `café`), so stripping it would REWRITE the
// spelling this bound exists to keep comparable. `instanceId` does strip them,
// because its output is a correlation token that is never compared to a path.
const CONTROL_RUN = /(?:[\u0000-\u0008\u000a-\u001f\u007f-\u009f\u2028\u2029]|\p{Cf})+/gu;

// A control-strip for paths a reader must COMPARE rather than merely read:
// `oneLine`'s clip would append an ellipsis and yield a different path, and
// collapsing every `\s+` would alter one containing consecutive spaces. This
// removes exactly what can fabricate or REWRITE a line. That is wider than the
// line breaks `\s` covers: a CSI sequence (`\x1b[1A`, `\x1b[2K`) moves the cursor
// and overwrites a row the reader already trusted, which is strictly worse than a
// `\v`. `CONTROL_RUN` is the shared class — every C0 and C1 control except TAB,
// plus U+2028/U+2029 — and ordinary spaces are deliberately NOT collapsed, which
// is what keeps the spelling comparable. Applied directly by every PLAIN-TEXT
// renderer — `show`, `list`, `limited`, `instances` and `resolve`'s
// ambiguous-candidate list — and reached by both BRIEF carriers too: `briefPath`
// and `briefShellArg` each route through it before applying their own bound. An
// earlier spelling of this note claimed the class was "never [used] by a brief",
// and that gap was the defect: the persisted artifact was the one carrier without
// it. Extend this roster when a renderer is added — an enumeration that silently
// omits a caller is the failure this file kept paying for.
function flatPath(p) {
  return String(p == null ? '' : p).replace(CONTROL_RUN, ' ');
}

// Every brief line that interpolates a transcript-derived PATH routes through
// this. `oneLine` collapses the newline that would otherwise end the bullet and
// fabricate a line of its own — including one spelled exactly like the brief's
// `--- END TAKEOVER MARKDOWN ---` marker — and the backtick swap stops a crafted
// path from closing its code span and letting the remainder render as prose
// inside a bolded advisory. The briefs are PERSISTED and read by an instance that
// need not have this skill loaded, so the bound has to live at the renderer.
//
// The `- worktree:` bullets and the other path carriers predate the write-anchor
// caution and were unbounded; they are routed through here rather than left as a
// noted gap, because the caution's own test could not otherwise distinguish "the
// new line is safe" from "the brief is safe".
//
// This bounds MARKDOWN, and nothing else. It is deliberately NOT used for EITHER
// runnable `cd` line — the takeover brief's `## How to continue` step 1 and the
// handoff brief's ```bash fence: clipping at 200 would silently yield a DIFFERENT,
// shorter path that `cd` still accepts, and swapping a backtick for an apostrophe
// does the same. In the TAKEOVER brief the `- worktree:` bullet renders the very
// same value, so a clipped operand would disagree with that bullet elsewhere in
// the same brief and a reader could not tell which spelling is real. (The handoff
// brief's bullet and its operand are deliberately different values — `r.wt` vs
// `r.cwd` — so there the harm is simply that the operand is not the path.)
// All FOUR runnable lines use `briefShellArg` — the two brief ones and the two
// `printResume` prints, which flow 3 now names as the remedy for a blocked commit.
// `CONTROL_RUN` FIRST, then `oneLine`. The two bounds are not interchangeable and
// neither subsumes the other: `oneLine` collapses `/\s+/`, and JS `\s` is only the
// line-break class plus a few spaces — it does not cover ESC, the rest of C0, DEL
// or C1. Leaving the brief on `oneLine` alone therefore let exactly the class
// `flatPath`'s header names as its whole reason for existing — a CSI sequence that
// moves the cursor and overwrites a row the reader already trusted — through on the
// carrier that matters most, since a brief is PERSISTED and opened by an instance
// that need not have this skill loaded. The clip stays, and stays SECOND, so the
// 200-char budget is measured on the text that will actually be rendered.
function briefPath(p) {
  return oneLine(String(p == null ? '' : p).replace(CONTROL_RUN, ' '), 200).replace(/`/g, "'") || '(unknown)';
}

// The FOUR carriers that must stay UNCLIPPED and be safe to paste: the takeover
// brief's `## How to continue` step 1 and the handoff brief's `## Continue this
// work` block, both inside a ```bash fence, plus `printResume`'s two `show`
// prints, which are plain terminal output. The skill tells a reader all four are
// runnable. Single-quoting is what neutralizes `$( )`, `;`, `&&` and
// `|` — the metacharacters `briefPath`'s backtick swap leaves live — and the
// POSIX `'\''` idiom closes and reopens the quote around an embedded apostrophe.
// No length clip: a shortened path is a DIFFERENT path that `cd` still accepts.
//
// The full CONTROL class is collapsed — the same `CONTROL_RUN` `flatPath` removes,
// which is wider than the line breaks alone: ESC, the rest of C0, DEL and C1 go too — and
// that is the one place exactness yields. Two reasons, one per caller: inside a
// brief, a line beginning ``` would close the fence; and `printResume`'s two
// prints are plain terminal output, where a `\v` or `\f` moves the cursor down a
// row and visually splits the `cd -- '…'` line, further down the same `show`
// output as a WORKTREE value that IS stripped. Neither is a shell-injection path — the bytes stay inside the
// quotes — but a spoofed display of a runnable line is worth the same treatment.
// No path carrying a line break could be `cd`-ed on one line anyway. Everything
// else survives verbatim — everything, that is, outside `CONTROL_RUN`.
function briefShellArg(p) {
  return `'${String(p == null ? '' : p).replace(CONTROL_RUN, ' ').replace(/'/g, "'\\''")}'`;
}

// The brief's caution is deliberately STATIC where the `show` line is measured.
// A brief is written by one session for a DIFFERENT one to open, so a verdict
// measured against the writer's anchor would be reported to a reader it was never
// about. This sentence is true for whoever opens the file, which is the same
// reason the untrusted-text warning is written into the artifact rather than left
// in the skill.
function writeAnchorCaution(wt) {
  const p = briefPath(wt);
  return `- **Before editing:** this brief describes work in \`${p}\`. A session whose own project root does not CONTAIN \`${p}\` can edit files there but cannot commit — the Zensu source-write gate refuses git writes outside the session anchor. Open this work from a session whose own anchor contains that worktree.`;
}

function nearestRepoRoot(cwd, memo) {
  if (memo.has(cwd)) return memo.get(cwd);
  let dir = cwd;
  for (let i = 0; i < 12; i++) {
    const dotGit = path.join(dir, '.git');
    let st;
    try { st = fs.statSync(dotGit); } catch { st = null; }
    if (st) {
      const root = st.isDirectory() ? dir : mainRootFromGitFile(dotGit) || dir;
      memo.set(cwd, root);
      return root;
    }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  memo.set(cwd, null);
  return null;
}

function mainRootFromGitFile(gitFile) {
  let txt;
  try { txt = fs.readFileSync(gitFile, 'utf8'); } catch { return null; }
  const m = /^gitdir:\s*(.+)$/m.exec(txt);
  if (!m) return null;
  const gitdir = m[1].trim();
  const idx = gitdir.indexOf(`${path.sep}.git${path.sep}worktrees${path.sep}`);
  if (idx === -1) return null;
  return gitdir.slice(0, idx);
}

const CCD_STORE = path.join(HOME, 'Library', 'Application Support', 'Claude', 'claude-code-sessions');
let CCD_CACHE = null;

function ccdIndex() {
  if (CCD_CACHE) return CCD_CACHE;
  const map = new Map();
  CCD_CACHE = map;
  if (!dirExists(CCD_STORE)) return map;
  const walk = (dir, depth, instance) => {
    if (depth > 3) return;
    let es;
    try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch { SKIPPED += 1; return; }
    for (const e of es) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { walk(p, depth + 1, instance || e.name); continue; }
      if (!/^local_.*\.json$/.test(e.name)) continue;
      let o;
      try { o = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
      if (!o || !o.cliSessionId) continue;
      map.set(o.cliSessionId, {
        instance: instance || '?',
        archived: o.isArchived === true,
        title: o.title || null,
        model: o.model || null,
        effort: o.effort || null,
        permissionMode: o.permissionMode || null,
        lastFocusedAt: o.lastFocusedAt || null,
      });
    }
  };
  walk(CCD_STORE, 0, null);
  return map;
}

// The desktop instance id, bounded for a FIXED-COLUMN row. `flatPath` strips the
// control class but deliberately preserves ordinary spaces, which is right for a
// path the reader must compare and wrong here: `cmdShow` appends `**ARCHIVED**`
// after this field, so a directory name padded with spaces can march itself into
// that column and impersonate a marker the reader treats as machine-derived. Two
// things are neutralized, and collapsing the padding alone is NOT enough — the
// literal `**ARCHIVED**` can sit inside the name itself. So a run of two or more
// spaces collapses (a single space is left alone, so an ordinary name renders
// exactly), and a run of asterisks is separated, which leaves the name legible
// while no longer spelling the emphasis marker `cmdShow` appends after this field.
// The zero-advance class is removed FIRST, and it is expressed as Unicode PROPERTIES
// rather than as a hand-rolled range list. That is the whole lesson of this line: an
// enumerated class was shipped once and missed the bidi-format block
// (U+202A-U+202E, U+2066-U+2069), U+034F and the variation selectors — every one of
// them zero-advance, and every one of them enough to break the asterisk run below so
// the separator never fires. A name spelled `x*<U+2069>*ARCHIVED*<U+2069>*` then
// reaches the terminal looking exactly like the marker `cmdShow` appends after this
// field, on a session that is not archived. The three categories are the zero-advance
// ones Unicode defines — format, non-spacing mark, enclosing mark — which is a
// DESCRIPTION rather than a remembered list, and that is the property that matters;
// it is not a proof of closure, and U+034F needs no separate mention because it is
// already `Mn`. `\p{Mn}` is deliberately over-broad for a display bound: it also strips
// legitimate diacritics, so two instance names differing only by combining marks
// render alike here. Both call sites use this helper, so correlation survives; only
// fidelity is spent, and that is the right way round for a column a reader trusts.
// The horizontal-space collapse is the full Zs class for the same reason, since TAB
// is deliberately outside `CONTROL_RUN` and U+1680/U+2000-U+200A pad a fixed column
// exactly as well as a plain space.
const ZERO_WIDTH = /[\p{Cf}\p{Mn}\p{Me}]/gu;
const H_SPACE_RUN = /[\u0020\u0009\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]{2,}/g;

// The 8-character SESSION-id prefix, in ONE place. `cmdList`, `cmdLimited` and
// `cmdInstances` all print it, and correlating those rows is the only thing the
// prefix is for — two spellings of one id make the field useless. It is
// `instanceId`'s bound, not `flatPath(...).slice(0, 8)`: the latter leaves the
// zero-advance class in a token a reader retypes as a selector, and a `resolve`
// prefix tier that matches on the raw id cannot find it again.
// `liveRegistry` accepts a record on `o.sessionId && o.pid` truthiness alone and
// never constrains the type, and its only filter is `process.kill(o.pid, 0)`,
// whose throw is swallowed. So `pid` is another runtime's field reaching a line
// directly above the TAKEOVER verdict — the same carrier `entrypoint` and `name`
// are bounded for. A non-integer is rendered as `?` rather than flattened,
// because a pid is a number and anything else is not a value to display.
function livePid(live) {
  const raw = live ? live.pid : null;
  return Number.isInteger(raw) && raw > 0 ? String(raw) : '?';
}

function sessionTag(value) {
  return instanceId(String(value == null ? '' : value), 8);
}

function instanceId(value, width) {
  return flatPath(value)
    .replace(ZERO_WIDTH, '')
    .replace(H_SPACE_RUN, ' ')
    .replace(/\*{2,}/g, (m) => m.split('').join(' '))
    .slice(0, width);
}

// `instanceId`, the same spelling `cmdInstances` uses for the id it prints beside
// this one — correlating those two rows is the only thing an 8-character prefix is
// for, so a divergence makes the field useless. `oneLine(x, 8)`
// was wrong twice over: it leaves ESC/C0/C1 in a row a reader trusts, and its clip
// yields `slice(0, n - 1) + '…'` — seven characters plus an ellipsis — while
// `cmdInstances` renders eight raw ones. Correlating a `list` row with an
// `instances` row is the only thing an 8-character prefix is for, so two spellings
// of one id made the field useless. `app.instance` is a DIRECTORY NAME read out of
// another application's store, which is why it needs the control bound at all.
function appTag(app) {
  if (!app) return '';
  return `${app.archived ? '[ARCHIVED] ' : ''}inst ${instanceId(app.instance, 8)}`;
}

function liveRegistry() {
  const map = new Map();
  if (!dirExists(SESSIONS)) return map;
  let regFiles;
  try { regFiles = fs.readdirSync(SESSIONS); } catch { SKIPPED += 1; return map; }
  for (const f of regFiles) {
    if (!f.endsWith('.json')) continue;
    let o;
    try { o = JSON.parse(fs.readFileSync(path.join(SESSIONS, f), 'utf8')); } catch { continue; }
    if (!o || !o.sessionId || !o.pid) continue;
    let alive = false;
    try { process.kill(o.pid, 0); alive = true; } catch (e) { alive = e && e.code === 'EPERM'; }
    if (!alive) continue;
    const prev = map.get(o.sessionId);
    if (!prev || (o.startedAt || 0) > (prev.startedAt || 0)) map.set(o.sessionId, o);
  }
  return map;
}

// Returns the text AND the two facts only this function can know: whether the
// read was complete, and where the tail segment starts inside the returned
// string. Both were previously re-derived by the caller from `size`, and one of
// those re-derivations now gates a verdict — a second truncation path added here
// would otherwise leave the caller asserting a full read it never got.
function readTranscript(file, size) {
  if (size <= FULL_READ_LIMIT) return { text: fs.readFileSync(file, 'utf8'), full: true, tailOffset: 0 };
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(HEAD_BYTES);
    fs.readSync(fd, head, 0, HEAD_BYTES, 0);
    const tail = Buffer.alloc(TAIL_BYTES);
    fs.readSync(fd, tail, 0, TAIL_BYTES, size - TAIL_BYTES);
    const headText = head.toString('utf8');
    return { text: `${headText}\n${tail.toString('utf8')}`, full: false, tailOffset: headText.length + 1 };
  } finally {
    fs.closeSync(fd);
  }
}

function lastMatch(text, re) {
  let m, last = null;
  re.lastIndex = 0;
  while ((m = re.exec(text)) !== null) last = m[1];
  return last;
}

function lastValidBranch(text) {
  const re = /"gitBranch":"((?:[^"\\]|\\.)*)"/g;
  let m;
  let last = null;
  while ((m = re.exec(text)) !== null) {
    const b = m[1];
    if (!b || b === 'HEAD') continue;
    last = b;
  }
  return last;
}

function firstMatch(text, re) {
  re.lastIndex = 0;
  const m = re.exec(text);
  return m ? m[1] : null;
}

const WT_MEMO = new Map();
function worktreeRoot(cwd) {
  if (WT_MEMO.has(cwd)) return WT_MEMO.get(cwd);
  let dir = cwd;
  for (let i = 0; i < 12; i++) {
    if (fs.existsSync(path.join(dir, '.git'))) { WT_MEMO.set(cwd, dir); return dir; }
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  WT_MEMO.set(cwd, null);
  return null;
}

function collectTyped(text, type) {
  const needle = `"type":"${type}"`;
  const out = [];
  for (const line of text.split('\n')) {
    if (line.indexOf(needle) === -1) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o && o.type === type) out.push(o);
  }
  return out;
}

function scrub(t) {
  return t
    .replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '')
    .replace(/<command-message>[\s\S]*?<\/command-message>/g, '')
    .trim();
}

const MACHINE_TAG = /^<(task-notification|local-command-stdout|local-command-out|local-command-caveat|bash-input|bash-stdout|user-prompt-submit-hook|ide_|new_file_contents|function_results|tool_use_error)/;
const MACHINE_PREFIX = [
  'Base directory for this skill:',
  'Stop hook feedback:',
  'PreToolUse:',
  'PostToolUse:',
  'Caveat: The messages below were generated by the user',
];
const SLASH_TAG = /<command-name>([^<]*)<\/command-name>/;
const BARE_SLASH = /^\/[A-Za-z0-9][A-Za-z0-9:_-]{1,60}\s*$/;
const COMPACTED = 'This session is being continued from a previous conversation';

function extractPrompts(text) {
  const out = [];
  const seen = new Set();
  const push = (at, raw) => {
    let t = scrub(String(raw || ''));
    if (!t) return;
    const slash = SLASH_TAG.exec(t);
    if (slash) t = `[slash] ${slash[1].trim()}`;
    else if (BARE_SLASH.test(t)) t = `[slash] ${t.trim()}`;
    else if (t.startsWith(COMPACTED)) t = `[compaction summary] ${t.slice(COMPACTED.length).replace(/^[.\s]*/, '')}`;
    if (MACHINE_TAG.test(t)) return;
    if (MACHINE_PREFIX.some((p) => t.startsWith(p))) return;
    if (t.startsWith('[Request interrupted')) return;
    if (t.startsWith('Caveman')) return;
    const key = t.slice(0, 160);
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ at, text: t });
  };
  for (const line of text.split('\n')) {
    if (line.indexOf('"type":"queue-operation"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o && o.operation === 'enqueue') push(o.timestamp, o.content);
      continue;
    }
    if (line.indexOf('"type":"user"') === -1) continue;
    if (line.indexOf('"toolUseResult"') !== -1) continue;
    if (line.indexOf('"isSidechain":true') !== -1) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (!o || o.type !== 'user') continue;
    const c = o.message && o.message.content;
    const t = typeof c === 'string'
      ? c
      : Array.isArray(c) ? c.filter((x) => x && x.type === 'text').map((x) => x.text).join('\n') : '';
    push(o.timestamp, t);
  }
  out.sort((a, b) => String(a.at || '').localeCompare(String(b.at || '')));
  return out;
}

function extractAssistantTail(text, n) {
  const lines = text.split('\n');
  const out = [];
  for (let i = lines.length - 1; i >= 0 && out.length < n; i--) {
    const line = lines[i];
    if (line.indexOf('"type":"assistant"') === -1) continue;
    if (line.indexOf('"isSidechain":true') !== -1) continue;
    if (line.indexOf('"isApiErrorMessage":true') !== -1) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    const c = o && o.message && o.message.content;
    if (!Array.isArray(c)) continue;
    const t = c.filter((x) => x && x.type === 'text').map((x) => x.text).join('\n').trim();
    if (t) out.push({ at: o.timestamp, text: t });
  }
  return out.reverse();
}

function isRealTurn(line) {
  if (line.indexOf('"isSidechain":true') !== -1) return false;
  if (line.indexOf('"isApiErrorMessage":true') !== -1) return false;
  if (line.indexOf('"type":"assistant"') !== -1) return true;
  if (line.indexOf('"type":"user"') !== -1 && line.indexOf('"toolUseResult"') === -1) return true;
  return false;
}

// `fromOffset` is the tail seam, for the same reason its two siblings take it:
// `laterTurns` — and therefore `final`, which decides STALLED vs RECOVERED and
// routes the whole usage-limit handover — is counted by walking forward from the
// error record. Across a spliced head+tail that walk crosses an unread gap, so a
// head-resident error would be graded against tail records that are not its
// successors. Scanning the tail slice alone keeps the count over contiguous text;
// an error that falls outside it is simply not reported, which is the honest
// answer for a read that never saw it.
function extractStopCause(text, fromOffset = 0) {
  if (fromOffset > 0) return extractStopCauseIn(text.slice(fromOffset));
  return extractStopCauseIn(text);
}

function extractStopCauseIn(text) {
  if (text.indexOf('"isApiErrorMessage":true') === -1) return null;
  const lines = text.split('\n');
  let errIdx = -1;
  let err = null;
  for (let i = lines.length - 1; i >= 0 && errIdx === -1; i--) {
    if (lines[i].indexOf('"isApiErrorMessage":true') === -1) continue;
    let o;
    try { o = JSON.parse(lines[i]); } catch { continue; }
    if (!o || o.isApiErrorMessage !== true) continue;
    errIdx = i;
    err = o;
  }
  if (errIdx === -1) return null;
  let laterTurns = 0;
  let lastTurnAt = null;
  for (let i = errIdx + 1; i < lines.length; i++) {
    if (!lines[i] || !isRealTurn(lines[i])) continue;
    laterTurns++;
    const m = /"timestamp":"([^"]+)"/.exec(lines[i]);
    if (m) lastTurnAt = m[1];
  }
  const c = err.message && err.message.content;
  const msg = typeof c === 'string'
    ? c
    : Array.isArray(c) ? c.filter((x) => x && x.type === 'text').map((x) => x.text).join(' ') : '';
  // EVERY transcript-derived field is bounded here, not just `message`.
  // Every one of them is interpolated raw into the takeover brief's `## Source`
  // block, and a JSON-parsed value can hold a real newline — so bounding only the
  // obvious one leaves the siblings able to break a line in a persisted file.
  // `resumedUntil` was the one that escaped this rule while the comment claimed
  // otherwise; count the fields below rather than trusting a number in prose.
  // A local helper rather than `oneLine`: these are short identifiers, not prose,
  // and the clip is applied without the ellipsis a truncated identifier must not carry.
  // `CONTROL_RUN` FIRST, then the whitespace collapse. `/\s+/` alone is the
  // line-break class plus Zs — it leaves ESC, the rest of C0, DEL and C1, which is
  // exactly the class that can overwrite a row above it. These five values reach
  // `show`'s STOPPED row, `limited`, and the PERSISTED takeover brief, so the weaker
  // bound was the one carrier this feature hardened everywhere except here.
  const flat = (v, n) => (v === null || v === undefined ? v : String(v).replace(CONTROL_RUN, ' ').replace(/\s+/g, ' ').trim().slice(0, n));
  return {
    error: flat(err.error, 64) || 'api_error',
    // `?? null` so the key is always present: `flat` passes `undefined` through,
    // and `JSON.stringify` would then omit these two entirely, giving a machine
    // consumer a different `stopCause` shape per record.
    status: flat(err.apiErrorStatus, 16) ?? null,
    at: flat(err.timestamp, 40) ?? null,
    message: flat(msg, 2000) || '',
    final: laterTurns === 0,
    laterTurns,
    resumedUntil: flat(lastTurnAt, 40) ?? null,
  };
}

// A stop reason travels from a third-party transcript into the verdict's reason
// string, which is printed, embedded in both briefs, and persisted outside every
// repository — so it is the one transcript-derived value here that a crafted
// record could aim at a reader. Every sibling extractor bounds its text through
// `oneLine`/`clip`; this one bounds by SHAPE instead, because the value is
// supposed to be an enum token. A value outside the shape is treated as absent,
// which resolves to "still working" — the conservative direction.
const STOP_REASON_SHAPE = /^[a-z_]{1,32}$/;

// Whether the process COULD act at all, which the transcript's file mtime cannot
// say. A completed assistant turn means it is waiting for its human. Measured on
// this machine: of 57 idle sessions 51 ended on `end_turn` or `stop_sequence`,
// and so did 4 of 10 sessions written to under three minutes ago — freshness and
// activity are different things. Anything else is treated as a turn in flight,
// including a sidechain record (a subagent is running) and an assistant record
// whose stop reason is null or absent (4 of 7320 sampled): uncertainty resolves
// towards "still working", which costs a question rather than a wrong takeover.
//
// `fromOffset` is where the caller's TAIL segment begins. On a truncated read the
// text is head+tail spliced together, so an unbounded backwards scan that found
// nothing in the tail would silently classify the session from a record at its
// START. Scanning only the tail makes that case return `unknown` instead, which
// is the honest answer: the last turn was not read.
function extractLastTurn(text, fromOffset = 0) {
  const lines = (fromOffset > 0 ? text.slice(fromOffset) : text).split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line) continue;
    if (line.indexOf('"type":"assistant"') === -1 && line.indexOf('"type":"user"') === -1) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type !== 'assistant' && o.type !== 'user') continue;
    // An API-error record is not a turn. Skipping it is what keeps a session that
    // died on a rate limit from reading as "a turn is in flight — it is working",
    // which is exactly the session the usage-limit handover exists to take over.
    // `isRealTurn` and `extractAssistantTail` carry the same skip — as a substring
    // test, which cannot tell the FIELD from the same bytes appearing inside an
    // assistant's own text. This one is checked after the parse, so there is one
    // guard rather than two, and a fixture can discriminate it.
    if (o.isApiErrorMessage === true) continue;
    const sidechain = o.isSidechain === true;
    const sr = o.message && o.message.stop_reason;
    const stopReason = typeof sr === 'string' && STOP_REASON_SHAPE.test(sr) ? sr : null;
    const awaiting = o.type === 'assistant' && !sidechain && stopReason !== null && stopReason !== 'tool_use';
    return { kind: awaiting ? 'awaiting-input' : 'in-turn', stopReason, sidechain };
  }
  return { kind: 'unknown', stopReason: null, sidechain: false };
}

// `reliable` is false when the caller only had head+tail of the transcript: the
// depth is an enqueue/dequeue BALANCE, so a dequeue sitting in the unread middle
// leaves a phantom prompt pending forever. A depth derived from a partial read is
// not evidence of anything, and a verdict must not be built on it. The parameter
// carries NO default on purpose — only the reader knows whether it got the whole
// file, and defaulting it would let a future call site assert a completeness it
// never established.
// A partial read is not uniformly blind. Counted over the WHOLE spliced text the
// depth is a balance across an unread gap and proves nothing — but counted over
// the TAIL SLICE alone it is a LOWER BOUND: an enqueue inside the slice whose
// dequeue never follows it inside that same slice is genuinely pending, because
// everything after it was read. So a positive tail-slice depth is evidence and a
// zero one still is not. Without this, every transcript past 8 MB discarded a
// real queued prompt — the one hazard that acts without its human — as "not
// evidence", and reported PROBABLY_FREE for a session about to move on its own.
function extractPendingQueue(text, reliable, tailOffset = 0) {
  if (reliable !== true && tailOffset > 0) {
    const fromTail = scanQueue(text.slice(tailOffset));
    if (fromTail.pending > 0) return { ...fromTail, reliable: true };
    return { pending: 0, last: null, at: null, reliable: false };
  }
  return { ...scanQueue(text), reliable: reliable === true };
}

function scanQueue(text) {
  if (text.indexOf('"type":"queue-operation"') === -1) return { pending: 0, last: null, at: null };
  let depth = 0;
  let last = null;
  let at = null;
  for (const line of text.split('\n')) {
    if (line.indexOf('"type":"queue-operation"') === -1) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.operation === 'enqueue') {
      depth++;
      last = String(o.content || '').trim();
      at = o.timestamp || null;
    } else if (o.operation === 'dequeue') {
      depth = Math.max(0, depth - 1);
      if (depth === 0) { last = null; at = null; }
    }
  }
  return { pending: depth, last, at };
}

// Both thresholds are re-quoted as prose in SKILL.md's "Verified gotchas" and in
// the PROBABLY_FREE / BUSY rows of its flow-3 verdict table. Changing a number
// here without changing them there leaves the model reading one rule while this
// resolves another; test-session-trail-skill.sh T24 pins the two literals.
const BUSY_IDLE_MIN = 15;
// Under this, nothing about the last record is trusted: a turn that ends between
// two reads would otherwise read as idle while its process is mid-write.
const ACTIVE_GRACE_MIN = 2;

// The verdict is a hazard report, never a permission gate — nothing here refuses
// anything, and nothing in this script enforces exclusivity, because none exists
// (no lock in the gitdir; a registry entry is a registration, not a claim).
//
// `force` and the measurement are ORTHOGONAL and stay separate fields. `level` is
// what a reader should act on; `measuredLevel` is what was actually observed and
// never changes; `authorized` says only that `--force` was on this invocation.
// Collapsing them would hide the hazard from every machine consumer the moment
// someone passed the flag.
//
// The wording is deliberately provenance, not conclusion. This script cannot see
// a user: `--force` is a token its caller types, so "the user authorized this" is
// a claim it has no evidence for — and that sentence gets persisted into briefs
// which tell the next instance never to ask again.
function activityVerdict(r, force = false) {
  const v = measuredVerdict(r);
  // The flag alone is not enough: the row must BE the one a selector resolved.
  // That is what makes the survey rule structural — a command that resolves no
  // selector cannot authorize any row, whatever it passes, so a future
  // selector-less command cannot reintroduce the machine-wide stamp by calling
  // the wrong helper.
  const selected = SELECTED_SESSION_ID !== null && r.sessionId === SELECTED_SESSION_ID;
  const base = { ...v, measuredLevel: v.level, measuredReason: v.reason, authorized: force === true && selected };
  if (v.level !== 'BUSY' || !base.authorized) return base;
  return {
    ...base,
    level: 'CONTESTED',
    reason: `${v.reason} --force was passed on this invocation, which records an authorization this script cannot verify.`,
  };
}

// A command that takes no selector cannot carry an authorization: the user
// approved ONE session, and rendering that against every busy row on the machine
// turns one go/no-go into a blanket one. The rule belongs here, at the verdict
// boundary, rather than in each renderer — applying it to the text path alone
// left `list --json --force` stamping CONTESTED on every row while the visible
// output looked correct.
function surveyVerdict(r) {
  return activityVerdict(r, false);
}

// The doctrine, with ONE owner. It was hand-copied into three renderers with
// different wording and different coverage, so a level could be emitted with no
// advice attached and every check stayed green. Keyed by level; every level
// `measuredVerdict` or `activityVerdict` can emit must have an entry, which
// test-session-trail-skill.sh T18 asserts against the emitted set.
const ADVICE = {
  FREE: ['Nothing holds this worktree. Take it over.'],
  PROBABLY_FREE: ['Proceed, but tell the user not to type in that window, and check for dev servers it may still own.'],
  BUSY: [
    'This is a hazard report, not a refusal. State it to the user in one line, take a single',
    'go/no-go, and on yes re-run with --force to record the authorization and take it over.',
  ],
  CONTESTED: [
    'Authorized. Take it over, name the window the user must not type in, and check whether',
    'it still owns dev servers or ports.',
  ],
};

function measuredVerdict(r) {
  // FLOOR, not round: `Math.round` crosses each threshold half a minute early —
  // a transcript touched 95 s ago rounded to 2 and escaped the 2-minute grace
  // window the docs promise, and 14 min 30 s rounded to 15 and read as "silent
  // ≥15 min". An age is only past a threshold once it has actually passed it.
  const idleMin = Math.floor((Date.now() - r.mtime) / 60000);
  const q = r.queue || { pending: 0, at: null, reliable: false };
  const turn = r.lastTurn || { kind: 'unknown', stopReason: null };
  const qAt = q.at ? Date.parse(q.at) : NaN;
  // An unreadable enqueue timestamp counts as fresh: a real queued prompt is a
  // genuine hazard, and over-reporting it now costs one question, not a refusal.
  const queueFresh = !Number.isFinite(qAt) || (Date.now() - qAt) / 60000 < BUSY_IDLE_MIN;
  // `q.reliable === true` is DEFENCE IN DEPTH and currently unreachable as a
  // discriminator: since the tail-slice change, `extractPendingQueue` only ever
  // reports a positive depth it can stand behind, so `pending > 0` already
  // implies it. A mutation probe confirmed no fixture bites this conjunct — it is
  // kept rather than removed so a future change to that reader cannot silently
  // reopen the phantom-queue BUSY, and it is documented rather than left looking
  // like a tested guarantee.
  const queueCounts = q.pending > 0 && q.reliable === true && queueFresh;
  // "Nothing is queued" is a positive claim, so it may only be made from a read
  // that could have SEEN a queue. An unreliable read reports its own blindness
  // instead — including when the depth came back zero, which on a partial read
  // means nothing at all.
  let queueNote = q.reliable === true
    ? ' Nothing is queued.'
    : ' Its queue could not be measured — the transcript was read head+tail only.';
  if (q.pending > 0 && !queueCounts) {
    queueNote = q.reliable === true
      ? ` Its recorded queue depth of ${q.pending} last grew ${ago(qAt)} ago — a stale balance, not a waiting prompt.`
      : ` Its recorded queue depth of ${q.pending} comes from a partial head+tail transcript read, so it is not evidence.`;
  }
  if (r.app && r.app.archived) {
    // This branch runs BEFORE the liveness check, so `r.live` can still be set —
    // asserting "its process was stopped" there contradicts the STATUS line
    // printed directly above it, and both end up in the same persisted brief.
    return {
      level: 'FREE',
      idleMin,
      reason: r.live
        ? `the desktop app archived this session, though pid ${livePid(r.live)} is still registered and alive`
        : 'the desktop app archived this session — its process was stopped',
    };
  }
  if (!r.live) {
    return { level: 'FREE', idleMin, reason: 'no live process holds this worktree' };
  }
  if (queueCounts) {
    // `queueFresh` is true for an unparseable timestamp, so this branch is
    // reachable with qAt === NaN; `ago(NaN)` would render a bare "?".
    const when = Number.isFinite(qAt) ? `, last enqueued ${ago(qAt)} ago,` : ' (enqueue time not recorded)';
    return { level: 'BUSY', idleMin, reason: `pid ${livePid(r.live)} has ${q.pending} prompt(s) queued${when} and will act on its own.` };
  }
  if (idleMin < ACTIVE_GRACE_MIN) {
    return { level: 'BUSY', idleMin, reason: `pid ${livePid(r.live)} wrote to its transcript ${idleMin} min ago — too recent to judge, its turn may still be streaming.` };
  }
  if (turn.kind === 'awaiting-input') {
    return {
      level: 'PROBABLY_FREE',
      idleMin,
      reason: `pid ${livePid(r.live)} ended its last turn (${turn.stopReason}) ${ago(r.mtime)} ago, so it cannot act unless the user types in that window.${queueNote}`,
    };
  }
  if (idleMin < BUSY_IDLE_MIN) {
    // `unknown` is not `in-turn`: no last record was identified, so naming one
    // would assert a measurement that was never taken.
    const why = turn.kind === 'in-turn'
      ? 'and its last record is a turn in flight — it is working.'
      : 'and no assistant or user record could be read from it, so its state is unmeasured.';
    return { level: 'BUSY', idleMin, reason: `pid ${livePid(r.live)} wrote to its transcript ${idleMin} min ago ${why}` };
  }
  // `awaiting-input` returned above, so this is `in-turn` or `unknown`. Only the
  // second justifies "it cannot act unless the user types": a turn in flight that
  // has gone quiet for hours may still be blocked on a long tool call, and that
  // DOES act without its human when it returns.
  const silent = `pid ${livePid(r.live)} is alive but has been silent for ${ago(r.mtime)}`;
  return {
    level: 'PROBABLY_FREE',
    idleMin,
    reason: turn.kind === 'in-turn'
      ? `${silent}, and its last record is a turn in flight — most likely abandoned, but it could still be blocked on something that returns.${queueNote}`
      : `${silent} — it cannot act unless the user types in that window.${queueNote}`,
  };
}

function extractTasks(text) {
  if (text.indexOf('"name":"TaskCreate"') === -1) return [];
  const byToolUse = new Map();
  const tasks = new Map();
  const status = new Map();
  for (const line of text.split('\n')) {
    if (!line) continue;
    if (line.indexOf('"name":"TaskCreate"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      const c = o && o.message && o.message.content;
      if (!Array.isArray(c)) continue;
      for (const b of c) if (b && b.type === 'tool_use' && b.name === 'TaskCreate') byToolUse.set(b.id, b.input || {});
      continue;
    }
    if (line.indexOf('"toolUseResult"') !== -1 && line.indexOf('"task"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      const t = o && o.toolUseResult && o.toolUseResult.task;
      if (!t || !t.id) continue;
      const c = o.message && o.message.content;
      const tr = Array.isArray(c) ? c.find((x) => x && x.type === 'tool_result') : null;
      const input = tr && byToolUse.get(tr.tool_use_id);
      tasks.set(String(t.id), {
        id: String(t.id),
        subject: t.subject || (input && input.subject) || '(untitled)',
        description: (input && input.description) || '',
      });
      continue;
    }
    if (line.indexOf('"name":"TaskUpdate"') !== -1) {
      let o; try { o = JSON.parse(line); } catch { continue; }
      const c = o && o.message && o.message.content;
      if (!Array.isArray(c)) continue;
      for (const b of c) {
        if (b && b.type === 'tool_use' && b.name === 'TaskUpdate' && b.input && b.input.taskId) {
          status.set(String(b.input.taskId), b.input.status || 'unknown');
        }
      }
    }
  }
  return [...tasks.values()]
    .map((t) => ({ ...t, status: status.get(t.id) || 'pending' }))
    .sort((a, b) => Number(a.id) - Number(b.id));
}

function extractCompaction(text, limit) {
  const marker = 'This session is being continued from a previous conversation';
  if (text.indexOf(marker) === -1) return null;
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].indexOf(marker) === -1) continue;
    let o; try { o = JSON.parse(lines[i]); } catch { continue; }
    const c = o && o.message && o.message.content;
    const t = typeof c === 'string'
      ? c
      : Array.isArray(c) ? c.filter((x) => x && x.type === 'text').map((x) => x.text).join('\n') : '';
    if (!t || t.indexOf(marker) === -1) continue;
    const clean = scrub(t);
    return { at: o.timestamp || null, text: clean.length > limit ? `${clean.slice(0, limit)}\n…[truncated]` : clean };
  }
  return null;
}

function extractTouchedFiles(text, limit) {
  const re = /"file_path":"((?:[^"\\]|\\.)*)"/g;
  const counts = new Map();
  let m;
  while ((m = re.exec(text)) !== null) {
    let p;
    try { p = JSON.parse(`"${m[1]}"`); } catch { continue; }
    counts.set(p, (counts.get(p) || 0) + 1);
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit).map(([p, n]) => ({ path: p, hits: n }));
}

// A pull-request record is transcript-derived, and both of its fields end up
// somewhere a shape matters: the URL as a markdown link target in two persisted
// briefs, the number in a command line the user is told to run. Anything that
// does not match is dropped rather than rendered — a missing PR row is a smaller
// loss than a link nobody chose.
const PR_URL_SHAPE = /^https:\/\/[A-Za-z0-9._-]+\/[A-Za-z0-9._\-/]+\/(?:pull|merge_requests|-\/merge_requests)\/\d{1,9}$/;
function safePr(rec) {
  const number = String(rec.prNumber ?? '');
  const url = String(rec.prUrl ?? '');
  if (!/^\d{1,9}$/.test(number) || !PR_URL_SHAPE.test(url)) return null;
  return { number, url, repository: oneLine(String(rec.prRepository ?? ''), 120) || null };
}

function summarize(file, size, deep) {
  const read = readTranscript(file, size);
  const text = read.text;
  const cwd = firstMatch(text, /"cwd":"((?:[^"\\]|\\.)*)"/g);
  const cwdLast = lastMatch(text, /"cwd":"((?:[^"\\]|\\.)*)"/g);
  const branch = lastValidBranch(text);
  const lastTs = lastMatch(text, /"timestamp":"([^"]+)"/g);
  const titles = collectTyped(text, 'custom-title');
  const prs = collectTyped(text, 'pr-link');
  const lastPrompts = collectTyped(text, 'last-prompt');
  const modes = collectTyped(text, 'mode');
  const out = {
    cwd: cwd ? unescapeJson(cwd) : null,
    cwdLast: cwdLast ? unescapeJson(cwdLast) : null,
    branch: branch ? unescapeJson(branch) : null,
    lastActivity: lastTs,
    title: titles.length ? titles[titles.length - 1].customTitle : null,
    lastPrompt: lastPrompts.length ? lastPrompts[lastPrompts.length - 1].lastPrompt : null,
    mode: modes.length ? modes[modes.length - 1].mode : null,
    // Bounded at the source like every other transcript-derived value. The URL is
    // rendered as a markdown LINK TARGET inside both persisted briefs, in the
    // block a reader treats as machine-derived provenance, and the number reaches
    // a printed command line — so both are shape-checked rather than trusted.
    pr: prs.length ? safePr(prs[prs.length - 1]) : null,
    truncated: !read.full,
    stopCause: extractStopCause(text, read.tailOffset),
    queue: extractPendingQueue(text, read.full, read.tailOffset),
    lastTurn: extractLastTurn(text, read.tailOffset),
  };
  if (deep) {
    out.prompts = extractPrompts(text);
    out.assistantTail = extractAssistantTail(text, 3);
    out.touched = extractTouchedFiles(text, 25);
    out.tasks = extractTasks(text);
    out.compaction = extractCompaction(text, 8000);
  }
  return out;
}

function unescapeJson(s) {
  try { return JSON.parse(`"${s}"`); } catch { return s; }
}

function gitState(cwd, full) {
  if (!dirExists(cwd)) return null;
  const branch = git(cwd, ['rev-parse', '--abbrev-ref', 'HEAD']);
  const porcelain = git(cwd, ['status', '--porcelain']) || '';
  const dirtyFiles = porcelain.split('\n').filter(Boolean);
  const base = detectBase(cwd);
  let ahead = null, behind = null;
  if (base) {
    const c = git(cwd, ['rev-list', '--left-right', '--count', `${base}...HEAD`]);
    if (c) {
      const parts = c.split(/\s+/);
      behind = Number(parts[0]);
      ahead = Number(parts[1]);
    }
  }
  const state = { branch, base, ahead, behind, dirty: dirtyFiles.length, dirtyFiles: dirtyFiles.slice(0, 25) };
  if (full) {
    state.head = git(cwd, ['rev-parse', '--short', 'HEAD']);
    state.headSubject = git(cwd, ['log', '-1', '--pretty=%s']);
    state.headWhen = git(cwd, ['log', '-1', '--pretty=%cI']);
    state.commits = base ? (git(cwd, ['log', '--oneline', '--no-decorate', `${base}..HEAD`]) || '').split('\n').filter(Boolean).slice(0, 30) : [];
    state.diffstat = base ? (git(cwd, ['diff', '--stat', `${base}...HEAD`]) || '').split('\n').filter(Boolean).slice(-30) : [];
  }
  return state;
}

function detectBase(cwd) {
  const r = git(cwd, ['symbolic-ref', '--quiet', 'refs/remotes/origin/HEAD']);
  if (r) return r.replace('refs/remotes/', '');
  for (const cand of ['origin/main', 'origin/master', 'main', 'master']) {
    if (git(cwd, ['rev-parse', '--verify', '--quiet', cand])) return cand;
  }
  return null;
}

function buildIndex(opts) {
  const live = liveRegistry();
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  if (!opts.all && !ctx) fail('not inside a git repository — use --all or --repo <path>');
  const prefix = ctx ? normSlug(ctx.root) : null;
  const cutoff = opts.days > 0 ? Date.now() - opts.days * 86400000 : 0;
  const rows = [];
  if (!dirExists(PROJECTS)) return { rows, ctx, live };
  let projectDirs;
  try { projectDirs = fs.readdirSync(PROJECTS); } catch { SKIPPED += 1; return { rows, ctx, live }; }
  for (const dir of projectDirs) {
    if (prefix && !dir.startsWith(prefix)) continue;
    const full = path.join(PROJECTS, dir);
    let st;
    try { st = fs.statSync(full); } catch { continue; }
    if (!st.isDirectory()) continue;
    let entries;
    try { entries = fs.readdirSync(full); } catch { SKIPPED += 1; continue; }
    for (const f of entries) {
      if (!f.endsWith('.jsonl')) continue;
      const file = path.join(full, f);
      let fst;
      try { fst = fs.statSync(file); } catch { continue; }
      const sessionId = f.replace(/\.jsonl$/, '');
      const isLive = live.has(sessionId);
      if (!isLive && cutoff && fst.mtimeMs < cutoff) continue;
      if (fst.size < 200) continue;
      let s;
      try { s = summarize(file, fst.size, false); } catch { SKIPPED += 1; continue; }
      // The registry half is TYPED, because it comes from another process's
      // `~/.claude/sessions/*.json` and `liveRegistry` accepts any record carrying a
      // `sessionId` and a `pid`. An object or a number there reaches `worktreeRoot`
      // and `path.basename` and takes the whole command down with an uncaught
      // TypeError, instead of the SKIPPED accounting this script is built around —
      // and the `cwd` repair is what made that value newly reachable in a runnable
      // `cd` line. `cmdInstances` already guards the same field this way.
      const registryCwd = (live.get(sessionId) || {}).cwd;
      const cwd = s.cwd || (typeof registryCwd === 'string' && registryCwd ? registryCwd : null) || null;
      if (!cwd) continue;
      if (ctx && !inRepo(cwd, ctx)) continue;
      const wt = (dirExists(cwd) && worktreeRoot(cwd)) || cwd;
      const app = ccdIndex().get(sessionId) || null;
      const row = {
        sessionId,
        transcript: file,
        transcriptDir: dir,
        size: fst.size,
        mtime: fst.mtimeMs,
        wt,
        cwdExists: dirExists(cwd),
        worktree: path.basename(wt),
        live: isLive ? live.get(sessionId) : null,
        ...s,
        // AFTER the spread, deliberately. `summarize()` ALWAYS emits a `cwd` key,
        // and it is null for exactly the rows the live-registry fallback above
        // exists to serve — a live session whose transcript carries no `"cwd":"…"`
        // match. Placed before `...s` the fallback value was written and then
        // immediately overwritten with that null, so `r.cwd` came back empty for a
        // session whose working directory the registry knew perfectly well. `r.wt`
        // hid it: that one is computed before this literal and `summarize` has no
        // `wt` key, so every worktree-shaped carrier looked correct while
        // `printResume` rendered `cd -- ''` and `cmdHandoff` called
        // `path.basename(null)`.
        cwd,
        app,
      };
      if (!row.title && app && app.title) row.title = app.title;
      rows.push(row);
    }
  }
  rows.sort((a, b) => b.mtime - a.mtime);
  if (opts.live) return { rows: rows.filter((r) => r.live), ctx, live };
  return { rows, ctx, live };
}

function inRepo(cwd, ctx) {
  if (ctx.worktrees.has(cwd)) return true;
  // Normalised before comparing: this cwd is read out of another session's
  // transcript, and `/repo/../elsewhere` satisfies a raw `startsWith('/repo/')`
  // — which would fold an out-of-scope row into a listing the user asked to be
  // repo-scoped, and run a git subprocess in that directory on the way.
  const c = path.resolve(cwd);
  return c === ctx.root || c.startsWith(`${ctx.root}${path.sep}`);
}

function ago(ms) {
  if (!ms) return '?';
  const d = Math.max(0, Date.now() - ms);
  const m = Math.floor(d / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

function statusOf(r) {
  if (r.live) return 'LIVE';
  if (!r.cwdExists) return 'GONE';
  return 'IDLE';
}

function rel(p, base) {
  return base && p.startsWith(`${base}${path.sep}`) ? p.slice(base.length + 1) : p;
}

function oneLine(s, n) {
  if (!s) return '';
  const t = String(s).replace(/\s+/g, ' ').trim();
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
}

function cmdList(opts) {
  const { rows: base, ctx } = buildIndex(opts);
  // The verdict travels in the payload rather than being left for a consumer to
  // recompute from the `queue`/`lastTurn` inputs the rows already carry — one
  // implementation of the policy, on every carrier.
  const rows = base.map((r) => ({ ...r, takeover: surveyVerdict(r) }));
  if (opts.json) return print(JSON.stringify({ repo: ctx && ctx.root, rows, skipped: SKIPPED }, null, 2));
  const scope = ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS';
  const liveCount = rows.filter((r) => r.live).length;
  print(`SCOPE  ${scope}`);
  print(`WINDOW ${opts.days > 0 ? `${opts.days}d` : 'unbounded'}   SESSIONS ${rows.length}   LIVE ${liveCount}\n`);
  if (!rows.length) return print('no sessions found');
  for (const r of rows) {
    const g = opts.git ? gitState(r.wt, false) : null;
    // The branch is transcript-derived on the `!g` arm and git-derived on the
    // other; both reach a survey row that has no other bound. `show` already
    // collapses it with `oneLine(..., 120)`.
    const gitPart = g
      ? `${flatPath(g.branch) || '?'}  +${g.ahead ?? '?'}/-${g.behind ?? '?'}  dirty ${g.dirty}`
      : (flatPath(r.branch) || '?');
    const pr = r.pr ? `PR #${r.pr.number}` : 'PR —';
    // `measuredLevel`, not `level`: this command takes no selector, so rendering
    // an authorization here would show one session's approval against every busy
    // row in scope. A survey reports what was measured.
    const owner = r.live ? `pid ${livePid(r.live)} ${r.takeover.measuredLevel}` : '';
    print(`${statusOf(r).padEnd(4)}  ${sessionTag(r.sessionId)}  ${ago(r.mtime).padStart(8)} ago  ${flatPath(r.worktree)}`);
    print(`      ${gitPart}   ${pr}   ${owner}${r.app ? `   ${appTag(r.app)}` : ''}`);
    print(`      "${oneLine(flatPath(r.title || r.lastPrompt || '(untitled)'), 96)}"`);
    if (!r.cwdExists) print(`      !! worktree directory missing: ${flatPath(r.cwd)}`);
    print('');
  }
  print(`next: node ${scriptPath()} show <session-id|worktree|branch|PR#|text>`);
}

function cmdInstances(opts) {
  const live = liveRegistry();
  const rows = [...live.values()].sort((a, b) => (a.startedAt || 0) - (b.startedAt || 0));
  if (opts.json) return print(JSON.stringify({ rows, skipped: SKIPPED }, null, 2));
  const memo = new Map();
  const groups = new Map();
  for (const s of rows) {
    const hasCwd = typeof s.cwd === 'string' && s.cwd !== '';
    const root = !hasCwd ? '(cwd not recorded)'
      : dirExists(s.cwd) ? (nearestRepoRoot(s.cwd, memo) || s.cwd) : path.dirname(s.cwd);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(s);
  }
  const insts = new Set();
  for (const s of rows) { const a = ccdIndex().get(s.sessionId); if (a) insts.add(a.instance); }
  print(`LIVE CLAUDE CODE SESSIONS: ${rows.length} (every session process on this machine)`);
  print(`DESKTOP INSTANCES INVOLVED: ${insts.size}${insts.size ? ` — ${[...insts].map((i) => instanceId(i, 8)).join(', ')}` : ''}\n`);
  for (const [root, list] of [...groups.entries()].sort()) {
    print(`${flatPath(root)}  (${list.length})`);
    for (const s of list) {
      const wt = typeof s.cwd !== 'string' || s.cwd === '' ? '(cwd not recorded)'
        : s.cwd === root ? '(main checkout)' : path.relative(root, s.cwd);
      const app = ccdIndex().get(s.sessionId) || null;
      // Same store and same fields as `cmdShow`'s STATUS row, so the same bound. The
      // `s.` binding is why they were missed: a roster anchored on `r.` could not see
      // them, and these three sat unbounded one renderer away from their hardened
      // twins. The id uses the identifier spelling, so it stays comparable with the
      // one `appTag` prints on the row below.
      print(`  ${livePid(s).padStart(6)}  ${sessionTag(s.sessionId)}  ${(oneLine(flatPath(s.entrypoint), 40) || '?').padEnd(15)}  ${ago(s.startedAt).padStart(8)} old  ${flatPath(wt)}`);
      print(`          "${oneLine(flatPath(s.name), 92)}"${app ? `   ${appTag(app)}` : ''}`);
    }
    print('');
  }
}

// The one session a selector actually named. `activityVerdict` requires a row to
// BE it before `--force` can mean anything, which makes the survey rule
// structural rather than a convention about which helper each call site happens
// to call: a command that resolves no selector can never authorize a row, no
// matter what it passes.
let SELECTED_SESSION_ID = null;

function resolve(opts, selectorRaw) {
  const { rows } = buildIndex({ ...opts, live: false });
  const sel = String(selectorRaw || '').trim();
  if (!sel) fail('missing selector');
  const low = sel.toLowerCase();
  const tiers = [
    rows.filter((r) => r.sessionId === sel),
    rows.filter((r) => sel.length >= 6 && r.sessionId.startsWith(low)),
    rows.filter((r) => /^#?\d+$/.test(sel) && r.pr && String(r.pr.number) === sel.replace('#', '')),
    rows.filter((r) => r.worktree.toLowerCase() === low || r.cwd === sel),
    rows.filter((r) => (r.branch || '').toLowerCase() === low),
    rows.filter((r) => r.worktree.toLowerCase().includes(low) || (r.branch || '').toLowerCase().includes(low)),
    rows.filter((r) => `${r.title || ''} ${r.lastPrompt || ''}`.toLowerCase().includes(low)),
  ];
  const select = (row) => { SELECTED_SESSION_ID = row.sessionId; return row; };
  for (const t of tiers) {
    if (t.length === 1) return select(t[0]);
    if (t.length > 1) {
      const byWorktree = new Set(t.map((r) => r.cwd));
      if (byWorktree.size === 1) return select(t.sort((a, b) => b.mtime - a.mtime)[0]);
      print(`ambiguous selector "${sel}" — ${t.length} candidates:\n`);
      for (const r of t) print(`  ${sessionTag(r.sessionId)}  ${statusOf(r).padEnd(4)}  ${flatPath(r.worktree)}  "${oneLine(flatPath(r.title || r.lastPrompt), 70)}"`);
      flush();
      process.exit(2);
    }
  }
  // Plain text: flush() has already put the NOTE on stdout, and this stderr
  // line repeats the count deliberately, because the two say different things
  // — the NOTE says the output is short, this says the thing you asked for may
  // be what went missing. Under --json the NOTE is suppressed and this is the
  // only carrier.
  fail(`no session matched "${sel}" (try --all or --days 0)${SKIPPED ? ` — NOTE ${SKIPPED} record(s) were unreadable and skipped, the target may be one of them` : ''}`, 2);
}

// The SECOND site of the same rule as `buildIndex`'s row literal, and the reason a
// fix applied only there did not hold: this re-spreads a fresh `summarize()` over
// the row, and that object always carries a `cwd` key which is null for a session
// whose working directory only the live registry knows. A blind spread therefore
// re-introduces exactly the null `buildIndex` had already resolved. Keep the two in
// step — a row's `cwd` is whatever the deep read found, falling back to what the
// index resolved, never null-because-the-transcript-did-not-say.
function hydrate(row) {
  let st;
  try { st = fs.statSync(row.transcript); } catch { return row; }
  try {
    const s = summarize(row.transcript, st.size, true);
    // `title` for the same reason as `cwd`, and it was missed the first time:
    // `summarize` always emits the key, it is null for a transcript with no
    // custom-title record, and `buildIndex` resolves a desktop-app title one line
    // before pushing the row. Without this the app title showed in `list` and
    // `(none)` in `show`, and both briefs fell back to a directory name in their H1.
    return { ...row, ...s, cwd: s.cwd || row.cwd, title: s.title || row.title };
  } catch { SKIPPED += 1; return row; }
}

function siblings(opts, row) {
  const { rows } = buildIndex({ ...opts, live: false });
  return rows.filter((r) => r.wt === row.wt && r.sessionId !== row.sessionId);
}

function cmdShow(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = opts.git ? gitState(r.wt, true) : null;
  const v = activityVerdict(r, opts.force);
  const w = writeAnchor(r.wt);
  if (opts.json) return print(JSON.stringify({ ...r, git: g, takeover: v, writes: w, skipped: SKIPPED }, null, 2));
  print(`SESSION  ${flatPath(r.sessionId)}`);
  print(`TITLE    ${oneLine(flatPath(r.title), 200) || '(none)'}`);
  // Bounded like every other third-party value: the registry record is another
  // instance's JSON, and a newline in `name` or `entrypoint` would fabricate a
  // line directly above the TAKEOVER verdict a reader acts on.
  // Both live-registry values carry the control class: they come from another
  // process's `~/.claude/sessions/*.json`, and this row sits directly above the
  // one a reader takes the verdict from. The roster in T29 could not see them —
  // the outer interpolation opens with a compliant `statusOf(`, so a nested
  // `${...}` inside the same template is invisible to a line-anchored scan.
  print(`STATUS   ${statusOf(r)}${r.live ? `  pid ${livePid(r.live)}  ${oneLine(flatPath(r.live.entrypoint), 40)}  name "${oneLine(flatPath(r.live.name), 92)}"` : ''}`);
  if (r.app) {
    // Same bound as `appTag`, at this row's own width: the value is a directory
    // name from another application's store, and `oneLine` leaves the control class
    // that can overwrite the row above this one.
    print(`OWNER    desktop instance ${instanceId(r.app.instance, 64)}${r.app.archived ? '   **ARCHIVED** (process stopped, worktree may have been cleaned up)' : ''}`);
    print(`CONFIG   model ${oneLine(flatPath(r.app.model), 40) || '?'}   effort ${oneLine(flatPath(r.app.effort), 40) || '?'}   permissions ${oneLine(flatPath(r.app.permissionMode), 40) || '?'}`);
  }
  print(`WORKTREE ${flatPath(r.wt)}${r.cwdExists ? '' : '   !! MISSING'}`);
  if (r.cwd !== r.wt) print(`CWD      ${flatPath(r.cwd)}   (session started in a subdirectory)`);
  print(`BRANCH   ${oneLine(flatPath((g && g.branch) || r.branch), 120) || '?'}`);
  print(`LAST     ${ago(r.mtime)} ago   transcript ${flatPath(r.transcript)}`);
  if (r.pr) print(`PR       #${r.pr.number}  ${r.pr.url}`);
  if (r.stopCause && r.stopCause.final) print(`STOPPED  ${r.stopCause.error}${r.stopCause.status ? ` (${r.stopCause.status})` : ''} at ${(r.stopCause.at || '').slice(0, 16)} — "${oneLine(r.stopCause.message, 90)}"`);
  else if (r.stopCause) print(`NOTE     hit ${r.stopCause.error} at ${(r.stopCause.at || '').slice(0, 16)} but recovered (${r.stopCause.laterTurns} turns after, last ${(r.stopCause.resumedUntil || '').slice(0, 16)})`);
  if (r.truncated) print('NOTE     transcript is large — head+tail only, middle not scanned');
  const sib = siblings(opts, r);
  if (sib.length) print(`SIBLINGS ${sib.map((s) => `${flatPath(s.sessionId).slice(0, 8)}(${statusOf(s)})`).join(' ')}  — same worktree, other sessions`);
  print('');
  print(`TAKEOVER ${v.level} — ${v.reason}`);
  for (const advice of (ADVICE[v.level] || ['No advice is registered for this verdict — treat it as BUSY and ask before editing.'])) {
    print(`         ${advice}`);
  }
  for (const line of writesLines(w)) print(line);
  print('\n--- PROMPT TIMELINE ---');
  const ps = r.prompts || [];
  const shown = ps.slice(-Math.max(1, opts.prompts));
  if (ps.length > shown.length) print(`(${ps.length - shown.length} earlier prompts omitted — raise with --prompts N)`);
  // These two blocks print verbatim text from ANOTHER session directly below the
  // WRITES verdict, so the control class has to go even though the text itself stays
  // free-form. `flatPath` never lengthens a string, so no clip behaviour changes —
  // and without it a prompt beginning with a cursor-up sequence rewrites the very
  // line this feature exists to make trustworthy. The free-text carriers in the
  // BRIEFS remain a stated gap in SKILL.md; this is the terminal renderer, where
  // there is nothing to trade away.
  for (const p of shown) print(`[${oneLine(flatPath(p.at), 40).slice(0, 16)}] ${oneLine(flatPath(p.text), 300)}`);
  if (r.assistantTail && r.assistantTail.length) {
    print('\n--- LAST ASSISTANT OUTPUT ---');
    for (const a of r.assistantTail) print(`[${oneLine(flatPath(a.at), 40).slice(0, 16)}] ${oneLine(flatPath(a.text), 400)}`);
  }
  if (g) {
    print('\n--- GIT ---');
    print(`base ${g.base || '?'}   ahead ${g.ahead ?? '?'}   behind ${g.behind ?? '?'}   dirty ${g.dirty}`);
    if (g.head) print(`HEAD ${g.head} ${g.headSubject || ''} (${(g.headWhen || '').slice(0, 16)})`);
    if (g.commits && g.commits.length) { print('commits:'); for (const c of g.commits) print(`  ${c}`); }
    if (g.dirtyFiles.length) { print('uncommitted:'); for (const d of g.dirtyFiles) print(`  ${d}`); }
    if (g.diffstat && g.diffstat.length) { print('diffstat:'); for (const d of g.diffstat) print(`  ${d}`); }
  }
  if (r.touched && r.touched.length) {
    print('\n--- FILES THE SESSION TOUCHED (from transcript) ---');
    for (const t of r.touched) print(`  ${String(t.hits).padStart(3)}x  ${flatPath(rel(t.path, r.wt))}`);
  }
  print('\n--- CONTINUE ELSEWHERE ---');
  printResume(r);
}

function printResume(r) {
  print(`  cd -- ${briefShellArg(r.cwd)} && claude --resume ${briefShellArg(r.sessionId)}`);
  print(`  cd -- ${briefShellArg(r.cwd)} && claude --resume ${briefShellArg(r.sessionId)} --fork-session`);
  if (r.pr) print(`  claude --from-pr ${r.pr.number}`);
  if (!r.cwdExists) print('  # worktree missing — recreate it first: git worktree add <path> <branch>');
}

const PLAN_DIRS = ['.zensu/plans', 'docs/plans', '.claude/plans', 'plans'];

function findPlanDocs(wt, limit) {
  const out = [];
  for (const rel of PLAN_DIRS) {
    const dir = path.join(wt, rel);
    if (!dirExists(dir)) continue;
    let names;
    try { names = fs.readdirSync(dir); } catch { SKIPPED += 1; continue; }
    for (const n of names) {
      if (!n.endsWith('.md')) continue;
      const p = path.join(dir, n);
      try { out.push({ path: `${rel}/${n}`, mtime: fs.statSync(p).mtimeMs }); } catch { /* skip */ }
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime).slice(0, limit);
}

function clip(s, n) {
  const t = String(s || '').trim();
  return t.length > n ? `${t.slice(0, n)}\n…[truncated]` : t;
}

function gitDiffText(cwd, base, maxLines) {
  if (!dirExists(cwd)) return null;
  const cut = (s) => {
    if (!s) return null;
    const lines = s.split('\n');
    return lines.length > maxLines ? `${lines.slice(0, maxLines).join('\n')}\n…[${lines.length - maxLines} more lines]` : s;
  };
  return {
    uncommitted: cut(git(cwd, ['diff'])),
    staged: cut(git(cwd, ['diff', '--cached'])),
    untracked: (git(cwd, ['ls-files', '--others', '--exclude-standard']) || '').split('\n').filter(Boolean).slice(0, 40),
    branchDiff: base ? cut(git(cwd, ['diff', `${base}...HEAD`])) : null,
  };
}

function cmdLimited(opts) {
  const { rows, ctx } = buildIndex({ ...opts, live: false });
  const hit = rows.filter((r) => r.stopCause);
  const verdicted = (list) => list.map((r) => ({ ...r, takeover: surveyVerdict(r) }));
  const stalled = verdicted(hit.filter((r) => r.stopCause.final));
  const recovered = verdicted(hit.filter((r) => !r.stopCause.final));
  if (opts.json) return print(JSON.stringify({ repo: ctx && ctx.root, stalled, recovered, skipped: SKIPPED }, null, 2));
  print(`SCOPE  ${ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS'}`);
  print(`STALLED AT AN API LIMIT/ERROR: ${stalled.length}   RECOVERED AFTERWARDS: ${recovered.length}   (of ${rows.length} scanned)\n`);
  const line = (r) => {
    print(`${statusOf(r).padEnd(4)}  ${sessionTag(r.sessionId)}  ${ago(r.mtime).padStart(8)} ago  ${flatPath(r.worktree)}${r.live ? `   pid ${livePid(r.live)} ${r.takeover.measuredLevel}` : ''}`);
    print(`      cause: ${r.stopCause.error}${r.stopCause.status ? ` (${r.stopCause.status})` : ''} at ${(r.stopCause.at || '').slice(0, 16)}${r.truncated ? '   [transcript >8 MB — read head+tail only, this classification saw the tail]' : ''}`);
    if (r.app) print(`      ${appTag(r.app)}`);
    if (r.stopCause.message) print(`      "${oneLine(r.stopCause.message, 110)}"`);
    if (!r.stopCause.final) {
      print(`      RECOVERED: ${r.stopCause.laterTurns} further turn(s) after that, last at ${(r.stopCause.resumedUntil || '').slice(0, 16)} — this is NOT why it stopped`);
    }
    print(`      task:  "${oneLine(flatPath(r.title || r.lastPrompt || '(untitled)'), 96)}"`);
    print('');
  };
  if (stalled.length) {
    print('--- STALLED: the error is the last thing in the transcript ---\n');
    for (const r of stalled) line(r);
  }
  if (recovered.length) {
    print('--- RECOVERED: hit a limit earlier, then kept working. Do not treat these as dead. ---\n');
    for (const r of recovered) line(r);
  }
  if (!hit.length) return print('none found in this window — widen with --days 0 or --all');
  print(`next: node ${scriptPath()} takeover <session-id>`);
}

function cmdTakeover(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = gitState(r.wt, true);
  const d = g ? gitDiffText(r.wt, g.base, 400) : null;
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  const target = handoffPath(r, ctx, g && g.branch).replace(/\.md$/, '.takeover.md');
  const tv = activityVerdict(r, opts.force);
  // `writes` reaches the JSON branch even though the MARKDOWN branch carries only
  // the static caution. The two are different artifacts with different readers: a
  // brief is written by one session for a DIFFERENT one to open later, where a
  // measurement taken in this process says nothing about the anchor of the session
  // that will act on it — the static caution is the honest line there. `--json` is
  // read by the session that ran the command, in the process whose environment was
  // measured, so withholding the measurement made this the one single-selector
  // invocation carrying no write-anchor information at all.
  if (opts.json) return print(JSON.stringify({ ...r, git: g, diff: d, target, takeover: tv, writes: writeAnchor(r.wt), skipped: SKIPPED }, null, 2));
  const L = [];
  L.push(`# Takeover: ${briefPath(r.title || path.basename(r.wt))}`);
  L.push('');
  L.push('> Reconstructed from the source session\'s transcript on disk. That session contributed nothing to this document and did not need to be running.');
  L.push('');
  L.push('## Source');
  L.push(`- session: \`${briefPath(r.sessionId)}\` (${statusOf(r)}${r.live ? `, STILL RUNNING as pid ${livePid(r.live)}` : ''})`);
  if (r.app) L.push(`- owning desktop instance: \`${briefPath(r.app.instance)}\`${r.app.archived ? ' — **ARCHIVED**: its process was stopped and the worktree may have been cleaned up' : ''}`);
  L.push(`- takeover verdict when this brief was written: **${tv.measuredLevel}** — ${tv.measuredReason}`);
  if (tv.authorized) {
    L.push(`- an authorization was recorded at ${new Date().toISOString()} by passing \`--force\` to the command that generated this file. It is bounded to that moment and to whoever gave it — this brief cannot carry it forward, so re-measure and take the go/no-go again before editing.`);
  }
  L.push(`- worktree: \`${briefPath(r.wt)}\`${r.cwdExists ? '' : '  **MISSING**'}`);
  L.push(writeAnchorCaution(r.wt));
  L.push(`- branch: \`${briefPath((g && g.branch) || r.branch || '?')}\``);
  L.push(`- last activity: ${new Date(r.mtime).toISOString()} (${ago(r.mtime)} ago)`);
  if (r.pr) L.push(`- pull request: [#${r.pr.number}](${r.pr.url})`);
  if (r.stopCause && r.stopCause.final) {
    L.push(`- **stopped on: ${r.stopCause.error}${r.stopCause.status ? ` (HTTP ${r.stopCause.status})` : ''}** at ${r.stopCause.at || '?'}`);
    if (r.stopCause.message) L.push(`  - > ${r.stopCause.message}`);
  } else if (r.stopCause) {
    L.push(`- hit \`${r.stopCause.error}\` at ${r.stopCause.at || '?'} but **recovered** — ${r.stopCause.laterTurns} further turn(s) followed, last at ${r.stopCause.resumedUntil || '?'}. That error is not why it is idle now.`);
    if (r.stopCause.message) L.push(`  - > ${r.stopCause.message}`);
  }
  if (r.truncated) L.push('- ⚠️ transcript exceeds 8 MB — only head+tail were scanned, the middle is not represented below');
  L.push('');
  const first = (r.prompts || [])[0];
  L.push('## Original objective');
  L.push(first ? clip(first.text, 4000) : '_no user prompt found in the scanned range_');
  L.push('');
  if (r.compaction) {
    L.push(`## State at last compaction (${briefPath(r.compaction.at).slice(0, 16)})`);
    L.push(clip(r.compaction.text, 8000));
    L.push('');
  }
  const plans = r.cwdExists ? findPlanDocs(r.wt, 5) : [];
  if (plans.length) {
    const startedAt = first && first.at ? Date.parse(first.at) : null;
    const inWindow = (p) => startedAt !== null && p.mtime >= startedAt && p.mtime <= r.mtime + 60000;
    const own = plans.filter(inWindow);
    L.push('## Plan documents in the worktree');
    L.push('_Read these first — they are written plans on disk, independent of the transcript._');
    for (const p of (own.length ? own : plans.slice(0, 3))) {
      L.push(`- \`${briefPath(p.path)}\` (modified ${new Date(p.mtime).toISOString().slice(0, 16)}${inWindow(p) ? ', **touched during this session**' : ''})`);
    }
    if (!own.length) L.push('- _none of these fall inside the session\'s active window; they may belong to other work_');
    L.push('');
  }
  L.push('## Task list at the moment it stopped');
  const tasks = r.tasks || [];
  if (!tasks.length) L.push('_the session tracked no tasks_');
  for (const t of tasks) {
    L.push(`- [${briefPath(String(t.status ?? '')).slice(0, 24)}] **#${briefPath(String(t.id ?? '')).slice(0, 16)} ${briefPath(String(t.subject ?? '')).slice(0, 200)}**`);
    if (t.description) L.push(`  - ${clip(t.description, 600)}`);
  }
  const open = tasks.filter((t) => t.status !== 'completed');
  if (open.length) L.push(`\n**${open.length} task(s) not completed: ${open.map((t) => `#${briefPath(String(t.id ?? '')).slice(0, 16)}`).join(', ')}**`);
  L.push('');
  L.push('## Recent instructions (verbatim, newest last)');
  const recent = (r.prompts || []).slice(-Math.max(1, opts.prompts));
  for (const p of recent) {
    L.push(`### \`${briefPath(oneLine(p.at, 40).slice(0, 16))}\``);
    L.push(clip(p.text, 2500));
  }
  L.push('');
  L.push('## What it said last');
  for (const a of (r.assistantTail || [])) {
    L.push(`### \`${briefPath(oneLine(a.at, 40).slice(0, 16))}\``);
    L.push(clip(a.text, 6000));
  }
  L.push('');
  L.push('## Git state');
  if (!g) L.push('- worktree directory is gone; git state unavailable');
  else {
    L.push(`- base \`${g.base || '?'}\`, ahead ${g.ahead ?? '?'}, behind ${g.behind ?? '?'}, uncommitted ${g.dirty}`);
    if (g.head) L.push(`- HEAD \`${g.head}\` ${g.headSubject || ''}`);
    if (g.commits && g.commits.length) { L.push('- commits on this branch:'); for (const c of g.commits) L.push(`  - \`${c}\``); }
    if (g.dirtyFiles.length) { L.push('- uncommitted files:'); for (const x of g.dirtyFiles) L.push(`  - \`${x}\``); }
    if (d && d.untracked.length) { L.push('- untracked files:'); for (const x of d.untracked) L.push(`  - \`${x}\``); }
    if (d && d.staged) { L.push('\n### Staged diff'); L.push('```diff'); L.push(d.staged); L.push('```'); }
    if (d && d.uncommitted) { L.push('\n### Uncommitted diff'); L.push('```diff'); L.push(d.uncommitted); L.push('```'); }
  }
  L.push('');
  L.push('## Files the session touched');
  for (const t of (r.touched || [])) L.push(`- \`${briefPath(rel(t.path, r.wt))}\` (${t.hits}x)`);
  L.push('');
  L.push('## How to continue');
  // Fenced, not a code span: `briefShellArg` deliberately does NOT swap backticks
  // (that would change the path bytes, which is the whole point of this helper),
  // so a crafted path would close a single-backtick span and render the rest as
  // prose inside a numbered instruction. A fence cannot be closed from mid-line.
  L.push('1. Work in this worktree, not a fresh checkout of the branch:');
  L.push('');
  L.push('```bash');
  L.push(`cd -- ${briefShellArg(r.wt)}`);
  L.push('```');
  L.push('2. Re-verify before trusting anything above: this is a snapshot, and the working tree may have moved since.');
  L.push('3. Restate the remaining work as a short plan and get the user\'s confirmation before editing.');
  if (tv.measuredLevel === 'BUSY') L.push(`4. ⚠️ **Hazard, not a veto** — ${tv.measuredReason} State it to the user in one line and take a single go/no-go before the first edit${tv.authorized ? ' — the authorization above was given when this brief was written, not here' : '; on yes, re-run this command with `--force`'}. Then take it over; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  else if (tv.measuredLevel === 'PROBABLY_FREE') L.push(`4. ${tv.measuredReason} Taking over is fine; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  print(`TAKEOVER_TARGET: ${target}`);
  print('--- BEGIN TAKEOVER MARKDOWN ---');
  print(L.join('\n'));
  print('--- END TAKEOVER MARKDOWN ---');
}

function handoffPath(r, ctx, liveBranch) {
  const root = (r.cwdExists && nearestRepoRoot(r.wt, new Map())) || null;
  // `repo` is derived from a path this script did not choose — a `gitdir:` line in
  // a linked worktree's `.git` file, or the parent directory name under `--all`.
  // Both can spell `..`, and `path.join` would then normalise the target OUT of
  // the handoffs directory: the model is told to Write to whatever this prints.
  // Sanitising is not enough on its own, because `..` survives a character class
  // that permits dots — so the result is asserted to be inside HANDOFFS as well.
  const rawRepo = (root && path.basename(root)) || (ctx && ctx.name) || path.basename(path.dirname(r.wt));
  const safe = (s) => String(s || '').replace(/[^A-Za-z0-9._-]/g, '-');
  const repo = safe(rawRepo).replace(/^\.+$/, 'unknown-repo') || 'unknown-repo';
  const usable = (b) => (b && b !== 'HEAD' ? b : null);
  const branch = safe(usable(r.branch) || usable(liveBranch) || path.basename(r.wt)).replace(/^\.+$/, 'unknown-branch') || 'unknown-branch';
  const target = path.join(HANDOFFS, repo, `${branch}.md`);
  if (!path.resolve(target).startsWith(HANDOFFS + path.sep)) {
    fail(`refusing to name a brief target outside ${HANDOFFS}: ${target}`);
  }
  return target;
}

function cmdHandoff(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = gitState(r.wt, true);
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  const target = handoffPath(r, ctx, g && g.branch);
  const L = [];
  L.push(`# Handoff: ${briefPath(r.title || path.basename(r.cwd))}`);
  L.push('');
  L.push('## Source');
  // Hoisted out of the template: a nested interpolation is structurally invisible
  // to the raw-carrier scan, and `entrypoint` is another process's registry value.
  const liveSuffix = r.live ? `, pid ${livePid(r.live)}, ${briefPath(r.live.entrypoint)}` : '';
  L.push(`- session: \`${briefPath(r.sessionId)}\` (${statusOf(r)}${liveSuffix})`);
  L.push(`- worktree: \`${briefPath(r.wt)}\`${r.cwdExists ? '' : '  **MISSING**'}`);
  L.push(writeAnchorCaution(r.wt));
  L.push(`- branch: \`${briefPath((g && g.branch) || r.branch || '?')}\``);
  L.push(`- transcript: \`${briefPath(r.transcript)}\``);
  L.push(`- last activity: ${new Date(r.mtime).toISOString()} (${ago(r.mtime)} ago)`);
  if (r.pr) L.push(`- pull request: [#${r.pr.number}](${r.pr.url})`);
  if (r.truncated) L.push('- note: transcript large, only head+tail scanned');
  L.push('');
  L.push('## What was asked');
  const hp = r.prompts || [];
  const hpShown = hp.slice(-30);
  if (hp.length > hpShown.length) L.push(`- _(${hp.length - hpShown.length} earlier prompts omitted)_`);
  for (const p of hpShown) L.push(`- \`${briefPath(oneLine(p.at, 40).slice(0, 16))}\` ${oneLine(p.text, 400)}`);
  L.push('');
  L.push('## Git state');
  if (!g) L.push('- worktree directory is gone; git state unavailable');
  else {
    L.push(`- base \`${g.base || '?'}\`, ahead ${g.ahead ?? '?'}, behind ${g.behind ?? '?'}, uncommitted ${g.dirty}`);
    if (g.head) L.push(`- HEAD \`${g.head}\` ${g.headSubject || ''}`);
    if (g.commits && g.commits.length) { L.push('- commits on this branch:'); for (const c of g.commits) L.push(`  - \`${c}\``); }
    if (g.dirtyFiles.length) { L.push('- uncommitted changes:'); for (const d of g.dirtyFiles) L.push(`  - \`${d}\``); }
    if (g.diffstat && g.diffstat.length) { L.push('- diffstat vs base:'); L.push('```'); for (const d of g.diffstat) L.push(d); L.push('```'); }
  }
  L.push('');
  L.push('## Files the session touched');
  for (const t of (r.touched || [])) L.push(`- \`${briefPath(rel(t.path, r.wt))}\` (${t.hits}x)`);
  L.push('');
  L.push('## Open threads');
  L.push('<!-- FILL: unresolved questions, failing checks, decisions still pending -->');
  L.push('');
  L.push('## Next steps');
  L.push('<!-- FILL: concrete, ordered, executable by a fresh session with no prior context -->');
  L.push('');
  L.push('## Continue this work');
  L.push('```bash');
  L.push(`cd -- ${briefShellArg(r.cwd)} && claude --resume ${briefShellArg(r.sessionId)}`);
  L.push('```');
  if (r.live) {
    // `measuredReason`, not `reason`: a label that says "measured" must not carry
    // the authorization clause, whose "this invocation" is unresolvable in a file
    // a DIFFERENT instance reads later.
    const hv = activityVerdict(r, opts.force);
    L.push('');
    L.push(`> **Still running** in pid ${livePid(r.live)} — measured takeover verdict **${hv.measuredLevel}**: ${hv.measuredReason}`);
    if (hv.authorized) L.push(`> An authorization was recorded at ${new Date().toISOString()} by passing --force to the command that generated this file. It was bounded to that moment and to whoever gave it, and this file cannot carry it forward.`);
    L.push('> Nothing enforces exclusivity here; the hazard is a human typing in that window, not the process holding a claim.');
    L.push('> Re-measure before acting: this line is a snapshot, and any authorization behind it was bounded to the moment this file was written.');
  }
  print(`HANDOFF_TARGET: ${target}`);
  print('--- BEGIN HANDOFF MARKDOWN ---');
  print(L.join('\n'));
  print('--- END HANDOFF MARKDOWN ---');
}

let buffer = [];
function print(s) { buffer.push(s); }
// Emitted from the dispatcher, not from one command: every command path can
// increment SKIPPED, so surfacing it in cmdList alone would leave show,
// limited, takeover and handoff silently incomplete at exit 0.
// Never appended under --json: the payloads already carry a `skipped` field,
// and trailing prose would turn a degraded-but-parseable answer into a hard
// JSON.parse failure at exit 0.
function skippedNote() { return SKIPPED && !JSON_MODE ? `\nNOTE   ${SKIPPED} record(s) unreadable and skipped — this output is incomplete` : ''; }
function flush() {
  const note = skippedNote();
  if (!buffer.length && !note) return;
  process.stdout.write(`${buffer.join('\n')}${note}\n`);
  buffer = [];
}
function scriptPath() { return new URL(import.meta.url).pathname; }

const argv = process.argv.slice(2);
const opts = parseArgs(argv);
const cmd = opts._[0] || 'list';
// Keyed to whether a JSON payload is actually EMITTED, not to the flag:
// handoff ignores --json and always emits markdown, so suppressing the note
// there would drop the count on every channel at once.
JSON_MODE = opts.json && cmd !== 'handoff';
if (cmd === 'list') cmdList(opts);
else if (cmd === 'instances') cmdInstances(opts);
else if (cmd === 'show') cmdShow(opts);
else if (cmd === 'handoff') cmdHandoff(opts);
else if (cmd === 'limited') cmdLimited(opts);
else if (cmd === 'takeover') cmdTakeover(opts);
else fail(`unknown command: ${cmd} (list | instances | show | handoff | limited | takeover)`);
flush();
