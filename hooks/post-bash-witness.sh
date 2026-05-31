#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then exit 0; fi

if ! command -v node >/dev/null 2>&1; then exit 0; fi

INPUT="$(cat)"

FIELDS="$(printf '%s' "$INPUT" | node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const cmd = (j.tool_input && typeof j.tool_input.command === "string") ? j.tool_input.command : "";
      const exit = (j.tool_response && typeof j.tool_response.exit_code === "number") ? String(j.tool_response.exit_code) : "?";
      const stdout = (j.tool_response && typeof j.tool_response.stdout === "string") ? j.tool_response.stdout : "";
      const tail = stdout.slice(-200);
      const session = (typeof j.session_id === "string" && j.session_id) ? j.session_id : "";
      process.stdout.write(JSON.stringify(cmd) + "\x01" + exit + "\x01" + JSON.stringify(tail) + "\x01" + session);
    } catch (_) { process.stdout.write("\"\"\x01?\x01\"\"\x01"); }
  });
' 2>/dev/null)"

IFS=$'\x01' read -r CMD_JSON EXIT_CODE TAIL_JSON SESSION <<<"$FIELDS"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SANITIZED_SESSION="$(zensu_resolve_session_id "$SESSION")"

# Activation: record witness lines only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). Replaces
# the legacy CLAUDE_AGENT_TYPE=zensu:tdd-manager subagent scoping.
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
if [ "$(tdd_session_active "$(tdd_state_file "$SANITIZED_SESSION")")" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
WITNESS_DIR="$PROJECT_DIR/.zensu/logs"
WITNESS_LOG="$WITNESS_DIR/witness-${SANITIZED_SESSION}.log"
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0

TS="$(date +%H:%M:%S)"
printf '[%s] BASH cmd=%s exit=%s tail=%s\n' "$TS" "$CMD_JSON" "$EXIT_CODE" "$TAIL_JSON" >> "$WITNESS_LOG" 2>/dev/null || true

exit 0
