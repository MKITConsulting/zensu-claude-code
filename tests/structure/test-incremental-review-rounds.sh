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
. "$(dirname "$0")/lib-unit-registry.sh"

source "$ROOT/tests/structure/lib-skill-text.sh"
TDD_MD="$(skill_text_file "$ROOT/skills/tdd")"
DELEGATE="$ROOT/hooks/post-review-tdd-delegate.sh"
CONFIG_EX="$ROOT/config.example.json"
CONFIG_DOC="$ROOT/docs/configuration.md"
CHAIN_DOC="$ROOT/docs/review-chain.md"
WORKFLOW_DOC="$ROOT/docs/tdd-manager-workflow.md"
ASPECT_MD="$ROOT/agents/review-aspect.md"

PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
grep_ok() { grep -qF -- "$2" "$1" && echo PASS || echo FAIL; }

for f in "$SCOPE_LIB" "$ASPECT_LIB" "$SCOPE_UNIT" "$ASPECT_UNIT" "$TDD_MD" \
         "$DELEGATE" "$CONFIG_EX" "$CONFIG_DOC" "$CHAIN_DOC" "$WORKFLOW_DOC" "$ASPECT_MD"; do
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

unit_check "I1 the review-round-scope unit file passes" "$SCOPE_UNIT"
unit_check "I2 the aspect-activation unit file passes" "$ASPECT_UNIT"

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

OUT="$(cd "$ROOT" && printf '' | node "$ASPECT_LIB" --panel full 2>&1)"
case "$OUT" in
  *"spawn=5"*) check "I5 empty change set fails open to all five aspects" PASS ;;
  *) check "I5 empty change set fails open to all five aspects" FAIL ;;
esac

OUT="$(cd "$ROOT" && printf '' | node "$ASPECT_LIB" 2>&1)"
case "$OUT" in
  *"spawn=3"*) check "I5b the default lean panel fails open to its three perspectives" PASS ;;
  *) check "I5b the default lean panel fails open to its three perspectives" FAIL ;;
esac

OUT="$(cd "$ROOT" && printf 'tests/structure/test-a.sh\n' | node "$ASPECT_LIB" --panel full 2>&1)"
case "$OUT" in
  *"spawn security"*) check "I6 a tests-only change set still runs security" PASS ;;
  *) check "I6 a tests-only change set still runs security" FAIL ;;
esac
case "$OUT" in
  *"skip architecture"*) check "I6a a tests-only change set drops architecture" PASS ;;
  *) check "I6a a tests-only change set drops architecture" FAIL ;;
esac

OUT="$(cd "$ROOT" && printf 'src/a.ts\ndocs/b.md\n' | node "$ASPECT_LIB" --panel full 2>&1)"
case "$OUT" in
  *"spawn=5"*) check "I7 one production file restores the full panel" PASS ;;
  *) check "I7 one production file restores the full panel" FAIL ;;
esac

