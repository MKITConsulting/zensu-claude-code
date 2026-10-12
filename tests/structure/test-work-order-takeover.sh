#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/hooks/lib/zensu-work-order.sh"
LOG_HELPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
VCS_LIB="$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"
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
  echo "test-work-order-takeover: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$WRAPPER" "$LOG_HELPER" "$STATE_LIB" "$VCS_LIB" "$FAKE_LIB" "$BASELINE"; do
  if [ ! -f "$f" ] || ! bash -n "$f" 2>/dev/null; then
    check "T0 required file exists and parses: $f" FAIL
    finish; exit 1
  fi
done
check "T0 wrapper, log helper, state library, VCS driver, fake and baseline exist and parse" PASS

source "$FAKE_LIB"

SBOX="$(mktemp -d -t wo-takeover-XXXXXX)"
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT
export HOME="$SBOX/home"
mkdir -p "$HOME"
export ZENSU_CONFIG="$SBOX/config.json"
printf '%s\n' '{}' > "$ZENSU_CONFIG"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Work Order Test" GIT_AUTHOR_EMAIL="wo@example.invalid"
export GIT_COMMITTER_NAME="Work Order Test" GIT_COMMITTER_EMAIL="wo@example.invalid"

wo_fake_install "$SBOX/bin" || { check "T1 fake zensu installs" FAIL; finish; exit 1; }
export FAKE_GH_DIR="$SBOX/gh"
mkdir -p "$FAKE_GH_DIR"
cat > "$SBOX/bin/gh" <<'FAKE_GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_DIR/calls"
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  "pr view")
    if [ -f "$FAKE_GH_DIR/pr.json" ]; then cat "$FAKE_GH_DIR/pr.json"; exit 0; fi
    echo "no pull requests found for branch" >&2
    exit 1
    ;;
  "pr create")
    printf 'created\n' >> "$FAKE_GH_DIR/created"
    echo "https://github.com/acme/widgets/pull/8"
    exit 0
    ;;
  "api graphql")
    case "$*" in
      *reviews*) [ -f "$FAKE_GH_DIR/reviews.json" ] && cat "$FAKE_GH_DIR/reviews.json" && exit 0 ;;
    esac
    exit 1
    ;;
esac
exit 1
FAKE_GH
chmod +x "$SBOX/bin/gh"
export PATH="$SBOX/bin:$PATH"
export FAKE_ZENSU_STATE="$SBOX/fake.json"
export FAKE_ZENSU_CALLS="$SBOX/calls.jsonl"
export ZENSU_WORK_ORDER_RETRY_MS=1
export ZENSU_WORK_ORDER_RETRY_BUDGET_MS=50
export ZENSU_VCS_REMOTE="https://github.com/acme/widgets.git"

