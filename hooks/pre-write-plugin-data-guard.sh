#!/bin/bash
# pre-write-plugin-data-guard.sh — PreToolUse containment gate for the plugin's
# private data store, on Edit|Write|MultiEdit and NotebookEdit.
#
# It denies a file-mutating tool call whose resolved target lies inside
# CLAUDE_PLUGIN_DATA. That store holds the immutable Session Control records
# under <plugin data>/session-control/v1/ and the review-evidence leases. It does
# NOT cover <project>/.zensu/state/, so this is not "the anchors every gate binds
# to"; the residuals are enumerated in the module header. Measured 2026-08-28 and recorded in
# docs/multi-repo-chains-spec.md §6.1.2: all three PreToolUse hooks that match a
# `Write` answered `allow` for a target inside the store, in every chain state,
# because none of them performs a containment check. The NET DELTA of this hook is
# the MAIN THREAD ONLY — reviewer-capability-v1.js already denies every non-main
# principal a write into this store — so never justify it with "every principal",
# which is true of the behaviour below and false as a description of what it adds.
# Residual 2 is main-thread only for the same reason.
#
# WHY IT IS A HOOK OF ITS OWN. pre-edit-tdd-reminder.sh returns early while no
# chain is armed, and that is precisely the state in which the store is read.
# Extending it would leave the hole open exactly where it matters.
#
# SCOPE — narrow on purpose. Only the store. A write anywhere else outside the
# project root stays allowed here, so this gate is deliberately NARROWER than the
# Bash source-write gate's rule (B), which denies every redirect escaping the
# project root (temp roots excepted). The asymmetry between the Edit path and
# the Bash path therefore survives this change; closing it needs a temp carve-out
# and would refuse ordinary work on files outside the project.
#
# THE BASH CHANNEL IS NOT COVERED AT ALL, and that bounds what this gate can be
# claimed to do: bash-source-write-parse.js filters targets through SRC, which
# carries no `json`, and mv/cp are out of scope — so a redirect, copy, move or
# link into the store passes every Bash gate. Anything holding Bash still reaches
# the store. This header carries residuals 1 and 2. The module header is the
# authoritative carrier for the FULL LIST; the numeral is
# spelled in three further places — `docs/gates.md`, the `docs/configuration.md`
# row and `CLAUDE.md` — and they move together. None of them is maintained here,
# which is why this header carries no count.
#
# NO ESCAPE. No ZENSU_*=off variable disables this, and no config flag does
# either. session-start-evidence-discipline.sh is the precedent for a control
# with no switch. Consequently nothing here lands a bypass-ledger entry: there is
# no gate escape to record.
#
# EVERY PRINCIPAL. There is no main-principal check — a subagent must not be able
# to write the store either.
#
# FAULT DIRECTION: every fault ALLOWS, with TWO exceptions. The shared
# plugin-root identity guard below refuses with exit 2 exactly as every sibling
# gate does — on this matcher that refusal blocks the call. And the module denies
# with `target-resolution-truncated` when a resolution hits an internal bound,
# because "outside" is a claim a walk that did not finish has not earned; that
# deny travels back through this wrapper, so it is stated here rather than only
# in the module. A missing `node`, an unresolvable CLAUDE_PLUGIN_DATA, an
# unparseable payload, or a module that will not load must never deny, because a
# deny there would block ordinary in-project writes — strictly worse than the
# hole this closes. THREE early exits here are outside the reach of the module's
# own TYPED reason, because this script returns before `node` runs: no `node`, a
# `hooks/lib` the `cd -P` cannot enter, and an absent or symlinked module file.
# They are NOT SILENT — each writes its own stderr note below, and so do both
# exit-2 plugin-root branches. Never write "cannot carry a note": that names a
# structural limit where there is only a channel boundary, and `cannot` is the
# word that stops the next maintainer from fixing it.
# THE `cd -P` TRANSPORT BELOW MOVES THE CWD, so the caller's own directory is
# captured into ZENSU_GUARD_CALLER_CWD first and exported. Without it the
# module's relative-target fallback anchored at <plugin root>/hooks/lib rather
# than where the tool call was issued, so a payload carrying no `cwd` with a
# RELATIVE target could resolve outside the store here while the tool resolved
# it inside. The payload's own absolute `cwd` still outranks this value — it is
# the FALLBACK — and the variable is exported unconditionally, so an inherited
# one can never decide a verdict. The decision itself lives in
# hooks/lib/plugin-data-guard-v1.js, which reuses `within` and `msysToDrive`
# from hooks/lib/bash-source-write-parse.js rather than hand-copying the
# containment rule a fifth time.
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || {
  echo "zensu: plugin-data guard cannot resolve its own plugin root" >&2
  exit 2
}
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

# CLAUDE_PROJECT_DIR is consumed UNHARDENED, and it is the only one of the three
# anchors that is. CLAUDE_PLUGIN_ROOT is re-derived and refused on mismatch above,
# and ZENSU_GUARD_CALLER_CWD is exported unconditionally so an inherited value can
# never decide a verdict — but the project root travels straight from the
# inherited environment into the over-arm valve, the one input that can WIDEN the
# boundary. What bounds it: the valve only ever carves out, never extends the
# gate, and the carve-out announces itself on stderr with the store it resolved.
# Residual 11 carries the rest.
#
# The caller's directory, captured BEFORE the `cd -P` above moved it. Exported
# unconditionally so an inherited value can never decide a verdict; an
# unresolvable cwd exports the empty string and the module falls back to its own
# process cwd exactly as before.
ZENSU_GUARD_CALLER_CWD="$(pwd -P 2>/dev/null || true)"
export ZENSU_GUARD_CALLER_CWD

# Drain stdin BEFORE any early exit, mirroring pre-bash-source-write-gate.sh's
# ordering: a hook that exits without reading leaves the harness writing into a
# closed pipe. The payload is handed back to node on stdin below.
INPUT="$(cat 2>/dev/null || true)"

command -v node >/dev/null 2>&1 || {
  echo "zensu: plugin-data guard did not run (node unavailable) — writes into the plugin data store are unguarded" >&2
  exit 0
}

# The module is reached by cwd-relative require after a `cd -P`, never as an argv
# token. That is one of the two transports
# tests/structure/test-msys-special-plugin-module-boundaries.sh declares
# acceptable, and it is the one its `pre-write-secret-scan.sh` sibling uses on
# these same two matchers (the third hook on the Edit matcher,
# `pre-edit-tdd-reminder.sh`, runs inline `node -e` programs and transports no
# module at all): MSYS rewrites an
# argv token on Windows, so an absolute path there can fail to resolve and this
# gate would then silently not run — the one hook where "did not run" removes a
# DENY rather than an advisory.
cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || {
  echo "zensu: plugin-data guard did not run (hooks/lib unreachable) — writes into the plugin data store are unguarded" >&2
  exit 0
}
[ -f ./plugin-data-guard-v1.js ] && [ ! -L ./plugin-data-guard-v1.js ] || {
  echo "zensu: plugin-data guard did not run (decision module absent or symlinked) — writes into the plugin data store are unguarded" >&2
  exit 0
}

# The payload travels on stdin for the same namespace reason.
exec node ./plugin-data-guard-v1.js <<<"$INPUT"
