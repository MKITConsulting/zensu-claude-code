#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" \
  || { return 2 2>/dev/null || exit 2; }
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
  echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
  return 2 2>/dev/null || exit 2
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

_tdd_context_binding() {
  local session_id="${1:-}" key record records
  key="$(zensu_resolve_session_id "$session_id")" || return 1
  if [ -n "${ZENSU_SESSION_CONTEXT:-}" ]; then
    record="$ZENSU_SESSION_CONTEXT"
    [ "$(basename "$record")" = "$key.json" ] || return 1
    records="$(dirname "$record")"
    printf '%s\n%s\n' claude "$records"
    return 0
  fi
  records="${HOME:-}/.zensu/session-control/codex/v3/records"
  [ -f "$records/$key.json" ] && [ ! -L "$records/$key.json" ] || return 1
  printf '%s\n%s\n' codex "$records"
}

tdd_activation_status() {
  local session_id="${1:-}" key binding state_file status active
  key="$(zensu_resolve_session_id "$session_id")" || { echo invalid; return 0; }
  binding="$(_tdd_context_binding "$key")" || { echo inactive; return 0; }
  state_file="$(tdd_state_file "$key")" || { echo invalid; return 0; }
  status="$(tdd_state_status "$state_file")"
  [ "$status" = "valid" ] || { echo invalid; return 0; }
  active="$(tdd_session_active "$state_file")"
  [ "$active" = "true" ] && echo active || echo inactive
}

tdd_state_file() {
  local session_id="${1:-}"
  local resolved project_root
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  resolved="$(zensu_resolve_session_id "$session_id")" || return 1
  project_root="$(zensu_resolve_project_dir)" || return 1
  echo "${project_root}/.zensu/state/tdd-phase-${resolved}.json"
}

_tdd_bound_project_root() {
  local state_file="${1:-}" session_id="${2:-}" expected project_root
  [ -n "$state_file" ] && [ -n "$session_id" ] || return 1
  expected="$(tdd_state_file "$session_id")" || return 1
  [ "$state_file" = "$expected" ] || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || return 1
  [ "$expected" = "$project_root/.zensu/state/tdd-phase-$(zensu_resolve_session_id "$session_id").json" ] || return 1
  printf '%s\n' "$project_root"
}

_tdd_begin_critical() {
  local state_file="$1"
  local session_id="$2"
  local vanilla="$3"
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" VANILLA="$vanilla" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "active",
        event: "tdd-begin",
      }, () => ({
        active: true,
        vanilla: process.env.VANILLA === "true",
        implComplete: false,
        chainDone: false,
        codeReviewDone: false,
        selfReviewFixed: false,
        workflowActive: false,
        workflowTools: [],
        bypasses: [],
        reviewRound: 0,
        stopBlocks: 0,
        phase: "UNINITIALIZED",
        step_id: "",
        history: [],
      }));
    ' 2>/dev/null
}

tdd_begin_session() {
  local supplied_session="${1:-}" vanilla="${2:-}" session_id state_file
  case "$vanilla" in true|false) ;; *) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_begin_critical "$state_file" "$session_id" "$vanilla"
}

