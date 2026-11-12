---
paths:
  - "hooks/lib/zensu-prompt-origin.sh"
  - "hooks/hooks.json"
  - "hooks/user-prompt-*.sh"
  - "tests/structure/test-user-prompt-budget.sh"
  - "tests/structure/test-intent-router-hook.sh"
  - "tests/structure/test-tdd-reminder-hook.sh"
---

# Prompt Origin and the UserPromptSubmit Budget (`hooks/lib/zensu-prompt-origin.sh`)

`UserPromptSubmit` fires for every prompt the host submits, not only for what the user types:
background-task notifications, `!` shell inputs, slash commands and CI-monitor events reach the
same hooks. Measured in one session on 2026-10-05/06: none of its 12 prompts was a typed request,
yet each received every directive, about 166,000 characters in all. `zensu_prompt_origin` tells
the kinds apart so a hook can answer only the prompts it is meant for.

## What the host sends

A logged payload from Claude Code 2.1.280 (headless, 2026-10-06) carried `session_id`,
`transcript_path`, `cwd`, `scratchpad_dir`, `prompt_id`, `permission_mode`, `hook_event_name` and
`prompt`, for a typed prompt and a task notification alike: no origin field. Slash commands
arrive as their raw text (`/probe`, `/probe alpha beta`). The 2.1.288 binary declares an optional
`source` enum (`user`, `sdk`, `system`, `loop_wakeup`, `schedule_wakeup`, `poll_event`) in its
input schema, but the builder that sends the payload compiles that field out. It is deliberately
NOT read: the desktop app submits typed prompts and CI-monitor events through the SDK, so both
would read `sdk`. Transcripts record `origin.kind` (`human` for typed text, slash commands and
shell inputs, `task-notification` for task notifications; CI-monitor events carry none), and that
is the one structured field the classifier reads when a payload carries it.

The desktop app (Claude Code 2.1.286 to 2.1.295, 2026-10-09/10) sends the same shapes. Its
transcript stores a task notification as the raw `<task-notification>` text with
`origin.kind: task-notification`. The `[SYSTEM NOTIFICATION - NOT USER INPUT]` system-reminder
the model sees around it is added when the turn is rendered for the model, from that origin
field, so it never reaches a hook: the 2.1.295 builder passes the submitted text as `prompt` and
still sends no origin field. A subagent hand-back is stored as the line `Another Claude session
sent a message:` followed by an `<agent-message from="…">` block, with `origin.kind: peer`, and the
`UserPromptSubmit` hooks fire on it. These facts come from the session transcript and from the
2.1.295 binary; no live payload was logged for them.

## The classification

`zensu_prompt_origin PROMPT [PAYLOAD]` prints one of `task-notification`, `agent-message`,
`ci-monitor-event`, `session-brief`, `bash-input`, `slash-command`, `slash-command-args` or
`typed`.

1. `origin.kind == task-notification` in the payload decides at once, and so does
   `origin.kind == peer`, which reads as `agent-message`. `origin.kind == human`
   forbids the three harness classes (`task-notification`, `ci-monitor-event`, `agent-message`),
   so pasted harness text in a human prompt stays typed. The app's brief line is not one of them:
   it reads as `session-brief` under every origin, because transcripts record most briefs with
   `origin.kind: human` (see below). Any other kind falls through to the tags. The payload is parsed by `node` only when it contains
   the literal key `"origin"`, so today's payloads cost no process.
2. Leading whitespace and leading `<system-reminder>` blocks are stripped. `zensu_prompt_reminder_span`
   measures that span once, inside the 16 KiB window below, and `zensu_prompt_own_text` prints the
   prompt without it, so a caller reads the same span the classifier skipped and keeps every
   character after it, past the window included.
3. The leading tag decides: `<task-notification>`, `<ci-monitor-event>`, `<agent-message>` or
   `<cross-session-message>` alone or after the `Another Claude session sent a message:` line, the
   app's `Background (from the session that started this one):` line, which opens the brief of a
   session another session started and reads as `session-brief`, `<bash-input>`, a raw
   `/name` or the `<command-name>` / `<command-message>` spelling. A slash command needs a name of
   letters, digits, `_`, `.`, `:` and `-` followed by whitespace or the end, so a prompt opening
   with an absolute path stays typed. Arguments are any non-space text after the name, or inside
   `<command-args>`.
