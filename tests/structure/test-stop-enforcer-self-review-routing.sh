#!/bin/bash
# Pins the stop-chain-enforcer.sh two-stage routing:
#   implComplete && !codeReviewDone           -> block, force Agent zensu:code-reviewer (unchanged)
#   implComplete && codeReviewDone && !chainDone -> block, force Skill zensu:self-review (NEW)
#   chainDone                                 -> allow (self-review owns the terminus)
#   selfReview later disabled + codeReviewDone -> still force the frozen self-review handoff
#   codeReviewDone + unbindable consumed ticket -> block on the repair branch, never a terminus,
#                                                and a recovery that can actually bind (/zensu:tdd,
#                                                not /zensu:reset-review-limit)
# Every inner-chain block reason also carries the mode-aware state legend
# (`Session state: mode=vanilla|strict, implComplete=..., chainDone=...`). The
# standalone code-reviewer branch teaches its zero-change escape as
# worktree-verified; the bound branch as an audited Autopilot outcome.
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
STATE_DIR="$(mktemp -d)"; export STATE_DIR
PROJ="$(mktemp -d)"
PROJ="$(cd "$PROJ" && pwd -P)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"   # force defaults -> selfReview enabled
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$PROJ"; }
trap cleanup EXIT

stop_run() {
  local payload="$1" cfg="${2:-}"
  payload="$(printf '%s' "$payload" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));p.hook_event_name="Stop";process.stdout.write(JSON.stringify(p))')"
  if [ -n "$cfg" ]; then
    printf '%s' "$payload" | ZENSU_CONFIG="$cfg" bash "$STOP" 2>/dev/null
  else
    printf '%s' "$payload" | bash "$STOP" 2>/dev/null
  fi
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason()   { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }

start_session() {
  local raw_session="$1" project="${2:-$PROJ}" label="${3:-$1}" plugin_root="${4:-$PLUGIN_DIR}"
  project="$(cd "$project" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data/$label"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$raw_session" "$plugin_root" \
    || exit 1
  [ -n "${ZENSU_SESSION_KEY:-}" ] && [ -n "${ZENSU_PROJECT_ROOT:-}" ] || exit 1
  STARTED_SESSION_KEY="$ZENSU_SESSION_KEY"
  STARTED_PROJECT_ROOT="$ZENSU_PROJECT_ROOT"
}

# --- Scenario 1: codeReviewDone=false -> force code-reviewer (unchanged) ---
SID1_RAW="stop-cr-pending"
start_session "$SID1_RAW"
SID1="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$SID1" >/dev/null
bash "$LOG" --tdd-complete --session "$SID1" >/dev/null
OUT1="$(stop_run '{"session_id":"'"$SID1_RAW"'"}')"
[ "$(printf '%s' "$OUT1" | decision)" = "block" ] && check "T1 implComplete + !codeReviewDone -> block" PASS || check "T1 block" FAIL
printf '%s' "$OUT1" | reason | grep -q "zensu:code-reviewer" && check "T2 !codeReviewDone reason forces zensu:code-reviewer" PASS || check "T2 reason code-reviewer" FAIL
if printf '%s' "$OUT1" | reason | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! printf '%s' "$OUT1" | reason | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "T2a code-review reason embeds the concrete session plugin root" PASS
else
  check "T2a code-review reason embeds the concrete session plugin root" FAIL
fi
REASON1="$(printf '%s' "$OUT1" | reason)"
if printf '%s' "$REASON1" | grep -qF 'That terminus verifies the claim before it closes anything' \
  && printf '%s' "$REASON1" | grep -qF 'untracked non-ignored file still reports a changed file' \
  && ! printf '%s' "$REASON1" | grep -qF 'audited Autopilot outcome'; then
  check "T2b standalone zero-change escape is taught as worktree-verified, not audited" PASS
else
  check "T2b standalone zero-change escape is taught as worktree-verified, not audited" FAIL
fi

# --- Scenario 2: codeReviewDone=true -> force self-review (NEW) ---
SID2_RAW="stop-cr-done"
start_session "$SID2_RAW"
SID2="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$SID2" >/dev/null
bash "$LOG" --tdd-complete --session "$SID2" >/dev/null
bash "$LOG" --code-review-done --session "$SID2" >/dev/null
OUT2="$(stop_run '{"session_id":"'"$SID2_RAW"'"}')"
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
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch STOP_PWNED) `touch STOP_TICKED`;touch STOP_SEMI; apostrophe'"'"'value [windows]'
    ;;
  *)
    SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch STOP_PWNED) `touch STOP_TICKED`;touch STOP_SEMI; apostrophe'"'"'value quote"back\slash'
    ;;
esac
mkdir -p "$SPECIAL_ROOT" "$SPECIAL_BASE/run"
SPECIAL_ROOT="$(cd "$SPECIAL_ROOT" && pwd -P)"
for runtime_entry in .claude-plugin .mcp.json hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
  cp -R "$PLUGIN_DIR/$runtime_entry" "$SPECIAL_ROOT/$runtime_entry"
