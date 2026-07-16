# empty-host fixture

Minimal cloneable host directory for promptfoo evaluation of `/zensu:reset-review-limit`. The wrapper (`scripts/claude-promptfoo-wrapper.sh`) clones this directory into a fresh `mktemp -d` per test run, so scenarios can create isolated Session Control state without polluting the repo.

No source files are needed. Scenarios bind to the current `ZENSU_SESSION_KEY`,
create one canonical CAS workflow document through the plugin helpers, and
validate it through the trusted Core reader.
