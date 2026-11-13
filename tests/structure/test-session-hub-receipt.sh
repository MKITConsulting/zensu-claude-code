#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-session-hub-receipt.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
CONTRACT="$PLUGIN_DIR/skills/session-trail/handover-contract.json"
TRAIL="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
UNIT="$PLUGIN_DIR/tests/structure/session-hub-receipt-v1.test.js"
HUB_DIR="$PLUGIN_DIR/plugins/session-hub"
HUB_ENTRY="$HUB_DIR/hooks/lib/session-hub-receipt-v1.mjs"
HUB_HOOKS_JSON="$HUB_DIR/hooks/hooks.json"
HUB_CONTRACT="$HUB_DIR/skills/session-trail/handover-contract.json"
HUB_TRAIL="$HUB_DIR/skills/session-trail/scripts/trail.mjs"
WORK="$(mktemp -d -t session-hub-receipt-XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
report() {
  echo "----"
  echo "test-session-hub-receipt: $PASS PASS / $FAIL FAIL"
}

if ! command -v node >/dev/null 2>&1; then
  check "R0 node is on PATH" FAIL
  report; exit 1
fi

bash -n "$HOOK" 2>/dev/null && check "R1 the hook passes bash -n" PASS || check "R1 the hook passes bash -n" FAIL

. "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"
unit_check "R2 the session-hub-receipt unit file passes" "$UNIT"

WANT_CONTRACT='{"schemaVersion":1,"takeover":{"contract":1,"prefix":"/zensu:session-trail takeover ","suffix":" --all","receipt":" --receipt "},"receipts":{"directory":"zensu/session-hub/v1/receipts","schemaVersion":1},"linkedSessions":{"contract":1,"lineage":{"directory":"zensu/session-lineage/v1/edges","schemaVersion":1}}}'
GOT_CONTRACT="$(cat "$CONTRACT" 2>/dev/null)"
GOT_BYTES="$(wc -c < "$CONTRACT" 2>/dev/null | tr -d ' ')"
if [ "$GOT_CONTRACT" = "$WANT_CONTRACT" ] && [ "$GOT_BYTES" = "$(( ${#WANT_CONTRACT} + 1 ))" ]; then
  check "R3 the handover contract is exactly the published one line" PASS
else
  check "R3 the handover contract changed (got ${GOT_BYTES:-0} bytes)" FAIL
fi

REGISTRATION="$(node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const found = [];
  for (const [event, groups] of Object.entries(doc.hooks || {})) {
    for (const group of groups || []) {
      for (const hook of group.hooks || []) {
        if (String(hook.command || "").includes("/hooks/user-prompt-session-hub-receipt.sh")) {
          found.push([event, group.matcher === undefined ? "none" : String(group.matcher), String(hook.timeout)].join(":"));
        }
      }
    }
  }
  process.stdout.write(found.join(","));
' "$HOOKS_JSON" 2>/dev/null)"
[ "$REGISTRATION" = "UserPromptSubmit:none:10" ] \
  && check "R4 hooks.json registers the hook once, on UserPromptSubmit, matcher-free, with a 10 s bound" PASS \
  || check "R4 hooks.json registration is ${REGISTRATION:-<absent>}, want UserPromptSubmit:none:10" FAIL

SID='0f8fad5b-d9cb-469f-a165-70867728950e'
TOKEN='9b2c4e6a8d0f1b3c5e7a9c1e3f5b7d90'
COMMAND="/zensu:session-trail takeover $SID --all --receipt $TOKEN"
NO_CONFIG="$WORK/no-such-config.json"
OFF_CONFIG="$WORK/off.json"
printf '%s' '{"hooks":{"sessionHubReceipt":false}}' > "$OFF_CONFIG"

