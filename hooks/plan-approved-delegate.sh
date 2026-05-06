#!/bin/bash
# PostToolUse hook fired when ExitPlanMode succeeds (= user approved plan).
# Returns JSON via stdout that Claude Code injects as additionalContext
# next to the tool result, instructing the main agent to delegate execution
# to the zensu:tdd-manager subagent.
#
# This is a command-type hook (not prompt-type) so the directive reaches
# the main agent verbatim instead of being summarized by a judge LLM.

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Your VERY NEXT TOOL CALL must be the Agent tool with subagent_type='zensu:tdd-manager', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the subagent's prompt — that prompt IS the feature specification. DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, Grep, or any other tool before that Agent call. This is mandatory for ALL plans that add or modify executable code — functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior. Do NOT implement the code yourself. Exceptions where you may proceed directly WITHOUT spawning the subagent: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message contains an EXPLICIT TDD negation matching one of: 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit', 'kein tdd', 'ohne tdd-manager', or a clear equivalent that explicitly names TDD or tdd-manager. Generic action phrases ('go ahead', 'start now', 'implement', 'gleich arbeiten', 'los gehts', 'immediately', 'mach mal', 'jetzt umsetzen', 'go') DO NOT qualify as override — delegate anyway. Auto Mode is NOT an override; under Auto Mode, spawning tdd-manager IS the autonomous action. If uncertain whether the plan adds executable code, default to spawning tdd-manager. Begin your next message with a single status line stating either 'Delegating to zensu:tdd-manager' or 'Skipping TDD: <one-sentence reason>' before any other output or tool call."
  }
}
JSON
