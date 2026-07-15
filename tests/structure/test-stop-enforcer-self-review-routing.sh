#!/bin/bash
# Pins the stop-chain-enforcer.sh two-stage routing:
#   implComplete && !codeReviewDone           -> block, force Agent zensu:code-reviewer (unchanged)
#   implComplete && codeReviewDone && !chainDone -> block, force Skill zensu:self-review (NEW)
#   chainDone                                 -> allow (self-review owns the terminus)
#   selfReview later disabled + codeReviewDone -> still force the frozen self-review handoff
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$TDD_STATE_DIR/no-such-config.json"   # force defaults -> selfReview enabled
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

stop_run() {
  local payload="$1" cfg="${2:-}"
  if [ -n "$cfg" ]; then
    printf '%s' "$payload" | ZENSU_CONFIG="$cfg" bash "$STOP" 2>/dev/null
  else
    printf '%s' "$payload" | bash "$STOP" 2>/dev/null
  fi
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason()   { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }

# --- Scenario 1: codeReviewDone=false -> force code-reviewer (unchanged) ---
SID1="stop-cr-pending"
bash "$LOG" --tdd-begin --session "$SID1" >/dev/null
bash "$LOG" --tdd-complete --session "$SID1" >/dev/null
OUT1="$(stop_run '{"session_id":"'"$SID1"'"}')"
[ "$(printf '%s' "$OUT1" | decision)" = "block" ] && check "T1 implComplete + !codeReviewDone -> block" PASS || check "T1 block" FAIL
printf '%s' "$OUT1" | reason | grep -q "zensu:code-reviewer" && check "T2 !codeReviewDone reason forces zensu:code-reviewer" PASS || check "T2 reason code-reviewer" FAIL
if printf '%s' "$OUT1" | reason | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! printf '%s' "$OUT1" | reason | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "T2a code-review reason embeds the concrete session plugin root" PASS
else
  check "T2a code-review reason embeds the concrete session plugin root" FAIL
fi

# --- Scenario 2: codeReviewDone=true -> force self-review (NEW) ---
SID2="stop-cr-done"
bash "$LOG" --tdd-begin --session "$SID2" >/dev/null
bash "$LOG" --tdd-complete --session "$SID2" >/dev/null
bash "$LOG" --code-review-done --session "$SID2" >/dev/null
OUT2="$(stop_run '{"session_id":"'"$SID2"'"}')"
[ "$(printf '%s' "$OUT2" | decision)" = "block" ] && check "T3 codeReviewDone + !chainDone -> block" PASS || check "T3 block" FAIL
printf '%s' "$OUT2" | reason | grep -q "skill='zensu:self-review'" && check "T4 codeReviewDone reason forces skill='zensu:self-review'" PASS || check "T4 reason self-review" FAIL
if printf '%s' "$OUT2" | reason | grep -q "zensu:code-reviewer"; then
  check "T5 self-review reason must NOT name zensu:code-reviewer" FAIL
else
  check "T5 self-review reason must NOT name zensu:code-reviewer" PASS
fi
if printf '%s' "$OUT2" | reason | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! printf '%s' "$OUT2" | reason | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "T5a self-review reason embeds the concrete session plugin root" PASS
else
  check "T5a self-review reason embeds the concrete session plugin root" FAIL
fi

# A root with shell syntax in its filename must survive JSON serialization and
# be emitted as one runnable, inert shell token in the stop reason.
SPECIAL_BASE="$(mktemp -d -t zensu-stop-root-XXXXXX)"
SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch STOP_PWNED) `touch STOP_TICKED`;touch STOP_SEMI; apostrophe'"'"'value quote"back\slash'
mkdir -p "$SPECIAL_ROOT/hooks" "$SPECIAL_BASE/run"
cp -R "$PLUGIN_DIR/hooks/lib" "$SPECIAL_ROOT/hooks/lib"
cp "$STOP" "$SPECIAL_ROOT/hooks/stop-chain-enforcer.sh"
SPECIAL_LOG="$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
SPECIAL_SID="stop-special-root"
CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --tdd-begin --session "$SPECIAL_SID" >/dev/null
CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --tdd-complete --session "$SPECIAL_SID" >/dev/null
CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --code-review-done --session "$SPECIAL_SID" >/dev/null
SPECIAL_OUT="$(printf '%s' '{"session_id":"'"$SPECIAL_SID"'"}' | CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" \
  bash "$SPECIAL_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
EXPECTED_Q="$(printf '%q' "$SPECIAL_LOG")"
SPECIAL_REASON="$(printf '%s' "$SPECIAL_OUT" | node -e '
  let s=""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      if (j.decision !== "block" || typeof j.reason !== "string") process.exit(2);
      process.stdout.write(j.reason);
    } catch (_) { process.exit(1); }
  });
' 2>/dev/null)"
SPECIAL_PARSE_RC=$?
SPECIAL_BOUND_TICKET="$(CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" \
  --current-review-ticket --session "$SPECIAL_SID" 2>/dev/null)"
