#!/bin/bash
# --tdd-complete refuses without an edit-landing receipt.
#
# zensu-doctor-home-exempt: this suite never RUNS the doctor. SCH1 greps
# hooks/lib/zensu-doctor-report.js for one constant, because the accepted-schema
# set has four spellings and no owner; no renderer process is started and no HOME
# is resolved.
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
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN ZENSU_EDIT_LANDING_GATE \
  ZENSU_REQUIREMENTS_GATE 2>/dev/null || true

# The gate is scoped to a project that actually changed — same scoping as the
# --chain-done dirty-tree refusal. Give the session project a real git repo with
# one dirty file, or the gate is correctly out of scope and proves nothing.
git init -q --template= "$PROJ" >/dev/null 2>&1
printf 'v1\n' > "$PROJ/tracked.txt"
# Session state lands under .zensu/; real repos gitignore it, and an unignored
# state dir would make every tree dirty and every case look in-scope.
# `.session-control-test/` is the baseline helper's own scratch directory: it is
# untracked, so without this line the anchor is NEVER clean here and the
# claim-armed section below would be graded by a dirty tree instead of by a claim.
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
for SID in gate-refuse gate-accept gate-escape gate-integration gate-clean-tree \
           gate-clean-claim gate-clean-noclaim gate-clean-empty gate-clean-unresolved \
           gate-clean-receipt gate-verdict gate-clean-noclaim-receipt \
           gate-stem-bind gate-retire; do
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
# Every source pin below reads the same awk range, and that range is now anchored on
# an EIGHT-SPACE `;;`. The old `/;;/` terminator could never fail to match, so the
# window was always bounded; a precise terminator can fail — and in awk a range whose
# end pattern never matches runs to EOF. The window would then swallow `--chain-done`,
# which carries the IDENTICAL strings by design, so W2 and S2 would match the wrong
# copy and pass while proving nothing. Bound the window ONCE, here, before anything
# relies on it. The discriminator is a string that lives only in `--chain-done`
# (pinned by S5 further down): finding it inside the window proves the range overran.
TC_WIN() { awk '/--tdd-complete\)/,/^        ;;/' "$LOG"; }
TC_WIN_LINES="$(TC_WIN | grep -c . 2>/dev/null || true)"
LOG_LINES="$(grep -c . "$LOG" 2>/dev/null || true)"
[ "${TC_WIN_LINES:-0}" -gt 0 ] \
  && [ "${TC_WIN_LINES:-0}" -lt "${LOG_LINES:-0}" ] \
  && ! TC_WIN | grep -qF 'refusing the unqualified standalone terminus'
check "W0 the --tdd-complete awk window is non-empty and still bounded (end anchor matches)" "$(verdict $?)"
TC_WIN | grep -qF 'ls-files --others --exclude-standard'
check "W2 the gate scopes itself on the same change set the terminus uses" "$(verdict $?)"
# W1 above replicates the predicate WITHOUT a fallback, so it cannot see the shape that
# actually broke: `grep -c .` prints 0 and then exits 1 on no match, so pairing it with an
# `|| echo 0` fallback appends a SECOND line. The count becomes "0\n0", the -gt comparison
# aborts with "integer expression expected", and the gate is skipped on exactly the empty
# change set it was scoping for. Pin the source shape, not a re-typed copy of it.
# The anchor is `_tc_changes` since the value became shared with the
# requirements-table gate. An absence assertion whose haystack is empty proves
# nothing, so the anchor's own presence is checked FIRST — that is exactly how
# this check went vacuous when the variable was renamed.
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF '_tc_changes="$('
check "W3pre the change-count anchor this check greps still exists" "$(verdict $?)"
! awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -A3 -F '_tc_changes="$(' | grep -qE '\|\|[[:space:]]*echo'
check "W3 the change-count expression cannot emit a second line on an empty change set" "$(verdict $?)"

receipt_for() {  # echo the path the GATE will look at for session $1
  local sf key
  sf="$(tdd_state_file "$1")"
  key="$(basename "$sf")"; key="${key#tdd-phase-}"; key="${key%.json}"
  printf '%s' "$(dirname "$sf")/edit-landing-${key}.json"
}

