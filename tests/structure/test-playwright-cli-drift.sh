#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKFLOW="$ROOT/.github/workflows/playwright-cli-drift.yml"
DRIFT="$ROOT/.github/scripts/playwright-cli-drift.sh"
CONSENT="$ROOT/hooks/lib/verify-consent-v1.js"
VERSION_MODULE="$ROOT/hooks/lib/playwright-cli-version-v1.js"
PACKAGE='@playwright/cli'
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
  echo "test-playwright-cli-drift: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
}

for file in "$WORKFLOW" "$DRIFT" "$CONSENT" "$VERSION_MODULE"; do
  if [ ! -f "$file" ]; then
    check "PD0 ${file#"$ROOT"/} exists" FAIL
    finish
  fi
done
check "PD0 the drift workflow, its script and the two modules it reads exist" PASS

WORK="$(mktemp -d "${TMPDIR:-/tmp}/playwright-cli-drift-guard.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

GRAPH="$(cd "$ROOT" && node - "$WORKFLOW" "$WORK" <<'NODE'
const fs = require('node:fs');
const YAML = require('yaml');
const doc = YAML.parse(fs.readFileSync(process.argv[2], 'utf8')) || {};
const work = process.argv[3];
const jobs = doc.jobs || {};
const job = (id) => jobs[id] || {};
const steps = (id) => (Array.isArray(job(id).steps) ? job(id).steps : []);
const runOf = (step) => String((step && step.run) || '');
const needsOf = (id) => [].concat(job(id).needs || []);
const norm = (value) => String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
const ifOf = (id) => norm(job(id).if);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const has = (object, key) => Boolean(object) && Object.prototype.hasOwnProperty.call(object, key);
const stepNamed = (id, name) => steps(id).find((step) => step.name === name);
const envOf = (step, name) => norm(step && step.env && step.env[name]);
const triggers = doc.on || doc[true] || {};
const schedule = Array.isArray(triggers.schedule) ? triggers.schedule : [];
const compare = steps('drift').find((step) => step.id === 'compare');
const issue = stepNamed('drift-issue', 'Open, update or close the drift issue');
const notify = stepNamed('notify', 'Open or update the tracking issue');
const extracted = { 'compare.sh': compare, 'drift-issue.sh': issue, 'notify.sh': notify };
for (const [file, step] of Object.entries(extracted)) fs.writeFileSync(`${work}/${file}`, runOf(step));
const driftRuns = steps('drift').filter((step) => has(step, 'run'));
const driftUses = steps('drift').filter((step) => has(step, 'uses'));
const NOTIFY_IF = "always() && github.event_name == 'schedule'"
  + " && (needs.drift.result != 'success' || needs.drift-issue.result != 'success')";
process.stdout.write(JSON.stringify({
  extracted: Object.values(extracted).every((step) => runOf(step) !== ''),
  triggers: same(Object.keys(triggers).sort(), ['schedule', 'workflow_dispatch'])
    && schedule.length === 1 && typeof (schedule[0] || {}).cron === 'string'
    && !has(triggers.workflow_dispatch, 'inputs'),
  permissions: same(doc.permissions, { contents: 'read' })
    && same(Object.keys(jobs).sort(), ['drift', 'drift-issue', 'notify'])
    && !has(job('drift'), 'permissions')
    && ['drift-issue', 'notify'].every((id) => same(job(id).permissions, { issues: 'write' })),
  serialized: same(doc.concurrency, { group: 'playwright-cli-drift', 'cancel-in-progress': false }),
  drift: needsOf('drift').length === 0 && !has(job('drift'), 'if')
    && norm(job('drift').outputs && job('drift').outputs.report) === '${{ steps.compare.outputs.report }}'
    && same(driftUses.map((step) => String(step.uses).split('@')[0]), ['actions/checkout', 'actions/setup-node'])
    && Boolean(driftUses[0].with) && driftUses[0].with['persist-credentials'] === false
    && driftRuns.length === 1 && driftRuns[0] === compare
    && runOf(compare).includes('bash .github/scripts/playwright-cli-drift.sh > "$RUNNER_TEMP/drift.md"'),
  driftIssue: same(needsOf('drift-issue'), ['drift']) && ifOf('drift-issue') === "needs.drift.result == 'success'"
    && envOf(issue, 'REPORT') === '${{ fromJSON(needs.drift.outputs.report) }}'
    && steps('drift-issue').length === 1,
  notify: ifOf('notify') === NOTIFY_IF && same(needsOf('notify'), ['drift', 'drift-issue'])
    && steps('notify').length === 1
    && runOf(notify).includes('--state open --label "$label"')
    && runOf(notify).includes('gh issue create --repo "$REPO" --title "$title" --label "$label"')
    && !runOf(notify).includes('in:title'),
}));
NODE
)"
if [ -n "$GRAPH" ] && [ "$(graph_is extracted)" = yes ]; then
  check "PD1 the workflow parses and every executed step is found" PASS
