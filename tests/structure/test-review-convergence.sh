#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LEDGER_LIB="$ROOT/hooks/lib/review-ledger-v1.js"
SCOPE_LIB="$ROOT/hooks/lib/review-round-scope-v1.js"
LEDGER_UNIT="$ROOT/tests/structure/review-ledger-v1.test.js"
LOG_WRITER="$ROOT/hooks/lib/zensu-log.sh"
. "$(dirname "$0")/lib-unit-summary.sh"

RUBRIC_DOC="$ROOT/docs/review-severity.md"
ASPECT_MD="$ROOT/agents/review-aspect.md"
JUDGE_MD="$ROOT/agents/review-judge.md"
REVIEWER_MD="$ROOT/agents/code-reviewer.md"
TDD_MD="$ROOT/skills/tdd/SKILL.md"
SELF_REVIEW_MD="$ROOT/skills/self-review/SKILL.md"
RESET_MD="$ROOT/skills/reset-review-limit/SKILL.md"
DELEGATE="$ROOT/hooks/post-review-tdd-delegate.sh"
CONFIG_EX="$ROOT/config.example.json"
CONFIG_DOC="$ROOT/docs/configuration.md"
CHAIN_DOC="$ROOT/docs/review-chain.md"
ARCH_DOC="$ROOT/docs/architecture.md"
WORKFLOW_DOC="$ROOT/docs/tdd-manager-workflow.md"
EVAL="$ROOT/evals/config-gate/test-review-convergence-directive.sh"
EVAL_RUNNER="$ROOT/evals/config-gate/run-eval.sh"
MANIFEST="$ROOT/tests/profiles/promptfoo-local-only.v1.json"
OVERVIEW_MD="$ROOT/tests/SUITE-OVERVIEW.md"

PASS=0; FAIL=0
check() {
  if [ "$#" -ne 2 ]; then
    printf '  FAIL  check() called with %s arguments, expected 2 — %s\n' "$#" "${1:-}"
    FAIL=$((FAIL+1)); return 0
  fi
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}
grep_ok() { grep -qF -- "$2" "$1" && echo PASS || echo FAIL; }
grep_absent() { grep -qF -- "$2" "$1" && echo FAIL || echo PASS; }
finish() {
  echo "----"
  echo "test-review-convergence: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
}

for f in "$LEDGER_LIB" "$SCOPE_LIB" "$LEDGER_UNIT" "$LOG_WRITER" "$RUBRIC_DOC" "$ASPECT_MD" "$JUDGE_MD" \
         "$REVIEWER_MD" "$TDD_MD" "$SELF_REVIEW_MD" "$RESET_MD" "$DELEGATE" "$CONFIG_EX" "$CONFIG_DOC" \
         "$CHAIN_DOC" "$ARCH_DOC" "$WORKFLOW_DOC" "$EVAL" "$EVAL_RUNNER" "$MANIFEST" "$OVERVIEW_MD"; do
  if [ ! -f "$f" ]; then
    check "R0 required file exists: $f" FAIL
    finish
  fi
done
if ! command -v node >/dev/null 2>&1; then
  check "R0a node is available" FAIL
  finish
fi

LEDGER_OUT="$(cd "$ROOT" && node --test "$LEDGER_UNIT" 2>&1)"
LEDGER_RC=$?
[ "$LEDGER_RC" -eq 0 ] && check "R1 review-ledger unit suite passes ($(unit_cases_report_text "$LEDGER_OUT"))" PASS \
                       || check "R1 review-ledger unit suite passes" FAIL
unit_cases_registered_floor_text "$LEDGER_OUT" 42 \
  && check "R1a review-ledger unit suite registers its cases ($UNIT_CASES_TESTS)" PASS \
  || check "R1a review-ledger unit suite registers its cases ($UNIT_CASES_TESTS)" FAIL
CELL="$(sed -n 's/^| `review-ledger-v1.test.js` | \([0-9][0-9]*\) |.*/\1/p' "$OVERVIEW_MD" | head -1)"
if [ -n "$CELL" ] && [ "$CELL" = "$UNIT_CASES_TESTS" ]; then
  check "R1b the SUITE-OVERVIEW Blocks cell equals the registered count (cell=$CELL)" PASS
