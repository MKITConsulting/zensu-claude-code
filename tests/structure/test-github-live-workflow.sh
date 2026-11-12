#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIVE="$ROOT/tests/integration/github"
WORKFLOW="$ROOT/.github/workflows/github-live.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
DRIVER="$ROOT/hooks/lib/zensu-vcs.sh"
SPEC="$ROOT/docs/vcs-driver-spec.md"
FAKE_TOKEN=ghs_EXAMPLE_TOKEN_FOR_FIXTURES_ONLY
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}
expect() {
  if [ "$2" = "$3" ]; then
    check "$1" PASS
  else
    check "$1 (got '$2' want '$3')" FAIL
  fi
}
graph_is() {
  printf '%s' "$GRAPH" | KEY="$1" node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => { process.stdout.write(JSON.parse(raw)[process.env.KEY] === true ? "yes" : "no"); });
  '
}
fact() {
  if [ "$(graph_is "$2")" = yes ]; then
    check "$1" PASS
  else
    check "$1" FAIL
  fi
}
finish() {
  echo "----"
  echo "test-github-live-workflow: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
}

for file in "$WORKFLOW" "$RELEASE" "$DRIVER" "$SPEC" "$LIVE/versions.v1.json" "$LIVE/lib.sh" "$LIVE/run.sh" \
  "$LIVE/gh-install.sh" "$LIVE/github-token.sh" "$LIVE/app-token.js" "$LIVE/drift.sh" "$LIVE/test-vcs-github-live.sh"; do
  if [ ! -f "$file" ]; then
    check "W0 ${file#"$ROOT"/} exists" FAIL
    finish
  fi
done
check "W0 the live harness, its workflow and its pins exist" PASS

