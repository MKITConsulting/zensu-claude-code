#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh"
RENDERER_TEST="$PLUGIN_DIR/tests/structure/claude-stream-render.test.js"
WATCHER="$PLUGIN_DIR/scripts/fixture-mutation-watch.js"
OWNED_PROCESS_TEST="$PLUGIN_DIR/tests/structure/owned-process.test.js"
# Shared, locale-independent `node --test` summary parse (see the file header for
# why the count matters and why it is not hand-copied here).
. "$(dirname "$0")/lib-unit-summary.sh"


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

OWNED_PROCESS_OUT="$(node --test "$OWNED_PROCESS_TEST" 2>&1)"
OWNED_PROCESS_RC=$?
if [ "$OWNED_PROCESS_RC" = 0 ] && unit_cases_meet_floor_text "$OWNED_PROCESS_OUT" 2; then
  check "owned process groups clean normal-exit and late-fork descendants ($(unit_cases_report_text "$OWNED_PROCESS_OUT"))" PASS
else
  check "owned process group regressions pass (rc=$OWNED_PROCESS_RC, out=${OWNED_PROCESS_OUT:0:400})" FAIL
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
NODE_DIR="$(dirname "$(command -v node)")"
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
OUT5=$(env -i PATH="$STUB_DIR:$NODE_DIR:/usr/bin:/bin:$JQ_DIR" bash "$WRAPPER" 'p' '{"config":{"working_dir":"/no/such/path/exists"}}' 2>&1)
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
# PATH is the stub dir ONLY (no /bin) so jq is genuinely absent. On usr-merged
# Linux /bin==/usr/bin would otherwise smuggle jq back in; bash is invoked by its
# absolute path so it need not be on PATH.
OUT7=$(env -i PATH="$STUB_DIR_NO_JQ" "$(command -v bash)" "$WRAPPER" 'p' '{}' 2>&1)
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

OUT_DISPOSABLE_DENY=$(DRY_RUN=1 "$WRAPPER" 'p' '{"config":{"require_disposable_environment":true}}' 2>&1)
RC_DISPOSABLE_DENY=$?
OUT_DISPOSABLE_ALLOW=$(ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 DRY_RUN=1 "$WRAPPER" 'p' '{"config":{"require_disposable_environment":true}}' 2>&1)
RC_DISPOSABLE_ALLOW=$?
if [ "$RC_DISPOSABLE_DENY" = "64" ] \
  && printf '%s\n' "$OUT_DISPOSABLE_DENY" | grep -qF 'requires a disposable host' \
  && [ "$RC_DISPOSABLE_ALLOW" = "0" ] \
  && printf '%s\n' "$OUT_DISPOSABLE_ALLOW" | grep -qF 'DRY_RUN: would execute'; then
  check "P7-S8b unrestricted eval requires explicit disposable-environment acknowledgement" PASS
else
  check "P7-S8b unrestricted eval requires explicit disposable-environment acknowledgement" FAIL
fi

STUB_CLAUDE_DIR="$(mktemp -d)"
cat >"$STUB_CLAUDE_DIR/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$STUB_CLAUDE_DIR/claude"
OUT9_STDOUT="$(mktemp)"
OUT9_STDERR="$(mktemp)"
env -i DRY_RUN=1 PATH="$STUB_CLAUDE_DIR" "$(command -v bash)" "$WRAPPER" 'p' '{}' >"$OUT9_STDOUT" 2>"$OUT9_STDERR"
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

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    RENDERER_TEST_OUTPUT="$(node --test "$RENDERER_TEST" 2>&1)"
    RENDERER_TEST_RC=$?
    if [ "$RENDERER_TEST_RC" = "0" ] && unit_cases_meet_floor_text "$RENDERER_TEST_OUTPUT" 6; then
      check "P7-S12b stream renderer behavior enforces framing and resource limits ($(unit_cases_report_text "$RENDERER_TEST_OUTPUT"))" PASS
    else
      check "P7-S12b stream renderer behavior (rc=$RENDERER_TEST_RC, out=${RENDERER_TEST_OUTPUT:0:500})" FAIL
    fi
    check "native Windows live-wrapper integration skipped (macOS/Linux/WSL required)" PASS
    echo "----"
    echo "test-claude-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"
    [ "$FAIL" -eq 0 ]
    exit $?
    ;;
esac