done
mkdir -p "$SPECIAL_ROOT/mcp-runtime"
cp "$PLUGIN_DIR/mcp-runtime/package.json" "$PLUGIN_DIR/mcp-runtime/package-lock.json" \
  "$SPECIAL_ROOT/mcp-runtime/"
SPECIAL_LOG="$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
SPECIAL_SID_RAW="stop-special-root"
SPECIAL_LABEL='special data $(touch STOP_DATA_PWNED) `touch STOP_DATA_TICKED`;touch STOP_DATA_SEMI'
start_session "$SPECIAL_SID_RAW" "$SPECIAL_BASE/run" "$SPECIAL_LABEL" "$SPECIAL_ROOT"
SPECIAL_SID="$STARTED_SESSION_KEY"
SPECIAL_PROJECT="$STARTED_PROJECT_ROOT"
SPECIAL_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
CLAUDE_PROJECT_DIR="$SPECIAL_PROJECT" CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --tdd-begin --session "$SPECIAL_SID" >/dev/null
CLAUDE_PROJECT_DIR="$SPECIAL_PROJECT" CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --tdd-complete --session "$SPECIAL_SID" >/dev/null
CLAUDE_PROJECT_DIR="$SPECIAL_PROJECT" CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --code-review-done --session "$SPECIAL_SID" >/dev/null
SPECIAL_OUT="$(printf '%s' '{"hook_event_name":"Stop","session_id":"'"$SPECIAL_SID_RAW"'"}' | CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" \
  CLAUDE_PROJECT_DIR="$SPECIAL_PROJECT" bash "$SPECIAL_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
EXPECTED_Q="$(printf '%q' "$SPECIAL_LOG")"
EXPECTED_DATA_Q="$(printf '%q' "$SPECIAL_PLUGIN_DATA")"
EXPECTED_PREFIX="CLAUDE_PLUGIN_DATA=$EXPECTED_DATA_Q bash $EXPECTED_Q"
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
SPECIAL_BOUND_TICKET="$(CLAUDE_PROJECT_DIR="$SPECIAL_PROJECT" CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" \
  --current-review-ticket --session "$SPECIAL_SID" 2>/dev/null)"
SPECIAL_TICKET_Q="$(printf '%q' "$SPECIAL_BOUND_TICKET")"
SPECIAL_EXPECTED_COMMAND="$EXPECTED_PREFIX --chain-done --claimed-review-ticket $SPECIAL_TICKET_Q"
SPECIAL_MSYS_EXCL="EXPECTED"
[ -z "${MSYS2_ENV_CONV_EXCL:-}" ] || SPECIAL_MSYS_EXCL="${MSYS2_ENV_CONV_EXCL};${SPECIAL_MSYS_EXCL}"
SPECIAL_EMITTED_COMMAND="$(printf '%s' "$SPECIAL_REASON" | MSYS2_ENV_CONV_EXCL="$SPECIAL_MSYS_EXCL" EXPECTED="$SPECIAL_EXPECTED_COMMAND" node -e '
  const body=require("fs").readFileSync(0,"utf8"),expected=process.env.EXPECTED;
  const at=body.indexOf(expected);if(at<0)process.exit(1);
  process.stdout.write(body.slice(at,at+expected.length));
