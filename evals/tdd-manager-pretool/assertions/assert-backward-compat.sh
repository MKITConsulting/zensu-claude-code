#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
COMPLIANCE="$PLUGIN_DIR/evals/tdd-review-chain/assert-tdd-log-compliance.sh"

if [ ! -x "$COMPLIANCE" ]; then
  echo "missing $COMPLIANCE" >&2
  exit 2
fi

LOG_PATH="${1:-}"
if [ -z "$LOG_PATH" ] || [ ! -f "$LOG_PATH" ]; then
  echo "usage: $0 <generated-log-path>" >&2
  exit 2
fi

"$COMPLIANCE" --log "$LOG_PATH"
