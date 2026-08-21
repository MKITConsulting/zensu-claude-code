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
// covers it. Both roots are matched in their given AND `realpath` spellings,
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

// The artifact layout, owned here. hooks/post-artifact-redact.sh consumes this
// table rather than re-spelling it, so a layout move is one edit.
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
const SWEEP_WINDOW_SECONDS = 300;

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
// Two properties of the segment class are load-bearing. It excludes quotes, so
// `cmd="ls /home/otherdev"` keeps its closing `"` — consuming it desynchronizes
// the claim from the witness entry and produces the very EVIDENCE GAP the
// witness redaction exists to prevent. And every alternative carries BOUNDARY,
// so `/homework/notes.md` is left alone instead of becoming `<home>work/…`.
const SEGMENT = '[^/\\\\\\s"\']*';
// The separator is matched in its ESCAPED spellings too. A JSON-encoded command
// — which is exactly what the witness writes, and what a `cmd="…"` field carries
// — renders a Windows path as `C:\\Users\\bob`, and matching a single
// separator there consumed the prefix but left `bob` behind: output that LOOKS
// redacted and still names the developer. Same for an escaped solidus.
const SEP_POSIX = '\\\\?\\/';
const SEP_WIN = '\\\\{1,2}';
// Rule 3 additionally refuses to fire immediately after a placeholder rules 1-2
// just emitted. `LEFT` excludes only segment-name characters, and `>` and `~` are
// not among them — so `<project>/home/config.yml`, a perfectly ordinary in-project
// directory named `home`, matched and collapsed to `<project><home>`. The rules
// cannot simply be reordered: rule 3 would then consume `/Users/m` before rule 1
// could match the longer `/Users/m/proj`.
const NOT_AFTER_PLACEHOLDER = '(?<!' + PROJECT_PLACEHOLDER + ')(?<!'
  + RESIDUAL_PLACEHOLDER + ')(?<!' + HOME_PLACEHOLDER + ')';
const RESIDUAL_RULES = [
  new RegExp(NOT_AFTER_PLACEHOLDER + LEFT + SEP_POSIX + '(?:Users|home)(?:' + SEP_POSIX + SEGMENT + ')?' + BOUNDARY, 'g'),
  new RegExp(NOT_AFTER_PLACEHOLDER + LEFT + SEP_WIN + 'Users(?:' + SEP_WIN + SEGMENT + ')?' + BOUNDARY, 'g'),
  new RegExp(NOT_AFTER_PLACEHOLDER + LEFT + SEP_POSIX + 'root' + BOUNDARY, 'g'),
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

function replaceRoots(text, roots, placeholder) {
  let out = text;
  const spellings = new Set();
  for (const root of asRootList(roots)) {
    for (const spelling of rootSpellings(root)) spellings.add(spelling);
  }
  for (const spelling of [...spellings].sort((a, b) => b.length - a.length)) {
    out = out.replace(new RegExp(LEFT + escapeRegExp(spelling) + BOUNDARY, 'g'), placeholder);
  }
  return out;
}

function redact(text, options = {}) {
  if (typeof text !== 'string' || text === '') return text;
  const { projectRoot, home } = options;
  let out = text;
  out = replaceRoots(out, projectRoot, PROJECT_PLACEHOLDER);
  out = replaceRoots(out, home, HOME_PLACEHOLDER);
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
  const out = [];
  if (typeof projectRoot !== 'string' || projectRoot.trim() === '') return out;
  for (const [bucket, extension] of Object.entries(ARTIFACT_BUCKETS)) {
    const dir = path.join(projectRoot, ARTIFACT_DIR, bucket);
    let entries;
    try {
      entries = fs.readdirSync(dir);
    } catch (_) {
      continue;
    }
    for (const name of entries) {
      if (!name.endsWith(extension)) continue;
      // The witness is redacted by its own writer, is gitignored and never
      // committed, and is the largest file in the directory.
      if (bucket === 'logs' && isWitnessName(name)) continue;
      const full = path.join(dir, name);
      let stat;
      try {
        stat = fs.lstatSync(full);
      } catch (_) {
        continue;
      }
      if (!stat.isFile()) continue;
      if (stat.mtimeMs < cutoff) continue;
      out.push(full);
    }
  }
  return out.sort();
}

// O_NOFOLLOW binds the FINAL component only; an intermediate directory can still
// be swapped for a symlink between `resolveArtifactTarget`'s realpath and the
// open. Re-deriving the expected location from the CANONICAL parent and
// comparing dev/ino against the descriptor catches that one component higher.
//
// Stated plainly, because an earlier revision of the surrounding prose claimed
// more than this delivers: it is still check-then-use. It narrows the window
// from a one-shot symlink plant to a rename race against a real directory; only
// `openat`-style semantics, which Node does not expose, would close it.
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
  const replace = options.mode === 'replace';
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | platformNoFollow() | NON_BLOCK
    | (replace ? 0 : fs.constants.O_APPEND);
  let fd;
  try {
    fd = fs.openSync(target.path, flags, 0o644);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) { fs.closeSync(fd); return { written: false, reason: 'not-a-file' }; }
    if (stat.nlink !== 1) { fs.closeSync(fd); return { written: false, reason: 'hard-link' }; }
    if (!sameInode(stat, target)) { fs.closeSync(fd); return { written: false, reason: 'moved' }; }
    if (replace) fs.ftruncateSync(fd, 0);
    fs.writeFileSync(fd, line);
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

module.exports = {
  redact,
  redactFile,
  writeArtifactLine,
  defaultHome,
  NON_ARTIFACT_REASONS,
  TRANSIENT_REASONS,
  rootSpellings,
  projectRootFromArtifactPath,
  resolveArtifactTarget,
  sweepTargets,
  msysSpelling,
  ARTIFACT_BUCKETS,
  ARTIFACT_DIR,
  WITNESS_PREFIX,
  SWEEP_WINDOW_SECONDS,
  CLEAN_REASONS,
  PROJECT_PLACEHOLDER,
  HOME_PLACEHOLDER,
  RESIDUAL_PLACEHOLDER,
  MAX_BYTES,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