WORK="$(mktemp -d "${TMPDIR:-/tmp}/github-live-workflow.XXXXXX")"
SERVER=''
cleanup() {
  [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

GRAPH="$(cd "$ROOT" && node - "$WORKFLOW" "$RELEASE" "$LIVE/versions.v1.json" "$SPEC" "$WORK" <<'NODE'
const fs = require('node:fs');
const YAML = require('yaml');
const liveText = fs.readFileSync(process.argv[2], 'utf8');
const releaseText = fs.readFileSync(process.argv[3], 'utf8');
const live = YAML.parse(liveText);
const release = YAML.parse(releaseText);
const pins = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const spec = fs.readFileSync(process.argv[5], 'utf8');
const work = process.argv[6];
const jobs = live.jobs || {};
const rjobs = release.jobs || {};
const steps = (job) => (job && Array.isArray(job.steps) ? job.steps : []);
const runOf = (step) => String((step && step.run) || '');
const needsOf = (job) => [].concat((job && job.needs) || []);
const norm = (value) => String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
const ifOf = (job) => norm(job && job.if);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const has = (object, key) => Boolean(object) && Object.prototype.hasOwnProperty.call(object, key);
const stepNamed = (job, name) => steps(job).find((step) => step.name === name);
const envOf = (step, name) => norm(step && step.env && step.env[name]);
const count = (text, needle) => text.split(needle).length - 1;
const CREDENTIAL = {
  ZENSU_GITHUB_IT_CACHE: '${{ runner.temp }}/github-it',
  ZENSU_GITHUB_IT_APP_ID: '${{ vars.ZENSU_GITHUB_IT_APP_ID }}',
  ZENSU_GITHUB_IT_REPO: '${{ vars.ZENSU_GITHUB_IT_REPO }}',
  ZENSU_GITHUB_IT_APP_KEY: '${{ secrets.ZENSU_GITHUB_IT_APP_KEY }}',
};
const credentialed = (step) => Boolean(step) && Object.entries(CREDENTIAL).every(([key, value]) => envOf(step, key) === value);
const harnessStep = (job) => steps(job).find((step) => runOf(step).includes('tests/integration/github/run.sh'));
const runsHarness = (job, selection) => runOf(harnessStep(job)).includes(`bash tests/integration/github/run.sh --gh ${selection}`);
const checkoutIndex = (job) => steps(job).findIndex((step) => runOf(step).includes('git checkout --detach "$EXPECTED_SHA"'));
const harnessIndex = (job) => steps(job).indexOf(harnessStep(job));
const readOnly = (job) => same(job && job.permissions, { contents: 'read' });
const triggers = live.on || live[true] || {};
const hex = (value, length) => typeof value === 'string' && new RegExp(`^[0-9a-f]{${length}}$`).test(value);
const decide = steps(jobs.scope).find((step) => step.id === 'decide');
const verdict = stepNamed(jobs.result, 'Check the GitHub live verdict');
const liveRun = stepNamed(jobs.live, 'Run the live GitHub suite');
const compare = steps(jobs.drift).find((step) => step.id === 'compare');
const issue = stepNamed(jobs['drift-issue'], 'Open, update or close the drift issue');
const notify = stepNamed(jobs.notify, 'Open or update the tracking issue');
const extracted = { 'scope.sh': decide, 'result.sh': verdict, 'live-run.sh': liveRun, 'compare.sh': compare,
  'drift-issue.sh': issue, 'notify.sh': notify };
for (const [file, step] of Object.entries(extracted)) fs.writeFileSync(`${work}/${file}`, runOf(step));
const driftRuns = steps(jobs.drift).filter((step) => has(step, 'run'));
const driftUses = steps(jobs.drift).filter((step) => has(step, 'uses')).map((step) => String(step.uses).split('@')[0]);
const tokenJobs = Object.entries(jobs)
  .filter(([, job]) => steps(job).some((step) => Object.values(step.env || {}).some((value) => String(value).includes('github.token'))))
  .map(([id]) => id).sort();
const PREPARE_IF = "${{ !cancelled() && !inputs.dry_run && needs.prepare-commit.result == 'success'"
  + " && ((needs.prepare-suite.result == 'success' && needs.prepare-gitlab-live.result == 'success'"
  + " && needs.prepare-github-live.result == 'success')"
  + " || (inputs.skip_test_gate && needs.prepare-suite.result == 'skipped' && needs.prepare-gitlab-live.result == 'skipped'"
  + " && needs.prepare-github-live.result == 'skipped')) }}";
const PUBLISH_IF = "${{ !cancelled() && needs.publish-plan.result == 'success'"
  + " && ((needs.publish-plan.outputs.gate == 'run' && needs.publish-suite.result == 'success'"
  + " && needs.publish-gitlab-live.result == 'success' && needs.publish-github-live.result == 'success')"
  + " || (needs.publish-plan.outputs.gate == 'skipped' && needs.publish-suite.result == 'skipped'"
  + " && needs.publish-gitlab-live.result == 'skipped' && needs.publish-github-live.result == 'skipped')) }}";
const NOTIFY_IF = "always() && github.event_name == 'schedule' && (needs.result.result != 'success'"
  + " || needs.drift.result != 'success' || needs.drift-issue.result != 'success')";
const prepareEvidence = stepNamed(rjobs.prepare, 'Record deterministic exact-commit runtime evidence');
const publishEvidence = stepNamed(rjobs.publish, 'Deterministic exact-main-SHA gate');
const entries = Array.isArray(pins.gh) ? pins.gh : [];
const versions = entries.map((entry) => String(entry && entry.version));
const order = (a, b) => {
  const x = a.split('.').map(Number);
  const y = b.split('.').map(Number);
  for (let i = 0; i < 3; i += 1) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
};
const floor = /The gh floor is ([0-9]+\.[0-9]+\.[0-9]+)/.exec(spec);
process.stdout.write(JSON.stringify({
  extracted: Object.values(extracted).every((step) => runOf(step) !== ''),
  triggers: ['pull_request', 'schedule', 'workflow_dispatch'].every((key) => has(triggers, key))
    && same(Object.keys((triggers.workflow_dispatch && triggers.workflow_dispatch.inputs) || {}), ['gh']),
  permissions: same(live.permissions, { contents: 'read' })
    && ['scope', 'live', 'result', 'drift'].every((id) => Boolean(jobs[id]) && !has(jobs[id], 'permissions'))
    && ['notify', 'drift-issue'].every((id) => same(jobs[id] && jobs[id].permissions, { issues: 'write' })),
  liveGated: same(needsOf(jobs.live), ['scope']) && ifOf(jobs.live) === "needs.scope.outputs.lanes != '[]'"
    && norm(jobs.live && jobs.live.strategy && jobs.live.strategy.matrix && jobs.live.strategy.matrix.lane)
      === '${{ fromJSON(needs.scope.outputs.lanes) }}',
  liveRuns: runOf(liveRun).includes('bash tests/integration/github/run.sh --gh "$selection"') && credentialed(liveRun)
    && envOf(liveRun, 'DISPATCH_GH') === '${{ inputs.gh }}' && envOf(liveRun, 'LANE') === '${{ matrix.lane }}',
  secretsScoped: count(liveText, 'secrets.') === 1 && count(releaseText, 'secrets.ZENSU_GITHUB_IT_APP_KEY') === 2
    && credentialed(harnessStep(rjobs['prepare-github-live'])) && credentialed(harnessStep(rjobs['publish-github-live']))
    && same(tokenJobs, ['drift', 'drift-issue', 'notify']),
  resultWired: ifOf(jobs.result) === 'always()' && same(needsOf(jobs.result), ['scope', 'live']),
  notify: ifOf(jobs.notify) === NOTIFY_IF && same(needsOf(jobs.notify), ['result', 'drift', 'drift-issue'])
    && steps(jobs.notify).length === 1,
  drift: ifOf(jobs.drift) === "github.event_name == 'schedule'" && needsOf(jobs.drift).length === 0
    && norm(jobs.drift && jobs.drift.outputs && jobs.drift.outputs.report) === '${{ steps.compare.outputs.report }}'
    && same(driftUses, ['actions/checkout', 'actions/setup-node'])
    && driftRuns.length === 1 && driftRuns[0] === compare
    && runOf(compare).includes('bash tests/integration/github/drift.sh > "$RUNNER_TEMP/drift.md"')
    && same(Object.keys((compare && compare.env) || {}), ['GH_TOKEN']) && envOf(compare, 'GH_TOKEN') === '${{ github.token }}',
  driftIssue: same(needsOf(jobs['drift-issue']), ['drift']) && ifOf(jobs['drift-issue']) === "needs.drift.result == 'success'"
    && envOf(issue, 'REPORT') === '${{ fromJSON(needs.drift.outputs.report) }}'
    && steps(jobs['drift-issue']).length === 1,
  preparePinned: runsHarness(rjobs['prepare-github-live'], 'pinned') && readOnly(rjobs['prepare-github-live'])
    && checkoutIndex(rjobs['prepare-github-live']) !== -1
    && checkoutIndex(rjobs['prepare-github-live']) < harnessIndex(rjobs['prepare-github-live'])
    && same(needsOf(rjobs['prepare-github-live']), ['prepare-commit'])
    && ifOf(rjobs['prepare-github-live']) === '${{ !inputs.dry_run && !inputs.skip_test_gate }}',
  prepareWaits: needsOf(rjobs.prepare).includes('prepare-github-live') && ifOf(rjobs.prepare) === PREPARE_IF
    && envOf(prepareEvidence, 'LIVE_GITHUB_RESULT') === '${{ needs.prepare-github-live.result }}',
  publishPinned: runsHarness(rjobs['publish-github-live'], 'pinned') && readOnly(rjobs['publish-github-live'])
    && same(needsOf(rjobs['publish-github-live']), ['publish-plan'])
    && ifOf(rjobs['publish-github-live']) === "needs.publish-plan.outputs.gate == 'run'",
  publishWaits: needsOf(rjobs.publish).includes('publish-github-live') && ifOf(rjobs.publish) === PUBLISH_IF
    && envOf(publishEvidence, 'LIVE_GITHUB_RESULT') === '${{ needs.publish-github-live.result }}',
  ghPinned: entries.length >= 2 && new Set(versions).size === versions.length
    && entries.every((entry) => /^[0-9]+\.[0-9]+\.[0-9]+$/.test(String(entry && entry.version))
      && entry.sha256 && hex(entry.sha256.linux_amd64, 64) && hex(entry.sha256.darwin_arm64, 64)),
  floorDocumented: Boolean(floor) && versions.length > 0 && versions.slice().sort(order)[0] === floor[1],
}));
NODE
)"
if [ -n "$GRAPH" ] && [ "$(printf '%s' "$GRAPH" | node -e 'let s="";process.stdin.on("data",(c)=>{s+=c;});process.stdin.on("end",()=>{process.stdout.write(String(JSON.parse(s).extracted));});')" = true ]; then
  check "W1 the workflows and pins parse and every executed step is found" PASS
else
  check "W1 the workflows and pins parse and every executed step is found" FAIL
  finish
fi

fact "W2 the live workflow runs on pull requests, on a schedule and on dispatch, whose only input picks pinned gh versions" triggers
fact "W3 only the notify and drift issue jobs widen the read-only token, and only to issues: write" permissions

FIXTURE_HOME="$WORK/fixture-home"
SCOPE_REPO="$WORK/scope-repo"
mkdir -p "$FIXTURE_HOME" "$SCOPE_REPO"
fixture_git() {
  (cd "$SCOPE_REPO" && HOME="$FIXTURE_HOME" GIT_CONFIG_NOSYSTEM=1 git -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath="$FIXTURE_HOME/no-hooks" "$@")
}
fixture_git init -q >/dev/null 2>&1
printf 'base\n' > "$SCOPE_REPO/README.md"
fixture_git add -A >/dev/null 2>&1
fixture_git commit -q -m base >/dev/null 2>&1
SCOPE_BASE="$(fixture_git rev-parse HEAD 2>/dev/null)"
scope_lanes() {
  local event="$1" base="$2" head_repo="$3" actor="$4" file rc notice
  shift 4
  fixture_git checkout -q --detach "$SCOPE_BASE" >/dev/null 2>&1 || { printf 'fixture checkout failed'; return 0; }
  if [ $# -gt 0 ]; then
    for file in "$@"; do
      mkdir -p "$SCOPE_REPO/$(dirname "$file")"
      printf 'changed\n' >> "$SCOPE_REPO/$file"
    done
    { fixture_git add -A && fixture_git commit -q -m change; } >/dev/null 2>&1 || { printf 'fixture commit failed'; return 0; }
  fi
  : > "$WORK/scope-output"
  (cd "$SCOPE_REPO" && HOME="$FIXTURE_HOME" GIT_CONFIG_NOSYSTEM=1 EVENT="$event" BASE_SHA="$base" HEAD_REPO="$head_repo" \
    REPO=fixture/zensu ACTOR="$actor" GITHUB_OUTPUT="$WORK/scope-output" bash "$WORK/scope.sh") >"$WORK/scope-stdout" 2>&1
  rc=$?
  notice=no
  grep -q '^::notice::' "$WORK/scope-stdout" && notice=yes
  printf 'rc=%s lanes=%s notice=%s' "$rc" "$(sed -n 's/^lanes=//p' "$WORK/scope-output")" "$notice"
}
expect "W4a a same-repository pull request that touches the driver selects the pinned lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" fixture/zensu octocat hooks/lib/zensu-vcs.sh)" 'rc=0 lanes=["pinned"] notice=no'
expect "W4b a same-repository pull request that touches the harness selects the pinned lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" fixture/zensu octocat tests/integration/github/lib.sh)" 'rc=0 lanes=["pinned"] notice=no'
expect "W4c a same-repository pull request that touches the workflow selects the pinned lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" fixture/zensu octocat .github/workflows/github-live.yml)" 'rc=0 lanes=["pinned"] notice=no'
expect "W4d a pull request that touches only lookalike paths selects no lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" fixture/zensu octocat docs/guide.md hooks/lib/zensu-vcs.sh.orig tests/integration/githubx/run.sh tests/integration/gitlab/run.sh)" \
  'rc=0 lanes=[] notice=no'
