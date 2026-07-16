#!/bin/bash
# Vanilla implementation mode (hooks.tddImplementation) — hermetic walk (no live
# claude, no API).
#
# Proves the config flag disables ONLY the RED→GREEN edit discipline while the
# rest of the chain stays enforced:
#   lib: the per-session `vanilla` state flag survives --phase rebuilds and is
#        cleared by --tdd-reset (freeze integrity)
#   begin: --tdd-begin persists the flag per config (both directions) and echoes
#        the effective mode; re-begin after reset follows current config
#   gate: state-flag bypass (frozen — config flips mid-session change nothing)
#   chain: witness + Stop-hook + post-review routing identical to strict mode
#   wording: ask-hooks / post-review / banner / primer emit mode-aware text
#   pins: SKILL.md vanilla section + config.example.json key
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
GATE="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
WITNESS="$PLUGIN_DIR/hooks/post-bash-witness.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
PLANHOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
REMINDER="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"
PRIMER="$PLUGIN_DIR/hooks/session-start-primer.sh"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# --- hermetic environment (no CLAUDE_AGENT_TYPE: main-thread chain-state only) --
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$PROJ/.zensu/state"; export STATE_DIR
for BASELINE_SID in \
  vanilla-lib vanilla-lib-reset vanilla-lib-array vanilla-lib-array-wf vanilla-lib-wf \
  vanilla-begin-default vanilla-begin-strict vanilla-begin-vanilla vanilla-fail \
  vanilla-strtrue vanilla-rebegin vanilla-malformed vanilla-conv; do
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$BASELINE_SID"
done
CFG_DEFAULT="$STATE_DIR/no-such-config.json"
CFG_VANILLA="$STATE_DIR/vanilla-config.json"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$CFG_VANILLA"
CFG_STRICT="$STATE_DIR/strict-config.json"
printf '%s' '{"hooks":{"tddImplementation":true}}' > "$CFG_STRICT"
export ZENSU_CONFIG="$CFG_DEFAULT"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$PROJ"; }
trap cleanup EXIT

session_key() { node "$SESSION_CORE" session-key "$1"; }
# The SessionStart hook exports the canonical realpath. Keep that exact spelling:
# on macOS, mktemp may expose /var while realpath resolves it to /private/var,
# and Session Control deliberately rejects a non-canonical context filename.
SESSION_RECORDS="$(dirname "$ZENSU_SESSION_CONTEXT")"
activate_session() {
  local key
  key="$(session_key "$1")" || return 1
  export ZENSU_SESSION_KEY="$key"
  export ZENSU_SESSION_CONTEXT="$SESSION_RECORDS/$key.json"
  [ -f "$ZENSU_SESSION_CONTEXT" ]
}
payload_session() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
    try { const p=JSON.parse(s); if (typeof p.session_id === "string") process.stdout.write(p.session_id); }
    catch (_) {}
  })'
}

prod_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"%s"}' "$1"; }
test_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"%s"}' "$1"; }

gate() {  # echoes allow|deny for a payload; $2 = optional ZENSU_CONFIG override
  local sid key context
  sid="$(printf '%s' "$1" | payload_session)"
  key="$(session_key "$sid")"
  context="$SESSION_RECORDS/$key.json"
  printf '%s' "$1" | ZENSU_SESSION_KEY="$key" ZENSU_SESSION_CONTEXT="$context" \
    ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$GATE" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{const j=JSON.parse(s);console.log(j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision==="deny"?"deny":"allow")}
      catch(_){console.log("allow")}});'
}
stop_dec() { local key; key="$(session_key "$1")"; printf '%s' '{"session_id":"'"$1"'"}' | \
  ZENSU_SESSION_KEY="$key" ZENSU_SESSION_CONTEXT="$SESSION_RECORDS/$key.json" \
  ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
stop_reason() { local key; key="$(session_key "$1")"; printf '%s' '{"session_id":"'"$1"'"}' | \
  ZENSU_SESSION_KEY="$key" ZENSU_SESSION_CONTEXT="$SESSION_RECORDS/$key.json" \
  ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }
hook_ctx() {  # stdin payload, $1 hook script, $2 optional ZENSU_CONFIG override -> echoes additionalContext
  local payload sid key context
  payload="$(cat)"
  sid="$(printf '%s' "$payload" | payload_session)"
  key="${ZENSU_SESSION_KEY:-}"
  context="${ZENSU_SESSION_CONTEXT:-}"
  if [ -n "$sid" ]; then
    key="$(session_key "$sid")"
    context="$SESSION_RECORDS/$key.json"
  fi
  printf '%s' "$payload" | ZENSU_SESSION_KEY="$key" ZENSU_SESSION_CONTEXT="$context" \
    ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$1" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")}});'
}

