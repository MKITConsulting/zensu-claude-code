#!/bin/bash
# The code-reviewer completion hook is scoped to one live TDD review chain.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
HANDBACK_HOOK="$PLUGIN_DIR/hooks/user-prompt-review-handback.sh"
STOP_HOOK="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
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

run_launch() {
  local sid="$1" prompt="$2" status="$3" agent="${4-}" payload_sid="$1"
  if [ -n "${ZENSU_SESSION_KEY:-}" ] && [ "$sid" = "$ZENSU_SESSION_KEY" ]; then
    payload_sid="${CLAUDE_CODE_SESSION_ID:?native host session id unavailable}"
  fi
  SID="$payload_sid" PROMPT="$prompt" STATUS="$status" AGENT="$agent" node -e '
    const response = {status: process.env.STATUS, isAsync: process.env.STATUS === "async_launched"};
    if (process.env.AGENT !== "") response.agentId = process.env.AGENT;
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {subagent_type: "zensu:code-reviewer", prompt: process.env.PROMPT},
      tool_response: response,
      session_id: process.env.SID
    }));
  ' | bash "$HOOK" 2>/dev/null
}

handback_prompt() {
  printf '<agent-message from="%s">\n' "$1"
  printf '%s\n' '[Subagent hand-back] The text below is the final report of a subagent this session delegated to. The report follows:'
  printf '%s\n' "${2:-# Code Review Report}" "" "- Verdict: PASS" | sed 's/^/  /'
  printf '%s' '</agent-message>'
}

run_handback() {
  local sid="$1" prompt="$2" payload_sid="$1"
  if [ -n "${ZENSU_SESSION_KEY:-}" ] && [ "$sid" = "$ZENSU_SESSION_KEY" ]; then
    payload_sid="${CLAUDE_CODE_SESSION_ID:?native host session id unavailable}"
  fi
  SID="$payload_sid" PROMPT="$prompt" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "UserPromptSubmit",
      prompt: process.env.PROMPT,
      session_id: process.env.SID
    }));
  ' | bash "$HANDBACK_HOOK" 2>/dev/null
}

context_of() {
  node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const h = JSON.parse(s).hookSpecificOutput;
        process.stdout.write(`${h.hookEventName}\n${h.additionalContext}`);
      } catch (_) {}
    });
  '
}

binding_of() {
  FILE="$(state "$1")" node -e '
    try {
      const b = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8")).reviewHandback;
      process.stdout.write(b === undefined ? "absent" : `${b.ticket} ${b.agentId} ${b.envelope.length}`);
    } catch (_) { process.stdout.write("invalid"); }
  '
}

stop_with_tasks() {
  local sid="$1" tasks="$2" payload_sid="$1"
  if [ -n "${ZENSU_SESSION_KEY:-}" ] && [ "$sid" = "$ZENSU_SESSION_KEY" ]; then
    payload_sid="${CLAUDE_CODE_SESSION_ID:?native host session id unavailable}"
  fi
  SID="$payload_sid" TASKS="$tasks" node -e '
    const payload = {hook_event_name: "Stop", session_id: process.env.SID, stop_hook_active: false};
    if (process.env.TASKS !== "absent") payload.background_tasks = JSON.parse(process.env.TASKS);
    process.stdout.write(JSON.stringify(payload));
  ' | bash "$STOP_HOOK"
}

stop_decision() {
  stop_with_tasks "$1" "$2" 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(s.trim()).decision === "block" ? "block" : "allow"); }
      catch (_) { process.stdout.write("allow"); }
    });
  '
}

reviewer_tasks() {
  printf '[{"id":"%s","type":"subagent","status":"%s","description":"consume-mode review","agent_type":"zensu:code-reviewer"}]' "$1" "${2:-running}"
}

AGENT_A=a84666756e22c9750
AGENT_B=ab257b34050b043c4

