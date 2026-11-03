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
           gate-clean-receipt gate-verdict gate-clean-noclaim-receipt gate-budget-claim gate-nolog gate-symlink-receipt gate-plain-receipt \
           gate-stem-bind gate-retire gate-claims-type gate-armed-log gate-git-refused gate-wt-standalone; do
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
# ANCHORED start address. `/--tdd-complete\)/` also matches the shared
# `--tdd-begin|--tdd-complete)` flag-validation arm earlier in the file, so the
# window used to be the UNION of two disjoint ranges and W0's bound covered only
# the tail. No needle lived in the spurious block, so nothing was fooled — but a
# later needle that also occurs in flag validation would have passed while the
# verb body lost it.
TC_WIN() { awk '/^      --tdd-complete\)$/,/^        ;;/' "$LOG"; }
TC_WIN_LINES="$(TC_WIN | grep -c . 2>/dev/null || true)"
LOG_LINES="$(grep -c . "$LOG" 2>/dev/null || true)"
[ "${TC_WIN_LINES:-0}" -gt 0 ] \
  && [ "${TC_WIN_LINES:-0}" -lt "${LOG_LINES:-0}" ] \
  && ! TC_WIN | grep -qF 'refusing the unqualified standalone terminus'
check "W0 the --tdd-complete awk window is non-empty and still bounded (end anchor matches)" "$(verdict $?)"
TC_WIN | grep -qF '_zensu_union_change_count "$_tc_root" "$session_val"' \
  && awk '/^_zensu_unqualified_change_count\(\) \{/,/^}/' "$LOG" | grep -qF 'ls-files --others --exclude-standard'
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
printf 'BUILD STARTED — claim fixture\nS1 IMPL completed — files: tracked.txt\n' \
  > "$PROJ/.zensu/logs/clean-claim.log"
clean_arm gate-clean-claim
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-clean-claim \
  --plan "$PROJ/.zensu/plans/clean-claim.md" 2>&1 >/dev/null)"
CC_RC=$?
[ "$CC_RC" -ne 0 ]
check "Z1 a clean anchor whose run log carries a claim is GATED" "$(verdict $?)"
printf '%s' "$CC_ERR" | grep -qF 'no edit-landing receipt'
check "Z2 the claim-armed refusal is the receipt refusal, naming the audit that produces it" "$(verdict $?)"
printf 'BUILD STARTED — no claim fixture\nCHECKPOINT — cmd="true" exit=0 result="PASS"\n' \
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
# `claims` moved from a report field to a GATE INPUT: it now arms the receipt
# requirement on a clean anchor. `Number.isFinite` rejects a string, so a producer
# serialising it as `"2"` silently disarms the claim channel and NOTHING is said —
# the existing UNRESOLVED disclosure fires only for a run-log channel fault. An
# unresolved channel that reads exactly like a resolved empty one is the failure
# this whole block exists to remove.
clean_arm gate-claims-type
mkdir -p "$(dirname "$(receipt_for gate-claims-type)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":"2","clean":true}\n' \
  > "$(receipt_for gate-claims-type)"
CT_ERR="$(bash "$LOG" --tdd-complete --session gate-claims-type 2>&1 >/dev/null)"
CT_RC=$?
[ "$CT_RC" -eq 0 ]
check "Z10-control a non-numeric claims count does not block completion" "$(verdict $?)"
printf '%s' "$CT_ERR" | grep -qF 'EDIT LANDING GATE UNRESOLVED'
check "Z10 a receipt whose claims count is not a number is DISCLOSED, not read as zero" "$(verdict $?)"
printf '%s' "$CT_ERR" | grep -qF 'claims'
check "Z10a the disclosure names the claim channel rather than the run log" "$(verdict $?)"
# JUDGE-3 — a receipt is evidence about ONE run log. `--tdd-begin` retires the
# previous generation's, and a receipt naming a DIFFERENT log is refused rather
# than accepted as this chain's clean verdict.
printf 'BUILD STARTED — other generation\nS1 IMPL completed — files: tracked.txt\n' \
  > "$PROJ/.zensu/logs/other-gen.log"
printf 'BUILD STARTED — stem fixture\nS1 IMPL completed — files: tracked.txt\n' \
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
remedy_bound() {
  printf '%s' "$1" | grep -qF -- '--project "<the path zensu-log.sh --project-root prints>"' \
    && ! printf '%s' "$1" | grep -qF 'CLAUDE_PROJECT_DIR:-.'
}
remedy_bound "$CC_ERR"
check "Z7b the run-log refusal's remedy names the bound root through --project-root" "$(verdict $?)"
# The control: the same receipt naming THIS chain's log is accepted.
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/stem-bind.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-stem-bind)"
bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" >/dev/null 2>&1
check "Z7a the same receipt naming THIS chain's run log is accepted" "$(verdict $?)"
# The refusal carries a stem out of a receipt in `.zensu/state/`, which the
# code's own comment calls session-writable, so its rendering is a screen rather
# than a formatting nicety. Z9 drives THIS host's locale and Z9b the C one; they
# are two arms of one property, because the length guard and the truncation both
# count characters under a UTF-8 locale and bytes under C, and only the second
# can cut a multi-byte stem mid-sequence.
EURO="$(printf '\342\202\254')"
LONG_STEM=""; LS_I=0
while [ "$LS_I" -lt 250 ]; do LONG_STEM="${LONG_STEM}${EURO}"; LS_I=$((LS_I+1)); done
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/%s.log","claims":1,"clean":true}\n' "$LONG_STEM" \
  > "$(receipt_for gate-stem-bind)"
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" 2>&1 >/dev/null)"
CC_RC=$?
{ [ "$CC_RC" -ne 0 ] && printf '%s' "$CC_ERR" | grep -qF 'describes the run log'; }
check "Z9-control the long-stem receipt reaches the stem-mismatch refusal at all" "$(verdict $?)"
if command -v iconv >/dev/null 2>&1; then
  printf '%s' "$CC_ERR" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
  check "Z9 under this host's own locale the truncated stem is valid UTF-8" "$(verdict $?)"
else
  check "Z9 SKIPPED — this host has no iconv to validate the encoding" PASS
fi
# Z9b — Z9 above passes for a LOCALE reason, not for the code. `${#var}` counts
# characters and `${var:0:N}` cuts characters under a UTF-8 locale, and BOTH
# count and cut BYTES under `LC_ALL=C` — which is what a non-interactive shell
# with no `LANG` gets. So the same construct does different things on the same
# input and the byte branch is the one a dev host takes. The `[[:cntrl:]]`
# screen moves too: under an ISO8859 locale it matches the C1 range, so every
# ordinary UTF-8 stem would be withheld as unsafe. Drive the C branch directly.
CC_ERR_C="$(LC_ALL=C bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" 2>&1 >/dev/null)"
printf '%s' "$CC_ERR_C" | grep -qF 'describes the run log'
check "Z9b-control the same fixture reaches the refusal under LC_ALL=C too" "$(verdict $?)"
if command -v iconv >/dev/null 2>&1; then
  printf '%s' "$CC_ERR_C" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
  check "Z9b under LC_ALL=C the truncated stem is still valid UTF-8" "$(verdict $?)"
