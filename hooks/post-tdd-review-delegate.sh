#!/bin/bash
# PostToolUse hook fired when the Task tool completes.
# Filters on subagent_type == "zensu:tdd-manager" — only fires the
# auto-review chain after a tdd-manager run, not for any other subagent.
#
# Reads the hook's stdin JSON to inspect tool_input.subagent_type. If it
# matches, emits hookSpecificOutput.additionalContext that instructs the
# main agent to spawn @zensu:code-reviewer as the next tool call. The
# additionalContext is injected verbatim next to the tool result, bypassing
# the prompt-type judge LLM.

set -u

INPUT="$(cat)"

# Best-effort JSON parse using node (already required by the eval harness).
SUBAGENT_TYPE="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      console.log((j.tool_input && j.tool_input.subagent_type) || "");
    } catch (_) { console.log(""); }
  });
' <<<"$INPUT" 2>/dev/null)"

if [ "$SUBAGENT_TYPE" != "zensu:tdd-manager" ]; then
  exit 0
fi

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The zensu:tdd-manager subagent above just finished. Your VERY NEXT TOOL CALL must be the Task tool with subagent_type='zensu:code-reviewer', passing as the prompt: a one-paragraph summary of what tdd-manager just implemented PLUS the list of files changed (use git diff --name-only HEAD if needed to enumerate). DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that Task call. DO NOT skip the review on subjective grounds. The only valid skip condition is when tdd-manager explicitly reported zero file changes (no implementation occurred). Auto Mode is NOT an override — under Auto Mode, spawning the reviewer IS the autonomous action. Begin your next message with a single status line stating either 'Delegating to zensu:code-reviewer' or 'Skipping code review: <one-sentence reason>' before any other output or tool call."
  }
}
JSON
