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

assert_test_path "src/user_spec.rb"         "true"  "POS user_spec.rb (underscore boundary)"
assert_test_path "src/User_Spec.rb"         "true"  "POS User_Spec.rb (underscore boundary)"
assert_test_path "src/foo_test.go"          "true"  "POS foo_test.go (existing _test pattern)"
assert_test_path "src/foo_tests.go"         "true"  "POS foo_tests.go (underscore tests)"
assert_test_path "src/foo_specs.go"         "true"  "POS foo_specs.go (underscore specs)"

assert_test_path "src/AttestSpec.tsx"       "false" "NEG AttestSpec.tsx (Attest contains 'test'; no underscore boundary)"
assert_test_path "src/AccountsTests.tsx"    "false" "NEG AccountsTests.tsx (no underscore boundary)"
assert_test_path "src/RequestSpec.ts"       "false" "NEG RequestSpec.ts (no underscore boundary)"
assert_test_path "src/Tests.tsx"            "false" "NEG Tests.tsx (no prefix, no underscore)"
assert_test_path "src/Spec.ts"              "false" "NEG Spec.ts (no prefix, no underscore)"
assert_test_path "src/Test.java"            "false" "NEG Test.java (no underscore boundary)"
assert_test_path "src/FooTest.java"         "false" "NEG FooTest.java (camelCase NOT enough; java test files belong in src/test/java/)"
assert_test_path "src/test/java/FooTest.java" "true" "POS FooTest.java IN src/test/ path"

echo "----"
echo "test-pre-edit-basename-boundary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
