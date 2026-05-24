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
  echo "test-rounds-default-location: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
FAKE_HOME="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR" "$FAKE_HOME"; }
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/proj"
mkdir -p "$PROJECT_DIR"

CFG="$TMP_DIR/config.json"
cat > "$CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 10}}
EOF

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$CFG"
export HOME="$FAKE_HOME"
unset CLAUDE_PLUGIN_DATA

SID="smoke-rounds-loc"
STDIN="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID}\"}"

printf '%s' "$STDIN" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT" >/dev/null 2>&1
EXIT=$?

if [ "$EXIT" = "0" ]; then
  check "hook exits 0 with CLAUDE_PLUGIN_DATA unset + CLAUDE_PROJECT_DIR set" PASS
else
  check "hook exits 0 (got $EXIT)" FAIL
fi

EXPECTED="$PROJECT_DIR/.zensu/state/rounds-${SID}.json"
UNEXPECTED="$FAKE_HOME/.zensu/state/rounds-${SID}.json"

if [ -f "$EXPECTED" ]; then
  check "counter file written to CLAUDE_PROJECT_DIR/.zensu/state (project-local default)" PASS
else
  check "counter file expected at $EXPECTED" FAIL
fi

if [ -f "$UNEXPECTED" ]; then
  check "counter file MUST NOT leak to \$HOME/.zensu/state (got $UNEXPECTED)" FAIL
else
  check "counter file does not leak to \$HOME/.zensu/state" PASS
fi

if [ -f "$EXPECTED" ]; then
  COUNT="$(node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(j && j.count);
    } catch (_) { console.log(""); }
  ' "$EXPECTED" 2>/dev/null)"
  if [ "$COUNT" = "1" ]; then
    check "project-local counter has count=1 after first invocation" PASS
  else
    check "project-local counter count=1 (got '$COUNT')" FAIL
  fi
fi

TMP_OVERRIDE="$(mktemp -d)"
export CLAUDE_PLUGIN_DATA="$TMP_OVERRIDE/state"
mkdir -p "$CLAUDE_PLUGIN_DATA"
SID_OV="smoke-rounds-override"
STDIN_OV="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_OV}\"}"
printf '%s' "$STDIN_OV" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT" >/dev/null 2>&1
OVERRIDE_FILE="$CLAUDE_PLUGIN_DATA/rounds-${SID_OV}.json"
PROJ_LEAK="$PROJECT_DIR/.zensu/state/rounds-${SID_OV}.json"
if [ -f "$OVERRIDE_FILE" ] && [ ! -f "$PROJ_LEAK" ]; then
  check "CLAUDE_PLUGIN_DATA explicit override still wins over project-local default" PASS
else
  check "CLAUDE_PLUGIN_DATA override (override=$([ -f "$OVERRIDE_FILE" ] && echo yes || echo no), proj_leak=$([ -f "$PROJ_LEAK" ] && echo yes || echo no))" FAIL
fi
rm -rf "$TMP_OVERRIDE"
unset CLAUDE_PLUGIN_DATA

echo "----"
echo "test-rounds-default-location: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
