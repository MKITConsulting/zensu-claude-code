#!/bin/bash
# State/review budgets reject symlinked ancestors and non-regular leaves.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
POST="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

ROOT="$(mktemp -d -t zensu-state-safety-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$ROOT/no-config.json"

run_begin() {
  local project="$1" state_dir="$2" rounds_dir="$3" sid="$4"
  CLAUDE_PROJECT_DIR="$project" TDD_STATE_DIR="$state_dir" \
    CLAUDE_PLUGIN_DATA_OVERRIDE="$rounds_dir" bash "$LOG" --tdd-begin --session "$sid" >/dev/null 2>&1
}

run_post() {
  local project="$1" state_dir="$2" rounds_dir="$3" sid="$4" ticket="$5"
  SID="$sid" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({session_id:process.env.SID,tool_input:{
      subagent_type:"zensu:code-reviewer",
      prompt:`PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
    }}));
  ' | CLAUDE_PROJECT_DIR="$project" TDD_STATE_DIR="$state_dir" \
      CLAUDE_PLUGIN_DATA_OVERRIDE="$rounds_dir" bash "$POST" 2>/dev/null
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

# Default project/.zensu is an untrusted path component, not a trusted anchor.
P1="$ROOT/project-symlink"; V1="$ROOT/victim-symlink"
mkdir -p "$P1" "$V1/state"
printf 'sentinel\n' > "$V1/state/rounds-linkproof.json"
if make_directory_symlink "$V1" "$P1/.zensu" \
  && ! CLAUDE_PROJECT_DIR="$P1" TDD_STATE_DIR= CLAUDE_PLUGIN_DATA_OVERRIDE= \
    bash "$LOG" --tdd-begin --session linkproof >/dev/null 2>&1 \
  && [ "$(cat "$V1/state/rounds-linkproof.json")" = sentinel ] \
  && [ ! -e "$V1/state/tdd-phase-linkproof.json" ]; then
  check "P1 intermediate project-state symlink cannot escape the worktree" PASS
else
  check "P1 intermediate project-state symlink cannot escape the worktree" FAIL
fi

# A deeper explicit path through an intermediate symlink is rejected too.
P2="$ROOT/project-explicit"; V2="$ROOT/victim-explicit"
mkdir -p "$P2" "$V2/real-subdir/state"
if make_directory_symlink "$V2" "$P2/link" \
  && ! run_begin "$P2" "$P2/link/real-subdir/state" "$P2/link/real-subdir/state" deep-link \
  && [ ! -e "$V2/real-subdir/state/tdd-phase-deep-link.json" ]; then
  check "P2 deep intermediate symlink is checked below the trusted root" PASS
else
  check "P2 deep intermediate symlink is checked below the trusted root" FAIL
fi

# Directories and FIFOs cannot act as state-file leaves.
P3="$ROOT/project-leaves"; S3="$P3/state"
mkdir -p "$S3/tdd-phase-dirleaf.json"
if ! run_begin "$P3" "$S3" "$S3" dirleaf \
  && [ -d "$S3/tdd-phase-dirleaf.json" ] \
  && [ -z "$(find "$S3/tdd-phase-dirleaf.json" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  check "P3 directory state leaf cannot report a successful begin" PASS
else
  check "P3 directory state leaf cannot report a successful begin" FAIL
fi

mkfifo "$S3/tdd-phase-fifoleaf.json"
if ! run_begin "$P3" "$S3" "$S3" fifoleaf && [ -p "$S3/tdd-phase-fifoleaf.json" ]; then
  check "P4 FIFO state leaf is rejected without replacement" PASS
else
  check "P4 FIFO state leaf is rejected without replacement" FAIL
fi

# A non-regular derived counter must not consume its one-shot ticket.
SID_DIR_COUNTER=dircounter
run_begin "$P3" "$S3" "$S3" "$SID_DIR_COUNTER"
CLAUDE_PROJECT_DIR="$P3" TDD_STATE_DIR="$S3" CLAUDE_PLUGIN_DATA_OVERRIDE="$S3" \
  bash "$LOG" --tdd-complete --session "$SID_DIR_COUNTER" >/dev/null
TICKET_DIR="$(CLAUDE_PROJECT_DIR="$P3" TDD_STATE_DIR="$S3" CLAUDE_PLUGIN_DATA_OVERRIDE="$S3" \
  bash "$LOG" --review-ticket --session "$SID_DIR_COUNTER")"
mkdir "$S3/rounds-${SID_DIR_COUNTER}.json"
OUT_DIR="$(run_post "$P3" "$S3" "$S3" "$SID_DIR_COUNTER" "$TICKET_DIR")"
STATE_DIR_COUNTER="$S3/tdd-phase-${SID_DIR_COUNTER}.json"
if [ -z "$OUT_DIR" ] && [ -d "$S3/rounds-${SID_DIR_COUNTER}.json" ] \
  && node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(j.reviewTicketConsumed===false&&j.reviewRound===0?0:1)' "$STATE_DIR_COUNTER"; then
  check "P5 directory counter leaf cannot consume/reset the budget" PASS
else
  check "P5 directory counter leaf cannot consume/reset the budget" FAIL
fi

SID_FIFO_COUNTER=fifocounter
run_begin "$P3" "$S3" "$S3" "$SID_FIFO_COUNTER"
CLAUDE_PROJECT_DIR="$P3" TDD_STATE_DIR="$S3" CLAUDE_PLUGIN_DATA_OVERRIDE="$S3" \
  bash "$LOG" --tdd-complete --session "$SID_FIFO_COUNTER" >/dev/null
TICKET_FIFO="$(CLAUDE_PROJECT_DIR="$P3" TDD_STATE_DIR="$S3" CLAUDE_PLUGIN_DATA_OVERRIDE="$S3" \
  bash "$LOG" --review-ticket --session "$SID_FIFO_COUNTER")"
mkfifo "$S3/rounds-${SID_FIFO_COUNTER}.json"
OUT_FIFO="$(run_post "$P3" "$S3" "$S3" "$SID_FIFO_COUNTER" "$TICKET_FIFO")"
if [ -z "$OUT_FIFO" ] && [ -p "$S3/rounds-${SID_FIFO_COUNTER}.json" ] \
  && node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(j.reviewTicketConsumed===false&&j.reviewRound===0?0:1)' "$S3/tdd-phase-${SID_FIFO_COUNTER}.json"; then
  check "P6 FIFO counter leaf cannot consume/reset the budget" PASS
else
  check "P6 FIFO counter leaf cannot consume/reset the budget" FAIL
fi

# Deleting/corrupting the derived counter cannot lower authoritative reviewRound.
SID_AUTH=authoritative
run_begin "$P3" "$S3" "$S3" "$SID_AUTH"
CLAUDE_PROJECT_DIR="$P3" TDD_STATE_DIR="$S3" CLAUDE_PLUGIN_DATA_OVERRIDE="$S3" \
  bash "$LOG" --tdd-complete --session "$SID_AUTH" >/dev/null
node -e 'const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p));j.reviewRound=4;fs.writeFileSync(p,JSON.stringify(j,null,2));' \
  "$S3/tdd-phase-${SID_AUTH}.json"
printf '{malformed\n' > "$S3/rounds-${SID_AUTH}.json"
TICKET_AUTH="$(CLAUDE_PROJECT_DIR="$P3" TDD_STATE_DIR="$S3" CLAUDE_PLUGIN_DATA_OVERRIDE="$S3" \
  bash "$LOG" --review-ticket --session "$SID_AUTH")"
OUT_AUTH="$(run_post "$P3" "$S3" "$S3" "$SID_AUTH" "$TICKET_AUTH")"
if printf '%s' "$OUT_AUTH" | grep -q hookSpecificOutput \
  && node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(j.reviewRound===5?0:1)' "$S3/tdd-phase-${SID_AUTH}.json" \
  && node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.exit(j.count===5?0:1)' "$S3/rounds-${SID_AUTH}.json"; then
  check "P7 state.reviewRound remains authoritative over the derived counter" PASS
else
  check "P7 state.reviewRound remains authoritative over the derived counter" FAIL
fi

# Explicit state roots may live on a mounted/shared sibling outside the project,
# configured temp root, and configured home. Only the existing parents are
# created up front so the validator must select an ancestor and inspect every
# new component before either override is used.
P8="$ROOT/project-outside-anchor"
TMP8="$ROOT/runtime-temp-anchor"
HOME8="$ROOT/runtime-home-anchor"
STATE_PARENT8="$ROOT/external-state-parent"
ROUNDS_PARENT8="$ROOT/external-rounds-parent"
S8="$STATE_PARENT8/deep/state"
R8="$ROUNDS_PARENT8/deep/rounds"
mkdir -p "$P8" "$TMP8" "$HOME8" "$STATE_PARENT8" "$ROUNDS_PARENT8"
if env TMPDIR="$TMP8" HOME="$HOME8" CLAUDE_PROJECT_DIR="$P8" \
    TDD_STATE_DIR="$S8" CLAUDE_PLUGIN_DATA_OVERRIDE="$R8" \
    bash "$LOG" --tdd-begin --session outside-anchor >/dev/null 2>&1 \
  && [ -f "$S8/tdd-phase-outside-anchor.json" ] \
  && [ ! -L "$S8/tdd-phase-outside-anchor.json" ] \
  && [ -d "$R8" ] && [ ! -L "$R8" ]; then
  check "P8 explicit state roots outside project, temp, and home use a safe existing ancestor" PASS
else
  check "P8 explicit outside state roots remain supported" FAIL
fi

echo "----"
echo "test-tdd-state-path-safety: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
