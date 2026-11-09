#!/bin/bash
set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
HERE="$ZENSU_GITLAB_IT_HERE"
CACHE="$ZENSU_GITLAB_IT_CACHE"
NAME="$ZENSU_GITLAB_IT_CONTAINER"
LOCK="$CACHE/run.lock"

die() {
  local code="$1"
  shift
  printf 'gitlab-live: %s\n' "$*" >&2
  exit "$code"
}

selection=pinned
keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --glab)
      [ $# -ge 2 ] || die 2 '--glab needs pinned or a comma-separated list of pinned versions'
      selection="$2"
      shift
      ;;
    --glab=*) selection="${1#--glab=}" ;;
    --keep) keep=1 ;;
    *) die 2 "unknown argument '$1' (usage: run.sh [--glab pinned|<v>[,<v>...]] [--keep])" ;;
  esac
  shift
done

case "$selection" in
  pinned)
    versions="$(gitlab_it_pin versions)" || die 2 "cannot read $ZENSU_GITLAB_IT_VERSIONS"
    ;;
  *)
    printf '%s' "$selection" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(,[0-9]+\.[0-9]+\.[0-9]+)*$' \
      || die 2 "invalid --glab value '$selection'"
    versions="$(printf '%s' "$selection" | tr ',' ' ')"
    ;;
esac
[ -n "$versions" ] || die 2 'no glab version selected'

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

started_here=0
teardown() {
  if [ "$started_here" = 1 ] && [ "$keep" = 0 ]; then
    bash "$HERE/gitlab-down.sh" || true
  fi
  rm -f "$LOCK/pid"
  rmdir "$LOCK" 2>/dev/null || true
}
trap teardown EXIT

binaries=()
for version in $versions; do
  bin="$(bash "$HERE/glab-install.sh" "$version" "$CACHE/glab/$version")" || die 2 "glab $version could not be installed"
  binaries+=("$bin")
done

if ! docker inspect "$NAME" >/dev/null 2>&1; then
  started_here=1
fi

bash "$HERE/gitlab-up.sh" || die 2 'GitLab did not come up'

failed=0
summary=""
for bin in "${binaries[@]}"; do
  version="$("$bin" --version 2>/dev/null | head -n 1 | awk '{ print $2 }')"
  if ZENSU_GITLAB_IT_GLAB="$bin" bash "$HERE/test-vcs-gitlab-live.sh"; then
    summary="$summary glab ${version:-?}: PASS;"
  else
    summary="$summary glab ${version:-?}: FAIL;"
    failed=1
  fi
done

printf 'gitlab-live:%s\n' "$summary"
exit "$failed"
