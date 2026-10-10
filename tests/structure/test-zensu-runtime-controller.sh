#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTROLLER="$ROOT/skills/verify-feature/scripts/zensu-monorepo-runtime.sh"
SUPERVISOR_TEST="$ROOT/tests/structure/process-supervisor.test.js"
# Shared, locale-independent `node --test` summary parse (see the file header for
# why the count matters and why it is not hand-copied here).
. "$(dirname "$0")/lib-unit-summary.sh"

TMP="$(mktemp -d -t zensu-runtime-controller-XXXXXX)"
STUBS="$TMP/stubs"
WORKTREE="$TMP/worktree"
RUN_PARENT="$WORKTREE/.zensu/verify-feature-runs"
RUN_DIR="$RUN_PARENT/run-ok"
DOCKER_STATE="$TMP/docker"
EVENTS="$TMP/events"
PASS=0; FAIL=0

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  PASS  native Windows local-adapter runtime skipped (macOS/Linux/WSL required)"
    echo "----"
    echo "test-zensu-runtime-controller: 1 PASS / 0 FAIL"
    exit 0
    ;;
esac

cleanup() {
  if [ -d "$RUN_DIR" ]; then
    env PATH="$STUBS:$PATH" DOCKER_STATE="$DOCKER_STATE" \
      ZENSU_VERIFY_NAVIGATION_POLICY_V1="$POLICY" \
      bash "$CONTROLLER" down "$RUN_DIR" "$WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM HUP

check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS + 1));
  else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

wait_for_file() {
  for ((attempt=0; attempt<200; attempt++)); do
    [ -f "$1" ] && return 0
    sleep 0.05
  done
  return 1
}

json_field() {
  node -e 'const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(value[process.argv[2]]));' "$1" "$2" 2>/dev/null
}

LOOPBACK_AVAILABLE=0
if node -e '
  const net = require("node:net");
  const server = net.createServer();
  server.once("error", () => process.exit(1));
  server.listen(0, "127.0.0.1", () => server.close(() => process.exit(0)));
' >/dev/null 2>&1; then
  LOOPBACK_AVAILABLE=1
fi

SUPERVISOR_FLOOR="$(unit_overview_declared "${SUPERVISOR_TEST##*/}")"
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "process-supervisor integration skipped because the managed host forbids loopback listeners" PASS
elif SUPERVISOR_OUT="$(node --test "$SUPERVISOR_TEST" 2>&1)" \
  && unit_cases_registered_floor_text "$SUPERVISOR_OUT" "$SUPERVISOR_FLOOR"; then
  check "process supervisor authenticates status/stop and terminates its child group ($(unit_cases_report_text "$SUPERVISOR_OUT"))" PASS
else
  check "process supervisor authenticates status/stop and terminates its child group ($(unit_cases_report_text "${SUPERVISOR_OUT:-}"), want >= ${SUPERVISOR_FLOOR:-<no overview row>} registered)" FAIL
fi
if SUPERVISOR_OVERVIEW="$(unit_overview_check "$SUPERVISOR_TEST")"; then
  check "the SUITE-OVERVIEW Blocks cell matches what ${SUPERVISOR_TEST##*/} registers ($SUPERVISOR_FLOOR)" PASS
else
  check "$SUPERVISOR_OVERVIEW" FAIL
fi

mkdir -p "$STUBS" "$RUN_DIR" "$DOCKER_STATE" "$WORKTREE/backend/cmd/zensu" \
  "$WORKTREE/frontend/node_modules"
: >"$DOCKER_STATE/events"
touch "$WORKTREE/backend/Makefile" "$WORKTREE/frontend/package.json" "$WORKTREE/frontend/pnpm-lock.yaml"

cat >"$STUBS/docker" <<'STUB'
#!/bin/bash
set -u
case "${1:-}" in
  info|exec) exit 0 ;;
  run)
    [ "${DOCKER_FAIL_RUN:-0}" != 1 ] || exit 17
    shift
    label=""; name=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --label) label="${2#*=}"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$label" >"$DOCKER_STATE/label"
    printf '%s\n' "$name" >"$DOCKER_STATE/name"
    printf 'container-id\n'
    ;;
  inspect)
    [ "${DOCKER_MISSING:-0}" != 1 ] || exit 1
    cat "$DOCKER_STATE/label"
    ;;
  rm) printf 'rm %s\n' "${*: -1}" >>"$DOCKER_STATE/events" ;;
  *) exit 2 ;;
