#!/bin/bash
# PostToolUse hook fired when the Agent (code-reviewer) tool completes.
# Routes only the consume-mode `zensu:code-reviewer` completion belonging to a
# live, implementation-complete TDD review chain. Every other Agent completion
# is a total no-op: it cannot read or mutate the auto-fix counter or chain state.
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
INPUT="$(cat)"
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

PROMPT_HEADER="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const prompt = j.tool_input && j.tool_input.prompt;
      const lines = typeof prompt === "string" ? prompt.split(/\r?\n/) : [];
      process.stdout.write((lines[0] || "") + "\n" + (lines[1] || ""));
    } catch (_) { process.stdout.write("\n"); }
  });
' <<<"$INPUT" 2>/dev/null)"
PROMPT_FIRST_LINE="${PROMPT_HEADER%%$'\n'*}"
if [ "$PROMPT_FIRST_LINE" = "$PROMPT_HEADER" ]; then
  PROMPT_SECOND_LINE=""
else
  PROMPT_SECOND_LINE="${PROMPT_HEADER#*$'\n'}"
fi

# This marker is emitted only by /zensu:tdd after the read-only review fan-out.
# Requiring it on the first line prevents an unrelated standalone reviewer from
# consuming stale state that happens to share the same Claude session.
[ "$PROMPT_FIRST_LINE" = "PRE-MERGED FINDINGS (fan-out)" ] || exit 0
case "$PROMPT_SECOND_LINE" in
  "REVIEW-TICKET: "*) REVIEW_TICKET="${PROMPT_SECOND_LINE#REVIEW-TICKET: }" ;;
  *) exit 0 ;;
esac

# The consume-mode reviewer prompt is either truly standalone (no durable
# envelope at all) or carries one complete official Autopilot envelope. Parse
# and reject partial, duplicate, malformed, conflicting, or team-review-only
# headers before reading or claiming any chain/counter state.
PROMPT_ENVELOPE_FIELDS="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const input = JSON.parse(s);
      const prompt = input.tool_input && input.tool_input.prompt;
      if (typeof prompt !== "string") process.exit(3);
      const lines = prompt.split(/\r?\n/);
      const collect = prefix => lines.filter(line => line.startsWith(prefix));
      const callers = collect("ZENSU-DELEGATED-CALLER:");
      const bindings = collect("AUTOPILOT-BINDING:");
      const stages = collect("AUTOPILOT-STAGE:");
      const reviewOps = collect("AUTOPILOT-REVIEW-OP:");
      const total = callers.length + bindings.length + stages.length + reviewOps.length;
      if (total === 0) {
        process.stdout.write(["standalone", "-", "0", "-", "-"].join("\t"));
        return;
      }
      if (callers.length !== 1 || bindings.length !== 1 || stages.length !== 1
          || reviewOps.length !== 0 || callers[0] !== "ZENSU-DELEGATED-CALLER: autopilot"
          || lines[2] !== callers[0] || lines[3] !== bindings[0] || lines[4] !== stages[0]) {
        process.exit(3);
      }
      const binding = /^AUTOPILOT-BINDING: run=([A-Za-z0-9][A-Za-z0-9_.:-]{2,127}) attempt=([1-9][0-9]{0,2}) chain=([A-Za-z0-9][A-Za-z0-9_.:-]{2,127})$/.exec(bindings[0]);
      const stage = /^AUTOPILOT-STAGE: (GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER)$/.exec(stages[0]);
      if (!binding || !stage || Number(binding[2]) > 999) process.exit(3);
      process.stdout.write(["bound", binding[1], binding[2], binding[3], stage[1]].join("\t"));
    } catch (_) { process.exit(3); }
  });
