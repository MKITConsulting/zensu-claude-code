# tests/e2e-tdd — live full `/zensu:tdd` cycle E2E

The heaviest suite: drives a **real** `claude --print` run through an entire feature
implementation while the TDD hooks are active, then proves the cycle actually
happened with **deterministic post-run assertions** — not just stdout text.

One fixture (`add-feature`): a clean git repo with a Node test runner and an empty
`src`. The agent writes the RED test and the implementation itself; the Stop-hook
drives the chain RED → GREEN → code-review → self-review → done.

## What it asserts after the run

| # | Assertion | Why it's reliable |
|---|---|---|
| 3 | chain-state `chainDone=true` | the Stop-hook only releases at the terminus → the whole chain ran |
| 4 | FSM history has `RED_FAIL` | a failing test really preceded the impl (test-first) |
| 5 | FSM history reached `IMPL`/`GREEN_PASS` | implementation happened |
| 6 | `node --test` passes in the fixture | the GREEN is real, executed here, not claimed |
| 7 | witness log has a test run | anti-hallucination trail |
| 8 | transcript shows the review stage | code-review / self-review ran |

3 + 4 + 6 together are the core proof: test-first, real pass, full chain complete.

## Running

```bash
bash tests/e2e-tdd/setup-fixtures.sh
bash tests/e2e-tdd/run.sh                 # LIVE — costs API, takes minutes
bash tests/e2e-tdd/run.sh --offline       # re-assert last run's fixture state + capture
bash tests/e2e-tdd/run.sh --self-check    # skeleton only, no claude

# Longer budget for slow runs:
ZENSU_TDD_E2E_TIMEOUT=900 bash tests/e2e-tdd/run.sh
```

The deterministic complement (no API) lives in
`tests/structure/test-tdd-full-cycle.sh`, which walks the same lifecycle by driving
the hooks directly. Run that first — if it fails, the live run will too.
