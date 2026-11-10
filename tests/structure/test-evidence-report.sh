#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LIB="$PLUGIN_DIR/hooks/lib/evidence-report-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/evidence-report-v1.test.js"
CORPUS="$PLUGIN_DIR/tests/fixtures/evidence-report/v1/cases"
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
  echo "test-evidence-report: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LOG" "$LIB" "$UNIT" "$PROFILE" "$CORPUS/render-matrix-pass/manifest.json"; do
  if [ ! -f "$f" ]; then
    check "R0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "R0 node and git are available" FAIL
  finish
  exit 1
fi
check "R0 required files, node and git are present" PASS

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-evidence-report.sh") ? 0 : 1);
' "$PROFILE"; then
  check "R0a the suite is classified as a CI structure test" PASS
else
  check "R0a the suite is classified as a CI structure test" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "R0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

unit_check "R0b the evidence-report unit file passes" "$UNIT"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{}\n' > "$ZENSU_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_EDIT_LANDING_GATE ZENSU_ACCEPTANCE_GATE 2>/dev/null || true

PROJ="$WORK/project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'v1\n' > "$PROJ/tracked.txt"
git -C "$PROJ" add .gitignore tracked.txt
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline
git -C "$PROJ" remote add origin https://github.com/example/demo.git
RUN="$PROJ/.zensu/verify-feature-runs/r1"
mkdir -p "$RUN"
PNG_SOURCE=""
for candidate in "$CORPUS"/render-matrix-pass/files/*.png; do PNG_SOURCE="$candidate"; done
cp "$PNG_SOURCE" "$RUN/shot.png"
printf 'GET /settings 200\nPUT /api/settings 200\n' > "$RUN/console.txt"
FAKE_TOKEN="ghp_$(printf 'Q7mZ%.0s' 1 2 3 4 5 6 7 8 9)"

export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || exit 1
if ! source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "report-main"; then
  check "R0c a Session Control session binds" FAIL
  finish
  exit 1
fi
check "R0c a Session Control session binds" PASS

OUT="$WORK/out"
ERRF="$WORK/err"
show() { cat "$OUT" "$ERRF" 2>/dev/null; }

bash "$LOG" --report-begin --run-dir "$RUN" --drivers browser,api >"$OUT" 2>"$ERRF" <<'EOF'
feature: The settings page saves the chosen locale
AC-001: The locale persists after a reload
AC-002: The API answers 200
EOF
RC=$?
ID="$(sed -n 's/^zensu evidence report: begun \(vr1_[0-9]*_[0-9a-f]*\) .*/\1/p' "$OUT")"
BUNDLE="$(sed -n 's/^zensu evidence report: bundle //p' "$OUT")"
if [ "$RC" -eq 0 ] && [ -n "$ID" ] && [ -d "$BUNDLE" ] \
  && grep -q '| local | drivers browser, api | criteria AC-001, AC-002$' "$OUT" \
  && [ -f "$(dirname "$BUNDLE")/$ID.binding.json" ]; then
  check "R1 --report-begin creates a report and its binding in the plugin data store" PASS
else
  check "R1 --report-begin creates a report and its binding in the plugin data store (rc=$RC)" FAIL
  show
