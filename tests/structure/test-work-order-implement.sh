#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-work-order.sh"
LOG_HELPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP_HOOK="$PLUGIN_DIR/hooks/stop-work-order.sh"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
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
  echo "test-work-order-implement: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "native Windows work-order run skipped (macOS/Linux/WSL required)" PASS
    finish; exit 0
    ;;
esac

for f in "$WRAPPER" "$LOG_HELPER" "$STOP_HOOK" "$STATE_LIB" "$FAKE_LIB" "$BASELINE"; do
  if [ ! -f "$f" ] || ! bash -n "$f" 2>/dev/null; then
    check "I0 required file exists and parses: $f" FAIL
    finish; exit 1
  fi
done
check "I0 wrapper, log helper, Stop hook, state library, fake and baseline exist and parse" PASS

source "$FAKE_LIB"

SBOX="$(mktemp -d -t wo-implement-XXXXXX)"
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT
export HOME="$SBOX/home"
mkdir -p "$HOME"
export ZENSU_CONFIG="$SBOX/config.json"
printf '%s\n' '{}' > "$ZENSU_CONFIG"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Work Order Test" GIT_AUTHOR_EMAIL="wo@example.invalid"
export GIT_COMMITTER_NAME="Work Order Test" GIT_COMMITTER_EMAIL="wo@example.invalid"

wo_fake_install "$SBOX/bin" || { check "I1 fake zensu installs" FAIL; finish; exit 1; }
export PATH="$SBOX/bin:$PATH"
export FAKE_ZENSU_STATE="$SBOX/fake.json"
export FAKE_ZENSU_CALLS="$SBOX/calls.jsonl"
export ZENSU_WORK_ORDER_RETRY_MS=1
export ZENSU_WORK_ORDER_RETRY_BUDGET_MS=50

json_get() {
  FILE="$1" EXPR="$2" node -e '
    const value = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
    const out = Function("value", `return (${process.env.EXPR})`)(value);
    process.stdout.write(out === undefined || out === null ? "" : String(out));
  ' 2>/dev/null
}
stage_events() {
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    const out = [];
    for (const line of lines) {
      const argv = JSON.parse(line).argv;
      if (argv[0] !== "work" || argv[1] !== "event") continue;
      const at = argv.indexOf("--stage");
      const blocked = argv.indexOf("--blocked");
      out.push(at >= 0 ? argv[at + 1] : `blocked:${argv[blocked + 1]}`);
    }
    process.stdout.write(out.join(" "));
  ' "$FAKE_ZENSU_CALLS" 2>/dev/null
}

new_project() {
  local name="$1"
  PROJECT="$SBOX/$name"
  REMOTE="$SBOX/$name-origin.git"
  git init -q --bare -b main "$REMOTE"
  git init -q -b main "$PROJECT"
  git -C "$PROJECT" remote add origin "$REMOTE"
  printf 'seed\n' > "$PROJECT/README.md"
  printf '.zensu/\n.session-control-test/\n' > "$PROJECT/.gitignore"
  git -C "$PROJECT" add README.md .gitignore
  git -C "$PROJECT" commit -q -m "chore: seed"
  git -C "$PROJECT" push -q origin main
  export CLAUDE_PROJECT_DIR="$PROJECT"
  export ZENSU_TEST_PLUGIN_DATA="$SBOX/$name-plugin-data"
}

ORDER="55555555-5555-4555-8555-555555555555"
SESSION="wo-implement-session-0001"
RUN="run_impl_0001"

new_project alpha
source "$BASELINE" "$SESSION" || { check "I1 test session binds" FAIL; finish; exit 1; }
wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER" "$SESSION" auto implement
export ZENSU_SESSION_TOKEN="zst_fake_session_token"
export ZENSU_API_URL="http://127.0.0.1:9"
bash "$WRAPPER" --start --order "$ORDER" >"$SBOX/start.out" 2>"$SBOX/start.err"; RC=$?
[ "$RC" -eq 0 ] && check "I1 a work-order session starts" PASS \
  || check "I1 a work-order session starts (rc=$RC $(cat "$SBOX/start.err"))" FAIL
git -C "$PROJECT" checkout -q -b "wo-55555555"