tdd_is_test_path() {
  local path="${1:-}"
  [ -z "$path" ] && { echo "false"; return 0; }

  if [ -L "$path" ]; then
    echo "false"; return 0
  fi

  local lower
  lower=$(echo "$path" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|*/specs/*)
      echo "true"; return 0 ;;
    test/*|tests/*|__tests__/*|spec/*|specs/*)
      echo "true"; return 0 ;;
  esac

  local base
  base=$(basename "$path")

  case "$base" in
    test_*|*_test.*|*_tests.*|*.test.*|*.tests.*|*.spec.*|*.specs.*|*_spec.*|*_specs.*)
      echo "true"; return 0 ;;
  esac

  local lower_base
  lower_base=$(echo "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower_base" in
    *_test.*|*_tests.*|*_spec.*|*_specs.*)
      echo "true"; return 0 ;;
  esac

  if [ -f "$path" ]; then
    local link_count
    link_count=$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path" 2>/dev/null || echo "1")
    if [ "${link_count:-1}" -gt 1 ] 2>/dev/null; then
      echo "false"; return 0
    fi
    local header
    header=$(head -n 20 "$path" 2>/dev/null | sed $'1s/^\xef\xbb\xbf//' 2>/dev/null || true)
    if printf '%s\n' "$header" | grep -Eq '^(func Test|describe\(|it\(|test\(|@Test|def test_)' 2>/dev/null; then
      echo "true"; return 0
    fi
    if printf '%s\n' "$header" | grep -Eq '^[[:space:]]*#\[test\]' 2>/dev/null; then
      echo "true"; return 0
    fi
    if printf '%s\n' "$header" | grep -Eq '^[[:space:]]*#\[cfg\(test\)\]' 2>/dev/null; then
      echo "true"; return 0
    fi
  fi

  echo "false"
}

_tdd_write_phase_critical() {
  local state_file="$1"
  local session_id="$2"
  local step_id="$3"
  local phase="$4"
  local reason="$5"
  local ts="$6"

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" STEP="$step_id" PHASE="$phase" REASON="$reason" TS="$ts" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: process.env.PHASE.toLowerCase(),
        event: "phase-" + process.env.PHASE.toLowerCase(),
        updatedAt: process.env.TS || undefined,
      }, (state) => {
        if (!Array.isArray(state.history)) state.history = [];
        const entry = { step: process.env.STEP, phase: process.env.PHASE };
        if (process.env.TS) entry.ts = process.env.TS;
        if (process.env.REASON) entry.reason = process.env.REASON;
        state.history.push(entry);
        state.step_id = process.env.STEP;
        state.phase = process.env.PHASE;
        return state;
      });
    ' 2>/dev/null
}

tdd_write_phase() {
  local supplied_session="${1:-}"
  local session_id
  local step_id="${2:-}"
  local phase="${3:-}"
  local reason="${4:-}"
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1

  local ts=""
  if [ "$(_zensu_log_style)" != "none" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_phase_critical "$state_file" "$session_id" "$step_id" "$phase" "$reason" "$ts"
}

# --- Chain-state flags (active / implComplete / chainDone) ----------------
# These live in the SAME per-session state file as the FSM phase. They drive
# main-thread hook activation (active), the Stop-hook review gate
# (implComplete), and chain termination (chainDone). All writes go through the
# shared Session Control CAS transaction so concurrent phase/flag writes cannot
# clobber each other or reset an invalid revision.

_tdd_write_flag_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  local val="$4"

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" KEY="$key" VAL="$val" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const value = process.env.VAL === "true";
      const names = {
        vanilla: "configured",
        active: value ? "active" : "idle",
        implComplete: "implementation_complete",
        chainDone: "complete",
        codeReviewDone: "code_review_complete",
        selfReviewFixed: "self_review_fixed"
      };
      const event = "flag-" + process.env.KEY.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase() + "-" + String(value);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: names[process.env.KEY] || "control",
        event,
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state[process.env.KEY] = value;
        if (process.env.KEY === "active" && value) {
          state.reviewRound = 0;
          state.stopBlocks = 0;
        }
        if (process.env.KEY === "codeReviewDone" && value) state.stopBlocks = 0;
        return state;
      });
    ' 2>/dev/null
}

_tdd_increment_counter_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" KEY="$key" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const names = { reviewRound: "review_progress", stopBlocks: "stop_guard" };
      if (!Object.prototype.hasOwnProperty.call(names, process.env.KEY)) process.exit(2);
      const next = core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: names[process.env.KEY],
        event: "counter-" + process.env.KEY.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase(),
      }, (state) => {
        if (state.active !== true) throw new Error("counter mutation requires an active workflow");
        const current = state[process.env.KEY] === undefined ? 0 : state[process.env.KEY];
        if (!Number.isSafeInteger(current) || current < 0 || current >= 1000000) {
          throw new Error("counter is invalid or exhausted");
        }
        state[process.env.KEY] = current + 1;
        if (process.env.KEY === "reviewRound") state.stopBlocks = 0;
        return state;
      });
      process.stdout.write(String(next[process.env.KEY]));
    ' 2>/dev/null
}

tdd_increment_counter() {
  local supplied_session="${1:-}" key="${2:-}" session_id state_file
  case "$key" in reviewRound|stopBlocks) ;; *) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_increment_counter_critical "$state_file" "$session_id" "$key"
}

tdd_reset_review_budget() {
  local supplied_session="${1:-}" expected_revision="${2:-}" session_id state_file
  case "$expected_revision" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected_revision" -ge 1 ] 2>/dev/null || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" EXPECTED_REVISION="$expected_revision" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const state = core.resetReviewBudget({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        expectedRevision: Number(process.env.EXPECTED_REVISION),
      });
      process.stdout.write(JSON.stringify(state));
    ' 2>/dev/null
}

tdd_set_flag() {
  local supplied_session="${1:-}"
  local session_id
  local key="${2:-}"
  local val="${3:-true}"
  [ -z "$key" ] && return 1
  case "$val" in true|false) ;; *) val="true" ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_flag_critical "$state_file" "$session_id" "$key" "$val"
}

_tdd_write_clear_critical() {
  local state_file="$1"
  local session_id="$2"
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "idle",
      event: "session-reset",
    }, (s) => {
      s.active = false; s.implComplete = false; s.chainDone = false;
      s.codeReviewDone = false; s.selfReviewFixed = false; s.workflowActive = false;
      s.workflowTools = []; s.vanilla = false; s.bypasses = [];
      s.reviewRound = 0; s.stopBlocks = 0;
      s.phase = "UNINITIALIZED"; s.step_id = ""; s.history = [];
      return s;
    });
  ' 2>/dev/null
}

tdd_clear_session() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_clear_critical "$state_file" "$session_id"
}

_tdd_write_chain_reset_critical() {
  local state_file="$1"
  local session_id="$2"
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "chain_reset",
      event: "chain-reset",
    }, (s) => {
      s.implComplete = false; s.chainDone = false;
      s.codeReviewDone = false; s.selfReviewFixed = false;
      s.reviewRound = 0; s.stopBlocks = 0;
      return s;
    });
  ' 2>/dev/null
}

# Clear only the review-chain completion flags (implComplete/chainDone/
# codeReviewDone/selfReviewFixed) in one atomic write, preserving active,
# vanilla, workflow and FSM keys. Called by --tdd-begin so the Stop backstop
# and the self-review fix-round latch re-arm for every chain in a session, not
# just the first.
tdd_reset_chain_flags() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_chain_reset_critical "$state_file" "$session_id"
}

_tdd_write_workflow_begin_critical() {
  local state_file="$1"
  local session_id="$2"
  local tools="$3"

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" TOOLS="$tools" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "workflow_active",
        event: "workflow-begin",
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state.workflowActive = true;
        state.workflowTools = (process.env.TOOLS || "").split(",").map(s => s.trim()).filter(Boolean);
        return state;
      });
    ' 2>/dev/null
}

tdd_workflow_begin() {
  local supplied_session="${1:-}"
  local session_id
  local tools="${2:-}"
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_workflow_begin_critical "$state_file" "$session_id" "$tools"
}

_tdd_read_validated_state() {
  local state_file="${1:-}"
  local mode="${2:-status}"
  local arg="${3:-}"
  local base key expected project_root
  if [ -z "$state_file" ]; then
    echo "missing"; return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "invalid"; return 0
  fi

  base="$(basename "$state_file")"
  case "$base" in
    tdd-phase-scv1_*.json) key="${base#tdd-phase-}"; key="${key%.json}" ;;
    *) echo "invalid"; return 0 ;;
  esac
  expected="$(tdd_state_file "$key")" || { echo "invalid"; return 0; }
  [ "$state_file" = "$expected" ] || { echo "invalid"; return 0; }
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || { echo "invalid"; return 0; }

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$project_root" STATE_FILE="$state_file" READ_MODE="$mode" READ_ARG="$arg" \
    node -e '
      const fs = require("node:fs");
      const path = require("node:path");
      const emit = (status, value) => {
        process.stdout.write(status);
        if (status === "valid" && value !== undefined) process.stdout.write("\n" + String(value));
      };
      const file = process.env.STATE_FILE || "";
      const match = /^tdd-phase-(scv1_[a-f0-9]{64})\.json$/.exec(path.basename(file));
      if (!match) { emit("invalid"); process.exit(0); }
      let stat;
      try { stat = fs.lstatSync(file); }
      catch (error) { emit(error && error.code === "ENOENT" ? "missing" : "invalid"); process.exit(0); }
      if (stat.isSymbolicLink() || !stat.isFile()) { emit("invalid"); process.exit(0); }
      let state;
      try {
        const core = require(process.env.CONTROL_CORE);
        state = core.readWorkflowState({ projectRoot: process.env.PROJECT_ROOT, sessionId: match[1] });
      } catch (_) { emit("invalid"); process.exit(0); }

      const mode = process.env.READ_MODE || "status";
      const arg = process.env.READ_ARG || "";
      if (mode === "status") emit("valid");
      else if (mode === "flag") emit("valid", state[arg] === true ? "true" : "false");
      else if (mode === "phase") emit("valid", state.phase === undefined ? "UNINITIALIZED" : state.phase);
      else if (mode === "step") emit("valid", state.step_id === undefined ? "" : state.step_id);
      else if (mode === "counter") {
        const value = state[arg] === undefined ? 0 : state[arg];
        if (!Number.isSafeInteger(value) || value < 0) emit("invalid");
        else emit("valid", value);
      }
      else if (mode === "red-fail") {
        const hit = Array.isArray(state.history)
          && state.history.some(entry => entry.step === arg && entry.phase === "RED_FAIL");
        emit("valid", hit ? "true" : "false");
      } else if (mode === "workflow-tool") {
        const hit = state.workflowActive === true
          && Array.isArray(state.workflowTools)
          && state.workflowTools.includes(arg);
        emit("valid", hit ? "true" : "false");
      } else if (mode === "bypasses") {
        const allow = String(arg).split(" ").filter(Boolean);
        const values = Array.isArray(state.bypasses)
          ? state.bypasses.filter((value, index, array) => allow.includes(value) && array.indexOf(value) === index)
          : [];
        emit("valid", values.join(", "));
      } else emit("invalid");
    ' 2>/dev/null || echo "invalid"
}

tdd_state_status() {
  local result
  result="$(_tdd_read_validated_state "${1:-}" status)"
  case "$result" in valid|missing|invalid) echo "$result" ;; *) echo "invalid" ;; esac
}

tdd_get_flag() {
  local state_file="${1:-}"
  local key="${2:-}"
  if [ -z "$key" ]; then
    echo "false"; return 0
  fi
  case "$key" in
    active|vanilla|implComplete|chainDone|codeReviewDone|selfReviewFixed|workflowActive) ;;
    *) echo "invalid"; return 0 ;;
  esac
  local result status value
  result="$(_tdd_read_validated_state "$state_file" flag "$key")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "false"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "invalid"; return 0; }
  value="${result#*$'\n'}"
  case "$value" in true|false) echo "$value" ;; *) echo "invalid" ;; esac
}

tdd_session_active()    { tdd_get_flag "${1:-}" active; }
tdd_vanilla_mode()      { tdd_get_flag "${1:-}" vanilla; }
tdd_impl_complete()     { tdd_get_flag "${1:-}" implComplete; }
tdd_chain_done()        { tdd_get_flag "${1:-}" chainDone; }
tdd_code_review_done()  { tdd_get_flag "${1:-}" codeReviewDone; }
tdd_self_review_fixed() { tdd_get_flag "${1:-}" selfReviewFixed; }
zensu_workflow_active()  { tdd_get_flag "${1:-}" workflowActive; }

tdd_get_counter() {
  local state_file="${1:-}" key="${2:-}" result status value
  case "$key" in reviewRound|stopBlocks) ;; *) echo "invalid"; return 0 ;; esac
  result="$(_tdd_read_validated_state "$state_file" counter "$key")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "0"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  value="${result#*$'\n'}"
  case "$value" in ''|*[!0-9]*) echo "invalid" ;; *) echo "$value" ;; esac
}

zensu_workflow_allows() {
  local sf="${1:-}" tool="${2:-}"
  [ -n "$tool" ] || { echo "false"; return 0; }
  local result status value
  result="$(_tdd_read_validated_state "$sf" workflow-tool "$tool")"
  status="${result%%$'\n'*}"
  [ "$status" = "valid" ] || { echo "false"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "true" ] && echo "true" || echo "false"
}

tdd_phase() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" phase)"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "UNINITIALIZED"; return 0 ;;
    invalid) echo "INVALID_STATE"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "INVALID_STATE"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value="UNINITIALIZED"
  echo "$value"
}

tdd_step() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" step)"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo ""; return 0 ;;
    invalid) echo "INVALID_STATE"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "INVALID_STATE"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value=""
  echo "$value"
}

tdd_has_red_fail() {
  local state_file="${1:-}"
  local step="${2:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" red-fail "$step")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "false"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "invalid"; return 0; }
  value="${result#*$'\n'}"
  case "$value" in true|false) echo "$value" ;; *) echo "invalid" ;; esac
}


# --- Bypass ledger (visible opt-outs) --------------------------------------
# Gate escapes (ZENSU_*=off) stay free but become visible: each gate records
# the env-var name it was bypassed through into the per-session state file
# while the session is active. Dedup per gate; consumers render the list at
# chain end. Writes are fail-open — a ledger failure never blocks a gate.
# Ledger hygiene: entries are validated against the closed gate allowlist at
# write AND read (pre-seeded junk is sanitized before the 32-entry cap so it
# can never exhaust the ledger) — a crafted value can neither smuggle
# directive text into the rendered surfaces nor bloat the state file every
# hook parses. New gates extend ZENSU_BYPASS_GATE_ALLOWLIST in ONE place.

ZENSU_BYPASS_GATE_ALLOWLIST="ZENSU_TDD_GATE ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE ZENSU_SECRET_SCAN ZENSU_CHAIN ZENSU_TEST_WITNESS"

_tdd_bypass_shape_ok() {
  case "${1:-}" in
    *[[:space:]]*|*$'\n'*|'') return 1 ;;
  esac
  case " $ZENSU_BYPASS_GATE_ALLOWLIST " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

_tdd_write_bypass_critical() {
  local state_file="$1"
  local session_id="$2"
  local gate="$3"

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" GATE="$gate" ALLOWLIST="$ZENSU_BYPASS_GATE_ALLOWLIST" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const allow = String(process.env.ALLOWLIST || "").split(" ").filter(Boolean);
      const gate = String(process.env.GATE || "").trim();
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "control",
        event: "bypass-recorded",
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state.bypasses = (Array.isArray(state.bypasses) ? state.bypasses : [])
          .filter((x, i, a) => allow.indexOf(x) >= 0 && a.indexOf(x) === i);
        if (allow.indexOf(gate) >= 0
            && state.bypasses.indexOf(gate) < 0) state.bypasses.push(gate);
        return state;
      });
    ' 2>/dev/null
}

tdd_add_bypass() {
  local supplied_session="${1:-}"
  local session_id
  local gate="${2:-}"
  _tdd_bypass_shape_ok "$gate" || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -L "$state_file" ] && return 1
  [ -L "$(dirname "$state_file")" ] && return 1
  case ", $(tdd_bypasses "$state_file")," in
    *", $gate,"*) return 0 ;;
  esac
  [ -f "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_bypass_critical "$state_file" "$session_id" "$gate"
}

tdd_record_bypass() {
  local session_id="${1:-}"
  local gate="${2:-}"
  [ -z "$session_id" ] && return 0
  if [ "$(tdd_session_active "$(tdd_state_file "$session_id")")" = "true" ]; then
    tdd_add_bypass "$session_id" "$gate" 2>/dev/null || true
  fi
  return 0
}

tdd_record_bypass_payload() {
  local payload="${1:-}"
  local gate="${2:-}"
  command -v node >/dev/null 2>&1 || return 0
  local sid
  sid="$(printf '%s' "$payload" | node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s || "{}");
        const sid = typeof j.session_id === "string" ? j.session_id : "";
        process.stdout.write(sid);
      } catch (_) { process.stdout.write(""); }
    });
  ' 2>/dev/null)"
  if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/zensu-session.sh" ]; then
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    sid="$(zensu_resolve_session_id "$sid")" || return 0
  fi
  tdd_record_bypass "$sid" "$gate"
}

tdd_clear_bypasses() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] || return 1
  [ -L "$state_file" ] && return 1
  [ -L "$(dirname "$state_file")" ] && return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_bypass_clear_critical "$state_file" "$session_id"
}

_tdd_write_bypass_clear_critical() {
  local state_file="$1"
  local session_id="$2"
  [ -f "$state_file" ] || return 1
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "control",
      event: "bypasses-cleared",
    }, (s) => { s.bypasses = []; return s; });
  ' 2>/dev/null
}

tdd_bypasses() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" bypasses "$ZENSU_BYPASS_GATE_ALLOWLIST")"
  status="${result%%$'\n'*}"
  [ "$status" = "valid" ] || { echo ""; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value=""
  echo "$value"
}

zensu_pending_review_file() {
  local project_root
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || return 1
  echo "${project_root}/.zensu/state/pending-review.json"
}

_tdd_write_pending_review_critical() {
  local pf="$1"
  local files="$2"
  local summary="$3"
  local ts="$4"

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" STATE_DIR="$(dirname "$pf")" PENDING_FILE="$pf" FILES="$files" SUMMARY="$summary" TS="$ts" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const files = (process.env.FILES || "").split(",").map(s => s.trim()).filter(Boolean);
      const o = { files, summary: process.env.SUMMARY || "" };
      if (process.env.TS) o.ts = process.env.TS;
      core.withFileLock(process.env.STATE_DIR, "pending-review", () => {
        core.atomicWriteJson(process.env.PENDING_FILE, o);
      });
    ' 2>/dev/null
}

tdd_write_pending_review() {
  local files="${1:-}"
  local summary="${2:-}"
  local pf
  pf="$(zensu_pending_review_file)"
  local dir
  dir="$(dirname "$pf")"
  [ -L "$pf" ] && return 1
  [ -L "$dir" ] && return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  local ts=""
  if [ "$(_zensu_log_style)" != "none" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  _tdd_write_pending_review_critical "$pf" "$files" "$summary" "$ts"
}

tdd_clear_pending_review() {
  local pf
  pf="$(zensu_pending_review_file)"
  local dir
  dir="$(dirname "$pf")"
  if [ -L "$pf" ]; then
    echo "zensu: refusing to clear pending-review marker through symlink at $pf" >&2
    return 1
  fi
  if [ -L "$dir" ]; then
    echo "zensu: refusing to clear pending-review marker under symlinked dir $dir" >&2
    return 1
  fi
  [ -d "$dir" ] || return 0
  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" STATE_DIR="$dir" PENDING_FILE="$pf" node -e '
    const fs = require("fs");
    const core = require(process.env.CONTROL_CORE);
    core.withFileLock(process.env.STATE_DIR, "pending-review", () => {
      try { fs.unlinkSync(process.env.PENDING_FILE); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
    });
  ' 2>/dev/null
}

tdd_pending_review_stale() {
  local ttl_hours="${1:-}"
  case "$ttl_hours" in ''|*[!0-9]*) echo "false"; return 0 ;; esac
  [ "$ttl_hours" -le 0 ] && { echo "false"; return 0; }
  local pf
  pf="$(zensu_pending_review_file)"
  [ -f "$pf" ] || { echo "false"; return 0; }
  [ -L "$pf" ] && { echo "false"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "false"; return 0; }
  local verdict
  verdict=$(TTL="$ttl_hours" node -e '
    try {
      const fs = require("fs");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const ts = j && j.ts;
      let t = (typeof ts === "string" && ts) ? Date.parse(ts) : NaN;
      if (!Number.isFinite(t)) {
        try { t = fs.statSync(process.argv[1]).mtimeMs; } catch (_) { console.log("false"); process.exit(0); }
      }
      if (!Number.isFinite(t)) { console.log("false"); process.exit(0); }
      const ttlMs = parseInt(process.env.TTL, 10) * 3600 * 1000;
      console.log((Date.now() - t) >= ttlMs ? "true" : "false");
    } catch (_) { console.log("false"); }
  ' "$pf" 2>/dev/null)
  [ "$verdict" = "true" ] && echo "true" || echo "false"
}

_tdd_write_seed_critical() {
  local state_file="$1"
  local session_id="$2"
  local vanilla="$3"

  CONTROL_CORE="${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" VANILLA="$vanilla" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "deferred_review",
        event: "deferred-review-seed",
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state.active = true;
        state.implComplete = true;
        state.vanilla = (process.env.VANILLA === "true");
        state.bypasses = [];
        state.reviewRound = 0;
        state.stopBlocks = 0;
        return state;
      });
    ' 2>/dev/null
}

tdd_seed_deferred_review() {
  local supplied_session="${1:-}"
  local session_id
  local vanilla="${2:-false}"
  case "$vanilla" in true|false) ;; *) vanilla="false" ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_seed_critical "$state_file" "$session_id" "$vanilla"
}

export -f _tdd_context_binding tdd_activation_status tdd_state_file _tdd_bound_project_root _tdd_begin_critical tdd_begin_session tdd_is_test_path tdd_write_phase _tdd_write_phase_critical _tdd_read_validated_state tdd_state_status tdd_phase tdd_step tdd_has_red_fail _tdd_write_flag_critical tdd_set_flag _tdd_increment_counter_critical tdd_increment_counter tdd_reset_review_budget _tdd_write_clear_critical tdd_clear_session _tdd_write_chain_reset_critical tdd_reset_chain_flags tdd_get_flag tdd_get_counter tdd_session_active tdd_vanilla_mode tdd_impl_complete tdd_chain_done tdd_code_review_done tdd_self_review_fixed zensu_workflow_active zensu_workflow_allows tdd_workflow_begin _tdd_write_workflow_begin_critical _tdd_bypass_shape_ok _tdd_write_bypass_critical tdd_add_bypass tdd_record_bypass tdd_record_bypass_payload tdd_bypasses _tdd_write_bypass_clear_critical tdd_clear_bypasses zensu_pending_review_file _tdd_write_pending_review_critical tdd_write_pending_review tdd_clear_pending_review tdd_pending_review_stale _tdd_write_seed_critical tdd_seed_deferred_review 2>/dev/null || true