json_get() {
  FILE="$1" EXPR="$2" node -e '
    const value = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
    const out = Function("value", `return (${process.env.EXPR})`)(value);
    process.stdout.write(out === undefined || out === null ? "" : String(out));
  ' 2>/dev/null
}
stage_calls() {
  node -e '
    const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    const out = [];
    for (const line of lines) {
      const argv = JSON.parse(line).argv;
      if (argv[0] !== "work" || argv[1] !== "event") continue;
      const at = argv.indexOf("--stage");
      if (at >= 0) out.push(argv[at + 1]);
    }
    process.stdout.write(out.join(" "));
  ' "$FAKE_ZENSU_CALLS" 2>/dev/null
}
apply_event() {
  (source "$STATE_LIB" && autopilot_apply_event "$RUN" "$1" "$2" "$3" "$PROJECT" >/dev/null 2>&1)
}
marker_for() {
  local order="$1" head="$2" key op
  key="$(source "$STATE_LIB" && autopilot_work_order_review_operation_key "$order" "$head")" || return 1
  op="$(printf '%s' "$key" | shasum -a 256 | cut -d' ' -f1)"
  printf '<!-- zensu-review:v1:%s:%s:%s:1:part=1/1 -->' "$op" "$(printf 'd%.0s' $(seq 1 64))" "$head"
}
reviews_json() {
  node -e '
    const nodes = process.argv.slice(1).map((body, index) => ({ id: `r${index}`, body: `Team review\n\n${body}`, url: `https://github.com/acme/widgets/pull/7#pullrequestreview-${index}` }));
    process.stdout.write(JSON.stringify([{ data: { repository: { pullRequest: { reviews: { nodes, pageInfo: { hasNextPage: false, endCursor: null } } } } } }]));
  ' "$@"
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

ORDER="99999999-9999-4999-8999-999999999999"
SESSION="wo-takeover-session-0001"
RUN="run_take_0002"
BRANCH="zensu/work-99999999"
STALE_OWNER="scv1_$(printf 'c%.0s' $(seq 1 64))"
SPEC_HASH="$(printf 'a%.0s' $(seq 1 64))"

new_project alpha
git -C "$PROJECT" checkout -q -b "$BRANCH"
printf 'feature\n' > "$PROJECT/feature.txt"
git -C "$PROJECT" add feature.txt
git -C "$PROJECT" commit -q -m "feat: add the feature"
REVIEW_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
printf 'fixed\n' >> "$PROJECT/feature.txt"
git -C "$PROJECT" commit -q -am "fix: address the review"
PR_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"
git -C "$PROJECT" push -q origin "$BRANCH"

source "$BASELINE" "$SESSION" || { check "T1 test session binds" FAIL; finish; exit 1; }
STALE_RUN="run_stale_0001"
(
  source "$STATE_LIB" || exit 1
  autopilot_begin_run "$STALE_RUN" "$STALE_OWNER" "$PROJECT" false false "" \
    "{\"orderId\":\"$ORDER\",\"attempt\":1,\"specHash\":\"$SPEC_HASH\"}" >/dev/null 2>&1
) || { check "T1 the stale run of attempt 1 is planted" FAIL; finish; exit 1; }
STALE_FILE="$PROJECT/.zensu/state/autopilot-run-${STALE_RUN}.json"

wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER" "$SESSION" auto implement
wo_fake_set "$FAKE_ZENSU_STATE" "
  state.order.attempt = 2;
  state.order.status = 'reviewing';
  state.order.branch = '$BRANCH';
  state.order.pr_url = 'https://github.com/acme/widgets/pull/7';
  state.order.pr_number = 7;
  state.order.head_sha = '$PR_HEAD';
  state.order.autopilot_run_id = '$STALE_RUN';
"
printf '{"number":7,"url":"https://github.com/acme/widgets/pull/7","state":"OPEN","headRefName":"%s","baseRefName":"main"}\n' "$BRANCH" > "$FAKE_GH_DIR/pr.json"
export ZENSU_SESSION_TOKEN="zst_fake_session_token"

bash "$WRAPPER" --start --order "$ORDER" >"$SBOX/start.out" 2>"$SBOX/start.err"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(json_get "$SBOX/start.out" 'value.attempt')" = "2" ] \
  && [ "$(json_get "$SBOX/start.out" 'value.prNumber')" = "7" ] \
  && [ "$(json_get "$SBOX/start.out" 'value.branch')" = "$BRANCH" ] \
  && [ "$(json_get "$SBOX/start.out" 'value.headSha')" = "$PR_HEAD" ] \
  && [ "$(json_get "$STALE_FILE" 'value.stage')" = "CANCELLED" ] \
  && [ "$(json_get "$STALE_FILE" 'value.events[value.events.length - 1].eventId')" = "work-order-release-2" ]; then
  check "T1 --start of attempt 2 names the branch, the pull request and the head, and releases the run attempt 1 left behind" PASS
else
  check "T1 --start of attempt 2 releases the run of attempt 1 (rc=$RC stage=$(json_get "$STALE_FILE" 'value.stage') $(cat "$SBOX/start.err"))" FAIL
fi

bash "$LOG_HELPER" --autopilot-begin --run "$RUN" --work-order "$ORDER" --cover false --validate false >/dev/null 2>"$SBOX/begin.err"; RC=$?
RUN_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN}.json"
: > "$FAKE_ZENSU_CALLS"
bash "$WRAPPER" --bind-spec --run "$RUN" >"$SBOX/bind.out" 2>"$SBOX/bind.err"; RC2=$?
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ "$(json_get "$RUN_FILE" 'value.stage')" = "AWAIT_TDD" ] \
  && [ "$(json_get "$RUN_FILE" 'value.workOrder.attempt')" = "2" ] \
  && ! stage_calls | grep -q 'implementing' \
  && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status')" = "reviewing" ]; then
  check "T2 the new attempt begins a fresh run and binds its spec without sending a stage behind the order" PASS
