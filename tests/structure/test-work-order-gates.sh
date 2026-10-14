#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-work-order.sh"
LOG_HELPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PRE_HOOK="$PLUGIN_DIR/hooks/pre-work-order-gate.sh"
POST_HOOK="$PLUGIN_DIR/hooks/post-work-order.sh"
STOP_HOOK="$PLUGIN_DIR/hooks/stop-work-order.sh"
HOOK_LIB="$PLUGIN_DIR/hooks/lib/zensu-work-order-hook.sh"
FAKE_LIB="$PLUGIN_DIR/tests/structure/lib-work-order.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-work-order-gates: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "native Windows work-order run skipped (macOS/Linux/WSL required)" PASS
    finish; exit 0
    ;;
esac

for f in "$WRAPPER" "$LOG_HELPER" "$PRE_HOOK" "$POST_HOOK" "$STOP_HOOK" "$HOOK_LIB" "$FAKE_LIB" "$BASELINE"; do
  if [ ! -f "$f" ] || ! bash -n "$f" 2>/dev/null; then
    check "G0 required file exists and parses: $f" FAIL
    finish; exit 1
  fi
done
check "G0 the three work-order hooks, their library, the helpers, the fake and the baseline exist and parse" PASS

source "$FAKE_LIB"

SBOX="$(mktemp -d -t wo-gates-XXXXXX)"
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT
export HOME="$SBOX/home"
mkdir -p "$HOME"
export ZENSU_CONFIG="$SBOX/config.json"
printf '%s\n' '{}' > "$ZENSU_CONFIG"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Work Order Test" GIT_AUTHOR_EMAIL="wo@example.invalid"
export GIT_COMMITTER_NAME="Work Order Test" GIT_COMMITTER_EMAIL="wo@example.invalid"
wo_fake_install "$SBOX/bin" || { check "G1 fake zensu installs" FAIL; finish; exit 1; }
export PATH="$SBOX/bin:$PATH"
export FAKE_ZENSU_STATE="$SBOX/fake.json"
export FAKE_ZENSU_CALLS="$SBOX/calls.jsonl"
export ZENSU_WORK_ORDER_RETRY_MS=1
export ZENSU_WORK_ORDER_RETRY_BUDGET_MS=50
unset ZENSU_SESSION_TOKEN

json_get() {
  FILE="$1" EXPR="$2" node -e '
    const value = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
    const out = Function("value", `return (${process.env.EXPR})`)(value);
    process.stdout.write(out === undefined || out === null ? "" : String(out));
  ' 2>/dev/null
}
payload() {
  SID="$1" TOOL="$2" CMD="${3:-}" node -e '
    const input = process.env.TOOL === "Bash" ? { command: process.env.CMD } : {};
    process.stdout.write(JSON.stringify({ hook_event_name: "PreToolUse", session_id: process.env.SID, tool_name: process.env.TOOL, tool_input: input }));
  '
}
decision_of() {
  node -e '
    let input = "";
    process.stdin.on("data", (chunk) => { input += chunk; });
    process.stdin.on("end", () => {
      try {
        const out = JSON.parse(input).hookSpecificOutput;
        process.stdout.write(`${out.permissionDecision}\t${out.permissionDecisionReason}`);
      } catch (_) { process.stdout.write(input ? "unparseable" : "none"); }
    });
  '
}
work_calls() {
  [ -f "$FAKE_ZENSU_CALLS" ] || { echo 0; return; }
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    process.stdout.write(String(lines.filter((line) => JSON.parse(line).argv[0] === "work").length));
  ' "$FAKE_ZENSU_CALLS"
}
new_project() {
  local name="$1"
  PROJECT="$SBOX/$name"
  REMOTE="$SBOX/$name-origin.git"
  git init -q --bare -b main "$REMOTE"
  git init -q -b main "$PROJECT"
  git -C "$PROJECT" remote add origin "$REMOTE"
  printf 'seed\n' > "$PROJECT/README.md"
  printf '.session-control-test/\n.zensu/state/\n' > "$PROJECT/.gitignore"
  git -C "$PROJECT" add README.md .gitignore
  git -C "$PROJECT" commit -q -m "chore: seed"
  git -C "$PROJECT" push -q origin main
  export CLAUDE_PROJECT_DIR="$PROJECT"
  export ZENSU_TEST_PLUGIN_DATA="$SBOX/$name-plugin-data"
}
clone_project() {
  local name="$1" branch="$2"
  PROJECT="$SBOX/$name"
  git clone -q "$REMOTE" "$PROJECT"
  git -C "$PROJECT" checkout -q -B "$branch" "origin/$branch"
  export CLAUDE_PROJECT_DIR="$PROJECT"
  export ZENSU_TEST_PLUGIN_DATA="$SBOX/$name-plugin-data"
}

