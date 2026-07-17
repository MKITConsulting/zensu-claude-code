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

PAYLOAD="$(cat)"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$PAYLOAD" PreToolUse || exit 0
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
if ! zensu_bind_hook_session "$PAYLOAD"; then
  zensu_emit_hook_session_deny
  exit 0
fi

LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
PLUGIN_DATA_Q="$(printf '%q' "${CLAUDE_PLUGIN_DATA:-}")"
LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"
_ZENSU_MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:-}"
case ";${_ZENSU_MSYS2_ENV_CONV_EXCL};" in
  *';PAYLOAD_LOG_COMMAND;'*) ;;
  *) _ZENSU_MSYS2_ENV_CONV_EXCL="${_ZENSU_MSYS2_ENV_CONV_EXCL:+${_ZENSU_MSYS2_ENV_CONV_EXCL};}PAYLOAD_LOG_COMMAND" ;;
esac

if ! command -v node >/dev/null 2>&1; then
  exit 2
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

SESSION_ID="$(parse_field session_id)"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")" || exit 0
FILE_PATH="$(parse_field tool_input.file_path)"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

STATE_FILE=$(tdd_state_file "$SESSION_ID")

# Bypass ledger: the escape stays free, but while a TDD session is active the
# opt-out is recorded to chain state so the chain-end summary can surface it.
if [ "${ZENSU_TDD_GATE:-}" = "off" ]; then
  tdd_record_bypass "$SESSION_ID" ZENSU_TDD_GATE 2>/dev/null || true
  exit 0
fi

# An existing state file that cannot be parsed as an object is not an inactive
# session. Treating corruption as `active=false` would silently disable both
# the TDD gate and its chain guarantees. Missing state remains the only
# pass-through case; invalid/unreadable state blocks until a fresh session is
# started (or the explicit ZENSU_TDD_GATE=off escape is deliberately used).
deny_invalid_state() {
  PAYLOAD_STATE_FILE="$STATE_FILE" node -e '
    const file = process.env.PAYLOAD_STATE_FILE || "(unknown)";
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "TDD-Phase-Gate: edit blocked because the existing session-state file is invalid or unreadable (" + file + "). It cannot be trusted as inactive or UNINITIALIZED. Start a fresh Claude Code session so Session Control v1 creates new state; use ZENSU_TDD_GATE=off only as an explicit, reviewed recovery escape."
      }
    }));
  '
  echo
  exit 0
}

# Activation: the gate enforces only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). When no
# active chain-state exists the hook is a silent pass-through — normal editing in
# the main thread, other subagents, and plain CLI are never gated. This replaces
# the legacy CLAUDE_AGENT_TYPE=zensu:tdd-manager scoping that only worked while
# TDD ran in a subagent.
STATE_STATUS="$(tdd_state_status "$STATE_FILE")"
if [ "$STATE_STATUS" = "missing" ]; then
  ACTIVATION_STATUS="$(tdd_activation_status "$SESSION_ID")"
  case "$ACTIVATION_STATUS" in active|invalid) deny_invalid_state ;; esac
  exit 0
fi
[ "$STATE_STATUS" = "invalid" ] && deny_invalid_state
ACTIVE_STATE="$(tdd_session_active "$STATE_FILE")"
[ "$ACTIVE_STATE" = "invalid" ] && deny_invalid_state
if [ "$ACTIVE_STATE" != "true" ]; then
  exit 0
fi

