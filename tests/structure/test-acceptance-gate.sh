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
source "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"

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

unit_check "A0b the acceptance-verify unit file passes" "$UNIT"

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

source "$PLUGIN_DIR/tests/structure/lib-skill-text.sh"
TDD_SKILL="$(skill_text_file "$PLUGIN_DIR/skills/build")"
SELF_REVIEW_SKILL="$PLUGIN_DIR/skills/self-review/SKILL.md"
VERIFY_SKILL="$PLUGIN_DIR/skills/verify-feature/SKILL.md"
PLAN_TEMPLATE="$PLUGIN_DIR/templates/zensu-plan.md"
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

STEM="2026-01-01-0101_build-acceptance-fixture"
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

audit_receipt() {
  bash "$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh" --log "$2/.zensu/logs/$STEM.log" --project "$2" \
    --session "$1" >/dev/null 2>&1
}

arm() {
  local sid="$1"
  export CLAUDE_PROJECT_DIR="$PROJ"
  cd "$PROJ" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
  write_plan "$PROJ"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/$STEM.log"
  audit_receipt "$sid" "$PROJ" || return 1
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
  local sid="$1" project="$2" run="$3" chain="$4" validate="$5"
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$project" false "$validate" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-$run" PLAN_APPROVED "{\"approvedPlanSha256\":\"$APPROVED_SHA\"}" "$project" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-begin --session "$sid" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1 || return 1
  write_plan "$project"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$project/.zensu/logs/$STEM.log"
  audit_receipt "$sid" "$project" || return 1
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
  acc_record AC-002 pass browser "" "./.zensu/logs/2026-01-01-0101_build-other.log" <<'EVIDENCE'
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

if arm "acc-shared"; then
  observe 'printf ok'
  SHARED_RUN="$RUN_ID"
  acc_record AC-001 pass cli "$SHARED_RUN" <<'EVIDENCE'
the shared check asserted the AC-001 case and exited 0
EVIDENCE
  RC_ONE=$?
  acc_record AC-002 pass api "$SHARED_RUN" <<'EVIDENCE'
the same check asserted the AC-002 case and exited 0
EVIDENCE
  RC_TWO=$?
  acc_status; RC_ST=$?
  if [ -n "$SHARED_RUN" ] && [ "$RC_ONE" -eq 0 ] && [ "$RC_TWO" -eq 0 ] && [ "$RC_ST" -eq 0 ] \
    && grep -q "| 2/2 active criteria pass$" "$WORK/sout"; then
    check "A12a one observed acceptance run backs two separately recorded criteria on an unchanged tree" PASS
  else
    check "A12a one run for two criteria (run=$SHARED_RUN one=$RC_ONE two=$RC_TWO status=$RC_ST)" FAIL
    cat "$WORK/sout"; ERR
  fi
  printf 'v3\n' > "$PROJ/tracked.txt"
  acc_status; RC_ST=$?
  STALE_OUT="$(cat "$WORK/sout")"
  acc_record AC-002 pass api "$SHARED_RUN" <<'EVIDENCE'
the earlier shared check, cited again after the tree changed
EVIDENCE
  RC_CITE=$?
  if [ "$RC_ST" -eq 1 ] && printf '%s\n' "$STALE_OUT" | grep -q "| 0/2 active criteria pass" \
    && [ "$RC_CITE" -eq 1 ] && grep -qF "evidence run $SHARED_RUN measured another tree than the current one" "$WORK/rerr"; then
    check "A12b after an edit the shared run backs neither criterion and cannot be cited again" PASS
  else
    check "A12b shared run after an edit (status=$RC_ST cite=$RC_CITE)" FAIL
    printf '%s\n' "$STALE_OUT"; ERR
  fi
  printf 'v2\n' > "$PROJ/tracked.txt"
else
  check "A12a arm a ticket-bound chain with a receipt" FAIL
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

echo "== A chain bound to an Autopilot run that drives a worktree below the anchor =="
BOUND_WT="$WORK/bound-worktree"
mkdir -p "$BOUND_WT"
git -C "$BOUND_WT" init -q
git -C "$BOUND_WT" config user.email t@example.invalid
git -C "$BOUND_WT" config user.name tester
printf '.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$BOUND_WT/.gitignore"
printf 'v1\n' > "$BOUND_WT/tracked.txt"
git -C "$BOUND_WT" add .gitignore tracked.txt
git -C "$BOUND_WT" -c commit.gpgsign=false commit -qm baseline
git -C "$BOUND_WT" worktree add -q "$BOUND_WT/.claude/worktrees/wt" -b wt-bound 2>/dev/null
BWT="$(cd -P "$BOUND_WT/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
bound_begin_wt() {
  local sid="$1" run="$2" chain="$3" rp
  export CLAUDE_PROJECT_DIR="$BOUND_WT"
  cd "$BOUND_WT" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$BOUND_WT" false true "$BWT" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-$run" PLAN_APPROVED "{\"approvedPlanSha256\":\"$APPROVED_SHA\"}" "$BOUND_WT" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-begin --session "$sid" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1 || return 1
  write_plan "$BOUND_WT"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$BOUND_WT/.zensu/logs/$STEM.log"
  rp="$(tdd_edit_landing_receipt "$sid")" || return 1
  mkdir -p "$(dirname "$rp")"
  printf '{"schema":"edit-landing-v2","session":"%s","log":".zensu/logs/%s.log","claims":1,"landed":1,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true,"workTree":".claude/worktrees/wt"}\n' \
    "$sid" "$STEM" > "$rp"
}
printf 'v2\n' > "$BWT/tracked.txt"
if [ -n "$BWT" ] && bound_begin_wt "acc-bound-wt" acc_run_wt acc-chain-wt; then
  observe 'pwd -P'
  WT_RUN="$RUN_ID"
  acc_record AC-001 pass cli "$WT_RUN" <<'EVIDENCE'
the fixture command printed the worktree
EVIDENCE
  RC_REC1=$?
  acc_record AC-002 pass browser "" <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_REC2=$?
  acc_status; RC=$?
  if [ -n "$WT_RUN" ] && grep -qxF "$BWT" "$WORK/eout" \
    && grep -qF "so the command runs in $BWT" "$WORK/eerr" \
    && [ "$RC_REC1" -eq 0 ] && [ "$RC_REC2" -eq 0 ] \
    && [ "$RC" -eq 0 ] && grep -q "| 2/2 active criteria pass$" "$WORK/sout"; then
    check "A29 for a chain bound to a worktree below the anchor an acceptance run from the anchor runs in the worktree, and records on its tree pass" PASS
  else
    check "A29 for a bound worktree chain an acceptance run runs in the worktree and its records pass (run=$WT_RUN rec=$RC_REC1/$RC_REC2 rc=$RC)" FAIL
    cat "$WORK/eout" "$WORK/eerr" "$WORK/sout" "$WORK/serr"
    ERR
  fi

  printf 'v3\n' > "$BWT/tracked.txt"
  acc_status; RC=$?
  if [ "$RC" -eq 1 ] \
    && grep -q "^AC-001 stale (files changed since it was verified: \.claude/worktrees/wt/tracked\.txt) | cli observed $WT_RUN | " "$WORK/sout" \
    && grep -q '^AC-002 stale (files changed since it was verified: \.claude/worktrees/wt/tracked\.txt) | browser attested | ' "$WORK/sout"; then
    check "A30 an edit in the worktree makes every acceptance record of the bound chain stale and names the worktree path" PASS
  else
    check "A30 an edit in the worktree makes every acceptance record of the bound chain stale (rc=$RC)" FAIL
    cat "$WORK/sout" "$WORK/serr"
  fi

  WT_RUN_FILE="$(autopilot_run_file acc_run_wt "$BOUND_WT")"
  cp "$WT_RUN_FILE" "$WORK/acc-run-wt.pre"
  BAD_WS="$BOUND_WT" node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.workspaceRoot = process.env.BAD_WS + "/missing-worktree"; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$WT_RUN_FILE"
  bash "$LOG" --evidence-run --scope acceptance --cmd "touch '$WORK/fault-ran'" --log "$RUN_LOG" >"$WORK/eout" 2>"$WORK/eerr"; RC_RUN=$?
  acc_status; RC_ST=$?
  acc_record AC-001 pass cli "$WT_RUN" <<'EVIDENCE'
the fixture command printed the worktree
EVIDENCE
  RC_REC=$?
  cp "$WORK/acc-run-wt.pre" "$WT_RUN_FILE"
  if [ "$RC_RUN" -eq 2 ] && [ ! -e "$WORK/fault-ran" ] \
    && grep -qF "zensu-log.sh --evidence-run: the chain's work tree could not be determined, so the command was not run: " "$WORK/eerr" \
    && [ "$RC_ST" -eq 2 ] \
    && grep -qF "ACCEPTANCE STATUS — unavailable | the chain's work tree could not be determined, so no acceptance record can be bound to it: " "$WORK/sout" \
    && grep -qF 'work tree not found' "$WORK/sout" \
    && [ "$RC_REC" -eq 2 ] \
    && grep -qF "zensu-log.sh --acceptance-record: the chain's work tree could not be determined, so no acceptance record can be bound to it: " "$WORK/rerr" \
    && grep -qF 'work tree not found' "$WORK/rerr" \
    && grep -qF "the chain's work tree could not be determined, so no acceptance record can be bound to it: " "$LIB" \
    && ! grep -qF "the chain's work tree could not be determined" "$LOG"; then
    check "A31 a bound chain whose worktree cannot be resolved refuses the acceptance run and both acceptance verbs with exit 2 and the cause, worded by the modules" PASS
  else
    check "A31 a bound chain whose worktree cannot be resolved refuses with exit 2 (run=$RC_RUN status=$RC_ST record=$RC_REC)" FAIL
    cat "$WORK/eerr" "$WORK/sout" "$WORK/serr" "$WORK/rerr"
  fi

  source "$PLUGIN_DIR/tests/structure/lib-work-tree-fault-stub.sh"
  work_tree_fault_stub "$WORK/fault-stub"
  BAD_WS="$BOUND_WT" node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.workspaceRoot = process.env.BAD_WS + "/missing-worktree"; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$WT_RUN_FILE"
  PATH="$WORK/fault-stub:$PATH" bash "$LOG" --acceptance-status --log "$RUN_LOG" >"$WORK/sout" 2>"$WORK/serr"; RC_TST=$?
  PATH="$WORK/fault-stub:$PATH" bash "$LOG" --acceptance-record --ac AC-001 --verdict pass --driver browser --log "$RUN_LOG" >"$WORK/rout" 2>"$WORK/rerr" <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_TREC=$?
  cp "$WORK/acc-run-wt.pre" "$WT_RUN_FILE"
  if [ "$RC_TST" -eq 2 ] && [ "$RC_TREC" -eq 2 ] && [ ! -s "$WORK/sout" ] && [ ! -s "$WORK/rout" ] \
    && grep -qF '/work-tree-fault: ' "$WORK/serr" \
    && grep -qF "zensu-log.sh --acceptance-status: the work-tree lookup failed and its cause could not be written to the temporary directory, so the acceptance module did not run." "$WORK/serr" \
    && grep -qF '/work-tree-fault: ' "$WORK/rerr" \
    && grep -qF "zensu-log.sh --acceptance-record: the work-tree lookup failed and its cause could not be written to the temporary directory, so the acceptance module did not run." "$WORK/rerr" \
    && ! grep -qF "the chain's work tree could not be determined" "$WORK/serr" "$WORK/rerr"; then
    check "A32 a work-tree fault whose transport write fails stops both acceptance verbs with exit 2 and the shell's own line, before the module runs" PASS
  else
    check "A32 a work-tree fault whose transport write fails stops both acceptance verbs (status=$RC_TST record=$RC_TREC)" FAIL
    cat "$WORK/sout" "$WORK/serr" "$WORK/rout" "$WORK/rerr"
  fi
else
  check "A29 arm a chain bound to an Autopilot run that drives a worktree below the anchor" FAIL
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

echo "== The Autopilot VALIDATE stage validates a run only on its acceptance records =="
source "$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"
PLAN_PAYLOAD_LIB="$PLUGIN_DIR/hooks/lib/plan-payload-v1.js"
VAL_PLAN_TEXT='# Fixture plan

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the fixture command prints ok | spec |
| AC-002 | the page shows the saved value | spec |
| FR-001 | a functional fixture row that is never verified live | spec |
'

val_project() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name tester
  printf '.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$1/.gitignore"
  printf 'v1\n' > "$1/tracked.txt"
  git -C "$1" add .gitignore tracked.txt
  git -C "$1" -c commit.gpgsign=false commit -qm baseline
}

