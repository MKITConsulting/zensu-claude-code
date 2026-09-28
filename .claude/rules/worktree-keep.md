---
paths:
  - "hooks/lib/worktree-keep-v1.js"
  - "hooks/lib/zensu-worktree-keep.sh"
  - "hooks/session-start-worktree-keep.sh"
  - "hooks/user-prompt-worktree-keep.sh"
  - "hooks/session-end-worktree-keep.sh"
  - "docs/worktree-keep.md"
  - "tests/structure/test-worktree-keep.sh"
  - "tests/structure/worktree-keep-v1.test.js"
---

# Worktree Keep (`hooks/lib/worktree-keep-v1.js` + three advisory hooks)

Claude Desktop runs one `Claude.app` process per signed-in account, and all of them share one
worktree registry (`~/Library/Application Support/Claude/git-worktrees.json`). Each process sees
only its own account's sessions and leases, so its `WorktreePool` treats a worktree that another
account's session is working in as `(was leased by none)`, re-leases it, and checks the taker's
branch out IN PLACE — the displaced session's directory changes branch under it. Measured
2026-09-20 on Claude Desktop **2.2553.1** against `.claude/worktrees/plugin-clarity-refinement-15ca39`
(the session behind PR #313), with the app's own `main.log` and the directory's reflog as the
evidence; every one of the eight rebinds of that directory since 2026-09-09 crossed an account
boundary. The root cause is the app's — per-instance lease visibility plus last-writer-wins
registry writes — and nothing here changes it.

**Two signals, and the second is the safety net for the first.** The app skips a worktree whose
root carries a file named `.worktree-keep` (`WORKTREE_KEEP_FILENAME` in `app.asar`, read by
`hasKeepSentinel` in BOTH the acquire walk that picks a reuse donor and the idle reaper's sweep;
its status probes either exclude the file or read it as an untracked file and judge the tree not
clean, so no path turns the marker into a reason to touch the worktree). `git worktree lock` is
deliberately NOT used: `isLockedByGit` gates removal only, never the checkout, so a stale lock
would only add a second thing to clean up. The marker is an APP-INTERNAL constant, and that is
the provenance rule: `KEEP_SOURCE_BUILD` in the module names the build the constant was read
from, the unit suite cross-checks it against `docs/worktree-keep.md` — that document is the
provenance carrier, because the module carries no comment lines and therefore no header of the
`DENIAL_MARKERS_SOURCE_BUILD` kind — and a later build that renames the file silently stops
the protection with every check green — re-verify against the binary, never against memory. The
drift detector is what survives that: it compares the worktree's current branch with the branch
this session recorded, and a mismatch discloses ONCE what happened and how to continue.

**ONE lifecycle rule, in ONE function.** `reconcileKeep` holds the marker present while at least
one LIVE anchor exists in `<worktree>/.zensu/state/` — an anchor is this session's
`worktree-anchor-<scv1 session key>.json` (schema 1: an ABSOLUTE worktree root without control
bytes, branch, head, liveness stamp, drift, and two optional fields, `idleHours` and `endedAt`),
`live` while its stamp is inside the window its WRITER recorded in `idleHours` (the caller's
`hooks.worktreeKeepIdleHours` applies only to a record without one; default 72, range 1..8760; a
FUTURE stamp is stale, the `classifyDenialNote` rule). Judging a sibling by the SWEEPER's window
would let a session whose worktree overlay sets one hour strip every sibling idle for an hour. A
record with `endedAt` is stale at once: SessionEnd AGES its own anchor rather than deleting it,
because deleting it would throw away the only baseline a later resume can detect a takeover
against. A stale anchor loses the marker but is RETAINED until `REAP_FACTOR` times its window,
because it is the only branch baseline: reaping it at the liveness edge would let a takeover
during the idle window pass undisclosed, since the next prompt would adopt the taker's branch as
a fresh record. Only a reconcile
in the SAME worktree reaps, and it re-reads each anchor right before the unlink;
`sweepSiblings` passes `reap: false`, so no session deletes another worktree's baseline. A
reconcile that unlinked the marker LISTS AGAIN and restores it when a live or a rejected anchor
appeared in between or the second listing cannot be read — the same holds the first pass
honours, so a race never releases what a quiet pass would keep; the writer reads the marker only
after writing its anchor, so the two re-checks together close the interleaving in which a
sibling's stale snapshot stripped a live session. **A REJECTED anchor holds the marker
too**, and that is a correctness rule rather than caution: without it a live session whose
anchor THIS build cannot validate would count as "no live anchor" and a sibling sweep would
unlink its marker — which is the exact damage the feature exists to prevent, and the shape §"Runtime Lineage" calls the ordinary case, since a mid-flight
update is precisely when one installation refuses what another wrote. `listAnchors` is also
BOUNDED at `MAX_ANCHOR_FILES`: the directory is session-writable and this walk sits on the
per-prompt path, so past the bound it answers `ok: false` and the marker is left exactly as it
stands — the same fail-safe an unreadable directory takes. The over-bound answer still carries the
reapable anchors the walk examined, and a reconcile in the same worktree reaps them and lists
again, because aged SessionEnd anchors accumulate for twice their window and a directory that
could only grow past the bound would never drain. Branch names are held to a ref-shape
predicate (`branchNameOk`) at the read boundary and at render, so a planted anchor cannot carry
free text into `additionalContext` or a doctor row. A branch git accepts and this predicate does
not is read as `UNRENDERABLE_BRANCH` — **a value, not a read failure**, which is the distinction
that keeps the feature working: reporting the shape refusal as `ok: false` would make
`detectDrift` return null, so a takeover onto `fix+123` would produce no disclosure at all,
silencing the one automatic channel the feature has. The sentinel fails `branchNameOk` by construction, so it can
never collide with a real name; `branchValueOk` is what admits it into a persisted record, and
`describeBranch` renders it as a branch whose name this plugin does not render. Every git child
runs with the fifteen `GIT_*`
discovery and config-injection variables `_tc_git` lists deleted from its environment, so an
inherited `GIT_DIR` cannot make the branch read answer a foreign repository or the exclude write
land in one. The marker is created only after `git check-ignore` confirms git ignores it
(`markerIgnored` adds the exclude entry first when it does not, and refuses otherwise), because an
untracked marker is one `git add -A` away from being committed into every checkout of the
repository; `markerIgnoreState` is the read-only verdict over the same probe and over
`excludeTarget`, the pre-checks `ensureExclude` itself runs, and answers `{state, reason}` in the
exported `IGNORE_STATES` vocabulary, so the doctor tells a missing exclude entry from an ignore
rule that re-includes the marker, from an exclude file the append refuses (symlinked,
hard-linked or oversized, one the process cannot write, or an `info` entry that is not a
directory) and from a check-ignore that cannot run — one set of pre-checks, because a doctor copy
of them would promise a restore the append then refuses. The write check is `W_OK` on the
exclude file, else on the `info` directory, else on the common dir, and it is skipped when the
file already lists the marker, because nothing is appended then. On Windows, libuv's access
check treats every directory as writable and reads only a file's read-only attribute (from its
source; not run on Windows here), so there the check can refuse only a read-only exclude file;
the unit case derives its expectation from the same probe instead of skipping. It is
PUBLISHED, not written in place: a temp file in the verified state directory is written and
fsynced, then `linkSync`ed onto the marker path, which never follows or replaces an existing
target, because an in-place write that fails half-way leaves a partial file the plugin reads as
foreign forever. Where the link fails because the volume has no hard links
(`LINK_UNSUPPORTED_CODES`), the complete temp file is copied with `COPYFILE_EXCL`, which never
replaces an existing target either, and a copy that fails part way removes only a truncated copy
of the plugin's own body. `publishMarker` re-reads the marker on `EEXIST` from either path, so a
lost race is not a refusal. It is removed only when it is a regular file the plugin wrote, and
a foreign or non-plain marker is left alone and reported. `ensureExclude` puts the name into the
`info/exclude` of the common dir git reports FROM THE WORKTREE ROOT — whose `.git` file
`managedWorktree` verified — never from the base repository, where discovery past an invalid
`.git` would answer for an enclosing repository. It pre-reads with `singleLink`, appends only through a
descriptor whose `nlink` is 1 and whose dev/ino match the pre-read, creates the file exclusively
when it was absent, and never touches `.gitignore`, so `git status` stays clean in every worktree
of the repository. `sweepSiblings` reconciles every sibling under `<repo>/.claude/worktrees/` at
SessionStart, bounded to 64 directories and with one `try` per sibling, which is what bounds marker
accumulation when SessionEnd never arrives.

