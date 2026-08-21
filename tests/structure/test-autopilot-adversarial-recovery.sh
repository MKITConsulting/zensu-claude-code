#!/bin/bash
# Adversarial recovery contracts for missing runtime/state and cross-file CAS.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
SESSION_INIT="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
HOST_PATH="$PLUGIN_DIR/hooks/lib/zensu-host-path.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

if [ ! -r "$STATE_LIB" ] || [ ! -r "$PHASE_LIB" ]; then
  check "X1 durable state libraries exist" FAIL
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_LIB"

ROOT="$(mktemp -d -t za-adv-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
mkdir -p "$ROOT/session-control/plugin-data"
ZENSU_TEST_PLUGIN_DATA="$(cd "$ROOT/session-control/plugin-data" && pwd -P)"
export ZENSU_TEST_PLUGIN_DATA

native_directory() {
  local rendered
  rendered="$(bash "$HOST_PATH" "$1")" || return 1
  MSYS2_ARG_CONV_EXCL='*' node -e '
    const fs = require("fs");
    process.stdout.write(fs.realpathSync.native(process.argv[1]));
  ' "$rendered"
}

activate_session() {
  local project="$1" supplied="$2" key context native_project native_plugin_data
  mkdir -p "$project" || return 1
  project="$(cd "$project" && pwd -P)" || return 1
  native_project="$(native_directory "$project")" || return 1
  native_plugin_data="$(native_directory "$ZENSU_TEST_PLUGIN_DATA")" || return 1
  key="$(node "$SESSION_CORE" session-key "$supplied")" || return 1
  context="$(MSYS2_ARG_CONV_EXCL='*' node -e '
    const path = require("path");
    process.stdout.write(path.join(process.argv[1], "session-control", "v1", "records", `${process.argv[2]}.json`));
  ' "$native_plugin_data" "$key")" || return 1
  if [ "${ZENSU_PROJECT_ROOT:-}" = "$native_project" ] \
      && [ "${ZENSU_SESSION_KEY:-}" = "$key" ] \
      && [ "${ZENSU_SESSION_CONTEXT:-}" = "$context" ] \
      && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] \
      && [ "$(node "$SESSION_CORE" session-key "$CLAUDE_CODE_SESSION_ID" 2>/dev/null)" = "$key" ]; then
    export CLAUDE_PROJECT_DIR="$project"
    return 0
  fi
  # A derived key cannot recreate the raw host identity. New bindings must be
  # initialized from the same raw session id Claude places in hook payloads.
  case "$supplied" in scv1_*) return 1 ;; esac
  export CLAUDE_PROJECT_DIR="$project"
  # shellcheck disable=SC1090
  source "$SESSION_INIT" "$supplied" || return 1
  [ "$ZENSU_SESSION_KEY" = "$key" ] && [ "$ZENSU_SESSION_CONTEXT" = "$context" ]
}

prepare_session() {
  local project="$1" supplied="$2" variable="$3"
  activate_session "$project" "$supplied" || return 1
  printf -v "$variable" '%s' "$ZENSU_SESSION_KEY"
}

decision() {
  node -e '
    let input="";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(input).decision || "allow"); }
      catch (_) { process.stdout.write("allow"); }
    });
  '
}

invoke_stop() {
  local project="$1" session_id="$2"
  activate_session "$project" "$session_id" || return 1
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$CLAUDE_CODE_SESSION_ID" \
    | CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$ROOT/missing-config.json" \
      bash "$STOP" 2>/dev/null
}

field_ok() {
  FILE="$1" EXPR="$2" node -e '
    const value = require(process.env.FILE);
    process.exit(Function("value", `return Boolean(${process.env.EXPR})`)(value) ? 0 : 1);
  ' 2>/dev/null
}

pair_ok() {
  OUTER_FILE="$1" INNER_FILE="$2" EXPR="$3" node -e '
    const outer = require(process.env.OUTER_FILE);
    const inner = require(process.env.INNER_FILE);
    process.exit(Function("outer", "inner", `return Boolean(${process.env.EXPR})`)(outer, inner) ? 0 : 1);
  ' 2>/dev/null
}

digest() {
  node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

copy_runtime() {
  local destination="$1" runtime_entry
  mkdir -p "$destination"
  destination="$(cd "$destination" && pwd -P)" || return 1
  for runtime_entry in .claude-plugin .mcp.json hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
    cp -R "$PLUGIN_DIR/$runtime_entry" "$destination/$runtime_entry" || return 1
  done
  mkdir -p "$destination/mcp-runtime"
  cp "$PLUGIN_DIR/mcp-runtime/package.json" "$PLUGIN_DIR/mcp-runtime/package-lock.json" \
    "$destination/mcp-runtime/" || return 1
}

bind_runtime_session() {
  local plugin_root="$1" project="$2" raw_session="$3" label="$4"
  local ZENSU_TEST_PLUGIN_DATA="$ROOT/$label-plugin-data"
  export ZENSU_TEST_PLUGIN_DATA
  export CLAUDE_PROJECT_DIR="$project"
  # shellcheck disable=SC1090
  source "$SESSION_INIT" "$raw_session" "$plugin_root"
}

IS_WINDOWS="$(node -p 'process.platform === "win32" ? "true" : "false"')"
make_file_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}

approve() {
  local project="$1" run_id="$2" session_id="$3"
  local plan_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  activate_session "$project" "$session_id" || return 1
  mkdir -p "$project"
  autopilot_begin_run "$run_id" "$session_id" "$project" >/dev/null \
    && autopilot_apply_event "$run_id" "plan-${run_id}" PLAN_APPROVED \
      "{\"approvedPlanSha256\":\"$plan_sha\"}" "$project" "$session_id" >/dev/null
}

begin_bound() {
  local project="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5"
  autopilot_begin_tdd_attempt "$run_id" "tdd-started-${chain_id}" "$project" \
    "$session_id" true "$attempt" GATES "$chain_id" >/dev/null
}

mark_complete() {
  local project="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5"
  CLAUDE_PROJECT_DIR="$project" tdd_mark_impl_complete_bound \
    "$session_id" "$run_id" "$attempt" "$chain_id" >/dev/null
}

seed_exhausted_review() {
  local project="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5"
  local ticket
  approve "$project" "$run_id" "$session_id" || return 1
  begin_bound "$project" "$run_id" "$session_id" "$attempt" "$chain_id" || return 1
  mark_complete "$project" "$run_id" "$session_id" "$attempt" "$chain_id" || return 1
  ticket="$(CLAUDE_PROJECT_DIR="$project" tdd_issue_review_ticket "$session_id")" || return 1
  CLAUDE_PROJECT_DIR="$project" tdd_consume_review_ticket \
    "$session_id" "$ticket" >/dev/null || return 1
  CLAUDE_PROJECT_DIR="$project" tdd_set_chain_outcome \
    "$session_id" max-rounds "$run_id" "$attempt" "$chain_id" "$ticket" >/dev/null || return 1
  CLAUDE_PROJECT_DIR="$project" tdd_mark_review_converged \
    "$session_id" "$ticket" codeReviewDone >/dev/null || return 1
  printf '%s\n' "$ticket"
}

check "X1 durable state libraries exist" PASS

