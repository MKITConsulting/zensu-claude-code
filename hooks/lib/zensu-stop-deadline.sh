#!/bin/bash

ZENSU_STOP_DEADLINE_DEFAULT_SECONDS=45
ZENSU_STOP_DEADLINE_MIN_SECONDS=10
ZENSU_STOP_DEADLINE_MAX_SECONDS=75
ZENSU_STOP_WORKER_FLAG="--zensu-stop-worker"

zensu_stop_deadline_seconds() {
  local raw="${ZENSU_STOP_DEADLINE_SECONDS:-}" value
  case "$raw" in
    ''|*[!0-9]*)
      printf '%s\n' "$ZENSU_STOP_DEADLINE_DEFAULT_SECONDS"
      return 0
      ;;
  esac
  value="${raw#"${raw%%[!0]*}"}"
  if [ -z "$value" ]; then
    value="$ZENSU_STOP_DEADLINE_MIN_SECONDS"
  elif [ "${#value}" -gt 6 ] || [ "$value" -gt "$ZENSU_STOP_DEADLINE_MAX_SECONDS" ]; then
    value="$ZENSU_STOP_DEADLINE_MAX_SECONDS"
  elif [ "$value" -lt "$ZENSU_STOP_DEADLINE_MIN_SECONDS" ]; then
    value="$ZENSU_STOP_DEADLINE_MIN_SECONDS"
  fi
  printf '%s\n' "$value"
}

zensu_stop_deadline_notice() {
  local deadline="$1" decided="$2"
  if [ "$decided" = true ]; then
    printf '%s\n' "zensu chain-enforcer: the Stop checks did not finish within ${deadline}s and were stopped. The decision they had already written stands; nothing after it was evaluated. An overloaded machine makes every step of this hook slow. ZENSU_STOP_DEADLINE_SECONDS in the Claude Code environment sets the bound between ${ZENSU_STOP_DEADLINE_MIN_SECONDS}s and ${ZENSU_STOP_DEADLINE_MAX_SECONDS}s (default ${ZENSU_STOP_DEADLINE_DEFAULT_SECONDS}s)."
  else
    printf '%s\n' "zensu chain-enforcer: releasing Stop — the Stop checks did not finish within ${deadline}s and were stopped before reaching a decision, so this session is not held any longer. No review-chain or Autopilot state was evaluated to the end: no completion was proven, only the wait was bounded, and the next Stop evaluates again. An overloaded machine makes every step of this hook slow. ZENSU_STOP_DEADLINE_SECONDS in the Claude Code environment sets the bound between ${ZENSU_STOP_DEADLINE_MIN_SECONDS}s and ${ZENSU_STOP_DEADLINE_MAX_SECONDS}s (default ${ZENSU_STOP_DEADLINE_DEFAULT_SECONDS}s)."
  fi
}

_zensu_stop_kill_group() {
  local leader="${1:-}"
  [ -n "$leader" ] || return 0
  kill -KILL -- "-$leader" 2>/dev/null || kill -KILL "$leader" 2>/dev/null
  wait "$leader" 2>/dev/null
  return 0
}

_zensu_stop_cleanup() {
  if [ -n "${_ZENSU_STOP_WATCHDOG:-}" ]; then
    _zensu_stop_kill_group "$_ZENSU_STOP_WATCHDOG"
    _ZENSU_STOP_WATCHDOG=""
  fi
  if [ -n "${_ZENSU_STOP_WORK:-}" ]; then
    rm -rf -- "$_ZENSU_STOP_WORK" 2>/dev/null
    _ZENSU_STOP_WORK=""
  fi
  return 0
}

_zensu_stop_abort() {
  trap '' TERM INT HUP
  if [ -n "${_ZENSU_STOP_WORKER:-}" ]; then
    _zensu_stop_kill_group "$_ZENSU_STOP_WORKER"
    _ZENSU_STOP_WORKER=""
  fi
  _zensu_stop_cleanup
  trap - EXIT
  exit "$1"
}

zensu_stop_supervise() {
  local script="${1:-}" input="${2:-}" deadline rc work worker supervisor fired decided
  [ -n "$script" ] && [ -f "$script" ] || return 0
  deadline="$(zensu_stop_deadline_seconds)" || return 0
  work="$(mktemp -d "${TMPDIR:-/tmp}/zensu-stop.XXXXXX" 2>/dev/null)" || return 0
  if [ ! -d "$work" ] || [ -L "$work" ] || ! printf '%s' "$input" >"$work/in" 2>/dev/null; then
    rm -rf -- "$work" 2>/dev/null
    return 0
  fi
  _ZENSU_STOP_WORK="$work"
  _ZENSU_STOP_WORKER=""
  _ZENSU_STOP_WATCHDOG=""
  trap '_zensu_stop_abort 143' TERM
  trap '_zensu_stop_abort 130' INT
  trap '_zensu_stop_abort 129' HUP
  trap '_zensu_stop_cleanup' EXIT
  supervisor=$$
  set -m 2>/dev/null
  "${BASH:-bash}" "$script" "$ZENSU_STOP_WORKER_FLAG" <"$work/in" >"$work/out" 2>"$work/err" &
  worker=$!
  _ZENSU_STOP_WORKER="$worker"
  (
    set +m 2>/dev/null
    sleep "$deadline"
    : >"$work/deadline"
    kill -KILL -- "-$worker" 2>/dev/null || kill -KILL "$worker" 2>/dev/null
    kill -0 "$supervisor" 2>/dev/null || rm -rf -- "$work"
  ) </dev/null >/dev/null 2>&1 &
  _ZENSU_STOP_WATCHDOG=$!
  set +m 2>/dev/null
  wait "$worker"
  rc=$?
  _ZENSU_STOP_WORKER=""
  fired=false
  [ -e "$work/deadline" ] && fired=true
  _zensu_stop_kill_group "$_ZENSU_STOP_WATCHDOG"
  _ZENSU_STOP_WATCHDOG=""
  decided=false
  [ -s "$work/out" ] && decided=true
  [ "$decided" = true ] && cat -- "$work/out" 2>/dev/null
  [ -s "$work/err" ] && cat -- "$work/err" >&2 2>/dev/null
  if [ "$fired" = true ]; then
    zensu_stop_deadline_notice "$deadline" "$decided" >&2
    rc=0
  fi
  trap - TERM INT HUP
  _zensu_stop_cleanup
  trap - EXIT
  exit "$rc"
}