echo "== Lib: vanilla flag plumbing =="
# shellcheck disable=SC1090
source "$PHASE_LIB"
SID_L="vanilla-lib"
activate_session "$SID_L"
SF_L="$(tdd_state_file "$SID_L")"
tdd_set_flag "$SID_L" vanilla true
[ "$(tdd_vanilla_mode "$SF_L" 2>/dev/null)" = "true" ] \
  && check "L1 tdd_vanilla_mode wrapper reads the flag" PASS || check "L1 tdd_vanilla_mode wrapper" FAIL
tdd_write_phase "$SID_L" SX GREEN_PASS "" >/dev/null 2>&1
{ [ "$(tdd_get_flag "$SF_L" vanilla)" = "true" ] && [ "$(tdd_phase "$SF_L")" = "GREEN_PASS" ]; } \
  && check "L2 vanilla flag survives --phase state rebuild (write landed)" PASS || check "L2 flag survives phase write" FAIL
SID_L3="vanilla-lib-reset"
activate_session "$SID_L3"
SF_L3="$(tdd_state_file "$SID_L3")"
tdd_set_flag "$SID_L3" vanilla true
tdd_clear_session "$SID_L3" >/dev/null 2>&1
[ "$(tdd_get_flag "$SF_L3" vanilla)" = "false" ] \
  && check "L3 --tdd-reset clears the vanilla flag" PASS || check "L3 reset clears flag" FAIL
SID_L5="vanilla-lib-array"
activate_session "$SID_L5"
SF_L5="$(tdd_state_file "$SID_L5")"
mkdir -p "$(dirname "$SF_L5")"
printf '%s' '["corrupt"]' > "$SF_L5"
if ! tdd_set_flag "$SID_L5" active true >/dev/null 2>&1 \
  && [ "$(cat "$SF_L5")" = '["corrupt"]' ] \
  && [ "$(tdd_state_status "$SF_L5")" = "invalid" ]; then
  check "L5 array-shaped state file: flag write fails closed and preserves evidence" PASS
else
  check "L5 array-shaped state file: flag write fails closed and preserves evidence" FAIL
fi
SID_L6="vanilla-lib-array-wf"
activate_session "$SID_L6"
SF_L6="$(tdd_state_file "$SID_L6")"
printf '%s' '[1,2]' > "$SF_L6"
if ! tdd_workflow_begin "$SID_L6" "create_feature" >/dev/null 2>&1 \
  && [ "$(cat "$SF_L6")" = '[1,2]' ] \
  && [ "$(tdd_state_status "$SF_L6")" = "invalid" ]; then
  check "L6 array-shaped state file: workflow write fails closed and preserves evidence" PASS
else
  check "L6 array-shaped state file: workflow write fails closed and preserves evidence" FAIL
fi
SID_L4="vanilla-lib-wf"
activate_session "$SID_L4"
SF_L4="$(tdd_state_file "$SID_L4")"
tdd_workflow_begin "$SID_L4" "create_feature,link_test" >/dev/null 2>&1
tdd_write_phase "$SID_L4" SY IMPL "" >/dev/null 2>&1
{ [ "$(zensu_workflow_active "$SF_L4")" = "true" ] && [ "$(zensu_workflow_allows "$SF_L4" create_feature)" = "true" ] && [ "$(tdd_phase "$SF_L4")" = "IMPL" ]; } \
  && check "L4 workflow window survives --phase state rebuild (preserve-all write landed)" PASS || check "L4 workflow flags survive phase write" FAIL

echo "== Begin: mode persist + echo =="
SID_A0="vanilla-begin-default"
activate_session "$SID_A0"
OUT_A0="$(ZENSU_CONFIG="$CFG_DEFAULT" bash "$LOG" --tdd-begin --session "$SID_A0" 2>/dev/null)"
[ "$OUT_A0" = "mode: vanilla" ] \
  && check "A0 default config (no tddImplementation key): --tdd-begin echoes 'mode: vanilla'" PASS || check "A0 default echo (got '$OUT_A0')" FAIL