# Both children `autopilot_workspace_root` spawns run inside the project lease on
# the gate path. A child that inherits the keeper's pipe prevents EOF and hangs
# the release, which surfaces as an unrelated suite that never returns.
WORKSPACE_FN="$(awk '/^autopilot_workspace_root\(\) \{/,/^\}/' "$STATE_LIB")"
WORKSPACE_SPAWNS="$(printf '%s\n' "$WORKSPACE_FN" | grep -cE 'rev-parse --show-toplevel|zensu-host-path\.sh|_autopilot_rendered_dir')"
WORKSPACE_REDIRECTS="$(printf '%s\n' "$WORKSPACE_FN" | grep -cF '</dev/null')"
RENDER_FN="$(awk '/^_autopilot_rendered_dir\(\) \{/,/^\}/' "$STATE_LIB")"
RENDER_REDIRECTS="$(printf '%s\n' "$RENDER_FN" | grep -cF '</dev/null')"
if [ "$WORKSPACE_SPAWNS" -ge 2 ] && [ "$WORKSPACE_REDIRECTS" -ge 1 ] && [ "$RENDER_REDIRECTS" -ge 1 ]; then
  check "X1b every child spawned under the project lease redirects stdin" PASS
else
  check "X1b lease-safe stdin redirects (spawns=$WORKSPACE_SPAWNS redirects=$WORKSPACE_REDIRECTS render=$RENDER_REDIRECTS)" FAIL
fi

if grep -qF "path_indexes=(0 1 2 3 6 10)" "$STATE_LIB" \
  && grep -qF "path_indexes=(0 1 2 4)" "$STATE_LIB" \
  && grep -qF "path_indexes=(0 1 4)" "$STATE_LIB" \
  && grep -qF "path_indexes=(0 1)" "$STATE_LIB" \
  && grep -qF "MSYS2_ARG_CONV_EXCL='*' node -" "$STATE_LIB" \
  && grep -qF '_tdd_native_project_path "$input"' "$STATE_LIB" \
  && grep -qF '_autopilot_native_project_root "$input"' "$STATE_LIB" \
  && grep -qF 'root="$(cd -P -- "$input" 2>/dev/null && pwd -P)"' "$STATE_LIB" \
  && grep -qF '_autopilot_msys_env_exclusions' "$STATE_LIB" \
  && ! grep -qF 'PAYLOAD_FILE="$payload_file"' "$STATE_LIB" \
  && ! grep -qF 'TARGET_FILE="$target" node -e' "$STATE_LIB" \
  && ! grep -qF 'STATE_FILE="$state_file" SID=' "$STATE_LIB"; then
  check "X1a native Node filesystem boundaries are explicit for the pinned modes" PASS
else
  check "X1a native Node filesystem boundaries are explicit for the pinned modes" FAIL
fi

# A bound Inner generation is proof that an outer run exists. Removing only
# the project-local active pointer must never turn that proof into "no run",
# including after the Inner terminus was durably committed first.
P2="$ROOT/missing-pointer-active"
R2=adversarial_pointer_active_run
S2=adversarial_pointer_active_session
C2=adversarial-pointer-active-chain
prepare_session "$P2" "$S2" S2 || exit 1
approve "$P2" "$R2" "$S2" && begin_bound "$P2" "$R2" "$S2" 1 "$C2" \
  && mark_complete "$P2" "$R2" "$S2" 1 "$C2" || exit 1
rm -f "$(autopilot_active_file "$P2" "$S2")"
RF2="$(autopilot_run_file "$R2" "$P2")"
TF2="$(tdd_state_file "$S2")"
BEFORE2_OUTER="$(digest "$RF2")"; BEFORE2_INNER="$(digest "$TF2")"
OUT2="$(invoke_stop "$P2" "$S2")"
if [ "$(printf '%s' "$OUT2" | decision)" = block ] \
  && printf '%s' "$OUT2" | grep -qi 'corrupt' \
  && [ "$(digest "$RF2")" = "$BEFORE2_OUTER" ] \
  && [ "$(digest "$TF2")" = "$BEFORE2_INNER" ]; then
  check "X2 missing pointer plus nonterminal run blocks centrally without mutation" PASS
else
  check "X2 missing active pointer cannot release a bound Inner generation" FAIL
fi

P3="$ROOT/missing-pointer-done"
R3=adversarial_pointer_done_run
S3=adversarial_pointer_done_session
C3=adversarial-pointer-done-chain
prepare_session "$P3" "$S3" S3 || exit 1
approve "$P3" "$R3" "$S3" && begin_bound "$P3" "$R3" "$S3" 1 "$C3" \
  && mark_complete "$P3" "$R3" "$S3" 1 "$C3" \
  && CLAUDE_PROJECT_DIR="$P3" tdd_finish_autopilot_chain \
    "$S3" "$R3" 1 "$C3" pass >/dev/null || exit 1
rm -f "$(autopilot_active_file "$P3" "$S3")"
RF3="$(autopilot_run_file "$R3" "$P3")"
TF3="$(tdd_state_file "$S3")"
BEFORE3_OUTER="$(digest "$RF3")"; BEFORE3_INNER="$(digest "$TF3")"
OUT3="$(invoke_stop "$P3" "$S3")"
if [ "$(printf '%s' "$OUT3" | decision)" = block ] \
  && printf '%s' "$OUT3" | grep -qi 'corrupt' \
  && [ "$(digest "$RF3")" = "$BEFORE3_OUTER" ] \
  && [ "$(digest "$TF3")" = "$BEFORE3_INNER" ] \
  && field_ok "$TF3" 'value.chainDone === true && value.chainOutcome === "pass"'; then
  check "X3 chainDone plus orphan outer state blocks centrally without mutation" PASS
else
  check "X3 chainDone cannot hide a missing bound active pointer" FAIL
fi

# Runtime loss must fail closed from the Inner state hint alone. These cases
# intentionally have no outer pointer and therefore exercise standalone TDD.
P4="$ROOT/standalone-runtime"
S4=adversarial_standalone_runtime
S4_RAW="$S4"
mkdir -p "$P4"
prepare_session "$P4" "$S4" S4 || exit 1
CLAUDE_PROJECT_DIR="$P4" bash "$LOG" --tdd-begin --session "$S4" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P4" bash "$LOG" --tdd-complete --session "$S4" >/dev/null \
  || exit 1
NO_NODE_PATH="$ROOT/no-node-path"
mkdir -p "$NO_NODE_PATH"
for utility in cat dirname grep; do
  utility_path="$(command -v "$utility")"
  [ -n "$utility_path" ] && ln -s "$utility_path" "$NO_NODE_PATH/$utility"
done
OUT4="$(printf '{"hook_event_name":"Stop","session_id":"%s"}' "$S4_RAW" \
  | CLAUDE_PROJECT_DIR="$P4" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" PATH="$NO_NODE_PATH" \
    /bin/bash "$STOP" 2>/dev/null)"
if [ -z "$OUT4" ]; then
  check "X4 missing Node stays silent before unauthenticated principal/state inspection" PASS
else
  check "X4 missing Node must not guess a main-thread Stop decision" FAIL
fi

MISSING_PHASE_ROOT="$ROOT/missing-phase-root"
copy_runtime "$MISSING_PHASE_ROOT"
MISSING_PHASE_ROOT="$(cd "$MISSING_PHASE_ROOT" && pwd -P)"
rm -f "$MISSING_PHASE_ROOT/hooks/lib/zensu-tdd-phase.sh"
bind_runtime_session "$MISSING_PHASE_ROOT" "$P4" "$S4_RAW" missing-phase
OUT5="$(printf '{"hook_event_name":"Stop","session_id":"%s"}' "$S4_RAW" \
  | CLAUDE_PROJECT_DIR="$P4" CLAUDE_PLUGIN_ROOT="$MISSING_PHASE_ROOT" \
    bash "$MISSING_PHASE_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT5" | decision)" = block ] \
  && printf '%s' "$OUT5" | grep -qF 'project-local inner state exists'; then
  check "X5 missing TDD core library blocks an active standalone Inner chain" PASS
