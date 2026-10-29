#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LIB="$PLUGIN_DIR/hooks/lib/round-prepare-v1.js"
EDIT_LANDING="$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh"
UNIT="$PLUGIN_DIR/tests/structure/round-prepare-v1.test.js"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
source "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }
finish() {
  echo "----"
  echo "test-round-prepare: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LOG" "$LIB" "$EDIT_LANDING" "$UNIT" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "RP0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "RP0 node and git are available" FAIL
  finish
  exit 1
fi
check "RP0 required files, node and git are present" PASS

node -e 'const m = require(process.argv[1]); process.exit(m.ciStructureTests.includes("test-round-prepare.sh") ? 0 : 1)' "$PROFILE"
check "RP0a the suite is classified as a CI structure test" "$(verdict $?)"

bash -n "$LOG" && node --check "$LIB" && bash -n "$EDIT_LANDING"
check "RP0c zensu-log.sh, the module and the edit-landing library parse" "$(verdict $?)"

WORK="$(mktemp -d 2>/dev/null)" || { check "RP0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

unit_check "RP0b the round-prepare unit file passes" "$UNIT"

PROJ="$WORK/project"
mkdir -p "$PROJ/src" "$PROJ/docs"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'one\n' > "$PROJ/src/a.js"
printf 'one\n' > "$PROJ/src/b.js"
git -C "$PROJ" add -A
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline
BASE="$(git -C "$PROJ" rev-parse HEAD)"
printf 'two\n' > "$PROJ/src/a.js"
printf 'two\n' > "$PROJ/src/b.js"
printf 'notes\n' > "$PROJ/docs/c.md"

export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || exit 1
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "round-prepare-verb" || { check "RP1 session baseline" FAIL; finish; exit 1; }
mkdir -p "$PROJ/.zensu/logs" "$PROJ/.zensu/state"
RUN="$PROJ/.zensu/logs/run.log"
SNAP="$PROJ/.zensu/state/round-snapshot-$ZENSU_SESSION_KEY.json"
DIFF="$PROJ/.zensu/state/round-diff-$ZENSU_SESSION_KEY.patch"
note() { printf '%s\n' "$1" >> "$RUN"; }
note "S1 IMPL completed — files: src/a.js, src/b.js"
note "S2 IMPL completed — files: docs/c.md"
prep() { bash "$LOG" --round-prepare --log "$RUN" --baseline "$BASE" "$@" 2>"$WORK/prep.err"; }
rounds() { node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(Object.keys(d.rounds).sort().join(","))' "$SNAP" 2>/dev/null; }

OUT0="$(prep --round 0)"; RC0=$?
[ "$RC0" -eq 0 ] && printf '%s' "$OUT0" | grep -qF 'ROUND PREPARE — round 0 recorded the round-start snapshot (3 changed files)' \
  && [ "$(rounds)" = "0" ] && ! grep -qF 'EDIT LANDING AUDIT STARTED' "$RUN" \
  && grep -qF 'ROUND PREPARE — round 0 recorded the round-start snapshot (3 changed files)' "$RUN"
check "RP2 --round 0 records the round-start snapshot of the change set and runs no audit" "$(verdict $?)"

REFUSED=0
prep >/dev/null || [ "$?" -eq 2 ] || REFUSED=1
for bad in 01 x 1000000 -1 ""; do
  prep --round "$bad" >/dev/null
  [ "$?" -eq 2 ] || REFUSED=1
done
bash "$LOG" --round-prepare --round 1 --log "$WORK/elsewhere.log" >/dev/null 2>&1
[ "$?" -eq 2 ] || REFUSED=1
bash "$LOG" --round-prepare --round 1 --log "$RUN" --colour >/dev/null 2>&1
[ "$?" -eq 2 ] || REFUSED=1
bash "$LOG" --round-prepare --round 1 --log "$RUN" --session-epoch 12x >/dev/null 2>&1
[ "$?" -eq 2 ] || REFUSED=1
[ "$REFUSED" -eq 0 ] && [ "$(rounds)" = "0" ]
check "RP3 a missing or malformed --round, a log outside .zensu/logs, an unknown flag and a bad epoch are refused with exit 2 and change nothing" "$(verdict $?)"

note "FINDING LEDGER — R1-F1 routed CRITICAL src/a.js:1 | broken"
note "FINDING LEDGER — R1-F2 parked IMPORTANT src/b.js:1 | later"
printf 'three\n' > "$PROJ/src/a.js"
note "R1-F1 IMPL completed — files: src/a.js"
OUT1="$(prep --round 1)"; RC1=$?
{ [ "$RC1" -eq 0 ] \
  && grep -qF 'EDIT LANDING AUDIT STARTED — round fix-1' "$RUN" \
  && grep -qE 'EDIT LANDING AUDIT — claims=4 ' "$RUN" \
  && grep -qF 'ROUND LANDING — R1-F1: landed (files=1 changed=1 unchanged=0 unresolved=0 failed=0)' "$RUN" \
  && grep -qF 'FINDING LEDGER — R1-F1 fixed CRITICAL src/a.js:1 | broken' "$RUN"; }
check "RP4 a fix round audits, resolves its pending claim against the snapshot and appends the fixed ledger line" "$(verdict $?)"
{ printf '%s' "$OUT1" | grep -qxF 'fixed: R1-F1' \
  && printf '%s' "$OUT1" | grep -qF 'open R1-F2 parked IMPORTANT src/b.js:1 | later' \
  && printf '%s' "$OUT1" | grep -qxF 'changed_files (round-delta): src/a.js, src/b.js' \
  && printf '%s' "$OUT1" | grep -qxF 'judge_changed_files: docs/c.md, src/a.js, src/b.js' \
  && printf '%s' "$OUT1" | grep -qxF 'spawn: correctness' \
  && grep -qF 'ASPECT SKIPPED — design (re-review-lean-panel)' "$RUN" \
  && grep -qF 'ASPECT SKIPPED — security (re-review-lean-panel)' "$RUN"; }
check "RP4a it prints the open ledger, the round-delta panel, the whole list for the judge and the spawn list, and logs the skipped aspects" "$(verdict $?)"
{ printf '%s' "$OUT1" | grep -qF "round_diff: $DIFF" && grep -qF '+three' "$DIFF" && grep -qF 'src/b.js' "$DIFF" \
  && [ "$(rounds)" = "0,1" ] && ! grep -qF "$PROJ" "$RUN"; }
check "RP4b it writes the round diff, records the next snapshot and leaves no absolute project path in the run log" "$(verdict $?)"

note "R2-R1-F2 IMPL completed — files: src/b.js"
OUT2="$(prep --round 2)"; RC2=$?
{ [ "$RC2" -eq 1 ] \
  && printf '%s' "$OUT2" | grep -qF 'ROUND PREPARE STOPPED — edit-landing: 1 claim(s) of this round did not land in this round: R2-R1-F2 (src/b.js unchanged); ' \
  && printf '%s' "$OUT2" | grep -qxF 'ROUND LANDING — R2-R1-F2: not-landed (files=1 changed=0 unchanged=1 unresolved=0 failed=0)' \
  && printf '%s' "$OUT2" | grep -qE '^EDIT LANDING AUDIT — claims=5 ' \
  && ! grep -qF 'FINDING LEDGER — R1-F2 fixed' "$RUN" \
  && grep -qF 'ROUND LANDING — R2-R1-F2: not-landed (files=1 changed=0 unchanged=1 unresolved=0 failed=0)' "$RUN" \
  && [ "$(rounds)" = "0,1" ]; }
check "RP5 a claim whose file did not change since the round began stops the round with exit 1, writes no fixed line and keeps the snapshot" "$(verdict $?)"

printf 'three\n' > "$PROJ/src/b.js"
OUT2B="$(prep --round 2)"; RC2B=$?
{ [ "$RC2B" -eq 0 ] && grep -qF 'FINDING LEDGER — R1-F2 fixed IMPORTANT src/b.js:1 | later' "$RUN" \
  && printf '%s' "$OUT2B" | grep -qxF 'fixed: R1-F2' && [ "$(rounds)" = "0,1,2" ]; }
check "RP6 after the edit lands, the same round passes and a cross-round label fixes the earlier finding" "$(verdict $?)"

OFF_CONFIG="$WORK/off.json"
printf '{"hooks":{"incrementalReviewRounds":false,"aspectActivation":false,"reviewConvergence":false,"reviewPanel":"full"}}\n' > "$OFF_CONFIG"
OUT3="$(ZENSU_CONFIG="$OFF_CONFIG" prep --round 3)"; RC3=$?
{ [ "$RC3" -eq 0 ] \
  && printf '%s' "$OUT3" | grep -qxF 'changed_files (incremental-off): docs/c.md, src/a.js, src/b.js' \
  && printf '%s' "$OUT3" | grep -qxF 'open_ledger: off (hooks.reviewConvergence is off); no fixed line was written' \
  && [ "$(printf '%s\n' "$OUT3" | grep -c '^open_ledger')" -eq 1 ] \
  && printf '%s' "$OUT3" | grep -q '^spawn: .*architecture'; }
check "RP7 the config keys are read: incremental rounds off keep the whole list, convergence off skips the ledger and says so, the full panel spawns over an empty activation input" "$(verdict $?)"

note "FINDING LEDGER — R3-F1 parked IMPORTANT docs/c.md:1 | docs"
printf 'notes fixed\n' > "$PROJ/docs/c.md"
note "SR-R3-F1 IMPL completed — files: docs/c.md"
OUTSR="$(prep --round self-review)"; RCSR=$?
{ [ "$RCSR" -eq 0 ] && grep -qF 'EDIT LANDING AUDIT STARTED — round self-review' "$RUN" \
  && grep -qF 'FINDING LEDGER — R3-F1 fixed IMPORTANT docs/c.md:1 | docs' "$RUN" \
  && ! printf '%s' "$OUTSR" | grep -q '^changed_files' && [ "$(rounds)" = "0,1,2,3" ]; }
check "RP8 the self-review round audits and writes its fixed line without packet fields or a new snapshot" "$(verdict $?)"

rm -f "$SNAP"
note "FINDING LEDGER — R5-F1 routed CRITICAL src/a.js:1 | again"
printf 'four\n' > "$PROJ/src/a.js"
note "R5-F1 IMPL completed — files: src/a.js"
OUT5="$(prep --round 5)"; RC5=$?
{ [ "$RC5" -eq 0 ] && grep -qF 'ROUND LANDING UNAVAILABLE — no round-start snapshot (missing)' "$RUN" \
  && grep -qF 'ROUND LANDING — R5-F1: unresolved (files=1 changed=0 unchanged=0 unresolved=1 failed=0)' "$RUN" \
  && ! grep -qF 'FINDING LEDGER — R5-F1 fixed' "$RUN" && printf '%s' "$OUT5" | grep -qxF 'unresolved_claims: R5-F1'; }
check "RP9 without a round-start snapshot the round is disclosed as unattributable and no fixed line is written" "$(verdict $?)"

STUB="$WORK/stub-bin"
mkdir -p "$STUB"
REAL_MV="$(command -v mv)"
cat > "$STUB/mv" <<EOF
#!/bin/bash
for last in "\$@"; do :; done
case "\$last" in
  */edit-landing-*.json) exit 1 ;;
esac
exec "$REAL_MV" "\$@"
EOF
chmod +x "$STUB/mv"
note "FINDING LEDGER — R6-F1 routed CRITICAL src/a.js:1 | receipt"
printf 'five\n' > "$PROJ/src/a.js"
note "R6-F1 IMPL completed — files: src/a.js"
OUT6="$(PATH="$STUB:$PATH" prep --round 6)"; RC6=$?
{ [ "$RC6" -eq 2 ] \
  && printf '%s' "$OUT6" | grep -qF 'ROUND PREPARE STOPPED — edit-landing: the audit graded the claims but could not write its receipt' \
  && printf '%s' "$OUT6" | grep -qF 'ROUND PREPARE FALLBACK — the round' \
  && grep -qF 'EDIT LANDING AUDIT STARTED — round fix-6' "$RUN" \
  && grep -qF 'RECEIPT REFUSED — the receipt could not be written' "$RUN" \
  && ! grep -qF 'ROUND LANDING — R6-F1' "$RUN" \
  && ! grep -qF 'FINDING LEDGER — R6-F1 fixed' "$RUN" \
  && [ "$(rounds)" = "5" ]; }
check "RP10 a refused edit-landing receipt stops the round with exit 2 before any claim is attributed and keeps the snapshot" "$(verdict $?)"

note "R6-F2 IMPL completed — files: src/b.js"
OUT7="$(prep --round 6)"; RC7=$?
note "CLAIM WITHDRAWN — R6-F2: src/b.js"
OUT7B="$(prep --round 6)"; RC7B=$?
{ [ "$RC7" -eq 1 ] \
  && printf '%s' "$OUT7" | grep -qF 'did not land in this round: R6-F2 (src/b.js unchanged); ' \
  && [ "$RC7B" -eq 0 ] \
  && printf '%s' "$OUT7B" | grep -qxF 'withdrawn_claims: R6-F2' \
  && printf '%s' "$OUT7B" | grep -qxF 'fixed: R6-F1' \
  && grep -qF 'ROUND LANDING — R6-F2: withdrawn (files=1 changed=0 unchanged=0 unresolved=0 failed=0 withdrawn=1)' "$RUN" \
  && grep -qF 'FINDING LEDGER — R6-F1 fixed CRITICAL src/a.js:1 | receipt' "$RUN" \
  && [ "$(rounds)" = "5,6" ]; }
check "RP11 a claim withdrawn after the stop lets the same round pass, with no fixed line for the withdrawn claim" "$(verdict $?)"

note "REVIEW BUDGET RESET — review rounds restart at 1"
printf 'six\n' > "$PROJ/src/a.js"
note "R1-F1 IMPL completed — files: src/a.js"
OUT8="$(prep --round 1)"; RC8=$?
{ [ "$RC8" -eq 0 ] \
  && printf '%s' "$OUT8" | grep -qF 'ROUND LANDING UNAVAILABLE — no round-start snapshot (other-generation)' \
  && printf '%s' "$OUT8" | grep -qF 'ROUND LANDING — R1-F1: unresolved (' \
  && printf '%s' "$OUT8" | grep -qxF 'unresolved_claims: R1-F1' \
  && [ "$(grep -c 'FINDING LEDGER — R1-F1 fixed' "$RUN")" -eq 1 ] \
  && [ "$(rounds)" = "1" ] \
  && node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).generation === 1 ? 0 : 1)' "$SNAP"; }
check "RP12 after a review budget reset the earlier generation's snapshot and claims attribute nothing" "$(verdict $?)"

printf 'seven\n' > "$PROJ/src/a.js"
note "R2-F1 IMPL completed — files: src/a.js"
OUT9="$(bash "$LOG" --round-prepare --log "$RUN" --round 2 2>"$WORK/prep.err")"; RC9=$?
{ [ "$RC9" -eq 0 ] \
  && printf '%s' "$OUT9" | grep -qF 'ROUND LANDING UNAVAILABLE — no round-start snapshot (other-baseline)' \
  && printf '%s' "$OUT9" | grep -qxF 'unresolved_claims: R2-F1'; }
check "RP13 a round listed without the baseline its start snapshot was recorded with attributes nothing" "$(verdict $?)"

mkdir -p "$WORK/home/.config/git"
printf 'private.env\n' > "$WORK/home/.config/git/ignore"
printf 'token\n' > "$PROJ/private.env"
printf 'eight\n' > "$PROJ/src/a.js"
note "R3-F1 IMPL completed — files: src/a.js"
OUT10="$(HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" bash "$LOG" --round-prepare --log "$RUN" --round 3 2>"$WORK/prep.err")"; RC10=$?
{ [ "$RC10" -eq 0 ] \
  && printf '%s' "$OUT10" | grep -qxF 'user_ignored: 1 changed path(s) your own git excludes ignore are left out of the packet lists and the round diff' \
  && printf '%s' "$OUT10" | grep -q '^judge_changed_files: ' \
  && ! printf '%s' "$OUT10" | grep -q '^judge_changed_files: .*private.env' \
  && ! printf '%s' "$OUT10" | grep -q '^changed_files .*private.env' \
  && ! grep -qF 'token' "$DIFF"; }
check "RP14 a changed path the user's own git excludes ignore stays out of the packet lists and the round diff" "$(verdict $?)"

unit_check_done "RP99 every unit file the registry gives this suite was graded"
finish
