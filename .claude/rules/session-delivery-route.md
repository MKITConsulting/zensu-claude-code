---
paths:
  - "hooks/lib/zensu-config.sh"
  - "hooks/lib/zensu-directive.sh"
  - "hooks/lib/zensu-delivery-route.sh"
  - "hooks/lib/zensu-tdd-mode.sh"
  - "hooks/lib/zensu-marker-write.sh"
  - "hooks/lib/linked-session-v1.js"
  - "hooks/lib/desktop-store-read-v1.js"
  - "hooks/lib/zensu-linked-session.sh"
  - "hooks/lib/zensu-prompt-deadline.sh"
  - "hooks/lib/zensu-doctor.sh"
  - "hooks/lib/zensu-doctor-report.js"
  - "hooks/session-start-banner.sh"
  - "hooks/session-start-primer.sh"
  - "hooks/plan-approved-delegate.sh"
  - "hooks/user-prompt-tdd-reminder.sh"
  - "skills/delivery-route/**"
  - "skills/doctor/SKILL.md"
  - "skills/doctor/references/linked-session.md"
  - "tests/structure/test-delivery-route.sh"
  - "tests/structure/test-linked-session-route.sh"
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
The mechanism is a session marker plus a config key; the question itself is the one
`.claude/rules/plan-approval-delivery-route.md` describes. The measured
reason: across this machine's transcripts from 12 June to 20 September 2026 the question was
asked 835 times in 539 sessions, and a session marker plus a configured `build` default would have
removed 488 of the 678 decisive answers. The only other switch, `autoTdd:false`, removes the
workflow together with the question.

## The ladder has one owner

`hooks/lib/zensu-config.sh` owns the whole ladder:

1. an explicit preference in the user's OWN text — fast-path (B) of the plan directive, the
   reminder's negation-then-affirmation arms — judged by the model and never recorded; an
   affirmation asking for TDD also runs that one chain strict through exactly one
   `TDD-MODE: strict` line unless a vanilla `/zensu:tdd-mode` choice outranks it
   (`.claude/rules/tdd-mode-precedence.md`);
2. the session marker `<project>/.zensu/state/delivery-route-<session-key>.json`
   (`{"route":"build"|"direct"}`; `{"route":"auto"}` is a recorded release and falls through);
3. the inherited route `<project>/.zensu/state/inherited-route-<session-key>.json`
   (`{"route":"build"}` only), which a released own marker skips (§"Linked sessions inherit `build`");
4. `hooks.defaultDeliveryRoute` ∈ `build | direct | ask`;
5. ask. Under `ask` the plan gate asks no question for a plan that names its own executor; it
   prints a notice instead (`.claude/rules/plan-approval-delivery-route.md`).

`zensu_delivery_route_resolve <root> <key>` answers `route<TAB>source`,
`zensu_delivery_route_field` renders the ONE spelling both directives and the doctor carry, and
`zensu_delivery_route_status_line` renders the `--status` line from the resolver's answer plus
the one fact the resolver drops (a RELEASED marker), so the ladder ORDER exists once.
`_zensu_marker_one_line_value` is the bounded reader of every session marker `zensu-config.sh`
owns — tdd-mode, delivery-route, inherited-route, linked-session and full-suite: one parse, and
each reader maps it onto its own vocabulary. The zen-mode marker keeps a reader and a writer of its
own; the write-primitive bullet under §"Known bounds" names both writers.

**All three mechanical ranks are read under the ONE root the caller hands the resolver.** Both
markers live under it, and the config overlay is read from it through
`zensu_default_delivery_route <root>` rather than from the ambient `CLAUDE_PROJECT_DIR`. No
caller pins `CLAUDE_PROJECT_DIR`; the two hooks, the helper's `--status` and the doctor probe
all pass the RECORDED project root, so they cannot pair one tree's markers with another tree's
config. An empty root answers `ask`: a hook whose `zensu_resolve_project_dir` failed never lets
the global config alone pick a route. `autoTdd`, `tddReminder` and `tddImplementation` in the
same hooks stay harness-anchored on purpose; moving them is its own change with its own pins
(D26 and siblings). R11b, R11c and R11d pin the two-root cases.

## The vocabulary bound is the safety property

The vocabulary is `build | direct` and nothing wider. `/zensu:autopilot` pushes a branch and opens
a pull request; `/zensu:pilot` commits, opens a pull request and mutates tracked feature state.
A committed `.zensu/config.json` must never pre-select either for every clone, and a marker must
never make a later approval take an outward-facing step the user did not choose for that plan.
The helper `hooks/lib/zensu-delivery-route.sh` refuses every verb except
`--build | --direct | --auto | --status`, the config reader answers `ask` for any other value, and
clause (C)'s bar on the two routes in a headless run is byte-identical: a decided route replaces
only the DEFAULT that (C) names. The `D13` slices in `tests/structure/test-plan-approved-delegate.sh`
hold that; this feature's directive text sits outside the (B) and (C) slices.

## Two writers

