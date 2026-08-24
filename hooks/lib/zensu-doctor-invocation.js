// zensu-doctor-invocation.js — recognize the TWO calls that stay reachable when
// the Session Control bind fails: the read-only /zensu:doctor diagnostic, and
// /zensu:adopt-session, which repairs the one bind failure that is repairable.
//
// A failed bind to the immutable Session Control record denies, and two states
// are relaxed for it (no record at all; a recorded project root that is gone).
// A record that EXISTS and disagrees about anything else keeps denying for
// every principal — including a session whose plugin was upgraded underneath it,
// which is the ordinary consequence of running `claude plugin marketplace
// update` inside a session. In that state /zensu:doctor is denied too, so the
// pointer every fail-closed message renders is a dead end, denied by the very
// defect it names. docs/session-control.md "Unbindable sessions" is the authoritative roster.
//
// This module is what lets those two through and NOTHING else. It is a widening
// of a state that includes genuine tamper suspicion, and the two are admitted on
// SEPARATE arguments that must not be merged.
//
// The diagnostic rests on one property: hooks/lib/zensu-doctor.sh writes nothing.
// The single write in the whole doctor flow is the expired-pending-review cleanup
// in Phase 3 of skills/doctor/SKILL.md, which the model issues as SEPARATE
// commands that stay fully gated. Folding that cleanup into the script would
// silently turn this into a write channel.
//
// The adoption DOES write, so it cannot borrow that argument; its own is in the
// header of hooks/lib/zensu-session-adopt.sh and is summarised at ADOPT_SEGMENTS
// below.
//
// The recognizer is a WHITELIST, never a blacklist of dangerous characters: it
// accepts a closed set of assignments followed by exactly one `bash <path>` and
// refuses everything else, so a second command cannot ride along. A blacklist
// would have to enumerate every operator the shell grows.
//
// Why the assignments exist at all: the Bash tool inherits NONE of
// CLAUDE_PLUGIN_DATA, CLAUDE_PROJECT_DIR or CLAUDE_PLUGIN_ROOT (measured — all
// three are unset in a tool call), while Claude renders those tokens natively
// into the skill body. The model therefore emits LITERAL absolute paths and the
// script cannot read them from its environment. Values are matched as literal
// paths for that reason; a `${...}` spelling is refused, because at recognition
// time it would be an unexpanded string and at run time a shell expansion this
// module never saw.
//
// The doctor path is compared against the EXECUTING plugin root, derived here
// from __dirname exactly as claude-hook-session-v1.js derives it. A caller
// cannot supply a different root: recognize() takes one only so the unit suite
// can drive a synthetic tree.

"use strict";

const fs = require("fs");
const nodePath = require("path");
// The MSYS drive rule is SHARED, never re-derived. On Windows a command token
// reaches this module over stdin, the one channel MSYS does not convert, so the
// doctor path can arrive spelled `/c/Users/...` while __dirname is already
// native `C:\Users\...`. Without the rewrite path.resolve reads that leading `/`
// as drive-relative, the two spellings never compare equal, and the diagnostic
// is refused on every Windows host — the exact failure this file exists to
// prevent. msysDrivePrefix is TOTAL: anything that is not an MSYS drive spelling
// comes back unchanged, and it never throws, so it cannot turn a refusal into a
// crashed hook.
const { msysDrivePrefix } = require("./claude-path-v1.js");

const COMMAND_MAX_BYTES = 4096;
const DOCTOR_SEGMENTS = ["hooks", "lib", "zensu-doctor.sh"];
// The SECOND recognized script, and the one that breaks the "writes nothing"
// premise the paragraph above rests on. It is admitted on a DIFFERENT
// justification, which lives in the header of hooks/lib/zensu-session-adopt.sh
// and is NOT restated here — a second copy is a second thing to go stale, and
// this comment is where a future reviewer decides whether the list stays at two.
// In one line: it writes one record for the calling session, one workflow
// history entry, and moves that session's stale review-evidence leases aside;
// what BOUNDS those writes is readContext (session
// hash, digest recomputed against the RECORDED root, that root's declared
// version) plus the sibling-root and plugin_data checks — NOT derivation, since
// CLAUDE_PLUGIN_DATA is a caller-supplied literal here exactly as it is for the
// diagnostic. Without --confirm it is read-only.
//
// Admitting it is what makes the lineage diagnosis actionable: the state it
// repairs denies Edit, Write and every other Bash call, so a remedy the user
// cannot invoke is not a remedy. Keep this list at two. A third entry needs its
// own justification written down the same way, not a wave at this one.
const ADOPT_SEGMENTS = ["hooks", "lib", "zensu-session-adopt.sh"];
const INTERPRETER = "bash";