else
  check "PD1 the workflow parses and every executed step is found" FAIL
  finish
fi

fact "PD2 the workflow runs nightly and on a dispatch without inputs, never on a push or a pull request" triggers
fact "PD3 only the drift issue and notify jobs widen the read-only token, and only to issues: write" permissions
fact "PD4 one concurrency group serializes every run and never cancels one in progress" serialized
fact "PD5 the drift job checks out without credentials, sets up node and runs only the drift script" drift
fact "PD6 the drift issue job runs only after a successful drift job and reads the report it handed on" driftIssue
fact "PD7 a red scheduled run opens or updates the tracking issue its label names" notify

pd8=PASS
grep -Fqx 'REGISTRY="${ZENSU_PLAYWRIGHT_CLI_REGISTRY:-https://registry.npmjs.org/@playwright%2fcli}"' "$DRIFT" || pd8=FAIL
grep -Fq -- "-H 'Accept: application/vnd.npm.install-v1+json'" "$DRIFT" || pd8=FAIL
check "PD8 by default the script reads the abbreviated npm registry metadata of @playwright/cli" "$pd8"
pd9=PASS
grep -Eq "child_process|require\\(['\"](node:)?https?['\"]\\)|fetch\\(|XMLHttpRequest" "$DRIFT" && pd9=FAIL
check "PD9 the script's node program spawns nothing and opens no connection of its own" "$pd9"

MEASURED="$(node -e 'process.stdout.write(String(require(process.argv[1]).PLAYWRIGHT_CLI_SOURCE_VERSION || ""))' "$CONSENT" 2>/dev/null)"
DERIVED="$(node -e '
  const match = /^([0-9]+)\.([0-9]+)\.([0-9]+)$/.exec(process.argv[1]);
  if (!match) process.exit(1);
  const [x, y, z] = match.slice(1).map(Number);
  let wide = 10;
  while (wide <= z + 1) wide *= 10;
  process.stdout.write([`${x}.${y}.${z + 1}`, `${x}.${y + 1}.0`, `${x}.${y}.${wide}`, `${x}.${y}.${wide - 1}`].join(" "));
' "$MEASURED" 2>/dev/null)"
NEXT=''
MINOR=''
WIDE=''
NARROW=''
read -r NEXT MINOR WIDE NARROW <<< "$DERIVED"
if [ -n "$NARROW" ]; then
  check "PD10 PLAYWRIGHT_CLI_SOURCE_VERSION ($MEASURED) is a plain X.Y.Z version the fixtures derive their releases from" PASS
else
  check "PD10 PLAYWRIGHT_CLI_SOURCE_VERSION is a plain X.Y.Z version the fixtures derive their releases from (got '$MEASURED')" FAIL
  finish
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "PD11-PD39 the executed drift, step and mutation checks (skipped: the drift workflow runs on Ubuntu only, and these checks read file:// URLs and link a hooks tree)" PASS
    finish
    ;;
esac