bash "$LOG_HELPER" --autopilot-begin --run "$RUN" >/dev/null 2>"$SBOX/begin-plain.err"; RC=$?
[ "$RC" -eq 4 ] && [ ! -e "$PROJECT/.zensu/state/autopilot-run-${RUN}.json" ] \
  && check "I2 a work-order session refuses an Autopilot begin without --work-order" PASS \
  || check "I2 a work-order session refuses an Autopilot begin without --work-order (rc=$RC)" FAIL

bash "$LOG_HELPER" --autopilot-begin --run "$RUN" --work-order "66666666-6666-4666-8666-666666666666" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 4 ] && [ ! -e "$PROJECT/.zensu/state/autopilot-run-${RUN}.json" ] \
  && check "I3 an Autopilot begin naming another order is refused" PASS \
  || check "I3 an Autopilot begin naming another order is refused (rc=$RC)" FAIL

bash "$LOG_HELPER" --autopilot-begin --run "$RUN" --work-order "$ORDER" >/dev/null 2>"$SBOX/begin.err"; RC=$?
RUN_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN}.json"
if [ "$RC" -eq 0 ] && [ "$(json_get "$RUN_FILE" 'value.workOrder.orderId')" = "$ORDER" ] \
  && [ "$(json_get "$RUN_FILE" 'value.workOrder.attempt')" = "1" ] \
  && [ "$(json_get "$RUN_FILE" 'value.stage')" = "PLANNING" ]; then
  check "I4 --autopilot-begin --work-order stores the order binding in the run record" PASS
else
  check "I4 --autopilot-begin --work-order stores the order binding in the run record (rc=$RC $(cat "$SBOX/begin.err"))" FAIL
fi

bash "$LOG_HELPER" --autopilot-event --run "$RUN" --event ORDER_SPEC_BOUND --event-id forged \
  --payload "{\"orderId\":\"$ORDER\",\"attempt\":1,\"specHash\":\"$(printf 'a%.0s' $(seq 1 64))\",\"approvedPlanSha256\":\"$(printf 'b%.0s' $(seq 1 64))\"}" \
  >/dev/null 2>"$SBOX/forged.err"; RC=$?
[ "$RC" -eq 2 ] && grep -q 'is internal' "$SBOX/forged.err" && [ "$(json_get "$RUN_FILE" 'value.stage')" = "PLANNING" ] \
  && check "I5 ORDER_SPEC_BOUND cannot be recorded through --autopilot-event" PASS \
  || check "I5 ORDER_SPEC_BOUND cannot be recorded through --autopilot-event (rc=$RC)" FAIL

bash "$LOG_HELPER" --autopilot-event --run "$RUN" --event PLAN_APPROVED --event-id plan-approved \
  --payload "{\"approvedPlanSha256\":\"$(printf 'b%.0s' $(seq 1 64))\"}" >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && [ "$(json_get "$RUN_FILE" 'value.stage')" = "PLANNING" ] \
  && check "I6 a work-order run refuses PLAN_APPROVED" PASS \
  || check "I6 a work-order run refuses PLAN_APPROVED (rc=$RC)" FAIL

bash "$WRAPPER" --bind-spec --run "$RUN" >"$SBOX/bind.out" 2>"$SBOX/bind.err"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(json_get "$RUN_FILE" 'value.stage')" = "AWAIT_TDD" ] \
  && [ "$(json_get "$RUN_FILE" 'value.events.some(e => e.eventType === "ORDER_SPEC_BOUND")')" = "true" ] \
  && [ "$(stage_events)" = "planning implementing" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status')" = "implementing" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.autopilot_run_id')" = "$RUN" ]; then
  check "I7 --bind-spec reports planning then implementing and moves the run to AWAIT_TDD through ORDER_SPEC_BOUND" PASS
else
  check "I7 --bind-spec reports planning then implementing and moves the run to AWAIT_TDD (rc=$RC events=$(stage_events) $(cat "$SBOX/bind.err"))" FAIL
fi

bash "$WRAPPER" --bind-spec --run "$RUN" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ "$(stage_events)" = "planning implementing" ] \
  && [ "$(json_get "$RUN_FILE" 'value.events.filter(e => e.eventType === "ORDER_SPEC_BOUND").length')" = "1" ] \
  && check "I8 a repeated --bind-spec sends nothing and records nothing twice" PASS \
  || check "I8 a repeated --bind-spec sends nothing and records nothing twice (rc=$RC events=$(stage_events))" FAIL

