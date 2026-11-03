#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
REGISTRATION_LIB="$PLUGIN_DIR/hooks/lib/hook-registration-v1.js"
CONFIG_LIB="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}
finish() {
  printf '%s\n' '----' "test-hook-process-budget: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit
}

. "$(dirname "$0")/lib-unit-registry.sh"
unit_check "B9 the dispatcher unit file passes" "$PLUGIN_DIR/tests/structure/hook-dispatch-v1.test.js"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "B0 the process-start budgets are calibrated on POSIX hosts; Git Bash is not measured (skipped)" PASS
    unit_check_done "B9z every unit file the registry gives this suite was graded"
    finish
    ;;
esac

REAL_BASH="$(command -v bash)"
REAL_NODE="$(command -v node)"
command -v node >/dev/null 2>&1 || { check "node is available" FAIL; finish; }
command -v git >/dev/null 2>&1 || { check "git is available" FAIL; finish; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zensu-hook-budget.XXXXXX")" || exit 1
TMP="$(cd -P -- "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

SHIMS="$TMP/shims"
mkdir -p "$SHIMS"
SHIM_COUNT="$(node - "$SHIMS" "$PATH" <<'NODE'
const fs = require('fs');
const path = require('path');
const [dir, searchPath] = process.argv.slice(2);
const seen = new Set();
for (const entry of searchPath.split(path.delimiter)) {
  if (!entry || !path.isAbsolute(entry)) continue;
  let names;
  try { names = fs.readdirSync(entry); } catch (_) { continue; }
  for (const name of names) {
    if (seen.has(name) || !/^[A-Za-z0-9._+-]+$/.test(name)) continue;
    const full = path.join(entry, name);
    if (full.includes("'")) continue;
    try {
      if (!fs.statSync(full).isFile()) continue;
      fs.accessSync(full, fs.constants.X_OK);
    } catch (_) { continue; }
    seen.add(name);
    fs.writeFileSync(path.join(dir, name),
      `#!/bin/sh\nprintf '%s\\n' '${name}' >> "$ZENSU_BUDGET_LOG"\nexec '${full}' "$@"\n`, { mode: 0o755 });
  }
}
process.stdout.write(String(seen.size));
NODE
)"
if [ "${SHIM_COUNT:-0}" -gt 0 ] && [ -x "$SHIMS/node" ] && [ -x "$SHIMS/bash" ] && [ -x "$SHIMS/git" ]; then
  check "B0 every program on PATH ($SHIM_COUNT names) is reachable only through a counting shim" PASS
else
  check "B0 counting shims for PATH programs (got ${SHIM_COUNT:-0})" FAIL
  finish
fi

PROJ="$TMP/project"
HOME_DIR="$TMP/home"
mkdir -p "$PROJ/src" "$HOME_DIR"
printf 'x\n' > "$PROJ/src/app.txt"
git -C "$PROJ" init -q
git -C "$PROJ" -c user.email=budget@example.invalid -c user.name=budget add -A
git -C "$PROJ" -c user.email=budget@example.invalid -c user.name=budget commit -q -m init
SID="hook-budget-$$"
export HOME="$HOME_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data"
unset ZENSU_CONFIG CLAUDE_ENV_FILE ZENSU_TDD_GATE ZENSU_CHAIN ZENSU_SECRET_SCAN ZENSU_MCP_GATE \
  ZENSU_BASH_WRITE_GATE ZENSU_SESSION_TOKEN CLAUDE_AGENT_TYPE NODE_OPTIONS
. "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID" "$PLUGIN_DIR" \
  || { check "B1 an armed session fixture is created" FAIL; finish; }
if bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin >/dev/null 2>&1; then
  check "B1 an armed session fixture is created" PASS
else
  check "B1 an armed session fixture is created" FAIL
  finish
fi

payload() {
  EVENT="$1" TOOL="$2" INPUT="$3" RESPONSE="${4:-}" SID="$SID" PROJ="$PROJ" node -e '
    const o = {
      hook_event_name: process.env.EVENT,
      session_id: process.env.SID,
      transcript_path: "",
      cwd: process.env.PROJ,
      permission_mode: "default",
      tool_name: process.env.TOOL,
      tool_input: JSON.parse(process.env.INPUT)
    };
    if (process.env.RESPONSE) o.tool_response = JSON.parse(process.env.RESPONSE);
    process.stdout.write(JSON.stringify(o));
  '
}

roster() {
  node - "$HOOKS_JSON" "$REGISTRATION_LIB" "$1" "$2" <<'NODE'
const fs = require('fs');
const [manifestFile, registrationFile, event, tool] = process.argv.slice(2);
const { hostMatcherCovers, REGISTRATION, dispatcherEvent } = require(registrationFile);
const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
const out = [];
for (const group of manifest.hooks[event] || []) {
  const covers = hostMatcherCovers(group.matcher, tool);
  if (covers === REGISTRATION.UNKNOWN) { out.push('unknown-matcher'); continue; }
  if (covers !== REGISTRATION.REGISTERED) continue;
  for (const hook of group.hooks || []) {
    const dispatched = dispatcherEvent(hook);
    if (dispatched !== null) {
      out.push(dispatched === event ? 'dispatch:' + (event === 'PreToolUse' ? 'pre' : 'post') : 'dispatch-event-mismatch');
      continue;
    }
    const m = /hooks\/([A-Za-z0-9._-]+\.sh)"?$/.exec(hook.command || '');
    out.push(m ? m[1] : 'unparseable-command');
  }
}
process.stdout.write(out.join('\n'));
NODE
}

