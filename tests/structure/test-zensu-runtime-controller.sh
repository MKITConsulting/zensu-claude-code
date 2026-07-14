#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTROLLER="$ROOT/skills/verify-feature/scripts/zensu-monorepo-runtime.sh"
SUPERVISOR_TEST="$ROOT/tests/structure/process-supervisor.test.js"
TMP="$(mktemp -d -t zensu-runtime-controller-XXXXXX)"
STUBS="$TMP/stubs"
WORKTREE="$TMP/worktree"
RUN_PARENT="$WORKTREE/.zensu/verify-feature-runs"
RUN_DIR="$RUN_PARENT/run-ok"
DOCKER_STATE="$TMP/docker"
EVENTS="$TMP/events"
PASS=0; FAIL=0

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

if node --test "$SUPERVISOR_TEST" >/dev/null 2>&1; then
  check "process supervisor authenticates status/stop and terminates its child group" PASS
else
  check "process supervisor authenticates status/stop and terminates its child group" FAIL
fi

mkdir -p "$STUBS" "$RUN_DIR" "$DOCKER_STATE" "$WORKTREE/backend/cmd/zensu" \
  "$WORKTREE/frontend/node_modules"
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
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
STUB
cat >"$STUBS/curl" <<'STUB'
#!/bin/bash
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

POLICY='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:45173","evidenceMode":"declared-safe","routes":["/"]}]}'
COMMON_ENV=(PATH="$STUBS:$PATH" DOCKER_STATE="$DOCKER_STATE" EVENTS="$EVENTS" ZENSU_VERIFY_NAVIGATION_POLICY_V1="$POLICY")

PLANNED_ORIGIN="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" planned-origin "$RUN_DIR" "$WORKTREE" 2>&1)"
UP_OUT="$(env "${COMMON_ENV[@]}" bash "$CONTROLLER" up "$RUN_DIR" "$WORKTREE" 2>&1)"
UP_RC=$?
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

PARTIAL="$RUN_PARENT/run-partial"
mkdir -p "$PARTIAL"
env "${COMMON_ENV[@]}" PNPM_FAIL_START=1 bash "$CONTROLLER" up "$PARTIAL" "$WORKTREE" >/dev/null 2>&1
PARTIAL_RC=$?
if [ "$PARTIAL_RC" != 0 ] && [ ! -e "$PARTIAL/zensu-runtime.json" ] \
  && [ ! -e "$PARTIAL/zensu-runtime.secrets" ] && [ ! -e "$PARTIAL/backend-supervisor.ready" ] \
  && [ ! -e "$PARTIAL/frontend-supervisor.ready" ]; then
  check "failed frontend startup tears down the already-started backend and container" PASS
else
  check "failed frontend startup tears down the already-started backend and container" FAIL
fi

INSTALL_PARTIAL="$RUN_PARENT/run-install-partial"
mkdir -p "$INSTALL_PARTIAL"
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
