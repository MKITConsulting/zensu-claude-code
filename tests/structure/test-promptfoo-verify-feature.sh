#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$PLUGIN_DIR/evals/verify-feature"
CFG="$EVAL_DIR/promptfooconfig.yaml"
LOCAL="$EVAL_DIR/scenarios/local-happy-path.yaml"
REMOTE="$EVAL_DIR/scenarios/remote-unsafe-url.yaml"
REMOTE_ACCEPTED="$EVAL_DIR/scenarios/remote-accepted-public.yaml"
REMOTE_PROVIDER="$EVAL_DIR/remote-provider.sh"
FIXTURE="$EVAL_DIR/test-projects/live-app"
RECIPE="$FIXTURE/.zensu/autopilot.yaml"
REMOTE_RECIPE="$FIXTURE/.zensu/remote-example.yaml"
RUNTIME="$FIXTURE/scripts/fixture-runtime.sh"
SERVER="$FIXTURE/scripts/fixture-server.js"
RUNNER="$EVAL_DIR/run-eval.sh"
RESERVATION="$EVAL_DIR/port-reservation.js"
README="$EVAL_DIR/README.md"
ASSERTION="$EVAL_DIR/assertions/transcript-check.js"
CONTRACT_TEST="$PLUGIN_DIR/tests/structure/verify-feature-transcript-check.test.js"
# Shared, locale-independent `node --test` summary parse (see the file header for
# why the count matters and why it is not hand-copied here).
. "$(dirname "$0")/lib-unit-summary.sh"


PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

LOOPBACK_AVAILABLE=0
if node -e '
  const net = require("node:net");
  const server = net.createServer();
  server.once("error", () => process.exit(1));
  server.listen(0, "127.0.0.1", () => server.close(() => process.exit(0)));
' >/dev/null 2>&1; then
  LOOPBACK_AVAILABLE=1
fi

for file in "$CFG" "$LOCAL" "$REMOTE" "$REMOTE_ACCEPTED" "$REMOTE_PROVIDER" "$RECIPE" "$REMOTE_RECIPE" "$RUNTIME" "$SERVER" "$FIXTURE/public/index.html" "$FIXTURE/CLAUDE.md" "$FIXTURE/.gitignore" "$RUNNER" "$RESERVATION" "$README" "$ASSERTION" "$CONTRACT_TEST"; do
  if [ -f "$file" ]; then
    check "file exists: ${file#$PLUGIN_DIR/}" PASS
  else
    check "file exists: ${file#$PLUGIN_DIR/}" FAIL
  fi
done

if [ -x "$RUNTIME" ] && [ -x "$RUNNER" ] && [ -x "$REMOTE_PROVIDER" ]; then
  check "runtime and live runner are executable" PASS
else
  check "runtime and live runner are executable" FAIL
fi

if bash -n "$RUNTIME" && bash -n "$RUNNER" && node --check "$SERVER" >/dev/null && node --check "$RESERVATION" >/dev/null && node --check "$ASSERTION" >/dev/null \
  && node --check "$CONTRACT_TEST" >/dev/null; then
  check "fixture and runner syntax checks pass" PASS
else
  check "fixture and runner syntax checks pass" FAIL
fi

CONTRACT_OUT="$(node --test "$CONTRACT_TEST" 2>&1)"
if [ "$?" = 0 ] && unit_cases_meet_floor_text "$CONTRACT_OUT" 14; then
  check "deterministic transcript contract regressions pass ($(unit_cases_report_text "$CONTRACT_OUT"))" PASS
else
  check "deterministic transcript contract regressions pass ($(unit_cases_report_text "$CONTRACT_OUT"), want >= 14 registered)" FAIL
fi

