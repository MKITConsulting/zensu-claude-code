"use strict";

const test = require("node:test");
const assert = require("node:assert");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const nodePath = require("node:path");

const modulePath = process.env.ZENSU_APPROVED_PLAN_UNIT_TARGET
  || nodePath.join(__dirname, "..", "..", "hooks", "lib", "approved-plan-v1.js");
const {
  APPROVED_PLAN_PREFIX, APPROVED_PLAN_FAILURES, approvedPlanStem, approvedPlanRelPath,
  readApprovedPlan, storeApprovedPlan, listPlanCriteria,
} = require(modulePath);
const { PLAN_FILE_MAX_BYTES } = require(nodePath.join(nodePath.dirname(modulePath), "plan-payload-v1.js"));

const tmpRoot = fs.mkdtempSync(nodePath.join(fs.realpathSync(os.tmpdir()), "zensu-approved-plan-"));
process.on("exit", () => { try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch (_) {} });

const digestOf = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const projectDir = (label) => fs.mkdtempSync(nodePath.join(tmpRoot, `${label}-`));
const copyPath = (root, digest) => nodePath.join(root, ".zensu", "state", `${APPROVED_PLAN_PREFIX}${digest}.md`);

test("an approved-plan copy is named by its lowercase sha256 digest and by nothing else", () => {
  const digest = digestOf(Buffer.from("plan\n"));
  assert.strictEqual(approvedPlanStem(digest), `${APPROVED_PLAN_PREFIX}${digest}`);
  assert.strictEqual(approvedPlanRelPath(digest), `.zensu/state/${APPROVED_PLAN_PREFIX}${digest}.md`);
  for (const bad of [digest.toUpperCase(), digest.slice(1), `${digest}0`, "../escape", "", null, 42]) {
    assert.strictEqual(approvedPlanStem(bad), null, `stem for ${String(bad)}`);
    assert.strictEqual(approvedPlanRelPath(bad), null, `path for ${String(bad)}`);
  }
});

test("the store keeps the exact approved bytes private and reads them back only when they still match", () => {
  const root = projectDir("store");
  const bytes = Buffer.from("# Spec\r\n\n| AC-001 | CRLF and bytes survive as approved | spec |\n<!-- zensu-autopilot:run_abc -->\n", "utf8");
  const digest = digestOf(bytes);
  const stored = storeApprovedPlan(root, digest, bytes);
  assert.strictEqual(stored.ok, true);
  assert.strictEqual(stored.reused, false);
  assert.strictEqual(stored.path, copyPath(root, digest));
  assert.strictEqual(stored.rel, approvedPlanRelPath(digest));
  assert.ok(fs.readFileSync(stored.path).equals(bytes));
  if (process.platform !== "win32") assert.strictEqual(fs.statSync(stored.path).mode & 0o777, 0o600);
  const read = readApprovedPlan(root, digest);
  assert.strictEqual(read.ok, true);
  assert.ok(read.bytes.equals(bytes));
  assert.strictEqual(read.stem, `${APPROVED_PLAN_PREFIX}${digest}`);
  assert.deepStrictEqual(fs.readdirSync(nodePath.join(root, ".zensu", "state")), [`${APPROVED_PLAN_PREFIX}${digest}.md`]);
});

test("a second store reuses an intact copy, and an edited copy reads as a mismatch until the next store restores it", () => {
  const root = projectDir("reuse");
  const bytes = Buffer.from("approved\n");
  const digest = digestOf(bytes);
  assert.strictEqual(storeApprovedPlan(root, digest, bytes).ok, true);
  assert.strictEqual(storeApprovedPlan(root, digest, bytes).reused, true);
  fs.writeFileSync(copyPath(root, digest), "approved, then edited\n");
  assert.deepStrictEqual(readApprovedPlan(root, digest), { ok: false, reason: APPROVED_PLAN_FAILURES.MISMATCH });
  const restored = storeApprovedPlan(root, digest, bytes);
  assert.strictEqual(restored.ok, true);
  assert.strictEqual(restored.reused, false);
  assert.ok(fs.readFileSync(copyPath(root, digest)).equals(bytes));
});

