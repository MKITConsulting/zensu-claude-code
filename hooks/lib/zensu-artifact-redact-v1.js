#!/usr/bin/env node
// zensu-artifact-redact-v1.js — the single source of truth for what makes a
// .zensu run artifact safe to commit.
//
// Consuming repos commit `.zensu/plans/{ts}_tdd-{slug}.md` and
// `.zensu/logs/{ts}_tdd-{slug}.log` as an audit trail. A scan of ~27k committed
// log lines across four such repos found no credential values and ~436 lines
// carrying an absolute developer path — `/Users/<name>/…` — which entered
// mostly through the `cmd="…"` field of CHECKPOINT/AUDIT lines, because that
// field quotes a shell command verbatim and those commands routinely begin
// `cd "/Users/<name>/IdeaProjects/<product>/<repo>/.claude/worktrees/<name>"`.
//
// So this module rewrites LOCATIONS, never identifiers. It deliberately does
// NOT touch secret NAMES: a name grants no access, this repo's own workflows
// carry `secrets.GITHUB_TOKEN` in public, and redacting names would only make
// the audit trail harder to read. Credential VALUES are a different problem
// with a different owner — hooks/lib/secret-patterns.js.
//
// THREE RULES, applied in this order, and the order is load-bearing:
//
//   1. the project root(s) -> `<project>`
//   2. $HOME               -> `~`
//   3. a residual home-prefix (`/Users/<seg>`, `/home/<seg>`, `/root`,
//      plus the Windows `\Users\<seg>` spelling) -> `<home>`
//
// Rule 1 must precede rule 2 because the project root is normally NESTED under
// $HOME; running them the other way leaves `~/IdeaProjects/<product>/<repo>`,
// which still names the product. Rule 3 is what makes the guarantee TOTAL
// rather than best-effort: another machine's home directory, or a checkout
// outside this $HOME, is caught by nothing else, and it is what
// tests/structure/test-artifact-redaction.sh can assert against — "the file
// contains no `/Users/`" is checkable, "the file contains no path that happens
// to be sensitive" is not.
//
// `projectRoot` accepts an ARRAY because two writers have to agree byte-for-byte
// or `zensu-evidence-crosscheck.js` reports an EVIDENCE GAP, and they derive the
// root from different authorities: the log writer from the artifact path, the
// witness hook from the Session Control record.
//
// State the actual wiring, not the ideal: each writer passes ITS OWN authority
// plus `CLAUDE_PROJECT_DIR` when that is set. Neither array carries the other
// writer's authority, so agreement rests on the two coinciding — which they do
// whenever the log is written from the session root, the shape the skill
// prescribes. A cwd elsewhere normally makes `append` REFUSE
// (`artifact-directory-unresolvable`) rather than diverge silently; a silent
// divergence needs a second `.zensu/logs` under a non-root cwd. Narrow, and
// named rather than papered over.
//
// The rule is TEXTUAL and that bound is real: a path spelled through a symlink
// or a shell alias that does not match a known root is not caught, and a git
// repository root ABOVE the project root is redacted only insofar as $HOME
// covers it.
//
// It is also a rule about PATHS, and identifiers reach these artifacts by other
// routes. A developer or organisation login appearing outside a path survives
// untouched — a `git config user.name`, an author line quoted from `git log`, an
// email address, a `github.com/<org>/<repo>` URL, a branch name carrying a
// person's name, a hostname in a `cmd=` field. Rule 1 removes the login when it
// is a directory segment of the project root and rule 3 removes it when it is the
// home segment; neither can see it anywhere else. That is a refusal to guess, not
// an oversight: a name has no pattern, and a regex that tried would either miss
// most of them or eat ordinary words out of the audit trail. The authoring rules
// in `skills/tdd/SKILL.md` carry this half, and they have to. Both roots are matched in their given AND `realpath` spellings,
// which closes the one alias that shows up on every macOS run (`/var/folders/…`
// against `/private/var/folders/…`).
//
// Substitution is bounded on BOTH sides in EVERY rule, not a bare substring
// replace: a match must start where a path can start and end where a segment
// can no longer continue. Without the right bound a home of `/h` rewrites the
// word `/hello` and `/homework` becomes `<home>work`; without the left bound
// the residual rules fire inside `src/home/index.ts`.
//
// CLI:
//   node zensu-artifact-redact-v1.js --file <artifact> --project <root> [--home <dir>]
//
// Every entry point is CONTAINED: the path it is given must resolve to a real
// `<root>/.zensu/{plans,logs}/<file>`, verified by canonicalizing the parent
// directory, and it refuses otherwise. `writeArtifactLine` narrows that further
// to the `logs` bucket and refuses the witness file, because `mode: 'replace'`
// truncates and would otherwise destroy a committed plan or the evidence the
// Phase-6 crosscheck matches against. Without containment this module is a write
// primitive with a caller-supplied destination that no Bash gate can see,
// because it carries none of the redirect/tee/heredoc tokens
// `bash-source-write-parse.js` recognizes as a channel.
//
// Both readers and the writer open with `O_NOFOLLOW`, judge the DESCRIPTOR
// (`isFile`, `nlink === 1`) rather than the path, and compare its dev/ino against
// the location re-derived from the canonical parent. `O_NOFOLLOW` binds the final
// component; the dev/ino comparison catches an intermediate-directory swap one
// component higher. Both are still CHECK-THEN-USE: they narrow the window from a
// one-shot symlink plant to a rename race against a real directory, and only
// `openat`-style semantics — which Node does not expose — would close it.
// The same is true of `redactFile`'s pre-rename re-stat and of
// `writeArtifactLine`'s single `writeFileSync`, which can leave a partial line
// on ENOSPC. Accepted gaps, stated rather than implied.
//
// A no-op redaction writes NOTHING. The reason is local and mundane — no
// gratuitous rename churn, and a `tail -f` on the run log keeps following
// across the inode swap. It is NOT, as an earlier revision of this comment
// claimed, protection for the Phase 6 mtime audit: that audit
// (`hooks/lib/zensu-edit-landing.sh`) stats claimed source paths and never
// reads a `.zensu/` artifact at all.
//
// Exit 0 on success (including a no-op), 2 on a usage error or a refused
// target. Callers that must never fail closed ignore the code; `zensu-log.sh
// append` does not, because a lost log line is worse than a loud refusal.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const { msysDrivePrefix } = require('./claude-path-v1.js');

