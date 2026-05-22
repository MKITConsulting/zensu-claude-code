#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MCP_JSON="$PLUGIN_DIR/.mcp.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$MCP_JSON" ]; then
  check ".mcp.json exists at plugin root" FAIL
  echo "----"
  echo "test-mcp-json-url: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check ".mcp.json exists at plugin root" PASS

URL_LINE="$(grep -E '"url"[[:space:]]*:' "$MCP_JSON" || true)"
URL_VALUE="$(printf '%s' "$URL_LINE" | sed -E 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"

EXPECTED='${ZENSU_MCP_URL:-https://mcp.zensu.dev}/mcp'
if [ "$URL_VALUE" = "$EXPECTED" ]; then
  check "mcpServers.zensu.url equals expected (no /v1) — got: $URL_VALUE" PASS
else
  check "mcpServers.zensu.url equals expected (no /v1) — got: $URL_VALUE, want: $EXPECTED" FAIL
fi

if grep -qF '/v1/mcp' "$MCP_JSON"; then
  check ".mcp.json contains no '/v1/mcp' substring (regression guard)" FAIL
else
  check ".mcp.json contains no '/v1/mcp' substring (regression guard)" PASS
fi

case "$URL_VALUE" in
  */mcp) check "URL ends with /mcp (suffix guard against future /v2/mcp drift)" PASS ;;
  *)     check "URL ends with /mcp (suffix guard against future /v2/mcp drift) — got: $URL_VALUE" FAIL ;;
esac

echo "----"
echo "test-mcp-json-url: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
