# evals/tdd-manager-pretool

Watertight promptfoo test suite for the PreToolUse phase-gate.

## What lives here

| Path | Role |
|---|---|
| `run-eval.sh` | 6-phase orchestrator (regression -> hook unit tests -> promptfoo). `--self-check` skips live-agent runs. |
| `promptfooconfig-pretool.yaml` | Main suite, 10 scenarios. |
| `promptfooconfig-regression.yaml` | Existing `evals/tdd-manager/` scenarios with the gate enabled. Expectation: no behavior change. |
| `scenarios/01-happy-frontend.yaml`..`10-override-env.yaml` | Three happy paths (FE/BE/Cross) + six drift scenarios + one override scenario. |
| `assertions/assert-*.{sh,js}` | Phase-sequence, gate-fired, no-bypass, backward-compat assertions. |
| `baselines/*.expected.json` | Expected state sequence per scenario (for baseline diff in Phase 6). |
| `fixtures/stdin-pre-edit-{allow,deny}.json` | Synthetic hook stdin inputs (parallel to `evals/config-gate/fixtures/`). |
| `fixtures/state-baselines/phase-{red-write,red-fail-s1,impl-no-red,green-pass}.json` | Prebuilt `.zensu/state/` baselines for hook unit tests. |
| `test-projects/react-go-fullstack/` | Fixture monorepo with React/TS frontend + Go backend; npm workspaces. |
| `prompts/*.md` | Feature specifications that promptfoo hands to the agent (happy + drift-hint variants). |
| `test-hermetic.sh` | Wrapper for multiple runs (3x per scenario against nondeterminism). |

## Gating

Real Claude runs require:

- `promptfoo` (npm install -g promptfoo) — currently not included in the setup env.
- `claude` CLI with a valid API key.
- `node`, `npm`, `go` (>= 1.20) on PATH.

Without these tools, `run-eval.sh --self-check` still runs (structure + hook unit tests + existing regression suites).

## Next steps

1. `npm install -g promptfoo` once on the CI runner.
2. Run `bash run-eval.sh` fully (~ 10-15 min on Sonnet 4.6).
3. Compare result JSONs under `results/` against the `baselines/` expectations.
