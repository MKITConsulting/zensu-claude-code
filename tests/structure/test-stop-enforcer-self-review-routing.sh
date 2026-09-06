#!/bin/bash
# Pins the stop-chain-enforcer.sh two-stage routing:
#   implComplete && !codeReviewDone           -> block, force Agent zensu:code-reviewer (unchanged)
#   implComplete && codeReviewDone && !chainDone -> block, force Skill zensu:self-review (NEW)
#   chainDone                                 -> allow (self-review owns the terminus)
#   selfReview later disabled + codeReviewDone -> still force the frozen self-review handoff
#   codeReviewDone + unbindable consumed ticket -> block on the repair branch, never a terminus,
#                                                and a recovery that can actually bind (/zensu:tdd,
#                                                not /zensu:reset-review-limit)
#   !codeReviewDone + the host refused the spawn -> block naming the permission layer and the
#                                                permissions.allow rule, never repeating the
#                                                impossible spawn and never offering a terminus
# Every inner-chain block reason also carries the mode-aware state legend
# (`Session state: mode=vanilla|strict, implComplete=..., chainDone=...`). The
# standalone code-reviewer branch teaches its zero-change escape as
# worktree-verified; the bound branch as an audited Autopilot outcome.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
. "$(dirname "$0")/lib-unit-summary.sh"   # shared, locale-independent summary parse

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

# The scanner's own properties — structural keying by tool_use_id, the host
# error flag, the tail bound, and every degrade-to-none failure mode — cannot be
# observed through the hook. Drive its unit suite from here so the tree runner,
# which only discovers tests/structure/test-*.sh, still covers them. Exit 0
# alone would also accept a file that registers zero cases, so the pass count is
# asserted too, and a failure prints which case failed.
#
# Deliberately FIRST, before any scenario. This suite is the most expensive one
# in the Windows profile, and a TIMED_OUT shard still reports every check it
# reached — so whatever sits at the tail is what silently goes unverified. At the
# tail this was the entire unit suite, the only coverage those properties have
# anywhere. It needs nothing but PLUGIN_DIR and STATE_DIR, so it belongs here.
UNIT_OUT="$STATE_DIR/reviewer-spawn-denial-unit.out"
if node --test "$PLUGIN_DIR/tests/structure/reviewer-spawn-denial-v1.test.js" >"$UNIT_OUT" 2>&1; then
  # Counts come from lib-unit-summary.sh, which owns the locale-independent parse
  # and the reporter-ordering caveat. This block used to carry its own copy of that
  # expression, byte-identical to the one in test-bash-source-write-gate.sh W3a;
  # both now delegate, so the next correction to it has exactly one site.
  UNIT_PASS="$(unit_summary_field pass "$UNIT_OUT")"
  UNIT_TOTAL="$(unit_summary_field tests "$UNIT_OUT")"
  # The total is the real floor; the pass floor is lower because the symlink and
  # FIFO cases skip themselves where the platform cannot create one.
  if [ "$UNIT_TOTAL" -ge 37 ] && [ "$UNIT_PASS" -ge 35 ]; then
    check "T26 reviewer-spawn-denial-v1 unit suite passes ($UNIT_PASS/$UNIT_TOTAL cases)" PASS
  else
    check "T26 reviewer-spawn-denial-v1 unit suite registered only $UNIT_PASS/$UNIT_TOTAL cases" FAIL
  fi
else
  echo "--- reviewer-spawn-denial-v1 unit failures ---"
  grep -B2 -A 20 '^not ok' "$UNIT_OUT" | head -60
  check "T26 reviewer-spawn-denial-v1 unit suite passes" FAIL
fi

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
# --- Scenario 7: the host refused the reviewer spawn -> diagnose, don't repeat ---
# The refusal is invisible to every PreToolUse/PostToolUse hook (a denied call
# never executes), so the transcript the Stop payload points at is the only
# evidence. Without this branch the enforcer demands the same impossible spawn
# until the cap releases it.
SID7_RAW="stop-reviewer-denied"
start_session "$SID7_RAW"
SID7="$STARTED_SESSION_KEY"
SID7_PROJECT="$STARTED_PROJECT_ROOT"
bash "$LOG" --tdd-begin --session "$SID7" >/dev/null
bash "$LOG" --tdd-complete --session "$SID7" >/dev/null

TRANSCRIPT_DENIED="$STATE_DIR/transcript-denied.jsonl"
cat >"$TRANSCRIPT_DENIED" <<'DENIED_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
DENIED_EOF
TRANSCRIPT_CLEAR="$STATE_DIR/transcript-clear.jsonl"
cat >"$TRANSCRIPT_CLEAR" <<'CLEAR_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":false,"content":"VERDICT: PASS"}]}}
CLEAR_EOF
TRANSCRIPT_PROSE="$STATE_DIR/transcript-prose.jsonl"
cat >"$TRANSCRIPT_PROSE" <<'PROSE_EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
PROSE_EOF

OUT7="$(stop_run '{"session_id":"'"$SID7_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED"'"}')"
REASON7="$(printf '%s' "$OUT7" | reason)"
if [ "$(printf '%s' "$OUT7" | decision)" = "block" ] \
  && printf '%s' "$REASON7" | grep -qF 'refused by the HOST permission layer, not by a Zensu gate' \
  && printf '%s' "$REASON7" | grep -qF 'auto mode classifier' \
  && ! printf '%s' "$REASON7" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence'; then
  check "T13 host-refused reviewer spawn -> diagnose the permission layer, not repeat the spawn" PASS
else
  check "T13 host-refused reviewer spawn -> diagnose the permission layer, not repeat the spawn" FAIL
fi
if printf '%s' "$REASON7" | grep -qF '"Agent(zensu:code-reviewer)" to permissions.allow'; then
  check "T14 denial reason prints the exact remedy rule" PASS
else
  check "T14 denial reason prints the exact remedy rule" FAIL
fi
# The only terminus this branch may teach is the zero-change one, which verifies
# its own claim against the worktree. Closing a chain that HAS changes would
# claim a review that never ran, and the reason must say so. The release
# threshold is deliberately not disclosed: a count is a wait-it-out recipe.
# The negative asserts the SHAPE of a leak, not one phrasing — $CAP and $BLOCKS
# are both in scope where the reason is built, so any wording that interpolates
# either has to fail here. A regex naming a sentence the code never emits (the
# earlier spelling) is satisfied unconditionally and pins nothing at all.
if printf '%s' "$REASON7" | grep -qF 'would claim a review that never ran' \
  && printf '%s' "$REASON7" | grep -qF 'Only valid exception: if implementation produced ZERO file changes' \
  && printf '%s' "$REASON7" | grep -qF 'That terminus verifies the claim before it closes anything' \
  && printf '%s' "$REASON7" | grep -qF 'This guard is bounded and will not wedge the session' \
  && ! printf '%s' "$REASON7" | grep -qE '\(cap [0-9]+\)|[0-9]+ (Stop )?nudges'; then
  check "T15 denial reason keeps only the worktree-verified zero-change exit and discloses no cap count" PASS
else
  check "T15 denial reason keeps only the worktree-verified zero-change exit and discloses no cap count" FAIL
fi
if printf '%s' "$REASON7" | grep -qF 'never edit a settings file yourself to widen your own permissions' \
  && printf '%s' "$REASON7" | grep -qF 'make exactly ONE further spawn attempt'; then
  check "T15a denial reason forbids self-granting the permission and allows exactly one retry after the user acts" PASS
else
  check "T15a denial reason forbids self-granting the permission and allows exactly one retry after the user acts" FAIL
