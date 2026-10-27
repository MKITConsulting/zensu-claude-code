#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
LIB="$PLUGIN_DIR/hooks/lib/stop-background-wait-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/stop-background-wait-v1.test.js"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
EXAMPLE_CONFIG="$PLUGIN_DIR/config.example.json"
source "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-stop-background-wait: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$STOP" "$LOG" "$PHASE" "$LIB" "$UNIT" "$PROFILE" "$EXAMPLE_CONFIG"; do
  if [ ! -f "$f" ]; then
    check "B0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "B0 node and git are available" FAIL
  finish
  exit 1
fi
check "B0 required files, node and git are present" PASS

if node -e 'const m = require(process.argv[1]); process.exit(m.ciStructureTests.includes("test-stop-background-wait.sh") ? 0 : 1)' "$PROFILE"; then
  check "B0a the suite is classified as a CI structure test" PASS
else
  check "B0a the suite is classified as a CI structure test" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "B0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

unit_check "B0b the background-wait unit file passes" "$UNIT"

if bash -n "$STOP" && bash -n "$LOG" && bash -n "$PHASE" && node --check "$LIB"; then
  check "B0c the hook, the log helper, the phase library and the module parse" PASS
else
  check "B0c the hook, the log helper, the phase library and the module parse" FAIL
fi

if node -e 'const c = require(process.argv[1]); process.exit(c.hooks && c.hooks.backgroundTaskWait === true ? 0 : 1)' "$EXAMPLE_CONFIG"; then
  check "B0d config.example.json carries hooks.backgroundTaskWait with its default" PASS
else
  check "B0d config.example.json carries hooks.backgroundTaskWait with its default" FAIL
fi

export HOME="$WORK/home"
mkdir -p "$HOME"
DEFAULT_CONFIG="$WORK/config-default.json"
printf '%s\n' '{}' >"$DEFAULT_CONFIG"
OFF_CONFIG="$WORK/config-off.json"
printf '%s\n' '{"hooks":{"backgroundTaskWait":false}}' >"$OFF_CONFIG"
export ZENSU_CONFIG="$DEFAULT_CONFIG"

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).reason||"")}catch(_){}});'; }
stop_notice_only() {
  OUT_TEXT="$1" ERR_FILE="$2" NEEDLE="${3:-}" node -e '
    const fs = require("node:fs");
    let parsed;
    try { parsed = JSON.parse(process.env.OUT_TEXT); } catch (_) { process.exit(1); }
    if (!parsed || Object.keys(parsed).join() !== "systemMessage" || typeof parsed.systemMessage !== "string") process.exit(1);
    const lines = parsed.systemMessage.split("\n");
    const stderrLines = fs.readFileSync(process.env.ERR_FILE, "utf8").split("\n");
    if (!lines.every((line) => stderrLines.includes(line))) process.exit(1);
    process.exit(lines.some((line) => line.includes(process.env.NEEDLE)) ? 0 : 1);
  ' 2>/dev/null
}

stop_payload() {
  RAW="$1" TASKS="${2:-absent}" MESSAGE="${3:-}" TRANSCRIPT="${4:-}" node -e '
    const payload = { hook_event_name: "Stop", session_id: process.env.RAW };
    if (process.env.TASKS !== "absent") payload.background_tasks = JSON.parse(process.env.TASKS);
    if (process.env.MESSAGE) payload.last_assistant_message = process.env.MESSAGE;
    if (process.env.TRANSCRIPT) payload.transcript_path = process.env.TRANSCRIPT;
    process.stdout.write(JSON.stringify(payload));
  '
}

arm() {
  local raw="$1"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/stop-data/$raw"
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$raw" || return 1
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  ARMED_KEY="$ZENSU_SESSION_KEY"
  ARMED_DATA="$CLAUDE_PLUGIN_DATA"
}

stop_count() {
  bash -c 'source "$1"; tdd_get_counter "$(tdd_state_file "$2")" stopBlockCount' _ "$PHASE" "$1" 2>/dev/null
}

numeric() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

RUN_TASKS='[{"id":"run1","type":"shell","status":"running","description":"E2E reproduction run","command":"npx playwright test"},{"id":"srv1","type":"shell","status":"running","description":"Start the dev server","command":"npm run dev"}]'
AWAIT_RUN=$'The E2E run is still going.\nZENSU-AWAIT: run1'
RELEASE_NOTE='releasing this Stop while the background task(s) this turn waits for still run (run1)'
HINT_LEAD="STOP intercepted by zensu chain-enforcer. This session's review chain is still armed"
RESUME='Resume the /zensu:tdd Phase 6 review sequence'

