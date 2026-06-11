# evals/context-nudge-reaction — model reaction to the context-nudge

Grades how the model REACTS to the context-compaction nudge that
[`hooks/user-prompt-context-nudge.sh`](../../hooks/user-prompt-context-nudge.sh) injects. The nudge only
fires where the context window is **known** — `windowSize` is configured, or occupancy past 200k proves a
1M session — so the injected message is always **confident** (there is no "may be wrong" hedge to grade).
The behaviour worth checking: the model surfaces `/compact` as a **user** action and does not claim to run
compaction itself (only the user may trigger it), while still answering the user.

The message *wording* is pinned deterministically by
[`tests/structure/test-context-nudge-hook.sh`](../../tests/structure/test-context-nudge-hook.sh); this
suite covers the non-deterministic complement: the model's behaviour.

## Scenario

- **`scenarios/reaction-configured.yaml`** — a confident nudge ("~60% of the configured 1M window"). The
  model must open with `CONTEXT-NUDGE-HANDLING: RELAY-TO-USER`, surface `/compact` as a user option (a
  "you …/compact" framing), not claim to self-run it, and still answer the user's question.

## Why this design

- **Simulated injection, not the real hook path.** A fresh `claude --print` session is ~0 occupancy, so
  the real `UserPromptSubmit` hook never fires and `transcript_path` cannot be overridden. The scenario
  places the exact hook message text in the prompt as a "hook-injected system note" and grades the reply.
- **No `llm-rubric`/grader** — matching every eval in this repo. Assertions are `type: javascript` over
  the model output, keyed on a forced decision token (`CONTEXT-NUDGE-HANDLING: RELAY-TO-USER`) and literal
  markers. `repeat: 3` averages model variance.
- **Live + advisory.** Running this costs API credits and can flake on model variance — NOT a CI gate.
  Only the deterministic shape pin
  [`tests/structure/test-promptfoo-context-nudge-reaction.sh`](../../tests/structure/test-promptfoo-context-nudge-reaction.sh)
  runs in `tests/run-all.sh` (no API).

## Run

```bash
promptfoo eval -c promptfooconfig.yaml        # live; needs claude CLI + promptfoo; costs API credits
```

`test-projects/` is the cloneable working-dir fixture.