esac
STUB
cat >"$STUBS/go" <<'STUB'
#!/bin/bash
if [ -n "${ARGV_DIR:-}" ]; then
  printf '%s\n' "$@" >"$ARGV_DIR/go.argv"
  pwd -P >"$ARGV_DIR/go.cwd"
  env | grep -E '^(DB_PASSWORD|JWT_SECRET)=' | cut -d= -f1 | LC_ALL=C sort >"$ARGV_DIR/go.secret-names"
  env | grep -E '^(TRUSTED_PROXY_CIDRS|SERVER_HOST|SERVER_PORT|DB_HOST|DB_PORT|DB_USER|DB_NAME|DB_SSLMODE|REGISTRATION_ENABLED|EMAIL_ALLOW_NOOP|NOTIFICATION_ALLOW_NOOP|APP_BASE_URL|ZENSU_VERIFY_RUNTIME_LEASE)=' \
    | LC_ALL=C sort >"$ARGV_DIR/go.env.tmp"
  mv "$ARGV_DIR/go.env.tmp" "$ARGV_DIR/go.env"
fi
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
STUB
cat >"$STUBS/pnpm" <<'STUB'
#!/bin/bash
if printf '%s\n' "$*" | grep -q ' install '; then
  [ "${PNPM_FAIL_INSTALL:-0}" != 1 ] || exit 18
  exit 0
fi
[ "${PNPM_FAIL_START:-0}" != 1 ] || exit 19
if [ -n "${ARGV_DIR:-}" ]; then
  printf '%s\n' "$@" >"$ARGV_DIR/pnpm.argv"
  pwd -P >"$ARGV_DIR/pnpm.cwd"
  env | grep -E '^(VITE_API_URL|ZENSU_VERIFY_RUNTIME_LEASE)=' | LC_ALL=C sort >"$ARGV_DIR/pnpm.env.tmp"
  mv "$ARGV_DIR/pnpm.env.tmp" "$ARGV_DIR/pnpm.env"
fi
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
STUB
cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
case " $* " in
  *' --connect-timeout '*)
    for arg in "$@"; do
      case "$arg" in
        http://127.0.0.1:*/)
          port="${arg#http://127.0.0.1:}"
          port="${port%/}"
          case ",${CURL_LISTENING_PORTS:-}," in *",$port,"*) exit 0 ;; esac
          ;;
      esac
    done
    exit 7
    ;;
