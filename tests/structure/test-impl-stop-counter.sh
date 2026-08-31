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
BOUNDED_LIB="$PLUGIN_DIR/hooks/lib/zensu-bounded-run.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

# ONE extraction of a shell function body from the hook, and it is defined up here
# because its three former call sites are hundreds of lines apart. They had drifted
# into three different awk spellings — one with the brace in the start pattern and one
# without, one with an anchored `/^\}$/` end and one with an unanchored `/^\}/` — which
# fail DIFFERENTLY: an unmatched anchored end runs the range to end of file rather than
# emptying it, so a check reading the over-extracted body can match live code from a
# LATER function and pass while the thing it names has been deleted. That is not a
# hypothesis; the sibling suite carries the same lesson about a stale awk anchor in
# test-doctor.sh, and C44 below is exactly a check whose needle also occurs outside
# this function. `$2` non-empty strips full-line comments.
hook_fn_body() {  # $1 = function name, $2 = "code" to strip comments, $3 = file (default $STOP)
  local body file="${3:-$STOP}"
  body="$(awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn,/^\}$/' "$file")"
  # An awk RANGE whose end pattern never matches silently runs to EOF. Refuse to
  # return such a body at all, so every consumer fails loudly instead of grading the
  # rest of the file. STATE WHAT THIS PROVES: that the range ended at SOME column-0
  # brace, not that it ended at the named function's own. This hook embeds `node -e`
  # programs inside these functions, and a reformatting that unindented one of their
  # closing braces would truncate the body while this guard still reported success —
  # and a truncated body is what makes a negative check pass for free. The consumer
  # labels say "ended at a column-0 brace" for that reason and no stronger.
  [ -n "$body" ] && [ "$(printf '%s\n' "$body" | tail -1)" = "}" ] || return 1
  if [ -n "${2:-}" ]; then printf '%s\n' "$body" | grep -v '^[[:space:]]*#'; else printf '%s\n' "$body"; fi
}

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
C1_ARM_RC=$?
# C1 was the only scenario here with no precondition control, and it is the one that
# most needs one: it is the first scenario, the first use of start_session in the run,
# and the only holder of the clean-worktree negative. BOTH its assertions are satisfied
# by a chain that never armed — an inactive session returns at the SESSION_ACTIVE branch
# one line ABOVE the wired one, so the nudge is never called, counter_of answers 0 and
# C1b passes; and decision() maps empty stdout to "allow", so C1a passes too. Same
# control pair C8 and C15 carry, for the same reason.
[ "$C1_ARM_RC" -eq 0 ] \
  && check "C1pre the clean-worktree chain actually armed" PASS \
  || check "C1pre the clean-worktree chain actually armed (rc=$C1_ARM_RC)" FAIL
C1_ACTIVE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || { echo unavailable; exit 0; }
  f="$(tdd_state_file "$2")" || { echo unavailable; exit 0; }
  tdd_session_active "$f"
' _ "$PLUGIN_DIR" "$C1" 2>/dev/null)"
[ "$C1_ACTIVE" = "true" ] \
  && check "C1pre2 that chain really is active, so the branch is reachable" PASS \
  || check "C1pre2 that chain really is active, so the branch is reachable (got '$C1_ACTIVE')" FAIL
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

# --- C23: the notice states what the probe MEASURES ------------------------
# `git status --porcelain -- . ':(exclude).zensu'` reports untracked entries as
# well as tracked modifications, so a stray build artifact or editor file
# satisfies the condition with no source change at all. `docs/configuration.md`
# and discipline patch 13 already word it correctly; only the model-facing
# string overstated. The presence half is this check's own positive control: an
# empty or unwritten $ERR fails it rather than passing the absence half for free.
if ! printf '%s' "$ERR" | grep -qF "changed source files" \
  && printf '%s' "$ERR" | grep -qF "a changed file outside"; then
  check "C23 the notice states the measured claim, not 'changed source files'" PASS
else
  check "C23 the notice states the measured claim, not 'changed source files'" FAIL
fi

# --- C24: the notice promises no silence the code does not keep ------------
# `[ "$count" -ge "$threshold" ]` holds on every later Stop, so the notice is
# written at every turn end until implComplete flips. A closing "it is silent
# again once the chain moves on" is therefore broken on the very next turn, and
# a notice that misdescribes its own behaviour is the fastest way to teach a
# reader to ignore it. Latching it is deliberately out of scope for this change,
# so the promise must not be made. Self-controlled: the first grep proves the
# notice was written at all.
if printf '%s' "$ERR" | grep -qF "still at 'implementing'" \
  && ! printf '%s' "$ERR" | grep -qF "silent again"; then
  check "C24 the notice makes no promise of silence the code does not keep" PASS
else
  check "C24 the notice makes no promise of silence the code does not keep" FAIL
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
BODY="$(hook_fn_body zensu_impl_stop_nudge code)"
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
printf '%s' "$REP" | grep -qF 'turns at `implementing`' \
  && check "C10 doctor renders the implementing-turns row at the threshold" PASS \
  || check "C10 doctor renders the implementing-turns row at the threshold" FAIL
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
# The count here is 3 and every render above uses a threshold EQUAL to it or above
# it, so `parkedCount >= implThreshold` mutated to `===` survived C10, C10b, C11, C12
# and C20 — the doctor twin of the hole C34 closed on the Stop surface. Repeating
# past the bound rather than firing once at it is a documented property of this row,
# so it needs a case that only `>=` satisfies. C38pre further down runs the identical
# render and is strictly stronger, so this is not the sole holder of that boundary —
# said here because a reader deleting either check would otherwise not know.
REP="$(doctor_report "$C10" 1)"
printf '%s' "$REP" | grep -qF 'turns at `implementing`' \
  && check "C47 above the threshold the doctor row still renders, so >= is not ==" PASS \
  || check "C47 above the threshold the doctor row still renders, so >= is not ==" FAIL
REP="$(doctor_report "$C10" 99)"
printf '%s' "$REP" | grep -qF 'turns at `implementing`' \
  && check "C11 below the threshold the doctor stays quiet" FAIL \
  || check "C11 below the threshold the doctor stays quiet" PASS
REP="$(doctor_report "$C10" 0)"
printf '%s' "$REP" | grep -qF 'turns at `implementing`' \
  && check "C12 threshold 0 disables the doctor row" FAIL \
  || check "C12 threshold 0 disables the doctor row" PASS
# Disabling must not read as "nothing to report": the reader has to be able to
# tell a clean result from a check that never ran.
printf '%s' "$REP" | grep -qF 'the implementing-turns check is switched off' \
  && check "C12a a disabled check says so instead of falling silent" PASS \
  || check "C12a a disabled check says so instead of falling silent" FAIL
# An unset value must fall back to the documented default, not to 0. Number('')
# is 0, which passes the >= 0 bound, so a blank export would silently delete the
# row; the reader treats blank as absent for exactly that reason.
REP="$(ZDOC_IMPL_STOP_NUDGE_AFTER='' doctor_report_unset "$C10")"
# POSITIVE CONTROL, and it is not decoration. `doctor_report_unset` is used by no
# other check, so an empty `$REP` — a renderer crash, a renamed required `ZDOC_`
# variable, a node fault — satisfied the absence assertion below while observing
# nothing at all. Its sibling C12 is controlled by C12a on the same report; this
# one had no partner. The count row renders on every report that runs.
printf '%s' "$REP" | grep -qE 'chain: [0-9]+ review chain' \
  && check "C12bpre the fallback report really rendered, so the absence below means something" PASS \
  || check "C12bpre the fallback report really rendered, so the absence below means something" FAIL
printf '%s' "$REP" | grep -qF 'the implementing-turns check is switched off' \
  && check "C12b a blank threshold falls back to the default rather than disabling" FAIL \
  || check "C12b a blank threshold falls back to the default rather than disabling" PASS

# --- C16: a session that already counted stops counting once the tree is clean
# Deliberately placed here, while C10's session is still the one start_session
# armed last: the ambient CLAUDE_PLUGIN_DATA resolves to it, and a later
# start_session would silently redirect these Stops at a different store.
C16_BEFORE="$(counter_of "$C10")"
# The precondition this check never had, and it is not decoration. Both sides of the
# comparison below read through `counter_of`, which answers the literal string
# `unavailable` once a later `start_session` has redirected the ambient session — and
# `unavailable = unavailable` passes while observing nothing at all. That is not
# hypothetical: a fallback-value scenario added above this line put its own
# `start_session` between C10's arming and these reads, and every check in the file
# stayed green while the one case covering "a counted session stops counting" had
# stopped measuring. Requiring a POSITIVE count makes the placement rule the banner
# comment states enforceable instead of merely stated.
[ "$C16_BEFORE" -gt 0 ] 2>/dev/null \
  && check "C16pre C10's chain is still the ambient session and had really counted, so C16 measures something" PASS \
  || check "C16pre C10's chain is still the ambient session and had really counted (got '$C16_BEFORE')" FAIL
clean_wt
stop_out "$C10_RAW" "$CFG5" >/dev/null
[ "$(counter_of "$C10")" = "$C16_BEFORE" ] \
  && check "C16 a counted session stops counting once the worktree is clean again" PASS \
  || check "C16 a counted session stops counting once the worktree is clean ($C16_BEFORE -> $(counter_of "$C10"))" FAIL

# C12b alone proves only "not disabled" — a fallback of 1, or of 99, satisfies it
# while the check's own name claims the DEFAULT. Grading the VALUE needs a chain whose
# count sits exactly ON the default, and that is the whole reason this scenario runs
# its own Stops instead of reusing C10's chain: at C10's count of 3 the thresholds 12
# and 13 are indistinguishable, so a first attempt at this check compared two reports
# that were identical for a reason unrelated to the fallback and passed against a
# renderer whose fallback had been mutated to 13. A comparison that cannot separate
# the value it names is worse than none.
#
# The default is READ from the shell getter rather than written as a literal, so this
# cannot drift away from the config side either — and it is read here rather than
# borrowed from C14's `$DEF`, which is assigned further down and would be an unbound
# variable under `set -u`.
C48_DEF="$(bash -c 'set -u; ZENSU_CONFIG="$2" ; source "$1/hooks/lib/zensu-config.sh"; zensu_impl_stop_nudge_after' _ "$PLUGIN_DIR" "$STATE_DIR/no-such-config.json" 2>/dev/null)"
C48_RAW="impl-fallback"
start_session "$C48_RAW"
C48="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C48" >/dev/null 2>&1
C48_ARM_RC=$?
dirty
C48_N=0
while [ -n "$C48_DEF" ] && [ "$C48_N" -lt "$C48_DEF" ]; do
  stop_out "$C48_RAW" "$CFG5" >/dev/null
  C48_N=$((C48_N + 1))
done
C48_COUNT="$(counter_of "$C48")"
[ "$C48_ARM_RC" -eq 0 ] && [ -n "$C48_DEF" ] && [ "$C48_COUNT" = "$C48_DEF" ] \
  && check "C48pre the chain armed and its count sits exactly on the getter's default, so the thresholds below differ" PASS \
  || check "C48pre the chain armed and its count sits exactly on the getter's default (rc=$C48_ARM_RC def='$C48_DEF' count='$C48_COUNT')" FAIL
# The BITE: at a count of exactly the default, one more than the default must render
# differently. Without this the comparison below is satisfied by any two thresholds
# the count happens to sit under.
C48_AT="$(doctor_report "$C48" "$C48_DEF")"
C48_OVER="$(doctor_report "$C48" "$((C48_DEF + 1))")"
[ -n "$C48_AT" ] && [ "$C48_AT" != "$C48_OVER" ] \
  && check "C48pre2 the default and one above it really render differently at this count" PASS \
  || check "C48pre2 the default and one above it really render differently at this count" FAIL
C48_BLANK="$(ZDOC_IMPL_STOP_NUDGE_AFTER='' doctor_report_unset "$C48")"
[ -n "$C48_BLANK" ] && [ "$C48_BLANK" = "$C48_AT" ] \
  && check "C48 a blank threshold renders exactly as the documented default does, not merely as something enabled" PASS \
  || check "C48 a blank threshold renders exactly as the documented default does, not merely as something enabled" FAIL

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
PARKED_LINE="$(printf '%s\n' "$REP" | grep -F 'turns at `implementing`' || true)"
if [ -z "$PARKED_LINE" ]; then
  check "C20 the implementing-turns row is present so ownership can be graded" FAIL
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
# grep for the bare variable name passes with the early return deleted, with the
# comparison inverted, or with the assignment moved out of emit_block entirely.
# The needle tracks the guard's SPELLING, so it moved when the guard was rewritten
# from `[ … ] && return 0` to the `if` form this file's own rule requires — that is
# the cost of anchoring on a whole statement, and it is the point: a looser needle
# would not have noticed the rewrite either way.
EMIT_BODY="$(hook_fn_body emit_block code)"
if [ -z "$EMIT_BODY" ]; then
  check "C22 emit_block body could not be extracted" FAIL
