#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
MODE="${1:-}"
STATE="$(mktemp -d -t zensu-reset-review-selfcheck-XXXXXX)"
trap 'rm -rf "$STATE"' EXIT
case "$MODE" in
  ""|--ci) ;;
  *) printf 'usage: %s [--ci]\n' "$0" >&2; exit 2 ;;
esac
if [ "$MODE" != "--ci" ]; then
  PROMPTFOO_CONFIG_DIR="$STATE" PROMPTFOO_DISABLE_TELEMETRY=1 PROMPTFOO_DISABLE_UPDATE=1 \
    "$ROOT/node_modules/.bin/promptfoo" validate config --config "$EVAL_DIR/promptfooconfig.yaml" >/dev/null
fi
node "$EVAL_DIR/tests/sealed-evidence.test.js"
node "$EVAL_DIR/tests/results.test.js"
bash "$EVAL_DIR/tests/barrier-selftest.sh"
PROVIDER_PREVIEW="$({
  cd "$EVAL_DIR" || exit 1
  ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 DRY_RUN=1 ./provider.sh probe \
    '{"config":{"working_dir":"./test-projects/empty-host"},"vars":{"scenario_id":"reset-cas-happy"}}'
})"
printf '%s' "$PROVIDER_PREVIEW" | grep -Fq 'cwd=./test-projects/empty-host'
printf '%s' "$PROVIDER_PREVIEW" | grep -Eq 'claude[[:space:]]+--print.*probe'
printf 'reset-review-limit self-check: PASS\n'
