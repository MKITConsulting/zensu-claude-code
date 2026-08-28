#!/bin/bash
# PreToolUse(Agent|Task) — grants Zensu's own capability-confined reviewer spawns so
# the host auto-mode classifier cannot wedge the review chain. The set, the measured
# provenance of the bypass and the three host limits that bound it live in
# hooks/lib/reviewer-spawn-allow-v1.js; this hook re-authors none of them.
#
# THIS HOOK CAN ONLY GRANT OR STAY SILENT. It never emits deny or ask, and every
# failure path is a silent `exit 0`. That is the opposite of the fail-closed
# direction the Bash and Edit gates take, and it is deliberate: a non-zero exit from
# a PreToolUse hook BLOCKS the tool call, so a fail-closed grant hook would break
# every Agent spawn in the session — including the reviewer it exists to admit. The
# inherited-plugin-root mismatch is therefore reported on stderr and then declines,
# where a gate would exit 2.
#
# Four conditions, all required. They are CONJUNCTIVE, so their order is free to choose,
# and the order below is a COST ordering rather than a semantic one: condition 4 is the
# cheapest and the one that rejects the overwhelming majority of spawns, so it runs first
# and the three that cost process launches run only for a name that could actually be
# granted. Nothing is weakened by that — the decision is emitted only after all four pass.
#   1. the main principal — a subagent never earns a grant for another subagent;
#   2. a bound Session Control record — an unbindable session gets nothing;
#   3. hooks.reviewerSpawnAutoAllow is not exactly false in ANY config source, read
#      FAIL-CLOSED: a missing node, a present-but-unreadable config, or a `false` in
#      either the global or the project file withdraws the grant;
#   4. the module's own verdict on tool_name and tool_input.subagent_type.
#
# Rank matters and is not ours to set: the host resolves deny > ask > allow across
# every hook on a matcher, so a sibling hook returning deny or ask still wins, and a
# permissions.deny or permissions.ask rule overrides this grant outright.

set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 0
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    cat >/dev/null 2>&1 || true
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 0
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    cat >/dev/null 2>&1 || true
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 0
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

# Capped and suppressed, like every sibling PreToolUse hook in this tree. The decision
# module's MAX_PAYLOAD_BYTES bounds the LAST of three full copies of this payload — the
# principal reader and the session binder each receive one before it — so a ceiling here
# is the only one that bounds the shell's own copy. One byte over the module's limit is
# enough for it to refuse, which keeps the limit itself spelled in exactly one place. The
# trailing sentinel survives command substitution stripping trailing newlines. The OUTER
# redirect is what keeps stderr clean, and it is the same technique, for the same reason,
# as zensu_tdd_mode_marker_state in hooks/lib/zensu-config.sh: bash 5 warns "ignored null
# byte in input" from the shell PERFORMING the substitution, which is outside the inner
# group, so that group's own 2>/dev/null cannot catch it. Apple bash 3.2 does not warn at
# all, which is why the divergence is invisible on macOS and fails A39 only on Linux. A
# `tr -d '\0'` suppresses it just as well and yields a byte-identical string — bash drops
# the NUL either way — but costs a process spawn on a path that runs on every tool call.
{ PAYLOAD="$( { head -c 4194305; printf 'X'; } 2>/dev/null )" || PAYLOAD="X"; } 2>/dev/null
PAYLOAD="${PAYLOAD%X}"

DECIDER="$CLAUDE_PLUGIN_ROOT/hooks/lib/reviewer-spawn-allow-v1.js"
[ -f "$DECIDER" ] && [ ! -L "$DECIDER" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# The decider is a pure function of stdin: it requires only its sibling modules through
# relative specifiers and reads no environment at all. Rendering plugin paths here and
# gating on them with `|| exit 0` added a FIFTH condition to the four this hook documents
# — an unset or unrenderable CLAUDE_PLUGIN_DATA silently withdrew the grant while the
# banner and the doctor row still asserted it. Do not reintroduce it.
#
# It runs FIRST because it is the cheapest of the four and the one that rejects the common
# case. Every ordinary Agent/Task spawn in a session reaches this hook, and almost none of
# them names a confined reviewer; deciding that from stdin alone costs one node start,
# where the three conditions below cost a principal read, a Session Control bind (itself
# two bash starts plus a node start) and a second node start for the config read. The
# order is a COST ordering, not a semantic one — all four remain required, and the grant
# is emitted only after every one of them has passed.
DECISION="$(printf '%s' "$PAYLOAD" | (
  cd -P -- "$CLAUDE_PLUGIN_ROOT/hooks/lib" && node ./reviewer-spawn-allow-v1.js
) 2>/dev/null)" || exit 0
[ -n "$DECISION" ] || exit 0

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-agent-context.sh" 2>/dev/null || exit 0
zensu_hook_is_main_principal "$PAYLOAD" PreToolUse || exit 0

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh" 2>/dev/null || exit 0
zensu_bind_hook_session "$PAYLOAD" >/dev/null 2>&1 || exit 0

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-config.sh" 2>/dev/null || exit 0
# The fail-CLOSED reader, deliberately not zensu_hook_enabled. That helper answers
# "enabled" when node is missing or the config read fails, which is right for a flag
# whose enabled state runs a protection and wrong for one whose enabled state hands out
# a capability: the same fallback would restore a grant the user withdrew.
zensu_hook_enabled_strict reviewerSpawnAutoAllow || exit 0

printf '%s\n' "$DECISION"
exit 0
