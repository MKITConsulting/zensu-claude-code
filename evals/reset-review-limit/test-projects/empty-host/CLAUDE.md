# empty-host fixture

Minimal cloneable host directory for promptfoo evaluation of `/zensu:reset-review-limit`. The wrapper (`scripts/claude-promptfoo-wrapper.sh`) clones this directory into a fresh `mktemp -d` per test run, so scenarios can freely write to `.zensu/state/` without polluting the repo.

No source files needed — the skill operates entirely on `.zensu/state/rounds-*.json` files that scenarios pre-seed via the Bash tool in their `spec_block`.
