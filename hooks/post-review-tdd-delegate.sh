#!/bin/bash
# PostToolUse hook fired when the Task tool completes.
# Filters on subagent_type == "zensu:code-reviewer" — classifies findings
# by severity and routes ONLY Critical + Important to zensu:tdd-manager
# for proper TDD-cycle fixes (not inline Edit/Write).
#
# Suggestions / Minor / Nits are NOT auto-fixed: they are buffered in the
# main agent's response under "### Suggestions (not auto-fixed)".
#
# Convergence: when no Critical+Important findings exist, the main agent
# does NOT spawn tdd-manager again — prevents the reviewer/tdd-manager
# chain from looping when only Suggestions remain.

set -u

INPUT="$(cat)"

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

if [ "$SUBAGENT_TYPE" != "zensu:code-reviewer" ]; then
  exit 0
fi

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed' and stop. Do NOT spawn anything.\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT spawn tdd-manager. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)'. Then stop.\n\n(C) ANY Critical OR Important findings present — your VERY NEXT TOOL CALL must be the Agent tool with subagent_type='zensu:tdd-manager', passing as the prompt a FEATURE SPECIFICATION shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings in that spec. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed. Buffer the excluded Suggestions in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that Agent call. DO NOT fix findings inline yourself — that bypasses TDD discipline and is the exact behavior this hook exists to prevent. Auto Mode is NOT an override — under Auto Mode, dispatching to tdd-manager IS the autonomous action.\n\nBegin your next message with one of these status lines: 'Delegating critical+important findings to zensu:tdd-manager' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A)."
  }
}
JSON
