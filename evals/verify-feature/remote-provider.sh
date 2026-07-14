#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

export ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1,"mode":"remote","targets":[{"origin":"https://example.com","evidenceMode":"declared-safe","routes":["/"]}]}'
exec "$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh" "$@"