STOP_PROJECT="$WORK/stop-project"
mkdir -p "$STOP_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$STOP_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1

arm bw-control || { check "B1 arm" FAIL; finish; exit 1; }
CONTROL_DATA="$ARMED_DATA"
OUT="$(stop_payload bw-control | bash "$STOP" 2>/dev/null)"
CONTROL_REASON="$(printf '%s' "$OUT" | reason)"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && printf '%s' "$CONTROL_REASON" | grep -qF "$RESUME" \
  && ! printf '%s' "$CONTROL_REASON" | grep -qF 'ZENSU-AWAIT'; then
  check "B1 control: an armed chain without background work blocks with the resume directive and no wait hint" PASS
else
  check "B1 control (out=$OUT)" FAIL
fi

arm bw-hint || { check "B2 arm" FAIL; finish; exit 1; }
HINT_KEY="$ARMED_KEY"
HINT_DATA="$ARMED_DATA"
BEFORE="$(stop_count "$HINT_KEY")"
OUT="$(stop_payload bw-hint "$RUN_TASKS" | bash "$STOP" 2>"$WORK/hint.err")"
HINT_REASON="$(printf '%s' "$OUT" | reason)"
AFTER_HINT="$(stop_count "$HINT_KEY")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && printf '%s' "$HINT_REASON" | grep -qF "$HINT_LEAD" \
  && printf '%s' "$HINT_REASON" | grep -qF 'run1 (shell: "E2E reproduction run")' \
  && printf '%s' "$HINT_REASON" | grep -qF 'srv1 (shell: "Start the dev server")' \
  && printf '%s' "$HINT_REASON" | grep -qF "'ZENSU-AWAIT: <task id>' on a line of its own" \
  && printf '%s' "$HINT_REASON" | grep -qF 'such as a dev server' \
  && ! printf '%s' "$HINT_REASON" | grep -qF "$RESUME" \
  && numeric "$BEFORE" && [ "$BEFORE" = "$AFTER_HINT" ]; then
  check "B2 running tasks without a ZENSU-AWAIT line get one wait hint naming each task, and it charges no Stop budget" PASS
else
  check "B2 hint (out=$OUT before=$BEFORE after=$AFTER_HINT err=$(cat "$WORK/hint.err"))" FAIL
fi

OUT="$(stop_payload bw-hint "$RUN_TASKS" | bash "$STOP" 2>/dev/null)"
AFTER_SECOND="$(stop_count "$HINT_KEY")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && printf '%s' "$OUT" | reason | grep -qF "$RESUME" \
  && ! printf '%s' "$OUT" | reason | grep -qF "$HINT_LEAD" \
  && numeric "$AFTER_SECOND" && [ "$AFTER_SECOND" = "$((AFTER_HINT + 1))" ]; then
  check "B3 a second Stop that sees no new task gets the ordinary directive, charged as before" PASS
else
  check "B3 hinted again (out=$OUT count=$AFTER_SECOND)" FAIL
fi

OUT="$(stop_payload bw-hint "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>"$WORK/release.err")"; RC=$?
AFTER_RELEASE="$(stop_count "$HINT_KEY")"
if [ "$RC" -eq 0 ] && stop_notice_only "$OUT" "$WORK/release.err" "$RELEASE_NOTE; release 1 of 5 for each" \
  && [ "$AFTER_RELEASE" = "$AFTER_SECOND" ]; then
  check "B4 a ZENSU-AWAIT line naming a running task releases the Stop, names it in one notice on stderr and as the Stop's systemMessage, and charges no Stop budget" PASS
else
  check "B4 release (rc=$RC out=$OUT count=$AFTER_RELEASE err=$(cat "$WORK/release.err"))" FAIL
fi

DECISIONS=""
for _ in 2 3 4 5 6; do
  OUT="$(stop_payload bw-hint "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>"$WORK/limit.err")"
  DECISIONS="$DECISIONS $(printf '%s' "$OUT" | decision)"