ORDER="99999999-9999-4999-8999-999999999999"
SESSION="wo-gates-session-0001"
new_project plain
source "$BASELINE" "$SESSION" || { check "G1 test session binds" FAIL; finish; exit 1; }
wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER" "$SESSION" auto implement
: > "$FAKE_ZENSU_CALLS"

OUT_PRE="$(payload "$SESSION" AskUserQuestion | bash "$PRE_HOOK" 2>&1)"; RC_PRE=$?
OUT_PUSH="$(payload "$SESSION" Bash 'git push origin main' | bash "$PRE_HOOK" 2>&1)"; RC_PUSH=$?
OUT_POST="$(payload "$SESSION" Bash 'git status' | bash "$POST_HOOK" 2>&1)"; RC_POST=$?
OUT_STOP="$(printf '{"hook_event_name":"Stop","session_id":"%s"}' "$SESSION" | bash "$STOP_HOOK" 2>&1)"; RC_STOP=$?
if [ "$RC_PRE$RC_PUSH$RC_POST$RC_STOP" = "0000" ] && [ -z "$OUT_PRE$OUT_PUSH$OUT_POST$OUT_STOP" ]; then
  check "G1 without the session token every work-order hook prints nothing and exits 0" PASS
else
  check "G1 without the session token every work-order hook prints nothing and exits 0 (rc=$RC_PRE$RC_PUSH$RC_POST$RC_STOP out=$OUT_PRE$OUT_PUSH$OUT_POST$OUT_STOP)" FAIL
fi

export ZENSU_SESSION_TOKEN="zst_fake_session_token"
export ZENSU_API_URL="http://127.0.0.1:9"
OUT_PRE="$(payload "$SESSION" AskUserQuestion | bash "$PRE_HOOK" 2>&1)"; RC_PRE=$?
OUT_PUSH="$(payload "$SESSION" Bash 'git push origin main' | bash "$PRE_HOOK" 2>&1)"; RC_PUSH=$?
OUT_POST="$(payload "$SESSION" Bash 'git status' | bash "$POST_HOOK" 2>&1)"; RC_POST=$?
OUT_STOP="$(printf '{"hook_event_name":"Stop","session_id":"%s"}' "$SESSION" | bash "$STOP_HOOK" 2>&1)"; RC_STOP=$?
if [ "$RC_PRE$RC_PUSH$RC_POST$RC_STOP" = "0000" ] && [ -z "$OUT_PRE$OUT_PUSH$OUT_POST$OUT_STOP" ] && [ "$(work_calls)" = "0" ]; then
  check "G2 with the token but without this session's marker every hook stays silent and calls no zensu work command" PASS
else
  check "G2 with the token but without a marker every hook stays silent (rc=$RC_PRE$RC_PUSH$RC_POST$RC_STOP out=$OUT_PRE$OUT_PUSH$OUT_POST$OUT_STOP calls=$(work_calls))" FAIL
fi

RUN_PLAIN="run_gates_plain"
env -u ZENSU_SESSION_TOKEN bash "$LOG_HELPER" --autopilot-begin --run "$RUN_PLAIN" >/dev/null 2>"$SBOX/plain.err"; RC=$?
PLAIN_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN_PLAIN}.json"
if [ "$RC" -eq 0 ] && [ "$(json_get "$PLAIN_FILE" 'value.stage')" = "PLANNING" ] \
  && [ "$(json_get "$PLAIN_FILE" '"workOrder" in value')" = "false" ] && [ "$(work_calls)" = "0" ] \
  && [ -z "$(payload "$SESSION" ExitPlanMode | env -u ZENSU_SESSION_TOKEN bash "$PRE_HOOK" 2>&1)" ]; then
  check "G3 outside work-order mode Autopilot begins as before, keeps no order binding, calls no zensu work command and may use plan mode" PASS