const PROJECT_PLACEHOLDER = '<project>';
const HOME_PLACEHOLDER = '~';
const RESIDUAL_PLACEHOLDER = '<home>';

// The artifact layout, owned here. Its consumers are IN THIS FILE —
// `sweepTargets` builds the two bucket directories from it and
// `projectRootFromArtifactPath` validates against it — and
// `hooks/post-artifact-redact.sh` consumes it TRANSITIVELY, by calling those
// functions instead of joining `.zensu/plans` and `.zensu/logs` itself. An
// earlier revision of this comment said the hook consumes the table directly; it
// does not, and never imported it.
const ARTIFACT_BUCKETS = { plans: '.md', logs: '.log' };
const ARTIFACT_DIR = '.zensu';

// The witness log's file-name prefix. Its WRITER is hooks/post-bash-witness.sh;
// this constant exists so the sweep can exclude it without a second spelling,
// and tests/structure/test-artifact-redaction.sh pins the pair.
const WITNESS_PREFIX = 'witness-';

// Case-insensitive, for the same reason the refusal is: the filesystem may not
// distinguish the spellings, so a case-sensitive test fails open on one side and
// sweeps a file it should skip on the other.
function isWitnessName(name) {
  return typeof name === 'string' && name.toLowerCase().startsWith(WITNESS_PREFIX);
}

// How far back the Bash sweep looks. A consuming repo can hold hundreds of
// tracked plans; an append worth catching is seconds old.
//
// What the window bounds is the WORK — which artifacts are read and redacted —
// and NOT the enumeration. An earlier revision of this comment, of the hook
// header and of the `docs/configuration.md` row all said the window is what
// keeps the sweep cheap, and none of the three was true: an entry's mtime is
// not knowable without a stat, so every candidate regular file costs one
// syscall before the cutoff can reject it. `sweepTargets` rejects what it can
// reject for free (wrong extension, and — through `withFileTypes` — anything
// that is not a regular file), and `SWEEP_MAX_TARGETS` bounds the rest.
const SWEEP_WINDOW_SECONDS = 300;

// How many artifacts one sweep may process. A `git checkout` refreshes every
// tracked artifact mtime at once, so without a cap the next tool call redacts
// all of them synchronously inside a PostToolUse hook, which declares no
// timeout of its own.
//
// Newest first, because a fresh unredacted append is what the sweep exists to
// catch and the newest mtime is the best available proxy for it. Nothing is
// lost by the cap on its own terms: an artifact left over stays in the window
// for the next pass, and the file the tool call just WROTE is prepended by
// `hooks/post-artifact-redact.sh` as the named target, so it can never be the
// one the cap drops.
//
// Accepted bound, stated rather than implied: a checkout that refreshes more
// than this many artifacts inside one window, followed by fewer tool calls than
// it takes to drain them, leaves the tail unswept until something touches it
// again. Bounding a hook's synchronous work is worth that.
const SWEEP_MAX_TARGETS = 25;

// 8 MiB. A narrative log that large is pathological; refusing to load it is
// better than an out-of-memory kill inside a PostToolUse hook. The refusal is
// REPORTED, never silent — an oversized artifact that shipped unredacted with
// nothing recording it would be the worst outcome this module can produce.
const MAX_BYTES = 8 * 1024 * 1024;

// A match must start where a path can start and end where a path segment can
// no longer continue. The left class holds only characters that can be part of
// a segment NAME — `/` and `\` are deliberately absent from it, so
// `file:///Users/x` still matches while `src/home/index.ts` does not.
const LEFT = '(?<![A-Za-z0-9_.\\-])';
const BOUNDARY = '(?![A-Za-z0-9_.\\-])';

// Rule 3. Each alternative consumes the prefix AND its user segment, so
// `/Users/other/x` becomes `<home>/x` rather than `<home>/other/x`. The
// optional-segment form also catches a bare `/Users` and a trailing `/Users/`,
// which a `+` quantifier would leave behind.
//
// Three properties of the segment class are load-bearing.
//
// It excludes quotes, so `cmd="ls /home/otherdev"` keeps its closing `"` —
// consuming it desynchronizes the claim from the witness entry and produces the
// very EVIDENCE GAP the witness redaction exists to prevent.
//
// It excludes the STRUCTURAL characters a path never contains but prose around
// one routinely does. An earlier spelling excluded only the separators,
// whitespace and quotes, so `;`, `:`, `,`, `)` and `]` were all valid segment
// characters and the greedy quantifier ran past the end of the path: `cd
// /home/runner;ls -la` redacted to `cd <home> -la`, DELETING the command that
// followed. That is a fidelity defect rather than a redaction gap — the output
// removes more than the identifier — and it lands in an artifact consuming repos
// commit as evidence.
//
// The trade-off here was decided deliberately: excluding structural characters
// keeps a NON-ASCII user segment working (`/Users/josé` still redacts whole),
// where narrowing to a `[A-Za-z0-9_.-]` name alphabet — which would agree with
// BOUNDARY by construction — would have left the `é` behind, i.e. a partial name
// in the published artifact. Readability of the rule was not worth that.
//
// It refuses to END on a `.`, which is why the class is written as a run of
// permitted characters closing on a non-dot one. A trailing period is far more
// often the end of a sentence than part of a directory name, and BOUNDARY counts
// `.` as a name character — so consuming it would have eaten `the checkout at
// /home/runner.` down to `… <home>`. An interior dot is untouched, so
// `/Users/first.last` still redacts whole.
const SEGMENT_CHAR = '[^/\\\\\\s"\';:,()\\[\\]{}|&<>]';
const SEGMENT = '(?:' + SEGMENT_CHAR + '*(?![.])' + SEGMENT_CHAR + ')?';
// ONE separator alternation, used in BOTH positions of every rule. The escaped
// spellings are matched too: a JSON-encoded command — which is exactly what the
// witness writes, and what a `cmd="…"` field carries — renders a Windows path as
// `C:\\Users\\bob`, and matching a single separator there consumed the prefix but
// left `bob` behind. Same for an escaped solidus.
//
// It is one alternation rather than a POSIX rule and a Windows rule because two
// rules could not CROSS forms: with `SEP_POSIX` in both positions of one and
// `SEP_WIN` in both of the other, a mixed spelling matched the prefix, failed the
// optional-segment group on the other separator, and satisfied BOUNDARY on it —
// so `C:/Users\bob` became `C:<home>\bob`. Output that LOOKS redacted and still
// names the developer is worse than a miss: it satisfies the assertable
// guarantee ("the file contains no `/Users/`") while publishing the identifier.
// Unifying also closes a gap the split left open — `\home` and `\root` had no
// Windows alternative at all.
//
// ALTERNATION ORDER IS LOAD-BEARING: the escaped solidus comes first. JS
// alternation is first-match, not longest-match, so with `\\{1,2}` leading, the
// backslash of an escaped `\/` matched as a Windows separator on its own, the
// segment then started at `/` — which the segment class excludes — and matched
// empty. `\/Users\/bob` collapsed to `<home>/bob`, leaving the name behind
// through the very spelling the escaped forms exist to catch.
const SEP_ANY = '(?:\\\\?\\/|\\\\{1,2})';
// Rule 3 additionally refuses to fire immediately after a placeholder rules 1-2
// just emitted. `LEFT` excludes only segment-name characters, and `>` and `~` are
// not among them — so `<project>/home/config.yml`, a perfectly ordinary in-project
// directory named `home`, matched and collapsed to `<project><home>`. The rules
// cannot simply be reordered: rule 3 would then consume `/Users/m` before rule 1
// could match the longer `/Users/m/proj`.
const NOT_AFTER_PLACEHOLDER = '(?<!' + PROJECT_PLACEHOLDER + ')(?<!'
  + RESIDUAL_PLACEHOLDER + ')(?<!' + HOME_PLACEHOLDER + ')';
