#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LIB="$PLUGIN_DIR/hooks/lib/acceptance-verify-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/acceptance-verify-v1.test.js"
CAPABILITY="$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
source "$PLUGIN_DIR/tests/structure/lib-unit-summary.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-acceptance-gate: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LOG" "$TDD_LIB" "$POSTREV" "$LIB" "$UNIT" "$CAPABILITY" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "A0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "A0 node and git are available" FAIL
  finish
  exit 1
fi
check "A0 required files, node and git are present" PASS

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-acceptance-gate.sh") ? 0 : 1);
' "$PROFILE"; then
  check "A0a the suite is classified as a CI structure test" PASS
else
  check "A0a the suite is classified as a CI structure test" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "A0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

if node --test "$UNIT" >"$WORK/unit.out" 2>&1; then
  check "A0b the unit suite passes (node --test acceptance-verify-v1.test.js)" PASS
else
  check "A0b the unit suite passes (node --test acceptance-verify-v1.test.js)" FAIL
  sed -n '1,60p' "$WORK/unit.out"
fi
if unit_cases_meet_floor "$WORK/unit.out" 25; then
  check "A0c the unit suite registered at least 25 passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" PASS
else
  check "A0c the unit suite registered at least 25 passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" FAIL
fi

if [ "$(grep -cF '_zensu_acceptance_gate "$session_val" 1 "$(_zensu_autopilot_validate_option "$done_run")" || exit 1' "$LOG")" = "1" ] \
  && [ "$(grep -cF '_zensu_acceptance_gate "$session_val" || chain_gate_rc=1' "$LOG")" = "1" ]; then
  check "A0d --chain-done gates the standalone terminus and passes the bound flag on an Autopilot pass" PASS
else
  check "A0d --chain-done gates the standalone terminus and passes the bound flag on an Autopilot pass" FAIL
fi

if grep -q '^ZENSU_BYPASS_GATE_ALLOWLIST=".* ZENSU_ACCEPTANCE_GATE"$' "$TDD_LIB" \
  && [ "$(grep -c "path.join(trusted.pluginData, 'acceptance-verify')" "$CAPABILITY")" = "2" ]; then
  check "A0e the escape is ledgered and the record store is in both protected-root lists" PASS
else
  check "A0e the escape is ledgered and the record store is in both protected-root lists" FAIL
fi

TDD_SKILL="$PLUGIN_DIR/skills/tdd/SKILL.md"
SELF_REVIEW_SKILL="$PLUGIN_DIR/skills/self-review/SKILL.md"
VERIFY_SKILL="$PLUGIN_DIR/skills/verify-feature/SKILL.md"
PLAN_TEMPLATE="$PLUGIN_DIR/templates/tdd-plan.md"
if grep -qF '6d. **Live Acceptance Verification**' "$TDD_SKILL" \
  && grep -qF -- '--acceptance-status --log {log_file}' "$TDD_SKILL" \
  && grep -qF 'the step 6d `ACCEPTANCE STATUS` lines' "$TDD_SKILL" \
  && grep -qF '**Acceptance re-verification**' "$SELF_REVIEW_SKILL" \
  && grep -qF 'Full suite, Acceptance, Build' "$SELF_REVIEW_SKILL" \
  && grep -qF 'leave `ZENSU_ACCEPTANCE_GATE` to the user' "$SELF_REVIEW_SKILL" \
  && grep -qF '## Chain mode (`--chain`)' "$VERIFY_SKILL" \
  && grep -qF -- '--acceptance-record --ac AC-001 --verdict pass --driver browser' "$VERIFY_SKILL" \
  && grep -qF -- '--evidence-run --scope acceptance' "$VERIFY_SKILL" \
  && grep -qF '/zensu:verify-feature --chain' "$PLAN_TEMPLATE"; then
  check "A0f the tdd, self-review and verify-feature skills and the plan template carry the chain stage" PASS
else
  check "A0f the tdd, self-review and verify-feature skills and the plan template carry the chain stage" FAIL
fi
if grep -qF 'Full suite, Acceptance, Build' "$POSTREV" \
  && grep -qF 'The Acceptance verdict carries the ACCEPTANCE' "$POSTREV" \
  && grep -qF 'Add one row per advisory ACCEPTANCE — line that did not pass' "$POSTREV" \
  && grep -qF -- '--acceptance-status --log <run log>' "$POSTREV" \
  && [ "$(grep -c 'ACCEPTANCE_REVERIFY' "$POSTREV")" -ge 3 ]; then
  check "A0g the combined summary carries the Acceptance row and the self-review-off close re-verifies standalone chains" PASS