else
  check "G3 outside work-order mode Autopilot begins as before (rc=$RC calls=$(work_calls) $(cat "$SBOX/plain.err"))" FAIL
fi
env -u ZENSU_SESSION_TOKEN bash "$LOG_HELPER" --autopilot-release --run "$RUN_PLAIN" --confirm >/dev/null 2>&1 || true

ORDER_W="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
SESSION_W="wo-gates-session-0002"
(
  new_project wired
  source "$BASELINE" "$SESSION_W" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER_W" "$SESSION_W" auto implement
  bash "$WRAPPER" --start --order "$ORDER_W" >/dev/null 2>&1 || exit 91
  for tool in AskUserQuestion EnterPlanMode ExitPlanMode mcp__ccd_session__spawn_task; do
    printf '%s\t' "$tool" >> "$SBOX/denials.txt"
    payload "$SESSION_W" "$tool" | bash "$PRE_HOOK" 2>/dev/null | decision_of >> "$SBOX/denials.txt"
    printf '\n' >> "$SBOX/denials.txt"
  done
  while IFS= read -r command; do
    printf '%s\t' "$command" >> "$SBOX/bash.txt"
    payload "$SESSION_W" Bash "$command" | bash "$PRE_HOOK" 2>/dev/null | decision_of >> "$SBOX/bash.txt"
    printf '\n' >> "$SBOX/bash.txt"
  done <<'COMMANDS'
git push origin HEAD
bash -c 'git push --force origin main'
gh pr merge 7 --squash
zensu work approve 1
printenv
echo "$ZENSU_SESSION_TOKEN"
git status
zensu work get 1 --json
zensu work list
zensu work questions --plan p1
zensu work policy get --product p1
zensu work repositories list --product p1
COMMANDS
  wo_fake_set "$FAKE_ZENSU_STATE" 'state.questions.push({ id: "q-answer-1", work_order_id: state.order.id, category: "scope", question: "Should archived widgets be listed?", status: "answered", answer: "List active widgets only." })'
  for lease in "$PROJECT"/.zensu/state/work-order/lease-*.json; do
    LEASE="$lease" node -e '
      const fs = require("fs");
      const lease = JSON.parse(fs.readFileSync(process.env.LEASE, "utf8"));
      lease.lastSuccessAt = Date.now() - 120000;
      fs.writeFileSync(process.env.LEASE, JSON.stringify(lease));
    '
  done
  payload "$SESSION_W" Read | bash "$POST_HOOK" > "$SBOX/post1.out" 2>/dev/null
  echo "$?" > "$SBOX/post1.rc"
); RC=$?
ASK_LINE="$(grep '^AskUserQuestion' "$SBOX/denials.txt" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$(grep -c "	deny	" "$SBOX/denials.txt")" = "4" ] \
  && printf '%s' "$ASK_LINE" | grep -qF "zensu work ask $ORDER_W" \
  && grep '^mcp__ccd_session__spawn_task' "$SBOX/denials.txt" | grep -qF "zensu work followup $ORDER_W"; then
  check "G4 in work-order mode the prompt tools and the chip tool are denied with the zensu work ask and followup routes" PASS
else
  check "G4 in work-order mode the prompt tools and the chip tool are denied (rc=$RC $(cat "$SBOX/denials.txt" 2>/dev/null | cut -c1-200))" FAIL