// BOUNDARY guards the NO-segment alternative only, and that placement is the
// point. Its job is to stop `/home` matching inside `/homework`, which is a
// question about what follows the PREFIX. Once a separator and a segment have
// matched, the segment class itself defines where the match stops — appending
// BOUNDARY there as well is what let the greedy old class run past `runner` and
// still satisfy the lookahead on the space that followed.
//
// The prefix literals are named ONCE and interpolated into the rules, because
// `redact`'s fast path scans for the same literals to decide whether any rule
// could fire. A prefix spelled twice would eventually be added to one side only,
// and the failure direction there is silent: the fast path would skip a text the
// rules would have redacted.
const RESIDUAL_HOME_PREFIXES = ['Users', 'home'];
const RESIDUAL_ROOT_PREFIX = 'root';
const RESIDUAL_PREFIXES = [...RESIDUAL_HOME_PREFIXES, RESIDUAL_ROOT_PREFIX];
const RESIDUAL_RULES = [
  new RegExp(NOT_AFTER_PLACEHOLDER + LEFT + SEP_ANY
    + '(?:' + RESIDUAL_HOME_PREFIXES.join('|') + ')'
    + '(?:' + SEP_ANY + SEGMENT + '|' + BOUNDARY + ')', 'g'),
  new RegExp(NOT_AFTER_PLACEHOLDER + LEFT + SEP_ANY + RESIDUAL_ROOT_PREFIX + BOUNDARY, 'g'),
];

// Windows has no O_NOFOLLOW, and the OR-zero coercion form is the one
// tests/structure/test-windows-portability-guards.sh forbids, because it hides
// an undefined constant behind a default. That pin is a plain grep over the
// whole file, so no comment here may spell the forbidden form either.
function platformNoFollow() {
  return process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW : 0;
}
// A FIFO parked at an artifact path would otherwise block the open forever, and
// the not-a-file check runs only AFTER the open returns.
const NON_BLOCK = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// The MSYS drive spelling of a native Windows path, or null.
//
// The forward direction (MSYS -> drive) is the shared rule in
// claude-path-v1.js. The INVERSE is hand-built here, because that module
// exports no inverse — so this is a hand-copy, stated plainly rather than
// described as delegation. `msysDrivePrefix` is used as the VALIDATOR: the
// candidate is accepted only when the shared rule maps it back onto the drive
// spelling it came from. Consequence worth knowing: if the shared rule ever
// changes, the round trip stops matching and the MSYS spelling silently drops
// out of `rootSpellings` — a root that is then not redacted in that one
// spelling, with no error. Keep the two in step by hand.
function msysSpelling(value) {
  const drive = /^([A-Za-z]):[\\/](.*)$/.exec(value);
  if (!drive) return null;
  const rest = drive[2].replace(/\\/g, '/');
  const candidate = `/${drive[1].toLowerCase()}/${rest}`;
  const expected = `${drive[1].toUpperCase()}:/${rest}`;
  return msysDrivePrefix(candidate, 'win32') === expected ? candidate : null;
}