elif printf '%s' "$EMIT_BODY" | grep -qE '^[[:space:]]*DECISION_EMITTED=true$' \
  && grep -qE '^DECISION_EMITTED=false$' "$STOP" \
  && printf '%s' "$BODY" | grep -qE '^[[:space:]]*if \[ "\$\{DECISION_EMITTED:-false\}" = "true" \]; then return 0; fi$'; then
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

# --- C25: the doctor row states the measured claim and the ACTUAL count ----
# The counter advances ONLY on a turn that ended with a changed worktree, so a
# chain reaching the bound is the busiest kind, not a parked one. A reader on
# turn 13 of genuine work can falsify an opening claim of "parked", and a row
# whose first clause the reader disproves is a row that gets dismissed for good.
# The threshold here (2) is deliberately BELOW C10's count (3) so the rendered
# number discriminates the count from the bound — at threshold 3 the two coincide
# and the check would pass either way.
C25_REP="$(doctor_report "$C10" 2)"
C25_LINE="$(printf '%s\n' "$C25_REP" | grep -F 'turns at `implementing`' || true)"
if [ -z "$C25_LINE" ]; then
  check "C25 the implementing-turns row is present so its wording can be graded" FAIL
else
  # Bound to the SENTENCE, not to the line. The row appends `parkedImpl`,
  # whose value already reads "<key>: 3 turns → <command>" — so a bare
  # `3 turns` needle is satisfied by the suffix even if the sentence itself went back
  # to rendering the threshold. `ended 3 turns at` can only come from the sentence.
  printf '%s' "$C25_LINE" | grep -qF 'ended 3 turns at' \
    && ! printf '%s' "$C25_LINE" | grep -qF 'at least 2' \
    && ! printf '%s' "$C25_LINE" | grep -qF 'parked at' \
    && check "C25 the row names the actual count and does not assert the chain is parked" PASS \
    || check "C25 the row names the actual count and does not assert the chain is parked" FAIL
fi

# --- C26: a switched-off check is never blamed on the missing session key ---
# With ZDOC_BINDING=bound and no session key the report already discloses that
# the key did not arrive. At threshold 0 the implementing row is withheld for a
# DIFFERENT reason — the check is switched off — and would be withheld with a
# perfectly good key. Attributing it to the missing key hands the reader the
# wrong cause for a row that is off by configuration.
C26_REP="$(doctor_report "" 0)"
# The needle is the SCOPED sentence, matching C12a. Two unrelated permission rows
# in the same report also emit a bare "switched off"; both are inert in this
# fixture, so an unscoped needle would discriminate only by accident.
if printf '%s' "$C26_REP" | grep -qF 'the session key did not reach this report' \
  && printf '%s' "$C26_REP" | grep -qF 'the implementing-turns check is switched off' \
  && ! printf '%s' "$C26_REP" | grep -qF 'withheld for the same reason'; then
  check "C26 at threshold 0 the withheld row is attributed to the switched-off check, not the missing key" PASS
else
  check "C26 at threshold 0 the withheld row is attributed to the switched-off check, not the missing key" FAIL
fi
# The SYMMETRIC arm. Without it the conditional clause could be deleted outright and
# C26 would still pass — an absence assertion with no matching presence assertion pins
# the clause's removal, not its correctness.
C26B_REP="$(doctor_report "" 3)"
if printf '%s' "$C26B_REP" | grep -qF 'the session key did not reach this report' \
  && printf '%s' "$C26B_REP" | grep -qF 'withheld for the same reason'; then
  check "C26b while the check is armed the missing key DOES claim the implementing-turns row" PASS
else
  check "C26b while the check is armed the missing key DOES claim the implementing-turns row" FAIL
fi

# --- C27: with the reviewer spawn refused, the notice QUALIFIES its remedy ----
# This check pinned the opposite contract for one round, and the reversal is the
# point. Withholding `--tdd-complete` outright looked right — completing while the
# refusal stands moves the chain into a gate the host will not let it pass, and
# every later Stop then BLOCKS until the cap releases — but the probe carries NO
# generation or recency bound. It answers `blocked` for the last reviewer result
# anywhere in a bounded transcript tail, and on THIS path nothing can clear it: the
# path never blocks, so the cap never releases it, and withholding the verb keeps
# the chain where no ticket can be issued and no spawn attempted. One stale refusal
# pinned every later turn into the withhold arm for the rest of the session — a
# state with no exit, adopted to avoid a state that at least ends at the cap.
#
# So the notice NAMES the exit and states the refusal beside it. AC-003 asks for
# "the permission remedy rather than `--tdd-complete` alone", which naming both
# satisfies; the verb's absence was never the requirement.
#
# Driven with the REAL host capture rather than a hand-authored envelope, so this
# check cannot pass against a refusal shape only this repository believes in.
CFG1="$(cfg_with 1)"
C27_RAW="impl-denied"
start_session "$C27_RAW" "denied"
C27="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C27" >/dev/null 2>&1
dirty
C27_TRANSCRIPT="$PLUGIN_DIR/tests/structure/fixtures/reviewer-spawn-denied-transcript.v1.jsonl"
C27_ERR="$STATE_DIR/c27.err"; C27_OUT="$STATE_DIR/c27.out"
printf '{"session_id":"%s","hook_event_name":"Stop","transcript_path":"%s"}' \
  "$C27_RAW" "$C27_TRANSCRIPT" \
  | ZENSU_CONFIG="$CFG1" bash "$STOP" >"$C27_OUT" 2>"$C27_ERR"
# Positive control: without it a failed arm, a failed bind or an early exit would
# leave an empty stderr, and the "names the permission remedy" check below would
# fail for a reason that has nothing to do with the branch it is grading.
C27_COUNT="$(counter_of "$C27")"
[ "$C27_COUNT" = "1" ] \
  && check "C27pre the refused-spawn chain reached the bound on one dirty Stop" PASS \
  || check "C27pre the refused-spawn chain reached the bound on one dirty Stop (got '$C27_COUNT')" FAIL
# The VALUES are graded, not the labels. Asserting `kind:` and `refusals observed:`
# alone left both interpolations unpinned: replacing them with the literals
# `unclassified` and `0` kept every needle present while the notice had stopped
# reporting anything the probe measured. The fixture's own verdict is
# `status=blocked kind=auto-mode-classifier spawns=1 denials=1`.
#
# The remedy must be ACTIONABLE. This is the earliest-firing refusal surface and,
# on this path, the only one: the note the branch now mints is what gives
# /zensu:doctor anything to say. Naming neither the rule nor the file left the
# reader told a permission must be lifted and unable to learn which — so both are
# required here, in the user-scoped spelling only.
#
# Two ABSENCES survive the reversal. The zero-change terminus is still never
# taught, for the reason C6 pins. And the retired withhold wording must not come
# back: it is the sentence that produced the no-exit state.
if grep -qF -- '--tdd-complete' "$C27_ERR" \
  && grep -qF 'kind: auto-mode-classifier' "$C27_ERR" \
  && grep -qF 'refusals observed: 1' "$C27_ERR" \
  && grep -qF 'permissions.allow' "$C27_ERR" \
  && grep -qF '~/.claude/settings.json' "$C27_ERR" \
  && grep -qF 'never edit a settings file yourself' "$C27_ERR" \
  && grep -qF 'Deny is evaluated before ask and allow' "$C27_ERR" \
  && grep -qF 'the review chain has not asked for a reviewer' "$C27_ERR" \
  && grep -qF 'compatible with a spawn that WAS attempted' "$C27_ERR" \
  && ! grep -qF 'Do NOT mark the implementation complete' "$C27_ERR" \
  && ! grep -qF -- '--chain-done' "$C27_ERR"; then
  check "C27 the refused-spawn notice names the exit, the measured refusal and an actionable rule" PASS
else
  check "C27 the refused-spawn notice names the exit, the measured refusal and an actionable rule" FAIL
fi
# The branch must MINT the note, which is the whole reason /zensu:doctor can say
# anything about this refusal: `reviewer_denial_note_clear` runs one statement
# earlier and unlinks any predecessor, so without a mint here the diagnosis died
# with the Stop while the doctor's own chain row went on printing the completion
# verb — two surfaces, one chain, opposite advice.
[ -f "$PROJ/.zensu/state/reviewer-spawn-denied-$C27.json" ] \
  && check "C27n the refused-spawn branch mints a denial note for /zensu:doctor" PASS \
  || check "C27n the refused-spawn branch mints a denial note for /zensu:doctor" FAIL
# END TO END, writer to reader. C27n proves only that a FILE landed, and C35 plants its
# own conforming note — so between them a writer-side payload drift (a kind outside
# DENIAL_MARKERS, a zero detectedAtMs, a bumped schemaVersion) would leave both checks
# green while `classifyDenialNote` buckets the real note `rejected`, the caveat vanishes,
# and the two surfaces disagree again. This is the only check that reads what the writer
# actually wrote. Its control comes first: the row must render at all.
C27D="$(doctor_report "$C27" 1 | grep -F 'turns at `implementing`' || true)"
[ -n "$C27D" ] \
  && check "C27dpre the doctor row renders for the refused-spawn chain, so the assertion below is not vacuous" PASS \
  || check "C27dpre the doctor row renders for the refused-spawn chain, so the assertion below is not vacuous" FAIL
if [ -n "$C27D" ] \
  && printf '%s\n' "$C27D" | grep -qF 'records that the host permission layer' \
  && printf '%s\n' "$C27D" | grep -qF 'no agent may edit a settings file' \
  && printf '%s\n' "$C27D" | grep -qF -- '--tdd-complete'; then
  check "C27d the note the WRITER minted is legible to the doctor and qualifies its row" PASS
else
  check "C27d the note the WRITER minted is legible to the doctor and qualifies its row" FAIL
fi
# The BELOW-two arm is what this single-refusal fixture reaches. Both arms were
# unpinned before: collapsing the ladder into one unconditional string, or
# inverting the predicate, left the whole suite green.
if grep -qF 'completing the implementation is the right next move' "$C27_ERR" \
  && ! grep -qF 'Two refusals already stand' "$C27_ERR"; then
  check "C27r one observed refusal takes the arm that sanctions the exit" PASS
else
  check "C27r one observed refusal takes the arm that sanctions the exit" FAIL
fi
# The branch must stay advisory on BOTH remedies. A diagnostic that starts
# blocking is the one outcome this whole feature forbids itself.
# The `[ ! -s ]` companion is not decoration: `decision()` maps an EMPTY stdout and an
# unparseable one to the same `allow`, so this arm alone cannot tell a released Stop from
# one that wrote bytes onto the decision channel — which the new note-writing mint on this
# very path could do if its own output redirection were dropped.
{ [ "$(decision < "$C27_OUT")" = "allow" ] && [ ! -s "$C27_OUT" ]; } \
  && check "C27a the refused-spawn notice still releases Stop and writes no decision bytes" PASS \
  || check "C27a the refused-spawn notice still releases Stop and writes no decision bytes" FAIL

# --- C27b: the ABOVE-two arm, reached with a second refusal ------------------
# The single-refusal capture can only ever exercise one arm, so before this check
# the ladder could be collapsed into one unconditional string — or its predicate
# inverted — with the whole suite green. The second refusal is built from that same
# capture: every `toolu_` id is rewritten wholesale, so the duplicated tool_use and
# tool_result stay keyed to each other and the fixture's own id is never spelled
# here.
C27B_TRANSCRIPT="$STATE_DIR/c27b.jsonl"
cat "$C27_TRANSCRIPT" > "$C27B_TRANSCRIPT"
sed 's/toolu_[A-Za-z0-9]*/toolu_01SecondRefusal000000000/g' "$C27_TRANSCRIPT" >> "$C27B_TRANSCRIPT"
# Positive control. A rewrite that broke the keying would leave the probe at one
# refusal, and the arm assertion below would then grade the wrong branch while
# still reporting on the one it names.
C27B_PROBE="$(node "$PLUGIN_DIR/hooks/lib/reviewer-spawn-denial-v1.js" --transcript "$C27B_TRANSCRIPT" 2>/dev/null || true)"
case "$C27B_PROBE" in
  'status=blocked '*' denials=2')
    check "C27bpre the built transcript really carries two refusals" PASS ;;
  *)
    check "C27bpre the built transcript really carries two refusals (got '$C27B_PROBE')" FAIL ;;
esac
C27B_RAW="impl-denied2"
start_session "$C27B_RAW" "denied2"
C27B="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C27B" >/dev/null 2>&1
dirty
C27B_ERR="$STATE_DIR/c27b.err"; C27B_OUT="$STATE_DIR/c27b.out"
printf '{"session_id":"%s","hook_event_name":"Stop","transcript_path":"%s"}' \
  "$C27B_RAW" "$C27B_TRANSCRIPT" \
  | ZENSU_CONFIG="$CFG1" bash "$STOP" >"$C27B_OUT" 2>"$C27B_ERR"
