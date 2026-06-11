# tests/e2e-intent-router — live intent-router E2E

Proves [`hooks/user-prompt-intent-router.sh`](../../hooks/user-prompt-intent-router.sh)
is wired into a **real** Claude Code `UserPromptSubmit` event end to end: the plugin
loads, the hook fires on the genuine event payload, and a planning prompt's injected
directive steers the live model toward `zensu-plm` delegation + greenfield/brownfield
project-context triage.

The deterministic structure test
([`tests/structure/test-intent-router-hook.sh`](../structure/test-intent-router-hook.sh))
pins the classify → emit contract against *synthetic* `{"prompt": …}` payloads. This
suite closes the gap only a real run can: it exercises the hook against the real
`UserPromptSubmit` payload field (`prompt`) and spends one live `claude --print` call
to prove the registration in `hooks/hooks.json` actually activates the hook in a real
session.

## What it asserts

1. **D1** (deterministic) — a planning payload shaped like the real `UserPromptSubmit`
   event yields the `UserPromptSubmit` `additionalContext` directive carrying the three
   load-bearing signals (`zensu-plm` delegation, greenfield+brownfield triage, Plan-mode
   allowance).
2. **D2** (deterministic) — a non-planning payload (`"fix the auth token expiry bug"`) is
   silent. Together D1+D2 prove the hook logic against the real event field name.
3. **L1** (live) — `claude --print` with a planning prompt through the plugin produces
   output: the plugin loaded, the `UserPromptSubmit` hook was active and did not break
   the session.
4. **L2** (live, **best-effort**) — the live reply surfaces an injected triage signal
   (`zensu-plm` / greenfield / brownfield / ghost-scan / bootstrap / "already built" /
   "starting fresh" …), proving the directive reached the model. Because model phrasing
   is non-deterministic this is PASS-or-**SKIP** (never a hard FAIL); the deterministic
   D1 is the real injection guarantee — mirroring the robustness stance of
   [`tests/e2e-context-nudge`](../e2e-context-nudge/README.md).
5. **L3** (live, **best-effort**) — a *false-positive* UI prompt
   (`"…add a new modern hero section to my landing page"`) that merely contains the word
   `product` is sent live; the model should **dismiss** the planning steer and just do the
   task. PASS when no triage signal appears; **OBSERVE** (logged, non-failing) if a triage
   signal leaks through so a human can retune the dismiss-clause; **SKIP** when the API is
   unavailable. The prefilter is a cheap broad-recall gate (it fires on a bare `product` /
   `feature` / `tier`); precision lives in the directive's dismiss-clause, whose presence is
   pinned offline by the structure test (`C14`).

The classify fingerprint (`zensu-plm` AND greenfield+brownfield AND Plan-mode) and the
whole-word prefilter are pinned hermetically by the structure test; this suite proves the
hook is *reached* by a real Claude Code session.

## Run

```bash
bash tests/e2e-intent-router/setup-fixtures.sh   # build the planning/ fixture
bash tests/e2e-intent-router/run.sh              # live (one API call)
bash tests/e2e-intent-router/run.sh --offline    # deterministic asserts only (no API)
bash tests/e2e-intent-router/run.sh --self-check # skeleton only (no claude)
```

Also wired into `tests/run-all.sh --live` and `--self-check`.

`ZENSU_INTENT_E2E_TIMEOUT` overrides the `claude --print` timeout (default 180s).
`fixtures/` and `results/` are generated and git-ignored.
