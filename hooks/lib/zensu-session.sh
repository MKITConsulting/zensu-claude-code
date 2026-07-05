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

zensu_resolve_session_via_helper() {
  local helper_root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$helper_root" ]; then
    helper_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  fi
  local helper="${helper_root}/hooks/lib/resolve-session-id.js"
  [ -f "$helper" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  local out
  out="$(ZENSU_TRANSCRIPT_PATH="${ZENSU_TRANSCRIPT_PATH:-}" node "$helper" "${ZENSU_BASH_START:-}" 2>/dev/null)"
  out="${out//$'\n'/}"
  out="${out//$'\r'/}"
  if [ -n "$out" ]; then
    local sanitized="${out//[^A-Za-z0-9_-]/_}"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  return 1
}

zensu_resolve_session_id() {
  local from_json="${1:-}"
  local sanitized helper_out
  if [ -n "$from_json" ]; then
    sanitized="${from_json//[^A-Za-z0-9_-]/_}"
    if [ -n "$sanitized" ]; then
      echo "$sanitized"
      return 0
    fi
  fi
  if helper_out="$(zensu_resolve_session_via_helper)"; then
    if [ -n "$helper_out" ]; then
      echo "$helper_out"
      return 0
    fi
  fi
  echo "fallback_$(zensu_session_key)"
}

# Resolve the active session's project dir (absolute) when CLAUDE_PROJECT_DIR is
# unavailable — the non-hook Bash-call counterpart to zensu_resolve_session_via_helper.
# Delegates to resolve-project-dir.js (active-transcript cwd), threading the same
# ZENSU_TRANSCRIPT_PATH / ZENSU_BASH_START env the session helper uses. Prints an
# absolute, EXISTING directory on success; returns non-zero (no output) otherwise,
# so callers can leave CLAUDE_PROJECT_DIR untouched on a miss.
zensu_resolve_project_dir() {
  local helper_root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$helper_root" ]; then
    helper_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  fi
  local helper="${helper_root}/hooks/lib/resolve-project-dir.js"
  [ -f "$helper" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  local out
  out="$(ZENSU_TRANSCRIPT_PATH="${ZENSU_TRANSCRIPT_PATH:-}" node "$helper" "${ZENSU_BASH_START:-}" 2>/dev/null)"
  out="${out//$'\n'/}"
  out="${out//$'\r'/}"
  [ -n "$out" ] || return 1
  # Only adopt an ABSOLUTE, existing directory. The transcript cwd is always an
  # absolute canonical path, so this never rejects the happy path; it hardens the
  # value that is about to be exported as CLAUDE_PROJECT_DIR and interpolated into
  # state-file mkdir/rm paths against a relative or otherwise unexpected result.
  case "$out" in /*) ;; *) return 1 ;; esac
  [ -d "$out" ] || return 1
  echo "$out"
  return 0
}

export -f zensu_session_key zensu_resolve_session_via_helper zensu_resolve_session_id zensu_resolve_project_dir 2>/dev/null || true
