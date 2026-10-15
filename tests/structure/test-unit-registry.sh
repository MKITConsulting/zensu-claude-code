#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB_JS="$ROOT/tests/structure/lib-unit-registry.js"
REGISTRY="$ROOT/tests/profiles/unit-files.v1.json"
PROBE_UNIT="tests/structure/chain-recovery-v1.test.js"
PROBE_DRIVER="$ROOT/tests/structure/test-chain-recover.sh"
PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
report() {
  echo "----"
  echo "test-unit-registry: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

. "$ROOT/tests/structure/lib-unit-registry.sh"

unit_check "U0 the registry module's own unit file passes" "$ROOT/tests/structure/unit-registry.test.js"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zensu-unit-registry-XXXXXX")" || {
  check "U0b cannot create a work directory" FAIL
  report
  exit 1
}
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

mutate_registry() {
  node - "$REGISTRY" "$1" "$2" "$3" <<'NODE'
const fs = require('node:fs');
const [source, target, unitPath, change] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(source, 'utf8'));
const index = doc.files.findIndex((entry) => entry.path === unitPath);
if (index < 0) process.exit(3);
if (change === 'drop') doc.files.splice(index, 1);
else doc.files[index].registered += Number(change);
fs.writeFileSync(target, JSON.stringify(doc));
NODE
}

if U1_OUT="$(node "$LIB_JS" census 2>&1)"; then
  check "U1 every node --test file under tests/ has exactly one valid registry entry, and each entry's registered count equals its column-0 test( registrations" PASS
else
  check "U1 census: $(unit_one_line "$U1_OUT")" FAIL
fi

if U2_OUT="$(node "$LIB_JS" drivers 2>&1)"; then
  check "U2 every registered driver is run with bash by CI, sources the library, names its files, calls the done check and drives its unit files before any exit 0 that starts a line, and no suite spawns node --test more often than it calls unit_grade" PASS
else
  check "U2 drivers: $(unit_one_line "$U2_OUT")" FAIL
fi

if U3_OUT="$(node "$LIB_JS" render --check 2>&1)"; then
  check "U3 the rendered regions of tests/SUITE-OVERVIEW.md equal the renderer's output" PASS
else
  check "U3 render: $(unit_one_line "$U3_OUT")" FAIL
fi

U3B_RC=0
if node -e '
const fs = require("fs");
const [source, target] = process.argv.slice(1);
const text = fs.readFileSync(source, "utf8");
const row = /^(\| `structure\/chain-recovery-v1\.test\.js` \| )(\d+)( \|)/m;
if (!row.test(text)) process.exit(3);
fs.writeFileSync(target, text.replace(row, (whole, head, count, tail) => `${head}${Number(count) + 1}${tail}`));
' "$ROOT/tests/SUITE-OVERVIEW.md" "$WORK/overview.md"; then
  U3B_OUT="$(node "$LIB_JS" render --check --overview "$WORK/overview.md" 2>&1)" || U3B_RC=$?
else
  U3B_OUT="the hand-edit helper found no chain-recovery row"; U3B_RC=99
fi
U3B_WANT="tests/SUITE-OVERVIEW.md: the section-4 region differs from its sources; run node tests/structure/lib-unit-registry.js render --write"
if [ "$U3B_RC" -eq 1 ] && [ "$U3B_OUT" = "$U3B_WANT" ]; then
  check "U3b a hand edit inside a generated region fails with a message naming the render command" PASS
else
  check "U3b hand-edited overview: rc=$U3B_RC, printed '$(unit_one_line "$U3B_OUT")', want rc=1 and '$U3B_WANT'" FAIL
fi

PROBE_REGISTERED="$(node -p 'require(process.argv[1]).files.find((entry) => entry.path === process.argv[2]).registered' "$REGISTRY" "$PROBE_UNIT" 2>/dev/null)"
case "$PROBE_REGISTERED" in
  (''|*[!0-9]*) PROBE_REGISTERED="" ;;
