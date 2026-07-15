#!/bin/bash
# Pins the post-review-tdd-delegate.sh terminus hand-off to /zensu:self-review.
# With selfReview enabled (default):
#   PASS / suggestions-only menu -> instructs --code-review-done + Skill zensu:self-review, NO --chain-done
#   max-rounds                   -> sets codeReviewDone (NOT chainDone), routes to self-review
# With selfReview disabled: legacy --chain-done close, no self-review.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$TDD_STATE_DIR/no-such-config.json"   # defaults -> selfReview on
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

flag() {
  local sid="$1" key="$2"
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));console.log(j[process.argv[2]]===true?"true":"false")}catch(_){console.log("false")}' "$TDD_STATE_DIR/tdd-phase-${sid}.json" "$key"
}
postrev() {
  local sid="$1" cfg="${2:-}"
  local ticket payload
  ticket="$(bash "$LOG" --review-ticket --session "$sid" 2>/dev/null)" || return 1
  payload="$(SID="$sid" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID
    }));
  ')"
  if [ -n "$cfg" ]; then
    printf '%s' "$payload" | ZENSU_CONFIG="$cfg" bash "$POSTREV" 2>/dev/null
  else
    printf '%s' "$payload" | bash "$POSTREV" 2>/dev/null
  fi | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")}})'
}

# --- A: normal PASS completion -> hand off to self-review ---
SID_A="postrev-pass"
bash "$LOG" --tdd-begin --session "$SID_A" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_A" >/dev/null
CTX_A="$(postrev "$SID_A")"
echo "$CTX_A" | grep -q -- "--code-review-done" && check "P1 PASS menu instructs --code-review-done" PASS || check "P1 --code-review-done" FAIL
echo "$CTX_A" | grep -qF "skill='zensu:self-review'" && check "P2 PASS menu invokes skill='zensu:self-review'" PASS || check "P2 self-review invoke" FAIL
if echo "$CTX_A" | grep -q -- "--chain-done"; then
  check "P3 PASS menu must NOT instruct --chain-done (self-review owns terminus)" FAIL
else
  check "P3 PASS menu must NOT instruct --chain-done (self-review owns terminus)" PASS
fi
echo "$CTX_A" | grep -qF "subagent_type='zensu:code-reviewer'" && check "P4 fix-loop (case C) reviewer re-spawn still present" PASS || check "P4 case C reviewer respawn" FAIL
if echo "$CTX_A" | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! echo "$CTX_A" | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "P4a PASS handoff embeds the concrete session plugin root" PASS
else
  check "P4a PASS handoff embeds the concrete session plugin root" FAIL
fi

# The model-facing command must remain valid JSON and a single inert shell
# token even when the active plugin root contains shell metacharacters.
SPECIAL_BASE="$(mktemp -d -t zensu-postreview-root-XXXXXX)"
SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch POSTREV_PWNED) `touch POSTREV_TICKED`;touch POSTREV_SEMI; apostrophe'"'"'value quote"back\slash'
mkdir -p "$SPECIAL_ROOT/hooks" "$SPECIAL_BASE/run"
cp -R "$PLUGIN_DIR/hooks/lib" "$SPECIAL_ROOT/hooks/lib"
cp "$POSTREV" "$SPECIAL_ROOT/hooks/post-review-tdd-delegate.sh"
SPECIAL_LOG="$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
SPECIAL_SID="postrev-special-root"
CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --tdd-begin --session "$SPECIAL_SID" >/dev/null
CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --tdd-complete --session "$SPECIAL_SID" >/dev/null
SPECIAL_TICKET="$(CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" bash "$SPECIAL_LOG" --review-ticket --session "$SPECIAL_SID" 2>/dev/null)"
SPECIAL_PAYLOAD="$(SID="$SPECIAL_SID" TICKET="$SPECIAL_TICKET" node -e '
  process.stdout.write(JSON.stringify({
    session_id: process.env.SID,
    tool_input: {
      subagent_type: "zensu:code-reviewer",
      prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
    }
  }));
')"
SPECIAL_OUT="$(printf '%s' "$SPECIAL_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" \
  bash "$SPECIAL_ROOT/hooks/post-review-tdd-delegate.sh" 2>/dev/null)"