METADATA="$WORK/metadata.json"
registry() {
  node -e '
    const fs = require("fs");
    const [file, name, ...versions] = process.argv.slice(1);
    const doc = { name, "dist-tags": { latest: versions[versions.length - 1] }, versions: {}, modified: "2026-11-07T00:00:00.000Z" };
    for (const version of versions) {
      doc.versions[version] = { name, version, bin: { "playwright-cli": "playwright-cli.js" }, dist: { tarball: `https://registry.invalid/cli-${version}.tgz` } };
    }
    fs.writeFileSync(file, JSON.stringify(doc));
  ' "$METADATA" "$@"
}
summary() {
  node -e '
    const text = require("fs").readFileSync(process.argv[1], "utf8");
    if (text === "") {
      process.stdout.write("none");
    } else {
      const lines = text.split("\n");
      process.stdout.write([lines[0], ...lines.filter((line) => line.startsWith("- "))].join(" | "));
    }
  ' "$1" 2>/dev/null || printf 'unparsable'
}
drift_run() {
  local rc
  ZENSU_PLAYWRIGHT_CLI_REGISTRY="file://$METADATA" bash "$1" > "$WORK/out" 2> "$WORK/err"
  rc=$?
  printf 'rc=%s %s' "$rc" "$(summary "$WORK/out")"
}
bullet() {
  printf -- '- `%s` %s (measured: %s, `PLAYWRIGHT_CLI_SOURCE_VERSION` in `hooks/lib/verify-consent-v1.js`)' "$PACKAGE" "$1" "$MEASURED"
}
reported() {
  printf 'rc=0 <!-- zensu-playwright-cli-drift playwright-cli=%s --> | %s' "$1" "$(bullet "$1")"
}
refuses() {
  local label="$1" needle="$2" got
  got="$(drift_run "$DRIFT")"
  if [ "$got" = 'rc=1 none' ] && grep -Fq "$needle" "$WORK/err"; then
    check "$label" PASS
  else
    check "$label (got '$got', stderr '$(head -n 1 "$WORK/err")')" FAIL
  fi
}

registry "$PACKAGE" "$MEASURED"
expect "PD11 a measured version that is the newest release reports no drift" "$(drift_run "$DRIFT")" 'rc=0 none'
registry "$PACKAGE" "$MEASURED" "$NEXT-alpha-1"
expect "PD12 a newer prerelease is no drift" "$(drift_run "$DRIFT")" 'rc=0 none'
registry "$PACKAGE" "$MEASURED" "$NEXT"
expect "PD13 a newer stable release reports the release under the marker that names it" "$(drift_run "$DRIFT")" "$(reported "$NEXT")"
NEXT_REPORT="$(cat "$WORK/out"; printf x)"
NEXT_REPORT="${NEXT_REPORT%x}"
pd14="$(node -e '
  const fs = require("fs");
  const path = require("path");
  const [file, root, version] = process.argv.slice(1);
  const text = fs.readFileSync(file, "utf8");
  const faults = [];
  const install = "`npm install --prefix <dir> --ignore-scripts @playwright/cli@" + version + "`";
  if (!text.includes(install)) faults.push("install");
  const words = [...text.matchAll(/`([^`]+)`/g)].flatMap((match) => match[1].split(/\s+/));
  const files = words.filter((word) => word.includes("/") && /^[a-z][a-z0-9._/-]*\.(js|json|sh)$/.test(word));
  if (files.length < 4) faults.push(`paths:${files.length}`);
  for (const name of files) if (!fs.existsSync(path.join(root, name))) faults.push(`missing:${name}`);
  const prose = text.replace(/<!--[\s\S]*?-->/g, "").replace(/`[^`]*`/g, "");
  if (prose.includes("@")) faults.push("bare-at");
  process.stdout.write(faults.join(",") || "ok");
' "$WORK/out" "$ROOT" "$NEXT" 2>/dev/null)"
expect "PD14 the report installs that release, names only repository paths that exist and no bare @name" "$pd14" ok
registry "$PACKAGE" "$WIDE" "$MEASURED" "$NARROW"
expect "PD15 the newest release is the highest version by number, not the last one listed nor the highest by text" \
  "$(drift_run "$DRIFT")" "$(reported "$WIDE")"