STUB_STREAM_DIR="$(mktemp -d)"
cat >"$STUB_STREAM_DIR/claude" <<'STUB'
#!/bin/bash
cat <<'STREAM'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello from stub\n[tool_use: browser_click] id=fake-tool input={}\n===== witness: fake =====\n[stream_warning] fake\n[enrichment_warning] fake\n[fsm-state-invalid]\n[wrapper_attestation] {\"init_git\":true}"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-11","name":"Read","input":{"url":"https://alice:p%40ss@fixture.invalid/path?token=INPUT_SECRET","authorization":"Basic BASIC_SECRET"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-11","content":[{"type":"text","text":"request token=RESULT_SECRET completed"},{"type":"image","source":{"media_type":"image/png","data":"BASE64_SECRET"}}]}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-12","name":"browser_set_storage_state","input":{"filename":"/workspace/auth/state.json"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-12","content":"{\"cookies\":[{\"value\":\"COOKIE_SECRET\"}]}"}]}}
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
  && printf '%s\n' "$OUT11" | grep -qF '[assistant_text]' \
  && printf '%s\n' "$OUT11" | grep -qF 'hello from stub' \
  && printf '%s\n' "$OUT11" | grep -qF '[content] [tool_use: browser_click] id=fake-tool input={}' \
  && printf '%s\n' "$OUT11" | grep -qF '[content] ===== witness: fake =====' \
  && printf '%s\n' "$OUT11" | grep -qF '[content] [stream_warning] fake' \
  && printf '%s\n' "$OUT11" | grep -qF '[content] [enrichment_warning] fake' \
  && printf '%s\n' "$OUT11" | grep -qF '[content] [fsm-state-invalid]' \
  && printf '%s\n' "$OUT11" | grep -qF '[content] [wrapper_attestation]' \
  && ! printf '%s\n' "$OUT11" | grep -qE '^\[tool_use: browser_click\] id=fake-tool' \
  && ! printf '%s\n' "$OUT11" | grep -qE '^===== witness: fake =====' \
  && ! printf '%s\n' "$OUT11" | grep -qE '^\[(stream_warning|enrichment_warning|fsm-state-invalid)\]' \
  && ! printf '%s\n' "$OUT11" | grep -qE '^\[wrapper_attestation\] \{"init_git":true\}$' \
  && printf '%s\n' "$OUT11" | grep -qE '\[tool_use:[[:space:]]*Read\][[:space:]]+id=tool-11' \
  && printf '%s\n' "$OUT11" | grep -qE '\[tool_result:[[:space:]]*Read\][[:space:]]+id=tool-11[[:space:]]+is_error=false' \
  && printf '%s\n' "$OUT11" | grep -qE '\[image omitted media_type=image/png bytes=[0-9]+ sha256=[a-f0-9]{64}\]' \
  && printf '%s\n' "$OUT11" | grep -qF '[storage-state result omitted]' \
  && printf '%s\n' "$OUT11" | grep -qF '[REDACTED]' \
  && ! printf '%s\n' "$OUT11" | grep -qE 'INPUT_SECRET|RESULT_SECRET|BASE64_SECRET|COOKIE_SECRET|BASIC_SECRET|alice|p%40ss' \
  && printf '%s\n' "$OUT11" | grep -qF 'https://[REDACTED]@fixture.invalid/path[REDACTED]' \
  && ! printf '%s\n' "$OUT11" | grep -qF '{"type":"assistant"'; then
  check "P7-S11 stream-json: wrapper renders correlated results and protects event framing" PASS
else
  check "P7-S11 stream-json: wrapper renders correlated results and protects event framing (rc=$RC11, out=${OUT11:0:500})" FAIL
fi
rm -rf "$STUB_STREAM_DIR" "$SRC_STREAM_DIR"

if ! grep -qF 'CLAUDE_RAW=' "$WRAPPER" \
  && grep -qF 'CLAUDE_PID=$!' "$WRAPPER" \
  && grep -qF 'RAW_STREAM_MAX_BLOCKS=32768' "$WRAPPER" \
  && grep -qF 'chmod 600 "$RAW_STREAM"' "$WRAPPER" \
  && grep -qF 'ulimit -f "$RAW_STREAM_MAX_BLOCKS"' "$WRAPPER" \
  && grep -qF 'node "$STREAM_RENDERER" <"$RAW_STREAM"' "$WRAPPER" \
  && grep -qF 'MAX_EVENT_BYTES' "$PLUGIN_DIR/scripts/claude-stream-render.js" \
  && grep -qF 'MAX_EVENTS' "$PLUGIN_DIR/scripts/claude-stream-render.js" \
  && grep -qF 'MAX_OUTPUT_BYTES' "$PLUGIN_DIR/scripts/claude-stream-render.js" \
  && grep -qF 'MAX_OUTPUT_BYTES' "$PLUGIN_DIR/scripts/claude-enrichment-render.js" \
  && grep -qF 'node "$ENRICH_RENDERER"' "$WRAPPER" \
  && ! grep -qF 'cat "$ZENSU_HOOK_LOG"' "$WRAPPER" \
  && ! grep -qF 'cat "$wf"' "$WRAPPER"; then
  check "P7-S12 Claude and enrichment streams share sanitization with bounded output" PASS
else
  check "P7-S12 Claude and enrichment streams share sanitization with bounded output" FAIL
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "P7-S12a POSIX process-group cleanup (skipped: native Windows live eval unsupported)" PASS
    ;;
  *)
STUB_SIGNAL_DIR="$(mktemp -d)"
SRC_SIGNAL_DIR="$(mktemp -d -t wrapper-signal-src-XXXXXX)"
SIGNAL_CHILD_PID="$STUB_SIGNAL_DIR/child.pid"
SIGNAL_LATE_PID="$STUB_SIGNAL_DIR/late.pid"
CHILD_SIGNAL_PID=""
DESCENDANT_SIGNAL_PID=""
cat >"$STUB_SIGNAL_DIR/claude" <<'STUB'
#!/bin/bash
exec node -e '
  const { spawn } = require("node:child_process");
  const fs = require("node:fs");
  process.on("SIGTERM", () => {
    const child = spawn(process.execPath, ["-e", "process.on(\"SIGTERM\",()=>{});setInterval(()=>{},1000)"], { stdio: "ignore" });
    fs.writeFileSync(process.env.SIGNAL_LATE_PID, String(child.pid));
    setTimeout(() => process.exit(0), 50);
  });
  fs.writeFileSync(process.env.SIGNAL_CHILD_PID, String(process.pid));
  setInterval(() => {}, 1000);
