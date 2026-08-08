"use strict";

// Unit suite for the pure half of the source-write gate's rule (C).
// gitTargets() decides which repository a git invocation addresses and whether
// the subcommand mutates it. Driving it through the hook needs a PreToolUse
// envelope and a subprocess, which is why the option lattice below is asserted
// here instead — same split as chain-recovery-v1.test.js.

const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const { gitTargets, GIT_MUTATIONS, GIT_OPTS_WITH_OPERAND, GIT_READONLY_FORMS } = require(
  path.join(__dirname, "..", "..", "hooks", "lib", "bash-source-write-parse.js")
);

const BASE = "/proj";
const HOME = "/home/u";
// Mirrors the production resolveFrom (stripSlash + path.resolve + expand), so the
// lattice below is pinned against the real resolution semantics, tilde included.
const expand = (p) => (p === "~" ? HOME : p.startsWith("~/") ? HOME + p.slice(1) : p);
const resolve = (base, value) =>
  path.posix.resolve(base, expand(value)).replace(/\/+$/, "") || "/";
const at = (args, base) => gitTargets(args, base === undefined ? BASE : base, resolve);

test("a bare subcommand addresses the base directory", () => {
  const t = at(["add", "-A"]);
  assert.strictEqual(t.sub, "add");
  assert.strictEqual(t.repo, "/proj");
  assert.deepStrictEqual(t.workTrees, []);
  assert.deepStrictEqual(t.gitDirs, []);
});

test("an empty argument list yields no subcommand", () => {
  assert.strictEqual(at([]).sub, "");
});

test("-C moves the addressed repository, relative and absolute", () => {
  assert.strictEqual(at(["-C", "../sibling", "commit", "-m", "x"]).repo, "/sibling");
  assert.strictEqual(at(["-C", "/elsewhere", "add", "."]).repo, "/elsewhere");
});

test("multiple -C are cumulative, each resolved against the previous", () => {
  assert.strictEqual(at(["-C", "..", "-C", "sibling", "add", "."]).repo, "/sibling");
});

test("-C spelled with = is accepted too", () => {
  assert.strictEqual(at(["-C=../sibling", "add", "."]).repo, "/sibling");
});

test("a trailing -C with no operand does not move the repository", () => {
  assert.strictEqual(at(["-C"]).repo, "/proj");
});

test("a global option's separate operand is not mistaken for the subcommand", () => {
  const t = at(["-c", "user.name=A", "commit", "-m", "x"]);
  assert.strictEqual(t.sub, "commit");
});

test("every option in GIT_OPTS_WITH_OPERAND consumes its separate operand", () => {
  for (const opt of GIT_OPTS_WITH_OPERAND) {
    if (opt === "-C") continue;
    const t = at([opt, "value", "commit"]);
    assert.strictEqual(t.sub, "commit", `${opt} swallowed the subcommand`);
  }
});

test("--work-tree and --git-dir are captured in both spellings", () => {
  assert.deepStrictEqual(at(["--work-tree=/foreign", "add", "."]).workTrees, ["/foreign"]);
  assert.deepStrictEqual(at(["--work-tree", "/foreign", "add", "."]).workTrees, ["/foreign"]);
  assert.deepStrictEqual(at(["--git-dir=/foreign/.git", "commit"]).gitDirs, ["/foreign/.git"]);
  assert.deepStrictEqual(at(["--git-dir", "/foreign/.git", "commit"]).gitDirs, ["/foreign/.git"]);
});

test("a quoted option value is unquoted after the = split, so it stays absolute", () => {
  assert.deepStrictEqual(at(['--git-dir="/foreign/.git"', "commit"]).gitDirs, ["/foreign/.git"]);
  assert.deepStrictEqual(at(["--work-tree='/foreign'", "add", "."]).workTrees, ["/foreign"]);
});