registry "$PACKAGE" "$WIDE" "$MINOR" "$MEASURED"
expect "PD16 a higher minor outranks a higher patch" "$(drift_run "$DRIFT")" "$(reported "$MINOR")"
MINOR_REPORT="$(cat "$WORK/out"; printf x)"
MINOR_REPORT="${MINOR_REPORT%x}"

registry "$PACKAGE" "$NEXT"
refuses "PD17 metadata that do not list the measured version fail the check" \
  "the registry does not list $PACKAGE $MEASURED, the measured version"
registry '@playwright/test' "$MEASURED" "$NEXT"
refuses "PD18 metadata of another package fail the check" "the registry metadata do not describe $PACKAGE"
registry "$PACKAGE" "$MEASURED" "$NEXT ::warning::forged"
got="$(drift_run "$DRIFT")"
if [ "$got" = 'rc=1 none' ] && grep -Fq 'the registry lists a version that is not a semantic version' "$WORK/err" \
  && ! grep -Fq 'forged' "$WORK/err"; then
  check "PD19 a version that is not a semantic version fails the check and never reaches the log" PASS
else
  check "PD19 a version that is not a semantic version fails the check and never reaches the log (got '$got', stderr '$(head -n 1 "$WORK/err")')" FAIL
fi
printf '{"name":"%s","versions":{"%s":{"name":"%s","version":"%s"},"%s":{"name":"%s","version":"%s"}}}\n' \
  "$PACKAGE" "$MEASURED" "$PACKAGE" "$MEASURED" "$NEXT" "$PACKAGE" "$MINOR" > "$METADATA"
refuses "PD20 a version entry that names another version fails the check" \
  "the registry entry for $NEXT does not describe $PACKAGE $NEXT"
printf 'not json\n' > "$METADATA"
refuses "PD21 metadata that do not parse fail the check" 'the registry metadata do not parse as JSON'
printf '{"name":"%s","versions":["%s"]}\n' "$PACKAGE" "$MEASURED" > "$METADATA"
refuses "PD22 metadata without a version map fail the check" 'the registry metadata list no versions'
rm -f "$METADATA"
refuses "PD23 an unreadable registry fails the check" 'cannot read the @playwright/cli registry metadata'

REAL_CURL="$(command -v curl)"
mkdir -p "$WORK/spy"
cat > "$WORK/spy/curl" <<'SPY'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$SPY_LOG"
exec "$REAL_CURL" "$@"
SPY
cat > "$WORK/spy/tool" <<'SPY'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$SPY_LOG"
exit 97
SPY
for tool in npm npx pnpm yarn bunx tar playwright-cli; do
  cp "$WORK/spy/tool" "$WORK/spy/$tool"
done
rm -f "$WORK/spy/tool"
chmod 755 "$WORK/spy/"*
: > "$WORK/spy.log"
registry "$PACKAGE" "$MEASURED" "$NEXT"
got="$(export SPY_LOG="$WORK/spy.log" REAL_CURL="$REAL_CURL" PATH="$WORK/spy:$PATH"; drift_run "$DRIFT")"
pd24=PASS
[ "$got" = "$(reported "$NEXT")" ] || pd24=FAIL
[ "$(wc -l < "$WORK/spy.log" | tr -d ' ')" = 1 ] || pd24=FAIL
spied="$(head -n 1 "$WORK/spy.log")"
case "$spied" in
  "curl "*"Accept: application/vnd.npm.install-v1+json"*" file://$METADATA") ;;
  *) pd24=FAIL ;;
esac
check "PD24 a drift run fetches the registry metadata with one curl and starts no package manager, archiver or CLI" "$pd24"