fi
DENIED_BASH="$(grep -c "	deny	" "$SBOX/bash.txt" 2>/dev/null)"
if [ "$DENIED_BASH" = "10" ] && grep -q "^git status	none" "$SBOX/bash.txt" && grep -q "^zensu work get 1 --json	none" "$SBOX/bash.txt" \
  && grep '^git push origin HEAD' "$SBOX/bash.txt" | grep -qF 'zensu-work-order.sh --push' \
  && [ "$(grep -c 'orderFile in the --start summary' "$SBOX/bash.txt")" = "4" ]; then
  check "G5 raw pushes, merges, human-gate verbs, token reads and the verbs Zensu refuses a session token are denied while ordinary commands pass silently" PASS
else
  check "G5 raw pushes, merges, human-gate verbs and token reads are denied (denied=$DENIED_BASH $(cut -c1-120 "$SBOX/bash.txt" 2>/dev/null | tr '\n' '|'))" FAIL
fi
POST_CONTEXT="$(node -e '
  let input = "";
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => { try { process.stdout.write(JSON.parse(input).hookSpecificOutput.additionalContext); } catch (_) {} });
' < "$SBOX/post1.out")"
if [ "$(cat "$SBOX/post1.rc" 2>/dev/null)" = "0" ] && printf '%s' "$POST_CONTEXT" | grep -qF 'List active widgets only.'; then
  check "G6 the PostToolUse hook hands the answer of a non-blocking question to the model as additionalContext" PASS
else
  check "G6 the PostToolUse hook hands the answer of a non-blocking question to the model (out=$(cat "$SBOX/post1.out" 2>/dev/null))" FAIL
fi

ORDER_P="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
SESSION_P1="wo-gates-session-0003"
RUN_P1="run_gates_plan_1"
BRANCH_P="wo-bbbbbbbb"
(
  new_project planner
  source "$BASELINE" "$SESSION_P1" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER_P" "$SESSION_P1" required implement
  wo_fake_set "$FAKE_ZENSU_STATE" 'state.order.repository = "https://github.com/acme/widgets"'
  bash "$WRAPPER" --start --order "$ORDER_P" >/dev/null 2>&1 || exit 91
  git -C "$PROJECT" checkout -q -b "$BRANCH_P"
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN_P1" --work-order "$ORDER_P" >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN_P1" >/dev/null 2>"$SBOX/plan-bind.err"
  echo "$?" > "$SBOX/plan-bind.rc"
  mkdir -p "$PROJECT/.zensu/plans"
  printf '# Plan for the widget list\n\n- AC-001 The list shows active widgets only.\n' > "$PROJECT/.zensu/plans/$ORDER_P.md"
  bash "$WRAPPER" --plan-approval > "$SBOX/plan.out" 2>"$SBOX/plan.err"
  echo "$?" > "$SBOX/plan.rc"
  json_get "$PROJECT/.zensu/state/autopilot-run-${RUN_P1}.json" 'value.stage' > "$SBOX/plan.stage"
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$SESSION_P1" | bash "$STOP_HOOK" > "$SBOX/plan.stop" 2>&1
); RC=$?
PLAN_COMMIT="$(git -C "$SBOX/planner-origin.git" rev-parse --verify --quiet "refs/heads/$BRANCH_P")"
ARTIFACT="$(wo_fake_get "$FAKE_ZENSU_STATE" 'JSON.stringify(state.events.filter(e => e.event_type === "artifact").map(e => e.detail))')"
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/plan-bind.rc")" = "8" ] && grep -q 'plan-approval-required' "$SBOX/plan-bind.err" \
  && [ "$(cat "$SBOX/plan.rc")" = "0" ] && [ -n "$PLAN_COMMIT" ] \
  && git -C "$SBOX/planner-origin.git" cat-file -e "$PLAN_COMMIT:.zensu/plans/$ORDER_P.md" 2>/dev/null \
  && printf '%s' "$ARTIFACT" | grep -qF "\"sha\":\"$PLAN_COMMIT\"" \
  && printf '%s' "$ARTIFACT" | grep -qF "https://github.com/acme/widgets/blob/$PLAN_COMMIT/.zensu/plans/$ORDER_P.md" \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_kind')" = "plan_approval" ] \
  && [ "$(cat "$SBOX/plan.stage")" = "CANCELLED" ] && [ ! -s "$SBOX/plan.stop" ]; then
  check "G7 a required plan approval commits and pushes the plan, attaches it with its commit and link, blocks with plan_approval and ends the session" PASS
