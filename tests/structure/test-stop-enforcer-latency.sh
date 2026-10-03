#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PROBE="$PLUGIN_DIR/hooks/lib/stop-idle-probe-v1.js"
DEADLINE_LIB="$PLUGIN_DIR/hooks/lib/zensu-stop-deadline.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
SESSION_LIB="$PLUGIN_DIR/hooks/lib/zensu-session.sh"
REAL_NODE="$(command -v node)"
IDLE_SPAWN_BUDGET=4
ARMED_SPAWN_BUDGET=60

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

for f in "$STOP" "$LOG" "$PROBE" "$DEADLINE_LIB" "$HOOKS_JSON" "$SESSION_LIB"; do
  if [ ! -f "$f" ]; then
    check "L0 required file exists: $f" FAIL
    echo "----"
    echo "test-stop-enforcer-latency: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
[ -n "$REAL_NODE" ] || { echo "node is required"; exit 1; }

EXPECTED_DEFAULT="$( ( source "$DEADLINE_LIB"; printf '%s' "$ZENSU_STOP_DEADLINE_DEFAULT_SECONDS" ) )"
EXPECTED_MIN="$( ( source "$DEADLINE_LIB"; printf '%s' "$ZENSU_STOP_DEADLINE_MIN_SECONDS" ) )"
EXPECTED_MAX="$( ( source "$DEADLINE_LIB"; printf '%s' "$ZENSU_STOP_DEADLINE_MAX_SECONDS" ) )"
FULL_PATH_DEADLINE="ZENSU_STOP_DEADLINE_SECONDS=$EXPECTED_MAX"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
export ZENSU_CONFIG="$WORK/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_AUTOPILOT CLAUDE_SESSION_ID ZENSU_STOP_DEADLINE_SECONDS 2>/dev/null || true

mkdir -p "$WORK/count-shim" "$WORK/hang-shim"
cat >"$WORK/count-shim/node" <<EOF
#!/bin/bash
kind=x
case "\$*" in
  (*'core.readContext({ recordsDir, sessionId: key })'*) kind=root ;;
  (*'session-control-core-v1.js session-key '*) kind=key ;;
esac
printf '%s\n' "\$kind" >>"\${ZENSU_TEST_NODE_COUNT:-/dev/null}"
if [ "\$kind" = root ] && [ -n "\${ZENSU_TEST_AFTER_ROOT:-}" ]; then
  "$REAL_NODE" "\$@"
  rc=\$?
  bash "\$ZENSU_TEST_AFTER_ROOT"
  exit "\$rc"
fi
exec "$REAL_NODE" "\$@"
EOF
cat >"$WORK/hang-shim/node" <<'EOF'
#!/bin/bash
printf '%s\n' "$$" >>"${ZENSU_TEST_HANG_PIDS:-/dev/null}"
exec sleep 600
EOF
chmod +x "$WORK/count-shim/node" "$WORK/hang-shim/node"

decision() {
  "$REAL_NODE" -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'
}

new_session() {
  local name="$1"
  export CLAUDE_PROJECT_DIR="${2:-$WORK/proj-$name}"
  mkdir -p "$CLAUDE_PROJECT_DIR"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/data-$name"
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$name" || return 1
  STATE_DIR="$CLAUDE_PROJECT_DIR/.zensu/state"
  DOC="$STATE_DIR/tdd-phase-${ZENSU_SESSION_KEY}.json"
  [ -f "$DOC" ]
}

stop_run() {
  local sid="$1"
  shift
  : >"$WORK/count"
  printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$sid" "$CLAUDE_PROJECT_DIR" \
    | env "$@" ZENSU_TEST_NODE_COUNT="$WORK/count" PATH="$WORK/count-shim:$PATH" \
      bash "$STOP" >"$WORK/out" 2>"$WORK/err"
  STOP_RC=$?
  STOP_OUT="$(cat "$WORK/out")"
  STOP_ERR="$(cat "$WORK/err")"
  NODE_COUNT="$(wc -l <"$WORK/count" | tr -d ' ')"
  ROOT_COUNT="$(grep -c '^root$' "$WORK/count")"
  KEY_COUNT="$(grep -c '^key$' "$WORK/count")"
  STOP_DECISION="$(printf '%s' "$STOP_OUT" | decision)"
  STOP_NOTE=""
  if printf '%s' "$STOP_ERR" | grep -q 'did not finish within'; then
    STOP_NOTE=" [the Stop deadline was reached: the machine is too loaded for this check]"
  fi
}

edit_doc() {
  DOC_FILE="$DOC" "$REAL_NODE" -e '
    const fs = require("node:fs");
    const state = JSON.parse(fs.readFileSync(process.env.DOC_FILE, "utf8"));
    Object.assign(state, JSON.parse(process.argv[1]));
    fs.writeFileSync(process.env.DOC_FILE, JSON.stringify(state) + "\n");
  ' "$1"
}

probe() {
  ZENSU_IDLE_PROJECT_ROOT="${2:-$ZENSU_PROJECT_ROOT}" ZENSU_IDLE_SESSION_KEY="${1:-$ZENSU_SESSION_KEY}" \
    "$REAL_NODE" "$PROBE" 2>/dev/null
}

echo "== early exit for a Stop with no armed chain"

new_session lat-idle || check "L1 fixture: idle session baseline" FAIL
stop_run lat-idle
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_OUT" ] && [ -z "$STOP_ERR" ] && [ "$NODE_COUNT" -ge 1 ] \
    && [ "$NODE_COUNT" -le "$IDLE_SPAWN_BUDGET" ]; then
  check "L1 idle session releases silently through the early exit within $IDLE_SPAWN_BUDGET node spawns (spawned $NODE_COUNT)" PASS
else
  check "L1 idle session early exit (rc=$STOP_RC spawns=$NODE_COUNT out=$STOP_OUT err=$STOP_ERR)$STOP_NOTE" FAIL
fi
IDLE_COUNT="$NODE_COUNT"

stop_run lat-no-record "$FULL_PATH_DEADLINE"
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_OUT" ]; then
  check "L1b a Stop whose session id has no record still releases" PASS