else
  check "Z9b SKIPPED — this host has no iconv to validate the encoding" PASS
fi
{ ! printf '%s' "$CC_ERR_C" | grep -qF '(withheld — unsafe to render)'; }
check "Z9c a multi-byte stem is not mistaken for a control byte" "$(verdict $?)"
# Z9d — the screen is a SUBSET of the doctor's and must carry all four of its own
# rules, not the two it shipped with. A forged `label : value` pair and a double
# space are what `forgesReportRow` refuses, and this value reaches a refusal a
# model relays.
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/a : b.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-stem-bind)"
CC_ERR_P="$(bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" 2>&1 >/dev/null)"
# The RESPONSE changed and the property did not: the pair must not FORM. The
# shared screen escapes the colon rather than withholding the stem, because
# withholding cost the reader the one thing the refusal exists to say — which
# run log the receipt describes — for a stem whose only sin is a colon.
{ ! printf '%s' "$CC_ERR_P" | grep -qF ' : '; }
check "Z9d a forged 'label : value' pair in the stem cannot form one" "$(verdict $?)"
printf '%s' "$CC_ERR_P" | grep -qF 'u003a'
check "Z9d1 the same stem is escaped rather than withheld, so it stays readable" "$(verdict $?)"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/a  b.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-stem-bind)"
CC_ERR_D="$(bash "$LOG" --tdd-complete --session gate-stem-bind \
  --plan "$PROJ/.zensu/plans/stem-bind.md" 2>&1 >/dev/null)"
{ printf '%s' "$CC_ERR_D" | grep -qF 'a b' && ! printf '%s' "$CC_ERR_D" | grep -qF 'a  b'; }
check "Z9e a double space in the stem is collapsed rather than withholding it" "$(verdict $?)"
# JUDGE-3 — arming a fresh generation retires the previous receipt by RENAME, so
# no chain can inherit another generation's clean verdict.
clean_arm gate-retire
mkdir -p "$(dirname "$(receipt_for gate-retire)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-retire)"
bash "$LOG" --tdd-begin --session gate-retire >/dev/null 2>&1
[ ! -e "$(receipt_for gate-retire)" ]
check "Z8 --tdd-begin retires the previous generation's receipt" "$(verdict $?)"
retired_count() { find "$(dirname "$(receipt_for gate-retire)")" -maxdepth 1 \
  -name "$(basename "$(receipt_for gate-retire)").superseded*" 2>/dev/null | grep -c . ; }
[ "$(retired_count)" -ge 1 ]
check "Z8a the retired receipt stays readable beside the record it describes" "$(verdict $?)"
# The destination used to be a FIXED `.superseded`, so the SECOND retirement
# destroyed the first — while the comment beside it promised that file is "the
# only durable record of what that audit found". Two generations, two records.
mkdir -p "$(dirname "$(receipt_for gate-retire)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-retire)"
bash "$LOG" --tdd-begin --session gate-retire >/dev/null 2>&1
[ "$(retired_count)" -ge 2 ]
check "Z8d a second retirement does not destroy the first one's record" "$(verdict $?)"
# The failure path cannot be staged from this fixture — forcing `mv` to fail
# means making the state directory unwritable, which breaks arming itself — so
# the disclosure is pinned where it is decided. Every other unresolved
# precondition in this verb family announces itself; this one used to swallow
# EACCES, EROFS and a `.superseded` that is a directory behind `|| true`.
grep -qF 'RECEIPT RETIREMENT UNRESOLVED' "$PLUGIN_DIR/hooks/lib/zensu-log.sh"
check "Z8e a retirement that did not complete is disclosed rather than swallowed" "$(verdict $?)"
# The slice is BOUNDED before it is searched. An awk range whose end address
# never matches runs to EOF, and the needle then matches somewhere else in the
# file entirely — the check stays green while the property it names is gone.
# This same suite's W4 shipped exactly that defect in round 1 (a 910-line range),
# so the bound is asserted rather than assumed: the slice must be non-empty and
# must be a small fraction of the file.
Z8F_SLICE="$(awk '/if \[ "\$tdd_begin_rc" -eq 0 \]/,/^        else$/' "$PLUGIN_DIR/hooks/lib/zensu-log.sh")"
Z8F_LINES="$(printf '%s\n' "$Z8F_SLICE" | grep -c . || true)"
Z8F_LINES="${Z8F_LINES:-0}"
Z8F_TOTAL="$(grep -c . "$PLUGIN_DIR/hooks/lib/zensu-log.sh" || true)"
Z8F_TOTAL="${Z8F_TOTAL:-0}"
{ [ "$Z8F_LINES" -gt 0 ] && [ "$Z8F_LINES" -lt $((Z8F_TOTAL / 4)) ]; }
check "Z8f-control the begin-success slice is bounded (${Z8F_LINES} lines), not a run to EOF" "$(verdict $?)"
printf '%s\n' "$Z8F_SLICE" | grep -qF '_tdd_locked_run'
check "Z8f the retirement runs under the workflow document's external lease" "$(verdict $?)"
# ORDERING is a contract, not layout. The retirement used to run above the arm,
# so a REFUSED `--tdd-begin` — a held workspace, a storage fault, a bad argument —
# left the PREVIOUS generation live with its receipt already renamed, and that
# chain's own `--tdd-complete` then refused with "no edit-landing receipt for this
# session", a cause that never happened. A failing begin cannot be staged from
# this suite, so the property is pinned where it is decided.
#
# "Runs only on the successful arm" is a NESTING property, and a bare `MV > ARM`
# line comparison establishes only textual ORDER. Move the retirement below the
# `fi` and it becomes unconditional again — restoring exactly the defect this
# check is named for — while `>` stays true and the check stays green. The range
# is bounded by the arm's own `else`, using the TC_WIN awk idiom already in this
# file, and the bound is proven by a mutant rather than asserted.
Z8C_SRC="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
z8c_holds() {
  local src="$1" arm end mv
  arm="$(grep -n 'if \[ "\$tdd_begin_rc" -eq 0 \]' "$src" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$arm" ] || return 1
  end="$(awk -v s="$arm" 'NR>s && /^        else$/{print NR; exit}' "$src")"
  [ -n "$end" ] || return 1
  mv="$(grep -n '_tdd_retire_receipt_critical "\$begin_receipt"' "$src" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$mv" ] || return 1
  [ "$mv" -gt "$arm" ] && [ "$mv" -lt "$end" ]
}
z8c_holds "$Z8C_SRC"
check "Z8c the receipt retirement runs only on the SUCCESSFUL arm of --tdd-begin" "$(verdict $?)"
# Under `.zensu/`, which this fixture gitignores. In the git ROOT it showed up
# as an untracked file, so every case after it measured a DIRTY anchor — which
# silently re-grades the claim-armed section by the change set instead of by the
# claim it is named for.
Z8C_MUT="$PROJ/.zensu/z8c-mutant.sh"
grep -v '_tdd_retire_receipt_critical "\$begin_receipt"' "$Z8C_SRC" > "$Z8C_MUT"
grep -n '_tdd_retire_receipt_critical "\$begin_receipt"' "$Z8C_SRC" | head -1 | cut -d: -f2- >> "$Z8C_MUT"
{ grep -q '_tdd_retire_receipt_critical "\$begin_receipt"' "$Z8C_MUT" && ! z8c_holds "$Z8C_MUT"; }
check "Z8c-mut the same predicate REJECTS a retirement moved out of the success block" "$(verdict $?)"

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
remedy_bound "$ERR_R"
check "R4b the missing-receipt remedy names the bound root through --project-root" "$(verdict $?)"
# Refusing must not have advanced the chain.
[ "$(tdd_get_flag "$(tdd_state_file "$SID_R")" implComplete)" != "true" ]
check "R5 a refused completion leaves implComplete unset" "$(verdict $?)"
R6_HOME="$PROJ/.zensu/r6-home"
R6_SAFE_HOME="$PROJ/.zensu/r6-safe-home"
mkdir -p "$R6_HOME" "$R6_SAFE_HOME"
printf '[safe]\n\tdirectory = *\n' > "$R6_SAFE_HOME/.gitconfig"
R6_ERR="$(HOME="$R6_HOME" XDG_CONFIG_HOME="$R6_HOME/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
  env LC_ALL=C git -C "$PROJ" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"
