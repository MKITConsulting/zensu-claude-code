#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$SCRIPT_DIR/fixture-server.js"
STATE_DIR="$ROOT_DIR/.verify-runtime"
PID_FILE="$STATE_DIR/server.pid"
TOKEN_FILE="$STATE_DIR/server.token"
URL_FILE="$STATE_DIR/base-url"
LEASE_FILE="$STATE_DIR/lease"
LOG_FILE="$STATE_DIR/server.log"
BACKEND_PORT_FILE="$STATE_DIR/backend-port"

fail() {
  echo "fixture-runtime: $*" >&2
  exit 1
}

validate_state_dir() {
  [ ! -L "$STATE_DIR" ] || fail "refusing symlinked state directory"
  if [ -e "$STATE_DIR" ] && [ ! -d "$STATE_DIR" ]; then
    fail "state path exists but is not a directory"
  fi
}

read_pid() {
  [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ] || return 1
  local pid
  pid="$(sed -n '1p' "$PID_FILE")"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

read_token() {
  [ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ] || return 1
  local token
  token="$(sed -n '1p' "$TOKEN_FILE")"
  case "$token" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  printf '%s\n' "$token"
}

owns_pid() {
  local pid="$1" token="$2" command_line
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    *"$SERVER --lease-token=$token"*) return 0 ;;
    *) return 1 ;;
  esac
}

runtime_url() {
  [ -f "$URL_FILE" ] && [ ! -L "$URL_FILE" ] || return 1
  local base_url
  base_url="$(sed -n '1p' "$URL_FILE")"
  case "$base_url" in
    http://127.0.0.1:*) printf '%s\n' "$base_url" ;;
    *) return 1 ;;
  esac
}

ready() {
  local base_url pid token
  pid="$(read_pid)" || return 1
  token="$(read_token)" || return 1
  owns_pid "$pid" "$token" || return 1
  base_url="$(runtime_url)" || return 1
  curl --fail --silent --show-error --max-time 1 "$base_url/health" >/dev/null
}

