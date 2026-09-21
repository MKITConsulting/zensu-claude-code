#!/bin/bash
# The CLI surface of run ADOPTION — release's constructive counterpart.
#
# A durable run is owned by one session id, and Claude Code can continue a
# conversation under a new one (SessionStart source `fork`, and a resume whose
# record was pruned). Ownership does not follow, so the successor cannot see the
# run, cannot drive it, and — while the previous owner's workflow document still
# looks fresh — cannot release it either. This suite drives the verb that lets
# the session standing in the run's tree take it over instead.
#
# It drives the `zensu-log.sh` verb a model actually types, because that is where
# the `--confirm` interlock, the argument parsing, the session resolution and the
# provenance write live — none of which a function-level call reaches.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
CFG="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
EXAMPLE_CONFIG="$PLUGIN_DIR/config.example.json"
SKILL="$PLUGIN_DIR/skills/autopilot-adopt/SKILL.md"
DOC_CONFIG="$PLUGIN_DIR/docs/configuration.md"
REPO_CLAUDE="$PLUGIN_DIR/CLAUDE.md"
DOC_WORKFLOW="$PLUGIN_DIR/docs/tdd-manager-workflow.md"
SUITE_OVERVIEW="$PLUGIN_DIR/tests/SUITE-OVERVIEW.md"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

for required in "$LIB" "$LOG" "$CFG" "$CORE" "$BASELINE" "$PLUGIN_JSON"; do
  if [ ! -r "$required" ]; then
    check "B0 required artifact missing: $required" FAIL
    printf '%s\n' "----" "test-autopilot-adopt-cli: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$LIB"

TMP="$(mktemp -d -t zensu-adopt-cli-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
# An inherited repository environment would let `rev-parse -C` answer for a tree
# the fixtures never named, and a TMPDIR inside a work tree would collapse the
# sibling trees onto one workspace. Both are premises the fixtures rest on.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES GIT_OBJECT_DIRECTORY
if git -C "$TMP" rev-parse --show-toplevel >/dev/null 2>&1; then
  check "B0 the fixture root must not sit inside a git work tree" FAIL
  printf '%s\n' "----" "test-autopilot-adopt-cli: $PASS PASS / $FAIL FAIL"
  exit 1
fi
mkdir -p "$TMP/plugin-data"
ZENSU_TEST_PLUGIN_DATA="$(cd "$TMP/plugin-data" && pwd -P)"
export ZENSU_TEST_PLUGIN_DATA

# `_zensu_config_bounded_int` is `hooks.<key>`-only by construction — its node
# program spells the namespace itself — so a top-level key here would be read as
# absent and the fixture would silently measure the DEFAULT instead of zero.
printf '%s' '{"hooks":{"autopilotOwnerActivityTtlHours":0}}' > "$TMP/ttl-zero.json"

# `run_verb` pins this per command, but an IN-PROCESS `autopilot_*` call reads the
# config in the suite's own shell, where `cfg()` falls back to `$HOME/.zensu/config.json`
# — and this suite does not override HOME. A developer whose global config sets an
# owner-activity window would then decide a liveness check here, turning an unrelated
# assertion red. Export the missing-file path once so every in-process call resolves
# the DEFAULTS; a case that needs another value still sets the variable inline.
export ZENSU_CONFIG="$TMP/missing-config.json"

activate_session() {
  local project="$1" raw_session="$2"
  mkdir -p "$project" || return 1
  export CLAUDE_PROJECT_DIR="$project"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session" || return 1
}

run_verb() {
  local project="$1" raw_session="$2"; shift 2
  activate_session "$project" "$raw_session" || return 90
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$TMP/missing-config.json" \
      bash "$LOG" "$@" )
}

# Same contract, but with a REAL config file, which is the only channel that can
# move `autopilotOwnerActivityTtlHours` off its default.
run_verb_cfg() {
  local project="$1" raw_session="$2" config="$3"; shift 3
  activate_session "$project" "$raw_session" || return 90
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$config" \
      bash "$LOG" "$@" )
}

json_ok() {
  FILE="$1" EXPR="$2" node -e '
    const value = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
    process.exit(Function("value", `return Boolean(${process.env.EXPR})`)(value) ? 0 : 1);
  ' 2>/dev/null
}

