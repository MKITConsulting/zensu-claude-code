---
paths:
  - "hooks/lib/session-reanchor-v1.js"
  - "hooks/lib/zensu-session-reanchor.sh"
  - "hooks/lib/bash-source-write-parse.js"
  - "hooks/pre-bash-source-write-gate.sh"
  - "tests/structure/test-session-reanchor.sh"
  - "tests/structure/session-reanchor-v1.test.js"
  - "skills/adopt-session/SKILL.md"
---

# Session Re-anchor (`reanchorVerdict` / `performReanchor`)

A session's record pins `project_root` to its SessionStart working directory. A session that
goes on to work in ANOTHER worktree of the same repository — typically one it created with
`git worktree add`, as this repository's own conventions ask — keeps its anchor in the worktree it
started in. While the opt-in source-write gate is on (`hooks.bashWriteGate: true`), rule (C) then
denies `git add`/`git commit` where the session really works and rule (B) denies a new source file
there; at every setting `zensu:review-aspect` reviewers stay confined to the old root.
`/zensu:adopt-session --reanchor` is the one sanctioned move, and it is BOUNDED, never
caller-named.

**The target is derived from the caller's working directory and then VERIFIED; it is never
trusted and never an argument.** `hooks/lib/zensu-session-reanchor.sh` captures `pwd -P` before
its own `cd`, and the only argv token it accepts is `--confirm`. The verdict ladder in
`hooks/lib/session-reanchor-v1.js`, in this order: strict record read (else orphan →
`recorded-root-missing`, pruned → `not-served-by-executing-runtime`, else `record-unreadable`),
`plugin_data` equality, `servesRecordedRuntime`, own workflow document PRESENT and holding no open
work, recorded root inside a git worktree, target inside a git worktree, SAME git common directory,
target top-level registered and not prunable, not already the anchor, not containing the recorded
root, containing no other registered worktree, target document for this session absent or intact,
no open Autopilot run this session owns under the recorded root, live claims. Keep the order: a
cheap refusal must not hide behind a probe that takes a project-wide lock or touches other
sessions' files, and the Autopilot rung takes the recorded root's Autopilot lock.