else
  check "L1b unregistered session release (rc=$STOP_RC out=$STOP_OUT)$STOP_NOTE" FAIL
fi

printf '{"hook_event_name":"Stop","session_id":"lat-idle","agent_id":"sub-1"}' \
  | ZENSU_TEST_NODE_COUNT="$WORK/count-agent" PATH="$WORK/count-shim:$PATH" bash "$STOP" >"$WORK/out" 2>/dev/null
AGENT_RC=$?
AGENT_COUNT="$(wc -l <"$WORK/count-agent" 2>/dev/null | tr -d ' ')"
if [ "$AGENT_RC" -eq 0 ] && [ ! -s "$WORK/out" ] && [ "${AGENT_COUNT:-0}" -le 1 ]; then
  check "L2 a spawned agent's Stop still exits after the principal check alone (spawned ${AGENT_COUNT:-0})" PASS
else
  check "L2 spawned agent Stop (rc=$AGENT_RC spawns=${AGENT_COUNT:-0})" FAIL
fi

edit_doc '{"bypasses":["ZENSU_CHAIN"]}'
stop_run lat-idle
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_OUT" ] && [ "$NODE_COUNT" -le $((IDLE_SPAWN_BUDGET + 1)) ] \
    && ! printf '%s' "$STOP_ERR" | grep -q 'Gates bypassed during this session'; then
  check "L3 idle session with recorded bypasses still takes the early exit while the chain enforcer is enabled (spawned $NODE_COUNT)" PASS
else
  check "L3 idle with bypasses, enforcer on (rc=$STOP_RC spawns=$NODE_COUNT err=$STOP_ERR)$STOP_NOTE" FAIL
fi

printf '{"hooks":{"chainEnforcer":false}}\n' >"$WORK/enforcer-off.json"
stop_run lat-idle ZENSU_CONFIG="$WORK/enforcer-off.json" "$FULL_PATH_DEADLINE"
if [ "$STOP_RC" -eq 0 ] && [ "$STOP_DECISION" = "allow" ] \
    && printf '%s' "$STOP_ERR" | grep -q 'Gates bypassed during this session: ZENSU_CHAIN'; then
  check "L4 with hooks.chainEnforcer=false the full path still renders the recorded bypasses" PASS
else
  check "L4 bypass rendering with enforcer off (rc=$STOP_RC err=$STOP_ERR)$STOP_NOTE" FAIL
fi
edit_doc '{"bypasses":[]}'

stop_run lat-idle ZENSU_CHAIN=off "$FULL_PATH_DEADLINE"
if [ "$STOP_RC" -eq 0 ] && [ "$STOP_DECISION" = "allow" ] && [ "$NODE_COUNT" -gt "$IDLE_SPAWN_BUDGET" ] \
    && [ -z "$STOP_NOTE" ]; then
  check "L5 ZENSU_CHAIN=off skips the early exit and keeps its full-path handling (spawned $NODE_COUNT)" PASS
else
  check "L5 ZENSU_CHAIN=off path (rc=$STOP_RC spawns=$NODE_COUNT)$STOP_NOTE" FAIL
fi
if [ "$ROOT_COUNT" -eq 1 ] && [ "$KEY_COUNT" -eq 0 ] && [ -z "$STOP_NOTE" ]; then
  check "L5b the ZENSU_CHAIN=off path verifies the project root once and spawns nothing to resolve its session key" PASS
else
  check "L5b ZENSU_CHAIN=off resolver spawns (root verifications=$ROOT_COUNT session-key spawns=$KEY_COUNT)$STOP_NOTE" FAIL
fi

echo "== every state with something to enforce still reaches the full path"

new_session lat-pending || check "L6 fixture: pending session baseline" FAIL
bash "$LOG" --pending-review --files "x.ts" >/dev/null 2>&1
if [ -f "$STATE_DIR/pending-review.json" ]; then
  stop_run lat-pending "$FULL_PATH_DEADLINE"
  if [ "$STOP_DECISION" = "block" ] && [ ! -f "$STATE_DIR/pending-review.json" ] \
      && [ "$NODE_COUNT" -gt "$IDLE_SPAWN_BUDGET" ]; then
    check "L6 a queued deferred review is adopted and blocks, as before (spawned $NODE_COUNT)" PASS
  else
    check "L6 pending review adoption (decision=$STOP_DECISION spawns=$NODE_COUNT marker=$([ -f "$STATE_DIR/pending-review.json" ] && echo kept || echo gone))$STOP_NOTE" FAIL
  fi
  if [ "$ROOT_COUNT" -eq 1 ] && [ "$KEY_COUNT" -eq 0 ] && [ -z "$STOP_NOTE" ]; then
    check "L6b the deferred-review adoption path verifies the project root once and spawns nothing to resolve its session key" PASS
  else
    check "L6b adoption path resolver spawns (root verifications=$ROOT_COUNT session-key spawns=$KEY_COUNT)$STOP_NOTE" FAIL
  fi
else
  check "L6 fixture: pending-review marker was written" FAIL
fi

new_session lat-armed || check "L7 fixture: armed session baseline" FAIL
bash "$LOG" --tdd-begin --session lat-armed >/dev/null 2>&1
bash "$LOG" --tdd-complete --session lat-armed >/dev/null 2>&1
stop_run lat-armed "$FULL_PATH_DEADLINE"
if [ "$STOP_DECISION" = "block" ] && [ "$NODE_COUNT" -gt "$IDLE_SPAWN_BUDGET" ]; then
  check "L7 an armed chain with implementation complete still blocks" PASS
else
  check "L7 armed chain block (decision=$STOP_DECISION spawns=$NODE_COUNT err=$STOP_ERR)$STOP_NOTE" FAIL
fi

edit_doc '{"chainDone":true}'
stop_run lat-armed
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_OUT" ] && [ "$NODE_COUNT" -le "$IDLE_SPAWN_BUDGET" ]; then
  check "L8 a chain already marked done takes the early exit (spawned $NODE_COUNT)" PASS