**Three hooks, all ADVISORY, all main-principal, all behind the permissive `hooks.worktreeKeep`.**
The SessionStart and SessionEnd halves anchor on ONE root in ONE order — the bound record's native project root first, the
payload `cwd` only when the bind fails (a fresh start whose record is still being minted) — and
hand node the host-native spelling the bind exports, never the MSYS one `zensu_resolve_project_dir`
renders on Git Bash; each also declines, before any helper is sourced, a payload that names no
`.claude/worktrees` component, so a session in a plain checkout pays no bind on this path — a
pre-filter that judges the raw payload TEXT while the hook itself anchors on the record, which is
a divergence stated in the gap list below rather than an equivalence. The payload reader and that
ladder live in `hooks/lib/zensu-worktree-keep.sh` and are CALLED twice rather than copied,
because the two halves write and remove the SAME anchor, so a one-sided edit orphans it under a
root the other never reads. The
module honours `WK_NOW` and `WK_MAX_DIRS` ONLY in the explicit JSON test mode (`WK_EMIT=json`);
the hook envelope is its default output and the hooks pin `WK_EMIT=claude-hook`. The module, not
each hook, owns that guard, so no caller can forget it: an inherited far-future `WK_NOW` would
make every anchor stale and let one SessionStart strip the marker from every sibling.
`sweepSiblings` additionally CLAMPS a supplied bound to `MAX_SWEEP_DIRS` rather than trusting it.
`session-start-worktree-keep.sh` writes or refreshes the anchor, puts the exclude line in,
reconciles, sweeps. A fresh start records the branch. `resume`/`compact` keep the recorded branch
and run the same `evaluateDrift` the prompt runs, with `repeat` set: a drift still in place is
stated again as SessionStart `additionalContext`, because the compacted context no longer holds
the first notice, and a NEW target is disclosed and recorded there. A drift recorded before a
paused rebase or bisect, or before a branch read that fails now, is stated again in its recorded
form (`recordedDisclosureText`, naming the pause or the failed read), because nothing in that
state can confirm or clear it and the prompt after the pause ends on the recorded target stays
silent — without the restatement the compacted context would never learn of it. A resume or compaction that
finds no usable anchor records the fault, rewrites the anchor and, only once that write landed and
only when the current branch could be read, says once that the current branch was adopted without
verification. `user-prompt-worktree-keep.sh` binds the session, refreshes the stamp at
most every ten minutes, reconciles, and on a NEW drift emits one `additionalContext` naming both
branches and the head, the possible takeover, the CONDITIONAL instruction not to switch the shared
directory back, the uncommitted-work check (`git status` and `git stash list`; commit, stash,
reset and discard nothing there), and the nested-worktree recipe from `remedyLines` —
`git worktree add .claude/worktrees/<slug> <recorded branch>` INSIDE the session's own worktree,
which the desktop write-guard admits (measured on 2.2553.1: only a sibling or temp-dir worktree is
refused as `sibling_worktree`) and the Zensu Bash gates admit as in-anchor git. The same drift is
disclosed once per context and a switch back clears it; `/clear` records a new baseline.
`branchState` is the ONE branch verdict: it builds on `judgeBranch` and answers one of the
frozen `BRANCH_STATES` with the pause, the drift and an explicit `readFailed`; `evaluateDrift`
and the doctor branch on it, the prompt backfill uses the same `backfillDue` rule, no exported
name judges a pause or a drift on its own, and `P1wk18-judge` holds the doctor to it. A detached
HEAD while `rebase-merge`, `rebase-apply` or `BISECT_LOG` exists in the worktree's git dir
(`PAUSED_MARKERS`) is not judged at all — neither disclosed nor cleared — because a paused rebase
or bisect detaches HEAD without any takeover. A baseline recorded during such a pause — a fresh
start, a re-created anchor, or the backfill of an unresolved record — takes the branch the
operation returns to (`pausedState` reads `rebase-merge/head-name`, `rebase-apply/head-name` or
`BISECT_START` and holds the name to `branchNameOk`), or stays unresolved until the operation
ends when that record cannot be read (`baselineFor`), because a detached head recorded as the
baseline would turn the operation's own end into a disclosed takeover. A missing or
root-mismatched own anchor (`anchorMatchesRoot`, the one rule the three verbs and the doctor
share), or a rejected record the next prompt can replace (unparseable, misshapen or oversized),
is rewritten with a one-time notice that the branch was adopted without verification; the
notice is given only once the write succeeded, so a symlink, a hard link or a non-file at the
anchor path, or a broken `.zensu`/`state` component, which `writeAnchor` never replaces, records
nothing and repeats no notice; the notice never renders the worktree root.
`session-end-worktree-keep.sh` ages the anchor (or removes one it cannot validate when it is a
regular file, a hard link included; `removeAnchor` leaves a symlink, a non-file or a broken
state component in place) and reconciles. With `hooks.worktreeKeep` off, SessionStart and SessionEnd run the `release` verb
instead of returning early — this session's anchor is removed and the marker reconciled and swept
with `create: false` — because an early return would strand every marker the plugin wrote. Every
fault exits 0 after a stderr note; nothing here returns a `permissionDecision` in either
direction, and no gate is relaxed.