fi
if printf '%s' "$REASON7" | grep -qF 'Session state: mode=vanilla, implComplete=true, chainDone=false.' \
  && printf '%s' "$REASON7" | grep -qF 'refused by the HOST permission layer' \
  && [ "$(printf '%s' "$REASON7" | grep -oF 'Session state: mode=' | wc -l | tr -d ' ')" -eq 1 ] \
  && printf '%s' "$REASON7" | grep -qF 'including the single exception it explicitly states' \
  && ! printf '%s' "$REASON7" | grep -qF 'including the exceptions it explicitly states'; then
  check "T16 denial reason carries the state legend exactly once" PASS
else
  check "T16 denial reason carries the state legend exactly once" FAIL
fi
SIDECAR7="$SID7_PROJECT/.zensu/state/reviewer-spawn-denied-$SID7.json"
if [ -f "$SIDECAR7" ] \
  && node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    process.exit(s.schemaVersion===1&&s.kind==="auto-mode-classifier"
      &&s.subagentType==="zensu:code-reviewer"&&Number.isFinite(s.detectedAtMs)?0:1)' "$SIDECAR7"; then
  check "T17 detection leaves a sidecar /zensu:doctor can read outside the turn" PASS
else
  check "T17 detection leaves a sidecar /zensu:doctor can read outside the turn" FAIL
fi

# The `[ ! -f ]` half only means something if the note was there to begin with:
# a tree in which the write silently stopped firing would satisfy it forever.
PRE18="absent"; [ -f "$SIDECAR7" ] && PRE18="present"
OUT8="$(stop_run '{"session_id":"'"$SID7_RAW"'","transcript_path":"'"$TRANSCRIPT_CLEAR"'"}')"
REASON8="$(printf '%s' "$OUT8" | reason)"
if [ "$PRE18" = "present" ] \
  && [ "$(printf '%s' "$OUT8" | decision)" = "block" ] \
  && printf '%s' "$REASON8" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$REASON8" | grep -qF 'refused by the HOST permission layer' \
  && [ ! -f "$SIDECAR7" ]; then
  check "T18 a later successful spawn restores the ordinary directive and clears the sidecar" PASS
else
  check "T18 a later successful spawn restores the ordinary directive and clears the sidecar (pre=$PRE18)" FAIL
fi

OUT9="$(stop_run '{"session_id":"'"$SID7_RAW"'","transcript_path":"'"$TRANSCRIPT_PROSE"'"}')"
REASON9="$(printf '%s' "$OUT9" | reason)"
OUT10="$(stop_run '{"session_id":"'"$SID7_RAW"'"}')"
REASON10="$(printf '%s' "$OUT10" | reason)"
if printf '%s' "$REASON9" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$REASON9" | grep -qF 'refused by the HOST permission layer' \
  && printf '%s' "$REASON10" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$REASON10" | grep -qF 'refused by the HOST permission layer'; then
  check "T19 quoted prose and a payload without transcript_path both keep the ordinary directive" PASS
else
  check "T19 quoted prose and a payload without transcript_path both keep the ordinary directive" FAIL
fi

# The second host kind drives a different cause, a different remedy and a
# different sidecar value; only the classifier kind was exercised above.
TRANSCRIPT_GENERIC="$STATE_DIR/transcript-generic.jsonl"
cat >"$TRANSCRIPT_GENERIC" <<'GENERIC_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t9","is_error":true,"content":"Permission for this action has been denied. Reason: user rejected."}]}}
GENERIC_EOF
OUT11="$(stop_run '{"session_id":"'"$SID7_RAW"'","transcript_path":"'"$TRANSCRIPT_GENERIC"'"}')"
REASON11="$(printf '%s' "$OUT11" | reason)"
if printf '%s' "$REASON11" | grep -qF 'refused by the HOST permission layer' \
  && printf '%s' "$REASON11" | grep -qF 'A deny rule outranks an allow rule, so the deny has to go first' \
  && ! printf '%s' "$REASON11" | grep -qF 'auto mode classifier' \
  && [ -f "$SIDECAR7" ] \
  && node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    process.exit(s.kind==="permission-denied"?0:1)' "$SIDECAR7"; then
  check "T21 the generic host denial drives its own cause, remedy and sidecar kind" PASS
else
  check "T21 the generic host denial drives its own cause, remedy and sidecar kind" FAIL
fi

# A reviewer that merely QUOTES a denial literal must not be read as a refusal:
# for an Agent call the tool_result body IS the subagent's own report.
TRANSCRIPT_QUOTING="$STATE_DIR/transcript-quoting.jsonl"
cat >"$TRANSCRIPT_QUOTING" <<'QUOTING_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tq","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tq","is_error":false,"content":"VERDICT: PASS. The module matches \"Permission for this action was denied by the Claude Code auto mode classifier.\" as a prefix."}]}}
QUOTING_EOF
# A transcript that cannot be read is an ordinary condition (rotated, absent) and
# must leave the diagnosis standing — widening the retire branch to a bare `else`
# would destroy it on every such Stop with the rest of this suite green.
OUT11b="$(stop_run '{"session_id":"'"$SID7_RAW"'","transcript_path":"'"$STATE_DIR"'/no-such-transcript.jsonl"}')"
REASON11b="$(printf '%s' "$OUT11b" | reason)"
if printf '%s' "$REASON11b" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && [ -f "$SIDECAR7" ]; then
  check "T21a an unreadable transcript keeps the ordinary directive and leaves the note standing" PASS
else
  check "T21a an unreadable transcript leaves the note standing" FAIL
fi

PRE22="absent"; [ -f "$SIDECAR7" ] && PRE22="present"
OUT12="$(stop_run '{"session_id":"'"$SID7_RAW"'","transcript_path":"'"$TRANSCRIPT_QUOTING"'"}')"
REASON12="$(printf '%s' "$OUT12" | reason)"
if [ "$PRE22" = "present" ] \
  && printf '%s' "$REASON12" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$REASON12" | grep -qF 'refused by the HOST permission layer' \
  && [ ! -f "$SIDECAR7" ]; then
  check "T22 a successful reviewer result quoting the denial literal is not a refusal" PASS
else
  check "T22 a successful reviewer result quoting the denial literal is not a refusal (pre=$PRE22)" FAIL
fi

# --- Scenario 7b: the same routing, driven by a REAL host capture ------------
# Every fixture above is hand-authored, so together they can only pin what this
# repo BELIEVES the host emits. fixtures/reviewer-spawn-denied-transcript.v1.jsonl
# is a redaction of two entries taken verbatim out of a real Claude Code 2.1.237
# session whose zensu:code-reviewer spawns the auto mode classifier refused: the
# tool_use/tool_result pair, the is_error flag and the full refusal body are the
# original bytes. The synthetic TRANSCRIPT_DENIED above is a faithful reduction
# of exactly this, and this scenario is what proves that claim rather than
# asserting it — a host rewording that the hand-authored envelope would keep
# passing fails here.
#
# Deliberately placed beside scenario 7 rather than at the tail of the file: on a
# TIMED_OUT Windows shard the tail is what silently goes unverified, and this is
# the only check in the suite reading bytes the host actually produced. It costs
# one session and one Stop. The recorded Windows range (985846-1274496 ms against
# a 1500000 ms cap) PREDATES this scenario and does not cover it — the slow sample
# already sat at 85% of the cap, so treat the headroom as unmeasured until a green
# Windows run reports a new figure.
#
# It is NOT a re-run of T13 with a different file. T13 proves the branch renders
# the right cause and remedy; this proves the branch is reachable AT ALL from the
# shape the host really writes.
SID7B_RAW="stop-reviewer-denied-capture"
start_session "$SID7B_RAW"
SID7B="$STARTED_SESSION_KEY"
SID7B_PROJECT="$STARTED_PROJECT_ROOT"
bash "$LOG" --tdd-begin --session "$SID7B" >/dev/null
bash "$LOG" --tdd-complete --session "$SID7B" >/dev/null
TRANSCRIPT_CAPTURE="$PLUGIN_DIR/tests/structure/fixtures/reviewer-spawn-denied-transcript.v1.jsonl"
OUT7B="$(stop_run '{"session_id":"'"$SID7B_RAW"'","transcript_path":"'"$TRANSCRIPT_CAPTURE"'"}')"
REASON7B="$(printf '%s' "$OUT7B" | reason)"
if [ "$(printf '%s' "$OUT7B" | decision)" = "block" ] \
  && printf '%s' "$REASON7B" | grep -qF 'refused by the HOST permission layer, not by a Zensu gate' \
  && printf '%s' "$REASON7B" | grep -qF 'auto mode classifier' \
  && printf '%s' "$REASON7B" | grep -qF '"Agent(zensu:code-reviewer)" to permissions.allow' \
  && ! printf '%s' "$REASON7B" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence'; then
  check "T36 the real 2.1.237 host refusal routes to the denial branch" PASS