else
  check "R1b the SUITE-OVERVIEW Blocks cell equals the registered count (cell=${CELL:-<none>} registered=$UNIT_CASES_TESTS)" FAIL
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zensu-rcv-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
printf 'FINDING LEDGER — R1-F1 routed IMPORTANT src/a.ts:3 | missing guard\n' > "$TMP/ok.log"
printf 'FINDING LEDGER — R1-F1 routed MAJOR src/a.ts:3 | bad severity\n' > "$TMP/malformed.log"
printf 'FINDING LEDGER — R2-F1 routed IMPORTANT src/a.ts:3 | two\nFINDING LEDGER — R1-F1 routed IMPORTANT src/b.ts:3 | one\n' > "$TMP/regression.log"
printf 'FINDING LEDGER — R2-F1 routed IMPORTANT src/a.ts:3 | two\nREVIEW BUDGET RESET\nFINDING LEDGER — R1-F1 routed IMPORTANT src/b.ts:3 | one\n' > "$TMP/reset.log"

OUT="$(cd "$ROOT" && node "$LEDGER_LIB" --log "$TMP/ok.log" 2>&1)"; RC=$?
case "$OUT" in
  *"summary status=ok generation=1 entries=1 open=1"*) [ "$RC" -eq 0 ] && check "R2 a valid ledger answers ok through the CLI" PASS \
                                                        || check "R2 a valid ledger answers ok through the CLI" FAIL ;;
  *) check "R2 a valid ledger answers ok through the CLI" FAIL ;;
esac
for bad in malformed regression absent; do
  OUT="$(cd "$ROOT" && node "$LEDGER_LIB" --log "$TMP/$bad.log" 2>&1)"; RC=$?
  case "$OUT" in
    *"status=ok"*) check "R3 an unusable ledger never answers ok [$bad]" FAIL ;;
    *"status=degraded"*) [ "$RC" -eq 0 ] && check "R3 an unusable ledger never answers ok [$bad]" PASS \
                                          || check "R3 an unusable ledger never answers ok [$bad] (exit $RC)" FAIL ;;
    *) check "R3 an unusable ledger never answers ok [$bad]" FAIL ;;
  esac
done
OUT="$(cd "$ROOT" && node "$LEDGER_LIB" --report --log "$TMP/malformed.log" 2>&1)"
case "$OUT" in
  *"summary status=partial"*"reason=malformed-line"*) check "R3a the report read answers partial where the routing read degrades" PASS ;;
  *) check "R3a the report read answers partial where the routing read degrades" FAIL ;;
esac
OUT="$(cd "$ROOT" && node "$LEDGER_LIB" --log "$TMP/reset.log" 2>&1)"
case "$OUT" in
  *"generation=2 entries=1"*) check "R4 a REVIEW BUDGET RESET line starts a fresh generation" PASS ;;
  *) check "R4 a REVIEW BUDGET RESET line starts a fresh generation" FAIL ;;
esac
printf 'R1-F1 IMPL completed — files: src/old.ts\nREVIEW BUDGET RESET\nR1-F1 IMPL completed — files: src/new.ts\n' > "$TMP/scope.log"
OUT="$(cd "$ROOT" && node "$SCOPE_LIB" --log "$TMP/scope.log" --round 1 2>&1)"
case "$OUT" in
  *"file src/old.ts"*) check "R5 the round-scope helper drops claims before the reset marker" FAIL ;;
  *"file src/new.ts"*) check "R5 the round-scope helper drops claims before the reset marker" PASS ;;
  *) check "R5 the round-scope helper drops claims before the reset marker" FAIL ;;
esac

WR_HOME="$TMP/home"
WR_PROJ="$TMP/proj"
mkdir -p "$WR_HOME" "$WR_PROJ/.zensu/logs" "$WR_PROJ/src"
WR_PROJ="$(cd "$WR_PROJ" && pwd -P)"
WR_LOG="$WR_PROJ/.zensu/logs/2026-01-01-0000_tdd-ledger.log"
( cd "$WR_PROJ" && HOME="$WR_HOME" CLAUDE_PROJECT_DIR="$WR_PROJ" \
    bash "$LOG_WRITER" append --truncate --log "$WR_LOG" \
    --message "FINDING LEDGER — R1-F1 routed IMPORTANT ${WR_PROJ}/src/a.ts:3 | written through the production append verb" >/dev/null 2>&1 )
( cd "$WR_PROJ" && HOME="$WR_HOME" CLAUDE_PROJECT_DIR="$WR_PROJ" \
    bash "$LOG_WRITER" append --log "$WR_LOG" \
    --message "FINDING LEDGER — R1-F1 fixed IMPORTANT ${WR_PROJ}/src/a.ts:3 | guard added" >/dev/null 2>&1 )