// Every spelling one root can appear under, longest first so a nested spelling
// is never shadowed by a prefix of itself.
function rootSpellings(root) {
  if (typeof root !== 'string' || root.trim() === '') return [];
  const seeds = [root.replace(/[\\/]+$/, '')];
  try {
    const real = fs.realpathSync(seeds[0]);
    if (real && real !== seeds[0]) seeds.push(real.replace(/[\\/]+$/, ''));
  } catch (_) {
    // An absent root is still worth redacting textually — a recycled worktree
    // is exactly the case where the path is stale and the leak is not.
  }
  // realpath resolves an alias INTO its canonical form, never back out of one,
  // so a root recorded as /private/var/... is never matched against a command
  // that spelled it /var/... . That pair is not hypothetical on macOS: /tmp and
  // /var are symlinks into /private, and both are ordinary places to put a
  // checkout. This is the one alias direction worth spelling by hand; every
  // other symlinked spelling remains the documented textual bound above.
  for (const seed of [...seeds]) {
    const stripped = /^\/private\/(?:tmp|var)(?:\/|$)/.test(seed) ? seed.slice('/private'.length) : '';
    if (stripped && !seeds.includes(stripped)) seeds.push(stripped);
  }

  const out = new Set();
  for (const seed of seeds) {
    if (seed.length < 2) continue;
    out.add(seed);
    out.add(seed.replace(/\//g, '\\'));
    out.add(seed.replace(/\\/g, '/'));
    const msys = msysSpelling(seed);
    if (msys) out.add(msys);
  }
  return [...out].filter((s) => s.length >= 2).sort((a, b) => b.length - a.length);
}

function asRootList(value) {
  const list = Array.isArray(value) ? value : [value];
  return list.filter((v) => typeof v === 'string' && v.trim() !== '');
}

// Every spelling of every supplied root, longest first. Split out of the
// replacement so `redact` can compute it ONCE and use it for both the fast-path
// scan and the passes themselves.
function rootSpellingList(roots) {
  const spellings = new Set();
  for (const root of asRootList(roots)) {
    for (const spelling of rootSpellings(root)) spellings.add(spelling);
  }
  return [...spellings].sort((a, b) => b.length - a.length);
}

function replaceSpellings(text, spellings, placeholder) {
  let out = text;
  for (const spelling of spellings) {
    out = out.replace(new RegExp(LEFT + escapeRegExp(spelling) + BOUNDARY, 'g'), placeholder);
  }
  return out;
}

// A text can only be changed by a root spelling it CONTAINS or by one of the
// three literal residual prefixes. Both are plain substring questions, and a
// substring scan is what the regex engine would do first anyway — minus the
// lookbehind, the lookahead and the alternation it evaluates at every candidate
// position.
//
// This is a cost fix, not a behavior change: the pre-check is strictly weaker
// than the rules, so anything it admits is decided by the rules exactly as
// before, and anything it rejects could not have matched. The literals come from
// the same constants the rules are built from, so the two cannot drift apart.
//
// It is worth having because the sweep's answer for the narrative log is `no-op`
// on essentially every pass — `zensu-log.sh append` already redacted at write
// time — and that answer used to cost the full set of passes over a file that
// only grows, once per in-window tool call.
//
// TWO BOUNDS ON THAT SAVING, and the second all but removes it for the very
// artifact the paragraph names. It does NOT remove the read: the sweep still
// loads the artifact to ask the question, and `SWEEP_MAX_TARGETS` is what bounds
// that. And the short-circuit only fires for text containing NONE of the three
// residual literals — two of which, `home` and `root`, are ordinary English
// words. A TDD narrative log for this repository says "project root" and "repo
// root" constantly, and any artifact a residual rule has already touched contains
// `<home>`, whose substring is `home`. Those texts admit and run every pass
// anyway. The reliable saving is on artifacts that mention none of the three;
// claiming it for the run log would be claiming the case that defeats it.
function redactionPossible(text, spellings, home) {
  for (const spelling of spellings) if (text.includes(spelling)) return true;
  for (const spelling of home) if (text.includes(spelling)) return true;
  for (const prefix of RESIDUAL_PREFIXES) if (text.includes(prefix)) return true;
  return false;
}

function redact(text, options = {}) {
  if (typeof text !== 'string' || text === '') return text;
  const projectSpellings = rootSpellingList(options.projectRoot);
  const homeSpellings = rootSpellingList(options.home);
  if (!redactionPossible(text, projectSpellings, homeSpellings)) return text;
  let out = text;
  out = replaceSpellings(out, projectSpellings, PROJECT_PLACEHOLDER);
  out = replaceSpellings(out, homeSpellings, HOME_PLACEHOLDER);
  for (const rule of RESIDUAL_RULES) out = out.replace(rule, RESIDUAL_PLACEHOLDER);
  return out;
}

// `<root>/.zensu/{plans,logs}/<file>` is the only shape either artifact has, so
// an artifact path names its own project root. LEXICAL only — see
// `resolveArtifactTarget` for the containment check that actually touches disk.
function projectRootFromArtifactPath(filePath) {
  if (typeof filePath !== 'string' || filePath === '') return '';
  const dir = path.dirname(path.resolve(filePath));
  const parent = path.dirname(dir);
  const bucket = path.basename(dir);
  if (path.basename(parent) !== ARTIFACT_DIR) return '';
  if (!Object.prototype.hasOwnProperty.call(ARTIFACT_BUCKETS, bucket)) return '';
  return path.dirname(parent);
}

// The containment check, and the only one that touches disk.
//
// `projectRootFromArtifactPath` is pure string work, so it answers `<root>` for
// `<root>/.zensu/logs/x.log` no matter what `.zensu/logs` actually IS. Every
// filesystem call that follows — readdir, read, rename — traverses intermediate
// symlinks, so a `.zensu/logs -> /var/log` link would carry a writer straight
// out of the project. Canonicalizing the PARENT and comparing it against the
// canonicalized `<root>/.zensu/<bucket>` is what closes that.
//
// When `expectedRoot` is supplied the derived root must also match it, which is
// what binds a caller's destination to the session it claims to be writing for.
function resolveArtifactTarget(filePath, expectedRoot, base) {
  if (typeof filePath !== 'string' || filePath === '') {
    return { ok: false, reason: 'no-path' };
  }
  // A relative path must resolve against the caller's project, not against
  // whatever cwd the hook process happens to hold. The skill prescribes a bare
  // relative plan path for the Write tool, so this is a real shape.
  const resolved = path.isAbsolute(filePath)
    ? path.resolve(filePath)
    : path.resolve(typeof base === 'string' && base ? base : process.cwd(), filePath);
  const derivedRoot = projectRootFromArtifactPath(resolved);
  if (!derivedRoot) return { ok: false, reason: 'not-an-artifact-path' };

  const bucket = path.basename(path.dirname(resolved));
  let realParent;
  let realRoot;
  try {
    realParent = fs.realpathSync(path.dirname(resolved));
    realRoot = fs.realpathSync(derivedRoot);
  } catch (_) {
    return { ok: false, reason: 'artifact-directory-unresolvable' };
  }
  // Compare the canonical parent against the root's OWN join, never against a
  // second realpath of the same lexical path: canonicalizing both sides
  // resolves them through the SAME symlink, so they always agree and the check
  // proves nothing. This spelling refuses a `.zensu/logs -> /var/log` link,
  // which is the whole point of the containment.
  if (realParent !== path.join(realRoot, ARTIFACT_DIR, bucket)) {
    return { ok: false, reason: 'artifact-directory-escapes' };
  }

  // `expectedRoot` takes the SAME vocabulary as `projectRoot` — string or array.
  // A non-string shape used to skip this block entirely and return ok, which
  // fails open on exactly the check containment exists for.
  if (expectedRoot !== undefined && expectedRoot !== null) {
    const expected = asRootList(expectedRoot);
    if (expected.length === 0) return { ok: false, reason: 'project-root-unusable' };
    // `realRoot` is the same canonicalization, already performed above; a second
    // realpath of the same path could only fail on a race, so its refusal reason
    // was dead code that no consumer classified.
    const matches = expected.some((candidate) => {
      try {
        return fs.realpathSync(candidate) === realRoot;
      } catch (_) {
        return false;
      }
    });
    if (!matches) return { ok: false, reason: 'foreign-project' };
  }
  // NOTE: no cwd-derived fallback bind belongs HERE. `redactFile` and the sweep
  // legitimately resolve with no `expectedRoot` and a caller root that is not an
  // ancestor of the process cwd, so constraining the shared resolver would deny
  // them; the one caller that lacked an authority is the `append` WRITER, and
  // `zensu-log.sh` binds it there against the same `target.projectRoot` this
  // function returns.

  return {
    ok: true,
    reason: 'artifact',
    path: resolved,
    bucket,
    projectRoot: derivedRoot,
    realParent,
  };
}

// The Bash sweep's candidate set, owned here rather than in a shell-quoted
// `node -e` program no unit test can reach.
function sweepTargets(projectRoot, options = {}) {
  const nowMs = typeof options.nowMs === 'number' ? options.nowMs : Date.now();
  const windowSeconds = typeof options.windowSeconds === 'number'
    ? options.windowSeconds : SWEEP_WINDOW_SECONDS;
  const cutoff = nowMs - windowSeconds * 1000;
  const maxTargets = Number.isInteger(options.maxTargets) && options.maxTargets >= 0
    ? options.maxTargets : SWEEP_MAX_TARGETS;
  const out = [];
  if (typeof projectRoot !== 'string' || projectRoot.trim() === '') return out;
  for (const [bucket, extension] of Object.entries(ARTIFACT_BUCKETS)) {
    const dir = path.join(projectRoot, ARTIFACT_DIR, bucket);
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      const name = entry.name;
      if (!name.endsWith(extension)) continue;
      // The witness is redacted by its own writer and is the largest file in the
      // directory. It is gitignored in THIS repository only — a consuming repo has
      // to add `.zensu/state/` and `.zensu/logs/witness-*.log` itself — so "never
      // committed" is NOT the reason it is skipped here, and saying so would
      // re-assert the claim docs/tdd-manager-workflow.md exists to retract.
      // EITHER bucket, not just `logs`. `redactFile` refuses any `witness-`
      // basename wherever it sits and answers `witness-artifact`, and that reason
      // is deliberately in none of the three exported sets — so a swept path
      // carrying it fell through the hook's partition and printed "artifact left
      // UNREDACTED (sweep)" once per tool call for the whole window, about a file
      // the design refuses on purpose. Scoping the skip to `logs` made the module
      // header's "excluded from EVERY path" false for the enumeration alone.
      if (isWitnessName(name)) continue;
      // The dirent carries the type, so a directory or a symlink named like an
      // artifact is rejected without a syscall. A filesystem that does not report
      // `d_type` answers UNKNOWN and every predicate below is false — the entry
      // then falls through to the stat, which is the right answer there: skipping
      // it would silently drop real artifacts on that host.
      if (entry.isDirectory() || entry.isSymbolicLink() || entry.isFIFO()
        || entry.isSocket() || entry.isCharacterDevice() || entry.isBlockDevice()) continue;
      const full = path.join(dir, name);
      let stat;
      try {
        stat = fs.lstatSync(full);
      } catch (_) {
        continue;
      }
      if (!stat.isFile()) continue;
      if (stat.mtimeMs < cutoff) continue;
      out.push({ full, mtimeMs: stat.mtimeMs });
    }
  }
  // Path is the tie-break, not decoration: a checkout stamps many artifacts with
  // the same mtime, and without it the capped SET would depend on readdir order.
  out.sort((a, b) => (b.mtimeMs - a.mtimeMs)
    || (a.full < b.full ? -1 : (a.full > b.full ? 1 : 0)));
  return out.slice(0, maxTargets).map((entry) => entry.full);
}

// What this check DELIVERS, stated without the claim it used to carry: the path
// still names the inode the descriptor holds. It re-derives the location from
// `target.realParent` — the canonicalized parent — rather than from the caller's
// spelling, so a `.zensu/logs` that is a symlink is resolved once and compared
// against its real destination.
//
// It does NOT catch an intermediate-directory swap in the ordinary case, which an
// earlier revision of this comment claimed. When nothing moved, `realParent` IS
// the lexical parent, so this lstats the same location the open used and both
// sides move together — a swap that redirects the path redirects this lookup with
// it. What it catches is the pair DISAGREEING: the name now resolving to a
// different inode than the one opened, which is the rename/replace race.
//
// And it is still check-then-use either way: the answer is true at the moment of
// the lstat, not at the moment of the write. Only `openat`-style semantics, which
// Node does not expose, would close that.
function sameInode(stat, target) {
  if (!target || typeof target.realParent !== 'string') return false;
  try {
    const expected = fs.lstatSync(path.join(target.realParent, path.basename(target.path)));
    return expected.dev === stat.dev && expected.ino === stat.ino;
  } catch (_) {
    return false;
  }
}

function defaultHome() {
  return process.env.HOME || process.env.USERPROFILE || '';
}

// Rewrite one artifact in place. Every refusal is REPORTED through the return
// value; no caller may treat an un-redacted artifact as a clean result.
function redactFile(filePath, options = {}) {
  const target = resolveArtifactTarget(filePath, options.expectedRoot, options.base);
  if (!target.ok) return { changed: false, reason: target.reason };
  // The witness is excluded from EVERY path, not just the sweep. Its `tail` must
  // stay raw — redaction there is purely subtractive and would let a `failed`
  // token inside an absolute path vanish, downgrading an EVIDENCE CONTRADICTION
  // to `verified` — and the targeted Edit/Write branch reaches this function
  // with a caller-supplied path.
  if (isWitnessName(path.basename(target.path))) {
    return { changed: false, reason: 'witness-artifact' };
  }

  // O_NOFOLLOW on the final component, then judge the DESCRIPTOR. lstat
  // followed by a path read is a TOCTOU window: the artifact tree is writable
  // from inside the session, so the path can become a symlink between the two.
  // Platform-gated on purpose, and spelled the way every other secure open in
  // this repo spells it: Windows has no O_NOFOLLOW, and the OR-zero coercion
  // form is the one tests/structure/test-windows-portability-guards.sh forbids,
  // because it hides an undefined constant behind a default. That pin is a
  // plain grep over the whole file, so this comment must not spell the
  // forbidden form either.
  const noFollow = platformNoFollow();
  let fd;
  let stat;
  let original;
  try {
    fd = fs.openSync(target.path, fs.constants.O_RDONLY | noFollow | NON_BLOCK);
    stat = fs.fstatSync(fd);
    if (!stat.isFile()) { fs.closeSync(fd); return { changed: false, reason: 'not-a-file' }; }
    if (stat.nlink !== 1) { fs.closeSync(fd); return { changed: false, reason: 'hard-link' }; }
    if (!sameInode(stat, target)) { fs.closeSync(fd); return { changed: false, reason: 'moved' }; }
    if (stat.size > MAX_BYTES) { fs.closeSync(fd); return { changed: false, reason: 'too-large' }; }
    const raw = Buffer.alloc(stat.size);
    let read = 0;
    while (read < stat.size) {
      const n = fs.readSync(fd, raw, read, stat.size - read, read);
      if (n <= 0) break;
      read += n;
    }
    fs.closeSync(fd);
    fd = undefined;
    if (read !== stat.size) return { changed: false, reason: 'short-read' };
    original = raw.toString('utf8');
    // A lossy decode would be written back as U+FFFD, corrupting an artifact
    // that merely captured a stray non-UTF-8 byte in a `tail=` field.
    if (!Buffer.from(original, 'utf8').equals(raw)) {
      return { changed: false, reason: 'not-utf8' };
    }
  } catch (err) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) { /* closing */ } }
    const linkErrno = err && (err.code === 'ELOOP' || err.code === 'EMLINK');
    return { changed: false, reason: linkErrno ? 'symlink' : 'unreadable' };
  }

  // UNION, never a choice. A caller-supplied root and the artifact-derived root
  // are two authorities for the same thing; substituting only one of them is
  // how the two writers drift apart and the crosscheck reports a gap.
  const projectRoot = [...asRootList(options.projectRoot), target.projectRoot];
  const home = options.home || defaultHome();
  const next = redact(original, { projectRoot, home });
  if (next === original) return { changed: false, reason: 'no-op' };

  const tmp = `${target.path}.zensu-redact-${process.pid}-${crypto.randomBytes(6).toString('hex')}`;
  let out;
  try {
    out = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
      stat.mode & 0o777);
    // writeFileSync loops internally; a bare writeSync returns a short count
    // rather than throwing when the filesystem fills mid-write, and the rename
    // would then publish a truncated audit artifact.
    fs.writeFileSync(out, next);
    fs.fsyncSync(out);
    fs.closeSync(out);
    out = undefined;
    // The append writer holds no lock, so a line can land between the read above
    // and this rename. Re-statting and abandoning NARROWS that window; it does
    // not close it — a write landing between this `lstat` and the `rename` goes
    // to the inode the rename then orphans, and is lost. An accepted gap, stated
    // rather than implied: closing it needs the external lease the other
    // `.zensu` writers take.
    const now = fs.lstatSync(target.path);
    if (now.size !== stat.size || now.mtimeMs !== stat.mtimeMs) {
      fs.unlinkSync(tmp);
      return { changed: false, reason: 'concurrent-write' };
    }
    fs.renameSync(tmp, target.path);
  } catch (_) {
    if (out !== undefined) { try { fs.closeSync(out); } catch (_ignored) { /* closing */ } }
    try { fs.unlinkSync(tmp); } catch (_ignored) { /* best effort */ }
    return { changed: false, reason: 'write-failed' };
  }
  return { changed: true, reason: 'redacted' };
}

