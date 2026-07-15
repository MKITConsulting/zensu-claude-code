#!/bin/bash
# The code-reviewer completion hook is scoped to one live TDD review chain.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

ROOT="$(mktemp -d -t zensu-postreview-scope-XXXXXX)"
STATE="$ROOT/state"
PROJECT="$ROOT/project"
mkdir -p "$STATE" "$PROJECT"
trap 'rm -rf "$ROOT"' EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export CLAUDE_PLUGIN_DATA_OVERRIDE="$STATE"
export TDD_STATE_DIR="$STATE"
export ZENSU_CONFIG="$ROOT/no-config.json"

MARKER='PRE-MERGED FINDINGS (fan-out)'

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

counter() { printf '%s/rounds-%s.json' "$STATE" "$1"; }
state() { printf '%s/tdd-phase-%s.json' "$STATE" "$1"; }
ticket_consumed() {
  node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(j.reviewTicketConsumed===true?"true":"false")}catch(_){process.stdout.write("invalid")}' "$(state "$1")"
}

# A different Agent type is invisible to the hook.
OUT="$(run_hook other-type general-purpose "$MARKER")"
[ -z "$OUT" ] && [ ! -e "$(counter other-type)" ] \
  && check "S1 wrong subagent type is a total no-op" PASS \
  || check "S1 wrong subagent type is a total no-op" FAIL

# A stale counter without a live TDD state must not be read or incremented.
printf '%s\n' '{"count":5,"ts":"sentinel"}' > "$(counter no-state)"
BEFORE="$(cat "$(counter no-state)")"
OUT="$(run_hook no-state zensu:code-reviewer "$MARKER")"
AFTER="$(cat "$(counter no-state)")"
[ -z "$OUT" ] && [ "$AFTER" = "$BEFORE" ] && [ ! -e "$(state no-state)" ] \
  && check "S2 reviewer without TDD state preserves stale counter byte-for-byte" PASS \
  || check "S2 reviewer without TDD state preserves stale counter byte-for-byte" FAIL

# Active but not implementation-complete is still outside the review chain.
bash "$LOG" --tdd-begin --session active-only >/dev/null
OUT="$(run_hook active-only zensu:code-reviewer "$MARKER")"
[ -z "$OUT" ] && [ ! -e "$(counter active-only)" ] \
  && check "S3 active session before implComplete is a no-op" PASS \
  || check "S3 active session before implComplete is a no-op" FAIL

# A completed inner chain cannot be re-opened by a late reviewer completion.
bash "$LOG" --tdd-begin --session chain-done >/dev/null
bash "$LOG" --tdd-complete --session chain-done >/dev/null
bash "$LOG" --chain-done --session chain-done >/dev/null
OUT="$(run_hook chain-done zensu:code-reviewer "$MARKER")"
[ -z "$OUT" ] && [ ! -e "$(counter chain-done)" ] \
  && check "S4 chainDone reviewer completion is a no-op" PASS \
  || check "S4 chainDone reviewer completion is a no-op" FAIL

# Once code review converged, another reviewer completion is stale too.
bash "$LOG" --tdd-begin --session review-done >/dev/null
bash "$LOG" --tdd-complete --session review-done >/dev/null
bash "$LOG" --code-review-done --session review-done >/dev/null
OUT="$(run_hook review-done zensu:code-reviewer "$MARKER")"
[ -z "$OUT" ] && [ ! -e "$(counter review-done)" ] \
  && check "S5 codeReviewDone reviewer completion is a no-op" PASS \
  || check "S5 codeReviewDone reviewer completion is a no-op" FAIL

# A live chain still requires the exact consume-mode marker on the first line.
bash "$LOG" --tdd-begin --session no-marker >/dev/null
bash "$LOG" --tdd-complete --session no-marker >/dev/null
OUT="$(run_hook no-marker zensu:code-reviewer 'ordinary reviewer prompt')"
[ -z "$OUT" ] && [ ! -e "$(counter no-marker)" ] \
  && check "S6 live chain without fan-out marker is a no-op" PASS \
  || check "S6 live chain without fan-out marker is a no-op" FAIL

bash "$LOG" --tdd-begin --session late-marker >/dev/null
bash "$LOG" --tdd-complete --session late-marker >/dev/null
OUT="$(run_hook late-marker zensu:code-reviewer "ordinary first line
$MARKER")"
[ -z "$OUT" ] && [ ! -e "$(counter late-marker)" ] \
  && check "S7 marker appearing after the first line is rejected" PASS \
  || check "S7 marker appearing after the first line is rejected" FAIL