echo "== Claim-armed scope: a clean anchor that CLAIMED an edit is still gated =="
# docs/multi-repo-chains-spec.md §5.2. The anchor's change count says nothing about
# a chain whose work landed in another repository, so a logged claim arms the
# requirement on its own. Both directions live in ONE section on purpose: the
# exemption is what keeps hermetic chain-mechanics tests from fabricating a receipt,
# and a one-sided check would let either half drift.
mkdir -p "$PROJ/.zensu/logs" "$PROJ/.zensu/plans"
CC_RC=0
# The invocation stays in the test body: a helper that runs it inside a command
# substitution loses its own exit status to the subshell, and every rc assertion
# below then reads the initialiser instead of the gate's verdict.
clean_arm() {
  activate_session "$1"
  if ! bash "$LOG" --tdd-begin --session "$1" >/dev/null 2>&1; then
    check "clean_arm(): --tdd-begin failed for session $1" FAIL
    return 1
  fi
  return 0
}
printf 'TDD STARTED — claim fixture\nS1 IMPL completed — files: tracked.txt\n' \
  > "$PROJ/.zensu/logs/clean-claim.log"
clean_arm gate-clean-claim
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-claim \
  --plan "$PROJ/.zensu/plans/clean-claim.md" 2>&1 >/dev/null)"
CC_RC=$?
[ "$CC_RC" -ne 0 ]
check "Z1 a clean anchor whose run log carries a claim is GATED" "$(verdict $?)"
printf '%s' "$CC_ERR" | grep -qF 'no edit-landing receipt'
check "Z2 the claim-armed refusal is the receipt refusal, naming the audit that produces it" "$(verdict $?)"
printf 'TDD STARTED — no claim fixture\nCHECKPOINT — cmd="true" exit=0 result="PASS"\n' \
  > "$PROJ/.zensu/logs/clean-noclaim.log"
clean_arm gate-clean-noclaim
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-noclaim \
  --plan "$PROJ/.zensu/plans/clean-noclaim.md" 2>&1 >/dev/null)"
CC_RC=$?
[ "$CC_RC" -eq 0 ]
check "Z3 a clean anchor whose run log carries NO claim stays exempt" "$(verdict $?)"
printf 'S1 IMPL completed — files:\nS2 WIRED (verified, no change) — tests/run-all.sh: glob picks it up\n' \
  > "$PROJ/.zensu/logs/clean-empty.log"
clean_arm gate-clean-empty
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-empty \
  --plan "$PROJ/.zensu/plans/clean-empty.md" 2>&1 >/dev/null)"
CC_RC=$?
[ "$CC_RC" -eq 0 ]
check "Z4 an empty file list and a verified-no-change line are NOT claims" "$(verdict $?)"
clean_arm gate-clean-unresolved
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-unresolved \
  --plan "$PROJ/.zensu/plans/absent-stem.md" 2>&1 >/dev/null)"
CC_RC=$?
{ [ "$CC_RC" -eq 0 ] && printf '%s' "$CC_ERR" | grep -qF 'EDIT LANDING GATE UNRESOLVED'; }
check "Z5 a --plan whose run log cannot be read DISCLOSES instead of exempting silently" "$(verdict $?)"
activate_session gate-clean-receipt
bash "$LOG" --tdd-begin --session gate-clean-receipt >/dev/null 2>&1
mkdir -p "$(dirname "$(receipt_for gate-clean-receipt)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":2,"clean":false}\n' \
  > "$(receipt_for gate-clean-receipt)"
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-receipt 2>&1 >/dev/null)"
CC_RC=$?
{ [ "$CC_RC" -ne 0 ] && printf '%s' "$CC_ERR" | grep -qF 'records a FAILED audit'; }
check "Z6 with no --plan the receipt's own claim count arms the gate and its verdict is judged" "$(verdict $?)"
# The discriminator: the SAME unclean verdict with claims:0 arms nothing, so Z6
# passes because of the COUNT rather than because the verdict block runs anyway.
activate_session gate-clean-noclaim-receipt
bash "$LOG" --tdd-begin --session gate-clean-noclaim-receipt >/dev/null 2>&1
mkdir -p "$(dirname "$(receipt_for gate-clean-noclaim-receipt)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":0,"clean":false}\n' \
  > "$(receipt_for gate-clean-noclaim-receipt)"
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-noclaim-receipt 2>&1 >/dev/null)"
CC_RC=$?
{ [ "$CC_RC" -eq 0 ] && ! printf '%s' "$CC_ERR" | grep -qF 'records a FAILED audit'; }
check "Z6a a receipt claiming NOTHING arms nothing, so its unclean verdict is never reached" "$(verdict $?)"
# JUDGE-3 — a receipt is evidence about ONE run log. `--tdd-begin` retires the
# previous generation's, and a receipt naming a DIFFERENT log is refused rather
# than accepted as this chain's clean verdict.
printf 'TDD STARTED — other generation\nS1 IMPL completed — files: tracked.txt\n' \
  > "$PROJ/.zensu/logs/other-gen.log"
