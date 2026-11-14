#!/bin/bash
set -euo pipefail

VER="${1:-}"
CHANGELOG="${2:-}"
OUT="${3:-}"
if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ -z "$CHANGELOG" ] || [ -z "$OUT" ]; then
  echo "::error::usage: session-hub-release-notes.sh X.Y.Z <changelog file> <notes file>"
  exit 1
fi
if ! grep -qE "^## \[${VER//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG"; then
  echo "::error::plugins/session-hub/CHANGELOG.md carries no ## [$VER] - YYYY-MM-DD section"
  exit 1
fi
awk -v head="## [$VER] - " '
  index($0, head) == 1 && !seen { f = 1; seen = 1; next }
  f && /^## \[/ { f = 0 }
  f { print }
' "$CHANGELOG" > "$OUT"
if [ -z "$(tr -d '[:space:]' < "$OUT")" ]; then
  echo "::error::the ## [$VER] section of plugins/session-hub/CHANGELOG.md is empty"
  exit 1
fi
