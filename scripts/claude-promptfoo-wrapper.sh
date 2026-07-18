#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STREAM_RENDERER="$SCRIPT_DIR/claude-stream-render.js"
ENRICH_RENDERER="$SCRIPT_DIR/claude-enrichment-render.js"
FIXTURE_MANIFEST="$SCRIPT_DIR/fixture-manifest.js"
FIXTURE_MUTATION_WATCH="$SCRIPT_DIR/fixture-mutation-watch.js"
OWNED_PROCESS="$SCRIPT_DIR/owned-process.js"
MUTATION_WATCH_PID=""
MUTATION_MARKER=""
MUTATION_READY=""
SANDBOX_PROFILE=""
SANDBOX_TMP=""
CLAUDE_PID=""
RENDER_PID=""
RENDER_STATUS_DIR=""

collect_process_tree() {
  local pid="$1" child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do collect_process_tree "$child"; done
  fi
  printf '%s\n' "$pid"
}

terminate_process_tree() {
  local root="$1" pid processes alive
  [ -n "$root" ] && kill -0 "$root" 2>/dev/null || return 0
  processes="$(collect_process_tree "$root")"
  for pid in $processes; do kill -TERM "$pid" 2>/dev/null || true; done
  for ((attempt=0; attempt<40; attempt++)); do
    alive=false
    for pid in $processes; do kill -0 "$pid" 2>/dev/null && alive=true; done
    [ "$alive" = false ] && return 0
    sleep 0.05
  done
  for pid in $processes; do kill -KILL "$pid" 2>/dev/null || true; done
}

terminate_owned_process() {
  local pid="$1" watchdog
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
  kill -TERM "$pid" 2>/dev/null || true
  ( sleep 8; kill -KILL "$pid" 2>/dev/null || true ) &
  watchdog=$!
  wait "$pid" 2>/dev/null || true
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
}

# jq is needed even for DRY_RUN (it parses the options JSON for the preview).
if ! command -v jq >/dev/null 2>&1; then
  echo "claude-promptfoo-wrapper: jq not found on PATH — install jq." >&2
  exit 127
fi

PROMPT="${1:-}"
OPTIONS_JSON="${2:-"{}"}"

AGENT="$(echo "$OPTIONS_JSON" | jq -r '.config.agent // ""' 2>/dev/null)"
WORKDIR="$(echo "$OPTIONS_JSON" | jq -r '.config.working_dir // "."' 2>/dev/null)"
INIT_GIT="$(echo "$OPTIONS_JSON" | jq -r 'if .config.init_git == true then "true" else "false" end' 2>/dev/null)"
REQUIRE_DISPOSABLE="$(echo "$OPTIONS_JSON" | jq -r 'if .config.require_disposable_environment == true then "true" else "false" end' 2>/dev/null)"
[ -z "$WORKDIR" ] && WORKDIR="."

if [ "$REQUIRE_DISPOSABLE" = "true" ] && [ "${ZENSU_E2E_DISPOSABLE_ENVIRONMENT:-0}" != "1" ]; then
  echo "claude-promptfoo-wrapper: this unrestricted live eval requires a disposable host; set ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 only inside an environment you accept Claude may fully access." >&2
  exit 64
fi

if [ -n "$AGENT" ]; then
  export CLAUDE_AGENT_TYPE="$AGENT"
fi

if [ -n "$AGENT" ]; then
  FULL_PROMPT="Use the Agent tool with subagent_type='${AGENT}' and prompt: ${PROMPT}"
else
  FULL_PROMPT="$PROMPT"
fi

CLONE_FLAGS="-cR"
CP_PROBE_SRC="$(mktemp -t cp-probe-src-XXXXXX 2>/dev/null || echo "")"
CP_PROBE_DST="$(mktemp -u -t cp-probe-dst-XXXXXX 2>/dev/null || echo "")"
if [ -n "$CP_PROBE_SRC" ] && [ -n "$CP_PROBE_DST" ]; then
  if ! cp -c "$CP_PROBE_SRC" "$CP_PROBE_DST" 2>/dev/null; then
    CLONE_FLAGS="-R"
  fi
  rm -f "$CP_PROBE_SRC" "$CP_PROBE_DST" 2>/dev/null
else
  CLONE_FLAGS="-R"
fi

