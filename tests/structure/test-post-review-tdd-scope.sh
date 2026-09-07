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
// hooks/ ONLY, and that bound is MEASURED rather than conservative. Widening the
// walk to tests/structure/ was tried and reverted: it scanned 1001 candidates and
// reported five that do not parse, all of them extraction artifacts rather than
// defects — a prose COMMENT quoting the literal, the nested `node -e ` + backslash
// quoting the suites use inside command substitutions, and a program whose closing
// delimiter the extractor mis-locates. The extractor assumes the plain opening and
// closing convention hooks/ follows; the suites do not follow it, so a scan there
// reports false positives, which is worse than no scan. Widening this needs an
// extractor that understands the other quoting shapes, not a second root.
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

# S19 — the bound branch used to open with a guard testing `PREFLIGHT_CONTEXT`
# against the empty object, and that guard was unreachable by construction:
# `EXPECT_BOUND` is derived from the SAME comparison one gate above, and the
# envelope classifier emits kind `bound` only when `EXPECT_BOUND` is `yes`, so
# the guard could never be false. The cost was never dead code on its own — it
# was that two operator accounts enumerated its decline as a live diagnosis, so
# the contract advertised a refusal nothing could produce. The derivation is
# asserted as a CONTROL: without it a rename of the variable would satisfy the
# absence test while leaving the guard in place under another name.
# The doc needles match the ENUMERATION, never the phrase: a correct account has
# to name the case in order to say it is unreachable, so forbidding the words
# outright is a predicate no correct fix can satisfy. Each file is also required
# to keep DISCUSSING it, so deleting the passage wholesale does not pass either.
S19_GUARD="$(grep -c 'PREFLIGHT_CONTEXT" != ' "$HOOK" || true)"
S19_DERIV="$(grep -c 'PREFLIGHT_CONTEXT" = ' "$HOOK" || true)"
S19_WF="$(tr '\n' ' ' < "$PLUGIN_DIR/docs/tdd-manager-workflow.md" | tr -s ' ' | grep -c 'discloses — including a bound prompt' || true)"
# CLAUDE.md is hard-wrapped, so the enumeration can straddle a line break: a
# line-local needle would pass on a re-added claim that happens to wrap.
S19_CM="$(tr '\n' ' ' < "$PLUGIN_DIR/CLAUDE.md" | tr -s ' ' | grep -c 'comparison, a bound prompt' || true)"
S19_WF_KEPT="$(grep -c 'bound prompt' "$PLUGIN_DIR/docs/tdd-manager-workflow.md" || true)"
S19_CM_KEPT="$(grep -c 'bound prompt' "$PLUGIN_DIR/CLAUDE.md" || true)"
# The two needles above forbid the two spellings this claim historically had, which
# a reworded re-addition escapes. So the doc half is ALSO positive and class-wide:
# every `bound prompt` mention in either carrier must sit within reach of an
# unreachability marker, which no live-diagnosis enumeration can satisfy however
# it is worded. Both files are hard-wrapped, so flatten first, then start a line at
# each mention and judge the window that follows it.
# The window is SYMMETRIC. Starting a line AT each mention judges only what follows
# it, and in both carriers today one marker sits BEFORE the mention — so a correct
# reword that moves the other marker ahead of it would be reported unmarked. Emit
# the tail of the preceding fragment together with the head of the mention line.
s19_unmarked() {
  tr '\n' ' ' < "$1" | tr -s ' ' | sed 's/bound prompt/\
&/g' | awk 'NR>1 { print substr(prev, length(prev)-180) " " substr($0,1,260) } { prev=$0 }' \
    | grep -cv 'UNREACHABLE\|does NOT fire' || true
}
S19_WF_UNMARKED="$(s19_unmarked "$PLUGIN_DIR/docs/tdd-manager-workflow.md")"
S19_CM_UNMARKED="$(s19_unmarked "$PLUGIN_DIR/CLAUDE.md")"
# EXACTLY one derivation, and it must be the EXPECT_BOUND line: a guard reintroduced
# with `=` instead of `!=` raises this count, where a `-ge 1` bound would not see it.
S19_DERIV_LINE="$(grep -cF -- "PREFLIGHT_CONTEXT\" = '{}' ]; then EXPECT_BOUND=" "$HOOK" || true)"
if [ "$S19_GUARD" -eq 0 ] && [ "$S19_DERIV" -eq 1 ] && [ "$S19_DERIV_LINE" -eq 1 ] \
  && [ "$S19_WF" -eq 0 ] && [ "$S19_CM" -eq 0 ] \
  && [ "$S19_WF_UNMARKED" -eq 0 ] && [ "$S19_CM_UNMARKED" -eq 0 ] \
  && [ "$S19_WF_KEPT" -ge 1 ] && [ "$S19_CM_KEPT" -ge 1 ]; then
  check "S19 the unreachable bound-branch guard is gone and every operator account marks the case unreachable" PASS
