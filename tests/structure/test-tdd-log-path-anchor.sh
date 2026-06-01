#!/bin/bash
set -u

# Pins the narrative-log path convention: the /zensu:tdd narrative log MUST be
# anchored to ${CLAUDE_PROJECT_DIR:-.} so per-phase appends are cwd-independent.
# Guards against regression of the relative-path bug where an append issued from a
# subdirectory failed with: no such file or directory: .zensu/logs/..._tdd-....log

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$PLUGIN_DIR/skills/tdd/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL" ]; then
  check "L0 skills/tdd/SKILL.md exists" FAIL
  echo "----"; echo "test-tdd-log-path-anchor: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "L0 skills/tdd/SKILL.md exists" PASS

# L1: the Phase-0 create mkdir is anchored to ${CLAUDE_PROJECT_DIR:-.}
if grep -Fq 'mkdir -p "${CLAUDE_PROJECT_DIR:-.}/.zensu/logs"' "$SKILL"; then
  check "L1 Phase-0 mkdir anchored to CLAUDE_PROJECT_DIR" PASS
else
  check "L1 Phase-0 mkdir anchored to CLAUDE_PROJECT_DIR" FAIL
fi

# L2: {log_file} is defined as the anchored absolute path
if grep -Fq '${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{SESSION_TS}_tdd-{slug}.log' "$SKILL"; then
  check "L2 {log_file} defined as anchored absolute path" PASS
else
  check "L2 {log_file} defined as anchored absolute path" FAIL
fi

# L3 (negative): no redirect (> or >>) targets a bare relative .zensu/logs/ path.
# Anchored redirects go to {log_file} or "${CLAUDE_PROJECT_DIR:-.}/..." and are exempt.
if grep -Eq '>>?[[:space:]]*"?\.zensu/logs/' "$SKILL"; then
  check "L3 no bare-relative .zensu/logs redirect remains" FAIL
else
  check "L3 no bare-relative .zensu/logs redirect remains" PASS
fi

echo "----"
echo "test-tdd-log-path-anchor: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
