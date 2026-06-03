#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then exit 0; fi

if ! command -v node >/dev/null 2>&1; then exit 0; fi

INPUT="$(cat)"

TMP_FIELDS="$(mktemp 2>/dev/null)" || exit 0
printf '%s' "$INPUT" | node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const cmd = (j.tool_input && typeof j.tool_input.command === "string") ? j.tool_input.command : "";
      const exit = (j.tool_response && typeof j.tool_response.exit_code === "number") ? String(j.tool_response.exit_code) : "?";
      const session = (typeof j.session_id === "string" && j.session_id) ? j.session_id : "";
      process.stdout.write(JSON.stringify(cmd) + "\n" + exit + "\n" + session + "\n");
    } catch (_) { process.stdout.write("\"\"\n?\n\n"); }
  });
' > "$TMP_FIELDS" 2>/dev/null

{ read -r CMD_JSON; read -r EXIT_CODE; read -r SESSION; } < "$TMP_FIELDS"
rm -f "$TMP_FIELDS"
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
printf '[%s] BASH cmd=%s exit=%s\n' "$TS" "$CMD_JSON" "$EXIT_CODE" >> "$WITNESS_LOG" 2>/dev/null || true

exit 0
