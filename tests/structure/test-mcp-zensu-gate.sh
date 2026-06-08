#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-mcp-zensu-gate.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/pre-mcp-zensu-gate.sh exists" FAIL
  echo "----"
  echo "test-mcp-zensu-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "C1 hook exists + executable" PASS || check "C1 hook exists + executable" FAIL
bash -n "$HOOK" 2>/dev/null && check "C2 bash -n syntax check passes" PASS || check "C2 bash -n syntax check passes" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const ok=pres.some(e=>/mcp__plugin_zensu_zensu/.test(e.matcher||"") && (e.hooks||[]).some(z=>/pre-mcp-zensu-gate\.sh/.test(z.command||"")));
  process.exit(ok?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "C3 registered in hooks.json PreToolUse with mcp matcher" PASS
else
  check "C3 registered in hooks.json PreToolUse with mcp matcher" FAIL
fi

grep -qF 'zensu_hook_enabled mcpGate' "$HOOK" \
  && check "C4 hook config-gated via zensu_hook_enabled mcpGate (default-on)" PASS \
  || check "C4 hook config-gated via zensu_hook_enabled mcpGate (default-on)" FAIL

payload() {
  TN="$1" AT="${2:-}" SID="${3:-gate-test}" node -e '
    const o={hook_event_name:"PreToolUse",tool_name:process.env.TN,tool_input:{},session_id:process.env.SID,cwd:"/tmp"};
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

CFG_ON="$(mktemp -t mcpgate-on-XXXXXX)";    printf '%s' '{"hooks":{"mcpGate":true}}'  > "$CFG_ON"
CFG_OFF="$(mktemp -t mcpgate-def-XXXXXX)";   printf '%s' '{"hooks":{}}'                 > "$CFG_OFF"
CFG_FALSE="$(mktemp -t mcpgate-no-XXXXXX)";  printf '%s' '{"hooks":{"mcpGate":false}}' > "$CFG_FALSE"
WRITE_TOOL="mcp__plugin_zensu_zensu__create_product"
READ_TOOL="mcp__plugin_zensu_zensu__list_features"

OUT="$(payload "$READ_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C5 gated read tool, gate on -> ALLOW" PASS || check "C5 read allow (got '$OUT')" FAIL

OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "C6 freelance main-thread write, gate on -> DENY" PASS || check "C6 freelance deny (got '$OUT')" FAIL

OUT="$(payload "$WRITE_TOOL" zensu-plm gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C7 write + agent_type (subagent) -> ALLOW" PASS || check "C7 subagent allow (got '$OUT')" FAIL

SDF="$(mktemp -d -t mcpgate-sd-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDF" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_set_flag "$sid" workflowActive true
' 2>/dev/null
OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDF" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C8 write + workflowActive flag (skill running) -> ALLOW" PASS || check "C8 flag allow (got '$OUT')" FAIL
rm -rf "$SDF"

OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C9 write + ZENSU_MCP_GATE=off -> ALLOW" PASS || check "C9 env escape (got '$OUT')" FAIL

OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_OFF" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "C10 write, gate default-on (mcpGate absent) -> DENY" PASS || check "C10 default-on (got '$OUT')" FAIL

OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_FALSE" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C11 write, mcpGate:false -> ALLOW" PASS || check "C11 explicit false (got '$OUT')" FAIL

rm -f "$CFG_ON" "$CFG_OFF" "$CFG_FALSE"

for sk in bootstrap ghost-scan; do
  F="$PLUGIN_DIR/skills/$sk/SKILL.md"
  if grep -qF -- '--workflow-begin' "$F" && grep -qF -- '--workflow-end' "$F"; then
    check "C12/$sk SKILL.md marks workflow (--workflow-begin/--workflow-end)" PASS
  else
    check "C12/$sk SKILL.md marks workflow (--workflow-begin/--workflow-end)" FAIL
  fi
done

if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(j.hooks && j.hooks.mcpGate === true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "C14 config.example.json hooks.mcpGate is true (default-on)" PASS
else
  check "C14 config.example.json hooks.mcpGate is true (default-on)" FAIL
fi

CFG2="$(mktemp -t mcpgate-on2-XXXXXX)"; printf '%s' '{"hooks":{"mcpGate":true}}' > "$CFG2"

OUT="$(payload "$WRITE_TOOL" general-purpose gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "C15 write + non-zensu-plm subagent -> DENY" PASS || check "C15 non-plm subagent (got '$OUT')" FAIL

OUT="$(payload "$WRITE_TOOL" "zensu:zensu-plm" gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C15b write + zensu-plm subagent (namespaced) -> ALLOW" PASS || check "C15b plm allow (got '$OUT')" FAIL

REASON_OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$REASON_OUT" | grep -qF 'zensu:bootstrap' \
   && printf '%s' "$REASON_OUT" | grep -qF 'create_product' \
   && ! printf '%s' "$REASON_OUT" | grep -qiF 'currently enabled'; then
  check "C16 deny reason names skills + tool, drops contradictory parenthetical" PASS
else
  check "C16 deny reason content" FAIL
fi

G_FAIL=0
for t in create_product create_product_vision apply_bootstrap ghost_apply create_feature; do
  O="$(payload "mcp__plugin_zensu_zensu__$t" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
  [ "$O" = "DENY" ] || { G_FAIL=$((G_FAIL+1)); echo "      $t -> $O (expected DENY)"; }
done
[ "$G_FAIL" -eq 0 ] && check "C17 all 5 gated tools freelance -> DENY" PASS || check "C17 gated-tool coverage ($G_FAIL)" FAIL

OUT="$(payload "mcp__plugin_zensu_zensu__update_feature" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C18 non-gated zensu write (update_feature) -> ALLOW" PASS || check "C18 non-gated allow (got '$OUT')" FAIL

SDR="$(mktemp -d -t mcpgate-rst-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDR" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_set_flag "$sid" workflowActive true
  tdd_clear_session "$sid"
' 2>/dev/null
OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "C19 --tdd-reset clears workflowActive -> DENY" PASS || check "C19 reset clears flag (got '$OUT')" FAIL
rm -rf "$SDR"

SDE="$(mktemp -d -t mcpgate-end-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDE" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_set_flag "$sid" workflowActive true
  tdd_set_flag "$sid" workflowActive false
' 2>/dev/null
OUT="$(payload "$WRITE_TOOL" '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDE" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "C20 workflowActive cleared (workflow-end) -> DENY" PASS || check "C20 re-arm (got '$OUT')" FAIL
rm -rf "$SDE"

OUT="$(printf '' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
OUT2="$(printf '%s' 'not json at all' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT" = "ALLOW" ] && [ "$OUT2" = "ALLOW" ]; then
  check "C21 fail-open: empty + non-JSON payload -> ALLOW" PASS
else
  check "C21 fail-open (empty='$OUT' nonjson='$OUT2')" FAIL
fi

SDD="$(mktemp -d -t mcpgate-dual-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDD" CLAUDE_SESSION_ID="skill-sess" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id "$CLAUDE_SESSION_ID")"
  tdd_set_flag "$sid" workflowActive true
' 2>/dev/null
OUT="$(payload "$WRITE_TOOL" '' other-sess | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" TDD_STATE_DIR="$SDD" CLAUDE_SESSION_ID="skill-sess" ZENSU_CONFIG="$CFG2" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "C22 dual session-resolution finds skill flag despite payload mismatch -> ALLOW" PASS || check "C22 dual-resolution (got '$OUT')" FAIL
rm -rf "$SDD"

rm -f "$CFG2"

echo "----"
echo "test-mcp-zensu-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
