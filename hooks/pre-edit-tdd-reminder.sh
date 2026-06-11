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

if [ "${ZENSU_TDD_GATE:-}" = "off" ]; then
  exit 0
fi

SESSION_ID="$(parse_field session_id)"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"
FILE_PATH="$(parse_field tool_input.file_path)"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

STATE_FILE=$(tdd_state_file "$SESSION_ID")

# Activation: the gate enforces only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). When no
# active chain-state exists the hook is a silent pass-through — normal editing in
# the main thread, other subagents, and plain CLI are never gated. This replaces
# the legacy CLAUDE_AGENT_TYPE=zensu:tdd-manager scoping that only worked while
# TDD ran in a subagent.
if [ "$(tdd_session_active "$STATE_FILE")" != "true" ]; then
  exit 0
fi

# Path classification on the NORMALIZED form (dot-segments, duplicate slashes,
# case folding, traversal, and the resolved TDD_STATE_DIR override all collapse
# to the same class) so the state deny below cannot be evaded by an alternate
# spelling that the broader .zensu/ exemption would then allow.
PATH_CLASS="$(FP="$FILE_PATH" SD="$(dirname "$STATE_FILE")" node -e '
  const path = require("path");
  const fs = require("fs");
  const lownorm = p => path.posix.normalize(String(p).replace(/\\/g, "/")).toLowerCase();
  const realdir = p => { try { return fs.realpathSync(p); } catch (_) { return path.resolve(p); } };
  const realfile = p => {
    try { return fs.realpathSync(p); }
    catch (_) { return path.join(realdir(path.dirname(p)), path.basename(p)); }
  };
  const fpRaw = process.env.FP || "";
  const f = lownorm(fpRaw);
  const fAbs = lownorm(realfile(path.resolve(fpRaw)));
  const sAbs = lownorm(realdir(path.resolve(process.env.SD || ""))) + "/";
  if (f.indexOf("/.zensu/state/") >= 0 || f.indexOf(".zensu/state/") === 0 || fAbs.indexOf(sAbs) === 0) { console.log("state"); }
  else if (f.indexOf("/.zensu/") >= 0 || f.indexOf(".zensu/") === 0) { console.log("zensu"); }
  else { console.log("other"); }
' 2>/dev/null)"

# Session-state hardening: while a session is active, Edit/Write on the
# session-state files is denied in BOTH modes — flipping `vanilla`/`active`
# there would silently un-gate the session. Legitimate state writes go through
# zensu-log.sh via the Bash tool, which this hook never sees. Checked BEFORE
# the vanilla bypass and the .zensu/ exemption on purpose.
if [ "$PATH_CLASS" = "state" ]; then
  PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" node -e '
    const root = process.env.PLUGIN_ROOT || "";
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "TDD-Phase-Gate: direct edits to the session-state files (.zensu/state/) are blocked while a session is active — state flags change only through bash " + root + "/hooks/lib/zensu-log.sh (e.g. --tdd-begin, --tdd-reset, --phase)."
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
if [ "$(tdd_vanilla_mode "$STATE_FILE")" = "true" ]; then
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