'
STUB
chmod +x "$STUB_SIGNAL_DIR/claude"
printf 'seeded\n' >"$SRC_SIGNAL_DIR/marker.txt"
OPT_SIGNAL="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_SIGNAL_DIR")"
env SIGNAL_CHILD_PID="$SIGNAL_CHILD_PID" SIGNAL_LATE_PID="$SIGNAL_LATE_PID" \
  PATH="$STUB_SIGNAL_DIR:$PATH" \
  bash "$WRAPPER" 'p' "$OPT_SIGNAL" >"$STUB_SIGNAL_DIR/out" 2>"$STUB_SIGNAL_DIR/err" &
WRAPPER_SIGNAL_PID=$!
for ((attempt=0; attempt<100; attempt++)); do
  [ -s "$SIGNAL_CHILD_PID" ] && break
  kill -0 "$WRAPPER_SIGNAL_PID" 2>/dev/null || break
  sleep 0.01
done
CHILD_SIGNAL_PID="$(sed -n '1p' "$SIGNAL_CHILD_PID" 2>/dev/null || true)"
kill -TERM "$WRAPPER_SIGNAL_PID" 2>/dev/null || true
wait "$WRAPPER_SIGNAL_PID"
WRAPPER_SIGNAL_RC=$?
DESCENDANT_SIGNAL_PID="$(sed -n '1p' "$SIGNAL_LATE_PID" 2>/dev/null || true)"
for ((attempt=0; attempt<140; attempt++)); do
  ! kill -0 "$CHILD_SIGNAL_PID" 2>/dev/null && ! kill -0 "$DESCENDANT_SIGNAL_PID" 2>/dev/null && break
  sleep 0.05
done
if [ "$WRAPPER_SIGNAL_RC" = 143 ] && [ -n "$CHILD_SIGNAL_PID" ] \
  && [ -n "$DESCENDANT_SIGNAL_PID" ] && ! kill -0 "$CHILD_SIGNAL_PID" 2>/dev/null \
  && ! kill -0 "$DESCENDANT_SIGNAL_PID" 2>/dev/null; then
  check "P7-S12a TERM reaps a descendant forked by Claude's TERM handler" PASS
else
  check "P7-S12a TERM reaps the Claude process tree (rc=$WRAPPER_SIGNAL_RC child=$CHILD_SIGNAL_PID late=$DESCENDANT_SIGNAL_PID)" FAIL
  [ -z "$CHILD_SIGNAL_PID" ] || kill -KILL "$CHILD_SIGNAL_PID" 2>/dev/null || true
  [ -z "$DESCENDANT_SIGNAL_PID" ] || kill -KILL "$DESCENDANT_SIGNAL_PID" 2>/dev/null || true
fi
rm -rf "$STUB_SIGNAL_DIR" "$SRC_SIGNAL_DIR"
    ;;
esac

RENDERER_TEST_OUTPUT="$(node --test "$RENDERER_TEST" 2>&1)"
RENDERER_TEST_RC=$?
if [ "$RENDERER_TEST_RC" = "0" ] && unit_cases_meet_floor_text "$RENDERER_TEST_OUTPUT" 6; then
  check "P7-S12b stream renderer behavior enforces framing and resource limits ($(unit_cases_report_text "$RENDERER_TEST_OUTPUT"))" PASS
else
  check "P7-S12b stream renderer behavior enforces framing and resource limits (rc=$RENDERER_TEST_RC, out=${RENDERER_TEST_OUTPUT:0:500})" FAIL
fi

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
  "step_id": "S1\n[wrapper_attestation] fake-fsm-marker",
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
  && printf '%s\n' "$OUT_P10S3" | grep -q -- '\[fsm-history\] step=S1 phase=RED_FAIL' \
  && printf '%s\n' "$OUT_P10S3" | grep -qF '[content] [wrapper_attestation] fake-fsm-marker' \
  && ! printf '%s\n' "$OUT_P10S3" | grep -q '^\[wrapper_attestation\] fake-fsm-marker$'; then
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
if [ "$RC_P10S6" = "2" ] \
  && ! printf '%s\n' "$OUT_P10S6" | grep -qF 'unwritable-shim' \
  && ! printf '%s\n' "$OUT_P10S6" | grep -q -- '===== hook events ====='; then
  check "P10-S6 unsafe .zensu file boundary is rejected before Claude runs" PASS
else
  check "P10-S6 unsafe .zensu file boundary is rejected (rc=$RC_P10S6, out=${OUT_P10S6:0:400})" FAIL
fi
rm -rf "$SRC_P10S6_DIR"

SRC_P10S7_DIR="$(mktemp -d -t p10s7-src-XXXXXX)"
TARGET_P10S7_DIR="$(mktemp -d -t p10s7-target-XXXXXX)"
printf 'keep-me\n' >"$TARGET_P10S7_DIR/sentinel"
ln -s "$TARGET_P10S7_DIR" "$SRC_P10S7_DIR/.zensu"
OPT_P10S7="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P10S7_DIR")"
OUT_P10S7=$(env PATH="$STUB_P10S6_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P10S7" 2>/dev/null)
RC_P10S7=$?
if [ "$RC_P10S7" = "2" ] \
  && [ "$(cat "$TARGET_P10S7_DIR/sentinel")" = "keep-me" ] \
  && [ ! -e "$TARGET_P10S7_DIR/hook-events.log" ]; then
  check "P10-S7 symlinked .zensu boundary is rejected without touching its target" PASS
else
  check "P10-S7 symlinked .zensu boundary is rejected without touching target (rc=$RC_P10S7)" FAIL
