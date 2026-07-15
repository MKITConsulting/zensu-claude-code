# empty-host fixture

Minimal cloneable host directory for promptfoo evaluation of `/zensu:reset-review-limit`. The wrapper (`scripts/claude-promptfoo-wrapper.sh`) clones this directory into a fresh `mktemp -d` per test run, so scenarios can freely write to `.zensu/state/` without polluting the repo.

No source files are needed. The skill talks only to the installed ticket-bound
state helper. One scenario creates sibling counter decoys solely to prove that
the current-session operation never discovers or mutates them.