expect "W4e a fork pull request that touches the driver selects no lane and says why" \
  "$(scope_lanes pull_request "$SCOPE_BASE" stranger/zensu stranger hooks/lib/zensu-vcs.sh)" 'rc=0 lanes=[] notice=yes'
expect "W4f a Dependabot pull request that touches the driver selects no lane and says why" \
  "$(scope_lanes pull_request "$SCOPE_BASE" fixture/zensu 'dependabot[bot]' hooks/lib/zensu-vcs.sh)" 'rc=0 lanes=[] notice=yes'
expect "W5a the schedule selects the pinned lane only" "$(scope_lanes schedule '' '' '')" 'rc=0 lanes=["pinned"] notice=no'
expect "W5b a dispatch selects the dispatch lane" "$(scope_lanes workflow_dispatch '' '' '')" 'rc=0 lanes=["dispatch"] notice=no'
expect "W5c an unexpected event fails the scope job" "$(scope_lanes push '' '' '')" 'rc=1 lanes= notice=no'
expect "W5d a pull request without a valid base SHA fails the scope job" \
  "$(scope_lanes pull_request 'not-a-sha' fixture/zensu octocat hooks/lib/zensu-vcs.sh)" 'rc=1 lanes= notice=no'

fact "W6 the live job waits for the scope job and runs only for a selected lane" liveGated
fact "W7 the live job runs the harness with the selected versions and maps the App credentials into that step" liveRuns
fact "W8 the App key reaches only the three steps that run the harness, and the job token only the drift and issue jobs" secretsScoped

verdict() {
  SCOPE_RESULT="$1" LANES="$2" LIVE_RESULT="$3" bash "$WORK/result.sh" >/dev/null 2>&1
  printf '%s' "$?"
}
fact "W9 the result job always runs after the scope and live jobs" resultWired
expect "W9a no selected lane and a skipped live job pass" "$(verdict success '[]' skipped)" 0
expect "W9b a selected lane that succeeded passes" "$(verdict success '["pinned"]' success)" 0
expect "W9c a dispatch lane that succeeded passes" "$(verdict success '["dispatch"]' success)" 0
expect "W9d a failed lane fails" "$(verdict success '["pinned"]' failure)" 1
expect "W9e a cancelled lane fails" "$(verdict success '["pinned"]' cancelled)" 1
expect "W9f a selected lane whose job was skipped fails" "$(verdict success '["pinned"]' skipped)" 1
expect "W9g a live job that ran without a selected lane fails" "$(verdict success '[]' success)" 1
expect "W9h a scope job without a lanes output fails" "$(verdict success '' skipped)" 1
expect "W9i a failed scope job fails" "$(verdict failure '' skipped)" 1
expect "W9j a cancelled scope job fails" "$(verdict cancelled '' skipped)" 1

fact "W10 a red scheduled live run or drift check reaches the tracking issue job" notify
fact "W11 the release gate runs the pinned matrix against the bundled release commit" preparePinned
fact "W12 the release branch and its evidence wait for the GitHub gate or an explicit skip of every gate" prepareWaits
fact "W13 the publish stage runs the pinned matrix when its gate runs" publishPinned
fact "W14 publishing and its evidence wait for the GitHub gate or an explicit skip of every gate" publishWaits
fact "W15 every pinned gh version carries the sha256 of its Linux and macOS arm64 builds" ghPinned
fact "W16 the oldest pin is the gh floor docs/vcs-driver-spec.md states" floorDocumented

w17=PASS
grep -Eq '^[[:space:]]*(source|\.)[[:space:]]' "$DRIVER" && w17=FAIL
[ "$(grep -o '\$lib/[A-Za-z0-9._-]*' "$DRIVER" | sort -u | tr '\n' ' ')" = '$lib/repo-conventions-v1.js ' ] || w17=FAIL
[ "$(grep -c 'BASH_SOURCE' "$DRIVER")" = 2 ] || w17=FAIL
grep -Fq 'lib="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1' "$DRIVER" || w17=FAIL
grep -Fq 'if [ "${BASH_SOURCE[0]}" = "${0}" ]; then' "$DRIVER" || w17=FAIL
grep -Fq 'CLAUDE_PLUGIN_ROOT' "$DRIVER" && w17=FAIL
grep -Fq -- '--conventions' "$LIVE/test-vcs-github-live.sh" && w17=FAIL
check "W17 the driver reads no file but repo-conventions-v1.js, which only --conventions loads and the live suite never calls" "$w17"
w18=PASS
grep -v '^[[:space:]]*#' "$ROOT/tests/run-all.sh" | grep -Fq 'integration/' && w18=FAIL
grep -rlF 'test-vcs-github-live' "$ROOT/tests/profiles" >/dev/null 2>&1 && w18=FAIL
check "W18 neither tests/run-all.sh nor a run profile runs the live suite" "$w18"