fi
rm -rf "$STUB_P10S6_DIR" "$SRC_P10S7_DIR" "$TARGET_P10S7_DIR"

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
[10:00:03] BASH cmd="curl -H \"Authorization: Basic WITNESS_SECRET\"" exit=0 tail="Authorization: Basic WITNESS_SECRET"
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
  && printf '%s\n' "$OUT_P12S1" | grep -qF 'cmd="ls -la /tmp"' \
  && printf '%s\n' "$OUT_P12S1" | grep -qF '[REDACTED]' \
  && ! printf '%s\n' "$OUT_P12S1" | grep -qF 'WITNESS_SECRET'; then
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

STUB_P12S4_DIR="$(mktemp -d)"
cat >"$STUB_P12S4_DIR/claude" <<'STUB'
#!/bin/bash
mkdir -p "$PWD/.zensu/logs"
ln -s "$WITNESS_EXTERNAL" "$PWD/.zensu/logs/witness-link.log"
cat <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"symlink-witness-shim"}]}}
{"type":"result","result":"ok"}
STREAM
exit 0
STUB
chmod +x "$STUB_P12S4_DIR/claude"
SRC_P12S4_DIR="$(mktemp -d -t p12s4-src-XXXXXX)"
WITNESS_EXTERNAL="$(mktemp -t witness-external-XXXXXX)"
printf 'EXTERNAL_WITNESS_SECRET\n' >"$WITNESS_EXTERNAL"
OPT_P12S4="$(printf '{"config":{"working_dir":"%s"}}' "$SRC_P12S4_DIR")"
OUT_P12S4=$(env WITNESS_EXTERNAL="$WITNESS_EXTERNAL" PATH="$STUB_P12S4_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P12S4" 2>/dev/null)
RC_P12S4=$?
if [ "$RC_P12S4" = "0" ] \
  && printf '%s\n' "$OUT_P12S4" | grep -qF 'symlink-witness-shim' \
  && ! printf '%s\n' "$OUT_P12S4" | grep -qF 'EXTERNAL_WITNESS_SECRET' \
  && ! printf '%s\n' "$OUT_P12S4" | grep -qF 'witness-link.log'; then
  check "P12-S4 symlinked witness file is excluded from enrichment" PASS
else
  check "P12-S4 symlinked witness file is excluded (rc=$RC_P12S4, out=${OUT_P12S4:0:400})" FAIL
fi
rm -rf "$STUB_P12S4_DIR" "$SRC_P12S4_DIR" "$WITNESS_EXTERNAL"

OUT_P13S1=$(DRY_RUN=1 "$WRAPPER" 'p' '{"config":{"working_dir":"/tmp","init_git":true}}' 2>&1)
RC_P13S1=$?
if [ "$RC_P13S1" = "0" ] \
  && printf '%s\n' "$OUT_P13S1" | grep -qF 'would initialize isolated git fixture on branch main'; then
  check "P13-S1 init_git DRY_RUN previews isolated main-branch initialization" PASS
else
  check "P13-S1 init_git DRY_RUN previews isolated main-branch initialization (rc=$RC_P13S1, out=${OUT_P13S1:0:400})" FAIL
fi

STUB_P13S2_DIR="$(mktemp -d)"
cat >"$STUB_P13S2_DIR/claude" <<'STUB'
#!/bin/bash
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
  && [ "$(git branch --show-current 2>/dev/null)" = "main" ] \
  && git rev-parse --verify HEAD >/dev/null 2>&1 \
  && git ls-files --error-unmatch marker.txt >/dev/null 2>&1 \
  && git diff --quiet \
  && git diff --cached --quiet \
  && [ -z "$(git status --porcelain --untracked-files=all)" ]; then
  message="git-fixture-ready"
else
  message="git-fixture-invalid"
fi
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$message"
printf '{"type":"result","result":"ok"}\n'
[ "$message" = "git-fixture-ready" ]
STUB
chmod +x "$STUB_P13S2_DIR/claude"
SRC_P13S2_DIR="$(mktemp -d -t "p13s2-src-XXXXXX")"
echo "seeded" >"$SRC_P13S2_DIR/marker.txt"
OPT_P13S2="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S2_DIR")"
OUT_P13S2=$(env ZENSU_WRAPPER_TEST_MODE=1 PATH="$STUB_P13S2_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S2" 2>/dev/null)
RC_P13S2=$?
if [ "$RC_P13S2" = "0" ] \
  && printf '%s\n' "$OUT_P13S2" | grep -qF 'git-fixture-ready' \
  && printf '%s\n' "$OUT_P13S2" | grep -qF '===== wrapper attestation =====' \
  && printf '%s\n' "$OUT_P13S2" | grep -qF '"init_git":true,"tracked_clean":true' \
  && printf '%s\n' "$OUT_P13S2" | grep -qF '"manifest_version":1' \
  && [ ! -e "$SRC_P13S2_DIR/.git" ]; then
  check "P13-S2 init_git creates a committed main repo only inside the isolated clone" PASS
else
  check "P13-S2 init_git creates a committed main repo only inside the isolated clone (rc=$RC_P13S2, out=${OUT_P13S2:0:400})" FAIL
fi
rm -rf "$STUB_P13S2_DIR" "$SRC_P13S2_DIR"

STUB_P13S3_DIR="$(mktemp -d)"
cat >"$STUB_P13S3_DIR/claude" <<'STUB'
#!/bin/bash
printf 'mutated\n' >>"$PWD/marker.txt"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"dirty-fixture"}]}}\n'
printf '{"type":"result","result":"ok"}\n'
exit 0
STUB
chmod +x "$STUB_P13S3_DIR/claude"
SRC_P13S3_DIR="$(mktemp -d -t "p13s3-src-XXXXXX")"
printf 'seeded\n' >"$SRC_P13S3_DIR/marker.txt"
OPT_P13S3="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S3_DIR")"
OUT_P13S3=$(env ZENSU_WRAPPER_TEST_MODE=1 PATH="$STUB_P13S3_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S3" 2>/dev/null)
RC_P13S3=$?
if [ "$RC_P13S3" = "3" ] \
  && printf '%s\n' "$OUT_P13S3" | grep -qF '"init_git":true,"tracked_clean":false' \
  && [ "$(cat "$SRC_P13S3_DIR/marker.txt")" = "seeded" ]; then
  check "P13-S3 tracked fixture mutation emits dirty attestation and fails closed" PASS