The user, through `/zensu:delivery-route` (the twin of `/zensu:tdd-mode`, with the same "only
the user changes it" injection rule, carried in the skill's description as well as its body);
and the model, immediately after the user answers the question with the Zensu workflow — the
RECORD sentence in both directives tells it to run the rendered helper command with `--build`
before dispatching, and names that one Bash call as coming BEFORE the "next tool call" the
workflow arm names, so the two orders cannot be read as a conflict. If the user declines that
call's permission prompt, the model says in one line that nothing was recorded and that the
question will come back, then dispatches. A direct answer, the outward-facing answers and a
preference taken from the approval or request text record nothing, and both directives tell the
model never to record `--direct` itself. The default for a refused question or a
`ZENSU HUMAN PRESENT:` field reading `no` runs the workflow and records nothing in both
directives, and the plan gate's (C) clause in both heredocs, the reminder's two full texts and its
ask short line say so: no person chose the route, and a run told only to skip the question can
borrow the Yes arm and record `build`. The question says what outlives it: the plan question's
workflow option and the reminder's Yes state that the answer is remembered for the rest of the
session, the other question's requests included unless that question is switched off, through
one Bash call the user may be asked to allow, the direct option and the No state
that they decide only that plan or request, and `/zensu:delivery-route` changes the route. Those
statements sit in the option descriptions, never in the LABELS, because
`evals/plan-approval-hook` selects by label.

**Only the fail-safe answer is recorded automatically.** The reminder asks per request and the
plan gate per plan, but both read one marker. A recorded `direct` would let one quick "No" to the
reminder skip the review chain AND the four-route question for a later, possibly large, approved
plan, with only the model's status line as notice. A recorded `build` adds the review chain rather
than removing it. So the model records only `build`, and `direct` becomes session-wide only through
the user's explicit `/zensu:delivery-route --direct` or `hooks.defaultDeliveryRoute`. Recording
provenance, or keeping a separate record per question, was rejected: either splits the one ladder
the two hooks share, and treating a foreign record as a mere recommendation would undo the (S)
clause's "do NOT ask". The skill states the sharing in its own text.

Every writer of a marker `zensu-config.sh` owns — this helper, `hooks/lib/zensu-tdd-mode.sh`,
`hooks/lib/zensu-full-suite.sh` and `hooks/lib/zensu-linked-session.sh` — writes through ONE
sequence, `zensu_write_session_marker` in `hooks/lib/zensu-marker-write.sh`, handed the helper's
own script name so each keeps its message prefix. The three command helpers source it right after
the verb check, and a failed load exits 2 with a cannot-load refusal before anything binds (R8l
drives this helper and `zensu-tdd-mode.sh`); `zensu-linked-session.sh` is a library the ask-hooks
source, and it loads the writer from its own directory unless the function is already defined.
The sequence is:
the shared symlink guard before the write and again before the rename (the second
call is the TOCTOU defense), an O_EXCL `mktemp` temp leaf with an `-L` refusal before the
redirect, a non-regular check, the rename, and a regular-file post-condition after it, because a
directory swapped in after the check makes `mv -f` succeed with nothing recorded. The
`-L` test narrows the temp-leaf window and does not close it; the closing O_NOFOLLOW open costs a
node spawn on every write and is not taken. The cleanup trap is EXIT-only and INT, TERM and HUP
only exit (130, 143, 129): a cleanup handler on the signals themselves returns into the write,
which then resumes and can re-create the temp leaf through a plain redirect without O_EXCL.
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
link target empty and leave no temp. R8k collects every shell file under `hooks/` that calls
`zensu_write_session_marker` with a script name, requires the four helpers named above among
them, and requires each to source the library, to keep no `mktemp` or `mv -f` of its own and to
redirect into no path of its own. It also reads each marker-path function of `zensu-config.sh`
together with the leaf template in its body, fails when a definition or a template is spelled in
a form it cannot read, fails for any other shell file under `hooks/` that calls one of those
functions without calling the writer, and fails for any other file under `hooks/`, whatever its
type, that spells a leaf itself: a derived stem followed by `-` and then a character that is not
a letter or digit, or the end of the line, which covers a shell variable, a JavaScript template
literal, a concatenation with either quote or a backtick and a `printf` format. Only whole comment
lines are skipped, `#` lines in shell files and `//` lines in JavaScript and TypeScript files; a
block comment counts as code, so code behind a closed `/* … */` is read. Editor leftovers
(`*.orig`, `*.rej`, `*~`, `.*.sw?`) are not read. A module that names something other than a
marker with a stem followed by such a character takes another spelling, as `full-suite-clone-v1`
does. L2 in `test-linked-session-route.sh` checks only that the two linked-session templates live
in `zensu-config.sh`. R8k2 plants each of these bypasses in a scratch tree, in shell, JavaScript,
module, CommonJS, TypeScript and JSON files, and requires R8k's reason for it. A marker path built
another way, such as a path joined from the bare stem in node, or written by another tool such as
`tee`, still escapes it.

## Linked sessions inherit `build`

A session another Claude Desktop session started (`start_session`, fresh or forked context) has its
own CLI session id and key, so the parent's marker does not reach it: over 424 linked sessions
measured on 2026-10-18, none opened with a decided route, the 6 whose parent had recorded the workflow route
included. Its first prompt is the brief the parent wrote, and the reminder answers it as a typed
prompt (a fresh brief classifies as `session-brief`, which the reminder treats as typed), so
without the brief note a route named in a brief acts as the user's own preference. The measurements and decisions are in
`docs/superpowers/specs/2026-10-18-linked-session-route-design.md`.

**Lineage comes from the desktop's own records, located through the hook environment.**
`hooks/lib/linked-session-v1.js` reads `CLAUDE_CODE_HOST_SESSION_ID`, `CLAUDE_CODE_ACCOUNT_UUID` and
`CLAUDE_CODE_ORGANIZATION_UUID` (a `UserPromptSubmit` hook run by the desktop's own Claude Code
2.1.299 binary saw all three), looks for `<store>/<account>/<org>/<host id>.json` in every store
candidate and follows `spawnedFrom.sessionId` to the parent's record in the directory that holds
the own record. The candidates are every store `ZENSU_CCD_EXTRA_STORES` names, split by the
platform's list separator (`;` on Windows, `:` elsewhere), each entry trimmed, MSYS-mapped and
resolved, which drops a trailing separator; then
the platform's default stores; then, on macOS only, every Zensu Session Hub profile store,
`~/Library/Application Support/Zensu Session Hub/Claude-Profile/<uuid>/claude-code-sessions`,
whose folder name is a canonical lowercase UUID, in sorted order; each spelling once. A set
`ZENSU_CCD_STORE`, trimmed, MSYS-mapped and resolved, is the only store candidate, with no
fallback behind it. Those are the rules of `ccdStoreCandidates` in `skills/session-trail/scripts/trail.mjs`, so a
store the user pointed session-trail at is a store this module reads; a relative value in either
variable names no store here, because a hook's working directory is not the user's. Every
candidate whose store, account and organization directories pass the binding checks that follow
is searched, and a real organization directory that two spellings reach is searched once. The
session answers `none` (`no-session-store`) when no candidate passes, `unresolved`
(`own-record-missing`) when none holds an entry under the own record's name, and `none`
(`own-record-ambiguous`) when two do, reading neither. Any entry under that name counts, a
refused one included, while session-trail reads neither copy of a session id only when two
stores hold records it accepts. Those two miss answers, `no-session-store` and
`own-record-missing`, come only from that search, so each one means that
`CLAUDE_CODE_HOST_SESSION_ID` is set and no candidate store holds the own record: an own
record the search saw and that is gone when the read opens it answers `unresolved`
(`own-record-unreadable`), as one that changes while it is read does. One search,
`searchStores`, serves the hooks and the doctor: `resolveLinkedSession` with `detail: true`
also returns every candidate store in candidate order (`stores`: the store, its source
`override`, `named`, `default` or `hub-profile`, and its state `no-folder`, `refused` with the
cause `ownedDirectoryRefusal` names, `same-folder` with the store it repeats, `no-record` or
`holds-record`), the store that held the own record (`ownStore`) and the parent's desktop id
(`parentSession`), while without it the verdict keeps its six fields and the line the shell
reads is the same. Binding checks: the shape of
each id; the store, account and organization directories real directories; each record a regular
file opened without following a link and without blocking, at most 8 MiB, a read that keeps
answering would-block retried 16 times 1 ms apart and then read as unreadable; off Windows, those
three directories and every record the module reads owned by the hook's own uid with no group or
other write bit (`writableOnlyByCaller`, a record judged on its `lstat` and again on the opened
descriptor), the rule and the bounded reader both living in `hooks/lib/desktop-store-read-v1.js`,
which session-trail applies to its own store reads too; the own record's `sessionId` equal to the host
id; its `cliSessionId`, when present, equal to the payload's `session_id`; a parent id other than
the own one. A directory that fails the owner and mode check skips its store candidate, so the
session answers `none` (`no-session-store`) when no other candidate passes; an own record that
fails answers `none` (`own-record-refused`), a parent record `linked` without a parent root
(`parent-record-unavailable`), and the parent's Session Control record `linked` without a parent
root (`parent-context-unavailable`). The check is the rule of `privateRecordsDirectory` with
`0o022` for its `0o077`, because the store directory measured 0755: on 2026-10-31 on macOS,
`claude-code-sessions` 0755, the account directories 0700 (nine) or 0755 (one), the organization
directories 0700 (all 39) and the records 0600 (all 4058), each owned by the user. A group write
bit is refused even where the group holds the user alone, as under the umask 002 of a
user-private-group setup; such a session loses the inheritance and the brief note. The check
never judges the parent's project root, whose
`realDirectory` call passes `anyOwnerOrMode`: `realDirectory` has no default policy and throws a
`TypeError` for a call that names none. The parent's
project root comes from the parent's Session Control record (`sessionKey`
of the parent's `cliSessionId`, read through `privateRecordsDirectory` after `CLAUDE_PLUGIN_DATA` is
canonicalized by the binder's own `canonicalDirectory`, as `resolveHookSession` does, at most 1 MiB,
schema and version equal to the core's `SCHEMA` and `SCHEMA_VERSION`, its `host` equal to `claude`,
the host the binder hands the core, and its `session_id_hash` equal to the core's `sessionIdHash` of
that `cliSessionId` as `readContext` requires, a canonical existing
directory), never from the desktop record's `cwd`, which
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
only while the lineage is pending. On `linked`, a same-repository parent whose own marker reads `build`, or whose own
marker is absent and whose inherited marker reads `build`, makes it write `inherited-route-<key>.json`
before the linked marker. The parent's markers are read through `zensu_delivery_route_marker_state`
and `zensu_inherited_route_state`, so each format keeps one reader. Every fault falls back to the
ladder without the inherited rank.

