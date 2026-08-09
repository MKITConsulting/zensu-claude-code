"use strict";

// Unit suite for the pure half of the source-write gate's rule (C).
// gitTargets() decides which repository a git invocation addresses and whether
// the subcommand mutates it. Driving it through the hook needs a PreToolUse
// envelope and a subprocess, which is why the option lattice below is asserted
// here instead — same split as chain-recovery-v1.test.js.

const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");

const { gitTargets, msysToDrive, splitTempList, isUnsafeTempEntry, GIT_MUTATIONS, GIT_OPTS_WITH_OPERAND, GIT_READONLY_FORMS } = require(
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

// ── The Windows comparison namespace ─────────────────────────────────
// On Windows the gate compares a project root MSYS already converted for it
// (`D:\a\proj`, because it was exported) against a payload cwd and command
// tokens that arrived over stdin untouched (`/d/a/proj`). path.resolve reads the
// leading `/` as drive-relative and splices the POSIX path under the current
// drive, so the session's own root came out as `D:\d\a\proj` and compared as an
// escape — every in-project git verb denied. The defect lives in path.resolve's
// PLATFORM behavior, so it cannot be reproduced end-to-end from a POSIX host;
// these cases pin the normalizer and re-run the production composition against
// path.win32 explicitly. tests/structure/test-bash-source-write-gate.sh pins
// that the production sites still route through it.

// Mirrors of the production composition, which lives in closures inside main()
// and is therefore not reachable from here. These must stay clause-for-clause
// identical to `stripSlash` (parser: strips a trailing FORWARD slash only, and
// only when length > 1), `resolveFrom`, and `within` (which stripSlash-es its
// root); an earlier draft of this file diverged on both counts and the win32
// cases then asserted against a composition that does not ship.
const winStripSlash = (p) => (p && p.length > 1 && p.endsWith("/") ? p.replace(/\/+$/, "") : p);
const winResolve = (base, value) =>
  winStripSlash(path.win32.resolve(base, msysToDrive(expand(value), true)));
const winWithin = (root, p) => {
  const rel = path.win32.relative(winStripSlash(root), p);
  return rel === "" || (rel !== ".." && !rel.startsWith(".." + path.win32.sep) && !path.win32.isAbsolute(rel));
};

const WIN_ROOT = "D:\\a\\repo\\proj";

test("msysToDrive rewrites an MSYS drive prefix on Windows", () => {
  assert.strictEqual(msysToDrive("/d/a/repo/proj", true), "D:/a/repo/proj");
  assert.strictEqual(msysToDrive("/c/Users/runner/.claude-env", true), "C:/Users/runner/.claude-env");
  // A bare drive keeps its root slash: `D:` alone is drive-RELATIVE to win32.
  assert.strictEqual(msysToDrive("/d", true), "D:/");
  assert.strictEqual(msysToDrive("/d/", true), "D:/");
});

test("msysToDrive is a no-op on POSIX, where /d/a is a real path and not a drive", () => {
  for (const value of ["/d/a/repo/proj", "/c/Users/u", "/d", "/tmp/x"]) {
    assert.strictEqual(msysToDrive(value, false), value, value);
  }
  // The POSIX resolution the existing suite depends on must be untouched.
  assert.strictEqual(path.posix.resolve("/proj", msysToDrive("/d/a/x", false)), "/d/a/x");
});

test("msysToDrive leaves every spelling that is not an MSYS drive prefix alone", () => {
  for (const value of [
    "/dd/a",            // two-letter first segment is a directory, not a drive
    "D:\\a\\repo",      // already native
    "d:/a/repo",        // already drive-qualified
    "//?/D:/x",         // extended-length prefix
    "src/lib.rs",       // relative
    "~/elsewhere",      // tilde, expanded before this runs
    "",                 // empty
    "/"                 // root alone names no drive
  ]) {
    assert.strictEqual(msysToDrive(value, true), value, JSON.stringify(value));
  }
  assert.strictEqual(msysToDrive(undefined, true), undefined);
  assert.strictEqual(msysToDrive(null, true), null);
});

test("a Git-Bash-spelled in-project token lands back inside the native root", () => {
  // The W110 regression: `git -C /d/a/repo/proj commit` against CLAUDE_PROJECT_DIR=D:\a\repo\proj.
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "/d/a/repo/proj")), true);
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "/d/a/repo/proj/sub")), true);
  // Without the normalizer the same token escaped — that is the bug being pinned.
  assert.strictEqual(winWithin(WIN_ROOT, path.win32.resolve(WIN_ROOT, "/d/a/repo/proj")), false);
  assert.strictEqual(path.win32.resolve(WIN_ROOT, "/d/a/repo/proj"), "D:\\d\\a\\repo\\proj");
});