if grep -qF 'Two refusals already stand' "$C27B_ERR" \
  && grep -qF 'refusals observed: 2' "$C27B_ERR" \
  && ! grep -qF 'completing the implementation is the right next move' "$C27B_ERR"; then
  check "C27b two observed refusals withdraw the sanction and route to the user" PASS
else
  check "C27b two observed refusals withdraw the sanction and route to the user" FAIL
fi
{ [ "$(decision < "$C27B_OUT")" = "allow" ] && [ ! -s "$C27B_OUT" ]; } \
  && check "C27c the withdrawn-sanction arm still releases Stop and writes no decision bytes" PASS \
  || check "C27c the withdrawn-sanction arm still releases Stop and writes no decision bytes" FAIL

# --- C28: a stuck counter is distinguishable from a clean worktree ----------
# `|| return 0` collapsed a missing state file, a missing node, an inactive chain,
# an exhausted counter and a contended-lock timeout into the SAME outcome as "the
# tree was clean". A counter sitting at the storage ceiling therefore disarmed the
# Stop surface permanently and silently, while the doctor kept rendering off the
# frozen value — two surfaces disagreeing about whether anything is measured.
C28_RAW="impl-stuck"
start_session "$C28_RAW" "stuck"
C28="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C28" >/dev/null 2>&1
C28_FILE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || exit 0
  tdd_state_file "$2"
' _ "$PLUGIN_DIR" "$C28" 2>/dev/null)"
if [ -n "$C28_FILE" ] && [ -f "$C28_FILE" ]; then
  # The storage ceiling itself: `_tdd_increment_counter_critical` refuses
  # `current >= 1000000` BEFORE incrementing, so the next Stop cannot advance it.
  node -e '
    const fs = require("fs"), f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.implStopCount = 1000000;
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$C28_FILE"
  dirty
  C28_ERR="$STATE_DIR/c28.err"; C28_OUT="$STATE_DIR/c28.out"
  printf '%s' "$(payload "$C28_RAW")" | ZENSU_CONFIG="$CFG5" bash "$STOP" >"$C28_OUT" 2>"$C28_ERR"
  # Read the plant back AFTER the Stop: it proves both that the document is still
  # valid (a tightened schema bound would answer `invalid` and render the same
  # message with this check green) and that the increment really did not advance.
  C28_PLANTED="$(counter_of "$C28")"
  [ "$C28_PLANTED" = "1000000" ] \
    && check "C28pre the planted counter is at the storage ceiling and still readable" PASS \
    || check "C28pre the planted counter is at the storage ceiling and still readable (got '$C28_PLANTED')" FAIL
    # The DISTINGUISHING clause, not the shared word: this arm is the increment
  # failure, not the non-numeric one.
  grep -qF 'could not be advanced' "$C28_ERR" \
    && check "C28 a failed increment says so instead of reading as a clean tree" PASS \
    || check "C28 a failed increment says so instead of reading as a clean tree" FAIL
  # The SHARED tail must state what is TRUE of the OTHER surface. It claimed the
  # doctor row was "measuring nothing" too, and then sent the reader to
  # /zensu:doctor in the same breath — but a failed increment leaves the persisted
  # counter intact, so that row keeps rendering the last recorded value and the
  # reader arrives at a row full of numbers having just been told it says nothing.
  # This very fixture is the counter-example: it plants 1000000 and the row would
  # render it. The retired claim is asserted ABSENT so it cannot return.
  # The RUNNABLE spelling, not the bare flag. `grep -qF 'chain-status'` alone matched the
  # very defect this arm was changed to remove — a flag with no interpreter, no path and no
  # CLAUDE_PLUGIN_DATA — so reverting `status_cmd` to the bare string kept every check green.
  if grep -qF 'The counter is stuck, not reset' "$C28_ERR" \
    && grep -qE 'bash .*zensu-log\.sh --chain-status' "$C28_ERR" \
    && grep -qF 'CLAUDE_PLUGIN_DATA=' "$C28_ERR" \
    && grep -qF 'threshold-gated and shows no count' "$C28_ERR" \
    && ! grep -qF 'shows nothing' "$C28_ERR" \
    && ! grep -qF 'both measuring nothing' "$C28_ERR" \
    && ! grep -qF 'keeps reporting the last value' "$C28_ERR" \
    && ! grep -qF 'parked-chain' "$C28_ERR"; then
    check "C28b the failure tail describes the doctor row truthfully" PASS
  else
    check "C28b the failure tail describes the doctor row truthfully" FAIL
  fi
  { [ "$(decision < "$C28_OUT")" = "allow" ] && [ ! -s "$C28_OUT" ]; } \
    && check "C28a the failed-increment notice still releases Stop and writes no decision bytes" PASS \
    || check "C28a the failed-increment notice still releases Stop and writes no decision bytes" FAIL
else
  check "C28 the planted workflow document could not be located" FAIL
fi

# --- C29: the configured range is strictly inside the storage ceiling -------
# The getter accepted `<= 1000000` while the counter refuses to advance at or
# past that same number, so a threshold of exactly 1000000 fires once and is
# silent forever after — the doctor meanwhile keeps rendering off the frozen
# value. Two bounds that coincide by hand, in two files, with only the DEFAULT
# machine-compared between them.
# $1 IS the config path. The comment said "$1 = configured value" while the body
# passed `$2` as ZENSU_CONFIG and discarded `$1`, so a later check written to the
# comment — `getter_with 5` — would export an empty ZENSU_CONFIG, get the built-in
# default back, and assert it successfully without the configured value ever being
# read. The throwaway first argument is gone rather than documented.
getter_with() {  # $1 = config path; prints the resolved threshold
  bash -c '
    set -u
    ZENSU_CONFIG="$2"; export ZENSU_CONFIG
    # shellcheck disable=SC1090
    source "$1/hooks/lib/zensu-config.sh" >/dev/null 2>&1 || { echo unavailable; exit 0; }
    zensu_impl_stop_nudge_after
  ' _ "$PLUGIN_DIR" "$1" 2>/dev/null
}
# DERIVED, not restated. Its neighbour C31a compares this same default against the
# renderer's declaration for exactly this reason, and a hardcoded `12` here turns
# C29 red on a legitimate default change — for a reason unrelated to the bound it
# grades.
# ONE extraction of the getter's operands, used by C29 and C31 alike. There were two
# spellings of it, and they drifted the moment the three duplicated getters collapsed
# onto `_zensu_config_bounded_int`: C31 was re-pointed and C29 was left reading a
# `local default=` line that no longer exists. Its own control caught that, which is
# the only reason it was a red check rather than a silently vacuous one — and the
# lesson is the same one the production collapse was about, one file over.
# PARAMETERIZED on the getter and its key, because the collapse made all three getters
# one-line calls with the same operand shape — so one extractor can pin all three
# hand-copied constant pairs instead of only the implementing-turns one.
# Both names are interpolated into a grep ERE and a sed BRE, so they must be plain
# identifiers. Every caller passes one; the contract is stated rather than enforced,
# because a key containing `.` would silently match any character and one containing `/`
# would break the `s` command — neither failure would look like a bad argument.
getter_operand() {  # $1 = getter name, $2 = config key (identifier chars only), $3 = 1|2|3
  grep -E "^$1\(\)" "$PLUGIN_DIR/hooks/lib/zensu-config.sh" \
    | head -1 \
    | sed -n "s/.*_zensu_config_bounded_int  *$2  *\([0-9][0-9]*\)  *\([0-9][0-9]*\)  *\([0-9][0-9]*\).*/\\1 \\2 \\3/p" \
    | awk -v i="$3" '{print $i}'
}
impl_getter_operand() {  # $1 = 1|2|3 for default|min|max
  getter_operand zensu_impl_stop_nudge_after implStopNudgeAfter "$1"
}
C29_DEFAULT="$(impl_getter_operand 1)"
[ -n "$C29_DEFAULT" ] \
  && check "C29dpre the getter's own default was located, so the comparison is not vacuous" PASS \
  || check "C29dpre the getter's own default was located, so the comparison is not vacuous" FAIL
C29_HIGH="$(getter_with "$(cfg_with 999999)")"
C29_OVER="$(getter_with "$(cfg_with 1000000)")"
[ "$C29_HIGH" = "999999" ] \
  && check "C29pre the getter still accepts the highest reachable threshold" PASS \
  || check "C29pre the getter still accepts the highest reachable threshold (got '$C29_HIGH')" FAIL
[ "$C29_OVER" = "$C29_DEFAULT" ] \
  && check "C29 a threshold the counter can never exceed falls back to the default" PASS \
  || check "C29 a threshold the counter can never exceed falls back to the default (got '$C29_OVER', want '$C29_DEFAULT')" FAIL

# --- C30: a blank TTL falls back to its default, exactly as the sibling does -
# `implStopThreshold` guards a blank string because Number('') is 0 and 0 means
# DISABLED. Its twin `ttlHours` did not, and 0 is equally the documented
# "disables the guard" value there — so a wrapper fault exporting an empty string
# silently switched the pending-review TTL off. The defect class was named and
# one of its two instances repaired; this grades the other.
mkdir -p "$PROJ/.zensu/state"
printf '{"ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PROJ/.zensu/state/pending-review.json"
C30_REP="$(ZDOC_TTL_HOURS='' ZDOC_ZENSU=absent ZDOC_NODE="vTEST" ZDOC_FORGE_PROVIDER=github \
  ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT=absent \
  ZDOC_BINDING=bound ZDOC_SESSION_KEY="$C10" ZDOC_IMPL_STOP_NUDGE_AFTER=99 \
  ZDOC_SESSION_PROJECT_ROOT="$PROJ" \
  ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN_DIR" ZENSU_CONFIG="" CLAUDE_PROJECT_DIR="$PROJ" \
  node "$REPORT" 2>/dev/null)"
if printf '%s' "$C30_REP" | grep -qF 'within its 6h TTL' \
  && ! printf '%s' "$C30_REP" | grep -qF 'TTL guard is disabled'; then
  check "C30 a blank ZDOC_TTL_HOURS falls back to the default rather than disabling the guard" PASS
else
  check "C30 a blank ZDOC_TTL_HOURS falls back to the default rather than disabling the guard" FAIL
fi
rm -f "$PROJ/.zensu/state/pending-review.json"

# --- C31: the doctor's hand-copies of the config default AND its bound --------
# CLAUDE.md names IMPL_STOP_NUDGE_FALLBACK / IMPL_STOP_NUDGE_MAX as a hand-copy of
# zensu_impl_stop_nudge_after's default and upper bound. C14a already compared the
# DEFAULT pair; the BOUND pair was unpinned, and the renderer's own comment could
# only NAME that gap. Drift there is silent in the worst direction: the doctor would
# grade a threshold the config reader rejects, so the two surfaces would disagree
# about whether the check is armed at all — the same "two surfaces measuring
# different things" failure this whole feature exists to remove.
#
# BOTH sides are derived from source, so neither literal can be edited alone, and
# the getter's bound is read out of its own DEFINITION LINE rather than out of the
# file: an unrelated `999999` elsewhere in zensu-config.sh must not satisfy it.
#
# The extraction was re-pointed when the three duplicated getters collapsed onto
# `_zensu_config_bounded_int`. Before that, the default came from a `local default=`
# line and the bound from an inline `n<=` comparison; both now travel as positional
# operands of one call, which is why the getter's own comment says those four
# operands must stay literals on a single line. It goes through `impl_getter_operand`
# rather than re-spelling the sed, because the two hand-copies of that spelling are
# exactly what drifted. The control below is what makes the re-point safe: if the
# extraction stops matching, C31pre fails loudly rather than letting `"" = ""` report
# agreement between two values nobody holds.
C31_CFG_DEFAULT="$(impl_getter_operand 1)"
C31_CFG_MAX="$(impl_getter_operand 3)"
C31_DOC_DEFAULT="$(sed -n 's/^var IMPL_STOP_NUDGE_FALLBACK = \([0-9][0-9]*\);$/\1/p' "$REPORT" | head -1)"
C31_DOC_MAX="$(sed -n 's/^var IMPL_STOP_NUDGE_MAX = \([0-9][0-9]*\);$/\1/p' "$REPORT" | head -1)"
# The control runs FIRST and is not decoration: every extraction above is a rename
# away from returning the empty string, and `"" = ""` would then report agreement
# between two values neither side actually holds.
if [ -n "$C31_CFG_DEFAULT" ] && [ -n "$C31_CFG_MAX" ] \
  && [ -n "$C31_DOC_DEFAULT" ] && [ -n "$C31_DOC_MAX" ]; then
  check "C31pre all four literals were located, so the comparison below is not vacuous" PASS
  [ "$C31_CFG_MAX" = "$C31_DOC_MAX" ] \
    && check "C31 the doctor's IMPL_STOP_NUDGE_MAX matches the getter's own bound" PASS \
    || check "C31 the doctor's IMPL_STOP_NUDGE_MAX matches the getter's own bound (cfg=$C31_CFG_MAX doctor=$C31_DOC_MAX)" FAIL
  [ "$C31_CFG_DEFAULT" = "$C31_DOC_DEFAULT" ] \
    && check "C31a the doctor's IMPL_STOP_NUDGE_FALLBACK matches the getter's default" PASS \
    || check "C31a the doctor's IMPL_STOP_NUDGE_FALLBACK matches the getter's default (cfg=$C31_CFG_DEFAULT doctor=$C31_DOC_DEFAULT)" FAIL
    # The bound must stay STRICTLY below the counter's storage ceiling, which
  # _tdd_increment_counter_critical refuses at. Equal is not good enough: a
  # threshold of exactly the ceiling is reachable once and never again.
  #
  # DERIVED, for the same reason C31 derives its two pairs: hardcoding the ceiling
  # here would let it DROP in zensu-tdd-phase.sh with this check still comparing
  # against the old number, so the very defect this arm names — a configured
  # threshold the counter can never reach — would ship with every check green.
  C31_CEIL="$(awk '/^_tdd_increment_counter_critical\(\)/{f=1} f{print} f&&/^}/{exit}' \
    "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" \
    | sed -n 's/.*current >= \([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -n "$C31_CEIL" ]; then
    check "C31bpre the counter's storage ceiling was located in its own function body" PASS
    [ "$C31_CFG_MAX" -lt "$C31_CEIL" ] 2>/dev/null \
      && check "C31b the configured bound stays strictly below the counter's storage ceiling" PASS \
      || check "C31b the configured bound stays strictly below the counter's storage ceiling (bound=$C31_CFG_MAX ceiling=$C31_CEIL)" FAIL
  else
    check "C31bpre the counter's storage ceiling was located in its own function body" FAIL
  fi
