#!/bin/bash
# The inner review chain routes first; the outer run releases only at a terminal.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
source "$LIB"
review_marker() {
  local operation_key="$1" head_sha="$2" payload_digest="$3"
  OPERATION_KEY="$operation_key" HEAD_SHA="$head_sha" PAYLOAD_DIGEST="$payload_digest" node -e '
    const crypto=require("crypto");
    const op=crypto.createHash("sha256").update(process.env.OPERATION_KEY).digest("hex");
    process.stdout.write(`<!-- zensu-review:v1:${op}:${process.env.PAYLOAD_DIGEST}:${process.env.HEAD_SHA.toLowerCase()}:1:part=1/1 -->`);
  '
}
TMP="$(mktemp -d -t zensu-autopilot-stop-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

activate_session() {
  local project="$1" raw_session="$2" project_root session_key
  project_root="$(cd "$project" && pwd -P)" || return 1
  session_key="$(node "$CORE" session-key "$raw_session")" || return 1
  export CLAUDE_PROJECT_DIR="$project"
  if [ "${ZENSU_PROJECT_ROOT:-}" = "$project_root" ] \
      && [ "${ZENSU_SESSION_KEY:-}" = "$session_key" ] \
      && [ "${ZENSU_CLAUDE_PLUGIN_ROOT:-}" = "$PLUGIN_DIR" ] \
      && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] \
      && [ "$(node "$CORE" session-key "$CLAUDE_CODE_SESSION_ID" 2>/dev/null)" = "$session_key" ] \
      && [ -f "${ZENSU_SESSION_CONTEXT:-}" ]; then
    return 0
  fi
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session"
}
start() {
  mkdir -p "$1"
  activate_session "$1" "$3" || return 1
  autopilot_begin_run "$2" "$ZENSU_SESSION_KEY" "$1" >/dev/null
}
invoke() {
  local project="$1" sid="$2" cfg="${3:-$TMP/missing.json}" chain="${4:-}" autopilot="${5:-}"
  activate_session "$project" "$sid" || return 1
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$sid" | CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" \
    ZENSU_CHAIN="$chain" ZENSU_AUTOPILOT="$autopilot" bash "$STOP" 2>/dev/null
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).decision||"allow")}catch(_){console.log("allow")}})'; }
context() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).reason||"")}catch(_){process.exit(1)}})'; }
field_ok() { FILE="$1" EXPR="$2" node -e 'const j=require(process.env.FILE);process.exit(Function("j",`return Boolean(${process.env.EXPR})`)(j)?0:1)' 2>/dev/null; }
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"; }

copy_runtime() {
  local destination="$1" runtime_entry
  mkdir -p "$destination"
  destination="$(cd "$destination" && pwd -P)" || return 1
  for runtime_entry in .claude-plugin .mcp.json hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
    cp -R "$PLUGIN_DIR/$runtime_entry" "$destination/$runtime_entry" || return 1
  done
  mkdir -p "$destination/mcp-runtime"
  cp "$PLUGIN_DIR/mcp-runtime/package.json" "$PLUGIN_DIR/mcp-runtime/package-lock.json" \
    "$destination/mcp-runtime/" || return 1
}

bind_runtime_session() {
  local plugin_root="$1" project="$2" raw_session="$3" label="$4"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/$label-plugin-data"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session" "$plugin_root"
  unset ZENSU_TEST_PLUGIN_DATA
}

P1="$TMP/planning"; start "$P1" stop_run_01 stop_session_01
OUT1="$(invoke "$P1" stop_session_01)"
if [ "$(printf '%s' "$OUT1" | decision)" = block ] && printf '%s' "$OUT1" | grep -qF 'nextActionCode=AWAIT_PLAN_APPROVAL'; then
  check "S1 non-terminal outer stage blocks Stop with its closed next action" PASS
else check "S1 non-terminal outer stage blocks Stop" FAIL; fi

P1H="$TMP/head-prerequisite"; start "$P1H" stop_run_head stop_session_head
HEAD_SESSION_KEY="$ZENSU_SESSION_KEY"
HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_READY=true
head_event() {
  autopilot_apply_event stop_run_head "$1" "$2" "$3" "$P1H" >/dev/null 2>&1 || HEAD_READY=false
}
head_event stop-head-plan PLAN_APPROVED '{"approvedPlanSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
head_event stop-head-tdd-start-1 TDD_STARTED "{\"attempt\":1,\"chainId\":\"stop-head-chain-01\",\"sessionId\":\"$HEAD_SESSION_KEY\"}"
head_event stop-head-tdd-done-1 TDD_CHAIN_DONE "{\"attempt\":1,\"chainId\":\"stop-head-chain-01\",\"sessionId\":\"$HEAD_SESSION_KEY\",\"outcome\":\"pass\"}"
head_event stop-head-gates GATES_PASSED "{\"headSha\":\"$HEAD_SHA\"}"
head_event stop-head-converge CONVERGENCE_PASSED '{}'
head_event stop-head-pr-request PR_OPEN_REQUESTED '{"operationKey":"pr:stop-head"}'
head_event stop-head-pr-open PR_OPENED "{\"operationKey\":\"pr:stop-head\",\"pr\":{\"number\":714,\"url\":\"https://github.com/acme/repo/pull/714\",\"headSha\":\"$HEAD_SHA\"}}"
HEAD_REVIEW_KEY="$(autopilot_team_review_operation_key stop_run_head "$HEAD_SHA")"
head_event stop-head-review-request TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$HEAD_REVIEW_KEY\",\"provider\":\"github\"}"
HEAD_REVIEW_PAYLOAD="$TMP/stop-head-review-payload.json"
printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Stop fixture review\",\"commit_id\":\"$HEAD_SHA\",\"comments\":[]}" > "$HEAD_REVIEW_PAYLOAD"
HEAD_REVIEW_SNAPSHOT="$(autopilot_store_team_review_payload stop_run_head "$HEAD_REVIEW_KEY" \
  "$HEAD_SHA" "$HEAD_REVIEW_PAYLOAD" github "$P1H" 2>/dev/null || true)"
[ -n "$HEAD_REVIEW_SNAPSHOT" ] || HEAD_READY=false
HEAD_REVIEW_DIGEST="$(_autopilot_team_review_payload_inspect \
  "$HEAD_REVIEW_SNAPSHOT" "$HEAD_SHA" true canonical 2>/dev/null || true)"
