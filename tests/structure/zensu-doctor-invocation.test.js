// Unit pins for hooks/lib/zensu-doctor-invocation.js — the doctor allowlist.
//
// Driven by tests/structure/test-doctor-reachability.sh, which pins the
// end-to-end behavior through the four gates. This file pins what the shell
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
  recognize, isDoctorInvocation, executingPluginRoot,
  ASSIGNMENTS, REASONS, COMMAND_MAX_BYTES, DOCTOR_SEGMENTS,
} = require(modulePath);

const tmpRoot = fs.mkdtempSync(nodePath.join(fs.realpathSync(os.tmpdir()), "zensu-doctor-invocation-"));
process.on("exit", () => { try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch (_) {} });

const pluginRoot = nodePath.join(tmpRoot, "plugin");
const doctorPath = nodePath.join(pluginRoot, ...DOCTOR_SEGMENTS);
fs.mkdirSync(nodePath.dirname(doctorPath), { recursive: true });
fs.writeFileSync(doctorPath, "#!/bin/bash\nexit 0\n");

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

test("the interpreter must be the bare word bash in the second-to-last position", () => {
  assert.strictEqual(verdict(`sh "${doctorPath}"`).reason, REASONS.SHAPE);
  assert.strictEqual(verdict(`/bin/bash "${doctorPath}"`).reason, REASONS.SHAPE);
  assert.strictEqual(verdict(`bash`).reason, REASONS.SHAPE);
  assert.strictEqual(verdict(`bash "${doctorPath}" extra`).reason, REASONS.SHAPE);
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

test("isDoctorInvocation binds the REAL executing root, which the unit tree is not", () => {
  assert.strictEqual(executingPluginRoot(), nodePath.resolve(__dirname, "..", ".."));
  assert.strictEqual(isDoctorInvocation(payload(`bash "${doctorPath}"`)), false);
  const live = nodePath.join(executingPluginRoot(), ...DOCTOR_SEGMENTS);
  assert.strictEqual(isDoctorInvocation(payload(`bash "${live}"`)), true);
});
