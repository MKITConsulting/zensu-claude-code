#!/bin/bash
# Bound max-rounds handoff must preserve one immutable outcome and drive the
# outer run to audited BLOCKED, both with and without the self-review stage.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
POST="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d -t zensu-autopilot-post-max-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
source "$STATE_LIB"
# shellcheck disable=SC1090
source "$PHASE"

start_session() {
  local project="$1" raw_session="$2" label="$3"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data/$label"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session"
}

approve() {
  local project="$1" run="$2" owner="$3"
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null \
    && autopilot_apply_event "$run" "plan-${run}" PLAN_APPROVED \
      "{\"approvedPlanSha256\":\"$sha\"}" "$project" "$owner" >/dev/null
}
field_ok() {
  FILE="$1" EXPR="$2" node -e '
    try { const j=JSON.parse(require("fs").readFileSync(process.env.FILE,"utf8"));
      process.exit(Function("j",`return Boolean(${process.env.EXPR})`)(j)?0:1); }
    catch (_) { process.exit(1); }
  ' 2>/dev/null
}
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
directive() {
  FILE="$1" node -e '
    try {
      const j=JSON.parse(require("fs").readFileSync(process.env.FILE,"utf8"));
      process.stdout.write(String(j.hookSpecificOutput.additionalContext));
    } catch (_) { process.exit(1); }
  ' 2>/dev/null
}
record_count() {
  local n=0 f
  for f in "$CLAUDE_PLUGIN_DATA/evidence-run/v1/records/${ZENSU_SESSION_KEY:-missing}"/*.json; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
run_max_hook() {
  local project="$1" session="$2" raw_session="$3" cfg="$4" out="${5:-/dev/null}" state ticket payload context
  state="$(tdd_state_file "$session")" || return 1
  tdd_increment_counter "$session" reviewRound >/dev/null || return 1
  ticket="$(CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$LOG" --review-ticket --session "$session")" || return 1
  context="$(tdd_autopilot_context "$state" "$session")" || return 1
  payload="$(SID="$raw_session" TICKET="$ticket" CONTEXT="$context" node -e '
    const c=JSON.parse(process.env.CONTEXT);
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse",
      tool_name:"Agent",
      session_id:process.env.SID,
      tool_input:{
      subagent_type:"zensu:code-reviewer",
      prompt:`PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nZENSU-DELEGATED-CALLER: autopilot\nAUTOPILOT-BINDING: run=${c.runId} attempt=${c.attempt} chain=${c.chainId}\nAUTOPILOT-STAGE: ${c.returnStage}\nfixture`
    }}));
  ')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$POST" >"$out"
}

CFG_ON="$TMP/self-review-on.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1,"selfReview":true}}' >"$CFG_ON"
P1="$TMP/on"; mkdir -p "$P1"; R1=post_max_review_on; S1_RAW=post_max_session_on; C1=post-max-chain-on
start_session "$P1" "$S1_RAW" on || exit 1
S1="$ZENSU_SESSION_KEY"
approve "$P1" "$R1" "$S1" || exit 1
CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$LOG" --tdd-begin --session "$S1" \
  --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C1" >/dev/null
CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$LOG" --tdd-complete --session "$S1" \
  --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C1" >/dev/null
run_max_hook "$P1" "$S1" "$S1_RAW" "$CFG_ON"
TF1="$(tdd_state_file "$S1")"; RF1="$(autopilot_run_file "$R1" "$P1")"
if field_ok "$TF1" 'j.chainOutcome==="max-rounds"&&j.codeReviewDone===true&&j.chainDone===false' \
  && field_ok "$RF1" 'j.stage==="TDD_RUNNING"'; then
  check "M1 self-review handoff persists bound max-rounds without closing early" PASS
else check "M1 self-review handoff persists bound max-rounds without closing early" FAIL; fi
OUT1_STOP="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$S1_RAW\"}" \
  | CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$STOP" 2>/dev/null)"
if printf '%s' "$OUT1_STOP" | grep -qF "skill='zensu:self-review'" \
  && ! printf '%s' "$OUT1_STOP" | grep -qF 'nextActionCode=AWAIT_TDD_CHAIN' \
  && field_ok "$TF1" 'j.stopBlockCount===1&&j.chainOutcome==="max-rounds"&&j.codeReviewDone===true' \
  && field_ok "$RF1" 'j.stage==="TDD_RUNNING"&&j.stopBudget.count===0'; then
  check "M1b Stop accepts the exact max-round handoff and routes self-review" PASS
else check "M1b max-round handoff cannot fall back to AWAIT_TDD_CHAIN" FAIL; fi
T1="$(FILE="$TF1" node -e 'process.stdout.write(require(process.env.FILE).reviewTicket)')"
D1="$(digest "$TF1")"; I1="$(inode "$TF1")"
if tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 GATES "$C1" "$T1" \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" wrong_run 1 GATES "$C1" "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 2 GATES "$C1" "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 VALIDATE "$C1" "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 GATES wrong_chain "$T1" >/dev/null 2>&1 \
  && ! tdd_mark_autopilot_max_round_handoff "$S1" "$R1" 1 GATES "$C1" rt_wrong >/dev/null 2>&1 \
  && [ "$(digest "$TF1")" = "$D1" ] && [ "$(inode "$TF1")" = "$I1" ]; then
  check "M1a only the exact ticket and generation retry is an rc0 byte-stable no-op" PASS
else check "M1a max-round handoff exact retry contract" FAIL; fi

# A self-review may apply its one allowed fix before it owns the final
# --chain-done terminus. If that turn stops in between, the max-round handoff is
# still live and Stop must resume self-review rather than falling back to the
# Outer AWAIT_TDD_CHAIN action.
if tdd_mark_review_converged "$S1" "$T1" selfReviewFixed; then
  OUT1_FIXED_STOP="$(printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"$S1_RAW\"}" \
    | CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$STOP" 2>/dev/null)"
else
  OUT1_FIXED_STOP=""
fi
if printf '%s' "$OUT1_FIXED_STOP" | grep -qF "skill='zensu:self-review'" \
  && ! printf '%s' "$OUT1_FIXED_STOP" | grep -qF 'nextActionCode=AWAIT_TDD_CHAIN' \
  && field_ok "$TF1" \
    'j.chainOutcome==="max-rounds"&&j.codeReviewDone===true&&j.selfReviewFixed===true&&j.chainDone===false&&j.stopBlockCount===2' \
  && field_ok "$RF1" 'j.stage==="TDD_RUNNING"&&j.stopBudget.count===0'; then
  check "M1c Stop resumes terminal self-review after its one fix and before chainDone" PASS
else check "M1c max-round selfReviewFixed crash window cannot fall back to AWAIT_TDD_CHAIN" FAIL; fi

if CLAUDE_PROJECT_DIR="$P1" ZENSU_CONFIG="$CFG_ON" bash "$LOG" --chain-done --session "$S1" \
    --autopilot-run "$R1" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$C1" --claimed-review-ticket "$T1" >/dev/null 2>"$TMP/m2.err" \
  && grep -qF "CONVERGENCE — not converged | this session has no edit-landing receipt, so no run log is bound to this chain" "$TMP/m2.err" \
  && field_ok "$TF1" 'j.chainOutcome==="max-rounds"&&j.chainDone===true' \
  && field_ok "$RF1" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "M2 terminal self-review carries the immutable max outcome into outer BLOCKED" PASS
else check "M2 terminal self-review carries the immutable max outcome into outer BLOCKED" FAIL; fi

CFG_OFF="$TMP/self-review-off.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1,"selfReview":false}}' >"$CFG_OFF"
P2="$TMP/off"; mkdir -p "$P2"; R2=post_max_review_off; S2_RAW=post_max_session_off; C2=post-max-chain-off
start_session "$P2" "$S2_RAW" off || exit 1
S2="$ZENSU_SESSION_KEY"
approve "$P2" "$R2" "$S2" || exit 1
CLAUDE_PROJECT_DIR="$P2" ZENSU_CONFIG="$CFG_OFF" bash "$LOG" --tdd-begin --session "$S2" \
  --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$C2" >/dev/null
CLAUDE_PROJECT_DIR="$P2" ZENSU_CONFIG="$CFG_OFF" bash "$LOG" --tdd-complete --session "$S2" \
  --autopilot-run "$R2" --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id "$C2" >/dev/null
run_max_hook "$P2" "$S2" "$S2_RAW" "$CFG_OFF" "$TMP/off.out"
TF2="$(tdd_state_file "$S2")"; RF2="$(autopilot_run_file "$R2" "$P2")"
if field_ok "$TF2" 'j.chainOutcome==="max-rounds"&&j.chainDone===true' \
  && field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "M3 no-self-review path closes inner and outer max-rounds atomically" PASS
else check "M3 no-self-review path closes inner and outer max-rounds atomically" FAIL; fi
D2="$(directive "$TMP/off.out")"
if printf '%s' "$D2" | grep -qF "Before you reply, run the FULL test suite through the evidence runner, skipping it only when the newest full-suite record is already green on the current tree: " \
  && printf '%s' "$D2" | grep -qF -- "--evidence-run --scope full --if-stale --cmd '<full test command>' --log <run log> (drop --cmd when evidence.fullSuiteCommand is configured). Fix rounds re-run only their own scoped suites and no terminus gate follows here, so this run is the only full-suite measurement of the tree that ships. Reply with" \
  && ! printf '%s' "$D2" | grep -qF -- "--cmd 'cd " \
  && ! printf '%s' "$D2" | grep -qF 'Do NOT run a closing suite'; then
  check "M6a a bound chain that works in the anchor keeps its close-suite sentence, with no cd" PASS
else
  check "M6a a bound chain that works in the anchor keeps its close-suite sentence, with no cd" FAIL
  printf '%s\n' "$D2" | head -c 3000; echo
fi
if [ -n "$D2" ] && ! printf '%s' "$D2" | grep -qF 'NEXT, ledger this final review' \
  && ! printf '%s' "$D2" | grep -qF 'returns to its Autopilot stage as converged'; then
  check "M3a the bound close without self-review carries no final-review ledger step and no outcome rule" PASS
else check "M3a the bound close without self-review carries no final-review ledger step and no outcome rule" FAIL; fi

# Simulate a process crash immediately after the ticket claim. Recovery has
# only the atomically returned binding and must be able to land outcome plus
# codeReviewDone in one exact, retry-safe inner CAS.
P3="$TMP/crash"; mkdir -p "$P3"
S3_RAW=post_max_crash_session; R3=post_max_crash_run; C3=post-max-crash-chain
start_session "$P3" "$S3_RAW" crash || exit 1
S3="$ZENSU_SESSION_KEY"
tdd_begin_session "$S3" false true false "" "$R3" 3 VALIDATE "$C3" >/dev/null
T3="$(tdd_issue_review_ticket "$S3")"
CLAIM3="$(tdd_consume_review_ticket_context "$S3" "$T3" 2>/dev/null)"
TF3="$(tdd_state_file "$S3")"
if [ -n "$CLAIM3" ] \
  && CLAIM="$CLAIM3" node -e '
    const value=JSON.parse(process.env.CLAIM);
    process.exit(value.next===1 && value.autopilot
      && value.autopilot.runId==="post_max_crash_run"
      && value.autopilot.attempt===3
      && value.autopilot.returnStage==="VALIDATE"
      && value.autopilot.chainId==="post-max-crash-chain"
      && value.autopilot.outcome==="" ? 0 : 1);
  ' \
  && field_ok "$TF3" 'j.reviewTicketConsumed===true&&j.chainOutcome===""&&j.codeReviewDone===false' \
  && tdd_mark_autopilot_max_round_handoff "$S3" "$R3" 3 VALIDATE "$C3" "$T3" \
  && field_ok "$TF3" 'j.chainOutcome==="max-rounds"&&j.codeReviewDone===true&&j.chainDone===false&&j.selfReviewFixed===false'; then
  D3="$(digest "$TF3")"; I3="$(inode "$TF3")"
  if tdd_mark_autopilot_max_round_handoff "$S3" "$R3" 3 VALIDATE "$C3" "$T3" \
    && [ "$(digest "$TF3")" = "$D3" ] && [ "$(inode "$TF3")" = "$I3" ]; then
    check "M4 crash-after-claim recovery atomically hands off and exact retry is stable" PASS
  else check "M4 crash recovery retry stability" FAIL; fi
else check "M4 crash-after-claim recovery atomic handoff" FAIL; fi

D3H="$(digest "$TF3")"
if ! tdd_set_chain_outcome "$S3" converged "$R3" 3 "$C3" "$T3" >/dev/null 2>&1 \
  && ! tdd_finish_autopilot_chain "$S3" "$R3" 3 "$C3" converged >/dev/null 2>&1 \
  && [ "$(digest "$TF3")" = "$D3H" ] \
  && tdd_finish_autopilot_chain "$S3" "$R3" 3 "$C3" converged "$T3" \
  && field_ok "$TF3" 'j.chainOutcome==="converged"&&j.chainDone===true&&j.codeReviewDone===true' \
  && D3C="$(digest "$TF3")" \
  && tdd_finish_autopilot_chain "$S3" "$R3" 3 "$C3" converged "$T3" \
  && [ "$(digest "$TF3")" = "$D3C" ] \
  && ! tdd_finish_autopilot_chain "$S3" "$R3" 3 "$C3" max-rounds "$T3" >/dev/null 2>&1; then
  check "M4a only the ticket-bound finish seals a max-rounds handoff as converged, and its exact retry is stable" PASS
else check "M4a only the ticket-bound finish seals a max-rounds handoff as converged, and its exact retry is stable" FAIL; fi

P3F="$TMP/fresh"; mkdir -p "$P3F"
S3F_RAW=post_max_fresh_session; R3F=post_max_fresh_run; C3F=post-max-fresh-chain
start_session "$P3F" "$S3F_RAW" fresh || exit 1
S3F="$ZENSU_SESSION_KEY"
tdd_begin_session "$S3F" false true false "" "$R3F" 2 GATES "$C3F" >/dev/null
T3F="$(tdd_issue_review_ticket "$S3F")"
tdd_consume_review_ticket_context "$S3F" "$T3F" >/dev/null 2>&1
TF3F="$(tdd_state_file "$S3F")"
D3F="$(digest "$TF3F")"
if field_ok "$TF3F" 'j.reviewTicketConsumed===true&&j.chainOutcome===""&&j.codeReviewDone===false' \
  && ! tdd_finish_autopilot_chain "$S3F" "$R3F" 2 "$C3F" converged "$T3F" >/dev/null 2>&1 \
  && [ "$(digest "$TF3F")" = "$D3F" ]; then
  check "M4b a chain without a max-rounds handoff can never be sealed as converged" PASS
else check "M4b a chain without a max-rounds handoff can never be sealed as converged" FAIL; fi

if grep -q 'tdd_mark_autopilot_max_round_handoff' "$POST" \
  && ! grep -q 'tdd_set_chain_outcome' "$POST" \
  && grep -q -- '--outcome max-rounds' "$POST"; then
  check "M5 hook uses atomic handoff for self-review and direct bound finish without it" PASS
else check "M5 max-round hook wiring is free of split outcome writes" FAIL; fi

wt_anchor() {
  local anchor="$1" name="$2" sub="${3:-}" base
  base="$anchor${sub:+/$sub}"
  mkdir -p "$base" && git -C "$anchor" init -q || return 1
  git -C "$anchor" config user.email t@example.invalid
  git -C "$anchor" config user.name tester
  printf '.zensu/\n.session-control-test/\n%s.claude/worktrees/\n' "${sub:+$sub/}" >"$anchor/.gitignore"
  printf 'baseline\n' >"$base/tracked.txt"
  git -C "$anchor" add .gitignore "${sub:+$sub/}tracked.txt" \
    && git -C "$anchor" -c commit.gpgsign=false commit -qm baseline \
    && git -C "$anchor" worktree add -q "$base/.claude/worktrees/$name" -b max-wt >/dev/null 2>&1
}
wt_arm() {
  local anchor="$1" workspace="$2" raw="$3" label="$4" run="$5" chain="$6"
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  start_session "$anchor" "$raw" "$label" || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$anchor" false true "$workspace" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-${run}" PLAN_APPROVED \
    "{\"approvedPlanSha256\":\"$sha\"}" "$anchor" "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  CLAUDE_PROJECT_DIR="$anchor" ZENSU_CONFIG="$CFG_OFF" bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" \
    --autopilot-run "$run" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1 || return 1
  CLAUDE_PROJECT_DIR="$anchor" ZENSU_CONFIG="$CFG_OFF" bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" \
    --autopilot-run "$run" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1
}
closed_blocked() {
  field_ok "$(tdd_state_file "$1")" 'j.chainOutcome==="max-rounds"&&j.chainDone===true' \
    && field_ok "$(autopilot_run_file "$2" "$3")" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'
}

P6="$TMP/wt-run"
wt_anchor "$P6" wt
P6="$(cd -P "$P6" 2>/dev/null && pwd -P)"
WT6="$(cd -P "$P6/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
WT6_NATIVE="$(bash "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$WT6" 2>/dev/null)"
R6=post_max_wt_run; S6_RAW=post_max_wt_session; C6=post-max-wt-chain
if [ -n "$WT6" ] && wt_arm "$P6" "$WT6" "$S6_RAW" wt "$R6" "$C6"; then
  S6="$ZENSU_SESSION_KEY"
  run_max_hook "$P6" "$S6" "$S6_RAW" "$CFG_OFF" "$TMP/wt.out"
  D6="$(directive "$TMP/wt.out")"
  if [ -n "$WT6_NATIVE" ] \
    && printf '%s' "$D6" | grep -qF -- "--evidence-run --scope scoped --if-stale --cmd 'cd \"$WT6_NATIVE\" && <full test command>' --log <run log>" \
    && printf '%s' "$D6" | grep -qF 'Keep the leading cd: this hook has already closed the chain' \
    && ! printf '%s' "$D6" | grep -qF -- '--evidence-run --scope full' \
    && ! printf '%s' "$D6" | grep -qF 'Do NOT run a closing suite' \
    && closed_blocked "$S6" "$R6" "$P6"; then
    check "M6 a bound chain in a nested worktree gets a closing run with a leading cd into it, and the outer run is BLOCKED" PASS
  else
    check "M6 a bound chain in a nested worktree gets a closing run with a leading cd into it, and the outer run is BLOCKED" FAIL
    printf '%s\n' "$D6" | head -c 3000; echo
  fi

  FLAG6H="$(A="$D2" B="$D6" W="$WT6_NATIVE" node -e '
    const cmd = (s) => { const m = String(s || "").match(/Before you reply, [^\n]*?( --evidence-run [^\n]*? --log <run log>)/); return m ? m[1] : null; };
    const a = cmd(process.env.A), b = cmd(process.env.B);
    if (!a || !b) { process.stdout.write("missing"); process.exit(0); }
    const want = a.replace(" --scope full ", " --scope scoped ").replace(" --cmd \x27", " --cmd \x27cd \"" + process.env.W + "\" && ");
    process.stdout.write(want === b ? "equal" : "differ");
  ' 2>/dev/null)"
  if [ "$FLAG6H" = equal ]; then
    check "M6h the local worktree arm runs the shared full-suite step's command with --scope scoped and the leading cd" PASS
  else
    check "M6h the local worktree arm runs the shared full-suite step's command with --scope scoped and the leading cd ($FLAG6H)" FAIL
  fi

  PREFIX6="$(D="$D6" node -e '
    const m=process.env.D.match(/--cmd \x27(cd "[^"]*" && )<full test command>\x27/);
    if (!m) process.exit(1);
    process.stdout.write(m[1]);
  ' 2>/dev/null)"
  OUT6="$(cd "$P6" && bash "$LOG" --evidence-run --scope scoped --cmd "${PREFIX6}pwd -P" 2>/dev/null)"; RC6=$?
  (cd "$P6" && bash "$LOG" --evidence-run --scope scoped --cmd "${PREFIX6}true" >/dev/null 2>&1)
  SKIP6="$(cd "$P6" && bash "$LOG" --evidence-run --scope scoped --if-stale --cmd "${PREFIX6}true" 2>/dev/null)"
  BEFORE6="$(record_count)"
  printf 'edited in the worktree\n' >"$WT6/tracked.txt"
  (cd "$P6" && bash "$LOG" --evidence-run --scope scoped --if-stale --cmd "${PREFIX6}true" >/dev/null 2>&1)
  AFTER6="$(record_count)"
  git -C "$WT6" checkout -q -- tracked.txt
  if [ -n "$PREFIX6" ] && [ "$RC6" -eq 0 ] && printf '%s\n' "$OUT6" | grep -qxF "$WT6" \
    && printf '%s' "$SKIP6" | grep -qF 'skipped (--if-stale)' && [ "$AFTER6" -eq $((BEFORE6 + 1)) ]; then
    check "M6b the directed command, run from the anchor after the terminus, runs in the worktree and an edit there makes it stale" PASS
  else
    check "M6b the directed command runs in the worktree and an edit there makes it stale (rc=$RC6 before=$BEFORE6 after=$AFTER6)" FAIL
    printf '%s\n' "$OUT6" "$SKIP6"
  fi
else
  check "M6 arm a bound chain whose run drives a worktree below the anchor" FAIL
fi

P7="$TMP/wt-fault"
wt_anchor "$P7" wt
P7="$(cd -P "$P7" 2>/dev/null && pwd -P)"
WT7="$(cd -P "$P7/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
R7=post_max_fault_run; S7_RAW=post_max_fault_session; C7=post-max-fault-chain
if [ -n "$WT7" ] && wt_arm "$P7" "$WT7" "$S7_RAW" fault "$R7" "$C7"; then
  S7="$ZENSU_SESSION_KEY"
  BAD_WS="$P7/missing-worktree" node -e '
    const fs=require("fs"); const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    s.workspaceRoot=process.env.BAD_WS; fs.writeFileSync(process.argv[1], JSON.stringify(s,null,2)+"\n");
  ' "$(autopilot_run_file "$R7" "$P7")"
  run_max_hook "$P7" "$S7" "$S7_RAW" "$CFG_OFF" "$TMP/fault.out"
  D7="$(directive "$TMP/fault.out")"
  if printf '%s' "$D7" | grep -qF "Do NOT run a closing suite: this chain's work tree could not be resolved before this hook closed the chain, and the evidence runner now treats the closed chain as a standalone one, so a run would measure the anchor instead of the tree that ships. Say in your reply that no closing suite ran, and why." \
    && ! printf '%s' "$D7" | grep -qF 'Before you reply, ' \
    && closed_blocked "$S7" "$R7" "$P7"; then
    check "M6c a work tree the hook cannot resolve gets no closing run, and the terminus still moves the outer run to BLOCKED" PASS
  else
    check "M6c a work tree the hook cannot resolve gets no closing run, and the terminus still moves the outer run to BLOCKED" FAIL
    printf '%s\n' "$D7" | head -c 3000; echo
  fi
else
  check "M6c arm a bound chain whose run drives a worktree below the anchor" FAIL
fi

P8="$TMP/wt-quote"
wt_anchor "$P8" "q'wt"
P8="$(cd -P "$P8" 2>/dev/null && pwd -P)"
WT8="$(cd -P "$P8/.claude/worktrees/q'wt" 2>/dev/null && pwd -P)"
R8=post_max_quote_run; S8_RAW=post_max_quote_session; C8=post-max-quote-chain
if [ -n "$WT8" ] && wt_arm "$P8" "$WT8" "$S8_RAW" quote "$R8" "$C8"; then
  S8="$ZENSU_SESSION_KEY"
  run_max_hook "$P8" "$S8" "$S8_RAW" "$CFG_OFF" "$TMP/quote.out"
  D8="$(directive "$TMP/quote.out")"
  if printf '%s' "$D8" | grep -qF "Do NOT run a closing suite: the path of this chain's work tree holds a quote, a dollar sign, a backtick, a backslash or a control character, which the runner command cannot carry, and the evidence runner now treats the closed chain as a standalone one" \
    && ! printf '%s' "$D8" | grep -qF -- "--cmd 'cd " \
    && closed_blocked "$S8" "$R8" "$P8"; then
    check "M6d a worktree path with a single quote gets no closing run, and the terminus still moves the outer run to BLOCKED" PASS
  else
    check "M6d a worktree path with a single quote gets no closing run, and the terminus still moves the outer run to BLOCKED" FAIL
    printf '%s\n' "$D8" | head -c 3000; echo
  fi
else
  check "M6d arm a bound chain whose run drives a worktree whose path holds a single quote" FAIL
fi

P9="$TMP/wt-render"
wt_anchor "$P9" wt sub
P9="$(cd -P "$P9/sub" 2>/dev/null && pwd -P)"
WT9="$(cd -P "$P9/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
R9=post_max_render_run; S9_RAW=post_max_render_session; C9=post-max-render-chain
if [ -n "$P9" ] && [ -n "$WT9" ] && wt_arm "$P9" "$WT9" "$S9_RAW" render "$R9" "$C9" \
  && mv "$WT9/sub" "$WT9/sub-real" && ln -s sub-real "$WT9/sub" 2>/dev/null; then
  if [ ! -L "$WT9/sub" ]; then
    echo "  SKIP  M6f this host's ln -s made no symbolic link, so a linked project directory cannot be built"
  else
    S9="$ZENSU_SESSION_KEY"
    run_max_hook "$P9" "$S9" "$S9_RAW" "$CFG_OFF" "$TMP/render.out"
    D9="$(directive "$TMP/render.out")"
    if printf '%s' "$D9" | grep -qF "Do NOT run a closing suite: the path of this chain's work tree could not be rendered in the native spelling the evidence runner reads, and the evidence runner now treats the closed chain as a standalone one" \
      && ! printf '%s' "$D9" | grep -qF -- "--cmd 'cd " \
      && closed_blocked "$S9" "$R9" "$P9"; then
      check "M6f a project directory in the worktree that has no native spelling gets no closing run, and the terminus still moves the outer run to BLOCKED" PASS
    else
      check "M6f a project directory in the worktree that has no native spelling gets no closing run, and the terminus still moves the outer run to BLOCKED" FAIL
      printf '%s\n' "$D9" | head -c 3000; echo
    fi
  fi
else
  check "M6f arm a bound chain in a subdirectory project whose worktree directory becomes a symbolic link" FAIL
fi

P10="$TMP/wt-dollar"
wt_anchor "$P10" wt sub/app
P10="$(cd -P "$P10/sub/app" 2>/dev/null && pwd -P)"
WT10="$(cd -P "$P10/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
R10=post_max_dollar_run; S10_RAW=post_max_dollar_session; C10=post-max-dollar-chain
if [ -n "$P10" ] && [ -n "$WT10" ] && wt_arm "$P10" "$WT10" "$S10_RAW" dollar "$R10" "$C10" \
  && mv "$WT10/sub" "$WT10/d\$x" && ln -s 'd$x' "$WT10/sub" 2>/dev/null; then
  if [ ! -L "$WT10/sub" ]; then
    echo "  SKIP  M6g this host's ln -s made no symbolic link, so a linked middle directory cannot be built"
  else
    S10="$ZENSU_SESSION_KEY"
    run_max_hook "$P10" "$S10" "$S10_RAW" "$CFG_OFF" "$TMP/dollar.out"
    D10="$(directive "$TMP/dollar.out")"
    if printf '%s' "$D10" | grep -qF "Do NOT run a closing suite: the path of this chain's work tree holds a quote, a dollar sign, a backtick, a backslash or a control character, which the runner command cannot carry, and the evidence runner now treats the closed chain as a standalone one" \
      && ! printf '%s' "$D10" | grep -qF -- "--cmd 'cd " \
      && closed_blocked "$S10" "$R10" "$P10"; then
      check "M6g a rendered work directory that gains a dollar sign through a linked middle directory gets no closing run, and the outer run is BLOCKED" PASS
    else
      check "M6g a rendered work directory that gains a dollar sign through a linked middle directory gets no closing run, and the outer run is BLOCKED" FAIL
      printf '%s\n' "$D10" | head -c 3000; echo
    fi
  fi
else
  check "M6g arm a bound chain whose project directory in the worktree sits below a directory that becomes a symbolic link" FAIL
fi

NEEDLE6E="--evidence-run --scope scoped --if-stale --cmd 'cd \\\"\${MAX_CLOSE_NATIVE}\\\" && "
CI6E="cd \\\"\${MAX_CLOSE_NATIVE}\\\" && <the Phase 6 affected-suite command>' --log <run log>\""
RENDER6E='MAX_CLOSE_NATIVE="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "$MAX_CLOSE_DIR" 2>/dev/null)"'
SCREEN6E="*\"'\"*|*'\"'*|*'\$'*|*'\`'*|*'\\'*|*[[:cntrl:]]*)"
if [ "$(grep -cF -- "$NEEDLE6E" "$POST")" -eq 2 ] && [ "$(grep -cF -- "$CI6E" "$POST")" -eq 1 ] \
  && [ "$(grep -cF -- "$RENDER6E" "$POST")" -eq 1 ] \
  && [ "$(grep -cF -- "$SCREEN6E" "$POST")" -eq 1 ] \
  && [ "$(grep -cF -- 'case "$MAX_CLOSE_NATIVE" in' "$POST")" -eq 1 ] \
  && ! grep -qF -- 'cd \"${MAX_CLOSE_DIR}\"' "$POST"; then
  check "M6e both runner variants of the bound closing run carry --scope scoped and a leading cd into the screened native spelling" PASS
else check "M6e both runner variants of the bound closing run carry --scope scoped and a leading cd into the screened native spelling" FAIL; fi

CFG_CV_OFF="$TMP/convergence-off.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1,"selfReview":true,"reviewConvergence":false}}' >"$CFG_CV_OFF"
LEDGER_ROUTED='FINDING LEDGER — R1-F1 routed IMPORTANT src/a.ts:3 | null guard missing'
LEDGER_FIXED='FINDING LEDGER — R1-F1 fixed IMPORTANT src/a.ts:3 | null guard missing'
LEDGER_DEFERRED='FINDING LEDGER — R2-F1 deferred SUGGESTION src/b.ts:4 | helper name is vague'
LEDGER_PARKED='FINDING LEDGER — R2-F2 parked IMPORTANT src/c.ts:9 | retry loop has no bound'
LEDGER_FINAL='FINAL REVIEW LEDGERED — R2'
conv_arm() {
  local project="$1" raw="$2" label="$3" run="$4" chain="$5" cfg="$6"
  mkdir -p "$project" || return 1
  start_session "$project" "$raw" "$label" || return 1
  approve "$project" "$run" "$ZENSU_SESSION_KEY" || return 1
  CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" \
    --autopilot-run "$run" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1 || return 1
  CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" \
    --autopilot-run "$run" --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1
}
conv_ledger() {
  local session="$1" claims="$2" clean="$3" receipt
  shift 3
  receipt="$(tdd_edit_landing_receipt "$session")" || return 1
  mkdir -p "$(dirname "$receipt")" "$CLAUDE_PROJECT_DIR/.zensu/logs" || return 1
  printf '%s\n' "$@" >"$CLAUDE_PROJECT_DIR/.zensu/logs/converge.log" \
    && printf '{"schema":"edit-landing-v2","log":".zensu/logs/converge.log","claims":%s,"clean":%s}\n' \
      "$claims" "$clean" >"$receipt"
}
conv_done() {
  local project="$1" session="$2" run="$3" chain="$4" cfg="$5" err="$6" ticket
  shift 6
  ticket="$(FILE="$(tdd_state_file "$session")" node -e 'process.stdout.write(String(require(process.env.FILE).reviewTicket || ""))' 2>/dev/null)"
  [ -n "$ticket" ] || return 9
  CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" bash "$LOG" --chain-done --session "$session" \
    --autopilot-run "$run" --autopilot-attempt 1 --autopilot-return-stage GATES \
    --chain-id "$chain" --claimed-review-ticket "$ticket" "$@" >/dev/null 2>"$err"
}

P11="$TMP/converge"; R11=post_max_converge_run; S11_RAW=post_max_converge_session; C11=post-max-converge-chain
if conv_arm "$P11" "$S11_RAW" converge "$R11" "$C11" "$CFG_ON"; then
  S11="$ZENSU_SESSION_KEY"
  run_max_hook "$P11" "$S11" "$S11_RAW" "$CFG_ON" "$TMP/converge.out"
  D11="$(directive "$TMP/converge.out")"
  ORDER11="$(D="$D11" node -e '
    const d=process.env.D;
    const a=d.indexOf("NEXT, ledger this final review: ");
    const b=d.indexOf("THEN your next action MUST be the Skill tool with skill=\x27zensu:self-review\x27");
    process.stdout.write(a>=0&&b>a?"ordered":"unordered");
  ' 2>/dev/null)"
  if printf '%s' "$D11" | grep -qF "because fix rounds re-run only their own scoped suites. NEXT, ledger this final review: " \
    && printf '%s' "$D11" | grep -qF "'FINDING LEDGER — R2-F<n> <routed|deferred> <CRITICAL|IMPORTANT|SUGGESTION> <path>:<line> | <paraphrase>'" \
    && printf '%s' "$D11" | grep -qF -- "--message-stdin" \
    && printf '%s' "$D11" | grep -qF "This attempt returns to its Autopilot stage as converged only when the self-review terminus finds no routed-unfixed or parked entry and no deferred IMPORTANT or CRITICAL entry in that ledger; otherwise it closes as max-rounds and the run blocks with TDD_MAX_ROUNDS." \
    && printf '%s' "$D11" | grep -qF "The terminus prints that decision as one 'CONVERGENCE — …' line with its reason; carry it verbatim into the final report's How I built it line." \
    && printf '%s' "$D11" | grep -qF "For every '[STILL OPEN] <ledger-id> covers <panel-id>' line whose panel finding is CRITICAL or IMPORTANT, append 'FINDING LEDGER — <ledger-id> parked <that severity> <path>:<line> | <paraphrase>' instead, so the earlier entry becomes a must-fix candidate." \
    && printf '%s' "$D11" | grep -qF "Then append the line 'FINAL REVIEW LEDGERED — R2', also when this review needed no ledger line: without it the terminus closes this attempt as max-rounds." \
    && printf '%s' "$D11" | grep -qF "A converged close still has to pass the edit-landing and full-suite gates. A refusal that names a command to run, a record to wait for or an audit to repeat keeps the attempt open: do that, then run the terminus again. When a gate refuses for a cause only an edit can remove, such as a failed full suite, and the attempt has no fix round left, run the terminus again with --outcome max-rounds, which closes it as max-rounds and blocks the run with TDD_MAX_ROUNDS; the How I built it line then marks the converged verdict as refused by a gate." \
    && printf '%s' "$D11" | grep -qF "The code-reviewer loop is closed for this attempt (codeReviewDone)." \
    && ! printf '%s' "$D11" | grep -qF "The code-reviewer chain is marked converged" \
    && [ "$ORDER11" = ordered ]; then
    check "M7 the bound max-rounds hand-off asks for the final review's ledger lines before self-review and states the outcome rule" PASS
  else
    check "M7 the bound max-rounds hand-off asks for the final review's ledger lines before self-review and states the outcome rule ($ORDER11)" FAIL
    printf '%s\n' "$D11" | head -c 3000; echo
  fi
  TF11="$(tdd_state_file "$S11")"; RF11="$(autopilot_run_file "$R11" "$P11")"
  conv_ledger "$S11" 1 false "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED" "$LEDGER_FINAL"
  conv_done "$P11" "$S11" "$R11" "$C11" "$CFG_ON" "$TMP/m7a.err"; RC11A=$?
  if [ "$RC11A" -eq 1 ] && grep -qF "CONVERGENCE — converged | " "$TMP/m7a.err" \
    && grep -qF "CONVERGED CLOSE — the edit-landing and full-suite gates below still decide this close. A refusal that names a command to run, a record to wait for or an audit to repeat keeps this attempt open: do that, then run this --chain-done again. When a gate refuses for a cause only an edit can remove, such as a failed full suite, and this attempt has no fix round left, run this --chain-done again with --outcome max-rounds" "$TMP/m7a.err" \
    && grep -qF "the chain stays open; re-run the edit-landing audit" "$TMP/m7a.err" \
    && field_ok "$TF11" 'j.chainOutcome==="max-rounds"&&j.chainDone===false' \
    && field_ok "$RF11" 'j.stage==="TDD_RUNNING"'; then
    check "M7a a converged attempt still meets the edit-landing gate, which keeps the chain open and names the convergence verdict" PASS
  else
    check "M7a a converged attempt still meets the edit-landing gate, which keeps the chain open and names the convergence verdict (rc=$RC11A)" FAIL
    cat "$TMP/m7a.err"
  fi
  conv_ledger "$S11" 0 true "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED" "$LEDGER_FINAL"
  conv_done "$P11" "$S11" "$R11" "$C11" "$CFG_ON" "$TMP/m7b.err"; RC11B=$?
  if [ "$RC11B" -eq 0 ] \
    && grep -qF "CONVERGENCE — converged | the findings ledger holds no routed-unfixed or parked entry and no deferred IMPORTANT or CRITICAL entry (2 entries, 1 deferred suggestion still open)" "$TMP/m7b.err" \
    && ! grep -qF "FULL SUITE — not checked | outcome max-rounds" "$TMP/m7b.err" \
    && field_ok "$TF11" 'j.chainOutcome==="converged"&&j.chainDone===true' \
    && field_ok "$RF11" 'j.stage==="GATES"&&j.tdd.outcome==="converged"'; then
    check "M7b a converged max-rounds attempt passes the gates and returns the outer run to its return stage" PASS
  else
    check "M7b a converged max-rounds attempt passes the gates and returns the outer run to its return stage (rc=$RC11B)" FAIL
    cat "$TMP/m7b.err"
  fi
  DT11="$(digest "$TF11")"; DR11="$(digest "$RF11")"
  conv_done "$P11" "$S11" "$R11" "$C11" "$CFG_ON" "$TMP/m7c.err"; RC11C=$?
  if [ "$RC11C" -eq 0 ] && ! grep -qF "CONVERGENCE — " "$TMP/m7c.err" \
    && [ "$(digest "$TF11")" = "$DT11" ] && [ "$(digest "$RF11")" = "$DR11" ]; then
    check "M7c a terminus retry after the converged seal reads the sealed outcome, decides nothing again and changes no state" PASS
  else
    check "M7c a terminus retry after the converged seal reads the sealed outcome, decides nothing again and changes no state (rc=$RC11C)" FAIL
    cat "$TMP/m7c.err"
  fi
  conv_done "$P11" "$S11" "$R11" "$C11" "$CFG_ON" "$TMP/m7d.err" --outcome max-rounds; RC11D=$?
  if [ "$RC11D" -ne 0 ] && [ "$(digest "$TF11")" = "$DT11" ] && [ "$(digest "$RF11")" = "$DR11" ] \
    && field_ok "$RF11" 'j.stage==="GATES"&&j.tdd.outcome==="converged"'; then
    check "M7d an explicit --outcome max-rounds after the converged seal is refused and changes no state" PASS
  else
    check "M7d an explicit --outcome max-rounds after the converged seal is refused and changes no state (rc=$RC11D)" FAIL
    cat "$TMP/m7d.err"
  fi
else
  check "M7 arm a bound chain with self-review on" FAIL
fi

P12="$TMP/converge-open"; R12=post_max_open_run; S12_RAW=post_max_open_session; C12=post-max-open-chain
if conv_arm "$P12" "$S12_RAW" open "$R12" "$C12" "$CFG_ON"; then
  S12="$ZENSU_SESSION_KEY"
  run_max_hook "$P12" "$S12" "$S12_RAW" "$CFG_ON"
  TF12="$(tdd_state_file "$S12")"; RF12="$(autopilot_run_file "$R12" "$P12")"
  conv_ledger "$S12" 0 true "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED" "$LEDGER_PARKED" "$LEDGER_FINAL"
  DT12="$(digest "$TF12")"; DR12="$(digest "$RF12")"
  conv_done "$P12" "$S12" "$R12" "$C12" "$CFG_ON" "$TMP/m8a.err" --outcome converged; RC12A=$?
  if [ "$RC12A" -eq 2 ] && grep -qF -- "--outcome converged is refused" "$TMP/m8a.err" \
    && [ "$(digest "$TF12")" = "$DT12" ] && [ "$(digest "$RF12")" = "$DR12" ]; then
    check "M8 a caller cannot request the converged outcome, and the refusal changes no state" PASS
  else
    check "M8 a caller cannot request the converged outcome, and the refusal changes no state (rc=$RC12A)" FAIL
    cat "$TMP/m8a.err"
  fi
  M8S_OK=true; M8S_RC=""
  for M8S_VALUE in $'converged\t' $'converged\n' ' converged' CONVERGED bogus; do
    conv_done "$P12" "$S12" "$R12" "$C12" "$CFG_ON" "$TMP/m8s.err" --outcome "$M8S_VALUE"; M8S_ONE=$?
    M8S_RC="$M8S_RC $M8S_ONE"
    if [ "$M8S_ONE" -ne 2 ] || ! grep -qF -- "--outcome must be pass, no-changes or max-rounds." "$TMP/m8s.err" \
      || [ "$(digest "$TF12")" != "$DT12" ] || [ "$(digest "$RF12")" != "$DR12" ]; then
      M8S_OK=false
    fi
  done
  if [ "$M8S_OK" = true ]; then
    check "M8s every other spelling of --outcome, a converged with a tab or newline included, is refused before any state is read" PASS
  else
    check "M8s every other spelling of --outcome, a converged with a tab or newline included, is refused before any state is read (rc:$M8S_RC)" FAIL
  fi
  conv_done "$P12" "$S12" "$R12" "$C12" "$CFG_ON" "$TMP/m8b.err"; RC12B=$?
  if [ "$RC12B" -eq 0 ] \
    && grep -qF "CONVERGENCE — not converged | the findings ledger holds 1 open defect: R2-F2 parked IMPORTANT" "$TMP/m8b.err" \
    && field_ok "$TF12" 'j.chainOutcome==="max-rounds"&&j.chainDone===true' \
    && field_ok "$RF12" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"&&j.tdd.outcome==="max-rounds"'; then
    check "M8a a parked IMPORTANT entry keeps the attempt max-rounds and the run BLOCKED with TDD_MAX_ROUNDS" PASS
  else
    check "M8a a parked IMPORTANT entry keeps the attempt max-rounds and the run BLOCKED with TDD_MAX_ROUNDS (rc=$RC12B)" FAIL
    cat "$TMP/m8b.err"
  fi
else
  check "M8 arm a bound chain with self-review on" FAIL
fi

P13="$TMP/converge-explicit"; R13=post_max_explicit_run; S13_RAW=post_max_explicit_session; C13=post-max-explicit-chain
if conv_arm "$P13" "$S13_RAW" explicit "$R13" "$C13" "$CFG_ON"; then
  S13="$ZENSU_SESSION_KEY"
  run_max_hook "$P13" "$S13" "$S13_RAW" "$CFG_ON"
  conv_ledger "$S13" 0 true "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED" "$LEDGER_FINAL"
  conv_done "$P13" "$S13" "$R13" "$C13" "$CFG_ON" "$TMP/m9.err" --outcome max-rounds; RC13=$?
  if [ "$RC13" -eq 0 ] && ! grep -qF "CONVERGENCE — " "$TMP/m9.err" \
    && closed_blocked "$S13" "$R13" "$P13"; then
    check "M9 an explicit --outcome max-rounds skips the convergence check and blocks the run" PASS
  else
    check "M9 an explicit --outcome max-rounds skips the convergence check and blocks the run (rc=$RC13)" FAIL
    cat "$TMP/m9.err"
  fi
else
  check "M9 arm a bound chain with self-review on" FAIL
fi

P14="$TMP/converge-off"; R14=post_max_cvoff_run; S14_RAW=post_max_cvoff_session; C14=post-max-cvoff-chain
if conv_arm "$P14" "$S14_RAW" cvoff "$R14" "$C14" "$CFG_CV_OFF"; then
  S14="$ZENSU_SESSION_KEY"
  run_max_hook "$P14" "$S14" "$S14_RAW" "$CFG_CV_OFF" "$TMP/cvoff.out"
  D14="$(directive "$TMP/cvoff.out")"
  conv_ledger "$S14" 0 true "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED" "$LEDGER_FINAL"
  conv_done "$P14" "$S14" "$R14" "$C14" "$CFG_CV_OFF" "$TMP/m10.err"; RC14=$?
  if printf '%s' "$D14" | grep -qF "THEN your next action MUST be the Skill tool with skill='zensu:self-review'" \
    && ! printf '%s' "$D14" | grep -qF 'NEXT, ledger this final review' \
    && [ "$RC14" -eq 0 ] \
    && grep -qF "CONVERGENCE — not converged | hooks.reviewConvergence is off, so no findings ledger records what the reviews left open" "$TMP/m10.err" \
    && closed_blocked "$S14" "$R14" "$P14"; then
    check "M10 with hooks.reviewConvergence off the hand-off asks for no ledger and the attempt still blocks as max-rounds" PASS
  else
    check "M10 with hooks.reviewConvergence off the hand-off asks for no ledger and the attempt still blocks as max-rounds (rc=$RC14)" FAIL
    cat "$TMP/m10.err"
  fi
else
  check "M10 arm a bound chain with hooks.reviewConvergence off" FAIL
fi

P15="$TMP/converge-escape"; R15=post_max_escape_run; S15_RAW=post_max_escape_session; C15=post-max-escape-chain
if conv_arm "$P15" "$S15_RAW" escape "$R15" "$C15" "$CFG_ON"; then
  S15="$ZENSU_SESSION_KEY"
  run_max_hook "$P15" "$S15" "$S15_RAW" "$CFG_ON"
  conv_ledger "$S15" 1 false "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED" "$LEDGER_FINAL"
  conv_done "$P15" "$S15" "$R15" "$C15" "$CFG_ON" "$TMP/m11a.err"; RC15A=$?
  conv_done "$P15" "$S15" "$R15" "$C15" "$CFG_ON" "$TMP/m11b.err" --outcome max-rounds; RC15B=$?
  if [ "$RC15A" -eq 1 ] && grep -qF "CONVERGED CLOSE — " "$TMP/m11a.err" \
    && [ "$RC15B" -eq 0 ] && ! grep -qF "CONVERGENCE — " "$TMP/m11b.err" \
    && grep -qF 'When such a stop follows a `CONVERGED CLOSE — …` line, rerun with `--outcome max-rounds` instead.' "$PLUGIN_DIR/skills/self-review/SKILL.md" \
    && grep -qF 'marked as refused by a gate after an `--outcome max-rounds` rerun.' "$PLUGIN_DIR/skills/self-review/SKILL.md" \
    && ! grep -qF 'After a `CONVERGED CLOSE — …` line, rerun' "$PLUGIN_DIR/skills/self-review/SKILL.md" \
    && closed_blocked "$S15" "$R15" "$P15"; then
    check "M11 a converged close that a pass gate refuses leaves through --outcome max-rounds, which blocks the run with TDD_MAX_ROUNDS, and the self-review takes that exit only from a stop and marks the converged verdict as refused" PASS
  else
    check "M11 a converged close that a pass gate refuses leaves through --outcome max-rounds, which blocks the run with TDD_MAX_ROUNDS, and the self-review takes that exit only from a stop and marks the converged verdict as refused (rc=$RC15A/$RC15B)" FAIL
    cat "$TMP/m11a.err" "$TMP/m11b.err"
  fi
else
  check "M11 arm a bound chain with self-review on" FAIL
fi

P16="$TMP/converge-unmarked"; R16=post_max_unmarked_run; S16_RAW=post_max_unmarked_session; C16=post-max-unmarked-chain
if conv_arm "$P16" "$S16_RAW" unmarked "$R16" "$C16" "$CFG_ON"; then
  S16="$ZENSU_SESSION_KEY"
  run_max_hook "$P16" "$S16" "$S16_RAW" "$CFG_ON"
  conv_ledger "$S16" 0 true "$LEDGER_ROUTED" "$LEDGER_FIXED" "$LEDGER_DEFERRED"
  conv_done "$P16" "$S16" "$R16" "$C16" "$CFG_ON" "$TMP/m12.err"; RC16=$?
  if [ "$RC16" -eq 0 ] \
    && grep -qF "CONVERGENCE — not converged | no 'FINAL REVIEW LEDGERED — R2' line follows the last review budget reset" "$TMP/m12.err" \
    && ! grep -qF "CONVERGED CLOSE — " "$TMP/m12.err" \
    && closed_blocked "$S16" "$R16" "$P16"; then
    check "M12 a final review that never reached the ledger keeps the attempt max-rounds and the run BLOCKED with TDD_MAX_ROUNDS" PASS
  else
    check "M12 a final review that never reached the ledger keeps the attempt max-rounds and the run BLOCKED with TDD_MAX_ROUNDS (rc=$RC16)" FAIL
    cat "$TMP/m12.err"
  fi
else
  check "M12 arm a bound chain with self-review on" FAIL
fi

seal_converged() {
  local session="$1" run="$2" chain="$3" ticket
  ticket="$(FILE="$(tdd_state_file "$session")" node -e 'process.stdout.write(String(require(process.env.FILE).reviewTicket || ""))' 2>/dev/null)"
  [ -n "$ticket" ] || return 9
  tdd_finish_autopilot_chain "$session" "$run" 1 "$chain" converged "$ticket" >/dev/null 2>&1 || return 1
  printf '%s\n' "$ticket"
}

P17="$TMP/converge-reconcile"; R17=post_max_reconcile_run; S17_RAW=post_max_reconcile_session; C17=post-max-reconcile-chain
if conv_arm "$P17" "$S17_RAW" reconcile "$R17" "$C17" "$CFG_ON"; then
  S17="$ZENSU_SESSION_KEY"
  run_max_hook "$P17" "$S17" "$S17_RAW" "$CFG_ON"
  TF17="$(tdd_state_file "$S17")"; RF17="$(autopilot_run_file "$R17" "$P17")"
  T17="$(seal_converged "$S17" "$R17" "$C17")"
  DT17="$(digest "$TF17")"
  RECONCILED17=false
  if [ -n "$T17" ] && field_ok "$RF17" 'j.stage==="TDD_RUNNING"' \
    && autopilot_reconcile_stop_active "$P17" "$S17" >/dev/null 2>&1; then
    RECONCILED17=true
  fi
  if [ "$RECONCILED17" = true ] \
    && field_ok "$RF17" 'j.stage==="GATES"&&j.tdd.outcome==="converged"' \
    && field_ok "$TF17" 'j.chainOutcome==="converged"&&j.chainDone===true' \
    && [ "$(digest "$TF17")" = "$DT17" ]; then
    check "M13 the Stop reconcile completes a converged inner seal the outer run missed and returns the run to its stage" PASS
  else
    check "M13 the Stop reconcile completes a converged inner seal the outer run missed and returns the run to its stage (ticket='$T17' reconciled=$RECONCILED17)" FAIL
  fi
else
  check "M13 arm a bound chain with self-review on" FAIL
fi

P18="$TMP/converge-rearm"; R18=post_max_rearm_run; S18_RAW=post_max_rearm_session; C18=post-max-rearm-chain
if conv_arm "$P18" "$S18_RAW" rearm "$R18" "$C18" "$CFG_ON"; then
  S18="$ZENSU_SESSION_KEY"
  run_max_hook "$P18" "$S18" "$S18_RAW" "$CFG_ON"
  TF18="$(tdd_state_file "$S18")"; RF18="$(autopilot_run_file "$R18" "$P18")"
  T18="$(seal_converged "$S18" "$R18" "$C18")"
  DT18="$(digest "$TF18")"
  RC18=9
  [ -n "$T18" ] && { autopilot_rearm_review "$R18" "$P18" "$S18" 1 "$C18" "$T18" >/dev/null 2>&1; RC18=$?; }
  if [ "$RC18" -eq 3 ] \
    && field_ok "$RF18" 'j.stage==="GATES"&&j.tdd.outcome==="converged"' \
    && field_ok "$TF18" 'j.chainOutcome==="converged"&&j.chainDone===true' \
    && [ "$(digest "$TF18")" = "$DT18" ]; then
    check "M14 a review rearm over a converged inner seal completes the outer transition and refuses to rearm" PASS
  else
    check "M14 a review rearm over a converged inner seal completes the outer transition and refuses to rearm (rc=$RC18)" FAIL
  fi
else
  check "M14 arm a bound chain with self-review on" FAIL
fi

echo "----"; echo "test-autopilot-post-review-max-rounds: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
