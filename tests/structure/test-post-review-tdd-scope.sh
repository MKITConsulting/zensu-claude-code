#!/bin/bash
# The code-reviewer completion hook is scoped to one live TDD review chain.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"

PASS=0
FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then
    echo "  PASS  $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $label"
    FAIL=$((FAIL + 1))
  fi
}

ROOT="$(mktemp -d -t zensu-postreview-scope-XXXXXX)"
ROOT="$(cd "$ROOT" && pwd -P)"
PROJECT="$ROOT/project"
mkdir -p "$PROJECT"
PROJECT="$(cd "$PROJECT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_CONFIG="$ROOT/no-config.json"
unset CLAUDE_PLUGIN_DATA ZENSU_PROJECT_ROOT ZENSU_SESSION_CONTEXT ZENSU_SESSION_KEY \
  ZENSU_TEST_PLUGIN_DATA 2>/dev/null || true

# shellcheck disable=SC1090
source "$PHASE"

MARKER='PRE-MERGED FINDINGS (fan-out)'
STARTED_SESSION_KEY=""

start_session() {
  local raw_session="$1" label="${2:-$1}"
  export ZENSU_TEST_PLUGIN_DATA="$ROOT/plugin-data-$label"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session"
  STARTED_SESSION_KEY="$ZENSU_SESSION_KEY"
}

log() {
  bash "$LOG" "$@" >/dev/null 2>/dev/null
}

issue_ticket() {
  bash "$LOG" --review-ticket --session "$1" 2>/dev/null
}

review_prompt() {
  printf '%s\nREVIEW-TICKET: %s\n%s' "$MARKER" "$1" "${2:-fixture}"
}

run_hook() {
  local sid="$1" subtype="$2" prompt="$3" payload_sid="$1"
  # Stateful helper calls may use the canonical key after model binding, but
  # Claude hook payloads always carry the raw host session id.
  if [ -n "${ZENSU_SESSION_KEY:-}" ] && [ "$sid" = "$ZENSU_SESSION_KEY" ]; then
    payload_sid="${CLAUDE_CODE_SESSION_ID:?native host session id unavailable}"
  fi
  SID="$payload_sid" SUBTYPE="$subtype" PROMPT="$prompt" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {subagent_type: process.env.SUBTYPE, prompt: process.env.PROMPT},
      session_id: process.env.SID
    }));
  ' | bash "$HOOK" 2>/dev/null
}

run_hook_as() {
  local sid="$1" subtype="$2" prompt="$3" principal_kind="$4" payload_sid="$1"
  if [ -n "${ZENSU_SESSION_KEY:-}" ] && [ "$sid" = "$ZENSU_SESSION_KEY" ]; then
    payload_sid="${CLAUDE_CODE_SESSION_ID:?native host session id unavailable}"
  fi
  SID="$payload_sid" SUBTYPE="$subtype" PROMPT="$prompt" PRINCIPAL_KIND="$principal_kind" node -e '
    const p={
      hook_event_name:"PostToolUse",
      tool_name:"Agent",
      tool_input:{subagent_type:process.env.SUBTYPE,prompt:process.env.PROMPT},
      session_id:process.env.SID,
    };
    if(process.env.PRINCIPAL_KIND==="reviewer")p.agent_type="zensu:code-reviewer";
    if(process.env.PRINCIPAL_KIND==="plm")p.agent_type="zensu:zensu-plm";
    if(process.env.PRINCIPAL_KIND==="neutral")p.agent_type="custom-agent";
    if(process.env.PRINCIPAL_KIND==="partial")p.agent_id="child-only";
    process.stdout.write(JSON.stringify(p));
  ' | ZENSU_FORCE_MAIN=1 bash "$HOOK" 2>/dev/null
}

state() {
  tdd_state_file "$1"
}

state_for_unstarted_raw_session() {
  local key
  key="$(node "$SESSION_CORE" session-key "$1")"
  printf '%s/.zensu/state/tdd-phase-%s.json' "$PROJECT" "$key"
}

digest() {
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
  ' "$1"
}

state_value() {
  FILE="$1" FIELD="$2" node -e '
    try {
      const value = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
      process.stdout.write(String(value[process.env.FIELD]));
    } catch (_) { process.stdout.write("invalid"); }
  '
}

ticket_consumed() {
  state_value "$(state "$1")" reviewTicketConsumed
}

review_round() {
  state_value "$(state "$1")" reviewRound
}

flags_are_false() {
  FILE="$(state "$1")" FIELDS="$2" node -e '
    try {
      const state = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
      const fields = process.env.FIELDS.split(",");
      process.exit(fields.every(field => state[field] === false) ? 0 : 1);
    } catch (_) { process.exit(1); }
  '
}

