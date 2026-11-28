#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HUB_DIR="$PLUGIN_DIR/plugins/session-hub"
CONTRACT="$HUB_DIR/hooks/interaction-contract.json"
MANIFEST="$HUB_DIR/.claude-plugin/plugin.json"
LAUNCHER="$HUB_DIR/hooks/lib/session-hub-courier-v1.mjs"
UNIT="$PLUGIN_DIR/tests/structure/session-hub-courier-v1.test.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
report() {
  echo "----"
  echo "test-session-hub-interaction: $PASS PASS / $FAIL FAIL"
}

if ! command -v node >/dev/null 2>&1; then
  check "I0 node is on PATH" FAIL
  report; exit 1
fi

WANT_CONTRACT='{"schemaVersion":1,"interaction":{"contract":1,"protocol":1,"pointer":"zensu/session-hub/v1/hub.json","maxLineBytes":262144,"courier":{"identifier":"dev.zensu.session-hub.courier","team":"3P6C5C4S5B"}}}'
GOT_CONTRACT="$(cat "$CONTRACT" 2>/dev/null)"
GOT_BYTES="$(wc -c < "$CONTRACT" 2>/dev/null | tr -d ' ')"
if [ "$GOT_CONTRACT" = "$WANT_CONTRACT" ] && [ "$GOT_BYTES" = "$(( ${#WANT_CONTRACT} + 1 ))" ]; then
  check "I1 the interaction contract is exactly the published one line" PASS
else
  check "I1 the interaction contract changed (got ${GOT_BYTES:-0} bytes)" FAIL
fi

. "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"
unit_check "I2 the session-hub-courier unit file passes" "$UNIT"

OPTION_BAD="$(node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const want = {
    allow_unsigned_courier: {
      type: "boolean",
      title: "Accept an unsigned Session Hub courier",
      description: "For development builds of the Zensu Session Hub only. Lets this plugin start a courier that does not carry the Session Hub release signature. Leave it off on every other Mac.",
      default: false,
    },
  };
  process.stdout.write(JSON.stringify(m.userConfig) === JSON.stringify(want) ? "" : JSON.stringify(m.userConfig));
' "$MANIFEST" 2>&1)"
[ -z "$OPTION_BAD" ] \
  && check "I3 the manifest declares one option, allow_unsigned_courier, a boolean that is off by default, neither required nor sensitive" PASS \
  || check "I3 the manifest userConfig is ${OPTION_BAD:-<unreadable>}" FAIL

IMPORTS_BAD="$(node -e '
  const text = require("fs").readFileSync(process.argv[1], "utf8");
  const bad = [];
  for (const m of text.matchAll(/^(?:import|export)\s[^;]*?\sfrom\s+([\x27"])([^\x27"\n]+)\1/gm)) if (!m[2].startsWith("node:")) bad.push(m[2]);
  if (/\bimport\(|\brequire\(/.test(text)) bad.push("dynamic-load");
  process.stdout.write(bad.join(" "));
' "$LAUNCHER" 2>&1)"
[ -z "$IMPORTS_BAD" ] \
  && check "I4 the courier launcher loads only node: builtins, and only statically" PASS \
  || check "I4 the courier launcher loads more: $IMPORTS_BAD" FAIL

unit_check_done "I2z every unit file the registry gives this suite was graded"

report
[ "$FAIL" -eq 0 ]
