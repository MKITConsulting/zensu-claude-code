#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PLUGIN_DIR/mcp-runtime"
if [ "${ZENSU_MCP_TEST_MODE:-0}" = "1" ] && [ -n "${ZENSU_MCP_RUNTIME_DIR_OVERRIDE:-}" ]; then
  RUNTIME_DIR="$ZENSU_MCP_RUNTIME_DIR_OVERRIDE"
fi
LOCK_FILE="$RUNTIME_DIR/package-lock.json"
BIN="$RUNTIME_DIR/node_modules/.bin/playwright-mcp"
PROXY="$PLUGIN_DIR/scripts/playwright-mcp-proxy.js"
STAMP="$RUNTIME_DIR/node_modules/.zensu-lock-sha256"
INSTALL_LOCK="$RUNTIME_DIR/.install.lock"
INSTALL_ONLY_FLAG="--zensu-install-runtime"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "zensu Playwright MCP: node and npm are required" >&2
  exit 127
fi
if [ ! -f "$RUNTIME_DIR/package.json" ] || [ ! -f "$LOCK_FILE" ]; then
  echo "zensu Playwright MCP: lockfile-backed runtime metadata is missing" >&2
  exit 2
fi

LOCK_HASH="$(node -e '
  const crypto = require("node:crypto");
  const fs = require("node:fs");
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$LOCK_FILE")"

needs_install() {
  local installed_hash
  installed_hash="$(sed -n '1p' "$STAMP" 2>/dev/null || true)"
  [ ! -x "$BIN" ] || [ "$installed_hash" != "$LOCK_HASH" ]
}

install_if_needed() {
  if needs_install; then
    echo "zensu Playwright MCP: installing integrity-locked runtime (first use or lockfile update)" >&2
    npm ci --prefix "$RUNTIME_DIR" --ignore-scripts --no-audit --no-fund >&2
    printf '%s\n' "$LOCK_HASH" >"$STAMP"
  fi
}

if [ "${1:-}" = "$INSTALL_ONLY_FLAG" ]; then
  install_if_needed
  exit 0
fi

if needs_install; then
  # Kernel advisory locks are released automatically on normal exit, signals, and SIGKILL;
  # a leftover lock file is inert, so there is no stale-owner reclamation race.
  if command -v lockf >/dev/null 2>&1; then
    lockf -k "$INSTALL_LOCK" "$0" "$INSTALL_ONLY_FLAG"
  elif command -v flock >/dev/null 2>&1; then
    flock "$INSTALL_LOCK" "$0" "$INSTALL_ONLY_FLAG"
  else
    echo "zensu Playwright MCP: lockf or flock is required for a safe runtime install" >&2
    exit 69
  fi
fi

if [ "${1:-}" = "install-browser" ]; then
  exec "$BIN" install-browser
fi
if [ "${ZENSU_MCP_TEST_MODE:-0}" = "1" ] && [ "${ZENSU_MCP_TEST_PASSTHROUGH:-0}" = "1" ]; then
  exec "$BIN" "$@"
fi
exec node "$PROXY" --runtime-dir "$RUNTIME_DIR" "$@"
