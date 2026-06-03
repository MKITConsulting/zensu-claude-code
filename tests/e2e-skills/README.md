# tests/e2e-skills — live LLM E2E for skills & agents

Behavioral end-to-end tests for the plugin's LLM surfaces that previously had only
structure tests (file-exists / string-present). Each fixture drives a **real**
`claude --print` invocation against the locally-loaded plugin and matches the
response with a tolerant regex pattern.

| Fixture | Surface | Invoked as | Proves |
|---|---|---|---|
| `zensu-help` | `/zensu:zensu-help` skill | `/slash` prompt | answers a glossary Q (ZEN-id, lifecycle stages) from embedded knowledge |
| `plan-review` | `/zensu:plan-review` skill | `/slash` prompt | casts a reviewer team, returns one verdict on a flawed plan, writes no code |
| `self-review` | `/zensu:self-review` skill | `/slash` prompt | 7-dimension reflection + Positive/Improvements/Risks over a diff |
| `review-aspect` | `zensu:review-aspect` agent | `--agent` | flags planted bugs from the `bugs` perspective only (no build/test) |

## Layout

```
run.sh              # runner: full | --offline | --self-check
setup-fixtures.sh   # idempotent fixture builder (git repos + uncommitted diffs)
test-runner.sh      # deterministic self-tests for the harness (no API)
prompts/<name>.txt  # the prompt fed to claude --print
prompts/<name>.agent# (optional) agent name -> invoke with --agent instead of a skill
expected/<name>.pattern  # tolerant regex asserts (positive; `!` = negative; `# ` = comment)
fixtures/           # generated, git-ignored
results/            # captures + reports, git-ignored
```

## Running

```bash
# 1. deterministic harness self-tests (no API):
bash tests/e2e-skills/test-runner.sh

# 2. build fixtures (idempotent):
bash tests/e2e-skills/setup-fixtures.sh

# 3a. skeleton check, no API spend:
bash tests/e2e-skills/run.sh --self-check

# 3b. LIVE run — COSTS API CREDITS, spawns claude per fixture:
bash tests/e2e-skills/run.sh

# 3c. re-match the most recent captures without re-spending:
bash tests/e2e-skills/run.sh --offline
```

## Notes

- **Patterns are tolerant by design** — LLM output is non-deterministic, so asserts
  check for stable concepts (verdict tokens, dimension names, the planted bug), not
  exact phrasing.
- **`plan-review` is the heaviest fixture**: it uses `TeamCreate` to spawn a reviewer
  team. The prompt caps the team at `--agents=3` to bound cost. If a headless team
  spawn is flaky, capture once with a live run and re-validate with `--offline`.
- No CI yet; this suite is local-only and opt-in (API cost). The repo-wide
  `tests/run-all.sh` only invokes it under `--live`.
