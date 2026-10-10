#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LEDGER_LIB="$PLUGIN_DIR/hooks/lib/review-ledger-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}
has() { case "$1" in *"$2"*) echo PASS ;; *) echo FAIL ;; esac; }
lacks() { case "$1" in *"$2"*) echo FAIL ;; *) echo PASS ;; esac; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

render_rounds() {
  local name="$1" config="$2" rounds="${3:-2}"
  mkdir -p "$TMP_DIR/$name/project/.zensu/state"
  printf '%s' "$config" > "$TMP_DIR/$name/config.json"
  (
    export CLAUDE_PROJECT_DIR="$TMP_DIR/$name/project"
    export ZENSU_CONFIG="$TMP_DIR/$name/config.json"
    SID="sess-convergence-$name"
    source "$BASELINE" "$SID" || exit 1
    bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
    bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
    for round in $(seq 1 "$rounds"); do
      TICKET="$(bash "$LOG" --review-ticket --session "$SID")"
      STDIN="{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET}\\nfixture\"},\"session_id\":\"${SID}\"}"
      printf '%s' "$STDIN" | "$SCRIPT" 2>/dev/null > "$TMP_DIR/$name/round-$round.json"
    done
  )
}

context_of() {
  node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      try {
        const parsed = JSON.parse(raw);
        const out = (parsed && parsed.hookSpecificOutput) || {};
        if (out.hookEventName !== "PostToolUse" || typeof out.additionalContext !== "string") process.exit(2);
        process.stdout.write(out.additionalContext);
      } catch (_) {
        process.exit(1);
      }
    });
  ' < "$1"
}

clause_of() {
  local rest="${1#*Review convergence (hooks.reviewConvergence is on).}"
  [ "$rest" = "$1" ] && return 1
  printf '%s' "${rest%%CONVERGENCE UNAVAILABLE — <reason>*}"
}

render_rounds on-all '{"hooks":{"autoFix":true,"autoFixIncludeSuggestions":true,"autoFixMaxRounds":5}}' &
render_rounds on-default '{"hooks":{"autoFix":true,"autoFixSeverity":"important","autoFixMaxRounds":5}}' &
render_rounds off-all '{"hooks":{"autoFix":true,"autoFixIncludeSuggestions":true,"reviewConvergence":false,"autoFixMaxRounds":5}}' &
render_rounds off-default '{"hooks":{"autoFix":true,"reviewConvergence":false,"autoFixMaxRounds":5}}' &
wait
render_rounds summary '{"hooks":{"autoFix":true,"selfReview":false,"autoFixMaxRounds":5}}' &
render_rounds summary-off '{"hooks":{"autoFix":true,"selfReview":false,"reviewConvergence":false,"autoFixMaxRounds":5}}' &
render_rounds max-rounds '{"hooks":{"autoFix":true,"autoFixMaxRounds":1}}' &
render_rounds max-rounds-off '{"hooks":{"autoFix":true,"selfReview":false,"autoFixMaxRounds":1}}' &
wait
render_rounds repro-off '{"hooks":{"autoFix":true,"criticalReproduction":false}}' &
render_rounds repro-fv-off '{"hooks":{"autoFix":true,"findingVerification":false}}' &
render_rounds one-round '{"hooks":{"autoFix":true}}' 3 &
render_rounds full-panel '{"hooks":{"autoFix":true,"reviewPanel":"full"}}' &
wait
render_rounds sev-all '{"hooks":{"autoFix":true,"autoFixSeverity":"all","autoFixMaxRounds":5}}' &
render_rounds sev-crit-legacy '{"hooks":{"autoFix":true,"autoFixSeverity":"critical","autoFixIncludeSuggestions":true}}' &
wait

ALL1="$(context_of "$TMP_DIR/on-all/round-1.json")" && check "V1 suggestions arm renders valid PostToolUse context at round 1" PASS \
  || check "V1 suggestions arm renders valid PostToolUse context at round 1" FAIL