**`/zensu:doctor` renders the state in `worktreeKeepRows`**, called from BOTH branches of
`stateBlock` — the populated path and the `readdirSync` ENOENT branch — because a session whose
worktree has no `.zensu/state` yet is exactly the one with no anchor. The module is required
LAZILY and guarded; a load failure costs one row, and that row is a WARN only when the project
root sits under a `.claude/worktrees` container, so a plugin root that predates this feature (most
doctor fixtures) stays green on a plain checkout; a `managedWorktree` fault under such a container
is the same WARN, never the OK "not an app-managed worktree" row. Disabling renders a switched-off
row rather than silence, the `reviewerSpawnPermissionCheck` rule — but the off branch still reads
the marker and lists the anchors, and a marker the plugin wrote is a WARN naming the file and what
still holds it — live session anchors; anchor files this build cannot validate, which the row says
to remove only after confirming no session on another plugin version is live there, because such a
file is usually a live anchor another installation wrote during an update; or an unreadable anchor
directory, which the row says drains when it is past its bound and holds expired anchors, since the
release pass reaps what it read — because the release pass removes it only once nothing does. A drift row, a
MISSING-marker row and a stale own-anchor row are WARN and withhold the green summary for as long
as they hold, deliberately: a taken or unprotected directory is real state the user must act on.
The MISSING row promises a restore only for an `IGNORED` or `NOT_YET_EXCLUDED` verdict and only
while the anchor listing can be read, because `reconcileKeep` publishes nothing otherwise. It
names the refusal when `markerIgnoreState` answers that git does not ignore the marker although
`info/exclude` lists it or that the exclude file refuses the entry, and every other verdict —
`UNKNOWN`, or one a later module adds — renders the git-could-not-say refusal, so the promise is
never the ladder's fall-through. The
no-anchor row promises no marker restore for the same reason. The own-anchor row for a REJECTED
anchor names the remedy `anchorRemedy` reads from `anchorTargetCheck`, the pre-check
`writeAnchor` itself applies, never from the rejection's reason string: the next prompt replaces
an unparseable, misshapen or oversized record; a symlink, a hard link or a non-file must be
removed by hand first; a symlinked `.zensu` or `state` component must be fixed by hand, and that
row promises no rewrite. The row promises a replacement only for `REPLACED`, and any value it does
not name renders a row without a promise (`P1wk47`). The unit suite holds each remedy to what
`writeAnchor` does. An own anchor whose recorded root is not this worktree's renders a WARN row
that the next prompt replaces it, in place of every branch row, and never prints the recorded
root (`P1wk46`). A component that is NOT A DIRECTORY does not reach that
row on macOS: `stateBlock`'s own `readdirSync` fails first with `ENOTDIR` (measured for a
`.zensu` file and for a `state` file) and renders the state-directory WARN row instead; the
errno on Windows was not measured. The listing row leaves this session's own anchor to that row (each rejected
entry carries its session key) and words every other entry as an anchor file this build cannot
validate, usually another installation's live anchor, to be removed only after confirming no such
session is live there. The no-branch row runs after the
branch judge, beside the stale and MISSING rows rather than instead of them, and names a paused
operation when one holds a detached HEAD, because a baseline recorded during a pause whose target
cannot be read is the second way to an unresolved record. Outside a pause it splits on the
current read: while the branch read still fails, it says a takeover could not be ruled out and
that the next prompt records the branch once git can answer, because the backfill needs a
readable branch. A paused rebase or
bisect is an OK row, and the drift check is skipped under it through the same `branchState` the
module uses — unless a drift was recorded before the pause or before the branch read began
failing, which keeps a WARN row naming the recorded move and the pause or the failed read. That
clause comes from the module's `recordedMoveSentence`, the sentence `recordedDisclosureText` also
uses, and both read the cause from the verdict's `paused` and `readFailed` fields, so the
restated disclosure and the row agree on when they fire as well as on the wording. The recorded-baseline OK row names
the baseline through `branchNoun`, so a detached baseline reads "recorded detached HEAD", never
"recorded a detached HEAD". The catch rows print the fault CODE — or the error name
when the error carries none, such as a module that fails to parse — through `worktreeFaultText`,
folded, never the raw message, whose path a co-tenant can name. The drift sentence and the remedy are rendered by the module's own
`driftSentence`, `describeBranch` and `remedyLines`, so the DISCLOSURE and this row cannot
disagree about the recipe — scope that to those two, because a THIRD renderer of the same advice
exists and deliberately differs: `TAKE_YOUR_OWN` / `continuationSlug` in
`skills/session-trail/scripts/trail.mjs` (§"Takeover Destination") strips a `claude/` prefix and
always passes `-b …-cont`, where `branchSlug` here strips nothing and offers `-b` only as the
checked-out-elsewhere fallback, so the two name DIFFERENT directories for one continuation. Each
is graded by its own suite alone; a reader who follows the doctor row and then runs
`/zensu:session-trail` gets two answers. Extracting one owner is the durable fix and is NOT taken
here. The idle window comes from the module's `idleMsFromHours` over
`ZDOC_WORKTREE_KEEP_IDLE_HOURS`, so the renderer holds no copy of the getter's bounds, and the
marker-state, verdict, ignore, remedy and branch-state WORDS and the marker's own name come from
the module's exported `MARKER_STATES` / `VERDICTS` / `IGNORE_STATES` / `ANCHOR_REMEDIES` /
`BRANCH_STATES` / `KEEP_FILENAME` rather than bare literals
(`P1wk18`) — a crossing between two files, which is the kind this repository records as
expensive to get wrong, and a renamed ignore word would silently turn a refusal back into a
restore promise. **Every path in the family is folded** through `foldPath`
before it is rendered: the doctor skill tells the model to relay these rows, so a directory name
carrying a spaced colon would otherwise forge a `label : value` pair inside a line the user reads
as the report's own verdict. And **every module call sits inside ONE try**: `lstatOrNull`
re-throws any errno but `ENOENT`, and the report is accumulated and written once, so one
`ENOTDIR` from a concurrently-swapped state directory would discard the WHOLE report. `anchors.ok`
is consulted before any count is rendered, because `listAnchors` answers its failure with EMPTY
lists and a green row claiming zero live anchors over a directory it never read is the inversion
the sibling doctor rows exist to prevent.

