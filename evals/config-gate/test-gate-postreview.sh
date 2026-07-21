#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
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
  echo "test-gate-postreview: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TMP_DIR="$(mktemp -d)"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export STATE_DIR="$TMP_DIR/state"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

render_code_reviewer_fixture() {
  FIXTURE="$EVAL_DIR/fixtures/stdin-code-reviewer.json" REVIEW_TICKET="$1" node -e '
    const fs = require("fs");
    const input = JSON.parse(fs.readFileSync(process.env.FIXTURE, "utf8"));
    input.tool_input.prompt = input.tool_input.prompt.replace("__REVIEW_TICKET__", process.env.REVIEW_TICKET);
    process.stdout.write(JSON.stringify(input));
  '
}

TMP_CFG="$TMP_DIR/config.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": false}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

# shellcheck disable=SC1090
source "$BASELINE" fixture-review
bash "$LOG" --tdd-begin --session fixture-review >/dev/null
bash "$LOG" --tdd-complete --session fixture-review >/dev/null

TICKET_DISABLED="$(bash "$LOG" --review-ticket --session fixture-review)"
STDIN_DISABLED="$(render_code_reviewer_fixture "$TICKET_DISABLED")"
OUT_DISABLED="$(printf '%s' "$STDIN_DISABLED" | "$SCRIPT" 2>/dev/null)"
EXIT_DISABLED=$?

if printf '%s' "$OUT_DISABLED" | grep -qF 'Auto-fix is disabled' \
  && printf '%s' "$OUT_DISABLED" | grep -qF -- '--claimed-review-ticket'; then
  check "autoFix=false + scoped code-reviewer: ticket-bound no-fix handoff" PASS
else
  check "autoFix=false + scoped code-reviewer: ticket-bound no-fix handoff" FAIL
fi

if [ "$EXIT_DISABLED" = "0" ]; then
  check "autoFix=false: exit code 0" PASS
else
  check "autoFix=false: exit code 0" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true}}
EOF

TICKET_ENABLED="$(bash "$LOG" --review-ticket --session fixture-review)"
STDIN_ENABLED="$(render_code_reviewer_fixture "$TICKET_ENABLED")"
OUT_ENABLED="$(printf '%s' "$STDIN_ENABLED" | "$SCRIPT" 2>/dev/null)"

case "$OUT_ENABLED" in
  *"zensu:code-reviewer"*) check "autoFix=true + code-reviewer: re-verify directive names zensu:code-reviewer" PASS ;;
  *)                       check "autoFix=true + code-reviewer: re-verify directive names zensu:code-reviewer" FAIL ;;
esac

OUT_OTHER="$("$SCRIPT" < "$EVAL_DIR/fixtures/stdin-other-agent.json" 2>/dev/null)"
if [ -z "$OUT_OTHER" ]; then
  check "autoFix=true + non-code-reviewer subagent: empty stdout (isolation preserved)" PASS
else
  check "autoFix=true + non-code-reviewer subagent: empty stdout (isolation preserved)" FAIL
fi

unset ZENSU_CONFIG
NOTHING_CFG="$TMP_DIR/no-config.json"
rm -f "$NOTHING_CFG"
export ZENSU_CONFIG="$NOTHING_CFG"
TICKET_DEFAULT="$(bash "$LOG" --review-ticket --session fixture-review)"
STDIN_DEFAULT="$(render_code_reviewer_fixture "$TICKET_DEFAULT")"
OUT_DEFAULT="$(printf '%s' "$STDIN_DEFAULT" | "$SCRIPT" 2>/dev/null)"
case "$OUT_DEFAULT" in
  *"zensu:code-reviewer"*) check "no config (default): re-verify directive names zensu:code-reviewer (enabled)" PASS ;;
  *)                       check "no config (default): re-verify directive names zensu:code-reviewer (enabled)" FAIL ;;
esac

rm -f "$TMP_CFG"

echo "----"
echo "test-gate-postreview: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