test("a relative --work-tree resolves against the POST- -C directory", () => {
  const t = at(["-C", "src", "--work-tree=../build", "add", "."]);
  assert.strictEqual(t.repo, "/proj/src");
  assert.deepStrictEqual(t.workTrees, ["/proj/build"]);
});

test("a relative --git-dir resolves against the POST- -C directory too", () => {
  const t = at(["-C", "src", "--git-dir=../other/.git", "commit", "-m", "x"]);
  assert.strictEqual(t.repo, "/proj/src");
  assert.deepStrictEqual(t.gitDirs, ["/proj/other/.git"]);
});

test("submodule foreach is a mutation, not a read", () => {
  assert.strictEqual(at(["submodule", "foreach", "git reset --hard"]).readOnly, false);
  assert.strictEqual(at(["submodule", "status"]).readOnly, true);
  assert.strictEqual(at(["submodule", "update", "--init"]).readOnly, false);
});

test("a bare worktree name yields no candidate path", () => {
  assert.deepStrictEqual(at(["worktree", "remove", "--force", "pr-42"]).paths, []);
  assert.deepStrictEqual(at(["worktree", "remove", "--force", "./pr-42"]).paths, ["/proj/pr-42"]);
});

test("read-only spellings of gated verbs are flagged read-only", () => {
  assert.strictEqual(at(["stash", "list"]).readOnly, true);
  assert.strictEqual(at(["stash", "show"]).readOnly, true);
  assert.strictEqual(at(["clean", "-n"]).readOnly, true);
  assert.strictEqual(at(["clean", "-nd"]).readOnly, true);
  assert.strictEqual(at(["clean", "--dry-run"]).readOnly, true);
  assert.strictEqual(at(["apply", "--check", "p.patch"]).readOnly, true);
  assert.strictEqual(at(["rm", "--dry-run", "f"]).readOnly, true);
  assert.strictEqual(at(["rm", "-n", "f"]).readOnly, true);
});

test("the mutating spellings of the same verbs are not read-only", () => {
  assert.strictEqual(at(["stash", "push"]).readOnly, false);
  assert.strictEqual(at(["stash"]).readOnly, false);
  assert.strictEqual(at(["clean", "-fd"]).readOnly, false);
  // -e takes a value, so the letters after it are the pattern, not flags.
  assert.strictEqual(at(["clean", "-fd", "-enode"]).readOnly, false);
  assert.strictEqual(at(["apply", "p.patch"]).readOnly, false);
  assert.strictEqual(at(["rm", "f"]).readOnly, false);
});

test("worktree is gated for remove and move only", () => {
  assert.strictEqual(at(["worktree", "remove", "--force", "/x"]).readOnly, false);
  assert.strictEqual(at(["worktree", "move", "a", "b"]).readOnly, false);
  assert.strictEqual(at(["worktree", "add", "/x"]).readOnly, true);
  assert.strictEqual(at(["worktree", "prune"]).readOnly, true);
  assert.strictEqual(at(["worktree", "list"]).readOnly, true);
});

test("a flag before the worktree subverb does not hide it", () => {
  assert.strictEqual(at(["worktree", "--quiet", "remove", "/x"]).readOnly, false);
});

test("reads and unknown verbs are simply not in the mutation set", () => {
  for (const verb of ["status", "log", "diff", "show", "rev-parse", "ls-files", "fetch", "blame"]) {
    assert.strictEqual(GIT_MUTATIONS.includes(at([verb]).sub), false, `${verb} must not be gated`);
  }
});

test("the mutation set holds the verbs rule (C) exists for", () => {
  for (const verb of ["add", "commit", "checkout", "restore", "clean", "reset", "rm", "mv",
    "stash", "apply", "switch", "merge", "rebase", "cherry-pick", "revert", "am", "pull", "worktree",
    // These check commits or trees out into the addressed repository too.
    "bisect", "submodule", "sparse-checkout",
    // Plumbing twins of add/checkout/reset — the most direct index rewrite there is.
    "read-tree", "update-index", "checkout-index"]) {
    assert.strictEqual(GIT_MUTATIONS.includes(verb), true, `${verb} missing from GIT_MUTATIONS`);
  }
});

