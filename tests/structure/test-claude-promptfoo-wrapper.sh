#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$WRAPPER" ]; then
  check "scripts/claude-promptfoo-wrapper.sh exists and is executable" FAIL
  echo "----"
  echo "test-claude-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "scripts/claude-promptfoo-wrapper.sh exists and is executable" PASS

if bash -n "$WRAPPER" 2>/dev/null; then
  check "P7-S6 bash -n syntax check passes" PASS
else
  check "P7-S6 bash -n syntax check passes" FAIL
fi

OUT=$(DRY_RUN=1 "$WRAPPER" 'test prompt' '{"config":{"agent":"zensu:tdd-manager","working_dir":"/tmp"}}' 2>&1)
RC=$?
if printf '%s\n' "$OUT" | grep -q -- 'claude' \
  && printf '%s\n' "$OUT" | grep -q -- '--print' \
  && printf '%s\n' "$OUT" | grep -q -- '--output-format' \
  && printf '%s\n' "$OUT" | grep -q -- 'json' \
  && printf '%s\n' "$OUT" | grep -q -- '--dangerously-skip-permissions' \
  && printf '%s\n' "$OUT" | grep -qE "subagent_type=\\\\?'zensu:tdd-manager\\\\?'"; then
  check "P7-S1 happy-path DRY_RUN emits claude command preview with subagent_type" PASS
else
  check "P7-S1 happy-path DRY_RUN emits claude command preview (got: ${OUT:0:300})" FAIL
fi
if [ "$RC" = "0" ]; then
  check "P7-S1 happy-path DRY_RUN exits 0" PASS
else
  check "P7-S1 happy-path DRY_RUN exits 0 (got rc=$RC)" FAIL
fi

OUT2=$(DRY_RUN=1 "$WRAPPER" 'raw prompt' '{}' 2>&1)
if printf '%s\n' "$OUT2" | grep -q -- 'subagent_type='; then
  check "P7-S2 raw passthrough with empty options omits subagent_type (got: ${OUT2:0:200})" FAIL
else
  check "P7-S2 raw passthrough with empty options omits subagent_type" PASS
fi

OUT3=$(DRY_RUN=1 "$WRAPPER" 'p' '{"config":{"agent":"x"}}' 2>&1)
if printf '%s\n' "$OUT3" | grep -q -- 'cwd=\.'; then
  check "P7-S3 missing working_dir defaults to ." PASS
else
  check "P7-S3 missing working_dir defaults to . (got: ${OUT3:0:200})" FAIL
fi

JQ_DIR="$(dirname "$(command -v jq)")"
OUT4=$(env -i PATH="/usr/bin:/bin:$JQ_DIR" bash "$WRAPPER" 'p' '{}' 2>&1)
RC4=$?
if [ "$RC4" = "127" ] && printf '%s\n' "$OUT4" | grep -q -- 'claude-promptfoo-wrapper:'; then
  check "P7-S4 real-run with PATH stripped: exit 127 + wrapper-specific diagnostic" PASS
else
  check "P7-S4 real-run with PATH stripped: exit 127 + wrapper-specific diagnostic (rc=$RC4, out=${OUT4:0:200})" FAIL
fi

STUB_DIR="$(mktemp -d)"
cat >"$STUB_DIR/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_DIR/claude"
OUT5=$(env -i PATH="$STUB_DIR:/usr/bin:/bin:$JQ_DIR" bash "$WRAPPER" 'p' '{"config":{"working_dir":"/no/such/path/exists"}}' 2>&1)
RC5=$?
if [ "$RC5" = "2" ] && printf '%s\n' "$OUT5" | grep -q -- 'cannot cd'; then
  check "P7-S5 real-run with bad working_dir: exit 2 + cannot-cd diagnostic" PASS
else
  check "P7-S5 real-run with bad working_dir: exit 2 + cannot-cd diagnostic (rc=$RC5, out=${OUT5:0:200})" FAIL
fi
rm -rf "$STUB_DIR"

STUB_DIR_NO_JQ="$(mktemp -d)"
cat >"$STUB_DIR_NO_JQ/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_DIR_NO_JQ/claude"
OUT7=$(env -i PATH="$STUB_DIR_NO_JQ:/bin" bash "$WRAPPER" 'p' '{}' 2>&1)
RC7=$?
if [ "$RC7" = "127" ] && printf '%s\n' "$OUT7" | grep -q -- 'jq not found'; then
  check "P7-S7 wrapper with jq missing from PATH: exit 127 + jq-not-found diagnostic" PASS
else
  check "P7-S7 wrapper with jq missing from PATH: exit 127 + jq-not-found diagnostic (rc=$RC7, out=${OUT7:0:200})" FAIL
fi
rm -rf "$STUB_DIR_NO_JQ"

OUT8=$(DRY_RUN=1 "$WRAPPER" 'p' '{"config":{"working_dir":""}}' 2>&1)
if printf '%s\n' "$OUT8" | grep -q -- 'cwd=\.'; then
  check "P7-S8 explicit empty working_dir defaults to . (DRY_RUN preamble)" PASS
else
  check "P7-S8 explicit empty working_dir defaults to . (DRY_RUN preamble) (got: ${OUT8:0:200})" FAIL
fi

STUB_CLAUDE_DIR="$(mktemp -d)"
cat >"$STUB_CLAUDE_DIR/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_CLAUDE_DIR/claude"
OUT9_STDOUT="$(mktemp)"
OUT9_STDERR="$(mktemp)"
env -i DRY_RUN=1 PATH="$STUB_CLAUDE_DIR:/bin" bash "$WRAPPER" 'p' '{}' >"$OUT9_STDOUT" 2>"$OUT9_STDERR"
RC9=$?
OUT9_STDOUT_CONTENT="$(cat "$OUT9_STDOUT")"
OUT9_STDERR_CONTENT="$(cat "$OUT9_STDERR")"
if [ "$RC9" = "127" ] \
  && printf '%s\n' "$OUT9_STDERR_CONTENT" | grep -q -- 'jq not found' \
  && ! printf '%s\n' "$OUT9_STDOUT_CONTENT" | grep -q -- 'DRY_RUN: would execute'; then
  check "P7-S9 DRY_RUN with jq missing: exit 127, stderr 'jq not found', stdout no preview" PASS
else
  check "P7-S9 DRY_RUN with jq missing: exit 127, stderr 'jq not found', stdout no preview (rc=$RC9, stdout=${OUT9_STDOUT_CONTENT:0:200}, stderr=${OUT9_STDERR_CONTENT:0:200})" FAIL
fi
rm -rf "$STUB_CLAUDE_DIR" "$OUT9_STDOUT" "$OUT9_STDERR"

echo "----"
echo "test-claude-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
