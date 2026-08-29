#!/bin/bash
# UserPromptSubmit hook — zen-mode re-injection. While zen-mode resolves to active
# for the current session, this hook injects the mode contract as additionalContext
# on every prompt. A skill is loaded once and fades after a handful of turns; a
# low-capacity user is the least likely to notice that drift, so the reminder rides
# along with each prompt instead.
#
# Resolution is three-valued, most specific first:
#   1. session marker `{"active":true|false}` — the choice this session recorded,
#      through /zensu:zen-mode, hooks/lib/zensu-zen-mode.sh, or the off-branch below
#   2. hooks.zenModeDefault — the configured default, itself defaulting to TRUE
# A symlinked marker or state directory, and a marker that does not spell out an
# active mode, both resolve to OFF: unreadable state must never impose the mode on
# a user who may have just left it.
#
# Deactivation is handled HERE rather than by the model: a prompt matching the
# off-phrases writes `{"active":false}` directly, so "normal mode" still works
# after the model has drifted. It WRITES rather than deletes on purpose — under a
# true default, removing the marker would re-enable the mode the user just left.
# The marker is keyed by the resolved Session Control key, so a fresh session
# always starts from the configured default and one session's choice never leaks
# into another.
#
# The marker root comes from zensu_resolve_project_dir, the same accessor the
# writer uses. It is deliberately NOT $ZENSU_PROJECT_ROOT: Session Control records
# the host-native path, which on Git Bash is a different namespace from the MSYS
# spelling shell builtins need, so concatenating the raw root here would have the
# hook stat a path the helper never wrote.
#
# Disable the hook entirely with hooks.zenMode:false in .zensu/config.json, or
# keep it and flip the default off with hooks.zenModeDefault:false — both are
# resolved through the usual env -> project-local -> global order. Every path after
# the plugin-root identity check exits 0 — missing node, unbindable session, absent
# marker, or a non-main principal are all silent no-ops and never block the prompt.
# The identity check itself exits 2, matching every other hook in this plugin.
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
{ INPUT="$(cat)"; } 2>/dev/null
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" UserPromptSubmit || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
zensu_bind_hook_session "$INPUT" || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled zenMode || exit 0
command -v node >/dev/null 2>&1 || exit 0

read_field() {
  PAYLOAD="$INPUT" FIELD="$1" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.FIELD];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

[ -n "${ZENSU_SESSION_KEY:-}" ] || exit 0
ZEN_ROOT="$(zensu_resolve_project_dir)" || exit 0
[ -n "$ZEN_ROOT" ] || exit 0

ZEN_STATE_DIR="$ZEN_ROOT/.zensu/state"
MARKER="$ZEN_STATE_DIR/zen-mode-${ZENSU_SESSION_KEY}.json"

# Resolve before the prompt is ever read, so a session whose mode is off keeps
# paying nothing for prompt extraction.
if [ -L "$ZEN_STATE_DIR" ] || [ -L "$MARKER" ]; then
  exit 0
elif [ -f "$MARKER" ]; then
  grep -q '"active"[[:space:]]*:[[:space:]]*true' "$MARKER" 2>/dev/null || exit 0
else
  zensu_zen_mode_default_on || exit 0
fi

PROMPT="$(read_field prompt)"

ZEN_OFF=0
if [ -n "$PROMPT" ]; then
  if printf '%s' "$PROMPT" \
    | grep -qiE '(^|[^[:alnum:]])(zen[ -]?(mode )?off|stop zen|turn off zen([ -]?mode)?)([^[:alnum:]]|$)'; then
    ZEN_OFF=1
  else
    case "$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '[:punct:]')" in
      normalmode) ZEN_OFF=1 ;;
    esac
  fi
fi

