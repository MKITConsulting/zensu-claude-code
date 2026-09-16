#!/bin/bash
# PostToolUse hook fired when the Agent (code-reviewer) tool completes.
# What binds a completion to a chain is the chain's own OUTSTANDING one-shot
# review ticket, carried in the prompt on a line of its own spelled
# `REVIEW-TICKET: <ticket>`; the line may sit anywhere and further such lines are
# ignored. `PRE-MERGED FINDINGS (fan-out)` is instructed by every producer and is
# NOT what this hook decides on — an earlier criterion routed on the consume-mode
# HEADER POSITION and refused a correct consume for every model-authored
# deviation. Only a `zensu:code-reviewer` completion whose prompt carries the
# ticket of a live, implementation-complete TDD review chain is routed. Every
# other Agent completion is a total no-op: it cannot read or mutate the auto-fix
# counter or chain state.
#
# Behavior is configurable via ~/.zensu/config.json (resolution order: env,
# project-local, global):
#   hooks.autoFixIncludeSuggestions=true  -> route ALL severities
#   hooks.autoFixIncludeSuggestions=false -> route Critical+Important only (default, backward-compat)
#   hooks.autoFixMaxRounds=<int 1..99>    -> loop guard (default 5)
#
# Review-round state is a validated field in the same per-session CAS workflow
# document as the TDD FSM; there is no independently writable counter file.

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
zensu_hook_is_main_principal "$INPUT" PostToolUse || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
zensu_bind_hook_session "$INPUT" || exit 0
PROJECT_ROOT="$(zensu_resolve_project_dir)" || exit 0
export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
AUTO_FIX_ON=1
zensu_hook_enabled autoFix || AUTO_FIX_ON=0

SUBAGENT_TYPE="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      console.log((j.tool_input && j.tool_input.subagent_type) || "");
    } catch (_) { console.log(""); }
  });
' <<<"$INPUT" 2>/dev/null)"

if [ "$SUBAGENT_TYPE" != "zensu:code-reviewer" ]; then
  exit 0
fi

# The model-facing emitter and the runnable helper spelling. Both are defined up
# here rather than beside their other call sites further down, because `decline`
# below runs long before them: a bash function must be defined before the CALL,
# and a flag with no program is not a command the reader can run.
LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
PLUGIN_DATA_Q="$(printf '%q' "${CLAUDE_PLUGIN_DATA:-}")"
LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"
emit_post_context() {
  node -e '
    const msg = require("node:fs").readFileSync(0, "utf8");
    process.stdout.write(JSON.stringify({hookSpecificOutput:{
      hookEventName:"PostToolUse", additionalContext:msg
    }}));
  '
  echo
}

SESSION_ID="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const id = j.session_id;
      console.log((typeof id === "string" && id) ? id : "");
    } catch (_) { console.log(""); }
  });
' <<<"$INPUT" 2>/dev/null)"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")" || exit 0

# Mode-aware fix discipline: the per-session `vanilla` flag was frozen into the
# state file by `--tdd-begin`. Read the STATE flag (never live config) so the
# fix-round directive matches the discipline the session actually runs under.
# The phase library ABORTS ITS OWN LOAD with `return 2` when the host-path render
# fails or its core module is absent or symlinked, and every helper it defines —
# `_tdd_state_storage_safe` and `tdd_state_file` included — is declared BELOW that
# guard. An unchecked source therefore left those names undefined, and the very
# next `|| exit 0` swallowed the completion silently for the exact fault the
# core-module disclosure further down is written to report, thirty-odd lines
# before that disclosure can be reached. It is reported HERE, where the fault is
# actually reachable, and this sits below the subagent-type filter above, so it
# can only fire for a real `zensu:code-reviewer` completion. It names no ticket
# value and no path, for the same reason that disclosure does not.
if ! source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"; then
  printf 'zensu: reviewer completion not judged (delegate-phase-library-unavailable) — this hook could not load its workflow-phase library from the plugin tree, so it cannot tell whether this chain holds an unclaimed review ticket and stays silent on the model channel\n' >&2
  exit 0
fi
TDD_STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Preflight the prompt envelope against both durable planes before consuming
# the one-shot ticket. A fully well-shaped but stale/conflicting envelope must
# be as byte-stable as a malformed one, so validation cannot happen after the
# claim transaction.
#
# THIS GUARD IS THE ONE THAT CATCHES TAMPER, and the disclosure belongs here
# rather than at the ticket probe below. `_tdd_paths_safe`'s JS walk tests
# `st.nlink !== 1` for the `regular-or-absent` mode this call passes, so a
# multi-linked workflow document is refused HERE — before any read — and a bare
# `exit 0` would strand the chain on both channels for exactly the tamper class
# the probe's own disclosure was written to report. Every trigger of this arm is
# a fault or a tamper: a symlink, a non-regular file, a second hard link, or a
# state directory that is not a directory. None of them is an ordinary state, so
# the line is not noise on a healthy session.
if ! _tdd_state_storage_safe "$TDD_STATE_FILE"; then
  printf 'zensu: reviewer completion not judged (delegate-workflow-storage-unsafe) — the workflow document for this session, its lock, or the directory holding them is a symlink, a non-regular file, or carries more than one hard link, so this hook refuses to read it and cannot tell whether this chain holds an unclaimed review ticket\n' >&2
  exit 0
fi
# The guard above already accepted every shape this one would refuse EXCEPT
# absence: it passes `regular-or-absent` while this passes `regular`, and the
# JS walk exits 3 for a missing leaf only in the strict mode. So the sole
# remaining trigger here is a workflow document that does not exist, which is
# the ordinary state of every reviewer completion in a project with no chain
# armed. Silence is the honest answer; do not add a disclosure to this line.
_tdd_path_safe "$TDD_STATE_FILE" regular "$(dirname "$TDD_STATE_FILE")" || exit 0
NATIVE_TDD_STATE_FILE="$(_tdd_native_project_path "$TDD_STATE_FILE")" || exit 0

# THIS FILE's own two workflow-document reads go through the core's HARDENED
# reader rather than a bare `readFileSync`. Scope the claim to those two reads and
# never to the PostToolUse path as a whole: the claim-and-mark verbs this path
# calls further down live in `hooks/lib/zensu-tdd-phase.sh`, which still opens the
# state file bare at its own read sites, so the hazard below is narrowed here and
# not closed for the path. S37's scan is bound to `$HOOK` and measures exactly
# that narrower claim. Naming those verbs here is deliberately avoided: two suite
# extractors anchor their regions on those literals, and a comment carrying one
# silently moves the region a behavioural check is measured over.
# The path lives under `<project>/.zensu/state/`,
# which is writable from inside any session in the project and covered by no gate
# while a chain is inactive, so a planted FIFO there blocks `open(2)` forever and
# the descriptor checks cannot help — they run only once the open has returned.
# `zensu-tdd-phase.sh` already resolved the native module path, so this reuses it
# rather than re-spelling the layout.
#
# It is read through the PUBLIC `zensu_tdd_control_core`, never through that
# library's `_ZENSU_TDD_CONTROL_CORE` directly. The underscore prefix is this
# repository's mark for an intra-file channel, so reading it across the boundary
# would make a rename over there a SILENT loss here: the variable resolves
# empty, `require("")` throws into the catch below, the probe answers `no`, and
# `decline()`'s own outstanding-ticket guard exits 0 — every reviewer completion
# becomes an unrouted no-op, which is the exact strand this hook exists to end.
# The `[ -f ]` / `[ ! -L ]` re-check stays: the accessor reports what the library
# derived, and this hook still owes its own look before handing a path to node.
#
# An UNUSABLE core is therefore disclosed on the operator channel rather than
# left to that strand. When the variable is empty every `require` below throws
# into its own catch, the ticket probe answers `no`, and both the operator gate
# and the model gate read that as "this chain holds no unclaimed ticket" — so the
# completion is silent on BOTH channels for a reason that is a fault in the
# plugin tree rather than a property of the chain. One stderr line, below the
# subagent-type filter so it can only fire for a real `zensu:code-reviewer`
# completion, and naming no ticket value.
#
# STATE THE REACHABLE CAUSES, because an earlier wording named the one cause this
# check can NEVER see: a module that is already absent or symlinked when the
# phase library loads aborts that load, which the guarded `source` above now
# reports under its own class and exits on. What is left for this check is
# everything that survives a successful load — the accessor renamed or dropped
# from the library, so the `declare -F` probe leaves the variable empty, and the
# module unlinked or replaced by a symlink AFTER that load, which only this
# hook's own `[ -f ]` / `[ ! -L ]` look can catch. Both are real and neither is
# covered by the guard above; do not restore the absent-at-load reading.
ZENSU_DELEGATE_CORE=""
if declare -F zensu_tdd_control_core >/dev/null 2>&1; then
  ZENSU_DELEGATE_CORE="$(zensu_tdd_control_core)"
fi
if [ ! -f "${ZENSU_DELEGATE_CORE:-}" ] || [ -L "${ZENSU_DELEGATE_CORE:-}" ]; then
  ZENSU_DELEGATE_CORE=""
  printf 'zensu: reviewer completion not judged (delegate-core-module-unavailable) — this hook could not load its workflow-document reader from the plugin tree, so it cannot tell whether this chain holds an unclaimed review ticket and stays silent on the model channel\n' >&2
fi
# The claim PREDICATE is resolved the same way and for the same reason. It is the
# ONE implementation of the conjunct set `_tdd_consume_review_ticket_critical`
# applies under lock, so this hook no longer spells that set at all: a copy here
# that grew one conjunct MORE than the claim answers `no` for a chain the claim
# would accept, `decline()` returns at its first guard, and every disclosure in
# this file goes silent with the whole test surface green. That is the direction
# a one-sided source comparison could not see, which is why the copy is gone
# rather than pinned.
ZENSU_DELEGATE_CLAIM=""
if declare -F zensu_tdd_review_ticket_claim_module >/dev/null 2>&1; then
  ZENSU_DELEGATE_CLAIM="$(zensu_tdd_review_ticket_claim_module)"
fi
if [ ! -f "${ZENSU_DELEGATE_CLAIM:-}" ] || [ -L "${ZENSU_DELEGATE_CLAIM:-}" ]; then
  ZENSU_DELEGATE_CLAIM=""
  printf 'zensu: reviewer completion not judged (delegate-claim-module-unavailable) — this hook could not load its review-ticket claim predicate from the plugin tree, so it cannot tell whether this chain holds an unclaimed review ticket and stays silent on the model channel\n' >&2
fi
# HAND-COPY, recorded rather than hoisted. The four disclosures in this file share
# a lead-in and a tail verbatim and NOTHING holds them in step — no shell constant,
# no needle in any suite. A reworded tail on one of them leaves an operator with two
# sentences for one class that no single grep finds together. The durable fix is one
# constant beside `emit_post_context` plus a check deriving the class tokens from the
# emission sites, which is the shape `Z42b`/`Z46` already ship for the zen-mode hook;
# it is a pin design rather than a reword and is deliberately not taken mid-round.
# Every class token here carries the `delegate-` prefix on purpose: the core composes
# its own `workflow-document-<state>` refusal reasons for the baseline repair, and an
# unprefixed token here would answer a grep for that unrelated vocabulary.
# ONE of the fourteen carriers that source the phase library checks the status, and it
# is the guarded `source` above. The other thirteen inherit the undefined-helper class
# this file's own guard exists to remove; that is knowingly left as is rather than
# fixed here, because it changes thirteen hooks' behaviour. Before relying on the
# guard as a tree-wide property, run
# `grep -rn 'hooks/lib/zensu-tdd-phase.sh"' hooks/` and judge every unchecked site.