' <<<"$INPUT" 2>/dev/null)" || exit 0
IFS=$'\t' read -r PROMPT_AUTOPILOT_KIND PROMPT_AUTOPILOT_RUN \
  PROMPT_AUTOPILOT_ATTEMPT PROMPT_AUTOPILOT_CHAIN PROMPT_AUTOPILOT_STAGE \
  <<<"$PROMPT_ENVELOPE_FIELDS"

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
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
TDD_STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Preflight the prompt envelope against both durable planes before consuming
# the one-shot ticket. A fully well-shaped but stale/conflicting envelope must
# be as byte-stable as a malformed one, so validation cannot happen after the
# claim transaction.
_tdd_state_storage_safe "$TDD_STATE_FILE" || exit 0
_tdd_path_safe "$TDD_STATE_FILE" regular "$(dirname "$TDD_STATE_FILE")" || exit 0
NATIVE_TDD_STATE_FILE="$(_tdd_native_project_path "$TDD_STATE_FILE")" || exit 0
PREFLIGHT_CONTEXT="$(STATE_FILE="$NATIVE_TDD_STATE_FILE" SID="$SESSION_ID" node -e '
  try {
    const fs=require("fs"),s=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8"));
    const keys=["autopilotRunId","autopilotAttempt","autopilotReturnStage","chainId","chainOutcome"];
    const count=keys.filter(key => Object.prototype.hasOwnProperty.call(s,key)).length;
    if(count===0){process.stdout.write("{}");process.exit(0);}
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
  } catch (_) { process.exit(3); }
' 2>/dev/null)" || exit 0
if [ "$PROMPT_AUTOPILOT_KIND" = standalone ]; then
  [ "$PREFLIGHT_CONTEXT" = '{}' ] || exit 0
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
      OUTER="$PREFLIGHT_OUTER" node -e '
      try {
        const s=JSON.parse(process.env.OUTER);
        process.exit(["DONE", "CANCELLED"].includes(s.stage) ? 0 : 1);
      } catch (_) { process.exit(2); }
      ' 2>/dev/null || exit 0
      ;;
    1) ;;
    *) exit 0 ;;
  esac
  # And: is anyone ELSE holding the working tree right now? Arming happens once,
  # at `tdd_begin_session`; this hook runs on every qualifying PostToolUse. A
  # durable run begun in this tree AFTER the chain armed is therefore refused by
  # the arm-time gate no longer, and by the owner-scoped read above never — a
  # window this preflight covered project-wide before it was narrowed. The
  # question is owner-independent, so it needs the owner-independent read.
  # rc 0 is a refusal exactly as the arm-time gate treats it, and anything that
  # is not a clean "free" fails closed.
  if autopilot_read_workspace "$PROJECT_ROOT" >/dev/null 2>&1; then
    exit 0
  else
    PREFLIGHT_WORKSPACE_RC=$?
    [ "$PREFLIGHT_WORKSPACE_RC" -eq 1 ] || exit 0
  fi