else
  check "X5 missing core library cannot release standalone Inner work" FAIL
fi

P6="$ROOT/corrupt-inner"
S6=adversarial_corrupt_inner
mkdir -p "$P6"
prepare_session "$P6" "$S6" S6 || exit 1
CLAUDE_PROJECT_DIR="$P6" bash "$LOG" --tdd-begin --session "$S6" >/dev/null || exit 1
TF6="$(tdd_state_file "$S6")"
printf '%s\n' '{not-json' > "$TF6"
OUT6="$(invoke_stop "$P6" "$S6")"
if [ "$(printf '%s' "$OUT6" | decision)" = block ] \
  && printf '%s' "$OUT6" | grep -qF 'current-session inner state is corrupt or unsafe'; then
  check "X6 corrupt current-session Inner JSON blocks Stop" PASS
else
  check "X6 corrupt Inner JSON cannot be interpreted as absent" FAIL
fi

# If the Inner terminus landed but the outer event did not, composite rearm
# must first preserve that evidence in the outer ledger, then retire and
# resume. It may not clear chainDone while leaving a BLOCKED outer generation
# pointing at an active unfinished Inner chain.
P7="$ROOT/rearm-crash-window"
R7=adversarial_rearm_crash_run
S7=adversarial_rearm_crash_session
C7=adversarial-rearm-crash-chain
prepare_session "$P7" "$S7" S7 || exit 1
T7="$(seed_exhausted_review "$P7" "$R7" "$S7" 1 "$C7")" || exit 1
CLAUDE_PROJECT_DIR="$P7" tdd_finish_autopilot_chain \
  "$S7" "$R7" 1 "$C7" max-rounds "$T7" >/dev/null || exit 1
RF7="$(autopilot_run_file "$R7" "$P7")"
TF7="$(tdd_state_file "$S7")"
if field_ok "$RF7" 'value.stage === "TDD_RUNNING"' \
  && field_ok "$TF7" 'value.chainDone === true && value.chainOutcome === "max-rounds"' \
  && CLAUDE_PROJECT_DIR="$P7" autopilot_rearm_review \
    "$R7" "$P7" "$S7" 1 "$C7" "$T7" >/dev/null \
  && pair_ok "$RF7" "$TF7" '
    outer.stage === "AWAIT_TDD"
      && inner.active === false && inner.chainDone === false && inner.chainOutcome === ""
      && inner.reviewRearm && inner.reviewRearm.retire === true
      && outer.events.some(event => event.eventType === "TDD_CHAIN_DONE"
        && event.payload && event.payload.chainId === "adversarial-rearm-crash-chain"
        && event.payload.outcome === "max-rounds")
      && outer.events.findIndex(event => event.eventType === "TDD_CHAIN_DONE")
        < outer.events.findIndex(event => event.eventType === "RESUME")
      && !(outer.stage === "BLOCKED" && inner.active === true && inner.chainDone === false)'; then
  check "X7 composite rearm preserves chainDone crash evidence before retire-and-resume" PASS
else
  check "X7 composite rearm cannot erase unreconciled chainDone evidence" FAIL
fi

# Race the same composite against a full finish. Both operations acquire the
# project-wide outer lock first, so the result must match one complete serial
# order: rearm-first leaves TDD_RUNNING with a freshly armed Inner generation;
# finish-first is reconciled and retired to AWAIT_TDD.
P8="$ROOT/rearm-finish-race"
R8=adversarial_rearm_race_run
S8=adversarial_rearm_race_session
C8=adversarial-rearm-race-chain
prepare_session "$P8" "$S8" S8 || exit 1
T8="$(seed_exhausted_review "$P8" "$R8" "$S8" 1 "$C8")" || exit 1
(
  CLAUDE_PROJECT_DIR="$P8" autopilot_rearm_review \
    "$R8" "$P8" "$S8" 1 "$C8" "$T8" >/dev/null 2>&1
  printf '%s\n' "$?" > "$P8/rearm.rc"
) &
REARM_PID=$!
(
  CLAUDE_PROJECT_DIR="$P8" autopilot_finish_tdd_attempt \
    "$R8" "tdd-done-${C8}" "$P8" "$S8" 1 "$C8" max-rounds true "$T8" \
    >/dev/null 2>&1
  printf '%s\n' "$?" > "$P8/finish.rc"
) &
FINISH_PID=$!
wait "$REARM_PID"
wait "$FINISH_PID"
RF8="$(autopilot_run_file "$R8" "$P8")"
TF8="$(tdd_state_file "$S8")"
if [ "$(cat "$P8/rearm.rc")" = 0 ] \
  && pair_ok "$RF8" "$TF8" '
    !(outer.stage === "BLOCKED" && inner.active === true && inner.chainDone === false)
      && ((outer.stage === "TDD_RUNNING"
          && inner.active === true && inner.implComplete === true
          && inner.chainDone === false && inner.chainOutcome === "")
        || (outer.stage === "AWAIT_TDD"
          && inner.active === false && inner.chainDone === false && inner.chainOutcome === ""
          && outer.events.some(event => event.eventType === "TDD_CHAIN_DONE"
            && event.payload && event.payload.outcome === "max-rounds")))'; then
  check "X8 outer-lock serializes parallel finish versus composite rearm" PASS
else
  check "X8 parallel finish/rearm cannot create BLOCKED plus active unfinished Inner" FAIL
fi

# A terminal outer run may clear only the generation it still names. A stale
# attempt-N reset must lose its CAS once attempt N+1 owns both files.
P9="$ROOT/stale-reset"
R9=adversarial_stale_reset_run
S9=adversarial_stale_reset_session
C9A=adversarial-stale-reset-chain-a
C9B=adversarial-stale-reset-chain-b
HEAD9=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
prepare_session "$P9" "$S9" S9 || exit 1
approve "$P9" "$R9" "$S9" && begin_bound "$P9" "$R9" "$S9" 1 "$C9A" \
  && mark_complete "$P9" "$R9" "$S9" 1 "$C9A" \
  && CLAUDE_PROJECT_DIR="$P9" autopilot_finish_tdd_attempt \
    "$R9" "tdd-done-${C9A}" "$P9" "$S9" 1 "$C9A" pass false >/dev/null \
  && autopilot_apply_event "$R9" adversarial-gates-failed GATES_FAILED \
    "{\"headSha\":\"$HEAD9\",\"reason\":\"retry\"}" "$P9" "$S9" >/dev/null \
  && begin_bound "$P9" "$R9" "$S9" 2 "$C9B" \
  && autopilot_apply_event "$R9" adversarial-cancel-newer CANCEL '{}' \
    "$P9" "$S9" >/dev/null || exit 1
TF9="$(tdd_state_file "$S9")"
BEFORE9="$(digest "$TF9")"
STALE_RESET_REJECTED=true
CLAUDE_PROJECT_DIR="$P9" tdd_clear_autopilot_session \
  "$S9" "$R9" 1 "$C9A" >/dev/null 2>&1 && STALE_RESET_REJECTED=false
CLAUDE_PROJECT_DIR="$P9" autopilot_reset_inner \
  "$R9" "$P9" "$S9" 1 "$C9A" >/dev/null 2>&1 && STALE_RESET_REJECTED=false
