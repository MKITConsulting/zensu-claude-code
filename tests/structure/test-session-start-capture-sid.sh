#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/session-start-capture-sid.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/session-start-capture-sid.sh exists" FAIL
  echo "----"
  echo "test-session-start-capture-sid: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S3-C0 hooks/session-start-capture-sid.sh exists" PASS

if bash -n "$HOOK" 2>/dev/null; then
  check "S3-C1 bash -n syntax check on session-start-capture-sid.sh" PASS
else
  check "S3-C1 bash -n syntax check on session-start-capture-sid.sh" FAIL
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/proj"
mkdir -p "$PROJECT_DIR/.zensu/state"

PAYLOAD='{"session_id":"abc-123-real"}'
printf '%s' "$PAYLOAD" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$HOOK" >/dev/null 2>&1
RC=$?

if [ "$RC" = "0" ]; then
  check "S3-C2a exit code 0 with valid session_id payload" PASS
else
  check "S3-C2a exit code 0 (got $RC)" FAIL
fi

CACHE_COUNT=$(find "$PROJECT_DIR/.zensu/state" -maxdepth 1 -name "session-id-*.txt" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$CACHE_COUNT" = "1" ]; then
  check "S3-C2b exactly 1 cache file written under <project>/.zensu/state/session-id-*.txt" PASS
else
  check "S3-C2b exactly 1 cache file (got $CACHE_COUNT)" FAIL
fi

CACHE_FILE=$(find "$PROJECT_DIR/.zensu/state" -maxdepth 1 -name "session-id-*.txt" -type f 2>/dev/null | head -1)
if [ -n "$CACHE_FILE" ]; then
  CONTENT=$(cat "$CACHE_FILE")
  if [ "$CONTENT" = "abc-123-real" ]; then
    check "S3-C2c cache file contents == captured session_id" PASS
  else
    check "S3-C2c cache file contents (got '$CONTENT')" FAIL
  fi

  CACHE_BASENAME=$(basename "$CACHE_FILE")
  case "$CACHE_BASENAME" in
    session-id-[0-9]*_[0-9]*.txt|session-id-[0-9]*.txt)
      check "S3-C2d cache filename pattern matches session-id-<key>.txt" PASS ;;
    *)
      check "S3-C2d cache filename pattern (got '$CACHE_BASENAME')" FAIL ;;
  esac
fi

PROJECT_DIR3="$TMP_DIR/proj3"
mkdir -p "$PROJECT_DIR3/.zensu/state"
NO_SID_PAYLOAD='{"hookEventName":"SessionStart"}'
printf '%s' "$NO_SID_PAYLOAD" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR3" bash "$HOOK" >/dev/null 2>&1
RC3=$?
NO_SID_COUNT=$(find "$PROJECT_DIR3/.zensu/state" -name "session-id-*.txt" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$RC3" = "0" ] && [ "$NO_SID_COUNT" = "0" ]; then
  check "S3-C3 stdin without session_id -> exit 0, no cache file written" PASS
else
  check "S3-C3 stdin without session_id (rc=$RC3, files=$NO_SID_COUNT)" FAIL
fi

PROJECT_DIR4="$TMP_DIR/proj4"
NODE_STUB_DIR="$TMP_DIR/stub-bin"
mkdir -p "$NODE_STUB_DIR" "$PROJECT_DIR4"
NO_NODE_PAYLOAD='{"session_id":"xyz"}'
RC4=0
printf '%s' "$NO_NODE_PAYLOAD" | env -i PATH="/usr/bin:/bin" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR4" bash "$HOOK" >/dev/null 2>&1
RC4=$?
if [ "$RC4" = "0" ]; then
  check "S3-C4a missing node on PATH -> graceful exit 0" PASS
else
  check "S3-C4a missing node graceful exit (got $RC4)" FAIL
fi

PROJECT_DIR5="$TMP_DIR/missing-proj-dir/nested/very/deep"
EMPTY_PAYLOAD='{"session_id":"deep"}'
printf '%s' "$EMPTY_PAYLOAD" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR5" bash "$HOOK" >/dev/null 2>&1
RC5=$?
if [ "$RC5" = "0" ]; then
  check "S3-C4b non-existent project dir -> graceful exit 0 (mkdir handles or fails silently)" PASS
else
  check "S3-C4b non-existent project dir exit (got $RC5)" FAIL
fi

PROJECT_DIR6="$TMP_DIR/proj6"
mkdir -p "$PROJECT_DIR6/.zensu/state"
EMPTY_STDIN=''
printf '%s' "$EMPTY_STDIN" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJECT_DIR6" bash "$HOOK" >/dev/null 2>&1
RC6=$?
COUNT6=$(find "$PROJECT_DIR6/.zensu/state" -name "session-id-*.txt" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$RC6" = "0" ] && [ "$COUNT6" = "0" ]; then
  check "S3-C5 empty stdin -> exit 0, no cache file written" PASS
else
  check "S3-C5 empty stdin (rc=$RC6 files=$COUNT6)" FAIL
fi

if grep -q "session-start-capture-sid.sh" "$HOOKS_JSON"; then
  check "S3-C6 hooks/hooks.json registers session-start-capture-sid.sh" PASS
else
  check "S3-C6 hooks/hooks.json does not reference session-start-capture-sid.sh" FAIL
fi

if grep -q "session-start-pulse.sh" "$HOOKS_JSON"; then
  check "S3-C6b session-start-pulse.sh still registered (sibling not replaced)" PASS
else
  check "S3-C6b session-start-pulse.sh missing (sibling replaced inadvertently)" FAIL
fi

if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$HOOKS_JSON" 2>/dev/null; then
  check "S3-C7 hooks/hooks.json is valid JSON after edit" PASS
else
  check "S3-C7 hooks/hooks.json invalid JSON after edit" FAIL
fi

echo "----"
echo "test-session-start-capture-sid: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
