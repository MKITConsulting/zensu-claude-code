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

assert_path() {
  local path="$1" expected="$2" label="$3"
  local got
  got=$(tdd_is_test_path "$path")
  if [ "$got" = "$expected" ]; then
    check "$label" PASS
  else
    check "$label (expected $expected, got $got)" FAIL
  fi
}

cat > "$WORK/jsdoc_describe.ts" <<'EOF'
// describe("legacy migration plan", () => { });
// it("documents prior behaviour")
export function reverse(s: string): string {
  return s.split('').reverse().join('');
}
EOF
assert_path "$WORK/jsdoc_describe.ts" "false" "JSDoc-style '// describe(' comment in production file"

cat > "$WORK/jsdoc_block.ts" <<'EOF'
/* describe(
 *   This is a block comment, not a test.
 */
export function add(a: number, b: number): number {
  return a + b;
}
EOF
assert_path "$WORK/jsdoc_block.ts" "false" "Block comment containing 'describe(' in production file"

cat > "$WORK/runner.ts" <<'EOF'
export function test(name: string, fn: () => void): void {
  console.log(name);
  fn();
}
EOF
assert_path "$WORK/runner.ts" "false" "Production file with 'function test(name, fn)' helper (not BOL test()"

cat > "$WORK/python_comment.py" <<'EOF'
# def test_something(): pretend doc-style example
def helper():
    return 1
EOF
assert_path "$WORK/python_comment.py" "false" "Python comment containing 'def test_'"

cat > "$WORK/godoc_comment.go" <<'EOF'
// func TestReverse shows API; not a real test.
package strings

func Reverse(s string) string { return s }
EOF
assert_path "$WORK/godoc_comment.go" "false" "Go comment containing 'func Test'"

cat > "$WORK/inline_jest_actual.test.ts" <<'EOF'
describe('group', () => {
  it('works', () => { });
});
EOF
assert_path "$WORK/inline_jest_actual.test.ts" "true" "ACTUAL test file (.test.ts basename) still classified true"

cat > "$WORK/inline_go.go" <<'EOF'
package strings

func TestReverse(t *testing.T) {
  if true {}
}
EOF
assert_path "$WORK/inline_go.go" "true" "Inline Go test (func Test header at BOL, no comment prefix) still classified true"

cat > "$WORK/inline_jest_bol.js" <<'EOF'
describe("group", () => {
  it("works", () => { });
});
EOF
assert_path "$WORK/inline_jest_bol.js" "true" "Inline jest describe( at BOL still classified true"

printf '\xef\xbb\xbfdescribe("bom test", () => { it("x", () => {}); });\n' > "$WORK/bom_test.ts"
assert_path "$WORK/bom_test.ts" "true" "BOM-prefixed test file classified as test (BOM stripped before grep)"

{
  for i in $(seq 1 12); do
    printf '// banner line %02d ------------------------------------\n' "$i"
  done
  printf 'describe("late group", () => { it("x", () => {}); });\n'
} > "$WORK/long_banner.ts"
assert_path "$WORK/long_banner.ts" "true" "Test signature after 300+ byte banner (line 13) classified as test"

dd if=/dev/urandom of="$WORK/binary_noise.bin" bs=1024 count=2 2>/dev/null
assert_path "$WORK/binary_noise.bin" "false" "Random binary bytes NOT classified as test (no false-positive after window widening)"

echo "----"
echo "test-pre-edit-inline-header: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
