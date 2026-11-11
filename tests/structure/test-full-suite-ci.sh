#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-full-suite.sh"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
UNIT="$PLUGIN_DIR/tests/structure/full-suite-ci-v1.test.js"
SKILL="$PLUGIN_DIR/skills/full-suite/SKILL.md"
MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"
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
  echo "test-full-suite-ci: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LOG" "$HELPER" "$TDD_LIB" "$POSTREV" "$UNIT" "$SKILL" "$MANIFEST" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "C0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "C0 node and git are available" FAIL
  finish
  exit 1
fi
check "C0 required files, node and git are present" PASS

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-full-suite-ci.sh") ? 0 : 1);
' "$PROFILE"; then
  check "C0a the suite is classified as a CI structure test" PASS
else
  check "C0a the suite is classified as a CI structure test" FAIL
fi

if node -e '
  const m = require(process.argv[1]);
  process.exit(Array.isArray(m.skills) && m.skills.includes("./skills/full-suite") ? 0 : 1);
' "$MANIFEST"; then
  check "C0b plugin.json registers the full-suite skill" PASS
else
  check "C0b plugin.json registers the full-suite skill" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "C0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

unit_check "C1 the full-suite CI unit file passes" "$UNIT"

SKILL_OK=PASS
for verb in '--status' '--ci --repo' '--local --repo' '--ci --session'; do
  grep -qF "zensu-full-suite.sh\" $verb" "$SKILL" || SKILL_OK=FAIL
done
for verb in '--local --session' '--auto --session' '--auto --repo'; do
  grep -qF -- "$verb" "$SKILL" || SKILL_OK=FAIL
done
check "C2 the skill renders every helper verb" "$SKILL_OK"

c28_holds() {
  local src="$1" arm end snap pat line
  arm="$(grep -nF 'if [ "$tdd_begin_rc" -eq 0 ]' "$src" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$arm" ] || return 1
  end="$(awk -v s="$arm" 'NR>s && /^        else$/{print NR; exit}' "$src")"
  [ -n "$end" ] || return 1
  snap="$(grep -nF 'zensu_full_suite_policy_node "zensu-log.sh --tdd-begin" snapshot' "$src" 2>/dev/null | head -1 | cut -d: -f1)"
  [ -n "$snap" ] && [ "$snap" -gt "$arm" ] && [ "$snap" -lt "$end" ] || return 1
  for pat in 'zensu_external_review_wait_reset "$session_val"' '_zensu_review_gate_reset "--tdd-begin" "$session_val"' 'zensu_stop_background_wait_reset "$session_val"'; do
    line="$(awk -v s="$arm" -v e="$end" -v p="$pat" 'NR>s && NR<e && index($0, p){print NR; exit}' "$src")"
    [ -n "$line" ] && [ "$line" -lt "$snap" ] || return 1
  done
}
if c28_holds "$LOG"; then
  check "C28 the --tdd-begin snapshot, which may wait on the network, runs after the three local resets of the success arm" PASS
else
  check "C28 the --tdd-begin snapshot, which may wait on the network, runs after the three local resets of the success arm" FAIL
fi
C28_MUT="$WORK/c28-mutant.sh"
node -e '
const fs = require("fs");
const [src, out] = process.argv.slice(1);
const lines = fs.readFileSync(src, "utf8").split("\n");
const arm = lines.findIndex((l) => l.includes("if [ \"$tdd_begin_rc\" -eq 0 ]"));
const start = lines.findIndex((l, i) => i > arm && l.includes("zensu_full_suite_policy_node \"zensu-log.sh --tdd-begin\" snapshot"));
const reset = lines.findIndex((l, i) => i > arm && l.includes("zensu_external_review_wait_reset \"$session_val\""));
if (arm < 0 || start < 0 || reset < 0 || reset > start) process.exit(1);
const block = lines.splice(start, 4);
lines.splice(reset, 0, ...block);
fs.writeFileSync(out, lines.join("\n"));
' "$LOG" "$C28_MUT" 2>/dev/null
if [ -s "$C28_MUT" ] && grep -qF 'zensu_full_suite_policy_node "zensu-log.sh --tdd-begin" snapshot' "$C28_MUT" && ! c28_holds "$C28_MUT"; then
  check "C28-mut the same predicate rejects a snapshot call moved above the resets" PASS
else
  check "C28-mut the same predicate rejects a snapshot call moved above the resets" FAIL
fi

unset CI GITHUB_ACTIONS GITLAB_CI TF_BUILD BUILDKITE ZENSU_VCS_REMOTE CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_FULL_SUITE_GATE ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE 2>/dev/null || true
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{"evidence":{"fullSuiteCommand":"echo full-suite-ok"}}\n' > "$ZENSU_CONFIG"
source "$TDD_LIB"

mkdir -p "$WORK/bin"
FIXTURE_DIR="$WORK/bin" GH_STUB_LIB="$PLUGIN_DIR/tests/structure/fixtures/gh-api-stub.js" node <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.env.FIXTURE_DIR;
const repo = 'acme/app';
const created = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
const map = {
  [`repos/${repo}`]: { default_branch: 'main', fork: false },
  [`repos/${repo}/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=20`]: { workflow_runs: [{ id: 7, conclusion: 'failure', created_at: created }] },
  [`repos/${repo}/actions/runs/7/jobs?per_page=100`]: { jobs: [{ name: 'test', conclusion: 'failure', steps: [{ name: 'Set up job' }, { name: 'Run npm test' }] }] },
  [`repos/${repo}/branches/main`]: { protection: { required_status_checks: { enforcement_level: 'off', contexts: [] } } },
  [`repos/${repo}/rules/branches/main`]: [],
};
const fixture = path.join(dir, 'fixture.json');
const calls = path.join(dir, 'calls.log');
fs.writeFileSync(fixture, JSON.stringify(map));
const stub = require(process.env.GH_STUB_LIB).writeGhStub(dir, fixture, calls);
fs.writeFileSync(path.join(dir, 'gh-stub-env.json'), JSON.stringify(stub.env));
NODE
GH_STUB_NODE_OPTIONS="$(node -e 'process.stdout.write(require(process.argv[1]).NODE_OPTIONS || "")' "$WORK/bin/gh-stub-env.json")"
[ -z "$GH_STUB_NODE_OPTIONS" ] || export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$GH_STUB_NODE_OPTIONS"
export PATH="$WORK/bin:$PATH"
CALLS="$WORK/bin/calls.log"