printf 'TDD STARTED — stem fixture\nS1 IMPL completed — files: tracked.txt\n' \
  > "$PROJ/.zensu/logs/stem-bind.log"
clean_arm gate-stem-bind
mkdir -p "$(dirname "$(receipt_for gate-stem-bind)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/other-gen.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-stem-bind)"
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" 2>&1 >/dev/null)"
CC_RC=$?
{ [ "$CC_RC" -ne 0 ] && printf '%s' "$CC_ERR" | grep -qF 'describes the run log'; }
check "Z7 a clean receipt describing ANOTHER run log does not satisfy this chain's gate" "$(verdict $?)"
# The control: the same receipt naming THIS chain's log is accepted.
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/stem-bind.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-stem-bind)"
bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" >/dev/null 2>&1
check "Z7a the same receipt naming THIS chain's run log is accepted" "$(verdict $?)"
# JUDGE-3 — arming a fresh generation retires the previous receipt by RENAME, so
# no chain can inherit another generation's clean verdict.
clean_arm gate-retire
mkdir -p "$(dirname "$(receipt_for gate-retire)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-retire)"
bash "$LOG" --tdd-begin --session gate-retire >/dev/null 2>&1
[ ! -e "$(receipt_for gate-retire)" ]
check "Z8 --tdd-begin retires the previous generation's receipt" "$(verdict $?)"
[ -f "$(receipt_for gate-retire).superseded" ]
check "Z8a the retired receipt stays readable beside the record it describes" "$(verdict $?)"
# ORDERING is a contract, not layout. The retirement used to run above the arm,
# so a REFUSED `--tdd-begin` — a held workspace, a storage fault, a bad argument —
# left the PREVIOUS generation live with its receipt already renamed, and that
# chain's own `--tdd-complete` then refused with "no edit-landing receipt for this
# session", a cause that never happened. A failing begin cannot be staged from
# this suite, so the property is pinned where it is decided.
Z8C_SRC="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
Z8C_ARM="$(grep -n 'if \[ "\$tdd_begin_rc" -eq 0 \]' "$Z8C_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
Z8C_MV="$(grep -n 'mv -f "\$begin_receipt"' "$Z8C_SRC" 2>/dev/null | head -1 | cut -d: -f1)"
{ [ -n "$Z8C_ARM" ] && [ -n "$Z8C_MV" ] && [ "$Z8C_MV" -gt "$Z8C_ARM" ]; }
check "Z8c the receipt retirement runs only on the SUCCESSFUL arm of --tdd-begin" "$(verdict $?)"

# From here on the project really changed, so the gate is in scope.
printf 'v2\n' > "$PROJ/tracked.txt"

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