done
if [ "$DECISIONS" = " allow allow allow allow block" ] && printf '%s' "$OUT" | reason | grep -qF "$RESUME" \
  && ! grep -qF "$RELEASE_NOTE" "$WORK/limit.err" && [ "$(stop_count "$HINT_KEY")" = "$((AFTER_RELEASE + 1))" ]; then
  check "B5 a task releases at most five Stops; the sixth gets the ordinary directive" PASS
else
  check "B5 limit (decisions=$DECISIONS count=$(stop_count "$HINT_KEY"))" FAIL
fi

STATE_FILE="$HINT_DATA/stop-background-wait/v1/$HINT_KEY.json"
STATE_PRESENT=false
[ -f "$STATE_FILE" ] && STATE_PRESENT=true
bash "$LOG" --tdd-begin --session "$HINT_KEY" >/dev/null 2>&1; BEGIN_RC=$?
if [ "$STATE_PRESENT" = true ] && [ "$BEGIN_RC" -eq 0 ] && [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
  check "B6 arming a new chain generation deletes the session's background-wait state" PASS
else
  check "B6 generation reset (present=$STATE_PRESENT rc=$BEGIN_RC)" FAIL
fi

arm bw-gone || { check "B7 arm" FAIL; finish; exit 1; }
OUT="$(stop_payload bw-gone "$RUN_TASKS" $'Waiting.\nZENSU-AWAIT: gone1' | bash "$STOP" 2>"$WORK/gone.err")"
FIRST_GONE="$(printf '%s' "$OUT" | decision)"
OUT="$(stop_payload bw-gone "$RUN_TASKS" $'Waiting.\nZENSU-AWAIT: gone1' | bash "$STOP" 2>>"$WORK/gone.err")"
if [ "$FIRST_GONE" = "block" ] && [ "$(printf '%s' "$OUT" | decision)" = "block" ] \
  && printf '%s' "$OUT" | reason | grep -qF "$RESUME" && ! grep -qF 'releasing this Stop' "$WORK/gone.err"; then
  check "B7 a ZENSU-AWAIT line naming a task that is not in flight never releases" PASS
else
  check "B7 named task not in flight (first=$FIRST_GONE out=$OUT)" FAIL
fi

DIFF_OK=true
for tasks in '[{"id":"t1","type":"dream","status":"running","description":"memory"}]' \
  '[{"id":"t1","type":"local_bash","status":"running","description":"raw"}]' \
  '[{"id":"t1","type":"shell","status":"completed","description":"done"}]' \
  '"shell"'; do
  RAW_NOW="bw-diff-$RANDOM"
  arm "$RAW_NOW" || DIFF_OK=false
  OUT="$(stop_payload "$RAW_NOW" "$tasks" $'Waiting.\nZENSU-AWAIT: t1' | bash "$STOP" 2>"$WORK/diff.err")"
  if [ "$(printf '%s' "$OUT" | decision)" != "block" ] || grep -qF 'releasing this Stop' "$WORK/diff.err"; then DIFF_OK=false; fi
  if [ "$(printf '%s' "$OUT" | reason | sed "s#$ARMED_DATA#DATA#g")" != "$(printf '%s' "$CONTROL_REASON" | sed "s#$CONTROL_DATA#DATA#g")" ]; then DIFF_OK=false; fi
done
if [ "$DIFF_OK" = "true" ]; then
  check "B8 another task type, a finished task and a malformed field neither release nor hint: the control block renders" PASS
else
  check "B8 differential render" FAIL
fi

arm bw-fix || { check "B9 arm" FAIL; finish; exit 1; }
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  s.reviewRound = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
' "$CLAUDE_PROJECT_DIR/.zensu/state/tdd-phase-$ARMED_KEY.json"
FIX_BEFORE="$(stop_count "$ARMED_KEY")"
OUT="$(stop_payload bw-fix "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>"$WORK/fix.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "allow" ] && grep -qF "$RELEASE_NOTE" "$WORK/fix.err" \
  && [ "$(stop_count "$ARMED_KEY")" = "$FIX_BEFORE" ]; then
  check "B9 a routed fix round is released while the task it waits for runs" PASS
else
  check "B9 fix round (out=$OUT err=$(cat "$WORK/fix.err"))" FAIL
fi

arm bw-converged || { check "B10 arm" FAIL; finish; exit 1; }
bash "$LOG" --code-review-done --session "$ARMED_KEY" >/dev/null 2>&1
CONVERGED_KEY="$ARMED_KEY"
OUT="$(stop_payload bw-converged "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>"$WORK/conv.err")"
CONV_RELEASE="$(printf '%s' "$OUT" | decision)"
OUT="$(stop_payload bw-converged '[{"id":"suite2","type":"shell","status":"running","description":"affected suites"}]' | bash "$STOP" 2>/dev/null)"
CONV_HINT_REASON="$(printf '%s' "$OUT" | reason)"
OUT="$(stop_payload bw-converged '[{"id":"suite2","type":"shell","status":"running","description":"affected suites"}]' | bash "$STOP" 2>/dev/null)"
if [ "$CONV_RELEASE" = "allow" ] && grep -qF "$RELEASE_NOTE" "$WORK/conv.err" \
  && printf '%s' "$CONV_HINT_REASON" | grep -qF 'suite2 (shell: "affected suites")' \
  && printf '%s' "$OUT" | reason | grep -qF "skill='zensu:self-review'"; then
  check "B10 the self-review stage is released for a named task, hinted for a new one, and keeps its own directive after that" PASS
else
  check "B10 self-review stage (release=$CONV_RELEASE out=$OUT err=$(cat "$WORK/conv.err"))" FAIL
fi

arm bw-off || { check "B11 arm" FAIL; finish; exit 1; }
OUT="$(stop_payload bw-off "$RUN_TASKS" "$AWAIT_RUN" | ZENSU_CONFIG="$OFF_CONFIG" bash "$STOP" 2>"$WORK/off.err")"
OFF_NAMED="$(printf '%s' "$OUT" | reason)"
OUT="$(stop_payload bw-off "$RUN_TASKS" | ZENSU_CONFIG="$OFF_CONFIG" bash "$STOP" 2>>"$WORK/off.err")"
if printf '%s' "$OFF_NAMED" | grep -qF "$RESUME" && printf '%s' "$OUT" | reason | grep -qF "$RESUME" \
  && ! printf '%s' "$OUT" | reason | grep -qF "$HINT_LEAD" && ! grep -qF 'releasing this Stop' "$WORK/off.err" \
  && [ ! -e "$ARMED_DATA/stop-background-wait/v1/$ARMED_KEY.json" ]; then
  check "B11 hooks.backgroundTaskWait=false neither releases nor hints" PASS
else
  check "B11 flag off (out=$OUT err=$(cat "$WORK/off.err"))" FAIL
fi

OVERLAY_PROJECT="$WORK/overlay-project"
OVERLAY_AMBIENT="$WORK/overlay-ambient"
mkdir -p "$OVERLAY_PROJECT/.zensu" "$OVERLAY_AMBIENT/.zensu"
export CLAUDE_PROJECT_DIR="$(cd -P "$OVERLAY_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
arm bw-overlay || { check "B12 arm" FAIL; finish; exit 1; }
overlay_run() {
  stop_payload bw-overlay "$RUN_TASKS" "$AWAIT_RUN" \
    | env -u ZENSU_CONFIG CLAUDE_PROJECT_DIR="$OVERLAY_AMBIENT" bash "$STOP" 2>/dev/null | decision
}
printf '%s\n' '{"hooks":{"backgroundTaskWait":false}}' >"$CLAUDE_PROJECT_DIR/.zensu/config.json"
RECORD_OFF="$(overlay_run)"
rm -f "$CLAUDE_PROJECT_DIR/.zensu/config.json"
printf '%s\n' '{"hooks":{"backgroundTaskWait":false}}' >"$OVERLAY_AMBIENT/.zensu/config.json"
AMBIENT_OFF="$(overlay_run)"
rm -f "$OVERLAY_AMBIENT/.zensu/config.json"
if [ "$RECORD_OFF" = "block" ] && [ "$AMBIENT_OFF" = "allow" ]; then
  check "B12 the record root's config overlay governs hooks.backgroundTaskWait, the ambient root's does not" PASS
else
  check "B12 record-anchored read (record=$RECORD_OFF ambient=$AMBIENT_OFF)" FAIL
fi

export CLAUDE_PROJECT_DIR="$(cd -P "$STOP_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
DENIED_TRANSCRIPT="$WORK/denied.jsonl"
cat >"$DENIED_TRANSCRIPT" <<'DENIED_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
DENIED_EOF
arm bw-denied || { check "B13 arm" FAIL; finish; exit 1; }
OUT="$(stop_payload bw-denied "$RUN_TASKS" "$AWAIT_RUN" "$DENIED_TRANSCRIPT" | bash "$STOP" 2>"$WORK/denied.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && printf '%s' "$OUT" | reason | grep -qF 'refused by the HOST permission layer' \
  && ! grep -qF 'releasing this Stop' "$WORK/denied.err"; then
  check "B13 a refused reviewer spawn keeps its own block while a named task runs" PASS
else
  check "B13 refused spawn (out=$OUT)" FAIL
fi

export ZENSU_TEST_PLUGIN_DATA="$WORK/stop-data/bw-implementing"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" bw-implementing || { check "B14 baseline" FAIL; finish; exit 1; }
bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1
OUT="$(stop_payload bw-implementing "$RUN_TASKS" | bash "$STOP" 2>"$WORK/impl.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "allow" ] && ! grep -qF 'releasing this Stop while the background' "$WORK/impl.err"; then
  check "B14 a chain still implementing is released by its own path, never hinted" PASS
