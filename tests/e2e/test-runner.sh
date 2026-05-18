#!/bin/bash
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$TEST_DIR/run.sh"
CANONICAL_RESULTS_DIR="$TEST_DIR/results"

mkdir -p "$CANONICAL_RESULTS_DIR"
CANONICAL_RESULTS_BEFORE="$(ls -1 "$CANONICAL_RESULTS_DIR" 2>/dev/null | sort)"

PASS=0
FAIL=0

check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then
    PASS=$((PASS + 1))
    echo "  PASS  $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL  $label  ${3:-}"
  fi
}

with_tmp_fixtures() {
  local body="$1"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures" "$tmp/expected"
  (
    cd "$tmp" || exit 1
    eval "$body"
  )
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

test_runner_is_executable() {
  if [ -x "$RUNNER" ]; then
    check "test_runner_is_executable" PASS
  else
    check "test_runner_is_executable" FAIL "$RUNNER not executable"
  fi
}

test_skeleton_reports_total_counts() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures" "$tmp/expected"
  out="$tmp/out.txt"
  if FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" RESULTS_DIR="$tmp/results" "$RUNNER" --self-check > "$out" 2>&1; then
    if grep -qE "TOTAL: 0/0" "$out"; then
      check "test_skeleton_reports_total_counts" PASS
    else
      check "test_skeleton_reports_total_counts" FAIL "no 'TOTAL: 0/0' in output: $(head -20 "$out")"
    fi
  else
    check "test_skeleton_reports_total_counts" FAIL "runner exited non-zero on empty fixtures dir"
  fi
  rm -rf "$tmp"
}

test_pattern_match_pass_and_fail() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/good" "$tmp/fixtures/bad" "$tmp/expected" "$tmp/results"
  echo "the captured reviewer output contains the expected signal" > "$tmp/results/good-20260101-000000.captured.txt"
  echo "this output does not contain the signal" > "$tmp/results/bad-20260101-000000.captured.txt"
  echo "expected signal" > "$tmp/expected/good.pattern"
  echo "missing-needle-12345" > "$tmp/expected/bad.pattern"

  local out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" RESULTS_DIR="$tmp/results" \
    "$RUNNER" --offline > "$out" 2>&1
  local total_line
  total_line="$(grep -E "TOTAL:" "$out" | tail -1)"

  if grep -qE "PASS\s+good" "$out" && grep -qE "FAIL\s+bad" "$out" && echo "$total_line" | grep -qE "1/2"; then
    check "test_pattern_match_pass_and_fail" PASS
  else
    check "test_pattern_match_pass_and_fail" FAIL "expected one PASS one FAIL with 1/2 total, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_offline_mode_picks_newest_capture() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/fx" "$tmp/expected" "$tmp/results"

  echo "OLD output contains old-needle" > "$tmp/results/fx-20260101-000000.captured.txt"
  sleep 0.1
  echo "NEW output contains new-needle" > "$tmp/results/fx-20260101-000001.captured.txt"

  echo "new-needle" > "$tmp/expected/fx.pattern"

  local out="$tmp/out.txt" shim_log="$tmp/claude-shim.log"
  echo "should-not-fire" > "$shim_log"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
EOF
  chmod +x "$tmp/bin/claude"

  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1
  local rc=$?

  if grep -qE "PASS\s+fx" "$out" \
     && [ "$rc" -eq 0 ] \
     && ! grep -q "claude-shim-invoked" "$shim_log"; then
    check "test_offline_mode_picks_newest_capture" PASS
  else
    check "test_offline_mode_picks_newest_capture" FAIL "rc=$rc out:$(printf '\n')$(cat "$out") shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_self_check_skips_claude() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/anything" "$tmp/expected" "$tmp/bin"
  echo "dummy" > "$tmp/fixtures/anything/.captured"
  echo "dummy" > "$tmp/expected/anything.pattern"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
echo "fake reviewer output"
EOF
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --self-check > "$out" 2>&1
  local rc=$?

  if [ "$rc" -eq 0 ] && [ ! -s "$shim_log" ]; then
    check "test_self_check_skips_claude" PASS
  else
    check "test_self_check_skips_claude" FAIL "rc=$rc shim_log_size=$(wc -c < "$shim_log" 2>/dev/null || echo MISSING)"
  fi
  rm -rf "$tmp"
}

test_invokes_claude_print_per_fixture() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/myfx" "$tmp/expected" "$tmp/bin"

  (
    cd "$tmp/fixtures/myfx" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "export const x = 1;" > sample.ts
    git add sample.ts
    git -c commit.gpgsign=false commit -q -m "main: initial"
    git checkout -q -b feature
    echo "export const x = 2;" > sample.ts
    git -c commit.gpgsign=false commit -qa -m "feature: change x"
  )

  echo "Files changed" > "$tmp/expected/myfx.pattern"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<'SHIM'