// The narrative-log WRITE, performed here rather than by a shell redirect.
//
// It is named for what it can do, not for its common case: `mode: 'replace'`
// truncates. Calling it `append` hid the destructive capability at every call
// site.
//
// A shell `>>` names a PATH and follows whatever it finds, while the validation
// that preceded it named a different moment and — for a hard link — a different
// property entirely: `[ -L ]` is false for one, and `resolveArtifactTarget`
// canonicalizes only the parent. Planting a hard link inside `.zensu/logs/`
// therefore turned the log verb into an append/truncate primitive on any file
// on the same filesystem, reachable through a command no Bash gate can parse as
// a write channel. Opening here with O_NOFOLLOW and judging the DESCRIPTOR
// closes the hole and the window together: the object checked is the object
// written. O_TRUNC is deliberately NOT in the open flags — it would truncate
// before the nlink check could refuse.
//
// IT PERFORMS NO REDACTION. The line is written exactly as handed in. That is the
// one trap a second caller is most likely to hit in a file that calls itself the
// single source of truth for publication safety: the containment, the symlink
// refusal and the hard-link refusal are all about WHERE the bytes land, never
// about what they say. `zensu-log.sh append` calls `redact` itself before calling
// this, and any other caller must do the same.
//
// The two modes are two different writes and no longer share an open. `append`
// stays an in-place O_APPEND write to the judged descriptor. `replace` publishes
// through `replaceArtifactFile` below, because an in-place truncate commits its
// destructive half before the new bytes exist.
function writeArtifactLine(filePath, line, options = {}) {
  const target = resolveArtifactTarget(filePath, options.expectedRoot, options.base);
  if (!target.ok) return { written: false, reason: target.reason };
  // The narrative LOG only. `resolveArtifactTarget` admits both buckets, so
  // without this the same verb — in `replace` mode — truncates a committed plan
  // or the witness log the Phase-6 crosscheck matches against.
  if (target.bucket !== 'logs') return { written: false, reason: 'not-a-log-artifact' };
  // Case-INSENSITIVE, because the comparison runs against a path the filesystem
  // may resolve case-insensitively: on APFS or NTFS `WITNESS-<key>.log` names the
  // same inode, and a case-sensitive test would fail OPEN on the one file whose
  // destruction the crosscheck cannot survive.
  if (isWitnessName(path.basename(target.path))) {
    return { written: false, reason: 'witness-artifact' };
  }
  if (options.mode === 'replace') return replaceArtifactFile(target, line);
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | platformNoFollow() | NON_BLOCK
    | fs.constants.O_APPEND;
  let fd;
  try {
    fd = fs.openSync(target.path, flags, 0o644);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) { fs.closeSync(fd); return { written: false, reason: 'not-a-file' }; }
    if (stat.nlink !== 1) { fs.closeSync(fd); return { written: false, reason: 'hard-link' }; }
    if (!sameInode(stat, target)) { fs.closeSync(fd); return { written: false, reason: 'moved' }; }
    fs.writeFileSync(fd, line);
    // Judged before the write and never again, the checks above prove only where
    // the line was GOING. A rename landing between them and the write sends it to
    // an inode no path names any more, and the earlier spelling still answered
    // `written: true` — so `zensu-log.sh append` exited 0 and the CHECKPOINT was
    // believed while nothing held it, with the sweeper reporting a clean reason
    // because nothing recorded a loss.
    //
    // Re-running the same comparison AFTER the write cannot prevent that: the
    // bytes are already in the orphan and this writer has no way to move them.
    // What it buys is the report — `concurrent-write` is a TRANSIENT reason, so
    // the caller retries and the line lands. It is still check-then-use, one
    // window later; only `openat`-style semantics would close it, and Node does
    // not expose them.
    //
    // An `fstat` that THROWS here falls to the catch and is reported as
    // `write-failed`. That is the deliberate answer: the line may or may not be
    // held by a path, and a caller that must not lose it is better served by a
    // loud refusal it retries than by a success it cannot verify.
    //
    // ONE CONSEQUENCE IN THE OTHER DIRECTION, stated rather than implied.
    // `sameInode` answers false on ANY `lstatSync` throw, not only on a genuine
    // inode mismatch — a concurrent `chmod` on the parent, an EIO — so a
    // TRANSIENT stat fault over a line that DID land is reported here as
    // `concurrent-write`. That reason tells the caller to retry, and the retry
    // then duplicates the entry in an audit log a consuming repo commits.
    // Narrow, and the trade is deliberate: the check cannot tell "the path names
    // a different inode" from "I could not ask", and of the two wrong answers a
    // duplicated line is recoverable by reading while a silently orphaned one is
    // not. Splitting the two verdicts would mean giving `sameInode` a third
    // value at all three of its call sites; do that only with a reason to.
    // Do NOT read the sentence above as "the line did not land" — it may have.
    if (!sameInode(fs.fstatSync(fd), target)) {
      fs.closeSync(fd);
      return { written: false, reason: 'concurrent-write' };
    }
    // The handle is deliberately NOT cleared before this close. That is a real
    // difference from `redactFile`, not an oversight there: statements that can
    // throw FOLLOW its close, so clearing is what keeps its catch from
    // double-closing. Here the close is the LAST statement in the try, so a clear
    // after it could never run on the one path that would need it, and could never
    // matter on any other.
    //
    // A close-time EIO therefore lands in the catch and is reported as
    // `write-failed`, which is the answer this writer wants: POSIX `close()`
    // returning EIO means a buffered write failed, so the line may not be on disk
    // and `zensu-log.sh` must exit non-zero rather than lose it silently. The
    // catch's second `closeSync` is then a double close — swallowed there, and safe
    // only because no descriptor is opened between the two, so a reused number
    // cannot be hit. Durability is claimed in NEITHER direction: unlike
    // `redactFile`, this path performs no `fsync`.
    fs.closeSync(fd);
  } catch (err) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) { /* closing */ } }
    const linkErrno = err && (err.code === 'ELOOP' || err.code === 'EMLINK');
    return { written: false, reason: linkErrno ? 'symlink' : 'write-failed' };
  }
  return { written: true, reason: 'written' };
}

