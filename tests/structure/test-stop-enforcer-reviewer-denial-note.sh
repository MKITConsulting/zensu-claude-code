#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
PROJ="$(mktemp -d)"
PROJ="$(cd "$PROJ" && pwd -P)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$PROJ"; }
trap cleanup EXIT

stop_run() {
  local payload="$1"
  payload="$(printf '%s' "$payload" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));p.hook_event_name="Stop";process.stdout.write(JSON.stringify(p))')"
  printf '%s' "$payload" | bash "$STOP" 2>/dev/null
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason()   { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }

start_session() {
  local raw_session="$1" project="${2:-$PROJ}" label="${3:-$1}" plugin_root="${4:-$PLUGIN_DIR}"
  project="$(cd "$project" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data/$label"
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$raw_session" "$plugin_root" \
    || exit 1
  [ -n "${ZENSU_SESSION_KEY:-}" ] && [ -n "${ZENSU_PROJECT_ROOT:-}" ] || exit 1
  STARTED_SESSION_KEY="$ZENSU_SESSION_KEY"
  STARTED_PROJECT_ROOT="$ZENSU_PROJECT_ROOT"
}

TRANSCRIPT_DENIED="$STATE_DIR/transcript-denied.jsonl"
cat >"$TRANSCRIPT_DENIED" <<'DENIED_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
DENIED_EOF

# --- Scenario 8: the note must not outlive the chain it describes ------------
SID8_RAW="stop-reviewer-denied-closed"
start_session "$SID8_RAW"
SID8="$STARTED_SESSION_KEY"
SID8_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR8="$SID8_PROJECT/.zensu/state/reviewer-spawn-denied-$SID8.json"
bash "$LOG" --tdd-begin --session "$SID8" >/dev/null
bash "$LOG" --tdd-complete --session "$SID8" >/dev/null
stop_run '{"session_id":"'"$SID8_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED"'"}' >/dev/null
WROTE8="absent"; [ -f "$SIDECAR8" ] && WROTE8="present"
bash "$LOG" --code-review-done --session "$SID8" >/dev/null
bash "$LOG" --chain-done --session "$SID8" >/dev/null
OUT13="$(stop_run '{"session_id":"'"$SID8_RAW"'"}')"
if [ "$WROTE8" = "present" ] \
  && [ "$(printf '%s' "$OUT13" | decision)" = "allow" ] \
  && [ ! -f "$SIDECAR8" ]; then
  check "T23 closing the chain retires the refusal note, so doctor stops reporting it" PASS
else
  check "T23 closing the chain retires the refusal note (wrote=$WROTE8)" FAIL
fi

# --- Scenario 9: the cap release must name the cause too ---------------------
stop_run_err() {
  local payload="$1" errfile="$2" cfg="$3"
  payload="$(printf '%s' "$payload" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));p.hook_event_name="Stop";process.stdout.write(JSON.stringify(p))')"
  printf '%s' "$payload" | ZENSU_CONFIG="$cfg" bash "$STOP" 2>"$errfile" >/dev/null
}
SID9_RAW="stop-reviewer-denied-capped"
start_session "$SID9_RAW"
SID9="$STARTED_SESSION_KEY"
SID9_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR9="$SID9_PROJECT/.zensu/state/reviewer-spawn-denied-$SID9.json"
bash "$LOG" --tdd-begin --session "$SID9" >/dev/null
bash "$LOG" --tdd-complete --session "$SID9" >/dev/null
CAP_ERR="$STATE_DIR/cap-release.err"
CAP_PAYLOAD='{"session_id":"'"$SID9_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED"'"}'
CAP_ROUNDS=1
CAP_CFG="$STATE_DIR/autofix-max-rounds.json"
printf '{"hooks":{"autoFixMaxRounds":%s}}\n' "$CAP_ROUNDS" > "$CAP_CFG"
# CAP is autoFixMaxRounds + 3, and CAP_CFG sets autoFixMaxRounds to the floor
# hooks/lib/zensu-config.sh accepts; the release needs one Stop beyond it.
CAP_EXPECTED=$((CAP_ROUNDS + 3))
CAP_RUNS=0
while [ "$CAP_RUNS" -le "$CAP_EXPECTED" ]; do
  # The last run is the cap release. Retire the note first so the assertion
  # below observes THAT path's write and not one of the ordinary blocks.
  [ "$CAP_RUNS" -eq "$CAP_EXPECTED" ] && rm -f "$SIDECAR9"
  stop_run_err "$CAP_PAYLOAD" "$CAP_ERR" "$CAP_CFG"
  CAP_RUNS=$((CAP_RUNS + 1))
done
if grep -qF 'that chain never stalled inside Zensu' "$CAP_ERR" \
  && grep -qF 'auto-mode-classifier' "$CAP_ERR" \
  && grep -qF 'The remedy is the user' "$CAP_ERR" \
  && [ -f "$SIDECAR9" ]; then
  check "T24 the cap release names the permission layer and writes the note on its own path" PASS
else
  check "T24 the cap release names the permission layer and writes the note on its own path" FAIL
fi

# --- Scenario 10: routing precedence, the pre-plant guard, and the third exit --
SID10_RAW="stop-reviewer-denied-precedence"
start_session "$SID10_RAW"
SID10="$STARTED_SESSION_KEY"
SID10_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR10="$SID10_PROJECT/.zensu/state/reviewer-spawn-denied-$SID10.json"
bash "$LOG" --tdd-begin --session "$SID10" >/dev/null
bash "$LOG" --tdd-complete --session "$SID10" >/dev/null
bash "$LOG" --code-review-done --session "$SID10" >/dev/null
# Pre-planted, because the interesting case is not "does it mint one" but "does
# a note from the refusal EARLIER in this session survive the successful spawn
# that followed it" — the recovery path the whole feature steers the user onto.
plant_converged_note() { mkdir -p "$(dirname "$1")" && printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":1}\n' > "$1"; }
plant_converged_note "$SIDECAR10"
OUT14="$(stop_run '{"session_id":"'"$SID10_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED"'"}')"
REASON14="$(printf '%s' "$OUT14" | reason)"
if printf '%s' "$REASON14" | grep -qF "skill='zensu:self-review'" \
  && ! printf '%s' "$REASON14" | grep -qF 'refused by the HOST permission layer' \
  && [ ! -f "$SIDECAR10" ]; then
  check "T27 a converged chain keeps the self-review directive and retires an earlier refusal note" PASS
else
  check "T27 a converged chain keeps the self-review directive and retires an earlier refusal note" FAIL
fi

# The note write is best-effort by contract: a path it refuses must cost the
# diagnosis, never the block.
SID11_RAW="stop-reviewer-denied-preplant"
start_session "$SID11_RAW"
SID11="$STARTED_SESSION_KEY"
SID11_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR11="$SID11_PROJECT/.zensu/state/reviewer-spawn-denied-$SID11.json"
bash "$LOG" --tdd-begin --session "$SID11" >/dev/null
bash "$LOG" --tdd-complete --session "$SID11" >/dev/null
mkdir -p "$SIDECAR11"
OUT15="$(stop_run '{"session_id":"'"$SID11_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED"'"}')"
REASON15="$(printf '%s' "$OUT15" | reason)"
if [ "$(printf '%s' "$OUT15" | decision)" = "block" ] \
  && printf '%s' "$REASON15" | grep -qF 'refused by the HOST permission layer' \
  && [ -d "$SIDECAR11" ] \
  && [ ! -f "$SIDECAR11.tmp" ]; then
  check "T28 a note path the writer refuses costs the diagnosis, never the block" PASS
else
  check "T28 a note path the writer refuses costs the diagnosis, never the block" FAIL
fi
rmdir "$SIDECAR11" 2>/dev/null || true

# The third clearing exit: a session with no armed chain at all.
SID12_RAW="stop-reviewer-denied-inactive"
start_session "$SID12_RAW"
SID12="$STARTED_SESSION_KEY"
SID12_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR12="$SID12_PROJECT/.zensu/state/reviewer-spawn-denied-$SID12.json"
mkdir -p "$SID12_PROJECT/.zensu/state"
printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":1}\n' > "$SIDECAR12"
stop_run '{"session_id":"'"$SID12_RAW"'"}' >/dev/null
if [ ! -f "$SIDECAR12" ]; then
  check "T29 a Stop with no armed chain retires a leftover note" PASS
else
  check "T29 a Stop with no armed chain retires a leftover note" FAIL
fi

# The reaper, which nothing else here exercises: every note the other scenarios
# plant belongs to a session whose workflow document is present and was written
# seconds ago, so the sweep never fires and its absence would go unnoticed.
# Measured — a debug run of this whole file reaped exactly zero files before this
# check existed. Three planted files, riding the clear the scenario above already
# performs, so it costs no extra Stop.
#
# The LIVE file is the discriminator and the reason this is not a one-sided
# check: a reaper that simply deleted every note it could name would satisfy the
# other two assertions and fail this one.
REAP_DEAD="scv1_$(printf '%063d' 0)c"
REAP_OLD="scv1_$(printf '%063d' 0)d"
REAP_LIVE="scv1_$(printf '%063d' 0)e"
REAP_STATE="$SID12_PROJECT/.zensu/state"
reap_note() {
  printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":%s}\n' \
    "$2" > "$REAP_STATE/reviewer-spawn-denied-$1.json"
}
# Unbound: no workflow document beside it.
reap_note "$REAP_DEAD" 1
# Bound but far past the TTL — the arm that answers the "a dead session's note
# outlives everything able to remove it" finding.
reap_note "$REAP_OLD" 1
: > "$REAP_STATE/tdd-phase-$REAP_OLD.json"
# Bound and current: must survive, and belongs to a DIFFERENT session than the
# one Stopping, so this also pins that the sweep does not eat live neighbours.
reap_note "$REAP_LIVE" "$(node -e 'process.stdout.write(String(Date.now()))')"
: > "$REAP_STATE/tdd-phase-$REAP_LIVE.json"
stop_run '{"session_id":"'"$SID12_RAW"'"}' >/dev/null
REAP_RESULT=""
[ -f "$REAP_STATE/reviewer-spawn-denied-$REAP_DEAD.json" ] && REAP_RESULT="$REAP_RESULT unbound-survived"
[ -f "$REAP_STATE/reviewer-spawn-denied-$REAP_OLD.json" ] && REAP_RESULT="$REAP_RESULT expired-survived"
[ -f "$REAP_STATE/reviewer-spawn-denied-$REAP_LIVE.json" ] || REAP_RESULT="$REAP_RESULT live-reaped"
if [ -z "$REAP_RESULT" ]; then
  check "T35 the reaper removes an unbound and an expired note and spares a live one" PASS
else
  check "T35 reaper sweep (unexpected:$REAP_RESULT)" FAIL
fi
rm -f "$REAP_STATE/reviewer-spawn-denied-$REAP_LIVE.json" \
  "$REAP_STATE/tdd-phase-$REAP_OLD.json" "$REAP_STATE/tdd-phase-$REAP_LIVE.json"

# The remaining clearing exit, and the one no scenario reached: a chain that was
# armed but whose implementation never completed. Every other session in this
# file runs --tdd-begin AND --tdd-complete, so the `implComplete != true` branch
# was unreachable from here — while being exactly the state a user leaves behind
# by abandoning a run after a refusal, and the state in which nothing else can
# ever remove the note.
SID15_RAW="stop-reviewer-denied-impl-incomplete"
start_session "$SID15_RAW"
SID15="$STARTED_SESSION_KEY"
SID15_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR15="$SID15_PROJECT/.zensu/state/reviewer-spawn-denied-$SID15.json"
bash "$LOG" --tdd-begin --session "$SID15" >/dev/null
mkdir -p "$SID15_PROJECT/.zensu/state"
printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":1}\n' > "$SIDECAR15"
PRE15="absent"; [ -f "$SIDECAR15" ] && PRE15="present"
stop_run '{"session_id":"'"$SID15_RAW"'"}' >/dev/null
if [ "$PRE15" = "present" ] && [ ! -f "$SIDECAR15" ]; then
  check "T32 an armed chain with implementation unfinished retires a leftover note" PASS
else
  check "T32 an armed chain with implementation unfinished retires a leftover note (pre=$PRE15)" FAIL
fi

# The cap path consults the probe ABOVE the codeReviewDone split, so it needs its
# own guard: a reviewer re-spawned against the self-review directive and refused
# there must not leave doctor reporting "no review ran" for a converged chain.
SID13_RAW="stop-reviewer-denied-capped-converged"
start_session "$SID13_RAW"
SID13="$STARTED_SESSION_KEY"
SID13_PROJECT="$STARTED_PROJECT_ROOT"
SIDECAR13="$SID13_PROJECT/.zensu/state/reviewer-spawn-denied-$SID13.json"
bash "$LOG" --tdd-begin --session "$SID13" >/dev/null
bash "$LOG" --tdd-complete --session "$SID13" >/dev/null
bash "$LOG" --code-review-done --session "$SID13" >/dev/null
CAP13_ERR="$STATE_DIR/cap-release-converged.err"
CAP13_PAYLOAD='{"session_id":"'"$SID13_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED"'"}'
CAP13_RUNS=0
while [ "$CAP13_RUNS" -le "$CAP_EXPECTED" ]; do
  stop_run_err "$CAP13_PAYLOAD" "$CAP13_ERR" "$CAP_CFG"
  CAP13_RUNS=$((CAP13_RUNS + 1))
done
# The positive control matters more than the two negatives: without it, a loop
# that never reached the cap would satisfy both and pin nothing.
if grep -qF 'terminal self-review did not converge after' "$CAP13_ERR" \
  && [ ! -f "$SIDECAR13" ] \
  && ! grep -qF 'that chain never stalled inside Zensu' "$CAP13_ERR"; then
  check "T30 a converged chain mints no refusal note even on the cap path" PASS
else
  check "T30 a converged chain mints no refusal note even on the cap path" FAIL
fi

# Two retire sites the routing scenarios cannot reach: both inner-guard escapes.
plant_note() { mkdir -p "$(dirname "$1")" && printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":1}\n' > "$1"; }
SID14_RAW="stop-reviewer-denied-chain-off"
start_session "$SID14_RAW"
SID14="$STARTED_SESSION_KEY"
SIDECAR14="$STARTED_PROJECT_ROOT/.zensu/state/reviewer-spawn-denied-$SID14.json"
bash "$LOG" --tdd-begin --session "$SID14" >/dev/null
bash "$LOG" --tdd-complete --session "$SID14" >/dev/null
plant_note "$SIDECAR14"
ESCAPE_PAYLOAD='{"session_id":"'"$SID14_RAW"'","hook_event_name":"Stop"}'
printf '%s' "$ESCAPE_PAYLOAD" | ZENSU_CHAIN=off bash "$STOP" >/dev/null 2>&1
CHAIN_OFF_CLEARED="no"; [ ! -f "$SIDECAR14" ] && CHAIN_OFF_CLEARED="yes"
plant_note "$SIDECAR14"
ESCAPE_CFG="$STATE_DIR/chain-enforcer-off.json"
printf '{"hooks":{"chainEnforcer":false}}\n' > "$ESCAPE_CFG"
printf '%s' "$ESCAPE_PAYLOAD" | ZENSU_CONFIG="$ESCAPE_CFG" bash "$STOP" >/dev/null 2>&1
CFG_OFF_CLEARED="no"; [ ! -f "$SIDECAR14" ] && CFG_OFF_CLEARED="yes"
if [ "$CHAIN_OFF_CLEARED" = "yes" ] && [ "$CFG_OFF_CLEARED" = "yes" ]; then
  check "T31 both inner-guard escapes retire a leftover refusal note" PASS
else
  check "T31 both inner-guard escapes retire a leftover note (ZENSU_CHAIN=$CHAIN_OFF_CLEARED, chainEnforcer=$CFG_OFF_CLEARED)" FAIL
fi

# The hook writes the note and the doctor renderer reads it; each side is
# otherwise pinned only against a hand-authored filename.
# See the same guard in tests/structure/test-doctor.sh: the doctor renderer
# reads HOME for the user-scoped config AND for the reviewer-spawn permission
# check, so an unsandboxed run reads the developer's own settings.
DOCTOR_HOME="$STATE_DIR/doctor-home"
mkdir -p "$DOCTOR_HOME"
DOC_OUT="$(ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$SID9_PROJECT" \
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' \
  ZDOC_FORGE_STATE='' ZDOC_PLAYWRIGHT=absent \
  HOME="$DOCTOR_HOME" node "$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js" 2>&1)"
case "$DOC_OUT" in
  *'host permission layer refused the zensu:code-reviewer spawn (auto-mode-classifier'*)
    check "T25 /zensu:doctor renders the note the hook itself wrote" PASS ;;
  *) check "T25 /zensu:doctor renders the note the hook itself wrote (got: $DOC_OUT)" FAIL ;;
esac

echo "----"
echo "test-stop-enforcer-reviewer-denial-note: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
