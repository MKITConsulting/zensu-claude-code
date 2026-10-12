#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
TREE_ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)" || exit 2
WRAPPER="$TREE_ROOT/scripts/claude-promptfoo-wrapper.sh"
CAPTURE="$EVAL_DIR/lib/capture-injections.sh"
INJECT="$EVAL_DIR/lib/inject-context.js"
PROBE="$EVAL_DIR/lib/decision-probe.js"
EVAL_CONFIG="$EVAL_DIR/eval-config.json"
SOURCES=' none ask tdd-config direct-config router nonce '
CLAUDE_HOME="${ROUTE_EVAL_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
NL=$'\n'

die() { printf 'route-eval provider: %s\n' "$1" >&2; exit "${2:-70}"; }

PROMPT="${1:-}"
OPTIONS_JSON="${2:-"{}"}"
FIRST_LINE="${PROMPT%%"$NL"*}"
case "$FIRST_LINE" in
  'route-eval-source: '*) ;;
  *) die "the prompt must open with the line 'route-eval-source: <source>'" 64 ;;
esac
SOURCE="${FIRST_LINE#route-eval-source: }"
case "$SOURCES" in *" $SOURCE "*) ;; *) die "unknown route source '$SOURCE'" 64 ;; esac
[ "$PROMPT" != "$FIRST_LINE" ] || die "the prompt carries no user message" 64
MESSAGE="${PROMPT#*"$NL"}"
while [ "${MESSAGE%"$NL"}" != "$MESSAGE" ]; do MESSAGE="${MESSAGE%"$NL"}"; done
[ -n "$MESSAGE" ] || die "the user message is empty" 64

for name in $(compgen -e); do
  case "$name" in ZENSU_*|CLAUDE_PLUGIN_ROOT|CLAUDE_PLUGIN_DATA|CLAUDE_PROJECT_DIR|CLAUDE_ENV_FILE) unset "$name" ;; esac
done

command -v node >/dev/null 2>&1 || die "node is not on PATH" 127
[ -f "$EVAL_CONFIG" ] || die "eval-config.json is missing" 70

LIVE_ROOT="$(node -e '
  const fs = require("node:fs");
  const [installed, settings] = process.argv.slice(1);
  let enabled = false;
  try { enabled = JSON.parse(fs.readFileSync(settings, "utf8")).enabledPlugins["zensu@zensu"] === true; } catch (_) { enabled = false; }
  if (!enabled) process.exit(3);
  try {
    const entries = JSON.parse(fs.readFileSync(installed, "utf8")).plugins["zensu@zensu"];
    const entry = Array.isArray(entries) ? entries.find((e) => e && e.scope === "user") : null;
    const root = entry && entry.installPath;
    if (!root || !fs.statSync(root).isDirectory()) process.exit(4);
    process.stdout.write(root);
  } catch (_) { process.exit(4); }
' "$CLAUDE_HOME/plugins/installed_plugins.json" "$CLAUDE_HOME/settings.json")"
case "$?" in
  0) ;;
  3) die "zensu@zensu is not enabled in $CLAUDE_HOME/settings.json; the Skill tool needs the installed plugin" 78 ;;
  *) die "zensu@zensu has no user-scoped install path in $CLAUDE_HOME/plugins/installed_plugins.json" 78 ;;
esac

HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P)" || die "HOME does not resolve to a directory" 64
RUN_PARENT="${ROUTE_EVAL_RUN_PARENT:-$HOME/.cache/zensu-route-eval}"
mkdir -p "$RUN_PARENT" && chmod 700 "$RUN_PARENT" || die "cannot prepare $RUN_PARENT"
RUN_PARENT_REAL="$(cd "$RUN_PARENT" && pwd -P)" || die "cannot resolve $RUN_PARENT"
case "$RUN_PARENT_REAL" in
  "$HOME_REAL"/*) ;;
  *) die "the run directory parent $RUN_PARENT_REAL must lie under HOME, the only place the eval sandbox lets the hooks write" 64 ;;
esac
RUN_DIR="$(mktemp -d "$RUN_PARENT_REAL/run-XXXXXX")" || die "cannot create a run directory"
trap 'rm -rf "$RUN_DIR"' EXIT

bash "$CAPTURE" silence "$LIVE_ROOT" "$EVAL_CONFIG" "$RUN_DIR" "$MESSAGE" >/dev/null || die "the installed runtime at $LIVE_ROOT is not silent under eval-config.json" 70
bash "$CAPTURE" capture "$SOURCE" "$TREE_ROOT" "$RUN_DIR" "$MESSAGE" >/dev/null || die "capturing the '$SOURCE' line from $TREE_ROOT failed" 70

node - "$RUN_DIR/settings.json" "$SOURCE" "$INJECT" "$PROBE" "$CLAUDE_HOME/settings.json" "$EVAL_CONFIG" <<'NODE' || die "cannot write the run settings"
const fs = require('node:fs');
const [file, source, inject, probe, settings, config] = process.argv.slice(2);
const quote = (p) => `'${p.split("'").join("'\\''")}'`;
const hooks = { PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: `node ${quote(probe)}` }] }] };
if (source !== 'none') hooks.UserPromptSubmit = [{ hooks: [{ type: 'command', command: `node ${quote(inject)}` }] }];
const enabledPlugins = {};
try {
  const user = JSON.parse(fs.readFileSync(settings, 'utf8')).enabledPlugins || {};
  for (const [name, on] of Object.entries(user)) if (on === true && name !== 'zensu@zensu') enabledPlugins[name] = false;
} catch (_) {}
const fd = fs.openSync(file, 'wx', 0o600);
try { fs.writeFileSync(fd, `${JSON.stringify({ env: { ZENSU_CONFIG: config }, hooks, enabledPlugins })}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
NODE

HOOK_NAME="$(node -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).hook || "")' "$RUN_DIR/capture.json")" || die "cannot read capture.json"
CAPTURE_LINE="$(node -e '
  const fs = require("node:fs");
  const [dir, live] = process.argv.slice(1);
  const value = JSON.parse(fs.readFileSync(`${dir}/capture.json`, "utf8"));
  const silence = JSON.parse(fs.readFileSync(`${dir}/silence.json`, "utf8"));
  value.live = { root: live, version: silence.version, silent_hooks: silence.hooks.length, leaks: silence.leaks.length, control_chars: silence.control.chars, router_control_chars: silence.router_control ? silence.router_control.chars : 0 };
  process.stdout.write(JSON.stringify(value));
' "$RUN_DIR" "$LIVE_ROOT")" || die "cannot assemble the capture line"

if [ "${ROUTE_EVAL_DRY_RUN:-0}" = "1" ]; then
  printf 'ROUTE_EVAL_DRY_RUN: settings %s\n' "$(cat "$RUN_DIR/settings.json")"
  printf 'ROUTE_EVAL_DRY_RUN: env ZENSU_CONFIG=%s ZENSU_WRAPPER_SETTINGS=%s ZENSU_ROUTE_EVAL_DIR=<run> ZENSU_ROUTE_EVAL_HOOK=%s\n' "$EVAL_CONFIG" '<run>/settings.json' "$HOOK_NAME"
  printf 'ROUTE_EVAL_DRY_RUN: message %s\n' "$MESSAGE"
  printf '[route-eval-capture] %s\n' "$CAPTURE_LINE"
  exit 0
fi

export ZENSU_CONFIG="$EVAL_CONFIG"
export ZENSU_WRAPPER_SETTINGS="$RUN_DIR/settings.json"
export ZENSU_ROUTE_EVAL_DIR="$RUN_DIR"
export ZENSU_ROUTE_EVAL_HOOK="$HOOK_NAME"
bash "$WRAPPER" "$MESSAGE" "$OPTIONS_JSON"
RC=$?
if [ -f "$RUN_DIR/hook.log" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    printf '[route-eval-hook] %s\n' "$line"
  done < "$RUN_DIR/hook.log"
fi
printf '[route-eval-capture] %s\n' "$CAPTURE_LINE"
exit "$RC"
