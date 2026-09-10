#!/bin/bash
set -u

# Structure test for the witness cross-check library
# (hooks/lib/zensu-evidence-crosscheck.js) and its two skill consumers.
#
# The library exists because the check it replaces was prose that a model had
# to re-execute by hand every run — and in a real session that execution
# returned `verified` for claims nobody had established. The recipe itself is
# not known to be wrong (the witness JSON-encodes recorded commands, so the
# escaping defeats the obvious self-corroboration attack); the point is that a
# hand-run procedure has no testable failure mode and no exit code a gate can
# consume. These checks are that missing failure mode.
#
# P2b still pins the log-write exclusion directly, because the escaping that
# happens to protect the grep is not a property this library should depend on.
#
# Runs the node --test unit suite (the test-chain-recover.sh pattern), drives
# the CLI end-to-end over fixture logs, and pins the skill wiring in
# skills/tdd/SKILL.md + skills/self-review/SKILL.md, including the NEGATIVE
# guard that the hand-grep recipe stays deleted.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-evidence-crosscheck.js"
UNIT="$PLUGIN_DIR/tests/structure/evidence-crosscheck-v1.test.js"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
SELF_MD="$PLUGIN_DIR/skills/self-review/SKILL.md"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
WORKFLOW_DOC="$PLUGIN_DIR/docs/tdd-manager-workflow.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-evidence-crosscheck: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LIB" "$UNIT" "$TDD_MD" "$SELF_MD" "$PROFILE" "$WORKFLOW_DOC"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
check "P0 all required files exist" PASS

if ! command -v node >/dev/null 2>&1; then
  check "P0 node is available (required to exercise the library)" FAIL
  finish
  exit 1
fi
check "P0 node is available" PASS

