#!/bin/bash
# UserPromptSubmit + SubagentStart hook — injects the best-solution-first rule as
# hookSpecificOutput.additionalContext so every process carries it: the main thread
# on EVERY prompt, and every spawned subagent at spawn time.
#
# The `user-prompt-` prefix names the primary recurring channel; the SubagentStart
# leg is the reach extension, exactly as session-start-evidence-discipline.sh names
# only its first event while serving two.
#
# The directive text is READ AT RUN TIME from docs/best-solution-first.md (the single
# line between the zensu:best-solution-first markers) rather than duplicated here, so
# this carrier can never drift from the canonical block. docs/ is inside the Session
# Control runtime digest (manifestRuntimeEntries in hooks/lib/session-control-core-v1.js),
# so that file is tamper-evident within a session; the load additionally refuses a
# symlink, as session-start-evidence-discipline.sh does for its own policy file.
#
# Deliberately different from session-start-evidence-discipline.sh in two ways: it IS
# switchable (hooks.bestSolutionFirst, default on) because it directs how a decision is
# presented rather than asserting a correctness invariant, and it fires on the prompt
# channel rather than only at session start — a rule that fades over a long session
# fades exactly when an agent starts optimizing for the smallest disturbance.
#
# Deliberately different from user-prompt-context-nudge.sh in two ways: no de-bounce
# band (the moment an agent is about to frame a question is not observable in advance,
# so the reminder has to be resident, not periodic) and no main-principal gate — the
# rule applies to subagents too, which is the whole point of the second event.
#
# Fail-silent by construction: an unknown event, a malformed payload, a missing node,
# or an absent/symlinked/malformed block exits 0 with no output, so it can never block
# a prompt or a spawn. The plugin-root guard is the one deliberate exception: it is the
# sibling hooks' guard plus CDPATH= and -- hardening, so a mismatched inherited
# CLAUDE_PLUGIN_ROOT still refuses with exit 2.
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(CDPATH= cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
ZENSU_BEST_SOLUTION_RULE_FILE="$_ZENSU_EXECUTED_PLUGIN_ROOT/docs/best-solution-first.md"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0
[ -f "$ZENSU_BEST_SOLUTION_RULE_FILE" ] && [ ! -L "$ZENSU_BEST_SOLUTION_RULE_FILE" ] || exit 0

# The payload is still unread on fd 0 here, so the config probe — which spawns its own
# node — takes stdin from /dev/null rather than risking the channel the emitter needs.
# shellcheck source=hooks/lib/zensu-config.sh
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh" </dev/null 2>/dev/null || exit 0
zensu_hook_enabled bestSolutionFirst </dev/null || exit 0

# node reads the payload itself: buffering it through the shell and re-piping it
# would corrupt a multi-byte character that straddles a stdin chunk boundary.
ZENSU_BEST_SOLUTION_RULE_FILE="$ZENSU_BEST_SOLUTION_RULE_FILE" node -e '
  const OPEN = "<!-- zensu:best-solution-first -->";
  const CLOSE = "<!-- /zensu:best-solution-first -->";
  try {
    const fs = require("fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) process.exit(0);
    const event = payload.hook_event_name;
    if (event !== "UserPromptSubmit" && event !== "SubagentStart") process.exit(0);

    const lines = fs.readFileSync(process.env.ZENSU_BEST_SOLUTION_RULE_FILE, "utf8").split("\n");
    const open = lines.indexOf(OPEN);
    if (open < 0 || lines.indexOf(OPEN, open + 1) !== -1) process.exit(0);
    if (lines[open + 2] !== CLOSE) process.exit(0);
    const block = String(lines[open + 1] || "").replace(/^>\s*/, "").trim();
    if (!block) process.exit(0);

    const directive = "Zensu best-solution-first — binding for every process in this "
      + "session, main thread and subagents alike. " + block;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: event,
        additionalContext: directive
      }
    }));
  } catch (_) {}
' 2>/dev/null
exit 0