else
  check "A0g the combined summary carries the Acceptance row and the self-review-off close re-verifies standalone chains" FAIL
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
ADVISORY_SUITE='{"evidence":{"fullSuiteGate":"advisory"}}'
printf '%s\n' "$ADVISORY_SUITE" > "$ZENSU_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_FULL_SUITE_GATE ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE ZENSU_ACCEPTANCE_GATE 2>/dev/null || true
source "$TDD_LIB"
source "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
APPROVED_SHA="$(printf 'a%.0s' $(seq 1 64))"

PROJ="$WORK/project"
PLAIN="$WORK/plain"
mkdir -p "$PROJ" "$PLAIN"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'v1\n' > "$PROJ/tracked.txt"
git -C "$PROJ" add .gitignore tracked.txt
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline

STEM="2026-01-01-0101_tdd-acceptance-fixture"
PLAN_REL=".zensu/plans/$STEM.md"
RUN_LOG="./.zensu/logs/$STEM.log"
FAKE_TOKEN="ghp_$(printf 'Q7mZ%.0s' 1 2 3 4 5 6 7 8 9)"

write_plan() {
  mkdir -p "$1/.zensu/plans" "$1/.zensu/logs"
  cat > "$1/$PLAN_REL" <<PLAN
# Fixture plan

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the fixture command prints ok | spec |
| AC-002 | ${2:-the page shows the saved value} | spec |
| FR-001 | a functional fixture row that is never verified live | spec |
PLAN
}

review_to_done() {
  local sid="$1" ctx
  TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
  [ -n "$TICKET" ] || return 1
  ctx="$(SID_VALUE="$sid" TICKET="$TICKET" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID_VALUE
    }));
  ')"
  printf '%s' "$ctx" | bash "$POSTREV" >/dev/null 2>&1
  bash "$LOG" --code-review-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1 || return 1
  SF="$(tdd_state_file "$sid")"
}

arm() {
  local sid="$1" rp
  export CLAUDE_PROJECT_DIR="$PROJ"
  cd "$PROJ" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
  write_plan "$PROJ"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/$STEM.log"
  rp="$(tdd_edit_landing_receipt "$sid")" || return 1
  mkdir -p "$(dirname "$rp")"
  printf '{"schema":"edit-landing-v2","session":"%s","log":".zensu/logs/%s.log","claims":1,"landed":1,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true}\n' \
    "$sid" "$STEM" > "$rp"
  bash "$LOG" --tdd-complete --plan "./$PLAN_REL" >/dev/null 2>&1 || return 1
  review_to_done "$sid"
}

arm_plain() {
  local sid="$1" project="$2"
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
  if [ "${3:-}" = "escape-edit-landing" ]; then
    bash "$LOG" --bypass-note ZENSU_EDIT_LANDING_GATE >/dev/null 2>&1 || return 1
  fi
  bash "$LOG" --tdd-complete >/dev/null 2>&1 || return 1
  review_to_done "$sid"
}

arm_begin() {
  local sid="$1" project="$2"
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
  SF="$(tdd_state_file "$sid")"
}

bound_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name tester
  printf '.zensu/\n.session-control-test/\n' > "$dir/.gitignore"
  printf 'v1\n' > "$dir/tracked.txt"
  git -C "$dir" add .gitignore tracked.txt
  git -C "$dir" -c commit.gpgsign=false commit -qm baseline
  printf 'v2\n' > "$dir/tracked.txt"
}

