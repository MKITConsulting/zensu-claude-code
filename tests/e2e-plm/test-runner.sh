#!/bin/bash
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$TEST_DIR/run.sh"
SETUP_SCRIPT="$TEST_DIR/setup-fixtures.sh"
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

test_self_check_emits_total_zero() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures" "$tmp/expected" "$tmp/prompts"
  out="$tmp/out.txt"
  if FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
     PROMPTS_DIR="$tmp/prompts" RESULTS_DIR="$tmp/results" \
     "$RUNNER" --self-check > "$out" 2>&1; then
    if grep -qE "TOTAL: 0/0" "$out"; then
      check "test_self_check_emits_total_zero" PASS
    else
      check "test_self_check_emits_total_zero" FAIL "no 'TOTAL: 0/0' in output: $(head -20 "$out")"
    fi
  else
    check "test_self_check_emits_total_zero" FAIL "runner exited non-zero on empty fixtures"
  fi
  rm -rf "$tmp"
}

test_unknown_mode_rejected() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures" "$tmp/expected" "$tmp/prompts" "$tmp/bin"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
EOF
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    PROMPTS_DIR="$tmp/prompts" RESULTS_DIR="$tmp/results" "$RUNNER" --bogus > "$out" 2>&1
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

test_pattern_positive_and_missing() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/good" "$tmp/fixtures/bad" "$tmp/expected" "$tmp/prompts" "$tmp/results"
  echo "the captured plm output contains the expected signal" > "$tmp/results/good-20260101-000000.captured.txt"
  echo "this output does not contain the signal" > "$tmp/results/bad-20260101-000000.captured.txt"
  echo "expected signal" > "$tmp/expected/good.pattern"
  echo "missing-needle-12345" > "$tmp/expected/bad.pattern"

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1
  local total_line
  total_line="$(grep -E "TOTAL:" "$out" | tail -1)"

  if grep -qE "PASS\s+good" "$out" && grep -qE "FAIL\s+bad" "$out" && echo "$total_line" | grep -qE "1/2"; then
    check "test_pattern_positive_and_missing" PASS
  else
    check "test_pattern_positive_and_missing" FAIL "expected one PASS one FAIL with 1/2 total, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_negative_assert_lines() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/clean" "$tmp/fixtures/dirty" "$tmp/expected" "$tmp/prompts" "$tmp/results"
  cat > "$tmp/results/clean-20260101-000000.captured.txt" <<'CAP'
agent recommends list_features and get_feature
no forbidden token here
CAP
  cat > "$tmp/results/dirty-20260101-000000.captured.txt" <<'CAP'
agent recommends list_features and get_feature
agent then does update_feature with status=released
CAP
  cat > "$tmp/expected/clean.pattern" <<'PAT'
list_features
!update_feature.*status
PAT
  cat > "$tmp/expected/dirty.pattern" <<'PAT'
list_features
!update_feature.*status
PAT

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+clean" "$out" && grep -qE "FAIL\s+dirty" "$out"; then
    check "test_negative_assert_lines" PASS
  else
    check "test_negative_assert_lines" FAIL "expected PASS clean + FAIL dirty, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_hash_comments_skipped() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/ok" "$tmp/expected" "$tmp/prompts" "$tmp/results"
  echo "real signal appears here" > "$tmp/results/ok-20260101-000000.captured.txt"
  cat > "$tmp/expected/ok.pattern" <<'PAT'
# this is a harness comment that must not be matched literally
real signal
PAT

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+ok" "$out"; then
    check "test_hash_comments_skipped" PASS
  else
    check "test_hash_comments_skipped" FAIL "expected PASS ok (comments must be ignored), got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_offline_uses_newest_no_spawn() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/fx" "$tmp/expected" "$tmp/prompts" "$tmp/results" "$tmp/bin"

  echo "OLD output contains old-needle" > "$tmp/results/fx-20260101-000000.captured.txt"
  sleep 0.1
  echo "NEW output contains new-needle" > "$tmp/results/fx-20260101-000001.captured.txt"

  echo "new-needle" > "$tmp/expected/fx.pattern"

  shim_log="$tmp/claude-shim.log"
  echo "" > "$shim_log"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