# The one-shot ticket is what BINDS a reviewer completion to this chain, and the
# claim transaction below re-checks it under lock. Reading it here as well is
# what lets the prompt be matched AGAINST the chain instead of against a fixed
# LINE POSITION. `PRE-MERGED FINDINGS (fan-out)` on line 1 and the ticket on
# line 2 were both model-authored; every deviation was a silent `exit 0`, and
# because issuing a ticket does not require the previous one to be consumed the
# chain then re-issued into the same mismatch and burned Stop blocks until the
# cap released it. The marker is still instructed by the producers and is no
# longer load-bearing here. The session hash is checked exactly as the claim
# checks it, so a document owned by another canonical session is not "this
# chain's outstanding ticket" and cannot even reach the disclosure below.
CHAIN_TICKET_STATE="$(STATE_FILE="$NATIVE_TDD_STATE_FILE" SID="$SESSION_ID" \
  CORE_MODULE="$ZENSU_DELEGATE_CORE" CLAIM_MODULE="$ZENSU_DELEGATE_CLAIM" node -e '
  try {
    // Hardened read, never a bare readFileSync: the core opens with O_NOFOLLOW
    // plus O_NONBLOCK and re-judges the descriptor, which is what keeps a FIFO
    // planted in the session-writable state directory from blocking this hook
    // forever. A missing or unloadable module throws here and lands in the
    // catch below, which is the same no-op every other fault on this path takes.
    const core = require(process.env.CORE_MODULE);
    // The shared claim predicate, required rather than re-spelled. It owns the
    // session-hash comparison, the chain-state conjuncts and the ticket shape,
    // and `_tdd_consume_review_ticket_critical` calls the same module under
    // lock, so the two carriers cannot disagree about which chain holds an
    // unclaimed ticket. A module that will not load throws into the catch below,
    // which is the same no-op every other fault on this path takes.
    const claim = require(process.env.CLAIM_MODULE);
    const s = JSON.parse(core.readRegularFileSnapshot(process.env.STATE_FILE).data.toString("utf8"));
    // The OUTSTANDING value rather than a match: this hook holds no ticket to
    // compare against, which is the one conjunct the claim keeps on its own side.
    const ticket = claim.outstandingTicket(s, process.env.SID);
    const outstanding = ticket !== "";
    process.stdout.write((outstanding ? "yes" : "no") + "\t" + (outstanding ? ticket : ""));
    // A THIRD status, because collapsing a FAULT into the no-ticket answer made
    // every later disclosure unreachable for the one cause they exist to report.
    // STATE THE REACHABLE CAUSES. A multi-linked or non-regular state file is NOT
    // among them: `_tdd_state_storage_safe` above passes mode `regular-or-absent`
    // into the JS walk of `_tdd_paths_safe`, which tests `st.nlink !== 1` and exits
    // 3, so that tamper is refused before this program runs and carries its own
    // disclosure at that guard. What reaches this catch is what the shape guards
    // cannot see: a document past MAX_JSON_BYTES, unparseable JSON, a non-object
    // root, a reader module that will not load, and a link planted inside the window
    // between that guard and this read. With the answer spelled `no`,
    // the split below cleared the ticket and `decline()`s own outstanding-ticket
    // guard then exited 0 for EVERY later decline in the session — the strand this
    // hook exists to end, silent on both channels. The caller re-normalizes this to
    // `no` immediately after disclosing, so no downstream conjunct sees a new value.
  } catch (_) { process.stdout.write("unreadable\t"); }
' 2>/dev/null)"
# The name carries the tense on purpose. This is a SNAPSHOT taken before the
# claim and never refreshed, so below the claim it no longer means "the ticket
# is unconsumed" — it means "this hook judged this session's chain, and that
# chain held an unclaimed ticket when this completion arrived". Every post-claim
# decline passes mode `spent`, where the ticket IS consumed and the disclosure
# still has to fire; a present-tense name there invites a later conjunct to
# reason from the opposite of what the value records.
CHAIN_TICKET_WAS_OUTSTANDING="${CHAIN_TICKET_STATE%%$'\t'*}"
OUTSTANDING_TICKET="${CHAIN_TICKET_STATE#*$'\t'}"
[ "$CHAIN_TICKET_WAS_OUTSTANDING" = "yes" ] || OUTSTANDING_TICKET=""
# The FAULT answer is disclosed on the operator channel and then normalized to `no`,
# so it reaches exactly one reader and every conjunct below keeps its two-value
# domain. It sits beside the sibling disclosures above for the same reason they
# do: below the subagent-type filter, so it can only fire for a real reviewer
# completion, and naming no path and no ticket value. The agent identity is
# deliberately NOT re-spelled here — the census CLAUDE.md pins counts matching LINES
# under `hooks/`, so a comment that names it again moves a figure this comment has no
# business moving. Without
# it a document this hook could not read was byte-identical to a chain holding no
# unclaimed ticket, and since that answer gates `decline()`s own first guard, every
# later decline in the session went silent on BOTH channels — including the one whose
# text exists to report exactly this fault.
if [ "$CHAIN_TICKET_WAS_OUTSTANDING" = "unreadable" ]; then
  # CONJOINED on BOTH plugin-tree modules being usable, and that is a correctness
  # fix rather than a tidy-up. `require("")` throws into the very same catch, so
  # with either module gone the probe answers `unreadable` for a fault in the
  # PLUGIN TREE — and an unconditional line here then printed a SECOND sentence
  # sending the operator to `.zensu/state/` to inspect a document that was never
  # the problem. Each disclosure above already named its own cause under its own
  # class. The NORMALIZATION stays unconditional, so no downstream conjunct sees
  # a different value either way.
  if [ -n "$ZENSU_DELEGATE_CORE" ] && [ -n "$ZENSU_DELEGATE_CLAIM" ]; then
    printf 'zensu: reviewer completion not judged (delegate-workflow-document-unreadable) — this hook could not read the workflow document for this session, so it cannot tell whether this chain holds an unclaimed review ticket and stays silent on the model channel\n' >&2
  fi
  CHAIN_TICKET_WAS_OUTSTANDING=no
fi

# A decline that leaves an outstanding ticket unconsumed is the state that
# stranded chains silently: the reviewer ran, the round was never recorded, and
# every later Stop asked for a review that could not be booked. Disclose it on
# the model-facing channel whenever the decline was decided by THIS session's
# own artifacts — the prompt text this session wrote, and its own workflow
# document, its own durable run record, or this hook's own inability to READ one
# of those. ONE class stays silent, and naming TWO was the error an earlier
# spelling of this comment made: it listed the workspace-HOLDER read answering
# rc 0, which DECLINES in the shipped code (the rc-0 arm below), so the
# partition asserted an existence-oracle guarantee this file does not have —
# and a partition that misstates a member reads as a guarantee twice over.
#   (1) the ticket claim and every exit below it. Do NOT restate that as "a
#       concurrent delivery already recorded the round": that is only the COMMON
#       cause. `tdd_consume_review_ticket_context` also returns 1 on a
#       ticket-shape refusal, a missing `node`, and any lock or IO failure, and
#       those leave the chain stranded with nothing reported — a known gap, not
#       a proof. Below the claim the ticket is already consumed, so a silent
#       exit there does not strand the chain in the state this seam is about.
# What keeps the cross-session existence ORACLE closed is not silence but
# SAMENESS: both workspace-read arms decline with ONE identical sentence, so the
# message's presence answers nothing a failed read would not. The handoff suite
# pins that sentence at exactly two occurrences for precisely this reason.
# TWO further bare-exit classes sit outside that one, and naming only one of them
# read as a partition while it was an omission:
#   (2) every exit ABOVE the ticket read — the principal test, the session bind,
#       the project-root resolve, the subagent-type filter and the state-storage
#       guards. No count is written here, because a numeral in prose is a claim
#       nothing recomputes; read them off `grep -n "exit 0"` down to the
#       `CHAIN_TICKET_STATE=` assignment. None of them can disclose anything: at
#       that point this hook has not read a chain, so it does not know whether a
#       ticket is outstanding, and the message would be about a chain that may
#       not exist. Silence there is the only honest answer, not a gap.
#   (3) the `else` arm of the standalone/bound split, for a
#       `PROMPT_AUTOPILOT_KIND` that is neither value. The parse above emits only
#       those two, so it is unreachable by construction — a defensive arm, not a
#       live class. Named because a reader counting `exit 0` finds it.
# An OWNERSHIP comparison was tried in the outer-run arm and DELETED: see the
# contract citation at that arm. It could only ever have added a third silent
# class on a branch the producer cannot reach.
# The ticket value is a capability token and is never echoed.
#
# It is additionally gated on the prompt showing CONSUME INTENT — the WHOLE-LINE
# fan-out marker, or a ticket that already MATCHED this chain's outstanding
# value. Never "any `REVIEW-TICKET:` line": a prompt QUOTING that literal
# satisfies it. Several flows spawn `zensu:code-reviewer`
# without arming a chain (`/zensu:cover`, `/zensu:wargame`, `/zensu:gauntlet-loop`,
# `/zensu:implement`); those completions already could not consume, and without
# this gate the disclosure would hijack them with a re-spawn instruction for a
# chain they were never part of — for as long as the ticket stays outstanding.
#
# The SAME program answers a second question the accept path needs: whether the
# prompt opened with the exact two consume-header lines. That is the convention
# the reviewer agent selects consume mode on, and it is STRICTER than the ticket
# match this hook decides on — the ticket may sit anywhere, the header may not.
# One probe answers both because the outstanding ticket is already resolved here
# and a second spawn on this path buys nothing.
PROMPT_CONSUME_PROBE="$(TICKET="$OUTSTANDING_TICKET" node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const prompt = j.tool_input && j.tool_input.prompt;
      if (typeof prompt !== "string") { process.stdout.write("no\tno"); return; }
      // WHOLE-LINE marker only, and deliberately NOT "carries a REVIEW-TICKET:
      // line". That weaker test is satisfied by a prompt merely QUOTING one,
      // and column-0 examples of that literal live in the test files of this
      // very repository, so a REVIEW PACKET excerpting them would arm the
      // disclosure for a reviewer from a chainless flow and hand it a remedy
      // that ROTATES the outstanding ticket of this chain. Same "the prompt
      // must not decide" class as the envelope gate above. The other intent
      // signal is a MATCHED ticket, which a quotation cannot forge; the
      // decline function adds it.
      // NO APOSTROPHE MAY APPEAR ANYWHERE IN THIS PROGRAM. It is a bash
      // single-quoted string, so one ends the quote and silently truncates the
      // JS; `bash -n` still passes and the assignment lands EMPTY, which is
      // how a shipped round of this file disabled the whole probe.
      // FIRST line, not any line. The marker is quotable, and this repository
      // renders it at column 0 in the Stop block reason a model reads back, so
      // an any-line test lets a chainless reviewer arm a disclosure whose
      // remedy ROTATES this chain outstanding ticket. Requiring index 0 costs
      // only the marker-not-first-and-no-ticket case, which stays silent; every
      // legitimate consume is already covered by the matched-ticket arm.
      const lines = prompt.split(/\r?\n/);
      const intent = lines[0] === "PRE-MERGED FINDINGS (fan-out)";
      // The header verdict, for the accept path only. It never gates this hook:
      // the ticket is what binds a completion, and a header slip costs the
      // merged fan-out rather than the round. The ticket value is compared, not
      // emitted, so the capability token stays off every channel.
      const want = process.env.TICKET;
      const header = intent && !!want
        && lines[1] === "REVIEW-TICKET: " + want;
      process.stdout.write((intent ? "yes" : "no") + "\t" + (header ? "yes" : "no"));
    } catch (_) { process.stdout.write("no\tno"); }
  });
' <<<"$INPUT" 2>/dev/null)"
PROMPT_CONSUME_INTENT="${PROMPT_CONSUME_PROBE%%$'\t'*}"
PROMPT_CONSUME_HEADER="${PROMPT_CONSUME_PROBE#*$'\t'}"
[ "$PROMPT_CONSUME_INTENT" = "yes" ] || PROMPT_CONSUME_INTENT="no"
[ "$PROMPT_CONSUME_HEADER" = "yes" ] || PROMPT_CONSUME_HEADER="no"

# --- Decline note (the DURABLE half of the operator-channel disclosure) -------
# `additionalContext` is transcript-scoped and the stderr line beside it rides a
# channel this repository already records as UNVERIFIED for delivery on this
# host, so before this note a decline died with the turn: a user returning to a
# stranded chain after a compaction or a fork saw exactly what they saw before
# the disclosure existed. `--chain-status` renders `ticket-unclaimed` with no
# notion that a completion was declined, and no workflow field is written.
#
# Modelled on `reviewer-spawn-denied-<key>.json` in `hooks/stop-chain-enforcer.sh`:
# same directory, same lease, the same character-exact name shape the only reader
# matches, the same `O_EXCL` temp landed by rename, and the same reader-side
# binding to a sibling `tdd-phase-<key>.json`. It carries the remedy MODE and a
# timestamp and NEVER the ticket value — the ticket is a capability token, which
# is why this hook echoes it on no channel at all.
#
# Every fault leaves the hook advisory: the write is best-effort, the exit status
# is untouched, and neither disclosure above it is withheld on a failed note.
decline_note_path() {
  # Asserts the SAME shape the doctor filename regex requires rather than the
  # prefix alone: a `scv1_` id of any other length would land under a name the
  # only reader silently never matches, which is the "rename one and doctor goes
  # quiet with everything still green" failure the sibling writer records.
  case "$SESSION_ID" in
    scv1_*[!0-9a-f]*) return 1 ;;
    scv1_????????????????????????????????????????????????????????????????) ;;
    *) return 1 ;;
  esac
  printf '%s/.zensu/state/review-decline-%s.json' "$PROJECT_ROOT" "$SESSION_ID"
}

