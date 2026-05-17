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
  echo "test-helper-no-node: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_CFG="/tmp/zensu-no-node-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoTdd": false, "autoReview": false, "autoFix": false, "pulseSession": false}}
EOF

SAFE_PATH="/dev/null"
if PATH="$SAFE_PATH" command -v node >/dev/null 2>&1; then
  check "precondition: SAFE_PATH hides node" FAIL
  rm -f "$TMP_CFG"
  echo "----"
  echo "test-helper-no-node: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "precondition: SAFE_PATH hides node" PASS

source "$HELPER"

export ZENSU_CONFIG="$TMP_CFG"

ORIG_PATH="$PATH"
PATH="$SAFE_PATH"

for KEY in autoTdd autoReview autoFix pulseSession; do
  if zensu_hook_enabled "$KEY"; then
    check "no-node + ${KEY}=false in config: helper falls back to enabled" PASS
  else
    check "no-node + ${KEY}=false in config: helper falls back to enabled" FAIL
  fi
done

PATH="$ORIG_PATH"

rm -f "$TMP_CFG"

echo "----"
echo "test-helper-no-node: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
