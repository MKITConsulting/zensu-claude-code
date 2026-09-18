#!/bin/bash
# Structure regression for the two review-cost reductions: per-round delta scoping
# (`hooks.incrementalReviewRounds`) and built-in aspect activation
# (`hooks.aspectActivation`).
#
# Both narrow what the review fan-out reads, so both can lose COVERAGE if they
# drift, and both fail in the direction that stays green: a helper that answered
# "narrow" where it should answer "use the whole diff" reviews less while every
# check around it passes. The suite therefore pins the FAIL-OPEN contract of each
# helper behaviourally (not just its source), and pins that every directive
# carrier still tells the model to fall back — a helper that fails open is worth
# nothing if the directive stopped saying so.
#
# It also pins the judge exclusion, which is the one claim that makes delta
# scoping safe at all: cross-cutting drift into a file the round did not touch is
# exactly what a delta hides, so `zensu:review-judge` must keep the full diff.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCOPE_LIB="$ROOT/hooks/lib/review-round-scope-v1.js"
ASPECT_LIB="$ROOT/hooks/lib/aspect-activation-v1.js"
SCOPE_UNIT="$ROOT/tests/structure/review-round-scope-v1.test.js"
ASPECT_UNIT="$ROOT/tests/structure/aspect-activation-v1.test.js"
. "$(dirname "$0")/lib-unit-summary.sh"

TDD_MD="$ROOT/skills/tdd/SKILL.md"
DELEGATE="$ROOT/hooks/post-review-tdd-delegate.sh"
CONFIG_EX="$ROOT/config.example.json"
CONFIG_DOC="$ROOT/docs/configuration.md"
CHAIN_DOC="$ROOT/docs/review-chain.md"
WORKFLOW_DOC="$ROOT/docs/tdd-manager-workflow.md"

PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
grep_ok() { grep -qF -- "$2" "$1" && echo PASS || echo FAIL; }

for f in "$SCOPE_LIB" "$ASPECT_LIB" "$SCOPE_UNIT" "$ASPECT_UNIT" "$TDD_MD" \
         "$DELEGATE" "$CONFIG_EX" "$CONFIG_DOC" "$CHAIN_DOC" "$WORKFLOW_DOC"; do
  if [ ! -f "$f" ]; then
    check "I0 required file exists: $f" FAIL
    echo "----"
    echo "test-incremental-review-rounds: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done

if ! command -v node >/dev/null 2>&1; then
  check "I0a node is available" FAIL
  echo "----"
  echo "test-incremental-review-rounds: $PASS PASS / $FAIL FAIL"
  exit 1
fi

# --- Unit drivers -----------------------------------------------------------
# tests/run-all.sh discovers only structure/test-*.sh, so an undriven *.test.js
# is never executed by the tree runner. Floor on the REGISTERED total: it is the
# platform-independent number and it is what catches a unit file emptied,
# renamed, or never collecting a case.
SCOPE_OUT="$(cd "$ROOT" && node --test "$SCOPE_UNIT" 2>&1)"
SCOPE_RC=$?
[ "$SCOPE_RC" -eq 0 ] && check "I1 review-round-scope unit suite passes ($(unit_cases_report_text "$SCOPE_OUT"))" PASS \
                      || check "I1 review-round-scope unit suite passes" FAIL
unit_cases_registered_floor_text "$SCOPE_OUT" 18 \
  && check "I1a review-round-scope unit suite registers its cases ($UNIT_CASES_TESTS)" PASS \
  || check "I1a review-round-scope unit suite registers its cases ($UNIT_CASES_TESTS)" FAIL

ASPECT_OUT="$(cd "$ROOT" && node --test "$ASPECT_UNIT" 2>&1)"
ASPECT_RC=$?
[ "$ASPECT_RC" -eq 0 ] && check "I2 aspect-activation unit suite passes ($(unit_cases_report_text "$ASPECT_OUT"))" PASS \
                       || check "I2 aspect-activation unit suite passes" FAIL
unit_cases_registered_floor_text "$ASPECT_OUT" 12 \
  && check "I2a aspect-activation unit suite registers its cases ($UNIT_CASES_TESTS)" PASS \
  || check "I2a aspect-activation unit suite registers its cases ($UNIT_CASES_TESTS)" FAIL

# --- Fail-open contract, driven through the real CLIs ------------------------
# The source pins below cannot see a helper that still SAYS fail-open while
# answering ok, so both directions run the shipped entry point.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zensu-irr-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
printf 'R1-S1 IMPL completed — files: src/a.ts\n' > "$TMP/run.log"

OUT="$(cd "$ROOT" && node "$SCOPE_LIB" --log "$TMP/run.log" --round 1 2>&1)"
case "$OUT" in
  *"status=ok"*) check "I3 a resolvable round narrows (status=ok)" PASS ;;
  *) check "I3 a resolvable round narrows (status=ok)" FAIL ;;
esac

for bad in "--log $TMP/absent.log --round 1" "--log $TMP/run.log --round 0" "--log $TMP/run.log --round 4"; do
  # shellcheck disable=SC2086
  OUT="$(cd "$ROOT" && node "$SCOPE_LIB" $bad 2>&1)"
  case "$OUT" in
    *"status=ok"*) check "I4 unresolvable delta never reports ok [$bad]" FAIL ;;
    *"status=empty"*|*"status=degraded"*) check "I4 unresolvable delta never reports ok [$bad]" PASS ;;
    *) check "I4 unresolvable delta never reports ok [$bad]" FAIL ;;
  esac
