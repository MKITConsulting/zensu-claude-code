---
paths:
  - "hooks/lib/code-roots-v1.js"
  - "hooks/lib/git-read-only-v1.js"
  - "hooks/lib/zensu-log.sh"
  - "hooks/lib/zensu-edit-landing.sh"
  - "hooks/lib/zensu-tdd-phase.sh"
  - "hooks/lib/zensu-autopilot-state.sh"
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/lib/reviewer-capability-v1.js"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/pre-bash-source-write-gate.sh"
  - "hooks/pre-edit-tdd-reminder.sh"
  - "hooks/stop-chain-enforcer.sh"
  - "docs/multi-repo-chains-*"
  - "tests/structure/code-roots-v1.test.js"
  - "tests/structure/test-code-roots.sh"
---

# Multi-Repo Code Roots (`hooks/lib/code-roots-v1.js`, dark launch)

Stage 2 of `docs/multi-repo-chains-spec.md` §6 lets a chain declare further git work trees with
`--tdd-begin --code-root <label>=<path>` and claim their files as `@<label>/<path>`. Every
consumer below is built and ships behind `CODE_ROOTS_ENABLED = false` in `code-roots-v1.js`,
so nothing a user runs changes until the release that flips it. The rules of
`.claude/rules/multi-repo-stage1.md` keep holding for the anchor and for every undeclared root.

**One judge.** `readCodeRoots` is the only reader that decides what the list means: an array of
at most `MAX_CODE_ROOTS` objects with exactly `ENTRY_KEYS`, re-checked against every string rule
of §6.2. A list that breaks one degrades to anchor-only (`anchor-only`), a document without the
key is `absent`, and every document reads `disabled` while the switch is off. The core has no
validator rule for `codeRoots`, so a hand edit never fails a hook closed; the exact key set is a
strict key set of the reader, which is why the release is `minor`. Absent is the only
single-root form, never an empty array, so a single-root document stays byte-identical.

**Arming is the only writer.** `armCodeRoots` validates in a fixed order: the switch, the spec
syntax, labels, baselines, the anchor, each path's shape, placement and location, git (top,
common directory, HEAD, a baseline that is an ancestor), the list rules, an anchor entry named
`@<label>`, and exclusivity last, because it reads other sessions. Exclusivity counts no
ancestor (§6.5): a live session anchored on the same folder, or on any ancestor of a root, does
not overlap it. `zensu-log.sh --tdd-begin` refuses `--code-root` and `--code-root-baseline`
together with the Autopilot binding flags before it calls the module, and hands the validated
compact JSON to `autopilot_begin_standalone_tdd` as its fourth argument, which refuses a root a
durable Autopilot run holds. It reads a root's own Autopilot state with the session binding
unset, because a bound read refuses every path outside the anchor. An empty records directory
refuses exclusivity instead of reading no record.

**The read-only git leaf.** `git-read-only-v1.js` owns `READ_ONLY_GIT` and `gitEnvironment`.
Every git call into a code root takes both: the module's recipes, the audit's per-claim
`check-ignore` (through the module's `ignored` verb) and rule (A)'s `tracked()` probe in the
Bash gate. `trail.mjs` and `evidence-run-v1.js` keep private copies until PRs C and D move
them; the unit file holds the three equal.

**Two recipes, one per consumer.** The enumeration follows the audit (`core.excludesFile` set
to `/dev/null`), the count follows `_zensu_unqualified_change_count` (the global excludes file
kept). Both add `<baseline>..HEAD` and the unborn case, and a code root never answers
`unknown`: a failure is `unavailable`. Every declared root inside the anchor, and an untracked
link inside it that resolves to one, is excluded from the anchor's own listings through
`:(exclude,top,literal)` pathspecs, run through `_tc_git_magic` and `_el_git_magic`, which unset
the pathspec-mode variables. They are wrappers of their own because `X10e` compares the
`_el_git` and `_tc_git` scrub lists and `worktree-keep-v1.test.js` pins the `_tc_git` list.

**The union.** `_zensu_union_change_count` is the count every terminus caller takes:
`--tdd-complete`, both `--chain-done` paths and `--code-review-done`. Any `unavailable` makes it
`unavailable`, a module that fails to load included, a non-zero part makes it non-zero, and otherwise it is the anchor's own answer,
so a folder anchor with clean roots keeps `unknown`, which the terminus reads as zero. Without
a `"codeRoots"` key in the document the helper spawns nothing and returns the anchor's count.
The Stop hook's implementing-turn probe asks the module's `count` verb only when the anchor's
`git status` shows no change, reading the document with a shell builtin, so a single-root
Stop starts no new process.

**The audit.** `zensu-edit-landing.sh` reads the roots from `--workflow`, or from the workflow
document the `--session` key names, and only then spawns the module. An `@<label>/` claim grades
against that root's change set; any other spelling that resolves into a declared root (an
absolute path, a placed relative claim, a link, a `~/…` or `<home>/…` redaction, a unique
basename match) grades `UNVERIFIED (respell)` with the exact `@<label>/` spelling. A git fault
in a root is an `EDIT LANDING AUDIT FAULT` naming that root's top. The foreign-root remedy names
`--code-root` only while the module's `enabled` verb answers 0, so the single-root output is
byte-identical. `--inventory` skips a declared top and prints `anchor<TAB>folder` for a folder
anchor; the terminus reads only `claimed-files=` and the doctor ignores unknown lines.

