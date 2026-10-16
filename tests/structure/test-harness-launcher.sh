#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN_DIR/harness/launcher.js"
MANIFEST="$PLUGIN_DIR/harness/manifest.json"
RUNTIME="$PLUGIN_DIR/hooks/lib/work-order-v1.js"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
FAKE_LIB="$PLUGIN_DIR/tests/structure/lib-work-order.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-harness-launcher: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

. "$(dirname "$0")/lib-unit-registry.sh"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "native Windows launcher run skipped (macOS/Linux/WSL required)" PASS
    unit_check_done "H12a every unit file the registry gives this suite was graded"
    finish; exit
    ;;
esac

if [ -f "$LAUNCHER" ] && node --check "$LAUNCHER" 2>/dev/null && [ -f "$MANIFEST" ] && [ -f "$RUNTIME" ] \
  && [ -f "$STATE_LIB" ] && [ -f "$FAKE_LIB" ] && bash -n "$FAKE_LIB" 2>/dev/null; then
  check "H0 launcher, manifest, runtime, state library and fake exist and parse" PASS
else
  check "H0 launcher, manifest, runtime, state library and fake exist and parse" FAIL
  finish; exit 1
fi

MANIFEST_VERDICT="$(PLUGIN_DIR="$PLUGIN_DIR" node -e '
  const fs = require("fs");
  const path = require("path");
  const root = process.env.PLUGIN_DIR;
  const runtime = require(path.join(root, "hooks", "lib", "work-order-v1.js"));
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(path.join(root, "harness", "manifest.json"), "utf8")); }
  catch (_) { process.stdout.write("unparseable"); process.exit(0); }
  const problems = [];
  const keys = Object.keys(manifest).sort().join(",");
  if (keys !== "contract_version,harness,launcher,supported_kinds") problems.push(`keys:${keys}`);
  if (manifest.harness !== runtime.CLIENT_NAME) problems.push("harness");
  if (!Number.isSafeInteger(manifest.contract_version) || manifest.contract_version < 1) problems.push("contract_version");
  const launcher = typeof manifest.launcher === "string" ? manifest.launcher : "";
  const resolved = path.resolve(root, launcher);
  if (!launcher || path.isAbsolute(launcher) || !resolved.startsWith(root + path.sep)) problems.push("launcher-path");
  else {
    try {
      const stat = fs.statSync(resolved);
      if (!stat.isFile() || (process.platform !== "win32" && (stat.mode & 0o111) === 0)) problems.push("launcher-file");
    } catch (_) { problems.push("launcher-missing"); }
  }
  if (JSON.stringify(manifest.supported_kinds) !== JSON.stringify([...runtime.SUPPORTED_KINDS])) problems.push("supported_kinds");
  process.stdout.write(problems.length ? problems.join(" ") : "ok");
' 2>&1)"
[ "$MANIFEST_VERDICT" = "ok" ] \
  && check "H1 the manifest names the harness, the contract version, an executable launcher in the plugin and the kinds the runtime supports" PASS \
  || check "H1 the manifest contract ($MANIFEST_VERDICT)" FAIL

source "$FAKE_LIB"
SBOX="$(mktemp -d -t harness-launcher-XXXXXX)"
SBOX="$(cd "$SBOX" && pwd -P)"
trap 'rm -rf "$SBOX"' EXIT
export HOME="$SBOX/home"
mkdir -p "$HOME"
export ZENSU_CONFIG="$SBOX/config.json"
printf '%s\n' '{}' > "$ZENSU_CONFIG"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Launcher Test" GIT_AUTHOR_EMAIL="launcher@example.invalid"
export GIT_COMMITTER_NAME="Launcher Test" GIT_COMMITTER_EMAIL="launcher@example.invalid"
wo_fake_install "$SBOX/bin" || { check "H2 fake zensu installs" FAIL; finish; exit 1; }
export PATH="$SBOX/bin:$PATH"
export FAKE_ZENSU_STATE="$SBOX/fake.json"
export FAKE_ZENSU_CALLS="$SBOX/calls.jsonl"
export ZENSU_WORK_ORDER_RETRY_MS=1
export ZENSU_WORK_ORDER_RETRY_BUDGET_MS=50
export ZENSU_SESSION_TOKEN="zst_fake_session_token"
export ZENSU_LAUNCHER_TICK_MS=100
export ZENSU_LAUNCHER_STOP_GRACE_MS=2000