start_session background
H="$STARTED_SESSION_KEY"
log --tdd-begin --session "$H"
log --tdd-complete --session "$H"
H_TICKET="$(issue_ticket "$H")"
H_PROMPT="$(review_prompt "$H_TICKET" 'merged findings')"
H_STATE="$(state "$H")"
H1_OUT="$(run_launch "$H" "$H_PROMPT" async_launched "$AGENT_A" | context_of)"
H_BOUND="$(digest "$H_STATE")"
case "$H1_OUT" in
  "PostToolUse"$'\n'*"runs in the background as agent $AGENT_A"*"hand-back"*) H1_TEXT=yes ;;
  *) H1_TEXT=no ;;
esac
[ "$H1_TEXT" = yes ] && [ "$(binding_of "$H")" = "$H_TICKET $AGENT_A 0" ] \
  && [ "$(ticket_consumed "$H")" = "false" ] && [ "$(review_round "$H")" = "0" ] \
  && check "H1 a background launch binds its ticket to the agent and leaves it unconsumed" PASS \
  || check "H1 a background launch binds its ticket to the agent and leaves it unconsumed (text=$H1_TEXT binding=$(binding_of "$H") consumed=$(ticket_consumed "$H"))" FAIL

H2_OUT="$(run_launch "$H" "$H_PROMPT" async_launched "$AGENT_A" | context_of)"
case "$H2_OUT" in *"runs in the background as agent $AGENT_A"*) H2_TEXT=yes ;; *) H2_TEXT=no ;; esac
[ "$H2_TEXT" = yes ] && [ "$(digest "$H_STATE")" = "$H_BOUND" ] \
  && check "H2 a repeated delivery of the same launch is idempotent" PASS \
  || check "H2 a repeated delivery of the same launch is idempotent (text=$H2_TEXT)" FAIL

H3_OUT="$(run_launch "$H" "$H_PROMPT" async_launched "$AGENT_B" | context_of)"
case "$H3_OUT" in *"already bound to agent $AGENT_A"*) H3_TEXT=yes ;; *) H3_TEXT=no ;; esac
[ "$H3_TEXT" = yes ] && [ "$(digest "$H_STATE")" = "$H_BOUND" ] \
  && check "H3 a second background launch for a bound ticket keeps the binding and names its holder" PASS \
  || check "H3 a second background launch for a bound ticket keeps the binding and names its holder (text=$H3_TEXT)" FAIL

H_STOPS="$(tdd_get_counter "$H_STATE" stopBlockCount)"
H4_OUT="$(stop_with_tasks "$H" "$(reviewer_tasks "$AGENT_A")" 2>"$ROOT/h4.err")"; H4_RC=$?
if [ "$H4_RC" -eq 0 ] && [ -z "$H4_OUT" ] \
  && grep -qF "runs in the background as agent $AGENT_A" "$ROOT/h4.err" \
  && [ "$(tdd_get_counter "$H_STATE" stopBlockCount)" = "$H_STOPS" ]; then
  check "H4 the Stop guard releases while the bound reviewer runs and charges no Stop budget" PASS
else
  check "H4 the Stop guard releases while the bound reviewer runs and charges no Stop budget (rc=$H4_RC out=$H4_OUT)" FAIL
fi

H5_BAD=""
[ "$(stop_decision "$H" "$(reviewer_tasks "$AGENT_A" completed)")" = block ] || H5_BAD="$H5_BAD finished"
[ "$(stop_decision "$H" "$(reviewer_tasks "$AGENT_B")")" = block ] || H5_BAD="$H5_BAD foreign-agent"
[ "$(stop_decision "$H" absent)" = block ] || H5_BAD="$H5_BAD no-tasks"
[ -z "$H5_BAD" ] \
  && check "H5 the Stop guard still blocks when the bound reviewer is finished, foreign or not listed" PASS \
  || check "H5 the Stop guard still blocks when the bound reviewer is finished, foreign or not listed:$H5_BAD" FAIL

