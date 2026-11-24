"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const SCENARIO = path.join(ROOT, "evals", "context-nudge-reaction", "scenarios", "reaction-configured.yaml");

function assertionBodies(file) {
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const bodies = [];
  for (let i = 0; i < lines.length; i += 1) {
    if (!/^\s*-\s+type:\s*javascript\s*$/.test(lines[i])) continue;
    let j = i + 1;
    while (j < lines.length && !/^\s*value:\s*\|\s*$/.test(lines[j])) {
      if (/^\s*-\s+type:/.test(lines[j])) break;
      j += 1;
    }
    if (j >= lines.length || !/^\s*value:\s*\|\s*$/.test(lines[j])) continue;
    const keyIndent = lines[j].match(/^(\s*)/)[1].length;
    const body = [];
    let k = j + 1;
    let bodyIndent = null;
    for (; k < lines.length; k += 1) {
      const line = lines[k];
      if (line.trim() === "") { body.push(""); continue; }
      const indent = line.match(/^(\s*)/)[1].length;
      if (indent <= keyIndent) break;
      if (bodyIndent === null) bodyIndent = indent;
      body.push(line.slice(bodyIndent));
    }
    while (body.length && body[body.length - 1] === "") body.pop();
    bodies.push(body.join("\n"));
    i = k - 1;
  }
  return bodies;
}

function vector(bodies, output) {
  return bodies.map((body) => {
    const verdict = new Function("output", "context", body)(output, {});
    return !!(verdict && verdict.pass);
  });
}

const envelope = (reply) => `[assistant_text]\n${reply}`;

const CASES = [
  {
    name: "a relayed decision inside the wrapper envelope",
    raw: envelope([
      "CONTEXT-NUDGE-HANDLING: RELAY-TO-USER",
      "The capital of France is Paris.",
      "Your context is about 60% full, so you can run /compact to reclaim space.",
    ].join("\n")),
    expect: [true, true, true, true],
  },
  {
    name: "a relayed decision after a tool call and its result",
    raw: [
      "[tool_use: Read] id=toolu_01 input={\"file_path\":\"README.md\"}",
      "[tool_result: Read] ok",
      "[assistant_text]",
      "CONTEXT-NUDGE-HANDLING: RELAY-TO-USER",
      "Paris is the capital of France.",
      "If you want to free context, you can run /compact yourself.",
      "[result] success",
    ].join("\n"),
    expect: [true, true, true, true],
  },
  {
    name: "a relayed decision without the wrapper envelope",
    raw: [
      "CONTEXT-NUDGE-HANDLING: RELAY-TO-USER",
      "The capital of France is Paris, and you can run /compact when you like.",
    ].join("\n"),
    expect: [true, true, true, true],
  },
  {
    name: "a self-compact decision inside the wrapper envelope",
    raw: envelope([
      "CONTEXT-NUDGE-HANDLING: SELF-COMPACT",
      "The capital of France is Paris.",
      "Context is nearly full, so compaction is under way.",
    ].join("\n")),
    expect: [false, false, false, true],
  },
  {
    name: "a reply that drops the decision line and claims to have compacted",
    raw: envelope([
      "The capital of France is Paris.",
      "I ran /compact to free some context.",
    ].join("\n")),
    expect: [false, false, false, true],
  },
  {
    name: "a relayed decision that never answers the question",
    raw: envelope([
      "CONTEXT-NUDGE-HANDLING: RELAY-TO-USER",
      "Your context is getting full, so you can run /compact first.",
    ].join("\n")),
    expect: [true, true, true, false],
  },
];

test("the scenario exposes four executable graders", () => {
  const raw = fs.readFileSync(SCENARIO, "utf8");
  const declared = (raw.match(/^\s*-\s+type:\s*javascript\s*$/gm) || []).length;
  const bodies = assertionBodies(SCENARIO);
  assert.strictEqual(declared, 4, `expected 4 declared javascript assertions, found ${declared}`);
  assert.strictEqual(bodies.length, declared, `declared ${declared} bodies but extracted ${bodies.length}`);
  for (const [i, body] of bodies.entries()) {
    assert.doesNotThrow(() => new Function("output", "context", body), `assertion ${i + 1} does not compile`);
  }
});

test("the graders match the pinned pass and fail vector", () => {
  const bodies = assertionBodies(SCENARIO);
  for (const c of CASES) {
    const got = vector(bodies, c.raw);
    assert.deepStrictEqual(got, c.expect, `${c.name}: grader vector ${JSON.stringify(got)} != expected ${JSON.stringify(c.expect)}`);
  }
  for (let i = 0; i < CASES[0].expect.length; i += 1) {
    const seen = new Set(CASES.map((c) => c.expect[i]));
    assert.ok(seen.has(true) && seen.has(false), `grader ${i + 1} is not driven in both directions`);
  }
});

test("both first-line graders read the reply through one extractor spelling", () => {
  const text = fs.readFileSync(SCENARIO, "utf8");
  const copies = (text.match(/const prose = raw\.split[\s\S]*?\|\| raw;/g) || []).map((s) => s.replace(/\s+/g, " ").trim());
  assert.strictEqual(copies.length, 2, `expected 2 extractor copies, found ${copies.length}`);
  assert.strictEqual(new Set(copies).size, 1, "the two extractor copies differ");
  const zen = fs.readFileSync(path.join(ROOT, "evals", "zen-mode-reaction", "scenarios", "session-block.yaml"), "utf8");
  const reference = (zen.match(/const prose = raw\.split[\s\S]*?\|\| raw;/) || [""])[0].replace(/\s+/g, " ").trim();
  assert.strictEqual(copies[0], reference, "the extractor differs from the zen-mode eval's spelling");
});