digest() {
  node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

json_field() {
  FILE="$1" KEY="$2" node -e '
    try {
      const v = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
      process.stdout.write(String(v[process.env.KEY] === undefined ? "" : v[process.env.KEY]));
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

# Pre-initialised because the file runs under `set -u` and each of these is assigned
# only inside a fixture-success branch; B21 expands all of them, so a degraded
# fixture would otherwise abort the suite before its own summary line prints.
B3_RC=""; B5_RC=""; B11_RC=""; B23_RC=""
PLAN_SHA="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update("adopt-plan").digest("hex"))')"

# --- Fixture: an owner holds a run; a second session is the adopter ----------
PROJECT="$TMP/project"; mkdir -p "$PROJECT"
PROJECT="$(cd "$PROJECT" && pwd -P)"
activate_session "$PROJECT" adopt_cli_owner || exit 1
OWNER_KEY="$ZENSU_SESSION_KEY"
autopilot_begin_run adopt_cli_run "$OWNER_KEY" "$PROJECT" >/dev/null 2>&1 \
  || { check "B0 fixture run could not be started" FAIL; exit 1; }
RUN_FILE="$(autopilot_run_file adopt_cli_run "$PROJECT")"
STATE_DIR="$PROJECT/.zensu/state"
OWNER_POINTER="$(_autopilot_active_path "$STATE_DIR" "$OWNER_KEY")"

if [ -f "$OWNER_POINTER" ]; then
  check "B0 fixture premise: the owner holds an active pointer to the run" PASS
else
  check "B0 fixture premise: owner pointer missing at $OWNER_POINTER" FAIL
fi

# --- B1 without --confirm the verb REPORTS and writes nothing (AC-011) -------
# The absence of `--confirm` used to be an INVOCATION fault: exit 2, one usage line,
# and no fact about the run at all. So the user was asked for a yes while the whole
# liveness question — whether the check will run, how old the owner's document is,
# whether a retired pointer stands it down — stayed invisible until the command that
# already moved ownership printed it. This arm is the live-owner half: the report
# runs the same ladder, reaches the same exit 7, and moves nothing.
#
# The taker's session is activated HERE rather than inside `run_verb` alone, because
# `activate_session` writes that session's own workflow document into the state
# directory: sampling the directory before that write would report the seed as a
# mutation this call made.
activate_session "$PROJECT" adopt_cli_taker || exit 1
B1_TAKER_KEY="$ZENSU_SESSION_KEY"
B1_TAKER_POINTER="$(_autopilot_active_path "$STATE_DIR" "$B1_TAKER_KEY")"
# Filtered to the `autopilot-` entries on purpose: the lease keeper and the session
# seed both touch this directory, so a bare listing would grade unrelated writes.
# The two report-mode output operands are named `autopilot-adopt-report-*`, so a
# regression that reaches a write lands INSIDE this filter rather than beside it.
B1_AP_BEFORE="$(ls -A "$STATE_DIR" | grep '^autopilot-' | sort | tr '\n' ' ')"
BEFORE_B1="$(digest "$RUN_FILE")"
BEFORE_B1_PTR="$(digest "$OWNER_POINTER")"
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --run adopt_cli_run \
  >"$TMP/b1.out" 2>"$TMP/b1.err"
B1_RC=$?
B1_AP_AFTER="$(ls -A "$STATE_DIR" | grep '^autopilot-' | sort | tr '\n' ' ')"
# The stderr sentence is graded here and nowhere else: a grep over `tests/`, `skills/`
# and `docs/` for the retired blanket spelling `report only, nothing was changed`
# returned NOTHING, so this arm is the only thing standing between that claim and a
# silent reword. It must name the ENUMERATED set the skill states at its own
# "changes nothing" sentence, because the blanket form asserts more than the report's
# guards establish: the verb DOES take the project lease (`_autopilot_locked_run`), so
# "nothing was changed" is false about the process even though it is true about the
# three artifacts. The lease's own lock file is created and unlinked by
# `releaseOwnedLock` in `session-control-core-v1.js`, so the artifact does not persist
# — but a sentence that has to be defended by tracing two modules is the wrong
# sentence to print at a user.
if [ "$B1_RC" -eq 7 ] \
  && grep -qF 'report: run adopt_cli_run was not changed by this call' "$TMP/b1.out" \
  && grep -qF 'no record, no pointer and no provenance entry is written' "$TMP/b1.out" \
  && grep -qF 'report: owner liveness' "$TMP/b1.out" \
  && grep -qF 'so adoption is refused' "$TMP/b1.out" \
  && ! grep -qF -- '--confirm would take run' "$TMP/b1.out" \
  && grep -qF 'no record, no pointer, no provenance entry' "$TMP/b1.err" \
  && ! grep -qF 'nothing was changed' "$TMP/b1.err" \
  && [ "$(digest "$RUN_FILE")" = "$BEFORE_B1" ] \
  && [ "$(digest "$OWNER_POINTER")" = "$BEFORE_B1_PTR" ] \
  && [ ! -e "$B1_TAKER_POINTER" ] \
  && [ "$B1_AP_AFTER" = "$B1_AP_BEFORE" ]; then
  check "B1 adopt without --confirm reports the liveness verdict, takes the same exit 7, and writes nothing" PASS
else
  check "B1 adopt report (rc=$B1_RC, stdout: $(head -c 200 "$TMP/b1.out" 2>/dev/null))" FAIL
fi

# --- B1b the PERMIT half of the same report (AC-011) -------------------------
# B1 alone proves nothing about the report's exit code: a verb that answered 7 for
# every input passes it. This arm reaches the takeover verdict, so it grades the one
# claim the user acts on — "--confirm would adopt this" — and then CONFIRMS it in the
# same fixture, which is what shows the report left the ladder it predicted intact.
# Its own project, because a report that lied by mutating would be invisible against
# a fixture another case has already moved.
B1BP="$TMP/reportstale"; mkdir -p "$B1BP"
B1BP="$(cd "$B1BP" && pwd -P)"
if activate_session "$B1BP" adopt_report_owner \
  && autopilot_begin_run adopt_report_run "$ZENSU_SESSION_KEY" "$B1BP" >/dev/null 2>&1; then
  B1B_OWNER="$ZENSU_SESSION_KEY"
  B1B_RUN_FILE="$(autopilot_run_file adopt_report_run "$B1BP")"
  B1B_POINTER="$(_autopilot_active_path "$B1BP/.zensu/state" "$B1B_OWNER")"
  B1B_BEACON="$B1BP/.zensu/state/tdd-phase-${B1B_OWNER}.json"
  printf '%s\n' '{}' > "$B1B_BEACON"
  touch -t 200001010000 "$B1B_BEACON" 2>/dev/null
  B1B_RUN_DIGEST="$(digest "$B1B_RUN_FILE")"
  B1B_PTR_DIGEST="$(digest "$B1B_POINTER")"
  if [ -f "$B1B_POINTER" ] && [ "$B1B_BEACON" -ot "$B1B_RUN_FILE" ]; then
    activate_session "$B1BP" adopt_report_taker || exit 1
    B1B_TAKER="$ZENSU_SESSION_KEY"
    B1B_TAKER_POINTER="$(_autopilot_active_path "$B1BP/.zensu/state" "$B1B_TAKER")"
    run_verb "$B1BP" adopt_report_taker --autopilot-adopt --run adopt_report_run \
      >"$TMP/b1b.out" 2>"$TMP/b1b.err"
    B1B_RC=$?
    # Sampled HERE, between the two commands: the confirmed adopt below legitimately
    # rewrites the record, retires the owner pointer and installs the taker's, so the
    # same three tests taken after it grade the takeover instead of the report.
    B1B_UNCHANGED=true
    [ "$(digest "$B1B_RUN_FILE")" = "$B1B_RUN_DIGEST" ] || B1B_UNCHANGED=false
    [ "$(digest "$B1B_POINTER")" = "$B1B_PTR_DIGEST" ] || B1B_UNCHANGED=false
    [ ! -e "$B1B_TAKER_POINTER" ] || B1B_UNCHANGED=false
    run_verb "$B1BP" adopt_report_taker --autopilot-adopt --run adopt_report_run --confirm \
      >/dev/null 2>"$TMP/b1b-confirm.err"
    B1B_CONFIRM_RC=$?
    if [ "$B1B_RC" -eq 0 ] \
      && grep -qF "report: --confirm would take run adopt_report_run over from session $B1B_OWNER" "$TMP/b1b.out" \
      && grep -qF 'so the age check permits adoption' "$TMP/b1b.out" \
      && [ "$B1B_UNCHANGED" = true ] \
      && [ "$B1B_CONFIRM_RC" -eq 0 ] \
      && json_ok "$B1B_RUN_FILE" "value.ownerSessionId === '$B1B_TAKER'"; then
      check "B1b the report predicts a takeover, changes nothing, and the same command with --confirm then delivers it" PASS
    else
      check "B1b adopt report permit (rc=$B1B_RC, unchanged=$B1B_UNCHANGED, confirm rc=$B1B_CONFIRM_RC, stdout: $(head -c 200 "$TMP/b1b.out" 2>/dev/null | tr '\n' ' '))" FAIL
    fi
  else
    check "B1b fixture could not backdate the owner beacon while keeping its pointer" FAIL
  fi
else
  check "B1b fixture could not build a stale-owner run" FAIL
fi

# --- B1c an unrecognized mode is REFUSED, never read as the mutating one ------
# `_autopilot_adopt_critical` tests `mode = report` and treats everything else as a
# confirmed run, so a misspelt mode reaching it would move ownership. The public
# verb refuses first. Its own project at `autopilotOwnerActivityTtlHours: 0`, because
# against a live owner a regressed guard would still stop at exit 7 and pass for the
# wrong reason; with the check disabled the regression is a real takeover, and the
# `report` control on the same fixture proves that path is otherwise reachable.
B1CP="$TMP/reportmode"; mkdir -p "$B1CP"
B1CP="$(cd "$B1CP" && pwd -P)"
if activate_session "$B1CP" adopt_mode_owner \
  && autopilot_begin_run adopt_mode_run "$ZENSU_SESSION_KEY" "$B1CP" >/dev/null 2>&1; then
  B1C_OWNER="$ZENSU_SESSION_KEY"
  B1C_RUN_FILE="$(autopilot_run_file adopt_mode_run "$B1CP")"
  activate_session "$B1CP" adopt_mode_taker || exit 1
  B1C_TAKER="$ZENSU_SESSION_KEY"
  B1C_TAKER_POINTER="$(_autopilot_active_path "$B1CP/.zensu/state" "$B1C_TAKER")"
  ( cd "$B1CP" && ZENSU_CONFIG="$TMP/ttl-zero.json" \
      autopilot_adopt_run adopt_mode_run "$B1CP" "$B1C_TAKER" reprot ) >/dev/null 2>"$TMP/b1c.err"
  B1C_RC=$?
  ( cd "$B1CP" && ZENSU_CONFIG="$TMP/ttl-zero.json" \
      autopilot_adopt_run adopt_mode_run "$B1CP" "$B1C_TAKER" report ) >"$TMP/b1c-report.out" 2>/dev/null
  B1C_REPORT_RC=$?
  if [ "$B1C_RC" -eq 3 ] \
    && grep -qF 'the adoption mode is neither confirm nor report' "$TMP/b1c.err" \
    && [ "$B1C_REPORT_RC" -eq 0 ] \
    && grep -qF 'unchecked, because hooks.autopilotOwnerActivityTtlHours is 0' "$TMP/b1c-report.out" \
    && json_ok "$B1C_RUN_FILE" "value.ownerSessionId === '$B1C_OWNER'" \
    && [ ! -e "$B1C_TAKER_POINTER" ]; then
    check "B1c a misspelt adoption mode is refused with exit 3 while the report path on the same fixture stays reachable and nothing moves" PASS
  else
    check "B1c adoption mode guard (rc=$B1C_RC, report rc=$B1C_REPORT_RC, stderr: $(head -c 160 "$TMP/b1c.err" 2>/dev/null))" FAIL
  fi
else
  check "B1c fixture could not build a run for the mode guard" FAIL
fi

# --- B2 the argument parser rejects every malformed spelling -----------------
B2_OK=true
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --confirm >/dev/null 2>&1
B2_RC=$?
[ "$B2_RC" -eq 2 ] || B2_OK=false
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --run adopt_cli_run --confirm --confirm >/dev/null 2>&1
[ "$?" -eq 2 ] || B2_OK=false
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --run a --run b --confirm >/dev/null 2>&1
[ "$?" -eq 2 ] || B2_OK=false
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --run adopt_cli_run --confirm --wat >/dev/null 2>&1
[ "$?" -eq 2 ] || B2_OK=false
if [ "$B2_OK" = true ] && [ "$(digest "$RUN_FILE")" = "$BEFORE_B1" ]; then
  check "B2 malformed adopt spellings are refused and mutate nothing" PASS
else
  check "B2 malformed adopt spellings" FAIL
fi

# --- B3 a caller outside the run's tree is refused, exit 6 (AC-002) ----------
# `mayHoldWorkspace` is CONTAINMENT in both directions, so this needs two trees
# where neither contains the other: SIBLING git worktrees under one project. A
# plain sibling directory would not reach the check at all — the run record's
# `projectRoot` would already mismatch and the worker would fail(2) above it,
# which is a different refusal about a different thing.
SIBP="$TMP/siblings"; mkdir -p "$SIBP"
SIBP="$(cd "$SIBP" && pwd -P)"
( cd "$SIBP" && git init -q . && git -c user.email=a@b -c user.name=t commit -q --allow-empty -m base ) >/dev/null 2>&1
WT_A="$SIBP/wt-a"; WT_B="$SIBP/wt-b"
( cd "$SIBP" && git worktree add -q -b adopt-wt-a "$WT_A" && git worktree add -q -b adopt-wt-b "$WT_B" ) >/dev/null 2>&1
if ! command -v git >/dev/null 2>&1 || [ ! -d "$WT_A" ] || [ ! -d "$WT_B" ]; then
  check "B3 containment fixture needs git and two usable worktrees — environment, not product" FAIL
else
  activate_session "$SIBP" adopt_sib_owner || exit 1
  SIB_OWNER="$ZENSU_SESSION_KEY"
  # The run declares wt-a; the adopt is driven from wt-b. Neither tree contains
  # the other, so the run does not hold the caller's workspace.
  if autopilot_begin_run adopt_sib_run "$SIB_OWNER" "$SIBP" false true "$WT_A" >/dev/null 2>&1; then
    rm -f "$(_autopilot_active_path "$SIBP/.zensu/state" "$SIB_OWNER")"
    SIB_RUN_FILE="$(autopilot_run_file adopt_sib_run "$SIBP")"
    BEFORE_B3="$(digest "$SIB_RUN_FILE")"
    activate_session "$SIBP" adopt_sib_taker || exit 1
    SIB_TAKER="$ZENSU_SESSION_KEY"
    B3_RC=0
    ( cd "$WT_B" && CLAUDE_PROJECT_DIR="$SIBP" ZENSU_CONFIG="$TMP/missing-config.json" \
        bash "$LOG" --autopilot-adopt --run adopt_sib_run --confirm ) >/dev/null 2>"$TMP/b3.err"
    B3_RC=$?
    # The no-mutation half must be captured HERE: the anti-vacuity control below
    # adopts the run, so a comparison after it would grade the control's write.
    B3_UNCHANGED=no
    [ "$(digest "$SIB_RUN_FILE")" = "$BEFORE_B3" ] && B3_UNCHANGED=yes
    # Anti-vacuity: from wt-a the SAME call by the SAME session must land, or B3
    # would pass for any reason at all — a broken fixture included. Re-activating a
    # different session here would vary the caller AND the tree, so the pair would
    # no longer isolate the workspace axis this check is named for.
    ( cd "$WT_A" && CLAUDE_PROJECT_DIR="$SIBP" ZENSU_CONFIG="$TMP/missing-config.json" \
        bash "$LOG" --autopilot-adopt --run adopt_sib_run --confirm ) >/dev/null 2>&1
    B3_CONTROL_RC=$?
    if [ "$B3_RC" -eq 6 ] && [ "$B3_UNCHANGED" = yes ] \
      && grep -qF "run does not hold the caller's working tree" "$TMP/b3.err" \
      && [ "$B3_CONTROL_RC" -eq 0 ] \
      && json_ok "$SIB_RUN_FILE" "value.ownerSessionId === '$SIB_TAKER'"; then
      check "B3 adopt is refused with exit 6 from a sibling worktree and lands from the held one" PASS
    else
      check "B3 workspace scope (sibling rc=$B3_RC expected 6, held rc=$B3_CONTROL_RC expected 0)" FAIL
    fi
  else
    check "B3 fixture could not begin a run declaring a nested worktree" FAIL
  fi
fi

# --- B4 the owner adopting its own run is an idempotent no-op (AC-003) -------
# AC-003 is worded against the WORKER's exit 10; no shipped surface returns it,
# because `_autopilot_adopt_critical` collapses it to 0 and the CLI exits that.
# B4b below pins the worker's own code, so this check grades the delivered contract
# instead: exit 0, nothing mutated, and — the half that was missing — the stderr
# line that tells this outcome apart from a real takeover. Discarding stderr here
# is what let the silent no-op ship while the skill promised it would be named.
BEFORE_B4="$(digest "$RUN_FILE")"
run_verb "$PROJECT" adopt_cli_owner --autopilot-adopt --run adopt_cli_run --confirm >/dev/null 2>"$TMP/b4.err"
B4_RC=$?
if [ "$B4_RC" -eq 0 ] && [ "$(digest "$RUN_FILE")" = "$BEFORE_B4" ] \
  && grep -qF 'already owns run adopt_cli_run and its owner pointer already designates it' "$TMP/b4.err" \
  && ! grep -qF 'was taken over from' "$TMP/b4.err"; then
  check "B4 the owner self-adopt is a no-op, exits 0, and names that outcome on stderr" PASS
else
  check "B4 owner self-adopt (rc=$B4_RC, stderr: $(head -c 160 "$TMP/b4.err" 2>/dev/null))" FAIL
fi

# --- B6 a live-looking owner is refused, exit 7 (AC-005) ---------------------
# `activate_session` above wrote the owner's workflow document moments ago and
# its pointer still designates the run, so this is the ordinary healthy state.
# It runs BEFORE the successful adopt, because that one retires the pointer.
BEFORE_B6="$(digest "$RUN_FILE")"
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --run adopt_cli_run --confirm >/dev/null 2>&1
B6_RC=$?
if [ "$B6_RC" -eq 7 ] && [ "$(digest "$RUN_FILE")" = "$BEFORE_B6" ]; then
  check "B6 adopt is refused with exit 7 while the owner still looks active" PASS
else
  check "B6 live owner refusal (rc=$B6_RC, expected 7)" FAIL
fi

# --- B6b the PERMIT case for the same age arithmetic (AC-005 control) -------
# B6 alone proves nothing about the clock: replace the whole `ownerActivity` block
# with an unconditional `fail(7, ...)` and B6 still passes, because every OTHER
# adopt this suite expects to succeed reaches the takeover with the owner pointer
# already deleted (B3, B7 and B17 unlink it; B12b runs at ttl 0; B4/B4b/B19/B24
# return from the already-owner branch before the guard). So the `isFile` and the
# `ageMs < ttlHours * 3600000` conditions were both deletable with the suite green.
# This case is B6's twin and differs from it in ONE thing — the beacon's mtime — so
# the pair is what makes THOSE two load-bearing. It mirrors W23 in
# test-autopilot-state-machine.sh, which carries the same control for the sibling
# verb and states the same reason.
#
# It does NOT cover `ageMs >= 0`, and an earlier version of this comment claimed it
# did. Both B6 and B6b use a beacon in the PAST, so both ages are positive and
# deleting that clause changes neither verdict. B6c is the arm that grades it.
B6BP="$TMP/staleowner"; mkdir -p "$B6BP"
B6BP="$(cd "$B6BP" && pwd -P)"
if activate_session "$B6BP" adopt_stale_owner \
  && autopilot_begin_run adopt_stale_run "$ZENSU_SESSION_KEY" "$B6BP" >/dev/null 2>&1; then
  B6B_OWNER="$ZENSU_SESSION_KEY"
  B6B_RUN_FILE="$(autopilot_run_file adopt_stale_run "$B6BP")"
  B6B_POINTER="$(_autopilot_active_path "$B6BP/.zensu/state" "$B6B_OWNER")"
  B6B_BEACON="$B6BP/.zensu/state/tdd-phase-${B6B_OWNER}.json"
  printf '%s\n' '{}' > "$B6B_BEACON"
  # The ONE difference from B6. `touch -t` is what the sibling control uses; if the
  # platform refuses it the case reports rather than passing on an untested premise.
  touch -t 200001010000 "$B6B_BEACON" 2>/dev/null
  if [ -f "$B6B_POINTER" ] && [ "$B6B_BEACON" -ot "$B6B_RUN_FILE" ]; then
    run_verb "$B6BP" adopt_stale_taker --autopilot-adopt --run adopt_stale_run --confirm \
      >/dev/null 2>"$TMP/b6b.err"
    B6B_RC=$?
    B6B_TAKER="$ZENSU_SESSION_KEY"
    if [ "$B6B_RC" -eq 0 ] \
      && json_ok "$B6B_RUN_FILE" "value.ownerSessionId === '$B6B_TAKER'" \
      && grep -qF 'was taken over from' "$TMP/b6b.err"; then
      check "B6b a stale owner beacon PERMITS the adopt with the pointer still in place" PASS
    else
      check "B6b stale-owner permit (rc=$B6B_RC, stderr: $(head -c 160 "$TMP/b6b.err" 2>/dev/null))" FAIL
    fi
  else
    check "B6b fixture could not backdate the owner beacon while keeping its pointer" FAIL
  fi
else
  check "B6b fixture could not build a stale-owner run" FAIL
fi

# --- B6c a FUTURE-dated owner beacon REFUSES the adopt ----------------------
# The discriminating case for the age sign, which B6 and B6b cannot see: both use a past
# mtime, so both ages are positive and the future arm is deletable against them.
# Adoption used to PERMIT here and only disclose, and the release refusal for the same
# input then recommended adoption as its route — so two confirmations cancelled a run
# whose owner is demonstrably live, which is the outcome that refusal exists to prevent.
# Both verbs now refuse a future stamp while the previous owner's pointer designates the
# run; a RETIRED pointer still stands the whole check down one branch above this one.
B6CP="$TMP/futureowner"; mkdir -p "$B6CP"
B6CP="$(cd "$B6CP" && pwd -P)"
if activate_session "$B6CP" adopt_future_owner \
  && autopilot_begin_run adopt_future_run "$ZENSU_SESSION_KEY" "$B6CP" >/dev/null 2>&1; then
  B6C_OWNER="$ZENSU_SESSION_KEY"
  B6C_RUN_FILE="$(autopilot_run_file adopt_future_run "$B6CP")"
  B6C_POINTER="$(_autopilot_active_path "$B6CP/.zensu/state" "$B6C_OWNER")"
  B6C_BEACON="$B6CP/.zensu/state/tdd-phase-${B6C_OWNER}.json"
  printf '%s\n' '{}' > "$B6C_BEACON"
  # Far enough ahead that no plausible clock skew between this line and the verb can
  # bring it back into the past. Reported rather than skipped if the platform refuses.
  touch -t 209901010000 "$B6C_BEACON" 2>/dev/null
  if [ -f "$B6C_POINTER" ] && [ "$B6C_BEACON" -nt "$B6C_RUN_FILE" ]; then
    run_verb "$B6CP" adopt_future_taker --autopilot-adopt --run adopt_future_run --confirm \
      >/dev/null 2>"$TMP/b6c.err"
    B6C_RC=$?
    if [ "$B6C_RC" -eq 7 ] \
      && json_ok "$B6C_RUN_FILE" "value.ownerSessionId === '$B6C_OWNER'" \
      && [ -f "$B6C_POINTER" ] \
      && grep -qF 'dated in the future, so its age cannot show that the owner has stopped' "$TMP/b6c.err" \
      && ! grep -qF 'owner liveness unchecked: the recorded owner workflow document is dated in the future' "$TMP/b6c.err"; then
      check "B6c a future-dated owner beacon REFUSES the adopt with exit 7 and moves nothing" PASS
    else
      check "B6c future-beacon refusal (rc=$B6C_RC, stderr: $(head -c 200 "$TMP/b6c.err" 2>/dev/null))" FAIL
    fi
  else
    check "B6c fixture could not forward-date the owner beacon while keeping its pointer" FAIL
  fi
else
  check "B6c fixture could not build a future-beacon run" FAIL
fi

# --- B5 a live inner TDD chain is refused, exit 3 (AC-004) -------------------
# Its own run and its own tree, because reaching TDD_RUNNING is a one-way trip
# and the main fixture is still needed at PLANNING.
TDDP="$TMP/tddrun"; mkdir -p "$TDDP"
TDDP="$(cd "$TDDP" && pwd -P)"
activate_session "$TDDP" adopt_tdd_owner || exit 1
TDD_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_tdd_run "$TDD_OWNER" "$TDDP" >/dev/null 2>&1 \
  && autopilot_apply_event adopt_tdd_run evt-plan PLAN_APPROVED \
    "{\"approvedPlanSha256\":\"$PLAN_SHA\"}" "$TDDP" >/dev/null 2>&1 \
  && autopilot_apply_event adopt_tdd_run evt-tdd TDD_STARTED \
    '{"attempt":1,"chainId":"adopt-chain-001","sessionId":"adopt-session-001"}' \
    "$TDDP" >/dev/null 2>&1; then
  TDD_RUN_FILE="$(autopilot_run_file adopt_tdd_run "$TDDP")"
  rm -f "$(_autopilot_active_path "$TDDP/.zensu/state" "$TDD_OWNER")"
  if json_ok "$TDD_RUN_FILE" 'value.stage === "TDD_RUNNING"'; then
    BEFORE_B5="$(digest "$TDD_RUN_FILE")"
    run_verb "$TDDP" adopt_tdd_taker --autopilot-adopt --run adopt_tdd_run --confirm \
      >/dev/null 2>"$TMP/b5.err"
    B5_RC=$?
    # Exit 3 is shared by three refusals (invalid arguments, terminal run, live inner
    # chain), so the code alone would be satisfied by an argument-marshalling regression.
    # The refusal must name the exits that REMAIN. It used to say "finish or block that
    # chain before adopting", and blocking changes nothing here: this verb tests the
    # PENDING stage, which a BLOCK out of TDD_RUNNING preserves — B18 drives exactly that
    # record and gets the same exit 3. Advising it sent the reader to an action that
    # cannot clear the refusal.
    if [ "$B5_RC" -eq 3 ] && [ "$(digest "$TDD_RUN_FILE")" = "$BEFORE_B5" ] \
      && grep -qF 'live inner TDD chain' "$TMP/b5.err" \
      && grep -qF 'blocking that chain does not make the run adoptable' "$TMP/b5.err" \
      && grep -qF '/zensu:autopilot-release' "$TMP/b5.err" \
      && ! grep -qF 'finish or block that chain before adopting' "$TMP/b5.err"; then
      check "B5 a run with a live inner TDD chain is refused with exit 3" PASS
    else
      check "B5 TDD_RUNNING refusal (rc=$B5_RC, expected 3)" FAIL
    fi
  else
    check "B5 fixture could not reach stage TDD_RUNNING" FAIL
  fi
else
  check "B5 fixture could not build a TDD_RUNNING run" FAIL
fi

# --- B7 a retired owner pointer is abandonment evidence; the adopt lands -----
# (AC-006) The pointer branch owes nothing to a clock: with it gone the previous
# owner's own read-active returns nothing, so it is not driving this run.
rm -f "$OWNER_POINTER"
# Captured BEFORE the adopt: B7b compares the event count against what the record
# actually carried, and B10b compares the taker's FSM cursor against its own prior
# value rather than against a literal that also holds for an absent field.
EVENTS_BEFORE_B7="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).events.length))' "$RUN_FILE" 2>/dev/null)"
activate_session "$PROJECT" adopt_cli_taker || exit 1
TAKER_RAW_FOR_LIB=adopt_cli_taker
TAKER_DOC_PRE="$STATE_DIR/tdd-phase-${ZENSU_SESSION_KEY}.json"
# A REAL cursor is written first. The SessionStart seed is `phase: UNINITIALIZED`
# with an empty `step_id`, and `json_field` returns the empty string for an absent
# key too — so grading the seed would compare "" with "" on one arm and would not
# be the "running chain" the property is about.
( export CLAUDE_PROJECT_DIR="$PROJECT"
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" 2>/dev/null
  tdd_write_phase "$TAKER_RAW_FOR_LIB" b10b-step IMPL "" ) >/dev/null 2>&1
TAKER_PHASE_BEFORE="$(json_field "$TAKER_DOC_PRE" phase)"
TAKER_STEP_BEFORE="$(json_field "$TAKER_DOC_PRE" step_id)"
run_verb "$PROJECT" adopt_cli_taker --autopilot-adopt --run adopt_cli_run --confirm >/dev/null 2>&1
B7_RC=$?
TAKER_KEY="$ZENSU_SESSION_KEY"
TAKER_POINTER="$(_autopilot_active_path "$STATE_DIR" "$TAKER_KEY")"
# Sampled HERE, immediately after the adopt: B9/B9b below write real phases, so a
# comparison taken at B10b would grade those writes instead of this one.
TAKER_PHASE_AFTER="$(json_field "$STATE_DIR/tdd-phase-${TAKER_KEY}.json" phase)"
TAKER_STEP_AFTER="$(json_field "$STATE_DIR/tdd-phase-${TAKER_KEY}.json" step_id)"
if [ "$B7_RC" -eq 0 ] \
  && json_ok "$RUN_FILE" "value.ownerSessionId === '$TAKER_KEY'" \
  && [ -f "$TAKER_POINTER" ] \
  && [ ! -f "$OWNER_POINTER" ]; then
  check "B7 adopt rewrites ownerSessionId and writes the caller's pointer" PASS
else
  check "B7 successful adopt (rc=$B7_RC)" FAIL
fi

# --- B7b the record carries NO new key and NO new event (AC-006) -------------
# `STATE_KEYS` and `EVENT_TYPES` are strict sets and `readRunInventory` fails the
# FIRST invalid record, so a member added here would fail the whole project
# closed for every installation that predates this change.
# The key list is DERIVED from the module's `STATE_KEYS` rather than hand-copied, so
# it grades the record against the shipped set instead of a stale copy. The one
# member NOT derived is `workspaceRoot`: the module spells `STATE_KEYS_WORKSPACE` as
# a spread plus that literal, so it is appended here by hand and a SECOND member
# added there would make this list short. The event count is the one captured before
# the adopt rather than a literal.
B7B_KEYS="$(node -e '
  const src = require("fs").readFileSync(process.argv[1], "utf8");
  const m = src.match(/const STATE_KEYS = \[([\s\S]*?)\];/);
  if (!m) process.exit(3);
  const keys = m[1].match(/"[^"]+"/g).map(k => k.slice(1, -1));
  keys.push("workspaceRoot");
  process.stdout.write(JSON.stringify(keys));
' "$LIB" 2>/dev/null)"
# The derived list cannot fail when a key is added to BOTH sides, so a HARDCODED
# anchor sits beside it — deliberately independent of the module under test, the
# same reason `git-repo-escape.test.js` keeps its own membership list. The old
# `eventType !== "ADOPT"` conjunct is gone: "ADOPT" is not in EVENT_TYPES, so
# `stateValid` would refuse such a record before it could ever be written, and the
# no-new-event property is carried by the events.length clause alone.
B7B_ANCHOR='["schemaVersion","runId","projectRoot","ownerSessionId","stage","nextActionCode","approvedPlanSha256","options","tdd","effects","evidence","blocked","bypasses","stopBudget","events","workspaceRoot"]'
if [ -n "$B7B_KEYS" ] \
  && json_ok "$RUN_FILE" "Object.keys(value).every(k => $B7B_ANCHOR.includes(k))" \
  && json_ok "$RUN_FILE" "value.events.length === $EVENTS_BEFORE_B7" \
  && json_ok "$RUN_FILE" "Object.keys(value).every(k => $B7B_KEYS.includes(k))" \
  && json_ok "$RUN_FILE" "$B7B_KEYS.filter(k => k !== 'workspaceRoot').every(k => Object.prototype.hasOwnProperty.call(value, k))"; then
  check "B7b the adopted record gains no event and no key outside the module's own strict sets" PASS
else
  check "B7b the adopted record grew a key, lost one, or gained an event (keys=${B7B_KEYS:0:40})" FAIL
fi

# --- B8 the run follows its new owner and leaves the old one (AC-007) --------
# `-ne 0` was satisfied by an unresolvable project root (2), a rejected session id
# (3) and by `_autopilot_read_storage_ready` (1/2) just as readily as by the
# intended verdict, so the specific code is asserted instead. 1 is what the worker
# returns via `fail(1, "state file absent: ...")` once the pointer is gone.
B8_NEW="$(autopilot_read_active "$PROJECT" "$TAKER_KEY" 2>/dev/null)"
autopilot_read_active "$PROJECT" "$OWNER_KEY" >/dev/null 2>&1
B8_OLD_RC=$?
if printf '%s' "$B8_NEW" | grep -q "adopt_cli_run" && [ "$B8_OLD_RC" -eq 1 ]; then
  check "B8 read-active finds the run for the new owner and not for the old one" PASS
else
  check "B8 read-active after adoption (new='$B8_NEW' old_rc=$B8_OLD_RC)" FAIL
fi

# --- B9 the reserved phase cannot be minted by a caller (AC-008) -------------
# Exit 2 alone would be satisfied by two unrelated `--phase` refusals, so each arm
# greps the literal that names THIS guard, matching how the sibling reserved phase is
# pinned in test-versioned-plugin-upgrade.sh.
B9_OK=true
run_verb "$PROJECT" adopt_cli_taker --phase AUTOPILOT_ADOPTED --step s1 >/dev/null 2>"$TMP/b9a.err"
[ "$?" -eq 2 ] || B9_OK=false
grep -qF 'AUTOPILOT_ADOPTED is written only by --autopilot-adopt' "$TMP/b9a.err" || B9_OK=false
run_verb "$PROJECT" adopt_cli_taker --phase IMPL --step s1 --reason "autopilot-adopted: forged" >/dev/null 2>"$TMP/b9b.err"
[ "$?" -eq 2 ] || B9_OK=false
grep -qF "an 'autopilot-adopted: ' reason is reserved for --autopilot-adopt" "$TMP/b9b.err" || B9_OK=false
# The CLI guards are case-folded too, and until this arm existed nothing drove them
# with anything but the exact spelling — so both `zensu-log.sh` comparisons could be
# reverted to exact matches with the whole suite green. B9b covers only the library.
run_verb "$PROJECT" adopt_cli_taker --phase Autopilot_Adopted --step s1 >/dev/null 2>"$TMP/b9c.err"
[ "$?" -eq 2 ] || B9_OK=false
grep -qF 'AUTOPILOT_ADOPTED is written only by --autopilot-adopt' "$TMP/b9c.err" || B9_OK=false
run_verb "$PROJECT" adopt_cli_taker --phase IMPL --step s1 --reason "Autopilot-Adopted: forged" >/dev/null 2>"$TMP/b9d.err"
[ "$?" -eq 2 ] || B9_OK=false
grep -qF "an 'autopilot-adopted: ' reason is reserved for --autopilot-adopt" "$TMP/b9d.err" || B9_OK=false
if [ "$B9_OK" = true ]; then
  check "B9 --phase refuses AUTOPILOT_ADOPTED and its reserved reason prefix, in any case, each by its own message" PASS
else
  check "B9 the reserved phase is mintable by a caller, or refuses without naming itself" FAIL
fi

# --- B9b the LIBRARY guards refuse too, which the CLI arm cannot reach -------
# `zensu-log.sh` refuses first, so `tdd_write_phase`'s own returns have no executed
# case through B9. Drive them directly, with a control that an ordinary phase lands.
B9B_OK=true
( set +e
  export CLAUDE_PROJECT_DIR="$PROJECT"
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" 2>/dev/null
  # Control first: an ORDINARY phase must LAND with this same session argument, or
  # the two refusals below would pass for an unresolvable session rather than for
  # the guards they name.
  tdd_write_phase "$TAKER_RAW_FOR_LIB" s1 IMPL "" >/dev/null 2>&1 || exit 1
  tdd_write_phase "$TAKER_RAW_FOR_LIB" s1 AUTOPILOT_ADOPTED "" >/dev/null 2>&1 && exit 1
  tdd_write_phase "$TAKER_RAW_FOR_LIB" s1 IMPL "autopilot-adopted: forged" >/dev/null 2>&1 && exit 1
  # The THIRD guard site: `tdd_write_phase` returns above it, so it has no executed
  # case through the two calls above. CLAUDE.md counts three sites; drive the last.
  B9B_STATE="$(tdd_state_file "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" 2>/dev/null)" || exit 1
  [ -n "$B9B_STATE" ] || exit 1
  # Its OWN control, at its OWN layer. The control above grades `tdd_write_phase`;
  # these arms hand-build a six-argument call into a different function, whose
  # guards are its FIRST statements — so a bad argument vector, or a
  # `_tdd_bound_project_root` fault, is indistinguishable from a guard return and
  # both refusals below would pass for a reason they do not name.
  _tdd_write_phase_critical "$B9B_STATE" "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" s1 IMPL "" "" >/dev/null 2>&1 || exit 1
  _tdd_write_phase_critical "$B9B_STATE" "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" s1 AUTOPILOT_ADOPTED "" "" >/dev/null 2>&1 && exit 1
  _tdd_write_phase_critical "$B9B_STATE" "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" s1 IMPL "autopilot-adopted: forged" "" >/dev/null 2>&1 && exit 1
  # Case-folded now, at both layers: the phase is lower-cased downstream, so an
  # exact comparison let a mixed-case spelling mint a document a reader cannot tell
  # from real provenance.
  tdd_write_phase "$TAKER_RAW_FOR_LIB" s1 AUTOPILOT_ADOPTEd "" >/dev/null 2>&1 && exit 1
  tdd_write_phase "$TAKER_RAW_FOR_LIB" s1 IMPL "Autopilot-Adopted: forged" >/dev/null 2>&1 && exit 1
  _tdd_write_phase_critical "$B9B_STATE" "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" s1 autopilot_adopted "" "" >/dev/null 2>&1 && exit 1
  # The REASON arm of `_tdd_write_phase_critical` had no mixed-case case anywhere:
  # `tdd_write_phase`'s own guard refuses first, so driving it through the outer
  # function can never reach this one. Called directly for that reason.
  _tdd_write_phase_critical "$B9B_STATE" "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" s1 IMPL "AUTOPILOT-ADOPTED: forged" "" >/dev/null 2>&1 && exit 1
  # The shared predicate must FAIL CLOSED when it cannot be reached. Extracting the two
  # inline `case` blocks into one function introduced a failure mode the duplication did
  # not have — an unexported or shadowed name would make the call fail, the `&&` not
  # fire, and the guard vanish silently. Shadowed here with a name that always reports
  # "not found" is impossible in bash, so the reachability check is graded instead.
  ( unset -f _tdd_reserved_provenance
    _tdd_write_phase_critical "$B9B_STATE" "$(zensu_resolve_session_id "$TAKER_RAW_FOR_LIB")" s1 IMPL "" "" >/dev/null 2>&1 ) && exit 1
  exit 0 ) || B9B_OK=false
if [ "$B9B_OK" = true ]; then
  check "B9b both library guard sites refuse the reserved phase and reason prefix, in any case, each behind its own same-layer control" PASS
else
  check "B9b the library guards accepted a reserved phase or reason" FAIL
fi

# --- B10 the takeover leaves provenance in the adopter's workflow history ----
TAKER_DOC="$STATE_DIR/tdd-phase-${TAKER_KEY}.json"
if [ -f "$TAKER_DOC" ] \
  && json_ok "$TAKER_DOC" 'Array.isArray(value.history) && value.history.some(e => e && e.phase === "AUTOPILOT_ADOPTED")' \
  && json_ok "$TAKER_DOC" "value.history.some(e => e && e.reason === 'autopilot-adopted: run adopt_cli_run taken over from $OWNER_KEY')"; then
  check "B10 the adopter's workflow history records the AUTOPILOT_ADOPTED takeover" PASS
else
  check "B10 provenance entry missing from $TAKER_DOC" FAIL
fi

# --- B10b provenance must not move a running chain's FSM cursor --------------
# `phase !== "AUTOPILOT_ADOPTED"` alone holds for an ABSENT value, so it could pass
# without the write having been observed at all. Compare against the cursor captured
# before the adopt instead, and cover `step_id` as well as `phase`.
if [ "$TAKER_PHASE_BEFORE" = IMPL ] && [ "$TAKER_STEP_BEFORE" = b10b-step ] \
  && [ "$TAKER_PHASE_BEFORE" = "$TAKER_PHASE_AFTER" ] \
  && [ "$TAKER_STEP_BEFORE" = "$TAKER_STEP_AFTER" ] \
  && [ "$TAKER_PHASE_AFTER" != "AUTOPILOT_ADOPTED" ]; then
  check "B10b the provenance write appends history and leaves phase and step_id byte-equal" PASS
else
  check "B10b the provenance write moved the FSM cursor (phase $TAKER_PHASE_BEFORE -> $TAKER_PHASE_AFTER, step '$TAKER_STEP_BEFORE' -> '$TAKER_STEP_AFTER')" FAIL
fi

# --- B11 a terminal run cannot be adopted ------------------------------------
TERMP="$TMP/terminal"; mkdir -p "$TERMP"
TERMP="$(cd "$TERMP" && pwd -P)"
activate_session "$TERMP" adopt_term_owner || exit 1
TERM_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_term_run "$TERM_OWNER" "$TERMP" >/dev/null 2>&1 \
  && autopilot_apply_event adopt_term_run evt-cancel CANCEL '{}' "$TERMP" >/dev/null 2>&1; then
  rm -f "$(_autopilot_active_path "$TERMP/.zensu/state" "$TERM_OWNER")"
  run_verb "$TERMP" adopt_term_taker --autopilot-adopt --run adopt_term_run --confirm \
    >/dev/null 2>"$TMP/b11.err"
  B11_RC=$?
  if [ "$B11_RC" -eq 3 ] && grep -qF 'terminal run cannot be adopted' "$TMP/b11.err"; then
    check "B11 a terminal run cannot be adopted" PASS
  else
    check "B11 terminal adopt (rc=$B11_RC, expected 3)" FAIL
  fi
else
  check "B11 fixture could not build a terminal run" FAIL
fi

# --- B12 the release's OWN config key gates its liveness check (AC-009) -------
# Two arms over one fixture whose owner looks alive: at the default the release
# refuses, and at `autopilotReleaseOwnerActivityTtlHours: 0` the check is disabled
# and the same call lands. Without the second arm the first would also pass against
# any reader that never disables. The adoption key is graded apart in
# test-autopilot-release-cli.sh A18, which proves it no longer reaches the release.
printf '%s' '{"hooks":{"autopilotReleaseOwnerActivityTtlHours":0}}' > "$TMP/release-ttl-zero.json"
RELP="$TMP/release"; mkdir -p "$RELP"
RELP="$(cd "$RELP" && pwd -P)"
activate_session "$RELP" adopt_rel_owner || exit 1
REL_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_rel_run "$REL_OWNER" "$RELP" >/dev/null 2>&1; then
  REL_RUN_FILE="$(autopilot_run_file adopt_rel_run "$RELP")"
  run_verb "$RELP" adopt_rel_taker --autopilot-release --run adopt_rel_run --confirm >/dev/null 2>&1
  B12A_RC=$?
  run_verb_cfg "$RELP" adopt_rel_taker "$TMP/release-ttl-zero.json" \
    --autopilot-release --run adopt_rel_run --confirm >/dev/null 2>&1
  B12B_RC=$?
  if [ "$B12A_RC" -eq 7 ] && [ "$B12B_RC" -eq 0 ] \
    && json_ok "$REL_RUN_FILE" 'value.stage === "CANCELLED"'; then
    check "B12 autopilotReleaseOwnerActivityTtlHours gates the release liveness check, and 0 disables it" PASS
  else
    check "B12 release TTL key (default rc=$B12A_RC expected 7, zero rc=$B12B_RC expected 0)" FAIL
  fi
else
  check "B12 fixture could not build a release run" FAIL
fi

# --- B12b the same key gates ADOPT, and 0 disables it there too --------------
ADP2="$TMP/ttlzero"; mkdir -p "$ADP2"
ADP2="$(cd "$ADP2" && pwd -P)"
activate_session "$ADP2" adopt_ttl_owner || exit 1
TTL_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_ttl_run "$TTL_OWNER" "$ADP2" >/dev/null 2>&1; then
  TTL_RUN_FILE="$(autopilot_run_file adopt_ttl_run "$ADP2")"
  # EVERY other successful-adopt fixture deletes the previous owner's pointer as its
  # abandonment precondition, which makes their "the old pointer is gone" assertion
  # true before the verb ever runs. This is the one fixture where it survives, so it
  # is where the retire is graded — deleting the unlink in the library left the whole
  # suite green until this check existed.
  TTL_OWNER_PTR="$(_autopilot_active_path "$ADP2/.zensu/state" "$TTL_OWNER")"
  B12B_PTR_BEFORE=no; [ -f "$TTL_OWNER_PTR" ] && B12B_PTR_BEFORE=yes
  run_verb_cfg "$ADP2" adopt_ttl_taker "$TMP/ttl-zero.json" \
    --autopilot-adopt --run adopt_ttl_run --confirm >/dev/null 2>"$TMP/b12b.err"
  B12C_RC=$?
  TTL_TAKER="$ZENSU_SESSION_KEY"
  # Disabling the check must not be SILENT, or an operator reads the missing refusal
  # as a boundary that is no longer enforced at all. The release twin asserts the same.
  # The needle names the CONFIG branch and its interpolated value: the bare prefix is
  # now shared by four stand-down messages across the two verbs, so it could no longer
  # tell this branch from an absent or future-dated beacon, and the value the message
  # interpolates was pinned by nothing anywhere in tests/.
  if [ "$B12C_RC" -eq 0 ] && json_ok "$TTL_RUN_FILE" "value.ownerSessionId === '$TTL_TAKER'" \
    && grep -qF 'owner liveness unchecked: autopilotOwnerActivityTtlHours is 0' "$TMP/b12b.err" \
    && [ "$B12B_PTR_BEFORE" = yes ] && [ ! -f "$TTL_OWNER_PTR" ]; then
    check "B12b at ttl 0 the adopt liveness check is disabled and the previous owner's pointer is retired" PASS
  else
    check "B12b adopt at ttl 0 (rc=$B12C_RC, pointer before=$B12B_PTR_BEFORE after=$( [ -f "$TTL_OWNER_PTR" ] && echo present || echo gone))" FAIL
  fi
else
  check "B12b fixture could not build a ttl-zero run" FAIL
fi

# --- B13 the operator-facing carriers name the key and the verb (FR-001) -----
B13_MISSING=""
for pair in \
  "$EXAMPLE_CONFIG:autopilotOwnerActivityTtlHours" \
  "$DOC_CONFIG:autopilotOwnerActivityTtlHours" \
  "$DOC_CONFIG:--autopilot-adopt" \
  "$EXAMPLE_CONFIG:autopilotReleaseOwnerActivityTtlHours" \
  "$DOC_CONFIG:autopilotReleaseOwnerActivityTtlHours" \
  "$DOC_WORKFLOW:autopilotReleaseOwnerActivityTtlHours" \
  "$REPO_CLAUDE:autopilot_adopt_run" \
  "$REPO_CLAUDE:AUTOPILOT_ADOPTED" \
  "$DOC_WORKFLOW:--autopilot-adopt" \
  "$DOC_WORKFLOW:autopilotOwnerActivityTtlHours" \
  "$SUITE_OVERVIEW:autopilot-adopt-cli"; do
  file="${pair%%:*}"; needle="${pair#*:}"
  if [ ! -r "$file" ] || ! grep -qF -- "$needle" "$file"; then
    B13_MISSING="$B13_MISSING $(basename "$file")=$needle"
  fi
done
if [ -z "$B13_MISSING" ]; then
  check "B13 config.example.json, docs/configuration.md, CLAUDE.md, the workflow doc and SUITE-OVERVIEW.md carry the key, the verb and the suite" PASS
else
  check "B13 missing carrier content:$B13_MISSING" FAIL
fi

# --- B14 the skill exists and is registered ----------------------------------
# Registration alone leaves the model-facing spelling ungraded: a typo in the
# frontmatter name or in any printed command ships with every check green. The
# sibling `test-autopilot-release-cli.sh` A11 pins the same set minus the report
# command, which exists only here: release has no read-only mode.
B14_MISS=""
if [ -r "$SKILL" ]; then
  grep -qF -- '"./skills/autopilot-adopt"' "$PLUGIN_JSON" || B14_MISS="$B14_MISS plugin.json-entry"
  grep -qE '^name: autopilot-adopt$' "$SKILL" || B14_MISS="$B14_MISS frontmatter-name"
  grep -qF '# /zensu:autopilot-adopt' "$SKILL" || B14_MISS="$B14_MISS heading"
  grep -qF -- '--autopilot-adopt --run <RUN_ID> --confirm' "$SKILL" || B14_MISS="$B14_MISS adopt-command"
  # The Step 1 REPORT spelling, anchored at end of line: the confirmed spelling above
  # contains it as a prefix, so an unanchored needle would be satisfied by that line
  # alone while the report command the model runs first went unpinned.
  grep -qE -- '--autopilot-adopt --run <RUN_ID>$' "$SKILL" || B14_MISS="$B14_MISS report-command"
  grep -qF -- '--autopilot-status' "$SKILL" || B14_MISS="$B14_MISS status-command"
else
  B14_MISS=" unreadable"
fi
if [ -z "$B14_MISS" ]; then
  check "B14 the skill is registered and its name, heading and all three printed commands are pinned" PASS
else
  check "B14 autopilot-adopt skill contract missing:$B14_MISS" FAIL
fi

# --- B38 the critical section REQUIRES its mode operand (F4) ------------------
# `_autopilot_adopt_critical` used to default the mode to `confirm` when the operand
# was omitted. Refusing an unrecognized VALUE while defaulting an ABSENT one was half a
# property, and the half that was missing is the dangerous one: the public entry point's
# own comment justifies the refusal on the ground that the permissive spelling is the one
# that MOVES OWNERSHIP, so an omission silently selected exactly that spelling.
#
# Driven rather than source-pinned, because a source pin on an arity test proves only
# that someone typed the test. It also supplies an UNCONDITIONAL measured exit 3: the
# other producers of that code sit inside conditional blocks that a fixture failure can
# skip, and B21 reads VALUES, so a skipped block contributes nothing and 3 would read as
# documented-but-unmeasured for a reason that is about this suite rather than the verb.
#
# The session is re-bound FIRST. Every call below runs in-process, so it is judged
# against whatever session the last fixture happened to leave active — and an unbound
# one refuses at exit 2 before any arity test is reached, which the CONTROL cannot tell
# from the pass it is named for: an empty stderr satisfies a `grep … && fail` control
# whatever the cause. Binding here is what makes the control discriminate.
activate_session "$PROJECT" adopt_cli_taker || exit 1
B38_ERR="$TMP/b38.err"
( _autopilot_adopt_critical "$PROJECT" adopt_cli_run "$B1_TAKER_KEY" "$PROJECT" 1 ) \
  >/dev/null 2>"$B38_ERR"
B38_RC=$?
B38_OK=true
[ "$B38_RC" -eq 3 ] || B38_OK=false
grep -qF 'the adoption mode operand is required' "$B38_ERR" || B38_OK=false
# CONTROL: the same call WITH the operand must not be refused for arity. It may refuse
# for any other reason this fixture produces — what must not happen is the arity cause,
# and what must not happen either is the silent exit-2 binding fault above, which would
# satisfy this control while proving nothing.
( _autopilot_adopt_critical "$PROJECT" adopt_cli_run "$B1_TAKER_KEY" "$PROJECT" 1 report ) \
  >/dev/null 2>"$TMP/b38b.err"
B38_CTL_RC=$?
grep -qF 'the adoption mode operand is required' "$TMP/b38b.err" && B38_OK=false
if [ "$B38_CTL_RC" -eq 2 ] && [ ! -s "$TMP/b38b.err" ]; then B38_OK=false; fi
# The PUBLIC entry point carries the same requirement. It kept a `confirm` default while
# the critical section refused an omission, so the one spelling that MOVES OWNERSHIP was
# what an omitted operand selected — at the only layer a caller outside this file reaches.
B38_PUB_ERR="$TMP/b38pub.err"
( cd "$PROJECT" && autopilot_adopt_run adopt_cli_run "$PROJECT" "$ZENSU_SESSION_KEY" ) \
  >/dev/null 2>"$B38_PUB_ERR"
B38_PUB_RC=$?
[ "$B38_PUB_RC" -eq 3 ] || B38_OK=false
grep -qF 'the adoption mode operand is required' "$B38_PUB_ERR" || B38_OK=false
# CONTROL: the same call WITH the operand is not refused for arity.
( cd "$PROJECT" && autopilot_adopt_run adopt_cli_run "$PROJECT" "$ZENSU_SESSION_KEY" report ) \
  >/dev/null 2>"$TMP/b38pubb.err"
grep -qF 'the adoption mode operand is required' "$TMP/b38pubb.err" && B38_OK=false
if [ "$B38_OK" = true ]; then
  check "B38 both the critical section and the public entry refuse an omitted mode operand with exit 3 and name it, and accept the same call with one" PASS
else
  check "B38 arity guard (critical rc=$B38_RC control rc=$B38_CTL_RC public rc=$B38_PUB_RC, stderr=$(head -c 120 "$B38_PUB_ERR" 2>/dev/null))" FAIL
fi

# --- B36 the REPORT-mode contract is stated where each audience reads it -------
# B14 pins the report COMMAND; nothing pinned what the skill promises ABOUT it, and
# the three promises below were each false in a different direction.
#
# The Step 2 exit table describes a CONFIRMED run: its exit-1 row says "the takeover
# may already have landed" and its exit-5 row prescribes a rollback reading. Neither
# state is reachable in report mode — the report branch returns before the first temp,
# and the worker's only `fail(5)` is `writeOutput`, which report mode never reaches.
# Step 1 nonetheless routed a non-zero REPORT exit straight into that table, so a
# model reading a refused read-only run was told a takeover might have landed and
# could go looking for a recovery against a run nothing touched. Exit 1 is genuinely
# reachable there (`_autopilot_read_storage_ready` answers 1 for an absent
# `.zensu/state`), so this is not a hypothetical row.
#
# The table is scoped in PROSE and never by adding a second table. `B21_DOCUMENTED`
# below extracts its codes with a `sed` over EVERY numeric-leading table row in this
# skill, so a parallel "report exits" table would silently enrol its own codes in the
# documented set and corrupt B21 in both directions at once.
B36_MISS=""
if [ -r "$SKILL" ]; then
  grep -qF 'A non-zero exit from the report never means anything moved' "$SKILL" \
    || B36_MISS="$B36_MISS step1-nothing-moved"
  grep -qF 'The table below describes the `--confirm` run' "$SKILL" \
    || B36_MISS="$B36_MISS step2-scoped-to-confirm"
  # F11: report mode's own write guard reuses exit 2, which the table already spends on
  # two unrelated classes. The guard is unreachable today, so the honest fix is to name
  # the overload in the row rather than to mint a code no case can ever measure.
  grep -qF "the report's own write guard also exits 2" "$SKILL" \
    || B36_MISS="$B36_MISS exit2-overload-documented"
else
  B36_MISS=" unreadable"
fi
# The library half, SLICE-BOUNDED. A file-wide grep is what made S7v vacuous in the
# sibling suite: the needle existed elsewhere in the same file, so the check passed
# whatever happened at the site it was named for. Bound to `_autopilot_adopt_critical`
# and require the lease sentence INSIDE it.
B36_LIB_START="$(grep -n '^_autopilot_adopt_critical() {' "$LIB" | head -1 | cut -d: -f1)"
if [ -n "$B36_LIB_START" ]; then
  B36_LIB_END="$(awk -v s="$B36_LIB_START" 'NR>s && /^}$/ {print NR; exit}' "$LIB")"
  if [ -n "$B36_LIB_END" ]; then
    sed -n "${B36_LIB_START},${B36_LIB_END}p" "$LIB" \
      | grep -qF 'runs under the project lease' \
      || B36_MISS="$B36_MISS lease-not-disclosed-at-the-report-branch"
  else
    B36_MISS="$B36_MISS lib-slice-unbounded"
  fi
else
  B36_MISS="$B36_MISS lib-anchor-missing"
fi
if [ -z "$B36_MISS" ]; then
  check "B36 the skill scopes its exit table to --confirm, states that a non-zero report moved nothing, names the exit-2 overload, and the library discloses the lease at the report branch" PASS
else
  check "B36 report-mode contract missing:$B36_MISS" FAIL
fi

# --- B37 the per-verb window split is stated consistently wherever it is stated ------
# Four carriers each asserted something the split made false, and every one of them is a
# CENSUS or a both-verbs claim — the drift class this repository records about itself.
# They are pinned NEGATIVELY, on the retired spelling, because that is the direction that
# can actually fail: the replacement wording is mine to choose, so a positive needle would
# only ever re-assert what I just wrote, while the retired literal is what a later edit
# would restore by accident.
B37_MISS=""
b37_forbid() { # file needle label
  [ -r "$1" ] || { B37_MISS="$B37_MISS $3=unreadable"; return; }
  grep -qF -- "$2" "$1" && B37_MISS="$B37_MISS $3"
  return 0
}
b37_require() { # file needle label
  [ -r "$1" ] || { B37_MISS="$B37_MISS $3=unreadable"; return; }
  grep -qF -- "$2" "$1" || B37_MISS="$B37_MISS $3"
  return 0
}
# F2 — the doctor paragraph called one key "the window --autopilot-release and
# --autopilot-adopt actually read". Release reads its own key now, and the SAME file
# states the split correctly further down, so the file contradicted itself.
b37_forbid "$DOC_WORKFLOW" \
  'the window `--autopilot-release` and `--autopilot-adopt` actually read' f2-both-verbs-window
# F13 — the getter comment named two constant-mirror pins where four getters now read
# operands through `getter_operand`.
b37_forbid "$PLUGIN_DIR/hooks/lib/zensu-config.sh" \
  'the two constant-mirror pins' f13-two-mirror-pins
# JUDGE-2 — three arms emit the stand-down line; the future-dated case REFUSES with
# exit 7 instead, which is not a stand-down. Fixing this by adding a fourth emission
# would contradict AC-005, so the comment is what moves.
b37_forbid "$LIB" 'FOUR ways to stand down' judge2-four-stand-downs
# F1 — the CLAUDE.md census said the re-resolve appears TWICE and that C21c runs under a
# floor of three; there are three blocks and the floor is four. Its own TRIGGER fired.
b37_forbid "$REPO_CLAUDE" 'record-root re-resolve TWICE' f1-stale-census
b37_forbid "$REPO_CLAUDE" 'under a floor of three' f1-stale-floor
# F8 — the trigger fired and the seam was NOT taken. A fired trigger declined in silence
# is the exact drift F1 documents, so the decline must be written down with a new one.
# The needle must be SPECIFIC to this seam. `TRIGGER was evaluated` alone already occurs
# in the Plan-Approval Delivery Route section from an unrelated round, so it matched prose
# nobody wrote for F8 and could never fail — the same needle-matches-prose defect F10 is
# about, reintroduced by the check written to prevent it.
b37_require "$REPO_CLAUDE" 'The TRIGGER FIRED in the per-verb window round' f8-decline-unrecorded
if [ -z "$B37_MISS" ]; then
  check "B37 no carrier still claims one window governs both verbs, names two mirror pins, counts four stand-downs or a two-block re-resolve, and the declined seam is recorded" PASS
else
  check "B37 per-verb split carriers still stale:$B37_MISS" FAIL
fi

# --- B15 the model-facing refusal offers adoption BEFORE cancellation --------
# One renderer, two audiences. The model form must quote no runnable command,
# because --confirm is the consent control and a complete invocation routes
# around the only place it exists.
HOLDER='{"runId":"held_run","stage":"BLOCKED","ownerSessionId":"someone-else"}'
MODEL_TEXT="$(_autopilot_workspace_refusal "$HOLDER" "not-the-owner" model 2>/dev/null)"
OPERATOR_TEXT="$(_autopilot_workspace_refusal "$HOLDER" "not-the-owner" operator 2>/dev/null)"
B15_OK=true
printf '%s' "$MODEL_TEXT" | grep -qF -- "/zensu:autopilot-adopt" || B15_OK=false
printf '%s' "$MODEL_TEXT" | grep -qF -- "/zensu:autopilot-release" || B15_OK=false
printf '%s' "$MODEL_TEXT" | grep -qF -- "--confirm" && B15_OK=false
printf '%s' "$MODEL_TEXT" | grep -qF -- "zensu-log.sh" && B15_OK=false
printf '%s' "$OPERATOR_TEXT" | grep -qF -- "zensu-log.sh --autopilot-adopt --run held_run --confirm" || B15_OK=false
printf '%s' "$OPERATOR_TEXT" | grep -qF -- "zensu-log.sh --autopilot-release --run held_run --confirm" || B15_OK=false
# Order is the property, not mere presence: a cancel reached for first cannot be undone.
# Flatten first: `awk index` emits one number per LINE, so a renderer string that ever
# wraps would make these variables multi-line and fail the numeric test for a wording
# reason rather than an ordering one. An absent needle still yields 0, caught below.
MODEL_ONE_LINE="$(printf '%s' "$MODEL_TEXT" | tr '\n' ' ')"
MODEL_ADOPT_AT="$(printf '%s' "$MODEL_ONE_LINE" | awk '{print index($0, "/zensu:autopilot-adopt")}')"
MODEL_REL_AT="$(printf '%s' "$MODEL_ONE_LINE" | awk '{print index($0, "/zensu:autopilot-release")}')"
[ -n "$MODEL_ADOPT_AT" ] && [ -n "$MODEL_REL_AT" ] \
  && [ "$MODEL_ADOPT_AT" -gt 0 ] && [ "$MODEL_ADOPT_AT" -lt "$MODEL_REL_AT" ] || B15_OK=false
if [ "$B15_OK" = true ]; then
  check "B15 the refusal names adoption before release in the model form, with no runnable command" PASS
else
  check "B15 refusal wording (model='$MODEL_TEXT')" FAIL
fi

# --- B16 the worker mode declares its path operands --------------------------
# A path operand missing from `path_indexes` is not converted before native Node
# starts, which on win32 leaves it in the MSYS namespace and silently mis-roots
# the write. This is a source pin because the defect is invisible on POSIX.
if grep -qE '^\s*adopt\) path_indexes=\(0 1 3 5 8\) ;;' "$LIB"; then
  check "B16 the adopt worker mode declares its five path operands" PASS
else
  check "B16 the adopt worker mode's path_indexes entry is missing or changed" FAIL
fi

# --- B4b the WORKER's already-owner exit 10 is asserted at its own layer -----
# `_autopilot_adopt_critical` maps rc 10 to `return 0`, so the CLI can never show
# it and B4 alone would stay green if the worker returned 0 and the shell arm were
# deleted. Drive the worker directly, from the run's own tree.
B4B_RC=""
if [ -f "$RUN_FILE" ]; then
  # The two temps must live INSIDE the project: `_autopilot_native_project_path`
  # refuses any path_indexes operand outside the project root, which is itself the
  # containment this worker relies on.
  : > "$STATE_DIR/.b4b-run.tmp"; : > "$STATE_DIR/.b4b-ptr.tmp"
  # The path validator keys on the exported ZENSU_PROJECT_ROOT / ZENSU_SESSION_KEY /
  # ZENSU_SESSION_CONTEXT triple, not on CLAUDE_PROJECT_DIR, and later fixtures
  # activated sessions in other roots — so re-activate THIS project's taker first or
  # every operand is refused with a bare rc 2 and no message.
  activate_session "$PROJECT" adopt_cli_taker || exit 1
  ( cd "$PROJECT" && CLAUDE_PROJECT_DIR="$PROJECT" \
    _autopilot_node adopt "$RUN_FILE" "$STATE_DIR/.b4b-run.tmp" adopt_cli_run \
      "$PROJECT" "$TAKER_KEY" "$STATE_DIR" "$PROJECT" 1 "$STATE_DIR/.b4b-ptr.tmp" ) >/dev/null 2>"$TMP/b4b.err"
  B4B_RC=$?
  rm -f "$STATE_DIR/.b4b-run.tmp" "$STATE_DIR/.b4b-ptr.tmp"
  if [ "$B4B_RC" -eq 10 ]; then
    check "B4b the worker reports the already-owner case as exit 10, which the shell collapses to 0" PASS
  else
    check "B4b worker already-owner exit (rc=$B4B_RC, expected 10; stderr: $(head -c 160 "$TMP/b4b.err" 2>/dev/null))" FAIL
  fi
else
  check "B4b fixture run file missing" FAIL
fi

# --- B17 the caller may not orphan a run it already owns ---------------------
# Overwriting the caller's owner pointer would leave its OTHER nonterminal run
# hidden behind it, and `read-active` then refuses with exit 2 for every consumer
# with no repair path — `begin`'s recovery arm requires a terminal active run.
# Two sibling worktrees, because the workspace hold makes this unreachable in one.
ORPH="$TMP/orphan"; mkdir -p "$ORPH"
ORPH="$(cd "$ORPH" && pwd -P)"
( cd "$ORPH" && git init -q . && git -c user.email=a@b -c user.name=t commit -q --allow-empty -m base ) >/dev/null 2>&1
OWT_A="$ORPH/own-a"; OWT_B="$ORPH/own-b"
( cd "$ORPH" && git worktree add -q -b orph-a "$OWT_A" && git worktree add -q -b orph-b "$OWT_B" ) >/dev/null 2>&1
B17_RC=""; B18_RC=""
if [ ! -d "$OWT_A" ] || [ ! -d "$OWT_B" ]; then
  check "B17 orphan fixture needs two usable worktrees — environment, not product" FAIL
else
  activate_session "$ORPH" adopt_orph_stranded || exit 1
  ORPH_STRANDED="$ZENSU_SESSION_KEY"
  autopilot_begin_run adopt_orph_target "$ORPH_STRANDED" "$ORPH" false true "$OWT_A" >/dev/null 2>&1
  rm -f "$(_autopilot_active_path "$ORPH/.zensu/state" "$ORPH_STRANDED")"
  activate_session "$ORPH" adopt_orph_taker || exit 1
  ORPH_TAKER="$ZENSU_SESSION_KEY"
  autopilot_begin_run adopt_orph_own "$ORPH_TAKER" "$ORPH" false true "$OWT_B" >/dev/null 2>&1
  ORPH_TARGET_FILE="$(autopilot_run_file adopt_orph_target "$ORPH")"
  ORPH_OWN_FILE="$(autopilot_run_file adopt_orph_own "$ORPH")"
  if [ -f "$ORPH_TARGET_FILE" ] && [ -f "$ORPH_OWN_FILE" ]; then
    BEFORE_B17="$(digest "$ORPH_TARGET_FILE")"
    ( cd "$OWT_A" && CLAUDE_PROJECT_DIR="$ORPH" ZENSU_CONFIG="$TMP/missing-config.json" \
        bash "$LOG" --autopilot-adopt --run adopt_orph_target --confirm ) >/dev/null 2>"$TMP/b17.err"
    B17_RC=$?
    B17_PTR="$(_autopilot_active_path "$ORPH/.zensu/state" "$ORPH_TAKER")"
    autopilot_read_active "$ORPH" "$ORPH_TAKER" >/dev/null 2>&1
    B17_READ_RC=$?
    # Captured HERE: the anti-vacuity control below adopts the target, so a digest
    # comparison after it would grade the control's write, not the refusal's silence.
    B17_UNCHANGED=no
    [ "$(digest "$ORPH_TARGET_FILE")" = "$BEFORE_B17" ] && B17_UNCHANGED=yes
    # The caller's pointer is order-sensitive for the same reason: the control adopts
    # the target, which moves this pointer onto it.
    B17_PTR_OK=no
    json_ok "$B17_PTR" 'value.runId === "adopt_orph_own"' && B17_PTR_OK=yes
    # Anti-vacuity: with the caller's OWN run cancelled the identical call must land,
    # or B17 would pass for any refusal at all — a broken fixture included.
    B17_CONTROL_RC=1
    if autopilot_apply_event adopt_orph_own evt-orph-cancel CANCEL '{}' "$ORPH" >/dev/null 2>&1; then
      activate_session "$ORPH" adopt_orph_taker >/dev/null 2>&1
      ( cd "$OWT_A" && CLAUDE_PROJECT_DIR="$ORPH" ZENSU_CONFIG="$TMP/missing-config.json" \
          bash "$LOG" --autopilot-adopt --run adopt_orph_target --confirm ) >/dev/null 2>&1
      B17_CONTROL_RC=$?
    fi
    if [ "$B17_RC" -eq 4 ] \
      && grep -qF 'caller already owns nonterminal run adopt_orph_own' "$TMP/b17.err" \
      && [ "$B17_CONTROL_RC" -eq 0 ] \
      && [ "$B17_UNCHANGED" = yes ] \
      && [ "$B17_PTR_OK" = yes ] \
      && [ "$B17_READ_RC" -eq 0 ]; then
      check "B17 a caller holding another nonterminal run is refused, and its own run stays readable" PASS
    else
      check "B17 orphan guard (rc=$B17_RC expected 4, read-active rc=$B17_READ_RC expected 0, control rc=${B17_CONTROL_RC:-unset} expected 0, needle=$(grep -cF 'caller already owns nonterminal run adopt_orph_own' "$TMP/b17.err"), unchanged=$B17_UNCHANGED ptr_ok=$B17_PTR_OK)" FAIL
    fi
  else
    check "B17 fixture could not build two owned runs" FAIL
  fi
fi

# --- B18 a run BLOCKED out of TDD_RUNNING is refused too ---------------------
# The guard tests the PENDING stage. A literal `stage === "TDD_RUNNING"` would let
# this through, and RESUME would then restore a chain whose TDD_CHAIN_DONE the new
# owner can never satisfy. B5 covers the direct case; this is the blocked one.
BLKP="$TMP/blocked"; mkdir -p "$BLKP"
BLKP="$(cd "$BLKP" && pwd -P)"
activate_session "$BLKP" adopt_blk_owner || exit 1
BLK_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_blk_run "$BLK_OWNER" "$BLKP" >/dev/null 2>&1 \
  && autopilot_apply_event adopt_blk_run evt-plan PLAN_APPROVED \
    "{\"approvedPlanSha256\":\"$PLAN_SHA\"}" "$BLKP" >/dev/null 2>&1 \
  && autopilot_apply_event adopt_blk_run evt-tdd TDD_STARTED \
    '{"attempt":1,"chainId":"blk-chain-001","sessionId":"blk-session-001"}' "$BLKP" >/dev/null 2>&1 \
  && autopilot_apply_event adopt_blk_run evt-block BLOCK \
    '{"code":"TDD_RECONCILIATION_INVALID"}' "$BLKP" >/dev/null 2>&1; then
  BLK_RUN_FILE="$(autopilot_run_file adopt_blk_run "$BLKP")"
  rm -f "$(_autopilot_active_path "$BLKP/.zensu/state" "$BLK_OWNER")"
  if json_ok "$BLK_RUN_FILE" 'value.stage === "BLOCKED" && value.blocked.from === "TDD_RUNNING"'; then
    BEFORE_B18="$(digest "$BLK_RUN_FILE")"
    run_verb "$BLKP" adopt_blk_taker --autopilot-adopt --run adopt_blk_run --confirm \
      >/dev/null 2>"$TMP/b18.err"
    B18_RC=$?
    if [ "$B18_RC" -eq 3 ] && grep -qF 'live inner TDD chain' "$TMP/b18.err" \
      && grep -qF 'blocking that chain does not make the run adoptable' "$TMP/b18.err" \
      && [ "$(digest "$BLK_RUN_FILE")" = "$BEFORE_B18" ]; then
      check "B18 a run blocked out of TDD_RUNNING is refused on its pending stage" PASS
    else
      check "B18 pending-stage guard (rc=$B18_RC, expected 3)" FAIL
    fi
  else
    check "B18 fixture could not reach BLOCKED with blocked.from TDD_RUNNING" FAIL
  fi
else
  check "B18 fixture could not build a blocked TDD run" FAIL
fi

# --- B19 the already-owner path repairs a missing pointer --------------------
# Exit 10 may only mean "already fully owned". With the record owned and the
# pointer gone, returning success would leave --autopilot-status showing nothing.
REP="$TMP/repair"; mkdir -p "$REP"
REP="$(cd "$REP" && pwd -P)"
activate_session "$REP" adopt_rep_owner || exit 1
REP_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_rep_run "$REP_OWNER" "$REP" >/dev/null 2>&1; then
  REP_PTR="$(_autopilot_active_path "$REP/.zensu/state" "$REP_OWNER")"
  REP_RUN_FILE="$(autopilot_run_file adopt_rep_run "$REP")"
  rm -f "$REP_PTR"
  # The premise, asserted rather than assumed: without it a path that stopped naming
  # the pointer would make `rm -f` a no-op and the surviving file would satisfy the
  # post-condition below, reporting a repair that never happened.
  B19_GONE=no; [ ! -f "$REP_PTR" ] && B19_GONE=yes
  run_verb "$REP" adopt_rep_owner --autopilot-adopt --run adopt_rep_run --confirm >/dev/null 2>"$TMP/b19.err"
  B19_RC=$?
  if [ "$B19_RC" -eq 0 ] && [ "$B19_GONE" = yes ] && [ -f "$REP_PTR" ] \
    && grep -qF "its owner pointer was missing or named a run that has already finished, and has been reinstalled" "$TMP/b19.err" \
    && json_ok "$REP_PTR" 'value.runId === "adopt_rep_run"' \
    && json_ok "$REP_RUN_FILE" "value.ownerSessionId === '$REP_OWNER'" \
    && json_ok "$REP_RUN_FILE" 'value.events.length === 1'; then
    check "B19 the owner's own adopt reinstalls a missing pointer and leaves the record intact" PASS
  else
    check "B19 pointer repair (rc=$B19_RC, removed=$B19_GONE, pointer $( [ -f "$REP_PTR" ] && echo present || echo missing))" FAIL
  fi
else
  check "B19 fixture could not build a repair run" FAIL
fi

# --- B19b the repair also covers a pointer naming a FINISHED run ---------------
# The branch has two entry shapes and B19 drives only the absent pointer. Here the
# pointer survives and names a run that has since been cancelled, so the exit-10 test
# fails on the run id and the terminal run is filtered out of the shadowed inventory.
# The second record is copied BEFORE the cancel: a copy taken afterwards would itself
# be terminal and the verb would refuse it with exit 3 before reaching the branch.
FIN="$TMP/finished"; mkdir -p "$FIN"
FIN="$(cd "$FIN" && pwd -P)"
activate_session "$FIN" adopt_fin_owner || exit 1
FIN_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_fin_old "$FIN_OWNER" "$FIN" >/dev/null 2>&1; then
  FIN_PTR="$(_autopilot_active_path "$FIN/.zensu/state" "$FIN_OWNER")"
  FIN_OLD_FILE="$(autopilot_run_file adopt_fin_old "$FIN")"
  FIN_NEW_FILE="$(autopilot_run_file adopt_fin_new "$FIN")"
  node -e '
    const fs = require("fs");
    const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    state.runId = "adopt_fin_new";
    fs.writeFileSync(process.argv[2], JSON.stringify(state, null, 2) + "\n");
  ' "$FIN_OLD_FILE" "$FIN_NEW_FILE" 2>/dev/null
  autopilot_apply_event adopt_fin_old evt-cancel CANCEL '{}' "$FIN" >/dev/null 2>&1
  B19B_PREMISE=no
  [ -f "$FIN_NEW_FILE" ] && json_ok "$FIN_OLD_FILE" 'value.stage === "CANCELLED"' \
    && json_ok "$FIN_PTR" 'value.runId === "adopt_fin_old"' && B19B_PREMISE=yes
  B19B_EVENTS="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).events.length))' "$FIN_NEW_FILE" 2>/dev/null)"
  run_verb "$FIN" adopt_fin_owner --autopilot-adopt --run adopt_fin_new --confirm >/dev/null 2>"$TMP/b19b.err"
  B19B_RC=$?
  if [ "$B19B_PREMISE" = yes ] && [ "$B19B_RC" -eq 0 ] \
    && grep -qF "its owner pointer was missing or named a run that has already finished, and has been reinstalled" "$TMP/b19b.err" \
    && json_ok "$FIN_PTR" 'value.runId === "adopt_fin_new"' \
    && json_ok "$FIN_NEW_FILE" "value.ownerSessionId === '$FIN_OWNER'" \
    && [ -n "$B19B_EVENTS" ] && json_ok "$FIN_NEW_FILE" "value.events.length === $B19B_EVENTS"; then
    check "B19b the owner's own adopt reinstalls a pointer that named a finished run and leaves the record's events unchanged" PASS
  else
    check "B19b finished-run repair (premise=$B19B_PREMISE, rc=$B19B_RC, events=$B19B_EVENTS, stderr: $(head -c 160 "$TMP/b19b.err" 2>/dev/null))" FAIL
  fi
else
  check "B19b fixture could not build a finished-run repair" FAIL
fi

# --- B32 a retry retires a stale pointer another key still holds for this run --
# A takeover that dies after its record install but before its retire leaves the
# previous owner's pointer naming a run that key no longer owns, and nothing re-derives
# that filename afterwards, because the previous owner's id has left the record. The
# retry lands on the already-owned exit, or on the repair when this session's own
# pointer is gone too, so both paths must sweep. The interrupted retire is reproduced by
# writing the previous owner's pointer back after a completed takeover.
b32_arm() {
  local arm="$1" project="$TMP/b32-$1" owner owner_ptr taker taker_ptr run err rc read_rc ok=true
  mkdir -p "$project" && project="$(cd "$project" && pwd -P)" || return 1
  run="adopt_b32_$arm"
  err="$TMP/b32-$arm.err"
  activate_session "$project" "adopt_b32_${arm}_owner" || return 1
  owner="$ZENSU_SESSION_KEY"
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null 2>&1 || return 1
  owner_ptr="$(_autopilot_active_path "$project/.zensu/state" "$owner")"
  run_verb_cfg "$project" "adopt_b32_${arm}_taker" "$TMP/ttl-zero.json" \
    --autopilot-adopt --run "$run" --confirm >/dev/null 2>&1 || return 1
  taker="$ZENSU_SESSION_KEY"
  taker_ptr="$(_autopilot_active_path "$project/.zensu/state" "$taker")"
  json_ok "$(autopilot_run_file "$run" "$project")" "value.ownerSessionId === '$taker'" || return 1
  [ ! -e "$owner_ptr" ] || return 1
  RUN="$run" node -e 'process.stdout.write(JSON.stringify({ schemaVersion: 1, runId: process.env.RUN }, null, 2) + "\n")' > "$owner_ptr" || return 1
  [ "$arm" = repair ] && rm -f "$taker_ptr"
  run_verb "$project" "adopt_b32_${arm}_taker" --autopilot-adopt --run "$run" --confirm >/dev/null 2>"$err"
  rc=$?
  autopilot_read_active "$project" "$owner" >/dev/null 2>&1
  read_rc=$?
  [ "$rc" -eq 0 ] || ok=false
  [ ! -e "$owner_ptr" ] || ok=false
  [ "$read_rc" -eq 1 ] || ok=false
  grep -qF "retired a stale owner pointer that still designated this run: $(basename "$owner_ptr")" "$err" || ok=false
  json_ok "$taker_ptr" "value.runId === '$run'" || ok=false
  B32_DETAIL="$B32_DETAIL $arm:rc=$rc,read=$read_rc,stale=$( [ -e "$owner_ptr" ] && echo kept || echo gone)"
  [ "$ok" = true ]
}
B32_DETAIL=""
B32_OK=true
b32_arm owned || B32_OK=false
b32_arm repair || B32_OK=false
if [ "$B32_OK" = true ]; then
  check "B32 the already-owned and repair retries both retire a stale pointer another key holds for the run, say so, and free that key's read" PASS
else
  check "B32 stale other-key pointer sweep (${B32_DETAIL# })" FAIL
fi

# --- B33 a just-adopted run is protected before its new owner's next turn end ----
# Liveness is judged on the owner's workflow-document mtime, and a session that adopts
# while its own document is stale used to leave that document stale: the second verb
# queued behind the lease then read the new owner as silent and took the run over, or
# cancelled it. The CLI's provenance write refreshes the document only AFTER the lease,
# and only when it succeeds, so the library verb is driven in-process here, where no
# provenance write follows. Two arms: a second adopter, and a third session's release.
b33_arm() {
  local arm="$1" project="$TMP/b33-$1" run owner first err rc ok=true
  mkdir -p "$project" && project="$(cd "$project" && pwd -P)" || return 1
  run="adopt_b33_$arm"
  err="$TMP/b33-$arm.err"
  activate_session "$project" "adopt_b33_${arm}_owner" || return 1
  owner="$ZENSU_SESSION_KEY"
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null 2>&1 || return 1
  touch -t 200001010000 "$project/.zensu/state/tdd-phase-$owner.json" || return 1
  activate_session "$project" "adopt_b33_${arm}_first" || return 1
  first="$ZENSU_SESSION_KEY"
  touch -t 200001010000 "$project/.zensu/state/tdd-phase-$first.json" || return 1
  ( cd "$project" && autopilot_adopt_run "$run" "$project" "$first" confirm ) >/dev/null 2>&1 || return 1
  json_ok "$(autopilot_run_file "$run" "$project")" "value.ownerSessionId === '$first'" || return 1
  if [ "$arm" = adopt ]; then
    run_verb "$project" "adopt_b33_${arm}_second" --autopilot-adopt --run "$run" --confirm >/dev/null 2>"$err"
  else
    run_verb "$project" "adopt_b33_${arm}_second" --autopilot-release --run "$run" --confirm >/dev/null 2>"$err"
  fi
  rc=$?
  [ "$rc" -eq 7 ] || ok=false
  grep -qF 'the owning session is still active' "$err" || ok=false
  json_ok "$(autopilot_run_file "$run" "$project")" "value.ownerSessionId === '$first' && value.stage !== 'CANCELLED'" || ok=false
  B33_DETAIL="$B33_DETAIL $arm:rc=$rc"
  [ "$ok" = true ]
}
B33_DETAIL=""
B33_OK=true
b33_arm adopt || B33_OK=false
b33_arm release || B33_OK=false
if [ "$B33_OK" = true ]; then
  check "B33 a run adopted by a session whose own document was stale is refused to a second adopter and to a release with exit 7" PASS
else
  check "B33 just-adopted protection (${B33_DETAIL# }, each expected 7)" FAIL
fi

# --- B34 the repair refuses a run whose live inner chain another session drives --
# Ownership on the repair branch is decided by `ownerSessionId`, an unauthenticated
# field, and the branch used to reinstall the pointer before any pending-stage check,
# so a record planted with this session's id at TDD_RUNNING became this session's
# active run. The repair now refuses with exit 3 while the pending stage is TDD_RUNNING
# and `tdd.sessionId` names another session, and installs nothing. The CONTROL is the
# same record whose chain this session drives itself, which still repairs.
b34_arm() {
  local arm="$1" project="$TMP/b34-$1" run owner chain_session ptr err rc ok=true
  mkdir -p "$project" && project="$(cd "$project" && pwd -P)" || return 1
  run="adopt_b34_$arm"
  err="$TMP/b34-$arm.err"
  activate_session "$project" "adopt_b34_${arm}_owner" || return 1
  owner="$ZENSU_SESSION_KEY"
  chain_session="b34-foreign-chain-session"
  [ "$arm" = control ] && chain_session="$owner"
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" evt-plan PLAN_APPROVED "{\"approvedPlanSha256\":\"$PLAN_SHA\"}" "$project" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" evt-tdd TDD_STARTED \
    "{\"attempt\":1,\"chainId\":\"b34-chain-001\",\"sessionId\":\"$chain_session\"}" "$project" >/dev/null 2>&1 || return 1
  json_ok "$(autopilot_run_file "$run" "$project")" "value.stage === 'TDD_RUNNING'" || return 1
  ptr="$(_autopilot_active_path "$project/.zensu/state" "$owner")"
  rm -f "$ptr"
  run_verb "$project" "adopt_b34_${arm}_owner" --autopilot-adopt --run "$run" --confirm >/dev/null 2>"$err"
  rc=$?
  if [ "$arm" = control ]; then
    [ "$rc" -eq 0 ] && [ -f "$ptr" ] || ok=false
  else
    [ "$rc" -eq 3 ] && [ ! -e "$ptr" ] || ok=false
    grep -qF 'its inner TDD chain is driven by another session' "$err" || ok=false
  fi
  B34_DETAIL="$B34_DETAIL $arm:rc=$rc,pointer=$( [ -e "$ptr" ] && echo present || echo absent)"
  [ "$ok" = true ]
}
B34_DETAIL=""
B34_OK=true
b34_arm refused || B34_OK=false
b34_arm control || B34_OK=false
if [ "$B34_OK" = true ]; then
  check "B34 the repair refuses a TDD_RUNNING run whose chain another session drives and installs nothing, while a chain this session drives still repairs" PASS
else
  check "B34 repair pending-stage refusal (${B34_DETAIL# })" FAIL
fi

# --- B24 owning a DIFFERENT live run refuses the repair, pointer untouched ------
# The guard is keyed on the owner-scoped INVENTORY, not on the pointer. Keying it on
# `activePointerFor` — which returns the owner-keyed pointer UNFILTERED — covered only
# the shape where a pointer happens to name the other run, and answered null on the
# legacy fallback, which is the shape that most needs the refusal. Either way the
# consequence is the same: the repair installs a pointer at this session's own key,
# orphaning the other run, after which `read-active` refuses with exit 2 for every
# consumer while the CLI has just reported a successful repair. The refusal must fire
# and the pointer must survive untouched.
SHD="$TMP/shadow"; mkdir -p "$SHD"
SHD="$(cd "$SHD" && pwd -P)"
activate_session "$SHD" adopt_shadow_owner || exit 1
SHD_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_shadow_live "$SHD_OWNER" "$SHD" >/dev/null 2>&1; then
  SHD_PTR="$(_autopilot_active_path "$SHD/.zensu/state" "$SHD_OWNER")"
  SHD_LIVE_FILE="$(autopilot_run_file adopt_shadow_live "$SHD")"
  SHD_OTHER_FILE="$(autopilot_run_file adopt_shadow_other "$SHD")"
  # A SECOND record owned by the same session. `begin` refuses to mint one, so it is
  # written by hand from the first — same owner, same project, a different run id.
  node -e '
    const fs = require("fs");
    const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    state.runId = "adopt_shadow_other";
    fs.writeFileSync(process.argv[2], JSON.stringify(state, null, 2) + "\n");
  ' "$SHD_LIVE_FILE" "$SHD_OTHER_FILE" 2>/dev/null
  B24_PTR_BEFORE="$(digest "$SHD_PTR")"
  run_verb "$SHD" adopt_shadow_owner --autopilot-adopt --run adopt_shadow_other --confirm \
    >/dev/null 2>"$TMP/b24.err"
  B24_RC=$?
  if [ -f "$SHD_OTHER_FILE" ] && [ "$B24_RC" -eq 4 ] \
    && grep -qF 'caller already owns nonterminal run adopt_shadow_live' "$TMP/b24.err" \
    && [ "$(digest "$SHD_PTR")" = "$B24_PTR_BEFORE" ] \
    && json_ok "$SHD_PTR" 'value.runId === "adopt_shadow_live"'; then
    check "B24 owning a different live run refuses the repair with exit 4 and leaves the pointer intact" PASS
  else
    check "B24 shadowed-pointer refusal (rc=$B24_RC expected 4, stderr: $(head -c 160 "$TMP/b24.err" 2>/dev/null))" FAIL
  fi
else
  check "B24 fixture could not build a shadowed-pointer run" FAIL
fi

# --- B35 an unsafe path at the taker's own pointer is refused before any write -
# The `regular-or-absent` pre-check guards the second writer of the owner-keyed
# pointer, and until this case its only pin was a source grep. Without the guard the
# same directory surfaces much later as a pointer-install exit 5, so the discriminator
# is the exit code together with the named refusal, plus both files left byte-identical.
UNS="$TMP/unsafe-pointer"; mkdir -p "$UNS"
UNS="$(cd "$UNS" && pwd -P)"
activate_session "$UNS" adopt_uns_owner || exit 1
UNS_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_uns_run "$UNS_OWNER" "$UNS" >/dev/null 2>&1; then
  UNS_RUN_FILE="$(autopilot_run_file adopt_uns_run "$UNS")"
  UNS_OWNER_PTR="$(_autopilot_active_path "$UNS/.zensu/state" "$UNS_OWNER")"
  activate_session "$UNS" adopt_uns_taker || exit 1
  UNS_TAKER_PTR="$(_autopilot_active_path "$UNS/.zensu/state" "$ZENSU_SESSION_KEY")"
  mkdir -p "$UNS_TAKER_PTR"
  B35_RUN_BEFORE="$(digest "$UNS_RUN_FILE")"
  B35_PTR_BEFORE="$(digest "$UNS_OWNER_PTR")"
  run_verb_cfg "$UNS" adopt_uns_taker "$TMP/ttl-zero.json" \
    --autopilot-adopt --run adopt_uns_run --confirm >/dev/null 2>"$TMP/b35.err"
  B35_RC=$?
  if [ -d "$UNS_TAKER_PTR" ] && [ "$B35_RC" -eq 2 ] \
    && grep -qF 'the owner pointer path was refused: not a regular file or an absent path inside the state directory' "$TMP/b35.err" \
    && [ "$(digest "$UNS_RUN_FILE")" = "$B35_RUN_BEFORE" ] \
    && [ "$(digest "$UNS_OWNER_PTR")" = "$B35_PTR_BEFORE" ]; then
    check "B35 a directory at the taker's pointer path is refused with exit 2 and a named cause, leaving the record and the previous owner's pointer untouched" PASS
  else
    check "B35 caller-pointer pre-check (rc=$B35_RC expected 2, stderr: $(head -c 160 "$TMP/b35.err" 2>/dev/null))" FAIL
  fi
else
  check "B35 fixture could not build an unsafe-pointer run" FAIL
fi

# --- B20 a broken TTL read falls back to the default, not to 0 ---------------
# 0 disables the liveness check, so normalizing a getter FAULT to it would fail
# open on a guard that also gates the destructive verb. Source-pinned: the fault
# is not reachable through the CLI while the getter returns its own default.
# Each verb reads its OWN window, so each fallback is judged inside its own function:
# the verb must call its own getter, and its normalization must fall back to THAT
# getter's default operand, DERIVED from the config library so a changed default turns
# this red instead of leaving a stale hand copy green. Scoping per function is what
# catches a swap of the two getters, which a file-wide count cannot see. The negative
# arm matches any `ttl_hours=0` normalization, not one exact spelling.
b20_body() { awk -v f="$1" '$0 ~ "^" f "\\(\\) *\\{" { p = 1 } p { print } p && /^\}$/ { exit }' "$LIB"; }
B20_OK=true
B20_DETAIL=""
for B20_PAIR in autopilot_adopt_run:zensu_autopilot_owner_activity_ttl_hours \
  autopilot_release_run:zensu_autopilot_release_owner_activity_ttl_hours; do
  B20_VERB="${B20_PAIR%%:*}"
  B20_GETTER="${B20_PAIR#*:}"
  B20_DEFAULT="$(sed -n "s/^${B20_GETTER}().*_zensu_config_bounded_int [A-Za-z]* \([0-9][0-9]*\) .*/\1/p" "$CFG")"
  B20_BODY="$(b20_body "$B20_VERB")"
  B20_CALLS="$(printf '%s\n' "$B20_BODY" | grep -cF "ttl_hours=\"\$(${B20_GETTER} 2>/dev/null)\"" || true)"
  B20_SITES="$(printf '%s\n' "$B20_BODY" | grep -cF "ttl_hours=${B20_DEFAULT} ;; esac" || true)"
  B20_DETAIL="$B20_DETAIL $B20_VERB:default=${B20_DEFAULT:-none},calls=${B20_CALLS:-0},sites=${B20_SITES:-0}"
  [ -n "$B20_DEFAULT" ] && [ -n "$B20_BODY" ] || B20_OK=false
  [ "${B20_CALLS:-0}" -eq 1 ] && [ "${B20_SITES:-0}" -eq 1 ] || B20_OK=false
done
B20_ZERO_SITES="$(grep -cE 'ttl_hours=0[[:space:]]*;;' "$LIB" || true)"
[ "${B20_ZERO_SITES:-0}" -eq 0 ] || B20_OK=false
if [ "$B20_OK" = true ]; then
  check "B20 each verb reads its own window getter and falls back to that getter's default, never to the disabling 0" PASS
else
  check "B20 TTL fallback (${B20_DETAIL# }, zero-sites=${B20_ZERO_SITES:-0} expected 0)" FAIL
fi

# --- B23 a project with no run storage refuses with exit 1 -------------------
# The skill documents this code, so the suite must be able to produce it; B21 below
# grades the table against exactly what was measured.
NOSTORE="$TMP/nostore"; mkdir -p "$NOSTORE"
NOSTORE="$(cd "$NOSTORE" && pwd -P)"
activate_session "$NOSTORE" adopt_nostore_taker || exit 1
NOSTORE_KEY="$ZENSU_SESSION_KEY"
# The shell entry is driven directly: `run_verb` re-activates the session, and the
# baseline recreates the very state directory this check needs to be absent.
rm -rf "$NOSTORE/.zensu/state"
( cd "$NOSTORE" && autopilot_adopt_run adopt_absent_run "$NOSTORE" "$NOSTORE_KEY" confirm ) >/dev/null 2>&1
B23_RC=$?
if [ "$B23_RC" -eq 1 ]; then
  check "B23 a project with no run storage refuses with exit 1" PASS
else
  check "B23 missing run storage (rc=$B23_RC, expected 1)" FAIL
fi

# --- B27 the named-refusal channel is BEHAVIOURALLY reachable -----------------
# Round 6 found `_autopilot_adopt_refusal` — the whole point of which is that a
# state-class refusal names itself — covered by nothing at all: no assertion, no
# source pin, no needle anywhere in `tests/`. Changing its one `>&2` to
# `>/dev/null` silenced eight refusal paths with the entire suite green, while
# `skills/autopilot-adopt/SKILL.md` went on teaching the reader to discriminate on
# the line's presence. B23 drove one of those paths and discarded stderr.
#
# This drives the SAME path B23 drives and CAPTURES the channel, so the two grade
# different halves of one invocation: B23 the exit code, B27 the sentence and the
# stream it travels on.
B27_ERR="$TMP/b27.err"
( cd "$NOSTORE" && autopilot_adopt_run adopt_absent_run "$NOSTORE" "$NOSTORE_KEY" confirm ) >/dev/null 2>"$B27_ERR"
B27_RC=$?
B27_OK=true
[ "$B27_RC" -eq 1 ] || B27_OK=false
grep -qF '[zensu-autopilot-state] --autopilot-adopt refused: ' "$B27_ERR" || B27_OK=false
# The rc=1 arm must NOT claim corruption. An absent `.zensu/state` is what a fresh
# clone, a `git clean` and a removed worktree all produce, and the exit-1 row says
# so; asserting an unsafe directory there sent the reader hunting for a planted
# symlink that was never there.
grep -qF 'this project holds no Autopilot run storage' "$B27_ERR" || B27_OK=false
grep -qF 'the run record is unreadable or the state directory is unsafe' "$B27_ERR" && B27_OK=false
# The refusal travels on stderr, never stdout: stdout is the worker's own
# `<basename>\t<owner>` protocol channel and a diagnostic must not enter it.
B27_OUT="$( ( cd "$NOSTORE" && autopilot_adopt_run adopt_absent_run "$NOSTORE" "$NOSTORE_KEY" confirm ) 2>/dev/null )"
[ -z "$B27_OUT" ] || B27_OK=false
if [ "$B27_OK" = true ]; then
  check "B27 a state-class refusal names itself on stderr, distinguishes absent storage from an unsafe one, and writes nothing to stdout" PASS
else
  check "B27 named-refusal channel (rc=$B27_RC, stderr=$(tr -d '\n' < "$B27_ERR" | cut -c1-120))" FAIL
fi

# --- B22 a tabless worker line is a protocol fault, not a silent repair --------
# The SINGLE legitimate exit-0 worker path emits a TAB, so a tabless line is a lost
# or short stdout write rather than an outcome. The three successes are separated by
# exit code — the repair exits 11 and writes no stdout at all — never by a token
# inside stdout. Without the refusal a lost takeover line would reach the shell as
# an empty basename and an empty previous owner, and the retire plus the provenance
# write would both be silently skipped under exit 0. Source-pinned: producing a lost
# pipe write on demand is not reachable from a fixture, so the discriminator is
# graded instead.
B22_OK=true
# The tabless arm is multi-line since round 6, because it now NAMES its cause
# instead of returning bare. Pin the two halves that matter — the cleanup and
# the code — rather than a one-line spelling that a reword breaks for no reason.
grep -qF 'the worker result line was malformed; no install was attempted and nothing moved' "$LIB" || B22_OK=false
grep -qF 'the worker result line named no previous owner; no install was attempted and nothing moved' "$LIB" || B22_OK=false
[ "$(grep -c 'rm -f "$run_tmp" "$ptr_tmp"' "$LIB")" -ge 2 ] || B22_OK=false
# The three success outcomes are separated by EXIT CODE, never by a token inside
# stdout: an exit code cannot be produced by a dropped write, so a lost takeover
# line lands in the protocol fault above instead of impersonating a repair.
grep -qF 'process.exit(11);' "$LIB" || B22_OK=false
grep -qF 'ZENSU_AUTOPILOT_ADOPT_OUTCOME=already-owned' "$LIB" || B22_OK=false
# The two install-dependent outcomes are STAGED and published only after both
# atomic replaces land, so a failed install can no longer announce — or record
# provenance for — a takeover that did not happen. Pin the staging spelling AND the
# publication, because either one alone is satisfied by the defect: staging without
# publishing loses the outcome entirely, publishing without staging is the original
# too-early assignment. `already-owned` above is deliberately NOT staged; it returns
# before any install and has nothing to wait for.
grep -qF 'pending_outcome=repaired' "$LIB" || B22_OK=false
grep -qF 'pending_outcome=adopted' "$LIB" || B22_OK=false
grep -qF 'ZENSU_AUTOPILOT_ADOPT_OUTCOME="$pending_outcome"' "$LIB" || B22_OK=false
grep -qF 'ZENSU_AUTOPILOT_ADOPTED_PREVIOUS_OWNER="$pending_owner"' "$LIB" || B22_OK=false
# ORDER is the whole property: the publication must sit BELOW both installs.
B22_PUB_LINE="$(grep -n 'ZENSU_AUTOPILOT_ADOPT_OUTCOME="$pending_outcome"' "$LIB" | head -1 | cut -d: -f1)"
# SCOPED to `_autopilot_adopt_critical`: eight functions install a run record with
# that same spelling, so a file-wide `head -1` compares the publication against an
# unrelated function and the order it asserts is not the one that matters.
B22_ADOPT_START="$(grep -n '^_autopilot_adopt_critical()' "$LIB" | head -1 | cut -d: -f1)"
# BOUNDED on the function's own closing brace as well as its opening line. An unbounded
# slice would run to end of file, and eight functions share the install spelling.
B22_ADOPT_END="$(awk -v s="$B22_ADOPT_START" 'NR>s && /^\}$/ { print NR; exit }' "$LIB")"
B22_RUN_INSTALL_LINE="$(awk -v s="$B22_ADOPT_START" -v e="$B22_ADOPT_END" 'NR>=s && NR<=e && /_tdd_atomic_replace_regular "\$run_tmp" "\$run_file"/ { print NR; exit }' "$LIB")"
# BOTH installs, not just the record one. The claim this check makes is that the
# publication sits below BOTH, and comparing against one of them is only equivalent
# while that one happens to be LAST — which the code comment beside the installs
# explicitly leaves open to reordering. Located separately and compared against the
# later of the two, the pin survives that reorder instead of silently inverting.
B22_PTR_INSTALL_LINE="$(awk -v s="$B22_ADOPT_START" -v e="$B22_ADOPT_END" 'NR>=s && NR<=e && /_tdd_atomic_replace_regular "\$ptr_tmp" "\$caller_pointer"/ { print NR; exit }' "$LIB")"
# `B22_ADOPT_START` is tested HERE and not only used: an empty anchor makes awk read
# `NR>=""` as true from line 1, so a renamed function silently reverts this check to the
# file-wide first match — the exact behaviour the comment above calls wrong — and the
# ordering assertion still passes against an unrelated function. A dead anchor must FAIL.
if [ -n "$B22_PUB_LINE" ] && [ -n "$B22_ADOPT_START" ] && [ -n "$B22_ADOPT_END" ] \
  && [ -n "$B22_RUN_INSTALL_LINE" ] && [ -n "$B22_PTR_INSTALL_LINE" ]; then
  B22_LAST_INSTALL="$B22_RUN_INSTALL_LINE"
  [ "$B22_PTR_INSTALL_LINE" -gt "$B22_LAST_INSTALL" ] && B22_LAST_INSTALL="$B22_PTR_INSTALL_LINE"
  [ "$B22_PUB_LINE" -gt "$B22_LAST_INSTALL" ] || B22_OK=false
else
  B22_OK=false
fi
grep -qF 'retiredBasename}\t${previousOwner}' "$LIB" || B22_OK=false
# No sentinel may come back: it is the shape this design replaced.
grep -qF 'pointer-repaired' "$LIB" && B22_OK=false
# All three outcomes name themselves to the operator, so silence is never one.
grep -qF 'was taken over from' "$LOG" || B22_OK=false
# The repair line names BOTH conditions the code repairs — a missing pointer AND one
# designating a run that has already finished — because the exit-4 refusal fires only
# for a NONTERMINAL shadowed run, so "missing" alone understated what it replaces.
grep -qF 'its owner pointer was missing or named a run that has already finished, and has been reinstalled' "$LOG" || B22_OK=false
grep -qF 'already designates it' "$LOG" || B22_OK=false
if [ "$B22_OK" = true ]; then
  check "B22 the three exit-0 outcomes are separated by exit code, a tabless line is refused, and each names itself on stderr" PASS
else
  check "B22 the exit-0 outcome discriminator or its protocol-fault refusal is missing" FAIL
fi

# --- B21b exit 5 is driven in-process on every install arm --------------------
# `_autopilot_adopt_critical` calls `_tdd_atomic_replace_regular` by name in the
# calling shell, so a subshell shadow reaches each install arm without breaking the
# filesystem. The shadow is keyed on the TARGET's shape rather than on call order, so
# an install the lease machinery performs cannot shift which call fails. Five arms:
# the pointer install fails; the record install fails with no earlier pointer and with
# one, both of which must roll the pointer back; the rollback itself fails; and the
# repair path, which has no record to install and must still report its repair.
eval "b21_real_install() $(declare -f _tdd_atomic_replace_regular | tail -n +2)"
B21B_POINTER_RC=""
B21B_DETAIL=""
b21_arm() {
  local arm="$1" project="$TMP/b21-$1" owner owner_ptr caller caller_ptr run run_file
  local prior_digest="" owner_ptr_digest run_digest out rc outcome err mark ok=true
  mkdir -p "$project" && project="$(cd "$project" && pwd -P)" || return 1
  run="adopt_b21_$arm"
  err="$TMP/b21-$arm.err"
  mark="$TMP/b21-$arm.record-install-attempted"
  if [ "$arm" = prior ] || [ "$arm" = stuck ]; then
    activate_session "$project" "adopt_b21_${arm}_taker" || return 1
    autopilot_begin_run "${run}_old" "$ZENSU_SESSION_KEY" "$project" >/dev/null 2>&1 || return 1
    autopilot_apply_event "${run}_old" evt-cancel CANCEL '{}' "$project" >/dev/null 2>&1 || return 1
  fi
  activate_session "$project" "adopt_b21_${arm}_owner" || return 1
  owner="$ZENSU_SESSION_KEY"
  autopilot_begin_run "$run" "$owner" "$project" >/dev/null 2>&1 || return 1
  run_file="$(autopilot_run_file "$run" "$project")"
  owner_ptr="$(_autopilot_active_path "$project/.zensu/state" "$owner")"
  if [ "$arm" = repair ]; then
    rm -f "$owner_ptr"
    caller="$owner"
  else
    activate_session "$project" "adopt_b21_${arm}_taker" || return 1
    caller="$ZENSU_SESSION_KEY"
    owner_ptr_digest="$(digest "$owner_ptr")"
  fi
  caller_ptr="$(_autopilot_active_path "$project/.zensu/state" "$caller")"
  if [ "$arm" = prior ] || [ "$arm" = stuck ]; then
    json_ok "$caller_ptr" "value.runId === '${run}_old'" || return 1
    prior_digest="$(digest "$caller_ptr")"
  fi
  run_digest="$(digest "$run_file")"
  out="$(
    B21_PTR_CALLS=0
    _tdd_atomic_replace_regular() {
      case "$2" in
        (*/autopilot-run-*.json)
          : > "$mark"
          case "$arm" in (record|prior|stuck|repair) return 1 ;; esac
          ;;
        (*/autopilot-active-*.json)
          B21_PTR_CALLS=$((B21_PTR_CALLS + 1))
          [ "$arm" = pointer ] && return 1
          [ "$arm" = stuck ] && [ "$B21_PTR_CALLS" -ge 2 ] && return 1
          ;;
      esac
      b21_real_install "$@"
    }
    export ZENSU_CONFIG="$TMP/ttl-zero.json"
    cd "$project" || exit 99
    autopilot_adopt_run "$run" "$project" "$caller" confirm >/dev/null 2>"$err"
    printf '%s|%s' "$?" "${ZENSU_AUTOPILOT_ADOPT_OUTCOME:-}"
  )"
  rc="${out%%|*}"
  outcome="${out#*|}"
  case "$arm" in
    pointer)
      B21B_POINTER_RC="$rc"
      [ "$rc" = 5 ] && [ -z "$outcome" ] || ok=false
      grep -qF 'pointer install failed; nothing moved' "$err" || ok=false
      [ ! -e "$caller_ptr" ] || ok=false
      ;;
    record)
      [ "$rc" = 5 ] && [ -z "$outcome" ] || ok=false
      grep -qF 'record install failed; the owner pointer was rolled back and nothing moved' "$err" || ok=false
      [ ! -e "$caller_ptr" ] || ok=false
      ;;
    prior)
      [ "$rc" = 5 ] && [ -z "$outcome" ] || ok=false
      grep -qF 'record install failed; the owner pointer was rolled back and nothing moved' "$err" || ok=false
      [ -f "$caller_ptr" ] && [ "$(digest "$caller_ptr")" = "$prior_digest" ] || ok=false
      ;;
    stuck)
      [ "$rc" = 5 ] && [ -z "$outcome" ] || ok=false
      grep -qF 'record install failed and rolling back the owner pointer also failed' "$err" || ok=false
      json_ok "$caller_ptr" "value.runId === '$run'" || ok=false
      ;;
    repair)
      [ "$rc" = 0 ] && [ "$outcome" = repaired ] || ok=false
      [ ! -e "$mark" ] || ok=false
      json_ok "$caller_ptr" "value.runId === '$run'" || ok=false
      ;;
  esac
  [ "$(digest "$run_file")" = "$run_digest" ] || ok=false
  if [ "$arm" != repair ]; then
    [ "$(digest "$owner_ptr")" = "$owner_ptr_digest" ] || ok=false
  fi
  B21B_DETAIL="$B21B_DETAIL $arm:rc=$rc,outcome=${outcome:-none},ptr=$( [ -e "$caller_ptr" ] && echo present || echo absent)"
  [ "$ok" = true ]
}
B21B_OK=true
for B21B_ARM in pointer record prior stuck repair; do
  b21_arm "$B21B_ARM" || B21B_OK=false