ASSERTION_SMOKE="$(node -e 'const check=require(process.argv[1]); const attest="\n===== wrapper attestation =====\n[wrapper_attestation] {\"init_git\":true,\"tracked_clean\":true,\"manifest_version\":1,\"root\":\"/tmp/eval\"}\n"; const up="[tool_use: Bash] id=u input={\"command\":\"./scripts/fixture-runtime.sh up\"}\n[tool_result: Bash] id=u is_error=false\nfixture-runtime: started\n"; const browser="[tool_use: mcp__playwright__browser_snapshot] id=s input={}\n[tool_result: mcp__playwright__browser_snapshot] id=s is_error=false\nok\n"; const down="[tool_use: Bash] id=d input={\"command\":\"./scripts/fixture-runtime.sh down\"}\n[tool_result: Bash] id=d is_error=false\nfixture-runtime: stopped\n"; const good=up+browser+down+attest; const fake=up+browser+"[tool_use: Bash] id=d input={\"command\":\"printf stopped # fixture-runtime.sh down\"}\n[tool_result: Bash] id=d is_error=false\nfixture-runtime: stopped\n"+attest; const unsafe=up+browser+"[tool_use: mcp__playwright__browser_run_code_unsafe] id=e input={}\n"+down+attest; if(check(good,{config:{check:"localTeardown"}}).pass&&!check(fake,{config:{check:"localTeardown"}}).pass&&!check(unsafe,{config:{check:"localTeardown"}}).pass) process.stdout.write("ok");' "$ASSERTION" 2>/dev/null)"
if [ "$ASSERTION_SMOKE" = "ok" ]; then
  check "grading requires clean attestation and rejects fake teardown/browser_evaluate" PASS
else
  check "grading requires clean attestation and rejects fake teardown/browser_evaluate" FAIL
fi
ASSERTION_PROTOCOL_SMOKE="$(node -e 'const check=require(process.argv[1]); const call="[tool_use: Skill] id=s1 input={\"skill\":\"zensu:verify-feature\"}\n"; const exact=call+"[tool_result: Skill] id=s1 is_error=false\nloaded\n"; const spoof="[tool_use: Skill] id=s1 input={\"skill\":\"other\",\"args\":\"\\\"skill\\\":\\\"zensu:verify-feature\\\"\"}\n[tool_result: Skill] id=s1 is_error=false\nloaded\n"; const pass="[assistant_text]\nreport\nVERIFY-FEATURE-VERDICT: PASS\n"; const early="[assistant_text]\nVERIFY-FEATURE-VERDICT: PASS\ntrailing text\n"; const duplicate="[assistant_text]\nVERIFY-FEATURE-VERDICT: PASS\nVERIFY-FEATURE-VERDICT: PASS\n"; const warned=exact+"[stream_warning] event limit reached\n"; if(check(exact,{config:{check:"skillInvocation"}}).pass&&!check(call,{config:{check:"skillInvocation"}}).pass&&!check(spoof,{config:{check:"skillInvocation"}}).pass&&!check(warned,{config:{check:"skillInvocation"}}).pass&&check(pass,{config:{check:"localVerdict"}}).pass&&!check(early,{config:{check:"localVerdict"}}).pass&&!check(duplicate,{config:{check:"localVerdict"}}).pass) process.stdout.write("ok");' "$ASSERTION" 2>/dev/null)"
if [ "$ASSERTION_PROTOCOL_SMOKE" = "ok" ]; then
  check "protocol grading decodes Skill input and requires one terminal verdict line" PASS
else
  check "protocol grading decodes Skill input and requires one terminal verdict line" FAIL
fi

if grep -qF 'claude-promptfoo-wrapper.sh' "$CFG" \
  && grep -qF 'working_dir: ./test-projects/live-app' "$CFG" \
  && grep -qF 'init_git: true' "$CFG"; then
  check "config uses the wrapper, live fixture, and isolated Git initialization" PASS
else
  check "config uses the wrapper, live fixture, and isolated Git initialization" FAIL
fi

if grep -qF 'local-happy-path.yaml' "$CFG" \
  && grep -qF 'remote-unsafe-url.yaml' "$CFG" \
  && grep -qF 'remote-accepted-public.yaml' "$CFG" \
  && grep -qF 'maxConcurrency: 1' "$CFG"; then
  check "config registers all three sequential live scenarios" PASS
else
  check "config registers all three sequential live scenarios" FAIL
fi

if grep -qF 'ZENSU_PLUGIN_DIR_OVERRIDE' "$RUNNER" \
  && grep -qF 'unset ZENSU_WRAPPER_TEST_MODE ZENSU_WRAPPER_TEST_KILL_WATCHER' "$RUNNER" \
  && grep -qF 'ZENSU_MCP_TEST_MODE ZENSU_MCP_TEST_PASSTHROUGH ZENSU_MCP_RUNTIME_DIR_OVERRIDE' "$RUNNER" \
  && grep -qF 'ZENSU_E2E_DISPOSABLE_ENVIRONMENT' "$RUNNER" \
  && grep -qF 'PROMPTFOO_CONFIG_DIR' "$RUNNER" \
  && grep -qF 'PROMPTFOO_DISABLE_TELEMETRY=1' "$RUNNER" \
  && grep -qF 'playwright-mcp.sh" --zensu-install-runtime' "$RUNNER" \
  && grep -qF 'PROMPTFOO_PID=$!' "$RUNNER" \
  && grep -qF "trap 'exit 143' TERM HUP" "$RUNNER" \
  && grep -qF -- '--no-cache' "$RUNNER" \
  && grep -qF -- '--no-share' "$RUNNER" \
  && grep -qF -- '--no-write' "$RUNNER"; then
  check "runner targets this worktree and disables persistent/shared Promptfoo state and telemetry" PASS
else
  check "runner targets this worktree and disables persistent/shared Promptfoo state and telemetry" FAIL
fi
if grep -qF 'require_disposable_environment: true' "$CFG" \
  && grep -qF 'ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 evals/verify-feature/run-eval.sh' "$README" \
  && grep -qF 'OS-enforced read-only filesystem boundary' "$README" \
  && grep -qF 'not a general host, process, or network sandbox' "$README"; then
  check "live eval requires and documents a disposable unrestricted host" PASS
else
  check "live eval requires and documents a disposable unrestricted host" FAIL
fi
if grep -qF 'promptfoo claude jq node npm git curl' "$RUNNER"; then
  check "runner preflights every CLI required by the locked browser runtime" PASS
else
  check "runner preflights every CLI required by the locked browser runtime" FAIL
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "TERM process-group cleanup is covered on macOS/Linux/WSL (native Windows live eval unsupported)" PASS
    ;;
  *)
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "TERM runner integration skipped because the managed host forbids loopback listeners" PASS
else
RUNNER_SIGNAL_STUBS="$(mktemp -d -t verify-feature-runner-signal-XXXXXX)"
RUNNER_SIGNAL_STATE="$RUNNER_SIGNAL_STUBS/state"
RUNNER_LATE_STATE="$RUNNER_SIGNAL_STUBS/late.pid"
cat >"$RUNNER_SIGNAL_STUBS/bash" <<'STUB'
#!/bin/bash
case "${1:-} ${2:-}" in
  *playwright-mcp.sh*' --zensu-install-runtime') exit 0 ;;
  *) exec /bin/bash "$@" ;;
