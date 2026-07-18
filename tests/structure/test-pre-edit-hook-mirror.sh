#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

seed_active() {
  local state_dir="$1" session_id="$2" phase="${3:-}"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
  export CLAUDE_PROJECT_DIR="$state_dir"
  export ZENSU_TEST_PLUGIN_DATA="$state_dir/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$session_id" || return 1
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
  tdd_set_flag "$session_id" active true >/dev/null 2>&1 || return 1
  [ -z "$phase" ] || tdd_write_phase "$session_id" S1 "$phase" "" >/dev/null 2>&1
}

seed_inactive() {
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
  export CLAUDE_PROJECT_DIR="$1"
  export ZENSU_TEST_PLUGIN_DATA="$1/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$2"
}

if [ ! -f "$HOOK" ]; then
  check "hooks/pre-edit-tdd-reminder.sh exists" FAIL
  echo "----"
  echo "test-pre-edit-hook-mirror: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "hooks/pre-edit-tdd-reminder.sh exists" PASS

if bash -n "$HOOK" 2>/dev/null; then
  check "C1 bash -n syntax check passes" PASS
else
  check "C1 bash -n syntax check passes" FAIL
fi

LOG_COMMAND_DEFINITION_COUNT="$(grep -c '^LOG_COMMAND=' "$HOOK" 2>/dev/null || true)"
LOG_COMMAND_USE_COUNT="$(grep -cF 'PAYLOAD_LOG_COMMAND="$LOG_COMMAND"' "$HOOK" 2>/dev/null || true)"
if [ "$LOG_COMMAND_DEFINITION_COUNT" = 1 ] && [ "$LOG_COMMAND_USE_COUNT" = 2 ]; then
  check "C1b guarded zensu-log command has one definition reused by both denial renderers" PASS
else
  check "C1b guarded zensu-log command deduplicated (definitions=$LOG_COMMAND_DEFINITION_COUNT uses=$LOG_COMMAND_USE_COUNT)" FAIL
fi

PAYLOAD_DENY='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.ts"},"session_id":"hookmirror-test"}'

C2_STATE_DIR="$(mktemp -d -t hookmirror-c2-XXXX)"
C2_LOG="$C2_STATE_DIR/should-not-exist.log"
seed_active "$C2_STATE_DIR" "hookmirror-test"
unset ZENSU_HOOK_LOG 2>/dev/null || true
OUT_C2=$(printf '%s' "$PAYLOAD_DENY" | \
  STATE_DIR="$C2_STATE_DIR" bash "$HOOK" 2>&1)
RC_C2=$?
if [ "$RC_C2" = "0" ] && [ ! -f "$C2_LOG" ]; then
  check "C2 no ZENSU_HOOK_LOG + denial path -> no mirror file" PASS
else
  check "C2 no ZENSU_HOOK_LOG + denial path -> no mirror file (rc=$RC_C2, log_exists=$([ -f "$C2_LOG" ] && echo y || echo n))" FAIL
fi
rm -rf "$C2_STATE_DIR"

C3_STATE_DIR="$(mktemp -d -t hookmirror-c3-XXXX)"
C3_LOG="$(mktemp -t hookmirror-c3-log-XXXX)"
C3_EXPECTED="$(mktemp -t hookmirror-c3-exp-XXXX)"
: > "$C3_LOG"
seed_active "$C3_STATE_DIR" "hookmirror-test"
cat >"$C3_EXPECTED" <<'EXPECTED'
[hook: PreToolUse] TDD-Phase-Gate: Edit on /tmp/x.ts blocked.
[hook: PreToolUse] Current phase: UNINITIALIZED, step: .
[hook: PreToolUse] Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step ) | (GREEN_PASS only on test paths).
[hook: PreToolUse] permissionDecision=deny
EXPECTED
OUT_C3=$(printf '%s' "$PAYLOAD_DENY" | \
  STATE_DIR="$C3_STATE_DIR" ZENSU_HOOK_LOG="$C3_LOG" bash "$HOOK" 2>&1)