# A different Agent type is invisible to the hook, even without Session
# Control context.
OUT="$(run_hook other-type general-purpose "$(review_prompt rt_other_type)")"
[ -z "$OUT" ] && [ ! -e "$(state_for_unstarted_raw_session other-type)" ] \
  && check "S1 wrong subagent type is a total no-op" PASS \
  || check "S1 wrong subagent type is a total no-op" FAIL

# A reviewer without a real SessionStart baseline cannot create workflow state.
NO_STATE_FILE="$(state_for_unstarted_raw_session no-state)"
OUT="$(run_hook no-state zensu:code-reviewer "$(review_prompt rt_no_state)")"
[ -z "$OUT" ] && [ ! -e "$NO_STATE_FILE" ] \
  && check "S2 reviewer without Session Control state is a total no-op" PASS \
  || check "S2 reviewer without Session Control state is a total no-op" FAIL

# Active but not implementation-complete is still outside the review chain.
start_session active-only
S3="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S3"
S3_STATE="$(state "$S3")"
BEFORE="$(digest "$S3_STATE")"
OUT="$(run_hook "$S3" zensu:code-reviewer "$(review_prompt rt_active_only)")"
AFTER="$(digest "$S3_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S3 active session before implComplete is a byte-stable no-op" PASS \
  || check "S3 active session before implComplete is a byte-stable no-op" FAIL

# A completed inner chain cannot be re-opened by a late reviewer completion.
start_session chain-done
S4="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S4"
log --tdd-complete --session "$S4"
log --chain-done --session "$S4"
S4_STATE="$(state "$S4")"
BEFORE="$(digest "$S4_STATE")"
OUT="$(run_hook "$S4" zensu:code-reviewer "$(review_prompt rt_chain_done)")"
AFTER="$(digest "$S4_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S4 chainDone reviewer completion is a byte-stable no-op" PASS \
  || check "S4 chainDone reviewer completion is a byte-stable no-op" FAIL

# Once code review converged, another reviewer completion is stale too.
start_session review-done
S5="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S5"
log --tdd-complete --session "$S5"
log --code-review-done --session "$S5"
S5_STATE="$(state "$S5")"
BEFORE="$(digest "$S5_STATE")"
OUT="$(run_hook "$S5" zensu:code-reviewer "$(review_prompt rt_review_done)")"
AFTER="$(digest "$S5_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S5 codeReviewDone reviewer completion is a byte-stable no-op" PASS \
  || check "S5 codeReviewDone reviewer completion is a byte-stable no-op" FAIL

# What binds a completion is the chain's OUTSTANDING TICKET, not a line
# position. These two chains never issued one, so no prompt can claim them and
# there is nothing to disclose either — the byte-stable no-op is unchanged.
start_session no-marker
S6="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S6"
log --tdd-complete --session "$S6"
S6_STATE="$(state "$S6")"
BEFORE="$(digest "$S6_STATE")"
OUT="$(run_hook "$S6" zensu:code-reviewer 'ordinary reviewer prompt')"
AFTER="$(digest "$S6_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S6 live chain without fan-out marker is a byte-stable no-op" PASS \
  || check "S6 live chain without fan-out marker is a byte-stable no-op" FAIL

start_session late-marker
S7="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7"
log --tdd-complete --session "$S7"
S7_STATE="$(state "$S7")"
BEFORE="$(digest "$S7_STATE")"
OUT="$(run_hook "$S7" zensu:code-reviewer "ordinary first line
$MARKER")"
AFTER="$(digest "$S7_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S7 marker appearing after the first line is rejected byte-stably" PASS \
  || check "S7 marker appearing after the first line is rejected byte-stably" FAIL

# A prompt that names no outstanding ticket still cannot claim the chain — but
# the decline is no longer SILENT. The reviewer ran and the round was never
# recorded, which is exactly the state that used to strand a chain at shape
# `ticket-unclaimed` with no cause reported anywhere, so the hook discloses it
# on the model-facing channel. The ticket value is a capability token and must
# never appear in that text.
start_session missing-ticket
S7A="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7A"
log --tdd-complete --session "$S7A"
MISSING_TICKET="$(issue_ticket "$S7A")"
S7A_STATE="$(state "$S7A")"
BEFORE="$(digest "$S7A_STATE")"
OUT="$(run_hook "$S7A" zensu:code-reviewer "$MARKER")"
AFTER="$(digest "$S7A_STATE")"
# The TEXT is asserted, not merely the envelope: `emit_post_context` always
# emits the `hookSpecificOutput` key, so a grep for that alone passes over an
# EMPTY message and pins nothing about the remedy the model actually reads.
[ -n "$MISSING_TICKET" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7A")" = "false" ] \
  && printf '%s' "$OUT" | grep -q 'hookSpecificOutput' \
  && printf '%s' "$OUT" | grep -qF -- "was NOT recorded against this session's review chain" \
  && printf '%s' "$OUT" | grep -qF -- "naming this chain's outstanding ticket" \
  && check "S7a a prompt naming no outstanding ticket is refused, and discloses" PASS \
  || check "S7a a prompt naming no outstanding ticket is refused, and discloses" FAIL

