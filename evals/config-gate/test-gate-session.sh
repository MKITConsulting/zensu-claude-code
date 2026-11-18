#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/session-start-pulse.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "session-start-pulse.sh exists and is executable" FAIL
  echo "----"
  echo "test-gate-session: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "session-start-pulse.sh exists and is executable" PASS

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

TMP_CFG="/tmp/zensu-gate-session-disabled-$$.json"
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"pulseSession": false}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

OUT_DISABLED="$(env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
EXIT_DISABLED=$?

if [ -z "$OUT_DISABLED" ]; then
  check "pulseSession=false: stdout is empty, no pulse context line" PASS
else
  check "pulseSession=false: stdout is empty, no pulse context line (out=$OUT_DISABLED)" FAIL
fi

if [ "$EXIT_DISABLED" = "0" ]; then
  check "pulseSession=false: exit code 0" PASS
else
  check "pulseSession=false: exit code 0" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"pulseSession": true}}
EOF

OUT_ENABLED="$(cd "$PLUGIN_DIR" && env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
EXIT_ENABLED=$?

if [ "$EXIT_ENABLED" = "0" ] && printf '%s' "$OUT_ENABLED" | grep -qF 'zensu: pulse context — HEAD=' \
  && ! printf '%s' "$OUT_ENABLED" | grep -qF 'pulse session'; then
  check "pulseSession=true: no legacy root export, rc=0, and the pulse context line emitted without claiming a session" PASS
else
  check "pulseSession=true: no legacy root export, rc=0, and the pulse context line emitted without claiming a session (rc=$EXIT_ENABLED, out=$OUT_ENABLED)" FAIL
fi

unset ZENSU_CONFIG
NOTHING_CFG="/tmp/zensu-no-config-session-$$.json"
rm -f "$NOTHING_CFG"
export ZENSU_CONFIG="$NOTHING_CFG"
OUT_DEFAULT="$(cd "$PLUGIN_DIR" && env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
case "$OUT_DEFAULT" in
  *"zensu: pulse context — HEAD="*|*"not a git repository, pulse context skipped"*) check "no config (default): stdout contains the pulse context line (enabled)" PASS ;;
  *)                                                                              check "no config (default): stdout contains the pulse context line (enabled)" FAIL ;;
esac

EMPTY_REPO="$(mktemp -d)"
NO_REPO="$(mktemp -d)"
git init -q "$EMPTY_REPO" >/dev/null 2>&1
OUT_EMPTY="$(cd "$EMPTY_REPO" && env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
OUT_NO_REPO="$(cd "$NO_REPO" && GIT_CEILING_DIRECTORIES="$(dirname "$NO_REPO")" env -u ZENSU_CLAUDE_PLUGIN_ROOT "$SCRIPT" 2>/dev/null)"
if [ "$OUT_EMPTY" = "zensu: no commit yet, pulse context skipped" ] \
  && [ "$OUT_NO_REPO" = "zensu: not a git repository, pulse context skipped" ]; then
  check "a repository without a commit and a directory outside any repository each get their own skip line" PASS
else
  check "a repository without a commit and a directory outside any repository each get their own skip line (empty=$OUT_EMPTY, none=$OUT_NO_REPO)" FAIL
fi
rm -rf "$EMPTY_REPO" "$NO_REPO"

rm -f "$TMP_CFG"

echo "----"
echo "test-gate-session: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
