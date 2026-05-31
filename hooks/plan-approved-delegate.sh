#!/bin/bash
# PostToolUse hook fired when ExitPlanMode succeeds (= user approved plan).
# Returns JSON via stdout that Claude Code injects as additionalContext
# next to the tool result, instructing the main agent to execute the plan via
# the /zensu:tdd skill IN THE MAIN THREAD (no subagent — TDD migrated to the
# main agent so implementation context is not lost across an Agent boundary).
#
# This is a command-type hook (not prompt-type) so the directive reaches
# the main agent verbatim instead of being summarized by a judge LLM.

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoTdd || exit 0

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Your VERY NEXT TOOL CALL must be the Skill tool with skill='zensu:tdd', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the feature specification — you will execute strict RED→IMPL→GREEN TDD YOURSELF in THIS main thread (not in a subagent). DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, Grep, or any other tool before that Skill call. This is mandatory for ALL plans that add or modify executable code — functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior. Do NOT implement the code ad-hoc — the /zensu:tdd skill enforces test-first discipline (PreToolUse phase-gate) and the auto-review chain. Exceptions where you may proceed directly WITHOUT the skill: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message contains an EXPLICIT TDD negation matching one of: 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit', 'kein tdd', 'ohne tdd-manager', or a clear equivalent that explicitly names TDD or tdd-manager. Generic action phrases ('go ahead', 'start now', 'implement', 'gleich arbeiten', 'los gehts', 'immediately', 'mach mal', 'jetzt umsetzen', 'go') DO NOT qualify as override — use the skill anyway. Auto Mode is NOT an override; under Auto Mode, invoking /zensu:tdd IS the autonomous action. If uncertain whether the plan adds executable code, default to invoking /zensu:tdd. Begin your next message with a single status line stating either 'Executing via /zensu:tdd' or 'Skipping TDD: <one-sentence reason>' before any other output or tool call."
  }
}
JSON