# The remedy must be RUNNABLE and must name the marker the reviewer agent keys
# its own consume mode on. A bare `zensu-log.sh` is a name the model resolves
# against whatever repository it is standing in.
printf '%s' "$OUT" | grep -qF -- "bash " \
  && printf '%s' "$OUT" | grep -qF -- "zensu-log.sh --review-ticket" \
  && printf '%s' "$OUT" | grep -qF -- "PRE-MERGED FINDINGS (fan-out)" \
  && check "S7a2 the disclosure carries a runnable ticket command and names the marker" PASS \
  || check "S7a2 the disclosure carries a runnable ticket command and names the marker" FAIL

# Conjoined with a POSITIVE anchor on the same capture: a bare `!` over an empty
# string reports PASS while testing nothing, so this would go green precisely
# when the disclosure regressed to silence.
printf '%s' "$OUT" | grep -q 'hookSpecificOutput' \
  && ! printf '%s' "$OUT" | grep -qF -- "$MISSING_TICKET" \
  && check "S7a1 the disclosure never echoes the ticket value" PASS \
  || check "S7a1 the disclosure never echoes the ticket value" FAIL

# The ticket binds by CONTENT, so its line position is irrelevant. Both of the
# next two prompts were refused by the previous positional contract and now
# consume: the ticket on the third line, and a decorated first-line marker.
start_session late-ticket
S7B="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7B"
log --tdd-complete --session "$S7B"
LATE_TICKET="$(issue_ticket "$S7B")"
OUT="$(run_hook "$S7B" zensu:code-reviewer "$MARKER
merged findings
REVIEW-TICKET: $LATE_TICKET")"
[ -n "$LATE_TICKET" ] && printf '%s' "$OUT" | grep -q 'hookSpecificOutput' \
  && [ "$(review_round "$S7B")" = "1" ] \
  && [ "$(ticket_consumed "$S7B")" = "true" ] \
  && check "S7b review ticket below the header block still consumes" PASS \
  || check "S7b review ticket below the header block still consumes" FAIL

start_session decorated-marker
S7C="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7C"
log --tdd-complete --session "$S7C"
DECORATED_TICKET="$(issue_ticket "$S7C")"
OUT="$(run_hook "$S7C" zensu:code-reviewer "$MARKER extra
REVIEW-TICKET: $DECORATED_TICKET")"
[ -n "$DECORATED_TICKET" ] && printf '%s' "$OUT" | grep -q 'hookSpecificOutput' \
  && [ "$(review_round "$S7C")" = "1" ] \
  && [ "$(ticket_consumed "$S7C")" = "true" ] \
  && check "S7c a decorated fan-out marker no longer blocks the consume" PASS \
  || check "S7c a decorated fan-out marker no longer blocks the consume" FAIL

# A ticket line whose VALUE is not the outstanding ticket is still refused, and
# discloses: only the exact one-shot ticket can ever claim the chain.
start_session malformed-ticket
S7D="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7D"
log --tdd-complete --session "$S7D"
MALFORMED_TICKET="$(issue_ticket "$S7D")"
S7D_STATE="$(state "$S7D")"
BEFORE="$(digest "$S7D_STATE")"
OUT="$(run_hook "$S7D" zensu:code-reviewer "$MARKER
REVIEW-TICKET: $MALFORMED_TICKET extra")"
AFTER="$(digest "$S7D_STATE")"
[ -n "$MALFORMED_TICKET" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7D")" = "false" ] \
  && printf '%s' "$OUT" | grep -qF -- "was NOT recorded against this session's review chain" \
  && check "S7d a ticket value that is not the outstanding one is refused, and discloses" PASS \
  || check "S7d a ticket value that is not the outstanding one is refused, and discloses" FAIL

