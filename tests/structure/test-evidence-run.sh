#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$PLUGIN_DIR/hooks/lib/evidence-run-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/evidence-run-v1.test.js"
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
  echo "test-evidence-run: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LIB" "$UNIT" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "E0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
check "E0 all required files exist" PASS

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "E0 node and git are available" FAIL
  finish
  exit 1
fi
check "E0 node and git are available" PASS

WORK="$(mktemp -d 2>/dev/null)" || { check "E0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT

if node --test "$UNIT" >"$WORK/unit.out" 2>&1; then
  check "E1 the unit suite passes (node --test evidence-run-v1.test.js)" PASS
else
  check "E1 the unit suite passes (node --test evidence-run-v1.test.js)" FAIL
  sed -n '1,60p' "$WORK/unit.out"
fi

if unit_cases_meet_floor "$WORK/unit.out" 40; then
  check "E1a the unit suite registered at least 40 passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" PASS
else
  check "E1a the unit suite registered at least 40 passing cases (tests=$UNIT_CASES_TESTS pass=$UNIT_CASES_PASS)" FAIL
fi

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-evidence-run.sh") ? 0 : 1);
' "$PROFILE"; then
  check "E2 the suite is classified as a CI structure test" PASS
else
  check "E2 the suite is classified as a CI structure test" FAIL
fi

LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{}\n' > "$ZENSU_CONFIG"
PROJ="$WORK/project"
mkdir -p "$PROJ"
PROJ="$(cd -P "$PROJ" && pwd -P)"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'baseline\n' > "$PROJ/tracked.txt"
git -C "$PROJ" add .gitignore tracked.txt
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline
unset CLAUDE_AGENT_TYPE 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || { check "E3 project directory" FAIL; finish; exit 1; }

if source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "evidence-run-cli"; then
  check "E3 a Session Control baseline binds the test session" PASS
else
  check "E3 a Session Control baseline binds the test session" FAIL
  finish
  exit 1
fi
RECORDS="$ZENSU_TEST_PLUGIN_DATA/evidence-run/v1/records/${ZENSU_SESSION_KEY:-missing}"

OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'echo suite-ok' 2>"$WORK/e4.err")"; RC=$?
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q 'full output: ' \
  && printf '%s' "$OUT" | grep -q '^suite-ok$' \
  && printf '%s' "$OUT" | grep -q 'zensu evidence-run: scope=full exit=0 ' \
  && [ "$(ls "$RECORDS" 2>/dev/null | grep -c '\.json$')" = "1" ]; then
  check "E4 a green full run exits 0, prints the tail and summary, and writes one record" PASS
else
  check "E4 a green full run exits 0, prints the tail and summary, and writes one record (rc=$RC)" FAIL
  printf '%s\n' "$OUT"; cat "$WORK/e4.err"
fi

OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'echo broken; exit 5' 2>/dev/null)"; RC=$?
if [ "$RC" -eq 5 ] && printf '%s' "$OUT" | grep -q 'exit=5 '; then
  check "E5 a red run passes the suite's exit code through" PASS
else
  check "E5 a red run passes the suite's exit code through (rc=$RC)" FAIL
fi

OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'false | cat' 2>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ]; then
  check "E6 a failing pipeline fails under the runner's pipefail" PASS
else
  check "E6 a failing pipeline fails under the runner's pipefail (rc=$RC)" FAIL
fi

PROBE='echo "k=${ZENSU_SESSION_KEY-unset} d=${CLAUDE_PLUGIN_DATA-unset} r=${CLAUDE_PLUGIN_ROOT-unset} pd=${CLAUDE_PROJECT_DIR-unset}"'
OUT="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG" --evidence-run --scope scoped --cmd "$PROBE" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF "k=unset d=unset r=unset pd=$PROJ"; then
  check "E7 the suite sees no plugin bindings and the caller's CLAUDE_PROJECT_DIR" PASS
