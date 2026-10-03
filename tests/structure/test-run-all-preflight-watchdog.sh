#!/bin/bash
# tests/run-all.sh must bound every suite and must never hang on one.
#
# Two defects motivated this. (1) `out="$("$@" 2>&1)"` blocks until every writer
# closes the pipe, so a suite that leaves a background child alive stalls the
# whole runner with no indication which suite did it — observed with
# evals/config-gate, whose own runner uses the same construct. (2) GNU `timeout`
# does not exist on macOS, so there was no bound at all: a hang was
# indistinguishable from a slow suite, forever.
#
# The watchdog and the dependency preflight are EXTRACTED from run-all.sh and
# driven against hermetic fixtures, so this suite tests the real code rather
# than pinning its prose.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_ALL="$PLUGIN_DIR/tests/run-all.sh"

# The extracted harness defines its own PASS/FAIL/HANG/BLOCKED counters, so this
# suite keeps its tally under distinct names — sourcing must not reset it.
T_PASS=0; T_FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; T_PASS=$((T_PASS+1));
  else echo "  FAIL  $label"; T_FAIL=$((T_FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

WORK=""
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM
WORK="$(mktemp -d)" || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1

echo "== Source pins =="
[ -f "$RUN_ALL" ]
check "P1 tests/run-all.sh exists" "$(verdict $?)"
# The construct that caused the stall must be gone from run_suite.
awk '/^run_suite\(\) \{/,/^\}/' "$RUN_ALL" | grep -q 'out="\$("\$@"'
[ $? -ne 0 ]
check "P2 run_suite no longer captures suite output via command substitution" "$(verdict $?)"
grep -q 'SUITE_TIMEOUT="\${ZENSU_SUITE_TIMEOUT:-' "$RUN_ALL"
check "P3 a per-suite timeout exists and is overridable via ZENSU_SUITE_TIMEOUT" "$(verdict $?)"
grep -q 'HANG  \$label' "$RUN_ALL"
check "P4 a hang is reported as HANG, distinct from FAIL" "$(verdict $?)"
grep -q 'npm ci' "$RUN_ALL"
check "P5 the dependency preflight names the command that fixes it" "$(verdict $?)"
grep -q '\[ "\$FAIL" -eq 0 \] && \[ "\$HANG" -eq 0 \] && \[ "\$BLOCKED" -eq 0 \]' "$RUN_ALL"
check "P6 hung or blocked suites keep the run from exiting green" "$(verdict $?)"
# A suite must not inherit the runner's stdin, or it can block on a read.
awk '/^run_suite\(\) \{/,/^\}/' "$RUN_ALL" | grep -q '</dev/null'
check "P7 suites run with stdin closed so none can block on a read" "$(verdict $?)"

echo "== Behaviour: the extracted watchdog against real fixtures =="
# Extract the real function plus the preflight helpers, then drive them with
# stub counters. Testing the shipped code, not a re-implementation.
HARNESS="$WORK/harness.sh"
{
  echo 'PASS=0; FAIL=0; HANG=0; BLOCKED=0'
  echo 'REPORT="$WORK/report.txt"'
  echo 'log() { printf "%s\n" "$1" >> "$REPORT"; }'
  awk '/^SUITE_TIMEOUT=/{print}' "$RUN_ALL"
  awk '/^run_suite\(\) \{/,/^\}/' "$RUN_ALL"
  awk '/^deps_ready\(\)/{print}' "$RUN_ALL"
  awk '/^block_suite\(\) \{/,/^\}/' "$RUN_ALL"
} > "$HARNESS"

grep -q 'run_suite()' "$HARNESS" && grep -q 'block_suite()' "$HARNESS"
check "B0 watchdog + preflight helpers extracted from the shipped runner" "$(verdict $?)"

# Fixture suites.
printf '#!/bin/bash\necho hello\nexit 0\n'                       > "$WORK/ok.sh"
printf '#!/bin/bash\necho nope\nexit 3\n'                        > "$WORK/bad.sh"
printf '#!/bin/bash\necho starting\nsleep 900\n'                 > "$WORK/hang.sh"
# Exits immediately but leaves a child holding the inherited stdout for a long
# time — the exact shape that stalls a command substitution.
printf '#!/bin/bash\necho quick\n( sleep 900 ) &\nexit 0\n'      > "$WORK/lingering.sh"
chmod +x "$WORK"/*.sh

# shellcheck disable=SC1090
WORK="$WORK" SUITE_TIMEOUT=3 . "$HARNESS"
SUITE_TIMEOUT=3

run_suite "ok" bash "$WORK/ok.sh"
{ [ "$PASS" -eq 1 ] && [ "$FAIL" -eq 0 ] && [ "$HANG" -eq 0 ]; }
check "B1 a passing suite still counts as PASS" "$(verdict $?)"

run_suite "bad" bash "$WORK/bad.sh"
{ [ "$FAIL" -eq 1 ] && [ "$HANG" -eq 0 ]; }
check "B2 a failing suite still counts as FAIL, not HANG" "$(verdict $?)"

START="$(date +%s)"
run_suite "lingering" bash "$WORK/lingering.sh"
ELAPSED=$(( $(date +%s) - START ))
{ [ "$PASS" -eq 2 ] && [ "$ELAPSED" -lt 3 ]; }
check "B3 a suite leaving a background child returns immediately (elapsed ${ELAPSED}s) — the stall is gone" "$(verdict $?)"

START="$(date +%s)"
run_suite "hang" bash "$WORK/hang.sh"
ELAPSED=$(( $(date +%s) - START ))
{ [ "$HANG" -eq 1 ] && [ "$ELAPSED" -lt 20 ]; }
check "B4 a hanging suite is killed at the bound and counted as HANG (elapsed ${ELAPSED}s)" "$(verdict $?)"
grep -q "HANG  hang" "$WORK/report.txt"
check "B5 the hang is named in the report with its label" "$(verdict $?)"
# The suite's partial output must survive, or a hang gives no diagnostic at all.
grep -q "starting" "$WORK/report.txt"
check "B6 output produced before the kill is preserved for diagnosis" "$(verdict $?)"

echo "== Behaviour: dependency preflight =="
NODE_DEPS_OK=1
deps_ready
check "D1 deps_ready is true when node_modules is present" "$(verdict $?)"
NODE_DEPS_OK=0
deps_ready
[ $? -ne 0 ]
check "D2 deps_ready is false when node_modules is absent" "$(verdict $?)"
BEFORE="$BLOCKED"
block_suite "some/suite"
{ [ "$BLOCKED" -eq $((BEFORE + 1)) ] && grep -q "BLOCK some/suite" "$WORK/report.txt"; }
check "D3 a blocked suite is counted and reported as BLOCK, never as PASS" "$(verdict $?)"
grep -q "npm ci" "$WORK/report.txt"
check "D4 the BLOCK line carries the actionable command" "$(verdict $?)"

echo "== Behaviour: nodeDepsStructureTests decides which structure suites report BLOCK =="
FIX="$WORK/runner"
mkdir -p "$FIX/tests/structure" "$FIX/tests/profiles"
cp "$RUN_ALL" "$FIX/tests/run-all.sh"
for SUITE in test-deps-ci.sh test-deps-local.sh test-plain-ci.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$FIX/tests/structure/$SUITE"
done
fixture_manifest() {
  printf '{"schemaVersion":1,"ciStructureTests":["test-deps-ci.sh","test-plain-ci.sh"],"localStructureTests":["test-deps-local.sh"],%s"ciOfflineSuites":[]}\n' "$1" \
    > "$FIX/tests/profiles/promptfoo-local-only.v1.json"
}
fixture_manifest '"nodeDepsStructureTests":["test-deps-ci.sh","test-deps-local.sh"],'
bash "$FIX/tests/run-all.sh" > "$WORK/no-deps.txt" 2>&1
NO_DEPS_RC=$?
{ [ "$NO_DEPS_RC" -ne 0 ] \
  && grep -q 'BLOCK structure/test-deps-ci.sh' "$WORK/no-deps.txt" \
  && grep -q 'BLOCK structure/test-deps-local.sh' "$WORK/no-deps.txt" \
  && grep -q 'PASS  structure/test-plain-ci.sh' "$WORK/no-deps.txt" \
  && grep -q '1 passed / 0 failed / 0 hung / 2 blocked' "$WORK/no-deps.txt"; }
check "D5 without node_modules every listed suite, CI and local alike, reports BLOCK while the rest still runs" "$(verdict $?)"
mkdir "$FIX/node_modules"
bash "$FIX/tests/run-all.sh" --ci > "$WORK/deps.txt" 2>&1
DEPS_RC=$?
{ [ "$DEPS_RC" -eq 0 ] \
  && grep -q 'PASS  structure/test-deps-ci.sh' "$WORK/deps.txt" \
  && ! grep -q 'BLOCK structure/' "$WORK/deps.txt"; }
check "D6 with node_modules a listed suite runs instead of reporting BLOCK" "$(verdict $?)"
REFUSED=""
for ENTRY in '' '"nodeDepsStructureTests":["test-deps-ci.sh","test-deps-ci.sh"],' '"nodeDepsStructureTests":["test-unclassified.sh"],'; do
  fixture_manifest "$ENTRY"
  bash "$FIX/tests/run-all.sh" --ci > "$WORK/refused.txt" 2>&1
  REFUSED_RC=$?
  { [ "$REFUSED_RC" -eq 2 ] && ! grep -q 'structure/test-' "$WORK/refused.txt"; } \
    || REFUSED="$REFUSED rc=$REFUSED_RC:${ENTRY:-absent}"
done
[ -z "$REFUSED" ]
check "D7 run-all refuses an absent nodeDepsStructureTests, a duplicate entry and an unclassified one before any suite runs${REFUSED:+ (accepted:$REFUSED)}" "$(verdict $?)"

echo "== Source scan: every npm-dependent structure suite is in nodeDepsStructureTests =="
SCAN="$WORK/npm-scan.js"
cat > "$SCAN" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const readJson = (file) => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'));
const pkg = readJson('package.json');
const lock = fs.existsSync(path.join(root, 'package-lock.json')) ? readJson('package-lock.json') : {};
const manifest = readJson('tests/profiles/promptfoo-local-only.v1.json');
const dir = path.join(root, 'tests', 'structure');
const any = (names) => (names.length
  ? names.map((name) => name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')
  : '(?!)');
const packages = Object.keys({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.optionalDependencies });
const bins = [...new Set(packages.flatMap((name) => [
  name,
  ...Object.keys(((lock.packages || {})[`node_modules/${name}`] || {}).bin || {}),
]))];
const scripts = Object.keys(pkg.scripts || {});
const specifier = `["'](?:${any(packages)})(?:/[^"']*)?["']`;
const needs = new RegExp([
  `\\brequire\\(\\s*${specifier}\\s*\\)`,
  `\\bimport\\(\\s*${specifier}\\s*\\)`,
  `\\bfrom\\s*${specifier}`,
  `\\bnode_modules/(?:\\.bin/(?:${any(bins)})\\b|(?:${any(packages)})/)`,
  `\\b(?:npx|npm\\s+exec)\\s+(?:-\\S+\\s+)*(?:${any(bins)})(?![\\w.-])`,
  `\\bnpm\\s+(?:run|run-script)\\s+(?:${any(scripts)})(?![\\w:.-])`,
].join('|'));
const code = (file) => fs.readFileSync(file, 'utf8').split('\n')
  .filter((line) => !/^\s*(#|\/\/|\/?\*)/.test(line)).join('\n');
const closure = (file, seen) => {
  if (seen.has(file) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return seen;
  seen.add(file);
  for (const [, relative] of code(file).matchAll(/\brequire\(\s*["'](\.{1,2}\/[^"']+)["']\s*\)/g)) {
    const target = path.resolve(path.dirname(file), relative);
    closure(fs.existsSync(target) ? target : `${target}.js`, seen);
  }
  return seen;
};
const flagged = [...manifest.ciStructureTests, ...manifest.localStructureTests].filter((suite) => {
  const source = path.join(dir, suite);
  const units = [...new Set(code(source).match(/[\w.-]+\.test\.js/g) || [])]
    .map((unit) => path.join(dir, unit))
    .filter((unit) => fs.existsSync(unit));
  const files = units.reduce((seen, unit) => closure(unit, seen), new Set([source]));
  return [...files].some((file) => needs.test(code(file)));
});
if (flagged.length) process.stdout.write(`${flagged.sort().join('\n')}\n`);
NODE
SCAN_FIX="$WORK/scan"
node - "$SCAN_FIX" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
const files = {
  'package.json': JSON.stringify({
    dependencies: { 'zensu-fixture-runtime': '1.0.0' },
    devDependencies: { 'zensu-fixture-cli': '1.0.0', 'zensu-fixture-parser': '1.0.0' },
    scripts: { 'fixture:cover': 'zensu-fixture-bin bash cover.sh' },
  }),
  'package-lock.json': JSON.stringify({
    packages: { 'node_modules/zensu-fixture-cli': { bin: { 'zensu-fixture-bin': 'bin/cli.js' } } },
  }),
  'tests/profiles/promptfoo-local-only.v1.json': JSON.stringify({
    ciStructureTests: [
      'test-bin.sh', 'test-decoys.sh', 'test-import.sh', 'test-npm-exec.sh', 'test-npm-run.sh',
      'test-npx.sh', 'test-own-require.sh', 'test-package-path.sh', 'test-transitive.sh',
      'test-unit-require.sh',
    ],
    localStructureTests: ['test-local-require.sh'],
  }),
  'tests/structure/test-own-require.sh': 'node -e "const parser = require(\'zensu-fixture-parser\');"\n',
  'tests/structure/test-unit-require.sh': 'node --test "$DIR/unit-require.test.js"\n',
  'tests/structure/unit-require.test.js': "const parse = require('zensu-fixture-parser/lib/parse.js');\n",
  'tests/structure/test-transitive.sh': 'node --test "$DIR/transitive.test.js"\n',
  'tests/structure/transitive.test.js': "require('./transitive-helper');\n",
  'tests/structure/transitive-helper.js': "require('../lib/deep.js');\n",
  'tests/lib/deep.js': "module.exports = require('zensu-fixture-runtime');\n",
  'tests/structure/test-import.sh': 'node --input-type=module -e "import parser from \'zensu-fixture-parser\';"\n',
  'tests/structure/test-bin.sh': '"$ROOT/node_modules/.bin/zensu-fixture-bin" --version\n',
  'tests/structure/test-package-path.sh': 'node "$ROOT/node_modules/zensu-fixture-cli/bin/cli.js"\n',
  'tests/structure/test-npx.sh': 'npx -y zensu-fixture-cli report\n',
  'tests/structure/test-npm-exec.sh': 'npm exec -- zensu-fixture-bin report\n',
  'tests/structure/test-npm-run.sh': 'npm run fixture:cover\n',
  'tests/structure/test-local-require.sh': 'node -e \'require("zensu-fixture-cli")\'\n',
  'tests/structure/test-decoys.sh': [
    '# node -e "require(\'zensu-fixture-parser\')"',
    "node - <<'JS'",
    "// const parser = require('zensu-fixture-parser');",
    'JS',
    'node -e \'require("playwright")\'',
    'node -e \'require("zensu-fixture-parserish")\'',
    'npm run lint',
    'npm run fixture:cover-all',
    'npx @playwright/cli snapshot',
    'mkdir -p "$BIN/node_modules/@playwright/cli"',
    'node -p \'require("./package-lock.json").packages["node_modules/zensu-fixture-cli"].version\'',
    'node --test "$DIR/decoy.test.js"',
    '',
  ].join('\n'),
  'tests/structure/decoy.test.js': [
    "/* require('zensu-fixture-parser') */",
    " * const parser = require('zensu-fixture-parser');",
    "// import parser from 'zensu-fixture-parser';",
    '',
  ].join('\n'),
};
for (const [name, content] of Object.entries(files)) {
  fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
  fs.writeFileSync(path.join(root, name), content);
}
NODE
node "$SCAN" "$SCAN_FIX" > "$WORK/scan-fixture.txt"
SCAN_FIX_RC=$?
GOT_SCAN="$(tr '\n' ' ' < "$WORK/scan-fixture.txt")"
WANT_SCAN='test-bin.sh test-import.sh test-local-require.sh test-npm-exec.sh test-npm-run.sh test-npx.sh test-own-require.sh test-package-path.sh test-transitive.sh test-unit-require.sh '
{ [ "$SCAN_FIX_RC" -eq 0 ] && [ "$GOT_SCAN" = "$WANT_SCAN" ]; }
check "D8 the scan flags every require, import, binary and npm-script form, and no comment, undeclared package or fixture path (got: ${GOT_SCAN:-nothing})" "$(verdict $?)"
MANIFEST="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
LISTED="$(node -e 'process.stdout.write(require(process.argv[1]).nodeDepsStructureTests.join("\n"))' "$MANIFEST")"
node "$SCAN" "$PLUGIN_DIR" > "$WORK/npm-dependent.txt"
SCAN_RC=$?
MISSING=""
for SUITE in $(cat "$WORK/npm-dependent.txt"); do
  printf '%s\n' "$LISTED" | grep -Fxq -- "$SUITE" || MISSING="$MISSING $SUITE"
done
{ [ "$SCAN_RC" -eq 0 ] && [ -s "$WORK/npm-dependent.txt" ] && [ -z "$MISSING" ]; }
check "D9 every structure suite whose code needs an npm package is listed in nodeDepsStructureTests${MISSING:+ (missing:$MISSING)}" "$(verdict $?)"

echo "----"
echo "test-run-all-preflight-watchdog: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