else
  check "C31pre all four literals were located, so the comparison below is not vacuous" FAIL
fi

# --- C32: the NON-NUMERIC counter arm, which no fixture can drive --------------
# C28b grades the increment-failure arm from a real Stop. Its twin — the arm that
# fires when tdd_increment_counter returns a non-numeric value — has no reachable
# fixture: the counter is written through mutateWorkflowState and read back through
# a schema that only admits integers, so producing a non-numeric return would mean
# breaking the reader this suite depends on everywhere else. Pinned at SOURCE
# instead, and labelled as such rather than left looking like a behavioural check.
#
# The control is the COUNT. An arm that is deleted, or a tail that is reworded in
# only one of the two, changes it — which is exactly the one-sided drift that let
# "parked-chain" survive in the failure tail after the doctor row had dropped it.
# COMMENTS STRIPPED. Without this the three counts below grade prose: the hook quotes the
# retired "silent again" wording in a comment explaining why it was retired, so a pure reflow
# of that paragraph turned C32 red with every production string correct — and, worse, a tail
# deleted from one arm and quoted in a comment kept C32_TAILS at 2 with C32 green. The sibling
# extraction earlier in this file already strips the same way.
C32_FN="$(hook_fn_body zensu_impl_stop_nudge code)"
C32_ECHOES="$(printf '%s\n' "$C32_FN" | grep -c '>&2' || true)"
[ -n "$C32_FN" ] && [ "$C32_ECHOES" -ge 3 ] \
  && check "C32pre the stripped function body is non-empty and still carries its notices" PASS \
  || check "C32pre the stripped function body is non-empty and still carries its notices (echoes=$C32_ECHOES)" FAIL
C32_TAILS="$(printf '%s\n' "$C32_FN" | grep -c 'The counter is stuck, not reset')"
# The retired claim, asserted absent in BOTH arms. It said the doctor row was
# measuring nothing while a failed increment leaves the persisted counter intact
# and that row keeps rendering it.
C32_FALSE="$(printf '%s\n' "$C32_FN" | grep -c 'both measuring nothing' || true)"
# The non-numeric arm has no reachable fixture, so C37's stderr sweep cannot see it. The
# extracted body can: sweeping it here is what keeps AC-002 pinned on the one branch no
# captured file covers.
C32_SILENT="$(printf '%s\n' "$C32_FN" | grep -c 'silent again' || true)"
if [ "$C32_TAILS" = "2" ] && [ "$C32_FALSE" = "0" ] && [ "$C32_SILENT" = "0" ]; then
  check "C32 both counter-failure arms carry the shared stuck-counter tail" PASS
else
  check "C32 both counter-failure arms carry the shared stuck-counter tail (found $C32_TAILS want 2, false-claim $C32_FALSE want 0, silence-promise $C32_SILENT want 0)" FAIL
fi
# WIDENED beyond the one function body. Scoping the retired-wording scan to
# `zensu_impl_stop_nudge` let the same vocabulary survive in the OTHER production
# carrier — `hooks/lib/zensu-doctor.sh` kept "the parked-at-implementing row" in a
# comment on the very variable this feature resolves — so the check reported a
# clean rename while half the tree still used the retired name.
# `grep -cE`, not `grep -c`: this file already records a check that went vacuous on a
# host whose grep does not honour the GNU-only `\|` alternation, and the same construct
# had come straight back here. The control below is what makes the difference visible —
# a pattern that cannot match anything reports zero exactly like a clean tree.
# FOUR arms, because the two hyphenated ones cannot match either retired EMITTED
# spelling: the row read `chain parked at \`implementing\`` (a SPACE, not a hyphen) and
# the switched-off row read ``the parked-at-\`implementing\` check`` (a BACKTICK exactly
# where the hyphenated arm requires `-implementing`). The check's label claimed a
# guard it did not provide.
# THREE arms, not four: `parked-at-.?implementing` subsumes `parked-at-implementing` in ERE
# because `.?` matches zero characters, so the redundant arm could be deleted with the control
# still reporting four. Each surviving arm is exercised by its own control line.
C32_PATTERN='parked-chain|parked at .?implementing|parked-at-.?implementing'
C32_CTRL="$(printf 'a parked-chain b\nc parked-at-implementing d\ne chain parked at `implementing` f\ng the parked-at-`implementing` check h\n' | grep -cE "$C32_PATTERN" || true)"
[ "$C32_CTRL" = "4" ] \
  && check "C32apre the retired-wording pattern matches every retired spelling on this host" PASS \
  || check "C32apre the retired-wording pattern matches every retired spelling on this host (got '$C32_CTRL')" FAIL
# THREE carriers. Scoping the scan to the Stop hook and the doctor wrapper left the
# retired name alive in the renderer — the file that actually owns the row — where its
# ZDOC_IMPL_STOP_NUDGE_AFTER header comment still used it.
# An unreadable carrier must FAIL, not be skipped: `grep -c` on a missing file emits
# nothing, `|| true` swallows the status, and the arithmetic then leaves the running
# total untouched — a renamed carrier would silently drop out of the negative scan.
C32_STALE=0
C32_SCANNED=0
for c32f in "$STOP" "$PLUGIN_DIR/hooks/lib/zensu-doctor.sh" "$REPORT"; do
  if [ -r "$c32f" ]; then
    C32_SCANNED=$((C32_SCANNED + 1))
    C32_STALE=$((C32_STALE + $(grep -cE "$C32_PATTERN" "$c32f" || true)))
  fi
done
[ "$C32_SCANNED" = "3" ] \
  && check "C32apre2 all three production carriers were readable and actually scanned" PASS \
  || check "C32apre2 all three production carriers were readable and actually scanned (got $C32_SCANNED)" FAIL
if [ "$C32_STALE" = "0" ]; then
  check "C32a no production carrier has drifted back to the retired 'parked' wording" PASS
else
  check "C32a no production carrier has drifted back to the retired 'parked' wording (found $C32_STALE)" FAIL
fi

# --- C33: zensu-doctor.sh sources its config library ONCE per run -------------
# The requirement was recorded as met while the file still carried a source inside
# EACH of the two resolve blocks. Neither ZDOC_ variable is pre-set in an ordinary
# invocation, so both guards passed and the library was sourced twice every run.
# Counted rather than read, because reading is what missed it.
# Both spellings and both brace forms. Counting only `. "$DIR/…"` would let a second
# load written as `source "${DIR}/…"` keep the count at 1 while the library really is
# sourced twice — the exact defect FR-003 names, passing its own check.
# Quoting-AGNOSTIC after the verb. The first spelling required `/` or `}` straight after
# `DIR`, so `. "$DIR"/zensu-config.sh` — the quote closed early — evaded the count entirely
# and C33 would have reported "exactly once" over a library sourced twice.
# NOT line-anchored. `^[[:space:]]*` missed a source written after any other token, so
# a resolve block compacted to `[ -f "$DIR/zensu-config.sh" ] && . "$DIR/zensu-config.sh"`
# kept the count at 1 over a library sourced twice — the very defect FR-003 names,
# passing its own check.
C33_PATTERN='(^|[;&|][[:space:]]*)[[:space:]]*(\.|source)[[:space:]]+[^;&|]*zensu-config\.sh'
C33_CTRL="$(printf '  . "$DIR/zensu-config.sh"\n  source "${DIR}/zensu-config.sh"\n  . "$DIR"/zensu-config.sh\n  [ -f x ] && . "$DIR/zensu-config.sh"\n  . "$DIR/zensu-config.sh"; . "$DIR/zensu-config.sh"\n' | grep -oE "$C33_PATTERN" | wc -l | tr -d ' ')"
[ "$C33_CTRL" = "6" ] \
  && check "C33pre the source-site pattern matches every source spelling on this host" PASS \
  || check "C33pre the source-site pattern matches every source spelling on this host (got '$C33_CTRL')" FAIL
# OCCURRENCES, not lines, and comments stripped first. `grep -c` counts LINES, so two loads
# written on one line read as one — the FR-003 defect passing its own check — and the
# de-anchored pattern matches inside a comment, so the file's own prose about a compacted
# source could drive the count to 2 with a single correct source site.
C33_SRC="$(grep -v '^[[:space:]]*#' "$PLUGIN_DIR/hooks/lib/zensu-doctor.sh" | grep -oE "$C33_PATTERN" | wc -l | tr -d ' ')"
[ "$C33_SRC" = "1" ] \
  && check "C33 zensu-doctor.sh sources zensu-config.sh exactly once" PASS \
  || check "C33 zensu-doctor.sh sources zensu-config.sh exactly once (found $C33_SRC)" FAIL

# --- C40: the missing-key clause is gated on BOTH bounds ------------------------
# The upper bound was added because at the getter's maximum the report rendered the
# cannot-fire row AND "withheld for the same reason" — two contradictory causes for one
# absent row. Nothing exercised it: the only empty-key reports ran at thresholds 0 and 3,
# and the only 999999 report supplied a real key, so deleting the bound changed nothing.
C40="$(doctor_report "" 999999)"
if printf '%s\n' "$C40" | grep -qF 'cannot fire in practice' \
  && printf '%s\n' "$C40" | grep -qF 'the session key did not reach this report' \
  && ! printf '%s\n' "$C40" | grep -qF 'withheld for the same reason'; then
  check "C40 at the maximum the missing-key row does not also claim the withheld row" PASS
else
  check "C40 at the maximum the missing-key row does not also claim the withheld row" FAIL
fi
# The symmetric partner: inside both bounds the clause MUST still be claimed, or the check
# above would pass against a clause deleted outright.
C40B="$(doctor_report "" 3)"
if printf '%s\n' "$C40B" | grep -qF 'the session key did not reach this report' \
  && printf '%s\n' "$C40B" | grep -qF 'withheld for the same reason'; then
  check "C40b inside both bounds the clause is still claimed" PASS
else
  check "C40b inside both bounds the clause is still claimed" FAIL
fi

# --- C39: the prose carriers quote the message the code actually emits ----------
# SEVEN times in this cycle a message was reworded and a carrier that QUOTES it was left on
# the retired wording — twice as a CRITICAL, because such a carrier presents itself as the
# authority on what the code says. The SEVENTH was this check's own first version: its comment
# claimed "the clause is compared, not described" while the body only blacklisted one retired
# literal, so the next rewording would have left all three carriers stale with C39 green.
#
# It COMPARES now. The clause is extracted from the hook's own comment-stripped body and each
# carrier must CONTAIN it, normalised for case and for line wrapping — CLAUDE.md legitimately
# uppercases part of it and hard-wraps mid-clause, so a raw fixed-string match would fail for
# a reason unrelated to drift. The retired-literal blacklist is kept as a second conjunct,
# anchored to its own context so an unrelated sentence elsewhere in these large files cannot
# turn it red while naming the wrong drift.
# BOTH arms must carry the clause and the pointer, not just the one a fixture can drive.
C32_GATED="$(printf '%s\n' "$C32_FN" | grep -c 'threshold-gated and shows no count' || true)"
C32_READ="$(printf '%s\n' "$C32_FN" | grep -c 'Read it with' || true)"
{ [ "$C32_GATED" = "2" ] && [ "$C32_READ" = "2" ]; } \
  && check "C32b both counter-failure arms carry the pointer and the threshold-gated clause" PASS \
  || check "C32b both counter-failure arms carry the pointer and the threshold-gated clause (gated=$C32_GATED read=$C32_READ, want 2/2)" FAIL