printf 'feature\n' > "$PROJECT/feature.txt"
git -C "$PROJECT" add feature.txt
git -C "$PROJECT" commit -q -m "feat: add the feature"
LOCAL_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
bash "$WRAPPER" --push >"$SBOX/push.out" 2>"$SBOX/push.err"; RC=$?
REMOTE_HEAD="$(git -C "$REMOTE" rev-parse --verify --quiet refs/heads/wo-55555555)"
if [ "$RC" -eq 0 ] && [ "$REMOTE_HEAD" = "$LOCAL_HEAD" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.head_sha')" = "$LOCAL_HEAD" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.branch')" = "wo-55555555" ]; then
  check "I9 --push pushes the branch and reports the new head with a same-status stage event" PASS
else
  check "I9 --push pushes the branch and reports the new head (rc=$RC remote=$REMOTE_HEAD $(cat "$SBOX/push.err"))" FAIL
fi

OTHER="$SBOX/alpha-other"
git clone -q "$REMOTE" "$OTHER"
git -C "$OTHER" checkout -q wo-55555555
printf 'foreign\n' > "$OTHER/foreign.txt"
git -C "$OTHER" add foreign.txt
git -C "$OTHER" commit -q -m "feat: a foreign commit"
git -C "$OTHER" push -q origin wo-55555555
FOREIGN_HEAD="$(git -C "$OTHER" rev-parse HEAD)"
printf 'more\n' >> "$PROJECT/feature.txt"
git -C "$PROJECT" commit -q -am "feat: extend the feature"
bash "$WRAPPER" --push >/dev/null 2>"$SBOX/push2.err"; RC=$?
[ "$RC" -eq 8 ] && [ "$(git -C "$REMOTE" rev-parse refs/heads/wo-55555555)" = "$FOREIGN_HEAD" ] \
  && check "I10 --push refuses when the remote branch moved past the head Zensu recorded" PASS \
  || check "I10 --push refuses when the remote branch moved past the head Zensu recorded (rc=$RC)" FAIL

bash "$WRAPPER" --finish >/dev/null 2>"$SBOX/finish0.err"; RC=$?
[ "$RC" -eq 8 ] && [ "$(json_get "$RUN_FILE" 'value.stage')" = "AWAIT_TDD" ] \
  && check "I11 --finish refuses a nonterminal run without a reason" PASS \
  || check "I11 --finish refuses a nonterminal run without a reason (rc=$RC)" FAIL

STOP_PAYLOAD="{\"hook_event_name\":\"Stop\",\"session_id\":\"$SESSION\"}"
OUT="$(printf '%s' "$STOP_PAYLOAD" | bash "$STOP_HOOK" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"decision":"block"' \
  && printf '%s' "$OUT" | grep -q "zensu-work-order.sh --finish"; then
  check "I12 the Stop hook blocks a work-order session with no reported outcome" PASS
else
  check "I12 the Stop hook blocks a work-order session with no reported outcome (rc=$RC out=$OUT)" FAIL
fi

OUT="$(printf '%s' "$STOP_PAYLOAD" | env -u ZENSU_SESSION_TOKEN bash "$STOP_HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && check "I13 the Stop hook prints nothing and exits 0 without the session token" PASS \
  || check "I13 the Stop hook prints nothing and exits 0 without the session token (rc=$RC out=$OUT)" FAIL

bash "$WRAPPER" --finish --reason "The build needs a database the worker does not provide." >/dev/null 2>"$SBOX/finish.err"; RC=$?
if [ "$RC" -eq 6 ] && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status')" = "blocked" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_kind')" = "worker_error" ] \
  && wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_reason' | grep -q 'database the worker does not provide' \
  && [ "$(json_get "$RUN_FILE" 'value.stage')" = "CANCELLED" ]; then
  check "I14 --finish --reason blocks the order with worker_error, exits non-zero and cancels the local run" PASS
else
  check "I14 --finish --reason blocks the order with worker_error and cancels the local run (rc=$RC stage=$(json_get "$RUN_FILE" 'value.stage') $(cat "$SBOX/finish.err"))" FAIL
fi

OUT="$(printf '%s' "$STOP_PAYLOAD" | bash "$STOP_HOOK" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && check "I15 the Stop hook lets an ended work-order session stop" PASS \
  || check "I15 the Stop hook lets an ended work-order session stop (rc=$RC out=$OUT)" FAIL

