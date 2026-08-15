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
#   chain: witness + Stop-hook + post-review routing decisions identical to
#        strict mode
#   wording: ask-hooks / post-review / banner / primer / Stop block state legend
#        emit mode-aware text
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
  vanilla-strtrue vanilla-rebegin vanilla-malformed vanilla-conv vanilla-plan \
  vanilla-ask-v vanilla-ask-s vanilla-ask-d vanilla-strict-stop; do
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
activate_session() {
  export CLAUDE_CODE_SESSION_ID="$1"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-session.sh"
  zensu_bind_model_session
}
payload_session() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
    try { const p=JSON.parse(s); if (typeof p.session_id === "string") process.stdout.write(p.session_id); }
    catch (_) {}
  })'
}

prod_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"%s"}' "$1"; }
test_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/foo.test.ts"},"session_id":"%s"}' "$1"; }

gate() {  # echoes allow|deny for a payload; $2 = optional ZENSU_CONFIG override
  local sid
  sid="$(printf '%s' "$1" | payload_session)"
  printf '%s' "$1" | ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$GATE" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{const j=JSON.parse(s);console.log(j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision==="deny"?"deny":"allow")}
      catch(_){console.log("allow")}});'
}
stop_dec() { printf '%s' '{"hook_event_name":"Stop","session_id":"'"$1"'"}' | \
  ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}
      try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
stop_reason() { printf '%s' '{"hook_event_name":"Stop","session_id":"'"$1"'"}' | \
  ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$STOP" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }
hook_ctx() {  # stdin payload, $1 hook script, $2 optional ZENSU_CONFIG override -> echoes additionalContext
  local payload
  payload="$(cat)"
  printf '%s' "$payload" | ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$1" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")}});'
}
postreview_ctx() { # $1 session, $2 optional live config; every delivery gets a fresh ticket
  local sid="$1" cfg="${2:-$ZENSU_CONFIG}" ticket
  ticket="$(bash "$LOG" --review-ticket --session "$sid" 2>/dev/null)" || return 1
  SID_VALUE="$sid" TICKET="$ticket" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID_VALUE
    }));
  ' | hook_ctx "$POSTREV" "$cfg"
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
# E3/E3b extend the freeze to the /zensu:tdd-mode SESSION override, which outranks
# the config at --tdd-begin. Outranking the config must not mean outranking the
# frozen flag: the gate reads state only, so a mid-chain switch can neither un-gate
# a strict chain nor re-arm a vanilla one — exactly as a config flip cannot.
E3_MARKER="$(bash -c 'source "$0"; zensu_tdd_mode_marker_path "$1" "$2"' \
  "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$PROJ" "$(session_key "$SID_B")")"
printf '%s' '{"mode":"strict"}' > "$E3_MARKER"
# Positive control first: the marker this block writes IS the one the resolver reads,
# so the two no-effect assertions below cannot pass through a spelling drift.
activate_session "vanilla-conv"
E3_CTRL="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "vanilla-conv" 2>/dev/null)"
E3_MARKER_CONV="$(bash -c 'source "$0"; zensu_tdd_mode_marker_path "$1" "$2"' \
  "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$PROJ" "$(session_key "vanilla-conv")")"
printf '%s' '{"mode":"strict"}' > "$E3_MARKER_CONV"
bash "$LOG" --tdd-reset --session "vanilla-conv" >/dev/null 2>&1
E3_CTRL2="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "vanilla-conv" 2>/dev/null)"
{ [ "$E3_CTRL" = "mode: vanilla" ] && [ "$E3_CTRL2" = "mode: strict" ]; } \
  && check "E3c control: a marker at this path IS read by --tdd-begin (vanilla -> strict on re-arm)" PASS \
  || check "E3c marker path control (first='$E3_CTRL' after='$E3_CTRL2')" FAIL
rm -f "$E3_MARKER_CONV"
[ "$(gate "$(prod_payload "$SID_B")")" = "allow" ] \
  && check "E3 session override flipped to strict mid-session: vanilla gate still allows (frozen)" PASS || check "E3 freeze vs session override" FAIL
# Read the allow above against a LIVE gate: an allow is also what a silently-exiting
# gate produces, so a deny from the strict session pins that the gate still decides.
[ "$(gate "$(prod_payload "$SID_A")")" = "deny" ] \
  && check "E3d control: the gate is still deciding while E3 reads its allow" PASS || check "E3d live-gate control" FAIL
activate_session "$SID_B"   # --mode refuses a cross-session query (M3); bind first
[ "$(bash "$LOG" --mode --session "$SID_B" 2>/dev/null)" = "vanilla" ] \
  && check "E3b --mode still reports the frozen mode, not the new session override" PASS || check "E3b --mode vs session override" FAIL
rm -f "$E3_MARKER"