**The fix-round verb stops.** `zensu-log.sh --round-prepare` reads the roots through the
`--code-roots` reader right after its node check and stops with `ROUND PREPARE STOPPED —
code-roots` while the chain declares one, because its snapshot, its landing attribution and its
round diff cover the anchor alone. With the switch off it reads no root and runs as before.

**The opt-in Bash gate reads the union from stdin alone.** The hook frames every parser call
as `ZENSU-BSWG-FRAME-V1 <bytes>` plus the workflow document and the payload, with a zero-length
frame for the unbound, control and targets calls. The parser takes the roots from that frame
through `readCodeRoots` and never from its environment, and only while `declaresLiveRoots`
holds (`active` true and `chainDone` not true), the predicate arming exclusivity applies to
other sessions' lists, so a finished chain widens nothing. Rules (B) and (C) accept a path
inside any union member, and `TEMP_SAFE` drops a temp entry that contains any union member.
The parser requires the module lazily, only for a framed document; the module keeps its own
containment predicate `contains`, which the unit file holds equal to the parser's `within`, so
no consumer of the module loads the parser. A frame head whose size the parser cannot honour
(not a number, over `FRAME_DOCUMENT_MAX`, past the input) exits 1, which the hook denies as
unevaluated; the hook sends the zero-length frame for a document over that bound, so such a
session gets the anchor-only rules.

**Protection does not depend on the list.** The reviewer and neutral profiles refuse a `.zensu`
segment below the anchor or below a declared root (`zensuBelowRoot`) and every declared root's
`.zensu`, read from the raw list (`declaredRootTops`), so an absent or broken list protects
nested `.zensu` trees all the same. The Edit gate refuses every root's `.zensu/state` and
classifies a test path relative to the root that owns it (`tdd_is_test_path`'s second
argument). Only a list the reader accepts names an owning root; a rejected or disabled list
classifies relative to the anchor, as a single-root chain does.

**Coupled sites.** The status literal `stages 2 and 3 are REDESIGNED, NOT ENABLED` in all three
multi-repo documents and X7 of `tests/structure/test-multi-repo-doc-consistency.sh`; the
caller-count pins `G13`, `Z6` and `W2`; the zero-change note and the resume directive pinned
by `T2b`, `T15` and the `REASON8` check of `tests/structure/test-stop-enforcer-self-review-routing.sh`;
the line citations of the multi-repo documents, which `test-multi-repo-doc-citations.sh` checks;
the unit-file registry entry and the `ciStructureTests` member of the driver suite.

**Known gaps.**

- Arming success cases and the switch flip belong to PR E; while the switch is off every arming
  call refuses, so the consumers are tested only against fixture documents and a plugin copy
  with the switch flipped.
- Evidence per root (PR C), the review side, `crossrepo` and session-trail (PR D) are not built.
- The Edit gate's phase rules govern files inside the anchor; a code root outside it gets the
  `.zensu/state` deny but no phase classification.
- `canon_claim` compares spellings without case folding, so on darwin a claim spelled with
  another letter case than the recorded top does not respell.
- Windows is unmeasured: the driver suite skips native Windows before grading.

**Version: `minor`.** A strict key set (the reader's `ENTRY_KEYS`), a workflow-state field
(`codeRoots`) and the arity of `autopilot_begin_standalone_tdd` all move.