WORK="$(mktemp -d 2>/dev/null)" || { check "P0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ── P1: the unit suite ──────────────────────────────────────────────────────
if node --test "$UNIT" >"$WORK/unit.out" 2>&1; then
  check "P1 the unit suite passes (node --test evidence-crosscheck-v1.test.js)" PASS
else
  check "P1 the unit suite passes (node --test evidence-crosscheck-v1.test.js)" FAIL
  sed -n '1,40p' "$WORK/unit.out"
fi

# A case-count FLOOR, for the reason this repo records for the sibling driver:
# `node --test` also exits 0 for a file that registers ZERO cases, so P1's exit
# code alone cannot tell "all green" from "the cases were deleted".
# node --test prints the summary as `ℹ pass <n>` on this runtime and `# pass <n>`
# on the TAP-style one; accept either so the floor does not silently stop biting.
UNIT_PASS="$(grep -Eo '^[#ℹ] pass [0-9]+' "$WORK/unit.out" 2>/dev/null | grep -Eo '[0-9]+$' | head -1)"
if [ -n "$UNIT_PASS" ] && [ "$UNIT_PASS" -ge 32 ]; then
  check "P1a the unit suite registered at least 32 cases (actual: $UNIT_PASS)" PASS
else
  check "P1a the unit suite registered at least 32 cases (actual: ${UNIT_PASS:-none})" FAIL
fi

# ── P2: end-to-end CLI ──────────────────────────────────────────────────────
# witness_line <cmd> <tail> <interrupted> -> the exact format post-bash-witness.sh writes
witness_line() {
  node -e '
    const [cmd, tail, interrupted] = process.argv.slice(1);
    process.stdout.write("BASH cmd=" + JSON.stringify(cmd) + " exit=? tail=" + JSON.stringify(tail) + " interrupted=" + interrupted + "\n");
  ' "$1" "$2" "$3"
}

RUNLOG="$WORK/2026-01-01-0000_tdd-x.log"
WITNESS="$WORK/witness-abc.log"

printf '%s\n' 'AUDIT — cmd="npm test" exit=0 result="PASS"' > "$RUNLOG"
witness_line 'npm test' 'pass 3' false > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'verified cmd="npm test"'; then
  check "P2a a corroborated claim reports verified and exits 0" PASS
else
  check "P2a a corroborated claim reports verified and exits 0 (rc=$RC)" FAIL
fi

# P2b — the log-write exclusion. The only witness entry is the printf that
# wrote the claim; it must never stand in for the run.
CLAIM='AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS"'
printf '%s\n' "$CLAIM" > "$RUNLOG"
witness_line "printf '%s\\n' \"$CLAIM\" >> $RUNLOG" '' false > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -qF 'EVIDENCE GAP' \
  && ! printf '%s' "$OUT" | grep -q '^verified '; then
  check "P2b the claim-logging command alone never corroborates the claim" PASS
else
  check "P2b the claim-logging command alone never corroborates the claim (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P2c — a superstring witness command is not a match
printf '%s\n' 'AUDIT — cmd="npm test" exit=0 result="PASS"' > "$RUNLOG"
witness_line 'npm test --watch' 'ok' false > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'EVIDENCE GAP'; then
  check "P2c matching is equality, not containment" PASS
else
  check "P2c matching is equality, not containment (rc=$RC)" FAIL
fi

# P2d — a failure marker in the witness tail contradicts a claimed pass
printf '%s\n' 'AUDIT — cmd="npm test" exit=0 result="PASS"' > "$RUNLOG"
witness_line 'npm test' 'tests 3
fail 2' false > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'EVIDENCE CONTRADICTION'; then
  check "P2d a contradicted pass is reported and exits non-zero" PASS
else
  check "P2d a contradicted pass is reported and exits non-zero (rc=$RC)" FAIL
fi

# P2e — a clean run whose tail reports a ZERO failure count is not a contradiction
printf '%s\n' 'AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS"' > "$RUNLOG"
witness_line 'bash tests/run-all.sh --ci' 'suites: 122 PASS / 0 FAIL' false > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qF 'EVIDENCE CONTRADICTION'; then
  check "P2e a zero failure count in the tail is not a contradiction" PASS
else
  check "P2e a zero failure count in the tail is not a contradiction (rc=$RC)" FAIL
fi

# P2f — fail closed on a missing witness log
printf '%s\n' 'AUDIT — cmd="npm test" exit=0 result="PASS"' > "$RUNLOG"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WORK/absent-witness.log" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'witness log unreadable'; then
  check "P2f a missing witness log fails closed" PASS
else
  check "P2f a missing witness log fails closed (rc=$RC)" FAIL
fi

# P2g — a missing run log is an error by default, a clean state with --allow-missing-log
: > "$WITNESS"
node "$LIB" --log "$WORK/absent-run.log" --witness "$WITNESS" >/dev/null 2>&1; RC_STRICT=$?
OUT="$(node "$LIB" --log "$WORK/absent-run.log" --witness "$WITNESS" --allow-missing-log 2>&1)"; RC_LENIENT=$?
if [ "$RC_STRICT" -eq 2 ] && [ "$RC_LENIENT" -eq 0 ] \
  && printf '%s' "$OUT" | grep -qF 'no evidence claims to cross-check'; then
  check "P2g missing run log: strict exits 2, --allow-missing-log exits 0" PASS
else
  check "P2g missing run log: strict exits 2, --allow-missing-log exits 0 (strict=$RC_STRICT lenient=$RC_LENIENT)" FAIL
fi

# P2h — a via= escape is a known limitation, never a gap
printf '%s\n' 'AUDIT — via=McpTestRunner claim="suite green"' > "$RUNLOG"
: > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -qF 'known limitation' \
  && ! printf '%s' "$OUT" | grep -qF 'EVIDENCE GAP'; then
  check "P2h a via= escape reports a known limitation and is not a gap" PASS
else
  check "P2h a via= escape reports a known limitation and is not a gap (rc=$RC)" FAIL
fi

# P2i — garbage input never crashes
printf 'not a log\n\x01\x02\n' > "$RUNLOG"
printf 'garbage\nBASH cmd=broken\n' > "$WITNESS"
node "$LIB" --log "$RUNLOG" --witness "$WITNESS" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; then
  check "P2i garbage input yields a verdict, never a crash (rc=$RC)" PASS
else
  check "P2i garbage input yields a verdict, never a crash (rc=$RC)" FAIL
fi

# ── P3: skill wiring ────────────────────────────────────────────────────────
if grep -qF 'hooks/lib/zensu-evidence-crosscheck.js' "$TDD_MD"; then
  check "P3a tdd Phase 6 calls the cross-check library" PASS
else
  check "P3a tdd Phase 6 calls the cross-check library" FAIL
fi
if grep -qF 'the library IS the recipe' "$TDD_MD" && grep -qF 'test-evidence-crosscheck.sh' "$TDD_MD"; then
  check "P3b tdd names the library as the recipe and this suite as its guard" PASS
else
  check "P3b tdd names the library as the recipe and this suite as its guard" FAIL
fi
# NEGATIVE guard: the hand-grep recipe must stay deleted from both skills.
if grep -qF "grep -F -q 'cmd=" "$TDD_MD" || grep -qF "grep -F -q 'cmd=" "$SELF_MD"; then
  check "P3c the hand-grep witness recipe stays deleted" FAIL
else
  check "P3c the hand-grep witness recipe stays deleted" PASS
fi
if grep -qF 'Never hand-grep the witness log' "$TDD_MD"; then
  check "P3d tdd names hand-execution as the failure mode this replaces" PASS
else
  check "P3d tdd names hand-execution as the failure mode this replaces" FAIL
fi
if grep -qF 'hooks/lib/zensu-evidence-crosscheck.js' "$SELF_MD" && grep -qF -- '--allow-missing-log' "$SELF_MD"; then
  check "P3e self-review runs the library with --allow-missing-log" PASS
else
  check "P3e self-review runs the library with --allow-missing-log" FAIL
fi
if grep -qF 'EVIDENCE CROSS-CHECK SUMMARY' "$SELF_MD" && grep -qF 'EVIDENCE CONTRADICTION' "$SELF_MD"; then
  check "P3f self-review carries the verdict into the final report" PASS
else
  check "P3f self-review carries the verdict into the final report" FAIL
fi
if grep -qF 'no evidence claims to cross-check' "$SELF_MD"; then
  check "P3g self-review names the empty-evidence clean state" PASS
else
  check "P3g self-review names the empty-evidence clean state" FAIL
fi

# ── P4: runner registration ─────────────────────────────────────────────────
if grep -qF '"test-evidence-crosscheck.sh"' "$PROFILE"; then
  check "P4 this suite is registered in promptfoo-local-only.v1.json" PASS
else
  check "P4 this suite is registered in promptfoo-local-only.v1.json" FAIL
fi

# ── P5: the operator-facing carrier names the library, not the retired grep ──
# docs/tdd-manager-workflow.md calls itself the source of truth for the Phase 5/6
# cross-check, and it taught `grep -F -q 'cmd="X"' witness.log` long after the skill
# forbade hand-grepping in bold. The negative guard above covers $TDD_MD and $SELF_MD
# only, so that carrier could regress to the retired recipe with every suite green.
# The negative needle is the RECIPE FRAGMENT alone, byte-identical to the P3c guard
# above — anchoring it on the old prose lead-in ("then runs …") let the same recipe
# return under any other wording with this row still green. Kept scoped to
# $WORKFLOW_DOC: docs/architecture.md quotes the retired recipe deliberately, as
# history, and would false-positive if the guard were widened to docs/.
# ── P6: the attempt half — corroborating a FAILURE ──────────────────────────
#
# Claude Code fires no PostToolUse for a Bash call that did not complete
# successfully, so a failing command left no `BASH cmd=` line and every claim
# naming it could only ever reach `EVIDENCE GAP`. This check could corroborate a
# PASS and structurally could not corroborate a FAILURE. `pre-bash-witness.sh`
# records `BASH-ATTEMPT cmd=` from PreToolUse, which the host fires
# unconditionally, so an attempt with no completed line is positive evidence.
#
# Every row below is a PAIR: the attempt-only shape and the same claim over a
# COMPLETED (zero-exit) run. Without the completed control a row would pass just
# as well if the library had started ignoring completed entries entirely, which
# is the regression that would silently reinstate the gap.

# attempt_line <cmd> -> the exact format pre-bash-witness.sh writes. Built from
# the library's own exported marker so a rename of the format cannot leave this
# suite agreeing with a spelling nothing writes any more.
attempt_line() {
  node -e '
    const marker = require(process.argv[1]).WITNESS_ATTEMPT_MARKER;
    process.stdout.write(marker + JSON.stringify(process.argv[2]) + "\n");
  ' "$LIB" "$1"
}

P6_MARKER="$(node -e 'process.stdout.write(require(process.argv[1]).WITNESS_ATTEMPT_MARKER)' "$LIB" 2>/dev/null)"
P6_RESULT_MARKER="$(node -e 'process.stdout.write(require(process.argv[1]).WITNESS_MARKER)' "$LIB" 2>/dev/null)"
if [ "$P6_MARKER" = "BASH-ATTEMPT cmd=" ] && [ "$P6_RESULT_MARKER" = "BASH cmd=" ] \
  && ! printf '%s' "$P6_MARKER" | grep -qF "$P6_RESULT_MARKER"; then
  check "P6a the two witness markers are exported and neither contains the other" PASS
else
  check "P6a witness markers (attempt='$P6_MARKER' result='$P6_RESULT_MARKER')" FAIL
fi

# P6b — a green claim over an attempt with no completed run is CONTRADICTED.
# Before the attempt half existed this was an EVIDENCE GAP, indistinguishable
# from a command that never ran at all.
printf '%s\n' 'AUDIT — cmd="bash tests/run-all.sh" exit=0 result="PASS"' > "$RUNLOG"
attempt_line 'bash tests/run-all.sh' > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -qF 'EVIDENCE CONTRADICTION' \
  && printf '%s' "$OUT" | grep -qF 'records only an attempt' \
  && printf '%s' "$OUT" | grep -qF 'contradictions=1' \
  && ! printf '%s' "$OUT" | grep -qF 'EVIDENCE GAP'; then
  check "P6b a claimed PASS over an attempt with no completed run is a contradiction" PASS
else
  check "P6b claimed PASS over an attempt-only record (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P6b-control — the zero-exit twin. The SAME claim, with a completed entry added
# beside the attempt, is verified and exits 0.
attempt_line 'bash tests/run-all.sh' > "$WITNESS"
witness_line 'bash tests/run-all.sh' 'all suites passed' false >> "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -qF 'verified cmd="bash tests/run-all.sh"' \
  && printf '%s' "$OUT" | grep -qF 'contradictions=0'; then
  check "P6b-control zero-exit twin: the same claim with a completed run is verified" PASS
else
  check "P6b-control the same claim with a completed run is verified (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P6c — the direction this check could not reach at all: a claimed FAILURE over
# an attempt-only record is CORROBORATED rather than reported as a gap.
printf '%s\n' 'AUDIT — cmd="bash tests/run-all.sh" exit=1 result="FAIL"' > "$RUNLOG"
attempt_line 'bash tests/run-all.sh' > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -qF 'verified cmd="bash tests/run-all.sh"' \
  && printf '%s' "$OUT" | grep -qF 'the claim asserts no pass, so the record corroborates it' \
  && printf '%s' "$OUT" | grep -qF 'gaps=0'; then
  check "P6c a claimed FAILURE over an attempt-only record is corroborated, not a gap" PASS
else
  check "P6c claimed FAILURE over an attempt-only record (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P6d — the gap is NOT swallowed. A claim matching neither kind still reports a
# gap, so the new verdicts narrowed the blind spot without widening corroboration.
printf '%s\n' 'AUDIT — cmd="never-ran --at-all" exit=0 result="PASS"' > "$RUNLOG"
attempt_line 'something-else' > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -qF 'EVIDENCE GAP' \
  && printf '%s' "$OUT" | grep -qF 'gaps=1'; then
  check "P6d a claim matching neither an attempt nor a completed run is still a gap" PASS
else
  check "P6d unmatched claim is still a gap (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P6e — the fail-fix-rerun cycle. An attempt-only record from the failing run
# must not contradict a claim the later green run corroborates, or every normal
# red-then-green cycle would report a false contradiction.
printf '%s\n' 'AUDIT — cmd="npm test" exit=0 result="PASS"' > "$RUNLOG"
attempt_line 'npm test' > "$WITNESS"
attempt_line 'npm test' >> "$WITNESS"
witness_line 'npm test' '3 passed' false >> "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'contradictions=0'; then
  check "P6e a failed-then-fixed cycle still verifies on its completed run" PASS
else
  check "P6e failed-then-fixed cycle (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P6f — the log-write exclusion covers attempts too. The printf that WROTE the
# claim is attempted like any other command, and must not stand in for the run.
CLAIM6='AUDIT — cmd="bash tests/run-all.sh --ci" exit=0 result="PASS"'
printf '%s\n' "$CLAIM6" > "$RUNLOG"
attempt_line "printf '%s\\n' \"$CLAIM6\" >> $RUNLOG" > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -qF 'EVIDENCE GAP' \
  && ! printf '%s' "$OUT" | grep -qF 'EVIDENCE CONTRADICTION'; then
  check "P6f a log-writing command's ATTEMPT never corroborates or contradicts the claim" PASS
else
  check "P6f log-writing attempt is excluded (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

# P6g — backwards compatibility. A witness log written before the attempt half
# existed carries no attempt lines, and every verdict over it is unchanged.
printf '%s\n' 'AUDIT — cmd="npm test" exit=0 result="PASS"' > "$RUNLOG"
witness_line 'npm test' 'pass 3' false > "$WITNESS"
OUT="$(node "$LIB" --log "$RUNLOG" --witness "$WITNESS" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -qF 'verified cmd="npm test"' \
  && ! printf '%s' "$OUT" | grep -qF 'attempt'; then
  check "P6g a pre-attempt-half witness log verifies exactly as before" PASS
else
  check "P6g legacy witness log is unchanged (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

if grep -qF 'hooks/lib/zensu-evidence-crosscheck.js' "$WORKFLOW_DOC" \
  && grep -qF -- 'not a hand-written `grep` — is the recipe' "$WORKFLOW_DOC" \
  && ! grep -qF -- "grep -F -q 'cmd=" "$WORKFLOW_DOC"; then
  check "P5 workflow doc names the cross-check library and no longer teaches the hand-grep" PASS
else
  check "P5 workflow doc names the cross-check library and no longer teaches the hand-grep" FAIL
fi

finish