fi
case "$BUNDLE" in
  "$ZENSU_TEST_PLUGIN_DATA"/evidence-report/v1/*) check "R1a the default store lies in the plugin data directory" PASS ;;
  *) check "R1a the default store lies in the plugin data directory: $BUNDLE" FAIL ;;
esac

bash "$LOG" --report-add --report "$ID" --kind image --file "$RUN/shot.png" --viewport 1440x900@2 >"$OUT" 2>"$ERRF" <<'EOF'
The settings page after a reload shows the new locale
EOF
RC=$?
if [ "$RC" -eq 0 ] && grep -q "^zensu evidence report: e1 added to $ID | image | image/png " "$OUT"; then
  check "R2 --report-add copies an image with its caption from stdin" PASS
else
  check "R2 --report-add copies an image with its caption from stdin (rc=$RC)" FAIL
  show
fi

(cd "$RUN" && bash "$LOG" --report-add --report "$ID" --kind text --file console.txt >"$OUT" 2>"$ERRF" <<'EOF'
The request log of the save
EOF
)
RC=$?
if [ "$RC" -eq 0 ] && grep -q "^zensu evidence report: e2 added to $ID | text | text/plain " "$OUT"; then
  check "R3 --report-add resolves a file named relative to the working directory" PASS
else
  check "R3 --report-add resolves a file named relative to the working directory (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-add --report "$ID" --kind request --method PUT --path /api/settings --status 200 </dev/null >"$OUT" 2>"$ERRF"
RC=$?
if [ "$RC" -eq 0 ] && grep -q "^zensu evidence report: e3 added to $ID | request | PUT /api/settings 200$" "$OUT"; then
  check "R4 a request item needs no stdin" PASS
else
  check "R4 a request item needs no stdin (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-add --report "$ID" --kind image --file "$RUN/shot.png" --caption "free text" >"$OUT" 2>"$ERRF" </dev/null
RC=$?
if [ "$RC" -eq 2 ] && grep -qF 'zensu-log.sh --report-add: unknown argument: --caption (a caption, a title, a feature and every other free text go on stdin)' "$ERRF"; then
  check "R5 no free-text flag exists: --caption is refused before the module runs" PASS
else
  check "R5 no free-text flag exists: --caption is refused before the module runs (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-add --report "$ID" --kind image --kind text >"$OUT" 2>"$ERRF" </dev/null
RC1=$?
bash "$LOG" --report-add --report "$ID" --kind >"$WORK/out2" 2>"$WORK/err2" </dev/null
RC2=$?
if [ "$RC1" -eq 2 ] && grep -qF -- '--kind is given more than once' "$ERRF" \
  && [ "$RC2" -eq 2 ] && grep -qF -- '--kind needs a value' "$WORK/err2"; then
  check "R6 a repeated flag and a flag without its value are refused" PASS
else
  check "R6 a repeated flag and a flag without its value are refused (rc=$RC1/$RC2)" FAIL
  show
  cat "$WORK/err2"
fi

bash "$LOG" --report-add --report "$ID" --kind text --file "$PROJ/tracked.txt" >"$OUT" 2>"$ERRF" <<'EOF'
A file outside the run directory
EOF
RC=$?
if [ "$RC" -eq 1 ] && grep -q "^zensu-log.sh --report-add: the evidence file .*tracked.txt lies outside the run directory" "$ERRF"; then
  check "R7 a file outside the run directory is refused with the module's reason under the verb's label" PASS
else
  check "R7 a file outside the run directory is refused with the module's reason under the verb's label (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-step --report "$ID" --priority P0 --driver browser --result pass --criteria AC-001 --evidence e1,e2 >"$OUT" 2>"$ERRF" <<'EOF'
title: Save the locale
expected: The page shows the new locale after a reload
observed: The page shows the new locale after a reload
EOF
RC1=$?
bash "$LOG" --report-step --report "$ID" --priority P1 --driver api --result pass --criteria AC-002 --evidence e3 >"$WORK/out2" 2>"$WORK/err2" <<'EOF'
title: The API stores the locale
expected: The request answers 200
observed: The request answered 200
EOF
RC2=$?
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && grep -q "^zensu evidence report: step 1 written to $ID | P0 browser pass | criteria AC-001 | evidence e1, e2$" "$OUT" \
  && grep -q "^zensu evidence report: step 2 written to $ID " "$WORK/out2"; then
  check "R8 --report-step writes numbered rows from stdin fields" PASS
else
  check "R8 --report-step writes numbered rows from stdin fields (rc=$RC1/$RC2)" FAIL
  show
  cat "$WORK/out2" "$WORK/err2"
fi

bash "$LOG" --report-step --report "$ID" --priority P2 --driver browser --result pass >"$OUT" 2>"$ERRF" <<EOF
title: Read the token
expected: Nothing leaks
observed: The page shows $FAKE_TOKEN
EOF
RC=$?
if [ "$RC" -eq 1 ] && grep -q 'secret pattern' "$ERRF" && ! grep -qF "$FAKE_TOKEN" "$OUT" "$ERRF" \
  && ! grep -rqF "$FAKE_TOKEN" "$ZENSU_TEST_PLUGIN_DATA/evidence-report"; then
  check "R9 a secret on stdin is refused and written nowhere" PASS
else
  check "R9 a secret on stdin is refused and written nowhere (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-render --report "$ID" --verdict PASS --console clean --network clean >"$OUT" 2>"$ERRF" <<'EOF'
limitation: No mobile viewport was checked
consent: http://localhost:3000 /settings asked
EOF
RC=$?
HTML="$(sed -n 's/^Evidence report: //p' "$OUT")"
if [ "$RC" -eq 0 ] && [ "$HTML" = "$BUNDLE/index.html" ] && [ -f "$HTML" ] && [ -f "$BUNDLE/manifest.json" ] \
  && ! grep -qi '<script' "$HTML" && grep -q '<h2>Coverage</h2>' "$HTML" \
  && ! grep -qF "$RUN" "$HTML" "$BUNDLE/manifest.json"; then
  check "R10 --report-render writes the manifest and a static index.html that names no run-directory path" PASS
else
  check "R10 --report-render writes the manifest and a static index.html that names no run-directory path (rc=$RC)" FAIL
  show
fi

if node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const ok = m.schema === "zensu-evidence-report/v1" && m.run.host === "claude-code" && m.verdict === "PASS"
    && m.target.repository === "example/demo" && m.coverage.source === "matrix"
    && m.coverage.criteria.map((c) => `${c.id}:${c.state}`).join(",") === "AC-001:pass,AC-002:pass"
    && m.sections.consent.length === 1 && m.sections.limitations[0] === "No mobile viewport was checked";
  process.exit(ok ? 0 : 1);
' "$BUNDLE/manifest.json"; then
  check "R11 the manifest names the host, the target and the coverage the verbs recorded" PASS
else
  check "R11 the manifest names the host, the target and the coverage the verbs recorded" FAIL
fi

bash "$LOG" --report-list >"$OUT" 2>"$ERRF"
RC=$?
if [ "$RC" -eq 0 ] && grep -q "^$ID | rendered | PASS | " "$OUT"; then
  check "R12 --report-list shows the rendered report" PASS
else
  check "R12 --report-list shows the rendered report (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-export --report "$ID" >"$OUT" 2>"$ERRF"
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$BUNDLE/export.html" ] && grep -q 'src="data:image/png;base64,' "$BUNDLE/export.html" \
  && ! grep -q '<a ' "$BUNDLE/export.html"; then
  check "R13 --report-export writes one self-contained page" PASS
else
  check "R13 --report-export writes one self-contained page (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-add --report "$ID" --kind request --method GET --path / --status 200 >"$OUT" 2>"$ERRF" </dev/null
RC=$?
if [ "$RC" -eq 1 ] && grep -q 'rendered and immutable' "$ERRF"; then
  check "R14 a rendered report is immutable" PASS
else
  check "R14 a rendered report is immutable (rc=$RC)" FAIL
  show
fi

env -u CLAUDE_CODE_SESSION_ID bash "$LOG" --report-list >"$OUT" 2>"$ERRF"
RC=$?
if [ "$RC" -eq 2 ] && grep -q 'rendered Session Control binding unavailable' "$ERRF"; then
  check "R15 the verbs bind to the session and refuse without one" PASS
else
  check "R15 the verbs bind to the session and refuse without one (rc=$RC)" FAIL
  show
fi

printf '{"evidence":{"report":{"enabled":false}}}\n' > "$WORK/disabled.json"
ZENSU_CONFIG="$WORK/disabled.json" bash "$LOG" --report-begin --run-dir "$RUN" --drivers browser >"$OUT" 2>"$ERRF" <<'EOF'
feature: A report that is switched off
EOF
RC=$?
if [ "$RC" -eq 3 ] && grep -q 'not begun, because evidence.report.enabled is false' "$OUT"; then
  check "R16 evidence.report.enabled false answers exit 3 and begins nothing" PASS
else
  check "R16 evidence.report.enabled false answers exit 3 and begins nothing (rc=$RC)" FAIL
  show
fi

printf '{"evidence":{"fullSuiteGate":"advisory","report":{"enabled":false,"dir":"/srv/reports","keep":3,"maxBytes":10,"other":1}}}\n' > "$WORK/reader.json"
READ_ALL="$(ZENSU_CONFIG="$WORK/reader.json" bash -c 'source "$1/hooks/lib/zensu-config.sh"; zensu_evidence_report_config_json' _ "$PLUGIN_DIR")"
READ_NONE="$(bash -c 'source "$1/hooks/lib/zensu-config.sh"; zensu_evidence_report_config_json' _ "$PLUGIN_DIR")"
if [ "$READ_ALL" = '{"enabled":false,"dir":"/srv/reports","keep":3,"maxBytes":10}' ] && [ "$READ_NONE" = '{}' ]; then
  check "R17 the config reader hands the four evidence.report keys to the module unjudged" PASS
else
  check "R17 the config reader hands the four evidence.report keys to the module unjudged ($READ_ALL / $READ_NONE)" FAIL
fi

mkdir -p "$WORK/layers/home/.zensu" "$WORK/layers/project/.zensu"
printf '{"evidence":{"report":{"maxBytes":5000}}}\n' > "$WORK/layers/home/.zensu/config.json"
printf '{"evidence":{"report":{"keep":2,"maxBytes":1}}}\n' > "$WORK/layers/project/.zensu/config.json"
READ_LAYERS="$(env -u ZENSU_CONFIG HOME="$WORK/layers/home" CLAUDE_PROJECT_DIR="$WORK/layers/project" bash -c 'source "$1/hooks/lib/zensu-config.sh"; zensu_evidence_report_config_json' _ "$PLUGIN_DIR")"
if [ "$READ_LAYERS" = '{"keep":2,"maxBytes":5000,"maxBytesFromProject":true}' ]; then
  check "R17a the store-wide maxBytes comes from the user layers only, and a project value is flagged" PASS
else
  check "R17a the store-wide maxBytes comes from the user layers only, and a project value is flagged ($READ_LAYERS)" FAIL
fi

STEM="2026-11-09-0100_build-report-fixture"
RUN_LOG="./.zensu/logs/$STEM.log"
mkdir -p "$PROJ/.zensu/plans" "$PROJ/.zensu/logs"
cat > "$PROJ/.zensu/plans/$STEM.md" <<'PLAN'
# Fixture plan

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the dashboard lists every project | spec |
| AC-002 | the empty state explains how to add a project | spec |
PLAN
printf 'v2\n' > "$PROJ/tracked.txt"
printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/$STEM.log"
bash "$LOG" --tdd-begin >/dev/null 2>&1
bash "$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh" --log "$PROJ/.zensu/logs/$STEM.log" --project "$PROJ" \
  --session "report-main" >/dev/null 2>&1
printf 'Only the desktop layout was checked\n' | bash "$LOG" --acceptance-record --ac AC-002 --verdict partial --driver browser --log "$RUN_LOG" >"$OUT" 2>"$ERRF"
RC0=$?
bash "$LOG" --report-begin --run-dir "$RUN" --drivers browser --log "$RUN_LOG" >"$OUT" 2>"$ERRF" <<'EOF'
feature: The dashboard of the fixture chain
EOF
RC=$?
CHAIN_ID="$(sed -n 's/^zensu evidence report: begun \(vr1_[0-9]*_[0-9a-f]*\) .*/\1/p' "$OUT")"
CHAIN_BUNDLE="$(sed -n 's/^zensu evidence report: bundle //p' "$OUT")"
if [ "$RC0" -eq 0 ] && [ "$RC" -eq 0 ] && [ -n "$CHAIN_ID" ] && grep -q "| chain $STEM$" "$OUT"; then
  check "R18 --report-begin --log binds the report to the chain the edit-landing receipt names" PASS
