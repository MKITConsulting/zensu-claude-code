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

assert_test_path() {
  local path="$1" expected="$2" label="$3"
  local got
  got=$(tdd_is_test_path "$path")
  if [ "$got" = "$expected" ]; then
    check "$label" PASS
  else
    check "$label (expected $expected, got $got)" FAIL
  fi
}

assert_test_path "tests/foo.ts"        "true"  "top-level tests/ dir"
assert_test_path "test/foo.ts"         "true"  "top-level test/ dir"
assert_test_path "spec/foo.rb"         "true"  "top-level spec/ dir"
assert_test_path "specs/foo.rb"        "true"  "top-level specs/ dir"
assert_test_path "__tests__/Foo.tsx"   "true"  "top-level __tests__ dir"
assert_test_path "Tests/Foo.tsx"       "true"  "case-insensitive Tests/ dir"
assert_test_path "TEST/foo.ts"         "true"  "uppercase TEST/ dir"

assert_test_path "src/foo.ts"          "false" "src/foo.ts must NOT be flagged (no test-dir prefix)"
assert_test_path "lib/utils.go"        "false" "lib/utils.go must NOT be flagged"

echo "----"
echo "test-pre-edit-toplevel-paths: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
