set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/resolve-session-id.js"
PULSE="$PLUGIN_DIR/hooks/session-start-pulse.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
sanitize() { printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/-/g'; }

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP  node not on PATH"
  echo "test-native-path-resolution: skipped"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJ="C:/ws/agent-native-repo"
SAN="$(sanitize "$PROJ")"
PDIR="$TMP/projects/$SAN"
mkdir -p "$PDIR"
UUID="a1a1a1a1-2b2b-3c3c-4d4d-5e5e5e5e5e5e"
: > "$PDIR/$UUID.jsonl"

OUT="$(MSYS_NO_PATHCONV=1 ZENSU_PROJECTS_DIR="$(native "$TMP/projects")" CLAUDE_PROJECT_DIR="$PROJ" node "$(native "$HELPER")")"
if [ "$OUT" = "$UUID" ]; then
  check "N1 resolve-session-id.js returns UUID driven with native projects path (agent-faithful)" PASS
else
  check "N1 resolve-session-id.js native-path resolve (got '$OUT' expected '$UUID')" FAIL
fi

FAKE_ROOT="$TMP/plugin-root-dir"
mkdir -p "$FAKE_ROOT/hooks/lib"
printf 'zensu_hook_enabled() { return 1; }\n' > "$FAKE_ROOT/hooks/lib/zensu-config.sh"
cp "$PULSE" "$FAKE_ROOT/hooks/session-start-pulse.sh"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

ROOT_NATIVE="$(native "$FAKE_ROOT")"
HOME_NATIVE="$(native "$FAKE_HOME")"
HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$ROOT_NATIVE" bash "$FAKE_ROOT/hooks/session-start-pulse.sh" >/dev/null 2>&1

PR_FILE="$FAKE_HOME/.zensu/plugin-root"
GOT="$(cat "$PR_FILE" 2>/dev/null || echo MISSING)"
if [ "$GOT" = "$ROOT_NATIVE" ]; then
  check "N2 session-start-pulse.sh persists plugin-root under native HOME/CLAUDE_PLUGIN_ROOT (agent-faithful)" PASS
else
  check "N2 pulse plugin-root persist (got '$GOT' expected '$ROOT_NATIVE')" FAIL
fi

echo "----"
echo "test-native-path-resolution: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
