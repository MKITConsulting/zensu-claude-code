#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIVE="$ROOT/tests/integration/gitlab"
WORKFLOW="$ROOT/.github/workflows/gitlab-live.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
DRIVER="$ROOT/hooks/lib/zensu-vcs.sh"
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
  echo "test-gitlab-live-workflow: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
}

for file in "$WORKFLOW" "$RELEASE" "$DRIVER" "$LIVE/versions.v1.json" "$LIVE/lib.sh" "$LIVE/run.sh" "$LIVE/gitlab-up.sh" \
  "$LIVE/gitlab-down.sh" "$LIVE/glab-install.sh" "$LIVE/drift.sh" "$LIVE/test-vcs-gitlab-live.sh"; do
  if [ ! -f "$file" ]; then
    check "W0 ${file#"$ROOT"/} exists" FAIL
    finish
  fi
done
check "W0 the live harness, its workflow and its pins exist" PASS

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-live-workflow.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

GRAPH="$(cd "$ROOT" && node - "$WORKFLOW" "$RELEASE" "$LIVE/versions.v1.json" "$WORK" <<'NODE'
const fs = require('node:fs');
const YAML = require('yaml');
const live = YAML.parse(fs.readFileSync(process.argv[2], 'utf8'));
const release = YAML.parse(fs.readFileSync(process.argv[3], 'utf8'));
const pins = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const work = process.argv[5];
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
const runsHarness = (job, selection) => steps(job).some((step) =>
  runOf(step).includes(`bash tests/integration/gitlab/run.sh --glab ${selection}`));
const tearsDown = (job) => steps(job).some((step) =>
  String(step.if || '') === 'always()' && runOf(step).includes('bash tests/integration/gitlab/gitlab-down.sh'));
const showsLogs = (job) => Boolean(job && job.env && job.env.ZENSU_GITLAB_IT_CONTAINER === 'zensu-gitlab-it')
  && steps(job).some((step) => String(step.if || '') === 'failure()'
    && runOf(step).includes('docker logs --tail 300 "$ZENSU_GITLAB_IT_CONTAINER"'));
const triggers = live.on || live[true] || {};
const checkoutIndex = (job) => steps(job).findIndex((step) => runOf(step).includes('git checkout --detach "$EXPECTED_SHA"'));
const harnessIndex = (job) => steps(job).findIndex((step) => runOf(step).includes('tests/integration/gitlab/run.sh'));
const hex = (value, length) => typeof value === 'string' && new RegExp(`^[0-9a-f]{${length}}$`).test(value);
const envOf = (step, name) => norm(step && step.env && step.env[name]);
const decide = steps(jobs.scope).find((step) => step.id === 'decide');
const verdict = stepNamed(jobs.result, 'Check the GitLab live verdict');
const liveRun = stepNamed(jobs.live, 'Run the live GitLab suite');
const compare = steps(jobs.drift).find((step) => step.id === 'compare');
const issue = stepNamed(jobs['drift-issue'], 'Open, update or close the drift issue');
const extracted = { 'scope.sh': decide, 'result.sh': verdict, 'live-run.sh': liveRun, 'compare.sh': compare, 'drift-issue.sh': issue };
for (const [file, step] of Object.entries(extracted)) fs.writeFileSync(`${work}/${file}`, runOf(step));
const driftRuns = steps(jobs.drift).filter((step) => has(step, 'run'));
const driftUses = steps(jobs.drift).filter((step) => has(step, 'uses')).map((step) => String(step.uses).split('@')[0]);
const PREPARE_IF = "${{ !cancelled() && !inputs.dry_run && needs.prepare-commit.result == 'success'"
  + " && ((needs.prepare-suite.result == 'success' && needs.prepare-gitlab-live.result == 'success')"
  + " || (inputs.skip_test_gate && needs.prepare-suite.result == 'skipped' && needs.prepare-gitlab-live.result == 'skipped')) }}";
const PUBLISH_IF = "${{ !cancelled() && needs.publish-plan.result == 'success'"
  + " && ((needs.publish-plan.outputs.gate == 'run' && needs.publish-suite.result == 'success'"
  + " && needs.publish-gitlab-live.result == 'success')"
  + " || (needs.publish-plan.outputs.gate == 'skipped' && needs.publish-suite.result == 'skipped'"
  + " && needs.publish-gitlab-live.result == 'skipped')) }}";
const NOTIFY_IF = "always() && github.event_name == 'schedule' && (needs.result.result != 'success'"
  + " || needs.drift.result != 'success' || needs.drift-issue.result != 'success')";