count_hook() {
  local hook="$1" body="$2" log="$TMP/count.log"
  : > "$log"
  case "$hook" in
    (dispatch:*) set -- "$REAL_NODE" "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" "${hook#dispatch:}" ;;
    (*) set -- "$REAL_BASH" "$PLUGIN_DIR/hooks/$hook" ;;
  esac
  printf '%s' "$body" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_SESSION_ADOPTED \
    PATH="$SHIMS" ZENSU_BUDGET_LOG="$log" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    "$@" >"$TMP/count.out" 2>/dev/null
  HOOK_RC=$?
  HOOK_STARTS="$(wc -l < "$log" | tr -d ' ')"
  HOOK_NODES="$(grep -cx node "$log")"
  HOOK_PROGRAMS="$(sort "$log" | uniq -c | awk '{printf "%s%s=%s", sep, $2, $1; sep=" "}')"
  HOOK_OUTPUT="$(cat "$TMP/count.out")"
}

BASH_INPUT='{"command":"git status --short","description":"Show the working tree"}'
BASH_RESPONSE='{"stdout":"","stderr":"","interrupted":false,"isImage":false}'
READ_INPUT="$(node -e 'process.stdout.write(JSON.stringify({ file_path: process.argv[1] }))' "$PROJ/src/app.txt")"
READ_RESPONSE='{"type":"text","file":{"content":"x"}}'
EDIT_INPUT="$(node -e 'process.stdout.write(JSON.stringify({ file_path: process.argv[1], old_string: "x", new_string: "y" }))' "$PROJ/src/app.txt")"
EDIT_RESPONSE='{"filePath":"x","oldString":"x","newString":"y"}'
NOTEBOOK_INPUT="$(node -e 'process.stdout.write(JSON.stringify({ notebook_path: process.argv[1], new_source: "y" }))' "$PROJ/src/app.ipynb")"
NOTEBOOK_RESPONSE='{"new_source":"y"}'
AGENT_INPUT='{"subagent_type":"zensu:code-reviewer","description":"review","prompt":"review"}'
AGENT_RESPONSE='{"status":"completed","content":[]}'

budget() {
  case "$1" in
    Bash) echo "2 0 0" ;;
    Read) echo "2 0 0" ;;
    Edit) echo "2 0 0" ;;
    NotebookEdit) echo "2 0 0" ;;
    Agent) echo "3 6 5" ;;
  esac
}

for TOOL in Bash Read Edit NotebookEdit Agent; do
  case "$TOOL" in
    Bash) INPUT="$BASH_INPUT"; RESPONSE="$BASH_RESPONSE" ;;
    Read) INPUT="$READ_INPUT"; RESPONSE="$READ_RESPONSE" ;;
    Edit) INPUT="$EDIT_INPUT"; RESPONSE="$EDIT_RESPONSE" ;;
    NotebookEdit) INPUT="$NOTEBOOK_INPUT"; RESPONSE="$NOTEBOOK_RESPONSE" ;;
    Agent) INPUT="$AGENT_INPUT"; RESPONSE="$AGENT_RESPONSE" ;;
  esac
  TOTAL=0
  NODES=0
  REGISTERED=0
  BAD=""
  for EVENT in PreToolUse PostToolUse; do
    if [ "$EVENT" = PreToolUse ]; then BODY="$(payload "$EVENT" "$TOOL" "$INPUT")"
    else BODY="$(payload "$EVENT" "$TOOL" "$INPUT" "$RESPONSE")"; fi
    for HOOK in $(roster "$EVENT" "$TOOL"); do
      case "$HOOK" in unknown-matcher|unparseable-command) BAD="$BAD $EVENT:$HOOK"; continue ;; esac
      REGISTERED=$((REGISTERED + 1))
      count_hook "$HOOK" "$BODY"
      case "$HOOK_OUTPUT" in *'"permissionDecision":"deny"'*) BAD="$BAD $HOOK:denied" ;; esac
      [ "$HOOK_RC" -eq 0 ] || BAD="$BAD $HOOK:rc=$HOOK_RC"
      printf '        %s %s %s: starts=%s node=%s (%s)\n' "$TOOL" "$EVENT" "$HOOK" "$HOOK_STARTS" "$HOOK_NODES" "$HOOK_PROGRAMS"
      TOTAL=$((TOTAL + HOOK_STARTS))
      NODES=$((NODES + HOOK_NODES))
    done
  done
  if [ -z "$BAD" ]; then
    check "B2-$TOOL every hook registered for a $TOOL call allows it in the armed fixture" PASS
  else
    check "B2-$TOOL a hook registered for a $TOOL call failed or denied:$BAD" FAIL
  fi
  read -r HOOK_LIMIT LIMIT NODE_LIMIT <<EOF
$(budget "$TOOL")
EOF
  if [ "$REGISTERED" -le "$HOOK_LIMIT" ] && [ "$TOTAL" -le "$LIMIT" ] && [ "$NODES" -le "$NODE_LIMIT" ]; then
    check "B3-$TOOL a $TOOL call starts $REGISTERED hook processes (budget $HOOK_LIMIT), which start $TOTAL programs through PATH (budget $LIMIT), $NODES of them node (budget $NODE_LIMIT)" PASS
  else
    check "B3-$TOOL a $TOOL call starts $REGISTERED hook processes (budget $HOOK_LIMIT), $TOTAL programs (budget $LIMIT), $NODES node (budget $NODE_LIMIT)" FAIL
  fi
