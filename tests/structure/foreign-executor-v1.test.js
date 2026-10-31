"use strict";

const test = require("node:test");
const assert = require("node:assert");
const nodePath = require("node:path");

const modulePath = process.env.ZENSU_FOREIGN_EXECUTOR_UNIT_TARGET
  || nodePath.join(__dirname, "..", "..", "hooks", "lib", "foreign-executor-v1.js");
const { foreignExecutor, noticeText, noticeForPayload } = require(modulePath);
const reader = require(nodePath.join(nodePath.dirname(modulePath), "plan-payload-v1.js"));

const LDQ = String.fromCharCode(0x201c);
const RDQ = String.fromCharCode(0x201d);
const LSQ = String.fromCharCode(0x2018);
const RSQ = String.fromCharCode(0x2019);
const HEADER = "REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.";
const PLAN = `# Plan\n\n> **For Claude:** ${HEADER}\n\n1. add a function`;
const NOTICE = noticeText("superpowers:executing-plans");
const payload = (response) => ({
  hook_event_name: "PostToolUse", tool_name: "ExitPlanMode", tool_input: {}, tool_response: response,
});

test("a REQUIRED SUB-SKILL header or an execute-this-plan line names the executor it invokes", () => {
  assert.strictEqual(foreignExecutor(PLAN), "superpowers:executing-plans");
  assert.strictEqual(
    foreignExecutor("Implement this plan using the superpowers:subagent-driven-development skill."),
    "superpowers:subagent-driven-development",
  );
  assert.strictEqual(foreignExecutor("Execute the plan via the gsd:execute-phase skill."), "gsd:execute-phase");
  assert.strictEqual(foreignExecutor("Execute this plan with /gsd:execute-phase, one phase at a time."), "gsd:execute-phase");
});

test("a zensu: skill anywhere in the plan, fenced or quoted included, names no foreign executor", () => {
  for (const own of ["Then run /zensu:build.", "```\nzensu:build\n```", "`zensu:self-review`", "\"Zensu:Build\""]) {
    assert.strictEqual(foreignExecutor(`${PLAN}\n${own}`), "", own);
  }
});

test("a skill that is only mentioned, or a line without an execute instruction, names no executor", () => {
  assert.strictEqual(foreignExecutor("1. Implement superpowers:brainstorming skill improvements"), "");
  assert.strictEqual(foreignExecutor("Use superpowers:executing-plans for the next feature."), "");
  assert.strictEqual(foreignExecutor("Implement this plan; see docs:intro for background."), "");
});

test("fenced code names no executor, in nested, quoted and longer fences, and a header after a closed fence does", () => {
  for (const fenced of [
    `\`\`\`\n${HEADER}\n\`\`\``,
    `~~~\n${HEADER}\n~~~`,
    `- \`\`\`\n  ${HEADER}\n  \`\`\``,
    `> \`\`\`\n> ${HEADER}\n> \`\`\``,
    `\`\`\`\`\n\`\`\`\n${HEADER}\n\`\`\`\``,
    `\`\`\`markdown\n${HEADER}\n\`\`\``,
  ]) {
    assert.strictEqual(foreignExecutor(fenced), "", fenced);
  }
  assert.strictEqual(foreignExecutor(`\`\`\`\ncode\n\`\`\`\n${HEADER}`), "superpowers:executing-plans");
});

test("inline code, double-backtick spans and straight or typographic quotes name no executor", () => {
  for (const quoted of [
    `Document \`${HEADER}\` in the README.`,
    `Document \`\`${HEADER}\`\` in the README.`,
    `Document "${HEADER}" in the README.`,
    `Document ${LDQ}${HEADER}${RDQ} in the README.`,
    `Document ${LSQ}${HEADER}${RSQ} in the README.`,
  ]) {
    assert.strictEqual(foreignExecutor(quoted), "", quoted);
  }
});

test("a negated execute instruction names no executor", () => {
  for (const negated of [
    "Do not implement this plan with the superpowers:executing-plans skill.",
    "Never execute this plan via /gsd:execute-phase.",
    "Don't use superpowers:executing-plans to implement this plan.",
    `Don${RSQ}t execute the plan with /gsd:execute-phase.`,
  ]) {
    assert.strictEqual(foreignExecutor(negated), "", negated);
  }
});