elif [ "$PROMPT_AUTOPILOT_KIND" = bound ]; then
  [ "$PREFLIGHT_CONTEXT" != '{}' ] || exit 0
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
    ' 2>/dev/null || exit 0
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
  PREFLIGHT_OUTER="$(autopilot_read_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)" || exit 0
  OUTER="$PREFLIGHT_OUTER" SID="$SESSION_ID" RUN_ID="$PROMPT_AUTOPILOT_RUN" \
    ATTEMPT="$PROMPT_AUTOPILOT_ATTEMPT" CHAIN_ID="$PROMPT_AUTOPILOT_CHAIN" \
    RETURN_STAGE="$PROMPT_AUTOPILOT_STAGE" node -e '
      try {
        const s=JSON.parse(process.env.OUTER),t=s.tdd;
        const exact=s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
          && s.stage==="TDD_RUNNING" && s.nextActionCode==="AWAIT_TDD_CHAIN" && t
          && t.sessionId===process.env.SID && String(t.attempt)===process.env.ATTEMPT
          && t.chainId===process.env.CHAIN_ID && t.returnStage===process.env.RETURN_STAGE
          && t.outcome===null;
        process.exit(exact?0:3);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null || exit 0
else
  exit 0
fi

# Claim the one-shot ticket, increment its round, and capture the exact
# fully-validated Autopilot binding from the same locked state read. There is no
# post-claim linkage reread: partial linkage fails before state/counter mutation,
# while a concurrent generation reset makes every later bound CAS stale.
CLAIM_CONTEXT="$(tdd_consume_review_ticket_context \
  "$SESSION_ID" "$REVIEW_TICKET")" || exit 0
CLAIM_FIELDS="$(CLAIM_CONTEXT="$CLAIM_CONTEXT" node -e '
  try {
    const value = JSON.parse(process.env.CLAIM_CONTEXT);
    const topKeys = Object.keys(value).sort().join(",");
    if (topKeys !== "autopilot,next" || !Number.isSafeInteger(value.next) || value.next < 1) {
      process.exit(3);
    }
    if (value.autopilot === null) {
      process.stdout.write([value.next, "standalone", "-", 0, "-", "-"].join("\t"));
      process.exit(0);
    }
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
  } catch (_) { process.exit(3); }
' 2>/dev/null)" || exit 0
IFS=$'\t' read -r NEXT AUTOPILOT_KIND AUTOPILOT_RUN AUTOPILOT_ATTEMPT \
  AUTOPILOT_RETURN_STAGE AUTOPILOT_CHAIN <<<"$CLAIM_FIELDS"
case "$NEXT" in ''|*[!0-9]*) exit 0 ;; esac

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
    && [ "$AUTOPILOT_CHAIN" = "$PROMPT_AUTOPILOT_CHAIN" ] || exit 0
  AUTOPILOT_BOUND=true
  AUTOPILOT_RUN_Q="$(printf '%q' "$AUTOPILOT_RUN")"
  AUTOPILOT_ATTEMPT_Q="$(printf '%q' "$AUTOPILOT_ATTEMPT")"
  AUTOPILOT_CHAIN_Q="$(printf '%q' "$AUTOPILOT_CHAIN")"
  AUTOPILOT_BOUND_ARGS=" --autopilot-run ${AUTOPILOT_RUN_Q} --autopilot-attempt ${AUTOPILOT_ATTEMPT_Q} --chain-id ${AUTOPILOT_CHAIN_Q}"
  AUTOPILOT_ENVELOPE_DIRECTIVE=$'\n\nOfficial Autopilot handoff envelope — append these three lines unchanged and exactly once after the required headers of every reviewer respawn and self-review invocation:\n'"ZENSU-DELEGATED-CALLER: autopilot"$'\n'"AUTOPILOT-BINDING: run=${AUTOPILOT_RUN} attempt=${AUTOPILOT_ATTEMPT} chain=${AUTOPILOT_CHAIN}"$'\n'"AUTOPILOT-STAGE: ${AUTOPILOT_RETURN_STAGE}"
  AUTOPILOT_CARRY_PHRASE=" Preserve the official three-line Autopilot envelope printed below unchanged and exactly once in the self-review invocation."
  AUTOPILOT_RESPAWN_PHRASE=" For every verification respawn, append the official three-line Autopilot envelope printed below unchanged and exactly once after REVIEW-TICKET."
elif [ "$AUTOPILOT_KIND" != standalone ]; then
  exit 0
elif [ "$PROMPT_AUTOPILOT_KIND" != standalone ]; then
  exit 0
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
  COMBINED_SUMMARY_DIRECTIVE=$'\n\nAfter your status line, produce a CHAIN-END SUMMARY. Render it as TABLES, not prose: every section below is a table plus at most one line of text, never a paragraph — the sole exception is ## Open, which ends with the bypass-ledger line and, when it applies, the converge offer. Keep it scannable — no restating, no narration of the process, no filler. Sections IN THIS ORDER, TL;DR LAST. Pull data from your own main-thread TDD execution and the prior zensu:code-reviewer Agent results in your context, do NOT re-spawn agents.\n\n## Problem\nExactly ONE sentence: the feature, bug, or need this session addressed.\n\n## What I built\nTable, columns: # | Deliverable | Status | Link. One row per deliverable, max 15 words per cell, Status is done / merged / built-tested, Link is a PR URL or an em dash.\nThen a second table, columns: Check | Verdict, with exactly these rows — Feature, Files modified, Tests created, Build, Mtime audit, Edit landing, Coverage, Plan, Log. Verdict cells are values, not sentences (passed, skipped, 12 files, a path). The Edit landing verdict carries the step 5b close marker plus any EDIT NOT LANDED line, and the UNVERIFIED (no claims logged) or unresolved PENDING PREDICATE close when either applies, VERBATIM in its cell — those are not clean states and must never be dropped, paraphrased, or shortened.\nWhen the session plan carries a ## Requirements table, add a third table, columns: ID | Status, keyed by its stable IDs (AC-###/FR-###: met / partial / dropped). One row per requirement, no commentary.\n\n## How I built it\nExactly ONE line: the TDD discipline followed, the final zensu:code-reviewer verdict (PASS / PASS with suggestions / max-rounds reached), the findings count by severity, and the number of files reviewed.\nThen a table, columns: Round | Findings | Fixed | Result. One row per review round 1..N including rounds that fixed nothing, whose Result cell reads PASS — 0 findings, nothing to fix. Always include the final clean verification round. At least one review round always ran.\n\n## Open\nTable, columns: Item | Type | Next step. One row per deferred suggestion (the buffered ### Suggestions block) or max-rounds finding requiring a manual fix. If nothing is open, write the single line: Nothing open.'"${CONVERGE_OFFER_DIRECTIVE}"$'\n\n## TL;DR\nExactly ONE sentence, and it MUST be the last section: what shipped and the test verdict.'
