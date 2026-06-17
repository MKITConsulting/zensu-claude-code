#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-bash-zensu-gate.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/pre-bash-zensu-gate.sh exists" FAIL
  echo "----"
  echo "test-bash-zensu-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "B1 hook exists + executable" PASS || check "B1 hook exists + executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "B2 bash -n syntax check passes" PASS || check "B2 bash -n syntax check passes" FAIL

# Registered in hooks.json PreToolUse with a Bash matcher -> the new gate, and the
# old mcp matcher is gone (CLI-only cutover).
if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const ok=pres.some(e=>(e.matcher||"")==="Bash" && (e.hooks||[]).some(z=>/pre-bash-zensu-gate\.sh/.test(z.command||"")));
  const noMcp=!pres.some(e=>/mcp__plugin_zensu_zensu/.test(e.matcher||""));
  process.exit(ok && noMcp ? 0 : 1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "B3 registered as PreToolUse Bash matcher; mcp matcher removed" PASS
else
  check "B3 registered as PreToolUse Bash matcher; mcp matcher removed" FAIL
fi

grep -qF 'zensu_hook_enabled mcpGate' "$HOOK" \
  && check "B4 hook config-gated via zensu_hook_enabled mcpGate (default-on)" PASS \
  || check "B4 hook config-gated via zensu_hook_enabled mcpGate (default-on)" FAIL

# Reuses the classification SoT + the CLI->tool map rather than re-listing tools.
grep -qF 'zensu-mcp-tools.sh' "$HOOK" && grep -qF 'zensu-cli-map.sh' "$HOOK" \
  && check "B4b reuses zensu-mcp-tools.sh + zensu-cli-map.sh" PASS \
  || check "B4b reuses zensu-mcp-tools.sh + zensu-cli-map.sh" FAIL

# Build a PreToolUse Bash payload carrying tool_input.command.
payload() {
  CMD="$1" AT="${2:-}" SID="${3:-gate-test}" node -e '
    const o={hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.env.CMD},session_id:process.env.SID,cwd:"/tmp"};
    if(process.env.AT) o.agent_type=process.env.AT;
    process.stdout.write(JSON.stringify(o));
  '
}
classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("ALLOW");return;}
      try{
        const j=JSON.parse(s); const d=j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision;
        process.stdout.write(d==="deny"?"DENY":(d||"OTHER"));
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}
# run <label> <command> <agent_type> <expected> [state_dir]
run() {
  local label="$1" cmd="$2" at="$3" exp="$4" sd="${5:-}"
  local out
  out="$(payload "$cmd" "$at" gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ${sd:+TDD_STATE_DIR=$sd} bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}

CFG_ON="$(mktemp -t bashgate-on-XXXXXX)";   printf '%s' '{"hooks":{"mcpGate":true}}'  > "$CFG_ON"
CFG_OFF="$(mktemp -t bashgate-def-XXXXXX)";  printf '%s' '{"hooks":{}}'                 > "$CFG_OFF"
CFG_FALSE="$(mktemp -t bashgate-no-XXXXXX)"; printf '%s' '{"hooks":{"mcpGate":false}}' > "$CFG_FALSE"

run "B5 read (features get)"                "zensu features get f1"                                      '' ALLOW
run "B6 freelance mutation (classify)"      "zensu security classify f1 --classification confidential"   '' DENY
run "B7 mutation + zensu-plm agent"         "zensu security classify f1"                          zensu-plm ALLOW
run "B12 alias mutation (sec classify)"     "zensu sec classify f1"                                      '' DENY
run "B12b alias read (feature get)"         "zensu feature get f1"                                       '' ALLOW
run "B13a api GET"                          "zensu api GET /features"                                    '' ALLOW
run "B13b api POST (write)"                 "zensu api POST /features -f title=x"                        '' DENY
run "B13c api path-only (GET default)"      "zensu api /api/features"                                    '' ALLOW
run "B13d api path + -f (body=>POST)"       "zensu api /features -f title=x"                             '' DENY
run "B14 zensu-log.sh is not the CLI"       "bash /p/hooks/lib/zensu-log.sh --workflow-begin --tools x"  '' ALLOW
run "B15 echo merely mentions zensu"        "echo use zensu security classify please"                    '' ALLOW
run "B16 env-prefix mutation (link test)"   "FOO=bar zensu link test f1 --test-type unit --file a.go"    '' DENY
run "B17 auth login (neutral)"              "zensu auth login"                                           '' ALLOW
run "B17b version flag"                     "zensu --version"                                            '' ALLOW
run "B18 knowledge search (POST-but-read)"  "zensu knowledge search --query x"                           '' ALLOW
run "B25 compound: read && mutation"        "zensu features get f1 && zensu security classify f2"        '' DENY

# B8 workflow-active (skill running) -> mutation in declared set ALLOW
SDF="$(mktemp -d -t bashgate-wf-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDF" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_workflow_begin "$sid" "set_security_classification" "$(( $(date +%s) + 3600 ))"
' 2>/dev/null
run "B8 mutation + workflowActive (in set)" "zensu security classify f1"                                '' ALLOW "$SDF"
run "B27b out-of-scope mutation -> DENY"    "zensu link test f1 --test-type unit --file a.go"            '' DENY "$SDF"
rm -rf "$SDF"

# B9 env escape; B10 default-on; B11 explicit false
OUT="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B9 mutation + ZENSU_MCP_GATE=off -> ALLOW" PASS || check "B9 env escape (got '$OUT')" FAIL
OUT="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_OFF" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "B10 mutation, gate default-on (mcpGate absent) -> DENY" PASS || check "B10 default-on (got '$OUT')" FAIL
OUT="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_FALSE" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B11 mutation, mcpGate:false -> ALLOW" PASS || check "B11 explicit false (got '$OUT')" FAIL

# B19 deny-reason content (state-mutating wording + skill routing + mapped tool name; not "currently enabled")
REASON_OUT="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$REASON_OUT" | grep -qiF 'state-mutating' \
   && printf '%s' "$REASON_OUT" | grep -qF 'zensu:bootstrap' \
   && printf '%s' "$REASON_OUT" | grep -qF '/zensu:implement' \
   && printf '%s' "$REASON_OUT" | grep -qF '/zensu:security-review' \
   && printf '%s' "$REASON_OUT" | grep -qF 'set_security_classification' \
   && ! printf '%s' "$REASON_OUT" | grep -qiF 'currently enabled'; then
  check "B19 deny reason: state-mutating wording + skill routing + mapped tool" PASS
else
  check "B19 deny reason content" FAIL
fi

# B20 fail-open: empty + non-JSON + non-zensu command -> ALLOW
OUT="$(printf '' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
OUT2="$(printf '%s' 'not json at all' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
OUT3="$(payload 'git status' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT" = "ALLOW" ] && [ "$OUT2" = "ALLOW" ] && [ "$OUT3" = "ALLOW" ]; then
  check "B20 fail-open: empty + non-JSON + non-zensu -> ALLOW" PASS
