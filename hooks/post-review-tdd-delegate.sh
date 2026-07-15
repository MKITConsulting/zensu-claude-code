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
# Counter state lives at ${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json. claude-code's auto-set CLAUDE_PLUGIN_DATA is intentionally IGNORED (use CLAUDE_PLUGIN_DATA_OVERRIDE to relocate).

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
AUTO_FIX_ON=1
zensu_hook_enabled autoFix || AUTO_FIX_ON=0

INPUT="$(cat)"

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
TRANSCRIPT_PATH=""
if [ -z "$SESSION_ID" ]; then
  TRANSCRIPT_PATH="$(node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        const tp = j.transcript_path;
        console.log((typeof tp === "string") ? tp : "");
      } catch (_) { console.log(""); }
    });
  ' <<<"$INPUT" 2>/dev/null)"
fi
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(ZENSU_TRANSCRIPT_PATH="$TRANSCRIPT_PATH" zensu_resolve_session_id "$SESSION_ID")"

# Mode-aware fix discipline: the per-session `vanilla` flag was frozen into the
# state file by `--tdd-begin`. Read the STATE flag (never live config) so the
# fix-round directive matches the discipline the session actually runs under.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
TDD_STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Validate the public counter location before claiming the ticket. A hostile
# symlink must remain a total no-op rather than consuming the one-shot event and
# stranding the chain.
STATE_DIR="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
COUNTER_FILE="$STATE_DIR/rounds-${SESSION_ID}.json"
if ! _tdd_path_safe "$STATE_DIR" directory "$STATE_DIR" \
    || ! _tdd_path_safe "$COUNTER_FILE" regular-or-absent "$STATE_DIR"; then
  echo "zensu post-review hook: refusing unsafe counter storage at $COUNTER_FILE — counter NOT updated" >&2
  exit 0
fi

# Claim the one-shot ticket, increment its round, and capture the exact
# fully-validated Autopilot binding from the same locked state read. There is no
# post-claim linkage reread: partial linkage fails before state/counter mutation,
# while a concurrent generation reset makes every later bound CAS stale.
CLAIM_CONTEXT="$(tdd_consume_review_ticket_context \
  "$SESSION_ID" "$REVIEW_TICKET" "$COUNTER_FILE")" || exit 0
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
AUTOPILOT_BINDING_LINE=""
if [ "$AUTOPILOT_KIND" = bound ]; then
  AUTOPILOT_BOUND=true
  AUTOPILOT_RUN_Q="$(printf '%q' "$AUTOPILOT_RUN")"
  AUTOPILOT_ATTEMPT_Q="$(printf '%q' "$AUTOPILOT_ATTEMPT")"
  AUTOPILOT_CHAIN_Q="$(printf '%q' "$AUTOPILOT_CHAIN")"
  AUTOPILOT_BOUND_ARGS=" --autopilot-run ${AUTOPILOT_RUN_Q} --autopilot-attempt ${AUTOPILOT_ATTEMPT_Q} --chain-id ${AUTOPILOT_CHAIN_Q}"
  AUTOPILOT_BINDING_LINE=" Carry this exact generation line into self-review: 'AUTOPILOT-BINDING: run=${AUTOPILOT_RUN} attempt=${AUTOPILOT_ATTEMPT} chain=${AUTOPILOT_CHAIN}'."
elif [ "$AUTOPILOT_KIND" != standalone ]; then
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

BYPASSES="$(tdd_bypasses "$(tdd_state_file "$SESSION_ID")" 2>/dev/null)"
[ -z "$BYPASSES" ] && BYPASSES="none"
BYPASS_DIRECTIVE=$'\n\nBypass ledger (from chain state): in the ## Open section include the literal line: Gates bypassed during this session: '"$BYPASSES"

COMBINED_SUMMARY_DIRECTIVE=""
if zensu_combined_summary_enabled; then
  COMBINED_SUMMARY_DIRECTIVE=$'\n\nAfter your status line, produce a CHAIN-END SUMMARY in narrative form with these sections IN THIS ORDER (pull data from your own main-thread TDD execution and the prior zensu:code-reviewer Agent results in your context, do NOT re-spawn agents). The TL;DR comes LAST:\n\n## Problem\nIn plain words: the feature, bug, or need this session addressed — why the work happened.\n\n## What I built\nNumbered deliverables. For each: what it does in plain words, its status (done / merged / built-tested), and a PR link if one exists. Carry the audit facts here: feature title, files modified, tests created, build status (passed / skipped / failed), mtime audit verdict, coverage status. Cite the plan + log file paths. When the session plan carries a ## Requirements table, also give per-requirement status keyed by its stable IDs (AC-###/FR-###: met / partial / dropped).\n\n## How I built it\nThe method and the review trail. State the TDD discipline followed, then the final zensu:code-reviewer verdict (PASS / PASS with suggestions / max-rounds reached) with findings count by severity and files reviewed. Then the auto-fix history: list EVERY review round 1..N — including rounds that fixed nothing. For each round give the round number and either the findings fixed in-thread (what changed, what remains), OR — for a verification round with no findings — mark it explicitly as PASS — 0 findings, nothing to fix. Always include the final clean verification round so the reader sees the chain converged with every finding addressed. At least one review round always ran.\n\n## Open\nWhat is left: any deferred suggestions (the buffered ### Suggestions block) or max-rounds findings requiring manual fix, plus the next step. If nothing is open, say so in one line.\n\n## TL;DR\nExactly ONE sentence, and it MUST be the last section: what shipped and the test verdict.'