out="$(env -u ZENSU_GITHUB_IT_GH ZENSU_GITHUB_IT_STATE="$WORK/none" bash "$LIVE/test-vcs-github-live.sh" 2>"$WORK/refuse.err")"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq 'not configured' "$WORK/refuse.err" && [ -z "$out" ]; then
  check "W19 the live suite refuses with exit 2 instead of passing when nothing is configured" PASS
else
  check "W19 the live suite refuses with exit 2 instead of passing when nothing is configured (rc=$rc)" FAIL
fi

PINS="$WORK/pins.json"
printf '{"schema":"zensu-github-live-versions-v1","gh":[{"version":"2.48.0","role":"fixture","sha256":{"linux_amd64":"%s"}}]}\n' \
  "$(printf '0%.0s' $(seq 1 64))" > "$PINS"
real_versions="$(env -u ZENSU_GITHUB_IT_VERSIONS bash -c '. "$1"; github_it_pin versions' _ "$LIVE/lib.sh" 2>/dev/null)"
pinned_versions="$(node -e '
  process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).gh.map((e) => e.version).join(" "));
' "$LIVE/versions.v1.json")"
fixture_versions="$(ZENSU_GITHUB_IT_VERSIONS="$PINS" bash -c '. "$1"; github_it_pin versions' _ "$LIVE/lib.sh" 2>/dev/null)"
fixture_sum="$(ZENSU_GITHUB_IT_VERSIONS="$PINS" bash -c '. "$1"; github_it_pin sha256 2.48.0 darwin_arm64' _ "$LIVE/lib.sh" 2>/dev/null)"
if [ "$real_versions" = "$pinned_versions" ] && [ "$fixture_versions" = 2.48.0 ] && [ -z "$fixture_sum" ]; then
  check "W20 the pin reader follows ZENSU_GITHUB_IT_VERSIONS and yields no sum for an unpinned platform" PASS
else
  check "W20 the pin reader follows ZENSU_GITHUB_IT_VERSIONS and yields no sum for an unpinned platform ($real_versions|$fixture_versions|$fixture_sum)" FAIL
fi

w21=PASS
[ "$(graph_is drift)" = yes ] || w21=FAIL
grep -Eq '(^|[[:space:];&|(])(tar|unzip|chmod|docker)[[:space:]]|gh-install|github-token|app-token|run\.sh|test-vcs-github-live|GH_BIN' "$LIVE/drift.sh" && w21=FAIL
check "W21 the nightly drift job keeps the read-only token and runs only drift.sh, which installs and runs no gh build" "$w21"
fact "W22 the drift issue job runs only after a successful drift job and reads the report it handed on" driftIssue

out="$(ZENSU_GITHUB_IT_CACHE="$WORK/cache-latest" bash "$LIVE/run.sh" --gh latest 2>"$WORK/latest.err")"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq "invalid --gh value 'latest'" "$WORK/latest.err" && [ -z "$out" ] && [ ! -e "$WORK/cache-latest" ]; then
  check "W23 run.sh refuses an unpinned gh selection before it touches anything" PASS
else
  check "W23 run.sh refuses an unpinned gh selection before it touches anything (rc=$rc)" FAIL
fi
mkdir -p "$WORK/empty-config"
out="$(env -u ZENSU_GITHUB_IT_APP_ID -u ZENSU_GITHUB_IT_REPO -u ZENSU_GITHUB_IT_APP_KEY -u ZENSU_GITHUB_IT_APP_KEY_FILE \
  ZENSU_GITHUB_IT_CONFIG="$WORK/empty-config" ZENSU_GITHUB_IT_CACHE="$WORK/cache-unconfigured" bash "$LIVE/run.sh" 2>"$WORK/unconfigured.err")"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq 'the sandbox credentials are not configured' "$WORK/unconfigured.err" && [ -z "$out" ] \
  && [ ! -e "$WORK/cache-unconfigured" ]; then
  check "W24 run.sh refuses missing sandbox credentials before it downloads anything" PASS
else
  check "W24 run.sh refuses missing sandbox credentials before it downloads anything (rc=$rc)" FAIL
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "W25-W62 the lane, installer, token, drift and issue checks (skipped: the live GitHub tier and its drift job run on Linux and macOS only)" PASS
    finish
    ;;
esac

mkdir -p "$WORK/fakebash"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LANE_LOG"\n' > "$WORK/fakebash/bash"
chmod 755 "$WORK/fakebash/bash"
lane_run() {
  : > "$WORK/lane.log"
  LANE="$1" DISPATCH_GH="$2" LANE_LOG="$WORK/lane.log" PATH="$WORK/fakebash:$PATH" "$BASH" "$WORK/live-run.sh" >/dev/null 2>&1
  printf 'rc=%s run=%s' "$?" "$(tr '\n' ';' < "$WORK/lane.log")"
}
expect "W25 the pinned lane runs the pinned matrix" "$(lane_run pinned '')" \
  'rc=0 run=tests/integration/github/run.sh --gh pinned;'
expect "W26 a dispatch without a selection runs the pinned matrix" "$(lane_run dispatch '')" \
  'rc=0 run=tests/integration/github/run.sh --gh pinned;'
expect "W27 a dispatch hands its version list to the harness" "$(lane_run dispatch '2.48.0,2.103.3')" \
  'rc=0 run=tests/integration/github/run.sh --gh 2.48.0,2.103.3;'
expect "W28 a lane the workflow does not know runs nothing" "$(lane_run latest '')" 'rc=2 run='

case "$(uname -s)" in
  Darwin) host_os=darwin; asset_os=macOS; ext=zip ;;
  *) host_os=linux; asset_os=linux; ext=tar.gz ;;
esac
case "$(uname -m)" in
  arm64|aarch64) host_arch=arm64 ;;
  *) host_arch=amd64 ;;
esac
HOST_PLATFORM="${host_os}_${host_arch}"
for version in 9.9.9 9.9.8 2.48.0; do
  stem="gh_${version}_${asset_os}_${host_arch}"
  mkdir -p "$WORK/src/$stem/bin" "$WORK/rel/v$version"
  printf '#!/bin/sh\necho "gh version 9.9.9 (2030-01-01)"\necho "https://github.com/cli/cli/releases/tag/v9.9.9"\n' > "$WORK/src/$stem/bin/gh"
  chmod 755 "$WORK/src/$stem/bin/gh"
  if [ "$ext" = zip ]; then
    (cd "$WORK/src" && zip -qr "$WORK/rel/v$version/$stem.zip" "$stem")
  else
    tar -czf "$WORK/rel/v$version/$stem.tar.gz" -C "$WORK/src" "$stem"
  fi