R6_RC=$?
[ "$R6_RC" -ne 0 ] && printf '%s\n' "$R6_ERR" | grep -qF 'dubious ownership'
check "R6-control real git refuses this suite's project as owned by another user" "$(verdict $?)"
SID_G="gate-git-refused"
activate_session "$SID_G"
bash "$LOG" --tdd-begin --session "$SID_G" >/dev/null 2>&1
ERR_G="$(HOME="$R6_HOME" XDG_CONFIG_HOME="$R6_HOME/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
  bash "$LOG" --tdd-complete --session "$SID_G" 2>&1 >/dev/null)"
RC_G=$?
[ "$RC_G" -eq 1 ] && printf '%s' "$ERR_G" | grep -qF 'git could not list this worktree' \
  && ! printf '%s' "$ERR_G" | grep -qF 'no edit-landing receipt' \
  && [ "$(tdd_get_flag "$(tdd_state_file "$SID_G")" implComplete)" != "true" ]
check "R6 a safe.directory refusal on a changed tree refuses rather than exempting the chain as unchanged" "$(verdict $?)"
ERR_GX="$(HOME="$R6_SAFE_HOME" XDG_CONFIG_HOME="$R6_SAFE_HOME/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
  bash "$LOG" --tdd-complete --session "$SID_G" 2>&1 >/dev/null)"
RC_GX=$?
[ "$RC_GX" -eq 1 ] && printf '%s' "$ERR_GX" | grep -qF 'no edit-landing receipt' \
  && ! printf '%s' "$ERR_GX" | grep -qF 'git could not list this worktree'
check "R6a once a safe.directory exception clears the refusal, the same chain meets the receipt refusal" "$(verdict $?)"

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
remedy_bound "$VR_ERR"
check "D1b the verdict refusal's remedy names the bound root through --project-root" "$(verdict $?)"
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
# `unreadable` is the state this feature ADDED the discrimination for — the reader
# splits an I/O fault from a content fault (`out = (e && e.code) ? "unreadable" :
# "unparseable"`) precisely because reporting an EACCES receipt as "does not
# parse" named the wrong cause and prescribed a remedy that would hit the same
# fault. It had no executed case: misspell the `unreadable)` label and the `*)`
# catch-all fires, telling the author "node is unavailable" for an unreadable
# file, with the suite green. The oversize arm reaches it deterministically and
# needs no permission change, so it works as an ordinary user and as root.
dd if=/dev/zero of="$V_RECEIPT" bs=1 count=1 seek=4194304 >/dev/null 2>&1
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
VR_RC=$?
{ [ "$VR_RC" -ne 0 ] && printf '%s' "$VR_ERR" | grep -qF 'it is not a regular file of bounded size'; }
check "D8 an oversized receipt is refused as unreadable, naming the size condition" "$(verdict $?)"
! printf '%s' "$VR_ERR" | grep -qF 'node is unavailable'
check "D8a the unreadable state is not reported as the residual node-unavailable one" "$(verdict $?)"
# The remedy paragraph used to be appended UNCONDITIONALLY, so all six states
# closed with "LAND the claimed edit … the run log is append-only". That is true
# of `unclean` alone: landing an edit cannot make an unreadable file readable,
# and for a corrupt or unknown-schema receipt every claimed edit may already have
# landed. Naming the right cause and then prescribing a remedy for a different
# one is the exact class this feature's own reader-discrimination fixed one layer
# down.
! printf '%s' "$VR_ERR" | grep -qF 'LAND the claimed edit'
check "D10 a file-fault refusal does not prescribe the claims remedy" "$(verdict $?)"
printf '%s' "$VR_ERR" | grep -qF 'Re-run the Phase 6 step 5b audit'
check "D10a every refusal still closes with the re-run line" "$(verdict $?)"
plant_receipt '{"schema":"edit-landing-v2","clean":false}'
VR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_V" 2>&1 >/dev/null)"
printf '%s' "$VR_ERR" | grep -qF 'LAND the claimed edit'
check "D10b the claims remedy survives on the one state it is true of" "$(verdict $?)"

echo "== An unresolved run log is disclosed on the ARMED path too =="
# The whole UNRESOLVED block used to be nested inside `_tc_armed -eq 0`, and both
# of its messages open with "the anchor reports no changed files". The run-log
# RESOLUTION was deliberately lifted out of that nesting — gating it made the stem
# cross-check unreachable on the dominant path, a dirty tree — but the DISCLOSURE
# of a failed resolution was left behind. So on a dirty tree with `--plan` passed
# and an unresolvable run log, the stem cross-check is silently skipped and a
# clean receipt naming an unrelated run log satisfies the gate with nothing
# written to any channel. That is exactly what `REQUIREMENTS GATE UNRESOLVED`
# exists to prevent one gate over: "the check passed" and "no check was run" must
# not read the same.
activate_session gate-armed-log
bash "$LOG" --tdd-begin --session gate-armed-log >/dev/null 2>&1
# A real, usable plan whose sibling run log does NOT exist: the requirements gate
# must pass so the only thing left to observe is the run-log channel.
mkdir -p "$PROJ/.zensu/plans"
cat > "$PROJ/.zensu/plans/never-written.md" <<'PLANEOF'
# Zensu Plan: armed-log fixture

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the armed path discloses an unresolved run log | fixture |
PLANEOF
mkdir -p "$(dirname "$(receipt_for gate-armed-log)")"
# The receipt names the SAME stem as the plan, so the requirements gate's own
# stem bind is satisfied and the only unresolved thing left is the run log file
# itself, which was never written. That isolates the channel under test.
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/never-written.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-armed-log)"
AL_ERR="$(bash "$LOG" --tdd-complete --session gate-armed-log \
  --plan "$PROJ/.zensu/plans/never-written.md" 2>&1 >/dev/null)"