# The REVIEW PACKET legitimately quotes the `REVIEW-TICKET: ` literal whenever
# the reviewer is reviewing this repository, so a uniqueness rule would refuse a
# correct consume. A second, stale ticket line must not block the claim.
start_session quoted-ticket
S7E="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7E"
log --tdd-complete --session "$S7E"
QUOTED_TICKET="$(issue_ticket "$S7E")"
OUT="$(run_hook "$S7E" zensu:code-reviewer "$MARKER
REVIEW-TICKET: $QUOTED_TICKET
merged findings
REVIEW-TICKET: rt_quoted_from_a_diff_hunk")"
[ -n "$QUOTED_TICKET" ] && printf '%s' "$OUT" | grep -q 'hookSpecificOutput' \
  && [ "$(review_round "$S7E")" = "1" ] \
  && [ "$(ticket_consumed "$S7E")" = "true" ] \
  && check "S7e a quoted second ticket line does not block the real consume" PASS \
  || check "S7e a quoted second ticket line does not block the real consume" FAIL

# A well-formed line carrying a ticket this chain never issued is refused.
start_session foreign-ticket
S7F="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7F"
log --tdd-complete --session "$S7F"
FOREIGN_OUTSTANDING="$(issue_ticket "$S7F")"
S7F_STATE="$(state "$S7F")"
BEFORE="$(digest "$S7F_STATE")"
OUT="$(run_hook "$S7F" zensu:code-reviewer "$MARKER
REVIEW-TICKET: rt_a_ticket_this_chain_never_issued")"
AFTER="$(digest "$S7F_STATE")"
[ -n "$FOREIGN_OUTSTANDING" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7F")" = "false" ] \
  && printf '%s' "$OUT" | grep -qF -- "was NOT recorded against this session's review chain" \
  && check "S7f a ticket this chain never issued is refused, and discloses" PASS \
  || check "S7f a ticket this chain never issued is refused, and discloses" FAIL

# --- the DISCLOSURE's arming predicate, conjunct by conjunct ---
# Every case above pairs a wrong/absent ticket with a chain that is otherwise
# live, so only `reviewTicket !== ""` was ever discriminated: the other
# conjuncts could all be deleted with the suite green. Each case below breaks
# exactly ONE of them and delivers a ticket the prompt cannot match, so a
# disclosure would prove the conjunct is gone.
# Each arming case below asserts an ABSENCE, and an absence proves nothing on its
# own: a hook that never disclosed at all would satisfy every one of them, and
# `break_state_field` rewrites the whole document, so silence was explained by
# (broken conjunct OR rewrite) with nothing separating the two. This runs the
# IDENTICAL non-matching prompt against the intact document first and requires a
# disclosure, so the case measures the conjunct rather than the rewrite. A
# decline consumes nothing, so the post-mutation delivery is unaffected.
arming_control() {
  local sid="$1"
  printf '%s' "$(run_hook "$sid" zensu:code-reviewer "$MARKER
REVIEW-TICKET: rt_not_the_outstanding_one")" | grep -qF -- "was NOT recorded against this session's review chain"
}

break_state_field() {
  FILE="$(state "$1")" FIELD="$2" VALUE="$3" node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
    s[process.env.FIELD] = JSON.parse(process.env.VALUE);
    fs.writeFileSync(process.env.FILE, JSON.stringify(s, null, 2));
  '
}

start_session arming-chaindone
S7G="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7G"
log --tdd-complete --session "$S7G"
S7G_TICKET="$(issue_ticket "$S7G")"
arming_control "${S7G}" && S7G_CONTROL=yes || S7G_CONTROL=no
break_state_field "$S7G" chainDone true
OUT="$(run_hook "$S7G" zensu:code-reviewer "$MARKER
REVIEW-TICKET: rt_not_the_outstanding_one")"
[ -n "$S7G_TICKET" ] && [ "$S7G_CONTROL" = yes ] && [ -z "$OUT" ] \
  && check "S7g chainDone true disarms the disclosure (control: intact document discloses)" PASS \
  || check "S7g chainDone true disarms the disclosure (control=$S7G_CONTROL)" FAIL

start_session arming-reviewdone
S7H="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7H"
log --tdd-complete --session "$S7H"
S7H_TICKET="$(issue_ticket "$S7H")"
arming_control "${S7H}" && S7H_CONTROL=yes || S7H_CONTROL=no
break_state_field "$S7H" codeReviewDone true
OUT="$(run_hook "$S7H" zensu:code-reviewer "$MARKER
REVIEW-TICKET: rt_not_the_outstanding_one")"
[ -n "$S7H_TICKET" ] && [ "$S7H_CONTROL" = yes ] && [ -z "$OUT" ] \
  && check "S7h codeReviewDone true disarms the disclosure (control: intact document discloses)" PASS \
  || check "S7h codeReviewDone true disarms the disclosure (control=$S7H_CONTROL)" FAIL

