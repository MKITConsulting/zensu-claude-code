#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"
export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-with-max-rounds.json"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"

SID="sess-conv-001"
KEY="$(node "$CORE" session-key "$SID")"
STATE_FILE="$STATE_DIR/tdd-phase-${KEY}.json"
# shellcheck disable=SC1090
source "$BASELINE" "$SID"
STATE_DIR="$ZENSU_PROJECT_ROOT/.zensu/state"
STATE_FILE="$STATE_DIR/tdd-phase-${KEY}.json"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID" >/dev/null

# Prime two completed review generations through the public ticket contract.
# reviewRound in the Session Control workflow document is authoritative.
for _round in 1 2; do
  PRIME_TICKET="$(bash "$LOG" --review-ticket --session "$SID")"
  PRIME_STDIN="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${PRIME_TICKET}\\nfixture\"},\"session_id\":\"${SID}\"}"
  printf '%s' "$PRIME_STDIN" | "$SCRIPT" >/dev/null 2>/dev/null
done

TICKET="$(bash "$LOG" --review-ticket --session "$SID")"
STDIN="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET}\\nfixture\"},\"session_id\":\"${SID}\"}"
OUT="$(printf '%s' "$STDIN" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in *"Auto-fix convergence: max 2 rounds reached"*) check "stdout contains convergence message" PASS ;; *) check "stdout contains convergence message" FAIL ;; esac
case "$OUT" in *"Do NOT spawn zensu:code-reviewer again"*) check "stdout stops further reviewer spawns" PASS ;; *) check "stdout stops further reviewer spawns" FAIL ;; esac
case "$OUT" in *"Findings (max rounds reached, manual fix required)"*) check "stdout names remaining-findings heading" PASS ;; *) check "stdout names remaining-findings heading" FAIL ;; esac
case "$OUT" in *"/zensu:reset-review-limit"*) check "stdout surfaces transactional reset skill" PASS ;; *) check "stdout surfaces transactional reset skill" FAIL ;; esac
case "$OUT" in *"skill='zensu:self-review'"*) check "selfReview default hands off to terminal skill" PASS ;; *) check "selfReview default hands off to terminal skill" FAIL ;; esac
case "$OUT" in
  *"Delegating critical+important findings"*|*"Delegating all findings"*)
    check "convergence output contains no delegation status line" FAIL ;;
  *) check "convergence output contains no delegation status line" PASS ;;
esac
case "$OUT" in
  *"subagent_type='zensu:tdd-manager'"*)
    check "convergence output contains no tdd-manager instruction" FAIL ;;
  *) check "convergence output contains no tdd-manager instruction" PASS ;;
esac

CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$SID" node -e '
  const core = require(process.env.CONTROL_CORE);
  const state = core.readWorkflowState({projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID});
  if (state.reviewRound !== 3 || state.stopBlockCount !== 0 || state.codeReviewDone !== true || state.chainDone === true) process.exit(1);
' && check "convergence is recorded in the validated workflow document" PASS \
  || check "convergence is recorded in the validated workflow document" FAIL

if find "$STATE_DIR" -maxdepth 1 \( -name 'rounds-*' -o -name '*.stopblocks' \) | grep -q .; then
  check "convergence creates no retired counter sidecars" FAIL
else
  check "convergence creates no retired counter sidecars" PASS
fi
[ -f "$STATE_FILE" ] && check "canonical workflow document remains present" PASS \
  || check "canonical workflow document remains present" FAIL

echo "----"
echo "test-autofix-rounds-convergence: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