done

body_and_check() {
  local label="$1" body="$2"
  shift 2
  BODY_OUT="$(printf '%s' "$body" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_SESSION_ADOPTED CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" "$@" \
    "$REAL_BASH" "$PLUGIN_DIR/hooks/checks/pre-edit-tdd-reminder.sh" 2>/dev/null)"
  BODY_RC=$?
  CHECK_OUT="$(printf '%s' "$body" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_SESSION_ADOPTED CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" "$@" \
    "$REAL_NODE" "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" pre --only tdd-edit-gate 2>/dev/null)"
  CHECK_RC=$?
  PARITY_CASES=$((PARITY_CASES + 1))
  if [ "$BODY_RC" != "$CHECK_RC" ] || [ "$BODY_OUT" != "$CHECK_OUT" ]; then
    PARITY_MISMATCH="$PARITY_MISMATCH [$label: rc $BODY_RC/$CHECK_RC, body '$BODY_OUT', check '$CHECK_OUT']"
  fi
  case "$BODY_OUT" in
    *'"permissionDecision":"deny"'*) PARITY_LAST=deny ;;
    '') PARITY_LAST=allow ;;
    *) PARITY_LAST=other ;;
  esac
}
expect_parity() {
  local want="$1" label="$2" body="$3"
  shift 3
  body_and_check "$label" "$body" "$@"
  [ "$PARITY_LAST" = "$want" ] || PARITY_MISMATCH="$PARITY_MISMATCH [$label: wanted $want, the body answered $PARITY_LAST]"
}
edit_body() {
  payload PreToolUse "${2:-Edit}" "$(node -e 'process.stdout.write(JSON.stringify({ file_path: process.argv[1], old_string: "x", new_string: "y" }))' "$1")"
}
set_state() {
  node -e '
    const fs = require("fs");
    const [file, field, value] = process.argv.slice(1);
    const state = JSON.parse(fs.readFileSync(file, "utf8"));
    state[field] = JSON.parse(value);
    fs.writeFileSync(file, JSON.stringify(state));
  ' "$STATE_FILE" "$1" "$2"
}
PARITY_CASES=0
PARITY_MISMATCH=""
SESSION_KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" "$SID")"
STATE_FILE="$PROJ/.zensu/state/tdd-phase-$SESSION_KEY.json"
cp "$STATE_FILE" "$TMP/state.saved"
restore_state() { cp "$TMP/state.saved" "$STATE_FILE"; }
expect_parity allow "armed vanilla, a source file" "$(edit_body "$PROJ/src/app.txt")"
expect_parity allow "armed vanilla, a relative source file" "$(edit_body src/app.txt)"
expect_parity allow "armed vanilla, a .zensu plan" "$(edit_body "$PROJ/.zensu/plans/p.md")"
expect_parity deny "armed vanilla, the state file" "$(edit_body "$STATE_FILE")"
expect_parity deny "armed vanilla, the state file through dot segments" "$(edit_body "$PROJ/src/../.zensu/state/x.json")"
expect_parity allow "a tool outside the group" "$(edit_body "$PROJ/src/app.txt" NotebookEdit)"
expect_parity allow "a child principal" "$(edit_body "$PROJ/.zensu/state/x.json" | node -e '
  const o = JSON.parse(require("fs").readFileSync(0, "utf8"));
  o.agent_id = "child";
  o.agent_type = "zensu:review-aspect";
  process.stdout.write(JSON.stringify(o));
')"
expect_parity allow "a malformed payload" "not json at all"
expect_parity allow "no file_path" "$(payload PreToolUse Edit '{"old_string":"x"}')"
expect_parity deny "a state path in another letter case" "$(payload PreToolUse Edit '{"file_path":".ZENSU/STATE/x.json"}')"
expect_parity deny "a state path with backslashes" "$(payload PreToolUse Edit '{"file_path":".zensu\\state\\x.json"}')"
expect_parity deny "a line feed in the path" "$(payload PreToolUse Edit '{"file_path":"src/a\nb.txt"}')"
ln -s "$PROJ/.zensu/state" "$PROJ/state-link"
expect_parity deny "a symlink into the state directory" "$(edit_body "$PROJ/state-link/x.json")"
rm -f "$PROJ/state-link"
set_state active '"true"'
expect_parity deny "an active flag that is no boolean" "$(edit_body "$PROJ/src/app.txt")"
restore_state
set_state vanilla 1
expect_parity deny "a vanilla flag that is no boolean" "$(edit_body "$PROJ/src/app.txt")"
restore_state
set_state vanilla false
expect_parity deny "armed strict, no phase" "$(edit_body "$PROJ/src/app.txt")"
expect_parity allow "armed strict, a .zensu plan" "$(edit_body "$PROJ/.zensu/plans/p.md")"
set_state phase '"RED_WRITE"'
expect_parity allow "armed strict at RED_WRITE" "$(edit_body "$PROJ/src/app.txt")"
count_hook dispatch:pre "$(edit_body "$PROJ/src/app.txt")"
if [ "$HOOK_RC" -eq 0 ] && [ "$HOOK_STARTS" -le 59 ] && [ "$HOOK_NODES" -le 40 ]; then
  check "B4 an Edit in a strict chain runs the edit gate's body: $HOOK_STARTS programs (budget 59), $HOOK_NODES of them node (budget 40) ($HOOK_PROGRAMS)" PASS
