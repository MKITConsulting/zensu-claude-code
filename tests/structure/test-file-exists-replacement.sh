#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCENARIOS_DIR="$PLUGIN_DIR/evals/tdd-manager-pretool/scenarios"
ASSERTIONS_DIR="$PLUGIN_DIR/evals/tdd-manager-pretool/assertions"
ASSERT_FILE_EXISTS="$ASSERTIONS_DIR/assert-file-exists.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -d "$SCENARIOS_DIR" ]; then
  check "scenarios dir exists" FAIL
  echo "----"
  echo "test-file-exists-replacement: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "scenarios dir exists" PASS

FILES=(
  "$SCENARIOS_DIR/01-happy-frontend.yaml"
  "$SCENARIOS_DIR/02-happy-backend.yaml"
  "$SCENARIOS_DIR/09-cross-stack.yaml"
)

for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then
    check "$(basename "$f") exists" PASS
  else
    check "$(basename "$f") exists" FAIL
  fi
done

if [ -f "$ASSERT_FILE_EXISTS" ]; then
  check "assertions/assert-file-exists.js exists" PASS
else
  check "assertions/assert-file-exists.js exists" FAIL
fi

if [ -f "$ASSERT_FILE_EXISTS" ] && grep -qE 'module\.exports[[:space:]]*=' "$ASSERT_FILE_EXISTS"; then
  check "assert-file-exists.js exports module.exports function" PASS
else
  check "assert-file-exists.js exports module.exports function" FAIL
fi

if [ -f "$ASSERT_FILE_EXISTS" ] && grep -qF 'context.vars.expected_paths' "$ASSERT_FILE_EXISTS"; then
  check "assert-file-exists.js reads context.vars.expected_paths" PASS
else
  check "assert-file-exists.js reads context.vars.expected_paths" FAIL
fi

