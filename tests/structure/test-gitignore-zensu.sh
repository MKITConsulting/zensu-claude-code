#!/bin/bash
set -u

# Pins the .zensu/ ignore contract (0.4.0 cleanup): the ephemeral witness log
# (`witness-*.log`) is gitignored and never committed, while the durable narrative
# log (`*_tdd-*.log`) and plans stay tracked.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GI="$PLUGIN_DIR/.gitignore"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$GI" ]; then
  check "G1 .gitignore exists" FAIL
  echo "----"; echo "test-gitignore-zensu: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "G1 .gitignore exists" PASS

if grep -qE '^\.zensu/logs/witness-\*\.log$' "$GI"; then
  check "G2 .gitignore re-ignores .zensu/logs/witness-*.log" PASS
else
  check "G2 .gitignore re-ignores .zensu/logs/witness-*.log" FAIL
fi

if grep -qF '!.zensu/logs/*.log' "$GI"; then
  check "G3 narrative .zensu/logs/*.log stays un-ignored (tracked)" PASS
else
  check "G3 narrative .zensu/logs/*.log stays un-ignored (tracked)" FAIL
fi

# Behavioral check via git check-ignore (the real guarantee).
cd "$PLUGIN_DIR" 2>/dev/null || true
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git check-ignore -q ".zensu/logs/witness-smoke-1.log"; then
    check "G4 git check-ignore: a witness log IS ignored" PASS
  else
    check "G4 git check-ignore: a witness log IS ignored" FAIL
  fi
  if git check-ignore -q ".zensu/logs/2026-01-01-0000_tdd-foo.log"; then
    check "G5 git check-ignore: a narrative log is NOT ignored" FAIL
  else
    check "G5 git check-ignore: a narrative log is NOT ignored" PASS
  fi
else
  check "G4 git check-ignore (skipped: not a git repo)" PASS
  check "G5 git check-ignore (skipped: not a git repo)" PASS
fi

echo "----"
echo "test-gitignore-zensu: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