ALL2="$(context_of "$TMP_DIR/on-all/round-2.json")" && check "V2 suggestions arm renders valid PostToolUse context at round 2" PASS \
  || check "V2 suggestions arm renders valid PostToolUse context at round 2" FAIL
DEF1="$(context_of "$TMP_DIR/on-default/round-1.json")" && check "V3 default arm renders valid PostToolUse context" PASS \
  || check "V3 default arm renders valid PostToolUse context" FAIL
OFF1="$(context_of "$TMP_DIR/off-all/round-1.json")" && check "V4 convergence-off render is valid PostToolUse context" PASS \
  || check "V4 convergence-off render is valid PostToolUse context" FAIL
SUM1="$(context_of "$TMP_DIR/summary/round-1.json")" && check "V5 combined-summary render is valid PostToolUse context" PASS \
  || check "V5 combined-summary render is valid PostToolUse context" FAIL
OFFD1="$(context_of "$TMP_DIR/off-default/round-1.json")" && check "V6 default-arm convergence-off render is valid PostToolUse context" PASS \
  || check "V6 default-arm convergence-off render is valid PostToolUse context" FAIL
SUMOFF1="$(context_of "$TMP_DIR/summary-off/round-1.json")" && check "V7 convergence-off combined-summary render is valid PostToolUse context" PASS \
  || check "V7 convergence-off combined-summary render is valid PostToolUse context" FAIL

check "C1 round 1 carries the convergence clause" "$(has "$ALL1" 'Review convergence (hooks.reviewConvergence is on)')"
check "C2 round 1 ledgers its findings under R1 ids" "$(has "$ALL1" "'FINDING LEDGER — R1-F<n> <routed|deferred|neutralized>")"
check "C3 round 1 numbers the next review R2" "$(has "$ALL1" 'R2-F1, R2-F2')"
check "C4 round 1 scopes the next review to fix round 1" "$(has "$ALL1" 'with --round 1 and node ')"
check "C5 round 1 names the ledger helper inside the project root" "$(has "$ALL1" 'review-ledger-v1.js --log {log_file} --root "$TOP"')"
check "C6 round 1 fails open with a disclosure" "$(has "$ALL1" "CONVERGENCE UNAVAILABLE — <reason>")"
check "C7 round 1 keeps Panel-FP and Unverified precedence" "$(has "$ALL1" 'Panel-FP and Unverified annotations take precedence')"
check "C8 round 1 records the original severity" "$(has "$ALL1" "the finding's original severity")"
check "C9 round 2 ledgers under R2 ids" "$(has "$ALL2" "'FINDING LEDGER — R2-F<n>")"
check "C10 round 2 numbers the next review R3" "$(has "$ALL2" 'R3-F1, R3-F2')"
check "C11 round 2 scopes the next review to fix round 2" "$(has "$ALL2" 'with --round 2 and node ')"
check "C12 no unexpanded round variable reaches the model" "$(lacks "$ALL2" '${NEXT')"
check "C13 no unexpanded plugin-root variable reaches the model" "$(lacks "$ALL1" '${CLAUDE_PLUGIN_ROOT}')"
check "C14 ledger text reaches the log verb only through a quoted heredoc" "$(has "$ALL1" '--message-stdin fed by a heredoc whose delimiter is quoted, so no finding text is ever shell-expanded, and never through --message')"
check "C15 a security paraphrase names only the class of weakness" "$(has "$ALL1" 'name only the class of weakness, never how to exploit it')"
check "C16 a line range is ledgered as its first line" "$(has "$ALL1" "write a line range as its first line and a finding without an anchor as '-'")"
check "C17 judge findings are numbered after the panel findings" "$(has "$ALL1" 'judge findings after the panel findings')"
check "C18 a still-open finding and its covers line take no new id" "$(has "$ALL1" "covers <panel-id>' line names, and that line itself, get no new line and no new id")"
check "C19 deferred findings are ledgered at classification time, before the review ticket" "$(has "$ALL1" 'Right after classifying, and before you issue the review ticket, append for every finding you retitled')"
check "C20 a neutralized line records the Panel-FP reason" "$(has "$ALL1" "a 'neutralized' line's paraphrase states the Panel-FP reason")"
check "C21 a refused ledger line is rewritten, never resent through a scan escape" "$(has "$ALL1" 'never resend the line with the zensu-secret-allow marker or ZENSU_SECRET_SCAN=off')"
check "C22 an IMPORTANT deferral is ledgered as parked" "$(has "$ALL1" "'parked' for an IMPORTANT finding, 'deferred' for every other")"
check "C23 a still-open IMPORTANT deferral parks the earlier id" "$(has "$ALL1" "deferring it as IMPORTANT appends 'parked' for that id")"
check "C24 the clause names the real log command with --message-stdin" "$(has "$ALL1" 'zensu-log.sh append --log {log_file} --message-stdin')"