FS_COUNT=$(grep -c 'fs.existsSync' "${FILES[@]}" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$FS_COUNT" = "0" ]; then
  check "no inline fs.existsSync blocks remain across 3 scenarios (got $FS_COUNT)" PASS
else
  check "no inline fs.existsSync blocks remain across 3 scenarios (got $FS_COUNT)" FAIL
fi

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  if grep -qF 'file://assertions/assert-file-exists.js' "$f"; then
    check "$base references file://assertions/assert-file-exists.js" PASS
  else
    check "$base references file://assertions/assert-file-exists.js" FAIL
  fi
done

for f in "${FILES[@]}"; do
  base=$(basename "$f")
  if grep -qF 'expected_paths' "$f"; then
    check "$base declares expected_paths var" PASS
  else
    check "$base declares expected_paths var" FAIL
  fi
done

FE_COUNT=$(grep -c 'type: file-exists' "${FILES[@]}" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
if [ "$FE_COUNT" = "0" ]; then
  check "no 'type: file-exists' assertions remain across 3 scenarios (got $FE_COUNT)" PASS
else
  check "no 'type: file-exists' assertions remain across 3 scenarios (got $FE_COUNT)" FAIL
fi

if [ -f "$ASSERT_FILE_EXISTS" ] && ! grep -qE "require\(['\"]fs['\"]\)" "$ASSERT_FILE_EXISTS"; then
  check "assert-file-exists.js does NOT require('fs') (transcript-grep based, isolation-safe)" PASS
else
  check "assert-file-exists.js does NOT require('fs') (transcript-grep based, isolation-safe)" FAIL
fi

if [ -f "$ASSERT_FILE_EXISTS" ] && ! grep -qF 'fs.existsSync' "$ASSERT_FILE_EXISTS"; then
  check "assert-file-exists.js does NOT call fs.existsSync (transcript-grep based, isolation-safe)" PASS
else
  check "assert-file-exists.js does NOT call fs.existsSync (transcript-grep based, isolation-safe)" FAIL
fi

if [ -f "$ASSERT_FILE_EXISTS" ] && grep -qF 'tool_use' "$ASSERT_FILE_EXISTS"; then
  check "assert-file-exists.js references tool_use marker (transcript-grep pattern present)" PASS
else
  check "assert-file-exists.js references tool_use marker (transcript-grep pattern present)" FAIL
fi

if [ -f "$ASSERT_FILE_EXISTS" ]; then
  NODE_OUT=$(node -e "
    const m = require('$ASSERT_FILE_EXISTS');
    if (typeof m !== 'function') { console.log('NOT_FUNCTION'); process.exit(0); }
    const writeRel  = '[tool_use: Write] input={\"file_path\":\"frontend/src/utils/reverseString.ts\",\"content\":\"x\"}';
    const editRel   = '[tool_use: Edit] input={\"file_path\":\"backend/internal/stringutil/reverse.go\",\"old_string\":\"\",\"new_string\":\"\"}';
    const writeAbs  = '[tool_use: Write] input={\"file_path\":\"/tmp/claude-eval-X/frontend/src/utils/reverseString.ts\",\"content\":\"x\"}';
    const multiEdit = '[tool_use: MultiEdit] input={\"file_path\":\"frontend/src/utils/debounce.ts\",\"edits\":[]}';
    const notebook  = '[tool_use: NotebookEdit] input={\"notebook_path\":\"analysis.ipynb\",\"new_source\":\"x\"}';
    const wrongDir  = '[tool_use: Write] input={\"file_path\":\"backend/wrong/reverseString.ts\",\"content\":\"x\"}';
    const bashHere  = '[tool_use: Bash] input={\"command\":\"cat > frontend/src/utils/reverseString.ts <<EOF\\nx\\nEOF\"}';
    const all = [writeRel, editRel, writeAbs, multiEdit, notebook].join('\n');
    const r1 = m({ output: writeRel,  context: { vars: { expected_paths: ['frontend/src/utils/reverseString.ts'] } } });
    const r2 = m({ output: writeAbs,  context: { vars: { expected_paths: ['frontend/src/utils/reverseString.ts'] } } });
    const r3 = m({ output: multiEdit, context: { vars: { expected_paths: ['frontend/src/utils/debounce.ts'] } } });
    const r4 = m({ output: notebook,  context: { vars: { expected_paths: ['analysis.ipynb'] } } });
    const r5 = m({ output: wrongDir,  context: { vars: { expected_paths: ['frontend/src/utils/reverseString.ts'] } } });
    const r6 = m({ output: bashHere,  context: { vars: { expected_paths: ['frontend/src/utils/reverseString.ts'] } } });
    const r7 = m({ output: 'no tool_use lines', context: { vars: { expected_paths: ['x.ts'] } } });
    const r8 = m({ output: writeRel,  context: { vars: {} } });
    const r9 = m({ output: all,       context: { vars: { expected_paths: ['frontend/src/utils/debounce.ts', 'analysis.ipynb'] } } });
    console.log(JSON.stringify({
      writeRel:r1.pass, writeAbs:r2.pass, multiEdit:r3.pass, notebook:r4.pass,
      wrongDir:r5.pass, bashHere:r6.pass, none:r7.pass, noVars:r8.pass, batch:r9.pass
    }));
  " 2>&1)
  EXPECTED='{"writeRel":true,"writeAbs":true,"multiEdit":true,"notebook":true,"wrongDir":false,"bashHere":false,"none":false,"noVars":false,"batch":true}'
  if [ "$NODE_OUT" = "$EXPECTED" ]; then
    check "assert-file-exists.js behavior: relative+absolute+MultiEdit+NotebookEdit PASS; wrong-dir/Bash/empty/no-vars FAIL" PASS
  else
    check "assert-file-exists.js behavior mismatch (got: ${NODE_OUT:0:300})" FAIL
  fi
else
  check "assert-file-exists.js behavior (file missing)" FAIL
fi

echo "----"
echo "test-file-exists-replacement: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