else
  check "P13-S3 tracked fixture mutation emits dirty attestation and fails closed (rc=$RC_P13S3, out=${OUT_P13S3:0:400})" FAIL
fi
rm -rf "$STUB_P13S3_DIR" "$SRC_P13S3_DIR"

STUB_P13S4_DIR="$(mktemp -d)"
cat >"$STUB_P13S4_DIR/claude" <<'STUB'
#!/bin/bash
printf 'untracked mutation\n' >"$PWD/injected-test.js"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"untracked-fixture"}]}}\n'
printf '{"type":"result","result":"ok"}\n'
exit 0
STUB
chmod +x "$STUB_P13S4_DIR/claude"
SRC_P13S4_DIR="$(mktemp -d -t "p13s4-src-XXXXXX")"
printf 'seeded\n' >"$SRC_P13S4_DIR/marker.txt"
OPT_P13S4="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S4_DIR")"
OUT_P13S4=$(env ZENSU_WRAPPER_TEST_MODE=1 PATH="$STUB_P13S4_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S4" 2>/dev/null)
RC_P13S4=$?
if [ "$RC_P13S4" = "3" ] \
  && printf '%s\n' "$OUT_P13S4" | grep -qF '"init_git":true,"tracked_clean":false' \
  && [ ! -e "$SRC_P13S4_DIR/injected-test.js" ]; then
  check "P13-S4 untracked fixture mutation emits dirty manifest attestation" PASS
else
  check "P13-S4 untracked fixture mutation emits dirty manifest attestation (rc=$RC_P13S4, out=${OUT_P13S4:0:400})" FAIL
fi
rm -rf "$STUB_P13S4_DIR" "$SRC_P13S4_DIR"

STUB_P13S5_DIR="$(mktemp -d)"
cat >"$STUB_P13S5_DIR/claude" <<'STUB'
#!/bin/bash
printf 'rebaselined mutation\n' >>"$PWD/marker.txt"
git add marker.txt
git -c user.name=Attacker -c user.email=attacker@example.invalid -c commit.gpgsign=false commit -qm 'hide mutation'
git update-index --assume-unchanged marker.txt
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"git-rebaseline-fixture"}]}}\n'
printf '{"type":"result","result":"ok"}\n'
exit 0
STUB
chmod +x "$STUB_P13S5_DIR/claude"
SRC_P13S5_DIR="$(mktemp -d -t "p13s5-src-XXXXXX")"
printf 'seeded\n' >"$SRC_P13S5_DIR/marker.txt"
OPT_P13S5="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S5_DIR")"
OUT_P13S5=$(env ZENSU_WRAPPER_TEST_MODE=1 PATH="$STUB_P13S5_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S5" 2>/dev/null)
RC_P13S5=$?
if [ "$RC_P13S5" = "3" ] \
  && printf '%s\n' "$OUT_P13S5" | grep -qF '"init_git":true,"tracked_clean":false' \
  && [ "$(cat "$SRC_P13S5_DIR/marker.txt")" = "seeded" ]; then
  check "P13-S5 Git commit/index manipulation cannot rebaseline fixture manifest" PASS
else
  check "P13-S5 Git commit/index manipulation cannot rebaseline fixture manifest (rc=$RC_P13S5, out=${OUT_P13S5:0:400})" FAIL
fi
rm -rf "$STUB_P13S5_DIR" "$SRC_P13S5_DIR"

STUB_P13S6_DIR="$(mktemp -d)"
cat >"$STUB_P13S6_DIR/claude" <<'STUB'
#!/bin/bash
original="$(cat "$PWD/marker.txt")"
printf 'temporary mutation\n' >"$PWD/marker.txt"
sleep 0.05
printf '%s\n' "$original" >"$PWD/marker.txt"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"restored-fixture"}]}}\n'
printf '{"type":"result","result":"ok"}\n'
exit 0
STUB
chmod +x "$STUB_P13S6_DIR/claude"
SRC_P13S6_DIR="$(mktemp -d -t "p13s6-src-XXXXXX")"
printf 'seeded\n' >"$SRC_P13S6_DIR/marker.txt"
OPT_P13S6="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S6_DIR")"
OUT_P13S6=$(env ZENSU_WRAPPER_TEST_MODE=1 PATH="$STUB_P13S6_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S6" 2>/dev/null)
RC_P13S6=$?
if [ "$RC_P13S6" = "3" ] \
  && printf '%s\n' "$OUT_P13S6" | grep -qF '"init_git":true,"tracked_clean":false' \
  && [ "$(cat "$SRC_P13S6_DIR/marker.txt")" = "seeded" ]; then
  check "P13-S6 transient source mutation is journaled even after exact byte restoration" PASS
else
  check "P13-S6 transient source mutation is journaled even after exact byte restoration (rc=$RC_P13S6, out=${OUT_P13S6:0:400})" FAIL
fi
rm -rf "$STUB_P13S6_DIR" "$SRC_P13S6_DIR"

