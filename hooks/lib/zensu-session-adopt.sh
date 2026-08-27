#!/bin/bash
# zensu-session-adopt.sh — report on, and optionally perform, the adoption of an
# intact Session Control record by a declared-incompatible executing runtime.
#
# This is the SECOND script the PreToolUse Bash gates recognize in a bind
# failure, and it differs from the first in the one way that matters: the
# diagnostic writes nothing, and this WRITES. The widening therefore does not
# inherit /zensu:doctor's justification and needs its own, stated here because
# hooks/lib/zensu-doctor-invocation.js points at this header:
#
#   - THREE write classes, all confined: one record for THIS session in the
#     private plugin-data store; one workflow history entry in the recorded
#     project; and any review-evidence lease naming the previous installation,
#     MOVED (never deleted) out of that session's own lease records directory
#     into a sibling `superseded/` one. The selector is broader than "names the
#     previous installation" and narrower than "everything listRecords rejects":
#     the keep-predicate is a SUPERSET of that reader's accept set, mirroring three
#     of its conjuncts, so a stale lease, one whose id disagrees with its filename,
#     a malformed record, a symlinked or oversized one and a non-.json leftover are
#     all moved — while an entry that fails only the checks NOT mirrored
#     (multiply-linked, non-canonical, otherwise validateRecord-invalid) and still
#     names the executing root is KEPT, and keeps wedging later lease operations. That
#     residual is documented in review-evidence-sweep-v1.js beside the predicate —
#     the sweep is no longer part of adoptContext, and THIS script is what invokes
#     it. Nothing else, and nothing outside
#     <plugin_data>/{session-control,review-evidence} and the recorded project.
#   - What BOUNDS that write is not derivation — CLAUDE_PLUGIN_DATA is a
#     caller-supplied literal, exactly as it is for the diagnostic — it is
#     readContext: the session-hash must match, the
#     runtime digest is recomputed against the RECORDED root, and that root's
#     manifest must still declare the recorded version. Add the sibling-root
#     bound and the plugin_data equality check, and a record the caller authored
#     under a directory it controls cannot reach the write for a session it does
#     not already own. State it this way and not as "every location is derived
#     from the record": that is the stronger claim, and it is not what the code
#     enforces.
#   - The record and history writes require every adoptableRecord condition to
#     hold. There is exactly ONE bounded exception, and it is stated here because
#     this header is what the recognizer's admission rests on: with `--confirm`, an
#     `already-served` refusal re-runs write class 3 — the lease sweep — as an
#     idempotent repair. It re-mints nothing and touches nothing outside
#     <plugin_data>/review-evidence/v1/{records,superseded}/<session key>. Without
#     `--confirm` that refusal is read-only like every other.
#   - It cannot reach project source files, cannot run a build or a test, and
#     takes no argument other than the single literal `--confirm`.
#   - Without `--confirm` it is strictly read-only and answers the same question
#     the doctor row asks.
#
# What it does NOT do: relax runtimeLineageCompatible, rewrite any record (the
# superseded one is set aside under a new name and stays readable), touch the
# workflow document's decision fields, or relax plugin_data. A session whose
# persisted shapes really did change is refused, by construction — validateContext
# and validateWorkflowState enforce the two schema constants, so a real break
# makes the record or the document unreadable and adoption declines.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session: cannot resolve the plugin library directory' >&2
  exit 1
}
PLUGIN_ROOT="$(cd "$DIR/../.." && pwd -P)" || {
  printf '%s\n' 'zensu:adopt-session: cannot resolve the executing plugin root' >&2
  exit 1
}
CORE="$DIR/session-control-core-v1.js"
[ -f "$CORE" ] && [ ! -L "$CORE" ] || {
  printf '%s\n' 'zensu:adopt-session: the Session Control runtime is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}
# The binder is loaded by the report module for its private-store constructor, so it
# gets the same guard the core does — zensu-session.sh applies it to this exact file
# at three sites, and a symlinked binder must not be the one library this
# write-capable script loads unchecked.
BINDER="$DIR/claude-hook-session-v1.js"
[ -f "$BINDER" ] && [ ! -L "$BINDER" ] || {
  printf '%s\n' 'zensu:adopt-session: the Session Control binder is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}
# The report itself. It used to be a `node -e` payload carried inside this script as a
# single-quoted string, which is why safe() had no test in either direction; it is a
# real module now and gets the same missing-or-symlinked guard as the two libraries
# above, because this is the file the write-capable command actually executes.
REPORT="$DIR/session-adopt-report-v1.js"
[ -f "$REPORT" ] && [ ! -L "$REPORT" ] || {
  printf '%s\n' 'zensu:adopt-session: the adoption report module is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}
# The sweep the report invokes after adoptContext, guarded for the same reason: a
# missing or symlinked sweep must stop this command BEFORE any record is mutated,
# not after.
SWEEP="$DIR/review-evidence-sweep-v1.js"
[ -f "$SWEEP" ] && [ ! -L "$SWEEP" ] || {
  printf '%s\n' 'zensu:adopt-session: the review-evidence sweep module is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}
# The lease-store OWNER, which the sweep requires. It is new to this command's load
# graph — before the seam the core hand-copied its constants precisely to avoid the
# require cycle — and it is the module that decides WHICH leases move
# (leaseRecordIsOwned) and that creates and chmods the store (ensurePrivateDirectory,
# storage). Leaving it unguarded while its four siblings are guarded would mean the
# one command still reachable in a tamper-suspicious state loads its move selector
# from a file nothing checked.
LEASE="$DIR/review-evidence-lease-v1.js"
[ -f "$LEASE" ] && [ ! -L "$LEASE" ] || {
  printf '%s\n' 'zensu:adopt-session: the review-evidence lease module is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}

# The display-safety rules. Newest member of this command's load graph — the report
# requires it at TOP LEVEL, and node's require FOLLOWS symlinks — and it is the one
# module that decides what every value in the report is allowed to look like before
# it reaches a terminal and the model's context. Unguarded, a link planted at this
# name substitutes the fold for the whole report: the project line the user reads to
# decide whether to take the record over is exactly what it renders. Same reasoning
# as the lease guard above, one module further along.
SAFE_DISPLAY_LIB="$DIR/zensu-safe-display-v1.js"
[ -f "$SAFE_DISPLAY_LIB" ] && [ ! -L "$SAFE_DISPLAY_LIB" ] || {
  printf '%s\n' 'zensu:adopt-session: the display-safety module is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}

# The host-path normalizer, reached TRANSITIVELY rather than by a require in the
# report module — the binder requires it, and so does the lease owner. It is not
# inert on that path: `canonicalDirectory` runs every trust-boundary path through
# `normalizeHostPathInput`, including the CLAUDE_PLUGIN_DATA value that locates the
# private record store, and nothing else re-verifies the EXECUTING tree here (the
# digest is recomputed against the RECORDED root only). It was left out when the
# list last grew, with the omission written into a comment as a known gap; a guard
# list whose completeness lives in prose is the shape this file already rejects for
# its six siblings.
PATH_LIB="$DIR/claude-path-v1.js"
[ -f "$PATH_LIB" ] && [ ! -L "$PATH_LIB" ] || {
  printf '%s\n' 'zensu:adopt-session: the host-path module is missing or symlinked; repair the Zensu plugin installation' >&2
  exit 1
}

CONFIRM=0
case "${1:-}" in
  '') ;;
  --confirm) CONFIRM=1 ;;
  *)
    printf '%s\n' 'zensu:adopt-session: the only supported argument is --confirm' >&2
    exit 2
    ;;
esac
[ "$#" -le 1 ] || {
  printf '%s\n' 'zensu:adopt-session: the only supported argument is --confirm' >&2
  exit 2
}

command -v node >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session: node is not available, so Session Control cannot be read' >&2
  exit 1
}
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || {
  printf '%s\n' 'zensu:adopt-session: CLAUDE_CODE_SESSION_ID is unset, so this session cannot be identified' >&2
  exit 1
}
[ -n "${CLAUDE_PLUGIN_DATA:-}" ] || {
  printf '%s\n' 'zensu:adopt-session: CLAUDE_PLUGIN_DATA is unset, so the record store cannot be located' >&2
  exit 1
}
# CLAUDE_PROJECT_DIR is deliberately NOT required, and is not read at all. It was
# required once, and rendered through the host-path script, which rejects a path
# that is not a directory — so a session whose harness project dir had been
# deleted exited here, before any report, in exactly the state this command
# exists to diagnose. adoptableRecord no longer judges the caller's project root:
# the anchor is carried from the record, and every write below is bounded by
# readContext, the sibling-root check and plugin_data. The recognizer still
# ACCEPTS the assignment, because the diagnostic reads it and the two share one
# set — this script simply ignores it.

# Both crossings into native Node go through the host-path renderer, as every
# other stateful helper does, and are excluded from Git Bash's heuristic
# environment conversion so a drive spelling is not reinterpreted twice.
# shellcheck disable=SC1090
# The two SHELL siblings. Every JS module in this command's require graph is guarded
# above; these two were not, and `source` executes arbitrary shell IN THIS PROCESS,
# which is strictly more powerful than a `require`. The read-only /zensu:doctor already
# refuses a symlinked `zensu-session.sh` and renders a dedicated row for it, so the
# write-capable command was the weaker of the two on the same file. Same bound as the
# others, stated rather than implied: `[ ! -L ]` catches a link, not a replaced regular
# file, so this is consistency in a defense-in-depth convention, not an independent
# control.
for _zsa_lib in "$DIR/zensu-session.sh" "$DIR/zensu-host-path.sh"; do
  [ -f "$_zsa_lib" ] && [ ! -L "$_zsa_lib" ] || {
    printf '%s\n' "zensu:adopt-session: ${_zsa_lib##*/} is missing or symlinked; repair the Zensu plugin installation" >&2
    exit 1
  }
done

source "$DIR/zensu-session.sh" >/dev/null 2>&1 || {
  printf '%s\n' 'zensu:adopt-session: the Session Control shell library is unavailable' >&2
  exit 1
}
# Both renders name their cause. zensu-host-path.sh exits SILENTLY for anything that
# is not an existing, non-symlink directory, and a bare `|| exit 1` here made this
# command — the last reachable diagnosis in a wedged session — produce no output at
# all for a plugin-data store that had been pruned, replaced by a file, or symlinked.
# The `private-record-store-unsafe` branch below already carries the right wording
# for exactly those shapes and never got the chance to run.
NATIVE_PLUGIN_ROOT="$(bash "$DIR/zensu-host-path.sh" "$PLUGIN_ROOT")" || {
  printf '%s\n' 'zensu:adopt-session: the executing plugin root is not a readable directory; repair the Zensu plugin installation' >&2
  exit 1
}
NATIVE_PLUGIN_DATA="$(bash "$DIR/zensu-host-path.sh" "$CLAUDE_PLUGIN_DATA")" || {
  printf '%s\n' 'zensu:adopt-session: CLAUDE_PLUGIN_DATA does not name a readable directory, so the record store cannot be located. It is missing, a file, or a symlink.' >&2
  exit 1
}
MSYS_EXCL="$(zensu_msys_env_exclusions ZADOPT_PLUGIN_ROOT ZADOPT_PLUGIN_DATA)" || {
  printf '%s\n' 'zensu:adopt-session: the host-path environment library is unavailable; repair the Zensu plugin installation' >&2
  exit 1
}

cd -P -- "$DIR" || exit 1
MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" \
ZADOPT_PLUGIN_ROOT="$NATIVE_PLUGIN_ROOT" \
ZADOPT_PLUGIN_DATA="$NATIVE_PLUGIN_DATA" \
ZADOPT_SESSION_ID="$CLAUDE_CODE_SESSION_ID" \
ZADOPT_CONFIRM="$CONFIRM" \
node "$DIR/session-adopt-report-v1.js"
