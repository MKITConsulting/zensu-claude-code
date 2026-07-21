#!/bin/bash
# Functional regression for the single revision-secured review-budget reset.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/reset-review-limit/SKILL.md"
LOG="$ROOT/hooks/lib/zensu-log.sh"
POST_REVIEW="$ROOT/hooks/post-review-tdd-delegate.sh"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_PLUGIN_ROOT="$ROOT"
export CLAUDE_PROJECT_DIR="$WORK/project"
export CLAUDE_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_TEST_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
export STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"
export ZENSU_CONFIG="$WORK/config.json"
mkdir -p "$CLAUDE_PROJECT_DIR" "$CLAUDE_PLUGIN_DATA"
printf '%s\n' '{"hooks":{"autoFix":true,"autoFixMaxRounds":5}}' > "$ZENSU_CONFIG"

SID="reset-transaction-revision"
# Exercise the same fresh SessionStart + per-Bash native binder used by the
# Session Control harness. No CLAUDE_ENV_FILE selectors are available anymore.
# shellcheck disable=SC1090
source "$ROOT/tests/session-control/initialize-baseline.sh" "$SID" "$ROOT"
# shellcheck disable=SC1090
source "$ROOT/hooks/lib/zensu-tdd-phase.sh"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
for _ in 1 2 3; do tdd_increment_counter "$SID" reviewRound >/dev/null; done
for _ in 1 2; do tdd_increment_counter "$SID" stopBlockCount >/dev/null; done
tdd_set_flag "$SID" chainDone true >/dev/null
tdd_set_flag "$SID" codeReviewDone true >/dev/null
tdd_set_flag "$SID" selfReviewFixed true >/dev/null

read_state() {
  CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$SID" node -e '
    const core=require(process.env.CONTROL_CORE);
    process.stdout.write(JSON.stringify(core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID})));
  '
}

BEFORE="$(read_state)"
REV_BEFORE="$(printf '%s' "$BEFORE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).revision)))')"

tdd_reset_review_budget "$SID" "$REV_BEFORE" >/dev/null
RESET_RC=$?
[ "$RESET_RC" -eq 0 ] \
  && check "T1 one atomic review-budget reset succeeds" PASS \
  || check "T1 one atomic review-budget reset succeeds" FAIL

AFTER="$(read_state)"
STATE_CHECK="$(BEFORE_REVISION="$REV_BEFORE" node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const j=JSON.parse(s), expected=Number(process.env.BEFORE_REVISION)+1;
    process.stdout.write(j.revision===expected && j.reviewRound===0 && j.stopBlockCount===0
      && j.chainDone===false && j.codeReviewDone===false && j.active===true
      && j.selfReviewFixed===false && j.implComplete===true ? "ok" : JSON.stringify(j));
  });
' <<<"$AFTER")"
[ "$STATE_CHECK" = ok ] \
  && check "T2 reset verifies revision +1, zero budgets, all flags re-armed, preserved active implementation" PASS \
  || check "T2 reset state invariant (got: $STATE_CHECK)" FAIL

STATE_FILE="$(tdd_state_file "$SID")"
file_digest() {
  node -e 'const fs=require("node:fs"),c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$1"
}
BYTES_BEFORE_STALE="$(file_digest "$STATE_FILE")"
if tdd_reset_review_budget "$SID" "$REV_BEFORE" >/dev/null 2>&1; then
  check "T3 stale CAS reset fails closed" FAIL
else
  check "T3 stale CAS reset fails closed" PASS
fi
BYTES_AFTER_STALE="$(file_digest "$STATE_FILE")"
[ "$BYTES_BEFORE_STALE" = "$BYTES_AFTER_STALE" ] \
  && check "T4 failed reset preserves exact state bytes and revision" PASS \
  || check "T4 failed reset preserves exact state bytes and revision" FAIL

TICKET="$(tdd_issue_review_ticket "$SID")"
STDIN="$(SID="$SID" TICKET="$TICKET" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "PostToolUse",
    tool_name: "Agent",
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`,
    },
    session_id: process.env.SID,
  }));
')"
OUT="$(printf '%s' "$STDIN" | bash "$POST_REVIEW" 2>/dev/null)"
case "$OUT" in
  *'zensu:code-reviewer'*'fix them YOURSELF IN THIS MAIN THREAD'*) check "T5 reset re-enables the normal post-review routing" PASS ;;
  *) check "T5 reset re-enables the normal post-review routing" FAIL ;;
esac
FINAL="$(read_state)"
FINAL_ROUND="$(printf '%s' "$FINAL" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).reviewRound)))')"
[ "$FINAL_ROUND" = 1 ] \
  && check "T6 next reviewer completion atomically advances reviewRound to 1" PASS \
  || check "T6 next reviewer completion advances reviewRound (got: $FINAL_ROUND)" FAIL

CODE_BLOCKS="$(awk '/^```/{inside=!inside; next} inside{print}' "$SKILL")"
if printf '%s\n' "$CODE_BLOCKS" | grep -Eq '(^|[[:space:]])(find|rm|mv|cp)[[:space:]]|rounds-|\.stopblocks|CLAUDE_PLUGIN_DATA_OVERRIDE'; then
  check "T7 reset recipe has no search, deletion, retired sidecar, or location override" FAIL
else
  check "T7 reset recipe has no search, deletion, retired sidecar, or location override" PASS
fi

echo "----"
echo "test-reset-review-limit-transaction: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
