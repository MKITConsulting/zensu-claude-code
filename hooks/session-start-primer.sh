#!/bin/bash
# SessionStart hook — model-facing orientation. Injects a short primer via
# hookSpecificOutput.additionalContext (like plan-approved-delegate.sh) so the
# agent proactively follows Zensu conventions (Plan mode -> /zensu:tdd). Fires
# only on fresh starts (source=startup/clear); silent on resume/compact. Gated
# by hooks.sessionBanner (same flag as the user banner).
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled sessionBanner || exit 0
command -v node >/dev/null 2>&1 || exit 0

SOURCE="$(node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s||"{}");
    process.stdout.write(typeof j.source==="string"?j.source:""); } catch(_){ process.stdout.write(""); } });
' 2>/dev/null)"
case "$SOURCE" in
  resume|compact) exit 0 ;;
esac

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Zensu PLM plugin is active. Convention: for any task that adds or modifies executable code, prefer Claude Code Plan mode; when the user approves the plan, the /zensu:tdd skill auto-triggers (strict RED→GREEN TDD in the MAIN thread, PreToolUse phase-gate, guaranteed zensu:code-reviewer chain) — do not hand-implement code that should go through it. Feature planning and tracking run via the zensu-plm agent and /zensu:bootstrap or /zensu:ghost-scan. Use /zensu:zensu-help to answer questions about Zensu. This is a one-time per-session orientation; the plan-approval hook gives the authoritative directive at approval time."
  }
}
JSON
exit 0