else
  check "S19 the unreachable bound-branch guard is gone and every operator account marks the case unreachable (guard=$S19_GUARD deriv=$S19_DERIV deriv-line=$S19_DERIV_LINE workflow-doc=$S19_WF claude-md=$S19_CM wf-unmarked=$S19_WF_UNMARKED cm-unmarked=$S19_CM_UNMARKED)" FAIL
fi

# S20 — consume intent has TWO disjuncts, and until this case every fixture that
# reached a decline carried the fan-out marker on line 1, so the SECOND one — a
# `REVIEW-TICKET:` line whose value already MATCHED the outstanding ticket —
# could be deleted with the whole suite green. This prompt does NOT open with the
# marker, so only the matched ticket can arm the disclosure. The refusal itself
# is the standalone deliberate-spoof arm: a complete, regex-valid envelope triple
# on a chain the durable state says is standalone.
start_session ticket-only-intent
S20="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S20"
log --tdd-complete --session "$S20"
S20_TICKET="$(issue_ticket "$S20")"
S20_STATE="$(state "$S20")"
S20_BEFORE="$(digest "$S20_STATE")"
OUT="$(run_hook "$S20" zensu:code-reviewer "REVIEW-TICKET: $S20_TICKET
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=run-fixture attempt=1 chain=chain-fixture
AUTOPILOT-STAGE: GATES")"
S20_AFTER="$(digest "$S20_STATE")"
[ -n "$S20_TICKET" ] && [ "$S20_AFTER" = "$S20_BEFORE" ] \
  && [ "$(ticket_consumed "$S20")" = "false" ] \
  && printf '%s' "$OUT" | grep -qF -- "was NOT recorded against this session's review chain" \
  && ! printf '%s' "$OUT" | grep -qF -- "$S20_TICKET" \
  && check "S20 a matched ticket alone arms the disclosure when the prompt does not open with the marker" PASS \
  || check "S20 a matched ticket alone arms the disclosure when the prompt does not open with the marker" FAIL

