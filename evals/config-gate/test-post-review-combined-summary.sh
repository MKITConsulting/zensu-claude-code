#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-post-review-combined-summary: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
TMP_CFG="$TMP_DIR/config.json"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export STATE_DIR="$TMP_DIR/state"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
export ZENSU_CONFIG="$TMP_CFG"
source "$TDD_LIB"

seed_active() {
  # shellcheck disable=SC1090
  source "$BASELINE" "$1"
  bash "$LOG" --tdd-begin --session "$1" >/dev/null 2>&1
}

# selfReview:false routes the CHAIN-END SUMMARY inline through this hook
# (TAIL_DIRECTIVE). With selfReview enabled (the 0.5.0 default) the summary is
# instead rendered by the terminal /zensu:self-review stage, so the hook emits
# only the handoff directive — these cases assert the hook's own inline summary.
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "selfReview": false}}
EOF

STDIN_A='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-a-001"}'
seed_active "sess-summary-a-001"
OUT="$(printf '%s' "$STDIN_A" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case A/B legacy + flag on (default): output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "case A/B legacy + flag on (default): output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

case "$OUT" in
  *"## Problem"*)
    check "case A/B legacy + flag on: output contains '## Problem' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Problem' heading" FAIL ;;
esac

case "$OUT" in
  *"## What I built"*)
    check "case A/B legacy + flag on: output contains '## What I built' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## What I built' heading" FAIL ;;
esac

case "$OUT" in
  *"## How I built it"*)
    check "case A/B legacy + flag on: output contains '## How I built it' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## How I built it' heading" FAIL ;;
esac

case "$OUT" in
  *"## Open"*)
    check "case A/B legacy + flag on: output contains '## Open' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Open' heading" FAIL ;;
esac

case "$OUT" in
  *"## TL;DR"*)
    check "case A/B legacy + flag on: output contains '## TL;DR' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## TL;DR' heading" FAIL ;;
esac

HOOK_SEQ="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s).hookSpecificOutput.additionalContext;process.stdout.write([...c.matchAll(/^## .*/gm)].map(m=>m[0].trim()).join("|"));})')"
EXPECTED_HOOK_SEQ="## Problem|## What I built|## How I built it|## Open|## TL;DR"
[ "$HOOK_SEQ" = "$EXPECTED_HOOK_SEQ" ] && check "case A/B legacy + flag on: hook emits exact ordered heading sequence" PASS || check "case A/B legacy + flag on: hook ordered sequence (got: $HOOK_SEQ)" FAIL

LAST_HOOK_HEADING="${HOOK_SEQ##*|}"
[ "$LAST_HOOK_HEADING" = "## TL;DR" ] && check "case A/B legacy + flag on: '## TL;DR' is the LAST section heading" PASS || check "case A/B legacy + flag on: '## TL;DR' last heading (got: $LAST_HOOK_HEADING)" FAIL

case "$OUT" in
  *"## Self-Review Summary"*)
    check "case A/B legacy + flag on: hook must NOT emit '## Self-Review Summary' (skill-only)" FAIL ;;
  *)
    check "case A/B legacy + flag on: hook must NOT emit '## Self-Review Summary' (skill-only)" PASS ;;
esac

SKILL_MD_PARITY="$PLUGIN_DIR/skills/self-review/SKILL.md"
SKILL_SEQ="$(awk '/^### Final report/{f=1} f&&/^```/{c++; if(c>=2) exit} f&&c>=1{print}' "$SKILL_MD_PARITY" | grep -E '^## ' | sed 's/[[:space:]]*$//' | paste -sd'|' -)"
SKILL_SEQ_NO_SR="${SKILL_SEQ/|## Self-Review Summary/}"
[ "$HOOK_SEQ" = "$SKILL_SEQ_NO_SR" ] && check "cross-renderer parity: hook seq == skill Final-report seq minus '## Self-Review Summary'" PASS || check "cross-renderer parity (hook: $HOOK_SEQ | skill-noSR: $SKILL_SEQ_NO_SR)" FAIL

case "$OUT" in
  *"including rounds that fixed nothing"*)
    check "case A/B legacy + flag on: auto-fix history lists no-fix/verification rounds" PASS ;;
  *)
    check "case A/B legacy + flag on: auto-fix history lists no-fix/verification rounds" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "combinedSummary": false, "selfReview": false}}
EOF

STDIN_OFF='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-off-001"}'
seed_active "sess-summary-off-001"
OUT="$(printf '%s' "$STDIN_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case A/B legacy + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "case A/B legacy + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

case "$OUT" in
  *"EXCLUDE all Suggestions"*)
    check "case A/B legacy + flag off: existing 'EXCLUDE all Suggestions' directive preserved" PASS ;;
  *)
    check "case A/B legacy + flag off: existing 'EXCLUDE all Suggestions' directive preserved" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": true, "selfReview": false}}
EOF

STDIN_SUGG_ON='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-sugg-001"}'
seed_active "sess-summary-sugg-001"
OUT="$(printf '%s' "$STDIN_SUGG_ON" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Include EVERY finding the reviewer raised"*)
    check "case B suggestions-on + flag on: existing all-findings directive preserved" PASS ;;
  *)
    check "case B suggestions-on + flag on: existing all-findings directive preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case B suggestions-on + flag on: output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "case B suggestions-on + flag on: output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": true, "combinedSummary": false, "selfReview": false}}
EOF

STDIN_SUGG_OFF='{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"},"session_id":"sess-summary-sugg-off-001"}'
seed_active "sess-summary-sugg-off-001"
OUT="$(printf '%s' "$STDIN_SUGG_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case B suggestions-on + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "case B suggestions-on + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

case "$OUT" in
  *"Include EVERY finding the reviewer raised"*)
    check "case B suggestions-on + flag off: all-findings directive preserved" PASS ;;
  *)
    check "case B suggestions-on + flag off: all-findings directive preserved" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5, "selfReview": false}}
EOF
SID_MR_ON="sess-summary-mr-on-001"
seed_active "$SID_MR_ON"
for _ in 1 2 3 4 5; do
  tdd_increment_counter "$SID_MR_ON" reviewRound >/dev/null
done
STDIN_MR_ON="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_MR_ON}\"}"
OUT="$(printf '%s' "$STDIN_MR_ON" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 5 rounds reached"*)
    check "max-rounds + flag on: existing convergence message preserved" PASS ;;
  *)
    check "max-rounds + flag on: existing convergence message preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "max-rounds + flag on: output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "max-rounds + flag on: output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

case "$OUT" in
  *"including rounds that fixed nothing"*)
    check "max-rounds + flag on: auto-fix history lists no-fix/verification rounds" PASS ;;
  *)
    check "max-rounds + flag on: auto-fix history lists no-fix/verification rounds" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5, "combinedSummary": false, "selfReview": false}}
EOF
SID_MR_OFF="sess-summary-mr-off-001"
seed_active "$SID_MR_OFF"
for _ in 1 2 3 4 5; do
  tdd_increment_counter "$SID_MR_OFF" reviewRound >/dev/null
done
STDIN_MR_OFF="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SID_MR_OFF}\"}"
OUT="$(printf '%s' "$STDIN_MR_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 5 rounds reached"*)
    check "max-rounds + flag off: existing convergence message preserved" PASS ;;
  *)
    check "max-rounds + flag off: existing convergence message preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "max-rounds + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "max-rounds + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

echo "----"
echo "test-post-review-combined-summary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