esac
if [ -z "$PROBE_REGISTERED" ]; then
  check "U4 the probe entry $PROBE_UNIT is readable from the registry" FAIL
  report
  exit 1
fi

U4_RC=0
if mutate_registry "$WORK/dropped.json" "$PROBE_UNIT" drop; then
  U4_OUT="$(node "$LIB_JS" census --registry "$WORK/dropped.json" 2>&1)" || U4_RC=$?
else
  U4_OUT="the mutation helper failed"; U4_RC=99
fi
U4_WANT="$PROBE_UNIT: no entry in tests/profiles/unit-files.v1.json; add one"
if [ "$U4_RC" -eq 1 ] && [ "$U4_OUT" = "$U4_WANT" ]; then
  check "U4 a registry missing one real entry is refused by the census, and the refusal prints exactly the path to add" PASS
else
  check "U4 census without the $PROBE_UNIT entry: rc=$U4_RC, printed '$(unit_one_line "$U4_OUT")', want rc=1 and '$U4_WANT'" FAIL
fi

U5_LOWER=$((PROBE_REGISTERED - 1))
U5_RESULT="$(
  mutate_registry "$WORK/lowered.json" "$PROBE_UNIT" -1 || { printf 'mutation-failed'; exit 0; }
  UNIT_REGISTRY_FILE="$WORK/lowered.json"
  UNIT_DRIVER="$PROBE_DRIVER"
  UNIT_GRADED=""
  status=0
  unit_run "$ROOT/$PROBE_UNIT" 2>"$WORK/lowered.err" || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
U5_WANT="1|$PROBE_UNIT: node registered $PROBE_REGISTERED, the registry declares $U5_LOWER; raise registered to $PROBE_REGISTERED in tests/profiles/unit-files.v1.json"
if [ "$U5_RESULT" = "$U5_WANT" ]; then
  check "U5 a real entry lowered by one fails its driver with the raise message" PASS
else
  check "U5 lowered entry: got '$U5_RESULT', want '$U5_WANT'" FAIL
fi

if tr -d '\r' < "$WORK/lowered.err" 2>/dev/null | grep -qx "# tests $PROBE_REGISTERED"; then
  check "U5d a failing grade replays the end of node's output on stderr" PASS
else
  check "U5d a failing grade replayed no excerpt of node's output on stderr" FAIL
fi

U5B_RESULT="$(
  mutate_registry "$WORK/raised.json" "$PROBE_UNIT" 1 || { printf 'mutation-failed'; exit 0; }
  UNIT_REGISTRY_FILE="$WORK/raised.json"
  UNIT_DRIVER="$PROBE_DRIVER"
  UNIT_GRADED=""
  status=0
  unit_run "$ROOT/$PROBE_UNIT" 2>/dev/null || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
U5B_WANT="1|$PROBE_UNIT: node registered $PROBE_REGISTERED, the registry declares $((PROBE_REGISTERED + 1)); 1 case(s) were removed; lower registered only if the removal was intended"
if [ "$U5B_RESULT" = "$U5B_WANT" ]; then
  check "U5b a real entry raised by one fails its driver with the removal message" PASS
else
  check "U5b raised entry: got '$U5B_RESULT', want '$U5B_WANT'" FAIL
fi

U5C_RC=0
if mutate_registry "$WORK/lowered-static.json" "$PROBE_UNIT" -1; then
  U5C_OUT="$(node "$LIB_JS" census --registry "$WORK/lowered-static.json" 2>&1)" || U5C_RC=$?
else
  U5C_OUT="the mutation helper failed"; U5C_RC=99
fi
U5C_WANT="$PROBE_UNIT: registers $PROBE_REGISTERED, the registry declares $U5_LOWER; raise registered to $PROBE_REGISTERED in tests/profiles/unit-files.v1.json"
if [ "$U5C_RC" -eq 1 ] && [ "$U5C_OUT" = "$U5C_WANT" ]; then
  check "U5c the census refuses the same lowered entry from the source alone, before any driver runs" PASS