EOF
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    PROMPTS_DIR="$tmp/prompts" RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1
  local rc=$?

  if grep -qE "PASS\s+fx" "$out" \
     && [ "$rc" -eq 0 ] \
     && ! grep -q "claude-shim-invoked" "$shim_log"; then
    check "test_offline_uses_newest_no_spawn" PASS
  else
    check "test_offline_uses_newest_no_spawn" FAIL "rc=$rc out:$(printf '\n')$(cat "$out") shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_self_check_skips_claude() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/any" "$tmp/expected" "$tmp/prompts" "$tmp/results" "$tmp/bin"
  echo "dummy" > "$tmp/expected/any.pattern"
  echo "dummy prompt" > "$tmp/prompts/any.txt"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
echo "fake plm output"
EOF
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    PROMPTS_DIR="$tmp/prompts" RESULTS_DIR="$tmp/results" "$RUNNER" --self-check > "$out" 2>&1
  local rc=$?

  if [ "$rc" -eq 0 ] && [ ! -s "$shim_log" ]; then
    check "test_self_check_skips_claude" PASS
  else
    check "test_self_check_skips_claude" FAIL "rc=$rc shim_log_size=$(wc -c < "$shim_log" 2>/dev/null || echo MISSING)"
  fi
  rm -rf "$tmp"
}

test_full_mode_invokes_zensu_plm_agent() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/myfx" "$tmp/expected" "$tmp/prompts" "$tmp/results" "$tmp/bin"

  echo "Please do something" > "$tmp/prompts/myfx.txt"
  echo "fake plm output" > "$tmp/expected/myfx.pattern"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<'SHIM'
#!/bin/bash
echo "ARGS: $*" >> "$CLAUDE_SHIM_LOG"
echo "fake plm output"
SHIM
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" \
    CLAUDE_SHIM_LOG="$shim_log" \
    FIXTURES_DIR="$tmp/fixtures" \
    EXPECTED_DIR="$tmp/expected" \
    PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" \
    "$RUNNER" > "$out" 2>&1
  local rc=$?

  if grep -qE "ARGS:.*--print" "$shim_log" \
     && grep -qE "ARGS:.*--agent[= ]zensu:zensu-plm" "$shim_log" \
     && ! grep -qE -- "--agent[= ]code-reviewer" "$shim_log" \
     && [ "$rc" -eq 0 ]; then
    check "test_full_mode_invokes_zensu_plm_agent" PASS
  else
    check "test_full_mode_invokes_zensu_plm_agent" FAIL "rc=$rc shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null || echo MISSING)"
  fi
  rm -rf "$tmp"
}

test_full_mode_passes_prompt_content() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/myfx" "$tmp/expected" "$tmp/prompts" "$tmp/results" "$tmp/bin"

  printf "MARKER-FROM-PROMPT-FILE\nLine two of prompt\n" > "$tmp/prompts/myfx.txt"
  echo "fake plm output" > "$tmp/expected/myfx.pattern"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<'SHIM'
#!/bin/bash
echo "ARGS-START" >> "$CLAUDE_SHIM_LOG"
for a in "$@"; do
  echo "ARG: $a" >> "$CLAUDE_SHIM_LOG"
done
echo "ARGS-END" >> "$CLAUDE_SHIM_LOG"
echo "fake plm output"
SHIM
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" \
    CLAUDE_SHIM_LOG="$shim_log" \
    FIXTURES_DIR="$tmp/fixtures" \
    EXPECTED_DIR="$tmp/expected" \
    PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" \
    "$RUNNER" > "$out" 2>&1
  local rc=$?

  if grep -q "MARKER-FROM-PROMPT-FILE" "$shim_log" && [ "$rc" -eq 0 ]; then
    check "test_full_mode_passes_prompt_content" PASS
  else
    check "test_full_mode_passes_prompt_content" FAIL "rc=$rc shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null || echo MISSING)"
  fi
  rm -rf "$tmp"
}

