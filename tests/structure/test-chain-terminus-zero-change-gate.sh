#!/bin/bash
# Pins the ZERO-file-change gate on the unqualified standalone chain terminus
# (zensu-log.sh --chain-done without --claimed-review-ticket):
#   G1 clean worktree                -> terminus allowed (the sanctioned escape)
#   G2 modified tracked file          -> refused, chainDone stays false
#   G3 untracked non-ignored file     -> refused (git ls-files --others)
#   G4 ignored-only change            -> allowed (--exclude-standard)
#   G5 --claimed-review-ticket form   -> gate never fires (terminus is ticket-bound)
#   G6 --code-review-done             -> gate never fires (not the terminus)
#   G7 non-git project root           -> allowed (claim not evaluable)
#   G8 git repo without a HEAD commit -> allowed (claim not evaluable)
# The unqualified form can only ever bind a chain in which no review ticket was
# consumed, so it is the one command that could close a chain over unreviewed
# changes. Complements test-stop-enforcer-escapes.sh (release paths) and
# test-stop-enforcer-self-review-routing.sh (block + routing).
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
GIT_PROJ="$(mktemp -d)"
BARE_PROJ="$(mktemp -d)"
PLAIN_PROJ="$(mktemp -d)"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$GIT_PROJ" "$BARE_PROJ" "$PLAIN_PROJ"; }
trap cleanup EXIT
# shellcheck disable=SC1090
source "$TDD_LIB"

git -C "$GIT_PROJ" init -q 2>/dev/null
git -C "$GIT_PROJ" config user.email t@t
git -C "$GIT_PROJ" config user.name t
printf '.zensu/\n.session-control-test/\n' > "$GIT_PROJ/.gitignore"
printf 'baseline\n' > "$GIT_PROJ/tracked.txt"
git -C "$GIT_PROJ" add .gitignore tracked.txt >/dev/null 2>&1
git -C "$GIT_PROJ" -c commit.gpgsign=false commit -qm baseline >/dev/null 2>&1
git -C "$BARE_PROJ" init -q 2>/dev/null

# Arm a standalone chain in $CLAUDE_PROJECT_DIR: active + implComplete, chainDone=false.
arm() {
  local sid="$1"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid"
  bash "$LOG" --tdd-begin --session "$sid" >/dev/null 2>&1
  bash "$LOG" --tdd-complete --session "$sid" >/dev/null 2>&1
}

GATE_PHRASE="refusing the unqualified standalone terminus"

export CLAUDE_PROJECT_DIR="$GIT_PROJ"

# --- G1 clean worktree: the sanctioned zero-change escape still closes ---
SID1="terminus-clean"
arm "$SID1"
ERR1="$STATE_DIR/g1.err"
bash "$LOG" --chain-done --session "$SID1" >/dev/null 2>"$ERR1"; RC1=$?
DONE1="$(tdd_chain_done "$(tdd_state_file "$SID1")" 2>/dev/null)"
if [ "$RC1" -eq 0 ] && [ "$DONE1" = "true" ] && [ ! -s "$ERR1" ]; then
  check "G1 clean worktree -> unqualified terminus closes the chain" PASS
else
  check "G1 clean worktree (rc=$RC1 chainDone=$DONE1 err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi

# --- G2 modified tracked file: refused, chain stays open ---
SID2="terminus-modified"
arm "$SID2"
printf 'changed\n' > "$GIT_PROJ/tracked.txt"
ERR2="$STATE_DIR/g2.err"
bash "$LOG" --chain-done --session "$SID2" >/dev/null 2>"$ERR2"; RC2=$?
DONE2="$(tdd_chain_done "$(tdd_state_file "$SID2")" 2>/dev/null)"
if [ "$RC2" -ne 0 ] && [ "$DONE2" != "true" ] && grep -qF "$GATE_PHRASE" "$ERR2"; then
  check "G2 modified tracked file -> terminus refused, chainDone stays false" PASS
else
  check "G2 modified tracked file (rc=$RC2 chainDone=$DONE2 err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi
if grep -qF "reports 1 changed file(s)" "$ERR2"; then
  check "G2a refusal names the exact changed-file count" PASS
else
  check "G2a refusal changed-file count (err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi
if grep -qF -- "--claimed-review-ticket" "$ERR2" && grep -qF "/zensu:tdd" "$ERR2"; then
  check "G2b refusal names both runnable continuations" PASS
else
  check "G2b refusal continuations (err='$(cat "$ERR2" 2>/dev/null)')" FAIL
fi

