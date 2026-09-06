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

# This is the ATTEMPT half of a two-writer witness, and it exists because the
# RESULT half structurally cannot see a failure: Claude Code does not deliver
# PostToolUse for a Bash call that did not complete successfully, so
# hooks/post-bash-witness.sh never runs for one. hooks/lib/zensu-witness.sh
# carries the measurement that established that and the full argument.
#
# PreToolUse fires unconditionally, so an ATTEMPT line here plus no RESULT line
# there is positive evidence that the call did not complete successfully —
# which is what lets hooks/lib/zensu-evidence-crosscheck.js CONTRADICT a claimed
# PASS over a failing command instead of reporting the absence as a gap.
#
# ADVISORY ONLY. It writes nothing to stdout, returns no permissionDecision of
# any kind, and always exits 0. That is not a style choice: stdout is the
# PreToolUse decision channel and a non-zero exit BLOCKS the tool call, so a
# witness that failed closed would break every Bash call in the session. It is
# also what keeps this hook a `patch` under CLAUDE.md's runtime-lineage rule,
# whose hook-inventory exemption covers exactly an advisory hook.
#
# WHAT AN ATTEMPT LINE DOES NOT PROVE: it is written before the command runs, and
# PreToolUse hooks on one matcher all run regardless of what any of them decides,
# so an attempt is also recorded for a call another gate then DENIES. An
# attempt without a result therefore means "the call did not complete
# successfully" — non-zero exit, interruption, abort or denial — and never
# specifically "it exited non-zero". The cross-check's wording says exactly that
# and must not be tightened.

{ INPUT="$(cat 2>/dev/null || true)"; } 2>/dev/null
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" PreToolUse || exit 0
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
zensu_bind_hook_session "$INPUT" || exit 0

# Resolved BEFORE the field extraction: the extraction redacts absolute
# developer paths out of `cmd`, and it needs the project root to do that. The
# two writers must substitute identically or the ATTEMPT line matches no RESULT
# line and no claim.
PROJECT_DIR="$(zensu_resolve_project_dir)" || exit 0

# Bypass ledger: the same escape governs both halves of the witness, so the same
# entry is recorded here. The recorder dedups per gate, so a session whose
# commands reach both hooks still lands exactly one entry — and recording it here
# too is what keeps the ledger honest for a session in which the escape is set
# and every Bash call fails, where the RESULT half never runs at all.
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

# A PreToolUse payload carries no `tool_response`, so the middle three fields are
# read and discarded: the attempt line records the command and nothing else.
# Writing a placeholder `exit=?` / `tail=""` here would produce a line a reader —
# or a future parser — could mistake for a completed run.
{ read -r CMD_JSON; read -r _EXIT_CODE; read -r _TAIL_JSON; read -r _INTERRUPTED; read -r SESSION; } < "$TMP_FIELDS"
rm -f "$TMP_FIELDS"
SANITIZED_SESSION="$(zensu_resolve_session_id "$SESSION")" || exit 0

# Activation: same scope as the RESULT half. Recording attempts for a session
# whose chain is not active would put ATTEMPT lines in a log the completed half
# never writes to, and the cross-check would then read every one of them as a
# run that did not finish.
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
printf '%sBASH-ATTEMPT cmd=%s\n' "$TS_PREFIX" "$CMD_JSON" >> "$WITNESS_LOG" 2>/dev/null || true

exit 0