else
  check "G7 a required plan approval commits, pushes, attaches and blocks (rc=$RC bind=$(cat "$SBOX/plan-bind.rc" 2>/dev/null) plan=$(cat "$SBOX/plan.rc" 2>/dev/null) stage=$(cat "$SBOX/plan.stage" 2>/dev/null) $(cat "$SBOX/plan.err" 2>/dev/null))" FAIL
fi

wo_fake_set "$FAKE_ZENSU_STATE" 'state.approvals.push({ spec_hash: state.order.spec_hash }); state.events.push({ id: "approved-1", client_event_id: null, event_type: "approved", detail: { subject: "implementation_plan", spec_hash: state.order.spec_hash } }); state.mode = "live"; state.order.status = "claimed"; state.order.blocked_kind = null; state.order.blocked_reason = null; state.order.attempt = 2; state.order.client_session_id = "wo-gates-session-0004"'
SESSION_P2="wo-gates-session-0004"
RUN_P2="run_gates_plan_2"
(
  REMOTE="$SBOX/planner-origin.git"
  clone_project planner-two "$BRANCH_P"
  source "$BASELINE" "$SESSION_P2" || exit 90
  bash "$WRAPPER" --start --order "$ORDER_P" >/dev/null 2>&1 || exit 91
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN_P2" --work-order "$ORDER_P" >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN_P2" >/dev/null 2>"$SBOX/approved.err"
  echo "$?" > "$SBOX/approved.rc"
  json_get "$PROJECT/.zensu/state/autopilot-run-${RUN_P2}.json" 'value.stage' > "$SBOX/approved.stage"
  json_get "$PROJECT/.zensu/state/autopilot-run-${RUN_P2}.json" 'value.approvedPlanSha256' > "$SBOX/approved.sha"
  shasum -a 256 "$PROJECT/.zensu/plans/$ORDER_P.md" | cut -d' ' -f1 > "$SBOX/approved.expected"
); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/approved.rc")" = "0" ] && [ "$(cat "$SBOX/approved.stage")" = "AWAIT_TDD" ] \
  && [ "$(cat "$SBOX/approved.sha")" = "$(cat "$SBOX/approved.expected")" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status')" = "implementing" ]; then
  check "G8 an approved attempt implements from the plan on the branch and pins the approved plan's SHA-256" PASS
else
  check "G8 an approved attempt implements from the plan on the branch (rc=$RC bind=$(cat "$SBOX/approved.rc" 2>/dev/null) stage=$(cat "$SBOX/approved.stage" 2>/dev/null) $(cat "$SBOX/approved.err" 2>/dev/null))" FAIL
fi

wo_fake_set "$FAKE_ZENSU_STATE" 'state.mode = "live"; state.order.status = "claimed"; state.order.attempt = 3; state.order.client_session_id = "wo-gates-session-0005"'
SESSION_P3="wo-gates-session-0005"
RUN_P3="run_gates_plan_3"
(
  REMOTE="$SBOX/planner-origin.git"
  clone_project planner-three "$BRANCH_P"
  source "$BASELINE" "$SESSION_P3" || exit 90
  bash "$WRAPPER" --start --order "$ORDER_P" >/dev/null 2>&1 || exit 91
  printf '\n- AC-002 Also archive old widgets.\n' >> "$PROJECT/.zensu/plans/$ORDER_P.md"
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN_P3" --work-order "$ORDER_P" >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN_P3" >/dev/null 2>"$SBOX/tampered.err"
  echo "$?" > "$SBOX/tampered.rc"
); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/tampered.rc")" = "6" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_kind')" = "worker_error" ] \
  && wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_reason' | grep -q 'differs from the plan that was approved'; then
  check "G9 a plan file that differs from the approved commit blocks the order with worker_error" PASS
else
  check "G9 a plan file that differs from the approved commit blocks the order (rc=$RC bind=$(cat "$SBOX/tampered.rc" 2>/dev/null) $(cat "$SBOX/tampered.err" 2>/dev/null))" FAIL
fi

finish