else
  check "T2 the new attempt binds its spec on an order at reviewing (begin=$RC bind=$RC2 stages=$(stage_calls) $(cat "$SBOX/begin.err" "$SBOX/bind.err"))" FAIL
fi

CHAIN="chain_take_0001"
if apply_event take-tdd-started TDD_STARTED "{\"attempt\":1,\"chainId\":\"$CHAIN\",\"sessionId\":\"$SESSION\"}" \
  && apply_event take-tdd-done TDD_CHAIN_DONE "{\"attempt\":1,\"chainId\":\"$CHAIN\",\"sessionId\":\"$SESSION\",\"outcome\":\"no-changes\"}" \
  && apply_event take-gates GATES_PASSED "{\"headSha\":\"$PR_HEAD\"}" \
  && apply_event take-converge CONVERGENCE_PASSED '{}' \
  && apply_event take-pr-request PR_OPEN_REQUESTED "{\"operationKey\":\"pr:$RUN\"}"; then
  READY=true
else
  READY=false
fi
printf 'body\n' > "$SBOX/body.md"
bash "$WRAPPER" --push >"$SBOX/push.out" 2>"$SBOX/push.err"; PUSH_RC=$?
bash "$WRAPPER" --open-pr --title "Take over" --body-file "$SBOX/body.md" >"$SBOX/open.out" 2>"$SBOX/open.err"; RC=$?
if [ "$READY" = true ] && [ "$PUSH_RC" -eq 0 ] && [ "$RC" -eq 0 ] \
  && [ "$(json_get "$SBOX/open.out" 'value.value.imported')" = "true" ] \
  && [ "$(json_get "$SBOX/open.out" 'value.value.number')" = "7" ] \
  && [ "$(json_get "$SBOX/open.out" 'value.value.head')" = "$PR_HEAD" ] \
  && [ ! -e "$FAKE_GH_DIR/created" ]; then
  check "T3 --open-pr imports the open pull request the order names instead of opening a second one" PASS
else
  check "T3 --open-pr imports the order's pull request (ready=$READY push=$PUSH_RC rc=$RC out=$(cat "$SBOX/open.out") $(cat "$SBOX/push.err" "$SBOX/open.err"))" FAIL
fi

apply_event take-pr-open PR_OPENED "{\"operationKey\":\"pr:$RUN\",\"pr\":{\"number\":7,\"url\":\"https://github.com/acme/widgets/pull/7\",\"headSha\":\"$PR_HEAD\"}}" \
  || READY=false

GOOD_MARKER="$(marker_for "$ORDER" "$REVIEW_HEAD")"
FOREIGN_MARKER="$(marker_for "12121212-1212-4212-8212-121212121212" "$REVIEW_HEAD")"
ORPHAN_HEAD="$(printf 'e%.0s' $(seq 1 40))"
ORPHAN_MARKER="$(marker_for "$ORDER" "$ORPHAN_HEAD")"
reviews_json "$FOREIGN_MARKER" "$GOOD_MARKER" "$ORPHAN_MARKER" > "$FAKE_GH_DIR/reviews.json"
bash "$WRAPPER" --review-import --run "$RUN" >"$SBOX/import.out" 2>"$SBOX/import.err"; RC=$?
if [ "$READY" = true ] && [ "$RC" -eq 0 ] \
  && [ "$(json_get "$SBOX/import.out" 'value.imported')" = "true" ] \
  && [ "$(json_get "$SBOX/import.out" 'value.headSha')" = "$REVIEW_HEAD" ] \
  && [ "$(json_get "$RUN_FILE" 'value.stage')" = "FIX_FINDINGS" ] \
  && [ "$(json_get "$RUN_FILE" 'value.events.filter(e => e.eventType === "TEAM_REVIEW_IMPORTED").length')" = "1" ] \
  && [ "$(json_get "$RUN_FILE" 'value.evidence.review.marker')" = "$GOOD_MARKER" ] \
  && [ "$(json_get "$RUN_FILE" 'value.effects.teamReview.status')" = "completed" ]; then
  check "T4 --review-import finds the earlier attempt's team review by its order-bound marker and moves the run to FIX_FINDINGS" PASS