RC_C3=$?
C3_LINES=$(wc -l < "$C3_LOG" 2>/dev/null | tr -d ' ')
C3_DIFF=$(diff "$C3_EXPECTED" "$C3_LOG" 2>&1)
C3_CONTENT="$(cat "$C3_LOG" 2>/dev/null)"
if [ "$RC_C3" = "0" ] && [ "$C3_LINES" = "4" ] && [ -z "$C3_DIFF" ]; then
  check "C3 denial (UNINITIALIZED) + ZENSU_HOOK_LOG -> exact 4-line mirror matches fixture" PASS
else
  check "C3 denial + ZENSU_HOOK_LOG -> exact 4-line mirror (rc=$RC_C3, lines=$C3_LINES, diff=${C3_DIFF:0:300}, content=${C3_CONTENT:0:300})" FAIL
fi
rm -rf "$C3_STATE_DIR" "$C3_LOG" "$C3_EXPECTED"

C4_STATE_DIR="$(mktemp -d -t hookmirror-c4-XXXX)"
C4_LOG="$(mktemp -t hookmirror-c4-log-XXXX)"
: > "$C4_LOG"
seed_active "$C4_STATE_DIR" "hookmirror-test" "RED_WRITE"
OUT_C4=$(printf '%s' "$PAYLOAD_DENY" | \
  STATE_DIR="$C4_STATE_DIR" ZENSU_HOOK_LOG="$C4_LOG" bash "$HOOK" 2>&1)
RC_C4=$?
C4_CONTENT="$(cat "$C4_LOG" 2>/dev/null)"
if [ "$RC_C4" = "0" ] && [ -z "$C4_CONTENT" ]; then
  check "C4 RED_WRITE (allow) + ZENSU_HOOK_LOG -> no mirror" PASS
else
  check "C4 RED_WRITE allow path -> no mirror (rc=$RC_C4, content=${C4_CONTENT:0:200})" FAIL
fi
rm -rf "$C4_STATE_DIR" "$C4_LOG"

C5_STATE_DIR="$(mktemp -d -t hookmirror-c5-XXXX)"
seed_active "$C5_STATE_DIR" "hookmirror-test"
OUT_C5=$(printf '%s' "$PAYLOAD_DENY" | \
  STATE_DIR="$C5_STATE_DIR" \
  ZENSU_HOOK_LOG=/dev/null/cannot-write bash "$HOOK" 2>&1)
RC_C5=$?
if [ "$RC_C5" = "0" ]; then
  check "C5 unwritable ZENSU_HOOK_LOG + denial -> hook still exits 0" PASS
else
  check "C5 unwritable ZENSU_HOOK_LOG -> exit 0 (rc=$RC_C5, out=${OUT_C5:0:200})" FAIL
fi
rm -rf "$C5_STATE_DIR"

C6_STATE_DIR="$(mktemp -d -t hookmirror-c6-XXXX)"
C6_LOG="$(mktemp -t hookmirror-c6-log-XXXX)"
: > "$C6_LOG"
seed_active "$C6_STATE_DIR" "hookmirror-test"
OUT_C6=$(printf '%s' "$PAYLOAD_DENY" | \
  STATE_DIR="$C6_STATE_DIR" \
  ZENSU_TDD_GATE=off ZENSU_HOOK_LOG="$C6_LOG" bash "$HOOK" 2>&1)
RC_C6=$?
C6_CONTENT="$(cat "$C6_LOG" 2>/dev/null)"
if [ "$RC_C6" = "0" ] && [ -z "$C6_CONTENT" ]; then
  check "C6 ZENSU_TDD_GATE=off -> no mirror (early exit precedes mirror)" PASS
else
  check "C6 ZENSU_TDD_GATE=off -> no mirror (rc=$RC_C6, content=${C6_CONTENT:0:200})" FAIL
fi
rm -rf "$C6_STATE_DIR" "$C6_LOG"

