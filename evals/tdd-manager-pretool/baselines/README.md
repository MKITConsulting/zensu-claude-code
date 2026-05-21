# Baselines

Each promptfoo scenario, when run with a temperature-0 Claude provider, produces a roughly stable token-count and phase-sequence. Save the first known-good run as `<scenario>.expected.json`:

```bash
promptfoo eval -c promptfooconfig-pretool.yaml --output baselines/01-happy-frontend.expected.json
```

Subsequent runs are then compared against the baseline with `tools/compare-baseline.js` (see `run-eval.sh` Phase 6).

Baselines are NOT checked in for now — generate locally after the first successful real-Claude run.
