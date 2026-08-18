// Unit pins for hooks/lib/zensu-doctor-invocation.js — the doctor allowlist.
//
// Driven by tests/structure/test-versioned-plugin-upgrade.sh (the AC-011 block),
// which also pins the end-to-end behavior through every hook on the Bash matcher
// (AC-C04) and the shell principal conjunct (FR-C03). Nothing else referenced
// this file, which is how a constant rename once left it red while run-all.sh
// stayed green. This file pins what the shell
// layer structurally cannot reach: the refusal codes, the tokenizer's quoting
// branches, the whitelist's edges, and the filesystem shapes (symlink, hard
// link, directory) that a synthetic tree can express but a live plugin root
// cannot.
//
// The recognizer is the ONE thing standing between a relaxed bind failure and a
// second command riding in on the diagnostic, so every case here that expects
// `ok: false` is a bite, not decoration.

"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const nodePath = require("node:path");

const modulePath = nodePath.join(__dirname, "..", "..", "hooks", "lib", "zensu-doctor-invocation.js");
const {
  recognize, recognizeAny, isDoctorInvocation, isRecognizedInvocation, executingPluginRoot,
  ASSIGNMENTS, REASONS, COMMAND_MAX_BYTES, DOCTOR_SEGMENTS, ADOPT_SEGMENTS, RECOGNIZED,
} = require(modulePath);

const tmpRoot = fs.mkdtempSync(nodePath.join(fs.realpathSync(os.tmpdir()), "zensu-doctor-invocation-"));
process.on("exit", () => { try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch (_) {} });

const pluginRoot = nodePath.join(tmpRoot, "plugin");
const doctorPath = nodePath.join(pluginRoot, ...DOCTOR_SEGMENTS);
fs.mkdirSync(nodePath.dirname(doctorPath), { recursive: true });
fs.writeFileSync(doctorPath, "#!/bin/bash\nexit 0\n");

const adoptPath = nodePath.join(pluginRoot, ...ADOPT_SEGMENTS);
fs.writeFileSync(adoptPath, "#!/bin/bash\nexit 0\n");

const dataDir = nodePath.join(tmpRoot, "plugin-data");
const projectDir = nodePath.join(tmpRoot, "project");
fs.mkdirSync(dataDir, { recursive: true });
fs.mkdirSync(projectDir, { recursive: true });

const payload = (command, toolName = "Bash") => ({
  hook_event_name: "PreToolUse",
  session_id: "unit-session",
  tool_name: toolName,
  tool_input: { command },
});

const verdict = (command, toolName) => recognize(payload(command, toolName), pluginRoot);
const canonical = `CLAUDE_PLUGIN_DATA="${dataDir}" CLAUDE_PROJECT_DIR="${projectDir}" ZDOC_PLAYWRIGHT_TOOLS=ready bash "${doctorPath}"`;

test("the canonical skill invocation is recognized", () => {
  assert.deepStrictEqual(verdict(canonical), { ok: true, reason: "" });
});

test("the bare invocation with no assignments is recognized", () => {
  assert.strictEqual(verdict(`bash "${doctorPath}"`).ok, true);
});

test("an unquoted path is recognized — quoting is the model's choice, not a signal", () => {
  assert.strictEqual(verdict(`bash ${doctorPath}`).ok, true);
});

test("assignment order is free and extra whitespace is tolerated", () => {
  const reordered = `ZDOC_PLAYWRIGHT_TOOLS=ready   CLAUDE_PROJECT_DIR="${projectDir}"  bash  "${doctorPath}"`;
  assert.strictEqual(verdict(reordered).ok, true);
});

test("a non-Bash tool never matches", () => {
  assert.deepStrictEqual(verdict(canonical, "Read"), { ok: false, reason: REASONS.NOT_BASH });
});

test("a payload with no command refuses on type, not shape", () => {
  assert.strictEqual(recognize({ tool_name: "Bash", tool_input: {} }, pluginRoot).reason, REASONS.COMMAND_TYPE);
  assert.strictEqual(recognize({ tool_name: "Bash" }, pluginRoot).reason, REASONS.COMMAND_TYPE);
  assert.strictEqual(recognize(null, pluginRoot).reason, REASONS.NOT_BASH);
});