# --- G6 --code-review-done is not the terminus: gate must not fire ---
ERR6="$STATE_DIR/g6.err"
bash "$LOG" --code-review-done --session "$SID2" >/dev/null 2>"$ERR6"; RC6=$?
CRD6="$(tdd_code_review_done "$(tdd_state_file "$SID2")" 2>/dev/null)"
if [ "$RC6" -eq 0 ] && [ "$CRD6" = "true" ] && ! grep -qF "$GATE_PHRASE" "$ERR6"; then
  check "G6 --code-review-done unaffected by the terminus gate" PASS
else
  check "G6 --code-review-done (rc=$RC6 codeReviewDone=$CRD6 err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi

# --- G5 ticket-bound terminus: gate must not fire (it fails on the ticket) ---
ERR5="$STATE_DIR/g5.err"
bash "$LOG" --chain-done --session "$SID2" --claimed-review-ticket "rt_deadbeef" \
  >/dev/null 2>"$ERR5"; RC5=$?
if [ "$RC5" -ne 0 ] && ! grep -qF "$GATE_PHRASE" "$ERR5"; then
  check "G5 --claimed-review-ticket form never reaches the gate" PASS
else
  check "G5 ticket-bound form (rc=$RC5 err='$(cat "$ERR5" 2>/dev/null)')" FAIL
fi
git -C "$GIT_PROJ" checkout -- tracked.txt >/dev/null 2>&1

# --- G3 untracked non-ignored file: refused ---
SID3="terminus-untracked"
arm "$SID3"
printf 'new\n' > "$GIT_PROJ/untracked.txt"
ERR3="$STATE_DIR/g3.err"
bash "$LOG" --chain-done --session "$SID3" >/dev/null 2>"$ERR3"; RC3=$?
DONE3="$(tdd_chain_done "$(tdd_state_file "$SID3")" 2>/dev/null)"
if [ "$RC3" -ne 0 ] && [ "$DONE3" != "true" ] && grep -qF "$GATE_PHRASE" "$ERR3"; then
  check "G3 untracked non-ignored file -> terminus refused" PASS
else
  check "G3 untracked file (rc=$RC3 chainDone=$DONE3 err='$(cat "$ERR3" 2>/dev/null)')" FAIL
fi
rm -f "$GIT_PROJ/untracked.txt"

# --- G4 ignored-only change: allowed ---
SID4="terminus-ignored"
arm "$SID4"
mkdir -p "$GIT_PROJ/.zensu"
printf 'scratch\n' > "$GIT_PROJ/.zensu/scratch.txt"
ERR4="$STATE_DIR/g4.err"
bash "$LOG" --chain-done --session "$SID4" >/dev/null 2>"$ERR4"; RC4=$?
DONE4="$(tdd_chain_done "$(tdd_state_file "$SID4")" 2>/dev/null)"
if [ "$RC4" -eq 0 ] && [ "$DONE4" = "true" ]; then
  check "G4 gitignored-only change -> terminus allowed" PASS
else
  check "G4 ignored-only change (rc=$RC4 chainDone=$DONE4 err='$(cat "$ERR4" 2>/dev/null)')" FAIL
fi

# --- G7 non-git project root: claim not evaluable, legacy behaviour ---
export CLAUDE_PROJECT_DIR="$PLAIN_PROJ"
SID7="terminus-no-repo"
arm "$SID7"
ERR7="$STATE_DIR/g7.err"
bash "$LOG" --chain-done --session "$SID7" >/dev/null 2>"$ERR7"; RC7=$?
DONE7="$(tdd_chain_done "$(tdd_state_file "$SID7")" 2>/dev/null)"
if [ "$RC7" -eq 0 ] && [ "$DONE7" = "true" ]; then
  check "G7 non-git project root -> terminus allowed (not evaluable)" PASS
else
  check "G7 non-git root (rc=$RC7 chainDone=$DONE7 err='$(cat "$ERR7" 2>/dev/null)')" FAIL
fi

# --- G8 git repo without a HEAD commit: claim not evaluable ---
export CLAUDE_PROJECT_DIR="$BARE_PROJ"
SID8="terminus-no-head"
arm "$SID8"
ERR8="$STATE_DIR/g8.err"
bash "$LOG" --chain-done --session "$SID8" >/dev/null 2>"$ERR8"; RC8=$?
DONE8="$(tdd_chain_done "$(tdd_state_file "$SID8")" 2>/dev/null)"
if [ "$RC8" -eq 0 ] && [ "$DONE8" = "true" ]; then
  check "G8 git repo without HEAD -> terminus allowed (not evaluable)" PASS
else
  check "G8 no-HEAD repo (rc=$RC8 chainDone=$DONE8 err='$(cat "$ERR8" 2>/dev/null)')" FAIL
fi

echo "----"
echo "test-chain-terminus-zero-change-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