fi

# When the self-review terminal stage is enabled, the code-reviewer chain hands
# off to /zensu:self-review (a main-thread Skill) instead of closing here:
# self-review owns the chain terminus (--chain-done) and renders the report.
SELF_REVIEW_ON=0
if zensu_hook_enabled selfReview; then SELF_REVIEW_ON=1; fi
BYPASS_TAIL_DIRECTIVE="$BYPASS_DIRECTIVE_TRAILING"
[ -n "$COMBINED_SUMMARY_DIRECTIVE" ] && BYPASS_TAIL_DIRECTIVE="$BYPASS_DIRECTIVE"
LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
PLUGIN_DATA_Q="$(printf '%q' "${CLAUDE_PLUGIN_DATA:-}")"
LOG_COMMAND="CLAUDE_PLUGIN_DATA=${PLUGIN_DATA_Q} bash ${LOG_HELPER_Q}"
REVIEW_TICKET_Q="$(printf '%q' "$REVIEW_TICKET")"

if [ "$SELF_REVIEW_ON" = "1" ]; then
  CLOSE_PASS="run this ticket-bound command: ${LOG_COMMAND} --code-review-done --claimed-review-ticket ${REVIEW_TICKET_Q}. Only if it exits 0, your VERY NEXT action must be the Skill tool with skill='zensu:self-review'. Carry this exact generation line into that skill: 'SELF-REVIEW-TICKET: ${REVIEW_TICKET}'.${AUTOPILOT_CARRY_PHRASE} The terminal self-review owns the chain terminus and renders the final CHAIN-END SUMMARY. If the command fails, this completion is stale: do NOT invoke self-review, do NOT mutate chain state, and resume the current chain instead. Do NOT close the chain yourself, do NOT render the summary here, and do NOT end your turn — self-review finalizes the matching generation."
  TAIL_DIRECTIVE=""
else
  CLOSE_PASS="close only this review generation by running: ${LOG_COMMAND} --chain-done${AUTOPILOT_BOUND_ARGS} --claimed-review-ticket ${REVIEW_TICKET_Q}. Stop only if it exits 0; on failure this completion is stale, so leave the current chain untouched and resume it."
  TAIL_DIRECTIVE="${COMBINED_SUMMARY_DIRECTIVE}${BYPASS_TAIL_DIRECTIVE}"
fi

emit_post_context() {
  node -e '
    const msg = require("node:fs").readFileSync(0, "utf8");
    process.stdout.write(JSON.stringify({hookSpecificOutput:{
      hookEventName:"PostToolUse", additionalContext:msg
    }}));
  '
  echo
}