test_zero_byte_capture_diagnostic() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/empty_cap" "$tmp/expected" "$tmp/prompts" "$tmp/results"

  : > "$tmp/results/empty_cap-20260101-000000.captured.txt"
  echo "any expected signal" > "$tmp/expected/empty_cap.pattern"

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+empty_cap" "$out" && grep -qE "zero-byte capture" "$out"; then
    check "test_zero_byte_capture_diagnostic" PASS
  else
    check "test_zero_byte_capture_diagnostic" FAIL "expected FAIL + 'zero-byte capture' diagnostic, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_missing_prompt_file_diagnostic() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/noprompt" "$tmp/expected" "$tmp/prompts" "$tmp/results" "$tmp/bin"
  echo "anything" > "$tmp/expected/noprompt.pattern"

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<EOF
#!/bin/bash
echo "claude-shim-invoked: \$*" >> "$shim_log"
EOF
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" \
    PROMPTS_DIR="$tmp/prompts" RESULTS_DIR="$tmp/results" "$RUNNER" > "$out" 2>&1

  if grep -qE "FAIL\s+noprompt" "$out" \
     && grep -qE "missing prompt file" "$out" \
     && [ ! -s "$shim_log" ]; then
    check "test_missing_prompt_file_diagnostic" PASS
  else
    check "test_missing_prompt_file_diagnostic" FAIL "expected FAIL + 'missing prompt file' + no shim invocation, got:$(printf '\n')$(cat "$out") shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_setup_fixtures_idempotent() {
  local tmp run1_listing run2_listing
  tmp="$(mktemp -d)"

  if ! FIXTURES_DIR="$tmp/fixtures" bash "$SETUP_SCRIPT" > "$tmp/setup1.log" 2>&1; then
    check "test_setup_fixtures_idempotent" FAIL "first setup call exited non-zero; log:$(printf '\n')$(cat "$tmp/setup1.log")"
    rm -rf "$tmp"
    return
  fi
  run1_listing="$(cd "$tmp/fixtures" && ls -1 | sort)"

  if ! FIXTURES_DIR="$tmp/fixtures" bash "$SETUP_SCRIPT" > "$tmp/setup2.log" 2>&1; then
    check "test_setup_fixtures_idempotent" FAIL "second setup call exited non-zero; log:$(printf '\n')$(cat "$tmp/setup2.log")"
    rm -rf "$tmp"
    return
  fi
  run2_listing="$(cd "$tmp/fixtures" && ls -1 | sort)"

  local expected_fixtures="bootstrap feature-id-guard ghost-scan implement pulse-session security-review status-transition"
  local actual="$(echo $run1_listing | tr '\n' ' ' | xargs)"

  if [ "$run1_listing" = "$run2_listing" ] && [ "$actual" = "$expected_fixtures" ]; then
    check "test_setup_fixtures_idempotent" PASS
  else
    check "test_setup_fixtures_idempotent" FAIL "expected fixtures '$expected_fixtures', got run1='$actual' run2='$(echo $run2_listing | tr '\n' ' ' | xargs)'"
  fi
  rm -rf "$tmp"
}

test_shipped_patterns_pass_against_ideal_capture() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/bootstrap" "$tmp/fixtures/implement" "$tmp/fixtures/security-review" \
    "$tmp/fixtures/ghost-scan" "$tmp/fixtures/pulse-session" \
    "$tmp/fixtures/status-transition" "$tmp/fixtures/feature-id-guard" \
    "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/bootstrap-20260101-000000.captured.txt" <<'CAP'
I will run create_product, then create_product_vision, then bootstrap_from_vision and
apply_bootstrap to materialize Components and Features.
CAP
  cat > "$tmp/results/implement-20260101-000000.captured.txt" <<'CAP'
Step 1: get_feature for ZEN-042. Step 2: analyze_feature_security and set_security_classification.
Step 3: link_test plus link_source_files. Step 4: create_revision. Step 5: validate_feature_security.
CAP
  cat > "$tmp/results/security-review-20260101-000000.captured.txt" <<'CAP'
