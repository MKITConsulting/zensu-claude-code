#!/bin/bash
# Pins the implementing-phase turn counter and the two surfaces that read it.
#
# The hole: stop-chain-enforcer.sh releases Stop unconditionally while
# implementation is not marked complete, so a chain armed with --tdd-begin whose
# session never runs --tdd-complete is never asked for a reviewer, and the doctor
# reported it only in an OK-severity count row.
#
# What is pinned here, and the ORDER of the first three matters because they are
# the properties that distinguish this fix from the two that were rejected:
#   1. the counter advances per TURN, never per elapsed second, so a paused
#      session and a powered-off machine advance it by zero;
#   2. it advances only while the worktree actually reports a changed file;
#   3. the Stop nudge is ADVISORY — it writes stderr and still releases, and it
#      must never emit a decision:"block" payload from this branch, because a
#      long legitimate implementation genuinely does span many turns.
# Then: the threshold and its 0-disables semantics, and the doctor WARN row.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
REPORT="$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
PROJ="$(mktemp -d)"
PROJ="$(cd "$PROJ" && pwd -P)"; export CLAUDE_PROJECT_DIR="$PROJ"
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
# C10..C12 execute the doctor renderer, which reads HOME for the user-scoped
# config AND for ~/.claude/settings.json. Without this sandbox those checks would
# grade whatever the developer's real settings happen to contain.
HOME="$STATE_DIR/home"; export HOME
mkdir -p "$HOME"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$STATE_DIR" "$PROJ"; }
trap cleanup EXIT

git -C "$PROJ" init -q
git -C "$PROJ" config user.email "suite@example.invalid"
git -C "$PROJ" config user.name "suite"
printf 'base\n' > "$PROJ/tracked.txt"
# The chain's own workflow document lives under <project>/.zensu/. Without this
# the fixture can never present a CLEAN worktree — `?? .zensu/` is a change like
# any other — and C1 would be testing nothing. It also matches what a real
# consuming project does: this repository's own .gitignore ignores .zensu/*.
printf '.zensu/\n' > "$PROJ/.gitignore"
git -C "$PROJ" add tracked.txt .gitignore >/dev/null 2>&1
git -C "$PROJ" commit -qm base >/dev/null 2>&1

cfg_with() {  # $1 = threshold; prints a config path
  local f="$STATE_DIR/cfg-$1.json"
  printf '{"hooks":{"implStopNudgeAfter":%s}}\n' "$1" > "$f"
  printf '%s' "$f"
}