**Coupled sites that move together:** `KEEP_FILENAME` / `KEEP_SOURCE_BUILD` / `ANCHOR_PREFIX` /
`ANCHOR_NAME_RE` / `DEFAULT_IDLE_HOURS` / `MAX_IDLE_HOURS` / `MAX_SWEEP_DIRS` /
`REFRESH_INTERVAL_MS` / `MAX_ANCHOR_FILES` / `UNRENDERABLE_BRANCH` / `branchValueOk` /
`MARKER_STATES` / `VERDICTS` / `IGNORE_STATES` / `ANCHOR_REMEDIES` / `BRANCH_STATES` / `ACTIONS` /
`EXCLUDE_COMMENT` and the three verbs in the module; `anchorTargetCheck` and `anchorRemedy` (the
pre-check `writeAnchor` applies, and the remedy the doctor names from it);
`PAUSED_MARKERS`, `pausedState` / `baselineFor` (git's paused-operation file
formats, `head-name` holding `refs/heads/<branch>` and `BISECT_START` holding a short branch name
or a commit id, measured on git 2.51.0), `branchState` over `judgeBranch` and `backfillDue`,
`anchorMatchesRoot`, `branchNoun` and `recordedMoveSentence` (shared with the doctor),
`markerIgnoreState` and `excludeTarget` (the verdict shared with the doctor, over the pre-checks
shared with `ensureExclude`), `LINK_UNSUPPORTED_CODES`, and the `release` member
of `VERBS`, which both lifecycle hooks select when the flag is off;
`hooks/lib/zensu-worktree-keep.sh`, the ONE payload reader and root/session-key ladder both
lifecycle hooks call (pinned by `K21`/`K21a`); the three hooks and
their three registrations in `hooks/hooks.json` (SessionStart, UserPromptSubmit, and a NEW
`SessionEnd` array, the first event of that kind this plugin registers);
`zensu_worktree_keep_idle_hours` in `hooks/lib/zensu-config.sh`, a one-line
`_zensu_config_bounded_int` call whose four operands must stay positional literals because `C58`
in `tests/structure/test-impl-stop-counter.sh` reads every getter's operands;
`STATE_SEGMENTS` in the module, a twin of the owner-exported `WORKFLOW_STATE_SEGMENTS` in
`session-control-core-v1.js` (pinned equal by the unit suite), and `SESSION_KEY_RE` /
`ANCHOR_NAME_RE`, two further members of the grep-governed `scv1_` family §"Foreign-Chain Row"
describes; `GIT_ENV_SCRUB` against `_tc_git`'s unset list in `hooks/lib/zensu-log.sh` (pinned by
the same suite); the secure-open inventory entry in
`tests/structure/test-windows-portability-guards.sh`, which classifies the module's one hardened
reader, its two exclusive temp creates (the anchor's, renamed, and the marker's, linked or, where
hard links are unsupported, copied with `COPYFILE_EXCL`), and its descriptor-landed append with
the exclusive-create, `nlink` and dev/ino checks; the
`ZDOC_WORKTREE_KEEP` / `ZDOC_WORKTREE_KEEP_IDLE_HOURS` exports in `hooks/lib/zensu-doctor.sh`
(pinned by `P1wk13`); the
`worktreeKeep` and `worktreeKeepIdleHours` entries in `config.example.json`; the `worktree:`
bullets and the frontmatter `session state` clause in `skills/doctor/SKILL.md`; the hook count in
`docs/configuration.md` (header, prose and its `#hooks-N` anchor), pinned by
`test-readme-hook-count-sync.sh`; the three
hook rows and two config rows in `docs/configuration.md`, the README docs-index row, and
`docs/worktree-keep.md`; the manifest entry in `tests/profiles/promptfoo-local-only.v1.json` with
the counts in `tests/SUITE-OVERVIEW.md`. `tests/structure/worktree-keep-v1.test.js` pins the
module (driven by `K3` in `tests/structure/test-worktree-keep.sh`, whose `UNIT_FLOOR` is the
measured case count and is raised in the same commit as any case added, whose `UNIT_MAX_SKIPPED`
pins how many cases may skip — none — so a skip fails K3 with its count and its `# SKIP` line
instead of reading as a deleted case, and which also drives the
three hooks end to end against a temp base repo plus a linked worktree), the `P1wk*` family in
`tests/structure/test-doctor.sh` pins the row shapes including the lazy-require degradation,
`P1wk13` pins the wrapper's two exports, `P1wk19` EXTRACTS the wrapper's on/off arm and evaluates
it against a stubbed predicate (presence greps cannot tell the arms apart, and driving the
whole wrapper cannot do it — it re-resolves its root from the bound record and ignores a fixture
`CLAUDE_PROJECT_DIR`), and `P1wk14` DERIVES every `worktree:` phrase the renderer emits and holds
the doctor skill's bullets against it. That derivation reads the source with a JavaScript string
reader rather than a character-class grep, because a character class stops at an escaped
apostrophe and truncates a row to a prefix another row's bullet already satisfies. It derives ONE
phrase per lead literal, so rows that share a lead (the stale, root-mismatch and no-branch
own-anchor rows and the no-branch variants; the four remedy variants of the rejected own-anchor
row, the fourth being the one without a promise; the two drift
rows; the two marker-present rows; the MISSING variants; the flag-off holds; the draining and the
non-draining unreadable listing) keep their distinguishing phrases pinned in both the
renderer and the skill by `P1wk14-shared`, and a new row that shares a lead adds its phrase
there. Name the pins
as a FAMILY (`P1wk*`), never as a range: a range endpoint is a hand-maintained numeral. Every row
has an executed case. The branch-unreadable row and the MISSING row's unknown variant are driven
by a worktree whose `.git` file names a missing directory, where `check-ignore`, `symbolic-ref`
and `rev-parse` exit 128 (measured on git 2.51.0); the same broken gitfile drives the recorded
drift while the branch is unreadable and, with a session started over it, the still-failing
no-branch row. An ignore verdict the ladder does not name is driven by a module wrapper that
overrides `markerIgnoreState` (`P1wk45`), a remedy it does not name by one that overrides
`anchorRemedy` (`P1wk47`), and the read-only exclude by a `0444` file, skipped
when the principal can write it anyway. The catch rows are driven by a missing module
(`P1wk7`), a module that fails to parse (`P1wk38`) and stub modules (`P1wk24`, `P1wk25`,
`P1wk37`). `P1wk18-judge` requires the renderer to call `branchState`, `anchorMatchesRoot`,
`recordedMoveSentence`, `branchNoun` and `anchorRemedy`, forbids it `judgeBranch`,
`unresolvedRecord`, `pausedState` and `detectDrift`, and holds it to handing `remedyLines` only
the recorded branch.

