#!/bin/bash

zensu_session_key() {
  local proc_start proc_hash
  proc_start="$(ps -o lstart= -p "$PPID" 2>/dev/null)"
  if [ -n "$proc_start" ]; then
    proc_hash="$(printf '%s' "$proc_start" | cksum 2>/dev/null | cut -d' ' -f1)"
  fi
  if [ -n "${proc_hash:-}" ]; then
    echo "${PPID}_${proc_hash}"
  else
    echo "${PPID}"
  fi
}

zensu_resolve_session_id() {
  local from_json="${1:-}"
  local sanitized key cache cached
  if [ -n "$from_json" ]; then
    sanitized="${from_json//[^A-Za-z0-9_-]/_}"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  key="$(zensu_session_key)"
  cache="${CLAUDE_PROJECT_DIR:-.}/.zensu/state/session-id-${key}.txt"
  if [ -f "$cache" ]; then
    cached="$(cat "$cache" 2>/dev/null)"
    cached="${cached//$'\n'/}"
    cached="${cached//$'\r'/}"
    sanitized="${cached//[^A-Za-z0-9_-]/_}"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  echo "fallback_${key}"
}

export -f zensu_session_key zensu_resolve_session_id 2>/dev/null || true