# Path classification on an explicitly native absolute spelling. Native Node
# must never receive an MSYS project path through its quote-sensitive implicit
# conversion. Relative Edit/Write paths are anchored to the immutable bound
# project before conversion, so dot-segments, duplicate slashes, case folding,
# and traversal aliases collapse to the same class.
PROJECT_ROOT_SHELL="$(zensu_resolve_project_dir)" || deny_invalid_state
case "$FILE_PATH" in
  /*|[A-Za-z]:[\\/]*|\\\\*) FILE_PATH_SHELL="$FILE_PATH" ;;
  *) FILE_PATH_SHELL="$PROJECT_ROOT_SHELL/$FILE_PATH" ;;
esac
NATIVE_FILE_PATH="$(_tdd_native_path "$FILE_PATH_SHELL")" || deny_invalid_state
NATIVE_STATE_DIR="$(_tdd_native_project_path "$(dirname "$STATE_FILE")")" || deny_invalid_state
if ! PATH_CLASS="$(FP="$NATIVE_FILE_PATH" SD="$NATIVE_STATE_DIR" node -e '
  const path = require("path");
  const fs = require("fs");
  const lownorm = p => path.posix.normalize(String(p).replace(/\\/g, "/")).toLowerCase();
  const realdir = p => { try { return fs.realpathSync(p); } catch (_) { return path.resolve(p); } };
  const realfile = p => {
    try { return fs.realpathSync(p); }
    catch (_) { return path.join(realdir(path.dirname(p)), path.basename(p)); }
  };
  const fAbs = lownorm(realfile(path.resolve(process.env.FP || "")));
  const sAbs = lownorm(realdir(path.resolve(process.env.SD || ""))) + "/";
  if (fAbs.indexOf(sAbs) === 0) { console.log("state"); }
  else if (fAbs.indexOf("/.zensu/") >= 0 || fAbs.endsWith("/.zensu")) { console.log("zensu"); }
  else { console.log("other"); }
' 2>/dev/null)"; then
  deny_invalid_state
fi
case "$PATH_CLASS" in
  state|zensu|other) ;;
  *) deny_invalid_state ;;
esac

# Session-state hardening: while a session is active, Edit/Write on the
# session-state files is denied in BOTH modes — flipping `vanilla`/`active`
# there would silently un-gate the session. Legitimate state writes go through
# zensu-log.sh via the Bash tool, which this hook never sees. Checked BEFORE
# the vanilla bypass and the .zensu/ exemption on purpose.
if [ "$PATH_CLASS" = "state" ]; then
  MSYS2_ENV_CONV_EXCL="$_ZENSU_MSYS2_ENV_CONV_EXCL" PAYLOAD_LOG_COMMAND="$LOG_COMMAND" node -e '
    const logCommand = process.env.PAYLOAD_LOG_COMMAND;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "TDD-Phase-Gate: direct edits to the session-state files (.zensu/state/) are blocked while a session is active — state flags change only through " + logCommand + " (e.g. --tdd-begin, --tdd-reset, --phase)."
      }
    }));
  '
  echo
  exit 0
fi

# Vanilla implementation mode: the per-session `vanilla` flag was frozen into
# the state file by `--tdd-begin` (hooks.tddImplementation=false at begin time).
# The gate reads ONLY the state flag — never live config — so a mid-session
# config flip can neither un-gate a strict session nor wedge a vanilla one.
VANILLA_STATE="$(tdd_vanilla_mode "$STATE_FILE")"
[ "$VANILLA_STATE" = "invalid" ] && deny_invalid_state
if [ "$VANILLA_STATE" = "true" ]; then
  exit 0
fi

if [ "$PATH_CLASS" = "zensu" ]; then
  exit 0
fi

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

MSYS2_ENV_CONV_EXCL="$_ZENSU_MSYS2_ENV_CONV_EXCL" PAYLOAD_PHASE="$PHASE" PAYLOAD_STEP="$STEP" PAYLOAD_FILE="$FILE_PATH" PAYLOAD_TOOL="$TOOL_NAME" PAYLOAD_LOG_COMMAND="$LOG_COMMAND" node -e '
  const phase = process.env.PAYLOAD_PHASE || "UNINITIALIZED";
  const step  = process.env.PAYLOAD_STEP || "(none)";
  const file  = process.env.PAYLOAD_FILE || "(unknown)";
  const tool  = process.env.PAYLOAD_TOOL || "Edit";
  const logCommand = process.env.PAYLOAD_LOG_COMMAND;
  const header =
    "TDD-Phase-Gate: " + tool + " on " + file + " blocked.\n" +
    "Current phase: " + phase + ", step: " + step + ".\n" +
    "Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step " + step + ") | (GREEN_PASS only on test paths).\n";
  const reason = header +
    "Action:\n" +
    "  1. New test file: " + logCommand + " --phase RED_WRITE --step <id>\n" +
    "  2. IMPL: first run the test, set RED_FAIL:\n" +
    "     " + logCommand + " --phase RED_RUN --step <id>\n" +
    "     (run the test command)\n" +
    "     " + logCommand + " --phase RED_FAIL --step <id> --reason \"...\"\n" +
    "     " + logCommand + " --phase IMPL --step <id>\n" +
    "  3. Refactor: " + logCommand + " --phase REFACTOR --step <id>\n" +
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
