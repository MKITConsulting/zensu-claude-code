'use strict';

// Unit driver for hooks/lib/plugin-data-guard-v1.js.
//
// It exists because of the properties below, each unreachable from the shell
// suite beside it. Deliberately NO numeral: this repository's own rule is that a
// prose census goes stale on the next added case, and this header had already
// drifted once. The separator class is selected by an `isWindows`
// parameter no payload carries; the two resolution bounds need thousands of
// segments or a link cycle to reach; the filesystem-root store arm is a value a
// shell fixture cannot safely create; and the containment EXPORT-SHAPE arm fires
// only when the sibling parser loads but is missing an export, which no on-disk
// state of this repository produces.
//
// tests/run-all.sh discovers only tests/structure/test-*.sh, so this file is
// invoked by test-plugin-data-guard.sh (G38) rather than by the tree runner.
// A new case here is free; a new FILE needs its own driver row.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const MODULE = path.join(__dirname, "..", "..", "hooks", "lib", "plugin-data-guard-v1.js");
const guard = require(MODULE);

const roots = [];
function scratch() {
  const d = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), "pdg-unit-")));
  roots.push(d);
  return d;
}
test.after(() => {
  for (const d of roots) fs.rmSync(d, { recursive: true, force: true });
});

function write(tool, field, target, extra) {
  const input = { content: "x" };
  input[field] = target;
  return Object.assign({ hook_event_name: "PreToolUse", tool_name: tool, tool_input: input }, extra || {});
}

// --- the separator class, both directions -----------------------------------
// PARTIAL by construction, and the module's own comment says so: the override
// reaches splitSegments and msysToDrive, while every path.* call stays bound to
// the host implementation. What is asserted here is therefore exactly the half
// that IS reachable — whether a backslash divides two segments or is an ordinary
// character in one. Both spellings name a path that does not exist, so the
// realpath fast path declines and the component walk decides.
test("a backslash is a separator when isWindows is true", () => {
  const out = guard.resolveTargetPath(path.sep + "pdg-a\\pdg-b", path.sep, true);
  assert.strictEqual(out.truncated, null);
  assert.ok(out.path.endsWith("pdg-b"), "expected the trailing segment, got " + out.path);
  assert.ok(!out.path.includes("\\"), "the backslash should have been consumed as a separator: " + out.path);
});

test("a backslash is an ordinary character when isWindows is false", () => {
  const out = guard.resolveTargetPath(path.sep + "pdg-a\\pdg-b", path.sep, false);
  assert.strictEqual(out.truncated, null);
  assert.ok(out.path.includes("\\"), "the backslash should have survived as a literal: " + out.path);
});

// --- the two resolution bounds ----------------------------------------------
test("a walk past MAX_COMPONENTS reports truncation instead of a prefix", () => {
  const spelling = path.sep + "pdg" + (path.sep + "a" + path.sep + "..").repeat(2100) + path.sep + "x";
  const out = guard.resolveTargetPath(spelling, path.sep, false);
  assert.strictEqual(out.truncated, "components");
});

test("the identical shape under the bound completes", () => {
  const spelling = path.sep + "pdg" + (path.sep + "a" + path.sep + "..").repeat(4) + path.sep + "x";
  const out = guard.resolveTargetPath(spelling, path.sep, false);
  assert.strictEqual(out.truncated, null);
});

test("a link cycle terminates on the hop bound rather than looping", (t) => {
  const root = scratch();
  try {
    fs.symlinkSync(path.join(root, "b"), path.join(root, "a"));
    fs.symlinkSync(path.join(root, "a"), path.join(root, "b"));
  } catch (_) {
    // A host without real symlinks proves nothing here. It is SKIPPED rather
    // than returned from: a silent early return counts as a pass and would hide
    // the lost coverage from the driver row's floor.
    t.skip("no real symlinks on this host");
    return;
  }
  const out = guard.resolveTargetPath(path.join(root, "a"), root, false);
  assert.strictEqual(out.truncated, "link-hops");
});

// --- an undecidable walk REFUSES; it never reads as "outside" ----------------
test("decide refuses a truncated resolution", () => {
  const store = scratch();
  const project = scratch();
  const spelling = path.sep + "pdg" + (path.sep + "a" + path.sep + "..").repeat(2100) + path.sep + "x";
  const v = guard.decide({
    payload: write("Write", "file_path", spelling),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
  assert.strictEqual(v.reason, guard.REASONS.TRUNCATED);
});

// --- the filesystem-root store arm ------------------------------------------
// A store that IS a root would deny every write in the session, and this gate
// ships with no config flag and no env escape, so the session could not edit the
// file that would fix it. The fail direction of this one value is the opposite
// of every other fault in the module.
test("a store that is a filesystem root disarms instead of arming", () => {
  const project = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(project, "src.ts")),
    pluginData: path.parse(project).root,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, guard.REASONS.NO_STORE);
});

