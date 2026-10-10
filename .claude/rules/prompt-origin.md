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

## The classification

`zensu_prompt_origin PROMPT [PAYLOAD]` prints one of `task-notification`, `ci-monitor-event`,
`bash-input`, `slash-command`, `slash-command-args` or `typed`.

1. `origin.kind == task-notification` in the payload decides at once. `origin.kind == human`
   forbids the two harness classes, so pasted harness text in a human prompt stays typed. Any
   other kind falls through to the tags. The payload is parsed by `node` only when it contains
   the literal key `"origin"`, so today's payloads cost no process.
2. Leading whitespace and leading `<system-reminder>` blocks are stripped.
3. The leading tag decides: `<task-notification>`, `<ci-monitor-event>`, `<bash-input>`, a raw
   `/name` or the `<command-name>` / `<command-message>` spelling. A slash command needs a name of
   letters, digits, `_`, `.`, `:` and `-` followed by whitespace or the end, so a prompt opening
   with an absolute path stays typed. Arguments are any non-space text after the name, or inside
   `<command-args>`.
4. Everything else, including an empty prompt and an unclosed reminder, is `typed`. Every unknown
   fails toward firing.

**Only the first 16 KiB of the prompt are classified.** Bash pattern removal is quadratic on bash
3.2: stripping a 64 KiB reminder took 0.73 s, and classifying a prompt behind a 400 KiB reminder
took 26 s. A reminder chain that runs past
the window classifies as `typed`, which is the firing direction. `U4` pins the bound.

## Which hook answers which kind

| Hook | Typed, slash with arguments | Task notification, `!` input, bare slash | CI-monitor event |
|---|---|---|---|
| `user-prompt-tdd-reminder.sh` | full reminder | silent | route field + one standing-authorization sentence, at most about 400 characters |
| `user-prompt-intent-router.sh` | keyword screen | silent | silent |
| `user-prompt-zen-mode.sh` | directive | directive | directive |
| `user-prompt-best-solution-first.sh` | directive | directive | directive |
| `user-prompt-context-nudge.sh` | once per band | once per band | once per band |
| `user-prompt-worktree-keep.sh` | notice only | notice only | notice only |

Zen-mode and best-solution-first stay on every kind on purpose: the reply to a notification or a
CI event is user-visible, so its shape and its option set still matter. The reminder's CI note is
emitted by `printf` through `emit_route_context`, never as a third `cat <<'JSON'` block, because the
parity helper in `tests/structure/test-tdd-vanilla-mode.sh` refuses a third block and `R13` in
`tests/structure/test-delivery-route.sh` counts two. Both exits sit before the two heredocs.

The router drops, before the keyword match, every whitespace token containing `/` or `\` (paths,
URLs, `owner/repo`), every `zensu:<name>` skill name, and the operand of `--repo` or `--repo=`.
`-R` is not dropped: other tools use it for unrelated operands.

## The budget suite

`tests/structure/test-user-prompt-budget.sh` derives its roster from the `UserPromptSubmit`
entries in `hooks/hooks.json` and fails when a registered hook has no declared budget or a budget
names an unregistered hook. **Adding a `UserPromptSubmit` hook therefore owes a `budget()` row**,
with a minimum for each kind it must answer and a maximum for each kind. It drives every hook on a
typed request, a task notification whose path contains `-zensu-zensu-claude-code-`, a
system-reminder plus `<bash-input>` prompt and a CI-monitor event, and holds each hook and each
sum under its ceiling. The reminder renders the helper command with two absolute paths, so the
suite replaces that command with a fixed placeholder before it measures; without that, the same
tree measured 5,699 and 5,775 characters at two install depths.

## Version

`patch`, walked against `.claude/rules/runtime-lineage.md`: no schema field, no strict key set,
no hook added, removed or renamed, no matcher change, no config key, and every changed hook still
emits only `additionalContext`. The new library changes the runtime digest, which the hook
exemption already covers.

## Known gaps

- Without a structured origin, a typed prompt that opens with a pasted `<task-notification>` or
  `<ci-monitor-event>` block is classified by that tag and loses the reminder and the router.
- The `!` input of the terminal CLI was not observed; the `<bash-input>` spelling comes from a
  desktop-app transcript.
- The desktop app's hook payload for a slash command was not observed; both the raw and the tag
  spelling are classified.