bound_arm() {
  local sid="$1" project="$2" run="$3" chain="$4" validate="$5" rp
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  autopilot_begin_run "$run" "$sid" "$project" false "$validate" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-$run" PLAN_APPROVED "{\"approvedPlanSha256\":\"$APPROVED_SHA\"}" "$project" "$sid" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-begin --session "$sid" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1 || return 1
  write_plan "$project"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$project/.zensu/logs/$STEM.log"
  rp="$(tdd_edit_landing_receipt "$sid")" || return 1
  mkdir -p "$(dirname "$rp")"
  printf '{"schema":"edit-landing-v2","session":"%s","log":".zensu/logs/%s.log","claims":1,"landed":1,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true}\n' \
    "$sid" "$STEM" > "$rp"
  bash "$LOG" --tdd-complete --session "$sid" --plan "./$PLAN_REL" --autopilot-run "$run" \
    --autopilot-attempt 1 --chain-id "$chain" >/dev/null 2>&1 || return 1
  SF="$(tdd_state_file "$sid")"
}

bound_done() {
  bash "$LOG" --chain-done --session "$1" --autopilot-run "$2" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$3" --outcome pass >"$WORK/out" 2>"$WORK/err"
}

chain_done() {
  bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"
}

observe() {
  RUN_ID=""
  bash "$LOG" --evidence-run --scope "${2:-acceptance}" --cmd "$1" --log "$RUN_LOG" >"$WORK/eout" 2>"$WORK/eerr"
  RUN_ID="$(sed -n 's/.* record=\(er1_[0-9]*_[0-9a-f]*\) cmd=.*/\1/p' "$WORK/eout" | tail -n 1)"
}

acc_record() {
  if [ -n "${4:-}" ]; then
    bash "$LOG" --acceptance-record --ac "$1" --verdict "$2" --driver "$3" --evidence-run "$4" --log "${5:-$RUN_LOG}" >"$WORK/rout" 2>"$WORK/rerr"
  else
    bash "$LOG" --acceptance-record --ac "$1" --verdict "$2" --driver "$3" --log "${5:-$RUN_LOG}" >"$WORK/rout" 2>"$WORK/rerr"
  fi
}

acc_status() {
  bash "$LOG" --acceptance-status --log "$RUN_LOG" >"$WORK/sout" 2>"$WORK/serr"
}

done_flag() {
  tdd_chain_done "$SF" 2>/dev/null
}

ERR() { cat "$WORK/err" "$WORK/rerr" 2>/dev/null; }

printf 'v2\n' > "$PROJ/tracked.txt"

if arm "acc-main"; then
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q "^ACCEPTANCE — incomplete | 0/2 acceptance criteria pass on the current tree [0-9a-f]\{12\}; AC-001 missing; AC-002 missing | plan: $PLAN_REL | gate: required | run: /zensu:verify-feature --chain --log .zensu/logs/$STEM.log$" "$WORK/err" \
    && grep -qF 'resolve the ACCEPTANCE refusal above' "$WORK/err" \
    && ! grep -q 'FR-001' "$WORK/err"; then
    check "A1 no acceptance record refuses the terminus and names every active AC but no FR row" PASS
  else
    check "A1 no acceptance record refuses the terminus (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi

  acc_record AC-001 pass cli "" <<'EVIDENCE'
ran the fixture command and saw ok
EVIDENCE
  RC=$?
  if [ "$RC" -eq 1 ] && grep -qF 'driver cli decides by an exit code, so the plugin must observe it' "$WORK/rerr"; then
    check "A2 an exit-code driver without a cited evidence run is refused" PASS
  else
    check "A2 an exit-code driver without a cited evidence run is refused (rc=$RC)" FAIL
    ERR
  fi

  observe 'printf ok'
  OK_RUN="$RUN_ID"
  acc_record AC-001 fail cli "$OK_RUN" <<'EVIDENCE'
the fixture command printed ok
EVIDENCE
  RC_FAIL=$?
  FAIL_ERR="$(cat "$WORK/rerr")"
  acc_record AC-001 pass cli "$OK_RUN" <<'EVIDENCE'
the fixture command printed ok
EVIDENCE
  RC=$?
  if [ -n "$OK_RUN" ] && [ "$RC_FAIL" -eq 1 ] \
    && printf '%s' "$FAIL_ERR" | grep -qF "evidence run $OK_RUN exited 0, which contradicts --verdict fail" \
    && [ "$RC" -eq 0 ] \
    && grep -q "^zensu acceptance: AC-001 pass | driver=cli observed $OK_RUN | tree=[0-9a-f]\{12\} | record=av1_[0-9]\{13\}_[0-9a-f]\{12\} | plan: $PLAN_REL | evidence: the fixture command printed ok$" "$WORK/rout" \
    && grep -qF "ACCEPTANCE — AC-001 pass | driver=cli observed $OK_RUN | tree=" "$PROJ/.zensu/logs/$STEM.log"; then
    check "A3 an observed pass must agree with the cited run's exit code and lands in the run log" PASS
  else
    check "A3 an observed pass must agree with the cited run (run=$OK_RUN rc_fail=$RC_FAIL rc=$RC)" FAIL
    ERR
  fi

  acc_status; RC=$?
  if [ "$RC" -eq 1 ] \
    && grep -q "^ACCEPTANCE STATUS — plan: $PLAN_REL | tree: [0-9a-f]\{12\} | 1/2 active criteria pass | run: /zensu:verify-feature --chain --log .zensu/logs/$STEM.log$" "$WORK/sout" \
    && grep -q "^AC-001 pass | cli observed $OK_RUN | record av1_[0-9_a-f]* | the fixture command prints ok$" "$WORK/sout" \
    && grep -q '^AC-002 missing | the page shows the saved value$' "$WORK/sout"; then
    check "A4 --acceptance-status lists every criterion and exits 1 while one is missing" PASS
  else
    check "A4 --acceptance-status lists every criterion (rc=$RC)" FAIL
    cat "$WORK/sout" "$WORK/serr"
  fi

  A5_OK=1
  acc_record AC-009 pass browser "" <<'EVIDENCE'
opened the page
EVIDENCE
  [ $? -eq 1 ] && grep -qF "AC-009 is not an acceptance criterion of $PLAN_REL (active: AC-001, AC-002)" "$WORK/rerr" || A5_OK=0
  acc_record FR-001 pass browser "" <<'EVIDENCE'
opened the page
EVIDENCE
  [ $? -eq 2 ] && grep -qF -- '--ac must name an acceptance criterion id such as AC-001' "$WORK/rerr" || A5_OK=0
  printf '   \n' | acc_record AC-002 pass browser ""
  [ $? -eq 1 ] && grep -qF 'the evidence text on stdin is empty' "$WORK/rerr" || A5_OK=0
  printf 'logged in with %s and saw the value\n' "$FAKE_TOKEN" | acc_record AC-002 pass browser ""
  [ $? -eq 1 ] && grep -qF 'the evidence text matches a secret pattern' "$WORK/rerr" || A5_OK=0
  acc_record AC-002 pass browser "" "./.zensu/logs/2026-01-01-0101_tdd-other.log" <<'EVIDENCE'
opened the page
EVIDENCE
  [ $? -eq 1 ] && grep -qF "but this chain's edit-landing receipt records .zensu/logs/$STEM.log" "$WORK/rerr" || A5_OK=0
  printf 'x\n' | bash "$LOG" --acceptance-record --ac AC-002 --verdict pass --driver browser >"$WORK/rout" 2>"$WORK/rerr"
  [ $? -eq 2 ] && grep -qF -- "--log <this chain's run log> is required" "$WORK/rerr" || A5_OK=0
  if [ "$A5_OK" -eq 1 ]; then
    check "A5 unknown and FR ids, empty or secret evidence, another run log and a missing --log are refused" PASS
  else
    check "A5 unknown and FR ids, empty or secret evidence, another run log and a missing --log are refused" FAIL
    ERR
  fi

  acc_record AC-002 pass browser "" <<'EVIDENCE'
opened the loopback page, saved the value, reloaded and saw it again
EVIDENCE
  RC_REC=$?
  acc_status; RC_ST=$?
  if [ "$RC_REC" -eq 0 ] && grep -q '^zensu acceptance: AC-002 pass | driver=browser attested | ' "$WORK/rout" \
    && [ "$RC_ST" -eq 0 ] && grep -q "| 2/2 active criteria pass$" "$WORK/sout"; then
    check "A6 an attested UI verdict is recorded and the status exits 0 once every criterion passes" PASS
  else
    check "A6 an attested UI verdict is recorded (rc_rec=$RC_REC rc_st=$RC_ST)" FAIL
    ERR
  fi

  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q "^ACCEPTANCE — pass | 2/2 acceptance criteria pass on the current tree [0-9a-f]\{12\} (observed 1, attested 1) | plan: $PLAN_REL | gate: required$" "$WORK/err"; then
    check "A7 every active criterion passing on the current tree closes the chain with the observed/attested split" PASS
  else
    check "A7 every active criterion passing closes the chain (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "A1 arm a ticket-bound chain with a receipt" FAIL
fi

if arm "acc-stale"; then
  observe 'printf ok'
  acc_record AC-001 pass cli "$RUN_ID" <<'EVIDENCE'
the fixture command printed ok
EVIDENCE
  acc_record AC-002 pass browser "" <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  printf 'v3\n' > "$PROJ/tracked.txt"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF 'AC-001 stale (files changed since it was verified: tracked.txt)' "$WORK/err" \
    && grep -qF 'AC-002 stale (files changed since it was verified: tracked.txt)' "$WORK/err"; then
    check "A8 an edit after verification makes every criterion stale and names the changed path" PASS
  else
    check "A8 an edit after verification makes every criterion stale (rc=$RC)" FAIL
    ERR
  fi
  printf 'v2\n' > "$PROJ/tracked.txt"

  write_plan "$PROJ" "the page shows the saved value after a reload"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && grep -q '| 1/2 acceptance criteria pass on the current tree [0-9a-f]\{12\}; AC-002 stale (the criterion text changed since it was verified) |' "$WORK/err"; then
    check "A9 a changed criterion text makes that criterion stale while the reverted tree keeps the other valid" PASS
  else
    check "A9 a changed criterion text makes that criterion stale (rc=$RC)" FAIL
    ERR
  fi

  write_plan "$PROJ"
  acc_record AC-002 fail browser "" <<'EVIDENCE'
the page lost the value after a reload
EVIDENCE
  write_plan "$PROJ" "(deprecated) the page shows the saved value"
  acc_record AC-002 pass browser "" <<'EVIDENCE'
the page showed the value
EVIDENCE
  RC_DEP=$?
  DEP_ERR="$(cat "$WORK/rerr")"
  chain_done; RC=$?
  if [ "$RC_DEP" -eq 1 ] && printf '%s' "$DEP_ERR" | grep -qF "AC-002 is marked deprecated in $PLAN_REL, so it is not verified" \
    && [ "$RC" -eq 1 ] && grep -qF 'AC-002 dropped' "$WORK/err"; then
    check "A10 deprecating a failing criterion never passes: it is dropped, and a deprecated id cannot be recorded" PASS
  else
    check "A10 deprecating a failing criterion is dropped (rc_dep=$RC_DEP rc=$RC)" FAIL
    ERR
  fi

  write_plan "$PROJ"
  acc_record AC-002 pass browser "" <<'EVIDENCE'
the page showed the saved value after a reload
EVIDENCE
  write_plan "$PROJ" "(deprecated) the page shows the saved value"
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q "^ACCEPTANCE — pass | 1/1 acceptance criteria pass on the current tree [0-9a-f]\{12\} (observed 1, attested 0); deprecated: AC-002 | plan: $PLAN_REL | gate: required$" "$WORK/err"; then
    check "A11 a deprecated criterion whose newest record passed is disclosed and does not block" PASS
  else
    check "A11 a deprecated criterion whose newest record passed does not block (rc=$RC)" FAIL
    ERR
  fi
  write_plan "$PROJ"
else
  check "A8 arm a ticket-bound chain with a receipt" FAIL
fi

if arm "acc-observed"; then
  observe 'printf x >> tracked.txt'
  acc_record AC-001 pass cli "$RUN_ID" <<'EVIDENCE'
the check appended to a tracked file
EVIDENCE
  RC_MUT=$?
  MUT_ERR="$(cat "$WORK/rerr")"
  printf 'v2\n' > "$PROJ/tracked.txt"
  observe 'true' full
  acc_record AC-001 pass cli "$RUN_ID" <<'EVIDENCE'
the full suite passed
EVIDENCE
  RC_FULL=$?
  FULL_ERR="$(cat "$WORK/rerr")"
  observe 'exit 3'
  RED_RUN="$RUN_ID"
  acc_record AC-001 pass cli "$RED_RUN" <<'EVIDENCE'
the fixture command failed
EVIDENCE
  RC_RED=$?
  RED_ERR="$(cat "$WORK/rerr")"
  if [ "$RC_MUT" -eq 1 ] && printf '%s' "$MUT_ERR" | grep -qF 'changed the tree while it ran' \
    && [ "$RC_FULL" -eq 1 ] && printf '%s' "$FULL_ERR" | grep -qF 'has scope full; run the check with --evidence-run --scope acceptance' \
    && [ "$RC_RED" -eq 1 ] && printf '%s' "$RED_ERR" | grep -qF "evidence run $RED_RUN exited 3, which contradicts --verdict pass"; then
    check "A12 a cited run that mutated the tree, a full-scope run and a red run cannot back a pass" PASS
  else
    check "A12 cited-run consistency (mut=$RC_MUT full=$RC_FULL red=$RC_RED)" FAIL
    printf '%s\n%s\n%s\n' "$MUT_ERR" "$FULL_ERR" "$RED_ERR"
  fi

  acc_record AC-001 fail cli "$RED_RUN" <<'EVIDENCE'
the fixture command exited 3
EVIDENCE
  acc_record AC-002 partial browser "" <<'EVIDENCE'
the page loaded but the save button was not reachable without a login
EVIDENCE
  observe 'printf ok'
  acc_record AC-001 pass cli "$RUN_ID" <<'EVIDENCE'
the fixture command printed ok after the fix
EVIDENCE
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && grep -q '| 1/2 acceptance criteria pass on the current tree [0-9a-f]\{12\}; AC-002 partial |' "$WORK/err"; then
    check "A13 a partial verdict blocks like a failure" PASS
  else
    check "A13 a partial verdict blocks (rc=$RC)" FAIL
    ERR
  fi

  acc_record AC-002 pass browser "" <<'EVIDENCE'
after a manual login the page saved the value and showed it after a reload
EVIDENCE
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^ACCEPTANCE — flaky: AC-001 had 1 earlier non-pass verdict(s) on this same tree$' "$WORK/err" \
    && grep -q '^ACCEPTANCE — flaky: AC-002 had 1 earlier non-pass verdict(s) on this same tree$' "$WORK/err"; then
    check "A14 a pass after earlier non-pass verdicts on the same tree closes the chain and discloses them" PASS
  else
    check "A14 a pass after earlier non-pass verdicts discloses them (rc=$RC)" FAIL
    ERR
  fi
else
  check "A12 arm a ticket-bound chain with a receipt" FAIL
fi

if arm "acc-escape"; then
  ZENSU_ACCEPTANCE_GATE=off bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  FIRST="$(grep -n '^ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record was read | gate: required$' "$WORK/err" | cut -d: -f1)"
  SECOND="$(grep -n '^Gates bypassed during this session: ZENSU_ACCEPTANCE_GATE$' "$WORK/err" | cut -d: -f1)"
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ "$LEDGER" = "ZENSU_ACCEPTANCE_GATE" ] \
    && [ -n "$FIRST" ] && [ -n "$SECOND" ] && [ "$FIRST" -lt "$SECOND" ]; then
    check "A15 the escape closes the chain, lands in the bypass ledger and renders before the ledger line" PASS
  else
    check "A15 the escape closes the chain and lands in the ledger (rc=$RC ledger='$LEDGER' first=$FIRST second=$SECOND)" FAIL
    ERR
  fi