echo "== Gate: session-state files are write-protected =="
state_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":".zensu/state/tdd-phase-evil.json"},"session_id":"%s"}' "$1"; }
plans_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":".zensu/plans/notes.md"},"session_id":"%s"}' "$1"; }
[ "$(gate "$(state_payload "$SID_A")")" = "deny" ] \
  && check "SP1 strict session: Edit on .zensu/state/ denied (no self-un-gating)" PASS || check "SP1 state-path deny strict" FAIL
[ "$(gate "$(state_payload "$SID_B")")" = "deny" ] \
  && check "SP2 vanilla session: Edit on .zensu/state/ denied (bypass does not cover state)" PASS || check "SP2 state-path deny vanilla" FAIL
[ "$(gate "$(plans_payload "$SID_B")")" = "allow" ] \
  && check "SP3 vanilla session: .zensu/plans/ exemption preserved" PASS || check "SP3 plans exemption" FAIL
[ "$(gate "$(plans_payload "$SID_A")")" = "allow" ] \
  && check "SP3b strict session: .zensu/plans/ exemption reached past the state deny" PASS || check "SP3b strict plans exemption" FAIL
evil_path_payload() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"},"session_id":"%s"}' "$1" "$2"; }
[ "$(gate "$(evil_path_payload ".zensu/./state/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP4 dot-segment spelling .zensu/./state/ still denied" PASS || check "SP4 dot-segment deny" FAIL
[ "$(gate "$(evil_path_payload ".zensu//state/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP5 double-slash spelling .zensu//state/ still denied" PASS || check "SP5 double-slash deny" FAIL
[ "$(gate "$(evil_path_payload ".ZENSU/State/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP6 case variant .ZENSU/State/ still denied" PASS || check "SP6 case-variant deny" FAIL
[ "$(gate "$(evil_path_payload "src/../.zensu/state/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
  && check "SP7 traversal src/../.zensu/state/ still denied" PASS || check "SP7 traversal deny" FAIL
activate_session "$SID_B"
BOUND_STATE_DIR="$(dirname "$(tdd_state_file "$SID_B")")"
[ "$(gate "$(evil_path_payload "$BOUND_STATE_DIR/tdd-phase-evil.json" "$SID_B")")" = "deny" ] \
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
echo '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"stdout":"ok"},"session_id":"'"$SID_B"'"}' | ZENSU_CONFIG="$CFG_VANILLA" bash "$WITNESS" >/dev/null 2>&1
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
D2_REASON="$(stop_reason "$SID_B" "$CFG_VANILLA")"
case "$D2_REASON" in *"zensu:code-reviewer"*) check "D2 block reason forces zensu:code-reviewer" PASS ;; *) check "D2 reason code-reviewer" FAIL ;; esac
{ printf '%s' "$D2_REASON" | grep -qF 'mode=vanilla' \
  && printf '%s' "$D2_REASON" | grep -qF 'implComplete=true, chainDone=false' \
  && printf '%s' "$D2_REASON" | grep -qF 'the RED/GREEN FSM is not driven' \
  && [ "$(printf '%s' "$D2_REASON" | grep -oF 'Session state: mode=' | wc -l | tr -d ' ')" -eq 1 ]; } \
  && check "D2b code-reviewer branch carries the vanilla state legend exactly once" PASS || check "D2b vanilla legend on code-reviewer branch" FAIL
D2C_REASON="$(stop_reason "$SID_B" "$CFG_STRICT")"
printf '%s' "$D2C_REASON" | grep -qF 'mode=vanilla' \
  && check "D2c vanilla state, strict LIVE config: legend says mode=vanilla — state wins (frozen)" PASS || check "D2c legend freeze cross-pin" FAIL
postreview_ctx "$SID_B" "$CFG_VANILLA" >/dev/null
VANILLA_REVIEW_TICKET="$(bash "$LOG" --current-review-ticket --session "$SID_B" 2>/dev/null)"
bash "$LOG" --code-review-done --claimed-review-ticket "$VANILLA_REVIEW_TICKET" \
  --session "$SID_B" >/dev/null 2>&1
[ "$(stop_dec "$SID_B" "$CFG_VANILLA")" = "block" ] && check "D3 codeReviewDone in vanilla: Stop still BLOCKS" PASS || check "D3 pre-self-review block" FAIL
D4_REASON="$(stop_reason "$SID_B" "$CFG_VANILLA")"
case "$D4_REASON" in *"zensu:self-review"*) check "D4 block reason forces skill='zensu:self-review'" PASS ;; *) check "D4 reason self-review" FAIL ;; esac
{ printf '%s' "$D4_REASON" | grep -qF 'mode=vanilla' \
  && printf '%s' "$D4_REASON" | grep -qF 'the RED/GREEN FSM is not driven'; } \
  && check "D4b self-review branch carries the vanilla state legend" PASS || check "D4b vanilla legend on self-review branch" FAIL
bash "$LOG" --chain-done --claimed-review-ticket "$VANILLA_REVIEW_TICKET" \
  --session "$SID_B" >/dev/null 2>&1
[ "$(stop_dec "$SID_B" "$CFG_VANILLA")" = "allow" ] && check "D5 chainDone in vanilla: Stop ALLOWS" PASS || check "D5 vanilla terminus allow" FAIL
SID_SS="vanilla-strict-stop"
activate_session "$SID_SS"
ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$SID_SS" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_SS" >/dev/null 2>&1
D5B_REASON="$(stop_reason "$SID_SS" "$CFG_STRICT")"
{ printf '%s' "$D5B_REASON" | grep -qF 'mode=strict' \
  && ! printf '%s' "$D5B_REASON" | grep -qF 'the RED/GREEN FSM is not driven'; } \
  && check "D5b strict session: block reason states mode=strict without the vanilla legend" PASS || check "D5b strict mode in block reason" FAIL
D5C_REASON="$(stop_reason "$SID_SS" "$CFG_VANILLA")"
printf '%s' "$D5C_REASON" | grep -qF 'mode=strict' \
  && check "D5c strict state, vanilla LIVE config: legend says mode=strict — state wins (frozen)" PASS || check "D5c legend freeze cross-pin (strict)" FAIL
bash "$LOG" --chain-done --session "$SID_SS" >/dev/null 2>&1
activate_session "$SID_B"

echo "== Ask-hooks: mode-aware directives =="
SID_PLAN="vanilla-plan"
PA_V="$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","session_id":"'"$SID_PLAN"'"}' | hook_ctx "$PLANHOOK" "$CFG_VANILLA")"
{ printf '%s' "$PA_V" | grep -q "vanilla" \
  && printf '%s' "$PA_V" | grep -qF "skill='zensu:tdd'" \
  && printf '%s' "$PA_V" | grep -q "AskUserQuestion" \
  && printf '%s' "$PA_V" | grep -qF "Skipping TDD: docs only" \
  && ! printf '%s' "$PA_V" | grep -qF "strict TDD flow"; } \
  && check "F1 plan-approval (vanilla cfg): vanilla wording + skill route + ask + docs fast-path, no strict text" PASS \
  || check "F1 plan-approval vanilla directive" FAIL
PA_S="$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","session_id":"'"$SID_PLAN"'"}' | hook_ctx "$PLANHOOK" "$CFG_STRICT")"
printf '%s' "$PA_S" | grep -qF "strict TDD flow" \
  && check "F2 plan-approval (tddImplementation:true): strict directive" PASS || check "F2 plan-approval strict directive" FAIL
PA_D="$(printf '%s' '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","session_id":"'"$SID_PLAN"'"}' | hook_ctx "$PLANHOOK" "$CFG_DEFAULT")"
{ printf '%s' "$PA_D" | grep -q "vanilla" && ! printf '%s' "$PA_D" | grep -qF "strict TDD flow"; } \
  && check "F2b plan-approval (default cfg): vanilla directive — default flipped to vanilla" PASS || check "F2b plan-approval default vanilla" FAIL
RM_V="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"implement a debounce helper","session_id":"vanilla-ask-v"}' | hook_ctx "$REMINDER" "$CFG_VANILLA")"
{ printf '%s' "$RM_V" | grep -q "vanilla" \
  && printf '%s' "$RM_V" | grep -qF "skill='zensu:tdd'" \
  && printf '%s' "$RM_V" | grep -q "AskUserQuestion" \
  && printf '%s' "$RM_V" | grep -qF "doc/comment/prose" \
  && ! printf '%s' "$RM_V" | grep -qF "strict TDD flow"; } \
  && check "F3 reminder (vanilla cfg): vanilla wording + skill route + ask + not-a-code-change fast-path, no strict text" PASS \
  || check "F3 reminder vanilla directive" FAIL
RM_S="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"implement a debounce helper","session_id":"vanilla-ask-s"}' | hook_ctx "$REMINDER" "$CFG_STRICT")"
printf '%s' "$RM_S" | grep -qF "strict TDD flow" \
  && check "F4 reminder (tddImplementation:true): strict directive" PASS || check "F4 reminder strict directive" FAIL
RM_D="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","prompt":"implement a debounce helper","session_id":"vanilla-ask-d"}' | hook_ctx "$REMINDER" "$CFG_DEFAULT")"
{ printf '%s' "$RM_D" | grep -q "vanilla" && ! printf '%s' "$RM_D" | grep -qF "strict TDD flow"; } \
  && check "F4b reminder (default cfg): vanilla directive — default flipped to vanilla" PASS || check "F4b reminder default vanilla" FAIL