FAKE_CLAUDE="$SBOX/fake-claude.js"
cat > "$FAKE_CLAUDE" <<'FAKE_CLAUDE_JS'
#!/usr/bin/env node
'use strict';
const fs = require('fs');
const mode = process.env.FAKE_CLAUDE_MODE || 'success';
if (process.env.FAKE_CLAUDE_ARGV) fs.writeFileSync(process.env.FAKE_CLAUDE_ARGV, JSON.stringify(process.argv.slice(2)));
if (process.env.FAKE_CLAUDE_PID) fs.writeFileSync(process.env.FAKE_CLAUDE_PID, String(process.pid));
const sessionId = process.argv[process.argv.indexOf('--session-id') + 1];
const line = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
line({ type: 'system', subtype: 'init', cwd: process.cwd(), session_id: sessionId, tools: ['Bash'], model: 'fake' });
line({ type: 'assistant', message: { content: [{ type: 'text', text: 'TRANSCRIPT-SECRET-4711 git push origin main' }] }, session_id: sessionId });
line({ type: 'user', message: { content: [{ type: 'tool_result', content: 'TOOL-OUTPUT-SECRET-4711' }] }, session_id: sessionId });
const result = (isError) => line({ type: 'result', subtype: isError ? 'error_during_execution' : 'success', is_error: isError, num_turns: 3, session_id: sessionId, total_cost_usd: 0.42 });
if (mode === 'success') { result(false); process.exit(0); }
if (mode === 'ratelimit') {
  line({ type: 'system', subtype: 'api_retry', attempt: 1, max_retries: 10, retry_delay_ms: 60000, error_status: 429, error: 'rate_limit' });
  result(false);
  process.exit(0);
}
if (mode === 'failure') { result(true); process.exit(1); }
if (mode === 'linger') {
  setTimeout(() => { result(false); process.exit(0); }, Number(process.env.FAKE_CLAUDE_MS || 1500));
} else {
  setInterval(() => {}, 1000);
}
FAKE_CLAUDE_JS
chmod +x "$FAKE_CLAUDE"

ORDER="44444444-4444-4444-8444-444444444444"
SID="5f0c3c3e-1d2b-4c1a-9b7e-2f6a1c0d9e88"
PROJECT="$SBOX/project"
git init -q -b main "$PROJECT"
printf 'seed\n' > "$PROJECT/README.md"
printf '.zensu/\n' > "$PROJECT/.gitignore"
git -C "$PROJECT" add README.md .gitignore
git -C "$PROJECT" commit -q -m "chore: seed"