done
if [ "$B21B_OK" = true ]; then
  check "B21b every install arm is driven: a failed pointer install moves nothing, a failed record install rolls the pointer back or says it could not, and a repair reports itself without a record install" PASS
else
  check "B21b install arms (${B21B_DETAIL# })" FAIL
fi

# --- B21 the skill's exit-code table matches the codes this suite measured ----
# B14 pins registration only. The table is what a model reads before running a
# state-mutating verb, so every row must name a code the verb actually returns.
# The code list is EXTRACTED from the skill's own table rather than hardcoded: a
# hardcoded list turns the check's name — a universal over what the skill documents
# — into a fixed sample, so a row naming a code the verb never returns would pass.
# DEFINED here, beside the B21b arms it continues, and CALLED at the very end of this
# file. It reads the VALUES of this suite's rc variables, so a variable assigned below
# the call contributes nothing: `B25_RC` and `B30_RC` sit further down and were both
# silently absent from the population while the scan itself looked total.
b21_report() {
B21_DOCUMENTED="$(sed -n 's/^| *\([0-9][0-9]*\) *|.*/\1/p' "$SKILL" | tr '\n' ' ')"
# Every documented code is measured, exit 5 included: B21b drives it in-process
# through a shadowed install, so no code needs an undriven allowance. B23 above exists
# for the same reason on exit 1.
# `$B2_RC` carries the INVOCATION-fault 2, which `$B1_RC` used to carry: a call with
# no `--confirm` is a read-only report now, not a usage error, so B1 measures 7 and
# the only remaining producer of 2 in this suite's own commands is a malformed flag.
# DERIVED, not hand-listed. This was an eleven-variable string typed by hand, and a
# hand-curated census beside a derived forward direction is the half-pinned shape that
# reads greener than an unpinned one: the "documented-but-unmeasured" arm above really
# does come from the skill's own table, so the pair LOOKED symmetric while this half
# only ever iterated whatever someone remembered to add.
#
# It was also wrong in BOTH directions, which is why the fix is derivation rather than
# a longer list. The retired string named `$B5_RC`, `$B11_RC` and `$B18_RC` while
# `B4_RC`, `B4B_RC`, `B8_OLD_RC` and `B27_RC` were absent from it. Extending the list by
# hand would have repeated the defect one round later — and the first derivation
# repeated it anyway from the other side: it anchored the scan at column zero, so those
# same three names, all assigned indented, stayed out of the population it built.
#
# The population comes from the suite's own source: every `<name>_RC=` assignment,
# wherever it sits on the line. Anchoring it at column zero was the same defect one
# layer down — it collected 13 of the 34 such variables this file assigns, because an
# assignment inside a conditional block, a function body or a command substitution is
# indented, so `B5_RC`, `B11_RC` and `B18_RC` were missing for exactly the reason the
# retired hand-list had them wrong. `eval` is what reads them, and it is safe here
# because the names are matched to `[A-Z0-9_]*_RC` first, so nothing but an identifier
# this file assigns can reach it.
# SCOPED to the CLI layer. `B4B_RC` is excluded by name and the reason is not a
# convenience: `B4b` captures the WORKER's pre-collapse exit 10 deliberately, asserting
# it at its own layer, and `zensu-log.sh` collapses 0/10/11 to a single 0 before any
# caller sees one. The skill's table documents the codes the COMMAND returns, so 10 is
# not an undocumented CLI exit — it is a worker code that never reaches a CLI table.
# Sweeping it in made the derivation report a gap that does not exist. This exclusion
# narrows the population with a stated cause; it must never be extended to silence a
# code the CLI really can return.
B21_EXCLUDED='^B4B_RC$'
B21_NAMES="$(grep -oE '(^|[[:space:]]|;|\()[A-Z0-9_]+_RC=' "$0" | sed 's/^[^A-Z]*//;s/=$//' | sort -u | grep -vE "$B21_EXCLUDED")"
B21_MEASURED=" "
for b21_var in $B21_NAMES; do
  eval "b21_val=\${$b21_var:-}"
  case "$b21_val" in
    ''|*[!0-9]*) continue ;;
  esac
  case "$B21_MEASURED" in *" $b21_val "*) continue ;; esac
  B21_MEASURED="$B21_MEASURED$b21_val "
