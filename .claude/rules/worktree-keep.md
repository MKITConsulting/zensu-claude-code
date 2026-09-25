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

**ONE lifecycle rule, in ONE function.** `reconcileKeep` holds the marker present iff at least one
LIVE anchor exists in `<worktree>/.zensu/state/` — an anchor is this session's
`worktree-anchor-<scv1 session key>.json` (schema 1: worktree root, branch, head, liveness stamp,
drift), `live` while its stamp is inside `hooks.worktreeKeepIdleHours` (default 72, range
1..8760; a FUTURE stamp is stale, the `classifyDenialNote` rule). A stale anchor loses the marker
but is RETAINED until `REAP_FACTOR` times the window, because it is the only branch baseline:
reaping it at the liveness edge let a takeover during the idle window pass undisclosed, since the
next prompt adopted the taker's branch as a fresh record. **A REJECTED anchor holds the marker
too**, and that is a correctness rule rather than caution: without it a live session whose
anchor THIS build cannot validate would count as "no live anchor" and a sibling sweep would
unlink its marker — which is the exact damage the feature exists to prevent, and the shape §"Runtime Lineage" calls the ordinary case, since a mid-flight
update is precisely when one installation refuses what another wrote. `listAnchors` is also
BOUNDED at `MAX_ANCHOR_FILES`: the directory is session-writable and this walk sits on the
per-prompt path, so past the bound it answers `ok: false` and the marker is left exactly as it
stands — the same fail-safe an unreadable directory already took. Branch names are held to a ref-shape
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
land in one. The marker is created `wx`
(never through an existing symlink), removed only when it is a regular file the plugin wrote, and
a foreign or non-plain marker is left alone and reported. `ensureExclude` puts the name into
`<git common dir>/info/exclude` once and never touches `.gitignore`, so `git status` stays clean
in every worktree of the repository. `sweepSiblings` reconciles every sibling under
`<repo>/.claude/worktrees/` at SessionStart, bounded to 64 directories, which is what bounds
accumulation when SessionEnd never arrives.

**Three hooks, all ADVISORY, all main-principal, all behind the permissive `hooks.worktreeKeep`.**
The SessionStart and SessionEnd halves anchor on ONE root in ONE order — the bound record's native project root first, the
payload `cwd` only when the bind fails (a fresh start whose record is still being minted) — and
hand node the host-native spelling the bind exports, never the MSYS one `zensu_resolve_project_dir`
renders on Git Bash; each also declines, before any helper is sourced, a payload that names no
`.claude/worktrees` component, so a session in a plain checkout pays no bind on this path — a
pre-filter that judges the raw payload TEXT while the hook itself anchors on the record, which is
a divergence stated in the gap list below rather than an equivalence. The payload reader and that
ladder live in `hooks/lib/zensu-worktree-keep.sh` and are CALLED twice rather than copied, for
the reason `hooks/lib/zensu-witness.sh` states about its own pair: the two halves write and
remove the SAME anchor, so a one-sided edit orphans it under a root the other never reads. Both
also `unset WK_NOW WK_MAX_DIRS` before the module child, because `inputFromEnv` reads the clock
and the sweep bound from the ambient environment: an inherited `WK_NOW` makes every anchor stale
and one SessionStart then strips the marker from every sibling worktree in the repository, with no
ledger entry and no row that tells it apart from "no anchors exist". `sweepSiblings` additionally
CLAMPS a supplied bound to `MAX_SWEEP_DIRS` rather than trusting it.
`session-start-worktree-keep.sh` writes or refreshes the anchor (a fresh start records the branch;
`resume`/`compact` refresh only the stamp, because the drift may already be in place), puts the
exclude line in, reconciles, sweeps. `user-prompt-worktree-keep.sh` binds the session, refreshes
the stamp at most every ten minutes, reconciles, and on a NEW drift emits one `additionalContext`
naming both branches and the head, the likely takeover, the instruction not to switch the shared
directory back, and the nested-worktree recipe from `remedyLines` —
`git worktree add .claude/worktrees/<slug> <recorded branch>` INSIDE the session's own worktree,
which the desktop write-guard admits (measured on 2.2553.1: only a sibling or temp-dir worktree is
refused as `sibling_worktree`) and the Zensu Bash gates admit as in-anchor git. The same drift is
disclosed once and a switch back clears it. `session-end-worktree-keep.sh` removes the anchor and
reconciles. Every fault exits 0 after a stderr note; nothing here returns a `permissionDecision`
in either direction, and no gate is relaxed.