ORDER2="77777777-7777-4777-8777-777777777777"
SESSION2="wo-implement-session-0002"
RUN2="run_impl_0002"
(
  new_project beta
  git -C "$PROJECT" checkout -q -b "wo-77777777"
  source "$BASELINE" "$SESSION2" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER2" "$SESSION2" required implement
  : > "$FAKE_ZENSU_CALLS"
  bash "$WRAPPER" --start --order "$ORDER2" >/dev/null 2>&1 || exit 91
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN2" --work-order "$ORDER2" >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN2" >/dev/null 2>"$SBOX/bind2.err"
  echo "$?" > "$SBOX/bind2.rc"
  json_get "$PROJECT/.zensu/state/autopilot-run-${RUN2}.json" 'value.stage' > "$SBOX/bind2.stage"
); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/bind2.rc")" = "8" ] && grep -q 'plan-approval-required' "$SBOX/bind2.err" \
  && [ "$(cat "$SBOX/bind2.stage")" = "PLANNING" ] && [ "$(stage_events)" = "planning" ]; then
  check "I16 a required but missing plan approval refuses the spec binding after planning and keeps the run at PLANNING" PASS
else
  check "I16 a required but missing plan approval refuses the spec binding (rc=$RC bind=$(cat "$SBOX/bind2.rc" 2>/dev/null) events=$(stage_events))" FAIL
fi

ORDER3="88888888-8888-4888-8888-888888888888"
SESSION3="wo-implement-session-0003"
(
  new_project gamma
  source "$BASELINE" "$SESSION3" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER3" "$SESSION3" auto implement
  bash "$WRAPPER" --start --order "$ORDER3" >/dev/null 2>&1 || exit 91
  git -C "$PROJECT" checkout -q -b "wo-88888888"
  wo_fake_set "$FAKE_ZENSU_STATE" 'state.order.status = "planning"'
  printf 'x\n' > "$PROJECT/x.txt"
  git -C "$PROJECT" add x.txt
  git -C "$PROJECT" commit -q -m "feat: x"
  wo_fake_set "$FAKE_ZENSU_STATE" 'state.staleAttempt = true'
  bash "$WRAPPER" --push >/dev/null 2>"$SBOX/push3.err"
  echo "$?" > "$SBOX/push3.rc"
  git -C "$REMOTE" rev-parse --verify --quiet refs/heads/wo-88888888 > "$SBOX/push3.remote" || true
  bash "$WRAPPER" --status > "$SBOX/push3.status" 2>/dev/null
); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/push3.rc")" = "4" ] && [ ! -s "$SBOX/push3.remote" ] \
  && grep -q '"lost": true' "$SBOX/push3.status" && grep -q '"forgeWrites": "denied"' "$SBOX/push3.status"; then
  check "I17 a stale attempt is detected before the push: nothing reaches the remote and forge writes stay denied" PASS
else
  check "I17 a stale attempt is detected before the push (rc=$RC push=$(cat "$SBOX/push3.rc" 2>/dev/null) remote=$(cat "$SBOX/push3.remote" 2>/dev/null))" FAIL
fi

