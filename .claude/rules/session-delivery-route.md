---
paths:
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-directive.sh"
  - "hooks/lib/zensu-delivery-route.sh"
  - "hooks/lib/zensu-tdd-mode.sh"
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
answer is the workflow or implementing directly, and never asked when the project configures a
default. An autopilot or pilot answer is never remembered, so the question comes back after it.
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
3. `hooks.defaultDeliveryRoute` ∈ `tdd | direct | ask`;
4. ask.

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
the user changes it" injection rule); and the model, immediately after the user answers the
question with the workflow or with implementing directly — the RECORD sentence in both
directives tells it to run the rendered helper command before dispatching, and names that one
Bash call as coming BEFORE the "next tool call" the dispatch arms name, so the two orders cannot
be read as a conflict. The outward-facing answers and a preference taken from the approval or
request text record nothing. Because the answer outlives the question, the question says so: the
reminder's question and the descriptions of the plan question's workflow and direct options state
that the answer is remembered for the rest of the session and that `/zensu:delivery-route`
changes it. The option LABELS are unchanged, because `evals/plan-approval-hook` selects by label.

**One marker, two questions — the asymmetry is decided, not accidental.** The reminder's yes/no
and the plan gate's four-route question write the same marker, so a "No" to the reminder also
answers the four-route question for the rest of the session, and `/zensu:autopilot` and
`/zensu:pilot` are then reachable only by naming them in the approval message or after
`--auto`. Recording provenance, or keeping a separate record per question, was rejected: either
splits the one ladder the two hooks share, and treating a foreign record as a mere recommendation
would undo the (S) clause's "do NOT ask". The skill states the sharing in its own text.

Both marker writers — this helper and `hooks/lib/zensu-tdd-mode.sh` — run the same write
sequence: the shared symlink guard before the write and again before the rename (the second
call is the TOCTOU defense), an O_EXCL `mktemp` temp leaf with an `-L` refusal before the
redirect, a non-regular check, the rename, and a regular-file post-condition after it, because a
directory swapped in after the check makes `mv -f` succeed with nothing recorded. The
`-L` test narrows the temp-leaf window and does not close it; the closing O_NOFOLLOW open costs a
node spawn on every write and is not taken. The cleanup trap is EXIT-only and INT, TERM and HUP
only exit (130, 143, 129): a cleanup handler on the signals themselves returned into the write,
which then resumed and could re-create the temp leaf through a plain redirect without O_EXCL.
R8f/R8g/R8h and T9g/T9h/T9i drive the temp-leaf refusal and both halves of the post-condition
(`! -f` and `-L`) through PATH shims for `mktemp` and `mv`; R8i and T9j send INT, TERM and HUP
through another `mv` shim and require the helper to end with 130, 143 and 129 and no success line.

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
the directive is never routed to silence; the primer emits nothing, as before.

## Disclosure, five surfaces

The directive field, the status line the model opens with (`Executing via /zensu:tdd (route:
session marker)`), the SessionStart banner line for a configured default, the `--status` verb,
and two `/zensu:doctor` rows.

- **Banner.** The disclosure sits ABOVE the `sessionBanner` gate for the reason the
  `autoTdd:false` line sits there, and it withholds the route-question promise. It reads the key
  under the root the binder's `resolveFreshHookProject` answers, through the same call and the
  same host-path conversions as `hooks/session-start-autopilot-resume.sh` — an existing record's
  root on a retry or a `clear`, else the canonical `CLAUDE_PROJECT_DIR`. Each copy names the
  other. The mutable payload `cwd` is never read; the binder's own rule says it is never a project
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
- **One wording, two carriers.** The three switched-off-half literals exist in the banner and in
  the doctor renderer. R14e extracts them from both files and requires equality.

Nothing is ledgered: a recorded route is a MODE choice like the tdd-mode marker, a config key is
standing configuration, and no `ZENSU_*=off` spelling exists for it.

## Coupled sites

- `zensu-config.sh`: `zensu_delivery_route_marker_path`, `zensu_delivery_route_marker_state`,
  `zensu_default_delivery_route`, `zensu_delivery_route_resolve`, `zensu_delivery_route_field`,
  `zensu_delivery_route_status_line`, and the header census of what that file opens.
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
  gives) and the write sequence it shares with `zensu-tdd-mode.sh`.
- Both heredocs of BOTH ask-hooks; the parity helper's `P1`/`P2` needle lists carry the new
  literals.
- The route-default block and the `_ZENSU_ROUTE_QUESTION_LIVE` guard in
  `hooks/session-start-banner.sh`, and the recap in both `hooks/session-start-primer.sh`
  heredocs.
- `skills/delivery-route/SKILL.md`, its `plugin.json` entry and the README row and counts;
  `config.example.json`; the `defaultDeliveryRoute` row and the hook rows in
  `docs/configuration.md`; the Layer 2 edge label in `docs/architecture.md` (the `D17` needle
  stays contiguous); the first `## When to Use` bullet of `skills/tdd/SKILL.md` (edited INSIDE
  its line — the file sits at its line cap); both interception paragraphs of
  `skills/gauntlet-loop/SKILL.md`.
- The doctor probe in `zensu-doctor.sh`, the two renderer rows and the shared literals in
  `zensu-doctor-report.js`, and their `skills/doctor/SKILL.md` bullets.
- `tests/structure/test-delivery-route.sh`, registered in `ciStructureTests`, in
  `tests/SUITE-OVERVIEW.md`, and in the `excluded` list of
  `tests/profiles/windows-native-structure.v1.json`: R9h's `MSYS2_ENV_CONV_EXCL` probe matches a
  native-Windows marker there, and `windows-ci-contract.test.js` fails for a marked suite that
  list does not name.
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

## Known bounds

- The marker is an ordinary file in the session-writable `.zensu/state`, so "only the user
  changes the route" is prose-controlled, exactly as for the tdd-mode marker. A `direct` marker
  removes the review chain for the session, as `autoTdd:false` already can from a committed file.
- The project overlay wins per key, so a committed `direct` overrides a user's global `tdd` for
  every clone — the exposure a committed `autoTdd:false` already has. The banner is silent on
  `resume|compact`, so a resumed session sees the default only in the directive field and the
  doctor row.
- The RECORD step is a model instruction: a model that skips it costs one repeated question,
  never a wrong route.
- A session that approves a plan carrying ANOTHER session's `<!-- zensu-autopilot:<run> -->`
  marker takes the standalone branch, because that run is invisible to its owner-scoped read
  (`.claude/rules/autopilot-run-scope.md`). A recorded or configured `tdd` or `direct` then
  dispatches the plan without the four-route question: `tdd` meets the standalone `--tdd-begin`
  workspace fence, and `direct` meets none. Forcing `ask` whenever a foreign durable run exists
  would cancel the feature for every project with an Autopilot run in a sibling worktree, so it is
  not done. The scoped fix is the payload-evaluator verdict the retained exit-6
  `OWNER_SESSION_MISMATCH` arm waits for (`.claude/rules/autopilot-run-scope.md`): once the
  standalone path can tell that the plan's marker names a run this session does not own, the hook
  refuses that plan, or renders the field as `ask`, before the field can dispatch it. It is not
  implemented.
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
