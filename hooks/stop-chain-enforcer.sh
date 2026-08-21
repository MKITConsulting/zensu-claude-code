#!/bin/bash
# Hierarchical Stop backstop. The inner TDD review chain gets first routing
# priority; after it permits a stop, a durable outer Autopilot run may still
# block until it reaches DONE, BLOCKED, or CANCELLED.
set -u
DEFERRED_OWNER_PID="${BASHPID:-$$}"
case "$DEFERRED_OWNER_PID" in ''|*[!0-9]*) exit 2 ;; esac
[ "$DEFERRED_OWNER_PID" -gt 0 ] || exit 2

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
INPUT=""
IFS= read -r -d '' INPUT || true

# These responses deliberately have no dynamic fields. Once a trusted main
# Stop event has been authenticated, durable or inner state plus a missing
# workflow library must never be interpreted as successful completion.
emit_runtime_unavailable_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu Autopilot Stop denied: durable state exists but the durable state runtime is unavailable."}'
}

emit_inner_runtime_unavailable_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: project-local inner state exists but the required runtime is unavailable."}'
}

emit_session_runtime_missing_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu Stop denied: the Session Control library is missing from this plugin installation, so review-chain and Autopilot completion cannot be proven. Repair the Zensu plugin installation, then retry; /zensu:doctor reports plugin integrity."}'
}

emit_session_bind_failed_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu Stop denied: this Stop event cannot be bound to the immutable Session Control record of its session, so review-chain and Autopilot completion cannot be proven. Three bind failures are released before this point — a session with NO record at all, a record whose recorded project root no longer exists (a deleted or recycled worktree), and an intact record served by a declared-incompatible plugin lineage (adoptable via /zensu:adopt-session) — so this is none of them: most often a record exists here and disagrees about something else, such as a record minted against a different plugin installation, a runtime digest that drifted, or a root that still exists but no longer matches. Any release check can also simply fail to evaluate, in which case no record was consulted at all. The Session Control binder usually printed the exact cause on stderr; when it did, that line is authoritative. Do not guess between these states and do not treat this as completion: report the block and ask the user to read the stderr output. /zensu:doctor stays reachable in every bind failure and names the disagreement; where a record does disagree for any other reason, only a fresh Claude Code session helps."}'
}

emit_session_record_unusable_block() {
  printf '%s\n' '{"decision":"block","reason":"Zensu Stop denied: the immutable Session Control record of this session no longer resolves against its recorded project root, which still exists, so review-chain and Autopilot completion cannot be proven. Restore that path to exactly what was recorded (a symlinked, moved, or re-created root does not match), then retry."}'
}

zensu_stop_guard_opted_out() {
  local config_lib="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
  if [ "${ZENSU_CHAIN:-}" = "off" ]; then
    echo "zensu chain-enforcer: releasing Stop because ZENSU_CHAIN=off is set explicitly. With no bindable session the durable Autopilot guarantee could not be evaluated either — no completion was proven, only the guard was waived." >&2
    return 0
  fi
  if [ -r "$config_lib" ]; then
    # shellcheck disable=SC1090
    source "$config_lib"
    if ! zensu_hook_enabled chainEnforcer; then
      echo "zensu chain-enforcer: releasing Stop because hooks.chainEnforcer=false is configured. With no bindable session the durable Autopilot guarantee could not be evaluated either — no completion was proven, only the guard was waived." >&2
      return 0
    fi
  fi
  return 1
}

AGENT_CONTEXT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
# Without Node or the principal classifier, this hook cannot authenticate a
# top-level Stop event. Stay silent rather than risk deadlocking a child.
command -v node >/dev/null 2>&1 || exit 0
[ -r "$AGENT_CONTEXT_LIB" ] || exit 0
# shellcheck disable=SC1090
source "$AGENT_CONTEXT_LIB"
zensu_hook_is_main_principal "$INPUT" Stop || exit 0


SESSION_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if [ ! -r "$SESSION_LIB" ]; then
  if ! zensu_stop_guard_opted_out; then
    echo "zensu chain-enforcer: ${SESSION_LIB} is missing or unreadable, so this session cannot be bound. Repair the plugin installation; ZENSU_CHAIN=off or hooks.chainEnforcer=false releases this guard explicitly." >&2
    emit_session_runtime_missing_block
  fi
  exit 0
fi
# shellcheck disable=SC1090
source "$SESSION_LIB"
if ! zensu_bind_hook_session "$INPUT"; then
  # A session Session Control never registered has no workflow document, so
  # there is no review chain and no Autopilot run to enforce — nothing is being
  # waived. Blocking it would leave the user with tools (the PreToolUse gates
  # relax the same state) but no way to ever end a turn, which is worse than the
  # deadlock this release fixes. Every other bind failure still blocks: a record
  # that exists and disagrees may well own state whose completion is unproven.
  if zensu_session_unregistered "$INPUT"; then
    echo "zensu chain-enforcer: releasing Stop — Session Control has no record for this session, so no review-chain or Autopilot state exists to enforce and none was waived. A session resumed across a plugin update never mints one. This session is readable but not workable: the TDD phase gate denies every Edit/Write and subagents cannot run. Start a fresh Claude Code session without --continue/--resume, and run /zensu:doctor to confirm the cause." >&2
    exit 0
  fi
  # The second state with nothing left to enforce, reached from the opposite
  # direction: the record is intact and only the directory it recorded is gone
  # (a deleted or harness-recycled worktree). The workflow document lives at
  # <project_root>/.zensu/state/, so it is not reachable from this record — and
  # because the record is immutable, it never will be again. Blocking it
  # protected no invariant; it only left the session unable to end a turn, with
  # every tool including /zensu:doctor denied and no in-session escape.
  #
  # Deliberately says "not reachable", not "gone": a MOVED or renamed root, and
  # an unmounted volume, produce the same ENOENT while the state survives intact
  # and restorable. That is why the message below claims no completion was
  # proven rather than that nothing existed to prove — the honest phrasing the
  # opt-out releases above already use. It does mean the release can be induced
  # — rename the root, end the turn, rename it back — and that IS reachable from
  # inside a session: `mv` carries no write channel, so the source-write gate
  # does not stop it, while ZENSU_CHAIN is read from this hook's INHERITED
  # environment and a per-command prefix cannot reach it. The two are therefore
  # NOT equivalent capabilities, and the release is unledgerable by design: the
  # document a bypass entry would live in is the one that became unreachable.
  # Accepted anyway, because the alternative wedges every legitimately deleted
  # worktree forever with no in-session escape at all. An induced release is
  # consequently silent; giving it a detection surface — a sidecar beside the
  # immutable record, surfaced by /zensu:doctor — is a known open improvement.
  #
  # Bound to THIS cause alone. A root that still EXISTS but no longer matches
  # (symlinked, moved, re-created) is a different state and keeps blocking, as
  # does every other bind failure — the predicate refuses a record that
  # disagrees about anything else, so a second disagreement is never relaxed
  # alongside the first. stdout is captured here, never leaked.
  if ORPHANED_PROJECT_ROOT="$(zensu_session_orphaned_project_root "$INPUT")" \
    && [ -n "$ORPHANED_PROJECT_ROOT" ]; then
    echo "zensu chain-enforcer: releasing Stop — the project root recorded for this session (${ORPHANED_PROJECT_ROOT}) no longer exists, so its workflow document is not reachable from this record and no completion could ever be proven from it. No review-chain or Autopilot state was evaluated: no completion was proven, only an unprovable guard released. If that directory was moved rather than deleted, its state still exists there. Re-create exactly that directory to resume the recorded session, or start a new session for further work." >&2
    exit 0
  fi
  # The THIRD release, and the only one whose state SURVIVES. The record is
  # intact and the sole disagreement is a declared-incompatible executing
  # lineage, so the workflow document is still on disk and still readable — it is
  # only unreachable from HERE, because the binding that resolves the project
  # root is what failed. This hook therefore cannot evaluate the chain at all; it
  # was blocking purely because it could not prove completion, and blocking a
  # session whose Edit and Bash channels are already denied buys nothing. It only
  # loops: the model cannot act, cannot end its turn, and the remedy never
  # reaches the user.
  #
  # So the guarantee is DEFERRED, not waived. Adoption re-binds this session, the
  # same document becomes reachable again, and the very next Stop enforces it —
  # unlike the two releases above, where the state is gone for good. Say that
  # plainly and still claim no completion was proven, because none was.
  #
  # Inducibility, stated as plainly as the orphan release above states its own:
  # this fires when the EXECUTING plugin version changes, and a command that
  # updates the installed plugin is not gated by any hook on the Bash matcher —
  # pre-bash-zensu-gate.sh exits before its bind for anything that is not a
  # `zensu <noun> <verb>` form, and the source-write parser's channel detector
  # does not recognise it as a write. So an armed chain CAN be released this way
  # from inside a session, unledgered, exactly as renaming the project root
  # releases the orphan branch. Accepted for the same reason: the alternative
  # loops every legitimately upgraded session forever with no in-session escape.
  #
  # The version pair is captured for the message and never leaked to stdout.
  if INCOMPATIBLE_RUNTIME="$(zensu_session_incompatible_runtime "$INPUT")" \
    && [ -n "$INCOMPATIBLE_RUNTIME" ]; then
    RECORDED_VERSION="${INCOMPATIBLE_RUNTIME%%$'\t'*}"
    EXECUTING_VERSION="${INCOMPATIBLE_RUNTIME##*$'\t'}"
    # Same shape guard every sibling consumer applies. A manifest version is only
    # requireText-validated, and this pair is interpolated into a single stderr
    # line the transcript renders verbatim — a newline in it would split one
    # diagnostic into several that look like separate hook messages.
    if ! [[ "$RECORDED_VERSION" =~ $ZENSU_SAFE_VERSION_RE ]] \
      || ! [[ "$EXECUTING_VERSION" =~ $ZENSU_SAFE_VERSION_RE ]]; then
      RECORDED_VERSION="(unreadable)"
      EXECUTING_VERSION="(unreadable)"
    fi
    # The remedy is OFFERED, never promised: this predicate also matches a
    # DOWNGRADE, and adoption refuses that outright (`executing-runtime-older`).
    # Claiming the guarantee is merely deferred would be false there — a rolled
    # back session has no path back except re-installing the newer version.
    echo "zensu chain-enforcer: releasing Stop — this session's Session Control record is intact and the only disagreement is that the running installation declares an incompatible lineage (record minted by ${RECORDED_VERSION}, executing ${EXECUTING_VERSION}). The binding that resolves the project root is what failed, so no review-chain or Autopilot state could be read from here: no completion was proven, only an unprovable guard released. The workflow document itself SURVIVES and is unchanged. Run /zensu:adopt-session to find out whether this installation may take the record over; if it can, /zensu:adopt-session --confirm re-binds the session and the very next Stop enforces the chain again. If the executing version is OLDER than the recorded one, adoption refuses and re-installing the newer version is the only way back — the guard stays released until then. Blocking instead would loop a session whose Edit and Bash channels are already denied, so the remedy would never reach you." >&2
    exit 0
  fi
  if ! zensu_stop_guard_opted_out; then
    echo "zensu chain-enforcer: this Stop cannot be bound to the Session Control record of this session. Three bind failures are released before this point — a session with no record at all, a record whose recorded project root no longer exists, and a record that is intact but served by a declared-incompatible lineage — so this is none of them: most often a record exists here and disagrees about something else (a foreign plugin installation, a runtime digest that drifted, a root that still exists but no longer matches, a tampered or unreadable record), though any release check can also fail to evaluate, in which case no record was consulted. Read the session-control-v1 line above when there is one — it states the exact cause, and it is authoritative over any inference. The record is immutable, so no Stop can ever prove completion from a record that disagrees: start a new session for further work. /zensu:doctor stays reachable in every bind failure and names the disagreement. ZENSU_CHAIN=off or hooks.chainEnforcer=false releases this guard explicitly." >&2
    emit_session_bind_failed_block
  fi
  exit 0
