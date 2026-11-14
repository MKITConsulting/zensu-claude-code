#!/bin/bash
set -euo pipefail

SUPERSEDED="${1:-}"
VER="${2:-}"
CHANGELOG="${3:-}"
if [[ ! "$SUPERSEDED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ ! -f "$CHANGELOG" ]; then
  echo "::error::usage: session-hub-release-supersede.sh <superseded X.Y.Z> <new X.Y.Z> <changelog file>"
  exit 1
fi
MATCHES="$(grep -nE "^## \[${SUPERSEDED//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG" || true)"
if [ -z "$MATCHES" ] || [ "$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')" != 1 ]; then
  echo "::error::plugins/session-hub/CHANGELOG.md carries no single ## [$SUPERSEDED] - YYYY-MM-DD section to mark as superseded"
  exit 1
fi
LINE="${MATCHES%%:*}"
MARKED="$(mktemp)"
trap 'rm -f "$MARKED"' EXIT
awk -v n="$LINE" -v note=" (superseded by $VER, never published)" 'NR == n { print $0 note; next } { print }' "$CHANGELOG" > "$MARKED"
cat "$MARKED" > "$CHANGELOG"
echo "Marked the ## [$SUPERSEDED] section of plugins/session-hub/CHANGELOG.md as superseded by $VER and never published."
