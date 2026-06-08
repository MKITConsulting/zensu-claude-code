#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN_DIR/agents/zensu-plm.md"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$AGENT" ]; then
  check "agents/zensu-plm.md exists" FAIL
  echo "test-zensu-plm-arg-guidance: $PASS PASS / $FAIL FAIL"
  exit 1
fi

CP_LINE="$(grep -F 'create_product` — Create a new product' "$AGENT" 2>/dev/null)"
if printf '%s' "$CP_LINE" | grep -qF 'slug' && printf '%s' "$CP_LINE" | grep -qF 'product_type'; then
  check "C1 create_product entry names required slug + snake_case product_type" PASS
else
  check "C1 create_product entry names required slug + snake_case product_type" FAIL
fi

if grep -qiF 'snake_case' "$AGENT" && grep -qiF 'camelcase' "$AGENT" && grep -qF 'product_type' "$AGENT"; then
  check "C2 snake_case argument rule present (warns camelCase, product_type example)" PASS
else
  check "C2 snake_case argument rule present (warns camelCase, product_type example)" FAIL
fi

echo "----"
echo "test-zensu-plm-arg-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