4. Everything else, including an empty prompt and an unclosed reminder, is `typed`. Every unknown
   fails toward firing.

A `<cross-session-message>` block, bare or after the peer line, is what a session receives from
another one; transcripts store the second shape with `origin.kind: peer`, so the tag arm now
agrees with the structured one. `session-brief` exists for the zen-mode gate. The reminder and the
router keep treating a side-session brief as typed: neither lists it among the kinds it skips, and
the reminder's linked-session brief note (`.claude/rules/session-delivery-route.md`) names it
beside `typed`, because that brief is the very prompt the note is written for. `U13` pins both
hooks on a brief and `L45` in `tests/structure/test-linked-session-route.sh` pins the note.

**Only the first 16 KiB of the prompt are classified.** Bash pattern removal is quadratic on bash
3.2: stripping a 64 KiB reminder took 0.73 s, and classifying a prompt behind a 400 KiB reminder
took 26 s. A reminder chain that runs past
the window classifies as `typed`, which is the firing direction. `U4` pins the bound.

## Which hook answers which kind

| Hook | Typed, slash with arguments | Task notification, subagent hand-back or cross-session message, `!` input, bare slash | CI-monitor event |
|---|---|---|---|
| `user-prompt-tdd-reminder.sh` | full reminder once per context generation, then a short line; the decided line on every prompt while the route is `build` or `direct`; on a linked session's brief, one more opening sentence; silent on a slash command that invokes `/zensu:autopilot`, `/zensu:pilot` or `/zensu:work` (`zensu_prompt_slash_name`) | silent | route field + one standing-authorization sentence, at most about 400 characters |
| `user-prompt-intent-router.sh` | keyword screen; full notice once per context generation, then a short line | silent | silent |
| `user-prompt-zen-mode.sh` | directive once per context generation and anchor variant, then a short body; the text behind the leading reminders can deactivate the mode | the same directive; never deactivates, except a bare slash command, which can | the same directive; never deactivates |
| `user-prompt-best-solution-first.sh` | one-line reminder | one-line reminder | one-line reminder |
| `user-prompt-context-nudge.sh` | once per band | once per band | once per band |
| `user-prompt-worktree-keep.sh` | notice only | notice only | notice only |
| `user-prompt-session-hub-receipt.sh` | silent; writes a receipt only for the Session Hub's exact takeover command | silent | silent |
| `user-prompt-session-hub-takeover-notice.sh` | one notice, only for the `session-hub@zensu` companion's takeover command, `/session-hub:session-trail takeover …`, in its raw or command-tag form and only while `hooks.bashWriteGate` is on; silent otherwise | silent | silent |
| `user-prompt-review-handback.sh` | silent, with no `node` child while no arrival note is pending; while one is, one `node` child (`arrive`), and the review's routing directive when the note is this session's | silent, with no `node` child while no background review is pending in the plugin's store; the hand-back or completion notification of a pending consume reviewer carries the review's routing directive, and with the review packet gate on a background panel reviewer's hand-back, or its notification with a `<result>`, carries the gate's advice when its packet differs (`.claude/rules/background-review-completion.md`) | silent, with the same arrival-note exception as a typed prompt |
| `user-prompt-context-auto-load.sh` | exactly one distinct key in typed prose or in a raw `/name` command's arguments: that feature's context package; typed prose with no key, at least 8 characters and two words: the candidates of one discovery search, which sends up to 2,000 characters of that prose to the Zensu backend; a failed read: an unavailability notice, 320 characters for discovery and 311 plus the key's length for a key; two or more keys, a slash command's prose arguments, the `<command-name>` spelling and a prompt behind a leading `<system-reminder>`: silent | silent, no CLI call | silent, no CLI call |

A side-session brief (`session-brief`) gets what a typed prompt gets in every row, the reminder's
brief note included, except zen-mode, which injects the same directive and never deactivates on it.

**A linked session's brief is marked by its lineage, not by its origin.** The first prompt of a
session another Claude Desktop session started is the brief that session wrote. It arrives with
`origin.kind: human` (335 of the 424 measured on 2026-10-18) or with none (87), behind the
reminders the desktop adds. A fresh brief opens with the app's Background line and classifies as
`session-brief` under either origin; a forked session's brief opens with no such line and stays
`typed`. The reminder and the router treat both as typed, and the reminder marks the brief through
the session's lineage instead: on the prompt that first resolves the
lineage as linked, its directive opens with one sentence saying the prompt is another session's
brief, so a route preference in it decides nothing (`.claude/rules/session-delivery-route.md`
§"Linked sessions inherit `build`"). No other hook reads the lineage.