PROJ="$WORK/project"
BARE="$WORK/bare"
mkdir -p "$PROJ/.github/workflows" "$BARE"
for repo in "$PROJ" "$BARE"; do
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.invalid
  git -C "$repo" config user.name tester
  printf '.zensu/\n.session-control-test/\n' > "$repo/.gitignore"
  printf 'baseline\n' > "$repo/tracked.txt"
done
cat > "$PROJ/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
jobs:
  test:
    name: test
    runs-on: ubuntu-latest
    steps:
      - run: npm test
YAML
for repo in "$PROJ" "$BARE"; do
  git -C "$repo" add -A
  git -C "$repo" -c commit.gpgsign=false commit -qm baseline
done
git -C "$PROJ" remote add origin https://github.com/acme/app.git

bind() {
  export CLAUDE_PROJECT_DIR="$2"
  cd "$2" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$1"
}

completion() {
  SID_VALUE="$1" TICKET="$TICKET" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID_VALUE
    }));
  '
}

arm() {
  local sid="$1"
  bash "$LOG" --tdd-begin >"$WORK/begin.out" 2>"$WORK/begin.err" || return 1
  bash "$LOG" --tdd-complete >/dev/null 2>&1 || return 1
  TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
  [ -n "$TICKET" ] || return 1
  completion "$sid" | bash "$POSTREV" >"$WORK/postrev.json" 2>/dev/null
  bash "$LOG" --code-review-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1 || return 1
  SF="$(tdd_state_file "$sid")"
}

directive() {
  node -e '
    let text = "";
    process.stdin.on("data", (chunk) => { text += chunk; }).on("end", () => {
      try {
        const parsed = JSON.parse(text);
        process.stdout.write(String((parsed.hookSpecificOutput && parsed.hookSpecificOutput.additionalContext) || ""));
      } catch {
        process.stdout.write("");
      }
    });
  ' <"$WORK/postrev.json"
}

chain_done() {
  bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"
}

done_flag() {
  tdd_chain_done "$SF" 2>/dev/null
}

records() {
  ls "$CLAUDE_PLUGIN_DATA/evidence-run/v1/records/${ZENSU_SESSION_KEY:-missing}" 2>/dev/null | grep -c '\.json$'
}

ERR() { cat "$WORK/err" 2>/dev/null; }

bind "fsci-policy" "$PROJ" || { check "C3 bind the policy session" FAIL; finish; exit 1; }

OUT="$(bash "$LOG" --full-suite-policy 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$CALLS" ] \
  && printf '%s\n' "$OUT" | grep -q '^full suite: local | no verified CI pull-request pipeline runs the full suite: .*cached yet.* | decided by: default$'; then
  check "C3 without a cached verification the policy stays local, offline, and says why" PASS
else
  check "C3 without a cached verification the policy stays local, offline, and says why (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

OUT="$(bash "$LOG" --full-suite-policy --refresh 2>&1)"; RC=$?
LINE1="$(printf '%s\n' "$OUT" | sed -n 1p)"
LINE2="$(printf '%s\n' "$OUT" | sed -n 2p)"
if [ "$RC" -eq 0 ] && [ -s "$CALLS" ] \
  && printf '%s' "$LINE1" | grep -q "^full suite: ask | candidate CI: \.github/workflows/ci\.yml, job \"test\" runs 'npm test' | last pull-request run 2 h ago (failure) | merge-blocking: no | conditions: none found | verified [0-9]* min ago | local full suite: 'echo full-suite-ok'$" \
  && printf '%s' "$LINE2" | grep -qF "Repository (this clone, every worktree): CLAUDE_PLUGIN_DATA=" \
  && printf '%s' "$LINE2" | grep -qF "zensu-full-suite.sh' --ci --repo | this session only: " \
  && printf '%s' "$LINE2" | grep -qF "zensu-full-suite.sh' --local --session"; then
  check "C4 a refresh verifies a red pull-request run and asks once with the three rendered answers" PASS
else
  check "C4 a refresh verifies a red pull-request run and asks once with the three rendered answers (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

OUT="$(CI=true bash "$LOG" --full-suite-policy 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'full suite: local | this process runs inside a CI pipeline, which is where the full suite runs | decided by: default'; then
  check "C5 a process inside CI never defers the full suite" PASS
else
  check "C5 a process inside CI never defers the full suite (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

bash "$HELPER" --ci >/dev/null 2>&1; RC_A=$?
bash "$HELPER" --status --ci >/dev/null 2>&1; RC_B=$?
bash "$HELPER" --ci --session --job 'test' >/dev/null 2>&1; RC_C=$?
bash "$HELPER" --ci --repo --refresh >/dev/null 2>&1; RC_D=$?
if [ "$RC_A" -eq 2 ] && [ "$RC_B" -eq 2 ] && [ "$RC_C" -eq 2 ] && [ "$RC_D" -eq 2 ]; then
  check "C6 the helper refuses incomplete and mixed verbs as usage errors" PASS
else
  check "C6 the helper refuses incomplete and mixed verbs as usage errors ($RC_A/$RC_B/$RC_C/$RC_D)" FAIL
fi

OUT="$(bash "$HELPER" --status 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^full suite: ask | ' \
  && printf '%s\n' "$OUT" | grep -qF 'full suite sources: session marker none | this clone none | config evidence.fullSuiteRunner unset'; then
  check "C7 --status reports the policy and every source" PASS