// Membership, asserted independently of the set: the loop above iterates the set
// under test, so only a hardcoded list catches an option being REMOVED — and a
// removed option makes its operand parse as the subcommand, silently disabling
// rule (C) for that spelling with the whole suite green.
test("the operand-consuming option set holds every global option rule (C) relies on", () => {
  for (const opt of ["-C", "-c", "--git-dir", "--work-tree", "--namespace",
    "--super-prefix", "--exec-path", "--config-env", "--attr-source"]) {
    assert.strictEqual(GIT_OPTS_WITH_OPERAND.includes(opt), true, `${opt} missing from GIT_OPTS_WITH_OPERAND`);
  }
});

test("every read-only exemption belongs to a gated verb", () => {
  for (const verb of GIT_READONLY_FORMS) {
    assert.strictEqual(GIT_MUTATIONS.includes(verb), true, `${verb} is exempt but never gated`);
  }
});

test("a verb's default spelling still classifies as a mutation", () => {
  for (const verb of GIT_READONLY_FORMS) {
    if (verb === "worktree") continue;
    assert.strictEqual(at([verb]).readOnly, false, `bare git ${verb} must not be read-only`);
  }
});

// Object.freeze does NOT stop Set.delete — the entries live in an internal slot —
// so the export must be a copy. Mutating what we get back must leave the gate's
// own decision unchanged, which is the property an isFrozen assertion cannot show.
test("mutating an exported table cannot neuter the gate", () => {
  assert.strictEqual(Object.isFrozen(GIT_MUTATIONS), true);
  assert.throws(() => { GIT_MUTATIONS.pop(); });
  assert.strictEqual(typeof GIT_MUTATIONS.delete, "undefined");
  assert.strictEqual(typeof GIT_OPTS_WITH_OPERAND.delete, "undefined");
  assert.strictEqual(GIT_MUTATIONS.includes("commit"), true);
});

test("an inherited Object.prototype member cannot classify itself read-only", () => {
  assert.strictEqual(at(["constructor"]).readOnly, false);
  assert.strictEqual(at(["toString"]).readOnly, false);
});

test("a pathspec after -- is not read as a dry-run flag", () => {
  assert.strictEqual(at(["clean", "-fd", "--", "-n"]).readOnly, false);
  assert.strictEqual(at(["rm", "-f", "--", "-n"]).readOnly, false);
  assert.strictEqual(at(["rm", "-n", "--", "f"]).readOnly, true);
});

test("apply's other read-only spellings are exempt too", () => {
  for (const flag of ["--check", "--stat", "--numstat", "--summary"]) {
    assert.strictEqual(at(["apply", flag, "p.patch"]).readOnly, true, `apply ${flag}`);
  }
});

test("worktree remove and move expose the tree they destroy as a candidate path", () => {
  assert.deepStrictEqual(at(["worktree", "remove", "--force", "../other"]).paths, ["/other"]);
  assert.deepStrictEqual(at(["worktree", "move", "../a", "../b"]).paths, ["/a", "/b"]);
  assert.deepStrictEqual(at(["worktree", "add", "../new"]).paths, []);
  assert.deepStrictEqual(at(["add", "-A"]).paths, []);
});

// The `--` truncation exists to make clean/rm fail CLOSED. It must not make this
// fail OPEN by emptying `paths` and falling back to judging the repository.
test("a worktree operand written after -- is still a candidate path", () => {
  assert.deepStrictEqual(at(["worktree", "remove", "--force", "--", "../other"]).paths, ["/other"]);
});

test("a tilde-prefixed repository designation is expanded, not treated as relative", () => {
  assert.strictEqual(at(["-C", "~/main-checkout", "add", "."]).repo, "/home/u/main-checkout");
  assert.deepStrictEqual(at(["--work-tree=~/elsewhere", "add", "."]).workTrees, ["/home/u/elsewhere"]);
});