if [ "$STALE_RESET_REJECTED" = true ] \
  && [ "$(digest "$TF9")" = "$BEFORE9" ] \
  && field_ok "$TF9" \
    'value.active === true && value.autopilotAttempt === 2 && value.chainId === "adversarial-stale-reset-chain-b"' \
  && CLAUDE_PROJECT_DIR="$P9" autopilot_reset_inner \
    "$R9" "$P9" "$S9" 2 "$C9B" >/dev/null; then
  check "X9 bound reset CAS cannot delete a newer attempt" PASS
else
  check "X9 stale bound reset leaves the newer attempt byte-stable" FAIL
fi

# The shared state-verb parser rejects malformed invocations before it resolves
# a state mutation. In particular, known-but-invalid options are not silently
# ignored and explicit empty sessions do not fall back to an implicit session.
P10="$ROOT/strict-cli"
S10=adversarial_strict_cli_session
mkdir -p "$P10"
prepare_session "$P10" "$S10" S10 || exit 1
CLAUDE_PROJECT_DIR="$P10" bash "$LOG" --tdd-begin --session "$S10" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P10" bash "$LOG" --tdd-complete --session "$S10" >/dev/null \
  || exit 1
TF10="$(tdd_state_file "$S10")"
BEFORE10="$(digest "$TF10")"
cli_rc() {
  CLAUDE_PROJECT_DIR="$P10" bash "$LOG" "$@" >/dev/null 2>&1
  printf '%s\n' "$?"
}
RC10_DUP="$(cli_rc --review-ticket --session "$S10" --session "$S10")"
RC10_EMPTY="$(cli_rc --review-ticket --session '')"
RC10_UNKNOWN="$(cli_rc --review-ticket --session "$S10" --not-a-zensu-option value)"
RC10_INVALID="$(cli_rc --review-ticket --session "$S10" --tools Bash)"
if [ "$RC10_DUP" = 2 ] && [ "$RC10_EMPTY" = 2 ] \
  && [ "$RC10_UNKNOWN" = 2 ] && [ "$RC10_INVALID" = 2 ] \
  && [ "$(digest "$TF10")" = "$BEFORE10" ]; then
  check "X10 strict CLI rejects duplicate/empty session and invalid flags byte-stably" PASS
else
  check "X10 malformed state-verb CLI returns rc=2 without mutation" FAIL
fi

# Pending-review adoption is a three-lock composite: Outer project inventory,
# pending marker/claim, then the seeded Inner session. With no outer inventory,
# the wrapper preserves the existing deferred-review behavior.
P11="$ROOT/adopt-absent"
S11=adversarial_adopt_absent_session
mkdir -p "$P11"
prepare_session "$P11" "$S11" S11 || exit 1
CLAUDE_PROJECT_DIR="$P11" TDD_STATE_DIR="$P11/.zensu/state" \
  tdd_write_pending_review absent.ts "absent outer fixture" >/dev/null || exit 1
if CLAUDE_PROJECT_DIR="$P11" TDD_STATE_DIR="$P11/.zensu/state" \
    autopilot_adopt_pending_review "$P11" "$S11" true 0 >/dev/null 2>&1 \
  && [ -f "$P11/.zensu/state/pending-review.json.claim" ] \
  && [ ! -e "$P11/.zensu/state/pending-review.json" ] \
  && field_ok "$(tdd_state_file "$S11")" \
    'value.active === true && value.implComplete === true && value.chainDone === false'; then
  check "X11 absent Outer inventory permits composite pending-review adoption" PASS
else
  check "X11 absent Outer inventory keeps deferred-review adoption compatible" FAIL
fi

# The inner API uses rc=2 for "nothing queued", while rc=2 from the Outer read
# means corrupt/unsafe durable inventory. The composite exposes no-work as rc=6
# so Stop can distinguish a benign empty queue from fail-closed corruption.
P11B="$ROOT/adopt-no-marker"
S11B=adversarial_adopt_no_marker_session
mkdir -p "$P11B"
prepare_session "$P11B" "$S11B" S11B || exit 1
TF11B="$(tdd_state_file "$S11B")"; BEFORE11B_INNER="$(digest "$TF11B")"
_autopilot_prepare_storage "$P11B" || exit 1
CLAUDE_PROJECT_DIR="$P11B" TDD_STATE_DIR="$P11B/.zensu/state" \
  autopilot_adopt_pending_review "$P11B" "$S11B" true 0 >/dev/null 2>&1
RC11B=$?
FILES11B="$(find "$P11B/.zensu/state" -maxdepth 1 -type f \
  ! -name 'autopilot.lock' ! -name 'pending-review.json.lock' \
  ! -name "$(basename "$TF11B")" ! -name "$(basename "$TF11B").lock" \
  | wc -l | tr -d '[:space:]')"
if [ "$RC11B" = 6 ] && [ "$FILES11B" = 0 ] \
  && [ ! -e "$P11B/.zensu/state/pending-review.json.claim" ] \
  && [ "$(digest "$TF11B")" = "$BEFORE11B_INNER" ] \
  && field_ok "$TF11B" 'value.active === false && value.implComplete === false && value.chainDone === false'; then
  check "X11b empty pending queue returns distinct no-work rc=6 byte-stably" PASS
else
  check "X11b no-work cannot collide with corrupt Outer rc=2 (rc=$RC11B files=$FILES11B)" FAIL
fi

# Failures inside the pending/Inner layer retain their legacy rc=1 and must not
# be collapsed into either no-work or corrupt-Outer status.
P11C="$ROOT/adopt-inner-failure"
S11C=adversarial_adopt_inner_failure_session
mkdir -p "$P11C/.zensu/state"
prepare_session "$P11C" "$S11C" S11C || exit 1
TF11C="$(tdd_state_file "$S11C")"; BEFORE11C_INNER="$(digest "$TF11C")"
printf '%s\n' '{"files":["safe.ts"],"summary":"must stay outside"}' > "$P11C/outside-pending.json"
if make_file_symlink "$P11C/outside-pending.json" \
    "$P11C/.zensu/state/pending-review.json"; then
  BEFORE11C="$(digest "$P11C/outside-pending.json")"
  CLAUDE_PROJECT_DIR="$P11C" TDD_STATE_DIR="$P11C/.zensu/state" \
    autopilot_adopt_pending_review "$P11C" "$S11C" true 0 >/dev/null 2>&1
  RC11C=$?
  if [ "$RC11C" = 1 ] \
    && [ "$(digest "$P11C/outside-pending.json")" = "$BEFORE11C" ] \
    && [ -L "$P11C/.zensu/state/pending-review.json" ] \
    && [ ! -e "$P11C/.zensu/state/pending-review.json.claim" ] \
    && [ "$(digest "$TF11C")" = "$BEFORE11C_INNER" ]; then
    check "X11c pending/Inner mutation failure remains distinct rc=1" PASS
  else
    check "X11c inner failure cannot look like no-work or Outer corruption (rc=$RC11C)" FAIL
  fi
elif [ "$IS_WINDOWS" = true ]; then
  check "X11c pending/Inner symlink rejection (native file symlinks unavailable)" PASS
else
  check "X11c pending/Inner symlink fixture creation failed" FAIL
fi