# S22 — AC-005. The reminder header claims the phrase lists are mirrored with
# plan-approved-delegate.sh while the PRECEDENCE is not, and nothing pinned either
# half: a grep over tests/ for its distinguishing literals returned nothing, so the
# qualification could be deleted or re-broken with every suite green. It was in fact
# shipped garbled once, as a duplicated noun phrase left by a substitution.
S22_HOOK="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
# Strip the comment marker from each line BEFORE flattening. A needle spanning a
# line break otherwise carries the NEXT line's `#`, which couples it to the physical
# wrap: a benign reflow of this comment turns the check red, and a re-garble wrapped
# one word earlier escapes it entirely. Count OCCURRENCES with grep -o, not lines:
# after flattening the stream is one line, so grep -c can only ever answer 0 or 1.
s22_flat() { sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' "$1" | tr '\n' ' ' | tr -s ' '; }
S22_LISTS="$(s22_flat "$S22_HOOK" | grep -o 'IN THEIR PHRASE LISTS' | wc -l | tr -d ' ')"
S22_PREC="$(s22_flat "$S22_HOOK" | grep -o 'NOT identical in PRECEDENCE' | wc -l | tr -d ' ')"
S22_DUP="$(s22_flat "$S22_HOOK" | grep -o 'utterance like a mixed utterance' | wc -l | tr -d ' ')"
if [ "$S22_LISTS" -ge 1 ] && [ "$S22_PREC" -eq 1 ] && [ "$S22_DUP" -eq 0 ]; then
  check "S22 the reminder header claims mirrored phrase lists without claiming mirrored precedence, ungarbled" PASS
else
  check "S22 the reminder header claims mirrored phrase lists without claiming mirrored precedence, ungarbled (lists=$S22_LISTS precedence=$S22_PREC duplicate=$S22_DUP)" FAIL
fi

# S23 — AC-006. Both operator carriers state the envelope collapse rule, and the
# rule they state must be the QUALIFIED one: the bound branch shape-filters binding
# and stage lines before collapsing, so an unqualified "two lines that differ are
# refused" is false for exactly the case the filter exists for. Nothing under tests/
# carried this literal before, in either direction.
S23_BAD=0
S23_OK=0
for S23_F in "$PLUGIN_DIR/docs/configuration.md" "$PLUGIN_DIR/docs/tdd-manager-workflow.md"; do
  S23_HAS="$(grep -c 'DISTINCT line each' "$S23_F" || true)"
  S23_QUAL="$(grep -c 'two DIFFERENT regex-valid lines' "$S23_F" || true)"
  S23_STALE="$(grep -c 'accepted, two lines that differ are refused' "$S23_F" || true)"
  if [ "$S23_HAS" -ge 1 ] && [ "$S23_QUAL" -ge 1 ] && [ "$S23_STALE" -eq 0 ]; then
    S23_OK=$((S23_OK + 1))
  else
    S23_BAD=$((S23_BAD + 1))
  fi
done
if [ "$S23_OK" -eq 2 ] && [ "$S23_BAD" -eq 0 ]; then
  check "S23 both operator carriers state the QUALIFIED envelope collapse rule" PASS
else
  check "S23 both operator carriers state the QUALIFIED envelope collapse rule (ok=$S23_OK bad=$S23_BAD)" FAIL
fi

# S24 — the stage allowlist in the delegate is a hand-copy of the set the state
# library owns. S7u pins the library against itself and reads only that file, so it
# is structurally blind to this third copy: a stage added there and not here makes
# the standalone decline render `observed: unreported` for a stage the record named,
# which is the exact defect the observed-stage disclosure was written to remove.
S24_OUT="$(HOOK_FILE="$HOOK" LIB_FILE="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" node -e '
const fs = require("node:fs");
const grab = (src, re) => { const m = src.match(re); return m ? m[1] : null; };
const members = raw => raw === null ? null
  : raw.split(",").map(x => x.trim()).filter(Boolean)
      .map(x => x.replace(/^["]|["]$/g, "")).sort().join(",");
const hook = fs.readFileSync(process.env.HOOK_FILE, "utf8");
const lib = fs.readFileSync(process.env.LIB_FILE, "utf8");
const a = members(grab(hook, /const RENDERABLE = \[([^\]]*)\]/));
const b = members(grab(lib, /^const STAGES = new Set\(\[([^\]]*)\]\)/m));
if (a === null || b === null) { process.stdout.write("unextractable"); }
else if (a !== b) { process.stdout.write("differ"); }
else { process.stdout.write("equal " + a.split(",").length); }
' 2>/dev/null)"
case "$S24_OUT" in
  equal\ *) check "S24 the delegate stage allowlist matches the set the state library owns ($S24_OUT)" PASS ;;
  *) check "S24 the delegate stage allowlist matches the set the state library owns (out=${S24_OUT:-none})" FAIL ;;
esac