ORDER4="99999999-9999-4999-8999-999999999999"
SESSION4="wo-implement-session-0004"
RUN4="run_impl_0004"
LEASE_HELPER="$PLUGIN_DIR/hooks/lib/zensu-review-evidence.sh"
SEAT_START="$PLUGIN_DIR/hooks/review-evidence-subagent-start.sh"
SEAT_STOP="$PLUGIN_DIR/hooks/review-evidence-subagent-stop.sh"
(
  new_project delta
  source "$BASELINE" "$SESSION4" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER4" "$SESSION4" auto implement
  bash "$WRAPPER" --start --order "$ORDER4" >/dev/null 2>&1 || exit 91
  git -C "$PROJECT" checkout -q -b "wo-99999999"
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN4" --work-order "$ORDER4" >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN4" >/dev/null 2>&1 || exit 93
  REVIEW="$SBOX/delta-review"
  mkdir -p "$PROJECT/src" "$REVIEW" && chmod 700 "$REVIEW"
  printf 'const value = 1;\n' > "$PROJECT/src/app.js"
  printf '%s\n' "$PROJECT/src/app.js" > "$REVIEW/FILES.txt"
  printf '%s\n' "$PROJECT/src" > "$REVIEW/ROOTS.txt"
  printf 'M\tsrc/app.js\n' > "$REVIEW/NAME-STATUS.txt"
  printf 'src/app.js\n' > "$REVIEW/CHANGED.txt"
  bash "$LEASE_HELPER" create --kind pr-review --files-manifest "$REVIEW/FILES.txt" \
    --safe-subtrees-manifest "$REVIEW/ROOTS.txt" --name-status-file "$REVIEW/NAME-STATUS.txt" \
    --changed-production-files-file "$REVIEW/CHANGED.txt" --max-workers 1 --ttl-seconds 600 \
    >/dev/null 2>"$SBOX/delta-lease.err" || exit 94
  seat_payload() {
    EVENT="$1" SESSION_VALUE="$SESSION4" PROJECT_VALUE="$PROJECT" MESSAGE="${2:-}" node -e '
      const payload = { hook_event_name: process.env.EVENT, session_id: process.env.SESSION_VALUE,
        cwd: process.env.PROJECT_VALUE, agent_id: "agent-bug-hunter", agent_type: "zensu:pr-review-worker" };
      if (process.env.EVENT === "SubagentStop") payload.last_assistant_message = process.env.MESSAGE;
      process.stdout.write(JSON.stringify(payload));
    '
  }
  seat_payload SubagentStart | bash "$SEAT_START" >/dev/null 2>&1 || exit 95
  STOP4="{\"hook_event_name\":\"Stop\",\"session_id\":\"$SESSION4\"}"
  for n in 1 2 3 4; do
    printf '%s' "$STOP4" | bash "$STOP_HOOK" > "$SBOX/delta.wait$n" 2>/dev/null
  done
  cat "$PROJECT"/.zensu/state/work-order/stop-*.json > "$SBOX/delta.state" 2>/dev/null
  RESULT='{"kind":"pr-review","role":"bug-hunter","verdict_hint":"approve","summary":"No blocking issue found.","inline_findings":[],"overall_notes":[],"positives":[]}'
  seat_payload SubagentStop "$RESULT" | bash "$SEAT_STOP" >/dev/null 2>&1 || exit 96
  for n in 1 2 3 4; do
    printf '%s' "$STOP4" | bash "$STOP_HOOK" > "$SBOX/delta.after$n" 2>/dev/null
  done
); RC=$?
WAITS_OK=true
for n in 1 2 3 4; do
  grep -q '"decision":"block"' "$SBOX/delta.wait$n" 2>/dev/null \
    && grep -q '1 review seat of this session is still in flight' "$SBOX/delta.wait$n" || WAITS_OK=false
done
if [ "$RC" -eq 0 ] && [ "$WAITS_OK" = true ] && [ "$(json_get "$SBOX/delta.state" 'value.count')" = "0" ]; then
  check "I18 the Stop hook reads the session's evidence lease and counts none of four stops while a review seat is in flight" PASS
else
  check "I18 the Stop hook reads the session's evidence lease and counts none of four stops while a review seat is in flight (rc=$RC wait1=$(cat "$SBOX/delta.wait1" 2>/dev/null) state=$(cat "$SBOX/delta.state" 2>/dev/null) lease=$(cat "$SBOX/delta-lease.err" 2>/dev/null))" FAIL
fi
AFTER_OK=true
for n in 1 2 3; do
  grep -q '"decision":"block"' "$SBOX/delta.after$n" 2>/dev/null \
    && grep -q '3 stops in a row without progress' "$SBOX/delta.after$n" || AFTER_OK=false
done
if [ "$RC" -eq 0 ] && [ "$AFTER_OK" = true ] && [ ! -s "$SBOX/delta.after4" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status')" = "blocked" ] \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.blocked_kind')" = "worker_error" ]; then
  check "I19 once the seat's result lands, three stops without progress block and the fourth reports the order blocked" PASS
else
  check "I19 once the seat's result lands, three stops without progress block and the fourth reports the order blocked (rc=$RC after1=$(cat "$SBOX/delta.after1" 2>/dev/null) after4=$(cat "$SBOX/delta.after4" 2>/dev/null) status=$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status'))" FAIL
fi

finish