else
  check "L8 done chain early exit (rc=$STOP_RC spawns=$NODE_COUNT out=$STOP_OUT)$STOP_NOTE" FAIL
fi

new_session lat-impl || check "L9 fixture: implementing session baseline" FAIL
bash "$LOG" --tdd-begin --session lat-impl >/dev/null 2>&1
stop_run lat-impl "$FULL_PATH_DEADLINE"
if [ "$STOP_RC" -eq 0 ] && [ "$STOP_DECISION" = "allow" ] && [ "$NODE_COUNT" -gt "$IDLE_SPAWN_BUDGET" ] \
    && [ -z "$STOP_NOTE" ]; then
  check "L9 a chain still implementing is released by the full path, not the early exit (spawned $NODE_COUNT)" PASS
else
  check "L9 implementing chain (rc=$STOP_RC decision=$STOP_DECISION spawns=$NODE_COUNT)$STOP_NOTE" FAIL
fi
if [ "$ROOT_COUNT" -eq 1 ] && [ "$KEY_COUNT" -eq 0 ] && [ -z "$STOP_NOTE" ]; then
  check "L9b the implementing path verifies the project root once and spawns nothing to resolve its session key" PASS
else
  check "L9b implementing path resolver spawns (root verifications=$ROOT_COUNT session-key spawns=$KEY_COUNT)$STOP_NOTE" FAIL
fi

new_session lat-missing || check "L10 fixture: missing-baseline session" FAIL
rm -f "$DOC"
stop_run lat-missing "$FULL_PATH_DEADLINE"
if [ "$STOP_DECISION" = "block" ] && printf '%s' "$STOP_OUT" | grep -q 'baseline is missing'; then
  check "L10 a missing workflow baseline still blocks instead of taking the early exit" PASS
else
  check "L10 missing baseline block (decision=$STOP_DECISION out=$STOP_OUT)$STOP_NOTE" FAIL
fi

new_session lat-corrupt || check "L11 fixture: corrupt session" FAIL
edit_doc '{"active":"yes"}'
stop_run lat-corrupt "$FULL_PATH_DEADLINE"
if [ "$STOP_DECISION" = "block" ] && printf '%s' "$STOP_OUT" | grep -q 'corrupt or unsafe'; then
  check "L11 a workflow document the snapshot rejects still blocks as corrupt" PASS
else
  check "L11 corrupt document block (decision=$STOP_DECISION out=$STOP_OUT)$STOP_NOTE" FAIL
fi

new_session lat-note || check "L12 fixture: refusal-note session" FAIL
NOTE="$STATE_DIR/reviewer-spawn-denied-${ZENSU_SESSION_KEY}.json"
printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":1}\n' >"$NOTE"
stop_run lat-note "$FULL_PATH_DEADLINE"
if [ "$STOP_RC" -eq 0 ] && [ "$STOP_DECISION" = "allow" ] && [ ! -e "$NOTE" ] \
    && [ "$NODE_COUNT" -gt "$IDLE_SPAWN_BUDGET" ]; then
  check "L12 a refusal note sends the Stop through the full path, which retires it" PASS
else
  check "L12 refusal note retired (rc=$STOP_RC spawns=$NODE_COUNT note=$([ -e "$NOTE" ] && echo kept || echo gone))$STOP_NOTE" FAIL
fi

new_session lat-unsafe || check "L13 fixture: unsafe-storage session" FAIL
ln -s "$WORK/elsewhere" "$STATE_DIR/autopilot"
stop_run lat-unsafe "$FULL_PATH_DEADLINE"
if [ "$STOP_DECISION" = "block" ] && [ "$NODE_COUNT" -gt "$IDLE_SPAWN_BUDGET" ]; then
  check "L13 unsafe Autopilot storage still blocks instead of taking the early exit" PASS
else
  check "L13 unsafe storage block (decision=$STOP_DECISION spawns=$NODE_COUNT out=$STOP_OUT)$STOP_NOTE" FAIL
fi

echo "== the idle probe's own verdicts"

new_session lat-probe || check "L14 fixture: probe session" FAIL
V="$(probe)"
[ "$V" = "idle" ] && check "L14 probe answers idle for a fresh baseline" PASS \
  || check "L14 probe fresh baseline (got '$V')" FAIL
for entry in pending-review.json pending-review.json.claim pending-review.json.tmp.ab12cd34 \
    autopilot-active.json autopilot-active-owner.json autopilot-run-r1.json \
    reviewer-spawn-denied-scv1_0000000000000000000000000000000000000000000000000000000000000000.json; do
  : >"$STATE_DIR/$entry"
  V="$(probe)"
  rm -f "$STATE_DIR/$entry"
  [ "$V" = "busy" ] && check "L15 probe answers busy while $entry exists" PASS \
    || check "L15 probe with $entry (got '$V')" FAIL
done
mkdir "$STATE_DIR/autopilot.lock"
V="$(probe)"; rmdir "$STATE_DIR/autopilot.lock"
[ "$V" = "busy" ] && check "L16 probe answers busy for a non-file autopilot.lock" PASS \
  || check "L16 probe non-file autopilot.lock (got '$V')" FAIL
: >"$STATE_DIR/autopilot.lockd"
V="$(probe)"; rm -f "$STATE_DIR/autopilot.lockd"
[ "$V" = "busy" ] && check "L16b probe answers busy for a non-directory autopilot.lockd" PASS \
  || check "L16b probe non-directory autopilot.lockd (got '$V')" FAIL
V="$(probe scv1_1111111111111111111111111111111111111111111111111111111111111111)"
[ "$V" = "busy" ] && check "L17 probe answers busy for a session with no workflow document" PASS \
  || check "L17 probe foreign key (got '$V')" FAIL
V="$(probe lat-probe)"
[ "$V" = "busy" ] && check "L17b probe answers busy for a non-canonical session key" PASS \
  || check "L17b probe raw id (got '$V')" FAIL
V="$(probe "" "relative/root")"
[ "$V" = "busy" ] && check "L17c probe answers busy for a relative project root" PASS \
  || check "L17c probe relative root (got '$V')" FAIL
