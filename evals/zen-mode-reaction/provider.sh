#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
TREE_ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)" || exit 2
WRAPPER="$TREE_ROOT/scripts/claude-promptfoo-wrapper.sh"
DENY="$EVAL_DIR/lib/deny-tools.js"
EVAL_CONFIG="$EVAL_DIR/eval-config.json"
CLAUDE_HOME="${ZEN_EVAL_CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"

die() { printf 'zen-mode eval provider: %s\n' "$1" >&2; exit "${2:-70}"; }

for name in $(compgen -e); do
  case "$name" in ZENSU_*|CLAUDE_PLUGIN_ROOT|CLAUDE_PLUGIN_DATA|CLAUDE_PROJECT_DIR|CLAUDE_ENV_FILE) unset "$name" ;; esac
done

command -v node >/dev/null 2>&1 || die "node is not on PATH" 127
[ -f "$EVAL_CONFIG" ] || die "eval-config.json is missing"
[ -f "$DENY" ] || die "lib/deny-tools.js is missing"
[ -f "$WRAPPER" ] || die "scripts/claude-promptfoo-wrapper.sh is missing"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zen-eval-XXXXXX")" || die "cannot create a run directory"
trap 'rm -rf "$RUN_DIR"' EXIT

node - "$RUN_DIR/settings.json" "$DENY" "$CLAUDE_HOME/settings.json" "$EVAL_CONFIG" <<'NODE' || die "cannot write the run settings"
const fs = require('node:fs');
const [file, deny, settings, config] = process.argv.slice(2);
const quote = (p) => `'${p.split("'").join("'\\''")}'`;
const enabledPlugins = { 'zensu@zensu': false };
try {
  const user = JSON.parse(fs.readFileSync(settings, 'utf8')).enabledPlugins || {};
  for (const [name, on] of Object.entries(user)) if (on === true) enabledPlugins[name] = false;
} catch (_) {}
const hooks = { PreToolUse: [{ matcher: '*', hooks: [{ type: 'command', command: `node ${quote(deny)}` }] }] };
const fd = fs.openSync(file, 'wx', 0o600);
try { fs.writeFileSync(fd, `${JSON.stringify({ env: { ZENSU_CONFIG: config }, hooks, enabledPlugins })}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
NODE

if [ "${ZEN_EVAL_DRY_RUN:-0}" = "1" ]; then
  printf 'ZEN_EVAL_DRY_RUN: settings %s\n' "$(cat "$RUN_DIR/settings.json")"
  exit 0
fi

export ZENSU_CONFIG="$EVAL_CONFIG"
export ZENSU_WRAPPER_SETTINGS="$RUN_DIR/settings.json"
bash "$WRAPPER" "${1:-}" "${2:-"{}"}"