down() {
  validate_state_dir
  local pid="" token=""
  pid="$(read_pid 2>/dev/null || true)"
  token="$(read_token 2>/dev/null || true)"

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    [ -n "$token" ] || fail "owned PID has no valid lease token; refusing to stop it"
    owns_pid "$pid" "$token" || fail "PID $pid is not the owned fixture server; refusing to stop it"
    if ! kill "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
      fail "owned fixture PID $pid could not be stopped"
    fi
    local attempt=0
    while [ "$attempt" -lt 40 ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
      attempt=$((attempt + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      owns_pid "$pid" "$token" || fail "PID $pid changed ownership during teardown"
      if ! kill -9 "$pid" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
        fail "owned fixture PID $pid could not be force-stopped"
      fi
    fi
  fi

  rm -f "$PID_FILE" "$TOKEN_FILE" "$URL_FILE" "$LEASE_FILE" "$LOG_FILE" "$BACKEND_PORT_FILE"
  rmdir "$STATE_DIR" 2>/dev/null || true
  echo "fixture-runtime: stopped"
}

up() {
  validate_state_dir
  local pid="" token=""
  pid="$(read_pid 2>/dev/null || true)"
  token="$(read_token 2>/dev/null || true)"
  if [ -n "$pid" ] && [ -n "$token" ] && owns_pid "$pid" "$token" && ready; then
    echo "fixture-runtime: started" >&2
    runtime_url
    return 0
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    fail "PID file points at a live process not owned by this fixture"
  fi

  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  rm -f "$PID_FILE" "$TOKEN_FILE" "$URL_FILE" "$LEASE_FILE" "$LOG_FILE" "$BACKEND_PORT_FILE"
  : >"$LEASE_FILE"
  chmod 600 "$LEASE_FILE"

  token="$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')"
  printf '%s\n' "$token" >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  case "${ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN:-}" in
    ''|*[!a-f0-9]*) fail "parent port reservation token is invalid" ;;
  esac
  [ "${#ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN}" = 32 ] \
    || fail "parent port reservation token is invalid"
  case "${ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF:-}" in /*) ;; *) fail "parent handoff path is invalid" ;; esac
  case "${ZENSU_VERIFY_FIXTURE_RESERVATION_ACK:-}" in /*) ;; *) fail "parent acknowledgement path is invalid" ;; esac
  case "${ZENSU_VERIFY_FIXTURE_PORT:-}" in ''|*[!0-9]*) fail "parent public port is invalid" ;; esac
  [ "$ZENSU_VERIFY_FIXTURE_PORT" -ge 1024 ] && [ "$ZENSU_VERIFY_FIXTURE_PORT" -le 65535 ] \
    || fail "parent public port is invalid"
  [ ! -e "$ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF" ] && [ ! -e "$ZENSU_VERIFY_FIXTURE_RESERVATION_ACK" ] \
    || fail "parent port reservation state is not fresh"

  ZENSU_FIXTURE_BACKEND_PORT_FILE="$BACKEND_PORT_FILE" \
  ZENSU_FIXTURE_LEASE_FILE="$LEASE_FILE" \
    node "$SERVER" "--lease-token=$token" >"$LOG_FILE" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$PID_FILE"
  chmod 600 "$PID_FILE"
  local backend_attempt=0
  while [ "$backend_attempt" -lt 200 ]; do
    [ -s "$BACKEND_PORT_FILE" ] && owns_pid "$pid" "$token" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
    backend_attempt=$((backend_attempt + 1))
  done
  [ -s "$BACKEND_PORT_FILE" ] && owns_pid "$pid" "$token" || {
    tail -20 "$LOG_FILE" >&2 || true
    down
    fail "backend server did not bind its private loopback port"
  }
  local backend_port
  backend_port="$(sed -n '1p' "$BACKEND_PORT_FILE")"
  case "$backend_port" in ''|*[!0-9]*) down; fail "backend port state is invalid" ;; esac
  printf '{"token":"%s","targetPort":%s}\n' "$ZENSU_VERIFY_FIXTURE_RESERVATION_TOKEN" "$backend_port" \
    >"$ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF"
  chmod 600 "$ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF"
  local handoff_attempt=0
  while [ "$handoff_attempt" -lt 200 ]; do
    [ -f "$ZENSU_VERIFY_FIXTURE_RESERVATION_ACK" ] && [ ! -L "$ZENSU_VERIFY_FIXTURE_RESERVATION_ACK" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
    handoff_attempt=$((handoff_attempt + 1))
  done
  env ACK="$ZENSU_VERIFY_FIXTURE_RESERVATION_ACK" EXPECTED_PORT="$backend_port" node -e '
    const fs = require("node:fs");
    const info = fs.lstatSync(process.env.ACK);
    const value = JSON.parse(fs.readFileSync(process.env.ACK, "utf8"));
    if (!info.isFile() || info.isSymbolicLink() || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify(["targetPort", "version"])
        || value.version !== 1 || value.targetPort !== Number(process.env.EXPECTED_PORT)) process.exit(2);
  ' || { down; fail "parent port reservation handoff was not acknowledged"; }
  printf 'http://127.0.0.1:%s\n' "$ZENSU_VERIFY_FIXTURE_PORT" >"$URL_FILE"
  chmod 600 "$URL_FILE"

  local attempt=0
  while [ "$attempt" -lt 100 ]; do
    if owns_pid "$pid" "$token" && ready; then
      echo "fixture-runtime: started" >&2
      runtime_url
      return 0
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done

  tail -20 "$LOG_FILE" >&2 || true
  down
  fail "server did not become ready"
}

case "${1:-}" in
  up) up ;;
  ready) ready ;;
  url) runtime_url ;;
  down) down ;;
  *) fail "usage: $0 {up|ready|url|down}" ;;
esac
