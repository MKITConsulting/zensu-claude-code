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
  echo "test-autofix-rounds-sanitize: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
ESCAPE_PROBE="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
  rm -rf "$ESCAPE_PROBE"
}
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA="$TMP_DIR/state"
mkdir -p "$CLAUDE_PLUGIN_DATA"
TMP_CFG="$TMP_DIR/config.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 10}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

MALICIOUS_SID="../../../${ESCAPE_PROBE##*/}/escape-XYZ"
STDIN_JSON="$(node -e '
  const sid = process.argv[1];
  process.stdout.write(JSON.stringify({
    tool_name: "Task",
    tool_input: { subagent_type: "zensu:code-reviewer", prompt: "x" },
    session_id: sid
  }));
' "$MALICIOUS_SID")"

printf '%s' "$STDIN_JSON" | "$SCRIPT" >/dev/null 2>&1
EXIT_CODE=$?

if [ "$EXIT_CODE" = "0" ]; then
  check "hook exits 0 with malicious session_id" PASS
else
  check "hook exits 0 with malicious session_id (got $EXIT_CODE)" FAIL
fi

INSIDE_COUNT="$(find "$CLAUDE_PLUGIN_DATA" -name 'rounds-*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$INSIDE_COUNT" = "1" ]; then
  check "exactly 1 counter file created inside CLAUDE_PLUGIN_DATA" PASS
else
  check "exactly 1 counter file inside CLAUDE_PLUGIN_DATA (got $INSIDE_COUNT)" FAIL
fi

OUTSIDE_COUNT="$(find "$ESCAPE_PROBE" -name 'escape-XYZ*' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$OUTSIDE_COUNT" = "0" ]; then
  check "no counter file escaped to ESCAPE_PROBE outside CLAUDE_PLUGIN_DATA" PASS
else
  check "counter file escaped outside CLAUDE_PLUGIN_DATA (found $OUTSIDE_COUNT in $ESCAPE_PROBE)" FAIL
fi

ORPHAN_COUNT="$(find "$CLAUDE_PLUGIN_DATA" -name 'rounds-*' -not -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ORPHAN_COUNT" = "0" ]; then
  check "no orphan mktemp artifacts left in state dir" PASS
else
  check "no orphan mktemp artifacts in state dir (got $ORPHAN_COUNT)" FAIL
fi

echo "----"
echo "test-autofix-rounds-sanitize: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