// The carve-out has its own reason since round 3: NO_STORE means the control is
// OFF, and here it is not — every target outside the project still denies.
test("a store that contains the project root carves out the project only", () => {
  const parent = scratch();
  const project = path.join(parent, "proj");
  fs.mkdirSync(project);
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(project, "src.ts")),
    pluginData: parent,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, guard.REASONS.SCOPED_IN_PROJECT);
});

// --- the containment export-shape arm ---------------------------------------
// loadContainment() is not exported and not injectable, so the arm is reached
// the only way that exercises the real branch: a COPY of the module beside a
// sibling parser that loads cleanly and exports neither `within` nor
// `msysToDrive`. A stub that threw would exercise the catch instead, which is a
// different branch.
function moduleWithParser(body) {
  const dir = scratch();
  fs.copyFileSync(MODULE, path.join(dir, "plugin-data-guard-v1.js"));
  fs.writeFileSync(path.join(dir, "bash-source-write-parse.js"), body);
  return require(path.join(dir, "plugin-data-guard-v1.js"));
}

test("a sibling parser missing its exports disarms with its own reason", () => {
  const mod = moduleWithParser("module.exports = {};\n");
  const store = scratch();
  const v = mod.decide({
    payload: write("Write", "file_path", path.join(store, "x.json")),
    pluginData: store,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, mod.REASONS.GUARD_UNAVAILABLE);
});

test("the same copy with a well-shaped parser still decides", () => {
  const mod = moduleWithParser(
    "module.exports = {\n" +
    "  within: (root, p) => p === root || p.startsWith(root + require(\"node:path\").sep),\n" +
    "  msysToDrive: (v) => v,\n" +
    "};\n",
  );
  const store = scratch();
  const project = scratch();
  const v = mod.decide({
    payload: write("Write", "file_path", path.join(store, "x.json")),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
  assert.strictEqual(v.reason, mod.REASONS.DENY);
});

// --- the ordinary verdicts, so the arms above are read against a baseline ----
test("a target inside the store denies", () => {
  const store = scratch();
  const project = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(store, "session-control", "v1", "x.json")),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
  assert.strictEqual(v.reason, guard.REASONS.DENY);
});

test("a target outside the store allows and says so", () => {
  const store = scratch();
  const project = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(project, "src.ts")),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, guard.REASONS.OUTSIDE);
});

test("NotebookEdit is judged on its own path field", () => {
  const store = scratch();
  const project = scratch();
  const v = guard.decide({
    payload: write("NotebookEdit", "notebook_path", path.join(store, "n.ipynb")),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
});

test("a tool that mutates no file is not judged at all", () => {
  const store = scratch();
  const v = guard.decide({
    payload: write("Bash", "file_path", path.join(store, "x.json")),
    pluginData: store,
    isWindows: false,
  });
  assert.strictEqual(v.reason, guard.REASONS.NOT_A_WRITE);
});

test("a payload carrying no path is reported, never silently allowed", () => {
  const store = scratch();
  const v = guard.decide({
    payload: { hook_event_name: "PreToolUse", tool_name: "Write", tool_input: { content: "x" } },
    pluginData: store,
    isWindows: false,
  });
  assert.strictEqual(v.reason, guard.REASONS.NO_TARGET);
  assert.ok(guard.SILENT_FAULT_IS_A_LIE.has(v.reason), "NO_TARGET must be disclosed");
});

test("an unreadable payload allows with a named reason", () => {
  const v = guard.decide({ payload: null, pluginData: scratch(), isWindows: false });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, guard.REASONS.UNREADABLE);
});

// --- round 2: the three behavioural findings -------------------------------
// F2. A failed stdin accumulation must not become a healthy-looking allow. The
// old catch cleared the buffer, so `JSON.parse("{}")` succeeded, the tool name
// was undefined, and the verdict was NOT_A_WRITE — a reason deliberately absent
// from SILENT_FAULT_IS_A_LIE, so nothing was written to stderr either. Padding
// `content` past V8's string limit is then the size-decides-the-verdict bypass
// AC-006 rejected, relocated from a configured cap to an engine limit.
test("a failed accumulation yields no payload, never an empty one", () => {
  assert.strictEqual(guard.payloadFromRaw('{"tool_name":"Write"}', true), null);
});

test("an ordinary read still parses", () => {
  assert.deepStrictEqual(guard.payloadFromRaw('{"tool_name":"Write"}', false), { tool_name: "Write" });
});

test("an unparseable read yields no payload", () => {
  assert.strictEqual(guard.payloadFromRaw("{not json", false), null);
});

test("an empty read yields the empty object, as an absent payload always did", () => {
  assert.deepStrictEqual(guard.payloadFromRaw("", false), {});
});

// F3. `within` is true at equality, so the old `projectRoot !== store` conjunct
// excluded exactly the case store === project root — where the gate armed and
// denied every in-project write with no config flag and no env escape.
test("a store equal to the project root carves out the project too", () => {
  const project = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(project, "src.ts")),
    pluginData: project,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, guard.REASONS.SCOPED_IN_PROJECT);
});