[ "$(tdd_get_flag "$(tdd_state_file "$SID_A0")" vanilla)" = "true" ] \
  && check "A0b default config: state vanilla=true (default flipped to vanilla)" PASS || check "A0b default state" FAIL
SID_A="vanilla-begin-strict"
activate_session "$SID_A"
OUT_A="$(ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$SID_A" 2>/dev/null)"
[ "$OUT_A" = "mode: strict" ] \
  && check "A1 tddImplementation:true: --tdd-begin echoes 'mode: strict'" PASS || check "A1 strict echo (got '$OUT_A')" FAIL
[ "$(tdd_get_flag "$(tdd_state_file "$SID_A")" vanilla)" = "false" ] \
  && check "A2 tddImplementation:true: state vanilla=false" PASS || check "A2 strict state" FAIL
SID_B="vanilla-begin-vanilla"
activate_session "$SID_B"
OUT_B="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$SID_B" 2>/dev/null)"
[ "$OUT_B" = "mode: vanilla" ] \
  && check "B1 tddImplementation:false: --tdd-begin echoes 'mode: vanilla'" PASS || check "B1 vanilla echo (got '$OUT_B')" FAIL
[ "$(tdd_get_flag "$(tdd_state_file "$SID_B")" vanilla)" = "true" ] \
  && check "B2 tddImplementation:false: state vanilla=true" PASS || check "B2 vanilla state" FAIL

echo "== Begin: project-bound state + robustness paths =="
activate_session "vanilla-fail"
OUT_A3="$(STATE_DIR="$STATE_DIR/forbidden-override" ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "vanilla-fail" 2>"$STATE_DIR/a3.err")"
RC_A3=$?
{ [ "$RC_A3" -eq 0 ] && [ "$OUT_A3" = "mode: vanilla" ] && [ -f "$(tdd_state_file vanilla-fail)" ] && [ ! -e "$STATE_DIR/forbidden-override" ]; } \
  && check "A3 ambient STATE_DIR override is ignored; canonical project state activates" PASS \
  || check "A3 project-bound state path (rc=$RC_A3 stdout='$OUT_A3' err='$(cat "$STATE_DIR/a3.err")')" FAIL
SID_A5="vanilla-strtrue"
activate_session "$SID_A5"
CFG_STR="$STATE_DIR/strtrue-config.json"
printf '%s' '{"hooks":{"tddImplementation":"true"}}' > "$CFG_STR"
OUT_A5="$(ZENSU_CONFIG="$CFG_STR" bash "$LOG" --tdd-begin --session "$SID_A5" 2>/dev/null)"
{ [ "$OUT_A5" = "mode: vanilla" ] && [ "$(tdd_get_flag "$(tdd_state_file "$SID_A5")" vanilla)" = "true" ]; } \
  && check "A5 non-boolean \"true\" stays vanilla (only boolean true flips to strict)" PASS || check "A5 non-boolean stays vanilla (got '$OUT_A5')" FAIL

echo "== --mode query verb =="
activate_session "$SID_B"
[ "$(bash "$LOG" --mode --session "$SID_B" 2>/dev/null)" = "vanilla" ] \
  && check "M1 --mode echoes vanilla for a vanilla session" PASS || check "M1 --mode vanilla" FAIL
activate_session "$SID_A"
[ "$(bash "$LOG" --mode --session "$SID_A" 2>/dev/null)" = "strict" ] \
  && check "M2 --mode echoes strict for a strict session" PASS || check "M2 --mode strict" FAIL
activate_session "$SID_B"
OUT_M3="$(bash "$LOG" --mode --session "no-such-session-xyz" 2>/dev/null)"
RC_M3=$?
{ [ "$RC_M3" -ne 0 ] && [ -z "$OUT_M3" ]; } \
  && check "M3 cross-session mode query fails closed" PASS || check "M3 cross-session mode query" FAIL
no_hang() {
  bash "$LOG" "$@" >/dev/null 2>&1 &
  local pid=$!
  local hung=1 i=0
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || { hung=0; break; }
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i+1))
  done
  [ "$hung" = "1" ] && kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ "$hung" = "0" ]
}
no_hang --mode --session \
  && check "M4 dangling --session terminates (no arg-loop spin)" PASS || check "M4 arg-loop termination" FAIL
no_hang --phase IMPL --step \
  && check "M4b dangling --step terminates" PASS || check "M4b dangling --step termination" FAIL
no_hang --workflow-begin --session m4c --tools \
  && check "M4c dangling --tools terminates" PASS || check "M4c dangling --tools termination" FAIL

