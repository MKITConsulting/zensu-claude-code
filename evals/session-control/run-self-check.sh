#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
PROMPTFOO="$ROOT/node_modules/.bin/promptfoo"
STATE="$(mktemp -d -t zensu-session-selfcheck-XXXXXX)"
trap 'rm -rf "$STATE"' EXIT

test "$(node -p 'require(process.argv[1]).devDependencies.promptfoo' "$ROOT/package.json")" = '0.121.18'
test "$(node -p 'require(process.argv[1]).packages["node_modules/promptfoo"].version' "$ROOT/package-lock.json")" = '0.121.18'
test -x "$PROMPTFOO"
PROMPTFOO_VERSION="$(
  PROMPTFOO_CONFIG_DIR="$STATE" PROMPTFOO_DISABLE_TELEMETRY=1 PROMPTFOO_DISABLE_UPDATE=1 \
    "$PROMPTFOO" --version 2>/dev/null | awk 'NF { version=$0 } END { print version }'
)"
test "$PROMPTFOO_VERSION" = '0.121.18'

for file in "$EVAL_DIR"/promptfooconfig-{contract,live,concurrency,adversarial}.yaml; do
  PROMPTFOO_CONFIG_DIR="$STATE" PROMPTFOO_DISABLE_TELEMETRY=1 PROMPTFOO_DISABLE_UPDATE=1 \
    "$PROMPTFOO" validate config --config "$file" >/dev/null
done

test "$(grep -c '^- description:' "$EVAL_DIR/scenarios/catalog.yaml")" -eq 67
test "$(grep -c '^- description:' "$EVAL_DIR/scenarios/adversarial.yaml")" -eq 6
test "$(grep -c '^- description:' "$EVAL_DIR/scenarios/live.yaml")" -eq 6
grep -q 'maxConcurrency: 4' "$EVAL_DIR/promptfooconfig-concurrency.yaml"
grep -q 'repeat: 3' "$EVAL_DIR/promptfooconfig-concurrency.yaml"
grep -q 'repeat: 5' "$EVAL_DIR/promptfooconfig-adversarial.yaml"
grep -q 'source_dir: ../..' "$EVAL_DIR/promptfooconfig-live.yaml"
PLUGIN_VERSION="$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")"
test "$(jq -r '.plugins[0].version' "$ROOT/.claude-plugin/marketplace.json")" = "$PLUGIN_VERSION"
test "$(jq -r '.plugins[0].source.source' "$ROOT/.claude-plugin/marketplace.json")" = github
test "$(jq -r '.plugins[0].source.repo' "$ROOT/.claude-plugin/marketplace.json")" = MKITConsulting/zensu-claude-code
test "$(jq -r '.plugins[0].source.ref' "$ROOT/.claude-plugin/marketplace.json")" = "v$PLUGIN_VERSION"
grep -q 'create-local-marketplace-fixture.js' "$EVAL_DIR/lib/provision-installed-plugin.sh"
grep -q 'plugin marketplace add "$MARKETPLACE_ROOT"' "$EVAL_DIR/lib/provision-installed-plugin.sh"
grep -q 'plugin install "$PLUGIN_ID" --scope user' "$EVAL_DIR/lib/provision-installed-plugin.sh"
grep -q 'plugin list --json' "$EVAL_DIR/lib/provision-installed-plugin.sh"
if grep -q -- '--plugin-dir' "$ROOT/scripts/session-control-claude-wrapper.sh"; then
  echo 'Session Control wrapper must load only from the isolated installed-plugin registry' >&2
  exit 1
fi
for workflow in "$ROOT/.github/workflows/session-control-nightly.yml" "$ROOT/.github/workflows/release.yml"; do
  grep -q '@anthropic-ai/claude-code@2.1.211' "$workflow"
done

node "$EVAL_DIR/tests/attestation.test.js"
node "$EVAL_DIR/tests/contract-provider.test.js"
node "$EVAL_DIR/tests/concurrency-barrier-selftest.js"
node "$EVAL_DIR/tests/results.test.js"
node "$EVAL_DIR/tests/live-evidence-negative.test.js"
bash "$EVAL_DIR/tests/preflight-selftest.sh"
bash "$EVAL_DIR/tests/marketplace-fixture-selftest.sh"
bash "$EVAL_DIR/tests/installed-plugin-provisioner-selftest.sh"
bash "$EVAL_DIR/tests/wrapper-selftest.sh"
printf 'session-control self-check: PASS\n'