**The Autopilot rung asks the Autopilot library, not the workflow document.** A run in `PLANNING`
or `AWAIT_TDD` has no chain linked yet, so the document's `autopilotRunId` misses it, and after a
move every reader of that run resolves it through the NEW root and goes silent. `ownedAutopilotRun`
spawns the shell at `ZREANCHOR_BASH` (the wrapper's own, rendered natively), sources
`zensu-autopilot-state.sh` from this module's installation and calls `autopilot_read_active_strict`
with the session key, with the ambient `ZENSU_*` bindings, `CLAUDE_ENV_FILE`, `BASH_ENV` and `ENV`
removed. Not `autopilot_read_active`: its last command is the lease-taking `_autopilot_locked_run`,
and `_tdd_locked_run` returns 1 for a storage-safety failure, a failed lock acquisition and a failed
release as well, so its exit 1 cannot tell "no run" from "could not look". The strict verb runs the
worker under the lease through a probe that always returns 0, as `autopilot_workspace_hold_report`
does, and answers 1 only for the worker's own "no run" or an absent state directory, 2 for an
orphaned, hidden or inconsistent run, 3 for a refused call and 5 for every lease, storage or path
fault. Exit 0 is open unless the stage is `DONE` or `CANCELLED`; every other outcome, a library
that fails to load (exit 97), a timeout and a missing shell included, refuses as
`autopilot-state-unverifiable`. Do not re-implement the run inventory here: the library's owner
scoping and orphan rules are the point. The verb is called by name across the file boundary, so
renaming it is a two-file edit.

**Containment decides widening, not only equality.** A target whose top-level contains the recorded
root — a session recorded in a subdirectory of its own worktree, or a nested worktree moving to
the main checkout — would keep the old root inside the new anchor, so it refuses as
`target-contains-recorded-root`. A target that contains any other registered worktree refuses as
`target-contains-other-worktrees`: with `git worktree add .claude/worktrees/<name>` every worktree
sits inside the main checkout, so anchoring there would admit writes into all of them, whether or
not their sessions are visible to the claim probe.

**Why the recorded root must EXIST.** The refused design was a caller-named anchor, because a
session may delete its own root and then name any directory. A root that is gone cannot prove
which repository it belonged to, so this move refuses it (`recorded-root-missing`, whose remedy
names `--restore-root`). Do not relax that to "same repository as the target": the repository IS
what the root has to prove.

**Live claims fail closed, and both sources are needed.** The host's live-session registry
(`<CLAUDE_CONFIG_DIR or ~/.claude>/sessions/<pid>.json`, liveness by `process.kill(pid, 0)`, EPERM
counts as alive) supplies each live session's working directory, and its Session Control record
supplies its recorded project root; another session's live or unvalidatable worktree-keep anchor
claims its worktree too. Each claim is mapped to its OWNING registered worktree, and a claim on the
target or on a worktree NESTED inside it conflicts — a session in the main checkout does not claim
a nested `.claude/worktrees/<name>`, but moving INTO the main checkout while one works nested in
it is refused. The registry must list THIS session, or the probe is looking at the wrong
configuration and refuses `live-sessions-unverifiable`; so does an unreadable registry, an
unreadable entry whose process is alive, a live entry without a working directory, and a live
entry whose record cannot be read. Never downgrade one of those to "no claim".

**The swap reuses the adoption's primitive; do not copy it.** `performReanchor` takes a
per-repository lock (`reanchor-<sha256 of the git common directory>` in the records lock
directory) and inside it the session's records lock, re-derives the verdict there, and refuses
when the re-derived common directory no longer matches the lock it holds. The repository lock is
what serializes two sessions moving into one worktree: the second one's verdict reads the first
one's new record as a claim. It then re-checks that the verified target still resolves to itself,
creates a missing target baseline, builds the new record with the RECORDED plugin root and
`created_at`, asserts that the written `project_root` IS the verified target and that every other
field is unchanged, and hands the swap to `supersedeContextRecord` in `session-control-core-v1.js`
— the same copy-aside-then-atomic-swap the adoption uses, extracted rather than duplicated. The
set-aside name is `<key>.superseded-reanchor-<UTC stamp>.json`, so a second move never collides
with the first. Provenance, the lease sweep, the keep-anchor move and the marker move run AFTER
the lock, and each reports its own outcome rather than failing the move.

**Per-session markers move with the anchor.** `tdd-mode-<key>.json`, `delivery-route-<key>.json`
and `zen-mode-<key>.json` live under the project root, so a marker left behind stops applying. They
are RENAMED into the new root's state directory, replacing a stale copy of this session's own
marker there; a marker that is not a regular file, or a `.zensu`/`.zensu/state` component that is
not a plain directory, is left in place and reported as a `marker fault`. The three names are the
path templates of `zensu-config.sh` and `zensu-zen-mode.sh`; a new per-session marker belongs in
`SESSION_MARKERS` too.

**Provenance is a history VALUE, reserved in both guard bodies.** `PROJECT_ROOT_REANCHORED` and
the `project-root-reanchored: ` reason prefix sit beside the other reserved pairs in
`zensu-log.sh --phase` and `_tdd_reserved_provenance`, case-insensitively. One entry lands in the
new AND in the old document. No bypass-ledger entry: it escapes no gate. `R5d`/`R5e` in
`test-restore-project-root.sh` count the RESTORED arm with a needle that must stay specific to it;
a shorter needle counts this arm as well.

**Leases are swept by project root.** `discardSupersededLeases` takes an optional fourth
argument; with it, an owned lease survives only when it names that project root, because the lease
reader compares `project_root` strictly and one stale lease wedges every later lease operation. The
three-argument callers are unchanged. The in-place repair of the adoption still sweeps with three
arguments, so a lease stuck by an interrupted re-anchor is NOT repaired by
`/zensu:adopt-session --confirm`; the re-anchor's own WARNING says to move it by hand.

**Reviewer confinement follows by construction.** `reviewer-capability-v1.js` reads
`project_root` from the record on every tool call. Nothing in the capability gate changed, and
`test-session-reanchor.sh` E6 pins both directions end to end.

**Deny texts.** A bound session's rule (B) deny and the repository and designation arms of rule
(C) name `/zensu:adopt-session --reanchor`, gated by `BSWG_REANCHOR=1` on the bound call site of
`pre-bash-source-write-gate.sh`; the unbound site pins it empty, because a session without a
usable record cannot run the move. The worktree-operand arm does not name it (W204b): moving the
anchor does not change which tree `git worktree remove` destroys. The hint says the move refuses a
worktree in which it FINDS another live session — never that it refuses wherever another session
works, because the probe does not see where a session edits. No remedy names the recorded root any more — rule (C) used to
recommend `git -C '<recorded root>' <verb> …`, which stages into the wrong worktree. The parser's
`OPT_IN_NOTE` stays LAST and names `hooks.bashWriteGate`, never the escape prefix
(`skills/session-trail` asserts that shape; W121, W121c and W163c pin it), `denies again` stays in
the designation arm (W163), and the operand arm is unchanged (W204). `test-session-reanchor.sh`
drives its `git add` and admission checks with the gate opted in through `gate-on-config.json`,
because at the default the gate allows every one of them. `P5b` in
`test-secret-scan-gate.sh` pins the literal `BSWG_MODE= PAYLOAD=`, so a new assignment goes AFTER
`PAYLOAD=`, never between the two.

**The identity comes from `CLAUDE_CODE_SESSION_ID`, never from a module-private variable.** The
source-write gate refuses a command-line rebind of that name, so `node session-reanchor-v1.js`
with another live session's raw id is refused where the invocation is visible. It is not refused
through an indirection — `bash -c`, a script file — which is the same residual every protected
Session Control input has.

**The report lists the target's uncommitted paths.** The claim probe finds where a live session
started, is anchored or keeps an anchor, not where it edits; a session anchored elsewhere that
writes into the target by absolute path is invisible to it. `git --no-optional-locks status
--porcelain=v1 -z` of the target, the first ten paths and a count, is what lets the user see that
before confirming. `reanchorReport` computes it on the report path only, never inside the verdict
that `--confirm` re-derives under both locks, and `--no-optional-locks` keeps a read-only report
from taking the target's `index.lock` or rewriting its index while a session the probe cannot see
works there. Every listed name is printed inside double quotes — the safe-display fold's escaped
form, or its plain form wrapped — because the fold's fast path returns a sentence-shaped file name
unchanged, and at the step that stands in for consent such a name would read as the report's own
text.

**It is a separate script on purpose.** `zensu-session-adopt.sh` is what the PreToolUse
recognizer admits in a bind failure, and its header is the justification that admission rests on.
Putting the move there would have widened the recognized surface and every write-class carrier.
The re-anchor runs only in a bound session, the recognizer admits it in no shape
(`test-session-reanchor.sh` E8), and the user-facing spelling stays `/zensu:adopt-session
--reanchor` because the skill routes that argument to the other script.

**Skills follow the anchor through `zensu-log.sh --project-root`.** The verb prints the
`CLAUDE_PROJECT_DIR` its binding case exports — the record's `project_root`, validated by
`zensu_resolve_project_dir` — writes nothing, and refuses any argument with exit 2. The host keeps
the Bash tool in the session's start directory, and `CLAUDE_PROJECT_DIR` is unset there, so a path
a skill builds from `${CLAUDE_PROJECT_DIR:-.}` names the previous root after a move while every
`--*` verb binds the new one. `/zensu:tdd` therefore reads `{project_root}` once in Phase 0 and
derives `{log_file}`, `{plan_file}`, `BASELINE_SHA`, the edit-landing `--project`, the step 10.1
plan bound, `TOP`, the plan template and the persona directory from it, and it runs every project
command it prescribes — test runs, checkpoints, the build, coverage and the step 5 `stat` — as
`cd "{project_root}" && …`. Phase 2's `--truncate` carries `CLAUDE_PROJECT_DIR="{project_root}"`,
because `append` without that variable binds a destructive write to the working directory, which
is the previous root after a move. `/zensu:self-review` derives `TOP` and its ledger root from the
verb and runs its fix round's commands in it, `/zensu:converge` discovers plans under it,
`/zensu:verify-feature --chain` resolves its git root from it and runs its commands there, a
recorded `down` included, and the three `--tdd-complete` refusal remedies name it instead of the
ambient spelling. Every `cd` into the root is spelled without `--`: the root is absolute, and
`bash-source-write-parse.js` takes the token after `cd` as the directory, an accepted gap its header
names, so `cd -- "<root>"` would scope rules (B) and (C) to `<cwd>/--`. Every plan glob keeps the
root inside double quotes (`"{project_root}"/.zensu/plans/*_tdd-*.md`), because the verb refuses
none of the characters a glob or word splitting acts on.

**The skills paste the root into double-quoted shell source, so the verb refuses a root it cannot
paste safely.** A root holding a double quote, a dollar sign, a backtick or a backslash exits 2 with
the reason and prints nothing: inside double quotes the shell would re-parse it, so a skill command
would expand a variable or run a command substitution instead of naming the directory. The
ambient spelling it replaced was a parameter expansion and never re-parsed. Session Control itself
rejects only control characters, and on Git Bash the verb prints the MSYS spelling, so a backslash
never reaches it there. The move itself still accepts such a target, because rules (B) and (C)
and the reviewer confinement need no pasted path; `UNPASTABLE_ROOT_RE` in `session-reanchor-v1.js`
tests the same four characters, and for a matching target the MOVABLE report and the MOVED outcome
withhold the promise that a chain can start there. The two predicates are a hand copy: E10p runs
the verb and E10q both renderers over the same five roots, one per character plus a control with
a space and a single quote, so a character added to one side and not the other fails there.

**`--evidence-run` follows the anchor on its own.** `runDirectory` in `evidence-run-v1.js` keeps
the caller's working directory when it lies in the git work tree of the bound root, and runs the
command in the bound root with a notice on stderr otherwise. Work-tree identity decides first,
because a nested worktree, an embedded clone or a submodule inside the root is another work tree
that the fingerprint does not measure; path containment decides only for a root outside git. The
tree fingerprint and the verdict were always bound to the record's root, so a run from the previous
worktree would have certified the new tree with a suite that tested the old one. The same-work-tree
rule keeps a session recorded in a subdirectory able to run its suite from the worktree top.

`test-tdd-log-path-anchor.sh` L8 fails when any `skills/*/SKILL.md` spells
`${CLAUDE_PROJECT_DIR:-.}`, and `test-session-reanchor.sh` E10 runs the chain from the start
directory after a move with the spans it EXTRACTS from `skills/tdd/SKILL.md`,
`skills/self-review/SKILL.md` and `skills/verify-feature/SKILL.md`. Rewording the `{log_file}` or
`{plan_file}` definition, the Phase 0, Phase 2, step 5b a) or step 10.1 command, the Phase 1 `cd`
rule, the Phase 6 step 1 evidence run, self-review's root derivation or verify-feature's git root
fails E10a there with the extraction named; the step 10.1 command is read from step 10 itself and
must match the Mandatory command protocol's spelling.