fi

if ! PROJECT_ROOT="$(zensu_resolve_project_dir)"; then
  # Kept deliberately, though it is now only the residual race window: binding
  # validates that the recorded root exists, so the steady-state deleted-root
  # session is released above and never reaches here. What survives is the
  # narrow TOCTOU case — the directory existed while the bind ran and was gone
  # by the time resolution asked again. It releases for exactly the reason the
  # bind-time branch does, and removing it would turn that race into the wedge
  # this hook no longer has.
  if [ -n "${ZENSU_PROJECT_ROOT:-}" ] && [ ! -d "${ZENSU_PROJECT_ROOT}" ]; then
    echo "zensu chain-enforcer: releasing Stop — the immutable project root of this session (${ZENSU_PROJECT_ROOT}) no longer exists, so no review-chain or Autopilot state is reachable and no completion can ever be proven from it. Re-create exactly that directory to resume the recorded session, or start a new session for further work." >&2
    exit 0
  fi
  if ! zensu_stop_guard_opted_out; then
    echo "zensu chain-enforcer: the recorded project root ${ZENSU_PROJECT_ROOT:-(unset)} exists but does not match this immutable Session Control record — a symlinked, moved, or re-created root never matches. Restore the recorded path; ZENSU_CHAIN=off or hooks.chainEnforcer=false releases this guard explicitly." >&2
    emit_session_record_unusable_block
  fi
  exit 0
fi
ACTIVE_POINTER_HINT="$PROJECT_ROOT/.zensu/state/autopilot-active.json"
ACTIVE_POINTER_EXISTS=false
if [ -e "$ACTIVE_POINTER_HINT" ] || [ -L "$ACTIVE_POINTER_HINT" ]; then
  ACTIVE_POINTER_EXISTS=true
fi
AUTOPILOT_RUN_HINT_EXISTS=false
for _zensu_run_hint in "$PROJECT_ROOT/.zensu/state"/autopilot-run-*.json; do
  if [ -e "$_zensu_run_hint" ] || [ -L "$_zensu_run_hint" ]; then
    AUTOPILOT_RUN_HINT_EXISTS=true
    break
  fi
done
unset _zensu_run_hint
DURABLE_STATE_HINT_EXISTS=false
if [ "$ACTIVE_POINTER_EXISTS" = "true" ] || [ "$AUTOPILOT_RUN_HINT_EXISTS" = "true" ]; then
  DURABLE_STATE_HINT_EXISTS=true
fi
INNER_STATE_DIR_HINT="${TDD_STATE_DIR:-$PROJECT_ROOT/.zensu/state}"
INNER_STATE_EXISTS=false
for _zensu_inner_hint in "$INNER_STATE_DIR_HINT"/tdd-phase-*.json; do
  if [ -e "$_zensu_inner_hint" ] || [ -L "$_zensu_inner_hint" ]; then
    INNER_STATE_EXISTS=true
    break
  fi
done
unset _zensu_inner_hint

AUTOPILOT_STATE_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
CONFIG_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
TDD_PHASE_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
if [ ! -r "$SESSION_LIB" ] || [ ! -r "$CONFIG_LIB" ] || [ ! -r "$TDD_PHASE_LIB" ] \
    || [ ! -r "$AUTOPILOT_STATE_LIB" ]; then
  if [ "$DURABLE_STATE_HINT_EXISTS" = "true" ]; then emit_runtime_unavailable_block
  elif [ "$INNER_STATE_EXISTS" = "true" ]; then emit_inner_runtime_unavailable_block
  fi
  exit 0
fi

read_field() {
  printf '%s' "$INPUT" | FIELD="$1" node -e '
    try {
      const j=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
      const v=j[process.env.FIELD];
      process.stdout.write(typeof v==="string"?v:(typeof v==="boolean"?String(v):""));
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

SESSION_ID="$(read_field session_id)"
TRANSCRIPT_PATH="$(read_field transcript_path)"
source "$SESSION_LIB"
PROJECT_ROOT="$(zensu_resolve_project_dir)" || exit 0
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")" || exit 0
source "$CONFIG_LIB"
source "$TDD_PHASE_LIB"
STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# A reviewer spawn the HOST refused never executes, so no PreToolUse or
# PostToolUse hook can see it and this Stop would otherwise demand the same
# impossible action until the cap releases it. The refusal IS visible in the
# transcript the payload points at, as a tool_result keyed to the Agent call —
# a channel the model cannot author. Diagnostic only: any failure to establish a
# verdict leaves the existing routing exactly as it was.
REVIEWER_DENIAL_STATUS=""
REVIEWER_DENIAL_KIND=""
REVIEWER_DENIALS=0
# Set only by the branch that routes this Stop as a host refusal — see the mint
# guard at the end of the file. Declared here so `set -u` holds on every path.
REVIEWER_DENIAL_ROUTED=false
reviewer_spawn_denial_probe() {
  local lib probe
  [ -n "$REVIEWER_DENIAL_STATUS" ] && return 0
  REVIEWER_DENIAL_STATUS="none"
  REVIEWER_DENIAL_KIND=""
  REVIEWER_DENIALS=0
  lib="${CLAUDE_PLUGIN_ROOT}/hooks/lib/reviewer-spawn-denial-v1.js"
  [ -n "$TRANSCRIPT_PATH" ] || return 0
  [ -f "$lib" ] && [ ! -L "$lib" ] || return 0
  # The byte and line clamps inside the module bound the WORK, not the wall
  # clock, and O_NONBLOCK is a no-op for a regular file. The transcript path is
  # host-supplied and lives outside the project root, so it can sit on stalled or
  # network-backed storage while this runs on the Stop path with no deadline
  # above it. A kill degrades exactly like every other probe failure: the
  # existing `|| return 0` leaves the verdict `none` and routing untouched.
  # `timeout` is absent on base macOS and some Git Bash installs, hence the guard.
  if command -v timeout >/dev/null 2>&1; then
    probe="$(timeout 5 node "$lib" --transcript "$TRANSCRIPT_PATH" 2>/dev/null)" || return 0
  else
    probe="$(node "$lib" --transcript "$TRANSCRIPT_PATH" 2>/dev/null)" || return 0
  fi
  case "$probe" in
    'status=blocked '*) REVIEWER_DENIAL_STATUS="blocked" ;;
    'status=clear '*) REVIEWER_DENIAL_STATUS="clear" ;;
    # `status=errored` and `status=unreadable` deliberately fall through here:
    # neither is a verdict this hook may act on, so both leave `none`.
    *) return 0 ;;
  esac
  # The kind is read as a FIELD, not matched against a local copy of the marker
  # set. That set lives in the module and is re-encoded exactly once more below,
  # in the `case` arms that render cause and remedy; a third copy here bought
  # nothing. The value is only ever a `case` SELECTOR — it is never interpolated
  # into the reason string — and its unknown arm is already the safe one, so a
  # value this hook does not recognize degrades to "unclassified" rather than
  # reaching an operator-visible string. `reviewerDenialRows` vets it a second
  # time against the same module before rendering a row.
  # Reading it generically also makes a marker ADDED to the module take effect
  # here with no matching shell edit: the closed set silently degraded such a
  # kind to the empty string, and the doctor then rendered `unclassified` for a
  # refusal whose real name both sides already knew.
  # Position-independent, unlike the `denials` strip below, which requires its
  # own field to stay last: the leading-space anchor makes `kind=` exact wherever
  # it sits, and a kind in final position simply has no trailing field to cut.
  case "$probe" in
    *' kind='*)
      REVIEWER_DENIAL_KIND="${probe#* kind=}"
      REVIEWER_DENIAL_KIND="${REVIEWER_DENIAL_KIND%% *}"
      ;;
  esac
  # `denials` is the LAST field of the contract line, so this suffix strip is
  # exact and does not depend on the space-delimited globs above. It is what
  # bounds the one-further-attempt sanction in the block reason: without a count,
  # every blocked Stop re-licenses a retry and the reason becomes the naive loop
  # it forbids two sentences earlier.
  REVIEWER_DENIALS="${probe##* denials=}"
  case "$REVIEWER_DENIALS" in ''|*[!0-9]*) REVIEWER_DENIALS=0 ;; esac
}