check "R5a the production writer redacts the ledger anchor to the project placeholder" "$(grep_ok "$WR_LOG" '<project>/src/a.ts:3')"
OUT="$(cd "$ROOT" && node "$LEDGER_LIB" --log "$WR_LOG" --root "$WR_PROJ" 2>&1)"
case "$OUT" in
  *"entry R1-F1 fixed IMPORTANT src/a.ts:3 | guard added"*"summary status=ok generation=1 entries=1 open=0"*)
    check "R5b a ledger written by the production writer parses back to a repo-relative anchor" PASS ;;
  *) check "R5b a ledger written by the production writer parses back to a repo-relative anchor" FAIL ;;
esac

RUBRIC_BLOCK="$(awk '/^<!-- zensu:review-severity -->$/{f=1} f{print} /^<!-- \/zensu:review-severity -->$/{if(f) exit}' "$RUBRIC_DOC")"
if [ -n "$RUBRIC_BLOCK" ] && [ "$(grep -cxF '<!-- zensu:review-severity -->' "$RUBRIC_DOC")" = 1 ]; then
  check "R6 the canonical rubric block exists exactly once" PASS
else
  check "R6 the canonical rubric block exists exactly once" FAIL
fi
for agent in "$ASPECT_MD" "$JUDGE_MD" "$REVIEWER_MD"; do
  AGENT_BLOCK="$(awk '/^<!-- zensu:review-severity -->$/{f=1} f{print} /^<!-- \/zensu:review-severity -->$/{if(f) exit}' "$agent")"
  if [ -n "$RUBRIC_BLOCK" ] && [ "$AGENT_BLOCK" = "$RUBRIC_BLOCK" ] \
     && [ "$(grep -cxF '<!-- zensu:review-severity -->' "$agent")" = 1 ]; then
    check "R7 $(basename "$agent") carries the rubric block byte-identically" PASS
  else
    check "R7 $(basename "$agent") carries the rubric block byte-identically" FAIL
  fi
done
for needle in '**CRITICAL** — blocks the merge' '**IMPORTANT** — should land before the merge' '**SUGGESTION** — optional'; do
  case "$RUBRIC_BLOCK" in
    *"$needle"*) check "R8 the rubric block defines [$needle]" PASS ;;
    *) check "R8 the rubric block defines [$needle]" FAIL ;;
  esac
done
for needle in 'When IMPORTANT and SUGGESTION both fit, choose SUGGESTION unless the evidence shows the higher impact' \
              'when CRITICAL and IMPORTANT both fit, choose CRITICAL'; do
  case "$RUBRIC_BLOCK" in
    *"$needle"*) check "R8b the rubric tie-break reads [$needle]" PASS ;;
    *) check "R8b the rubric tie-break reads [$needle]" FAIL ;;
  esac
done
check "R8a the rubric intro states the selfReview-off routing" "$(grep_ok "$RUBRIC_DOC" 'off it keeps every IMPORTANT finding routable')"
check "R8c the rubric intro keeps judge-raised IMPORTANT findings routable" "$(grep_ok "$RUBRIC_DOC" 'judge raised, tagged `[NOT FIXED]` or cited on code the previous')"

check "R9 the judge accepts an optional findings_ledger" "$(grep_ok "$JUDGE_MD" 'Optional: `findings_ledger`')"
check "R10 the judge rules ledger re-raises as Panel-FP" "$(grep_ok "$JUDGE_MD" 'rule it `Panel-FP: ledger <id>`')"
check "R11 the judge reports fixes that do not hold" "$(grep_ok "$JUDGE_MD" 'tagged `[NOT FIXED] <id>`')"
check "R11a the judge names a re-raised open entry instead of repeating it" "$(grep_ok "$JUDGE_MD" 'report `[STILL OPEN] <id> covers <panel-id>`')"
check "R11b the judge's no-repeat rule admits the covers form" "$(grep_ok "$JUDGE_MD" 'a `covers <panel-id>` line names one instead of repeating it')"
check "R10a the judge judges a CRITICAL re-raise fresh" "$(grep_ok "$JUDGE_MD" 'never for a re-raise you rate CRITICAL, which you judge fresh on current source evidence')"
check "R11c the judge names a re-raised parked entry as still open" "$(grep_ok "$JUDGE_MD" 're-raises an open `deferred`, `parked` or `routed-unfixed` entry')"
check "R12 the consume reviewer keeps deferred findings out of routing" "$(grep_ok "$REVIEWER_MD" 'never restore a deferred finding to fix routing')"
check "R12a the consume reviewer keeps the judge's still-open lines visible" "$(grep_ok "$REVIEWER_MD" '`[STILL OPEN] <id> covers <panel-id>`')"