run_hook() {
  local config_root="$1" prompt="$2" zensu_config="${3:-$NO_CONFIG}" plugin_root="${4:-$PLUGIN_DIR}" extra="${5:-}"
  node -e '
    const body = { session_id: "receipt-test", cwd: process.argv[2], hook_event_name: "UserPromptSubmit", prompt: process.argv[1] };
    if (process.argv[3]) body.agent_id = process.argv[3];
    process.stdout.write(JSON.stringify(body));
  ' "$prompt" "$WORK" "$extra" > "$WORK/payload.json"
  env CLAUDE_CONFIG_DIR="$config_root" ZENSU_CONFIG="$zensu_config" CLAUDE_PLUGIN_ROOT="$plugin_root" bash "$HOOK" < "$WORK/payload.json"
}

entries() {
  node -e '
    const fs = require("fs"), path = require("path");
    const out = [];
    const walk = (dir) => {
      let names = [];
      try { names = fs.readdirSync(dir); } catch { return; }
      for (const name of names.sort()) {
        const file = path.join(dir, name);
        const stat = fs.lstatSync(file);
        out.push(path.relative(process.argv[1], file) + ":" + (stat.mode & 0o777).toString(8));
        if (stat.isDirectory()) walk(file);
      }
    };
    walk(process.argv[1]);
    process.stdout.write(out.join(","));
  ' "$1"
}

CFG="$WORK/cfg-hit"
mkdir -p "$CFG"
OUT="$(run_hook "$CFG" "$COMMAND")"
RC=$?
LISTED="$(entries "$CFG")"
WANT_LISTED="zensu:700,zensu/session-hub:700,zensu/session-hub/v1:700,zensu/session-hub/v1/receipts:700,zensu/session-hub/v1/receipts/$TOKEN.json:600"
if [ "$RC" = "0" ] && [ -z "$OUT" ] && [ "$LISTED" = "$WANT_LISTED" ]; then
  check "R5 the Session Hub command lands exactly one private receipt and prints nothing" PASS
else
  check "R5 the Session Hub command (rc=$RC, stdout ${#OUT} chars, tree ${LISTED:-<empty>})" FAIL
fi
BODY_OK="$(node -e '
  const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const keys = Object.keys(r).sort().join(",");
  process.stdout.write(String(keys === "event,kind,plugin,recordedAt,schemaVersion,token" && r.schemaVersion === 1
    && r.kind === "session-hub-receipt" && r.token === process.argv[2] && r.event === "UserPromptSubmit"
    && typeof r.plugin === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(r.recordedAt)));
' "$CFG/zensu/session-hub/v1/receipts/$TOKEN.json" "$TOKEN" 2>/dev/null)"
[ "$BODY_OK" = "true" ] && check "R6 the receipt holds the six documented fields and nothing else" PASS \
  || check "R6 the receipt body is not the documented six fields" FAIL

FIRST="$(cat "$CFG/zensu/session-hub/v1/receipts/$TOKEN.json" 2>/dev/null)"
OUT="$(run_hook "$CFG" "$COMMAND")"
RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] && [ "$(cat "$CFG/zensu/session-hub/v1/receipts/$TOKEN.json" 2>/dev/null)" = "$FIRST" ] \
  && check "R7 a second identical command leaves the first receipt untouched" PASS \
  || check "R7 a second identical command changed the receipt or the output (rc=$RC)" FAIL

CFG="$WORK/cfg-miss"
mkdir -p "$CFG"
MISS_BAD=""
for PROMPT in \
  'add a feature flag to the checkout page' \
  "/zensu:session-trail takeover $SID --all" \
  "please run $COMMAND" \
  "$COMMAND extra" \
  "/zensu:session-trail show $SID --all --receipt $TOKEN" \
  "/session-hub:session-trail takeover $SID --all --receipt $TOKEN" \
  $'<task-notification>\n<status>completed</status>\n</task-notification>'; do
  OUT="$(run_hook "$CFG" "$PROMPT")"
  RC=$?
  [ "$RC" = "0" ] && [ -z "$OUT" ] || MISS_BAD="$MISS_BAD [$(printf '%s' "$PROMPT" | head -c 30): rc=$RC out=${#OUT}]"