// `mode: 'replace'` — the destructive half of the log verb, published by rename.
//
// The in-place spelling ran `ftruncateSync(fd, 0)` and only then wrote, so a
// write that failed after the truncate left the artifact EMPTY with no recovery
// path: the destroy had committed and the create had not. The file at risk is the
// run log a consuming repo commits as its audit trail, and the shipped Phase-2
// recipe is what creates it, so the loss window sat on the normal path.
//
// Writing an O_EXCL temp beside it, fsyncing, and renaming makes the publish
// atomic — the previous bytes stay addressable until the rename, and every
// failure before it changes nothing on disk. This is the same discipline
// `redactFile` uses, spelled the same way on purpose.
//
// The refusals are unchanged and are still judged on a DESCRIPTOR: the target is
// opened read-only with O_NOFOLLOW first, so a symlink, a hard link, a directory
// and a swapped inode all refuse exactly as before. ENOENT is the one tolerated
// open failure — creating the log is this mode's ordinary Phase-2 case.
//
// The pre-rename re-check narrows the same window `redactFile` documents and
// does not close it: a write landing between the `lstat` and the `rename` goes
// to the inode the rename orphans. Closing that needs the external lease the
// other `.zensu` writers take. Stated rather than implied.
function replaceArtifactFile(target, line) {
  let fd;
  let prior = null;
  let mode = 0o644;
  try {
    fd = fs.openSync(target.path, fs.constants.O_RDONLY | platformNoFollow() | NON_BLOCK);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) { fs.closeSync(fd); return { written: false, reason: 'not-a-file' }; }
    if (stat.nlink !== 1) { fs.closeSync(fd); return { written: false, reason: 'hard-link' }; }
    if (!sameInode(stat, target)) { fs.closeSync(fd); return { written: false, reason: 'moved' }; }
    fs.closeSync(fd);
    fd = undefined;
    prior = { size: stat.size, mtimeMs: stat.mtimeMs };
    mode = stat.mode & 0o777;
  } catch (err) {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) { /* closing */ } }
    if (!err || err.code !== 'ENOENT') {
      const linkErrno = err && (err.code === 'ELOOP' || err.code === 'EMLINK');
      return { written: false, reason: linkErrno ? 'symlink' : 'write-failed' };
    }
  }

  const tmp = `${target.path}.zensu-redact-${process.pid}-${crypto.randomBytes(6).toString('hex')}`;
  let out;
  try {
    out = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, mode);
    // writeFileSync loops internally; a bare writeSync returns a short count
    // rather than throwing when the filesystem fills mid-write, and the rename
    // would then publish a truncated artifact.
    fs.writeFileSync(out, line);
    fs.fsyncSync(out);
    fs.closeSync(out);
    out = undefined;
    let now = null;
    try { now = fs.lstatSync(target.path); } catch (_) { now = null; }
    // Absence and presence are both states worth defending: a target that
    // APPEARED since the open is someone else's file, and one that VANISHED is no
    // longer the object that was judged.
    const moved = prior === null
      ? now !== null
      : (now === null || now.size !== prior.size || now.mtimeMs !== prior.mtimeMs);
    if (moved) {
      fs.unlinkSync(tmp);
      return { written: false, reason: 'concurrent-write' };
    }
    fs.renameSync(tmp, target.path);
  } catch (_) {
    if (out !== undefined) { try { fs.closeSync(out); } catch (_ignored) { /* closing */ } }
    try { fs.unlinkSync(tmp); } catch (_ignored) { /* best effort */ }
    return { written: false, reason: 'write-failed' };
  }
  return { written: true, reason: 'written' };
}