mv "$STATE_DIR" "$STATE_DIR.real"
ln -s "$STATE_DIR.real" "$STATE_DIR"
V="$(probe)"
rm -f "$STATE_DIR"; mv "$STATE_DIR.real" "$STATE_DIR"
[ "$V" = "busy" ] && check "L17d probe answers busy for a symlinked state directory" PASS \
  || check "L17d probe symlinked state dir (got '$V')" FAIL
V="$(probe)"
[ "$V" = "idle" ] && check "L17e probe answers idle again once the fixture is restored (control)" PASS \
  || check "L17e probe restored fixture (got '$V')" FAIL

echo "== the deadline"

resolve_deadline() {
  ( source "$DEADLINE_LIB"; zensu_stop_deadline_seconds )
}
DEADLINE_OK=PASS
for pair in ":$EXPECTED_DEFAULT" "abc:$EXPECTED_DEFAULT" "-5:$EXPECTED_DEFAULT" "3.5:$EXPECTED_DEFAULT" \
    "0:$EXPECTED_MIN" "000:$EXPECTED_MIN" "5:$EXPECTED_MIN" "30:30" "030:30" \
    "999:$EXPECTED_MAX" "99999999999999999999:$EXPECTED_MAX"; do
  raw="${pair%%:*}"; want="${pair#*:}"
  got="$(ZENSU_STOP_DEADLINE_SECONDS="$raw" resolve_deadline)"
  [ "$got" = "$want" ] || { DEADLINE_OK=FAIL; echo "    deadline for '$raw': got '$got', want '$want'"; }
done
check "L18 ZENSU_STOP_DEADLINE_SECONDS resolves to the default, or clamps to [$EXPECTED_MIN, $EXPECTED_MAX]" "$DEADLINE_OK"
if [ "$EXPECTED_MIN" -le "$EXPECTED_DEFAULT" ] && [ "$EXPECTED_DEFAULT" -le "$EXPECTED_MAX" ] \
    && [ "$EXPECTED_DEFAULT" -lt 60 ]; then
  check "L18b the default deadline ($EXPECTED_DEFAULT s) lies inside its bounds and under one minute" PASS
else
  check "L18b default deadline bounds (default=$EXPECTED_DEFAULT min=$EXPECTED_MIN max=$EXPECTED_MAX)" FAIL
fi

HOST_TIMEOUT="$("$REAL_NODE" -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const entry = (h.hooks.Stop || []).flatMap((g) => g.hooks || [])
    .find((x) => /stop-chain-enforcer\.sh/.test(x.command || ""));
  process.stdout.write(entry && Number.isInteger(entry.timeout) ? String(entry.timeout) : "");
' "$HOOKS_JSON")"
if [ -n "$HOST_TIMEOUT" ] && [ "$HOST_TIMEOUT" -ge $((EXPECTED_MAX + 10)) ] && [ "$HOST_TIMEOUT" -le 120 ]; then
  check "L19 the host timeout ($HOST_TIMEOUT s) backs the internal deadline with at least 10 s to spare and stays within two minutes" PASS
else
  check "L19 host timeout in hooks.json (got '${HOST_TIMEOUT:-none}', internal max $EXPECTED_MAX)" FAIL
fi

mkdir -p "$WORK/mark" "$WORK/tmp"
cat >"$WORK/driver.sh" <<'EOF'
#!/bin/bash
set -u
source "$1"
zensu_stop_deadline_seconds() { printf '%s\n' "$DRIVER_DEADLINE"; }
zensu_stop_supervise "$2" "$3"
EOF
cat >"$WORK/worker-hang.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-stop-worker" ] || exit 97
printf '%s\n' "$$" >"$MARK_DIR/worker.pid"
sleep 600 &
printf '%s\n' "$!" >"$MARK_DIR/grandchild.pid"
printf 'partial stderr\n' >&2
sleep 600
EOF
cat >"$WORK/worker-decided.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-stop-worker" ] || exit 97
printf '{"decision":"block","reason":"decided before the deadline"}\n'
sleep 600
EOF
cat >"$WORK/worker-fast.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--zensu-stop-worker" ] || exit 97
cat >"$MARK_DIR/stdin.copy"
printf 'fast stdout'
printf 'fast stderr\n' >&2
exit 2
EOF
alive() { kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null && echo yes || echo no; }
sleepers() { ps -ax -o command= 2>/dev/null | grep -cx "sleep $1"; }
tmp_left() { ls -A "$WORK/tmp" | wc -l | tr -d ' '; }
drive() {
  TMPDIR="$WORK/tmp" DRIVER_DEADLINE="$1" MARK_DIR="$WORK/mark" \
    bash "$WORK/driver.sh" "$DEADLINE_LIB" "$2" "$3"
}

rm -f "$WORK/mark/"*.pid
T0="$(date +%s)"
drive 2 "$WORK/worker-hang.sh" '{"p":1}' >"$WORK/d.out" 2>"$WORK/d.err"
D_RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
if [ "$D_RC" -eq 0 ] && [ ! -s "$WORK/d.out" ] && [ "$ELAPSED" -le 15 ] \
    && grep -q 'releasing Stop' "$WORK/d.err" && grep -q 'partial stderr' "$WORK/d.err"; then
  check "L20 a worker past the deadline is stopped and the Stop is released with a notice (${ELAPSED}s for a 2 s deadline)" PASS
else
  check "L20 deadline release (rc=$D_RC elapsed=${ELAPSED}s err=$(cat "$WORK/d.err"))" FAIL
fi
if [ -s "$WORK/mark/grandchild.pid" ] && [ "$(alive "$WORK/mark/worker.pid")" = no ] \
    && [ "$(alive "$WORK/mark/grandchild.pid")" = no ] && [ "$(tmp_left)" -eq 0 ]; then
  check "L21 the deadline kills the worker's whole process group and removes its private directory" PASS
else
  check "L21 worker group killed (worker=$(alive "$WORK/mark/worker.pid") grandchild=$(alive "$WORK/mark/grandchild.pid") tmp=$(tmp_left))" FAIL
fi