reviewer_spawn_denied() {
  reviewer_spawn_denial_probe
  [ "$REVIEWER_DENIAL_STATUS" = "blocked" ]
}

# Best-effort only: /zensu:doctor has no transcript path of its own, so without
# this note the diagnosis would exist for exactly one Stop and nowhere else.
# A failed write never changes the decision this hook emits.
# Anchored on the project root, NOT on the retired ambient TDD_STATE_DIR: the
# only reader resolves the directory from CLAUDE_PROJECT_DIR, so honoring an
# override here would write the note where /zensu:doctor never looks — and aim
# an unlink outside the session-bound directory.
reviewer_denial_note_path() {
  # Asserts the SAME shape the doctor's filename regex requires, not merely the
  # prefix: a `scv1_` id of any other length would be written to a name the only
  # reader silently never matches, which is the "rename one and doctor goes quiet
  # with everything still green" failure. Defense in depth — no path is known
  # where the resolver emits a non-canonical id.
  case "$SESSION_ID" in
    scv1_*[!0-9a-f]*) return 1 ;;
    scv1_????????????????????????????????????????????????????????????????) ;;
    *) return 1 ;;
  esac
  printf '%s/.zensu/state/reviewer-spawn-denied-%s.json' "$PROJECT_ROOT" "$SESSION_ID"
}

# Clearing is separate from writing and takes no probe, because it must run on
# the terminal paths this hook exits through early — a note that outlived the
# review it says never happened would have /zensu:doctor reporting a refusal
# forever, which is exactly what the doctor row promises cannot happen.
# The note is the one artifact in `.zensu/state/` written with no lease, and its
# two halves are an unlink and a rename: a clear can remove a note a concurrent
# write has just published, or miss one published an instant later. Both halves
# therefore run inside the same external lease every other writer of this
# directory takes, keyed on this session's own workflow document.
#
# The lease is an IMPROVEMENT, never a precondition. When it cannot be acquired
# the operation still runs unlocked, because failing to write or retire the note
# must never change the Stop decision — the contract this whole diagnostic sits
# under. Both callbacks therefore ALWAYS return 0, which is what makes a non-zero
# result here unambiguously a lease failure rather than a failed operation.
# The one overlap is a lease that acquires and then fails to release: the
# callback already ran and runs a second time. Harmless by construction — the
# clear is `rm -f` and the write republishes identical bytes under a fresh
# timestamp — and preferable to the alternative of silently skipping it.
reviewer_note_locked() {
  _tdd_locked_run "$STATE_FILE" "$@" 2>/dev/null && return 0
  "$@"
  return 0
}

# Reaps every note no session can own any more, not merely this one's. Nothing
# else removes them: a session whose spawn was refused and which then never Stops
# again cannot clear its own note, the doctor is read-only by contract, and there
# is no reaper for `tdd-phase-*.json` either — so without this the file survives
# every process able to explain it.
#
# The set is exactly the one `reviewerDenialRows` already refuses to count: a
# note whose sibling workflow document is gone. So this can never destroy a live
# diagnosis — only files the reader has already stopped believing. The name is
# matched to the same character-exact shape the writer asserts before it, so the
# unlink cannot widen past a note this plugin could have written.
reviewer_denial_notes_reap() {
  local state_dir ttl
  state_dir="$PROJECT_ROOT/.zensu/state"
  [ -d "$state_dir" ] || return 0
  # Cheap pre-check first: this runs on every clear, and the overwhelming
  # majority of Stops have no note to reap. Without it every Stop in every
  # session would pay for a node process to learn there is nothing to do.
  set -- "$state_dir"/reviewer-spawn-denied-scv1_*.json
  [ -f "$1" ] || return 0
  # The SAME TTL the doctor ages a note out against, read from the same config
  # key. A note past it is the one the doctor's own row calls safe to delete.
  ttl="$(zensu_pending_review_ttl_hours 2>/dev/null)" || ttl=0
  case "$ttl" in ''|*[!0-9]*) ttl=0 ;; esac
  # stdin is redirected below alongside the output channels, and that is not
  # cosmetic: this runs INSIDE the lease, whose keeper is a bash coprocess, and a
  # child inheriting those descriptors holds the control channel's write end open
  # after the parent closes it — the keeper then never sees EOF. It does not
  # surface as a hang here; it surfaces as unrelated checks failing later,
  # because the Stop that held the lease finished degraded.
  # The trailing `|| true` keeps this best-effort, which also means a fault
  # inside the script below is SILENT. Everything between the quotes is
  # JavaScript — a stray shell comment in there is a syntax error that reaps
  # nothing and says nothing.
  REAP_DIR="$state_dir" REAP_TTL="$ttl" node -e '
    const fs=require("node:fs"), path=require("node:path");
    const dir=process.env.REAP_DIR, ttl=Number(process.env.REAP_TTL);
    // The same character-exact shape the writer asserts before it writes. This
    // is the one place a Stop unlinks a file belonging to another session, so
    // the name is pinned rather than prefix-matched.
    const NAME=/^reviewer-spawn-denied-(scv1_[a-f0-9]{64})\.json$/;
    let entries;
    try { entries=fs.readdirSync(dir); } catch (e) { process.exit(0); }
    const now=Date.now();
    for (const f of entries) {
      const m=NAME.exec(f); if(!m) continue;
      // Unbound: no workflow document for the session that could have written
      // it. The doctor already refuses to count these, so removing one destroys
      // no diagnosis anybody still reads.
      let dead = entries.indexOf("tdd-phase-"+m[1]+".json") === -1;
      // Past the TTL: its session has not ended a turn in longer than the doctor
      // is willing to believe the note, and cannot clear it itself. `ttl === 0`
      // DISABLES the age-out, exactly as it does on the reading side.
      if (!dead && ttl > 0) {
        try {
          const p=path.join(dir,f);
          const st=fs.lstatSync(p);
          if (!st.isFile() || st.nlink !== 1) continue;
          const parsed=JSON.parse(fs.readFileSync(p,"utf8"));
          const ts=parsed && parsed.detectedAtMs;
          if (Number.isInteger(ts) && ts > 0 && (now-ts)/3600000 > ttl) dead=true;
        } catch (e) {
          // Unreadable or unparseable: the doctor reports it as a note this
          // plugin did not write and tells the user to delete it. Deleting it
          // HERE would silently destroy a file this plugin does not own.
          continue;
        }
      }
      if (!dead) continue;
      try { fs.rmSync(path.join(dir,f),{force:true}); } catch (e) { /* next Stop retries */ }
    }
  ' </dev/null >/dev/null 2>&1 || true
  return 0
}

reviewer_denial_note_clear_unlocked() {
  local note
  reviewer_denial_notes_reap
  note="$(reviewer_denial_note_path)" || return 0
  # The temp carries a per-process suffix (see the writer), so the glob is what
  # reaps a crashed writer's leftover. An unmatched glob is silently ignored
  # under `rm -f`, and the shape guard above has already pinned every character
  # of the name, so this cannot widen past the intended file.
  rm -f "$note" "$note".*.tmp 2>/dev/null || true
  return 0
}

reviewer_denial_note_clear() {
  reviewer_note_locked reviewer_denial_note_clear_unlocked
}

