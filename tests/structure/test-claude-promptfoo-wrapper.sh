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

SRC_DIR="$(mktemp -d -t "claude-eval-src-XXXXXX")"
echo "marker-file" >"$SRC_DIR/source-marker.txt"
OPT10="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_DIR")"
OUT10=$(DRY_RUN=1 "$WRAPPER" 'isolation prompt' "$OPT10" 2>&1)
RC10=$?
if printf '%s\n' "$OUT10" | grep -qE 'cp[[:space:]]+-c?R' \
  && printf '%s\n' "$OUT10" | grep -qE 'isolated=.*claude-eval-' \
  && ! printf '%s\n' "$OUT10" | grep -qE "would execute.*cwd=$SRC_DIR\b"; then
  check "P7-S10 DRY_RUN previews cp clone into /tmp/claude-eval-* (isolation, not raw WORKDIR)" PASS
else
  check "P7-S10 DRY_RUN previews cp clone into /tmp/claude-eval-* (rc=$RC10, out=${OUT10:0:300})" FAIL
fi
if [ "$RC10" = "0" ]; then
  check "P7-S10 DRY_RUN with isolation preview exits 0" PASS
else
  check "P7-S10 DRY_RUN with isolation preview exits 0 (got rc=$RC10)" FAIL
fi
rm -rf "$SRC_DIR"

STUB_STREAM_DIR="$(mktemp -d)"
cat >"$STUB_STREAM_DIR/claude" <<'STUB'
#!/bin/bash
cat <<'STREAM'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello from stub"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/x"}}]}}
{"type":"result","result":"stub-finished"}
STREAM
exit 0
STUB
chmod +x "$STUB_STREAM_DIR/claude"
SRC_STREAM_DIR="$(mktemp -d -t "stream-src-XXXXXX")"
echo "stream-src-content" >"$SRC_STREAM_DIR/marker.txt"
OPT11="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_STREAM_DIR")"
OUT11=$(env PATH="$STUB_STREAM_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT11" 2>/dev/null)
RC11=$?
if [ "$RC11" = "0" ] \
  && printf '%s\n' "$OUT11" | grep -qF 'hello from stub' \
  && printf '%s\n' "$OUT11" | grep -qE '\[tool_use:[[:space:]]*Read\]' \
  && ! printf '%s\n' "$OUT11" | grep -qF '{"type":"assistant"'; then
  check "P7-S11 stream-json: wrapper concatenates assistant text + tool_use names (no raw JSON envelopes)" PASS
else
  check "P7-S11 stream-json: wrapper concatenates assistant text + tool_use names (rc=$RC11, out=${OUT11:0:300})" FAIL
fi
rm -rf "$STUB_STREAM_DIR" "$SRC_STREAM_DIR"

OUT_P10S1=$(DRY_RUN=1 "$WRAPPER" 'p' '{"config":{"agent":"zensu:tdd-manager","working_dir":"/tmp"}}' 2>&1)
if printf '%s\n' "$OUT_P10S1" | grep -q -- '===== hook events =====' \
  || printf '%s\n' "$OUT_P10S1" | grep -q -- '===== fsm state:'; then
  check "P10-S1 DRY_RUN omits enrichment block (no hook events / fsm state headers)" FAIL
else
  check "P10-S1 DRY_RUN omits enrichment block (no hook events / fsm state headers)" PASS
fi

