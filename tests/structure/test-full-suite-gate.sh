#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LIB="$PLUGIN_DIR/hooks/lib/evidence-run-v1.js"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-full-suite-gate: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LOG" "$TDD_LIB" "$POSTREV" "$LIB" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "F0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "F0 node and git are available" FAIL
  finish
  exit 1
fi
check "F0 required files, node and git are present" PASS

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-full-suite-gate.sh") ? 0 : 1);
' "$PROFILE"; then
  check "F0a the suite is classified as a CI structure test" PASS
else
  check "F0a the suite is classified as a CI structure test" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "F0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{"evidence":{"acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_FULL_SUITE_GATE ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE ZENSU_ACCEPTANCE_GATE 2>/dev/null || true
source "$TDD_LIB"

PROJ="$WORK/project"
PLAIN="$WORK/plain"
mkdir -p "$PROJ" "$PLAIN"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'baseline\n' > "$PROJ/tracked.txt"
git -C "$PROJ" add .gitignore tracked.txt
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline

arm() {
  local sid="$1" project="$2" ctx
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete >/dev/null 2>&1 || return 1
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

chain_done() {
  bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"
}

run_full() {
  bash "$LOG" --evidence-run --scope full "$@" >/dev/null 2>&1
}

done_flag() {
  tdd_chain_done "$SF" 2>/dev/null
}

ERR() { cat "$WORK/err" 2>/dev/null; }

if arm "fsg-missing" "$PROJ"; then
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — missing | no full-suite run is recorded for this session | cmd: none recorded | gate: required | run: CLAUDE_PLUGIN_DATA=.* --evidence-run --scope full --cmd '"'"'<your full test command>'"'"'$' "$WORK/err" \
    && grep -qF 'the chain stays open' "$WORK/err"; then
    check "F1 no full-suite record refuses the ticket-bound terminus with a runnable remedy" PASS
  else
    check "F1 no full-suite record refuses the ticket-bound terminus (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "F1 arm a ticket-bound chain" FAIL
fi

run_full --cmd 'echo red; exit 3'
chain_done; RC=$?
if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
  && grep -q '^FULL SUITE — failed | the newest full-suite run exited 3 ' "$WORK/err" \
  && grep -qF "run: CLAUDE_PLUGIN_DATA=" "$WORK/err" \
  && grep -qF -- "--cmd 'echo red; exit 3'" "$WORK/err"; then
  check "F2 a red full-suite record refuses and names the command to re-run" PASS
else
  check "F2 a red full-suite record refuses (rc=$RC)" FAIL
  ERR
fi

run_full --cmd 'true'
chain_done; RC=$?
if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
  && grep -q '^FULL SUITE — pass | exit 0 on the current tree [0-9a-f]\{12\} (record er1_' "$WORK/err" \
  && grep -q '^FULL SUITE — flaky: 1 earlier run(s) on this same tree did not pass$' "$WORK/err"; then
  check "F3 a green record on the current tree closes the chain and discloses the earlier red run" PASS
else
  check "F3 a green record on the current tree closes the chain (rc=$RC done=$(done_flag))" FAIL
  ERR
fi

chain_done; RC=$?
if [ "$RC" -eq 0 ] && ! grep -q 'FULL SUITE' "$WORK/err"; then
  check "F4 a repeated terminus on a closed chain short-circuits without a verdict" PASS
else
  check "F4 a repeated terminus on a closed chain short-circuits (rc=$RC)" FAIL
  ERR
fi

if arm "fsg-stale" "$PROJ"; then
  run_full --cmd 'true'
  printf 'edited\n' > "$PROJ/tracked.txt"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — stale | the newest green full-suite run measured an older tree (record er1_[0-9_a-f]*); files changed since: tracked.txt | ' "$WORK/err"; then
    check "F5 an edit after the green run refuses as stale and lists the path" PASS
  else
    check "F5 an edit after the green run refuses as stale (rc=$RC)" FAIL
    ERR
  fi
  BADGIT="$WORK/bad-gitfile"
  mkdir -p "$BADGIT"
  printf 'garbage\n' > "$BADGIT/.git"
  _evr_work_tree="$BADGIT" _evr_work_dir="$BADGIT" _avr_work_tree="$BADGIT" \
    bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — stale | the newest green full-suite run measured an older tree (record er1_[0-9_a-f]*); files changed since: tracked.txt | ' "$WORK/err"; then
    check "F24 work-tree variables inherited from the caller leave the standalone verdict unchanged" PASS
  else
    check "F24 work-tree variables inherited from the caller leave the standalone verdict unchanged (rc=$RC)" FAIL
    ERR
  fi
  run_full --cmd 'true' --if-stale
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && grep -q '^FULL SUITE — pass | ' "$WORK/err"; then
    check "F6 --if-stale re-runs the stale suite and the terminus then closes" PASS
  else
    check "F6 --if-stale re-runs the stale suite and the terminus then closes (rc=$RC)" FAIL
    ERR
  fi
  git -C "$PROJ" checkout -q -- tracked.txt
else
  check "F5 arm a ticket-bound chain" FAIL
fi

if arm "fsg-running" "$PROJ"; then
  rm -f "$WORK/live.pid"
  node -e 'require("fs").writeFileSync(process.argv[1], String(process.pid)); setTimeout(() => {}, 120000);' \
    "$WORK/live.pid" &
  LIVE_JOB=$!
  tries=0
  while [ ! -s "$WORK/live.pid" ] && [ "$tries" -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
  LIVE_PID="$(cat "$WORK/live.pid" 2>/dev/null)"
  if [ -n "$LIVE_PID" ]; then
    ZENSU_EVR_LIB_PATH="$LIB" PD="$CLAUDE_PLUGIN_DATA" KEY="$ZENSU_SESSION_KEY" ROOT="$ZENSU_PROJECT_ROOT" LIVE_PID="$LIVE_PID" node -e '
      const evr = require(process.env.ZENSU_EVR_LIB_PATH);
      const locations = evr.storeLocations(process.env.PD, process.env.KEY);
      evr.writeRecordAtomic(locations.records, {
        schema: evr.SCHEMA, id: evr.newRecordId(Date.now()), session_key: process.env.KEY,
        project_root: process.env.ROOT, scope: "full", command: "npm test", cwd: process.env.ROOT,
        state: "running", pid: Number(process.env.LIVE_PID), started_at: new Date().toISOString(),
        finished_at: null, duration_ms: null, exit_code: null, signal: null,
        tree_start: null, tree_start_reason: "fixture", tree_end: null, tree_end_reason: null,
        plugin_version: "fixture", log_bytes: 0, log_truncated: false,
      });
    '
    chain_done; RC=$?
    if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
      && grep -q '^FULL SUITE — running | a full-suite run is still in progress .* | gate: required$' "$WORK/err"; then
      check "F7 a live running record refuses without suggesting a second run" PASS
    else
      check "F7 a live running record refuses (rc=$RC)" FAIL
      ERR
    fi
    node -e 'try { process.kill(Number(process.argv[1])); } catch (_) {}' "$LIVE_PID"
  else
    check "F7 fixture: a live node process to own the running record" FAIL
  fi
  kill "$LIVE_JOB" 2>/dev/null
  wait "$LIVE_JOB" 2>/dev/null
else
  check "F7 arm a ticket-bound chain" FAIL
fi

if arm "fsg-escape" "$PROJ"; then
  ZENSU_FULL_SUITE_GATE=off bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  FIRST="$(grep -n '^FULL SUITE — escaped | ZENSU_FULL_SUITE_GATE=off switched this check off, so no run was read | gate: required$' "$WORK/err" | cut -d: -f1)"
  SECOND="$(grep -n '^Gates bypassed during this session: ZENSU_FULL_SUITE_GATE$' "$WORK/err" | cut -d: -f1)"
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ "$LEDGER" = "ZENSU_FULL_SUITE_GATE" ] \
    && [ -n "$FIRST" ] && [ -n "$SECOND" ] && [ "$FIRST" -lt "$SECOND" ]; then
    check "F8 the escape closes the chain, lands in the bypass ledger and renders before the ledger line" PASS
  else
    check "F8 the escape closes the chain and lands in the bypass ledger (rc=$RC ledger='$LEDGER' first=$FIRST second=$SECOND)" FAIL
    ERR
  fi
else
  check "F8 arm a ticket-bound chain" FAIL
fi

if arm "fsg-wrong-ticket" "$PROJ"; then
  ZENSU_FULL_SUITE_GATE=off bash "$LOG" --chain-done --claimed-review-ticket "rt_wrong" >"$WORK/out" 2>"$WORK/err"; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  if [ "$RC" -ne 0 ] && [ "$(done_flag)" = "false" ] && ! grep -q 'FULL SUITE' "$WORK/err" && [ -z "$LEDGER" ]; then
    check "F9 a wrong ticket is refused by the ticket check, before the verdict, and records no escape" PASS
  else
    check "F9 a wrong ticket is refused by the ticket check (rc=$RC ledger='$LEDGER')" FAIL
    ERR
  fi
else
  check "F9 arm a ticket-bound chain" FAIL
fi

printf '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
if arm "fsg-advisory" "$PROJ"; then
  chain_done; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ -z "$LEDGER" ] \
    && grep -q '^FULL SUITE — missing (advisory, not blocking) | .* | gate: advisory | run: ' "$WORK/err"; then
    check "F10 advisory mode discloses the missing record and closes the chain" PASS
  else
    check "F10 advisory mode discloses the missing record and closes the chain (rc=$RC)" FAIL
    ERR
  fi