else
  check "E7 the suite sees no plugin bindings and the caller's CLAUDE_PROJECT_DIR (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

OUT="$(bash "$LOG" --evidence-run --scope scoped --cmd 'pwd' 2>/dev/null)"; RC=$?
mkdir -p "$PROJ/nested"
OUT_NESTED="$(cd "$PROJ/nested" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd' 2>/dev/null)"; RC_NESTED=$?
if [ "$RC" -eq 0 ] && [ "$RC_NESTED" -eq 0 ] && printf '%s' "$OUT_NESTED" | grep -q '/nested$'; then
  check "E8 the suite runs in the caller's working directory" PASS
else
  check "E8 the suite runs in the caller's working directory (rc=$RC/$RC_NESTED)" FAIL
fi

printf '{"evidence":{"fullSuiteCommand":"echo configured-suite"}}\n' > "$ZENSU_CONFIG"
OUT="$(bash "$LOG" --evidence-run --scope full 2>/dev/null)"; RC=$?
ERR="$(bash "$LOG" --evidence-run --scope full --cmd 'true' 2>&1 >/dev/null)"; RC_MISMATCH=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^configured-suite$' \
  && [ "$RC_MISMATCH" -eq 2 ] && printf '%s' "$ERR" | grep -q 'differs from evidence.fullSuiteCommand'; then
  check "E9 evidence.fullSuiteCommand is the default and a different --cmd is refused" PASS
else
  check "E9 evidence.fullSuiteCommand is the default and a different --cmd is refused (rc=$RC/$RC_MISMATCH)" FAIL
fi
printf '{}\n' > "$ZENSU_CONFIG"

mkdir -p "$PROJ/.zensu/logs"
RUN_LOG="$PROJ/.zensu/logs/2026-01-01-0000_tdd-evidence.log"
: > "$RUN_LOG"
bash "$LOG" --evidence-run --scope lint --cmd 'echo lint-ok' --log "$RUN_LOG" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'EVIDENCE RUN — scope=lint exit=0 .* | cmd: echo lint-ok$' "$RUN_LOG"; then
  check "E10 --log appends one machine-authored run-log line" PASS
else
  check "E10 --log appends one machine-authored run-log line (rc=$RC)" FAIL
  cat "$RUN_LOG"
fi

bash "$LOG" --evidence-run --scope full --cmd 'true' >/dev/null 2>&1
OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'true' --if-stale 2>/dev/null)"; RC=$?
BEFORE="$(ls "$RECORDS" | grep -c '\.json$')"
printf 'edited\n' > "$PROJ/tracked.txt"
bash "$LOG" --evidence-run --scope full --cmd 'true' --if-stale >/dev/null 2>&1
AFTER="$(ls "$RECORDS" | grep -c '\.json$')"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'skipped (--if-stale)' && [ "$AFTER" -eq $((BEFORE + 1)) ]; then
  check "E11 --if-stale skips a fresh green record and runs after an edit" PASS
else
  check "E11 --if-stale skips a fresh green record and runs after an edit (rc=$RC before=$BEFORE after=$AFTER)" FAIL
fi

bash "$LOG" --evidence-run --scope everything --cmd 'true' >/dev/null 2>&1; RC_SCOPE=$?
bash "$LOG" --evidence-run --scope full --bogus >/dev/null 2>&1; RC_ARG=$?
bash "$LOG" --evidence-run --scope lint >/dev/null 2>&1; RC_CMD=$?
if [ "$RC_SCOPE" -eq 2 ] && [ "$RC_ARG" -eq 2 ] && [ "$RC_CMD" -eq 2 ]; then
  check "E12 an unknown scope, an unknown argument and a missing --cmd are usage errors" PASS
else
  check "E12 an unknown scope, an unknown argument and a missing --cmd are usage errors ($RC_SCOPE/$RC_ARG/$RC_CMD)" FAIL
fi

finish