HEAD_REVIEW_MARKER="$(review_marker "$HEAD_REVIEW_KEY" "$HEAD_SHA" "$HEAD_REVIEW_DIGEST")"
head_event stop-head-review-published TEAM_REVIEW_PUBLISHED "{\"operationKey\":\"$HEAD_REVIEW_KEY\",\"marker\":\"$HEAD_REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}"
head_event stop-head-fix-required FIX_REQUIRED "{\"headSha\":\"$HEAD_SHA\",\"unresolvedCount\":1}"
head_event stop-head-tdd-start-2 TDD_STARTED "{\"attempt\":2,\"chainId\":\"stop-head-chain-02\",\"sessionId\":\"$HEAD_SESSION_KEY\"}"
head_event stop-head-tdd-done-2 TDD_CHAIN_DONE "{\"attempt\":2,\"chainId\":\"stop-head-chain-02\",\"sessionId\":\"$HEAD_SESSION_KEY\",\"outcome\":\"pass\"}"
OUT1H="$(invoke "$P1H" stop_session_head)"
if [ "$HEAD_READY" = true ] \
  && [ "$(printf '%s' "$OUT1H" | decision)" = block ] \
  && printf '%s' "$OUT1H" | grep -qF 'prerequisiteActionCode=UPDATE_PR_HEAD; nextActionCode=FIX_REVIEW_FINDINGS' \
  && printf '%s' "$OUT1H" | grep -qF 'FIRST execute prerequisite action UPDATE_PR_HEAD' \
  && printf '%s' "$OUT1H" | grep -qF 'Only after that succeeds continue the static stage action FIX_REVIEW_FINDINGS'; then
  check "S1b head-update prerequisite precedes the static outer action" PASS
else check "S1b head-update prerequisite is explicit and ordered" FAIL; fi

CFG_INNER_OFF="$TMP/inner-off.json"; printf '%s\n' '{"hooks":{"chainEnforcer":false}}' > "$CFG_INNER_OFF"
OUT2="$(invoke "$P1" stop_session_01 "$CFG_INNER_OFF")"
[ "$(printf '%s' "$OUT2" | decision)" = block ] \
  && check "S2 chainEnforcer=false disables only the inner chain" PASS \
  || check "S2 chainEnforcer=false disables only the inner chain" FAIL
OUT3="$(invoke "$P1" stop_session_01 "$TMP/missing.json" off)"
[ "$(printf '%s' "$OUT3" | decision)" = block ] \
  && check "S3 ZENSU_CHAIN=off cannot bypass the outer run" PASS \
  || check "S3 ZENSU_CHAIN=off cannot bypass the outer run" FAIL

P2="$TMP/escape-env"; start "$P2" stop_run_escape_env stop_session_escape_env
OUT4="$(invoke "$P2" stop_session_escape_env "$TMP/missing.json" '' off)"
RF2="$(autopilot_run_file stop_run_escape_env "$P2")"
if [ -z "$OUT4" ] && field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="ZENSU_AUTOPILOT_OFF"&&j.events.some(e=>e.eventType==="BLOCK")&&!j.events.some(e=>e.eventType==="DELIVERY_COMPLETE")'; then
  check "S4 env escape is audited as BLOCKED and never DONE" PASS
else check "S4 env escape is audited as BLOCKED and never DONE" FAIL; fi
autopilot_apply_event stop_run_escape_env resume-escape-env RESUME '{}' "$P2" >/dev/null
OUT4B="$(invoke "$P2" stop_session_escape_env "$TMP/missing.json" '' off)"
if [ -z "$OUT4B" ] \
  && field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="ZENSU_AUTOPILOT_OFF"&&j.events.filter(e=>e.eventType==="BLOCK").length===2&&new Set(j.events.filter(e=>e.eventType==="BLOCK").map(e=>e.eventId)).size===2'; then
  check "S4b repeated escape after RESUME records a fresh BLOCK generation" PASS
else check "S4b repeated escape cannot reuse a stale idempotency event" FAIL; fi

P3="$TMP/escape-config"; start "$P3" stop_run_escape_cfg stop_session_escape_cfg
CFG_OUTER_OFF="$TMP/outer-off.json"; printf '%s\n' '{"hooks":{"autopilotEnforcer":false}}' > "$CFG_OUTER_OFF"
OUT5="$(invoke "$P3" stop_session_escape_cfg "$CFG_OUTER_OFF")"
RF3="$(autopilot_run_file stop_run_escape_cfg "$P3")"
if [ -z "$OUT5" ] && field_ok "$RF3" 'j.stage==="BLOCKED"&&j.blocked.code==="AUTOPILOT_ENFORCER_DISABLED"'; then
  check "S5 config escape is audited as BLOCKED" PASS
else check "S5 config escape is audited as BLOCKED" FAIL; fi

P4="$TMP/cancel"; start "$P4" stop_run_cancel stop_session_cancel
autopilot_apply_event stop_run_cancel cancel-stop CANCEL '{}' "$P4" >/dev/null
OUT6="$(invoke "$P4" stop_session_cancel)"
[ -z "$OUT6" ] && check "S6 CANCELLED is terminal and permits Stop" PASS || check "S6 CANCELLED permits Stop" FAIL
rm -f "$(autopilot_active_file "$P4")"
OUT6B="$(invoke "$P4" stop_session_cancel)"
[ -z "$OUT6B" ] \
  && check "S6b terminal history without a pointer remains compatible with Stop" PASS \
  || check "S6b terminal-only history is treated as absent" FAIL

P5="$TMP/owner"; start "$P5" stop_run_owner stop_session_owner
RF5="$(autopilot_run_file stop_run_owner "$P5")"; BEFORE5="$(digest "$RF5")"
OUT7="$(invoke "$P5" foreign_session)"; AFTER5="$(digest "$RF5")"
if [ "$(printf '%s' "$OUT7" | decision)" = block ] && [ "$BEFORE5" = "$AFTER5" ]; then
  check "S7 foreign session blocks without mutating owner state" PASS
else check "S7 foreign session blocks without mutation" FAIL; fi

P5T="$TMP/owner-terminal"; start "$P5T" stop_run_owner_terminal stop_session_owner_terminal
autopilot_apply_event stop_run_owner_terminal cancel-owner-terminal CANCEL '{}' "$P5T" >/dev/null
OUT7T="$(invoke "$P5T" foreign_terminal_session)"
[ -z "$OUT7T" ] \
  && check "S7b foreign-session terminal permits Stop before owner mismatch" PASS \
  || check "S7b foreign-session terminal permits Stop" FAIL
OUT7TE="$(invoke "$P5T" foreign_terminal_session "$TMP/missing.json" '' off)"
[ -z "$OUT7TE" ] \
  && check "S7c foreign-session terminal also permits the explicit escape path" PASS \
  || check "S7c foreign terminal escape permits Stop" FAIL

P6="$TMP/corrupt"; start "$P6" stop_run_corrupt stop_session_corrupt
AF6="$(autopilot_active_file "$P6")"
AF6="$AF6" node -e 'const fs=require("fs"),p=process.env.AF6,j=JSON.parse(fs.readFileSync(p));j.extra=true;fs.writeFileSync(p,JSON.stringify(j))'
OUT8="$(invoke "$P6" stop_session_corrupt)"
if [ "$(printf '%s' "$OUT8" | decision)" = block ] && printf '%s' "$OUT8" | grep -qi 'corrupt'; then
  check "S8 corrupt active pointer fails closed" PASS
else check "S8 corrupt active pointer fails closed" FAIL; fi