C7_STATE_DIR="$(mktemp -d -t hookmirror-c7-XXXX)"
C7_LOG="$(mktemp -t hookmirror-c7-log-XXXX)"
: > "$C7_LOG"
seed_inactive "$C7_STATE_DIR" "hookmirror-test"
OUT_C7=$(printf '%s' "$PAYLOAD_DENY" | \
  STATE_DIR="$C7_STATE_DIR" ZENSU_HOOK_LOG="$C7_LOG" bash "$HOOK" 2>&1)
RC_C7=$?
C7_CONTENT="$(cat "$C7_LOG" 2>/dev/null)"
if [ "$RC_C7" = "0" ] && [ -z "$C7_CONTENT" ]; then
  check "C7 session not activated -> no mirror (chain-state scope guard)" PASS
else
  check "C7 session not activated -> no mirror (rc=$RC_C7, content=${C7_CONTENT:0:200})" FAIL
fi
rm -rf "$C7_STATE_DIR" "$C7_LOG"

C8_STATE_DIR="$(mktemp -d -t hookmirror-c8-XXXX)"
C8_LOG="$(mktemp -t hookmirror-c8-log-XXXX)"
: > "$C8_LOG"
seed_active "$C8_STATE_DIR" "hookmirror-test"
PAYLOAD_ZENSU='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"/work/proj/.zensu/plans/2026-01-01_tdd-x.md"},"session_id":"hookmirror-test"}'
OUT_C8=$(printf '%s' "$PAYLOAD_ZENSU" | \
  STATE_DIR="$C8_STATE_DIR" ZENSU_HOOK_LOG="$C8_LOG" bash "$HOOK" 2>&1)
RC_C8=$?
C8_CONTENT="$(cat "$C8_LOG" 2>/dev/null)"
if [ "$RC_C8" = "0" ] && [ -z "$C8_CONTENT" ] && ! printf '%s' "$OUT_C8" | grep -qF 'permissionDecision'; then
  check "C8 .zensu/ path under UNINITIALIZED -> allowed (no deny JSON, no mirror)" PASS
else
  check "C8 .zensu/ path allowed (rc=$RC_C8, content=${C8_CONTENT:0:160}, out=${OUT_C8:0:160})" FAIL
fi
rm -rf "$C8_STATE_DIR" "$C8_LOG"

C9_STATE_DIR="$(mktemp -d -t hookmirror-c9-XXXX)"
seed_active "$C9_STATE_DIR" "hookmirror-test"
if [ -d "$C9_STATE_DIR/.zensu" ]; then
  check "C9p seeded project prefix exists before traversal normalization" PASS
else
  check "C9p seeded project prefix exists before traversal normalization" FAIL
fi
C9_CLASSIFIER_MARKER="$C9_STATE_DIR/classifier-exclusions"
C9_PRELOAD_SHELL="$PLUGIN_DIR/tests/structure/fixtures/pre-edit-classifier-transport-preload.js"
C9_NODE_OPTIONS="--require=$C9_PRELOAD_SHELL"
C9_BASE_EXCLUSIONS='EXISTING_SELECTOR'
# Exercise the traversal alias beneath the real seeded project. Its `.zensu`
# prefix exists, so Git Bash can canonicalize `..` before the native classifier;
# an unrelated `/work/proj` fixture fails earlier on Windows for the correct
# ENOENT reason and never tests the intended classifier transport boundary.
PAYLOAD_TRAVERSAL='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":".zensu/../src/main.ts"},"session_id":"hookmirror-test"}'
C9_EXPECTED_REASON='TDD-Phase-Gate: Write on .zensu/../src/main.ts blocked.'
C9_BASELINE="$(
  unset FP SD
  printf '%s' "$PAYLOAD_TRAVERSAL" | \
    MSYS2_ENV_CONV_EXCL="$C9_BASE_EXCLUSIONS" \
    STATE_DIR="$C9_STATE_DIR" bash "$HOOK" 2>&1
)"
C9_BASELINE_RC=$?
if [ "$C9_BASELINE_RC" = "0" ] && printf '%s' "$C9_BASELINE" | grep -qF "$C9_EXPECTED_REASON" \
  && [ ! -e "$C9_CLASSIFIER_MARKER" ]; then
  check "C9a uninstrumented full hook preserves ambient MSYS exclusions" PASS
