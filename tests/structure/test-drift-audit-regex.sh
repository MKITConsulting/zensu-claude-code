#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCENARIO="$PLUGIN_DIR/evals/tdd-manager-pretool/scenarios/precondition-drift-audit.yaml"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SCENARIO" ]; then
  check "precondition-drift-audit.yaml exists" FAIL
  echo "----"
  echo "test-drift-audit-regex: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "precondition-drift-audit.yaml exists" PASS

REGEX_LINE=$(grep -E 'zero file changes|audit-only|audit\[\- \]only' "$SCENARIO" | head -1)
if [ -z "$REGEX_LINE" ]; then
  check "regex assertion #3 line found in scenario" FAIL
  echo "----"
  echo "test-drift-audit-regex: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "regex assertion #3 line found in scenario" PASS

REGEX_BODY=$(printf '%s' "$REGEX_LINE" | sed -E 's|^[^/]*/||; s|/i?[[:space:]]*\.test.*$||')

NODE_OUT=$(node -e "
  const re = new RegExp(\`$REGEX_BODY\`, 'i');
  const fix1 = \"Skipping code review: tdd-manager ran Phase 6 audit only, no files implemented or changed.\";
  const fix2 = \"Skipping code review: tdd-manager ran Phase 6 audit only, no files modified.\";
  const fix3 = \"audit FAIL — Phase 6 NOT complete\";
  console.log(JSON.stringify({m1: re.test(fix1), m2: re.test(fix2), m3: re.test(fix3)}));
" 2>&1)

if [ "$NODE_OUT" = '{"m1":true,"m2":true,"m3":true}' ]; then
  check "drift-audit regex matches 'audit only' (space variant) + 'no files implemented' + audit FAIL" PASS
else
  check "drift-audit regex matches all 3 fixture strings (got: $NODE_OUT, regex=$REGEX_BODY)" FAIL
fi

NEG_LINE=$(grep -E 'no drift \(found' "$SCENARIO" | head -1)
if [ -z "$NEG_LINE" ]; then
  check "regex assertion #3 (negative-guard) line found in scenario" FAIL
else
  check "regex assertion #3 (negative-guard) line found in scenario" PASS
fi
NEG_BODY=$(printf '%s' "$NEG_LINE" | sed -E 's|^[^/]*/||; s|/i?[[:space:]]*\.test.*$||')

FIXTURE_OUT=$(SCENARIO="$SCENARIO" node -e "
  const fs = require('fs');
  const yaml = fs.readFileSync(process.env.SCENARIO, 'utf8');
  const m2 = yaml.match(/\/(zero file changes[^\/]*)\/i/);
  const m3 = yaml.match(/\/(no [a-zA-Z][^\/]*)\/i/);
  if (!m2 || !m3) { console.log('REGEX_NOT_FOUND'); process.exit(0); }
  const re2 = new RegExp(m2[1], 'i');
  const re3 = new RegExp(m3[1], 'i');
  const fixA = 'Skipping code review: tdd-manager performed audit only, audit found no files modified.';
  const fixB = 'audit passed: no drift found, clean run';
  const fixC = 'Phase 6 audit FAIL — drift detected on snorgleblorf';
  const evalFix = (txt) => ({
    a2: re2.test(txt),
    a3_pass: !re3.test(txt)
  });
  console.log(JSON.stringify({
    fixA: evalFix(fixA),
    fixB: evalFix(fixB),
    fixC: evalFix(fixC)
  }));
" 2>&1)

EXPECTED_FIXTURE_OUT='{"fixA":{"a2":true,"a3_pass":true},"fixB":{"a2":false,"a3_pass":false},"fixC":{"a2":true,"a3_pass":true}}'
if [ "$FIXTURE_OUT" = "$EXPECTED_FIXTURE_OUT" ]; then
  check "Fixture A (audit-anchored true positive) PASS, Fixture B (over-match guard) FAIL, Fixture C (explicit audit FAIL) PASS" PASS
else
  check "Fixture A/B/C behavior (expected=$EXPECTED_FIXTURE_OUT got=$FIXTURE_OUT)" FAIL
fi

echo "----"
echo "test-drift-audit-regex: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