const prepareEvidence = stepNamed(rjobs.prepare, 'Record deterministic exact-commit runtime evidence');
const publishEvidence = stepNamed(rjobs.publish, 'Deterministic exact-main-SHA gate');
process.stdout.write(JSON.stringify({
  extracted: Object.values(extracted).every((step) => runOf(step) !== ''),
  triggers: ['pull_request', 'schedule', 'workflow_dispatch'].every((key) => has(triggers, key))
    && same(Object.keys((triggers.workflow_dispatch && triggers.workflow_dispatch.inputs) || {}), ['glab']),
  permissions: same(live.permissions, { contents: 'read' })
    && ['scope', 'live', 'result', 'drift'].every((id) => Boolean(jobs[id]) && !has(jobs[id], 'permissions'))
    && ['notify', 'drift-issue'].every((id) => same(jobs[id] && jobs[id].permissions, { issues: 'write' })),
  liveGated: same(needsOf(jobs.live), ['scope']) && ifOf(jobs.live) === "needs.scope.outputs.lanes != '[]'"
    && norm(jobs.live && jobs.live.strategy && jobs.live.strategy.matrix && jobs.live.strategy.matrix.lane)
      === '${{ fromJSON(needs.scope.outputs.lanes) }}',
  liveRuns: runOf(liveRun).includes('bash tests/integration/gitlab/run.sh --glab "$selection" --keep'),
  liveTearsDown: tearsDown(jobs.live) && showsLogs(jobs.live),
  resultWired: ifOf(jobs.result) === 'always()' && same(needsOf(jobs.result), ['scope', 'live']),
  notify: ifOf(jobs.notify) === NOTIFY_IF
    && same(needsOf(jobs.notify), ['result', 'drift', 'drift-issue'])
    && steps(jobs.notify).some((step) => runOf(step).includes('gh label create "$label"')
      && runOf(step).includes('--state open --label "$label"')
      && runOf(step).includes('gh issue create --repo "$REPO" --title "$title" --label "$label"')
      && !runOf(step).includes('in:title')),
  drift: ifOf(jobs.drift) === "github.event_name == 'schedule'" && needsOf(jobs.drift).length === 0
    && norm(jobs.drift && jobs.drift.outputs && jobs.drift.outputs.report) === '${{ steps.compare.outputs.report }}'
    && same(driftUses, ['actions/checkout', 'actions/setup-node'])
    && driftRuns.length === 1 && driftRuns[0] === compare
    && runOf(compare).includes('bash tests/integration/gitlab/drift.sh > "$RUNNER_TEMP/drift.md"'),
  driftIssue: same(needsOf(jobs['drift-issue']), ['drift']) && ifOf(jobs['drift-issue']) === "needs.drift.result == 'success'"
    && envOf(issue, 'REPORT') === '${{ fromJSON(needs.drift.outputs.report) }}'
    && steps(jobs['drift-issue']).length === 1,
  preparePinned: runsHarness(rjobs['prepare-gitlab-live'], 'pinned') && tearsDown(rjobs['prepare-gitlab-live'])
    && showsLogs(rjobs['prepare-gitlab-live'])
    && checkoutIndex(rjobs['prepare-gitlab-live']) !== -1
    && checkoutIndex(rjobs['prepare-gitlab-live']) < harnessIndex(rjobs['prepare-gitlab-live'])
    && same(needsOf(rjobs['prepare-gitlab-live']), ['prepare-commit'])
    && ifOf(rjobs['prepare-gitlab-live']) === '${{ !inputs.dry_run && !inputs.skip_test_gate }}',
  prepareWaits: needsOf(rjobs.prepare).includes('prepare-gitlab-live') && ifOf(rjobs.prepare) === PREPARE_IF
    && envOf(prepareEvidence, 'GITLAB_RESULT') === '${{ needs.prepare-gitlab-live.result }}',
  publishPinned: runsHarness(rjobs['publish-gitlab-live'], 'pinned') && tearsDown(rjobs['publish-gitlab-live'])
    && showsLogs(rjobs['publish-gitlab-live'])
    && same(needsOf(rjobs['publish-gitlab-live']), ['publish-plan'])
    && ifOf(rjobs['publish-gitlab-live']) === "needs.publish-plan.outputs.gate == 'run'",
  publishWaits: needsOf(rjobs.publish).includes('publish-gitlab-live') && ifOf(rjobs.publish) === PUBLISH_IF
    && envOf(publishEvidence, 'GITLAB_RESULT') === '${{ needs.publish-gitlab-live.result }}',
  imagePinned: Boolean(pins.gitlab) && typeof pins.gitlab.image === 'string' && typeof pins.gitlab.tag === 'string'
    && typeof pins.gitlab.digest === 'string' && /^sha256:[0-9a-f]{64}$/.test(pins.gitlab.digest),
  glabPinned: Array.isArray(pins.glab) && pins.glab.length >= 2
    && pins.glab.every((entry) => /^[0-9]+\.[0-9]+\.[0-9]+$/.test(entry.version || '')
      && entry.sha256 && hex(entry.sha256.linux_amd64, 64)),
}));
NODE
)"
if [ -n "$GRAPH" ] && [ "$(printf '%s' "$GRAPH" | node -e 'let s="";process.stdin.on("data",(c)=>{s+=c;});process.stdin.on("end",()=>{process.stdout.write(String(JSON.parse(s).extracted));});')" = true ]; then
  check "W1 the workflows and pins parse and every executed step is found" PASS
