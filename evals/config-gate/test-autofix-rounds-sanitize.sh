#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
POST_REVIEW="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
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
export STATE_DIR="$TMP_DIR/state"
export ZENSU_CONFIG="$TMP_DIR/config.json"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
printf '%s\n' '{"hooks":{"autoFix":true,"autoFixMaxRounds":10}}' > "$ZENSU_CONFIG"

tamper() {
  FIELD="$2" VALUE="$3" node -e '
    const fs = require("fs");
    const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    state[process.env.FIELD] = JSON.parse(process.env.VALUE);
    fs.writeFileSync(process.argv[1], JSON.stringify(state) + "\n");
  ' "$1"
}

# A string-valued reviewRound must invalidate the whole document. The
# post-review hook must fail instead of coercing or resetting it.
SID_R="tampered-review-round"
KEY_R="$(node "$CORE" session-key "$SID_R")"
STATE_R="$STATE_DIR/tdd-phase-${KEY_R}.json"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_R"
STATE_DIR="$ZENSU_PROJECT_ROOT/.zensu/state"
STATE_R="$STATE_DIR/tdd-phase-${KEY_R}.json"
bash "$LOG" --tdd-begin --session "$SID_R" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_R" >/dev/null 2>&1
TICKET_R="$(bash "$LOG" --review-ticket --session "$SID_R")"
tamper "$STATE_R" reviewRound '"2"'
cp "$STATE_R" "$TMP_DIR/review-state-before.json"
PAYLOAD_R="{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET_R}\\nfixture\"},\"session_id\":\"${SID_R}\"}"
printf '%s' "$PAYLOAD_R" | "$POST_REVIEW" >"$TMP_DIR/review.out" 2>"$TMP_DIR/review.err"
POST_REVIEW_RC=$?
if [ "$POST_REVIEW_RC" -eq 0 ] && [ ! -s "$TMP_DIR/review.out" ]; then
  check "string reviewRound makes post-review fail closed" PASS
else
  check "string reviewRound makes post-review fail closed" FAIL
fi
. "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
[ "$(tdd_state_status "$STATE_R")" = invalid ] && check "canonical reader rejects manipulated reviewRound" PASS \
  || check "canonical reader rejects manipulated reviewRound" FAIL
cmp -s "$TMP_DIR/review-state-before.json" "$STATE_R" \
  && check "failed mutation leaves corrupt state byte-identical" PASS \
  || check "failed mutation leaves corrupt state byte-identical" FAIL

# A negative stopBlockCount value must make Stop block on integrity, independently
# of the normal anti-deadlock budget.
SID_S="tampered-stop-blocks"
KEY_S="$(node "$CORE" session-key "$SID_S")"
STATE_S="$STATE_DIR/tdd-phase-${KEY_S}.json"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_S"
STATE_S="$STATE_DIR/tdd-phase-${KEY_S}.json"
bash "$LOG" --tdd-begin --session "$SID_S" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_S" >/dev/null 2>&1
tamper "$STATE_S" stopBlockCount '-1'
PAYLOAD_S="{\"hook_event_name\":\"Stop\",\"session_id\":\"${SID_S}\",\"cwd\":\"${CLAUDE_PROJECT_DIR}\"}"
STOP_OUT="$(printf '%s' "$PAYLOAD_S" | "$STOP" 2>/dev/null)"
case "$STOP_OUT" in
  *'"decision":"block"'*'corrupt or unsafe'*) check "negative stopBlockCount makes Stop fail closed" PASS ;;
  *) check "negative stopBlockCount makes Stop fail closed (got $STOP_OUT)" FAIL ;;
esac
[ "$(tdd_get_counter "$STATE_S" stopBlockCount)" = invalid ] && check "counter reader exposes manipulated stopBlockCount only as invalid" PASS \
  || check "counter reader exposes manipulated stopBlockCount only as invalid" FAIL

# The upper bound is part of the persisted schema, not only the increment path.
SID_B="tampered-review-bound"
KEY_B="$(node "$CORE" session-key "$SID_B")"
STATE_B="$STATE_DIR/tdd-phase-${KEY_B}.json"
# shellcheck disable=SC1090
source "$BASELINE" "$SID_B"
STATE_B="$STATE_DIR/tdd-phase-${KEY_B}.json"
bash "$LOG" --tdd-begin --session "$SID_B" >/dev/null 2>&1
tamper "$STATE_B" reviewRound '1000001'
[ "$(tdd_state_status "$STATE_B")" = invalid ] && check "out-of-range reviewRound invalidates persisted state" PASS \
  || check "out-of-range reviewRound invalidates persisted state" FAIL

echo "----"
echo "test-autofix-rounds-sanitize: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
