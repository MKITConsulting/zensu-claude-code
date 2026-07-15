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

LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
emit_context() {
  ZENSU_LOG_HELPER_Q="$LOG_HELPER_Q" node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        const out = j.hookSpecificOutput || {};
        out.additionalContext = String(out.additionalContext || "")
          .split("__ZENSU_LOG_HELPER_Q__").join(process.env.ZENSU_LOG_HELPER_Q || "");
        process.stdout.write(JSON.stringify(j));
      } catch (_) { process.exitCode = 1; }
    });
  '
}

if zensu_tdd_strict_enabled; then
cat <<'JSON' | emit_context
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Zensu PLM plugin is active. Convention: for any task that adds or modifies executable code, prefer Claude Code Plan mode; when the user approves the plan, the plan-approval hook directs you to ASK the user (via the AskUserQuestion tool) whether to run the /zensu:tdd skill. On yes you run strict RED→GREEN TDD in the MAIN thread — FIRST arm the phase-gate via bash __ZENSU_LOG_HELPER_Q__ --tdd-begin, then declare every phase BEFORE acting via --phase <RED_WRITE|RED_RUN|RED_FAIL|IMPL|GREEN_RUN|GREEN_PASS> --step <id> (the --step id is required on every marker; the gate matches IMPL against RED_FAIL per step and DENIES production edits without it) — with the guaranteed zensu:code-reviewer chain after; on no you implement the plan directly. Either way, do not hand-implement code that should go through TDD without asking first (fast-paths that skip the question: doc-only plans, an explicit TDD preference already in the approval message, non-interactive Auto Mode). Feature planning and tracking run via the zensu-plm agent and /zensu:bootstrap or /zensu:ghost-scan; continuing or conducting an EXISTING tracked feature runs via the /zensu:pilot conductor skill. Use /zensu:zensu-help to answer questions about Zensu. Zensu CLI auth recovery: if any zensu command fails with an authentication error (invalid_grant, expired or invalid token, not authenticated, or 401), your recovery action is to run zensu auth login yourself and retry the command — it is an interactive OAuth browser flow that auto-approves when a Zensu web session is already active, so run it rather than deferring to the user (only ask the user if the browser authorize step genuinely needs them). This is a one-time per-session orientation; the plan-approval hook gives the authoritative directive at approval time."
  }
}
JSON
else
cat <<'JSON' | emit_context
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Zensu PLM plugin is active in vanilla implementation mode (hooks.tddImplementation=false). Convention: for any task that adds or modifies executable code, prefer Claude Code Plan mode; when the user approves the plan, the plan-approval hook directs you to ASK the user (via the AskUserQuestion tool) whether to run the /zensu:tdd skill. On yes you run the implementation in vanilla mode in the MAIN thread — no RED→GREEN discipline, tests at your discretion; the workflow keeps the Phase 5/6 evidence audits and the guaranteed zensu:code-reviewer chain. On no you implement the plan directly. Either way, do not hand-implement code that should go through the workflow without asking first (fast-paths that skip the question: doc-only plans, an explicit preference already in the approval message, non-interactive Auto Mode). Feature planning and tracking run via the zensu-plm agent and /zensu:bootstrap or /zensu:ghost-scan; continuing or conducting an EXISTING tracked feature runs via the /zensu:pilot conductor skill. Use /zensu:zensu-help to answer questions about Zensu. Zensu CLI auth recovery: if any zensu command fails with an authentication error (invalid_grant, expired or invalid token, not authenticated, or 401), your recovery action is to run zensu auth login yourself and retry the command — it is an interactive OAuth browser flow that auto-approves when a Zensu web session is already active, so run it rather than deferring to the user (only ask the user if the browser authorize step genuinely needs them). This is a one-time per-session orientation; the plan-approval hook gives the authoritative directive at approval time."
  }
}
JSON
fi
exit 0