AL_RC=$?
[ "$AL_RC" -eq 0 ]
check "Z11-control an unresolvable run log does not block completion on an armed tree" "$(verdict $?)"
printf '%s' "$AL_ERR" | grep -qF 'EDIT LANDING GATE UNRESOLVED'
check "Z11 a failed run-log resolution is disclosed even when the gate is armed by a dirty tree" "$(verdict $?)"
! printf '%s' "$AL_ERR" | grep -qF 'the anchor reports no changed files'
check "Z11a the armed disclosure does not claim the anchor reported no changed files" "$(verdict $?)"

echo "== One artifact, two reads, one hardening =="
# The receipt is read TWICE inside one invocation of this verb, about two hundred
# lines apart, with a `bash … --inventory` child in between. Read #1 (the verdict
# reader) opens `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, `fstat`s the descriptor and
# loop-reads. Read #2 (the requirements gate's own reader) used `lstatSync`
# followed by `readFileSync` — a SECOND path resolution with no O_NOFOLLOW and no
# O_NONBLOCK. `.zensu/state/` is writable from inside the session, so a co-tenant
# that replaces the receipt with a FIFO between the two makes `readFileSync`
# block in `open(2)` forever; the call site is a bare command substitution with
# `|| true`, which tests an exit status and can do nothing about a hang.
#
# The window is a race, so it cannot be staged deterministically from a fixture.
# The property that CAN be checked is the one that closes it: read #2 opens a
# descriptor and judges THAT, exactly as read #1 does.
# The end anchor is the reader function's own closing brace. A range whose end
# pattern never matches runs to EOF in awk, and the whole rest of the file then
# satisfies every needle below — which is exactly what the first spelling of this
# check did, reporting PASS for an O_NOFOLLOW that lives 700 lines further down.
RQ_MODULE="$PLUGIN_DIR/hooks/lib/edit-landing-receipt-v1.js"
RQ_READER="$(awk '/^function readBoundedJson\(/,/^}$/' "$RQ_MODULE")"
RQ_READER_LINES="$(printf '%s\n' "$RQ_READER" | grep -c .)"
MODULE_ALL_LINES="$(grep -c . "$RQ_MODULE")"
{ [ "$RQ_READER_LINES" -gt 10 ] && [ "$RQ_READER_LINES" -lt "$MODULE_ALL_LINES" ] \
  && grep -qF 'main(["receipt-log"])' "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && grep -qF 'readBoundedJson(options.receiptPath' "$RQ_MODULE"; }
check "W4-control the requirements gate reads the receipt through the module's extracted, bounded reader" "$(verdict $?)"
# Comment lines are stripped: the absence assertion below is about CODE, and the
# comment recording why the old spelling was wrong legitimately names it.
RQ_CODE="$(printf '%s\n' "$RQ_READER" | grep -vE '^[[:space:]]*//')"
printf '%s' "$RQ_CODE" | grep -qF 'O_NOFOLLOW'
check "W4 the requirements-gate receipt read opens with O_NOFOLLOW" "$(verdict $?)"
printf '%s' "$RQ_CODE" | grep -qF 'O_NONBLOCK'
check "W4a the same read opens with O_NONBLOCK, so a FIFO cannot block the verb" "$(verdict $?)"
printf '%s' "$RQ_CODE" | grep -qF 'fstatSync'
check "W4b the same read judges the DESCRIPTOR rather than re-resolving the path" "$(verdict $?)"
! printf '%s' "$RQ_CODE" | grep -qF 'readFileSync'
check "W4c the same read no longer re-opens the receipt by path" "$(verdict $?)"

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
SCH_DERIVE="$(grep -cF "RECEIPT_SCHEMAS = Object.freeze({ 'edit-landing-v1': 1, 'edit-landing-v2': 2 })" "$SCH_LIB/edit-landing-receipt-v1.js" 2>/dev/null)"; SCH_DERIVE="${SCH_DERIVE:-0}"
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
for _sch_f in "$SCH_LIB/zensu-edit-landing.sh" "$SCH_LIB/zensu-log.sh" "$SCH_LIB/edit-landing-receipt-v1.js" "$SCH_LIB/zensu-doctor-report.js"; do
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

# Z12 — a claim inventory that could not COMPLETE still answers a lower bound,
# and the arming must use it. The child breaks, prints the partial
# `claimed-files=` it already counted, and exits non-zero; the consumer mapped
# every non-zero rc to `_tc_log_claims=0`, so `_tc_armed` stayed 0 and the
# receipt requirement DISARMED. A run log naming more claims than the child can
# process therefore armed LESS than one naming three — the inversion is the
# defect, not the truncation. A partial count is a sound lower bound: the claims
# it counted are claims that exist.
# Under `.zensu/`, which this fixture gitignores: anywhere else the mkdir makes
# the anchor dirty and the chain then arms on the CHANGE SET, which is the one
# thing this case must not be graded by.
# Restore the anchor first. Earlier cases modify `tracked.txt`, and a dirty tree
# arms the requirement through the CHANGE SET — the inventory is then never run
# and this case would pass for the one reason it must not.
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c core.hooksPath=/dev/null checkout -- . >/dev/null 2>&1
# Earlier cases also leave untracked scratch directories in the fixture root.
# Exclude them locally rather than deleting them — another case may still be
# holding one — and do it generically, so a scratch directory added later does
# not silently re-dirty this anchor and re-grade the case by the change set.
mkdir -p "$PROJ/.git/info"
git -C "$PROJ" status --porcelain 2>/dev/null \
  | awk '$1 == "??" { sub(/^\?\? /, ""); print }' >> "$PROJ/.git/info/exclude" 2>/dev/null
Z12_CLEAN="$(git -C "$PROJ" status --porcelain 2>/dev/null)"
[ -z "$Z12_CLEAN" ]
check "Z12-clean the anchor is clean, so the claim channel is what arms this case" "$(verdict $?)"
Z12_DEEP="$PROJ/.zensu/deep"; Z12_I=0
while [ "$Z12_I" -lt 70 ]; do Z12_DEEP="$Z12_DEEP/d"; Z12_I=$((Z12_I+1)); done
mkdir -p "$Z12_DEEP"
printf 'x\n' > "$Z12_DEEP/f.txt"
printf 'BUILD STARTED — budget fixture\nS1 IMPL completed — files: tracked.txt\nS2 IMPL completed — files: %s/f.txt\n' "$Z12_DEEP" \
  > "$PROJ/.zensu/logs/budget-claim.log"
clean_arm gate-budget-claim
CC_ERR="$(bash "$LOG" --tdd-complete --session gate-budget-claim \
  --plan "$PROJ/.zensu/plans/budget-claim.md" 2>&1 >/dev/null)"
CC_RC=$?
[ "$CC_RC" -ne 0 ]
check "Z12-pre the budget fixture reaches a refusal at all (Z12a is the arming claim)" "$(verdict $?)"
printf '%s' "$CC_ERR" | grep -qF 'no edit-landing receipt'
check "Z12a the armed refusal is the receipt refusal, not a disarmed pass" "$(verdict $?)"
# And it must SAY so. The old disclosure lived inside `_tc_armed -eq 0`, so
# arming on the partial count would have deleted the only line telling anyone the
# inventory was truncated — trading a silent disarm for a silent arm.
printf '%s' "$CC_ERR" | grep -qF 'CLAIM INVENTORY INCOMPLETE'
check "Z12b the truncation is disclosed even though the chain armed" "$(verdict $?)"
# Control: a log the child CAN process reaches the same refusal with no
# incompleteness line, so Z12b cannot pass by printing that line unconditionally.
CC_ERR_OK="$(bash "$LOG" --tdd-complete --session gate-clean-claim \
  --plan "$PROJ/.zensu/plans/clean-claim.md" 2>&1 >/dev/null)"
CC_RC_OK=$?
# Conjoined on the armed refusal: an absence alone is satisfied by the gate
# never arming, which is the one state that would stop Z12b discriminating.
# Conjoined on the gate having RUN — a non-zero exit is what proves it armed,
# and which refusal it reached depends on fixture order earlier in this file.
# An absence alone is satisfied by the gate never arming, which is the one state
# that would stop Z12b discriminating.
{ [ "$CC_RC_OK" -ne 0 ] && ! printf '%s' "$CC_ERR_OK" | grep -qF 'CLAIM INVENTORY INCOMPLETE'; }
check "Z12b-control a completable inventory arms and emits no incompleteness line" "$(verdict $?)"

# Z13 — the stem cross-check is conjoined on BOTH the chain's run log and the
# receipt's `log` field being non-empty, and the ARMED disclosure beside it
# covers only the run-log-empty cell. The other cell — the run log resolved, the
# receipt's `log` absent or not a string — passed with neither the check nor a
# word, which is the exact shape both disclosures exist to remove: a skipped
# check reading like a passed one. The receipt is a file in `.zensu/state/`, so
# dropping one field is the cheapest way to reach it.
printf 'BUILD STARTED — nolog fixture\nS1 IMPL completed — files: tracked.txt\n' \
  > "$PROJ/.zensu/logs/nolog.log"
clean_arm gate-nolog
mkdir -p "$(dirname "$(receipt_for gate-nolog)")"
printf '{"schema":"edit-landing-v2","session":"x","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-nolog)"
CC_ERR_NL="$(bash "$LOG" --tdd-complete --session gate-nolog \
  --plan "$PROJ/.zensu/plans/nolog.md" 2>&1 >/dev/null)"
printf '%s' "$CC_ERR_NL" | grep -qF 'EDIT LANDING GATE UNRESOLVED'
check "Z13 a clean receipt with no \`log\` field is disclosed, not silently accepted" "$(verdict $?)"
printf '%s' "$CC_ERR_NL" | grep -qF 'never cross-checked'
check "Z13a the disclosure names the check that was skipped" "$(verdict $?)"
# Control: the same receipt WITH a matching `log` is accepted in silence, so Z13
# cannot pass by printing the line unconditionally.
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/nolog.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-nolog)"
CC_ERR_NL2="$(bash "$LOG" --tdd-complete --session gate-nolog \
  --plan "$PROJ/.zensu/plans/nolog.md" 2>&1 >/dev/null)"
{ ! printf '%s' "$CC_ERR_NL2" | grep -qF 'EDIT LANDING GATE UNRESOLVED'; }
check "Z13-control a receipt naming THIS run log is accepted without the line" "$(verdict $?)"