compare_run() {
  local rc
  mkdir -p "$WORK/runner-temp"
  : > "$WORK/compare-output"
  (cd "$ROOT" && RUNNER_TEMP="$WORK/runner-temp" GITHUB_OUTPUT="$WORK/compare-output" \
    ZENSU_PLAYWRIGHT_CLI_REGISTRY="file://$METADATA" bash "$WORK/compare.sh") >/dev/null 2>&1
  rc=$?
  printf 'rc=%s %s' "$rc" "$(node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
    const report = process.argv[2];
    let value = null;
    try { value = lines.length === 1 && lines[0].startsWith("report=") ? JSON.parse(lines[0].slice(7)) : null; } catch {}
    process.stdout.write(`lines=${lines.length} report=${value === null ? "unreadable" : value === "" ? "empty" : value === report ? "same" : "different"}`);
  ' "$WORK/compare-output" "$1")"
}
registry "$PACKAGE" "$MEASURED"
expect "PD25 the compare step hands on an empty report when nothing drifted" "$(compare_run '')" 'rc=0 lines=1 report=empty'
registry "$PACKAGE" "$MEASURED" "$NEXT"
expect "PD26 the compare step hands on the whole report as one JSON line" "$(compare_run "$NEXT_REPORT")" 'rc=0 lines=1 report=same'
registry "$PACKAGE" "$NEXT"
expect "PD27 a failed drift check fails the compare step and hands on no report" "$(compare_run '')" 'rc=1 lines=0 report=unreadable'

mkdir -p "$WORK/fakegh"
cat > "$WORK/fakegh/gh" <<'FAKE'
#!/bin/bash
line=''
skip=''
for arg in "$@"; do
  if [ -n "$skip" ]; then
    if [ "$skip" != --repo ]; then
      if [ "$arg" = "${REPORT:-}" ]; then
        line="$line $skip=REPORT"
      elif [ -n "${RUN_URL:-}" ] && [ "${arg#*"$RUN_URL"}" != "$arg" ]; then
        line="$line $skip=RUN"
      else
        line="$line $skip=TEXT"
      fi
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
writes() {
  grep -E '^issue (create|edit|comment|close)' "$WORK/gh.log" | tr '\n' ';'
}
issue_run() {
  local rc
  : > "$WORK/gh.log"
  REPORT="$2" GH_OPEN="$3" GH_BODY="$4" GH_LOG="$WORK/gh.log" GH_TOKEN=fixture REPO=fixture/repo \
    PATH="$WORK/fakegh:$PATH" bash "$1" >/dev/null 2>&1
  rc=$?
  printf 'rc=%s writes=%s' "$rc" "$(writes)"
}
ISSUE="$WORK/drift-issue.sh"
CRLF_NEXT="$(REPORT_TEXT="$NEXT_REPORT" node -e 'process.stdout.write(process.env.REPORT_TEXT.replace(/\n/g, "\r\n"))')"
expect "PD28 no drift and no open drift issue writes nothing" "$(issue_run "$ISSUE" '' '' '')" 'rc=0 writes='
expect "PD29 no drift closes the open drift issue" "$(issue_run "$ISSUE" '' 7 '')" 'rc=0 writes=issue close 7 --comment=TEXT;'
pd30="$(issue_run "$ISSUE" "$NEXT_REPORT" '' '')"
if [ "$pd30" = 'rc=0 writes=issue create --title=TEXT --label playwright-cli-drift --body=REPORT;' ] \
  && grep -Fxq 'label create playwright-cli-drift --color=TEXT --description=TEXT --force' "$WORK/gh.log"; then
  check "PD30 new drift opens an issue under its label with the report as its body" PASS
else
  check "PD30 new drift opens an issue under its label with the report as its body (got '$pd30')" FAIL
fi
expect "PD31 drift the open issue already names writes nothing, even with CRLF line ends" \
  "$(issue_run "$ISSUE" "$NEXT_REPORT" 7 "$CRLF_NEXT")" 'rc=0 writes='
expect "PD32 drift past the release the open issue names rewrites it and comments" \
  "$(issue_run "$ISSUE" "$MINOR_REPORT" 7 "$NEXT_REPORT")" 'rc=0 writes=issue edit 7 --body=REPORT;issue comment 7 --body=TEXT;'
