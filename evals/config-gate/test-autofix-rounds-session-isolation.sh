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
printf '%s\n' '{"hooks":{"autoFix":true,"autoFixMaxRounds":5}}' > "$ZENSU_CONFIG"

payload() {
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"%s"}' "$1"
}
# shellcheck disable=SC1090
source "$BASELINE" sess-A
SESSION_RECORDS="$(dirname "$ZENSU_SESSION_CONTEXT")"
bash "$LOG" --tdd-begin --session sess-A >/dev/null 2>&1
payload sess-A | "$SCRIPT" >/dev/null 2>&1

# shellcheck disable=SC1090
source "$BASELINE" sess-B
bash "$LOG" --tdd-begin --session sess-B >/dev/null 2>&1
payload sess-B | "$SCRIPT" >/dev/null 2>&1

export ZENSU_SESSION_KEY="$(node "$CORE" session-key sess-A)"
export ZENSU_SESSION_CONTEXT="$SESSION_RECORDS/$ZENSU_SESSION_KEY.json"
payload sess-A | "$SCRIPT" >/dev/null 2>&1

KEY_A="$(node "$CORE" session-key sess-A)"
KEY_B="$(node "$CORE" session-key sess-B)"
STATE_A="$STATE_DIR/tdd-phase-${KEY_A}.json"
STATE_B="$STATE_DIR/tdd-phase-${KEY_B}.json"
[ -f "$STATE_A" ] && [ -f "$STATE_B" ] && check "two sessions retain distinct canonical workflow documents" PASS \
  || check "two sessions retain distinct canonical workflow documents" FAIL

read_round() {
  CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$1" node -e '
    const core = require(process.env.CONTROL_CORE);
    const state = core.readWorkflowState({projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID});
    process.stdout.write(String(state.reviewRound));
  '
}
ROUND_A="$(read_round sess-A 2>/dev/null || true)"
ROUND_B="$(read_round sess-B 2>/dev/null || true)"
[ "$ROUND_A" = 2 ] && check "session A integrated reviewRound reaches 2" PASS \
  || check "session A integrated reviewRound reaches 2 (got $ROUND_A)" FAIL
[ "$ROUND_B" = 1 ] && check "session B remains isolated at reviewRound 1" PASS \
  || check "session B remains isolated at reviewRound 1 (got $ROUND_B)" FAIL

if find "$STATE_DIR" -maxdepth 1 \( -name 'rounds-*' -o -name '*.stopblocks' \) | grep -q .; then
  check "session isolation uses no retired sidecars" FAIL
else
  check "session isolation uses no retired sidecars" PASS
fi

echo "----"
echo "test-autofix-rounds-session-isolation: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
