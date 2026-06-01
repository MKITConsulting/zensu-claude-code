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
  mkdir -p "$1"
  if [ -n "${3:-}" ]; then
    printf '{"session_id":"%s","active":true,"phase":"%s","step_id":"S1","history":[{"step":"S1","phase":"%s","ts":"2026-05-22T00:00:00Z"}]}\n' \
      "$2" "$3" "$3" > "$1/tdd-phase-$2.json"
  else
    printf '{"session_id":"%s","active":true}\n' "$2" > "$1/tdd-phase-$2.json"
  fi
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

PAYLOAD_DENY='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.ts"},"session_id":"hookmirror-test"}'

C2_STATE_DIR="$(mktemp -d -t hookmirror-c2-XXXX)"
C2_LOG="$C2_STATE_DIR/should-not-exist.log"
seed_active "$C2_STATE_DIR" "hookmirror-test"
unset ZENSU_HOOK_LOG 2>/dev/null || true
OUT_C2=$(printf '%s' "$PAYLOAD_DENY" | \
  TDD_STATE_DIR="$C2_STATE_DIR" bash "$HOOK" 2>&1)
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
  TDD_STATE_DIR="$C3_STATE_DIR" ZENSU_HOOK_LOG="$C3_LOG" bash "$HOOK" 2>&1)
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
  TDD_STATE_DIR="$C4_STATE_DIR" ZENSU_HOOK_LOG="$C4_LOG" bash "$HOOK" 2>&1)
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
  TDD_STATE_DIR="$C5_STATE_DIR" \
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
  TDD_STATE_DIR="$C6_STATE_DIR" \
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
OUT_C7=$(printf '%s' "$PAYLOAD_DENY" | \
  TDD_STATE_DIR="$C7_STATE_DIR" ZENSU_HOOK_LOG="$C7_LOG" bash "$HOOK" 2>&1)
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
PAYLOAD_ZENSU='{"tool_name":"Write","tool_input":{"file_path":"/work/proj/.zensu/plans/2026-01-01_tdd-x.md"},"session_id":"hookmirror-test"}'
OUT_C8=$(printf '%s' "$PAYLOAD_ZENSU" | \
  TDD_STATE_DIR="$C8_STATE_DIR" ZENSU_HOOK_LOG="$C8_LOG" bash "$HOOK" 2>&1)
RC_C8=$?
C8_CONTENT="$(cat "$C8_LOG" 2>/dev/null)"
if [ "$RC_C8" = "0" ] && [ -z "$C8_CONTENT" ] && ! printf '%s' "$OUT_C8" | grep -qF 'permissionDecision'; then
  check "C8 .zensu/ path under UNINITIALIZED -> allowed (no deny JSON, no mirror)" PASS
else
  check "C8 .zensu/ path allowed (rc=$RC_C8, content=${C8_CONTENT:0:160}, out=${OUT_C8:0:160})" FAIL
fi
rm -rf "$C8_STATE_DIR" "$C8_LOG"

C9_STATE_DIR="$(mktemp -d -t hookmirror-c9-XXXX)"
C9_LOG="$(mktemp -t hookmirror-c9-log-XXXX)"
: > "$C9_LOG"
seed_active "$C9_STATE_DIR" "hookmirror-test"
PAYLOAD_TRAVERSAL='{"tool_name":"Write","tool_input":{"file_path":"/work/proj/.zensu/../src/main.ts"},"session_id":"hookmirror-test"}'
OUT_C9=$(printf '%s' "$PAYLOAD_TRAVERSAL" | \
  TDD_STATE_DIR="$C9_STATE_DIR" ZENSU_HOOK_LOG="$C9_LOG" bash "$HOOK" 2>&1)
RC_C9=$?
C9_CONTENT="$(cat "$C9_LOG" 2>/dev/null)"
if [ "$RC_C9" = "0" ] && printf '%s' "$OUT_C9" | grep -qF 'permissionDecision' && [ -n "$C9_CONTENT" ]; then
  check "C9 .zensu/../ traversal path -> still gated (not waved through the .zensu bypass)" PASS
else
  check "C9 .zensu/../ traversal denied (rc=$RC_C9, content=${C9_CONTENT:0:120}, out=${OUT_C9:0:120})" FAIL
fi
rm -rf "$C9_STATE_DIR" "$C9_LOG"

echo "----"
echo "test-pre-edit-hook-mirror: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