json_lines_ok() {
  FILE="$1" EXPR="$2" node -e '
    const lines = require("fs").readFileSync(process.env.FILE, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
    process.exit(Function("lines", `return (${process.env.EXPR})`)(lines) ? 0 : 1);
  ' 2>/dev/null
}
launch() {
  local out="$1"; shift
  node "$LAUNCHER" --order "$ORDER" --session-id "$SID" --project "$PROJECT" --claude "$FAKE_CLAUDE" "$@" >"$out" 2>"$out.err"
}
reap() {
  local launcher_pid="$1" pid_file="$2" waited=0
  while kill -0 "$launcher_pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$launcher_pid" 2>/dev/null; then
    kill -KILL "$launcher_pid" 2>/dev/null
    [ -f "$pid_file" ] && kill -KILL "$(cat "$pid_file")" 2>/dev/null
    wait "$launcher_pid" 2>/dev/null
    return 124
  fi
  wait "$launcher_pid"
}

FAKE_CLAUDE_MODE=success FAKE_CLAUDE_ARGV="$SBOX/argv.json" launch "$SBOX/success.out" --permission-mode acceptEdits -- --model fake-model
RC=$?
if [ "$RC" -eq 0 ] && json_lines_ok "$SBOX/success.out" \
    'lines.length === 2 && lines[0].event === "session_started" && lines[0].client_session_id === "'"$SID"'" && lines[1].event === "exited" && lines[1].status === "success" && lines[1].exit_code === 0'; then
  check "H2 a successful session prints session_started and exited success, and the launcher exits 0" PASS
else
  check "H2 a successful session (rc=$RC out=$(cat "$SBOX/success.out") err=$(cat "$SBOX/success.out.err"))" FAIL
fi

if ! grep -qE 'TRANSCRIPT-SECRET|TOOL-OUTPUT-SECRET|git push|total_cost_usd|0\.42' "$SBOX/success.out" \
  && json_lines_ok "$SBOX/success.out" 'lines.every((line) => ["session_started", "rate_limited", "exited"].includes(line.event))'; then
  check "H3 the launcher forwards no transcript, tool call, tool output or cost, only the normalized lines" PASS
else
  check "H3 the launcher forwards nothing but the normalized lines ($(cat "$SBOX/success.out"))" FAIL
fi

if ARGV_FILE="$SBOX/argv.json" SID="$SID" ORDER="$ORDER" node -e '
  const argv = JSON.parse(require("fs").readFileSync(process.env.ARGV_FILE, "utf8"));
  const pair = (flag, value) => argv.some((arg, index) => arg === flag && argv[index + 1] === value);
  const ok = argv[0] === "-p" && pair("--session-id", process.env.SID) && pair("--output-format", "stream-json")
    && argv.includes("--verbose") && pair("--setting-sources", "user") && argv.includes("--strict-mcp-config")
    && pair("--permission-mode", "acceptEdits") && pair("--model", "fake-model")
    && argv[argv.length - 1] === `/zensu:work ${process.env.ORDER}`;
  process.exit(ok ? 0 : 1);
' 2>/dev/null; then
  check "H4 the launcher starts claude -p with stream-json, --verbose, user settings only, a strict MCP config, the slot options and /zensu:work <id>" PASS
else
  check "H4 the launcher builds the claude command line ($(cat "$SBOX/argv.json" 2>/dev/null))" FAIL
fi

BEFORE="$(node -e 'process.stdout.write(String(Date.now()))')"
FAKE_CLAUDE_MODE=ratelimit launch "$SBOX/rate.out"
RC=$?
if [ "$RC" -eq 0 ] && BEFORE="$BEFORE" json_lines_ok "$SBOX/rate.out" \
    'lines.length === 3 && lines[1].event === "rate_limited" && Date.parse(lines[1].reset_at) >= Number(process.env.BEFORE) + 59000 && Date.parse(lines[1].reset_at) <= Date.now() + 61000'; then
  check "H5 a rate-limit retry becomes one rate_limited line with its reset time" PASS
else
  check "H5 a rate-limit retry becomes a rate_limited line (rc=$RC out=$(cat "$SBOX/rate.out"))" FAIL
fi

FAKE_CLAUDE_MODE=failure launch "$SBOX/failure.out"
RC=$?
if [ "$RC" -eq 1 ] && json_lines_ok "$SBOX/failure.out" \
    'lines[lines.length - 1].event === "exited" && lines[lines.length - 1].status === "failure" && lines[lines.length - 1].exit_code === 1'; then
  check "H6 a failed session ends with exited failure and a non-zero exit" PASS
else
  check "H6 a failed session ends with exited failure (rc=$RC out=$(cat "$SBOX/failure.out"))" FAIL
fi

FAKE_CLAUDE_MODE=hang FAKE_CLAUDE_PID="$SBOX/hang.pid" node "$LAUNCHER" --order "$ORDER" --session-id "$SID" --project "$PROJECT" \
  --claude "$FAKE_CLAUDE" >"$SBOX/hang.out" 2>"$SBOX/hang.err" &
LAUNCHER_PID=$!
for _ in $(seq 1 100); do
  grep -q session_started "$SBOX/hang.out" 2>/dev/null && break
  sleep 0.05
done
kill -TERM "$LAUNCHER_PID" 2>/dev/null
reap "$LAUNCHER_PID" "$SBOX/hang.pid"; RC=$?
HANG_PID="$(cat "$SBOX/hang.pid" 2>/dev/null)"
if [ "$RC" -eq 143 ] && json_lines_ok "$SBOX/hang.out" \
    'lines.length === 2 && lines[1].event === "exited" && lines[1].status === "cancelled"' \
  && [ -n "$HANG_PID" ] && ! kill -0 "$HANG_PID" 2>/dev/null; then
  check "H7 SIGTERM stops the session's process group and ends with exited cancelled" PASS
else
  check "H7 SIGTERM ends with exited cancelled (rc=$RC out=$(cat "$SBOX/hang.out") pid=$HANG_PID)" FAIL
fi

node "$LAUNCHER" --session-id "$SID" --project "$PROJECT" --claude "$FAKE_CLAUDE" >"$SBOX/usage.out" 2>/dev/null; RC=$?
env -u ZENSU_SESSION_TOKEN node "$LAUNCHER" --order "$ORDER" --session-id "$SID" --project "$PROJECT" --claude "$FAKE_CLAUDE" >"$SBOX/notoken.out" 2>/dev/null; RC2=$?
[ "$RC" -eq 2 ] && [ ! -s "$SBOX/usage.out" ] && [ "$RC2" -eq 2 ] && [ ! -s "$SBOX/notoken.out" ] \
  && check "H8 a usage error and a missing session token exit 2 and print nothing on stdout" PASS \
  || check "H8 usage errors exit 2 silently (rc=$RC rc2=$RC2)" FAIL

KEY="$(RUNTIME="$RUNTIME" SID="$SID" node -e 'process.stdout.write(require(process.env.RUNTIME).sessionKeyOf(process.env.SID) || "")')"
LEASE_FILE="$PROJECT/.zensu/state/work-order/lease-${KEY#scv1_}.json"
wo_fake_seed "$FAKE_ZENSU_STATE" "$ORDER" "$SID" auto implement
(cd "$PLUGIN_DIR/hooks/lib" && WO_PROJECT_ROOT="$PROJECT" WO_SESSION_KEY="$KEY" node ./work-order-v1.js start --order "$ORDER" >/dev/null 2>&1)
backdate_lease() {
  LEASE_FILE="$LEASE_FILE" AGE_MS="$1" node -e '
    const fs = require("fs");
    const lease = JSON.parse(fs.readFileSync(process.env.LEASE_FILE, "utf8"));
    lease.lastSuccessAt = Date.now() - Number(process.env.AGE_MS);
    fs.writeFileSync(process.env.LEASE_FILE + ".tmp", JSON.stringify(lease));
    fs.renameSync(process.env.LEASE_FILE + ".tmp", process.env.LEASE_FILE);
  '
}
heartbeats() { wo_calls_matching "$FAKE_ZENSU_CALLS" '^work heartbeat'; }

if [ -f "$LEASE_FILE" ]; then
  : > "$FAKE_ZENSU_CALLS"
  FAKE_CLAUDE_MODE=linger FAKE_CLAUDE_MS=1200 launch "$SBOX/fresh.out"
  FRESH_BEATS="$(heartbeats)"
  backdate_lease 700000
  : > "$FAKE_ZENSU_CALLS"
  FAKE_CLAUDE_MODE=linger FAKE_CLAUDE_MS=1200 launch "$SBOX/due.out"; RC=$?
  DUE_BEATS="$(heartbeats)"
  AGE="$(LEASE_FILE="$LEASE_FILE" node -e 'process.stdout.write(String(Date.now() - JSON.parse(require("fs").readFileSync(process.env.LEASE_FILE, "utf8")).lastSuccessAt))')"
  if [ "$FRESH_BEATS" = "0" ] && [ "$RC" -eq 0 ] && [ "$DUE_BEATS" -ge 1 ] && [ "$AGE" -lt 60000 ]; then
    check "H9 the watchdog renews once no renewal succeeded for a third of the lease, and leaves a fresh lease alone" PASS
  else
    check "H9 the watchdog renews after a third of the lease (fresh=$FRESH_BEATS due=$DUE_BEATS rc=$RC age=$AGE)" FAIL
  fi
else
  check "H9 the work-order session state is prepared (no lease file)" FAIL
fi

RUN="run_launch_0001"
(
  cd "$PROJECT" || exit 1
  source "$STATE_LIB" || exit 1
  autopilot_begin_run "$RUN" "$KEY" "$PROJECT" false false "" \
    "{\"orderId\":\"$ORDER\",\"attempt\":1,\"specHash\":\"$(printf 'a%.0s' $(seq 1 64))\"}" >/dev/null 2>&1
) || check "H10 an Autopilot run of the current attempt is planted" FAIL
RUN_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN}.json"
FAKE_CLAUDE_MODE=success launch "$SBOX/release.out"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(`${r.stage}:${r.events[r.events.length - 1].eventId}`)' "$RUN_FILE" 2>/dev/null)" = "CANCELLED:work-order-release-2" ]; then
  check "H10 the launcher releases the session's nonterminal Autopilot run after the session exits" PASS