else
  check "C9a uninstrumented full hook reaches traversal deny (rc=$C9_BASELINE_RC, marker=$([ -e "$C9_CLASSIFIER_MARKER" ] && echo y || echo n), out=${C9_BASELINE:0:240})" FAIL
fi
C9_NEGATIVE_RC=0
NODE_OPTIONS="$C9_NODE_OPTIONS" ZENSU_TEST_PRE_EDIT_CLASSIFIER_PROBE=1 \
  ZENSU_TEST_PRE_EDIT_CLASSIFIER_MARKER="$C9_CLASSIFIER_MARKER" \
  MSYS2_ENV_CONV_EXCL="${C9_BASE_EXCLUSIONS};SD=" \
  FP=/native/file SD=/native/state node -e 'process.exit(0)' \
  >/dev/null 2>&1 || C9_NEGATIVE_RC=$?
if [ "$C9_NEGATIVE_RC" = "91" ] && [ ! -e "$C9_CLASSIFIER_MARKER" ]; then
  check "C9b classifier canary rejects a missing FP exclusion" PASS
else
  check "C9b classifier canary detects missing FP exclusion (rc=$C9_NEGATIVE_RC, marker=$([ -e "$C9_CLASSIFIER_MARKER" ] && echo y || echo n))" FAIL
fi
OUT_C9="$(
  unset FP SD
  printf '%s' "$PAYLOAD_TRAVERSAL" | \
    NODE_OPTIONS="$C9_NODE_OPTIONS" ZENSU_TEST_PRE_EDIT_CLASSIFIER_PROBE=1 \
    ZENSU_TEST_PRE_EDIT_CLASSIFIER_MARKER="$C9_CLASSIFIER_MARKER" \
    MSYS2_ENV_CONV_EXCL="$C9_BASE_EXCLUSIONS" \
    STATE_DIR="$C9_STATE_DIR" bash "$HOOK" 2>&1
)"
RC_C9=$?
C9_EXCLUSIONS="$(cat "$C9_CLASSIFIER_MARKER" 2>/dev/null)"
C9_EXCLUSIONS_OK=true
for C9_NAME in EXISTING_SELECTOR FP= SD=; do
  case ";$C9_EXCLUSIONS;" in *";$C9_NAME;"*) ;; *) C9_EXCLUSIONS_OK=false ;; esac
done
if [ "$RC_C9" = "0" ] && printf '%s' "$OUT_C9" | grep -qF "$C9_EXPECTED_REASON" \
  && [ -e "$C9_CLASSIFIER_MARKER" ] && [ "$C9_EXCLUSIONS_OK" = true ]; then
  check "C9 .zensu/../ traversal stays gated with explicit native FP/SD transport" PASS
else
  check "C9 traversal native transport (rc=$RC_C9, marker=$([ -e "$C9_CLASSIFIER_MARKER" ] && echo y || echo n), exclusions=${C9_EXCLUSIONS:0:160}, out=${OUT_C9:0:240})" FAIL
fi
rm -rf "$C9_STATE_DIR"