# Z14 — the retirement reported SUCCESS for a receipt it did not retire. Its
# first line is `[ -f ] && [ ! -L ] || return 0`, so a SYMLINK at that path —
# which is exactly the shape the terminus refuses to read — took the "nothing to
# do" exit, the RECEIPT RETIREMENT UNRESOLVED disclosure never fired, and the
# link survived into the next generation. Harmless today only because a second
# check downstream refuses it; the retirement's own contract ("renamed, never
# unlinked") was silently not honoured and rested on a guard this function does
# not know about.
clean_arm gate-symlink-receipt
mkdir -p "$(dirname "$(receipt_for gate-symlink-receipt)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":1,"clean":true}\n' \
  > "$PROJ/.zensu/state/receipt-target.json"
ln -sf "$PROJ/.zensu/state/receipt-target.json" "$(receipt_for gate-symlink-receipt)"
if [ -L "$(receipt_for gate-symlink-receipt)" ]; then
  Z14_ERR="$(bash "$LOG" --tdd-begin --session gate-symlink-receipt 2>&1 >/dev/null)"
  printf '%s' "$Z14_ERR" | grep -qF 'RECEIPT RETIREMENT UNRESOLVED'
  check "Z14 a symlinked receipt is reported unretired rather than silently left" "$(verdict $?)"
  [ -L "$(receipt_for gate-symlink-receipt)" ]
  check "Z14a the link itself is left in place — this verb renames, it never unlinks" "$(verdict $?)"
else
  check "Z14 SKIPPED — this host made no symlink, so ln -s copied the receipt" PASS
  check "Z14a SKIPPED — this host made no symlink, so ln -s copied the receipt" PASS
fi
# Control: an ORDINARY receipt is retired in silence, so Z14 cannot pass by
# printing the line for every arming.
clean_arm gate-plain-receipt
mkdir -p "$(dirname "$(receipt_for gate-plain-receipt)")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/clean-claim.log","claims":1,"clean":true}\n' \
  > "$(receipt_for gate-plain-receipt)"
Z14_OK="$(bash "$LOG" --tdd-begin --session gate-plain-receipt 2>&1 >/dev/null)"
{ ! printf '%s' "$Z14_OK" | grep -qF 'RECEIPT RETIREMENT UNRESOLVED'; }
check "Z14-control an ordinary receipt is retired without the line" "$(verdict $?)"
# Z14b — the mktemp-failure fallback reinstated the FIXED `.superseded` name: the
# `mv -f` could overwrite an earlier generation's record, and the cleanup
# `rm -f "$dest"` then UNLINKED a pre-existing one — both against this verb's own
# "renamed, never unlinked" invariant. A directory where `mktemp` cannot create a
# sibling is one where the `mv` would fail anyway, so the fallback bought nothing
# and cost a destroy primitive.
# Scoped to a NON-COMMENT line: the rationale beside the fix quotes the retired
# spelling, so a bare file-wide needle matches the comment explaining why the
# code is gone and the check can never pass.
# `[^#[:space:]]` CONSUMES the first non-space character, so against a
# standalone `            dest="${receipt}.superseded"` the `.*dest=` that
# follows has no second `dest=` left to find — that regex could only ever match
# a form carrying the assignment twice on one line, which is not the shape a
# reintroduction takes. Strip comments and search for the fixed string, and
# prove the pipeline reports a PLANTED one rather than asserting an absence
# nothing establishes is detectable.
Z14B_CODE="$(grep -vE '^[[:space:]]*#' "$LOG")"
{ ! printf '%s\n' "$Z14B_CODE" | grep -qF 'dest="${receipt}.superseded"'; }
check "Z14b the retirement has no fixed-name fallback to overwrite or unlink" "$(verdict $?)"
Z14B_PROBE="$PROJ/.zensu/z14b-probe.sh"
{ printf '%s\n' "$Z14B_CODE"; printf '            dest="${receipt}.superseded"\n'; } > "$Z14B_PROBE"
grep -vE '^[[:space:]]*#' "$Z14B_PROBE" | grep -qF 'dest="${receipt}.superseded"'
check "Z14b-control the same pipeline DOES report a planted fixed-name fallback" "$(verdict $?)"