echo "== Reset hygiene: vanilla begin -> reset -> strict re-begin (same SID) =="
SID_G="vanilla-rebegin"
activate_session "$SID_G"
ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$SID_G" >/dev/null 2>&1
bash "$LOG" --tdd-reset --session "$SID_G" >/dev/null 2>&1
OUT_G="$(ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$SID_G" 2>/dev/null)"
[ "$OUT_G" = "mode: strict" ] \
  && check "G1 strict re-begin after vanilla+reset echoes 'mode: strict'" PASS || check "G1 re-begin echo (got '$OUT_G')" FAIL
[ "$(tdd_get_flag "$(tdd_state_file "$SID_G")" vanilla)" = "false" ] \
  && check "G2 strict re-begin clears stale vanilla flag" PASS || check "G2 re-begin state" FAIL

echo "== Gate: vanilla bypass + freeze =="
[ "$(gate "$(prod_payload "$SID_A")")" = "deny" ] \
  && check "GA1 strict session: prod deny at UNINITIALIZED (characterization)" PASS || check "GA1 strict prod deny" FAIL
[ "$(gate "$(prod_payload "$SID_B")")" = "allow" ] \
  && check "GB1 vanilla session: prod edit allowed without phase marker" PASS || check "GB1 vanilla prod allow" FAIL
[ "$(gate "$(test_payload "$SID_B")")" = "allow" ] \
  && check "GB2 vanilla session: test edit allowed" PASS || check "GB2 vanilla test allow" FAIL
bash "$LOG" --phase GREEN_PASS --step SX --session "$SID_B" >/dev/null 2>&1
[ "$(gate "$(prod_payload "$SID_B")")" = "allow" ] \
  && check "GB3 vanilla survives phase write: prod allowed at GREEN_PASS" PASS || check "GB3 freeze across phase write" FAIL
[ "$(gate "$(prod_payload "$SID_B")" "$CFG_DEFAULT")" = "allow" ] \
  && check "E1 config flip to default mid-session: vanilla gate still allows (frozen)" PASS || check "E1 freeze vanilla->default" FAIL
[ "$(gate "$(prod_payload "$SID_A")" "$CFG_VANILLA")" = "deny" ] \
  && check "E2 config flip to vanilla mid-session: strict gate still denies (frozen)" PASS || check "E2 freeze strict->vanilla" FAIL

echo "== Gate: session-state files are write-protected =="
state_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":".zensu/state/tdd-phase-evil.json"},"session_id":"%s"}' "$1"; }
plans_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":".zensu/plans/notes.md"},"session_id":"%s"}' "$1"; }
[ "$(gate "$(state_payload "$SID_A")")" = "deny" ] \
  && check "SP1 strict session: Edit on .zensu/state/ denied (no self-un-gating)" PASS || check "SP1 state-path deny strict" FAIL
[ "$(gate "$(state_payload "$SID_B")")" = "deny" ] \
  && check "SP2 vanilla session: Edit on .zensu/state/ denied (bypass does not cover state)" PASS || check "SP2 state-path deny vanilla" FAIL
[ "$(gate "$(plans_payload "$SID_B")")" = "allow" ] \
  && check "SP3 vanilla session: .zensu/plans/ exemption preserved" PASS || check "SP3 plans exemption" FAIL
[ "$(gate "$(plans_payload "$SID_A")")" = "allow" ] \
  && check "SP3b strict session: .zensu/plans/ exemption reached past the state deny" PASS || check "SP3b strict plans exemption" FAIL
