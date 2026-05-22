#!/bin/bash
set -u

if ! command -v claude >/dev/null 2>&1; then
  echo "claude-promptfoo-wrapper: claude CLI not found on PATH — install Claude Code CLI." >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "claude-promptfoo-wrapper: jq not found on PATH — install jq." >&2
  exit 127
fi

PROMPT="${1:-}"
OPTIONS_JSON="${2:-{}}"

AGENT="$(echo "$OPTIONS_JSON" | jq -r '.config.agent // ""' 2>/dev/null)"
WORKDIR="$(echo "$OPTIONS_JSON" | jq -r '.config.working_dir // "."' 2>/dev/null)"
[ -z "$WORKDIR" ] && WORKDIR="."

if [ -n "$AGENT" ]; then
  FULL_PROMPT="Use the Agent tool with subagent_type='${AGENT}' and prompt: ${PROMPT}"
else
  FULL_PROMPT="$PROMPT"
fi

CMD=(claude --print --output-format json --dangerously-skip-permissions "$FULL_PROMPT")

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would execute (cwd=$WORKDIR):"
  printf '  %q' "${CMD[@]}"
  echo
  exit 0
fi

cd "$WORKDIR" || {
  echo "claude-promptfoo-wrapper: cannot cd to working_dir='$WORKDIR'" >&2
  exit 2
}

exec "${CMD[@]}"
