#!/bin/bash

zensu_hook_agent_id() {
  PAYLOAD="${1:-}" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j.agent_id;
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

zensu_hook_agent_type() {
  PAYLOAD="${1:-}" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j.agent_type;
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

zensu_is_spawned_agent() {
  local agent_id="${1:-}"
  local agent_type="${2:-}"
  if [ "${ZENSU_FORCE_MAIN:-}" = "1" ]; then
    echo "false"
    return 0
  fi
  if [ -n "$agent_id" ]; then
    echo "true"
    return 0
  fi
  case "$agent_type" in
    zensu:code-reviewer|zensu:review-aspect|zensu:review-judge)
      echo "true"
      return 0
      ;;
  esac
  echo "false"
}

export -f zensu_hook_agent_id zensu_hook_agent_type zensu_is_spawned_agent 2>/dev/null || true