STUB_P10S2_DIR="$(mktemp -d)"
cat >"$STUB_P10S2_DIR/claude" <<'STUB'
#!/bin/bash
mkdir -p "$PWD/.zensu"
cat >"$PWD/.zensu/hook-events.log" <<'HOOK'
[hook: PreToolUse] TDD-Phase-Gate: Edit on /tmp/x.ts blocked.
[hook: PreToolUse] Current phase: UNINITIALIZED, step: .
[hook: PreToolUse] Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step ) | (GREEN_PASS only on test paths).
[hook: PreToolUse] permissionDecision=deny
HOOK
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"hook-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P10S2_DIR/claude"
SRC_P10S2_DIR="$(mktemp -d -t "p10s2-src-XXXXXX")"
echo "src" >"$SRC_P10S2_DIR/marker.txt"
OPT_P10S2="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P10S2_DIR")"
OUT_P10S2=$(env PATH="$STUB_P10S2_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P10S2" 2>/dev/null)
RC_P10S2=$?
if [ "$RC_P10S2" = "0" ] && printf '%s\n' "$OUT_P10S2" | grep -q -- '===== hook events =====' \
  && printf '%s\n' "$OUT_P10S2" | grep -q 'TDD-Phase-Gate'; then
  check "P10-S2 shim writes hook mirror -> output contains '===== hook events ====='" PASS
else
  check "P10-S2 shim writes hook mirror -> output contains '===== hook events =====' (rc=$RC_P10S2, out=${OUT_P10S2:0:400})" FAIL
fi
rm -rf "$STUB_P10S2_DIR" "$SRC_P10S2_DIR"

STUB_P10S3_DIR="$(mktemp -d)"
cat >"$STUB_P10S3_DIR/claude" <<'STUB'
#!/bin/bash
mkdir -p "$PWD/.zensu/state"
cat >"$PWD/.zensu/state/tdd-phase-test.json" <<'STATE'
{
  "session_id": "test",
  "step_id": "S1",
  "phase": "REFACTOR",
  "history": [
    { "step": "S1", "phase": "RED_WRITE", "ts": "2026-05-22T10:00:00Z" },
    { "step": "S1", "phase": "RED_FAIL", "ts": "2026-05-22T10:01:00Z" },
    { "step": "S1", "phase": "IMPL", "ts": "2026-05-22T10:02:00Z" },
    { "step": "S1", "phase": "GREEN_PASS", "ts": "2026-05-22T10:03:00Z" },
    { "step": "S1", "phase": "REFACTOR", "ts": "2026-05-22T10:04:00Z" }
  ]
}
STATE
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"fsm-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P10S3_DIR/claude"
SRC_P10S3_DIR="$(mktemp -d -t "p10s3-src-XXXXXX")"
echo "src" >"$SRC_P10S3_DIR/marker.txt"
OPT_P10S3="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P10S3_DIR")"
OUT_P10S3=$(env PATH="$STUB_P10S3_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P10S3" 2>/dev/null)
RC_P10S3=$?
if [ "$RC_P10S3" = "0" ] \
  && printf '%s\n' "$OUT_P10S3" | grep -q -- '===== fsm state: tdd-phase-test.json =====' \
  && printf '%s\n' "$OUT_P10S3" | grep -q -- '\[fsm-state-final\] phase=REFACTOR' \
  && printf '%s\n' "$OUT_P10S3" | grep -q -- '\[fsm-history\] step=S1 phase=RED_FAIL'; then
  check "P10-S3 shim writes state file -> output contains fsm-state header + history lines" PASS
else
  check "P10-S3 shim writes state file -> fsm-state header + history (rc=$RC_P10S3, out=${OUT_P10S3:0:500})" FAIL
fi
rm -rf "$STUB_P10S3_DIR" "$SRC_P10S3_DIR"

STUB_P10S4_DIR="$(mktemp -d)"
cat >"$STUB_P10S4_DIR/claude" <<'STUB'
#!/bin/bash
mkdir -p "$PWD/.zensu"
cat >"$PWD/.zensu/hook-events.log" <<'HOOK'
[hook: PreToolUse] TDD-Phase-Gate: Edit on /tmp/x.ts blocked.
[hook: PreToolUse] Current phase: UNINITIALIZED, step: .
[hook: PreToolUse] Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step ) | (GREEN_PASS only on test paths).
[hook: PreToolUse] permissionDecision=deny
HOOK
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"unin-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P10S4_DIR/claude"
SRC_P10S4_DIR="$(mktemp -d -t "p10s4-src-XXXXXX")"
echo "src" >"$SRC_P10S4_DIR/marker.txt"
OPT_P10S4="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P10S4_DIR")"
OUT_P10S4=$(env PATH="$STUB_P10S4_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P10S4" 2>/dev/null)
RC_P10S4=$?
if [ "$RC_P10S4" = "0" ] \
  && printf '%s\n' "$OUT_P10S4" | grep -q -- '\[fsm-state-final\] phase=UNINITIALIZED'; then
  check "P10-S4 mirror UNINITIALIZED + no state file -> synthetic [fsm-state-final] phase=UNINITIALIZED" PASS
