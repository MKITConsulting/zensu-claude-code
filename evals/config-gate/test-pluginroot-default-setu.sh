#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
HOOKS_DIR="$PLUGIN_DIR/hooks"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-pluginroot-default-setu: $PASS PASS / $FAIL FAIL"
  exit 1
fi

if bash -c "
  set -u
  unset CLAUDE_PLUGIN_ROOT 2>/dev/null
  : \"\${CLAUDE_PLUGIN_ROOT:=$(cd "$HOOKS_DIR/.." && pwd)}\"
  source \"\${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh\"
  zensu_hook_enabled autoTdd >/dev/null 2>&1
  exit 0
" 2>/dev/null; then
  check "set -u + unset CLAUDE_PLUGIN_ROOT: defaulting idiom does not crash" PASS
else
  check "set -u + unset CLAUDE_PLUGIN_ROOT: defaulting idiom does not crash" FAIL
fi
unset ZENSU_CONFIG 2>/dev/null || true

OUT="$(bash -c "
  set -u
  unset CLAUDE_PLUGIN_ROOT 2>/dev/null
  : \"\${CLAUDE_PLUGIN_ROOT:=$(cd "$HOOKS_DIR/.." && pwd)}\"
  echo PLUGIN_ROOT=\${CLAUDE_PLUGIN_ROOT}
" 2>&1)"
case "$OUT" in
  *"PLUGIN_ROOT=$(cd "$HOOKS_DIR/.." && pwd)"*)
    check "defaulting idiom resolves CLAUDE_PLUGIN_ROOT to a real path under set -u" PASS ;;
  *)
    check "defaulting idiom resolves CLAUDE_PLUGIN_ROOT to a real path under set -u" FAIL ;;
esac

if bash -c "
  set -u
  unset CLAUDE_PLUGIN_ROOT 2>/dev/null
  : \"\${CLAUDE_PLUGIN_ROOT:=$(cd "$HOOKS_DIR/.." && pwd)}\"
  source \"\${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh\"
  unset ZENSU_CONFIG 2>/dev/null || true
  zensu_hook_enabled autoTdd && zensu_hook_enabled autoReview && zensu_hook_enabled autoFix && zensu_hook_enabled pulseSession
" 2>/dev/null; then
  check "set -u: helper returns enabled for all four keys with no config present" PASS
else
  check "set -u: helper returns enabled for all four keys with no config present" FAIL
fi

echo "----"
echo "test-pluginroot-default-setu: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
