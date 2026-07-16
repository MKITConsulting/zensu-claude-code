#!/bin/bash
# Stop hook — guarantees the post-implementation review chain runs to completion
# in the main-thread TDD model.
#
# TDD runs in the MAIN thread, so this Stop hook is the hard backstop: it refuses to let the main
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

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
  echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
  exit 2
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT
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
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")" || exit 0
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Bypass ledger: the escape stays free, but while a TDD session is active the
# opt-out is recorded to chain state so the chain-end summary can surface it.
if [ "${ZENSU_CHAIN:-}" = "off" ]; then
  tdd_record_bypass "$SESSION_ID" ZENSU_CHAIN 2>/dev/null || true
  exit 0
fi

# Corrupt workflow state cannot prove that the session is inactive, that
# implementation never completed, or that the review chain reached its
# terminus. Block before reading any flags; unlike the ordinary chain nudge,
# this integrity failure is not released by the stop-block budget.
stop_on_invalid_state() {
  REASON="STOP intercepted by zensu chain-enforcer because the existing session-state file is invalid or unreadable (${STATE_FILE}). Its active/implComplete/chainDone flags cannot be trusted, so Stop and the chain terminus fail closed. Start a fresh Claude Code session so Session Control v1 creates new state; use ZENSU_CHAIN=off only as an explicit, reviewed recovery escape."
  node -e 'process.stdout.write(JSON.stringify({ decision: "block", reason: process.argv[1] }))' "$REASON"
  echo
  exit 0
}

# Not active: either stop normally, or adopt a pending-review marker as a
# review-only chain for THIS interactive session (deferred review fallback).
STATE_STATUS="$(tdd_state_status "$STATE_FILE")"
if [ "$STATE_STATUS" = "missing" ]; then
  ACTIVATION_STATUS="$(tdd_activation_status "$SESSION_ID")"
  case "$ACTIVATION_STATUS" in active|invalid) stop_on_invalid_state ;; esac
fi
ACTIVE_STATE="$(tdd_session_active "$STATE_FILE")"
[ "$ACTIVE_STATE" = "invalid" ] && stop_on_invalid_state
if [ "$ACTIVE_STATE" != "true" ]; then
  PENDING_FILE="$(zensu_pending_review_file)"
  if [ -n "$PENDING_FILE" ] && [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ]; then
    if [ "$(tdd_pending_review_stale "$(zensu_pending_review_ttl_hours)")" = "true" ]; then
      tdd_clear_pending_review >/dev/null 2>&1 || true
      exit 0
    fi
    if zensu_tdd_strict_enabled; then VANILLA_SEED=false; else VANILLA_SEED=true; fi
    if tdd_seed_deferred_review "$SESSION_ID" "$VANILLA_SEED"; then
      tdd_clear_pending_review >/dev/null 2>&1 || true
    else
      echo "zensu chain-enforcer: failed to seed deferred-review chain-state for ${SESSION_ID}; leaving pending-review marker for retry." >&2
      exit 0
    fi
  else
    exit 0
  fi
fi
# Implementation not finished -> do not enforce the review chain yet (allow
# legit mid-TDD pauses; TDD progression itself is driven by the gate + skill).
IMPL_COMPLETE_STATE="$(tdd_impl_complete "$STATE_FILE")"
[ "$IMPL_COMPLETE_STATE" = "invalid" ] && stop_on_invalid_state
[ "$IMPL_COMPLETE_STATE" = "true" ] || exit 0
# Chain already terminated -> allow stop.
CHAIN_DONE_STATE="$(tdd_chain_done "$STATE_FILE")"
[ "$CHAIN_DONE_STATE" = "invalid" ] && stop_on_invalid_state
[ "$CHAIN_DONE_STATE" = "true" ] && exit 0

# Anti-deadlock budget: cap consecutive Stop-hook blocks so a stalled chain
# (agent never spawns the reviewer, chainDone never set) cannot loop forever.
MAX_ROUNDS="$(zensu_autofix_max_rounds)"
case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=5 ;; esac
CAP=$((MAX_ROUNDS + 3))
BLOCKS="$(tdd_increment_counter "$SESSION_ID" stopBlocks)" || stop_on_invalid_state
case "$BLOCKS" in ''|*[!0-9]*) stop_on_invalid_state ;; esac
if [ "$BLOCKS" -gt "$CAP" ]; then
  [ "$(tdd_state_status "$STATE_FILE")" = "invalid" ] && stop_on_invalid_state
  echo "zensu chain-enforcer: review chain did not converge after ${BLOCKS} nudges (cap ${CAP}); allowing stop. Run /zensu:reset-review-limit and re-spawn zensu:code-reviewer to continue, or set ZENSU_CHAIN=off." >&2
  exit 0
fi

# Two-stage terminus: once the code-reviewer chain has converged
# (codeReviewDone), the terminal self-review stage must run before chainDone.
# The self-review stage is itself a main-thread Skill, so no Agent-completion
# event fires for it — this Stop hook is its hard backstop too.
CODE_REVIEW_DONE="$(tdd_code_review_done "$STATE_FILE")"
[ "$CODE_REVIEW_DONE" = "invalid" ] && stop_on_invalid_state
if zensu_hook_enabled selfReview && [ "$CODE_REVIEW_DONE" = "true" ]; then
  REASON="STOP intercepted by zensu chain-enforcer. The code-reviewer chain has converged (codeReviewDone) but the terminal self-review stage has not run. Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — it performs a final critical self-reflection over this session's changes, takes at most one fix round under the still-active TDD phase-gate, and OWNS the chain terminus (it runs 'bash \"\${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/hooks/lib/zensu-log.sh\" --chain-done'). Do NOT end your turn, do NOT re-run the reviewer agent, and do NOT run --chain-done yourself — let /zensu:self-review finalize the chain."
else
  REASON="STOP intercepted by zensu chain-enforcer. A main-thread TDD session finished implementation (or a fix round) but the zensu:code-reviewer chain has not completed. Resume the /zensu:tdd Phase 6 review sequence where it left off: fan out the five zensu:review-aspect agents over the changed files ('git diff --name-only HEAD'), merge their findings in-thread, run the zensu:review-judge second pass when hooks.reviewJudge is enabled (the default), then your NEXT action MUST be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt begins with the marker line 'PRE-MERGED FINDINGS (fan-out)' followed by the merged findings + build/test status. Do NOT end your turn, and do NOT fix anything inline first — the post-review hook routes findings back to you and sets chain completion on PASS or max rounds. Only valid exception: if implementation produced ZERO file changes, run 'bash \"\${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/hooks/lib/zensu-log.sh\" --chain-done' and then stop."
fi

node -e 'process.stdout.write(JSON.stringify({ decision: "block", reason: process.argv[1] }))' "$REASON"
echo
exit 0
