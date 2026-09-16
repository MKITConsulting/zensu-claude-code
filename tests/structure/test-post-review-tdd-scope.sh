#!/bin/bash
# The code-reviewer completion hook is scoped to one live TDD review chain.
#
# WINDOWS POSITION, stated because a reviewer read the absence of a
# `windows-ci.v1.json` entry as "never runs on Windows", which is false in one
# direction and true in the other. This suite IS in `ciStructureTests`
# (`tests/profiles/promptfoo-local-only.v1.json`), which is the inventory
# `tests/run-windows-safety-shard.js` builds the weekly `Windows full safety
# suite` run from, so every check here does execute on windows-latest once a
# week. It is NOT in `tests/profiles/windows-ci.v1.json`, so none of them can
# block a pull request: a Windows-only regression surfaces at the next weekly
# run rather than on the PR that caused it. That omission is the house rule
# rather than an oversight — every shard in that profile carries a
# `profileTimeoutMs` of 1800000 and several already report job durations at or
# above it, so an entry has to be paid for by moving another suite off, and this
# suite is one of the expensive ones (283 s and 410 s across two macOS runs on
# 2026-09-07, both on a loaded machine, so read the pair as a range rather than a
# figure, and
# the one recorded macOS-to-Windows ratio in this tree is about 9x). Say "runs
# weekly, does not block a PR"; never say "covered" and never say "never runs on
# Windows". Closing it properly means a shard of its own, on a MEASURED cap from
# a green weekly run — not an estimate, and not a suite displaced to make room.
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

# S0 — the `node --test` driver for `tests/structure/review-ticket-claim-v1.test.js`,
# which is the unit contract of the shared review-ticket claim predicate S32 below
# proves both carriers call. `tests/run-all.sh` discovers only
# `tests/structure/test-*.sh`, so a `*.test.js` with no driver is never executed by the
# tree runner at all. It runs FIRST, before any fixture: it needs only `PLUGIN_DIR`, and
# at the tail a Windows timeout would take the only coverage that module has anywhere.
# The registration FLOOR is what keeps exit 0 from also accepting a file that registers
# nothing — the same reason T26 in the Stop-routing suite carries one.
S0_UNIT="$PLUGIN_DIR/tests/structure/review-ticket-claim-v1.test.js"
S0_OUT="$(cd "$PLUGIN_DIR" && node --test "$S0_UNIT" 2>&1)" && S0_RC=0 || S0_RC=$?
S0_CASES="$(grep -cE "^test\(" "$S0_UNIT" || true)"
[ "$S0_RC" -eq 0 ] && [ "$S0_CASES" -ge 10 ] \
  && check "S0 the shared review-ticket claim predicate unit contract passes" PASS \
  || check "S0 the shared review-ticket claim predicate unit contract passes (rc=$S0_RC cases=$S0_CASES)" FAIL

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

# S18 — every `node -e '...'` program under `hooks/` and `tests/structure/` must
# be valid JavaScript.
# A bash single-quoted string ends at the FIRST apostrophe, so one inside the JS —
# including inside a `//` comment, which is where it is invisible — silently
# truncates the program. `bash -n` still passes, because the remainder re-quotes
# into valid shell, and the assignment lands EMPTY. That shipped in THIS hook: a
# comment reading "this repo's own test files" disabled the consume-intent probe
# outright, and only a behavioural case caught it. The scan is TREE-WIDE on
# purpose — the defect class is — so a failure here can name a file this suite is
# not otherwise about: fix the apostrophe in the file the message names, not this
# suite.
#
# `tests/structure/` was OUT of scope for one release on a measurement that read
# five reports there as extraction artifacts. FOUR of them were: a needle quoted
# inside a shell `#` comment, two programs opened in the nested
# backslash-apostrophe spelling, and one whose closing delimiter is the middle
# apostrophe of the quote-doublequote idiom sitting inside a JS comment. The
# FIFTH was a real shipped defect this scan then caught —
# `tests/structure/test-autopilot-full-cycle.sh` handed `process.stdout.write` an
# object literal rather than a string, so its `gh api ... /replies` stub threw
# `ERR_INVALID_ARG_TYPE` and never reached the `exit 0` below it. So the revert
# was justified by a measurement that mis-classified a defect as noise. The
# extractor below understands all three spellings, which is what the reverted
# widening lacked.
S18_OUT="$(SCAN_ROOT="$PLUGIN_DIR" node -e '
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Q = String.fromCharCode(39);
const DQ = String.fromCharCode(34);
const NEEDLE = "node -e " + Q;
// Two shell spellings escape an apostrophe inside a single-quoted string:
// backslash-quote, and the quote-doublequote concatenation. Both are built out
// of Q so that this program itself stays apostrophe-free and cannot be the
// defect it looks for.
const OPEN_NESTED = "\\" + Q + Q;
const ESC_BACKSLASH = Q + "\\" + Q + Q;
const ESC_CONCAT = Q + DQ + Q + DQ + Q;
const ROOTS = ["hooks", "tests/structure"];
const counts = [];
const broken = [];
for (const relRoot of ROOTS) {
  const files = [];
  (function walk(d) {
    for (const e of fs.readdirSync(d, {withFileTypes: true})) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile() && e.name.endsWith(".sh")) files.push(p);
    }
  })(path.join(process.env.SCAN_ROOT, relRoot));
  let scanned = 0;
  for (const f of files) {
    const src = fs.readFileSync(f, "utf8");
    let i = 0;
    while ((i = src.indexOf(NEEDLE, i)) !== -1) {
      let start = i + NEEDLE.length;
      // A needle on a shell comment line is prose about a program, never one.
      const lineStart = src.lastIndexOf("\n", i) + 1;
      if (/^\s*#/.test(src.slice(lineStart, i))) { i = start; continue; }
      let closer = Q;
      if (src.startsWith(OPEN_NESTED, start)) {
        start += OPEN_NESTED.length;
        closer = ESC_BACKSLASH;
      }
      let out = "";
      let p = start;
      let end = -1;
      for (;;) {
        const q = src.indexOf(closer, p);
        if (q === -1) break;
        // An escaped apostrophe is NOT the end of the program: it closes the
        // shell string, emits one apostrophe and reopens, so the JS receives a
        // literal Q and the scan must continue past it.
        if (closer === Q && src.startsWith(ESC_CONCAT, q)) {
          out += src.slice(p, q) + Q;
          p = q + ESC_CONCAT.length;
          continue;
        }
        if (closer === Q && src.startsWith(ESC_BACKSLASH, q)) {
          out += src.slice(p, q) + Q;
          p = q + ESC_BACKSLASH.length;
          continue;
        }
        out += src.slice(p, q);
        end = q;
        break;
      }
      if (end === -1) break;
      scanned++;
      const line = src.slice(0, start).split("\n").length;
      const name = path.relative(process.env.SCAN_ROOT, f) + ":" + line;
      // THREE tests, because a parse check alone is not enough: a truncation
      // whose prefix happens to be complete JavaScript compiles clean and ships
      // dead. The structural half covers that — after a real closing quote the
      // shell continues with a redirect, a pipe, a paren, an operator or a
      // newline, never with a word character, which is exactly what an
      // apostrophe inside prose leaves behind. The third targets the observed
      // shape most directly: a program whose last line is a line comment ended
      // inside that comment, which is complete JavaScript whenever the
      // apostrophe happens to sit at brace depth 0.
      try { new vm.Script(out); }
      catch (e) { broken.push(name + " (does not parse)"); }
      if (/[A-Za-z0-9_]/.test(src.charAt(end + closer.length))) {
        broken.push(name + " (word character after the closing quote)");
      }
      const lastLine = out.split("\n").pop().trim();
      if (lastLine.startsWith("//")) {
        broken.push(name + " (program ends inside a line comment)");
      }
      i = end + closer.length;
    }
  }
  counts.push(scanned);
}
process.stdout.write(counts[0] + " " + counts[1] + " " + broken.join(","));
' 2>/dev/null)"
S18_HOOKS="${S18_OUT%% *}"
S18_REST="${S18_OUT#* }"
S18_TESTS="${S18_REST%% *}"
S18_BROKEN="${S18_REST#* }"
# A scanner that finds nothing is indistinguishable from a scanner that ran over
# nothing, so each count is a floor as well as a report. The floors are PER ROOT
# rather than one sum: `tests/structure/` outnumbers `hooks/` more than four to
# one, so a single combined floor would still be cleared by a regression that
# stopped descending into `hooks/lib/` entirely. Each floor sits close to its
# measured population (193 and 839 on 2026-09-07), not at a round number well
# below it.
case "$S18_HOOKS" in ''|*[!0-9]*) S18_HOOKS=0 ;; esac
case "$S18_TESTS" in ''|*[!0-9]*) S18_TESTS=0 ;; esac
if [ "$S18_HOOKS" -ge 180 ] && [ "$S18_TESTS" -ge 800 ] && [ -z "$S18_BROKEN" ]; then
  check "S18 every node -e program under hooks/ and tests/structure/ is valid JS (scanned: $S18_HOOKS + $S18_TESTS)" PASS
else
  check "S18 every node -e program under hooks/ and tests/structure/ is valid JS — an apostrophe truncates the bash single-quoted string (scanned: $S18_HOOKS + $S18_TESTS, broken: ${S18_BROKEN:-none})" FAIL
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

# S22 — AC-005. The reminder header states how its fast-path phrase lists relate to
# plan-approved-delegate.sh's, and nothing pinned that claim: a grep over tests/ for
# its distinguishing literals returned nothing, so it could be deleted or re-broken
# with every suite green. It was in fact shipped garbled once, as a duplicated noun
# phrase left by a substitution.
#
# The needles moved when the plan hook grew its four-route delivery question and this
# header was rewritten around it. The property is the same and is now stated in three
# parts: the two lists OVERLAP rather than nest, neither is a superset of the other,
# and this hook mirrors ONLY the TDD half — which is what makes a claim of mirrored
# precedence impossible to write here in the first place. Anchor on those, and keep
# the garble arm FILE-INDEPENDENT rather than on the retired phrase: a substitution
# that duplicates a noun phrase leaves an immediately repeated word run, and that is
# detectable without knowing which sentence broke.
S22_HOOK="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
# Strip the comment marker from each line BEFORE flattening. A needle spanning a
# line break otherwise carries the NEXT line's `#`, which couples it to the physical
# wrap: a benign reflow of this comment turns the check red, and a re-garble wrapped
# one word earlier escapes it entirely. Count OCCURRENCES with grep -o, not lines:
# after flattening the stream is one line, so grep -c can only ever answer 0 or 1.
s22_flat() { sed -n '1,/^set -u/p' "$1" | sed 's/^[[:space:]]*#[[:space:]]\{0,1\}//' | tr '\n' ' ' | tr -s ' '; }
S22_LISTS="$(s22_flat "$S22_HOOK" | grep -o 'OVERLAP rather than nest' | wc -l | tr -d ' ')"
S22_SUPERSET="$(s22_flat "$S22_HOOK" | grep -o 'neither is a superset of the other' | wc -l | tr -d ' ')"
S22_SCOPE="$(s22_flat "$S22_HOOK" | grep -o 'mirrors ONLY the TDD half' | wc -l | tr -d ' ')"
S22_DUP="$(s22_flat "$S22_HOOK" | node -e '
let s = "";
process.stdin.on("data", (c) => { s += c; });
process.stdin.on("end", () => {
  // A substitution that duplicates a noun phrase leaves an immediately repeated
  // run of words. Four is the width: shorter runs occur legitimately, and the
  // observed garble repeated more than four. Measured against this header on
  // 2026-09-07: 228 words, zero repeats, so the arm is not vacuous by luck.
  const w = s.trim().split(/\s+/);
  let hits = 0;
  for (let i = 0; i + 8 <= w.length; i++) {
    if (w.slice(i, i + 4).join(" ") === w.slice(i + 4, i + 8).join(" ")) hits++;
  }
  process.stdout.write(String(hits));
});' 2>/dev/null)"
case "$S22_DUP" in ''|*[!0-9]*) S22_DUP=-1 ;; esac
if [ "$S22_LISTS" -eq 1 ] && [ "$S22_SUPERSET" -eq 1 ] && [ "$S22_SCOPE" -eq 1 ] && [ "$S22_DUP" -eq 0 ]; then
  check "S22 the reminder header states how its phrase lists relate to the plan hook, ungarbled" PASS