done
INSTALL_PINS="$WORK/install-pins.json"
node -e '
  const fs = require("fs");
  const crypto = require("crypto");
  const [dir, out, platform, osName, arch, ext] = process.argv.slice(1);
  const sum = (version) => crypto.createHash("sha256")
    .update(fs.readFileSync(`${dir}/rel/v${version}/gh_${version}_${osName}_${arch}.${ext}`)).digest("hex");
  fs.writeFileSync(out, JSON.stringify({
    schema: "zensu-github-live-versions-v1",
    gh: [
      { version: "9.9.9", role: "fixture", sha256: { [platform]: sum("9.9.9") } },
      { version: "9.9.8", role: "fixture", sha256: { [platform]: sum("9.9.8") } },
      { version: "2.48.0", role: "fixture", sha256: { [platform]: "0".repeat(64) } },
    ],
  }));
' "$WORK" "$INSTALL_PINS" "$HOST_PLATFORM" "$asset_os" "$host_arch" "$ext"
install_gh() {
  ZENSU_GITHUB_IT_VERSIONS="$INSTALL_PINS" ZENSU_GH_DOWNLOAD_BASE="file://$WORK/rel" bash "$LIVE/gh-install.sh" "$@"
}

installed="$(install_gh 9.9.9 "$WORK/ok" 2>"$WORK/ok.err")"
if [ "$installed" = "$WORK/ok/gh" ] && [ "$("$WORK/ok/gh" --version | head -n 1)" = 'gh version 9.9.9 (2030-01-01)' ] \
  && [ -f "$WORK/ok/.gh-sha256" ]; then
  check "W29 gh-install installs a release whose download matches its pinned sha256" PASS
else
  check "W29 gh-install installs a release whose download matches its pinned sha256 ($(head -n 1 "$WORK/ok.err"))" FAIL
fi

install_gh 2.48.0 "$WORK/tampered" >/dev/null 2>"$WORK/tampered.err"
rc=$?
if [ "$rc" -ne 0 ] && grep -Fq 'sha256 mismatch' "$WORK/tampered.err" && [ ! -e "$WORK/tampered/gh" ]; then
  check "W30 gh-install refuses a download that differs from the pinned sha256 and installs nothing" PASS
else
  check "W30 gh-install refuses a download that differs from the pinned sha256 and installs nothing (rc=$rc)" FAIL
fi

install_gh 9.9.8 "$WORK/mislabelled" >/dev/null 2>"$WORK/mislabelled.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -Fq 'does not report version 9.9.8' "$WORK/mislabelled.err" && [ ! -e "$WORK/mislabelled/.gh-sha256" ]; then
  check "W31 gh-install refuses a build that reports another version and stamps nothing" PASS
else
  check "W31 gh-install refuses a build that reports another version and stamps nothing (rc=$rc)" FAIL
fi

install_gh 9.9.7 "$WORK/unpinned" >/dev/null 2>"$WORK/unpinned.err"
unpinned_rc=$?
install_gh latest "$WORK/latest" >/dev/null 2>"$WORK/install-latest.err"
latest_rc=$?
install_gh 9.9.9 "$WORK/flagged" --unpinned >/dev/null 2>"$WORK/install-flag.err"
flag_rc=$?
if [ "$unpinned_rc" -eq 2 ] && grep -Fq 'no pinned sha256' "$WORK/unpinned.err" \
  && [ "$latest_rc" -eq 2 ] && grep -Fq "invalid gh version 'latest'" "$WORK/install-latest.err" \
  && [ "$flag_rc" -eq 2 ] && grep -Fq 'usage: gh-install.sh <version> <dest-dir>' "$WORK/install-flag.err" \
  && [ ! -e "$WORK/unpinned" ] && [ ! -e "$WORK/latest" ] && [ ! -e "$WORK/flagged" ]; then
  check "W32 gh-install takes neither an unpinned version nor latest nor an unpinned flag" PASS
else
  check "W32 gh-install takes neither an unpinned version nor latest nor an unpinned flag ($unpinned_rc/$latest_rc/$flag_rc)" FAIL
fi

TOK="$WORK/token"
mkdir -p "$TOK/config"
node -e '
  const crypto = require("crypto");
  const fs = require("fs");
  const dir = process.argv[1];
  const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
  fs.writeFileSync(`${dir}/config/private-key.pem`, privateKey.export({ type: "pkcs1", format: "pem" }), { mode: 0o600 });
  fs.writeFileSync(`${dir}/public.pem`, publicKey.export({ type: "spki", format: "pem" }));
' "$TOK"
printf '12345\n' > "$TOK/config/app-id"
printf 'fixture-owner/fixture-sandbox\n' > "$TOK/config/repo"
printf 'normal' > "$TOK/mode"
cat > "$TOK/server.js" <<'SERVER'
const fs = require('node:fs');
const http = require('node:http');
const crypto = require('node:crypto');
const [dir, token] = process.argv.slice(2);
const publicKey = crypto.createPublicKey(fs.readFileSync(`${dir}/public.pem`, 'utf8'));
const log = (line) => fs.appendFileSync(`${dir}/server.log`, `${line}\n`);
const claims = (header) => {
  const match = /^Bearer ([^.]+)\.([^.]+)\.([^.]+)$/.exec(header || '');
  if (!match) return null;
  const signed = Buffer.from(`${match[1]}.${match[2]}`);
  if (!crypto.verify('sha256', signed, publicKey, Buffer.from(match[3], 'base64url'))) return null;
  return JSON.parse(Buffer.from(match[2], 'base64url').toString('utf8'));
};
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    const send = (status, value) => {
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(value === undefined ? '' : JSON.stringify(value));
    };
    const mode = fs.readFileSync(`${dir}/mode`, 'utf8').trim();
    if (req.method === 'DELETE' && req.url === '/installation/token') {
      log(`DELETE ${req.headers.authorization === `Bearer ${token}` ? 'minted' : 'other'}`);
      send(204);
      return;
    }
    const jwt = claims(req.headers.authorization);
    if (!jwt) {
      log(`${req.method} ${req.url} unsigned`);
      send(401, { message: 'A JSON web token could not be decoded' });
      return;
    }
    log(`${req.method} ${req.url} iss=${jwt.iss} span=${jwt.exp - jwt.iat}`);
    if (req.method === 'GET' && req.url === '/repos/fixture-owner/fixture-sandbox/installation') {
      send(200, { id: 4242 });
    } else if (req.method === 'POST' && req.url === '/app/installations/4242/access_tokens') {
      log(`request ${body}`);
      const request = JSON.parse(body);
      const permissions = mode === 'wide' ? { ...request.permissions, issues: 'write' } : request.permissions;
      const repositories = [{ full_name: 'fixture-owner/fixture-sandbox' }];
      if (mode === 'all-repos') repositories.push({ full_name: 'fixture-owner/other' });
      send(201, { token, expires_at: '2030-01-01T00:00:00Z', permissions, repositories });
    } else {
      send(404, { message: 'Not Found' });
    }
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(`${dir}/port`, String(server.address().port)));
SERVER
node "$TOK/server.js" "$TOK" "$FAKE_TOKEN" &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  [ -s "$TOK/port" ] && break
  sleep 0.2
