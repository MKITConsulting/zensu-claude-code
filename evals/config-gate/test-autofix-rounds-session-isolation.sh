#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-autofix-rounds-session-isolation: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA="$TMP_DIR/state"
TMP_CFG="$TMP_DIR/config.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

STDIN_A='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-A"}'
STDIN_B='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-B"}'

printf '%s' "$STDIN_A" | "$SCRIPT" >/dev/null 2>&1
printf '%s' "$STDIN_B" | "$SCRIPT" >/dev/null 2>&1

COUNTER_A="$CLAUDE_PLUGIN_DATA/rounds-sess-A.json"
COUNTER_B="$CLAUDE_PLUGIN_DATA/rounds-sess-B.json"

if [ -f "$COUNTER_A" ] && [ -f "$COUNTER_B" ]; then
  check "two distinct counter files exist after two sessions" PASS
else
  check "two distinct counter files exist (A=$COUNTER_A, B=$COUNTER_B)" FAIL
fi

read_count() {
  node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(j && j.count);
    } catch (_) { console.log(""); }
  ' "$1" 2>/dev/null
}

cA="$(read_count "$COUNTER_A")"
cB="$(read_count "$COUNTER_B")"

if [ "$cA" = "1" ]; then
  check "session A counter starts at 1 (isolated from B)" PASS
else
  check "session A counter starts at 1 (got '$cA')" FAIL
fi

if [ "$cB" = "1" ]; then
  check "session B counter starts at 1 (isolated from A)" PASS
else
  check "session B counter starts at 1 (got '$cB')" FAIL
fi

printf '%s' "$STDIN_A" | "$SCRIPT" >/dev/null 2>&1
cA2="$(read_count "$COUNTER_A")"
cB2="$(read_count "$COUNTER_B")"

if [ "$cA2" = "2" ]; then
  check "session A second invocation increments A to 2" PASS
else
  check "session A second invocation increments A to 2 (got '$cA2')" FAIL
fi

if [ "$cB2" = "1" ]; then
  check "session B counter unaffected by session A invocations" PASS
else
  check "session B counter unaffected by session A invocations (got '$cB2')" FAIL
fi

echo "----"
echo "test-autofix-rounds-session-isolation: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