P6B="$TMP/dangling"; start "$P6B" stop_run_dangling stop_session_dangling
rm -f "$(autopilot_run_file stop_run_dangling "$P6B")"
OUT8B="$(invoke "$P6B" stop_session_dangling)"
if [ "$(printf '%s' "$OUT8B" | decision)" = block ] && printf '%s' "$OUT8B" | grep -qi 'corrupt'; then
  check "S8b dangling active pointer fails closed instead of looking absent" PASS
else check "S8b dangling active pointer fails closed" FAIL; fi

P6D="$TMP/orphan-no-pointer"; start "$P6D" stop_run_orphan stop_session_orphan
rm -f "$(autopilot_active_file "$P6D")"
OUT8D="$(invoke "$P6D" stop_session_orphan)"
if [ "$(printf '%s' "$OUT8D" | decision)" = block ] && printf '%s' "$OUT8D" | grep -qi 'corrupt'; then
  check "S8d nonterminal run without a pointer blocks Stop" PASS
else check "S8d orphan nonterminal run cannot look absent" FAIL; fi

# Model the exact adoption race: the initial locked read reports absent, the
# adoption lease stays contended, and its descriptor-backed fallback proves a
# nonterminal run is active. That proof must block this Stop directly; a second
# contended read must never turn the active generation back into "absent".
P6G="$TMP/adoption-active-contention"; start "$P6G" stop_run_contention stop_session_contention
RF6G="$(autopilot_run_file stop_run_contention "$P6G")"
BEFORE8G="$(digest "$RF6G")"
CONTENTION_PLUGIN="$TMP/adoption-contention-plugin"; copy_runtime "$CONTENTION_PLUGIN"
CONTENTION_PLUGIN="$(cd "$CONTENTION_PLUGIN" && pwd -P)"
CONTENTION_STATE_LIB="$CONTENTION_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'autopilot_read_active() { printf '\''read\n'\'' >> "$ZENSU_CONTENTION_READ_MARKER"; return 1; }' \
  '_autopilot_locked_run() { printf '\''lock\n'\'' >> "$ZENSU_CONTENTION_LOCK_MARKER"; return 1; }' \
  > "$CONTENTION_STATE_LIB"
bind_runtime_session "$CONTENTION_PLUGIN" "$P6G" stop_session_contention adoption-contention
OUT8G="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_contention"}' \
  | CLAUDE_PROJECT_DIR="$P6G" CLAUDE_PLUGIN_ROOT="$CONTENTION_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" \
    ZENSU_CONTENTION_READ_MARKER="$TMP/adoption-contention-read" \
    ZENSU_CONTENTION_LOCK_MARKER="$TMP/adoption-contention-lock" \
    bash "$CONTENTION_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
AFTER8G="$(digest "$RF6G")"
if [ "$(printf '%s' "$OUT8G" | decision)" = block ] \
  && printf '%s' "$OUT8G" | grep -qF 'became active while deferred review adoption was waiting for the Outer lock' \
  && [ -s "$TMP/adoption-contention-read" ] \
  && [ -s "$TMP/adoption-contention-lock" ] \
  && [ "$BEFORE8G" = "$AFTER8G" ]; then
  check "S8g active Outer proof cannot degrade to absent after adoption contention" PASS
else check "S8g adoption contention must fail closed on the proven active Outer" FAIL; fi

P6E="$TMP/hidden-orphan"; start "$P6E" stop_run_old_terminal stop_session_old_terminal
autopilot_apply_event stop_run_old_terminal cancel-old-terminal CANCEL '{}' "$P6E" >/dev/null
OLD_POINTER8E="$TMP/old-terminal-pointer.json"
cp "$(autopilot_active_file "$P6E")" "$OLD_POINTER8E"
start "$P6E" stop_run_hidden stop_session_hidden
cp "$OLD_POINTER8E" "$(autopilot_active_file "$P6E")"
OUT8E="$(invoke "$P6E" stop_session_hidden)"
if [ "$(printf '%s' "$OUT8E" | decision)" = block ] && printf '%s' "$OUT8E" | grep -qi 'corrupt'; then
  check "S8e terminal pointer cannot hide a newer nonterminal run from Stop" PASS
else check "S8e hidden nonterminal run cannot inherit terminal release" FAIL; fi

P6F="$TMP/orphan-blocked"; start "$P6F" stop_run_orphan_blocked stop_session_orphan_blocked
autopilot_apply_event stop_run_orphan_blocked block-orphan-fixture BLOCK \
  '{"code":"MANUAL_ORPHAN_BLOCK"}' "$P6F" >/dev/null
rm -f "$(autopilot_active_file "$P6F")"
OUT8F="$(invoke "$P6F" stop_session_orphan_blocked)"
if [ "$(printf '%s' "$OUT8F" | decision)" = block ] && printf '%s' "$OUT8F" | grep -qi 'corrupt'; then
  check "S8f orphan BLOCKED run remains nonterminal for inventory safety" PASS
else check "S8f orphan BLOCKED run cannot look terminal or absent" FAIL; fi

P6C="$TMP/corrupt-inner-cap"; start "$P6C" stop_run_corrupt_cap stop_session_corrupt_cap
autopilot_apply_event stop_run_corrupt_cap plan-corrupt-cap PLAN_APPROVED \
  '{"approvedPlanSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' "$P6C" >/dev/null
CLAUDE_PROJECT_DIR="$P6C" bash "$LOG" --tdd-begin --session stop_session_corrupt_cap \
  --autopilot-run stop_run_corrupt_cap --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-corrupt-cap-001 >/dev/null
CLAUDE_PROJECT_DIR="$P6C" bash "$LOG" --tdd-complete --session stop_session_corrupt_cap \
  --autopilot-run stop_run_corrupt_cap --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-corrupt-cap-001 >/dev/null
AF6C="$(autopilot_active_file "$P6C")"
AF6C="$AF6C" node -e 'const fs=require("fs"),p=process.env.AF6C,j=JSON.parse(fs.readFileSync(p));j.extra=true;fs.writeFileSync(p,JSON.stringify(j))'
CAP_CORRUPT_BLOCKS=true
for _ in 1 2 3 4 5 6 7 8 9; do
  current="$(invoke "$P6C" stop_session_corrupt_cap)"
  [ "$(printf '%s' "$current" | decision)" = block ] || CAP_CORRUPT_BLOCKS=false
done
if [ "$CAP_CORRUPT_BLOCKS" = true ] && printf '%s' "$current" | grep -qi 'corrupt'; then
  check "S8c corrupt outer remains fail-closed after the inner Stop budget is exhausted" PASS
else check "S8c inner cap cannot bypass corrupt outer state" FAIL; fi

P6P="$TMP/bound-permission-hint"; start "$P6P" stop_run_perm_hint stop_session_perm_hint
autopilot_apply_event stop_run_perm_hint plan-perm-hint PLAN_APPROVED \
  '{"approvedPlanSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' "$P6P" >/dev/null