if [ "$ZEN_OFF" -eq 1 ]; then
  ZEN_OFF_RECORDED=0
  if mkdir -p -m 700 "$ZEN_STATE_DIR" 2>/dev/null \
    && { printf '{"active":false}\n' > "$MARKER"; } 2>/dev/null; then
    grep -q '"active"[[:space:]]*:[[:space:]]*true' "$MARKER" 2>/dev/null || ZEN_OFF_RECORDED=1
  fi
  if [ "$ZEN_OFF_RECORDED" -eq 0 ]; then
    cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "zen-mode COULD NOT BE DEACTIVATED: the session marker under .zensu/state/ could not be written, so the mode is still on and this hook will keep re-injecting it. Tell the user this in one plain sentence, name the .zensu/state/ directory as the place to look, and then answer their request normally. Do not silently ignore this."
  }
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "zen-mode is now OFF — the user asked for it. Drop the zen-mode response shape entirely and answer in your ordinary style from this response onward. Mention the switch in one short clause, then answer the request. Do not keep the recap line or the single-next-step ending unless they genuinely help this particular answer."
  }
}
JSON
  exit 0
fi

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "zen-mode is ACTIVE. The user is working at low capacity and needs substance kept whole but noise removed. Shape this response accordingly, writing in the user's own language: (1) Open with ONE short recap line covering what happened since their last message; omit it when nothing happened. (2) Give the result in the first sentence after that — no preamble, no announcing what is coming. (3) Stay near 8 lines and leave out caveats and history you were not asked for, and trade-offs or alternatives you were NOT asked to choose between — never the options of a decision that is actually in front of the user; when you deliberately withheld depth, close with a short offer instead. (4) Write full, short sentences. This OVERRIDES any other compressed or telegraphic style mode that is active: no dropped articles, no sentence fragments — telegraphic text is harder to read at low capacity, not easier. (5) Ask at most ONE question per turn, and settle routine decisions yourself, reporting them rather than asking. (6) Gloss unavoidable jargon in three words or fewer, show code as changed lines only, and anchor work that spans several turns with a one-line chain-progress line, placed directly above the closing next step — or above the final step list when the one-next-step rule is suspended. Render the steps of THIS run in order on ONE line, each prefixed '✓' for a step you observed finish AND pass, '▶' for the step running now, '·' for one not yet reached, and '✗' for one that failed or is blocked; a step that finished with a failing or unresolved outcome is '✗' and never a tick — for example 'Run: ✓fetch ✓parse ▶render', where 'Run:' is a fixed English prefix and not a mark, and where those step names are illustrative rather than a list to reuse. The line describes where the run stands NOW, so a step that failed and is being retried carries the mark of its current attempt rather than of the attempt that failed — the anchor is a position, not a history; that governs the MARK only, and an earlier failure is still reported in the prose of the turn it happened in. Name the steps this run actually has, taking them from what this session observed and from the steps you have already told the user you will take — when you have named none, show the steps so far plus the one running. Never copy a canonical pipeline out of another component, never pad with steps nobody planned, and never drop one the run traversed, with one exception: a step the run deliberately did not perform is left off the line rather than marked failed. Use short lower-case step names, and let only the words around them follow the user's language. A step is marked done from an observation, never from the plan, so a step you did not see finish stays '·'. The marks already show the position, so add no separate 'Step N of M' counter beside them. (7) End with exactly ONE next step, never two parallel suggestions. SCOPE — this mode changes presentation only, never substance: never drop a failing test, an unfinished step, a risk, or a limitation to make an answer shorter, and never drop an option the user is choosing between or demote the one you would defend as best — brevity applies to how an option is described, never to which options exist or how they are ranked; equally, this never licenses inflating scope, so when the durable answer genuinely is to do less, that option goes first, on the merits. Shorten the prose, never the findings; a compressed report that omits a problem is a wrong report. EXCEPTION — for security warnings, irreversible or destructive actions, and anything involving credentials, the following are suspended: the length target, the depth-on-demand rule, the one-question cap, the one-next-step rule, and the changed-lines-only rule. Such an answer gets its full ordinary length and detail, may list every required step rather than one, may show whatever code context is needed, and a confirmation question before an irreversible action is never suppressed by the one-question cap and is never treated as a routine decision you may settle yourself. The full-sentence rule is NEVER suspended — a safety warning is the last place for fragments. The user leaves the mode by writing 'normal mode', 'zen off', 'zen-mode off', 'turn off zen', or 'stop zen'; if they ask to leave it in any other wording or in another language, that counts too — run the zen-mode helper's --off verb yourself (hooks/lib/zensu-zen-mode.sh in the Zensu plugin, invoked exactly as skills/zen-mode/SKILL.md renders it) and confirm in one clause. Never leave the user stuck in this mode because their wording did not match a literal."
  }
}
JSON
exit 0
