#!/bin/bash
set -euo pipefail

OUT="${1:-}"
NOTES="${2:-}"
case "$OUT|$NOTES" in
  (/*\|/*) ;;
  (*)
    echo "::error::usage: session-hub-release-target.sh <absolute output file> <absolute notes file>"
    exit 1
    ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd -P)"
cd "$(git rev-parse --show-toplevel)"

HEAD_SHA="$(git rev-parse HEAD)"
VER="$(jq -r .version plugins/session-hub/.claude-plugin/plugin.json)"
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::plugins/session-hub/.claude-plugin/plugin.json carries no X.Y.Z version"
  exit 1
fi
TAG="session-hub--v$VER"
TARGET=""
while read -r COMMIT; do
  [ "$(git show "$COMMIT:plugins/session-hub/.claude-plugin/plugin.json" 2>/dev/null | jq -r .version 2>/dev/null)" = "$VER" ] || break
  TARGET="$COMMIT"
done < <(git log --first-parent --format=%H "$HEAD_SHA" -- plugins/session-hub/.claude-plugin/plugin.json)
if [ -z "$TARGET" ]; then
  echo "::error::no commit on the first-parent line of $HEAD_SHA introduces plugins/session-hub $VER"
  exit 1
fi
if [ "${GITHUB_EVENT_NAME:-}" = push ] && [ "$TARGET" != "$HEAD_SHA" ]; then
  echo "::error::the pushed release commit $HEAD_SHA does not introduce session-hub $VER; $TARGET does"
  exit 1
fi
HUB_ENTRY='[.plugins[] | select(.name == "session-hub")] | select(length == 1) | .[0]'
if ! git show "$TARGET:.claude-plugin/marketplace.json" | jq -e --arg ver "$VER" --arg tag "$TAG" "$HUB_ENTRY"' | .version == $ver
    and (.source | keys | sort) == ["path", "ref", "source", "url"]
    and .source.source == "git-subdir"
    and .source.url == "https://github.com/MKITConsulting/zensu-claude-code.git"
    and .source.path == "plugins/session-hub"
    and .source.ref == $tag' > /dev/null; then
  echo "::error::the session-hub marketplace entry at $TARGET is not the git-subdir entry for $TAG"
  exit 1
fi
CHANGELOG_AT_TARGET="$(mktemp)"
trap 'rm -f "$CHANGELOG_AT_TARGET"' EXIT
git show "$TARGET:plugins/session-hub/CHANGELOG.md" > "$CHANGELOG_AT_TARGET"
bash "$HERE/session-hub-release-notes.sh" "$VER" "$CHANGELOG_AT_TARGET" "$NOTES"
TAGGED=false
if git rev-parse --verify --quiet "refs/tags/$TAG" > /dev/null; then
  TAG_SHA="$(git rev-list -n 1 "refs/tags/$TAG")"
  if [ "$TAG_SHA" != "$TARGET" ]; then
    echo "::error::$TAG already exists at $TAG_SHA, not at $TARGET, the commit that introduced session-hub $VER; a maintainer has to account for that tag before the companion can be released"
    exit 1
  fi
  TAGGED=true
fi
printf 'version=%s\ntag=%s\ntarget=%s\ntagged=%s\n' "$VER" "$TAG" "$TARGET" "$TAGGED" > "$OUT"
echo "session-hub $VER: release target $TARGET, tag $TAG (exists: $TAGGED)"
