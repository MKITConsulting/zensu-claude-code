#!/bin/bash
set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
HERE="$ZENSU_GITHUB_IT_HERE"
CACHE="$ZENSU_GITHUB_IT_CACHE"
LOCK="$CACHE/run.lock"

die() {
  local code="$1"
  shift
  printf 'github-live: %s\n' "$*" >&2
  exit "$code"
}

selection=pinned
while [ $# -gt 0 ]; do
  case "$1" in
    --gh)
      [ $# -ge 2 ] || die 2 '--gh needs pinned or a comma-separated list of pinned versions'
      selection="$2"
      shift
      ;;
    --gh=*) selection="${1#--gh=}" ;;
    *) die 2 "unknown argument '$1' (usage: run.sh [--gh pinned|<v>[,<v>...]])" ;;
  esac
  shift
done

case "$selection" in
  pinned)
    versions="$(github_it_pin versions)" || die 2 "cannot read $ZENSU_GITHUB_IT_VERSIONS"
    ;;
  *)
    printf '%s' "$selection" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+\.[0-9]+)*$' \
      || die 2 "invalid --gh value '$selection'"
    versions="$(printf '%s' "$selection" | tr ',' ' ')"
    ;;
esac
[ -n "$versions" ] || die 2 'no gh version selected'
bash "$HERE/github-token.sh" --check || die 2 'the sandbox credentials are not configured'

mkdir -p "$CACHE" || die 2 "cannot create $CACHE"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  case "$holder" in
    (''|*[!0-9]*) die 2 "$LOCK exists without a holder pid; remove it once no run is active" ;;
  esac
  if kill -0 "$holder" 2>/dev/null; then
    die 2 "another run (pid $holder) holds $LOCK"
  fi
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || die 2 "cannot take over the stale lock $LOCK"
fi
printf '%s\n' "$$" > "$LOCK/pid"

teardown() {
  bash "$HERE/github-token.sh" --revoke || true
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
}
trap teardown EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

binaries=()
for version in $versions; do
  bin="$(bash "$HERE/gh-install.sh" "$version" "$CACHE/gh/$version")" || die 2 "gh $version could not be installed"
  binaries+=("$bin")
done

mkdir -p "$CACHE/gh-config"
failed=0
summary=""
for bin in "${binaries[@]}"; do
  version="$(GH_CONFIG_DIR="$CACHE/gh-config" GH_NO_UPDATE_NOTIFIER=1 "$bin" --version 2>/dev/null | head -n 1 | awk '{ print $3 }')"
  bash "$HERE/github-token.sh"
  minted=$?
  [ "$minted" -eq 0 ] || die "$minted" 'no installation token could be minted'
  if env -u ZENSU_GITHUB_IT_APP_KEY -u ZENSU_GITHUB_IT_APP_KEY_FILE ZENSU_GITHUB_IT_GH="$bin" bash "$HERE/test-vcs-github-live.sh"; then
    summary="$summary gh ${version:-?}: PASS;"
  else
    summary="$summary gh ${version:-?}: FAIL;"
    failed=1
  fi
  bash "$HERE/github-token.sh" --revoke || true
done

printf 'github-live:%s\n' "$summary"
exit "$failed"
