#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/session-start-pulse.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "session-start-pulse.sh exists and is executable" FAIL
  echo "----"
  echo "test-gate-session: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "session-start-pulse.sh exists and is executable" PASS

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

TMP_CFG="/tmp/zensu-gate-session-disabled-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"pulseSession": false}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

OUT_DISABLED="$(env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
EXIT_DISABLED=$?

case "$OUT_DISABLED" in
  *"Pulse context available"*) check "pulseSession=false: stdout does NOT contain Pulse context" FAIL ;;
  *)                           check "pulseSession=false: stdout does NOT contain Pulse context" PASS ;;
esac

if [ "$EXIT_DISABLED" = "0" ]; then
  check "pulseSession=false: exit code 0" PASS
else
  check "pulseSession=false: exit code 0" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"pulseSession": true}}
EOF

OUT_ENABLED="$(cd "$PLUGIN_DIR" && env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
EXIT_ENABLED=$?

case "$OUT_ENABLED" in
  *"Pulse context available"*|*"not a git repository"*) check "pulseSession=true: stdout contains context (or graceful 'not a git' skip)" PASS ;;
  *)                                                     check "pulseSession=true: stdout contains context (or graceful 'not a git' skip)" FAIL ;;
esac

unset ZENSU_CONFIG
NOTHING_CFG="/tmp/zensu-no-config-session-$$.json"
rm -f "$NOTHING_CFG"
export ZENSU_CONFIG="$NOTHING_CFG"
OUT_DEFAULT="$(cd "$PLUGIN_DIR" && env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
case "$OUT_DEFAULT" in
  *"Pulse context available"*|*"not a git repository"*) check "no config (default): stdout contains context (enabled)" PASS ;;
  *)                                                     check "no config (default): stdout contains context (enabled)" FAIL ;;
esac

rm -f "$TMP_CFG"

echo "----"
echo "test-gate-session: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