drive 2 "$WORK/worker-decided.sh" '{}' >"$WORK/d.out" 2>"$WORK/d.err"
D_RC=$?
if [ "$D_RC" -eq 0 ] && [ "$(decision <"$WORK/d.out")" = "block" ] \
    && grep -q 'already written stands' "$WORK/d.err" && ! grep -q 'releasing Stop' "$WORK/d.err"; then
  check "L22 a decision written before the deadline is kept, and the notice says so" PASS
else
  check "L22 decision kept at deadline (rc=$D_RC out=$(cat "$WORK/d.out") err=$(cat "$WORK/d.err"))" FAIL
fi

PAYLOAD='{"hook_event_name":"Stop","text":"tab	and \"quote\" and trailing spaces  "}'
drive 4271 "$WORK/worker-fast.sh" "$PAYLOAD" >"$WORK/d.out" 2>"$WORK/d.err"
D_RC=$?
if [ "$D_RC" -eq 2 ] && [ "$(cat "$WORK/d.out")" = "fast stdout" ] && [ "$(cat "$WORK/d.err")" = "fast stderr" ] \
    && [ "$(cat "$WORK/mark/stdin.copy")" = "$PAYLOAD" ]; then
  check "L23 a worker that finishes in time has stdin, stdout, stderr and its exit code passed through unchanged" PASS
else
  check "L23 pass-through (rc=$D_RC out=$(cat "$WORK/d.out") err=$(cat "$WORK/d.err"))" FAIL
fi
sleep 1
if [ "$(sleepers 4271)" -eq 0 ] && [ "$(tmp_left)" -eq 0 ]; then
  check "L24 a worker that finishes in time leaves no watchdog and no private directory behind" PASS
else
  check "L24 leftovers after an in-time worker (watchdog sleepers=$(sleepers 4271) tmp=$(tmp_left))" FAIL
fi

wait_for_file() {
  local tries=0
  while [ ! -s "$1" ] && [ "$tries" -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
  [ -s "$1" ]
}

rm -f "$WORK/mark/"*.pid
T0="$(date +%s)"
TMPDIR="$WORK/tmp" DRIVER_DEADLINE=8 MARK_DIR="$WORK/mark" \
  bash "$WORK/driver.sh" "$DEADLINE_LIB" "$WORK/worker-hang.sh" '{}' >/dev/null 2>&1 &
DRIVER_PID=$!
wait_for_file "$WORK/mark/grandchild.pid"
kill -KILL "$DRIVER_PID" 2>/dev/null
wait "$DRIVER_PID" 2>/dev/null
SUPERVISOR_GONE=no
kill -0 "$DRIVER_PID" 2>/dev/null || SUPERVISOR_GONE=yes
BEFORE="$(alive "$WORK/mark/worker.pid")"
while [ $(( $(date +%s) - T0 )) -lt 11 ]; do sleep 1; done
if [ "$SUPERVISOR_GONE" = yes ] && [ "$BEFORE" = yes ] && [ "$(alive "$WORK/mark/worker.pid")" = no ] \
    && [ "$(alive "$WORK/mark/grandchild.pid")" = no ] && [ "$(tmp_left)" -eq 0 ]; then
  check "L25 a supervisor killed by SIGKILL still has its worker killed at the deadline, by the watchdog it left behind" PASS
else
  check "L25 orphaned worker bound (supervisor gone=$SUPERVISOR_GONE worker before=$BEFORE after=$(alive "$WORK/mark/worker.pid") grandchild=$(alive "$WORK/mark/grandchild.pid") tmp=$(tmp_left))" FAIL
fi

rm -f "$WORK/mark/"*.pid
TMPDIR="$WORK/tmp" DRIVER_DEADLINE=37 MARK_DIR="$WORK/mark" \
  bash "$WORK/driver.sh" "$DEADLINE_LIB" "$WORK/worker-hang.sh" '{}' >/dev/null 2>&1 &
DRIVER_PID=$!
wait_for_file "$WORK/mark/grandchild.pid"
kill -TERM "$DRIVER_PID" 2>/dev/null
wait "$DRIVER_PID"
T_RC=$?
sleep 1
if [ "$T_RC" -eq 143 ] && [ "$(alive "$WORK/mark/worker.pid")" = no ] \
    && [ "$(alive "$WORK/mark/grandchild.pid")" = no ] && [ "$(sleepers 37)" -eq 0 ] && [ "$(tmp_left)" -eq 0 ]; then
  check "L26 SIGTERM to the supervisor kills the worker group and the watchdog at once and exits 143" PASS
else
  check "L26 SIGTERM handling (rc=$T_RC worker=$(alive "$WORK/mark/worker.pid") grandchild=$(alive "$WORK/mark/grandchild.pid") watchdog sleepers=$(sleepers 37) tmp=$(tmp_left))" FAIL
fi

new_session lat-hang || check "L27 fixture: hang session" FAIL
: >"$WORK/hang-pids"
T0="$(date +%s)"
printf '{"hook_event_name":"Stop","session_id":"lat-hang","cwd":"%s"}' "$CLAUDE_PROJECT_DIR" \
  | ZENSU_STOP_DEADLINE_SECONDS="$EXPECTED_MIN" ZENSU_TEST_HANG_PIDS="$WORK/hang-pids" \
    PATH="$WORK/hang-shim:$PATH" bash "$STOP" >"$WORK/out" 2>"$WORK/err"
H_RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
if [ "$H_RC" -eq 0 ] && [ ! -s "$WORK/out" ] && [ "$ELAPSED" -ge "$EXPECTED_MIN" ] \
    && [ "$ELAPSED" -le $((EXPECTED_MIN + 15)) ] && grep -q 'releasing Stop' "$WORK/err"; then
  check "L27 the real Stop hook with a hung child is released at its ${EXPECTED_MIN} s deadline (took ${ELAPSED}s)" PASS
else
  check "L27 real hook deadline (rc=$H_RC elapsed=${ELAPSED}s err=$(cat "$WORK/err"))" FAIL
fi
HUNG_ALIVE=0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  if kill -0 "$pid" 2>/dev/null; then HUNG_ALIVE=$((HUNG_ALIVE + 1)); kill -KILL "$pid" 2>/dev/null; fi
done <"$WORK/hang-pids"
if [ -s "$WORK/hang-pids" ] && [ "$HUNG_ALIVE" -eq 0 ]; then
  check "L28 no hung child of the real hook survives the deadline" PASS
else
  check "L28 hung children still alive: $HUNG_ALIVE (recorded: $(wc -l <"$WORK/hang-pids" | tr -d ' '))" FAIL
fi

echo "== one project-root verification per Stop run"

new_session lat-budget || check "L29 fixture: budget session baseline" FAIL
bash "$LOG" --tdd-begin --session lat-budget >/dev/null 2>&1
bash "$LOG" --tdd-complete --session lat-budget >/dev/null 2>&1
stop_run lat-budget "$FULL_PATH_DEADLINE"
if [ "$STOP_DECISION" = "block" ] && [ "$ROOT_COUNT" -eq 1 ] && [ "$KEY_COUNT" -eq 0 ] && [ -z "$STOP_NOTE" ]; then
  check "L29 an armed Stop verifies the project root against the session record once and spawns nothing to resolve its session key" PASS
else
  check "L29 armed Stop resolver spawns (decision=$STOP_DECISION root verifications=$ROOT_COUNT session-key spawns=$KEY_COUNT)$STOP_NOTE" FAIL
fi
if [ "$STOP_DECISION" = "block" ] && [ "$NODE_COUNT" -le "$ARMED_SPAWN_BUDGET" ] && [ -z "$STOP_NOTE" ]; then
  check "L30 an armed Stop stays within $ARMED_SPAWN_BUDGET node spawns (spawned $NODE_COUNT)" PASS
else
  check "L30 armed Stop spawn budget (decision=$STOP_DECISION spawns=$NODE_COUNT budget=$ARMED_SPAWN_BUDGET)$STOP_NOTE" FAIL
fi
ARMED_COUNT="$NODE_COUNT"

cat >"$WORK/link-lib.sh" <<EOF
make_directory_symlink() {
  "$REAL_NODE" -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"junction":"dir");
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "\$1" "\$2"
}
make_file_symlink() {
  "$REAL_NODE" -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "\$1" "\$2"
}
EOF
source "$WORK/link-lib.sh"

