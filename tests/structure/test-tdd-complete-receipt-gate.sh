#!/bin/bash
# --tdd-complete refuses without an edit-landing receipt.
#
# Phase 6 step 5b was a documented obligation: a model that simply forgot it lost
# nothing it could notice, and a claimed edit that never landed leaves no diff
# for any reviewer to catch. This turns the obligation into a precondition — the
# same move --chain-done already makes when it checks the working tree itself
# rather than asking the model whether the tree is clean.
#
# The load-bearing case is the LAST one: the library and the gate must agree on
# where the receipt lives. A harness session id and its on-disk state key are
# different strings, so this is exactly the seam where a plausible-looking
# implementation silently never gates.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

T_PASS=0; T_FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; T_PASS=$((T_PASS+1));
  else echo "  FAIL  $label"; T_FAIL=$((T_FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PROJ="$(mktemp -d)" || exit 1
export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$PROJ/.zensu/state"; export STATE_DIR
cleanup() { [ -n "${PROJ:-}" ] && rm -rf "$PROJ"; return 0; }
trap cleanup EXIT INT TERM
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN ZENSU_EDIT_LANDING_GATE 2>/dev/null || true

# The gate is scoped to a project that actually changed — same scoping as the
# --chain-done dirty-tree refusal. Give the session project a real git repo with
# one dirty file, or the gate is correctly out of scope and proves nothing.
git init -q --template= "$PROJ" >/dev/null 2>&1
printf 'v1\n' > "$PROJ/tracked.txt"
# Session state lands under .zensu/; real repos gitignore it, and an unignored
# state dir would make every tree dirty and every case look in-scope.
printf '.zensu/\n' > "$PROJ/.gitignore"
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
for SID in gate-refuse gate-accept gate-escape gate-integration gate-clean-tree; do
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID"
done

activate_session() {
  export CLAUDE_CODE_SESSION_ID="$1"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-session.sh"
  zensu_bind_model_session
}
# shellcheck disable=SC1090
source "$PHASE_LIB"

echo "== Scoping: a chain that changed nothing is out of scope =="
# Chain-mechanics suites drive --tdd-complete in hermetic projects that change no
# files. Forcing them to fabricate a receipt would buy nothing and would make the
# gate look enforced where there is no claim to verify. Checked FIRST, while the
# bound project is still clean.
# Session Control binds the project itself, so a live clean-tree session cannot
# be staged here — the real-world evidence is tests/structure/test-tdd-full-cycle.sh,
# which drives --tdd-complete in a clean hermetic project and stays green. What
# IS verifiable here is the predicate the gate scopes on: run the gate's own
# change-set expression against a clean fixture and require zero.
CLEAN_FIX="$(mktemp -d)" || exit 1
git init -q --template= "$CLEAN_FIX" >/dev/null 2>&1
printf 'v1\n' > "$CLEAN_FIX/a.txt"
printf '.zensu/\n' > "$CLEAN_FIX/.gitignore"
git -C "$CLEAN_FIX" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$CLEAN_FIX" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
mkdir -p "$CLEAN_FIX/.zensu/state"; printf '{}' > "$CLEAN_FIX/.zensu/state/probe.json"
CLEAN_COUNT="$( { git -C "$CLEAN_FIX" diff --name-only HEAD 2>/dev/null
                  git -C "$CLEAN_FIX" ls-files --others --exclude-standard 2>/dev/null; } \
                | sort -u | grep -c . )"
rm -rf "$CLEAN_FIX"
[ "$CLEAN_COUNT" -eq 0 ]
check "W1 the scoping predicate reports zero changes for a clean project (gate out of scope)" "$(verdict $?)"
awk '/--tdd-complete\)/,/;;/' "$LOG" | grep -qF 'ls-files --others --exclude-standard'
check "W2 the gate scopes itself on the same change set the terminus uses" "$(verdict $?)"

# From here on the project really changed, so the gate is in scope.
printf 'v2\n' > "$PROJ/tracked.txt"

receipt_for() {  # echo the path the GATE will look at for session $1
  local sf key
  sf="$(tdd_state_file "$1")"
  key="$(basename "$sf")"; key="${key#tdd-phase-}"; key="${key%.json}"
  printf '%s' "$(dirname "$sf")/edit-landing-${key}.json"
}

echo "== Refusal without a receipt =="
SID_R="gate-refuse"
activate_session "$SID_R"
bash "$LOG" --tdd-begin --session "$SID_R" >/dev/null 2>&1
ERR_R="$(bash "$LOG" --tdd-complete --session "$SID_R" 2>&1 >/dev/null)"
RC_R=$?
[ "$RC_R" -ne 0 ]
check "R1 --tdd-complete exits non-zero when no receipt exists" "$(verdict $?)"
printf '%s' "$ERR_R" | grep -qF 'no edit-landing receipt'
check "R2 the refusal names the missing receipt" "$(verdict $?)"
printf '%s' "$ERR_R" | grep -qF 'zensu-edit-landing.sh'
check "R3 the refusal names the command that produces it" "$(verdict $?)"
printf '%s' "$ERR_R" | grep -qF 'never landed leaves no diff'
check "R4 the refusal explains why the check exists, not just that it failed" "$(verdict $?)"
# Refusing must not have advanced the chain.
[ "$(tdd_get_flag "$(tdd_state_file "$SID_R")" implComplete)" != "true" ]
check "R5 a refused completion leaves implComplete unset" "$(verdict $?)"