CLAUDE_PROJECT_DIR="$P6P" bash "$LOG" --tdd-begin --session stop_session_perm_hint \
  --autopilot-run stop_run_perm_hint --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-perm-hint-001 >/dev/null
CLAUDE_PROJECT_DIR="$P6P" bash "$LOG" --tdd-complete --session stop_session_perm_hint \
  --autopilot-run stop_run_perm_hint --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-perm-hint-001 >/dev/null
PERM_FIRST="$(invoke "$P6P" stop_session_perm_hint)"
PERM_SECOND="$(invoke "$P6P" stop_session_perm_hint)"
if printf '%s' "$PERM_FIRST" | grep -qF 'NOT a second exception'; then
  check "S8p the FIRST bound nudge stays free of the permission-refusal paragraph" FAIL
else check "S8p the FIRST bound nudge stays free of the permission-refusal paragraph" PASS; fi
if printf '%s' "$PERM_SECOND" | grep -qF 'REFUSED by the permission layer' \
  && printf '%s' "$PERM_SECOND" | grep -qF 'outcome no-changes' \
  && printf '%s' "$PERM_SECOND" | grep -qF 'AUTOPILOT-BINDING: run=stop_run_perm_hint'; then
  check "S8q the SECOND bound nudge carries the refusal paragraph alongside the Autopilot envelope and its bound terminus" PASS
else check "S8q bound nudge refusal paragraph + envelope (got: $PERM_SECOND)" FAIL; fi

P7="$TMP/priority"; start "$P7" stop_run_priority stop_session_priority
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
autopilot_apply_event stop_run_priority plan-priority PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7" >/dev/null
CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-begin --session stop_session_priority --autopilot-run stop_run_priority --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-priority-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-complete --session stop_session_priority \
  --autopilot-run stop_run_priority --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-priority-001 >/dev/null
OUT9="$(invoke "$P7" stop_session_priority)"
CTX9="$(printf '%s' "$OUT9" | context)"
if [ "$(printf '%s' "$OUT9" | decision)" = block ] \
  && printf '%s' "$OUT9" | grep -qF 'zensu:code-reviewer' \
  && printf '%s' "$OUT9" | grep -qF -- '--outcome no-changes' \
  && [ "$(printf '%s\n' "$CTX9" | grep -cFx 'ZENSU-DELEGATED-CALLER: autopilot')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9" | grep -cFx 'AUTOPILOT-BINDING: run=stop_run_priority attempt=1 chain=chain-priority-001')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9" | grep -cFx 'AUTOPILOT-STAGE: GATES')" -eq 1 ] \
  && ! printf '%s' "$OUT9" | grep -qF 'nextActionCode=AWAIT_TDD_CHAIN'; then
  check "S9 inner review routing has priority over outer-stage routing" PASS
else check "S9 inner review routing has priority" FAIL; fi

# Complete the matching reviewer ticket in the narrow window after the bound
# budget CAS but before the fresh prompt snapshot. Stop must route from that
# fresh codeReviewDone value, never from its initial snapshot.
P7F="$TMP/fresh-review-routing"; start "$P7F" stop_run_fresh stop_session_fresh
autopilot_apply_event stop_run_fresh plan-fresh PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7F" >/dev/null
CLAUDE_PROJECT_DIR="$P7F" bash "$LOG" --tdd-begin --session stop_session_fresh \
  --autopilot-run stop_run_fresh --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-fresh-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7F" bash "$LOG" --tdd-complete --session stop_session_fresh \
  --autopilot-run stop_run_fresh --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-fresh-001 >/dev/null
TICKET9F="$(CLAUDE_PROJECT_DIR="$P7F" bash "$LOG" --review-ticket --session stop_session_fresh)"
CLAUDE_PROJECT_DIR="$P7F" tdd_consume_review_ticket "$ZENSU_SESSION_KEY" "$TICKET9F" >/dev/null
FRESH_PLUGIN="$TMP/fresh-prompt-plugin"; mkdir -p "$FRESH_PLUGIN"
FRESH_PLUGIN="$(cd "$FRESH_PLUGIN" && pwd -P)"
for runtime_entry in .claude-plugin .mcp.json hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
  cp -R "$PLUGIN_DIR/$runtime_entry" "$FRESH_PLUGIN/$runtime_entry"
done
mkdir -p "$FRESH_PLUGIN/mcp-runtime"
cp "$PLUGIN_DIR/mcp-runtime/package.json" "$PLUGIN_DIR/mcp-runtime/package-lock.json" \
  "$FRESH_PLUGIN/mcp-runtime/"
FRESH_STATE_LIB="$FRESH_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_increment_inner_stop_budget_capped | sed '\''1s/autopilot_increment_inner_stop_budget_capped/_autopilot_increment_inner_stop_budget_capped_real/'\'')"' \
  'autopilot_increment_inner_stop_budget_capped() {' \
  '  local result rc' \
  '  result="$(_autopilot_increment_inner_stop_budget_capped_real "$@")"; rc=$?' \
  '  [ "$rc" -eq 0 ] || return "$rc"' \
  '  CLAUDE_PROJECT_DIR="$7" tdd_mark_review_converged "$8" "$ZENSU_FRESH_REVIEW_TICKET" codeReviewDone || return 5' \
  '  printf '\''%s\n'\'' "$result"' \
  '}' > "$FRESH_STATE_LIB"
ZENSU_TEST_PLUGIN_DATA="$TMP/fresh-prompt-plugin-data"
export ZENSU_TEST_PLUGIN_DATA
# The instrumented runtime is a distinct installation. Bootstrap its own
# authenticated session context so the handoff acknowledgement exercises the
# real plugin-root boundary instead of relying on the original fixture's root.
# shellcheck disable=SC1090
source "$BASELINE" stop_session_fresh "$FRESH_PLUGIN"
unset ZENSU_TEST_PLUGIN_DATA
OUT9F="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_fresh"}' \
  | CLAUDE_PROJECT_DIR="$P7F" CLAUDE_PLUGIN_ROOT="$FRESH_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_FRESH_REVIEW_TICKET="$TICKET9F" \
    bash "$FRESH_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
CTX9F="$(printf '%s' "$OUT9F" | context)"
if [ "$(printf '%s' "$OUT9F" | decision)" = block ] \
  && printf '%s' "$OUT9F" | grep -qF "skill='zensu:self-review'" \
  && [ "$(printf '%s\n' "$CTX9F" | grep -cFx 'ZENSU-DELEGATED-CALLER: autopilot')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9F" | grep -cFx 'AUTOPILOT-BINDING: run=stop_run_fresh attempt=1 chain=chain-fresh-001')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9F" | grep -cFx 'AUTOPILOT-STAGE: GATES')" -eq 1 ] \
  && ! printf '%s' "$OUT9F" | grep -qF "subagent_type='zensu:code-reviewer'"; then
  check "S9a fresh codeReviewDone routes self-review after the budget CAS" PASS
else check "S9a fresh prompt snapshot owns reviewer vs self-review routing" FAIL; fi