#!/bin/bash
echo "ARGS: $*" >> "$CLAUDE_SHIM_LOG"
echo "STDIN:" >> "$CLAUDE_SHIM_LOG"
cat >> "$CLAUDE_SHIM_LOG" 2>/dev/null || true
echo "Files changed: [sample.ts]"
echo "fake reviewer report content"
SHIM
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" \
    CLAUDE_SHIM_LOG="$shim_log" \
    FIXTURES_DIR="$tmp/fixtures" \
    EXPECTED_DIR="$tmp/expected" \
    RESULTS_DIR="$tmp/results" \
    "$RUNNER" > "$out" 2>&1
  local rc=$?

  if grep -q "ARGS:.*--print" "$shim_log" \
     && grep -q "sample.ts" "$shim_log" \
     && [ "$rc" -eq 0 ]; then
    check "test_invokes_claude_print_per_fixture" PASS
  else
    check "test_invokes_claude_print_per_fixture" FAIL "rc=$rc shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null || echo MISSING) outfile:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_pattern_comment_vs_markdown_header() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/hdr_ok" "$tmp/fixtures/hdr_bad" "$tmp/expected"
  mkdir -p "$tmp/results"
  cat > "$tmp/results/hdr_ok-20260101-000000.captured.txt" <<'CAP'
some preamble text
## Build Verification: ✓ passed
trailing text
CAP
  cat > "$tmp/results/hdr_bad-20260101-000000.captured.txt" <<'CAP'
some preamble text
no header here
trailing text
CAP
  cat > "$tmp/expected/hdr_ok.pattern" <<'PAT'
# this is a harness comment, must be skipped
## Build [Vv]erification:.*(passed|failed)
PAT
  cat > "$tmp/expected/hdr_bad.pattern" <<'PAT'
# this is a harness comment, must be skipped
## Build [Vv]erification:.*(passed|failed)
PAT

  local out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" RESULTS_DIR="$tmp/results" \
    "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+hdr_ok" "$out" && grep -qE "FAIL\s+hdr_bad" "$out"; then
    check "test_pattern_comment_vs_markdown_header" PASS
  else
    check "test_pattern_comment_vs_markdown_header" FAIL "expected PASS hdr_ok and FAIL hdr_bad, got: $(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_false_test_claim_pattern_rejects_prompt_echo() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/echo" "$tmp/fixtures/real" "$tmp/expected" "$tmp/results"

  cat > "$tmp/results/echo-20260101-000000.captured.txt" <<'CAP'
The prompt mentioned: tdd-manager reported: 100/100 PASS — Coverage 100%.
Files reviewed. No findings. Verdict: PASS.
CAP

  cat > "$tmp/results/real-20260101-000000.captured.txt" <<'CAP'
# Code Review Report

## Critical Issues
1. **tdd-claim.txt:1** Test count mismatch: tdd-manager reported 100/100 PASS, reviewer reproduced 0/0.
   Fix: Re-run the suite.

Verdict: NEEDS CHANGES
CAP

  local pattern_dest="$tmp/expected/echo.pattern"
  cp /Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code/.claude/worktrees/quirky-black-840860/tests/e2e/expected/false-test-claim.pattern "$pattern_dest"
  cp "$pattern_dest" "$tmp/expected/real.pattern"

  local out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" RESULTS_DIR="$tmp/results" \
    "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+echo" "$out" && grep -qE "PASS\s+real" "$out"; then
    check "test_false_test_claim_pattern_rejects_prompt_echo" PASS
  else
    check "test_false_test_claim_pattern_rejects_prompt_echo" FAIL "expected FAIL echo + PASS real, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_invokes_named_agent() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/myfx" "$tmp/expected" "$tmp/bin"

  (
    cd "$tmp/fixtures/myfx" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "export const x = 1;" > sample.ts
    git add sample.ts
    git -c commit.gpgsign=false commit -q -m "main: initial"
    git checkout -q -b feature
    echo "export const x = 2;" > sample.ts
    git -c commit.gpgsign=false commit -qa -m "feature: change x"
  )

  echo "Files changed" > "$tmp/expected/myfx.pattern"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<'SHIM'
