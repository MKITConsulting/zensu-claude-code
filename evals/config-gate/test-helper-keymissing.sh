#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-helper-keymissing: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_CFG="/tmp/zensu-keymissing-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {}}
EOF

export ZENSU_CONFIG="$TMP_CFG"

source "$HELPER"

if zensu_hook_enabled autoTdd; then
  check "helper returns 0 (enabled) when hooks.autoTdd key missing" PASS
else
  check "helper returns 0 (enabled) when hooks.autoTdd key missing" FAIL
fi

if zensu_hook_enabled pulseSession; then
  check "helper returns 0 (enabled) when hooks.pulseSession key missing" PASS
else
  check "helper returns 0 (enabled) when hooks.pulseSession key missing" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"unrelated": "value"}
EOF

if zensu_hook_enabled autoTdd; then
  check "helper returns 0 (enabled) when 'hooks' object missing entirely" PASS
else
  check "helper returns 0 (enabled) when 'hooks' object missing entirely" FAIL
fi

rm -f "$TMP_CFG"

echo "----"
echo "test-helper-keymissing: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