# Z15 — the comments that describe the hardened receipt reader. Both named
# `lstatSync` as the mechanism after the reader stopped using it: the derived
# channel now opens with `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, `fstat`s the
# DESCRIPTOR and reads in a bounded loop inside `try/finally`. A comment that
# names a retired mechanism is worse than none — the next reader trusts it and
# looks for a guard that is not there.
Z15_RE='^[[:space:]]*#.*reader below refuses one outright \(`lstatSync`\)'
{ ! grep -nE "$Z15_RE" "$LOG" >/dev/null; }
check "Z15 no comment still names lstatSync as the derived reader's mechanism" "$(verdict $?)"
# Prove the expression BITES. An absence assertion over one exact historical
# byte-string says nothing until something establishes it can match at all, and
# the token `lstatSync` legitimately survives elsewhere in this file, so a bare
# token search is not that proof either.
Z15_PROBE="$PROJ/.zensu/z15-probe.txt"
printf '          # reader below refuses one outright (`lstatSync`). Without this\n' > "$Z15_PROBE"
grep -nE "$Z15_RE" "$Z15_PROBE" >/dev/null
check "Z15-control the same expression DOES report the retired sentence" "$(verdict $?)"
grep -qF 'O_NOFOLLOW' "$LOG"
check "Z15a the hardened open really is in this file" "$(verdict $?)"
# Z16 — the two consumers of ONE inventory child read its non-zero status
# DIFFERENTLY on purpose, and that has to be written down at both sites or the
# next maintainer "aligns" them and reintroduces the disarm. The terminus trusts
# a partial `claimed-files=` as a lower bound for ARMING; the doctor discards the
# whole answer, because a truncated ROOT LIST is not trustworthy for a row that
# names repositories.
# LINE-LOCAL needle: the sentence wraps in the source, and `grep -F` over a
# phrase that crosses a line break can never match.
grep -qF 'discards the whole answer' "$LOG"
check "Z16 the terminus records why it reads a truncated inventory differently" "$(verdict $?)"
grep -qF 'discards the whole answer' "$PLUGIN_DIR/hooks/lib/zensu-doctor-report.js"
check "Z16a the doctor side carries the same note, so neither is aligned to the other" "$(verdict $?)"

echo "== A work-tree receipt on a chain that works in the anchor =="
WA_SID=gate-wt-standalone
WA_STEM="2026-10-29-0001_build-wt-standalone"
cat > "$PROJ/.zensu/plans/$WA_STEM.md" <<'PLAN'
# Standalone work-tree fixture plan

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the tracked file changed | spec |
PLAN
printf '%s\n' '[10:00:00] S1 IMPL completed — files: tracked.txt' > "$PROJ/.zensu/logs/$WA_STEM.log"
clean_arm "$WA_SID"
WA_RECEIPT="$(receipt_for "$WA_SID")"
mkdir -p "$(dirname "$WA_RECEIPT")"
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/%s.log","claims":1,"clean":true,"workTree":".claude/worktrees/wt"}\n' \
  "$WA_STEM" > "$WA_RECEIPT"
WA_ERR="$(bash "$LOG" --tdd-complete --session "$WA_SID" --plan "$PROJ/.zensu/plans/$WA_STEM.md" 2>&1 >/dev/null)"; WA_RC=$?
printf '{"schema":"edit-landing-v2","session":"x","log":".zensu/logs/%s.log","claims":1,"clean":true}\n' \
  "$WA_STEM" > "$WA_RECEIPT"
bash "$LOG" --tdd-complete --session "$WA_SID" --plan "$PROJ/.zensu/plans/$WA_STEM.md" >/dev/null 2>&1; WA_CTL_RC=$?
{ [ "$WA_RC" -ne 0 ] && [ "$WA_CTL_RC" -eq 0 ] \
  && printf '%s' "$WA_ERR" | grep -qF 'graded a work tree other than the anchor, but this chain works in the anchor itself'; }
check "WA1 a standalone chain refuses a receipt that graded a work tree and completes on the same receipt without it (rc=$WA_RC/$WA_CTL_RC)" "$(verdict $?)"

echo "== A bound chain whose Autopilot run drives a worktree below the anchor =="
# shellcheck disable=SC1091
source "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
cd "$PROJ" || exit 1
printf '.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$PROJ/.gitignore"
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null add .gitignore >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null commit -qm ignore-worktrees >/dev/null 2>&1
git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/wt" -b wt-bound >/dev/null 2>&1
WTB="$(cd "$PROJ/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
PROJ_CANON="$(cd "$PROJ" && pwd -P)"
mkdir -p "$WTB/locales/en" "$WTB/locales/de"
printf '{}\n' > "$WTB/locales/en/settings.json"
printf '{}\n' > "$WTB/locales/de/settings.json"
printf '{}\n' > "$WTB/locales/en/ghost.json"
printf '{}\n' > "$WTB/locales/de/ghost.json"
SID_WT=gate-wt-bound
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID_WT"
activate_session "$SID_WT"
WT_KEY="$(basename "$(tdd_state_file "$SID_WT")")"; WT_KEY="${WT_KEY#tdd-phase-}"; WT_KEY="${WT_KEY%.json}"
WT_STANDALONE="$(bash "$LOG" --chain-work-tree --session "$SID_WT" 2>/dev/null)"
autopilot_begin_run wt_run "$WT_KEY" "$PROJ" false true "$WTB" >/dev/null 2>&1; WTB_BEGIN=$?
autopilot_apply_event wt_run plan-wt_run PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$(printf 'a%.0s' $(seq 1 64))\"}" "$PROJ" >/dev/null 2>&1; WTB_PLAN=$?
bash "$LOG" --tdd-begin --session "$SID_WT" --autopilot-run wt_run --autopilot-attempt 1 \
  --autopilot-return-stage GATES --chain-id wt-chain >/dev/null 2>&1; WTB_ARM=$?
{ [ -n "$WTB" ] && [ "$WTB_BEGIN" -eq 0 ] && [ "$WTB_PLAN" -eq 0 ] && [ "$WTB_ARM" -eq 0 ]; }
check "WB0 an Autopilot run records the nested worktree as its workspace and arms a bound chain" "$(verdict $?)"
[ "$WT_STANDALONE" = "$PROJ_CANON" ]
check "WB1 before the binding, --chain-work-tree answers the anchor's top level (got '$WT_STANDALONE')" "$(verdict $?)"
WT_BOUND="$(bash "$LOG" --chain-work-tree --session "$SID_WT" 2>/dev/null)"; WT_BOUND_RC=$?
{ [ "$WT_BOUND_RC" -eq 0 ] && [ "$WT_BOUND" = "$WTB" ]; }
check "WB2 for the bound chain --chain-work-tree answers the run's own worktree (got '$WT_BOUND')" "$(verdict $?)"
WT_STEM="2026-10-29-0000_build-wt-bound"
mkdir -p "$PROJ/.zensu/plans" "$PROJ/.zensu/logs"
cat > "$PROJ/.zensu/plans/$WT_STEM.md" <<'PLAN'
# Work-tree fixture plan

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | both locale files exist in the run's worktree | spec |
PLAN
printf '%s\n' '[10:00:00] S1 IMPL completed — files: locales/{en,de}/settings.json, locales/*/ghost.json' > "$PROJ/.zensu/logs/$WT_STEM.log"
WT_RECEIPT="$(receipt_for "$SID_WT")"
mkdir -p "$(dirname "$WT_RECEIPT")"
printf '{"schema":"edit-landing-v2","session":"%s","log":".zensu/logs/%s.log","claims":2,"landed":2,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true}\n' \
  "$SID_WT" "$WT_STEM" > "$WT_RECEIPT"
