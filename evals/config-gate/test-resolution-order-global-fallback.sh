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
  echo "test-resolution-order-global-fallback: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
HOME_CFG_DIR="$TMP_DIR/home/.zensu"
HOME_CFG="$HOME_CFG_DIR/config.json"

mkdir -p "$PROJECT_DIR" "$HOME_CFG_DIR"
printf '{"_marker":"home"}' > "$HOME_CFG"

unset ZENSU_CONFIG
export HOME="$TMP_DIR/home"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"

source "$HELPER"

resolved="$(_zensu_resolve_config)"
if [ "$resolved" = "$HOME_CFG" ]; then
  check "global config used when env and project-local absent" PASS
else
  check "global config used when env and project-local absent (got '$resolved')" FAIL
fi

unset CLAUDE_PROJECT_DIR
resolved="$(_zensu_resolve_config)"
if [ "$resolved" = "$HOME_CFG" ]; then
  check "CLAUDE_PROJECT_DIR unset also falls through to global" PASS
else
  check "CLAUDE_PROJECT_DIR unset also falls through to global (got '$resolved')" FAIL
fi

echo "----"
echo "test-resolution-order-global-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
