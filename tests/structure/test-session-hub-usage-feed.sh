#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
MODULE="$PLUGIN_DIR/hooks/usage-feed.ts"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
CONTRACT="$PLUGIN_DIR/hooks/usage-feed-contract.json"
HANDOVER="$PLUGIN_DIR/skills/session-trail/handover-contract.json"
MODULE_TEST="$PLUGIN_DIR/tests/mods/usage-feed.test.ts"
MIN_CLAUDE_CODE='2.1.296'

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
report() {
  echo "----"
  echo "test-session-hub-usage-feed: $PASS PASS / $FAIL FAIL"
}

if ! command -v node >/dev/null 2>&1; then
  check "U0 node is on PATH" FAIL
  report; exit 1
fi

WANT_CONTRACT='{"schemaVersion":1,"usage":{"directory":"zensu/session-hub/v1/usage","schemaVersion":1,"record":["schemaVersion","sessionId","observedAt","rateLimits"],"rateLimit":["kind","percentUsed","resetsAt"]}}'
GOT_CONTRACT="$(cat "$CONTRACT" 2>/dev/null)"
GOT_BYTES="$(wc -c < "$CONTRACT" 2>/dev/null | tr -d ' ')"
if [ "$GOT_CONTRACT" = "$WANT_CONTRACT" ] && [ "$GOT_BYTES" = "$(( ${#WANT_CONTRACT} + 1 ))" ]; then
  check "U1 the usage-feed contract is exactly the published one line" PASS
else
  check "U1 the usage-feed contract changed (got ${GOT_BYTES:-0} bytes)" FAIL
fi

REGISTRATION="$(node -e '
  const doc = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(JSON.stringify([Object.keys(doc).sort(), doc.modules]));
' "$HOOKS_JSON" 2>/dev/null)"
if [ "$REGISTRATION" = '[["hooks","modules"],["./usage-feed.ts"]]' ] && [ -f "$MODULE" ] && [ ! -L "$MODULE" ]; then
  check "U2 hooks.json names exactly the usage-feed module beside its classic hooks, and the module is a regular file" PASS
else
  check "U2 hooks.json keys and modules are ${REGISTRATION:-<unreadable>}, want hooks and modules [\"./usage-feed.ts\"]" FAIL
fi

SOURCE_FACTS="$(node -e '
  const fs = require("fs");
  const path = require("path");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const contract = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const handover = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
  const only = (pattern) => {
    const found = [...source.matchAll(pattern)];
    return found.length === 1 ? found[0][1] : null;
  };
  const keysOf = (literal) => literal === null ? null : literal.split(", ").map((part) => part.split(":")[0].trim());
  const version = only(/^const SCHEMA_VERSION = (\d+)$/gm);
  const directory = only(/^const USAGE_DIRECTORY = \x27([^\x27\n]+)\x27$/gm);
  const record = keysOf(only(/^  const record = \{ ([^}\n]+) \}$/gm));
  const reading = keysOf(only(/^    readings\.push\(\{ ([^}\n]+) \}\)$/gm));
  const calls = [...new Set([...source.matchAll(/\$\.([A-Za-z_]+)(?:\.([A-Za-z_]+))?/g)].map((m) => m[2] ? m[1] + "." + m[2] : m[1]))].sort();
  const envNames = [...new Set([...source.matchAll(/\$\.env\.get\(\x27([A-Z_]+)\x27\)/g)].map((m) => m[1]))].sort();
  const events = [...source.matchAll(/\bon\(\x27([a-z.]+)\x27/g)].map((m) => m[1]);
  const imports = [...source.matchAll(/^import .*$/gm)].map((m) => m[0]);
  const facts = {
    constants: version !== null && Number(version) === contract.usage.schemaVersion && directory === contract.usage.directory,
    sibling: path.posix.dirname(contract.usage.directory) === path.posix.dirname(handover.receipts.directory),
    record: JSON.stringify(record) === JSON.stringify(contract.usage.record),
    reading: JSON.stringify(reading) === JSON.stringify(contract.usage.rateLimit),
    calls: JSON.stringify(calls) === JSON.stringify(["clock.now", "env.get", "fs.exists", "fs.stat", "fs.write", "session.id"]),
    env: JSON.stringify(envNames) === JSON.stringify(["CLAUDE_CONFIG_DIR", "HOME"]),
    events: JSON.stringify(events) === JSON.stringify(["session.measure"]),
    imports: imports.length > 0 && imports.every((line) => /^import type \{[^}]+\} from \x27claude-code\x27$/.test(line)),
  };
  facts.detail = JSON.stringify({ version, directory, record, reading, calls, envNames, events, imports });
  process.stdout.write(Object.entries(facts).map(([key, value]) => key + "=" + value).join("\n"));
' "$MODULE" "$CONTRACT" "$HANDOVER" 2>/dev/null)"
fact() { printf '%s\n' "$SOURCE_FACTS" | grep -Fx "$1=true" >/dev/null && echo PASS || echo FAIL; }
DETAIL="$(printf '%s\n' "$SOURCE_FACTS" | sed -n 's/^detail=//p')"

check "U3 the module's SCHEMA_VERSION and USAGE_DIRECTORY equal the contract" "$(fact constants)"
check "U4 the usage directory is a sibling of the session-trail receipt directory" "$(fact sibling)"
[ "$(fact record)" = PASS ] && [ "$(fact reading)" = PASS ] \
  && check "U5 the record and each rate-limit reading name exactly the contract's keys, in its order" PASS \
  || check "U5 the record or reading literal differs from the contract: ${DETAIL:-<unreadable>}" FAIL
[ "$(fact calls)" = PASS ] && [ "$(fact env)" = PASS ] \
  && check "U6 the module reaches only the clock, CLAUDE_CONFIG_DIR and HOME, three fs calls, and the session id" PASS \
  || check "U6 the module reaches more of the engine than the feed needs: ${DETAIL:-<unreadable>}" FAIL
check "U7 the module hooks session.measure alone, so session.start writes no stale reading" "$(fact events)"
check "U8 the module imports nothing but types from claude-code" "$(fact imports)"

[ -f "$MODULE_TEST" ] && grep -q "from 'claude-code/testing'" "$MODULE_TEST" \
  && check "U9 the claude plugin test file for the module is present" PASS \
  || check "U9 tests/mods/usage-feed.test.ts is missing or does not use the claude-code/testing kit" FAIL

FLOORS="$(grep -rhoE 'Claude Code[^.|]{0,12}[0-9]+\.[0-9]+\.[0-9]+[^.|]{0,6}(or newer|or later)' "$PLUGIN_DIR/README.md" "$PLUGIN_DIR/docs" 2>/dev/null \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')"
[ "$FLOORS" = "$MIN_CLAUDE_CODE " ] \
  && check "U10 README.md and docs/ state one minimum Claude Code version, the module's floor $MIN_CLAUDE_CODE" PASS \
  || check "U10 README.md and docs/ state minimum Claude Code versions '${FLOORS:-none}', want only $MIN_CLAUDE_CODE" FAIL

report
[ "$FAIL" -eq 0 ]
