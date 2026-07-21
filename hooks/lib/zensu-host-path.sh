#!/bin/bash
# Render an existing directory in the absolute path spelling consumed by the
# native host runtime. Git Bash reports drive paths as /c/... (and its shared
# temporary directory as /tmp/...), while Claude's native Node runtime does not
# apply MSYS argument conversion to JSON/manifests. Convert once at the producer
# boundary; never consult mutable MSYS mount tables in the native consumer.
set -u

[ "$#" -eq 1 ] && [ -n "${1:-}" ] || exit 2
case "$1" in *$'\r'*|*$'\n'*) exit 2 ;; esac
[ -d "$1" ] && [ ! -L "$1" ] || exit 2

CANONICAL="$(cd -P -- "$1" 2>/dev/null && pwd -P)" || exit 2
UNAME_S="$(uname -s 2>/dev/null)" || exit 2

case "$UNAME_S" in
  MINGW*|MSYS*|CYGWIN*)
    command -v cygpath >/dev/null 2>&1 || exit 2
    HOST_PATH="$(cygpath -am "$CANONICAL" 2>/dev/null)" || exit 2
    case "$HOST_PATH" in ""|*$'\r'*|*$'\n'*) exit 2 ;; esac
    case "$HOST_PATH" in
      [A-Za-z]:/*|//?*/*) ;;
      *) exit 2 ;;
    esac
    [ -d "$HOST_PATH" ] && [ ! -L "$HOST_PATH" ] || exit 2
    ROUNDTRIP="$(cd -P -- "$HOST_PATH" 2>/dev/null && pwd -P)" || exit 2
    [ "$ROUNDTRIP" = "$CANONICAL" ] || [ "$ROUNDTRIP" -ef "$CANONICAL" ] || exit 2
    printf '%s\n' "$HOST_PATH"
    ;;
  *)
    printf '%s\n' "$CANONICAL"
    ;;
esac