else
  check "T4 --review-import imports the earlier team review (ready=$READY rc=$RC out=$(cat "$SBOX/import.out") stage=$(json_get "$RUN_FILE" 'value.stage') $(cat "$SBOX/import.err"))" FAIL
fi

if ! grep -qE '^pr (create|review|comment)|addPullRequestReview|--method POST|-X POST' "$FAKE_GH_DIR/calls" \
  && [ ! -e "$FAKE_GH_DIR/created" ]; then
  check "T5 the takeover publishes no second team review and opens no second pull request" PASS
else
  check "T5 the takeover publishes no second team review ($(cat "$FAKE_GH_DIR/calls"))" FAIL
fi

bash "$WRAPPER" --review-import --run "$RUN" >"$SBOX/import2.out" 2>/dev/null; RC=$?
[ "$RC" -eq 0 ] && [ "$(json_get "$SBOX/import2.out" 'value.imported')" = "true" ] \
  && [ "$(json_get "$RUN_FILE" 'value.events.filter(e => e.eventType === "TEAM_REVIEW_IMPORTED").length')" = "1" ] \
  && check "T6 a repeated --review-import records nothing twice" PASS \
  || check "T6 a repeated --review-import records nothing twice (rc=$RC)" FAIL

bash "$LOG_HELPER" --autopilot-event --run "$RUN" --event TEAM_REVIEW_IMPORTED --event-id forged-import \
  --payload '{}' >/dev/null 2>"$SBOX/forged.err"; RC=$?
bash "$LOG_HELPER" --autopilot-event --run "$RUN" --event CANCEL --event-id work-order-release-9 \
  --payload '{}' >/dev/null 2>"$SBOX/squat.err"; RC2=$?
[ "$RC" -eq 2 ] && grep -q 'is internal' "$SBOX/forged.err" && [ "$RC2" -eq 2 ] \
  && grep -q "work-order-release-" "$SBOX/squat.err" && [ "$(json_get "$RUN_FILE" 'value.stage')" = "FIX_FINDINGS" ] \
  && check "T7 TEAM_REVIEW_IMPORTED and the work-order release event ids cannot be recorded through --autopilot-event" PASS \
  || check "T7 TEAM_REVIEW_IMPORTED and the release namespace are internal (rc=$RC rc2=$RC2)" FAIL

: > "$FAKE_ZENSU_CALLS"
if apply_event take-findings FINDINGS_CLEARED "{\"headSha\":\"$PR_HEAD\",\"unresolvedCount\":0}" \
  && apply_event take-delivery DELIVERY_COMPLETE "{\"headSha\":\"$PR_HEAD\"}" \
  && [ "$(json_get "$RUN_FILE" 'value.stage')" = "DONE" ]; then
  bash "$WRAPPER" --finish >"$SBOX/finish.out" 2>"$SBOX/finish.err"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status')" = "ready_for_merge" ] \
    && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.head_sha')" = "$PR_HEAD" ] \
    && [ "$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.pr_number')" = "7" ]; then
    check "T8 a run with an imported review delivers and reports ready_for_merge on the order's pull request and head" PASS
  else
    check "T8 a run with an imported review reports ready_for_merge (rc=$RC status=$(wo_fake_get "$FAKE_ZENSU_STATE" 'state.order.status') $(cat "$SBOX/finish.err"))" FAIL
  fi
else
  check "T8 a run with an imported review reaches DONE (stage=$(json_get "$RUN_FILE" 'value.stage'))" FAIL
fi