test("every shell operator that could carry a second command is refused on the charset", () => {
  const riders = [
    `${canonical}; rm -rf /`,
    `${canonical} && whoami`,
    `${canonical} || whoami`,
    `${canonical} | tee /tmp/x`,
    `${canonical} & `,
    `${canonical} > /tmp/out`,
    `${canonical} 2>&1`,
    `${canonical}\nwhoami`,
    `bash "${doctorPath}" $(whoami)`,
    "bash `echo /x`",
    `bash "${doctorPath}" \\; whoami`,
    `bash '${doctorPath}'`,
    `bash "${doctorPath}"*`,
    `bash ~/x`,
    `CLAUDE_PLUGIN_DATA=$HOME bash "${doctorPath}"`,
  ];
  for (const rider of riders) {
    assert.strictEqual(verdict(rider).reason, REASONS.CHARSET, `expected charset refusal for: ${rider}`);
  }
});

test("an unterminated quote is refused rather than guessed at", () => {
  assert.strictEqual(verdict(`bash "${doctorPath}`).reason, REASONS.QUOTING);
  assert.strictEqual(verdict(`CLAUDE_PROJECT_DIR="${projectDir} bash "${doctorPath}"`).reason, REASONS.QUOTING);
});

test("quoting cannot hide a token — the concatenated literal faces the same whitelist", () => {
  assert.strictEqual(verdict(`bash "${doctorPath}"x`).reason, REASONS.PATH);
  assert.strictEqual(verdict(`bash x"${doctorPath}"`).reason, REASONS.PATH);
  assert.strictEqual(verdict(`"CLAUDE_PLUGIN_DATA"="${dataDir}" bash "${doctorPath}"`).ok, true);
  assert.strictEqual(verdict(`PA"TH"=/x bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
});

// The scan runs left to right — assignments, `bash`, the script, then whatever
// that script DECLARES — because a recognized script may now carry a trailing
// argument, so the path is no longer the last token. A trailing token is
// therefore an ARGUMENT question, not a shape one, and the doctor declares none.
test("the interpreter must be the bare word bash, and the doctor declares no arguments", () => {
  assert.strictEqual(verdict(`sh "${doctorPath}"`).reason, REASONS.SHAPE);
  assert.strictEqual(verdict(`/bin/bash "${doctorPath}"`).reason, REASONS.SHAPE);
  assert.strictEqual(verdict(`bash`).reason, REASONS.SHAPE);
  assert.strictEqual(verdict(`bash "${doctorPath}" extra`).reason, REASONS.ARGUMENT);
  assert.strictEqual(verdict(`bash "${doctorPath}" --confirm`).reason, REASONS.ARGUMENT);
});

test("an assignment outside the allowlist is refused", () => {
  assert.strictEqual(verdict(`PATH=/x bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
  assert.strictEqual(verdict(`ZENSU_TDD_GATE=off bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
  assert.strictEqual(verdict(`ZENSU_BASH_WRITE_GATE=off bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
});

test("a duplicated assignment is refused so a later value cannot shadow a checked one", () => {
  const duplicated = `CLAUDE_PLUGIN_DATA="${dataDir}" CLAUDE_PLUGIN_DATA="${projectDir}" bash "${doctorPath}"`;
  assert.strictEqual(verdict(duplicated).reason, REASONS.DUPLICATE);
});

test("a path-kind assignment must be rooted and traversal-free", () => {
  assert.strictEqual(verdict(`CLAUDE_PROJECT_DIR=relative bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
  assert.strictEqual(verdict(`CLAUDE_PROJECT_DIR=/a/../b bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
  assert.strictEqual(verdict(`CLAUDE_PROJECT_DIR= bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
});

test("a Set-kind assignment accepts only its declared members", () => {
  assert.strictEqual(verdict(`ZDOC_PLAYWRIGHT_TOOLS=1 bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
  assert.strictEqual(verdict(`ZDOC_PLAYWRIGHT_TOOLS=ready bash "${doctorPath}"`).ok, true);
});

test("ZDOC_PLAYWRIGHT is NOT reachable — only the tools signal is", () => {
  assert.ok(!Object.prototype.hasOwnProperty.call(ASSIGNMENTS, "ZDOC_PLAYWRIGHT"));
  assert.strictEqual(verdict(`ZDOC_PLAYWRIGHT=ready bash "${doctorPath}"`).reason, REASONS.ASSIGNMENT);
});

test("a doctor script outside the executing plugin root is refused", () => {
  const foreign = nodePath.join(tmpRoot, "other", ...DOCTOR_SEGMENTS);
  fs.mkdirSync(nodePath.dirname(foreign), { recursive: true });
  fs.writeFileSync(foreign, "#!/bin/bash\nexit 0\n");
  assert.strictEqual(verdict(`bash "${foreign}"`).reason, REASONS.PATH);
  assert.strictEqual(verdict(`bash "${nodePath.join(pluginRoot, "hooks", "lib", "zensu-log.sh")}"`).reason, REASONS.PATH);
});

test("a symlink to the real doctor script is refused even though it resolves correctly", () => {
  const link = nodePath.join(tmpRoot, "link-plugin", ...DOCTOR_SEGMENTS);
  fs.mkdirSync(nodePath.dirname(link), { recursive: true });
  fs.symlinkSync(doctorPath, link);
  assert.strictEqual(fs.realpathSync(link), fs.realpathSync(doctorPath));
  assert.strictEqual(recognize(payload(`bash "${link}"`), nodePath.join(tmpRoot, "link-plugin")).reason, REASONS.NOT_REGULAR);
});

test("a hard link is refused — a second name for the file is still a second name", () => {
  const linked = nodePath.join(tmpRoot, "hardlink-plugin", ...DOCTOR_SEGMENTS);
  fs.mkdirSync(nodePath.dirname(linked), { recursive: true });
  fs.linkSync(doctorPath, linked);
  assert.strictEqual(recognize(payload(`bash "${linked}"`), nodePath.join(tmpRoot, "hardlink-plugin")).reason, REASONS.NOT_REGULAR);
});

test("a missing or non-regular doctor path is refused", () => {
  const absentRoot = nodePath.join(tmpRoot, "absent-plugin");
  const absent = nodePath.join(absentRoot, ...DOCTOR_SEGMENTS);
  assert.strictEqual(recognize(payload(`bash "${absent}"`), absentRoot).reason, REASONS.NOT_REGULAR);

  const dirRoot = nodePath.join(tmpRoot, "dir-plugin");
  fs.mkdirSync(nodePath.join(dirRoot, ...DOCTOR_SEGMENTS), { recursive: true });
  assert.strictEqual(recognize(payload(`bash "${nodePath.join(dirRoot, ...DOCTOR_SEGMENTS)}"`), dirRoot).reason, REASONS.NOT_REGULAR);
});

test("an oversized command is refused before it is parsed", () => {
  const padded = `bash "${doctorPath}"${" ".repeat(COMMAND_MAX_BYTES)}`;
  assert.strictEqual(verdict(padded).reason, REASONS.COMMAND_SIZE);
});

// A POSIX host cannot observe the Windows branch, so this pins the DELEGATION
// instead: the MSYS drive rule is shared through claude-path-v1.js and must never
// be hand-copied here. A private copy would drift from the one the source-write
// gate and the session-control trust boundary already share.
test("the MSYS drive rule is delegated, never re-derived in this file", () => {
  const source = fs.readFileSync(modulePath, "utf8");
  assert.match(source, /require\(["']\.\/claude-path-v1\.js["']\)/);
  assert.match(source, /msysDrivePrefix/);
  const privateDriveRules = source.match(/\(\[A-Za-z\]\)/g) || [];
  assert.deepStrictEqual(privateDriveRules, [], "no private drive-prefix regex may reappear here");
  // Matches the CALL, not the word: the rationale comment names posix.isAbsolute
  // to explain why it is wrong here, and a bare-phrase match would fail on it.
  assert.ok(!/nodePath\.posix\./.test(source), "posix path helpers refuse every native Windows spelling");
});

test("on this POSIX host an MSYS-looking path stays an ordinary path", () => {
  const msysLooking = nodePath.join(tmpRoot, "d");
  const root = nodePath.join(msysLooking, "plugin");
  fs.mkdirSync(nodePath.join(root, "hooks", "lib"), { recursive: true });
  fs.writeFileSync(nodePath.join(root, ...DOCTOR_SEGMENTS), "#!/bin/bash\nexit 0\n");
  assert.strictEqual(recognize(payload(`bash "${nodePath.join(root, ...DOCTOR_SEGMENTS)}"`), root).ok, true);
});

test("isDoctorInvocation binds the REAL executing root, which the unit tree is not", () => {
  assert.strictEqual(executingPluginRoot(), nodePath.resolve(__dirname, "..", ".."));
  assert.strictEqual(isDoctorInvocation(payload(`bash "${doctorPath}"`)), false);
  const live = nodePath.join(executingPluginRoot(), ...DOCTOR_SEGMENTS);
  assert.strictEqual(isDoctorInvocation(payload(`bash "${live}"`)), true);
});

// The SECOND recognized script. It is admitted on its own justification and — the
// whole point of the per-script argument table — it is the only one that may carry
// `--confirm`, the literal that turns a report into a write.
const anyVerdict = (command, toolName) => recognizeAny(payload(command, toolName), pluginRoot);

test("the adoption is recognized bare and with exactly one --confirm", () => {
  assert.strictEqual(anyVerdict(`bash "${adoptPath}"`).ok, true);
  assert.strictEqual(anyVerdict(`bash "${adoptPath}" --confirm`).ok, true);
  assert.strictEqual(
    anyVerdict(`CLAUDE_PLUGIN_DATA="${dataDir}" CLAUDE_PROJECT_DIR="${projectDir}" bash "${adoptPath}" --confirm`).ok,
    true,
  );
});

test("the adoption declares exactly one argument and refuses every other shape", () => {
  assert.strictEqual(anyVerdict(`bash "${adoptPath}" --force`).reason, REASONS.ARGUMENT);
  assert.strictEqual(anyVerdict(`bash "${adoptPath}" --confirm --confirm`).reason, REASONS.ARGUMENT);
  assert.strictEqual(anyVerdict(`bash "${adoptPath}" --confirm extra`).reason, REASONS.ARGUMENT);
  assert.strictEqual(anyVerdict(`EVIL=1 bash "${adoptPath}"`).reason, REASONS.ASSIGNMENT);
  assert.strictEqual(anyVerdict(`bash "${adoptPath}"; whoami`).reason, REASONS.CHARSET);
});

// The doctor-only predicate must stay doctor-only: a caller that means "the
// read-only diagnostic" has to be able to say exactly that without admitting the
// write. RECOGNIZED stays at two entries for the same reason.
test("isDoctorInvocation never admits the write, and the recognized list stays at two", () => {
  const liveAdopt = nodePath.join(executingPluginRoot(), ...ADOPT_SEGMENTS);
  const liveDoctor = nodePath.join(executingPluginRoot(), ...DOCTOR_SEGMENTS);
  assert.strictEqual(isDoctorInvocation(payload(`bash "${liveAdopt}" --confirm`)), false);
  assert.strictEqual(isRecognizedInvocation(payload(`bash "${liveAdopt}" --confirm`)), true);
  assert.strictEqual(isRecognizedInvocation(payload(`bash "${liveDoctor}"`)), true);
  assert.deepStrictEqual(Object.keys(RECOGNIZED).sort(), ["adopt", "doctor"]);
  assert.deepStrictEqual(RECOGNIZED.doctor.args, []);
  assert.deepStrictEqual(RECOGNIZED.adopt.args, ["--confirm"]);
});