reviewer_denial_note_write_unlocked() {
  local note
  note="$(reviewer_denial_note_path)" || return 0
  [ -d "$(dirname "$note")" ] || return 0
  if reviewer_spawn_denied; then
    # The state directory is writable from inside the session, so the note is
    # written the way every other record in it is: refuse a pre-planted link or
    # hard link outright, then land an exclusive temp file by rename.
    # stdout is redirected too, not just stderr: this hook's stdout IS the Stop
    # decision channel and this runs immediately before emit_block, so a single
    # stray byte here would prefix the decision JSON and lose the block entirely.
    KIND="$REVIEWER_DENIAL_KIND" NOTE="$note" node -e '
      const fs=require("node:fs");
      const note=process.env.NOTE;
      // Per-process temp name. With a deterministic one, every writer unlinked
      // it before creating it, so O_EXCL rejected nobody: two writers could each
      // create their own inode and the losing rename published bytes that
      // process never wrote. A private name means O_EXCL guards the create, and no
      // process removes a path another process owns. It also removes the
      // one-mkdir denial of service: a planted directory at the fixed .tmp made
      // rmSync throw EISDIR and permanently silenced the note.
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
            schemaVersion:1, kind:process.env.KIND||"",
            subagentType:"zensu:code-reviewer", detectedAtMs:Date.now(),
          })+"\n");
        } finally { fs.closeSync(fd); }
        fs.renameSync(tmp, note);
      } catch (e) {
        // A half-written temp file must not outlive the attempt that made it.
        // Safe now that only this pid can name it.
        try { fs.rmSync(tmp,{force:true}); } catch (_) { /* nothing else to do */ }
      }
    ' >/dev/null 2>&1 || true
  elif [ "$REVIEWER_DENIAL_STATUS" = "clear" ]; then
    # The UNLOCKED spelling on purpose: this already runs inside the lease, and
    # the lease is not reentrant — taking it again here would fail to acquire and
    # fall back to an unlocked clear anyway, at the cost of a second keeper
    # process on the Stop path.
    reviewer_denial_note_clear_unlocked
  fi
  return 0
}

reviewer_denial_note() {
  # The probe runs BEFORE the lease is taken. It reads a host-supplied transcript
  # that may sit on slow or network-backed storage, and holding this directory's
  # lease across that read would make every other writer of it wait on a path
  # with no deadline above it. The probe memoizes, so the callback re-reads
  # nothing and the verdict it acts on is the same one.
  reviewer_spawn_denial_probe
  reviewer_note_locked reviewer_denial_note_write_unlocked
}

INNER_SNAPSHOT=""
if INNER_SNAPSHOT="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
  INNER_STATUS=0
else
  INNER_STATUS=$?
fi
case "$INNER_STATUS" in
  0)
    INNER_FIELDS="$(printf '%s' "$INNER_SNAPSHOT" | node -e '
      try {
        const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
        process.stdout.write([s.active,s.implComplete,s.chainDone,s.codeReviewDone,
          s.autopilot?s.autopilot.runId:"",s.autopilot?s.autopilot.attempt:"",
          s.autopilot?s.autopilot.returnStage:"",
          s.autopilot?s.autopilot.chainId:""].join("\t"));
      } catch (_) { process.exit(3); }
    ' 2>/dev/null)" || {
      printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: current-session inner state is corrupt or unsafe."}'
      exit 0
    }
    IFS=$'\t' read -r SESSION_ACTIVE SESSION_IMPL_COMPLETE SESSION_CHAIN_DONE \
      _SESSION_CODE_REVIEW_DONE INNER_BOUND_RUN INNER_BOUND_ATTEMPT \
      INNER_BOUND_RETURN_STAGE INNER_BOUND_CHAIN <<<"$INNER_FIELDS"
    ;;
  1)
    # SessionStart creates this baseline before any model action. Once the
    # immutable session context is bound, a missing baseline is deletion or an
    # incomplete initialization and must never be reinterpreted as inactivity.
    printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: the mandatory current-session workflow baseline is missing. Start a fresh Claude Code session or repair the Session Control state; do not infer completion."}'
    exit 0
    ;;
  *)
    printf '%s\n' '{"decision":"block","reason":"Zensu review-chain Stop denied: current-session inner state is corrupt or unsafe."}'
    exit 0
    ;;
esac

OUTER_STATUS=1
OUTER_JSON=""
if [ -r "$AUTOPILOT_STATE_LIB" ]; then
  # shellcheck disable=SC1090
  source "$AUTOPILOT_STATE_LIB"
  if OUTER_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then
    OUTER_STATUS=0
  else
    OUTER_STATUS=$?
  fi
fi

emit_block() {
  printf '%s' "$1" | node -e '
    const reason = require("node:fs").readFileSync(0, "utf8");
    process.stdout.write(JSON.stringify({decision:"block",reason}));
  '
  echo
}

# A corrupt/orphaned outer inventory is authoritative and must fail closed
# before deferred-review adoption, inner counters, or any other mutation.
if [ "$OUTER_STATUS" -gt 1 ]; then
  emit_block "Zensu Autopilot Stop denied: project-local durable state is corrupt or unsafe. Repair or explicitly cancel it; do not infer completion."
  exit 0
fi

if [ "$OUTER_STATUS" -eq 1 ] && [ -n "$INNER_BOUND_RUN" ]; then
  emit_block "Zensu Autopilot Stop denied: the current inner generation is bound to run ${INNER_BOUND_RUN}, but its project-local active pointer is missing. Restore or explicitly repair the durable outer state; do not infer completion."
  exit 0
fi

outer_fields() {
  printf '%s' "$OUTER_JSON" | node -e '
    let input="";
    process.stdin.on("data",c=>input+=c);
    process.stdin.on("end",()=>{ try {
      const s=JSON.parse(input||"{}");
      if(!s.tdd || typeof s.tdd.headUpdateRequired!=="boolean")process.exit(3);
      process.stdout.write([s.runId,s.ownerSessionId,s.stage,s.nextActionCode,
        s.tdd.headUpdateRequired].join("\t"));
    } catch (_) { process.exit(3); } });
  ' 2>/dev/null
}

outer_reload() {
  if OUTER_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then OUTER_STATUS=0; else OUTER_STATUS=$?; fi
}

outer_is_stop_terminal() {
  [ "$OUTER_STATUS" -eq 0 ] || return 1
  printf '%s' "$OUTER_JSON" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8")||"{}");
      // BLOCKED is stop-releasing but still resumable and project-owning.  It
      // must never be treated as historical for standalone/deferred adoption.
      process.exit(["DONE","CANCELLED"].includes(s.stage)?0:1);
    } catch (_) { process.exit(2); }
  ' 2>/dev/null
}

outer_apply_block() {
  local run_id="$1" code="$2" suffix="$3" payload state generation event_key event_id verified
  state="$(autopilot_read_run "$run_id" "$PROJECT_ROOT" 2>/dev/null)" || return 1
  generation="$(printf '%s' "$state" | node -e '
    let input="";process.stdin.on("data",c=>input+=c);process.stdin.on("end",()=>{try{
      const s=JSON.parse(input); if(!Array.isArray(s.events)||typeof s.stage!=="string")process.exit(3);
      process.stdout.write(`${s.stage}:${s.events.length}`);
    }catch(_){process.exit(3);}});
  ' 2>/dev/null)" || return 1
  event_key="$(RUN="$run_id" CODE="$code" SUFFIX="$suffix" GENERATION="$generation" node -e '
    const crypto=require("crypto");
    process.stdout.write(crypto.createHash("sha256").update(JSON.stringify([
      process.env.RUN,process.env.CODE,process.env.SUFFIX,process.env.GENERATION
    ])).digest("hex"));
  ')" || return 1
  event_id="outer-block-${event_key}"
  payload="$(CODE="$code" node -e 'process.stdout.write(JSON.stringify({code:process.env.CODE}))')"
  autopilot_apply_event "$run_id" "$event_id" BLOCK "$payload" \
    "$PROJECT_ROOT" "$SESSION_ID" >/dev/null 2>&1 || return 1
  verified="$(autopilot_read_run "$run_id" "$PROJECT_ROOT" 2>/dev/null)" || return 1
  printf '%s' "$verified" | CODE="$code" EVENT_ID="$event_id" node -e '
    let input="";process.stdin.on("data",c=>input+=c);process.stdin.on("end",()=>{try{
      const s=JSON.parse(input),last=Array.isArray(s.events)&&s.events[s.events.length-1];
      const ok=s.stage==="BLOCKED"&&s.blocked&&s.blocked.code===process.env.CODE
        &&last&&last.eventId===process.env.EVENT_ID&&last.eventType==="BLOCK"
        &&last.payload&&last.payload.code===process.env.CODE;
      process.exit(ok?0:3);
    }catch(_){process.exit(3);}});
  ' 2>/dev/null
}

# Explicit Autopilot escapes are audited state transitions. They never forge a
# successful terminus and they take precedence over inner-chain enforcement.
if [ "$OUTER_STATUS" -eq 0 ] && { [ "${ZENSU_AUTOPILOT:-}" = "off" ] || ! zensu_hook_enabled autopilotEnforcer; }; then
  # The escape decision is a current-pointer proof, not a cached-status check.
  # Reconcile/read under the project lock so a historical DONE/CANCELLED
  # snapshot cannot release a concurrently published active run.
  if OUTER_JSON="$(autopilot_reconcile_stop_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)"; then
    OUTER_STATUS=0
  else
    OUTER_STATUS=$?
    # Every release in this escape branch retires a refusal note for the same
    # reason the inner-guard escapes below do: once it releases, this session's
    # Stop never routes the inner chain again, so nothing else could remove it.
    if [ "$OUTER_STATUS" -eq 1 ]; then reviewer_denial_note_clear; exit 0; fi
    emit_block "Zensu Autopilot escape denied: current durable state could not be proven safely."
    exit 0
  fi
  FIELDS="$(outer_fields)" || { emit_block "Zensu Autopilot state is corrupt; the requested escape could not be audited. Repair or cancel the project-local state explicitly."; exit 0; }
  IFS=$'\t' read -r OUTER_RUN OUTER_OWNER OUTER_STAGE _ <<<"$FIELDS"
  case "$OUTER_STAGE" in DONE|BLOCKED|CANCELLED) reviewer_denial_note_clear; exit 0 ;; esac
  if [ "$OUTER_OWNER" != "$SESSION_ID" ]; then
    emit_block "Zensu Autopilot Stop denied: the active durable run belongs to another top-level session and cannot be escaped here. Only its original owner task/session may resume or cancel it; a fresh session cannot take ownership. Reopen the owner task or perform explicit manual state recovery."
    exit 0
  fi
  if [ "${ZENSU_AUTOPILOT:-}" = "off" ]; then ESCAPE_CODE=ZENSU_AUTOPILOT_OFF; else ESCAPE_CODE=AUTOPILOT_ENFORCER_DISABLED; fi
  case "$OUTER_STAGE" in DONE|BLOCKED|CANCELLED) ;;
    *) outer_apply_block "$OUTER_RUN" "$ESCAPE_CODE" "escape-${OUTER_STAGE}" || {
         emit_block "Zensu Autopilot escape failed to persist BLOCKED; Stop remains denied to avoid an unaudited bypass."
         exit 0
       } ;;
  esac
  reviewer_denial_note_clear
  exit 0