done
TOKEN_API="http://127.0.0.1:$(cat "$TOK/port" 2>/dev/null)"
mint() {
  local state="$1"
  shift
  env -u ZENSU_GITHUB_IT_APP_ID -u ZENSU_GITHUB_IT_REPO -u ZENSU_GITHUB_IT_APP_KEY -u ZENSU_GITHUB_IT_APP_KEY_FILE -u GITHUB_ACTIONS \
    ZENSU_GITHUB_IT_CONFIG="$TOK/config" ZENSU_GITHUB_IT_STATE="$state" ZENSU_GITHUB_IT_API="$TOKEN_API" "$@" \
    bash "$LIVE/github-token.sh" >"$TOK/mint.out" 2>"$TOK/mint.err"
  printf '%s' "$?"
}
modes() {
  node -e '
    const fs = require("fs");
    process.stdout.write(process.argv.slice(1).map((p) => (fs.existsSync(p) ? (fs.statSync(p).mode & 0o777).toString(8) : "absent")).join(" "));
  ' "$@"
}

rc="$(mint "$TOK/state-ok")"
if [ "$rc" = 0 ] && [ ! -s "$TOK/mint.out" ] && grep -Fq 'minted an installation token for fixture-owner/fixture-sandbox' "$TOK/mint.err" \
  && [ "$(modes "$TOK/state-ok" "$TOK/state-ok/token" "$TOK/state-ok/header")" = '700 600 600' ] \
  && [ "$(cat "$TOK/state-ok/header")" = "Authorization: Bearer $FAKE_TOKEN" ] \
  && ! grep -Fq "$FAKE_TOKEN" "$TOK/mint.err"; then
  check "W33 github-token mints into a 0700 state directory with 0600 token and header files and prints no token" PASS
else
  check "W33 github-token mints into a 0700 state directory with 0600 token and header files and prints no token (rc=$rc, $(head -n 1 "$TOK/mint.err"))" FAIL
fi
expect "W34 the token request carries a JWT the App key signed and asks for the sandbox with contents and pull request rights only" \
  "$(grep -E '^(GET|POST|request)' "$TOK/server.log" | tr '\n' ';')" \
  'GET /repos/fixture-owner/fixture-sandbox/installation iss=12345 span=600;POST /app/installations/4242/access_tokens iss=12345 span=600;request {"repositories":["fixture-sandbox"],"permissions":{"contents":"write","metadata":"read","pull_requests":"write"}};'
rc="$(mint "$TOK/state-actions" GITHUB_ACTIONS=true)"
expect "W35 inside GitHub Actions the minted token is masked and nothing else reaches stdout" \
  "$rc $(tr '\n' ';' < "$TOK/mint.out")" "0 ::add-mask::$FAKE_TOKEN;"
cp "$TOK/config/private-key.pem" "$TOK/open-key.pem"
chmod 644 "$TOK/open-key.pem"
rc="$(mint "$TOK/state-open" ZENSU_GITHUB_IT_APP_KEY_FILE="$TOK/open-key.pem")"
if [ "$rc" = 2 ] && grep -Fq 'is readable by others' "$TOK/mint.err" && [ ! -e "$TOK/state-open/token" ]; then
  check "W36 an App key readable by others is refused and nothing is minted" PASS
else
  check "W36 an App key readable by others is refused and nothing is minted (rc=$rc)" FAIL
fi
printf 'wide' > "$TOK/mode"
rc="$(mint "$TOK/state-wide")"
if [ "$rc" = 1 ] && grep -Fq 'other permissions than requested' "$TOK/mint.err" && [ ! -e "$TOK/state-wide/token" ]; then
  check "W37 a token that carries more permissions than requested is refused and not stored" PASS
else
  check "W37 a token that carries more permissions than requested is refused and not stored (rc=$rc)" FAIL
fi
printf 'all-repos' > "$TOK/mode"
rc="$(mint "$TOK/state-repos")"
if [ "$rc" = 1 ] && grep -Fq 'is not limited to fixture-owner/fixture-sandbox' "$TOK/mint.err" && [ ! -e "$TOK/state-repos/token" ]; then
  check "W38 a token that reaches another repository is refused and not stored" PASS
else
  check "W38 a token that reaches another repository is refused and not stored (rc=$rc)" FAIL
fi
printf 'normal' > "$TOK/mode"
mv "$TOK/config/private-key.pem" "$TOK/key-text.pem"
rc="$(mint "$TOK/state-env" ZENSU_GITHUB_IT_APP_KEY="$(cat "$TOK/key-text.pem")")"
mv "$TOK/key-text.pem" "$TOK/config/private-key.pem"
if [ "$rc" = 0 ] && [ -f "$TOK/state-env/token" ] && [ ! -e "$TOK/state-env/app-key.pem" ]; then
  check "W39 an App key handed in through the environment mints and leaves no key file behind" PASS
else
  check "W39 an App key handed in through the environment mints and leaves no key file behind (rc=$rc)" FAIL
fi
ZENSU_GITHUB_IT_STATE="$TOK/state-ok" ZENSU_GITHUB_IT_API="$TOKEN_API" bash "$LIVE/github-token.sh" --revoke >/dev/null 2>&1
rc=$?
expect "W40 --revoke deletes the token files and revokes the token at GitHub" \
  "$rc $(modes "$TOK/state-ok/token" "$TOK/state-ok/header") $(tail -n 1 "$TOK/server.log")" "0 absent absent DELETE minted"
env -u ZENSU_GITHUB_IT_APP_ID -u ZENSU_GITHUB_IT_REPO -u ZENSU_GITHUB_IT_APP_KEY -u ZENSU_GITHUB_IT_APP_KEY_FILE \
  ZENSU_GITHUB_IT_CONFIG="$WORK/empty-config" ZENSU_GITHUB_IT_STATE="$TOK/state-check" bash "$LIVE/github-token.sh" --check \
  >/dev/null 2>"$TOK/check.err"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq 'not configured' "$TOK/check.err" && [ ! -e "$TOK/state-check" ]; then
  check "W41 --check refuses missing credentials and creates nothing" PASS
else
  check "W41 --check refuses missing credentials and creates nothing (rc=$rc)" FAIL
fi
kill "$SERVER" 2>/dev/null
wait "$SERVER" 2>/dev/null
SERVER=''

