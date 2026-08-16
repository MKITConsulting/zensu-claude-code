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
  UNIT_PASS="$(sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p;s/^. pass \([0-9][0-9]*\)$/\1/p' "$UNIT_OUT" | tail -1)"
  UNIT_TOTAL="$(sed -n 's/^# tests \([0-9][0-9]*\)$/\1/p;s/^. tests \([0-9][0-9]*\)$/\1/p' "$UNIT_OUT" | tail -1)"
  case "$UNIT_PASS" in ''|*[!0-9]*) UNIT_PASS=0 ;; esac
  case "$UNIT_TOTAL" in ''|*[!0-9]*) UNIT_TOTAL=0 ;; esac
  # The total is the real floor; the pass floor is lower because the symlink and
  # FIFO cases skip themselves where the platform cannot create one.
  if [ "$UNIT_TOTAL" -ge 29 ] && [ "$UNIT_PASS" -ge 27 ]; then
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
  && [ "$(printf '%s' "$REASON7" | grep -oF 'Session state: mode=' | wc -l | tr -d ' ')" -eq 1 ]; then
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
DOC_OUT="$(ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$SID9_PROJECT" \
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=unknown ZDOC_FORGE_CLI='' \
  ZDOC_FORGE_STATE='' ZDOC_PLAYWRIGHT=absent \
  node "$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js" 2>&1)"
case "$DOC_OUT" in
  *'host permission layer refused the zensu:code-reviewer spawn (auto-mode-classifier'*)
    check "T25 /zensu:doctor renders the note the hook itself wrote" PASS ;;
  *) check "T25 /zensu:doctor renders the note the hook itself wrote (got: $DOC_OUT)" FAIL ;;
esac

start_session "stop-routing-restore"

echo "----"
echo "test-stop-enforcer-self-review-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
