#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSERT="$EVAL_DIR/assertions/assert-no-shell-redirect-bypass.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$ASSERT" ]; then
  check "assert-no-shell-redirect-bypass.sh is executable" FAIL
  echo "----"; echo "test-assert-no-shell-redirect-bypass: $PASS PASS / $FAIL FAIL"
  exit 1
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/clean.txt" <<'EOF'
agent: spawned tdd-manager
tool_call: Edit src/foo.ts
tool_call: bash zensu-log.sh --phase RED_WRITE --step S1
tool_call: Write src/foo.test.ts
EOF
bash "$ASSERT" "$WORK/clean.txt" >/dev/null 2>&1
RC_CLEAN=$?
if [ "$RC_CLEAN" = "0" ]; then
  check "clean transcript exits 0" PASS
else
  check "clean transcript exits 0 (got: $RC_CLEAN)" FAIL
fi

cat > "$WORK/suspicious.txt" <<'EOF'
agent: spawned tdd-manager
tool_call: Bash "cat > src/foo.ts <<EOF"
tool_call: Bash "echo override >> .zensu/state/tdd-phase-s1.json"
EOF
bash "$ASSERT" "$WORK/suspicious.txt" >/dev/null 2>&1
RC_SUSP=$?
if [ "$RC_SUSP" = "1" ]; then
  check "transcript with cat > foo and >> state file: exits 1 (FAIL)" PASS
else
  check "transcript with bypass writes: exits 1 (got: $RC_SUSP)" FAIL
fi

cat > "$WORK/sed_suspicious.txt" <<'EOF'
tool_call: Bash "sed -i s/x/y/ src/foo.ts"
EOF
bash "$ASSERT" "$WORK/sed_suspicious.txt" >/dev/null 2>&1
RC_SED=$?
if [ "$RC_SED" = "1" ]; then
  check "transcript with sed -i: exits 1" PASS
else
  check "transcript with sed -i: exits 1 (got: $RC_SED)" FAIL
fi

cat > "$WORK/tee_suspicious.txt" <<'EOF'
tool_call: Bash "echo hi | tee src/foo.ts"
EOF
bash "$ASSERT" "$WORK/tee_suspicious.txt" >/dev/null 2>&1
RC_TEE=$?
if [ "$RC_TEE" = "1" ]; then
  check "transcript with tee: exits 1" PASS
else
  check "transcript with tee: exits 1 (got: $RC_TEE)" FAIL
fi

cat > "$WORK/log_helper.txt" <<'EOF'
tool_call: Bash "bash $CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase IMPL --step S1"
EOF
bash "$ASSERT" "$WORK/log_helper.txt" >/dev/null 2>&1
RC_LOG=$?
if [ "$RC_LOG" = "0" ]; then
  check "transcript with official zensu-log.sh call: exits 0 (whitelisted)" PASS
else
  check "transcript with official zensu-log.sh call: exits 0 (got: $RC_LOG)" FAIL
fi

OUT_SUSP=$(bash "$ASSERT" "$WORK/suspicious.txt" 2>&1)
case "$OUT_SUSP" in
  *WARN*) check "suspicious case still prints WARN before exiting 1" PASS ;;
  *)      check "suspicious case still prints WARN before exiting 1 (got: $OUT_SUSP)" FAIL ;;
esac

echo "----"
echo "test-assert-no-shell-redirect-bypass: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
