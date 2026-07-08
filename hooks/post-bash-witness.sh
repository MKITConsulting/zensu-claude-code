#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"

# Bypass ledger: the escape stays free, but while a TDD session is active the
# opt-out is recorded to chain state (fail-open, gate name only; per-gate dedup
# makes this once per session). The state-dir pre-filter keeps the off-path
# free of node spawns when no session was ever armed.
if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then
  _state_dir="${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  ls "$_state_dir"/tdd-phase-*.json >/dev/null 2>&1 || exit 0
  command -v node >/dev/null 2>&1 || exit 0
  INPUT="$(cat 2>/dev/null || true)"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  tdd_record_bypass_payload "$INPUT" ZENSU_TEST_WITNESS 2>/dev/null || true
  exit 0
fi

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
      const stdout = (j.tool_response && typeof j.tool_response.stdout === "string") ? j.tool_response.stdout : "";
      const tail = stdout.slice(-200);
      const interrupted = (j.tool_response && j.tool_response.interrupted === true) ? "true" : "false";
      const session = (typeof j.session_id === "string" && j.session_id) ? j.session_id : "";
      const transcript = (typeof j.transcript_path === "string") ? j.transcript_path : "";
      process.stdout.write(JSON.stringify(cmd) + "\n" + exit + "\n" + JSON.stringify(tail) + "\n" + interrupted + "\n" + session + "\n" + transcript + "\n");
    } catch (_) { process.stdout.write("\"\"\n?\n\"\"\nfalse\n\n\n"); }
  });
' > "$TMP_FIELDS" 2>/dev/null

{ read -r CMD_JSON; read -r EXIT_CODE; read -r TAIL_JSON; read -r INTERRUPTED; read -r SESSION; read -r TRANSCRIPT_PATH; } < "$TMP_FIELDS"
rm -f "$TMP_FIELDS"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SANITIZED_SESSION="$(ZENSU_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" zensu_resolve_session_id "$SESSION")"

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

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-config.sh"
TS_PREFIX=""
if [ "$(_zensu_log_style)" != "none" ]; then
  TS_PREFIX="[$(date +%H:%M:%S)] "
fi
printf '%sBASH cmd=%s exit=%s tail=%s interrupted=%s\n' "$TS_PREFIX" "$CMD_JSON" "$EXIT_CODE" "$TAIL_JSON" "$INTERRUPTED" >> "$WITNESS_LOG" 2>/dev/null || true

exit 0
