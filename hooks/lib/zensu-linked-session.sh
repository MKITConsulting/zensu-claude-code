#!/bin/bash

_ZENSU_LINKED_SESSION_LIB_DIR="$(case "${BASH_SOURCE[0]}" in (*/*) cd "${BASH_SOURCE[0]%/*}/" ;; esac && pwd -P)"
declare -F zensu_linked_session_state >/dev/null 2>&1 \
  || source "$_ZENSU_LINKED_SESSION_LIB_DIR/zensu-config.sh"
declare -F zensu_write_session_marker >/dev/null 2>&1 \
  || source "$_ZENSU_LINKED_SESSION_LIB_DIR/zensu-marker-write.sh"

_zensu_linked_session_write() {
  local project_dir="$1" marker="$2" line="$3"
  ( zensu_write_session_marker zensu-linked-session.sh "$project_dir" "$marker" "$line" ) >/dev/null 2>&1
}

_zensu_linked_session_cache_writable() {
  local project_dir="$1" marker="$2" state_dir
  state_dir="$(dirname "$marker")"
  zensu_tdd_mode_state_linked "$project_dir" "$marker" && return 1
  mkdir -p -m 700 "$state_dir" 2>/dev/null || { [ -d "$state_dir" ] && [ ! -L "$state_dir" ]; } || return 1
  [ -w "$state_dir" ] && [ -x "$state_dir" ]
}

_zensu_linked_parent_route_is_build() {
  local parent_root="$1" parent_key="$2"
  case "$(zensu_delivery_route_marker_state "$parent_root" "$parent_key")" in
    (build) return 0 ;;
    (none) [ "$(zensu_inherited_route_state "$parent_root" "$parent_key")" = build ] ;;
    (*) return 1 ;;
  esac
}

zensu_linked_session_pending() {
  local project_dir="${1:-}" session_key="${2:-}"
  [ -n "$project_dir" ] && [ -n "$session_key" ] && [ -n "${CLAUDE_CODE_HOST_SESSION_ID:-}" ] || return 1
  case "$(zensu_linked_session_state "$project_dir" "$session_key")" in
    (linked|none) return 1 ;;
  esac
  command -v node >/dev/null 2>&1
}

zensu_linked_session_resolve() {
  local project_dir="${1:-}" session_key="${2:-}" session_id="${3:-}"
  local state marker inherited answer kind parent_root parent_key repository turn
  [ -n "$project_dir" ] && [ -n "$session_key" ] || { echo "none"; return 0; }
  state="$(zensu_linked_session_state "$project_dir" "$session_key")"
  case "$state" in
    (linked|none) echo "$state"; return 0 ;;
  esac
  marker="$(zensu_linked_session_marker_path "$project_dir" "$session_key")" || { echo "none"; return 0; }
  if [ -z "${CLAUDE_CODE_HOST_SESSION_ID:-}" ] || [ -z "$session_id" ] || ! command -v node >/dev/null 2>&1 \
    || ! _zensu_linked_session_cache_writable "$project_dir" "$marker"; then
    echo "none"
    return 0
  fi
  answer="$(ZENSU_LINKED_SESSION_ID="$session_id" ZENSU_LINKED_PROJECT_ROOT="$project_dir" \
    node "$_ZENSU_LINKED_SESSION_LIB_DIR/linked-session-v1.js" 2>/dev/null)" || answer=""
  IFS=$'\t' read -r kind _ parent_root parent_key repository turn <<<"$answer"
  case "$kind" in
    (linked)
      if [ "$repository" = same ] && [ "$parent_root" != - ] && [ "$parent_key" != - ] \
        && _zensu_linked_parent_route_is_build "$parent_root" "$parent_key"; then
        inherited="$(zensu_inherited_route_marker_path "$project_dir" "$session_key")" \
          && _zensu_linked_session_write "$project_dir" "$inherited" '{"route":"build"}'
      fi
      _zensu_linked_session_write "$project_dir" "$marker" '{"state":"linked"}'
      if [ "$(zensu_linked_session_state "$project_dir" "$session_key")" != linked ]; then
        echo "none"
      elif [ "$state" = absent ] && [ "$turn" = first ]; then
        echo "fresh-linked"
      else
        echo "linked"
      fi
      ;;
    (unresolved)
      if [ "$state" = absent ]; then
        _zensu_linked_session_write "$project_dir" "$marker" '{"state":"unresolved"}'
      else
        _zensu_linked_session_write "$project_dir" "$marker" '{"state":"none"}'
      fi
      echo "unresolved"
      ;;
    (*)
      _zensu_linked_session_write "$project_dir" "$marker" '{"state":"none"}'
      echo "none"
      ;;
  esac
}
