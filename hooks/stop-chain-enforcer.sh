#!/bin/bash
# Stop hook — guarantees the post-implementation review chain runs to completion
# in the main-thread TDD model.
#
# In the old subagent model the reviewer auto-spawn was hook-enforced by the
# tdd-manager subagent's Agent-tool completion (post-tdd-review-delegate.sh).
# With TDD running in the MAIN thread that completion event no longer exists, so
# this Stop hook is the replacement hard backstop: it refuses to let the main
# agent end its turn while a TDD session has finished implementation
# (chain-state implComplete=true) but the review/auto-fix chain has not
# terminated (chainDone=true). Coordinates with post-review-tdd-delegate.sh,
# which sets chainDone at PASS / max-rounds.
#
# Activation: only when chain-state `active` is true for THIS session. Other
# sessions, non-TDD work, and plain CLI stop normally.
#
# Spawned-agent safety: only the genuine top-level interactive thread enforces
# the chain. Any spawned/orchestrated agent (Task/Agent reviewers AND Claude
# Code Workflow workers) is detected via the hook-input agent_id and stops
# normally — blocking a subagent would deadlock the review cycle (it cannot run
# the human-facing chain, and a nested agent() spawn throws).
#
# Deferred review: a spawned agent that finished implementation but could not
# run review itself records a project-scoped pending-review marker; the next
# interactive Stop adopts it as a review-only chain so the aggregate diff is
# reviewed once through the existing machinery.
#
# Escapes:
#   ZENSU_CHAIN=off                 -> never block
#   hooks.chainEnforcer=false       -> disable via ~/.zensu/config.json
#   stop-block budget exceeded      -> allow stop + stderr warning (anti-deadlock)

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled chainEnforcer || exit 0

command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

read_field() {
  PAYLOAD="$INPUT" FIELD="$1" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = j[process.env.FIELD];
      process.stdout.write(typeof v === "string" ? v : (typeof v === "boolean" ? String(v) : ""));
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
if [ "$(zensu_is_spawned_agent "$(zensu_hook_agent_id "$INPUT")" "$(zensu_hook_agent_type "$INPUT")")" = "true" ]; then
  exit 0
fi

SESSION_ID="$(read_field session_id)"
TRANSCRIPT_PATH=""
[ -z "$SESSION_ID" ] && TRANSCRIPT_PATH="$(read_field transcript_path)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(ZENSU_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" zensu_resolve_session_id "$SESSION_ID")"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Bypass ledger: the escape stays free, but while a TDD session is active the
# opt-out is recorded to chain state so the chain-end summary can surface it.
if [ "${ZENSU_CHAIN:-}" = "off" ]; then
  tdd_record_bypass "$SESSION_ID" ZENSU_CHAIN 2>/dev/null || true
  exit 0
fi

# An inactive session and a fully terminated prior generation may both adopt a
# newly queued deferred review. The claim is serialized project-wide by the
# pending marker lock; only one concurrent interactive session can seed it.
SESSION_ACTIVE="$(tdd_session_active "$STATE_FILE")"
SESSION_IMPL_COMPLETE="$(tdd_impl_complete "$STATE_FILE")"
SESSION_CHAIN_DONE="$(tdd_chain_done "$STATE_FILE")"
ADOPT_ELIGIBLE=false
if [ "$SESSION_ACTIVE" != "true" ]; then
  ADOPT_ELIGIBLE=true
elif [ "$SESSION_IMPL_COMPLETE" = "true" ] && [ "$SESSION_CHAIN_DONE" = "true" ]; then
  ADOPT_ELIGIBLE=true
fi

if [ "$ADOPT_ELIGIBLE" = "true" ]; then
  if zensu_tdd_strict_enabled; then VANILLA_SEED=false; else VANILLA_SEED=true; fi
  if tdd_adopt_pending_review "$SESSION_ID" "$VANILLA_SEED" "$(zensu_pending_review_ttl_hours)"; then
    SESSION_ACTIVE=true
    SESSION_IMPL_COMPLETE=true
    SESSION_CHAIN_DONE=false
  else
    ADOPT_RC=$?
    if [ "$ADOPT_RC" -eq 1 ]; then
      echo "zensu chain-enforcer: failed to claim/seed deferred-review chain-state for ${SESSION_ID}; pending review remains retryable." >&2
    fi
    # Eligibility was only a preflight read. A concurrent --tdd-begin may have
    # won the session CAS; re-read and enforce that new generation instead of
    # granting this Stop from stale state.
    SESSION_ACTIVE="$(tdd_session_active "$STATE_FILE")"
    SESSION_IMPL_COMPLETE="$(tdd_impl_complete "$STATE_FILE")"
    SESSION_CHAIN_DONE="$(tdd_chain_done "$STATE_FILE")"
    [ "$SESSION_ACTIVE" = "true" ] || exit 0
  fi
elif [ "$SESSION_ACTIVE" != "true" ]; then
  exit 0