decline_note_write_unlocked() {
  local note
  note="$(decline_note_path)" || return 0
  # `dirname` reads argv and cannot block on stdin, so it is the one child here
  # that carries no `</dev/null` — the same exemption the sibling writer states.
  [ -d "$(dirname "$note")" ] || return 0
  # The state directory is writable from inside the session, so the note is
  # written the way every other record in it is: refuse a pre-planted symlink,
  # non-file or hard link outright, then land an exclusive temp by rename.
  # stdout is redirected as well as stderr, because this hook writes its
  # model-facing context to stdout and a stray byte here would corrupt it.
  MODE="$1" NOTE="$note" node -e '
    const fs=require("node:fs");
    const note=process.env.NOTE;
    // Per-process temp name, for the reason the sibling writer records: a
    // deterministic one lets two writers publish bytes neither of them wrote,
    // and a planted directory at that fixed name silences the note forever.
    const tmp=note+"."+process.pid+".tmp";
    try {
      const st=fs.lstatSync(note);
      if(st.isSymbolicLink()||!st.isFile()||st.nlink!==1) process.exit(0);
    } catch (e) { if(e.code!=="ENOENT") process.exit(0); }
    try {
      const fd=fs.openSync(tmp,
        fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL, 0o600);
      try {
        fs.writeSync(fd, JSON.stringify({
          schemaVersion:1, kind:process.env.MODE||"",
          subagentType:"zensu:code-reviewer", detectedAtMs:Date.now(),
        })+"\n");
      } finally { fs.closeSync(fd); }
      fs.renameSync(tmp, note);
    } catch (e) {
      // A half-written temp must not outlive the attempt that made it. Safe
      // because only this pid can name it.
      try { fs.rmSync(tmp,{force:true}); } catch (_) { /* nothing else to do */ }
    }
  ' </dev/null >/dev/null 2>&1 || true
  return 0
}

decline_note_clear_unlocked() {
  local note
  note="$(decline_note_path)" || return 0
  # The temp carries a per-process suffix (see the writer), so the glob is what
  # retires a crashed writer leftover. An unmatched glob is silently ignored
  # under `rm -f`, and the shape guard above has already pinned every character
  # of the name, so this cannot widen past the intended file.
  rm -f "$note" "$note".*.tmp 2>/dev/null || true
  return 0
}

decline_note_clear() {
  if declare -F _tdd_locked_run >/dev/null 2>&1 && [ -n "${TDD_STATE_FILE:-}" ]; then
    _tdd_locked_run "$TDD_STATE_FILE" decline_note_clear_unlocked 2>/dev/null && return 0
  fi
  decline_note_clear_unlocked
  return 0
}

decline_note_write() {
  # Same `set -u` plus bash 3.2 hazard the sibling lease wrapper guards against,
  # and `return 0` is the right direction here for the same reason: this writer
  # never changes what the hook emits.
  [ "$#" -gt 0 ] || return 0
  # The lease is an IMPROVEMENT, never a precondition: on a failed acquisition
  # the write still runs unlocked, because a lost note must not cost the
  # disclosure. The callback ALWAYS returns 0, which is what makes a non-zero
  # result here unambiguously a lease failure rather than a failed write.
  if declare -F _tdd_locked_run >/dev/null 2>&1 && [ -n "${TDD_STATE_FILE:-}" ]; then
    _tdd_locked_run "$TDD_STATE_FILE" decline_note_write_unlocked "$1" 2>/dev/null && return 0
  fi
  decline_note_write_unlocked "$1"
  return 0
}

