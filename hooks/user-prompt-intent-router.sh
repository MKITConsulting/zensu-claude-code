#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
  echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
  exit 2
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled intentRouter || exit 0
command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

PROMPT="$(PAYLOAD="$INPUT" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    process.stdout.write(typeof j.prompt === "string" ? j.prompt : "");
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"

[ -n "$PROMPT" ] || exit 0

printf '%s' "$PROMPT" | grep -qiE '(^|[^[:alnum:]])(zensu|product|feature|roadmap|milestone|bootstrap|ghost.?scan|journey|tier)(s|es|ing|ed)?([^[:alnum:]]|$)' || exit 0

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This prompt contains a product/planning keyword, so it MIGHT be a Zensu product-planning or product-tracking request — or it might just be ordinary work that mentions such a word. FIRST decide which. If it IS a genuine request to plan, track, bootstrap, scan, or manage features / roadmap / journeys / tiers in Zensu: your VERY NEXT action is to run the project-context triage — ASK the user these three questions directly and do NOT guess them: (1) is the code already built, or are you starting fresh? (2) is there a plan, vision, or spec document? (3) if both exist, does the plan describe items not yet built? Do NOT read files, do NOT launch Explore or search subagents, and do NOT try to 'ground' or understand the repo first before asking — the user answers these in seconds, and grounding-first is the same deferral trap as the 'no writes yet' excuse. Asking is READ-ONLY and is ALLOWED in Plan mode. Once the user answers, route in this top-level interactive thread: fresh code + plan doc -> /zensu:bootstrap (greenfield); built code + no plan -> /zensu:ghost-scan (brownfield); built code + plan with unbuilt items -> the hybrid sequence. Invoke the matching skill yourself; never delegate mutations to zensu-plm or another child and never call Zensu CLI mutations freelance. EXCEPTION — existing tracked feature: if the request is to continue, resume, conduct, or status-check ONE feature that is already tracked in Zensu (e.g. 'continue feature X', 'what's next for ZEN-42', 'guide me through this feature'), skip the triage entirely and route to the /zensu:pilot conductor skill instead — it probes the feature's real state and offers the next pipeline step. If instead this is an ordinary implementation, coding, UI, design, debugging, refactor, or content task that merely contains a word like 'product', 'feature', or 'tier' (for example 'add a modern hero section to my landing page', 'add a feature flag to checkout', 'optimize the cache tier latency'): IGNORE this notice entirely and answer the request normally — do NOT mention Zensu planning, do NOT run the triage. This is advisory steering, not a hard gate."
  }
}
JSON
exit 0
