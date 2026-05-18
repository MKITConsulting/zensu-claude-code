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
  echo "test-log-style-fallback: $PASS PASS / $FAIL FAIL"
  exit 1
fi

source "$HELPER"

MISSING_CFG="/tmp/zensu-log-fallback-missing-$$.json"
rm -f "$MISSING_CFG"
export ZENSU_CONFIG="$MISSING_CFG"
style=$(_zensu_log_style)
if [ "$style" = "wall" ]; then
  check "missing config file falls back to 'wall'" PASS
else
  check "missing config file falls back to 'wall' (got '$style')" FAIL
fi

TMP_CFG="/tmp/zensu-log-fallback-keymissing-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {}}
EOF
export ZENSU_CONFIG="$TMP_CFG"
style=$(_zensu_log_style)
if [ "$style" = "wall" ]; then
  check "missing logging.timestampStyle key falls back to 'wall'" PASS
else
  check "missing logging.timestampStyle key falls back to 'wall' (got '$style')" FAIL
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-malformed.json"
style=$(_zensu_log_style)
if [ "$style" = "wall" ]; then
  check "malformed JSON falls back to 'wall'" PASS
else
  check "malformed JSON falls back to 'wall' (got '$style')" FAIL
fi

export ZENSU_CONFIG="$EVAL_DIR/fixtures/config-log-invalid.json"
style=$(_zensu_log_style)
if [ "$style" = "wall" ]; then
  check "invalid timestampStyle value 'foo' falls back to 'wall'" PASS
else
  check "invalid timestampStyle value 'foo' falls back to 'wall' (got '$style')" FAIL
fi

rm -f "$TMP_CFG"

echo "----"
echo "test-log-style-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
