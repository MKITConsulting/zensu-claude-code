#!/bin/bash

ZENSU_PROMPT_DEADLINE_DEFAULT_SECONDS=20
ZENSU_PROMPT_DEADLINE_MIN_SECONDS=10
ZENSU_PROMPT_DEADLINE_MAX_SECONDS=20
ZENSU_PROMPT_WORKER_FLAG="--zensu-prompt-worker"
_ZENSU_PROMPT_BUDGET=""
_ZENSU_PROMPT_WORK=""
_ZENSU_PROMPT_SUPERVISED_WORK=""
_ZENSU_PROMPT_FALLBACK=""
_ZENSU_PROMPT_DEADLINE=""
case "${BASH_SOURCE[0]}" in
  (*/*)
    _ZENSU_PROMPT_SUPERVISE_LIB="${BASH_SOURCE[0]%/*}/zensu-supervise.sh"
    declare -F zensu_supervise >/dev/null 2>&1 \
      || { [ -f "$_ZENSU_PROMPT_SUPERVISE_LIB" ] && [ ! -L "$_ZENSU_PROMPT_SUPERVISE_LIB" ] \
        && source "$_ZENSU_PROMPT_SUPERVISE_LIB" 2>/dev/null; }
    ;;
esac

zensu_prompt_deadline_seconds() {
  local raw="${ZENSU_PROMPT_DEADLINE_SECONDS:-}" value
  case "$raw" in
    (''|*[!0-9]*)
      printf '%s\n' "$ZENSU_PROMPT_DEADLINE_DEFAULT_SECONDS"
      return 0
      ;;
  esac
  value="${raw#"${raw%%[!0]*}"}"
  if [ -z "$value" ]; then
    value="$ZENSU_PROMPT_DEADLINE_MIN_SECONDS"
  elif [ "${#value}" -gt 6 ] || [ "$value" -gt "$ZENSU_PROMPT_DEADLINE_MAX_SECONDS" ]; then
    value="$ZENSU_PROMPT_DEADLINE_MAX_SECONDS"
  elif [ "$value" -lt "$ZENSU_PROMPT_DEADLINE_MIN_SECONDS" ]; then
    value="$ZENSU_PROMPT_DEADLINE_MIN_SECONDS"
  fi
  printf '%s\n' "$value"
}

zensu_prompt_worker_enter() {
  local budget="${2:-}" work="${3:-}"
  case "$budget" in
    (''|*[!0-9]*) budget="" ;;
  esac
  [ "${#budget}" -le 6 ] || budget=""
  _ZENSU_PROMPT_BUDGET="$budget"
  if [ -n "$work" ] && [ -d "$work" ] && [ ! -L "$work" ] && [ -f "$work/in" ] && [ ! -L "$work/in" ]; then
    _ZENSU_PROMPT_WORK="$work"
    trap 'zensu_prompt_delivered' EXIT
  fi
  return 0
}

zensu_prompt_delivered() {
  [ -n "$_ZENSU_PROMPT_WORK" ] && : >"$_ZENSU_PROMPT_WORK/done" 2>/dev/null
  return 0
}

_zensu_prompt_name_ok() {
  case "${1:-}" in
    ([abcdefghijklmnopqrstuvwxyz]*) ;;
    (*) return 1 ;;
  esac
  case "$1" in
    (*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

zensu_prompt_classified() {
  [ -n "$_ZENSU_PROMPT_WORK" ] && _zensu_prompt_name_ok "${1:-}" || return 0
  printf '%s\n' "$1" >"$_ZENSU_PROMPT_WORK/classified" 2>/dev/null
  return 0
}

zensu_prompt_record() {
  local name="${1:-}" value="${2:-}"
  [ -n "$_ZENSU_PROMPT_WORK" ] && _zensu_prompt_name_ok "$name" || return 0
  case "$value" in
    (*$'\n'*|*$'\r'*) return 0 ;;
  esac
  [ "${#value}" -le 256 ] || return 0
  printf '%s\n' "$value" >"$_ZENSU_PROMPT_WORK/fact-$name" 2>/dev/null
  return 0
}

zensu_prompt_recorded() {
  local name="${1:-}" work="${_ZENSU_PROMPT_SUPERVISED_WORK:-}" value=""
  [ -n "$work" ] && _zensu_prompt_name_ok "$name" || return 0
  [ -f "$work/fact-$name" ] && [ ! -L "$work/fact-$name" ] || return 0
  IFS= read -r value <"$work/fact-$name" || true
  printf '%s' "$value"
}

zensu_prompt_lineage_budget() {
  local reserve="${1:-0}" total="${_ZENSU_PROMPT_BUDGET:-}" left
  case "$reserve" in
    (''|*[!0-9]*) reserve=0 ;;
  esac
  [ "${#reserve}" -le 6 ] || reserve=0
  [ -n "$total" ] || total="$(zensu_prompt_deadline_seconds)"
  left=$(( total - SECONDS - reserve ))
  [ "$left" -gt 0 ] || left=0
  printf '%s\n' "$left"
}

_zensu_prompt_deadline_action() {
  local work="${1:-}" kind=""
  if [ -e "$work/done" ]; then
    zensu_supervise_forward "$work" || :
    return 0
  fi
  if [ -f "$work/classified" ] && [ ! -L "$work/classified" ]; then
    IFS= read -r kind <"$work/classified" || true
  fi
  _ZENSU_PROMPT_SUPERVISED_WORK="$work"
  _zensu_prompt_name_ok "$kind" && "$_ZENSU_PROMPT_FALLBACK" "$kind" "$_ZENSU_PROMPT_DEADLINE"
  _ZENSU_PROMPT_SUPERVISED_WORK=""
  return 0
}

zensu_prompt_supervise() {
  local script="${1:-}" input="${2:-}" fallback="${3:-}" deadline remaining
  [ -n "$script" ] && [ -f "$script" ] || return 0
  [ -n "$fallback" ] && declare -F "$fallback" >/dev/null 2>&1 || return 0
  declare -F zensu_supervise >/dev/null 2>&1 || return 0
  deadline="$(zensu_prompt_deadline_seconds)" || return 0
  zensu_supervise_files zensu-prompt "$input" || return 0
  _ZENSU_PROMPT_FALLBACK="$fallback"
  _ZENSU_PROMPT_DEADLINE="$deadline"
  remaining=$(( deadline - SECONDS ))
  [ "$remaining" -gt 0 ] || remaining=1
  zensu_supervise _zensu_prompt_deadline_action "$remaining" "$ZENSU_SUPERVISE_WORK" \
    "${BASH:-bash}" "$script" "$ZENSU_PROMPT_WORKER_FLAG" "$remaining" "$ZENSU_SUPERVISE_WORK"
  exit $?
}
