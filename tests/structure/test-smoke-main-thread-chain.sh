#!/bin/bash
# Funktionsnachweis (hermetic smoke test) for the 0.4.0 main-thread TDD migration.
#
# Pure bash, no live `claude`, no API key. CRUCIALLY it NEVER sets
# CLAUDE_AGENT_TYPE — proving that the phase-gate, witness, and Stop-hook all
# activate on the per-session chain-state `active` flag in the MAIN thread, not
# on the retired CLAUDE_AGENT_TYPE=zensu:tdd-manager subagent scoping.
#
# Asserts the whole new state machine end-to-end:
#   1. gate activation via chain-state
#   2. witness activation via chain-state
#   3. Stop-hook block/allow matrix
#   4. post-review in-thread routing + max-round chainDone
#   5. hooks.json + plan-approved wiring
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
GATE="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
WITNESS="$PLUGIN_DIR/hooks/post-bash-witness.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
PLANHOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# --- hermetic environment -------------------------------------------------
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$TDD_STATE_DIR/strict-config.json"   # tddImplementation:true (strict gate) + all other defaults
printf '%s' '{"hooks":{"tddImplementation":true}}' > "$ZENSU_CONFIG"
unset CLAUDE_AGENT_TYPE 2>/dev/null || true   # the whole point: no subagent scoping
unset ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

SID="smoke-chain"
SF="$TDD_STATE_DIR/tdd-phase-${SID}.json"

# --- helpers --------------------------------------------------------------
gate_decision() {
  # echoes "deny" or "allow"
  printf '%s' "$1" | bash "$GATE" 2>/dev/null | node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{ s=s.trim();
      if(!s){console.log("allow");return;}
      try{const j=JSON.parse(s);console.log(j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision==="deny"?"deny":"allow");}
      catch(_){console.log("allow");}
    });'
}
stop_decision() {
  # arg1=payload ; optional arg2=env assignment (e.g. ZENSU_CHAIN=off)
  local payload="$1" envk="${2:-}"
  printf '%s' "$payload" | env $envk bash "$STOP" 2>/dev/null | node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{ s=s.trim();
      if(!s){console.log("allow");return;}
      try{const j=JSON.parse(s);console.log(j.decision==="block"?"block":"allow");}
      catch(_){console.log("allow");}
    });'
}
flag() { node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(j[process.argv[2]]===true?"true":"false")}catch(_){console.log("false")}' "$SF" "$1"; }
postrev_ctx() {
  local ticket
  ticket="$(bash "$LOG" --review-ticket --session "$SID" 2>/dev/null)" || return 1
  SID_VALUE="$SID" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID_VALUE
    }));
  ' \
    | bash "$POSTREV" 2>/dev/null | node -e '
      let s=""; process.stdin.on("data",c=>s+=c);
      process.stdin.on("end",()=>{ try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")} });'
}

echo "== 1. Gate activation via chain-state (no CLAUDE_AGENT_TYPE) =="
P_PROD='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'"$SID"'"}'
P_TEST='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"'"$SID"'"}'

[ "$(gate_decision "$P_PROD")" = "allow" ] && check "1a no chain-state -> pass-through (not gated)" PASS || check "1a no chain-state -> pass-through" FAIL

bash "$LOG" --tdd-begin --session "$SID" >/dev/null
[ "$(gate_decision "$P_PROD")" = "deny" ] && check "1b active + UNINITIALIZED + prod edit -> deny" PASS || check "1b active+UNINITIALIZED prod -> deny" FAIL

bash "$LOG" --phase RED_WRITE --step S1 --session "$SID" >/dev/null
[ "$(gate_decision "$P_TEST")" = "allow" ] && check "1c RED_WRITE + test edit -> allow" PASS || check "1c RED_WRITE test -> allow" FAIL

bash "$LOG" --phase RED_RUN  --step S1 --session "$SID" >/dev/null
bash "$LOG" --phase RED_FAIL --step S1 --session "$SID" >/dev/null
[ "$(gate_decision "$P_PROD")" = "deny" ] && check "1d RED_FAIL + prod edit -> deny" PASS || check "1d RED_FAIL prod -> deny" FAIL

bash "$LOG" --phase IMPL --step S1 --session "$SID" >/dev/null
[ "$(gate_decision "$P_PROD")" = "allow" ] && check "1e IMPL (after RED_FAIL for step) + prod edit -> allow" PASS || check "1e IMPL prod -> allow" FAIL

echo "== 2. Witness activation via chain-state =="
echo '{"tool_input":{"command":"npm test"},"tool_response":{"exit_code":0,"stdout":"ok"},"session_id":"'"$SID"'"}' | bash "$WITNESS"
WLOG="$PROJ/.zensu/logs/witness-${SID}.log"
{ [ -f "$WLOG" ] && grep -qF 'cmd="npm test"' "$WLOG"; } && check "2a active session records witness line" PASS || check "2a active witness line" FAIL

SID_INACTIVE="smoke-inactive"
echo '{"tool_input":{"command":"echo hi"},"tool_response":{"exit_code":0,"stdout":"hi"},"session_id":"'"$SID_INACTIVE"'"}' | bash "$WITNESS"
[ ! -f "$PROJ/.zensu/logs/witness-${SID_INACTIVE}.log" ] && check "2b inactive session writes NO witness" PASS || check "2b inactive witness skipped" FAIL

echo "== 3. Stop-hook block/allow matrix =="
SID_S="smoke-stop"; export SF_BACKUP="$SF"; SF="$TDD_STATE_DIR/tdd-phase-${SID_S}.json"
P_STOP='{"session_id":"'"$SID_S"'"}'
[ "$(stop_decision "$P_STOP")" = "allow" ] && check "3a no chain-state -> allow stop" PASS || check "3a no chain-state allow" FAIL
bash "$LOG" --tdd-begin --session "$SID_S" >/dev/null
[ "$(stop_decision "$P_STOP")" = "allow" ] && check "3b active + !implComplete -> allow stop (mid-TDD)" PASS || check "3b mid-TDD allow" FAIL
bash "$LOG" --tdd-complete --session "$SID_S" >/dev/null
[ "$(stop_decision "$P_STOP")" = "block" ] && check "3c implComplete + !chainDone -> BLOCK stop (force review)" PASS || check "3c block" FAIL
[ "$(stop_decision "$P_STOP" "ZENSU_CHAIN=off")" = "allow" ] && check "3d ZENSU_CHAIN=off escape -> allow stop" PASS || check "3d ZENSU_CHAIN=off allow" FAIL
bash "$LOG" --chain-done --session "$SID_S" >/dev/null
[ "$(stop_decision "$P_STOP")" = "allow" ] && check "3e chainDone -> allow stop" PASS || check "3e chainDone allow" FAIL
SF="$SF_BACKUP"

echo "== 4. post-review routing (in-thread) + max-round chainDone =="
SID_R="smoke-review"; SF="$TDD_STATE_DIR/tdd-phase-${SID_R}.json"
postrev_ctx() {
  local ticket
  ticket="$(bash "$LOG" --review-ticket --session "$SID_R" 2>/dev/null)" || return 1
  SID_VALUE="$SID_R" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID_VALUE
    }));
  ' \
    | bash "$POSTREV" 2>/dev/null | node -e '
      let s=""; process.stdin.on("data",c=>s+=c);
      process.stdin.on("end",()=>{ try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")} });'
}
bash "$LOG" --tdd-begin --session "$SID_R" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_R" >/dev/null
CTX="$(postrev_ctx)"
echo "$CTX" | grep -q "/zensu:tdd" && check "4a routes findings in-thread (/zensu:tdd)" PASS || check "4a in-thread routing" FAIL
echo "$CTX" | grep -q "subagent_type='zensu:tdd-manager'" && check "4b must NOT spawn tdd-manager subagent" FAIL || check "4b no tdd-manager spawn" PASS
echo "$CTX" | grep -q "subagent_type='zensu:code-reviewer'" && check "4c re-verify via code-reviewer" PASS || check "4c re-verify reviewer" FAIL
RCOUNT="$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).count)}catch(_){console.log("?")}' "$PROJ/.zensu/state/rounds-${SID_R}.json")"
[ "$RCOUNT" = "1" ] && check "4d round counter increments (1)" PASS || check "4d counter=1 (got $RCOUNT)" FAIL
[ "$(flag chainDone)" = "false" ] && check "4e chainDone stays false under max" PASS || check "4e chainDone false" FAIL
# Force max rounds (default 5): reviewRound is authoritative; the public
# rounds JSON is only its derived compatibility view. Seed both to 5 so the
# next ticket completion becomes round 6 and converges.
# (selfReview is on by default; the code-reviewer chain converges via codeReviewDone, and
# /zensu:self-review owns the final --chain-done. Set hooks.selfReview=false to restore the
# legacy chainDone-at-max-rounds behavior.)
printf '{"count":5,"ts":"x"}' > "$PROJ/.zensu/state/rounds-${SID_R}.json"
STATE_FILE="$SF" node -e '
  const fs = require("fs");
  const state = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
  state.reviewRound = 5;
  fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state, null, 2));