else
  check "C7 --status reports the policy and every source (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

bind "fsci-session" "$PROJ" || { check "C8 bind the session-choice session" FAIL; finish; exit 1; }
OUT="$(bash "$HELPER" --ci --session 2>&1)"; RC=$?
MARKER="$PROJ/.zensu/state/full-suite-${ZENSU_SESSION_KEY:-missing}.json"
if [ "$RC" -eq 0 ] && grep -q '"runner":"ci"' "$MARKER" 2>/dev/null \
  && printf '%s\n' "$OUT" | grep -qF 'full-suite: ci for this session only; later sessions ask again' \
  && printf '%s\n' "$OUT" | grep -q '^full suite: ci | CI: \.github/workflows/ci\.yml, job "test" runs .* | decided by: session marker$' \
  && printf '%s\n' "$OUT" | grep -qF 'CI runs the suite when a pull request against main is opened or updated | deactivate: /zensu:full-suite --local --repo (this clone, every worktree) or /zensu:full-suite --local --session (this session only)'; then
  check "C8 --ci --session writes the session marker and names how to deactivate" PASS
else
  check "C8 --ci --session writes the session marker and names how to deactivate (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

if arm "fsci-session"; then
  SNAPSHOT="$CLAUDE_PLUGIN_DATA/ci-contract/v1/snapshots/${ZENSU_SESSION_KEY:-missing}.json"
  if node -e '
    const s = require(process.argv[1]);
    process.exit(s.runner === "ci" && s.decidedBy === "session marker" ? 0 : 1);
  ' "$SNAPSHOT" 2>/dev/null && ! grep -q 'FULL SUITE SNAPSHOT UNAVAILABLE' "$WORK/begin.err" \
    && grep -qx 'full suite: ci | this chain began with the CI runner: \.github/workflows/ci\.yml, job "test" runs its full suite when a pull request against main is opened or updated | decided by: session marker' "$WORK/begin.out"; then
    check "C9 --tdd-begin records the chain's CI runner in a snapshot" PASS
  else
    check "C9 --tdd-begin records the chain's CI runner in a snapshot" FAIL
    cat "$WORK/begin.err"
  fi
  CHAIN_OUT="$(bash "$LOG" --full-suite-policy --chain 2>&1)"
  if printf '%s\n' "$CHAIN_OUT" | head -n 1 | grep -q '^full suite: ci | .* | decided by: session marker$'; then
    check "C27b --full-suite-policy --chain answers ci for a chain that began with the CI runner" PASS
  else
    check "C27b --full-suite-policy --chain answers ci for a chain that began with the CI runner" FAIL
    printf '%s\n' "$CHAIN_OUT"
  fi

  DIRECTIVE="$(directive)"
  if printf '%s' "$DIRECTIVE" | grep -qF -- "--evidence-run --scope scoped --if-stale --cmd '<the Phase 6 affected-suite command>'" \
    && printf '%s' "$DIRECTIVE" | grep -qF 'so do NOT run --scope full' \
    && printf '%s' "$DIRECTIVE" | grep -qF -- '--code-review-done --claimed-review-ticket' \
    && printf '%s' "$DIRECTIVE" | grep -qF "re-run this round's OWN scoped suites — this chain never runs the full suite locally, because CI runs it" \
    && ! printf '%s' "$DIRECTIVE" | grep -qF -- '--evidence-run --scope full --if-stale'; then
    check "C10 the post-review directive of a CI chain re-runs only scoped suites" PASS
  else
    check "C10 the post-review directive of a CI chain re-runs only scoped suites" FAIL
    printf '%s\n' "$DIRECTIVE" | head -c 4000; echo
  fi

  BEFORE="$(records)"
  bash "$LOG" --evidence-run --scope full >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 2 ] && [ "$(records)" = "$BEFORE" ] \
    && grep -qF 'not a suite failure' "$WORK/err" \
    && grep -q '^FULL SUITE — CI contract | CI: \.github/workflows/ci\.yml, job "test" ' "$WORK/err"; then
    check "C11 a full run in a CI chain is refused without a record and names the contract" PASS
  else
    check "C11 a full run in a CI chain is refused without a record and names the contract (rc=$RC)" FAIL
    ERR
  fi

  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -q "^FULL SUITE — missing | .* | run: CLAUDE_PLUGIN_DATA=.* --evidence-run --scope scoped --cmd '<the tests affected by this change>'$" "$WORK/err"; then
    check "C12 a CI chain without any local test run refuses with a scoped remedy" PASS
  else
    check "C12 a CI chain without any local test run refuses with a scoped remedy (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi

  bash "$LOG" --evidence-run --scope scoped --cmd 'echo affected-ok' >/dev/null 2>&1
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -q '^FULL SUITE — deferred-ci | the newest run of each local test command on the current tree [0-9a-f]\{12\} exited 0 (1 command(s), newest record er1_.*CI runs it when a pull request against main is opened or updated | cmd: echo affected-ok | gate: required$' "$WORK/err" \
    && grep -q '^FULL SUITE — CI contract | CI: \.github/workflows/ci\.yml, job "test" runs '"'"'npm test'"'"' | .* | decided by: session marker$' "$WORK/err"; then
    check "C13 a green scoped run closes the CI chain as deferred-ci and names the contract" PASS
  else
    check "C13 a green scoped run closes the CI chain as deferred-ci and names the contract (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "C9 arm a ticket-bound CI chain" FAIL
  cat "$WORK/begin.err" 2>/dev/null
fi