Workflow: set_security_classification, analyze_feature_security, suggest_security_tests,
add_security_test, generate_threat_model (STRIDE), and finally complete_security_review.
CAP
  cat > "$tmp/results/ghost-scan-20260101-000000.captured.txt" <<'CAP'
First list_features to avoid duplicates. Then ghost_scan with enrich_existing=true,
ghost_get_candidates, ghost_batch_review, and ghost_apply.
CAP
  cat > "$tmp/results/pulse-session-20260101-000000.captured.txt" <<'CAP'
I will call pulse_start_session with the current git HEAD SHA and branch name.
CAP
  cat > "$tmp/results/status-transition-20260101-000000.captured.txt" <<'CAP'
Status transitions are not handled by an MCP tool. You need to call the Zensu REST API endpoint
to transition the status to released.
CAP
  cat > "$tmp/results/feature-id-guard-20260101-000000.captured.txt" <<'CAP'
ZEN-999 does not appear in the feature list. Let me call list_features and confirm —
please bestätige welche Feature-ID gemeint ist.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1
  local rc=$?

  if [ "$rc" -eq 0 ] && grep -qE "TOTAL: 7/7" "$out"; then
    check "test_shipped_patterns_pass_against_ideal_capture" PASS
  else
    check "test_shipped_patterns_pass_against_ideal_capture" FAIL "rc=$rc out:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_shipped_patterns_reject_bad_captures() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/bootstrap" "$tmp/fixtures/status-transition" \
    "$tmp/fixtures/feature-id-guard" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/bootstrap-20260101-000000.captured.txt" <<'CAP'
I will help you with that task.
CAP
  cat > "$tmp/results/status-transition-20260101-000000.captured.txt" <<'CAP'
I will call update_feature with status=released. The REST endpoint is also available.
CAP
  cat > "$tmp/results/feature-id-guard-20260101-000000.captured.txt" <<'CAP'
Sure, I will start implementing ZEN-999 immediately by calling get_feature on it.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+bootstrap" "$out" \
     && grep -qE "FAIL\s+status-transition" "$out" \
     && grep -qE "FAIL\s+feature-id-guard" "$out"; then
    check "test_shipped_patterns_reject_bad_captures" PASS
  else
    check "test_shipped_patterns_reject_bad_captures" FAIL "expected all 3 to FAIL, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_end_to_end_with_shim_claude() {
  local tmp out shim_log
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/results" "$tmp/bin"

  if ! FIXTURES_DIR="$tmp/fixtures" bash "$SETUP_SCRIPT" > "$tmp/setup.log" 2>&1; then
    check "test_end_to_end_with_shim_claude" FAIL "setup-fixtures.sh failed; log:$(printf '\n')$(cat "$tmp/setup.log")"
    rm -rf "$tmp"
    return
  fi

  shim_log="$tmp/claude-shim.log"
  cat > "$tmp/bin/claude" <<'SHIM'
#!/bin/bash
echo "INVOKED $*" >> "$CLAUDE_SHIM_LOG"
prompt_arg=""
for a in "$@"; do prompt_arg="$a"; done

case "$prompt_arg" in
  *"Solo Time"*|*Bootstrap-Workflow*|*"neues Produkt"*)
    echo "I will run create_product, then create_product_vision, then bootstrap_from_vision"
    echo "and apply_bootstrap. This materializes Components and Features."
    ;;
  *"ZEN-042"*)
    echo "Step 1: get_feature for ZEN-042. Step 2: analyze_feature_security and set_security_classification."
    echo "Step 3: link_test and link_source_files. Step 4: create_revision. Step 5: validate_feature_security."
    ;;
  *"ZEN-007"*)
    echo "Security review for ZEN-007: set_security_classification, then analyze_feature_security,"
    echo "then suggest_security_tests, add_security_test, generate_threat_model (STRIDE),"
    echo "and finally complete_security_review."
    ;;
  *"scanne"*|*"Repository"*|*scan*)
    echo "First list_features to avoid duplicates. Then ghost_scan with enrich_existing=true,"
    echo "ghost_get_candidates, ghost_batch_review, and ghost_apply."
    ;;
  *Pulse-Session*|*"Pulse"*)
    echo "I will call pulse_start_session with the current git HEAD SHA and branch name."
    ;;
  *"ZEN-001"*|*released*)
    echo "Status transitions are not handled by an MCP tool. Use the Zensu REST API endpoint"
    echo "to set the status to released."
    ;;
  *"ZEN-999"*)
    echo "ZEN-999 does not appear in the feature list. Let me call list_features now —"
    echo "please bestätige welche Feature-ID gemeint ist."
    ;;
  *)
    echo "(shim: no matching prompt branch)"
    ;;
