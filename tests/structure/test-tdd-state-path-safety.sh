#!/bin/bash
# Canonical Session Control workflow state rejects symlinked ancestors and
# non-regular leaves, and retired ambient state-root knobs cannot redirect it.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
POST="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

ROOT="$(mktemp -d -t zensu-state-safety-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$ROOT/no-config.json"
unset TDD_STATE_DIR CLAUDE_PLUGIN_DATA_OVERRIDE 2>/dev/null || true

# Start a real Claude SessionStart baseline and expose its canonical workflow
# identity to the remainder of the current case.
start_session() {
  local project="$1" raw_sid="$2"
  mkdir -p "$project"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$project/.session-control-test/plugin-data"
  export ZENSU_TEST_ENV_FILE="$project/.session-control-test/${raw_sid}.env"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_sid" || return 1
  CLAUDE_PROJECT_DIR="$ZENSU_PROJECT_ROOT"; export CLAUDE_PROJECT_DIR
  SID="$ZENSU_SESSION_KEY"
  STATE_DIR="$ZENSU_PROJECT_ROOT/.zensu/state"
  STATE_FILE="$STATE_DIR/tdd-phase-${SID}.json"
}

run_begin() {
  bash "$LOG" --tdd-begin --session "$1" >/dev/null 2>&1
}