else
  check "P10-S4 mirror UNINITIALIZED + no state file -> synthetic marker (rc=$RC_P10S4, out=${OUT_P10S4:0:500})" FAIL
fi
rm -rf "$STUB_P10S4_DIR" "$SRC_P10S4_DIR"

STUB_P10S5_DIR="$(mktemp -d)"
cat >"$STUB_P10S5_DIR/claude" <<'STUB'
#!/bin/bash
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"silent-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P10S5_DIR/claude"
SRC_P10S5_DIR="$(mktemp -d -t "p10s5-src-XXXXXX")"
echo "src" >"$SRC_P10S5_DIR/marker.txt"
OPT_P10S5="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P10S5_DIR")"
OUT_P10S5=$(env PATH="$STUB_P10S5_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P10S5" 2>/dev/null)
RC_P10S5=$?
if [ "$RC_P10S5" = "0" ] \
  && ! printf '%s\n' "$OUT_P10S5" | grep -q -- '===== hook events =====' \
  && ! printf '%s\n' "$OUT_P10S5" | grep -q -- '===== fsm state:' \
  && ! printf '%s\n' "$OUT_P10S5" | grep -q -- '\[fsm-state-final\]'; then
  check "P10-S5 no mirror + no state file -> no enrichment block in output" PASS
else
  check "P10-S5 no mirror + no state file -> no enrichment block (rc=$RC_P10S5, out=${OUT_P10S5:0:500})" FAIL
fi
rm -rf "$STUB_P10S5_DIR" "$SRC_P10S5_DIR"

STUB_P10S6_DIR="$(mktemp -d)"
cat >"$STUB_P10S6_DIR/claude" <<'STUB'
#!/bin/bash
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"unwritable-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P10S6_DIR/claude"
SRC_P10S6_DIR="$(mktemp -d -t "p10s6-src-XXXXXX")"
echo "src" >"$SRC_P10S6_DIR/marker.txt"
printf 'not-a-directory' >"$SRC_P10S6_DIR/.zensu"
OPT_P10S6="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P10S6_DIR")"
OUT_P10S6=$(env PATH="$STUB_P10S6_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P10S6" 2>/dev/null)
RC_P10S6=$?
if [ "$RC_P10S6" = "0" ] \
  && printf '%s\n' "$OUT_P10S6" | grep -qF 'unwritable-shim' \
  && ! printf '%s\n' "$OUT_P10S6" | grep -q -- '===== hook events =====' \
  && ! printf '%s\n' "$OUT_P10S6" | grep -q -- '===== fsm state:'; then
  check "P10-S6 unwritable ZENSU_HOOK_LOG path (.zensu is a file) -> wrapper exits 0, no enrichment headers" PASS
else
  check "P10-S6 unwritable ZENSU_HOOK_LOG path -> exit 0 no enrichment (rc=$RC_P10S6, out=${OUT_P10S6:0:400})" FAIL
fi
rm -rf "$STUB_P10S6_DIR" "$SRC_P10S6_DIR"

