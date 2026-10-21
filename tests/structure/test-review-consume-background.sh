#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
SUBSTOP="$PLUGIN_DIR/hooks/review-consume-subagent-stop.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
MODULE="$PLUGIN_DIR/hooks/lib/review-consume-v1.js"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
WORK="$(mktemp -d -t zensu-review-consume-XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
PROJ="$WORK/project"
mkdir -p "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
export CLAUDE_PROJECT_DIR="$PROJ"
trap 'rm -rf "$WORK"' EXIT
export ZENSU_CONFIG="$WORK/config.json"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$ZENSU_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_CHAIN CLAUDE_PLUGIN_DATA ZENSU_PROJECT_ROOT \
  ZENSU_SESSION_CONTEXT ZENSU_SESSION_KEY ZENSU_TEST_PLUGIN_DATA 2>/dev/null || true

start_session() {
  SID_RAW="$1"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data-$1"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID_RAW"
  SID_KEY="$ZENSU_SESSION_KEY"
  PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
  unset ZENSU_CLAUDE_PLUGIN_ROOT ZENSU_SESSION_KEY ZENSU_SESSION_CONTEXT \
    ZENSU_RUNTIME_DIGEST ZENSU_PROJECT_ROOT
  export CLAUDE_PLUGIN_DATA="$PLUGIN_DATA"
  STATE_FILE="$PROJ/.zensu/state/tdd-phase-${SID_KEY}.json"
  RECORDS="$PROJ/.zensu/state/review-consume-${SID_KEY}"
}

model_log() {
  CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$SID_RAW" bash "$LOG" "$@"
}