else
  check "A15 arm a ticket-bound chain with a receipt" FAIL
fi

if arm "acc-wrong-ticket"; then
  ZENSU_ACCEPTANCE_GATE=off bash "$LOG" --chain-done --claimed-review-ticket "rt_wrong" >"$WORK/out" 2>"$WORK/err"; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  if [ "$RC" -ne 0 ] && [ "$(done_flag)" = "false" ] && ! grep -q 'ACCEPTANCE' "$WORK/err" && [ -z "$LEDGER" ]; then
    check "A16 a wrong ticket is refused before the verdict and records no escape" PASS
  else
    check "A16 a wrong ticket is refused before the verdict (rc=$RC ledger='$LEDGER')" FAIL
    ERR
  fi
else
  check "A16 arm a ticket-bound chain with a receipt" FAIL
fi

printf '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
if arm "acc-advisory"; then
  chain_done; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ -z "$LEDGER" ] \
    && grep -q "^ACCEPTANCE — incomplete (advisory, not blocking) | 0/2 acceptance criteria pass on .* | gate: advisory | run: /zensu:verify-feature --chain --log .zensu/logs/$STEM.log$" "$WORK/err"; then
    check "A17 advisory mode discloses the missing criteria and closes the chain" PASS
  else
    check "A17 advisory mode discloses the missing criteria and closes the chain (rc=$RC)" FAIL
    ERR
  fi