#!/bin/bash
echo "ARGS: $*" >> "$CLAUDE_SHIM_LOG"
echo "fake reviewer report content"
echo "Files changed: [sample.ts]"
SHIM
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" \
    CLAUDE_SHIM_LOG="$shim_log" \
    FIXTURES_DIR="$tmp/fixtures" \
    EXPECTED_DIR="$tmp/expected" \
    RESULTS_DIR="$tmp/results" \
    "$RUNNER" > "$out" 2>&1
  local rc=$?

  if grep -qE "ARGS:.*--agent[= ]code-reviewer" "$shim_log" \
     && ! grep -qE "@zensu:code-reviewer" "$shim_log" \
     && [ "$rc" -eq 0 ]; then
    check "test_invokes_named_agent" PASS
  else
    check "test_invokes_named_agent" FAIL "rc=$rc shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null || echo MISSING)"
  fi
  rm -rf "$tmp"
}

test_build_fails_fixture_runs_tsc() {
  if ! command -v npm >/dev/null 2>&1; then
    check "test_build_fails_fixture_runs_tsc" FAIL "npm not on PATH (required for hermetic fixture build)"
    return
  fi

  local tmp setup_script tsc_out tsc_rc
  tmp="$(mktemp -d)"
  setup_script="$TEST_DIR/setup-fixtures.sh"

  FIXTURES_DIR="$tmp/fixtures" bash "$setup_script" > "$tmp/setup.log" 2>&1
  local setup_rc=$?

  if [ "$setup_rc" -ne 0 ]; then
    check "test_build_fails_fixture_runs_tsc" FAIL "setup-fixtures.sh exited $setup_rc; log:$(printf '\n')$(cat "$tmp/setup.log")"
    rm -rf "$tmp"
    return
  fi

  if [ ! -d "$tmp/fixtures/build-fails/node_modules/typescript" ]; then
    check "test_build_fails_fixture_runs_tsc" FAIL "node_modules/typescript missing after setup — fixture not hermetic"
    rm -rf "$tmp"
    return
  fi

  tsc_out="$tmp/tsc.out"
  (cd "$tmp/fixtures/build-fails" && ./node_modules/.bin/tsc) > "$tsc_out" 2>&1
  tsc_rc=$?

  if [ "$tsc_rc" -ne 0 ] && grep -qE "TS2322" "$tsc_out"; then
    check "test_build_fails_fixture_runs_tsc" PASS
  else
    check "test_build_fails_fixture_runs_tsc" FAIL "tsc_rc=$tsc_rc tsc_out:$(printf '\n')$(cat "$tsc_out")"
  fi
  rm -rf "$tmp"
}

test_unknown_mode_rejected() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures" "$tmp/expected" "$tmp/bin"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
EOF
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --bogus > "$out" 2>&1
  local rc=$?

  if [ "$rc" -eq 2 ] \
     && grep -qE "unknown mode" "$out" \
     && [ ! -s "$shim_log" ]; then
    check "test_unknown_mode_rejected" PASS
  else
    check "test_unknown_mode_rejected" FAIL "rc=$rc out:$(printf '\n')$(cat "$out") shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_zero_byte_capture_diagnostic() {
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/empty_cap" "$tmp/expected" "$tmp/results"

  : > "$tmp/results/empty_cap-20260101-000000.captured.txt"

  echo "any expected signal" > "$tmp/expected/empty_cap.pattern"

  local out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" RESULTS_DIR="$tmp/results" \
    "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+empty_cap" "$out" && grep -qE "zero-byte capture" "$out"; then
    check "test_zero_byte_capture_diagnostic" PASS
  else
    check "test_zero_byte_capture_diagnostic" FAIL "expected FAIL + 'zero-byte capture' diagnostic for empty_cap, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_results_dir_isolated_per_test() {
  local after diff
  after="$(ls -1 "$CANONICAL_RESULTS_DIR" 2>/dev/null | sort)"
  diff="$(comm -13 <(printf "%s\n" "$CANONICAL_RESULTS_BEFORE") <(printf "%s\n" "$after"))"
  if [ -z "$diff" ]; then
    check "test_results_dir_isolated_per_test" PASS
  else
    check "test_results_dir_isolated_per_test" FAIL "canonical results dir leaked files:$(printf '\n')$diff"
  fi
}

echo "=== test-runner.sh ==="
test_runner_is_executable
test_skeleton_reports_total_counts
test_pattern_match_pass_and_fail
test_pattern_comment_vs_markdown_header
test_offline_mode_picks_newest_capture
test_self_check_skips_claude
test_invokes_claude_print_per_fixture
test_invokes_named_agent
test_false_test_claim_pattern_rejects_prompt_echo
test_unknown_mode_rejected
test_build_fails_fixture_runs_tsc
test_zero_byte_capture_diagnostic
test_results_dir_isolated_per_test

echo ""
echo "Result: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