# CANCELLED is genuinely terminal and does not retain ownership. It therefore
# permits a later standalone deferred review, unlike resumable BLOCKED.
P12="$ROOT/adopt-cancelled"
R12=adversarial_adopt_cancelled_run
O12=adversarial_adopt_cancelled_owner
S12=adversarial_adopt_after_cancel
mkdir -p "$P12"
prepare_session "$P12" "$O12" O12 || exit 1
autopilot_begin_run "$R12" "$O12" "$P12" >/dev/null \
  && autopilot_apply_event "$R12" adversarial-adopt-cancel CANCEL '{}' \
    "$P12" "$O12" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P12" TDD_STATE_DIR="$P12/.zensu/state" \
    tdd_write_pending_review cancelled.ts "cancelled outer fixture" >/dev/null || exit 1
prepare_session "$P12" "$S12" S12 || exit 1
if CLAUDE_PROJECT_DIR="$P12" TDD_STATE_DIR="$P12/.zensu/state" \
    autopilot_adopt_pending_review "$P12" "$S12" false 0 >/dev/null 2>&1 \
  && field_ok "$(tdd_state_file "$S12")" \
    'value.active === true && value.implComplete === true && value.chainDone === false' \
  && field_ok "$(autopilot_run_file "$R12" "$P12")" 'value.stage === "CANCELLED"'; then
  check "X12 CANCELLED Outer history permits composite pending-review adoption" PASS
else
  check "X12 terminal CANCELLED does not suppress a later deferred review" FAIL
fi

# BLOCKED is resumable and still owns the project. Adoption must return rc=4
# without moving the marker, writing a claim, seeding Inner, or changing Outer.
P13="$ROOT/adopt-blocked"
R13=adversarial_adopt_blocked_run
O13=adversarial_adopt_blocked_owner
S13=adversarial_adopt_blocked_contender
mkdir -p "$P13"
prepare_session "$P13" "$O13" O13 || exit 1
autopilot_begin_run "$R13" "$O13" "$P13" >/dev/null \
  && autopilot_apply_event "$R13" adversarial-adopt-block BLOCK \
    '{"code":"ADOPTION_BLOCKED_FIXTURE"}' "$P13" "$O13" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P13" TDD_STATE_DIR="$P13/.zensu/state" \
    tdd_write_pending_review blocked.ts "blocked outer fixture" >/dev/null || exit 1
prepare_session "$P13" "$S13" S13 || exit 1
TF13="$(tdd_state_file "$S13")"; BEFORE13_INNER="$(digest "$TF13")"
RF13="$(autopilot_run_file "$R13" "$P13")"
PF13="$P13/.zensu/state/pending-review.json"
BEFORE13_OUTER="$(digest "$RF13")"; BEFORE13_PENDING="$(digest "$PF13")"
CLAUDE_PROJECT_DIR="$P13" TDD_STATE_DIR="$P13/.zensu/state" \
  autopilot_adopt_pending_review "$P13" "$S13" true 0 >/dev/null 2>&1
RC13=$?
if [ "$RC13" = 4 ] \
  && [ "$(digest "$RF13")" = "$BEFORE13_OUTER" ] \
  && [ "$(digest "$PF13")" = "$BEFORE13_PENDING" ] \
  && [ ! -e "${PF13}.claim" ] \
  && [ "$(digest "$TF13")" = "$BEFORE13_INNER" ]; then
  check "X13 BLOCKED Outer rejects pending adoption byte-stably" PASS
else
  check "X13 BLOCKED cannot be mistaken for a terminal adoption window" FAIL
fi

# Corrupt durable inventory is not absence. The pending marker and every Inner
# path remain untouched when strict read-active validation fails.
P14="$ROOT/adopt-corrupt"
R14=adversarial_adopt_corrupt_run
O14=adversarial_adopt_corrupt_owner
S14=adversarial_adopt_corrupt_contender
mkdir -p "$P14"
prepare_session "$P14" "$O14" O14 || exit 1
autopilot_begin_run "$R14" "$O14" "$P14" >/dev/null \
  && CLAUDE_PROJECT_DIR="$P14" TDD_STATE_DIR="$P14/.zensu/state" \
    tdd_write_pending_review corrupt.ts "corrupt outer fixture" >/dev/null || exit 1
prepare_session "$P14" "$S14" S14 || exit 1
TF14="$(tdd_state_file "$S14")"; BEFORE14_INNER="$(digest "$TF14")"
AF14="$(autopilot_active_file "$P14" "$O14")"; RF14="$(autopilot_run_file "$R14" "$P14")"
# Adoption judges workspace occupancy from the run inventory, so the run
# record is where corruption has to fail it closed.
RF14="$RF14" node -e '
  const fs=require("fs"),p=process.env.RF14,j=JSON.parse(fs.readFileSync(p));
  j.extra=true;fs.writeFileSync(p,JSON.stringify(j));
'
PF14="$P14/.zensu/state/pending-review.json"
BEFORE14_ACTIVE="$(digest "$AF14")"; BEFORE14_OUTER="$(digest "$RF14")"
BEFORE14_PENDING="$(digest "$PF14")"
CLAUDE_PROJECT_DIR="$P14" TDD_STATE_DIR="$P14/.zensu/state" \
  autopilot_adopt_pending_review "$P14" "$S14" true 0 >/dev/null 2>&1
RC14=$?
if [ "$RC14" = 2 ] \
  && [ "$(digest "$AF14")" = "$BEFORE14_ACTIVE" ] \
  && [ "$(digest "$RF14")" = "$BEFORE14_OUTER" ] \
  && [ "$(digest "$PF14")" = "$BEFORE14_PENDING" ] \
  && [ ! -e "${PF14}.claim" ] \
  && [ "$(digest "$TF14")" = "$BEFORE14_INNER" ]; then
  check "X14 corrupt Outer inventory fails pending adoption closed" PASS
else
  check "X14 corrupt inventory never degrades to absent adoption" FAIL
fi

# Hold the Outer mutex across begin's run+pointer publication, then start an
# adopter that signals immediately before it attempts the same mutex. Once the
# holder releases, adoption must observe the completed nonterminal begin and
# return rc=4 without consuming the queued marker.
_adversarial_publish_begin_critical() {
  local project="$1" run_id="$2" owner="$3" entered="$4" release="$5"
  : > "$entered"
  while [ ! -e "$release" ]; do sleep 0.01; done
  _autopilot_begin_critical "$project" "$run_id" "$owner" false true \
    "$(autopilot_workspace_root "$project")"
}
P15="$ROOT/adopt-race"
R15=adversarial_adopt_race_run
O15=adversarial_adopt_race_owner
S15=adversarial_adopt_race_contender
mkdir -p "$P15"
prepare_session "$P15" "$O15" O15 || exit 1
P15_CANON="$(_autopilot_project_root "$P15")" || exit 1
CLAUDE_PROJECT_DIR="$P15" TDD_STATE_DIR="$P15/.zensu/state" \
  tdd_write_pending_review race.ts "concurrent begin fixture" >/dev/null || exit 1
