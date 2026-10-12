# evals/route-short-line-reaction — model reaction to the route short lines

Grades how the model REACTS to the short lines the prompt ledger leaves on every later prompt of a
context generation (see [`.claude/rules/prompt-ledger.md`](../../.claude/rules/prompt-ledger.md)):

- the ask short line of [`hooks/user-prompt-tdd-reminder.sh`](../../hooks/user-prompt-tdd-reminder.sh)
  in vanilla implementation mode, while the route field reads `ask`;
- the two decided lines of the same hook, while `hooks.defaultDeliveryRoute` decides the route
  (`tdd` and `direct`);
- the short planning notice of [`hooks/user-prompt-intent-router.sh`](../../hooks/user-prompt-intent-router.sh).

Each scenario delivers ONE of these lines ALONE, with no full text before it. That is the worst case
of a long context in which the full reminder has faded, and the only case in which a failure points
at the short line and at nothing else. The decided lines have no shorter form: the hook prints the
same decided line on every prompt, so their scenarios test that line as it always reads.

This is the lean core. It covers the vanilla-mode ask and decided lines and the router line. The
strict-mode lines, the CI-event line and the session-marker source of the decided lines are not
covered here.

## Scenarios

- **`control-no-injection.yaml`** — the baseline. Nothing is injected and the installed runtime's
  prompt hooks are silenced. The model must not print a route status line, ask a route or triage question, or copy
  hook scaffolding, and its first decisive action is an edit or nothing. A control that fails shows
  that something other than the line under test steers the run.
- **`control-planning-no-injection.yaml`** — the baseline for the router result. Nothing is
  injected, and the model gets the router scenario's planning request. It must ask no route or
  triage question and print no route status line. A planning control that asks the three triage
  questions shows that the host produces the triage, and the router result then credits nothing to
  the line.
- **`ask-headless-code-change.yaml`** — the ask short line on a code change. The model either runs
  the Zensu workflow through the Skill tool without asking, as the line's headless clause says, or
  asks a complete route question. It never edits first and never records a route itself. After an
  unanswered route question it runs the workflow or stops.
- **`decided-tdd-code-change.yaml`** — the decided `tdd` line. The reply begins with
  `Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)` and runs the workflow
  through the Skill tool with the request as its argument, with no route question and no record
  command.
- **`decided-direct-code-change.yaml`** — the decided `direct` line. The reply begins with
  `Skipping TDD: route direct (hooks.defaultDeliveryRoute)` and edits in this thread, with no route
  question, no Skill call and no `--tdd-begin`.
- **`router-genuine-planning.yaml`** — the router short line on a genuine planning request. The next
  action is the three triage questions, asked before any file read or search, and nothing is
  delegated to a subagent or done through a Zensu CLI mutation.
- **`preflight/channel-check.yaml`** — run by `promptfooconfig-preflight.yaml`, never graded with the
  scenarios above. It proves the two harness assumptions no deterministic test can prove. A random
  nonce directive goes through the same `UserPromptSubmit` channel as the lines under test, and a
  first line equal to the nonce shows that the channel delivers. The user asks for a Skill call, and
  a denied Skill call whose result carries the probe's own reason shows that the `PreToolUse` probe
  intercepts even under `--dangerously-skip-permissions`.
- **`preflight/read-check.yaml`** — the second preflight run. The user asks for one Bash read of
  the fixture, which the probe allows. A result that is not an error and carries the fixture's
  source shows that an allowed call runs: no hook of the installed runtime answers it in the
  probe's place, and the sandbox lets Claude Code write its own temporary files. The channel check
  cannot show this: a hook that blocks every allowed call leaves its denied Skill call unchanged.

## How a run works

[`provider.sh`](provider.sh) is the promptfoo `exec` provider. The first prompt line names the
source (`route-eval-source: <source>`); the rest is the user message.

1. It finds the user-scoped install of the Zensu runtime through `installed_plugins.json` in
   `CLAUDE_CONFIG_DIR`, or `~/.claude` when that is unset, and requires `zensu@zensu` to be enabled,
   because the Skill tool resolves `zensu:tdd` from the installed plugin.
2. It checks that runtime for silence: [`lib/capture-injections.sh`](lib/capture-injections.sh)
   fires every `UserPromptSubmit` hook of the installed `hooks.json` twice under
   [`eval-config.json`](eval-config.json) with the scenario's message, and requires no output and
   a zero exit from each. A positive control fires the reminder without that config and must get
   output, so the check is not vacuous for the reminder. A second control fires the intent router
   the same way; a planning scenario requires its output, so the router's silence is not vacuous
   either. The check proves silence for the prompt
   it sends: it sends no transcript path, so the context nudge would stay quiet even without its
   switch, and `eval-config.json` switches it off as well.