// F4. The valve must not be skipped in silence. The module no longer reads
// CLAUDE_PROJECT_DIR itself; when the caller supplies no project root the
// verdict carries a flag its host half discloses.
test("an armed decision with no project root reports that the valve was unchecked", () => {
  const store = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(store, "x.json")),
    pluginData: store,
    isWindows: false,
  });
  assert.strictEqual(v.overArmUnchecked, true);
});

test("an armed decision with a project root does not report it", () => {
  const store = scratch();
  const project = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(store, "x.json")),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.notStrictEqual(v.overArmUnchecked, true);
});

// --- the cwd ranking --------------------------------------------------------
// The wrapper `cd -P`s into hooks/lib before requiring this module, so the
// caller's directory arrives as opts.cwd. It is the FALLBACK: an absolute
// payload cwd still outranks it, and a RELATIVE fallback is refused rather than
// resolved against process.cwd() one call later.
test("an absolute payload cwd outranks the caller fallback", () => {
  const store = scratch();
  const project = scratch();
  const rel = path.join("session-control", "x.json");
  const v = guard.decide({
    payload: write("Write", "file_path", rel, { cwd: store }),
    pluginData: store,
    projectRoot: project,
    cwd: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
});

test("the caller fallback decides when the payload carries no cwd", () => {
  const store = scratch();
  const project = scratch();
  const rel = path.join("session-control", "x.json");
  const v = guard.decide({
    payload: write("Write", "file_path", rel),
    pluginData: store,
    projectRoot: project,
    cwd: store,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
});

test("a relative caller fallback is ignored rather than resolved later", () => {
  const store = scratch();
  const project = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join("..", "escape.json")),
    pluginData: store,
    projectRoot: project,
    cwd: "relative/not/absolute",
    isWindows: false,
  });
  // The VERDICT cannot discriminate here — the target lands outside the store
  // either way, so `deny === false` held whether or not the relative fallback was
  // honoured. The resolved target does discriminate: with the fallback rejected
  // the anchor is process.cwd(); with it honoured the walk would start at the
  // relative spelling instead.
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.target, path.resolve(process.cwd(), "..", "escape.json"));
});