# Main-thread edit authority comes only from the trusted payload principal.
# Neither ZENSU_FORCE_MAIN nor a partial agent identity may reach the bypass
# ledger, denial renderer, or its concrete helper command.
C10_STATE_DIR="$(mktemp -d -t hookmirror-c10-XXXX)"
seed_active "$C10_STATE_DIR" "hookmirror-principal"
C10_STATE_FILE="$(tdd_state_file "$ZENSU_SESSION_KEY")"
C10_BEFORE="$(node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$C10_STATE_FILE")"
C10_OK=true
for C10_KIND in reviewer plm neutral partial; do
  C10_PAYLOAD="$(BASE="$PAYLOAD_DENY" KIND="$C10_KIND" node -e '
    const p=JSON.parse(process.env.BASE); p.session_id="hookmirror-principal";
    if(process.env.KIND==="reviewer")p.agent_type="zensu:code-reviewer";
    if(process.env.KIND==="plm")p.agent_type="zensu:zensu-plm";
    if(process.env.KIND==="neutral")p.agent_type="custom-agent";
    if(process.env.KIND==="partial")p.agent_id="child-only";
    process.stdout.write(JSON.stringify(p));
  ')"
  C10_OUT="$(printf '%s' "$C10_PAYLOAD" | ZENSU_FORCE_MAIN=1 ZENSU_TDD_GATE=off \
    STATE_DIR="$C10_STATE_DIR" bash "$HOOK" 2>&1)"
  [ -z "$C10_OUT" ] || C10_OK=false
done
C10_AFTER="$(node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$C10_STATE_FILE")"
if [ "$C10_OK" = true ] && [ "$C10_AFTER" = "$C10_BEFORE" ]; then
  check "C10 reviewer/PLM/neutral/partial principals are silent and byte-stable despite ZENSU_FORCE_MAIN" PASS
else
  check "C10 non-main principals are silent and byte-stable" FAIL
fi
rm -rf "$C10_STATE_DIR"

# Execute the command prefix copied verbatim from the denial text. This proves
# the model-facing command supplies the per-call plugin-data binding rather
# than depending on inherited ZENSU_* selectors.
C11_STATE_DIR="$(mktemp -d -t hookmirror-c11-XXXX)"
seed_active "$C11_STATE_DIR" "hookmirror-command"
C11_PAYLOAD="$(BASE="$PAYLOAD_DENY" node -e 'const p=JSON.parse(process.env.BASE);p.session_id="hookmirror-command";process.stdout.write(JSON.stringify(p))')"
C11_OUT="$(printf '%s' "$C11_PAYLOAD" | STATE_DIR="$C11_STATE_DIR" bash "$HOOK" 2>/dev/null)"
C11_HELPER_Q="$(printf '%q' "$PLUGIN_DIR/hooks/lib/zensu-log.sh")"
C11_DATA_Q="$(printf '%q' "$CLAUDE_PLUGIN_DATA")"
C11_PREFIX="CLAUDE_PLUGIN_DATA=$C11_DATA_Q bash $C11_HELPER_Q"
C11_MSYS_EXCL="EXPECTED"
[ -z "${MSYS2_ENV_CONV_EXCL:-}" ] || C11_MSYS_EXCL="${MSYS2_ENV_CONV_EXCL};${C11_MSYS_EXCL}"
C11_EMITTED_PREFIX="$(printf '%s' "$C11_OUT" | MSYS2_ENV_CONV_EXCL="$C11_MSYS_EXCL" EXPECTED="$C11_PREFIX" node -e '
  const body=require("fs").readFileSync(0,"utf8"), expected=process.env.EXPECTED;
  const at=body.indexOf(expected); if(at<0)process.exit(1);
  process.stdout.write(body.slice(at,at+expected.length));
' 2>/dev/null)"
C11_EXTRACT_RC=$?
eval "$C11_EMITTED_PREFIX --phase RED_WRITE --step emitted-command" >/dev/null 2>&1
C11_EXEC_RC=$?
C11_PHASE="$(tdd_phase "$(tdd_state_file "$ZENSU_SESSION_KEY")")"
if [ "$C11_EXTRACT_RC" = 0 ] && [ "$C11_EXEC_RC" = 0 ] && [ "$C11_PHASE" = RED_WRITE ]; then
  check "C11 command prefix extracted from denial executes with native per-call binding" PASS
else
  check "C11 emitted command prefix executes (extract=$C11_EXTRACT_RC exec=$C11_EXEC_RC phase=$C11_PHASE)" FAIL
fi
rm -rf "$C11_STATE_DIR"

echo "----"
echo "test-pre-edit-hook-mirror: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
