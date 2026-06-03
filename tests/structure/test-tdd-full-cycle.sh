#!/bin/bash
# Full /zensu:tdd lifecycle — hermetic end-to-end walk (no live claude, no API).
#
# Drives ONE session through the COMPLETE cycle via the real hooks/libs in the
# real order, asserting the phase-gate, witness, post-review routing and Stop-hook
# at EVERY transition — the depth complement to test-smoke-main-thread-chain.sh
# (which proves activation breadth but stops at IMPL).
#
# Walk:
#   plan approved -> --tdd-begin
#   S1: RED_WRITE -> RED_RUN -> RED_FAIL -> IMPL -> GREEN_RUN -> GREEN_PASS
#   S2: RED_WRITE -> RED_FAIL -> IMPL -> GREEN_PASS   (multi-step progression)
#   REFACTOR
#   witness a command mid-cycle
#   --tdd-complete -> Stop BLOCK (force code-reviewer)
#   post-review (code-reviewer) routes in-thread, increments rounds
#   --code-review-done -> Stop BLOCK (force self-review)
#   --chain-done -> Stop ALLOW
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
GATE="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
WITNESS="$PLUGIN_DIR/hooks/post-bash-witness.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
PLANHOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# --- hermetic environment (no CLAUDE_AGENT_TYPE: main-thread chain-state only) --
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$PROJ/state"
export ZENSU_CONFIG="$TDD_STATE_DIR/no-such-config.json"   # force all defaults (selfReview on)
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

SID="full-cycle"
SF="$TDD_STATE_DIR/tdd-phase-${SID}.json"

PROD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'"$SID"'"}'
TEST='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"'"$SID"'"}'