done
[ -z "$MISS_BAD" ] && [ -z "$(entries "$CFG")" ] \
  && check "R8 every other prompt, the companion's takeover command included, writes nothing and prints nothing" PASS \
  || check "R8 another prompt wrote or printed something:$MISS_BAD tree=$(entries "$CFG")" FAIL

CFG="$WORK/cfg-guards"
mkdir -p "$CFG"
GUARD_BAD=""
OUT="$(run_hook "$CFG" "$COMMAND" "$OFF_CONFIG")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || GUARD_BAD="$GUARD_BAD switched-off:rc=$RC"
OUT="$(run_hook "$CFG" "$COMMAND" "$NO_CONFIG" "$WORK")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || GUARD_BAD="$GUARD_BAD wrong-root:rc=$RC"
OUT="$(run_hook "$CFG" "$COMMAND" "$NO_CONFIG" "$PLUGIN_DIR" "agent-1")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || GUARD_BAD="$GUARD_BAD subagent:rc=$RC"
[ -z "$GUARD_BAD" ] && [ -z "$(entries "$CFG")" ] \
  && check "R9 the switch, a foreign plugin root and a subagent payload each write nothing and exit 0" PASS \
  || check "R9 a guard wrote or failed:$GUARD_BAD tree=$(entries "$CFG")" FAIL

CFG="$WORK/cfg-link"
ELSEWHERE="$WORK/elsewhere"
mkdir -p "$CFG" "$ELSEWHERE"
ln -s "$ELSEWHERE" "$CFG/zensu"
OUT="$(run_hook "$CFG" "$COMMAND")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] && [ -z "$(entries "$ELSEWHERE")" ] \
  && check "R10 a symlinked store component is refused silently and nothing lands behind it" PASS \
  || check "R10 a symlinked store component (rc=$RC, behind it: $(entries "$ELSEWHERE"))" FAIL

EMPTY="$WORK/empty-config"
mkdir -p "$EMPTY"
receipt_flag_bad() {
  local trail="$1" bad="" verb out lineage_out shape_out
  for verb in show handoff takeover; do
    out="$(node "$trail" "$verb" "$SID" --all --receipt "$TOKEN" --no-git --config-dir "$EMPTY" 2>&1)"
    case "$verb:$out" in
      takeover:*) out="$(ZENSU_SESSION_LINEAGE=off node "$trail" takeover "$SID" --all --no-record --receipt "$TOKEN" --config-dir "$EMPTY" 2>&1)" ;;
    esac
    case "$out" in *"not a flag of"*|*"--receipt needs"*|*"unknown flag"*) bad="$bad $verb" ;; esac
  done
  lineage_out="$(node "$trail" lineage --receipt "$TOKEN" --config-dir "$EMPTY" 2>&1)"
  case "$lineage_out" in *"--receipt is not a flag of \`lineage\`"*) ;; *) bad="$bad lineage-accepted" ;; esac
  shape_out="$(node "$trail" show "$SID" --receipt ABCDEF --config-dir "$EMPTY" 2>&1)"
  case "$shape_out" in *"--receipt needs 32 lowercase hexadecimal characters"*) ;; *) bad="$bad malformed-accepted" ;; esac
  printf '%s' "$bad"
}
FLAG_BAD="$(receipt_flag_bad "$TRAIL")"
[ -z "$FLAG_BAD" ] \
  && check "R11 trail.mjs accepts --receipt on show, handoff and takeover, refuses it elsewhere and refuses a malformed token" PASS \
  || check "R11 trail.mjs --receipt handling:$FLAG_BAD" FAIL