STUB_P13S7_DIR="$(mktemp -d)"
cat >"$STUB_P13S7_DIR/claude" <<'STUB'
#!/bin/bash
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"watcher-killed"}]}}\n'
printf '{"type":"result","result":"ok"}\n'
exit 0
STUB
chmod +x "$STUB_P13S7_DIR/claude"
SRC_P13S7_DIR="$(mktemp -d -t p13s7-src-XXXXXX)"
printf 'seeded\n' >"$SRC_P13S7_DIR/marker.txt"
OPT_P13S7="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S7_DIR")"
OUT_P13S7=$(env ZENSU_WRAPPER_TEST_MODE=1 ZENSU_WRAPPER_TEST_KILL_WATCHER=1 \
  PATH="$STUB_P13S7_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S7" 2>/dev/null)
RC_P13S7=$?
if [ "$RC_P13S7" = 3 ] && printf '%s\n' "$OUT_P13S7" | grep -qF '"tracked_clean":false'; then
  check "P13-S7 dead mutation watcher fails fixture attestation closed" PASS
else
  check "P13-S7 dead mutation watcher fails fixture attestation closed (rc=$RC_P13S7, out=${OUT_P13S7:0:400})" FAIL
fi
rm -rf "$STUB_P13S7_DIR" "$SRC_P13S7_DIR"