else
  check "B14 implementing (out=$OUT)" FAIL
fi

OUTER_PROJECT="$WORK/outer-project"
mkdir -p "$OUTER_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$OUTER_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
arm bw-outer || { check "B15 arm" FAIL; finish; exit 1; }
bash -c 'source "$1"; autopilot_begin_run run-bw-outer "$2" "$3"' _ "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" "$ARMED_KEY" "$CLAUDE_PROJECT_DIR" >/dev/null 2>&1 || { check "B15 the Autopilot run fixture begins" FAIL; finish; exit 1; }
OUT="$(stop_payload bw-outer "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>"$WORK/outer.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && ! grep -qF 'releasing this Stop while the background' "$WORK/outer.err" \
  && ! printf '%s' "$OUT" | reason | grep -qF "$HINT_LEAD" \
  && [ ! -e "$ARMED_DATA/stop-background-wait/v1/$ARMED_KEY.json" ]; then
  check "B15 a session that owns a live Autopilot run neither releases nor hints" PASS
else
  check "B15 own Autopilot run (out=$OUT err=$(cat "$WORK/outer.err"))" FAIL
fi

ADOPT_PROJECT="$WORK/adopt-project"
mkdir -p "$ADOPT_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$ADOPT_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
export ZENSU_TEST_PLUGIN_DATA="$WORK/stop-data/bw-adopt"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" bw-adopt || { check "B16 baseline" FAIL; finish; exit 1; }
bash "$LOG" --pending-review --files "src/x.ts" --summary "queued work" >/dev/null 2>&1
OUT="$(stop_payload bw-adopt "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>"$WORK/adopt.err")"
ADOPT_DECISION="$(printf '%s' "$OUT" | decision)"
OUT="$(stop_payload bw-adopt "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>>"$WORK/adopt.err")"
if [ "$ADOPT_DECISION" = "block" ] && [ "$(printf '%s' "$OUT" | decision)" = "block" ] \
  && ! grep -qF 'releasing this Stop while the background' "$WORK/adopt.err" \
  && ! printf '%s' "$OUT" | reason | grep -qF "$HINT_LEAD" \
  && [ -e "$CLAUDE_PROJECT_DIR/.zensu/state/pending-review.json.claim" ]; then
  check "B16 a Stop that adopts a deferred review, and every later Stop while the claim is held, neither releases nor hints" PASS
