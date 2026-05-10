#!/bin/bash
# Empirical PostToolUse:Task logger for the T4 experiment in run-eval.sh.
# Reads the hook input (JSON on stdin) and appends a timestamped marker with
# the tool name and any subagent_type to a log file. Exits 0 silently to avoid
# perturbing Claude's flow.

LOG_FILE="${POSTTOOL_TASK_LOG:-/tmp/tdd-review-chain-posttool-task.log}"
INPUT="$(cat)"

TS="$(date +%Y-%m-%dT%H:%M:%S)"
SUBAGENT="$(printf '%s' "$INPUT" | node -e '
  let buf=""; process.stdin.on("data",d=>buf+=d); process.stdin.on("end",()=>{
    try {
      const j = JSON.parse(buf);
      const t = (j.tool_input && (j.tool_input.subagent_type || j.tool_input.subagentType)) || "";
      console.log(t);
    } catch(_) { console.log(""); }
  });
' 2>/dev/null)"

printf '[%s] PostToolUse:Task fired subagent_type=%s\n' "$TS" "$SUBAGENT" >> "$LOG_FILE"
exit 0