else
  check "B4 an Edit in a strict chain: rc=$HOOK_RC, $HOOK_STARTS programs (budget 59), $HOOK_NODES node (budget 40) ($HOOK_PROGRAMS)" FAIL
fi
restore_state
set_state active false
expect_parity allow "a chain that is not active" "$(edit_body "$STATE_FILE")"
restore_state
printf 'not json' > "$STATE_FILE"
expect_parity deny "a corrupt workflow document" "$(edit_body "$PROJ/src/app.txt")"
rm -f "$STATE_FILE"
expect_parity deny "a missing workflow document" "$(edit_body "$PROJ/src/app.txt")"
restore_state
BYPASS_OUT="$(printf '%s' "$(edit_body "$STATE_FILE")" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
  -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_SESSION_ADOPTED CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_TDD_GATE=off \
  "$REAL_NODE" "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" pre --only tdd-edit-gate 2>/dev/null)"
if [ -n "$BYPASS_OUT" ] || ! grep -q '"ZENSU_TDD_GATE"' "$STATE_FILE"; then
  PARITY_MISMATCH="$PARITY_MISMATCH [ZENSU_TDD_GATE=off did not allow and record the bypass: '$BYPASS_OUT']"
fi
PARITY_CASES=$((PARITY_CASES + 1))
restore_state
if [ -z "$PARITY_MISMATCH" ]; then
  check "D1 the in-process edit gate answers byte for byte like its body in all $PARITY_CASES states" PASS
else
  check "D1 the in-process edit gate differs from its body:$PARITY_MISMATCH" FAIL
fi

dispatch_pre() {
  printf '%s' "$1" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_SESSION_ADOPTED CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" "${@:2}" \
    "$REAL_NODE" "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" pre 2>/dev/null
}
STORE_TARGET="$ZENSU_TEST_PLUGIN_DATA/planted.json"
case "$(dispatch_pre "$(edit_body "$STORE_TARGET" Write)")" in
  *'"permissionDecision":"deny"'*Plugin-Data-Guard*|*Plugin-Data-Guard*'"permissionDecision":"deny"'*) check "D2 the dispatcher runs the data guard for a Write" PASS ;;
  *) check "D2 the dispatcher runs the data guard for a Write" FAIL ;;
esac
NOTEBOOK_STORE="$(payload PreToolUse NotebookEdit "$(node -e 'process.stdout.write(JSON.stringify({ notebook_path: process.argv[1], new_source: "y" }))' "$ZENSU_TEST_PLUGIN_DATA/planted.ipynb")")"
case "$(dispatch_pre "$NOTEBOOK_STORE")" in
  *Plugin-Data-Guard*) check "D2b the dispatcher runs the data guard for a NotebookEdit" PASS ;;
  *) check "D2b the dispatcher runs the data guard for a NotebookEdit" FAIL ;;
esac
case "$(dispatch_pre "$(edit_body "$STATE_FILE")")" in
  *TDD-Phase-Gate*) check "D3 the dispatcher runs the edit gate for an Edit" PASS ;;
  *) check "D3 the dispatcher runs the edit gate for an Edit" FAIL ;;
esac
SECRET_INPUT="$(node -e 'process.stdout.write(JSON.stringify({ file_path: process.argv[1], content: "key = \"sk_" + "live_abcdef1234567890XY\"" }))' "$PROJ/src/app.txt")"
case "$(dispatch_pre "$(payload PreToolUse Write "$SECRET_INPUT")")" in
  *stripe-live-key*) check "D4 the dispatcher runs the secret scan for a Write" PASS ;;
  *) check "D4 the dispatcher runs the secret scan for a Write" FAIL ;;
esac
SECRET_NOTEBOOK="$(node -e 'process.stdout.write(JSON.stringify({ notebook_path: process.argv[1], new_source: "key = \"sk_" + "live_abcdef1234567890XY\"" }))' "$PROJ/src/app.ipynb")"
case "$(dispatch_pre "$(payload PreToolUse NotebookEdit "$SECRET_NOTEBOOK")")" in
  *stripe-live-key*) check "D4b the dispatcher runs the secret scan for a NotebookEdit" PASS ;;
  *) check "D4b the dispatcher runs the secret scan for a NotebookEdit" FAIL ;;
esac
SPAWN_BODY="$(payload PreToolUse Agent "$AGENT_INPUT")"
case "$(dispatch_pre "$SPAWN_BODY")" in
  *'"permissionDecision":"allow"'*zensu:code-reviewer*) check "D5 the dispatcher grants a confined reviewer spawn" PASS ;;
  *) check "D5 the dispatcher grants a confined reviewer spawn" FAIL ;;
esac
printf '%s' '{"hooks":{"reviewerSpawnAutoAllow":false}}' > "$TMP/grant-off.json"
case "$(dispatch_pre "$SPAWN_BODY" ZENSU_CONFIG="$TMP/grant-off.json")" in
  *'"permissionDecision":"allow"'*) check "D5b hooks.reviewerSpawnAutoAllow=false withdraws the grant under the dispatcher" FAIL ;;
  *) check "D5b hooks.reviewerSpawnAutoAllow=false withdraws the grant under the dispatcher" PASS ;;