post_review() {
  STATUS="$1" AGENT="$2" TICKET="$3" SID_VALUE="$SID_RAW" node -e '
    const payload = {
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nREVIEW PACKET v1\nfixture`,
      },
      session_id: process.env.SID_VALUE,
    };
    if (process.env.STATUS) {
      payload.tool_response = { status: process.env.STATUS };
      if (process.env.AGENT) payload.tool_response.agentId = process.env.AGENT;
    }
    process.stdout.write(JSON.stringify(payload));
  ' | bash "$POSTREV" 2>/dev/null
}

context_of() {
  node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(s).hookSpecificOutput.additionalContext || ""); }
      catch (_) { process.stdout.write(""); }
    });
  '
}

subagent_stop() {
  AGENT="$1" TYPE="$2" SID_VALUE="$SID_RAW" PROJECT_VALUE="$PROJ" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "SubagentStop",
      session_id: process.env.SID_VALUE,
      cwd: process.env.PROJECT_VALUE,
      agent_id: process.env.AGENT,
      agent_type: process.env.TYPE,
      last_assistant_message: "",
      stop_hook_active: false,
    }));
  ' | CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" bash "$SUBSTOP"
}

stop_hook() {
  printf '%s' '{"hook_event_name":"Stop","session_id":"'"$SID_RAW"'"}' \
    | CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" bash "$STOP" 2>"$WORK/stop.err"
}

decision_of() {
  node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { process.stdout.write("allow"); return; }
      try { process.stdout.write(JSON.parse(s).decision === "block" ? "block" : "allow"); }
      catch (_) { process.stdout.write("allow"); }
    });
  '
}

reason_of() {
  node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(s).reason || ""); } catch (_) { process.stdout.write(""); }
    });
  '
}

state_field() {
  CONTROL_CORE="$SESSION_CORE" PROJECT_ROOT="$PROJ" SID="$SID_RAW" FIELD="$1" node -e '
    try {
      const core = require(process.env.CONTROL_CORE);
      const s = core.readWorkflowState({ projectRoot: process.env.PROJECT_ROOT, sessionId: process.env.SID });
      process.stdout.write(String(s[process.env.FIELD]));
    } catch (_) { process.stdout.write("?"); }
  '
}

digest() {
  node -e '
    const fs = require("fs"), crypto = require("crypto");
    process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
  ' "$1"
}

record_field() {
  FILE="$1" FIELD="$2" node -e '
    try {
      const r = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
      process.stdout.write(String(r[process.env.FIELD]));
    } catch (_) { process.stdout.write("?"); }
  '
}

contains() {
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

echo "== Registration =="
if node -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks;
  const groups = h.SubagentStop || [];
  const hits = groups.filter(g => g.matcher === undefined)
    .flatMap(g => g.hooks)
    .filter(x => x.type === "command" && x.command === "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/review-consume-subagent-stop.sh\"");
  process.exit(hits.length === 1 && Number.isInteger(hits[0].timeout) ? 0 : 1);
' "$HOOKS_JSON" && [ -x "$SUBSTOP" ]; then
  check "BC0 hooks.json registers review-consume-subagent-stop.sh once on SubagentStop with a timeout" PASS
else
  check "BC0 hooks.json registers review-consume-subagent-stop.sh once on SubagentStop with a timeout" FAIL
fi

echo "== Background launch is recorded, not consumed =="
start_session background-main
model_log --tdd-begin >/dev/null 2>&1
model_log --tdd-complete >/dev/null 2>&1
TICKET="$(model_log --review-ticket 2>/dev/null)"
AGENT="a1b2c3d4e5f6a7b8c"
BEFORE="$(digest "$STATE_FILE")"
CTX="$(post_review async_launched "$AGENT" "$TICKET" | context_of)"
AFTER="$(digest "$STATE_FILE")"
if [ -n "$TICKET" ] && contains "$CTX" "async_launched" && contains "$CTX" "NOT consumed" \
  && contains "$CTX" "--review-consume --ticket $TICKET" && ! contains "$CTX" "run_in_background: false" \
  && contains "$CTX" "its hand-back message or its task notification" \
  && contains "$CTX" "failed or was stopped without a report" && contains "$CTX" "--review-ticket" \
  && ! contains "$CTX" "just finished" && [ "$AFTER" = "$BEFORE" ] \
  && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
  check "BC1 an async_launched reviewer keeps its ticket and is told to consume it after its notification" PASS
else
  check "BC1 an async_launched reviewer keeps its ticket and is told to consume it after its notification (ctx='$CTX')" FAIL
fi
LAUNCH_FILE="$RECORDS/launch-$AGENT.json"
if [ -f "$LAUNCH_FILE" ] && [ "$(record_field "$LAUNCH_FILE" ticket)" = "$TICKET" ] \
  && [ "$(record_field "$LAUNCH_FILE" agentId)" = "$AGENT" ] \
  && [ "$(record_field "$LAUNCH_FILE" kind)" = "standalone" ] && [ ! -e "$RECORDS/stop-$AGENT.json" ]; then
  check "BC2 the launch is recorded against the ticket and the agent id" PASS
else
  check "BC2 the launch is recorded against the ticket and the agent id" FAIL
fi

echo "== The claim refuses until the reviewer stopped =="
OUT="$(model_log --review-consume --ticket "$TICKET" 2>&1)"
RC=$?
if [ "$RC" -eq 4 ] && contains "$OUT" "has not stopped yet" && contains "$OUT" "its stop was not recorded" \
  && [ "$(digest "$STATE_FILE")" = "$BEFORE" ]; then
  check "BC3 --review-consume refuses a running reviewer with exit 4 and changes nothing" PASS
else
  check "BC3 --review-consume refuses a running reviewer with exit 4 and changes nothing (rc=$RC out='$OUT')" FAIL
fi
OUT="$(model_log --review-consume --ticket rt_00000000000000000000000000000000 2>&1)"
RC=$?
if [ "$RC" -eq 3 ] && contains "$OUT" "no background zensu:code-reviewer launch is recorded"; then
  check "BC4 --review-consume refuses a ticket without a recorded launch with exit 3" PASS
else
  check "BC4 --review-consume refuses a ticket without a recorded launch with exit 3 (rc=$RC out='$OUT')" FAIL
fi
OUT="$(model_log --review-consume 2>&1)"
RC=$?
OUT2="$(model_log --review-consume --ticket "$TICKET" --extra x 2>&1)"
RC2=$?
if [ "$RC" -eq 2 ] && [ "$RC2" -eq 2 ] && contains "$OUT2" "unknown argument"; then
  check "BC5 --review-consume requires exactly --ticket" PASS
else
  check "BC5 --review-consume requires exactly --ticket (rc=$RC/$RC2)" FAIL
fi

echo "== The Stop guard waits for the running reviewer, bounded =="
WAITS_OK=true
for n in 1 2 3; do
  DECISION="$(stop_hook | decision_of)"
  if [ "$DECISION" != "allow" ] || ! grep -qF "wait $n of 3" "$WORK/stop.err" \
    || ! grep -qF -- "--review-consume --ticket $TICKET" "$WORK/stop.err"; then
    WAITS_OK=false
  fi
done
if [ "$WAITS_OK" = true ] && [ "$(state_field stopBlockCount)" = "0" ]; then
  check "BC6 three Stops are released while the reviewer runs, none counted against the cap" PASS
else
  check "BC6 three Stops are released while the reviewer runs, none counted against the cap" FAIL
fi
STOP_OUT="$(stop_hook)"
STOP_REASON="$(printf '%s' "$STOP_OUT" | reason_of)"
if [ "$(printf '%s' "$STOP_OUT" | decision_of)" = "block" ] && contains "$STOP_REASON" "has not stopped yet" \
  && contains "$STOP_REASON" "--review-consume --ticket $TICKET" \
  && ! contains "$STOP_REASON" "Resume the /zensu:tdd Phase 6 review sequence"; then
  check "BC7 past the wait bound the Stop blocks with the claim command, not a review restart" PASS
else
  check "BC7 past the wait bound the Stop blocks with the claim command, not a review restart (reason='$STOP_REASON')" FAIL
fi

echo "== SubagentStop records only the launched reviewer =="
OUT="$(subagent_stop "$AGENT" zensu:review-aspect)"
RC=$?
OUT2="$(subagent_stop a9999999999999999 zensu:code-reviewer)"
RC2=$?
if [ "$RC" -eq 0 ] && [ "$RC2" -eq 0 ] && [ -z "$OUT$OUT2" ] && [ ! -e "$RECORDS/stop-$AGENT.json" ] \
  && [ ! -e "$RECORDS/stop-a9999999999999999.json" ]; then
  check "BC8 a stop of another agent type or of an unlaunched reviewer records nothing" PASS
else
  check "BC8 a stop of another agent type or of an unlaunched reviewer records nothing" FAIL
fi
BEFORE_STOP="$(digest "$STATE_FILE")"
OUT="$(subagent_stop "$AGENT" zensu:code-reviewer)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -f "$RECORDS/stop-$AGENT.json" ] \
  && [ "$(record_field "$RECORDS/stop-$AGENT.json" agentType)" = "zensu:code-reviewer" ] \
  && [ "$(digest "$STATE_FILE")" = "$BEFORE_STOP" ] \
  && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
  check "BC9 the launched reviewer's SubagentStop records its stop silently and claims nothing" PASS
else
  check "BC9 the launched reviewer's SubagentStop records its stop silently and claims nothing" FAIL
fi
REPLAY="$(post_review async_launched "$AGENT" "$TICKET" | context_of)"
if contains "$REPLAY" "--review-consume --ticket $TICKET" && [ -f "$RECORDS/stop-$AGENT.json" ] \
  && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
  check "BC9b a repeated delivery of the same async launch keeps the recorded stop" PASS
else
  check "BC9b a repeated delivery of the same async launch keeps the recorded stop" FAIL
fi
STOP_OUT="$(stop_hook)"
STOP_REASON="$(printf '%s' "$STOP_OUT" | reason_of)"
if [ "$(printf '%s' "$STOP_OUT" | decision_of)" = "block" ] && contains "$STOP_REASON" "has stopped" \
  && contains "$STOP_REASON" "--review-consume --ticket $TICKET" \
  && contains "$STOP_REASON" "failed or was stopped without a report" \
  && ! contains "$STOP_REASON" "Resume the /zensu:tdd Phase 6 review sequence"; then
  check "BC10 once the reviewer stopped the Stop names the claim command" PASS
else
  check "BC10 once the reviewer stopped the Stop names the claim command (reason='$STOP_REASON')" FAIL
fi

echo "== The claim consumes the ticket and routes the review =="
OUT="$(model_log --review-consume --ticket "$TICKET" 2>"$WORK/consume.err")"
RC=$?
if [ "$RC" -eq 0 ] && contains "$OUT" "consumed review ticket $TICKET" \
  && contains "$OUT" "its hand-back message or its task notification delivered" \
  && contains "$OUT" "The zensu:code-reviewer subagent above just finished" \
  && contains "$OUT" "--code-review-done --claimed-review-ticket $TICKET" \
  && ! contains "$OUT" "hookSpecificOutput" \
  && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ]; then
  check "BC11 --review-consume claims the stopped reviewer's ticket and prints the routing directive" PASS
else
  check "BC11 --review-consume claims the stopped reviewer's ticket and prints the routing directive (rc=$RC err='$(cat "$WORK/consume.err")')" FAIL
fi
CLAIMED="$(digest "$STATE_FILE")"
OUT="$(model_log --review-consume --ticket "$TICKET" 2>&1)"
RC=$?
if [ "$RC" -eq 5 ] && contains "$OUT" "could not be consumed" && [ "$(digest "$STATE_FILE")" = "$CLAIMED" ] \
  && [ "$(state_field reviewRound)" = "1" ]; then
  check "BC12 a second claim of the same ticket is refused with exit 5 and changes nothing" PASS
else
  check "BC12 a second claim of the same ticket is refused with exit 5 and changes nothing (rc=$RC)" FAIL
fi
DUP="$(post_review completed "$AGENT" "$TICKET")"
if [ -z "$DUP" ] && [ "$(digest "$STATE_FILE")" = "$CLAIMED" ]; then
  check "BC13 a late foreground completion of the consumed ticket stays a no-op" PASS
else
  check "BC13 a late foreground completion of the consumed ticket stays a no-op" FAIL
fi

echo "== The chain reaches its terminus through supported commands =="
model_log --code-review-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ "$(state_field codeReviewDone)" = "true" ]; then
  check "BC14 --code-review-done accepts the background-consumed ticket" PASS
else
  check "BC14 --code-review-done accepts the background-consumed ticket (rc=$RC)" FAIL
fi
model_log --chain-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ "$(state_field chainDone)" = "true" ] && [ "$(stop_hook | decision_of)" = "allow" ]; then
  check "BC15 --chain-done closes the chain and the Stop guard releases" PASS
else
  check "BC15 --chain-done closes the chain and the Stop guard releases (rc=$RC)" FAIL
fi

echo "== A new chain generation clears the records =="
model_log --tdd-begin >/dev/null 2>&1
if [ ! -e "$RECORDS" ]; then
  check "BC16 --tdd-begin removes the session's background review records" PASS
else
  check "BC16 --tdd-begin removes the session's background review records" FAIL
fi

echo "== An unrecordable launch falls back to the foreground respawn =="
model_log --tdd-complete >/dev/null 2>&1
TICKET2="$(model_log --review-ticket 2>/dev/null)"
printf 'not a directory\n' > "$RECORDS"
BEFORE="$(digest "$STATE_FILE")"
CTX="$(post_review async_launched "$AGENT" "$TICKET2" | context_of)"
if contains "$CTX" "could not be recorded" && contains "$CTX" "run_in_background: false" \
  && [ "$(digest "$STATE_FILE")" = "$BEFORE" ] && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
  check "BC17 a launch that cannot be recorded keeps the ticket and asks for a foreground reviewer" PASS
else
  check "BC17 a launch that cannot be recorded keeps the ticket and asks for a foreground reviewer (ctx='$CTX')" FAIL
fi
CTX="$(post_review async_launched "" "$TICKET2" | context_of)"
if contains "$CTX" "could not be recorded" && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
  check "BC18 a launch without an agent id is never recorded" PASS
else
  check "BC18 a launch without an agent id is never recorded" FAIL
fi
rm -f "$RECORDS"

echo "== The record module validates what it stores =="
module() {
  ZENSU_RC_PROJECT_ROOT="$PROJ" ZENSU_RC_SESSION_KEY="$SID_KEY" node "$MODULE" "$@"
}
module launch --ticket rt_bound --agent abound1 --kind bound --run run-1 --attempt 2 \
  --chain chain-1 --stage GATES >/dev/null 2>&1
RC=$?
RUNNING="$(module lookup --ticket rt_bound 2>/dev/null)"
RRC=$?
PROJECT_VALUE="$PROJ" SESSION_VALUE="$SID_KEY" MODULE_VALUE="$MODULE" node -e '
  const m = require(process.env.MODULE_VALUE);
  m.recordStop({ projectRoot: process.env.PROJECT_VALUE, sessionKey: process.env.SESSION_VALUE,
    agentId: "abound1", agentType: "zensu:code-reviewer" });
' >/dev/null 2>&1
STOPPED="$(module lookup --ticket rt_bound 2>/dev/null)"
SRC=$?
if [ "$RC" -eq 0 ] && [ "$RRC" -eq 4 ] && [ "$RUNNING" = "running" ] && [ "$SRC" -eq 0 ] \
  && [ "$STOPPED" = "$(printf 'stopped\tabound1\tbound\trun-1\t2\tchain-1\tGATES')" ]; then
  check "BC19 a bound launch round-trips its Autopilot envelope through the record" PASS
else
  check "BC19 a bound launch round-trips its Autopilot envelope through the record (rc=$RC/$RRC/$SRC '$STOPPED')" FAIL
fi
BAD=0
module launch --ticket rt_bad --agent abad1 --kind bound --run run-1 --attempt 1000 --chain chain-1 --stage GATES >/dev/null 2>&1 && BAD=$((BAD+1))
module launch --ticket rt_bad --agent abad2 --kind bound --run run-1 --attempt 1 --chain chain-1 --stage SHIP >/dev/null 2>&1 && BAD=$((BAD+1))
module launch --ticket rt_bad --agent abad3 --kind standalone --run run-1 --attempt 0 --chain - --stage - >/dev/null 2>&1 && BAD=$((BAD+1))
module launch --ticket 'rt bad' --agent abad4 --kind standalone --run - --attempt 0 --chain - --stage - >/dev/null 2>&1 && BAD=$((BAD+1))
module launch --ticket rt_bad --agent '../x' --kind standalone --run - --attempt 0 --chain - --stage - >/dev/null 2>&1 && BAD=$((BAD+1))
if [ "$BAD" -eq 0 ] && [ "$(module lookup --ticket rt_bad 2>/dev/null)" = "none" ]; then
  check "BC20 malformed launch fields are refused and nothing is recorded" PASS
else
  check "BC20 malformed launch fields are refused and nothing is recorded ($BAD accepted)" FAIL
fi
SESSION_DIR="$PROJ/.zensu/state/review-consume-$SID_KEY"
rm -rf "$SESSION_DIR"
ln -s "$WORK" "$SESSION_DIR"
module launch --ticket rt_link --agent alink1 --kind standalone --run - --attempt 0 --chain - --stage - >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -e "$WORK/launch-alink1.json" ]; then
  check "BC21 a symbolic link in place of the record directory is refused" PASS
else
  check "BC21 a symbolic link in place of the record directory is refused" FAIL
fi
rm -f "$SESSION_DIR"

echo "== A rotated-out ticket never claims, and a new ticket waits afresh =="
start_session background-rotate
model_log --tdd-begin >/dev/null 2>&1
model_log --tdd-complete >/dev/null 2>&1
T1="$(model_log --review-ticket 2>/dev/null)"
A1="a1111111111111111"
post_review async_launched "$A1" "$T1" >/dev/null
for n in 1 2 3; do stop_hook >/dev/null; done
LIMIT_REASON="$(stop_hook | reason_of)"
subagent_stop "$A1" zensu:code-reviewer >/dev/null
T2="$(model_log --review-ticket 2>/dev/null)"
ROTATED="$(digest "$STATE_FILE")"
OUT="$(model_log --review-consume --ticket "$T1" 2>&1)"
RC=$?
if contains "$LIMIT_REASON" "has not stopped yet" && [ -n "$T2" ] && [ "$T2" != "$T1" ] \
  && [ "$RC" -eq 5 ] && contains "$OUT" "could not be consumed" \
  && [ "$(digest "$STATE_FILE")" = "$ROTATED" ] && [ "$(state_field reviewTicket)" = "$T2" ] \
  && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
  check "BC22 the recorded stop of a rotated-out ticket is refused with exit 5 and changes nothing" PASS
else
  check "BC22 the recorded stop of a rotated-out ticket is refused with exit 5 and changes nothing (rc=$RC out='$OUT')" FAIL
fi
STOP_OUT="$(stop_hook)"
STOP_REASON="$(printf '%s' "$STOP_OUT" | reason_of)"
if [ "$(printf '%s' "$STOP_OUT" | decision_of)" = "block" ] \
  && contains "$STOP_REASON" "Resume the /zensu:tdd Phase 6 review sequence" \
  && ! contains "$STOP_REASON" "--review-consume --ticket $T1" \
  && ! grep -qF "releasing this Stop while the background" "$WORK/stop.err"; then
  check "BC23 the Stop guard ignores the records of a rotated-out ticket" PASS
else
  check "BC23 the Stop guard ignores the records of a rotated-out ticket (reason='$STOP_REASON')" FAIL
fi
A2="a2222222222222222"
post_review async_launched "$A2" "$T2" >/dev/null
if [ "$(stop_hook | decision_of)" = "allow" ] && grep -qF "wait 1 of 3" "$WORK/stop.err" \
  && grep -qF -- "--review-consume --ticket $T2" "$WORK/stop.err"; then
  check "BC24 the background reviewer of a new ticket starts a fresh wait" PASS
else
  check "BC24 the background reviewer of a new ticket starts a fresh wait" FAIL
fi

echo "== Another session cannot claim this session's reviewer =="
subagent_stop "$A2" zensu:code-reviewer >/dev/null
OWNER_STATE="$STATE_FILE"
OWNER_DIGEST="$(digest "$OWNER_STATE")"
start_session background-foreign
OUT="$(model_log --review-consume --ticket "$T2" 2>&1)"
RC=$?
if [ "$RC" -eq 3 ] && contains "$OUT" "no background zensu:code-reviewer launch is recorded" \
  && [ "$(digest "$OWNER_STATE")" = "$OWNER_DIGEST" ]; then
  check "BC25 a claim from another session finds no launch of its own and changes nothing" PASS
else
  check "BC25 a claim from another session finds no launch of its own and changes nothing (rc=$RC out='$OUT')" FAIL
fi

echo "== The guard keeps its routing when it must not or cannot wait =="
start_session background-guard
model_log --tdd-begin >/dev/null 2>&1
model_log --tdd-complete >/dev/null 2>&1
T3="$(model_log --review-ticket 2>/dev/null)"
A3="a3333333333333333"
post_review async_launched "$A3" "$T3" >/dev/null
CLAIM_FILE="$PROJ/.zensu/state/pending-review.json.claim"
: > "$CLAIM_FILE"
STOP_OUT="$(stop_hook)"
if [ "$(printf '%s' "$STOP_OUT" | decision_of)" = "block" ] \
  && ! grep -qF "releasing this Stop while the background" "$WORK/stop.err"; then
  check "BC26 a held deferred-review claim never waits for the background reviewer" PASS
else
  check "BC26 a held deferred-review claim never waits for the background reviewer" FAIL
fi
rm -f "$CLAIM_FILE"
rm -rf "$RECORDS"
printf 'not a directory\n' > "$RECORDS"
STOP_OUT="$(stop_hook)"
STOP_REASON="$(printf '%s' "$STOP_OUT" | reason_of)"
if [ "$(printf '%s' "$STOP_OUT" | decision_of)" = "block" ] \
  && contains "$STOP_REASON" "Resume the /zensu:tdd Phase 6 review sequence" \
  && ! contains "$STOP_REASON" "--review-consume --ticket" \
  && ! grep -qF "releasing this Stop while the background" "$WORK/stop.err"; then
  check "BC27 unreadable background review records leave the Stop guard's routing unchanged" PASS
else
  check "BC27 unreadable background review records leave the Stop guard's routing unchanged (reason='$STOP_REASON')" FAIL
fi
rm -f "$RECORDS"

echo "== A consumed ticket whose directive cannot be printed is not reported as success =="
post_review async_launched "$A3" "$T3" >/dev/null
subagent_stop "$A3" zensu:code-reviewer >/dev/null
model_log --review-consume --ticket "$T3" 1</dev/null 2>"$WORK/unprinted.err"
RC=$?
if [ "$RC" -eq 6 ] && grep -qF "was consumed, but no routing directive could be printed" "$WORK/unprinted.err" \
  && grep -qF -- "--chain-status" "$WORK/unprinted.err" \
  && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ]; then
  check "BC28 a claim whose directive cannot be printed exits 6 instead of reporting success" PASS
else
  check "BC28 a claim whose directive cannot be printed exits 6 instead of reporting success (rc=$RC err='$(cat "$WORK/unprinted.err")')" FAIL
fi

echo "----"
echo "test-review-consume-background: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
