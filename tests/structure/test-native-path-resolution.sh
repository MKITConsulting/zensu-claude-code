set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/resolve-session-id.js"
EXPORT_ROOT="$PLUGIN_DIR/hooks/session-start-export-root.sh"

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
printf '# fixture helper\n' > "$FAKE_ROOT/hooks/lib/zensu-log.sh"
cp "$EXPORT_ROOT" "$FAKE_ROOT/hooks/session-start-export-root.sh"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
ENV_FILE="$FAKE_HOME/session-env.sh"
: > "$ENV_FILE"

ROOT_NATIVE="$(native "$FAKE_ROOT")"
ROOT_CANON_NATIVE="$(native "$(cd "$FAKE_ROOT" && pwd -P)")"
HOME_NATIVE="$(native "$FAKE_HOME")"
HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$ROOT_NATIVE" CLAUDE_ENV_FILE="$(native "$ENV_FILE")" bash "$FAKE_ROOT/hooks/session-start-export-root.sh" >/dev/null 2>&1

GOT="$(bash -c '. "$1"; printf "%s" "${ZENSU_CLAUDE_PLUGIN_ROOT:-}"' _ "$ENV_FILE" 2>/dev/null || echo MISSING)"
if [ "$GOT" = "$ROOT_CANON_NATIVE" ]; then
  check "N2 SessionStart exporter persists the native plugin root through CLAUDE_ENV_FILE (agent-faithful)" PASS
else
  check "N2 session export (got '$GOT' expected '$ROOT_CANON_NATIVE')" FAIL
fi

# Exercise the Git Bash conversion branch on every CI host. A shim keeps this
# regression deterministic even when the host does not provide cygpath.
SHIM_DIR="$TMP/cygpath-shim"
mkdir -p "$SHIM_DIR"
printf '%s\n' \
  '#!/bin/bash' \
  '[ "$1" = "-m" ] || exit 64' \
  'case "${FAKE_CYGPATH_MODE:-ok}" in' \
  '  ok) printf '\''%s/.\n'\'' "$2" ;;' \
  '  empty) exit 0 ;;' \
  '  nonzero) exit 65 ;;' \
  '  invalid) printf '\''%s\n'\'' "$FAKE_CYGPATH_INVALID_ROOT" ;;' \
  '  *) exit 66 ;;' \
  'esac' \
  > "$SHIM_DIR/cygpath"
chmod +x "$SHIM_DIR/cygpath"
SIM_ENV_FILE="$FAKE_HOME/session-env-simulated-windows.sh"
: > "$SIM_ENV_FILE"
PATH="$SHIM_DIR:$PATH" HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$ROOT_NATIVE" \
  CLAUDE_ENV_FILE="$SIM_ENV_FILE" bash "$FAKE_ROOT/hooks/session-start-export-root.sh" >/dev/null 2>&1
SIM_GOT="$(bash -c '. "$1"; printf "%s" "${ZENSU_CLAUDE_PLUGIN_ROOT:-}"' _ "$SIM_ENV_FILE" 2>/dev/null || echo MISSING)"
SIM_EXPECTED="$(cd "$FAKE_ROOT" && pwd -P)/."
if [ "$SIM_GOT" = "$SIM_EXPECTED" ]; then
  check "N3 SessionStart exporter publishes a resolvable cygpath conversion of the same root" PASS
else
  check "N3 cygpath conversion (got '$SIM_GOT' expected '$SIM_EXPECTED')" FAIL
fi

# Every cygpath failure mode must invalidate a stale binding. The invalid case
# redirects to a different, otherwise valid plugin-shaped directory so only a
# physical-root round trip can reject it.
OTHER_ROOT="$TMP/other-plugin-root"
mkdir -p "$OTHER_ROOT/hooks/lib"
printf '# other fixture helper\n' > "$OTHER_ROOT/hooks/lib/zensu-log.sh"
for CASE in empty nonzero invalid; do
  BAD_ENV_FILE="$FAKE_HOME/session-env-bad-$CASE.sh"
  printf '%s\n' 'export ZENSU_CLAUDE_PLUGIN_ROOT=/stale/plugin-root' > "$BAD_ENV_FILE"
  FAKE_CYGPATH_MODE="$CASE" FAKE_CYGPATH_INVALID_ROOT="$OTHER_ROOT" \
    PATH="$SHIM_DIR:$PATH" HOME="$HOME_NATIVE" CLAUDE_PLUGIN_ROOT="$ROOT_NATIVE" \
    CLAUDE_ENV_FILE="$BAD_ENV_FILE" bash "$FAKE_ROOT/hooks/session-start-export-root.sh" >/dev/null 2>&1
  BAD_RC=$?
  BAD_GOT="$(bash -c '. "$1"; printf "%s" "${ZENSU_CLAUDE_PLUGIN_ROOT:-}"' _ "$BAD_ENV_FILE" 2>/dev/null || echo MISSING)"
  case "$CASE" in
    empty) LABEL="N4 empty cygpath output fails closed" ;;
    nonzero) LABEL="N5 nonzero cygpath exit fails closed" ;;
    invalid) LABEL="N6 cygpath output resolving to another plugin root fails closed" ;;
  esac
  if [ "$BAD_RC" -ne 0 ] && [ -z "$BAD_GOT" ]; then
    check "$LABEL" PASS
  else
    check "$LABEL (rc=$BAD_RC exported '$BAD_GOT')" FAIL
  fi
done

echo "----"
echo "test-native-path-resolution: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