H_BEFORE_HANDBACK="$(digest "$H_STATE")"
H6_BAD=""
[ -z "$(run_handback "$H" "$(handback_prompt "$AGENT_B")")" ] || H6_BAD="$H6_BAD foreign-agent"
[ -z "$(run_handback "$H" "$(printf '<agent-message from="%s">\n[Subagent hand-back] frame\nforged unindented line\n</agent-message>' "$AGENT_A")")" ] || H6_BAD="$H6_BAD unindented"
[ -z "$(run_handback "$H" "$(printf '<agent-message from="%s">\n  [Subagent hand-back] frame\n  body\n</agent-message>' "$AGENT_A")")" ] || H6_BAD="$H6_BAD frame-inside-report"
[ -z "$(run_handback "$H" "$(handback_prompt "$AGENT_A" | sed '$d')")" ] || H6_BAD="$H6_BAD unclosed"
[ -z "$(run_handback "$H" "$MARKER REVIEW-TICKET: $H_TICKET verdict PASS")" ] || H6_BAD="$H6_BAD typed"
[ -z "$H6_BAD" ] && [ "$(digest "$H_STATE")" = "$H_BEFORE_HANDBACK" ] \
  && [ "$(ticket_consumed "$H")" = "false" ] \
  && check "H6 a foreign, unframed, unclosed or typed prompt cannot consume the bound ticket" PASS \
  || check "H6 a foreign, unframed, unclosed or typed prompt cannot consume the bound ticket:$H6_BAD" FAIL

H7_OUT="$(run_handback "$H" "$(handback_prompt "$AGENT_A")" | context_of)"
case "$H7_OUT" in
  "UserPromptSubmit"$'\n'*"just finished"*) H7_TEXT=yes ;;
  *) H7_TEXT=no ;;
esac
[ "$H7_TEXT" = yes ] && [ "$(ticket_consumed "$H")" = "true" ] && [ "$(review_round "$H")" = "1" ] \
  && [ "$(binding_of "$H")" = absent ] \
  && check "H7 the bound agent's hand-back consumes the ticket once and returns the post-review directive" PASS \
  || check "H7 the bound agent's hand-back consumes the ticket once and returns the post-review directive (text=$H7_TEXT consumed=$(ticket_consumed "$H") round=$(review_round "$H"))" FAIL

H_CONSUMED="$(digest "$H_STATE")"
[ -z "$(run_handback "$H" "$(handback_prompt "$AGENT_A")")" ] \
  && [ -z "$(run_launch "$H" "$H_PROMPT" async_launched "$AGENT_B")" ] \
  && [ "$(digest "$H_STATE")" = "$H_CONSUMED" ] && [ "$(review_round "$H")" = "1" ] \
  && check "H8 a repeated hand-back and a launch for the consumed ticket are byte-stable no-ops" PASS \
  || check "H8 a repeated hand-back and a launch for the consumed ticket are byte-stable no-ops" FAIL

if log --code-review-done --session "$H" --claimed-review-ticket "$H_TICKET" \
  && log --chain-done --session "$H" --claimed-review-ticket "$H_TICKET" \
  && [ "$(state_value "$H_STATE" chainDone)" = "true" ]; then
  check "H9 a chain whose consume-mode reviewer ran in the background closes through --chain-done --claimed-review-ticket" PASS
else
  check "H9 a chain whose consume-mode reviewer ran in the background closes through --chain-done --claimed-review-ticket" FAIL
fi

start_session background-unbound
HU="$STARTED_SESSION_KEY"
log --tdd-begin --session "$HU"
log --tdd-complete --session "$HU"
HU_TICKET="$(issue_ticket "$HU")"
HU_OUT="$(run_launch "$HU" "$(review_prompt "$HU_TICKET")" async_launched "" | context_of)"
case "$HU_OUT" in *"could not be bound"*"--review-ticket"*) HU_TEXT=yes ;; *) HU_TEXT=no ;; esac
[ "$HU_TEXT" = yes ] && [ "$(binding_of "$HU")" = absent ] && [ "$(ticket_consumed "$HU")" = "false" ] \
  && check "H10 a background launch without a usable agent id records nothing and says the chain cannot advance" PASS \
  || check "H10 a background launch without a usable agent id records nothing and says the chain cannot advance (text=$HU_TEXT)" FAIL