else
  check "A17 arm a ticket-bound chain with a receipt" FAIL
fi

printf '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"sometimes"}}\n' > "$ZENSU_CONFIG"
if arm "acc-unknown-mode"; then
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "ACCEPTANCE — evidence.acceptanceGate value 'sometimes' is not recognized (expected required or advisory); treated as required" "$WORK/err" \
    && grep -q "^ACCEPTANCE — incomplete | .* | gate: required | run: /zensu:verify-feature --chain --log .zensu/logs/$STEM.log$" "$WORK/err"; then
    check "A18 an unknown gate mode is disclosed and acts as required" PASS
  else
    check "A18 an unknown gate mode is disclosed and acts as required (rc=$RC)" FAIL
    ERR
  fi
else
  check "A18 arm a ticket-bound chain with a receipt" FAIL
fi

printf '{}\n' > "$ZENSU_CONFIG"
if arm "acc-both-gates"; then
  observe 'printf ok'
  acc_record AC-001 pass cli "$RUN_ID" <<'EVIDENCE'
the fixture command printed ok
EVIDENCE
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — missing | ' "$WORK/err" \
    && grep -q '^ACCEPTANCE — incomplete | 1/2 acceptance criteria pass' "$WORK/err" \
    && grep -qF 'resolve the FULL SUITE refusal above' "$WORK/err" \
    && grep -qF 'resolve the ACCEPTANCE refusal above' "$WORK/err"; then
    check "A19 both terminus gates are evaluated together and an acceptance run never counts as a full-suite run" PASS
  else
    check "A19 both terminus gates are evaluated together (rc=$RC)" FAIL
    ERR
  fi