prepare_session "$P15" "$S15" S15 || exit 1
TF15="$(tdd_state_file "$S15")"; BEFORE15_INNER="$(digest "$TF15")"
PF15="$P15/.zensu/state/pending-review.json"; BEFORE15_PENDING="$(digest "$PF15")"
_autopilot_prepare_storage "$P15_CANON" || exit 1
(
  _autopilot_locked_run "$P15_CANON" "$R15" _adversarial_publish_begin_critical \
    "$P15_CANON" "$R15" "$O15" "$P15/begin-entered" "$P15/release-begin"
  printf '%s\n' "$?" > "$P15/begin.rc"
) & PID15_BEGIN=$!
for _ in {1..500}; do [ -e "$P15/begin-entered" ] && break; sleep 0.01; done
(
  eval "$(declare -f _autopilot_locked_run | sed '1s/_autopilot_locked_run/_adversarial_original_locked_run/')"
  # This override is invoked indirectly by the public helper.
  # shellcheck disable=SC2329
  _autopilot_locked_run() {
    : > "$P15/adopt-lock-attempted"
    _adversarial_original_locked_run "$@"
  }
  CLAUDE_PROJECT_DIR="$P15" TDD_STATE_DIR="$P15/.zensu/state" \
    autopilot_adopt_pending_review "$P15" "$S15" true 0 >/dev/null 2>&1
  printf '%s\n' "$?" > "$P15/adopt.rc"
) & PID15_ADOPT=$!
for _ in {1..500}; do
  [ -e "$P15/adopt-lock-attempted" ] || [ -e "$P15/adopt.rc" ] && break
  sleep 0.01
done
ADOPT_WAITED=true
[ -e "$P15/adopt.rc" ] && ADOPT_WAITED=false
: > "$P15/release-begin"
wait "$PID15_BEGIN"; wait "$PID15_ADOPT"
if [ "$ADOPT_WAITED" = true ] \
  && [ "$(cat "$P15/begin.rc")" = 0 ] && [ "$(cat "$P15/adopt.rc")" = 4 ] \
  && [ "$(digest "$PF15")" = "$BEFORE15_PENDING" ] \
  && [ ! -e "${PF15}.claim" ] \
  && [ "$(digest "$TF15")" = "$BEFORE15_INNER" ] \
  && field_ok "$(autopilot_run_file "$R15" "$P15")" 'value.stage === "PLANNING"'; then
  check "X15 Outer lock serializes pending adoption behind concurrent begin" PASS
else
  check "X15 concurrent begin wins without pending or Inner split-brain (waited=$ADOPT_WAITED begin=$(cat "$P15/begin.rc" 2>/dev/null) adopt=$(cat "$P15/adopt.rc" 2>/dev/null) lock=$([ -e "$P15/adopt-lock-attempted" ] && echo yes || echo no))" FAIL
fi

# An Inner claim/seed rc=1 is permanent for the current composite transaction.
# The critical helper tags it internally so only genuine Outer-lock contention
# is retried, while the public API keeps its historical rc=1 contract.
P16="$ROOT/nonretry-inner-failure"
S16=adversarial_nonretry_inner
mkdir -p "$P16/.zensu/state"
prepare_session "$P16" "$S16" S16 || exit 1
P16_CANON="$(_autopilot_project_root "$P16")" || exit 1
tdd_adopt_pending_review() { return 1; }
if _autopilot_adopt_pending_review_critical "$P16_CANON" "$S16" true 0 "$$" >/dev/null 2>&1; then
  INNER_RC16=0
else
  INNER_RC16=$?
fi
ADOPT_CALLS16=0
_autopilot_locked_run() {
  ADOPT_CALLS16=$((ADOPT_CALLS16 + 1))
  return 7
}
if autopilot_adopt_pending_review "$P16" "$S16" true 0 >/dev/null 2>&1; then
  PUBLIC_RC16=0
else
  PUBLIC_RC16=$?
fi
if [ "$INNER_RC16" -eq 7 ] && [ "$PUBLIC_RC16" -eq 1 ] \
  && [ "$ADOPT_CALLS16" -eq 1 ]; then
  check "X16 permanent Inner adoption failure preserves public rc=1 without transaction retries" PASS
else
  check "X16 Inner failure mapping (inner=$INNER_RC16 public=$PUBLIC_RC16 calls=$ADOPT_CALLS16)" FAIL
fi
# X16 intentionally replaces the public lock wrapper to count retries. Restore
# the production implementation before the native-path integration fixture.
# shellcheck disable=SC1090
source "$STATE_LIB" || exit 1

# Outer-lock contention must not turn a safely foreign-owned deferred review
# into repeated fail-closed Stop prompts. After a fresh absent-Outer read, the
# public composite may prove the foreign claim read-only and return no-work.
P16B="$ROOT/owned-claim-contention"
O16B=adversarial_contention_owner
S16B=adversarial_contention_contender
mkdir -p "$P16B"
prepare_session "$P16B" "$O16B" O16B || exit 1
CLAUDE_PROJECT_DIR="$P16B" TDD_STATE_DIR="$P16B/.zensu/state" \
  tdd_write_pending_review owned.ts "owned contention fixture" >/dev/null || exit 1
tdd_adopt_pending_review "$O16B" true 0 "${BASHPID:-$$}" >/dev/null || exit 1
tdd_mark_pending_review_handoff "$O16B" "${BASHPID:-$$}" >/dev/null || exit 1
OWNER_STATE16B="$(tdd_state_file "$O16B")"
CLAIM16B="$P16B/.zensu/state/pending-review.json.claim"
BEFORE_OWNER16B="$(digest "$OWNER_STATE16B")"
BEFORE_CLAIM16B="$(digest "$CLAIM16B")"
prepare_session "$P16B" "$S16B" S16B || exit 1
CONTENDER_STATE16B="$(tdd_state_file "$S16B")"
BEFORE_CONTENDER16B="$(digest "$CONTENDER_STATE16B")"
LOCK_ATTEMPTS16B=0
_autopilot_locked_run() {
  LOCK_ATTEMPTS16B=$((LOCK_ATTEMPTS16B + 1))
  return 1
}
if autopilot_adopt_pending_review "$P16B" "$S16B" true 0 >/dev/null 2>&1; then
  RC16B=0
else
  RC16B=$?
fi
if [ "$RC16B" -eq 6 ] && [ "$LOCK_ATTEMPTS16B" -eq 1 ] \
    && [ "$(digest "$OWNER_STATE16B")" = "$BEFORE_OWNER16B" ] \
    && [ "$(digest "$CLAIM16B")" = "$BEFORE_CLAIM16B" ] \
    && [ "$(digest "$CONTENDER_STATE16B")" = "$BEFORE_CONTENDER16B" ]; then
  check "X16b foreign-owned claim releases Outer-lock contention as byte-stable no-work" PASS
else
  check "X16b owned contention fallback (rc=$RC16B attempts=$LOCK_ATTEMPTS16B)" FAIL
fi

# rc=1 can also mean unsafe Outer storage rather than ordinary lease
# contention. A valid foreign claim must never mask that evidence as no-work.
mkdir "$P16B/.zensu/state/autopilot" || exit 1
LOCK_ATTEMPTS16B_UNSAFE=0
_autopilot_locked_run() {
  LOCK_ATTEMPTS16B_UNSAFE=$((LOCK_ATTEMPTS16B_UNSAFE + 1))
  return 1
}
if autopilot_adopt_pending_review "$P16B" "$S16B" true 0 >/dev/null 2>&1; then
  RC16B_UNSAFE=0
else
  RC16B_UNSAFE=$?
fi
rmdir "$P16B/.zensu/state/autopilot" || exit 1
if [ "$RC16B_UNSAFE" -eq 2 ] && [ "$LOCK_ATTEMPTS16B_UNSAFE" -eq 1 ] \
    && [ "$(digest "$OWNER_STATE16B")" = "$BEFORE_OWNER16B" ] \
    && [ "$(digest "$CLAIM16B")" = "$BEFORE_CLAIM16B" ] \
    && [ "$(digest "$CONTENDER_STATE16B")" = "$BEFORE_CONTENDER16B" ]; then
  check "X16b2 unsafe Outer storage cannot masquerade as owned-claim no-work" PASS