done
# Fail loudly rather than vacuously: an empty derivation means the scan stopped
# matching, and a universal over an empty set passes while grading nothing.
if [ -z "$(printf '%s' "$B21_MEASURED" | tr -d ' ')" ]; then
  check "B21pre-measured the rc-variable scan yielded no codes — the derivation, not the verb, is broken" FAIL
else
  check "B21pre-measured the rc-variable scan yields codes, so the reverse comparison below is not vacuous" PASS
fi
# A non-empty derivation is not enough either, and that is the lesson the anchored scan
# taught: it was non-empty throughout and still missed two thirds of its population. The
# FLOOR is the same scan with no position rule at all, which no assignment spelling can
# escape — so a scan that stops seeing one form fails here rather than quietly grading a
# smaller world.
B21_UNBOUNDED="$(grep -oE '[A-Z0-9_]+_RC=' "$0" | sed 's/=$//' | sort -u | grep -vE "$B21_EXCLUDED")"
B21_NAME_COUNT="$(printf '%s\n' "$B21_NAMES" | grep -c '[A-Z]')"
B21_FLOOR_COUNT="$(printf '%s\n' "$B21_UNBOUNDED" | grep -c '[A-Z]')"
if [ "$B21_NAME_COUNT" -gt 0 ] && [ "$B21_NAME_COUNT" -eq "$B21_FLOOR_COUNT" ]; then
  check "B21pre-population the scan collects every rc variable this file assigns" PASS
