# Empty host (zen-mode-reaction eval fixture)

Minimal cloneable host directory for the promptfoo evaluation of the zen-mode model-reaction scenarios.
The wrapper (`scripts/claude-promptfoo-wrapper.sh`) clones this directory into a fresh `mktemp -d` per
test run. The scenarios inject a simulated hook contract into the prompt and grade the reply, so no
project files are needed here — this fixture only gives the wrapper a clean working dir.