decline() {
  local cause="$1" mode="${2:-runstate}" lead remedy
  [ "$CHAIN_TICKET_WAS_OUTSTANDING" = "yes" ] || exit 0
  # The OPERATOR channel is not gated on consume intent, and that asymmetry is
  # the point: the model-facing disclosure below is withheld whenever the prompt
  # showed no consume intent, so without this line a chain holding an unclaimed
  # ticket could be stranded with nothing on ANY channel. One line, naming the
  # gate that refused and the remedy MODE, never the ticket value. It stays
  # below the outstanding-ticket guard, and the bound that guard enforces is the
  # SESSION's chain rather than the completing flow: a completion arriving while
  # this session's chain holds no unclaimed ticket strands nothing and owes the
  # operator no line. A completion from a chainless flow while this session's own
  # chain DOES hold one is therefore reported, which is correct — the strand is
  # the chain's, not the flow's.
  # ONE post-claim decision, THREE consumers. The lead is per-mode for the same
  # reason the model-facing opener below is: above the claim the round was NOT
  # recorded, below it the round counted and only the findings were dropped. One
  # fixed lead made the two channels contradict each other about the same event.
  # What decides that is the CLAIM PHASE rather than any single mode name, and
  # two of the three dispatches used to test the literal `spent` directly — so a
  # SECOND post-claim mode would have fallen to their catch-all and told the
  # reader the completion was not recorded while its ticket was consumed and its
  # round counted. The post-claim set is enumerated HERE, once; the remedy `case`
  # below still names every mode, because it selects a text per mode rather than
  # per phase. It is a `local` rather than a file-scope constant deliberately:
  # `decline()` is extracted and evaluated in isolation by S28a, so every value
  # its body depends on has to travel with the body.
  local post_claim_modes="spent"
  local post_claim=no
  case " ${post_claim_modes} " in
    *" ${mode} "*) post_claim=yes ;;
  esac
  local stderr_lead="reviewer completion not recorded"
  [ "$post_claim" = "yes" ] && stderr_lead="reviewer round recorded but its findings were not routed"
  printf 'zensu: %s (%s) — %s\n' "$stderr_lead" "$mode" "$cause" >&2
  # The DURABLE half of the same disclosure, minted on the SAME gate the line
  # above uses — the outstanding ticket alone, never the consume-intent test
  # below — because a decline this hook reports on no durable surface is exactly
  # the strand this feature exists to end. `declare -F` rather than a bare call:
  # `decline()` is extracted and evaluated in ISOLATION by the scope suite, where
  # only `emit_post_context` is stubbed, so an unguarded name would fail a
  # harness whose fixture never defines it.
  if declare -F decline_note_write >/dev/null 2>&1; then decline_note_write "$mode"; fi
  # Consume intent is the marker as the FIRST line, or a ticket that already
  # MATCHED. Only the second is unforgeable: a quotation cannot reproduce the
  # chain's live outstanding value, while the marker is ordinary text that this
  # repository itself renders at column 0 in the Stop block reason. Do NOT
  # restate this as "neither can be supplied by a chainless flow" — that was
  # asserted here and is false. What the line-0 requirement buys is that the
  # quoted copy has to be the prompt's opening line, which no chainless flow
  # produces; the residual is recorded rather than claimed away.
  [ "$PROMPT_CONSUME_INTENT" = "yes" ] || [ -n "${REVIEW_TICKET:-}" ] || exit 0
  # The remedy is selected by the caller through a NAMED mode, because one remedy
  # for every cause is worse than none. The arm set is the `case` below and its
  # count is deliberately not written here: a numeral in prose is a claim nothing
  # recomputes, and the previous one ("TWO") had already drifted past the arms
  # that shipped. The re-spawn recipe is correct only where the PROMPT is
  # what was refused. Several gates refuse on DURABLE RUN STATE instead — that
  # set is likewise not counted; read it off `grep -n runstate` over this file.
  # On every one of them a fresh
  # ticket plus a re-spawn reproduces byte-identical inputs to the same gate —
  # an unbounded loop, since this hook never blocks and the Stop cap therefore
  # never arbitrates it, while the rotation strands any spawn still in flight.
  # The mode is a NAMED positional and the selector is a `case` with a catch-all,
  # never `${2:-respawn}`: a misspelled or omitted mode at a call site used to
  # select the rotation text silently, and the rotation is the one remedy that
  # is destructive when it is wrong. The safe text is therefore the default AND
  # the catch-all — an unknown mode refuses to guess.
  # The lead sentence is per-mode, because the state it describes is not the same
  # above and below the claim. State the CRITERION rather than a list: an
  # enumeration here read "runstate, runstate-foreign, respawn" while EVERY
  # pre-claim mode already selected `outstanding_lead`, and every mode added since
  # made it wronger. EVERY pre-claim mode — which is every mode the
  # `post_claim_modes` set above does not name — refuses while the ticket is
  # still OUTSTANDING, so their lead says the
  # backstop keeps asking and the chain cannot converge. The post-claim callers
  # pass `spent`: the ticket is already consumed and this round is counted, so the
  # loss is a DIFFERENT one — the merged findings were dropped — and telling the
  # reader the ticket is still outstanding would be false and would invite a
  # rotation that strands nothing but wastes the next budget.
  local outstanding_lead="The chain still holds an unclaimed review ticket, so the Stop backstop will keep asking for a review and the chain cannot converge."
  local spent_lead="Its round counted and the ticket is spent, but its findings were NOT routed to a fix round, so the merged findings were dropped while the Stop backstop still asks for a review this chain has not converged."
  # DERIVED ONCE, off the same `$post_claim` classifier the stderr lead above and
  # the opener below read — never per-arm inside the remedy `case`. Keyed on the
  # ARM, a SECOND post-claim mode added to `post_claim_modes` alone would select
  # `outstanding_lead` here while the opener said the round WAS recorded, so the
  # two model-facing halves of one message would contradict each other about the
  # same event. That is the failure a per-mode lead exists to prevent, and an
  # arm-keyed assignment reintroduces it silently. The `case` below therefore
  # selects the remedy TEXT alone, which really is per mode rather than per phase.
  lead="$outstanding_lead"
  [ "$post_claim" = "yes" ] && lead="$spent_lead"
  # CROSS-FILE CONTRACT — the two NAMES below are read from another file, so a
  # rename here is a cross-file edit whose failure surfaces in a suite this file
  # is not named for. `T63` in `tests/structure/test-stop-enforcer-self-review-routing.sh`
  # greps `local spent_remedy=` and `local runstate_remedy=` verbatim, then holds
  # EACH SIDE to its own literals — the delegate slices against delegate-side
  # needles, both `INNER_REVIEW_HEADERS` variants in `hooks/stop-chain-enforcer.sh`
  # against Stop-side ones. The two needle sets are DISJOINT and nothing is
  # compared across the file boundary, so state it that way: T63 fails when either
  # side stops naming both rotation arms, and does NOT fail when one side is
  # reworded while still carrying its own needle. That residual is the reason the
  # rename above is still a cross-file edit to make by hand. Named HERE rather than only
  # in that suite for the reason the bound-args copy below already records: a
  # trigger nobody reads at the site that fires it is not a trigger. CLAUDE.md
  # §"Ticket-Keyed Review Consumption" carries the same pair on its pin roster.
  local spent_remedy="Nothing is stranded in flight, because the spawn that carried this ticket is the completion above, so do not rotate a ticket on reflex. Mint a fresh ${LOG_COMMAND} --review-ticket and re-spawn zensu:code-reviewer with the same consume header and the same merged findings; that next completion counts against the same review budget. Do NOT take the command ${LOG_COMMAND} --chain-status names in this state: a consumed claim classifies as a review still in flight, whose supported next command is --code-review-done, and running that here would close the round with the dropped findings never routed."
  # It prescribes no repair under `.zensu/state/`, and that omission is the whole
  # correction: every sibling remedy forbids editing that directory, the plugin's
  # own Edit gate denies it while a chain is active, and the only channel left is
  # an ungated shell redirect this repository records as an accepted residual
  # rather than a sanctioned one. A remedy that names an action with no
  # performable sanctioned channel steers the reader into that residual, and this
  # is the DEFAULT mode as well as the catch-all, so it was the most-reached text
  # in the file.
  #
  # SCOPE THE DENY CLAIM TO THE GATE THAT MAKES IT, because the remedy asserted a
  # control the tree does not have. What denies is `hooks/pre-edit-tdd-reminder.sh`,
  # on its `Edit|Write|MultiEdit` matcher, and only while a chain is active. No Bash
  # gate covers that path at all — `hooks/lib/bash-source-write-parse.js` carries no
  # `.zensu` rule in any of its three rules — so a shell redirect into
  # `.zensu/state/` is ungated in every chain state, which is exactly the residual
  # the paragraph above already names. An unqualified "that path is gate-denied"
  # therefore told a model the one channel it could still take was closed, which is
  # both false and the wrong kind of false: it invites the reader to discover the
  # open channel and read the refusal as a bug. State the gate, and let the
  # instruction rest on the absence of a sanctioned repair rather than on a deny
  # that does not exist.
  #
  # THE RESIDUAL STAYS HERE AND NEVER IN THE EMITTED STRING, and the two corrections
  # pull opposite ways — restore neither. An earlier spelling fixed the overstatement
  # by naming the ungated redirect channel to the MODEL, which is the hatch-teaching
  # shape CLAUDE.md forbids under §"Git Mutation Tables": a shipped escape teaches the
  # hatch. This is the catch-all arm, so that sentence reached every consuming repo on
  # every unclassified decline, with nothing behind it but prose telling the reader not
  # to use what it had just named. The four sibling remedies forbid the same edit while
  # naming no channel at all; that is the wording to match. So: do NOT restore the
  # unqualified "that path is gate-denied", and do NOT restore the channel disclosure.
  local runstate_remedy="Do NOT issue a fresh review ticket and do NOT re-spawn: the prompt is not what was refused, so a re-spawn reproduces this decline exactly while rotating the ticket out from under any spawn still in flight. Resolve the durable run state first — read a fresh ${LOG_COMMAND} --autopilot-status, then finish or release that run — and only then re-spawn with the ticket the chain already holds. Do not edit anything under .zensu/state/ to make the read succeed: the Edit, Write and MultiEdit tools are gate-denied on that path while a chain is active, and no channel of any kind repairs this."
  local respawn_remedy="Re-spawn zensu:code-reviewer with a prompt whose FIRST line is exactly 'PRE-MERGED FINDINGS (fan-out)' and whose SECOND line is exactly 'REVIEW-TICKET: <the current ticket>'. Both lines, in that order: the reviewer agent enters consume mode only on that pair, and a prompt that satisfies this hook but not the agent still records the round while throwing the whole fan-out away, because the reviewer then re-reviews from scratch instead of consuming the merged findings. Mint a replacement by running: ${LOG_COMMAND} --review-ticket — that verb ISSUES a new ticket and ROTATES the outstanding one, it does not read the current value back, so run it only when no zensu:code-reviewer spawn is still in flight: a spawn already running carries the old value and can never be recorded afterwards. An Autopilot-bound chain must additionally carry exactly one DISTINCT value each of ZENSU-DELEGATED-CALLER, AUTOPILOT-BINDING and AUTOPILOT-STAGE, unchanged — a byte-identical repeat is fine, two regex-valid lines that differ are not, and a binding or stage line failing its regex is dropped before the collapse rather than counted; the caller line keeps its exact-literal test and has no such filter. A STANDALONE chain must not carry a COMPLETE, well-formed set of those three; an incomplete set is ignored, so quoting one of them is harmless."
  # The UNATTRIBUTABLE run-state remedy. The arms that select it refused on a
  # read that is owner-independent — a workspace held by some run, a record in
  # the shared state directory that would not validate — so nothing here may
  # point at `--autopilot-status`, which is owner-scoped and structurally cannot
  # show a foreign run, and nothing here may instruct an edit under
  # `.zensu/state/`, because the record behind the refusal may belong to another
  # live session. That is the whole difference from `runstate_remedy`, whose
  # arms have established that the run is this session's own.
  local foreign_remedy="Do NOT issue a fresh review ticket and do NOT re-spawn: the prompt is not what was refused, so a re-spawn reproduces this decline exactly while rotating the ticket out from under any spawn still in flight. The durable run state behind this refusal is not attributable to this session from here — the state directory under .zensu/state/ can hold a run record another live session owns — so do not edit anything there. Wait for or coordinate with the session that holds the working tree, or hand this to the user, and re-spawn with the ticket the chain already holds only once the tree is free."
  # The ENVELOPE remedy exists because the gate that selects it decides on PROMPT
  # CONTENT ALONE — it reads `tool_input.prompt` and nothing else, and it runs
  # before any durable run record is read. Routing it to `runstate_remedy` told
  # the model "the prompt is not what was refused" in the same breath as a cause
  # naming the prompt's own envelope, and sent it to repair a record under
  # `.zensu/state/` that nothing on that path established as unreadable. The
  # ticket rotation stays WITHHELD here, unlike `respawn_remedy`: the prompt is
  # repairable without a new ticket, and rotating would strand any spawn still in
  # flight for a fault the next prompt can simply not carry.
  local envelope_remedy="Do NOT issue a fresh review ticket: the ticket is not what was refused and rotating it would strand any spawn still in flight. What was refused is the Autopilot envelope in the PROMPT, and nothing about the durable run state was read on this path — so do not read --autopilot-status for this and do not edit anything under .zensu/state/. Re-spawn zensu:code-reviewer with the SAME ticket the chain already holds, the same two consume-header lines, and a corrected envelope: a bound chain carries exactly one DISTINCT regex-valid line each of ZENSU-DELEGATED-CALLER, AUTOPILOT-BINDING and AUTOPILOT-STAGE, matching the durable run; a standalone chain carries no complete set of the three at all, so drop them rather than repairing them."
  # The ENVELOPE-VS-RECORD remedy, and it is a mode of its own rather than a reuse
  # of `envelope_remedy` for a reason that is easy to get wrong in either
  # direction. No ordinal is written here: the paragraph above the
  # `outstanding_lead` declaration states that this function's own mode count is
  # deliberately not spelled in prose, because a numeral in a comment is a claim
  # nothing recomputes — and the one that stood here named an ordinal the remedy
  # `case` had already outgrown while CLAUDE.md named a different one. Anchor that
  # cross-reference by SYMBOL and never by a line offset: it read "four lines
  # above" while the statement sat some ninety lines up, which is the stale-anchor
  # class this repository forbids. Do not restore either numeral.
  # Both gates refuse on the PROMPT, so both withhold the rotation — three shipped
  # carriers state that rule (the `post-review-tdd-delegate.sh` row in
  # `docs/configuration.md`, the matching paragraph in
  # `docs/tdd-manager-workflow.md`, and `skills/tdd/SKILL.md` Phase 6 step 5), and
  # routing this arm to `respawn` violated all three: that remedy mints a fresh
  # ticket, which strands any spawn still in flight for a fault the next prompt
  # can simply not carry. But `envelope_remedy` additionally asserts that nothing
  # about the durable run state was read on its path, which is true of the PARSE
  # gate and false here: this arm compares the prompt against `PREFLIGHT_CONTEXT`,
  # this chain's OWN workflow document, already read above. Reusing it would have
  # forbidden the one read that resolves this state. The Stop hook's own clause
  # rotates the ticket only when the TICKET ITSELF is unusable — a completion that
  # named no outstanding ticket at all, or one declined after its claim landed and
  # therefore spent — and neither holds here: the ticket is outstanding and the
  # prompt is what is wrong, so withholding the rotation is what that clause says
  # rather than an exception to it. An earlier wording quoted the clause's old
  # "only when the PROMPT was what a previous completion was refused on" lead and
  # defended the withholding as a PERMISSION bound; that lead was itself
  # contradicted by its own second arm and has been replaced, so do not restore
  # the quotation or the permission argument from it.
  local envelope_record_remedy="Do NOT issue a fresh review ticket: the ticket is not what was refused, and rotating it would strand any spawn still in flight. What was refused is the Autopilot envelope in the PROMPT, measured against this chain's OWN record rather than against the durable run — so read ${LOG_COMMAND} --chain-status for the run, attempt and chain this chain is bound to, and use a fresh ${LOG_COMMAND} --autopilot-status only to confirm the durable run still agrees with it. Editing anything under .zensu/state/ is not the repair: the record is the truth here and the prompt is what is wrong. Re-spawn zensu:code-reviewer with the SAME ticket the chain already holds, the same two consume-header lines, and an envelope whose run, attempt, chain and stage match that record exactly."
  # The RUN-GONE remedy, and BOTH of its earlier defects are recorded here because
  # each reads as correct on its own. `runstate_remedy` prescribes three actions —
  # finish the run, release it, repair an unreadable record — and on this arm none
  # has a referent: this session's owner-keyed pointer designates no nonterminal
  # run, so there is nothing to finish and no record that failed to read.
  #
  # (1) It must not forbid what its own exit prescribes. Routing the reader to
  #     `--chain-status` while forbidding a fresh ticket AND a re-spawn was a dead
  #     end: at this point the ticket is still outstanding and unconsumed, so the
  #     chain classifies `ticket-unclaimed`, whose supported next command IS
  #     "issue a fresh ticket and re-spawn" — the two actions the text banned. The
  #     bans were written against the OTHER failure mode, a re-spawn that re-enters
  #     the same read; what makes that harmless here is the order. Re-anchor the
  #     durable binding FIRST, and only then take the shape's own command.
  # (2) It must not claim more than an owner-scoped rc 1 proves. That status means
  #     no nonterminal run of THIS session is designated by the owner-keyed
  #     pointer; a live record whose pointer read failed produces it too, and there
  #     the right action is a release rather than the one the old text ruled out.
  #     Same standard the sibling orphan release states: "not reachable", never
  #     "gone".
  # (3) It must name the states its arms REALLY reach, which is the correction
  #     this round made. Two arms select it and they are not the same state. The
  #     owner-scoped read's rc 1 is `state file absent: <pointer>` — the pointer
  #     FILE is gone — and it says nothing at all about release or completion,
  #     because `autopilot_release_run` leaves the owner's pointer in place. A
  #     released or completed run therefore answers rc 0 carrying a TERMINAL
  #     record, and that is the second arm: the bound comparison below splits it
  #     off rather than letting it fall through to a binding-disagreement verdict
  #     that misdiagnoses a finished run as a mismatched prompt.
  local run_gone_remedy="Do NOT rotate the ticket yet, and do not re-spawn into this state unchanged: this session's owner-keyed pointer designates no LIVE durable Autopilot run to judge the bound claim against, so the same read answers the same way and the chain does not advance. Two different states reach here and the cause above says which: either the owner-keyed pointer file itself is absent — which proves only that, never that the run was released or completed — or the run it designates has already reached a terminal stage. Establish which before acting: read ${LOG_COMMAND} --autopilot-status. Where it reports a run, its stage is the answer — a terminal one means this attempt is over and the bound claim has nothing left to record, and a live one means the pointer read failed rather than the run ending, so finish or release that run instead of treating it as absent. Where it refuses in the same way this did, the pointer is genuinely gone. Do not edit anything under .zensu/state/ to make the read succeed. Once the durable binding is settled, read ${LOG_COMMAND} --chain-status and take the supported command it names for the shape it reports — with the ticket still unclaimed that command is a fresh ticket plus a re-spawn, and it is correct THEN because the read it re-enters has been resolved."
  # The OPENER is decided by the CLAIM PHASE for the same reason the stderr lead
  # is, and off the same `$post_claim` classifier rather than off its own literal.
  # A fixed opener asserting the completion was NOT recorded contradicted
  # `spent_lead` on every post-claim decline, and the Stop hook's own directive
  # asks the model to branch on exactly that distinction.
  local opener
  case "$mode" in
    runstate)         remedy="$runstate_remedy" ;;
    runstate-foreign) remedy="$foreign_remedy" ;;
    respawn)          remedy="$respawn_remedy" ;;
    envelope)         remedy="$envelope_remedy" ;;
    envelope-record)  remedy="$envelope_record_remedy" ;;
    run-gone)         remedy="$run_gone_remedy" ;;
    spent)            remedy="$spent_remedy" ;;
    *)                remedy="$runstate_remedy" ;;
  esac
  opener="The zensu:code-reviewer subagent above finished, but its completion was NOT recorded against this session's review chain: ${cause}."
  [ "$post_claim" = "yes" ] && opener="The zensu:code-reviewer subagent above finished and its completion WAS recorded against this session's review chain, but the round's findings were not routed back: ${cause}."
  printf '%s' "${opener} ${lead} ${remedy} Do NOT arm a new chain to work around this — that would grant a new review budget." | emit_post_context
  exit 0
}

# Match the prompt against the chain's OUTSTANDING ticket rather than requiring
# a unique REVIEW-TICKET line: the REVIEW PACKET legitimately quotes that
# literal whenever the reviewer is reviewing this repository itself, so a
# uniqueness rule would refuse a correct consume. Only the outstanding one-shot
# ticket can ever match, which is exactly the binding the claim enforces.
REVIEW_TICKET="$(TICKET="$OUTSTANDING_TICKET" node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const prompt = j.tool_input && j.tool_input.prompt;
      const want = process.env.TICKET;
      if (typeof prompt !== "string" || !want) process.exit(3);
      const found = prompt.split(/\r?\n/)
        .filter(line => line.startsWith("REVIEW-TICKET: "))
        .map(line => line.slice("REVIEW-TICKET: ".length));
      if (!found.includes(want)) process.exit(3);
      process.stdout.write(want);
    } catch (_) { process.exit(3); }
  });
' <<<"$INPUT" 2>/dev/null)" \
  || decline "the prompt carried no \`REVIEW-TICKET: <ticket>\` line naming this chain's outstanding ticket" respawn

PREFLIGHT_CONTEXT="$(STATE_FILE="$NATIVE_TDD_STATE_FILE" SID="$SESSION_ID" CORE_MODULE="$ZENSU_DELEGATE_CORE" node -e '
  try {
    // Same hardened read as the ticket probe above, and for the same reason: a
    // bare open on this session-writable path blocks forever on a planted FIFO.
    const core = require(process.env.CORE_MODULE);
    const s=JSON.parse(core.readRegularFileSnapshot(process.env.STATE_FILE).data.toString("utf8"));
    const keys=["autopilotRunId","autopilotAttempt","autopilotReturnStage","chainId","chainOutcome"];
    const count=keys.filter(key => Object.prototype.hasOwnProperty.call(s,key)).length;
    if(count===0){process.stdout.write("{}");process.exitCode=0;}else{
    const id=value => typeof value==="string" && value.length>=3 && value.length<=128
      && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
    const valid=count===keys.length
      && s.session_id_hash===`sha256:${process.env.SID.slice("scv1_".length)}`
      && id(s.autopilotRunId) && Number.isInteger(s.autopilotAttempt)
      && s.autopilotAttempt>=1 && s.autopilotAttempt<=999
      && ["GATES","CONVERGE","FIX_FINDINGS","VALIDATE","COVER"].includes(s.autopilotReturnStage)
      && id(s.chainId) && s.chainOutcome===""
      && s.active===true && s.implComplete===true && s.chainDone===false;
    if(!valid)process.exit(3);
    process.stdout.write(JSON.stringify({
      active:s.active,implComplete:s.implComplete,chainDone:s.chainDone,
      runId:s.autopilotRunId,attempt:s.autopilotAttempt,
      returnStage:s.autopilotReturnStage,chainId:s.chainId,outcome:s.chainOutcome
    }));
    }
  // A FAULT is not a judged payload — the same rule this file applies to both of
  // its stdin pipes, and the rule the plan-payload gate states for its own load
  // failures. The catch used to exit 3, indistinguishable from the
  // `if(!valid)process.exit(3)` above it, so a require fault or a refusal from
  // the hardened reader was declined as a document that carries an INVALID
  // linkage block — and the run-state remedy then told the reader to go and
  // resolve a document nothing had managed to open.
  } catch (_) { process.exit(4); }