start_session background-foreground
HF="$STARTED_SESSION_KEY"
log --tdd-begin --session "$HF"
log --tdd-complete --session "$HF"
HF_TICKET="$(issue_ticket "$HF")"
HF_PROMPT="$(review_prompt "$HF_TICKET" 'merged findings')"
run_launch "$HF" "$HF_PROMPT" async_launched "$AGENT_A" >/dev/null
HF_BOUND="$(binding_of "$HF")"
HF_DONE="$(run_launch "$HF" "$HF_PROMPT" completed "" | context_of)"
HF_LATE="$(run_handback "$HF" "$(handback_prompt "$AGENT_A")")"
case "$HF_DONE" in "PostToolUse"$'\n'*"just finished"*) HF_TEXT=yes ;; *) HF_TEXT=no ;; esac
[ "$HF_BOUND" = "$HF_TICKET $AGENT_A 0" ] && [ "$HF_TEXT" = yes ] && [ -z "$HF_LATE" ] \
  && [ "$(ticket_consumed "$HF")" = "true" ] && [ "$(review_round "$HF")" = "1" ] \
  && [ "$(binding_of "$HF")" = absent ] \
  && check "H11 a foreground completion still routes, removes the binding, and the late hand-back is a no-op" PASS \
  || check "H11 a foreground completion still routes, removes the binding, and the late hand-back is a no-op (bound=$HF_BOUND text=$HF_TEXT late=$HF_LATE)" FAIL

start_session background-reset
HR="$STARTED_SESSION_KEY"
log --tdd-begin --session "$HR"
log --tdd-complete --session "$HR"
HR_T1="$(issue_ticket "$HR")"
run_launch "$HR" "$(review_prompt "$HR_T1")" async_launched "$AGENT_A" >/dev/null
HR_B1="$(binding_of "$HR")"
HR_T2="$(issue_ticket "$HR")"
HR_B2="$(binding_of "$HR")"
run_launch "$HR" "$(review_prompt "$HR_T2")" async_launched "$AGENT_B" >/dev/null
HR_B3="$(binding_of "$HR")"
log --tdd-begin --session "$HR"
HR_B4="$(binding_of "$HR")"
log --tdd-complete --session "$HR"
HR_T3="$(issue_ticket "$HR")"
run_launch "$HR" "$(review_prompt "$HR_T3")" async_launched "$AGENT_A" >/dev/null
HR_B5="$(binding_of "$HR")"
log --tdd-reset --session "$HR"
HR_B6="$(binding_of "$HR")"
[ "$HR_B1" = "$HR_T1 $AGENT_A 0" ] && [ "$HR_B2" = absent ] && [ "$HR_B3" = "$HR_T2 $AGENT_B 0" ] \
  && [ "$HR_B4" = absent ] && [ "$HR_B5" = "$HR_T3 $AGENT_A 0" ] && [ "$HR_B6" = absent ] \
  && check "H12 a fresh ticket, --tdd-begin and --tdd-reset remove the binding" PASS \
  || check "H12 a fresh ticket, --tdd-begin and --tdd-reset remove the binding ($HR_B1|$HR_B2|$HR_B3|$HR_B4|$HR_B5|$HR_B6)" FAIL

start_session background-invalid
HI="$STARTED_SESSION_KEY"
log --tdd-begin --session "$HI"
log --tdd-complete --session "$HI"
HI_TICKET="$(issue_ticket "$HI")"
run_launch "$HI" "$(review_prompt "$HI_TICKET")" async_launched "$AGENT_A" >/dev/null
HI_VALID="$(tdd_state_status "$(state "$HI")")"
FILE="$(state "$HI")" node -e '
  const fs = require("fs"), s = JSON.parse(fs.readFileSync(process.env.FILE, "utf8"));
  s.reviewHandback.extra = true;
  fs.writeFileSync(process.env.FILE, JSON.stringify(s, null, 2));