else
  check "T36 the real 2.1.237 host refusal routes to the denial branch" FAIL
fi
SIDECAR7B="$SID7B_PROJECT/.zensu/state/reviewer-spawn-denied-$SID7B.json"
if [ -f "$SIDECAR7B" ] \
  && node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    process.exit(s.schemaVersion===1&&s.kind==="auto-mode-classifier"
      &&s.subagentType==="zensu:code-reviewer"&&Number.isFinite(s.detectedAtMs)?0:1)' "$SIDECAR7B"; then
  check "T36a the real capture mints the sidecar /zensu:doctor reads" PASS
else
  check "T36a the real capture mints the sidecar /zensu:doctor reads" FAIL
fi

# The OTHER arm of the retry sanction, which nothing in this tree asserted. T15a
# pins that ONE further attempt is offered; the withdrawal that fires once the
# scanner reports two or more refusals was untested in both directions, and it is
# the arm that carries the whole point of counting: without it this branch
# re-licenses a retry on every blocked Stop and becomes the naive loop its own
# reason text forbids two sentences earlier. The observed session took three
# refusals, so this is the arm that should have governed its 2nd and 3rd Stop.
# Reuses SID7B rather than arming a session of its own — one extra Stop, no extra
# session, on a chain far below the release cap.
TRANSCRIPT_DENIED2="$STATE_DIR/transcript-denied-twice.jsonl"
cat >"$TRANSCRIPT_DENIED2" <<'DENIED2_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
DENIED2_EOF
OUT7C="$(stop_run '{"session_id":"'"$SID7B_RAW"'","transcript_path":"'"$TRANSCRIPT_DENIED2"'"}')"
REASON7C="$(printf '%s' "$OUT7C" | reason)"
if [ "$(printf '%s' "$OUT7C" | decision)" = "block" ] \
  && printf '%s' "$REASON7C" | grep -qF 'refused by the HOST permission layer, not by a Zensu gate' \
  && printf '%s' "$REASON7C" | grep -qF 'A retry has already been spent and was refused again' \
  && ! printf '%s' "$REASON7C" | grep -qF 'make exactly ONE further spawn attempt'; then
  check "T37 a second refusal withdraws the retry sanction instead of re-offering it" PASS
else
  check "T37 a second refusal withdraws the retry sanction instead of re-offering it" FAIL
fi

# T38-T41 pin ZENSU_REVIEW_SPAWN_IN_SCOPE (T41 covers the operator account that
# names it). Without them the sentence is invisible to
# every check in this file: each reason assertion greps ONE clause, and the resume
# discriminator ('Resume the /zensu:tdd Phase 6 review sequence') survives the
# sentence's removal, so deleting it changed no verdict. T39's negative is the arm
# that matters — the host-refusal branch must NOT carry it, and T37's own negative
# needle cannot see that because the exhausted arm never held the phrase it greps.
IN_SCOPE_NEEDLE='If a session rule leads you to withhold them, do not withhold silently'
IN_SCOPE_OWNER="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
IN_SCOPE_DELEGATE_FILE="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
# All three agent identities are asserted, not just one: this constant made its
# owner a NEW carrier of the identity triple, and the repo's control for renaming
# those is a manual grep. Pinning them here is what keeps a missed rename loud.
if printf '%s' "$REASON8" | grep -qF "$IN_SCOPE_NEEDLE" \
  && printf '%s' "$REASON8" | grep -qF 'zensu:review-aspect panel' \
  && printf '%s' "$REASON8" | grep -qF 'zensu:review-judge second pass when it is enabled' \
  && printf '%s' "$REASON8" | grep -qF 'zensu:code-reviewer consolidation'; then
  check "T38 the resume directive renders the in-scope sentence, naming all three spawns" PASS
else
  check "T38 the resume directive renders the in-scope sentence, naming all three spawns" FAIL
fi

# The two negatives are anchored on a POSITIVE that proves each reason was
# actually captured — an empty or unset capture satisfies a bare `!` and reports
# PASS while testing nothing, which is the idiom this file states for itself at
# the PRE18/PRE22 checks above. Both arms render from the same REASON= site and
# differ only in DENIAL_RETRY_CLAUSE, so the second arm guards a future split
# rather than an independent render site today.
# The needle-liveness conjunct is the third anchor: without it, a reword of the
# owner's sentence that left IN_SCOPE_NEEDLE stale would make both negatives true
# against a string that exists nowhere.
# A FOURTH anchor, in the same namespace as the assertion: the source-side conjunct
# proves the string exists in a FILE, while the two negatives measure EMITTED output.
# That left one shape uncovered — a change that keeps the constant intact but breaks
# the literal match against emitted text (an encoding or normalisation change in the
# reason channel) would satisfy the file anchor while making both negatives true for
# the wrong reason. REASON8 is already captured and already proven by T38 to carry the
# needle, so closing it costs no extra Stop.
if grep -qF "$IN_SCOPE_NEEDLE" "$IN_SCOPE_OWNER" \
  && printf '%s' "$REASON8" | grep -qF "$IN_SCOPE_NEEDLE" \
  && printf '%s' "$REASON7C" | grep -qF 'refused by the HOST permission layer' \
  && printf '%s' "$REASON7" | grep -qF 'refused by the HOST permission layer' \
  && ! printf '%s' "$REASON7C" | grep -qF "$IN_SCOPE_NEEDLE" \
  && ! printf '%s' "$REASON7" | grep -qF "$IN_SCOPE_NEEDLE"; then
  check "T39 neither host-refusal arm renders the in-scope sentence" PASS
else
  check "T39 neither host-refusal arm renders the in-scope sentence" FAIL
fi