// Each recognized script declares the arguments it accepts, as exact literals.
// The doctor takes none. The adoption takes at most one, and `--confirm` is the
// whole difference between a report and a write, so it is spelled out here
// rather than left to the script: the gate decides what may be invoked, and a
// script cannot widen its own recognition.
const RECOGNIZED = {
  doctor: { segments: DOCTOR_SEGMENTS, args: [] },
  adopt: { segments: ADOPT_SEGMENTS, args: ["--confirm"] },
};

const ASSIGNMENT_TOKEN = /^[A-Za-z_][A-Za-z0-9_]*=/;

// The UNION of names the recognized scripts read and the Bash tool does not
// supply. `CLAUDE_PLUGIN_DATA` is read by both; `CLAUDE_PROJECT_DIR` is
// doctor-only in practice — the adoption is bounded by the record and ignores it
// — and `ZDOC_PLAYWRIGHT_TOOLS` is doctor-only outright. Accepting either on the
// adoption form costs nothing, because that script reads neither. Kept as one shared set
// rather than per-entry: unlike `args`, an assignment cannot change what a
// script DOES, only what it can see. `path` requires a rooted, traversal-free
// literal; a Set requires one of its members.
//
// `CLAUDE_PROJECT_DIR` is NOT a harmless leftover now that the adoption ignores it,
// and it must not be dropped on that reasoning. It is what keeps a model still
// holding the PREVIOUS release's skill body — which emits the assignment — from
// having its command refused. That is not an exotic case: a mid-session upgrade is
// precisely the state this whole feature exists for, and the skill text a running
// model holds is the one thing an upgrade does not replace.
//
// The residual it leaves sits on the READ command rather than the write one:
// `isRootedLiteralPath("")` is false, so a harness rendering the placeholder empty
// makes the assignment reject and denies the entire invocation — /zensu:doctor
// included, the first thing a wedged user is told to run. `skills/doctor/SKILL.md`
// therefore instructs the model to OMIT the assignment rather than render it empty;
// the recognizer cannot fix that end, because by the time it sees the command the
// empty value is already there.
const ASSIGNMENTS = {
  CLAUDE_PLUGIN_DATA: "path",
  CLAUDE_PROJECT_DIR: "path",
  ZDOC_PLAYWRIGHT_TOOLS: new Set(["ready"]),
};

// WINDOWS IS OUT OF SCOPE, DELIBERATELY AND VISIBLY.
//
// The command token reaches this module over stdin, the one channel MSYS never
// converts, so on a win32 host the doctor path arrives in MSYS spelling while
// __dirname is already native. msysDrivePrefix maps `/d/...` to `D:/...`, but a
// Git Bash temp or mount path — `/tmp/...` — has no drive letter to map, and
// resolving it splices it onto the current drive (`\tmp\...`). Mapping it
// correctly needs the MSYS mount table, which this repository deliberately does
// not probe (see the parser header in bash-source-write-parse.js).
//
// Guessing would be worse than refusing: a wrong mapping either admits a path
// that is not the diagnostic, or silently denies while claiming to allow. So
// win32 refuses outright and the diagnostic stays denied there in a bind failure
// — exactly the behavior every host had before this module existed. It is a gap,
// not a regression, and test-versioned-plugin-upgrade.sh pins it per platform so
// it cannot quietly become an unverified claim.
const PLATFORM_SUPPORTED = process.platform !== "win32";

const REASONS = {
  PLATFORM: "PLATFORM_UNSUPPORTED",
  NOT_BASH: "NOT_A_BASH_CALL",
  COMMAND_TYPE: "COMMAND_NOT_A_STRING",
  COMMAND_SIZE: "COMMAND_TOO_LARGE",
  CHARSET: "COMMAND_CHARSET_REJECTED",
  QUOTING: "COMMAND_QUOTING_REJECTED",
  SHAPE: "COMMAND_SHAPE_REJECTED",
  ASSIGNMENT: "ASSIGNMENT_REJECTED",
  DUPLICATE: "ASSIGNMENT_DUPLICATED",
  PATH: "SCRIPT_PATH_REJECTED",
  NOT_REGULAR: "SCRIPT_PATH_NOT_REGULAR",
  ARGUMENT: "SCRIPT_ARGUMENT_REJECTED",
};