for arm in ALL1 DEF1; do
  TEXT="${!arm}"
  check "R1 [$arm] classification runs only on two ok answers" "$(has "$TEXT" 'ONLY when both answer status=ok')"
  check "R2 [$arm] a CRITICAL finding stays routable" "$(has "$TEXT" 'A CRITICAL finding stays routable.')"
  check "R3 [$arm] an IMPORTANT finding routes only when judge-raised, not fixed or on edited code" "$(has "$TEXT" 'An IMPORTANT finding stays routable only when the zensu:review-judge raised it, when the judge tagged it [NOT FIXED]')"
  check "R4 [$arm] a deferred finding is exempt in every severity mode" "$(has "$TEXT" 'is exempt from fix routing in every severity mode, including autoFixIncludeSuggestions')"
  case "$TEXT" in
    *"Review convergence (hooks.reviewConvergence is on)."*"IMPL completed — files: {list}' claims"*"Your NEXT action must be the Agent tool"*)
      check "R8 [$arm] the clause precedes the fix-done sentence and the spawn instruction" PASS ;;
    *) check "R8 [$arm] the clause precedes the fix-done sentence and the spawn instruction" FAIL ;;
  esac
  check "R9 [$arm] the spawn instruction is followed by the backstop, not by the clause" "$(lacks "$TEXT" "REVIEW-TICKET: <ticket>'. Review convergence")"
done
CLAUSE_ALL="$(clause_of "$ALL1")"
CLAUSE_DEF="$(clause_of "$DEF1")"
if [ -n "$CLAUSE_ALL" ] && [ "$CLAUSE_ALL" = "$CLAUSE_DEF" ]; then
  check "R5 both arms render the same convergence clause" PASS
else
  check "R5 both arms render the same convergence clause" FAIL
fi
check "R6 with selfReview off every IMPORTANT finding stays routable" "$(has "$SUM1" 'An IMPORTANT finding stays routable, because hooks.selfReview is off')"
check "R7 with selfReview off no IMPORTANT finding is deferred" "$(lacks "$SUM1" 'An IMPORTANT finding stays routable only when')"

TEMPLATE_LOG="$TMP_DIR/template.log"
node -e '
  const text = process.argv[1];
  const m = /exactly in the form \x27(FINDING LEDGER[^\x27]*)\x27/.exec(text);
  if (!m) process.exit(1);
  const line = m[1]
    .replace("<n>", "1")
    .replace(/<([A-Za-z]+(?:\|[A-Za-z]+)+)>/g, (_, alts) => alts.split("|")[0])
    .replace("<path>:<line>", "src/a.ts:3")
    .replace("<paraphrase>", "filled from the rendered template");
  require("fs").writeFileSync(process.argv[2], line + "\n");
' "$ALL1" "$TEMPLATE_LOG" && TEMPLATE_OUT="$(node "$LEDGER_LIB" --log "$TEMPLATE_LOG" 2>&1)" || TEMPLATE_OUT=""
check "T1 a line written from the rendered template parses as a clean ledger" "$(has "$TEMPLATE_OUT" 'summary status=ok generation=1 entries=1 open=1')"