echo "== Post-review: mode-aware fix directive =="
bash "$LOG" --tdd-begin --session "$SID_B" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_B" >/dev/null 2>&1
PR_V="$(postreview_ctx "$SID_B")"
{ printf '%s' "$PR_V" | grep -q "vanilla" \
  && ! printf '%s' "$PR_V" | grep -qF "strict TDD discipline" \
  && ! printf '%s' "$PR_V" | grep -qF "After the fixes are GREEN" \
  && printf '%s' "$PR_V" | grep -qF "After the fixes are applied" \
  && printf '%s' "$PR_V" | grep -qF "/zensu:tdd" \
  && printf '%s' "$PR_V" | grep -qF "subagent_type='zensu:code-reviewer'"; } \
  && check "D6 post-review (vanilla session): vanilla fix wording + done-phrase, pinned literals retained" PASS \
  || check "D6 post-review vanilla directive" FAIL
activate_session "$SID_A"
ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$SID_A" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_A" >/dev/null 2>&1
PR_S="$(postreview_ctx "$SID_A")"
{ printf '%s' "$PR_S" | grep -qF "strict TDD discipline" \
  && printf '%s' "$PR_S" | grep -qF "After the fixes are GREEN" \
  && printf '%s' "$PR_S" | grep -qF "subagent_type='zensu:code-reviewer'"; } \
  && check "D7 post-review (strict session): strict fix wording + done-phrase unchanged" PASS \
  || check "D7 post-review strict directive" FAIL
