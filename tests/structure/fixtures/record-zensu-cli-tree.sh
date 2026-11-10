#!/bin/bash
set -u

ZENSU_BIN="${1:-zensu}"
export ZENSU_NO_UPDATE_CHECK=1

help_of() {
  "$ZENSU_BIN" "$@" --help 2>/dev/null </dev/null
}

commands_of() {
  help_of "$@" | awk '/^Available Commands:/ { f = 1; next } f && /^[^ ]/ { f = 0 } f && NF { print $1 }'
}

aliases_of() {
  help_of "$@" | awk '/^Aliases:/ { getline; gsub(/,/, " "); print; exit }'
}

print_aliases() {
  local name="$1" alias
  shift
  for alias in $(aliases_of "$@"); do
    [ "$alias" = "$name" ] || printf 'alias %s %s\n' "$*" "$alias"
  done
}

VERSION="$("$ZENSU_BIN" --version 2>/dev/null </dev/null | awk 'NR == 1 { print $2 }')"
[ -n "$VERSION" ] || { echo "record-zensu-cli-tree: cannot read the version of $ZENSU_BIN" >&2; exit 1; }
GROUPS_FOUND="$(commands_of)"
[ -n "$GROUPS_FOUND" ] || { echo "record-zensu-cli-tree: $ZENSU_BIN lists no commands" >&2; exit 1; }

printf 'version %s\n' "$VERSION"
for group in $GROUPS_FOUND; do
  print_aliases "$group" "$group"
  verbs="$(commands_of "$group")"
  if [ -z "$verbs" ]; then
    printf 'leaf %s\n' "$group"
    continue
  fi
  for verb in $verbs; do
    print_aliases "$verb" "$group" "$verb"
    subs="$(commands_of "$group" "$verb")"
    if [ -z "$subs" ]; then
      printf 'leaf %s %s\n' "$group" "$verb"
      continue
    fi
    for sub in $subs; do
      print_aliases "$sub" "$group" "$verb" "$sub"
      printf 'leaf %s %s %s\n' "$group" "$verb" "$sub"
    done
  done
done