'
CTX2="$(postrev_ctx)"
echo "$CTX2" | grep -q "max 5 rounds reached" && check "4f max rounds -> convergence directive" PASS || check "4f convergence msg" FAIL
echo "$CTX2" | grep -qF "skill='zensu:self-review'" && check "4g max rounds -> hands off to terminal self-review" PASS || check "4g self-review handoff" FAIL
[ "$(flag codeReviewDone)" = "true" ] && check "4h max rounds -> hook sets codeReviewDone (code-review chain converged)" PASS || check "4h codeReviewDone true" FAIL
[ "$(flag chainDone)" = "false" ] && check "4i max rounds -> chainDone deferred to self-review (stays false)" PASS || check "4i chainDone deferred" FAIL

echo "== 5. Wiring =="
node -e 'const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(h.hooks.Stop&&h.hooks.Stop[0].hooks.some(x=>/stop-chain-enforcer/.test(x.command))?0:1)' "$HOOKS_JSON" \
  && check "5a hooks.json registers Stop -> stop-chain-enforcer.sh" PASS || check "5a Stop registered" FAIL
node -e 'const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const a=(h.hooks.PostToolUse||[]).find(x=>x.matcher==="Agent");const bad=a&&a.hooks.some(x=>/post-tdd-review-delegate/.test(x.command));process.exit(bad?1:0)' "$HOOKS_JSON" \
  && check "5b Agent matcher no longer references post-tdd-review-delegate.sh" PASS || check "5b post-tdd-review deregistered" FAIL
grep -qF "skill='zensu:tdd'" "$PLANHOOK" && check "5c plan-approved-delegate invokes /zensu:tdd skill" PASS || check "5c plan-approved skill invoke" FAIL
grep -qF "subagent_type='zensu:tdd-manager'" "$PLANHOOK" && check "5d plan-approved must NOT spawn tdd-manager subagent" FAIL || check "5d plan-approved no subagent spawn" PASS

echo "----"
echo "test-smoke-main-thread-chain: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
