#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-autofix-rounds-reset-on-fresh-tdd: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/state"
mkdir -p "$CLAUDE_PLUGIN_DATA_OVERRIDE"
TMP_CFG="$TMP_DIR/config.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoReview": true, "autoFix": true, "autoFixMaxRounds": 5}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

SID="sess-reset-001"
COUNTER_FILE="$CLAUDE_PLUGIN_DATA_OVERRIDE/rounds-${SID}.json"

seed_counter() {
  printf '{"count":4,"ts":"2026-01-01T00:00:00Z"}\n' > "$COUNTER_FILE"
}

counter_count() {
  node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(j && j.count);
    } catch (_) { console.log(""); }
  ' "$COUNTER_FILE" 2>/dev/null
}

# --- Case 1: fresh-task prompt (no sentinel) -> counter deleted ---
seed_counter
FRESH_STDIN="$(node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Task",
    tool_input: {
      subagent_type: "zensu:tdd-manager",
      prompt: "Implement feature X: add a new endpoint that returns the current time."
    },
    session_id: process.argv[1]
  }));
' "$SID")"
FRESH_OUT="$(printf '%s' "$FRESH_STDIN" | "$SCRIPT" 2>/dev/null)"

if [ ! -f "$COUNTER_FILE" ]; then
  check "fresh-task prompt deletes the round counter" PASS
else
  check "fresh-task prompt deletes the round counter (still count=$(counter_count))" FAIL
fi

case "$FRESH_OUT" in
  *"subagent_type='zensu:code-reviewer'"*)
    check "fresh-task stdout still emits the spawn-reviewer directive" PASS ;;
  *)
    check "fresh-task stdout still emits the spawn-reviewer directive (got: $FRESH_OUT)" FAIL ;;
esac

# --- Case 2: fix-round prompt (sentinel present) -> counter preserved ---
seed_counter
FIX_STDIN="$(node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Task",
    tool_input: {
      subagent_type: "zensu:tdd-manager",
      prompt: "Fix the following findings from code review:\n1. foo.sh:10 — bug\n   Fix: do the thing"
    },
    session_id: process.argv[1]
  }));
' "$SID")"
printf '%s' "$FIX_STDIN" | "$SCRIPT" >/dev/null 2>&1

if [ -f "$COUNTER_FILE" ] && [ "$(counter_count)" = "4" ]; then
  check "fix-round prompt preserves the round counter (count stays 4)" PASS
else
  check "fix-round prompt preserves the round counter (present=$([ -f "$COUNTER_FILE" ] && echo y || echo n), count=$(counter_count))" FAIL
fi

# --- Case 3: empty prompt -> counter preserved ---
seed_counter
EMPTY_STDIN="$(node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Task",
    tool_input: { subagent_type: "zensu:tdd-manager", prompt: "" },
    session_id: process.argv[1]
  }));
' "$SID")"
printf '%s' "$EMPTY_STDIN" | "$SCRIPT" >/dev/null 2>&1

if [ -f "$COUNTER_FILE" ] && [ "$(counter_count)" = "4" ]; then
  check "empty prompt preserves the round counter (count stays 4)" PASS
else
  check "empty prompt preserves the round counter (present=$([ -f "$COUNTER_FILE" ] && echo y || echo n), count=$(counter_count))" FAIL
fi

# --- Case 4: non-tdd-manager subagent -> early exit, counter preserved ---
seed_counter
OTHER_STDIN="$(node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Task",
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: "Review the changes in the worktree."
    },
    session_id: process.argv[1]
  }));
' "$SID")"
printf '%s' "$OTHER_STDIN" | "$SCRIPT" >/dev/null 2>&1

if [ -f "$COUNTER_FILE" ] && [ "$(counter_count)" = "4" ]; then
  check "non-tdd-manager subagent preserves the round counter (early exit)" PASS
else
  check "non-tdd-manager subagent preserves the round counter (present=$([ -f "$COUNTER_FILE" ] && echo y || echo n), count=$(counter_count))" FAIL
fi

# --- Case 5: symlink guard -> counter file (symlink) NOT deleted + stderr warning ---
SYMLINK_TARGET="$TMP_DIR/real-counter.json"
printf '{"count":4,"ts":"2026-01-01T00:00:00Z"}\n' > "$SYMLINK_TARGET"
rm -f "$COUNTER_FILE"
ln -s "$SYMLINK_TARGET" "$COUNTER_FILE"
SYM_STDERR="$(printf '%s' "$FRESH_STDIN" | "$SCRIPT" 2>&1 >/dev/null)"

if [ -L "$COUNTER_FILE" ] && [ -f "$SYMLINK_TARGET" ]; then
  check "symlink counter file is NOT followed/deleted (reset path)" PASS
else
  check "symlink counter file is NOT followed/deleted (link present=$([ -L "$COUNTER_FILE" ] && echo y || echo n), target present=$([ -f "$SYMLINK_TARGET" ] && echo y || echo n))" FAIL
fi

case "$SYM_STDERR" in
  *symlink*)
    check "symlink guard writes a stderr warning" PASS ;;
  *)
    check "symlink guard writes a stderr warning (got: $SYM_STDERR)" FAIL ;;
esac

echo "----"
echo "test-autofix-rounds-reset-on-fresh-tdd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
