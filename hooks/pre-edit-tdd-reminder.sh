#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

PAYLOAD="$(cat)"

if ! command -v node >/dev/null 2>&1; then
  exit 0
fi

parse_field() {
  local field="$1"
  PAYLOAD_BODY="$PAYLOAD" FIELD_PATH="$field" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD_BODY || "{}");
      const path = process.env.FIELD_PATH.split(".");
      let v = j;
      for (const p of path) { if (v && typeof v === "object") v = v[p]; else { v = ""; break; } }
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

TOOL_NAME="$(parse_field tool_name)"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

AGENT_CONTEXT="${CLAUDE_AGENT_TYPE:-}"
if [ -z "$AGENT_CONTEXT" ]; then
  exit 0
fi

if [ "$AGENT_CONTEXT" != "zensu:tdd-manager" ]; then
  exit 0
fi

if [ "${ZENSU_TDD_GATE:-}" = "off" ]; then
  exit 0
fi

SESSION_ID="$(parse_field session_id)"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
FILE_PATH="$(parse_field tool_input.file_path)"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

STATE_FILE=$(tdd_state_file "$SESSION_ID")
PHASE=$(tdd_phase "$STATE_FILE")
STEP=$(tdd_step "$STATE_FILE")
IS_TEST_PATH=$(tdd_is_test_path "$FILE_PATH")
RED_FAIL_FOR_STEP=$(tdd_has_red_fail "$STATE_FILE" "$STEP")

decide_allow() {
  case "$PHASE" in
    RED_WRITE) return 0 ;;
    RED_FAIL)
      [ "$IS_TEST_PATH" = "true" ] && return 0
      return 1
      ;;
    IMPL)
      [ "$RED_FAIL_FOR_STEP" = "true" ] && return 0
      return 1
      ;;
    GREEN_PASS)
      [ "$IS_TEST_PATH" = "true" ] && return 0
      return 1
      ;;
    REFACTOR) return 0 ;;
    UNINITIALIZED) return 1 ;;
    *) return 1 ;;
  esac
}

if decide_allow; then
  exit 0
fi

PAYLOAD_PHASE="$PHASE" PAYLOAD_STEP="$STEP" PAYLOAD_FILE="$FILE_PATH" PAYLOAD_TOOL="$TOOL_NAME" PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" node -e '
  const phase = process.env.PAYLOAD_PHASE || "UNINITIALIZED";
  const step  = process.env.PAYLOAD_STEP || "(none)";
  const file  = process.env.PAYLOAD_FILE || "(unknown)";
  const tool  = process.env.PAYLOAD_TOOL || "Edit";
  const root  = process.env.PLUGIN_ROOT || "$CLAUDE_PLUGIN_ROOT";
  const header =
    "TDD-Phase-Gate: " + tool + " on " + file + " blocked.\n" +
    "Current phase: " + phase + ", step: " + step + ".\n" +
    "Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step " + step + ") | (GREEN_PASS only on test paths).\n";
  const reason = header +
    "Action:\n" +
    "  1. New test file: bash " + root + "/hooks/lib/zensu-log.sh --phase RED_WRITE --step <id>\n" +
    "  2. IMPL: first run the test, set RED_FAIL:\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase RED_RUN --step <id>\n" +
    "     (run the test command)\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase RED_FAIL --step <id> --reason \"...\"\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase IMPL --step <id>\n" +
    "  3. Refactor: bash " + root + "/hooks/lib/zensu-log.sh --phase REFACTOR --step <id>\n" +
    "  4. Legitimate non-TDD edit: set ZENSU_TDD_GATE=off";
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason
    }
  }));
'
echo

if [ -n "${ZENSU_HOOK_LOG:-}" ]; then
  {
    echo "[hook: PreToolUse] TDD-Phase-Gate: $TOOL_NAME on $FILE_PATH blocked."
    echo "[hook: PreToolUse] Current phase: $PHASE, step: $STEP."
    echo "[hook: PreToolUse] Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step $STEP) | (GREEN_PASS only on test paths)."
    echo "[hook: PreToolUse] permissionDecision=deny"
  } >> "$ZENSU_HOOK_LOG" 2>/dev/null || true
fi

exit 0