# Capture attempt 1 in Stop, then deterministically advance both Outer and Inner
# to attempt 2 during the first Outer read. The stale Stop invocation must lose
# its generation CAS before touching either attempt-2's inner Stop budget or the
# current Outer budget, and must fail closed from the changed generation.
P7G="$TMP/stale-inner-budget-generation"; start "$P7G" stop_run_generation stop_session_generation
autopilot_apply_event stop_run_generation plan-generation PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7G" >/dev/null
CLAUDE_PROJECT_DIR="$P7G" bash "$LOG" --tdd-begin --session stop_session_generation \
  --autopilot-run stop_run_generation --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-generation-stop-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7G" bash "$LOG" --tdd-complete --session stop_session_generation \
  --autopilot-run stop_run_generation --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-generation-stop-001 >/dev/null
TF7G="$(tdd_state_file stop_session_generation)"
RF7G="$(autopilot_run_file stop_run_generation "$P7G")"
INITIAL7G=false
field_ok "$TF7G" \
  'j.autopilotAttempt===1&&j.chainId==="chain-generation-stop-001"&&j.implComplete===true&&j.stopBlockCount===0' \
  && INITIAL7G=true
GENERATION_PLUGIN="$TMP/stale-inner-budget-plugin"; copy_runtime "$GENERATION_PLUGIN"
GENERATION_PLUGIN="$(cd "$GENERATION_PLUGIN" && pwd -P)"
GENERATION_STATE_LIB="$GENERATION_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_read_active | sed '\''1s/autopilot_read_active/_autopilot_read_active_real/'\'')"' \
  'autopilot_read_active() {' \
  '  local root="${1:-${CLAUDE_PROJECT_DIR:-.}}"' \
  '  if [ ! -e "$ZENSU_GENERATION_RACE_MARKER" ]; then' \
  '    : > "$ZENSU_GENERATION_RACE_MARKER"' \
  '    CLAUDE_PROJECT_DIR="$root" autopilot_finish_tdd_attempt "$ZENSU_GENERATION_RUN" generation-stop-done-1 "$root" "$ZENSU_GENERATION_SID" 1 "$ZENSU_GENERATION_CHAIN_1" no-changes false >/dev/null || return 5' \
  '    autopilot_apply_event "$ZENSU_GENERATION_RUN" generation-gates-failed GATES_FAILED '\''{"headSha":"dddddddddddddddddddddddddddddddddddddddd","reason":"deterministic Stop generation race"}'\'' "$root" "$ZENSU_GENERATION_SID" >/dev/null || return 5' \
  '    CLAUDE_PROJECT_DIR="$root" autopilot_begin_tdd_attempt "$ZENSU_GENERATION_RUN" generation-stop-start-2 "$root" "$ZENSU_GENERATION_SID" false 2 GATES "$ZENSU_GENERATION_CHAIN_2" >/dev/null || return 5' \
  '    CLAUDE_PROJECT_DIR="$root" tdd_mark_impl_complete_bound "$ZENSU_GENERATION_SID" "$ZENSU_GENERATION_RUN" 2 "$ZENSU_GENERATION_CHAIN_2" >/dev/null || return 5' \
  '  fi' \
  '  _autopilot_read_active_real "$@"' \
  '}' > "$GENERATION_STATE_LIB"
bind_runtime_session "$GENERATION_PLUGIN" "$P7G" stop_session_generation generation-race
OUT9G="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_generation"}' \
  | CLAUDE_PROJECT_DIR="$P7G" CLAUDE_PLUGIN_ROOT="$GENERATION_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_GENERATION_RACE_MARKER="$TMP/generation-race-fired" \
    ZENSU_GENERATION_RUN=stop_run_generation ZENSU_GENERATION_SID="$ZENSU_SESSION_KEY" \
    ZENSU_GENERATION_CHAIN_1=chain-generation-stop-001 \
    ZENSU_GENERATION_CHAIN_2=chain-generation-stop-002 \
    bash "$GENERATION_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$INITIAL7G" = true ] && [ -e "$TMP/generation-race-fired" ] \
  && [ "$(printf '%s' "$OUT9G" | decision)" = block ] \
  && printf '%s' "$OUT9G" | grep -qF 'generation changed' \
  && field_ok "$TF7G" \
    'j.autopilotAttempt===2&&j.chainId==="chain-generation-stop-002"&&j.implComplete===true&&j.chainDone===false&&j.stopBlockCount===0' \
  && field_ok "$RF7G" \
    'j.stage==="TDD_RUNNING"&&j.tdd.attempt===2&&j.tdd.chainId==="chain-generation-stop-002"&&j.stopBudget.count===0'; then
  check "S9f stale attempt-1 Stop cannot charge attempt 2 before fresh routing" PASS
else check "S9f stale attempt-1 Stop leaves attempt-2 Inner and Outer budgets untouched" FAIL; fi

P7T="$TMP/bound-terminal"; start "$P7T" stop_run_bound stop_session_bound
autopilot_apply_event stop_run_bound plan-bound PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7T" >/dev/null
CLAUDE_PROJECT_DIR="$P7T" bash "$LOG" --tdd-begin --session stop_session_bound --autopilot-run stop_run_bound --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-bound-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7T" bash "$LOG" --tdd-complete --session stop_session_bound \
  --autopilot-run stop_run_bound --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-bound-001 >/dev/null
autopilot_apply_event stop_run_bound block-bound BLOCK '{"code":"MANUAL_BLOCK"}' "$P7T" >/dev/null
OUT9T="$(invoke "$P7T" stop_session_bound)"
[ -z "$OUT9T" ] \
  && check "S9b terminal outer run wins over its same-bound unfinished inner chain" PASS \
  || check "S9b same-bound terminal permits Stop" FAIL

# Return a cached R1/CANCELLED snapshot from the first Outer read, but publish a
# new R2/PLANNING pointer before Stop evaluates that terminal snapshot. Stop may
# release only after revalidating the current pointer; stale R1 must not permit
# the turn while R2 is active.
P7U="$TMP/stale-terminal-release"; start "$P7U" stop_run_terminal_old stop_session_terminal_race
autopilot_apply_event stop_run_terminal_old plan-terminal-old PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7U" >/dev/null
CLAUDE_PROJECT_DIR="$P7U" bash "$LOG" --tdd-begin --session stop_session_terminal_race \
  --autopilot-run stop_run_terminal_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-terminal-old-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7U" bash "$LOG" --tdd-complete --session stop_session_terminal_race \
  --autopilot-run stop_run_terminal_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-terminal-old-001 >/dev/null