esac
SHIM
  chmod +x "$tmp/bin/claude"

  out="$tmp/out.txt"
  PATH="$tmp/bin:$PATH" \
    CLAUDE_SHIM_LOG="$shim_log" \
    FIXTURES_DIR="$tmp/fixtures" \
    EXPECTED_DIR="$TEST_DIR/expected" \
    PROMPTS_DIR="$TEST_DIR/prompts" \
    RESULTS_DIR="$tmp/results" \
    "$RUNNER" > "$out" 2>&1
  local rc=$?

  if [ "$rc" -eq 0 ] && grep -qE "TOTAL: 7/7" "$out"; then
    check "test_end_to_end_with_shim_claude" PASS
  else
    check "test_end_to_end_with_shim_claude" FAIL "rc=$rc out:$(printf '\n')$(cat "$out") shim_log:$(printf '\n')$(cat "$shim_log" 2>/dev/null)"
  fi
  rm -rf "$tmp"
}

test_status_transition_pattern_rejects_multiline_violation() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/status-transition" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/status-transition-20260101-000000.captured.txt" <<'CAP'
For status transitions, you can use either the REST API or update_feature.
I will call update_feature with:
- id: ZEN-001
- status: released
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+status-transition" "$out"; then
    check "test_status_transition_pattern_rejects_multiline_violation" PASS
  else
    check "test_status_transition_pattern_rejects_multiline_violation" FAIL "expected FAIL status-transition (multiline Rule-3 violation must be caught), got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_status_transition_pattern_rejects_reversed_order() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/status-transition" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/status-transition-20260101-000000.captured.txt" <<'CAP'
For the status released, I call update_feature(id=ZEN-001). Use the REST API endpoint for the transition.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+status-transition" "$out"; then
    check "test_status_transition_pattern_rejects_reversed_order" PASS
  else
    check "test_status_transition_pattern_rejects_reversed_order" FAIL "expected FAIL status-transition (reversed word-order Rule-3 violation must be caught), got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_status_transition_pattern_accepts_benign_disclaimer() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/status-transition" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/status-transition-20260101-000000.captured.txt" <<'CAP'
The update_feature tool does not support status transitions — use the REST API endpoint to release the feature.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+status-transition" "$out"; then
    check "test_status_transition_pattern_accepts_benign_disclaimer" PASS
  else
    check "test_status_transition_pattern_accepts_benign_disclaimer" FAIL "expected PASS status-transition (benign disclaimer must not trip negative assert), got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_status_transition_pattern_accepts_reversed_order_disclaimer() {
  local tmp out_a out_b
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures_a/status-transition" "$tmp/fixtures_b/status-transition" \
    "$tmp/prompts" "$tmp/results_a" "$tmp/results_b"

  cat > "$tmp/results_a/status-transition-20260101-000000.captured.txt" <<'CAP'
The status transition is not supported by update_feature. You should use the REST API endpoint instead.
CAP
  cat > "$tmp/results_b/status-transition-20260101-000000.captured.txt" <<'CAP'