**Only `build` is inherited**, by the rule in §"Two writers": an inherited `build` adds the review chain
and never removes it. A parent's `direct`, a released parent marker and a configured default pass
nothing on. The answer is a snapshot: later changes in the parent do not move the child. The
inherited rank sits below the own marker and above the config key, because it is a choice the user
made for the same work. A released own marker (`--auto`) skips it, and `--direct` writes an own
marker that wins. `zensu-delivery-route.sh` keeps its four verbs: only the hooks write the two new
files.

**A miss is visible in `/zensu:doctor`.** For ten days after the user's accounts moved into Zensu
Session Hub profiles, every linked session there answered a store miss and nothing showed it: the
field read `ask`, as for a session no other session started (the FR-007 census of 2026-11-24). So
the doctor renders a `linked session:` row for a bound session whose environment carries
`CLAUDE_CODE_HOST_SESSION_ID`; the Bash tool that runs the doctor carries the same three desktop
variables the hooks see. `linkedSessionRow` in `hooks/lib/zensu-doctor-report.js` runs
`resolveLinkedSession` live with `detail: true`, the doctor's `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_PLUGIN_DATA` and the recorded project root, so the row answers what the hooks would
answer now. A miss is a warning that names the reason token, every store searched with its state
(a Session Hub profile store by its folder name, a refused store by the folder that failed: the
store itself, its account folder or its organization folder, which the detail mode's `folder`
field names) and the remedy: the `ZENSU_CCD_EXTRA_STORES` remedy with `ZENSU_CCD_STORE` named as
the variable that replaces every other store, or, while `ZENSU_CCD_STORE` is in force (the detail
mode's `override`), that variable alone. With no store at all the row names the one cause that
holds, and every remedy says that a changed store variable helps only a lineage that is still
open when the change reaches the hooks. An ambiguous, refused, unreadable or mismatching own
record, a malformed parent, a parent record that is not readable beside the own one or names no
CLI session, an unread Session Control store and a repository comparison that could not be made
are warnings too; a resolved lineage, a session not started from another one and a parent whose
context or root is gone are green. Paths go through `foldPath`, except the parent's project root,
which the row wraps in a parenthetical of its own and therefore renders through
`parenthesizedPath`, which withholds a root that carries a closing parenthesis. The wrapper probes
`ZDOC_LINKED_SESSION` and `ZDOC_INHERITED_ROUTE` read the kept answer and the inherited-route
snapshot through `zensu_linked_session_state` and `zensu_inherited_route_state`, each marker's one
reader, so a same-repository row says whether the session inherited `build`, inherited nothing,
or has not settled its lineage yet. The row also takes `ZDOC_DELIVERY_ROUTE`, the field the
`delivery route:` row renders, because the snapshot decides the route only below the session's
own marker. The route follows the snapshot, never the live answer, so
every inheritance statement of the live answer speaks of a resolution made now
(`LINKED_NOTHING_NOW`), and the row names what the hooks kept that the live answer does not
explain: a kept `none` beside a lineage that resolves in the same repository is green and names
the route that decides instead once the field comes from the session marker or
`hooks.defaultDeliveryRoute`, and otherwise turns the row into a warning that names the `--build`
remedy unless a kept snapshot still applies or could not be read; a kept `none` beside another
live answer is named with the fact
that the session keeps it; a kept `linked` beside any answer but the same-repository resolution
is named with what the session inherited then (`build`, nothing, or a missing check); a snapshot
that reads `build` beside a kept answer that is not `linked` is a warning of its own while the
field reads `build (inherited from parent session)` or could not be read, and is named as set
aside by the session's own marker once the field reads anything else; and a kept `none` says the
session inherits nothing only while the snapshot reads `none` or is set aside. An unreadable own
record promises another look only while the hooks have not kept an answer, and a kept answer or
snapshot the probe could not read is a missing check. The row's operator account is
`skills/doctor/references/linked-session.md`.

**The brief note.** Both ask-hooks resolve the lineage: the reminder on a typed, slash-with-arguments
or CI-monitor prompt while no chain is active, and the plan gate on its standalone branch. A brief
that opens with the app's `Background (from the session that started this one):` line classifies as
`session-brief` (`.claude/rules/prompt-origin.md`), and the reminder treats it as typed here. The
resolver answers `fresh-linked` only on the run that wrote the linked marker from absent AND only
while the own desktop record shows no completed turn, and only the reminder then prefixes
`ZENSU_LINKED_BRIEF_LEAD` from `hooks/lib/zensu-directive.sh` to whichever shape it emits, through
the optional third argument of `zensu_delivery_route_substitute`. The marker alone cannot say that a
prompt is the brief: it is keyed by root and session key, so a patch update reaching a running
session, `--restore-root`, a re-anchor or a new CLI session id under the same desktop session all
find it absent on a prompt the user typed. The desktop's own `completedTurns`, which its result
handler raises after every successful turn and which is absent before the first, is the
session-wide fact; the module reads it as the sixth field of its line, `first` or `later`. A fork
the user starts in the desktop app carries `spawnedFrom.userFork: true`, and a fork in which the
user continues another linked session carries a `forkedFromSessionId` that names that session, not
its parent. Neither shows a completed turn, yet the first prompt of each is the user's own, so
`isUserFork` makes the module answer `fork` for both, which the wrapper treats like `later`: they
inherit `build` and never carry the note (spec D16, L73-L75, L77, L78). Only `userFork: true`
counts, or a fork source that matches the host session pattern and names neither the parent nor
the session itself. The lead asks for the route question only while the field reads `ask`
and the request changes executable code, the condition of the reminder's own clause (a) (L76). The lead is
added on the parsed JSON, never in a third heredoc, so it leaves the heredocs that `P1`, `P2` and
`R13` grade alone. A retry
that resolves `linked` answers `linked`, because a later prompt is the user's own. The plan gate adds
no sentence: its fast path (B) reads only the user's own approval message, and its heredocs sit close
to `D44`'s 9,000-character bound.

## The reminder's time budget

**The measured cause.** The FR-007 census of 2026-11-24 found 30 of 510 linked sessions whose first
prompt carried no route field, because the reminder hit the host's 30 s limit for a hook registered
without a `timeout` (the transcripts record `timeoutMs: 30000`). All 30 sit inside fan-out bursts,
13 on 2026-11-07 and 11 on 2026-11-20, and on every one the sibling prompt hooks were slow too:
zen-mode took 11 to 47 s and hit its own 20 s limit 7 times, worktree-keep hit its 10 s limit 15
times. The lineage read was not the cost. A linked first prompt ran 16 `node` children in series,
seven of them hashing the plugin runtime again (the bind and six project-root verifications), and
at a load average of 90 to 120 on 16 cores the hook took 9.1 to 31.7 s, the lineage resolver's own
process 1.6 to 2.9 s of it.

**Fewer processes.** The reminder memoizes the root verification
(`.claude/rules/stop-latency.md`, the memo's fourth caller), reads the payload's prompt and session
id in one `node` child, and takes the bound session key instead of a `session-key` child: 9
children on a linked first prompt, one verification. `L59` in
`tests/structure/test-linked-session-route.sh` holds at most nine and exactly one.

**A deadline for the whole hook.** `hooks/lib/zensu-prompt-deadline.sh` re-runs the reminder as a
worker in its own process group, with stdin, stdout and stderr in a private `mktemp -d` directory,
and a watchdog in a group of its own kills that group at the deadline: 20 s by default,
`ZENSU_PROMPT_DEADLINE_SECONDS` clamped to 10 to 20 s, under the registration's explicit `"timeout":
30` (`L65` holds the registration at least 10 s above the ceiling). The floor sits above the 6 s
lineage reserve, so a lowered value still leaves the lineage read time to run. The design follows
the Stop hook's supervisor and stays a copy of it (`.claude/rules/stop-latency.md` §"Deadline" says
why), with its residuals: on Git Bash the group kill is unverified, the supervisor itself still
needs the CPU to start, and a kill can land inside an adopting bind. A worker that finished is
forwarded as it wrote, and so is one the deadline met after it marked its output delivered: the
reminder calls `zensu_prompt_delivered` after each emission and before the prompt ledger, and the
supervisor then exits 0 whatever status the kill left. A worker killed before that leaves the
supervisor the `classified` file the worker writes once the prompt has passed every silent exit,
the active-chain check included, and the facts it recorded on the way through
`zensu_prompt_record`: the route field once read, and `lead` as `brief` once a linked session's
brief was recognized. The library knows no kind or fact name. The reminder's
`emit_deadline_fallback` reads the facts through `zensu_prompt_recorded`, screens the route against
the six spellings of the field, and prints:

- `prompt` with a recorded `build` or `direct` route: that route's decided line, built by the same
  `decided_line` the worker uses and headed as shortened, with the real field and no human-present
  field (`L62c`).
- `prompt` otherwise: a shortened ask reminder with the field `ask` and the human-present field,
  which also says the route was not read when none was recorded (`L62b`). It carries what every ask
  shape carries: the ranking clause with a person present and the workflow-first sentence without
  one, the sentence that this reminder never runs `/zensu:autopilot`, `TDD_STRICT_ASK`,
  `TDD_UNTRUSTED`, the preference rule and the yield sentence of `docs/precedence.md` (`R15b`
  counts four carriers). It names the workflow question without the record command, so nothing is
  recorded from it, and it marks no prompt ledger, so the next prompt still gets the full text.
  `L62` checks both against the full reminder of `L60`, which carries the command with `--build`
  and marks the ledger. It refuses the helper's name, the `__ZENSU_ROUTE_COMMAND__` placeholder,
  `--build`, and the skill sentence it reads from `zensu-directive.sh`, which that library renders
  in the command's place when the data root is unusable.
- either `prompt` shape after a recognized brief opens with `ZENSU_LINKED_BRIEF_LEAD`, which the
  fallback sources from `zensu-directive.sh` on that path alone (`L62d`).
- `ci` with a recorded route: the CI note with that field, the text the worker would have printed
  (`L63`).
- `ci` without one: the CI note with `ask` and a sentence that a code change in this event runs the
  Zensu workflow, because `ask` on a CI event otherwise means fix, commit and push without a route
  (`L63b`).
- any other kind, and no file: nothing at all, because the prompt may be one the reminder stays
  silent on, such as a task notification or a session with `tddReminder` off (`L64`).

An unread route reads `ask` because that is the answer the ladder already gives when the root
cannot be resolved: a hook that could not finish never lets a marker it did not read, or the config
alone, pick a route. `L66` to `L71` drive the library itself through a small driver: the fallback
with its facts and the facts it refuses, a kind it refuses, a worker that marked its output
delivered before the deadline, the pass-through of stdin, stdout, stderr and exit code with nothing
left behind, a supervisor killed by SIGKILL, and SIGTERM; `L72` and `L72b` run the real lineage
resolution inside such a worker, with a lineage budget that outlasts a 3 s deadline. A `sleep` shim
on the driver's `PATH` records each sleeper's PID and parent under its argument. The supervisor's
watchdog sleeps the deadline less the whole seconds already spent, so `L69` and `L71` look it up
within `PD_SLACK` seconds below the deadline, and fail unless that sleeper was recorded during the
run and is gone afterwards. The name screen spells its letters out instead of using bracket ranges,
because `/bin/bash` 3.2 collates `[a-z]` under a UTF-8 locale and accepts `B` there. `L66b` requires
both spelled-out classes and no bracket range in the function as bash parsed it, which fails on
every runner, and runs the screen under `en_US.UTF-8` with `globasciiranges` off over names that
include a slash, dots, the empty name and an accented letter after a valid first one; where ranges
still do not collate, its PASS text says that only the parse check could tell a range from a
spelled-out class.

**A budget for the lineage.** The worker hands `zensu_linked_session_resolve` the seconds left until
the deadline minus the 6 s reserve it passes to `zensu_prompt_lineage_budget` for the rest of its
run. The resolver then runs in its own process group under a watchdog inside the command
substitution; one the watchdog kills answers `deferred`,
writes no marker, and the field comes from the ordinary ladder in the full text (`L60`), so the
session's own marker and a configured default still decide it (`L60b`); the next prompt resolves
again (`L61`). A spent budget answers `deferred` without starting the resolver
(`L61b`). The plan gate passes no budget and resolves as before. The supervisor's group kill does
not reach the resolver or its watchdog, because each leads a process group of its own: a deadline
that stops the worker during a lineage read caches no answer, and leaves a hung resolver running
until its watchdog stops it at the lineage budget and then exits (`L72`). A resolver that answers
after the deadline exits on its own, while its watchdog, orphaned before the worker could stop it,
sleeps out the budget and then exits (`L72b`). Its last act is the kill it was started for, aimed at
a group that no longer exists: should the system reuse that process ID within those seconds, the
process or group now holding it gets the signal, a residual no check covers. The reserve places that budget before the deadline, and the watchdog
counts it from the resolver's start, so a resolver outlives the deadline only when the steps between
reading the budget and starting the resolver took longer than the reserve less one second, because
the worker reads the time spent from bash's whole-second `SECONDS`.

**Known gaps.** The host can stop the supervisor after the worker marked the prompt ledger and
before the supervisor forwarded the text, so a full text the model never received can count as
delivered; that takes a machine that cannot run the supervisor between the deadline and the host's
limit, and the short lines carry every obligation (`.claude/rules/prompt-ledger.md`). The bound
starts when bash starts: a machine that cannot schedule the supervisor within the host's 30 s still
loses the field. A worker stopped after the resolver wrote the linked marker and before the brief
was recorded loses the brief note for good, because the next prompt reads the marker; the reserve
leaves at least 6 s for that step. The other prompt hooks of a fan-out burst keep their own limits
and their own costs; the router and zen-mode bind and verify the same way and are the next
candidates.

## Placeholders, not interpolation

Each ask-hook keeps exactly TWO quoted `cat <<'JSON'` heredocs, because the parity helper in
`tests/structure/test-tdd-vanilla-mode.sh` refuses a third block. The values travel as
placeholders substituted on the PARSED JSON by `zensu_directive_substitute` in
`hooks/lib/zensu-directive.sh` (`hooks/session-start-primer.sh` for its log command, both
ask-hooks through `zensu_delivery_route_substitute`): the record command carries `printf %q`
backslashes that a shell substitution into the raw text cannot JSON-escape. That library holds
the record command and the skill fallback too, so `zensu-config.sh` keeps to reading config and
the session markers. It is one of TWO substitution conventions, and the second is deliberate:
`hooks/user-prompt-zen-mode.sh` fills `{{ZENSU_CHAIN_ANCHOR}}` by shell parameter expansion on
the raw body, with no process, because that value is a closed vocabulary that never needs JSON
escaping. Each hook that substitutes sources the directive library itself. The substitution is
one pass, so a value is never scanned for another placeholder. When node cannot substitute, the
delivery-route wrapper still emits valid JSON with the skill sentence in place of the command, so
the directive is never routed to silence, and it puts the brief lead right after the
`additionalContext` opener, in either spelling the hooks emit, so the note survives the fallback;
the primer emits nothing. The reminder's other
three shapes are `printf` literals through the same wrapper, never a third heredoc: the CI note, the
decided line it sends on every prompt while the field reads `build` or `direct`, and the short line it
sends on a later `ask` prompt of a context generation that already received the full text
(`.claude/rules/prompt-ledger.md`). The CI note and the decided line never carry the record command;
the short line does, through the same placeholder, so a Yes can be recorded even when the full text
is no longer in context.

## Disclosure, five surfaces

The directive field, the status line the model opens with (`Executing via /zensu:build (route:
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
  flag before it resolves the route, and a `build` session row then names the one half that still
  dispatches to `/zensu:build` rather than claiming every code change does (R18g). An unknown config value renders as written — a string once,
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
  `zensu_delivery_route_status_line`, and the header census of what that file opens. R8k reads
  each `zensu_*_marker_path()` definition at the start of its line and the
  `/.zensu/state/<stem>-$session_key.json` template in its body, so a marker written in another
  spelling fails R8k.
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
  in the resolver and `ccdStoreCandidates`, `namedStoreCandidates` and `hubProfileFolders` in
  `skills/session-trail/scripts/trail.mjs`, which apply one `ZENSU_CCD_STORE` rule, one
  `ZENSU_CCD_EXTRA_STORES` split, one Session Hub profile path and folder-name filter and one
  candidate order, so a change to either side's rule moves both, together with
  `.claude/rules/session-lineage-ledger.md` and `.claude/rules/session-trail-targeted-lookup.md`,
  which state those rules for session-trail; `L3o` in
  `tests/structure/test-linked-session-route.sh` fails when the two macOS candidate lists differ
  in one of its four layouts (named stores beside lower-case, upper-case and non-UUID profile
  folders, a padded `ZENSU_CCD_STORE` beside a named store, a blank one beside blank, padded and
  repeated named entries, a home without a profiles folder), so a difference outside them passes
  it, and a relative entry or another platform's default, where the two sides differ by design,
  is never compared; `taggedStoreCandidates`, which `storeCandidates` maps to its paths,
  `storeOverride`, the one reading of `ZENSU_CCD_STORE`, and `searchStores`, the one search the
  hook resolution and the detail mode share, which tags a failed store with the `STORE_FOLDERS`
  member that failed and reports whether the override decided the candidates (`L3q` holds the
  detail states and the candidate order, `L3r` the race answer and the unchanged hook line, and
  `L49`, `L50` and `L54` the `folder` and `override` fields through the row);
  the doctor row, `linkedSessionRow`, `linkedSessionText`, `linkedKeptClause`, `linkedStoreMiss`,
  `linkedSameRepository`, `linkedStoreList`, `linkedStoreState`, `linkedFolderSubject` and the
  `LINKED_*` texts in `hooks/lib/zensu-doctor-report.js`, which key on the resolver's exported
  `KINDS`, `REASONS`, `REPOSITORY`, `HOST_SESSION_RE`, `STORE_STATES`, `STORE_SOURCES` and
  `STORE_FOLDERS`, so a new reason, state or folder needs a row text (`L57` fails without one);
  `LINKED_REFUSAL_PREDICATE`, a hand copy of the causes `ownedDirectoryRefusal` returns, because
  `desktop-store-read-v1.js` exports no cause vocabulary and has a byte-identical copy in
  `plugins/session-hub/`, so an unknown cause renders as a check the row has no text for and `L54`
  renders every known one; the `ZDOC_LINKED_SESSION` and `ZDOC_INHERITED_ROUTE` probes in
  `hooks/lib/zensu-doctor.sh`, which join the probe guard that sources `zensu-config.sh` once; and
  `skills/doctor/references/linked-session.md` with its pointer in `skills/doctor/SKILL.md`,
  whose phrases `L58` holds against the rendered rows (`L48`-`L56` drive the arms and the real
  wrapper);
  `hooks/lib/desktop-store-read-v1.js`, the one owner of `writableOnlyByCaller`, `anyOwnerOrMode`,
  `realDirectory` with its required policy, `ownedRegularFile` and the bounded record reader, which
  the resolver and `trail.mjs` both load, so a change to the rule moves both readers, and
  `.claude/rules/session-trail-targeted-lookup.md` names session-trail's side; `L3j` and `L3k` in
  `test-linked-session-route.sh` fail when either reader defines a copy, as a function or as a
  `const`, `let` or `var` binding, or when a `realDirectory` call names a policy other than
  `writableOnlyByCaller` or `anyOwnerOrMode` or is spelled in a form the pin cannot read, and `L3l` when the
  reader stops reusing the scratch buffer session-trail passes or the resolver starts passing one;
  `isUserFork` in the resolver and `linkedKind` in `skills/session-trail/scripts/linked-sessions-v1.mjs`
  and its `plugins/session-hub/` copy, which apply one rule to the desktop's fork markers, a
  `spawnedFrom.userFork` of `true` or a `forkedFromSessionId` of the session pattern that names
  neither the parent nor the session itself, which `L3p` in `test-linked-session-route.sh` holds
  equal over one table of desktop records, so a change to either marker moves all three (PLM's
  frozen copy takes it as a fix, `.claude/rules/session-hub-companion.md`), and
  `.claude/rules/session-trail-linked-sessions.md` names session-trail's side and the Session Hub's
  `kind_of`, which still reads `user_fork` alone;
  `ZENSU_LINKED_BRIEF_LEAD` and the `ZENSU_DIRECTIVE_LEAD` name in `zensu-directive.sh`; the
  closed spelling list in the doctor probe of `zensu-doctor.sh` and the two source regexes in
  `zensu-doctor-report.js`, which accept `inherited from parent session`; and
  `LINKED_OWN_ROUTE_RE` and `LINKED_INHERITED_FIELD` in the same renderer, hand copies of the
  `zensu_delivery_route_field` vocabulary as `deliveryRouteRow`'s regexes are, which decide
  whether the linked row names the session's own route and whether a kept snapshot applies or is
  set aside, so a new field spelling moves every one of these copies.
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
  gives), and `hooks/lib/zensu-marker-write.sh`, the one write sequence every helper of a
  `zensu-config.sh` marker sources: it, `zensu-tdd-mode.sh`, `zensu-full-suite.sh` and
  `zensu-linked-session.sh`.
- Both heredocs of BOTH ask-hooks; the parity helper's `P1`/`P2` needle lists carry this
  feature's literals.
- The route-default block and the `_ZENSU_ROUTE_QUESTION_LIVE` guard in
  `hooks/session-start-banner.sh`, and the recap in both `hooks/session-start-primer.sh`
  heredocs.
- `skills/delivery-route/SKILL.md`, its `plugin.json` entry and the README row and counts;
  `config.example.json`; the `defaultDeliveryRoute` row and the hook rows in
  `docs/configuration.md`; the fork paragraph of `docs/session-control.md`, which names the delivery
  route as the one state a linked session or a user fork inherits; the Layer 2 edge label in `docs/architecture.md` (the `D17` needle
  stays contiguous); the first `## When to Use` bullet of `skills/build/SKILL.md`; both interception paragraphs of
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
  figure yet; take one from its first green CI run. Its budget block (`L59` to `L72b`) classifies
  every `node` child through a second shim by literals it shares with the code: the inline
  `core.readContext({ recordsDir, sessionId: key })` of `zensu_resolve_project_dir`, the
  resolver's file name, `ZENSU_DIRECTIVE_PLACEHOLDERS` of the substitution,
  `classifyPreToolPayload` of the principal check and `j.hooks.defaultDeliveryRoute` of
  `zensu_default_delivery_route`. Rewording one of them turns its check red. Every driver case but
  `L70` records its sleepers through a `sleep` shim keyed by the sleep argument, so a supervisor
  watchdog that stops starting `sleep` from `PATH`, or sleeps longer than the deadline or more than
  `PD_SLACK` seconds less, turns `L69` and `L71` red, and a lineage watchdog that stops sleeping the
  exact budget turns `L72` and `L72b` red. The hung-child cases wait for real deadlines; the
  hook-level fallback cases run side by side, and so do the two lineage cases, which wait about 12 s.
- The time budget: `hooks/lib/zensu-prompt-deadline.sh` (the clamp, `zensu_prompt_supervise`,
  the worker entry, `zensu_prompt_classified`, `zensu_prompt_record`, `zensu_prompt_recorded`,
  `zensu_prompt_delivered`, `zensu_prompt_lineage_budget`); the reminder's `CI_NOTE`, the `TDD_*`
  sentences and `decided_line` it defines above the supervise call, `emit_deadline_fallback` with
  its six field spellings, which `zensu_delivery_route_field` renders, the stubs it defines when the
  library does not load, and its three `zensu_prompt_delivered` calls; the optional budget and
  `_zensu_linked_session_answer` in `hooks/lib/zensu-linked-session.sh`, the third copy of the
  group watchdog (`.claude/rules/stop-latency.md`); and the reminder's `"timeout": 30` in
  `hooks/hooks.json`.
- `evals/plan-approval-hook/`: `route_recorded` in the runner grades `T2.9` on the marker the
  helper writes, through `zensu_delivery_route_marker_path` and
  `zensu_delivery_route_marker_state` rather than a copy of either, the expect script's
  `record_prompt_ok` keys on the helper's file name and its `--build` verb and its result arm on the
  helper's `delivery-route: build` line, and `route_fixture` pins `ask` on top of the effective
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
ignores both files and asks, which is the fail-safe direction. The resolver's owner and mode check
is `patch` as well: no kind, reason or field changes, and it only turns a resolution into an
existing `none`, `parent-record-unavailable` or `parent-context-unavailable` answer. Moving the check
into `hooks/lib/desktop-store-read-v1.js` changes none of its answers. Reading the named and Session
Hub profile stores is `patch` as well: no kind or field changes, the verdict line keeps its six
fields, and the one new reason, `own-record-ambiguous`, comes under the existing kind `none`; the
shell's tab-split `read` in `hooks/lib/zensu-linked-session.sh` discards the reason field, and no
reason value is matched outside the resolver and its suite. The visible miss is `patch` too: the
one remapped case moves between two reasons of the kind `unresolved`, so the shell writes the same
marker and retries as before; the detail fields, `folder` and `override` included, exist only on
a call that asks for them, and the new `STORE_FOLDERS` export is read only by the doctor row; the
doctor row is advisory and read-only; both wrapper probes read their marker through its one
reader; and the new reason text is matched only by the doctor row and its suite, which ship
together.
The reminder's time budget is `patch` on the same walk: no schema field, no strict key set, no hook
added, removed or renamed, no matcher changed (the registration gains a `timeout`, which is not its
matcher), the knob is an environment variable rather than a config key, `deferred` is a new answer
of an in-tree shell function that writes nothing, and the hook still emits only
`additionalContext`. An older runtime of the same lineage never reads the new library, and a marker
it finds absent after a deferral it resolves itself.
The `fork` turn and the code condition in the lead are `patch` as well: the turn is a
new value of the line's sixth field, which only `zensu-linked-session.sh` reads, comparing it with
`first`, so no kind, reason, field or marker changes, and the lead stays advisory
`additionalContext`.

## Known bounds

- The marker is an ordinary file in the session-writable `.zensu/state`, so "only the user
  changes the route" is prose-controlled, exactly as for the tdd-mode marker. A `direct` marker
  removes the review chain for the session, as `autoTdd:false` already can from a committed file;
  only an explicit `/zensu:delivery-route --direct` writes one. No hook-emitted, user-visible
  notice fires when a marker decides `direct`; the model's status line is the per-dispatch notice.
- With any recorded or configured route neither question is asked, so `/zensu:autopilot` and
  `/zensu:pilot` are reachable only by naming them in the approval message or invoking the skill.
  Invoking either skill stays possible under every field, because the reminder answers no slash
  command that invokes `/zensu:autopilot`, `/zensu:pilot` or `/zensu:work`, so its decided line
  never steers one elsewhere. While the field reads `ask` and the human-present field reads `yes`,
  the reminder's question offers `/zensu:autopilot` on a direct code request too, so a session that
  starts without a plan sees it before a Yes records `build`. Its rule that a request asking for
  Autopilot states no preference lives in the ask shapes only: the decided lines carry no Autopilot
  text, which `R13f` pins, so under a decided field a request that names Autopilot in prose meets
  the decided line's own action and no sentence about Autopilot. `docs/precedence.md` and the
  delivery-route skill scope the rule the same way.
  Whether to ask anyway when the plan's own ranking would put Autopilot or Pilot first is an open
  product decision.
- The project overlay wins per key, so a committed `direct` overrides a user's global `build` for
  every clone — the exposure a committed `autoTdd:false` already has. The banner is silent on
  `resume|compact`, so a resumed session sees the default only in the directive field and the
  doctor row.
- The RECORD step is a model instruction and a Bash call the user may be asked to allow: a model
  that skips it, or a user who declines the prompt, costs one repeated question, never a wrong
  route. Recording from the user's own click in a hook would remove the prompt and is not
  implemented.
- A session that approves a plan carrying ANOTHER session's `<!-- zensu-autopilot:<run> -->`
  marker takes the standalone branch, because that run is invisible to its owner-scoped read
  (`.claude/rules/autopilot-run-scope.md`). A recorded `build`, an explicitly recorded `direct`, or
  a configured default then dispatches the plan without the four-route question: `build` meets the
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
  `/zensu:build` or implements it directly without the question, where an `ask` field re-asks it.
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
  emission. Both now run inside the reminder's deadline (§"The reminder's time budget").
- Windows is unverified for `tests/structure/test-delivery-route.sh`: it runs only in the weekly Windows Safety structure
  shard, with no blocking PR-shard entry by design.
- `/zensu:delivery-route` cannot be exercised live from a `--plugin-dir` checkout in a session
  bound to the installed plugin, because the sibling-root rule refuses the bind; its behavioural
  coverage is the suite's own Session Control fixtures, as for `/zensu:tdd-mode`.
- Two write primitives serve the session markers. `hooks/lib/zensu-zen-mode.sh` opens a fresh
  temp inode with `O_EXCL` in a node child, writes through that one descriptor, fsyncs and
  renames, for the zen-mode marker alone; `zensu_write_session_marker` re-opens its `mktemp` leaf
  through a plain redirect that the `-L` refusal only narrows, for the five markers
  `zensu-config.sh` owns (tdd-mode, delivery-route, inherited-route, linked-session and
  full-suite). Unifying the two is a separate change, because R8f-R8j and T9g-T9k drive the shell sequence through PATH shims for `mktemp` and
  `mv`, R8k pins its shape, and all of them would be re-authored with it.
- The desktop record format is private and unversioned; the resolver was written against Claude
  Desktop 2.42304.0 on macOS. Drift reads as `none` or `unresolved`, which is the ladder without
  the inherited rank, never a wrong route. Windows and Linux are unverified: `storeCandidates`
  takes `APPDATA`/`LOCALAPPDATA` and `XDG_CONFIG_HOME`/`~/.config`, inferred from
  `ccdStoreCandidates` in `skills/session-trail/scripts/trail.mjs`, and the three variables were
  observed on macOS only. `ccdStoreCandidates` probes every platform's candidates on every host,
  the Session Hub profile path included, and resolves a relative `ZENSU_CCD_STORE` or
  `ZENSU_CCD_EXTRA_STORES` entry against its working directory, while `storeCandidates` takes only
  the platform's own defaults, probes the profile path on macOS only and refuses a relative value;
  both read the same stores wherever Claude Desktop writes into its default data folder, into a
  Session Hub profile on macOS or into a store an absolute `ZENSU_CCD_EXTRA_STORES` entry names
  (`.claude/rules/session-trail-targeted-lookup.md`). A linked session started in a Claude Desktop
  that runs on any other data folder of its own answers `unresolved` (`own-record-missing`) when
  another store holds the same account and organization folders and `none` (`no-session-store`)
  when none does, and inherits nothing; the doctor's `linked session:` row shows that miss with
  every store it searched. Naming that store in `ZENSU_CCD_EXTRA_STORES` helps only a
  lineage still open when the variable reaches the hook, because `linked-session-<key>.json` keeps
  a `none` at once and retries an `unresolved` once, on a later prompt, before keeping it as
  `none`; a session that has answered resolves its route as one without a parent does, from its own
  marker (`/zensu:delivery-route`) and then `hooks.defaultDeliveryRoute`, `ask` when unset. An
  own record two stores hold answers `none` (`own-record-ambiguous`) and inherits nothing, because
  which copy is the session's own cannot be told. That count takes every entry under the own
  record's name, a refused one included, where session-trail counts only the records it accepts,
  so a refused entry in a second store withholds the inherited route here while session-trail
  still reads the accepted record; the stricter count only withholds, the fail-safe direction.
- The doctor row resolves in the doctor's own environment, the Bash tool's, which carried the three
  desktop variables in a desktop session (measured on 2026-11-24 with the desktop-bundled CLI
  2.1.330). A `ZENSU_CCD_STORE` or `ZENSU_CCD_EXTRA_STORES` changed after the hooks answered makes
  the row search other stores than the hooks did; the cached-answer clause shows only that the two
  answers differ, not why. The row is withheld for an unbound session and for a doctor run outside
  the session, and it lists every store, so a machine with many Session Hub profiles gets a long
  warning. The structure suites unset the three variables (`L3s`); the evals under `evals/` that
  run an ask-hook do not, and the session-trail suites keep their own home-directory sandboxing.
- A `.zensu/state` that passes the writable test and still refuses the write, on a full disk for
  example, leaves the answer uncached, so the module starts again on the next prompt. The test
  covers the read-only and the foreign-owned directory, the common cases.
- The desktop records and the parent's markers are ordinary user-writable files. A forged lineage
  can add the workflow, because only `build` is inherited; drop the brief note, so a route named
  in the brief acts as the user's own preference; or mark a prompt the user typed as another session's brief,
  so a route preference in that one prompt decides nothing and the field answers. Under a field
  that reads `direct` (the own marker or `hooks.defaultDeliveryRoute`) that removes review: a
  request for the workflow typed into that prompt is implemented directly. The effect covers that
  one prompt, the brief note asks the model to name the route the prompt asked for, and an `ask`
  field asks the route question instead for a code change. Letting a request for the workflow count even in a brief
  would close it, at the price of letting a genuine brief add the workflow, so the brief decides
  nothing in either direction and this residual is accepted, for the accidental paths below as
  well: after a first turn that ended in an error, `completedTurns` is still absent, so the user's
  own next prompt is taken for the brief once more. Every path ends the same way: one prompt, a
  note that names the requested route, and, for a code change, the route question under an `ask`
  field. In the desktop
  store only a deliberate actor with the user's own write access forges these records, and the
  plugin guards against accidents, not against such an actor: off Windows the resolver refuses a
  store, account or organization directory and a record that another account owns or that grants
  group or other write, so a `ZENSU_CCD_STORE` naming a shared directory answers `none` instead of
  extending the residual to another account. The check reads the owner and the mode bits only: a
  directory or record another account can write through an access-control list still extends it,
  and on Windows, where neither is judged, so does any store another account can write. A fork the
  user starts or continues resolves with the turn `fork`, so no prompt typed there is taken for a
  brief.
- A brief that is a bare slash command is skipped by the reminder, like every bare slash command,
  so the lineage resolves on the next typed prompt. That prompt carries no brief note once the slash
  command's turn completed and raised `completedTurns`; after a turn that ended in an error, the
  user's own next prompt still carries it, and for that one request a route preference the user
  typed decides nothing.
- With `hooks.tddReminder=false` no brief note appears; the plan gate still resolves the
  inheritance. A terminal fork (`--fork-session`) leaves no desktop record and inherits nothing;
  its lineage source is different and is a follow-up. The desktop's fork action writes `spawnedFrom`
  with `userFork: true`, and a fork in which the user continues another linked session names that
  session in `forkedFromSessionId`, so both inherit `build` like any linked session and never carry
  the note.
- The one resolution is a cross-session read: two desktop records, one Session Control record, up
  to two markers of another session, and `git rev-parse` in both roots. Measured on 2026-10-18:
  p95 26 ms in-process, and p95 174 ms through the CLI at a load average of 27, where a bare `node`
  start alone took p50 81 ms. Measured again on 2026-11-24: 1 ms in-process where a Hub profile's
  store is unreachable, and 31 to 41 ms on the multi-store resolver of PR #648 (eleven store
  candidates in under 0.5 ms, the two `git rev-parse` calls 24 to 29 ms); as a process at a load
  average of 90 to 120 the resolver took 1.6 to 2.9 s and the two `git` starts 0.5 to 0.8 s, all of
  it process start. Later prompts read one marker in bash and start no process.
- A resolution the lineage budget cut short answers `deferred` and caches nothing, so the next
  prompt resolves again and inherits. The brief itself gets its route field from the ordinary
  ladder and no brief note, so a route preference in it can act as the user's own for that one
  prompt, the behavior from before inheritance. The next prompt is the user's own once the brief's
  turn completed, so it gets the inherited route and no note.
- The parent is looked up under its current `cliSessionId` only. A parent whose record lists
  `priorCliSessionIds` and whose marker was written under one of those earlier ids passes nothing
  on.
- The brief is recognized through `completedTurns` in the own desktop record, a private field. A
  first turn that ended in an error leaves it absent, so a re-resolution after such a turn still adds
  the note; a desktop build that never writes it makes every re-resolution `first`, so the linked
  marker's absence alone decides the note; and the field must be on disk before the next prompt's hook reads
  it, which the desktop's save after each result makes likely but which was not observed live.
- A user fork is recognized through two more private fields of the own record, `spawnedFrom.userFork`
  and `forkedFromSessionId`. Measured on 2026-11-24 over the ten Session Hub profile stores: 74
  records carried `forkedFromSessionId`; 43 carried `userFork: true` (41 with the parent as the fork
  source, 2 with another session) and 31 carried `userFork: false` with a source other than the
  parent. None of the 74 was created by a `start_session` or `hand_off_to_session` call, and none
  opened with a brief: 63 first prompts were typed by the user, the rest were task notifications,
  compaction summaries, a `/goal` command or no prompt. No `start_session` call with
  `context: "fork"` appears in the 5,538 transcripts written since 2026-10-15, so the record of a
  session that another session forks is unmeasured. `isUserFork` therefore counts a source other
  than the parent, never the parent itself, so such a session keeps the note as long as it names its
  own parent as the source and carries no `userFork: true`. A session another session started that
  carried either marker would lose the note, so a route preference in its brief would decide that
  one prompt, the direction that removes review under a `build` field. A desktop build that renames
  the markers makes user forks read as briefs again, the behavior from before the `fork` turn.
- A linked session that is already running when the release carrying this arrives resolves its
  lineage on its first prompt under the new runtime. It gets no brief note, because its
  `completedTurns` is set, but it can start inheriting `build` mid-session, which the field discloses.
- A new CLI session id under the same desktop session resolves again under the new key. It gets no
  note, but it inherits from the parent's CURRENT markers rather than the snapshot the old key took,
  and a desktop that has not yet written the new `cliSessionId` answers `cli-session-mismatch`, a
  final `none`. None of the 525 linked records on this machine carried `priorCliSessionIds` on
  2026-10-18.