**Version: `patch`.** Walked against §"Runtime Lineage" entry by entry: no context-record or
workflow-state schema field — the anchor is a new session-keyed state file, the same class as the
reviewer denial note; no strict key set; three hooks ADDED and none removed, renamed or
re-matched, every one of them the ADVISORY shape the hook-inventory exemption names (their only
model-facing output is `additionalContext`, and they return no `permissionDecision`); two config
keys read through the PERMISSIVE `zensu_hook_enabled` / `_zensu_config_bounded_int` readers; no
attestation change.

**Known gaps, accepted and named:**

- **`.worktree-keep` is the app's constant, not a contract.** A later desktop build that renames
  it stops the protection silently; the drift detector is the net, and the source build in
  `KEEP_SOURCE_BUILD` is the thing to re-verify against the bundle after every desktop update.
- **`SessionEnd` delivery by the desktop app is UNVERIFIED.** A session that dies without it keeps
  its worktree out of the pool until its anchor ages past the idle window, and only a later
  SessionStart in the SAME base repository sweeps it. Say "unverified", never "handled".
- **The marker and the anchor are files in a session-writable directory.** They separate a
  worktree a live session holds from one nobody holds; they authenticate nothing, and a session
  can hold any worktree in its repository by writing a marker there by hand. The anchor's branch
  fields are the one channel a co-tenant could write INTO this session's context, and they are
  bounded by shape rather than by trust: `branchNameOk` refuses anything outside a git ref
  charset, so a planted record is rejected as a whole and the next prompt rewrites it.