else
  check "B20 fail-open (empty='$OUT' nonjson='$OUT2' nonzensu='$OUT3')" FAIL
fi

# B22 dual session-resolution: workflow under CLAUDE_SESSION_ID, payload session mismatched -> ALLOW
SDD="$(mktemp -d -t bashgate-dual-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDD" CLAUDE_SESSION_ID="skill-sess" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id "$CLAUDE_SESSION_ID")"
  tdd_workflow_begin "$sid" "set_security_classification" "$(( $(date +%s) + 3600 ))"
' 2>/dev/null
OUT="$(payload 'zensu security classify f1' '' other-sess | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDD" CLAUDE_SESSION_ID="skill-sess" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B22 dual session-resolution finds skill flag -> ALLOW" PASS || check "B22 dual-resolution (got '$OUT')" FAIL
rm -rf "$SDD"

# B23 representative mutations across nouns -> DENY (freelance)
M_FAIL=0
for c in \
  "zensu features create --product p --component c --title T" \
  "zensu roadmap create --product p --title R" \
  "zensu link test f1 --test-type unit --file a" \
  "zensu ghost apply s1" \
  "zensu wiki create --product p --title T --content X" \
  "zensu tiers set-feature f1 --tiers []"; do
  O="$(payload "$c" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
  [ "$O" = "DENY" ] || { M_FAIL=$((M_FAIL+1)); echo "      '$c' -> $O (expected DENY)"; }
