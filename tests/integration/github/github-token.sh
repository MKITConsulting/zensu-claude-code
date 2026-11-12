#!/bin/bash
set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
HERE="$ZENSU_GITHUB_IT_HERE"
STATE="$ZENSU_GITHUB_IT_STATE"
CONFIG="$ZENSU_GITHUB_IT_CONFIG"

die() {
  local code="$1"
  shift
  printf 'github-token: %s\n' "$*" >&2
  exit "$code"
}

command -v node >/dev/null 2>&1 || die 2 'node is not installed'

mode=mint
case "$#:${1:-}" in
  (0:) ;;
  (1:--check) mode=check ;;
  (1:--revoke) mode=revoke ;;
  (*) die 2 'usage: github-token.sh [--check|--revoke]' ;;
esac
if [ "$mode" = revoke ]; then
  [ -d "$STATE" ] || exit 0
  node "$HERE/app-token.js" revoke --api "$ZENSU_GITHUB_IT_API" --state "$STATE" || true
  exit 0
fi

config_value() {
  [ -f "$CONFIG/$1" ] || return 0
  tr -d '[:space:]' < "$CONFIG/$1"
}

app_id="${ZENSU_GITHUB_IT_APP_ID:-}"
[ -n "$app_id" ] || app_id="$(config_value app-id)"
repo="${ZENSU_GITHUB_IT_REPO:-}"
[ -n "$repo" ] || repo="$(config_value repo)"
key_file="${ZENSU_GITHUB_IT_APP_KEY_FILE:-}"
key_text="${ZENSU_GITHUB_IT_APP_KEY:-}"
unset ZENSU_GITHUB_IT_APP_KEY
if [ -z "$key_file" ] && [ -z "$key_text" ] && [ -f "$CONFIG/private-key.pem" ]; then
  key_file="$CONFIG/private-key.pem"
fi

[ -n "$app_id" ] || die 2 "not configured: set ZENSU_GITHUB_IT_APP_ID or write the App ID to $CONFIG/app-id"
[ -n "$repo" ] || die 2 "not configured: set ZENSU_GITHUB_IT_REPO or write owner/name to $CONFIG/repo"
[ -n "$key_file" ] || [ -n "$key_text" ] \
  || die 2 "not configured: set ZENSU_GITHUB_IT_APP_KEY_FILE or ZENSU_GITHUB_IT_APP_KEY, or place the App key at $CONFIG/private-key.pem"
if [ "$mode" = check ]; then
  [ -z "$key_file" ] || [ -f "$key_file" ] || die 2 "not configured: the App key file $key_file does not exist"
  exit 0
fi

( umask 077 && mkdir -p "$STATE" ) || die 2 "cannot create $STATE"
chmod 700 "$STATE" || die 2 "cannot restrict $STATE"

temp_key=''
cleanup() {
  [ -z "$temp_key" ] || rm -f "$temp_key"
}
trap cleanup EXIT
if [ -z "$key_file" ]; then
  temp_key="$STATE/app-key.pem"
  rm -f "$temp_key"
  ( umask 077 && printf '%s\n' "$key_text" > "$temp_key" ) || die 2 "cannot write the App key to $temp_key"
  key_file="$temp_key"
fi
key_text=''

node "$HERE/app-token.js" mint --api "$ZENSU_GITHUB_IT_API" --app-id "$app_id" --key-file "$key_file" --repo "$repo" --out "$STATE"