ORDER2="13131313-1313-4313-8313-131313131313"
SESSION2="wo-takeover-session-0002"
RUN2="run_take_fresh_0001"
(
  new_project beta
  RUN="$RUN2"
  git -C "$PROJECT" checkout -q -b "zensu/work-13131313"
  printf 'x\n' > "$PROJECT/x.txt"
  git -C "$PROJECT" add x.txt
  git -C "$PROJECT" commit -q -m "feat: x"
  HEAD2="$(git -C "$PROJECT" rev-parse HEAD)"
  git -C "$PROJECT" push -q origin "zensu/work-13131313"
  source "$BASELINE" "$SESSION2" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER2" "$SESSION2" auto implement
  wo_fake_set "$FAKE_ZENSU_STATE" "state.order.branch = 'zensu/work-13131313'; state.order.head_sha = '$HEAD2';"
  rm -f "$FAKE_GH_DIR/pr.json" "$FAKE_GH_DIR/created"
  reviews_json "$(marker_for "$ORDER" "$REVIEW_HEAD")" > "$FAKE_GH_DIR/reviews.json"
  bash "$WRAPPER" --start --order "$ORDER2" >/dev/null 2>&1 || exit 91
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN2" --work-order "$ORDER2" --cover false --validate false >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN2" >/dev/null 2>&1 || exit 93
  apply_event fresh-tdd-started TDD_STARTED "{\"attempt\":1,\"chainId\":\"chain_fresh_1\",\"sessionId\":\"$SESSION2\"}" || exit 94
  apply_event fresh-tdd-done TDD_CHAIN_DONE "{\"attempt\":1,\"chainId\":\"chain_fresh_1\",\"sessionId\":\"$SESSION2\",\"outcome\":\"pass\"}" || exit 95
  apply_event fresh-gates GATES_PASSED "{\"headSha\":\"$HEAD2\"}" || exit 96
  apply_event fresh-converge CONVERGENCE_PASSED '{}' || exit 97
  apply_event fresh-pr-request PR_OPEN_REQUESTED "{\"operationKey\":\"pr:$RUN2\"}" || exit 98
  bash "$WRAPPER" --open-pr --title "Fresh" --body-file "$SBOX/body.md" > "$SBOX/fresh-open.out" 2>/dev/null || exit 99
  apply_event fresh-pr-open PR_OPENED "{\"operationKey\":\"pr:$RUN2\",\"pr\":{\"number\":8,\"url\":\"https://github.com/acme/widgets/pull/8\",\"headSha\":\"$HEAD2\"}}" || exit 100
  bash "$WRAPPER" --review-import --run "$RUN2" > "$SBOX/fresh-import.out" 2>/dev/null || exit 101
  RUN_KEY="$(source "$STATE_LIB" && autopilot_team_review_operation_key "$RUN2" "$HEAD2")"
  apply_event fresh-review-run-key TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$RUN_KEY\",\"provider\":\"github\"}" && exit 102
  ORDER_KEY="$(json_get "$SBOX/fresh-import.out" 'value.operationKey')"
  [ "$ORDER_KEY" = "$(source "$STATE_LIB" && autopilot_work_order_review_operation_key "$ORDER2" "$HEAD2")" ] || exit 103
  apply_event fresh-review-order-key TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$ORDER_KEY\",\"provider\":\"github\"}" || exit 104
  json_get "$PROJECT/.zensu/state/autopilot-run-${RUN2}.json" 'value.effects.teamReview.status' > "$SBOX/fresh.status"
  json_get "$SBOX/fresh-import.out" 'value.imported' > "$SBOX/fresh.imported"
  [ -e "$FAKE_GH_DIR/created" ] && printf 'created' > "$SBOX/fresh.created"
  printf '{"event":"COMMENT","body":"Work-order team review","commit_id":"%s","comments":[]}\n' "$HEAD2" > "$SBOX/review-payload.json"
  SNAPSHOT="$(source "$STATE_LIB" && autopilot_store_team_review_payload "$RUN2" "$ORDER_KEY" "$HEAD2" "$SBOX/review-payload.json" github "$PROJECT")" || exit 105
  [ -f "$SNAPSHOT" ] || exit 106
  MARKER="$(source "$VCS_LIB" && _zensu_vcs_review_payload_meta github "$SNAPSHOT" "$HEAD2" "$ORDER_KEY" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).marker)')" || exit 107
  apply_event fresh-review-published TEAM_REVIEW_PUBLISHED "{\"operationKey\":\"$ORDER_KEY\",\"provider\":\"github\",\"marker\":\"$MARKER\",\"headSha\":\"$HEAD2\"}" || exit 108
  json_get "$PROJECT/.zensu/state/autopilot-run-${RUN2}.json" 'value.stage' > "$SBOX/fresh.published"
  exit 0
); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/fresh.imported")" = "false" ] && [ "$(cat "$SBOX/fresh.status")" = "requested" ] \
  && [ "$(cat "$SBOX/fresh.created" 2>/dev/null)" = "created" ]; then
  check "T9 without an earlier review of this order --review-import imports nothing, and the run accepts only the order-bound review key" PASS