evil_path_payload() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"session_id":"%s"}' "$1" "$2"; }
[ "$(gate "$(evil_path_payload ".zensu/./state/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP4 dot-segment spelling .zensu/./state/ still denied" PASS || check "SP4 dot-segment deny" FAIL
[ "$(gate "$(evil_path_payload ".zensu//state/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP5 double-slash spelling .zensu//state/ still denied" PASS || check "SP5 double-slash deny" FAIL
[ "$(gate "$(evil_path_payload ".ZENSU/State/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP6 case variant .ZENSU/State/ still denied" PASS || check "SP6 case-variant deny" FAIL
[ "$(gate "$(evil_path_payload "src/../.zensu/state/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP7 traversal src/../.zensu/state/ still denied" PASS || check "SP7 traversal deny" FAIL
[ "$(gate "$(evil_path_payload "$STATE_DIR/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP8 resolved STATE_DIR override location denied too" PASS || check "SP8 state-dir override deny" FAIL
ln -s "$STATE_DIR" "$PROJ/statelink" 2>/dev/null
if [ -L "$PROJ/statelink" ]; then
  [ "$(gate "$(evil_path_payload "$PROJ/statelink/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
    && check "SP9 symlink alias to the state dir denied (realpath-resolved)" PASS || check "SP9 symlink-alias deny" FAIL
  ln -s "$STATE_DIR/tdd-phase-$(session_key "$SID_B").json" "$PROJ/innocent.json" 2>/dev/null
  { [ -L "$PROJ/innocent.json" ] && [ "$(gate "$(evil_path_payload "$PROJ/innocent.json" "$SID_B")")" = "deny" ]; } \
    && check "SP10 file symlink to a state file denied (full-path realpath)" PASS || check "SP10 file-symlink deny" FAIL
else
  check "SP9 SKIPPED — symlinks unavailable on this platform (ln -s failed)" PASS
  check "SP10 SKIPPED — symlinks unavailable on this platform (ln -s failed)" PASS
fi

echo "== Witness: records in vanilla session (live vanilla config) =="
activate_session "$SID_B"
echo '{"tool_input":{"command":"npm test"},"tool_response":{"stdout":"ok"},"session_id":"'"$SID_B"'"}' | ZENSU_CONFIG="$CFG_VANILLA" bash "$WITNESS" >/dev/null 2>&1
WLOG="$PROJ/.zensu/logs/witness-$(session_key "$SID_B").log"
W_LINE="$(grep -F 'cmd="npm test"' "$WLOG" 2>/dev/null | head -n1)"
{ [ -f "$WLOG" ] && printf '%s' "$W_LINE" | grep -qF 'cmd="npm test"' && printf '%s' "$W_LINE" | grep -qF 'tail="ok"'; } \
  && check "C1 vanilla session records witness line with cmd= + tail=" PASS || check "C1 witness in vanilla (got '${W_LINE}')" FAIL

echo "== Gate: malformed state fails closed =="
SID_MS="vanilla-malformed"
activate_session "$SID_MS"
bash "$LOG" --tdd-begin --session "$SID_MS" >/dev/null 2>&1
printf '%s' 'this is not json{{{' > "$(tdd_state_file "$SID_MS")"
[ "$(gate "$(prod_payload "$SID_MS")")" = "deny" ] \
  && check "MS1 corrupt state JSON: gate blocks instead of treating it as inactive" PASS || check "MS1 malformed-state fail-closed" FAIL

echo "== Chain guarantee: vanilla keeps Stop-hook enforcement (live vanilla config) =="
activate_session "$SID_B"
[ "$(stop_dec "$SID_B" "$CFG_VANILLA")" = "allow" ] && check "D0 mid-implementation: Stop allows" PASS || check "D0 mid-impl allow" FAIL
bash "$LOG" --tdd-complete --session "$SID_B" >/dev/null 2>&1
[ "$(stop_dec "$SID_B" "$CFG_VANILLA")" = "block" ] && check "D1 implComplete in vanilla: Stop BLOCKS" PASS || check "D1 vanilla terminus block" FAIL
case "$(stop_reason "$SID_B" "$CFG_VANILLA")" in *"zensu:code-reviewer"*) check "D2 block reason forces zensu:code-reviewer" PASS ;; *) check "D2 reason code-reviewer" FAIL ;; esac
bash "$LOG" --code-review-done --session "$SID_B" >/dev/null 2>&1
[ "$(stop_dec "$SID_B" "$CFG_VANILLA")" = "block" ] && check "D3 codeReviewDone in vanilla: Stop still BLOCKS" PASS || check "D3 pre-self-review block" FAIL
case "$(stop_reason "$SID_B" "$CFG_VANILLA")" in *"zensu:self-review"*) check "D4 block reason forces skill='zensu:self-review'" PASS ;; *) check "D4 reason self-review" FAIL ;; esac
bash "$LOG" --chain-done --session "$SID_B" >/dev/null 2>&1
[ "$(stop_dec "$SID_B" "$CFG_VANILLA")" = "allow" ] && check "D5 chainDone in vanilla: Stop ALLOWS" PASS || check "D5 vanilla terminus allow" FAIL

echo "== Ask-hooks: mode-aware directives =="
PA_V="$(printf '%s' '{}' | hook_ctx "$PLANHOOK" "$CFG_VANILLA")"
{ printf '%s' "$PA_V" | grep -q "vanilla" \
  && printf '%s' "$PA_V" | grep -qF "skill='zensu:tdd'" \
  && printf '%s' "$PA_V" | grep -q "AskUserQuestion" \
  && printf '%s' "$PA_V" | grep -qF "Skipping TDD: docs only" \
  && ! printf '%s' "$PA_V" | grep -qF "strict TDD flow"; } \
  && check "F1 plan-approval (vanilla cfg): vanilla wording + skill route + ask + docs fast-path, no strict text" PASS \
  || check "F1 plan-approval vanilla directive" FAIL
PA_S="$(printf '%s' '{}' | hook_ctx "$PLANHOOK" "$CFG_STRICT")"
printf '%s' "$PA_S" | grep -qF "strict TDD flow" \
  && check "F2 plan-approval (tddImplementation:true): strict directive" PASS || check "F2 plan-approval strict directive" FAIL
PA_D="$(printf '%s' '{}' | hook_ctx "$PLANHOOK" "$CFG_DEFAULT")"
{ printf '%s' "$PA_D" | grep -q "vanilla" && ! printf '%s' "$PA_D" | grep -qF "strict TDD flow"; } \
  && check "F2b plan-approval (default cfg): vanilla directive — default flipped to vanilla" PASS || check "F2b plan-approval default vanilla" FAIL
RM_V="$(printf '%s' '{"prompt":"implement a debounce helper","session_id":"vanilla-ask-v"}' | hook_ctx "$REMINDER" "$CFG_VANILLA")"
{ printf '%s' "$RM_V" | grep -q "vanilla" \
  && printf '%s' "$RM_V" | grep -qF "skill='zensu:tdd'" \
  && printf '%s' "$RM_V" | grep -q "AskUserQuestion" \
  && printf '%s' "$RM_V" | grep -qF "doc/comment/prose" \
  && ! printf '%s' "$RM_V" | grep -qF "strict TDD flow"; } \
  && check "F3 reminder (vanilla cfg): vanilla wording + skill route + ask + not-a-code-change fast-path, no strict text" PASS \
  || check "F3 reminder vanilla directive" FAIL
RM_S="$(printf '%s' '{"prompt":"implement a debounce helper","session_id":"vanilla-ask-s"}' | hook_ctx "$REMINDER" "$CFG_STRICT")"
printf '%s' "$RM_S" | grep -qF "strict TDD flow" \
  && check "F4 reminder (tddImplementation:true): strict directive" PASS || check "F4 reminder strict directive" FAIL
RM_D="$(printf '%s' '{"prompt":"implement a debounce helper","session_id":"vanilla-ask-d"}' | hook_ctx "$REMINDER" "$CFG_DEFAULT")"
{ printf '%s' "$RM_D" | grep -q "vanilla" && ! printf '%s' "$RM_D" | grep -qF "strict TDD flow"; } \
  && check "F4b reminder (default cfg): vanilla directive — default flipped to vanilla" PASS || check "F4b reminder default vanilla" FAIL

echo "== Post-review: mode-aware fix directive =="
PR_V="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"'"$SID_B"'"}' | hook_ctx "$POSTREV")"
{ printf '%s' "$PR_V" | grep -q "vanilla" \
  && ! printf '%s' "$PR_V" | grep -qF "strict TDD discipline" \
  && ! printf '%s' "$PR_V" | grep -qF "After the fixes are GREEN" \
  && printf '%s' "$PR_V" | grep -qF "After the fixes are applied" \
  && printf '%s' "$PR_V" | grep -qF "/zensu:tdd" \
  && printf '%s' "$PR_V" | grep -qF "subagent_type='zensu:code-reviewer'"; } \
  && check "D6 post-review (vanilla session): vanilla fix wording + done-phrase, pinned literals retained" PASS \
  || check "D6 post-review vanilla directive" FAIL
PR_S="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"'"$SID_A"'"}' | hook_ctx "$POSTREV")"
{ printf '%s' "$PR_S" | grep -qF "strict TDD discipline" \
  && printf '%s' "$PR_S" | grep -qF "After the fixes are GREEN" \
  && printf '%s' "$PR_S" | grep -qF "subagent_type='zensu:code-reviewer'"; } \
  && check "D7 post-review (strict session): strict fix wording + done-phrase unchanged" PASS \
  || check "D7 post-review strict directive" FAIL
PR_S2="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"'"$SID_A"'"}' | hook_ctx "$POSTREV" "$CFG_VANILLA")"
printf '%s' "$PR_S2" | grep -qF "strict TDD discipline" \
  && check "D8 post-review (strict state, vanilla LIVE config): strict wording — state wins (frozen)" PASS \
  || check "D8 post-review freeze cross-pin" FAIL
SID_C="vanilla-conv"
activate_session "$SID_C"
ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$SID_C" >/dev/null 2>&1
for _ in 1 2 3 4 5; do
  tdd_increment_counter "$SID_C" reviewRound >/dev/null
done
PR_CONV="$(printf '%s' '{"tool_input":{"subagent_type":"zensu:code-reviewer"},"session_id":"'"$SID_C"'"}' | hook_ctx "$POSTREV" "$CFG_VANILLA")"
{ printf '%s' "$PR_CONV" | grep -qF "Auto-fix convergence" \
  && printf '%s' "$PR_CONV" | grep -qF "skill='zensu:self-review'" \
  && [ "$(tdd_get_flag "$(tdd_state_file "$SID_C")" codeReviewDone)" = "true" ] \
  && ! printf '%s' "$PR_CONV" | grep -qF "strict TDD discipline" \
  && ! printf '%s' "$PR_CONV" | grep -qF "RED test"; } \
  && check "D9 max-rounds convergence in vanilla: CONV branch taken, self-review routing, no strict-TDD ceremony" PASS \
  || check "D9 CONV vanilla pin" FAIL

echo "== Ask-hook heredoc parity (drift guard) =="
parity() {
  local f="$1"; shift
  local d
  d="$(mktemp -d "$STATE_DIR/parity-XXXXXX")"
  awk -v dir="$d" '{ if ($0 ~ /^cat <<.JSON.$/) { n++; inb=1; next } if ($0 == "JSON") { inb=0 } if (inb) print > (dir "/b" n) }' "$f"
  if [ ! -f "$d/b1" ] || [ ! -f "$d/b2" ]; then echo "MISSING_BLOCKS"; return; fi
  if [ -f "$d/b3" ]; then echo "EXTRA_BLOCKS"; return; fi
  local p
  for p in "$@"; do
    if ! grep -qF "$p" "$d/b1" || ! grep -qF "$p" "$d/b2"; then echo "DRIFT:$p"; return; fi
  done
  echo "OK"
}
P1="$(parity "$PLANHOOK" "Skipping TDD: docs only" "Skipping TDD: user declined" "AskUserQuestion" "kein tdd" "'use tdd', 'with tdd'" "Auto Mode" "skill='zensu:tdd'")"
[ "$P1" = "OK" ] && check "P1 plan-approval heredocs: shared invariants present in BOTH branches" PASS || check "P1 plan-approval parity ($P1)" FAIL
P2="$(parity "$REMINDER" "Skipping TDD: user declined" "AskUserQuestion" "kein tdd" "'use tdd', 'with tdd'" "Auto Mode" "skill='zensu:tdd'" "doc/comment/prose")"
[ "$P2" = "OK" ] && check "P2 reminder heredocs: shared invariants present in BOTH branches" PASS || check "P2 reminder parity ($P2)" FAIL
P3="$(parity "$PRIMER" "/zensu:tdd" "Plan mode" "AskUserQuestion" "top-level interactive thread" "/zensu:bootstrap")"
[ "$P3" = "OK" ] && check "P3 primer heredocs: shared invariants present in BOTH branches" PASS || check "P3 primer parity ($P3)" FAIL

echo "== Banner + primer: mode-aware wording =="
BN_V="$(printf '%s' '{"source":"startup"}' | ZENSU_CONFIG="$CFG_VANILLA" bash "$BANNER" 2>/dev/null)"
{ printf '%s' "$BN_V" | grep -q "vanilla" && ! printf '%s' "$BN_V" | grep -qF "strict RED→GREEN TDD"; } \
  && check "BNR1 banner (vanilla cfg): vanilla wording, no strict-TDD flow line" PASS || check "BNR1 banner vanilla wording" FAIL
BN_S="$(printf '%s' '{"source":"startup"}' | ZENSU_CONFIG="$CFG_STRICT" bash "$BANNER" 2>/dev/null)"
printf '%s' "$BN_S" | grep -qF "strict RED→GREEN TDD" \
  && check "BNR2 banner (tddImplementation:true): strict wording" PASS || check "BNR2 banner strict wording" FAIL
BN_D="$(printf '%s' '{"source":"startup"}' | ZENSU_CONFIG="$CFG_DEFAULT" bash "$BANNER" 2>/dev/null)"
{ printf '%s' "$BN_D" | grep -q "vanilla" && ! printf '%s' "$BN_D" | grep -qF "strict RED→GREEN TDD"; } \
  && check "BNR2b banner (default cfg): vanilla wording — default flipped to vanilla" PASS || check "BNR2b banner default vanilla" FAIL
PRM_V="$(printf '%s' '{"source":"startup"}' | hook_ctx "$PRIMER" "$CFG_VANILLA")"
{ printf '%s' "$PRM_V" | grep -q "vanilla" && printf '%s' "$PRM_V" | grep -qF "/zensu:tdd" \
  && ! printf '%s' "$PRM_V" | grep -qF "strict RED→GREEN TDD"; } \
  && check "BNR3 primer (vanilla cfg): vanilla orientation, /zensu:tdd route kept" PASS || check "BNR3 primer vanilla wording" FAIL
PRM_S="$(printf '%s' '{"source":"startup"}' | hook_ctx "$PRIMER" "$CFG_STRICT")"
printf '%s' "$PRM_S" | grep -qF "strict RED→GREEN TDD" \
  && check "BNR4 primer (tddImplementation:true): strict orientation" PASS || check "BNR4 primer strict wording" FAIL
PRM_D="$(printf '%s' '{"source":"startup"}' | hook_ctx "$PRIMER" "$CFG_DEFAULT")"
if printf '%s\n%s\n' "$PRM_V" "$PRM_S" | grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session'; then
  check "F13 strict/vanilla primer outputs positively pin the fail-closed helper guard" PASS
else
  check "F13 strict/vanilla primer outputs lack the fail-closed helper guard" FAIL
fi
{ printf '%s' "$PRM_D" | grep -q "vanilla" && ! printf '%s' "$PRM_D" | grep -qF "strict RED→GREEN TDD"; } \
  && check "BNR4b primer (default cfg): vanilla orientation — default flipped to vanilla" PASS || check "BNR4b primer default vanilla" FAIL

echo "== Content pins: SKILL.md + config.example.json =="
SKILL_TDD="$PLUGIN_DIR/skills/tdd/SKILL.md"
{ grep -qF "## Vanilla Implementation Mode" "$SKILL_TDD" \
  && grep -qF "mode: vanilla" "$SKILL_TDD" \
  && grep -qF "DISCIPLINE AUDIT SKIPPED — vanilla mode" "$SKILL_TDD"; } \
  && check "H1 SKILL.md documents the vanilla mode deltas + mode echo + audit skip" PASS || check "H1 SKILL.md vanilla section" FAIL
node -e 'const c=require(process.argv[1]);process.exit(c.hooks&&c.hooks.tddImplementation===false?0:1)' "$PLUGIN_DIR/config.example.json" 2>/dev/null \
  && check "H2 config.example.json ships hooks.tddImplementation=false (default vanilla)" PASS || check "H2 config.example.json key" FAIL
{ grep -qF "Precondition Drift Audit" "$SKILL_TDD" \
  && grep -qF "mtime Discipline Audit" "$SKILL_TDD" \
  && grep -qF "Cross-Layer Value Flow Audit" "$SKILL_TDD" \
  && grep -A20 "## Vanilla Implementation Mode" "$SKILL_TDD" | grep -qi "precondition" \
  && ! grep -qF "steps 1-4 + 7-10" "$SKILL_TDD"; } \
  && check "H3 vanilla deltas name the audits (no bare step-number coupling) + carry the precondition check" PASS \
  || check "H3 SKILL.md name-based audit refs" FAIL
grep -qF -- "--mode" "$PLUGIN_DIR/skills/self-review/SKILL.md" \
  && check "H4 self-review detects vanilla via the --mode query verb" PASS || check "H4 self-review --mode" FAIL
grep -qF "checked into" "$PLUGIN_DIR/README.md" && grep -A3 "| \`tddImplementation\` |" "$PLUGIN_DIR/README.md" | grep -qF ".zensu/config.json" \
  && check "H5 README documents the repo-shipped project-overlay vector" PASS || check "H5 README overlay vector" FAIL

echo "----"
echo "test-tdd-vanilla-mode: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