autopilot_apply_event stop_run_terminal_old cancel-terminal-old CANCEL '{}' "$P7U" >/dev/null
TERMINAL_PLUGIN="$TMP/stale-terminal-plugin"; copy_runtime "$TERMINAL_PLUGIN"
TERMINAL_PLUGIN="$(cd "$TERMINAL_PLUGIN" && pwd -P)"
TERMINAL_STATE_LIB="$TERMINAL_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_read_active | sed '\''1s/autopilot_read_active/_autopilot_read_active_real/'\'')"' \
  'autopilot_read_active() {' \
  '  local cached rc root="${1:-${CLAUDE_PROJECT_DIR:-.}}"' \
  '  cached="$(_autopilot_read_active_real "$@")"; rc=$?' \
  '  [ "$rc" -eq 0 ] || return "$rc"' \
  '  if [ ! -e "$ZENSU_TERMINAL_RACE_MARKER" ]; then' \
  '    : > "$ZENSU_TERMINAL_RACE_MARKER"' \
  '    autopilot_begin_run "$ZENSU_TERMINAL_NEW_RUN" "$ZENSU_TERMINAL_SID" "$root" >/dev/null || return 5' \
  '  fi' \
  '  printf '\''%s\n'\'' "$cached"' \
  '}' > "$TERMINAL_STATE_LIB"
bind_runtime_session "$TERMINAL_PLUGIN" "$P7U" stop_session_terminal_race terminal-race
OUT9U="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_terminal_race"}' \
  | CLAUDE_PROJECT_DIR="$P7U" CLAUDE_PLUGIN_ROOT="$TERMINAL_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_TERMINAL_RACE_MARKER="$TMP/terminal-race-fired" \
    ZENSU_TERMINAL_NEW_RUN=stop_run_terminal_new ZENSU_TERMINAL_SID="$ZENSU_SESSION_KEY" \
    bash "$TERMINAL_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
RF7U_NEW="$(autopilot_run_file stop_run_terminal_new "$P7U")"
if [ -e "$TMP/terminal-race-fired" ] \
  && [ "$(printf '%s' "$OUT9U" | decision)" = block ] \
  && printf '%s' "$OUT9U" | grep -qF 'run stop_run_terminal_new' \
  && printf '%s' "$OUT9U" | grep -qF 'stage=PLANNING; nextActionCode=AWAIT_PLAN_APPROVAL' \
  && field_ok "$RF7U_NEW" 'j.stage==="PLANNING"'; then
  check "S9g stale terminal snapshot cannot release Stop after a new run begins" PASS
else check "S9g terminal release revalidates and blocks the current Outer run" FAIL; fi

# The explicit escape branch must use the same current-pointer proof. Return a
# cached terminal R1 snapshot while publishing R2/PLANNING, then request the
# supported ZENSU_AUTOPILOT=off escape. R2 must receive its own audited BLOCK;
# stale R1 must never make the hook release an unaudited active generation.
P7V="$TMP/stale-terminal-escape"; start "$P7V" stop_run_escape_old stop_session_escape_race
autopilot_apply_event stop_run_escape_old plan-escape-old PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7V" >/dev/null
CLAUDE_PROJECT_DIR="$P7V" bash "$LOG" --tdd-begin --session stop_session_escape_race \
  --autopilot-run stop_run_escape_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-escape-old-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7V" bash "$LOG" --tdd-complete --session stop_session_escape_race \
  --autopilot-run stop_run_escape_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-escape-old-001 >/dev/null
autopilot_apply_event stop_run_escape_old cancel-escape-old CANCEL '{}' "$P7V" >/dev/null
bind_runtime_session "$TERMINAL_PLUGIN" "$P7V" stop_session_escape_race terminal-race
OUT9V="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_escape_race"}' \
  | CLAUDE_PROJECT_DIR="$P7V" CLAUDE_PLUGIN_ROOT="$TERMINAL_PLUGIN" ZENSU_AUTOPILOT=off \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_TERMINAL_RACE_MARKER="$TMP/terminal-escape-race-fired" \
    ZENSU_TERMINAL_NEW_RUN=stop_run_escape_new ZENSU_TERMINAL_SID="$ZENSU_SESSION_KEY" \
    bash "$TERMINAL_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
RF7V_NEW="$(autopilot_run_file stop_run_escape_new "$P7V")"
if [ -e "$TMP/terminal-escape-race-fired" ] && [ -z "$OUT9V" ] \
  && field_ok "$RF7V_NEW" \
    'j.stage==="BLOCKED"&&j.blocked.code==="ZENSU_AUTOPILOT_OFF"&&j.events.some(e=>e.eventType==="BLOCK"&&e.payload.code==="ZENSU_AUTOPILOT_OFF")'; then
  check "S9i stale terminal escape audits the newly active Outer generation" PASS
else check "S9i explicit escape cannot release a new active run from stale terminal state" FAIL; fi

P7S="$TMP/stale-terminal"; start "$P7S" stop_run_stale stop_session_stale
autopilot_apply_event stop_run_stale cancel-stale CANCEL '{}' "$P7S" >/dev/null
activate_session "$P7S" later_standalone || exit 1
CLAUDE_PROJECT_DIR="$P7S" bash "$LOG" --tdd-begin --session later_standalone >/dev/null
CLAUDE_PROJECT_DIR="$P7S" bash "$LOG" --tdd-complete --session later_standalone >/dev/null
OUT9S="$(invoke "$P7S" later_standalone)"
if [ "$(printf '%s' "$OUT9S" | decision)" = block ] && printf '%s' "$OUT9S" | grep -qF 'zensu:code-reviewer'; then
  check "S9c old terminal pointer cannot bypass a later standalone TDD chain" PASS
else check "S9c old terminal does not bypass standalone inner chain" FAIL; fi

CLAUDE_PROJECT_DIR="$P7S" bash "$LOG" --pending-review --files 'src/pending.ts' \
  --summary 'review queued after terminal autopilot' >/dev/null
OUT9SP="$(invoke "$P7S" pending_after_terminal)"
activate_session "$P7S" pending_after_terminal || exit 1
TF9SP="$(tdd_state_file pending_after_terminal)"
if [ "$(printf '%s' "$OUT9SP" | decision)" = block ] \
  && printf '%s' "$OUT9SP" | grep -qF 'zensu:code-reviewer' \
  && field_ok "$TF9SP" 'j.active===true&&j.implComplete===true&&j.chainDone===false'; then
  check "S9c2 terminal pointer does not suppress a later deferred review adoption" PASS
else check "S9c2 terminal pointer preserves deferred review compatibility" FAIL; fi

# CANCELLED relinquishes ownership even when its exact old Inner remains armed
# in the same session. A new pending review must retire that historical binding
# and become the current standalone deferred-review chain; it may not remain
# queued forever behind the stale terminal ownership shortcut. The existing
# S9e assertion below keeps resumable BLOCKED deliberately conservative.
P7P="$TMP/cancelled-pending-same-session"; start "$P7P" stop_run_pending_old stop_session_pending_same
activate_session "$P7P" stop_session_pending_same || exit 1
autopilot_apply_event stop_run_pending_old plan-pending-old PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7P" >/dev/null
CLAUDE_PROJECT_DIR="$P7P" bash "$LOG" --tdd-begin --session stop_session_pending_same \
  --autopilot-run stop_run_pending_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-pending-old-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7P" bash "$LOG" --tdd-complete --session stop_session_pending_same \
  --autopilot-run stop_run_pending_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-pending-old-001 >/dev/null