# BOTH arms, not the first. `head -1` left arm two's tail uncompared against the carriers,
# so a divergence after "no count" in one arm only would have gone unseen.
C39_ALL="$(printf '%s\n' "$C32_FN" | grep -o 'threshold-gated and shows [a-z ]*until that recorded value reaches the bound')"
C39_UNIQ="$(printf '%s\n' "$C39_ALL" | sort -u | grep -c .)"
C39_N="$(printf '%s\n' "$C39_ALL" | grep -c .)"
{ [ "$C39_N" = "2" ] && [ "$C39_UNIQ" = "1" ]; } \
  && check "C39apre both counter-failure arms phrase the clause identically" PASS \
  || check "C39apre both counter-failure arms phrase the clause identically (found $C39_N, distinct $C39_UNIQ)" FAIL
C39_PHRASE="$(printf '%s\n' "$C39_ALL" | head -1)"
[ -n "$C39_PHRASE" ] \
  && check "C39pre the emitted threshold-gated clause was located, so the comparison is not vacuous" PASS \
  || check "C39pre the emitted threshold-gated clause was located, so the comparison is not vacuous" FAIL
C39_NORM="$(printf '%s' "$C39_PHRASE" | tr -s '[:space:]' ' ' | tr 'A-Z' 'a-z')"
C39_MISS=""
for c39f in "$PLUGIN_DIR/CLAUDE.md" "$PLUGIN_DIR/docs/configuration.md" "$PLUGIN_DIR/docs/tdd-manager-workflow.md"; do
  c39n="$(basename "$c39f")"
  if [ ! -r "$c39f" ]; then C39_MISS="$C39_MISS unreadable:$c39n"; continue; fi
  # POSITIVE, per OCCURRENCE rather than per file. Containment clears a carrier on one hit,
  # and `docs/configuration.md` quotes the clause twice — so reverting one of them to a
  # wording outside the blacklist would have left C39 green.
  c39have="$(tr -s '[:space:]' ' ' < "$c39f" | tr 'A-Z' 'a-z' | grep -o "$C39_NORM" | grep -c . || true)"
  c39want="$(tr -s '[:space:]' ' ' < "$c39f" | tr 'A-Z' 'a-z' \
    | grep -o 'threshold-gated and [a-z ]*' | grep -c . || true)"
  [ "$c39have" = "$c39want" ] && [ "$c39have" -ge 1 ] \
    || C39_MISS="$C39_MISS stale:$c39n($c39have/$c39want)"
  # NEGATIVE: and must not still carry a retired spelling of the same clause.
  tr -s '[:space:]' ' ' < "$c39f" | tr 'A-Z' 'a-z' \
    | grep -qE 'threshold-gated and (shows nothing|silent)' \
    && C39_MISS="$C39_MISS retired:$c39n"
done
if [ -n "$C39_PHRASE" ] && [ -n "$C39_NORM" ] && [ -z "$C39_MISS" ]; then
  check "C39 all three prose carriers quote the clause the code emits" PASS
else
  check "C39 all three prose carriers quote the clause the code emits ($C39_MISS)" FAIL
fi

# --- C38: an unreachable threshold discloses, exactly as `0` does ---------------
# Only the literal `0` produced the switched-off row, while the getter accepts any integer up
# to its ceiling — so `implStopNudgeAfter: 999999` silenced this review-integrity diagnostic on
# both surfaces with no row and no bypass-ledger entry, since no gate was escaped. The config
# carrier is writable from inside a session, which is what makes it worth a check rather than
# a note. The control comes first: the same fixture must still render the ordinary row.
C38_CTRL="$(doctor_report "$C10" 1 | grep -cF 'turns at `implementing`' || true)"
[ "$C38_CTRL" = "1" ] \
  && check "C38pre the fixture still renders the ordinary implementing-turns row" PASS \
  || check "C38pre the fixture still renders the ordinary implementing-turns row (got $C38_CTRL)" FAIL
C38="$(doctor_report "$C10" 999999)"
# The retired MECHANICAL claim is asserted absent. The first wording said the threshold was
# "at or above the counter's own storage ceiling", which is false — the ceiling is one higher,
# as this repo's own IMPL_STOP_NUDGE_MAX comment says in the opposite direction — and it
# reached emitted operator text the doctor skill orders relayed.
if printf '%s\n' "$C38" | grep -qF 'cannot fire in practice' \
  && printf '%s\n' "$C38" | grep -qF 'the highest value the getter accepts' \
  && printf '%s\n' "$C38" | grep -qF 'switched-off check, not a clean one' \
  && ! printf '%s\n' "$C38" | grep -qF 'storage ceiling' \
  && ! printf '%s\n' "$C38" | grep -qF 'turns at `implementing`'; then
  check "C38 a threshold no chain can reach discloses instead of falling silent" PASS
else
  check "C38 a threshold no chain can reach discloses instead of falling silent" FAIL
fi

# --- C36: the flag is advertised where this repo advertises every flag ---------
# `config.example.json` is documented as carrying every flag, and five sibling
# features pin their own entry there. This one had none, so the entry could be
# dropped from that file with every check in the tree green — and the coupling
# roster in CLAUDE.md did not name the file either, so a rename driven off the
# roster would have left it advertising a dead key.
grep -qF '"implStopNudgeAfter"' "$PLUGIN_DIR/config.example.json" \
  && check "C36 config.example.json carries the implStopNudgeAfter entry" PASS \
  || check "C36 config.example.json carries the implStopNudgeAfter entry" FAIL

# --- C34: the notice fires ABOVE the threshold, not only AT it -----------------
# Every graded pair in this suite was (4,5), (5,5) or (1,1) — count below, count
# equal, count equal. So `-ge` and `-eq` agreed on all of them and the mutant
# survived the whole file. This is the pair that separates them: threshold 2 with
# the counter at 3.
C34_CFG="$(cfg_with 2)"
C34_RAW="impl-above"
start_session "$C34_RAW" "above"
C34="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C34" >/dev/null 2>&1
C34_ERR="$STATE_DIR/c34.err"
for _ in 1 2 3; do
  dirty
  printf '%s' "$(payload "$C34_RAW")" | ZENSU_CONFIG="$C34_CFG" bash "$STOP" >/dev/null 2>"$C34_ERR"
done
# Positive control: the assertion below is about a count STRICTLY above the
# threshold, so it proves nothing unless the counter really got there.
C34_COUNT="$(counter_of "$C34")"
[ "$C34_COUNT" = "3" ] \
  && check "C34pre three dirty Stops drove the counter above the threshold of 2" PASS \
  || check "C34pre three dirty Stops drove the counter above the threshold of 2 (got '$C34_COUNT')" FAIL
if grep -qF "ended 3 turns" "$C34_ERR" \
  && grep -qF "still at 'implementing'" "$C34_ERR"; then
  check "C34 the notice still fires with the count above the threshold" PASS
else
  check "C34 the notice still fires with the count above the threshold" FAIL
fi

# --- C35: the doctor row QUALIFIES the verb while a refusal note stands ---------
# Two surfaces, one chain. The Stop notice names `--tdd-complete` only with the
# refusal stated beside it; the doctor row named it bare, so a user who ran
# /zensu:doctor for a second opinion was told to walk into the gate the first
# surface had just warned about. The row now ADDS a caveat while a LIVE note for
# its own session key exists and KEEPS the command in every arm — withholding was
# the first attempt and was wrong on two independent grounds, both recorded at the
# push site. The controls below are what keep these arms from passing because the
# row vanished altogether.
C35_RAW="impl-rowdenied"
start_session "$C35_RAW" "rowdenied"
C35="$STARTED_SESSION_KEY"
bash "$LOG" --tdd-begin --session "$C35" >/dev/null 2>&1
C35_FILE="$(bash -c '
  set -u
  # shellcheck disable=SC1090
  source "$1/hooks/lib/zensu-tdd-phase.sh" >/dev/null 2>&1 || exit 0
  tdd_state_file "$2"
' _ "$PLUGIN_DIR" "$C35" 2>/dev/null)"
if [ -n "$C35_FILE" ] && [ -f "$C35_FILE" ]; then
  node -e '
    const fs = require("fs"), f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.implStopCount = 12;
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  ' "$C35_FILE"
  # WITHOUT the note first: the command must be there, or the assertion after it
  # would pass for a row that never renders a command at all.
  # SCOPED to the row itself, never to the whole report: other rows legitimately
  # name the same verb, and an unscoped absence assertion would grade them too.
  #
  # The row QUALIFIES rather than withholding, and the three arms below are what
  # hold that apart from the withholding version it replaced. Withholding was wrong
  # twice: the note is unauthenticated, so anything able to write the state
  # directory could delete the row's only remedy; and the note is minted only by a
  # Stop that clears the dirty-tree and threshold gates, while this row renders off
  # the persisted counter alone, so one clean-tree turn silently restored the bare
  # recommendation. The command must therefore be present in ALL THREE arms.
  C35_CAVEAT='records that the host permission layer'
  C35_BEFORE="$(doctor_report "$C35" 12 | grep -F 'turns at `implementing`' || true)"
  if [ -n "$C35_BEFORE" ] && printf '%s\n' "$C35_BEFORE" | grep -qF -- '--tdd-complete' \
    && ! printf '%s\n' "$C35_BEFORE" | grep -qF "$C35_CAVEAT"; then
    check "C35pre without a refusal note the row names the verb and adds no caveat" PASS
  else
    check "C35pre without a refusal note the row names the verb and adds no caveat" FAIL
  fi
  # PROJECT-anchored, like the writer: `reviewer_denial_note_path` joins
  # PROJECT_ROOT, and `stateProjectRoot()` in the renderer resolves the same tree.
  # Writing it into the suite's own STATE_DIR instead put the note where neither
  # side looks, which is how this check first passed its control and failed itself.
  mkdir -p "$PROJ/.zensu/state"
  node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      schemaVersion: 1, kind: "auto-mode-classifier", detectedAtMs: Date.now(),
    }) + "\n");
  ' "$PROJ/.zensu/state/reviewer-spawn-denied-$C35.json"
  C35_AFTER="$(doctor_report "$C35" 12 | grep -F 'turns at `implementing`' || true)"
  if [ -n "$C35_AFTER" ] \
    && printf '%s\n' "$C35_AFTER" | grep -qF "$C35_CAVEAT" \
    && printf '%s\n' "$C35_AFTER" | grep -qF -- '--tdd-complete'; then
    check "C35 a live refusal note adds the caveat and keeps the remedy" PASS
  else
    check "C35 a live refusal note adds the caveat and keeps the remedy" FAIL
  fi
  # The LIVENESS half. Without it the predicate under test is unpinned in the one
  # direction that matters: `classifyDenialNote(...) === 'live'` could be relaxed to
  # `!== 'missing'` and both arms above would still pass, so a note past its TTL — or
  # future-stamped, or shape-rejected — would keep qualifying the row forever.
  # `doctor_report` pins ZDOC_TTL_HOURS=6, so seven hours is unambiguously stale.
  node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      schemaVersion: 1, kind: "auto-mode-classifier",
      detectedAtMs: Date.now() - 7 * 3600 * 1000,
    }) + "\n");
  ' "$PROJ/.zensu/state/reviewer-spawn-denied-$C35.json"
  C35_STALE="$(doctor_report "$C35" 12 | grep -F 'turns at `implementing`' || true)"
  if [ -n "$C35_STALE" ] \
    && printf '%s\n' "$C35_STALE" | grep -qF -- '--tdd-complete' \
    && ! printf '%s\n' "$C35_STALE" | grep -qF "$C35_CAVEAT"; then
    check "C35s a note past the TTL no longer qualifies the row" PASS
  else
    check "C35s a note past the TTL no longer qualifies the row" FAIL
  fi
  # The REJECTED arm. C35pre plants nothing, C35 plants a live note and C35s a stale one, so
  # the verdict test could be relaxed from `=== 'live'` to anything-but-missing-or-stale and
  # all three would still pass — letting a malformed, unauthenticated note attach the refusal
  # caveat to the row, which is the fabricated-permission outcome the sibling reader guards.
  node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      schemaVersion: 2, kind: "auto-mode-classifier", detectedAtMs: Date.now(),
    }) + "\n");
  ' "$PROJ/.zensu/state/reviewer-spawn-denied-$C35.json"
  C35_REJ="$(doctor_report "$C35" 12 | grep -F 'turns at `implementing`' || true)"
  if [ -n "$C35_REJ" ] \
    && printf '%s\n' "$C35_REJ" | grep -qF -- '--tdd-complete' \
    && ! printf '%s\n' "$C35_REJ" | grep -qF "$C35_CAVEAT"; then
    check "C35r a shape-rejected note does not qualify the row" PASS
  else
    check "C35r a shape-rejected note does not qualify the row" FAIL
  fi
  rm -f "$PROJ/.zensu/state/reviewer-spawn-denied-$C35.json"
else
  check "C35 the planted workflow document could not be located" FAIL
