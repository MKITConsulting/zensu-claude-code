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
  echo "test-log-style-no-node: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_CFG="/tmp/zensu-log-no-node-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"logging": {"timestampStyle": "relative"}}
EOF

SAFE_PATH="/dev/null"
if PATH="$SAFE_PATH" command -v node >/dev/null 2>&1; then
  check "precondition: SAFE_PATH hides node" FAIL
  rm -f "$TMP_CFG"
  echo "----"
  echo "test-log-style-no-node: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "precondition: SAFE_PATH hides node" PASS

source "$HELPER"

export ZENSU_CONFIG="$TMP_CFG"

ORIG_PATH="$PATH"
PATH="$SAFE_PATH"

style=$(_zensu_log_style)
if [ "$style" = "wall" ]; then
  check "no-node + logging.timestampStyle=relative in config: helper falls back to 'wall'" PASS
else
  check "no-node + logging.timestampStyle=relative in config: helper falls back to 'wall' (got '$style')" FAIL
fi

PATH="$ORIG_PATH"

rm -f "$TMP_CFG"

echo "----"
echo "test-log-style-no-node: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