else
  check "B21pre-population the scan collects every rc variable this file assigns (collected $B21_NAME_COUNT of $B21_FLOOR_COUNT; difference: $(printf '%s\n%s\n' "$B21_NAMES" "$B21_UNBOUNDED" | sort | uniq -u | tr '\n' ' '))" FAIL
fi
if [ -z "$(printf '%s' "$B21_DOCUMENTED" | tr -d ' ')" ]; then
  check "B21pre the skill's exit table yielded no codes — the extraction, not the table, is broken" FAIL
else
  check "B21pre the skill's exit table yields codes, so the comparison below is not vacuous" PASS
fi
B21_MISSING=""
for code in $B21_DOCUMENTED; do
  case "$B21_MEASURED" in *" $code "*) continue ;; esac
  B21_MISSING="$B21_MISSING documented-but-unmeasured:$code"
done
# The other direction too: a code this suite measures and the skill omits is a gap
# in the model-facing contract, which is what B14 alone could never see.
for code in $(printf '%s' "$B21_MEASURED" | tr ' ' '\n' | grep -v '^$' | sort -u); do
  case " $B21_DOCUMENTED " in *" $code "*) ;; *) B21_MISSING="$B21_MISSING measured-but-undocumented:$code" ;; esac
done
if [ -z "$B21_MISSING" ]; then
  check "B21 the skill's documented exit codes and the codes this suite measured are the same set" PASS
