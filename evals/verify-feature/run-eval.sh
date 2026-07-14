#!/bin/bash
set -euo pipefail

# Test-only escape hatches must never cross into the live runner.
unset ZENSU_WRAPPER_TEST_MODE ZENSU_WRAPPER_TEST_KILL_WATCHER \
  ZENSU_MCP_TEST_MODE ZENSU_MCP_TEST_PASSTHROUGH ZENSU_MCP_RUNTIME_DIR_OVERRIDE

if [ "${ZENSU_E2E_DISPOSABLE_ENVIRONMENT:-0}" != "1" ]; then
  echo "verify-feature eval: Claude runs with unrestricted host permissions; use a disposable environment and set ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 to acknowledge that boundary" >&2
  exit 64
fi

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
OWNED_PROCESS="$PLUGIN_DIR/scripts/owned-process.js"
PROMPTFOO_STATE="$(mktemp -d -t zensu-verify-feature-promptfoo-XXXXXX)"
RESERVATION_PID=""
PROMPTFOO_PID=""

terminate_owned_process() {
  local pid="$1" watchdog
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || true
  ( sleep 8; kill -KILL "$pid" 2>/dev/null || true ) &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

cleanup() {
  [ -n "$PROMPTFOO_PID" ] && terminate_owned_process "$PROMPTFOO_PID" || true
  [ -n "$RESERVATION_PID" ] && kill "$RESERVATION_PID" 2>/dev/null || true
  [ -n "$RESERVATION_PID" ] && wait "$RESERVATION_PID" 2>/dev/null || true
  rm -rf "$PROMPTFOO_STATE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

for cli in promptfoo claude jq node npm git curl; do
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "verify-feature eval: required CLI '$cli' is not on PATH" >&2
    exit 127
  fi
done

# Prepare the integrity-checked MCP dependency before Claude enters the immutable
# fixture sandbox, where package installation is intentionally impossible.
bash "$PLUGIN_DIR/scripts/playwright-mcp.sh" --zensu-install-runtime

export ZENSU_PLUGIN_DIR_OVERRIDE="$PLUGIN_DIR"
export PROMPTFOO_CONFIG_DIR="$PROMPTFOO_STATE"
export PROMPTFOO_DISABLE_TELEMETRY=1
PORT_FILE="$PROMPTFOO_STATE/fixture-port"
export ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF="$PROMPTFOO_STATE/fixture-port.handoff"
export ZENSU_VERIFY_FIXTURE_RESERVATION_ACK="$PROMPTFOO_STATE/fixture-port.ready"
export ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(16).toString("hex"))')"
node "$EVAL_DIR/port-reservation.js" "$PORT_FILE" "$ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF" \
  "$ZENSU_VERIFY_FIXTURE_RESERVATION_ACK" "$ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN" &
RESERVATION_PID=$!
for ((attempt=0; attempt<200; attempt++)); do
  [ -s "$PORT_FILE" ] && break
  kill -0 "$RESERVATION_PID" 2>/dev/null || break
  sleep 0.01
done
[ -s "$PORT_FILE" ] || { echo "verify-feature eval: failed to reserve fixture port" >&2; exit 1; }
export ZENSU_VERIFY_FIXTURE_PORT="$(sed -n '1p' "$PORT_FILE")"
export ZENSU_VERIFY_NAVIGATION_POLICY_V1="$(printf '{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:%s","evidenceMode":"declared-safe","routes":["/"]}]}' "$ZENSU_VERIFY_FIXTURE_PORT")"

cd "$EVAL_DIR"
node "$OWNED_PROCESS" promptfoo eval \
  --config promptfooconfig.yaml \
  --no-cache \
  --no-share \
  --no-write \
  --no-progress-bar \
  "$@" &
PROMPTFOO_PID=$!
if wait "$PROMPTFOO_PID"; then
  PROMPTFOO_RC=0
else
  PROMPTFOO_RC=$?
fi
PROMPTFOO_PID=""
exit "$PROMPTFOO_RC"
