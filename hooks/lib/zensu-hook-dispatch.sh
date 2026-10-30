#!/bin/bash

_zensu_dispatch_config_path() {
  local value="${1:-}" native
  case "$value" in
    (/*) ;;
    (*) printf '%s\n' "$value"; return 0 ;;
  esac
  command -v cygpath >/dev/null 2>&1 || { printf '%s\n' "$value"; return 0; }
  native="$(cygpath -am "$value" 2>/dev/null)" || { printf '%s\n' "$value"; return 0; }
  case "$native" in
    ([A-Za-z]:/*|//?*/*) printf '%s\n' "$native" ;;
    (*) printf '%s\n' "$value" ;;
  esac
}

_zensu_dispatch_msys_environment() {
  local hooks="$1" native name exclusions
  unset -f zensu_host_path _zensu_host_path_render _zensu_host_path_drive zensu_msys_env_exclusions 2>/dev/null || true
  source "$hooks/lib/zensu-host-path.sh" 2>/dev/null || return 0
  source "$hooks/lib/zensu-msys-env.sh" 2>/dev/null || return 0
  declare -F zensu_host_path >/dev/null 2>&1 && declare -F zensu_msys_env_exclusions >/dev/null 2>&1 || return 0
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    native="$(CDPATH= cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && zensu_host_path "$PWD")" && CLAUDE_PLUGIN_ROOT="$native"
  fi
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    native="$(zensu_host_path "$CLAUDE_PLUGIN_DATA")" && CLAUDE_PLUGIN_DATA="$native"
  fi
  for name in ZENSU_CONFIG HOME CLAUDE_PROJECT_DIR; do
    if [ -n "${!name:-}" ]; then
      native="$(_zensu_dispatch_config_path "${!name}")" && printf -v "$name" '%s' "$native"
    fi
  done
  exclusions="$(zensu_msys_env_exclusions CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA CLAUDE_ENV_FILE ZENSU_CONFIG HOME CLAUDE_PROJECT_DIR)" \
    && export MSYS2_ENV_CONV_EXCL="$exclusions"
}

zensu_hook_dispatch() {
  local event="${1:-}" check="${2:-}" hooks="${3:-}"
  case "${OSTYPE:-}" in
    (msys*|cygwin*|mingw*|MSYS*|CYGWIN*|MINGW*) _zensu_dispatch_msys_environment "$hooks" ;;
  esac
  [ -f "$hooks/lib/hook-dispatch-v1.js" ] || return 1
  CDPATH= cd -P -- "$hooks/lib" 2>/dev/null || return 1
  exec node ./hook-dispatch-v1.js "$event" --only "$check"
}

zensu_hook_dispatch_guarded() {
  local event="${1:-}" check="${2:-}" hooks="${3:-}" lead="${4:-}" captured status rest stdout stderr
  captured="$(
    {
      stdout="$(
        case "${OSTYPE:-}" in
          (msys*|cygwin*|mingw*|MSYS*|CYGWIN*|MINGW*) _zensu_dispatch_msys_environment "$hooks" ;;
        esac
        { CDPATH= cd -P -- "$hooks/lib" 2>/dev/null && node ./hook-dispatch-v1.js "$event" --only "$check"; }
        printf '\001%s' "$?"
      )"
      printf '\002%s' "$stdout"
    } 2>&1
  )"
  status="${captured##*$'\001'}"
  rest="${captured%$'\001'*}"
  stdout="${rest##*$'\002'}"
  stderr="${rest%$'\002'*}"
  stderr="${stderr%$'\n'}"
  case "$status" in
    (0) printf '%s' "$stdout"; return 0 ;;
    (2)
      case "$stderr" in
        (*$'\n'*|*$'\r'*) ;;
        ("$lead"*) printf '%s\n' "$stderr" >&2; return 2 ;;
      esac
      ;;
    (''|*[!0-9]*) status=unknown ;;
  esac
  cat >/dev/null 2>&1 || true
  printf '%sthe policy check exited with status %s\n' "$lead" "$status" >&2
  return 2
}
