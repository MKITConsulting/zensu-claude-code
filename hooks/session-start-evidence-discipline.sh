#!/bin/bash
# SessionStart + SubagentStart hook — injects the plugin-wide evidence-discipline
# rule as hookSpecificOutput.additionalContext so every process carries it: the
# main thread and every spawned subagent alike.
#
# The directive text is READ AT RUN TIME from docs/evidence-discipline.md (the
# single line between the zensu:evidence-discipline markers) rather than
# duplicated here, so this carrier can never drift from the canonical block the
# agents and skills quote. docs/ is inside the Session Control runtime digest
# (manifestRuntimeEntries in hooks/lib/session-control-core-v1.js), so that file
# is tamper-evident within a session; the load additionally refuses a symlink,
# as review-evidence-subagent-start.sh and -stop.sh do for their policy file.
#
# Deliberately different from session-start-primer.sh in three ways: it reads no
# config (no opt-out flag, in particular NOT hooks.sessionBanner), it has no
# fresh-start filter (it also fires on resume/compact, where the rule would
# otherwise be lost with the compacted context), and it applies to every
# principal rather than only main-v1.
#
# Fail-silent by construction: an unknown event, a malformed payload, a missing
# node, or an absent/symlinked/malformed block exits 0 with no output, so it can
# never block a prompt or a spawn. The plugin-root guard is the one deliberate
# exception: it is the sibling hooks' guard plus CDPATH= and -- hardening, so a
# mismatched inherited CLAUDE_PLUGIN_ROOT still refuses with exit 2.
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
ZENSU_EVIDENCE_RULE_FILE="$_ZENSU_EXECUTED_PLUGIN_ROOT/docs/evidence-discipline.md"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0
[ -f "$ZENSU_EVIDENCE_RULE_FILE" ] && [ ! -L "$ZENSU_EVIDENCE_RULE_FILE" ] || exit 0

# node reads the payload itself: buffering it through the shell and re-piping it
# would corrupt a multi-byte character that straddles a stdin chunk boundary.
ZENSU_EVIDENCE_RULE_FILE="$ZENSU_EVIDENCE_RULE_FILE" node -e '
  const OPEN = "<!-- zensu:evidence-discipline -->";
  const CLOSE = "<!-- /zensu:evidence-discipline -->";
  try {
    const fs = require("fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) process.exit(0);
    const event = payload.hook_event_name;
    if (event !== "SessionStart" && event !== "SubagentStart") process.exit(0);

    const lines = fs.readFileSync(process.env.ZENSU_EVIDENCE_RULE_FILE, "utf8").split("\n");
    const open = lines.indexOf(OPEN);
    if (open < 0 || lines.indexOf(OPEN, open + 1) !== -1) process.exit(0);
    if (lines[open + 2] !== CLOSE) process.exit(0);
    const block = String(lines[open + 1] || "").replace(/^>\s*/, "").trim();
    if (!block) process.exit(0);

    const directive = "Zensu evidence discipline — binding for every process in this "
      + "session, main thread and subagents alike, and not switchable off. " + block;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: event,
        additionalContext: directive
      }
    }));
  } catch (_) {}
' 2>/dev/null
exit 0
