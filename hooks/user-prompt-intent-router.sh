#!/bin/bash
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
zensu_hook_enabled intentRouter || exit 0
command -v node >/dev/null 2>&1 || exit 0

{ INPUT="$(cat)"; } 2>/dev/null
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" UserPromptSubmit || exit 0

PROMPT="$(printf '%s' "$INPUT" | node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
    process.stdout.write(typeof j.prompt === "string" ? j.prompt : "");
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"

[ -n "$PROMPT" ] || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-prompt-origin.sh"
case "$(zensu_prompt_origin "$PROMPT" "$INPUT")" in
  task-notification|agent-message|ci-monitor-event|bash-input|slash-command) exit 0 ;;
esac

KEYWORD_TEXT="$(printf '%s\n' "$PROMPT" | awk '
  {
    for (i = 1; i <= NF; i++) {
      t = $i
      if (skip) { skip = 0; continue }
      if (t == "--repo") { skip = 1; continue }
      if (index(t, "--repo=") == 1) continue
      if (index(t, "/") || index(t, "\\")) continue
      l = tolower(t)
      sub(/^[^a-z0-9]+/, "", l)
      if (l ~ /^zensu:[a-z0-9]/) continue
      printf " %s", t
    }
    printf "\n"
  }
')"

printf '%s' "$KEYWORD_TEXT" | grep -qiE '(^|[^[:alnum:]])(zensu|product|feature|roadmap|milestone|bootstrap|ghost.?scan|journey|tier)(s|es|ing|ed)?([^[:alnum:]]|$)' || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-prompt-ledger.sh"
ROUTER_SESSION_ID="$(printf '%s' "$INPUT" | node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
    process.stdout.write(typeof j.session_id === "string" ? j.session_id : "");
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"
ROUTER_KEY=''
if [ -n "$ROUTER_SESSION_ID" ]; then
  ROUTER_KEY="$(zensu_resolve_session_id "$ROUTER_SESSION_ID" 2>/dev/null)" || ROUTER_KEY=''
fi
if zensu_prompt_ledger_has "$ROUTER_KEY" router; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Zensu planning notice (the full notice given earlier in this context still applies): this prompt contains a product/planning keyword. If it is a genuine request to plan, track, bootstrap, scan or manage Zensu features, roadmap, journeys or tiers, your very next action is to ask the user the three project-context triage questions (is the code built, is there a plan or spec document, does the plan hold unbuilt items) instead of guessing them, before reading any file or launching a search; asking is read-only and allowed in Plan mode. Then route in this thread yourself: fresh code with a plan document to /zensu:bootstrap, built code without a plan to /zensu:ghost-scan, built code whose plan holds unbuilt items to the hybrid sequence, never delegating mutations to a child or running Zensu CLI mutations freelance. A request to continue, resume, conduct or status-check one feature already tracked in Zensu skips the triage and goes to /zensu:pilot. An ordinary coding, UI, design, debugging, refactor or content task that merely mentions such a word ignores this notice and is answered normally."}}'
  exit 0
fi

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "This prompt contains a product/planning keyword, so it MIGHT be a Zensu product-planning or product-tracking request — or it might just be ordinary work that mentions such a word. FIRST decide which. If it IS a genuine request to plan, track, bootstrap, scan, or manage features / roadmap / journeys / tiers in Zensu: your VERY NEXT action is to run the project-context triage — ASK the user these three questions directly and do NOT guess them: (1) is the code already built, or are you starting fresh? (2) is there a plan, vision, or spec document? (3) if both exist, does the plan describe items not yet built? Do NOT read files, do NOT launch Explore or search subagents, and do NOT try to 'ground' or understand the repo first before asking — the user answers these in seconds, and grounding-first is the same deferral trap as the 'no writes yet' excuse. Asking is READ-ONLY and is ALLOWED in Plan mode. Once the user answers, route in this top-level interactive thread: fresh code + plan doc -> /zensu:bootstrap (greenfield); built code + no plan -> /zensu:ghost-scan (brownfield); built code + plan with unbuilt items -> the hybrid sequence. Invoke the matching skill yourself; never delegate mutations to zensu-plm or another child and never call Zensu CLI mutations freelance. EXCEPTION — existing tracked feature: if the request is to continue, resume, conduct, or status-check ONE feature that is already tracked in Zensu (e.g. 'continue feature X', 'what's next for ZEN-42', 'guide me through this feature'), skip the triage entirely and route to the /zensu:pilot conductor skill instead — it probes the feature's real state and offers the next pipeline step. If instead this is an ordinary implementation, coding, UI, design, debugging, refactor, or content task that merely contains a word like 'product', 'feature', or 'tier' (for example 'add a modern hero section to my landing page', 'add a feature flag to checkout', 'optimize the cache tier latency'): IGNORE this notice entirely and answer the request normally — do NOT mention Zensu planning, do NOT run the triage. This is advisory steering, not a hard gate."
  }
}
JSON
zensu_prompt_ledger_mark "$ROUTER_KEY" router
exit 0
