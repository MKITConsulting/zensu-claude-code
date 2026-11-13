#!/bin/bash
set -euo pipefail

VERSION_TYPE="${1:-}"
SUPERSEDE="${2:-}"
OUT="${3:-}"
case "$VERSION_TYPE" in
  (patch|minor|major) ;;
  (*)
    echo "::error::unknown version_type: ${VERSION_TYPE:-<none>}"
    exit 1
    ;;
esac
case "$SUPERSEDE" in
  (true|false) ;;
  (*)
    echo "::error::supersede must be true or false, got: ${SUPERSEDE:-<none>}"
    exit 1
    ;;
esac
case "$OUT" in
  (/*) ;;
  (*)
    echo "::error::usage: session-hub-release-version.sh patch|minor|major true|false <absolute output file>"
    exit 1
    ;;
esac
cd "$(git rev-parse --show-toplevel)"

CURRENT="$(jq -r .version plugins/session-hub/.claude-plugin/plugin.json)"
if [[ ! "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::plugins/session-hub/.claude-plugin/plugin.json carries no X.Y.Z version"
  exit 1
fi
LATEST="$(git tag -l 'session-hub--v*' | sed -n -E 's/^session-hub--v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -V | tail -n 1)"
SUPERSEDED=""
if [ "$LATEST" != "$CURRENT" ]; then
  if [ "$SUPERSEDE" != true ]; then
    echo "::error::plugins/session-hub is at $CURRENT and the newest companion tag is session-hub--v${LATEST:-<none>}; publish $CURRENT first (mode: publish), or dispatch prepare with supersede: true when $CURRENT can never be published"
    exit 1
  fi
  if [ -n "$LATEST" ] && [ "$(printf '%s\n%s\n' "$LATEST" "$CURRENT" | sort -V | tail -n 1)" != "$CURRENT" ]; then
    echo "::error::supersede replaces an untagged version newer than every companion tag; session-hub--v$LATEST is not older than $CURRENT"
    exit 1
  fi
  SUPERSEDED="$CURRENT"
elif [ "$SUPERSEDE" = true ]; then
  echo "::error::supersede applies only while plugins/session-hub $CURRENT has no tag; session-hub--v$CURRENT exists, so dispatch prepare without supersede"
  exit 1
fi

IFS='.' read -r MA MI PA <<< "$CURRENT"
MA=$((10#$MA)); MI=$((10#$MI)); PA=$((10#$PA))
case "$VERSION_TYPE" in
  (major) MA=$((MA + 1)); MI=0; PA=0 ;;
  (minor) MI=$((MI + 1)); PA=0 ;;
  (patch) PA=$((PA + 1)) ;;
esac
VER="$MA.$MI.$PA"
printf 'version=%s\ntag=%s\nsuperseded=%s\n' "$VER" "session-hub--v$VER" "$SUPERSEDED" > "$OUT"
echo "Companion version: $CURRENT -> $VER${SUPERSEDED:+ ($SUPERSEDED is superseded and never published)}"
