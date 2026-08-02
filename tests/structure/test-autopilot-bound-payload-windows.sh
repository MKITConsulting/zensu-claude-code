#!/bin/bash
# Focused native-Windows contract for immutable Session Control bindings and
# Autopilot review-payload transport. The complete lifecycle/adversarial suites
# remain in the scheduled Windows Safety workflow.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

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

for required in "$STATE_LIB" "$BASELINE"; do
  if [ ! -f "$required" ] || ! bash -n "$required" 2>/dev/null; then
    check "WBP1 bound-payload dependencies exist and parse" FAIL
    printf '%s\n' "----" "test-autopilot-bound-payload-windows: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "WBP1 bound-payload dependencies exist and parse" PASS

# shellcheck disable=SC1090
source "$STATE_LIB"

ROOT="$(mktemp -d -t zensu-bound-payload-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
PROJECT="$ROOT/native path O'Brien project"
SOURCE_DIR="$ROOT/external review O'Brien source"
PLUGIN_DATA="$ROOT/plugin data O'Brien"
mkdir -p "$PROJECT" "$SOURCE_DIR" "$PLUGIN_DATA"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_TEST_PLUGIN_DATA="$PLUGIN_DATA"

RUN=bound_payload_windows_run
RAW_SESSION=bound_payload_windows_session
CHAIN=bound-payload-windows-chain
HEAD_SHA=1818181818181818181818181818181818181818
PLAN_SHA=1818181818181818181818181818181818181818181818181818181818181818
SOURCE_FILE="$SOURCE_DIR/review payload with spaces.json"
printf '%s\n' \
  "{\"comments\":[],\"body\":\"bound Windows review\",\"event\":\"COMMENT\",\"commit_id\":\"$HEAD_SHA\"}" \
  > "$SOURCE_FILE"

# A real SessionStart supplies the immutable native project root and private
# Session Control record. In MSYS this also exercises explicit
# MSYS2_ENV_CONV_EXCL transport for an external source path.
# shellcheck disable=SC1090
if source "$BASELINE" "$RAW_SESSION"; then
  check "WBP2 fresh SessionStart binding is available" PASS
else
  check "WBP2 fresh SessionStart binding is available" FAIL
  printf '%s\n' "----" "test-autopilot-bound-payload-windows: $PASS PASS / $FAIL FAIL"
  exit 1
fi
SESSION="$ZENSU_SESSION_KEY"

advance_to_review() {
  local pr_key review_key
  pr_key="pr:$RUN"
  autopilot_begin_run "$RUN" "$SESSION" "$PROJECT" >/dev/null \
    && autopilot_apply_event "$RUN" bound-plan PLAN_APPROVED \
      "{\"approvedPlanSha256\":\"$PLAN_SHA\"}" "$PROJECT" "$SESSION" >/dev/null \
    && autopilot_begin_tdd_attempt "$RUN" bound-tdd-start "$PROJECT" \
      "$SESSION" true 1 GATES "$CHAIN" >/dev/null \
    && autopilot_apply_event "$RUN" bound-tdd-done TDD_CHAIN_DONE \
      "{\"attempt\":1,\"chainId\":\"$CHAIN\",\"sessionId\":\"$SESSION\",\"outcome\":\"pass\"}" \
      "$PROJECT" "$SESSION" >/dev/null \
    && autopilot_apply_event "$RUN" bound-gates GATES_PASSED \
      "{\"headSha\":\"$HEAD_SHA\"}" "$PROJECT" "$SESSION" >/dev/null \
    && autopilot_apply_event "$RUN" bound-convergence CONVERGENCE_PASSED '{}' \
      "$PROJECT" "$SESSION" >/dev/null \
    && autopilot_apply_event "$RUN" bound-pr-request PR_OPEN_REQUESTED \
      "{\"operationKey\":\"$pr_key\"}" "$PROJECT" "$SESSION" >/dev/null \
    && autopilot_apply_event "$RUN" bound-pr-open PR_OPENED \
      "{\"operationKey\":\"$pr_key\",\"pr\":{\"number\":18,\"url\":\"https://github.com/acme/repo/pull/18\",\"headSha\":\"$HEAD_SHA\"}}" \
      "$PROJECT" "$SESSION" >/dev/null \
    || return 1
  review_key="$(autopilot_team_review_operation_key "$RUN" "$HEAD_SHA")" || return 1
  autopilot_apply_event "$RUN" bound-review-request TEAM_REVIEW_REQUESTED \
    "{\"operationKey\":\"$review_key\",\"provider\":\"github\"}" \
    "$PROJECT" "$SESSION" >/dev/null
}

if advance_to_review; then
  check "WBP3 bound Autopilot reaches TEAM_REVIEW" PASS
else
  check "WBP3 bound Autopilot reaches TEAM_REVIEW" FAIL
  printf '%s\n' "----" "test-autopilot-bound-payload-windows: $PASS PASS / $FAIL FAIL"
  exit 1
fi

REVIEW_KEY="$(autopilot_team_review_operation_key "$RUN" "$HEAD_SHA")"
STORE_ERROR="$ROOT/store-error.log"
SNAPSHOT="$(autopilot_store_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" \
  "$SOURCE_FILE" github "$PROJECT" 2>"$STORE_ERROR")"
STORE_RC=$?

if [ "$STORE_RC" -eq 0 ] && [ -n "$SNAPSHOT" ] && [ -f "$SNAPSHOT" ] \
    && cmp -s "$SOURCE_FILE" "$SNAPSHOT"; then
  check "WBP4 bound external payload is stored immutably" PASS
else
  TARGET="$(_autopilot_team_review_payload_target \
    "$PROJECT" "$REVIEW_KEY" "$HEAD_SHA" 2>/dev/null || true)"
  _autopilot_team_review_payload_identity_critical \
    "$PROJECT" "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github >/dev/null 2>&1
  IDENTITY_RC=$?
  CLAUDE_PROJECT_DIR="$PROJECT" _tdd_paths_safe \
    "$PROJECT/.zensu/state" directory "$SOURCE_FILE" regular \
    "$TARGET" regular-or-absent >/dev/null 2>&1
  PATHS_RC=$?
  _autopilot_team_review_payload_inspect \
    "$SOURCE_FILE" "$HEAD_SHA" false >/dev/null 2>&1
  SOURCE_INSPECT_RC=$?
  NATIVE_SOURCE="$(_autopilot_native_path "$SOURCE_FILE" 2>/dev/null || true)"
  NATIVE_TARGET="$(_autopilot_native_project_path "$TARGET" 2>/dev/null || true)"
  printf '  DIAG  store_rc=%s identity_rc=%s paths_rc=%s source_inspect_rc=%s shell_source_length=%s native_source_length=%s shell_target_length=%s native_target_length=%s\n' \
    "$STORE_RC" "$IDENTITY_RC" "$PATHS_RC" "$SOURCE_INSPECT_RC" \
    "${#SOURCE_FILE}" "${#NATIVE_SOURCE}" "${#TARGET}" "${#NATIVE_TARGET}"
  if [ -s "$STORE_ERROR" ]; then
    sed 's/^/  DIAG  stderr: /' "$STORE_ERROR"
  fi
  check "WBP4 bound external payload is stored immutably" FAIL
fi

if [ "$FAIL" -eq 0 ] \
    && [ "$(autopilot_read_team_review_payload \
      "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" 2>/dev/null)" = "$SNAPSHOT" ]; then
  check "WBP5 bound payload is readable through the public API" PASS
else
  check "WBP5 bound payload is readable through the public API" FAIL
fi

printf '%s\n' "----" "test-autopilot-bound-payload-windows: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