cat >"$WORK/memo-driver.sh" <<'EOF'
#!/bin/bash
set -u
source "$MEMO_SESSION_LIB"
source "$MEMO_LINK_LIB"
case "${1:-}" in
  (plain)
    zensu_resolve_project_dir && zensu_resolve_project_dir
    ;;
  (memo)
    zensu_memoize_project_dir || exit 9
    first="$(zensu_resolve_project_dir)" || exit 8
    second="$(zensu_resolve_project_dir)" || exit 8
    [ "$first" = "$second" ] || exit 8
    printf '%s\n' "$second"
    ;;
  (rekey)
    zensu_memoize_project_dir || exit 9
    ZENSU_PROJECT_ROOT="$MEMO_OTHER_ROOT"
    zensu_resolve_project_dir
    ;;
  (child)
    zensu_memoize_project_dir || exit 9
    bash "$0" plain
    ;;
  (rebind)
    zensu_memoize_project_dir || exit 9
    zensu_bind_model_session || exit 7
    zensu_resolve_project_dir
    ;;
  (swap-ancestor)
    zensu_memoize_project_dir || exit 9
    mv "$MEMO_SWAP_PARENT" "$MEMO_SWAP_PARENT.real" || exit 6
    make_directory_symlink "$MEMO_SWAP_PARENT.real" "$MEMO_SWAP_PARENT" || exit 5
    zensu_resolve_project_dir
    ;;
  (remove)
    zensu_memoize_project_dir || exit 9
    mv "$ZENSU_PROJECT_ROOT" "$ZENSU_PROJECT_ROOT.moved" || exit 6
    zensu_resolve_project_dir
    ;;
  (set-input)
    zensu_memoize_project_dir || exit 9
    printf -v "$MEMO_SET_NAME" '%s' "$MEMO_SET_VALUE"
    zensu_resolve_project_dir
    ;;
  (record-gone)
    zensu_memoize_project_dir || exit 9
    mv "$ZENSU_SESSION_CONTEXT" "$ZENSU_SESSION_CONTEXT.moved" || exit 6
    zensu_resolve_project_dir
    ;;
  (record-link)
    zensu_memoize_project_dir || exit 9
    mv "$ZENSU_SESSION_CONTEXT" "$ZENSU_SESSION_CONTEXT.moved" || exit 6
    make_file_symlink "$ZENSU_SESSION_CONTEXT.moved" "$ZENSU_SESSION_CONTEXT" || exit 5
    zensu_resolve_project_dir
    ;;
  (hook-rebind)
    zensu_memoize_project_dir || exit 9
    zensu_bind_hook_session "$MEMO_HOOK_PAYLOAD" || exit 7
    zensu_resolve_project_dir
    ;;
  (gap-swap)
    if zensu_memoize_project_dir; then echo kept; else echo refused; fi
    zensu_resolve_project_dir
    ;;
  (key)
    zensu_resolve_session_id "$MEMO_KEY_ARG"
    ;;
  (*) exit 64 ;;
esac
EOF

memo_run() {
  local mode="$1"
  shift
  : >"$WORK/count"
  MEMO_OUT="$(env "$@" MEMO_SESSION_LIB="$SESSION_LIB" MEMO_LINK_LIB="$WORK/link-lib.sh" \
    ZENSU_TEST_NODE_COUNT="$WORK/count" PATH="$WORK/count-shim:$PATH" \
    bash "$WORK/memo-driver.sh" "$mode" 2>/dev/null)"
  MEMO_RC=$?
  ROOT_COUNT="$(grep -c '^root$' "$WORK/count")"
  KEY_COUNT="$(grep -c '^key$' "$WORK/count")"
}