# Source-level: one owner, and every renderer CONSUMES it.
# Counts are OCCURRENCES, not lines: both delegate consumptions and the enforcer's
# sit on single mega-lines, so a duplicate interpolation added inside one of them
# is invisible to `grep -c`.
# The no-redeclaration arms are what actually pin AC-001: `grep -c` over the OWNER
# alone cannot see a consumer file re-declaring the constant between the `source`
# and its own render, which shadows the library value with every other count green.
# The tree-wide arm catches a verbatim prose copy in a third file, which no
# per-file count can.
# The FORM arm keeps the definition a plain assignment: a `${VAR:-…}` respelling
# would satisfy the count while making model-facing directive text environment-
# overridable.
# The last two arms keep a future reword from borrowing a branch discriminator,
# which would hollow out the negatives at T37, T39 and the four
# 'refused by the HOST permission layer' negatives elsewhere in this file.
occ() { grep -oF "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
# `occ` exists for the multi-match-per-line case, and nothing in the tree produces one:
# every occurrence it counts today sits alone on its line. So if it silently degraded
# to line counting, every arm below would stay green and the stated protection would be
# gone — the "a control that never fires" class this repo flags elsewhere. Two lines
# make the discrimination real.
printf 'x ${IN_SCOPE_CLAUSE} y ${IN_SCOPE_CLAUSE}\n' > "$STATE_DIR/occ-probe"
if [ "$(occ '${IN_SCOPE_CLAUSE}' "$STATE_DIR/occ-probe")" = "2" ]; then
  check "T40pre occ() counts occurrences, not lines" PASS
else
  check "T40pre occ() counts occurrences, not lines" FAIL
fi
# Both consumers now interpolate the constant ONCE, into a local `IN_SCOPE_CLAUSE`
# that carries the config gate (and, in the Stop enforcer, the probe gate) — so the
# constant's own count is 1 per consumer and the RENDER count moved to the clause.
# Both are pinned: dropping the clause count would restore exactly the blind spot the
# occurrence form exists for, since the delegate's two arms sit on single mega-lines.
IN_SCOPE_DEF="$(occ 'ZENSU_REVIEW_SPAWN_IN_SCOPE="' "$IN_SCOPE_OWNER")"
IN_SCOPE_STOP="$(occ '${ZENSU_REVIEW_SPAWN_IN_SCOPE}' "$STOP")"
IN_SCOPE_DELEGATE="$(occ '${ZENSU_REVIEW_SPAWN_IN_SCOPE}' "$IN_SCOPE_DELEGATE_FILE")"
IN_SCOPE_CLAUSE_STOP="$(occ '${IN_SCOPE_CLAUSE}' "$STOP")"
IN_SCOPE_CLAUSE_DELEGATE="$(occ '${IN_SCOPE_CLAUSE}' "$IN_SCOPE_DELEGATE_FILE")"
# The redeclaration scan matches the ASSIGNMENT, not one quoting style: a shadow
# spelled with single quotes or $'…' would score 0 against a `="`-only needle.
# tests/ is excluded from the hand-copy scan: this file legitimately holds the needle.
# The scanned roots are enumerated at the scan itself, a few lines below.
IN_SCOPE_REDECL="$(( $(grep -cE '^[[:space:]]*(readonly |declare |export |local |typeset )?ZENSU_REVIEW_SPAWN_IN_SCOPE=' "$STOP" || true) + $(grep -cE '^[[:space:]]*(readonly |declare |export |local |typeset )?ZENSU_REVIEW_SPAWN_IN_SCOPE=' "$IN_SCOPE_DELEGATE_FILE" || true) ))"
# `agents/` and `templates/` were silently out of scope, and both ship model-facing
# prose in this repo (agents/*.md frontmatter and bodies, templates/tdd-plan.md,
# templates/pr-body.md, templates/autopilot-pr-body.md) — the file class most likely to
# attract a verbatim copy of a directive paragraph. Repo-root CLAUDE.md is included for
# the same reason; it paraphrases today, which is what keeps the expected count at 1.
# `tests/` stays carved out: this file legitimately holds the needle.
IN_SCOPE_TREE="$(grep -rlF "$IN_SCOPE_NEEDLE" \
  "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/skills" "$PLUGIN_DIR/docs" \
  "$PLUGIN_DIR/agents" "$PLUGIN_DIR/templates" "$PLUGIN_DIR/CLAUDE.md" \
  2>/dev/null | wc -l | tr -d ' ')"
# The owner-side uniqueness scan used to be NARROWER than the consumer-side one, in the
# wrong direction: an indented or single-quoted second assignment inside the owner
# scored 0 against a `^`-anchored `="`-only needle while every other arm stayed green,
# and the shipped value would be whichever assignment ran last. One spelling for all
# three files also keeps the next correction to it from landing in only two of them.
IN_SCOPE_LINE="$(grep -E '^[[:space:]]*(readonly |declare |export |local |typeset )?ZENSU_REVIEW_SPAWN_IN_SCOPE=' "$IN_SCOPE_OWNER" || true)"
IN_SCOPE_DEF_LINES="$(grep -cE '^[[:space:]]*(readonly |declare |export |local |typeset )?ZENSU_REVIEW_SPAWN_IN_SCOPE=' "$IN_SCOPE_OWNER" || true)"
if [ "$IN_SCOPE_DEF" = "1" ] && [ "$IN_SCOPE_STOP" = "1" ] && [ "$IN_SCOPE_DELEGATE" = "1" ] \
  && [ "$IN_SCOPE_CLAUSE_STOP" = "1" ] && [ "$IN_SCOPE_CLAUSE_DELEGATE" = "2" ] \
  && [ "$IN_SCOPE_REDECL" = "0" ] && [ "$IN_SCOPE_TREE" = "1" ] && [ "$IN_SCOPE_DEF_LINES" = "1" ] \
  && printf '%s' "$IN_SCOPE_LINE" | grep -qF 'ZENSU_REVIEW_SPAWN_IN_SCOPE="These spawns' \
  && printf '%s' "$IN_SCOPE_LINE" | grep -qF 'a host permission refusal is still a refusal."' \
  && ! printf '%s' "$IN_SCOPE_LINE" | grep -qF ':-' \
  && ! printf '%s' "$IN_SCOPE_LINE" | grep -qF 'refused by the HOST permission layer' \
  && ! printf '%s' "$IN_SCOPE_LINE" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence'; then
  check "T40 one owner, three consumers, no redeclaration or hand-copy, and no borrowed discriminator" PASS
else
  # Ten conjuncts under one label told the reader nothing about WHICH failed — a
  # legitimately added render site, a doc that quoted the sentence, and a reworded
  # opening clause all printed the same line. The count arms are a REGISTRATION
  # mechanism (a new render site is supposed to fail here until the number is raised),
  # so this message is that mechanism's whole user interface. Same idiom as T18/T22/T26.
  check "T40 one owner, three consumers, no redeclaration or hand-copy, and no borrowed discriminator (def=$IN_SCOPE_DEF stop=$IN_SCOPE_STOP delegate=$IN_SCOPE_DELEGATE clauseStop=$IN_SCOPE_CLAUSE_STOP clauseDelegate=$IN_SCOPE_CLAUSE_DELEGATE redecl=$IN_SCOPE_REDECL tree=$IN_SCOPE_TREE lines=$IN_SCOPE_DEF_LINES)" FAIL
fi

# The windowed-REVIEWER_DENIALS bound is stated in THREE places — the code comment
# beside the arm it affects, the CLAUDE.md gap bullet, and the docs host-refusal
# paragraph — and the CLAUDE.md bullet names the other two as "the other two carriers".
# A declared coupling pinned by nothing is the drift class this repo treats as its main
# defect mode; T41 six lines down is the same pattern applied to the other prose
# coupling. Each needle is distinctive enough to survive a reword of its surrounding
# paragraph and specific enough to fail on deletion.
if grep -qF 'scroll out and the sanction' "$STOP" \
  && grep -qF 'two earlier refusals scroll out of the window' "$PLUGIN_DIR/CLAUDE.md" \
  && grep -qF 'the withdrawal is scoped to the scanned transcript tail' "$PLUGIN_DIR/docs/tdd-manager-workflow.md"; then
  check "T49 all three carriers of the windowed-REVIEWER_DENIALS bound are still present" PASS
else
  check "T49 all three carriers of the windowed-REVIEWER_DENIALS bound are still present" FAIL
fi

# T50-T53 pin the gate's RENDER side, which T38 covered for `clear` alone. The design
# forbids a `clear`-only gate in so many words, and the whole rest of the suite stayed
# green under one — so these are the arms that make that statement enforceable.
#
# The classification changed in this round: `unreadable` now RENDERS. It is returned
# BEFORE any tool result is inspected (a rotated or deleted transcript, a FIFO, an
# EACCES path), which is the same "could not look" evidence state as a probe that
# timed out or an installation with no scanner module — and both of those already
# rendered. Withholding on one while rendering on the other was one class taking two
# opposite directions inside one block. Only `errored` — a result the host flagged as
# an error whose text matched no known refusal literal — withholds now, because that
# is the only verdict in which a refusal was actually observed.
if grep -qF "$IN_SCOPE_NEEDLE" "$IN_SCOPE_OWNER" \
  && printf '%s' "$REASON11b" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && printf '%s' "$REASON11b" | grep -qF "$IN_SCOPE_NEEDLE"; then
  check "T50 an unreadable transcript renders the scope sentence, like every other could-not-look state" PASS
else
  check "T50 an unreadable transcript renders the scope sentence, like every other could-not-look state" FAIL
fi

# `none` (a transcript with no reviewer result — every chain's FIRST resume Stop) and
# `unprobed` (no transcript path at all). Both captures already exist; T19 asserted only
# the resume discriminator on them, so a `clear`-only gate was invisible to the suite.
if printf '%s' "$REASON9" | grep -qF "$IN_SCOPE_NEEDLE" \
  && printf '%s' "$REASON10" | grep -qF "$IN_SCOPE_NEEDLE"; then
  check "T51 the none and unprobed states both render the scope sentence" PASS
else
  check "T51 the none and unprobed states both render the scope sentence" FAIL
fi

# The residual arm. `REVIEWER_DENIAL_RAW` is a hand-enumeration of a vocabulary the
# scanner module owns and does not export, so a status added there lands in the `case`'s
# default. Source-pinned rather than behavioural: no fixture can make the module emit a
# word it does not have. The render side must be a closed ALLOWLIST and the default must
# name itself, so an unknown verdict withholds instead of inheriting the initializer.
# Anchored to a whole line, not a substring: `grep -qF` on the alternation still matches
# after a member is PREPENDED, and would also be satisfied by a comment quoting it. Both
# residual arms must name themselves — the parseable-but-unrecognized one and the
# unparseable one — because an arm that inherits the initializer lands in the render
# allowlist, which is the split this round removed for `unreadable`.
if grep -qE '^[[:space:]]*clear\|none\|unprobed\|unreadable\)[[:space:]]*$' "$STOP" \
  && grep -qF 'REVIEWER_DENIAL_RAW="unknown"' "$STOP" \
  && grep -qF 'REVIEWER_DENIAL_RAW="unparseable"' "$STOP"; then
  check "T54 the render side is a closed allowlist and an unrecognized status names itself" PASS
else
  check "T54 the render side is a closed allowlist and an unrecognized status names itself" FAIL
fi

if grep -qF 'export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"; zensu_hook_enabled reviewSpawnScopeSentence' "$STOP"; then
  check "T58 the Stop site resolves the scope-sentence flag from the record's project root" PASS
else
  check "T58 the Stop site resolves the scope-sentence flag from the record's project root" FAIL
fi


# `config.example.json` is advertised as carrying every flag, and ten sibling suites pin
# their own key there. Without this arm the file can silently lose the key.
if grep -qF '"reviewSpawnScopeSentence"' "$PLUGIN_DIR/config.example.json"; then
  check "T55 config.example.json carries the reviewSpawnScopeSentence flag" PASS
else
  check "T55 config.example.json carries the reviewSpawnScopeSentence flag" FAIL
fi

# The false bypass-ledger claim, pinned NEGATIVELY in all three carriers it was copied
# into. `hooks.chainEnforcer=false` is a config-disabled gate, and this repo's own
# authoritative residual list says config-disabled gates are deliberately not ledgered —
# only the eight ZENSU_* env escapes are. The positive anchor keeps the check from
# passing on a file that lost the row entirely.
# Assembled from two halves so this file never holds the forbidden literal verbatim —
# the scan covers this suite too, and a check that contains its own needle can never pass.
LEDGER_FALSE_CLAIM="disables the whole guard and lands"' a bypass-ledger entry'
if grep -qF 'reviewSpawnScopeSentence' "$PLUGIN_DIR/docs/configuration.md" \
  && grep -qF 'disables the whole guard' "$PLUGIN_DIR/docs/configuration.md" \
  && grep -qF 'a bypass-ledger entry' "$PLUGIN_DIR/docs/configuration.md" \
  && ! grep -qF "$LEDGER_FALSE_CLAIM" "$PLUGIN_DIR/docs/configuration.md" \
  && ! grep -qF "$LEDGER_FALSE_CLAIM" "$PLUGIN_DIR/CLAUDE.md" \
  && ! grep -qF "$LEDGER_FALSE_CLAIM" "$PLUGIN_DIR/docs/tdd-manager-workflow.md" \
  && ! grep -qF "$LEDGER_FALSE_CLAIM" "$0"; then
  check "T56 no carrier claims a config-disabled gate lands a bypass-ledger entry" PASS
else
  check "T56 no carrier claims a config-disabled gate lands a bypass-ledger entry" FAIL
fi

# The operator account names the constant by identifier. Nothing else compares the
# two, so a rename would leave that paragraph pointing at a symbol that no longer
# exists with every other check green.
# Anchored on the POSITIVE account's own heading, not on the identifier alone: the
# identifier also appears in the host-refusal paragraph's omission clause, so a bare
# name grep survives deletion of the paragraph this check exists to protect.
# The CLAUDE.md section is the THIRD carrier, and the owner comment asserts a coupling
# to it in so many words ("CLAUDE.md §... holds the same four bounds and must move with
# this comment"). Nothing compared them: the tree scan is a hand-copy scan, not a
# presence check, so that pointer could dangle with every other arm green.
if grep -qF '**The review-spawn scope sentence.**' "$PLUGIN_DIR/docs/tdd-manager-workflow.md" \
  && grep -qF 'ZENSU_REVIEW_SPAWN_IN_SCOPE' "$PLUGIN_DIR/docs/tdd-manager-workflow.md" \
  && grep -qF '## Review-Spawn Scope Sentence (`ZENSU_REVIEW_SPAWN_IN_SCOPE`)' "$PLUGIN_DIR/CLAUDE.md"; then
  check "T41 the operator account still carries the positive paragraph and names the constant" PASS
else
  check "T41 the operator account still carries the positive paragraph and names the constant" FAIL
fi

# T42-T43 pin the clause's GATE, which is a different question from T38/T39.
# T38/T39 ask WHICH BRANCH renders it; these ask whether the resume branch itself
# may render it given what the reviewer-spawn probe actually established.
#
# `reviewer_spawn_denied` is true only for `status=blocked`, so the shell's own
# `case` folds `status=errored` and `status=unreadable` into `none` and both reach
# the resume branch. `errored` is the shape a host produces when it refuses with a
# body that matches no DENIAL_MARKERS prefix — a REAL refusal the scanner could not
# classify. Rendering "do not withhold silently and do not work around it" there is
# precisely the adjacency the owner comment says must never occur, and worse than
# the case it considers: the reason carries no permission text at all to tell the
# model which restraint is meant. T39 is structurally blind to it because both of
# its captures come from `blocked` runs.
#
# The gate deliberately suppresses on `errored`/`unreadable` ONLY, never on `none`.
# Measured, not assumed: `reviewer-spawn-denial-v1.js` returns `verdict('none')`
# when no reviewer result exists at all, which is every chain's FIRST resume Stop —
# the case this sentence exists for. A `status=clear`-only gate would therefore
# delete the feature rather than narrow it.
TRANSCRIPT_ERRORED="$STATE_DIR/transcript-errored.jsonl"
cat >"$TRANSCRIPT_ERRORED" <<'ERRORED_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"te","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"te","is_error":true,"content":"The operation could not be completed for an unstated reason."}]}}
ERRORED_EOF
OUT_ERRORED="$(stop_run '{"session_id":"'"$SID7B_RAW"'","transcript_path":"'"$TRANSCRIPT_ERRORED"'"}')"
REASON_ERRORED="$(printf '%s' "$OUT_ERRORED" | reason)"
# Three positive anchors before the negative, matching T39's idiom: needle liveness
# in the owner, the resume discriminator (proving this really is the resume branch),
# and the absence of the host-refusal text (proving the probe did NOT say `blocked`).
if grep -qF "$IN_SCOPE_NEEDLE" "$IN_SCOPE_OWNER" \
  && printf '%s' "$REASON_ERRORED" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$REASON_ERRORED" | grep -qF 'refused by the HOST permission layer' \
  && ! printf '%s' "$REASON_ERRORED" | grep -qF "$IN_SCOPE_NEEDLE"; then
  check "T42 an unclassifiable refusal keeps the resume directive but withholds the scope sentence" PASS
else
  check "T42 an unclassifiable refusal keeps the resume directive but withholds the scope sentence" FAIL
fi

# The positive control for T42, and the AC-004 half: when the clause DOES render,
# the appended legend closer must not still claim a single exception. Before this
# change the reason stated one deviation (the zero-change terminus) and the closer
# said "the single exception it explicitly states"; the clause adds a second
# sanctioned route, so the singular closer became a false statement about the very
# instruction it closes. REASON8 is the clean-probe capture T38 already uses.
if printf '%s' "$REASON8" | grep -qF "$IN_SCOPE_NEEDLE" \
  && printf '%s' "$REASON8" | grep -qF 'including the exceptions it explicitly states' \
  && ! printf '%s' "$REASON8" | grep -qF 'including the single exception it explicitly states'; then
  check "T43 a rendered scope sentence is closed by the plural-exception legend" PASS
else
  check "T43 a rendered scope sentence is closed by the plural-exception legend" FAIL
fi

# T52-T53 sit HERE, after T42's capture, rather than beside T50/T51 above: they read
# $REASON_ERRORED, and under `set -u` a check placed before its capture aborts the whole
# suite rather than failing one line.
#
# The withhold side's OWN closer. T43 pins the plural on a rendered reason; without this
# arm both closers could collapse to the plural with every check green — the same false
# statement AC-004 exists to remove, in the other direction.
if printf '%s' "$REASON_ERRORED" | grep -qF 'including the single exception it explicitly states' \
  && ! printf '%s' "$REASON_ERRORED" | grep -qF 'including the exceptions it explicitly states'; then
  check "T52 a withheld scope sentence keeps the singular-exception legend" PASS
else
  check "T52 a withheld scope sentence keeps the singular-exception legend" FAIL
fi

# The body's own lead-in must agree with the closer. Before this round the body said
# "Only valid exception:" while the plural closer said "the exceptions it explicitly
# states", so one emitted directive asserted both that there is exactly one sanctioned
# deviation and that there are several. The withhold side keeps the singular lead, which
# is what the negative on $REASON_ERRORED pins.
if printf '%s' "$REASON8" | grep -qF 'Two valid exceptions.' \
  && ! printf '%s' "$REASON8" | grep -qF 'Only valid exception:' \
  && printf '%s' "$REASON_ERRORED" | grep -qF 'Only valid exception:' \
  && ! printf '%s' "$REASON_ERRORED" | grep -qF 'Two valid exceptions.'; then
  check "T53 the exception lead-in agrees with the closer on both sides of the gate" PASS
else
  check "T53 the exception lead-in agrees with the closer on both sides of the gate" FAIL
fi

# The lead-in and the closer both COUNT the exceptions; nothing asserted that the second
# one is actually STATED. Emptying it left a directive announcing two exceptions, stating
# one, and closing by naming "the exceptions" in the plural — the exact false-statement
# class T43/T52/T53 exist to remove — with both suites green.
#
# The bound is part of the assertion, not decoration. The route this exception sanctions
# does NOT release the Stop guard: reporting the withholding and ending the turn re-fires
# Stop and re-injects the same reason until the cap. The host-refusal branch discloses
# exactly that about its own report-to-the-user instruction ("This guard is bounded and
# will not wedge the session"); without the same disclosure here the directive reads as
# offering a way out that it does not have.
if printf '%s' "$REASON8" | grep -qF 'Second: if a session rule leads you to withhold the fan-out' \
  && printf '%s' "$REASON8" | grep -qF 'this Stop guard is bounded' \
  && printf '%s' "$REASON_ERRORED" | grep -qF 'Only valid exception:' \
  && ! printf '%s' "$REASON_ERRORED" | grep -qF 'Second: if a session rule leads you to withhold the fan-out'; then
  check "T57 the second exception is stated, discloses its bound, and appears only where it is sanctioned" PASS
else
  check "T57 the second exception is stated, discloses its bound, and appears only where it is sanctioned" FAIL
fi

# The owner comment records a SECOND draft discarded for "swapping the rule's own
# criterion for one the plugin can always satisfy". A clause contrasting the chain's
# spawns with subagents "chosen ad hoc" restates that criterion one noun over: every
# spawn this sentence renders beside belongs to a declared chain, so the predicate is
# one the plugin satisfies unconditionally. Asserted on the emitted directive, and
# conjoined with the three identities so it cannot pass on an empty capture.
if printf '%s' "$REASON8" | grep -qF 'zensu:review-aspect panel' \
  && printf '%s' "$REASON8" | grep -qF 'zensu:code-reviewer consolidation' \
  && printf '%s' "$REASON8" | grep -qF 'armed in this session' \
  && ! printf '%s' "$REASON8" | grep -qF 'not subagents chosen ad hoc'; then
  check "T44 the scope sentence states the chain's shape without the ad-hoc contrast" PASS
else
  check "T44 the scope sentence states the chain's shape without the ad-hoc contrast" FAIL
fi

# This is the ONE piece of model-facing prose in the tree whose subject is a
# HOST-level session rule, and it renders on every resume directive and every fix
# round including on hosts that carry no such rule. Every comparable surface here is
# switchable (hooks.selfReview, hooks.reviewJudge, hooks.findingVerification,
# hooks.reviewerSpawnAutoAllow, hooks.bestSolutionFirst); without a key of its own the
# only lever is hooks.chainEnforcer=false, which disables the whole guard and is not
# ledgered either: a config-disabled gate has no decision point to record, so only the
# ZENSU_* env escapes ever produce an entry. Permissively read, so an unreadable config
# keeps the default.
CFG_NO_SCOPE="$STATE_DIR/config-no-scope-sentence.json"
printf '%s\n' '{"hooks":{"reviewSpawnScopeSentence":false}}' >"$CFG_NO_SCOPE"
OUT_NOSCOPE="$(stop_run '{"session_id":"'"$SID7B_RAW"'","transcript_path":"'"$TRANSCRIPT_CLEAR"'"}' "$CFG_NO_SCOPE")"
REASON_NOSCOPE="$(printf '%s' "$OUT_NOSCOPE" | reason)"
if grep -qF "$IN_SCOPE_NEEDLE" "$IN_SCOPE_OWNER" \
  && printf '%s' "$REASON_NOSCOPE" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$REASON_NOSCOPE" | grep -qF "$IN_SCOPE_NEEDLE" \
  && printf '%s' "$REASON_NOSCOPE" | grep -qF 'Only valid exception:' \
  && printf '%s' "$REASON_NOSCOPE" | grep -qF 'including the single exception it explicitly states' \
  && ! printf '%s' "$REASON_NOSCOPE" | grep -qF 'Second: if a session rule leads you to withhold the fan-out'; then
  check "T45 hooks.reviewSpawnScopeSentence=false suppresses the sentence, not the directive" PASS
else
  check "T45 hooks.reviewSpawnScopeSentence=false suppresses the sentence, not the directive" FAIL
fi

# The premise the whole feature rests on is a HOST fact — which prompt section
# carries the rule, on which Claude Code build. Every sibling host literal in this
# tree records its build in a constant cross-checked against the comment that names
# it (DENIAL_MARKERS_SOURCE_BUILD, SETTINGS_SOURCE_BUILD, ALLOW_BYPASS_SOURCE_BUILD).
# Without one, a host that retires that prompt section leaves this sentence arguing
# against a rule that no longer exists, with every check green.
SCOPE_BUILD="$(grep -m1 '^ZENSU_REVIEW_SPAWN_SCOPE_SOURCE_BUILD=' "$IN_SCOPE_OWNER" | sed 's/.*="//; s/".*//')"
# Uniqueness, for the same reason T40 pins it for the sibling constant: with a second,
# later assignment the shipped value is whichever ran last and `-m1` compares the wrong one.
SCOPE_BUILD_LINES="$(grep -cE '^[[:space:]]*(readonly |declare |export |local |typeset )?ZENSU_REVIEW_SPAWN_SCOPE_SOURCE_BUILD=' "$IN_SCOPE_OWNER" || true)"
# Anchored to the scope-sentence comment block rather than to the whole 2800-line file:
# an unrelated host literal recording the same build elsewhere would otherwise satisfy this
# after the block lost its own provenance sentence.
SCOPE_BLOCK="$(awk '/^# --- Review-spawn scope sentence/,/^ZENSU_REVIEW_SPAWN_IN_SCOPE=/' "$IN_SCOPE_OWNER")"
if [ -n "$SCOPE_BUILD" ] && [ "$SCOPE_BUILD_LINES" = "1" ] \
  && printf '%s' "$SCOPE_BLOCK" | grep -qF "Claude Code $SCOPE_BUILD"; then
  check "T46 the scope sentence records its host build and the comment names the same one" PASS
else
  check "T46 the scope sentence records its host build and the comment names the same one (build=${SCOPE_BUILD:-<absent>} defs=${SCOPE_BUILD_LINES:-0} blockLines=$(printf '%s' "$SCOPE_BLOCK" | grep -c . || true))" FAIL
fi

# The carrier census in CLAUDE.md is the repo's own manual-grep control for renaming
# this identity, and its derived unpinned count is arithmetic over it — so a stale
# number sends a maintainer to check one file too few. Measured here rather than
# restated, which is what keeps it from going stale again.
census_word() {
  case "$1" in
    8) printf 'EIGHT' ;; 9) printf 'NINE' ;; 10) printf 'TEN' ;;
    11) printf 'ELEVEN' ;; 12) printf 'TWELVE' ;; 13) printf 'THIRTEEN' ;;
    *) printf '%s' "$1" ;;
  esac
}
census_lower() {
  case "$1" in
    5) printf 'five' ;; 6) printf 'six' ;; 7) printf 'seven' ;; 8) printf 'eight' ;;
    9) printf 'nine' ;; 10) printf 'ten' ;; 11) printf 'eleven' ;;
    *) printf '%s' "$1" ;;
  esac
}
CENSUS_FILES="$(grep -rlF 'zensu:code-reviewer' "$PLUGIN_DIR/hooks" 2>/dev/null | wc -l | tr -d ' ')"
CENSUS_LINES="$(grep -rhF 'zensu:code-reviewer' "$PLUGIN_DIR/hooks" 2>/dev/null | wc -l | tr -d ' ')"
# The pinned count is stated in CLAUDE.md as prose and subtracted here. Pinning the prose
# literal keeps the two from drifting: add a fourth pin and this arm fails, instead of the
# check quietly enforcing a sentence that has become false.
CENSUS_PINNED=3
CENSUS_UNPINNED="$((CENSUS_FILES - CENSUS_PINNED))"
if [ "$(census_word "$CENSUS_FILES")" = "$CENSUS_FILES" ] || [ "$(census_lower "$CENSUS_UNPINNED")" = "$CENSUS_UNPINNED" ]; then
  check "T47pre the census word tables have no entry for $CENSUS_FILES / $CENSUS_UNPINNED — extend the table, the census itself may be fine" FAIL