autopilot_apply_event stop_run_pending_old cancel-pending-old CANCEL '{}' "$P7P" >/dev/null
CLAUDE_PROJECT_DIR="$P7P" bash "$LOG" --pending-review --files 'src/same-session-pending.ts' \
  --summary 'must supersede cancelled exact inner binding' >/dev/null
PF7P="$P7P/.zensu/state/pending-review.json"
OUT9P="$(invoke "$P7P" stop_session_pending_same)"
TF7P="$(tdd_state_file stop_session_pending_same)"
if [ "$(printf '%s' "$OUT9P" | decision)" = block ] \
  && printf '%s' "$OUT9P" | grep -qF 'zensu:code-reviewer' \
  && [ ! -e "$PF7P" ] && [ -f "$PF7P.claim" ] \
  && field_ok "$TF7P" \
    'j.active===true&&j.implComplete===true&&j.chainDone===false&&j.deferredReviewClaim&&!("autopilotRunId" in j)&&!("autopilotAttempt" in j)&&!("chainId" in j)' \
  && field_ok "$(autopilot_run_file stop_run_pending_old "$P7P")" 'j.stage==="CANCELLED"'; then
  check "S9h CANCELLED exact old Inner cannot starve same-session pending adoption" PASS
else check "S9h terminal same-session pending review remains adoptable while BLOCKED stays conservative" FAIL; fi

P7R="$TMP/reconciled-terminal"; start "$P7R" stop_run_reconcile stop_session_reconcile
autopilot_apply_event stop_run_reconcile plan-reconcile PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7R" >/dev/null
CLAUDE_PROJECT_DIR="$P7R" bash "$LOG" --tdd-begin --session stop_session_reconcile --autopilot-run stop_run_reconcile --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-reconcile-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7R" bash "$LOG" --tdd-complete --session stop_session_reconcile \
  --autopilot-run stop_run_reconcile --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-reconcile-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7R" tdd_finish_autopilot_chain "$ZENSU_SESSION_KEY" \
  stop_run_reconcile 1 chain-reconcile-001 max-rounds
OUT9R="$(invoke "$P7R" stop_session_reconcile)"; RF7R="$(autopilot_run_file stop_run_reconcile "$P7R")"
if [ -z "$OUT9R" ] && field_ok "$RF7R" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "S9d crash-window reconciliation re-applies terminal release after BLOCKED" PASS
else check "S9d reconciled terminal permits Stop" FAIL; fi

# BLOCKED is resumable and still owns its exact Inner generation. A deferred
# review marker must remain queued; Stop must never overwrite that binding with
# an unbound seed merely because chainDone already released the hook.
TF7R="$(tdd_state_file stop_session_reconcile)"
BEFORE9RB="$(digest "$TF7R")"
CLAUDE_PROJECT_DIR="$P7R" bash "$LOG" --pending-review --files 'src/blocked-pending.ts' \
  --summary 'must remain queued behind blocked outer' >/dev/null
PENDING9RB="$(CLAUDE_PROJECT_DIR="$P7R" zensu_pending_review_file)"
OUT9RB="$(invoke "$P7R" stop_session_reconcile)"
AFTER9RB="$(digest "$TF7R")"
if [ -z "$OUT9RB" ] && [ "$BEFORE9RB" = "$AFTER9RB" ] && [ -f "$PENDING9RB" ] \
  && field_ok "$TF7R" 'j.autopilotRunId==="stop_run_reconcile"&&j.autopilotAttempt===1&&j.chainId==="chain-reconcile-001"'; then
  check "S9e BLOCKED outer preserves binding and queued deferred review" PASS
else check "S9e BLOCKED outer cannot seed an unbound deferred review" FAIL; fi

# A standalone unfinished Inner can legitimately predate a later Outer in the
# same session. BLOCKED owns only an exact bound Inner generation, so it must
# leave this Outer byte-stable while the unrelated standalone review routes.
P7W="$TMP/blocked-after-standalone"; mkdir -p "$P7W"
S7W=stop_session_blocked_after_standalone
R7W=stop_run_blocked_after_standalone
activate_session "$P7W" "$S7W" || exit 1
CLAUDE_PROJECT_DIR="$P7W" bash "$LOG" --tdd-begin --session "$S7W" >/dev/null
CLAUDE_PROJECT_DIR="$P7W" bash "$LOG" --tdd-complete --session "$S7W" >/dev/null
start "$P7W" "$R7W" "$S7W"
autopilot_apply_event "$R7W" block-after-standalone BLOCK \
  '{"code":"MANUAL_BLOCK"}' "$P7W" >/dev/null
TF7W="$(tdd_state_file "$S7W")"
RF7W="$(autopilot_run_file "$R7W" "$P7W")"
BEFORE9W="$(digest "$RF7W")"
OUT9W="$(invoke "$P7W" "$S7W")"
AFTER9W="$(digest "$RF7W")"
if [ "$(printf '%s' "$OUT9W" | decision)" = block ] \
  && printf '%s' "$OUT9W" | grep -qF 'zensu:code-reviewer' \
  && [ "$BEFORE9W" = "$AFTER9W" ] \
  && field_ok "$TF7W" \
    'j.active===true&&j.implComplete===true&&j.chainDone===false&&j.stopBlockCount===1&&!("autopilotRunId" in j)' \
  && field_ok "$RF7W" \
    'j.stage==="BLOCKED"&&j.blocked.code==="MANUAL_BLOCK"&&j.stopBudget.count===0'; then
  check "S9j BLOCKED outer cannot suppress an unrelated standalone review chain" PASS
else check "S9j unrelated standalone review wins while BLOCKED outer remains byte-stable" FAIL; fi

P8="$TMP/cap"; start "$P8" stop_run_cap stop_session_cap
CAP_BLOCKS=true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  current="$(invoke "$P8" stop_session_cap)"
  [ "$(printf '%s' "$current" | decision)" = block ] || CAP_BLOCKS=false
done
OUT10="$(invoke "$P8" stop_session_cap)"; RF8="$(autopilot_run_file stop_run_cap "$P8")"
if [ "$CAP_BLOCKS" = true ] && [ -z "$OUT10" ] && field_ok "$RF8" 'j.stage==="BLOCKED"&&j.blocked.code==="STOP_BUDGET_EXHAUSTED"'; then
  check "S10 exhausted outer budget moves to audited BLOCKED then permits Stop" PASS
else check "S10 outer budget cap blocks safely" FAIL; fi