CLAUSE_LINE="$(grep -F 'CONVERGENCE_CLAUSE=" Review convergence' "$DELEGATE")"
if [ -n "$CLAUSE_LINE" ] && [ "$(grep -cF 'CONVERGENCE_CLAUSE=" Review convergence' "$DELEGATE")" = 1 ]; then
  check "R13 the delegate defines the convergence clause once" PASS
else
  check "R13 the delegate defines the convergence clause once" FAIL
fi
check "R14 the clause is gated on hooks.reviewConvergence" "$(grep_ok "$DELEGATE" 'if zensu_hook_enabled reviewConvergence; then')"
n="$(grep -cF -- '${CONVERGENCE_CLAUSE}' "$DELEGATE")"
[ "$n" -eq 2 ] && check "R15 both severity arms interpolate the clause (${n}x)" PASS \
               || check "R15 both severity arms interpolate the clause (${n}x, want 2)" FAIL
RULE_LINES="$(grep -F 'IMPORTANT_RULE="' "$DELEGATE")"
for needle in 'step 4c Finding Verification Gate' 'hooks.incrementalReviewRounds is enabled' 'review-round-scope-v1.js' \
              'status=empty or status=degraded' 'always keeps the full cumulative diff' 'hooks.aspectActivation skips one' \
              're-run the FULL test suite over the current tree in the FOREGROUND' '${CLAUDE_PLUGIN_ROOT}'; do
  case "$CLAUSE_LINE$RULE_LINES" in
    *"$needle"*) check "R16 the clause lines avoid a per-line counted phrase [$needle]" FAIL ;;
    *) check "R16 the clause lines avoid a per-line counted phrase [$needle]" PASS ;;
  esac
done
SELF_AT="$(grep -n '^SELF_REVIEW_ON=0$' "$DELEGATE" | head -1 | cut -d: -f1)"
CLAUSE_AT="$(grep -n '^CONVERGENCE_CLAUSE=""$' "$DELEGATE" | head -1 | cut -d: -f1)"
if [ -n "$SELF_AT" ] && [ -n "$CLAUSE_AT" ] && [ "$SELF_AT" -lt "$CLAUSE_AT" ]; then
  check "R16a hooks.selfReview is resolved before the clause reads it" PASS
else
  check "R16a hooks.selfReview is resolved before the clause reads it" FAIL
fi
n="$(grep -cF -- "log this round's 'R\${NEXT}-{step_id} IMPL completed — files: {list}' claims" "$DELEGATE")"
[ "$n" -eq 2 ] && check "R16b both arms prescribe the round claim prefix outside the gated clause (${n}x)" PASS \
               || check "R16b both arms prescribe the round claim prefix outside the gated clause (${n}x, want 2)" FAIL
check "R16c the clause confines the ledger read to the project root" "$(grep_ok "$DELEGATE" '--log {log_file} --root \"\$TOP\"')"
check "R17 the suggestions arm closes a fully annotated round" "$(grep_ok "$DELEGATE" 'or every finding carries a do-not-fix annotation')"
check "R18 the suggestions arm exempts deferred findings" "$(grep_ok "$DELEGATE" "items annotated '[Deferred — do not fix]' were deferred by review convergence")"
check "R19 the combined summary sources open ledger entries" "$(grep_ok "$DELEGATE" 'one row per open entry (state deferred, parked or routed-unfixed')"
check "R19a the combined summary reads the ledger leniently" "$(grep_ok "$DELEGATE" '--report --log {log_file} --root \"\$TOP\" lists when it answers status=ok or status=partial')"
ROWS_GATED="$(awk '
  prev == "if [ \"$CONVERGENCE_ON\" = \"1\" ]; then" && index($0, "  LEDGER_OPEN_ROWS=\", plus one row per open entry") == 1 { hit++ }
  /LEDGER_OPEN_ROWS="/ { assigned++ }
  { prev = $0 }
  END { print (hit == 1 && assigned == 2) ? "PASS" : "FAIL" }' "$DELEGATE")"
check "R19c the combined summary adds ledger rows only inside the reviewConvergence gate" "$ROWS_GATED"
check "R19b the combined summary discloses an unreadable ledger" "$(grep_ok "$DELEGATE" 'the row FINDINGS LEDGER UNAVAILABLE — <reason> on status=degraded')"