' 2>/dev/null)" || PREFLIGHT_CONTEXT_RC=$?
case "${PREFLIGHT_CONTEXT_RC:-0}" in
  0) ;;
  4) decline "this session's workflow document could not be read, or its reader module could not be loaded, so the Autopilot linkage block was never judged" runstate ;;
  *) decline "this session's workflow document carries an incomplete or invalid Autopilot linkage block (run, attempt, return stage, chain id, outcome), so the completion cannot be recorded against it" runstate ;;
esac

# WHETHER this chain is Autopilot-bound is decided by the DURABLE STATE above,
# never by counting prefixes in the prompt. Deciding it from the prompt made a
# single QUOTED envelope literal refuse a standalone chain: the old rule took
# the standalone branch only when the four prefixes summed to zero, and those
# literals sit at column 0 in `skills/autopilot`, `skills/pr-fix-findings` and
# `skills/pr-team-review`, which a REVIEW PACKET quotes whenever the reviewer is
# reviewing this repository — the same class removed for the ticket one gate up.
# On a standalone chain the envelope authorises nothing, so an incomplete set of
# literals is IGNORED; a COMPLETE, regex-valid triple is still refused, because
# that is a deliberate spoof rather than a quotation. On a bound chain the rule
# is unchanged and strict: exactly one of each, no team-review header, the
# caller value exact, both regexes — then every field compared against the run.
if [ "$PREFLIGHT_CONTEXT" = '{}' ]; then EXPECT_BOUND=no; else EXPECT_BOUND=yes; fi
PROMPT_ENVELOPE_FIELDS="$(EXPECT_BOUND="$EXPECT_BOUND" node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const input = JSON.parse(s);
      const prompt = input.tool_input && input.tool_input.prompt;
      if (typeof prompt !== "string") process.exit(3);
      const lines = prompt.split(/\r?\n/);
      // The bound branch counts DISTINCT REGEX-VALID lines, and the collapse
      // happens further down, on that branch alone: `collect` here returns raw
      // occurrences. A byte-identical repeat asserts the same binding twice and
      // adds no authority, while the skill files in this repository carry these
      // literals at column 0 — so a REVIEW PACKET quoting them while a bound
      // chain runs reproduced one and the whole envelope was refused, which is
      // the same defect the standalone branch was relaxed for. Two DIFFERENT
      // regex-valid lines are still refused: the hook may not pick between two
      // bindings. A shape-invalid line is dropped ahead of the collapse, so it
      // neither refuses nor authorizes; `callers` keeps its exact-literal test
      // and carries no such filter, so two differing caller lines are refused
      // whatever their shape.
      // NOTE: no apostrophe may appear anywhere in this program. It lives in a
      // bash single-quoted string, so one truncates the whole thing — which is
      // exactly what happened while this comment was first written, and what
      // S18 in tests/structure/test-post-review-tdd-scope.sh scans for.
      const collect = prefix => lines.filter(line => line.startsWith(prefix));
      const distinct = list => [...new Set(list)];
      const callers = collect("ZENSU-DELEGATED-CALLER:");
      const bindings = collect("AUTOPILOT-BINDING:");
      const stages = collect("AUTOPILOT-STAGE:");
      const reviewOps = collect("AUTOPILOT-REVIEW-OP:");
      const BINDING_RE = /^AUTOPILOT-BINDING: run=([A-Za-z0-9][A-Za-z0-9_.:-]{2,127}) attempt=([1-9][0-9]{0,2}) chain=([A-Za-z0-9][A-Za-z0-9_.:-]{2,127})$/;
      const STAGE_RE = /^AUTOPILOT-STAGE: (GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER)$/;
      const binding = bindings.length === 1 ? BINDING_RE.exec(bindings[0]) : null;
      const stage = stages.length === 1 ? STAGE_RE.exec(stages[0]) : null;
      // The SPOOF test and the BOUND-acceptance test are separate on purpose.
      // Folding `reviewOps.length === 0` into the triple made one extra
      // AUTOPILOT-REVIEW-OP line flip a complete, regex-valid spoof back to
      // "standalone" — the refusal the comment above promises, bypassed by
      // adding a header rather than by removing one.
      // State what that buys, precisely: the spoof refusal is BEST-EFFORT and is
      // add-a-line evadable by construction, because the raw counting above makes
      // a second differing AUTOPILOT-BINDING line yield bindings.length === 2 and
      // therefore a null binding, so the triple is false and the claim proceeds.
      // Keeping the review-op conjunct out of it removes one such spelling, not the
      // class. What actually prevents a FORGED binding is that AUTOPILOT_KIND is
      // derived from the durable claim context further down and the standalone path
      // requires it to be standalone — never this arm.
      // RAW counts here. This predicate is ALSO the standalone spoof test, and
      // collapsing repeats on that arm moved a doubled quotation from ignored
      // to refused-as-a-spoof — a decline whose remedy rotates a live ticket.
      // ONE predicate over the CALLER list and the two already-reduced operands.
      // Written twice, a conjunct added to one and not the other was a divergence
      // no fixture could see, because each arm is driven only by its own cases.
      // State the bound precisely: the helper covers the caller test and the attempt
      // ceiling, and the binding and stage REDUCTIONS above and below it are still
      // two hand-written sites that differ on a SECOND axis besides raw-versus-
      // distinct — the bound one shape-filters before counting cardinality, the
      // standalone one counts unfiltered lines. Re-check those two by hand.
      const CALLER_LITERAL = "ZENSU-DELEGATED-CALLER: autopilot";
      const triple = (c, b, st) => c.length === 1 && c[0] === CALLER_LITERAL
        && !!b && !!st && Number(b[2]) <= 999;
      const completeTriple = triple(callers, binding, stage);
      // DISTINCT counts, bound branch only: a byte-identical repeat asserts the
      // same binding twice and adds no authority, and the skill files in this
      // repository carry these literals at column 0, so a REVIEW PACKET quoting
      // one refused a bound chain outright. Two DIFFERENT regex-valid lines are
      // still refused; a shape-invalid line is dropped by the filter below and
      // is therefore neither a refusal nor an authorization.
      // Shape-filter BEFORE collapsing, the same discipline realReviewOps gets:
      // the skill files carry placeholder binding and stage lines at column 0 that
      // do NOT collapse against a real rendered line, so a quotation reached size 2
      // and vetoed a live bound envelope. `callers` deliberately keeps its exact
      // literal test: shape-filtering there would IGNORE a foreign caller value
      // that must still refuse.
      const dCallers = distinct(callers);
      const dBindings = distinct(bindings.filter(line => BINDING_RE.test(line)));
      const dStages = distinct(stages.filter(line => STAGE_RE.test(line)));
      const dBinding = dBindings.length === 1 ? BINDING_RE.exec(dBindings[0]) : null;
      const dStage = dStages.length === 1 ? STAGE_RE.exec(dStages[0]) : null;
      const boundTriple = triple(dCallers, dBinding, dStage);
      if (process.env.EXPECT_BOUND !== "yes") {
        if (completeTriple) process.exit(3);
        process.stdout.write(["standalone", "-", "0", "-", "-"].join("\t"));
        return;
      }
      // A bound chain additionally refuses a team-review header. That conjunct
      // belongs HERE and not in `completeTriple`, which is also the spoof test.
      // reviewOps needs the same shape discipline as its siblings: judged by
      // PREFIX alone, any quoted placeholder starting with the literal vetoed the
      // whole envelope, and the skill files carry exactly such placeholders.
      // The pattern is the EXACT producer shape rather than a permissive class.
      // Both producers mint `team-review:v1:` plus 64 lowercase hex, and the state
      // library already spells that shape twice itself; the character class this
      // replaced accepted a domain no producer can reach, sitting between the two
      // producers and the still wider `nonEmpty(operationKey, 256)` the worker
      // validator takes. S25 pins it against a key the shell producer really minted.
      const REVIEW_OP_RE = /^AUTOPILOT-REVIEW-OP: key=team-review:v1:[a-f0-9]{64} head=[a-fA-F0-9]{7,64}$/;
      const realReviewOps = distinct(reviewOps).filter(line => REVIEW_OP_RE.test(line));
      if (!boundTriple || realReviewOps.length !== 0) process.exit(3);
      process.stdout.write(["bound", dBinding[1], dBinding[2], dBinding[3], dStage[1]].join("\t"));
    } catch (_) { process.exit(3); }
  });
' <<<"$INPUT" 2>/dev/null)" \
  || decline "the Autopilot envelope in the prompt did not match this chain: a bound chain needs exactly one DISTINCT line each of ZENSU-DELEGATED-CALLER / AUTOPILOT-BINDING / AUTOPILOT-STAGE and no team-review header, and a standalone chain must carry no complete envelope at all" envelope
IFS=$'\t' read -r PROMPT_AUTOPILOT_KIND PROMPT_AUTOPILOT_RUN \
  PROMPT_AUTOPILOT_ATTEMPT PROMPT_AUTOPILOT_CHAIN PROMPT_AUTOPILOT_STAGE \
  <<<"$PROMPT_ENVELOPE_FIELDS"