else
  check "X16b2 unsafe contention evidence (rc=$RC16B_UNSAFE attempts=$LOCK_ATTEMPTS16B_UNSAFE)" FAIL
fi

# read-active is intentionally unlocked in the fallback. During begin it may
# see the run before the active pointer and return rc=2 even though storage is
# safe; that observation is inconclusive and must go back through all bounded
# serialized retries rather than becoming an immediate corruption decision.
# shellcheck disable=SC1090
source "$STATE_LIB" || exit 1
prepare_session "$P16B" adversarial_contention_contender S16B || exit 1
LOCK_ATTEMPTS16B_TRANSIENT_FIRST=0
_autopilot_locked_run() {
  LOCK_ATTEMPTS16B_TRANSIENT_FIRST=$((LOCK_ATTEMPTS16B_TRANSIENT_FIRST + 1))
  return 1
}
_autopilot_node() { return 2; }
if autopilot_adopt_pending_review "$P16B" "$S16B" true 0 >/dev/null 2>&1; then
  RC16B_TRANSIENT_FIRST=0
else
  RC16B_TRANSIENT_FIRST=$?
fi
if [ "$RC16B_TRANSIENT_FIRST" -eq 1 ] \
    && [ "$LOCK_ATTEMPTS16B_TRANSIENT_FIRST" -eq 5 ] \
    && [ "$(digest "$OWNER_STATE16B")" = "$BEFORE_OWNER16B" ] \
    && [ "$(digest "$CLAIM16B")" = "$BEFORE_CLAIM16B" ] \
    && [ "$(digest "$CONTENDER_STATE16B")" = "$BEFORE_CONTENDER16B" ]; then
  check "X16b3 transient first Outer read returns to bounded serialized retry" PASS
else
  check "X16b3 first-read transient routing (rc=$RC16B_TRANSIENT_FIRST attempts=$LOCK_ATTEMPTS16B_TRANSIENT_FIRST)" FAIL
fi

# The second read is the linearization fence and can hit the same transient.
# It likewise cannot authorize no-work or emit an immediate corruption result.
# shellcheck disable=SC1090
source "$STATE_LIB" || exit 1
prepare_session "$P16B" adversarial_contention_contender S16B || exit 1
LOCK_ATTEMPTS16B_TRANSIENT_FENCE=0
READ_MARKER16B_TRANSIENT="$P16B/first-transient-fence-read"
rm -f "$READ_MARKER16B_TRANSIENT"
_autopilot_locked_run() {
  LOCK_ATTEMPTS16B_TRANSIENT_FENCE=$((LOCK_ATTEMPTS16B_TRANSIENT_FENCE + 1))
  return 1
}
_autopilot_node() {
  if [ ! -e "$READ_MARKER16B_TRANSIENT" ]; then
    : > "$READ_MARKER16B_TRANSIENT"
    return 1
  fi
  return 2
}
if autopilot_adopt_pending_review "$P16B" "$S16B" true 0 >/dev/null 2>&1; then
  RC16B_TRANSIENT_FENCE=0
else
  RC16B_TRANSIENT_FENCE=$?
fi
if [ "$RC16B_TRANSIENT_FENCE" -eq 1 ] \
    && [ "$LOCK_ATTEMPTS16B_TRANSIENT_FENCE" -eq 5 ] \
    && [ -e "$READ_MARKER16B_TRANSIENT" ] \
    && [ "$(digest "$OWNER_STATE16B")" = "$BEFORE_OWNER16B" ] \
    && [ "$(digest "$CLAIM16B")" = "$BEFORE_CLAIM16B" ] \
    && [ "$(digest "$CONTENDER_STATE16B")" = "$BEFORE_CONTENDER16B" ]; then
  check "X16b4 transient final Outer fence returns to bounded serialized retry" PASS
else
  check "X16b4 final-fence transient routing (rc=$RC16B_TRANSIENT_FENCE attempts=$LOCK_ATTEMPTS16B_TRANSIENT_FENCE marker=$([ -e "$READ_MARKER16B_TRANSIENT" ] && echo yes || echo no))" FAIL
fi

# A current nonterminal Outer generation remains authoritative even when a
# foreign deferred claim is present: the same contention fallback must route
# back to the Outer state instead of using the no-work proof.
# shellcheck disable=SC1090
source "$STATE_LIB" || exit 1
P16C="$ROOT/active-outer-contention"
R16C=adversarial_active_outer_contention_run
O16C=adversarial_active_outer_contention_owner
S16C=adversarial_active_outer_contention_contender
mkdir -p "$P16C"
prepare_session "$P16C" "$O16C" O16C || exit 1
CLAUDE_PROJECT_DIR="$P16C" TDD_STATE_DIR="$P16C/.zensu/state" \
  tdd_write_pending_review outer-owned.ts "active outer contention fixture" >/dev/null || exit 1
tdd_adopt_pending_review "$O16C" true 0 "${BASHPID:-$$}" >/dev/null || exit 1
tdd_mark_pending_review_handoff "$O16C" "${BASHPID:-$$}" >/dev/null || exit 1
autopilot_begin_run "$R16C" "$O16C" "$P16C" >/dev/null || exit 1
CLAIM16C="$P16C/.zensu/state/pending-review.json.claim"
RUN16C="$(autopilot_run_file "$R16C" "$P16C")"
BEFORE_CLAIM16C="$(digest "$CLAIM16C")"
BEFORE_RUN16C="$(digest "$RUN16C")"
prepare_session "$P16C" "$S16C" S16C || exit 1
LOCK_ATTEMPTS16C=0
_autopilot_locked_run() {
  LOCK_ATTEMPTS16C=$((LOCK_ATTEMPTS16C + 1))
  return 1
}
if autopilot_adopt_pending_review "$P16C" "$S16C" true 0 >/dev/null 2>&1; then
  RC16C=0
else
  RC16C=$?
fi
if [ "$RC16C" -eq 4 ] && [ "$LOCK_ATTEMPTS16C" -eq 1 ] \
    && [ "$(digest "$CLAIM16C")" = "$BEFORE_CLAIM16C" ] \
    && [ "$(digest "$RUN16C")" = "$BEFORE_RUN16C" ]; then
  check "X16c active Outer remains authoritative during owned-claim contention" PASS
else
  check "X16c active Outer contention routing (rc=$RC16C attempts=$LOCK_ATTEMPTS16C)" FAIL
fi
# Restore the production lock wrapper before the remaining integration cases.
# shellcheck disable=SC1090
source "$STATE_LIB" || exit 1

# The final unlocked Outer read is the contention proof's linearization fence.
# Force the first read to report absence, keep the foreign claim valid, then let
# the real second read reveal the already-active run; routing must still be rc=4.
eval "$(declare -f _autopilot_node | sed '1s/_autopilot_node/_adversarial_original_node_16d/')"
LOCK_ATTEMPTS16D=0
READ_MARKER16D="$P16C/first-contention-read"
rm -f "$READ_MARKER16D"
_autopilot_locked_run() {
  LOCK_ATTEMPTS16D=$((LOCK_ATTEMPTS16D + 1))
  return 1
}
_autopilot_node() {
  # The contention proof reads workspace occupancy, so that is the mode whose
  # first answer has to be forced to absence for the fence to be observable.
  if [ "${1:-}" = read-workspace ] && [ ! -e "$READ_MARKER16D" ]; then
    : > "$READ_MARKER16D"
    return 1
  fi
  _adversarial_original_node_16d "$@"
}
if autopilot_adopt_pending_review "$P16C" "$S16C" true 0 >/dev/null 2>&1; then
  RC16D=0
