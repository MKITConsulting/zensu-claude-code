#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"
export ZENSU_CONFIG="$TMP_DIR/config.json"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
printf '%s\n' '{"hooks":{"autoFix":true,"autoFixMaxRounds":99}}' > "$ZENSU_CONFIG"

SID="sess-cas-parallel-review-round"
KEY="$(node "$CORE" session-key "$SID")"
STATE_FILE="$STATE_DIR/tdd-phase-${KEY}.json"
# shellcheck disable=SC1090
source "$BASELINE" "$SID"
STATE_DIR="$ZENSU_PROJECT_ROOT/.zensu/state"
STATE_FILE="$STATE_DIR/tdd-phase-${KEY}.json"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1 || {
  check "active workflow seed succeeds" FAIL
  exit 1
}
check "active workflow seed succeeds" PASS

read_field() {
  CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$SID" FIELD="$1" node -e '
    const core = require(process.env.CONTROL_CORE);
    const state = core.readWorkflowState({projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID});
    process.stdout.write(String(state[process.env.FIELD]));
  '
}

BEFORE_REV="$(read_field revision)"
PAYLOAD="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID}\"}"
PIDS=""
for i in $(seq 1 4); do
  printf '%s' "$PAYLOAD" | "$SCRIPT" >"$TMP_DIR/out.$i" 2>"$TMP_DIR/err.$i" &
  PIDS="$PIDS $!"
done
FAILED=0
for pid in $PIDS; do
  wait "$pid" || FAILED=$((FAILED + 1))
done
[ "$FAILED" -eq 0 ] && check "four concurrent reviewer completions all succeed" PASS \
  || check "four concurrent reviewer completions all succeed (failures=$FAILED)" FAIL

ROUND="$(read_field reviewRound 2>/dev/null || true)"
AFTER_REV="$(read_field revision 2>/dev/null || true)"
STOP_BLOCKS="$(read_field stopBlocks 2>/dev/null || true)"
[ "$ROUND" = 4 ] && check "CAS reviewRound reaches 4 without a lost update" PASS \
  || check "CAS reviewRound reaches 4 without a lost update (got $ROUND)" FAIL
[ "$AFTER_REV" = "$((BEFORE_REV + 4))" ] && check "each concurrent increment advances the shared revision exactly once" PASS \
  || check "each concurrent increment advances revision by 4 (before=$BEFORE_REV after=$AFTER_REV)" FAIL
[ "$STOP_BLOCKS" = 0 ] && check "review progress resets integrated stopBlocks" PASS \
  || check "review progress resets integrated stopBlocks (got $STOP_BLOCKS)" FAIL

if find "$STATE_DIR" -maxdepth 1 \( -name 'rounds-*' -o -name '*.stopblocks' \) | grep -q .; then
  check "no retired rounds/stopblocks sidecar is created" FAIL
else
  check "no retired rounds/stopblocks sidecar is created" PASS
fi
if [ -f "$STATE_FILE" ]; then check "one canonical workflow document owns the counters" PASS
else check "one canonical workflow document owns the counters" FAIL; fi

echo "----"
echo "test-autofix-rounds-increment: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