payload() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$1"; }
stop_out() { printf '%s' "$(payload "$1")" | ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$STOP" 2>/dev/null; }
stop_err() { printf '%s' "$(payload "$1")" | ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$STOP" 2>&1 >/dev/null; }
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }

counter_of() {  # $1 = session key
  bash -c '
    set -u
    # shellcheck disable=SC1090
    source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || { echo unavailable; exit 0; }
    f="$(tdd_state_file "$2")" || { echo unavailable; exit 0; }
    tdd_get_counter "$f" implStopCount
  ' _ "$PLUGIN_DIR" "$1" 2>/dev/null
}

# Every stop_out/stop_err after this resolves against the session started LAST,
# because initialize-baseline.sh exports the derived CLAUDE_PLUGIN_DATA into this
# shell. STARTED_PLUGIN_DATA is captured so a check can name the session it means
# rather than relying on scenario order; the "counter unchanged" checks below all
# run before the next start_session, and C16 states that dependency where it uses it.
start_session() {
  local raw_session="$1" label="${2:-$1}" project="${3:-$PROJ}"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data/$label"
  STARTED_PLUGIN_DATA="$STATE_DIR/plugin-data/$label"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$raw_session" "$PLUGIN_DIR" \
    || exit 1
  [ -n "${ZENSU_SESSION_KEY:-}" ] || exit 1
  STARTED_SESSION_KEY="$ZENSU_SESSION_KEY"
}

dirty()  { printf 'changed %s\n' "$RANDOM" > "$PROJ/tracked.txt"; }
# Deliberately NOT `git clean -fdq`: that removes the ignored .zensu/ directory
# too, which is where the chain this suite is driving keeps its own workflow
# document. An earlier revision did exactly that and the session under test
# vanished mid-scenario.
clean_wt() { git -C "$PROJ" checkout -- tracked.txt >/dev/null 2>&1; }

# --- C1: clean worktree never advances the counter -------------------------
CFG5="$(cfg_with 5)"
C1_RAW="impl-clean"
start_session "$C1_RAW"
C1="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C1" >/dev/null 2>&1
clean_wt
OUT="$(stop_out "$C1_RAW" "$CFG5")"
[ "$(printf '%s' "$OUT" | decision)" = "allow" ] \
  && check "C1a implementing + clean worktree still releases Stop" PASS \
  || check "C1a implementing + clean worktree still releases Stop" FAIL
[ "$(counter_of "$C1")" = "0" ] \
  && check "C1b a clean worktree does not advance the counter" PASS \
  || check "C1b a clean worktree does not advance the counter (got $(counter_of "$C1"))" FAIL

# --- C2/C3: a dirty worktree advances it once per TURN ---------------------
C2_RAW="impl-dirty"
start_session "$C2_RAW"
C2="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C2" >/dev/null 2>&1
dirty
OUT="$(stop_out "$C2_RAW" "$CFG5")"
[ "$(printf '%s' "$OUT" | decision)" = "allow" ] \
  && check "C2a a counted turn still releases Stop" PASS \
  || check "C2a a counted turn still releases Stop" FAIL
[ "$(counter_of "$C2")" = "1" ] \
  && check "C2b one Stop with a changed worktree counts exactly one turn" PASS \
  || check "C2b one Stop with a changed worktree counts exactly one turn (got $(counter_of "$C2"))" FAIL
stop_out "$C2_RAW" "$CFG5" >/dev/null
stop_out "$C2_RAW" "$CFG5" >/dev/null
[ "$(counter_of "$C2")" = "3" ] \
  && check "C3 three turns count three, so the unit is turns and not seconds" PASS \
  || check "C3 three turns count three (got $(counter_of "$C2"))" FAIL

# --- C4: exactly ONE turn below the threshold the nudge stays silent -------
# The count is 3 on entry, so this Stop makes it 4. C4pre pins that, because a
# negative case that sits two or more turns below the bound would still pass
# while proving nothing about the boundary.
ERR="$(stop_err "$C2_RAW" "$CFG5")"
[ "$(counter_of "$C2")" = "4" ] \
  && check "C4pre the negative case really sits one turn below the threshold" PASS \
  || check "C4pre the negative case really sits one turn below the threshold (got $(counter_of "$C2"))" FAIL
# Fixed-string, matching the three sibling absence checks. The earlier form used a
# GNU-only `\|` alternation whose "parked" half can never match this notice, so on
# a host that does not honour that extension it degraded to a literal matching
# nothing and the boundary negative passed without testing anything.
if printf '%s' "$ERR" | grep -qF "still at 'implementing'"; then
  check "C4 one turn below the threshold no nudge is written" FAIL
else
  check "C4 one turn below the threshold no nudge is written" PASS
fi

# --- C5: at EXACTLY the threshold it nudges, and still releases ------------
# The boundary is the point: with `-gt` in place of `-ge` this pair goes red.
# ONE Stop with BOTH channels captured. An earlier revision graded the decision on
# a LATER Stop than the one it had pinned the count on, so `-ge` → `-eq` left every
# check green while the graded invocation emitted nothing on either channel.
C5_OUT="$STATE_DIR/c5.out"; C5_ERR="$STATE_DIR/c5.err"
printf '%s' "$(payload "$C2_RAW")" | ZENSU_CONFIG="$CFG5" bash "$STOP" >"$C5_OUT" 2>"$C5_ERR"
[ "$(counter_of "$C2")" = "5" ] \
  && check "C5pre the boundary case sits at exactly the threshold" PASS \
  || check "C5pre the boundary case sits at exactly the threshold (got $(counter_of "$C2"))" FAIL
grep -qF "still at 'implementing'" "$C5_ERR" \
  && check "C5a at exactly the threshold the nudge is written to stderr" PASS \
  || check "C5a at exactly the threshold the nudge is written to stderr" FAIL
[ "$(decision < "$C5_OUT")" = "allow" ] \
  && check "C5b the same Stop that nudged still released" PASS \
  || check "C5b the same Stop that nudged still released" FAIL
# decision() maps EMPTY stdout to allow, so C5b alone cannot tell a released Stop
# from one that wrote the notice onto the decision channel. stdout must be empty —
# graded on the SAME invocation whose stderr C5a just matched.
[ ! -s "$C5_OUT" ] \
  && check "C5c the notice never reaches stdout, which is the decision channel" PASS \
  || check "C5c the notice never reaches stdout, which is the decision channel" FAIL
ERR="$(cat "$C5_ERR")"

# --- C6: names the review path, and NOT the zero-change terminus -----------
# From shape `implementing` no ticket has ever been consumed, so --chain-done is
# the unqualified no-ticket terminus and a mid-run commit would let it close a
# chain nothing reviewed. The notice must not teach it.
if printf '%s' "$ERR" | grep -qF -- "--tdd-complete" \
  && printf '%s' "$ERR" | grep -qF "edit-landing audit" \
  && ! printf '%s' "$ERR" | grep -qF -- "--chain-done"; then
  check "C6 the notice names --tdd-complete with its precondition and never the zero-change terminus" PASS
else
  check "C6 the notice names --tdd-complete with its precondition and never the zero-change terminus" FAIL
fi

# --- C7: the branch is unreachable once implementation is complete ---------
BEFORE="$(counter_of "$C2")"
# The worktree stays DIRTY on purpose, so this pins that implComplete ALONE
# stops the branch being reached — C1 already covers the clean-worktree half.
# Keeping it dirty means --tdd-complete's own receipt and requirements-table
# preconditions are in scope, so both are switched off for this one command
# through their documented env opt-outs; neither is what this check is about.
ZENSU_EDIT_LANDING_GATE=off ZENSU_REQUIREMENTS_GATE=off \
  bash "$LOG" --tdd-complete --session "$C2" >/dev/null 2>&1
TC_RC=$?
# Positive controls. Without them a failed bind, a hook crash, or the
# SESSION_ACTIVE early exit would freeze the counter for a reason that has
# nothing to do with implComplete, and C7 would pass on it.
[ "$TC_RC" -eq 0 ] \
  && check "C7pre --tdd-complete actually succeeded" PASS \
  || check "C7pre --tdd-complete actually succeeded (rc=$TC_RC)" FAIL
IMPL_DONE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || { echo unavailable; exit 0; }
  f="$(tdd_state_file "$2")" || { echo unavailable; exit 0; }
  tdd_impl_complete "$f"
' _ "$PLUGIN_DIR" "$C2" 2>/dev/null)"
[ "$IMPL_DONE" = "true" ] \
  && check "C7pre2 the workflow document really reads implComplete=true" PASS \
  || check "C7pre2 the workflow document really reads implComplete=true (got '$IMPL_DONE')" FAIL
stop_out "$C2_RAW" "$CFG5" >/dev/null
[ "$(counter_of "$C2")" = "$BEFORE" ] \
  && check "C7 a completed implementation freezes the counter" PASS \
  || check "C7 a completed implementation freezes the counter ($BEFORE -> $(counter_of "$C2"))" FAIL

# --- C18: a re-armed chain starts from zero -------------------------------
# Six production sites delete the counter at a generation boundary and NOTHING
# else covered them: C13 reads a chain that never counted, which exercises the
# `missing` branch, not a delete. Without this, a regression in the arm-path
# delete makes chain 2 of a session nudge on its first turn.
# Placed here, while C2 is still the session start_session armed last — the
# counter reader resolves through the ambient plugin data, so a later scenario
# would make this report `unavailable` rather than a count.
C18_BEFORE="$(counter_of "$C2")"
bash "$LOG" --tdd-begin --session "$C2" >/dev/null 2>&1
C18_AFTER="$(counter_of "$C2")"
if [ "$C18_BEFORE" -gt 0 ] 2>/dev/null; then
  check "C18pre the chain really carried a count before the re-arm ($C18_BEFORE)" PASS
else
  check "C18pre the chain really carried a count before the re-arm (got '$C18_BEFORE')" FAIL
fi
[ "$C18_AFTER" = "0" ] \
  && check "C18 re-arming a chain clears the counter" PASS \
  || check "C18 re-arming a chain clears the counter ($C18_BEFORE -> $C18_AFTER)" FAIL

# --- C8: threshold 0 disables the count and the nudge ----------------------
CFG0="$(cfg_with 0)"
C8_RAW="impl-disabled"
start_session "$C8_RAW"
C8="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C8" >/dev/null 2>&1
C8_ARM_RC=$?
# C8 is the only check that proves the threshold is read from a CONFIG FILE at all
# (every CFG5 case is indistinguishable from the built-in default), and both its
# assertions are also satisfied by a chain that never armed — an inactive session
# releases before the nudge is ever called. Same control pair C15 carries.
[ "$C8_ARM_RC" -eq 0 ] \
  && check "C8pre the disabled-threshold chain actually armed" PASS \
  || check "C8pre the disabled-threshold chain actually armed (rc=$C8_ARM_RC)" FAIL
C8_ACTIVE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || { echo unavailable; exit 0; }
  f="$(tdd_state_file "$2")" || { echo unavailable; exit 0; }
  tdd_session_active "$f"
' _ "$PLUGIN_DIR" "$C8" 2>/dev/null)"
[ "$C8_ACTIVE" = "true" ] \
  && check "C8pre2 that chain really is active, so the branch is reachable" PASS \
  || check "C8pre2 that chain really is active, so the branch is reachable (got '$C8_ACTIVE')" FAIL
dirty
ERR="$(stop_err "$C8_RAW" "$CFG0")"
[ "$(counter_of "$C8")" = "0" ] \
  && check "C8a threshold 0 does not advance the counter" PASS \
  || check "C8a threshold 0 does not advance the counter (got $(counter_of "$C8"))" FAIL
if printf '%s' "$ERR" | grep -qF "still at 'implementing'"; then
  check "C8b threshold 0 writes no nudge" FAIL
else
  check "C8b threshold 0 writes no nudge" PASS
fi

# --- C9: no wall clock on the increment path -------------------------------
# The rejected alternative was an age bound. A behavioural test cannot prove a
# negative about elapsed time in reasonable wall clock, so the property is
# pinned at source: the function body must consult no clock at all.
CLOCK_RE='\bdate\b|updated_at|EPOCHSECONDS|SECONDS|mtime'
# Full-line comments are stripped deliberately: rationale prose is allowed to use
# ordinary English words the alternation matches, and comparing comment TEXT would
# turn this red for a reason unrelated to the property being pinned.
BODY="$(awk '/^zensu_impl_stop_nudge\(\) \{/,/^\}/' "$STOP" | grep -v '^[[:space:]]*#')"
if [ -z "$BODY" ]; then
  check "C9 zensu_impl_stop_nudge body could not be extracted" FAIL
elif ! printf 'x=$(date +%%s)\n' | grep -qE "$CLOCK_RE"; then
  # Positive control: a negative scan whose own pattern cannot match anything is
  # green for free, which is the exact vacuity this repo's source pins guard.
  check "C9ctl the clock alternation can match a real clock read" FAIL
elif printf '%s' "$BODY" | grep -qE "$CLOCK_RE"; then
  check "C9 the increment path reads no wall clock" FAIL
else
  check "C9ctl the clock alternation can match a real clock read" PASS
  check "C9 the increment path reads no wall clock" PASS
fi

# --- C10..C12: the doctor row ----------------------------------------------
doctor_report() {  # $1 = session key, $2 = threshold
  ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=6 \
  ZDOC_BINDING=bound ZDOC_SESSION_KEY="$1" ZDOC_IMPL_STOP_NUDGE_AFTER="$2" \
  ZDOC_SESSION_PROJECT_ROOT="$PROJ" \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="" CLAUDE_PROJECT_DIR="$PROJ" \
    node "$REPORT" 2>/dev/null
}
# Same fixture, but it does NOT set the threshold itself, so whatever the caller
# exported (including an empty string) reaches the reader. This is the only way to
# drive the fallback branch, which doctor_report can never reach.
doctor_report_unset() {  # $1 = session key
  ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github ZDOC_FORGE_CLI=gh \
  ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent ZDOC_TTL_HOURS=6 \
  ZDOC_BINDING=bound ZDOC_SESSION_KEY="$1" \
  ZDOC_SESSION_PROJECT_ROOT="$PROJ" \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="" CLAUDE_PROJECT_DIR="$PROJ" \
    node "$REPORT" 2>/dev/null
}
C10_RAW="impl-doctor"
start_session "$C10_RAW"
C10="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C10" >/dev/null 2>&1
dirty
for _ in 1 2 3; do stop_out "$C10_RAW" "$CFG5" >/dev/null; done
REP="$(doctor_report "$C10" 3)"
printf '%s' "$REP" | grep -qF 'parked at `implementing`' \
  && check "C10 doctor renders the parked row at the threshold" PASS \
  || check "C10 doctor renders the parked row at the threshold" FAIL
# A "no 'all checks green'" assertion would be a TAUTOLOGY here: the fixture pins
# ZDOC_ZENSU=absent, ZDOC_FORGE_STATE=missing and ZDOC_PLAYWRIGHT=absent, each of
# which already emits a warning, so that string can never print and demoting the
# parked row to OK would leave the check green. Measure the row's OWN contribution
# to the warning count instead — the shape P1mg1 uses for the foreign-open row.
WARN_WITH="$(doctor_report "$C10" 3  | grep -c '⚠️')"
WARN_WITHOUT="$(doctor_report "$C10" 99 | grep -c '⚠️')"
[ "$((WARN_WITH - WARN_WITHOUT))" -eq 1 ] \
  && check "C10b the parked row adds exactly one warning, so it withholds the green summary" PASS \
  || check "C10b the parked row adds exactly one warning (with=$WARN_WITH without=$WARN_WITHOUT)" FAIL
REP="$(doctor_report "$C10" 99)"
printf '%s' "$REP" | grep -qF 'parked at `implementing`' \
  && check "C11 below the threshold the doctor stays quiet" FAIL \
  || check "C11 below the threshold the doctor stays quiet" PASS
REP="$(doctor_report "$C10" 0)"
printf '%s' "$REP" | grep -qF 'parked at `implementing`' \
  && check "C12 threshold 0 disables the doctor row" FAIL \
  || check "C12 threshold 0 disables the doctor row" PASS
# Disabling must not read as "nothing to report": the reader has to be able to
# tell a clean result from a check that never ran.
printf '%s' "$REP" | grep -qF 'the parked-at-`implementing` check is switched off' \
  && check "C12a a disabled check says so instead of falling silent" PASS \
  || check "C12a a disabled check says so instead of falling silent" FAIL
# An unset value must fall back to the documented default, not to 0. Number('')
# is 0, which passes the >= 0 bound, so a blank export would silently delete the
# row; the reader treats blank as absent for exactly that reason.
REP="$(ZDOC_IMPL_STOP_NUDGE_AFTER='' doctor_report_unset "$C10")"
printf '%s' "$REP" | grep -qF 'the parked-at-`implementing` check is switched off' \
  && check "C12b a blank threshold falls back to the default rather than disabling" FAIL \
  || check "C12b a blank threshold falls back to the default rather than disabling" PASS

# --- C16: a session that already counted stops counting once the tree is clean
# Deliberately placed here, while C10's session is still the one start_session
# armed last: the ambient CLAUDE_PLUGIN_DATA resolves to it, and a later
# start_session would silently redirect these Stops at a different store.
C16_BEFORE="$(counter_of "$C10")"
clean_wt
stop_out "$C10_RAW" "$CFG5" >/dev/null
[ "$(counter_of "$C10")" = "$C16_BEFORE" ] \
  && check "C16 a counted session stops counting once the worktree is clean again" PASS \
  || check "C16 a counted session stops counting once the worktree is clean ($C16_BEFORE -> $(counter_of "$C10"))" FAIL

# --- C20: the row names only chains this session owns ---------------------
# Nothing pinned the ownership half: with only ONE qualifying chain in the state
# directory, deleting `entry.key === ownKey` left every doctor check green while
# the row would start naming other sessions' work — contradicting its own text.
C20_RAW="impl-foreign-owner"
start_session "$C20_RAW"
C20="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C20" >/dev/null 2>&1
dirty
for _ in 1 2 3 4; do stop_out "$C20_RAW" "$CFG5" >/dev/null; done
C20_COUNT="$(counter_of "$C20")"
[ "$C20_COUNT" -ge 3 ] 2>/dev/null \
  && check "C20pre the second chain really is above the reporting threshold ($C20_COUNT)" PASS \
  || check "C20pre the second chain really is above the reporting threshold (got '$C20_COUNT')" FAIL
REP="$(doctor_report "$C10" 3)"
C20_TAG="$(printf '%s' "$C20" | cut -c1-13)"
C10_TAG="$(printf '%s' "$C10" | cut -c1-13)"
# Scoped to the PARKED row alone. The count row above it legitimately lists every
# chain in the project, so grepping the whole report would fail for the wrong reason.
PARKED_LINE="$(printf '%s\n' "$REP" | grep -F 'parked at `implementing`' || true)"
if [ -z "$PARKED_LINE" ]; then
  check "C20 the parked row is present so ownership can be graded" FAIL
elif printf '%s' "$PARKED_LINE" | grep -qF "$C20_TAG"; then
  check "C20 a chain owned by another session is never named in this session's row" FAIL
elif printf '%s' "$PARKED_LINE" | grep -qF "$C10_TAG"; then
  check "C20 a chain owned by another session is never named in this session's row" PASS
else
  check "C20 the parked row names neither chain, so it grades nothing" FAIL
fi
# The row appends the owning module's next command, so the "never teach the
# zero-change terminus" claim has to be graded on the RENDERED line too — C6 only
# covers the hand-authored Stop notice.
if [ -n "$PARKED_LINE" ] && printf '%s' "$PARKED_LINE" | grep -qF -- '--chain-done'; then
  check "C20a the rendered row never names the zero-change terminus" FAIL
else
  check "C20a the rendered row never names the zero-change terminus" PASS
fi

# --- C22: a Stop the enforcer itself blocks is not counted -----------------
# SOURCE pin, and the reason is stated rather than glossed: driving the
# behavioural half needs a durable Autopilot run fixture, which this suite does
# not build, so the BEHAVIOUR is uncovered and only the wiring is pinned here.
# Deleting either half would make the nudge count a turn that never ended and
# assert "Stop is not blocked" beside a decision:"block" on stdout.
# Anchored on the WHOLE guard statement and on emit_block's own extracted body: a
# grep for the bare variable name passes with `&& return 0` deleted, with the
# comparison inverted, or with the assignment moved out of emit_block entirely.
EMIT_BODY="$(awk '/^emit_block\(\) \{/,/^\}/' "$STOP")"
if [ -z "$EMIT_BODY" ]; then
  check "C22 emit_block body could not be extracted" FAIL
elif printf '%s' "$EMIT_BODY" | grep -qE '^[[:space:]]*DECISION_EMITTED=true$' \
  && grep -qE '^DECISION_EMITTED=false$' "$STOP" \
  && printf '%s' "$BODY" | grep -qE '^[[:space:]]*\[ "\$\{DECISION_EMITTED:-false\}" = "true" \] && return 0$'; then
  check "C22 emit_block records the decision and the nudge returns on it" PASS
else
  check "C22 emit_block records the decision and the nudge returns on it" FAIL
fi
# The guard is only reachable because the nudge is CALLED after outer_finish; pin
# that order, or a reordering would make the guard dead with C22 still green.
if grep -qE 'reviewer_denial_note_clear; outer_finish; zensu_impl_stop_nudge; exit 0' "$STOP"; then
  check "C22a the nudge runs after the decision-bearing calls, which is what makes the guard reachable" PASS
else
  check "C22a the nudge runs after the decision-bearing calls, which is what makes the guard reachable" FAIL
fi

# --- C21: the wrapper half really resolves and exports the threshold -------
# Both doctor fixtures preset ZDOC_* and call the renderer directly, so the only
# production producer of ZDOC_IMPL_STOP_NUDGE_AFTER is exercised by nothing.
# Dropping the export would silently return every real run to the built-in
# fallback with the whole suite green — the same shape as the ZDOC_SESSION_KEY pin.
DOCTOR_SH="$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"
# The `-z` guard is part of the pin: flipping it to `-n` leaves all the other
# needles matching while the getter is never called for an unset variable.
if grep -qF 'zensu_impl_stop_nudge_after' "$DOCTOR_SH" \
  && grep -qF 'if [ -z "${ZDOC_IMPL_STOP_NUDGE_AFTER:-}" ]' "$DOCTOR_SH" \
  && grep -qF 'ZDOC_IMPL_STOP_NUDGE_AFTER="$(zensu_impl_stop_nudge_after' "$DOCTOR_SH" \
  && grep -qE '^export ZDOC_IMPL_STOP_NUDGE_AFTER$' "$DOCTOR_SH"; then
  check "C21 the wrapper resolves the threshold through the canonical getter and exports it" PASS
else
  check "C21 the wrapper resolves the threshold through the canonical getter and exports it" FAIL
fi

# --- C13/C14: the accessors themselves -------------------------------------
C13_RAW="impl-accessor"
start_session "$C13_RAW"
C13="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C13" >/dev/null 2>&1
[ "$(counter_of "$C13")" = "0" ] \
  && check "C13 tdd_get_counter accepts implStopCount and answers 0 when absent" PASS \
  || check "C13 tdd_get_counter accepts implStopCount and answers 0 when absent (got $(counter_of "$C13"))" FAIL
DEF="$(bash -c 'set -u; ZENSU_CONFIG="$2" ; source "$1/hooks/lib/zensu-config.sh"; zensu_impl_stop_nudge_after' _ "$PLUGIN_DIR" "$STATE_DIR/no-such-config.json" 2>/dev/null)"
[ "$DEF" = "12" ] \
  && check "C14 the configured default is 12" PASS \
  || check "C14 the configured default is 12 (got $DEF)" FAIL
# The renderer keeps a hand-copy of that default for direct (no-wrapper) runs and
# says so in its own comment. Nothing compared the two, so a drift would make every
# such doctor invocation judge a different threshold than the Stop hook.
JS_DEF="$(grep -oE 'IMPL_STOP_NUDGE_FALLBACK = [0-9]+' "$REPORT" | grep -oE '[0-9]+' | head -1)"
[ "$JS_DEF" = "$DEF" ] \
  && check "C14a the renderer fallback matches the shell getter's default" PASS \
  || check "C14a the renderer fallback matches the shell getter's default (js=$JS_DEF sh=$DEF)" FAIL

# --- C19: the .zensu pathspec exclusion has a bite ------------------------
# The main fixture gitignores .zensu, which MASKS the exclusion: deleting it from
# production would leave every other check green. This second fixture does not
# ignore it, so a write under .zensu/ is an ordinary untracked change and only
# the pathspec keeps it from counting.
PROJ3="$(mktemp -d)"
PROJ3="$(cd "$PROJ3" && pwd -P)"
git -C "$PROJ3" init -q
git -C "$PROJ3" config user.email "suite@example.invalid"
git -C "$PROJ3" config user.name "suite"
printf 'base\n' > "$PROJ3/tracked.txt"
git -C "$PROJ3" add tracked.txt >/dev/null 2>&1
git -C "$PROJ3" commit -qm base >/dev/null 2>&1
C19_RAW="impl-zensu-pathspec"
start_session "$C19_RAW" "$C19_RAW" "$PROJ3"
C19="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C19" >/dev/null 2>&1
mkdir -p "$PROJ3/.zensu/plans"
printf 'plan\n' > "$PROJ3/.zensu/plans/x.md"
stop_out "$C19_RAW" "$CFG5" >/dev/null
[ "$(counter_of "$C19")" = "0" ] \
  && check "C19 a change confined to .zensu never advances the counter" PASS \
  || check "C19 a change confined to .zensu never advances the counter (got $(counter_of "$C19"))" FAIL
# Positive control in the SAME fixture: without it C19 passes on any failure that
# stops the probe from running at all.
printf 'changed\n' > "$PROJ3/tracked.txt"
stop_out "$C19_RAW" "$CFG5" >/dev/null
[ "$(counter_of "$C19")" = "1" ] \
  && check "C19a a change outside .zensu in the same fixture does advance it" PASS \
  || check "C19a a change outside .zensu in the same fixture does advance it (got $(counter_of "$C19"))" FAIL
rm -rf "$PROJ3"

# --- C15: a project root that is not a git work tree ----------------------
# The feature is INERT there rather than firing blind, and that inertness is a
# recorded decision, not an accident: without a repository the probe cannot tell
# a clean tree from an unanswerable one, so it declines to count at all.
PROJ2="$(mktemp -d)"
PROJ2="$(cd "$PROJ2" && pwd -P)"
C15_RAW="impl-nogit"
start_session "$C15_RAW" "$C15_RAW" "$PROJ2"
C15="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C15" >/dev/null 2>&1
C15_ARM_RC=$?
# Positive controls. counter_of answers "0" for the MISSING status too, so a
# failed bind, a failed arm or a Stop that exits early all produce exactly the
# observation this check treats as success.
[ "$C15_ARM_RC" -eq 0 ] \
  && check "C15pre the non-git chain actually armed" PASS \
  || check "C15pre the non-git chain actually armed (rc=$C15_ARM_RC)" FAIL
C15_ACTIVE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || { echo unavailable; exit 0; }
  f="$(tdd_state_file "$2")" || { echo unavailable; exit 0; }
  tdd_session_active "$f"
' _ "$PLUGIN_DIR" "$C15" 2>/dev/null)"
[ "$C15_ACTIVE" = "true" ] \
  && check "C15pre2 the non-git session really has an active chain" PASS \
  || check "C15pre2 the non-git session really has an active chain (got '$C15_ACTIVE')" FAIL
printf 'content\n' > "$PROJ2/untracked.txt"
ERR="$(stop_err "$C15_RAW" "$CFG5")"
[ "$(counter_of "$C15")" = "0" ] \
  && check "C15 a non-git project root never advances the counter" PASS \
  || check "C15 a non-git project root never advances the counter (got $(counter_of "$C15"))" FAIL
if printf '%s' "$ERR" | grep -qF "still at 'implementing'"; then
  check "C15a a non-git project root writes no notice" FAIL
else
  check "C15a a non-git project root writes no notice" PASS
fi
rm -rf "$PROJ2"

# --- C17: the schema membership has a bite --------------------------------
# `validateWorkflowState` has no closed top-level key set, so the ONLY effect of
# listing implStopCount in WORKFLOW_INTEGER_EXTENSIONS is the bound in
# validateWorkflowExtensions. Plant a value past that bound: with the membership
# the document fails validation and the reader answers `invalid`; without it the
# value is unchecked and the reader hands back the digits.
C17_RAW="impl-validator"
start_session "$C17_RAW"
C17="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C17" >/dev/null 2>&1
C17_FILE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || exit 0
  tdd_state_file "$2"
' _ "$PLUGIN_DIR" "$C17" 2>/dev/null)"
if [ -n "$C17_FILE" ] && [ -f "$C17_FILE" ]; then
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.implStopCount = 1000001;
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$C17_FILE"
  C17_READ="$(counter_of "$C17")"
  [ "$C17_READ" = "invalid" ] \
    && check "C17 an out-of-bounds implStopCount is rejected by the schema extension list" PASS \
    || check "C17 an out-of-bounds implStopCount is rejected by the schema extension list (got '$C17_READ')" FAIL
else
  check "C17 the planted workflow document could not be located" FAIL
fi

echo ""
echo "impl-stop-counter: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