else
  check "S22 the reminder header states how its phrase lists relate to the plan hook, ungarbled (overlap=$S22_LISTS superset=$S22_SUPERSET scope=$S22_SCOPE repeats=$S22_DUP)" FAIL
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
// SECOND pair, same file, same reason. The terminal set is the other vocabulary this
// hook hand-copies from that library, and it was the only one of the four with no
// machine pin: S25 covers the review-op key, S26 the return stages, the pair above the
// stages. A stage added to the owner and not here makes a terminal run read as live and
// refuses a standalone claim that should have been recorded — a false refusal, which is
// the direction that strands a chain. The doctor suite already pins `const TERMINAL`
// this way against its own renderer copy; this is the same comparison from the hook side.
// EVERY occurrence, not the first. `grab` returns match[1] of the first hit, so a
// SECOND terminal hand-copy in the same file — the bound branch grew one when the
// terminal-run arm split off from the binding-disagreement catch-all — was invisible
// to this pin while the first copy kept it green. That is the same first-match
// blindness S7u has from the library side, reproduced one file over.
// WHITESPACE-TOLERANT, like the sibling S26 extraction one block down, which already
// spells its own join as `\]\s*\n?\s*\.includes\(`. A `prettier` pass or a hand re-wrap
// that breaks the line between the array literal and `.includes` drops the copy out of
// this comparison, and the only guard below was `c.length === 0` — so ONE surviving copy
// kept the check green while the other went unmeasured.
//
// That is the same hole from the other side, and it is what `sites` closes: extracting
// EITHER copy into a `const TERMINAL_STAGES` leaves the call site spelled
// `TERMINAL_STAGES.includes(s.stage)`, which the bracket-literal pattern cannot match,
// so `c.length` silently falls to 1 while the hook still carries two terminal decisions.
// Counting the CALL SITES and requiring the two counts to agree makes that refactor fail
// loudly instead — and it stays member-agnostic, which a count of `["DONE", "CANCELLED"]`
// literals would not: hardcoding the members here would re-spell the very set this check
// exists to derive from the library.
const all = (src, re) => [...src.matchAll(re)].map(m => members(m[1]));
const c = all(hook, /\[([^\]]*)\]\s*\.includes\(\s*s\.stage\s*\)/g);
const sites = (hook.match(/\.includes\(\s*s\.stage\s*\)/g) || []).length;
const d = members(grab(lib, /^const TERMINAL = new Set\(\[([^\]]*)\]\)/m));
if (a === null || b === null || d === null || c.length === 0) { process.stdout.write("unextractable"); }
else if (c.length !== sites) { process.stdout.write("uncompared terminal " + c.length + "/" + sites); }
else if (a !== b) { process.stdout.write("differ stages"); }
else if (c.some(x => x !== d)) { process.stdout.write("differ terminal"); }
else { process.stdout.write("equal " + a.split(",").length + "+" + c.length + "x" + d.split(",").length); }
' 2>/dev/null)"
case "$S24_OUT" in
  equal\ *) check "S24 the delegate stage allowlist and its terminal pair both match the sets the state library owns ($S24_OUT)" PASS ;;
  *) check "S24 the delegate stage allowlist and its terminal pair both match the sets the state library owns (out=${S24_OUT:-none})" FAIL ;;
esac

# S25 — the team-review operation-key recognizer is a hand-copy of a shape the state
# library mints, and the divergence direction is fail-OPEN: a real header the pattern
# stops matching is treated as absent, so the bound envelope is accepted. This pin
# EXECUTES the producer rather than comparing spellings: it sources
# `autopilot_team_review_operation_key` out of the state library, mints a real key,
# and requires the recognizer to accept the header built from it. A source needle
# alone was the weaker form and was the finding that put this here — it anchored on
# the module-scope JS template and never named the shell verb the delegate is
# actually downstream of, so a rename there would have passed.
#
# The recognizer is the EXACT producer shape now, not a character class. It used to
# read `key=[A-Za-z0-9][A-Za-z0-9_.:-]{2,191}`, which is wider than anything either
# producer can mint and narrower than the `nonEmpty(payload.operationKey, 256)` the
# worker validator accepts — a domain no side owned. Both exact-shape checks the
# library already carries spell it `^team-review:v1:[a-f0-9]{64}$`, so this is the
# third copy of one shape rather than a fourth domain, and the arm below rejects a
# key no producer can mint.
S25_KEY="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash -c '
  set -eu
  . "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-autopilot-state.sh"
  autopilot_team_review_operation_key "s25-run" "0123456789abcdef0123456789abcdef01234567"
' 2>/dev/null)" || S25_KEY=""
S25_OUT="$(HOOK_FILE="$HOOK" LIB_FILE="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" \
  PRODUCED_KEY="$S25_KEY" node -e '
const fs = require("node:fs");
const hook = fs.readFileSync(process.env.HOOK_FILE, "utf8");
const lib = fs.readFileSync(process.env.LIB_FILE, "utf8");
const key = process.env.PRODUCED_KEY;
const m = hook.match(/const REVIEW_OP_RE = (\/\^AUTOPILOT-REVIEW-OP:[^\n]*?\/);/);
if (!key) { process.stdout.write("no-produced-key"); }
else if (!m) { process.stdout.write("no-recognizer"); }
// BOTH producers must still be named. The key above came from the shell verb, so
// that half is proven by construction; the JS template is the one a run under the
// worker mints from, and anchoring on either alone lets a rename of the other pass.
else if (lib.indexOf("autopilot_team_review_operation_key()") < 0) {
  process.stdout.write("no-shell-producer");
}
else if (!/team-review:v1:\$\{digest\(/.test(lib)) { process.stdout.write("no-js-producer"); }
else {
  // new RegExp, never eval: the capture is source text, and a constructor can only
  // ever build a pattern where eval could call a function spliced into the literal.
  const re = new RegExp(m[1].slice(1, -1));
  const sha = "0123456789abcdef0123456789abcdef01234567";
  const line = "AUTOPILOT-REVIEW-OP: key=" + key + " head=" + sha;
  // The NEGATIVE arms are what a prefix regression needs. A pattern relaxed back to
  // a bare prefix accepts a quoted column-0 placeholder and vetoes a live envelope,
  // which is the defect the recognizer shape exists to prevent; a pattern relaxed
  // back to a character class accepts a key neither producer can mint, which is the
  // domain the tightening removed.
  const placeholder = "AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>";
  const unmintable = "AUTOPILOT-REVIEW-OP: key=" + "z".repeat(79) + " head=" + sha;
  if (!re.test(line)) { process.stdout.write("rejects-a-real-key"); }
  else if (re.test(placeholder)) { process.stdout.write("accepts-a-placeholder"); }
  else if (re.test(unmintable)) { process.stdout.write("accepts-an-unmintable-key"); }
  else { process.stdout.write("matches"); }
}
' 2>/dev/null)"
if [ "$S25_OUT" = matches ]; then
  check "S25 the review-op recognizer accepts a key the state library actually minted, and only that shape" PASS
else
  check "S25 the review-op recognizer accepts a key the state library actually minted, and only that shape (out=${S25_OUT:-none})" FAIL
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

# S27 — AC-010 / AC-011. The standalone deliberate-spoof decline (the S20 shape) took
# `${2:-respawn}` because its call site passed no mode, so the model was handed the
# ticket-ROTATING remedy for a cause a re-spawn cannot change: the envelope triple can
# come from a REVIEW PACKET quoting this very file, and the packet regenerates from
# the same bytes on every spawn. Two properties, asserted together: the emitted remedy
# is the ENVELOPE one — this decline is decided on prompt content alone, and the header
# said "the run-state one" while the assertions below required the envelope remedy and
# NEGATED two run-state prescriptions, so one check carried two opposite contracts — and
# the selector itself is a `case` over a named mode with a
# catch-all arm, so an unknown or omitted mode can never fall through to the rotation
# text again. The source half is what a behavioural case cannot see — no fixture can
# pass a misspelled mode to a function internal to the hook.
start_session spoof-runstate-remedy
S27="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S27"
log --tdd-complete --session "$S27"
S27_TICKET="$(issue_ticket "$S27")"
OUT="$(run_hook "$S27" zensu:code-reviewer "$MARKER
REVIEW-TICKET: $S27_TICKET
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=run-fixture attempt=1 chain=chain-fixture
AUTOPILOT-STAGE: GATES")"
s27_decline_body() { awk '/^decline\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HOOK"; }
# PER-BLOCK, never body-wide. Counting `*)` across the whole decline() body and comparing
# the total to the selector count is satisfied by a coincidence of layout: a `case` over
# some OTHER value carrying a catch-all restores the equality while a `$mode` selector
# loses its own. Each `case "$mode" in` … `esac` region is sliced instead and reports its
# own `<catch-all> <spent>` pair, so the property is asserted where it holds.
s27_mode_block_arms() {
  s27_decline_body | awk '
    index($0,"case \"$mode\" in")>0 { blk=1; c=0; s=0; next }
    blk && /^[[:space:]]*esac/ { printf "%d %d\n", c, s; blk=0; next }
    blk && /^[[:space:]]+\*\)/ { c++ }
    blk && /^[[:space:]]+spent\)/ { s++ }
  '
}
S27_BODY_LINES="$(s27_decline_body | wc -l | tr -d ' ')"
S27_CASE_HEAD="$(s27_decline_body | grep -cF -- 'case "$mode" in' || true)"
S27_BLOCKS="$(s27_mode_block_arms | wc -l | tr -d ' ')"
S27_BAD_BLOCKS="$(s27_mode_block_arms | grep -cvE '^1 1$' || true)"
# The catch-all pair above is NOT enough, and the gap it left is the one this arm
# closes. It counts `*)` and `spent)` only, so a NAMED mode arm can be deleted with
# every block still reporting `1 1`: the mode then falls to `*)` and renders
# `runstate_remedy`, which prescribes actions that have no referent for the cause
# that was actually refused — exactly the contradiction the `envelope` and
# `envelope-record` splits exist to remove. So the required arm set is DERIVED from
# the `decline "…" <mode>` call sites rather than written down here; a literal list
# would be a hand-maintained census that goes stale the next time a mode is added,
# which is the failure this file records elsewhere about its own numerals.
# Only the REMEDY selector is held to it. The operator-lead and opener selectors
# legitimately serve every non-`spent` mode from their catch-all, so requiring the
# full set in all three blocks would fail on correct code; the remedy block is
# identified by its arms assigning `remedy=` rather than by its position.
s27_call_site_modes() {
  grep -oE 'decline "[^"]*" [a-z][a-z-]*' "$HOOK" | grep -oE '[a-z][a-z-]*$' | sort -u
}
s27_remedy_block_arms() {
  s27_decline_body | awk '
    index($0,"case \"$mode\" in")>0 { blk=1; n=0; isr=0; next }
    blk && /^[[:space:]]*esac/ { if (isr) for (i=1;i<=n;i++) print arm[i]; blk=0; next }
    blk && match($0, /^[[:space:]]+[a-z*][a-z-]*\)/) {
      a=$0; sub(/^[[:space:]]+/,"",a); sub(/\).*$/,"",a); arm[++n]=a
      if (index($0,"remedy=")>0) isr=1
    }
  '
}
S27_MODES="$(s27_call_site_modes)"
S27_MODE_COUNT="$(printf '%s\n' "$S27_MODES" | grep -c . || true)"
S27_REMEDY_ARMS="$(s27_remedy_block_arms)"
S27_REMEDY_ARM_COUNT="$(printf '%s\n' "$S27_REMEDY_ARMS" | grep -c . || true)"
S27_ARM_MISSING=""
for s27_mode in $S27_MODES; do
  printf '%s\n' "$S27_REMEDY_ARMS" | grep -qxF -- "$s27_mode" || S27_ARM_MISSING="$S27_ARM_MISSING $s27_mode"