esac
case "$(dispatch_pre "$SPAWN_BODY" MSYS2_ENV_CONV_EXCL="$(printf 'A=\nB=')")" in
  *'"permissionDecision":"allow"'*) check "D5c a line break in MSYS2_ENV_CONV_EXCL fails the bind, so no grant" FAIL ;;
  *) check "D5c a line break in MSYS2_ENV_CONV_EXCL fails the bind, so no grant" PASS ;;
esac

strict_pair() {
  (
    env_name="$1"
    env_value="$2"
    unset ZENSU_CONFIG
    export HOME="$TMP/config-home" CLAUDE_PROJECT_DIR="$TMP/config-project"
    export "$env_name=$env_value"
    . "$CONFIG_LIB"
    ref="$(_zensu_config_node -e "$_ZENSU_STRICT_JS"' process.stdout.write(verdict(process.argv[1]))' probeKey 2>/dev/null)"
    disp="$(node -e '
      const d = require(process.argv[1]);
      process.stdout.write(d.configHookEnabledStrict("probeKey", process.env, process.cwd()) ? "1" : "0");
    ' "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" 2>/dev/null)"
    printf '%s %s' "${ref:-0}" "${disp:-y}"
  )
}
CR="$(printf '\r')"
LF="$(printf '\nx')"
LF="${LF%x}"
STRICT_BREAK_BAD=""
mkdir -p "$TMP/config-home" "$TMP/config-project"
printf '%s' '{"hooks":{"probeKey":false}}' > "$TMP/strict-off.json"
for STRICT_CASE in "ZENSU_CONFIG:$TMP/strict-off.json$LF" "ZENSU_CONFIG:$TMP/strict-off.json$CR" "HOME:$TMP/config-home$LF" "CLAUDE_PROJECT_DIR:$TMP/config-project$CR"; do
  case "$(strict_pair "${STRICT_CASE%%:*}" "${STRICT_CASE#*:}")" in
    '0 0') ;;
    *) STRICT_BREAK_BAD="$STRICT_BREAK_BAD [${STRICT_CASE%%:*}: $(strict_pair "${STRICT_CASE%%:*}" "${STRICT_CASE#*:}")]" ;;
  esac
done
if [ -z "$STRICT_BREAK_BAD" ]; then
  check "C1d a line break in a strict config input withholds the grant in the dispatcher and in _ZENSU_STRICT_JS" PASS
else
  check "C1d the strict readers differ for a line break in a config input:$STRICT_BREAK_BAD" FAIL
fi

CONFIG_HOME="$TMP/config-home"
CONFIG_PROJ="$TMP/config-project"
mkdir -p "$CONFIG_HOME/.zensu" "$CONFIG_PROJ/.zensu"
GLOBAL_FILE="$CONFIG_HOME/.zensu/config.json"
PROJECT_FILE="$CONFIG_PROJ/.zensu/config.json"
BACKSLASH="$(printf '\134')"
put() {
  rm -rf "$1"
  case "$2" in
    absent) ;;
    text) printf '%s' "$3" > "$1" ;;
    nul) printf '{"hooks":{}}\000{"hooks":{"probeKey":false}}' > "$1" ;;
    dir) mkdir -p "$1" ;;
    unreadable) printf '%s' "$3" > "$1"; chmod 000 "$1" ;;
  esac
}
CONFIG_MISMATCH=""
CONFIG_NODE_MISMATCH=""
CONFIG_DISPATCH_MISMATCH=""
CONFIG_STRICT_MISMATCH=""
CONFIG_CASES=0
config_case() {
  local label="$1" expect_decided="$2" home="$3" override="${4:-}" result
  result="$(
    export HOME="$home" CLAUDE_PROJECT_DIR="$CONFIG_PROJ"
    if [ -n "$override" ]; then export ZENSU_CONFIG="$override"; else unset ZENSU_CONFIG; fi
    . "$CONFIG_LIB"
    : > "$TMP/config.log"
    export ZENSU_BUDGET_LOG="$TMP/config.log"
    SAVED_PATH="$PATH"
    PATH="$SHIMS"
    zensu_hook_enabled probeKey; enabled=$?
    zensu_hook_opted_in probeKey; opted=$?
    PATH="$SAVED_PATH"
    nodes="$(grep -cx node "$TMP/config.log")"
    val="$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks[process.argv[1]]===false?"0":"1")' probeKey 2>/dev/null)"
    if [ -z "$val" ] || [ "$val" = 1 ]; then ref_enabled=0; else ref_enabled=1; fi
    val="$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks[process.argv[1]]===true?"1":"0")' probeKey 2>/dev/null)"
    if [ "$val" = 1 ]; then ref_opted=0; else ref_opted=1; fi
    disp="$(node -e '
      const d = require(process.argv[1]);
      process.stdout.write((d.configHookEnabled("probeKey", process.env, process.cwd()) ? "0" : "1")
        + " " + (d.configHookOptedIn("probeKey", process.env, process.cwd()) ? "0" : "1"));
    ' "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" 2>/dev/null)"
    strict_ref="$(_zensu_config_node -e "$_ZENSU_STRICT_JS"' process.stdout.write(verdict(process.argv[1]))' probeKey 2>/dev/null)"
    strict_disp="$(node -e '
      const d = require(process.argv[1]);
      process.stdout.write(d.configHookEnabledStrict("probeKey", process.env, process.cwd()) ? "1" : "0");
    ' "$PLUGIN_DIR/hooks/lib/hook-dispatch-v1.js" 2>/dev/null)"
    printf '%s %s %s %s %s %s %s %s' "$enabled" "$opted" "$nodes" "$ref_enabled" "$ref_opted" "${disp:-x x}" "${strict_ref:-x}" "${strict_disp:-y}"
  )"
  CONFIG_CASES=$((CONFIG_CASES + 1))
  set -- $result
  if [ "$1" != "$4" ] || [ "$2" != "$5" ]; then
    CONFIG_MISMATCH="$CONFIG_MISMATCH [$label: enabled $1/$4 opted $2/$5]"
  fi
  if [ "${6:-x}" != "$4" ] || [ "${7:-x}" != "$5" ]; then
    CONFIG_DISPATCH_MISMATCH="$CONFIG_DISPATCH_MISMATCH [$label: enabled ${6:-x}/$4 opted ${7:-x}/$5]"
  fi
  if [ "${8:-x}" != "${9:-y}" ]; then
    CONFIG_STRICT_MISMATCH="$CONFIG_STRICT_MISMATCH [$label: strict ${9:-y}/${8:-x}]"
  fi
  case "$expect_decided:$3" in
    yes:0|no:[1-9]*|any:*) ;;
    *) CONFIG_NODE_MISMATCH="$CONFIG_NODE_MISMATCH [$label: $3 node]" ;;
  esac
}
put "$GLOBAL_FILE" absent; put "$PROJECT_FILE" absent
config_case "no candidate file" yes "$CONFIG_HOME"
config_case "an empty HOME" yes ""
put "$GLOBAL_FILE" text '{"hooks":{"other":false},"logging":{"timestampStyle":"none"}}'
config_case "a global file without the key" yes "$CONFIG_HOME"
put "$GLOBAL_FILE" text ''
config_case "an empty global file" yes "$CONFIG_HOME"
put "$GLOBAL_FILE" text 'not json at all'
config_case "a malformed global file" yes "$CONFIG_HOME"
put "$GLOBAL_FILE" nul
config_case "a global file whose key follows a NUL byte" yes "$CONFIG_HOME"
put "$GLOBAL_FILE" text '{"note":"probeKey","hooks":{}}'
config_case "the key only as a string value" no "$CONFIG_HOME"
put "$GLOBAL_FILE" text '{"hooks":{"probeKey":false}}'
config_case "the global file disables the key" no "$CONFIG_HOME"
put "$GLOBAL_FILE" text '{"hooks":{"probeKey":true}}'
config_case "the global file opts the key in" no "$CONFIG_HOME"
put "$PROJECT_FILE" text '{"hooks":{"probeKey":false}}'
config_case "the project file overrides a global opt-in" no "$CONFIG_HOME"
put "$PROJECT_FILE" text '{"hooks":null}'
config_case "a project file that nulls the hooks object" no "$CONFIG_HOME"
put "$PROJECT_FILE" absent
put "$GLOBAL_FILE" text "{\"hooks\":{\"${BACKSLASH}u0070robeKey\":false}}"
case "$(cat "$GLOBAL_FILE")" in
  *'"probeKey"'*) CONFIG_MISMATCH="$CONFIG_MISMATCH [the escaped-key fixture holds the plain key]" ;;
  *"${BACKSLASH}u0070robeKey"*) ;;
  *) CONFIG_MISMATCH="$CONFIG_MISMATCH [the escaped-key fixture holds no escape]" ;;