# A standalone Inner may predate a later durable Outer in the same session.
# Exhausting only the Inner guard must never release Stop while that Outer is
# still nonterminal; the final decision must pass through outer_finish.
P8C="$TMP/standalone-cap-with-outer"; mkdir -p "$P8C"
S8C=stop_session_standalone_cap; R8C=stop_run_after_standalone
CFG8C="$TMP/standalone-cap-one.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1}}' > "$CFG8C"
activate_session "$P8C" "$S8C" || exit 1
CLAUDE_PROJECT_DIR="$P8C" bash "$LOG" --tdd-begin --session "$S8C" >/dev/null
CLAUDE_PROJECT_DIR="$P8C" bash "$LOG" --tdd-complete --session "$S8C" >/dev/null
start "$P8C" "$R8C" "$S8C"
PRECAP8C=true
for _ in 1 2 3 4; do
  CURRENT8C="$(invoke "$P8C" "$S8C" "$CFG8C")"
  [ "$(printf '%s' "$CURRENT8C" | decision)" = block ] || PRECAP8C=false
done
OUT10C="$(invoke "$P8C" "$S8C" "$CFG8C")"
RF8C="$(autopilot_run_file "$R8C" "$P8C")"
if [ "$PRECAP8C" = true ] \
  && [ "$(printf '%s' "$OUT10C" | decision)" = block ] \
  && printf '%s' "$OUT10C" | grep -qF 'run stop_run_after_standalone' \
  && printf '%s' "$OUT10C" | grep -qF 'stage=PLANNING; nextActionCode=AWAIT_PLAN_APPROVAL' \
  && field_ok "$RF8C" 'j.stage==="PLANNING"&&j.stopBudget.count===1'; then
  check "S10c standalone Inner cap cannot release a later active Outer" PASS
else check "S10c standalone cap must still enforce the durable Outer" FAIL; fi

# Deterministically advance the stage in the narrow window after locked
# reconciliation but before the capped budget CAS. The first capped call
# simulates that concurrent transition and returns the helper's stale rc=4;
# Stop must re-read, route the new action, and increment only that generation.
P8B="$TMP/cap-stale-stage"; start "$P8B" stop_run_cap_stale stop_session_cap_stale
STALE_PLUGIN="$TMP/stale-cap-plugin"; copy_runtime "$STALE_PLUGIN"
STALE_PLUGIN="$(cd "$STALE_PLUGIN" && pwd -P)"
STALE_STATE_LIB="$STALE_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_increment_stop_budget_capped | sed '\''1s/autopilot_increment_stop_budget_capped/_autopilot_increment_stop_budget_capped_real/'\'')"' \
  'autopilot_increment_stop_budget_capped() {' \
  '  if [ ! -e "$ZENSU_STALE_CAP_MARKER" ]; then' \
  '    : > "$ZENSU_STALE_CAP_MARKER"' \
  '    autopilot_apply_event "$1" stale-cap-plan-approved PLAN_APPROVED '\''{"approvedPlanSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'\'' "$3" "$4" >/dev/null 2>&1 || return 5' \
  '    return 4' \
  '  fi' \
  '  _autopilot_increment_stop_budget_capped_real "$@"' \
  '}' > "$STALE_STATE_LIB"
bind_runtime_session "$STALE_PLUGIN" "$P8B" stop_session_cap_stale stale-cap
OUT10B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_cap_stale"}' \
  | CLAUDE_PROJECT_DIR="$P8B" CLAUDE_PLUGIN_ROOT="$STALE_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_STALE_CAP_MARKER="$TMP/stale-cap-fired" \
    bash "$STALE_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
RF8B="$(autopilot_run_file stop_run_cap_stale "$P8B")"
if [ "$(printf '%s' "$OUT10B" | decision)" = block ] \
  && printf '%s' "$OUT10B" | grep -qF 'stage=AWAIT_TDD; nextActionCode=START_TDD' \
  && ! printf '%s' "$OUT10B" | grep -qF 'nextActionCode=AWAIT_PLAN_APPROVAL' \
  && field_ok "$RF8B" 'j.stage==="AWAIT_TDD"&&j.stopBudget.count===1&&j.events.filter(e=>e.eventType==="PLAN_APPROVED").length===1'; then
  check "S10b stale outer-cap CAS re-routes once from the new stage" PASS
else check "S10b stale outer-cap CAS cannot mutate or describe the old stage" FAIL; fi

P9="$TMP/runtime-missing"; start "$P9" stop_run_runtime stop_session_runtime
NO_NODE_PATH="$TMP/no-node-path"; mkdir -p "$NO_NODE_PATH"
ln -s "$(command -v dirname)" "$NO_NODE_PATH/dirname"
OUT11="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_runtime"}' | CLAUDE_PROJECT_DIR="$P9" PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
if [ -z "$OUT11" ]; then
  check "S11 missing Node stays silent before principal/state authentication" PASS
else check "S11 missing Node must not guess a main-thread Stop decision" FAIL; fi
OUT11B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_orphan"}' | CLAUDE_PROJECT_DIR="$P6D" \
  PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
if [ -z "$OUT11B" ]; then
  check "S11b orphan missing-Node path also stays unauthenticated and silent" PASS
else check "S11b orphan missing-Node path must not guess a Stop principal" FAIL; fi

MISSING_LIB_ROOT="$TMP/missing-state-lib"; copy_runtime "$MISSING_LIB_ROOT"
MISSING_LIB_ROOT="$(cd "$MISSING_LIB_ROOT" && pwd -P)"
rm -f "$MISSING_LIB_ROOT/hooks/lib/zensu-autopilot-state.sh"
bind_runtime_session "$MISSING_LIB_ROOT" "$P9" stop_session_runtime missing-state
OUT12="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_runtime"}' | CLAUDE_PROJECT_DIR="$P9" CLAUDE_PLUGIN_ROOT="$MISSING_LIB_ROOT" bash "$MISSING_LIB_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT12" | decision)" = block ] && printf '%s' "$OUT12" | grep -qF 'durable state runtime is unavailable'; then
  check "S12 missing outer-state library with an active pointer fails closed" PASS
else check "S12 missing state library fails closed" FAIL; fi
bind_runtime_session "$MISSING_LIB_ROOT" "$P6D" stop_session_orphan missing-state
OUT12B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_orphan"}' | CLAUDE_PROJECT_DIR="$P6D" \
  CLAUDE_PLUGIN_ROOT="$MISSING_LIB_ROOT" bash "$MISSING_LIB_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT12B" | decision)" = block ] \
  && printf '%s' "$OUT12B" | grep -qF 'durable state runtime is unavailable'; then
  check "S12b missing state library with an orphan run fails closed" PASS
else check "S12b orphan run cannot look absent without the state library" FAIL; fi

OUT13="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_runtime","agent_id":"spawned-no-runtime"}' | CLAUDE_PROJECT_DIR="$P9" PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
[ -z "$OUT13" ] \
  && check "S13 spawned-agent no-op still precedes missing-runtime enforcement" PASS \
  || check "S13 spawned agent remains first no-op" FAIL
OUT13B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_orphan","agent_id":"spawned-orphan-no-runtime"}' \
  | CLAUDE_PROJECT_DIR="$P6D" PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
[ -z "$OUT13B" ] \
  && check "S13b spawned-agent no-op precedes orphan runtime enforcement" PASS \
  || check "S13b orphan hint must not deadlock a spawned agent" FAIL

echo "----"; echo "test-autopilot-stop-enforcer: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