test("the store refuses a malformed digest, foreign bytes, an empty or oversized plan and a relative root, and writes nothing", () => {
  const root = projectDir("refuse");
  const bytes = Buffer.from("plan\n");
  const digest = digestOf(bytes);
  const big = Buffer.alloc(PLAN_FILE_MAX_BYTES + 1, 0x61);
  assert.strictEqual(storeApprovedPlan(root, "f".repeat(63), bytes).reason, APPROVED_PLAN_FAILURES.DIGEST);
  assert.strictEqual(storeApprovedPlan(root, digestOf(Buffer.from("other\n")), bytes).reason, APPROVED_PLAN_FAILURES.MISMATCH);
  assert.strictEqual(storeApprovedPlan(root, digestOf(Buffer.alloc(0)), Buffer.alloc(0)).reason, APPROVED_PLAN_FAILURES.EMPTY);
  assert.strictEqual(storeApprovedPlan(root, digest, "plan\n").reason, APPROVED_PLAN_FAILURES.EMPTY);
  assert.strictEqual(storeApprovedPlan(root, digestOf(big), big).reason, APPROVED_PLAN_FAILURES.TOO_LARGE);
  assert.strictEqual(storeApprovedPlan("relative/root", digest, bytes).reason, APPROVED_PLAN_FAILURES.ROOT);
  assert.strictEqual(readApprovedPlan(root, "not-a-digest").reason, APPROVED_PLAN_FAILURES.DIGEST);
  assert.strictEqual(fs.existsSync(nodePath.join(root, ".zensu")), false);
});

test("a missing copy reads as missing, and a symlinked state directory is refused on store and on read", () => {
  const root = projectDir("link");
  const elsewhere = projectDir("elsewhere");
  const bytes = Buffer.from("plan\n");
  const digest = digestOf(bytes);
  assert.strictEqual(readApprovedPlan(root, digest).reason, APPROVED_PLAN_FAILURES.MISSING);
  fs.mkdirSync(nodePath.join(root, ".zensu", "state"), { recursive: true });
  assert.strictEqual(readApprovedPlan(root, digest).reason, APPROVED_PLAN_FAILURES.MISSING);
  fs.rmdirSync(nodePath.join(root, ".zensu", "state"));
  let linked = true;
  try { fs.symlinkSync(elsewhere, nodePath.join(root, ".zensu", "state"), "dir"); } catch (_) { linked = false; }
  if (!linked) return;
  assert.strictEqual(storeApprovedPlan(root, digest, bytes).reason, APPROVED_PLAN_FAILURES.STATE_DIRECTORY);
  assert.strictEqual(readApprovedPlan(root, digest).reason, APPROVED_PLAN_FAILURES.STATE_DIRECTORY);
  assert.deepStrictEqual(fs.readdirSync(elsewhere), []);
});

test("a copy that gained a second hard link is refused like a symlink", () => {
  const root = projectDir("hardlink");
  const bytes = Buffer.from("plan\n");
  const digest = digestOf(bytes);
  assert.strictEqual(storeApprovedPlan(root, digest, bytes).ok, true);
  let linked = true;
  try { fs.linkSync(copyPath(root, digest), nodePath.join(root, "second-name.md")); } catch (_) { linked = false; }
  if (!linked) return;
  assert.strictEqual(readApprovedPlan(root, digest).reason, APPROVED_PLAN_FAILURES.LINKED);
});

test("the criteria are listed from a private copy of the verified bytes, and the lister's exit decides content against fault by number", () => {
  const scratch = projectDir("criteria");
  const listed = (text, options = {}) => listPlanCriteria(Buffer.from(text), { tmpDirectory: scratch, ...options });
  const table = "# Plan\n\n## Requirements\n| ID | Requirement | Source |\n|----|-------------|--------|\n| AC-001 | The gate reads this criterion. | spec |\n";
  assert.deepStrictEqual(listed(table), { status: "ok", active: 1 });
  assert.deepStrictEqual(listed("# Plan\n\nNo table.\n"), { status: "unusable", detail: "exit-3" });
  assert.deepStrictEqual(listed(`${table}\n\`\`\`\nan example that never closes\n`), { status: "unusable", detail: "exit-5" });
  const faulty = nodePath.join(scratch, "faulty-lister.sh");
  fs.writeFileSync(faulty, "echo 'zensu-plan-requirements.sh: plan has an unterminated code fence' >&2\nexit 2\n");
  assert.deepStrictEqual(listed(table, { lister: faulty }), { status: "unreadable", detail: "exit-2" });
  assert.strictEqual(listed(table, { bashPath: nodePath.join(scratch, "no-such-bash") }).status, "unreadable");
  assert.deepStrictEqual(listPlanCriteria("not a buffer"), { status: "unreadable", detail: "input-rejected" });
  assert.deepStrictEqual(fs.readdirSync(scratch).filter((name) => name.startsWith("zensu-plan-criteria-")), []);
});