else
  check "A19 arm a ticket-bound chain with a receipt" FAIL
fi
printf '%s\n' "$ADVISORY_SUITE" > "$ZENSU_CONFIG"

if arm "acc-sentinel"; then
  mkdir -p "$WORK/sentinel-a" "$WORK/sentinel-b"
  : > "$WORK/sentinel-a/keep"
  : > "$WORK/sentinel-b/keep"
  _avr_dir="$WORK/sentinel-a" bash "$LOG" --evidence-run --scope acceptance --cmd 'printf ok' --log "$RUN_LOG" >/dev/null 2>&1
  _evr_dir="$WORK/sentinel-b" bash "$LOG" --acceptance-status --log "$RUN_LOG" >/dev/null 2>&1
  _avr_dir="$WORK/sentinel-a" _evr_dir="$WORK/sentinel-b" bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1
  if [ -f "$WORK/sentinel-a/keep" ] && [ -f "$WORK/sentinel-b/keep" ]; then
    check "A25 an inherited temporary-directory variable is never removed by a verb's exit trap" PASS
  else
    check "A25 an inherited temporary-directory variable is never removed by a verb's exit trap" FAIL
  fi
else
  check "A25 arm a ticket-bound chain with a receipt" FAIL
fi

BOUND_ON="$WORK/bound-on"
bound_project "$BOUND_ON"
if bound_arm "acc-bound-on" "$BOUND_ON" acc_run_on acc-chain-on true; then
  bound_done "acc-bound-on" acc_run_on acc-chain-on; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^ACCEPTANCE — not-checked | Autopilot-bound chain: the /zensu:autopilot VALIDATE stage validates every acceptance criterion of the run$' "$WORK/err"; then
    check "A26 a bound pass with live validation on closes as not-checked through the shell transport" PASS
  else
    check "A26 a bound pass with live validation on closes as not-checked (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "A26 arm an Autopilot-bound chain with a receipt and a dirty tree" FAIL
