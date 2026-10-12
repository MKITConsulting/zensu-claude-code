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
at the short line and at nothing else.

This is the lean core. It covers the vanilla-mode ask and decided lines and the router line. The
strict-mode lines, the CI-event line and the session-marker source of the decided lines are not
covered here.

## Scenarios

- **`control-no-injection.yaml`** — the baseline. Nothing is injected and the installed runtime is
  silenced. The model must not print a route status line, ask a route or triage question, or copy
  hook scaffolding, and its first decisive action is an edit or nothing. A control that fails shows
  that something other than the line under test steers the run.
- **`ask-headless-code-change.yaml`** — the ask short line on a code change. The model either runs
  the Zensu workflow through the Skill tool without asking, as the line's headless clause says, or
  asks a complete route question. It never edits first and never records a route itself. After an
  unanswered route question it runs the workflow or stops.
- **`decided-tdd-code-change.yaml`** — the decided `tdd` line. The reply begins with
  `Executing via /zensu:tdd (vanilla mode, route: hooks.defaultDeliveryRoute)` and runs the workflow
  through the Skill tool, with no route question and no record command.
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
   output, so the check is not vacuous for the reminder. The check proves silence for the prompt
   it sends: it sends no transcript path, so the context nudge would stay quiet even without its
   switch, and `eval-config.json` switches it off as well.
3. It captures the line under test from THIS tree's hook. The hook runs in a sandbox after a
   `SessionStart`, fires twice, and the second output is kept, because the ledger gives the full
   text on the first prompt and the short line on every later one. The capture checks the opening
   shape, the route field and that no placeholder is left.
4. It writes run settings that add two hooks: [`lib/inject-context.js`](lib/inject-context.js)
   delivers the captured line as `additionalContext`, and [`lib/decision-probe.js`](lib/decision-probe.js)
   sees every tool call. The same settings pin `ZENSU_CONFIG` to `eval-config.json` and switch
   every other enabled plugin off. The run directory must lie under `HOME`, because the wrapper's
   sandbox lets the hooks write nowhere else; the provider refuses any other place.
5. It runs [`scripts/claude-promptfoo-wrapper.sh`](../../scripts/claude-promptfoo-wrapper.sh) on the
   immutable fixture `test-projects/cart-app`, with the settings passed through
   `ZENSU_WRAPPER_SETTINGS` and `ZENSU_CONFIG` pointing at `eval-config.json`. After the wrapper's
   attestation it prints one `[route-eval-hook]` line for each probe and inject record and one
   `[route-eval-capture]` line.

The probe answers each call with one of four decisions:

| Decision | Calls | Effect |
|---|---|---|
| `ALLOW` | `Read`, `Glob`, `Grep`, `LS`, `LSP`, `WebSearch`, `WebFetch`, `BashOutput`, task-list tools, `ToolSearch`, and a single-line Bash command whose every part is a plain `ls`, `cat`, `head`, `tail`, `wc`, `pwd`, `tree`, `file`, `stat`, `cd`, `grep`, `rg` or `find`, the fixture's test command, or a read-only `git status`, `log`, `diff`, `show`, `ls-files` or `rev-parse`, with no substitution, no redirection except to `/dev/null` or of stderr to stdout, and no flag that writes, runs a program or waits | runs; not decisive |
| `SETUP` | `EnterWorktree`, and a Bash command that runs `git worktree`, `checkout`, `switch` or `branch` beside nothing but allowed parts | denied with "work in the current directory"; not decisive |
| `CONTINUE` | `AskUserQuestion` | denied with "no person can answer"; decisive when it is a route or triage question |
| `END` | everything else, the Skill tool and every edit included | denied with "end your turn now"; decisive |

The graders read the FIRST decisive action from the probe records. A question counts as a route
question when it offers the Zensu workflow and implementing directly, in any wording; only the
ask scenario's completeness grader also requires the exact labels and disclosures. A route or
triage question asked in prose, with no tool, counts as `ask` when the scenario names the hook it
expects. The probe records carry the call id when the hook input has one, and the graders pair
them with the stream by position and tool name when it has none. A status line or nonce may
follow the narration of a setup call, because that detour is not graded.

## Graders

Every scenario carries three harness graders from `defaultTest`. `harness-attested.js` requires one
wrapper attestation, the immutable fixture, a capture for the scenario's source and the silence
proof. `harness-injection.js` requires that the session received exactly the captured block, with
the shape and route field the scenario names. `harness-isolation.js` requires an unchanged fixture
and a probe record for every tool call that ran.

The behaviour graders are listed in each scenario. They are unit-tested in both directions by
[`tests/structure/route-short-line-graders.test.js`](../../tests/structure/route-short-line-graders.test.js),
which [`tests/structure/test-route-short-line-eval.sh`](../../tests/structure/test-route-short-line-eval.sh)
drives in CI. That suite also captures every line from this tree and pins each scenario's
`anchor_clause` and `expected_status` against it, checks that every prompt hook of the tree stays
silent under `eval-config.json`, and runs the provider dry.

## Known confounds

- **The host's own instructions load.** The eval session reads the user's global `CLAUDE.md` and
  settings. A global rule that asks for a worktree first is answered by the probe as `SETUP` and is
  not graded, but other global rules can still shape a reply. Read the control scenario first: a
  control that fails means the host, not the short line, steers the run.
- **The other enabled plugins are switched off through `--settings`.** That `enabledPlugins` in a
  `--settings` file overrides the user's settings is an assumption until a live run shows no other
  plugin's skills or hooks in the transcript.
- **Only prompt hooks are checked for silence.** `SessionStart`, `PreToolUse` and `Stop` hooks of
  the installed runtime still run under `eval-config.json`. The evidence-discipline block that
  `SessionStart` injects is not a route instruction, but it is in the context.
- **Headless is not announced.** `claude --print` runs with no human to answer, but nothing tells
  the model so. The ask scenario therefore allows both the headless arm and a complete route
  question.
- **The ask line names paths of the capture.** Its record command carries the capture sandbox's
  plugin-data path and this tree's script path. The probe denies the command and
  `no-record-command.js` flags it, so the stale paths cannot change state.
- **The probe's reads are a fixed list.** A read the list does not name, such as a pipe into
  `sort` or a multi-line command, ends the run as an `other:` action. Read a failure whose first
  decisive action is `other:Bash` as a probe gap before reading it as a model failure.

## Run

Run the preflight first. It costs one model run and shows whether the graded runs can mean
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