else
  check "W1 the workflows and pins parse and every executed step is found" FAIL
  finish
fi

fact "W2 the live workflow runs on pull requests, on a schedule and on dispatch, whose only input picks pinned glab versions" triggers
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
  local event="$1" base="$2" file rc
  shift 2
  fixture_git checkout -q --detach "$SCOPE_BASE" >/dev/null 2>&1 || { printf 'fixture checkout failed'; return 0; }
  if [ $# -gt 0 ]; then
    for file in "$@"; do
      mkdir -p "$SCOPE_REPO/$(dirname "$file")"
      printf 'changed\n' >> "$SCOPE_REPO/$file"
    done
    { fixture_git add -A && fixture_git commit -q -m change; } >/dev/null 2>&1 || { printf 'fixture commit failed'; return 0; }
  fi
  : > "$WORK/scope-output"
  (cd "$SCOPE_REPO" && HOME="$FIXTURE_HOME" GIT_CONFIG_NOSYSTEM=1 EVENT="$event" BASE_SHA="$base" \
    GITHUB_OUTPUT="$WORK/scope-output" bash "$WORK/scope.sh") >/dev/null 2>&1
  rc=$?
  printf 'rc=%s lanes=%s' "$rc" "$(sed -n 's/^lanes=//p' "$WORK/scope-output")"
}
expect "W4a a pull request that touches the driver selects the pinned lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" hooks/lib/zensu-vcs.sh)" 'rc=0 lanes=["pinned"]'
expect "W4b a pull request that touches the harness selects the pinned lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" tests/integration/gitlab/lib.sh)" 'rc=0 lanes=["pinned"]'
expect "W4c a pull request that touches the workflow selects the pinned lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" .github/workflows/gitlab-live.yml)" 'rc=0 lanes=["pinned"]'
expect "W4d a pull request that touches only lookalike paths selects no lane" \
  "$(scope_lanes pull_request "$SCOPE_BASE" docs/guide.md hooks/lib/zensu-vcs.sh.orig tests/integration/gitlabx/run.sh tests/integration/README.md)" \
  'rc=0 lanes=[]'
expect "W5a the schedule selects the pinned lane only" "$(scope_lanes schedule '')" 'rc=0 lanes=["pinned"]'
expect "W5b a dispatch selects the dispatch lane" "$(scope_lanes workflow_dispatch '')" 'rc=0 lanes=["dispatch"]'
expect "W5c an unexpected event fails the scope job" "$(scope_lanes push '')" 'rc=1 lanes='
expect "W5d a pull request without a valid base SHA fails the scope job" \
  "$(scope_lanes pull_request 'not-a-sha' hooks/lib/zensu-vcs.sh)" 'rc=1 lanes='

fact "W6 the live job waits for the scope job and runs only for a selected lane" liveGated
fact "W7 the live job runs the harness and keeps the container for the log step" liveRuns
fact "W8 the live job shows the container logs on failure and always removes the container" liveTearsDown

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

fact "W10 a red scheduled live run or drift check opens or updates the tracking issue its label names" notify
fact "W11 the release gate runs the pinned matrix against the bundled release commit" preparePinned
fact "W12 the release branch and its evidence wait for the GitLab gate or an explicit skip of every gate" prepareWaits
fact "W13 the publish stage runs the pinned matrix when its gate runs" publishPinned
fact "W14 publishing and its evidence wait for the GitLab gate or an explicit skip of every gate" publishWaits
fact "W15 the GitLab image is pinned by digest" imagePinned
fact "W16 every pinned glab version carries the sha256 of its Linux build" glabPinned

w17=PASS
grep -Eq '^[[:space:]]*(source|\.)[[:space:]]' "$DRIVER" && w17=FAIL
[ "$(grep -o '\$lib/[A-Za-z0-9._-]*' "$DRIVER" | sort -u | tr '\n' ' ')" = '$lib/repo-conventions-v1.js ' ] || w17=FAIL
[ "$(grep -c 'BASH_SOURCE' "$DRIVER")" = 2 ] || w17=FAIL
grep -Fq 'lib="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1' "$DRIVER" || w17=FAIL
grep -Fq 'if [ "${BASH_SOURCE[0]}" = "${0}" ]; then' "$DRIVER" || w17=FAIL
grep -Fq 'CLAUDE_PLUGIN_ROOT' "$DRIVER" && w17=FAIL
grep -Fq -- '--conventions' "$LIVE/test-vcs-gitlab-live.sh" && w17=FAIL
check "W17 the driver reads no file but repo-conventions-v1.js, which only --conventions loads and the live suite never calls" "$w17"
w18=PASS
grep -v '^[[:space:]]*#' "$ROOT/tests/run-all.sh" | grep -Fq 'integration/' && w18=FAIL
grep -rlF 'test-vcs-gitlab-live' "$ROOT/tests/profiles" >/dev/null 2>&1 && w18=FAIL
check "W18 neither tests/run-all.sh nor a run profile runs the live suite" "$w18"