3. It captures the line under test from THIS tree's hook. The hook runs in a sandbox after a
   `SessionStart`, fires twice, and the second output is kept, because the ledger gives the full
   text on the first prompt and the short line on every later one. The capture checks the opening
   shape, the route field and that no placeholder is left.
4. It writes run settings that add [`lib/decision-probe.js`](lib/decision-probe.js), which sees
   every tool call, and, unless the source is `none`, [`lib/inject-context.js`](lib/inject-context.js),
   which delivers the captured line as `additionalContext`. The same settings pin `ZENSU_CONFIG` to `eval-config.json` and switch
   every other enabled plugin off. The run directory must lie under `HOME`, because the wrapper's
   sandbox lets the hooks write nowhere else that lasts; the provider refuses any other place.
5. It runs [`scripts/claude-promptfoo-wrapper.sh`](../../scripts/claude-promptfoo-wrapper.sh) on the
   immutable fixture `test-projects/cart-app`, with the settings passed through
   `ZENSU_WRAPPER_SETTINGS` and `ZENSU_CONFIG` pointing at `eval-config.json`. After the wrapper's
   attestation it prints one `[route-eval-hook]` line for each probe and inject record and one
   `[route-eval-capture]` line.

The probe answers each call with one of four decisions:

| Decision | Calls | Effect |
|---|---|---|
| `ALLOW` | `Read`, `Glob`, `Grep`, `LS`, `LSP`, `WebSearch`, `WebFetch`, `BashOutput`, task-list tools, `ToolSearch`, and a single-line Bash command whose every part is a plain `ls`, `cat`, `head`, `tail`, `wc`, `pwd`, `tree`, `file`, `stat`, `cd`, `grep`, `rg`, `find`, `echo`, `printf` or `nl`, `true`, `test` or `[` (none of these three with `-v` or `-R`), a `sed -n` that prints a numbered line range, the fixture's test command, a read-only `git status`, `log`, `diff`, `show`, `ls-files` or `rev-parse`, or `git remote` with at most `-v`, with no substitution, no redirection except to `/dev/null` or of stderr to stdout, and no flag that writes, runs a program or waits | runs; not decisive |
| `SETUP` | `EnterWorktree`, and a Bash command that runs `git worktree`, `git branch`, `checkout` or `switch`, listings included and also behind `--no-pager`, beside nothing but allowed parts | denied with "work in the current directory"; not decisive |
| `CONTINUE` | `AskUserQuestion` | denied with "no person can answer"; decisive when it is a route or triage question |
| `END` | everything else, the Skill tool and every edit included | denied with "end your turn now"; decisive |

The probe splits a Bash command at `&&`, `||`, `|`, `;` and parentheses, outside quotes only. A
quoted string counts as literal text, so a pattern such as `"a|b"` stays one argument, and a
`$` or backtick inside double quotes, or an unclosed quote, makes the command `END`. A backslash
outside quotes keeps the next character as literal text, so `\(` stays one argument; a backslash at
the end of the command, and any line break, make it `END`.

`END` denies the call and asks the model to end its turn, but the model may go on.
`first-decisive.js` and `after-ask.js` judge the first decisive call and the one after an
unanswered route question. `no-route-question.js`, `no-delegation.js` and
`route-question-complete.js` read only what comes before the first `END`. `no-record-command.js`,
`no-route-status.js`, `no-placeholder-copy.js` and `router-triage-first.js` read the whole run, so
a record command, a status line or a look after the deny still fails it.

The graders read the FIRST decisive action from the probe records. A question counts as a route
question when it offers the Zensu workflow and implementing directly in a wording that
`ROUTE_WORKFLOW` and `ROUTE_DIRECT` in [`lib/envelope.js`](lib/envelope.js) know; only the ask
scenario's completeness grader also requires the exact labels and disclosures. A question counts as
the triage when its three topics stand in sentences that ask, or in list items under a lead-in that
asks; a statement before a dash, colon or semicolon in such a sentence is left out, but a guess
joined to a question by a comma still counts. A question asked through the tool counts as `ask` only
when it is the kind the scenario's hook asks for, a route question for the reminder and the triage
for the router; any other, and every one in a control, is graded `ask:route` or `ask:triage`. A
question asked in prose counts as `ask` when the scenario names a hook and no decisive call was
made, with the scenario's own status line left out of that prose. The probe records carry the call id when the hook input has one, and the graders pair
them with the stream by position and tool name when it has none. A status line or nonce may
follow the narration of a setup call, because that detour is not graded. The status line must
also come before every call the probe does not answer with `SETUP`; the nonce only has to open the
first text the model writes. After a setup call the first two lines of the next text count, so a
one-line acknowledgement of the denial may come first.