else
  check "B16 deferred review (first=$ADOPT_DECISION out=$OUT err=$(cat "$WORK/adopt.err"))" FAIL
fi

WAIT_FN="$(sed -n '/^stop_background_wait() {/,/^}/p' "$STOP")"
probe_wait() {
  BOUND="$1" ADOPTED="$2" PROBE_INPUT="$3" CALLS="$4" COUNT="${5:-0}" WAIT_FN="$WAIT_FN" PLUGIN_DIR="$PLUGIN_DIR" PROBE_DATA="$WORK/probe-data" bash -c '
    eval "$WAIT_FN"
    INPUT="$PROBE_INPUT"
    OUTER_PRESENT=false
    DEFERRED_ADOPTED="$ADOPTED"
    INNER_BOUND_RUN="$BOUND"
    SESSION_ID="scv1_0000000000000000000000000000000000000000000000000000000000000000"
    PROJECT_ROOT="$PROBE_DATA"
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
    CLAUDE_PLUGIN_DATA="$PROBE_DATA"
    CAP=5
    STATE_FILE="$PROBE_DATA/tdd-phase.json"
    note() { printf "%s\n" "$1" >>"$CALLS"; }
    zensu_session_key_canonical() { note key; return 0; }
    zensu_hook_enabled() { note config; return 0; }
    reviewer_spawn_denied() { note probe; return 1; }
    zensu_pending_review_file() { note pending; printf "%s\n" "$PROBE_DATA/pending-review.json"; }
    zensu_pending_review_claim_file() { note claim; printf "%s\n" "$1.claim"; }
    tdd_get_counter() { note counter; printf "%s\n" "$COUNT"; }
    zensu_msys_env_exclusions() { note msys; printf "\n"; }
    bash() { note bash; printf "%s\n" "$PROBE_DATA"; }
    node() { note node; return 1; }
    zensu_run_bounded() { note run; printf "wait release=1 max=5 tasks=1 ids=run1\nnote line\n"; }
    if stop_background_wait; then printf "%s %s\n" "$STOP_WAIT_VERDICT" "$STOP_WAIT_TEXT"; else printf "kept\n"; fi
  '
}
mkdir -p "$WORK/probe-data"
TASK_INPUT='{"background_tasks":[{"id":"run1","type":"shell","status":"running"}]}'
UNBOUND_PROBE="$(probe_wait "" false "$TASK_INPUT" "$WORK/calls-unbound")"
BOUND_PROBE="$(probe_wait "run-bw-bound" false "$TASK_INPUT" "$WORK/calls-bound")"
ADOPTED_PROBE="$(probe_wait "" true "$TASK_INPUT" "$WORK/calls-adopted")"
CAPPED_PROBE="$(probe_wait "" false "$TASK_INPUT" "$WORK/calls-capped" 5)"
if [ -n "$WAIT_FN" ] && [ "$UNBOUND_PROBE" = "wait note line" ] && grep -qx run "$WORK/calls-unbound" \
  && [ "$BOUND_PROBE" = "kept" ] && [ ! -e "$WORK/calls-bound" ] \
  && [ "$ADOPTED_PROBE" = "kept" ] && [ ! -e "$WORK/calls-adopted" ] \
  && [ "$CAPPED_PROBE" = "kept" ] && grep -qx counter "$WORK/calls-capped" && ! grep -qx run "$WORK/calls-capped"; then
  check "B17 the shipped function refuses an Autopilot-bound chain and an adopting Stop before any call, and a chain at its Stop cap before the module runs" PASS
