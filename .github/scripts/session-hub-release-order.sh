#!/bin/bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PLM_TAG="$(git tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
if [ -z "$PLM_TAG" ]; then
  echo "::error::no Zensu release tag vX.Y.Z exists; release Zensu first, then the companion"
  exit 1
fi
for file in hooks/usage-feed.ts hooks/usage-feed-contract.json; do
  if ! git show "$PLM_TAG:$file" 2>/dev/null | cmp -s - "plugins/session-hub/$file"; then
    echo "::error::plugins/session-hub/$file differs from $file in the newest Zensu release $PLM_TAG, so an installed Zensu would write the usage feed by another rule; release Zensu first, then the companion"
    exit 1
  fi
done
if ! git cat-file -e "$PLM_TAG:hooks/user-prompt-session-hub-takeover-notice.sh" 2>/dev/null; then
  echo "::error::the newest Zensu release $PLM_TAG ships no takeover notice for /session-hub:session-trail; release Zensu first, then the companion"
  exit 1
fi
echo "Zensu $PLM_TAG ships this companion's usage feed byte for byte and its takeover notice."