else
  check "T9 a first attempt requests its own review under the order-bound key (rc=$RC imported=$(cat "$SBOX/fresh.imported" 2>/dev/null) status=$(cat "$SBOX/fresh.status" 2>/dev/null))" FAIL
fi
[ "$RC" -eq 0 ] && [ "$(cat "$SBOX/fresh.published" 2>/dev/null)" = "FIX_FINDINGS" ] \
  && check "T9b the order-bound review payload is stored and its publication is recorded like any other" PASS \
  || check "T9b the order-bound review payload is stored and its publication is recorded (rc=$RC stage=$(cat "$SBOX/fresh.published" 2>/dev/null))" FAIL

ORDER3="14141414-1414-4414-8414-141414141414"
SESSION3="wo-takeover-session-0003"
RUN3="run_take_closed_0001"
(
  new_project gamma
  RUN="$RUN3"
  git -C "$PROJECT" checkout -q -b "zensu/work-14141414"
  printf 'y\n' > "$PROJECT/y.txt"
  git -C "$PROJECT" add y.txt
  git -C "$PROJECT" commit -q -m "feat: y"
  HEAD3="$(git -C "$PROJECT" rev-parse HEAD)"
  git -C "$PROJECT" push -q origin "zensu/work-14141414"
  source "$BASELINE" "$SESSION3" || exit 90
  wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER3" "$SESSION3" auto implement
  wo_fake_set "$FAKE_ZENSU_STATE" "
    state.order.attempt = 2; state.order.status = 'pr_open'; state.order.branch = 'zensu/work-14141414';
    state.order.pr_url = 'https://github.com/acme/widgets/pull/9'; state.order.pr_number = 9; state.order.head_sha = '$HEAD3';
  "
  printf '{"number":9,"url":"https://github.com/acme/widgets/pull/9","state":"CLOSED","headRefName":"zensu/work-14141414","baseRefName":"main"}\n' > "$FAKE_GH_DIR/pr.json"
  rm -f "$FAKE_GH_DIR/created"
  bash "$WRAPPER" --start --order "$ORDER3" >/dev/null 2>&1 || exit 91
  bash "$LOG_HELPER" --autopilot-begin --run "$RUN3" --work-order "$ORDER3" --cover false --validate false >/dev/null 2>&1 || exit 92
  bash "$WRAPPER" --bind-spec --run "$RUN3" >/dev/null 2>&1 || exit 93
  bash "$WRAPPER" --open-pr --title "Closed" --body-file "$SBOX/body.md" >/dev/null 2>"$SBOX/closed.err"
  echo "$?" > "$SBOX/closed.rc"
  [ -e "$FAKE_GH_DIR/created" ] && printf 'created' > "$SBOX/closed.created"
  exit 0
); RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$SBOX/closed.rc")" = "8" ] && grep -q 'is closed' "$SBOX/closed.err" \
  && [ ! -e "$SBOX/closed.created" ]; then
  check "T10 --open-pr refuses an order whose pull request was closed and opens no replacement" PASS
else
  check "T10 --open-pr refuses a closed pull request (rc=$RC open=$(cat "$SBOX/closed.rc" 2>/dev/null) $(cat "$SBOX/closed.err" 2>/dev/null))" FAIL
fi

finish