out="$(env -u ZENSU_GITLAB_IT_GLAB ZENSU_GITLAB_IT_STATE="$WORK/none" bash "$LIVE/test-vcs-gitlab-live.sh" 2>"$WORK/refuse.err")"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq 'not configured' "$WORK/refuse.err" && [ -z "$out" ]; then
  check "W19 the live suite refuses with exit 2 instead of passing when nothing is configured" PASS
else
  check "W19 the live suite refuses with exit 2 instead of passing when nothing is configured (rc=$rc)" FAIL
fi

PINS="$WORK/pins.json"
node -e '
  const fs = require("fs");
  const [dir, real] = process.argv.slice(1);
  const pins = JSON.parse(fs.readFileSync(real, "utf8"));
  const wrong = "0".repeat(64);
  fs.writeFileSync(`${dir}/pins.json`, JSON.stringify({
    schema: pins.schema,
    gitlab: { image: "fixture/gitlab", tag: "0" },
    glab: [{ version: "1.113.0", role: "fixture",
      sha256: { linux_amd64: wrong, linux_arm64: wrong, darwin_amd64: wrong, darwin_arm64: wrong } }],
  }));
' "$WORK" "$LIVE/versions.v1.json"
real_image="$(env -u ZENSU_GITLAB_IT_VERSIONS bash -c '. "$1"; gitlab_it_pin image' _ "$LIVE/lib.sh" 2>/dev/null)"
pinned_image="$(node -e '
  const g = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).gitlab;
  process.stdout.write(`${g.image}:${g.tag}@${g.digest}`);
' "$LIVE/versions.v1.json")"
fixture_versions="$(ZENSU_GITLAB_IT_VERSIONS="$PINS" bash -c '. "$1"; gitlab_it_pin versions' _ "$LIVE/lib.sh" 2>/dev/null)"
ZENSU_GITLAB_IT_VERSIONS="$PINS" bash -c '. "$1"; gitlab_it_pin image' _ "$LIVE/lib.sh" >/dev/null 2>&1
fixture_image_rc=$?
if [ "$real_image" = "$pinned_image" ] && [ "$fixture_versions" = 1.113.0 ] && [ "$fixture_image_rc" -eq 1 ]; then
  check "W20 the pin reader follows ZENSU_GITLAB_IT_VERSIONS and yields no image without a digest" PASS
else
  check "W20 the pin reader follows ZENSU_GITLAB_IT_VERSIONS and yields no image without a digest ($real_image|$fixture_versions|$fixture_image_rc)" FAIL
fi

w21=PASS
[ "$(graph_is drift)" = yes ] || w21=FAIL
grep -Eq '(^|[[:space:];&|(])(docker|tar|chmod)[[:space:]]|glab-install|run\.sh' "$LIVE/drift.sh" && w21=FAIL
check "W21 the nightly drift job keeps the read-only token and runs only drift.sh, which starts and unpacks nothing" "$w21"
fact "W22 the drift issue job runs only after a successful drift job and reads the report it handed on" driftIssue

out="$(ZENSU_GITLAB_IT_CACHE="$WORK/cache-latest" bash "$LIVE/run.sh" --glab latest 2>"$WORK/latest.err")"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq "invalid --glab value 'latest'" "$WORK/latest.err" && [ -z "$out" ] && [ ! -e "$WORK/cache-latest" ]; then
  check "W23 run.sh refuses an unpinned glab selection before it touches anything" PASS
else
  check "W23 run.sh refuses an unpinned glab selection before it touches anything (rc=$rc)" FAIL
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "W24-W54 the lane, gitlab-up, installer and drift checks (skipped: the live tier and its drift job run on Linux and macOS only)" PASS
    finish
    ;;
esac

mkdir -p "$WORK/fakebash"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$LANE_LOG"\n' > "$WORK/fakebash/bash"
chmod 755 "$WORK/fakebash/bash"
lane_run() {
  : > "$WORK/lane.log"
  LANE="$1" DISPATCH_GLAB="$2" LANE_LOG="$WORK/lane.log" PATH="$WORK/fakebash:$PATH" "$BASH" "$WORK/live-run.sh" >/dev/null 2>&1
  printf 'rc=%s run=%s' "$?" "$(tr '\n' ';' < "$WORK/lane.log")"
}
expect "W24 the pinned lane runs the pinned matrix" "$(lane_run pinned '')" \
  'rc=0 run=tests/integration/gitlab/run.sh --glab pinned --keep;'
