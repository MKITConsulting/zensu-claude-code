#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
SCRIPT="$EVAL_DIR/run-eval.sh"

PASS=0
FAIL=0
TESTS=()

register() {
  TESTS+=("$1")
}

check() {
  local label="$1" cond="$2" detail="${3:-}"
  if [ "$cond" = "PASS" ]; then
    PASS=$((PASS + 1))
    echo "  PASS  $label"
  else
    FAIL=$((FAIL + 1))
    if [ -n "$detail" ]; then
      echo "  FAIL  $label  -- $detail"
    else
      echo "  FAIL  $label"
    fi
  fi
}

run_all() {
  for t in "${TESTS[@]}"; do
    "$t"
  done
  echo ""
  echo "════════════════════════════════════════"
  echo "  TOTAL: $PASS/$((PASS + FAIL)) PASS ($FAIL FAIL)"
  echo "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
}

list_tests() {
  printf '%s\n' "${TESTS[@]}"
}

test_skeleton_self_test() {
  if [ -n "$EVAL_DIR" ] && [ -f "$SCRIPT" ]; then
    check "test_skeleton_self_test" PASS
  else
    check "test_skeleton_self_test" FAIL "EVAL_DIR='$EVAL_DIR' SCRIPT='$SCRIPT'"
  fi
}

register test_skeleton_self_test

test_reset_project_aborts_when_project_dir_missing() {
  local tmp out rc
  tmp="$(mktemp -d)"
  out="$tmp/out.txt"
  (
    cd "$tmp" || exit 1
    PROJECT_DIR="$tmp/nonexistent-test-project" \
      bash -c "source '$SCRIPT' 2>/dev/null; reset_project" \
      > "$out" 2>&1
  )
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qiE 'project_dir|test-project' "$out" && grep -qiE 'missing|not.found|unreadable' "$out"; then
    check "test_reset_project_aborts_when_project_dir_missing" PASS
  else
    check "test_reset_project_aborts_when_project_dir_missing" FAIL "rc=$rc out: $(head -5 "$out")"
  fi
  rm -rf "$tmp"
}

register test_reset_project_aborts_when_project_dir_missing

test_reset_project_aborts_when_not_own_toplevel() {
  local sandbox out rc sentinel
  sandbox="$(mktemp -d "$PLUGIN_DIR/tmp-hermetic-sandbox-XXXXXX")"
  sentinel="$sandbox/canary-$$.txt"
  echo "must-survive" > "$sentinel"
  out="$sandbox/out.txt"
  (
    cd "$sandbox" || exit 1
    PROJECT_DIR="$sandbox" \
      bash -c "source '$SCRIPT' 2>/dev/null; reset_project" \
      > "$out" 2>&1
  )
  rc=$?
  local pass=true
  [ "$rc" -eq 0 ] && pass=false
  grep -qiE 'toplevel|enclosing|refusing' "$out" || pass=false
  if $pass; then
    check "test_reset_project_aborts_when_not_own_toplevel" PASS
  else
    check "test_reset_project_aborts_when_not_own_toplevel" FAIL "rc=$rc sentinel=$([ -f "$sentinel" ] && echo present || echo MISSING) out: $(head -5 "$out")"
  fi
  rm -rf "$sandbox"
}

register test_reset_project_aborts_when_not_own_toplevel

test_self_check_runs_without_destruction() {
  local tmp out rc reviewer_hash_before reviewer_hash_after tdd_hash_before tdd_hash_after
  local plans_before plans_after logs_before logs_after results_before results_after
  tmp="$(mktemp -d)"
  out="$tmp/out.txt"
  reviewer_hash_before="$(shasum -a 256 "$PLUGIN_DIR/agents/code-reviewer.md" | awk '{print $1}')"
  tdd_hash_before="$(shasum -a 256 "$PLUGIN_DIR/agents/tdd-manager.md" | awk '{print $1}')"
  plans_before="$(ls -1 "$PLUGIN_DIR/.zensu/plans" 2>/dev/null | sort | tr '\n' ' ')"
  logs_before="$(ls -1 "$PLUGIN_DIR/.zensu/logs" 2>/dev/null | sort | tr '\n' ' ')"
  results_before="$(ls -1 "$EVAL_DIR/results" 2>/dev/null | sort | tr '\n' ' ')"

  (
    cd "$tmp" || exit 1
    bash "$SCRIPT" --self-check > "$out" 2>&1
  )
  rc=$?

  reviewer_hash_after="$(shasum -a 256 "$PLUGIN_DIR/agents/code-reviewer.md" | awk '{print $1}')"
  tdd_hash_after="$(shasum -a 256 "$PLUGIN_DIR/agents/tdd-manager.md" | awk '{print $1}')"
  plans_after="$(ls -1 "$PLUGIN_DIR/.zensu/plans" 2>/dev/null | sort | tr '\n' ' ')"
  logs_after="$(ls -1 "$PLUGIN_DIR/.zensu/logs" 2>/dev/null | sort | tr '\n' ' ')"
  results_after="$(ls -1 "$EVAL_DIR/results" 2>/dev/null | sort | tr '\n' ' ')"

  local pass=true reasons=""
  [ "$rc" -ne 0 ] && { pass=false; reasons+="rc=$rc "; }
  [ "$reviewer_hash_before" != "$reviewer_hash_after" ] && { pass=false; reasons+="reviewer-hash-changed "; }
  [ "$tdd_hash_before" != "$tdd_hash_after" ] && { pass=false; reasons+="tdd-hash-changed "; }
  [ "$plans_before" != "$plans_after" ] && { pass=false; reasons+="plans-listing-changed "; }
  [ "$logs_before" != "$logs_after" ] && { pass=false; reasons+="logs-listing-changed "; }
  [ "$results_before" != "$results_after" ] && { pass=false; reasons+="results-listing-changed "; }
  grep -qiE 'self.check|structural' "$out" || { pass=false; reasons+="no-self-check-marker "; }

  if $pass; then
    check "test_self_check_runs_without_destruction" PASS
  else
    check "test_self_check_runs_without_destruction" FAIL "$reasons | out-head: $(head -3 "$out")"
  fi
  rm -rf "$tmp"
}

