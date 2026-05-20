#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-autofix-rounds-increment: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA="$TMP_DIR/state"
TMP_CFG="$TMP_DIR/config.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 10}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

SID="sess-incr-xyz"
COUNTER_FILE="$CLAUDE_PLUGIN_DATA/rounds-${SID}.json"
STDIN="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID}\"}"

read_count() {
  node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(j && j.count);
    } catch (_) { console.log(""); }
  ' "$1" 2>/dev/null
}

for i in 1 2 3; do
  printf '%s' "$STDIN" | "$SCRIPT" >/dev/null 2>&1
  c="$(read_count "$COUNTER_FILE")"
  if [ "$c" = "$i" ]; then
    check "after invocation $i: counter file count=$i" PASS
  else
    check "after invocation $i: counter file count=$i (got '$c')" FAIL
  fi
done

if [ -f "$COUNTER_FILE" ]; then
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$COUNTER_FILE" 2>/dev/null; then
    check "counter file is valid JSON after writes" PASS
  else
    check "counter file is valid JSON after writes" FAIL
  fi

  if node -e '
    const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if (typeof j.ts === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(j.ts)) {
      process.exit(0);
    }
    process.exit(1);
  ' "$COUNTER_FILE" 2>/dev/null; then
    check "counter file has ISO-UTC timestamp" PASS
  else
    check "counter file has ISO-UTC timestamp" FAIL
  fi
else
  check "counter file present after invocations" FAIL
fi

orphans="$(find "$CLAUDE_PLUGIN_DATA" -name 'rounds-'"${SID}"'.*' -not -name 'rounds-'"${SID}"'.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$orphans" = "0" ]; then
  check "no orphaned mktemp artifacts left in state dir" PASS
else
  check "no orphaned mktemp artifacts left in state dir (found $orphans)" FAIL
fi

echo "----"
echo "test-autofix-rounds-increment: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