- **An armed review chain still measures the taken directory.** The remedy moves the session's
  WORK into a nested worktree, but every record-root-anchored verb — the completion gate's change
  set, the edit-landing audit, the implementing-turn probe, the run log — keeps reading the outer
  directory, which now holds the taker's checkout. The remedy text and `docs/worktree-keep.md`
  say so; a Session Control re-anchor verb is the standing fix for this case as well as the
  recycle case.
- **The feature engages only for a session that STARTED inside `.claude/worktrees/<name>`.** The
  record root and the SessionStart `cwd` are what the three verbs key on, so a session that starts
  in the origin checkout and creates its worktree by hand — this repository's own mandated flow —
  is never anchored, marked or drift-checked; whether the pool would touch such a hand-created
  worktree at all is unverified.
- **The per-prompt cost is bounded by a payload pre-filter, not measured.** Past the pre-filter the
  prompt hook pays the principal check, the config read, the session bind, the project-root
  resolve, the idle-hours getter and the module child before it can answer — six `node` spawns
  and two `bash` spawns — on every prompt of a managed-worktree session; no wall clock was taken.
- **A branch switch the session made itself fires the disclosure once per context.** The text is
  conditional and names the re-baseline path; the detector cannot tell a takeover from a
  `git switch` run in the same directory. That path, `/clear`, relies on the host delivering a
  `clear` SessionStart, which records a fresh anchor whether or not the session id changes;
  whether it does change was not measured.