else
  check "U5c census over a lowered entry: rc=$U5C_RC, printed '$(unit_one_line "$U5C_OUT")', want rc=1 and '$U5C_WANT'" FAIL
fi

U6_RESULT="$(
  UNIT_DRIVER="$PROBE_DRIVER"
  UNIT_GRADED=""
  status=0
  unit_registry_done || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
U6_WANT="1|tests/structure/test-chain-recover.sh: never ran or graded $PROBE_UNIT, which the registry says it runs"
if [ "$U6_RESULT" = "$U6_WANT" ]; then
  check "U6 a driver that never runs a file the registry gives it fails its done check, naming the file" PASS
else
  check "U6 done check without a run: got '$U6_RESULT', want '$U6_WANT'" FAIL
fi

U7_RESULT="$(
  UNIT_GRADED=""
  status=0
  unit_run "$ROOT/$PROBE_UNIT" 2>/dev/null || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
U7_WANT="2|$PROBE_UNIT: tests/structure/test-unit-registry.sh is not a registered driver of this file; add it to the entry's runs in tests/profiles/unit-files.v1.json"
if [ "$U7_RESULT" = "$U7_WANT" ]; then
  check "U7 a driver the registry does not list for a file is refused as a plumbing fault" PASS
else
  check "U7 unregistered caller: got '$U7_RESULT', want '$U7_WANT'" FAIL
fi

U8_CI="$(
  CI=1
  status=0
  unit_not_run "$ROOT/$PROBE_UNIT" "probe" >/dev/null || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
U8_LOCAL="$(
  unset CI
  status=0
  unit_not_run "$ROOT/$PROBE_UNIT" "probe" >/dev/null || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
if [ "$U8_CI" = "1|NOT RUN $PROBE_UNIT: probe" ] && [ "$U8_LOCAL" = "0|NOT RUN $PROBE_UNIT: probe" ]; then
  check "U8 unit_not_run prints NOT RUN with its reason, and fails only when CI is set" PASS
else
  check "U8 unit_not_run: with CI '$U8_CI', without '$U8_LOCAL'" FAIL
fi

cat > "$WORK/failing.tap" <<'TAP'
TAP version 13
# Subtest: passes
ok 1 - passes
  ---
  duration_ms: 0.3
  type: 'test'
  ...
# Subtest: fails
not ok 2 - fails
  ---
  duration_ms: 0.6
  type: 'test'
  failureType: 'testCodeFailure'
  error: |-
    Expected values to be strictly equal:

    1 !== 2

  code: 'ERR_ASSERTION'
  expected: 2
  actual: 1
  operator: 'strictEqual'
  ...
# Subtest: after
ok 3 - after
  ---
  duration_ms: 0.1
  type: 'test'
  ...
1..3
# tests 3
# pass 2
# fail 1
TAP
cat > "$WORK/failing.want" <<'TAP'
not ok 2 - fails
  ---
  duration_ms: 0.6
  type: 'test'
  failureType: 'testCodeFailure'
  error: |-
    Expected values to be strictly equal:

    1 !== 2

  code: 'ERR_ASSERTION'
  expected: 2
  actual: 1
  operator: 'strictEqual'
  ...
TAP
unit_failure_excerpt "$WORK/failing.tap" > "$WORK/failing.got"
if cmp -s "$WORK/failing.want" "$WORK/failing.got"; then
  check "U10 the failure excerpt keeps each not ok line with its YAML diagnostics and stops at the next case" PASS
else
  check "U10 failure excerpt: got '$(unit_one_line "$(cat "$WORK/failing.got")")'" FAIL
fi