else
  check "B17 bound, adopting or capped chain (unbound=$UNBOUND_PROBE bound=$BOUND_PROBE adopted=$ADOPTED_PROBE capped=$CAPPED_PROBE)" FAIL
fi

QUIET_OK=true
for input in '{"hook_event_name":"Stop"}' '{"background_tasks":[]}' '{"background_tasks": []}' '{"last_assistant_message":"ZENSU-AWAIT: run1"}'; do
  rm -f "$WORK/calls-quiet"
  [ "$(probe_wait "" false "$input" "$WORK/calls-quiet")" = "kept" ] || QUIET_OK=false
  [ ! -e "$WORK/calls-quiet" ] || QUIET_OK=false
done
if [ "$QUIET_OK" = "true" ]; then
  check "B18 a Stop input without a background task returns before any config read, probe or child process" PASS
else
  check "B18 quiet path" FAIL
fi

TWO_LINE_OK=true
for answer in 'wait release=1 max=5 tasks=1 ids=run1' 'hint tasks=1 ids=run1' 'nowait reason=hinted tasks=1' $'garbage\ntext'; do
  RESULT="$(WAIT_FN="$WAIT_FN" PLUGIN_DIR="$PLUGIN_DIR" PROBE_DATA="$WORK/probe-data" ANSWER="$answer" bash -c '
    eval "$WAIT_FN"
    INPUT="{\"background_tasks\":[{\"id\":\"run1\",\"type\":\"shell\",\"status\":\"running\"}]}"
    OUTER_PRESENT=false; DEFERRED_ADOPTED=false; INNER_BOUND_RUN=""
    SESSION_ID="scv1_0000000000000000000000000000000000000000000000000000000000000000"
    PROJECT_ROOT="$PROBE_DATA"; CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"; CLAUDE_PLUGIN_DATA="$PROBE_DATA"
    CAP=5; STATE_FILE="$PROBE_DATA/tdd-phase.json"
    tdd_get_counter() { printf "0\n"; }
    zensu_session_key_canonical() { return 0; }
    zensu_hook_enabled() { return 0; }
    reviewer_spawn_denied() { return 1; }
    zensu_pending_review_file() { printf "%s\n" "$PROBE_DATA/pending-review.json"; }
    zensu_pending_review_claim_file() { printf "%s\n" "$1.claim"; }
    zensu_msys_env_exclusions() { printf "\n"; }
    bash() { printf "%s\n" "$PROBE_DATA"; }
    zensu_run_bounded() { printf "%s\n" "$ANSWER"; }
    if stop_background_wait; then printf "released\n"; else printf "kept\n"; fi
  ')"
  [ "$RESULT" = "kept" ] || TWO_LINE_OK=false
