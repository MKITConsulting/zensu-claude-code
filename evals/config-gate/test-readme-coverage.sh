#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$README" ]; then
  check "README.md exists" FAIL
  echo "----"
  echo "test-readme-coverage: $PASS PASS / $FAIL FAIL"
  exit 1
fi

contains() {
  local needle="$1"
  if grep -F -q -- "$needle" "$README"; then return 0; fi
  return 1
}

if contains "autoFixIncludeSuggestions"; then
  check "README documents autoFixIncludeSuggestions flag" PASS
else
  check "README documents autoFixIncludeSuggestions flag" FAIL
fi

if contains "autoFixMaxRounds"; then
  check "README documents autoFixMaxRounds flag" PASS
else
  check "README documents autoFixMaxRounds flag" FAIL
fi

if contains "Config Resolution Order"; then
  check "README contains 'Config Resolution Order' subsection" PASS
else
  check "README contains 'Config Resolution Order' subsection" FAIL
fi

if contains "CLAUDE_PROJECT_DIR"; then
  check "README references CLAUDE_PROJECT_DIR" PASS
else
  check "README references CLAUDE_PROJECT_DIR" FAIL
fi

if contains ".zensu/config.json"; then
  check "README references project-local '.zensu/config.json'" PASS
else
  check "README references project-local '.zensu/config.json'" FAIL
fi

if grep -E -q "REPLACES[^,]*, does not [^M]*MERGE|REPLACES[^,]*, does not [^m]*merge" "$README"; then
  check "README states resolution REPLACES, does not MERGE (or merge)" PASS
else
  check "README states resolution REPLACES, does not MERGE (or merge)" FAIL
fi

if contains "autoFix:true"; then
  check "README mentions autoFix:true prerequisite" PASS
elif contains "\`autoFix\`: \`true\`"; then
  check "README mentions autoFix:true prerequisite (alt formatting)" PASS
elif contains "autoFix=true"; then
  check "README mentions autoFix=true prerequisite (alt formatting)" PASS
else
  check "README mentions autoFix:true prerequisite" FAIL
fi

echo "----"
echo "test-readme-coverage: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