check "R20 the tdd skill prepends the rubric to persona prompts" "$(grep_ok "$TDD_MD" 'prepend it right after the evidence-discipline block, so a persona rates findings on the same scale')"
check "R20a the tdd skill logs an unreadable rubric on its own" "$(grep_ok "$TDD_MD" 'PERSONA CARRIER UNAVAILABLE — review-severity: <reason>')"
check "R21 the tdd skill numbers merged findings" "$(grep_ok "$TDD_MD" 'number the merged findings `R<k>-F<n>`')"
check "R21a the tdd skill numbers judge findings after the panel" "$(grep_ok "$TDD_MD" 'takes the next free `R<k>-F<n>` id after the panel findings')"
check "R21c the tdd skill gives a judge covers line no id of its own" "$(grep_ok "$TDD_MD" 'it is a meta-verdict like `Panel-FP:`, takes no id, and names the panel finding it covers')"
check "R21b the tdd skill prescribes the round claim prefix" "$(grep_ok "$TDD_MD" "log this round's \`R{N}-<step> IMPL completed — files:\` claims")"
check "R22 the tdd skill hands the ledger to the judge" "$(grep_ok "$TDD_MD" 'plus `findings_ledger` when the post-review directive')"
check "R23 the tdd skill keeps the ledger out of the finding list" "$(grep_ok "$TDD_MD" 'The ledger is history for the judge only')"
lines="$(wc -l < "$TDD_MD" | tr -d ' ')"
[ "$lines" -le 433 ] && check "R24 the tdd skill stays within its line cap ($lines)" PASS \
                     || check "R24 the tdd skill stays within its line cap ($lines, cap 433)" FAIL
check "R25 self-review takes ledger entries as candidates" "$(grep_ok "$SELF_REVIEW_MD" 'every `deferred` entry rated IMPORTANT or CRITICAL, is a candidate')"
check "R25a self-review re-reads a candidate before it becomes a must-fix" "$(grep_ok "$SELF_REVIEW_MD" 'keep it only when that code still shows what its summary describes')"
check "R25b self-review reads the chain's own run log" "$(grep_ok "$SELF_REVIEW_MD" 'never a log resolved by recency')"
check "R25c self-review reads the ledger leniently inside the project root" "$(grep_ok "$SELF_REVIEW_MD" 'review-ledger-v1.js" --report --log <run-log> --root')"
check "R25d self-review never shell-expands a ledger line" "$(grep_ok "$SELF_REVIEW_MD" 'fed by a heredoc whose delimiter is quoted, never through `--message`')"
check "R25e self-review appends its fixed lines through the stdin verb" "$(grep_ok "$SELF_REVIEW_MD" 'append --log <run-log> --message-stdin')"
check "R25f self-review reads the ledger only while reviewConvergence is on" "$(grep_ok "$SELF_REVIEW_MD" 'zensu_hook_enabled reviewConvergence && echo on || echo off')"
check "R25g self-review takes parked entries as candidates" "$(grep_ok "$SELF_REVIEW_MD" '`routed-unfixed` or `parked`, and every `deferred` entry rated IMPORTANT or CRITICAL')"
check "R25h self-review fixes a supported parked entry whatever the must-fix bar says" "$(grep_ok "$SELF_REVIEW_MD" 'whatever the must-fix bar above says')"
check "R25i self-review reports the candidates it fixed without a re-review" "$(grep_ok "$SELF_REVIEW_MD" 'how many of them this stage fixed without a re-review')"
check "R26 self-review lists open ledger entries once per id" "$(grep_ok "$SELF_REVIEW_MD" 'one row per open findings-ledger entry')"
check "R26a self-review lists parked entries under their listed id" "$(grep_ok "$SELF_REVIEW_MD" '(state `deferred`, `parked` or `routed-unfixed`, under the id the ledger lists, a')"
check "R26b self-review adds ledger rows only while reviewConvergence is on" "$(grep_ok "$SELF_REVIEW_MD" 'when `hooks.reviewConvergence` is enabled and')"
check "R27 the reset skill writes the generation marker" "$(grep_ok "$RESET_MD" 'REVIEW BUDGET RESET')"
check "R28 the reset skill never searches for a log" "$(grep_ok "$RESET_MD" 'never search for')"
check "R28a the reset skill names the partial report instead of a safe-side drop" "$(grep_ok "$RESET_MD" 'listed under a `FINDINGS LEDGER PARTIAL` row')"
check "R28b the reset skill keeps earlier open entries under a generation prefix" "$(grep_ok "$RESET_MD" 'still lists every earlier open entry, under a `G<g>:`')"
check "R28c the reset skill names the undetectable unmarked reset" "$(grep_ok "$RESET_MD" 'repeats its earlier state and anchor, and no new id carries a round')"