WT_ANCHOR_ERR="$(bash "$LOG" --tdd-complete --session "$SID_WT" --plan "$PROJ/.zensu/plans/$WT_STEM.md" \
  --autopilot-run wt_run --autopilot-attempt 1 --chain-id wt-chain 2>&1 >/dev/null)"; WT_ANCHOR_RC=$?
{ [ "$WT_ANCHOR_RC" -ne 0 ] && printf '%s' "$WT_ANCHOR_ERR" | grep -qF "graded the anchor's own change set" \
  && printf '%s' "$WT_ANCHOR_ERR" | grep -qF -- '--work-tree'; }
check "WB3 a clean receipt the audit wrote for the anchor is refused for a work-tree chain, with a --work-tree remedy" "$(verdict $?)"
wt_receipt() {
  printf '{"schema":"edit-landing-v2","session":"%s","log":".zensu/logs/%s.log","claims":2,"landed":2,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true%s}\n' \
    "$SID_WT" "$WT_STEM" "$1" > "$WT_RECEIPT"
}
wt_complete() {
  bash "$LOG" --tdd-complete --session "$SID_WT" --plan "$PROJ/.zensu/plans/$WT_STEM.md" \
    --autopilot-run wt_run --autopilot-attempt 1 --chain-id wt-chain 2>&1 >/dev/null
}
WT_TREE_REMEDY='--work-tree "<the path zensu-log.sh --chain-work-tree prints>"'
wt_receipt ',"workTree":7'
WT_UNREAD_ERR="$(wt_complete)"; WT_UNREAD_RC=$?
wt_receipt ',"workTree":".claude/worktrees"'
WT_OTHER_ERR="$(wt_complete)"; WT_OTHER_RC=$?
{ [ "$WT_UNREAD_RC" -ne 0 ] && [ "$WT_OTHER_RC" -ne 0 ] \
  && printf '%s' "$WT_UNREAD_ERR" | grep -qF "names a work tree that is not this Autopilot-bound chain's work tree" \
  && printf '%s' "$WT_OTHER_ERR" | grep -qF "names a work tree that is not this Autopilot-bound chain's work tree" \
  && printf '%s' "$WT_UNREAD_ERR" | grep -qF -- "$WT_TREE_REMEDY" \
  && printf '%s' "$WT_OTHER_ERR" | grep -qF -- "$WT_TREE_REMEDY"; }
check "WB13 a clean receipt naming an unreadable or another work tree is refused for the bound chain, with a --work-tree remedy" "$(verdict $?)"
WT_RUN_FILE="$(autopilot_run_file wt_run "$PROJ_CANON")"
WT_RUN_PRE="$PROJ_CANON/.zensu/wt-run.pre"
cp "$WT_RUN_FILE" "$WT_RUN_PRE"
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); delete s.workspaceRoot; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$WT_RUN_FILE"
wt_receipt ',"workTree":".claude/worktrees/wt"'
WT_ANCHORED_ERR="$(wt_complete)"; WT_ANCHORED_RC=$?
cp "$WT_RUN_PRE" "$WT_RUN_FILE"
WT_ANCHORED_REMEDY="$(printf '%s\n' "$WT_ANCHORED_ERR" | grep -F 'zensu-edit-landing.sh')"
{ [ "$WT_ANCHORED_RC" -ne 0 ] \
  && printf '%s' "$WT_ANCHORED_ERR" | grep -qF 'graded a work tree other than the anchor, but this chain works in the anchor itself' \
  && [ -n "$WT_ANCHORED_REMEDY" ] && ! printf '%s' "$WT_ANCHORED_REMEDY" | grep -qF -- '--work-tree'; }
check "WB14 a work-tree receipt is refused once the run record resolves the chain to the anchor, and its remedy drops --work-tree" "$(verdict $?)"
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.workspaceRoot = process.argv[2]; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$WT_RUN_FILE" "$PROJ_CANON/.claude/worktrees/gone"
WT_GONE_ERR="$(wt_complete)"; WT_GONE_RC=$?
cp "$WT_RUN_PRE" "$WT_RUN_FILE"
{ [ "$WT_GONE_RC" -ne 0 ] \
  && printf '%s' "$WT_GONE_ERR" | grep -qF 'the work tree of this Autopilot-bound chain could not be resolved' \
  && printf '%s' "$WT_GONE_ERR" | grep -qF 'work tree not found'; }
check "WB15 a workspaceRoot that names no work tree refuses --tdd-complete and names the resolver's cause" "$(verdict $?)"
WT_INDEX="$(git -C "$WTB" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
WT_INDEX_PRE="$PROJ_CANON/.zensu/wt-index.pre"
cp -p "$WT_INDEX" "$WT_INDEX_PRE"
printf 'not an index\n' > "$WT_INDEX"
git -C "$WTB" diff --name-only HEAD >/dev/null 2>&1; WT_INDEX_GIT_RC=$?
WT_INDEX_ERR="$(wt_complete)"; WT_INDEX_RC=$?
cp -p "$WT_INDEX_PRE" "$WT_INDEX"
{ [ -n "$WT_INDEX" ] && [ "$WT_INDEX_GIT_RC" -ne 0 ] && [ "$WT_INDEX_RC" -ne 0 ] \
  && printf '%s' "$WT_INDEX_ERR" | grep -qF "git could not list the changes of the project root or of this chain's work tree" \
  && printf '%s' "$WT_INDEX_ERR" | grep -qF 'zensu-log.sh --chain-work-tree prints'; }
check "WB16 a work tree git cannot list refuses --tdd-complete instead of counting it as unchanged" "$(verdict $?)"
wt_receipt ''
bash "$LIB" --log "$PROJ/.zensu/logs/$WT_STEM.log" --project "$PROJ" --work-tree "$WTB" \
  --session "$SID_WT" >"$PROJ/wt-audit.out" 2>&1; WT_AUDIT_RC=$?
{ [ "$WT_AUDIT_RC" -eq 0 ] && grep -qF '"workTree":".claude/worktrees/wt"' "$WT_RECEIPT" \
  && grep -qF '"clean":true' "$WT_RECEIPT"; }
check "WB4 the audit over the run's worktree grades the brace and glob claims clean and records workTree in this session's receipt" "$(verdict $?)"
WT_DONE_ERR="$(bash "$LOG" --tdd-complete --session "$SID_WT" --plan "$PROJ/.zensu/plans/$WT_STEM.md" \
  --autopilot-run wt_run --autopilot-attempt 1 --chain-id wt-chain 2>&1 >/dev/null)"; WT_DONE_RC=$?