else
  check "F10 arm a ticket-bound chain" FAIL
fi

printf '{"evidence":{"fullSuiteGate":"sometimes","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
if arm "fsg-unknown-mode" "$PROJ"; then
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "FULL SUITE — evidence.fullSuiteGate value 'sometimes' is not recognized (expected required or advisory); treated as required" "$WORK/err" \
    && grep -q '^FULL SUITE — missing | .* | gate: required | run: ' "$WORK/err"; then
    check "F11 an unknown gate mode is disclosed and acts as required" PASS
  else
    check "F11 an unknown gate mode is disclosed and acts as required (rc=$RC)" FAIL
    ERR
  fi
else
  check "F11 arm a ticket-bound chain" FAIL
fi

printf '{"evidence":{"fullSuiteCommand":"echo configured","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
if arm "fsg-mismatch" "$PROJ"; then
  run_full --cmd 'true'
  printf '{"evidence":{"acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
  run_full --cmd 'true'
  printf '{"evidence":{"fullSuiteCommand":"echo configured","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — command-mismatch | .* | cmd: echo configured | gate: required | run: CLAUDE_PLUGIN_DATA=.* --evidence-run --scope full$' "$WORK/err"; then
    check "F12 a green run of a different command than evidence.fullSuiteCommand refuses as command-mismatch" PASS
  else
    check "F12 a green run of a different command refuses as command-mismatch (rc=$RC)" FAIL
    ERR
  fi
  run_full
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && grep -q '^FULL SUITE — pass | .* | cmd: echo configured | gate: required$' "$WORK/err"; then
    check "F13 a run of the configured command closes the chain" PASS
  else
    check "F13 a run of the configured command closes the chain (rc=$RC)" FAIL
    ERR
  fi
