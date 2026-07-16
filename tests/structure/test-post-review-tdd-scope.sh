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
  ZENSU_TEST_ENV_FILE ZENSU_TEST_PLUGIN_DATA 2>/dev/null || true

# shellcheck disable=SC1090
source "$PHASE"

MARKER='PRE-MERGED FINDINGS (fan-out)'
STARTED_SESSION_KEY=""

start_session() {
  local raw_session="$1" label="${2:-$1}"
  export ZENSU_TEST_PLUGIN_DATA="$ROOT/plugin-data-$label"
  export ZENSU_TEST_ENV_FILE="$ROOT/session-$label.env"
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
  local sid="$1" subtype="$2" prompt="$3"
  SID="$sid" SUBTYPE="$subtype" PROMPT="$prompt" node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "Agent",
      tool_input: {subagent_type: process.env.SUBTYPE, prompt: process.env.PROMPT},
      session_id: process.env.SID
    }));
  ' | bash "$HOOK" 2>/dev/null
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

# A live chain still requires the exact consume-mode marker on the first line.
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

# Both header lines are positional contracts. An otherwise armed ticket stays
# unconsumed when the second line is absent, displaced, malformed, or the first
# line contains even a small decoration.
start_session missing-ticket
S7A="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7A"
log --tdd-complete --session "$S7A"
MISSING_TICKET="$(issue_ticket "$S7A")"
S7A_STATE="$(state "$S7A")"
BEFORE="$(digest "$S7A_STATE")"
OUT="$(run_hook "$S7A" zensu:code-reviewer "$MARKER")"
AFTER="$(digest "$S7A_STATE")"
[ -n "$MISSING_TICKET" ] && [ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7A")" = "false" ] \
  && check "S7a exact first line without the required second line is rejected" PASS \
  || check "S7a exact first line without the required second line is rejected" FAIL

start_session late-ticket
S7B="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7B"
log --tdd-complete --session "$S7B"
LATE_TICKET="$(issue_ticket "$S7B")"
S7B_STATE="$(state "$S7B")"
BEFORE="$(digest "$S7B_STATE")"
OUT="$(run_hook "$S7B" zensu:code-reviewer "$MARKER
merged findings
REVIEW-TICKET: $LATE_TICKET")"
AFTER="$(digest "$S7B_STATE")"
[ -n "$LATE_TICKET" ] && [ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7B")" = "false" ] \
  && check "S7b review ticket on the third line is rejected" PASS \
  || check "S7b review ticket on the third line is rejected" FAIL

start_session decorated-marker
S7C="$STARTED_SESSION_KEY"
log --tdd-begin --session "$S7C"
log --tdd-complete --session "$S7C"
DECORATED_TICKET="$(issue_ticket "$S7C")"
S7C_STATE="$(state "$S7C")"
BEFORE="$(digest "$S7C_STATE")"
OUT="$(run_hook "$S7C" zensu:code-reviewer "$MARKER extra
REVIEW-TICKET: $DECORATED_TICKET")"
AFTER="$(digest "$S7C_STATE")"
[ -n "$DECORATED_TICKET" ] && [ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7C")" = "false" ] \
  && check "S7c decorated first-line marker is rejected" PASS \
  || check "S7c decorated first-line marker is rejected" FAIL

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
[ -n "$MALFORMED_TICKET" ] && [ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(ticket_consumed "$S7D")" = "false" ] \
  && check "S7d malformed second-line ticket is rejected" PASS \
  || check "S7d malformed second-line ticket is rejected" FAIL

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
log --tdd-begin --session "$S8"
log --tdd-complete --session "$S8"
NEW_VALID_TICKET="$(issue_ticket "$S8")"
OUT_OLD="$(run_hook "$S8" zensu:code-reviewer "$VALID_PROMPT")"
OUT_NEW="$(run_hook "$S8" zensu:code-reviewer "$(review_prompt "$NEW_VALID_TICKET" 'new chain')")"
[ -z "$OUT_OLD" ] && printf '%s' "$OUT_NEW" | grep -q 'hookSpecificOutput' \
  && [ "$(review_round "$S8")" = "1" ] \
  && check "S8b late completion from a prior chain cannot mutate the re-armed chain" PASS \
  || check "S8b late completion from a prior chain cannot mutate the re-armed chain" FAIL

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

echo "----"
echo "test-post-review-tdd-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
