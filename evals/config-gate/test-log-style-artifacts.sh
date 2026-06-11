#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WITNESS_HOOK="$PLUGIN_DIR/hooks/post-bash-witness.sh"
ROUNDS_HOOK="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG_NONE="$EVAL_DIR/fixtures/config-log-none.json"
CFG_WALL="$EVAL_DIR/fixtures/config-log-wall.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if ! command -v node >/dev/null 2>&1; then
  check "node available (required for artifact timestamp eval)" FAIL
  echo "----"
  echo "test-log-style-artifacts: $PASS PASS / $FAIL FAIL"
  exit 1
fi

# ---- Witness log: none suppresses the [HH:MM:SS] prefix ----------------------
WPROJ="$(mktemp -d)"
SID="wt-none-$$"
env CLAUDE_PROJECT_DIR="$WPROJ" TDD_STATE_DIR="$WPROJ/.zensu/state" ZENSU_CONFIG="$CFG_NONE" \
  bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
PAY=$(printf '{"tool_input":{"command":"go test ./..."},"tool_response":{"exit_code":0,"stdout":"ok"},"session_id":"%s"}' "$SID")
echo "$PAY" | env CLAUDE_PROJECT_DIR="$WPROJ" TDD_STATE_DIR="$WPROJ/.zensu/state" ZENSU_CONFIG="$CFG_NONE" \
  bash "$WITNESS_HOOK" >/dev/null 2>&1
WLINE="$(head -n1 "$WPROJ/.zensu/logs/witness-${SID}.log" 2>/dev/null)"
case "$WLINE" in
  "BASH cmd="*) check "witness none: line has NO timestamp prefix (starts 'BASH cmd=')" PASS ;;
  *)            check "witness none: no timestamp prefix (got '$WLINE')" FAIL ;;
esac
if printf '%s' "$WLINE" | grep -qF 'cmd="go test ./..."'; then
  check "witness none: cmd= still recorded (evidence intact)" PASS
else
  check "witness none: cmd= still recorded (got '$WLINE')" FAIL
fi
rm -rf "$WPROJ"

# ---- Witness log: wall keeps the [HH:MM:SS] prefix (unchanged behavior) ------
WPROJ2="$(mktemp -d)"
SID2="wt-wall-$$"
env CLAUDE_PROJECT_DIR="$WPROJ2" TDD_STATE_DIR="$WPROJ2/.zensu/state" ZENSU_CONFIG="$CFG_WALL" \
  bash "$LOG" --tdd-begin --session "$SID2" >/dev/null 2>&1
PAY2=$(printf '{"tool_input":{"command":"npm test"},"tool_response":{"exit_code":0,"stdout":"ok"},"session_id":"%s"}' "$SID2")
echo "$PAY2" | env CLAUDE_PROJECT_DIR="$WPROJ2" TDD_STATE_DIR="$WPROJ2/.zensu/state" ZENSU_CONFIG="$CFG_WALL" \
  bash "$WITNESS_HOOK" >/dev/null 2>&1
WLINE2="$(head -n1 "$WPROJ2/.zensu/logs/witness-${SID2}.log" 2>/dev/null)"
if printf '%s' "$WLINE2" | grep -qE '^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] BASH cmd='; then
  check "witness wall: line keeps [HH:MM:SS] prefix" PASS
else
  check "witness wall: keeps [HH:MM:SS] prefix (got '$WLINE2')" FAIL
fi
rm -rf "$WPROJ2"

# ---- Phase state JSON: none omits history[].ts, keeps step+phase -------------
PSTATE="$(mktemp -d)"
export TDD_STATE_DIR="$PSTATE"
source "$LIB"

export ZENSU_CONFIG="$CFG_NONE"
PSID_N="ph-none-$$"
tdd_write_phase "$PSID_N" "S1" "RED_WRITE" "" >/dev/null 2>&1
PF_N="$(tdd_state_file "$PSID_N")"
HAS_TS_N=$(node -e '
  const h=(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).history||[])[0]||{};
  process.stdout.write(("ts" in h)?"yes":"no");
' "$PF_N" 2>/dev/null)
[ "$HAS_TS_N" = "no" ] && check "phase none: history entry omits ts" PASS \
  || check "phase none: history entry omits ts (got '$HAS_TS_N')" FAIL
STEP_N=$(node -e '
  const h=(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).history||[])[0]||{};
  process.stdout.write((h.step==="S1"&&h.phase==="RED_WRITE")?"ok":"no");
' "$PF_N" 2>/dev/null)
[ "$STEP_N" = "ok" ] && check "phase none: step+phase still recorded" PASS \
  || check "phase none: step+phase still recorded (got '$STEP_N')" FAIL

export ZENSU_CONFIG="$CFG_WALL"
PSID_W="ph-wall-$$"
tdd_write_phase "$PSID_W" "S1" "RED_WRITE" "" >/dev/null 2>&1
PF_W="$(tdd_state_file "$PSID_W")"
TS_W=$(node -e '
  const h=(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).history||[])[0]||{};
  process.stdout.write((typeof h.ts==="string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(h.ts))?"ok":"no");
' "$PF_W" 2>/dev/null)
[ "$TS_W" = "ok" ] && check "phase wall: history entry keeps ISO-UTC ts" PASS \
  || check "phase wall: history entry keeps ISO-UTC ts (got '$TS_W')" FAIL

unset ZENSU_CONFIG TDD_STATE_DIR
rm -rf "$PSTATE"

# ---- Rounds counter JSON: none omits ts, keeps count ------------------------
RSTATE="$(mktemp -d)"
SIDR="rd-none-$$"
STDINR="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SIDR}\"}"
printf '%s' "$STDINR" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA_OVERRIDE="$RSTATE" ZENSU_CONFIG="$CFG_NONE" \
  bash "$ROUNDS_HOOK" >/dev/null 2>&1
R_N=$(node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.stdout.write((j.count===1?"c1":"cX")+"|"+(("ts" in j)?"ts":"nots"));
' "$RSTATE/rounds-${SIDR}.json" 2>/dev/null)
[ "$R_N" = "c1|nots" ] && check "rounds none: count=1 and ts omitted" PASS \
  || check "rounds none: count=1 and ts omitted (got '$R_N')" FAIL
rm -rf "$RSTATE"

RSTATE2="$(mktemp -d)"
SIDR2="rd-wall-$$"
STDINR2="{\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"zensu:code-reviewer\",\"prompt\":\"x\"},\"session_id\":\"${SIDR2}\"}"
printf '%s' "$STDINR2" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA_OVERRIDE="$RSTATE2" ZENSU_CONFIG="$CFG_WALL" \
  bash "$ROUNDS_HOOK" >/dev/null 2>&1
R_W=$(node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const iso=typeof j.ts==="string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(j.ts);
  process.stdout.write((j.count===1?"c1":"cX")+"|"+(iso?"iso":"nots"));
' "$RSTATE2/rounds-${SIDR2}.json" 2>/dev/null)
[ "$R_W" = "c1|iso" ] && check "rounds wall: count=1 and ISO-UTC ts kept" PASS \
  || check "rounds wall: count=1 and ISO-UTC ts kept (got '$R_W')" FAIL
rm -rf "$RSTATE2"

echo "----"
echo "test-log-style-artifacts: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