else
  check "H10 the launcher releases the nonterminal run on exit (rc=$RC stage=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).stage)' "$RUN_FILE" 2>/dev/null))" FAIL
fi

LOST_FILE="$PROJECT/.zensu/state/work-order/lost-${KEY#scv1_}.json"
wo_fake_set "$FAKE_ZENSU_STATE" 'state.staleAttempt = true'
backdate_lease 700000
FAKE_CLAUDE_MODE=hang FAKE_CLAUDE_PID="$SBOX/lost.pid" node "$LAUNCHER" --order "$ORDER" --session-id "$SID" \
  --project "$PROJECT" --claude "$FAKE_CLAUDE" >"$SBOX/lost.out" 2>"$SBOX/lost.out.err" &
reap "$!" "$SBOX/lost.pid"; RC=$?
LOST_PID="$(cat "$SBOX/lost.pid" 2>/dev/null)"
if [ "$RC" -eq 1 ] && json_lines_ok "$SBOX/lost.out" \
    'lines[lines.length - 1].event === "exited" && lines[lines.length - 1].status === "failure" && lines[lines.length - 1].reason === "lease_lost"' \
  && [ -f "$LOST_FILE" ] && [ -n "$LOST_PID" ] && ! kill -0 "$LOST_PID" 2>/dev/null; then
  check "H11 a stale attempt on the watchdog renewal writes the lease-lost marker and terminates the session" PASS
else
  check "H11 a lost lease terminates the session (rc=$RC out=$(cat "$SBOX/lost.out") lost=$([ -f "$LOST_FILE" ] && echo yes))" FAIL
fi

SUPERVISOR_TEST="$PLUGIN_DIR/tests/structure/process-supervisor.test.js"
LOOPBACK_AVAILABLE=0
if node -e '
  const net = require("node:net");
  const server = net.createServer();
  server.once("error", () => process.exit(1));
  server.listen(0, "127.0.0.1", () => server.close(() => process.exit(0)));
' >/dev/null 2>&1; then
  LOOPBACK_AVAILABLE=1
fi
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  if unit_not_run "$SUPERVISOR_TEST" "the managed host forbids loopback listeners"; then
    check "H12 process-supervisor unit file skipped because the managed host forbids loopback listeners" PASS
  else
    check "H12 process-supervisor unit file: $UNIT_RUN_VERDICT" FAIL
  fi
else
  unit_check "H12 the process supervisor the launcher loads authenticates status/stop and terminates its child group" "$SUPERVISOR_TEST"
fi
unit_check_done "H12a every unit file the registry gives this suite was graded"

finish
