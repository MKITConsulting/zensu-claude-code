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
unset CLAUDE_PLUGIN_DATA_OVERRIDE

SID="smoke-rounds-loc"
STDIN="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID}\"}"

printf '%s' "$STDIN" | CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT" >/dev/null 2>&1
EXIT=$?

if [ "$EXIT" = "0" ]; then
  check "C1: hook exits 0 with both CLAUDE_PLUGIN_DATA and CLAUDE_PLUGIN_DATA_OVERRIDE unset + CLAUDE_PROJECT_DIR set" PASS
else
  check "C1: hook exits 0 (got $EXIT)" FAIL
fi

EXPECTED="$PROJECT_DIR/.zensu/state/rounds-${SID}.json"
UNEXPECTED="$FAKE_HOME/.zensu/state/rounds-${SID}.json"

if [ -f "$EXPECTED" ]; then
  check "C2: counter file written to CLAUDE_PROJECT_DIR/.zensu/state (project-local default)" PASS
else
  check "C2: counter file expected at $EXPECTED" FAIL
fi

if [ -f "$UNEXPECTED" ]; then
  check "C3: counter file MUST NOT leak to \$HOME/.zensu/state (got $UNEXPECTED)" FAIL
else
  check "C3: counter file does not leak to \$HOME/.zensu/state" PASS
fi

if [ -f "$EXPECTED" ]; then
  COUNT="$(node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(j && j.count);
    } catch (_) { console.log(""); }
  ' "$EXPECTED" 2>/dev/null)"
  if [ "$COUNT" = "1" ]; then
    check "C4: project-local counter has count=1 after first invocation" PASS
  else
    check "C4: project-local counter count=1 (got '$COUNT')" FAIL
  fi
fi

PLUGIN_DATA_DIR_C6="$(mktemp -d)"
SID_C6="smoke-rounds-ignore-pluginedata"
STDIN_C6="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_C6}\"}"
printf '%s' "$STDIN_C6" | CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_DIR_C6" CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT" >/dev/null 2>&1
EXIT_C6=$?
PROJ_LOCAL_C6="$PROJECT_DIR/.zensu/state/rounds-${SID_C6}.json"
LEAK_PLUGIN_C6="$PLUGIN_DATA_DIR_C6/rounds-${SID_C6}.json"

if [ "$EXIT_C6" = "0" ]; then
  check "C6a: hook exits 0 when only CLAUDE_PLUGIN_DATA set (no OVERRIDE)" PASS
else
  check "C6a: hook exits 0 (got $EXIT_C6)" FAIL
fi

if [ -f "$PROJ_LOCAL_C6" ]; then
  check "C6b: counter written to CLAUDE_PROJECT_DIR/.zensu/state even when CLAUDE_PLUGIN_DATA set" PASS
else
  check "C6b: counter expected at $PROJ_LOCAL_C6" FAIL
fi

if [ -f "$LEAK_PLUGIN_C6" ]; then
  check "C6c: counter MUST NOT write to CLAUDE_PLUGIN_DATA (claude-code's auto-set value is ignored)" FAIL
else
  check "C6c: counter ignored CLAUDE_PLUGIN_DATA (no file at $LEAK_PLUGIN_C6)" PASS
fi
rm -rf "$PLUGIN_DATA_DIR_C6"
unset CLAUDE_PLUGIN_DATA

OVERRIDE_DIR_C7="$(mktemp -d)/state"
mkdir -p "$OVERRIDE_DIR_C7"
SID_C7="smoke-rounds-override-wins"
STDIN_C7="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_C7}\"}"
printf '%s' "$STDIN_C7" | CLAUDE_PLUGIN_DATA_OVERRIDE="$OVERRIDE_DIR_C7" CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT" >/dev/null 2>&1
OVERRIDE_FILE_C7="$OVERRIDE_DIR_C7/rounds-${SID_C7}.json"
PROJ_LEAK_C7="$PROJECT_DIR/.zensu/state/rounds-${SID_C7}.json"

if [ -f "$OVERRIDE_FILE_C7" ]; then
  check "C7a: CLAUDE_PLUGIN_DATA_OVERRIDE explicit override wins over project-local default" PASS
else
  check "C7a: counter expected at $OVERRIDE_FILE_C7" FAIL
fi

if [ -f "$PROJ_LEAK_C7" ]; then
  check "C7b: counter MUST NOT leak to project-local when OVERRIDE is set" FAIL
else
  check "C7b: counter does not leak to project-local when OVERRIDE is set" PASS
fi
rm -rf "$(dirname "$OVERRIDE_DIR_C7")"
unset CLAUDE_PLUGIN_DATA_OVERRIDE

PLUGIN_DATA_DIR_C8="$(mktemp -d)"
OVERRIDE_DIR_C8="$(mktemp -d)/state"
mkdir -p "$OVERRIDE_DIR_C8"
SID_C8="smoke-rounds-override-beats-both"
STDIN_C8="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_C8}\"}"
printf '%s' "$STDIN_C8" | CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_DIR_C8" CLAUDE_PLUGIN_DATA_OVERRIDE="$OVERRIDE_DIR_C8" \
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT" >/dev/null 2>&1
OVERRIDE_FILE_C8="$OVERRIDE_DIR_C8/rounds-${SID_C8}.json"
PLUGIN_LEAK_C8="$PLUGIN_DATA_DIR_C8/rounds-${SID_C8}.json"
PROJ_LEAK_C8="$PROJECT_DIR/.zensu/state/rounds-${SID_C8}.json"

if [ -f "$OVERRIDE_FILE_C8" ]; then
  check "C8a: OVERRIDE wins when both CLAUDE_PLUGIN_DATA and CLAUDE_PLUGIN_DATA_OVERRIDE set" PASS
else
  check "C8a: counter expected at $OVERRIDE_FILE_C8" FAIL
fi

if [ -f "$PLUGIN_LEAK_C8" ]; then
  check "C8b: counter MUST NOT write to CLAUDE_PLUGIN_DATA when OVERRIDE wins" FAIL
else
  check "C8b: counter does not write to CLAUDE_PLUGIN_DATA when OVERRIDE wins" PASS
fi

if [ -f "$PROJ_LEAK_C8" ]; then
  check "C8c: counter MUST NOT write to project-local when OVERRIDE wins" FAIL
else
  check "C8c: counter does not write to project-local when OVERRIDE wins" PASS
fi
rm -rf "$PLUGIN_DATA_DIR_C8" "$(dirname "$OVERRIDE_DIR_C8")"
unset CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_DATA_OVERRIDE

echo "----"
echo "test-rounds-default-location: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