expect "W25 a dispatch without a selection runs the pinned matrix" "$(lane_run dispatch '')" \
  'rc=0 run=tests/integration/gitlab/run.sh --glab pinned --keep;'
expect "W26 a dispatch hands its version list to the harness" "$(lane_run dispatch '1.113.0,1.128.0')" \
  'rc=0 run=tests/integration/gitlab/run.sh --glab 1.113.0,1.128.0 --keep;'
expect "W27 a lane the workflow does not know runs nothing" "$(lane_run latest '')" 'rc=2 run='

mkdir -p "$WORK/fakedocker"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$DOCKER_LOG"\nexit 1\n' > "$WORK/fakedocker/docker"
chmod 755 "$WORK/fakedocker/docker"
: > "$WORK/docker.log"
ZENSU_GITLAB_IT_IMAGE=gitlab/gitlab-ce:latest ZENSU_GITLAB_IT_STATE="$WORK/up-state" ZENSU_GITLAB_IT_CONTAINER=zensu-gitlab-it-fixture \
  DOCKER_LOG="$WORK/docker.log" PATH="$WORK/fakedocker:$PATH" env -u ZENSU_GITLAB_IT_VERSIONS \
  bash "$LIVE/gitlab-up.sh" >/dev/null 2>"$WORK/up.err"
rc=$?
started="$(awk '$1 == "run" { print $NF }' "$WORK/docker.log")"
if [ "$rc" -eq 1 ] && [ "$started" = "$pinned_image" ] && grep -Fq "docker run failed for $pinned_image" "$WORK/up.err"; then
  check "W28 gitlab-up starts the pinned image whatever ZENSU_GITLAB_IT_IMAGE names" PASS
else
  check "W28 gitlab-up starts the pinned image whatever ZENSU_GITLAB_IT_IMAGE names (rc=$rc started=$started)" FAIL
fi

mkdir -p "$WORK/src/bin"
printf '#!/bin/sh\necho "glab 9.9.9 (fixture)"\n' > "$WORK/src/bin/glab"
chmod 755 "$WORK/src/bin/glab"
for version in 9.9.9 1.113.0; do
  mkdir -p "$WORK/rel/v$version/downloads"
  for platform in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
    tar -czf "$WORK/rel/v$version/downloads/glab_${version}_${platform}.tar.gz" -C "$WORK/src" bin/glab
  done
done
INSTALL_PINS="$WORK/install-pins.json"
node -e '
  const fs = require("fs");
  const crypto = require("crypto");
  const [dir, out] = process.argv.slice(1);
  const platforms = ["linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64"];
  const sum = (platform) => crypto.createHash("sha256")
    .update(fs.readFileSync(`${dir}/rel/v9.9.9/downloads/glab_9.9.9_${platform}.tar.gz`)).digest("hex");
  fs.writeFileSync(out, JSON.stringify({
    schema: "zensu-gitlab-live-versions-v1",
    gitlab: { image: "fixture/gitlab", tag: "0" },
    glab: [
      { version: "9.9.9", role: "fixture", sha256: Object.fromEntries(platforms.map((p) => [p, sum(p)])) },
      { version: "1.113.0", role: "fixture", sha256: Object.fromEntries(platforms.map((p) => [p, "0".repeat(64)])) },
    ],
  }));
' "$WORK" "$INSTALL_PINS"
install_glab() {
  ZENSU_GITLAB_IT_VERSIONS="$INSTALL_PINS" ZENSU_GLAB_DOWNLOAD_BASE="file://$WORK/rel" bash "$LIVE/glab-install.sh" "$@"
}

installed="$(install_glab 9.9.9 "$WORK/ok" 2>"$WORK/ok.err")"
if [ "$installed" = "$WORK/ok/glab" ] && [ "$("$WORK/ok/glab" --version)" = 'glab 9.9.9 (fixture)' ]; then
  check "W29 glab-install installs a release whose download matches its pinned sha256" PASS
else
  check "W29 glab-install installs a release whose download matches its pinned sha256 ($(head -n 1 "$WORK/ok.err"))" FAIL
fi

install_glab 1.113.0 "$WORK/tampered" >/dev/null 2>"$WORK/tampered.err"
rc=$?
if [ "$rc" -ne 0 ] && grep -Fq 'sha256 mismatch' "$WORK/tampered.err" && [ ! -e "$WORK/tampered/glab" ]; then
  check "W30 glab-install refuses a download that differs from the pinned sha256 and installs nothing" PASS
else
  check "W30 glab-install refuses a download that differs from the pinned sha256 and installs nothing (rc=$rc)" FAIL