hex64() {
  local out=''
  while [ "${#out}" -lt 64 ]; do out="$out$1"; done
  printf '%s' "$out"
}
P1="$(hex64 1)"; P2="$(hex64 2)"; P3="$(hex64 3)"; P4="$(hex64 4)"; N5="$(hex64 5)"; N6="$(hex64 6)"; N7="$(hex64 7)"
DRIFT="$WORK/drift"
mkdir -p "$DRIFT/fixtures" "$DRIFT/bin"
cat > "$DRIFT/pins.json" <<JSON
{
  "schema": "zensu-github-live-versions-v1",
  "gh": [
    { "version": "2.48.0", "role": "floor-first-api-slurp", "sha256": { "linux_amd64": "$P1", "darwin_arm64": "$P2" } },
    { "version": "2.103.3", "role": "newest-pinned", "sha256": { "linux_amd64": "$P3", "darwin_arm64": "$P4" } }
  ]
}
JSON
CURRENT_SUMS="$(printf '%s  %s\n' "$N7" gh_2.103.3_linux_arm64.tar.gz "$P3" gh_2.103.3_linux_amd64.tar.gz "$P4" gh_2.103.3_macOS_arm64.zip "$N7" gh_2.103.3_windows_amd64.zip)"
printf '%s\n' "$CURRENT_SUMS" > "$DRIFT/fixtures/sums-2.103.3.txt"
printf '%s  %s\n' "$N5" gh_2.104.0_linux_amd64.tar.gz "$N7" gh_2.104.0_linux_arm64.tar.gz "$N6" gh_2.104.0_macOS_arm64.zip \
  > "$DRIFT/fixtures/sums-2.104.0.txt"
printf '%s  %s\n' "$N5" gh_2.105.0_linux_amd64.tar.gz > "$DRIFT/fixtures/sums-2.105.0.txt"
printf '%s  %s\n' "$P3" gh_2.102.0_linux_amd64.tar.gz "$P4" gh_2.102.0_macOS_arm64.zip > "$DRIFT/fixtures/sums-2.102.0.txt"
cat > "$DRIFT/bin/curl" <<'CURL'
#!/bin/bash
argv="$*"
out=''
url=''
config=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -K) [ "$2" = - ] && config="$(cat)"; shift ;;
    --max-time) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
auth=anonymous
case "$config" in *"Authorization: Bearer $DRIFT_TOKEN"*) auth=token ;; esac
leak=clean
case "$argv" in *"$DRIFT_TOKEN"*) leak=argv ;; esac
printf '%s %s %s\n' "$url" "$auth" "$leak" >> "$CURL_LOG"
case "$url" in
  https://api.github.com/repos/cli/cli/releases/latest) src="$CURL_FIXTURES/latest.json" ;;
  https://github.com/cli/cli/releases/download/v*/gh_*_checksums.txt)
    version="${url#https://github.com/cli/cli/releases/download/v}"
    src="$CURL_FIXTURES/sums-${version%%/*}.txt"
    ;;
  *) exit 22 ;;
esac
[ -f "$src" ] || exit 22
cp "$src" "$out"
CURL
chmod 755 "$DRIFT/bin/curl"
for forbidden in gh tar unzip chmod; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$forbidden" "$DRIFT/forbidden.log" > "$DRIFT/bin/$forbidden"
  /bin/chmod 755 "$DRIFT/bin/$forbidden"
done
: > "$DRIFT/forbidden.log"
drift_env() {
  env -u ZENSU_GH_LATEST_RELEASE_URL -u ZENSU_GH_DOWNLOAD_BASE ZENSU_GITHUB_IT_VERSIONS="$DRIFT/pins.json" \
    CURL_FIXTURES="$DRIFT/fixtures" CURL_LOG="$DRIFT/curl.log" DRIFT_TOKEN="$FAKE_TOKEN" PATH="$DRIFT/bin:$PATH" "$@"
}
drift_upstream() {
  printf '%s\n' "$1" > "$DRIFT/fixtures/latest.json"
}
latest() {
  printf '{"tag_name":"%s","draft":false,"prerelease":%s}' "$1" "${2:-false}"
}
drift_run() {
  local rc
  drift_upstream "$1"
  : > "$DRIFT/curl.log"
  drift_env GH_TOKEN="${2:-}" bash "$LIVE/drift.sh" > "$DRIFT/out" 2>"$DRIFT/err"
  rc=$?
  printf 'rc=%s %s' "$rc" "$(node -e '
    const text = require("fs").readFileSync(process.argv[1], "utf8");
    if (text === "") {
      process.stdout.write("none");
    } else {
      const lines = text.split("\n");
      const blocks = [...text.matchAll(/```json\n([\s\S]*?)\n```/g)].map((m) => JSON.stringify(JSON.parse(m[1])));
      process.stdout.write([lines[0], lines.filter((line) => line.startsWith("- ")).join("; "), ...blocks].join(" | "));
    }
  ' "$DRIFT/out" 2>/dev/null || printf 'unparsable')"
}
drift_refuses() {
  local label="$1" got
  got="$(drift_run "$2")"
  if [ "$got" = 'rc=1 none' ] && grep -Fq "$3" "$DRIFT/err"; then
    check "$label" PASS
  else
    check "$label (got '$got', stderr '$(head -n 1 "$DRIFT/err")')" FAIL
  fi
}
GH_BLOCK="{\"version\":\"2.104.0\",\"role\":\"newest-pinned\",\"sha256\":{\"linux_amd64\":\"$N5\",\"darwin_arm64\":\"$N6\"}}"
expect "W42 pins that match the newest release and its vendor checksums report no drift" \
  "$(drift_run "$(latest v2.103.3)")" 'rc=0 none'
expect "W43 a newer gh release reports its vendor sums for every pinned platform" \
  "$(drift_run "$(latest v2.104.0)")" \
  "rc=0 <!-- zensu-github-drift gh=2.104.0 --> | - gh 2.104.0 (newest pin: 2.103.3) | $GH_BLOCK"
GH_REPORT="$(cat "$DRIFT/out"; printf x)"
GH_REPORT="${GH_REPORT%x}"
drift_run "$(latest v2.104.0)" "$FAKE_TOKEN" >/dev/null
expect "W44 the job token goes to the GitHub API only, through curl's stdin, and never to a download" \
  "$(tr '\n' ';' < "$DRIFT/curl.log")" \
  'https://api.github.com/repos/cli/cli/releases/latest token clean;https://github.com/cli/cli/releases/download/v2.104.0/gh_2.104.0_checksums.txt anonymous clean;'
printf '%s  %s\n' "$P4" gh_2.103.3_macOS_arm64.zip "$N5" gh_2.103.3_linux_amd64.tar.gz > "$DRIFT/fixtures/sums-2.103.3.txt"
drift_refuses "W45 vendor checksums that no longer match the pinned gh fail the check" "$(latest v2.103.3)" \
  'gh_2.103.3_checksums.txt no longer lists the pinned sha256 for linux_amd64'
printf '%s\n' "$CURRENT_SUMS" > "$DRIFT/fixtures/sums-2.103.3.txt"
drift_refuses "W46 a release without a plain vX.Y.Z tag fails the check" "$(latest v2.104.0-rc1)" \
  'the newest gh release carries no vX.Y.Z tag'
