# evals/tdd-manager-pretool

Wasserfeste promptfoo-Test-Suite für den PreToolUse-Phase-Gate.

## Was hier liegt

| Path | Rolle |
|---|---|
| `run-eval.sh` | 6-Phasen-Orchestrator (Regression -> Hook-Unit-Tests -> Promptfoo). `--self-check` skipt Live-Agent-Runs. |
| `promptfooconfig-pretool.yaml` | Haupt-Suite, 10 Szenarien. |
| `promptfooconfig-regression.yaml` | Bestehende `evals/tdd-manager/`-Szenarien mit aktiviertem Gate. Erwartung: keine Verhaltensänderung. |
| `scenarios/01-happy-frontend.yaml`..`10-override-env.yaml` | Drei Happy-Paths (FE/BE/Cross) + sechs Drift-Szenarien + ein Override-Szenario. |
| `assertions/assert-*.{sh,js}` | Phasensequenz-, Gate-fired-, No-Bypass-, Backward-Compat-Assertions. |
| `baselines/*.expected.json` | Erwartete State-Sequenz pro Szenario (für Baseline-Diff in Phase 6). |
| `fixtures/stdin-pre-edit-{allow,deny}.json` | Synthetische Hook-Stdin-Inputs (parallel zu `evals/config-gate/fixtures/`). |
| `fixtures/state-baselines/phase-{red-write,red-fail-s1,impl-no-red,green-pass}.json` | Vorgefertigte `.zensu/state/`-Baselines fuer Hook-Unit-Tests. |
| `test-projects/react-go-fullstack/` | Fixture-Monorepo mit React/TS-Frontend + Go-Backend; npm workspaces. |
| `prompts/*.md` | Feature-Spezifikationen die promptfoo dem Agenten reicht (Happy + Drift-Hint-Varianten). |
| `test-hermetic.sh` | Wrapper fuer Mehrfach-Runs (3x je Szenario gegen Nondeterminismus). |

## Gating

Real-Claude-Runs benoetigen:

- `promptfoo` (npm install -g promptfoo) — aktuell nicht im Setup-Env enthalten.
- `claude` CLI mit gueltigem API-Key.
- `node`, `npm`, `go` (>= 1.20) im PATH.

Ohne diese Tools laeuft `run-eval.sh --self-check` weiter (Struktur + Hook-Unit-Tests + bestehende Regression-Suiten).

## Naechste Schritte

1. `npm install -g promptfoo` einmalig auf dem CI-Runner.
2. `bash run-eval.sh` vollstaendig durchlaufen (~ 10-15 min bei Sonnet 4.6).
3. Resultat-JSONs unter `results/` mit `baselines/`-Erwartungen vergleichen.