else
  check "F12 arm a ticket-bound chain" FAIL
fi
printf '{"evidence":{"acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"

if arm "fsg-plain" "$PLAIN"; then
  ZENSU_FULL_SUITE_GATE=off bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"; RC=$?
  LEDGER="$(tdd_bypasses "$SF" 2>/dev/null)"
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ -z "$LEDGER" ] \
    && grep -q '^FULL SUITE — not-applicable | the project is not a git repository, so no run can be bound to a tree | gate: required$' "$WORK/err"; then
    check "F14 a project outside git is not gated, says why, and records no escape" PASS
  else
    check "F14 a project outside git is not gated (rc=$RC ledger='$LEDGER')" FAIL
    ERR
  fi
else
  check "F14 arm a ticket-bound chain" FAIL
fi

export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || exit 1
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "fsg-zero-change"
bash "$LOG" --tdd-begin >/dev/null 2>&1
bash "$LOG" --tdd-complete >/dev/null 2>&1
bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(tdd_chain_done "$(tdd_state_file "fsg-zero-change")")" = "true" ] && [ ! -s "$WORK/err" ]; then
  check "F15 the unqualified zero-change terminus stays exempt and silent without any record" PASS
else
  check "F15 the unqualified zero-change terminus stays exempt and silent (rc=$RC)" FAIL
  ERR
fi

