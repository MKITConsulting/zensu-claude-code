#!/bin/bash
# Deterministic self-tests for the e2e-skills harness (no API, no claude spawn).
# Validates: --self-check skeleton, unknown-mode rejection, prompt/pattern parity,
# the agent-file convention, and the positive/negative pattern matcher (via --offline
# against a synthetic capture).
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$TEST_DIR/run.sh"
SETUP="$TEST_DIR/setup-fixtures.sh"
PROMPTS_DIR="$TEST_DIR/prompts"
EXPECTED_DIR="$TEST_DIR/expected"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label  ${3:-}"; FAIL=$((FAIL+1)); fi
}

# --- R1 --self-check on empty dirs -> TOTAL 0/0, exit 0 ---
tmp="$(mktemp -d)"
mkdir -p "$tmp/fixtures" "$tmp/expected" "$tmp/prompts" "$tmp/results"
if FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
   RESULTS_DIR="$tmp/results" bash "$RUNNER" --self-check >"$tmp/out" 2>&1 \
   && grep -qE "TOTAL: 0/0" "$tmp/out"; then
  check "R1 --self-check on empty fixtures -> TOTAL 0/0, exit 0" PASS
else
  check "R1 --self-check on empty fixtures" FAIL "$(tail -3 "$tmp/out")"
fi
rm -rf "$tmp"

# --- R2 unknown mode -> exit 2 ---
tmp="$(mktemp -d)"
FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
  RESULTS_DIR="$tmp/results" bash "$RUNNER" --bogus >/dev/null 2>&1
[ "$?" -eq 2 ] && check "R2 unknown mode rejected with exit 2" PASS || check "R2 unknown mode rejected with exit 2" FAIL
rm -rf "$tmp"

# --- R3 prompt/pattern parity ---
parity_ok=1
for p in "$PROMPTS_DIR"/*.txt; do
  [ -e "$p" ] || continue
  n="$(basename "$p" .txt)"
  [ -f "$EXPECTED_DIR/$n.pattern" ] || { parity_ok=0; echo "    missing expected/$n.pattern"; }
done
for e in "$EXPECTED_DIR"/*.pattern; do
  [ -e "$e" ] || continue
  n="$(basename "$e" .pattern)"
  [ -f "$PROMPTS_DIR/$n.txt" ] || { parity_ok=0; echo "    missing prompts/$n.txt"; }
done
[ "$parity_ok" -eq 1 ] && check "R3 every prompt has a pattern and vice versa" PASS || check "R3 prompt/pattern parity" FAIL

# --- R4 agent-file convention names a plugin agent ---
AGENT_FILE="$PROMPTS_DIR/review-aspect.agent"
if [ -f "$AGENT_FILE" ] && grep -qE 'review-aspect' "$AGENT_FILE"; then
  check "R4 review-aspect.agent names the review-aspect agent" PASS
else
  check "R4 review-aspect.agent names the review-aspect agent" FAIL
fi

# --- R5 matcher: positive assert matches (case-insensitive) ---
tmp="$(mktemp -d)"
mkdir -p "$tmp/fixtures/foo" "$tmp/expected" "$tmp/prompts" "$tmp/results"
printf 'irrelevant\n' > "$tmp/prompts/foo.txt"
printf 'feature\n'    > "$tmp/expected/foo.pattern"
printf 'hello world FEATURE lifecycle\n' > "$tmp/results/foo-20200101-000000.captured.txt"
if FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
   RESULTS_DIR="$tmp/results" bash "$RUNNER" --offline >"$tmp/out" 2>&1 \
   && grep -qE "TOTAL: 1/1" "$tmp/out"; then
  check "R5 positive pattern matches synthetic capture (--offline)" PASS
else
  check "R5 positive pattern match" FAIL "$(tail -3 "$tmp/out")"
fi
rm -rf "$tmp"

# --- R6 matcher: negative assert rejects when forbidden text present ---
tmp="$(mktemp -d)"
mkdir -p "$tmp/fixtures/bar" "$tmp/expected" "$tmp/prompts" "$tmp/results"
printf 'irrelevant\n' > "$tmp/prompts/bar.txt"
printf '!forbidden\n' > "$tmp/expected/bar.pattern"
printf 'this contains forbidden text\n' > "$tmp/results/bar-20200101-000000.captured.txt"
FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
  RESULTS_DIR="$tmp/results" bash "$RUNNER" --offline >"$tmp/out" 2>&1
if grep -qE "TOTAL: 0/1" "$tmp/out"; then
  check "R6 negative assert rejects forbidden text (--offline)" PASS
else
  check "R6 negative assert rejection" FAIL "$(tail -3 "$tmp/out")"
fi
rm -rf "$tmp"

# --- R7 setup-fixtures builds git fixtures with uncommitted diffs ---
tmp="$(mktemp -d)"
if FIXTURES_DIR="$tmp/fixtures" bash "$SETUP" >/dev/null 2>&1; then
  ra_git=0; ra_dirty=0; sr_dirty=0; zh_dir=0
  [ -d "$tmp/fixtures/review-aspect/.git" ] && ra_git=1
  [ -n "$(git -C "$tmp/fixtures/review-aspect" status --porcelain 2>/dev/null)" ] && ra_dirty=1
  [ -n "$(git -C "$tmp/fixtures/self-review" status --porcelain 2>/dev/null)" ] && sr_dirty=1
  [ -d "$tmp/fixtures/zensu-help" ] && zh_dir=1
  if [ "$ra_git" = 1 ] && [ "$ra_dirty" = 1 ] && [ "$sr_dirty" = 1 ] && [ "$zh_dir" = 1 ]; then
    check "R7 setup-fixtures: git repos + uncommitted diffs (review-aspect/self-review) + zensu-help dir" PASS
  else
    check "R7 setup-fixtures state (ra_git=$ra_git ra_dirty=$ra_dirty sr_dirty=$sr_dirty zh_dir=$zh_dir)" FAIL
  fi
else
  check "R7 setup-fixtures runs" FAIL
fi
rm -rf "$tmp"

echo "----"
echo "e2e-skills/test-runner: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