if [ "$AUTO_FIX_ON" = "0" ]; then
  DISABLED_MSG="Auto-fix is disabled for this ticket-bound review completion. Do NOT modify findings automatically and do NOT spawn another reviewer loop. Report the reviewer verdict and all findings unchanged, then ${CLOSE_PASS}"
  DISABLED_TAIL=""
  [ "$SELF_REVIEW_ON" = "0" ] && DISABLED_TAIL="${BYPASS_DIRECTIVE_TRAILING}"
  printf '%s' "${DISABLED_MSG}${DISABLED_TAIL}${AUTOPILOT_ENVELOPE_DIRECTIVE}" | emit_post_context
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
        "$REVIEW_TICKET" || exit 0
    else
      tdd_mark_review_converged "$SESSION_ID" "$REVIEW_TICKET" codeReviewDone || exit 0
    fi
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The code-reviewer chain is marked converged (codeReviewDone). Do NOT spawn zensu:code-reviewer again and do NOT keep fixing its findings. Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — the terminal self-review stage. Carry this exact generation line into it: 'SELF-REVIEW-TICKET: ${REVIEW_TICKET}'.${AUTOPILOT_CARRY_PHRASE} Carry the remaining reviewer findings forward under '### Findings (max rounds reached, manual fix required)' so they land in the final report. /zensu:self-review owns the ticket-bound chain terminus and renders the final summary — do NOT close the chain yourself. To grant another reviewer budget instead of finalizing, the user can invoke the /zensu:reset-review-limit skill."
  else
    if [ "$AUTOPILOT_BOUND" = "true" ]; then
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --session "$SESSION_ID" \
        --autopilot-run "$AUTOPILOT_RUN" --autopilot-attempt "$AUTOPILOT_ATTEMPT" \
        --chain-id "$AUTOPILOT_CHAIN" --claimed-review-ticket "$REVIEW_TICKET" \
        --outcome max-rounds >/dev/null 2>&1 || exit 0
    else
      tdd_mark_review_converged "$SESSION_ID" "$REVIEW_TICKET" chainDone || exit 0
    fi
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The review chain is now marked complete (chainDone) so you MAY end your turn. Do NOT spawn zensu:code-reviewer again and do NOT keep fixing. Reply with the remaining findings under '### Findings (max rounds reached, manual fix required)' and stop. To grant another budget and resume the review/fix cycle in this same session, the user can invoke the /zensu:reset-review-limit skill — surface this hint at the end of your reply so the user knows the escape hatch exists.${COMBINED_SUMMARY_DIRECTIVE}${BYPASS_TAIL_DIRECTIVE}"
  fi
  printf '%s' "${CONV_MSG}${AUTOPILOT_ENVELOPE_DIRECTIVE}" | emit_post_context
  exit 0
fi

if zensu_autofix_include_suggestions; then
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_ALL}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nInclude EVERY finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering (two exceptions: items annotated '[Panel-FP-neutralized — do not fix]' are judged false positives and items annotated '[Unverified — do not fix]' failed the Finding Verification Gate — never fix either). ${FIX_DONE_PHRASE}, log this round's '{step_id} IMPL completed — files: {list}' claims and re-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them (a fix round is where a no-op mechanical replacement hides; carry any EDIT NOT LANDED line verbatim into your status line and into whatever end-of-chain summary this session renders), then re-run the /zensu:tdd review sequence to re-verify: re-fan-out the five zensu:review-aspect agents, re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, re-run the /zensu:tdd Phase 6 step 4c Finding Verification Gate over THIS round's merged list when hooks.findingVerification is enabled (never carry a prior round's verification verdicts forward), then issue a FRESH one-shot ticket by running: ${LOG_COMMAND} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'.${AUTOPILOT_RESPAWN_PHRASE} The Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT reuse a prior ticket. Do NOT mark the chain done in case B. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing all findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
else
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)' so they land in the final report, then ${CLOSE_PASS}\n\n(C) ANY Critical OR Important findings present — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_CI}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed; buffer them in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. ${FIX_DONE_PHRASE}, log this round's '{step_id} IMPL completed — files: {list}' claims and re-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them (a fix round is where a no-op mechanical replacement hides; carry any EDIT NOT LANDED line verbatim into your status line and into whatever end-of-chain summary this session renders), then re-run the /zensu:tdd review sequence to re-verify: re-fan-out the five zensu:review-aspect agents, re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, re-run the /zensu:tdd Phase 6 step 4c Finding Verification Gate over THIS round's merged list when hooks.findingVerification is enabled (never carry a prior round's verification verdicts forward), then issue a FRESH one-shot ticket by running: ${LOG_COMMAND} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'.${AUTOPILOT_RESPAWN_PHRASE} The Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT reuse a prior ticket. Do NOT mark the chain done in case C. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing critical+important findings in-thread, then re-reviewing' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"
EXPANDED_MSG="${EXPANDED_MSG}${AUTOPILOT_ENVELOPE_DIRECTIVE}"

printf '%s' "$EXPANDED_MSG" | emit_post_context