# S25 — the team-review operation-key recognizer is a hand-copy of a shape the state
# library mints, and the divergence direction is fail-OPEN: a real header the pattern
# stops matching is treated as absent, so the bound envelope is accepted. Pin the
# recognizer against the producer rather than against a fixture that hardcodes the
# current spelling.
S25_OUT="$(HOOK_FILE="$HOOK" LIB_FILE="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" node -e '
const fs = require("node:fs");
const crypto = require("node:crypto");
const hook = fs.readFileSync(process.env.HOOK_FILE, "utf8");
const lib = fs.readFileSync(process.env.LIB_FILE, "utf8");
const m = hook.match(/const REVIEW_OP_RE = (\/\^AUTOPILOT-REVIEW-OP:[^\n]*?\/);/);
if (!m) { process.stdout.write("no-recognizer"); }
else if (!/team-review:v1:\$\{digest\(/.test(lib)) { process.stdout.write("no-producer"); }
else {
  // new RegExp, never eval: the capture is source text, and a constructor can only
  // ever build a pattern where eval could call a function spliced into the literal.
  const re = new RegExp(m[1].slice(1, -1));
  const sha = crypto.createHash("sha256").update("x").digest("hex");
  const key = "team-review:v1:" + sha;
  const line = "AUTOPILOT-REVIEW-OP: key=" + key + " head=" + sha;
  // The NEGATIVE arm is what a prefix regression needs: a pattern relaxed back to
  // a bare prefix accepts a quoted column-0 placeholder and vetoes a live envelope,
  // which is the defect the recognizer shape exists to prevent.
  const placeholder = "AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>";
  if (!re.test(line)) { process.stdout.write("rejects-a-real-key"); }
  else if (re.test(placeholder)) { process.stdout.write("accepts-a-placeholder"); }
  else { process.stdout.write("matches"); }
}
' 2>/dev/null)"
if [ "$S25_OUT" = matches ]; then
  check "S25 the review-op recognizer accepts a key of the shape the state library actually mints" PASS
else
  check "S25 the review-op recognizer accepts a key of the shape the state library actually mints (out=${S25_OUT:-none})" FAIL
fi

# S26 — the delegate re-spells the RETURN STAGE vocabulary THREE times: in STAGE_RE,
# in the PREFLIGHT_CONTEXT validator over s.autopilotReturnStage, and in the claim
# validator over binding.returnStage. The state library
# owns it as RETURN_STAGES. CONVERGE was dropped from one of those copies once and
# restored; nothing compared them. An end-to-end CONVERGE fixture was tried first
# and REMOVED: the run record cannot reach that return stage the short way, because
# PLAN_APPROVED sets tdd.returnStage to GATES unconditionally and TDD_STARTED only
# CHECKS the field rather than assigning from the payload, so a --tdd-begin naming
# CONVERGE is refused before any chain is armed. Driving the machine honestly needs
# a full GATES pass plus CONVERGENCE_FAILED, which belongs in the state-machine
# suite and not in the tail of the suite this repository already records as the
# first thing a Windows timeout truncates. The set comparison catches the same
# regression — a member silently dropped from either delegate copy.
S26_OUT="$(HOOK_FILE="$HOOK" LIB_FILE="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" node -e '
const fs = require("node:fs");
const hook = fs.readFileSync(process.env.HOOK_FILE, "utf8");
const lib = fs.readFileSync(process.env.LIB_FILE, "utf8");
const sorted = list => list.slice().sort().join(",");
const owner = lib.match(/^const RETURN_STAGES = new Set\(\[([^\]]*)\]\)/m);
const reAlt = hook.match(/const STAGE_RE = \/\^AUTOPILOT-STAGE: \(([^)]*)\)\$\//);
const listing = hook.match(/\[("GATES"[^\]]*)\]\s*\n?\s*\.includes\(binding\.returnStage\)/);
const preflight = hook.match(/\[("GATES"[^\]]*)\]\s*\n?\s*\.includes\(s\.autopilotReturnStage\)/);
if (!owner || !reAlt || !listing || !preflight) { process.stdout.write("unextractable"); }
else {
  const strip = raw => raw.split(",").map(x => x.trim()).filter(Boolean)
    .map(x => x.replace(/^["]|["]$/g, ""));
  const a = sorted(strip(owner[1]));
  const b = sorted(reAlt[1].split("|").map(x => x.trim()).filter(Boolean));
  const c = sorted(strip(listing[1]));
  const d = sorted(strip(preflight[1]));
  if (a !== b) { process.stdout.write("stage-re-differs"); }
  else if (a !== c) { process.stdout.write("claim-list-differs"); }
  else if (a !== d) { process.stdout.write("preflight-list-differs"); }
  else { process.stdout.write("equal " + a.split(",").length); }
}
' 2>/dev/null)"
case "$S26_OUT" in
  equal\ *) check "S26 all three delegate return-stage copies match RETURN_STAGES in the state library ($S26_OUT)" PASS ;;
  *) check "S26 all three delegate return-stage copies match RETURN_STAGES in the state library (out=${S26_OUT:-none})" FAIL ;;
esac

# S21 pins the RAW half of the raw-versus-distinct split, which nothing asserted:
# the standalone spoof arm counts OCCURRENCES so that a doubled quotation stays
# ignored, while the bound arm collapses to distinct lines. Every other envelope
# fixture in the tree carries each line exactly once, so rewriting completeTriple
# onto the distinct lists kept every suite green while reintroducing the defect —
# a doubled caller line would move from ignored to refused-as-a-spoof, and that
# decline rotates a live ticket. The prompt below repeats ONE caller line and is
# otherwise a complete regex-valid triple: under raw counting callers.length is 2,
# completeTriple is false, and the claim proceeds; under distinct counting it is 1
# and the hook would refuse. This check is placed LAST because it arms a session.
start_session doubled-caller-standalone
S21="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S21"
log --tdd-complete --session "$S21"
S21_TICKET="$(issue_ticket "$S21")"
OUT="$(run_hook "$S21" zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $S21_TICKET
ZENSU-DELEGATED-CALLER: autopilot
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=run-fixture attempt=1 chain=chain-fixture
AUTOPILOT-STAGE: GATES")"
[ -n "$S21_TICKET" ] \
  && [ "$(ticket_consumed "$S21")" = "true" ] \
  && ! printf '%s' "$OUT" | grep -qF -- "was NOT recorded against this session's review chain" \
  && check "S21 a doubled caller line on a standalone chain is ignored, not read as a second caller" PASS \
  || check "S21 a doubled caller line on a standalone chain is ignored, not read as a second caller" FAIL

echo "----"
echo "test-post-review-tdd-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
