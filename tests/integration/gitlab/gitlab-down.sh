#!/bin/bash
set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
NAME="$ZENSU_GITLAB_IT_CONTAINER"
STATE="$ZENSU_GITLAB_IT_STATE"

label="$(docker inspect -f "{{index .Config.Labels \"$ZENSU_GITLAB_IT_LABEL\"}}" "$NAME" 2>/dev/null || true)"
if [ "$label" = 1 ]; then
  docker rm -f -v "$NAME" >/dev/null 2>&1 || {
    printf 'gitlab-down: could not remove container %s\n' "$NAME" >&2
    exit 1
  }
elif [ -n "$label" ] || docker inspect "$NAME" >/dev/null 2>&1; then
  printf 'gitlab-down: container %s was not started by gitlab-up.sh; left alone\n' "$NAME" >&2
  exit 1
fi

rm -f "$STATE/header" "$STATE/token" "$STATE/url" "$STATE/image"
rmdir "$STATE" 2>/dev/null || true
printf 'GitLab container %s removed\n' "$NAME"