fi

BOUND_OFF="$WORK/bound-off"
bound_project "$BOUND_OFF"
if bound_arm "acc-bound-off" "$BOUND_OFF" acc_run_off acc-chain-off false; then
  bound_done "acc-bound-off" acc_run_off acc-chain-off; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^ACCEPTANCE — not-checked | Autopilot-bound chain started with --no-validate: live validation is switched off for this run, so no acceptance criterion was validated$' "$WORK/err"; then
    check "A27 a bound pass of a --no-validate run says that no acceptance criterion was validated" PASS
  else
    check "A27 a bound pass of a --no-validate run says so (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "A27 arm an Autopilot-bound chain started with --no-validate" FAIL
fi

BOUND_ESC="$WORK/bound-escape"
bound_project "$BOUND_ESC"
if bound_arm "acc-bound-escape" "$BOUND_ESC" acc_run_esc acc-chain-esc true; then
  ZENSU_ACCEPTANCE_GATE=off bound_done "acc-bound-escape" acc_run_esc acc-chain-esc; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ -z "$LEDGER" ] \
    && grep -q '^ACCEPTANCE — not-checked | Autopilot-bound chain' "$WORK/err" \
    && ! grep -q '^ACCEPTANCE — escaped' "$WORK/err"; then
    check "A28 the acceptance escape on a bound chain is not ledgered, because the gate does not apply there" PASS
  else
    check "A28 the acceptance escape on a bound chain is not ledgered (rc=$RC ledger='$LEDGER')" FAIL
    ERR
  fi
else
  check "A28 arm an Autopilot-bound chain for the escape case" FAIL
fi
cd "$PROJ" || exit 1

git -C "$PROJ" checkout -q -- tracked.txt
rm -rf "$PROJ/.zensu/plans" "$PROJ/.zensu/logs"

if arm_plain "acc-no-receipt-clean" "$PROJ"; then
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^ACCEPTANCE — not-applicable | no edit-landing receipt and no changed file, so this chain implemented nothing to verify | gate: required$' "$WORK/err"; then
    check "A20 a chain with no receipt and no changed file is not gated and says why" PASS
  else
    check "A20 a chain with no receipt and no changed file is not gated (rc=$RC)" FAIL
    ERR
  fi
else
  check "A20 arm a ticket-bound chain without a receipt" FAIL
fi

