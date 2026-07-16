#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNTIME_DIR="$PLUGIN_DIR/mcp-runtime"
# Node-based tests pass native Windows temp paths into Git Bash. Normalize only
# that drive-letter form; regular POSIX paths and production plugin paths stay untouched.
if command -v cygpath >/dev/null 2>&1; then
  case "$RUNTIME_DIR" in
    [A-Za-z]:[\\/]*) RUNTIME_DIR="$(cygpath -u "$RUNTIME_DIR")" ;;
  esac
fi
PACKAGE_FILE="$RUNTIME_DIR/package.json"
LOCK_FILE="$RUNTIME_DIR/package-lock.json"
PROXY="$PLUGIN_DIR/scripts/playwright-mcp-proxy.js"
MATERIALIZE_ONLY_FLAG="--zensu-install-runtime"

RUNTIME_GENERATION=""
CHILD_PID=""
RECEIVED_SIGNAL=""

for forbidden_test_control in \
  ZENSU_MCP_TEST_MODE \
  ZENSU_MCP_TEST_PASSTHROUGH \
  ZENSU_MCP_RUNTIME_DIR_OVERRIDE; do
  if [ -n "${!forbidden_test_control:-}" ]; then
    echo "zensu Playwright MCP: test-only launcher controls are not supported" >&2
    exit 2
  fi
done

SANITIZED_HOME=""

cleanup_runtime() {
  if [ -n "$RUNTIME_GENERATION" ] && [ -e "$RUNTIME_GENERATION" ]; then
    rm -rf "$RUNTIME_GENERATION"
  fi
  if [ -n "$SANITIZED_HOME" ] && [ -e "$SANITIZED_HOME" ]; then
    rm -rf "$SANITIZED_HOME"
  fi
}

signal_exit_code() {
  case "$1" in
    HUP) printf '129\n' ;;
    INT) printf '130\n' ;;
    TERM) printf '143\n' ;;
  esac
}

handle_signal() {
  local signal="$1"
  RECEIVED_SIGNAL="$signal"
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill -s "$signal" "$CHILD_PID" 2>/dev/null || true
  else
    exit "$(signal_exit_code "$signal")"
  fi
}

run_child() {
  local child_status
  "$@" <&0 >&1 2>&2 &
  CHILD_PID=$!
  set +e
  while :; do
    wait "$CHILD_PID"
    child_status=$?
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      break
    fi
  done
  set -e
  CHILD_PID=""
  if [ -n "$RECEIVED_SIGNAL" ]; then
    child_status="$(signal_exit_code "$RECEIVED_SIGNAL")"
  fi
  return "$child_status"
}

run_sanitized_child() {
  local env_args=(
    "PATH=$PATH"
    "HOME=$SANITIZED_HOME"
    "XDG_CONFIG_HOME=$SANITIZED_HOME/.config"
    "XDG_CACHE_HOME=$SANITIZED_HOME/.cache"
    "XDG_DATA_HOME=$SANITIZED_HOME/.local/share"
  )
  local name value
  for name in \
    TMPDIR SHELL TERM LANG LC_ALL CI \
    HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy \
    SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS \
    ZENSU_VERIFY_NAVIGATION_POLICY_V1; do
    value="${!name-}"
    [ -z "$value" ] || env_args+=( "$name=$value" )
  done
  run_child env -i "${env_args[@]}" "$@"
}

trap cleanup_runtime EXIT
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "zensu Playwright MCP: node and npm are required" >&2
  exit 127
fi
SANITIZED_HOME="$(mktemp -d "${TMPDIR:-/tmp}/zensu-playwright-home.XXXXXX")"
chmod 700 "$SANITIZED_HOME"
if [ ! -f "$PACKAGE_FILE" ] || [ -L "$PACKAGE_FILE" ] \
  || [ ! -f "$LOCK_FILE" ] || [ -L "$LOCK_FILE" ]; then
  echo "zensu Playwright MCP: regular lockfile-backed runtime metadata is required" >&2
  exit 2
fi

# Policy validation runs only the checked-in broker and never loads the upstream
# npm package graph, so it needs no generated runtime.
if [ "${1:-}" = "--check-policy" ]; then
  run_sanitized_child node "$PROXY" --runtime-dir "$RUNTIME_DIR" "$@"
  exit $?
fi

materialize_runtime() {
  local temp_base generation_real bin_target npm_status
  temp_base="${TMPDIR:-/tmp}"
  RUNTIME_GENERATION="$(mktemp -d "$temp_base/zensu-playwright-mcp.XXXXXX")"
  generation_real="$(cd "$RUNTIME_GENERATION" && pwd -P)"
  RUNTIME_GENERATION="$generation_real"
  case "$RUNTIME_GENERATION" in
    "$PLUGIN_DIR"|"$PLUGIN_DIR"/*)
      echo "zensu Playwright MCP: isolated runtime must be outside the plugin root" >&2
      exit 2
      ;;
  esac

  # Copy only the Session-Control-bound npm metadata. Shared node_modules is
  # neither read nor written; each invocation receives a new private graph.
  cp "$PACKAGE_FILE" "$RUNTIME_GENERATION/package.json"
  cp "$LOCK_FILE" "$RUNTIME_GENERATION/package-lock.json"
  echo "zensu Playwright MCP: materializing isolated integrity-locked runtime" >&2
  npm_status=0
  run_sanitized_child npm ci --prefix "$RUNTIME_GENERATION" --ignore-scripts --no-audit --no-fund >&2 || npm_status=$?
  if [ "$npm_status" -ne 0 ]; then
    echo "zensu Playwright MCP: npm ci failed" >&2
    exit "$npm_status"
  fi

  BIN="$RUNTIME_GENERATION/node_modules/.bin/playwright-mcp"
  if [ ! -d "$RUNTIME_GENERATION/node_modules" ] \
    || [ -L "$RUNTIME_GENERATION/node_modules" ] || [ ! -x "$BIN" ]; then
    echo "zensu Playwright MCP: npm ci did not materialize the pinned executable" >&2
    exit 2
  fi
  bin_target="$(node -e 'const fs=require("node:fs"); process.stdout.write(fs.realpathSync(process.argv[1]))' "$BIN")"
  case "$bin_target" in
    "$RUNTIME_GENERATION/node_modules"/*) ;;
    *)
      echo "zensu Playwright MCP: pinned executable escapes its isolated runtime" >&2
      exit 2
      ;;
  esac
}

materialize_runtime

if [ "${1:-}" = "$MATERIALIZE_ONLY_FLAG" ]; then
  exit 0
fi

child_status=0
if [ "${1:-}" = "install-browser" ]; then
  run_sanitized_child "$BIN" install-browser || child_status=$?
else
  run_sanitized_child node "$PROXY" --runtime-dir "$RUNTIME_GENERATION" "$@" || child_status=$?
fi
exit "$child_status"
