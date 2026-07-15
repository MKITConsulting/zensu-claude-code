#!/bin/bash
# Pins the deferred-review fallback (0.8.x): a project-scoped pending-review
# marker (written by zensu-log.sh --pending-review) is adopted by the next
# interactive Stop as a review-only chain, so a Claude Code Workflow whose
# workers no-op'd their own Stop still gets the review chain once over the
# aggregate diff. --pending-review-done clears it (orchestrator-driven path).
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"; export TDD_STATE_DIR
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$TDD_STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN CLAUDE_SESSION_ID 2>/dev/null || true
cleanup() { rm -rf "$TDD_STATE_DIR" "$PROJ"; }
trap cleanup EXIT

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }

MARKER="$TDD_STATE_DIR/pending-review.json"
SID="deferred-main"

OUT="$(printf '{"session_id":"%s"}' "$SID" | bash "$STOP" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | decision)" = "allow" ]; then
  check "D0 no marker + not active -> allow stop (clean exit 0, not a crash)" PASS
else
  check "D0 clean stop (rc=$RC out=$OUT)" FAIL
fi

bash "$LOG" --pending-review --files "src/x.ts,src/y.ts" --summary "workflow changes" >/dev/null 2>&1
[ -f "$MARKER" ] \
  && check "D1 --pending-review writes project marker" PASS \
  || check "D1 marker written" FAIL

OUT="$(printf '{"session_id":"%s"}' "$SID" | bash "$STOP" 2>/dev/null)"
DEC="$(printf '%s' "$OUT" | decision)"
if [ "$DEC" = "block" ] && printf '%s' "$OUT" | grep -q "zensu:code-reviewer"; then
  check "D2 marker present + not active -> adopt -> block with reviewer directive" PASS
else
  check "D2 adopt+block (dec=$DEC out=${OUT:0:90})" FAIL
fi

[ -f "$MARKER" ] \
  && check "D3 marker cleared after adoption" FAIL \
  || check "D3 marker cleared after adoption" PASS

D4FILE="$TDD_STATE_DIR/tdd-phase-${SID}.json"
if node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((s.active===true&&s.implComplete===true&&s.vanilla===true)?0:1)' "$D4FILE" 2>/dev/null; then
  check "D4 adopted session seeded active+implComplete+vanilla (default vanilla fork)" PASS
else
  check "D4 adopted flags (state: $(tr -d '\n' < "$D4FILE" 2>/dev/null | head -c 200))" FAIL
fi

bash "$LOG" --pending-review --files "z.ts" >/dev/null 2>&1
bash "$LOG" --pending-review-done >/dev/null 2>&1
[ -f "$MARKER" ] \
  && check "D5 --pending-review-done clears marker (orchestrator-driven path)" FAIL \
  || check "D5 --pending-review-done clears marker" PASS

SID_SYM="deferred-symlink"
# D2 intentionally leaves its adopted claim as a recovery record. Retire that
# completed fixture before exercising an unrelated unsafe-marker case.
rm -f "$MARKER" "${MARKER}.claim" 2>/dev/null
ln -s /etc/hosts "$MARKER" 2>/dev/null || true
if [ -L "$MARKER" ]; then
  OUT="$(printf '{"session_id":"%s"}' "$SID_SYM" | bash "$STOP" 2>/dev/null)"; RC=$?
  if [ "$RC" -eq 0 ] \
    && [ "$(printf '%s' "$OUT" | decision)" = "block" ] \
    && [ -L "$MARKER" ] \
    && [ ! -e "${MARKER}.claim" ] \
    && [ ! -e "$TDD_STATE_DIR/tdd-phase-${SID_SYM}.json" ]; then
    check "D6 symlinked marker fails closed without claim or session mutation" PASS
  else
    check "D6 symlink refused (rc=$RC symlink=$([ -L "$MARKER" ] && echo y || echo n) claim=$([ -e "${MARKER}.claim" ] && echo y || echo n) state=$([ -e "$TDD_STATE_DIR/tdd-phase-${SID_SYM}.json" ] && echo y || echo n) out=$OUT)" FAIL
  fi
else
  echo "  SKIP  D6 symlink refusal — ln -s did not create a real symlink (Windows/MSYS)"
fi
rm -f "$MARKER" "${MARKER}.claim"

SID_CO="deferred-coexist"
bash "$LOG" --tdd-begin --session "$SID_CO" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_CO" >/dev/null 2>&1
bash "$LOG" --pending-review --files "co.ts" >/dev/null 2>&1
OUT="$(printf '{"session_id":"%s"}' "$SID_CO" | bash "$STOP" 2>/dev/null)"
DEC="$(printf '%s' "$OUT" | decision)"
MARK_OK="no"; { [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; } && MARK_OK="yes"
if [ "$DEC" = "block" ] && [ "$MARK_OK" = "yes" ] && printf '%s' "$OUT" | grep -q "zensu:code-reviewer"; then
  check "D7 active session NOT hijacked by marker (blocks via own state; marker survives un-adopted)" PASS
else
  check "D7 coexistence (dec=$DEC marker_survives=$MARK_OK)" FAIL
fi
bash "$LOG" --pending-review-done >/dev/null 2>&1

SID_FAIL="deferred-seedfail"
bash "$LOG" --pending-review --files "x.ts" --summary "fresh" >/dev/null 2>&1
chmod 555 "$TDD_STATE_DIR" 2>/dev/null || true
if touch "$TDD_STATE_DIR/.wprobe" 2>/dev/null; then
  rm -f "$TDD_STATE_DIR/.wprobe" 2>/dev/null
  chmod 755 "$TDD_STATE_DIR" 2>/dev/null || true
  echo "  SKIP  D8 seed-failure — state dir still writable (cannot force failure on this platform)"
else
  OUT="$(printf '{"session_id":"%s"}' "$SID_FAIL" | bash "$STOP" 2>/dev/null)"; RC=$?
  chmod 755 "$TDD_STATE_DIR" 2>/dev/null || true
  if [ "$RC" -eq 0 ] \
    && [ "$(printf '%s' "$OUT" | decision)" = "block" ] \
    && [ -f "$MARKER" ] \
    && [ ! -e "${MARKER}.claim" ] \
    && [ ! -e "$TDD_STATE_DIR/tdd-phase-${SID_FAIL}.json" ]; then
    check "D8 seed-write failure fails closed and remains mutation-free for retry" PASS
  else
    check "D8 seed-failure (rc=$RC dec=$(printf '%s' "$OUT" | decision) marker=$([ -f "$MARKER" ] && echo y || echo n) claim=$([ -e "${MARKER}.claim" ] && echo y || echo n) state=$([ -e "$TDD_STATE_DIR/tdd-phase-${SID_FAIL}.json" ] && echo y || echo n))" FAIL
  fi
fi
chmod 755 "$TDD_STATE_DIR" 2>/dev/null || true
rm -f "$MARKER"

echo "----"
echo "test-deferred-review-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
