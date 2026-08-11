// Unit pins for hooks/lib/plan-payload-v1.js — the plan-source decision.
//
// Driven by tests/structure/test-plan-payload-fallback.sh, which pins the
// end-to-end behavior through the hook. This file pins what the shell layer
// structurally cannot reach: the exported table's shape and order, the branches
// no JSON payload can express (a NUL byte in a path, a carrier that is a bare
// string), and the reader's refusal codes without building a 4 MiB fixture.

"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const nodePath = require("node:path");

// Deliberately NOT PLAN_PAYLOAD_LIB: the hook exports that name, so a shell
// that has it set would silently grade a different file.
const modulePath = process.env.ZENSU_PLAN_PAYLOAD_UNIT_TARGET
  || nodePath.join(__dirname, "..", "..", "hooks", "lib", "plan-payload-v1.js");
const {
  resolveApprovedPlan, readPlanFile, platformNoFollow,
  LSTAT_PRECHECK_MODE, PLAN_FILE_MAX_BYTES, REASONS, SOURCES,
} = require(modulePath);

const tmpRoot = fs.mkdtempSync(nodePath.join(fs.realpathSync(os.tmpdir()), "zensu-plan-payload-"));
process.on("exit", () => { try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch (_) {} });
const writeFile = (name, contents) => {
  const target = nodePath.join(tmpRoot, name);
  fs.writeFileSync(target, contents);
  return target;
};

test("SOURCES is the four-entry precedence table, in order", () => {
  assert.deepStrictEqual(SOURCES.map((s) => s.label), [
    "tool_input.plan",
    "tool_input.planFilePath",
    "tool_response.plan",
    "tool_response.filePath",
  ]);
  for (const source of SOURCES) {
    assert.strictEqual(source.label, `${source.carrier}.${source.field}`, "label must name carrier.field");
    assert.ok(source.kind === "text" || source.kind === "path", "kind is text or path");
    assert.strictEqual(typeof source.live, "boolean", "every source records its liveness");
  }
  // The two tool_input carriers are the dead ones on the current build. If this
  // flips, the retirement note in the module header is what has to move.
  assert.deepStrictEqual(SOURCES.map((s) => s.live), [false, false, true, true]);
});

test("the resolver walks the table it is GIVEN, not the module's own", () => {
  const ownTable = [{ carrier: "custom", field: "body", kind: "text", label: "custom.body", live: true }];
  const resolved = resolveApprovedPlan({ custom: { body: "# ported" } }, ownTable);
  assert.strictEqual(resolved.ok, true);
  assert.strictEqual(resolved.plan, "# ported");
  assert.strictEqual(resolved.source, "custom.body");
  // A port's table must not see this host's carriers.
  assert.strictEqual(resolveApprovedPlan({ tool_response: { plan: "# host" } }, ownTable).ok, false);
});

test("precedence: each source wins only when every earlier one is absent or empty", () => {
  const all = {
    tool_input: { plan: "# one", planFilePath: "/nope" },
    tool_response: { plan: "# three", filePath: "/nope" },
  };
  assert.strictEqual(resolveApprovedPlan(all).source, "tool_input.plan");
  assert.strictEqual(resolveApprovedPlan({ ...all, tool_input: { plan: "" } }).source, "tool_response.plan");
  assert.strictEqual(
    resolveApprovedPlan({ tool_input: { plan: "", planFilePath: "" }, tool_response: { plan: "# r" } }).source,
    "tool_response.plan",
  );
});

test("source 2 wins when only source 1 is empty, and carries the file's bytes", () => {
  // The 1>2 and 2>3 edges: the earlier precedence test replaced tool_input
  // wholesale, so no case ever showed source 2 actually winning.
  const planFile = writeFile("precedence-source2.md", "# from source 2\n");
  const resolved = resolveApprovedPlan({
    tool_input: { plan: "", planFilePath: planFile },
    tool_response: { plan: "# source 3", filePath: planFile },
  });
  assert.strictEqual(resolved.source, "tool_input.planFilePath");
  assert.ok(Buffer.isBuffer(resolved.buffer), "a path source binds the file bytes");
});

test("an explicit null field is absent, not a type refusal", () => {
  // A harness that saved no file can plausibly send filePath: null. Absent lets
  // the chain continue; a type refusal would end it with a different receipt.
  const resolved = resolveApprovedPlan({ tool_response: { plan: null, filePath: null } });
  assert.strictEqual(resolved.ok, false);
  assert.strictEqual(resolved.reason, REASONS.MISSING);
  const fallthrough = resolveApprovedPlan({
    tool_input: { plan: null }, tool_response: { plan: "# still reached" },
  });
  assert.strictEqual(fallthrough.source, "tool_response.plan");
});

test("a supplied table that is empty or malformed refuses instead of falling back", () => {
  for (const bad of [[], "not a table", {}, null]) {
    const resolved = resolveApprovedPlan({ tool_response: { plan: "# host" } }, bad);
    assert.strictEqual(resolved.ok, false, `table ${JSON.stringify(bad)} must not resolve`);
    assert.strictEqual(resolved.reason, REASONS.MISSING);
  }
  // Omitted is a different answer from supplied-but-unusable.
  assert.strictEqual(resolveApprovedPlan({ tool_response: { plan: "# host" } }).ok, true);
});