# --- Directive carriers ------------------------------------------------------
check "I8 tdd skill names the round-scope helper" "$(grep_ok "$TDD_MD" 'review-round-scope-v1.js')"
check "I9 tdd skill names the aspect-activation helper" "$(grep_ok "$TDD_MD" 'aspect-activation-v1.js')"
check "I10 tdd skill narrows only when the directive says the key is on" "$(grep_ok "$TDD_MD" 'when the post-review directive says `hooks.incrementalReviewRounds is on`')"
check "I10a tdd skill keeps the whole diff when the directive says the key is off" "$(grep_ok "$TDD_MD" 'when it says `hooks.incrementalReviewRounds is off`, the packet keeps the WHOLE diff, and you never resolve the key yourself')"
ACTIVATION_PROBE='ZENSU_ROOT="{plugin_root}" CLAUDE_PROJECT_DIR="{project_root}" bash -c '\''source "$ZENSU_ROOT/hooks/lib/zensu-config.sh"; zensu_hook_enabled aspectActivation && echo on || echo off'\'
check "I11 tdd skill resolves hooks.aspectActivation through the anchored probe" "$(grep_ok "$TDD_MD" "$ACTIVATION_PROBE")"
check "I11a tdd skill pipes an empty change set while activation is off" "$(grep_ok "$TDD_MD" 'on `off` pipe an empty change set')"
check "I11b tdd skill logs that activation is off" "$(grep_ok "$TDD_MD" 'into the same command instead and log `ASPECT ACTIVATION OFF — hooks.aspectActivation`')"
mkdir -p "$TMP/probe-off/.zensu" "$TMP/probe-on" "$TMP/probe-home"
printf '%s\n' '{"hooks":{"aspectActivation":false}}' > "$TMP/probe-off/.zensu/config.json"
PROBE_CMD="${ACTIVATION_PROBE//\{plugin_root\}/$ROOT}"
OUT="$(unset ZENSU_CONFIG; HOME="$TMP/probe-home" bash -c "${PROBE_CMD//\{project_root\}/$TMP/probe-off}" 2>&1)"
[ "$OUT" = off ] && check "I11c the probe honors a project config that turns activation off" PASS \
                 || check "I11c the probe honors a project config that turns activation off (got: $OUT)" FAIL
OUT="$(unset ZENSU_CONFIG; HOME="$TMP/probe-home" bash -c "${PROBE_CMD//\{project_root\}/$TMP/probe-on}" 2>&1)"
[ "$OUT" = on ] && check "I11d the probe answers on without a config" PASS \
                || check "I11d the probe answers on without a config (got: $OUT)" FAIL
OUT="$(cd "$ROOT" && printf '' | node "$ASPECT_LIB" --panel lean --round re 2>&1)"
case "$OUT" in
  *"spawn correctness"*"skip design re-review-lean-panel"*"skip security re-review-lean-panel"*"summary spawn=1 "*)
    check "I11e an empty change set keeps the lean re-review shape" PASS ;;
  *) check "I11e an empty change set keeps the lean re-review shape" FAIL ;;
esac
check "I12 tdd skill narrows ONLY on status=ok" "$(grep_ok "$TDD_MD" 'ONLY on `status=ok`')"
check "I13 tdd skill keeps the whole diff on empty/degraded" "$(grep_ok "$TDD_MD" 'the packet keeps the WHOLE diff')"
check "I14 tdd skill exempts the judge from the delta" "$(grep_ok "$TDD_MD" 'ALWAYS keeps the full cumulative `changed_files`')"
check "I15 tdd skill logs every skipped aspect" "$(grep_ok "$TDD_MD" 'ASPECT SKIPPED —')"
check "I16 tdd skill spawns the whole panel when activation is unavailable" "$(grep_ok "$TDD_MD" 'ASPECT ACTIVATION UNAVAILABLE —')"

# The three delegate arms are verbatim-identical by contract, so every needle must
# appear THREE times — a one-sided edit is the failure this counts rather than greps.
for needle in 'aspect-activation-v1.js --panel ${PANEL} --round re answers spawn for ${ACTIVATION_INPUT})' \
              '— ${ROUND_SCOPE} — re-merge'; do
  n="$(grep -cF -- "$needle" "$DELEGATE")"
  [ "$n" -eq 3 ] && check "I17 every delegate arm carries [$needle] (${n}x)" PASS \
                 || check "I17 every delegate arm carries [$needle] (${n}x, want 3)" FAIL
done
check "I17a the delegate resolves hooks.aspectActivation for the re-review input" "$(grep_ok "$DELEGATE" "if zensu_hook_enabled aspectActivation; then ACTIVATION_INPUT=\"this round's changed_files\"; fi")"
check "I17b the delegate's disabled activation names an empty change set" "$(grep_ok "$DELEGATE" 'ACTIVATION_INPUT="an empty change set, because hooks.aspectActivation is off"')"
check "I17c the delegate resolves hooks.incrementalReviewRounds for the round scope" "$(grep_ok "$DELEGATE" 'if zensu_hook_enabled incrementalReviewRounds; then')"
ON_LINE="$(grep -F '  ROUND_SCOPE="hooks.incrementalReviewRounds is on: ' "$DELEGATE")"
for needle in 'status=empty or status=degraded' 'always keeps the full cumulative diff'; do
  n="$(grep -cF -- "$needle" "$DELEGATE")"
  case "$ON_LINE" in
    *"$needle"*) [ "$n" -eq 1 ] && check "I17d only the enabled round scope carries [$needle]" PASS \
                                || check "I17d only the enabled round scope carries [$needle] (${n}x, want 1)" FAIL ;;
    *) check "I17d only the enabled round scope carries [$needle]" FAIL ;;
  esac