if [ "$PROMPT_AUTOPILOT_KIND" = standalone ]; then
  # Two separate questions, and only the first is about ownership. WHOSE outer
  # generation is this chain bound to? Only an absent or terminal one OF THIS
  # SESSION permits an unbound claim, so that read stays owner-scoped: a foreign
  # run is not this session's outer generation and legitimately leaves the chain
  # unbound. A corrupt read is authoritative and must fail closed before ticket
  # mutation.
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
  if PREFLIGHT_OUTER="$(autopilot_read_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)"; then
    PREFLIGHT_OUTER_RC=0
  else
    PREFLIGHT_OUTER_RC=$?
  fi
  case "$PREFLIGHT_OUTER_RC" in
    0)
      # rc 0 ALREADY PROVES OWNERSHIP, so this arm asserts an own run without
      # re-deriving it. `zensu-autopilot-state.sh`'s `read-active` worker runs
      # `if (state.ownerSessionId !== expectedOwnerSessionId) fail(2, ...)`
      # BEFORE its only `process.exit(0)`, and `readRunInventory` additionally
      # skips records it can prove belong to another owner. An owner comparison
      # here was tried and was DEAD CODE: its foreign arm is unreachable while
      # that worker check stands. This also explains the one measurement that
      # looked like a counter-example — `test-post-review-self-review-handoff.sh`
      # P15 begins a run under a foreign owner key and this gate reports an own
      # run for it. It does not, and state that case the way the fixture's own
      # contract states it rather than the way an earlier wording here guessed:
      # the owner-scoped read is BLIND to a foreign run, so the owner-keyed
      # pointer is simply absent and the read answers rc 1. Nothing on this arm
      # sees it at all; the owner-INDEPENDENT workspace-holder read below is what
      # refuses, with the shared sentence that names no owner.
      # The terminal pair MIRRORS `TERMINAL` in `hooks/lib/zensu-autopilot-state.sh`
      # and deliberately NOT its `STOP_TERMINAL` sibling, which also holds
      # `BLOCKED`: a blocked run must still refuse an unbound claim, because the
      # generation exists and has not been released. What the mirror must never do
      # is call such a run LIVE — it is not — so the stage travels back and the
      # cause names what was actually observed. The record is session-writable, so
      # only a member of the CLOSED stage set below is echoed; anything else makes
      # the probe emit the empty string and the shell default renders the cause as
      # `unreported`, rather than putting untrusted bytes in front of the model.
      # PIPED, never exported: stateValid accepts up to 512 events and the record
      # is pretty-printed, so a long ledger passes a single environment string on
      # Linux and the whole environment block under the Windows process creation
      # Git Bash uses. An E2BIG spawn failure would land in the catch-all arm and
      # blame the record for not parsing. hooks/lib/zensu-autopilot-state.sh states
      # the rule and hooks/stop-chain-enforcer.sh pipes the same payload.
      OUTER_STAGE="$(printf '%s' "$PREFLIGHT_OUTER" | node -e '
      let raw;
      try { raw = require("fs").readFileSync(0, "utf8"); } catch (_) { process.exit(4); }
      try {
        const s=JSON.parse(raw);
        const stage = typeof s.stage === "string" ? s.stage : "";
        // Membership in the CLOSED set the state library declares, never a bare
        // shape rule: the record is session-writable, and hooks/lib/zensu-autopilot-state.sh
        // rejects a shape rule for exactly this reason where it renders a stage.
        const RENDERABLE = ["PLANNING","AWAIT_TDD","TDD_RUNNING","GATES","TEAM_REVIEW",
          "CONVERGE","FIX_FINDINGS","VALIDATE","COVER","DELIVER","OPEN_PR","BLOCKED","DONE","CANCELLED"];
        process.stdout.write(RENDERABLE.includes(stage) ? stage : "");
        // NOT process.exit(): the write above goes to a command-substitution
        // pipe and may still be queued, and exit() discards it — which would
        // drop the stage and render the cause as "observed: unreported" while
        // the exit code still arrived. Set the code and let node drain, the
        // rule hooks/plan-approved-delegate.sh states for the same seam.
        process.exitCode = ["DONE", "CANCELLED"].includes(s.stage) ? 0 : 1;
      } catch (_) { process.exit(2); }
      ' 2>/dev/null)"
      case "$?" in
        0) ;;
        1) decline "this session's own durable Autopilot run has not reached a terminal stage (observed: ${OUTER_STAGE:-unreported}), so a standalone claim cannot be recorded against it" runstate ;;
        4) decline "this session's own durable Autopilot run record could not be read from the pipe, so a standalone claim cannot be judged against it" runstate ;;
        # This arm is the payload not PARSING, or node itself not running — a missing
        # interpreter exits 127 and lands here too, so the wording stays broad. The record
        # travels over stdin rather than the environment, so a read fault is a real
        # second cause — it exits 4 and gets its own arm rather than being folded in
        # here, because a fault must never be reported as a judged payload. That is
        # a different fault from the read failing, which the exit-4 arm above names
        # in its own words: the two once shared one sentence, so the ledger could
        # not tell them apart and neither could anyone reading a chain that
        # stranded here. This arm has no executed fixture:
        # `autopilot_read_active` emits JSON or fails, so a successful read that
        # will not parse is unreachable from a test, which is why the pin for
        # this distinction is a source pin (P13f).
        *) decline "this session's own durable Autopilot run record did not parse, so a standalone claim cannot be judged against it" runstate ;;
      esac
      ;;
    1) ;;
    *) decline "a durable Autopilot run record in this project could not be read, so a standalone claim cannot be judged against it" runstate-foreign ;;
  esac
  # And: is anyone ELSE holding the working tree right now? Arming happens once,
  # at `tdd_begin_session`; this hook runs on every qualifying PostToolUse. A
  # durable run begun in this tree AFTER the chain armed is therefore refused by
  # the arm-time gate no longer, and by the owner-scoped read above never — a
  # window this preflight covered project-wide before it was narrowed. The
  # question is owner-independent, so it needs the owner-independent read.
  # rc 0 is a refusal exactly as the arm-time gate treats it, and anything that
  # is not a clean "free" fails closed.
  # rc 0 is the one FOREIGN-state answer in this file. It used to stay SILENT so
  # that the message's mere presence could not answer "is another session's run
  # holding this tree?" — the existence-oracle property
  # `test-plan-payload-fallback.sh` F20/F32/F45c pin for the sibling plan gate.
  # Silence reproduced the exact strand this hook exists to end, and once every
  # other pre-claim arm disclosed, the ABSENCE of a message became the oracle
  # answer instead. So it now discloses with the SAME sentence the read-failure
  # arm below uses: presence answers nothing a failed read would not, the strand
  # ends, and the remedy is the unattributable one — no owner-scoped status
  # verb, no instruction to touch the shared state directory. P15 holds the two
  # sentences in lockstep by exact count. A read that FAILED discloses too, and
  # the reason is the STRAND, never a claim that the failure reveals nothing
  # about other sessions, which an earlier wording here made and which is false:
  # this read is owner-INDEPENDENT and fails on any record in the shared state
  # directory that will not validate, so a foreign record IS observable through
  # it. That residual is accepted rather than argued away — silence here leaves
  # the chain holding an unclaimed ticket with nothing on the model channel,
  # which is the exact failure this seam exists to end, and the remedy it
  # selects is the unattributable one for the same reason.
  if autopilot_read_workspace "$PROJECT_ROOT" >/dev/null 2>&1; then
    decline "whether a durable Autopilot run holds this working tree could not be judged, so a standalone claim cannot be recorded against it" runstate-foreign
  else
    PREFLIGHT_WORKSPACE_RC=$?
    [ "$PREFLIGHT_WORKSPACE_RC" -eq 1 ] \
      || decline "whether a durable Autopilot run holds this working tree could not be judged, so a standalone claim cannot be recorded against it" runstate-foreign
  fi
elif [ "$PROMPT_AUTOPILOT_KIND" = bound ]; then
  # There is deliberately NO guard here on `PREFLIGHT_CONTEXT` being the empty
  # object. `EXPECT_BOUND` is derived from exactly that comparison one gate
  # above, and the classifier emits kind `bound` only when `EXPECT_BOUND` is
  # `yes`, so reaching this branch already proves the context is non-empty. One
  # stood here and could never be false; the cost was not the dead code but that
  # two operator accounts enumerated its decline as a live diagnosis, so the
  # contract advertised a refusal nothing could produce. Do not reintroduce it —
  # if this ever has to be decidable, make the classifier decide it.
  AUTOPILOT_CTX="$PREFLIGHT_CONTEXT" RUN_ID="$PROMPT_AUTOPILOT_RUN" \
    ATTEMPT="$PROMPT_AUTOPILOT_ATTEMPT" CHAIN_ID="$PROMPT_AUTOPILOT_CHAIN" \
    RETURN_STAGE="$PROMPT_AUTOPILOT_STAGE" node -e '
      try {
        const c=JSON.parse(process.env.AUTOPILOT_CTX);
        const exact=c.active===true && c.implComplete===true && c.chainDone===false
          && c.runId===process.env.RUN_ID && String(c.attempt)===process.env.ATTEMPT
          && c.chainId===process.env.CHAIN_ID && c.returnStage===process.env.RETURN_STAGE
          && c.outcome==="";
        process.exit(exact?0:3);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null \
    || decline "the Autopilot envelope in the prompt disagrees with this chain's own record — re-derive run, attempt, chain and stage from --chain-status, which reports what this chain is bound to" envelope-record
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
  # `autopilot_read_active` is OWNER-SCOPED, so rc 1 names the caller's OWN durable
  # run record — not another session's — and discloses as an own-artifact decline.
  # Every OTHER status does NOT establish that: `readRunInventory` fails closed on
  # an UNATTRIBUTABLE record, so a co-tenant's corrupt file in the shared state
  # directory reaches this arm, which is why it names no owner and passes the
  # owner-independent mode. The one SILENT class in this hook is the ticket claim
  # and every exit below it; the workspace read is not it — both of its arms
  # decline, with one identical sentence.
  if PREFLIGHT_OUTER="$(autopilot_read_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)"; then
    :
  else
    # rc 1 is "no active run", not a fault. State what it PROVES and no more: the
    # worker reaches it only at `fail(1, "state file absent: <pointer>")`, so the
    # owner-keyed pointer FILE is absent — and that is not the same as the run
    # having been released or completed, because `autopilot_release_run` leaves
    # the owner pointer in place and a released run therefore answers rc 0 with a
    # terminal record instead. That second state is split off at the comparison
    # below rather than reported here. Reporting rc 1 as unreadable sent the model
    # to repair a record that is simply absent — the same conflation the
    # standalone branch above no longer makes.
    case "$?" in
      1) decline "this session's owner-keyed Autopilot pointer is absent, so no durable run is designated for the bound claim to be judged against — that proves the pointer is gone, not that the run was released or completed" run-gone ;;
      *) decline "a durable Autopilot run record in this project could not be read, so the bound claim cannot be judged against it" runstate-foreign ;;
    esac
  fi
  # The record is PIPED for the reason stated at the stage probe above; the small
  # scalars stay in the environment, where no size bound is in play.
  printf '%s' "$PREFLIGHT_OUTER" | SID="$SESSION_ID" RUN_ID="$PROMPT_AUTOPILOT_RUN" \
    ATTEMPT="$PROMPT_AUTOPILOT_ATTEMPT" CHAIN_ID="$PROMPT_AUTOPILOT_CHAIN" \
    RETURN_STAGE="$PROMPT_AUTOPILOT_STAGE" node -e '
      let raw;
      try { raw = require("fs").readFileSync(0, "utf8"); } catch (_) { process.exit(4); }
      try {
        const s=JSON.parse(raw),t=s.tdd;
        // A run this prompt legitimately names, already at a terminal stage, is
        // NOT a binding disagreement, and reporting it as one was a real
        // misdiagnosis. autopilot_release_run leaves the owner pointer in place,
        // so a released or completed run reaches this probe at rc 0 and fails
        // only the TDD_RUNNING conjunct below — which the catch-all then rendered
        // as a prompt whose binding disagrees with the run, sending the model to
        // resolve a run state that is already resolved. The terminal pair MIRRORS
        // TERMINAL in hooks/lib/zensu-autopilot-state.sh and deliberately not its
        // STOP_TERMINAL sibling, exactly as the standalone stage probe above
        // does; S24 holds every copy in this file against that owner.
        if (s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
          && ["DONE", "CANCELLED"].includes(s.stage)) process.exit(5);
        const exact=s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
          && s.stage==="TDD_RUNNING" && s.nextActionCode==="AWAIT_TDD_CHAIN" && t
          && t.sessionId===process.env.SID && String(t.attempt)===process.env.ATTEMPT
          && t.chainId===process.env.CHAIN_ID && t.returnStage===process.env.RETURN_STAGE
          && t.outcome===null;
        process.exit(exact?0:3);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null
  # A READ fault is not a disagreement. The record travels over stdin here too, so
  # exit 4 is split off and declines in its own words rather than telling the model
  # its binding conflicts with a record nothing managed to read — the same rule the
  # stage probe above states, applied to the second pipe.
  case "$?" in
    0) ;;
    4) decline "this session's own durable Autopilot run record could not be read from the pipe, so the prompt's Autopilot binding cannot be compared against it" runstate ;;
    5) decline "the durable Autopilot run this prompt names is this session's own and has already reached a terminal stage, so there is no live run for the bound claim to be recorded against" run-gone ;;
    *) decline "the prompt's Autopilot binding disagrees with this session's own durable run — resolve the run state first, because the gate above has already pinned the envelope to this chain's own record" runstate ;;
  esac
else
  exit 0
fi

# Claim the one-shot ticket, increment its round, and capture the exact
# fully-validated Autopilot binding from the same locked state read. There is no
# post-claim linkage reread: partial linkage fails before state/counter mutation,
# while a concurrent generation reset makes every later bound CAS stale.
CLAIM_CONTEXT="$(tdd_consume_review_ticket_context \
  "$SESSION_ID" "$REVIEW_TICKET")" || exit 0
# The claim landed, so this round is recorded and the ticket is spent: a decline
# note minted for THIS session before it is stale evidence by construction, and
# a durable surface that keeps reporting a strand the chain has left is the same
# defect in the other direction. Retired here rather than at a Stop, because the
# Stop hook never learns that a completion claimed. A post-claim decline below
# mints its own note again, under the `spent` mode, which is a different and
# still-current finding. `declare -F` for the isolation reason the mint states.
if declare -F decline_note_clear >/dev/null 2>&1; then decline_note_clear; fi
CLAIM_FIELDS="$(CLAIM_CONTEXT="$CLAIM_CONTEXT" node -e '
  try {
    const value = JSON.parse(process.env.CLAIM_CONTEXT);
    const topKeys = Object.keys(value).sort().join(",");
    if (topKeys !== "autopilot,next" || !Number.isSafeInteger(value.next) || value.next < 1) {
      process.exit(3);
    }
    // NOT process.exit() on the standalone arm: the write goes to a command
    // substitution pipe and may still be queued, and exit() discards it — the
    // rule this file states above the stage probe and hooks/plan-approved-delegate.sh
    // states for the same seam. The ticket is already consumed by this point, so a
    // dropped write costs the round its directive with no way to reissue. Fall off
    // the end of the program instead and let node drain.
    if (value.autopilot === null) {
      process.stdout.write([value.next, "standalone", "-", 0, "-", "-"].join("\t"));
    } else {
      const binding = value.autopilot;
      const bindingKeys = binding && typeof binding === "object" && !Array.isArray(binding)
        ? Object.keys(binding).sort().join(",") : "";
      const linkId = candidate => typeof candidate === "string"
        && candidate.length > 0 && candidate.length <= 128
        && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(candidate);
      const valid = bindingKeys === "attempt,chainId,outcome,returnStage,runId"
        && linkId(binding.runId)
        && Number.isInteger(binding.attempt) && binding.attempt >= 1 && binding.attempt <= 999
        && ["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]
          .includes(binding.returnStage)
        && linkId(binding.chainId)
        && binding.outcome === "";
      if (!valid) process.exit(3);
      process.stdout.write([
        value.next, "bound", binding.runId, binding.attempt, binding.returnStage, binding.chainId
      ].join("\t"));
    }
  } catch (_) { process.exit(3); }
' 2>/dev/null)" || decline "the claim was consumed but its binding context did not read back as a parseable standalone or bound linkage" spent
IFS=$'\t' read -r NEXT AUTOPILOT_KIND AUTOPILOT_RUN AUTOPILOT_ATTEMPT \
  AUTOPILOT_RETURN_STAGE AUTOPILOT_CHAIN <<<"$CLAIM_FIELDS"
case "$NEXT" in ''|*[!0-9]*) decline "the claimed round counter did not read back as a positive integer, so the round cannot be validated" spent ;; esac