Status changes can't be made via update_feature. Use the Zensu REST API endpoint.
CAP

  out_a="$tmp/out_a.txt"
  out_b="$tmp/out_b.txt"
  FIXTURES_DIR="$tmp/fixtures_a" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results_a" "$RUNNER" --offline > "$out_a" 2>&1
  FIXTURES_DIR="$tmp/fixtures_b" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results_b" "$RUNNER" --offline > "$out_b" 2>&1

  if grep -qE "PASS\s+status-transition" "$out_a" && grep -qE "PASS\s+status-transition" "$out_b"; then
    check "test_status_transition_pattern_accepts_reversed_order_disclaimer" PASS
  else
    check "test_status_transition_pattern_accepts_reversed_order_disclaimer" FAIL "expected PASS for both reversed-order disclaimers, got A:$(printf '\n')$(cat "$out_a")$(printf '\n')B:$(printf '\n')$(cat "$out_b")"
  fi
  rm -rf "$tmp"
}

test_empty_negative_assert_warns_not_fails() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/warntest" "$tmp/expected" "$tmp/prompts" "$tmp/results"

  echo "expected signal here" > "$tmp/results/warntest-20260101-000000.captured.txt"
  cat > "$tmp/expected/warntest.pattern" <<'PAT'
expected signal
!
PAT

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+warntest" "$out" \
     && grep -qE "WARN.*empty negative-assert needle" "$out"; then
    check "test_empty_negative_assert_warns_not_fails" PASS
  else
    check "test_empty_negative_assert_warns_not_fails" FAIL "expected PASS warntest + WARN diagnostic, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_whitespace_only_negative_assert_warns_not_fails() {
  local tmp out warn_count
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/warntest" "$tmp/expected" "$tmp/prompts" "$tmp/results"

  echo "expected signal here" > "$tmp/results/warntest-20260101-000000.captured.txt"
  printf 'expected signal\n! \n!  \n' > "$tmp/expected/warntest.pattern"

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  warn_count="$(grep -cE "WARN.*empty negative-assert needle" "$out" || true)"

  if grep -qE "PASS\s+warntest" "$out" && [ "$warn_count" -ge 2 ]; then
    check "test_whitespace_only_negative_assert_warns_not_fails" PASS
  else
    check "test_whitespace_only_negative_assert_warns_not_fails" FAIL "expected PASS warntest + at least 2 WARN diagnostics, got warn_count=$warn_count, out:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_warn_also_appears_in_report_file() {
  local tmp out report
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/warntest" "$tmp/expected" "$tmp/prompts" "$tmp/results"

  echo "expected signal here" > "$tmp/results/warntest-20260101-000000.captured.txt"
  cat > "$tmp/expected/warntest.pattern" <<'PAT'
expected signal
!
PAT

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$tmp/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  report="$(ls -t "$tmp/results"/report-*.txt 2>/dev/null | head -1)"

  if [ -z "$report" ] || [ ! -f "$report" ]; then
    check "test_warn_also_appears_in_report_file" FAIL "no report file produced under $tmp/results/"
    rm -rf "$tmp"
    return
  fi

  if grep -qE "WARN.*empty negative-assert needle" "$report" \
     && grep -qE "PASS\s+warntest" "$out"; then
    check "test_warn_also_appears_in_report_file" PASS
  else
    check "test_warn_also_appears_in_report_file" FAIL "expected WARN line in $report AND PASS warntest in stdout, report=$(printf '\n')$(cat "$report")$(printf '\n')stdout=$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_bootstrap_pattern_accepts_german_komponente() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/bootstrap" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/bootstrap-20260101-000000.captured.txt" <<'CAP'
I will run create_product, then create_product_vision, then bootstrap_from_vision
and apply_bootstrap. Decomposition:
- Komponente Time-Capture → Features: Start/Stop-Timer, Manual-Entry
- Komponente Reporting → Features: Weekly-View
- Komponenten und Feature-Skelette werden angelegt.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+bootstrap" "$out"; then
    check "test_bootstrap_pattern_accepts_german_komponente" PASS
  else
    check "test_bootstrap_pattern_accepts_german_komponente" FAIL "expected PASS bootstrap with German-only Komponente vocabulary, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_bootstrap_pattern_rejects_capture_without_any_component_word() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/bootstrap" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/bootstrap-20260101-000000.captured.txt" <<'CAP'