run_post() {
  local sid="$1" ticket="$2"
  SID="$sid" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({session_id:process.env.SID,tool_input:{
      subagent_type:"zensu:code-reviewer",
      prompt:`PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
    }}));
  ' | bash "$POST" 2>/dev/null
}

make_directory_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"junction":"dir");
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}

# The project-local .zensu boundary is untrusted. The real SessionStart
# baseline must fail before a symlink can redirect workflow initialization.
P1="$ROOT/project-symlink"; V1="$ROOT/victim-symlink"
mkdir -p "$P1" "$V1/state"
printf 'sentinel\n' > "$V1/state/sentinel.txt"
if make_directory_symlink "$V1" "$P1/.zensu" \
  && ! (start_session "$P1" linkproof) >/dev/null 2>&1 \
  && [ "$(cat "$V1/state/sentinel.txt")" = sentinel ] \
  && ! find "$V1" -name 'tdd-phase-scv1_*.json' -print -quit | grep -q .; then
  check "P1 project-state symlink cannot escape the worktree at SessionStart" PASS
else
  check "P1 project-state symlink cannot escape the worktree at SessionStart" FAIL
fi

# The fixed .zensu/state component is checked independently as well.
P2="$ROOT/project-state-symlink"; V2="$ROOT/victim-state-symlink"
mkdir -p "$P2/.zensu" "$V2"
printf 'sentinel\n' > "$V2/sentinel.txt"
if make_directory_symlink "$V2" "$P2/.zensu/state" \
  && ! (start_session "$P2" state-linkproof) >/dev/null 2>&1 \
  && [ "$(cat "$V2/sentinel.txt")" = sentinel ] \
  && ! find "$V2" -name 'tdd-phase-scv1_*.json' -print -quit | grep -q .; then
  check "P2 canonical state-directory symlink is rejected at SessionStart" PASS
else
  check "P2 canonical state-directory symlink is rejected at SessionStart" FAIL
fi

# The remaining cases share one immutable SessionStart identity. Each case
# restores the exact idle baseline bytes so no prior adversarial leaf can leak
# state into the next assertion (and the runtime digest stays stable longer).
P_CANONICAL="$ROOT/project-canonical"
start_session "$P_CANONICAL" canonical-safety
BASELINE_STATE="$P_CANONICAL/session-start-baseline.json"
cp "$STATE_FILE" "$BASELINE_STATE"
restore_baseline() {
  if [ -d "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
    rmdir "$STATE_FILE" 2>/dev/null || return 1
  else
    rm -f "$STATE_FILE" || return 1
  fi
  cp "$BASELINE_STATE" "$STATE_FILE"
}

# Directories and FIFOs cannot replace the canonical workflow-document leaf.
rm -f "$STATE_FILE"
mkdir "$STATE_FILE"
if ! run_begin "$SID" \
  && [ -d "$STATE_FILE" ] \
  && [ -z "$(find "$STATE_FILE" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  check "P3 directory workflow leaf cannot report a successful begin" PASS
else
  check "P3 directory workflow leaf cannot report a successful begin" FAIL
fi

restore_baseline
rm -f "$STATE_FILE"
mkfifo "$STATE_FILE"
if ! run_begin "$SID" && [ -p "$STATE_FILE" ]; then
  check "P4 FIFO workflow leaf is rejected without replacement" PASS
else
  check "P4 FIFO workflow leaf is rejected without replacement" FAIL
fi

# Replacing an armed canonical workflow leaf with a non-regular object must not
# let the reviewer hook emit a handoff or mutate the saved one-shot ticket.
restore_baseline
run_begin "$SID"
bash "$LOG" --tdd-complete --session "$SID" >/dev/null
TICKET_DIR="$(bash "$LOG" --review-ticket --session "$SID")"
SAVED_DIR="$P_CANONICAL/saved-before-directory.json"
cp "$STATE_FILE" "$SAVED_DIR"
rm -f "$STATE_FILE"
mkdir "$STATE_FILE"
OUT_DIR="$(run_post "$SID" "$TICKET_DIR")"
if [ -z "$OUT_DIR" ] && [ -d "$STATE_FILE" ] \
  && [ -z "$(find "$STATE_FILE" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] \
  && node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(j.reviewTicketConsumed===false&&j.reviewRound===0?0:1)' "$SAVED_DIR"; then
  check "P5 directory workflow leaf cannot consume the one-shot review ticket" PASS
else
  check "P5 directory workflow leaf cannot consume the one-shot review ticket" FAIL
fi

restore_baseline
run_begin "$SID"
bash "$LOG" --tdd-complete --session "$SID" >/dev/null
TICKET_FIFO="$(bash "$LOG" --review-ticket --session "$SID")"
SAVED_FIFO="$P_CANONICAL/saved-before-fifo.json"
cp "$STATE_FILE" "$SAVED_FIFO"
rm -f "$STATE_FILE"
mkfifo "$STATE_FILE"
OUT_FIFO="$(run_post "$SID" "$TICKET_FIFO")"
if [ -z "$OUT_FIFO" ] && [ -p "$STATE_FILE" ] \
  && node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(j.reviewTicketConsumed===false&&j.reviewRound===0?0:1)' "$SAVED_FIFO"; then
  check "P6 FIFO workflow leaf cannot consume the one-shot review ticket" PASS
else
  check "P6 FIFO workflow leaf cannot consume the one-shot review ticket" FAIL
fi

# reviewRound is integrated into the canonical CAS document. A malformed file
# at the retired rounds-* pathname is inert and must remain byte-identical.
restore_baseline
run_begin "$SID"
bash "$LOG" --tdd-complete --session "$SID" >/dev/null
CONTROL_CORE="$CORE" PROJECT_ROOT="$ZENSU_PROJECT_ROOT" SESSION_KEY="$SID" node -e '
  const core=require(process.env.CONTROL_CORE);
  const previous=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SESSION_KEY});
  core.mutateWorkflowState({
    projectRoot:process.env.PROJECT_ROOT,
    sessionId:process.env.SESSION_KEY,
    expectedRevision:previous.revision,
    workflowState:"reviewing",
    event:"review-budget-primed",
  }, (state) => { state.reviewRound=4; return state; });
'
RETIRED_COUNTER="$STATE_DIR/rounds-${SID}.json"
printf '{malformed\n' > "$RETIRED_COUNTER"
TICKET_AUTH="$(bash "$LOG" --review-ticket --session "$SID")"
OUT_AUTH="$(run_post "$SID" "$TICKET_AUTH")"
if printf '%s' "$OUT_AUTH" | grep -q hookSpecificOutput \
  && CONTROL_CORE="$CORE" PROJECT_ROOT="$ZENSU_PROJECT_ROOT" SESSION_KEY="$SID" node -e '
    const core=require(process.env.CONTROL_CORE);
    const j=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SESSION_KEY});
    process.exit(j.reviewRound===5?0:1);
  ' \
  && [ "$(cat "$RETIRED_COUNTER")" = '{malformed' ]; then
  check "P7 integrated reviewRound ignores a malformed retired counter sidecar" PASS
else
  check "P7 integrated reviewRound ignores a malformed retired counter sidecar" FAIL
fi

# Retired ambient roots are not a compatibility fallback. Even when supplied,
# all mutations remain in the SessionStart-bound project CAS document.
S8="$ROOT/retired-state-override/deep/state"
R8="$ROOT/retired-plugin-data-override/deep/rounds"
restore_baseline
export TDD_STATE_DIR="$S8"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$R8"
if run_begin "$SID" \
  && [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] \
  && [[ "$(basename "$STATE_FILE")" =~ ^tdd-phase-scv1_[a-f0-9]{64}\.json$ ]] \
  && [ ! -e "$S8" ] && [ ! -e "$R8" ]; then
  check "P8 ambient state roots cannot redirect the canonical workflow document" PASS
else
  check "P8 canonical project-bound state remains authoritative" FAIL
fi

echo "----"
echo "test-tdd-state-path-safety: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
