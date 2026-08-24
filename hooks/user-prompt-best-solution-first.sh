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
# so that file is tamper-evident within a session THAT IS SERVED BY THE RUNTIME WHICH
# MINTED ITS RECORD — servesRecordedRuntime lets a compatible sibling install serve a
# record it did not mint, and this hook reads from the EXECUTING root, so a lineage-served
# upgrade injects bytes no in-session digest measured. The build-time digest pin in
# tests/structure/test-best-solution-first.sh (B2f1) is what actually binds the text.
# The load additionally refuses a symlink, as session-start-evidence-discipline.sh does
# for its own policy file.
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
# a config library that is absent, symlinked, or fails to load, or a rule file that is
# absent, symlinked, swapped between the pre-check and the open, oversized in FILE or in
# BLOCK, short-read, or malformed exits 0 with no output, so it can never block a prompt or
# a spawn. The injection is DROPPED, not truncated, and nothing reports it.
#
# What the build-time pins in tests/structure/test-best-solution-first.sh cover, stated
# precisely because an earlier wording of this paragraph overclaimed it: they make a
# malformed shape a hard failure IN THIS REPOSITORY'S TREE. No suite ever runs in an
# INSTALLED tree, so the failure modes have to be separated by whether they self-heal:
#
#   TRANSIENT and self-healing — a missing node, a rule file being written at the moment
#   it is read, a swap caught by the dev/ino re-check. The next prompt injects.
#
#   PERSISTENT, operator-caused and invisible forever — a hand-edited or re-wrapped block
#   in the installed docs/, a symlinked rule file or config library, a partial install
#   missing hooks/lib/rule-block-v1.js, a forgotten `bestSolutionFirst: false`. Nothing in
#   the plugin reports any of these, and no test in this repository can see them, because
#   they are states of somebody else's filesystem. That gap is real and is not closed here;
#   docs/architecture.md records the proposal for a read-only diagnostic surface, and B16a
#   in the suite was narrowed so this hook staying stateless does not foreclose it.
# The plugin-root guard is the one deliberate exception: it is the sibling hooks' guard
# plus CDPATH= and -- hardening, so a mismatched inherited CLAUDE_PLUGIN_ROOT refuses
# with exit 2.
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

# The library is EXECUTED, not read, so it earns at least the guard the data file gets.
ZENSU_BEST_SOLUTION_CONFIG_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
[ -f "$ZENSU_BEST_SOLUTION_CONFIG_LIB" ] && [ ! -L "$ZENSU_BEST_SOLUTION_CONFIG_LIB" ] || exit 0

# The payload is still unread on fd 0 here, so the config probe — which spawns its own
# node — takes stdin from /dev/null rather than risking the channel the emitter needs.
# shellcheck source=hooks/lib/zensu-config.sh
source "$ZENSU_BEST_SOLUTION_CONFIG_LIB" </dev/null 2>/dev/null || exit 0
# The verdict is CARRIED rather than acted on here, because the shell cannot see
# the event: the payload is still unread on fd 0 and buffering it through the
# shell would corrupt a multi-byte character straddling a chunk boundary. node
# reads the event and applies the verdict per leg.
if zensu_hook_enabled bestSolutionFirst </dev/null; then
  ZENSU_BEST_SOLUTION_ENABLED=1
else
  ZENSU_BEST_SOLUTION_ENABLED=0
fi

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
ZENSU_BEST_SOLUTION_RULE_FILE="$ZENSU_BEST_SOLUTION_RULE_FILE" \
ZENSU_BEST_SOLUTION_ENABLED="$ZENSU_BEST_SOLUTION_ENABLED" \
ZENSU_RULE_BLOCK_LIB="$ZENSU_RULE_BLOCK_LIB" node -e '
  const OPEN = "<!-- zensu:best-solution-first -->";
  const CLOSE = "<!-- /zensu:best-solution-first -->";
  try {
    const fs = require("fs");
    const payload = JSON.parse(fs.readFileSync(0, "utf8") || "{}");
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) process.exit(0);
    const event = payload.hook_event_name;
    if (event !== "UserPromptSubmit" && event !== "SubagentStart") process.exit(0);

    // The config opt-out is scoped to the MAIN-THREAD leg. `zensu_hook_enabled`
    // resolves the merged config and a project-local `.zensu/config.json` wins per
    // key, so a single `hooks.bestSolutionFirst: false` there silenced both legs.
    // For UserPromptSubmit that is the documented bargain — the user chose to open
    // the project. It does not transfer to SubagentStart: a confined reviewer
    // spawned to review a repository would have its directive set decided by a file
    // in the repository under review, and the reviewer is exactly the process whose
    // instructions must not be editable by its subject. The opt-out remains real
    // for the user; it just no longer reaches a spawn.
    if (process.env.ZENSU_BEST_SOLUTION_ENABLED !== "1" && event !== "SubagentStart") process.exit(0);

    // The hardened open, the size and short-read bounds, MAX_BLOCK and the marker
    // parse all live in hooks/lib/rule-block-v1.js. This carrier used to hold a
    // byte-identical copy of every one of them; the copy then had to be policed by
    // a cross-carrier equality check, which proves the copies agree rather than
    // that they are right and cannot be driven from a unit layer at all.
    const { readRuleBlock } = require(process.env.ZENSU_RULE_BLOCK_LIB);
    const { block } = readRuleBlock(process.env.ZENSU_BEST_SOLUTION_RULE_FILE, OPEN, CLOSE);
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