// --- targets that EXIST on disk -------------------------------------------
// These take the realpath fast path in production, but nothing here can ATTRIBUTE
// the answer to it: for a fully existing target the component walk canonicalizes
// every segment and returns the identical realpath, which is exactly why the fast
// path is safe. The names therefore claim only what the assertions establish.
// Every other case here names a leaf that does not exist, so `realpathSync`
// throws and the component walk decides. A production `Edit` names an existing
// file and takes the fast path instead, which left the branch answering most
// real calls with no executed coverage at all.
test("an existing target inside the store resolves to its realpath and denies", () => {
  const store = scratch();
  const project = scratch();
  const dir = path.join(store, "session-control", "v1");
  fs.mkdirSync(dir, { recursive: true });
  const target = path.join(dir, "record.json");
  fs.writeFileSync(target, "{}");
  assert.strictEqual(guard.resolveTargetPath(target, store, false).path, fs.realpathSync.native(target));
  const v = guard.decide({
    payload: write("Edit", "file_path", target),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
  assert.strictEqual(v.reason, guard.REASONS.DENY);
});

test("an existing target outside the store resolves to its realpath and allows", () => {
  const store = scratch();
  const project = scratch();
  const target = path.join(project, "src.ts");
  fs.writeFileSync(target, "x");
  assert.strictEqual(guard.resolveTargetPath(target, store, false).path, fs.realpathSync.native(target));
  const v = guard.decide({
    payload: write("Edit", "file_path", target),
    pluginData: store,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.strictEqual(v.reason, guard.REASONS.OUTSIDE);
});

test("the fast path and the component walk agree on an existing symlinked target", (t) => {
  const store = scratch();
  const outside = scratch();
  fs.mkdirSync(path.join(store, "real"), { recursive: true });
  const real = path.join(store, "real", "x.json");
  fs.writeFileSync(real, "{}");
  let link;
  try {
    link = path.join(outside, "link.json");
    fs.symlinkSync(real, link);
  } catch (_) {
    // SKIPPED, never returned from: a silent early return counts as a pass and
    // would satisfy the driver row's floor while measuring nothing.
    t.skip("no real symlinks on this host");
    return;
  }
  assert.strictEqual(guard.resolveTargetPath(link, outside, false).path, fs.realpathSync.native(real));
});

// --- round 2: the two remaining anchor findings ----------------------------
// F20. A relative store is a misconfiguration, not a path to resolve. The old
// code ran it through path.resolve, which anchors at process.cwd() — and the
// wrapper has already moved that to <plugin root>/hooks/lib, so the gate armed
// on a directory inside the plugin tree. The spelling below is chosen to
// DISCRIMINATE: "hooks/lib" exists relative to this repository root, so a
// lexical resolve finds a real directory and arms on it, while an absolute
// requirement refuses.
test("a relative store is refused rather than resolved against the process cwd", () => {
  // The case BUILDS its own cwd rather than asserting a fact about where the
  // runner was started. The premise still has to hold — a relative spelling that
  // names a real directory is the only shape that discriminates, since otherwise
  // both the fixed and the unfixed code answer NO_STORE — but it is now a fact
  // about this fixture instead of about the invocation.
  const root = scratch();
  const project = scratch();
  fs.mkdirSync(path.join(root, "hooks", "lib"), { recursive: true });
  const previous = process.cwd();
  try {
    process.chdir(root);
    assert.ok(fs.existsSync(path.join(process.cwd(), "hooks", "lib")), "premise: the relative spelling names a real directory");
    const v = guard.decide({
      payload: write("Write", "file_path", path.join(root, "hooks", "lib", "planted.json")),
      pluginData: path.join("hooks", "lib"),
      projectRoot: project,
      isWindows: false,
    });
    assert.strictEqual(v.deny, false);
    assert.strictEqual(v.reason, guard.REASONS.NO_STORE);
  } finally {
    process.chdir(previous);
  }
});

// F20. The store anchor goes through the same kernel-imitating walk the target
// uses. path.resolve collapses `..` before any link is read — measured bypass #2,
// applied to the ANCHOR instead of the target. The two spellings are built to
// disagree: lexically the `..` cancels `link` and yields <a>/real-store, which
// does not exist; through the kernel the link is followed first and the answer is
// <b>/real-store, which does.
test("a store spelled through a symlink then .. resolves like the kernel, not lexically", (t) => {
  const a = scratch();
  const b = scratch();
  const real = path.join(b, "real-store");
  fs.mkdirSync(real);
  let link;
  try {
    link = path.join(a, "link");
    fs.symlinkSync(b, link);
  } catch (_) {
    // SKIPPED, never returned from: a silent early return counts as a pass and
    // would satisfy the driver row's floor while measuring nothing.
    t.skip("no real symlinks on this host");
    return;
  }
  // CONCATENATION, never path.join: join collapses the `..` lexically before the
  // string reaches the module, so the fixture would test a spelling the caller
  // never sends. The first draft of this case did exactly that and failed for
  // that reason, not for the property it names.
  const spelling = link + path.sep + ".." + path.sep + path.basename(b) + path.sep + "real-store";
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(real, "x.json")),
    pluginData: spelling,
    projectRoot: scratch(),
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
  assert.strictEqual(v.reason, guard.REASONS.DENY);
});

// F23. The over-arm disarm was total: with a store that contains the project it
// allowed EVERY target, including the records directory the gate exists for. The
// usability argument only requires in-project writes to keep working.
test("a containing store still protects targets outside the project", () => {
  const parent = scratch();
  const project = path.join(parent, "proj");
  fs.mkdirSync(project);
  const records = path.join(parent, "session-control", "v1");
  fs.mkdirSync(records, { recursive: true });
  const inProject = guard.decide({
    payload: write("Write", "file_path", path.join(project, "src.ts")),
    pluginData: parent,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(inProject.deny, false, "an in-project write must still be allowed");
  const inStore = guard.decide({
    payload: write("Write", "file_path", path.join(records, "record.json")),
    pluginData: parent,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(inStore.deny, true, "a target inside the store but outside the project must still be denied");
});

// --- round 3: what the SCOPED valve broke ----------------------------------
// The valve's allow used to `return`, which exits the whole target walk. This
// module collects EVERY path-bearing field precisely because first-match-wins is
// the unsafe direction for a deny gate; the scoped allow reinstated it for one
// configuration. The shell row that pins the two-field shape uses a store that
// does NOT contain the project, so `workspace` is empty there and it cannot see
// this.
test("a scoped-allowed field does not stop the walk before a store-targeting one", (t) => {
  const parent = scratch();
  const project = path.join(parent, "proj");
  fs.mkdirSync(project);
  const records = path.join(parent, "session-control", "v1");
  fs.mkdirSync(records, { recursive: true });
  const payload = {
    hook_event_name: "PreToolUse",
    tool_name: "NotebookEdit",
    tool_input: {
      content: "x",
      file_path: path.join(project, "src.ts"),
      notebook_path: path.join(records, "record.json"),
    },
  };
  const v = guard.decide({ payload, pluginData: parent, projectRoot: project, isWindows: false });
  assert.strictEqual(v.deny, true, "the store-targeting second field must still be judged");
});

// The truncation refusal has to be decided BEFORE containment, because on an
// overrun `target` is the prefix the walk reached, not where the path leads. With
// the check below the containment test, a prefix that lands inside the workspace
// was scoped-allowed while the unresolved remainder climbed into the store.
test("a truncated walk refuses even when its prefix lands inside the project", () => {
  const parent = scratch();
  const project = path.join(parent, "proj");
  fs.mkdirSync(project);
  const spelling = project + path.sep + ("a" + path.sep + ".." + path.sep).repeat(2100) + "x";
  const v = guard.decide({
    payload: write("Write", "file_path", spelling),
    pluginData: parent,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, true);
  assert.strictEqual(v.reason, guard.REASONS.TRUNCATED);
});

// The flag reports whether the valve was EVALUATED, not whether its input was
// supplied. A project root that is present but unresolvable — a removed worktree
// is the ordinary case this repository documents — skipped the valve while the
// flag stayed false and the host printed nothing.
test("a present but unresolvable project root still reports the valve unchecked", () => {
  const store = scratch();
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(store, "x.json")),
    pluginData: store,
    projectRoot: path.join(store, "does-not-exist"),
    isWindows: false,
  });
  assert.strictEqual(v.overArmUnchecked, true);
});

// The scoped allow must not borrow NO_STORE. That reason means the control is
// OFF, it is a member of the disclosed set, and the host renders it as "guard did
// not run" — false on both counts here, since the store is set, resolved, and
// still denying every target outside the project.
test("the scoped allow has its own reason and does not claim the guard did not run", () => {
  const parent = scratch();
  const project = path.join(parent, "proj");
  fs.mkdirSync(project);
  const v = guard.decide({
    payload: write("Write", "file_path", path.join(project, "src.ts")),
    pluginData: parent,
    projectRoot: project,
    isWindows: false,
  });
  assert.strictEqual(v.deny, false);
  assert.notStrictEqual(v.reason, guard.REASONS.NO_STORE);
  assert.strictEqual(v.reason, guard.REASONS.SCOPED_IN_PROJECT);
  assert.ok(!guard.SILENT_FAULT_IS_A_LIE.has(v.reason), "a working gate must not announce that it did not run");
});

// --- round 4 -----------------------------------------------------------------
// The scoped allow must report the target that SET it. `lastTarget` is whatever
// the loop saw last, which on a two-field payload can be a path that is neither
// in the store nor in the project — a verdict whose reason and target contradict
// each other in an exported contract.
test("the scoped allow reports the target that earned it", () => {
  const parent = scratch();
  const project = path.join(parent, "proj");
  fs.mkdirSync(project);
  const inProject = path.join(project, "src.ts");
  const payload = {
    hook_event_name: "PreToolUse",
    tool_name: "NotebookEdit",
    tool_input: { content: "x", file_path: inProject, notebook_path: path.join(scratch(), "elsewhere.txt") },
  };
  const v = guard.decide({ payload, pluginData: parent, projectRoot: project, isWindows: false });
  assert.strictEqual(v.reason, guard.REASONS.SCOPED_IN_PROJECT);
  assert.strictEqual(v.target, fs.realpathSync.native(project) + path.sep + "src.ts");
});