bind "fsci-upgrade" "$PROJ" || { check "C14 bind the upgrade session" FAIL; finish; exit 1; }
if arm "fsci-upgrade"; then
  BEGIN_LINES="$(grep -c '' "$WORK/begin.out")"
  BEGIN_MODE="$(grep -cxE 'mode: (vanilla|strict)' "$WORK/begin.out")"
  bash "$HELPER" --ci --session >/dev/null 2>&1
  CHAIN_OUT="$(bash "$LOG" --full-suite-policy --chain 2>&1)"
  POLICY_OUT="$(bash "$LOG" --full-suite-policy 2>&1)"
  if [ "$CHAIN_OUT" = 'full suite: local | this chain began with the local runner; a switch to CI takes effect with the next chain | decided by: chain begin' ] \
    && printf '%s\n' "$POLICY_OUT" | grep -q '^full suite: ci | '; then
    check "C27 --full-suite-policy --chain answers with the runner the chain began with, not with the cache" PASS
  else
    check "C27 --full-suite-policy --chain answers with the runner the chain began with, not with the cache" FAIL
    printf '%s\n' "$CHAIN_OUT" "$POLICY_OUT"
  fi
  bash "$LOG" --evidence-run --scope scoped --cmd 'echo affected-ok' >/dev/null 2>&1
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && [ "$BEGIN_LINES" = 1 ] && [ "$BEGIN_MODE" = 1 ] \
    && grep -qF 'FULL SUITE — local runner | this chain began with the local runner; a switch to CI takes effect with the next chain | decided by: chain begin' "$WORK/err" \
    && grep -q '^FULL SUITE — missing | ' "$WORK/err"; then
    check "C14 a switch to CI in the middle of a chain never relaxes that chain's terminus" PASS
  else
    check "C14 a switch to CI in the middle of a chain never relaxes that chain's terminus (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "C14 arm a ticket-bound chain" FAIL
fi