done
S27_ARM_MISSING="${S27_ARM_MISSING# }"
# The OTHER direction, which `[ "$S27_REMEDY_ARM_COUNT" -gt "$S27_MODE_COUNT" ]` could
# never test: that comparison is implied by its own siblings. With `S27_ARM_MISSING`
# empty the arms are a superset of the call-site modes, and the per-block `*)` the
# `S27_BAD_BLOCKS` conjunct already requires is never a call-site mode, so `-gt` held by
# construction and passed for a tree in which every real property had been deleted. What
# it was reaching for is the RETIRED-MODE direction — a mode dropped from every call site
# leaving its remedy arm behind, which is dead text a later caller can select by typo —
# so that is asserted directly instead.
# Read LINE-WISE, never by word splitting: the arm set contains the literal `*`, and an
# unquoted `for` over it pathname-expands that arm into the repository listing, so every
# top-level entry was reported as a retired mode and the guard below could never pass.
S27_ARM_EXTRA=""
while IFS= read -r s27_arm; do
  [ -n "$s27_arm" ] || continue
  [ "$s27_arm" = "*" ] && continue
  printf '%s\n' "$S27_MODES" | grep -qxF -- "$s27_arm" || S27_ARM_EXTRA="$S27_ARM_EXTRA $s27_arm"
done <<EOF_S27_ARMS
$S27_REMEDY_ARMS
EOF_S27_ARMS
S27_ARM_EXTRA="${S27_ARM_EXTRA# }"
# The CLAIM-PHASE classifier. `decline()` decides THREE texts — the operator lead, the
# model-facing lead and the model-facing opener — by claim phase rather than by mode name,
# and each of them used to test the single literal `spent` or sit in a per-mode `case` arm,
# so a second post-claim mode would have told the reader the completion was not recorded
# while its ticket was consumed and its round counted. The phase is derived ONCE now, from
# an enumerated set, and all THREE phase-dependent texts read that answer: the body must
# declare the set exactly once, use it three times, and carry the literal `spent)` in the
# REMEDY selector alone. Raise the use count with the next phase-dependent text; a floor
# that lags the tree lets one of them silently revert to an arm-keyed assignment.
S27_CLASSIFIER="$(s27_decline_body | grep -cE '^[[:space:]]*local post_claim_modes=' || true)"
# COMMENT-FILTERED like its siblings: a line of prose in `decline()` quoting this
# literal would inflate the count and mask the deletion of one of the three real
# phase-dependent reads the `-ge 3` floor exists to hold.
S27_PHASE_USES="$(s27_decline_body | grep -F -- '"$post_claim" = "yes"' | grep -cvE '^[[:space:]]*(//|#)' || true)"
S27_SPENT_ARMS="$(s27_decline_body | grep -cE '^[[:space:]]*spent\)' || true)"
# EVERY `$mode` selector, however many there are. State it that way and never as a count:
# this comment read "three times" while exactly ONE `case "$mode" in` has ever existed in
# that body, because the other two texts branch on the derived claim phase instead. The
# property is per-selector: no `$mode` dispatch may fall through, and none may let the
# post-claim mode land in its catch-all, so every sliced block must carry exactly one `*)`
# and one `spent)` arm — which is why the slicer reports a pair per block rather than a
# total. A second `$mode` selector added later is covered without editing this check.
# S28 reads the same slices for the `spent` half.
#
# The DECLINE this drives is the standalone envelope mismatch, which is decided on PROMPT
# CONTENT ALONE — the gate reads `tool_input.prompt` and runs before any durable record is
# opened. It therefore takes the `envelope` remedy, not the run-state one: the remedy names
# the prompt as the refused input, withholds the ticket ROTATION, prescribes a re-spawn with
# the ticket the chain already holds, and instructs no edit under `.zensu/state/`. The two
# NEGATIVE needles are the discriminator, and they are the run-state text's own
# prescriptions rather than a bare `--autopilot-status` mention: the envelope remedy names
# that verb too, to forbid reading it here, so its presence proves nothing while
# `Resolve the durable run state first` and `finish or release that run` appear only in
# `runstate_remedy`. NAME THE LITERALS THIS CHECK ACTUALLY USES: an earlier wording here
# named `repair the unreadable record`, which occurs in no shipped file at all, so a
# maintainer following this comment went looking for a discriminator that does not exist.
# Their ABSENCE is what proves this decline did not inherit the
# run-state text whose first sentence denies the prompt was the cause.
[ -n "$S27_TICKET" ] && [ "$S27_BODY_LINES" -gt 3 ] \
  && printf '%s' "$OUT" | grep -qF -- "was NOT recorded against this session's review chain" \
  && printf '%s' "$OUT" | grep -qF -- 'Do NOT issue a fresh review ticket' \
  && printf '%s' "$OUT" | grep -qF -- 'the Autopilot envelope in the PROMPT' \
  && printf '%s' "$OUT" | grep -qF -- 'SAME ticket the chain already holds' \
  && printf '%s' "$OUT" | grep -qF -- 'do not edit anything under .zensu/state/' \
  && ! printf '%s' "$OUT" | grep -qF -- 'Resolve the durable run state first' \
  && ! printf '%s' "$OUT" | grep -qF -- 'finish or release that run' \
  && ! printf '%s' "$OUT" | grep -qF -- "$S27_TICKET" \
  && [ "$S27_CASE_HEAD" -ge 1 ] && [ "$S27_BLOCKS" = "$S27_CASE_HEAD" ] && [ "$S27_BAD_BLOCKS" -eq 0 ] \
  && [ "$S27_MODE_COUNT" -ge 5 ] && [ -z "$S27_ARM_MISSING" ] && [ -z "$S27_ARM_EXTRA" ] \
  && [ "$S27_CLASSIFIER" -eq 1 ] && [ "$S27_PHASE_USES" -ge 3 ] && [ "$S27_SPENT_ARMS" -eq 1 ] \
  && check "S27 the standalone envelope-mismatch decline takes the envelope remedy (prompt named, no rotation, no state edit, no run-state prescriptions), every decline() mode selector carries its own catch-all arm ($S27_BLOCKS blocks), the remedy selector names every one of the $S27_MODE_COUNT call-site modes and no retired extras, and the claim phase is derived once and read by all three phase-dependent texts" PASS \
  || check "S27 the standalone envelope-mismatch decline takes the envelope remedy (prompt named, no rotation, no state edit, no run-state prescriptions), every decline() mode selector carries its own catch-all arm, the remedy selector names every call-site mode and no retired extras, and the claim phase is derived once (body=$S27_BODY_LINES case-head=$S27_CASE_HEAD blocks=$S27_BLOCKS bad=$S27_BAD_BLOCKS modes=$S27_MODE_COUNT remedy-arms=$S27_REMEDY_ARM_COUNT unserved='$S27_ARM_MISSING' retired='$S27_ARM_EXTRA' classifier=$S27_CLASSIFIER phase-uses=$S27_PHASE_USES spent-arms=$S27_SPENT_ARMS)" FAIL

# S28 — AC-015. Below the claim the ticket is consumed and the round is counted, so a
# bare `exit 0` there is a DIFFERENT silent loss from the pre-claim one: the budget has
# moved and the merged findings are dropped with nothing on any channel, and
# `--chain-status` then reports `ticket-spent` with a remedy that says nothing about why
# the findings vanished. Two regions carry every post-claim exit — the claim-context
# block (from `CLAIM_FIELDS=` to the vanilla-mode split) and the terminal-marking block
# (from the first `tdd_mark_` call to the `chainDone` mark) — and none of those exits
# is reachable from a fixture: the three kind/binding mismatches need a record moved
# between two reads of one hook run, and a failed mark needs a CAS that succeeds for
# the claim and fails for the mark. Source pin, with controls that both extractions
# are non-empty and anchored on the lines they are named after. The `spent` arm count is
# held against the SELECTOR count S27 derives rather than against a literal. State the
# derivation the way S27's own comment now states it: the remedy selector is the ONE
# `case "$mode" in` dispatch in that body, and it must name `spent` explicitly, while the
# operator lead and the model-facing opener branch on the DERIVED `post_claim` phase and
# name no mode at all. An earlier wording here said both dispatch on `$mode` and both must
# name `spent` — which contradicts S27's `S27_SPENT_ARMS -eq 1` one check up, and describes
# a body that has never existed. What the property protects is unchanged: a selector that
# let the post-claim mode fall into its catch-all would tell the operator the round was not
# recorded while the model is told it was.
s28_region_claim() { awk '/^CLAIM_FIELDS=/{f=1} index($0,"tdd_vanilla_mode")>0{exit} f{print}' "$HOOK"; }
s28_region_mark() { awk 'index($0,"tdd_mark_autopilot_max_round_handoff")>0{f=1} f{print} f&&index($0,"tdd_mark_review_converged")>0&&index($0,"chainDone")>0{exit}' "$HOOK"; }
S28_CLAIM_LINES="$(s28_region_claim | wc -l | tr -d ' ')"
S28_MARK_LINES="$(s28_region_mark | wc -l | tr -d ' ')"
S28_BARE_RE='(^|[^[:alnum:]_])exit 0($|[^[:alnum:]_])'
S28_SPENT_RE='decline "[^"]+" spent([[:space:]]|$)'
S28_CLAIM_BARE="$(s28_region_claim | grep -cE "$S28_BARE_RE" || true)"
S28_MARK_BARE="$(s28_region_mark | grep -cE "$S28_BARE_RE" || true)"
S28_CLAIM_SPENT="$(s28_region_claim | grep -cE "$S28_SPENT_RE" || true)"
S28_MARK_SPENT="$(s28_region_mark | grep -cE "$S28_SPENT_RE" || true)"
# PER-BLOCK for the reason S27 states: a body-wide `spent)` tally is satisfied by a second
# selector carrying two of them while a `$mode` block carries none. S28 reads the same
# slices rather than trusting S27 to have read them, so deleting S27 cannot make this
# vacuous.
S28_SPENT_ARM="$(s27_mode_block_arms | awk '$2==1' | wc -l | tr -d ' ')"
[ "$S28_CLAIM_LINES" -gt 5 ] && [ "$S28_MARK_LINES" -gt 5 ] \
  && s28_region_claim | grep -qF 'CLAIM_FIELDS=' \
  && s28_region_claim | grep -qF 'AUTOPILOT_BOUND=false' \
  && s28_region_mark | grep -qF 'tdd_mark_autopilot_max_round_handoff' \
  && [ "$S28_CLAIM_BARE" -eq 0 ] && [ "$S28_MARK_BARE" -eq 0 ] \
  && [ "$S28_CLAIM_SPENT" -ge 5 ] && [ "$S28_MARK_SPENT" -ge 4 ] \
  && [ "$S28_SPENT_ARM" -ge 1 ] && [ "$S28_SPENT_ARM" = "$S27_CASE_HEAD" ] \
  && check "S28 no bare exit remains below the claim; every post-claim exit routes through the spent remedy, which every decline() mode selector names explicitly ($S28_SPENT_ARM/$S27_CASE_HEAD)" PASS \
  || check "S28 no bare exit remains below the claim; every post-claim exit routes through the spent remedy, which every decline() mode selector names explicitly (claim: lines=$S28_CLAIM_LINES bare=$S28_CLAIM_BARE spent=$S28_CLAIM_SPENT; mark: lines=$S28_MARK_LINES bare=$S28_MARK_BARE spent=$S28_MARK_SPENT; arm=$S28_SPENT_ARM selectors=$S27_CASE_HEAD)" FAIL