drift_refuses "W47 a prerelease handed out as the newest release fails the check" "$(latest v2.104.0 true)" \
  'the newest gh release carries no vX.Y.Z tag'
drift_refuses "W48 a newest release below the pin fails the check" "$(latest v2.102.0)" \
  'the newest gh release, 2.102.0, is older than the pin 2.103.3'
drift_refuses "W49 vendor checksums without a pinned platform fail the check" "$(latest v2.105.0)" \
  'gh_2.105.0_checksums.txt names no gh_2.105.0_macOS_arm64.zip'
drift_refuses "W50 a release whose checksums cannot be read fails the check" "$(latest v2.106.0)" \
  'cannot read gh_2.106.0_checksums.txt'
expect "W51 drift.sh ran no gh, tar, unzip or chmod in any of the checks above" "$(cat "$DRIFT/forbidden.log")" ''

compare_run() {
  local rc
  drift_upstream "$1"
  mkdir -p "$WORK/runner-temp"
  : > "$WORK/compare-output"
  (cd "$ROOT" && RUNNER_TEMP="$WORK/runner-temp" GITHUB_OUTPUT="$WORK/compare-output" GH_TOKEN="$FAKE_TOKEN" \
    drift_env bash "$WORK/compare.sh") >/dev/null 2>&1
  rc=$?
  printf 'rc=%s %s' "$rc" "$(node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    const report = process.argv[2];
    let value = null;
    try { value = lines.length === 1 && lines[0].startsWith("report=") ? JSON.parse(lines[0].slice(7)) : null; } catch {}
    process.stdout.write(`lines=${lines.length} report=${value === null ? "unreadable" : value === "" ? "empty" : value === report ? "same" : "different"}`);
  ' "$WORK/compare-output" "$2")"
}
expect "W52 the compare step hands on an empty report when nothing drifted" \
  "$(compare_run "$(latest v2.103.3)" '')" 'rc=0 lines=1 report=empty'
expect "W53 the compare step hands on the whole report as one JSON line" \
  "$(compare_run "$(latest v2.104.0)" "$GH_REPORT")" 'rc=0 lines=1 report=same'
expect "W54 a failed drift check fails the compare step and hands on no report" \
  "$(compare_run "$(latest v2.102.0)" '')" 'rc=1 lines=0 report=unreadable'

mkdir -p "$WORK/fakegh"
cat > "$WORK/fakegh/gh" <<'FAKE'
#!/bin/bash
line=''
skip=''
for arg in "$@"; do
  if [ -n "$skip" ]; then
    if [ "$skip" != --repo ]; then
      if [ "$arg" = "${REPORT:-}" ]; then line="$line $skip=REPORT"; else line="$line $skip=TEXT"; fi
    fi
    skip=''
    continue
  fi
  case "$arg" in
    --repo|--body|--comment|--title|--description|--color|--jq|--json|--limit|--state) skip="$arg" ;;
    *) line="$line $arg" ;;
  esac
done
printf '%s\n' "${line# }" >> "$GH_LOG"
case "$1 $2" in
  'issue list') printf '%s\n' "${GH_OPEN:-}" ;;
  'issue view') printf '%s\n' "${GH_BODY:-}" ;;
esac
exit 0
FAKE
chmod 755 "$WORK/fakegh/gh"
issue_run() {
  local rc
  : > "$WORK/gh.log"
  REPORT="$1" GH_OPEN="$2" GH_BODY="$3" GH_LOG="$WORK/gh.log" GH_TOKEN=fixture REPO=fixture/repo \
    PATH="$WORK/fakegh:$PATH" bash "$WORK/drift-issue.sh" >/dev/null 2>&1
  rc=$?
  printf 'rc=%s writes=%s' "$rc" "$(grep -E '^issue (create|edit|comment|close)' "$WORK/gh.log" | tr '\n' ';')"
}
printf '%s  %s\n' "$N5" gh_2.105.1_linux_amd64.tar.gz "$N6" gh_2.105.1_macOS_arm64.zip > "$DRIFT/fixtures/sums-2.105.1.txt"
drift_run "$(latest v2.105.1)" >/dev/null
NEWER_REPORT="$(cat "$DRIFT/out"; printf x)"
NEWER_REPORT="${NEWER_REPORT%x}"
CRLF_REPORT="$(REPORT_TEXT="$GH_REPORT" node -e 'process.stdout.write(process.env.REPORT_TEXT.replace(/\n/g, "\r\n"))')"
expect "W55 no drift and no open drift issue writes nothing" "$(issue_run '' '' '')" 'rc=0 writes='
expect "W56 no drift closes the open drift issue" "$(issue_run '' 7 '')" 'rc=0 writes=issue close 7 --comment=TEXT;'
w57="$(issue_run "$GH_REPORT" '' '')"
if [ "$w57" = 'rc=0 writes=issue create --title=TEXT --label github-live-drift --body=REPORT;' ] \
  && grep -Fxq 'label create github-live-drift --color=TEXT --description=TEXT --force' "$WORK/gh.log"; then
  check "W57 new drift opens an issue under its label with the report as its body" PASS
else
  check "W57 new drift opens an issue under its label with the report as its body (got '$w57')" FAIL
fi
expect "W58 drift the open issue already lists writes nothing, even with CRLF line ends" \
  "$(issue_run "$GH_REPORT" 7 "$CRLF_REPORT")" 'rc=0 writes='
expect "W59 drift past what the open issue lists rewrites it and comments" "$(issue_run "$NEWER_REPORT" 7 "$GH_REPORT")" \
  'rc=0 writes=issue edit 7 --body=REPORT;issue comment 7 --body=TEXT;'
expect "W60 a report without its marker line fails and writes nothing" \
  "$(issue_run 'Upstream published a release.' '' '')" 'rc=1 writes='
expect "W61 a report whose marker line is not first fails and writes nothing" \
  "$(issue_run "$(printf 'preface\n%s' "$GH_REPORT")" 7 "$GH_REPORT")" 'rc=1 writes='

notify_run() {
  : > "$WORK/gh.log"
  GH_OPEN="$1" GH_LOG="$WORK/gh.log" GH_TOKEN=fixture REPO=fixture/repo RUN_URL=https://example.invalid/run/1 \
    PATH="$WORK/fakegh:$PATH" bash "$WORK/notify.sh" >/dev/null 2>&1
  printf 'rc=%s writes=%s labels=%s' "$?" "$(grep -E '^issue (create|comment)' "$WORK/gh.log" | tr '\n' ';')" \
    "$(grep -c '^label create github-live --color=TEXT --description=TEXT --force$' "$WORK/gh.log")"
}
expect "W62 a red scheduled run opens the tracking issue under its label, or comments on the open one" \
  "$(notify_run '') | $(notify_run 9)" \
  'rc=0 writes=issue create --title=TEXT --label github-live --body=TEXT; labels=1 | rc=0 writes=issue comment 9 --body=TEXT; labels=1'

finish