STUB_P11S1_DIR="$(mktemp -d)"
ENV_DUMP_P11S1="$(mktemp -t p11s1-env-dump-XXXXXX)"
cat >"$STUB_P11S1_DIR/claude" <<STUB
#!/bin/bash
printenv > "$ENV_DUMP_P11S1"
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"env-dump-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P11S1_DIR/claude"
SRC_P11S1_DIR="$(mktemp -d -t "p11s1-src-XXXXXX")"
echo "src" >"$SRC_P11S1_DIR/marker.txt"
OPT_P11S1="$(printf '{"config":{"agent":"zensu:tdd-manager","working_dir":"%s"}}' "$SRC_P11S1_DIR")"
OUT_P11S1=$(env PATH="$STUB_P11S1_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P11S1" 2>/dev/null)
RC_P11S1=$?
ENV_DUMP_CONTENT="$(cat "$ENV_DUMP_P11S1" 2>/dev/null)"
if [ "$RC_P11S1" = "0" ] \
  && printf '%s\n' "$ENV_DUMP_CONTENT" | grep -q '^CLAUDE_AGENT_TYPE=zensu:tdd-manager$'; then
  check "P11-S1 wrapper exports CLAUDE_AGENT_TYPE=zensu:tdd-manager when config.agent is set" PASS
else
  check "P11-S1 wrapper exports CLAUDE_AGENT_TYPE=zensu:tdd-manager (rc=$RC_P11S1, env_dump_grep=$(printf '%s\n' "$ENV_DUMP_CONTENT" | grep CLAUDE_AGENT_TYPE | head -1))" FAIL
fi
rm -rf "$STUB_P11S1_DIR" "$SRC_P11S1_DIR" "$ENV_DUMP_P11S1"

STUB_P11S2_DIR="$(mktemp -d)"
ENV_DUMP_P11S2="$(mktemp -t p11s2-env-dump-XXXXXX)"
cat >"$STUB_P11S2_DIR/claude" <<STUB
#!/bin/bash
printenv > "$ENV_DUMP_P11S2"
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"no-agent-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P11S2_DIR/claude"
SRC_P11S2_DIR="$(mktemp -d -t "p11s2-src-XXXXXX")"
echo "src" >"$SRC_P11S2_DIR/marker.txt"
OPT_P11S2="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P11S2_DIR")"
OUT_P11S2=$(env -u CLAUDE_AGENT_TYPE PATH="$STUB_P11S2_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P11S2" 2>/dev/null)
RC_P11S2=$?
ENV_DUMP_CONTENT_2="$(cat "$ENV_DUMP_P11S2" 2>/dev/null)"
if [ "$RC_P11S2" = "0" ] \
  && ! printf '%s\n' "$ENV_DUMP_CONTENT_2" | grep -q '^CLAUDE_AGENT_TYPE='; then
  check "P11-S2 wrapper does NOT export CLAUDE_AGENT_TYPE when config.agent is absent/empty" PASS
else
  check "P11-S2 wrapper does NOT export CLAUDE_AGENT_TYPE (rc=$RC_P11S2, env_dump_grep=$(printf '%s\n' "$ENV_DUMP_CONTENT_2" | grep CLAUDE_AGENT_TYPE | head -1))" FAIL
fi
rm -rf "$STUB_P11S2_DIR" "$SRC_P11S2_DIR" "$ENV_DUMP_P11S2"

STUB_P12S1_DIR="$(mktemp -d)"
cat >"$STUB_P12S1_DIR/claude" <<'STUB'
#!/bin/bash
mkdir -p "$PWD/.zensu/logs"
cat >"$PWD/.zensu/logs/witness-sess1.log" <<'WIT'
[10:00:01] BASH cmd="bash -c \"echo test-marker-001\"" exit=0 tail="test-marker-001\n"
[10:00:02] BASH cmd="ls -la /tmp" exit=0 tail="total 0\n"
WIT
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"witness-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P12S1_DIR/claude"
SRC_P12S1_DIR="$(mktemp -d -t "p12s1-src-XXXXXX")"
echo "src" >"$SRC_P12S1_DIR/marker.txt"
OPT_P12S1="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P12S1_DIR")"
OUT_P12S1=$(env PATH="$STUB_P12S1_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P12S1" 2>/dev/null)
RC_P12S1=$?
if [ "$RC_P12S1" = "0" ] \
  && printf '%s\n' "$OUT_P12S1" | grep -q -- '===== witness: witness-sess1.log =====' \
  && printf '%s\n' "$OUT_P12S1" | grep -qF 'cmd="bash -c \"echo test-marker-001\""' \
  && printf '%s\n' "$OUT_P12S1" | grep -qF 'cmd="ls -la /tmp"'; then
  check "P12-S1 wrapper appends '===== witness: ... =====' block when .zensu/logs/witness-*.log present" PASS