test("CRLF plans read like LF plans, the first invoked name wins, and a non-string plan names none", () => {
  assert.strictEqual(foreignExecutor(`# Plan\r\n${HEADER}\r\n`), "superpowers:executing-plans");
  assert.strictEqual(foreignExecutor(`\`\`\`\r\n${HEADER}\r\n\`\`\`\r\n`), "");
  assert.strictEqual(
    foreignExecutor(`Execute this plan with /gsd:execute-phase.\n${HEADER}`), "gsd:execute-phase",
  );
  for (const value of [undefined, null, 42, {}, []]) assert.strictEqual(foreignExecutor(value), "");
});

test("the notice names the executor and the way back to the Zensu workflow, and asks nothing", () => {
  assert.ok(NOTICE.includes(
    "the approved plan names its own executor, superpowers:executing-plans, so Zensu asks no delivery-route question for it",
  ));
  assert.ok(NOTICE.includes("because the plan names superpowers:executing-plans, and that /zensu:build runs this plan"));
  assert.ok(NOTICE.includes("/zensu:build runs this plan under the Zensu workflow"));
  assert.ok(!NOTICE.includes("AskUserQuestion"));
  assert.ok(!NOTICE.includes("ZENSU DELIVERY ROUTE:"));
  assert.ok(NOTICE.length <= 1200);
  assert.match(NOTICE, /^[\x20-\x7e]+$/);
});

test("an ExitPlanMode payload from the main session gets the notice through the response and the input carrier", () => {
  assert.strictEqual(noticeForPayload(payload({ plan: PLAN, isAgent: false, hasTaskTool: true }), reader), NOTICE);
  assert.strictEqual(noticeForPayload(payload({ plan: PLAN }), reader), NOTICE);
  assert.strictEqual(noticeForPayload({ tool_name: "ExitPlanMode", tool_input: { plan: PLAN } }, reader), NOTICE);
});

test("an agent-origin response and a non-boolean isAgent keep the route question", () => {
  assert.strictEqual(noticeForPayload(payload({ plan: PLAN, isAgent: true }), reader), "");
  for (const drifted of ["false", "true", 0, 1, {}]) {
    assert.strictEqual(noticeForPayload(payload({ plan: PLAN, isAgent: drifted }), reader), "", JSON.stringify(drifted));
  }
});

test("the caller origin is judged before any plan source is read", () => {
  let walked = 0;
  const spy = { ...reader, resolveApprovedPlan: (...args) => { walked += 1; return reader.resolveApprovedPlan(...args); } };
  assert.strictEqual(noticeForPayload(payload({ plan: PLAN, isAgent: true }), spy), "");
  assert.strictEqual(walked, 0);
  assert.strictEqual(noticeForPayload(payload({ plan: PLAN, isAgent: false }), spy), NOTICE);
  assert.strictEqual(walked, 1);
});

test("another tool's payload, a refused plan source and a plan without a foreign executor keep the route question", () => {
  assert.strictEqual(noticeForPayload({ ...payload({ plan: PLAN }), tool_name: "Write" }, reader), "");
  assert.strictEqual(noticeForPayload(payload({ plan: 42 }), reader), "");
  assert.strictEqual(noticeForPayload(payload({ plan: "# Plan\n\n1. add a function" }), reader), "");
  for (const value of [undefined, null, "ExitPlanMode", []]) assert.strictEqual(noticeForPayload(value, reader), "");
});

test("a reader that is missing, incomplete, throws or answers out of shape keeps the route question", () => {
  const good = payload({ plan: PLAN, isAgent: false });
  for (const broken of [
    undefined,
    {},
    { ...reader, responseOrigin: undefined },
    { ...reader, resolveApprovedPlan: undefined },
    { ...reader, SOURCES: [] },
    { ...reader, SOURCES: "tool_response.plan" },
    { ...reader, responseOrigin: () => { throw new Error("origin fault"); } },
    { ...reader, resolveApprovedPlan: () => { throw new Error("reader fault"); } },
    { ...reader, responseOrigin: () => ({ ok: "yes" }) },
    { ...reader, resolveApprovedPlan: () => ({ ok: true }) },
  ]) {
    assert.strictEqual(noticeForPayload(good, broken), "");
  }
  assert.strictEqual(noticeForPayload(good, reader), NOTICE);
});
