#!/bin/bash
set -u

TRANSCRIPT="${1:-}"
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "usage: $0 <transcript-path>" >&2
  exit 2
fi

SUSPICIOUS=$(grep -nE '(^|[^>])(>|>>) |sed -i|tee ' "$TRANSCRIPT" 2>/dev/null | grep -vE 'zensu-log\.sh' || true)
if [ -n "$SUSPICIOUS" ]; then
  echo "WARN: possible state-file bypass writes detected:"
  echo "$SUSPICIOUS"
  exit 1
fi
exit 0
