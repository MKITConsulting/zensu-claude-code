#!/bin/bash
# Runtime proof that reviewer findings return to the interactive main thread.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$ROOT/hooks/post-review-tdd-delegate.sh"
LOG="$ROOT/hooks/lib/zensu-log.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP/project"
mkdir -p "$CLAUDE_PROJECT_DIR"
export CLAUDE_PLUGIN_ROOT="$ROOT"
export ZENSU_CONFIG="$TMP/config.json"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$ZENSU_CONFIG"
SID="tdd-review-chain-current"
# shellcheck disable=SC1091
source "$ROOT/tests/session-control/initialize-baseline.sh" "$SID"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null

PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"'"$SID"'"}'
OUT="$(printf '%s' "$PAYLOAD" | bash "$HOOK" 2>/dev/null)"
printf '%s' "$OUT" | grep -qF '"additionalContext"' \
  && check "code-reviewer completion emits additionalContext" PASS \
  || check "code-reviewer completion emits additionalContext" FAIL
printf '%s' "$OUT" | grep -qF 'fix them YOURSELF IN THIS MAIN THREAD' \
  && ! printf '%s' "$OUT" | grep -qF 'zensu:tdd-manager' \
  && check "findings route to the interactive main thread, never tdd-manager" PASS \
  || check "review fix routing is not main-thread-only" FAIL
for literal in 'Critical' 'Important' 'Suggestions' 'No fixes needed: review passed' 'No critical/important findings — suggestions only'; do
  printf '%s' "$OUT" | grep -qF "$literal" \
    && check "directive contains: $literal" PASS \
    || check "directive contains: $literal" FAIL
done
printf '%s' "$OUT" | grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session' \
  && check "directive positively pins the fail-closed helper guard" PASS \
  || check "directive lacks the fail-closed helper guard" FAIL

OTHER="$(printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"zensu-plm"},"session_id":"'"$SID"'"}' | bash "$HOOK" 2>/dev/null)"
[ -z "$OTHER" ] && check "neutral non-reviewer child is isolated" PASS \
  || check "neutral non-reviewer child is isolated" FAIL

echo "----"
echo "assert-severity-routing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
