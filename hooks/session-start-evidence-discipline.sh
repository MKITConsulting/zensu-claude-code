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
# is tamper-evident within a session THAT IS SERVED BY THE RUNTIME WHICH MINTED
# ITS RECORD — readContextInternal measures the RECORDED plugin root while this
# hook reads from the EXECUTING one, and servesRecordedRuntime deliberately lets a
# compatible sibling install serve a record it did not mint, so a lineage-served
# upgrade injects bytes no in-session digest measured. What binds this text across
# that case is the build-time pinning in tests/structure/test-evidence-discipline.sh:
# the block's own phrases plus the requirement that every agent and every skill
# carries it verbatim. The load additionally refuses a symlink, as
# review-evidence-subagent-start.sh and -stop.sh do for their policy file, and the
# reader below re-checks the inode it actually opened.
#
# Deliberately different from session-start-primer.sh in three ways: it reads no
# config (no opt-out flag, in particular NOT hooks.sessionBanner), it has no
# fresh-start filter (it also fires on resume/compact, where the rule would
# otherwise be lost with the compacted context), and it applies to every
# principal rather than only main-v1.
#
# Fail-silent by construction: an unknown event, a malformed payload, a missing
# node, or a rule file that is absent, symlinked, swapped between the pre-check and
# the open, oversized in FILE or in BLOCK, short-read or malformed exits 0 with no
# output, so it can never block a prompt or a spawn. Note what that means for an
# unswitchable rule: the injection is DROPPED, not truncated, and nothing reports it —
# the build-time pins in tests/structure/test-evidence-discipline.sh are what make that
# a hard failure. The plugin-root guard is the one deliberate
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

# The hardened read and the marker parse live in ONE module now, not in a
# hand-copy per carrier. zensu-host-path.sh renders a DIRECTORY in the native
# spelling; the file name is appended after conversion, and the spelling that is
# actually loaded is what gets guarded — including readability, because a module
# that is present but unreadable would otherwise throw inside node and be
# indistinguishable from a malformed rule file.
ZENSU_RULE_BLOCK_DIR="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" \
  "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null)"
# The renderer only MATTERS on win32, where the two namespaces differ. When it
# cannot run at all — a stripped PATH, a partial install — falling back to the
# plain spelling keeps the POSIX carrier working instead of turning a rendering
# failure into a silent no-injection. The guards below still judge the spelling
# that is actually loaded, so the fallback widens nothing.
[ -n "$ZENSU_RULE_BLOCK_DIR" ] || ZENSU_RULE_BLOCK_DIR="${CLAUDE_PLUGIN_ROOT}/hooks/lib"
ZENSU_RULE_BLOCK_LIB="${ZENSU_RULE_BLOCK_DIR:+${ZENSU_RULE_BLOCK_DIR}/rule-block-v1.js}"
[ -n "$ZENSU_RULE_BLOCK_LIB" ] && [ -f "$ZENSU_RULE_BLOCK_LIB" ] \
  && [ ! -L "$ZENSU_RULE_BLOCK_LIB" ] && [ -r "$ZENSU_RULE_BLOCK_LIB" ] || exit 0

# node reads the payload itself: buffering it through the shell and re-piping it
# would corrupt a multi-byte character that straddles a stdin chunk boundary.
ZENSU_EVIDENCE_RULE_FILE="$ZENSU_EVIDENCE_RULE_FILE" \
ZENSU_RULE_BLOCK_LIB="$ZENSU_RULE_BLOCK_LIB" node -e '
  const OPEN = "<!-- zensu:evidence-discipline -->";
  const CLOSE = "<!-- /zensu:evidence-discipline -->";
  try {
    const fs = require("fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) process.exit(0);
    const event = payload.hook_event_name;
    if (event !== "SessionStart" && event !== "SubagentStart") process.exit(0);

    // The hardened open, the size and short-read bounds, MAX_BLOCK and the marker
    // parse all live in hooks/lib/rule-block-v1.js. This carrier used to hold a
    // byte-identical copy of every one of them, and it is the carrier where the
    // duplicate-OPEN rule mattered most: this directive is documented as not
    // switchable off, and appending one duplicated marker line to the rule file
    // silently disabled it. The module takes the FIRST marker pair instead.
    const { readRuleBlock } = require(process.env.ZENSU_RULE_BLOCK_LIB);
    const { block } = readRuleBlock(process.env.ZENSU_EVIDENCE_RULE_FILE, OPEN, CLOSE);
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