echo "== Receipt verdict: presence is not a verdict =="
# docs/multi-repo-chains-spec.md §5.1. The audit writes its receipt BEFORE its own
# exit status, carrying `clean` as a field rather than as a precondition for
# writing — so an audit that reported EDIT NOT LANDED still satisfied an
# existence test. All four refused states are asserted here, and the absent-field
# one is the case a two-valued implementation silently accepts.
SID_V="gate-verdict"
activate_session "$SID_V"
bash "$LOG" --tdd-begin --session "$SID_V" >/dev/null 2>&1
V_RECEIPT="$(receipt_for "$SID_V")"
mkdir -p "$(dirname "$V_RECEIPT")"
VR_RC=0
# Same rule as the claim-armed section above: plant the receipt in a helper, run
# the verb in the test body, or the substitution swallows the exit status.
plant_receipt() { printf '%s\n' "$1" > "$V_RECEIPT"; }
plant_receipt '{"schema":"edit-landing-v2","clean":false}'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
{ [ "$VR_RC" -ne 0 ] && printf '%s' "$VR_ERR" | grep -qF 'records a FAILED audit'; }
check "D1 a receipt recording clean:false is refused" "$(verdict $?)"
plant_receipt '{"schema":"edit-landing-v2"}'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
{ [ "$VR_RC" -ne 0 ] && printf '%s' "$VR_ERR" | grep -qF 'records no verdict'; }
check "D2 a receipt with NO clean field is refused (the affirmative spelling)" "$(verdict $?)"
plant_receipt '{"schema":"edit-landing-v2","clean":"true"}'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
{ [ "$VR_RC" -ne 0 ] && printf '%s' "$VR_ERR" | grep -qF 'records no verdict'; }
check "D3 a quoted \"true\" is not a boolean verdict" "$(verdict $?)"
plant_receipt '{"schema":"edit-landing-v2","clean":true'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
{ [ "$VR_RC" -ne 0 ] && printf '%s' "$VR_ERR" | grep -qF 'does not parse as an edit-landing receipt'; }
check "D4 an unparseable receipt is refused" "$(verdict $?)"
plant_receipt '{"schema":"edit-landing-v9","clean":true}'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
{ [ "$VR_RC" -ne 0 ] && printf '%s' "$VR_ERR" | grep -qF 'carries a schema this runtime does not know'; }
check "D5 an unknown schema is refused rather than read for its clean field" "$(verdict $?)"
[ "$(tdd_get_flag "$(tdd_state_file "$SID_V")" implComplete)" != "true" ]
check "D6 none of the refused verdicts advanced the chain" "$(verdict $?)"
plant_receipt '{"schema":"edit-landing-v1","clean":true}'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
[ "$VR_RC" -eq 0 ]
check "D7 a v1 receipt recording clean:true is accepted — both schema versions stay readable" "$(verdict $?)"

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
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF 'edit-landing-'
check "S2 the receipt check sits inside the --tdd-complete verb" "$(verdict $?)"
# The gate must not weaken the pre-existing refusals around it.
grep -qF 'corrupt, inactive, or foreign session state' "$LOG"
check "S3 the pre-existing session-state refusal is intact" "$(verdict $?)"
grep -qF 'Autopilot binding was supplied for a standalone chain' "$LOG"
check "S4 the pre-existing standalone/bound refusal is intact" "$(verdict $?)"
grep -qF 'refusing the unqualified standalone terminus' "$LOG"
check "S5 the --chain-done dirty-tree refusal this gate is modelled on is intact" "$(verdict $?)"