done
case "$ON_LINE" in
  *'via hooks/lib/review-round-scope-v1.js'*) check "I17f the enabled round scope names the round-scope helper" PASS ;;
  *) check "I17f the enabled round scope names the round-scope helper" FAIL ;;
esac
check "I17g the round-scope helper path is quoted beside the ledger helper" "$(grep_ok "$DELEGATE" 'SCOPE_HELPER_Q="$(printf '"'"'%q'"'"' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/review-round-scope-v1.js")"')"
check "I17h the convergence clause names the round-scope helper whatever the round scope says" "$(grep_ok "$DELEGATE" 'run the round-scope helper, node ${SCOPE_HELPER_Q} --log {log_file} --root \"\$TOP\", with --round ${NEXT} and node ${LEDGER_HELPER_Q}')"
check "I17e the disabled round scope keeps the whole diff" "$(grep_ok "$DELEGATE" "ROUND_SCOPE=\"hooks.incrementalReviewRounds is off, so THIS round's packet keeps the whole diff")"
check "I17i a review_scope line narrows the aspect's own read in step 1" "$(grep_ok "$ASPECT_MD" '1. Read governing `CLAUDE.md` files and every listed changed file, or, when a `review_scope:` line is present, only the paths it lists plus what they reference.')"

BASELINE="$ROOT/tests/session-control/initialize-baseline.sh"
LOG_WRITER="$ROOT/hooks/lib/zensu-log.sh"
render_delegate() {
  local name="$1" zensu_config="$2" project_config="$3"
  mkdir -p "$TMP/$name/project/.zensu/state" "$TMP/$name/home"
  [ -z "$project_config" ] || printf '%s\n' "$project_config" > "$TMP/$name/project/.zensu/config.json"
  [ -z "$zensu_config" ] || printf '%s\n' "$zensu_config" > "$TMP/$name/config.json"
  (
    export CLAUDE_PLUGIN_ROOT="$ROOT"
    export CLAUDE_PROJECT_DIR="$TMP/$name/project"
    export HOME="$TMP/$name/home"
    unset ZENSU_CONFIG
    [ -z "$zensu_config" ] || export ZENSU_CONFIG="$TMP/$name/config.json"
    SID="sess-irr-$name"
    source "$BASELINE" "$SID" || exit 1
    bash "$LOG_WRITER" --tdd-begin --session "$SID" >/dev/null 2>&1
    bash "$LOG_WRITER" --tdd-complete --session "$SID" >/dev/null 2>&1
    TICKET="$(bash "$LOG_WRITER" --review-ticket --session "$SID")"
    STDIN="{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET}\\nfixture\"},\"session_id\":\"${SID}\"}"
    printf '%s' "$STDIN" | bash "$DELEGATE" 2>/dev/null > "$TMP/$name/out.json"
  )
}
context_of() {
  node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      try {
        const out = (JSON.parse(raw) || {}).hookSpecificOutput || {};
        if (out.hookEventName !== "PostToolUse" || typeof out.additionalContext !== "string") process.exit(2);
        process.stdout.write(out.additionalContext);
      } catch (_) {
        process.exit(1);
      }
    });
  ' < "$TMP/$1/out.json"
}
has() { case "$1" in *"$2"*) echo PASS ;; *) echo FAIL ;; esac; }
lacks() { case "$1" in *"$2"*) echo FAIL ;; *) echo PASS ;; esac; }

