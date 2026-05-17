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
  echo "test-helper-envoverride: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_CFG="/tmp/zensu-envoverride-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoTdd": false}}
EOF

export ZENSU_CONFIG="$TMP_CFG"
source "$HELPER"

if zensu_hook_enabled autoTdd; then
  check "ZENSU_CONFIG=$TMP_CFG: autoTdd disabled is honored" FAIL
else
  check "ZENSU_CONFIG=$TMP_CFG: autoTdd disabled is honored" PASS
fi

NOTHING_CFG="/tmp/zensu-envoverride-not-here-$$.json"
rm -f "$NOTHING_CFG"
export ZENSU_CONFIG="$NOTHING_CFG"

if zensu_hook_enabled autoTdd; then
  check "ZENSU_CONFIG to nonexistent file: returns enabled" PASS
else
  check "ZENSU_CONFIG to nonexistent file: returns enabled" FAIL
fi

OTHER_CFG="/tmp/zensu-envoverride-other-$$.json"
cat > "$OTHER_CFG" <<'EOF'
{"hooks": {"autoTdd": true}}
EOF
export ZENSU_CONFIG="$OTHER_CFG"

if zensu_hook_enabled autoTdd; then
  check "ZENSU_CONFIG switches between configs (true config wins)" PASS
else
  check "ZENSU_CONFIG switches between configs (true config wins)" FAIL
fi

rm -f "$TMP_CFG" "$OTHER_CFG"

echo "----"
echo "test-helper-envoverride: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