# The pre-read mirrors the claim's own conjuncts. A document the claim would
# refuse must not arm a disclosure whose remedy the claim then refuses too.
start_session arming-vanilla
S7I="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7I"
log --tdd-complete --session "$S7I"
S7I_TICKET="$(issue_ticket "$S7I")"
arming_control "$S7I" && S7I_CONTROL=yes || S7I_CONTROL=no
FILE="$(state "$S7I")" node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  delete s.vanilla;
  fs.writeFileSync(process.env.FILE, JSON.stringify(s, null, 2));
'
OUT="$(run_hook "$S7I" zensu:code-reviewer "$MARKER
REVIEW-TICKET: rt_not_the_outstanding_one")"
[ -n "$S7I_TICKET" ] && [ "$S7I_CONTROL" = yes ] && [ -z "$OUT" ] \
  && check "S7i a document the claim would refuse disarms the disclosure (control: intact document discloses)" PASS \
  || check "S7i a document the claim would refuse disarms the disclosure (control=$S7I_CONTROL)" FAIL

# A reviewer from a chainless flow carries neither the marker nor a ticket line.
# It already could not consume; it must not be hijacked with a re-spawn remedy.
start_session arming-nointent
S7J="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7J"
log --tdd-complete --session "$S7J"
S7J_TICKET="$(issue_ticket "$S7J")"
arming_control "$S7J" && S7J_CONTROL=yes || S7J_CONTROL=no
OUT="$(run_hook "$S7J" zensu:code-reviewer 'Review the diff for the /zensu:cover flow.')"
[ -n "$S7J_TICKET" ] && [ "$S7J_CONTROL" = yes ] && [ -z "$OUT" ] \
  && [ "$(ticket_consumed "$S7J")" = "false" ] \
  && check "S7j a reviewer with no consume intent is not hijacked by the disclosure (control: the same chain discloses for an intent-bearing prompt)" PASS \
  || check "S7j a reviewer with no consume intent is not hijacked by the disclosure (control=$S7J_CONTROL)" FAIL

# Fully armed and correctly marked is the only routed path.
start_session valid
S8="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S8"
log --tdd-complete --session "$S8"
VALID_TICKET="$(issue_ticket "$S8")"
VALID_PROMPT="$(review_prompt "$VALID_TICKET" 'merged findings')"
OUT="$(run_hook "$S8" zensu:code-reviewer "$VALID_PROMPT")"
printf '%s' "$OUT" | grep -q 'hookSpecificOutput' \
  && [ "$(review_round "$S8")" = "1" ] \
  && [ "$(ticket_consumed "$S8")" = "true" ] \
  && check "S8 armed consume-mode reviewer is routed exactly once" PASS \
  || check "S8 armed consume-mode reviewer is routed exactly once" FAIL

# A repeated delivery of the same Agent completion cannot claim the ticket twice.
S8_STATE="$(state "$S8")"
BEFORE="$(digest "$S8_STATE")"
OUT="$(run_hook "$S8" zensu:code-reviewer "$VALID_PROMPT")"
AFTER="$(digest "$S8_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] && [ "$(review_round "$S8")" = "1" ] \
  && check "S8a duplicate completion is a byte-stable no-op" PASS \
  || check "S8a duplicate completion is a byte-stable no-op" FAIL

# Re-arming the same Claude session invalidates every ticket from the old chain.
# The stale delivery is still refused; it now discloses, because the re-armed
# chain does hold an unclaimed ticket and the model has to be told which one.
log --tdd-begin --session "$S8"
log --tdd-complete --session "$S8"
NEW_VALID_TICKET="$(issue_ticket "$S8")"
S8B_STATE="$(state "$S8")"
BEFORE="$(digest "$S8B_STATE")"
OUT_OLD="$(run_hook "$S8" zensu:code-reviewer "$VALID_PROMPT")"
AFTER="$(digest "$S8B_STATE")"
OUT_NEW="$(run_hook "$S8" zensu:code-reviewer "$(review_prompt "$NEW_VALID_TICKET" 'new chain')")"
[ "$AFTER" = "$BEFORE" ] \
  && printf '%s' "$OUT_OLD" | grep -qF -- "was NOT recorded against this session's review chain" \
  && ! printf '%s' "$OUT_OLD" | grep -qF -- "$NEW_VALID_TICKET" \
  && printf '%s' "$OUT_NEW" | grep -q 'hookSpecificOutput' \
  && [ "$(review_round "$S8")" = "1" ] \
  && check "S8b a prior chain's ticket cannot mutate the re-armed chain, and discloses" PASS \
  || check "S8b a prior chain's ticket cannot mutate the re-armed chain, and discloses" FAIL

# State remains session-local even when another canonical baseline becomes current.
start_session session-a
S9A="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S9A"
log --tdd-complete --session "$S9A"
S9A_STATE="$(state "$S9A")"
A_BEFORE="$(digest "$S9A_STATE")"

