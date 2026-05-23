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
  export CLAUDE_AGENT_TYPE="$AGENT"
fi

if [ -n "$AGENT" ]; then
  FULL_PROMPT="Use the Agent tool with subagent_type='${AGENT}' and prompt: ${PROMPT}"
else
  FULL_PROMPT="$PROMPT"
fi

CLONE_FLAGS="-cR"
CP_PROBE_SRC="$(mktemp -t cp-probe-src-XXXXXX 2>/dev/null || echo "")"
CP_PROBE_DST="$(mktemp -u -t cp-probe-dst-XXXXXX 2>/dev/null || echo "")"
if [ -n "$CP_PROBE_SRC" ] && [ -n "$CP_PROBE_DST" ]; then
  if ! cp -c "$CP_PROBE_SRC" "$CP_PROBE_DST" 2>/dev/null; then
    CLONE_FLAGS="-R"
  fi
  rm -f "$CP_PROBE_SRC" "$CP_PROBE_DST" 2>/dev/null
else
  CLONE_FLAGS="-R"
fi

ISOLATED_DIR="$(mktemp -d -t "claude-eval-XXXXXX")"
cleanup() {
  if [ "${KEEP_ISOLATED:-0}" = "1" ]; then
    echo "claude-promptfoo-wrapper: KEEP_ISOLATED=1, leaving $ISOLATED_DIR" >&2
  else
    rm -rf "$ISOLATED_DIR" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM HUP

CP_CMD=(cp "$CLONE_FLAGS" "$WORKDIR/." "$ISOLATED_DIR/")

CMD=(claude --print --output-format stream-json --include-partial-messages --verbose --dangerously-skip-permissions "$FULL_PROMPT")

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "DRY_RUN: would isolate (cwd=$WORKDIR -> isolated=$ISOLATED_DIR):"
  printf '  %q' "${CP_CMD[@]}"
  echo
  echo "DRY_RUN: would execute (cwd=$ISOLATED_DIR):"
  printf '  %q' "${CMD[@]}"
  echo
  exit 0
fi

if [ ! -d "$WORKDIR" ]; then
  echo "claude-promptfoo-wrapper: cannot cd to working_dir='$WORKDIR'" >&2
  exit 2
fi

if ! "${CP_CMD[@]}" 2>/dev/null; then
  echo "claude-promptfoo-wrapper: failed to clone working_dir='$WORKDIR' into '$ISOLATED_DIR'" >&2
  exit 2
fi

echo "claude-promptfoo-wrapper: isolated working dir: $ISOLATED_DIR" >&2

cd "$ISOLATED_DIR" || {
  echo "claude-promptfoo-wrapper: cannot cd to isolated dir='$ISOLATED_DIR'" >&2
  exit 2
}

export ZENSU_HOOK_LOG="$ISOLATED_DIR/.zensu/hook-events.log"
mkdir -p "$(dirname "$ZENSU_HOOK_LOG")" 2>/dev/null || true
: > "$ZENSU_HOOK_LOG" 2>/dev/null || true

CLAUDE_RAW="$("${CMD[@]}" 2>/dev/null)"
CLAUDE_RC=$?

printf '%s\n' "$CLAUDE_RAW" | jq -rs '
  map(select(.type == "assistant" or .type == "tool_use" or .type == "result"))
  | map(
      if .type == "assistant" then
        ((.message.content // []) | map(
          if .type == "text" then (.text // "")
          elif .type == "tool_use" then "[tool_use: \(.name // "?")] input=\(.input // {} | tostring)"
          else "" end
        ) | join("\n"))
      elif .type == "tool_use" then "[tool_use: \(.name // "?")] input=\(.input // {} | tostring)"
      elif .type == "result" then "[result] \(.result // "")"
      else "" end
    )
  | map(select(. != ""))
  | join("\n")
'

if [ -s "$ZENSU_HOOK_LOG" ]; then
  echo ""
  echo "===== hook events ====="
  cat "$ZENSU_HOOK_LOG"
fi

SAW_STATE=0
shopt -s nullglob
for sf in "$ISOLATED_DIR"/.zensu/state/tdd-phase-*.json; do
  [ -f "$sf" ] || continue
  SAW_STATE=1
  echo ""
  echo "===== fsm state: $(basename "$sf") ====="
  jq -r '
    "[fsm-state-final] phase=\(.phase // "UNINITIALIZED") step=\(.step_id // "?")",
    ((.history // []) | map("[fsm-history] step=\(.step // "?") phase=\(.phase // "?") ts=\(.ts // "?")") | join("\n"))
  ' "$sf" 2>/dev/null
done
shopt -u nullglob

if [ "$SAW_STATE" = "0" ] && [ -s "$ZENSU_HOOK_LOG" ] && grep -qE 'Current phase: UNINITIALIZED[,.]' "$ZENSU_HOOK_LOG"; then
  echo ""
  echo "[fsm-state-final] phase=UNINITIALIZED step=(none)"
fi

exit "$CLAUDE_RC"
