'use strict';

// Reads a Claude Code session transcript and answers ONE question: was the most
// recent reviewer subagent spawn refused by the HOST permission layer?
//
// A refused tool call never executes, so no PreToolUse/PostToolUse hook can
// observe it. The Stop payload's `transcript_path` is the only channel that
// carries the evidence. Three conditions must hold together before a refusal is
// declared, and NONE of them is sufficient alone:
//
//   1. structural keying — `tool_use_id` -> the `Agent`/`Task` tool_use it
//      answers -> that call's `subagent_type`;
//   2. the host's own error flag, `is_error === true`;
//   3. the result text STARTS with a marker.
//
// Condition 1 alone is not enough, and assuming it was is the defect this
// header used to describe: for an `Agent` call the tool_result body IS the
// subagent's returned message, so a reviewer that merely QUOTES a denial
// literal — reviewing this very module, for instance — would be read as a
// refusal, and the chain would be abandoned while a real review sat in hand.
// Conditions 2 and 3 are what the model cannot author.
//
// DENIAL_MARKERS are host-emitted literals, read out of the installed Claude
// Code binary (2.1.240). They are matched as prefixes: the host appends a
// `Reason: ...` tail that is not part of the contract.
//
// Both literals were re-read out of 2.1.237, 2.1.239 and 2.1.240 and are
// byte-identical across all three, so the prefix rule below still holds against
// the shipping host. The refusal the host actually writes into the transcript
// continues past the `Reason: ` tail into several sentences of advice; only the
// prefix is contracted.
//
// The same transcript entry ALSO carries a host-native `toolDenialKind` beside
// `message` (observed value `automode-blocked`). It is deliberately NOT read:
// it is an undocumented, unversioned host field whose absence would be
// indistinguishable from a clean spawn, and it buys nothing the three
// conditions below do not already establish. Recorded here so a future reader
// knows it was seen and declined, not missed.
//
// The CLI's single output line is a PARSED CONTRACT, not a display string:
// `status=<s> kind=<k> tool=<n> spawns=<n> denials=<n>`. The shell caller in
// hooks/stop-chain-enforcer.sh matches `status=` first and `kind=` with a space
// on both sides, so field order and separators are load-bearing.
//
// This module is a diagnostic, never a gate: `scanTranscript` never throws and
// the CLI always exits 0. A verdict it cannot establish is `none`/`unreadable`/
// `errored`, which every caller must treat as "no detection, existing behavior
// stands".
//
// `errored` exists because `clear` is a POSITIVE claim, not the absence of one,
// and the shell acts on it by RETIRING the refusal note. A result that is keyed
// to a reviewer spawn and carries the host's own `is_error` but matches no
// marker is a refusal this module does not recognize — a reworded host message,
// a subagent crash, a transport failure. Reporting that as `clear` would delete
// a correct diagnosis written by an earlier, recognized refusal. It gets its own
// verdict so callers can fall through instead, exactly as they do for `none`.

const fs = require('node:fs');

const DENIAL_MARKERS = Object.freeze([
  Object.freeze({
    kind: 'auto-mode-classifier',
    text: 'Permission for this action was denied by the Claude Code auto mode classifier.',
  }),
  Object.freeze({
    kind: 'permission-denied',
    text: 'Permission for this action has been denied.',
  }),
]);

// The build the two literals above were read out of. Exported and pinned by the
// unit suite against the header text, so the version cannot be edited in one
// place and left stale in the other — a reworded host message is invisible to
// every other check in this repo, and this is the line that forces a human to
// re-verify rather than assume.
const DENIAL_MARKERS_SOURCE_BUILD = '2.1.240';

const REVIEWER_SUBAGENT_TYPE = 'zensu:code-reviewer';
const SPAWN_TOOL_NAMES = Object.freeze(['Agent', 'Task']);
const MAX_TAIL_BYTES = 4 * 1024 * 1024;
const MAX_LINES = 20000;
// Built rather than written literally: a raw NUL byte in a source file is
// invisible in review and mangled by ordinary text tooling.
const NUL_BYTE = String.fromCharCode(0);

function verdict(status, extra) {
  return Object.assign({
    status: status,
    kind: '',
    toolName: '',
    subagentType: '',
    spawns: 0,
    denials: 0,
  }, extra || {});
}

// The path comes from the host payload, and this runs on the Stop path with no
// timeout above it: a FIFO would block the open forever and wedge the very turn
// this module exists to unwedge. lstat decides the shape BEFORE the open, and
// O_NOFOLLOW/O_NONBLOCK close the window between the two.
// The win32 conjunct is this repo's pinned secure-open spelling: O_NOFOLLOW is
// not available on every Windows Node build, and the lstat above is what covers
// the path lookup where it is missing.
function readOnlyFlags() {
  const noFollow = process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)
    ? fs.constants.O_NOFOLLOW : 0;
  const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;
  return fs.constants.O_RDONLY | noFollow | nonBlock;
}

