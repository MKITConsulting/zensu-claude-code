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

PROJ="/agent/native/repo"
SAN="$(sanitize "$PROJ")"
PDIR="$TMP/projects/$SAN"
mkdir -p "$PDIR"
UUID="a1a1a1a1-2b2b-3c3c-4d4d-5e5e5e5e5e5e"
: > "$PDIR/$UUID.jsonl"

NPROJ="$(native "$TMP/projects")"
NHELP="$(native "$HELPER")"
echo "  DIAG bash_pdir=$PDIR"
echo "  DIAG native_projects=$NPROJ"
ls -la "$PDIR" 2>&1 | sed 's/^/  DIAG ls /'
ZENSU_PROJECTS_DIR="$NPROJ" CLAUDE_PROJECT_DIR="$PROJ" node -e '
  const fs=require("fs"), path=require("path");
  const base=process.env.ZENSU_PROJECTS_DIR;
  const sub=String(process.env.CLAUDE_PROJECT_DIR).replace(/[^A-Za-z0-9_-]/g,"-");
  const dir=path.join(base, sub);
  process.stdout.write("  DIAG node_dir="+dir+"\n");
  process.stdout.write("  DIAG node_exists="+fs.existsSync(dir)+"\n");
  try { process.stdout.write("  DIAG node_readdir="+JSON.stringify(fs.readdirSync(dir))+"\n"); }
  catch(e){ process.stdout.write("  DIAG node_readdir_ERR="+e.message+"\n"); }
'
OUT="$(ZENSU_PROJECTS_DIR="$NPROJ" CLAUDE_PROJECT_DIR="$PROJ" node "$NHELP")"
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