if arm_plain "acc-no-receipt-dirty" "$PROJ"; then
  printf 'late edit\n' > "$PROJ/tracked.txt"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q "^ACCEPTANCE — unresolved | the working tree has changes but no edit-landing receipt names this chain's plan; run the Phase 6 step 5b Edit Landing Audit | gate: required$" "$WORK/err"; then
    check "A21 changed files without a receipt refuse as unresolved instead of passing" PASS
  else
    check "A21 changed files without a receipt refuse as unresolved (rc=$RC)" FAIL
    ERR
  fi
  git -C "$PROJ" checkout -q -- tracked.txt
else
  check "A21 arm a ticket-bound chain without a receipt" FAIL
fi

if arm_plain "acc-landing-escaped" "$PROJ" escape-edit-landing; then
  write_plan "$PROJ"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/$STEM.log"
  acc_record AC-001 pass browser "" <<'EVIDENCE'
the fixture command printed ok in the terminal
EVIDENCE
  RC_REC=$?
  REC_ERR="$(cat "$WORK/rerr")"
  chain_done; RC=$?
  if [ "$RC_REC" -eq 0 ] \
    && printf '%s' "$REC_ERR" | grep -qF 'ACCEPTANCE STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt, so the --log stem was not cross-checked against one' \
    && [ "$RC" -eq 1 ] \
    && grep -qF 'ACCEPTANCE STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt, so the plan was taken from the newest acceptance record' "$WORK/err" \
    && grep -q "^ACCEPTANCE — incomplete | 1/2 acceptance criteria pass on .*; AC-002 missing | plan: $PLAN_REL | " "$WORK/err"; then
    check "A22 an escaped edit-landing gate takes the plan from --log and then from the newest record, and says so" PASS
  else
    check "A22 an escaped edit-landing gate takes the plan from the records (rc_rec=$RC_REC rc=$RC)" FAIL
    printf '%s\n' "$REC_ERR"
    ERR
  fi
  rm -rf "$PROJ/.zensu/plans" "$PROJ/.zensu/logs"
else
  check "A22 arm a ticket-bound chain with the edit-landing gate escaped" FAIL
fi

if arm_begin "acc-env-escape" "$PROJ"; then
  write_plan "$PROJ"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/$STEM.log"
  ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --acceptance-status --log "$RUN_LOG" >"$WORK/sout" 2>"$WORK/serr"; RC_ENV=$?
  bash "$LOG" --acceptance-status --log "$RUN_LOG" >"$WORK/sout2" 2>"$WORK/serr2"; RC_PLAIN=$?
  ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --acceptance-record --ac AC-002 --verdict pass --driver browser --log "$RUN_LOG" >"$WORK/rout" 2>"$WORK/rerr" <<'EVIDENCE'
the page showed the saved value after a reload
EVIDENCE
  RC_REC=$?
  if [ "$RC_ENV" -eq 1 ] && grep -qF 'ACCEPTANCE STEM UNCHECKED' "$WORK/sout" && grep -q '^AC-001 missing' "$WORK/sout" \
    && [ "$RC_PLAIN" -eq 2 ] && grep -qF 'no edit-landing receipt exists for this chain' "$WORK/sout2" \
    && [ "$RC_REC" -eq 0 ]; then
    check "A22b the edit-landing escape set in the environment serves step 6d before --tdd-complete records it" PASS
  else
    check "A22b the environment escape serves step 6d (rc_env=$RC_ENV rc_plain=$RC_PLAIN rc_rec=$RC_REC)" FAIL
    cat "$WORK/sout" "$WORK/serr" "$WORK/sout2" "$WORK/rerr" 2>/dev/null
  fi
  rm -rf "$PROJ/.zensu/plans" "$PROJ/.zensu/logs"
else
  check "A22b arm a chain without completing it" FAIL
fi

if arm_plain "acc-plain" "$PLAIN"; then
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^ACCEPTANCE — not-applicable | no edit-landing receipt, and the project is not a git repository, so no change can be established | gate: required$' "$WORK/err"; then
    check "A23 a project outside git without a receipt is not gated and says why" PASS
  else
    check "A23 a project outside git without a receipt is not gated (rc=$RC)" FAIL
    ERR
  fi
else
  check "A23 arm a ticket-bound chain outside git" FAIL
fi

export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || exit 1
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "acc-zero-change"
bash "$LOG" --tdd-begin >/dev/null 2>&1
bash "$LOG" --tdd-complete >/dev/null 2>&1
bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(tdd_chain_done "$(tdd_state_file "acc-zero-change")")" = "true" ] && [ ! -s "$WORK/err" ]; then
  check "A24 the unqualified zero-change terminus stays exempt and silent" PASS
else
  check "A24 the unqualified zero-change terminus stays exempt and silent (rc=$RC)" FAIL
  ERR
fi

finish
