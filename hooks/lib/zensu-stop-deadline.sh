#!/bin/bash

ZENSU_STOP_DEADLINE_DEFAULT_SECONDS=45
ZENSU_STOP_DEADLINE_MIN_SECONDS=10
ZENSU_STOP_DEADLINE_MAX_SECONDS=75
ZENSU_STOP_WORKER_FLAG="--zensu-stop-worker"
_ZENSU_STOP_DEADLINE=""
case "${BASH_SOURCE[0]}" in
  (*/*)
    _ZENSU_STOP_SUPERVISE_LIB="${BASH_SOURCE[0]%/*}/zensu-supervise.sh"
    declare -F zensu_supervise >/dev/null 2>&1 \
      || { [ -f "$_ZENSU_STOP_SUPERVISE_LIB" ] && [ ! -L "$_ZENSU_STOP_SUPERVISE_LIB" ] \
        && source "$_ZENSU_STOP_SUPERVISE_LIB" 2>/dev/null; }
    ;;
esac

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

_zensu_stop_deadline_action() {
  local work="${1:-}" decided=false
  zensu_supervise_forward "$work" && decided=true
  zensu_stop_deadline_notice "$_ZENSU_STOP_DEADLINE" "$decided" >&2
  [ "$decided" = true ] || printf '{"systemMessage":"%s"}\n' "$(zensu_stop_deadline_notice "$_ZENSU_STOP_DEADLINE" false)"
  return 0
}

zensu_stop_supervise() {
  local script="${1:-}" input="${2:-}" deadline
  [ -n "$script" ] && [ -f "$script" ] || return 0
  declare -F zensu_supervise >/dev/null 2>&1 || return 0
  deadline="$(zensu_stop_deadline_seconds)" || return 0
  zensu_supervise_files zensu-stop "$input" || return 0
  _ZENSU_STOP_DEADLINE="$deadline"
  zensu_supervise _zensu_stop_deadline_action "$deadline" "$ZENSU_SUPERVISE_WORK" \
    "${BASH:-bash}" "$script" "$ZENSU_STOP_WORKER_FLAG"
  exit $?
}
