#!/bin/bash
set -u

{ INPUT="$(cat)"; } 2>/dev/null
case "$INPUT" in
  *'<agent-message from='*'[Subagent hand-back]'*) ;;
  *) exit 0 ;;
esac
HOOK_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 0
printf '%s' "$INPUT" | bash "$HOOK_DIR/post-review-tdd-delegate.sh" --handback
exit 0