fi

# --- C37: the no-false-silence rule holds on EVERY branch, not just the ordinary one
# AC-002's absence assertion lived on the ordinary branch's stderr alone, so the
# refused-spawn arms and both counter-failure arms could regain a silence promise with
# the whole suite green. Every notice this file captures is swept here instead.
# The control comes first: a sweep over files that do not exist reports zero hits and
# reads exactly like a clean result.
# BRANCHES, not a file count. `$C5_ERR` and `$C34_ERR` both capture the ORDINARY notice,
# so a floor of four was reachable with only three distinct branches swept — and the one
# that could drop out was `$C28_ERR`, the only capture of the branch this round rewrote.
# Each is required by NAME instead.
C37_FILES=""
C37_MISSING=""
for c37pair in "ordinary:$C5_ERR" "refused-below-two:$C27_ERR" "refused-at-two:$C27B_ERR" "counter-failure:${C28_ERR:-}"; do
  c37name="${c37pair%%:*}"; c37f="${c37pair#*:}"
  if [ -n "$c37f" ] && [ -s "$c37f" ]; then C37_FILES="$C37_FILES $c37f"; else C37_MISSING="$C37_MISSING $c37name"; fi
done
# The above-threshold ordinary capture is swept too, but it is not a distinct BRANCH, so
# it is not required.
[ -n "${C34_ERR:-}" ] && [ -s "${C34_ERR:-}" ] && C37_FILES="$C37_FILES $C34_ERR"
[ -z "$C37_MISSING" ] \
  && check "C37pre every distinct notice branch was captured and is available to sweep" PASS \
  || check "C37pre every distinct notice branch was captured and is available to sweep (missing:$C37_MISSING)" FAIL
C37_BAD=0
for c37f in $C37_FILES; do
  grep -qF 'silent again' "$c37f" && C37_BAD=$((C37_BAD + 1))
done
[ "$C37_BAD" = "0" ] \
  && check "C37 no notice branch promises future silence the code does not keep" PASS \
  || check "C37 no notice branch promises future silence the code does not keep (found $C37_BAD)" FAIL

# --- C41: CLAUDE.md names SYMBOLS, never line numbers, for this hook -----------
# Two anchors in the foreign-chain bullet went stale the moment this feature
# inserted a function above them: `:951` named the SESSION_IMPL_COMPLETE release
# and `:954-956` the CAP release, which sit far below that now. A line number in
# prose is a claim that rots silently — nothing recomputes it and no reader can
# tell a correct one from a drifted one without opening the file — so the FORM is
# forbidden rather than corrected to today's numbers, which would only reset the
# clock on the same defect.
C41_MD="$PLUGIN_DIR/CLAUDE.md"
# Filename-INDEPENDENT, because the rule it enforces is. A `zensu-tdd-phase.sh:1198`
# or a `zensu-doctor-report.js:1808` anchor rots in exactly the same way and read as
# permitted while the guard named one hook. The whole file carries zero matches of the
# broader class today, so widening costs no red check and closes the form for every
# carrier the rule names.
C41_RE='\.(sh|js|mjs|json|md):[0-9]'
C41_CTRL="$(printf 'a hooks/stop-chain-enforcer.sh:951 line\nand zensu-doctor-report.js:1808 too\n' | grep -cE "$C41_RE" || true)"
[ "$C41_CTRL" = "2" ] \
  && check "C41pre the line-anchor pattern matches the form it forbids" PASS \
  || check "C41pre the line-anchor pattern matches the form it forbids (got '$C41_CTRL')" FAIL
C41_HITS="$(grep -cE "$C41_RE" "$C41_MD" || true)"
C41_WHERE="$(grep -nE "$C41_RE" "$C41_MD" | head -3 | tr '\n' ' ' || true)"
[ "$C41_HITS" = "0" ] \
  && check "C41 CLAUDE.md carries no <file>:<line> source anchor" PASS \
  || check "C41 CLAUDE.md carries no <file>:<line> source anchor (found $C41_HITS: $C41_WHERE)" FAIL

# The next several all read the SAME function body. `hook_fn_body` refuses a body
# whose closing brace it did not reach, so an over-extraction fails here rather than
# silently handing every check below the rest of the file.
C42_BODY="$(hook_fn_body zensu_impl_stop_nudge)"
# The comment-stripped companion. Checks that grade CODE take this one: the hook writes
# the pathspec literal and the words `command -v timeout` in prose as well, so a raw body
# lets a sentence satisfy a positive check and break a negative one.
C42_CODE="$(hook_fn_body zensu_impl_stop_nudge code)"
# The `tdd_increment_counter` conjunct grades the STRIPPED body: the function's own LOCK
# DOMAIN comment names that identifier, so on the raw body the precondition survived the
# call site being deleted — and C43, C44, C50, C56a and C56b all rest on it.
[ -n "$C42_BODY" ] && [ -n "$C42_CODE" ] && printf '%s' "$C42_CODE" | grep -qF 'tdd_increment_counter' \
  && check "C42pre the nudge function body was extracted and ended at a column-0 brace" PASS \
  || check "C42pre the nudge function body was extracted and ended at a column-0 brace" FAIL

# --- C42: the shared watchdog ladder probes gtimeout as well as timeout --------
# MEASURED on the maintainer's own host: neither `timeout` nor `gtimeout` exists
# on base macOS. `gtimeout` is what a Homebrew coreutils install actually puts on
# PATH, so probing only `timeout` misses the one watchdog such a host is likely to
# have. The unbounded fallback is KEPT on purpose — C56 pins that arm, and the
# CLAUDE.md gap bullet states its bound, which C42b/C53 hold against this ladder.
#
# The ladder lives in `zensu_run_bounded` now, shared with the transcript probe,
# so it is read out of THAT body: a check pointed at the nudge would go green on a
# ladder the nudge no longer contains.
C42_LADDER="$(hook_fn_body zensu_run_bounded code "$BOUNDED_LIB")"
[ -n "$C42_LADDER" ] \
  && check "C42lpre the shared watchdog helper's body was extracted and ended at a column-0 brace" PASS \
  || check "C42lpre the shared watchdog helper's body was extracted and ended at a column-0 brace" FAIL
printf '%s' "$C42_LADDER" | grep -qF 'command -v gtimeout' \
  && check "C42 the shared ladder falls back to gtimeout before running unbounded" PASS \
  || check "C42 the shared ladder falls back to gtimeout before running unbounded" FAIL
# ORDER, not presence. A ladder that probed `gtimeout` first would satisfy a bare
# presence pair while the stated preference was false, so compare positions the way
# C43 does.
C42A_T="$(printf '%s\n' "$C42_LADDER" | grep -n 'command -v timeout' | head -1 | cut -d: -f1)"
C42A_G="$(printf '%s\n' "$C42_LADDER" | grep -n 'command -v gtimeout' | head -1 | cut -d: -f1)"
[ -n "$C42A_T" ] && [ -n "$C42A_G" ] && [ "$C42A_T" -lt "$C42A_G" ] \
  && check "C42a the ladder prefers timeout, so gtimeout is a fallback and not a replacement" PASS \
  || check "C42a the ladder prefers timeout, so gtimeout is a fallback and not a replacement (timeout='$C42A_T' gtimeout='$C42A_G')" FAIL
# The gap bullet must describe the shipped ladder. It named only `timeout`, which
# made the sentence false the moment a second watchdog was probed — and its own
# claim of a mitigation was what the review finding rejected.
grep -qF 'gtimeout' "$C41_MD" \
  && check "C42b the CLAUDE.md gap bullet names the second watchdog the code probes" PASS \
  || check "C42b the CLAUDE.md gap bullet names the second watchdog the code probes" FAIL

# --- C43: the free checks come before the node spawn ---------------------------
# `zensu_impl_stop_nudge_after` spawns node. On a host with no git the feature can
# never fire, so paying a process spawn first is a cost every armed-but-incomplete
# chain carries at every turn end for nothing. Compare positions within the body.
#
# COMMENTS ARE STRIPPED FIRST, and that is not tidiness. The comment explaining this
# very ordering names `zensu_impl_stop_nudge_after`, so an unfiltered scan found the
# PROSE ahead of the code and reported the ordering as still wrong after it had been
# fixed. An oracle that reads its own explanation is measuring the wrong file.
C43_CODE="$C42_CODE"
C43_GIT="$(printf '%s\n' "$C43_CODE" | grep -n 'command -v git' | head -1 | cut -d: -f1)"
C43_CFG="$(printf '%s\n' "$C43_CODE" | grep -n 'zensu_impl_stop_nudge_after' | head -1 | cut -d: -f1)"
[ -n "$C43_GIT" ] && [ -n "$C43_CFG" ] \
  && check "C43pre both ordering landmarks were located in the function body" PASS \
  || check "C43pre both ordering landmarks were located in the function body (git='$C43_GIT' cfg='$C43_CFG')" FAIL
[ -n "$C43_GIT" ] && [ -n "$C43_CFG" ] && [ "$C43_GIT" -lt "$C43_CFG" ] \
  && check "C43 the free git probe precedes the threshold node spawn" PASS \
  || check "C43 the free git probe precedes the threshold node spawn (git line $C43_GIT, spawn line $C43_CFG)" FAIL

# --- C44: the lock-domain decision is recorded, not left to be rediscovered -----
# The increment holds only the CAS lock while the sibling stop-budget counter takes
# the external lease, so the document has two writer classes that do not serialise
# against each other. Taking the lease here was REJECTED — this branch's contract is
# to release immediately and a contended lock already costs seconds — but a decision
# nobody wrote down is indistinguishable from an oversight, and the next reader would
# "fix" it straight into the latency regression it was rejected to avoid.
printf '%s' "$C42_BODY" | grep -qF 'tdd_increment_stop_budget' \
  && check "C44 the increment call site names the sibling lease writer it deliberately diverges from" PASS \
  || check "C44 the increment call site names the sibling lease writer it deliberately diverges from" FAIL

# --- C45: the Autopilot flag triple has ONE rendering site ---------------------
# Two hand-authored copies of the same three-flag string existed, from the same three
# variables with the same printf '%q' quoting, and their guards had already drifted
# apart cosmetically — the fingerprint of a second authoring. Count non-comment
# rendering sites in the hook.
# Counted by OCCURRENCE of one unsplittable token, not by matching all three flags on
# one line. The line-anchored form could not see a copy whose printf format was wrapped
# across two lines, and counted two same-line copies as one — either way reporting
# "exactly one place" for a file that had two. The three-flag pattern is kept as the
# SHAPE control, so a token count that stops corresponding to a real rendering site
# fails loudly rather than drifting into a bare word count.
C45_RE='\-\-autopilot-run .*--autopilot-attempt .*--chain-id'
C45_CTRL="$(printf ' x=" --autopilot-run $A --autopilot-attempt $B --chain-id $C"\n' | grep -cE "$C45_RE" || true)"
[ "$C45_CTRL" = "1" ] \
  && check "C45pre the triple pattern matches a rendering site" PASS \
  || check "C45pre the triple pattern matches a rendering site (got '$C45_CTRL')" FAIL
C45_SITES="$(grep -v '^[[:space:]]*#' "$STOP" | grep -oF -- '--autopilot-run' | wc -l | tr -d ' ')"
C45_SHAPE="$(grep -v '^[[:space:]]*#' "$STOP" | grep -cE "$C45_RE" || true)"
[ "$C45_SITES" = "1" ] && [ "$C45_SHAPE" = "1" ] \
  && check "C45 the Autopilot flag triple is rendered in exactly one place in the Stop hook" PASS \
  || check "C45 the Autopilot flag triple is rendered in exactly one place in the Stop hook (tokens=$C45_SITES shaped=$C45_SHAPE)" FAIL

# --- C46: the docs row does not lend stopBlockCount's atomicity to this counter -
# The row earns "atomically increments" for `stopBlockCount`, which is written under
# the external lease. The implementing-turns counter is not, and a reader who carries
# the qualifier down the same cell would believe a guarantee nothing provides.
# SCOPED TO THE ROW, not the file. Both needles are about co-location — the qualifier
# and the sentence that stops it carrying down the cell have to be in the SAME table
# row, or a reader of that row still inherits the wrong guarantee. Whole-file greps
# stay green when the scoping sentence is moved into any other row, which is exactly
# the shape the labels claim to forbid. C20 and C25 scope rows for the same reason.
C46_DOC="$PLUGIN_DIR/docs/configuration.md"
C46_ROW="$(grep -F '| `stop-chain-enforcer.sh` |' "$C46_DOC" | head -1)"
[ -n "$C46_ROW" ] && printf '%s' "$C46_ROW" | grep -qF 'atomically increments the integrated' \
  && check "C46pre the row was located and still carries the qualifier this check scopes" PASS \
  || check "C46pre the row was located and still carries the qualifier this check scopes" FAIL
printf '%s' "$C46_ROW" | grep -qF 'holds only the CAS lock' \
  && check "C46 the same row states that the implementing-turns counter takes no lease" PASS \
  || check "C46 the same row states that the implementing-turns counter takes no lease" FAIL