SPECIAL_TICKET_Q="$(printf '%q' "$SPECIAL_BOUND_TICKET")"
(
  cd "$SPECIAL_BASE/run" || exit 1
  CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" eval "bash $EXPECTED_Q --chain-done --claimed-review-ticket $SPECIAL_TICKET_Q --session $SPECIAL_SID" >/dev/null 2>&1
)
SPECIAL_EXEC_RC=$?
if [ "$SPECIAL_PARSE_RC" = "0" ] && [ "$SPECIAL_EXEC_RC" = "0" ] \
  && printf '%s' "$SPECIAL_REASON" | grep -qF "bash $EXPECTED_Q --chain-done" \
  && printf '%s' "$SPECIAL_REASON" | grep -qF -- "--claimed-review-ticket $SPECIAL_TICKET_Q" \
  && ! printf '%s' "$SPECIAL_REASON" | grep -qF '${CLAUDE_PLUGIN_ROOT}' \
  && [ ! -e "$SPECIAL_BASE/run/STOP_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_SEMI" ]; then
  check "T5b special-character root stays valid JSON and inert in stop command" PASS
else
  check "T5b special-character root stays valid JSON and inert in stop command" FAIL
fi
if grep -qE 'LOG_HELPER_Q=.*printf.*%q.*CLAUDE_PLUGIN_ROOT.*zensu-log\.sh' "$STOP" \
  && grep -qF 'bash ${LOG_HELPER_Q}' "$STOP"; then
  check "T5c generated stop commands serialize the active root through printf %q" PASS
else
  check "T5c generated stop commands serialize the active root through printf %q" FAIL
fi
rm -rf "$SPECIAL_BASE"

# --- Scenario 3: chainDone -> allow (terminus) ---
SID3="stop-chain-done"
bash "$LOG" --tdd-begin --session "$SID3" >/dev/null
bash "$LOG" --tdd-complete --session "$SID3" >/dev/null
bash "$LOG" --code-review-done --session "$SID3" >/dev/null
bash "$LOG" --chain-done --session "$SID3" >/dev/null
OUT3="$(stop_run '{"session_id":"'"$SID3"'"}')"
[ "$(printf '%s' "$OUT3" | decision)" = "allow" ] && check "T6 chainDone -> allow stop (self-review owns terminus)" PASS || check "T6 allow" FAIL

# --- Scenario 4: persisted handoff wins over a later selfReview=false config ---
SID4="stop-selfreview-off"
OFFCFG="$TDD_STATE_DIR/selfreview-off.json"
printf '{"hooks":{"selfReview":false}}' > "$OFFCFG"
bash "$LOG" --tdd-begin --session "$SID4" >/dev/null
bash "$LOG" --tdd-complete --session "$SID4" >/dev/null
bash "$LOG" --code-review-done --session "$SID4" >/dev/null
OUT4="$(stop_run '{"session_id":"'"$SID4"'"}' "$OFFCFG")"
[ "$(printf '%s' "$OUT4" | decision)" = "block" ] && check "T7 selfReview flip after codeReviewDone -> block" PASS || check "T7 block" FAIL
if printf '%s' "$OUT4" | reason | grep -q "skill='zensu:self-review'" \
  && ! printf '%s' "$OUT4" | reason | grep -q "zensu:code-reviewer"; then
  check "T8 persisted codeReviewDone still forces self-review after config flip" PASS
else
  check "T8 persisted codeReviewDone still forces self-review after config flip" FAIL
fi

# Exercise the real ticket-bound true->false transition: the post-review hook
# consumes the ticket while selfReview is enabled, its instructed close freezes
# codeReviewDone, and a subsequent Stop under selfReview=false must retain that
# exact ticket/terminus instead of asking for an impossible fresh reviewer ticket.
SID5="stop-selfreview-ticket-flip"
bash "$LOG" --tdd-begin --session "$SID5" >/dev/null
bash "$LOG" --tdd-complete --session "$SID5" >/dev/null
TICKET5="$(bash "$LOG" --review-ticket --session "$SID5")"
PAYLOAD5="$(SID="$SID5" TICKET="$TICKET5" node -e '
  process.stdout.write(JSON.stringify({
    session_id: process.env.SID,
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
    }
  }));
')"
printf '%s' "$PAYLOAD5" | bash "$POSTREV" >/dev/null 2>&1
bash "$LOG" --code-review-done --session "$SID5" \
  --claimed-review-ticket "$TICKET5" >/dev/null
OUT5="$(stop_run '{"session_id":"'"$SID5"'"}' "$OFFCFG")"
BOUND5="$(bash "$LOG" --current-review-ticket --session "$SID5" 2>/dev/null)"
bash "$LOG" --review-ticket --session "$SID5" >/dev/null 2>&1
FRESH5_RC=$?
if [ "$(printf '%s' "$OUT5" | decision)" = "block" ] \
  && printf '%s' "$OUT5" | reason | grep -q "skill='zensu:self-review'" \
  && [ "$BOUND5" = "$TICKET5" ] && [ "$FRESH5_RC" -ne 0 ]; then
  check "T9 ticket-bound true-to-false flip preserves the frozen self-review terminus" PASS
else
  check "T9 ticket-bound true-to-false flip preserves the frozen self-review terminus" FAIL
fi

echo "----"
echo "test-stop-enforcer-self-review-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
