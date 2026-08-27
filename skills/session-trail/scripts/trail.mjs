#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import {
  ledgerPaths, writeEdge, readEdges, dedupeEdges,
  makeEndpoint, buildEdge as buildLedgerEdge, walkChain, chainWalks,
  readLabels as readLabelsFile, updateLabels, emptyLabels, boundLabel,
  removeEdgeFiles, otherSchemaLedgers, MAX_EDGE_RECORDS, byRecordedAtAsc,
  isSafeHostSessionId, EDGE_REFUSALS, boundText,
} from './session-lineage-v1.mjs';

// Shared, never re-spelled. CLAUDE.md records `msysDrivePrefix` in
// hooks/lib/claude-path-v1.js as the ONE MSYS drive rule in this repo, and a
// second copy is exactly the drift that rule exists to prevent. It is a CommonJS
// module, so it comes in through createRequire rather than an import.
const requireFromHere = createRequire(import.meta.url);
let msysDrivePrefix = null;
try {
  ({ msysDrivePrefix } = requireFromHere('../../../hooks/lib/claude-path-v1.js'));
} catch { msysDrivePrefix = null; }

// Every externally supplied root passes through here before `path.resolve` sees
// it. The hazard is a root that reaches this process still spelled `/d/work`:
// `path.resolve` reads that leading slash as drive-RELATIVE and splices the whole
// POSIX path under the current drive, so the store is written somewhere nobody
// reads back.
//
// How likely that is, stated honestly rather than assumed. CLAUDE.md's pinned
// premise — measured for `bash-source-write-parse.js` — is that MSYS rewrites
// exported variables AND the argument vector on the way into a native binary, and
// that stdin is the one channel it never touches. `CLAUDE_CONFIG_DIR` is an
// exported variable and `--config-dir` is an argv token, so on that premise both
// arrive already native and this call is identity. It is kept as defence in depth
// for the spellings that premise does not cover — an `MSYS2_ENV_CONV_EXCL` opt-out,
// a value read from a file, a future carrier — and NOT because an unconverted root
// was observed here. Nobody has run this under Git Bash; treat the premise as the
// repo's, not as something this code measured.
//
// A missing module FAILS rather than falling back to identity: an identity
// fallback would silently restore the split namespace on the one platform the
// call exists for, and a plugin tree missing its own lib is broken anyway.
function hostPath(value) {
  if (typeof msysDrivePrefix !== 'function') {
    fail('hooks/lib/claude-path-v1.js could not be loaded, so a path cannot be normalised for this host — the plugin tree is incomplete');
  }
  return msysDrivePrefix(value);
}

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
// The config root is resolved, not hardcoded: an instance started with its own
// CLAUDE_CONFIG_DIR writes its registry, transcripts AND lineage ledger there, so
// a reader pinned to ~/.claude reports "no sessions found" for that user and — far
// worse once the ledger exists — writes edges into a root nobody reads back.
// These stay `let` because `--config-dir` is only known after parseArgs; every
// consumer is a function the dispatcher calls, so `resolveRoots()` below runs first.
// The derivation lives in ONE place: a second copy at module load would only be
// overwritten, and a root added there and forgotten here reproduces exactly the
// hazard the paragraph above describes.
let CONFIG_ROOT;
let PROJECTS;
let SESSIONS;
let HANDOFFS;
let LEDGER_DIR;
let LABELS_FILE;

function defaultConfigRoot() {
  const env = process.env.CLAUDE_CONFIG_DIR;
  if (env && env.trim()) return path.resolve(hostPath(env.trim()));
  return path.join(HOME, '.claude');
}