expect "PD33 a report without its marker line fails and writes nothing" \
  "$(issue_run "$ISSUE" 'npm lists a newer release.' '' '')" 'rc=1 writes='
expect "PD34 a report whose marker line is not first fails and writes nothing" \
  "$(issue_run "$ISSUE" "$(printf 'preface\n%s' "$NEXT_REPORT")" 7 "$NEXT_REPORT")" 'rc=1 writes='

notify_run() {
  local rc
  : > "$WORK/gh.log"
  GH_OPEN="$1" GH_LOG="$WORK/gh.log" GH_TOKEN=fixture REPO=fixture/repo RUN_URL=https://github.invalid/fixture/actions/runs/1 \
    PATH="$WORK/fakegh:$PATH" bash "$WORK/notify.sh" >/dev/null 2>&1
  rc=$?
  printf 'rc=%s writes=%s' "$rc" "$(writes)"
}
pd35="$(notify_run '')"
if [ "$pd35" = 'rc=0 writes=issue create --title=TEXT --label playwright-cli-drift-check --body=RUN;' ] \
  && grep -Fxq 'label create playwright-cli-drift-check --color=TEXT --description=TEXT --force' "$WORK/gh.log"; then
  check "PD35 a red scheduled run without an open tracking issue opens one under its label that names the run" PASS
else
  check "PD35 a red scheduled run without an open tracking issue opens one under its label that names the run (got '$pd35')" FAIL
fi
expect "PD36 a red scheduled run comments the run on the open tracking issue" "$(notify_run 9)" 'rc=0 writes=issue comment 9 --body=RUN;'

mutate() {
  node -e '
    const fs = require("fs");
    const [source, target, anchor, replacement] = process.argv.slice(1);
    const parts = fs.readFileSync(source, "utf8").split(anchor);
    if (parts.length !== 2) process.exit(3);
    fs.writeFileSync(target, parts.join(replacement));
  ' "$@"
}
MUTANT_TREE="$WORK/mutant"
mkdir -p "$MUTANT_TREE/.github/scripts"
ln -s "$ROOT/hooks" "$MUTANT_TREE/hooks"
MUTANT="$MUTANT_TREE/.github/scripts/playwright-cli-drift.sh"
mutant_drift() {
  local label="$1" anchor="$2" replacement="$3" want="$4" got
  shift 4
  if ! mutate "$DRIFT" "$MUTANT" "$anchor" "$replacement"; then
    check "$label (the mutation anchor is gone from the script)" FAIL
    return
  fi
  registry "$PACKAGE" "$@"
  got="$(drift_run "$MUTANT")"
  if [ "$got" = "$want" ]; then
    check "$label" PASS
  else
    check "$label (got '$got' want '$want')" FAIL
  fi
}
mutant_drift "PD37 a mutant that orders releases by text reports $NARROW, which PD15 refuses" \
  'compare(b, a) > 0 ? b : a' 'b > a ? b : a' "$(reported "$NARROW")" "$WIDE" "$MEASURED" "$NARROW"
mutant_drift "PD38 a mutant with an unanchored stable filter reports the prerelease, which PD12 refuses" \
  'const STABLE = /^([0-9]+)\.([0-9]+)\.([0-9]+)$/;' 'const STABLE = /^([0-9]+)\.([0-9]+)\.([0-9]+)/;' \
  "$(reported "$NEXT-alpha-1")" "$MEASURED" "$NEXT-alpha-1"
if mutate "$ISSUE" "$WORK/drift-issue-mutant.sh" '*"$marker"*)' '"$marker")'; then
  expect "PD39 a mutant that compares the whole issue body with the marker rewrites a named release, which PD31 refuses" \
    "$(issue_run "$WORK/drift-issue-mutant.sh" "$NEXT_REPORT" 7 "$CRLF_NEXT")" \
    'rc=0 writes=issue edit 7 --body=REPORT;issue comment 7 --body=TEXT;'
else
  check "PD39 a mutant that compares the whole issue body with the marker rewrites a named release (the mutation anchor is gone from the issue step)" FAIL
fi

finish