bind "fsci-downgrade" "$PROJ" || { check "C15 bind the downgrade session" FAIL; finish; exit 1; }
bash "$HELPER" --ci --session >/dev/null 2>&1
if arm "fsci-downgrade"; then
  bash "$HELPER" --local --session >/dev/null 2>&1
  bash "$LOG" --evidence-run --scope scoped --cmd 'echo affected-ok' >/dev/null 2>&1
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && grep -q '^FULL SUITE — missing | ' "$WORK/err"; then
    check "C15 a switch to local in the middle of a chain applies at once" PASS
  else
    check "C15 a switch to local in the middle of a chain applies at once (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  bash "$LOG" --evidence-run --scope full >/dev/null 2>&1; RC_RUN=$?
  chain_done; RC=$?
  if [ "$RC_RUN" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && grep -q '^FULL SUITE — pass | ' "$WORK/err"; then
    check "C16 the local full run is then allowed and closes the chain" PASS
  else
    check "C16 the local full run is then allowed and closes the chain (run=$RC_RUN rc=$RC)" FAIL
    ERR
  fi
else
  check "C15 arm a ticket-bound chain" FAIL
fi

bind "fsci-local-flag" "$PROJ" || { check "C17 bind the --local session" FAIL; finish; exit 1; }
bash "$HELPER" --ci --session >/dev/null 2>&1
if arm "fsci-local-flag"; then
  bash "$LOG" --evidence-run --scope full --local >/dev/null 2>&1; RC_RUN=$?
  chain_done; RC=$?
  if [ "$RC_RUN" -eq 0 ] && [ "$RC" -eq 0 ] && grep -q '^FULL SUITE — pass | a local full-suite run exited 0 on the current tree' "$WORK/err"; then
    check "C17 --local runs the full suite in a CI chain and the terminus reads it as pass" PASS
  else
    check "C17 --local runs the full suite in a CI chain and the terminus reads it as pass (run=$RC_RUN rc=$RC)" FAIL
    ERR
  fi
else
  check "C17 arm a ticket-bound chain" FAIL
fi

bind "fsci-repo" "$PROJ" || { check "C18 bind the repo-choice session" FAIL; finish; exit 1; }
OUT="$(bash "$HELPER" --ci --repo 2>&1)"; RC=$?
POLICY="$(bash "$LOG" --full-suite-policy 2>&1)"
if [ "$RC" -eq 0 ] \
  && printf '%s\n' "$OUT" | grep -qF 'full-suite: ci for this clone (every worktree) — .github/workflows/ci.yml, job "test"; later chains do not ask again' \
  && printf '%s\n' "$OUT" | grep -qF 'full-suite: deactivate with /zensu:full-suite --local --repo' \
  && printf '%s\n' "$POLICY" | grep -q '^full suite: ci | .* | decided by: this clone$' \
  && printf '%s\n' "$POLICY" | grep -qF '| deactivate: /zensu:full-suite --local --repo'; then
  check "C18 --ci --repo records the clone choice and every later chain names the deactivation" PASS
else
  check "C18 --ci --repo records the clone choice and every later chain names the deactivation (rc=$RC)" FAIL
  printf '%s\n' "$OUT" "$POLICY"
fi

OUT="$(bash "$HELPER" --local --repo 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'full suite: local | the record for this clone chose local full-suite runs | decided by: this clone'; then
  check "C19 --local --repo switches the clone back to local runs" PASS
else
  check "C19 --local --repo switches the clone back to local runs (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

OUT="$(bash "$HELPER" --auto --repo 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'full-suite: the choice recorded for this clone was removed' \
  && printf '%s\n' "$OUT" | grep -q '^full suite: ask | '; then
  check "C20 --auto --repo removes the clone choice so the question returns" PASS
else
  check "C20 --auto --repo removes the clone choice so the question returns (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

bind "fsci-bare" "$BARE" || { check "C21 bind the bare session" FAIL; finish; exit 1; }
OUT="$(bash "$HELPER" --ci --repo 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'refusing to record CI full-suite runs for this clone — ' \
  && [ -z "$(ls "$CLAUDE_PLUGIN_DATA/ci-contract/v1/clones" 2>/dev/null)" ]; then
  check "C21 --ci --repo refuses without a verified pipeline and records nothing" PASS
else
  check "C21 --ci --repo refuses without a verified pipeline and records nothing (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

snapshot_is() {
  node -e '
    const s = require(process.argv[1]);
    process.exit(s.runner === process.argv[2] && s.decidedBy === process.argv[3] ? 0 : 1);
  ' "$CLAUDE_PLUGIN_DATA/ci-contract/v1/snapshots/${ZENSU_SESSION_KEY:-missing}.json" "$1" "$2" 2>/dev/null
}

call_count() {
  if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi
}

CI_BEGIN_LINE='full suite: ci | this chain began with the CI runner: .github/workflows/ci.yml, job "test" runs its full suite when a pull request against main is opened or updated | decided by: this clone'
WT_B=""
if git -C "$PROJ" worktree add -q "$WORK/wt-b" -b wt-b >/dev/null 2>&1; then
  WT_B="$(cd -P "$WORK/wt-b" 2>/dev/null && pwd -P)"
fi
if [ -n "$WT_B" ] \
  && printf '# the workflow of worktree b\n' >> "$WT_B/.github/workflows/ci.yml" \
  && git -C "$WT_B" add -A && git -C "$WT_B" -c commit.gpgsign=false commit -qm 'worktree b workflow' \
  && git -C "$WT_B" checkout -q -b fsci-older-ci \
  && printf '# an older branch\n' >> "$WT_B/.github/workflows/ci.yml" \
  && git -C "$WT_B" add -A && git -C "$WT_B" -c commit.gpgsign=false commit -qm 'older workflow' \
  && git -C "$WT_B" checkout -q wt-b; then
  bind "fsci-wt-a" "$PROJ" || { check "C24 bind worktree A" FAIL; finish; exit 1; }
  bash "$LOG" --full-suite-policy --refresh >/dev/null 2>&1
  bash "$HELPER" --ci --repo >/dev/null 2>&1; RC_REPO=$?
  bind "fsci-wt-b" "$WT_B" || { check "C24 bind worktree B" FAIL; finish; exit 1; }
  BEFORE_B="$(call_count)"
  OUT_B="$(bash "$LOG" --full-suite-policy --refresh 2>&1)"
  AFTER_B="$(call_count)"
  bind "fsci-wt-a-begin" "$PROJ" || { check "C24 bind worktree A again" FAIL; finish; exit 1; }
  OUT_A="$(bash "$LOG" --full-suite-policy 2>&1)"
  bash "$LOG" --tdd-begin >"$WORK/begin.out" 2>"$WORK/begin.err"; RC_BEGIN=$?
  if [ "$RC_REPO" -eq 0 ] && [ "$RC_BEGIN" -eq 0 ] && [ "$AFTER_B" -gt "$BEFORE_B" ] \
    && printf '%s\n' "$OUT_B" | grep -q '^full suite: ci | .* | decided by: this clone$' \
    && printf '%s\n' "$OUT_A" | grep -q '^full suite: ci | .* | decided by: this clone$' \
    && snapshot_is ci 'this clone' \
    && grep -qxF "$CI_BEGIN_LINE" "$WORK/begin.out" \
    && ! grep -q 'FULL SUITE SNAPSHOT UNAVAILABLE' "$WORK/begin.err"; then
    check "C24 a worktree whose workflow file differs verifies its own version and leaves the other worktree's proof and snapshot ci" PASS
  else
    check "C24 a worktree whose workflow file differs verifies its own version and leaves the other worktree's proof and snapshot ci (repo=$RC_REPO begin=$RC_BEGIN calls=$BEFORE_B/$AFTER_B)" FAIL
    printf '%s\n' "$OUT_B" "$OUT_A"
    cat "$WORK/begin.out" "$WORK/begin.err"
  fi

  cp "$WORK/bin/fixture.json" "$WORK/fixture.healthy.json"
  bind "fsci-switch-fail" "$WT_B" || { check "C25 bind the switching session" FAIL; finish; exit 1; }
  OUT="$(bash "$LOG" --full-suite-policy --refresh 2>&1)"
  git -C "$WT_B" checkout -q fsci-older-ci
  printf '{"repos/acme/app":{"__fail":"error connecting to api.github.com"}}\n' > "$WORK/bin/fixture.json"
  bash "$LOG" --tdd-begin >"$WORK/begin.out" 2>"$WORK/begin.err"; RC_BEGIN=$?
  cp "$WORK/fixture.healthy.json" "$WORK/bin/fixture.json"
  if [ "$RC_BEGIN" -eq 0 ] \
    && printf '%s\n' "$OUT" | grep -q '^full suite: ci | .* | decided by: this clone$' \
    && snapshot_is local 'this clone' \
    && grep -qxF 'full suite: local | the record for this clone chose CI full-suite runs, but the CI pull-request pipeline is not verified: gh api repos/acme/app failed: error connecting to api.github.com | decided by: this clone | this chain began with the local runner, so it closes only on a local full-suite run, whatever --full-suite-policy printed before' "$WORK/begin.out"; then
    check "C25 a branch switch after the refresh whose new workflow cannot be verified at --tdd-begin snapshots local and prints why" PASS
  else
    check "C25 a branch switch after the refresh whose new workflow cannot be verified at --tdd-begin snapshots local and prints why (begin=$RC_BEGIN)" FAIL
    printf '%s\n' "$OUT"
    cat "$WORK/begin.out" "$WORK/begin.err"
  fi

  git -C "$WT_B" checkout -q wt-b
  bind "fsci-switch-ok" "$WT_B" || { check "C26 bind the switching session" FAIL; finish; exit 1; }
  OUT="$(bash "$LOG" --full-suite-policy --refresh 2>&1)"
  git -C "$WT_B" checkout -q fsci-older-ci
  BEFORE_BEGIN="$(call_count)"
  bash "$LOG" --tdd-begin >"$WORK/begin.out" 2>"$WORK/begin.err"; RC_BEGIN=$?
  AFTER_BEGIN="$(call_count)"
  if [ "$RC_BEGIN" -eq 0 ] && [ "$AFTER_BEGIN" -gt "$BEFORE_BEGIN" ] \
    && printf '%s\n' "$OUT" | grep -q '^full suite: ci | .* | decided by: this clone$' \
    && snapshot_is ci 'this clone' \
    && grep -qxF "$CI_BEGIN_LINE" "$WORK/begin.out"; then
    check "C26 a branch switch after the refresh refreshes once at --tdd-begin and keeps the chain ci" PASS
  else
    check "C26 a branch switch after the refresh refreshes once at --tdd-begin and keeps the chain ci (begin=$RC_BEGIN calls=$BEFORE_BEGIN/$AFTER_BEGIN)" FAIL
    printf '%s\n' "$OUT"
    cat "$WORK/begin.out" "$WORK/begin.err"
  fi
  git -C "$WT_B" checkout -q wt-b
  bash "$HELPER" --auto --repo >/dev/null 2>&1
else
  check "C24 prepare a second worktree with another workflow file" FAIL
fi

max_rounds() {
  local sid="$1" round
  bind "$sid" "$PROJ" || return 1
  bash "$HELPER" --ci --session >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-begin >"$WORK/begin.out" 2>"$WORK/begin.err" || return 1
  bash "$LOG" --tdd-complete >/dev/null 2>&1 || return 1
  for round in 1 2; do
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    [ -n "$TICKET" ] || return 1
    completion "$sid" | bash "$POSTREV" >"$WORK/postrev.json" 2>/dev/null
  done
}

ZENSU_CONFIG="$WORK/max-rounds.json"
printf '{"evidence":{"fullSuiteCommand":"echo full-suite-ok"},"hooks":{"autoFix":true,"autoFixMaxRounds":1}}\n' > "$ZENSU_CONFIG"
if max_rounds "fsci-max-rounds"; then
  DIRECTIVE="$(directive)"
  if printf '%s' "$DIRECTIVE" | grep -qF 'FIRST, re-run the affected-suite command of Phase 6 step 1 through the evidence runner' \
    && printf '%s' "$DIRECTIVE" | grep -qF -- "--evidence-run --scope scoped --if-stale --cmd '<the Phase 6 affected-suite command>'" \
    && printf '%s' "$DIRECTIVE" | grep -qF "THEN your next action MUST be the Skill tool with skill='zensu:self-review'" \
    && ! printf '%s' "$DIRECTIVE" | grep -qF -- '--evidence-run --scope full --if-stale'; then
    check "C22 the max-rounds hand-off of a CI chain re-runs the affected suite before the self-review" PASS
  else
    check "C22 the max-rounds hand-off of a CI chain re-runs the affected suite before the self-review" FAIL
    printf '%s\n' "$DIRECTIVE" | head -c 4000; echo
  fi
else
  check "C22 drive a CI chain to the max-rounds hand-off" FAIL
fi

printf '{"evidence":{"fullSuiteCommand":"echo full-suite-ok"},"hooks":{"autoFix":true,"selfReview":false,"autoFixMaxRounds":1}}\n' > "$ZENSU_CONFIG"
if max_rounds "fsci-max-rounds-off"; then
  DIRECTIVE="$(directive)"
  if printf '%s' "$DIRECTIVE" | grep -qF 'Before you reply, re-run the affected-suite command of Phase 6 step 1 through the evidence runner' \
    && printf '%s' "$DIRECTIVE" | grep -qF -- "--evidence-run --scope scoped --if-stale --cmd '<the Phase 6 affected-suite command>'" \
    && printf '%s' "$DIRECTIVE" | grep -qF 'this run is the only local test measurement of the tree that ships, and CI runs the full suite' \
    && ! printf '%s' "$DIRECTIVE" | grep -qF -- '--evidence-run --scope full --if-stale'; then
    check "C23 the max-rounds close of a CI chain without self-review re-runs the affected suite before the reply" PASS
  else
    check "C23 the max-rounds close of a CI chain without self-review re-runs the affected suite before the reply" FAIL
    printf '%s\n' "$DIRECTIVE" | head -c 4000; echo
  fi
else
  check "C23 drive a CI chain without self-review to the max-rounds close" FAIL
fi

CI_STANDALONE="$(directive)"
source "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
WT_CI=""
printf '.claude/worktrees/\n' >> "$PROJ/.gitignore"
if git -C "$PROJ" add .gitignore && git -C "$PROJ" -c commit.gpgsign=false commit -qm 'ignore worktrees' \
  && git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/ci-wt" -b ci-wt >/dev/null 2>&1; then
  WT_CI="$(cd -P "$PROJ/.claude/worktrees/ci-wt" 2>/dev/null && pwd -P)"
fi
WT_CI_NATIVE=""
[ -n "$WT_CI" ] && WT_CI_NATIVE="$(bash "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$WT_CI" 2>/dev/null)"
BOUND_RUN_FILE=""

bound_begin() {
  local sid="$1" run="$2" chain="$3" tree="$4"
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  bind "$sid" "$PROJ" || return 1
  bash "$HELPER" --ci --session >/dev/null 2>&1 || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$PROJ" false true "$tree" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-${run}" PLAN_APPROVED \
    "{\"approvedPlanSha256\":\"$sha\"}" "$PROJ" "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  BEGIN_CALLS_BEFORE="$(call_count)"
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >"$WORK/begin.out" 2>"$WORK/begin.err" || return 1
  BEGIN_CALLS_AFTER="$(call_count)"
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1
}

bound_review() {
  local sid="$1" state ctx
  state="$(tdd_state_file "$ZENSU_SESSION_KEY")" || return 1
  TICKET="$(bash "$LOG" --review-ticket --session "$ZENSU_SESSION_KEY" 2>/dev/null)"
  [ -n "$TICKET" ] || return 1
  ctx="$(tdd_autopilot_context "$state" "$ZENSU_SESSION_KEY")" || return 1
  SID_VALUE="$sid" TICKET="$TICKET" CONTEXT="$ctx" node -e '
    const c = JSON.parse(process.env.CONTEXT);
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      session_id: process.env.SID_VALUE,
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nZENSU-DELEGATED-CALLER: autopilot\nAUTOPILOT-BINDING: run=${c.runId} attempt=${c.attempt} chain=${c.chainId}\nAUTOPILOT-STAGE: ${c.returnStage}\nfixture`
      }
    }));
  ' | bash "$POSTREV" >"$WORK/postrev.json" 2>/dev/null
  return 0
}

bound_ci_max_rounds() {
  bound_begin "fsci-bound-wt" fsci_bound_wt_run fsci-bound-wt-chain "$WT_CI" || return 1
  tdd_increment_counter "$ZENSU_SESSION_KEY" reviewRound >/dev/null || return 1
  bound_review "fsci-bound-wt" || return 1
  BOUND_RUN_FILE="$(autopilot_run_file fsci_bound_wt_run "$PROJ")"
}

if [ -n "$WT_CI_NATIVE" ] && bound_ci_max_rounds; then
  DIRECTIVE="$(directive)"
  FLAG23B="$(A="$CI_STANDALONE" B="$DIRECTIVE" W="$WT_CI_NATIVE" node -e '
    const cmd = (s) => { const m = String(s || "").match(/Before you reply, [^\n]*?( --evidence-run [^\n]*? --log <run log>)/); return m ? m[1] : null; };
    const a = cmd(process.env.A), b = cmd(process.env.B);
    if (!a || !b) { process.stdout.write("missing"); process.exit(0); }
    const want = a.replace(" --cmd \x27", " --cmd \x27cd \"" + process.env.W + "\" && ");
    process.stdout.write(want === b ? "equal" : "differ");
  ' 2>/dev/null)"
  if printf '%s' "$DIRECTIVE" | grep -qF "Before you reply, re-run the affected-suite command of Phase 6 step 1 in this chain's work tree through the evidence runner: " \
    && printf '%s' "$DIRECTIVE" | grep -qF -- "--evidence-run --scope scoped --if-stale --cmd 'cd \"$WT_CI_NATIVE\" && <the Phase 6 affected-suite command>' --log <run log>" \
    && ! printf '%s' "$DIRECTIVE" | grep -qF -- '--evidence-run --scope full' \
    && [ "$FLAG23B" = equal ] \
    && node -e '
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      process.exit(j.stage === "BLOCKED" && j.blocked && j.blocked.code === "TDD_MAX_ROUNDS" ? 0 : 1);
    ' "$BOUND_RUN_FILE" 2>/dev/null; then
    check "C23b the max-rounds close of a bound CI chain in a nested worktree re-runs the shared affected-suite command there, and the outer run is BLOCKED" PASS
  else
    check "C23b the max-rounds close of a bound CI chain in a nested worktree re-runs the shared affected-suite command there, and the outer run is BLOCKED (flag=$FLAG23B)" FAIL
    printf '%s\n' "$DIRECTIVE" | head -c 4000; echo
  fi
else
  check "C23b drive a bound CI chain in a nested worktree to the max-rounds close without self-review" FAIL
fi

ZENSU_CONFIG="$WORK/config.json"
ANCHOR_BRANCH="$(git -C "$PROJ" rev-parse --abbrev-ref HEAD 2>/dev/null)"
PUSH_ONLY_YAML=$'name: CI\non:\n  push:\n    branches: [main]\njobs:\n  test:\n    name: test\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm test\n'
PUSH_ONLY_REASON='the session marker chose CI full-suite runs, but the CI pull-request pipeline is not verified: no workflow under .github/workflows triggers on pull_request'
CI_SESSION_BEGIN='full suite: ci | this chain began with the CI runner: .github/workflows/ci.yml, job "test" runs its full suite when a pull request against main is opened or updated | decided by: session marker'

nested_worktree() {
  local name="$1" workflow="$2" tree
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/$name" -b "$name" >/dev/null 2>&1 || return 1
  tree="$(cd -P "$PROJ/.claude/worktrees/$name" 2>/dev/null && pwd -P)" || return 1
  printf '%s' "$workflow" > "$tree/.github/workflows/ci.yml" || return 1
  git -C "$tree" add .github/workflows/ci.yml && git -C "$tree" -c commit.gpgsign=false commit -qm "$name workflow" >/dev/null 2>&1 || return 1
  printf '%s\n' "$tree"
}

proof_exists() {
  node -e '
    const crypto = require("crypto"), fs = require("fs"), path = require("path");
    const [data, tree] = process.argv.slice(1);
    const sha = (text) => crypto.createHash("sha256").update(text).digest("hex");
    const name = `${sha("acme/app\n.github/workflows/ci.yml").slice(0, 40)}.${sha(fs.readFileSync(path.join(tree, ".github", "workflows", "ci.yml")))}.${sha("test").slice(0, 16)}.json`;
    process.exit(fs.existsSync(path.join(data, "ci-contract", "v1", "cache", name)) ? 0 : 1);
  ' "$CLAUDE_PLUGIN_DATA" "$1" 2>/dev/null
}

local_directive() {
  printf '%s' "$1" | grep -qF -- '--evidence-run --scope full --if-stale' \
    && ! printf '%s' "$1" | grep -qF 'so do NOT run --scope full'
}

ci_directive() {
  printf '%s' "$1" | grep -qF -- "--evidence-run --scope scoped --if-stale --cmd '<the Phase 6 affected-suite command>'" \
    && printf '%s' "$1" | grep -qF 'so do NOT run --scope full' \
    && ! printf '%s' "$1" | grep -qF -- '--evidence-run --scope full --if-stale'
}

WT_PUSH="$(nested_worktree ci-push-only "$PUSH_ONLY_YAML")"
if [ -n "$WT_PUSH" ] && bound_begin "fsci-bound-push" fsci_bound_push_run fsci-bound-push-chain "$WT_PUSH"; then
  if snapshot_is local 'session marker' \
    && grep -qxF "full suite: local | $PUSH_ONLY_REASON | decided by: session marker | this chain began with the local runner, so it closes only on a local full-suite run, whatever --full-suite-policy printed before" "$WORK/begin.out"; then
    check "C29 a bound chain whose nested worktree's workflow does not trigger on pull_request begins local, although the anchor's workflow is verified" PASS
  else
    check "C29 a bound chain whose nested worktree's workflow does not trigger on pull_request begins local, although the anchor's workflow is verified" FAIL
    cat "$WORK/begin.out" "$WORK/begin.err"
  fi
  CHAIN_OUT="$(bash "$LOG" --full-suite-policy --chain 2>&1)"
  if [ "$CHAIN_OUT" = "full suite: local | $PUSH_ONLY_REASON | decided by: session marker" ]; then
    check "C29b --full-suite-policy --chain judges that chain by its worktree's workflow file" PASS
  else
    check "C29b --full-suite-policy --chain judges that chain by its worktree's workflow file" FAIL
    printf '%s\n' "$CHAIN_OUT"
  fi
  if bound_review "fsci-bound-push"; then
    DIRECTIVE="$(directive)"
    if local_directive "$DIRECTIVE"; then
      check "C29c the post-review directive of that chain keeps the local full suite" PASS
    else
      check "C29c the post-review directive of that chain keeps the local full suite" FAIL
      printf '%s\n' "$DIRECTIVE" | head -c 4000; echo
    fi
  else
    check "C29c drive the review of that chain" FAIL
  fi
  BEFORE="$(records)"
  bash "$LOG" --evidence-run --scope full >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(records)" -gt "$BEFORE" ] && ! grep -qF 'not a suite failure' "$WORK/err"; then
    check "C29d the runner lets that chain run its full suite locally" PASS
  else
    check "C29d the runner lets that chain run its full suite locally (rc=$RC)" FAIL
    ERR
  fi
else
  check "C29 prepare a bound chain in a nested worktree whose workflow does not trigger on pull_request" FAIL
  cat "$WORK/begin.err" 2>/dev/null
fi

DIFF_YAML="$(cat "$PROJ/.github/workflows/ci.yml")"$'\n# the workflow of the chain branch\n'
WT_DIFF="$(nested_worktree ci-differs "$DIFF_YAML")"
if [ -n "$WT_DIFF" ] && bound_begin "fsci-bound-diff" fsci_bound_diff_run fsci-bound-diff-chain "$WT_DIFF"; then
  if [ "$BEGIN_CALLS_AFTER" -gt "$BEGIN_CALLS_BEFORE" ] && proof_exists "$WT_DIFF" \
    && snapshot_is ci 'session marker' && grep -qxF "$CI_SESSION_BEGIN" "$WORK/begin.out"; then
    check "C30 a bound chain whose nested worktree's workflow differs verifies that version at --tdd-begin and begins ci" PASS
  else
    check "C30 a bound chain whose nested worktree's workflow differs verifies that version at --tdd-begin and begins ci (calls=$BEGIN_CALLS_BEFORE/$BEGIN_CALLS_AFTER)" FAIL
    cat "$WORK/begin.out" "$WORK/begin.err"
  fi
  SWITCHED=no
  if git -C "$PROJ" checkout -q -b fsci-anchor-push-only \
    && printf '%s' "$PUSH_ONLY_YAML" > "$PROJ/.github/workflows/ci.yml" \
    && git -C "$PROJ" add .github/workflows/ci.yml \
    && git -C "$PROJ" -c commit.gpgsign=false commit -qm 'anchor push-only workflow' >/dev/null 2>&1; then
    SWITCHED=yes
  fi
  CHAIN_OUT="$(bash "$LOG" --full-suite-policy --chain 2>&1)"
  if [ "$SWITCHED" = yes ] && printf '%s\n' "$CHAIN_OUT" | head -n 1 | grep -q '^full suite: ci | CI: \.github/workflows/ci\.yml, job "test" .* | decided by: session marker$'; then
    check "C30b a branch switch in the anchor checkout in the middle of the chain leaves --full-suite-policy --chain ci" PASS
  else
    check "C30b a branch switch in the anchor checkout in the middle of the chain leaves --full-suite-policy --chain ci (switched=$SWITCHED)" FAIL
    printf '%s\n' "$CHAIN_OUT"
  fi
  if bound_review "fsci-bound-diff"; then
    DIRECTIVE="$(directive)"
    if ci_directive "$DIRECTIVE"; then
      check "C30c after that switch the post-review directive still runs only the affected suite" PASS
    else
      check "C30c after that switch the post-review directive still runs only the affected suite" FAIL
      printf '%s\n' "$DIRECTIVE" | head -c 4000; echo
    fi
  else
    check "C30c drive the review of that chain" FAIL
  fi
  BEFORE="$(records)"
  bash "$LOG" --evidence-run --scope full >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 2 ] && [ "$(records)" = "$BEFORE" ] && grep -qF 'not a suite failure' "$WORK/err"; then
    check "C30d after that switch the runner still refuses a local full run of that chain" PASS
  else
    check "C30d after that switch the runner still refuses a local full run of that chain (rc=$RC)" FAIL
    ERR
  fi
  [ -z "$ANCHOR_BRANCH" ] || git -C "$PROJ" checkout -q "$ANCHOR_BRANCH" >/dev/null 2>&1
else
  check "C30 prepare a bound chain in a nested worktree whose workflow differs from the anchor's" FAIL
  cat "$WORK/begin.err" 2>/dev/null
fi

unit_check_done "C1z every unit file the registry gives this suite was graded"
finish