check "A1 suggestions arm closes a fully annotated round in case A" "$(has "$ALL1" "(A) Verdict PASS / zero findings, or every finding carries a do-not-fix annotation ('[Panel-FP-neutralized — do not fix]', '[Unverified — do not fix]' or '[Deferred — do not fix]')")"
check "A2 suggestions arm names the fully-annotated status line" "$(has "$ALL1" "'No critical/important findings — suggestions only' (case A, every finding annotated)")"
check "A3 suggestions arm lists the deferred annotation as an exception" "$(has "$ALL1" "items annotated '[Deferred — do not fix]' were deferred by review convergence")"
check "A4 suggestions arm keeps the Unverified exception wording" "$(has "$ALL1" "items annotated '[Unverified — do not fix]' failed the Finding Verification Gate")"
check "A5 suggestions arm still routes every unannotated severity" "$(has "$ALL1" 'Include EVERY finding the reviewer raised')"
check "A6 suggestions arm still shows the round counter" "$(has "$ALL2" 'round 2/5')"
check "A7 suggestions arm routes only findings without a do-not-fix annotation in case B" "$(has "$ALL1" '(B) ANY finding without a do-not-fix annotation present')"
check "A8 suggestions arm keeps the Panel-FP exception" "$(has "$ALL1" "items annotated '[Panel-FP-neutralized — do not fix]' are judged false positives")"

check "D1 default arm carries the same convergence clause" "$(has "$DEF1" 'Review convergence (hooks.reviewConvergence is on)')"
check "D2 default arm states the round in its fix status line" "$(has "$DEF1" "'Fixing critical+important findings in-thread, then re-reviewing (round 1/5)' (case C)")"
check "D3 default arm still excludes suggestions" "$(has "$DEF1" 'EXCLUDE all Suggestions')"
check "D4 default arm keeps its own case lettering" "$(lacks "$DEF1" 'or every finding carries a do-not-fix annotation')"

check "O1 convergence off drops the clause" "$(lacks "$OFF1" 'Review convergence')"
check "O2 convergence off writes no ledger instruction" "$(lacks "$OFF1" 'FINDING LEDGER')"
check "O3 convergence off keeps the fully-annotated close" "$(has "$OFF1" 'or every finding carries a do-not-fix annotation')"
check "O4 convergence off drops the clause from the default arm too" "$(lacks "$OFFD1" 'Review convergence')"
check "O5 the round claim prefix survives with convergence off" "$(has "$OFF1" "log this round's 'R1-{step_id} IMPL completed — files: {list}' claims")"
check "O6 the default arm prescribes the round claim prefix with convergence off" "$(has "$OFFD1" "log this round's 'R1-{step_id} IMPL completed — files: {list}' claims")"

check "S1 combined summary lists open ledger entries" "$(has "$SUM1" 'one row per open entry (state deferred, parked or routed-unfixed, under the id the ledger lists, a G<g>: prefix included)')"
check "S2 combined summary reads the ledger leniently" "$(has "$SUM1" 'review-ledger-v1.js --report --log {log_file} --root "$TOP" lists when it answers status=ok or status=partial')"
check "S3 combined summary never lists one finding twice" "$(has "$SUM1" 'never list one finding twice')"
check "S4 combined summary discloses a partial or unreadable ledger" "$(has "$SUM1" 'the row FINDINGS LEDGER PARTIAL — <reason> on status=partial and the row FINDINGS LEDGER UNAVAILABLE — <reason> on status=degraded')"
check "S5 convergence off drops the ledger rows from the combined summary" "$(lacks "$SUMOFF1" 'FINDINGS LEDGER')"
check "S6 convergence off never runs the ledger reader at chain end" "$(lacks "$SUMOFF1" 'review-ledger-v1.js')"
check "S7 convergence off keeps the pre-convergence ## Open sentence" "$(has "$SUMOFF1" 'One row per deferred suggestion (the buffered ### Suggestions block) or max-rounds finding requiring a manual fix, and one row per advisory FULL SUITE — line that did not pass, carrying that line verbatim. Every cell follows')"