# S28a — the spent arm's TEXT, which the source pin cannot see and no hook fixture can
# reach. The extracted decline() is evaluated in a subshell with its two guards
# satisfied the way a post-claim caller satisfies them — an outstanding-ticket verdict
# read before the claim, and a matched ticket value — and emit_post_context replaced
# by cat. The spent text must state that the round was consumed and the findings were
# not routed, must route through --chain-status, must not describe the ticket as
# unclaimed, must not carry the pre-claim do-not-rotate remedy, and must not echo the
# ticket value. The runstate render in the same harness is the control that the
# harness discriminates rather than passing on an empty capture.
s28a_render() {
  (
    emit_post_context() { cat; }
    LOG_COMMAND="S28A_LOGCMD"; CHAIN_TICKET_WAS_OUTSTANDING=yes; PROMPT_CONSUME_INTENT=no
    REVIEW_TICKET="s28a-ticket-value"
    eval "$(s27_decline_body)"
    decline "$1" "$2"
  ) 2>/dev/null
}
S28A_SPENT="$(s28a_render "the claim context did not parse" spent)"
S28A_CONTROL="$(s28a_render "the run has not reached a terminal stage" runstate)"
# The MINT is what separates the spent arm from `run_gone_remedy`, and without it the
# whole positive set above passed under a `spent)` arm mapped to that text: the lead
# sentence is phase-selected rather than remedy-selected, `--chain-status` appears in
# both, `Do NOT arm a new chain` is the shared tail, and every negative literal is
# absent from run-gone too. So the check named for pinning the mint never looked at it.
# Both directions are asserted: the mint present here, and run-gone's own opening
# sentence absent.
S28A_MINT='S28A_LOGCMD --review-ticket'
S28A_RUNGONE_LEAD='designates no LIVE durable Autopilot run'
# NAMED conjuncts, because the two checks below carry seventeen and twelve terms and used
# to report nothing but the two capture lengths — which says the render happened and
# nothing about WHICH needle moved, leaving a maintainer to bisect them by hand. Every
# sibling in this tree already names the failing term: S27 reports its derived counters,
# S34 its per-arm counts, and `p15_fail` in the handoff suite names the conjunct. The
# accumulator is what makes the failure list the diagnosis. A `!` prefix on a label marks
# a needle that was required to be ABSENT and was found, so the two directions stay
# distinguishable in one line. Both helpers `return 0` unconditionally: the suite runs
# under `set -u` and not `set -e`, but a helper whose exit status tracked its own verdict
# would read as a conjunct at every call site and invite exactly the chain this replaces.
S28A_FAILED=""
s28a_need() {
  printf '%s' "$2" | grep -qF -- "$3" || S28A_FAILED="$S28A_FAILED $1"
  return 0
}
s28a_deny() {
  if printf '%s' "$2" | grep -qF -- "$3"; then S28A_FAILED="$S28A_FAILED !$1"; fi
  return 0
}
[ -n "$S28A_SPENT" ] || S28A_FAILED="$S28A_FAILED spent-render-empty"
[ -n "$S28A_CONTROL" ] || S28A_FAILED="$S28A_FAILED control-render-empty"
s28a_need spent-findings-dropped  "$S28A_SPENT"   'its findings were NOT routed'
s28a_need spent-chain-status      "$S28A_SPENT"   'S28A_LOGCMD --chain-status'
s28a_need spent-mints-replacement "$S28A_SPENT"   "$S28A_MINT"
s28a_deny spent-run-gone-lead     "$S28A_SPENT"   "$S28A_RUNGONE_LEAD"
s28a_need spent-no-new-chain      "$S28A_SPENT"   'Do NOT arm a new chain'
s28a_deny spent-outstanding-lead  "$S28A_SPENT"   'unclaimed review ticket'
s28a_deny spent-withholds-ticket  "$S28A_SPENT"   'Do NOT issue a fresh review ticket'
s28a_deny spent-respawn-text      "$S28A_SPENT"   'whose FIRST line is exactly'
s28a_deny spent-echoes-ticket     "$S28A_SPENT"   's28a-ticket-value'
s28a_need spent-opener-recorded   "$S28A_SPENT"   "completion WAS recorded against this session's review chain"
s28a_deny spent-opener-not-recorded "$S28A_SPENT" 'was NOT recorded against this session'
s28a_need control-outstanding-lead "$S28A_CONTROL" 'unclaimed review ticket'
s28a_need control-withholds-ticket "$S28A_CONTROL" 'Do NOT issue a fresh review ticket'
s28a_need control-opener-not-recorded "$S28A_CONTROL" "was NOT recorded against this session's review chain"
s28a_need control-resolve-run-state "$S28A_CONTROL" 'Resolve the durable run state first'
s28a_need control-finish-or-release "$S28A_CONTROL" 'finish or release that run'
# POSITIVE, because the literal this was written against exists nowhere in the tree.
# As a `deny` on `repair the unreadable record` the conjunct could never fire — the
# same class CLAUDE.md records for S7d — so the check title claimed the run-state
# control "prescribes no repair under .zensu/state/" while nothing measured it.
# `runstate_remedy` spells the clause as a PROHIBITION, so assert the prohibition.
s28a_need control-no-state-repair  "$S28A_CONTROL" 'Do not edit anything under .zensu/state/'
s28a_deny control-teaches-channel  "$S28A_CONTROL" 'ungated only because no gate covers it'
S28A_FAILED="${S28A_FAILED# }"
[ -z "$S28A_FAILED" ] \
  && check "S28a the spent arm states the consumed round and the unrouted findings, routes through --chain-status, mints its replacement rather than re-spawning on the consumed ticket or inheriting the run-gone text, opens by saying the completion WAS recorded, and never echoes the ticket; the runstate control carries its discriminator literals and prescribes no repair under .zensu/state/" PASS \
  || check "S28a the spent arm states the consumed round and the unrouted findings, routes through --chain-status, mints its replacement rather than re-spawning on the consumed ticket or inheriting the run-gone text, opens by saying the completion WAS recorded, and never echoes the ticket; the runstate control carries its discriminator literals and prescribes no repair under .zensu/state/ (failed: $S28A_FAILED; spent=${#S28A_SPENT} chars, control=${#S28A_CONTROL} chars)" FAIL

# S28b — the two remedy arms nothing reached. `run-gone` occurs in `tests/` in no
# assertion at all and `envelope-record` only in a comment, so both mappings could be
# rewritten to another remedy with every suite green: `run-gone` to the run-state text
# its own arm exists to remove, and `envelope-record` to `respawn_remedy`, which
# restores the ticket rotation that arm was split off to withhold. Each is rendered
# through the same harness and held to the text its mode owns, in both directions.
S28A_RUNGONE="$(s28a_render "this session's owner-keyed Autopilot pointer is absent" run-gone)"
S28A_ENVREC="$(s28a_render "the prompt envelope disagrees with this chain's own record" envelope-record)"
S28A_FAILED=""
[ -n "$S28A_RUNGONE" ] || S28A_FAILED="$S28A_FAILED run-gone-render-empty"
[ -n "$S28A_ENVREC" ] || S28A_FAILED="$S28A_FAILED envelope-record-render-empty"
s28a_need run-gone-own-lead        "$S28A_RUNGONE" "$S28A_RUNGONE_LEAD"
s28a_need run-gone-autopilot-status "$S28A_RUNGONE" 'S28A_LOGCMD --autopilot-status'
s28a_need run-gone-chain-status    "$S28A_RUNGONE" 'S28A_LOGCMD --chain-status'
s28a_deny run-gone-runstate-text   "$S28A_RUNGONE" 'Resolve the durable run state first'
s28a_deny run-gone-mints-ticket    "$S28A_RUNGONE" "$S28A_MINT"
s28a_need envrec-withholds-ticket  "$S28A_ENVREC"  'Do NOT issue a fresh review ticket'
s28a_need envrec-names-prompt      "$S28A_ENVREC"  'the Autopilot envelope in the PROMPT'
s28a_need envrec-chain-status      "$S28A_ENVREC"  'S28A_LOGCMD --chain-status'
s28a_need envrec-same-ticket       "$S28A_ENVREC"  'SAME ticket the chain already holds'
s28a_deny envrec-respawn-text      "$S28A_ENVREC"  'whose FIRST line is exactly'
s28a_deny envrec-mints-ticket      "$S28A_ENVREC"  "$S28A_MINT"
s28a_deny envrec-runstate-text     "$S28A_ENVREC"  'Resolve the durable run state first'
S28A_FAILED="${S28A_FAILED# }"
[ -z "$S28A_FAILED" ] \
  && check "S28b the run-gone arm renders its own text rather than the run-state one and mints no ticket, and the envelope-record arm names the prompt and this chain's own record while withholding the rotation respawn_remedy would have performed" PASS \
  || check "S28b the run-gone arm renders its own text rather than the run-state one and mints no ticket, and the envelope-record arm names the prompt and this chain's own record while withholding the rotation respawn_remedy would have performed (failed: $S28A_FAILED; run-gone=${#S28A_RUNGONE} chars, envelope-record=${#S28A_ENVREC} chars)" FAIL