fi

install_glab 9.9.7 "$WORK/unpinned" >/dev/null 2>"$WORK/unpinned.err"
rc=$?
if [ "$rc" -eq 2 ] && grep -Fq 'no pinned sha256' "$WORK/unpinned.err" && [ ! -e "$WORK/unpinned/glab" ]; then
  check "W31 glab-install refuses a version without a pin" PASS
else
  check "W31 glab-install refuses a version without a pin (rc=$rc)" FAIL
fi

install_glab latest "$WORK/latest" >/dev/null 2>"$WORK/install-latest.err"
latest_rc=$?
install_glab 9.9.9 "$WORK/flagged" --unpinned >/dev/null 2>"$WORK/install-flag.err"
flag_rc=$?
if [ "$latest_rc" -eq 2 ] && grep -Fq "invalid glab version 'latest'" "$WORK/install-latest.err" \
  && [ "$flag_rc" -eq 2 ] && grep -Fq 'usage: glab-install.sh <version> <dest-dir>' "$WORK/install-flag.err" \
  && [ ! -e "$WORK/latest" ] && [ ! -e "$WORK/flagged" ]; then
  check "W32 glab-install takes neither latest nor an unpinned flag" PASS
else
  check "W32 glab-install takes neither latest nor an unpinned flag (latest rc=$latest_rc, flag rc=$flag_rc)" FAIL
fi

hex64() {
  local out=''
  while [ "${#out}" -lt 64 ]; do out="$out$1"; done
  printf '%s' "$out"
}
P1="$(hex64 1)"; P2="$(hex64 2)"; P3="$(hex64 3)"; P4="$(hex64 4)"; N5="$(hex64 5)"; N6="$(hex64 6)"; N7="$(hex64 7)"
D1="sha256:$(hex64 a)"; D2="sha256:$(hex64 b)"; D3="sha256:$(hex64 c)"; D4="sha256:$(hex64 d)"
DRIFT="$WORK/drift"
mkdir -p "$DRIFT/api/permalink"
for version in 1.127.0 1.128.0 1.130.0 1.131.0; do
  mkdir -p "$DRIFT/dl/v$version/downloads"
done
cat > "$DRIFT/pins.json" <<JSON
{
  "schema": "zensu-gitlab-live-versions-v1",
  "gitlab": { "image": "gitlab/gitlab-ce", "tag": "19.5.3-ce.0", "digest": "$D1" },
  "glab": [
    { "version": "1.113.0", "role": "headerless-input-body", "sha256": { "linux_amd64": "$P1", "darwin_arm64": "$P2" } },
    { "version": "1.128.0", "role": "newest-pinned", "sha256": { "linux_amd64": "$P3", "darwin_arm64": "$P4" } }
  ]
}
JSON
CURRENT_SUMS="$(printf '%s  %s\n' "$P4" glab_1.128.0_darwin_arm64.tar.gz "$N7" glab_1.128.0_linux_arm64.tar.gz "$P3" glab_1.128.0_linux_amd64.tar.gz)"
printf '%s\n' "$CURRENT_SUMS" > "$DRIFT/dl/v1.128.0/downloads/checksums.txt"
printf '%s  %s\n' "$P3" glab_1.127.0_linux_amd64.tar.gz "$P4" glab_1.127.0_darwin_arm64.tar.gz > "$DRIFT/dl/v1.127.0/downloads/checksums.txt"
printf '%s  %s\n' "$N5" glab_1.130.0_linux_amd64.tar.gz "$N7" glab_1.130.0_linux_arm64.tar.gz "$N6" glab_1.130.0_darwin_arm64.tar.gz \
  > "$DRIFT/dl/v1.130.0/downloads/checksums.txt"
