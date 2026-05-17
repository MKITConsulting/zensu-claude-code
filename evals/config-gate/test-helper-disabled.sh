#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-helper-disabled: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-only-tdd.json"

source "$HELPER"

if zensu_hook_enabled autoTdd; then
  check "helper returns 1 (disabled) when autoTdd=false" FAIL
else
  check "helper returns 1 (disabled) when autoTdd=false" PASS
fi

if zensu_hook_enabled autoReview; then
  check "helper returns 0 (enabled) for autoReview when only autoTdd disabled" PASS
else
  check "helper returns 0 (enabled) for autoReview when only autoTdd disabled" FAIL
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-all-disabled.json"

if zensu_hook_enabled autoTdd; then
  check "all-disabled: autoTdd returns 1 (disabled)" FAIL
else
  check "all-disabled: autoTdd returns 1 (disabled)" PASS
fi

if zensu_hook_enabled autoReview; then
  check "all-disabled: autoReview returns 1 (disabled)" FAIL
else
  check "all-disabled: autoReview returns 1 (disabled)" PASS
fi

if zensu_hook_enabled autoFix; then
  check "all-disabled: autoFix returns 1 (disabled)" FAIL
else
  check "all-disabled: autoFix returns 1 (disabled)" PASS
fi

if zensu_hook_enabled pulseSession; then
  check "all-disabled: pulseSession returns 1 (disabled)" FAIL
else
  check "all-disabled: pulseSession returns 1 (disabled)" PASS
fi

TMP_CFG="/tmp/zensu-truthy-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoTdd": true}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

if zensu_hook_enabled autoTdd; then
  check "explicit true returns 0 (enabled)" PASS
else
  check "explicit true returns 0 (enabled)" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoTdd": "false"}}
EOF

if zensu_hook_enabled autoTdd; then
  check "string 'false' (not boolean) returns 0 (enabled, strict ===)" PASS
else
  check "string 'false' (not boolean) returns 0 (enabled, strict ===)" FAIL
fi

rm -f "$TMP_CFG"

echo "----"
echo "test-helper-disabled: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