gate() {  # echoes allow|deny for a payload
  printf '%s' "$1" | bash "$GATE" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{const j=JSON.parse(s);console.log(j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision==="deny"?"deny":"allow")}
      catch(_){console.log("allow")}});'
}
stop_dec() { printf '%s' '{"session_id":"'"$SID"'"}' | bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
stop_reason() { printf '%s' '{"session_id":"'"$SID"'"}' | bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }
phase_step() { bash "$LOG" --phase "$1" --step "$2" --session "$SID" >/dev/null 2>&1; }

echo "== Phase 0: plan approval -> begin =="
[ "$(gate "$PROD")" = "allow" ] && check "0a pre-begin: gate is a pass-through (no chain-state)" PASS || check "0a pre-begin pass-through" FAIL
grep -qF "skill='zensu:tdd'" "$PLANHOOK" && check "0b plan-approved hook routes to /zensu:tdd skill" PASS || check "0b plan-approved wiring" FAIL
bash "$LOG" --tdd-begin --session "$SID" >/dev/null
[ "$(gate "$PROD")" = "deny" ] && check "0c after --tdd-begin: active + UNINITIALIZED -> prod deny" PASS || check "0c begin activates gate" FAIL

echo "== Step S1: RED -> GREEN =="
phase_step RED_WRITE S1
[ "$(gate "$TEST")" = "allow" ] && check "S1a RED_WRITE: test edit allow" PASS || check "S1a RED_WRITE test allow" FAIL
[ "$(gate "$PROD")" = "allow" ] && check "S1b RED_WRITE: prod edit allow (scaffolding ok)" PASS || check "S1b RED_WRITE prod allow" FAIL
phase_step RED_RUN S1
[ "$(gate "$PROD")" = "deny" ] && check "S1c RED_RUN: no edits during test run (prod deny)" PASS || check "S1c RED_RUN prod deny" FAIL
phase_step RED_FAIL S1
[ "$(gate "$TEST")" = "allow" ] && check "S1d RED_FAIL: test edit allow" PASS || check "S1d RED_FAIL test allow" FAIL
[ "$(gate "$PROD")" = "deny" ] && check "S1e RED_FAIL: prod edit deny (must IMPL first)" PASS || check "S1e RED_FAIL prod deny" FAIL
phase_step IMPL S1
[ "$(gate "$PROD")" = "allow" ] && check "S1f IMPL after RED_FAIL(S1): prod edit allow" PASS || check "S1f IMPL prod allow" FAIL
phase_step GREEN_RUN S1
[ "$(gate "$PROD")" = "deny" ] && check "S1g GREEN_RUN: no edits during test run (prod deny)" PASS || check "S1g GREEN_RUN prod deny" FAIL
phase_step GREEN_PASS S1
[ "$(gate "$PROD")" = "deny" ] && check "S1h GREEN_PASS: prod deny (no drift without new RED)" PASS || check "S1h GREEN_PASS prod deny" FAIL
[ "$(gate "$TEST")" = "allow" ] && check "S1i GREEN_PASS: test edit allow (write next RED)" PASS || check "S1i GREEN_PASS test allow" FAIL

echo "== Step S2: progression (RED_FAIL belongs to current step) =="
phase_step RED_WRITE S2
[ "$(gate "$TEST")" = "allow" ] && check "S2a S2 RED_WRITE: test edit allow" PASS || check "S2a S2 RED_WRITE test allow" FAIL
phase_step RED_FAIL S2
[ "$(gate "$PROD")" = "deny" ] && check "S2b S2 RED_FAIL: prod deny" PASS || check "S2b S2 RED_FAIL prod deny" FAIL
phase_step IMPL S2
[ "$(gate "$PROD")" = "allow" ] && check "S2c S2 IMPL after RED_FAIL(S2): prod allow" PASS || check "S2c S2 IMPL prod allow" FAIL
phase_step GREEN_PASS S2

echo "== REFACTOR =="
phase_step REFACTOR S2
[ "$(gate "$PROD")" = "allow" ] && check "R1 REFACTOR: prod edit allow" PASS || check "R1 REFACTOR prod allow" FAIL
[ "$(gate "$TEST")" = "allow" ] && check "R2 REFACTOR: test edit allow" PASS || check "R2 REFACTOR test allow" FAIL

echo "== Witness mid-cycle (active session) =="
echo '{"tool_input":{"command":"npm test"},"tool_response":{"exit_code":0,"stdout":"ok"},"session_id":"'"$SID"'"}' | bash "$WITNESS" >/dev/null 2>&1
WLOG="$PROJ/.zensu/logs/witness-${SID}.log"
W1_LINE="$(grep -F 'cmd="npm test"' "$WLOG" 2>/dev/null | head -n1)"
{ [ -f "$WLOG" ] && printf '%s' "$W1_LINE" | grep -qF 'cmd="npm test"' && printf '%s' "$W1_LINE" | grep -qF 'tail="ok"'; } \
  && check "W1 active session records witness line with cmd= + tail=" PASS || check "W1 witness line (tail) got='${W1_LINE}'" FAIL

# W1b: production-shaped tool_response (NO exit_code, as the real Claude Code Bash payload) ->
# exit=? but tail= still captured from real stdout. The reality the exit_code mocks can't show.
echo '{"tool_input":{"command":"node --test"},"tool_response":{"stdout":"pass 1","stderr":"","interrupted":false,"isImage":false},"session_id":"'"$SID"'"}' | bash "$WITNESS" >/dev/null 2>&1
W1B_LINE="$(grep -F 'cmd="node --test"' "$WLOG" 2>/dev/null | head -n1)"
{ printf '%s' "$W1B_LINE" | grep -qF 'exit=?' && printf '%s' "$W1B_LINE" | grep -qF 'tail="' && printf '%s' "$W1B_LINE" | grep -qF 'pass 1'; } \
  && check "W1b production payload (no exit_code) -> exit=? + tail= captured" PASS || check "W1b reality-shape tail got='${W1B_LINE}'" FAIL

echo "== Terminus: implComplete -> review -> self-review -> done =="
# Mid-TDD (not yet complete): Stop must allow.
[ "$(stop_dec)" = "allow" ] && check "T0 mid-cycle (!implComplete): Stop allows" PASS || check "T0 mid-cycle allow" FAIL
bash "$LOG" --tdd-complete --session "$SID" >/dev/null
[ "$(stop_dec)" = "block" ] && check "T1 implComplete + !codeReviewDone: Stop BLOCKS" PASS || check "T1 terminus block" FAIL
case "$(stop_reason)" in *"zensu:code-reviewer"*) check "T2 block reason forces zensu:code-reviewer" PASS ;; *) check "T2 reason code-reviewer" FAIL ;; esac
# code-reviewer Agent completes -> post-review routes in-thread + counts a round
CTX="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"'"$SID"'"}' | bash "$POSTREV" 2>/dev/null | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")}})')"
echo "$CTX" | grep -q "/zensu:tdd" && check "T3 post-review routes fixes in-thread (/zensu:tdd)" PASS || check "T3 in-thread routing" FAIL
RCOUNT="$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).count)}catch(_){console.log("?")}' "$PROJ/state/rounds-${SID}.json")"
[ "$RCOUNT" = "1" ] && check "T4 round counter increments (1)" PASS || check "T4 counter=1 (got $RCOUNT)" FAIL
# reviewer PASS -> code-review chain converges
bash "$LOG" --code-review-done --session "$SID" >/dev/null
[ "$(stop_dec)" = "block" ] && check "T5 codeReviewDone + !chainDone: Stop still BLOCKS" PASS || check "T5 pre-self-review block" FAIL
case "$(stop_reason)" in *"zensu:self-review"*) check "T6 block reason now forces skill='zensu:self-review'" PASS ;; *) check "T6 reason self-review" FAIL ;; esac
# self-review owns the terminus
bash "$LOG" --chain-done --session "$SID" >/dev/null
[ "$(stop_dec)" = "allow" ] && check "T7 chainDone: Stop ALLOWS (cycle complete)" PASS || check "T7 terminus allow" FAIL

echo "----"
echo "test-tdd-full-cycle: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
