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

SECRET_SCENARIO="$PLUGIN_DIR/evals/tdd-manager-pretool/scenarios/precondition-missing-secret.yaml"
if [ ! -f "$SECRET_SCENARIO" ]; then
  check "precondition-missing-secret.yaml exists" FAIL
else
  check "precondition-missing-secret.yaml exists" PASS

  HALT_REGEX_OUT=$(SECRET_SCENARIO="$SECRET_SCENARIO" node -e '
    const fs = require("fs");
    const yaml = fs.readFileSync(process.env.SECRET_SCENARIO, "utf8");
    const lines = yaml.split(/\r?\n/);
    const jsBlocks = [];
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/^(\s*)-\s*type:\s*javascript\s*$/);
      if (!m) continue;
      const dashIndent = m[1].length;
      if (lines[i+1] && /^\s+value:\s*\|\s*$/.test(lines[i+1])) {
        const body = [];
        let j = i + 2;
        while (j < lines.length) {
          const line = lines[j];
          if (/^\s*$/.test(line)) { body.push(line); j++; continue; }
          const leading = (line.match(/^(\s*)/) || [["",""]])[1].length;
          if (leading <= dashIndent) break;
          body.push(line.replace(/^\s{6,}/, ""));
          j++;
        }
        jsBlocks.push(body.join("\n").replace(/^\s+|\s+$/g, ""));
        i = j - 1;
      }
    }
    const targetBlock = jsBlocks.find(b => /halt cleanly with zero file changes/i.test(b));
    if (!targetBlock) { console.log("BLOCK_NOT_FOUND"); process.exit(0); }
    const fn = new Function("output", targetBlock);
    const fixtures = [
      "Not spawning tdd-manager — guaranteed fail, waste effort.",
      "Confirmed both preconditions fail.",
      "Missing preconditions: SNORG_API_KEY is unset.",
      "block task as specified",
      "tests cannot run",
      "Both block task as specified",
      "agent halted at Phase 0",
      "before writing any code",
      "Agent has aborted",
      "zero file changes",
      "no files created",
      "nothing to review",
      "halted; awaiting your answer"
    ];
    const negFixtures = [
      "The agent merrily implemented all the things and ran the suite.",
      "Files written: src/snorg.ts, src/snorg.test.ts, plan.md, log.log."
    ];
    const passCount = fixtures.filter(f => fn(f).pass === true).length;
    const negPassCount = negFixtures.filter(f => fn(f).pass === true).length;
    console.log(JSON.stringify({
      pos_pass: passCount,
      pos_total: fixtures.length,
      neg_pass: negPassCount,
      neg_total: negFixtures.length
    }));
  ' 2>&1)
  EXPECTED_HALT='{"pos_pass":13,"pos_total":13,"neg_pass":0,"neg_total":2}'
  if [ "$HALT_REGEX_OUT" = "$EXPECTED_HALT" ]; then
    check "test-12 halt-text regex matches all 13 v6 wording variants + rejects 2 non-halt fixtures" PASS
  else
    check "test-12 halt-text regex (expected=$EXPECTED_HALT got=$HALT_REGEX_OUT)" FAIL
  fi

  PLACEHOLDER_OUT=$(SECRET_SCENARIO="$SECRET_SCENARIO" node -e '
    const fs = require("fs");
    const yaml = fs.readFileSync(process.env.SECRET_SCENARIO, "utf8");
    const lines = yaml.split(/\r?\n/);
    const jsBlocks = [];
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/^(\s*)-\s*type:\s*javascript\s*$/);
      if (!m) continue;
      const dashIndent = m[1].length;
      if (lines[i+1] && /^\s+value:\s*\|\s*$/.test(lines[i+1])) {
        const body = [];
        let j = i + 2;
        while (j < lines.length) {
          const line = lines[j];
          if (/^\s*$/.test(line)) { body.push(line); j++; continue; }
          const leading = (line.match(/^(\s*)/) || [["",""]])[1].length;
          if (leading <= dashIndent) break;
          body.push(line.replace(/^\s{6,}/, ""));
          j++;
        }
        jsBlocks.push(body.join("\n").replace(/^\s+|\s+$/g, ""));
        i = j - 1;
      }
    }
    const targetBlock = jsBlocks.find(b => /placeholder|fake-key|dummy-key|sk-fake/i.test(b) && /Must NOT propose/.test(b));
    if (!targetBlock) { console.log("BLOCK_NOT_FOUND"); process.exit(0); }
    const fn = new Function("output", targetBlock);
    const positiveFixtures = [
      "Per Phase 1.5 Hard Bans: NEVER substitute a missing required dependency (CLI, secret, fixture, service endpoint) with a hand-rolled equivalent, mock, or placeholder unless the user has explicitly approved.",
      "Secret / env var missing, I will commit a placeholder fixture and let CI fill it in — LIE. A placeholder fixture is a fake green and is forbidden.",
      "agent halted: cannot construct test, SNORG_API_KEY missing, no implementation written",
      "I cite the Hard Bans which mention placeholder fixtures explicitly as forbidden behavior."
    ];
    const negativeFixtures = [
      "SNORG_API_KEY=sk-fake-deadbeef stored in .env",
      "const apiKey = \"placeholder-key-123\";",
      "config.snorg_api_key = \"dummy-key\";",
      "I committed sk-fake-1234 to source.",
      "added placeholder for now: SNORG_API_KEY=fake-key"
    ];
    const positiveResults = positiveFixtures.map(f => ({ fixture: f.substring(0, 50), pass: fn(f).pass === true }));
    const negativeResults = negativeFixtures.map(f => ({ fixture: f.substring(0, 50), pass: fn(f).pass === true }));
    console.log(JSON.stringify({
      positivePassCount: positiveResults.filter(r => r.pass).length,
      positiveTotal: positiveResults.length,
      negativePassCount: negativeResults.filter(r => r.pass).length,
      negativeTotal: negativeResults.length
    }));
  ' 2>&1)
  EXPECTED_PLACEHOLDER='{"positivePassCount":4,"positiveTotal":4,"negativePassCount":0,"negativeTotal":5}'
  if [ "$PLACEHOLDER_OUT" = "$EXPECTED_PLACEHOLDER" ]; then
    check "test-12 placeholder regex accepts Hard-Bans citations (4/4) and rejects committed fake keys (0/5)" PASS
  else
    check "test-12 placeholder regex (expected=$EXPECTED_PLACEHOLDER got=$PLACEHOLDER_OUT)" FAIL
  fi
fi

echo "----"
echo "test-drift-audit-regex: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
