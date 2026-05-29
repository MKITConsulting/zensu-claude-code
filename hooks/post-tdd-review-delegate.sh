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
#
# Also owns auto-fix-rounds RESET on a fresh task boundary. Every auto-fix
# chain begins with a tdd-manager run whose prompt is a FEATURE SPECIFICATION
# (plan markdown or direct spec) — never the fix-delegation sentinel
# "findings from code review". That sentinel-free, non-empty prompt is the
# task boundary: this hook deletes the round counter
# (${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json)
# so the new task's review chain restarts at round 1. Safe polarity protects
# the max-rounds guard above all: reset ONLY when the sentinel is ABSENT and
# the prompt is non-empty. Sentinel present (fix round) or empty/unreadable
# prompt -> do NOT reset (counter keeps climbing; guard intact). Reset
# diagnostics go to stderr only; the stdout JSON directive is unchanged.

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoReview || exit 0

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

# --- Auto-fix-rounds reset at fresh task boundary -------------------------
# Inspect the tdd-manager prompt: a fix round starts with the load-bearing
# sentinel "Fix the following findings from code review:" (matched here on
# the stable "findings from code review" substring). A fresh task's prompt is
# the approved plan or a direct feature spec and never contains it.
PROMPT="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const p = j.tool_input && j.tool_input.prompt;
      process.stdout.write(typeof p === "string" ? p : "");
    } catch (_) { /* leave empty */ }
  });
' <<<"$INPUT" 2>/dev/null)"

PROMPT_EMPTY=1
[ -n "$PROMPT" ] && PROMPT_EMPTY=0

IS_FIX=0
case "$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')" in
  *"findings from code review"*) IS_FIX=1 ;;
esac

# Reset only on a fresh task (sentinel absent AND prompt non-empty). Sentinel
# present (fix round) or empty/unreadable prompt -> keep the counter so the
# max-rounds guard stays intact.
if [ "$IS_FIX" -eq 0 ] && [ "$PROMPT_EMPTY" -eq 0 ]; then
  RESET_SESSION_ID="$(node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        const id = j.session_id;
        console.log((typeof id === "string" && id) ? id : "");
      } catch (_) { console.log(""); }
    });
  ' <<<"$INPUT" 2>/dev/null)"
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  RESET_SESSION_ID="$(zensu_resolve_session_id "$RESET_SESSION_ID")"

  RESET_STATE_DIR="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  RESET_COUNTER_FILE="$RESET_STATE_DIR/rounds-${RESET_SESSION_ID}.json"
  if [ -L "$RESET_COUNTER_FILE" ]; then
    echo "zensu post-tdd hook: refusing to delete through symlink at $RESET_COUNTER_FILE — counter NOT reset" >&2
  elif [ -L "$RESET_STATE_DIR" ]; then
    echo "zensu post-tdd hook: refusing to reset under symlinked state dir $RESET_STATE_DIR — counter NOT reset" >&2
  else
    rm -f -- "$RESET_COUNTER_FILE"
  fi
fi
# ------------------------------------------------------------------------

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The zensu:tdd-manager subagent above just finished. Your VERY NEXT TOOL CALL must be the Task tool with subagent_type='zensu:code-reviewer', passing as the prompt: a one-paragraph summary of what tdd-manager just implemented PLUS the list of files changed (use git diff --name-only HEAD if needed to enumerate). DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that Task call. DO NOT skip the review on subjective grounds. The only valid skip condition is when tdd-manager explicitly reported zero file changes (no implementation occurred). Auto Mode is NOT an override — under Auto Mode, spawning the reviewer IS the autonomous action. Begin your next message with a single status line stating either 'Delegating to zensu:code-reviewer' or 'Skipping code review: <one-sentence reason>' before any other output or tool call."
  }
}
JSON