EXPECTED_Q="$(printf '%q' "$SPECIAL_LOG")"
SPECIAL_CTX="$(printf '%s' "$SPECIAL_OUT" | node -e '
  let s=""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const out = j.hookSpecificOutput || {};
      if (out.hookEventName !== "PostToolUse" || typeof out.additionalContext !== "string") process.exit(2);
      process.stdout.write(out.additionalContext);
    } catch (_) { process.exit(1); }
  });
' 2>/dev/null)"
SPECIAL_PARSE_RC=$?
(
  cd "$SPECIAL_BASE/run" || exit 1
  CLAUDE_PLUGIN_ROOT="$SPECIAL_ROOT" eval "bash $EXPECTED_Q --review-ticket --session $SPECIAL_SID" >/dev/null 2>&1
)
SPECIAL_EXEC_RC=$?
if [ "$SPECIAL_PARSE_RC" = "0" ] && [ "$SPECIAL_EXEC_RC" = "0" ] \
  && printf '%s' "$SPECIAL_CTX" | grep -qF "bash $EXPECTED_Q --code-review-done" \
  && printf '%s' "$SPECIAL_CTX" | grep -qF "bash $EXPECTED_Q --review-ticket" \
  && ! printf '%s' "$SPECIAL_CTX" | grep -qF '${CLAUDE_PLUGIN_ROOT}' \
  && [ ! -e "$SPECIAL_BASE/run/POSTREV_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/POSTREV_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/POSTREV_SEMI" ]; then
  check "P4b special-character root stays valid JSON and inert in review commands" PASS
else
  check "P4b special-character root stays valid JSON and inert in review commands" FAIL
fi
if grep -qE 'LOG_HELPER_Q=.*printf.*%q.*CLAUDE_PLUGIN_ROOT.*zensu-log\.sh' "$POSTREV" \
  && grep -qF 'bash ${LOG_HELPER_Q}' "$POSTREV"; then
  check "P4c generated review commands serialize the active root through printf %q" PASS
else
  check "P4c generated review commands serialize the active root through printf %q" FAIL
fi
rm -rf "$SPECIAL_BASE"

# --- B: max-rounds -> codeReviewDone set, chainDone NOT set, routes to self-review ---
SID_B="postrev-maxrounds"
bash "$LOG" --tdd-begin --session "$SID_B" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_B" >/dev/null
mkdir -p "$PROJ/.zensu/state"
printf '{"count":5,"ts":"x"}' > "$PROJ/.zensu/state/rounds-${SID_B}.json"
# The ticket-bound state is authoritative; the public rounds file is only a
# derived compatibility view.
node -e 'const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p));j.reviewRound=5;fs.writeFileSync(p,JSON.stringify(j,null,2));' \
  "$TDD_STATE_DIR/tdd-phase-${SID_B}.json"
CTX_B="$(postrev "$SID_B")"
[ "$(flag "$SID_B" codeReviewDone)" = "true" ] && check "P5 max-rounds sets codeReviewDone" PASS || check "P5 codeReviewDone set" FAIL
[ "$(flag "$SID_B" chainDone)" = "false" ] && check "P6 max-rounds does NOT set chainDone (self-review owns terminus)" PASS || check "P6 chainDone stays false" FAIL
echo "$CTX_B" | grep -qF "skill='zensu:self-review'" && check "P7 max-rounds routes to self-review" PASS || check "P7 max-rounds self-review" FAIL

# --- C: selfReview disabled -> legacy --chain-done close, no self-review ---
SID_C="postrev-selfreview-off"
OFFCFG="$TDD_STATE_DIR/selfreview-off.json"
printf '{"hooks":{"selfReview":false}}' > "$OFFCFG"
bash "$LOG" --tdd-begin --session "$SID_C" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_C" >/dev/null
CTX_C="$(postrev "$SID_C" "$OFFCFG")"
echo "$CTX_C" | grep -q -- "--chain-done" && check "P8 selfReview off -> legacy --chain-done close" PASS || check "P8 legacy --chain-done" FAIL
if echo "$CTX_C" | grep -qF "skill='zensu:self-review'"; then
  check "P9 selfReview off -> no self-review invoke" FAIL
else
  check "P9 selfReview off -> no self-review invoke" PASS
fi
if echo "$CTX_C" | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! echo "$CTX_C" | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "P10 legacy close embeds the concrete session plugin root" PASS
else
  check "P10 legacy close embeds the concrete session plugin root" FAIL
fi

echo "----"
echo "test-post-review-self-review-handoff: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