**Version: `patch`.** No record or workflow schema field, no strict key set, no hook added,
removed or re-matched, no config key, no attestation change; a new history VALUE, a new script,
reworded deny texts, a read-only `zensu-log.sh` verb whose only callers are skills of the same
installation, and an evidence runner that picks its working directory differently while writing
the same record shape.

**Known gaps:** a session visible to no source — another `CLAUDE_CONFIG_DIR` and no keep
anchor — is not detected, and neither is one that only edits the target by absolute path; the
invoking environment selects the registry, git and the shell; every source is a plain same-user
file, so this guards against accidents, not against a deliberate actor; a session registering in
the target while the move runs is not serialized by the repository lock, because SessionStart
does not take it; an Autopilot run ANOTHER session drives in the target is not consulted — the
library keeps a run's state under its owner's project root, so a run whose workspace is the target
while its state sits under another worktree is visible neither to this probe nor to the library's
own workspace fences, and a fresh session started in the target has the same reach; the host keeps
the session's start directory and the Bash tool returns there, so a command the user runs outside
the skills named above needs a `cd` into the new anchor, and what other skills read through the
working directory — `/zensu:plan-review`'s plan and persona discovery, `/zensu:setup`'s
project-local config target, the load-time overlays of `/zensu:tdd` and `/zensu:cover`, the
templates of `/zensu:autopilot` and `/zensu:pilot`, and the checkout `/zensu:autopilot` opens its
pull request from — still comes from the start directory's worktree of the same repository; the
source-write gate reads its project-level `hooks.bashWriteGate` opt-in through the host's
`CLAUDE_PROJECT_DIR`, ahead of its bind, so after a move the start worktree's
`.zensu/config.json` still decides whether the gate runs; a
project whose root holds a double quote, a dollar sign, a backtick or a backslash cannot run
`/zensu:tdd`, because `--project-root` refuses it; open work under the old root must reach its end
first;
`/zensu:doctor` has no row for a session working outside its anchor; Windows is unmeasured, since
the suite is in `ciStructureTests` but in no Windows CI profile; the ports (`zensu-codex`,
`zensu-kiro`, `zensu-antigravity`) were not changed.
