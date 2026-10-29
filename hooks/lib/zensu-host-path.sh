#!/bin/bash
# Render an existing directory in the absolute path spelling consumed by the
# native host runtime. Git Bash reports drive paths as /c/... (and its shared
# temporary directory as /tmp/...), while Claude's native Node runtime does not
# apply MSYS argument conversion to JSON/manifests. Convert once at the producer
# boundary; never consult mutable MSYS mount tables in the native consumer.

_zensu_host_path_drive() {
  local letter rest index
  _ZENSU_HOST_PATH_DRIVE=""
  case "${1:-}" in
    /[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ])
      letter="${1#/}"
      rest=""
      ;;
    /[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]/*)
      letter="${1:1:1}"
      rest="${1:3}"
      ;;
    *) return 1 ;;
  esac
  case "$letter" in
    [abcdefghijklmnopqrstuvwxyz])
      index="abcdefghijklmnopqrstuvwxyz"
      index="${index%%"$letter"*}"
      letter="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
      letter="${letter:${#index}:1}"
      ;;
  esac
  _ZENSU_HOST_PATH_DRIVE="$letter:/$rest"
}

_zensu_host_path_render() {
  local canonical host_path roundtrip
  [ "$#" -eq 1 ] && [ -n "${1:-}" ] || return 2
  case "$1" in *$'\r'*|*$'\n'*) return 2 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || return 2
  CDPATH= cd -P -- "$1" 2>/dev/null || return 2
  canonical="$PWD"
  case "${OSTYPE:-}" in
    msys*|cygwin*|mingw*|MSYS*|CYGWIN*|MINGW*) ;;
    *)
      printf '%s\n' "$canonical"
      return
      ;;
  esac
  if _zensu_host_path_drive "$canonical" \
      && [ -d "$_ZENSU_HOST_PATH_DRIVE" ] && [ ! -L "$_ZENSU_HOST_PATH_DRIVE" ] \
      && CDPATH= cd -P -- "$_ZENSU_HOST_PATH_DRIVE" 2>/dev/null \
      && [ "$PWD" = "$canonical" ]; then
    printf '%s\n' "$_ZENSU_HOST_PATH_DRIVE"
    return
  fi
  command -v cygpath >/dev/null 2>&1 || return 2
  host_path="$(cygpath -am "$canonical" 2>/dev/null)" || return 2
  case "$host_path" in ""|*$'\r'*|*$'\n'*) return 2 ;; esac
  case "$host_path" in
    [A-Za-z]:/*|//?*/*) ;;
    *) return 2 ;;
  esac
  [ -d "$host_path" ] && [ ! -L "$host_path" ] || return 2
  CDPATH= cd -P -- "$host_path" 2>/dev/null || return 2
  roundtrip="$PWD"
  [ "$roundtrip" = "$canonical" ] || [ "$roundtrip" -ef "$canonical" ] || return 2
  printf '%s\n' "$host_path"
}

zensu_host_path() {
  [ "${BASH_SUBSHELL:-0}" -gt 0 ] || return 2
  _zensu_host_path_render "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  _zensu_host_path_render "$@"
  exit
fi
