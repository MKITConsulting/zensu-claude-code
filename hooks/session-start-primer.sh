#!/bin/bash
# SessionStart hook — model-facing orientation. Injects a short primer via
# hookSpecificOutput.additionalContext (like plan-approved-delegate.sh) so the
# agent proactively follows Zensu conventions (Plan mode -> /zensu:tdd). Fires
# only on fresh starts (source=startup/clear); silent on resume/compact. Gated
# by hooks.sessionBanner (same flag as the user banner).
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled sessionBanner || exit 0
command -v node >/dev/null 2>&1 || exit 0

{ INPUT="$(cat)"; } 2>/dev/null
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" SessionStart || exit 0

START_META="$(printf '%s' "$INPUT" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s||"{}");
    if (j.hook_event_name!=="SessionStart") process.exit(2);
    if (j.source!=="startup" && j.source!=="clear") process.exit(2);
    process.stdout.write(j.source+"\t"+j.hook_event_name);
  } catch(_){ process.exit(2); } });
' 2>/dev/null)" || exit 0
IFS=$'\t' read -r SOURCE HOOK_EVENT_NAME <<<"$START_META"
[ "$HOOK_EVENT_NAME" = "SessionStart" ] || exit 0
case "$SOURCE" in
  startup|clear) ;;
  *) exit 0 ;;
esac

# The emitted model command must never carry an empty or host-invalid plugin
# data selector. Session Control applies the same real-directory/no-alias
# invariant before any stateful helper binds.
case "${CLAUDE_PLUGIN_DATA:-}" in
  ""|*$'\r'*|*$'\n'*) exit 0 ;;
esac
[ -d "$CLAUDE_PLUGIN_DATA" ] && [ ! -L "$CLAUDE_PLUGIN_DATA" ] || exit 0

LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
PLUGIN_DATA_Q="$(printf '%q' "${CLAUDE_PLUGIN_DATA:-}")"
LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"
emit_context() {
  local msys_env_exclusions="ZENSU_LOG_COMMAND"
  if [ -n "${MSYS2_ENV_CONV_EXCL:-}" ]; then
    msys_env_exclusions="${MSYS2_ENV_CONV_EXCL};${msys_env_exclusions}"
  fi
  MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" ZENSU_LOG_COMMAND="$LOG_COMMAND" node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        const out = j.hookSpecificOutput || {};
        out.additionalContext = String(out.additionalContext || "")
          .split("__ZENSU_LOG_COMMAND__").join(process.env.ZENSU_LOG_COMMAND || "");
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
    "additionalContext": "Zensu PLM plugin is active. Convention: for any task that adds or modifies executable code, prefer Claude Code Plan mode; when the user approves the plan, the plan-approval hook directs you to ASK the user (via the AskUserQuestion tool) WHICH delivery route the plan takes — /zensu:autopilot (unattended through to a reviewed, validated pull request), /zensu:tdd (this plan now, under the strict flow and the review chain), /zensu:pilot (a guided pipeline for a feature already tracked in Zensu), or implementing it directly. On the /zensu:tdd route you run strict RED→GREEN TDD in the MAIN thread — FIRST arm the phase-gate via __ZENSU_LOG_COMMAND__ --tdd-begin, then declare every phase BEFORE acting via --phase <RED_WRITE|RED_RUN|RED_FAIL|IMPL|GREEN_RUN|GREEN_PASS> --step <id> (the --step id is required on every marker; the gate matches IMPL against RED_FAIL per step and DENIES production edits without it) — with the guaranteed zensu:code-reviewer chain after; on the direct route you implement the plan yourself. Either way, do not hand-implement code that should go through TDD without asking first (fast-paths that skip the question: doc-only plans, an explicit route preference already in the approval message, non-interactive Auto Mode — which never escalates to /zensu:autopilot, because that route pushes a branch and opens a pull request). Feature planning and tracking run through /zensu:bootstrap, /zensu:ghost-scan, or the matching skill in this same top-level interactive thread; never delegate mutations to a child. Continuing or conducting an EXISTING tracked feature runs via the /zensu:pilot conductor skill. Use /zensu:zensu-help to answer questions about Zensu. Zensu CLI auth recovery: if any zensu command fails with an authentication error (invalid_grant, expired or invalid token, not authenticated, or 401), your recovery action is to run zensu auth login yourself and retry the command — it is an interactive OAuth browser flow that auto-approves when a Zensu web session is already active, so run it rather than deferring to the user (only ask the user if the browser authorize step genuinely needs them). This is a one-time per-session orientation; the plan-approval hook gives the authoritative directive at approval time."
  }
}
JSON
else
cat <<'JSON' | emit_context
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Zensu PLM plugin is active in vanilla implementation mode (hooks.tddImplementation=false). Convention: for any task that adds or modifies executable code, prefer Claude Code Plan mode; when the user approves the plan, the plan-approval hook directs you to ASK the user (via the AskUserQuestion tool) WHICH delivery route the plan takes — /zensu:autopilot (unattended through to a reviewed, validated pull request), /zensu:tdd (this plan now, under the workflow and its review chain), /zensu:pilot (a guided pipeline for a feature already tracked in Zensu), or implementing it directly. On the /zensu:tdd route you run the implementation in vanilla mode in the MAIN thread — no RED→GREEN discipline, tests at your discretion; FIRST arm the workflow via __ZENSU_LOG_COMMAND__ --tdd-begin; the workflow keeps the Phase 5/6 evidence audits and the guaranteed zensu:code-reviewer chain. On the direct route you implement the plan yourself. Either way, do not hand-implement code that should go through the workflow without asking first (fast-paths that skip the question: doc-only plans, an explicit route preference already in the approval message, non-interactive Auto Mode — which never escalates to /zensu:autopilot, because that route pushes a branch and opens a pull request). Feature planning and tracking run through /zensu:bootstrap, /zensu:ghost-scan, or the matching skill in this same top-level interactive thread; never delegate mutations to a child. Continuing or conducting an EXISTING tracked feature runs via the /zensu:pilot conductor skill. Use /zensu:zensu-help to answer questions about Zensu. Zensu CLI auth recovery: if any zensu command fails with an authentication error (invalid_grant, expired or invalid token, not authenticated, or 401), your recovery action is to run zensu auth login yourself and retry the command — it is an interactive OAuth browser flow that auto-approves when a Zensu web session is already active, so run it rather than deferring to the user (only ask the user if the browser authorize step genuinely needs them). This is a one-time per-session orientation; the plan-approval hook gives the authoritative directive at approval time."
  }
}
JSON
fi
exit 0