[ "$WT_DONE_RC" -eq 0 ]
check "WB5 the reference shape completes --tdd-complete without a bypass (rc=$WT_DONE_RC)" "$(verdict $?)"
[ "$WT_DONE_RC" -eq 0 ] || printf '%s\n' "$WT_DONE_ERR" | head -6 | sed 's/^/        /'
grep -qF '_zensu_unqualified_change_count "$_tc_wt"' "$LOG"
check "WB6 --tdd-complete counts the bound work tree through the shared change-count helper" "$(verdict $?)"
WT_LOG_FILE="$PROJ_CANON/.zensu/logs/$WT_STEM.log"
WT_BASE_SHA="$(git -C "$WTB" rev-parse HEAD 2>/dev/null)"
WT_RP0="$(bash "$LOG" --round-prepare --round 0 --log "$WT_LOG_FILE" --baseline "$WT_BASE_SHA" 2>&1)"; WT_RP0_RC=$?
WT_SNAP="$PROJ_CANON/.zensu/state/round-snapshot-$WT_KEY.json"
{ [ "$WT_RP0_RC" -eq 0 ] \
  && grep -qF 'ROUND PREPARE — round 0 recorded the round-start snapshot (4 changed files)' "$WT_LOG_FILE" \
  && node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.exit(d.top === process.argv[2] ? 0 : 1)' "$WT_SNAP" "$WTB"; }
check "WB7 round 0 of the bound chain snapshots the run's worktree and logs into the anchor's run log" "$(verdict $?)"
[ "$WT_RP0_RC" -eq 0 ] || printf '%s\n' "$WT_RP0" | head -6 | sed 's/^/        /'
printf '{"a":1}\n' > "$WTB/locales/en/settings.json"
printf '%s\n' '[10:01:00] R1-F1 IMPL completed — files: locales/en/settings.json' >> "$WT_LOG_FILE"
WT_RP1="$(bash "$LOG" --round-prepare --round 1 --log "$WT_LOG_FILE" --baseline "$WT_BASE_SHA" 2>&1)"; WT_RP1_RC=$?
WT_DIFF="$PROJ_CANON/.zensu/state/round-diff-$WT_KEY.patch"
{ [ "$WT_RP1_RC" -eq 0 ] \
  && printf '%s\n' "$WT_RP1" | grep -qxF 'ROUND LANDING — R1-F1: landed (files=1 changed=1 unchanged=0 unresolved=0 failed=0)' \
  && printf '%s\n' "$WT_RP1" | grep -E '^changed_files \(' | grep -qF '.claude/worktrees/wt/locales/en/settings.json' \
  && printf '%s\n' "$WT_RP1" | grep -E '^judge_changed_files: ' | grep -qF '.claude/worktrees/wt/locales/en/settings.json' \
  && grep -qF 'b/.claude/worktrees/wt/locales/en/settings.json' "$WT_DIFF" \
  && grep -qF 'EDIT LANDING AUDIT STARTED — round fix-1' "$WT_LOG_FILE" \
  && grep -qF '"workTree":".claude/worktrees/wt"' "$WT_RECEIPT"; }
check "WB8 a fix round of the bound chain grades its claim in the run's worktree and prints the reviewer lists and the diff with the worktree prefix" "$(verdict $?)"
[ "$WT_RP1_RC" -eq 0 ] || printf '%s\n' "$WT_RP1" | head -8 | sed 's/^/        /'
WT_CRD_ERR="$(bash "$LOG" --code-review-done --session "$SID_WT" 2>&1 >/dev/null)"; WT_CRD_RC=$?
WT_CD_ERR="$(bash "$LOG" --chain-done --session "$SID_WT" 2>&1 >/dev/null)"; WT_CD_RC=$?
{ [ "$WT_CRD_RC" -ne 0 ] && [ "$WT_CD_RC" -ne 0 ] \
  && printf '%s' "$WT_CD_ERR" | grep -qF 'bound chain requires --autopilot-run, --autopilot-attempt, and --chain-id'; }
check "WB9 the unqualified --code-review-done and --chain-done refuse the bound chain, so --tdd-complete holds its only change count" "$(verdict $?)"
source "$PLUGIN_DIR/tests/structure/lib-autopilot-lease.sh"
WT_RUN_FILE="$(autopilot_run_file wt_run "$PROJ_CANON")"
WT_RUN_SAVED="$PROJ_CANON/wt-run.saved"
cp "$WT_RUN_FILE" "$WT_RUN_SAVED"
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); delete s.workspaceRoot; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$WT_RUN_FILE"
WT_LEGACY="$(bash "$LOG" --chain-work-tree --session "$SID_WT" 2>&1)"; WT_LEGACY_RC=$?
{ [ "$WT_LEGACY_RC" -eq 0 ] && [ "$WT_LEGACY" = "$PROJ_CANON" ]; }
check "WB10 a legacy run record without workspaceRoot resolves the chain's work tree to the anchor's top (got '$WT_LEGACY')" "$(verdict $?)"
WT_OUTSIDE_PARENT="$(mktemp -d)"
git -C "$PROJ_CANON" worktree add -q "$WT_OUTSIDE_PARENT/outside" -b wt-run-outside >/dev/null 2>&1
WT_OUTSIDE="$(cd "$WT_OUTSIDE_PARENT/outside" 2>/dev/null && pwd -P)"
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.workspaceRoot = process.argv[2]; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$WT_RUN_FILE" "$WT_OUTSIDE"
WT_FAULT_ERR="$(bash "$LOG" --chain-work-tree --session "$SID_WT" 2>&1 >/dev/null)"; WT_FAULT_RC=$?
{ [ -n "$WT_OUTSIDE" ] && [ "$WT_FAULT_RC" -ne 0 ] && printf '%s' "$WT_FAULT_ERR" | grep -qF 'does not lie below the project root'; }; WT_FAULT_OK=$?
check "WB11 a workspaceRoot outside the project root fails the resolver with the topology reason instead of falling back to the anchor" "$(verdict $WT_FAULT_OK)"
[ "$WT_FAULT_OK" -eq 0 ] || printf '%s\n' "rc=$WT_FAULT_RC $WT_FAULT_ERR" | head -3 | sed 's/^/        /'
cp "$WT_RUN_SAVED" "$WT_RUN_FILE"
rm -rf "$WT_OUTSIDE_PARENT"
WT_LEASE_START="$(date +%s)"
WT_LEASED="$(with_autopilot_lease "$PROJ_CANON" bash "$LOG" --chain-work-tree --session "$SID_WT" 2>/dev/null)"; WT_LEASED_RC=$?
WT_LEASE_SECS=$(( $(date +%s) - WT_LEASE_START ))
{ [ "$WT_LEASED_RC" -eq 0 ] && [ "$WT_LEASED" = "$WTB" ] && [ "$WT_LEASE_SECS" -lt 8 ]; }
check "WB12 the resolver answers while another process holds the project lease, so it takes none (${WT_LEASE_SECS}s)" "$(verdict $?)"

echo "----"
echo "test-tdd-complete-receipt-gate: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