function resolveRoots(configDir) {
  CONFIG_ROOT = configDir && configDir.trim() ? path.resolve(hostPath(configDir.trim())) : defaultConfigRoot();
  PROJECTS = path.join(CONFIG_ROOT, 'projects');
  SESSIONS = path.join(CONFIG_ROOT, 'sessions');
  HANDOFFS = path.join(CONFIG_ROOT, 'handoffs');
  const led = ledgerPaths(CONFIG_ROOT);
  LEDGER_DIR = led.edges;
  LABELS_FILE = led.labels;
}
// NOT called at module load. It was, and `fail()` is reachable from it through
// `hostPath` — but `fail` calls `flush`, `flush` calls `skippedNote`, and that
// reads `SKIPPED` and `JSON_MODE`, both declared BELOW where the call stood. The
// carefully worded "the plugin tree is incomplete" diagnostic was therefore
// replaced by `ReferenceError: Cannot access 'SKIPPED' before initialization`, on
// exactly the path it exists for. The same hazard the note under `JSON_MODE`
// already records for `parseArgs`, one call site earlier.
//
// The call was also redundant: the dispatcher resolves every root from
// `opts.configDir` before any command runs, and no module-scope statement between
// here and there reads one.
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
  const out = {
    _: [], days: 21, prompts: 12, json: false, all: false, live: false, git: true, repo: null, force: false,
    configDir: null, where: null, diagnose: false, backfill: false, apply: false, record: true, reason: null, self: false,
    forget: null, remove: null,
    daysExplicit: false, promptsExplicit: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') out.json = true;
    else if (a === '--all') out.all = true;
    else if (a === '--force') out.force = true;
    else if (a === '--live') out.live = true;
    else if (a === '--no-git') out.git = false;
    else if (a === '--diagnose') out.diagnose = true;
    else if (a === '--backfill') out.backfill = true;
    else if (a === '--apply') out.apply = true;
    else if (a === '--no-record') out.record = false;
    // A real flag, not a positional: parseArgs rejects every unknown `--token`,
    // so reading `--self` off the positional list could never have worked.
    else if (a === '--self') out.self = true;
    else if (a === '--config-dir') out.configDir = stringOperand(a, argv[++i]);
    else if (a === '--where') out.where = stringOperand(a, argv[++i]);
    // Both take an operand rather than reading a positional: they are the two
    // destructive spellings in this file, and a positional silently swallowed from
    // a neighbouring flag would name a target the user never typed.
    else if (a === '--forget') out.forget = stringOperand(a, argv[++i]);
    else if (a === '--remove') out.remove = stringOperand(a, argv[++i]);
    else if (a === '--reason') out.reason = stringOperand(a, argv[++i]);
    // Both operands are validated. An unvalidated `--prompts` was the worse of
    // the two: `Number("--json")` is NaN, `Math.max(1, NaN)` is NaN, and
    // `slice(-NaN)` is `slice(0)` — the ENTIRE prompt history, with the
    // "(N earlier omitted)" self-report suppressed by the same NaN. The mistake
    // ran towards maximum disclosure and reported nothing.
    else if (a === '--days') { out.days = numericOperand(a, argv[++i]); out.daysExplicit = true; }
    else if (a === '--prompts') { out.prompts = numericOperand(a, argv[++i]); out.promptsExplicit = true; }
    else if (a === '--repo') out.repo = stringOperand(a, argv[++i]);
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

// Validated for the same reason numericOperand is: an operand swallowed from a
// following flag (`--where --json`) would otherwise become the value silently, and
// for --config-dir that means writing the ledger into a directory named "--json".
function stringOperand(flag, raw) {
  if (raw === undefined || raw === '' || raw.startsWith('--')) {
    fail(`${flag} needs a value (got ${raw === undefined ? 'nothing' : `"${raw}"`})`);
  }
  return raw;
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

// The LEXICAL spelling of one path: resolved and normalized, never realpathed.
// It is the operand shape the gate uses for a write target — its header states
// the asymmetry at line 35, "Only the comparison roots are canonicalized, once,
// via `canonical()`" — so an absolute token is compared in the spelling it was
// written in. The base a relative operand resolves against is canonicalized only
// where it is SEEDED FROM THE PAYLOAD CWD (parser :703); an in-command `cd`
// re-seeds it lexically (parser :1005 -> `abspath` -> `resolveFrom`, no
// `realpathSync` anywhere). Say it that narrowly: the resolved reading below
// models a writer whose SHELL cwd is already inside the target across separate
// Bash calls, not a `cd` in the same command.
function lexicalDir(p) {
  return trimDir(path.resolve(GATE ? GATE.msysToDrive(String(p), IS_WINDOWS) : String(p)));
}

// Containment, asked BOTH ways, because the gate's answer depends on how the
// writer reaches the directory and this process cannot know which they will do.
// When the target's literal and resolved spellings differ, the two readings give
// OPPOSITE answers and picking either one is a guess:
//
//   - the RESOLVED reading alone answers `allowed` for a target the gate refuses
//     when the literal spelling is the one written. That is the narrowing this
//     function's predecessor disclosed and kept; it is the one direction this
//     verdict may not be wrong in, so it is now removed rather than documented.
//   - the LITERAL reading alone answers `denied here` for a worktree the gate
//     allows the moment the reader `cd`s into it — on macOS that is every fixture
//     under `$TMPDIR`, since `/var` is itself a symlink.
//
// So both are computed and a DISAGREEMENT is reported as not-determinable.
// `GATE.within` is CALLED for each, never re-encoded, so the predicate stays the
// gate's own; only the operand shape differs between the two readings.
// Returns `true` / `false` / `null`.
// The anchor comes from the JOINT pair, which is what keeps this consistent with
// `canonicalPair`'s all-or-nothing rule: when either side cannot be realpathed
// both operands stay lexical, the two readings below coincide, and the answer is
// definite. The dual reading therefore engages exactly where both paths exist and
// the target's spelling actually resolves elsewhere.
function containment(callerRoot, targetRoot) {
  if (!GATE) return null;
  const [anchor, targetCanon] = canonicalPair(callerRoot, targetRoot);
  const literal = GATE.within(anchor, lexicalDir(targetRoot));
  const resolved = GATE.within(anchor, targetCanon);
  return literal === resolved ? literal : null;
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
// TWO narrowings, stated rather than hidden, and they do NOT share a direction.
// Rule (C) also exempts a target under a temp root (`isTemp`), so a worktree in
// `/tmp` is writable while this reports it covered=false. That one errs toward
// WARNING, which is the safe direction for a line whose remedy is "start a session
// over there". The second errs toward `allowed`, which is why it is written down:
// rule (A) can still deny an in-anchor raw shell overwrite of tracked source,
// which this never reports — and it fires on an IN-ANCHOR target, precisely where
// this answers `allowed`.
//
// A THIRD narrowing used to sit here and is GONE rather than merely unlikely.
// Canonicalizing both sides through `realpathSync` answered covered=true for a
// target whose literal spelling escapes the anchor but whose realpath lands
// inside — a confident `allowed` for a write the gate refuses, in the one
// direction this verdict may not be wrong in. `containment` now computes the
// literal and the resolved reading and reports a DISAGREEMENT as
// not-determinable, so symlink tolerance is kept everywhere the two agree and
// given up only where they cannot both be right.
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
  // TRUST is carried as DATA, not inferred from the display label. It used to be a
  // hardcoded `=== 'env:CLAUDE_PROJECT_DIR'` comparison at the soundness downgrade
  // and a second one at the deny-head attribution, with nothing holding the pair
  // together: adding a third weak channel meant remembering two independent edits,
  // and the failure direction at the downgrade is the false `allowed` this feature
  // may never produce. Renaming a label was already pinned; ADDING one was not.
  const candidates = [
    { label: 'env:ZENSU_PROJECT_ROOT', value: process.env.ZENSU_PROJECT_ROOT, trusted: true },
    { label: 'env:CLAUDE_PROJECT_DIR', value: process.env.CLAUDE_PROJECT_DIR, trusted: false }
  ];
  const present = (c) => Boolean(c.value) && String(c.value).trim() !== '';
  const fromEnv = candidates.find((c) => present(c) && path.isAbsolute(String(c.value)));
  // KNOWN LIMIT, stated rather than implied: `rejected` reaches the reader only when
  // NO channel resolved, because `source` is its single consumer and a winner takes
  // precedence there. So `ZENSU_PROJECT_ROOT` set to a relative path while an
  // absolute `CLAUDE_PROJECT_DIR` resolves is reported as the ordinary weak-channel
  // case, and the operator is not told the authoritative variable they set was
  // refused. Surfacing it needs a second return field and a render line; that is a
  // shape change, and `W11_REL_FALLBACK` pins the current answer.
  const rejected = candidates.find((c) => present(c) && !path.isAbsolute(String(c.value)));
  const callerRoot = fromEnv ? String(fromEnv.value) : null;
  const source = fromEnv ? fromEnv.label : (rejected ? `rejected:${rejected.label}` : 'unknown');
  // Absolute-only on the TARGET side too — see the header for why, and note that
  // the rationale has to live THERE: W3b greps this body for the name of the
  // rejected derivation, so spelling it here trips the pin that proves it absent.
  const targetRoot = (targetWt && path.isAbsolute(String(targetWt))) ? String(targetWt) : null;
  // The REASON is decided HERE, beside the measurement that produced it, and both
  // halves are returned. `reasonCode` is the BRANCHABLE one — a closed set — and
  // `reason` is the human sentence the rendered line reuses. Sending a machine
  // consumer to free-text prose would make it substring-match a sentence this
  // renderer is free to reword, which is the `source`-as-grammar problem one level
  // up and strictly worse, since `source` at least has a closed, pinned domain.
  const rejectedChannel = rejected ? String(rejected.label).replace(/^env:/, '') : null;
  if (!callerRoot) {
    return {
      callerRoot,
      targetRoot: targetWt || null,
      covered: null,
      source,
      sourceTrusted: null,
      reasonCode: rejectedChannel ? 'channel-not-absolute' : 'no-channel',
      reason: rejectedChannel
        ? `${rejectedChannel} is set but is not an absolute path, so it cannot anchor the comparison`
        : 'no ZENSU_PROJECT_ROOT or CLAUDE_PROJECT_DIR in this process — the ordinary case',
    };
  }
  if (!targetRoot) {
    return {
      callerRoot,
      targetRoot: targetWt || null,
      covered: null,
      source,
      sourceTrusted: fromEnv.trusted,
      reasonCode: targetWt ? 'target-not-absolute' : 'target-absent',
      reason: targetWt
        ? 'the target session\'s recorded worktree is not an absolute path, so it cannot anchor the comparison either'
        : 'the target session has no recorded worktree',
    };
  }
  // No local fallback when the gate module did not load. A hand-rolled copy here
  // is exactly what this seam removed, and answering off a weaker rule than the
  // gate's would be a confident verdict measured with the wrong instrument.
  if (!GATE) {
    return {
      callerRoot,
      targetRoot,
      covered: null,
      source: 'rejected:gate-unavailable',
      sourceTrusted: fromEnv.trusted,
      reasonCode: 'gate-unavailable',
      reason: 'the source-write gate module could not be loaded, so its own containment predicate was never asked',
    };
  }
  const contained = containment(callerRoot, targetRoot);
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
  // `contained` is already `null` when the two readings disagreed; this downgrade
  // only ever discards a `true`, so the two null causes compose without either
  // masking the other.
  const covered = (contained === true && !fromEnv.trusted) ? null : contained;
  const reason = covered !== null
    ? null
    : contained === null
      ? 'the target worktree\'s literal and resolved spellings disagree — a symlink in its path, or a case or short-name difference on this filesystem — so it is inside this anchor when reached by cd and outside it when written out, and the gate compares the anchor resolved against the path as written'
      : 'CLAUDE_PROJECT_DIR is this host\'s wider project directory, not the immutable root the gate compares, so containment in it settles nothing';
  const reasonCode = covered !== null ? null : contained === null ? 'ambiguous-spelling' : 'weak-channel';
  return { callerRoot, targetRoot, covered, source, sourceTrusted: fromEnv.trusted, reasonCode, reason };
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
  // `allowed` carries its own caveat, because the header above enumerates two
  // narrowings and ONE of them errs in exactly this direction: rule (A) can still
  // refuse an in-anchor raw shell overwrite of tracked source. (The realpath
  // asymmetry was a second one until `containment` started answering `null` on a
  // disagreement; it is gone, not merely unlikely.) Leaving this branch as one bare
  // sentence applied the design's fail-safe to the `null` case and dropped it on
  // the only case that can send a reader confidently into a deny.
  if (w.covered === true) {
    return [
      'WRITES   allowed — the target worktree is inside this session\'s anchor.',
      '         Necessary, not sufficient: rule (A) can still refuse a raw shell',
      '         overwrite of tracked source inside the anchor, and this line answers',
      '         only the containment question the gate asks first.'
    ];
  }
  const target = flatPath(w.targetRoot) || '(unknown)';
  // The reason is READ, not re-derived. `writeAnchor` decides it beside the
  // measurement that produced it and returns it as `w.reason`, so the head and the
  // reason cannot disagree — which the previous spelling only claimed. That one
  // rebuilt the whole ladder here from `source` alone, and `source` separates only
  // two of the seven null causes, so a `null` from one cause could be explained by
  // a sentence describing another. `w.reasonCode` is the branchable half for a
  // `--json` consumer; this renderer wants the sentence.
  //
  // The fallback exists because this renderer must not depend on a caller having
  // gone through `writeAnchor`: an older payload, or a future second producer,
  // would otherwise interpolate `undefined` into a disclosure line.
  const why = flatPath(w.reason) || 'the anchor comparison did not produce a reason';
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
    ? (w.sourceTrusted === false
      ? `WRITES   denied here (hint) — measured against CLAUDE_PROJECT_DIR (${flatPath(w.callerRoot)}), which does not contain that worktree. That is not the immutable root the gate compares, and nothing here established how the two relate, so treat this as a strong hint and check the WORKTREE row against your own working directory.`
      : `WRITES   denied here — this session is anchored to ${flatPath(w.callerRoot)}, which does not contain that worktree.`)
    // "the anchor was not measured" was true for exactly ONE of the seven null
    // causes — the one where neither channel resolved. In the others the anchor
    // resolved fine and it is the COMPARISON that could not be settled: no recorded
    // worktree, a relative one, two spellings that disagree, a channel whose `true`
    // may not be believed, or a gate module that did not load. Naming the anchor as
    // the missing piece sent a reader to check an environment variable that was
    // already correct. `${why}` carries the actual cause; the head states only what
    // holds in every branch.
    : `WRITES   unknown — containment could not be established (${why}); assume denied and check yourself.`;
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

// The desktop store's top-level directory is the ACCOUNT UUID, not a "desktop
// instance". Measured 2026-08-21 on macOS, three independent ways: one directory
// equalled `oauthAccount.accountUuid` in ~/.claude.json; another equalled
// `lastKnownAccountUuid` in Claude/config.json AND held the running session's own
// record; and ant-device-registry.json — a per-account artifact — is keyed on
// exactly that set of UUIDs. So the account that owns a session IS derivable, which
// the SKILL's blanket "no account provenance exists" claim got wrong: that claim
// holds for the registry and the transcripts, and only for those.
//
// ONLY the macOS path is verified. The Windows and Linux candidates below are
// INFERRED from the usual Electron userData locations and have never been observed;
// `lineage --diagnose` prints every probe so a wrong guess is visible in one command,
// and $ZENSU_CCD_STORE overrides the list without a code change.
function ccdStoreCandidates() {
  const out = [];
  // An explicit override is AUTHORITATIVE, not merely first: falling through to a
  // guessed path when the named one is absent would silently attribute sessions to
  // accounts read out of a store the operator did not choose, and the fallback would
  // be invisible in every output except --diagnose.
  const env = process.env.ZENSU_CCD_STORE;
  if (env && env.trim()) return [{ source: 'ZENSU_CCD_STORE (authoritative)', dir: path.resolve(hostPath(env.trim())) }];
  out.push({ source: 'macOS (verified)', dir: path.join(HOME, 'Library', 'Application Support', 'Claude', 'claude-code-sessions') });
  const appData = process.env.APPDATA;
  if (appData && appData.trim()) out.push({ source: 'Windows APPDATA (unverified)', dir: path.join(appData.trim(), 'Claude', 'claude-code-sessions') });
  const localAppData = process.env.LOCALAPPDATA;
  if (localAppData && localAppData.trim()) out.push({ source: 'Windows LOCALAPPDATA (unverified)', dir: path.join(localAppData.trim(), 'Claude', 'claude-code-sessions') });
  const xdg = process.env.XDG_CONFIG_HOME;
  if (xdg && xdg.trim()) out.push({ source: 'XDG_CONFIG_HOME (unverified)', dir: path.join(xdg.trim(), 'Claude', 'claude-code-sessions') });
  out.push({ source: 'Linux ~/.config (unverified)', dir: path.join(HOME, '.config', 'Claude', 'claude-code-sessions') });
  return out;
}

function ccdStore() {
  for (const c of ccdStoreCandidates()) {
    if (dirExists(c.dir)) return c;
  }
  return null;
}

// The store's EXISTENCE as a separate, memoised answer — main hoisted it for the
// reason its comment gives: it is a process constant and the row literal runs once
// per session record, and a store that does not exist on this host is NOT the same
// as one that exists and lacks this session. It is derived from `ccdStore()` rather
// than from a hardcoded macOS path, so the three-valued worktree advice is correct
// on Linux and Windows too. A function rather than a module const because resolving
// the store routes through `hostPath`, which FAILS when the plugin tree is
// incomplete: evaluating that at module load would abort every command instead of
// the one that actually needs a store.
let CCD_STORE_EXISTS_MEMO = null;
function ccdStoreExists() {
  if (CCD_STORE_EXISTS_MEMO === null) CCD_STORE_EXISTS_MEMO = Boolean(ccdStore());
  return CCD_STORE_EXISTS_MEMO;
}

let CCD_CACHE = null;

function ccdIndex() {
  if (CCD_CACHE) return CCD_CACHE;
  const map = new Map();
  CCD_CACHE = map;
  const store = ccdStore();
  if (!store) return map;
  const walk = (dir, depth, accountUuid) => {
    if (depth > 3) return;
    let es;
    try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch { SKIPPED += 1; return; }
    for (const e of es) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) { walk(p, depth + 1, accountUuid || e.name); continue; }
      if (!/^local_.*\.json$/.test(e.name)) continue;
      let o;
      try { o = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
      if (!o || !o.cliSessionId) continue;
      map.set(o.cliSessionId, {
        accountUuid: accountUuid || null,
        archived: o.isArchived === true,
        title: o.title || null,
        model: o.model || null,
        effort: o.effort || null,
        permissionMode: o.permissionMode || null,
        lastFocusedAt: o.lastFocusedAt || null,
      });
    }
  };
  walk(store.dir, 0, null);
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

function appTag(app) {
  if (!app) return '';
  const acct = app.accountUuid ? accountLabel(app.accountUuid) : 'account ?';
  return `${app.archived ? '[ARCHIVED] ' : ''}${acct}`;
}

// ── Account labels ──────────────────────────────────────────────────────────
// The account UUID is derivable; a human-readable name for it is not — the only
// email on disk is `oauthAccount.emailAddress` in ~/.claude.json, and that names
// whichever account wrote the file LAST, not the account of any given session. So
// the label is user-supplied and purely cosmetic: the GROUPING is automatic and
// cannot be typo'd, the label only makes it readable.
let LABEL_CACHE = null;

let LABELS_UNREADABLE = false;
let LABELS_SCHEMA_MISMATCH = false;

function readLabels() {
  if (LABEL_CACHE) return LABEL_CACHE;
  // CONFIG_ROOT as the ceiling, the same one ledgerRead and lineageForget pass:
  // the writer already refuses a symlinked ancestor, so the reader must too.
  const { labels, unreadable, schemaMismatch } = readLabelsFile(LABELS_FILE, CONFIG_ROOT);
  LABELS_UNREADABLE = unreadable;
  LABELS_SCHEMA_MISMATCH = !!schemaMismatch;
  if (unreadable || schemaMismatch) SKIPPED += 1;
  LABEL_CACHE = labels;
  return LABEL_CACHE;
}

// The uuid prefix stays beside the label, never instead of it: two accounts
// sharing a label must still be distinguishable in a rendered chain.
function accountLabel(key) {
  if (!key) return 'account ?';
  const l = Object.prototype.hasOwnProperty.call(readLabels().accounts, key) ? readLabels().accounts[key] : undefined;
  return l ? `${l} (${instanceId(key, 8)})` : `account ${instanceId(key, 8)}`;
}

function windowLabel(appPid) {
  const w = readLabels().windows;
  // The qualified key ONLY. A bare-pid fallback would restore exactly the reuse
  // hazard the qualification removes — and silently, since a label that resolves
  // renders identically whether or not it belongs to the window in front of you.
  const key = windowKey(appPid);
  const l = key && Object.prototype.hasOwnProperty.call(w, key) ? w[key] : undefined;
  return l ? `window ${appPid} (${l})` : `window pid ${appPid}`;
}

// ── Window identity ─────────────────────────────────────────────────────────
// A second, INDEPENDENT route to "which window": each account runs its own
// Claude.app main process, and a CLI session is a descendant of exactly one of
// them (measured 2026-08-21: 13084 -> 13083 Contents/Helpers/disclaimer -> 79209
// Claude.app/Contents/MacOS/Claude). This matters because the desktop store is the
// ONLY source of accountUuid, and its path outside macOS is unverified — when the
// store is unreachable, this still groups sessions by window correctly.
let PROC_TABLE = null;
let PROC_TABLE_FAULT = null;

function processTable() {
  if (PROC_TABLE) return PROC_TABLE;
  PROC_TABLE = new Map();
  // One table read rather than a `ps` per ancestor: the walk is at most a handful
  // of hops, but on Windows each hop would be a separate PowerShell start-up.
  let out = '';
  try {
    if (process.platform === 'win32') {
      // An absolute root only: a relative %SystemRoot% would make the interpreter
      // path relative to the process cwd, which is the repository directory. Absolute
      // is a SHAPE test and not a trust test, so the resolved interpreter is stat'd
      // before it is spawned — `D:\\evil` is absolute too, and this process's
      // environment is set by whatever launched it.
      const sysRoot = process.env.SystemRoot;
      const root = sysRoot && path.isAbsolute(sysRoot) ? sysRoot : 'C:\\Windows';
      const shell = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
      let shellStat;
      try { shellStat = fs.lstatSync(shell); } catch { return PROC_TABLE; }
      if (!shellStat.isFile()) return PROC_TABLE;
      // The CreationDate is rendered explicitly, in UTC and under the invariant
      // culture. `"$($_.CreationDate)"` follows the ambient culture, so changing
      // the machine's locale or timezone changed the token and silently unbound
      // every window label — the POSIX branch pins LC_ALL/TZ for the same reason
      // and the token's own comment leans on that pin.
      const program = "Get-CimInstance Win32_Process | ForEach-Object { \"$($_.ProcessId)`t$($_.ParentProcessId)`t$($_.CreationDate.ToUniversalTime().ToString('yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture))`t$($_.Name)\" }";
      // -EncodedCommand, not -Command. The program carries embedded double quotes, and
      // Node escapes those as `\"` when it builds a Windows command line; powershell.exe
      // then re-reads the backslashes with its own rules, which is the documented
      // argument-mangling class. The observable result was an EMPTY process table on the
      // Windows runner: windowKey() answered null, no window label was ever written, and
      // eight checks failed against a labels.json that had never been created. Base64
      // UTF-16LE removes the ambiguity instead of guessing which layer ate which
      // character — there is nothing left for either parser to interpret.
      out = execFileSync(shell, ['-NoProfile', '-NonInteractive', '-EncodedCommand',
        Buffer.from(program, 'utf16le').toString('base64')],
      { encoding: 'utf8',
        timeout: 8000,
        stdio: ['ignore', 'pipe', 'pipe'],
        // The environment is pinned here for the same reason it is pinned on the POSIX
        // arm below, and one reason more: `-NoProfile` does not cover module resolution,
        // so `Get-CimInstance` is auto-loaded from whatever `PSModulePath` names. An
        // inherited entry pointing at a writable directory holding a `CimCmdlets` module
        // is loaded by the real powershell.exe. Degrading here costs only the
        // window-grouping route, which every caller already treats as optional.
        env: {
          SystemRoot: root,
          windir: root,
          SystemDrive: path.parse(root).root.replace(/\\+$/, ''),
          ComSpec: path.join(root, 'System32', 'cmd.exe'),
          // The previous spelling replaced the environment wholesale and left a
          // Windows process without PATH, windir, SystemDrive or ComSpec. Get-CimInstance
          // reaches WMI through the provider host under System32\Wbem, so that
          // omission is the first thing to suspect. INFERRED, not observed: the runner
          // discarded stderr, so all the evidence there is says 229 of 288 checks
          // consumed the whole 900s budget -- about 3.9s per check against a probe
          // capped at 8s -- while every window-namespace check failed against a
          // labels.json the probe never let anything write. A stall on every
          // invocation fits that arithmetic; a fast failure does not. The stderr
          // capture below is what settles it rather than reasoning about it again.
          PATH: [
            path.join(root, 'System32'),
            root,
            path.join(root, 'System32', 'Wbem'),
            path.join(root, 'System32', 'WindowsPowerShell', 'v1.0'),
          ].join(';'),
          PSModulePath: path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules'),
          PATHEXT: '.COM;.EXE;.BAT;.CMD',
          TEMP: process.env.TEMP || path.join(root, 'Temp'),
          TMP: process.env.TMP || path.join(root, 'Temp'),
        } });
    } else {
      // Absolute path and a pinned environment, as hooks/lib/session-control-core-v1.js
      // does for the same probe: the argument vector is a fixed literal, so the only
      // exposure left is program resolution and an inherited environment.
      // `lstart` rather than `etime`: an elapsed time changes on every read, so it
      // cannot key anything. The `LC_ALL=C` pin below is what makes it parseable at
      // all: the weekday and month are rendered in the caller's locale, so without
      // the pin the column carries localized abbreviations no ASCII shape matches.
      out = execFileSync('/bin/ps', ['-Ao', 'pid=,ppid=,lstart=,comm='], {
        encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'],
        env: { PATH: '/usr/bin:/bin', LC_ALL: 'C', LANG: 'C', TZ: 'UTC' },
      });
    }
  } catch (e) { PROC_TABLE_FAULT = probeFault(e); return PROC_TABLE; }
  for (const line of out.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    let pid; let ppid; let comm; let started = null;
    if (process.platform === 'win32') {
      const f = t.split('\t');
      if (f.length < 3) continue;
      // Four fields now, but a three-field line is still accepted: losing the start
      // time must cost the LABEL, never the ppid walk that windowOf depends on.
      pid = Number(f[0]); ppid = Number(f[1]);
      if (f.length >= 4) { started = String(f[2]).trim(); comm = String(f[3]).trim(); }
      else comm = String(f[2]).trim();
    } else {
      // Two patterns, tried widest-first, for the same reason: a row whose `lstart`
      // does not parse still contributes its parent link. Dropping the row instead
      // would break the ancestor walk on exactly the hosts whose `ps` differs.
      const withStart = /^(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.*)$/.exec(t);
      const m = withStart || /^(\d+)\s+(\d+)\s+(.*)$/.exec(t);
      if (!m) continue;
      pid = Number(m[1]); ppid = Number(m[2]);
      if (withStart) { started = m[3].trim(); comm = m[4].trim(); }
      else comm = m[3].trim();
    }
    if (!Number.isFinite(pid) || !Number.isFinite(ppid)) continue;
    PROC_TABLE.set(pid, { ppid, comm, started });
  }
  return PROC_TABLE;
}

// An OS pid is reused the moment its process exits, so a label keyed by the bare
// number silently renames whatever window inherits it next — and renders with
// exactly the confidence a correct one gets. The key names the INCARNATION: the
// pid plus the process's own start time, taken from the table windowOf already
// builds, so no second probe is spawned for it.
//
// The token is the raw start string with its punctuation flattened, NOT a parsed
// instant. `Date.parse` would introduce a timezone: `ps` renders under the pinned
// TZ=UTC of its own environment while the parse happens in this process's local
// zone, and the two only have to AGREE WITH THEMSELVES for the key to discriminate.
// Anything that round-trips a clock invites a mismatch that silently unbinds every
// label on the machine.
// Whether the start-time column parsed at all. When the locale pin does not hold —
// a wrapper that re-exports LANG, a host whose `ps` ignores it — the widest parse
// fails, `started` is null for every row, and every window label silently stops
// resolving with nothing anywhere saying why. This is the command whose entire job
// is explaining why something does not resolve.
function probeFault(e) {
  if (!e) return 'unknown';
  const parts = [];
  if (e.code) parts.push(String(e.code));
  if (e.signal) parts.push(`signal ${e.signal}`);
  if (typeof e.status === 'number' && e.status !== 0) parts.push(`exit ${e.status}`);
  const err = e.stderr ? String(e.stderr).split('\n').map((l) => l.trim()).find(Boolean) : '';
  if (err) parts.push(err);
  const text = parts.join(' ') || String((e && e.message) || 'unknown');
  return text.replace(/\s+/g, ' ').slice(0, 200);
}

function processStartTimeHealth() {
  const table = processTable();
  if (!table.size) return PROC_TABLE_FAULT ? `probe-failed — ${PROC_TABLE_FAULT}` : 'no-process-table';
  let withStart = 0;
  for (const e of table.values()) if (e && e.started) withStart += 1;
  if (withStart === 0) return 'unreadable — window labels cannot resolve';
  return withStart === table.size ? 'ok' : `partial (${withStart}/${table.size})`;
}

function incarnationToken(entry) {
  const raw = entry && entry.started ? String(entry.started).trim() : '';
  if (!raw) return null;
  return raw.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || null;
}

// null when the pid names no running process, and every caller treats that as
// "there is no window to label" rather than falling back to the bare number.
// Deliberate consequence: a window-keyed label stops resolving once its process is
// gone. That is the safe direction — the alternative is the label resurfacing on an
// unrelated window, which is the defect this exists to remove.
function windowKey(appPid) {
  const pid = Number(appPid);
  if (!Number.isFinite(pid)) return null;
  const tok = incarnationToken(processTable().get(pid));
  return tok ? `${pid}@${tok}` : null;
}

// The HIGHEST ancestor whose PROGRAM names Claude, excluding the CLI process
// itself. Highest rather than nearest: the chain passes through a helper under
// `Contents/Helpers/`, and it is the app process at the top that owns the window.
// A session with no such ancestor — a terminal or IDE launch — answers null, which
// is the honest result, not a fallback to itself.
//
// The basename, never the whole string. `ps -o comm=` yields the full executable
// PATH on macOS, so the previous whole-string test matched any ancestor that
// merely LIVED under a claude-named directory — `~/claude-tools/bin/watcher`, or a
// checkout of this plugin. The session was then grouped under a window that is not
// one, and this walk is the fallback that exists precisely for when the desktop
// store (the only other source of that grouping) is unreachable.
function windowOf(pid, table = processTable()) {
  if (!table || !table.size || !Number.isFinite(pid)) return null;
  let cur = table.get(pid);
  let found = null;
  for (let hop = 0; hop < 12 && cur && cur.ppid > 1; hop += 1) {
    const next = table.get(cur.ppid);
    if (!next) break;
    if (/claude/i.test(path.basename(next.comm))) found = cur.ppid;
    cur = next;
  }
  return found;
}

// ── Lineage ledger ──────────────────────────────────────────────────────────
// The schema, the store layout and the chain walk live in session-lineage-v1.mjs.
// These wrappers only bind the module to this process's resolved roots and to the
// module-scope SKIPPED counter, so the record shape has exactly one owner.
// The read's status travels with its RESULT and no longer through module-scope
// state. Three globals meant every later reader saw whatever the last call left
// behind: two reads in one command reported the first one's failures against the
// second one's records, and a consumer that never read at all still rendered a
// clean null ledger error as though it had measured one.

// The one durable way to decline collection. `--no-record` is per-invocation and
// `takeover`-only, so a user who wants no lineage recorded at all had nothing to set:
// the store is machine-wide, permanent until someone runs `lineage --forget`, and
// written from inside a node process that no Write-tool hook can see.
//
// It REFUSES rather than returning quietly, and the message names the variable — a
// switch whose effect is indistinguishable from a broken command teaches the user
// nothing, and every caller of `ledgerWrite` already renders the reason it was given.
// The check lives at the single write chokepoint on purpose: a per-verb check is one
// a later verb can forget.
const LINEAGE_DISABLED = 'lineage recording is disabled by ZENSU_SESSION_LINEAGE=off — nothing was written';

function lineageRecordingDisabled() {
  return String(process.env.ZENSU_SESSION_LINEAGE || '').trim().toLowerCase() === 'off';
}

function ledgerWrite(edge) {
  if (lineageRecordingDisabled()) throw new Error(LINEAGE_DISABLED);
  return writeEdge(LEDGER_DIR, edge, Date.now(), CONFIG_ROOT);
}

// The store has TWO writers, and the switch has to cover both or its promise is false:
// `labels.json` sits in the same directory as the edges and names accounts and windows.
// `label --remove` is deliberately NOT gated — it REMOVES recorded information, and a
// privacy control that blocked a deletion would work against the person who set it.
function labelsSet(mutate) {
  if (lineageRecordingDisabled()) throw new Error(LINEAGE_DISABLED);
  return updateLabels(LABELS_FILE, mutate, CONFIG_ROOT);
}

// A refused record is COUNTED, never dropped silently, and a directory that could
// not be read at all is reported separately: a lineage that quietly loses a link
// reads exactly like a session nobody ever took over, which is the one wrong
// answer this whole feature exists to prevent.
function ledgerRead() {
  // CONFIG_ROOT is the ceiling, the same one ledgerWrite passes: without it the
  // read and delete paths check the leaf only, and a symlink at `session-lineage/`
  // or `v1/` is resolved as an ordinary intermediate component — which let
  // `lineage --forget --apply` unlink a record OUTSIDE the ledger directory.
  const { edges, refused, directoryError, truncated } = readEdges(LEDGER_DIR, CONFIG_ROOT);
  if (directoryError) SKIPPED += 1;
  let schemaNewer = false;
  for (const r of refused) {
    SKIPPED += 1;
    if (r.reason === EDGE_REFUSALS.SCHEMA_NEWER) schemaNewer = true;
  }
  // `truncated` is the record-COUNT cap readEdges applies, and it used to be
  // dropped here. A ledger past the bound then answered from a prefix and rendered
  // exactly like a complete one -- the silent truncation the bound was added to
  // make visible. Per-record refusals stay a separate number: they are the narrow
  // half of the same hazard, one dropped record is one pair missing from the
  // duplicate guard, and the remedies differ.
  return { edges, refused: refused.length, directoryError, schemaNewer, truncated };
}


// ── Edge construction ───────────────────────────────────────────────────────
// The running session identifies itself from its own environment rather than by
// guessing from the registry: CLAUDE_PID and CLAUDE_CODE_SESSION_ID are set for
// every session, and CLAUDE_CODE_HOST_SESSION_ID is the desktop record's file name
// — the direct join to this session's own account.
function selfIdentity() {
  const pid = Number(process.env.CLAUDE_PID);
  const sessionId = (process.env.CLAUDE_CODE_SESSION_ID || '').trim() || null;
  const hostSessionId = (process.env.CLAUDE_CODE_HOST_SESSION_ID || '').trim() || null;
  let accountUuid = null;
  if (sessionId) {
    const app = ccdIndex().get(sessionId);
    if (app) accountUuid = app.accountUuid;
  }
  if (!accountUuid && hostSessionId) accountUuid = accountForHostSession(hostSessionId);
  const cwd = process.cwd();
  const wt = (dirExists(cwd) && worktreeRoot(cwd)) || cwd;
  return makeEndpoint({
    sessionId,
    accountUuid,
    appPid: Number.isFinite(pid) ? windowOf(pid) : null,
    pid: Number.isFinite(pid) ? pid : null,
    // `cwd` and `title` are deliberately absent: makeEndpoint persists six fields
    // and drops anything else, so passing them advertised a shape the record does
    // not have. `cwd` is still read above, for `wt`.
    worktree: wt,
    branch: git(wt, ['rev-parse', '--abbrev-ref', 'HEAD']),
  });
}

// The desktop record is keyed on cliSessionId, so a session whose transcript this
// tool cannot see is invisible to ccdIndex(). CLAUDE_CODE_HOST_SESSION_ID names the
// record file directly, which is the one lookup that does not need the transcript.
function accountForHostSession(hostSessionId) {
  // Refused before it becomes a path component: `..` normalises out of the store,
  // and because the probe returns the first matching account directory, any
  // always-present path would make one account answer for every session — and
  // that answer is then persisted as provenance.
  if (!isSafeHostSessionId(hostSessionId)) return null;
  const store = ccdStore();
  if (!store) return null;
  const want = `${hostSessionId}.json`;
  let accounts;
  try { accounts = fs.readdirSync(store.dir, { withFileTypes: true }); } catch { SKIPPED += 1; return null; }
  for (const a of accounts) {
    if (!a.isDirectory()) continue;
    const accountDir = path.join(store.dir, a.name);
    let workspaces;
    try { workspaces = fs.readdirSync(accountDir, { withFileTypes: true }); } catch { continue; }
    for (const w of workspaces) {
      if (!w.isDirectory()) continue;
      try {
        if (fs.existsSync(path.join(accountDir, w.name, want))) return a.name;
      } catch { /* keep probing */ }
    }
  }
  return null;
}

function endpointFromRow(row) {
  const pid = row && row.live && Number.isFinite(row.live.pid) ? row.live.pid : null;
  return makeEndpoint({
    sessionId: row && row.sessionId,
    accountUuid: (row && row.app && row.app.accountUuid) || null,
    appPid: pid ? windowOf(pid) : null,
    pid,
    worktree: row && row.wt,
    branch: row && row.branch,
  });
}

// `workRoot` is the HANDED-OVER work, never the recording process's directory.
// The documented takeover route runs from a window in a different repo, so
// deriving the repo from the recorder filed the edge under the taker's repo and
// made the default, repo-scoped `lineage` render nothing where the work lives.
// `confidence` and `at` are both CALLER decisions and neither may be defaulted here.
// The tier is what the caller is entitled to claim: generating a takeover brief is
// not the same event as having taken the session over, so a plain `takeover` claims
// `provisional`, while `--force` (the user's approval, on the command line) and
// `adopt` (the confirmation verb) claim `confirmed`.
//
// `at` is when the handover HAPPENED, which for a reconstructed edge is the stalled
// session's own last activity — not the moment `--apply` ran. Stamping every guess
// with the apply instant made it newer than every real handover by construction, and
// `recordedAt` is the sole ordering key at four sites, so one backfill promoted
// guesses above measurements permanently and printChain printed the backfill date as
// the date of the handover.
function buildEdge(fromRow, to, reason, recordedBy, confidence, at) {
  return buildLedgerEdge({
    from: endpointFromRow(fromRow),
    to,
    workRoot: (fromRow && fromRow.wt) || to.worktree || null,
    repoRootOf: (root) => nearestRepoRoot(root, new Map()),
    reason,
    recordedBy,
    confidence,
    at,
  });
}

const nowStamp = () => new Date().toISOString();

// The reader-facing half of the confidence tier. Recording the tier and rendering
// nothing would leave the user exactly where they were: unable to tell a brief that
// was generated from a handover that actually happened. `confirmed` is deliberately
// silent — annotating the ordinary case would drain the marker of meaning.
// The one-word form, for renderings that carry a list rather than a numbered chain.
// Same owner as the long form so a new tier lands in one place; `confirmed` is the
// silent tier on both, because a marker every line carries marks nothing.
function confidenceMark(edge) {
  const tier = edgeTier(edge);
  return tier === 'confirmed' ? '' : ` [${tier === 'inferred' ? 'inferred' : 'unconfirmed'}]`;
}

function edgeTier(edge) {
  return (edge && edge.confidence) || (edge && edge.inferred ? 'inferred' : 'provisional');
}

function confidenceNote(edge) {
  const tier = edgeTier(edge);
  if (tier === 'inferred') return '   [inferred — a guess from --backfill, not a recorded handover]';
  if (tier === 'provisional') return '   [unconfirmed — a takeover brief was generated; no confirmation followed]';
  return '';
}

function liveState(sessionId, live) {
  return live.has(sessionId) ? 'LIVE' : 'not running';
}

function endpointLabel(ep) {
  if (ep.accountUuid) return accountLabel(ep.accountUuid);
  if (ep.appPid) return windowLabel(ep.appPid);
  return 'account unknown';
}

function sessionTag(value) {
  return instanceId(String(value == null ? '' : value), 8);
}

function instanceId(value, width) {
  // ORDER is load-bearing because `CONTROL_RUN` carries `\p{Cf}`: strip the
  // zero-advance class from the RAW value FIRST. Run the other way round,
  // `flatPath` matches those code points before the strip can and leaves a SPACE
  // where the strip was meant to leave nothing — the substitution then CONSUMES a
  // column of the fixed width and shifts real characters out of the prefix, so
  // `a<ZWSP>bcdefgh` renders `a bcdefg` instead of `abcdefgh` and how much of the
  // real id survives depends on how many invisible characters it carried.
  //
  // It does NOT make two ids that differ only by a zero-advance character
  // distinct — both orders collapse those (measured), and the class header below
  // accepts that trade deliberately.
  return flatPath(String(value == null ? '' : value).replace(ZERO_WIDTH, ''))
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
// MEMOIZED, exactly as `ccdIndex` is, and for a reason `ccdIndex` never had to
// state: `SKIPPED` is a module-scope counter this function increments, so a second
// walk of the same directory counts the same unreadable file twice. `cmdShow`
// reaches `buildIndex` twice — once through `resolve` and once through `siblings`
// — and `buildIndex` calls this unconditionally, so one corrupt registry record
// would render `NOTE 2 record(s) unreadable` in the plain-text path while
// `show --json`, emitted BEFORE `siblings` runs, reported `"skipped": 1` for the
// identical machine state. Two carriers of one command disagreeing about a number
// the skill documents is worse than the number being large.
let LIVE_CACHE = null;

function liveRegistry() {
  if (LIVE_CACHE) return LIVE_CACHE;
  const map = new Map();
  LIVE_CACHE = map;
  if (!dirExists(SESSIONS)) return map;
  let regFiles;
  try { regFiles = fs.readdirSync(SESSIONS); } catch { SKIPPED += 1; return map; }
  for (const f of regFiles) {
    if (!f.endsWith('.json')) continue;
    let o;
    // COUNTED, not swallowed. SKILL.md promises that every command prints a NOTE
    // naming how many records were skipped — so a corrupt registry file that
    // silently drops a LIVE session is exactly the state that promise exists to
    // make visible, and it is indistinguishable from an idle machine without it.
    try { o = JSON.parse(fs.readFileSync(path.join(SESSIONS, f), 'utf8')); } catch { SKIPPED += 1; continue; }
    // Identity first, pid SECOND and under ONE rule. Testing `!o.pid` here and a
    // bad pid further down split the accounting: `pid: 0`, `pid: ""` and
    // `pid: false` were dropped in silence while `pid: "abc"` and `pid: -1` were
    // counted, though a falsy pid is exactly as malformed as a non-numeric one.
    if (!o || !o.sessionId) continue;
    // Normalize the pid HERE rather than bounding its fourteen render sites. It is
    // another process's JSON, its type was never constrained, and `process.kill`
    // accepts a numeric STRING — so a padded or decorated spelling survived the
    // only filter and then reached a STATUS row, two brief bullets and half a dozen
    // verdict reasons raw, where a line break fabricates a line directly above the
    // verdict a reader acts on.
    //
    // The TYPE is checked before the coercion, and that is not pedantry: `Number`
    // is total, so `true` becomes 1 and `[7]` becomes 7 — both integers, both > 0,
    // both admitted. A record spelling its pid as a boolean would then be probed
    // against init and, on any host that answers EPERM there, rendered as a LIVE
    // session that does not exist. Only a number or a string can be a pid spelling.
    const raw = o.pid;
    const pid = (typeof raw === 'number' || typeof raw === 'string') ? Number(raw) : NaN;
    if (!Number.isInteger(pid) || pid <= 0) { SKIPPED += 1; continue; }
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch (e) { alive = e && e.code === 'EPERM'; }
    if (!alive) continue;
    const rec = { ...o, pid };
    const prev = map.get(o.sessionId);
    if (!prev || (rec.startedAt || 0) > (prev.startedAt || 0)) map.set(o.sessionId, rec);
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
  // Code units, not `localeCompare`: these are ISO-8601 stamps, where the two
  // agree on every input that matters — but `localeCompare` resolves the host
  // locale, so the ONE rule this file now holds for ledger records may as well
  // hold for the only other timestamp ordering in it. Same defect class, caught
  // beside its sibling rather than left as the exception that invites the next one.
  out.sort((a, b) => {
    const x = String(a.at || ''); const y = String(b.at || '');
    if (x < y) return -1;
    return x > y ? 1 : 0;
  });
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
    // NOT bounded here, and the ordering is the reason. `rel(t.path, r.wt)` strips
    // the worktree prefix at render time by string comparison, and `r.wt` is the RAW
    // value — so binding the path at extraction leaves the two spellings unable to
    // match, and every row renders the absolute path instead of the relative one. It
    // was measured doing exactly that: a worktree carrying a newline produced a brief
    // with no `## Files the session touched` rows at all. All three renderers bound
    // this value themselves (`flatPath` in `show`, `briefPath` in both briefs), which
    // is what makes the early bound redundant as well as wrong.
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

// Memoized on the options that actually decide the scan. One process runs one
// command, and a second identical pass fired every SKIPPED increment twice — so
// `show` reported double what `show --json` did for the same machine state.
const INDEX_CACHE = new Map();
function buildIndex(opts) {
  const key = JSON.stringify([opts.repo || null, opts.all, opts.days, opts.live, opts.git]);
  if (INDEX_CACHE.has(key)) return INDEX_CACHE.get(key);
  const built = buildIndexUncached(opts);
  INDEX_CACHE.set(key, built);
  return built;
}

function buildIndexUncached(opts) {
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
        ccdStore: ccdStoreExists(),
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

// Delegates to the ledger module rather than re-spelling the bound: `\s` does not
// match ESC or the rest of Cc/Cf, so a private copy here disagreed with boundText
// about what can forge a line — and this is the bound on RENDERED terminal output,
// fed from third-party transcripts. boundText returns null on an empty result;
// this caller wants the empty string.
function oneLine(s, n) {
  // The falsy guard is kept rather than folded into boundText: boundText returns
  // "0" for the number 0 and "false" for false, where this renderer has always
  // produced the empty string. No call site passes either today -- every one
  // hands over a string or null -- so dropping it would have changed nothing
  // visible now and something visible later, which is the worse of the two.
  if (!s) return '';
  return boundText(s, n) || '';
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
  // The lineage is rendered HERE because the window that ran out of quota cannot
  // ask anything — one `instances` call from any working window has to answer
  // "where did that session go" for every session on the machine.
  const led = ledgerRead();
  const edges = dedupeEdges(led.edges);
  const lineageOf = (sessionId) => {
    const out = [];
    for (const e of edges) {
      // The SHORT tier marker, not the legacy `inferred` boolean this used to read.
      // SKILL.md says the tier is annotated in every rendering, and this is the view
      // it names as the machine-wide answer — so a `provisional` edge rendered here
      // as a completed handover, which is the one claim the tier exists to prevent.
      if (e.from.sessionId === sessionId) out.push(`→ continued in ${sessionTag(e.to.sessionId)} (${endpointLabel(e.to)})${confidenceMark(e)}`);
      if (e.to.sessionId === sessionId) out.push(`← taken over from ${sessionTag(e.from.sessionId)} (${endpointLabel(e.from)})${confidenceMark(e)}`);
    }
    return out;
  };
  if (opts.json) {
    return print(JSON.stringify({
      rows: rows.map((r) => ({ ...r, lineage: lineageOf(r.sessionId) })),
      edgeCount: edges.length,
      ledgerTruncated: led.truncated, ledgerError: led.directoryError,
      schemaNewer: led.schemaNewer,
      skipped: SKIPPED,
    }, null, 2));
  }
  const memo = new Map();
  const groups = new Map();
  for (const s of rows) {
    const hasCwd = typeof s.cwd === 'string' && s.cwd !== '';
    const root = !hasCwd ? '(cwd not recorded)'
      : dirExists(s.cwd) ? (nearestRepoRoot(s.cwd, memo) || s.cwd) : path.dirname(s.cwd);
    if (!groups.has(root)) groups.set(root, []);
    groups.get(root).push(s);
  }
  const accounts = new Set();
  for (const s of rows) { const a = ccdIndex().get(s.sessionId); if (a && a.accountUuid) accounts.add(a.accountUuid); }
  print(`LIVE CLAUDE CODE SESSIONS: ${rows.length} (every session process on this machine)`);
  print(`ACCOUNTS INVOLVED: ${accounts.size}${accounts.size ? ` — ${[...accounts].map((i) => accountLabel(i)).join(', ')}` : ''}`);
  // This view is the machine-wide answer to "where did that session go" — the one
  // a window with no quota left cannot ask for itself — so a lineage line that is
  // MISSING must not render as one that is absent. The --json carrier said so from
  // the start; the text carrier printed the sessions and nothing else.
  { const t = truncatedNote(led); if (t) print(`!  ${t}`); }
  if (led.directoryError) print(`!  the ledger could not be read (${led.directoryError}) — the lineage lines below are missing, not absent.`);
  if (led.schemaNewer) print('!  the ledger holds records from a NEWER schema than this build reads — the lineage below is incomplete.');
  print('');
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
      for (const l of lineageOf(s.sessionId)) print(`          ${l}`);
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

// Takes the rows the caller already built. A second buildIndex() pass fired every
// SKIPPED increment twice, so `show` reported double what `show --json` did for
// the identical machine state.
function siblings(opts, row) {
  // The index is built HERE rather than by the caller: `buildIndex` is memoized, so
  // the second walk costs nothing, and passing rows in let a caller hand over an
  // index built with different options than the row it is comparing against.
  const { rows } = buildIndex({ ...opts, live: false });
  return rows.filter((r) => r.wt === row.wt && r.sessionId !== row.sessionId);
}

// WHERE to continue another session's work. Distinct from the write-anchor
// question `writeAnchor` answers: that one asks whether this session MAY write
// there, this one asks whether the directory will still EXIST. Archiving removes
// a worktree — SKILL.md section 6 measures 498 of 657 archived worktree-sessions
// losing theirs — and a session still working in it then loses its project root
// mid-flight, which denies Edit/Write/MultiEdit outright.
//
// THREE decisions, all taken ABOVE the directory split. Taking any of them inside
// a leg is how the two legs drift: the `null` case falls through to "this session
// is not archived" on one of them, or the liveness qualification ends up on one
// and not the other.
function worktreeAdvice(r) {
  const archived = r.app ? r.app.archived === true : null;
  // `null` is not `false`. It means no record was readable for this session, and
  // asserting "not archived" there is exactly what SKILL.md forbids.
  const unreadable = archived === null;
  const noStore = unreadable && r.ccdStore === false;
  const unreadableWhy = noStore
    ? 'no desktop-app record store exists on this host'
    : 'the desktop app has no record for this session';
  // A registered live process can remove or move the worktree whatever the
  // archived flag says — that flag records what the desktop app did, not what the
  // process can still do — so an archived-but-alive session is treated as not
  // archived on EVERY leg. `liveRegistry` reads only `~/.claude/sessions`, so an
  // instance under its own CLAUDE_CONFIG_DIR is invisible here; the adopt-in-place
  // text says what was actually observed rather than claiming more.
  const liveDespiteArchive = archived === true && !!r.live;
  const safeToAdopt = archived === true && !liveDespiteArchive;
  // `cwdExists` measures the session's RECORDED cwd, which may be a subdirectory
  // the session started in rather than the worktree root. The wording names that
  // value rather than a line label: when the directory is gone `wt === cwd`, so no
  // rendered line carries a root-vs-subdirectory signal at all.
  const subdirCaveat = [
    'The recorded path may be a subdirectory the session started in rather than a worktree',
    'root — check whether a root above it still exists and still holds that branch before',
    'you add anything. That path comes out of another session\'s transcript, so read it',
    'before you use it as a create target.',
  ];
  if (!r.cwdExists) {
    if (safeToAdopt) {
      return [
        'Archived, dead, and the recorded directory is gone. Restore it with',
        '  git worktree add <path> <session-branch>',
        'The branch always survives archiving, so nothing is lost. If git answers that the',
        'branch is already checked out somewhere, the worktree you were told is gone is a',
        'SUBDIRECTORY of a root that still exists — find that root and work there. Do not',
        'reach for --force, and do not git checkout it elsewhere: that is what this rule forbids.',
        ...subdirCaveat,
      ];
    }
    // The REASON travels with its own lead, because a shared one was false in a
    // third of the cells: in the archived-but-alive arm the archive demonstrably
    // HAS run, and the hazard is the registered process acting on that path.
    const goneLead = liveDespiteArchive
      ? [
        `Archived, but pid ${r.live.pid} is still registered and alive, and the recorded directory is gone.`,
        'That process can still create or move a worktree at that path, so restoring its own path',
        'would put your work back under it.',
      ]
      : unreadable
        ? [
          `The archive state could not be read (${unreadableWhy}), and the recorded directory is gone.`,
          'Restoring its own path would leave the work exposed to an archive that has not run yet.',
        ]
        : [
          'This session is not archived, and the recorded directory is gone.',
          'Restoring its own path would leave the work exposed to an archive that has not run yet.',
        ];
    return [
      ...goneLead,
      'Take your own path instead:',
      '  git worktree add <path> <session-branch>',
      ...subdirCaveat,
    ];
  }
  if (safeToAdopt) {
    // States what was OBSERVED. The earlier wording promised that nothing recorded in
    // `~/.claude/sessions` can remove this worktree — true of that registry, and
    // beside the point: its entries are sessions, and the desktop app that performs
    // archiving is not one of them, so the reassurance rested on a registry that by
    // construction cannot list the agent that does the removing. Section 6 measures
    // the counter-example: of 657 archived worktree-sessions, the 159 survivors were
    // overwhelmingly DIRTY, which is exactly what `git worktree remove` refuses on.
    // So an archived directory that is still here is close to by construction one
    // archiving already tried to delete — and a takeover's first act is to commit,
    // which removes the very condition that saved it.
    return [
      'Adopt it in place — archiving already ran once and this directory survived. One caveat',
      'worth a look first: a surviving worktree is usually a DIRTY one, because that is what',
      '`git worktree remove` refuses on. Run `git status` here before you commit; committing',
      'removes the very condition that kept this directory alive.',
    ];
  }
  const lead = liveDespiteArchive
    ? [
      `Archived, but pid ${r.live.pid} is still registered and alive, so it can still remove or`,
      'move this worktree. Treat it as not archived.',
    ]
    : unreadable
      ? [
        `The archive state could not be read (${unreadableWhy}), so treat this worktree as one`,
        'that still belongs to an archivable session.',
      ]
      : [
        'Never continue in a worktree that still belongs to an archivable session — archiving',
        'deletes it under you.',
      ];
  return [
    ...lead,
    'Take your own on a NEW branch:',
    '  git worktree add <path> -b claude/<name>-cont <session-branch>',
    'A second worktree on the SAME branch is refused while the original still exists, and',
    'cp -R is not the copy route: the copy keeps the original gitdir and dies with it.',
  ];
}

function cmdShow(opts) {
  const base = resolve(opts, opts._[1]);
  const r = hydrate(base);
  const g = opts.git ? gitState(r.wt, true) : null;
  const v = activityVerdict(r, opts.force);
  const w = writeAnchor(r.wt);
  if (opts.json) return print(JSON.stringify({ ...r, git: g, takeover: v, writes: w, worktreeAdvice: worktreeAdvice(r), skipped: SKIPPED }, null, 2));
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
    print(`OWNER    account ${r.app.accountUuid ? instanceId(r.app.accountUuid, 64) : '(not resolvable)'}${r.app.accountUuid ? ` (${accountLabel(r.app.accountUuid)})` : ''}${r.app.archived ? '   **ARCHIVED** (process stopped, worktree may have been cleaned up)' : ''}`);
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
  if (sib.length) print(`SIBLINGS ${sib.map((s) => `${instanceId(String(s.sessionId), 8)}(${statusOf(s)})`).join(' ')}  — same worktree, other sessions`);
  print('');
  print(`TAKEOVER ${v.level} — ${v.reason}`);
  for (const advice of (ADVICE[v.level] || ['No advice is registered for this verdict — treat it as BUSY and ask before editing.'])) {
    print(`         ${advice}`);
  }
  // WHERE, below the verdict and above the write-anchor lines: the verdict says
  // whether taking over is safe, `writesLines` whether you may write there, and
  // this whether the directory will still exist while you do.
  print('');
  const wtAdvice = worktreeAdvice(r);
  print(`WHERE    ${wtAdvice[0]}`);
  for (const advice of wtAdvice.slice(1)) print(`         ${advice}`);
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
  // Recorded before the --json branch on purpose: a caller that asked for JSON is
  // taking the session over just as much as one reading the markdown, and an edge
  // that only exists on the text path would be missing exactly when a tool drives
  // this command.
  const lineage = recordTakeoverEdge(opts, r);
  // `writes` reaches the JSON branch even though the MARKDOWN branch carries only
  // the static caution. The two are different artifacts with different readers: a
  // brief is written by one session for a DIFFERENT one to open later, where a
  // measurement taken in this process says nothing about the anchor of the session
  // that will act on it — the static caution is the honest line there. `--json` is
  // read by the session that ran the command, in the process whose environment was
  // measured, so withholding the measurement made this the one single-selector
  // invocation carrying no write-anchor information at all.
  if (opts.json) return print(JSON.stringify({ ...r, git: g, diff: d, target, takeover: tv, lineage, writes: writeAnchor(r.wt), worktreeAdvice: worktreeAdvice(r), skipped: SKIPPED }, null, 2));
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
  L.push('1. Choose the working directory before anything else:');
  for (const advice of worktreeAdvice(r)) L.push(`   ${advice}`);
  L.push('');
  L.push('   Then, in whichever directory that decision names:');
  L.push('');
  L.push('```bash');
  L.push(`cd -- ${briefShellArg(r.wt)}`);
  L.push('```');
  L.push('2. Re-verify before trusting anything above: this is a snapshot, and the working tree may have moved since.');
  L.push('3. Restate the remaining work as a short plan and get the user\'s confirmation before editing.');
  if (tv.measuredLevel === 'BUSY') L.push(`4. ⚠️ **Hazard, not a veto** — ${tv.measuredReason} State it to the user in one line and take a single go/no-go before the first edit${tv.authorized ? ' — the authorization above was given when this brief was written, not here' : '; on yes, re-run this command with `--force`'}. Then take it over; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  else if (tv.measuredLevel === 'PROBABLY_FREE') L.push(`4. ${tv.measuredReason} Taking over is fine; tell the user not to type in that window, and check whether it still owns dev servers or ports.`);
  print(`TAKEOVER_TARGET: ${target}`);
  // ABOVE the fence, with the other provenance lines. SKILL.md instructs the model
  // to treat anything after `--- END ---` as untrusted text that happened to be in
  // the stream, so a write announcement emitted there is one the reader is told to
  // disbelieve — and this tool announcing its own write is the one line that must
  // land.
  print(`LINEAGE  ${lineage.message}`);
  print('--- BEGIN TAKEOVER MARKDOWN ---');
  print(L.join('\n'));
  print('--- END TAKEOVER MARKDOWN ---');
}

// The edge is recorded HERE, automatically, because forgetting this step is the
// exact failure the ledger exists to fix — a takeover that leaves no trace is
// indistinguishable from one that never happened. It is announced on its own line
// rather than done quietly: a read command that writes must say so. `--no-record`
// opts out for a genuine read-only inspection, and a session with no
// CLAUDE_CODE_SESSION_ID (a bare `node trail.mjs` outside Claude Code) records
// nothing rather than inventing an endpoint.
function recordTakeoverEdge(opts, row) {
  if (!opts.record) return { recorded: false, reason: 'opted-out', message: 'not recorded (--no-record)' };
  const me = selfIdentity();
  if (!me.sessionId) {
    return { recorded: false, reason: 'no-self-session-id', message: 'not recorded — this process has no CLAUDE_CODE_SESSION_ID, so the continuing session cannot be named' };
  }
  if (me.sessionId === row.sessionId) {
    return { recorded: false, reason: 'self-target', message: 'not recorded — the target is this same session' };
  }
  const reason = opts.reason || (row.stopCause && row.stopCause.error) || 'manual';
  let file;
  // `--force` is the flag that carries the user's approval onto the command line, so
  // it is the one spelling of `takeover` entitled to claim a completed handover.
  const tier = opts.force ? 'confirmed' : 'provisional';
  try { file = ledgerWrite(buildEdge(row, me, reason, 'takeover', tier, nowStamp())); } catch (e) {
    return { recorded: false, reason: 'write-failed', message: `NOT RECORDED — ${e && e.message ? e.message : 'write failed'}` };
  }
  return {
    recorded: true,
    reason,
    file: path.basename(file),
    message: `recorded ${sessionTag(row.sessionId)} → ${sessionTag(me.sessionId)} (reason: ${reason}) in ${path.basename(file)}`,
  };
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
  L.push('Choose the working directory before running this:');
  const hoLines = worktreeAdvice(r);
  for (let i = 0; i < hoLines.length; i++) {
    const line = hoLines[i];
    if (/^\s{2}git /.test(line)) { L.push('', '```bash', line.trim(), '```'); continue; }
    L.push(i === 0 ? `- ${line}` : `  ${line}`);
  }
  L.push('');
  L.push('The command below `cd`s into the directory this session RECORDED. That is not always');
  L.push('where the work should continue — when the advice above sends you elsewhere, change the');
  L.push('path before running it.');
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

// ── lineage / adopt / label ─────────────────────────────────────────────────

function cmdLabel(opts) {
  // `--self` is a parsed flag, so the label text is the FIRST positional there
  // and the SECOND when a key is named explicitly.
  const positional = opts._.slice(1);
  let target = '';
  let text = '';
  let kind = 'account';
  // The removal spelling names its key on the flag, so neither the --self probe nor
  // the positional split applies: `label --remove <key>` carries no text to read.
  // `--self` resolves its own kind because it names an identity rather than a
  // typed key; the two typed spellings decide theirs from the SHAPE, which is why
  // they wait until the value has been bounded below.
  let shapeRule = null;
  if (opts.remove !== null) {
    target = String(opts.remove).trim();
    // `<digits>` OR `<digits>@…`: the set path stores the QUALIFIED window key and
    // then ECHOES it, so an all-digits test sent a user who copied that echo into
    // the account namespace, where it reported "nothing was removed" while the
    // label sat on disk — the permanent state this verb exists to end.
    shapeRule = /^\d+(@|$)/;
  } else if (opts.self) {
    const me = selfIdentity();
    if (me.accountUuid) { target = me.accountUuid; kind = 'account'; }
    else if (me.appPid) { target = String(me.appPid); kind = 'window'; }
    if (!target) fail('--self could not resolve this session\'s account or window — run `lineage --diagnose`');
    text = positional.join(' ').trim();
  } else {
    target = String(positional[0] || '').trim();
    text = positional.slice(1).join(' ').trim();
    // A pid is not a uuid; the key kind is decided by shape rather than guessed.
    shapeRule = /^\d+$/;
  }
  if (!target) fail('usage: label <accountUuid|appPid|--self> <text>');
  // Bounded HERE, once, before anything else looks at it. Every reader resolves
  // `boundLabel(key)` (normalizeLabels bounds keys as well as values), so a raw key
  // that differs from its bounded form became a different key on the next read:
  // the set path reported success, the entry rendered under a name nothing typed,
  // and `--remove` could not name it either. The reserved-name refusal below now
  // compares the same value that will be stored, rather than a spelling that
  // collapses onto it afterwards.
  //
  // Refused rather than restored to the raw spelling. `|| target` made the bound a
  // no-op for exactly the input it exists to reject — a key of nothing but control
  // characters bounds to nothing, and the fallback then stored and PRINTED the raw
  // bytes, straight into the terminal a model reads back.
  const boundedTarget = boundLabel(target);
  if (!boundedTarget) fail('refusing that label key — it carries no usable character once control and format characters are removed');
  target = boundedTarget;
  // AFTER the bound, never before: the raw spelling and the stored one can disagree
  // about the shape, and deciding here on the raw value looked the key up in the
  // account namespace while it sat under windows — reporting "nothing was removed"
  // for a label the tool itself had just written.
  if (shapeRule) kind = shapeRule.test(target) ? 'window' : 'account';
  if (target === '__proto__' || target === 'constructor' || target === 'prototype') {
    fail(`refusing "${target}" as a label key — it names an object member, not an account`);
  }
  // Below the key guards and above the text one: a removal has a key to validate
  // and no text, so requiring text first would refuse every `--remove`.
  if (opts.remove !== null) return labelRemove(opts, target, kind);
  // Qualified on the SET path only. `--remove` keeps taking the bare pid, because
  // that is what the operator has to type — the incarnation half is machine state
  // they never saw and cannot reconstruct once the window is gone.
  if (kind === 'window') {
    const key = windowKey(target);
    if (!key) fail(`${target} names no running process — there is no window to label. Run \`instances\` to see the live ones.`);
    target = key;
  }
  if (!text) fail('usage: label <accountUuid|appPid|--self> <text>');
  // Bounded like every other rendered value: this label is machine-wide and is
  // interpolated into numbered chain lines every other session reads, so an
  // unbounded one could fabricate a line there.
  const bounded = boundLabel(text);
  if (!bounded) fail('label text is empty after trimming');
  const current = readLabels();
  // Refused rather than merged: the reader returns an EMPTY map for a file it
  // could not parse, so writing on top of that would replace every existing label
  // with the one being set.
  if (LABELS_UNREADABLE) {
    fail(`${LABELS_FILE} exists but could not be read — refusing to overwrite it; move it aside and re-run`);
  }
  // A newer schema reduces to an empty map on read, which is exactly what a write
  // would then replace the real labels with.
  if (LABELS_SCHEMA_MISMATCH) {
    fail(`${LABELS_FILE} was written by a different label schema — refusing to overwrite it; update the plugin or move it aside`);
  }
  // Landed through updateLabels, which owns the whole read-modify-write. The
  // caller-side version this replaces read here, merged here and wrote here, so two
  // windows labelling two different accounts lost one of them — and the process that
  // lost it printed success and exited 0. `current` above is still read, for the two
  // refusals it feeds; the merge itself runs on the copy updateLabels re-reads inside
  // its own bounded retry.
  let next;
  try {
    next = labelsSet((cur) => {
      // Object.assign onto the module's own maps: an object-literal spread would give
      // them Object.prototype back, and a `__proto__` key would then hit the inherited
      // setter, store nothing, and still be reported as written.
      const merged = emptyLabels();
      Object.assign(merged.accounts, cur.accounts);
      Object.assign(merged.windows, cur.windows);
      // Two namespaces: an account uuid is stable, an OS pid is reused after its
      // process exits. One flat map let a pid-keyed label silently rename an
      // unrelated window later, with no way to tell the two kinds apart in the file.
      if (kind === 'window') merged.windows[target] = bounded;
      else merged.accounts[target] = bounded;
      return merged;
    });
  } catch (e) {
    fail(`could not write ${LABELS_FILE}: ${e && e.message ? e.message : 'write failed'}`);
  }
  LABEL_CACHE = next;
  if (opts.json) return print(JSON.stringify({ labelled: target, kind, text: bounded, file: LABELS_FILE, skipped: SKIPPED }, null, 2));
  print(`labelled ${kind} ${target} → "${bounded}"   (${LABELS_FILE})`);
}

// The clear path. `label` has had a set path from the start and no way to undo it,
// so a label typed into the wrong window stayed on that account for every session
// that renders it, on every window of the machine. Namespace-aware, because `label`
// writes into two maps and a remove that swept both would clear an unrelated window
// whose pid happens to spell the same digits as the account key being cleared.
function labelRemove(opts, target, kind) {
  const current = readLabels();
  // The same two refusals the set path takes, and for the same reason: both land a
  // WHOLE document, so writing on top of a file this build could not read replaces
  // every label in it with the one edit being made.
  if (LABELS_UNREADABLE) {
    fail(`${LABELS_FILE} exists but could not be read — refusing to overwrite it; move it aside and re-run`);
  }
  if (LABELS_SCHEMA_MISMATCH) {
    fail(`${LABELS_FILE} was written by a different label schema — refusing to overwrite it; update the plugin or move it aside`);
  }
  const held = kind === 'window' ? current.windows : current.accounts;
  // Used only to decide whether to report "nothing was removed"; the DELETION below
  // recomputes its own set from the copy updateLabels re-reads, so an incarnation
  // added between the two reads is deleted rather than reported-and-kept.
  // A window key names an incarnation (`<pid>@<start>`) and the operator types the
  // bare pid, so every incarnation recorded under that pid goes — which is what
  // "forget this window" means to the person asking. The bare form is matched too,
  // and that is the only way a label written before the qualification existed can
  // ever be cleared: it no longer resolves, so nothing else would ever name it.
  const matches = kind === 'window'
    ? Object.keys(held).filter((k) => k === target || k.startsWith(`${target}@`))
    : (Object.prototype.hasOwnProperty.call(held, target) ? [target] : []);
  const present = matches.length > 0;
  // Reported, never smoothed into a success. A "removed" for a key that was never
  // there tells the operator that a label they can still see was cleared, and they
  // stop looking for the entry that is actually rendering it.
  if (!present) {
    if (opts.json) return print(JSON.stringify({ removed: false, key: target, kind, reason: 'not-labelled', file: LABELS_FILE, skipped: SKIPPED }, null, 2));
    return print(`no ${kind} label is recorded for ${target} — nothing was removed   (${LABELS_FILE})`);
  }
  let next;
  try {
    next = updateLabels(LABELS_FILE, (cur) => {
      const merged = emptyLabels();
      Object.assign(merged.accounts, cur.accounts);
      Object.assign(merged.windows, cur.windows);
      if (kind === 'window') {
        for (const k of Object.keys(merged.windows)) {
          if (k === target || k.startsWith(`${target}@`)) delete merged.windows[k];
        }
      } else delete merged.accounts[target];
      return merged;
    }, CONFIG_ROOT);
  } catch (e) {
    fail(`could not write ${LABELS_FILE}: ${e && e.message ? e.message : 'write failed'}`);
  }
  LABEL_CACHE = next;
  if (opts.json) return print(JSON.stringify({ removed: true, key: target, kind, reason: null, file: LABELS_FILE, skipped: SKIPPED }, null, 2));
  print(`removed the ${kind} label for ${target}   (${LABELS_FILE})`);
}

function cmdAdopt(opts) {
  const row = resolve(opts, opts._[1]);
  const me = selfIdentity();
  if (!me.sessionId) {
    fail('this process has no CLAUDE_CODE_SESSION_ID, so it cannot record itself as the continuing session');
  }
  if (me.sessionId === row.sessionId) fail('refusing to record a session as its own continuation');
  // `adopt` IS the confirmation verb — the documented step a user runs once they have
  // actually taken the session over — so it is entitled to `confirmed`.
  const edge = buildEdge(row, me, opts.reason || 'manual', 'adopt', 'confirmed', nowStamp());
  // Guarded exactly as the takeover path is: the same unwritable-ledger condition
  // must not kill one verb with a stack trace while its sibling reports it.
  let file;
  try { file = ledgerWrite(edge); } catch (e) {
    fail(`could not record the handover: ${e && e.message ? e.message : 'write failed'}`);
  }
  if (opts.json) return print(JSON.stringify({ recorded: edge, file, skipped: SKIPPED }, null, 2));
  print(`RECORDED  ${sessionTag(row.sessionId)} (${endpointLabel(edge.from)}) → ${sessionTag(me.sessionId)} (${endpointLabel(edge.to)})`);
  print(`          reason: ${edge.reason}   worktree: ${edge.to.worktree || '(unknown)'}`);
  print(`          ${path.join(LEDGER_DIR, file ? path.basename(file) : '')}`);
}

function lineageDiagnose(opts) {
  const probes = ccdStoreCandidates().map((c) => ({ ...c, exists: dirExists(c.dir) }));
  const resolved = probes.find((p) => p.exists) || null;
  const led = ledgerRead();
  const edges = led.edges;
  if (opts.json) {
    return print(JSON.stringify({
      configRoot: CONFIG_ROOT,
      configRootSource: opts.configDir ? '--config-dir' : (process.env.CLAUDE_CONFIG_DIR ? 'CLAUDE_CONFIG_DIR' : 'default'),
      ledgerDir: LEDGER_DIR,
      labelsFile: LABELS_FILE,
      edgeCount: edges.length,
      ledgerTruncated: led.truncated, ledgerError: led.directoryError,
      schemaNewer: led.schemaNewer,
      store: resolved,
      probes,
      platform: process.platform,
      processStartTimes: processStartTimeHealth(),
      skipped: SKIPPED,
    }, null, 2));
  }
  print(`PLATFORM     ${process.platform}`);
  print(`CONFIG ROOT  ${CONFIG_ROOT}   (${opts.configDir ? '--config-dir' : (process.env.CLAUDE_CONFIG_DIR ? 'CLAUDE_CONFIG_DIR' : 'default ~/.claude')})`);
  print(`LEDGER       ${LEDGER_DIR}   (${edges.length} edge record(s))`);
  { const t = truncatedNote(led); if (t) print(`LEDGER CAP   ${t}`); }
  if (led.directoryError) print(`LEDGER ERROR ${led.directoryError} — the count above is NOT a measurement of what exists.`);
  if (led.schemaNewer) print('LEDGER SCHEMA A record from a NEWER schema was refused; upgrade the plugin to read it.');
  print(`START TIMES  ${processStartTimeHealth()}`);
  print(`LABELS       ${LABELS_FILE}`);
  print('');
  print('DESKTOP STORE PROBES (first existing wins; only the macOS path is verified):');
  for (const p of probes) print(`  ${p.exists ? 'FOUND  ' : 'absent '} ${p.source}\n           ${p.dir}`);
  print('');
  if (!resolved) {
    print('No desktop store found, so no session can be attributed to an account.');
    print('Chains still render and still group by window (process ancestry).');
    print('If this machine DOES run the Claude desktop app, point ZENSU_CCD_STORE at its');
    print('claude-code-sessions directory — the Windows and Linux paths above are inferred,');
    print('not measured, and this is the command that shows which one was tried.');
  }
}

function lineageBackfill(opts) {
  // Unbounded unless the caller narrowed it explicitly. This verb exists to
  // reconstruct handovers from BEFORE the ledger, and the 21-day default excluded
  // exactly those while reporting "0 candidates" on a machine that has them.
  const days = opts.daysExplicit ? opts.days : 0;
  const { rows } = buildIndex({ ...opts, days, live: false });
  const led = ledgerRead();
  const existing = led.edges;
  // JSON-encoded, for the reason `dedupeEdges` gives: `>` survives boundText, so
  // two different pairs could spell one key. Here a collision suppresses a
  // legitimate candidate rather than minting a duplicate, but it is the same
  // defect and the module already states the rule.
  const pairKey = (e) => JSON.stringify([e.from.sessionId, e.to.sessionId]);
  const known = new Set(existing.map(pairKey));
  // The duplicate guard below is exactly as good as this read. An unreadable
  // directory yields an EMPTY `known` set, so every edge that IS already recorded
  // re-proposes and --apply mints a second copy machine-wide. The dry run still
  // renders — only the write is refused, and it says which half failed.
  // Per-RECORD refusals count too, not only the whole-directory failure: readEdges
  // drops an unreadable, malformed or wrong-schema record, and each one is a pair
  // missing from `known` above. The gate names which of the two it is, because the
  // remedies differ -- fix the directory, versus find the one bad record.
  const refusedCount = led.refused;
  // The cap belongs in this gate for the identical reason a refused record does:
  // `known` is built from THIS read, so a pair beyond the bound is missing from it
  // and --apply mints a second copy of an edge the machine already holds. The
  // refusal text below already made that argument for the per-record cause.
  const applyBlocked = Boolean(opts.apply && (led.directoryError || refusedCount > 0 || led.truncated));
  const applyRefusal = led.directoryError ? 'ledger-unreadable' : (refusedCount > 0 ? 'records-refused' : 'ledger-truncated');
  const stalled = rows.filter((r) => r.stopCause && r.stopCause.final);
  const candidates = [];
  for (const s of stalled) {
    // Ordered by last activity, and the start guard applies ONLY where a start is
    // actually observable. `r.live` is null for every finished session — the whole
    // population this verb reconstructs — so the previous `startedAt(r) >= s.mtime`
    // conjunct rejected nothing there while wrongly excluding a live window that
    // was already open when the stall happened. Stated rather than implied: a
    // transcript's first timestamp is not read here, so the "started after the
    // stall" claim is NOT established for finished sessions.
    const successor = rows
      .filter((r) => r.wt === s.wt && r.sessionId !== s.sessionId && r.mtime > s.mtime)
      .sort((a, b) => a.mtime - b.mtime)[0];
    if (!successor) continue;
    const fromAcct = (s.app && s.app.accountUuid) || null;
    const toAcct = (successor.app && successor.app.accountUuid) || null;
    // Same account is a resumption, not a handover — and two unknown accounts are
    // not evidence of a DIFFERENT one, so they are excluded too. A heuristic that
    // guessed here would mint edges nobody can distinguish from measured ones.
    if (!fromAcct || !toAcct || fromAcct === toAcct) continue;
    if (known.has(JSON.stringify([s.sessionId, successor.sessionId]))) continue;
    candidates.push({ from: s, to: successor });
  }
  if (opts.json && !opts.apply) {
    return print(JSON.stringify({
      dryRun: true,
      windowDays: days,
      candidates: candidates.map((c) => ({
        from: c.from.sessionId, to: c.to.sessionId, worktree: c.to.wt,
        cause: c.from.stopCause.error || 'rate_limit',
      })),
      ledgerTruncated: led.truncated, ledgerError: led.directoryError,
      schemaNewer: led.schemaNewer,
      skipped: SKIPPED,
    }, null, 2));
  }
  if (!opts.apply) {
    print(`BACKFILL DRY RUN — ${candidates.length} candidate edge(s), nothing written.`);
    print(`WINDOW ${days > 0 ? `${days} day(s)` : 'unbounded'}`);
    print('Each is a GUESS: a session that stalled on an API limit, and the next session on the');
    print('same worktree under a different account. Re-run with --apply to record them; they are');
    print('then marked inferred and rendered as such, so a guess never reads like a measurement.\n');
    for (const c of candidates) {
      print(`  ${sessionTag(c.from.sessionId)} (${endpointLabel(endpointFromRow(c.from))}) → ${sessionTag(c.to.sessionId)} (${endpointLabel(endpointFromRow(c.to))})`);
      // The absolute worktree and the same cause fallback the write uses: this is
      // the only review surface before --apply mints machine-wide inferred edges,
      // so it has to show what will actually be recorded.
      print(`      worktree: ${oneLine(c.to.wt, 200)}   cause: ${c.from.stopCause.error || 'rate_limit'}`);
    }
    if (!candidates.length) print('  (none)');
    return;
  }
  if (applyBlocked) {
    if (opts.json) {
      return print(JSON.stringify({
        dryRun: false, applied: false, refusal: applyRefusal,
        written: 0, files: [], writeError: null, refusedRecords: refusedCount,
        ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED,
      }, null, 2));
    }
    if (led.directoryError) print(`BACKFILL REFUSED — the ledger could not be read (${led.directoryError}).`);
    else if (refusedCount > 0) print(`BACKFILL REFUSED — ${refusedCount} ledger record(s) could not be read.`);
    else print(`BACKFILL REFUSED — ${truncatedNote(led)}.`);
    print('Nothing was written. The already-recorded edges could not be listed in full, so a');
    print('candidate above may already exist and --apply would mint a duplicate of it.');
    print(`Fix the ledger (${LEDGER_DIR}) and re-run; \`lineage --diagnose\` names what failed.`);
    return;
  }
  const written = [];
  let writeError = null;
  for (const c of candidates) {
    // Stamped from the SUCCESSOR's first observable activity, not from now: this edge
    // reconstructs a handover that happened when the stalled session went quiet and
    // the next one picked the worktree up. `c.to.mtime` is that session's last write,
    // which is the closest observable instant the transcripts offer — and any past
    // stamp is enough to stop a guess from outranking every measurement by
    // construction. Stated rather than implied: it is an approximation of when, not a
    // measurement of it, which is exactly why the edge is `inferred`.
    const occurredAt = new Date(c.to.mtime || c.from.mtime || Date.now()).toISOString();
    const edge = buildEdge(c.from, endpointFromRow(c.to), c.from.stopCause.error || 'rate_limit', 'backfill', 'inferred', occurredAt);
    // Reported, not abandoned: a batch that dies mid-way had already written real
    // records, and claiming none were written is the wrong half of the truth.
    try { written.push(path.basename(ledgerWrite(edge))); } catch (e) {
      writeError = e && e.message ? e.message : 'write failed';
      break;
    }
  }
  if (opts.json) return print(JSON.stringify({ dryRun: false, applied: true, refusal: null, written: written.length, files: written, writeError, refusedRecords: refusedCount, ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED }, null, 2));
  print(`BACKFILL APPLIED — ${written.length} inferred edge(s) recorded in ${LEDGER_DIR}`);
  if (writeError) print(`BACKFILL INCOMPLETE — stopped after ${written.length} edge(s): ${writeError}`);
}

// The record cap, in one sentence with one owner. Every payload carried the flag
// and no TEXT renderer did, so a ledger past the bound answered from a prefix and
// rendered exactly like a complete one — beside LEDGER ERROR and LEDGER SCHEMA
// lines that do disclose. Four hand-written copies would drift, and three of them
// saying it is not a disclosure.
// One owner for the "the read FAILED, so this is not an absence" answer, for the
// reason truncatedNote has one: the listing branch disclosed both causes while its
// `--where` sibling disclosed neither, so one ledger answered "no handover was
// recorded" through one code path and named the fault through the other — and the
// --where branch then closed with the reconstruction offer, the one line in this
// file that mints machine-wide guesses. Returns true when it rendered, so a caller
// knows to stop.
function renderLedgerFault(led) {
  if (led.directoryError) {
    print(`The ledger could not be read (${led.directoryError}) — this is NOT evidence that no handover was recorded.`);
    print(`Check ${LEDGER_DIR}, then re-run.`);
    return true;
  }
  if (led.schemaNewer) {
    print('The ledger holds records written by a NEWER schema than this build can read.');
    print('Update the plugin rather than treating this as an empty history.');
    return true;
  }
  return false;
}

function truncatedNote(led) {
  return led && led.truncated
    // "the first" was true while the reader sliced from the head. It now keeps the
    // NEWEST records, and this one owner feeds every truncation line the operator sees
    // — including BACKFILL REFUSED — so the sentence pointed at precisely the half that
    // was evicted.
    ? `only the most recent ${MAX_EDGE_RECORDS} record(s) were read — this is the newest slice of the ledger, not a measurement of it`
    : null;
}

// A migration is a fact about the STORE, so both callers ask the same question of
// the same quantity: does THIS BUILD's own directory hold nothing while a sibling
// schema directory holds something. Gating it on a repo-scoped count instead made
// a repo that simply has no handovers report machine-wide blindness while the
// current store held plenty for other repos — and suppressed the ordinary guidance
// while doing it. Returns true when it rendered, so a caller knows to stop.
//
// And it no longer EXTINGUISHES itself. Gated on `ownCount > 0` the notice fired only
// until the first record landed in the new store and then never again, while the old
// history sat beside it unread — the fact it reports is about the STORE and does not
// stop being true because one record has since been written. The full block still
// belongs to the empty-store case, where there is no other answer to give; once the
// current store answers for itself the disclosure shrinks to one line above that
// answer rather than replacing it.
function renderMigration(ownCount) {
  const foreign = otherSchemaLedgers(CONFIG_ROOT);
  if (!foreign.length) return false;
  if (ownCount > 0) {
    const held = foreign.reduce((n, f) => n + f.records, 0);
    print(`! ${held} record(s) live in another schema directory and are NOT read here — run \`lineage --diagnose\` for the paths.\n`);
    return false;
  }
  print('This build reads none of the records this machine already holds:\n');
  for (const f of foreign) print(`  v${f.version} (${f.relation} schema)   ${f.records} record(s)${f.truncated ? ' (bounded read)' : ''}   ${f.dir}`);
  print('');
  print('That is a MIGRATION, not an empty history. Do not reconstruct anything here —');
  print('a guess would duplicate a handover already recorded above as a measurement.');
  print(foreign.some((f) => f.relation === 'newer')
    ? 'A newer schema directory means this plugin is behind: update it, then re-run.'
    : 'Update the plugin, or move those records forward once a migration exists.');
  return true;
}

// The only verb in this file that DESTROYS a record, and the reason it exists: the
// store is append-only and machine-wide, so until now a mistaken takeover — or a
// guess `--backfill` minted — was permanent for every window on the machine, and
// the operator's only recourse was deleting a file whose name the tool never
// showed them. A dry run first, for the same reason `--backfill` has one.
function lineageForget(opts) {
  const want = String(opts.forget).trim().toLowerCase();
  // The same floor `--where` applies, and it carries more here: a prefix short
  // enough to match everything would empty the whole ledger from one typo.
  if (want.length < 6) fail('--forget needs a session id or a prefix of at least 6 characters');
  // NOT deduped. `dedupeEdges` collapses the rendered view to one line per pair;
  // forgetting a session has to reach every RECORD naming it, and the collapsed
  // view would leave the losers of that collapse behind — invisible and, because
  // nothing renders them, undeletable.
  const led = ledgerRead();
  const edges = led.edges;
  if (led.directoryError) {
    if (opts.json) {
      return print(JSON.stringify({
        mode: 'forget', query: opts.forget, dryRun: !opts.apply, applied: false, refusal: 'ledger-unreadable',
        matched: 0, removed: 0, files: [], failed: [], refusedRecords: led.refused,
        ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED,
      }, null, 2));
    }
    print(`FORGET REFUSED — the ledger could not be read (${led.directoryError}).`);
    print('Nothing was removed, and this is NOT evidence that no record names that session.');
    print(`Fix the ledger (${LEDGER_DIR}) and re-run; \`lineage --diagnose\` names what failed.`);
    return;
  }
  const startsWant = (id) => String(id || '').toLowerCase().startsWith(want);
  const hits = edges.filter((e) => startsWant(e.from.sessionId) || startsWant(e.to.sessionId));
  const distinctSet = new Set();
  for (const e of hits) {
    if (startsWant(e.from.sessionId)) distinctSet.add(e.from.sessionId);
    if (startsWant(e.to.sessionId)) distinctSet.add(e.to.sessionId);
  }
  const distinct = [...distinctSet];
  // Refused, never resolved. `--where` picks the first candidate and prints an
  // answer a reader can check; an unlink cannot be re-read afterwards, so an
  // ambiguous prefix has to stop the command rather than choose for the user.
  if (distinct.length > 1) {
    print(`ambiguous --forget "${opts.forget}" — ${distinct.length} candidates:\n`);
    for (const sid of distinct) print(`  ${sid}`);
    print('\nNothing was removed. Name one of them in full.');
    flush();
    process.exit(2);
  }
  const target = distinct[0] || null;
  const files = hits.map((e) => e.file).filter((f) => typeof f === 'string' && f);
  // Disclosed rather than blocking, unlike `--backfill`'s. A refused record is one
  // this command cannot see and therefore cannot remove, so the removal stays
  // correct for everything it did see — it is the COUNT that would otherwise read
  // as "that is all of them".
  // BOTH causes, because both mean the same thing to the operator: the count below
  // is not "all of them". A capped read is the worse of the two here — "N of N
  // record(s) removed" on a prefix is the most confident wrong sentence in the file.
  const notes = [];
  if (led.refused > 0) notes.push(`${led.refused} record(s) could not be read and were not examined — one of them may also name this session.`);
  { const t = truncatedNote(led); if (t) notes.push(`${t}, so records naming this session may remain beyond it.`); }
  const refusedNote = notes.length ? notes.join(' ') : null;
  if (!opts.apply) {
    if (opts.json) {
      return print(JSON.stringify({
        mode: 'forget', query: opts.forget, dryRun: true, applied: false, refusal: null,
        session: target, matched: files.length, removed: 0, files, failed: [],
        refusedRecords: led.refused, ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED,
      }, null, 2));
    }
    // Nothing matched is its own answer, not a zero-count dry run: pointing the
    // operator at --apply there names a destructive command that would do nothing,
    // and the offer is the one line of this output that carries a consequence.
    if (!files.length) {
      print(`No record names ${target || opts.forget}.`);
      if (refusedNote) print(`! ${refusedNote}`);
      return;
    }
    print(`FORGET (dry run) — ${files.length} record(s) name ${target || opts.forget}`);
    // Bounded like every persisted field, and for the identical reason: the name
    // comes off a directory every session on this machine can write, and these
    // lines are what an operator reads before authorising a deletion.
    for (const f of files) print(`  ${boundText(f)}`);
    if (refusedNote) print(`\n! ${refusedNote}`);
    print('\nNothing was removed. Re-run with --apply to remove them — the ledger is');
    print('machine-wide, so this takes them from every window and cannot be undone.');
    return;
  }
  const { removed, failed } = removeEdgeFiles(LEDGER_DIR, files, CONFIG_ROOT);
  if (opts.json) {
    return print(JSON.stringify({
      mode: 'forget', query: opts.forget, dryRun: false, applied: true, refusal: null,
      session: target, matched: files.length, removed: removed.length, files: removed, failed,
      refusedRecords: led.refused, ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED,
    }, null, 2));
  }
  print(`FORGET APPLIED — ${removed.length} of ${files.length} record(s) removed from ${LEDGER_DIR}`);
  for (const f of removed) print(`  removed ${boundText(f)}`);
  // Named individually rather than summed into the count above: "3 of 4" tells the
  // operator a record survived, not WHICH one, and the survivor keeps asserting a
  // handover they just asked to retract.
  for (const f of failed) print(`  ! kept ${boundText(f.file)} (${f.reason})`);
  if (refusedNote) print(`! ${refusedNote}`);
}

function cmdLineage(opts) {
  // The dispatch below is a first-match ladder, so before this guard
  // `--diagnose --backfill` ran the diagnostic and discarded the backfill without
  // a word — and a user who typed both read the output of whichever arm came
  // first as the answer to the other. That was survivable while every mode only
  // READ. `--forget` is not: paired with `--apply` it destroys records, and a
  // ladder that silently drops it prints a diagnostic while the removal the user
  // asked for never happened. `--where` is in the set for the same reason: it
  // selects a different rendering, and every mode above it ignores it.
  const modes = [];
  if (opts.diagnose) modes.push('--diagnose');
  if (opts.backfill) modes.push('--backfill');
  if (opts.forget !== null) modes.push('--forget');
  if (opts.where !== null) modes.push('--where');
  if (modes.length > 1) fail(`lineage takes one mode at a time — got ${modes.join(' and ')}`);
  // `--apply` is not a mode of its own: it turns a dry run into a write, and a mode
  // with no dry run to turn simply swallows it. Refused rather than dropped — the
  // user typed the flag that authorises a write, and hearing nothing back about it
  // reads as "applied".
  if (opts.apply && !opts.backfill && opts.forget === null) {
    fail('--apply has no effect on its own — it applies `lineage --backfill` or `lineage --forget <session>`');
  }
  if (opts.diagnose) return lineageDiagnose(opts);
  if (opts.backfill) return lineageBackfill(opts);
  if (opts.forget !== null) return lineageForget(opts);
  const led = ledgerRead();
  const edges = dedupeEdges(led.edges);
  const live = liveRegistry();
  const ctx = opts.all ? null : repoContext(opts.repo || process.cwd());
  // Absolute roots only. A basename arm made ~/work/clientA/api and
  // ~/work/clientB/api share one lineage scope — the collision SKILL.md already
  // documents for brief targets.
  // Canonicalized on both sides. A record stores the path as it was resolved when
  // the edge was written, and on macOS /var and /private/var name the same
  // directory — an uncanonical comparison silently scoped a repo's own handovers
  // out of its own listing.
  const canon = (v) => {
    if (!v) return null;
    try { return fs.realpathSync.native(v); } catch { return path.resolve(v); }
  };
  const ctxRoot = ctx ? canon(ctx.root) : null;
  const ctxTrees = ctx ? new Set([...ctx.worktrees].map(canon)) : null;
  const inScope = (e) => {
    if (!ctx) return true;
    if (!e.repo || !e.repo.root) return false;
    const r = canon(e.repo.root);
    // Containment as well as equality: nearestRepoRoot answers with a NESTED repo
    // or submodule when one exists, so an exact-match rule scoped a repo's own
    // handovers out of its own listing. The clientA/api vs clientB/api
    // discrimination survives, because both sides are absolute and canonical.
    return r === ctxRoot || ctxTrees.has(r) || (ctxRoot && r.startsWith(`${ctxRoot}${path.sep}`));
  };
  // Collapsed for every COUNT and every rendered line: the store is deliberately
  // append-only and re-running `takeover` is a documented routine step, so raw
  // record counts would report one handover twice.
  const scoped = dedupeEdges(edges.filter(inScope));
  const me = selfIdentity();

  if (opts.where) {
    const want = String(opts.where).trim().toLowerCase();
    // The same floor resolve() applies. Without it `--where " "` trims to an empty
    // prefix that startsWith matches for every edge, and the command then prints a
    // confident CONTINUED IN for a blank query.
    if (want.length < 6) fail('--where needs a session id or a prefix of at least 6 characters');
    const match = edges.filter((e) => e.from.sessionId.toLowerCase().startsWith(want) || e.to.sessionId.toLowerCase().startsWith(want));
    // Both endpoints per edge: preferring `from` hid the case where a single edge
    // has two endpoints sharing the queried prefix, and the walk then answered for
    // one of two candidates without saying so.
    const distinctSet = new Set();
    for (const e of match) {
      if (e.from.sessionId.toLowerCase().startsWith(want)) distinctSet.add(e.from.sessionId);
      if (e.to.sessionId.toLowerCase().startsWith(want)) distinctSet.add(e.to.sessionId);
    }
    const distinct = [...distinctSet];
    if (distinct.length > 1) {
      print(`ambiguous --where "${opts.where}" — ${distinct.length} candidates:\n`);
      for (const sid of distinct) print(`  ${sid}`);
      flush();
      process.exit(2);
    }
    if (!match.length) {
      if (opts.json) return print(JSON.stringify({ query: opts.where, found: false, otherSchemaLedgers: led.directoryError ? [] : otherSchemaLedgers(CONFIG_ROOT), ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED }, null, 2));
      // The same migration check the listing path takes. Without it this sibling
      // branch kept offering the reconstruction on a store the schema had moved out
      // from under — the exact offer the listing path stopped making, surviving one
      // code path over.
      // Ahead of the migration check and the offer below, both of which describe a
      // ledger that was actually READ.
      if (renderLedgerFault(led)) return;
      if (renderMigration(led.edges.length)) return;
      print(`No lineage recorded for "${opts.where}".`);
      print('Either that session was never handed over, or the handover predates the ledger.');
      { const t = truncatedNote(led); if (t) print(`! ${t}`); }
      print(`Try: node ${scriptPath()} lineage --backfill`);
      return;
    }
    // Walked from the QUERIED session, not from the predecessor of the matched
    // edge: starting at the `from` made a predecessor's newest branch the answer,
    // so a question about one session was answered with a sibling's continuation.
    const start = distinct[0];
    const walk = walkChain(start, edges);
    const links = walk.links;
    // A leaf has no outgoing edge, so the answer is the INCOMING edge's real
    // endpoint — a fabricated one printed "CONTINUED IN <the id you asked about>"
    // with an unknown worktree and no chain, discarding what the ledger holds.
    // The module's comparator, not a local one. `localeCompare` resolves the host
    // locale, so the order of a machine-wide ledger depended on the reader's ICU
    // build — and this sort decides which endpoint a leaf query answers with.
    const incoming = edges.filter((e) => e.to.sessionId === start)
      .sort(byRecordedAtAsc)
      .pop();
    const last = links.length ? links[links.length - 1].to
      : (incoming ? incoming.to : makeEndpoint({ sessionId: start }));
    const isLeaf = !links.length;
    if (opts.json) {
      return print(JSON.stringify({ query: opts.where, found: true, start, current: last, live: liveState(last.sessionId, live), links, forks: walk.forks, truncated: walk.truncated, revisited: walk.revisited, ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED }, null, 2));
    }
    print(`${isLeaf ? 'THIS IS THE END OF THE CHAIN' : 'CONTINUED IN'}  ${sessionTag(last.sessionId)}   ${endpointLabel(last)}   ${liveState(last.sessionId, live)}`);
    print(`WORKTREE      ${last.worktree || '(unknown)'}${last.branch ? `   branch ${last.branch}` : ''}`);
    if (last.pid) print(`PID           ${last.pid}${last.appPid ? `   window pid ${last.appPid}` : ''}`);
    print('');
    printChain(links, live, me, walk.forks);
    { const t = truncatedNote(led); if (t) print(`  ! ${t}`); }
    if (led.schemaNewer) print('  ! the ledger also holds records written by a NEWER schema than this build can read — update the plugin.');
    if (walk.truncated) print('  ! chain truncated at the hop bound — it is longer than shown');
    // `revisited` was computed and read by nobody, so the reset flow it exists for
    // — adopt A>B, then adopt B>A from the original window — still printed
    // CONTINUED IN with no caveat while the newest edge said the work had come back.
    if (walk.revisited) print('  ! the work came back to a session already in this chain — the line above is where the walk stopped, not where the work is');
    return;
  }

  if (opts.json) {
    // The walk `chainWalks` already performed to decide the roots, reused rather
    // than repeated. It owns the index too — it needs the edge ORDER for root
    // discovery, and taking both an array and a prebuilt index let the two disagree
    // about which ledger was walked. Re-walking here was not only the wasted pass:
    // it made the root decision and the rendered chain two independent traversals.
    const { roots: chainRootIds, walks: chainWalkById } = chainWalks(scoped);
    const chains = chainRootIds.map((root) => {
      const w = chainWalkById.get(root);
      // Both bounds travel with the chain. The --where rendering carries them and
      // this one dropped them, so the reset flow (adopt A>B, then adopt B>A) and a
      // chain past the hop bound both rendered here as complete.
      return { root, links: w.links, forks: w.forks, truncated: w.truncated, revisited: w.revisited };
    });
    // Keyed on the OWN store, not on the repo-scoped view: "this build reads none
    // of the records this machine holds" is a claim about the store, and a repo
    // with no handovers of its own is not evidence for it. Computed only when the
    // own store is empty, which keeps a directory read off every ordinary call.
    return print(JSON.stringify({ repo: ctx && ctx.root, chains, edgeCount: scoped.length, otherSchemaLedgers: led.directoryError ? [] : otherSchemaLedgers(CONFIG_ROOT), ledgerTruncated: led.truncated, ledgerError: led.directoryError, schemaNewer: led.schemaNewer, skipped: SKIPPED }, null, 2));
  }
  print(`SCOPE  ${ctx ? `${ctx.name} (${ctx.root})` : 'ALL REPOS'}`);
  print(`RECORDED HANDOVERS: ${scoped.length}\n`);
  { const t = truncatedNote(led); if (t) print(`! ${t}\n`); }
  // Above the split, not inside the empty arm. A NEWER-schema record is refused
  // individually while its neighbours parse, so a non-empty listing was rendered
  // with no hint that this build cannot read part of the store — the generic
  // skipped NOTE names no cause and no remedy.
  // Gated on a NON-empty result: below the split, renderLedgerFault owns the same
  // sentence for the empty arm, and printing both made that one branch say it twice
  // — the "one owner" rule failing in the direction of noise rather than silence.
  if (scoped.length && led.schemaNewer) print('! the ledger also holds records written by a NEWER schema than this build can read — update the plugin.\n');
  if (!scoped.length) {
    if (renderLedgerFault(led)) return;
    // A schema move leaves every existing record under the PREVIOUS `v<n>/`
    // directory, invisible to this build. Saying "nothing was recorded" there — and
    // then offering to reconstruct guesses — would mint inferred edges for handovers
    // the machine still holds as measurements, one directory away. That is the worst
    // outcome the confidence axis exists to prevent, reached by a command this tool
    // itself recommends. The reconstruction offer below is deliberately NOT printed
    // on that branch.
    if (renderMigration(led.edges.length)) return;
    print('No handover has been recorded yet.');
    print(`Past ones can be reconstructed as GUESSES: node ${scriptPath()} lineage --backfill`);
    return;
  }
  // The disclosure belongs on THIS path too. `renderMigration` was reachable only from
  // the empty-scope branch above, so as soon as the current store could answer for
  // itself the fact that a foreign schema directory still holds unread history stopped
  // being mentioned at all — the decay this notice must not have.
  renderMigration(led.edges.length);
  const { roots: textRootIds, walks: textWalkById } = chainWalks(scoped);
  for (const root of textRootIds) {
    const { links, forks, truncated: walkTruncated, revisited } = textWalkById.get(root);
    if (!links.length) continue;
    const wt = links[0].to.worktree || links[0].from.worktree;
    print(`CHAIN  ${links[0].repo && links[0].repo.name ? links[0].repo.name : '(unknown repo)'}${wt ? `   ${path.basename(wt)}` : ''}`);
    printChain(links, live, me, forks);
    if (walkTruncated) print('  ! chain truncated at the hop bound — it is longer than shown');
    if (revisited) print('  ! the work came back to a session already in this chain — the line above is where the walk stopped, not where the work is');
    print('');
  }
}

function printChain(links, live, me, forks = []) {
  if (!links.length) return;
  for (const f of forks) {
    print(`  ! ${sessionTag(f.at)} was taken over more than once — following ${sessionTag(f.taken)}, also recorded: ${f.alsoTo.map((s2) => sessionTag(s2)).join(', ')}`);
  }
  const seq = [links[0].from, ...links.map((l) => l.to)];
  seq.forEach((ep, i) => {
    const edge = i === 0 ? null : links[i - 1];
    const here = me.sessionId && ep.sessionId === me.sessionId ? '   ← HERE' : '';
    // One annotation per non-confirmed tier, and NONE for `confirmed` — an ordinary
    // link must stay quiet or the marker means nothing. `provisional` is the case
    // this rendering exists for: `takeover` writes its edge while it generates the
    // brief, before the user has been asked to confirm, so without a marker a
    // declined takeover reads exactly like a completed one.
    const tier = edge ? confidenceNote(edge) : '';
    print(`  ${String(i + 1).padStart(2)}. ${sessionTag(ep.sessionId)}   ${endpointLabel(ep).padEnd(26)} ${liveState(ep.sessionId, live).padEnd(12)}${here}`);
    if (ep.worktree) print(`      ${ep.worktree}${ep.branch ? `   ${ep.branch}` : ''}`);
    if (edge) print(`      handed over ${String(edge.recordedAt || '').slice(0, 16)}   reason: ${edge.reason}${tier}`);
  });
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
// fileURLToPath, not URL.pathname: the latter is percent-encoded and carries a
// leading slash before a Windows drive letter, so the printed hint was unusable
// there and on any path containing a space.

// A test seam, and a narrow one: it reads a table from stdin, runs the ancestry rule
// against it and returns the answer. It touches no process table, no store and no
// file. It exists because the live tree cannot be arranged into the shapes that
// decide the rule — a helper hop between the session and the app, a chain with no
// Claude ancestor, the hop bound — and the real probe resolves an absolute
// interpreter path by design, so no PATH shim can stand in for it.
function windowProbe(raw) {
  let spec;
  try { spec = JSON.parse(raw); } catch { return { error: 'probe input is not JSON' }; }
  if (!spec || !Array.isArray(spec.table) || !Number.isFinite(spec.pid)) {
    return { error: 'probe needs { pid: <number>, table: [{ pid, ppid, comm }] }' };
  }
  const table = new Map();
  for (const row of spec.table) {
    if (!row || !Number.isFinite(row.pid) || !Number.isFinite(row.ppid)) continue;
    table.set(row.pid, { ppid: row.ppid, comm: String(row.comm || '') });
  }
  return { appPid: windowOf(spec.pid, table) };
}

function scriptPath() { return fileURLToPath(import.meta.url); }

const argv = process.argv.slice(2);
const opts = parseArgs(argv);
const cmd = opts._[0] || 'list';
// Keyed to whether a JSON payload is actually EMITTED, not to the flag:
// handoff ignores --json and always emits markdown, so suppressing the note
// there would drop the count on every channel at once.
JSON_MODE = opts.json && cmd !== 'handoff';
// Roots are resolved before any command runs, never at module load: --config-dir
// is only known once argv is parsed, and a command that read the default root first
// would write its ledger into ~/.claude while reading sessions from elsewhere.
resolveRoots(opts.configDir);
// The two tables are adjacent because the invariant between them is the whole
// point: every dispatched command needs a flag row, or it accepts every flag in
// the namespace again. Keys drive the usage string too, so a tenth command cannot
// be added to one and forgotten in the other.
const COMMANDS = {
  list: cmdList,
  instances: cmdInstances,
  show: cmdShow,
  handoff: cmdHandoff,
  limited: cmdLimited,
  takeover: cmdTakeover,
  lineage: cmdLineage,
  adopt: cmdAdopt,
  label: cmdLabel,
  'window-probe': (opts) => print(JSON.stringify({ ...windowProbe(fs.readFileSync(0, 'utf8')), skipped: SKIPPED }, null, 2)),
};

// The flag namespace is global — parseArgs accepts every flag for every command —
// while the rules about them lived inside two handlers. The dispatcher routes NINE,
// so `takeover x --forget y --apply` parsed both, recorded an edge, and named
// neither: exactly the silence the mode-exclusivity guard refuses INSIDE `lineage`,
// surviving one layer up. The rule belongs where the command name is decided.
//
// `--force` on `list` and `limited` is a DOCUMENTED deliberate ignore — one
// session's approval is not approval for every busy row in a survey — so it is
// listed there rather than refused. `instances` emits no verdict at all, so it
// has no such contract to keep and refuses it.
//
// Ten of the eighteen flags were scoped and eight were not, so `--json`, `--all`,
// `--live`, `--no-git`, `--config-dir`, `--days`, `--prompts` and `--repo` were
// accepted by every verb and quietly ignored by the ones that never read them:
// `lineage --days 3` answered machine-wide while the user believed they had asked for
// a three-day window. SKILL.md states the refusal is general with two exceptions, so
// the gap was a promise the code did not keep.
//
// `--config-dir` is consumed by `resolveRoots` before dispatch and `--json` selects the
// output shape, so both are read by every verb; listing them ten times would be ten
// copies of one row.
const GLOBAL_FLAGS = ['--json', '--config-dir'];

// The SCAN flags: `buildIndex` keys its cache on exactly these, so any verb reaching it
// — directly, or through `resolve()` — genuinely reads them. `--live` is NOT among
// them, because only `list` passes it through; every other caller forces `live: false`.
const SCAN_FLAGS = ['--all', '--repo', '--days', '--no-git'];

const COMMAND_FLAGS = {
  list: ['--force', ...SCAN_FLAGS, '--live'],
  instances: [...SCAN_FLAGS],
  show: ['--force', ...SCAN_FLAGS, '--prompts'],
  handoff: ['--force', ...SCAN_FLAGS],
  limited: ['--force', ...SCAN_FLAGS],
  takeover: ['--force', '--no-record', '--reason', ...SCAN_FLAGS, '--prompts'],
  // `--days` is deliberately absent: the listing branch reads `opts.all` and
  // `opts.repo` and nothing else from the scan set.
  lineage: ['--diagnose', '--backfill', '--forget', '--where', '--apply', '--all', '--repo'],
  // `adopt` IS the record, so `--no-record` would leave a verb whose entire
  // output is suppressed. It used to be accepted and then ignored, which wrote the
  // machine-wide record the flag said it was skipping.
  adopt: ['--reason', ...SCAN_FLAGS],
  // No selector scan at all: a label is keyed by account or window, so `resolve()` is
  // never reached and none of the scan flags decides anything here.
  label: ['--remove', '--self'],
  'window-probe': [],
};

function refuseForeignFlags(opts, cmd) {
  const mine = COMMAND_FLAGS[cmd];
  // Fail closed rather than `|| []`: a command present in COMMANDS and missing
  // from COMMAND_FLAGS would otherwise silently accept every flag, which is the
  // defect this function exists to remove.
  if (!mine) fail(`internal: \`${cmd}\` has no flag table`);
  const accepted = [...GLOBAL_FLAGS, ...mine];
  const supplied = [];
  // Every flag `parseArgs` sets, in its declaration order. A flag missing from this
  // list is accepted by every verb and silently ignored by the ones that do not read
  // it, which is exactly the defect this function exists to remove — so the two lists
  // have to stay the same length.
  if (opts.json) supplied.push('--json');
  if (opts.all) supplied.push('--all');
  if (opts.live) supplied.push('--live');
  if (!opts.git) supplied.push('--no-git');
  if (opts.configDir !== null) supplied.push('--config-dir');
  // The two numeric operands are reported only when the user actually typed them:
  // both carry a default, so presence cannot be read off the value.
  if (opts.daysExplicit) supplied.push('--days');
  if (opts.promptsExplicit) supplied.push('--prompts');
  if (opts.repo !== null) supplied.push('--repo');
  if (opts.diagnose) supplied.push('--diagnose');
  if (opts.backfill) supplied.push('--backfill');
  if (opts.apply) supplied.push('--apply');
  if (opts.self) supplied.push('--self');
  if (opts.force) supplied.push('--force');
  if (!opts.record) supplied.push('--no-record');
  if (opts.reason !== null) supplied.push('--reason');
  if (opts.forget !== null) supplied.push('--forget');
  if (opts.remove !== null) supplied.push('--remove');
  if (opts.where !== null) supplied.push('--where');
  const foreign = supplied.filter((f) => !accepted.includes(f));
  if (foreign.length) fail(`${foreign.join(' and ')} is not a flag of \`${cmd}\` — it would have been parsed and then ignored`);
}

// The unknown-command refusal stays FIRST: a typo must be reported as a typo, not
// as a flag that does not belong to the command the user did not name.
const handler = Object.prototype.hasOwnProperty.call(COMMANDS, cmd) ? COMMANDS[cmd] : null;
if (!handler) fail(`unknown command: ${cmd} (${Object.keys(COMMANDS).join(' | ')})`);
refuseForeignFlags(opts, cmd);
handler(opts);
flush();