fi
if [ "$CENSUS_FILES" -gt "$CENSUS_PINNED" ] \
  && grep -qF "three pinned (the lazy-require pair plus this one)" "$PLUGIN_DIR/CLAUDE.md" \
  && grep -qF "$(census_word "$CENSUS_FILES") files under \`hooks/\` ($CENSUS_LINES matching lines" "$PLUGIN_DIR/CLAUDE.md" \
  && grep -qF "the other $(census_lower "$CENSUS_UNPINNED") files are NOT pinned" "$PLUGIN_DIR/CLAUDE.md"; then
  check "T47 the CLAUDE.md carrier census matches the tree ($CENSUS_FILES files, $CENSUS_LINES lines)" PASS
else
  check "T47 the CLAUDE.md carrier census matches the tree ($CENSUS_FILES files, $CENSUS_LINES lines, unpinned=$CENSUS_UNPINNED)" FAIL
fi

# T60: the two INNER_REVIEW_HEADERS variants are HAND-PARALLEL and were pinned by
# nothing, so the content-matching clause landed on the standalone arm alone for a
# round. The bound arm is the one carrying three extra model-authored header lines,
# i.e. the highest formatting-slip exposure, so it is the arm that most needs it.
HEADER_CLAUSE="the ticket line is what binds the completion to this chain; the hook matches it by content anywhere in the prompt, so a formatting slip no longer strands the chain"
HEADER_VARIANTS="$(grep -c 'INNER_REVIEW_HEADERS=' "$STOP" || true)"
# CO-LOCATED, not merely co-resident. Counting the clause file-wide let any
# second occurrence on a NON-assignment line — a comment restating the contract,
# which is this file's house style — offset a variant that had lost it, so the
# one-sided placement T60 exists to catch would have passed. Both clauses sit on
# their assignment lines today, so the tightening is behaviour-preserving.
HEADER_CLAUSED="$(grep 'INNER_REVIEW_HEADERS=' "$STOP" | grep -cF -- "$HEADER_CLAUSE" || true)"
if [ "$HEADER_VARIANTS" -ge 2 ] && [ "$HEADER_CLAUSED" = "$HEADER_VARIANTS" ]; then
  check "T60 every INNER_REVIEW_HEADERS variant carries the content-matching clause ($HEADER_VARIANTS/$HEADER_VARIANTS)" PASS