**`/zensu:doctor` renders the state in `worktreeKeepRows`**, called from BOTH branches of
`stateBlock` — the populated path and the `readdirSync` ENOENT branch — because a session whose
worktree has no `.zensu/state` yet is exactly the one with no anchor. The module is required
LAZILY and guarded; a load failure costs one row, and that row is a WARN only when the project
root sits under a `.claude/worktrees` container, so a plugin root that predates this feature (most
doctor fixtures) stays green on a plain checkout. Disabling renders a switched-off row rather than
silence, the `reviewerSpawnPermissionCheck` rule. A drift row and a MISSING-marker row are WARN
and withhold the green summary for as long as they hold, deliberately: a taken directory is real
state the user must act on. The drift sentence and the remedy are rendered by the module's own
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
marker-state and verdict WORDS come from the module's exported `MARKER_STATES` / `VERDICTS`
rather than bare literals — a crossing between two files, which is the kind this repository
records as expensive to get wrong. **Every path in the family is folded** through `foldPath`
before it is rendered: the doctor skill tells the model to relay these rows, so a directory name
carrying a spaced colon would otherwise forge a `label : value` pair inside a line the user reads
as the report's own verdict. And **every module call sits inside ONE try**: `lstatOrNull`
re-throws any errno but `ENOENT`, and the report is accumulated and written once, so one
`ENOTDIR` from a concurrently-swapped state directory discarded the WHOLE report. `anchors.ok`
is consulted before any count is rendered, because `listAnchors` answers its failure with EMPTY
lists and a green row claiming zero live anchors over a directory it never read is the inversion
the sibling doctor rows exist to prevent.

**Coupled sites that move together:** `KEEP_FILENAME` / `KEEP_SOURCE_BUILD` / `ANCHOR_PREFIX` /
`ANCHOR_NAME_RE` / `DEFAULT_IDLE_HOURS` / `MAX_IDLE_HOURS` / `MAX_SWEEP_DIRS` /
`REFRESH_INTERVAL_MS` / `MAX_ANCHOR_FILES` / `UNRENDERABLE_BRANCH` / `branchValueOk` /
`MARKER_STATES` / `VERDICTS` / `ACTIONS` / `EXCLUDE_COMMENT` and the three verbs in the module;
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
reader, its two exclusive creates and its descriptor-landed append; the
`ZDOC_WORKTREE_KEEP` / `ZDOC_WORKTREE_KEEP_IDLE_HOURS` exports in `hooks/lib/zensu-doctor.sh`
(pinned by `P1wk13`); the
`worktreeKeep` and `worktreeKeepIdleHours` entries in `config.example.json`; the `worktree:`
bullets and the frontmatter `session state` clause in `skills/doctor/SKILL.md`; the hook count in
`docs/configuration.md` (header, prose, `#hooks-31`) and the `configuration.md#hooks-31`
cross-link in `docs/architecture.md`, both pinned by `test-readme-hook-count-sync.sh`; the three
hook rows and two config rows in `docs/configuration.md`, the README docs-index row, and
`docs/worktree-keep.md`; the manifest entry in `tests/profiles/promptfoo-local-only.v1.json` with
the counts in `tests/SUITE-OVERVIEW.md`. `tests/structure/worktree-keep-v1.test.js` pins the
module (driven by `K3` in `tests/structure/test-worktree-keep.sh`, which also drives the three
hooks end to end against a temp base repo plus a linked worktree), `P1wk1`–`P1wk12` in
`tests/structure/test-doctor.sh` pin twelve row shapes including the lazy-require degradation,
`P1wk13` pins the wrapper's two exports, `P1wk19` EXTRACTS the wrapper's on/off arm and evaluates
it against a stubbed predicate (presence greps cannot tell the arms apart, and driving the
whole wrapper cannot do it — it re-resolves its root from the bound record and ignores a fixture
`CLAUDE_PROJECT_DIR`), and `P1wk14` DERIVES every `worktree:` phrase the renderer emits and holds
the doctor skill's bullets against it. That derivation reads the source with a JavaScript string
reader rather than a character-class grep, because a character class stops at an escaped
apostrophe and truncates a row to a prefix another row's bullet already satisfies. Name the pins
as a FAMILY (`P1wk*`), never as a range: a range endpoint is a hand-maintained numeral. ONE row still has no
executed case — the branch-unreadable row, which needs `git` to fail inside the renderer — and
the catch arm now has none either, because the try was widened to cover every module call; the
derivation covers their wording only.

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
- **A branch switch the session made itself fires the disclosure once.** The text says so; the
  detector cannot tell a takeover from a `git switch` run in the same directory.
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
- **The state-directory components are checked and then re-traversed.** `removeAnchor` and
  `ensureStateDir` verify `.zensu` and `state` through `stateDirVerdict` and then let
  `unlinkSync`/`mkdirSync` resolve the path again, so a sibling worktree's owner can swap a
  component between the two and move an unlink or a recursive create outside the container this
  process verified. The unlink target name is pinned to `worktree-anchor-scv1_<64 hex>`, so the
  victim must already carry that exact name — narrow enough to be a residual rather than a
  primitive, and named here rather than left to be rediscovered. A descriptor-relative walk is the
  durable fix and Node exposes no `unlinkat`.
- **`WK_NOW` and `WK_MAX_DIRS` remain a test seam in production code.** The hooks unset them and
  the sweep bound is clamped, so no shipped caller can reach them — but they are still read from
  the ambient environment by `inputFromEnv`, and a fourth caller that forgets the unset inherits
  the whole failure. Gating them behind an explicit test-only flag is the fix that removes the
  class rather than the instance.
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