MAX2="$(context_of "$TMP_DIR/max-rounds/round-2.json")" && check "V8 max-rounds hand-off render is valid PostToolUse context" PASS \
  || check "V8 max-rounds hand-off render is valid PostToolUse context" FAIL
MAXOFF2="$(context_of "$TMP_DIR/max-rounds-off/round-2.json")" && check "V9 max-rounds close render without self-review is valid PostToolUse context" PASS \
  || check "V9 max-rounds close render without self-review is valid PostToolUse context" FAIL
case "$MAX2" in
  *"FIRST, run the FULL test suite through the evidence runner, skipping it only when the newest full-suite record is already green on the current tree: "*"--evidence-run --scope full --if-stale"*"THEN your next action MUST be the Skill tool with skill='zensu:self-review'"*)
    check "MR1 the max-rounds hand-off runs the full suite before the self-review" PASS ;;
  *) check "MR1 the max-rounds hand-off runs the full suite before the self-review" FAIL ;;
esac
case "$MAXOFF2" in
  *"Before you reply, run the FULL test suite through the evidence runner, skipping it only when the newest full-suite record is already green on the current tree: "*"--evidence-run --scope full --if-stale"*"this run is the only full-suite measurement of the tree that ships"*)
    check "MR2 the max-rounds close without self-review runs the full suite before the reply" PASS ;;
  *) check "MR2 the max-rounds close without self-review runs the full suite before the reply" FAIL ;;
esac
ONE1="$(context_of "$TMP_DIR/one-round/round-1.json")"
ONE2="$(context_of "$TMP_DIR/one-round/round-2.json")"
RPOFF2="$(context_of "$TMP_DIR/repro-off/round-2.json")"
RPOFF1="$(context_of "$TMP_DIR/repro-off/round-1.json")"
RPFV1="$(context_of "$TMP_DIR/repro-fv-off/round-1.json")"
check "RP0 the default budget routes a fix round after the first review" "$(has "$ONE1" 'Review convergence (hooks.reviewConvergence is on)')"
ONE3="$(context_of "$TMP_DIR/one-round/round-3.json")"
check "RP0b the default budget routes a second fix round" "$(has "$ONE2" "'Fixing critical findings in-thread, then re-reviewing (round 2/2)' (case C)")"
check "RP0c the default budget hands the third review over at max rounds" "$(has "$ONE3" 'max 2 rounds reached')"
check "RP1 the default clause gates a re-review CRITICAL on a reproduction" "$(has "$ONE1" 'routes only after /zensu:tdd step 4c stage 3 reproduced it')"
check "RP2 the default hand-off names the reproduction rule for self-review" "$(has "$ONE3" 'is a self-review must-fix only when its FINDING REPRODUCTION line reads REPRODUCED')"
check "RP3 criticalReproduction off drops the rule from the clause" "$(lacks "$RPOFF1" 'FINDING REPRODUCTION')"
check "RP4 criticalReproduction off drops the rule from the hand-off" "$(lacks "$RPOFF2" 'FINDING REPRODUCTION')"
check "RP5 findingVerification off drops the rule, since stage 3 lives in that gate" "$(lacks "$RPFV1" 'FINDING REPRODUCTION')"
FULL1="$(context_of "$TMP_DIR/full-panel/round-1.json")"
check "LP1 the default fix round re-reviews with the lean panel" "$(has "$ONE1" 'aspect-activation-v1.js --panel lean --round re answers spawn')"
check "LP2 the default fix round keeps the judge for the full panel only" "$(has "$ONE1" 'only when hooks.reviewJudge is enabled and hooks.reviewPanel is full')"
check "LP3 reviewPanel full re-reviews with the full panel" "$(has "$FULL1" 'aspect-activation-v1.js --panel full --round re answers spawn')"
check "LP4 no unexpanded panel variable reaches the model" "$(lacks "$ONE1" '${PANEL}')"