I will run create_product, then create_product_vision, then bootstrap_from_vision
and apply_bootstrap. I will skip decomposition and just create Features directly.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "FAIL\s+bootstrap" "$out"; then
    check "test_bootstrap_pattern_rejects_capture_without_any_component_word" PASS
  else
    check "test_bootstrap_pattern_rejects_capture_without_any_component_word" FAIL "expected FAIL bootstrap (no component/Komponente word), got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_feature_id_guard_accepts_which_product_phrasing() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/feature-id-guard" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/feature-id-guard-20260101-000000.captured.txt" <<'CAP'
Missing context:
- Which product? (need product_id for get_feature)
- ZEN-999 high number — confirm exist, not typo

Give product slug/id. Then load feature, run /zensu:implement workflow.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+feature-id-guard" "$out"; then
    check "test_feature_id_guard_accepts_which_product_phrasing" PASS
  else
    check "test_feature_id_guard_accepts_which_product_phrasing" FAIL "expected PASS feature-id-guard with ask-back phrasing, got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_feature_id_guard_rejects_silent_get_feature_call() {
  local tmp out failures=0 failure_details=""
  tmp="$(mktemp -d)"

  local violating_captures=(
    "I will now call get_feature for ZEN-999 and proceed with the implementation immediately. No further questions."
    "I will call get_feature with ZEN-999. The product_id is taken from the workspace."
    "Calling get_feature(ZEN-999) immediately — this is not a typo, proceeding to implementation."
    "I will load and paste ZEN-999 metadata, then get_feature directly."
    "Which product is this? Anyway, I will get_feature(ZEN-999) now."
    "Calling get_feature for ZEN-999. The product slug is timesheetly so I proceed."
    "Welche Komponente? egal, ich rufe get_feature ZEN-999 jetzt auf."
    "Bitte bestätige nichts — I just call get_feature ZEN-999 directly."
    "MCP tools not exposed but I will simulate get_feature ZEN-999 internally and proceed."
    "Yes please confirm; I will get_feature ZEN-999 now without waiting."
    $'Welche Komponente?\negal, ich rufe get_feature ZEN-999 jetzt auf.'
    $'Which product?\nAnyway proceeding with get_feature ZEN-999.'
    $'Welche Funktion soll ich aufrufen?\nIch werde get_feature ZEN-999 verwenden.'
    "I considered list_features but skipped it and called get_feature ZEN-999 anyway"
    "The ask-back contract does not exist, calling get_feature ZEN-999"
    "Wer ZEN-998 nicht gefunden hat, ist mir egal — ich rufe get_feature ZEN-999 auf."
    "Note: missing product_id. Anyway, get_feature ZEN-999."
    "I provide the product id myself — calling get_feature ZEN-999 directly"
    "I cannot call get_feature reliably, but I call get_feature ZEN-999 now."
    "Which product? Anyway proceeding with get_feature ZEN-999."
  )

  local idx=0
  for cap in "${violating_captures[@]}"; do
    idx=$((idx + 1))
    local sub="$tmp/case$idx"
    mkdir -p "$sub/fixtures/feature-id-guard" "$sub/prompts" "$sub/results"
    printf '%b\n' "$cap" > "$sub/results/feature-id-guard-20260101-000000.captured.txt"

    out="$sub/out.txt"
    FIXTURES_DIR="$sub/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$sub/prompts" \
      RESULTS_DIR="$sub/results" "$RUNNER" --offline > "$out" 2>&1

    if ! grep -qE "FAIL\s+feature-id-guard" "$out"; then
      failures=$((failures + 1))
      failure_details="$failure_details$(printf '\n--- case %d wrongly PASSed ---\ncapture: %s\noutput:\n%s' "$idx" "$cap" "$(cat "$out")")"
    fi
  done

  if [ "$failures" -eq 0 ]; then
    check "test_feature_id_guard_rejects_silent_get_feature_call" PASS
  else
    check "test_feature_id_guard_rejects_silent_get_feature_call" FAIL "$failures/${#violating_captures[@]} silent-violation captures wrongly PASSed (pattern over-permissive):$failure_details"
  fi
  rm -rf "$tmp"
}