# S28c — S28b renders the run-gone TEXT through the harness and proves nothing about WHICH
# call site selects that mode. Both selections were unpinned: greps for
# `no live run for the bound claim` and `already reached a terminal stage` returned zero
# matches anywhere under `tests/`, so changing either call site to `runstate` stayed green
# in every suite — and that is the one mode whose remedy opens by denying the run state is
# what was refused. The two causes are DIFFERENT states and each owns its own arm: the
# owner-keyed pointer FILE is absent, and the run that pointer designates has reached a
# terminal stage. The terminal arm additionally needs its exit-5 PRODUCER pinned, because
# deleting that `process.exit(5)` routes the state to the catch-all and the arm goes dead
# with its own literal still sitting in the file — an arm nothing can reach passes every
# text-only check. Both directions are asserted: the mode is selected here, and neither
# cause is selected with `runstate`.
S28C_SELECTIONS="$(grep -cE 'decline "[^"]*" run-gone ;;' "$HOOK" || true)"
S28C_POINTER="$(grep -cE 'decline "[^"]*pointer is absent[^"]*" run-gone ;;' "$HOOK" || true)"
S28C_TERMINAL="$(grep -cE 'decline "[^"]*already reached a terminal stage[^"]*" run-gone ;;' "$HOOK" || true)"
# The ARM KEY, not just the text. Every needle above matches from `decline` rightward
# and constrains nothing to its left, so changing `5)` to `6)` — or `1)` to `2)` —
# leaves all three counts intact while the state falls to the `*)` catch-all and takes
# `runstate` or `runstate-foreign` instead. That is the exact misrouting this check is
# named for, and it is the shape the sibling S30b already avoids by anchoring its count
# on `^[[:space:]]*4\) decline `. The two keys are the STATUSES their producers emit:
# rc 1 from the owner-scoped active read, and `process.exit(5)` from the terminal probe.
S28C_POINTER_KEY="$(grep -cE '^[[:space:]]*1\) decline "[^"]*pointer is absent[^"]*" run-gone ;;' "$HOOK" || true)"
S28C_TERMINAL_KEY="$(grep -cE '^[[:space:]]*5\) decline "[^"]*already reached a terminal stage[^"]*" run-gone ;;' "$HOOK" || true)"
S28C_EXIT5="$(grep -F -- 'process.exit(5)' "$HOOK" | grep -cvE '^[[:space:]]*(//|#)' || true)"
S28C_PAIR="$(grep -cF -- '.includes(s.stage)) process.exit(5)' "$HOOK" || true)"
[ "$S28C_SELECTIONS" -eq 2 ] && [ "$S28C_POINTER" -eq 1 ] && [ "$S28C_TERMINAL" -eq 1 ] \
  && [ "$S28C_POINTER_KEY" -eq 1 ] && [ "$S28C_TERMINAL_KEY" -eq 1 ] \
  && [ "$S28C_EXIT5" -eq 1 ] && [ "$S28C_PAIR" -eq 1 ] \
  && grep -qF -- 'no live run for the bound claim' "$HOOK" \
  && ! grep -qE 'decline "[^"]*already reached a terminal stage[^"]*" runstate' "$HOOK" \
  && ! grep -qE 'decline "[^"]*pointer is absent[^"]*" runstate' "$HOOK" \
  && check "S28c both run-gone call sites select that mode by name AND sit on the status key their producer emits — the absent owner pointer at rc 1 and this session's own terminal run at exit 5 — and the terminal arm keeps the exit-5 producer that is the only thing able to reach it" PASS \
  || check "S28c both run-gone call sites select that mode by name AND sit on the status key their producer emits — the absent owner pointer at rc 1 and this session's own terminal run at exit 5 — and the terminal arm keeps the exit-5 producer that is the only thing able to reach it (selections=$S28C_SELECTIONS pointer=$S28C_POINTER/$S28C_POINTER_KEY terminal=$S28C_TERMINAL/$S28C_TERMINAL_KEY exit5=$S28C_EXIT5 pair=$S28C_PAIR)" FAIL

# S29 — AC-014. The model-facing disclosure is gated on consume intent, so a decline
# whose prompt showed none reaches nobody: the chain keeps an unclaimed ticket and every
# channel is silent. One OPERATOR line closes that, and it must sit BELOW the
# outstanding-ticket guard and ABOVE the consume-intent one — below, because a
# completion from a flow that armed no chain strands nothing; above, because the
# withheld-disclosure case is the one the line exists for. The decline body is evaluated
# the way S28a evaluates it, with stdout discarded and stderr captured, so the two
# channels are observed separately.
s29_stderr() {
  (
    emit_post_context() { cat >/dev/null; }
    LOG_COMMAND="S29_LOGCMD"; CHAIN_TICKET_WAS_OUTSTANDING="$1"; PROMPT_CONSUME_INTENT="$2"
    REVIEW_TICKET="$3"
    eval "$(s27_decline_body)"
    decline "the s29 gate under test refused" "$4"
  ) 2>&1 >/dev/null
}
s29_stdout() {
  (
    emit_post_context() { cat; }
    LOG_COMMAND="S29_LOGCMD"; CHAIN_TICKET_WAS_OUTSTANDING="$1"; PROMPT_CONSUME_INTENT="$2"
    REVIEW_TICKET="$3"
    eval "$(s27_decline_body)"
    decline "the s29 gate under test refused" "$4"
  ) 2>/dev/null
}
S29_WITHHELD_ERR="$(s29_stderr yes no "" runstate)"
S29_WITHHELD_OUT="$(s29_stdout yes no "" runstate)"
S29_DISCLOSED_ERR="$(s29_stderr yes yes s29-ticket-value respawn)"
S29_NOCHAIN_ERR="$(s29_stderr no yes s29-ticket-value respawn)"
[ -n "$S29_WITHHELD_ERR" ] && [ -z "$S29_WITHHELD_OUT" ] \
  && printf '%s' "$S29_WITHHELD_ERR" | grep -qF -- 'the s29 gate under test refused' \
  && printf '%s' "$S29_WITHHELD_ERR" | grep -qF -- '(runstate)' \
  && [ "$(printf '%s' "$S29_WITHHELD_ERR" | grep -c '' )" -eq 1 ] \
  && printf '%s' "$S29_DISCLOSED_ERR" | grep -qF -- '(respawn)' \
  && ! printf '%s' "$S29_DISCLOSED_ERR" | grep -qF -- 's29-ticket-value' \
  && [ -z "$S29_NOCHAIN_ERR" ] \
  && check "S29 every decline mirrors one stderr line naming the gate and the mode, including the one whose model-facing disclosure is withheld, and never for a chainless completion" PASS \
  || check "S29 every decline mirrors one stderr line naming the gate and the mode, including the one whose model-facing disclosure is withheld, and never for a chainless completion (withheld-err=${#S29_WITHHELD_ERR} withheld-out=${#S29_WITHHELD_OUT} disclosed-err=${#S29_DISCLOSED_ERR} nochain-err=${#S29_NOCHAIN_ERR})" FAIL

# S30 — AC-016. The workflow-document decline used to say the document "did not validate
# as a chain", which names no field and sends a reader at the whole document. What that
# gate actually judges is the Autopilot LINKAGE block, so the cause names it and its five
# fields. Source pin: the branch needs a document carrying a partial linkage between two
# reads of one hook run, which no fixture can build.
S30_NEW="$(grep -cF -- 'carries an incomplete or invalid Autopilot linkage block' "$HOOK" || true)"
S30_OLD="$(grep -cF -- 'did not validate as a chain' "$HOOK" || true)"
S30_MODE="$(grep -cE 'carries an incomplete or invalid Autopilot linkage block.*" runstate' "$HOOK" || true)"
[ "$S30_NEW" -eq 1 ] && [ "$S30_OLD" -eq 0 ] && [ "$S30_MODE" -eq 1 ] \
  && grep -qF -- '(run, attempt, return stage, chain id, outcome)' "$HOOK" \
  && check "S30 the workflow-document decline names the Autopilot linkage block and keeps the run-state remedy" PASS \
  || check "S30 the workflow-document decline names the Autopilot linkage block and keeps the run-state remedy (new=$S30_NEW old=$S30_OLD mode=$S30_MODE)" FAIL

# S30b — the FAULT-vs-VERDICT split, which nothing pinned in either direction. Every
# `node -e` pipe in this hook answers 3 for a JUDGED disagreement and 4 for a fault that
# stopped it judging at all: a stdin read that threw, or a reader module that would not
# load. Reverting any `process.exit(4)` to 3 and deleting its `4)` arm was byte-silent
# under every other check here — the fault then renders the VERDICT cause, telling the
# model its workflow document carries an invalid linkage block, or that its binding
# disagrees with a record nothing managed to read, and the run-state remedy then sends it
# to resolve a document nothing opened. That is the sibling of the rule S30 pins one arm
# up, and CLAUDE.md states it for the plan-payload gate in the same words: a load fault is
# never reported as a judged payload. DERIVED, never a list: producers and consumers are
# counted and compared, so a fourth pipe is covered without editing this check. Each
# consumer is held to a could-not-read cause and to `runstate`, and the negative conjunct
# is what catches the revert — a `4)` arm carrying a verdict cause is the defect itself.
#
# The `runstate` conjunct pins TODAY'S ROUTING and must never be read as endorsing it. A
# review round recorded an OPEN finding against exactly that choice: `runstate_remedy`
# prescribes `--autopilot-status` and `finish or release that run`, which has no referent for
# a document or reader-module fault and is reachable on a standalone chain with no durable run
# at all. Closing it properly means a mode of its own with its own remedy — a new arm in the
# remedy selector, new call sites, and S27's derived mode set moving with them — so it was
# deliberately not taken inside a fix round. Until it is, this conjunct is what keeps the arms
# off `respawn`, whose remedy ROTATES the ticket; when the dedicated mode lands, change this
# needle deliberately rather than reading a green check as a contract.
S30B_PRODUCERS="$(grep -F -- 'process.exit(4)' "$HOOK" | grep -cvE '^[[:space:]]*(//|#)' || true)"
S30B_ARMS="$(grep -cE '^[[:space:]]*4\) decline ' "$HOOK" || true)"
S30B_READ_CAUSE="$(grep -cE '^[[:space:]]*4\) decline "[^"]*could not be (read|loaded)' "$HOOK" || true)"
S30B_MODE="$(grep -cE '^[[:space:]]*4\) decline "[^"]*" runstate ;;' "$HOOK" || true)"
S30B_LEAK="$(grep -cE '^[[:space:]]*4\) decline "[^"]*(incomplete or invalid|disagrees with)' "$HOOK" || true)"
[ "$S30B_PRODUCERS" -ge 3 ] && [ "$S30B_ARMS" -eq "$S30B_PRODUCERS" ] \
  && [ "$S30B_READ_CAUSE" -eq "$S30B_ARMS" ] && [ "$S30B_MODE" -eq "$S30B_ARMS" ] \
  && [ "$S30B_LEAK" -eq 0 ] \
  && grep -qF -- 'so the Autopilot linkage block was never judged' "$HOOK" \
  && check "S30b every node pipe splits a read or load fault off from its judged verdict — one 4) arm per exit-4 producer, each naming what could not be read rather than what failed to validate" PASS \
  || check "S30b every node pipe splits a read or load fault off from its judged verdict — one 4) arm per exit-4 producer, each naming what could not be read rather than what failed to validate (producers=$S30B_PRODUCERS arms=$S30B_ARMS read-cause=$S30B_READ_CAUSE mode=$S30B_MODE verdict-leak=$S30B_LEAK)" FAIL

# S31 — AC-017. The ticket binds by CONTENT, so a prompt carrying it anywhere is recorded,
# while the reviewer AGENT selects consume mode positionally on the exact two header
# lines. A slip therefore costs the merged fan-out and nothing said it: the round counted
# and the panel result was thrown away silently. Two real accept-path runs, one per
# session because the ticket is one-shot: the slipped one carries the notice, the exact
# one does not, and with the ticket normalized the slipped render minus its notice is
# BYTE-IDENTICAL to the exact render — which is what keeps the prefix from rewriting the
# directive it fronts. The ticket value never appears in the notice.
start_session consume-header-exact
S31A="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S31A"
log --tdd-complete --session "$S31A"
S31_T1="$(issue_ticket "$S31A")"
S31_EXACT="$(run_hook "$S31A" zensu:code-reviewer "$MARKER
REVIEW-TICKET: $S31_T1
findings follow")"
start_session consume-header-slipped
S31B="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S31B"
log --tdd-complete --session "$S31B"
S31_T2="$(issue_ticket "$S31B")"
S31_SLIP="$(run_hook "$S31B" zensu:code-reviewer "$MARKER
context line the spawn put between the headers
REVIEW-TICKET: $S31_T2
findings follow")"
s31_context() {
  node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        process.stdout.write(String(j.hookSpecificOutput.additionalContext));
      } catch (_) { process.exit(3); }
    });
  ' 2>/dev/null
}
S31_NOTICE_TAIL='and only then the rest of the prompt. '
S31_EXACT_CTX="$(printf '%s' "$S31_EXACT" | s31_context)"
S31_SLIP_CTX="$(printf '%s' "$S31_SLIP" | s31_context)"
# Two values legitimately differ between the two runs and neither belongs to the
# property under test: the one-shot ticket, and the per-fixture plugin-data path
# `LOG_COMMAND` carries. Both are normalized so the comparison is about the
# directive text and nothing else.
S31_EXACT_NORM="${S31_EXACT_CTX//$S31_T1/S31TICKET}"
S31_EXACT_NORM="${S31_EXACT_NORM//consume-header-exact/S31FIXTURE}"
S31_SLIP_NORM="${S31_SLIP_CTX//$S31_T2/S31TICKET}"
S31_SLIP_NORM="${S31_SLIP_NORM//consume-header-slipped/S31FIXTURE}"
S31_SLIP_HEAD="${S31_SLIP_NORM%%$S31_NOTICE_TAIL*}"
S31_SLIP_TAIL="${S31_SLIP_NORM#*$S31_NOTICE_TAIL}"
# The ticket-echo test reads the RAW notice, before normalization would hide a leak.
# The directive BELOW the notice carries the ticket by design — the close command and
# the self-review generation line both need it — so the test is scoped to the notice.
S31_RAW_NOTICE="${S31_SLIP_CTX%%$S31_NOTICE_TAIL*}"
[ -n "$S31_T1" ] && [ -n "$S31_T2" ] && [ -n "$S31_EXACT_CTX" ] && [ -n "$S31_SLIP_CTX" ] \
  && [ "${S31_SLIP_NORM#Consume-header slip}" != "$S31_SLIP_NORM" ] \
  && [ "$S31_SLIP_HEAD" != "$S31_SLIP_NORM" ] \
  && ! printf '%s' "$S31_SLIP_HEAD" | grep -qF -- 'STOP.' \
  && printf '%s' "$S31_SLIP" | grep -qF -- 'did not open with the two required consume-header lines' \
  && printf '%s' "$S31_SLIP" | grep -qF -- 'the merged fan-out for this round was discarded' \
  && printf '%s' "$S31_SLIP" | grep -qF -- 'put both header lines FIRST' \
  && [ -n "$S31_RAW_NOTICE" ] && [ "$S31_RAW_NOTICE" != "$S31_SLIP_CTX" ] \
  && ! printf '%s' "$S31_RAW_NOTICE" | grep -qF -- "$S31_T2" \
  && printf '%s' "$S31_SLIP_CTX" | grep -qF -- "$S31_T2" \
  && ! printf '%s' "$S31_EXACT" | grep -qF -- 'Consume-header slip' \
  && [ "$S31_SLIP_TAIL" = "$S31_EXACT_NORM" ] \
  && check "S31 a header slip prefixes the routed directive with the consume-mode notice, an exact header renders byte-identically, and the ticket is never echoed" PASS \
  || check "S31 a header slip prefixes the routed directive with the consume-mode notice, an exact header renders byte-identically, and the ticket is never echoed (exact-ctx=${#S31_EXACT_CTX} slip-ctx=${#S31_SLIP_CTX} head=${#S31_SLIP_HEAD} tail=${#S31_SLIP_TAIL} norm=${#S31_EXACT_NORM})" FAIL

# S32 — AC-019/AC-002. The arming predicate and the claim transaction are now ONE
# implementation, so this check proves that rather than comparing two copies. What it
# replaced compared field-name sets plus a ONE-SIDED containment over the value
# constraints, and the one-sidedness was deliberate: only a hook WEAKER than the claim
# was thought to strand a correct re-spawn. The STRONGER direction is the one that
# passed — a hook requiring one conjunct MORE answers `no` for a chain the claim would
# accept, `decline()` returns at its first guard, and every disclosure in that file goes
# silent while every fixture satisfies both copies. Comparing two copies cannot see it;
# deleting one of them can. Each extraction carries a non-empty control, because a scan
# that matches nothing would otherwise report agreement.
S32_MODULE="$PLUGIN_DIR/hooks/lib/review-ticket-claim-v1.js"
s32_hook_slice() { awk '/^CHAIN_TICKET_STATE=/{f=1} f{print} f&&/^CHAIN_TICKET_WAS_OUTSTANDING=/{exit}' "$HOOK"; }
# The claim slice ENDS at the `claimableWith` call, and that boundary is load-bearing
# rather than tidiness: everything below it is the Autopilot-linkage block and the round
# mutation, which legitimately READ `s.reviewRound` to increment it. Running the slice to
# the closing brace reports that read as a surviving copy of a conjunct the module owns,
# which is a finding about the mutation rather than about the predicate.
s32_claim_slice() {
  awk '
    /^_tdd_consume_review_ticket_critical\(\) \{/ { f = 1 }
    f { print }
    f && /claim\.claimableWith\(/ { exit }
    f && /^\}$/ { exit }
  ' "$PHASE"
}
s32_shape_owner() { awk '/^_tdd_review_ticket_shape_ok\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$PHASE"; }
# Field READS, never writes: the claim legitimately keeps `s.reviewTicketConsumed = true`
# and `s.reviewRound = next`, which are the mutation the module has no business owning.
# The write filter alone is not enough on the claim side — see the slice boundary above.
s32_read_fields() {
  grep -vE '^[[:space:]]*s\.[A-Za-z_][A-Za-z0-9_]* = ' \
    | grep -oE '(^|[^A-Za-z0-9_.])(s|state)\.[A-Za-z_][A-Za-z0-9_]*' \
    | sed -E 's/.*\.//' | sort -u
}
S32_HOOK_LINES="$(s32_hook_slice | wc -l | tr -d ' ')"
S32_CLAIM_LINES="$(s32_claim_slice | wc -l | tr -d ' ')"
S32_MODULE_FIELDS="$(s32_read_fields < "$S32_MODULE")"
S32_MODULE_N="$(printf '%s\n' "$S32_MODULE_FIELDS" | grep -c . || true)"
S32_HOOK_REQ="$(s32_hook_slice | grep -cF -- 'require(process.env.CLAIM_MODULE)' || true)"
S32_CLAIM_REQ="$(s32_claim_slice | grep -cF -- 'require(process.env.CLAIM_MODULE)' || true)"
S32_HOOK_CALL="$(s32_hook_slice | grep -cF -- 'claim.outstandingTicket(' || true)"
S32_CLAIM_CALL="$(s32_claim_slice | grep -cF -- 'claim.claimableWith(' || true)"
# The conjunct list may survive in NEITHER carrier. The claim keeps its Autopilot-linkage
# reads, which the module does not hold, so the test is an intersection against the
# module's own field set rather than a ban on reading the document at all.
S32_HOOK_COPY="$(comm -12 <(s32_hook_slice | s32_read_fields) <(printf '%s\n' "$S32_MODULE_FIELDS") | tr '\n' ' ')"
S32_CLAIM_COPY="$(comm -12 <(s32_claim_slice | s32_read_fields) <(printf '%s\n' "$S32_MODULE_FIELDS") | tr '\n' ' ')"
# The ticket SHAPE has two spellings that no `require` can unify — the module's regex and
# the shell owner `_tdd_review_ticket_shape_ok`, which `tdd_consume_review_ticket_context`
# and the issuer still call. They stay pinned to each other here.
S32_SHAPE_MODULE="$(grep -cF -- '/^[A-Za-z0-9_-]{1,96}$/' "$S32_MODULE" || true)"
S32_SHAPE_LEN="$(s32_shape_owner | grep -cF -- '-le 96' || true)"
S32_SHAPE_CLASS="$(s32_shape_owner | grep -cF -- '*[!A-Za-z0-9_-]*' || true)"
S32_SHAPE_HOOK="$(s32_hook_slice | grep -cF -- '/^[A-Za-z0-9_-]{1,96}$/' || true)"
[ "$S32_HOOK_LINES" -ge 5 ] && [ "$S32_CLAIM_LINES" -ge 20 ] && [ "$S32_MODULE_N" -ge 13 ] \
  && [ "$S32_HOOK_REQ" -eq 1 ] && [ "$S32_CLAIM_REQ" -eq 1 ] \
  && [ "$S32_HOOK_CALL" -eq 1 ] && [ "$S32_CLAIM_CALL" -eq 1 ] \
  && [ -z "$S32_HOOK_COPY" ] && [ -z "$S32_CLAIM_COPY" ] \
  && [ "$S32_SHAPE_MODULE" -eq 1 ] && [ "$S32_SHAPE_LEN" -eq 1 ] && [ "$S32_SHAPE_CLASS" -eq 1 ] \
  && [ "$S32_SHAPE_HOOK" -eq 0 ] \
  && check "S32 both carriers require the shared claim predicate and neither re-spells the conjunct list, and the module and the shell shape owner still agree" PASS \
  || check "S32 both carriers require the shared claim predicate and neither re-spells the conjunct list, and the module and the shell shape owner still agree (hook-lines=$S32_HOOK_LINES claim-lines=$S32_CLAIM_LINES module-fields=$S32_MODULE_N req=$S32_HOOK_REQ/$S32_CLAIM_REQ call=$S32_HOOK_CALL/$S32_CLAIM_CALL copied=${S32_HOOK_COPY:-none}/${S32_CLAIM_COPY:-none} shape=$S32_SHAPE_MODULE/$S32_SHAPE_LEN/$S32_SHAPE_CLASS/$S32_SHAPE_HOOK)" FAIL

# S33 — AC-020. Three comments in this hook stated something the shipped code does not do.
# The workspace-read comment justified its disclosure with "confirms nothing about anyone
# else", which is false for an owner-INDEPENDENT read that fails on any invalid record in
# a shared directory; the silent-exit partition named one further bare exit while the
# exits above the ticket read are a class of their own; and the remedy comment carried a
# numeral for a run-state gate count that nothing recomputes.
S33_OLD_WS="$(grep -cF -- 'confirms nothing about anyone else' "$HOOK" || true)"
S33_NEW_WS="$(grep -cF -- 'owner-INDEPENDENT and fails on any record' "$HOOK" || true)"
S33_PRE_TICKET="$(grep -cF -- 'every exit ABOVE the ticket read' "$HOOK" || true)"
S33_NUMERAL="$(s27_decline_body | grep -cEi '(one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+) gates refuse' || true)"
S33_NOCOUNT="$(s27_decline_body | grep -cF -- 'count is deliberately not written here' || true)"
[ "$S33_OLD_WS" -eq 0 ] && [ "$S33_NEW_WS" -eq 1 ] \
  && [ "$S33_PRE_TICKET" -eq 1 ] && [ "$S33_NUMERAL" -eq 0 ] && [ "$S33_NOCOUNT" -eq 1 ] \
  && check "S33 the workspace-read, silent-exit and remedy comments describe the shipped code and claim no gate count" PASS \
  || check "S33 the workspace-read, silent-exit and remedy comments describe the shipped code and claim no gate count (old-ws=$S33_OLD_WS new-ws=$S33_NEW_WS pre-ticket=$S33_PRE_TICKET numeral=$S33_NUMERAL nocount=$S33_NOCOUNT)" FAIL

# S34 — AC-021. The consume-header notice must PREFIX every ACCEPT-path emission, and S31
# drives exactly one of them. Three `emit_post_context` call sites sit below the notice
# assignment — the disabled-enforcer arm, the converged arm and the fix-round arm — so a
# notice dropped from either of the two S31 does not reach would leave a real header slip
# silent on paths a chain routinely takes, with every behavioural check green. The DECLINE
# emission above the assignment must NOT carry it: there the completion was not recorded at
# all, so a slip notice would describe a round that never counted. Source-derived on both
# sides, because the partition is what the check is about: a fourth accept-path emission
# added without the prefix enrols itself here rather than shipping unnoticed.
# The partition is derived from `decline()`s OWN BODY, never from the notice assignment
# line number. A positional split buckets any accept-path emission written ABOVE that
# assignment as a decline and exempts it from the prefix requirement — silently, which is
# the opposite of the enrolment property this check is named for. The one emission inside
# `decline()` is the decline site; every other one is an accept site. And the site needle
# is the bare function name rather than `| emit_post_context`: the function reads STDIN, so
# a heredoc or process-substitution feed is a real call shape that the pipe-only needle
# could not see at all. The function DEFINITION is excluded by name, and so is every COMMENT
# line: a sentence naming the function — the kind this hook already carries about where the
# definition sits and why — would otherwise enrol itself as a call site, and which way that
# broke depended only on where the sentence happened to sit. Inside `decline()`s body it
# inflates the decline count silently; outside it, it is scored as an accept site with no
# prefix and fails the check for a comment. The filter is anchored on the `grep -n` prefix so
# it can only drop a line whose FIRST non-space character is `#`.
S34_ASSIGN="$(grep -n '^CONSUME_SHAPE_NOTICE=""' "$HOOK" | head -1 | cut -d: -f1)"
S34_DECL_START="$(grep -n '^decline() {' "$HOOK" | head -1 | cut -d: -f1)"
S34_DECL_END="$(awk -v s="${S34_DECL_START:-0}" 'NR>s && /^\}/{print NR; exit}' "$HOOK")"
S34_SITES="$(grep -n 'emit_post_context' "$HOOK" | grep -vF 'emit_post_context() {' | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1)"
S34_PREFIX_RE='^[[:space:]]*printf .%s. "\$\{CONSUME_SHAPE_NOTICE\}'
S34_ACCEPT=0
S34_PREFIXED=0
S34_DECLINE=0
S34_DECLINE_TAINTED=0
for s34_ln in $S34_SITES; do
  s34_line="$(sed -n "${s34_ln}p" "$HOOK")"
  if [ -n "$S34_DECL_START" ] && [ -n "$S34_DECL_END" ] \
    && [ "$s34_ln" -ge "$S34_DECL_START" ] && [ "$s34_ln" -le "$S34_DECL_END" ]; then
    S34_DECLINE=$((S34_DECLINE + 1))
  else
    S34_ACCEPT=$((S34_ACCEPT + 1))
    printf '%s\n' "$s34_line" | grep -qE -- "$S34_PREFIX_RE" && S34_PREFIXED=$((S34_PREFIXED + 1))
  fi
done
# The taint half is BODY-scoped, and the title is why. It read the emission LINE alone,
# so building the decline body into a variable first and piping that variable — the
# ordinary refactor, and the shape the accept sites already use — moved the notice off
# the emission line and left the count at zero while the notice really would be emitted
# at every post-claim decline. The check is named for the decline BODY carrying none of
# it, so that is what is measured; comment lines are excluded for the reason the site
# scan above excludes them, since a sentence naming the constant is not an emission.
if [ -n "$S34_DECL_START" ] && [ -n "$S34_DECL_END" ]; then
  S34_DECLINE_TAINTED="$(sed -n "${S34_DECL_START},${S34_DECL_END}p" "$HOOK" \
    | grep -v '^[[:space:]]*#' | grep -cF -- 'CONSUME_SHAPE_NOTICE' || true)"
fi
[ -n "$S34_ASSIGN" ] && [ -n "$S34_DECL_START" ] && [ -n "$S34_DECL_END" ] \
  && [ "$S34_ACCEPT" -ge 3 ] && [ "$S34_PREFIXED" = "$S34_ACCEPT" ] \
  && [ "$S34_DECLINE" -ge 1 ] && [ "$S34_DECLINE_TAINTED" -eq 0 ] \
  && check "S34 every accept-path emission prefixes the consume-header notice and the decline emission carries none ($S34_PREFIXED/$S34_ACCEPT)" PASS \
  || check "S34 every accept-path emission prefixes the consume-header notice and the decline emission carries none (assign=${S34_ASSIGN:-none} decline-body=${S34_DECL_START:-none}..${S34_DECL_END:-none} accept=$S34_ACCEPT prefixed=$S34_PREFIXED decline=$S34_DECLINE tainted=$S34_DECLINE_TAINTED)" FAIL

# S35 — AC-022. The notice RESTATES the reviewer agent's positional consume-mode rule, and
# that rule belongs to `agents/code-reviewer.md`, which states it is deliberately stricter
# than this hook's content match. Nothing compared the two, so a reworded agent rule would
# leave the hook teaching a header the agent no longer selects on — the one instruction whose
# whole purpose is to stop the next round throwing its fan-out away. Both carriers are
# whitespace-FLATTENED first, because the agent wraps the rule across two physical lines.
# The agent side is SLICED to its rule sentence, never read whole. `%%` takes the FIRST
# occurrence of a literal anywhere in the file, so a whole-file haystack makes the ordering
# comparison accurate only while each literal occurs exactly once — which nothing enforces.
# A later mention of the marker earlier in that file would move the comparison onto
# unrelated prose while the rule itself could be reworded, with this check still green. The
# slice runs from the anchor `Enter consume mode only when` to the end of the sentence, and
# the anchor is required to occur exactly ONCE so the slice cannot be ambiguous either.
S35_AGENT="$PLUGIN_DIR/agents/code-reviewer.md"
s35_flat() { tr '\n' ' ' | tr -s ' '; }
S35_ANCHOR='Enter consume mode only when'
S35_ANCHOR_N="$(grep -cF -- "$S35_ANCHOR" "$S35_AGENT" || true)"
S35_AGENT_FLAT="$(awk -v a="$S35_ANCHOR" 'index($0,a)>0{f=1} f{print} f&&/\.$/{exit}' "$S35_AGENT" | s35_flat)"
S35_NOTICE="$(grep -F 'CONSUME_SHAPE_NOTICE="Consume-header slip' "$HOOK" | s35_flat)"
S35_MARK='PRE-MERGED FINDINGS (fan-out)'
S35_TICKET='REVIEW-TICKET:'
S35_AGENT_ORDER=0
S35_NOTICE_ORDER=0
S35_AGENT_HEAD="${S35_AGENT_FLAT%%$S35_MARK*}"
S35_AGENT_TAIL="${S35_AGENT_FLAT%%$S35_TICKET*}"
[ "$S35_AGENT_HEAD" != "$S35_AGENT_FLAT" ] && [ "$S35_AGENT_TAIL" != "$S35_AGENT_FLAT" ] \
  && [ "${#S35_AGENT_HEAD}" -lt "${#S35_AGENT_TAIL}" ] && S35_AGENT_ORDER=1
S35_NOTICE_HEAD="${S35_NOTICE%%$S35_MARK*}"
S35_NOTICE_TAIL="${S35_NOTICE%%$S35_TICKET*}"
[ "$S35_NOTICE_HEAD" != "$S35_NOTICE" ] && [ "$S35_NOTICE_TAIL" != "$S35_NOTICE" ] \
  && [ "${#S35_NOTICE_HEAD}" -lt "${#S35_NOTICE_TAIL}" ] && S35_NOTICE_ORDER=1
S35_AGENT_FIRST="$(printf '%s' "$S35_AGENT_FLAT" | grep -cF -- 'first line is exactly' || true)"
S35_AGENT_SECOND="$(printf '%s' "$S35_AGENT_FLAT" | grep -cF -- 'second line is' || true)"
S35_NOTICE_FIRST="$(printf '%s' "$S35_NOTICE" | grep -cF -- 'line 1 exactly' || true)"
S35_NOTICE_SECOND="$(printf '%s' "$S35_NOTICE" | grep -cF -- 'line 2 exactly' || true)"
[ -n "$S35_NOTICE" ] && [ -n "$S35_AGENT_FLAT" ] && [ "$S35_ANCHOR_N" -eq 1 ] \
  && [ "$S35_AGENT_ORDER" -eq 1 ] && [ "$S35_NOTICE_ORDER" -eq 1 ] \
  && [ "$S35_AGENT_FIRST" -eq 1 ] && [ "$S35_AGENT_SECOND" -eq 1 ] \
  && [ "$S35_NOTICE_FIRST" -ge 1 ] && [ "$S35_NOTICE_SECOND" -ge 1 ] \
  && check "S35 the consume-header notice restates the reviewer agent's positional rule with the same two literals in the same order, read from the agent's own sliced rule sentence" PASS \
  || check "S35 the consume-header notice restates the reviewer agent's positional rule with the same two literals in the same order, read from the agent's own sliced rule sentence (notice=${#S35_NOTICE} slice=${#S35_AGENT_FLAT} anchors=$S35_ANCHOR_N agent-order=$S35_AGENT_ORDER notice-order=$S35_NOTICE_ORDER agent=$S35_AGENT_FIRST/$S35_AGENT_SECOND notice=$S35_NOTICE_FIRST/$S35_NOTICE_SECOND)" FAIL

# S36 — AC-023. Every other stderr assertion in this suite evaluates `decline()` in a
# SUBSHELL, and `run_hook` discards stderr outright, so nothing observed the operator line
# coming out of the real process. That is the gap this feature's own disclosure argument
# rests on: a redirect lost inside the hook, a wrapper that closed fd 2, or a decline moved
# below a `exec 2>/dev/null` would leave S29 green over a channel no operator receives.
# Both channels are captured separately from ONE shipped-hook run, and a completion from a
# subagent this hook does not judge is the control that the capture discriminates.
run_hook_capture() {
  local sid="$1" subtype="$2" prompt="$3" errfile="$4" payload_sid="$1"
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
  ' | bash "$HOOK" 2>"$errfile"
}
start_session stderr-end-to-end
S36="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S36"
log --tdd-complete --session "$S36"
S36_TICKET="$(issue_ticket "$S36")"
S36_PROMPT="$MARKER
REVIEW-TICKET: $S36_TICKET
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=run-fixture attempt=1 chain=chain-fixture
AUTOPILOT-STAGE: GATES"
S36_ERRFILE="$ROOT/s36-decline.err"
S36_CTRLFILE="$ROOT/s36-control.err"
S36_OUT="$(run_hook_capture "$S36" zensu:code-reviewer "$S36_PROMPT" "$S36_ERRFILE")"
S36_ERR="$(cat "$S36_ERRFILE" 2>/dev/null || true)"
S36_CTRL_OUT="$(run_hook_capture "$S36" general-purpose "$S36_PROMPT" "$S36_CTRLFILE")"
S36_CTRL_ERR="$(cat "$S36_CTRLFILE" 2>/dev/null || true)"
S36_ERR_LINES="$(printf '%s' "$S36_ERR" | grep -c '' || true)"
[ -n "$S36_TICKET" ] && [ -n "$S36_ERR" ] && [ "$S36_ERR_LINES" -eq 1 ] \
  && printf '%s' "$S36_ERR" | grep -qF -- 'zensu: reviewer completion not recorded' \
  && printf '%s' "$S36_ERR" | grep -qF -- '(envelope)' \
  && ! printf '%s' "$S36_ERR" | grep -qF -- '(runstate)' \
  && ! printf '%s' "$S36_ERR" | grep -qF -- "$S36_TICKET" \
  && [ -n "$S36_OUT" ] \
  && printf '%s' "$S36_OUT" | grep -qF -- 'Do NOT issue a fresh review ticket' \
  && printf '%s' "$S36_OUT" | grep -qF -- 'the Autopilot envelope in the PROMPT' \
  && ! printf '%s' "$S36_OUT" | grep -qF -- 'Resolve the durable run state first' \
  && [ -z "$S36_CTRL_ERR" ] && [ -z "$S36_CTRL_OUT" ] \
  && check "S36 the shipped hook writes the operator line to its own stderr while the model-facing remedy goes to stdout, and a completion it does not judge writes neither" PASS \
  || check "S36 the shipped hook writes the operator line to its own stderr while the model-facing remedy goes to stdout, and a completion it does not judge writes neither (err=${#S36_ERR} lines=$S36_ERR_LINES out=${#S36_OUT} ctrl-err=${#S36_CTRL_ERR} ctrl-out=${#S36_CTRL_OUT})" FAIL

# S37 — AC-024. The hook reads the workflow document TWICE from `node -e`, and both reads go
# through the core module rather than a bare `readFileSync`, because `<project>/.zensu/state/`
# is session-writable and a planted FIFO there makes a plain open block forever on a PostToolUse
# path. Nothing observed that: a revert to `readFileSync(process.env.STATE_FILE)` keeps every
# behavioural case in this suite green, since an ordinary regular file reads identically either
# way. The accessor name is DERIVED from the phase library rather than spelled here, so a rename
# there reports a missing accessor instead of passing against a literal nothing produces — and
# the same derivation is what makes the negative arm meaningful: the hook may DISCUSS the
# library's private global in a comment, and must never read it on a code line.
S37_PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
# The name class admits no leading underscore, because the check is named for a PUBLIC
# accessor and this repository's own mark for an intra-file channel is that prefix. The
# old `^[a-z_]` matched a private helper just as readily, so a library that retired its
# public accessor and left `_zensu_tdd_control_core` behind would have satisfied a check
# whose whole subject is that the hook reads the public one.
S37_ACCESSOR="$(awk '
  match($0, /^[a-z][a-z0-9_]*\(\)/) > 0 { name=substr($0, 1, RLENGTH-2); next }
  index($0, "printf") > 0 && index($0, "_ZENSU_TDD_CONTROL_CORE:-") > 0 && name != "" { print name; exit }
' "$S37_PHASE")"
S37_SPAWNS="$(grep -c 'STATE_FILE="\$NATIVE_TDD_STATE_FILE"' "$HOOK" || true)"
S37_HARDENED="$(grep -cF 'core.readRegularFileSnapshot(process.env.STATE_FILE)' "$HOOK" || true)"
S37_BARE="$(grep -cE 'readFileSync\((process\.env\.)?STATE_FILE' "$HOOK" || true)"
# The CALL, never the NAME. A whole-line count of the bare name is satisfied by the
# comment that explains the accessor plus the `declare -F` guard that tests for it, so
# replacing the one assignment with a hardcoded path still left the count at two and
# passed — while the hook re-spelled a layout that resolves to the shell namespace on
# MSYS, where the require throws and the decline is silent. The guard is counted
# separately, so neither can stand in for the other.
S37_CALLS=0
S37_GUARD=0
if [ -n "$S37_ACCESSOR" ]; then
  # Comment lines are filtered, exactly as `S37_PRIVATE_CODE` below filters them. This
  # check is about a CALL, and a line of prose quoting the substitution satisfies a bare
  # count just as readily as the assignment does — which is the same standing-in the
  # comment above records for the bare NAME, one form further along. The two counts are
  # derived side by side and must not disagree about what counts as code.
  S37_CALLS="$(grep -F -- "\$($S37_ACCESSOR)" "$HOOK" | grep -cvE '^[[:space:]]*(//|#)' || true)"
  S37_GUARD="$(grep -E "declare -F[[:space:]]+$S37_ACCESSOR" "$HOOK" | grep -cv '^[[:space:]]*#' || true)"
fi
S37_PRIVATE_CODE="$(grep -n '_ZENSU_TDD_CONTROL_CORE' "$HOOK" | cut -d: -f2- | grep -cv '^[[:space:]]*#' || true)"
# The floor on the SPAWN count is 1, not 2. The property is that EVERY state-file read is
# hardened and none is bare, which `S37_HARDENED -eq S37_SPAWNS` plus `S37_BARE -eq 0`
# states completely; a floor of 2 additionally pinned the current two-read implementation,
# so consolidating the two programs into one — which would also close the window in which
# they can observe different documents — failed a check named for FIFO hardening.
[ -n "$S37_ACCESSOR" ] && [ "$S37_SPAWNS" -ge 1 ] \
  && [ "$S37_HARDENED" -eq "$S37_SPAWNS" ] \
  && [ "$S37_BARE" -eq 0 ] \
  && [ "$S37_CALLS" -ge 1 ] && [ "$S37_GUARD" -ge 1 ] \
  && [ "$S37_PRIVATE_CODE" -eq 0 ] \
  && check "S37 every workflow-document read goes through the core hardened reader, no bare readFileSync on the state file survives, and the module path is CALLED from the phase library's PUBLIC accessor behind its own guard rather than read from its private global" PASS \
  || check "S37 every workflow-document read goes through the core hardened reader, no bare readFileSync on the state file survives, and the module path is CALLED from the phase library's PUBLIC accessor behind its own guard rather than read from its private global (accessor=${S37_ACCESSOR:-none} spawns=$S37_SPAWNS hardened=$S37_HARDENED bare=$S37_BARE calls=$S37_CALLS guard=$S37_GUARD private-code=$S37_PRIVATE_CODE)" FAIL


# S38 — AC-006/AC-007/AC-012. `additionalContext` is transcript-scoped, so before this the
# whole decline died with the turn: a user returning to a stranded chain after a compaction
# or a fork saw exactly what they saw before the disclosure existed. The note is the durable
# half, minted on the SAME gate the operator-channel line already uses, and it carries the
# remedy MODE rather than the ticket — the ticket is a capability token and a note is an
# ordinary file in a session-writable directory. S36 above produced a real `envelope`
# decline, so this reads that run's bytes rather than building a second fixture; the control
# is a completion this hook does not judge, in its own session, which must mint nothing.
S38_NOTE="$PROJECT/.zensu/state/review-decline-$S36.json"
S38_BYTES=""
[ -f "$S38_NOTE" ] && [ ! -L "$S38_NOTE" ] && S38_BYTES="$(cat "$S38_NOTE" 2>/dev/null || true)"

start_session decline-note-control
S38C="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S38C"
log --tdd-complete --session "$S38C"
S38C_TICKET="$(issue_ticket "$S38C")"
S38C_ERRFILE="$ROOT/s38-control.err"
S38C_PROMPT="$MARKER
REVIEW-TICKET: $S38C_TICKET
ZENSU-DELEGATED-CALLER: autopilot
AUTOPILOT-BINDING: run=run-fixture attempt=1 chain=chain-fixture
AUTOPILOT-STAGE: GATES"
run_hook_capture "$S38C" general-purpose "$S38C_PROMPT" "$S38C_ERRFILE" >/dev/null
S38C_NOTE="$PROJECT/.zensu/state/review-decline-$S38C.json"

[ -n "$S38_BYTES" ] \
  && printf '%s' "$S38_BYTES" | grep -qF -- '"schemaVersion":1' \
  && printf '%s' "$S38_BYTES" | grep -qF -- '"kind":"envelope"' \
  && printf '%s' "$S38_BYTES" | grep -qF -- '"subagentType":"zensu:code-reviewer"' \
  && printf '%s' "$S38_BYTES" | grep -qE -- '"detectedAtMs":[0-9]+' \
  && [ -n "$S36_TICKET" ] \
  && ! printf '%s' "$S38_BYTES" | grep -qF -- "$S36_TICKET" \
  && [ ! -e "$S38C_NOTE" ] \
  && check "S38 a declined reviewer completion mints a durable decline note carrying the remedy mode and a timestamp but never the ticket, and a completion this hook does not judge mints none" PASS \
  || check "S38 a declined reviewer completion mints a durable decline note carrying the remedy mode and a timestamp but never the ticket, and a completion this hook does not judge mints none (note=${#S38_BYTES} control-note=$([ -e "$S38C_NOTE" ] && echo present || echo absent))" FAIL
echo "----"
echo "test-post-review-tdd-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
