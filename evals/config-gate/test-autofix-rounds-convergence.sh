#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-autofix-rounds-convergence: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$TMP_DIR/state"
export TDD_STATE_DIR="$CLAUDE_PLUGIN_DATA_OVERRIDE"
mkdir -p "$CLAUDE_PLUGIN_DATA_OVERRIDE"
export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-with-max-rounds.json"

SID="sess-conv-001"
COUNTER_FILE="$CLAUDE_PLUGIN_DATA_OVERRIDE/rounds-${SID}.json"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null
bash "$LOG" --tdd-complete --session "$SID" >/dev/null

# Prime two completed review generations through the public ticket contract.
# The rounds file is only a derived compatibility view; reviewRound in the
# ticket-bound session state is authoritative.
for _round in 1 2; do
  PRIME_TICKET="$(bash "$LOG" --review-ticket --session "$SID")"
  PRIME_STDIN="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${PRIME_TICKET}\\nfixture\"},\"session_id\":\"${SID}\"}"
  printf '%s' "$PRIME_STDIN" | "$SCRIPT" >/dev/null 2>/dev/null
done

TICKET="$(bash "$LOG" --review-ticket --session "$SID")"
STDIN="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"PRE-MERGED FINDINGS (fan-out)\\nREVIEW-TICKET: ${TICKET}\\nfixture\"},\"session_id\":\"${SID}\"}"
OUT="$(printf '%s' "$STDIN" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 2 rounds reached"*)
    check "stdout contains convergence message" PASS ;;
  *)
    check "stdout contains convergence message (got: $OUT)" FAIL ;;
esac

case "$OUT" in
  *"Do NOT spawn zensu:code-reviewer again"*)
    check "stdout instructs to NOT spawn zensu:code-reviewer" PASS ;;
  *)
    check "stdout instructs to NOT spawn zensu:code-reviewer" FAIL ;;
esac

case "$OUT" in
  *"Findings (max rounds reached, manual fix required)"*)
    check "stdout names the remaining-findings heading" PASS ;;
  *)
    check "stdout names the remaining-findings heading" FAIL ;;
esac

case "$OUT" in
  *"/zensu:reset-review-limit"*)
    check "stdout surfaces /zensu:reset-review-limit escape hatch" PASS ;;
  *)
    check "stdout surfaces /zensu:reset-review-limit escape hatch (got: $OUT)" FAIL ;;
esac

case "$OUT" in
  *"Delegating critical+important findings"*)
    check "convergence output must NOT contain delegation status line" FAIL ;;
  *"Delegating all findings"*)
    check "convergence output must NOT contain delegation status line" FAIL ;;
  *)
    check "convergence output must NOT contain delegation status line" PASS ;;
esac

case "$OUT" in
  *"subagent_type='zensu:tdd-manager'"*)
    check "convergence output must NOT contain subagent_type instruction" FAIL ;;
  *)
    check "convergence output must NOT contain subagent_type instruction" PASS ;;
esac

if [ -f "$COUNTER_FILE" ]; then
  c="$(node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      console.log(j && j.count);
    } catch (_) { console.log(""); }
  ' "$COUNTER_FILE" 2>/dev/null)"
  if [ "$c" = "3" ]; then
    check "counter incremented to 3 before convergence check (reflects just-completed cycle)" PASS
  else
    check "counter incremented to 3 before convergence check (got '$c')" FAIL
  fi
fi

case "$OUT" in
  *"skill='zensu:self-review'"*)
    check "max-rounds + selfReview default on: hands off to skill='zensu:self-review' (owns terminus)" PASS ;;
  *)
    check "max-rounds + selfReview default on: hands off to skill='zensu:self-review' (owns terminus)" FAIL ;;
esac

echo "----"
echo "test-autofix-rounds-convergence: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