echo "== The accepted-schema set has FOUR spellings and no owner =="
# Until a host-neutral module owns the set, this is what holds the four in step:
# the writer, the terminus verdict reader, the requirements-gate derivation reader
# and the doctor renderer. A one-sided edit degrades one consumer SILENTLY — a
# missing topology row, or a REQUIREMENTS GATE UNRESOLVED line naming no cause.
SCH_LIB="$PLUGIN_DIR/hooks/lib"
SCH_WRITER="$(grep -c 'schema: "edit-landing-v2"' "$SCH_LIB/zensu-edit-landing.sh" 2>/dev/null)"; SCH_WRITER="${SCH_WRITER:-0}"
SCH_VERDICT="$(grep -c 'j.schema !== "edit-landing-v1" && j.schema !== "edit-landing-v2"' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; SCH_VERDICT="${SCH_VERDICT:-0}"
SCH_DERIVE="$(grep -c 'j.schema === "edit-landing-v1"' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; SCH_DERIVE="${SCH_DERIVE:-0}"
SCH_DOCTOR="$(grep -cF "RECEIPT_SCHEMAS = ['edit-landing-v1', 'edit-landing-v2']" "$SCH_LIB/zensu-doctor-report.js" 2>/dev/null)"; SCH_DOCTOR="${SCH_DOCTOR:-0}"
{ [ "$SCH_WRITER" -ge 1 ] && [ "$SCH_VERDICT" -ge 1 ] && [ "$SCH_DERIVE" -ge 1 ] && [ "$SCH_DOCTOR" -ge 1 ]; }
check "SCH1 all four accepted-schema spellings are present and agree on edit-landing-v1/v2" "$(verdict $?)"
# The control: the needles are specific, so a nonsense schema name matches none.
SCH_CONTROL="$(grep -c 'edit-landing-v9' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; SCH_CONTROL="${SCH_CONTROL:-0}"
[ "$SCH_CONTROL" -eq 0 ]
check "SCH1-control the pin is not matching an arbitrary schema name" "$(verdict $?)"
# Presence alone catches a RENAME or a REMOVAL and not an ADDITION: a reader
# widened to accept `edit-landing-v3` leaves all four needles matching while the
# writer and the readers disagree about the accepted SET. The negative arm is
# what closes that direction, and it covers all four carriers rather than one.
SCH_EXTRA=0
for _sch_f in "$SCH_LIB/zensu-edit-landing.sh" "$SCH_LIB/zensu-log.sh" "$SCH_LIB/zensu-doctor-report.js"; do
  _sch_hits="$(grep -oE 'edit-landing-v[0-9]+' "$_sch_f" 2>/dev/null | grep -vE 'edit-landing-v[12]$' | wc -l | tr -d ' ')"
  _sch_hits="${_sch_hits:-0}"
  [ "$_sch_hits" -eq 0 ] || SCH_EXTRA=$((SCH_EXTRA + _sch_hits))
done
[ "$SCH_EXTRA" -eq 0 ]
check "SCH1b no carrier names a schema version outside {v1,v2} — an ADDITION fails too" "$(verdict $?)"
# The control for the negative arm: the scan really does see a foreign version.
SCH_PROBE="$(mktemp)"; printf 'schema: "edit-landing-v7"\n' > "$SCH_PROBE"
_sch_probe_hits="$(grep -oE 'edit-landing-v[0-9]+' "$SCH_PROBE" 2>/dev/null | grep -vE 'edit-landing-v[12]$' | wc -l | tr -d ' ')"
rm -f "$SCH_PROBE"
[ "${_sch_probe_hits:-0}" -eq 1 ]
check "SCH1b-control the negative scan reports a planted foreign schema version" "$(verdict $?)"

# The stem derivation the terminus uses to bind a receipt to THIS chain's run log
# is separator-blind by hand, because an `edit-landing-v1` receipt persists the
# raw `--log` spelling and a win32 caller writes backslashes. POSIX cannot observe
# that arm, so it is pinned at source — and the code comment names THIS check,
# not MB4, which governs a different value in a different gate.
Z8B_BODY="$(grep -cF '_tc_receipt_stem="${_tc_receipt_stem##*\\}"' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; Z8B_BODY="${Z8B_BODY:-0}"
Z8B_ARMED="$(grep -cF '_tc_armed_stem="${_tc_armed_stem##*\\}"' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; Z8B_ARMED="${Z8B_ARMED:-0}"
Z8B_NOBASENAME="$(grep -cE 'basename "[$]_tc_(receipt|armed|run)' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; Z8B_NOBASENAME="${Z8B_NOBASENAME:-0}"
{ [ "$Z8B_BODY" -ge 1 ] && [ "$Z8B_ARMED" -ge 1 ] && [ "$Z8B_NOBASENAME" -eq 0 ]; }
check "Z8b both stems strip a BACKSLASH-separated prefix and neither uses basename" "$(verdict $?)"
# The control: the needle is a fixed string, so it does not match the sibling
# forward-slash expansion on the same two lines.
Z8B_CONTROL="$(grep -cF '_tc_receipt_stem="${_tc_receipt_stem##*/}"' "$SCH_LIB/zensu-log.sh" 2>/dev/null)"; Z8B_CONTROL="${Z8B_CONTROL:-0}"
[ "$Z8B_CONTROL" -eq 0 ]
check "Z8b-control the backslash needle is not matching the forward-slash arm" "$(verdict $?)"

echo "----"
echo "test-tdd-complete-receipt-gate: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