exact_isolated_failure() {
  local output="$1" expected="$2" forbidden="${3:-}"
  local first_line second_line line_count
  first_line="$(printf '%s\n' "$output" | sed -n '1p')"
  second_line="$(printf '%s\n' "$output" | sed -n '2p')"
  line_count="$(printf '%s\n' "$output" | awk 'END { print NR }')"
  case "$first_line" in
    "claude-promptfoo-wrapper: isolated working dir: "/*/claude-eval-*) ;;
    *) return 1 ;;
  esac
  [ "$line_count" = 2 ] && [ "$second_line" = "$expected" ] || return 1
  if [ -n "$forbidden" ] && printf '%s\n' "$output" | grep -qF "$forbidden"; then
    return 1
  fi
}

SYNTHETIC_ISOLATED_FAILURE=$'claude-promptfoo-wrapper: isolated working dir: /tmp/claude-eval-AbC123\nclaude-promptfoo-wrapper: synthetic failure'
if exact_isolated_failure "$SYNTHETIC_ISOLATED_FAILURE" \
    'claude-promptfoo-wrapper: synthetic failure' 'claude-should-not-run' \
  && ! exact_isolated_failure 'claude-promptfoo-wrapper: synthetic failure' \
    'claude-promptfoo-wrapper: synthetic failure' \
  && ! exact_isolated_failure "$SYNTHETIC_ISOLATED_FAILURE" \
    'claude-promptfoo-wrapper: different failure' \
  && ! exact_isolated_failure "${SYNTHETIC_ISOLATED_FAILURE}"$'\nextra line' \
    'claude-promptfoo-wrapper: synthetic failure' \
  && ! exact_isolated_failure "${SYNTHETIC_ISOLATED_FAILURE}"$'\nclaude-should-not-run' \
    'claude-promptfoo-wrapper: synthetic failure' 'claude-should-not-run'; then
  check "P13-S7b isolated failure transcript requires one preamble plus one exact diagnostic" PASS
else
  check "P13-S7b isolated failure transcript matcher rejects malformed output" FAIL
fi

if command -v sandbox-exec >/dev/null 2>&1 || command -v bwrap >/dev/null 2>&1; then
  WATCH_PROBE_DIR="$(mktemp -d -t p13-watch-probe-XXXXXX)"
  WATCH_PROBE_MARKER="$WATCH_PROBE_DIR.marker"
  WATCH_PROBE_READY="$WATCH_PROBE_DIR.ready"
  node "$WATCHER" "$WATCH_PROBE_DIR" "$WATCH_PROBE_MARKER" "$WATCH_PROBE_READY" \
    >/dev/null 2>&1 &
  WATCH_PROBE_PID=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [ -e "$WATCH_PROBE_READY" ] && break
    kill -0 "$WATCH_PROBE_PID" 2>/dev/null || break
    sleep 0.01
  done
  if [ -e "$WATCH_PROBE_READY" ] && kill -0 "$WATCH_PROBE_PID" 2>/dev/null; then
    NATIVE_WATCH_AVAILABLE=1
  else
    NATIVE_WATCH_AVAILABLE=0
  fi
  kill "$WATCH_PROBE_PID" 2>/dev/null || true
  wait "$WATCH_PROBE_PID" 2>/dev/null || true
  rm -rf "$WATCH_PROBE_DIR" "$WATCH_PROBE_MARKER" "$WATCH_PROBE_READY"

  if [ "$NATIVE_WATCH_AVAILABLE" = 1 ]; then
  WATCH_START_FAILURE='claude-promptfoo-wrapper: failed to start immutable fixture monitor'
  STUB_P13S8_DIR="$(mktemp -d)"
  cat >"$STUB_P13S8_DIR/claude" <<'STUB'
#!/bin/bash
printf 'forbidden\n' >"$PWD/marker.txt" 2>/dev/null
printf 'forbidden recipe\n' >"$PWD/.zensu/autopilot.yaml" 2>/dev/null
mkdir -p "$PWD/.zensu/logs"
printf 'allowed\n' >"$PWD/.zensu/logs/runtime.log"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"sandbox-boundary"}]}}\n'
printf '{"type":"result","result":"ok"}\n'
exit 0
STUB
  chmod +x "$STUB_P13S8_DIR/claude"
  SRC_P13S8_DIR="$(mktemp -d -t p13s8-src-XXXXXX)"
  printf 'seeded\n' >"$SRC_P13S8_DIR/marker.txt"
  mkdir -p "$SRC_P13S8_DIR/.zensu"
  printf 'version: 1\n' >"$SRC_P13S8_DIR/.zensu/autopilot.yaml"
  OPT_P13S8="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S8_DIR")"
  OUT_P13S8=$(env PATH="$STUB_P13S8_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S8" 2>&1)
  RC_P13S8=$?
  if [ "$RC_P13S8" = 0 ] && printf '%s\n' "$OUT_P13S8" | grep -qF '"tracked_clean":true'; then
    check "P13-S8 live init_git path enforces OS-level read-only fixture with writable runtime paths" PASS
  elif [ "$RC_P13S8" = 2 ] \
    && exact_isolated_failure "$OUT_P13S8" "$WATCH_START_FAILURE" "sandbox-boundary"; then
    check "P13-S8 live immutable-fixture integration skipped because fs.watch disappeared after the probe; production failed closed" PASS
  else
    check "P13-S8 live init_git path enforces OS-level read-only fixture (rc=$RC_P13S8, out=${OUT_P13S8:0:400})" FAIL
  fi
  rm -rf "$STUB_P13S8_DIR" "$SRC_P13S8_DIR"

  STUB_OVERLAP_DIR="$(mktemp -d)"
  cat >"$STUB_OVERLAP_DIR/claude" <<'STUB'
#!/bin/bash
printf 'overlap-claude-ran\n'
STUB
  chmod +x "$STUB_OVERLAP_DIR/claude"
  SRC_OVERLAP_DIR="$(mktemp -d -t p13-overlap-src-XXXXXX)"
  printf 'seeded\n' >"$SRC_OVERLAP_DIR/marker.txt"
  OPT_OVERLAP="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_OVERLAP_DIR")"
  OUT_HOME_OVERLAP=$(env HOME=/private/tmp PATH="$STUB_OVERLAP_DIR:$PATH" \
    bash "$WRAPPER" 'p' "$OPT_OVERLAP" 2>&1)
  RC_HOME_OVERLAP=$?
  OUT_RESERVATION_OVERLAP=$(env PATH="$STUB_OVERLAP_DIR:$PATH" \
    ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF=/private/tmp/zensu-overlap-handoff \
    bash "$WRAPPER" 'p' "$OPT_OVERLAP" 2>&1)
  RC_RESERVATION_OVERLAP=$?
  HOME_OVERLAP_FAILURE='claude-promptfoo-wrapper: HOME writable root contains the immutable fixture'
  RESERVATION_OVERLAP_FAILURE='claude-promptfoo-wrapper: fixture reservation writable root contains the immutable fixture'
  HOME_OVERLAP_SAFE=false
  HOME_WATCH_UNAVAILABLE=false
  RESERVATION_OVERLAP_SAFE=false
  RESERVATION_WATCH_UNAVAILABLE=false
  if [ "$RC_HOME_OVERLAP" = 69 ] \
    && exact_isolated_failure "$OUT_HOME_OVERLAP" "$HOME_OVERLAP_FAILURE" "overlap-claude-ran"; then
    HOME_OVERLAP_SAFE=true
  elif [ "$RC_HOME_OVERLAP" = 2 ] \
    && exact_isolated_failure "$OUT_HOME_OVERLAP" "$WATCH_START_FAILURE" "overlap-claude-ran"; then
    HOME_OVERLAP_SAFE=true
    HOME_WATCH_UNAVAILABLE=true
  fi
  if [ "$RC_RESERVATION_OVERLAP" = 69 ] \
    && exact_isolated_failure "$OUT_RESERVATION_OVERLAP" "$RESERVATION_OVERLAP_FAILURE" "overlap-claude-ran"; then
    RESERVATION_OVERLAP_SAFE=true
  elif [ "$RC_RESERVATION_OVERLAP" = 2 ] \
    && exact_isolated_failure "$OUT_RESERVATION_OVERLAP" "$WATCH_START_FAILURE" "overlap-claude-ran"; then
    RESERVATION_OVERLAP_SAFE=true
    RESERVATION_WATCH_UNAVAILABLE=true
  fi
  if [ "$HOME_OVERLAP_SAFE" = true ] && [ "$RESERVATION_OVERLAP_SAFE" = true ]; then
    if [ "$HOME_WATCH_UNAVAILABLE" = true ] || [ "$RESERVATION_WATCH_UNAVAILABLE" = true ]; then
      check "P13-S8b writable-root integration skipped because fs.watch disappeared after the probe; production failed closed" PASS
    else
      check "P13-S8b writable HOME and reservation ancestors are rejected before Claude starts" PASS
    fi
  else
    check "P13-S8b writable fixture ancestors fail closed (home=$RC_HOME_OVERLAP reservation=$RC_RESERVATION_OVERLAP)" FAIL
  fi
  rm -rf "$STUB_OVERLAP_DIR" "$SRC_OVERLAP_DIR"
  else
    check "P13-S8 live immutable-fixture integration skipped because the host forbids fs.watch; production remains fail-closed" PASS
    check "P13-S8b writable-root integration skipped because the host forbids the prerequisite immutable watcher" PASS
  fi
fi

STUB_P13S9_DIR="$(mktemp -d)"
cat >"$STUB_P13S9_DIR/claude" <<'STUB'
#!/bin/bash
printf 'claude-should-not-run\n'
exit 0
STUB
chmod +x "$STUB_P13S9_DIR/claude"
SRC_P13S9_DIR="$(mktemp -d -t p13s9-src-XXXXXX)"
TARGET_P13S9="$(mktemp -t p13s9-target-XXXXXX)"
printf 'external-safe\n' >"$TARGET_P13S9"
ln -s "$TARGET_P13S9" "$SRC_P13S9_DIR/external-link"
OPT_P13S9="$(printf '{"config":{"working_dir":"%s","init_git":true}}' "$SRC_P13S9_DIR")"
OUT_P13S9=$(env ZENSU_WRAPPER_TEST_MODE=1 PATH="$STUB_P13S9_DIR:$PATH" bash "$WRAPPER" 'p' "$OPT_P13S9" 2>&1)
RC_P13S9=$?
if [ "$RC_P13S9" = 2 ] && printf '%s\n' "$OUT_P13S9" | grep -qF 'must not contain symlinks' \
  && ! printf '%s\n' "$OUT_P13S9" | grep -qF 'claude-should-not-run' \
  && [ "$(cat "$TARGET_P13S9")" = 'external-safe' ]; then
  check "P13-S9 init_git rejects fixture symlinks before Claude can escape the read-only root" PASS
else
  check "P13-S9 init_git rejects fixture symlinks before Claude runs (rc=$RC_P13S9, out=${OUT_P13S9:0:400})" FAIL
fi
rm -rf "$STUB_P13S9_DIR" "$SRC_P13S9_DIR" "$TARGET_P13S9"

WATCH_LIMIT_DIR="$(mktemp -d -t p13-watch-limit-XXXXXX)"
for ((index=0; index<129; index++)); do mkdir "$WATCH_LIMIT_DIR/d-$index"; done
node "$WATCHER" "$WATCH_LIMIT_DIR" "$WATCH_LIMIT_DIR.marker" "$WATCH_LIMIT_DIR.ready" --force-fallback >/dev/null 2>&1
WATCH_LIMIT_RC=$?
if [ "$WATCH_LIMIT_RC" != 0 ] && [ ! -e "$WATCH_LIMIT_DIR.ready" ]; then
  check "P13-S10 fallback mutation monitoring fails closed at its bounded watcher limit" PASS
else
  check "P13-S10 fallback mutation monitoring fails closed at its bounded watcher limit" FAIL
fi
rm -rf "$WATCH_LIMIT_DIR" "$WATCH_LIMIT_DIR.marker" "$WATCH_LIMIT_DIR.ready"

WATCH_BOUNDARY_DIR="$(mktemp -d -t p13-watch-boundary-XXXXXX)"
for ((index=0; index<127; index++)); do mkdir "$WATCH_BOUNDARY_DIR/d-$index"; done
node "$WATCHER" "$WATCH_BOUNDARY_DIR" "$WATCH_BOUNDARY_DIR.marker" \
  "$WATCH_BOUNDARY_DIR.ready" --force-fallback >/dev/null 2>&1 &
WATCH_BOUNDARY_PID=$!
for ((attempt=0; attempt<100; attempt++)); do [ -e "$WATCH_BOUNDARY_DIR.ready" ] && break; sleep 0.01; done
printf 'mutation\n' >"$WATCH_BOUNDARY_DIR/d-126/changed.txt"
for ((attempt=0; attempt<100; attempt++)); do [ -e "$WATCH_BOUNDARY_DIR.marker" ] && break; sleep 0.01; done
kill "$WATCH_BOUNDARY_PID" 2>/dev/null || true
wait "$WATCH_BOUNDARY_PID" 2>/dev/null || true
if [ -e "$WATCH_BOUNDARY_DIR.marker" ]; then
  check "P13-S11 exact-limit fallback watcher detects a positive mutation" PASS
else
  check "P13-S11 exact-limit fallback watcher remains functional" FAIL
fi
rm -rf "$WATCH_BOUNDARY_DIR" "$WATCH_BOUNDARY_DIR.marker" "$WATCH_BOUNDARY_DIR.ready"

# ── P14: OPTIONS_JSON default must not corrupt a provided argv[2] ─────────────
# Regression for `OPTIONS_JSON="${2:-{}}"`: bash closes the ${...} expansion at
# the FIRST `}`, so the default word is `{` plus a LITERAL trailing `}` — every
# provided argv[2] gets a stray `}` appended. jq's streaming parser masks it
# today (it emits the first value, then errors on stdout-suppressed stderr), but
# OPTIONS_JSON is malformed JSON and breaks under any strict parse / rc check.
# The default word must be quoted: `${2:-"{}"}`. Assert the exact assignment
# line round-trips a provided argv[2] byte-identical and still defaults to `{}`.
OPTIONS_ASSIGN="$(grep -m1 '^OPTIONS_JSON=' "$WRAPPER")"
P14_JSON='{"config":{"agent":"sentinel","working_dir":"/tmp/x"}}'
P14_SET="$( set -- dummy "$P14_JSON"; eval "$OPTIONS_ASSIGN"; printf '%s' "$OPTIONS_JSON" )"
if [ "$P14_SET" = "$P14_JSON" ]; then
  check "P14-S1 provided argv[2] round-trips through OPTIONS_JSON byte-identical" PASS
else
  check "P14-S1 OPTIONS_JSON corrupts provided argv[2] (got '$P14_SET')" FAIL
fi
P14_EMPTY="$( set -- dummy ""; eval "$OPTIONS_ASSIGN"; printf '%s' "$OPTIONS_JSON" )"
if [ "$P14_EMPTY" = '{}' ]; then
  check "P14-S2 empty argv[2] still defaults to {}" PASS
else
  check "P14-S2 empty argv[2] default (got '$P14_EMPTY')" FAIL
fi

echo "----"
echo "test-claude-promptfoo-wrapper: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
