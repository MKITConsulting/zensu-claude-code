---
paths:
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-directive.sh"
  - "hooks/lib/zensu-delivery-route.sh"
  - "hooks/lib/zensu-tdd-mode.sh"
  - "hooks/lib/zensu-marker-write.sh"
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/session-start-banner.sh"
  - "hooks/session-start-primer.sh"
  - "hooks/plan-approved-delegate.sh"
  - "hooks/user-prompt-tdd-reminder.sh"
  - "skills/delivery-route/**"
  - "tests/structure/test-delivery-route.sh"
  - "tests/structure/test-plan-approved-delegate.sh"
  - "tests/structure/test-tdd-vanilla-mode.sh"
---

# Session Delivery Route (`/zensu:delivery-route` + `hooks.defaultDeliveryRoute`)

The route question that `hooks/plan-approved-delegate.sh` asks after a plan approval and
`hooks/user-prompt-tdd-reminder.sh` asks on a code request is answered ONCE PER SESSION when the
answer is the Zensu workflow, and never asked when the project configures a default. A direct,
autopilot or pilot answer is never remembered, so the question comes back after it; implementing
directly becomes the session's route only through an explicit `/zensu:delivery-route --direct`
or the config key.
The mechanism is a session marker plus a config key; the question itself is unchanged
(`.claude/rules/plan-approval-delivery-route.md`). The measured
reason: across this machine's transcripts from 12 June to 20 September 2026 the question was
asked 835 times in 539 sessions, and a session marker plus a configured `tdd` default would have
removed 488 of the 678 decisive answers. Before this, the only switch was `autoTdd:false`, which
removes the workflow together with the question.

## The ladder has one owner

`hooks/lib/zensu-config.sh` owns the whole ladder:

1. an explicit preference in the user's OWN text — fast-path (B) of the plan directive, the
   reminder's negation-then-affirmation arms — judged by the model and never recorded;
2. the session marker `<project>/.zensu/state/delivery-route-<session-key>.json`
   (`{"route":"tdd"|"direct"}`; `{"route":"auto"}` is a recorded release and falls through);
3. the inherited route `<project>/.zensu/state/inherited-route-<session-key>.json`
   (`{"route":"tdd"}` only), which a released own marker skips (§"Linked sessions inherit `tdd`");
4. `hooks.defaultDeliveryRoute` ∈ `tdd | direct | ask`;
5. ask.

`zensu_delivery_route_resolve <root> <key>` answers `route<TAB>source`,
`zensu_delivery_route_field` renders the ONE spelling both directives and the doctor carry, and
`zensu_delivery_route_status_line` renders the `--status` line from the resolver's answer plus
the one fact the resolver drops (a RELEASED marker), so the ladder ORDER exists once.
`_zensu_marker_one_line_value` is the bounded reader shared with the tdd-mode marker: one parse,
two vocabularies.

**Both mechanical ranks are read under the ONE root the caller hands the resolver.** The marker
lives under it, and the config overlay is read from it through
`zensu_default_delivery_route <root>` rather than from the ambient `CLAUDE_PROJECT_DIR`. No
caller pins `CLAUDE_PROJECT_DIR`; the two hooks, the helper's `--status` and the doctor probe
all pass the RECORDED project root, so they cannot pair one tree's marker with another tree's
config. An empty root answers `ask`: a hook whose `zensu_resolve_project_dir` failed never lets
the global config alone pick a route. `autoTdd`, `tddReminder` and `tddImplementation` in the
same hooks stay harness-anchored on purpose; moving them is its own change with its own pins
(D26 and siblings). R11b, R11c and R11d pin the two-root cases.

## The vocabulary bound is the safety property

The vocabulary is `tdd | direct` and nothing wider. `/zensu:autopilot` pushes a branch and opens
a pull request; `/zensu:pilot` commits, opens a pull request and mutates tracked feature state.
A committed `.zensu/config.json` must never pre-select either for every clone, and a marker must
never make a later approval take an outward-facing step the user did not choose for that plan.
The helper `hooks/lib/zensu-delivery-route.sh` refuses every verb except
`--tdd | --direct | --auto | --status`, the config reader answers `ask` for any other value, and
clause (C)'s bar on the two routes in a headless run is byte-identical: a decided route replaces
only the DEFAULT that (C) names. The `D13` slices in `tests/structure/test-plan-approved-delegate.sh`
hold that; the new directive text sits outside the (B) and (C) slices.

