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
printf '{}\n' > "$ZENSU_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_FULL_SUITE_GATE ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE 2>/dev/null || true
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
  ZENSU_EVR_LIB_PATH="$LIB" PD="$CLAUDE_PLUGIN_DATA" KEY="$ZENSU_SESSION_KEY" ROOT="$ZENSU_PROJECT_ROOT" SHELL_PID="$$" node -e '
    const evr = require(process.env.ZENSU_EVR_LIB_PATH);
    const locations = evr.storeLocations(process.env.PD, process.env.KEY);
    evr.writeRecordAtomic(locations.records, {
      schema: evr.SCHEMA, id: evr.newRecordId(Date.now()), session_key: process.env.KEY,
      project_root: process.env.ROOT, scope: "full", command: "npm test", cwd: process.env.ROOT,
      state: "running", pid: Number(process.env.SHELL_PID), started_at: new Date().toISOString(),
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

printf '{"evidence":{"fullSuiteGate":"advisory"}}\n' > "$ZENSU_CONFIG"
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

printf '{"evidence":{"fullSuiteGate":"sometimes"}}\n' > "$ZENSU_CONFIG"
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

printf '{"evidence":{"fullSuiteCommand":"echo configured"}}\n' > "$ZENSU_CONFIG"
if arm "fsg-mismatch" "$PROJ"; then
  run_full --cmd 'true'
  printf '{}\n' > "$ZENSU_CONFIG"
  run_full --cmd 'true'
  printf '{"evidence":{"fullSuiteCommand":"echo configured"}}\n' > "$ZENSU_CONFIG"
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
printf '{}\n' > "$ZENSU_CONFIG"

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

finish