else
  check "B21 skill exit-code table vs measured codes:$B21_MISSING" FAIL
fi
}

# --- B25 the LEGACY owner pointer is retired by an adopt too ------------------
# Every other successful-adopt fixture gives the previous owner an owner-KEYED pointer,
# so `retired` is always the 64-hex form and the legacy admission in the shell shape
# check had no executed case: deleting it — and the resolver arm that emits the name —
# left the whole suite green while reinstating the defect they were added to fix, a
# derived basename naming nothing whenever the legacy fallback won.
B25P="$TMP/legacyptr"; mkdir -p "$B25P"
B25P="$(cd "$B25P" && pwd -P)"
if activate_session "$B25P" adopt_legacy_owner \
  && autopilot_begin_run adopt_legacy_run "$ZENSU_SESSION_KEY" "$B25P" >/dev/null 2>&1; then
  B25_OWNER="$ZENSU_SESSION_KEY"
  B25_RUN_FILE="$(autopilot_run_file adopt_legacy_run "$B25P")"
  B25_KEYED="$(_autopilot_active_path "$B25P/.zensu/state" "$B25_OWNER")"
  B25_LEGACY="$(_autopilot_legacy_active_path "$B25P/.zensu/state")"
  # Move the pointer the writer produced onto the pre-scoping name, so the previous
  # owner holds ONLY the legacy spelling — the shape the resolver's fallback exists for.
  # The legacy pointer still DESIGNATES the run, so the liveness guard is armed and the
  # fresh owner beacon would refuse with exit 7 before the retire path is ever reached.
  # Removing the beacon is the abandonment signal, and it doubles as the only END-TO-END
  # case for the absent-document disclosure — asserted below, since a guard that stands
  # down silently is what this round added the line for.
  B25_BEACON="$B25P/.zensu/state/tdd-phase-${B25_OWNER}.json"
  rm -f "$B25_BEACON"
  if [ -f "$B25_KEYED" ] && mv "$B25_KEYED" "$B25_LEGACY" 2>/dev/null; then
    run_verb "$B25P" adopt_legacy_taker --autopilot-adopt --run adopt_legacy_run --confirm \
      >/dev/null 2>"$TMP/b25.err"
    B25_RC=$?
    B25_TAKER="$ZENSU_SESSION_KEY"
    B25_TAKER_PTR="$(_autopilot_active_path "$B25P/.zensu/state" "$B25_TAKER")"
    if [ "$B25_RC" -eq 0 ] \
      && json_ok "$B25_RUN_FILE" "value.ownerSessionId === '$B25_TAKER'" \
      && [ ! -f "$B25_LEGACY" ] && [ -f "$B25_TAKER_PTR" ] \
      && grep -qF 'owner liveness unchecked: no workflow document for the recorded owner' "$TMP/b25.err" \
      && ! grep -qF 'previous owner pointer not retired' "$TMP/b25.err"; then
      check "B25 an adopt retires a LEGACY previous-owner pointer, installs the caller's, and discloses the unchecked liveness" PASS
    else
      check "B25 legacy-pointer adopt (rc=$B25_RC, legacy=$( [ -f "$B25_LEGACY" ] && echo present || echo gone))" FAIL
    fi
  else
    check "B25 fixture could not move the owner pointer onto its legacy name" FAIL
  fi