new_session lat-memo || check "L31 fixture: memo session baseline" FAIL
MEMO_ROOT="$(cd -P -- "$CLAUDE_PROJECT_DIR" && pwd -P)"
MEMO_KEY="$ZENSU_SESSION_KEY"
MEMO_CONTEXT="$ZENSU_SESSION_CONTEXT"
MEMO_OTHER="$WORK/memo-other-root"
mkdir -p "$MEMO_OTHER"

memo_run plain
if [ "$MEMO_RC" -eq 0 ] && [ "$ROOT_COUNT" -eq 2 ] \
    && [ "$MEMO_OUT" = "$(printf '%s\n%s' "$MEMO_ROOT" "$MEMO_ROOT")" ]; then
  check "L31 without a memo every call verifies the project root against the record (control)" PASS
else
  check "L31 unmemoized resolver (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run memo
if [ "$MEMO_RC" -eq 0 ] && [ "$ROOT_COUNT" -eq 1 ] && [ "$MEMO_OUT" = "$MEMO_ROOT" ]; then
  check "L32 after one verification in the calling shell, later calls and their command substitutions reuse it" PASS
else
  check "L32 memoized resolver (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run plain _ZENSU_PROJECT_DIR_MEMO="$MEMO_OTHER" ZENSU_PROJECT_ROOT="$MEMO_OTHER"
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 1 ]; then
  check "L33 an environment variable named like the memo cannot stand in for it: a foreign root is verified and refused" PASS
else
  check "L33 environment-supplied memo (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run rekey MEMO_OTHER_ROOT="$MEMO_OTHER"
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 2 ]; then
  check "L34 the memo answers only for the binding it verified: a changed project root is verified again and refused" PASS
else
  check "L34 memo under a changed binding (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run child
if [ "$MEMO_RC" -eq 0 ] && [ "$ROOT_COUNT" -eq 3 ]; then
  check "L35 the memo never reaches a child process: a child shell verifies every call itself" PASS
else
  check "L35 memo in a child process (rc=$MEMO_RC verifications=$ROOT_COUNT)" FAIL
fi

memo_run rebind
if [ "$MEMO_RC" -eq 0 ] && [ "$ROOT_COUNT" -eq 2 ] && [ "$MEMO_OUT" = "$MEMO_ROOT" ]; then
  check "L36 binding the session again discards the memo" PASS
else
  check "L36 memo after a second bind (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run remove
mv "$CLAUDE_PROJECT_DIR.moved" "$CLAUDE_PROJECT_DIR" 2>/dev/null
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 1 ]; then
  check "L37 a project root that vanishes after the memo was taken is refused" PASS
else
  check "L37 memo with a vanished root (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run key MEMO_KEY_ARG="$MEMO_KEY"
KEY_BOUND="$MEMO_RC:$MEMO_OUT:$KEY_COUNT"
memo_run key -u ZENSU_SESSION_KEY MEMO_KEY_ARG="$MEMO_KEY"
if [ "$KEY_BOUND" = "0:$MEMO_KEY:0" ] && [ "$MEMO_RC:$MEMO_OUT:$KEY_COUNT" = "0:$MEMO_KEY:0" ]; then
  check "L38 a canonical session key is returned without a node spawn, with or without a bound key" PASS
else
  check "L38 canonical session key (bound=$KEY_BOUND unbound=$MEMO_RC:$MEMO_OUT:$KEY_COUNT)" FAIL
fi

memo_run key MEMO_KEY_ARG="scv1_$(printf '%064d' 0)"
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$KEY_COUNT" -eq 0 ]; then
  check "L39 the canonical key of another session is still refused under a bound key" PASS
else
  check "L39 foreign canonical key (rc=$MEMO_RC out=$MEMO_OUT session-key spawns=$KEY_COUNT)" FAIL
fi

memo_run key MEMO_KEY_ARG="$MEMO_KEY" ZENSU_SESSION_KEY="scv1_short"
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$KEY_COUNT" -eq 1 ]; then
  check "L40 a bound key that is not canonical still refuses every id" PASS
else
  check "L40 non-canonical bound key (rc=$MEMO_RC out=$MEMO_OUT session-key spawns=$KEY_COUNT)" FAIL
fi

memo_run key MEMO_KEY_ARG="lat-memo"
if [ "$MEMO_RC" -eq 0 ] && [ "$MEMO_OUT" = "$MEMO_KEY" ] && [ "$KEY_COUNT" -eq 1 ]; then
  check "L41 a raw session id is still hashed by the core module" PASS
else
  check "L41 raw session id (rc=$MEMO_RC out=$MEMO_OUT session-key spawns=$KEY_COUNT)" FAIL
fi

NEAR_OK=PASS
HEX63="$(printf '%063d' 0)"
for near in "scv1_${HEX63}A" "scv1_${HEX63}" "scv1_${HEX63}00" "scv1_${HEX63}g" "SCV1_${HEX63}0" " scv1_${HEX63}0"; do
  want="$(cd "$PLUGIN_DIR/hooks/lib" && "$REAL_NODE" ./session-control-core-v1.js session-key "$near")"
  memo_run key -u ZENSU_SESSION_KEY MEMO_KEY_ARG="$near"
  if [ "$MEMO_RC" -ne 0 ] || [ -z "$want" ] || [ "$MEMO_OUT" != "$want" ] || [ "$MEMO_OUT" = "$near" ] \
      || [ "$KEY_COUNT" -ne 1 ]; then
    NEAR_OK=FAIL
    echo "    near-canonical '$near': rc=$MEMO_RC out='$MEMO_OUT' want='$want' session-key spawns=$KEY_COUNT"
  fi
done
check "L42 an id that only resembles a canonical key is hashed by the core module, never returned as it is" "$NEAR_OK"

memo_run set-input MEMO_SET_NAME=ZENSU_SESSION_KEY MEMO_SET_VALUE="scv1_$(printf '%064d' 0)"
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 2 ]; then
  check "L44 the memo answers only for the session key it verified: another key is verified again and refused" PASS
else
  check "L44 memo under a changed session key (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

printf '{}\n' >"$WORK/memo-other-context.json"
memo_run set-input MEMO_SET_NAME=ZENSU_SESSION_CONTEXT MEMO_SET_VALUE="$WORK/memo-other-context.json"
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 2 ]; then
  check "L45 the memo answers only for the session record it verified: another record file is verified again and refused" PASS