- **A paused operation suspends the check whoever started it.** While `rebase-merge`,
  `rebase-apply` or `BISECT_LOG` exists and HEAD is detached, no drift is recorded or disclosed,
  so a taker that pauses a rebase in the taken directory is reported only once it finishes; a
  drift recorded before the pause is stated again at a compaction or resume, and the doctor keeps
  showing it.
- **The paused baseline reads git's internal files.** `head-name` and `BISECT_START` are git's
  own state, not a documented interface; a git release that changes their format makes
  `pausedState` answer an unreadable target, which leaves the baseline unresolved until the
  operation ends rather than recording a wrong branch.
- **The copy fallback is not atomic.** Where hard links are unsupported, `COPYFILE_EXCL` creates
  the marker and then fills it, so a concurrent reader can see a partial marker as foreign for
  the instant the copy takes; it reports it and leaves it alone, and the next reconcile reads the
  complete marker as the plugin's own. A process killed during the copy leaves a partial marker
  that the plugin reads as foreign and never removes; the doctor reports it.
- **One silent adoption remains.** An anchor re-created at a prompt whose branch read ALSO failed
  is written unresolved and backfilled by a later prompt without the adopted-unverified notice,
  because the backfill cannot tell that record from a fresh start whose branch read failed.
- **Two DIFFERENT unrenderable branches read alike.** Both answer `UNRENDERABLE_BRANCH`, so a
  takeover that moves one to the other produces no drift. The head does move, but the head alone
  changes on every commit and cannot carry the signal.
