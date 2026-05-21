#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

source "$LIB"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/real.test.ts" <<'EOF'
describe('real', () => { it('x', () => {}); });
EOF
ln -s "$WORK/real.test.ts" "$WORK/innocent.ts"

GOT=$(tdd_is_test_path "$WORK/innocent.ts")
if [ "$GOT" = "false" ]; then
  check "symlink innocent.ts -> real.test.ts classified as NOT test" PASS
else
  check "symlink innocent.ts -> real.test.ts classified as NOT test (got: $GOT)" FAIL
fi

cat > "$WORK/inline_test.ts" <<'EOF'
describe('real', () => { it('x', () => {}); });
EOF
ln -s "$WORK/inline_test.ts" "$WORK/decoy.ts"

GOT2=$(tdd_is_test_path "$WORK/decoy.ts")
if [ "$GOT2" = "false" ]; then
  check "symlink to inline-test header classified as NOT test" PASS
else
  check "symlink to inline-test header classified as NOT test (got: $GOT2)" FAIL
fi

cat > "$WORK/real_test.ts" <<'EOF'
describe('real', () => { it('x', () => {}); });
EOF
ln -s "$WORK/real_test.ts" "$WORK/innocent2.ts"
GOT3=$(tdd_is_test_path "$WORK/innocent2.ts")
if [ "$GOT3" = "false" ]; then
  check "symlink with test-like basename target STILL rejected (link basename used, not target)" PASS
else
  check "symlink with test-like basename target STILL rejected (got: $GOT3)" FAIL
fi

GOT4=$(tdd_is_test_path "$WORK/real.test.ts")
if [ "$GOT4" = "true" ]; then
  check "REAL non-symlink test file still classified true" PASS
else
  check "REAL non-symlink test file still classified true (got: $GOT4)" FAIL
fi

cat > "$WORK/hardlink_target.test.ts" <<'EOF'
describe('real', () => { it('x', () => {}); });
EOF
ln "$WORK/hardlink_target.test.ts" "$WORK/innocent_hardlink.ts"
GOT5=$(tdd_is_test_path "$WORK/innocent_hardlink.ts")
if [ "$GOT5" = "false" ]; then
  check "hard-link innocent_hardlink.ts (ln to real.test.ts) classified as NOT test" PASS
else
  check "hard-link innocent_hardlink.ts (ln to real.test.ts) classified as NOT test (got: $GOT5)" FAIL
fi

GOT6=$(tdd_is_test_path "$WORK/hardlink_target.test.ts")
if [ "$GOT6" = "true" ]; then
  check "hard-link source (hardlink_target.test.ts) — basename still test → true (link-count >1 ignored when basename matches before link-check)" PASS
else
  check "hard-link source — basename match: true (got: $GOT6)" FAIL
fi

echo "----"
echo "test-pre-edit-symlink-reject: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
