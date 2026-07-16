#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
OPTIONS_JSON="${2:-}"
[ -n "$OPTIONS_JSON" ] || OPTIONS_JSON='{}'
SCENARIO_ID="$(printf '%s' "$OPTIONS_JSON" | jq -er '.vars.scenario_id // .config.vars.scenario_id // empty')" \
  || { echo 'reset-review-limit provider: scenario_id is required' >&2; exit 2; }
case "$SCENARIO_ID" in
  reset-cas-happy|reset-invalid-state|reset-sidecar-isolation) ;;
  *) echo 'reset-review-limit provider: unsupported scenario_id' >&2; exit 2 ;;
esac

export ZENSU_RESET_REVIEW_LIMIT_ATTESTATION=1
export ZENSU_RESET_REVIEW_LIMIT_SCENARIO="$SCENARIO_ID"
export ZENSU_PLUGIN_DIR_OVERRIDE="$ROOT"
exec "$ROOT/scripts/claude-promptfoo-wrapper.sh" "$@"