test("an entry whose kind is neither text nor path is refused, never read as a path", () => {
  const resolved = resolveApprovedPlan({ c: { f: "/etc/passwd" } },
    [{ carrier: "c", field: "f", kind: "typo", label: "c.f", live: true }]);
  assert.strictEqual(resolved.ok, false);
  assert.strictEqual(resolved.reason, REASONS.FIELD_TYPE);
});

test("a carrier named after an inherited member reads the payload, not Object.prototype", () => {
  const resolved = resolveApprovedPlan({},
    [{ carrier: "constructor", field: "name", kind: "text", label: "constructor.name", live: true }]);
  assert.strictEqual(resolved.ok, false, "Object.name must not resolve as a plan");
});

test("an empty string is absent, a non-string is a refusal", () => {
  assert.strictEqual(resolveApprovedPlan({ tool_response: { plan: "" } }).reason, REASONS.MISSING);
  const refused = resolveApprovedPlan({ tool_response: { plan: { not: "a string" } } });
  assert.strictEqual(refused.ok, false);
  assert.strictEqual(refused.reason, REASONS.FIELD_TYPE);
  assert.strictEqual(refused.source, "tool_response.plan", "a refusal names the field that caused it");
});

test("a carrier that is not a plain object carries no field", () => {
  // Unreachable from the shell suite for the string case: the rendered response
  // is exactly what a text-mining implementation would consume.
  for (const carrier of ["User has approved your plan. Saved to: /etc/passwd", ["# plan"], null, 7, true]) {
    const resolved = resolveApprovedPlan({ tool_response: carrier });
    assert.strictEqual(resolved.ok, false, `carrier ${JSON.stringify(carrier)} must not resolve`);
    assert.strictEqual(resolved.reason, REASONS.MISSING);
  }
});

test("a successful resolve always names its source; a missing one never does", () => {
  assert.strictEqual(resolveApprovedPlan({ tool_response: { plan: "# x" } }).source, "tool_response.plan");
  assert.strictEqual(resolveApprovedPlan({}).source, "");
});

test("every REASONS value is a distinct non-empty string", () => {
  const values = Object.values(REASONS);
  assert.strictEqual(new Set(values).size, values.length, "no two reasons share a value");
  for (const value of values) assert.match(value, /^[A-Z_]+$/);
});

test("readPlanFile rejects a path shape before touching the filesystem", () => {
  // A NUL byte cannot survive the shell suite's env-var transport, so this
  // branch is only reachable here.
  assert.strictEqual(readPlanFile(`${tmpRoot}/plan${String.fromCharCode(0)}.md`).failure, REASONS.PATH_REJECTED);
  assert.strictEqual(readPlanFile("relative/plan.md").failure, REASONS.PATH_REJECTED);
  assert.strictEqual(readPlanFile("//host/share/plan.md").failure, REASONS.PATH_REJECTED);
});

test("readPlanFile maps each filesystem condition to its own reason", (t) => {
  assert.strictEqual(readPlanFile(nodePath.join(tmpRoot, "absent.md")).failure, REASONS.UNREADABLE);
  assert.strictEqual(readPlanFile(tmpRoot).failure, REASONS.NOT_REGULAR);
  assert.strictEqual(readPlanFile(writeFile("empty.md", "")).failure, REASONS.EMPTY);

  // A hard link is a fixture, not a contract. Confirm it through the same stat
  // the reader uses and SKIP where the platform cannot make one — this suite
  // runs on Windows CI, where a throw here would read as a module regression.
  const hardLink = nodePath.join(tmpRoot, "hard-link.md");
  let linked = false;
  try {
    fs.linkSync(writeFile("link-target.md", "# target\n"), hardLink);
    linked = fs.statSync(hardLink).nlink === 2;
  } catch (_) { linked = false; }
  if (!linked) t.skip("this platform cannot create a hard link");
  else assert.strictEqual(readPlanFile(hardLink).failure, REASONS.SYMLINK, "nlink > 1 is refused like a symlink");
});

test("readPlanFile returns the file's raw bytes, and enforces the size limit at its edge", () => {
  const bytes = Buffer.from([0x23, 0x20, 0xff, 0xfe, 0x0a]);
  const read = readPlanFile(writeFile("raw.md", bytes));
  assert.ok(read.bytes.equals(bytes), "invalid UTF-8 survives as raw bytes");

  assert.strictEqual(readPlanFile(writeFile("at-limit.md", Buffer.alloc(PLAN_FILE_MAX_BYTES, 0x61))).failure, undefined);
  assert.strictEqual(
    readPlanFile(writeFile("over-limit.md", Buffer.alloc(PLAN_FILE_MAX_BYTES + 1, 0x61))).failure,
    REASONS.TOO_LARGE,
  );
});