esac
config_case "the key spelled with a unicode escape" no "$CONFIG_HOME"
put "$GLOBAL_FILE" dir
config_case "a directory at the global path" no "$CONFIG_HOME"
put "$GLOBAL_FILE" unreadable '{"hooks":{}}'
config_case "an unreadable global file" any "$CONFIG_HOME"
put "$GLOBAL_FILE" absent
put "$PROJECT_FILE" text '{"hooks":{"other":true}}'
config_case "a project file without the key" yes "$CONFIG_HOME"
printf '%s' '{"hooks":{"probeKey":false}}' > "$TMP/override.json"
config_case "ZENSU_CONFIG disables the key" no "$CONFIG_HOME" "$TMP/override.json"
config_case "ZENSU_CONFIG names a missing file" no "$CONFIG_HOME" "$TMP/missing-override.json"
PRECHECK_BYTES="$(. "$CONFIG_LIB" && printf '%s' "${_ZENSU_CONFIG_PRECHECK_BYTES:-}")"
case "$PRECHECK_BYTES" in
  ''|*[!0-9]*) CONFIG_MISMATCH="$CONFIG_MISMATCH [the pre-check names no read bound]" ;;
  *)
    PAD="$(printf "%0${PRECHECK_BYTES}d" 0)"
    put "$PROJECT_FILE" absent
    put "$GLOBAL_FILE" text "{\"pad\":\"$PAD\",\"hooks\":{\"other\":false}}"
    config_case "a global file longer than the pre-check reads" no "$CONFIG_HOME"
    put "$GLOBAL_FILE" text "{\"pad\":\"$PAD\",\"hooks\":{\"probeKey\":false}}"
    config_case "a global file whose key lies past the bytes the pre-check reads" no "$CONFIG_HOME"
    ;;