# Both header lines are positional contracts. An otherwise armed ticket stays
# unconsumed when the second line is absent, displaced, malformed, or the first
# line contains even a small decoration.
bash "$LOG" --tdd-begin --session missing-ticket >/dev/null
bash "$LOG" --tdd-complete --session missing-ticket >/dev/null
MISSING_TICKET="$(issue_ticket missing-ticket)"
OUT="$(run_hook missing-ticket zensu:code-reviewer "$MARKER")"
[ -n "$MISSING_TICKET" ] && [ -z "$OUT" ] && [ ! -e "$(counter missing-ticket)" ] \
  && [ "$(ticket_consumed missing-ticket)" = "false" ] \
  && check "S7a exact first line without the required second line is rejected" PASS \
  || check "S7a exact first line without the required second line is rejected" FAIL

bash "$LOG" --tdd-begin --session late-ticket >/dev/null
bash "$LOG" --tdd-complete --session late-ticket >/dev/null
LATE_TICKET="$(issue_ticket late-ticket)"
OUT="$(run_hook late-ticket zensu:code-reviewer "$MARKER
merged findings
REVIEW-TICKET: $LATE_TICKET")"
[ -n "$LATE_TICKET" ] && [ -z "$OUT" ] && [ ! -e "$(counter late-ticket)" ] \
  && [ "$(ticket_consumed late-ticket)" = "false" ] \
  && check "S7b review ticket on the third line is rejected" PASS \
  || check "S7b review ticket on the third line is rejected" FAIL

bash "$LOG" --tdd-begin --session decorated-marker >/dev/null
bash "$LOG" --tdd-complete --session decorated-marker >/dev/null
DECORATED_TICKET="$(issue_ticket decorated-marker)"
OUT="$(run_hook decorated-marker zensu:code-reviewer "$MARKER extra
REVIEW-TICKET: $DECORATED_TICKET")"
[ -n "$DECORATED_TICKET" ] && [ -z "$OUT" ] && [ ! -e "$(counter decorated-marker)" ] \
  && [ "$(ticket_consumed decorated-marker)" = "false" ] \
  && check "S7c decorated first-line marker is rejected" PASS \
  || check "S7c decorated first-line marker is rejected" FAIL

bash "$LOG" --tdd-begin --session malformed-ticket >/dev/null
bash "$LOG" --tdd-complete --session malformed-ticket >/dev/null
MALFORMED_TICKET="$(issue_ticket malformed-ticket)"
OUT="$(run_hook malformed-ticket zensu:code-reviewer "$MARKER
REVIEW-TICKET: $MALFORMED_TICKET extra")"
[ -n "$MALFORMED_TICKET" ] && [ -z "$OUT" ] && [ ! -e "$(counter malformed-ticket)" ] \
  && [ "$(ticket_consumed malformed-ticket)" = "false" ] \
  && check "S7d malformed second-line ticket is rejected" PASS \
  || check "S7d malformed second-line ticket is rejected" FAIL

# Fully armed and correctly marked is the only routed path.
bash "$LOG" --tdd-begin --session valid >/dev/null
bash "$LOG" --tdd-complete --session valid >/dev/null
VALID_TICKET="$(issue_ticket valid)"
VALID_PROMPT="$(review_prompt "$VALID_TICKET" 'merged findings')"
OUT="$(run_hook valid zensu:code-reviewer "$VALID_PROMPT")"
COUNT="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count))}catch(_){process.stdout.write("")}' "$(counter valid)")"
printf '%s' "$OUT" | grep -q 'hookSpecificOutput' && [ "$COUNT" = "1" ] \
  && check "S8 armed consume-mode reviewer is routed exactly once" PASS \
  || check "S8 armed consume-mode reviewer is routed exactly once" FAIL

# A repeated delivery of the same Agent completion cannot claim the ticket twice.
OUT="$(run_hook valid zensu:code-reviewer "$VALID_PROMPT")"
COUNT="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count))}catch(_){process.stdout.write("")}' "$(counter valid)")"
[ -z "$OUT" ] && [ "$COUNT" = "1" ] \
  && check "S8a duplicate completion is a byte-stable no-op" PASS \
  || check "S8a duplicate completion is a byte-stable no-op" FAIL