esac
STUB
cat >"$RUNNER_SIGNAL_STUBS/claude" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$RUNNER_SIGNAL_STUBS/promptfoo" <<'STUB'
#!/bin/bash
exec node -e '
  const { spawn } = require("node:child_process");
  const fs = require("node:fs");
  process.on("SIGTERM", () => {
    const child = spawn(process.execPath, ["-e", "process.on(\"SIGTERM\",()=>{});setInterval(()=>{},1000)"], { stdio: "ignore" });
    fs.writeFileSync(process.env.RUNNER_LATE_STATE, String(child.pid));
    setTimeout(() => process.exit(0), 50);
  });
  fs.writeFileSync(process.env.RUNNER_SIGNAL_STATE, `${process.pid} ${process.env.PROMPTFOO_CONFIG_DIR}\n`);
  setInterval(() => {}, 1000);
'
STUB
chmod +x "$RUNNER_SIGNAL_STUBS"/*
env PATH="$RUNNER_SIGNAL_STUBS:$PATH" RUNNER_SIGNAL_STATE="$RUNNER_SIGNAL_STATE" \
  RUNNER_LATE_STATE="$RUNNER_LATE_STATE" \
  ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 /bin/bash "$RUNNER" \
  >"$RUNNER_SIGNAL_STUBS/out" 2>"$RUNNER_SIGNAL_STUBS/err" &
RUNNER_SIGNAL_PID=$!
for ((attempt=0; attempt<300; attempt++)); do
  [ -s "$RUNNER_SIGNAL_STATE" ] && break
  kill -0 "$RUNNER_SIGNAL_PID" 2>/dev/null || break
  sleep 0.01
done
PROMPTFOO_SIGNAL_PID=""; PROMPTFOO_DESCENDANT_PID=""; PROMPTFOO_SIGNAL_DIR=""
read -r PROMPTFOO_SIGNAL_PID PROMPTFOO_SIGNAL_DIR \
  <"$RUNNER_SIGNAL_STATE" 2>/dev/null || true
RUNNER_OWNED_PIDS="$(pgrep -P "$RUNNER_SIGNAL_PID" 2>/dev/null || true)"
kill -TERM "$RUNNER_SIGNAL_PID" 2>/dev/null || true
wait "$RUNNER_SIGNAL_PID"
RUNNER_SIGNAL_RC=$?
PROMPTFOO_DESCENDANT_PID="$(sed -n '1p' "$RUNNER_LATE_STATE" 2>/dev/null || true)"
for ((attempt=0; attempt<100; attempt++)); do
  RUNNER_TREE_ALIVE=false
  for pid in $RUNNER_OWNED_PIDS "$PROMPTFOO_SIGNAL_PID" "$PROMPTFOO_DESCENDANT_PID"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && RUNNER_TREE_ALIVE=true
  done
  [ "$RUNNER_TREE_ALIVE" = false ] && break
  sleep 0.05
done
if [ "$RUNNER_SIGNAL_RC" = 143 ] && [ -n "$PROMPTFOO_DESCENDANT_PID" ] \
  && [ "$RUNNER_TREE_ALIVE" = false ] \
  && [ -n "$PROMPTFOO_SIGNAL_DIR" ] && [ ! -e "$PROMPTFOO_SIGNAL_DIR" ]; then
  check "TERM reaps Promptfoo's late-forked descendant, port reservation, and temporary runner state" PASS
else
  check "TERM fully cleans the live runner process tree (rc=$RUNNER_SIGNAL_RC alive=$RUNNER_TREE_ALIVE)" FAIL
  for pid in $RUNNER_OWNED_PIDS "$PROMPTFOO_SIGNAL_PID" "$PROMPTFOO_DESCENDANT_PID"; do
    [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  done
fi
rm -rf "$RUNNER_SIGNAL_STUBS"
fi
    ;;
esac

if grep -qF '/zensu:verify-feature' "$LOCAL" \
  && grep -qF 'exhaustive' "$LOCAL" \
  && grep -qF 'Do not resize the browser.' "$LOCAL" \
  && grep -qF 'own standalone Bash invocation exactly' "$LOCAL" \
  && grep -qF 'own standalone Bash invocation, byte-for-byte' "$FIXTURE/CLAUDE.md" \
  && grep -qF 'file://assertions/transcript-check.js' "$LOCAL" \
  && grep -qF 'check: localEvidence' "$LOCAL" \
  && grep -qF 'check: localTeardown' "$LOCAL" \
  && grep -qF "input?.skill === 'zensu:verify-feature'" "$ASSERTION" \
  && grep -qF 'browser_take_screenshot' "$ASSERTION" \
  && grep -qF 'result.id === call.id' "$ASSERTION" \
  && grep -qF "input.command === './scripts/fixture-runtime.sh down'" "$ASSERTION" \
  && grep -qF 'result.id === teardown.id' "$ASSERTION" \
  && grep -qF 'screenshotEvidenceOffsets({' "$ASSERTION" \
  && grep -qF "Object.prototype.hasOwnProperty.call(input, 'filename')" "$ASSERTION" \
  && grep -qF 'imageEvidence.test(result.body)' "$ASSERTION" \
  && grep -qF 'after: snapshot.end' "$ASSERTION"; then
  check "local scenario pins correlated browser evidence, data, verdict, and teardown" PASS
else
  check "local scenario pins correlated browser evidence, data, verdict, and teardown" FAIL
fi

if grep -qF 'EXAMPLE_REJECT_ME' "$REMOTE" \
  && grep -qF 'remote target rejected before' "$REMOTE" \
  && grep -qF 'Do not repeat or describe the rejected scheme, hostname, path, query key' "$REMOTE" \
  && grep -qF 'check: remoteOnlySkill' "$REMOTE" \
  && grep -qF 'check: remoteNoLeak' "$REMOTE" \
  && grep -qF 'uses.length === 1' "$ASSERTION" \
  && grep -qF 'no later tool call' "$ASSERTION" \
  && grep -qF 'No assistant-authored prose may repeat' "$ASSERTION"; then
  check "remote scenario pins pre-navigation query rejection and final-report non-disclosure" PASS
else
  check "remote scenario pins pre-navigation query rejection and final-report non-disclosure" FAIL
fi

if grep -qF "id: 'exec: ./remote-provider.sh'" "$REMOTE_ACCEPTED" \
  && grep -qF 'https://example.com/' "$REMOTE_ACCEPTED" \
  && grep -qF 'check: remoteAcceptedTools' "$REMOTE_ACCEPTED" \
  && grep -qF 'check: remoteAcceptedEvidence' "$REMOTE_ACCEPTED" \
  && grep -qF 'check: remoteAcceptedVerdict' "$REMOTE_ACCEPTED" \
  && grep -qF '"mode":"remote"' "$REMOTE_PROVIDER" \
  && grep -qF '"origin":"https://example.com"' "$REMOTE_PROVIDER" \
  && grep -qF 'mode: declared-safe' "$REMOTE_RECIPE" \
  && grep -qF 'dataClassification: pre-classified-non-sensitive' "$REMOTE_RECIPE" \
  && grep -qF 'containsSecrets: false' "$REMOTE_RECIPE"; then
  check "accepted remote scenario pins a dedicated exact policy and complete brokered evidence" PASS
else
  check "accepted remote scenario and policy are fully registered" FAIL
fi

if grep -qF 'up: "./scripts/fixture-runtime.sh up"' "$RECIPE" \
  && grep -qF 'ready: "./scripts/fixture-runtime.sh ready"' "$RECIPE" \
  && grep -qF 'down: "./scripts/fixture-runtime.sh down"' "$RECIPE" \
  && grep -qF 'bindHost: "127.0.0.1"' "$RECIPE" \
  && grep -qF 'port: "parent-reserved-exact"' "$RECIPE" \
  && grep -qF 'baseUrlCommand:' "$RECIPE" \
  && grep -qF 'navigationBroker:' "$RECIPE" \
  && grep -qF 'policyEnv: ZENSU_VERIFY_NAVIGATION_POLICY_V1' "$RECIPE" \
  && grep -qF 'contractVersion: 1' "$RECIPE" \
  && grep -qF 'mode: declared-safe' "$RECIPE" \
  && grep -qF 'dataClassification: synthetic' "$RECIPE" \
  && grep -qF 'containsPersonalData: false' "$RECIPE" \
  && grep -qF 'containsSecrets: false' "$RECIPE"; then
  check "runtime recipe declares startup, isolation, scoped teardown, and synthetic evidence safety" PASS
else
  check "runtime recipe declares startup, isolation, scoped teardown, and synthetic evidence safety" FAIL
fi

if grep -qF 'server.listen(0, host' "$SERVER" \
  && grep -qF "const host = '127.0.0.1'" "$SERVER" \
  && grep -qF 'ZENSU_FIXTURE_BACKEND_PORT_FILE' "$SERVER" \
  && grep -qF 'ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF' "$RUNTIME" \
  && grep -qF 'owns_pid' "$RUNTIME" \
  && grep -qF 'pid="$(read_pid)"' "$RUNTIME" \
  && grep -qF 'token="$(read_token)"' "$RUNTIME" \
  && grep -qF -- '--lease-token=' "$RUNTIME" \
  && ! grep -qE '\bpkill\b|\bkillall\b' "$RUNTIME"; then
  check "fixture uses a parent-reserved brokered loopback port and exact-PID ownership" PASS
else
  check "fixture uses a parent-reserved brokered loopback port and exact-PID ownership" FAIL
fi

if grep -qF '.verify-runtime/' "$FIXTURE/.gitignore" \
  && grep -qF '.zensu/hook-events.log' "$FIXTURE/.gitignore"; then
  check "fixture ignores run-owned runtime and wrapper artifacts" PASS
else
  check "fixture ignores run-owned runtime and wrapper artifacts" FAIL
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "fixture lifecycle smoke test (covered on macOS/Linux/WSL)" PASS
    ;;
  *)
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "fixture lifecycle integration skipped because the managed host forbids loopback listeners" PASS
else
SMOKE_DIR="$(mktemp -d -t verify-feature-smoke-XXXXXX)"
cp -R "$FIXTURE/." "$SMOKE_DIR/"
SMOKE_RUNTIME="$SMOKE_DIR/scripts/fixture-runtime.sh"
SMOKE_OUT=""
SMOKE_PID=""
SMOKE_BODY=""
SMOKE_OK=0
SMOKE_RESERVATION_DIR="$(mktemp -d -t verify-feature-port-XXXXXX)"
SMOKE_PORT_FILE="$SMOKE_RESERVATION_DIR/port"
SMOKE_HANDOFF="$SMOKE_RESERVATION_DIR/handoff"
SMOKE_ACK="$SMOKE_RESERVATION_DIR/ack"
SMOKE_TOKEN='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
node "$RESERVATION" "$SMOKE_PORT_FILE" "$SMOKE_HANDOFF" "$SMOKE_ACK" "$SMOKE_TOKEN" &
SMOKE_RESERVATION_PID=$!
for ((attempt=0; attempt<200; attempt++)); do [ -s "$SMOKE_PORT_FILE" ] && break; sleep 0.01; done
SMOKE_PORT="$(sed -n '1p' "$SMOKE_PORT_FILE")"
if SMOKE_OUT="$(ZENSU_VERIFY_FIXTURE_PORT="$SMOKE_PORT" \
  ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF="$SMOKE_HANDOFF" \
  ZENSU_VERIFY_FIXTURE_RESERVATION_ACK="$SMOKE_ACK" \
  ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN="$SMOKE_TOKEN" "$SMOKE_RUNTIME" up 2>/dev/null)"; then
  SMOKE_PID="$(sed -n '1p' "$SMOKE_DIR/.verify-runtime/server.pid" 2>/dev/null)"
  if "$SMOKE_RUNTIME" ready \
    && [ "$($SMOKE_RUNTIME url)" = "$SMOKE_OUT" ] \
    && SMOKE_BODY="$(curl --fail --silent "$SMOKE_OUT/api/items")" \
    && printf '%s\n' "$SMOKE_BODY" | grep -qF '"name":"Alpha","quantity":3' \
    && printf '%s\n' "$SMOKE_BODY" | grep -qF '"name":"Beta","quantity":7'; then
    SMOKE_OK=1
  fi
fi
kill "$SMOKE_RESERVATION_PID" 2>/dev/null || true
wait "$SMOKE_RESERVATION_PID" 2>/dev/null || true
"$SMOKE_RUNTIME" down >/dev/null 2>&1 || true
if [ "$SMOKE_OK" = "1" ] \
  && { [ -z "$SMOKE_PID" ] || ! kill -0 "$SMOKE_PID" 2>/dev/null; } \
  && [ ! -e "$SMOKE_DIR/.verify-runtime" ]; then
  check "fixture lifecycle smoke test serves inventory and removes its exact runtime" PASS
else
  check "fixture lifecycle smoke test serves inventory and removes its exact runtime" FAIL
fi
rm -rf "$SMOKE_DIR" "$SMOKE_RESERVATION_DIR"
fi
    ;;
esac

NEG_DIR="$(mktemp -d -t verify-feature-port-negative-XXXXXX)"
NEG_PORT_FILE="$NEG_DIR/port"
NEG_HANDOFF="$NEG_DIR/handoff"
NEG_ACK="$NEG_DIR/ack"
NEG_TOKEN='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
node "$RESERVATION" relative-port "$NEG_HANDOFF" "$NEG_ACK" "$NEG_TOKEN" >/dev/null 2>&1
if [ "$?" = 2 ]; then
  check "port proxy rejects non-absolute parent contract paths" PASS
else
  check "port proxy rejects non-absolute parent contract paths" FAIL
fi
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "wrong-token proxy integration skipped because the managed host forbids loopback listeners" PASS
else
  node "$RESERVATION" "$NEG_PORT_FILE" "$NEG_HANDOFF" "$NEG_ACK" "$NEG_TOKEN" &
  NEG_PID=$!
  for ((attempt=0; attempt<200; attempt++)); do [ -s "$NEG_PORT_FILE" ] && break; sleep 0.01; done
  printf '{"token":"wrongwrongwrongwrongwrongwrongwr","targetPort":12345}\n' >"$NEG_HANDOFF"
  sleep 0.1
  if kill -0 "$NEG_PID" 2>/dev/null && [ ! -e "$NEG_ACK" ]; then
    check "port proxy rejects a handoff with the wrong parent token and keeps the reservation" PASS
  else
    check "port proxy rejects a handoff with the wrong parent token and keeps the reservation" FAIL
  fi
  kill "$NEG_PID" 2>/dev/null || true
  wait "$NEG_PID" 2>/dev/null || true
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "fixture parent-death cleanup (covered on macOS/Linux/WSL)" PASS
    ;;
  *)
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "fixture parent-death integration skipped because the managed host forbids loopback listeners" PASS
else
EARLY_DIR="$(mktemp -d -t verify-feature-early-death-XXXXXX)"
cp -R "$FIXTURE/." "$EARLY_DIR/"
EARLY_PORT_FILE="$NEG_DIR/early-port"
EARLY_HANDOFF="$NEG_DIR/early-handoff"
EARLY_ACK="$NEG_DIR/early-ack"
node "$RESERVATION" "$EARLY_PORT_FILE" "$EARLY_HANDOFF" "$EARLY_ACK" "$NEG_TOKEN" &
EARLY_PID=$!
for ((attempt=0; attempt<200; attempt++)); do [ -s "$EARLY_PORT_FILE" ] && break; sleep 0.01; done
EARLY_PORT="$(sed -n '1p' "$EARLY_PORT_FILE")"
kill "$EARLY_PID" 2>/dev/null || true
wait "$EARLY_PID" 2>/dev/null || true
ZENSU_VERIFY_FIXTURE_PORT="$EARLY_PORT" \
  ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF="$EARLY_HANDOFF" \
  ZENSU_VERIFY_FIXTURE_RESERVATION_ACK="$EARLY_ACK" \
  ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN="$NEG_TOKEN" \
  "$EARLY_DIR/scripts/fixture-runtime.sh" up >/dev/null 2>&1
EARLY_RC=$?
if [ "$EARLY_RC" != 0 ] && [ ! -e "$EARLY_DIR/.verify-runtime" ]; then
  check "fixture startup fails closed and cleans up when the parent proxy dies before acknowledgement" PASS
else
  check "fixture startup fails closed when the parent proxy dies before acknowledgement" FAIL
fi
rm -rf "$NEG_DIR" "$EARLY_DIR"
fi
    ;;
esac

rm -rf "$NEG_DIR"

if grep -qF 'live and advisory' "$README" \
  && grep -qF 'remote-accepted-public.yaml' "$README" \
  && grep -qF 'tests/structure/test-promptfoo-verify-feature.sh' "$README"; then
  check "eval README separates advisory live proof from deterministic structure coverage" PASS
else
  check "eval README separates advisory live proof from deterministic structure coverage" FAIL
fi

echo "----"
echo "test-promptfoo-verify-feature: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