val_store_plan() {
  VAL_SHA="$(ROOT="$1" PLAN_TEXT="$VAL_PLAN_TEXT" LIB="$PLAN_PAYLOAD_LIB" node -e '
    const crypto = require("crypto");
    const bytes = Buffer.from(process.env.PLAN_TEXT, "utf8");
    const sha = crypto.createHash("sha256").update(bytes).digest("hex");
    const stored = require(process.env.LIB).storeApprovedPlan(process.env.ROOT, sha, bytes);
    if (!stored || stored.ok !== true) process.exit(1);
    process.stdout.write(sha);
  ')" && [ -n "$VAL_SHA" ]
}

val_event() {
  autopilot_apply_event "$1" "$2" "$3" "$4" "$5" >/dev/null 2>&1
}

val_drive() {
  local run="$1" project="$2" sha="$3" head="$4" key payload digest marker
  val_event "$run" "plan-$run" PLAN_APPROVED "{\"approvedPlanSha256\":\"$sha\"}" "$project" || return 1
  val_event "$run" "tdd-start-$run" TDD_STARTED \
    "{\"attempt\":1,\"chainId\":\"chain-$run\",\"sessionId\":\"$ZENSU_SESSION_KEY\"}" "$project" || return 1
  val_event "$run" "tdd-done-$run" TDD_CHAIN_DONE \
    "{\"attempt\":1,\"chainId\":\"chain-$run\",\"sessionId\":\"$ZENSU_SESSION_KEY\",\"outcome\":\"pass\"}" "$project" || return 1
  val_event "$run" "gates-$run" GATES_PASSED "{\"headSha\":\"$head\"}" "$project" || return 1
  val_event "$run" "converge-$run" CONVERGENCE_PASSED '{}' "$project" || return 1
  val_event "$run" "pr-request-$run" PR_OPEN_REQUESTED "{\"operationKey\":\"pr:$run\"}" "$project" || return 1
  val_event "$run" "pr-open-$run" PR_OPENED \
    "{\"operationKey\":\"pr:$run\",\"pr\":{\"number\":41,\"url\":\"https://github.test/acme/widget/pull/41\",\"headSha\":\"$head\"}}" "$project" || return 1
  key="$(autopilot_team_review_operation_key "$run" "$head" 2>/dev/null)" && [ -n "$key" ] || return 1
  val_event "$run" "review-request-$run" TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$key\",\"provider\":\"github\"}" "$project" || return 1
  payload="$WORK/review-payload-$run.json"
  printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Validate fixture review\",\"commit_id\":\"$head\",\"comments\":[]}" > "$payload"
  autopilot_store_team_review_payload "$run" "$key" "$head" "$payload" github "$project" >/dev/null 2>&1 || return 1
  digest="$(_zensu_vcs_review_payload_meta github "$payload" "$head" "$key" 2>/dev/null \
    | node -e 'let d = ""; process.stdin.on("data", (c) => { d += c; }).on("end", () => { try { process.stdout.write(String(JSON.parse(d).payloadDigest || "")); } catch (_) {} });')"
  [ -n "$digest" ] || return 1
  marker="$(OPERATION_KEY="$key" HEAD_SHA="$head" PAYLOAD_DIGEST="$digest" node -e '
    const op = require("crypto").createHash("sha256").update(process.env.OPERATION_KEY).digest("hex");
    process.stdout.write(`<!-- zensu-review:v1:${op}:${process.env.PAYLOAD_DIGEST}:${process.env.HEAD_SHA.toLowerCase()}:1:part=1/1 -->`);
  ')"
  val_event "$run" "review-published-$run" TEAM_REVIEW_PUBLISHED \
    "{\"operationKey\":\"$key\",\"marker\":\"$marker\",\"headSha\":\"$head\",\"provider\":\"github\"}" "$project" || return 1
  val_event "$run" "findings-clear-$run" FINDINGS_CLEARED "{\"headSha\":\"$head\",\"unresolvedCount\":0}" "$project"
}