// The reason space, partitioned EXPLICITLY. A consumer that has to fall back on
// "everything else" ends up reporting a routine race as the worst outcome the
// hook can produce, which is what an implicit residual class did here once.
//
//   CLEAN      — the artifact is in the intended state
//   TRANSIENT  — nothing was done, nothing was lost, the next pass retries
//   NON_ARTIFACT — the path is simply not an artifact of this project; an
//                  ordinary outcome on a matcher that sees every file written
//   everything else — a genuine refusal a caller must surface
//
// `foreign-project` is deliberately NOT in NON_ARTIFACT: "not an artifact" and
// "someone else's artifact" are different facts, and only the second is worth
// an operator's attention.
const CLEAN_REASONS = new Set(['redacted', 'no-op', 'written']);
const TRANSIENT_REASONS = new Set(['concurrent-write', 'moved']);
const NON_ARTIFACT_REASONS = new Set([
  'not-an-artifact-path',
  'artifact-directory-unresolvable',
  'no-path',
]);

function parseArgs(argv) {
  const opts = { mode: '', projectRoot: '', home: '', file: '' };
  for (let i = 0; i < argv.length; i += 1) {
    switch (argv[i]) {
      case '--file':
        opts.mode = 'file';
        opts.file = argv[i + 1] || '';
        i += 1;
        break;
      case '--project':
        opts.projectRoot = argv[i + 1] || '';
        i += 1;
        break;
      case '--home':
        opts.home = argv[i + 1] || '';
        i += 1;
        break;
      default:
        return null;
    }
  }
  return opts.mode ? opts : null;
}

