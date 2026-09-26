---
paths:
  - "hooks/lib/claude-hook-session-v1.js"
  - "hooks/lib/zensu-session.sh"
  - "hooks/lib/reviewer-capability-v1.js"
  - "tests/structure/test-orphaned-project-root.sh"
  - "tests/structure/test-stop-session-binding-recovery.sh"
  - "tests/structure/test-vanished-session-cwd.sh"
---

# Relaxable Bind Failures (`hooks/lib/claude-hook-session-v1.js`)

_Moved from the root `CLAUDE.md`. Where this text says "this file" or names `CLAUDE.md`, it means the repository conventions as a whole: `CLAUDE.md` plus `.claude/rules/`._

A failed bind to the immutable Session Control record denies, with exactly **two**
documented exceptions. Both mean no workflow document is reachable, so relaxing waives
nothing — and they are deliberately **two predicates, never one widened check**, because
they are different diagnoses with different remedies:

- `unregisteredSession` — no record at all (the 0.17.0 upgrade state). True only on a
  clean `ENOENT` of the records directory or the record file.
- `orphanedProjectRootSession` / `resolveOrphanedProjectRoot` — a record valid in every
  other respect whose recorded `project_root` is gone (a deleted or recycled worktree).
  It waives ONE check via `readOrphanedProjectRootContext`
  (`hooks/lib/session-control-core-v1.js`, an internal `allowMissingProjectRoot` option
  on `validateContext`) and additionally requires that path to be **absent** — `lstat`,
  never `realpath`, so a dangling symlink stays a present-but-wrong root. It then
  re-applies the plugin-root and plugin-data identity checks `resolveHookSession`
  applies, so a second disagreement is never relaxed alongside the first.
  **Amended by semver-compatible binding:** the plugin-root check there is now the
  lineage-relaxed `servesRecordedRuntime`, so a vanished project root IS relaxed
  alongside an executing root that is a declared-compatible upgrade — deliberate,
  since neither disagreement can anchor a workflow document. An INCOMPATIBLE root,
  a differing `plugin_data`, and every other disagreement stay unrelaxed. See
  "Runtime Lineage (`version_type` is load-bearing)" above.

**Every gate that relaxes one must consider the other**, and they do NOT all agree by
design — the split is the contract, so changing a predicate means re-deciding each site.
The authoritative per-gate roster is the "Unbindable sessions" table in
`docs/session-control.md`, which
carries one column per state; keep exactly one roster and do not duplicate it here. Two
properties are easy to get wrong and cost the whole feature:

- **A deny from ANY hook on a matcher wins.** `hooks.json` registers four PreToolUse
  hooks on the `Bash` matcher (`pre-bash-zensu-gate.sh`, `pre-bash-source-write-gate.sh`,
  `pre-write-secret-scan.sh`, `pre-browser-navigation-consent.sh`) and one on `.*`
  (`pre-reviewer-capability-gate.sh` via `reviewer-capability-v1.js`), and all five can
  deny. O21a enumerates the matcher, so a hook added there changes this roster. The consent gate exits before its bind for every command
  that carries no `playwright-cli` marker and admits the recognized `/zensu:doctor` and adoption
  commands through `zensu_doctor_allowed` before its module runs, so on a POSIX host with `node`
  it never stands between a session and the doctor — the recognizer refuses on win32; it denies a `zensu-verify-*` call and a command that merely mentions
  both markers. `/zensu:doctor` runs through Bash, so it is reachable only
  if EVERY one of them allows. Both the `.*` gate and the secret-scan gate were missed in
  turn while the single-gate test stayed green and the feature silently did not work.
  `tests/structure/test-orphaned-project-root.sh` O21a therefore enumerates the Bash
  matcher from `hooks.json` and asserts every hook on it allows, so a hook added later is
  covered without editing the test.
- **Mutating tools stay denied on purpose.** `pre-edit-tdd-reminder.sh` relaxes neither
  state: nothing in either can anchor a write to a project. Its matcher is
  `Edit|Write|MultiEdit`, so `NotebookEdit` is NOT phase-gated — in a healthy session
  either, which is why the relaxation restores the pre-Session-Control capability set
  rather than widening it. Say "Edit/Write/MultiEdit", never "all mutating tools".