## Two writers

The user, through `/zensu:delivery-route` (the twin of `/zensu:tdd-mode`, with the same "only
the user changes it" injection rule, carried in the skill's description as well as its body);
and the model, immediately after the user answers the question with the Zensu workflow — the
RECORD sentence in both directives tells it to run the rendered helper command with `--tdd`
before dispatching, and names that one Bash call as coming BEFORE the "next tool call" the
workflow arm names, so the two orders cannot be read as a conflict. If the user declines that
call's permission prompt, the model says in one line that nothing was recorded and that the
question will come back, then dispatches. A direct answer, the outward-facing answers and a
preference taken from the approval or request text record nothing, and both directives tell the
model never to record `--direct` itself. The question says what outlives it: the plan question's
workflow option and the reminder's Yes state that the answer is remembered for the rest of the
session, the other question's requests included unless that question is switched off, through
one Bash call the user may be asked to allow, the direct option and the No state
that they decide only that plan or request, and `/zensu:delivery-route` changes the route. The
option LABELS are unchanged, because `evals/plan-approval-hook` selects by label.

**Only the fail-safe answer is recorded automatically.** The reminder asks per request and the
plan gate per plan, but both read one marker. A recorded `direct` would let one quick "No" to the
reminder skip the review chain AND the four-route question for a later, possibly large, approved
plan, with only the model's status line as notice. A recorded `tdd` adds the review chain rather
than removing it. So the model records only `tdd`, and `direct` becomes session-wide only through
the user's explicit `/zensu:delivery-route --direct` or `hooks.defaultDeliveryRoute`. Recording
provenance, or keeping a separate record per question, was rejected: either splits the one ladder
the two hooks share, and treating a foreign record as a mere recommendation would undo the (S)
clause's "do NOT ask". The skill states the sharing in its own text.

Both marker writers — this helper and `hooks/lib/zensu-tdd-mode.sh` — write through ONE
sequence, `zensu_write_session_marker` in `hooks/lib/zensu-marker-write.sh`, sourced right after
the verb check — a failed load exits 2 with a cannot-load refusal before anything binds (R8l) —
and handed the helper's own script name so each keeps its message prefix:
the shared symlink guard before the write and again before the rename (the second
call is the TOCTOU defense), an O_EXCL `mktemp` temp leaf with an `-L` refusal before the
redirect, a non-regular check, the rename, and a regular-file post-condition after it, because a
directory swapped in after the check makes `mv -f` succeed with nothing recorded. The
`-L` test narrows the temp-leaf window and does not close it; the closing O_NOFOLLOW open costs a
node spawn on every write and is not taken. The cleanup trap is EXIT-only and INT, TERM and HUP
only exit (130, 143, 129): a cleanup handler on the signals themselves returned into the write,
which then resumed and could re-create the temp leaf through a plain redirect without O_EXCL.
The state directory is created with `mkdir -p -m 700`, and a failed call is still accepted when it
left a directory that is not a symlink: Git Bash on Windows creates the directory and then fails
the mode change with `Permission denied`, so a fresh project could never record a route there.
`hooks/lib/zensu-zen-mode.sh` and `hooks/user-prompt-zen-mode.sh` carry the same fallback. R8c3
and Z100 in `tests/structure/test-zen-mode.sh` drive both outcomes through a `mkdir` PATH shim:
the directory created without its mode is accepted, and a call that created nothing is refused.
R8f/R8g/R8h and T9g/T9h/T9i drive the temp-leaf refusal and both halves of the post-condition
(`! -f` and `-L`) through PATH shims for `mktemp` and `mv`; R8i and T9j send INT, TERM and HUP
through another `mv` shim and require the helper to end with 130, 143 and 129 and no success line.
R8j and T9k drive the pre-rename re-check: a `mktemp` shim plants a link to an empty directory at
the marker leaf after the temp exists, and each helper must refuse with its own prefix, leave the
link target empty and leave no temp. R8k requires both helpers to source the library and neither
to keep its own `mktemp` or `mv -f`.

## Linked sessions inherit `tdd`

A session another Claude Desktop session started (`start_session`, fresh or forked context) has its
own CLI session id and key, so the parent's marker never reached it: over 424 linked sessions
measured on 2026-10-18, none opened with a decided route, the 6 whose parent had recorded `tdd`
included. Its first prompt is the brief the parent wrote, and it arrives as `typed`, so a route
named in a brief acted as the user's own preference. The measurements and decisions are in
`docs/superpowers/specs/2026-10-18-linked-session-route-design.md`.

**Lineage comes from the desktop's own records, located through the hook environment.**
`hooks/lib/linked-session-v1.js` reads `CLAUDE_CODE_HOST_SESSION_ID`, `CLAUDE_CODE_ACCOUNT_UUID` and
`CLAUDE_CODE_ORGANIZATION_UUID` (a `UserPromptSubmit` hook run by the desktop's own Claude Code
2.1.299 binary saw all three), opens `<store>/<account>/<org>/<host id>.json` and follows
`spawnedFrom.sessionId` to the parent's record in the same directory. A set `ZENSU_CCD_STORE`,
trimmed and MSYS-mapped, is the only store candidate, with no fallback behind it, the rule of
`ccdStoreCandidates` in `skills/session-trail/scripts/trail.mjs`, so a store the user pointed
session-trail at is the store this module reads; a relative value names no store here, because a
hook's working directory is not the user's. Binding checks: the shape of
each id; the store, account and organization directories real directories; each record a regular
file opened without following a link, at most 8 MiB; the own record's `sessionId` equal to the host
id; its `cliSessionId`, when present, equal to the payload's `session_id`; a parent id other than
the own one. The parent's project root comes from the parent's Session Control record (`sessionKey`
of the parent's `cliSessionId`, read through `privateRecordsDirectory` after `CLAUDE_PLUGIN_DATA` is
canonicalized by the binder's own `canonicalDirectory`, as `resolveHookSession` does, at most 1 MiB,
schema and version checked, a canonical existing directory), never from the desktop record's `cwd`, which
session-trail measured disagreeing with a fork's own records. Inheritance needs both roots to share
one real `git rev-parse --git-common-dir`.

**One answer per session.** `zensu_linked_session_resolve` in `hooks/lib/zensu-linked-session.sh`
runs the module and keeps the answer in `linked-session-<key>.json`
(`{"state":"linked"|"none"|"unresolved"}`). `linked` and `none` are final. `unresolved`, an own
record that is missing or unreadable, is retried once and then written as `none`. A session without
`CLAUDE_CODE_HOST_SESSION_ID`, without a payload session id or without node answers `none` with no
process and no file, and so does one whose `.zensu/state` cannot be written:
`_zensu_linked_session_cache_writable` creates the directory as the marker writer does and requires
it writable and searchable before the module starts, because an answer that cannot be cached would
start the module again on every prompt. `zensu_linked_session_pending` answers the same cheap questions without a
process, so a caller that would have to start one only to read the payload session id asks it first:
the plan gate reads that id once, where its Autopilot branch already reads it, and calls the resolver
only while the lineage is pending. On `linked`, a same-repository parent whose own marker reads `tdd`, or whose own
marker is absent and whose inherited marker reads `tdd`, makes it write `inherited-route-<key>.json`
before the linked marker. The parent's markers are read through `zensu_delivery_route_marker_state`
and `zensu_inherited_route_state`, so each format keeps one reader. Every fault falls back to the
ladder without the inherited rank.

**Only `tdd` is inherited**, by the rule in §"Two writers": an inherited `tdd` adds the review chain
and never removes it. A parent's `direct`, a released parent marker and a configured default pass
nothing on. The answer is a snapshot: later changes in the parent do not move the child. The
inherited rank sits below the own marker and above the config key, because it is a choice the user
made for the same work. A released own marker (`--auto`) skips it, and `--direct` writes an own
marker that wins. `zensu-delivery-route.sh` keeps its four verbs: only the hooks write the two new
files.

**The brief note.** Both ask-hooks resolve the lineage: the reminder on a typed, slash-with-arguments
or CI-monitor prompt while no chain is active, and the plan gate on its standalone branch. The
resolver answers `fresh-linked` only on the run that wrote the linked marker from absent AND only
while the own desktop record shows no completed turn, and only the reminder then prefixes
`ZENSU_LINKED_BRIEF_LEAD` from `hooks/lib/zensu-directive.sh` to whichever shape it emits, through
the optional third argument of `zensu_delivery_route_substitute`. The marker alone cannot say that a
prompt is the brief: it is keyed by root and session key, so a patch update reaching a running
session, `--restore-root`, a re-anchor or a new CLI session id under the same desktop session all
find it absent on a prompt the user typed. The desktop's own `completedTurns`, which its result
handler raises after every successful turn and which is absent before the first, is the
session-wide fact; the module reads it as the sixth field of its line, `first` or `later`. The lead is
added on the parsed JSON, never in a third heredoc, so `P1`, `P2` and `R13` are untouched. A retry
that resolves `linked` answers `linked`, because a later prompt is the user's own. The plan gate adds
no sentence: its fast path (B) reads only the user's own approval message, and its heredocs sit close
to `D44`'s 9,000-character bound.

## Placeholders, not interpolation

Each ask-hook keeps exactly TWO quoted `cat <<'JSON'` heredocs, because the parity helper in
`tests/structure/test-tdd-vanilla-mode.sh` refuses a third block. The values travel as
placeholders substituted on the PARSED JSON by `zensu_directive_substitute` in
`hooks/lib/zensu-directive.sh` (`hooks/session-start-primer.sh` for its log command, both
ask-hooks through `zensu_delivery_route_substitute`): the record command carries `printf %q`
backslashes that a shell substitution into the raw text cannot JSON-escape. That library holds
the record command and the skill fallback too, so `zensu-config.sh` keeps to reading config and
the two markers. It is one of TWO substitution conventions, and the second is deliberate:
`hooks/user-prompt-zen-mode.sh` fills `{{ZENSU_CHAIN_ANCHOR}}` by shell parameter expansion on
the raw body, with no process, because that value is a closed vocabulary that never needs JSON
escaping. Each hook that substitutes sources the directive library itself. The substitution is
one pass, so a value is never scanned for another placeholder. When node cannot substitute, the
delivery-route wrapper still emits valid JSON with the skill sentence in place of the command, so
the directive is never routed to silence, and it puts the brief lead right after the
`additionalContext` opener, in either spelling the hooks emit, so the note survives the fallback;
the primer emits nothing, as before. The reminder's other
three shapes are `printf` literals through the same wrapper, never a third heredoc: the CI note, the
decided line it sends on every prompt while the field reads `tdd` or `direct`, and the short line it
sends on a later `ask` prompt of a context generation that already received the full text
(`.claude/rules/prompt-ledger.md`). The CI note and the decided line never carry the record command;
the short line does, through the same placeholder, so a Yes can be recorded even when the full text
is no longer in context.

## Disclosure, five surfaces

The directive field, the status line the model opens with (`Executing via /zensu:tdd (route:
session marker)`), the SessionStart banner line for a configured default, the `--status` verb,
and two `/zensu:doctor` rows.

- **Banner.** The disclosure sits ABOVE the `sessionBanner` gate for the reason the
  `autoTdd:false` line sits there, and it withholds the route-question promise. It reads the key
  under the root the binder's `resolveFreshHookProject` answers, through the same call and the
  same host-path conversions as `hooks/session-start-autopilot-resume.sh` — an existing record's
  root on a retry or a `clear`, else the canonical `CLAUDE_PROJECT_DIR`. Each copy names the
  other; one shared helper for both copies crosses the MSYS path-conversion boundary and is a
  separate change. The mutable payload `cwd` is never read; the binder's own rule says it is never a project
  authority. When that resolution is unavailable, the ambient read stands. KNOWN LIMIT: on a FRESH
  start the banner runs concurrently with the Session Control registrar, which mints the record
  from the payload `cwd`; until the record exists the banner falls back to `CLAUDE_PROJECT_DIR`,
  so where the two roots differ the race decides which tree's config the banner discloses, while
  both ask-hooks later read the record's root.
- **Doctor.** A Config row validates `hooks.defaultDeliveryRoute`, and a Session-state
  `delivery route:` row is fed by the wrapper probe `ZDOC_DELIVERY_ROUTE`, which runs only for a
  `bound` session and renders a missing-check row otherwise. Both rows name a switched-off
  reader (`hooks.autoTdd=false`, `hooks.tddReminder=false`), because each hook exits on its own
  flag before it resolves the route, and a `tdd` session row then names the one half that still
  dispatches to `/zensu:tdd` rather than claiming every code change does (R18g). An unknown config value renders as written — a string once,
  never re-quoted — bounded to 40 characters with a `…` marker, folded through `foldSlot`, and
  the load-failure arm renders `FOLD_UNAVAILABLE` inside the call site's own parentheses.
- **One wording, two carriers.** The three switched-off-half literals and the message-preference
  literal (a preference in a message decides only that request; `/zensu:delivery-route` changes
  the route for the session) exist in the banner and in the doctor renderer. R14e extracts all
  four from both files and requires equality.
- **The banner never reads the marker.** It discloses the configured default only. A marker that
  a `clear` leaves in place is disclosed by the directive field, the status line, `--status` and
  the doctor row.

Nothing is ledgered: a recorded route is a MODE choice like the tdd-mode marker, a config key is
standing configuration, and no `ZENSU_*=off` spelling exists for it. The prompt ledger of
`.claude/rules/prompt-ledger.md` records which full TEXTS a context generation received, never a
route: a route change moves only the field, and every shape of the reminder carries the field.

## Coupled sites

- `zensu-config.sh`: `zensu_delivery_route_marker_path`, `zensu_delivery_route_marker_state`,
  `zensu_inherited_route_marker_path`, `zensu_inherited_route_state`,
  `zensu_linked_session_marker_path`, `zensu_linked_session_state`,
  `zensu_default_delivery_route`, `zensu_delivery_route_resolve`, `zensu_delivery_route_field`,
  `zensu_delivery_route_status_line`, and the header census of what that file opens.
- The lineage pair: `hooks/lib/linked-session-v1.js` (`KINDS`, `REASONS`, `REPOSITORY`, `TURNS`,
  the six-field `renderVerdict` line the shell reads with one tab-split `read`) and
  `hooks/lib/zensu-linked-session.sh` (`zensu_linked_session_pending`, `zensu_linked_session_resolve`);
  the guarded `source` of the latter in both ask-hooks, which stays guarded because
  `test-autopilot-plan-delegate.sh` copies a subset of `hooks/lib` without it; the plan gate's one
  `RAW_SESSION_ID` read in its Autopilot branch, which its lineage call reuses; the
  `canonicalDirectory` export of `hooks/lib/claude-hook-session-v1.js`, which the resolver applies
  to `CLAUDE_PLUGIN_DATA` before `privateRecordsDirectory`; `SESSION_MARKERS` in
  `hooks/lib/session-reanchor-v1.js`, which moves `inherited-route` and then `linked-session` with
  the anchor and holds `linked-session` back when `inherited-route` did not move; `storeCandidates`
  in the resolver and `ccdStoreCandidates` in `skills/session-trail/scripts/trail.mjs`, which apply
  one `ZENSU_CCD_STORE` rule, so a change to either side's override moves both, together with
  `.claude/rules/session-lineage-ledger.md`, which states that rule for session-trail;
  `ZENSU_LINKED_BRIEF_LEAD` and the `ZENSU_DIRECTIVE_LEAD` name in `zensu-directive.sh`; the
  closed spelling list in the doctor probe of `zensu-doctor.sh` and the two source regexes in
  `zensu-doctor-report.js`, which accept `inherited from parent session`.
- `zensu-directive.sh`: `zensu_delivery_route_record_command`,
  `ZENSU_DELIVERY_ROUTE_SKILL_FALLBACK`, `zensu_directive_substitute`,
  `zensu_delivery_route_substitute`, its header naming the two substitution conventions, and the
  `source` line in each of the three hooks that use it (and in the two test fixtures that copy a
  subset of `hooks/lib`: `test-session-start-banner.sh` and `test-autopilot-plan-delegate.sh`).
  The library loads `zensu-msys-env.sh` from its own directory, so every fixture that copies it
  copies that file too; without it the substitution silently takes the hand-rolled MSYS append.
  It is the second loader of that file, beside `zensu-session.sh`, and its failure policy differs
  on purpose: it records whether the load worked and falls back, where `zensu-session.sh`
  installs a stub that refuses. `R9h` in `tests/structure/test-delivery-route.sh` grades both
  branches.
- The twin prologue in `zensu-delivery-route.sh` (the third copy, for the reason the first copy
  gives), and `hooks/lib/zensu-marker-write.sh`, the one write sequence it and
  `zensu-tdd-mode.sh` source.
- Both heredocs of BOTH ask-hooks; the parity helper's `P1`/`P2` needle lists carry the new
  literals.
- The route-default block and the `_ZENSU_ROUTE_QUESTION_LIVE` guard in
  `hooks/session-start-banner.sh`, and the recap in both `hooks/session-start-primer.sh`
  heredocs.
- `skills/delivery-route/SKILL.md`, its `plugin.json` entry and the README row and counts;
  `config.example.json`; the `defaultDeliveryRoute` row and the hook rows in
  `docs/configuration.md`; the Layer 2 edge label in `docs/architecture.md` (the `D17` needle
  stays contiguous); the first `## When to Use` bullet of `skills/tdd/SKILL.md`; both interception paragraphs of
  `skills/gauntlet-loop/SKILL.md`.
- The doctor probe in `zensu-doctor.sh`, the two renderer rows and the shared literals in
  `zensu-doctor-report.js`, and their `skills/doctor/SKILL.md` bullets.
- `tests/structure/test-delivery-route.sh`, registered in `ciStructureTests`, in
  `tests/SUITE-OVERVIEW.md`, and in the `excluded` list of
  `tests/profiles/windows-native-structure.v1.json`: R9h's `MSYS2_ENV_CONV_EXCL` probe matches a
  native-Windows marker there, and `windows-ci-contract.test.js` fails for a marked suite that
  list does not name.
- `tests/structure/test-linked-session-route.sh`, registered in `ciStructureTests` and in
  `tests/SUITE-OVERVIEW.md`, drives both ask-hooks, the helper and the doctor against a fake
  desktop store, real git worktrees and real Session Control records, and counts resolver
  processes through a `node` shim on `PATH`. It skips on native Windows, where the store layout
  it builds is unverified, and carries no native-Windows marker, so
  `windows-native-structure.v1.json` does not list it. It has no `ci-shard-weights.v1.json`
  figure yet; take one from its first green CI run.
- `evals/plan-approval-hook/`: `route_recorded` in the runner grades `T2.9` on the marker the
  helper writes, through `zensu_delivery_route_marker_path` and
  `zensu_delivery_route_marker_state` rather than a copy of either, the expect script's
  `record_prompt_ok` keys on the helper's file name and its `--tdd` verb and its result arm on the
  helper's `delivery-route: tdd` line, and `route_fixture` pins `ask` on top of the effective
  config. `D38`-`D41` in `tests/structure/test-plan-approved-delegate.sh` grade the fixture, the
  guard, the `T2.9` grading and `strip_ansi`, because the eval never runs in CI.

## Version

`patch`, walked against `.claude/rules/runtime-lineage.md`: no context-record or workflow-state
schema field (the marker is a new file in `.zensu/state`, the same class as the tdd-mode
marker), no strict key set, no hook added, removed or renamed, no matcher changed, the config key
is read permissively, no attestation change, and both hooks still emit only `additionalContext`.
The linked-session inheritance is `patch` on the same walk: two new one-line files in
`.zensu/state`, read permissively, one new source spelling that only the model and the doctor
read, no config key, and the helper keeps its four verbs. An older runtime of the same lineage
ignores both files and asks, which is the fail-safe direction.

## Known bounds

- The marker is an ordinary file in the session-writable `.zensu/state`, so "only the user
  changes the route" is prose-controlled, exactly as for the tdd-mode marker. A `direct` marker
  removes the review chain for the session, as `autoTdd:false` already can from a committed file;
  only an explicit `/zensu:delivery-route --direct` writes one. No hook-emitted, user-visible
  notice fires when a marker decides `direct`; the model's status line is the per-dispatch notice.
- With any recorded or configured route the four-route question is not asked, so
  `/zensu:autopilot` and `/zensu:pilot` are reachable only by naming them in the approval message.
  Whether to ask anyway when the plan's own ranking would put Autopilot or Pilot first is an open
  product decision.
- The project overlay wins per key, so a committed `direct` overrides a user's global `tdd` for
  every clone — the exposure a committed `autoTdd:false` already has. The banner is silent on
  `resume|compact`, so a resumed session sees the default only in the directive field and the
  doctor row.
- The RECORD step is a model instruction and a Bash call the user may be asked to allow: a model
  that skips it, or a user who declines the prompt, costs one repeated question, never a wrong
  route. Recording from the user's own click in a hook would remove the prompt and is not
  implemented.
- A session that approves a plan carrying ANOTHER session's `<!-- zensu-autopilot:<run> -->`
  marker takes the standalone branch, because that run is invisible to its owner-scoped read
  (`.claude/rules/autopilot-run-scope.md`). A recorded `tdd`, an explicitly recorded `direct`, or
  a configured default then dispatches the plan without the four-route question: `tdd` meets the
  standalone `--tdd-begin` workspace fence, and `direct` meets none. Forcing `ask` whenever a foreign durable run exists
  would cancel the feature for every project with an Autopilot run in a sibling worktree, so it is
  not done. The scoped fix is the payload-evaluator verdict the retained exit-6
  `OWNER_SESSION_MISMATCH` arm waits for (`.claude/rules/autopilot-run-scope.md`): once the
  standalone path can tell that the plan's marker names a run this session does not own, the hook
  refuses that plan, or renders the field as `ask`, before the field can dispatch it. It is not
  implemented.
- An Autopilot planning approval that falls through to the standalone branch, because
  `skills/autopilot/SKILL.md` Phase 0.D ran `ExitPlanMode` before `--autopilot-begin`, meets a
  recorded or configured route like any other plan: the field sends the Autopilot spec to
  `/zensu:tdd` or implements it directly without the question, where an `ask` field re-asks it.
  The guard is running `--autopilot-begin` before `ExitPlanMode`. Phase 0.D states that order and
  this consequence, and `D16` in `tests/structure/test-autopilot-durable-skill.sh` pins both as
  text; nothing observes the order a model actually takes
  (`.claude/rules/plan-approval-delivery-route.md`).
- The `ZENSU DELIVERY ROUTE:` field is identified by a fixed literal with no per-turn binding,
  the class `.claude/rules/zen-mode-chain-anchor.md` records for its anchor. A planted
  `direct (session marker)` spelling competes for a decision that removes the review chain; the
  vocabulary bounds the worst outcome to a skipped question resolving to `direct`, never to an
  outward-facing route. A per-turn nonce in the field name is the fix and is not implemented.
- A NUL byte inside the marker is translated to \001 in the reader's one open, so it counts toward
  the 512-byte ceiling and fails the whole-line match; R7b2 pins both the NUL-bearing body and a
  NUL-padded oversized file. The translation costs one `tr` child per read.
- The shared reader tests `[ -f ]` and then opens the marker through a plain redirect, so a FIFO
  swapped into that window blocks the UserPromptSubmit hook. The closing form is a node open with
  O_NONBLOCK, a spawn on every prompt, and is not taken.
- The doctor's Config row judges `configFiles()`, built from the ambient `CLAUDE_PROJECT_DIR`,
  while the Session-state row reads the recorded root; where the two roots differ, one report
  can carry a `⚠️ config:` row beside a `✅ delivery route:` row. The flag qualification of the
  Session-state row reads the same `configFiles()` pass.
- The `CLAUDE_PLUGIN_DATA=… bash …` command for `zensu-log.sh` is rendered by five hooks from
  their own copies (the primer, the pre-edit, post-review and Stop hooks, and the durable
  plan-gate branch), and their policies for an unusable data root differ: the primer stays
  silent, the durable plan-gate branch renders the command unconditionally.
  `zensu_delivery_route_record_command` renders only the delivery-route helper's command, and
  its policy is the skill-sentence fallback. One renderer for all of them is a separate change.
- Every prompt without an active chain pays up to two further `node` spawns in the reminder:
  `zensu_default_delivery_route` when the marker does not decide, and the substitution on every
  emission. Unmeasured, on a hook registered without a `timeout`.
- Windows is unverified for the new suite: it runs only in the weekly Windows Safety structure
  shard, with no blocking PR-shard entry by design.
- `/zensu:delivery-route` cannot be exercised live from a `--plugin-dir` checkout in a session
  bound to the installed plugin, because the sibling-root rule refuses the bind; its behavioural
  coverage is the suite's own Session Control fixtures, as for `/zensu:tdd-mode`.
- Two write primitives serve the three mode markers. `hooks/lib/zensu-zen-mode.sh` opens a fresh
  temp inode with `O_EXCL` in a node child, writes through that one descriptor, fsyncs and
  renames; `zensu_write_session_marker` re-opens its `mktemp` leaf through a plain redirect that
  the `-L` refusal only narrows. The difference is historical: this change moved the tdd-mode
  sequence into a shared library, not onto zen-mode's primitive. Unifying all three is a separate
  change, because R8f-R8j and T9g-T9k drive the shell sequence through PATH shims for `mktemp` and
  `mv`, R8k pins its shape, and all of them would be re-authored with it.
- The desktop record format is private and unversioned; the resolver was written against Claude
  Desktop 2.42304.0 on macOS. Drift reads as `none` or `unresolved`, which is the ladder without
  the inherited rank, never a wrong route. Windows and Linux are unverified: `storeCandidates`
  takes `APPDATA`/`LOCALAPPDATA` and `XDG_CONFIG_HOME`/`~/.config`, inferred from
  `ccdStoreCandidates` in `skills/session-trail/scripts/trail.mjs`, and the three variables were
  observed on macOS only. `ccdStoreCandidates` probes every platform's candidates on every host
  and resolves a relative `ZENSU_CCD_STORE` against its working directory, while `storeCandidates`
  takes only the platform's own and refuses a relative override; both name the same store wherever
  the desktop app writes one.
- A `.zensu/state` that passes the writable test and still refuses the write, on a full disk for
  example, leaves the answer uncached, so the module starts again on the next prompt. The test
  covers the read-only and the foreign-owned directory, the common cases.
- The desktop records and the parent's markers are ordinary user-writable files. A forged lineage
  can add the workflow, because only `tdd` is inherited, or drop the brief note, which is the
  behavior from before inheritance.
- A brief that is a bare slash command is skipped by the reminder, like every bare slash command,
  so the lineage resolves on the next typed prompt. That prompt carries no brief note once the slash
  command's turn completed and raised `completedTurns`; after a turn that ended in an error, the
  user's own next prompt still carries it, and for that one request a route preference the user
  typed decides nothing.
- With `hooks.tddReminder=false` no brief note appears; the plan gate still resolves the
  inheritance. Forks the user starts (the desktop's fork action, `--fork-session`) carry no
  `spawnedFrom` and inherit nothing; their lineage source is different and is a follow-up.
- The one resolution is a cross-session read: two desktop records, one Session Control record, up
  to two markers of another session, and `git rev-parse` in both roots. Measured on 2026-10-18:
  p95 26 ms in-process, and p95 174 ms through the CLI at a load average of 27, where a bare `node`
  start alone took p50 81 ms. Later prompts read one marker in bash and start no process.
- The parent is looked up under its current `cliSessionId` only. A parent whose record lists
  `priorCliSessionIds` and whose marker was written under one of those earlier ids passes nothing
  on.
- The brief is recognized through `completedTurns` in the own desktop record, a private field. A
  first turn that ended in an error leaves it absent, so a re-resolution after such a turn still adds
  the note; a desktop build that never writes it makes every re-resolution `first`, which is the
  behavior from before the check; and the field must be on disk before the next prompt's hook reads
  it, which the desktop's save after each result makes likely but which was not observed live.
- A linked session that is already running when the release carrying this arrives resolves its
  lineage on its first prompt under the new runtime. It gets no brief note, because its
  `completedTurns` is set, but it can start inheriting `tdd` mid-session, which the field discloses.
- A new CLI session id under the same desktop session resolves again under the new key. It gets no
  note, but it inherits from the parent's CURRENT markers rather than the snapshot the old key took,
  and a desktop that has not yet written the new `cliSessionId` answers `cli-session-mismatch`, a
  final `none`. None of the 525 linked records on this machine carried `priorCliSessionIds` on
  2026-10-18.
