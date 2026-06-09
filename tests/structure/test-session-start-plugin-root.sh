#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/session-start-pulse.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/session-start-pulse.sh exists" FAIL
  echo "----"
  echo "test-session-start-plugin-root: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "hooks/session-start-pulse.sh exists" PASS

if bash -n "$HOOK" 2>/dev/null; then
  check "PR-S1 bash -n syntax check passes" PASS
else
  check "PR-S1 bash -n syntax check passes" FAIL
fi

if grep -qF '$HOME/.zensu' "$HOOK"; then
  check "PR-S2 hook source references \$HOME/.zensu directory" PASS
else
  check "PR-S2 hook source references \$HOME/.zensu directory" FAIL
fi

if grep -qF 'plugin-root' "$HOOK"; then
  check "PR-S3 hook source writes to plugin-root file" PASS
else
  check "PR-S3 hook source writes to plugin-root file" FAIL
fi

if grep -qE '(if.*!=.*CLAUDE_PLUGIN_ROOT|current=)' "$HOOK"; then
  check "PR-S4 hook source contains idempotency guard (current vs new)" PASS
else
  check "PR-S4 hook source contains idempotency guard (current vs new)" FAIL
fi

TMP_HOME="$(mktemp -d -t "ssp-home-XXXXXX")"
FAKE_PLUGIN_ROOT="$(mktemp -d -t "ssp-plugin-XXXXXX")"
mkdir -p "$FAKE_PLUGIN_ROOT/hooks/lib"
cat >"$FAKE_PLUGIN_ROOT/hooks/lib/zensu-config.sh" <<'EOF'
zensu_hook_enabled() { return 0; }
EOF
mkdir -p "$FAKE_PLUGIN_ROOT/hooks"
cp "$HOOK" "$FAKE_PLUGIN_ROOT/hooks/session-start-pulse.sh"

env -i PATH="$PATH" HOME="$TMP_HOME" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN_ROOT" bash "$FAKE_PLUGIN_ROOT/hooks/session-start-pulse.sh" >/dev/null 2>&1
ROOT_FILE="$TMP_HOME/.zensu/plugin-root"
if [ -f "$ROOT_FILE" ] && [ "$(cat "$ROOT_FILE")" = "$FAKE_PLUGIN_ROOT" ]; then
  check "PR-F1 functional: invoking hook creates \$HOME/.zensu/plugin-root with CLAUDE_PLUGIN_ROOT content" PASS
else
  check "PR-F1 functional: missing or wrong content (got=$([ -f "$ROOT_FILE" ] && cat "$ROOT_FILE" || echo MISSING))" FAIL
fi

MTIME_BEFORE=$(stat -c %Y "$ROOT_FILE" 2>/dev/null || stat -f %m "$ROOT_FILE" 2>/dev/null || echo 0)
sleep 1
env -i PATH="$PATH" HOME="$TMP_HOME" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN_ROOT" bash "$FAKE_PLUGIN_ROOT/hooks/session-start-pulse.sh" >/dev/null 2>&1
MTIME_AFTER=$(stat -c %Y "$ROOT_FILE" 2>/dev/null || stat -f %m "$ROOT_FILE" 2>/dev/null || echo 0)
if [ "$MTIME_BEFORE" = "$MTIME_AFTER" ]; then
  check "PR-F2 idempotent: second invocation with same CLAUDE_PLUGIN_ROOT does not rewrite file (mtime unchanged)" PASS
else
  check "PR-F2 idempotent: mtime changed ($MTIME_BEFORE -> $MTIME_AFTER)" FAIL
fi

DIFFERENT_PLUGIN_ROOT="$(mktemp -d -t "ssp-plugin2-XXXXXX")"
mkdir -p "$DIFFERENT_PLUGIN_ROOT/hooks/lib"
cat >"$DIFFERENT_PLUGIN_ROOT/hooks/lib/zensu-config.sh" <<'EOF'
zensu_hook_enabled() { return 0; }
EOF
cp "$HOOK" "$DIFFERENT_PLUGIN_ROOT/hooks/session-start-pulse.sh"
env -i PATH="$PATH" HOME="$TMP_HOME" CLAUDE_PLUGIN_ROOT="$DIFFERENT_PLUGIN_ROOT" bash "$DIFFERENT_PLUGIN_ROOT/hooks/session-start-pulse.sh" >/dev/null 2>&1
NEW_CONTENT="$(cat "$ROOT_FILE" 2>/dev/null)"
if [ "$NEW_CONTENT" = "$DIFFERENT_PLUGIN_ROOT" ]; then
  check "PR-F3 update path: changed CLAUDE_PLUGIN_ROOT rewrites file to the new value" PASS
else
  check "PR-F3 update path: file content mismatch (expected=$DIFFERENT_PLUGIN_ROOT, got=$NEW_CONTENT)" FAIL
fi

PERSIST_LINE=$(grep -nF 'printf '"'"'%s\n'"'"' "$CLAUDE_PLUGIN_ROOT" > "$HOME/.zensu/plugin-root"' "$HOOK" | head -1 | cut -d: -f1)
GATE_LINE=$(grep -nF 'zensu_hook_enabled pulseSession' "$HOOK" | head -1 | cut -d: -f1)
if [ -n "$PERSIST_LINE" ] && [ -n "$GATE_LINE" ] && [ "$PERSIST_LINE" -lt "$GATE_LINE" ]; then
  check "PR-S5 persist block appears BEFORE pulseSession gate (persist line $PERSIST_LINE < gate line $GATE_LINE)" PASS
else
  check "PR-S5 persist block appears BEFORE pulseSession gate (persist=$PERSIST_LINE gate=$GATE_LINE)" FAIL
fi

TMP_HOME2="$(mktemp -d -t "ssp-home2-XXXXXX")"
FAKE_PLUGIN_ROOT2="$(mktemp -d -t "ssp-plugin3-XXXXXX")"
mkdir -p "$FAKE_PLUGIN_ROOT2/hooks/lib"
cat >"$FAKE_PLUGIN_ROOT2/hooks/lib/zensu-config.sh" <<'EOF'
zensu_hook_enabled() { return 1; }
EOF
cp "$HOOK" "$FAKE_PLUGIN_ROOT2/hooks/session-start-pulse.sh"
env -i PATH="$PATH" HOME="$TMP_HOME2" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN_ROOT2" bash "$FAKE_PLUGIN_ROOT2/hooks/session-start-pulse.sh" >/dev/null 2>&1
ROOT_FILE2="$TMP_HOME2/.zensu/plugin-root"
if [ -f "$ROOT_FILE2" ] && [ "$(cat "$ROOT_FILE2")" = "$FAKE_PLUGIN_ROOT2" ]; then
  check "PR-F4 pulseSession=false still writes plugin-root (persist runs unconditionally)" PASS
else
  check "PR-F4 pulseSession=false but plugin-root missing or wrong (got=$([ -f "$ROOT_FILE2" ] && cat "$ROOT_FILE2" || echo MISSING))" FAIL
fi

rm -rf "$TMP_HOME" "$FAKE_PLUGIN_ROOT" "$DIFFERENT_PLUGIN_ROOT" "$TMP_HOME2" "$FAKE_PLUGIN_ROOT2"

echo "----"
echo "test-session-start-plugin-root: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