start_session session-b
S9B="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S9B"
log --tdd-complete --session "$S9B"
TICKET_B="$(issue_ticket "$S9B")"
run_hook "$S9B" zensu:code-reviewer "$(review_prompt "$TICKET_B")" >/dev/null
[ "$(digest "$S9A_STATE")" = "$A_BEFORE" ] && [ "$(review_round "$S9B")" = "1" ] \
  && check "S9 reviewer completion cannot mutate another session state" PASS \
  || check "S9 reviewer completion cannot mutate another session state" FAIL

# Corrupt state fails open without replacing or repairing the real baseline file.
start_session malformed
S10="$STARTED_SESSION_KEY"
S10_STATE="$(state "$S10")"
printf '%s\n' '{malformed' > "$S10_STATE"
BEFORE="$(digest "$S10_STATE")"
OUT="$(run_hook "$S10" zensu:code-reviewer "$(review_prompt rt_malformed)")"
AFTER="$(digest "$S10_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S10 malformed Session Control state is a no-op with no repair write" PASS \
  || check "S10 malformed Session Control state is a no-op with no repair write" FAIL

# Syntactically valid but incomplete state is malformed too. Derive it from a
# real armed baseline so only the mandatory revision field is missing.
start_session partial
S11="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S11"
log --tdd-complete --session "$S11"
PARTIAL_TICKET="$(issue_ticket "$S11")"
S11_STATE="$(state "$S11")"
FILE="$S11_STATE" node -e '
  const fs = require("fs"), state = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  delete state.revision;
  fs.writeFileSync(process.env.FILE, JSON.stringify(state, null, 2));
'
BEFORE="$(digest "$S11_STATE")"
OUT="$(run_hook "$S11" zensu:code-reviewer "$(review_prompt "$PARTIAL_TICKET")")"
AFTER="$(digest "$S11_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S11 incomplete typed state derived from a baseline is a byte-stable no-op" PASS \
  || check "S11 incomplete typed state derived from a baseline is a byte-stable no-op" FAIL

# All routing flags and a real ticket are not sufficient: the hook must validate
# the complete chain schema before claiming the ticket.
start_session missing-required
S11A="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S11A"
log --tdd-complete --session "$S11A"
SCHEMA_TICKET="$(issue_ticket "$S11A")"
S11A_STATE="$(state "$S11A")"
FILE="$S11A_STATE" node -e '
  const fs = require("fs"), state = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  delete state.vanilla;
  fs.writeFileSync(process.env.FILE, JSON.stringify(state, null, 2));
'
BEFORE="$(digest "$S11A_STATE")"
OUT="$(run_hook "$S11A" zensu:code-reviewer "$(review_prompt "$SCHEMA_TICKET")")"
AFTER="$(digest "$S11A_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S11a missing mandatory schema field is a byte-stable no-op" PASS \
  || check "S11a missing mandatory schema field is a byte-stable no-op" FAIL

start_session wrong-session
S12="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S12"
log --tdd-complete --session "$S12"
WRONG_SESSION_TICKET="$(issue_ticket "$S12")"
S12_STATE="$(state "$S12")"
OTHER_SESSION_KEY="$(node "$SESSION_CORE" session-key different-session)"
FILE="$S12_STATE" OTHER_KEY="$OTHER_SESSION_KEY" node -e '
  const fs = require("fs"), state = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  state.session_id_hash = `sha256:${process.env.OTHER_KEY.slice("scv1_".length)}`;
  fs.writeFileSync(process.env.FILE, JSON.stringify(state, null, 2));
'
BEFORE="$(digest "$S12_STATE")"
OUT="$(run_hook "$S12" zensu:code-reviewer "$(review_prompt "$WRONG_SESSION_TICKET")")"
AFTER="$(digest "$S12_STATE")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && check "S12 state owned by another canonical session is a byte-stable no-op" PASS \
  || check "S12 state owned by another canonical session is a byte-stable no-op" FAIL

# Explicit or partial hook principals must never borrow the main thread's
# consume-mode reviewer authority, even when ambient force-main is set.
start_session principal-guard
S12B="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S12B"
log --tdd-complete --session "$S12B"
PRINCIPAL_TICKET="$(issue_ticket "$S12B")"
PRINCIPAL_PROMPT="$(review_prompt "$PRINCIPAL_TICKET")"
S12B_STATE="$(state "$S12B")"
BEFORE="$(digest "$S12B_STATE")"
PRINCIPAL_OUTPUT=""
for PRINCIPAL_KIND in reviewer plm neutral partial; do
  PRINCIPAL_OUTPUT="${PRINCIPAL_OUTPUT}$(run_hook_as "$S12B" zensu:code-reviewer "$PRINCIPAL_PROMPT" "$PRINCIPAL_KIND")"