WANT_HUB_CONTRACT='{"schemaVersion":1,"takeover":{"contract":2,"prefix":"/session-hub:session-trail takeover ","suffix":" --all","receipt":" --receipt "},"receipts":{"directory":"zensu/session-hub/v1/receipts","schemaVersion":1},"linkedSessions":{"contract":1,"lineage":{"directory":"zensu/session-lineage/v1/edges","schemaVersion":1}}}'
GOT_HUB_CONTRACT="$(cat "$HUB_CONTRACT" 2>/dev/null)"
GOT_HUB_BYTES="$(wc -c < "$HUB_CONTRACT" 2>/dev/null | tr -d ' ')"
if [ "$GOT_HUB_CONTRACT" = "$WANT_HUB_CONTRACT" ] && [ "$GOT_HUB_BYTES" = "$(( ${#WANT_HUB_CONTRACT} + 1 ))" ]; then
  check "R12 the companion's handover contract is exactly the contract-2 line" PASS
else
  check "R12 the companion's handover contract changed (got ${GOT_HUB_BYTES:-0} bytes)" FAIL
fi

HUB_REGISTRATION="$(node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const canonical = (value) => Array.isArray(value)
    ? "[" + value.map(canonical).join(",") + "]"
    : value !== null && typeof value === "object"
      ? "{" + Object.keys(value).sort().map((key) => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}"
      : JSON.stringify(value);
  process.stdout.write(canonical(doc.hooks));
' "$HUB_HOOKS_JSON" 2>/dev/null)"
[ "$HUB_REGISTRATION" = '{"UserPromptSubmit":[{"hooks":[{"args":["${CLAUDE_PLUGIN_ROOT}/hooks/lib/session-hub-receipt-v1.mjs"],"command":"node","timeout":10,"type":"command"}]}]}' ] \
  && check "R13 the companion registers its receipt entry once, on UserPromptSubmit, in exec form with a 10 s bound" PASS \
  || check "R13 the companion's registration is ${HUB_REGISTRATION:-<absent>}" FAIL

HUB_COMMAND="/session-hub:session-trail takeover $SID --all --receipt $TOKEN"
HUB_TAGGED="$(printf '<command-message>session-hub:session-trail</command-message>\n<command-name>/session-hub:session-trail</command-name>\n<command-args>takeover %s --all --receipt %s</command-args>' "$SID" "$TOKEN")"
HUB_HOME="$WORK/hub-home"
mkdir -p "$HUB_HOME"
HUB_OFF_HOME="$WORK/hub-off-home"
mkdir -p "$HUB_OFF_HOME/.zensu"
printf '%s' '{"hooks":{"sessionHubReceipt":false}}' > "$HUB_OFF_HOME/.zensu/config.json"

run_hub() {
  local config_root="$1" prompt="$2" home="${3:-$HUB_HOME}" plugin_root="${4:-$HUB_DIR}" extra="${5:-}"
  node -e '
    const body = { session_id: "receipt-test", cwd: process.argv[2], hook_event_name: "UserPromptSubmit", prompt: process.argv[1] };
    if (process.argv[3]) body.agent_id = process.argv[3];
    process.stdout.write(JSON.stringify(body));
  ' "$prompt" "$WORK" "$extra" > "$WORK/hub-payload.json"
  env CLAUDE_CONFIG_DIR="$config_root" HOME="$home" ZENSU_CONFIG="$OFF_CONFIG" CLAUDE_PLUGIN_ROOT="$plugin_root" node "$HUB_ENTRY" < "$WORK/hub-payload.json"
}

HUB_HIT_BAD=""
for FORM in raw tagged; do
  CFG="$WORK/hub-hit-$FORM"
  mkdir -p "$CFG"
  case "$FORM" in (raw) PROMPT="$HUB_COMMAND" ;; (*) PROMPT="$HUB_TAGGED" ;; esac
  OUT="$(run_hub "$CFG" "$PROMPT")"; RC=$?
  [ "$RC" = "0" ] && [ -z "$OUT" ] && [ "$(entries "$CFG")" = "$WANT_LISTED" ] || HUB_HIT_BAD="$HUB_HIT_BAD $FORM:rc=$RC:out=${#OUT}:tree=$(entries "$CFG")"
  HUB_BODY="$(node -e '
    const fs = require("fs");
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const want = JSON.parse(fs.readFileSync(process.argv[3], "utf8")).version;
    process.stdout.write(String(Object.keys(r).sort().join(",") === "event,kind,plugin,recordedAt,schemaVersion,token" && r.token === process.argv[2] && r.plugin === want));
  ' "$CFG/zensu/session-hub/v1/receipts/$TOKEN.json" "$TOKEN" "$HUB_DIR/.claude-plugin/plugin.json" 2>/dev/null)"
  [ "$HUB_BODY" = "true" ] || HUB_HIT_BAD="$HUB_HIT_BAD $FORM:body"