else
  check "L45 memo under a changed record path (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run set-input MEMO_SET_NAME=ZENSU_PROJECT_ROOT MEMO_SET_VALUE="$WORK/./proj-lat-memo"
if [ "$MEMO_RC" -eq 0 ] && [ "$MEMO_OUT" = "$MEMO_ROOT" ] && [ "$ROOT_COUNT" -eq 2 ]; then
  check "L46 the memo compares the root as it is spelled: another spelling of the same directory is verified again" PASS
else
  check "L46 memo under another root spelling (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run record-gone
mv "$MEMO_CONTEXT.moved" "$MEMO_CONTEXT" 2>/dev/null
if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 1 ]; then
  check "L47 a session record that vanishes after the memo was taken is refused before the memo is consulted" PASS
else
  check "L47 memo with a vanished record (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run record-link
RECORD_LINK_RC="$MEMO_RC"
if [ -L "$MEMO_CONTEXT" ]; then
  rm -f "$MEMO_CONTEXT"
fi
mv "$MEMO_CONTEXT.moved" "$MEMO_CONTEXT" 2>/dev/null
if [ "$RECORD_LINK_RC" -eq 5 ]; then
  check "L48 this host creates no symbolic link, so there is no linked record to refuse" PASS
elif [ "$RECORD_LINK_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 1 ]; then
  check "L48 a session record replaced by a symbolic link after the memo was taken is refused before the memo is consulted" PASS
else
  check "L48 memo with a linked record (rc=$RECORD_LINK_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

memo_run hook-rebind \
  MEMO_HOOK_PAYLOAD="$(printf '{"hook_event_name":"Stop","session_id":"lat-memo","cwd":"%s"}' "$CLAUDE_PROJECT_DIR")"
if [ "$MEMO_RC" -eq 0 ] && [ "$ROOT_COUNT" -eq 2 ] && [ "$MEMO_OUT" = "$MEMO_ROOT" ]; then
  check "L49 binding the session again from a hook payload discards the memo" PASS
else
  check "L49 memo after a hook bind (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

new_session lat-alias "$WORK/alias-target/proj" || check "L50 fixture: alias session baseline" FAIL
if make_directory_symlink "$WORK/alias-target" "$WORK/alias-link"; then
  memo_run set-input MEMO_SET_NAME=ZENSU_PROJECT_ROOT MEMO_SET_VALUE="$WORK/alias-link/proj"
  if [ "$MEMO_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 2 ]; then
    check "L50 the same root spelled through a symlinked ancestor is not answered by the memo: it is verified again and refused" PASS
  else
    check "L50 memo under an aliased root spelling (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
  fi
else
  check "L50 this host creates no symbolic link, so there is no aliased root spelling to refuse" PASS
fi

new_session lat-swap "$WORK/swap-parent/proj" || check "L43 fixture: swap session baseline" FAIL
memo_run swap-ancestor MEMO_SWAP_PARENT="$WORK/swap-parent"
SWAP_RC="$MEMO_RC"
if [ "$SWAP_RC" -eq 5 ]; then
  check "L43 this host creates no symbolic link, so there is no ancestor swap to detect" PASS
elif [ "$SWAP_RC" -ne 0 ] && [ -z "$MEMO_OUT" ] && [ "$ROOT_COUNT" -eq 2 ]; then
  check "L43 a project root that starts resolving through a symlinked ancestor after the memo was taken is verified again and refused" PASS
else
  check "L43 memo after an ancestor swap (rc=$SWAP_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

if [ "$SWAP_RC" -eq 5 ]; then
  check "L51 this host creates no symbolic link, so there is no mismatched root to stop on" PASS
else
  stop_run lat-swap "$FULL_PATH_DEADLINE"
  if [ "$STOP_DECISION" = "block" ] && [ "$ROOT_COUNT" -eq 1 ] && [ -z "$STOP_NOTE" ] \
      && printf '%s' "$STOP_ERR" | grep -q 'exists but does not match'; then
    check "L51 a Stop whose root no longer matches the record takes the failure branch after one verification" PASS
  else
    check "L51 Stop with a mismatched root (decision=$STOP_DECISION verifications=$ROOT_COUNT err=$STOP_ERR)$STOP_NOTE" FAIL
  fi
fi

new_session lat-gap "$WORK/gap-parent/proj" || check "L52 fixture: gap session baseline" FAIL
cat >"$WORK/swap-after-root.sh" <<'EOF'
#!/bin/bash
[ -e "$MEMO_SWAP_PARENT.real" ] && exit 0
[ -d "$MEMO_SWAP_PARENT" ] || exit 0
mv "$MEMO_SWAP_PARENT" "$MEMO_SWAP_PARENT.real" || exit 0
source "$MEMO_LINK_LIB"
make_directory_symlink "$MEMO_SWAP_PARENT.real" "$MEMO_SWAP_PARENT" || : >"$MEMO_SWAP_PARENT.unlinked"
EOF
memo_run gap-swap MEMO_SWAP_PARENT="$WORK/gap-parent" ZENSU_TEST_AFTER_ROOT="$WORK/swap-after-root.sh"
if [ -e "$WORK/gap-parent.unlinked" ]; then
  check "L52 this host creates no symbolic link, so there is no swap inside the memoizing call" PASS
elif [ "$MEMO_RC" -ne 0 ] && [ "$MEMO_OUT" = "refused" ] && [ "$ROOT_COUNT" -eq 2 ]; then
  check "L52 an ancestor swapped between the verification and the render is not memoized, and the root is refused" PASS
else
  check "L52 swap inside the memoizing call (rc=$MEMO_RC verifications=$ROOT_COUNT out=$MEMO_OUT)" FAIL
fi

echo "----"
echo "test-stop-enforcer-latency: $PASS PASS / $FAIL FAIL (idle Stop spawned ${IDLE_COUNT:-?} node processes, armed Stop ${ARMED_COUNT:-?})"
[ "$FAIL" -eq 0 ]