done
AFTER="$(digest "$S12B_STATE")"
if [ -z "$PRINCIPAL_OUTPUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S12B")" = false ] && [ "$(review_round "$S12B")" = 0 ]; then
  check "S12b reviewer/PLM/neutral/partial principals cannot consume a ticket or emit helper text" PASS
else
  check "S12b non-main principals are a byte-stable post-review no-op" FAIL
fi

# Parallel duplicate deliveries race on one atomic ticket claim; exactly one wins.
start_session concurrent
S13="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S13"
log --tdd-complete --session "$S13"
CONCURRENT_TICKET="$(issue_ticket "$S13")"
CONCURRENT_PROMPT="$(review_prompt "$CONCURRENT_TICKET")"
i=1
while [ "$i" -le 20 ]; do
  run_hook "$S13" zensu:code-reviewer "$CONCURRENT_PROMPT" > "$ROOT/concurrent-$i.out" &
  i=$((i + 1))
done
wait
WINNERS="$(grep -l 'hookSpecificOutput' "$ROOT"/concurrent-*.out 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$(review_round "$S13")" = "1" ] && [ "$WINNERS" = "1" ] \
  && check "S13 parallel duplicate completions produce one routed CAS round" PASS \
  || check "S13 parallel duplicate completions produce one routed CAS round" FAIL

# Every delayed terminus is bound to the consumed ticket. Re-arming between
# claim and close invalidates old PASS/max/self-review commands.
start_session stale-terminus
S14="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S14"
log --tdd-complete --session "$S14"
STALE_TICKET="$(issue_ticket "$S14")"
ROUND="$(tdd_consume_review_ticket "$S14" "$STALE_TICKET")"
log --tdd-begin --session "$S14"
log --tdd-complete --session "$S14"
if [ "$ROUND" = "1" ] \
  && ! log --code-review-done --session "$S14" --claimed-review-ticket "$STALE_TICKET" \
  && ! log --chain-done --session "$S14" --claimed-review-ticket "$STALE_TICKET" \
  && flags_are_false "$S14" 'codeReviewDone,chainDone'; then
  check "S14 stale PASS/max close cannot mark a re-armed generation" PASS
else
  check "S14 stale PASS/max close cannot mark a re-armed generation" FAIL
fi

start_session stale-self-review
S15="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S15"
log --tdd-complete --session "$S15"
SELF_TICKET="$(issue_ticket "$S15")"
SELF_ROUND="$(tdd_consume_review_ticket "$S15" "$SELF_TICKET")"
SELF_CODE_REVIEW_DONE=false
if log --code-review-done --session "$S15" --claimed-review-ticket "$SELF_TICKET"; then
  SELF_CODE_REVIEW_DONE=true
fi
log --tdd-begin --session "$S15"
log --tdd-complete --session "$S15"
if [ "$SELF_ROUND" = "1" ] && [ "$SELF_CODE_REVIEW_DONE" = "true" ] \
  && ! log --self-review-fixed --session "$S15" --claimed-review-ticket "$SELF_TICKET" \
  && ! log --chain-done --session "$S15" --claimed-review-ticket "$SELF_TICKET" \
  && flags_are_false "$S15" 'selfReviewFixed,chainDone'; then
  check "S15 stale self-review latch/terminus cannot close a new generation" PASS
else
  check "S15 stale self-review latch/terminus cannot close a new generation" FAIL
fi

start_session unbound-after-ticket
S16="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S16"
log --tdd-complete --session "$S16"
UNBOUND_TICKET="$(issue_ticket "$S16")"
UNBOUND_ROUND="$(tdd_consume_review_ticket "$S16" "$UNBOUND_TICKET")"
if [ "$UNBOUND_ROUND" = "1" ] \
  && ! log --chain-done --session "$S16" \
  && flags_are_false "$S16" chainDone; then
  check "S16 unqualified terminus is rejected after a ticket was consumed" PASS
else
  check "S16 unqualified terminus is rejected after a ticket was consumed" FAIL
fi

