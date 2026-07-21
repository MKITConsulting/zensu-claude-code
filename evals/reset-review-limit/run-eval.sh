#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
PROMPTFOO="$ROOT/node_modules/.bin/promptfoo"
test -x "$PROMPTFOO" || { echo 'reset-review-limit eval: run npm ci first' >&2; exit 127; }
test "${ZENSU_E2E_DISPOSABLE_ENVIRONMENT:-0}" = 1 || {
  echo 'reset-review-limit eval: set ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 only on a disposable live-eval host' >&2
  exit 64
}

STATE="$(mktemp -d -t zensu-reset-review-promptfoo-XXXXXX)"
trap 'rm -rf "$STATE"' EXIT
export PROMPTFOO_CONFIG_DIR="$STATE/config"
export PROMPTFOO_DISABLE_TELEMETRY=1
export PROMPTFOO_DISABLE_UPDATE=1
export ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1
mkdir -p "$PROMPTFOO_CONFIG_DIR"

RESULT="$STATE/results.json"
cd "$EVAL_DIR"
"$PROMPTFOO" eval --config promptfooconfig.yaml --no-cache --no-share --no-write \
  --no-progress-bar --output "$RESULT" "$@"
node "$EVAL_DIR/verify-results.js" "$RESULT"