check "R29 the example config carries reviewConvergence" "$(grep_ok "$CONFIG_EX" '"reviewConvergence": true')"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$CONFIG_EX" 2>/dev/null \
  && check "R30 the example config stays valid JSON" PASS || check "R30 the example config stays valid JSON" FAIL
check "R31 configuration.md documents reviewConvergence" "$(grep_ok "$CONFIG_DOC" '| `reviewConvergence` |')"
check "R32 configuration.md states the fail-open disclosure" "$(grep_ok "$CONFIG_DOC" 'CONVERGENCE UNAVAILABLE — <reason>')"
check "R33 configuration.md names the regression-judgment gap" "$(grep_ok "$CONFIG_DOC" 'not a mechanical hunk diff')"
check "R33a configuration.md states the selfReview-off routing" "$(grep_ok "$CONFIG_DOC" 'every IMPORTANT finding stays routable and only SUGGESTION findings are deferred')"
check "R33b configuration.md names the lenient report read" "$(grep_ok "$CONFIG_DOC" 'FINDINGS LEDGER PARTIAL — <reason>')"
check "R33c configuration.md keeps judge-raised IMPORTANT findings routable" "$(grep_ok "$CONFIG_DOC" 'stays routable only when the judge raised it, tagged it `[NOT FIXED]`, or it')"
check "R33d configuration.md names the two-key rollback" "$(grep_ok "$CONFIG_DOC" 'set `incrementalReviewRounds` to `false` as well for the full pre-convergence behavior')"
check "R33e configuration.md names the stdin append path" "$(grep_ok "$CONFIG_DOC" 'appended only through `zensu-log.sh append --message-stdin`')"
check "R34 review-chain.md records the convergence bound" "$(grep_ok "$CHAIN_DOC" 'hooks.reviewConvergence')"
check "R34b review-chain.md keeps judge-raised IMPORTANT findings routable" "$(grep_ok "$CHAIN_DOC" 'IMPORTANT findings the judge raised, tagged `[NOT FIXED]` or cited on code the previous fix pass edited')"
check "R34a architecture.md records round-2+ routing" "$(grep_ok "$ARCH_DOC" 'with hooks.reviewConvergence a re-review routes only CRITICAL findings')"
check "R34c architecture.md keeps judge-raised IMPORTANT findings routable" "$(grep_ok "$ARCH_DOC" 'IMPORTANT findings the judge raised, tagged [NOT FIXED] or cited on code the previous fix pass edited')"
check "R35 tdd-manager-workflow.md names the ledger helper" "$(grep_ok "$WORKFLOW_DOC" 'review-ledger-v1.js')"
check "R35a the publication-safety section covers ledger lines" "$(grep_ok "$WORKFLOW_DOC" 'finding it names only the class of weakness, never how to exploit it')"
check "R35b the chain-end summary account lists the ledger rows" "$(grep_ok "$WORKFLOW_DOC" '`FINDINGS LEDGER PARTIAL — <reason>` or `FINDINGS LEDGER UNAVAILABLE — <reason>` row')"
check "R35c tdd-manager-workflow.md keeps judge-raised IMPORTANT findings routable" "$(grep_ok "$WORKFLOW_DOC" 'the IMPORTANT findings the judge raised, tagged `[NOT FIXED]` or cited on code the previous fix pass edited')"
check "R35d tdd-manager-workflow.md ledgers a deferred IMPORTANT finding as parked" "$(grep_ok "$WORKFLOW_DOC" 'ledgered `parked` when it is IMPORTANT')"
check "R36 the workflow doc no longer claims max rounds on the 5th round" "$(grep_absent "$WORKFLOW_DOC" 'On the 5th round')"

if [ -x "$EVAL" ] && grep -qF 'test-review-convergence-directive.sh' "$EVAL_RUNNER"; then
  check "R37 the directive eval is executable and registered in the eval runner" PASS
else
  check "R37 the directive eval is executable and registered in the eval runner" FAIL
fi
node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit((m.ciStructureTests || []).includes("test-review-convergence.sh") ? 0 : 1);
' "$MANIFEST" && check "R38 this suite is registered in ciStructureTests" PASS \
             || check "R38 this suite is registered in ciStructureTests" FAIL

finish