# Re-arming the same Claude session invalidates every ticket from the old chain.
bash "$LOG" --tdd-begin --session valid >/dev/null
bash "$LOG" --tdd-complete --session valid >/dev/null
NEW_VALID_TICKET="$(issue_ticket valid)"
OUT_OLD="$(run_hook valid zensu:code-reviewer "$VALID_PROMPT")"
OUT_NEW="$(run_hook valid zensu:code-reviewer "$(review_prompt "$NEW_VALID_TICKET" 'new chain')")"
COUNT="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count))}catch(_){process.stdout.write("")}' "$(counter valid)")"
[ -z "$OUT_OLD" ] && printf '%s' "$OUT_NEW" | grep -q 'hookSpecificOutput' && [ "$COUNT" = "1" ] \
  && check "S8b late completion from a prior chain cannot mutate the re-armed chain" PASS \
  || check "S8b late completion from a prior chain cannot mutate the re-armed chain" FAIL

# State and counters remain session-local.
bash "$LOG" --tdd-begin --session session-a >/dev/null
bash "$LOG" --tdd-complete --session session-a >/dev/null
bash "$LOG" --tdd-begin --session session-b >/dev/null
bash "$LOG" --tdd-complete --session session-b >/dev/null
TICKET_B="$(issue_ticket session-b)"
run_hook session-b zensu:code-reviewer "$(review_prompt "$TICKET_B")" >/dev/null
[ ! -e "$(counter session-a)" ] && [ -e "$(counter session-b)" ] \
  && check "S9 reviewer completion cannot mutate another session counter" PASS \
  || check "S9 reviewer completion cannot mutate another session counter" FAIL

# Corrupt state fails open without replacing the file or creating a counter.
printf '%s\n' '{malformed' > "$(state malformed)"
BEFORE="$(cat "$(state malformed)")"
OUT="$(run_hook malformed zensu:code-reviewer "$MARKER")"
AFTER="$(cat "$(state malformed)")"
[ -z "$OUT" ] && [ "$BEFORE" = "$AFTER" ] && [ ! -e "$(counter malformed)" ] \
  && check "S10 malformed state is a no-op with no repair write" PASS \
  || check "S10 malformed state is a no-op with no repair write" FAIL

# Syntactically valid but incomplete or cross-session state is malformed too.
printf '%s\n' '{"session_id":"partial","active":true,"implComplete":true,"reviewTicket":"partial-ticket","reviewTicketConsumed":false}' > "$(state partial)"
BEFORE="$(cat "$(state partial)")"
OUT="$(run_hook partial zensu:code-reviewer "$(review_prompt partial-ticket)")"
AFTER="$(cat "$(state partial)")"
[ -z "$OUT" ] && [ "$BEFORE" = "$AFTER" ] && [ ! -e "$(counter partial)" ] \
  && check "S11 incomplete typed state is a no-op" PASS \
  || check "S11 incomplete typed state is a no-op" FAIL

# All routing flags and a shape-valid ticket are not sufficient: the hook must
# validate the complete chain schema before claiming the ticket. This fixture
# deliberately omits only the mandatory boolean `vanilla` field.
printf '%s\n' '{"session_id":"missing-required","phase":"UNINITIALIZED","history":[],"active":true,"implComplete":true,"chainDone":false,"codeReviewDone":false,"selfReviewFixed":false,"reviewTicket":"schema-ticket","reviewTicketConsumed":false,"bypasses":[]}' > "$(state missing-required)"
BEFORE="$(cat "$(state missing-required)")"
OUT="$(run_hook missing-required zensu:code-reviewer "$(review_prompt schema-ticket)")"
AFTER="$(cat "$(state missing-required)")"
[ -z "$OUT" ] && [ "$BEFORE" = "$AFTER" ] && [ ! -e "$(counter missing-required)" ] \
  && check "S11a missing mandatory schema field is a byte-stable no-op" PASS \
  || check "S11a missing mandatory schema field is a byte-stable no-op" FAIL

printf '%s\n' '{"session_id":"different-session","active":true,"implComplete":true,"chainDone":false,"codeReviewDone":false,"reviewTicket":"wrong-session-ticket","reviewTicketConsumed":false}' > "$(state wrong-session)"
BEFORE="$(cat "$(state wrong-session)")"
OUT="$(run_hook wrong-session zensu:code-reviewer "$(review_prompt wrong-session-ticket)")"
AFTER="$(cat "$(state wrong-session)")"
[ -z "$OUT" ] && [ "$BEFORE" = "$AFTER" ] && [ ! -e "$(counter wrong-session)" ] \
  && check "S12 state owned by another session is a no-op" PASS \
  || check "S12 state owned by another session is a no-op" FAIL