printf '.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$PROJ/.gitignore"
git -C "$PROJ" add .gitignore
git -C "$PROJ" -c commit.gpgsign=false commit -qm ignore-worktrees
NESTED="$PROJ/.claude/worktrees/wt"
git -C "$PROJ" worktree add -q "$NESTED" -b wt 2>/dev/null
if [ -d "$NESTED" ] && arm "fsg-nested" "$PROJ"; then
  (cd "$NESTED" && bash "$LOG" --evidence-run --scope full --cmd 'true' >"$WORK/nested.out" 2>"$WORK/nested.err")
  printf 'edited in the worktree\n' > "$NESTED/tracked.txt"
  (cd "$NESTED" && bash "$LOG" --evidence-run --scope full --cmd 'true' --if-stale >"$WORK/nested-skip.out" 2>&1)
  if grep -qF 'the working directory is not in the work tree of the bound project root, so the command runs in ' "$WORK/nested.err" \
    && grep -qF 'skipped (--if-stale)' "$WORK/nested-skip.out"; then
    check "F16 a run from inside a nested worktree runs in the project root, so an edit there leaves it current" PASS
  else
    check "F16 a run from inside a nested worktree runs in the project root, so an edit there leaves it current" FAIL
    cat "$WORK/nested.err" "$WORK/nested-skip.out"
  fi
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && grep -q '^FULL SUITE — pass | ' "$WORK/err" \
    && ! grep -qF 'of the project and' "$WORK/err"; then
    check "F17 the terminus closes on the project tree that run measured" PASS
  else
    check "F17 the terminus closes on the project tree that run measured (rc=$RC)" FAIL
    ERR
  fi
else
  check "F16 arm a ticket-bound chain beside a nested worktree" FAIL
fi

NESTED_HOST="$(bash "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$NESTED" 2>/dev/null)"
if [ -n "$NESTED_HOST" ] && arm "fsg-cd" "$PROJ"; then
  run_full --cmd "cd '$NESTED_HOST' && true"
  printf 'edited again in the worktree\n' > "$NESTED/tracked.txt"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — stale | the newest green full-suite run measured an older tree of the project and \.claude/worktrees/wt (record er1_[0-9_a-f]*); files changed since: \.claude/worktrees/wt/tracked\.txt | ' "$WORK/err"; then
    check "F18 a run from the project root that cds into a nested worktree sees an edit there as stale" PASS
  else
    check "F18 a run from the project root that cds into a nested worktree sees an edit there as stale (rc=$RC)" FAIL
    ERR
  fi
  run_full --cmd "cd '$NESTED_HOST' && true" --if-stale
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && grep -q '^FULL SUITE — pass | ' "$WORK/err"; then
    check "F19 --if-stale with the same cd re-runs the suite and the terminus then closes" PASS
  else
    check "F19 --if-stale with the same cd re-runs the suite and the terminus then closes (rc=$RC)" FAIL
    ERR
  fi
else
  check "F18 arm a ticket-bound chain for a cd into a nested worktree" FAIL
fi