# --- C49: the SIBLING watchdog on this same Stop path uses the same ladder ------
# `reviewer_spawn_denial_probe` runs on the very path the nudge does, and its own
# comment records the LARGER exposure: the transcript path is host-supplied, lives
# outside the project root, and can sit on stalled or network-backed storage. Adding
# `gtimeout` to the git probe and not to that one left the lower-risk child bounded
# on a Homebrew-coreutils host and the higher-risk one unbounded.
#
# The body is taken COMMENT-STRIPPED. A first spelling took it raw, and the probe's own
# comment names `zensu_run_bounded` — so deleting the actual invocation left C49 green,
# reading its own explanation. The same defect C43 records one block up, reintroduced.
C49_BODY="$(hook_fn_body reviewer_spawn_denial_probe code)"
[ -n "$C49_BODY" ] \
  && check "C49pre the sibling probe body was extracted and ended at a column-0 brace" PASS \
  || check "C49pre the sibling probe body was extracted and ended at a column-0 brace" FAIL
# It must CONSUME the shared ladder rather than carry its own arm: a second copy is how
# the two diverged in the first place. Anchored on the INVOCATION form, not the bare
# symbol, so a mention cannot stand in for a call.
printf '%s' "$C49_BODY" | grep -qF 'zensu_run_bounded node' \
  && check "C49 the sibling transcript probe consumes the shared watchdog ladder" PASS \
  || check "C49 the sibling transcript probe consumes the shared watchdog ladder" FAIL
printf '%s' "$C49_BODY" | grep -qE 'command -v (timeout|gtimeout)' \
  && check "C49a the sibling probe keeps no private copy of the ladder" FAIL \
  || check "C49a the sibling probe keeps no private copy of the ladder" PASS

# --- C49b was REMOVED, twice over, and the reason is recorded rather than retried --
# The first spelling counted ladder invocations and asserted two. That fires on the
# CORRECT behaviour — a third wrapped child turns it red — and is blind to the wrong one,
# because a child added WITHOUT the ladder adds no occurrence and leaves the count at two.
#
# The second spelling tried to become the membership check its own comment described: scan
# for command-position child spawns, excuse the two lease children CLAUDE.md declares
# unbounded, and require the remainder to be empty. Two independent reviewers found it
# still asserted the same frozen count, and that its spawn regex could not even see the
# `VAR=value node -e` spelling this hook uses seven times — including in both declared
# children, so the exclusion list excused nothing.
#
# It is GONE rather than rewritten a third time, because the criterion is not expressible
# here. What the shared ladder serves is "children that read OUTSIDE this process", and no
# grep can tell that from the many `printf … | node -e` children that read this process's
# own stdin. A census that flagged all of them would be wrong; one that flagged none would
# be the frozen count again. The two children that DO qualify are pinned individually and
# by name — C49 for the transcript read, C56a for the git probe. State the bound with them:
# that holds for the TWO children that exist today and for no future one. A third
# out-of-process child added without the ladder is caught by nothing here — C60 compares
# ladder COPIES, not consumers, so it stays green. That is the residual this deletion
# accepts, named rather than dressed up as coverage.

# --- C61: the SECOND shell rendering agrees with the first, byte for byte -------
# C45 is scoped to the Stop hook while the contract is not: `post-review-tdd-delegate.sh`
# builds the same three flags from its own globals, `zensu-log.sh` parses the result, and
# nothing held the two against each other — a flag-order or quoting divergence there could
# land green. Compare the FLAG SEQUENCE of both renderings, which is the part `zensu-log.sh`
# reads; the operand spellings legitimately differ (`%q` conversions here, pre-quoted
# variables there). This is the byte-comparison shape CLAUDE.md records for S7m.
C61_DELEGATE="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
c61_flags() { grep -oE '\-\-autopilot-run [^ ]+ --autopilot-attempt [^ ]+ --chain-id' | head -1 | sed 's/[^ ]*\$[^ ]*/<operand>/g; s/%q/<operand>/g'; }
# Derived HERE, not borrowed from C55's body: that variable is assigned further down the
# file, so reading it would have compared the delegate against an empty string.
C61_OWNER="$(hook_fn_body zensu_autopilot_link_args code | c61_flags)"
C61_COPY="$(grep -vE '^[[:space:]]*#' "$C61_DELEGATE" | c61_flags)"
[ -n "$C61_OWNER" ] && [ -n "$C61_COPY" ] \
  && check "C61pre both renderings were located, so the comparison below is not two empty strings" PASS \
  || check "C61pre both renderings were located (owner='$C61_OWNER' copy='$C61_COPY')" FAIL
[ "$C61_OWNER" = "$C61_COPY" ] \
  && check "C61 the delegate's hand-authored copy carries the same flag sequence as the single renderer" PASS \
  || check "C61 the delegate's hand-authored copy carries the same flag sequence (owner='$C61_OWNER' copy='$C61_COPY')" FAIL

# --- C50: the watchdog ladder spells its payload ONCE --------------------------
# The arms are mutually exclusive per host, so a divergence between them cannot fail
# behaviourally anywhere: on a Linux CI runner only the `timeout` arm ever executes,
# while base macOS takes the last one. Three copies of the pathspec the surrounding
# comment calls load-bearing is the same one-rendering-site hazard C45 exists to
# forbid for the Autopilot flag triple, three lines away from it.
#
# COMMENT-STRIPPED, because the same pathspec literal is written in prose elsewhere in
# this hook: an unstripped count would go red when a sentence moves and stay green when
# the probe is deleted beside a comment that mentions it.
C50_SPELLINGS="$(printf '%s\n' "$C42_CODE" | grep -c "exclude).zensu" || true)"
[ "$C50_SPELLINGS" = "1" ] \
  && check "C50 the nudge spells the git probe exactly once" PASS \
  || check "C50 the nudge spells the git probe exactly once (found $C50_SPELLINGS)" FAIL

# --- C51/C52: CLAUDE.md registers what this change made shared -----------------
# Both are new single sources of truth, and this repository's whole convention is
# that a shared owner is named on a roster so the next reader finds its consumers.
grep -qF 'zensu_autopilot_link_args' "$C41_MD" \
  && check "C51 CLAUDE.md names the single renderer of the Autopilot flag triple" PASS \
  || check "C51 CLAUDE.md names the single renderer of the Autopilot flag triple" FAIL
grep -qF '_zensu_config_bounded_int' "$C41_MD" \
  && check "C52 CLAUDE.md names the shared bounded-int config helper" PASS \
  || check "C52 CLAUDE.md names the shared bounded-int config helper" FAIL
# The third shared owner this change introduced. Without it, renaming the ladder would
# redden only the checks that grade the HOOK, and the fix would land in this file while
# the CLAUDE.md roster went stale unnoticed — which is the drift C51/C52 exist to stop.
grep -qF 'zensu_run_bounded' "$C41_MD" \
  && check "C59 CLAUDE.md names the shared watchdog ladder" PASS \
  || check "C59 CLAUDE.md names the shared watchdog ladder" FAIL

# --- C53: the watchdog PROSE and the watchdog CODE describe one ladder ---------
# C42b greps the whole file, so the gap bullet alone satisfies it while the section's
# main prose still says `timeout`-only eighty lines above — the exact drift shape that
# paragraph already records about itself once. Scope the assertion to the paragraph
# carrying the claim.
# Anchored on the CLAIM, not on the adjective. A first spelling keyed on
# "`timeout`-bounded WHEN" and went vacuous the moment that phrase was corrected —
# a check that only fires while the defect's exact wording survives is worth nothing.
# "The SAME conditional applies to a second" is the sentence whose truth depends on
# both children carrying the same ladder, so it is the right thing to hold.
C53_PARA="$(awk -v RS='' '/The SAME conditional applies to a second/' "$C41_MD" | head -40)"
[ -n "$C53_PARA" ] \
  && check "C53pre the watchdog paragraph was located, so the scan is not vacuous" PASS \
  || check "C53pre the watchdog paragraph was located, so the scan is not vacuous" FAIL
printf '%s' "$C53_PARA" | grep -qF 'gtimeout' \
  && check "C53 the paragraph making the watchdog claim names both binaries the code probes" PASS \
  || check "C53 the paragraph making the watchdog claim names both binaries the code probes" FAIL

# --- C54: the renderer's coupling comment names the extraction that exists -----
# It named `n<=999999` read "out of the function body", a spelling the config collapse
# removed entirely. A guarding comment that sends a maintainer after bytes the code
# does not carry is the failure class this file's C39 exists for.
# POSITIVE, not negative. A first spelling forbade the string `n<=999999` anywhere in
# the file and then matched the very sentence that explains the spelling is gone — a
# negative assertion that cannot distinguish a stale claim from its own correction.
# What matters is that the comment names the extraction that EXISTS, and that it no
# longer claims to read a bound out of a function body the collapse removed.
# `getter_operand`, not `impl_getter_operand`: the extractor was parameterized and the
# comment names the owning function. The shorter needle matches either spelling, so this
# does not have to move again when a caller does.
grep -qF 'getter_operand' "$REPORT" \
  && check "C54 the renderer comment names the extraction that actually holds its constants" PASS \
  || check "C54 the renderer comment names the extraction that actually holds its constants" FAIL
# The companion is FLATTENED before matching, because the claim it forbids wraps across
# comment lines and `grep -F` matches per line. Comment markers are stripped too: the
# first spelling matched `out of the // function body`, which pins ONE wrap of one
# sentence — reintroduce the claim on a single line and the needle is absent, so the
# check passes while the forbidden text is right there. C54actl proves the needle can
# match the claim in any wrap, which is what a negative check owes its reader.
c54_flat() { tr '\n' ' ' | sed 's|//| |g' | tr -s ' '; }
C54_CTL="$(printf '// … read out of the\n// function body, not the file\n' | c54_flat | grep -c 'read out of the function body' || true)"
[ "$C54_CTL" = "1" ] \
  && check "C54actl the flattened needle matches the claim regardless of how it wraps" PASS \
  || check "C54actl the flattened needle matches the claim regardless of how it wraps (got '$C54_CTL')" FAIL
c54_flat < "$REPORT" | grep -q 'read out of the function body' \
  && check "C54a the comment no longer claims a bound is read out of the getter's function body" FAIL \
  || check "C54a the comment no longer claims a bound is read out of the getter's function body" PASS

# --- C55: the flag triple is rendered with %q, and something says so -----------
# The three operands arrive raw from the workflow document, which the session can
# write, and land in text a model is told to run. C45 counts rendering SITES and
# matches `%s` exactly as well as `%q`, so the quoting the consolidation comment cites
# as the risk it removes was itself unguarded.
C55_BODY="$(hook_fn_body zensu_autopilot_link_args code)"
C55_FMT="$(printf '%s\n' "$C55_BODY" | grep -c -- "--autopilot-run %q --autopilot-attempt %q --chain-id %q" || true)"
[ "$C55_FMT" = "1" ] \
  && check "C55 the single renderer shell-quotes all three session-writable operands" PASS \
  || check "C55 the single renderer shell-quotes all three session-writable operands (found $C55_FMT)" FAIL
# A SUBSTRING match cannot see a FOURTH operand appended to the same format string, and an
# unquoted one would reach model-read text exactly as the three quoted ones do. Forbid any
# other conversion in this body, with a control proving the pattern sees one.
# A TOTAL rule, not a blacklist of spellings. Enumerating conversion letters missed `%c`,
# `%f` and the `%*s` / `%#x` / `%+d` flag forms, every one of which would reach the same
# model-read remedy string unquoted. Count every `%` with `%%` collapsed first, and require
# the total to equal the count of `%q`: any other conversion, in any spelling, breaks it.
c55_pcts() { tr -d '\n' | sed 's/%%//g' | grep -o "$1" | wc -l | tr -d ' '; }
C55_SAMPLE="  printf ' --a %q --b %c'"
C55_CTL_ALL="$(printf '%s' "$C55_SAMPLE" | c55_pcts '%')"
C55_CTL_Q="$(printf '%s' "$C55_SAMPLE" | c55_pcts '%q')"
[ "$C55_CTL_ALL" = "2" ] && [ "$C55_CTL_Q" = "1" ] \
  && check "C55ctl the conversion count sees a %c the letter blacklist missed" PASS \
  || check "C55ctl the conversion count sees a %c the letter blacklist missed (all=$C55_CTL_ALL q=$C55_CTL_Q)" FAIL
C55_ALL="$(printf '%s\n' "$C55_BODY" | c55_pcts '%')"
C55_Q="$(printf '%s\n' "$C55_BODY" | c55_pcts '%q')"
[ "$C55_Q" = "3" ] && [ "$C55_ALL" = "$C55_Q" ] \
  && check "C55a every conversion in the renderer is a %q" PASS \
  || check "C55a every conversion in the renderer is a %q (all=$C55_ALL q=$C55_Q)" FAIL