done
[ -z "$HUB_HIT_BAD" ] \
  && check "R14 the companion entry lands exactly one private receipt with the companion's version for the raw and the command-tag form, prints nothing and ignores ZENSU_CONFIG" PASS \
  || check "R14 the companion entry:$HUB_HIT_BAD" FAIL

CFG="$WORK/hub-miss"
mkdir -p "$CFG"
HUB_MISS_BAD=""
for PROMPT in \
  'add a feature flag to the checkout page' \
  "$COMMAND" \
  "/session-hub:session-trail takeover $SID --all" \
  "please run $HUB_COMMAND" \
  "$HUB_COMMAND extra" \
  "/session-hub:session-trail show $SID --all --receipt $TOKEN" \
  $'<task-notification>\n<status>completed</status>\n</task-notification>'; do
  OUT="$(run_hub "$CFG" "$PROMPT")"; RC=$?
  [ "$RC" = "0" ] && [ -z "$OUT" ] || HUB_MISS_BAD="$HUB_MISS_BAD [$(printf '%s' "$PROMPT" | head -c 30): rc=$RC out=${#OUT}]"
done
[ -z "$HUB_MISS_BAD" ] && [ -z "$(entries "$CFG")" ] \
  && check "R15 the companion entry writes nothing for PLM's takeover command or any other prompt" PASS \
  || check "R15 the companion entry wrote or printed something:$HUB_MISS_BAD tree=$(entries "$CFG")" FAIL

CFG="$WORK/hub-guards"
mkdir -p "$CFG"
HUB_GUARD_BAD=""
OUT="$(run_hub "$CFG" "$HUB_COMMAND" "$HUB_OFF_HOME")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || HUB_GUARD_BAD="$HUB_GUARD_BAD switched-off:rc=$RC"
OUT="$(run_hub "$CFG" "$HUB_COMMAND" "$HUB_HOME" "$WORK")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || HUB_GUARD_BAD="$HUB_GUARD_BAD wrong-root:rc=$RC"
OUT="$(run_hub "$CFG" "$HUB_COMMAND" "$HUB_HOME" "$HUB_DIR" "agent-1")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || HUB_GUARD_BAD="$HUB_GUARD_BAD subagent:rc=$RC"
OUT="$(printf '%s' '{"prompt": "--receipt "' | env CLAUDE_CONFIG_DIR="$CFG" HOME="$HUB_HOME" CLAUDE_PLUGIN_ROOT="$HUB_DIR" node "$HUB_ENTRY")"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] || HUB_GUARD_BAD="$HUB_GUARD_BAD not-json:rc=$RC"
[ -z "$HUB_GUARD_BAD" ] && [ -z "$(entries "$CFG")" ] \
  && check "R16 hooks.sessionHubReceipt false in ~/.zensu/config.json, a foreign plugin root, a subagent payload and a broken payload each write nothing and exit 0" PASS \
  || check "R16 a companion guard wrote or failed:$HUB_GUARD_BAD tree=$(entries "$CFG")" FAIL

HUB_FLAG_BAD="$(receipt_flag_bad "$HUB_TRAIL")"
[ -z "$HUB_FLAG_BAD" ] \
  && check "R17 the companion's trail.mjs accepts --receipt on show, handoff and takeover, refuses it elsewhere and refuses a malformed token" PASS \
  || check "R17 the companion's trail.mjs --receipt handling:$HUB_FLAG_BAD" FAIL

unit_check_done "R2z every unit file the registry gives this suite was graded"

report
[ "$FAIL" -eq 0 ]