test("normalizing the namespace does not open an escape", () => {
  // A genuine sibling stays outside, in either spelling.
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "/d/a/repo/sibling")), false);
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "D:\\a\\repo\\sibling")), false);
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "../sibling")), false);
  // Another drive is not the session root either.
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "/e/a/repo/proj")), false);
  // `..bak` is nested, not an escape — the anchored `..` test survives win32.
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "/d/a/repo/proj/..bak")), true);
});

// The textual lockstep lives in test-bash-source-write-gate.sh (W3d). This is the
// behavioral half: on the inputs claude-path-v1 accepts, the gate's copy must
// produce the identical spelling, or the two halves of the plugin would judge one
// Windows location as two.
test("msysToDrive agrees with claude-path-v1 on every spelling that module accepts", () => {
  const { normalizeHostPathInput } = require(
    path.join(__dirname, "..", "..", "hooks", "lib", "claude-path-v1.js")
  );
  for (const value of ["/d/a/repo/proj", "/c/Users/runner/.claude-env", "/d", "/d/", "/e/x/y"]) {
    assert.strictEqual(
      msysToDrive(value, true),
      normalizeHostPathInput(value, "gate path", "win32"),
      value
    );
  }
  // And where that module fails closed by throwing, the gate must NOT: an
  // exception here exits the parser non-zero, so the hook's fail-closed branch
  // denies every Bash call in the session instead of the one command. Note
  // `/var/folders/x` — a DEFAULT temp root. Routing the temp list through that
  // module would throw on win32 before a single command was judged.
  for (const value of ["/tmp/x", "/var/folders/x", "D:rel"]) {
    assert.throws(() => normalizeHostPathInput(value, "gate path", "win32"), undefined, value);
    assert.strictEqual(msysToDrive(value, true), value, value);
  }
  // Not converting a complete UNC is not a gap: path.win32.resolve already
  // yields the same spelling the module would have produced.
  const root = "D:\\a\\repo\\proj";
  assert.strictEqual(
    path.win32.resolve(root, msysToDrive("//server/share/x", true)),
    path.win32.resolve(root, normalizeHostPathInput("//server/share/x", "gate path", "win32"))
  );
});

// The parser justifies leaving those spellings raw with "it resolves outside the
// session root and within() denies it". That consequence is the actual safety
// claim, so assert it rather than the identity return alone. `D:rel` is the one
// worth naming: it is drive-RELATIVE, the spelling whose composition could
// plausibly land UNDER the base instead of outside it.
// "Outside the session root" is what within() reports; whether the path is then
// DENIED is a separate question, because isTemp() runs first in decide(). `/tmp/x`
// and `/var/folders/x` are members of the DEFAULT temp list, so production allows
// them by design — the claim asserted here is containment, not the verdict.
test("the spellings claude-path-v1 rejects still resolve outside the session root", () => {
  for (const value of ["/tmp/x", "/var/folders/x", "//server/share/x"]) {
    assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, value)), false, value);
  }
  // `D:rel` is the documented exception, pinned here so the gap stays visible.
  // Drive-relative means "relative to the CURRENT directory on drive D", which
  // path.win32 models as the base when the drives match — so the token lands
  // INSIDE the session root and is allowed. If the shell's actual cwd on D: is
  // some other directory, the real write lands outside while the gate allowed it.
  // Pre-existing and unchanged by the normalizer (`D:rel` has no leading slash,
  // so msysToDrive never touches it); pinned so a future change to that judgment
  // is deliberate. A foreign drive is not affected — it resolves against that
  // drive's own cwd, outside the root.
  assert.strictEqual(path.win32.resolve(WIN_ROOT, "D:rel"), "D:\\a\\repo\\proj\\rel");
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "D:rel")), true);
  assert.strictEqual(winWithin(WIN_ROOT, winResolve(WIN_ROOT, "C:rel")), false);
});

