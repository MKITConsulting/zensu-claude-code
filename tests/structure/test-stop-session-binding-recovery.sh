#!/bin/bash
# Pins the recovery paths of stop-chain-enforcer.sh when the immutable session
# binding cannot be resolved — the states that used to wedge a session forever
# because the release switches are only read further down the hook:
#   B0 healthy bound session                   -> still blocks (control)
#   B1 recorded project root deleted           -> binding fails: cause on stderr, remedies named,
#                                                 and ZENSU_CHAIN=off actually releases it
#   B3 same session, chainEnforcer=false       -> release
#   B4 root replaced by a symlink, no opt-out  -> block, cause named, no bypass in the reason
#                                                 (skipped where directory symlinks are unavailable)
#   B5 block reasons stay field-free           -> no interpolation in any emit payload
#   B6 session with no record at all           -> block, missing-record cause routed to a fresh
#                                                 session and to /zensu:doctor, still releasable
# The release switches used to be unreachable here: they are read ~300 lines
# below these blocks, so a session whose worktree was deleted could never end a
# turn again. B1c is the regression pin for that wedge.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
PROJECTS="$STATE_DIR/projects"
mkdir -p "$PROJECTS"
cleanup() { chmod -R u+w "$STATE_DIR" 2>/dev/null; rm -rf "$STATE_DIR"; }
trap cleanup EXIT

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason()   { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }

# Arm a blocking standalone chain in a fresh project root (never in a subshell:
# the baseline exports the plugin-data path the hook binds against).
ARMED_ROOT=""
arm() {
  local label="$1"
  local project="$PROJECTS/$label"
  mkdir -p "$project"
  project="$(cd "$project" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data/$label"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$label" || return 1
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  ARMED_ROOT="$ZENSU_PROJECT_ROOT"
}

stop_run() {
  local raw="$1" errfile="$2"
  shift 2
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$raw" | env "$@" bash "$STOP" 2>"$errfile"
}

# --- B0 control: a healthy bound session still blocks ---
arm stop-bind-control || { echo "B0 fixture failed" >&2; exit 1; }
ROOT0="$ARMED_ROOT"
ERR0="$STATE_DIR/b0.err"
OUT0="$(stop_run stop-bind-control "$ERR0" IGNORE=1)"
REASON0="$(printf '%s' "$OUT0" | reason)"
if [ "$(printf '%s' "$OUT0" | decision)" = "block" ] \
  && printf '%s' "$REASON0" | grep -qF 'zensu:code-reviewer'; then
  check "B0 healthy bound session still blocks on the chain reason" PASS
else
  check "B0 healthy bound session (out=$OUT0)" FAIL
fi

# --- B1 recorded project root deleted -> the authoritative cause plus a way out ---
arm stop-bind-deleted || { echo "B1 fixture failed" >&2; exit 1; }
ROOT1="$ARMED_ROOT"
rm -rf "$ROOT1"
[ ! -d "$ROOT1" ] || { echo "B1 fixture: project root still present" >&2; exit 1; }
ERR1="$STATE_DIR/b1.err"
OUT1="$(stop_run stop-bind-deleted "$ERR1" IGNORE=1)"
REASON1="$(printf '%s' "$OUT1" | reason)"
if [ "$(printf '%s' "$OUT1" | decision)" = "block" ] \
  && grep -qF "context project root does not exist" "$ERR1"; then
  check "B1 deleted project root fails binding, not resolution (cause on stderr)" PASS
else
  check "B1 deleted project root (out=$OUT1 err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
if grep -qF "re-create exactly that directory" "$ERR1" \
  && grep -qF "start a new session" "$ERR1" \
  && grep -qF "the record is immutable" "$ERR1" \
  && grep -qF "a record exists here and disagrees" "$ERR1" \
  && grep -qF 'ZENSU_CHAIN=off or hooks.chainEnforcer=false' "$ERR1"; then
  check "B1a stderr names the deleted-worktree remedies, its own scope, and the release switches" PASS
else
  check "B1a bind diagnostic (err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