`.claude/rules/prompt-ledger.md` owns the once-per-generation mechanism. Zen-mode and best-solution-first stay on every kind on purpose: the reply to a notification or a
CI event is user-visible, so its shape and its option set still matter. The reminder's CI note, its decided
line and its short line are emitted by `printf` through `emit_route_context`, never as a third `cat <<'JSON'` block, because the
parity helper in `tests/structure/test-tdd-vanilla-mode.sh` refuses a third block and `R13` in
`tests/structure/test-delivery-route.sh` counts two. All of these exits sit before the two heredocs.

The router drops, before the keyword match, every whitespace token containing `/` or `\` (paths,
URLs, `owner/repo`), every `zensu:<name>` skill name, and the operand of `--repo` or `--repo=`.
`-R` is not dropped: other tools use it for unrelated operands.

The context auto-load hook does not call `zensu_prompt_origin`: `promptText` and `taskQuery` in
`hooks/lib/context-auto-load-v1.js` screen the prompt themselves. They drop a payload whose
`origin` carries a kind other than `human`, and every prompt that opens with `<`, `!` or the
`Another Claude session sent a message:` line, so a typed prompt behind a leading
`<system-reminder>` stays silent here although the classifier strips the reminder and calls the
rest typed. The hook keeps no ledger, so every qualifying prompt reads again. The budget suite
puts a `zensu` stub that exits 1 first on `PATH`, so the typed figure it holds this hook to, 300
to 400 characters, is the 320-character discovery notice; every other kind must stay at 0.

## Zen-mode deactivation

Only the user's own text can turn zen-mode off. `zen_origin_may_deactivate` in
`hooks/user-prompt-zen-mode.sh` is an allowlist over the classifier: `typed`, `slash-command`,
`slash-command-args`, and an empty answer, which only a classifier that failed to load gives and
which fails toward firing so the escape survives. Every other class, a future one included, never
deactivates. The directive is still injected on those prompts.

**A typed prompt behind leading system reminders:** only the text behind them counts, for the four
phrases and for the whole-prompt editor phrase. A reminder is harness text. Measured on the 300
newest transcripts of this project on 2026-10-30: 202 of 268 sessions with typed prompts carried
leading reminders on some or all of them, the most frequent being the linked-sessions status and
the worktree path, and side-session report notes arrive the same way. A worktree or a linked
session whose name holds a phrase would otherwise end the mode, and the editor phrase could never
match behind a reminder, so typing that escape did nothing. The largest reminder block in that
census was 1,615 characters, well inside the window.

The same census shows the class of the defect: a deactivation phrase appeared in 17 of 2,090 task
notifications, 1 of 166 subagent or peer hand-backs and 2 of 38 side-session briefs, and in none of
1,514 typed prompts. One of those briefs ended the mode of the session it started on 2026-10-30.

**The lost-prompt last resort honours the same gate.** Both call sites scan what
`zen_payload_own_text` hands them: one `awk` pass reads the `prompt` string out of the raw payload
up to its first unescaped closing quote, decodes the `\n`, `\t` and `\r` escapes so the classifier
and the phrase boundaries see real whitespace, keeps an escaped backslash a backslash so `\\n` is
never read as a newline, and the gate and the own-text helper run on the result. That also removes
three false readings of the raw scan: a phrase in another field, such as `scratchpad_dir`, no
longer fires whether it is serialized before or after the prompt, an empty `prompt` string scans
nothing instead of the whole payload, and a phrase right after a newline escape, where the `n` of
`\n` defeated the word boundary, is now seen. The healthy-path call site runs only when the
lost-prompt arm did not already scan, so no turn pays for the scan twice; `Z115` drives that call
site through a live child.

**The classifier library is loaded through a guard.** `zen_origin_lib_load` sources
`hooks/lib/zensu-prompt-origin.sh` only when it is a readable regular file and otherwise defines two
fallbacks: a classifier that answers empty, which the gate admits, and an own-text helper that
returns the whole prompt. So a missing library costs the origin gate, never the escape. `Z116`
drives the extracted loader against an empty plugin root and against the real one, and requires the
hook to call it. A pure-bash read was measured first and rejected: `[[ =~ ]]` plus `${var//\\n/…}` over
a 16 KiB window of escaped newlines had used 20 s of CPU without finishing on bash 3.2.57. A payload
with no readable `prompt` string is still scanned whole, minus `cwd` and `transcript_path`, unless a
structured origin refuses it. `Z114` drives this arm through a `node` shim that kills only the merged
child and requires the arm's own disclosure line, so the check cannot pass without reaching it.

## The budget suite

`tests/structure/test-user-prompt-budget.sh` derives its roster from the `UserPromptSubmit`
entries in `hooks/hooks.json` and fails when a registered hook has no declared budget or a budget
names an unregistered hook. **Adding a `UserPromptSubmit` hook therefore owes a `budget()` row**,
with a minimum for each kind it must answer and a maximum for each kind. It drives every hook on a
typed request, a task notification whose path contains `-zensu-zensu-claude-code-`, a subagent
hand-back, a system-reminder plus `<bash-input>` prompt and a CI-monitor event, each kind in a fresh session and
twice: the first prompt of the session and a repeat, with a ceiling per hook and per sum for each.
`U9` resets the ledger with a `compact` `SessionStart` and requires the first-prompt figures again,
`U10` requires the decided line for a configured `build` or `direct` route, `U12` holds
`zensu_prompt_own_text` to the leading blocks the window closes, and `U13` holds the reminder and
the router to treating a side-session brief as typed and to silence on a cross-session message. The reminder renders the helper command with two absolute paths, so the
suite replaces that command with a fixed placeholder before it measures; without that, the same
tree measured 5,699 and 5,775 characters at two install depths.

## Version

`patch`, walked against `.claude/rules/runtime-lineage.md`: no schema field, no strict key set,
no hook added, removed or renamed, no matcher change, no config key, and every changed hook still
emits only `additionalContext`. The new library changes the runtime digest, which the hook
exemption already covers.

The zen-mode deactivation gate walks the same way, entry by entry, and is a `patch` too. No context
record, workflow-state field or strict key set moves, and the `{"active":true|false}` marker keeps
its shape. No hook is added, removed or renamed, no matcher changes, no config key is added, and no
hook gains a `permissionDecision`. `session-brief` is a new return value of an in-tree shell
function that only hooks of the same installation read, and the reminder names it beside `typed`
for its brief note, so that note's behaviour does not move. The reminder and the router going
silent on a cross-session message changes advisory `additionalContext` only.

## Known gaps

- A session forked from another one opens with a fork reminder and no app line, so its brief stays
  `typed` and can deactivate. A fork the user started has the same shape, so the two cannot be told
  apart.
- `<side-sessions-event>`, `<create-pr-command>` and the app's other generated prompts stay `typed`.
  Their bodies are fixed app text and side-session notes ride in leading reminders, so none of them
  carried a deactivation phrase in its own text in the census above; a future app text that quotes
  one would deactivate.
- A pasted harness shape cuts both ways. Without a structured origin, a typed prompt opening with a
  pasted `<task-notification>` block cannot deactivate; the directive's request to leave the mode in
  any wording, which the model honours through `--off`, remains the way out.
- A reminder chain that runs past the 16 KiB window counts as own text from the first block the
  window cannot close, so a phrase inside it still deactivates. That is the firing direction.
- On the lost-prompt arm a phrase inside a raw `{"prompt":{…}}` object is scanned as raw JSON, where
  the `n` of a `\n` escape right before it still defeats the word boundary.
- No `UserPromptSubmit` record was parented to any of the 165 compaction summaries in the 60 newest
  transcripts, so a summary is not classified. That is an observation of the transcripts, not of
  the host's code.
- Without a structured origin, a typed prompt that opens with a pasted `<task-notification>` or
  `<ci-monitor-event>` block is classified by that tag and loses the reminder and the router.
- The `!` input of the terminal CLI was not observed; the `<bash-input>` spelling comes from a
  desktop-app transcript.
- The desktop app's hook payload for a slash command was not observed; both the raw and the tag
  spelling are classified.
- `user-prompt-intent-router.sh` still reads a linked session's brief as the user's own text, so a
  brief with a planning keyword can trigger its triage. Reusing the linked-session marker there is
  a follow-up.
