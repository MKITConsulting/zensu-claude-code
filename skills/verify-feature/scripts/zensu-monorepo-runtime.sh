#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
RUN_DIR_INPUT="${2:-}"
WORKTREE_INPUT="${3:-}"

fail() { echo "zensu verify runtime: $*" >&2; exit 1; }
[ -n "$ACTION" ] && [ -n "$RUN_DIR_INPUT" ] && [ -n "$WORKTREE_INPUT" ] \
  || fail "usage: zensu-monorepo-runtime.sh <planned-origin|up|ready|origin|seed|down> <run-dir> <worktree>"

[ -d "$WORKTREE_INPUT" ] || fail "worktree does not exist"
WORKTREE="$(cd "$WORKTREE_INPUT" && pwd -P)"
EXPECTED_PARENT="$WORKTREE/.zensu/verify-feature-runs"
[ -d "$EXPECTED_PARENT" ] && [ ! -L "$WORKTREE/.zensu" ] && [ ! -L "$EXPECTED_PARENT" ] \
  || fail "run parent is missing or unsafe"
[ -d "$RUN_DIR_INPUT" ] && [ ! -L "$RUN_DIR_INPUT" ] || fail "run directory is missing or unsafe"
RUN_DIR="$(cd "$RUN_DIR_INPUT" && pwd -P)"
case "$RUN_DIR" in "$EXPECTED_PARENT"/*) ;; *) fail "run directory is outside the verified worktree" ;; esac

PLUGIN_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SUPERVISOR="$PLUGIN_ROOT/scripts/process-supervisor.js"
STATE="$RUN_DIR/zensu-runtime.json"
SECRETS="$RUN_DIR/zensu-runtime.secrets"
BACKEND_READY="$RUN_DIR/backend-supervisor.ready"
FRONTEND_READY="$RUN_DIR/frontend-supervisor.ready"
LOG_BACKEND="$RUN_DIR/backend.log"
LOG_FRONTEND="$RUN_DIR/frontend.log"

for marker in backend/cmd/zensu backend/Makefile frontend/package.json frontend/pnpm-lock.yaml; do
  [ -e "$WORKTREE/$marker" ] || fail "required repository marker is missing"
done
[ -f "$SUPERVISOR" ] && [ ! -L "$SUPERVISOR" ] || fail "runtime supervisor is unavailable"

worktree_key() { printf '%s' "$WORKTREE" | cksum | cut -d' ' -f1; }

state_values() {
  [ -f "$STATE" ] && [ ! -L "$STATE" ] || fail "runtime state is unavailable"
  node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const keys = Object.keys(value || {}).sort();
    const expected = ["backendPort", "container", "frontendPort", "origin", "pgPort", "runId", "version"];
    const ports = [value.pgPort, value.backendPort, value.frontendPort];
    if (JSON.stringify(keys) !== JSON.stringify(expected) || value.version !== 1
        || !/^[a-f0-9]{12}$/.test(value.runId || "")
        || typeof value.container !== "string"
        || ports.some((port) => !Number.isInteger(port) || port < 1024 || port > 65535)
        || new Set(ports).size !== ports.length
        || value.origin !== `http://127.0.0.1:${value.frontendPort}`) process.exit(2);
    process.stdout.write([value.runId, value.container, ...ports, value.origin].join("\t"));
  ' "$STATE" || fail "runtime state is invalid"
}

load_secrets() {
  [ -f "$SECRETS" ] && [ ! -L "$SECRETS" ] || fail "runtime secrets are unavailable"
  IFS=$'\t' read -r DB_PASSWORD JWT_SECRET RUNTIME_LEASE <<<"$(node -e '
    const fs = require("node:fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split(/\n/).filter(Boolean);
    const expected = new Set(["DB_PASSWORD", "JWT_SECRET", "RUNTIME_LEASE"]);
    const values = new Map();
    for (const line of lines) {
      const match = /^([A-Z_]+)=([a-f0-9]+)$/.exec(line);
      if (!match || !expected.has(match[1]) || values.has(match[1])) process.exit(2);
      values.set(match[1], match[2]);
    }
    if (values.size !== expected.size) process.exit(2);
    process.stdout.write([values.get("DB_PASSWORD"), values.get("JWT_SECRET"), values.get("RUNTIME_LEASE")].join("\t"));
  ' "$SECRETS")" || fail "runtime secret state is invalid"
  [[ "$DB_PASSWORD" =~ ^[a-f0-9]{48}$ ]] && [[ "$JWT_SECRET" =~ ^[a-f0-9]{64}$ ]] \
    && [[ "$RUNTIME_LEASE" =~ ^[a-f0-9]{64}$ ]] || fail "runtime secret state is invalid"
}

lease_hash() {
  env RUNTIME_LEASE="$RUNTIME_LEASE" node -e '
    const crypto = require("node:crypto");
    process.stdout.write(crypto.createHash("sha256").update(process.env.RUNTIME_LEASE).digest("hex"));
  '
}

expected_container() {
  printf 'zensu-verify-%s-%s-pg' "$(worktree_key)" "$1"
}

verify_container_ownership() {
  local run_id="$1" container="$2" observed
  verify_container_identity "$run_id" "$container"
  observed="$(docker inspect --format '{{ index .Config.Labels "dev.zensu.verify.lease-sha256" }}' "$container" 2>/dev/null)" \
    || fail "runtime container is unavailable"
  [ "$observed" = "$(lease_hash)" ] || fail "runtime container lease is invalid"
}

verify_container_identity() {
  local run_id="$1" container="$2" expected
  expected="$(expected_container "$run_id")"
  [ "$container" = "$expected" ] || fail "runtime container identity is invalid"
}

remove_owned_container_if_present() {
  local run_id="$1" container="$2" observed
  verify_container_identity "$run_id" "$container"
  observed="$(docker inspect --format '{{ index .Config.Labels "dev.zensu.verify.lease-sha256" }}' "$container" 2>/dev/null)" \
    || return 0
  [ "$observed" = "$(lease_hash)" ] || return 1
  docker rm -f "$container" >/dev/null
}

supervisor_request() {
  local action="$1" endpoint="$2"
  [ -f "$endpoint" ] && [ ! -L "$endpoint" ] || return 1
  ZENSU_VERIFY_RUNTIME_LEASE="$RUNTIME_LEASE" node "$SUPERVISOR" "$action" "$endpoint" >/dev/null
}

stop_owned_supervisors() {
  local frontend_port="$1" backend_port="$2" failed=0
  if [ -e "$FRONTEND_READY" ]; then
    supervisor_request stop "$FRONTEND_READY" || failed=1
  elif lsof -nP -iTCP:"$frontend_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    failed=1
  fi
  if [ -e "$BACKEND_READY" ]; then
    supervisor_request stop "$BACKEND_READY" || failed=1
  elif lsof -nP -iTCP:"$backend_port" -sTCP:LISTEN -t >/dev/null 2>&1; then
    failed=1
  fi
  return "$failed"
}

wait_for_supervisor() {
  local endpoint="$1"
  for ((attempt=0; attempt<100; attempt++)); do
    if [ -f "$endpoint" ] && supervisor_request status "$endpoint" 2>/dev/null; then return 0; fi
    sleep 0.05
  done
  return 1
}

terminate_supervisor_pid() {
  local pid="$1" endpoint="$2" command_line
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in *"$SUPERVISOR start $endpoint "*) ;; *) return 1 ;; esac
  kill "$pid" 2>/dev/null || true
  for ((attempt=0; attempt<100; attempt++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  kill -9 "$pid" 2>/dev/null || true
}

PLANNED_ORIGIN_FILE="$RUN_DIR/zensu-planned-origin"
FREE_PORT_HELPER="$PLUGIN_ROOT/scripts/verify-free-port.js"

consent_origin() {
  local origin port rest
  if [ -e "$PLANNED_ORIGIN_FILE" ] || [ -L "$PLANNED_ORIGIN_FILE" ]; then
    [ -f "$PLANNED_ORIGIN_FILE" ] && [ ! -L "$PLANNED_ORIGIN_FILE" ] || fail "planned origin record is unsafe"
    origin="$(head -c 64 "$PLANNED_ORIGIN_FILE" | tr -d '\n')"
    case "$origin" in
      http://127.0.0.1:*) ;;
      *) fail "planned origin record is invalid" ;;
    esac
    rest="${origin#http://127.0.0.1:}"
    case "$rest" in
      ''|*[!0-9]*) fail "planned origin record is invalid" ;;
    esac
    printf '%s' "$origin"
    return 0
  fi
  [ -f "$FREE_PORT_HELPER" ] && [ ! -L "$FREE_PORT_HELPER" ] || fail "free-port helper is unavailable"
  port="$(node "$FREE_PORT_HELPER" --from 5173)" || fail "no free loopback port for the frontend"
  case "$port" in
    ''|*[!0-9]*) fail "free-port helper printed no port" ;;
  esac
  origin="http://127.0.0.1:${port}"
  ( umask 077; printf '%s\n' "$origin" >"$PLANNED_ORIGIN_FILE" ) || fail "cannot record the planned origin"
  printf '%s' "$origin"
}

parent_origin() {
  if [ -z "${ZENSU_VERIFY_NAVIGATION_POLICY_V1:-}" ]; then
    consent_origin
    return
  fi
  env POLICY="${ZENSU_VERIFY_NAVIGATION_POLICY_V1:-}" node -e '
    const value = JSON.parse(process.env.POLICY || "null");
    if (!value || value.version !== 1 || value.mode !== "local" || !Array.isArray(value.targets)
        || value.targets.length !== 1) process.exit(2);
    const target = value.targets[0];
    if (!target || target.evidenceMode !== "declared-safe" || !Array.isArray(target.routes)
        || !target.routes.includes("/")) process.exit(2);
    const url = new URL(target.origin);
    if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || !url.port
        || url.pathname !== "/" || url.search || url.hash || url.username || url.password) process.exit(2);
    process.stdout.write(url.origin);
  ' 2>/dev/null || fail "an exact parent-authorized 127.0.0.1 origin is required before startup"
}

case "$ACTION" in
  planned-origin)
    parent_origin
    printf '\n'
    ;;
  up)
    [ ! -e "$STATE" ] && [ ! -e "$SECRETS" ] && [ ! -e "$BACKEND_READY" ] \
      && [ ! -e "$FRONTEND_READY" ] || fail "runtime state already exists"
    for command in docker go pnpm curl lsof cksum openssl git node make; do
      command -v "$command" >/dev/null 2>&1 || fail "$command is required"
    done

    ORIGIN="$(parent_origin)"
    FRONTEND_PORT="${ORIGIN##*:}"
    if lsof -nP -iTCP:"$FRONTEND_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
      fail "the parent-authorized frontend port is already in use"
    fi

    WTKEY="$(worktree_key)"
    OFFSET=$((WTKEY % 200))
    FOUND=false
    for ((attempt=0; attempt<200; attempt++)); do
      PG_PORT=$((55432 + OFFSET))
      BACKEND_PORT=$((8090 + OFFSET))
      if [ "$PG_PORT" != "$FRONTEND_PORT" ] && [ "$BACKEND_PORT" != "$FRONTEND_PORT" ] \
        && ! lsof -nP -iTCP:"$PG_PORT" -sTCP:LISTEN -t >/dev/null 2>&1 \
        && ! lsof -nP -iTCP:"$BACKEND_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
        FOUND=true
        break
      fi
      OFFSET=$(((OFFSET + 1) % 200))
    done
    [ "$FOUND" = true ] || fail "no isolated backend/database port pair is available"

    RUN_ID="$(openssl rand -hex 6)"
    DB_PASSWORD="$(openssl rand -hex 24)"
    JWT_SECRET="$(openssl rand -hex 32)"
    RUNTIME_LEASE="$(openssl rand -hex 32)"
    CONTAINER="$(expected_container "$RUN_ID")"
    LEASE_HASH="$(lease_hash)"
    umask 077
    printf 'DB_PASSWORD=%s\nJWT_SECRET=%s\nRUNTIME_LEASE=%s\n' \
      "$DB_PASSWORD" "$JWT_SECRET" "$RUNTIME_LEASE" >"$SECRETS"
    chmod 600 "$SECRETS"

    PG_STARTED=false
    BACKEND_SUPERVISOR_PID=""
    FRONTEND_SUPERVISOR_PID=""
    cleanup_failed_up() {
      supervisor_request stop "$FRONTEND_READY" 2>/dev/null \
        || terminate_supervisor_pid "$FRONTEND_SUPERVISOR_PID" "$FRONTEND_READY" 2>/dev/null || true
      supervisor_request stop "$BACKEND_READY" 2>/dev/null \
        || terminate_supervisor_pid "$BACKEND_SUPERVISOR_PID" "$BACKEND_READY" 2>/dev/null || true
      if [ "$PG_STARTED" = true ]; then
        OBSERVED_LABEL="$(docker inspect --format '{{ index .Config.Labels "dev.zensu.verify.lease-sha256" }}' "$CONTAINER" 2>/dev/null || true)"
        [ "$OBSERVED_LABEL" = "$LEASE_HASH" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
      fi
      rm -f "$STATE" "$SECRETS" "$BACKEND_READY" "$FRONTEND_READY"
    }
    trap cleanup_failed_up EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    docker info >/dev/null
    docker run -d --name "$CONTAINER" \
      --label "dev.zensu.verify.lease-sha256=$LEASE_HASH" \
      -e POSTGRES_USER=zensu -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=zensu \
      -p "127.0.0.1:${PG_PORT}:5432" pgvector/pgvector:pg17 >/dev/null
    PG_STARTED=true

    ZENSU_VERIFY_RUNTIME_LEASE="$RUNTIME_LEASE" SERVER_HOST=127.0.0.1 SERVER_PORT="$BACKEND_PORT" \
      DB_HOST=localhost DB_PORT="$PG_PORT" DB_USER=zensu DB_PASSWORD="$DB_PASSWORD" \
      DB_NAME=zensu DB_SSLMODE=disable REGISTRATION_ENABLED=true EMAIL_ALLOW_NOOP=true \
      NOTIFICATION_ALLOW_NOOP=true JWT_SECRET="$JWT_SECRET" APP_BASE_URL="$ORIGIN" \
      nohup node "$SUPERVISOR" start "$BACKEND_READY" "$LOG_BACKEND" \
      "$WORKTREE/backend" go run ./cmd/zensu </dev/null >/dev/null 2>&1 &
    BACKEND_SUPERVISOR_PID=$!
    wait_for_supervisor "$BACKEND_READY" || fail "backend supervisor failed to start"

    [ -d "$WORKTREE/frontend/node_modules" ] || pnpm -C "$WORKTREE/frontend" install --frozen-lockfile
    ZENSU_VERIFY_RUNTIME_LEASE="$RUNTIME_LEASE" VITE_API_URL="http://127.0.0.1:${BACKEND_PORT}" \
      nohup node "$SUPERVISOR" start "$FRONTEND_READY" "$LOG_FRONTEND" \
      "$WORKTREE/frontend" pnpm dev -- --host 127.0.0.1 --port "$FRONTEND_PORT" --strictPort \
      </dev/null >/dev/null 2>&1 &
    FRONTEND_SUPERVISOR_PID=$!
    wait_for_supervisor "$FRONTEND_READY" || fail "frontend supervisor failed to start"

    supervisor_request status "$BACKEND_READY" && supervisor_request status "$FRONTEND_READY" \
      || fail "runtime supervisors failed to start"

    STATE_TMP="$STATE.tmp.$$"
    env STATE_TMP="$STATE_TMP" RUN_ID="$RUN_ID" CONTAINER="$CONTAINER" PG_PORT="$PG_PORT" \
      BACKEND_PORT="$BACKEND_PORT" FRONTEND_PORT="$FRONTEND_PORT" ORIGIN="$ORIGIN" node -e '
        const fs = require("node:fs");
        const value = {
          version: 1,
          runId: process.env.RUN_ID,
          container: process.env.CONTAINER,
          pgPort: Number(process.env.PG_PORT),
          backendPort: Number(process.env.BACKEND_PORT),
          frontendPort: Number(process.env.FRONTEND_PORT),
          origin: process.env.ORIGIN,
        };
        fs.writeFileSync(process.env.STATE_TMP, `${JSON.stringify(value)}\n`, { mode: 0o600, flag: "wx" });
      '
    mv "$STATE_TMP" "$STATE"
    trap - EXIT INT TERM HUP
    echo "zensu verify runtime: started"
    ;;
  ready)
    IFS=$'\t' read -r RUN_ID CONTAINER PG_PORT BACKEND_PORT FRONTEND_PORT ORIGIN <<<"$(state_values)"
    load_secrets
    verify_container_ownership "$RUN_ID" "$CONTAINER"
    supervisor_request status "$BACKEND_READY" && supervisor_request status "$FRONTEND_READY" \
      || fail "runtime supervisor identity is unavailable"
    for ((attempt=0; attempt<90; attempt++)); do
      docker exec "$CONTAINER" pg_isready -U zensu -d zensu >/dev/null 2>&1 \
        && curl -fsS "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -fsS "http://127.0.0.1:${BACKEND_PORT}/api/health" >/dev/null \
      || fail "backend readiness failed"
    for ((attempt=0; attempt<60; attempt++)); do
      curl -fsS "$ORIGIN" >/dev/null 2>&1 && break
      sleep 1
    done
    curl -fsS "$ORIGIN" >/dev/null || fail "frontend readiness failed"
    echo "zensu verify runtime: ready"
    ;;
  origin)
    IFS=$'\t' read -r _ _ _ _ _ ORIGIN <<<"$(state_values)"
    printf '%s\n' "$ORIGIN"
    ;;
  seed)
    IFS=$'\t' read -r RUN_ID CONTAINER PG_PORT _ _ _ <<<"$(state_values)"
    load_secrets
    verify_container_ownership "$RUN_ID" "$CONTAINER"
    DSN="postgres://zensu:${DB_PASSWORD}@127.0.0.1:${PG_PORT}/zensu?sslmode=disable"
    DSN="$DSN" make -C "$WORKTREE/backend" seed >"$RUN_DIR/seed.log" 2>&1 \
      || fail "repository seed command failed"
    echo "zensu verify runtime: seeded"
    ;;
  down)
    if [ ! -e "$STATE" ]; then
      [ ! -e "$SECRETS" ] && [ ! -e "$BACKEND_READY" ] && [ ! -e "$FRONTEND_READY" ] \
        || fail "ownership state is incomplete; refusing cleanup"
      echo "zensu verify runtime: stopped"
      exit 0
    fi
    IFS=$'\t' read -r RUN_ID CONTAINER _ BACKEND_PORT FRONTEND_PORT _ <<<"$(state_values)"
    load_secrets
    verify_container_identity "$RUN_ID" "$CONTAINER"
    CLEANUP_FAILED=0
    stop_owned_supervisors "$FRONTEND_PORT" "$BACKEND_PORT" || CLEANUP_FAILED=1
    remove_owned_container_if_present "$RUN_ID" "$CONTAINER" || CLEANUP_FAILED=1
    [ "$CLEANUP_FAILED" = 0 ] || fail "runtime teardown failed for one or more owned resources"
    rm -f "$STATE" "$SECRETS" "$BACKEND_READY" "$FRONTEND_READY"
    echo "zensu verify runtime: stopped"
    ;;
  *) fail "unknown action" ;;
esac