## Graders

Every scenario carries three harness graders from `defaultTest`. `harness-attested.js` requires one
wrapper attestation, the immutable fixture, a capture for the scenario's source and the silence
proof, and on a planning message the intent router's positive control. `harness-injection.js` requires that the session received exactly the captured block, with
the shape and route field the scenario names. `harness-isolation.js` requires an unchanged fixture,
a probe record for every tool call that ran, and the probe's own answer on every probed call: an
allowed call shows no hook error, and a denied call is an error that carries the probe's reason.
A call that another `PreToolUse` hook answered fails the run as a harness fault, so it is never
read as model behaviour.

The behaviour graders are listed in each scenario. They are unit-tested in both directions by
[`tests/structure/route-short-line-graders.test.js`](../../tests/structure/route-short-line-graders.test.js),
which [`tests/structure/test-route-short-line-eval.sh`](../../tests/structure/test-route-short-line-eval.sh)
drives in CI. That suite also captures every line from this tree and pins each scenario's
`anchor_clause` and `expected_status` against it, checks that every prompt hook of the tree stays
silent under `eval-config.json`, and runs the provider dry.

## Known confounds

- **The host's own instructions load.** The eval session reads the user's global `CLAUDE.md` and
  settings. A global rule that asks for a worktree first is answered by the probe as `SETUP`, listings
  of worktrees and branches included, and is not graded. Other reads such a rule may start with, such
  as `git status` or `ls`, are allowed calls: one before the status line ends the window of
  `status-line-exact.js`, and one before the triage counts as a look in `router-triage-first.js`.
  Other global rules can still shape a reply. Read the controls first:
  `control-no-injection.yaml` for the code-change scenarios and `control-planning-no-injection.yaml`
  for the router. A control that fails means the host, not the short line, steers the run.
- **The other enabled plugins are switched off through `--settings`.** That `enabledPlugins` in a
  `--settings` file overrides the user's settings is an assumption until a live run shows no other
  plugin's skills or hooks in the transcript.
- **Only prompt hooks are checked for silence.** `SessionStart`, `PreToolUse` and `Stop` hooks of
  the installed runtime still run under `eval-config.json`. The evidence-discipline block that
  `SessionStart` injects is not a route instruction, but it is in the context. A `PreToolUse` hook
  that answers a probed call in place of the probe fails `harness-isolation.js`.
- **Headless shows only through a missing tool.** `claude --print` offers no `AskUserQuestion`
  among its tools (Claude Code 2.1.280 lists 21 tools at session start, `ToolSearch` among them and
  `AskUserQuestion` not), and nothing else tells the model that no person can answer. A model that
  cannot reach the tool takes the headless arm or asks in prose, so the ask scenario allows both the
  headless arm and a complete route question, and its result shows what the line does when the
  model cannot ask through the tool.
- **The ask line names paths of the capture.** Its record command carries the capture sandbox's
  plugin-data path and this tree's script path. The probe denies the command and
  `no-record-command.js` flags it, so the stale paths cannot change state.
- **The probe's reads are a fixed list.** A read the list does not name, such as a pipe into
  `sort` or a multi-line command, is answered with `END` and graded as an `other:` action, and the
  grader's reason names the command. Read a failure whose first
  decisive action is `other:Bash` as a probe gap before reading it as a model failure.

## Run

Run the preflight first. It costs two model runs and shows whether the graded runs can mean
anything. Always pass `--no-cache`: promptfoo keys its cache on the provider script, the prompt and
the options, so without it a second run returns the stored transcript, and an edited hook line,
probe or installed runtime is graded against the old one.

```bash
promptfoo eval --no-cache --no-share -c promptfooconfig-preflight.yaml
```

```bash
promptfoo eval --no-cache --no-share -c promptfooconfig.yaml
```

Both are live: they need the `claude` CLI, promptfoo and an enabled `zensu@zensu` install, and they
cost API credits. Like every promptfoo eval in this repository, this one is local-only and never a
CI gate. `ROUTE_EVAL_DRY_RUN=1 ./provider.sh "$(printf 'route-eval-source: ask\nhello')"` prints the
settings, environment and capture of a run without starting a model.