// Letters, digits and the punctuation a rooted POSIX path plus `name=value`
// needs. Everything a shell could act on — ; & | < > ( ) ` $ \ ' * ? [ ] { }
// ~ # ! % and every newline — is outside this set and never reaches the parser.
const SAFE_CHARACTER = /^[A-Za-z0-9_./:=+@,-]$/;

const refuse = (reason) => ({ ok: false, reason });

const isSafeText = (value) => {
  for (const character of value) {
    if (character === " " || character === "\t" || character === '"') continue;
    if (!SAFE_CHARACTER.test(character)) return false;
  }
  return true;
};

// Splits on whitespace and concatenates quoted with unquoted runs exactly as the
// shell does, because `NAME="/path"` — a bare name against a quoted value — is
// the shape the skill emits. The parser must agree with the shell about the
// resulting LITERAL and never be more clever than it: an unterminated quote is
// refused rather than guessed at, and the concatenated result is then held to
// the same whitelist as an unquoted token, so quoting can hide nothing.
const tokenize = (command) => {
  const tokens = [];
  let index = 0;
  while (index < command.length) {
    if (command[index] === " " || command[index] === "\t") {
      index += 1;
      continue;
    }
    let token = "";
    while (index < command.length && command[index] !== " " && command[index] !== "\t") {
      if (command[index] === '"') {
        const close = command.indexOf('"', index + 1);
        if (close === -1) return null;
        token += command.slice(index + 1, close);
        index = close + 1;
        continue;
      }
      token += command[index];
      index += 1;
    }
    tokens.push(token);
  }
  return tokens;
};

// Platform-aware on purpose. posix.isAbsolute rejects every native Windows
// spelling (`C:\x` and `C:/x` alike), which would refuse the diagnostic on the
// one host family that cannot spell a path any other way.
const isRootedLiteralPath = (value) => {
  if (typeof value !== "string" || value === "" || value.includes("\0")) return false;
  const rooted = msysDrivePrefix(value);
  return nodePath.isAbsolute(rooted) && !rooted.split(/[\\/]/).includes("..");
};

const assignmentViolation = (token, seen) => {
  const separator = token.indexOf("=");
  if (separator <= 0) return REASONS.SHAPE;
  const name = token.slice(0, separator);
  const value = token.slice(separator + 1);
  if (!Object.prototype.hasOwnProperty.call(ASSIGNMENTS, name)) return REASONS.ASSIGNMENT;
  if (seen.has(name)) return REASONS.DUPLICATE;
  const kind = ASSIGNMENTS[name];
  if (kind === "path" ? !isRootedLiteralPath(value) : !kind.has(value)) return REASONS.ASSIGNMENT;
  seen.add(name);
  return null;
};

// The path must BE the executing installation's own copy of that script — not a
// copy of it, not a link to it. lstat rather than realpath: a symlink that
// resolves to the right file is still a second name an attacker controls.
const scriptPathViolation = (token, pluginRoot, segments) => {
  if (!isRootedLiteralPath(token)) return REASONS.PATH;
  const rooted = msysDrivePrefix(token);
  if (nodePath.resolve(rooted) !== nodePath.resolve(nodePath.join(pluginRoot, ...segments))) {
    return REASONS.PATH;
  }
  let stat;
  try {
    stat = fs.lstatSync(rooted);
  } catch {
    return REASONS.NOT_REGULAR;
  }
  return stat.isFile() && stat.nlink === 1 ? null : REASONS.NOT_REGULAR;
};

// Trailing arguments are matched as exact literals against the script's own
// declared set, each at most once. This stays a whitelist for the same reason
// the assignment check is one: a blacklist would have to keep up with every flag
// a script ever grows, and the gate is what decides which invocation is allowed.
const argumentViolation = (tokens, allowed) => {
  const seen = new Set();
  for (const token of tokens) {
    if (!allowed.includes(token) || seen.has(token)) return REASONS.ARGUMENT;
    seen.add(token);
  }
  return null;
};