- **A Bash write without a project anchor denies; a read does not.** In both relaxed
  states `CLAUDE_PROJECT_DIR` is typically gone or unset — in the orphaned state it is by
  construction the deleted directory, since the record's `project_root` was minted from
  the SessionStart cwd. `pre-bash-source-write-gate.sh` therefore runs the parser's
  `BSWG_MODE=detect` channel check, which needs no anchor, and denies only commands that
  actually write. Denying unconditionally there once put the diagnostic back behind the
  defect it reports, and the healthy-anchor test fixtures hid it; `O29`/`O29a` pin both
  the deleted-root and unset-anchor shapes.

**A vanished LIVE `cwd` is NOT a third member, and it must not become one.** Both states
above are failures of the BIND. A PreToolUse `cwd` that no longer names a real directory —
a worktree removed while the session was still inside it, with the recorded project root
intact — leaves the bind whole. `reviewer-capability-v1.js` used to canonicalize that `cwd`
inside `revalidateSessionContext`, so every tool call of a perfectly bound session — the two
recognized commands aside, and those only off win32 — was denied with the generic `immutable context revalidation
failed: PreToolUse cwd does not exist`, and neither relaxation above could reach it, because
both key on the bind and the bind had not failed. It now
canonicalizes the `cwd` only in the three branches whose path rules consume it —
`reviewer-readonly-v1`, `zensu-plm-readonly-v1` and `host-profile-v1`, which deny through
`unusableWorkingDirectoryReason` — while `main-v1` returns before any path rule and
`evidence-worker-v1` resolves its leased paths against the canonical project root on
`trusted`. The two read-only profiles' `SubagentHandback` report is decided between the
revalidation and that resolution, because it resolves no path — see
`.claude/rules/reviewer-capability-gate.md`. **The ORDER is the contract:** the bind, the recorded root, the digest and the
workflow revalidation all run BEFORE the `cwd` is judged, so the missing-baseline named deny
and every bind-failure deny still win for the main thread. `pathResolutionProfile` re-spells
the branch ladder below it to pick the profile name, so a new principal branch lands in both.
A branch placed ABOVE the resolution that reads `trusted.toolCwd` gets `undefined`, and
`path.resolve` throws a `TypeError` into that branch's own catch — fail-closed, but unnamed.
Measured before the change: driving every `PreToolUse` registration in `hooks/hooks.json`
with a vanished `cwd` showed the capability gate as the ONLY hook that denied.
`tests/structure/test-vanished-session-cwd.sh` pins the verdict matrix and re-derives that
cross-hook comparison, so a later hook that starts canonicalizing the `cwd` fails there
rather than wedging sessions in the field. Operator accounts: the `cwd` sentence in
`docs/session-control.md` §"Claude Code Workflows" and `docs/gates.md` §"Vanished Working
Directory". **Version: `patch`** — it lifts an existing deny for two principals and rewords
it for three; no schema field, strict key set, hook, matcher, config key or attestation
moves. Windows is UNVERIFIED: the suite is in `ciStructureTests` and not in
`windows-ci.v1.json`, so only the weekly Windows Safety structure shard reaches it.
`zensu-codex`, `zensu-kiro` and `zensu-antigravity` carry their own capability gates and
were NOT included.

Shell wrappers live in `hooks/lib/zensu-session.sh` (`zensu_session_unregistered`,
`zensu_session_orphaned_project_root`, `..._model`, plus
`zensu_session_incompatible_runtime` / `..._model` and
`zensu_session_incompatible_orphaned_root` / `..._model`, and
`zensu_session_pruned_plugin_root` / `..._model`). The orphaned wrapper **prints the
dead path on stdout**, BOTH version-pair predicates print `recorded<TAB>executing`, and the
orphaned-root pair prints **the dead path** too;
inside a PreToolUse gate stdout is the JSON decision channel, so a caller wanting the
predicate alone must discard it explicitly, and a caller wanting the value must capture
it into a variable before emitting anything. The orphaned-root pair additionally answers on
THREE statuses — 0 with a path, **3** for a positive negative, 1 for an unavailable answer —
because a caller that cannot tell the last two apart has to guess, and guessing wrong makes it
assert a workflow document that is gone.

