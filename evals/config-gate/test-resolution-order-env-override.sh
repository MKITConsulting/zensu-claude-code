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
  echo "test-resolution-order-env-override: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ENV_CFG="$TMP_DIR/env-config.json"
PROJECT_DIR="$TMP_DIR/project"
PROJECT_CFG_DIR="$PROJECT_DIR/.zensu"
PROJECT_CFG="$PROJECT_CFG_DIR/config.json"
HOME_CFG_DIR="$TMP_DIR/home/.zensu"
HOME_CFG="$HOME_CFG_DIR/config.json"

mkdir -p "$PROJECT_CFG_DIR" "$HOME_CFG_DIR"
printf '{"_marker":"env"}'      > "$ENV_CFG"
printf '{"_marker":"project"}'  > "$PROJECT_CFG"
printf '{"_marker":"home"}'     > "$HOME_CFG"

export HOME="$TMP_DIR/home"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
export ZENSU_CONFIG="$ENV_CFG"

source "$HELPER"

resolved="$(_zensu_resolve_config)"
if [ "$resolved" = "$ENV_CFG" ]; then
  check "ZENSU_CONFIG env override beats project-local and global" PASS
else
  check "ZENSU_CONFIG env override beats project-local and global (got '$resolved')" FAIL
fi

echo "----"
echo "test-resolution-order-env-override: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
