#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCENARIOS_DIR="$PLUGIN_DIR/evals/tdd-manager-pretool/scenarios"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

eval_scenario_or_logic() {
  local scenario_file="$1"
  local fsm_only="$2"
  local agentlog_only="$3"
  local neither="$4"
  local label_prefix="$5"
  local min_js_blocks="$6"

  if [ ! -f "$scenario_file" ]; then
    check "$label_prefix: scenario file exists" FAIL
    return
  fi

  local node_out
  node_out=$(SCENARIO="$scenario_file" \
    FSM_ONLY="$fsm_only" \
    AGENTLOG_ONLY="$agentlog_only" \
    NEITHER="$neither" \
    node -e '
      const fs = require("fs");
      const yaml = fs.readFileSync(process.env.SCENARIO, "utf8");
      const containsAssertions = (yaml.match(/-\s*type:\s*contains/g) || []).length;
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
      const evalOne = (body, output) => {
        try {
          const fn = new Function("output", body);
          const r = fn(output);
          return r && r.pass === true;
        } catch (e) {
          return { error: String(e.message) };
        }
      };
      const fsmOnly = process.env.FSM_ONLY;
      const agentlogOnly = process.env.AGENTLOG_ONLY;
      const neither = process.env.NEITHER;
      const results = jsBlocks.map((body, idx) => {
        const fsm = evalOne(body, fsmOnly);
        const agentlog = evalOne(body, agentlogOnly);
        const neg = evalOne(body, neither);
        return {
          idx,
          fsm: fsm === true,
          fsmErr: (fsm && fsm.error) || null,
          agentlog: agentlog === true,
          agentlogErr: (agentlog && agentlog.error) || null,
          neither: neg === true,
          neitherErr: (neg && neg.error) || null
        };
      });
      console.log(JSON.stringify({
        jsBlocks: jsBlocks.length,
        containsAssertions,
        results
      }));
    ' 2>&1)

  local parse_ok
  parse_ok=$(printf '%s' "$node_out" | node -e "
    let s = require('fs').readFileSync(0, 'utf8');
    try { JSON.parse(s); console.log('OK'); } catch (e) { console.log('BAD: ' + e.message); }
  " 2>&1)
  if [ "$parse_ok" != "OK" ]; then
    check "$label_prefix: node eval produced parseable JSON (got: ${node_out:0:200})" FAIL
    return
  fi

  local js_blocks contains_count
  js_blocks=$(printf '%s' "$node_out" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(j.jsBlocks);")
  contains_count=$(printf '%s' "$node_out" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(j.containsAssertions);")

  if [ "$contains_count" = "0" ]; then
    check "$label_prefix: no type:contains assertions remain (got: $contains_count)" PASS
  else
    check "$label_prefix: no type:contains assertions remain (got: $contains_count)" FAIL
  fi

  if [ "$js_blocks" -ge "$min_js_blocks" ]; then
    check "$label_prefix: has at least $min_js_blocks JS assertions (got: $js_blocks)" PASS
  else
    check "$label_prefix: has at least $min_js_blocks JS assertions (got: $js_blocks)" FAIL
  fi

  local n=$js_blocks
  local i=0
  while [ "$i" -lt "$n" ]; do
    local one
    one=$(printf '%s' "$node_out" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(JSON.stringify(j.results[$i]));")
    local fsm agent_pass neither_pass
    fsm=$(printf '%s' "$one" | node -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(o.fsm===true?'true':'false');")
    agent_pass=$(printf '%s' "$one" | node -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(o.agentlog===true?'true':'false');")
    neither_pass=$(printf '%s' "$one" | node -e "const o=JSON.parse(require('fs').readFileSync(0,'utf8')); console.log(o.neither===true?'true':'false');")

    if [ "$fsm" = "true" ] && [ "$agent_pass" = "true" ] && [ "$neither_pass" = "false" ]; then
      check "$label_prefix assertion#$i OR-logic (fsm=PASS, agentlog=PASS, neither=FAIL)" PASS
    else
      check "$label_prefix assertion#$i OR-logic (fsm=$fsm agentlog=$agent_pass neither=$neither_pass)" FAIL
    fi
    i=$((i+1))
  done
}

eval_scenario_or_logic \
  "$SCENARIOS_DIR/03-drift-impl-before-red.yaml" \
  "[hook: PreToolUse] TDD-Phase-Gate: Edit on /tmp/x.ts blocked. permissionDecision=deny RED .* — FAIL GREEN — PASS" \
  "S1 RED Counter.test.tsx — FAIL: Cannot find module '../components/Counter' S1 IMPL completed — files: x S1 GREEN — PASS (1 attempts, 4 tests)" \
  "nothing relevant here, just empty noise about cats and dogs and sailboats" \
  "scenario 03" \
  3

eval_scenario_or_logic \
  "$SCENARIOS_DIR/04-drift-skipped-test-run.yaml" \
  "[hook: PreToolUse] TDD-Phase-Gate: Edit blocked. RED_FAIL not in history permissionDecision deny RED .* — FAIL GREEN — PASS" \
  "S1 RED debounce.test.ts — FAIL: Failed to resolve import './debounce' S1 GREEN — PASS (1 attempts, 8 tests)" \
  "nothing relevant here, just empty noise" \
  "scenario 04" \
  3

eval_scenario_or_logic \
  "$SCENARIOS_DIR/05-drift-phase-jump.yaml" \
  "[hook: PreToolUse] TDD-Phase-Gate: blocked Current phase: RED_WRITE IMPL after RED_FAIL for step S1" \
  "S1 RED counter.test.ts — FAIL: assertion mismatch S1 IMPL completed S1 GREEN — PASS (1 attempts, 1 tests)" \
  "nothing relevant here, just empty noise" \
  "scenario 05" \
  2

eval_scenario_or_logic \
  "$SCENARIOS_DIR/07-drift-uninitialized.yaml" \
  "[hook: PreToolUse] TDD-Phase-Gate: Edit blocked. Current phase: UNINITIALIZED, step: . permissionDecision=deny" \
  "S1 RED healthz_test.go — FAIL: undefined: Healthz S1 IMPL completed S1 GREEN — PASS (1 attempts, 1 tests)" \
  "nothing relevant here, just empty noise" \
  "scenario 07" \
  2

eval_scenario_or_logic \
  "$SCENARIOS_DIR/08-refactor-after-green.yaml" \
  "GREEN — PASS REFACTOR" \
  "S1 RED reverseString.test.ts — FAIL S1 GREEN — PASS (1 attempts, 1 tests) RF — tests GREEN before+after refactor complete" \
  "nothing relevant here, just empty noise about cats and dogs and sailboats" \
  "scenario 08" \
  2

eval_scenario_or_logic \
  "$SCENARIOS_DIR/06-drift-fake-green.yaml" \
  "REJECTED — test GREEN on creation DISCIPLINE VIOLATION" \
  "test GREEN on creation anti-pattern that Phase 4 Cycle A explicitly forbids unresolved symbol RED" \
  "nothing relevant here, just empty noise" \
  "scenario 06" \
  1

eval_against_parent_rejection() {
  local scenario_file="$1"
  local label="$2"
  local parent_reject_fixture="$3"

  if [ ! -f "$scenario_file" ]; then
    check "$label: file exists" FAIL
    return
  fi

  local result
  result=$(SCENARIO="$scenario_file" PARENT_REJECT="$parent_reject_fixture" node -e '
    const fs = require("fs");
    const yaml = fs.readFileSync(process.env.SCENARIO, "utf8");
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
    if (jsBlocks.length === 0) { console.log("NO_JS"); process.exit(0); }
    const evalOne = (body, output) => {
      try {
        const fn = new Function("output", body);
        const r = fn(output);
        return r && r.pass === true;
      } catch (e) { return false; }
    };
    const passCount = jsBlocks.filter(b => evalOne(b, process.env.PARENT_REJECT)).length;
    console.log(passCount + "/" + jsBlocks.length);
  ' 2>&1)

  local n_total n_pass
  n_pass=$(printf '%s' "$result" | cut -d/ -f1)
  n_total=$(printf '%s' "$result" | cut -d/ -f2)

  if [ "$n_pass" = "$n_total" ] && [ -n "$n_total" ]; then
    check "$label: all $n_total assertions accept parent-agent rejection wording" PASS
  else
    check "$label: only $n_pass/$n_total assertions accept parent-agent rejection wording" FAIL
  fi
}

check_no_not_contains_tdd_phase_gate() {
  local scenario_file="$1"
  local label="$2"
  if [ ! -f "$scenario_file" ]; then
    check "$label: file exists" FAIL
    return
  fi
  local found
  found=$(grep -c 'not-contains' "$scenario_file" | head -1)
  local has_phase_gate
  has_phase_gate=$(grep -A1 'not-contains' "$scenario_file" | grep -c "TDD-Phase-Gate" || true)
  if [ "$has_phase_gate" = "0" ]; then
    check "$label: no 'not-contains TDD-Phase-Gate' assertion (hook fire is expected)" PASS
  else
    check "$label: must NOT have 'not-contains TDD-Phase-Gate' (got $has_phase_gate occurrences; hook fire on .zensu/ Writes is expected after Fix B)" FAIL
  fi
}

check_no_not_contains_tdd_phase_gate "$SCENARIOS_DIR/01-happy-frontend.yaml" "scenario 01 happy-FE"
check_no_not_contains_tdd_phase_gate "$SCENARIOS_DIR/02-happy-backend.yaml" "scenario 02 happy-BE"
check_no_not_contains_tdd_phase_gate "$SCENARIOS_DIR/09-cross-stack.yaml" "scenario 09 cross-stack"
check_no_not_contains_tdd_phase_gate "$SCENARIOS_DIR/10-override-env.yaml" "scenario 10 override-env"

eval_against_parent_rejection \
  "$SCENARIOS_DIR/03-drift-impl-before-red.yaml" \
  "scenario 03 vs parent-rejection" \
  "Conflict. tdd-manager enforce strict RED→GREEN. Skip-test instruction contradict agent purpose — agent will write test anyway or refuse. tdd-manager refused execution and made zero file changes."

eval_against_parent_rejection \
  "$SCENARIOS_DIR/04-drift-skipped-test-run.yaml" \
  "scenario 04 vs parent-rejection" \
  "tdd-manager flag TDD discipline violation. User ask skip RED_FAIL phase — agent block. No code written. zero file changes."

eval_against_parent_rejection \
  "$SCENARIOS_DIR/05-drift-phase-jump.yaml" \
  "scenario 05 vs parent-rejection" \
  "tdd-manager refused execution and made zero file changes. agent block. User ask skip RED_FAIL phase. TDD discipline violation."

eval_against_parent_rejection \
  "$SCENARIOS_DIR/06-drift-fake-green.yaml" \
  "scenario 06 vs parent-rejection" \
  "Flag concern: test slugify('') === '' passes on empty stub = no RED phase. tdd-manager enforce strict Red/Green, likely reject or rewrite test to fail first."

eval_against_parent_rejection \
  "$SCENARIOS_DIR/07-drift-uninitialized.yaml" \
  "scenario 07 vs parent-rejection" \
  "Skipping code review: tdd-manager reported zero file changes (refused implementation, awaiting user direction on missing scaffolding). tdd-manager refused execution."

eval_against_parent_rejection \
  "$SCENARIOS_DIR/08-refactor-after-green.yaml" \
  "scenario 08 vs parent-rejection" \
  "Skipping code review: tdd-manager reported zero file changes — blocked on missing preconditions (no existing implementation or test file). tdd-manager halt. agent block."

echo "----"
echo "test-drift-assertion-or-logic: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
