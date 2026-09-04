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
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"
TDD_STATE_FILE="$(tdd_state_file "$SESSION_ID")"

# Preflight the prompt envelope against both durable planes before consuming
# the one-shot ticket. A fully well-shaped but stale/conflicting envelope must
# be as byte-stable as a malformed one, so validation cannot happen after the
# claim transaction.
_tdd_state_storage_safe "$TDD_STATE_FILE" || exit 0
_tdd_path_safe "$TDD_STATE_FILE" regular "$(dirname "$TDD_STATE_FILE")" || exit 0
NATIVE_TDD_STATE_FILE="$(_tdd_native_project_path "$TDD_STATE_FILE")" || exit 0

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
CHAIN_TICKET_STATE="$(STATE_FILE="$NATIVE_TDD_STATE_FILE" SID="$SESSION_ID" node -e '
  try {
    const s = JSON.parse(require("fs").readFileSync(process.env.STATE_FILE, "utf8"));
    const mine = s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`;
    // These conjuncts mirror `_tdd_consume_review_ticket_critical` and
    // `_tdd_review_ticket_shape_ok`, and the set is NOT decoration: a predicate
    // WEAKER than the claim arms a disclosure whose remedy the claim then
    // refuses, so the model re-spawns correctly and is stranded anyway.
    const live = mine && s.active === true && s.implComplete === true
      && s.chainDone === false && s.codeReviewDone === false
      && typeof s.phase === "string" && Array.isArray(s.history)
      && Array.isArray(s.bypasses) && typeof s.vanilla === "boolean"
      && typeof s.selfReviewFixed === "boolean"
      && Number.isSafeInteger(s.reviewRound) && s.reviewRound >= 0
      && s.reviewRound < Number.MAX_SAFE_INTEGER;
    const ticket = typeof s.reviewTicket === "string"
      && /^[A-Za-z0-9_-]{1,96}$/.test(s.reviewTicket) ? s.reviewTicket : "";
    const outstanding = live && ticket !== "" && s.reviewTicketConsumed === false;
    process.stdout.write((outstanding ? "yes" : "no") + "\t" + (outstanding ? ticket : ""));
  } catch (_) { process.stdout.write("no\t"); }
' 2>/dev/null)"
CHAIN_TICKET_OUTSTANDING="${CHAIN_TICKET_STATE%%$'\t'*}"
OUTSTANDING_TICKET="${CHAIN_TICKET_STATE#*$'\t'}"
[ "$CHAIN_TICKET_OUTSTANDING" = "yes" ] || OUTSTANDING_TICKET=""

# A decline that leaves an outstanding ticket unconsumed is the state that
# stranded chains silently: the reviewer ran, the round was never recorded, and
# every later Stop asked for a review that could not be booked. Disclose it on
# the model-facing channel whenever the decline was decided by THIS session's
# own artifacts — the prompt text this session wrote, and its own workflow
# document, its own durable run record, or this hook's own inability to READ one
# of those. TWO classes stay silent, and stating one was the error an earlier
# spelling of this comment made — a partition that omits a member reads as a
# guarantee and is not one:
#   (1) the workspace-HOLDER read answering rc 0, the single foreign-state
#       question in this file. Disclosing there would answer "is a foreign run
#       holding this tree?" and turn this hook into an existence oracle, the
#       property `test-plan-payload-fallback.sh` F20/F32/F45c pin for the
#       sibling plan gate. Its FAILURE arm is not in this class and discloses.
#   (2) the ticket claim and every exit below it. Do NOT restate that as "a
#       concurrent delivery already recorded the round": that is only the COMMON
#       cause. `tdd_consume_review_ticket_context` also returns 1 on a
#       ticket-shape refusal, a missing `node`, and any lock or IO failure, and
#       those leave the chain stranded with nothing reported — a known gap, not
#       a proof. Below the claim the ticket is already consumed, so a silent
#       exit there does not strand the chain in the state this seam is about.
# ONE further bare `exit 0` exists and is deliberately outside both classes: the
# `else` arm of the standalone/bound split, for a `PROMPT_AUTOPILOT_KIND` that is
# neither value. The parse above emits only those two, so it is unreachable by
# construction — a defensive arm, not a third class. Named here because a reader
# counting `exit 0` finds it and a partition that ignores it reads as sloppy.
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
PROMPT_CONSUME_INTENT="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const prompt = j.tool_input && j.tool_input.prompt;
      if (typeof prompt !== "string") { process.stdout.write("no"); return; }
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
      const intent = prompt.split(/\r?\n/)[0] === "PRE-MERGED FINDINGS (fan-out)";
      process.stdout.write(intent ? "yes" : "no");
    } catch (_) { process.stdout.write("no"); }
  });
' <<<"$INPUT" 2>/dev/null)"

decline() {
  [ "$CHAIN_TICKET_OUTSTANDING" = "yes" ] || exit 0
  # Consume intent is the marker as the FIRST line, or a ticket that already
  # MATCHED. Only the second is unforgeable: a quotation cannot reproduce the
  # chain's live outstanding value, while the marker is ordinary text that this
  # repository itself renders at column 0 in the Stop block reason. Do NOT
  # restate this as "neither can be supplied by a chainless flow" — that was
  # asserted here and is false. What the line-0 requirement buys is that the
  # quoted copy has to be the prompt's opening line, which no chainless flow
  # produces; the residual is recorded rather than claimed away.
  [ "$PROMPT_CONSUME_INTENT" = "yes" ] || [ -n "${REVIEW_TICKET:-}" ] || exit 0
  # TWO remedies, selected by the caller, because one remedy for every cause is
  # worse than none. The re-spawn recipe is correct only where the PROMPT is
  # what was refused. Five gates refuse on DURABLE RUN STATE, and there a fresh
  # ticket plus a re-spawn reproduces byte-identical inputs to the same gate —
  # an unbounded loop, since this hook never blocks and the Stop cap therefore
  # never arbitrates it, while the rotation strands any spawn still in flight.
  local remedy
  if [ "${2:-respawn}" = runstate ]; then
    remedy="Do NOT issue a fresh review ticket and do NOT re-spawn: the prompt is not what was refused, so a re-spawn reproduces this decline exactly while rotating the ticket out from under any spawn still in flight. Resolve the durable run state first — read a fresh ${LOG_COMMAND} --autopilot-status, then finish or release that run, or repair the unreadable record under .zensu/state/ — and only then re-spawn with the ticket the chain already holds."
  else
    remedy="Re-spawn zensu:code-reviewer with a prompt whose FIRST line is exactly 'PRE-MERGED FINDINGS (fan-out)' and whose SECOND line is exactly 'REVIEW-TICKET: <the current ticket>'. Both lines, in that order: the reviewer agent enters consume mode only on that pair, and a prompt that satisfies this hook but not the agent still records the round while throwing the whole fan-out away, because the reviewer then re-reviews from scratch instead of consuming the merged findings. Mint a replacement by running: ${LOG_COMMAND} --review-ticket — that verb ISSUES a new ticket and ROTATES the outstanding one, it does not read the current value back, so run it only when no zensu:code-reviewer spawn is still in flight: a spawn already running carries the old value and can never be recorded afterwards. An Autopilot-bound chain must additionally carry exactly one each of ZENSU-DELEGATED-CALLER, AUTOPILOT-BINDING and AUTOPILOT-STAGE, unchanged; a STANDALONE chain must carry none of those three, not even quoted at the start of a line."
  fi
  printf '%s' "The zensu:code-reviewer subagent above finished, but its completion was NOT recorded against this session's review chain: ${1}. The chain still holds an unclaimed review ticket, so the Stop backstop will keep asking for a review and the chain cannot converge. ${remedy} Do NOT arm a new chain to work around this — that would grant a new review budget." | emit_post_context
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
  || decline "the prompt carried no \`REVIEW-TICKET: <ticket>\` line naming this chain's outstanding ticket"

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
' 2>/dev/null)" \
  || decline "this session's own workflow document did not validate as a chain the reviewer completion could be recorded against" runstate

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
      const collect = prefix => lines.filter(line => line.startsWith(prefix));
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
      const completeTriple = callers.length === 1
        && callers[0] === "ZENSU-DELEGATED-CALLER: autopilot"
        && !!binding && !!stage && Number(binding[2]) <= 999;
      if (process.env.EXPECT_BOUND !== "yes") {
        if (completeTriple) process.exit(3);
        process.stdout.write(["standalone", "-", "0", "-", "-"].join("\t"));
        return;
      }
      // A bound chain additionally refuses a team-review header. That conjunct
      // belongs HERE and not in `completeTriple`, which is also the spoof test.
      if (!completeTriple || reviewOps.length !== 0) process.exit(3);
      process.stdout.write(["bound", binding[1], binding[2], binding[3], stage[1]].join("\t"));
    } catch (_) { process.exit(3); }
  });
' <<<"$INPUT" 2>/dev/null)" \
  || decline "the Autopilot envelope in the prompt did not match this chain: a bound chain needs exactly one each of ZENSU-DELEGATED-CALLER / AUTOPILOT-BINDING / AUTOPILOT-STAGE and no team-review header, and a standalone chain must carry no complete envelope at all"
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
      # run for it. It does not: that case fails the worker check, arrives as
      # rc 2, and is refused by the outer unreadable arm, whose wording
      # deliberately names no owner.
      OUTER="$PREFLIGHT_OUTER" node -e '
      try {
        const s=JSON.parse(process.env.OUTER);
        process.exit(["DONE", "CANCELLED"].includes(s.stage) ? 0 : 1);
      } catch (_) { process.exit(2); }
      ' 2>/dev/null
      case "$?" in
        0) ;;
        1) decline "this session's own durable Autopilot run is still live, so a standalone claim cannot be recorded against it" runstate ;;
        *) decline "a durable Autopilot run record in this project could not be read, so a standalone claim cannot be judged against it" runstate ;;
      esac
      ;;
    1) ;;
    *) decline "a durable Autopilot run record in this project could not be read, so a standalone claim cannot be judged against it" runstate ;;
  esac
  # And: is anyone ELSE holding the working tree right now? Arming happens once,
  # at `tdd_begin_session`; this hook runs on every qualifying PostToolUse. A
  # durable run begun in this tree AFTER the chain armed is therefore refused by
  # the arm-time gate no longer, and by the owner-scoped read above never — a
  # window this preflight covered project-wide before it was narrowed. The
  # question is owner-independent, so it needs the owner-independent read.
  # rc 0 is a refusal exactly as the arm-time gate treats it, and anything that
  # is not a clean "free" fails closed.
  # rc 0 is the one FOREIGN-state answer in this file and stays SILENT: the
  # message's mere presence would answer "is another session's run holding this
  # tree?", the existence-oracle property `test-plan-payload-fallback.sh`
  # F20/F32/F45c pin for the sibling plan gate. A read that FAILED is a
  # different question — it reports this hook's own inability to look and
  # confirms nothing about anyone else — so it discloses.
  if autopilot_read_workspace "$PROJECT_ROOT" >/dev/null 2>&1; then
    exit 0
  else
    PREFLIGHT_WORKSPACE_RC=$?
    [ "$PREFLIGHT_WORKSPACE_RC" -eq 1 ] \
      || decline "whether a durable Autopilot run holds this working tree could not be read, so a standalone claim cannot be judged against it" runstate
  fi
elif [ "$PROMPT_AUTOPILOT_KIND" = bound ]; then
  [ "$PREFLIGHT_CONTEXT" != '{}' ] \
    || decline "the prompt carried a complete Autopilot envelope, but this session owns no active durable run to bind it to — drop the envelope for a standalone chain, or read a fresh --autopilot-status and rebuild it from a run this session owns"
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
    || decline "the Autopilot envelope in the prompt disagrees with this chain's own record — check run, attempt, chain and stage against a fresh --autopilot-status"
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"
  # `autopilot_read_active` is OWNER-SCOPED, so this is the caller's OWN durable
  # run record — not another session's. It therefore discloses like every other
  # own-artifact decline; only the owner-INDEPENDENT workspace read stays silent.
  PREFLIGHT_OUTER="$(autopilot_read_active "$PROJECT_ROOT" "$SESSION_ID" 2>/dev/null)" \
    || decline "a durable Autopilot run record in this project could not be read, so the bound claim cannot be judged against it" runstate
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
    ' 2>/dev/null \
    || decline "the prompt's Autopilot binding disagrees with this session's own durable run — resolve the run state first, because the gate above has already pinned the envelope to this chain's own record" runstate
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
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_ALL}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nInclude EVERY finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering (two exceptions: items annotated '[Panel-FP-neutralized — do not fix]' are judged false positives and items annotated '[Unverified — do not fix]' failed the Finding Verification Gate — never fix either). ${FIX_DONE_PHRASE}, log this round's '{step_id} IMPL completed — files: {list}' claims and re-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them (a fix round is where a no-op mechanical replacement hides; carry any EDIT NOT LANDED line verbatim into your status line and into whatever end-of-chain summary this session renders), then re-run the /zensu:tdd review sequence to re-verify: re-fan-out the five zensu:review-aspect agents, re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, re-run the /zensu:tdd Phase 6 step 4c Finding Verification Gate over THIS round's merged list when hooks.findingVerification is enabled (never carry a prior round's verification verdicts forward), then issue a FRESH one-shot ticket by running: ${LOG_COMMAND} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'.${AUTOPILOT_RESPAWN_PHRASE} ${IN_SCOPE_CLAUSE}The Stop-hook backstop enforces this, so do NOT end your turn first.${IN_SCOPE_EXCEPTION} Do NOT reuse a prior ticket. Do NOT mark the chain done in case B. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing all findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A)${WITHHOLD_STATUS_LINE}.${TAIL_DIRECTIVE}"
else
  MSG="STOP. The zensu:code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)' so they land in the final report, then ${CLOSE_PASS}\n\n(C) ANY Critical OR Important findings present — fix them YOURSELF IN THIS MAIN THREAD ${FIX_DISCIPLINE_CI}. Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed; buffer them in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. ${FIX_DONE_PHRASE}, log this round's '{step_id} IMPL completed — files: {list}' claims and re-run the /zensu:tdd Phase 6 step 5b Edit Landing Audit over them (a fix round is where a no-op mechanical replacement hides; carry any EDIT NOT LANDED line verbatim into your status line and into whatever end-of-chain summary this session renders), then re-run the /zensu:tdd review sequence to re-verify: re-fan-out the five zensu:review-aspect agents, re-merge, re-run the zensu:review-judge second pass when hooks.reviewJudge is enabled, re-run the /zensu:tdd Phase 6 step 4c Finding Verification Gate over THIS round's merged list when hooks.findingVerification is enabled (never carry a prior round's verification verdicts forward), then issue a FRESH one-shot ticket by running: ${LOG_COMMAND} --review-ticket; capture its non-empty stdout as <ticket>. Your NEXT action must be the Agent tool with subagent_type='zensu:code-reviewer' whose prompt starts with EXACTLY these two lines: 'PRE-MERGED FINDINGS (fan-out)' then 'REVIEW-TICKET: <ticket>'.${AUTOPILOT_RESPAWN_PHRASE} ${IN_SCOPE_CLAUSE}The Stop-hook backstop enforces this, so do NOT end your turn first.${IN_SCOPE_EXCEPTION} Do NOT reuse a prior ticket. Do NOT mark the chain done in case C. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing critical+important findings in-thread, then re-reviewing' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A)${WITHHOLD_STATUS_LINE}.${TAIL_DIRECTIVE}"
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"
EXPANDED_MSG="${EXPANDED_MSG}${AUTOPILOT_ENVELOPE_DIRECTIVE}"

printf '%s' "$EXPANDED_MSG" | emit_post_context