fi

# When the self-review terminal stage is enabled, the code-reviewer chain hands
# off to /zensu:self-review (a main-thread Skill) instead of closing here:
# self-review owns the chain terminus (--chain-done) and renders the report.
SELF_REVIEW_ON=0
if zensu_hook_enabled selfReview; then SELF_REVIEW_ON=1; fi
LOG_HELPER_Q="$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh")"
REVIEW_TICKET_Q="$(printf '%q' "$REVIEW_TICKET")"

if [ "$SELF_REVIEW_ON" = "1" ]; then
  CLOSE_PASS="run this ticket-bound command: bash ${LOG_HELPER_Q} --code-review-done --claimed-review-ticket ${REVIEW_TICKET_Q}. Only if it exits 0, your VERY NEXT action must be the Skill tool with skill='zensu:self-review'. Carry this exact generation line into that skill: 'SELF-REVIEW-TICKET: ${REVIEW_TICKET}'.${AUTOPILOT_BINDING_LINE} The terminal self-review owns the chain terminus and renders the final CHAIN-END SUMMARY. If the command fails, this completion is stale: do NOT invoke self-review, do NOT mutate chain state, and resume the current chain instead. Do NOT close the chain yourself, do NOT render the summary here, and do NOT end your turn — self-review finalizes the matching generation."
  TAIL_DIRECTIVE=""
else
  CLOSE_PASS="close only this review generation by running: bash ${LOG_HELPER_Q} --chain-done${AUTOPILOT_BOUND_ARGS} --claimed-review-ticket ${REVIEW_TICKET_Q}. Stop only if it exits 0; on failure this completion is stale, so leave the current chain untouched and resume it."
  TAIL_DIRECTIVE="${COMBINED_SUMMARY_DIRECTIVE}${BYPASS_DIRECTIVE}"
fi

if [ "$AUTO_FIX_ON" = "0" ]; then
  DISABLED_MSG="Auto-fix is disabled for this ticket-bound review completion. Do NOT modify findings automatically and do NOT spawn another reviewer loop. Report the reviewer verdict and all findings unchanged, then ${CLOSE_PASS}"
  node -e '
    process.stdout.write(JSON.stringify({hookSpecificOutput:{
      hookEventName:"PostToolUse", additionalContext:process.argv[1]
    }}));
  ' "$DISABLED_MSG"
  echo
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
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The code-reviewer chain is marked converged (codeReviewDone). Do NOT spawn zensu:code-reviewer again and do NOT keep fixing its findings. Your VERY NEXT action MUST be the Skill tool with skill='zensu:self-review' — the terminal self-review stage. Carry this exact generation line into it: 'SELF-REVIEW-TICKET: ${REVIEW_TICKET}'.${AUTOPILOT_BINDING_LINE} Carry the remaining reviewer findings forward under '### Findings (max rounds reached, manual fix required)' so they land in the final report. /zensu:self-review owns the ticket-bound chain terminus and renders the final summary — do NOT close the chain yourself. To grant another reviewer budget instead of finalizing, the user can invoke the /zensu:reset-review-limit skill."
  else
    if [ "$AUTOPILOT_BOUND" = "true" ]; then
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --session "$SESSION_ID" \
        --autopilot-run "$AUTOPILOT_RUN" --autopilot-attempt "$AUTOPILOT_ATTEMPT" \
        --chain-id "$AUTOPILOT_CHAIN" --claimed-review-ticket "$REVIEW_TICKET" \
        --outcome max-rounds >/dev/null 2>&1 || exit 0
    else
      tdd_mark_review_converged "$SESSION_ID" "$REVIEW_TICKET" chainDone || exit 0
    fi
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The review chain is now marked complete (chainDone) so you MAY end your turn. Do NOT spawn zensu:code-reviewer again and do NOT keep fixing. Reply with the remaining findings under '### Findings (max rounds reached, manual fix required)' and stop. To grant another budget and resume the review/fix cycle in this same session, the user can invoke the /zensu:reset-review-limit skill — surface this hint at the end of your reply so the user knows the escape hatch exists.${COMBINED_SUMMARY_DIRECTIVE}${BYPASS_DIRECTIVE}"
  fi
  node -e '
    const msg = process.argv[1];
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: msg
      }
    }));
  ' "$CONV_MSG"
  echo
  exit 0
fi

if zensu_autofix_include_suggestions; then
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_ALL}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nInclude EVERY finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering (one exception: items annotated '[Panel-FP-neutralized — do not fix]' are judged false positives — never fix those). ${FIX_DONE_PHRASE}, re-run the /zensu:tdd review sequence to re-verify: re-fan-out the five zensu:review-aspect agents, re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, then issue a FRESH one-shot ticket by running: bash ${LOG_HELPER_Q} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'. The Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT reuse a prior ticket. Do NOT mark the chain done in case B. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing all findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
else
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)' so they land in the final report, then ${CLOSE_PASS}\n\n(C) ANY Critical OR Important findings present — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_CI}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed; buffer them in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. ${FIX_DONE_PHRASE}, re-run the /zensu:tdd review sequence to re-verify: re-fan-out the five zensu:review-aspect agents, re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, then issue a FRESH one-shot ticket by running: bash ${LOG_HELPER_Q} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'. The Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT reuse a prior ticket. Do NOT mark the chain done in case C. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing critical+important findings in-thread, then re-reviewing' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"

node -e '
  const msg = process.argv[1];
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: msg
    }
  }));
' "$EXPANDED_MSG"
echo