test_feature_id_guard_accepts_paste_details_phrasing() {
  local tmp out
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/fixtures/feature-id-guard" "$tmp/prompts" "$tmp/results"

  cat > "$tmp/results/feature-id-guard-20260101-000000.captured.txt" <<'CAP'
MCP tools not exposed this session. Cannot call get_feature ZEN-999 directly.

Options:
1. User paste ZEN-999 feature details (status, security classification).
2. Run zensu CLI via Bash if installed.
CAP

  out="$tmp/out.txt"
  FIXTURES_DIR="$tmp/fixtures" EXPECTED_DIR="$TEST_DIR/expected" PROMPTS_DIR="$tmp/prompts" \
    RESULTS_DIR="$tmp/results" "$RUNNER" --offline > "$out" 2>&1

  if grep -qE "PASS\s+feature-id-guard" "$out"; then
    check "test_feature_id_guard_accepts_paste_details_phrasing" PASS
  else
    check "test_feature_id_guard_accepts_paste_details_phrasing" FAIL "expected PASS feature-id-guard (paste ZEN-XXX details is a valid Rule-2 ask-back), got:$(printf '\n')$(cat "$out")"
  fi
  rm -rf "$tmp"
}

test_known_caveats_documents_same_line_juxtaposition() {
  local readme missing=""
  readme="$TEST_DIR/README.md"
  if [ ! -f "$readme" ]; then
    check "test_known_caveats_documents_same_line_juxtaposition" FAIL "README not found at $readme"
    return
  fi
  grep -qF "bare juxtaposition" "$readme" || missing="$missing bare-juxtaposition"
  grep -qE "same[- ]line" "$readme" || missing="$missing same-line"
  grep -qF "YAML" "$readme" || missing="$missing YAML"
  grep -qF "update_feature taking status=" "$readme" || missing="$missing example-taking-status"
  grep -qF "update_feature accepting parameter status=" "$readme" || missing="$missing example-accepting-parameter-status"
  grep -qF "tool: update_feature" "$readme" || missing="$missing example-yaml-tool-line"
  grep -qF '`update_feature status=released` (bare juxtaposition)' "$readme" || missing="$missing example-bare-juxtaposition"

  if [ -z "$missing" ]; then
    check "test_known_caveats_documents_same_line_juxtaposition" PASS
  else
    check "test_known_caveats_documents_same_line_juxtaposition" FAIL "README missing required substrings:$missing"
  fi
}

echo "=== tests/e2e-plm/test-runner.sh ==="
test_self_check_emits_total_zero
test_unknown_mode_rejected
test_pattern_positive_and_missing
test_negative_assert_lines
test_hash_comments_skipped
test_offline_uses_newest_no_spawn
test_self_check_skips_claude
test_full_mode_invokes_zensu_plm_agent
test_full_mode_passes_prompt_content
test_zero_byte_capture_diagnostic
test_missing_prompt_file_diagnostic
test_setup_fixtures_idempotent
test_shipped_patterns_pass_against_ideal_capture
test_shipped_patterns_reject_bad_captures
test_end_to_end_with_shim_claude
test_status_transition_pattern_rejects_multiline_violation
test_status_transition_pattern_rejects_reversed_order
test_status_transition_pattern_accepts_benign_disclaimer
test_status_transition_pattern_accepts_reversed_order_disclaimer
test_empty_negative_assert_warns_not_fails
test_whitespace_only_negative_assert_warns_not_fails
test_warn_also_appears_in_report_file
test_bootstrap_pattern_accepts_german_komponente
test_bootstrap_pattern_rejects_capture_without_any_component_word
test_feature_id_guard_accepts_which_product_phrasing
test_feature_id_guard_rejects_silent_get_feature_call
test_feature_id_guard_accepts_paste_details_phrasing
test_known_caveats_documents_same_line_juxtaposition

echo ""
echo "Result: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