else
  check "P12-S1 wrapper appends witness block (rc=$RC_P12S1, out=${OUT_P12S1:0:500})" FAIL
fi
rm -rf "$STUB_P12S1_DIR" "$SRC_P12S1_DIR"

STUB_P12S2_DIR="$(mktemp -d)"
cat >"$STUB_P12S2_DIR/claude" <<'STUB'
#!/bin/bash
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"no-witness-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P12S2_DIR/claude"
SRC_P12S2_DIR="$(mktemp -d -t "p12s2-src-XXXXXX")"
echo "src" >"$SRC_P12S2_DIR/marker.txt"
OPT_P12S2="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P12S2_DIR")"
OUT_P12S2=$(env PATH="$STUB_P12S2_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P12S2" 2>/dev/null)
RC_P12S2=$?
if [ "$RC_P12S2" = "0" ] \
  && printf '%s\n' "$OUT_P12S2" | grep -qF 'no-witness-shim' \
  && ! printf '%s\n' "$OUT_P12S2" | grep -q -- '===== witness:'; then
  check "P12-S2 wrapper omits witness block when no witness log exists (clean output)" PASS
else
  check "P12-S2 wrapper omits witness block when no witness log (rc=$RC_P12S2, out=${OUT_P12S2:0:400})" FAIL
fi
rm -rf "$STUB_P12S2_DIR" "$SRC_P12S2_DIR"

STUB_P12S3_DIR="$(mktemp -d)"
cat >"$STUB_P12S3_DIR/claude" <<'STUB'
#!/bin/bash
mkdir -p "$PWD/.zensu/logs"
cat >"$PWD/.zensu/logs/witness-multi.log" <<'WIT'
[10:00:01] BASH cmd="cmd-one" exit=0 tail="one"
[10:00:02] BASH cmd="cmd-two" exit=0 tail="two"
[10:00:03] BASH cmd="cmd-three" exit=1 tail="three"
[10:00:04] BASH cmd="cmd-four" exit=0 tail="four"
WIT
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"multi-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P12S3_DIR/claude"
SRC_P12S3_DIR="$(mktemp -d -t "p12s3-src-XXXXXX")"
echo "src" >"$SRC_P12S3_DIR/marker.txt"
OPT_P12S3="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P12S3_DIR")"
OUT_P12S3=$(env PATH="$STUB_P12S3_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P12S3" 2>/dev/null)
RC_P12S3=$?
if [ "$RC_P12S3" = "0" ] \
  && printf '%s\n' "$OUT_P12S3" | grep -qF 'cmd="cmd-one"' \
  && printf '%s\n' "$OUT_P12S3" | grep -qF 'cmd="cmd-two"' \
  && printf '%s\n' "$OUT_P12S3" | grep -qF 'cmd="cmd-three"' \
  && printf '%s\n' "$OUT_P12S3" | grep -qF 'cmd="cmd-four"'; then
  check "P12-S3 multi-invocation witness log content all 4 lines appear in wrapper output" PASS
else
  check "P12-S3 multi-invocation witness content (rc=$RC_P12S3, out=${OUT_P12S3:0:500})" FAIL
fi
rm -rf "$STUB_P12S3_DIR" "$SRC_P12S3_DIR"

echo "----"
echo "test-claude-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