register test_self_check_runs_without_destruction

test_unknown_flag_rejected() {
  local tmp out rc
  tmp="$(mktemp -d)"
  out="$tmp/out.txt"
  (
    cd "$tmp" || exit 1
    bash "$SCRIPT" --bogus > "$out" 2>&1
  )
  rc=$?
  if [ "$rc" -eq 2 ] && grep -qi "unknown mode" "$out"; then
    check "test_unknown_flag_rejected" PASS
  else
    check "test_unknown_flag_rejected" FAIL "rc=$rc (expected 2); out-head: $(head -3 "$out")"
  fi
  rm -rf "$tmp"
}

register test_unknown_flag_rejected

test_self_check_preserves_agents_modifications() {
  local agent_file backup tmp out rc sentinel
  agent_file="$PLUGIN_DIR/agents/code-reviewer.md"
  backup="$(mktemp)"
  cp "$agent_file" "$backup"
  sentinel="# TEST_SENTINEL_$(od -An -N4 -tx1 /dev/urandom | tr -d ' ')"
  printf '\n%s\n' "$sentinel" >> "$agent_file"
  tmp="$(mktemp -d)"
  out="$tmp/out.txt"
  (
    cd "$tmp" || exit 1
    bash "$SCRIPT" --self-check > "$out" 2>&1
  )
  rc=$?
  local survived=true
  if ! grep -qF "$sentinel" "$agent_file"; then
    survived=false
  fi
  cp "$backup" "$agent_file"
  rm -f "$backup"
  rm -rf "$tmp"
  if [ "$rc" -eq 0 ] && $survived; then
    check "test_self_check_preserves_agents_modifications" PASS
  else
    check "test_self_check_preserves_agents_modifications" FAIL "rc=$rc survived=$survived"
  fi
}

register test_self_check_preserves_agents_modifications

test_self_check_preserves_zensu() {
  local marker tmp out rc
  marker="$PLUGIN_DIR/.zensu/test-marker-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' ').txt"
  echo "must-survive" > "$marker"
  tmp="$(mktemp -d)"
  out="$tmp/out.txt"
  (
    cd "$tmp" || exit 1
    bash "$SCRIPT" --self-check > "$out" 2>&1
  )
  rc=$?
  local survived=true
  [ ! -f "$marker" ] && survived=false
  rm -f "$marker"
  rm -rf "$tmp"
  if [ "$rc" -eq 0 ] && $survived; then
    check "test_self_check_preserves_zensu" PASS
  else
    check "test_self_check_preserves_zensu" FAIL "rc=$rc survived=$survived"
  fi
}

register test_self_check_preserves_zensu

test_self_check_works_from_multiple_cwds() {
  local cwd1 cwd2 out1 out2 rc1 rc2
  cwd1="$PLUGIN_DIR"
  cwd2="$(mktemp -d)"
  out1="$cwd2/out1.txt"
  out2="$cwd2/out2.txt"
  (cd "$cwd1" && bash "$SCRIPT" --self-check > "$out1" 2>&1)
  rc1=$?
  (cd "$cwd2" && bash "$SCRIPT" --self-check > "$out2" 2>&1)
  rc2=$?
  local pass=true reasons=""
  [ "$rc1" -ne 0 ] && { pass=false; reasons+="cwd1-rc=$rc1 "; }
  [ "$rc2" -ne 0 ] && { pass=false; reasons+="cwd2-rc=$rc2 "; }
  grep -qiE 'self.check' "$out1" || { pass=false; reasons+="cwd1-no-marker "; }
  grep -qiE 'self.check' "$out2" || { pass=false; reasons+="cwd2-no-marker "; }
  rm -rf "$cwd2"
  if $pass; then
    check "test_self_check_works_from_multiple_cwds" PASS
  else
    check "test_self_check_works_from_multiple_cwds" FAIL "$reasons"
  fi
}

register test_self_check_works_from_multiple_cwds

test_full_mode_aborts_when_project_dir_missing() {
  local tmp out rc
  tmp="$(mktemp -d)"
  out="$tmp/out.txt"
  (
    cd "$tmp" || exit 1
    PROJECT_DIR="$tmp/nonexistent-test-project" \
      bash "$SCRIPT" > "$out" 2>&1
  )
  rc=$?
  local pass=true reasons=""
  [ "$rc" -ne 2 ] && { pass=false; reasons+="rc=$rc(expected 2) "; }
  grep -qi "test-project missing" "$out" || { pass=false; reasons+="no-diagnostic "; }
  grep -qi "claude -p\|Running run1\|Eval Suite" "$out" && { pass=false; reasons+="reached-claude-or-eval-body "; }
  if $pass; then
    check "test_full_mode_aborts_when_project_dir_missing" PASS
  else
    check "test_full_mode_aborts_when_project_dir_missing" FAIL "$reasons | out-head: $(head -5 "$out")"
  fi
  rm -rf "$tmp"
}

register test_full_mode_aborts_when_project_dir_missing

MODE="${1:-run}"
case "$MODE" in
  --list) list_tests; exit 0 ;;
  run|"") run_all; exit $? ;;
  *) echo "unknown mode: $MODE (accepted: --list, run)" >&2; exit 2 ;;
esac