' 2>/dev/null)"
SPECIAL_COMMAND_RC=$?
(
  cd "$SPECIAL_BASE/run" || exit 1
  unset CLAUDE_PLUGIN_DATA
  export CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT"
  eval "$SPECIAL_EMITTED_COMMAND" >/dev/null 2>&1
)
SPECIAL_EXEC_RC=$?
if [ "$SPECIAL_PARSE_RC" = "0" ] && [ "$SPECIAL_COMMAND_RC" = "0" ] && [ "$SPECIAL_EXEC_RC" = "0" ] \
  && printf '%s' "$SPECIAL_REASON" | grep -qF "$EXPECTED_PREFIX --chain-done" \
  && printf '%s' "$SPECIAL_REASON" | grep -qF -- "--claimed-review-ticket $SPECIAL_TICKET_Q" \
  && ! printf '%s' "$SPECIAL_REASON" | grep -qF '${CLAUDE_PLUGIN_ROOT}' \
  && [ ! -e "$SPECIAL_BASE/run/STOP_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_SEMI" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_DATA_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_DATA_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/STOP_DATA_SEMI" ]; then
  check "T5b exact emitted stop command executes with inert quoted root and plugin data" PASS
else
  check "T5b exact emitted stop command executes with inert quoted root and plugin data" FAIL
fi
if grep -qE 'LOG_HELPER_Q=.*printf.*%q.*CLAUDE_PLUGIN_ROOT.*zensu-log\.sh' "$STOP" \
  && grep -qF 'LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"' "$STOP"; then
  check "T5c generated stop commands quote plugin data and active root" PASS
else
  check "T5c generated stop commands quote plugin data and active root" FAIL
fi
rm -rf "$SPECIAL_BASE"

# --- Scenario 3: chainDone -> allow (terminus) ---
SID3_RAW="stop-chain-done"
start_session "$SID3_RAW"
SID3="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$SID3" >/dev/null
bash "$LOG" --tdd-complete --session "$SID3" >/dev/null
bash "$LOG" --code-review-done --session "$SID3" >/dev/null
bash "$LOG" --chain-done --session "$SID3" >/dev/null
OUT3="$(stop_run '{"session_id":"'"$SID3_RAW"'"}')"
[ "$(printf '%s' "$OUT3" | decision)" = "allow" ] && check "T6 chainDone -> allow stop (self-review owns terminus)" PASS || check "T6 allow" FAIL

# --- Scenario 4: persisted handoff wins over a later selfReview=false config ---
SID4_RAW="stop-selfreview-off"
start_session "$SID4_RAW"
SID4="$STARTED_SESSION_KEY"
OFFCFG="$STATE_DIR/selfreview-off.json"
printf '{"hooks":{"selfReview":false}}' > "$OFFCFG"
bash "$LOG" --tdd-begin --session "$SID4" >/dev/null
bash "$LOG" --tdd-complete --session "$SID4" >/dev/null
bash "$LOG" --code-review-done --session "$SID4" >/dev/null
OUT4="$(stop_run '{"session_id":"'"$SID4_RAW"'"}' "$OFFCFG")"
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
SID5_RAW="stop-selfreview-ticket-flip"
start_session "$SID5_RAW"
SID5="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$SID5" >/dev/null
bash "$LOG" --tdd-complete --session "$SID5" >/dev/null
TICKET5="$(bash "$LOG" --review-ticket --session "$SID5")"
PAYLOAD5="$(SID="$SID5_RAW" TICKET="$TICKET5" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "PostToolUse",
    tool_name: "Agent",
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
OUT5="$(stop_run '{"session_id":"'"$SID5_RAW"'"}' "$OFFCFG")"
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

# --- Scenario 6: unbindable consumed ticket -> repair branch, never a terminus ---
SID6_RAW="stop-ticket-unbindable"
start_session "$SID6_RAW"
SID6="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$SID6" >/dev/null
bash "$LOG" --tdd-complete --session "$SID6" >/dev/null
bash "$LOG" --code-review-done --session "$SID6" >/dev/null
SID6_STATE="$STARTED_PROJECT_ROOT/.zensu/state/tdd-phase-$SID6.json"
[ -f "$SID6_STATE" ] || { echo "scenario 6 fixture: state file missing at $SID6_STATE" >&2; exit 1; }
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  s.reviewTicket = "not a valid ticket!";
  s.reviewTicketConsumed = true;
  s.reviewRound = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
' "$SID6_STATE" || { echo "scenario 6 fixture: state rewrite failed" >&2; exit 1; }
OUT6="$(stop_run '{"session_id":"'"$SID6_RAW"'"}')"
REASON6="$(printf '%s' "$OUT6" | reason)"
if [ "$(printf '%s' "$OUT6" | decision)" = "block" ] \
  && printf '%s' "$REASON6" | grep -qF 'no valid consumed review ticket can bind' \
  && ! printf '%s' "$REASON6" | grep -q "skill='zensu:self-review'" \
  && ! printf '%s' "$REASON6" | grep -qF -- '--chain-done'; then
  check "T10 unbindable consumed ticket -> repair branch, no self-review handoff, no runnable terminus" PASS
else
  check "T10 unbindable consumed ticket -> repair branch, no self-review handoff, no runnable terminus" FAIL
fi
if printf '%s' "$REASON6" | grep -qF '/zensu:reset-review-limit cannot repair this state' \
  && printf '%s' "$REASON6" | grep -qF 'rebinds a RETAINED consumed ticket' \
  && printf '%s' "$REASON6" | grep -qF 'Re-enter /zensu:tdd for the current task' \
  && printf '%s' "$REASON6" | grep -qF "resets this session's review ticket, round counter, and chain flags"; then
  check "T12 repair branch names a recovery that can actually bind (not reset-review-limit)" PASS
else
  check "T12 repair branch names a recovery that can actually bind (not reset-review-limit)" FAIL
fi
if printf '%s' "$REASON6" | grep -qF 'Session state: mode=vanilla, implComplete=true, chainDone=false.' \
  && printf '%s' "$REASON6" | grep -qF 'the RED/GREEN FSM is not driven' \
  && ! printf '%s' "$REASON6" | grep -qF 'exception it explicitly states' \
  && [ "$(printf '%s' "$REASON6" | grep -oF 'Session state: mode=' | wc -l | tr -d ' ')" -eq 1 ]; then
  check "T11 repair branch carries the vanilla state legend exactly once, without the exception clause" PASS
else
  check "T11 repair branch carries the vanilla state legend exactly once, without the exception clause" FAIL
fi
start_session "stop-routing-restore"

echo "----"
echo "test-stop-enforcer-self-review-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