: > "$WORK/no-fail.tap"
: > "$WORK/no-fail.want"
LINE=1
while [ "$LINE" -le 50 ]; do
  printf 'line %s\n' "$LINE" >> "$WORK/no-fail.tap"
  [ "$LINE" -le 10 ] || printf 'line %s\n' "$LINE" >> "$WORK/no-fail.want"
  LINE=$((LINE + 1))
done
unit_failure_excerpt "$WORK/no-fail.tap" > "$WORK/no-fail.got"
if cmp -s "$WORK/no-fail.want" "$WORK/no-fail.got"; then
  check "U10b without a not ok line the failure excerpt is the last 40 lines of node's output" PASS
else
  check "U10b failure excerpt without a not ok line: got '$(unit_one_line "$(cat "$WORK/no-fail.got")")'" FAIL
fi

U10C_STATUS="$(
  UNIT_DRIVER="$PROBE_DRIVER"
  UNIT_GRADED=""
  status=0
  unit_grade "$ROOT/$PROBE_UNIT" "$WORK/failing.tap" 1 2>"$WORK/graded.err" || status=$?
  printf '%s' "$status"
)"
if [ "$U10C_STATUS" = 1 ] && cmp -s "$WORK/failing.want" "$WORK/graded.err"; then
  check "U10c a grade that fails on a not ok case replays that case with its YAML diagnostics on stderr" PASS
else
  check "U10c failing grade: status '$U10C_STATUS', stderr '$(unit_one_line "$(cat "$WORK/graded.err" 2>/dev/null)")'" FAIL
fi

cat > "$WORK/load-failure.tap" <<'TAP'
TAP version 13
# stdout before the throw
# Error: boom at load
#     at Object.<anonymous> (/probe/load.test.js:4:7)
# Node.js v20.20.2
# Subtest: /probe/load.test.js
not ok 1 - /probe/load.test.js
  ---
  duration_ms: 141.407
  failureType: 'testCodeFailure'
  exitCode: 1
  error: 'test failed'
  code: 'ERR_TEST_FAILURE'
  ...
1..1
# tests 1
# pass 0
# fail 1
TAP
cat > "$WORK/load-failure.want" <<'TAP'
# stdout before the throw
# Error: boom at load
#     at Object.<anonymous> (/probe/load.test.js:4:7)
# Node.js v20.20.2
not ok 1 - /probe/load.test.js
  ---
  duration_ms: 141.407
  failureType: 'testCodeFailure'
  exitCode: 1
  error: 'test failed'
  code: 'ERR_TEST_FAILURE'
  ...
TAP
unit_failure_excerpt "$WORK/load-failure.tap" > "$WORK/load-failure.got"
if cmp -s "$WORK/load-failure.want" "$WORK/load-failure.got"; then
  check "U10d a file that fails to load keeps the diagnostics node printed before its file-level not ok" PASS
else
  check "U10d load-failure excerpt: got '$(unit_one_line "$(cat "$WORK/load-failure.got")")'" FAIL
fi

U10E_RESULT="$(
  UNIT_RUN_TEE=1
  UNIT_RUN_OUTPUT=""
  UNIT_DRIVER="$PROBE_DRIVER"
  UNIT_GRADED=""
  status=0
  unit_run "$ROOT/$PROBE_UNIT" >/dev/null 2>&1 || status=$?
  printf '%s|%s' "$status" "$UNIT_RUN_VERDICT"
)"
U10E_WANT="2|$PROBE_UNIT: UNIT_RUN_TEE needs UNIT_RUN_OUTPUT, a file the driver creates and removes"
if [ "$U10E_RESULT" = "$U10E_WANT" ]; then
  check "U10e unit_run refuses UNIT_RUN_TEE without a driver-owned UNIT_RUN_OUTPUT before node runs" PASS
else
  check "U10e tee without an output file: got '$U10E_RESULT', want '$U10E_WANT'" FAIL
fi

unit_check_done "U9 every unit file the registry gives this driver was graded"

report
