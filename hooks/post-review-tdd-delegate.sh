#!/bin/bash
# PostToolUse hook fired when the Task tool completes.
# Filters on subagent_type == "zensu:code-reviewer" and routes findings to
# zensu:tdd-manager via additionalContext.
#
# Behavior is configurable via ~/.zensu/config.json (resolution order: env,
# project-local, global):
#   hooks.autoFixIncludeSuggestions=true  -> route ALL severities
#   hooks.autoFixIncludeSuggestions=false -> route Critical+Important only (default, backward-compat)
#   hooks.autoFixMaxRounds=<int 1..99>    -> loop guard (default 5)
#
# Counter state lives at ${CLAUDE_PLUGIN_DATA:-$HOME/.zensu/state}/rounds-<session_id>.json.

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoFix || exit 0

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

SESSION_ID="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const id = j.session_id;
      console.log((typeof id === "string" && id) ? id : "unknown");
    } catch (_) { console.log("unknown"); }
  });
' <<<"$INPUT" 2>/dev/null)"
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
SESSION_ID="${SESSION_ID//[^A-Za-z0-9_-]/_}"
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"

MAX_ROUNDS="$(zensu_autofix_max_rounds)"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.zensu/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
COUNTER_FILE="$STATE_DIR/rounds-${SESSION_ID}.json"

CURRENT="$(node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const n = j && j.count;
    console.log(Number.isInteger(n) && n >= 0 ? String(n) : "0");
  } catch (_) { console.log("0"); }
' "$COUNTER_FILE" 2>/dev/null)"
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac
NEXT=$((CURRENT + 1))

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if TMP_FILE="$(mktemp "${STATE_DIR}/rounds-${SESSION_ID}.XXXXXX" 2>/dev/null)"; then
  if printf '{"count":%d,"ts":"%s"}\n' "$NEXT" "$TS" > "$TMP_FILE" \
     && mv "$TMP_FILE" "$COUNTER_FILE" 2>/dev/null; then
    :
  else
    rm -f "$TMP_FILE" 2>/dev/null
    echo "zensu post-review hook: failed to persist counter for session ${SESSION_ID} (write/mv)" >&2
    if ! printf '{"count":%d,"ts":"%s"}\n' "$NEXT" "$TS" > "$COUNTER_FILE" 2>/dev/null; then
      echo "zensu post-review hook: fallback direct write also failed; counter NOT updated" >&2
    fi
  fi
else
  echo "zensu post-review hook: mktemp failed under ${STATE_DIR} for session ${SESSION_ID}" >&2
  if ! printf '{"count":%d,"ts":"%s"}\n' "$NEXT" "$TS" > "$COUNTER_FILE" 2>/dev/null; then
    echo "zensu post-review hook: fallback direct write also failed; counter NOT updated" >&2
  fi
fi

if [ "$NEXT" -gt "$MAX_ROUNDS" ]; then
  CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. Do NOT spawn zensu:tdd-manager again. Reply with remaining findings under '### Findings (max rounds reached, manual fix required)' and stop."
  node -e '
    const msg = process.argv[1];
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: msg
      }
    }));
  ' "$CONV_MSG"
  echo
  exit 0
fi

if zensu_autofix_include_suggestions; then
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed' and stop. Do NOT spawn anything.\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — your VERY NEXT TOOL CALL must be the Agent tool with subagent_type='zensu:tdd-manager', passing as the prompt a FEATURE SPECIFICATION shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ALL findings regardless of severity in that spec. INCLUDE every finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering. DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that Agent call. DO NOT fix findings inline yourself — that bypasses TDD discipline and is the exact behavior this hook exists to prevent. Auto Mode is NOT an override — under Auto Mode, dispatching to tdd-manager IS the autonomous action.\n\nBegin your next message with one of these status lines: 'Delegating all findings to zensu:tdd-manager (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A)."
else
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed' and stop. Do NOT spawn anything.\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT spawn tdd-manager. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)'. Then stop.\n\n(C) ANY Critical OR Important findings present — your VERY NEXT TOOL CALL must be the Agent tool with subagent_type='zensu:tdd-manager', passing as the prompt a FEATURE SPECIFICATION shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings in that spec. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed. Buffer the excluded Suggestions in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. DO NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that Agent call. DO NOT fix findings inline yourself — that bypasses TDD discipline and is the exact behavior this hook exists to prevent. Auto Mode is NOT an override — under Auto Mode, dispatching to tdd-manager IS the autonomous action.\n\nBegin your next message with one of these status lines: 'Delegating critical+important findings to zensu:tdd-manager' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A)."
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"

node -e '
  const msg = process.argv[1];
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: msg
    }
  }));
' "$EXPANDED_MSG"
echo