if [ "$INIT_GIT" = "true" ] && [ "${ZENSU_WRAPPER_TEST_MODE:-0}" != "1" ] \
  && [ "${DRY_RUN:-0}" != "1" ]; then
  ISOLATION_ROOT=""
  for candidate in /private/tmp /var/tmp; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then ISOLATION_ROOT="$candidate"; break; fi
  done
  [ -n "$ISOLATION_ROOT" ] || {
    echo "claude-promptfoo-wrapper: no safe fixture isolation root is available" >&2
    exit 69
  }
  ISOLATED_DIR="$(mktemp -d "$ISOLATION_ROOT/claude-eval-XXXXXX")"
else
  ISOLATED_DIR="$(mktemp -d -t "claude-eval-XXXXXX")"
fi
cleanup() {
  exec 3>&- 2>/dev/null || true
  if [ -n "$CLAUDE_PID" ]; then
    terminate_owned_process "$CLAUDE_PID"
  fi
  if [ -n "$RENDER_PID" ]; then
    terminate_process_tree "$RENDER_PID"
    wait "$RENDER_PID" 2>/dev/null || true
  fi
  if [ -n "$MUTATION_WATCH_PID" ]; then
    kill "$MUTATION_WATCH_PID" 2>/dev/null || true
    wait "$MUTATION_WATCH_PID" 2>/dev/null || true
  fi
  rm -f "$MUTATION_MARKER" "$MUTATION_READY" "$SANDBOX_PROFILE" 2>/dev/null || true
  [ -z "$RENDER_STATUS_DIR" ] || rm -rf "$RENDER_STATUS_DIR" 2>/dev/null || true
  [ -z "$SANDBOX_TMP" ] || rm -rf "$SANDBOX_TMP" 2>/dev/null || true
  if [ "${KEEP_ISOLATED:-0}" = "1" ]; then
    echo "claude-promptfoo-wrapper: KEEP_ISOLATED=1, leaving $ISOLATED_DIR" >&2
  else
    rm -rf "$ISOLATED_DIR" 2>/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

CP_CMD=(cp "$CLONE_FLAGS" "$WORKDIR/." "$ISOLATED_DIR/")

# Headless Claude needs non-interactive permissions. Callers that set
# require_disposable_environment must explicitly acknowledge that this is host access, not a sandbox.
CMD=(claude --print --output-format stream-json --include-partial-messages --verbose --dangerously-skip-permissions)
if [ -n "${ZENSU_PLUGIN_DIR_OVERRIDE:-}" ] && [ -d "$ZENSU_PLUGIN_DIR_OVERRIDE" ]; then
  CMD+=(--plugin-dir "$ZENSU_PLUGIN_DIR_OVERRIDE")
fi
CMD+=("$FULL_PROMPT")

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would isolate (cwd=$WORKDIR -> isolated=$ISOLATED_DIR):"
  printf '  %q' "${CP_CMD[@]}"
  echo
  echo "DRY_RUN: would execute (cwd=$ISOLATED_DIR):"
  printf '  %q' "${CMD[@]}"
  echo
  if [ "$INIT_GIT" = "true" ]; then
    echo "DRY_RUN: would initialize isolated git fixture on branch main"
  fi
  exit 0
fi

# Real run only — DRY_RUN previews above never need the claude CLI installed.
if ! command -v claude >/dev/null 2>&1; then
  echo "claude-promptfoo-wrapper: claude CLI not found on PATH — install Claude Code CLI." >&2
  exit 127
fi
if ! command -v node >/dev/null 2>&1 || [ ! -f "$STREAM_RENDERER" ] || [ ! -f "$ENRICH_RENDERER" ] \
  || [ ! -f "$FIXTURE_MANIFEST" ] || [ ! -f "$FIXTURE_MUTATION_WATCH" ] \
  || [ ! -f "$OWNED_PROCESS" ]; then
  echo "claude-promptfoo-wrapper: node or transcript renderer is unavailable." >&2
  exit 127
fi

if [ ! -d "$WORKDIR" ]; then
  echo "claude-promptfoo-wrapper: cannot cd to working_dir='$WORKDIR'" >&2
  exit 2
fi

if ! "${CP_CMD[@]}" 2>/dev/null; then
  echo "claude-promptfoo-wrapper: failed to clone working_dir='$WORKDIR' into '$ISOLATED_DIR'" >&2
  exit 2
fi

echo "claude-promptfoo-wrapper: isolated working dir: $ISOLATED_DIR" >&2

cd "$ISOLATED_DIR" || {
  echo "claude-promptfoo-wrapper: cannot cd to isolated dir='$ISOLATED_DIR'" >&2
  exit 2
}
ISOLATED_REAL="$(pwd -P)"

if [ "$INIT_GIT" = "true" ]; then
  node "$FIXTURE_MANIFEST" --assert-no-symlinks "$ISOLATED_REAL" 2>/dev/null || {
    echo "claude-promptfoo-wrapper: init_git fixtures must not contain symlinks" >&2
    exit 2
  }
  for run_owned in .verify-runtime .verify-feature-runtime .zensu/hook-events.log \
    .zensu/logs .zensu/state .zensu/verify-feature-runs; do
    if [ -e "$ISOLATED_REAL/$run_owned" ] || [ -L "$ISOLATED_REAL/$run_owned" ]; then
      echo "claude-promptfoo-wrapper: init_git fixture contains pre-existing run-owned state: $run_owned" >&2
      exit 2
    fi
  done
  if ! command -v git >/dev/null 2>&1; then
    echo "claude-promptfoo-wrapper: git not found on PATH — required by config.init_git." >&2
    exit 127
  fi
  if [ -e "$ISOLATED_DIR/.git" ]; then
    echo "claude-promptfoo-wrapper: config.init_git requires a fixture without a .git entry" >&2
    exit 2
  fi
  if ! git init -q -b main 2>/dev/null; then
    git init -q || {
      echo "claude-promptfoo-wrapper: failed to initialize isolated git fixture" >&2
      exit 2
    }
    git symbolic-ref HEAD refs/heads/main || {
      echo "claude-promptfoo-wrapper: failed to select main in isolated git fixture" >&2
      exit 2
    }
  fi
  git config user.name "Zensu Eval"
  git config user.email "eval@zensu.invalid"
  git config core.hooksPath /dev/null
  git add -A
  if ! git -c commit.gpgsign=false commit -qm "test: seed promptfoo fixture"; then
    echo "claude-promptfoo-wrapper: failed to seed isolated git fixture" >&2
    exit 2
  fi
  printf '%s\n' '.zensu/hook-events.log' >>"$ISOLATED_DIR/.git/info/exclude"
fi

export ZENSU_HOOK_LOG="$ISOLATED_DIR/.zensu/hook-events.log"
if [ -L "$ISOLATED_DIR/.zensu" ] || { [ -e "$ISOLATED_DIR/.zensu" ] && [ ! -d "$ISOLATED_DIR/.zensu" ]; }; then
  echo "claude-promptfoo-wrapper: refusing unsafe .zensu boundary in isolated fixture" >&2
  exit 2
fi
mkdir -p "$ISOLATED_DIR/.zensu" || exit 2
chmod 700 "$ISOLATED_DIR/.zensu" || exit 2
if [ "$INIT_GIT" = "true" ]; then
  mkdir -p "$ISOLATED_DIR/.verify-runtime" "$ISOLATED_DIR/.verify-feature-runtime" \
    "$ISOLATED_DIR/.zensu/logs" "$ISOLATED_DIR/.zensu/state" \
    "$ISOLATED_DIR/.zensu/verify-feature-runs" || exit 2
  chmod 700 "$ISOLATED_DIR/.verify-runtime" "$ISOLATED_DIR/.verify-feature-runtime" \
    "$ISOLATED_DIR/.zensu/logs" "$ISOLATED_DIR/.zensu/state" \
    "$ISOLATED_DIR/.zensu/verify-feature-runs" || exit 2
fi
if [ -L "$ZENSU_HOOK_LOG" ] || { [ -e "$ZENSU_HOOK_LOG" ] && [ ! -f "$ZENSU_HOOK_LOG" ]; }; then
  echo "claude-promptfoo-wrapper: refusing unsafe hook log path" >&2
  exit 2
fi
if ! node -e '
  const fs = require("node:fs");
  const flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_NOFOLLOW;
  const fd = fs.openSync(process.argv[1], flags, 0o600);
  fs.closeSync(fd);
' "$ZENSU_HOOK_LOG" 2>/dev/null; then
  echo "claude-promptfoo-wrapper: cannot create hook log without following symlinks" >&2
  exit 2
fi

BASELINE_MANIFEST=""
if [ "$INIT_GIT" = "true" ]; then
  BASELINE_MANIFEST="$(node "$FIXTURE_MANIFEST" "$ISOLATED_REAL" 2>/dev/null)" || {
    echo "claude-promptfoo-wrapper: failed to capture immutable fixture manifest" >&2
    exit 2
  }
  if ! printf '%s' "$BASELINE_MANIFEST" | grep -qE '^[a-f0-9]{64}$'; then
    echo "claude-promptfoo-wrapper: invalid immutable fixture manifest" >&2
    exit 2
  fi
  MUTATION_MARKER="$(mktemp -u -t zensu-fixture-mutated-XXXXXX)"
  MUTATION_READY="$(mktemp -u -t zensu-fixture-watch-ready-XXXXXX)"
  node "$FIXTURE_MUTATION_WATCH" "$ISOLATED_REAL" "$MUTATION_MARKER" "$MUTATION_READY" \
    >/dev/null 2>&1 &
  MUTATION_WATCH_PID=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [ -f "$MUTATION_READY" ] && break
    kill -0 "$MUTATION_WATCH_PID" 2>/dev/null || break
    sleep 0.01
  done
  if [ ! -f "$MUTATION_READY" ] || ! kill -0 "$MUTATION_WATCH_PID" 2>/dev/null; then
    echo "claude-promptfoo-wrapper: failed to start immutable fixture monitor" >&2
    exit 2
  fi
fi

export GIT_OPTIONAL_LOCKS=0
EXEC_CMD=("${CMD[@]}")
if [ "$INIT_GIT" = "true" ] && [ "${ZENSU_WRAPPER_TEST_MODE:-0}" != "1" ]; then
  SANDBOX_TMP="$(mktemp -d -t zensu-claude-runtime-XXXXXX)" || exit 69
  RESERVATION_PARENT=""
  if [ -n "${ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF:-}" ]; then
    case "$ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF" in /*) ;; *)
      echo "claude-promptfoo-wrapper: fixture reservation handoff must be absolute" >&2; exit 69 ;;
    esac
    RESERVATION_PARENT="$(cd "$(dirname "$ZENSU_VERIFY_FIXTURE_RESERVATION_HANDOFF")" 2>/dev/null && pwd -P)" || exit 69
    case "$RESERVATION_PARENT" in "$ISOLATED_REAL"|"$ISOLATED_REAL"/*)
      echo "claude-promptfoo-wrapper: fixture reservation state must stay outside the fixture" >&2; exit 69 ;;
    esac
  fi
  reject_overlapping_writable_root() {
    local candidate="$1" label="$2" physical
    physical="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 1
    case "$physical" in "$ISOLATED_REAL"|"$ISOLATED_REAL"/*)
      echo "claude-promptfoo-wrapper: $label writable root overlaps the immutable fixture" >&2
      return 1
    esac
    case "$ISOLATED_REAL" in "$physical"/*)
      echo "claude-promptfoo-wrapper: $label writable root contains the immutable fixture" >&2
      return 1
    esac
  }
  reject_overlapping_writable_root "$SANDBOX_TMP" "sandbox temp" || exit 69
  [ -z "$RESERVATION_PARENT" ] \
    || reject_overlapping_writable_root "$RESERVATION_PARENT" "fixture reservation" || exit 69
  case "$(uname -s)" in
    Darwin)
      command -v sandbox-exec >/dev/null 2>&1 || {
        echo "claude-promptfoo-wrapper: sandbox-exec is required for immutable live fixtures" >&2
        exit 69
      }
      SANDBOX_PROFILE="$(mktemp -t zensu-fixture-sandbox-XXXXXX)"
      HOME_REAL="$(cd "${HOME:-/}" 2>/dev/null && pwd -P)" || exit 69
      reject_overlapping_writable_root "$HOME_REAL" "HOME" || exit 69
      printf '%s\n' \
        '(version 1)' \
        '(deny default)' \
        '(import "system.sb")' \
        '(allow file-read*)' \
        '(allow process*)' \
        '(allow network*)' \
        '(allow sysctl-read)' \
        '(allow mach-lookup)' \
        "(allow file-write* (subpath \"$HOME_REAL\"))" \
        "(allow file-write* (subpath \"$SANDBOX_TMP\"))" \
        "(allow file-write* (literal \"$ISOLATED_REAL/.zensu/hook-events.log\"))" \
        "(allow file-write* (subpath \"$ISOLATED_REAL/.zensu/logs\"))" \
        "(allow file-write* (subpath \"$ISOLATED_REAL/.zensu/state\"))" \
        "(allow file-write* (subpath \"$ISOLATED_REAL/.zensu/verify-feature-runs\"))" \
        "(allow file-write* (subpath \"$ISOLATED_REAL/.verify-runtime\"))" \
        "(allow file-write* (subpath \"$ISOLATED_REAL/.verify-feature-runtime\"))" \
        >"$SANDBOX_PROFILE"
      if [ -n "$RESERVATION_PARENT" ]; then
        printf '(allow file-write* (subpath "%s"))\n' "$RESERVATION_PARENT" >>"$SANDBOX_PROFILE"
      fi
      EXEC_CMD=(sandbox-exec -f "$SANDBOX_PROFILE" env TMPDIR="$SANDBOX_TMP" "${CMD[@]}")
      ;;
    Linux)
      command -v bwrap >/dev/null 2>&1 || {
        echo "claude-promptfoo-wrapper: bwrap is required for immutable live fixtures" >&2
        exit 69
      }
      if [ -n "${HOME:-}" ]; then
        HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P)" || exit 69
        reject_overlapping_writable_root "$HOME_REAL" "HOME" || exit 69
      fi
      EXEC_CMD=(bwrap --ro-bind / / --dev-bind /dev /dev --proc /proc --share-net)
      [ -n "${HOME:-}" ] && EXEC_CMD+=(--bind "$HOME" "$HOME")
      EXEC_CMD+=(--bind "$SANDBOX_TMP" "$SANDBOX_TMP" --setenv TMPDIR "$SANDBOX_TMP")
      [ -n "$RESERVATION_PARENT" ] && EXEC_CMD+=(--bind "$RESERVATION_PARENT" "$RESERVATION_PARENT")
      EXEC_CMD+=(--bind "$ISOLATED_REAL/.zensu/hook-events.log" "$ISOLATED_REAL/.zensu/hook-events.log")
      EXEC_CMD+=(--bind "$ISOLATED_REAL/.zensu/logs" "$ISOLATED_REAL/.zensu/logs")
      EXEC_CMD+=(--bind "$ISOLATED_REAL/.zensu/state" "$ISOLATED_REAL/.zensu/state")
      EXEC_CMD+=(--bind "$ISOLATED_REAL/.zensu/verify-feature-runs" "$ISOLATED_REAL/.zensu/verify-feature-runs")
      EXEC_CMD+=(--bind "$ISOLATED_REAL/.verify-runtime" "$ISOLATED_REAL/.verify-runtime")
      EXEC_CMD+=(--bind "$ISOLATED_REAL/.verify-feature-runtime" "$ISOLATED_REAL/.verify-feature-runtime")
      EXEC_CMD+=(-- "${CMD[@]}")
      ;;
    *)
      echo "claude-promptfoo-wrapper: no supported immutable-fixture sandbox is available" >&2
      exit 69
      ;;
  esac
fi
RENDER_STATUS_DIR="$(mktemp -d -t zensu-render-status-XXXXXX)" || exit 69
RENDER_STATUS="$RENDER_STATUS_DIR/exit"
exec 3> >(node "$STREAM_RENDERER"; printf '%s\n' "$?" >"$RENDER_STATUS")
RENDER_PID=$!
node "$OWNED_PROCESS" "${EXEC_CMD[@]}" >&3 2>/dev/null &
CLAUDE_PID=$!
wait "$CLAUDE_PID"
CLAUDE_RC=$?
CLAUDE_PID=""
exec 3>&-
for ((attempt=0; attempt<200; attempt++)); do
  [ -s "$RENDER_STATUS" ] && break
  kill -0 "$RENDER_PID" 2>/dev/null || break
  sleep 0.01
done
wait "$RENDER_PID" 2>/dev/null || true
RENDER_PID=""
RENDER_RC="$(sed -n '1p' "$RENDER_STATUS" 2>/dev/null || true)"
case "$RENDER_RC" in ''|*[!0-9]*) RENDER_RC=1 ;; esac
rm -rf "$RENDER_STATUS_DIR"
RENDER_STATUS_DIR=""
if [ "$CLAUDE_RC" = "0" ] && [ "$RENDER_RC" != "0" ]; then
  CLAUDE_RC="$RENDER_RC"
fi
if [ "${ZENSU_WRAPPER_TEST_MODE:-0}" = "1" ] \
  && [ "${ZENSU_WRAPPER_TEST_KILL_WATCHER:-0}" = "1" ] \
  && [ -n "$MUTATION_WATCH_PID" ]; then
  kill -KILL "$MUTATION_WATCH_PID" 2>/dev/null || true
  wait "$MUTATION_WATCH_PID" 2>/dev/null || true
fi
ENRICH_ARGS=(--root "$ISOLATED_REAL")
ENRICH_COUNT=0
safe_enrichment_file() {
  local file="$1" physical_parent physical_file
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  physical_parent="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 1
  physical_file="$physical_parent/$(basename "$file")"
  case "$physical_file" in "$ISOLATED_REAL"/*) return 0 ;; *) return 1 ;; esac
}
add_enrichment() {
  [ "$ENRICH_COUNT" -lt 100 ] || return 0
  if [ "$1" != "--synthetic-uninitialized" ]; then safe_enrichment_file "$2" || return 0; fi
  ENRICH_ARGS+=("$1" "$2")
  ENRICH_COUNT=$((ENRICH_COUNT + 1))
}
if [ -s "$ZENSU_HOOK_LOG" ]; then add_enrichment --hook "$ZENSU_HOOK_LOG"; fi
SAW_STATE=0
shopt -s nullglob
for sf in "$ISOLATED_DIR"/.zensu/state/tdd-phase-*.json; do
  [ -f "$sf" ] || continue
  SAW_STATE=1
  add_enrichment --fsm "$sf"
done
shopt -u nullglob

if [ "$SAW_STATE" = "0" ] && [ -s "$ZENSU_HOOK_LOG" ] && grep -qE 'Current phase: UNINITIALIZED[,.]' "$ZENSU_HOOK_LOG"; then
  add_enrichment --synthetic-uninitialized -
fi

shopt -s nullglob
for wf in "$ISOLATED_DIR"/.zensu/logs/witness-*.log; do
  [ -f "$wf" ] || continue
  add_enrichment --witness "$wf"
done
shopt -u nullglob

if [ "$ENRICH_COUNT" -gt 0 ]; then
  node "$ENRICH_RENDERER" "${ENRICH_ARGS[@]}"
  ENRICH_RC=$?
  if [ "$CLAUDE_RC" = "0" ] && [ "$ENRICH_RC" != "0" ]; then CLAUDE_RC="$ENRICH_RC"; fi
fi

ATTEST_CLEAN="unavailable"
if [ "$INIT_GIT" = "true" ]; then
  WATCH_HEALTHY=true
  if [ -z "$MUTATION_WATCH_PID" ] || ! kill -0 "$MUTATION_WATCH_PID" 2>/dev/null \
    || [ ! -f "$MUTATION_READY" ]; then
    WATCH_HEALTHY=false
  fi
  CURRENT_MANIFEST="$(node "$FIXTURE_MANIFEST" "$ISOLATED_REAL" 2>/dev/null)" || CURRENT_MANIFEST="invalid"
  if [ "$WATCH_HEALTHY" = true ] && [ "$CURRENT_MANIFEST" = "$BASELINE_MANIFEST" ] \
    && [ ! -e "$MUTATION_MARKER" ]; then
    ATTEST_CLEAN="true"
  else
    ATTEST_CLEAN="false"
    if [ "$CLAUDE_RC" = "0" ]; then CLAUDE_RC=3; fi
  fi
  if [ -n "$MUTATION_WATCH_PID" ]; then
    kill "$MUTATION_WATCH_PID" 2>/dev/null || true
    wait "$MUTATION_WATCH_PID"
    WATCH_RC=$?
    MUTATION_WATCH_PID=""
    if [ "$WATCH_RC" != 0 ]; then
      ATTEST_CLEAN="false"
      [ "$CLAUDE_RC" != 0 ] || CLAUDE_RC=3
    fi
  fi
fi
rm -f "$MUTATION_MARKER" "$MUTATION_READY" 2>/dev/null || true
printf '\n===== wrapper attestation =====\n'
node -e '
  const value = {
    init_git: process.argv[1] === "true",
    tracked_clean: process.argv[2] === "true" ? true : process.argv[2] === "false" ? false : null,
    manifest_version: process.argv[1] === "true" ? 1 : null,
    root: process.argv[3]
  };
  process.stdout.write(`[wrapper_attestation] ${JSON.stringify(value)}\n`);
' "$INIT_GIT" "$ATTEST_CLEAN" "$ISOLATED_REAL"

exit "$CLAUDE_RC"