printf '%s  %s\n' "$N5" glab_1.131.0_linux_amd64.tar.gz > "$DRIFT/dl/v1.131.0/downloads/checksums.txt"
tag() {
  printf '{"name":"%s","digest":"%s"}' "$1" "$2"
}
listing() {
  local IFS=,
  printf '{"count":%s,"results":[%s]}' "$#" "$*"
}
TAGS_CURRENT="$(listing "$(tag latest "$D1")" "$(tag nightly "$D3")" "$(tag 19.0.11-ce.0 "$D4")" "$(tag 19.5.3-ce.0 "$D1")" "$(tag 19.4.5-ce.0 "$D3")" "$(tag rc "$D1")")"
TAGS_NEWER="$(listing "$(tag 19.9.4-ce.0 "$D3")" "$(tag latest "$D2")" "$(tag 19.10.0-ce.0 "$D2")" "$(tag 19.5.3-ce.0 "$D1")")"
TAGS_REPUSHED="$(listing "$(tag latest "$D4")" "$(tag 19.5.3-ce.0 "$D4")" "$(tag 19.4.5-ce.0 "$D3")")"
TAGS_OLDER="$(listing "$(tag latest "$D3")" "$(tag 19.4.5-ce.0 "$D3")")"
TAGS_NONE="$(listing "$(tag latest "$D1")" "$(tag nightly "$D3")" "$(tag 19.6.0-rc42.ce.0 "$D2")")"
TAGS_BAD_DIGEST="$(listing "$(tag 19.10.0-ce.0 sha256:not-a-digest)" "$(tag 19.5.3-ce.0 "$D1")")"
drift_env() {
  ZENSU_GITLAB_IT_VERSIONS="$DRIFT/pins.json" ZENSU_GLAB_RELEASES_API="file://$DRIFT/api" \
    ZENSU_GLAB_DOWNLOAD_BASE="file://$DRIFT/dl" ZENSU_GITLAB_IT_TAGS_URL="file://$DRIFT/tags.json" "$@"
}
drift_upstream() {
  printf '{"tag_name":"%s","upcoming_release":false}\n' "$1" > "$DRIFT/api/permalink/latest"
  printf '%s\n' "$2" > "$DRIFT/tags.json"
}
drift_run() {
  local rc
  drift_upstream "$1" "$2"
  drift_env bash "$LIVE/drift.sh" > "$DRIFT/out" 2>"$DRIFT/err"
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
  got="$(drift_run "$2" "$3")"
  if [ "$got" = 'rc=1 none' ] && grep -Fq "$4" "$DRIFT/err"; then
    check "$label" PASS
  else
    check "$label (got '$got', stderr '$(head -n 1 "$DRIFT/err")')" FAIL
  fi
}
GLAB_BLOCK="{\"version\":\"1.130.0\",\"role\":\"newest-pinned\",\"sha256\":{\"linux_amd64\":\"$N5\",\"darwin_arm64\":\"$N6\"}}"
expect "W33 pins that match the newest releases and their vendor checksums report no drift" \
  "$(drift_run v1.128.0 "$TAGS_CURRENT")" 'rc=0 none'
expect "W34 a newer glab release reports its vendor sums for every pinned platform" \
  "$(drift_run v1.130.0 "$TAGS_CURRENT")" \
  "rc=0 <!-- zensu-gitlab-drift glab=1.130.0 --> | - glab 1.130.0 (newest pin: 1.128.0) | $GLAB_BLOCK"
expect "W35 the newest GitLab release is the highest version, not the last one pushed or listed" \
  "$(drift_run v1.128.0 "$TAGS_NEWER")" \
  "rc=0 <!-- zensu-gitlab-drift gitlab=19.10.0-ce.0@$D2 --> | - GitLab CE 19.10.0-ce.0 at $D2 (pin: 19.5.3-ce.0 at $D1) | {\"image\":\"gitlab/gitlab-ce\",\"tag\":\"19.10.0-ce.0\",\"digest\":\"$D2\"}"
expect "W36 a pinned GitLab tag that now names another digest is drift" \
  "$(drift_run v1.128.0 "$TAGS_REPUSHED")" \
  "rc=0 <!-- zensu-gitlab-drift gitlab=19.5.3-ce.0@$D4 --> | - GitLab CE 19.5.3-ce.0 at $D4 (pin: 19.5.3-ce.0 at $D1) | {\"image\":\"gitlab/gitlab-ce\",\"tag\":\"19.5.3-ce.0\",\"digest\":\"$D4\"}"
expect "W37 drift in both reports both under one marker" \
  "$(drift_run v1.130.0 "$TAGS_NEWER")" \
  "rc=0 <!-- zensu-gitlab-drift glab=1.130.0 gitlab=19.10.0-ce.0@$D2 --> | - glab 1.130.0 (newest pin: 1.128.0); - GitLab CE 19.10.0-ce.0 at $D2 (pin: 19.5.3-ce.0 at $D1) | $GLAB_BLOCK | {\"image\":\"gitlab/gitlab-ce\",\"tag\":\"19.10.0-ce.0\",\"digest\":\"$D2\"}"
BOTH_REPORT="$(cat "$DRIFT/out"; printf x)"
BOTH_REPORT="${BOTH_REPORT%x}"
drift_run v1.130.0 "$TAGS_CURRENT" >/dev/null
GLAB_REPORT="$(cat "$DRIFT/out"; printf x)"
GLAB_REPORT="${GLAB_REPORT%x}"

printf '%s  %s\n' "$P3" glab_1.128.0_darwin_arm64.tar.gz "$N5" glab_1.128.0_linux_amd64.tar.gz > "$DRIFT/dl/v1.128.0/downloads/checksums.txt"
drift_refuses "W38 vendor checksums that no longer match the pinned glab fail the check" v1.128.0 "$TAGS_CURRENT" \
  'checksums.txt of glab 1.128.0 no longer lists the pinned sha256 for linux_amd64'
