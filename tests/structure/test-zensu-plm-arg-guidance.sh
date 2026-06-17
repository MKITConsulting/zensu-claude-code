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

CP_LINE="$(grep -F 'products create` — Create a new product' "$AGENT" 2>/dev/null)"
if printf '%s' "$CP_LINE" | grep -qF -- '--slug' && printf '%s' "$CP_LINE" | grep -qF -- '--name'; then
  check "C1 create_product entry names required --name + --slug flags" PASS
else
  check "C1 create_product entry names required --name + --slug flags" FAIL
fi

RULE_LINE="$(grep -iF 'kebab-case' "$AGENT" 2>/dev/null)"
if printf '%s' "$RULE_LINE" | grep -qF -- '--slug' && printf '%s' "$RULE_LINE" | grep -qiF 'required'; then
  check "C2 CLI flag rule present (kebab-case + --slug + required on one line)" PASS
else
  check "C2 CLI flag rule present (kebab-case + --slug + required on one line)" FAIL
fi

echo "----"
echo "test-zensu-plm-arg-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