AUTOPILOT_BOUND=false
AUTOPILOT_BOUND_ARGS=""
AUTOPILOT_ENVELOPE_DIRECTIVE=""
AUTOPILOT_CARRY_PHRASE=""
AUTOPILOT_RESPAWN_PHRASE=""
if [ "$AUTOPILOT_KIND" = bound ]; then
  [ "$PROMPT_AUTOPILOT_KIND" = bound ] \
    && [ "$AUTOPILOT_RUN" = "$PROMPT_AUTOPILOT_RUN" ] \
    && [ "$AUTOPILOT_ATTEMPT" = "$PROMPT_AUTOPILOT_ATTEMPT" ] \
    && [ "$AUTOPILOT_RETURN_STAGE" = "$PROMPT_AUTOPILOT_STAGE" ] \
    && [ "$AUTOPILOT_CHAIN" = "$PROMPT_AUTOPILOT_CHAIN" ] || decline "after the claim, the bound Autopilot envelope no longer matched this chain's own record" spent
  AUTOPILOT_BOUND=true
  AUTOPILOT_RUN_Q="$(printf '%q' "$AUTOPILOT_RUN")"
  AUTOPILOT_ATTEMPT_Q="$(printf '%q' "$AUTOPILOT_ATTEMPT")"
  AUTOPILOT_CHAIN_Q="$(printf '%q' "$AUTOPILOT_CHAIN")"
  # The SECOND shell rendering of the Autopilot flag triple. The first is
  # `zensu_autopilot_link_args` in `hooks/stop-chain-enforcer.sh`, which was parameterized
  # so this site could consume it once it moves into `hooks/lib/`. Named here rather than
  # only there, because the trigger recorded at that function is "the next change that
  # touches the delegate's own bound-args line" — a trigger nobody reads at the site that
  # fires it is not a trigger. It has NOT fired: the ticket-keyed rewrite left the line
  # below byte-identical, so the copy stands and the move is still owed. Do not upgrade
  # that to "this change took it". Do not diverge the quoting or the flag order.
  AUTOPILOT_BOUND_ARGS=" --autopilot-run ${AUTOPILOT_RUN_Q} --autopilot-attempt ${AUTOPILOT_ATTEMPT_Q} --chain-id ${AUTOPILOT_CHAIN_Q}"
  AUTOPILOT_ENVELOPE_DIRECTIVE=$'\n\nOfficial Autopilot handoff envelope — append these three lines unchanged and exactly once after the required headers of every reviewer respawn and self-review invocation:\n'"ZENSU-DELEGATED-CALLER: autopilot"$'\n'"AUTOPILOT-BINDING: run=${AUTOPILOT_RUN} attempt=${AUTOPILOT_ATTEMPT} chain=${AUTOPILOT_CHAIN}"$'\n'"AUTOPILOT-STAGE: ${AUTOPILOT_RETURN_STAGE}"
  AUTOPILOT_CARRY_PHRASE=" Preserve the official three-line Autopilot envelope printed below unchanged and exactly once in the self-review invocation."
  AUTOPILOT_RESPAWN_PHRASE=" For every verification respawn, append the official three-line Autopilot envelope printed below unchanged and exactly once after REVIEW-TICKET."
elif [ "$AUTOPILOT_KIND" != standalone ]; then
  decline "the claimed binding kind was neither a valid bound envelope nor a standalone chain" spent
elif [ "$PROMPT_AUTOPILOT_KIND" != standalone ]; then
  decline "the prompt's binding kind disagreed with this chain's own standalone record after the claim" spent
fi

if [ "$(tdd_vanilla_mode "$TDD_STATE_FILE")" = "true" ]; then
  FIX_DISCIPLINE_ALL="in vanilla mode by re-entering the /zensu:tdd workflow's vanilla implementation loop (fix each finding directly — no RED→GREEN cycle required, tests at your discretion; keep the structured CHECKPOINT/AUDIT evidence discipline; the phase-gate passes through in this session)"
  FIX_DISCIPLINE_CI="$FIX_DISCIPLINE_ALL"
  FIX_DONE_PHRASE="After the fixes are applied and verified"
else
  FIX_DISCIPLINE_ALL="under strict TDD discipline by re-entering the /zensu:tdd workflow (for each finding: write or adjust a RED test, then IMPL, then GREEN; the PreToolUse phase-gate is still active in this session)"
  FIX_DISCIPLINE_CI="under strict TDD discipline by re-entering the /zensu:tdd workflow (for each finding: RED test, then IMPL, then GREEN; the PreToolUse phase-gate is still active in this session)"
  FIX_DONE_PHRASE="After the fixes are GREEN"
fi

MAX_ROUNDS="$(zensu_autofix_max_rounds)"

BYPASS_RC=0
BYPASSES="$(zensu_bypass_display "$(tdd_state_file "$SESSION_ID")" text)" || BYPASS_RC=$?
[ "$BYPASS_RC" -eq 0 ] && [ -z "$BYPASSES" ] && BYPASSES="none"
BYPASS_DIRECTIVE=$'\n\nBypass ledger (from chain state): as the last line of the ## Open section, include the literal line: Gates bypassed during this session: '"$BYPASSES"
BYPASS_DIRECTIVE_TRAILING=$'\n\nBypass ledger (from chain state): end your reply with the literal line: Gates bypassed during this session: '"$BYPASSES"

CONVERGE_OFFER_DIRECTIVE=""
if [ "$AUTOPILOT_BOUND" != "true" ]; then
  CONVERGE_OFFER_DIRECTIVE=$'\nThen, for a STANDALONE chain only and never for an Autopilot-bound one, when the session plan carries a ## Requirements table, close ## Open with ONE more line, exactly this and nothing else: `Optional next step: /zensu:converge — flow-back audit of the code against the plan\'s Requirements table.` It is an offer only — never run it unasked — and it never gates, delays, or precedes the chain terminus. Render it only in the turn that closes the chain, never in a fix round that will be re-reviewed.'
fi

COMBINED_SUMMARY_DIRECTIVE=""
if zensu_combined_summary_enabled; then
  COMBINED_SUMMARY_DIRECTIVE=$'\n\nAfter your status line, produce a CHAIN-END SUMMARY. Render it as TABLES, not prose: every section below is a table plus at most one line of text, never a paragraph — the sole exception is ## Open, which ends with the bypass-ledger line and, when it applies, the converge offer. Keep it scannable — no restating, no narration of the process, no filler. Sections IN THIS ORDER, TL;DR LAST. Mark every status and verdict cell with a leading marker: 🟢 good (passed, clean, done, met), 🟡 attention (partial, advisory, skipped, not measured), 🔴 bad (failed, must-fix, dropped, contradicted, blocked, not landed, unverified, unresolved predicate, evidence gap, evidence contradiction, cross-check unavailable, verification degraded, a gate bypassed), ⚪ not applicable — admissible ONLY where the source of the value itself says the item does not apply, which today means exactly one case: a requirement row the plan already marks deprecated. An outcome that was merely not run is 🟡, never ⚪. The marker PREFIXES the cell value and NEVER replaces it: every verbatim literal keeps its own words unchanged after its marker, subject only to the pipe-escaping rule below, which the renderer undoes so the reader still sees the original text. A marker never stands alone and is never separated from the words it marks by a line break. The ## Open table has no status or verdict column and takes no marker. Pull data from your own main-thread TDD execution and the prior zensu:code-reviewer Agent results in your context, do NOT re-spawn agents.\n\n## Problem\nExactly ONE sentence: the feature, bug, or need this session addressed.\n\n## What I built\nTable, columns: # | Deliverable | Status | Link. One row per deliverable, max 15 words per cell, Status is 🟢 done / 🟢 merged / 🟢 built-tested / 🔴 blocked, Link is a PR URL or an em dash.\nThen a second table, columns: Check | Verdict, with exactly these rows — Feature, Files modified, Tests created, Build, Coverage, Edit landing, Mtime audit, Finding verification, Gates bypassed, Plan, Log. Verdict cells are values, not sentences (passed, skipped, 12 files, a path). Mark a cell when its value is a STATE; leave it unmarked when the value is a title, a path, or a bare count with no target — that is Feature, Files modified, Plan and Log, and every other row above is marked. A count measured AGAINST a target IS a state, so {N}/{M} GREEN and {N}/{M} files >= {threshold} take 🟢 when the target was met, 🔴 when it was not, 🟡 when the run was skipped. Gates bypassed takes 🟢 ONLY for the literal none read from a valid document and 🔴 for anything else, including a named escape, the UNREADABLE — ... form and any wording this renderer does not recognize; it repeats the ## Open bypass-ledger line rather than replacing it. Finding verification carries the FINDING VERIFICATION — {n} verified, ... line and any FINDING VERIFICATION DEGRADED — <reason> line verbatim, 🔴 when a DEGRADED line is present or the unsupported or phantom count is non-zero (an off-changeset finding is not by itself a defect), 🟡 not run (hooks.findingVerification disabled) when the gate was skipped and emitted no line at all, and 🟢 only when the gate RAN and neither condition holds — never ⚪. The Edit landing verdict carries the step 5b close marker plus any EDIT NOT LANDED line, and the UNVERIFIED (no claims logged) or unresolved PENDING PREDICATE close when either applies, VERBATIM in its cell — those are not clean states and must never be dropped, paraphrased, or shortened, and both take 🔴, never 🟡. Every verbatim cell follows the pipe-escaping rule, applied in this order: first write every backslash as two backslashes, then every pipe as a backslash-pipe. An unescaped pipe splits the row and the renderer drops the cells past the last column, which is exactly the verdict clause the row exists to surface.\nWhen the session plan carries a ## Requirements table, add a third table, columns: ID | Status, keyed by its stable IDs (AC-###/FR-###: 🟢 met / 🟡 partial / 🔴 contradicted / 🔴 dropped / ⚪ deprecated). ⚪ is bound to PROVENANCE, never to judgement: use it only when that requirement row in the plan already carries that status. A requirement this session did not implement is 🔴 dropped even if it was retired mid-session. One row per requirement, no commentary. When the plan carries NO ## Requirements table, omit the table and write the single line `🟡 Requirements: no ## Requirements table in the session plan — per-requirement status not tracked`, so an untracked chain never reads like a fully met one.\n\n## How I built it\nExactly ONE line: the TDD discipline followed, the final zensu:code-reviewer verdict (PASS / PASS with suggestions / max-rounds reached), the findings count by severity, and the number of files reviewed.\nThen a table, columns: Round | Findings | Fixed | Result. One row per review round 1..N including rounds that fixed nothing; a round with ZERO findings reads 🟢 PASS — 0 findings, nothing to fix, and a round that had findings never claims that literal. Mark each Result 🟢 for a clean round AND for an ordinary round whose findings were all fixed and re-verified, 🟡 for a max-rounds convergence that left findings open AND for a round whose findings were deliberately deferred as suggestions rather than fixed, 🔴 for a round whose fixes did not land. Always include the final clean verification round. At least one review round always ran.\n\n## Open\nTable, columns: Item | Type | Next step. One row per deferred suggestion (the buffered ### Suggestions block) or max-rounds finding requiring a manual fix. Every cell follows the same pipe-escaping rule as the verdict cells above, applied in this order: first write every backslash as two backslashes, then every pipe as a backslash-pipe. If nothing is open, write the single line: Nothing open.'"${CONVERGE_OFFER_DIRECTIVE}"$'\n\n## TL;DR\nExactly ONE sentence, and it MUST be the last section: what shipped and the test verdict.'
fi

# When the self-review terminal stage is enabled, the code-reviewer chain hands
# off to /zensu:self-review (a main-thread Skill) instead of closing here:
# self-review owns the chain terminus (--chain-done) and renders the report.
SELF_REVIEW_ON=0
if zensu_hook_enabled selfReview; then SELF_REVIEW_ON=1; fi
BYPASS_TAIL_DIRECTIVE="$BYPASS_DIRECTIVE_TRAILING"
[ -n "$COMBINED_SUMMARY_DIRECTIVE" ] && BYPASS_TAIL_DIRECTIVE="$BYPASS_DIRECTIVE"
REVIEW_TICKET_Q="$(printf '%q' "$REVIEW_TICKET")"