function main(argv) {
  const opts = parseArgs(argv);
  if (!opts) {
    process.stderr.write(
      'usage: zensu-artifact-redact-v1.js --file <artifact> --project <root> [--home <dir>]\n');
    return 2;
  }

  if (opts.mode === 'file') {
    if (!opts.file) {
      process.stderr.write('zensu-artifact-redact-v1.js: --file needs a path\n');
      return 2;
    }
    if (!opts.projectRoot) {
      process.stderr.write(
        'zensu-artifact-redact-v1.js: --file needs --project <root> to bind the target\n');
      return 2;
    }
    const result = redactFile(opts.file, {
      projectRoot: opts.projectRoot,
      expectedRoot: opts.projectRoot,
      home: opts.home || undefined,
    });
    if (CLEAN_REASONS.has(result.reason)) return 0;
    process.stderr.write(`zensu-artifact-redact-v1.js: refused ${opts.file} (${result.reason})\n`);
    return 2;
  }

  // Unreachable while `--file` is the only mode, and explicit anyway: falling off
  // the end would assign `undefined` to process.exitCode, which is neither of the
  // two codes this CLI documents.
  process.stderr.write('zensu-artifact-redact-v1.js: --file is the only mode\n');
  return 2;

}

// The exported surface is exactly what has a consumer in `hooks/` or in
// `tests/structure/test-artifact-redaction.sh`, and that sentence is checkable
// rather than aspirational — NINE names have been removed for failing it:
// `projectRootFromArtifactPath`, `ARTIFACT_BUCKETS`, `ARTIFACT_DIR`, the three
// placeholder constants, and then `SWEEP_WINDOW_SECONDS`, `SWEEP_MAX_TARGETS` and
// `MAX_BYTES`. The last three were the ones the first pass missed: the hook and
// the docs NAME them in prose, and a name in a comment reads like a consumer at a
// glance, but nothing imports them. The suite drives the sweep through the
// `windowSeconds` and `maxTargets` OPTIONS and the oversize case through a
// literal, so the defaults were exported for no caller at all.
//
// Dead API surface is not free here: an export reads as a contract a port has to
// honour, and a tuning constant exported as contract is the worst of the two —
// the layout constants invited a caller to re-derive a path this module exists to
// own, and these invited one to depend on a number this host is free to change.
// Everything below is imported somewhere; adding a name here without a caller is
// how that grew back twice.
module.exports = {
  redact,
  redactFile,
  writeArtifactLine,
  defaultHome,
  NON_ARTIFACT_REASONS,
  TRANSIENT_REASONS,
  CLEAN_REASONS,
  rootSpellings,
  resolveArtifactTarget,
  sweepTargets,
  msysSpelling,
  WITNESS_PREFIX,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