else
  check "B25 fixture could not build a legacy-pointer run" FAIL
fi

# --- B26 both retire-unreachable arms are driven on a real takeover -----------
# Both arms are selected in the calling shell — the refused-shape arm by a by-name call
# to `_autopilot_owner_pointer_basename_ok`, the failed-unlink arm by `rm` — so a
# subshell shadow of either reaches it. The fixture keeps the previous owner's pointer,
# the only shape in which a retire happens at all, and the ttl-zero config lets the
# takeover land without a clock deciding it. The disclosure must name the CONSEQUENCE,
# because the surviving pointer is what makes the previous owner's own read refuse.
b26_arm() {
  local arm="$1" project="$TMP/b26-$1" owner owner_ptr taker err rc read_rc said=no ok=true
  mkdir -p "$project" && project="$(cd "$project" && pwd -P)" || return 1
  activate_session "$project" "adopt_b26_${arm}_owner" || return 1
  owner="$ZENSU_SESSION_KEY"
  autopilot_begin_run "adopt_b26_$arm" "$owner" "$project" >/dev/null 2>&1 || return 1
  owner_ptr="$(_autopilot_active_path "$project/.zensu/state" "$owner")"
  [ -f "$owner_ptr" ] || return 1
  activate_session "$project" "adopt_b26_${arm}_taker" || return 1
  taker="$ZENSU_SESSION_KEY"
  err="$TMP/b26-$arm.err"
  (
    if [ "$arm" = shape ]; then
      _autopilot_owner_pointer_basename_ok() { return 1; }
    else
      rm() { if [ "$#" -eq 2 ] && [ "$2" = "$owner_ptr" ]; then return 1; fi; command rm "$@"; }
    fi
    export ZENSU_CONFIG="$TMP/ttl-zero.json"
    cd "$project" && autopilot_adopt_run "adopt_b26_$arm" "$project" "$taker" confirm
  ) >/dev/null 2>"$err"
  rc=$?
  autopilot_read_active "$project" "$owner" >/dev/null 2>&1
  read_rc=$?
  [ "$rc" -eq 0 ] || ok=false
  json_ok "$(autopilot_run_file "adopt_b26_$arm" "$project")" "value.ownerSessionId === '$taker'" || ok=false
  grep -qF "previous owner pointer not retired: $(basename "$owner_ptr")" "$err" \
    && grep -qF 'active pointer references a run that is absent or owned by another session' "$err" \
    && said=yes
  [ "$said" = yes ] || ok=false
  [ -f "$owner_ptr" ] || ok=false
  [ "$read_rc" -eq 2 ] || ok=false
  B26_DETAIL="$B26_DETAIL $arm:rc=$rc,read=$read_rc,said=$said,ptr=$( [ -f "$owner_ptr" ] && echo kept || echo gone)"
  [ "$ok" = true ]
}
B26_DETAIL=""
B26_OK=true
b26_arm shape || B26_OK=false
b26_arm unlink || B26_OK=false
if [ "$B26_OK" = true ]; then
  check "B26 a refused basename and a failed unlink each keep the previous owner's pointer, land the takeover, and disclose the consequence the previous owner's read then shows" PASS
