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

if [ ! -f "$LIB" ]; then
  check "hooks/lib/zensu-tdd-phase.sh exists" FAIL
  echo "----"
  echo "test-pre-edit-lib-paths: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "hooks/lib/zensu-tdd-phase.sh exists" PASS

source "$LIB"

for fn in tdd_state_file tdd_is_test_path; do
  if declare -F "$fn" >/dev/null; then
    check "function defined: $fn" PASS
  else
    check "function defined: $fn" FAIL
  fi
done

STATE_PATH="$(tdd_state_file "sid-abc123")"
case "$STATE_PATH" in
  */tdd-phase-sid-abc123.json) check "tdd_state_file returns expected path" PASS ;;
  *)                            check "tdd_state_file returns expected path (got: $STATE_PATH)" FAIL ;;
esac

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

assert_test_path "src/foo.ts"                       "false" "production .ts is NOT test"
assert_test_path "src/utils/reverse.go"             "false" "production .go is NOT test"
assert_test_path "main.py"                          "false" "production .py is NOT test"

assert_test_path "src/foo.test.ts"                  "true"  ".test.ts basename pattern"
assert_test_path "src/foo.spec.ts"                  "true"  ".spec.ts basename pattern"
assert_test_path "frontend/src/__tests__/Foo.tsx"   "true"  "__tests__ dir pattern"
assert_test_path "backend/internal/foo/foo_test.go" "true"  "_test.go basename pattern"
assert_test_path "tests/test_foo.py"                "true"  "tests/ dir + test_ prefix"
assert_test_path "specs/SomethingSpec.scala"        "true"  "specs/ dir pattern"
assert_test_path "src/test/java/FooTest.java"       "true"  "FooTest.java under src/test/java/ path"

INLINE_DIR="$(mktemp -d)"
cleanup() { rm -rf "$INLINE_DIR"; }
trap cleanup EXIT

cat > "$INLINE_DIR/inline_go.go" <<'EOF'
package strings

func TestReverse(t *testing.T) {
  if true {}
}
EOF
assert_test_path "$INLINE_DIR/inline_go.go" "true" "inline Go test (func Test header)"

cat > "$INLINE_DIR/inline_rs.rs" <<'EOF'
#[cfg(test)]
mod tests {
  #[test]
  fn it_works() { assert_eq!(2 + 2, 4); }
}
EOF
assert_test_path "$INLINE_DIR/inline_rs.rs" "true" "inline Rust test (#[test] header)"

cat > "$INLINE_DIR/inline_jest.js" <<'EOF'
describe("group", () => {
  it("works", () => { });
});
EOF
assert_test_path "$INLINE_DIR/inline_jest.js" "true" "inline jest (describe header)"

cat > "$INLINE_DIR/inline_py.py" <<'EOF'
def test_something():
    assert 1 == 1
EOF
assert_test_path "$INLINE_DIR/inline_py.py" "true" "inline python (def test_ header)"

cat > "$INLINE_DIR/plain.ts" <<'EOF'
export function reverse(s: string): string {
  return s.split('').reverse().join('');
}
EOF
assert_test_path "$INLINE_DIR/plain.ts" "false" "plain ts production file (no test header)"

echo "----"
echo "test-pre-edit-lib-paths: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