val_setup() {
  local sid="$1" dir="$2" run="$3" cover="${4:-false}" sha="${5:-}"
  val_project "$dir" || return 1
  export CLAUDE_PROJECT_DIR="$dir"
  cd "$dir" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$dir" "$cover" true >/dev/null 2>&1 || return 1
  if [ -z "$sha" ]; then
    val_store_plan "$dir" || return 1
    sha="$VAL_SHA"
  fi
  VAL_HEAD="$(git -C "$dir" rev-parse HEAD)"
  val_drive "$run" "$dir" "$sha" "$VAL_HEAD" || return 1
  VAL_RUN_FILE="$(autopilot_run_file "$run" "$dir")"
  run_json_ok "$VAL_RUN_FILE" 'v.stage === "VALIDATE"'
}

run_json_ok() {
  RUN_JSON_FILE="$1" RUN_JSON_EXPR="$2" node -e '
    const v = JSON.parse(require("fs").readFileSync(process.env.RUN_JSON_FILE, "utf8"));
    process.exit(Function("v", `return (${process.env.RUN_JSON_EXPR});`)(v) ? 0 : 1);
  ' 2>/dev/null
}

file_sha() {
  node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"
}

val_observe() {
  VAL_EVR=""
  bash "$LOG" --evidence-run --scope acceptance --run "$1" --cmd "$2" >"$WORK/veout" 2>"$WORK/veerr"
  VAL_EVR="$(sed -n 's/.* record=\(er1_[0-9]*_[0-9a-f]*\) cmd=.*/\1/p' "$WORK/veout" | tail -n 1)"
}

val_record() {
  if [ -n "${5:-}" ]; then
    bash "$LOG" --acceptance-record --run "$1" --ac "$2" --verdict "$3" --driver "$4" --evidence-run "$5" >"$WORK/vrout" 2>"$WORK/vrerr"
  else
    bash "$LOG" --acceptance-record --run "$1" --ac "$2" --verdict "$3" --driver "$4" >"$WORK/vrout" 2>"$WORK/vrerr"
  fi
}

val_validate() {
  local run="$1"
  shift
  bash "$LOG" --autopilot-validate --run "$run" "$@" >"$WORK/vout" 2>"$WORK/verr"
}

VERR() { cat "$WORK/vout" "$WORK/verr" "$WORK/vrout" "$WORK/vrerr" "$WORK/veout" "$WORK/veerr" 2>/dev/null; }

VM="$WORK/val-main"
if val_setup "val-main" "$VM" val_run_main false; then
  VM_HEAD="$VAL_HEAD"
  VM_SHA="$VAL_SHA"
  VM_FILE="$VAL_RUN_FILE"
  VM_COPY=".zensu/state/autopilot-approved-plan-$VM_SHA.md"
  VM_BEFORE="$(file_sha "$VM_FILE")"
  bash "$LOG" --autopilot-event --run val_run_main --event VALIDATION_PASSED --event-id forged-validation \
    --payload "{\"headSha\":\"$VM_HEAD\"}" >"$WORK/vout" 2>"$WORK/verr"; RC_EVT=$?
  bash "$LOG" --autopilot-event --run val_run_main --event VALIDATION_FAILED --event-id "validation-passed:1:$VM_HEAD" \
    --payload "{\"headSha\":\"$VM_HEAD\"}" >"$WORK/vout2" 2>"$WORK/verr2"; RC_NS=$?
  if [ "$RC_EVT" -eq 2 ] && grep -qF -- 'VALIDATION_PASSED is internal; use zensu-log.sh --autopilot-validate --run <id>' "$WORK/verr" \
    && [ "$RC_NS" -eq 2 ] && grep -qF -- "the 'validation-passed:' and 'validation-bypass:' event-id namespaces are reserved for --autopilot-validate" "$WORK/verr2" \
    && [ "$(file_sha "$VM_FILE")" = "$VM_BEFORE" ]; then
    check "V1 the event CLI refuses VALIDATION_PASSED and the validation event-id namespaces and leaves the run at VALIDATE" PASS
  else
    check "V1 the event CLI refuses VALIDATION_PASSED (rc=$RC_EVT/$RC_NS)" FAIL
    VERR; cat "$WORK/verr2"
  fi

  val_validate val_run_main; RC=$?
  if [ "$RC" -eq 1 ] \
    && grep -qF "ACCEPTANCE — incomplete | autopilot run val_run_main: 0/2 acceptance criteria pass on the pull-request head ${VM_HEAD:0:12}; AC-001 missing; AC-002 missing | plan: $VM_COPY | gate: required | run: drive each criterion that does not pass again on this tree and record it with zensu-log.sh --acceptance-record --run val_run_main" "$WORK/verr" \
    && grep -qF 'zensu-log.sh --autopilot-validate: autopilot run val_run_main stays at VALIDATE' "$WORK/verr" \
    && [ ! -s "$WORK/vout" ] && [ "$(file_sha "$VM_FILE")" = "$VM_BEFORE" ]; then
    check "V2 a run without acceptance records stays at VALIDATE and names each missing criterion with its remedy" PASS
  else
    check "V2 a run without acceptance records stays at VALIDATE (rc=$RC)" FAIL
    VERR
  fi

  printf 'dirty\n' > "$VM/tracked.txt"
  val_record val_run_main AC-002 pass browser <<'EVIDENCE'