test("a temp entry that is a whole volume is dropped, on either platform", () => {
  // TEMP_SAFE only rejects a root that CONTAINS the project, which on win32 can
  // never be true of another drive — so `C:\` would otherwise carve out that whole
  // drive while the project sits on `D:`, with no bypass-ledger entry.
  assert.strictEqual(isUnsafeTempEntry("C:\\", path.win32), true);
  assert.strictEqual(isUnsafeTempEntry("D:\\", path.win32), true);
  assert.strictEqual(isUnsafeTempEntry("/", path.posix), true);
  // Drive-RELATIVE entries carry no root, so node would resolve them against that
  // drive's own cwd — an arbitrary place. `filter(Boolean)` keeps them, this drops them.
  assert.strictEqual(isUnsafeTempEntry("C:", path.win32), true);
  assert.strictEqual(isUnsafeTempEntry("C:rel", path.win32), true);
  // …and nothing narrower is dropped.
  assert.strictEqual(isUnsafeTempEntry("D:\\a\\tmp", path.win32), false);
  assert.strictEqual(isUnsafeTempEntry("D:/a/tmp", path.win32), false);
  assert.strictEqual(isUnsafeTempEntry("/tmp", path.posix), false);
  assert.strictEqual(isUnsafeTempEntry("", path.posix), false);
  // A POSIX path that merely looks drive-ish must stay untouched on POSIX.
  assert.strictEqual(isUnsafeTempEntry("C:rel", path.posix), false);
  // The spelling the normalizer newly makes reachable: `/c` becomes `C:/`, whose
  // parse root is itself — so the RAW stage already drops it, before any resolve.
  assert.strictEqual(isUnsafeTempEntry(msysToDrive("/c", true), path.win32), true);
  assert.strictEqual(
    isUnsafeTempEntry(path.win32.resolve(msysToDrive("/c", true)), path.win32),
    true
  );
  assert.strictEqual(
    isUnsafeTempEntry(path.win32.resolve(msysToDrive("/c/tmp", true)), path.win32),
    false
  );
});

// The win32 arm of isPathish, reachable because gitTargets takes the platform as a
// parameter. Without it a native-spelled operand yields no candidate path at all,
// so `git worktree remove 'D:\a\repo\wt'` is ALLOWED — and since the namespace fix
// makes the deny reason print exactly that spelling, re-issuing the command with
// the path the gate just quoted would pass.
const atWin = (args) => gitTargets(args, "D:\\a\\repo\\proj", winResolve, true);

test("a native-spelled worktree operand is a candidate path on Windows", () => {
  assert.deepStrictEqual(
    atWin(["worktree", "remove", "--force", "D:\\a\\repo\\wt"]).paths,
    ["D:\\a\\repo\\wt"]
  );
  assert.deepStrictEqual(
    atWin(["worktree", "remove", "--force", "D:/a/repo/wt"]).paths,
    ["D:\\a\\repo\\wt"]
  );
  // A bare NAME stays unjudgeable on Windows too — git resolves it against a
  // worktree list this parser deliberately never reads.
  assert.deepStrictEqual(atWin(["worktree", "remove", "--force", "pr-42"]).paths, []);
  // And POSIX is unchanged: a backslash there is a legal filename character, not a
  // separator, so it must not turn a bare name into a path.
  assert.deepStrictEqual(
    gitTargets(["worktree", "remove", "--force", "pr\\42"], BASE, resolve, false).paths,
    []
  );
});

test("splitTempList keeps a drive colon and still splits real list separators", () => {
  // The regression: `.split(":")` shredded a native entry into ["D", "\\a\\tmp"],
  // so the root never entered TEMP and rule (B)'s carve-out stopped applying.
  assert.deepStrictEqual(splitTempList("D:\\a\\tmp", true), ["D:\\a\\tmp"]);
  assert.deepStrictEqual(splitTempList("D:\\a;E:\\b", true), ["D:\\a", "E:\\b"]);
  // MSYS converts an exported POSIX list, so both conventions must survive.
  assert.deepStrictEqual(splitTempList("/d/a/tmp", true), ["/d/a/tmp"]);
  assert.deepStrictEqual(splitTempList("/d/a/tmp:/e/b", true), ["/d/a/tmp", "/e/b"]);
  // The renderer in this repo emits drive-qualified FORWARD-slash paths, so that
  // spelling — alone and in a list — has to survive too.
  assert.deepStrictEqual(splitTempList("D:/a/tmp", true), ["D:/a/tmp"]);
  assert.deepStrictEqual(splitTempList("D:/a/tmp;E:/b", true), ["D:/a/tmp", "E:/b"]);
  // A single-letter DIRECTORY followed by a colon is a separator, not a drive:
  // only position 1 of an entry makes a colon a drive colon.
  assert.deepStrictEqual(splitTempList("/a/b:/c/d", true), ["/a/b", "/c/d"]);
  // Degenerate entries survive the split. `""` is dropped downstream by
  // filter(Boolean); `"C:"` is NOT — Boolean("C:") is true — which is why
  // isUnsafeTempEntry rejects drive-relative entries rather than relying on it.
  assert.deepStrictEqual(splitTempList("", true), [""]);
  assert.deepStrictEqual(splitTempList("C:", true), ["C:"]);
});