render_delegate defaults '{"hooks":{"autoFix":true}}' '' &
render_delegate activation-off '{"hooks":{"autoFix":true,"aspectActivation":false}}' '' &
render_delegate rounds-off-project '' '{"hooks":{"incrementalReviewRounds":false}}' &
wait
render_delegate rounds-off-important '{"hooks":{"autoFix":true,"autoFixSeverity":"important","incrementalReviewRounds":false}}' '' &
render_delegate rounds-off-all '{"hooks":{"autoFix":true,"autoFixSeverity":"all","incrementalReviewRounds":false}}' '' &
wait

DEFAULTS="$(context_of defaults)" && check "I30 the default render is valid PostToolUse context" PASS \
  || check "I30 the default render is valid PostToolUse context" FAIL
check "I30a the default fix round activates over this round's changed_files" "$(has "$DEFAULTS" "aspect-activation-v1.js --panel lean --round re answers spawn for this round's changed_files)")"
check "I30b the default fix round names the round delta on a review_scope line" "$(has "$DEFAULTS" "hooks.incrementalReviewRounds is on: name THIS round's delta, resolved via hooks/lib/review-round-scope-v1.js, on a 'review_scope:' line after each aspect's block")"
check "I30c the default fix round keeps the round delta on" "$(lacks "$DEFAULTS" 'hooks.incrementalReviewRounds is off')"
check "I30d the default fix round keeps activation on" "$(lacks "$DEFAULTS" 'hooks.aspectActivation is off')"
ACT_OFF="$(context_of activation-off)" && check "I31 the activation-off render is valid PostToolUse context" PASS \
  || check "I31 the activation-off render is valid PostToolUse context" FAIL
check "I31a activation off re-reviews over an empty change set" "$(has "$ACT_OFF" 'aspect-activation-v1.js --panel lean --round re answers spawn for an empty change set, because hooks.aspectActivation is off)')"
check "I31b activation off never activates over the round's changed_files" "$(lacks "$ACT_OFF" "answers spawn for this round's changed_files")"
check "I31c activation off leaves the round delta to its own key" "$(has "$ACT_OFF" 'hooks.incrementalReviewRounds is on: name THIS round')"
for name in rounds-off-project rounds-off-important rounds-off-all; do
  case "$name" in
    (rounds-off-project) status_line="'Fixing critical findings in-thread, then re-reviewing (round 1/2)'" ;;
    (rounds-off-important) status_line="'Fixing critical+important findings in-thread, then re-reviewing (round 1/2)'" ;;
    (*) status_line="'Fixing all findings in-thread, then re-reviewing (round 1/2)'" ;;
  esac
  ROUNDS_OFF="$(context_of "$name")" && check "I32 the $name render is valid PostToolUse context" PASS \
    || check "I32 the $name render is valid PostToolUse context" FAIL
  check "I32a $name renders its own severity arm" "$(has "$ROUNDS_OFF" "$status_line")"
  check "I32b $name keeps the whole diff for every agent" "$(has "$ROUNDS_OFF" "hooks.incrementalReviewRounds is off, so THIS round's packet keeps the whole diff as changed_files for the zensu:review-aspect agents and the zensu:review-judge alike")"
  check "I32c $name still names the round-scope helper for convergence" "$(has "$ROUNDS_OFF" 'hooks/lib/review-round-scope-v1.js --log {log_file} --root "$TOP", with --round 1 and node ')"
  check "I32e $name never names the round delta" "$(lacks "$ROUNDS_OFF" "THIS round's delta")"
  check "I32f $name never carries the narrowing trigger" "$(lacks "$ROUNDS_OFF" 'hooks.incrementalReviewRounds is on')"
  check "I32d $name still activates over the round's changed_files" "$(has "$ROUNDS_OFF" "answers spawn for this round's changed_files)")"
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

rm -f "$TDD_MD"
unit_check_done "I2z every unit file the registry gives this suite was graded"
echo "----"
echo "test-incremental-review-rounds: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
