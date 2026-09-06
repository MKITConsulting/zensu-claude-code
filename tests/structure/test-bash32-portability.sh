#!/bin/bash
set -u

# zensu-doctor-home-exempt: this suite never RUNS the doctor. It scans shell
# sources and greps hooks/lib/zensu-doctor.sh, so no renderer process is started
# and no HOME is resolved.
#
# Guards the bash 3.2 command-substitution truncation class. macOS ships 3.2.57
# as /bin/bash, so it is the default shell for every hook here; that release
# extracts a `$( ... )` body with a naive paren scanner, and a case arm written
# in the bare `pattern)` form closes the substitution at its own `)`. The whole
# rationale, the oracle and the one trap deliberately NOT machine-checked live in
# the header of tests/structure/bash32-substitution-scan.js — read that before
# changing anything here.
#
# The coupling runs in the UNOBVIOUS direction, the shape CLAUDE.md records for
# G12: an ordinary edit to any *.sh in this tree can redden a suite named for
# bash 3.2, and the remedy is in the file that changed, not in this one.

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCAN="$ROOT/tests/structure/bash32-substitution-scan.js"
DOCTOR="$ROOT/hooks/lib/zensu-doctor.sh"

PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1"; fi; }

if [ ! -f "$SCAN" ]; then
  echo "FAIL  B0 scanner missing: $SCAN"
  echo "test-bash32-portability: 0 PASS / 1 FAIL"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- B1: the tree is clean, and the scan actually looked at something ---------
B1_ERR="$TMP/b1.err"
B1_OUT="$(node "$SCAN" "$ROOT" 2>"$B1_ERR")"
B1_RC=$?
B1_SCANNED="$(sed -n 's/^scanned \([0-9]*\) shell file(s).*/\1/p' "$B1_ERR")"

if [ "$B1_RC" -eq 0 ] && [ -z "$B1_OUT" ]; then
  check "B1 no shell source carries a bash 3.2 truncating command substitution" PASS
else
  check "B1 bash 3.2 truncating command substitution(s) found:
$B1_OUT" FAIL
fi

# A scanner that walks nothing reports a clean tree. Pin the population so a
# broken file walk cannot pass as health.
if [ -n "$B1_SCANNED" ] && [ "$B1_SCANNED" -ge 100 ]; then
  check "B1a the scan covered the tree (${B1_SCANNED} shell files)" PASS
else
  check "B1a the scan covered almost nothing (scanned='${B1_SCANNED}') — a vacuous B1" FAIL
fi

# --- B1b/B1c: the scanner can fail, and accepts the documented fix ------------
# Without these two, B1 is satisfied by a scanner that reports nothing ever.
mkdir -p "$TMP/bad" "$TMP/good"
# Only the FIXED shape is written literally here, and the broken one is derived
# from it by deleting the single character under test. Two reasons, both real.
# This file is itself a *.sh under ROOT, so a literal bare case arm in a heredoc
# is scanned by B1 and reported — the suite failed on its own fixture the first
# time it ran. And deriving the pair guarantees they differ in exactly the `(`,
# which is the property B1b and B1c exist to demonstrate.
cat > "$TMP/good/probe.sh" <<'GOOD'
V="$(
  case "${F:-}" in (*[[:cntrl:]]*) exit 0 ;; esac
  printf 'ok'
)"
echo "$V"
GOOD
sed 's/in (\*/in */' "$TMP/good/probe.sh" > "$TMP/bad/probe.sh"
if ! grep -q 'in \*\[\[:cntrl:\]\]\*)' "$TMP/bad/probe.sh" \
  || cmp -s "$TMP/good/probe.sh" "$TMP/bad/probe.sh"; then
  check "B1pre fixture: deriving the bare form from the paren form did not work" FAIL
else
  check "B1pre fixture: the two probes differ only in the leading paren" PASS
fi

B1B_OUT="$(node "$SCAN" "$TMP/bad" 2>/dev/null)"; B1B_RC=$?
case "$B1B_OUT" in
  *"probe.sh:1"*) [ "$B1B_RC" -eq 1 ] && B1B=PASS || B1B=FAIL ;;
  *) B1B=FAIL ;;
esac
check "B1b control: a bare case pattern inside \$( ) IS reported (rc=$B1B_RC out='$B1B_OUT')" "$B1B"

B1C_OUT="$(node "$SCAN" "$TMP/good" 2>/dev/null)"; B1C_RC=$?
if [ "$B1C_RC" -eq 0 ] && [ -z "$B1C_OUT" ]; then
  check "B1c control: the paren-prefixed form is accepted" PASS
else
  check "B1c control: the documented fix shape was reported (rc=$B1C_RC out='$B1C_OUT')" FAIL
fi

# --- B1d: the two forms really do differ on a live bash ----------------------
# B1b/B1c pin the SCANNER. This pins the PREMISE the scanner encodes, so a bash
# that stopped behaving this way is reported here rather than silently making
# every other row meaningless. On bash 5 both forms yield `ok`; on bash 3.2 the
# bare one yields the truncated tail. Either way the paren form must be `ok`.
B1D_GOOD="$(F='' bash "$TMP/good/probe.sh" 2>/dev/null)"
if [ "$B1D_GOOD" = ok ]; then
  check "B1d premise: the paren-prefixed form evaluates correctly on this bash ($BASH_VERSION)" PASS
else
  check "B1d premise: the paren-prefixed form did not evaluate to ok (got '$B1D_GOOD') on $BASH_VERSION" FAIL
fi

# --- B2: the doctor's own arm keeps the fixed shape --------------------------
# A source pin as well as a scan: if the scanner is ever neutered, the one arm
# whose regression cost the whole binding verdict is still held.
B2_ARM="$(grep -n 'ZENSU_PROJECT_ROOT:-}" in' "$DOCTOR" 2>/dev/null)"
if [ -z "$B2_ARM" ]; then
  check "B2pre anchor: the ZDOC_SESSION_PAIR control-byte case arm was not found in zensu-doctor.sh" FAIL
else
  check "B2pre anchor: the control-byte case arm is present" PASS
  case "$B2_ARM" in
    *'in (*[[:cntrl:]]*)'*) check "B2 the arm uses the paren-prefixed pattern" PASS ;;
    *) check "B2 the arm reverted to the bare form: $B2_ARM" FAIL ;;
  esac
fi

# --- B3: the rule is stated where the next editor of that block will read it --
B3_MISS=""
for needle in \
  'naive scanner' \
  'POSIX-optional leading paren' \
  'bare `pattern)` form' \
  'test-bash32-portability.sh'
do
  grep -qF -- "$needle" "$DOCTOR" || B3_MISS="$B3_MISS [$needle]"
done
if [ -z "$B3_MISS" ]; then
  check "B3 zensu-doctor.sh states the rule, the fix and the guard beside the substitution" PASS
else
  check "B3 zensu-doctor.sh no longer states:$B3_MISS" FAIL
fi

echo "----"
echo "test-bash32-portability: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