# The reason must name BOTH known causes rather than ranking one as "the common
# one": it used to assert the deleted-worktree guess, which sent the user hunting
# a worktree while the real cause was a session resumed across a plugin update —
# that session simply has no record, because resume never mints one.
# This block is now reached ONLY for a record that exists and disagrees — a
# session with no record at all is released before it (B6). The reason must say
# so, must not rank a guess as "the common one" the way it used to, and must not
# send the user to /zensu:doctor, which is itself denied in this exact state.
if printf '%s' "$REASON1" | grep -qF 'cannot be bound to the immutable Session Control record' \
  && printf '%s' "$REASON1" | grep -qF 'a deleted or moved worktree' \
  && printf '%s' "$REASON1" | grep -qF 'released earlier' \
  && printf '%s' "$REASON1" | grep -qF 'most often a record exists here and disagrees' \
  && printf '%s' "$REASON1" | grep -qF 'can also simply fail to evaluate' \
  && printf '%s' "$REASON1" | grep -qF 'Where a record does disagree' \
  && ! printf '%s' "$REASON1" | grep -qF 'the common one' \
  && ! printf '%s' "$REASON1" | grep -qF 'ZENSU_CHAIN' \
  && ! printf '%s' "$REASON1" | grep -qF 'chainEnforcer'; then
  check "B1b reason hedges between a disagreeing record and an unevaluable check, teaches no bypass, and scopes the doctor advice" PASS
else
  check "B1b bind reason (reason='$REASON1')" FAIL
fi
ERR1B="$STATE_DIR/b1b.err"
OUT1B="$(stop_run stop-bind-deleted "$ERR1B" ZENSU_CHAIN=off)"
if [ "$(printf '%s' "$OUT1B" | decision)" = "allow" ] \
  && grep -qF "ZENSU_CHAIN=off is set explicitly" "$ERR1B"; then
  check "B1c the deleted-root session is releasable, no longer wedged forever" PASS
else
  check "B1c deleted-root release (out=$OUT1B err='$(cat "$ERR1B" 2>/dev/null)')" FAIL
fi

# --- B3 the config switch reaches the same unbindable state ---
CFG_OFF="$STATE_DIR/enforcer-off.json"
printf '{"hooks":{"chainEnforcer":false}}' > "$CFG_OFF"
ERR3="$STATE_DIR/b3.err"
OUT3="$(stop_run stop-bind-deleted "$ERR3" "ZENSU_CONFIG=$CFG_OFF")"
if [ "$(printf '%s' "$OUT3" | decision)" = "allow" ] \
  && grep -qF "hooks.chainEnforcer=false is configured" "$ERR3"; then
  check "B3 hooks.chainEnforcer=false releases the same deleted-root session" PASS
else
  check "B3 chainEnforcer=false (out=$OUT3 err='$(cat "$ERR3" 2>/dev/null)')" FAIL
fi

# --- B6 the session has NO record at all -----------------------------------
# The 0.17.0 mass failure: Session Control shipped in that release, and a
# resume/compact SessionStart requires a record it never mints, so every session
# predating the update is unbindable. Same hook path as B1, different cause —
# the stderr line must distinguish them instead of sending the user worktree
# hunting, and the escape must still work so the session can end its turn.
arm stop-bind-norecord || { echo "B6 fixture failed" >&2; exit 1; }
ERR6="$STATE_DIR/b6.err"
OUT6="$(stop_run "a-session-that-was-never-registered" "$ERR6" IGNORE=1)"
# Such a session has no workflow document, so there is no review chain and no
# Autopilot run to enforce and nothing is waived. The PreToolUse gates relax the
# same state, so blocking here would leave the user with tools but no way to end
# a turn — strictly worse than the deadlock this release fixes.
if [ "$(printf '%s' "$OUT6" | decision)" = "allow" ]; then
  check "B6 a session with no Session Control record releases Stop instead of wedging" PASS
else
  check "B6 unregistered session (out=$OUT6 err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi
if grep -qF "no record for this session" "$ERR6" \
  && grep -qF "none was waived" "$ERR6" \
  && grep -qF "without --continue/--resume" "$ERR6" \
  && grep -qF "/zensu:doctor" "$ERR6"; then
  check "B6a the release states no completion was proven and routes to a fresh session" PASS
else
  check "B6a missing-record diagnostic (err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi
# The release is bound to that ONE state: a deleted project root still blocks
# (B1 above), and the two diagnostics must stay distinguishable.
if ! grep -qF "context project root does not exist" "$ERR6" \
  && ! grep -qF "missing file" "$ERR1"; then
  check "B6b the no-record and deleted-root diagnostics never collapse into one" PASS
else
  check "B6b diagnostic distinction (b6='$(cat "$ERR6" 2>/dev/null)' b1='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
# Releasing must not require an opt-out switch, and must not teach one either.
if ! grep -qF 'ZENSU_CHAIN=off' "$ERR6" && ! grep -qF 'chainEnforcer' "$ERR6"; then
  check "B6c the no-record release needs no bypass and advertises none" PASS
else
  check "B6c no-record release advertises a bypass (err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi

# --- root replaced by a symlink: a resolvable path with an unusable record.
# Windows without developer mode cannot create one, so probe before relying on it.
SYMLINK_OK=true
if ! ln -s "$STATE_DIR" "$STATE_DIR/symlink-probe" 2>/dev/null || [ ! -L "$STATE_DIR/symlink-probe" ]; then
  SYMLINK_OK=false
fi
rm -f "$STATE_DIR/symlink-probe" 2>/dev/null

replace_root_with_symlink() {
  local root="$1"
  mv "$root" "${root}.real" || return 1
  ln -s "${root}.real" "$root" || return 1
  [ -L "$root" ] && [ -d "$root" ]
}

# --- B4 without an opt-out it still blocks, but says which cause and how to fix ---
if [ "$SYMLINK_OK" != true ]; then
  check "B4 unusable-record branch skipped: this platform cannot create directory symlinks" PASS
else
arm stop-bind-record || { echo "B4 fixture failed" >&2; exit 1; }
ROOT4="$ARMED_ROOT"
replace_root_with_symlink "$ROOT4" || { echo "B4 fixture: symlink swap failed" >&2; exit 1; }
ERR4="$STATE_DIR/b4.err"
OUT4="$(stop_run stop-bind-record "$ERR4" IGNORE=1)"
REASON4="$(printf '%s' "$OUT4" | reason)"
if [ "$(printf '%s' "$OUT4" | decision)" = "block" ] \
  && printf '%s' "$REASON4" | grep -qF 'no longer resolves against its recorded project root' \
  && printf '%s' "$REASON4" | grep -qF 'Restore that path'; then
  check "B4 unusable record blocks with its own cause and remedy" PASS
else
  check "B4 unusable record (out=$OUT4)" FAIL
fi
if ! printf '%s' "$REASON4" | grep -qF 'ZENSU_CHAIN' \
  && ! printf '%s' "$REASON4" | grep -qF 'chainEnforcer' \
  && grep -qF 'ZENSU_CHAIN=off or hooks.chainEnforcer=false' "$ERR4" \
  && grep -qF "$ROOT4" "$ERR4"; then
  check "B4a release switches stay operator-facing, never in the model reason" PASS
else
  check "B4a switch placement (reason='$REASON4' err='$(cat "$ERR4" 2>/dev/null)')" FAIL
fi
if printf '%s' "$REASON4" | grep -qF 'Zensu Stop denied: the immutable Session Control record' \
  && ! printf '%s' "$REASON4" | grep -qF 'the immutable main-session binding is unavailable'; then
  check "B4b the single all-causes reason was replaced by a specific one" PASS
else
  check "B4b cause-specific reason (reason='$REASON4')" FAIL
fi
fi

# --- B5 every binding block payload stays field-free ---
BLOCK_BODIES="$(sed -n '/^emit_session_runtime_missing_block()/,/^}/p;/^emit_session_bind_failed_block()/,/^}/p;/^emit_session_record_unusable_block()/,/^}/p' "$STOP")"
BLOCK_COUNT="$(printf '%s\n' "$BLOCK_BODIES" | grep -c "^  printf '%s")"
if [ "$BLOCK_COUNT" -eq 3 ] && ! printf '%s\n' "$BLOCK_BODIES" | grep -q '\$'; then
  check "B5 all three binding block reasons are static literals" PASS
else
  check "B5 static block reasons (literals=$BLOCK_COUNT)" FAIL
fi

echo "----"
echo "test-stop-session-binding-recovery: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