# Parallel duplicate deliveries race on one atomic ticket claim; exactly one wins.
bash "$LOG" --tdd-begin --session concurrent >/dev/null
bash "$LOG" --tdd-complete --session concurrent >/dev/null
CONCURRENT_TICKET="$(issue_ticket concurrent)"
CONCURRENT_PROMPT="$(review_prompt "$CONCURRENT_TICKET")"
i=1
while [ "$i" -le 20 ]; do
  run_hook concurrent zensu:code-reviewer "$CONCURRENT_PROMPT" > "$ROOT/concurrent-$i.out" &
  i=$((i + 1))
done
wait
COUNT="$(node -e 'try{process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1])).count))}catch(_){process.stdout.write("")}' "$(counter concurrent)")"
WINNERS="$(grep -l 'hookSpecificOutput' "$ROOT"/concurrent-*.out 2>/dev/null | wc -l | tr -d '[:space:]')"
[ "$COUNT" = "1" ] && [ "$WINNERS" = "1" ] \
  && check "S13 parallel duplicate completions produce one routed round" PASS \
  || check "S13 parallel duplicate completions produce one routed round" FAIL

# Every delayed terminus is bound to the consumed ticket. Re-arming between
# claim and close invalidates old PASS/max/self-review commands.
SID_STALE="stale-terminus"
bash "$LOG" --tdd-begin --session "$SID_STALE" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_STALE" >/dev/null
STALE_TICKET="$(issue_ticket "$SID_STALE")"
ROUND="$(bash -c 'source "$1"; tdd_consume_review_ticket "$2" "$3" "$4"' _ \
  "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" "$SID_STALE" "$STALE_TICKET" "$(counter "$SID_STALE")")"
bash "$LOG" --tdd-begin --session "$SID_STALE" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_STALE" >/dev/null
if [ "$ROUND" = "1" ] \
  && ! bash "$LOG" --code-review-done --session "$SID_STALE" --claimed-review-ticket "$STALE_TICKET" >/dev/null 2>&1 \
  && ! bash "$LOG" --chain-done --session "$SID_STALE" --claimed-review-ticket "$STALE_TICKET" >/dev/null 2>&1 \
  && [ "$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(String(j.codeReviewDone||j.chainDone));' "$(state "$SID_STALE")")" = "false" ]; then
  check "S14 stale PASS/max close cannot mark a re-armed generation" PASS
else
  check "S14 stale PASS/max close cannot mark a re-armed generation" FAIL
fi

SID_SELF="stale-self-review"
bash "$LOG" --tdd-begin --session "$SID_SELF" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_SELF" >/dev/null
SELF_TICKET="$(issue_ticket "$SID_SELF")"
bash -c 'source "$1"; tdd_consume_review_ticket "$2" "$3" "$4" >/dev/null' _ \
  "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" "$SID_SELF" "$SELF_TICKET" "$(counter "$SID_SELF")"
bash "$LOG" --code-review-done --session "$SID_SELF" --claimed-review-ticket "$SELF_TICKET" >/dev/null
bash "$LOG" --tdd-begin --session "$SID_SELF" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_SELF" >/dev/null
if ! bash "$LOG" --self-review-fixed --session "$SID_SELF" --claimed-review-ticket "$SELF_TICKET" >/dev/null 2>&1 \
  && ! bash "$LOG" --chain-done --session "$SID_SELF" --claimed-review-ticket "$SELF_TICKET" >/dev/null 2>&1 \
  && [ "$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(String(j.selfReviewFixed||j.chainDone));' "$(state "$SID_SELF")")" = "false" ]; then
  check "S15 stale self-review latch/terminus cannot close a new generation" PASS
else
  check "S15 stale self-review latch/terminus cannot close a new generation" FAIL
fi

SID_UNBOUND="unbound-after-ticket"
bash "$LOG" --tdd-begin --session "$SID_UNBOUND" >/dev/null
bash "$LOG" --tdd-complete --session "$SID_UNBOUND" >/dev/null
UNBOUND_TICKET="$(issue_ticket "$SID_UNBOUND")"
bash -c 'source "$1"; tdd_consume_review_ticket "$2" "$3" "$4" >/dev/null' _ \
  "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" "$SID_UNBOUND" "$UNBOUND_TICKET" "$(counter "$SID_UNBOUND")"
if ! bash "$LOG" --chain-done --session "$SID_UNBOUND" >/dev/null 2>&1 \
  && [ "$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(String(j.chainDone));' "$(state "$SID_UNBOUND")")" = "false" ]; then
  check "S16 unqualified terminus is rejected after a ticket was consumed" PASS
else
  check "S16 unqualified terminus is rejected after a ticket was consumed" FAIL
fi

echo "----"
echo "test-post-review-tdd-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