done
[ "$M_FAIL" -eq 0 ] && check "B23 representative mutations freelance -> DENY" PASS || check "B23 mutation coverage ($M_FAIL)" FAIL

# B24 representative reads + telemetry -> ALLOW (freelance)
R_FAIL=0
for c in \
  "zensu features list --product p" \
  "zensu roadmap get r1" \
  "zensu security posture --product p" \
  "zensu journeys health --product p j1" \
  "zensu ghost candidates s1" \
  "zensu pulse summary s1" \
  "zensu knowledge search --query x"; do
  O="$(payload "$c" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
  [ "$O" = "ALLOW" ] || { R_FAIL=$((R_FAIL+1)); echo "      '$c' -> $O (expected ALLOW)"; }
done
[ "$R_FAIL" -eq 0 ] && check "B24 representative reads + telemetry -> ALLOW" PASS || check "B24 read coverage ($R_FAIL)" FAIL

# B28 parser hardening — disguised invocations must still gate (false-negative direction)
run "B28a wrapper command + mutation"        "command zensu security classify f1"                         '' DENY
run "B28b wrapper env + mutation"            "env zensu security classify f1"                             '' DENY
run "B28c wrapper sudo + mutation"           "sudo zensu security classify f1"                            '' DENY
run "B28d double-quoted zensu + mutation"    "\"zensu\" security classify f1"                             '' DENY
run "B28e backslash zensu + mutation"        "\\zensu security classify f1"                               '' DENY
run "B28f cmd-substitution mutation"         "zensu features get \$(zensu security classify f1)"          '' DENY
run "B28g assignment-substitution mutation"  "x=\$(zensu security classify f1 --foo bar)"                 '' DENY

# B29 api method/path fidelity
run "B29a api POST (path named POST = read)" "zensu api POST"                                             '' ALLOW
run "B29b api POST /features (write)"         "zensu api POST /features"                                   '' DENY
run "B29c api path + --data (write)"          "zensu api /features --data title=x"                         '' DENY
run "B29d api path + -d (write)"              "zensu api /features -d title=x"                             '' DENY

# B30 --api-url <value> must not be misread as the subcommand
run "B30 --api-url value + mutation"          "zensu --api-url https://h security classify f1"             '' DENY

# B31 compound where the mutation is not the first invocation
run "B31 reads then mutation (3rd invoc.)"    "zensu features get f1 && zensu features list --product p && zensu link test f1 --test-type unit --file a" '' DENY

# B32 stale-flag guard — after workflow-end / --tdd-reset, the same in-scope mutation DENIES again (ports the deleted MCP test's C19/C20)
SDR="$(mktemp -d -t bashgate-end-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDR" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_workflow_begin "$sid" "set_security_classification" "$(( $(date +%s) + 3600 ))"
  tdd_set_flag "$sid" workflowActive false
' 2>/dev/null
run "B32 mutation after workflow-end -> DENY" "zensu security classify f1"                                '' DENY "$SDR"
rm -rf "$SDR"

SDX="$(mktemp -d -t bashgate-rst-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDX" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_workflow_begin "$sid" "set_security_classification" "$(( $(date +%s) + 3600 ))"
  tdd_clear_session "$sid"
' 2>/dev/null
run "B32b mutation after --tdd-reset -> DENY" "zensu security classify f1"                                '' DENY "$SDX"
rm -rf "$SDX"

rm -f "$CFG_ON" "$CFG_OFF" "$CFG_FALSE"

echo "----"
echo "test-bash-zensu-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