else
  check "T60 every INNER_REVIEW_HEADERS variant carries the content-matching clause (variants=$HEADER_VARIANTS claused=$HEADER_CLAUSED)" FAIL
fi

# The three KNOWN BOUND notes. BOUND 2's remedy named a shared JS module, which is
# exactly as unreachable from the three POSIX-shell render sites as the shell
# constant is from JS. BOUND 3 shipped a hand-maintained roster of three files while
# nine under skills/ carry the identity — the census failure mode this repo already
# writes down for the sibling identity, one bound over. BOUND 0 is the ordering the
# roster missed entirely: a model that withholds the fan-out normally also withholds
# --tdd-complete, and stop-chain-enforcer.sh releases Stop unconditionally in that
# state, so neither render site is ever reached.
if grep -qF 'KNOWN BOUND 0' "$IN_SCOPE_OWNER" \
  && grep -qF 'KNOWN BOUND 0' "$PLUGIN_DIR/CLAUDE.md" \
  && grep -qF "grep -rn 'zensu:review-aspect' skills/" "$IN_SCOPE_OWNER" \
  && grep -qF 'a JS module is exactly as unreachable from' "$IN_SCOPE_OWNER"; then
  check "T48 the bound roster carries BOUND 0, a grep instruction, and no unreachable remedy" PASS