else
  check "B26 retire-unreachable arms (${B26_DETAIL# })" FAIL
fi

# --- B28 the two round-6 refusal texts exist and are DISTINCT ------------------
# Control for B27's negative arm: both messages must be real strings in the library,
# or B27's `grep -qF ... && FAIL` would pass for the trivial reason that neither is
# ever emitted by anything.
B28_OK=true
grep -qF 'this project holds no Autopilot run storage' "$LIB" || B28_OK=false
grep -qF 'the run record is unreadable or the state directory is unsafe' "$LIB" || B28_OK=false
# Every refusal the shell half takes on its own must NAME itself. Four of them were
# bare `return`s until round 6, one of which was a regression the round-5 fix
# introduced, replacing a worker line that DID print with silence. The first needle
# below is now emitted at TWO layers — the critical section and the public entry — so
# the call census beneath this loop counts it twice on purpose.
for B28_NEEDLE in \
  'the adoption mode operand is required' \
  'the adoption mode is neither confirm nor report' \
  'the run id is not a schema identifier' \
  'the caller session id is not a persistable owner identity' \
  'the worker result line was malformed; no install was attempted and nothing moved' \
  'the worker result line named no previous owner; no install was attempted and nothing moved' \
  'the project root could not be resolved' \
  'the caller working tree could not be resolved' \
  'the owner pointer path could not be derived for this caller' \
  'the owner pointer path was refused' \
  'temp allocation beside the run record failed; nothing moved' \
  'temp allocation beside the owner pointer failed; nothing moved' \
  'pointer install failed; nothing moved' \
  'temp allocation for the owner pointer rollback copy failed; nothing moved' \
  'the existing owner pointer could not be copied for rollback; nothing moved' \
  'record install failed; the owner pointer was rolled back and nothing moved' \
  'record install failed and rolling back the owner pointer also failed'; do
  grep -qF "$B28_NEEDLE" "$LIB" || B28_OK=false
done
# The shared lock dispatcher serves EVERY verb, so its line must stay verb-neutral —
# naming this verb there would mislabel a release or a begin refusal.
# BOTH arms. The line branches on an empty run id, and pinning only the named arm
# left the verb-neutrality invariant unenforced on exactly the arm that was added
# with it — five callers reach that one, and they are the Stop-hook paths.
grep -qF 'refused under the project lock: run storage for' "$LIB" || B28_OK=false
grep -qF 'refused under the project lock: run storage in this project is unsafe' "$LIB" || B28_OK=false
# The call count is compared against an INDEPENDENT literal. Every call site is a
# one-line call with a quoted message, so a count derived from the file drops in
# lockstep with a deleted call site and cannot catch one. Adding or removing a call
# site must update B28_REFUSAL_CALLS_EXPECTED in the same commit. The USES equality
# stays beside it for the other failure: a call spelled without the double quote the
# CALLS count keys on. Its `+ 1` is the comment in the shared lock dispatcher.
B28_REFUSAL_CALLS_EXPECTED=20
B28_REFUSAL_USES="$(grep -c '_autopilot_adopt_refusal' "$LIB")"
B28_REFUSAL_CALLS="$(grep -c '_autopilot_adopt_refusal "' "$LIB")"
B28_REFUSAL_DEF="$(grep -c '^_autopilot_adopt_refusal()' "$LIB")"
[ "$B28_REFUSAL_DEF" -eq 1 ] || B28_OK=false
[ "$B28_REFUSAL_CALLS" -eq "$B28_REFUSAL_CALLS_EXPECTED" ] || B28_OK=false
[ "$B28_REFUSAL_USES" -eq "$((B28_REFUSAL_CALLS + B28_REFUSAL_DEF + 1))" ] || B28_OK=false
if [ "$B28_OK" = true ]; then
  check "B28 every shell-half refusal names its own cause and the shared lock dispatcher stays verb-neutral" PASS
else
  check "B28 a shell-half refusal is missing its named cause" FAIL
fi

# --- B29 the basename shape gate REFUSES, not just accepts ---------------------
# B25 and B12b exercise its two accepting arms and B26 pins its consumer; nothing
# drove a name it must reject, so deleting the character class left every check
# green while the gate that stops a record-supplied basename from naming a file
# outside the state directory was gone.
B29_OK=true
_autopilot_owner_pointer_basename_ok 'autopilot-active.json' || B29_OK=false
_autopilot_owner_pointer_basename_ok "autopilot-active-$(printf 'a%.0s' $(seq 64)).json" || B29_OK=false
# Refusals: traversal, a short key, a non-hex key, a separator inside the key, and
# an empty name.
_autopilot_owner_pointer_basename_ok '../evil.json' && B29_OK=false
_autopilot_owner_pointer_basename_ok "autopilot-active-$(printf 'a%.0s' $(seq 63)).json" && B29_OK=false
_autopilot_owner_pointer_basename_ok "autopilot-active-$(printf 'g%.0s' $(seq 64)).json" && B29_OK=false
_autopilot_owner_pointer_basename_ok "autopilot-active-$(printf 'a%.0s' $(seq 32))/$(printf 'a%.0s' $(seq 31)).json" && B29_OK=false
_autopilot_owner_pointer_basename_ok '' && B29_OK=false
if [ "$B29_OK" = true ]; then
  check "B29 the owner-pointer basename gate accepts both legitimate shapes and refuses traversal, a short, non-hex or separator-bearing key, and an empty name" PASS
else
  check "B29 the owner-pointer basename shape gate accepts or refuses the wrong names" FAIL
fi

# --- B30 the FOURTH liveness stand-down is asserted ---------------------------
# Three of the four stand-down lines had a value-bearing assertion (future-dated at
# B6c, TTL-0 at B12b, absent beacon at B25). The fourth — a pointer that no longer
# designates the run — is reached by MOST successful adopts in this suite (B3, B7,
# B17 all unlink the previous owner's pointer first) and asserted by none of them,
# because all three discard stderr. Its own code comment calls it the one stand-down
# an outsider reaches by unlinking an ordinary file, which is exactly why it must
# say so out loud.
B30="$TMP/b30"; mkdir -p "$B30"
B30="$(cd "$B30" && pwd -P)"
activate_session "$B30" adopt_b30_owner || exit 1
B30_OWNER="$ZENSU_SESSION_KEY"
if autopilot_begin_run adopt_b30_run "$B30_OWNER" "$B30" false true >/dev/null 2>&1; then
  # Retire the previous owner's pointer, and keep its beacon FRESH: the pointer arm
  # is what must decide here, so a stale or absent beacon would let a different arm
  # reach the same verdict and the check would prove nothing.
  rm -f "$(_autopilot_active_path "$B30/.zensu/state" "$B30_OWNER")"
  : > "$B30/.zensu/state/tdd-phase-$B30_OWNER.json"
  activate_session "$B30" adopt_b30_taker || exit 1
  B30_TAKER="$ZENSU_SESSION_KEY"
  B30_ERR="$TMP/b30.err"
  ( cd "$B30" && autopilot_adopt_run adopt_b30_run "$B30" "$B30_TAKER" confirm ) >/dev/null 2>"$B30_ERR"
  B30_RC=$?
  B30_OK=true
  [ "$B30_RC" -eq 0 ] || B30_OK=false
  grep -qF "owner liveness unchecked: the previous owner's active pointer no longer designates this run" "$B30_ERR" || B30_OK=false
  # NO age-based discriminator here, and the reason is worth stating: the pointer
  # arm is evaluated BEFORE any beacon read, so with the pointer retired the worker
  # never enters the branch that could emit an age-based line. An earlier spelling
  # asserted that line ABSENT and called it a discriminator — it could not fire, and
  # the fresh beacon it wrote was never read. What discriminates instead is that the
  # pointer line is the one emitted, which the positive assertion above already
  # grades. The beacon is still written, so the fixture stays honest about the state
  # it builds rather than leaving the file absent and the arms ambiguous.
  if [ "$B30_OK" = true ]; then
    check "B30 a retired owner pointer stands the liveness check down and says so, with the beacon still fresh" PASS
  else
    check "B30 fourth stand-down (rc=$B30_RC, stderr=$(tr -d '\n' < "$B30_ERR" | cut -c1-140))" FAIL
  fi
else
  check "B30 could not arm the fixture run — environment, not product" FAIL
fi

# --- B31 the write vocabulary is the INTERSECTION, driven by discriminating ids -
# Every fixture session id in this tree is `scv1_<64 hex>`, which satisfies BOTH
# halves, so nothing distinguished the intersection from either half alone:
# replacing the gate with `_autopilot_session_id_ok` OR with `_autopilot_identifier_ok`
# left the whole tree green. These ids are the discriminators the predicate's own
# comment names. The project must RESOLVE, or the root check above the gate refuses
# first and every arm passes for the wrong reason — hence B30's tree, not a bare one.
B31_OK=true
b31_gate() { ( cd "$B30" && autopilot_adopt_run adopt_b30_run "$B30" "$1" confirm ) >/dev/null 2>&1; printf '%s' "$?"; }
# `a.b` passes _autopilot_identifier_ok (dots are legal there) and FAILS
# _autopilot_session_id_ok, whose charset builds the pointer filename.
[ "$(b31_gate 'a.b')" -eq 3 ] || B31_OK=false
# `ab` passes _autopilot_session_id_ok and FAILS _autopilot_identifier_ok, whose
# minimum length is three.
[ "$(b31_gate 'ab')" -eq 3 ] || B31_OK=false
# `_abc` passes _autopilot_session_id_ok and FAILS _autopilot_identifier_ok, which
# requires an alphanumeric first character.
[ "$(b31_gate '_abc')" -eq 3 ] || B31_OK=false
# CONTROL: a value satisfying BOTH halves must not be refused by this gate. It gets
# past it and is refused further down for a different reason, so any code but 3
# proves the three refusals above came from the identity gate and not the fixture.
# NOTE the value: a DOT is legal in _autopilot_identifier_ok and ILLEGAL in
# _autopilot_session_id_ok, so `a.valid-owner_1` is refused by the intersection and
# would make this control assert the opposite of what it is named for.
[ "$(b31_gate 'valid-owner_1')" -ne 3 ] || B31_OK=false
# And the refusal names itself, so the round-5 regression this closes cannot return.
B31_ERR="$TMP/b31.err"
( cd "$B30" && autopilot_adopt_run adopt_b30_run "$B30" 'a.b' confirm ) >/dev/null 2>"$B31_ERR"
grep -qF 'the caller session id is not a persistable owner identity' "$B31_ERR" || B31_OK=false
if [ "$B31_OK" = true ]; then
  check "B31 the owner write gate refuses each half-satisfying id, admits one satisfying both, and names its cause" PASS
else
  check "B31 the owner write gate is not the intersection of the two vocabularies" FAIL
fi

b21_report

printf '%s\n' "----" "test-autopilot-adopt-cli: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
