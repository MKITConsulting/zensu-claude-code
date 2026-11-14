#!/bin/bash
set -euo pipefail

MESSAGE="${1:-}"
if [ -z "$MESSAGE" ]; then
  echo "::error::usage: session-hub-require-immutable-releases.sh <error message>"
  exit 1
fi
if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::IMMUTABLE_RELEASES_ADMIN_TOKEN with read access to repository settings is required"
  exit 1
fi
if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "::error::GITHUB_REPOSITORY is not set"
  exit 1
fi
ENABLED="$(gh api -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$GITHUB_REPOSITORY/immutable-releases" \
  --jq '.enabled')" || {
  echo "::error::$MESSAGE (the Immutable Releases setting could not be read)"
  exit 1
}
if [ "$ENABLED" != true ]; then
  echo "::error::$MESSAGE"
  exit 1
fi
echo "GitHub Immutable Releases is enabled for $GITHUB_REPOSITORY."