test("platformNoFollow states the real per-platform contract", () => {
  const flag = platformNoFollow();
  assert.ok(Number.isInteger(flag), "the flag is always an integer, never undefined");
  if (process.platform === "win32") {
    assert.strictEqual(flag, 0, "Windows has no O_NOFOLLOW and must not OR one in");
  } else if (Number.isInteger(fs.constants.O_NOFOLLOW)) {
    assert.strictEqual(flag, fs.constants.O_NOFOLLOW, "a POSIX host that defines it must use it");
    assert.notStrictEqual(flag, 0, "the flag this host defines is not the fallback sentinel");
  } else {
    assert.strictEqual(flag, 0, "a host without the constant falls back to the lstat precheck");
  }
});

// The noFollow === 0 branch is what a host WITHOUT O_NOFOLLOW runs: lstat first,
// then re-check dev/ino against the opened descriptor. Every POSIX host this
// ships to defines the flag, so in production that branch never executes and
// would be dead, untested code. The seam is the only way to reach it.
//
// Measured, not assumed: deleting EITHER of the branch's two guards on its own
// leaves this green, because the other still catches the link — that redundancy
// is the point of the branch. Deleting BOTH fails here and nowhere else in the
// suite, so this is the only pin standing between a host without the flag and a
// followed symlink. Both modes agreeing on the verdict is the contract; do not
// rewrite this into a discrimination test, there is nothing to discriminate.
test("the O_NOFOLLOW-unavailable fallback refuses a symlink, it is not merely declared", (t) => {
  const target = writeFile("precheck-target.md", "# target\n");
  const link = nodePath.join(tmpRoot, "precheck-link.md");
  let linked = false;
  try {
    fs.symlinkSync(target, link);
    linked = fs.lstatSync(link).isSymbolicLink();
  } catch (_) { linked = false; }
  if (!linked) return t.skip("this platform cannot create a symlink");

  assert.strictEqual(
    readPlanFile(link, LSTAT_PRECHECK_MODE).failure, REASONS.SYMLINK,
    "the lstat precheck catches what O_NOFOLLOW would have caught",
  );
  // Same mode, ordinary file: the branch must not refuse everything, or the
  // assertion above would pass for the wrong reason.
  assert.ok(
    readPlanFile(target, LSTAT_PRECHECK_MODE).bytes.equals(Buffer.from("# target\n")),
    "the fallback mode still reads a regular file",
  );
});

test("the noFollow seam selects a mode and never accepts a caller flag mask", () => {
  const target = writeFile("seam.md", "# seam\n");
  // Anything that is not the mode string takes the platform default. A caller
  // handing in a numeric mask must NOT have it OR-ed into the open flags, so
  // these all behave like the production one-argument call.
  for (const attempt of [undefined, null, 0, 1, "", "lstat", fs.constants.O_CREAT, { noFollow: 0 }]) {
    assert.ok(
      readPlanFile(target, attempt).bytes.equals(Buffer.from("# seam\n")),
      `a non-mode second argument (${String(attempt)}) must not change the open`,
    );
  }
  // O_CREAT is the discriminator: were the argument OR-ed into the flags, this
  // would CREATE the missing file and report EMPTY instead of UNREADABLE.
  const missing = nodePath.join(tmpRoot, "seam-absent.md");
  assert.strictEqual(readPlanFile(missing, fs.constants.O_CREAT).failure, REASONS.UNREADABLE);
  assert.strictEqual(fs.existsSync(missing), false, "the reader must never create a path it was handed");

  assert.strictEqual(typeof LSTAT_PRECHECK_MODE, "string", "the seam is selected by name, not by a mask");
});

test("resolveApprovedPlan never hands the seam through to the reader", () => {
  // Production must always take the platform default. A source entry carrying a
  // stray mode-like field must not reach readPlanFile's second parameter.
  const target = writeFile("no-seam.md", "# no seam\n");
  const calls = [];
  const probe = new Proxy({ filePath: target }, {
    get(base, key) { calls.push(key); return base[key]; },
  });
  const resolved = resolveApprovedPlan({ tool_response: probe });
  assert.strictEqual(resolved.ok, true);
  assert.strictEqual(readPlanFile.length, 2, "the reader declares the seam as its second parameter");
  assert.strictEqual(
    resolveApprovedPlan.toString().includes("readPlanFile(value)"), true,
    "the resolver calls the reader with the path alone, so production keeps the platform default",
  );
});

test("a resolved file source carries the bytes, a resolved text source does not", () => {
  const planFile = writeFile("resolved.md", "# from disk\n");
  const fromFile = resolveApprovedPlan({ tool_response: { filePath: planFile } });
  assert.strictEqual(fromFile.ok, true);
  assert.ok(Buffer.isBuffer(fromFile.buffer), "the digest must be taken over the file's own bytes");
  assert.strictEqual(fromFile.plan, "# from disk\n");

  const fromText = resolveApprovedPlan({ tool_response: { plan: "# transported" } });
  assert.strictEqual(fromText.buffer, null, "a transported plan has no file bytes to bind");
});