echo "== A chain bound to an Autopilot run that drives a worktree below the anchor =="
source "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
APPROVED_SHA="$(printf 'a%.0s' $(seq 1 64))"
WSTEM="2026-01-01-0202_build-bound-worktree"
BOUND="$WORK/bound"
mkdir -p "$BOUND"
git -C "$BOUND" init -q
git -C "$BOUND" config user.email t@example.invalid
git -C "$BOUND" config user.name tester
printf '.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$BOUND/.gitignore"
printf 'baseline\n' > "$BOUND/tracked.txt"
git -C "$BOUND" add .gitignore tracked.txt
git -C "$BOUND" -c commit.gpgsign=false commit -qm baseline
git -C "$BOUND" worktree add -q "$BOUND/.claude/worktrees/wt" -b wt-bound 2>/dev/null
BWT="$(cd -P "$BOUND/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
BOUND_HOST="$(bash "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$BOUND" 2>/dev/null)"
bound_arm_wt() {
  local sid="$1" run="$2" chain="$3" rp
  export CLAUDE_PROJECT_DIR="$BOUND"
  cd "$BOUND" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$BOUND" false true "$BWT" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-$run" PLAN_APPROVED "{\"approvedPlanSha256\":\"$APPROVED_SHA\"}" "$BOUND" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-begin --session "$sid" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1 || return 1
  mkdir -p "$BOUND/.zensu/plans" "$BOUND/.zensu/logs"
  printf '# Fixture plan\n\n## Requirements\n| ID | Requirement | Source |\n|----|-------------|--------|\n| AC-001 | the worktree file changed | spec |\n' \
    > "$BOUND/.zensu/plans/$WSTEM.md"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$BOUND/.zensu/logs/$WSTEM.log"
  rp="$(tdd_edit_landing_receipt "$sid")" || return 1
  mkdir -p "$(dirname "$rp")"
  printf '{"schema":"edit-landing-v2","session":"%s","log":".zensu/logs/%s.log","claims":1,"landed":1,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true,"workTree":".claude/worktrees/wt"}\n' \
    "$sid" "$WSTEM" > "$rp"
  bash "$LOG" --tdd-complete --session "$sid" --plan "$BOUND/.zensu/plans/$WSTEM.md" --autopilot-run "$run" \
    --autopilot-attempt 1 --chain-id "$chain" >/dev/null 2>"$WORK/complete.err" || return 1
  SF="$(tdd_state_file "$sid")"
}
bound_done_wt() {
  bash "$LOG" --chain-done --session fsg-bound-wt --autopilot-run fsg_run --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id fsg-chain --outcome pass >"$WORK/out" 2>"$WORK/err"
}
printf 'changed in the worktree\n' > "$BWT/tracked.txt"
if [ -n "$BWT" ] && [ -n "$BOUND_HOST" ] && bound_arm_wt fsg-bound-wt fsg_run fsg-chain; then
  run_full --cmd "cd '$BOUND_HOST' && true"
  bound_done_wt; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — stale | the newest green full-suite run measured an older tree of the project and \.claude/worktrees/wt (record er1_[0-9_a-f]*); ' "$WORK/err"; then
    check "F20 for a bound chain a green run that measured only the anchor reads stale, because the terminus measures the run's worktree" PASS
  else
    check "F20 for a bound chain a run that measured only the anchor reads stale (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi

  bash "$LOG" --evidence-run --scope full --cmd 'pwd -P' >"$WORK/bound-full.out" 2>"$WORK/bound-full.err"; RC_RUN=$?
  printf 'edited again in the worktree\n' > "$BWT/tracked.txt"
  bound_done_wt; RC=$?
  if [ "$RC_RUN" -eq 0 ] && grep -qxF "$BWT" "$WORK/bound-full.out" \
    && grep -qF "so the command runs in $BWT" "$WORK/bound-full.err" \
    && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — stale | the newest green full-suite run measured an older tree of the project and \.claude/worktrees/wt (record er1_[0-9_a-f]*); files changed since: \.claude/worktrees/wt/tracked\.txt | ' "$WORK/err"; then
    check "F21 a run from the anchor runs in the worktree, and an edit there makes it stale with the worktree path listed" PASS
  else
    check "F21 a run from the anchor runs in the worktree and an edit there makes it stale (run=$RC_RUN rc=$RC)" FAIL
    cat "$WORK/bound-full.out" "$WORK/bound-full.err"
    ERR
  fi

  BOUND_RUN_FILE="$(autopilot_run_file fsg_run "$BOUND")"
  cp "$BOUND_RUN_FILE" "$WORK/fsg-run.pre"
  BAD_WS="$BOUND" node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.workspaceRoot = process.env.BAD_WS + "/missing-worktree"; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$BOUND_RUN_FILE"
  bound_done_wt; RC=$?
  cp "$WORK/fsg-run.pre" "$BOUND_RUN_FILE"
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q '^FULL SUITE — unavailable | the work tree of this Autopilot-bound chain could not be resolved (.*), so no run can be bound to it | cmd: none recorded | gate: required$' "$WORK/err"; then
    check "F22 a bound chain whose worktree cannot be resolved is refused as unavailable and stays open" PASS
  else
    check "F22 a bound chain whose worktree cannot be resolved is refused as unavailable (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi

  run_full --cmd 'pwd -P' --if-stale
  bound_done_wt; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^FULL SUITE — pass | exit 0 on the current tree [0-9a-f]\{12\} of the project and \.claude/worktrees/wt (record er1_' "$WORK/err"; then
    check "F23 --if-stale re-runs the suite in the worktree and the bound terminus then closes on it" PASS
  else
    check "F23 --if-stale re-runs the suite in the worktree and the bound terminus closes (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "F20 arm a chain bound to an Autopilot run that drives a worktree below the anchor" FAIL
  cat "$WORK/complete.err" 2>/dev/null
fi

GATES_DOC="$PLUGIN_DIR/docs/gates.md"
check "FS-A1 the gate doc names the combined fingerprint" "$(grep -qF 'combines the project tree and that work tree' "$GATES_DOC" && echo PASS || echo FAIL)"
check "FS-A2 the gate doc names the leading cd" "$(grep -qF 'target of a leading literal `cd <dir>`' "$GATES_DOC" && echo PASS || echo FAIL)"
check "FS-A3 both max-rounds hand-offs run the suite step once before they close" "$([ "$(grep -cF '${CLOSE_SUITE_STEP}' "$POSTREV")" -eq 2 ] && grep -qF 'CLOSE_SUITE_REASON="this run is the only full-suite measurement of the tree that ships"' "$POSTREV" && echo PASS || echo FAIL)"

finish