esac
exit 0
STUB
cat >"$STUBS/lsof" <<'STUB'
#!/bin/bash
exit 1
STUB
cat >"$STUBS/openssl" <<'STUB'
#!/bin/bash
count=$(( ${3:-0} * 2 ))
printf '%*s\n' "$count" '' | tr ' ' a
STUB
cat >"$STUBS/git" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$STUBS/make" <<'STUB'
#!/bin/bash
printf 'seeded\n' >>"$EVENTS"
exit 0
STUB
chmod +x "$STUBS"/*

POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:45173","evidenceMode":"declared-safe"}]}'
COMMON_ENV=(PATH="$STUBS:$PATH" DOCKER_STATE="$DOCKER_STATE" EVENTS="$EVENTS" ZENSU_VERIFY_NAVIGATION_POLICY_V1="$POLICY")

PLANNED_ORIGIN="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" planned-origin "$RUN_DIR" "$WORKTREE" 2>&1)"

LEGACY_POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:45173","evidenceMode":"declared-safe","routes":["/teams"]}]}'
LEGACY_ORIGIN="$(env PATH="$STUBS:$PATH" ZENSU_VERIFY_NAVIGATION_POLICY_V1="$LEGACY_POLICY" bash "$CONTROLLER" planned-origin "$RUN_DIR" "$WORKTREE" 2>&1)"
if [ "$PLANNED_ORIGIN" = 'http://127.0.0.1:45173' ] && [ "$LEGACY_ORIGIN" = 'http://127.0.0.1:45173' ]; then
  check "a policy target authorizes its origin without a route list, and a legacy route list that omits / is ignored" PASS
else
  check "a policy target authorizes its origin without a route list, and a legacy route list that omits / is ignored (got '$PLANNED_ORIGIN' / '$LEGACY_ORIGIN')" FAIL
fi
MALFORMED_POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:45173","evidenceMode":"declared-safe","routes":"/"}]}'
if ! env PATH="$STUBS:$PATH" ZENSU_VERIFY_NAVIGATION_POLICY_V1="$MALFORMED_POLICY" bash "$CONTROLLER" planned-origin "$RUN_DIR" "$WORKTREE" >/dev/null 2>&1; then
  check "a policy target whose legacy routes value is not a list is refused" PASS
else
  check "a policy target whose legacy routes value is not a list is refused" FAIL
fi
if [ "$LOOPBACK_AVAILABLE" = 1 ]; then
ARGV_DIR="$TMP/argv"
mkdir -p "$ARGV_DIR"
UP_OUT="$(env "${COMMON_ENV[@]}" ARGV_DIR="$ARGV_DIR" bash "$CONTROLLER" up "$RUN_DIR" "$WORKTREE" 2>&1)"
UP_RC=$?
wait_for_file "$ARGV_DIR/go.env"
wait_for_file "$ARGV_DIR/pnpm.env"
READY_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" ready "$RUN_DIR" "$WORKTREE" 2>&1)"
READY_RC=$?
ORIGIN_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" origin "$RUN_DIR" "$WORKTREE" 2>&1)"
SEED_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" seed "$RUN_DIR" "$WORKTREE" 2>&1)"
SEED_RC=$?

if [ "$PLANNED_ORIGIN" = 'http://127.0.0.1:45173' ] \
  && [ "$UP_RC" = 0 ] && printf '%s' "$UP_OUT" | grep -qF 'started' \
  && [ "$READY_RC" = 0 ] && printf '%s' "$READY_OUT" | grep -qF 'ready' \
  && [ "$ORIGIN_OUT" = 'http://127.0.0.1:45173' ] \
  && [ "$SEED_RC" = 0 ] && printf '%s' "$SEED_OUT" | grep -qF 'seeded' \
  && [ -s "$EVENTS" ]; then
  check "controller behavior covers up, ready, origin, and repository-owned seed" PASS
else
  check "controller behavior covers up, ready, origin, and repository-owned seed" FAIL
fi

STATE_PG_PORT="$(json_field "$RUN_DIR/zensu-runtime.json" pgPort)"
STATE_BACKEND_PORT="$(json_field "$RUN_DIR/zensu-runtime.json" backendPort)"
EXPECTED_PNPM_ARGV="$(printf '%s\n' dev --host 127.0.0.1 --port 45173 --strictPort)"
PNPM_ARGV="$(cat "$ARGV_DIR/pnpm.argv" 2>/dev/null)"
if [ "$PNPM_ARGV" = "$EXPECTED_PNPM_ARGV" ] \
  && [ "$(cat "$ARGV_DIR/pnpm.cwd" 2>/dev/null)" = "$(cd "$WORKTREE/frontend" && pwd -P)" ]; then
  check "the frontend runs pnpm dev --host 127.0.0.1 --port <planned port> --strictPort with no literal -- that would hide the flags from Vite" PASS
else
  check "the frontend runs pnpm dev --host 127.0.0.1 --port <planned port> --strictPort with no literal -- that would hide the flags from Vite (got '$(printf '%s' "$PNPM_ARGV" | tr '\n' ' ')')" FAIL
fi
if [ "$(cat "$ARGV_DIR/pnpm.env" 2>/dev/null)" = "VITE_API_URL=http://127.0.0.1:${STATE_BACKEND_PORT}" ]; then
  check "the frontend proxies the API to the recorded literal-loopback backend port and never receives the runtime lease" PASS
else
  check "the frontend proxies the API to the recorded literal-loopback backend port and never receives the runtime lease (got '$(tr '\n' ' ' <"$ARGV_DIR/pnpm.env" 2>/dev/null)')" FAIL
fi
EXPECTED_GO_ENV="$(printf '%s\n' \
  "APP_BASE_URL=http://127.0.0.1:45173" "DB_HOST=localhost" "DB_NAME=zensu" "DB_PORT=${STATE_PG_PORT}" \
  "DB_SSLMODE=disable" "DB_USER=zensu" "EMAIL_ALLOW_NOOP=true" "NOTIFICATION_ALLOW_NOOP=true" \
  "REGISTRATION_ENABLED=true" "SERVER_HOST=127.0.0.1" "SERVER_PORT=${STATE_BACKEND_PORT}" \
  "TRUSTED_PROXY_CIDRS=none" | LC_ALL=C sort)"
GO_ENV="$(cat "$ARGV_DIR/go.env" 2>/dev/null)"
if [ "$(cat "$ARGV_DIR/go.argv" 2>/dev/null)" = "$(printf '%s\n' run ./cmd/zensu)" ] \
  && [ "$(cat "$ARGV_DIR/go.cwd" 2>/dev/null)" = "$(cd "$WORKTREE/backend" && pwd -P)" ] \
  && [ "$GO_ENV" = "$EXPECTED_GO_ENV" ] \
  && [ "$(cat "$ARGV_DIR/go.secret-names" 2>/dev/null)" = "$(printf '%s\n' DB_PASSWORD JWT_SECRET)" ]; then
  check "the backend runs go run ./cmd/zensu with TRUSTED_PROXY_CIDRS=none and the exact loopback, database and noop environment, without the runtime lease" PASS
else
  check "the backend runs go run ./cmd/zensu with TRUSTED_PROXY_CIDRS=none and the exact loopback, database and noop environment, without the runtime lease (got '$(printf '%s' "$GO_ENV" | tr '\n' ' ')')" FAIL
fi

DOWN_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" down "$RUN_DIR" "$WORKTREE" 2>&1)"
DOWN_RC=$?
SECOND_DOWN_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" down "$RUN_DIR" "$WORKTREE" 2>&1)"
SECOND_DOWN_RC=$?
if [ "$DOWN_RC" = 0 ] && [ "$SECOND_DOWN_RC" = 0 ] \
  && printf '%s' "$DOWN_OUT$SECOND_DOWN_OUT" | grep -qF 'stopped' \
  && [ ! -e "$RUN_DIR/zensu-runtime.json" ] && [ ! -e "$RUN_DIR/zensu-runtime.secrets" ] \
  && [ ! -e "$RUN_DIR/backend-supervisor.ready" ] && [ ! -e "$RUN_DIR/frontend-supervisor.ready" ] \
  && [ "$(wc -l <"$DOCKER_STATE/events" | tr -d ' ')" = 1 ]; then
  check "down is idempotent and removes exactly the lease-owned resources" PASS
else
  check "down is idempotent and removes exactly the lease-owned resources" FAIL
fi

CONSENT_RUN="$RUN_PARENT/run-consent"
mkdir -p "$CONSENT_RUN"
CONSENT_ENV=(PATH="$STUBS:$PATH" DOCKER_STATE="$DOCKER_STATE" EVENTS="$EVENTS")
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "consent-mode planned origin skipped because the managed host forbids loopback listeners" PASS
else
  CONSENT_ORIGIN="$(env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 "${CONSENT_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" 2>&1)"
  CONSENT_AGAIN="$(env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 "${CONSENT_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" 2>&1)"
  # GNU first: BSD stat rejects -c, but GNU stat -f SUCCEEDS with a filesystem
  # dump, so a BSD-first order never reaches the fallback on Linux.
  CONSENT_MODE="$(stat -c '%a' "$CONSENT_RUN/zensu-planned-origin" 2>/dev/null || stat -f '%Lp' "$CONSENT_RUN/zensu-planned-origin" 2>/dev/null)"
  if printf '%s' "$CONSENT_ORIGIN" | grep -qE '^http://127\.0\.0\.1:[0-9]+$' \
    && [ "$CONSENT_ORIGIN" = "$CONSENT_AGAIN" ] \
    && [ "$(cat "$CONSENT_RUN/zensu-planned-origin")" = "$CONSENT_ORIGIN" ] \
    && [ "$CONSENT_MODE" = 600 ]; then
    check "without a parent policy planned-origin picks a free loopback port once and persists it for the run" PASS
  else
    check "without a parent policy planned-origin picks a free loopback port once and persists it for the run (got '$CONSENT_ORIGIN' / '$CONSENT_AGAIN' / mode $CONSENT_MODE)" FAIL
  fi
  printf 'http://evil.example:80\n' >"$CONSENT_RUN/zensu-planned-origin"
  if ! env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 "${CONSENT_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" >/dev/null 2>&1; then
    check "a planted non-loopback planned-origin record is refused" PASS
  else
    check "a planted non-loopback planned-origin record is refused" FAIL
  fi
  rm -f "$CONSENT_RUN/zensu-planned-origin"
  printf 'http://127.0.0.1:45173@evil.example\n' >"$CONSENT_RUN/zensu-planned-origin"
  if ! env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 "${CONSENT_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" >/dev/null 2>&1; then
    check "a planned-origin record with a trailing suffix after the port is refused" PASS
  else
    check "a planned-origin record with a trailing suffix after the port is refused" FAIL
  fi
  rm -f "$CONSENT_RUN/zensu-planned-origin"
  printf 'http://127.0.0.1:45173\n' >"$CONSENT_RUN/valid-origin-target"
  ln -s "$CONSENT_RUN/valid-origin-target" "$CONSENT_RUN/zensu-planned-origin"
  SYMLINK_ERR="$(env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 "${CONSENT_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" 2>&1 >/dev/null)"
  SYMLINK_STATUS=$?
  case "$SYMLINK_STATUS:$SYMLINK_ERR" in
    0:*) check "a symlinked planned-origin record is refused even when its target is a valid origin" FAIL ;;
    *'planned origin record is unsafe'*) check "a symlinked planned-origin record is refused even when its target is a valid origin" PASS ;;
    *) check "a symlinked planned-origin record is refused even when its target is a valid origin" FAIL ;;
  esac
  rm -f "$CONSENT_RUN/zensu-planned-origin" "$CONSENT_RUN/valid-origin-target"
  ln -s "$CONSENT_RUN/no-such-planned-origin-target" "$CONSENT_RUN/zensu-planned-origin"
  DANGLING_ERR="$(env -u ZENSU_VERIFY_NAVIGATION_POLICY_V1 "${CONSENT_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" 2>&1 >/dev/null)"
  DANGLING_STATUS=$?
  case "$DANGLING_STATUS:$DANGLING_ERR" in
    0:*) check "a dangling planned-origin symlink is refused rather than written through" FAIL ;;
    *'planned origin record is unsafe'*) check "a dangling planned-origin symlink is refused rather than written through" PASS ;;
    *) check "a dangling planned-origin symlink is refused rather than written through" FAIL ;;
  esac
  if [ ! -e "$CONSENT_RUN/no-such-planned-origin-target" ]; then
    check "the refused dangling symlink left no file at its target" PASS
  else
    check "the refused dangling symlink left no file at its target" FAIL
  fi
  rm -f "$CONSENT_RUN/zensu-planned-origin" "$CONSENT_RUN/no-such-planned-origin-target"
  POLICY_ORIGIN="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" planned-origin "$CONSENT_RUN" "$WORKTREE" 2>&1)"
  [ "$POLICY_ORIGIN" = 'http://127.0.0.1:45173' ] && [ ! -e "$CONSENT_RUN/zensu-planned-origin" ] \
    && check "with a parent policy present the policy origin still wins and nothing is persisted" PASS \
    || check "with a parent policy present the policy origin still wins and nothing is persisted" FAIL
fi

MISSING_CONTAINER="$RUN_PARENT/run-missing-container"
mkdir -p "$MISSING_CONTAINER"
env "${COMMON_ENV[@]}" bash "$CONTROLLER" up "$MISSING_CONTAINER" "$WORKTREE" >/dev/null 2>&1
MISSING_UP_RC=$?
BEFORE_MISSING_RM="$(wc -l <"$DOCKER_STATE/events" | tr -d ' ')"
env "${COMMON_ENV[@]}" DOCKER_MISSING=1 bash "$CONTROLLER" down "$MISSING_CONTAINER" "$WORKTREE" >/dev/null 2>&1
MISSING_DOWN_RC=$?
AFTER_MISSING_RM="$(wc -l <"$DOCKER_STATE/events" | tr -d ' ')"
if [ "$MISSING_UP_RC" = 0 ] && [ "$MISSING_DOWN_RC" = 0 ] \
  && [ "$BEFORE_MISSING_RM" = "$AFTER_MISSING_RM" ] \
  && [ ! -e "$MISSING_CONTAINER/backend-supervisor.ready" ] \
  && [ ! -e "$MISSING_CONTAINER/frontend-supervisor.ready" ] \
  && [ ! -e "$MISSING_CONTAINER/zensu-runtime.json" ]; then
  check "missing owned container does not prevent independent supervisor teardown" PASS
else
  check "missing container still tears down both supervisors (up=$MISSING_UP_RC down=$MISSING_DOWN_RC)" FAIL
fi

STALE="$RUN_PARENT/run-stale-endpoints"
mkdir -p "$STALE"
STALE_DOCKER="$TMP/docker-stale"
mkdir -p "$STALE_DOCKER"
: >"$STALE_DOCKER/events"
STALE_ENV=(PATH="$STUBS:$PATH" DOCKER_STATE="$STALE_DOCKER" EVENTS="$EVENTS" ZENSU_VERIFY_NAVIGATION_POLICY_V1="$POLICY")
env "${STALE_ENV[@]}" bash "$CONTROLLER" up "$STALE" "$WORKTREE" >/dev/null 2>&1
STALE_UP_RC=$?
STALE_LEASE="$(sed -n 's/^RUNTIME_LEASE=//p' "$STALE/zensu-runtime.secrets" 2>/dev/null)"
ABANDONED=0
for endpoint in "$STALE/frontend-supervisor.ready" "$STALE/backend-supervisor.ready"; do
  child_pid="$(ZENSU_VERIFY_RUNTIME_LEASE="$STALE_LEASE" node "$ROOT/scripts/process-supervisor.js" status "$endpoint" 2>/dev/null \
    | node -e 'let text = ""; process.stdin.on("data", (chunk) => { text += chunk; }).on("end", () => { process.stdout.write(String(JSON.parse(text).childPid)); });' 2>/dev/null)"
  supervisor_pid="$(json_field "$endpoint" supervisorPid)"
  [[ "$child_pid" =~ ^[0-9]+$ ]] && [[ "$supervisor_pid" =~ ^[0-9]+$ ]] || continue
  kill -KILL -- "-$child_pid" 2>/dev/null
  kill -KILL "$supervisor_pid" 2>/dev/null
  for ((attempt=0; attempt<200; attempt++)); do
    ZENSU_VERIFY_RUNTIME_LEASE="$STALE_LEASE" node "$ROOT/scripts/process-supervisor.js" status "$endpoint" >/dev/null 2>&1
    if [ "$?" = 3 ]; then ABANDONED=$((ABANDONED + 1)); break; fi
    sleep 0.05
  done
done
LISTENING_OUT="$(env "${STALE_ENV[@]}" CURL_LISTENING_PORTS=45173 bash "$CONTROLLER" down "$STALE" "$WORKTREE" 2>&1)"
LISTENING_RC=$?
if [ "$STALE_UP_RC" = 0 ] && [ "$ABANDONED" = 2 ] && [ "$LISTENING_RC" != 0 ] \
  && printf '%s' "$LISTENING_OUT" | grep -qF 'port 45173 still answers although no supervisor owns it' \
  && [ -e "$STALE/zensu-runtime.json" ] && [ -e "$STALE/zensu-runtime.secrets" ] \
  && [ -e "$STALE/frontend-supervisor.ready" ]; then
  check "an endpoint no supervisor answers is not cleared while its service port still answers" PASS
else
  check "an endpoint no supervisor answers is not cleared while its service port still answers (up=$STALE_UP_RC abandoned=$ABANDONED down=$LISTENING_RC)" FAIL
fi
STALE_DOWN_OUT="$(env "${STALE_ENV[@]}" bash "$CONTROLLER" down "$STALE" "$WORKTREE" 2>&1)"
STALE_DOWN_RC=$?
env "${STALE_ENV[@]}" bash "$CONTROLLER" down "$STALE" "$WORKTREE" >/dev/null 2>&1
STALE_AGAIN_RC=$?
if [ "$STALE_DOWN_RC" = 0 ] && [ "$STALE_AGAIN_RC" = 0 ] \
  && printf '%s' "$STALE_DOWN_OUT" | grep -qF 'stopped' \
  && ! printf '%s' "$STALE_DOWN_OUT" | grep -qF 'no supervisor answers' \
  && [ ! -e "$STALE/zensu-runtime.json" ] && [ ! -e "$STALE/zensu-runtime.secrets" ] \
  && [ ! -e "$STALE/frontend-supervisor.ready" ] && [ ! -e "$STALE/backend-supervisor.ready" ]; then
  check "down converges after both supervisors vanished and left their endpoints: nothing owned answers, so it succeeds, and succeeds again" PASS
else
  check "down converges after both supervisors vanished and left their endpoints (down=$STALE_DOWN_RC again=$STALE_AGAIN_RC: $STALE_DOWN_OUT)" FAIL
fi
else
  if [ "$PLANNED_ORIGIN" = 'http://127.0.0.1:45173' ]; then
    check "controller resolves the immutable planned origin without starting a listener" PASS
  else
    check "controller resolves the immutable planned origin without starting a listener" FAIL
  fi
  DOWN_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" down "$RUN_DIR" "$WORKTREE" 2>&1)"
  DOWN_RC=$?
  SECOND_DOWN_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" down "$RUN_DIR" "$WORKTREE" 2>&1)"
  SECOND_DOWN_RC=$?
  if [ "$DOWN_RC" = 0 ] && [ "$SECOND_DOWN_RC" = 0 ] \
    && [ ! -e "$RUN_DIR/zensu-runtime.json" ] && [ ! -e "$RUN_DIR/zensu-runtime.secrets" ]; then
    check "down remains idempotent when no listener-backed runtime was started" PASS
  else
    check "down remains idempotent when no listener-backed runtime was started" FAIL
  fi
  check "missing-container supervisor integration skipped because the managed host forbids loopback listeners" PASS
fi

mkdir -p "$RUN_PARENT/run-invalid"
INVALID="$RUN_PARENT/run-invalid"
printf '{"version":1,"runId":"aaaaaaaaaaaa","container":"other","pgPort":1,"backendPort":2,"frontendPort":3,"origin":"bad"}\n' >"$INVALID/zensu-runtime.json"
printf 'DB_PASSWORD=%048d\nJWT_SECRET=%064d\nRUNTIME_LEASE=%064d\n' 0 0 0 >"$INVALID/zensu-runtime.secrets"
BEFORE_RM="$(wc -l <"$DOCKER_STATE/events" | tr -d ' ')"
env "${COMMON_ENV[@]}" bash "$CONTROLLER" down "$INVALID" "$WORKTREE" >/dev/null 2>&1
INVALID_RC=$?
AFTER_RM="$(wc -l <"$DOCKER_STATE/events" | tr -d ' ')"
if [ "$INVALID_RC" != 0 ] && [ "$BEFORE_RM" = "$AFTER_RM" ]; then
  check "invalid ownership state fails before any cleanup side effect" PASS
else
  check "invalid ownership state fails before any cleanup side effect" FAIL
fi

FAILED="$RUN_PARENT/run-failed"
mkdir -p "$FAILED"
env "${COMMON_ENV[@]}" DOCKER_FAIL_RUN=1 bash "$CONTROLLER" up "$FAILED" "$WORKTREE" >/dev/null 2>&1
FAILED_RC=$?
if [ "$FAILED_RC" != 0 ] && [ ! -e "$FAILED/zensu-runtime.json" ] && [ ! -e "$FAILED/zensu-runtime.secrets" ]; then
  check "failed up removes partial secret/state ownership files" PASS
else
  check "failed up removes partial secret/state ownership files" FAIL
fi

# The secrets write moved from a truncating > plus a follow-up chmod to an O_EXCL create at
# 0600, and the threat it names is a symlink planted between the top-of-arm absence test and
# the write — which would carry DB_PASSWORD, JWT_SECRET and RUNTIME_LEASE out of the run
# directory. What the suite asserted about that file was only that it is GONE after `down`,
# which a passing run proves without exercising either property the change was made for. A
# DANGLING symlink is the discriminating shape: `[ ! -e ]` is true for it, so it survives the
# absence guard and reaches the write, where O_EXCL must refuse it.
SECRET_LINK="$RUN_PARENT/run-secret-link"
mkdir -p "$SECRET_LINK"
SECRET_LINK_TARGET="$RUN_PARENT/secret-link-target"
rm -f "$SECRET_LINK_TARGET"
ln -s "$SECRET_LINK_TARGET" "$SECRET_LINK/zensu-runtime.secrets"
# Its own DOCKER_STATE: the shared one holds single-value label/name files the stub
# overwrites per run, and a later check reads them to prove a missing container is still torn
# down. Reusing COMMON_ENV here clobbered that state and turned an unrelated check red.
SECRET_LINK_DOCKER="$TMP/docker-secret-link"
mkdir -p "$SECRET_LINK_DOCKER"
: >"$SECRET_LINK_DOCKER/events"
SECRET_LINK_OUT="$(env "${COMMON_ENV[@]}" DOCKER_STATE="$SECRET_LINK_DOCKER" bash "$CONTROLLER" up "$SECRET_LINK" "$WORKTREE" 2>&1)"
SECRET_LINK_RC=$?
case "$SECRET_LINK_OUT" in
  *'could not be created exclusively'*) SECRET_LINK_NAMED=1 ;;
  *) SECRET_LINK_NAMED=0 ;;
esac
if [ "$SECRET_LINK_RC" != 0 ] && [ "$SECRET_LINK_NAMED" = 1 ] && [ ! -e "$SECRET_LINK_TARGET" ]; then
  check "a symlinked secrets name is refused exclusively and its target is never written" PASS
else
  check "a symlinked secrets name is refused exclusively and its target is never written (rc=$SECRET_LINK_RC named=$SECRET_LINK_NAMED)" FAIL
fi
rm -f "$SECRET_LINK/zensu-runtime.secrets" "$SECRET_LINK_TARGET"

PARTIAL="$RUN_PARENT/run-partial"
mkdir -p "$PARTIAL"
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "frontend-start cleanup integration skipped because the managed host forbids supervisor listeners" PASS
else
env "${COMMON_ENV[@]}" PNPM_FAIL_START=1 bash "$CONTROLLER" up "$PARTIAL" "$WORKTREE" >/dev/null 2>&1
PARTIAL_RC=$?
if [ "$PARTIAL_RC" != 0 ] && [ ! -e "$PARTIAL/zensu-runtime.json" ] \
  && [ ! -e "$PARTIAL/zensu-runtime.secrets" ] && [ ! -e "$PARTIAL/backend-supervisor.ready" ] \
  && [ ! -e "$PARTIAL/frontend-supervisor.ready" ]; then
  check "failed frontend startup tears down the already-started backend and container" PASS
else
  check "failed frontend startup tears down the already-started backend and container" FAIL
fi
fi

INSTALL_PARTIAL="$RUN_PARENT/run-install-partial"
mkdir -p "$INSTALL_PARTIAL"
if [ "$LOOPBACK_AVAILABLE" != 1 ]; then
  check "dependency-install cleanup integration skipped because the managed host forbids supervisor listeners" PASS
else
rmdir "$WORKTREE/frontend/node_modules"
env "${COMMON_ENV[@]}" PNPM_FAIL_INSTALL=1 bash "$CONTROLLER" up "$INSTALL_PARTIAL" "$WORKTREE" >/dev/null 2>&1
INSTALL_PARTIAL_RC=$?
mkdir -p "$WORKTREE/frontend/node_modules"
if [ "$INSTALL_PARTIAL_RC" != 0 ] && [ ! -e "$INSTALL_PARTIAL/zensu-runtime.json" ] \
  && [ ! -e "$INSTALL_PARTIAL/zensu-runtime.secrets" ] \
  && [ ! -e "$INSTALL_PARTIAL/backend-supervisor.ready" ]; then
  check "dependency install failure after backend handshake still tears down the owned supervisor" PASS
else
  check "dependency install failure tears down the already-started backend (rc=$INSTALL_PARTIAL_RC)" FAIL
fi
fi

MALICIOUS="$RUN_PARENT/run-malicious-secrets"
mkdir -p "$MALICIOUS"
printf '{"version":1,"runId":"aaaaaaaaaaaa","container":"zensu-verify-%s-aaaaaaaaaaaa-pg","pgPort":55432,"backendPort":8090,"frontendPort":45173,"origin":"http://127.0.0.1:45173"}\n' \
  "$(printf '%s' "$WORKTREE" | cksum | cut -d' ' -f1)" >"$MALICIOUS/zensu-runtime.json"
printf 'DB_PASSWORD=%048d\nJWT_SECRET=%064d\nRUNTIME_LEASE=%064d\nEVIL=$(touch %s)\n' \
  0 0 0 "$TMP/executed" >"$MALICIOUS/zensu-runtime.secrets"
env "${COMMON_ENV[@]}" bash "$CONTROLLER" seed "$MALICIOUS" "$WORKTREE" >/dev/null 2>&1
if [ "$?" != 0 ] && [ ! -e "$TMP/executed" ]; then
  check "secret state is parsed as data and rejects executable or unknown assignments" PASS
else
  check "secret state is parsed as data and rejects executable or unknown assignments" FAIL
fi

OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"
env "${COMMON_ENV[@]}" bash "$CONTROLLER" origin "$OUTSIDE" "$WORKTREE" >/dev/null 2>&1
if [ "$?" != 0 ]; then
  check "controller rejects run directories outside the physical worktree boundary" PASS
else
  check "controller rejects run directories outside the physical worktree boundary" FAIL
fi

echo "----"
echo "test-zensu-runtime-controller: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