the page showed the saved value on a tree that was later reverted
EVIDENCE
  RC_STALE=$?
  git -C "$VM" checkout -q -- tracked.txt
  val_observe val_run_main 'exit 1'
  FAIL_EVR="$VAL_EVR"
  val_record val_run_main AC-001 fail cli "$FAIL_EVR" <<'EVIDENCE'
the fixture command exited 1
EVIDENCE
  RC_FAIL=$?
  val_validate val_run_main; RC=$?
  MIXED_ERR="$(cat "$WORK/verr")"
  val_validate val_run_main --accept-partial; RC_ACCEPT=$?
  if [ "$RC_STALE" -eq 0 ] && [ -n "$FAIL_EVR" ] && [ "$RC_FAIL" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$RC_ACCEPT" -eq 1 ] \
    && printf '%s' "$MIXED_ERR" | grep -qF "; AC-001 fail; AC-002 stale (files changed since it was verified: tracked.txt) | plan: $VM_COPY | gate: required | run: " \
    && printf '%s' "$MIXED_ERR" | grep -qF "| fix: a criterion that fails on this tree needs a code change; send VALIDATION_FAILED for autopilot run val_run_main so the run returns to its fix loop" \
    && ! printf '%s' "$MIXED_ERR" | grep -qF '| accept:' \
    && grep -qF '; AC-002 stale (files changed since it was verified: tracked.txt); --accept-partial covers only partial criteria | plan: ' "$WORK/verr" \
    && [ "$(file_sha "$VM_FILE")" = "$VM_BEFORE" ]; then
    check "V3 a failing and a stale criterion refuse with their fix and run remedies, and --accept-partial does not cover them" PASS
  else
    check "V3 a failing and a stale criterion refuse (stale=$RC_STALE fail=$RC_FAIL rc=$RC accept=$RC_ACCEPT run=$FAIL_EVR)" FAIL
    VERR
  fi

  printf 'stray\n' > "$VM/stray.txt"
  val_observe val_run_main 'printf ok'
  DIRTY_EVR="$VAL_EVR"
  val_record val_run_main AC-001 pass cli "$DIRTY_EVR" <<'EVIDENCE'
the fixture command printed ok on a tree with an untracked file
EVIDENCE
  RC_D1=$?
  val_record val_run_main AC-002 pass browser <<'EVIDENCE'
the page showed the saved value on a tree with an untracked file
EVIDENCE
  RC_D2=$?
  val_validate val_run_main; RC_DIRTY=$?
  DIRTY_ERR="$(cat "$WORK/verr")"
  rm -f "$VM/stray.txt"
  printf 'v2\n' > "$VM/tracked.txt"
  git -C "$VM" -c commit.gpgsign=false commit -qam 'newer commit'
  VM_NEWER="$(git -C "$VM" rev-parse HEAD)"
  val_observe val_run_main 'printf ok'
  AHEAD_EVR="$VAL_EVR"
  val_record val_run_main AC-001 pass cli "$AHEAD_EVR" <<'EVIDENCE'
the fixture command printed ok on a commit newer than the pull-request head
EVIDENCE
  RC_A1=$?
  val_record val_run_main AC-002 pass browser <<'EVIDENCE'
the page showed the saved value on a commit newer than the pull-request head
EVIDENCE
  RC_A2=$?
  val_validate val_run_main; RC_AHEAD=$?
  git -C "$VM" reset -q --hard "$VM_HEAD"
  if [ -n "$DIRTY_EVR" ] && [ "$RC_D1" -eq 0 ] && [ "$RC_D2" -eq 0 ] && [ "$RC_DIRTY" -eq 1 ] \
    && printf '%s' "$DIRTY_ERR" | grep -qF "ACCEPTANCE — unresolved | autopilot run val_run_main: the work tree has uncommitted changes, so it is not the pull-request head ${VM_HEAD:0:12}" \
    && [ -n "$AHEAD_EVR" ] && [ "$RC_A1" -eq 0 ] && [ "$RC_A2" -eq 0 ] && [ "$RC_AHEAD" -eq 1 ] \
    && grep -qF "ACCEPTANCE — unresolved | autopilot run val_run_main: HEAD of the work tree is ${VM_NEWER:0:12}, not the pull-request head ${VM_HEAD:0:12}" "$WORK/verr" \
    && [ "$(file_sha "$VM_FILE")" = "$VM_BEFORE" ]; then
    check "V4 records that all pass on an untracked file or on a HEAD other than the pull-request head refuse and name the cause" PASS
  else
    check "V4 a dirty tree or another HEAD refuses even when every record passes (d=$RC_D1/$RC_D2/$RC_DIRTY a=$RC_A1/$RC_A2/$RC_AHEAD)" FAIL
    printf '%s\n' "$DIRTY_ERR"
    VERR
  fi

  cp "$VM/$VM_COPY" "$WORK/val-copy.pre"
  printf 'appended after approval\n' >> "$VM/$VM_COPY"
  val_validate val_run_main; RC=$?
  bash "$LOG" --acceptance-status --run val_run_main >"$WORK/vsout" 2>"$WORK/vserr"; RC_ST=$?
  cp "$WORK/val-copy.pre" "$VM/$VM_COPY"
  if [ "$RC" -eq 1 ] \
    && grep -qF "ACCEPTANCE — unresolved | the stored copy $VM_COPY no longer matches the digest the run approved" "$WORK/verr" \
    && [ "$RC_ST" -eq 2 ] && grep -qF "ACCEPTANCE STATUS — unresolved | the stored copy $VM_COPY no longer matches" "$WORK/vsout" \
    && [ "$(file_sha "$VM_FILE")" = "$VM_BEFORE" ]; then
    check "V5 a stored plan copy that no longer matches the approved digest refuses as unresolved" PASS
  else
    check "V5 a tampered plan copy refuses as unresolved (rc=$RC status=$RC_ST)" FAIL
    VERR; cat "$WORK/vsout" "$WORK/vserr"
  fi

  val_observe val_run_main 'printf ok'
  PASS_EVR="$VAL_EVR"
  val_record val_run_main AC-001 pass cli "$PASS_EVR" <<'EVIDENCE'
the fixture command printed ok
EVIDENCE
  RC_R1=$?
  val_record val_run_main AC-002 pass browser <<'EVIDENCE'
the page showed the saved value after a reload
EVIDENCE
  RC_R2=$?
  bash "$LOG" --acceptance-status --run val_run_main >"$WORK/vsout" 2>"$WORK/vserr"; RC_ST=$?
  val_validate val_run_main; RC=$?
  if [ -n "$PASS_EVR" ] && [ "$RC_R1" -eq 0 ] && [ "$RC_R2" -eq 0 ] && [ "$RC_ST" -eq 0 ] \
    && grep -qF "ACCEPTANCE STATUS — autopilot run val_run_main | plan: $VM_COPY | tree: " "$WORK/vsout" \
    && grep -q "^AC-001 pass | cli observed $PASS_EVR | record av1_[^ ]* | evidence: the fixture command printed ok | the fixture command prints ok$" "$WORK/vsout" \
    && [ "$RC" -eq 0 ] \
    && grep -qF "ACCEPTANCE — pass | autopilot run val_run_main: 2/2 acceptance criteria pass on the pull-request head ${VM_HEAD:0:12} (observed 1, attested 1) | plan: $VM_COPY | gate: required" "$WORK/verr" \
    && grep -qF 'ACCEPTANCE — flaky: AC-001 had 1 earlier non-pass verdict(s) on this same tree' "$WORK/verr" \
    && grep -qxF "zensu autopilot: run val_run_main validated at the pull-request head ${VM_HEAD:0:12}" "$WORK/vout" \
    && run_json_ok "$VM_FILE" "v.stage === \"DELIVER\" && v.evidence.validation.passed === true && v.evidence.validation.headSha === \"$VM_HEAD\" && v.bypasses.length === 0 && v.events[v.events.length - 1].eventId === \"validation-passed:1:$VM_HEAD\""; then
    check "V6 every criterion passing on a clean tree at the pull-request head applies VALIDATION_PASSED with the durable head" PASS
  else
    check "V6 every criterion passing applies VALIDATION_PASSED (r1=$RC_R1 r2=$RC_R2 status=$RC_ST rc=$RC run=$PASS_EVR)" FAIL
    VERR; cat "$WORK/vsout" "$WORK/vserr"
  fi

  val_validate val_run_main; RC=$?
  if [ "$RC" -eq 2 ] && grep -qF 'autopilot run val_run_main is at stage DELIVER, not VALIDATE, so there is nothing to validate' "$WORK/verr"; then
    check "V7 a run past VALIDATE is refused rather than validated twice" PASS
  else
    check "V7 a run past VALIDATE is refused (rc=$RC)" FAIL
    VERR
  fi

  val_event val_run_main "cancel-val_run_main" CANCEL '{}' "$VM"; RC_CANCEL=$?
  VM_ENDED="$(file_sha "$VM_FILE")"
  val_validate val_run_main; RC=$?
  ENDED_ERR="$(cat "$WORK/verr")"
  bash "$LOG" --acceptance-status --run val_run_main >"$WORK/vsout" 2>"$WORK/vserr"; RC_ST=$?
  bash "$LOG" --evidence-run --scope acceptance --run val_run_main --cmd "touch '$WORK/val-ended-ran'" >"$WORK/veout" 2>"$WORK/veerr"; RC_EVR=$?
  if [ "$RC_CANCEL" -eq 0 ] && run_json_ok "$VM_FILE" 'v.stage === "CANCELLED"' \
    && [ "$RC" -eq 2 ] && printf '%s' "$ENDED_ERR" | grep -qF 'zensu-log.sh --autopilot-validate: autopilot run val_run_main has already ended' \
    && [ "$RC_ST" -eq 2 ] && grep -qF 'zensu-log.sh --acceptance-status: autopilot run val_run_main has already ended' "$WORK/vserr" \
    && [ "$RC_EVR" -eq 2 ] && [ ! -e "$WORK/val-ended-ran" ] \
    && grep -qF 'zensu-log.sh --evidence-run: autopilot run val_run_main has already ended' "$WORK/veerr" \
    && [ "$(file_sha "$VM_FILE")" = "$VM_ENDED" ]; then
    check "V7b a run that has ended is refused with exit 2 by the verb, the status and the acceptance evidence run, and none of them changes it" PASS
  else
    check "V7b an ended run is refused with exit 2 (cancel=$RC_CANCEL rc=$RC status=$RC_ST evidence=$RC_EVR)" FAIL
    printf '%s\n' "$ENDED_ERR"
    VERR; cat "$WORK/vserr"
  fi
else
  check "V1 drive an Autopilot run to VALIDATE with a stored approved plan" FAIL
fi

VP="$WORK/val-partial"
if val_setup "val-partial" "$VP" val_run_partial false; then
  VP_HEAD="$VAL_HEAD"
  VP_FILE="$VAL_RUN_FILE"
  val_record val_run_partial AC-001 partial cli <<'EVIDENCE'
the fixture command printed ok, but only for the default locale
EVIDENCE
  RC_R1=$?
  val_record val_run_partial AC-002 pass browser <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_R2=$?
  val_validate val_run_partial; RC_PLAIN=$?
  PLAIN_ERR="$(cat "$WORK/verr")"
  val_validate val_run_partial --accept-partial; RC=$?
  if [ "$RC_R1" -eq 0 ] && [ "$RC_R2" -eq 0 ] && [ "$RC_PLAIN" -eq 1 ] \
    && printf '%s' "$PLAIN_ERR" | grep -qF '| accept: every criterion that does not pass is partial, so zensu-log.sh --autopilot-validate --run val_run_partial --accept-partial records the gap' \
    && [ "$RC" -eq 0 ] \
    && grep -qF "ACCEPTANCE — partial-accepted | autopilot run val_run_partial: 1/2 acceptance criteria pass on the pull-request head ${VP_HEAD:0:12}; accepted as partial: AC-001" "$WORK/verr" \
    && grep -qxF "zensu autopilot: run val_run_partial validated at the pull-request head ${VP_HEAD:0:12}, with the acceptance-partial bypass recorded in its ledger" "$WORK/vout" \
    && run_json_ok "$VP_FILE" "v.stage === \"DELIVER\" && v.bypasses.length === 1 && v.bypasses[0].gate === \"acceptance-partial\" && v.bypasses[0].stage === \"VALIDATE\" && v.events.some((e) => e.eventId === \"validation-bypass:acceptance-partial:1:$VP_HEAD\")"; then
    check "V8 --accept-partial with only partial criteria records acceptance-partial in the run's ledger and validates the run" PASS
  else
    check "V8 --accept-partial records the bypass and validates (r1=$RC_R1 r2=$RC_R2 plain=$RC_PLAIN rc=$RC)" FAIL
    printf '%s\n' "$PLAIN_ERR"
    VERR
  fi
else
  check "V8 drive an Autopilot run to VALIDATE for the partial case" FAIL
fi

VN="$WORK/val-no-copy"
if val_setup "val-no-copy" "$VN" val_run_nocopy false "$APPROVED_SHA"; then
  VN_HEAD="$VAL_HEAD"
  VN_FILE="$VAL_RUN_FILE"
  VN_BEFORE="$(file_sha "$VN_FILE")"
  val_validate val_run_nocopy; RC=$?
  NOCOPY_ERR="$(cat "$WORK/verr")"
  val_record val_run_nocopy AC-002 pass browser <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_REC=$?
  ZENSU_ACCEPTANCE_GATE=off val_validate val_run_nocopy; RC_ESC=$?
  if [ "$RC" -eq 1 ] \
    && printf '%s' "$NOCOPY_ERR" | grep -qF "ACCEPTANCE — unresolved | autopilot run val_run_nocopy has no stored copy of the plan it approved (.zensu/state/autopilot-approved-plan-$APPROVED_SHA.md)" \
    && printf '%s' "$NOCOPY_ERR" | grep -qF 'only the user can leave ZENSU_ACCEPTANCE_GATE=off for this run | gate: required' \
    && [ "$RC_REC" -eq 1 ] && grep -qF 'has no stored copy of the plan it approved' "$WORK/vrerr" \
    && [ "$RC_ESC" -eq 0 ] \
    && grep -qF 'ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record of autopilot run val_run_nocopy was read | gate: required' "$WORK/verr" \
    && run_json_ok "$VN_FILE" "v.stage === \"DELIVER\" && v.evidence.validation.headSha === \"$VN_HEAD\" && v.bypasses.length === 1 && v.bypasses[0].gate === \"ZENSU_ACCEPTANCE_GATE\" && v.bypasses[0].stage === \"VALIDATE\""; then
    check "V9 a run without a stored plan refuses as unresolved and names the user's escape, which is ledgered when taken" PASS
  else
    check "V9 a run without a stored plan refuses, and the escape is ledgered (rc=$RC rec=$RC_REC esc=$RC_ESC)" FAIL
    printf '%s\n' "$NOCOPY_ERR"
    VERR
  fi
else
  check "V9 drive an Autopilot run to VALIDATE without a stored plan copy" FAIL
fi

VA="$WORK/val-advisory"
printf '%s\n' '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"advisory"}}' > "$WORK/config-acceptance-advisory.json"
if val_setup "val-advisory" "$VA" val_run_advisory false; then
  VA_HEAD="$VAL_HEAD"
  VA_FILE="$VAL_RUN_FILE"
  ZENSU_CONFIG="$WORK/config-acceptance-advisory.json" val_validate val_run_advisory; RC=$?
  if [ "$RC" -eq 0 ] \
    && grep -qF "ACCEPTANCE — incomplete (advisory, not blocking) | autopilot run val_run_advisory: 0/2 acceptance criteria pass on the pull-request head ${VA_HEAD:0:12}" "$WORK/verr" \
    && grep -qxF "zensu autopilot: run val_run_advisory validated at the pull-request head ${VA_HEAD:0:12}, with the acceptance-advisory bypass recorded in its ledger" "$WORK/vout" \
    && run_json_ok "$VA_FILE" "v.stage === \"DELIVER\" && v.bypasses.length === 1 && v.bypasses[0].gate === \"acceptance-advisory\" && v.bypasses[0].stage === \"VALIDATE\" && v.events.some((e) => e.eventId === \"validation-bypass:acceptance-advisory:1:$VA_HEAD\")"; then
    check "V10 an advisory acceptance gate discloses the missing criteria, records acceptance-advisory in the run's ledger and validates" PASS
  else
    check "V10 an advisory acceptance gate discloses and validates (rc=$RC)" FAIL
    VERR
  fi
else
  check "V10 drive an Autopilot run to VALIDATE for the advisory case" FAIL
fi

VW="$WORK/val-worktree"
val_project "$VW"
git -C "$VW" worktree add -q "$VW/.claude/worktrees/wt" -b val-wt 2>/dev/null
VWT="$(cd -P "$VW/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
VW_OK=false
if [ -n "$VWT" ]; then
  printf 'worktree v2\n' > "$VWT/tracked.txt"
  git -C "$VWT" -c commit.gpgsign=false commit -qam 'worktree change'
  VW_HEAD="$(git -C "$VWT" rev-parse HEAD)"
  export CLAUDE_PROJECT_DIR="$VW"
  cd "$VW" || exit 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "val-worktree" \
    && autopilot_begin_run val_run_wt "$ZENSU_SESSION_KEY" "$VW" true true "$VWT" >/dev/null 2>&1 \
    && val_store_plan "$VW" \
    && val_drive val_run_wt "$VW" "$VAL_SHA" "$VW_HEAD" \
    && VW_OK=true
fi
if [ "$VW_OK" = true ]; then
  VW_FILE="$(autopilot_run_file val_run_wt "$VW")"
  val_observe val_run_wt 'pwd -P'
  WT_EVR="$VAL_EVR"
  WT_OUT="$(cat "$WORK/veout")"
  WT_NOTE="$(cat "$WORK/veerr")"
  val_record val_run_wt AC-001 pass cli "$WT_EVR" <<'EVIDENCE'
the fixture command printed the worktree
EVIDENCE
  RC_R1=$?
  val_record val_run_wt AC-002 pass browser <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_R2=$?
  bash "$LOG" --acceptance-status --run val_run_wt >"$WORK/vsout" 2>"$WORK/vserr"; RC_ST=$?
  printf 'worktree v3\n' > "$VWT/tracked.txt"
  bash "$LOG" --acceptance-status --run val_run_wt >"$WORK/vsout2" 2>"$WORK/vserr2"; RC_STALE=$?
  val_validate val_run_wt; RC_DIRTY=$?
  git -C "$VWT" checkout -q -- tracked.txt
  val_validate val_run_wt; RC=$?
  if [ -n "$WT_EVR" ] && printf '%s\n' "$WT_OUT" | grep -qxF "$VWT" \
    && printf '%s' "$WT_NOTE" | grep -qF "so the command runs in $VWT" \
    && [ "$RC_R1" -eq 0 ] && [ "$RC_R2" -eq 0 ] \
    && [ "$RC_ST" -eq 0 ] && grep -q '| 2/2 active criteria pass$' "$WORK/vsout" \
    && [ "$RC_STALE" -eq 1 ] \
    && grep -q "^AC-001 stale (files changed since it was verified: \.claude/worktrees/wt/tracked\.txt) | cli observed $WT_EVR | " "$WORK/vsout2" \
    && [ "$RC_DIRTY" -eq 1 ] \
    && [ "$RC" -eq 0 ] \
    && grep -qF "ACCEPTANCE — pass | autopilot run val_run_wt: 2/2 acceptance criteria pass on the pull-request head ${VW_HEAD:0:12}" "$WORK/verr" \
    && run_json_ok "$VW_FILE" "v.stage === \"COVER\" && v.evidence.validation.headSha === \"$VW_HEAD\""; then
    check "V11 a run that drives a worktree below the anchor runs, records and validates against the combined tree, and an edit there makes its records stale" PASS
  else
    check "V11 a worktree run binds the combined tree (run=$WT_EVR r1=$RC_R1 r2=$RC_R2 status=$RC_ST stale=$RC_STALE dirty=$RC_DIRTY rc=$RC)" FAIL
    printf '%s\n%s\n' "$WT_OUT" "$WT_NOTE"
    VERR; cat "$WORK/vsout" "$WORK/vserr" "$WORK/vsout2" "$WORK/vserr2"
  fi
else
  check "V11 drive an Autopilot run that drives a worktree below the anchor to VALIDATE" FAIL
fi

VX="$WORK/val-no-validate"
val_project "$VX"
export CLAUDE_PROJECT_DIR="$VX"
cd "$VX" || exit 1
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "val-no-validate"
if autopilot_begin_run val_run_novalidate "$ZENSU_SESSION_KEY" "$VX" false false >/dev/null 2>&1; then
  VX_FILE="$(autopilot_run_file val_run_novalidate "$VX")"
  VX_BEFORE="$(file_sha "$VX_FILE")"
  val_validate val_run_novalidate; RC=$?
  NOVAL_ERR="$(cat "$WORK/verr")"
  val_record val_run_novalidate AC-002 pass browser <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_REC=$?
  val_validate val_run_unknown; RC_OTHER=$?
  OTHER_ERR="$(cat "$WORK/verr")"
  bash "$LOG" --acceptance-status --log "$RUN_LOG" --run val_run_novalidate >"$WORK/vsout" 2>"$WORK/vserr"; RC_BOTH=$?
  bash "$LOG" --evidence-run --scope full --run val_run_novalidate --cmd "touch '$WORK/val-full-ran'" >"$WORK/veout" 2>"$WORK/veerr"; RC_FULL=$?
  if [ "$RC" -eq 2 ] \
    && printf '%s' "$NOVAL_ERR" | grep -qF 'autopilot run val_run_novalidate was begun with --no-validate, so it has no VALIDATE stage and nothing to validate' \
    && [ "$RC_REC" -eq 1 ] && grep -qF 'autopilot run val_run_novalidate was begun with --no-validate, so it has no acceptance criteria to verify' "$WORK/vrerr" \
    && [ "$RC_OTHER" -eq 2 ] && printf '%s' "$OTHER_ERR" | grep -qF -- '--run val_run_unknown is not the active Autopilot run of this session' \
    && [ "$RC_BOTH" -eq 2 ] && grep -qF -- '--log and --run name two different anchors' "$WORK/vserr" \
    && [ "$RC_FULL" -eq 2 ] && [ ! -e "$WORK/val-full-ran" ] && grep -qF -- '--run applies only to --scope acceptance' "$WORK/veerr" \
    && [ "$(file_sha "$VX_FILE")" = "$VX_BEFORE" ]; then
    check "V12 a --no-validate run is refused by the verb and the records, another run id is refused, and --run excludes --log and every scope but acceptance" PASS
  else
    check "V12 the run-mode refusals (rc=$RC rec=$RC_REC other=$RC_OTHER both=$RC_BOTH full=$RC_FULL)" FAIL
    printf '%s\n%s\n' "$NOVAL_ERR" "$OTHER_ERR"
    VERR; cat "$WORK/vserr"
  fi
else
  check "V12 begin a --no-validate Autopilot run" FAIL
fi

VZ="$WORK/val-no-run"
val_project "$VZ"
export CLAUDE_PROJECT_DIR="$VZ"
cd "$VZ" || exit 1
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "val-no-run"
val_validate val_run_main; RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'this session owns no active Autopilot run, so --run val_run_main names no run it may verify' "$WORK/verr"; then
  check "V13 a session that owns no active run cannot validate another session's run" PASS
else
  check "V13 a session without a run is refused (rc=$RC)" FAIL
  VERR
fi

VS="$WORK/val-subdirectory"
val_project "$VS"
printf '/.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$VS/.gitignore"
mkdir -p "$VS/app" "$VS/shared"
printf 'app v1\n' > "$VS/app/app.txt"
printf 'shared v1\n' > "$VS/shared/lib.txt"
git -C "$VS" add .gitignore app/app.txt shared/lib.txt
git -C "$VS" -c commit.gpgsign=false commit -qm 'a project root below the repository top'
VSA="$(cd -P "$VS/app" 2>/dev/null && pwd -P)"
VS_OK=false
if [ -n "$VSA" ]; then
  VS_HEAD="$(git -C "$VS" rev-parse HEAD)"
  export CLAUDE_PROJECT_DIR="$VSA"
  cd "$VSA" || exit 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "val-subdirectory" \
    && autopilot_begin_run val_run_sub "$ZENSU_SESSION_KEY" "$VSA" false true >/dev/null 2>&1 \
    && val_store_plan "$VSA" \
    && val_drive val_run_sub "$VSA" "$VAL_SHA" "$VS_HEAD" \
    && VS_OK=true
fi
if [ "$VS_OK" = true ]; then
  VS_FILE="$(autopilot_run_file val_run_sub "$VSA")"
  val_observe val_run_sub 'printf ok'
  SUB_EVR="$VAL_EVR"
  val_record val_run_sub AC-001 pass cli "$SUB_EVR" <<'EVIDENCE'
the fixture command printed ok
EVIDENCE
  RC_R1=$?
  val_record val_run_sub AC-002 pass browser <<'EVIDENCE'
the page showed the saved value
EVIDENCE
  RC_R2=$?
  bash "$LOG" --acceptance-status --run val_run_sub >"$WORK/vsout" 2>"$WORK/vserr"; RC_ST=$?
  printf 'shared v2\n' > "$VS/shared/lib.txt"
  bash "$LOG" --acceptance-status --run val_run_sub >"$WORK/vsout2" 2>"$WORK/vserr2"; RC_STALE=$?
  val_validate val_run_sub; RC_DIRTY=$?
  SUB_DIRTY_ERR="$(cat "$WORK/verr")"
  git -C "$VS" checkout -q -- shared/lib.txt
  val_validate val_run_sub; RC=$?
  if [ -n "$SUB_EVR" ] && [ "$RC_R1" -eq 0 ] && [ "$RC_R2" -eq 0 ] \
    && [ "$RC_ST" -eq 0 ] && grep -q '| 2/2 active criteria pass$' "$WORK/vsout" \
    && [ "$RC_STALE" -eq 1 ] \
    && grep -q "^AC-001 stale (files changed since it was verified: \.\./shared/lib\.txt) | cli observed $SUB_EVR | " "$WORK/vsout2" \
    && [ "$RC_DIRTY" -eq 1 ] \
    && printf '%s' "$SUB_DIRTY_ERR" | grep -qF "ACCEPTANCE — unresolved | autopilot run val_run_sub: the work tree has uncommitted changes, so it is not the pull-request head ${VS_HEAD:0:12}" \
    && [ "$RC" -eq 0 ] \
    && grep -qF "ACCEPTANCE — pass | autopilot run val_run_sub: 2/2 acceptance criteria pass on the pull-request head ${VS_HEAD:0:12}" "$WORK/verr" \
    && run_json_ok "$VS_FILE" "v.stage === \"DELIVER\" && v.evidence.validation.headSha === \"$VS_HEAD\""; then
    check "V14 a run whose project root lies below the repository top binds the whole repository: an edit outside the project root makes its records stale and refuses validation until it is gone" PASS
  else
    check "V14 a subdirectory session binds the whole repository (run=$SUB_EVR r1=$RC_R1 r2=$RC_R2 status=$RC_ST stale=$RC_STALE dirty=$RC_DIRTY rc=$RC)" FAIL
    printf '%s\n' "$SUB_DIRTY_ERR"
    VERR; cat "$WORK/vsout" "$WORK/vserr" "$WORK/vsout2" "$WORK/vserr2"
  fi
else
  check "V14 drive an Autopilot run whose project root lies below the repository top to VALIDATE" FAIL
fi

VH="$WORK/val-head-update"
if val_setup "val-head-update" "$VH" val_run_head false; then
  VH_HEAD="$VAL_HEAD"
  VH_FILE="$VAL_RUN_FILE"
  val_event val_run_head "validation-failed-1-val_run_head" VALIDATION_FAILED \
      "{\"headSha\":\"$VH_HEAD\",\"reason\":\"a criterion fails on this tree\"}" "$VH" \
    && val_event val_run_head "tdd-start-2-val_run_head" TDD_STARTED \
      "{\"attempt\":2,\"chainId\":\"chain-fix-val_run_head\",\"sessionId\":\"$ZENSU_SESSION_KEY\"}" "$VH" \
    && val_event val_run_head "tdd-done-2-val_run_head" TDD_CHAIN_DONE \
      "{\"attempt\":2,\"chainId\":\"chain-fix-val_run_head\",\"sessionId\":\"$ZENSU_SESSION_KEY\",\"outcome\":\"pass\"}" "$VH" \
    && run_json_ok "$VH_FILE" 'v.stage === "VALIDATE" && v.tdd.headUpdateRequired === true'
  RC_LOOP=$?
  VH_BACK="$(file_sha "$VH_FILE")"
  val_validate val_run_head; RC_PENDING=$?
  PENDING_ERR="$(cat "$WORK/verr")"
  ZENSU_ACCEPTANCE_GATE=off val_validate val_run_head; RC_PENDING_ESC=$?
  PENDING_ESC_ERR="$(cat "$WORK/verr")"
  VH_REFUSED="$(file_sha "$VH_FILE")"
  printf 'v2\n' > "$VH/tracked.txt"
  git -C "$VH" -c commit.gpgsign=false commit -qam 'fix the failing criterion'
  VH_NEW="$(git -C "$VH" rev-parse HEAD)"
  val_event val_run_head "head:$VH_HEAD:$VH_NEW" PR_HEAD_UPDATED \
    "{\"previousHeadSha\":\"$VH_HEAD\",\"headSha\":\"$VH_NEW\",\"gatesPassed\":true,\"pushCompleted\":true}" "$VH" \
    && val_event val_run_head "findings-clear-2-val_run_head" FINDINGS_CLEARED "{\"headSha\":\"$VH_NEW\",\"unresolvedCount\":0}" "$VH" \
    && run_json_ok "$VH_FILE" 'v.stage === "VALIDATE" && v.tdd.headUpdateRequired === false'
  RC_HANDOFF=$?
  ZENSU_ACCEPTANCE_GATE=off val_validate val_run_head; RC=$?
  PENDING_TEXT='autopilot run val_run_head came back to VALIDATE from a fix attempt whose pushed head is not recorded yet, so it has no pull-request head to validate: re-run the gates, push the fix and record PR_HEAD_UPDATED'
  if [ "$RC_LOOP" -eq 0 ] \
    && [ "$RC_PENDING" -eq 2 ] && printf '%s' "$PENDING_ERR" | grep -qF "zensu-log.sh --autopilot-validate: $PENDING_TEXT" \
    && [ "$RC_PENDING_ESC" -eq 2 ] && printf '%s' "$PENDING_ESC_ERR" | grep -qF "zensu-log.sh --autopilot-validate: $PENDING_TEXT" \
    && [ "$VH_REFUSED" = "$VH_BACK" ] \
    && [ "$RC_HANDOFF" -eq 0 ] \
    && [ "$RC" -eq 0 ] \
    && grep -qxF "zensu autopilot: run val_run_head validated at the pull-request head ${VH_NEW:0:12}, with the ZENSU_ACCEPTANCE_GATE bypass recorded in its ledger" "$WORK/vout" \
    && run_json_ok "$VH_FILE" "v.stage === \"DELIVER\" && v.evidence.validation.headSha === \"$VH_NEW\" && v.bypasses.length === 1 && v.bypasses[0].gate === \"ZENSU_ACCEPTANCE_GATE\" && v.events.some((e) => e.eventId === \"validation-bypass:ZENSU_ACCEPTANCE_GATE:3:$VH_NEW\") && v.events[v.events.length - 1].eventId === \"validation-passed:3:$VH_NEW\""; then
    check "V15 a run back at VALIDATE from a fix attempt is refused until its pushed head is recorded, the switched-off gate included, without a ledger entry, and its next visit validates under event ids of visit 3" PASS
  else
    check "V15 a pending head update refuses validation and the next visit validates (loop=$RC_LOOP pending=$RC_PENDING escaped=$RC_PENDING_ESC handoff=$RC_HANDOFF rc=$RC)" FAIL
    printf '%s\n%s\n' "$PENDING_ERR" "$PENDING_ESC_ERR"
    VERR
  fi
else
  check "V15 drive an Autopilot run to VALIDATE for the head-update case" FAIL
fi
cd "$PROJ" || exit 1

rm -f "$TDD_SKILL"
unit_check_done "A0z every unit file the registry gives this suite was graded"
finish