printf '%s\n' "$CURRENT_SUMS" > "$DRIFT/dl/v1.128.0/downloads/checksums.txt"
drift_refuses "W39 a glab release without a plain vX.Y.Z tag fails the check" 'v1.130.0-rc1' "$TAGS_CURRENT" \
  'the newest glab release carries no vX.Y.Z tag'
drift_refuses "W40 a newest glab release below the pin fails the check" v1.127.0 "$TAGS_CURRENT" \
  'the newest glab release, 1.127.0, is older than the pin 1.128.0'
drift_refuses "W41 vendor checksums without a pinned platform fail the check" v1.131.0 "$TAGS_CURRENT" \
  'checksums.txt of glab 1.131.0 names no glab_1.131.0_darwin_arm64.tar.gz'
drift_refuses "W42 a tag listing whose newest release is below the pin fails the check" v1.128.0 "$TAGS_OLDER" \
  'the newest GitLab CE release on the first page of the tag listing, 19.4.5-ce.0, is older than the pin 19.5.3-ce.0'
drift_refuses "W43 a tag listing without a release tag fails the check" v1.128.0 "$TAGS_NONE" \
  'the GitLab CE tag listing names no X.Y.Z-ce.0 release'
drift_refuses "W44 a newest GitLab release without a sha256 digest fails the check" v1.128.0 "$TAGS_BAD_DIGEST" \
  'GitLab CE 19.10.0-ce.0 carries no sha256 digest'

compare_run() {
  local rc
  drift_upstream "$1" "$2"
  mkdir -p "$WORK/runner-temp"
  : > "$WORK/compare-output"
  (cd "$ROOT" && RUNNER_TEMP="$WORK/runner-temp" GITHUB_OUTPUT="$WORK/compare-output" drift_env bash "$WORK/compare.sh") >/dev/null 2>&1
  rc=$?
  printf 'rc=%s %s' "$rc" "$(node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    const report = process.argv[2];
    let value = null;
    try { value = lines.length === 1 && lines[0].startsWith("report=") ? JSON.parse(lines[0].slice(7)) : null; } catch {}
    process.stdout.write(`lines=${lines.length} report=${value === null ? "unreadable" : value === "" ? "empty" : value === report ? "same" : "different"}`);
  ' "$WORK/compare-output" "$3")"
}
expect "W45 the compare step hands on an empty report when nothing drifted" \
  "$(compare_run v1.128.0 "$TAGS_CURRENT" '')" 'rc=0 lines=1 report=empty'
expect "W46 the compare step hands on the whole report as one JSON line" \
  "$(compare_run v1.130.0 "$TAGS_NEWER" "$BOTH_REPORT")" 'rc=0 lines=1 report=same'
expect "W47 a failed drift check fails the compare step and hands on no report" \
  "$(compare_run v1.127.0 "$TAGS_CURRENT" '')" 'rc=1 lines=0 report=unreadable'

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
CRLF_REPORT="$(REPORT_TEXT="$BOTH_REPORT" node -e 'process.stdout.write(process.env.REPORT_TEXT.replace(/\n/g, "\r\n"))')"
expect "W48 no drift and no open drift issue writes nothing" "$(issue_run '' '' '')" 'rc=0 writes='
expect "W49 no drift closes the open drift issue" "$(issue_run '' 7 '')" 'rc=0 writes=issue close 7 --comment=TEXT;'
w50="$(issue_run "$BOTH_REPORT" '' '')"
if [ "$w50" = 'rc=0 writes=issue create --title=TEXT --label gitlab-live-drift --body=REPORT;' ] \
  && grep -Fxq 'label create gitlab-live-drift --color=TEXT --description=TEXT --force' "$WORK/gh.log"; then
  check "W50 new drift opens an issue under its label with the report as its body" PASS
else
  check "W50 new drift opens an issue under its label with the report as its body (got '$w50')" FAIL
fi
expect "W51 drift the open issue already lists writes nothing, even with CRLF line ends" \
  "$(issue_run "$BOTH_REPORT" 7 "$CRLF_REPORT")" 'rc=0 writes='
expect "W52 drift past what the open issue lists rewrites it and comments" "$(issue_run "$BOTH_REPORT" 7 "$GLAB_REPORT")" \
  'rc=0 writes=issue edit 7 --body=REPORT;issue comment 7 --body=TEXT;'
expect "W53 a report without its marker line fails and writes nothing" \
  "$(issue_run 'Upstream published releases.' '' '')" 'rc=1 writes='
expect "W54 a report whose marker line is not first fails and writes nothing" \
  "$(issue_run "$(printf 'preface\n%s' "$BOTH_REPORT")" 7 "$GLAB_REPORT")" 'rc=1 writes='

finish