else
  check "T48 the bound roster carries BOUND 0, a grep instruction, and no unreachable remedy" FAIL
fi

# The observed gap this capture came from was NOT a detection failure: the
# session ran a plugin installation that predated this module entirely, so the
# probe's own guard returned before node was ever invoked and every Stop kept the
# ordinary directive. That is the intended fail-open direction and the reason
# /zensu:doctor stayed silent, so it is pinned here rather than left implicit.
# Structural, not behavioral: the functional bite needs a full plugin-tree copy
# this file's Windows budget cannot afford (same reason T33 is structural). What
# it catches is the guard being dropped or reordered below the invocation, which
# would turn a pre-module installation from silently undiagnosed into a probe
# that runs `node` on a path it has not shape-checked.
PROBE_SRC="$(awk '/^reviewer_spawn_denial_probe\(\) \{/,/^\}/' "$PLUGIN_DIR/hooks/stop-chain-enforcer.sh")"
PROBE_LIB_TEST="$(printf '%s' "$PROBE_SRC" | grep -n '\[ -f "\$lib" \]' | head -1 | cut -d: -f1)"
PROBE_NODE_CALL="$(printf '%s' "$PROBE_SRC" | grep -n 'node "\$lib"' | head -1 | cut -d: -f1)"
if [ -n "$PROBE_SRC" ] && [ -n "$PROBE_LIB_TEST" ] && [ -n "$PROBE_NODE_CALL" ] \
  && [ "$PROBE_LIB_TEST" -lt "$PROBE_NODE_CALL" ] \
  && printf '%s' "$PROBE_SRC" | grep -qF '[ -f "$lib" ] && [ ! -L "$lib" ] || return 0'; then
  check "T36b a plugin installation without the module fails open, before any node call" PASS