if [ "$SELF_REVIEW_ON" = "1" ]; then
  CLOSE_PASS="FIRST, when ANY file changed since the last \`| scope: full\` AUDIT line, re-run the FULL test suite over the current tree in the FOREGROUND and log a fresh \`AUDIT — cmd=\"...\" exit=<rc> result=\"...\" | scope: full\` line: Phase 5 checkpoints are SCOPED, so this convergence branch is where the verdict for the tree that ships is measured, and a verdict taken before the fix rounds describes a tree that no longer exists. THEN run this ticket-bound command: ${LOG_COMMAND} --code-review-done --claimed-review-ticket ${REVIEW_TICKET_Q}. Only if it exits 0, your VERY NEXT action must be the Skill tool with skill='zensu:self-review'. Carry this exact generation line into that skill: 'SELF-REVIEW-TICKET: ${REVIEW_TICKET}'.${AUTOPILOT_CARRY_PHRASE} The terminal self-review owns the chain terminus and renders the final CHAIN-END SUMMARY. If the command fails, this completion is stale: do NOT invoke self-review, do NOT mutate chain state, and resume the current chain instead. Do NOT close the chain yourself, do NOT render the summary here, and do NOT end your turn — self-review finalizes the matching generation."
  TAIL_DIRECTIVE=""
else
  CLOSE_PASS="FIRST, when ANY file changed since the last \`| scope: full\` AUDIT line, re-run the FULL test suite over the current tree in the FOREGROUND and log a fresh \`AUDIT — cmd=\"...\" exit=<rc> result=\"...\" | scope: full\` line: Phase 5 checkpoints are SCOPED and NO self-review stage follows in this configuration, so this is the last chance to measure the tree that ships. THEN close only this review generation by running: ${LOG_COMMAND} --chain-done${AUTOPILOT_BOUND_ARGS} --claimed-review-ticket ${REVIEW_TICKET_Q}. Stop only if it exits 0; on failure this completion is stale, so leave the current chain untouched and resume it."
  TAIL_DIRECTIVE="${COMBINED_SUMMARY_DIRECTIVE}${BYPASS_TAIL_DIRECTIVE}"
fi

# The ticket binds a completion by CONTENT, so a prompt that carried it anywhere
# is recorded — but the reviewer AGENT selects consume mode positionally, on the
# exact two header lines, and stays stricter than this hook. A slip therefore
# costs the merged fan-out rather than the round: the agent re-reviews from
# scratch, the round counts, and the findings the panel merged are thrown away
# with nothing said. The notice is a PREFIX on every routed directive variant
# below, so no accept path can emit without it; with the exact header it is
# empty and every variant renders byte-identically. It says LIKELY, because this
# hook observes the prompt and never the agent mode, and it never echoes the
# ticket value.
CONSUME_SHAPE_NOTICE=""
if [ "$PROMPT_CONSUME_HEADER" != "yes" ]; then
  CONSUME_SHAPE_NOTICE="Consume-header slip on the completion above: its prompt carried this chain's ticket, so the round IS recorded, but the prompt did not open with the two required consume-header lines. The reviewer agent enters consume mode only on that exact pair, so it most likely did not enter consume mode and re-reviewed from scratch — the merged fan-out for this round was discarded. If this chain spawns another reviewer at all — the directive below decides that, and not every variant this notice can prefix permits one — put both header lines FIRST, in this order: line 1 exactly 'PRE-MERGED FINDINGS (fan-out)', line 2 exactly 'REVIEW-TICKET: <the freshly minted ticket>', and only then the rest of the prompt. "
fi

if [ "$AUTO_FIX_ON" = "0" ]; then
  DISABLED_MSG="Auto-fix is disabled for this ticket-bound review completion. Do NOT modify findings automatically and do NOT spawn another reviewer loop. Report the reviewer verdict and all findings unchanged, then ${CLOSE_PASS}"
  DISABLED_TAIL=""
  [ "$SELF_REVIEW_ON" = "0" ] && DISABLED_TAIL="${BYPASS_DIRECTIVE_TRAILING}"
  printf '%s' "${CONSUME_SHAPE_NOTICE}${DISABLED_MSG}${DISABLED_TAIL}${AUTOPILOT_ENVELOPE_DIRECTIVE}" | emit_post_context
  exit 0
fi

if [ "$NEXT" -gt "$MAX_ROUNDS" ]; then
  # Max rounds reached. With self-review enabled the chain does NOT terminate
  # here: mark the code-reviewer chain converged (codeReviewDone) and hand off to
  # the terminal self-review stage, which owns --chain-done. With self-review
  # disabled, terminate as before (chainDone) so the Stop-hook backstop releases.
  if [ "$SELF_REVIEW_ON" = "1" ]; then
    # Bound chains land the durable outcome and handoff flag in one exact CAS.
    # Standalone chains keep the ticket-bound convergence flag transition.
    if [ "$AUTOPILOT_BOUND" = "true" ]; then
      tdd_mark_autopilot_max_round_handoff "$SESSION_ID" "$AUTOPILOT_RUN" \
        "$AUTOPILOT_ATTEMPT" "$AUTOPILOT_RETURN_STAGE" "$AUTOPILOT_CHAIN" \
        "$REVIEW_TICKET" || decline "the max-rounds handoff CAS did not land, so the converged reviewer round could not be recorded" spent
    else
      tdd_mark_review_converged "$SESSION_ID" "$REVIEW_TICKET" codeReviewDone || decline "the codeReviewDone convergence CAS did not land, so the reviewer round could not be marked converged" spent
    fi
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The code-reviewer chain is marked converged (codeReviewDone). Do NOT spawn zensu:code-reviewer again and do NOT keep fixing its findings. Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — the terminal self-review stage. Carry this exact generation line into it: 'SELF-REVIEW-TICKET: ${REVIEW_TICKET}'.${AUTOPILOT_CARRY_PHRASE} Carry the remaining reviewer findings forward under '### Findings (max rounds reached, manual fix required)' so they land in the final report. /zensu:self-review owns the ticket-bound chain terminus and renders the final summary — do NOT close the chain yourself. To grant another reviewer budget instead of finalizing, the user can invoke the /zensu:reset-review-limit skill."
  else
    if [ "$AUTOPILOT_BOUND" = "true" ]; then
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --session "$SESSION_ID" \
        --autopilot-run "$AUTOPILOT_RUN" --autopilot-attempt "$AUTOPILOT_ATTEMPT" \
        --chain-id "$AUTOPILOT_CHAIN" --claimed-review-ticket "$REVIEW_TICKET" \
        --outcome max-rounds >/dev/null 2>&1 || decline "the bound chain-done terminus did not land, so the max-rounds outcome could not be recorded" spent
    else
      tdd_mark_review_converged "$SESSION_ID" "$REVIEW_TICKET" chainDone || decline "the standalone chainDone terminus CAS did not land, so the review chain could not be closed" spent
    fi
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The review chain is now marked complete (chainDone) so you MAY end your turn. Do NOT spawn zensu:code-reviewer again and do NOT keep fixing. Reply with the remaining findings under '### Findings (max rounds reached, manual fix required)' and stop. To grant another budget and resume the review/fix cycle in this same session, the user can invoke the /zensu:reset-review-limit skill — surface this hint at the end of your reply so the user knows the escape hatch exists.${COMBINED_SUMMARY_DIRECTIVE}${BYPASS_TAIL_DIRECTIVE}"
  fi
  printf '%s' "${CONSUME_SHAPE_NOTICE}${CONV_MSG}${AUTOPILOT_ENVELOPE_DIRECTIVE}" | emit_post_context
  exit 0
fi

# Resolved ONCE, above the severity split, so the two hand-parallel arms cannot
# disagree about whether the sentence renders. Permissive read: for this key
# "enabled" means a sentence renders, so an unreadable config falling back to
# enabled restores the default rather than a capability. The trailing space lives
# inside the value, which keeps the spacing correct in both states.
#
# No probe gate here, unlike the Stop enforcer's resume site, and the asymmetry is
# deliberate rather than an omission: this hook returns above unless the completed
# subagent was the reviewer itself, so it only ever runs AFTER a reviewer call the host
# actually let through. A reviewer-spawn probe here could therefore only ever report a
# refusal from EARLIER in the session — stale by construction — and withholding on it
# would suppress the sentence for the rest of a chain that is demonstrably able to spawn.
# Residual, stated rather than glossed: this hook never reads `tool_response`, so it
# cannot distinguish a clean completion from one the host flagged as an error. That is
# the `errored` state the Stop gate withholds on, and whether a host fires PostToolUse
# for such a call is host behaviour this tree does not establish.
#
# The status line and the sentence travel together: emitting the withhold opener while
# the only text sanctioning that route is config-suppressed would leave an enumeration
# whose fourth member no case covers.
IN_SCOPE_CLAUSE=""
IN_SCOPE_EXCEPTION=""
WITHHOLD_STATUS_LINE=""
if zensu_hook_enabled reviewSpawnScopeSentence; then
  # The sentence sanctions "say so and let the user decide", and the next clause in both
  # arms says "do NOT end your turn first". The bound is the SAME one the Stop site
  # discloses, one turn later: taking the route and ending the turn leaves the chain active
  # with implementation complete and neither flag set, which is the state
  # `stop-chain-enforcer.sh` blocks on, so the report meets that hook's cap rather than
  # closing anything. Saying only "this hook does not fire again" would be true of this
  # hook and false about what the model actually meets. Without the reconciliation
  # a model reads a sanctioned route and a flat prohibition side by side, and the two ways
  # out are the two the sentence itself forbids: work around the restraint, or withhold
  # silently.
  IN_SCOPE_CLAUSE="${ZENSU_REVIEW_SPAWN_IN_SCOPE} "
  IN_SCOPE_EXCEPTION=" The one exception to that: if a session rule leads you to withhold the fan-out, say so instead of ending the turn silently — that is a report, not a terminus. State it once: nothing here closes the chain, and ending the turn hands you to the Stop guard, which is bounded but does not release on a report, so repeating it every turn only spends that bound."
  WITHHOLD_STATUS_LINE=" | 'Withholding the review fan-out — reporting to the user for a decision'"
fi

if zensu_autofix_include_suggestions; then
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_ALL}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nInclude EVERY finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering (two exceptions: items annotated '[Panel-FP-neutralized — do not fix]' are judged false positives and items annotated '[Unverified — do not fix]' failed the Finding Verification Gate — never fix either). ${FIX_DONE_PHRASE}, log this round's '{step_id} IMPL completed — files: {list}' claims and re-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them (a fix round is where a no-op mechanical replacement hides; carry any EDIT NOT LANDED line verbatim into your status line and into whatever end-of-chain summary this session renders), then re-run the /zensu:tdd review sequence to re-verify: re-fan-out the zensu:review-aspect agents (five perspectives, fewer when hooks.aspectActivation skips one) — when hooks.incrementalReviewRounds is enabled (the default) scope THIS round's packet changed_files to the round delta via hooks/lib/review-round-scope-v1.js and fall back to the whole diff on its status=empty or status=degraded, while the zensu:review-judge packet always keeps the full cumulative diff — re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, re-run the /zensu:tdd Phase 6 step 4c Finding Verification Gate over THIS round's merged list when hooks.findingVerification is enabled (never carry a prior round's verification verdicts forward), then issue a FRESH one-shot ticket by running: ${LOG_COMMAND} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'.${AUTOPILOT_RESPAWN_PHRASE} ${IN_SCOPE_CLAUSE}The Stop-hook backstop enforces this, so do NOT end your turn first.${IN_SCOPE_EXCEPTION} Do NOT reuse a prior ticket. Do NOT mark the chain done in case B. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing all findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A)${WITHHOLD_STATUS_LINE}.${TAIL_DIRECTIVE}"
else
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)' so they land in the final report, then ${CLOSE_PASS}\n\n(C) ANY Critical OR Important findings present — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_CI}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed; buffer them in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. ${FIX_DONE_PHRASE}, log this round's '{step_id} IMPL completed — files: {list}' claims and re-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them (a fix round is where a no-op mechanical replacement hides; carry any EDIT NOT LANDED line verbatim into your status line and into whatever end-of-chain summary this session renders), then re-run the /zensu:tdd review sequence to re-verify: re-fan-out the zensu:review-aspect agents (five perspectives, fewer when hooks.aspectActivation skips one) — when hooks.incrementalReviewRounds is enabled (the default) scope THIS round's packet changed_files to the round delta via hooks/lib/review-round-scope-v1.js and fall back to the whole diff on its status=empty or status=degraded, while the zensu:review-judge packet always keeps the full cumulative diff — re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, re-run the /zensu:tdd Phase 6 step 4c Finding Verification Gate over THIS round's merged list when hooks.findingVerification is enabled (never carry a prior round's verification verdicts forward), then issue a FRESH one-shot ticket by running: ${LOG_COMMAND} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'.${AUTOPILOT_RESPAWN_PHRASE} ${IN_SCOPE_CLAUSE}The Stop-hook backstop enforces this, so do NOT end your turn first.${IN_SCOPE_EXCEPTION} Do NOT reuse a prior ticket. Do NOT mark the chain done in case C. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing critical+important findings in-thread, then re-reviewing' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A)${WITHHOLD_STATUS_LINE}.${TAIL_DIRECTIVE}"
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"
EXPANDED_MSG="${EXPANDED_MSG}${AUTOPILOT_ENVELOPE_DIRECTIVE}"

printf '%s' "${CONSUME_SHAPE_NOTICE}${EXPANDED_MSG}" | emit_post_context