done

OUT="$(cd "$ROOT" && printf '' | node "$ASPECT_LIB" 2>&1)"
case "$OUT" in
  *"spawn=5"*) check "I5 empty change set fails open to all five aspects" PASS ;;
  *) check "I5 empty change set fails open to all five aspects" FAIL ;;
esac

OUT="$(cd "$ROOT" && printf 'tests/structure/test-a.sh\n' | node "$ASPECT_LIB" 2>&1)"
case "$OUT" in
  *"spawn security"*) check "I6 a tests-only change set still runs security" PASS ;;
  *) check "I6 a tests-only change set still runs security" FAIL ;;
esac
case "$OUT" in
  *"skip architecture"*) check "I6a a tests-only change set drops architecture" PASS ;;
  *) check "I6a a tests-only change set drops architecture" FAIL ;;
esac

OUT="$(cd "$ROOT" && printf 'src/a.ts\ndocs/b.md\n' | node "$ASPECT_LIB" 2>&1)"
case "$OUT" in
  *"spawn=5"*) check "I7 one production file restores the full panel" PASS ;;
  *) check "I7 one production file restores the full panel" FAIL ;;
esac

# --- Directive carriers ------------------------------------------------------
check "I8 tdd skill names the round-scope helper" "$(grep_ok "$TDD_MD" 'review-round-scope-v1.js')"
check "I9 tdd skill names the aspect-activation helper" "$(grep_ok "$TDD_MD" 'aspect-activation-v1.js')"
check "I10 tdd skill gates delta scoping on hooks.incrementalReviewRounds" "$(grep_ok "$TDD_MD" '`hooks.incrementalReviewRounds` is enabled')"
check "I11 tdd skill gates activation on hooks.aspectActivation" "$(grep_ok "$TDD_MD" '`hooks.aspectActivation` is enabled')"
check "I12 tdd skill narrows ONLY on status=ok" "$(grep_ok "$TDD_MD" 'ONLY on `status=ok`')"
check "I13 tdd skill keeps the whole diff on empty/degraded" "$(grep_ok "$TDD_MD" 'the packet keeps the WHOLE diff')"
check "I14 tdd skill exempts the judge from the delta" "$(grep_ok "$TDD_MD" 'ALWAYS keeps the full cumulative `changed_files`')"
check "I15 tdd skill logs every skipped aspect" "$(grep_ok "$TDD_MD" 'ASPECT SKIPPED —')"
check "I16 tdd skill spawns all five when activation is unavailable" "$(grep_ok "$TDD_MD" 'ASPECT ACTIVATION UNAVAILABLE —')"

# The two delegate arms are verbatim-identical by contract, so every needle must
# appear TWICE — a one-sided edit is the failure this counts rather than greps.
for needle in 'hooks.incrementalReviewRounds is enabled' 'review-round-scope-v1.js' \
              'status=empty or status=degraded' 'always keeps the full cumulative diff' \
              'hooks.aspectActivation skips one'; do
  n="$(grep -cF -- "$needle" "$DELEGATE")"
  [ "$n" -eq 2 ] && check "I17 both delegate arms carry [$needle] (${n}x)" PASS \
                 || check "I17 both delegate arms carry [$needle] (${n}x, want 2)" FAIL
done

# --- Config and operator accounts -------------------------------------------
check "I18 example config carries incrementalReviewRounds" "$(grep_ok "$CONFIG_EX" '"incrementalReviewRounds": true')"
check "I19 example config carries aspectActivation" "$(grep_ok "$CONFIG_EX" '"aspectActivation": true')"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$CONFIG_EX" 2>/dev/null \
  && check "I20 example config stays valid JSON" PASS || check "I20 example config stays valid JSON" FAIL

check "I21 configuration.md documents incrementalReviewRounds" "$(grep_ok "$CONFIG_DOC" '| `incrementalReviewRounds` |')"
check "I22 configuration.md documents aspectActivation" "$(grep_ok "$CONFIG_DOC" '| `aspectActivation` |')"
check "I23 configuration.md states the judge exclusion" "$(grep_ok "$CONFIG_DOC" 'The judge is excluded by design')"
check "I24 configuration.md states the fail-open contract" "$(grep_ok "$CONFIG_DOC" 'Fail-open by contract:')"
check "I25 configuration.md keeps security on a tests-only change set" "$(grep_ok "$CONFIG_DOC" 'still runs on a tests-only change set')"
check "I26 review-chain.md records both reductions" "$(grep_ok "$CHAIN_DOC" 'hooks.incrementalReviewRounds')"
check "I27 tdd-manager-workflow.md records the per-round delta" "$(grep_ok "$WORKFLOW_DOC" 'review-round-scope-v1.js')"

# --- Known-gap honesty -------------------------------------------------------
# Both reductions are bounded by a stated gap, and a doc that drops the gap while
# keeping the feature is the drift this repository treats as worse than the gap.
check "I28 configuration.md names the unlogged-edit gap" "$(grep_ok "$CONFIG_DOC" 'a round that edits a file without logging the claim')"
check "I29 configuration.md names the path-shaped classifier gap" "$(grep_ok "$CONFIG_DOC" 'the classifier is path-shaped')"

echo "----"
echo "test-incremental-review-rounds: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