fi
outer_finish() {
  local fields run_id owner stage action head_update_required count cap
  local budget_json budget_fields budget_blocked reconcile_rc budget_rc
  local stale_retry="${1:-false}"

  # Re-read and, when necessary, reconcile the current Outer+Inner generation
  # under the canonical Outer -> Inner lock order. Never decide from the stale
  # snapshots captured when this Stop invocation began: a newer TDD attempt may
  # already own both files by the time inner-first routing reaches this point.
  if OUTER_JSON="$(autopilot_reconcile_stop_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)"; then
    OUTER_STATUS=0
  else
    reconcile_rc=$?
    OUTER_STATUS=$reconcile_rc
    case "$reconcile_rc" in
      1) return 0 ;;
      *) emit_block "Zensu Autopilot Stop denied: project-local durable state could not be reconciled safely. Repair or explicitly cancel it; do not infer completion."; return 0 ;;
    esac
  fi

  fields="$(outer_fields)" || { emit_block "Zensu Autopilot Stop denied: validated state fields could not be read."; return 0; }
  IFS=$'\t' read -r run_id owner stage action head_update_required <<<"$fields"
  case "$stage" in
    DONE|BLOCKED|CANCELLED) return 0 ;;
  esac
  if [ "$owner" != "$SESSION_ID" ]; then
    emit_block "Zensu Autopilot Stop denied: active run ${run_id} is owned by another top-level session. Only the original owner task/session may continue, resume, or cancel it; a fresh session cannot take ownership. Reopen the owner task or perform explicit manual state recovery."
    return 0
  fi

  # Reconciliation can move the run to its return stage or to audited BLOCKED.
  case "$stage" in
    DONE|BLOCKED|CANCELLED) return 0 ;;
  esac

  cap=12
  if budget_json="$(autopilot_increment_stop_budget_capped "$run_id" "$stage" \
      "$PROJECT_ROOT" "$SESSION_ID" "$cap" STOP_BUDGET_EXHAUSTED 2>/dev/null)"; then
    :
  else
    budget_rc=$?
    if [ "$budget_rc" -eq 4 ] && [ "$stale_retry" != "true" ]; then
      # Stage/event generation changed after reconciliation but before the
      # capped mutation. Re-route exactly once from fresh state so the response
      # names the new action and the stale generation remains byte-stable.
      if OUTER_JSON="$(autopilot_read_active "$PROJECT_ROOT" 2>/dev/null)"; then
        OUTER_STATUS=0
        outer_finish true
      else
        OUTER_STATUS=$?
        if [ "$OUTER_STATUS" -ne 1 ]; then
          emit_block "Zensu Autopilot Stop denied: durable state changed and could not be re-read safely."
        fi
      fi
      return 0
    fi
    emit_block "Zensu Autopilot Stop denied: stage budget could not be persisted safely for run ${run_id}."
    return 0
  fi
  budget_fields="$(printf '%s' "$budget_json" | node -e '
    try {
      const b=JSON.parse(require("fs").readFileSync(0,"utf8"));
      if(!Number.isSafeInteger(b.count)||b.count<0||typeof b.blocked!=="boolean")process.exit(3);
      process.stdout.write(`${b.count}\t${b.blocked}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || {
    emit_block "Zensu Autopilot Stop denied: the persisted stage-budget result is invalid."
    return 0
  }
  IFS=$'\t' read -r count budget_blocked <<<"$budget_fields"
  if [ "$budget_blocked" = "true" ]; then
    echo "zensu autopilot: Stop budget exhausted in ${stage}; run moved to audited BLOCKED (never DONE)." >&2
    return 0
  fi

  if [ "$head_update_required" = "true" ]; then
    emit_block "STOP intercepted by durable Zensu Autopilot run ${run_id}. stage=${stage}; prerequisiteActionCode=UPDATE_PR_HEAD; nextActionCode=${action}; stopBlock=${count}/${cap}. FIRST execute prerequisite action UPDATE_PR_HEAD: re-run the configured gates, push the fixes, read the resulting PR head, and persist the exact PR_HEAD_UPDATED event. Only after that succeeds continue the static stage action ${action}. Inner TDD completion never releases the outer run; only DONE, BLOCKED, or CANCELLED may stop."
  else
    emit_block "STOP intercepted by durable Zensu Autopilot run ${run_id}. stage=${stage}; nextActionCode=${action}; stopBlock=${count}/${cap}. Continue exactly that closed next action. Inner TDD completion never releases the outer run; only DONE, BLOCKED, or CANCELLED may stop."
  fi
  return 0
}

# Corrupt outer state must be handled before project-wide deferred review
# adoption. A valid active outer run also never adopts an unrelated pending
# marker: its TDD attempt is explicitly run/attempt/chain bound.
OUTER_PRESENT=false
[ "$OUTER_STATUS" -ne 1 ] && OUTER_PRESENT=true

INNER_ENABLED=true
zensu_hook_enabled chainEnforcer || INNER_ENABLED=false

# Both escapes retire a refusal note for the same reason the terminal exits do:
# this session's Stop will never route the inner chain again, so nothing else
# could ever remove it and /zensu:doctor would warn about it forever.
if [ "${ZENSU_CHAIN:-}" = "off" ]; then
  tdd_record_bypass "$SESSION_ID" ZENSU_CHAIN 2>/dev/null || true
  reviewer_denial_note_clear
  outer_finish
  exit 0
fi
if [ "$INNER_ENABLED" != "true" ]; then
  reviewer_denial_note_clear
  outer_finish
  exit 0
fi

# Evaluate a completed/cancelled historical pointer against the current inner generation before the
# usual inner-first routing. Matching run/attempt/chain means the outer audit
# already owns the terminus. A standalone or stale/mismatched inner generation
# continues through normal review enforcement.
OUTER_RELEASE_STAGE=""
if [ "$OUTER_STATUS" -eq 0 ]; then
  OUTER_RELEASE_STAGE="$(printf '%s' "$OUTER_JSON" | node -e '
    try { process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).stage || ""); }
    catch (_) { process.exit(3); }
  ' 2>/dev/null)" || OUTER_RELEASE_STAGE=""
fi
if [ "$OUTER_RELEASE_STAGE" = "BLOCKED" ]; then
  # BLOCKED releases Stop but remains resumable and keeps ownership. Prove the
  # current exact binding atomically, and never retire it or adopt queued work.
  if [ "$SESSION_ACTIVE" = "true" ] && [ "$SESSION_IMPL_COMPLETE" = "true" ] \
      && [ "$SESSION_CHAIN_DONE" != "true" ] && [ -n "$INNER_BOUND_RUN" ] \
      && autopilot_terminal_owns_inner_current "$INNER_BOUND_RUN" "$PROJECT_ROOT" \
        "$SESSION_ID" "$INNER_BOUND_ATTEMPT" "$INNER_BOUND_RETURN_STAGE" \
        "$INNER_BOUND_CHAIN"; then
    # The outer audit has abandoned this review, so nothing here will ever route
    # the inner chain again. One of several retire sites — see the roster in the
    # "Host-Refused Reviewer Spawn" section of CLAUDE.md.
    reviewer_denial_note_clear
    exit 0
  fi
  # BLOCKED does not own an unrelated standalone or mismatched Inner. Keep the
  # resumable Outer present, but let that unfinished Inner reach the ordinary
  # review routing (or the bound-generation fail-closed check) below.
fi
if outer_is_stop_terminal; then
  # A terminal pointer owns only its exact still-armed inner generation. It is
  # otherwise historical and must not suppress later standalone/deferred review
  # work merely because the pointer remains project-local for auditability.
  OUTER_PRESENT=false
  if [ "$SESSION_ACTIVE" = "true" ] && [ "$SESSION_IMPL_COMPLETE" = "true" ] \
      && [ "$SESSION_CHAIN_DONE" != "true" ] && [ -n "$INNER_BOUND_RUN" ]; then
    # Retire the exact historical Inner under the canonical Outer -> Inner lock
    # order. Besides closing the stale-terminal race, this prevents a queued
    # deferred review from starving forever behind a terminal run's old Inner.
    if autopilot_reset_inner "$INNER_BOUND_RUN" "$PROJECT_ROOT" "$SESSION_ID" \
        "$INNER_BOUND_ATTEMPT" "$INNER_BOUND_CHAIN"; then
      SESSION_ACTIVE=false; SESSION_IMPL_COMPLETE=false; SESSION_CHAIN_DONE=false
      _SESSION_CODE_REVIEW_DONE=false; INNER_BOUND_RUN=""; INNER_BOUND_ATTEMPT=""
      INNER_BOUND_RETURN_STAGE=""; INNER_BOUND_CHAIN=""
    else
      outer_reload
      if [ "$OUTER_STATUS" -eq 0 ] && ! outer_is_stop_terminal; then
        outer_finish
        exit 0
      elif [ "$OUTER_STATUS" -gt 1 ]; then
        emit_block "Zensu Autopilot Stop denied: terminal release raced with unsafe durable state."
        exit 0
      fi
      # The same terminal pointer does not own this Inner. Continue through
      # ordinary review enforcement instead of releasing it.
    fi
  fi
fi

ADOPT_ELIGIBLE=false
if [ "$OUTER_PRESENT" = false ]; then
  if [ "$SESSION_ACTIVE" != "true" ]; then
    ADOPT_ELIGIBLE=true
  elif [ "$SESSION_IMPL_COMPLETE" = "true" ] && [ "$SESSION_CHAIN_DONE" = "true" ]; then
    ADOPT_ELIGIBLE=true
  fi
fi

if [ "$ADOPT_ELIGIBLE" = "true" ]; then
  # Behavioral, not wording: this seeds the `vanilla` flag of an adopted deferred
  # review that has no prior state to freeze from. It reads the EFFECTIVE mode so an
  # adopted chain gets the discipline this session actually chose — the adopting
  # session's own marker, then the config.
  if zensu_tdd_strict_effective "$PROJECT_ROOT" "${ZENSU_SESSION_KEY:-}"; then VANILLA_SEED=false; else VANILLA_SEED=true; fi
  if ! declare -F autopilot_adopt_pending_review >/dev/null 2>&1; then
    emit_block "Zensu review-chain Stop denied: the durable Outer-lock adoption helper is unavailable. Repair the plugin runtime before claiming deferred review work."
    exit 0
  fi
  if autopilot_adopt_pending_review "$PROJECT_ROOT" "$SESSION_ID" \
      "$VANILLA_SEED" "$(zensu_pending_review_ttl_hours)" "$DEFERRED_OWNER_PID"; then
    :
  else
    ADOPT_RC=$?
    case "$ADOPT_RC" in
      6) ;; # no pending marker/claim; this is a normal no-work result
      4)
        # The locked read or its descriptor-backed contention fallback proved
        # that a durable run became active after the initial absent snapshot.
        # Do not take a second contended read here: its legacy rc=1 conflates
        # lock timeout with absence and could erase that stronger proof.
        emit_block "Zensu Autopilot Stop denied: a durable run became active while deferred review adoption was waiting for the Outer lock. Retry Stop so the current durable state can be routed safely."
        exit 0
        ;;
      *)
        emit_block "Zensu review-chain Stop denied: deferred-review adoption could not prove a safe absent/DONE/CANCELLED Outer generation (rc=${ADOPT_RC}). The pending review remains retryable."
        exit 0
        ;;
    esac
  fi
  if INNER_SNAPSHOT="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
    INNER_FIELDS="$(printf '%s' "$INNER_SNAPSHOT" | node -e '
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.stdout.write([s.active,s.implComplete,s.chainDone,s.codeReviewDone,
        s.autopilot?s.autopilot.runId:"",s.autopilot?s.autopilot.attempt:"",
        s.autopilot?s.autopilot.returnStage:"",
        s.autopilot?s.autopilot.chainId:""].join("\t"));
    ' 2>/dev/null)" || { emit_block "Zensu review-chain Stop denied: adopted inner state could not be validated."; exit 0; }
    IFS=$'\t' read -r SESSION_ACTIVE SESSION_IMPL_COMPLETE SESSION_CHAIN_DONE \
      _SESSION_CODE_REVIEW_DONE INNER_BOUND_RUN INNER_BOUND_ATTEMPT \
      INNER_BOUND_RETURN_STAGE INNER_BOUND_CHAIN <<<"$INNER_FIELDS"
  else
    SNAPSHOT_RC=$?
    if [ "$SNAPSHOT_RC" -eq 1 ]; then
      SESSION_ACTIVE=false; SESSION_IMPL_COMPLETE=false; SESSION_CHAIN_DONE=false
      _SESSION_CODE_REVIEW_DONE=false; INNER_BOUND_RUN=""; INNER_BOUND_ATTEMPT=""
      INNER_BOUND_RETURN_STAGE=""; INNER_BOUND_CHAIN=""
    else
    emit_block "Zensu review-chain Stop denied: deferred-review adoption left invalid inner state."
    exit 0
    fi
  fi
fi

# Every path below this point still has a chain to enforce. These three do not —
# no session, implementation not finished, chain already closed — so they retire
# a refusal note here rather than in the routing branches, which they never
# reach. They are not the only retire sites; the escapes and the BLOCKED-outer
# release above clear too, and the cap path clears on a converged chain.
if [ "$SESSION_ACTIVE" != "true" ]; then reviewer_denial_note_clear; outer_finish; exit 0; fi
if [ "$SESSION_IMPL_COMPLETE" != "true" ]; then reviewer_denial_note_clear; outer_finish; exit 0; fi
if [ "$SESSION_CHAIN_DONE" = "true" ]; then reviewer_denial_note_clear; outer_finish; exit 0; fi

MAX_ROUNDS="$(zensu_autofix_max_rounds)"
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5 ;; esac
CAP=$((MAX_ROUNDS + 3))
INNER_CAP_BLOCKED=false
if [ -n "$INNER_BOUND_RUN" ]; then
  # Every bound-Inner increment is one Outer -> Inner transaction. Besides the
  # exact run/attempt/chain binding, stage and event count are a generation CAS,
  # so an old Stop cannot cap a newly advanced outer stage.
  BOUND_OUTER_META="$(printf '%s' "$OUTER_JSON" | RUN_ID="$INNER_BOUND_RUN" SID="$SESSION_ID" \
    EXPECTED_ATTEMPT="$INNER_BOUND_ATTEMPT" EXPECTED_RETURN_STAGE="$INNER_BOUND_RETURN_STAGE" \
    EXPECTED_CHAIN="$INNER_BOUND_CHAIN" node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      const exact=s.runId===process.env.RUN_ID&&s.ownerSessionId===process.env.SID
        &&s.stage==="TDD_RUNNING"&&Array.isArray(s.events)&&s.tdd
        &&String(s.tdd.attempt)===process.env.EXPECTED_ATTEMPT
        &&s.tdd.returnStage===process.env.EXPECTED_RETURN_STAGE
        &&s.tdd.chainId===process.env.EXPECTED_CHAIN
        &&s.tdd.sessionId===process.env.SID;
      if(!exact)process.exit(3);
      process.stdout.write(`${s.stage}\t${s.events.length}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || BOUND_OUTER_META=""
  if [ -z "$BOUND_OUTER_META" ]; then
    outer_reload
    emit_block "Zensu review-chain Stop denied: the bound inner generation changed before its Stop budget could be claimed; retry Stop from current state."
    exit 0
  fi
  IFS=$'\t' read -r BOUND_OUTER_STAGE BOUND_OUTER_EVENTS <<<"$BOUND_OUTER_META"
  if INNER_CAP_RESULT="$(autopilot_increment_inner_stop_budget_capped \
      "$INNER_BOUND_RUN" "$BOUND_OUTER_STAGE" "$BOUND_OUTER_EVENTS" \
      "$INNER_BOUND_ATTEMPT" "$INNER_BOUND_RETURN_STAGE" "$INNER_BOUND_CHAIN" \
      "$PROJECT_ROOT" "$SESSION_ID" "$CAP" \
      INNER_REVIEW_STOP_BUDGET_EXHAUSTED 2>/dev/null)"; then
    :
  else
    # A stale CAS is expected under concurrency. Route from the new durable
    # outer generation; never emit a review prompt derived from the old inner
    # snapshot and never mutate that newer generation.
    outer_reload
    emit_block "Zensu review-chain Stop denied: the bound inner budget generation changed before it could be persisted safely; retry Stop from current state."
    exit 0
  fi
  INNER_CAP_FIELDS="$(printf '%s' "$INNER_CAP_RESULT" | node -e '
    try {
      const b=JSON.parse(require("fs").readFileSync(0,"utf8"));
      if(!Number.isSafeInteger(b.count)||b.count<0||typeof b.blocked!=="boolean")process.exit(3);
      process.stdout.write(`${b.count}\t${b.blocked}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || {
    emit_block "Zensu review-chain Stop denied: the persisted bound-inner budget result is invalid."
    exit 0
  }
  IFS=$'\t' read -r BLOCKS INNER_CAP_BLOCKED <<<"$INNER_CAP_FIELDS"
else
  if BLOCKS="$(tdd_increment_stop_budget "$SESSION_ID" 2>/dev/null)"; then
    case "$BLOCKS" in
      ''|*[!0-9]*) emit_block "Zensu review-chain Stop denied: the persisted standalone-inner budget result is invalid."; exit 0 ;;
    esac
  else
    # The locked increment rejected a stale snapshot (or could not persist).
    # Re-read before routing and fail closed if this is still the same live
    # review generation; never synthesize a counter and continue on old fields.
    if FRESH_INNER="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
      if printf '%s' "$FRESH_INNER" | node -e '
        try {
          const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
          process.exit(s.active===true&&s.implComplete===true&&s.chainDone===false?0:1);
        } catch (_) { process.exit(2); }
      ' 2>/dev/null; then
        emit_block "Zensu review-chain Stop denied: the current standalone-inner budget could not be persisted safely."
      else
        outer_finish
      fi
    else
      FRESH_INNER_RC=$?
      if [ "$FRESH_INNER_RC" -eq 1 ]; then outer_finish
      else emit_block "Zensu review-chain Stop denied: current-session inner state became corrupt while updating its Stop budget."
      fi
    fi
    exit 0
  fi
fi

if [ "$BLOCKS" -gt "$CAP" ]; then
  if ! tdd_release_pending_review_claim "$SESSION_ID" 2>/dev/null; then
    emit_block "Zensu review-chain Stop denied: the deferred-review cancellation receipt could not be persisted safely at the Stop cap. Repair storage and retry; the guard remains active."
    exit 0
  fi
  # Before the bound arms, which exit: a bound run capped by a refused spawn
  # needs the diagnosis recorded just as much as a standalone one. Guarded by the
  # same accessor the branch below uses, because a converged chain must never
  # mint a note — the model can re-spawn the reviewer against the self-review
  # directive and have THAT refused, which would otherwise make /zensu:doctor
  # report "no review ran" for a chain that already converged.
  if [ "$(tdd_code_review_done "$STATE_FILE")" != "true" ]; then
    reviewer_denial_note
    # Emitted HERE, above the bound arms, because both of them exit before the
    # standalone release message below. A bound Autopilot run whose spawn the
    # host refused would otherwise be told only that the review "did not
    # converge" — the sentence that sends the reader hunting inside Zensu, which
    # is the outcome this diagnosis exists to prevent. The probe is memoized, so
    # this costs no second transcript read.
    if reviewer_spawn_denied; then
      echo "zensu chain-enforcer: that chain never stalled inside Zensu — the zensu:code-reviewer spawn was refused by the host permission layer${REVIEWER_DENIAL_KIND:+ (${REVIEWER_DENIAL_KIND})}. Nothing was reviewed. The remedy is the user's to apply and no agent may apply it for them, least of all by editing a settings file itself: allow the spawn with the permissions.allow rule \"Agent(zensu:code-reviewer)\", or leave the permission mode that refused it. Then re-enter /zensu:tdd for the current task." >&2
    fi
  else
    reviewer_denial_note_clear
  fi
  if [ "$INNER_CAP_BLOCKED" = "true" ]; then
    echo "zensu chain-enforcer: inner review did not converge; active Autopilot run moved to audited BLOCKED." >&2
    exit 0
  elif [ -n "$INNER_BOUND_RUN" ]; then
    emit_block "Zensu inner review cap was reached, but the bound Autopilot generation did not persist its required audited BLOCKED transition."
    exit 0
  fi
  if [ "$(tdd_code_review_done "$STATE_FILE")" = "true" ]; then
    echo "zensu chain-enforcer: terminal self-review did not converge after ${BLOCKS} nudges (cap ${CAP}); releasing the standalone Inner guard. Run /zensu:reset-review-limit to re-arm this ticket-bound review generation, or set ZENSU_CHAIN=off explicitly. Any durable Outer run remains enforced." >&2
  else
    echo "zensu chain-enforcer: review chain did not converge after ${BLOCKS} nudges (cap ${CAP}); releasing the standalone Inner guard. This is a stalled pre-terminus chain, so /zensu:reset-review-limit is not applicable. Run /zensu:doctor (or /zensu:recover-chain) to read the chain shape and the command it names; only otherwise re-enter /zensu:tdd for the current task to start a fresh guarded chain, or set ZENSU_CHAIN=off explicitly. Any durable Outer run remains enforced." >&2
    # The refusal diagnosis itself is emitted above, before the bound arms, so
    # every cap sub-path carries it rather than the standalone one alone.
  fi
  outer_finish
  exit 0
fi

# Ensure the prompt below still describes the exact generation whose counter
# was incremented. A concurrent begin/complete is routed from fresh state.
if FRESH_PROMPT_INNER="$(tdd_chain_snapshot "$STATE_FILE" "$SESSION_ID" 2>/dev/null)"; then
  FRESH_PROMPT_RC=0
else
  FRESH_PROMPT_RC=$?
  if [ "$FRESH_PROMPT_RC" -eq 1 ]; then outer_finish
  else emit_block "Zensu review-chain Stop denied: current-session inner state became corrupt before routing."
  fi
  exit 0
fi
if FRESH_PROMPT_FIELDS="$(printf '%s' "$FRESH_PROMPT_INNER" | EXPECTED_RUN="$INNER_BOUND_RUN" \
    EXPECTED_ATTEMPT="$INNER_BOUND_ATTEMPT" EXPECTED_RETURN_STAGE="$INNER_BOUND_RETURN_STAGE" \
    EXPECTED_CHAIN="$INNER_BOUND_CHAIN" \
    EXPECTED_COUNT="$BLOCKS" node -e '
  try {
    const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
    const linked=process.env.EXPECTED_RUN
      ? s.autopilot&&s.autopilot.runId===process.env.EXPECTED_RUN
        &&String(s.autopilot.attempt)===process.env.EXPECTED_ATTEMPT
        &&s.autopilot.returnStage===process.env.EXPECTED_RETURN_STAGE
        &&s.autopilot.chainId===process.env.EXPECTED_CHAIN
      : s.autopilot===null;
    const exact=s.active===true&&s.implComplete===true&&s.chainDone===false
      &&typeof s.codeReviewDone==="boolean"&&typeof s.vanilla==="boolean"
      &&s.stopBlockCount===Number(process.env.EXPECTED_COUNT)&&linked;
    if(!exact)process.exit(1);
    process.stdout.write([String(s.vanilla),String(s.implComplete),
      String(s.chainDone),String(s.codeReviewDone)].join("\t"));
  } catch (_) { process.exit(2); }
  ' 2>/dev/null)"; then
  :
else
  if printf '%s' "$FRESH_PROMPT_INNER" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.exit(s.active===true&&s.implComplete===true&&s.chainDone===false?0:1);
    } catch (_) { process.exit(2); }
  ' 2>/dev/null; then
    emit_block "Zensu review-chain Stop denied: the inner generation changed while Stop was being routed; retry Stop from current state."
  else
    outer_finish
  fi
  exit 0
fi

IFS=$'\t' read -r SESSION_VANILLA SESSION_IMPL SESSION_CHAIN CODE_REVIEW_DONE \
  <<<"$FRESH_PROMPT_FIELDS"
STATE_LEGEND="Session state: mode=strict, implComplete=${SESSION_IMPL}, chainDone=${SESSION_CHAIN}."
if [ "$SESSION_VANILLA" = "true" ]; then
  STATE_LEGEND="Session state: mode=vanilla, implComplete=${SESSION_IMPL}, chainDone=${SESSION_CHAIN}. In vanilla mode the RED/GREEN FSM is not driven, so the 'phase' and 'history' fields carry no signal here and are never by themselves evidence of a corrupt or never-started session."
fi
LEGEND_CLOSER="That observation does not change what must happen next: the instruction above still governs before this turn may end."
LEGEND_CLOSER_WITH_EXCEPTION="That observation does not change what must happen next: the instruction above — including the single exception it explicitly states — still governs before this turn may end."
LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
PLUGIN_DATA_Q="$(printf '%q' "${CLAUDE_PLUGIN_DATA:-}")"
LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"
INNER_BOUND_ARGS=""
INNER_ZERO_CHANGE_ARGS=""
INNER_ZERO_CHANGE_NOTE=" That terminus verifies the claim before it closes anything: it refuses while 'git diff --name-only HEAD' or an untracked non-ignored file still reports a changed file, so it can never stand in for a review of real changes."
INNER_SELF_REVIEW_ENVELOPE=" "
INNER_REVIEW_HEADERS="whose prompt starts with exactly two header lines — first 'PRE-MERGED FINDINGS (fan-out)', second 'REVIEW-TICKET: <ticket>'"
INNER_REVIEW_SUFFIX=", followed by"
if [ -n "$INNER_BOUND_RUN" ]; then
  INNER_BOUND_RUN_Q="$(printf '%q' "$INNER_BOUND_RUN")"
  INNER_BOUND_ATTEMPT_Q="$(printf '%q' "$INNER_BOUND_ATTEMPT")"
  INNER_BOUND_CHAIN_Q="$(printf '%q' "$INNER_BOUND_CHAIN")"
  INNER_BOUND_ARGS=" --autopilot-run ${INNER_BOUND_RUN_Q} --autopilot-attempt ${INNER_BOUND_ATTEMPT_Q} --chain-id ${INNER_BOUND_CHAIN_Q}"
  INNER_ZERO_CHANGE_ARGS="${INNER_BOUND_ARGS} --outcome no-changes"
  INNER_ZERO_CHANGE_NOTE=" That terminus records 'no-changes' as this attempt's audited Autopilot outcome, so the durable run keeps a receipt that distinguishes it from a reviewed close."
  INNER_SELF_REVIEW_ENVELOPE=$' Carry this exact official three-line Autopilot envelope into the skill unchanged and exactly once:\n'"ZENSU-DELEGATED-CALLER: autopilot"$'\n'"AUTOPILOT-BINDING: run=${INNER_BOUND_RUN} attempt=${INNER_BOUND_ATTEMPT} chain=${INNER_BOUND_CHAIN}"$'\n'"AUTOPILOT-STAGE: ${INNER_BOUND_RETURN_STAGE}"$'\n'
  INNER_REVIEW_HEADERS=$'whose prompt starts with exactly these five header lines:\nPRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: <ticket>\n'"ZENSU-DELEGATED-CALLER: autopilot"$'\n'"AUTOPILOT-BINDING: run=${INNER_BOUND_RUN} attempt=${INNER_BOUND_ATTEMPT} chain=${INNER_BOUND_CHAIN}"$'\n'"AUTOPILOT-STAGE: ${INNER_BOUND_RETURN_STAGE}"$'\n'
  INNER_REVIEW_SUFFIX="followed by"
fi
if [ "$CODE_REVIEW_DONE" = "true" ]; then
  # Convergence means a reviewer ran (or the verified zero-change terminus closed
  # it), so a note minted by an EARLIER refusal in this same session is stale by
  # definition — and this branch never consults the probe, so the `case` below
  # would leave it standing while doctor reports "no review ran". The clear is
  # probe-free, so it costs no transcript read and cannot change the decision.
  reviewer_denial_note_clear
  SELF_REVIEW_TICKET="$(tdd_ensure_self_review_ticket "$SESSION_ID" 2>/dev/null)" || SELF_REVIEW_TICKET=""
  if _tdd_review_ticket_shape_ok "$SELF_REVIEW_TICKET"; then
    SELF_REVIEW_TICKET_Q="$(printf '%q' "$SELF_REVIEW_TICKET")"
    REASON="STOP intercepted by zensu chain-enforcer. The code-reviewer chain has converged (codeReviewDone) but the terminal self-review stage has not run. Carry this exact generation line into the skill: 'SELF-REVIEW-TICKET: ${SELF_REVIEW_TICKET}'.${INNER_SELF_REVIEW_ENVELOPE}Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — it performs a final critical self-reflection over this session's changes, takes at most one fix round under the still-active TDD phase-gate, and OWNS the generation-bound chain terminus (it runs: ${LOG_COMMAND} --chain-done${INNER_BOUND_ARGS} --claimed-review-ticket ${SELF_REVIEW_TICKET_Q}). Do NOT end your turn, do NOT re-run the reviewer agent, and do NOT run an unqualified --chain-done yourself — let /zensu:self-review finalize only this chain generation."
  else
    REASON="STOP intercepted by zensu chain-enforcer. The state says codeReviewDone=true, but no valid consumed review ticket can bind the terminal self-review generation. Do NOT run self-review or an unqualified terminus. /zensu:reset-review-limit cannot repair this state either — it rebinds a RETAINED consumed ticket, which is exactly what is missing here. FIRST read the chain shape with: ${LOG_COMMAND} --chain-status. Act on it ONLY if it reports shape=wedged-stale-rearm with recoverable=true — then /zensu:recover-chain repairs exactly that and the chain can continue. For this state it will normally report shape=self-review-unbindable, whose own next step is the fresh generation below. Re-enter /zensu:tdd for the current task, whose fresh --tdd-begin resets this session's review ticket, round counter, and chain flags in one transition, so the reviewer chain can run again and its terminus can bind."
  fi
  REASON="${REASON} ${STATE_LEGEND} ${LEGEND_CLOSER}"
elif reviewer_spawn_denied; then
  # This branch fires on EVERY blocked Stop up to the cap, and the reason carries
  # no memory of its own. Sanctioning "one further attempt" unconditionally
  # therefore re-licenses a retry each time — the naive loop the same reason
  # forbids two sentences earlier. The scanner already counts every refused
  # reviewer result in the scanned tail, so a second refusal is observable:
  # after it, the sanction is withdrawn instead of repeated.
  REVIEWER_DENIAL_ROUTED=true
  if [ "${REVIEWER_DENIALS:-0}" -ge 2 ]; then
    DENIAL_RETRY_CLAUSE="A retry has already been spent and was refused again, so there is no attempt left to make: stop and report this to the user."
  else
    DENIAL_RETRY_CLAUSE="The ONE case for trying again: if the user says in this conversation that they have just applied it, make exactly ONE further spawn attempt — a second refusal means stop and say so."
  fi
  # Names only the user-scoped file on purpose. The project-local spelling is a
  # path this very agent could write, and pointing at it — beside the exact rule
  # that grants the refused capability — is an invitation the prose below can
  # only ask it to decline. The user-facing doctor row carries the fuller form.
  DENIAL_RULE="Add the rule \"Agent(zensu:code-reviewer)\" to permissions.allow in the user settings file ~/.claude/settings.json"
  case "$REVIEWER_DENIAL_KIND" in
    auto-mode-classifier)
      DENIAL_CAUSE="the Claude Code auto mode classifier refused it ('Permission for this action was denied by the Claude Code auto mode classifier')"
      DENIAL_REMEDY="${DENIAL_RULE}, or take this session out of auto mode with Shift+Tab so the spawn prompts for approval instead of being classified."
      ;;
    permission-denied)
      DENIAL_CAUSE="the permission layer refused it ('Permission for this action has been denied'), which is a deny rule, a dontAsk mode, or a person declining the prompt"
      DENIAL_REMEDY="${DENIAL_RULE}, remove any deny rule that names the Agent tool, and approve the spawn when it prompts. A deny rule outranks an allow rule, so the deny has to go first."
      ;;
    # A kind this hook does not know is reported as unclassified rather than
    # described as one specific host sentence it may well not have been.
    *)
      DENIAL_CAUSE="the permission layer refused it in a form this hook does not classify, so read the refusal text in the transcript before acting on it"
      DENIAL_REMEDY="${DENIAL_RULE}, remove any deny rule that names the Agent tool, and check the permission mode this session runs in."
      ;;
  esac
  REASON="STOP intercepted by zensu chain-enforcer. The zensu:code-reviewer spawn this chain needs was refused by the HOST permission layer, not by a Zensu gate: the most recent Agent call with subagent_type='zensu:code-reviewer' in this session's transcript came back refused, because ${DENIAL_CAUSE}. Spawning it again cannot succeed until that permission exists, so do NOT retry it in a loop, and do NOT reach for a terminus instead: an unqualified --chain-done would claim a review that never ran, and it refuses anyway while the worktree still reports a changed file. This is not something you can grant yourself — it is a harness setting outside the conversation, so the user has to lift it, and you must never edit a settings file yourself to widen your own permissions. ${DENIAL_REMEDY} Your next message MUST report this blocker to the user, naming the rule above, instead of retrying the spawn or inventing a review result; /zensu:doctor reports the same diagnosis from outside this turn. ${DENIAL_RETRY_CLAUSE} This guard is bounded and will not wedge the session, but nothing here has been reviewed yet. Only valid exception: if implementation produced ZERO file changes, run: ${LOG_COMMAND} --chain-done${INNER_ZERO_CHANGE_ARGS}; then stop.${INNER_ZERO_CHANGE_NOTE}"
  REASON="${REASON} ${STATE_LEGEND} ${LEGEND_CLOSER_WITH_EXCEPTION}"
else
  # Reached by CONSULTING the probe — the `elif` above evaluated it and it said
  # no — so this Stop is entitled to act on the verdict, and for a `clear` that
  # means retiring a note an earlier refusal in this same session left behind.
  # The self-review branch at the top of this ladder never evaluates the probe
  # and therefore never sets this, which is the whole point of the flag.
  REVIEWER_DENIAL_ROUTED=true
  REASON="STOP intercepted by zensu chain-enforcer. A main-thread TDD session finished implementation (or a fix round) but the zensu:code-reviewer chain has not completed. Resume the /zensu:tdd Phase 6 review sequence where it left off: fan out the five zensu:review-aspect agents over the changed files ('git diff --name-only HEAD'), merge their findings in-thread, run the zensu:review-judge second pass when hooks.reviewJudge is enabled (the default), run the Phase 6 step 4c Finding Verification Gate over the merged list when hooks.findingVerification is enabled (the default) and annotate every finding it does not confirm '[Unverified — do not fix]', issue a fresh review ticket, then your NEXT action MUST be the Agent tool with subagent_type='zensu:code-reviewer' ${INNER_REVIEW_HEADERS}${INNER_REVIEW_SUFFIX} the merged findings + build/test status. Do NOT end your turn, and do NOT fix anything inline first — the post-review hook routes findings back to you and sets chain completion on PASS or max rounds. Only valid exception: if implementation produced ZERO file changes, run: ${LOG_COMMAND} --chain-done${INNER_ZERO_CHANGE_ARGS}; then stop.${INNER_ZERO_CHANGE_NOTE}"
  REASON="${REASON} ${STATE_LEGEND} ${LEGEND_CLOSER_WITH_EXCEPTION}"
fi

if ! tdd_mark_pending_review_handoff "$SESSION_ID" "$DEFERRED_OWNER_PID" 2>/dev/null; then
  emit_block "Zensu review-chain Stop denied: the review handoff lease could not be persisted safely. No actionable review instruction was emitted; repair storage and retry Stop."
  exit 0
fi
# Only the branch that actually ROUTED this Stop as a refusal may touch the note.
# Testing REVIEWER_DENIAL_STATUS instead would test "some branch happened to call
# the memoizing probe" — true today only because one branch can, so adding a
# probe call anywhere above for an unrelated message would silently start minting
# notes on the converged path, with every existing check still green. The flag
# says what the case was only implying.
# An `if` rather than `[ ... ] && ...`: the short-circuit form leaves a non-zero
# status on the false branch, which a later `set -e` would turn into an exit
# right before the block is emitted.
if [ "$REVIEWER_DENIAL_ROUTED" = "true" ]; then
  reviewer_denial_note
fi
emit_block "$REASON"
exit 0
