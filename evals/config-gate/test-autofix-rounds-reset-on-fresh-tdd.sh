#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
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
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"

SID="sess-reset-001"
# shellcheck disable=SC1090
source "$BASELINE" "$SID"
STATE_DIR="$ZENSU_PROJECT_ROOT/.zensu/state"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
. "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SID")" || exit 1
STATE_DIR="$(dirname "$STATE_FILE")"
tdd_increment_counter "$SID" reviewRound >/dev/null
tdd_increment_counter "$SID" reviewRound >/dev/null
tdd_increment_counter "$SID" stopBlockCount >/dev/null
tdd_increment_counter "$SID" stopBlockCount >/dev/null
tdd_set_flag "$SID" chainDone true >/dev/null
tdd_set_flag "$SID" codeReviewDone true >/dev/null

read_state() {
  CONTROL_CORE="$CORE" PROJECT_ROOT="$CLAUDE_PROJECT_DIR" SID="$SID" node -e '
    const core = require(process.env.CONTROL_CORE);
    process.stdout.write(JSON.stringify(core.readWorkflowState({projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID})));
  '
}
BEFORE="$(read_state)"
BEFORE_REV="$(printf '%s' "$BEFORE" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(String(JSON.parse(s).revision)))')"

BEGIN_ERR="$TMP_DIR/begin.err"
bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>"$BEGIN_ERR"
BEGIN_RC=$?
[ "$BEGIN_RC" -eq 0 ] && check "fresh-task begin succeeds through CAS" PASS \
  || check "fresh-task begin succeeds through CAS (rc=$BEGIN_RC)" FAIL
AFTER="$(read_state 2>/dev/null || true)"
AFTER_REV="$(printf '%s' "$AFTER" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(String(JSON.parse(s).revision)))' 2>/dev/null)"
printf '%s' "$AFTER" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c).on("end",()=>{
    const j=JSON.parse(s);
    process.exit(j.active===true && j.reviewRound===0 && j.stopBlockCount===0
      && j.chainDone===false && j.codeReviewDone===false ? 0 : 1);
  });
' && check "fresh-task begin resets integrated budgets and re-arms chain flags" PASS \
  || check "fresh-task begin resets integrated budgets and re-arms chain flags" FAIL
[ "$AFTER_REV" -gt "$BEFORE_REV" ] && check "fresh-task reset advances the workflow revision" PASS \
  || check "fresh-task reset advances workflow revision (before=$BEFORE_REV after=$AFTER_REV)" FAIL

tdd_increment_counter "$SID" reviewRound >/dev/null
bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
[ "$(tdd_get_counter "$STATE_FILE" reviewRound)" = 1 ] && check "--tdd-complete preserves integrated reviewRound" PASS \
  || check "--tdd-complete preserves integrated reviewRound" FAIL
bash "$LOG" --chain-done --session "$SID" >/dev/null 2>&1
[ "$(tdd_get_counter "$STATE_FILE" reviewRound)" = 1 ] && check "--chain-done preserves integrated reviewRound" PASS \
  || check "--chain-done preserves integrated reviewRound" FAIL

# A retired sidecar pathname is inert. Neither fresh-task reset nor Stop reads,
# deletes, follows, or warns about it.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "  SKIP  inert stopblocks symlink checks — symlinks unavailable" ;;
  *)
    TARGET="$TMP_DIR/sidecar-target"
    printf '%s\n' 'do-not-touch' > "$TARGET"
    ln -s "$TARGET" "${STATE_FILE}.stopblocks"
    tdd_set_flag "$SID" chainDone false >/dev/null
    tdd_set_flag "$SID" codeReviewDone false >/dev/null
    tdd_set_flag "$SID" implComplete true >/dev/null
    RESET_REVISION="$(CONTROL_CORE="$CORE" PROJECT_ROOT="$ZENSU_PROJECT_ROOT" SID="$SID" node -e '
      const core=require(process.env.CONTROL_CORE);
      process.stdout.write(String(core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID}).revision));
    ')"
    tdd_reset_review_budget "$SID" "$RESET_REVISION" >/dev/null
    PAYLOAD="{\"hook_event_name\":\"Stop\",\"session_id\":\"${SID}\",\"cwd\":\"${CLAUDE_PROJECT_DIR}\"}"
    STOP_OUT="$(printf '%s' "$PAYLOAD" | "$STOP" 2>"$TMP_DIR/stop.err")"
    case "$STOP_OUT" in *'"decision":"block"'*) check "Stop still enforces with an inert .stopblocks symlink present" PASS ;; *) check "Stop still enforces with inert sidecar present" FAIL ;; esac
    [ -L "${STATE_FILE}.stopblocks" ] && [ "$(<"$TARGET")" = do-not-touch ] \
      && check "retired .stopblocks symlink and target are untouched" PASS \
      || check "retired .stopblocks symlink and target are untouched" FAIL
    [ "$(tdd_get_counter "$STATE_FILE" stopBlockCount)" = 1 ] \
      && check "Stop increments only the integrated stopBlockCount field" PASS \
      || check "Stop increments only the integrated stopBlockCount field" FAIL
    if grep -Eqi 'symlink|stopblocks file' "$TMP_DIR/stop.err"; then
      check "Stop emits no sidecar-specific warning" FAIL
    else
      check "Stop emits no sidecar-specific warning" PASS
    fi
    ;;
esac

if find "$STATE_DIR" -maxdepth 1 -name 'rounds-*' | grep -q .; then
  check "fresh-task reset creates no rounds sidecar" FAIL
else
  check "fresh-task reset creates no rounds sidecar" PASS
fi

echo "----"
echo "test-autofix-rounds-reset-on-fresh-tdd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