function readTail(transcriptPath) {
  if (transcriptPath.indexOf(NUL_BYTE) !== -1) return { error: 'unreadable' };
  let pre;
  try {
    pre = fs.lstatSync(transcriptPath);
  } catch (e) {
    return { error: 'unreadable' };
  }
  if (!pre.isFile()) return { error: 'unreadable' };
  let fd;
  try {
    fd = fs.openSync(transcriptPath, readOnlyFlags());
  } catch (e) {
    return { error: 'unreadable' };
  }
  try {
    const st = fs.fstatSync(fd);
    if (!st.isFile()) return { error: 'unreadable' };
    const size = st.size;
    if (size === 0) return { text: '', truncated: false };
    const start = size > MAX_TAIL_BYTES ? size - MAX_TAIL_BYTES : 0;
    const length = size - start;
    const buf = Buffer.allocUnsafe(length);
    let read = 0;
    while (read < length) {
      const n = fs.readSync(fd, buf, read, length - read, start + read);
      if (n <= 0) break;
      read += n;
    }
    return { text: buf.toString('utf8', 0, read), truncated: start > 0 };
  } catch (e) {
    return { error: 'unreadable' };
  } finally {
    try { fs.closeSync(fd); } catch (e) { /* already closed */ }
  }
}

function resultText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  const parts = [];
  for (const block of content) {
    if (block && typeof block === 'object' && typeof block.text === 'string') parts.push(block.text);
    else if (typeof block === 'string') parts.push(block);
  }
  return parts.join('\n');
}

function matchMarker(block) {
  if (!block || block.is_error !== true) return null;
  const text = resultText(block.content).trimStart();
  if (!text) return null;
  for (const marker of DENIAL_MARKERS) {
    if (text.startsWith(marker.text)) return marker;
  }
  return null;
}

function scanTranscript(transcriptPath, options) {
  const opts = options || {};
  const subagentType = typeof opts.subagentType === 'string' && opts.subagentType
    ? opts.subagentType
    : REVIEWER_SUBAGENT_TYPE;
  if (typeof transcriptPath !== 'string' || !transcriptPath) {
    return verdict('none', { subagentType: subagentType });
  }
  const tail = readTail(transcriptPath);
  if (tail.error) return verdict('unreadable', { subagentType: subagentType });

  let lines = tail.text.split('\n');
  if (tail.truncated && lines.length) lines = lines.slice(1);
  if (lines.length > MAX_LINES) lines = lines.slice(lines.length - MAX_LINES);

  const spawnIds = new Map();
  let last = null;
  let spawns = 0;
  let denials = 0;

  for (const line of lines) {
    if (!line || line.charAt(0) !== '{') continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (e) {
      continue;
    }
    const message = entry && typeof entry === 'object' ? entry.message : null;
    const content = message && typeof message === 'object' ? message.content : null;
    if (!Array.isArray(content)) continue;
    for (const block of content) {
      if (!block || typeof block !== 'object') continue;
      if (block.type === 'tool_use') {
        if (typeof block.id !== 'string' || !block.id) continue;
        if (SPAWN_TOOL_NAMES.indexOf(block.name) === -1) continue;
        const input = block.input && typeof block.input === 'object' ? block.input : {};
        if (input.subagent_type !== subagentType) continue;
        spawnIds.set(block.id, block.name);
        spawns += 1;
        continue;
      }
      if (block.type !== 'tool_result') continue;
      if (typeof block.tool_use_id !== 'string') continue;
      const toolName = spawnIds.get(block.tool_use_id);
      if (!toolName) continue;
      const marker = matchMarker(block);
      if (marker) denials += 1;
      // The host's error flag is carried out separately from the marker match:
      // together they are a refusal, but the flag ALONE is an error this module
      // cannot classify, and that must not be reported as a clean spawn.
      last = {
        toolName: toolName,
        kind: marker ? marker.kind : '',
        isError: block.is_error === true,
      };
    }
  }

  if (!last) return verdict('none', { subagentType: subagentType, spawns: spawns });
  const status = last.kind ? 'blocked' : (last.isError ? 'errored' : 'clear');
  return verdict(status, {
    kind: last.kind,
    toolName: last.toolName,
    subagentType: subagentType,
    spawns: spawns,
    denials: denials,
  });
}

function main(argv) {
  let transcriptPath = '';
  let subagentType = REVIEWER_SUBAGENT_TYPE;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--transcript' && i + 1 < argv.length) { transcriptPath = argv[i + 1]; i += 1; }
    else if (argv[i] === '--subagent-type' && i + 1 < argv.length) { subagentType = argv[i + 1]; i += 1; }
  }
  let report;
  try {
    report = scanTranscript(transcriptPath, { subagentType: subagentType });
  } catch (e) {
    report = verdict('unreadable', { subagentType: subagentType });
  }
  process.stdout.write([
    'status=' + report.status,
    'kind=' + report.kind,
    'tool=' + report.toolName,
    'spawns=' + report.spawns,
    'denials=' + report.denials,
  ].join(' ') + '\n');
  return 0;
}

module.exports = {
  DENIAL_MARKERS: DENIAL_MARKERS,
  DENIAL_MARKERS_SOURCE_BUILD: DENIAL_MARKERS_SOURCE_BUILD,
  REVIEWER_SUBAGENT_TYPE: REVIEWER_SUBAGENT_TYPE,
  SPAWN_TOOL_NAMES: SPAWN_TOOL_NAMES,
  MAX_TAIL_BYTES: MAX_TAIL_BYTES,
  MAX_LINES: MAX_LINES,
  // Exported so the open flags can be pinned directly. The lstat shape guard in
  // readTail answers first for a FIFO and for a symlink, so a test driving those
  // paths exercises the guard and never reaches the open — leaving the flags
  // themselves uncovered unless the composition is asserted here.
  readOnlyFlags: readOnlyFlags,
  scanTranscript: scanTranscript,
  main: main,
};

if (require.main === module) {
  process.exitCode = main(process.argv.slice(2));
}