esac
put "$GLOBAL_FILE" absent; put "$PROJECT_FILE" absent
if [ -z "$CONFIG_MISMATCH" ]; then
  check "C1 zensu_hook_enabled and zensu_hook_opted_in answer like the node reader in all $CONFIG_CASES config cases" PASS
else
  check "C1 the shell pre-check disagrees with the node reader:$CONFIG_MISMATCH" FAIL
fi
if [ -z "$CONFIG_DISPATCH_MISMATCH" ]; then
  check "C1b the dispatcher's config reader answers like the node reader in all $CONFIG_CASES config cases" PASS
else
  check "C1b the dispatcher's config reader disagrees with the node reader:$CONFIG_DISPATCH_MISMATCH" FAIL
fi
if [ -z "$CONFIG_STRICT_MISMATCH" ]; then
  check "C1c the dispatcher's strict config reader answers like _ZENSU_STRICT_JS in all $CONFIG_CASES config cases" PASS
else
  check "C1c the dispatcher's strict config reader disagrees with _ZENSU_STRICT_JS:$CONFIG_STRICT_MISMATCH" FAIL
fi
if [ -z "$CONFIG_NODE_MISMATCH" ]; then
  check "C2 the config getters start no node when no candidate file names the key, and defer to node when one does or is longer than the pre-check reads" PASS
else
  check "C2 node starts of the config getters:$CONFIG_NODE_MISMATCH" FAIL
fi

