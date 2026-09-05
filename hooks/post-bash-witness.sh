#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

# This is the RESULT half of a two-writer witness. It records a completed Bash
# tool call — the command, the stdout tail and the interrupted flag. Claude Code
# does NOT fire PostToolUse for a Bash call that did not complete successfully,
# so a failing command never reaches this file at all; the ATTEMPT half
# (hooks/pre-bash-witness.sh) is what records it, and hooks/lib/zensu-witness.sh
# carries the measurement and the whole argument. Both writers share the field
# extraction there, because a divergence in the redaction breaks the equality
# match the cross-check is built on.

{ INPUT="$(cat 2>/dev/null || true)"; } 2>/dev/null
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" PostToolUse || exit 0
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
zensu_bind_hook_session "$INPUT" || exit 0

# Resolved BEFORE the field extraction, not after it as this hook used to: the
# extraction redacts absolute developer paths out of `cmd` (only — see
# hooks/lib/zensu-witness.sh for why the `tail` is left raw), and it needs the
# project root to do that.
PROJECT_DIR="$(zensu_resolve_project_dir)" || exit 0

# Bypass ledger: the escape stays free, but while a TDD session is active the
# opt-out is recorded to chain state (fail-open, gate name only; per-gate dedup
# makes this once per session). The project-bound state pre-filter keeps the off-path
# free of node spawns when no session was ever armed.
if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then
  _state_dir="$PROJECT_DIR/.zensu/state"
  ls "$_state_dir"/tdd-phase-*.json >/dev/null 2>&1 || exit 0
  command -v node >/dev/null 2>&1 || exit 0
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  tdd_record_bypass_payload "$INPUT" ZENSU_TEST_WITNESS 2>/dev/null || true
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then exit 0; fi

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-witness.sh"
ZENSU_REDACT_LIB_PATH="$(zensu_witness_redact_lib_path "$CLAUDE_PLUGIN_ROOT")"

TMP_FIELDS="$(mktemp 2>/dev/null)" || exit 0
zensu_witness_fields "$INPUT" "$ZENSU_REDACT_LIB_PATH" "$PROJECT_DIR" "$TMP_FIELDS"

{ read -r CMD_JSON; read -r EXIT_CODE; read -r TAIL_JSON; read -r INTERRUPTED; read -r SESSION; } < "$TMP_FIELDS"
rm -f "$TMP_FIELDS"
SANITIZED_SESSION="$(zensu_resolve_session_id "$SESSION")" || exit 0

# Activation: record witness lines only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). Replaces
# the legacy CLAUDE_AGENT_TYPE=zensu:tdd-manager subagent scoping.
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
if [ "$(tdd_session_active "$(tdd_state_file "$SANITIZED_SESSION")")" != "true" ]; then
  exit 0
fi

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