// Mirrors the production TEMP pipeline, both filters in order. Asserting the
// predicate alone is not enough, and NEITHER filter alone suffices: drive-relative
// survives only until path.resolve qualifies it away, so it is catchable only at
// the raw stage, while a RELATIVE entry becomes a root only after resolving, so it
// is catchable only at the resolved stage. `base` models the process cwd the
// resolve happens against, which is what makes the second case reachable.
const winTempList = (raw, base) =>
  splitTempList(raw, true)
    .filter(Boolean)
    .filter((p) => !isUnsafeTempEntry(msysToDrive(p, true), path.win32))
    .map((p) => winStripSlash(base === undefined
      ? path.win32.resolve(msysToDrive(p, true))
      : path.win32.resolve(base, msysToDrive(p, true))))
    .filter((t) => !isUnsafeTempEntry(t, path.win32));

test("the temp pipeline drops both unsafe spellings and keeps ordinary roots", () => {
  assert.deepStrictEqual(winTempList("C:"), []);
  assert.deepStrictEqual(winTempList("C:rel"), []);
  assert.deepStrictEqual(winTempList("/c"), []);
  assert.deepStrictEqual(winTempList(""), []);
  assert.deepStrictEqual(winTempList("D:\\a\\tmp"), ["D:\\a\\tmp"]);
  assert.deepStrictEqual(winTempList("D:/a/tmp"), ["D:\\a\\tmp"]);
  assert.deepStrictEqual(winTempList("/d/a/tmp"), ["D:\\a\\tmp"]);
  // A list keeps the safe members and drops only the unsafe one.
  assert.deepStrictEqual(winTempList("C:;D:\\a\\tmp"), ["D:\\a\\tmp"]);
  assert.deepStrictEqual(winTempList("/d/a/tmp:/c"), ["D:\\a\\tmp"]);
  // Only the POST-resolve filter can catch this one: a relative entry carries no
  // root until it is resolved, and against a cwd at the drive root it becomes one.
  // Without that second filter this case would carve out the whole drive.
  assert.deepStrictEqual(winTempList("..", "D:\\a"), []);
  assert.deepStrictEqual(winTempList(".", "D:\\"), []);
  assert.deepStrictEqual(winTempList("tmp", "D:\\a"), ["D:\\a\\tmp"]);
  // POSIX is untouched: a colon is always a separator there.
  assert.deepStrictEqual(splitTempList("/tmp:/var/folders", false), ["/tmp", "/var/folders"]);
  assert.deepStrictEqual(splitTempList("/tmp", false), ["/tmp"]);
});

test("a native-spelled temp override survives into the comparison namespace", () => {
  // The half the Git-Bash-spelled case could not cover: this repo's own native
  // path renderer emits `D:/…`, and pr-team-review's cleanup depends on the
  // carve-out applying to it.
  // Ride the single mirror rather than re-deriving the pipeline, and feed the
  // FORWARD-slash spelling the renderer actually emits — the backslash form is
  // covered by the splitTempList cases above.
  const [temp] = winTempList("D:/a/repo/tests/tmp1");
  assert.strictEqual(temp, "D:\\a\\repo\\tests\\tmp1");
  assert.strictEqual(winWithin(temp, winResolve(WIN_ROOT, "/d/a/repo/tests/tmp1/inner")), true);
  assert.strictEqual(winWithin(temp, winResolve(WIN_ROOT, "/d/a/repo/tests/tmp2")), false);
});

// Split out so the platform premise is reported on its own: inside the gate's own
// test it never executed on the pre-fix tree, because the discriminating assertion
// above it aborted first.
test("path.win32.resolve splices an MSYS-spelled path under the current drive", () => {
  assert.strictEqual(path.win32.resolve("D:\\a\\repo\\proj", "/d/a/repo/proj"), "D:\\d\\a\\repo\\proj");
});

test("a temp root spelled the Git Bash way compares equal to its native spelling", () => {
  // The W116/W186 class: ZENSU_BSWGATE_TEMP_DIRS is read from the environment,
  // so its entries and the tokens judged against them can disagree in spelling.
  const temp = winStripSlash(path.win32.resolve(msysToDrive("/d/a/repo/tests/.bswgate-tmp.1", true)));
  assert.strictEqual(winWithin(temp, winResolve(WIN_ROOT, "/d/a/repo/tests/.bswgate-tmp.1")), true);
  assert.strictEqual(winWithin(temp, winResolve(WIN_ROOT, "/d/a/repo/tests/.bswgate-tmp.1/inner")), true);
  assert.strictEqual(winWithin(temp, winResolve(WIN_ROOT, "/d/a/repo/tests/.bswgate-tmp.2")), false);
});