fi
# Implementation not finished -> do not enforce the review chain yet (allow
# legit mid-TDD pauses; TDD progression itself is driven by the gate + skill).
[ "$(tdd_impl_complete "$STATE_FILE")" = "true" ] || exit 0
# Chain already terminated -> allow stop.
[ "$(tdd_chain_done "$STATE_FILE")" = "true" ] && exit 0

# Anti-deadlock budget: cap consecutive Stop-hook blocks so a stalled chain
# (agent never spawns the reviewer, chainDone never set) cannot loop forever.
MAX_ROUNDS="$(zensu_autofix_max_rounds)"
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5 ;; esac
CAP=$((MAX_ROUNDS + 3))
BLOCKS="$(tdd_increment_stop_budget "$SESSION_ID" 2>/dev/null)" || BLOCKS=1
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=1 ;; esac
if [ "$BLOCKS" -gt "$CAP" ]; then
  if ! tdd_release_pending_review_claim "$SESSION_ID" 2>/dev/null; then
    echo "zensu chain-enforcer: failed to release this session's deferred-review claim at the Stop cap; manual state repair may be required." >&2
  fi
  if [ "$(tdd_code_review_done "$STATE_FILE")" = "true" ]; then
    echo "zensu chain-enforcer: terminal self-review did not converge after ${BLOCKS} nudges (cap ${CAP}); allowing stop. Run /zensu:reset-review-limit to re-arm this ticket-bound review generation, or set ZENSU_CHAIN=off explicitly." >&2
  else
    echo "zensu chain-enforcer: review chain did not converge after ${BLOCKS} nudges (cap ${CAP}); allowing stop. This is a stalled pre-terminus chain, so /zensu:reset-review-limit is not applicable. Re-enter /zensu:tdd for the current task to start a fresh guarded chain, or set ZENSU_CHAIN=off explicitly." >&2
  fi
  exit 0
fi

# Two-stage terminus: once the code-reviewer chain has converged
# (codeReviewDone), the terminal self-review stage must run before chainDone.
# codeReviewDone is the persisted handoff decision made by the post-review hook;
# do not reinterpret it through a later selfReview config change. Generations
# that started with selfReview disabled close directly with chainDone instead.
# The self-review stage is itself a main-thread Skill, so no Agent-completion
# event fires for it — this Stop hook is its hard backstop too.
CODE_REVIEW_DONE="$(tdd_code_review_done "$STATE_FILE")"
LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
if [ "$CODE_REVIEW_DONE" = "true" ]; then
  SELF_REVIEW_TICKET="$(tdd_ensure_self_review_ticket "$SESSION_ID" 2>/dev/null)" || SELF_REVIEW_TICKET=""
  if _tdd_review_ticket_shape_ok "$SELF_REVIEW_TICKET"; then
    SELF_REVIEW_TICKET_Q="$(printf '%q' "$SELF_REVIEW_TICKET")"
    REASON="STOP intercepted by zensu chain-enforcer. The code-reviewer chain has converged (codeReviewDone) but the terminal self-review stage has not run. Carry this exact generation line into the skill: 'SELF-REVIEW-TICKET: ${SELF_REVIEW_TICKET}'. Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — it performs a final critical self-reflection over this session's changes, takes at most one fix round under the still-active TDD phase-gate, and OWNS the generation-bound chain terminus (it runs: bash ${LOG_HELPER_Q} --chain-done --claimed-review-ticket ${SELF_REVIEW_TICKET_Q}). Do NOT end your turn, do NOT re-run the reviewer agent, and do NOT run an unqualified --chain-done yourself — let /zensu:self-review finalize only this chain generation."
  else
    REASON="STOP intercepted by zensu chain-enforcer. The state says codeReviewDone=true, but no valid consumed review ticket can bind the terminal self-review generation. Do NOT run self-review or an unqualified terminus. Run /zensu:reset-review-limit for this current session, then resume the reviewer chain with a fresh ticket."
  fi
else
  REASON="STOP intercepted by zensu chain-enforcer. A main-thread TDD session finished implementation (or a fix round) but the zensu:code-reviewer chain has not completed. Resume the /zensu:tdd Phase 6 review sequence where it left off: fan out the five zensu:review-aspect agents over the changed files ('git diff --name-only HEAD'), merge their findings in-thread, run the zensu:review-judge second pass when hooks.reviewJudge is enabled (the default), issue a fresh review ticket, then your NEXT action MUST be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with 'PRE-MERGED FINDINGS (fan-out)' and a second line 'REVIEW-TICKET: <ticket>' followed by the merged findings + build/test status. Do NOT end your turn, and do NOT fix anything inline first — the post-review hook routes findings back to you and sets chain completion on PASS or max rounds. Only valid exception: if implementation produced ZERO file changes, run: bash ${LOG_HELPER_Q} --chain-done; then stop."
fi

node -e 'process.stdout.write(JSON.stringify({ decision: "block", reason: process.argv[1] }))' "$REASON"
echo
# This also re-acknowledges an already-seeded claim after a prior Stop process
# died before emitting its handoff. The helper is owner/session-bound, so this
# is a no-op for ordinary TDD sessions and for another session's live claim.
tdd_mark_pending_review_handoff "$SESSION_ID" 2>/dev/null || true
exit 0