PR_S2="$(postreview_ctx "$SID_A" "$CFG_VANILLA")"
printf '%s' "$PR_S2" | grep -qF "strict TDD discipline" \
  && check "D8 post-review (strict state, vanilla LIVE config): strict wording — state wins (frozen)" PASS \
  || check "D8 post-review freeze cross-pin" FAIL
SID_C="vanilla-conv"
activate_session "$SID_C"
ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$SID_C" >/dev/null 2>&1
bash "$LOG" --tdd-complete --session "$SID_C" >/dev/null 2>&1
# Drive five real ticket-bound deliveries through the authoritative Session
# Control workflow document before delivery six crosses the cap.
CONV_ROUND=0
while [ "$CONV_ROUND" -lt 5 ]; do
  postreview_ctx "$SID_C" "$CFG_VANILLA" >/dev/null
  CONV_ROUND=$((CONV_ROUND + 1))
done
PR_CONV="$(postreview_ctx "$SID_C" "$CFG_VANILLA")"
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
  awk -v dir="$d" '{
    if ($0 ~ /^[[:space:]]*cat[[:space:]]+<<\047?JSON\047?([[:space:]]*\|.*)?$/) { n++; inb=1; next }
    if ($0 ~ /^[[:space:]]*JSON[[:space:]]*$/) { inb=0; next }
    if (inb) print > (dir "/b" n)
  }' "$f"
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
PRM_V="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | hook_ctx "$PRIMER" "$CFG_VANILLA")"
{ printf '%s' "$PRM_V" | grep -q "vanilla" && printf '%s' "$PRM_V" | grep -qF "/zensu:tdd" \
  && ! printf '%s' "$PRM_V" | grep -qF "strict RED→GREEN TDD"; } \
  && check "BNR3 primer (vanilla cfg): vanilla orientation, /zensu:tdd route kept" PASS || check "BNR3 primer vanilla wording" FAIL
PRM_S="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | hook_ctx "$PRIMER" "$CFG_STRICT")"
printf '%s' "$PRM_S" | grep -qF "strict RED→GREEN TDD" \
  && check "BNR4 primer (tddImplementation:true): strict orientation" PASS || check "BNR4 primer strict wording" FAIL
PRM_D="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' | hook_ctx "$PRIMER" "$CFG_DEFAULT")"
EXPECTED_PRIMER_HELPER="$(printf '%q' "$PLUGIN_DIR/hooks/lib/zensu-log.sh")"
if printf '%s' "$PRM_V" | grep -qF "$EXPECTED_PRIMER_HELPER" \
  && printf '%s' "$PRM_S" | grep -qF "$EXPECTED_PRIMER_HELPER"; then
  check "F13 strict/vanilla primer outputs pin the executing plugin helper path" PASS
else
  check "F13 strict/vanilla primer outputs lack the executing plugin helper path" FAIL
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
grep -qF "checked into" "$PLUGIN_DIR/docs/configuration.md" && grep -A3 "| \`tddImplementation\` |" "$PLUGIN_DIR/docs/configuration.md" | grep -qF ".zensu/config.json" \
  && check "H5 docs/configuration.md documents the repo-shipped project-overlay vector" PASS || check "H5 config-doc overlay vector" FAIL

echo "----"
echo "test-tdd-vanilla-mode: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