- **The payload pre-filter and the hook's own anchor judge different objects.** The filter reads
  the raw payload TEXT; the hook anchors on the bound record. A payload that stops naming a
  `.claude/worktrees` component therefore skips the hook silently for the rest of the session even
  though the recorded root is a managed worktree — and the drift detector is this feature's own
  stated net for the day the app renames its marker constant. Keying the filter on the resolved
  root is the uncompromised fix and costs a session bind plus a node child on every prompt of every
  plain-checkout session, which is why it was not taken; the trigger needs the host to stop
  reporting the session's own directory.
- **The state-directory components are checked and then re-traversed.** `removeAnchor`,
  `ensureStateDir` and `publishMarker` (for its temp file) verify `.zensu` and `state` through
  `stateDirVerdict` and then let `unlinkSync`/`mkdirSync`/`openSync` resolve the path again, so a
  sibling worktree's owner can swap a component between the two and move an unlink, a recursive
  create or the marker's temp write outside the container this process verified. The unlink target name is pinned to `worktree-anchor-scv1_<64 hex>`, so the
  victim must already carry that exact name — narrow enough to be a residual rather than a
  primitive, and named here rather than left to be rediscovered. A descriptor-relative walk is the
  durable fix and Node exposes no `unlinkat`.
- **The RECYCLE case is NOT addressed.** When the app moves a session to a fresh worktree, the
  Session Control anchor stays on the old directory; that needs a re-anchor verb in Session
  Control and is a separate feature.
- **An UNBOUND session gets no disclosure.** The prompt hook reads the anchor under the RECORDED
  project root, so every relaxable bind failure in §"Relaxable Bind Failures" exits it silently;
  the doctor row is the only surface there.
- **Windows is UNVERIFIED and the CI weight is unmeasured.** `test-worktree-keep.sh` is in
  `ciStructureTests` and NOT in `tests/profiles/windows-ci.v1.json`, so only the weekly Windows
  Safety structure shard reaches it, with no wall clock taken; it has no
  `tests/profiles/ci-shard-weights.v1.json` entry and is costed at `defaultSeconds` until a real
  ubuntu `--ci` figure exists.
- **No ports.** `zensu-codex`, `zensu-kiro` and `zensu-antigravity` were NOT included. The premise
  is host-coupled twice over: whether that host's app reuses worktrees at all, and which file name
  its pool honours.