// Scans left to right instead of indexing from the end, because a recognized
// script may now carry a trailing argument and the path is no longer the last
// token. The shape is unchanged otherwise: assignments, then `bash`, then the
// script, then whatever that script declares.
function recognizeScript(payload, pluginRoot, spec) {
  if (!payload || typeof payload !== "object" || payload.tool_name !== "Bash") {
    return refuse(REASONS.NOT_BASH);
  }
  const input = payload.tool_input;
  const command = input && typeof input === "object" ? input.command : undefined;
  if (typeof command !== "string" || command.trim() === "") return refuse(REASONS.COMMAND_TYPE);
  if (Buffer.byteLength(command, "utf8") > COMMAND_MAX_BYTES) return refuse(REASONS.COMMAND_SIZE);
  if (!isSafeText(command)) return refuse(REASONS.CHARSET);

  const tokens = tokenize(command);
  if (tokens === null) return refuse(REASONS.QUOTING);

  const seen = new Set();
  let index = 0;
  while (index < tokens.length && ASSIGNMENT_TOKEN.test(tokens[index])) {
    const violation = assignmentViolation(tokens[index], seen);
    if (violation) return refuse(violation);
    index += 1;
  }
  if (tokens[index] !== INTERPRETER) return refuse(REASONS.SHAPE);
  index += 1;
  if (index >= tokens.length) return refuse(REASONS.SHAPE);
  const pathViolation = scriptPathViolation(tokens[index], pluginRoot, spec.segments);
  if (pathViolation) return refuse(pathViolation);
  const argViolation = argumentViolation(tokens.slice(index + 1), spec.args);
  if (argViolation) return refuse(argViolation);
  return { ok: true, reason: "" };
}

// Kept as the doctor-only recognizer so a caller that means "the read-only
// diagnostic" can still say exactly that and not accidentally admit the write.
function recognize(payload, pluginRoot) {
  return recognizeScript(payload, pluginRoot, RECOGNIZED.doctor);
}

function recognizeAny(payload, pluginRoot) {
  const doctor = recognizeScript(payload, pluginRoot, RECOGNIZED.doctor);
  if (doctor.ok) return doctor;
  const adopt = recognizeScript(payload, pluginRoot, RECOGNIZED.adopt);
  if (adopt.ok) return adopt;
  // Neither matched, so pick the more USEFUL refusal rather than a fixed one.
  // A doctor-first rule reports "wrong path" for an adoption invocation whose
  // only fault is an undeclared flag — true of the doctor entry, and useless to
  // the caller. Whichever entry got PAST its path check is the one the user was
  // actually invoking, so its reason is the one that names their mistake.
  const doctorPathRejected = doctor.reason === REASONS.PATH || doctor.reason === REASONS.NOT_REGULAR;
  const adoptPathRejected = adopt.reason === REASONS.PATH || adopt.reason === REASONS.NOT_REGULAR;
  if (doctorPathRejected && !adoptPathRejected) return adopt;
  return doctor;
}

const executingPluginRoot = () => nodePath.resolve(__dirname, "..", "..");

const isDoctorInvocation = (payload) =>
  PLATFORM_SUPPORTED && recognize(payload, executingPluginRoot()).ok;

// What every gate asks: is this one of the commands that must stay reachable
// while the session is unbound. Both are, for different reasons.
const isRecognizedInvocation = (payload) =>
  PLATFORM_SUPPORTED && recognizeAny(payload, executingPluginRoot()).ok;

if (require.main === module) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    raw += chunk;
    if (raw.length > COMMAND_MAX_BYTES * 4) {
      process.exit(1);
    }
  });
  process.stdin.on("end", () => {
    if (!PLATFORM_SUPPORTED) process.exit(1);
    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      process.exit(1);
    }
    process.exit(isRecognizedInvocation(payload) ? 0 : 1);
  });
} else {
  module.exports = {
    recognize, recognizeAny, recognizeScript,
    isDoctorInvocation, isRecognizedInvocation, executingPluginRoot,
    ASSIGNMENTS, REASONS, COMMAND_MAX_BYTES,
    DOCTOR_SEGMENTS, ADOPT_SEGMENTS, RECOGNIZED, PLATFORM_SUPPORTED,
  };
}