**The third and fourth predicates are DIAGNOSES, never further relaxations.**
`zensu_session_incompatible_runtime` and `zensu_session_pruned_plugin_root`
belong to this roster only because every gate that consults the two above must decide what
to do about them too — and the answer is the same everywhere: keep denying. The pruned state
is unrelaxed because a workflow document is still reachable there — its project root is
present by construction. The lineage predicate matches TWO states, and they are unrelaxed for
DIFFERENT reasons: with the recorded project root still present a workflow document is
reachable, so relaxing would waive a live guarantee rather than a dead one; with that root
gone the document is not reachable from this record, and what stands in for the guarantee is
that the state has a real in-place repair — adoption, a user action leaving provenance —
rather than a silent waiver. A consumer that says anything about the workflow document must
ask `zensu_session_incompatible_orphaned_root` and branch. TWO do: the Stop hook, and
`zensu-doctor.sh`, which asks the model twin and selects its fourth binding row from it.
What the predicates change is the MESSAGE: `zensu_emit_hook_session_deny` now spells FIVE
scopes, two of which — `incompatible-runtime` and `pruned-plugin-root` — take the two
versions as positional arguments. FIVE gates can deny
in either state: the four shell gates emit the matching scope, and `pre-reviewer-capability-gate.sh` —
the `.*` matcher, where `isRecognizedInvocation` is false for every non-Bash tool — spells the
same cause and remedy itself in JS, because the shell emitter is not reachable from it. A gate
left on the generic text tells the user to start a fresh session while its sibling says the session can
be repaired in place — two denies contradicting each other about the two bind failures that
have an in-place remedy. The Stop hook is the single exception and RELEASES for both, because
it cannot read the chain from an unbound session at all.

`zensu_emit_hook_session_deny` must never assert "no record" as the cause: naming the
wrong relaxable state sends a user whose worktree was deleted hunting for a record that is
sitting intact in plugin data. Same rule for the `/zensu:doctor` binding rows.

**The release claims only what an ENOENT proves.** A moved or renamed root, and an
unmounted volume, produce the same ENOENT while the workflow state survives intact
elsewhere — so the Stop release says no completion was proven, never that nothing existed
to prove. It also means the release can be induced by renaming the project root, and that
IS reachable from inside a session: `mv` carries no write channel, while `ZENSU_CHAIN` is
read from the hook's inherited environment and a per-command prefix cannot reach it — the
two are not equivalent capabilities. Accepted anyway, because the alternative wedges every
legitimately deleted worktree forever with no in-session escape. **Known open improvement:**
an induced release is currently silent — it cannot be ledgered, because the document a
bypass entry would live in is the one that became unreachable — so a detection surface (a
sidecar beside the immutable record, surfaced by `/zensu:doctor`) is still missing.

**Port-relevant.** The core half (`validateContext`'s `allowMissingProjectRoot`,
`readContextInternal`/`readOrphanedProjectRootContext`, and `requireAbsentDirectoryPath`,
which is the shape-without-existence rule both that reader and `buildContext`'s waived
branch share) lives in the cross-host
`session-control-core-v1.js`; the host half (binder mode, shell predicate, gate
re-decisions, doctor row) is per host. A port that takes only the core delta keeps the
worktree-deletion wedge; a port that takes neither drifts from this core.

Operator-facing accounts that must move with the predicates: the "Unbindable sessions"
table in `docs/session-control.md`, the Stop-binding section of
`docs/tdd-manager-workflow.md`, and the
binding rows in `skills/doctor/SKILL.md`.
`tests/structure/test-orphaned-project-root.sh` pins the predicate truth table, the
capability gate, every Bash-matcher hook, the Edit gate and the doctor rows;
`tests/structure/test-stop-session-binding-recovery.sh` pins the Stop halves, where B4 is
the discrimination test that a root which still EXISTS but no longer matches keeps
blocking, and B1d that a second disagreement is never relaxed alongside the first.