CFG_JS="$(. "$CONFIG_LIB" && printf '%s' "$_ZENSU_CFG_JS")"
SHAPE_HOME="$TMP/shape-home"
SHAPE_PROJECT="$TMP/shape-project"
SHAPE_OVERRIDE="$TMP/shape-override.json"
in_shape() {
  local project_state="$1" override_state="$2"
  shift 2
  (
    export HOME="$SHAPE_HOME"
    case "$project_state" in
      set) export CLAUDE_PROJECT_DIR="$SHAPE_PROJECT" ;;
      empty) export CLAUDE_PROJECT_DIR="" ;;
      *) unset CLAUDE_PROJECT_DIR ;;
    esac
    case "$override_state" in
      set) export ZENSU_CONFIG="$SHAPE_OVERRIDE" ;;
      empty) export ZENSU_CONFIG="" ;;
      *) unset ZENSU_CONFIG ;;
    esac
    "$@"
  )
}
cfg_candidates() {
  node - "$CFG_JS" <<'NODE'
const vm = require('vm');
const read = [];
const fs = new Proxy({}, {
  get: () => (file) => {
    if (typeof file === 'string') read.push(file);
    const error = new Error('ENOENT');
    error.code = 'ENOENT';
    throw error;
  }
});
const sandbox = {
  require: (name) => (name === 'fs' || name === 'node:fs' ? fs : require(name)),
  process: { env: Object.assign({}, process.env) }
};
vm.runInNewContext(process.argv[2] + ';cfg();', sandbox);
process.stdout.write(read.join('\n'));
NODE
}
precheck_decides() {
  . "$CONFIG_LIB"
  _zensu_config_key_unset probeKey
}
CANDIDATE_MISMATCH=""
CANDIDATE_PROBES=0
for SHAPE in "set unset" "unset unset" "empty unset" "set empty" "set set"; do
  rm -rf "$SHAPE_HOME" "$SHAPE_PROJECT" "$SHAPE_OVERRIDE"
  mkdir -p "$SHAPE_HOME" "$SHAPE_PROJECT"
  set -- $SHAPE
  CANDIDATES="$(in_shape "$1" "$2" cfg_candidates)"
  [ -n "$CANDIDATES" ] || CANDIDATE_MISMATCH="$CANDIDATE_MISMATCH [$SHAPE: cfg() read no file]"
  if [ "$2" != set ] && ! in_shape "$1" "$2" precheck_decides; then
    CANDIDATE_MISMATCH="$CANDIDATE_MISMATCH [$SHAPE: the pre-check does not decide while no file exists]"
  fi
  while IFS= read -r CANDIDATE; do
    [ -n "$CANDIDATE" ] || continue
    case "$CANDIDATE" in
      "$TMP"/*) ;;
      *) CANDIDATE_MISMATCH="$CANDIDATE_MISMATCH [$SHAPE: cfg() reads $CANDIDATE outside the fixture]"; continue ;;
    esac
    mkdir -p "${CANDIDATE%/*}"
    printf '%s' '{"hooks":{"probeKey":false}}' > "$CANDIDATE"
    CANDIDATE_PROBES=$((CANDIDATE_PROBES + 1))
    if in_shape "$1" "$2" precheck_decides; then
      CANDIDATE_MISMATCH="$CANDIDATE_MISMATCH [$SHAPE: the pre-check misses $CANDIDATE]"
    fi
    rm -f "$CANDIDATE"
  done <<EOF
$CANDIDATES
EOF
done
if [ -z "$CANDIDATE_MISMATCH" ]; then
  check "C3 a key in any of the $CANDIDATE_PROBES files cfg() reads across five environment shapes sends the shell pre-check to node" PASS
else
  check "C3 the shell pre-check misses a file cfg() reads:$CANDIDATE_MISMATCH" FAIL
fi

cat > "$TMP/self-location-scan.js" <<'NODE'
const fs = require('fs');
const path = require('path');
const [pluginDir, controlFile] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(path.join(pluginDir, 'hooks/hooks.json'), 'utf8'));
const { dispatcherEvent } = require(path.join(pluginDir, 'hooks/lib/hook-registration-v1.js'));
const { REGISTRY } = require(path.join(pluginDir, 'hooks/lib/hook-dispatch-v1.js'));
const out = [];
const queue = [];
for (const event of ['PreToolUse', 'PostToolUse']) {
  for (const group of manifest.hooks[event] || []) {
    for (const hook of group.hooks || []) {
      if (dispatcherEvent(hook) === event) {
        for (const check of REGISTRY) {
          if (check.event !== event) continue;
          queue.push('hooks/' + check.script);
          if (check.body !== null) queue.push('hooks/' + check.body);
        }
        continue;
      }
      const m = /hooks\/([A-Za-z0-9._-]+\.sh)"?$/.exec(hook.command || '');
      if (m) queue.push('hooks/' + m[1]);
      else out.push('unresolved ' + event + ' command ' + (hook.command || ''));
    }
  }
}
const SOURCE = /(?:^|[\s;&|(!])(?:source|\.)\s+"([^"]+)"/g;
const LEADING_SOURCE = /^\s*(?:(?:if|then|else|do)\s+)?(?:!|\|\||&&)?\s*(?:source|\.)\s/;
const LIBRARY = /([A-Za-z0-9_-]+\.sh)$/;
const VARIABLE = /^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/;
const SELF_LOCATION = /dirname[^|;&)]*(\$0\b|\$\{0\}|BASH_SOURCE)/;
const PLUGIN_ROOT_DEFAULT = /\$\{CLAUDE_PLUGIN_ROOT:=\$\(/;
const code = (file) => fs.readFileSync(path.join(pluginDir, file), 'utf8').split('\n')
  .map((line, index) => ({ text: line, number: index + 1 }))
  .filter((line) => !/^\s*#/.test(line.text));
const selfLocations = (file) => code(file).filter((line) => SELF_LOCATION.test(line.text)
  && !(file === 'hooks/lib/zensu-autopilot-state.sh' && PLUGIN_ROOT_DEFAULT.test(line.text)));
const locate = (name) => ['hooks/lib/' + name, 'hooks/' + name]
  .find((candidate) => fs.existsSync(path.join(pluginDir, candidate)));
const seen = new Set();
while (queue.length) {
  const file = queue.shift();
  if (seen.has(file)) continue;
  seen.add(file);
  for (const line of selfLocations(file)) out.push('hit ' + file + ':' + line.number);
  const lines = code(file);
  const text = lines.map((line) => line.text).join('\n');
  for (const line of lines) {
    const sources = Array.from(line.text.matchAll(SOURCE));
    if (!sources.length && LEADING_SOURCE.test(line.text)) out.push('unresolved ' + file + ':' + line.number);
    for (const match of sources) {
      let name = (LIBRARY.exec(match[1]) || [])[1];
      const variable = !name && (VARIABLE.exec(match[1]) || [])[1];
      if (variable) name = (new RegExp('\\b' + variable + '=[^\\n]*?([A-Za-z0-9_-]+\\.sh)').exec(text) || [])[1];
      const target = name && locate(name);
      if (target) queue.push(target);
      else out.push('unresolved ' + file + ':' + line.number);
    }
  }
}
for (const file of seen) out.push('member ' + file);
out.push('control ' + selfLocations(controlFile).length + ' ' + (seen.has(controlFile) ? 'member' : 'outside'));
process.stdout.write(out.join('\n') + '\n');
NODE
SCAN_OUT="$(node "$TMP/self-location-scan.js" "$PLUGIN_DIR" hooks/stop-work-order.sh)"
SCAN_MEMBERS="$(printf '%s\n' "$SCAN_OUT" | grep -c '^member ')"
SCAN_PROBLEMS="$(printf '%s\n' "$SCAN_OUT" | grep -E '^(hit|unresolved) ' | tr '\n' ' ')"
for REQUIRED in hooks/pre-agent-reviewer-allow.sh hooks/plan-approved-delegate.sh hooks/post-workflow-launch.sh \
    hooks/lib/zensu-work-order-hook.sh hooks/lib/zensu-session.sh hooks/lib/zensu-msys-env.sh; do
  printf '%s\n' "$SCAN_OUT" | grep -qx "member $REQUIRED" || SCAN_PROBLEMS="$SCAN_PROBLEMS not-reached $REQUIRED"
done
if [ -z "$SCAN_PROBLEMS" ]; then
  check "S1 no PreToolUse or PostToolUse hook and no library it sources ($SCAN_MEMBERS files) finds its own directory with dirname" PASS
else
  check "S1 a tool-call hook or library it sources finds its directory with dirname, or a source could not be followed: $SCAN_PROBLEMS" FAIL
fi
case "$(printf '%s\n' "$SCAN_OUT" | grep '^control ')" in
  'control 0 '*|*' member') check "S1b the scan flags the dirname self-location of hooks/stop-work-order.sh, a Stop hook outside the scan" FAIL ;;
  'control '*) check "S1b the scan flags the dirname self-location of hooks/stop-work-order.sh, a Stop hook outside the scan" PASS ;;
  *) check "S1b the scan reported no control result" FAIL ;;
esac

unit_check_done "B9z every unit file the registry gives this suite was graded"
finish