# S17 — the convergence full-suite instruction, in BOTH CLOSE_PASS directive strings.
# Phase 5 checkpoints are SCOPED, so this branch is where the verdict for the tree that
# ships is measured. The skill states the rule, but CLOSE_PASS is what the model actually
# RECEIVES at convergence, and with `hooks.selfReview:false` no self-review stage follows
# to re-measure — so the selfReview-OFF arm is the one that must not be dropped. Both
# arms pinned: the skill-side rule can survive while the carrier that delivers it does not.
# Needles are SINGLE-quoted: these contain backticks, and a double-quoted needle would be
# command-substituted away by bash and pin nothing (that exact defect shipped once here).
CLOSE_PASS_HITS="$(grep -cF -- 're-run the FULL test suite over the current tree in the FOREGROUND' "$HOOK" 2>/dev/null || echo 0)"
if [ "$CLOSE_PASS_HITS" -eq 2 ] \
  && grep -qF -- 'this convergence branch is where the verdict for the tree that ships is measured' "$HOOK" \
  && grep -qF -- 'NO self-review stage follows in this configuration' "$HOOK" \
  && grep -qF -- '| scope: full' "$HOOK"; then
  check "S17 both CLOSE_PASS arms carry the convergence full-suite instruction" PASS
else
  check "S17 both CLOSE_PASS arms carry the convergence full-suite instruction (hits: $CLOSE_PASS_HITS)" FAIL
fi

# S18 — every `node -e '...'` program under `hooks/` must be valid JavaScript.
# A bash single-quoted string ends at the FIRST apostrophe, so one inside the JS —
# including inside a `//` comment, which is where it is invisible — silently
# truncates the program. `bash -n` still passes, because the remainder re-quotes
# into valid shell, and the assignment lands EMPTY. That shipped in THIS hook: a
# comment reading "this repo's own test files" disabled the consume-intent probe
# outright, and only a behavioural case caught it. The scan is TREE-WIDE on
# purpose — the defect class is, and 190 programs were otherwise unguarded — so a
# failure here can name a file this suite is not otherwise about: fix the
# apostrophe in the file the message names, not this suite.
S18_OUT="$(SCAN_ROOT="$PLUGIN_DIR" node -e '
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.join(process.env.SCAN_ROOT, "hooks");
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, {withFileTypes: true})) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.isFile() && e.name.endsWith(".sh")) files.push(p);
  }
})(root);
const NEEDLE = "node -e " + String.fromCharCode(39);
let scanned = 0;
const broken = [];
for (const f of files) {
  const src = fs.readFileSync(f, "utf8");
  let i = 0;
  while ((i = src.indexOf(NEEDLE, i)) !== -1) {
    const start = i + NEEDLE.length;
    const end = src.indexOf(String.fromCharCode(39), start);
    if (end === -1) break;
    scanned++;
    const line = src.slice(0, start).split("\n").length;
    const rel = path.relative(process.env.SCAN_ROOT, f) + ":" + line;
    // TWO tests, because a parse check alone is not enough: a truncation whose
    // prefix happens to be complete JavaScript compiles clean and ships dead.
    // The structural half is what covers that — after a real closing quote the
    // shell continues with a redirect, a pipe, a paren, an operator or a
    // newline, never with a word character, which is exactly what an apostrophe
    // inside prose leaves behind (`repo` + `s own test files`).
    try { new vm.Script(src.slice(start, end)); }
    catch (e) { broken.push(rel + " (does not parse)"); }
    if (/[A-Za-z0-9_]/.test(src.charAt(end + 1))) {
      broken.push(rel + " (word character after the closing quote)");
    }
    // THIRD test, and the one that targets the observed shape most directly: a
    // program whose last line is a `//` comment ended inside that comment. A
    // truncation there is complete JavaScript whenever the apostrophe happens to
    // sit at brace depth 0, so neither of the two tests above sees it.
    const lastLine = src.slice(start, end).split("\n").pop().trim();
    if (lastLine.startsWith("//")) {
      broken.push(rel + " (program ends inside a line comment)");
    }
    i = end + 1;
  }
}
process.stdout.write(scanned + " " + broken.join(","));
' 2>/dev/null)"
S18_SCANNED="${S18_OUT%% *}"
S18_BROKEN="${S18_OUT#* }"
# A scanner that finds nothing is indistinguishable from a scanner that ran over
# nothing, so the count is a floor as well as a report.
case "$S18_SCANNED" in ''|*[!0-9]*) S18_SCANNED=0 ;; esac
# The floor is close to the measured population (190 on 2026-09-02), not a round
# number well below it: at 100 a regression that stopped descending into
# `hooks/lib/` — which holds the large majority of these programs — would still
# clear the guard and report a clean scan over a fraction of the tree.
if [ "$S18_SCANNED" -ge 180 ] && [ -z "$S18_BROKEN" ]; then
  check "S18 every node -e program under hooks/ is valid JS (scanned: $S18_SCANNED)" PASS
else
  check "S18 every node -e program under hooks/ is valid JS — an apostrophe truncates the bash single-quoted string (scanned: $S18_SCANNED, broken: ${S18_BROKEN:-none})" FAIL
fi

echo "----"
echo "test-post-review-tdd-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
