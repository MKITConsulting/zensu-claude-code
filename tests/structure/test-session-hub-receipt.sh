#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-session-hub-receipt.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
CONTRACT="$PLUGIN_DIR/skills/session-trail/handover-contract.json"
TRAIL="$PLUGIN_DIR/skills/session-trail/scripts/trail.mjs"
UNIT="$PLUGIN_DIR/tests/structure/session-hub-receipt-v1.test.js"
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

UNIT_OUT="$(node --test "$UNIT" 2>&1)"
UNIT_RC=$?
UNIT_TOTAL="$(printf '%s' "$UNIT_OUT" | sed -n 's/^.*[[:space:]]tests \([0-9][0-9]*\)$/\1/p' | tail -1)"
UNIT_PASS="$(printf '%s' "$UNIT_OUT" | sed -n 's/^.*[[:space:]]pass \([0-9][0-9]*\)$/\1/p' | tail -1)"
if [ "$UNIT_RC" = "0" ] && [ "${UNIT_TOTAL:-0}" = "12" ] && [ "${UNIT_PASS:-0}" = "12" ]; then
  check "R2 session-hub-receipt-v1.test.js passes all 12 cases" PASS
else
  check "R2 session-hub-receipt-v1.test.js (rc=$UNIT_RC pass=${UNIT_PASS:-0} total=${UNIT_TOTAL:-0}, want 12 of 12)" FAIL
  printf '%s\n' "$UNIT_OUT" | tail -20
fi

WANT_CONTRACT='{"schemaVersion":1,"takeover":{"contract":1,"prefix":"/zensu:session-trail takeover ","suffix":" --all","receipt":" --receipt "},"receipts":{"directory":"zensu/session-hub/v1/receipts","schemaVersion":1}}'
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
  $'<task-notification>\n<status>completed</status>\n</task-notification>'; do
  OUT="$(run_hook "$CFG" "$PROMPT")"
  RC=$?
  [ "$RC" = "0" ] && [ -z "$OUT" ] || MISS_BAD="$MISS_BAD [$(printf '%s' "$PROMPT" | head -c 30): rc=$RC out=${#OUT}]"
done
[ -z "$MISS_BAD" ] && [ -z "$(entries "$CFG")" ] \
  && check "R8 every other prompt writes nothing and prints nothing" PASS \
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
FLAG_BAD=""
for VERB in show handoff takeover; do
  OUT="$(node "$TRAIL" "$VERB" "$SID" --all --receipt "$TOKEN" --no-git --config-dir "$EMPTY" 2>&1)"
  case "$VERB:$OUT" in
    takeover:*) OUT="$(ZENSU_SESSION_LINEAGE=off node "$TRAIL" takeover "$SID" --all --no-record --receipt "$TOKEN" --config-dir "$EMPTY" 2>&1)" ;;
  esac
  case "$OUT" in *"not a flag of"*|*"--receipt needs"*|*"unknown flag"*) FLAG_BAD="$FLAG_BAD $VERB" ;; esac
done
LINEAGE_OUT="$(node "$TRAIL" lineage --receipt "$TOKEN" --config-dir "$EMPTY" 2>&1)"
case "$LINEAGE_OUT" in *"--receipt is not a flag of \`lineage\`"*) ;; *) FLAG_BAD="$FLAG_BAD lineage-accepted" ;; esac
SHAPE_OUT="$(node "$TRAIL" show "$SID" --receipt ABCDEF --config-dir "$EMPTY" 2>&1)"
case "$SHAPE_OUT" in *"--receipt needs 32 lowercase hexadecimal characters"*) ;; *) FLAG_BAD="$FLAG_BAD malformed-accepted" ;; esac
[ -z "$FLAG_BAD" ] \
  && check "R11 trail.mjs accepts --receipt on show, handoff and takeover, refuses it elsewhere and refuses a malformed token" PASS \
  || check "R11 trail.mjs --receipt handling:$FLAG_BAD" FAIL

report
[ "$FAIL" -eq 0 ]