# --- C56: the unbounded third arm is pinned, not just its rationale ------------
# C42/C42a/C42b observe only that two `command -v` probes and one doc word exist, so
# replacing the last arm with `return 0` — the alternative the comment records as
# REJECTED — left every one of them green. The arm the whole decision is about needs
# a pin of its own, in the same spirit as C44 pinning the lock-domain decision.
# Two halves, because the rejected alternative could be reinstated on either side.
# The HELPER must still RUN the command when neither binary exists — its last arm is a
# bare `"$@"`, not a `return`. The pattern accepts a `return` in command position after a
# `;` as well as at the start of a line: the first spelling anchored on `^[[:space:]]*`
# only, so the same inert arm written as a one-liner slipped past it. C56ctl proves the
# pattern can match the form it forbids, which the first spelling also lacked.
# ONE pattern, bound once and shared by the control and the assertion. Two hardcoded
# copies would let a one-sided edit leave the control green over a changed assertion —
# which is what C32_PATTERN, C33_PATTERN, C41_RE and C45_RE all exist to avoid.
# The pattern accepts `return` in EVERY command position, not only after `;` or at line
# start: `|| return 0` and `&& return 0` are the spellings the inert arm would most naturally
# take, and the first version saw neither. The control plants one of each.
C56_RE='(^|;|\|\||&&|then|\{)[[:space:]]*(else[[:space:]]+)?return[[:space:]]'
C56_CTL="$(printf '  if x; then a; else return 1; fi\n  y || return 0\n  z && return 0\n' | grep -cE "$C56_RE" || true)"
[ "$C56_CTL" = "3" ] \
  && check "C56ctl the inert-arm pattern matches every command position the form can take" PASS \
  || check "C56ctl the inert-arm pattern matches every command position the form can take (got '$C56_CTL')" FAIL
# SCOPED TO THE LADDER, not the whole helper body. The helper's own arity guard is itself a
# `|| return 1`, so a whole-body scan would either miss the inert arm — which the narrow
# pattern did — or, once widened, condemn that guard and report it AS the inert arm: a true
# failure with a false diagnosis. Slice from the first watchdog probe onward.
C56_ARMS="$(printf '%s\n' "$C42_LADDER" | awk '/command -v timeout/{f=1} f{print}')"
[ -n "$C56_ARMS" ] \
  && check "C56pre the ladder's arms were sliced out of the helper, so the scan below is not vacuous" PASS \
  || check "C56pre the ladder's arms were sliced out of the helper, so the scan below is not vacuous" FAIL
printf '%s\n' "$C56_ARMS" | grep -qE "$C56_RE" \
  && check "C56 the shared ladder still runs the command unbounded rather than the rejected inert arm" FAIL \
  || check "C56 the shared ladder still runs the command unbounded rather than the rejected inert arm" PASS
printf '%s\n' "$C42_LADDER" | grep -qE '^[[:space:]]*"\$@"' \
  && check "C56d the ladder contains a bare invocation of the caller's command" PASS \
  || check "C56d the ladder contains a bare invocation of the caller's command" FAIL
# And the CALLERS must invoke unconditionally. A caller that guarded its command on a
# watchdog being present would reinstate the same rejected behaviour one level up, with
# the helper left innocent. Both read the COMMENT-STRIPPED body, because this hook
# discusses `command -v timeout` in prose and a raw body would grade the discussion.
printf '%s\n' "$C42_CODE" | grep -qE 'zensu_run_bounded git ' \
  && check "C56a the git probe runs through the ladder unconditionally" PASS \
  || check "C56a the git probe runs through the ladder unconditionally" FAIL
printf '%s\n' "$C42_CODE" | grep -qE 'command -v (timeout|gtimeout)' \
  && check "C56b the git probe keeps no watchdog-presence guard of its own" FAIL \
  || check "C56b the git probe keeps no watchdog-presence guard of its own" PASS

# --- C60: the ladder exists ONCE in the whole hook, not once per function ------
# The consolidation's actual purchase is ONE ladder, and every other check that grades it is
# scoped to a function body — so a THIRD function spelling its own `command -v timeout` arm
# passes all of them, which is exactly the divergence the consolidation removed. Compare the
# whole-file count against the count inside the shared helper: equal means no second copy.
C60_HELPER="$(printf '%s\n' "$C42_LADDER" | grep -cE 'command -v (timeout|gtimeout)' || true)"
# Across BOTH files, because the ladder moved into its own library: the hook must carry
# none of it and the library exactly the two probes. A count scoped to one file would go
# green on a copy living in the other.
C60_HOOK="$(grep -vE '^[[:space:]]*#' "$STOP" | grep -cE 'command -v (timeout|gtimeout)' || true)"
C60_LIB="$(grep -vE '^[[:space:]]*#' "$BOUNDED_LIB" | grep -cE 'command -v (timeout|gtimeout)' || true)"
[ "$C60_HELPER" = "2" ] \
  && check "C60pre the shared helper carries exactly the two probes, so the comparison is anchored" PASS \
  || check "C60pre the shared helper carries exactly the two probes (found $C60_HELPER)" FAIL
[ "$C60_HOOK" = "0" ] && [ "$C60_LIB" = "$C60_HELPER" ] \
  && check "C60 the watchdog ladder lives only in its own library, nowhere in the hook" PASS \
  || check "C60 the watchdog ladder lives only in its own library (hook=$C60_HOOK lib=$C60_LIB helper=$C60_HELPER)" FAIL

# --- C57: the TTL constant pair is pinned too, now that one extractor can ------
# `TTL_HOURS_FALLBACK` / `TTL_HOURS_MAX` in the doctor renderer declare themselves a
# mirror of `zensu_pending_review_ttl_hours` in prose and were pinned by nothing. The
# collapse onto `_zensu_config_bounded_int` made every getter a one-line call with the
# same operand shape, so the extractor that already held the implementing-turns pair
# holds this one for the cost of two arguments. Recorded as an open gap in the same
# round it became cheap to close, which is the wrong place to leave it.
C57_CFG_DEF="$(getter_operand zensu_pending_review_ttl_hours pendingReviewTtlHours 1)"
C57_CFG_MAX="$(getter_operand zensu_pending_review_ttl_hours pendingReviewTtlHours 3)"
C57_DOC_DEF="$(sed -n 's/^var TTL_HOURS_FALLBACK = \([0-9][0-9]*\);$/\1/p' "$REPORT" | head -1)"
C57_DOC_MAX="$(sed -n 's/^var TTL_HOURS_MAX = \([0-9][0-9]*\);$/\1/p' "$REPORT" | head -1)"
if [ -n "$C57_CFG_DEF" ] && [ -n "$C57_CFG_MAX" ] && [ -n "$C57_DOC_DEF" ] && [ -n "$C57_DOC_MAX" ]; then
  check "C57pre all four TTL literals were located, so the comparison below is not vacuous" PASS
  [ "$C57_CFG_DEF" = "$C57_DOC_DEF" ] && [ "$C57_CFG_MAX" = "$C57_DOC_MAX" ] \
    && check "C57 the doctor's TTL constants match the getter's own default and bound" PASS \
    || check "C57 the doctor's TTL constants match the getter's own default and bound (cfg=$C57_CFG_DEF/$C57_CFG_MAX doctor=$C57_DOC_DEF/$C57_DOC_MAX)" FAIL
else
  check "C57pre all four TTL literals were located, so the comparison below is not vacuous (cfg=$C57_CFG_DEF/$C57_CFG_MAX doctor=$C57_DOC_DEF/$C57_DOC_MAX)" FAIL
fi

# --- C58: the shared bounded-int helper's arithmetic, for ALL THREE call sites -
# The helper's own comment claimed a characterization matrix as the thing any future
# change to it owes the three getters. That matrix was run by hand and committed
# nowhere, so the claim named evidence the suite did not carry — and only
# `implStopNudgeAfter`'s bound was exercised at all. This is that matrix, table-driven
# and in the suite, so the claim is now true and the two other call sites have their
# bound arithmetic covered rather than assumed.
c58_get() {  # $1 = getter, $2 = json config body
  printf '%s' "$2" > "$STATE_DIR/c58.json"
  bash -c 'set -u; ZENSU_CONFIG="$2"; source "$1/hooks/lib/zensu-config.sh"; "$3"' \
    _ "$PLUGIN_DIR" "$STATE_DIR/c58.json" "$1" 2>/dev/null
}
C58_FAILS=""
# The bounds are DERIVED through the same `getter_operand` C57 uses, not hand-copied:
# restating them here would turn C58 red on a legitimate bound change for a reason
# unrelated to the arithmetic it grades.
for c58row in \
  "zensu_autofix_max_rounds:autoFixMaxRounds" \
  "zensu_pending_review_ttl_hours:pendingReviewTtlHours" \
  "zensu_impl_stop_nudge_after:implStopNudgeAfter"; do
  c58fn="${c58row%%:*}"; c58key="${c58row#*:}"
  c58def="$(getter_operand "$c58fn" "$c58key" 1)"
  c58min="$(getter_operand "$c58fn" "$c58key" 2)"
  c58max="$(getter_operand "$c58fn" "$c58key" 3)"
  if [ -z "$c58def" ] || [ -z "$c58min" ] || [ -z "$c58max" ]; then
    C58_FAILS="$C58_FAILS $c58fn(operands-unreadable)"
    continue
  fi
  # at-min and at-max are ACCEPTED; one below min and one above max fall back; a
  # non-integer and a QUOTED IN-RANGE number fall back; an absent key falls back.
  #
  # The quoted case uses the MIN, never the default: quoting the default made acceptance
  # and rejection produce the same string, so replacing `Number.isInteger` with a coercing
  # `Number` left the row green. The min differs from the default in all three rows.
  for c58case in "$c58min:$c58min" "$c58max:$c58max" "$((c58min - 1)):$c58def" \
                 "$((c58max + 1)):$c58def" "1.5:$c58def" "\"$c58min\":$c58def"; do
    c58in="${c58case%%:*}"; c58want="${c58case#*:}"
    c58got="$(c58_get "$c58fn" "{\"hooks\":{\"$c58key\":$c58in}}")"
    [ "$c58got" = "$c58want" ] || C58_FAILS="$C58_FAILS $c58fn($c58in)->$c58got!=$c58want"
  done
  c58got="$(c58_get "$c58fn" '{"hooks":{}}')"
  [ "$c58got" = "$c58def" ] || C58_FAILS="$C58_FAILS $c58fn(absent)->$c58got!=$c58def"
done
# The control matters: a typo in the loop would leave C58_FAILS empty and report a green
# matrix that never ran. Require the accepted cases to have produced real values first.
# The object-shape conjunct (`typeof h === "object" && !Array.isArray(h)`) is unreachable
# through the three shipped getters, because none of their keys is one a string or an array
# owns. Drive the helper DIRECTLY with the key `length` against both shapes: with
# `hasOwnProperty` alone, `"abcdefgh".length` and `[1,2,3,4,5].length` are own integers that
# would pass the bounds and be echoed instead of the default.
c58_direct() {  # $1 = json config body
  printf '%s' "$1" > "$STATE_DIR/c58d.json"
  bash -c 'set -u; ZENSU_CONFIG="$2"; source "$1/hooks/lib/zensu-config.sh"; _zensu_config_bounded_int length 5 1 99' \
    _ "$PLUGIN_DIR" "$STATE_DIR/c58d.json" 2>/dev/null
}
C58_STR="$(c58_direct '{"hooks":"abcdefgh"}')"
# SEVEN elements, not five: with a five-element array `hooks.length` IS the default, so
# deleting `!Array.isArray(h)` produced the same answer as the guarded path and the arm
# could not fail. The string arm discriminates on its own; this one now does too.
C58_ARR="$(c58_direct '{"hooks":[1,2,3,4,5,6,7]}')"
C58_OBJ="$(c58_direct '{"hooks":{"length":7}}')"
[ "$C58_OBJ" = "7" ] \
  && check "C58cpre the direct helper call really reads a hooks key, so the two below mean something" PASS \
  || check "C58cpre the direct helper call really reads a hooks key (got '$C58_OBJ')" FAIL
[ "$C58_STR" = "5" ] && [ "$C58_ARR" = "5" ] \
  && check "C58c a string or array hooks value yields the default, never its own length" PASS \
  || check "C58c a string or array hooks value yields the default (string='$C58_STR' array='$C58_ARR')" FAIL
C58_CTL="$(c58_get zensu_impl_stop_nudge_after '{"hooks":{"implStopNudgeAfter":7}}')"
[ "$C58_CTL" = "7" ] \
  && check "C58pre the matrix harness really drives the getters, so an empty failure list means something" PASS \
  || check "C58pre the matrix harness really drives the getters (got '$C58_CTL')" FAIL
[ -z "$C58_FAILS" ] \
  && check "C58 all three bounded-int getters honour their own min, max, fallback and absent-key behaviour" PASS \
  || check "C58 all three bounded-int getters honour their own bounds (failures:$C58_FAILS)" FAIL

echo ""
echo "impl-stop-counter: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