else
  RC16D=$?
fi
if [ "$RC16D" -eq 4 ] && [ "$LOCK_ATTEMPTS16D" -eq 1 ] \
    && [ -e "$READ_MARKER16D" ] \
    && [ "$(digest "$CLAIM16C")" = "$BEFORE_CLAIM16C" ] \
    && [ "$(digest "$RUN16C")" = "$BEFORE_RUN16C" ]; then
  check "X16d second Outer read fences the owned-claim contention proof" PASS
else
  check "X16d contention TOCTOU fence (rc=$RC16D attempts=$LOCK_ATTEMPTS16D marker=$([ -e "$READ_MARKER16D" ] && echo yes || echo no))" FAIL
fi
# shellcheck disable=SC1090
source "$STATE_LIB" || exit 1

# Git Bash skips or misapplies its heuristic path conversion for some quoted
# values (notably apostrophes). Exercise every Autopilot worker path schema plus
# direct payload and Inner-state Node boundaries under one immutable binding.
P17="$ROOT/native path O'Brien project"
SOURCE_DIR17="$ROOT/external review O'Brien source"
FOREIGN17="$ROOT/foreign project O'Brien"
R17=adversarial_native_path_run
RAW17=adversarial_native_path_session
C17=adversarial-native-path-chain
HEAD17=1717171717171717171717171717171717171717
PLAN17=1717171717171717171717171717171717171717171717171717171717171717
mkdir -p "$P17" "$SOURCE_DIR17" "$FOREIGN17"
prepare_session "$P17" "$RAW17" S17 || exit 1
SOURCE17="$SOURCE_DIR17/review payload with spaces.json"
printf '%s\n' \
  "{\"comments\":[],\"body\":\"special-path review\",\"event\":\"COMMENT\",\"commit_id\":\"$HEAD17\"}" \
  > "$SOURCE17"
NATIVE17_OK=true
SHELL_ROOT17="$(zensu_resolve_project_dir)" || NATIVE17_OK=false
NATIVE_DESC17="${ZENSU_PROJECT_ROOT%/}/.zensu/state"
FOREIGN_NATIVE17="$(bash "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$FOREIGN17")" \
  || NATIVE17_OK=false
[ "$(_autopilot_native_project_path "$NATIVE_DESC17" 2>/dev/null)" = "$NATIVE_DESC17" ] \
  || NATIVE17_OK=false
if _autopilot_native_project_path "$FOREIGN_NATIVE17" >/dev/null 2>&1; then
  NATIVE17_OK=false
fi
if _autopilot_native_project_path \
    "$SHELL_ROOT17/../$(basename "$FOREIGN17")/.zensu/state" >/dev/null 2>&1; then
  NATIVE17_OK=false
fi
if autopilot_begin_run adversarial_foreign_path_run "$S17" "$FOREIGN17" \
    >/dev/null 2>&1 || [ -e "$FOREIGN17/.zensu" ]; then
  NATIVE17_OK=false
fi
autopilot_begin_run "$R17" "$S17" "$P17" >/dev/null || NATIVE17_OK=false
[ "$(autopilot_increment_stop_budget "$R17" PLANNING "$P17" "$S17" 2>/dev/null)" = 1 ] \
  || NATIVE17_OK=false
printf '%s' "$(autopilot_increment_stop_budget_capped \
  "$R17" PLANNING "$P17" "$S17" 5 SPECIAL_PATH_CAP 2>/dev/null)" \
  | grep -qF '"count":2,"blocked":false' || NATIVE17_OK=false
autopilot_apply_event "$R17" native-path-plan PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$PLAN17\"}" "$P17" "$S17" >/dev/null \
  || NATIVE17_OK=false
begin_bound "$P17" "$R17" "$S17" 1 "$C17" || NATIVE17_OK=false
# Exact replay enters the direct Inner STATE_FILE verifier.
begin_bound "$P17" "$R17" "$S17" 1 "$C17" || NATIVE17_OK=false
autopilot_apply_event "$R17" native-path-tdd-done TDD_CHAIN_DONE \
  "{\"attempt\":1,\"chainId\":\"$C17\",\"sessionId\":\"$S17\",\"outcome\":\"pass\"}" \
  "$P17" "$S17" >/dev/null || NATIVE17_OK=false
autopilot_apply_event "$R17" native-path-gates GATES_PASSED \
  "{\"headSha\":\"$HEAD17\"}" "$P17" "$S17" >/dev/null || NATIVE17_OK=false
autopilot_apply_event "$R17" native-path-converge CONVERGENCE_PASSED '{}' \
  "$P17" "$S17" >/dev/null || NATIVE17_OK=false
PR_KEY17="pr:$R17"
autopilot_apply_event "$R17" native-path-pr-request PR_OPEN_REQUESTED \
  "{\"operationKey\":\"$PR_KEY17\"}" "$P17" "$S17" >/dev/null || NATIVE17_OK=false
autopilot_apply_event "$R17" native-path-pr-open PR_OPENED \
  "{\"operationKey\":\"$PR_KEY17\",\"pr\":{\"number\":17,\"url\":\"https://github.com/acme/repo/pull/17\",\"headSha\":\"$HEAD17\"}}" \
  "$P17" "$S17" >/dev/null || NATIVE17_OK=false
REVIEW_KEY17="$(autopilot_team_review_operation_key "$R17" "$HEAD17")" \
  || NATIVE17_OK=false
autopilot_apply_event "$R17" native-path-review-request TEAM_REVIEW_REQUESTED \
  "{\"operationKey\":\"$REVIEW_KEY17\",\"provider\":\"github\"}" \
  "$P17" "$S17" >/dev/null || NATIVE17_OK=false
SNAPSHOT17="$(autopilot_store_team_review_payload "$R17" "$REVIEW_KEY17" "$HEAD17" \
  "$SOURCE17" github "$P17" 2>/dev/null)" || NATIVE17_OK=false
DIGEST17="$(_autopilot_team_review_payload_inspect \
  "$SNAPSHOT17" "$HEAD17" true canonical 2>/dev/null)" || NATIVE17_OK=false
OP_DIGEST17="$(printf '%s' "$REVIEW_KEY17" \
  | node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(0)).digest("hex"));')"
MARKER17="<!-- zensu-review:v1:${OP_DIGEST17}:${DIGEST17}:${HEAD17}:1:part=1/1 -->"
autopilot_apply_event "$R17" native-path-review-published TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY17\",\"marker\":\"$MARKER17\",\"headSha\":\"$HEAD17\",\"provider\":\"github\"}" \
  "$P17" "$S17" >/dev/null || NATIVE17_OK=false
FINAL17="$ROOT/native-path-final.json"
autopilot_read_run "$R17" "$P17" > "$FINAL17" 2>/dev/null || NATIVE17_OK=false
if [ "$NATIVE17_OK" = true ] \
  && [ -n "$SNAPSHOT17" ] && cmp -s "$SOURCE17" "$SNAPSHOT17" \
  && field_ok "$FINAL17" 'value.stage === "FIX_FINDINGS" && value.evidence.review.provider === "github"' \
  && [ -f "$(tdd_state_file "$S17")" ]; then
  check "X17 immutable native paths survive spaces and apostrophes across the full worker flow" PASS
else
  check "X17 native special-path flow remains coherent (ready=$NATIVE17_OK snapshot=${SNAPSHOT17:-missing})" FAIL
fi

printf '%s\n' "----" "test-autopilot-adversarial-recovery: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