done
if [ "$TWO_LINE_OK" = "true" ]; then
  check "B19 a verdict without its text line, a nowait verdict and an unknown answer never release or hint" PASS
else
  check "B19 malformed verdicts" FAIL
fi

CAP_PROJECT="$WORK/cap-project"
mkdir -p "$CAP_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$CAP_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
arm bw-cap || { check "B20 arm" FAIL; finish; exit 1; }
CAP_KEY="$ARMED_KEY"
CAP_DATA="$ARMED_DATA"
for _ in 1 2 3 4 5; do stop_payload bw-cap | bash "$STOP" >/dev/null 2>&1; done
CAP_AT="$(stop_count "$CAP_KEY")"
OUT="$(stop_payload bw-cap "$RUN_TASKS" | bash "$STOP" 2>"$WORK/cap.err")"
CAP_UNNAMED="$(printf '%s' "$OUT" | decision)"
OUT="$(stop_payload bw-cap "$RUN_TASKS" "$AWAIT_RUN" | bash "$STOP" 2>>"$WORK/cap.err")"
if [ "$CAP_AT" = "5" ] && [ "$CAP_UNNAMED" = "allow" ] && [ "$(printf '%s' "$OUT" | decision)" = "allow" ] \
  && [ "$(grep -cF 'did not converge after 5 blocked Stops' "$WORK/cap.err")" = "2" ] \
  && ! grep -qF 'releasing this Stop while the background' "$WORK/cap.err" \
  && [ ! -e "$CAP_DATA/stop-background-wait/v1/$CAP_KEY.json" ]; then
  check "B20 a chain at its Stop cap is released by the cap path with its disclosure, never hinted or released by the wait" PASS
else
  check "B20 capped chain (count=$CAP_AT unnamed=$CAP_UNNAMED out=$OUT err=$(cat "$WORK/cap.err"))" FAIL
fi

arm bw-hints || { check "B21 arm" FAIL; finish; exit 1; }
HINTS_KEY="$ARMED_KEY"
HINTS_BEFORE="$(stop_count "$HINTS_KEY")"
HINT_KINDS=""
for id in h1 h2 h3; do
  OUT="$(stop_payload bw-hints "[{\"id\":\"$id\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"step $id\"}]" | bash "$STOP" 2>/dev/null)"
  if printf '%s' "$OUT" | reason | grep -qF "$HINT_LEAD"; then HINT_KINDS="$HINT_KINDS hint"; else HINT_KINDS="$HINT_KINDS other"; fi
done
HINTS_MID="$(stop_count "$HINTS_KEY")"
OUT="$(stop_payload bw-hints '[{"id":"h4","type":"shell","status":"running","description":"step h4"}]' | bash "$STOP" 2>/dev/null)"
if [ "$HINT_KINDS" = " hint hint hint" ] && [ "$HINTS_MID" = "$HINTS_BEFORE" ] \
  && printf '%s' "$OUT" | reason | grep -qF "$RESUME" && ! printf '%s' "$OUT" | reason | grep -qF "$HINT_LEAD" \
  && [ "$(stop_count "$HINTS_KEY")" = "$((HINTS_MID + 1))" ]; then
  check "B21 a chain generation gets at most three uncharged hints; a fourth new task gets the ordinary directive, charged" PASS
else
  check "B21 hint bound (kinds=$HINT_KINDS before=$HINTS_BEFORE mid=$HINTS_MID count=$(stop_count "$HINTS_KEY"))" FAIL
fi

unit_check_done "B0z every unit file the registry gives this suite was graded"
finish