else
  check "R18 --report-begin --log binds the report to the chain the edit-landing receipt names (rc=$RC0/$RC)" FAIL
  show
fi

bash "$LOG" --report-render --report "$CHAIN_ID" --verdict PARTIAL >"$OUT" 2>"$ERRF" </dev/null
RC=$?
if [ "$RC" -eq 1 ] && grep -q 'is in chain mode; pass --log' "$ERRF"; then
  check "R19 a chain report renders only with its run log" PASS
else
  check "R19 a chain report renders only with its run log (rc=$RC)" FAIL
  show
fi

bash "$LOG" --report-render --report "$CHAIN_ID" --verdict PARTIAL --log "$RUN_LOG" >"$OUT" 2>"$ERRF" </dev/null
RC=$?
if [ "$RC" -eq 0 ] && node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const states = m.coverage.criteria.map((c) => `${c.id}:${c.state}`).join(",");
  process.exit(m.coverage.source === "acceptance-records" && m.run.chain.plan === `.zensu/plans/${process.argv[2]}.md` && states === "AC-001:missing,AC-002:partial" ? 0 : 1);
' "$CHAIN_BUNDLE/manifest.json" "$STEM"; then
  check "R20 --report-render --log folds the chain's acceptance states into the coverage" PASS
else
  check "R20 --report-render --log folds the chain's acceptance states into the coverage (rc=$RC)" FAIL
  show
fi

unit_check_done "R0z every unit file the registry gives this suite was graded"
finish