echo "== Acceptance with a receipt =="
SID_A="gate-accept"
activate_session "$SID_A"
bash "$LOG" --tdd-begin --session "$SID_A" >/dev/null 2>&1
mkdir -p "$(dirname "$(receipt_for "$SID_A")")"
printf '{"schema":"edit-landing-v1","clean":true}\n' > "$(receipt_for "$SID_A")"
bash "$LOG" --tdd-complete --session "$SID_A" >/dev/null 2>&1
RC_A=$?
[ "$RC_A" -eq 0 ]
check "A1 --tdd-complete succeeds once the receipt is present" "$(verdict $?)"
[ "$(tdd_get_flag "$(tdd_state_file "$SID_A")" implComplete)" = "true" ]
check "A2 the accepted completion actually marks implComplete" "$(verdict $?)"

echo "== Escape hatch =="
SID_E="gate-escape"
activate_session "$SID_E"
bash "$LOG" --tdd-begin --session "$SID_E" >/dev/null 2>&1
ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --tdd-complete --session "$SID_E" >/dev/null 2>&1
[ $? -eq 0 ]
check "E1 ZENSU_EDIT_LANDING_GATE=off bypasses the gate for an exempted session" "$(verdict $?)"
printf '%s' "$ERR_R" | grep -qF 'ZENSU_EDIT_LANDING_GATE=off'
check "E2 the refusal documents the escape hatch instead of hiding it" "$(verdict $?)"

echo "== Integration: the library writes where the gate reads =="
# The whole gate is worthless if these two disagree on the path, and a wrong
# path fails OPEN in the most misleading way: the audit runs, the receipt is
# written somewhere, and completion is refused anyway (or never gated).
SID_I="gate-integration"
activate_session "$SID_I"
bash "$LOG" --tdd-begin --session "$SID_I" >/dev/null 2>&1
REPO="$PROJ/repo"
mkdir -p "$REPO"
git init -q --template= "$REPO" >/dev/null 2>&1
printf 'v1\n' > "$REPO/a.txt"
git -C "$REPO" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$REPO" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
printf 'v2\n' > "$REPO/a.txt"
printf 'S1 IMPL completed — files: a.txt\n' > "$REPO/run.log"

bash "$LIB" --log "$REPO/run.log" --project "$REPO" --session "$SID_I" >/dev/null 2>&1
LIB_RC=$?
[ "$LIB_RC" -eq 0 ]
check "I1 the audit runs clean on a fixture where the claim really landed" "$(verdict $?)"
# The library writes into the audited project; the gate reads the session state
# dir. Assert the file the gate expects now exists.
EXPECTED="$(receipt_for "$SID_I")"
LIB_WROTE="$REPO/.zensu/state/$(basename "$EXPECTED")"
[ -f "$LIB_WROTE" ]
check "I2 the library wrote a receipt under the audited project's state dir" "$(verdict $?)"
[ "$(basename "$LIB_WROTE")" = "$(basename "$EXPECTED")" ]
check "I3 library and gate agree on the receipt FILENAME (session-key derivation matches)" "$(verdict $?)"
# Same project for both: audit the session's own project root, as the skill does.
bash "$LIB" --log "$REPO/run.log" --project "$REPO" --receipt "$EXPECTED" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_I" >/dev/null 2>&1
[ $? -eq 0 ]
check "I4 completion is accepted after the audit deposits the receipt where the gate reads" "$(verdict $?)"

echo "== Source pins =="
grep -qF 'ZENSU_EDIT_LANDING_GATE' "$LOG"
check "S1 the gate lives in zensu-log.sh" "$(verdict $?)"
awk '/--tdd-complete\)/,/;;/' "$LOG" | grep -qF 'edit-landing-'
check "S2 the receipt check sits inside the --tdd-complete verb" "$(verdict $?)"
# The gate must not weaken the pre-existing refusals around it.
grep -qF 'corrupt, inactive, or foreign session state' "$LOG"
check "S3 the pre-existing session-state refusal is intact" "$(verdict $?)"
grep -qF 'Autopilot binding was supplied for a standalone chain' "$LOG"
check "S4 the pre-existing standalone/bound refusal is intact" "$(verdict $?)"
grep -qF 'refusing the unqualified standalone terminus' "$LOG"
check "S5 the --chain-done dirty-tree refusal this gate is modelled on is intact" "$(verdict $?)"

echo "----"
echo "test-tdd-complete-receipt-gate: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
