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
source "$PLUGIN_DIR/tests/structure/lib-unit-summary.sh"

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

if node --test "$UNIT" >"$WORK/unit.out" 2>&1; then
  check "C1 the unit suite passes (node --test full-suite-ci-v1.test.js)" PASS
else
  check "C1 the unit suite passes (node --test full-suite-ci-v1.test.js)" FAIL
  sed -n '1,80p' "$WORK/unit.out"
fi

UNIT_FLOOR="$(unit_overview_declared "${UNIT##*/}")"
if unit_cases_meet_floor "$WORK/unit.out" "$UNIT_FLOOR"; then
  check "C1a the unit suite registered at least $UNIT_FLOOR passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" PASS
else
  check "C1a the unit suite registered at least ${UNIT_FLOOR:-<no overview row>} passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" FAIL
fi
if C1B="$(unit_overview_check "$UNIT")"; then
  check "C1b the SUITE-OVERVIEW Blocks cell matches what ${UNIT##*/} registers ($UNIT_FLOOR)" PASS
else
  check "C1b $C1B" FAIL
fi

SKILL_OK=PASS
for verb in '--status' '--ci --repo' '--local --repo' '--ci --session'; do
  grep -qF "zensu-full-suite.sh\" $verb" "$SKILL" || SKILL_OK=FAIL
done
for verb in '--local --session' '--auto --session' '--auto --repo'; do
  grep -qF -- "$verb" "$SKILL" || SKILL_OK=FAIL
done
check "C2 the skill renders every helper verb" "$SKILL_OK"

unset CI GITHUB_ACTIONS GITLAB_CI TF_BUILD BUILDKITE ZENSU_VCS_REMOTE CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_FULL_SUITE_GATE ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE 2>/dev/null || true
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{"evidence":{"fullSuiteCommand":"echo full-suite-ok"}}\n' > "$ZENSU_CONFIG"
source "$TDD_LIB"

mkdir -p "$WORK/bin"
FIXTURE_DIR="$WORK/bin" node <<'NODE'
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
fs.writeFileSync(path.join(dir, 'gh'), [
  `#!${process.execPath}`,
  "const fs = require('fs');",
  `const map = JSON.parse(fs.readFileSync(${JSON.stringify(fixture)}, 'utf8'));`,
  'const endpoint = process.argv[3];',
  `fs.appendFileSync(${JSON.stringify(calls)}, endpoint + '\\n');`,
  "if (!Object.prototype.hasOwnProperty.call(map, endpoint)) { process.stderr.write('HTTP 404: Not Found\\n'); process.exit(1); }",
  'process.stdout.write(JSON.stringify(map[endpoint]));',
  '',
].join('\n'), { mode: 0o755 });
NODE
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
  ' "$SNAPSHOT" 2>/dev/null && ! grep -q 'FULL SUITE SNAPSHOT UNAVAILABLE' "$WORK/begin.err"; then
    check "C9 --tdd-begin records the chain's CI runner in a snapshot" PASS
  else
    check "C9 --tdd-begin records the chain's CI runner in a snapshot" FAIL
    cat "$WORK/begin.err"
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
  bash "$HELPER" --ci --session >/dev/null 2>&1
  bash "$LOG" --evidence-run --scope scoped --cmd 'echo affected-ok' >/dev/null 2>&1
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
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

finish