SEVALL1="$(context_of "$TMP_DIR/sev-all/round-1.json")"
SEVCL1="$(context_of "$TMP_DIR/sev-crit-legacy/round-1.json")"
check "SV1 the default threshold is critical" "$(has "$ONE1" 'hooks.autoFixSeverity is critical: this loop fixes only Critical findings')"
check "SV2 case B parks IMPORTANT findings under the round's ids" "$(has "$ONE1" "exactly in the form 'FINDING LEDGER — R1-F<n> parked IMPORTANT <path>:<line> | <paraphrase>'")"
check "SV3 the clause form admits the parked state" "$(has "$ONE1" "'FINDING LEDGER — R1-F<n> <routed|deferred|neutralized|parked>")"
check "SV4 case C parks every IMPORTANT finding it leaves unfixed" "$(has "$ONE1" "'parked' for every IMPORTANT finding you leave unfixed, 'deferred' for every other finding you leave unfixed")"
check "SV5 a re-review never keeps an IMPORTANT finding routable" "$(has "$ONE1" 'An IMPORTANT finding never stays routable, because hooks.autoFixSeverity is critical')"
check "SV6 the judge exceptions are absent under critical" "$(lacks "$ONE1" 'An IMPORTANT finding stays routable only when')"
check "SV7 case C names the critical status line" "$(has "$ONE1" "'Fixing critical findings in-thread, then re-reviewing (round 1/2)' (case C)")"
check "SV8 case B names the parked status line" "$(has "$ONE1" "'No critical findings — important findings parked for /zensu:self-review' (case B)")"
check "SV9 case C lists only Critical findings" "$(has "$ONE1" 'List ONLY Critical findings. EXCLUDE all Important findings')"
check "SV10 an unavailable convergence fixes IMPORTANT findings too" "$(has "$ONE1" 'fixing its IMPORTANT findings with its CRITICAL ones because no ledger carries a parked finding to /zensu:self-review')"
check "SV11 the important arm keeps its own wording" "$(has "$DEF1" "'Fixing critical+important findings in-thread, then re-reviewing (round 1/5)' (case C)")"
check "SV12 the important arm carries no critical sentence" "$(lacks "$DEF1" 'hooks.autoFixSeverity is critical')"
check "SV13 convergence off falls back to the important arm" "$(has "$OFFD1" 'Fixing critical+important findings in-thread')"
check "SV14 selfReview off falls back to the important arm" "$(has "$SUM1" 'Fixing critical+important findings in-thread')"
check "SV15 autoFixSeverity all renders the suggestions arm" "$(has "$SEVALL1" 'Fixing all findings in-thread')"
check "SV16 an explicit critical beats the legacy key" "$(has "$SEVCL1" 'hooks.autoFixSeverity is critical')"
PARK_LOG="$TMP_DIR/park.log"
node -e '
  const m = /exactly in the form \x27(FINDING LEDGER — R1-F<n> parked[^\x27]*)\x27/.exec(process.argv[1]);
  if (!m) process.exit(1);
  const line = m[1].replace("<n>", "1").replace("<path>:<line>", "src/a.ts:3").replace("<paraphrase>", "filled from the park template");
  require("fs").writeFileSync(process.argv[2], line + "\n");
' "$ONE1" "$PARK_LOG" && PARK_OUT="$(node "$LEDGER_LIB" --log "$PARK_LOG" 2>&1)" || PARK_OUT=""
check "SV17 a parked line written from the rendered template parses as an open ledger entry" "$(has "$PARK_OUT" 'entry R1-F1 parked IMPORTANT src/a.ts:3')"

echo "----"
echo "test-review-convergence-directive: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
