#!/bin/bash

ZENSU_SUPERVISE_WORK=""
_ZENSU_SUPERVISE_CLEANUP_DIR=""
_ZENSU_SUPERVISE_WORKER=""
_ZENSU_SUPERVISE_WATCHDOG=""
_ZENSU_SUPERVISE_MODE=""

zensu_supervise_files() {
  local prefix="${1:-}" input="${2:-}" work
  ZENSU_SUPERVISE_WORK=""
  work="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null)" || return 1
  if [ -z "$work" ] || [ ! -d "$work" ] || [ -L "$work" ] || ! printf '%s' "$input" >"$work/in" 2>/dev/null; then
    [ -n "$work" ] && rm -rf -- "$work" 2>/dev/null
    return 1
  fi
  ZENSU_SUPERVISE_WORK="$work"
  return 0
}

zensu_supervise_forward() {
  local work="${1:-}" forwarded=1
  [ -n "$work" ] || return 1
  if [ -s "$work/out" ]; then
    forwarded=0
    cat -- "$work/out" 2>/dev/null
  fi
  [ -s "$work/err" ] && cat -- "$work/err" >&2 2>/dev/null
  return "$forwarded"
}

_zensu_supervise_kill_group() {
  local leader="${1:-}" mode="${2:-}"
  case "$leader" in
    (''|0*|1|*[!0123456789]*) return 0 ;;
  esac
  case "$mode" in
    (group) kill -KILL -- "-$leader" 2>/dev/null ;;
    (pid) kill -KILL "$leader" 2>/dev/null ;;
    (*) kill -KILL -- "-$leader" 2>/dev/null || kill -KILL "$leader" 2>/dev/null ;;
  esac
  wait "$leader" 2>/dev/null
  return 0
}

_zensu_supervise_cleanup() {
  if [ -n "${_ZENSU_SUPERVISE_WATCHDOG:-}" ]; then
    _zensu_supervise_kill_group "$_ZENSU_SUPERVISE_WATCHDOG"
    _ZENSU_SUPERVISE_WATCHDOG=""
  fi
  if [ -n "${_ZENSU_SUPERVISE_CLEANUP_DIR:-}" ]; then
    rm -rf -- "$_ZENSU_SUPERVISE_CLEANUP_DIR" 2>/dev/null
    [ "$ZENSU_SUPERVISE_WORK" != "$_ZENSU_SUPERVISE_CLEANUP_DIR" ] || ZENSU_SUPERVISE_WORK=""
    _ZENSU_SUPERVISE_CLEANUP_DIR=""
  fi
  return 0
}

_zensu_supervise_abort() {
  trap '' TERM INT HUP
  if [ -n "${_ZENSU_SUPERVISE_WORKER:-}" ]; then
    _zensu_supervise_kill_group "$_ZENSU_SUPERVISE_WORKER" "$_ZENSU_SUPERVISE_MODE"
    _ZENSU_SUPERVISE_WORKER=""
  fi
  _zensu_supervise_cleanup
  trap - EXIT
  exit "$1"
}

zensu_supervise() {
  [ "$#" -ge 4 ] || return 1
  local action="$1" seconds="$2" work="$3" worker mode supervisor rc fired=false
  shift 3
  if [ -n "$work" ]; then
    [ "$work" = "$ZENSU_SUPERVISE_WORK" ] && [ -d "$work" ] && [ ! -L "$work" ] || return 1
  fi
  _ZENSU_SUPERVISE_CLEANUP_DIR="$work"
  _ZENSU_SUPERVISE_WORKER=""
  _ZENSU_SUPERVISE_WATCHDOG=""
  _ZENSU_SUPERVISE_MODE=""
  trap '_zensu_supervise_abort 143' TERM
  trap '_zensu_supervise_abort 130' INT
  trap '_zensu_supervise_abort 129' HUP
  trap '_zensu_supervise_cleanup' EXIT
  supervisor="${BASHPID:-$$}"
  set -m 2>/dev/null
  if [ -n "$work" ]; then
    "$@" <"$work/in" >"$work/out" 2>"$work/err" &
  else
    "$@" &
  fi
  worker=$!
  _ZENSU_SUPERVISE_WORKER="$worker"
  kill -0 -- "-$worker" 2>/dev/null && mode=group || mode=pid
  _ZENSU_SUPERVISE_MODE="$mode"
  (
    set +m 2>/dev/null
    sleep "$seconds"
    [ -z "$work" ] || : >"$work/deadline"
    _zensu_supervise_kill_group "$worker" "$mode"
    [ -z "$work" ] || kill -0 "$supervisor" 2>/dev/null || rm -rf -- "$work"
  ) </dev/null >/dev/null 2>&1 &
  _ZENSU_SUPERVISE_WATCHDOG=$!
  set +m 2>/dev/null
  wait "$worker" 2>/dev/null
  rc=$?
  _ZENSU_SUPERVISE_WORKER=""
  if [ -n "$work" ]; then
    [ -e "$work/deadline" ] && fired=true
  elif [ "$rc" -eq 137 ]; then
    fired=true
  fi
  _zensu_supervise_kill_group "$_ZENSU_SUPERVISE_WATCHDOG"
  _ZENSU_SUPERVISE_WATCHDOG=""
  if [ "$fired" = true ]; then
    "$action" "$work"
    rc=$?
  else
    zensu_supervise_forward "$work" || :
  fi
  trap - TERM INT HUP
  _zensu_supervise_cleanup
  trap - EXIT
  return "$rc"
}