else
  check "T36b a plugin installation without the module fails open, before any node call" FAIL
fi

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
  local payload="$1" errfile="$2"
  payload="$(printf '%s' "$payload" | node -e 'const p=JSON.parse(require("fs").readFileSync(0,"utf8"));p.hook_event_name="Stop";process.stdout.write(JSON.stringify(p))')"
  printf '%s' "$payload" | bash "$STOP" 2>"$errfile" >/dev/null
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
# CAP is autoFixMaxRounds + 3, and hooks/lib/zensu-config.sh defaults that to 5;
# the release needs one Stop beyond it. Derived rather than hardcoded so a
# changed default fails loudly here instead of silently overshooting.
CAP_EXPECTED=$((5 + 3))
CAP_RUNS=0
while [ "$CAP_RUNS" -le "$CAP_EXPECTED" ]; do
  # The last run is the cap release. Retire the note first so the assertion
  # below observes THAT path's write and not one of the ordinary blocks.
  [ "$CAP_RUNS" -eq "$CAP_EXPECTED" ] && rm -f "$SIDECAR9"
  stop_run_err "$CAP_PAYLOAD" "$CAP_ERR"
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
  stop_run_err "$CAP13_PAYLOAD" "$CAP13_ERR"
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

# The marker set lives in the module. It is re-encoded exactly ONCE outside it —
# the remedy arms below — and the probe reads `kind` as a field instead of
# holding a second copy. Structural, because the functional bite needs a THIRD
# marker that does not exist: a module edit plus the full plugin-tree copy this
# file's Windows budget cannot afford. What it catches is the copy coming back,
# which is the regression that was actually there.
PROBE_BODY="$(awk '/^reviewer_spawn_denial_probe\(\) \{/,/^\}/' "$PLUGIN_DIR/hooks/stop-chain-enforcer.sh")"
REMEDY_BODY="$(awk '/^  case "\$REVIEWER_DENIAL_KIND" in/,/^  esac/' "$PLUGIN_DIR/hooks/stop-chain-enforcer.sh")"
if [ -n "$PROBE_BODY" ] \
  && ! printf '%s' "$PROBE_BODY" | grep -qF 'auto-mode-classifier' \
  && ! printf '%s' "$PROBE_BODY" | grep -qF 'permission-denied' \
  && printf '%s' "$PROBE_BODY" | grep -qF 'kind='; then
  check "T33 the probe reads kind as a field and holds no copy of the marker set" PASS
else
  check "T33 the probe reads kind as a field and holds no copy of the marker set" FAIL
fi
# The other half: deduplicating must not have taken the remedy arms with it. A
# probe that parses a kind nothing renders would be silently worse than the copy.
if [ -n "$REMEDY_BODY" ] \
  && printf '%s' "$REMEDY_BODY" | grep -qF 'auto-mode-classifier)' \
  && printf '%s' "$REMEDY_BODY" | grep -qF 'permission-denied)' \
  && printf '%s' "$REMEDY_BODY" | grep -qF '*)'; then
  check "T34 both marker kinds keep a remedy arm, and the unknown arm survives" PASS
else
  check "T34 both marker kinds keep a remedy arm, and the unknown arm survives" FAIL
fi

start_session "stop-routing-restore"

# T59 runs LAST among the real checks, and deliberately: it arms its OWN session, and
# `start_session` re-exports CLAUDE_PROJECT_DIR and the plugin-data root for that session.
# Placed earlier it silently re-pointed every later SID7B check at the wrong session — five
# checks went red at once for a reason none of them was about.
# T59 is the BEHAVIOURAL half of T58, and it is what makes that claim more than a literal
# grep. Every other config fixture in this file arrives through ZENSU_CONFIG, which
# short-circuits `cfg()` before the project overlay is consulted at all — so the overlay
# path, the one the export governs and the one `docs/configuration.md` documents as
# writable from inside a session, was exercised by nothing. Here the overlay is written
# under the RECORD's project root while the ambient CLAUDE_PROJECT_DIR points somewhere
# else, and ZENSU_CONFIG is unset. Both directions are asserted: the record root's overlay
# must win, and an overlay under the ambient root alone must NOT suppress the sentence.
T59_RAW="stop-scope-overlay"
start_session "$T59_RAW"
T59_SESSION="$STARTED_SESSION_KEY"
T59_PROJECT="$STARTED_PROJECT_ROOT"
bash "$LOG" --tdd-begin --session "$T59_SESSION" >/dev/null
bash "$LOG" --tdd-complete --session "$T59_SESSION" >/dev/null
T59_AMBIENT="$STATE_DIR/t59-ambient"
T59_HOME="$STATE_DIR/t59-home"
mkdir -p "$T59_AMBIENT/.zensu" "$T59_HOME" "$T59_PROJECT/.zensu"
# HOME is sandboxed because these are the only two runs in this file that remove the
# ZENSU_CONFIG sentinel: `cfg()` then falls back to $HOME/.zensu/config.json as the global
# base under the project overlay, so without this the check reads the developer's own file
# and can fail — or pass vacuously — for a reason that has nothing to do with the anchoring.
t59_run() {
  printf '%s' '{"session_id":"'"$T59_RAW"'","transcript_path":"'"$TRANSCRIPT_CLEAR"'","hook_event_name":"Stop"}' \
    | env -u ZENSU_CONFIG HOME="$T59_HOME" CLAUDE_PROJECT_DIR="$T59_AMBIENT" bash "$STOP" 2>/dev/null | reason
}
printf '%s\n' '{"hooks":{"reviewSpawnScopeSentence":false}}' > "$T59_PROJECT/.zensu/config.json"
T59_RECORD_OUT="$(t59_run)"
rm -f "$T59_PROJECT/.zensu/config.json"
printf '%s\n' '{"hooks":{"reviewSpawnScopeSentence":false}}' > "$T59_AMBIENT/.zensu/config.json"
T59_AMBIENT_OUT="$(t59_run)"
rm -f "$T59_AMBIENT/.zensu/config.json"
if printf '%s' "$T59_RECORD_OUT" | grep -qF 'Resume the /zensu:tdd Phase 6 review sequence' \
  && ! printf '%s' "$T59_RECORD_OUT" | grep -qF "$IN_SCOPE_NEEDLE" \
  && printf '%s' "$T59_AMBIENT_OUT" | grep -qF "$IN_SCOPE_NEEDLE"; then
  check "T59 the record root's config overlay governs the flag, the ambient root's does not" PASS
else
  check "T59 the record root's config overlay governs the flag, the ambient root's does not" FAIL
fi


echo "----"
echo "test-stop-enforcer-self-review-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