'
HI_INVALID="$(tdd_state_status "$(state "$HI")")"
[ "$HI_VALID" = valid ] && [ "$HI_INVALID" = invalid ] \
  && check "H13 the workflow document validates reviewHandback with an exact key set" PASS \
  || check "H13 the workflow document validates reviewHandback with an exact key set ($HI_VALID then $HI_INVALID)" FAIL

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
CLOSE_PASS_HITS="$(grep -cF -- 'CLOSE_PASS="FIRST, ${FULL_SUITE_STEP}. ' "$HOOK" 2>/dev/null || echo 0)"
if [ "$CLOSE_PASS_HITS" -eq 2 ] \
  && grep -qF -- 'FULL_SUITE_STEP="run the FULL test suite through the evidence runner, skipping it only when the newest full-suite record is already green on the current tree: ${LOG_COMMAND} --evidence-run --scope full --if-stale' "$HOOK" \
  && grep -qF -- 'this convergence branch is where the verdict for the tree that ships is measured' "$HOOK" \
  && grep -qF -- 'NO self-review stage follows in this configuration' "$HOOK" \
  && [ "$(grep -cF -- '--evidence-run --scope full --if-stale' "$HOOK" 2>/dev/null || echo 0)" -eq 1 ]; then
  check "S17 both CLOSE_PASS arms carry the convergence full-suite instruction" PASS
else
  check "S17 both CLOSE_PASS arms carry the convergence full-suite instruction (hits: $CLOSE_PASS_HITS)" FAIL
fi

source "$STATE_LIB"
BOUND_PROJECT="$ROOT/bound-project"
mkdir -p "$BOUND_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd "$BOUND_PROJECT" && pwd -P)"
start_session background-bound
HB="$STARTED_SESSION_KEY"
HB_RUN=handback_bound_run
HB_CHAIN=handback-bound-chain
HB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
autopilot_begin_run "$HB_RUN" "$HB" "$CLAUDE_PROJECT_DIR" >/dev/null 2>&1
autopilot_apply_event "$HB_RUN" "plan-$HB_RUN" PLAN_APPROVED "{\"approvedPlanSha256\":\"$HB_SHA\"}" \
  "$CLAUDE_PROJECT_DIR" "$HB" >/dev/null 2>&1
log --tdd-begin --session "$HB" --autopilot-run "$HB_RUN" --autopilot-attempt 1 \
  --autopilot-return-stage GATES --chain-id "$HB_CHAIN"
log --tdd-complete --session "$HB" --autopilot-run "$HB_RUN" --autopilot-attempt 1 \
  --autopilot-return-stage GATES --chain-id "$HB_CHAIN"
HB_TICKET="$(issue_ticket "$HB")"
HB_PROMPT="$(printf '%s\nREVIEW-TICKET: %s\nZENSU-DELEGATED-CALLER: autopilot\nAUTOPILOT-BINDING: run=%s attempt=1 chain=%s\nAUTOPILOT-STAGE: GATES\nfixture' \
  "$MARKER" "$HB_TICKET" "$HB_RUN" "$HB_CHAIN")"
run_launch "$HB" "$HB_PROMPT" async_launched "$AGENT_A" >/dev/null
HB_BOUND="$(binding_of "$HB")"
HB_OUT="$(run_handback "$HB" "$(handback_prompt "$AGENT_A")" | context_of)"
case "$HB_OUT" in
  "UserPromptSubmit"$'\n'*"just finished"*"Official Autopilot handoff envelope"*"AUTOPILOT-BINDING: run=$HB_RUN attempt=1 chain=$HB_CHAIN"*) HB_TEXT=yes ;;
  *) HB_TEXT=no ;;
esac
[ -n "$HB_TICKET" ] && [ "$HB_BOUND" = "$HB_TICKET $AGENT_A 3" ] && [ "$HB_TEXT" = yes ] \
  && [ "$(ticket_consumed "$HB")" = "true" ] && [ "$(review_round "$HB")" = "1" ] \
  && check "H14 an Autopilot-bound background reviewer binds its envelope and its hand-back routes with the official envelope" PASS \
  || check "H14 an Autopilot-bound background reviewer binds its envelope and its hand-back routes with the official envelope (ticket=$HB_TICKET bound=$HB_BOUND text=$HB_TEXT consumed=$(ticket_consumed "$HB"))" FAIL

echo "----"
echo "test-post-review-tdd-scope: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
