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
  const reg=require(process.argv[2]);
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const covers=(e,tool)=>reg.hostMatcherCovers(e.matcher,tool)===reg.REGISTRATION.REGISTERED;
  const ok=pres.some(e=>covers(e,"Bash") && covers(e,"PowerShell") && !covers(e,"Read") && (e.hooks||[]).some(z=>/pre-bash-zensu-gate\.sh/.test(z.command||"")));
  const noMcp=!pres.some(e=>/mcp__plugin_zensu_zensu/.test(e.matcher||""));
  process.exit(ok && noMcp ? 0 : 1);
' "$HOOKS_JSON" "$PLUGIN_DIR/hooks/lib/hook-registration-v1.js" 2>/dev/null; then
  check "B3 registered on a PreToolUse matcher covering Bash and PowerShell; mcp matcher removed" PASS
else
  check "B3 registered on a PreToolUse matcher covering Bash and PowerShell; mcp matcher removed" FAIL
fi

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const pres=(h.hooks&&h.hooks.PreToolUse)||[];
  const regs=pres.flatMap(e=>(e.hooks||[]).filter(z=>/pre-bash-zensu-gate\.sh/.test(z.command||"")));
  process.exit(regs.length===1 && regs[0].timeout===60 ? 0 : 1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "B3b registration carries the 60 s gate timeout" PASS
else
  check "B3b registration carries the 60 s gate timeout" FAIL
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
  CMD="$1" AT="${2:-}" SID="${3:-gate-test}" TOOL="${4:-Bash}" node -e '
    const o={hook_event_name:"PreToolUse",tool_name:process.env.TOOL,tool_input:{command:process.env.CMD},session_id:process.env.SID,cwd:"/tmp"};
    if(process.env.AT) { o.agent_id="gate-subagent-1"; o.agent_type=process.env.AT; }
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
  out="$(payload "$cmd" "$at" gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ${sd:+STATE_DIR=$sd} bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}
large_payload() {
  node -e '
    const o={hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"zensu security classify f1 --reason \x27"+"a".repeat(700000)+"\x27"},session_id:"gate-test",cwd:"/tmp"};
    if(process.argv[2]) { o.agent_id="gate-subagent-1"; o.agent_type=process.argv[2]; }
    require("fs").writeFileSync(process.argv[1], JSON.stringify(o));
  ' "$1" "${2:-}"
}
run_large() {
  env LARGE_PAD_A="$LARGE_PAD" LARGE_PAD_B="$LARGE_PAD" LARGE_PAD_C="$LARGE_PAD" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$1" 2>/dev/null
}

CFG_ON="$(mktemp -t bashgate-on-XXXXXX)";   printf '%s' '{"hooks":{"mcpGate":true}}'  > "$CFG_ON"
CFG_OFF="$(mktemp -t bashgate-def-XXXXXX)";  printf '%s' '{"hooks":{}}'                 > "$CFG_OFF"
CFG_FALSE="$(mktemp -t bashgate-no-XXXXXX)"; printf '%s' '{"hooks":{"mcpGate":false}}' > "$CFG_FALSE"
PROJECT="$(mktemp -d -t bashgate-project-XXXXXX)"
export CLAUDE_PROJECT_DIR="$PROJECT"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" gate-test
LARGE_PAD=
if [ "$(uname -s)" = Darwin ]; then
  LARGE_PAD="$(node -e 'process.stdout.write("p".repeat(125000))')"
fi
LARGE_MAIN="$PROJECT/large-main.json"
LARGE_SUB="$PROJECT/large-subagent.json"
large_payload "$LARGE_MAIN"
large_payload "$LARGE_SUB" general-purpose

run "B5 read (features get)"                "zensu features get f1"                                      '' ALLOW
run "B6 freelance mutation (classify)"      "zensu security classify f1 --classification confidential"   '' DENY
run "B7 neutral zensu-plm has no mutation exemption" "zensu security classify f1"                    zensu-plm DENY
run "B12 alias mutation (sec classify)"     "zensu sec classify f1"                                      '' DENY
run "B12b alias read (feature get)"         "zensu feature get f1"                                       '' ALLOW
run "B13 api passthrough removed (ungated)" "zensu api POST /features -f title=x"                        '' ALLOW
run "B14 zensu-log.sh is not the CLI"       "bash /p/hooks/lib/zensu-log.sh --workflow-begin --tools x"  '' ALLOW
run "B15 echo merely mentions zensu"        "echo use zensu security classify please"                    '' ALLOW
run "B16 env-prefix mutation (link test)"   "FOO=bar zensu link test f1 --test-type unit --file a.go"    '' DENY
run "B17 auth login (neutral)"              "zensu auth login"                                           '' ALLOW
run "B17b version flag"                     "zensu --version"                                            '' ALLOW
run "B18 knowledge search (POST-but-read)"  "zensu knowledge search --query x"                           '' ALLOW
run "B25 compound: read && mutation"        "zensu features get f1 && zensu security classify f2"        '' DENY
LARGE_OUT="$(run_large "$LARGE_MAIN")"
if [ "$(printf '%s' "$LARGE_OUT" | classify)" = "DENY" ] \
   && printf '%s' "$LARGE_OUT" | grep -qF "maps to 'set_security_classification'"; then
  check "B40 a mutation in a payload over the exec size limit is still parsed and denied" PASS
else
  check "B40 oversized-payload mutation (got '$(printf '%s' "$LARGE_OUT" | cut -c1-160)')" FAIL
fi

PAYLOAD_LIMIT="$(node -e 'const cap = require(process.argv[1]).MAX_PAYLOAD_BYTES; process.stdout.write(Number.isSafeInteger(cap) ? String(cap) : "")' "$PLUGIN_DIR/hooks/lib/claude-hook-session-v1.js" 2>/dev/null)"
[ -n "$PAYLOAD_LIMIT" ] && check "B48 the binder exports the payload limit it enforces" PASS \
  || check "B48 the binder exports the payload limit it enforces" FAIL
LIMIT="${PAYLOAD_LIMIT:-1048576}"
sized_payload() {
  node -e '
    const [file, total, prefix, agent, tool] = process.argv.slice(1);
    const shell = tool || "Bash";
    const base = { hook_event_name: "PreToolUse", tool_name: shell, tool_input: { command: prefix + (shell === "Bash" ? " && : " : "; # ") }, session_id: "gate-test", cwd: "/tmp" };
    if (agent) { base.agent_id = "gate-subagent-1"; base.agent_type = agent; }
    base.tool_input.command += "a".repeat(Number(total) - Buffer.byteLength(JSON.stringify(base)));
    require("fs").writeFileSync(file, JSON.stringify(base));
  ' "$1" "$2" "$3" "${4:-}" "${5:-}"
}
size_denied() {
  printf '%s' "$1" | grep -qF '"permissionDecision":"deny"' \
    && printf '%s' "$1" | grep -qF "payload is $2 bytes, over the ${LIMIT}-byte limit" \
    && ! printf '%s' "$1" | grep -qF 'binding is unavailable or invalid'
}
SIZED_AT="$PROJECT/sized-at-limit.json"
SIZED_OVER="$PROJECT/sized-over-limit.json"
SIZED_MUTATION="$PROJECT/sized-mutation.json"
SIZED_SUBAGENT="$PROJECT/sized-subagent.json"
SIZED_PLAIN="$PROJECT/sized-plain.json"
sized_payload "$SIZED_AT" "$LIMIT" "zensu features get f1"
sized_payload "$SIZED_OVER" "$((LIMIT + 1))" "zensu features get f1"
sized_payload "$SIZED_MUTATION" "$((LIMIT + 150000))" "zensu security classify f1"
sized_payload "$SIZED_SUBAGENT" "$((LIMIT + 150000))" "zensu security classify f1" general-purpose
sized_payload "$SIZED_PLAIN" "$((LIMIT + 150000))" "echo hello"
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_AT" 2>/dev/null | classify)"
[ "$OUT" = ALLOW ] && check "B48a a read in a payload of exactly the limit is bound and allowed" PASS \
  || check "B48a read at the payload limit (got '$OUT')" FAIL
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_OVER" 2>/dev/null)"
size_denied "$OUT" "$((LIMIT + 1))" \
  && check "B48b a read one byte over the limit is denied with a reason that names its size and the limit, not a broken binding" PASS \
  || check "B48b read one byte over the limit (got '$(printf '%s' "$OUT" | cut -c1-200)')" FAIL
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_MUTATION" 2>/dev/null)"
OUT_SUB="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_SUBAGENT" 2>/dev/null)"
if size_denied "$OUT" "$((LIMIT + 150000))" && size_denied "$OUT_SUB" "$((LIMIT + 150000))"; then
  check "B48c an oversized mutation gets the same size deny on the main thread and in a subagent" PASS
else
  check "B48c oversized mutation (main '$(printf '%s' "$OUT" | cut -c1-120)' subagent '$(printf '%s' "$OUT_SUB" | cut -c1-120)')" FAIL
fi
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_PLAIN" 2>/dev/null | classify)"
[ "$OUT" = ALLOW ] && check "B48e an oversized command that names no zensu invocation stays outside this gate" PASS \
  || check "B48e oversized non-zensu command (got '$OUT')" FAIL
SIZED_PS_MUTATION="$PROJECT/sized-ps-mutation.json"
SIZED_PS_PLAIN="$PROJECT/sized-ps-plain.json"
sized_payload "$SIZED_PS_MUTATION" "$((LIMIT + 150000))" "zensu security classify f1" "" PowerShell
sized_payload "$SIZED_PS_PLAIN" "$((LIMIT + 150000))" "Get-ChildItem" "" PowerShell
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_PS_MUTATION" 2>/dev/null)"
size_denied "$OUT" "$((LIMIT + 150000))" \
  && check "B48f an oversized PowerShell command that names zensu gets the same size deny through the bind" PASS \
  || check "B48f oversized PowerShell zensu command (got '$(printf '%s' "$OUT" | cut -c1-200)')" FAIL
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_PS_PLAIN" 2>/dev/null | classify)"
[ "$OUT" = ALLOW ] && check "B48g an oversized PowerShell command that names no zensu stays outside this gate" PASS \
  || check "B48g oversized PowerShell command without zensu (got '$OUT')" FAIL

# B8 workflow-active (skill running) -> mutation in declared set ALLOW
source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
tdd_workflow_begin gate-test "set_security_classification" "$(( $(date +%s) + 3600 ))" 2>/dev/null
run "B8 mutation + workflowActive (in set)" "zensu security classify f1"                                '' ALLOW
run "B8a arbitrary subagent cannot borrow the active main workflow window" "zensu security classify f1" general-purpose DENY
run "B8b arbitrary subagent keeps Zensu CLI reads" "zensu features get f1" general-purpose ALLOW
LARGE_OUT="$(run_large "$LARGE_SUB")"
if [ "$(printf '%s' "$LARGE_OUT" | classify)" = "DENY" ] \
   && printf '%s' "$LARGE_OUT" | grep -qF 'reserved for the interactive main thread'; then
  check "B40b a subagent mutation in a payload over the exec size limit cannot borrow the active main workflow window" PASS
else
  check "B40b oversized subagent payload (got '$(printf '%s' "$LARGE_OUT" | cut -c1-160)')" FAIL
fi
run "B27b out-of-scope mutation -> DENY"    "zensu link test f1 --test-type unit --file a.go"            '' DENY
tdd_workflow_begin gate-test "approve_work_plan,send_work_order_heartbeat,create_mock" "$(( $(date +%s) + 3600 ))" 2>/dev/null
run "B47a a window that declares a human decision does not let it through" "zensu plan approve p1"        '' DENY
run "B47b a window that declares a work-order verb does not let it through" "zensu work heartbeat o1"     '' DENY
run "B47c the same window still lets a declared ordinary mutation through"  "zensu mocks create f1 m.png" '' ALLOW
tdd_set_flag gate-test workflowActive false >/dev/null 2>&1

tdd_workflow_begin gate-test "set_security_classification,link_test" "$(( $(date +%s) + 3600 ))" 2>/dev/null
SHIM_DIR="$PROJECT/node-shim"
mkdir -p "$SHIM_DIR"
printf '#!/bin/bash\nprintf x >> "$NODE_SPAWN_LOG"\nexec %s "$@"\n' "$(printf '%q' "$(command -v node)")" > "$SHIM_DIR/node"
chmod +x "$SHIM_DIR/node"
node_spawns() {
  local log="$PROJECT/node-spawns.log" decision
  : > "$log"
  decision="$(payload "$1" '' gate-test | env PATH="$SHIM_DIR:$PATH" NODE_SPAWN_LOG="$log" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
  printf '%s:%s' "$decision" "$(wc -c < "$log" | tr -d ' ')"
}
SPAWNS_ONE="$(node_spawns 'zensu security classify f1')"
SPAWNS_THREE="$(node_spawns 'zensu security classify f1 && zensu link test f1 --test-type unit --file a && zensu security classify f2')"
if [ "${SPAWNS_ONE%%:*}" = ALLOW ] && [ "${SPAWNS_THREE%%:*}" = ALLOW ] \
   && [ "${SPAWNS_ONE#*:}" -gt 0 ] && [ "${SPAWNS_ONE#*:}" = "${SPAWNS_THREE#*:}" ]; then
  check "B50 three workflow-allowed mutations of two tools spawn as many node children as one, so the workflow is read once per run" PASS
else
  check "B50 workflow read once per run (decision:node-spawns one=$SPAWNS_ONE three=$SPAWNS_THREE)" FAIL
fi
tdd_set_flag gate-test workflowActive false >/dev/null 2>&1

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
SUB_REASON_OUT="$(payload 'zensu security classify f1' general-purpose gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$SUB_REASON_OUT" | grep -qF '"permissionDecision":"deny"' \
   && printf '%s' "$SUB_REASON_OUT" | grep -qF 'set_security_classification' \
   && printf '%s' "$SUB_REASON_OUT" | grep -qF 'reserved for the interactive main thread' \
   && printf '%s' "$SUB_REASON_OUT" | grep -qF 'Report the operation you need to the main thread' \
   && printf '%s' "$SUB_REASON_OUT" | grep -qF '/zensu:security-review' \
   && ! printf '%s' "$SUB_REASON_OUT" | grep -qF 'ZENSU_MCP_GATE' \
   && ! printf '%s' "$SUB_REASON_OUT" | grep -qF 'prefix the command with' \
   && ! printf '%s' "$SUB_REASON_OUT" | grep -qF 'in the interactive main thread. For a deliberate one-off'; then
  check "B19b subagent deny reason: reports the operation to the main thread and names no escape" PASS
else
  check "B19b subagent deny reason content" FAIL
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

# B22 Session Control authorization is single-session. An ambient legacy
# CLAUDE_SESSION_ID must never donate another session's workflow grant to the
# current hook payload; the exact current payload session remains authorized.
# A missing payload session is denied: hook subprocesses do not inherit the
# SessionStart export block, so ambient ZENSU_SESSION_KEY is never authority.
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" skill-sess
tdd_workflow_begin skill-sess "set_security_classification" "$(( $(date +%s) + 3600 ))" 2>/dev/null
OUT="$(payload 'zensu security classify f1' '' other-sess | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_SESSION_ID="skill-sess" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "B22a foreign CLAUDE_SESSION_ID workflow cannot authorize current payload -> DENY" PASS || check "B22a cross-session isolation (got '$OUT')" FAIL
OUT="$(payload 'zensu security classify f1' '' skill-sess | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_SESSION_ID="foreign-ambient" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B22b exact current payload workflow remains authorized -> ALLOW" PASS || check "B22b exact-current authorization (got '$OUT')" FAIL
SKILL_SESSION_KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key skill-sess)"
PAYLOAD_NO_SESSION="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"zensu security classify f1"},cwd:"/tmp"}))')"
OUT="$(printf '%s' "$PAYLOAD_NO_SESSION" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_SESSION_ID="foreign-ambient" ZENSU_SESSION_KEY="$SKILL_SESSION_KEY" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "B22c omitted payload session cannot use ambient exported key -> DENY" PASS || check "B22c missing-payload authorization (got '$OUT')" FAIL

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
  "zensu security posture p" \
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

run "B38a timeout wrapper + mutation"                 "timeout 60 zensu security classify f1"                  '' DENY
run "B38b subagent timeout wrapper + mutation"        "timeout 60 zensu security classify f1"                  general-purpose DENY
run "B38c subagent nice -n + mutation"                "nice -n 5 zensu security classify f1"                   general-purpose DENY
run "B38d subagent env -i + mutation"                 "env -i zensu security classify f1"                      general-purpose DENY
run "B38e subagent xargs + mutation"                  "printf 'f1\\n' | xargs -n1 zensu security classify"     general-purpose DENY
run "B38f subagent loop body + mutation"              "for id in f1; do zensu security classify \"\$id\"; done" general-purpose DENY
run "B38g subagent bash -c body + mutation"           "bash -c \"zensu security classify f1\""                 general-purpose DENY
run "B38h subagent eval body + mutation"              "eval \"zensu security classify f1\""                    general-purpose DENY
run "B38i subagent wrapped read"                      "timeout 60 zensu features get f1"                       general-purpose ALLOW
run "B38j search text that names a mutation"          "grep -rn \"zensu security classify\" skills"            general-purpose ALLOW
run "B38l inline off reaches a wrapped main-thread mutation" "ZENSU_MCP_GATE=off timeout 60 zensu security classify f1" '' ALLOW
run "B38m substitution inside a parameter expansion"   "FEATURE_ID=\${FEATURE_ID:-\$(zensu features create --product p --title T)}" '' DENY
run "B38n subagent substitution inside a parameter expansion" "FEATURE_ID=\${FEATURE_ID:-\$(zensu features create --product p --title T)}" general-purpose DENY
run "B38o subagent remote command string"              "ssh deploy@host \"cd /srv/app && zensu security classify f1\"" general-purpose DENY
run "B38p subagent container shell string"             "docker compose exec api sh -c \"cd /app && zensu security classify f1\"" general-purpose DENY

FALLBACK_BASE="$(mktemp -d -t bashgate-fallback-XXXXXX)"
FALLBACK_ROOT="$FALLBACK_BASE/plugin"
mkdir -p "$FALLBACK_ROOT" "$FALLBACK_BASE/project"
for part in hooks agents skills docs templates scripts .claude-plugin; do
  [ -e "$PLUGIN_DIR/$part" ] && cp -R "$PLUGIN_DIR/$part" "$FALLBACK_ROOT/$part"
done
rm -f "$FALLBACK_ROOT/hooks/lib/subagent-shell-guard-v1.js"
FALLBACK_OUT="$(
  export CLAUDE_PROJECT_DIR="$FALLBACK_BASE/project"
  ZENSU_TEST_PLUGIN_DATA="$FALLBACK_BASE/plugin-data" source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" fallback-gate "$FALLBACK_ROOT" || exit 1
  printf 'BOUND\n'
  for cmd in 'zensu security classify f1' 'zensu features get f1' 'timeout 60 zensu security classify f1'; do
    payload "$cmd" '' fallback-gate | env CLAUDE_PLUGIN_ROOT="$FALLBACK_ROOT" ZENSU_CONFIG="$CFG_ON" bash "$FALLBACK_ROOT/hooks/pre-bash-zensu-gate.sh" 2>/dev/null | tr -d '\n'
    printf '\n<<%s>>\n' "$cmd"
  done
)"
FALLBACK_BOUND="$(printf '%s\n' "$FALLBACK_OUT" | sed -n '1p')"
FALLBACK_DENY="$(printf '%s\n' "$FALLBACK_OUT" | sed -n '2p')"
FALLBACK_READ="$(printf '%s\n' "$FALLBACK_OUT" | sed -n '4p')"
FALLBACK_WRAPPED="$(printf '%s\n' "$FALLBACK_OUT" | sed -n '6p')"
if [ "$FALLBACK_BOUND" = "BOUND" ] && [ ! -e "$FALLBACK_ROOT/hooks/lib/subagent-shell-guard-v1.js" ] \
   && printf '%s' "$FALLBACK_DENY" | grep -qF "maps to 'set_security_classification'"; then
  check "B39a without the shell-model module the token scan still gates a mutation" PASS
else
  check "B39a module-less fallback mutation (bound='$FALLBACK_BOUND' got '$FALLBACK_DENY')" FAIL
fi
[ "$FALLBACK_BOUND" = "BOUND" ] && [ -z "$FALLBACK_READ" ] && check "B39b the module-less copy is bound, so a read passes" PASS \
  || check "B39b module-less read (bound='$FALLBACK_BOUND' got '$FALLBACK_READ')" FAIL
[ "$FALLBACK_BOUND" = "BOUND" ] && [ -z "$FALLBACK_WRAPPED" ] && check "B39c the token scan alone does not see a wrapped mutation, so the module was absent" PASS \
  || check "B39c module-less wrapped mutation (bound='$FALLBACK_BOUND' got '$FALLBACK_WRAPPED')" FAIL
PARSER_SENTINEL="$FALLBACK_BASE/parser-loaded"
node -e 'require("fs").writeFileSync(process.argv[1], "require(\"fs\").writeFileSync(" + JSON.stringify(process.argv[2]) + ", \"loaded\");\nmodule.exports = { commandInvocations: () => [] };\n")' \
  "$FALLBACK_ROOT/hooks/lib/subagent-shell-guard-v1.js" "$PARSER_SENTINEL"
FALLBACK_OVERSIZED="$(CLAUDE_PLUGIN_ROOT="$FALLBACK_ROOT" ZENSU_CONFIG="$CFG_ON" bash "$FALLBACK_ROOT/hooks/pre-bash-zensu-gate.sh" < "$SIZED_OVER" 2>/dev/null)"
PARSER_LOADED_OVERSIZED=no
[ -e "$PARSER_SENTINEL" ] && PARSER_LOADED_OVERSIZED=yes
payload 'zensu features get f1' '' parser-probe | env CLAUDE_PLUGIN_ROOT="$FALLBACK_ROOT" ZENSU_CONFIG="$CFG_ON" bash "$FALLBACK_ROOT/hooks/pre-bash-zensu-gate.sh" >/dev/null 2>&1
PARSER_LOADED_SMALL=no
[ -e "$PARSER_SENTINEL" ] && PARSER_LOADED_SMALL=yes
if size_denied "$FALLBACK_OVERSIZED" "$((LIMIT + 1))" && [ "$PARSER_LOADED_OVERSIZED" = no ] && [ "$PARSER_LOADED_SMALL" = yes ]; then
  check "B48d the size is compared before the parser runs: an oversized payload never loads the shell-model module, an ordinary one does" PASS
else
  check "B48d size check before the parser (oversized loaded=$PARSER_LOADED_OVERSIZED small loaded=$PARSER_LOADED_SMALL got '$(printf '%s' "$FALLBACK_OVERSIZED" | cut -c1-120)')" FAIL
fi
rm -rf "$FALLBACK_BASE"

# B30 --api-url <value> must not be misread as the subcommand
run "B30 --api-url value + mutation"          "zensu --api-url https://h security classify f1"             '' DENY

# B31 compound where the mutation is not the first invocation
run "B31 reads then mutation (3rd invoc.)"    "zensu features get f1 && zensu features list --product p && zensu link test f1 --test-type unit --file a" '' DENY

# B32 stale-flag guard — after workflow-end / --tdd-reset, the same in-scope mutation DENIES again (ports the deleted MCP test's C19/C20)
SDR="$(mktemp -d -t bashgate-end-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" STATE_DIR="$SDR" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_workflow_begin "$sid" "set_security_classification" "$(( $(date +%s) + 3600 ))"
  tdd_set_flag "$sid" workflowActive false
' 2>/dev/null
run "B32 mutation after workflow-end -> DENY" "zensu security classify f1"                                '' DENY "$SDR"
rm -rf "$SDR"

SDX="$(mktemp -d -t bashgate-rst-XXXXXX)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" STATE_DIR="$SDX" bash -c '
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  sid="$(zensu_resolve_session_id gate-test)"
  tdd_workflow_begin "$sid" "set_security_classification" "$(( $(date +%s) + 3600 ))"
  tdd_clear_session "$sid"
' 2>/dev/null
run "B32b mutation after --tdd-reset -> DENY" "zensu security classify f1"                                '' DENY "$SDX"
rm -rf "$SDX"

# B33–B36 gate-narrowing: reads/--help, inline ZENSU_MCP_GATE=off, localhost-skip
run "B33 mutation + --help (a read) -> ALLOW"      "zensu security classify f1 --help"                          '' ALLOW
run "B33b mutation + -h (a read) -> ALLOW"         "zensu features create -h"                                   '' ALLOW
run "B34 inline ZENSU_MCP_GATE=off -> ALLOW"       "ZENSU_MCP_GATE=off zensu security classify f1"              '' ALLOW
run "B34b inline gate value not 'off' -> DENY"     "ZENSU_MCP_GATE=on zensu security classify f1"               '' DENY
run "B34c subagent inline ZENSU_MCP_GATE=off -> DENY" "ZENSU_MCP_GATE=off zensu security classify f1"           general-purpose DENY
run "B34d subagent inline off keeps reads"         "ZENSU_MCP_GATE=off zensu features get f1"                   general-purpose ALLOW
run "B35 --api-url localhost -> ALLOW"             "zensu --api-url http://localhost:8090 security classify f1" '' ALLOW
run "B35b inline ZENSU_API_URL 127.0.0.1 -> ALLOW" "ZENSU_API_URL=http://127.0.0.1:8090 zensu security classify f1" '' ALLOW
run "B35c --api-url prod still -> DENY"            "zensu --api-url https://api.zensu.dev security classify f1" '' DENY

# B36 localhost / prod via the hook's own ZENSU_API_URL process env
OUT="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_API_URL=http://localhost:8090 bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B36 process-env ZENSU_API_URL=localhost -> ALLOW" PASS || check "B36 process-env localhost (got '$OUT')" FAIL
OUT="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_API_URL=https://api.zensu.dev bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "B36b process-env ZENSU_API_URL=prod -> DENY" PASS || check "B36b process-env prod (got '$OUT')" FAIL

# B37 deny-reason advertises the narrowed escapes (inline off + localhost)
REASON_N="$(payload 'zensu security classify f1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$REASON_N" | grep -qF 'ZENSU_MCP_GATE=off' && printf '%s' "$REASON_N" | grep -qiF 'localhost'; then
  check "B37 deny reason advertises inline-off + localhost escapes" PASS
else
  check "B37 deny reason narrowed-escape wording" FAIL
fi
REASON_S="$(payload 'ZENSU_MCP_GATE=off zensu security classify f1' general-purpose gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$REASON_S" | grep -qF 'never a route for a subagent. Do not retry this command, with or without a prefix.' \
   && ! printf '%s' "$REASON_S" | grep -qF 'prefix the command with ZENSU_MCP_GATE=off' \
   && ! printf '%s' "$REASON_S" | grep -qF 'ZENSU_API_URL' \
   && ! printf '%s' "$REASON_N" | grep -qF 'never a route for a subagent'; then
  check "B37b subagent deny reason withdraws the inline escapes; the main-thread reason does not" PASS
else
  check "B37b subagent deny reason must name the withdrawn inline escape" FAIL
fi

parser_lines() {
  node -e '
    const fs = require("fs");
    const { spawnSync } = require("child_process");
    const [hook, binder, guard] = process.argv.slice(1);
    const source = fs.readFileSync(hook, "utf8");
    const begin = source.indexOf("INVOCATIONS=");
    const open = begin < 0 ? -1 : source.indexOf("node -e \x27", begin);
    const close = open < 0 ? -1 : source.indexOf("\n\x27 2>/dev/null)", open);
    if (close < 0) { process.stdout.write("UNEXTRACTABLE"); process.exit(0); }
    const command = fs.readFileSync(0, "utf8");
    const run = spawnSync(process.execPath, ["-e", source.slice(open + "node -e \x27".length, close)], {
      input: JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command }, session_id: "gate-test", cwd: "/tmp" }),
      encoding: "utf8",
      timeout: 15000,
      maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, ZAPI: "", ZGUARD: guard, ZBIND: binder },
    });
    if (run.error || run.status !== 0) { process.stdout.write("NO-ANSWER " + (run.error ? run.error.code : run.status)); process.exit(0); }
    process.stdout.write(run.stdout);
  ' "$HOOK" "$PLUGIN_DIR/hooks/lib/claude-hook-session-v1.js" "${1:-$PLUGIN_DIR/hooks/lib/subagent-shell-guard-v1.js}"
}
TAB="$(printf '\t')"
LINES_ONE="$(printf '%s' 'zensu features get f1' | parser_lines)"
LINES_MIXED="$(printf '%s' 'zensu features get f1 && zensu features get f1 && zensu security classify f2' | parser_lines)"
if [ "$LINES_ONE" = "features${TAB}get${TAB}f1" ] && [ "$LINES_MIXED" = "features${TAB}get${TAB}f1
security${TAB}classify${TAB}f2" ]; then
  check "B49 the parser emits each distinct invocation once, although the walker and the token scan both find it" PASS
else
  check "B49 deduplicated invocation lines (one='$LINES_ONE' mixed='$LINES_MIXED')" FAIL
fi
NO_GUARD="$PROJECT/no-shell-model.js"
LINES_TOKEN="$(node -e 'process.stdout.write("zensu features get f1; x" + "\x27".repeat(600000) + "y")' | parser_lines "$NO_GUARD")"
LINES_PREFIX="$(node -e 'process.stdout.write("A=x" + "\x27".repeat(600000) + "y zensu features get f1")' | parser_lines "$NO_GUARD")"
LINES_URL="$(node -e 'process.stdout.write("zensu --api-url x" + "\x27".repeat(600000) + "y features get f1")' | parser_lines "$NO_GUARD")"
if [ "$LINES_TOKEN" = "features${TAB}get${TAB}f1" ] && [ "$LINES_PREFIX" = "features${TAB}get${TAB}f1" ] && [ "$LINES_URL" = "features${TAB}get${TAB}f1" ]; then
  check "B51 the token scan trims quotes in linear time: a 600000-quote command word, assignment value and --api-url value each finish within 15 s" PASS
else
  check "B51 linear quote trim (word='$LINES_TOKEN' prefix='$LINES_PREFIX' url='$LINES_URL')" FAIL
fi

source "$PLUGIN_DIR/hooks/lib/zensu-mcp-tools.sh"
source "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
MAP_FAIL=0
while IFS='|' read -r m_noun m_verb m_third m_tool m_class; do
  [ -n "$m_noun" ] || continue
  m_got="$(zensu_cli_to_tool "$m_noun" "$m_verb" "$m_third")"
  m_cls=none
  if [ -n "$m_got" ]; then
    if zensu_is_read_tool "$m_got"; then m_cls=read
    elif zensu_is_human_decision_tool "$m_got"; then m_cls=human
    elif zensu_is_work_order_tool "$m_got"; then m_cls=workorder
    elif zensu_is_mutation_tool "$m_got"; then m_cls=mutation
    else m_cls=unclassified
    fi
  fi
  if [ "$m_got" != "$m_tool" ] || [ "$m_cls" != "$m_class" ]; then
    MAP_FAIL=$((MAP_FAIL+1)); echo "      zensu $m_noun $m_verb $m_third -> '$m_got' ($m_cls), want '$m_tool' ($m_class)"
  fi
done <<'MAP'
mocks|create||create_mock|mutation
mocks|list||list_mocks|read
mocks|get||get_mock|read
design|context||get_design_context|read
journeys|step-update||update_journey_step|mutation
journeys|step-delete||delete_journey_step|mutation
work|create||create_work_order|human
work|list||list_work_orders|read
work|get||get_work_order|read
work|events||list_work_order_events|read
work|approve||approve_work_order|human
work|requeue||requeue_work_order|human
work|cancel||cancel_work_order|human
work|confirm-merge||confirm_work_order_merge|human
work|claim||claim_work_order|workorder
work|confirm||confirm_work_order_claim|workorder
work|release||release_work_order|workorder
work|usage||report_work_order_usage|workorder
work|heartbeat||send_work_order_heartbeat|workorder
work|event||send_work_order_event|workorder
work|ask||ask_work_order_question|workorder
work|followup||report_work_order_followup|workorder
work|answer||answer_work_question|human
work|overturn||overturn_work_answer|human
work|questions||list_work_questions|read
work|policy|get|get_automation_policy|read
work|policy|set|set_automation_policy|human
work|policy|||none
work|repositories|list|list_product_repositories|read
work|repos|list|list_product_repositories|read
work|repositories|add|add_product_repository|human
work|repositories|update|update_product_repository|human
work|repos|remove|remove_product_repository|human
work|repositories|||none
plan|push||push_work_plan|human
plan|status||get_work_plan|read
plan|list||list_work_plans|read
plan|approve||approve_work_plan|human
plan|finalize||finalize_work_plan|human
plan|abandon||abandon_work_plan|human
plan|confirm-merge||confirm_work_plan_merge|human
plan|followups||list_work_plan_followups|read
plan|followup|accept|accept_work_plan_followup|human
plan|followup|dismiss|dismiss_work_plan_followup|human
plan|followup|||none
security|analyze||analyze_feature_security|read
security|threat-model||generate_threat_model|read
doc|claude-md||generate_claude_md|read
meta|scaffold-agent|||none
MAP
[ "$MAP_FAIL" -eq 0 ] && check "B41 every v0.10.0 mocks, design, journeys-step, work and plan verb maps to its tool and class, with the third word for work policy, work repositories|repos and plan followup" PASS \
  || check "B41 map and class coverage ($MAP_FAIL)" FAIL

unset ZENSU_SESSION_TOKEN
run "B42a mocks create uploads a file"             "zensu mocks create f1 mock.html --title Checkout"         '' DENY
run "B42b mock alias create"                       "zensu mock create f1 mock.png"                            '' DENY
run "B42c journeys step-update"                    "zensu journeys step-update j1 s1 --title T"               '' DENY
run "B42d journey alias step-delete"               "zensu journey step-delete j1 s1"                          '' DENY
run "B42e work policy set (third word)"            "zensu work policy set --product p --max-attempts 2"      '' DENY
run "B42f work repos remove (alias, third word)"   "zensu work repos remove r1 --product p"                  '' DENY
run "B42g plan followup accept (third word)"       "zensu plan followup accept p1 f1"                        '' DENY
run "B42h plan push creates features and revisions" "zensu plan push plan.md"                                '' DENY
run "B42i work create dispatches a work order"     "zensu work create --product p --feature f"               '' DENY
run "B42j reads, reclassified reads and the unmapped stub" "zensu mocks list f1 && zensu mocks get f1 m1 --raw && zensu design context p1 && zensu work list && zensu work get o1 && zensu work events o1 && zensu work questions && zensu work policy get --product p && zensu work repositories list --product p && zensu work repos list --product p && zensu plan status p1 --watch && zensu plan list && zensu plan followups p1 && zensu security analyze f1 && zensu security threat-model f1 && zensu doc claude-md --product p && zensu meta scaffold-agent" '' ALLOW

HUMAN_MAIN="$(payload 'zensu plan approve p1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$HUMAN_MAIN" | grep -qF '"permissionDecision":"deny"' \
   && printf '%s' "$HUMAN_MAIN" | grep -qF "maps to 'approve_work_plan'" \
   && printf '%s' "$HUMAN_MAIN" | grep -qF 'It records a decision that the person makes, so the person runs it' \
   && printf '%s' "$HUMAN_MAIN" | grep -qF 'let them run it' \
   && ! printf '%s' "$HUMAN_MAIN" | grep -qF '/zensu:' \
   && ! printf '%s' "$HUMAN_MAIN" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B43a human-decision deny reason: the person decides and runs it; no skill, no escape" PASS
else
  check "B43a human-decision deny reason (got '$(printf '%s' "$HUMAN_MAIN" | cut -c1-200)')" FAIL
fi
HUMAN_SUB="$(payload 'zensu work answer q1 --answer yes' general-purpose gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$HUMAN_SUB" | grep -qF '"permissionDecision":"deny"' \
   && printf '%s' "$HUMAN_SUB" | grep -qF "maps to 'answer_work_question'" \
   && printf '%s' "$HUMAN_SUB" | grep -qF 'It records a decision that the person makes' \
   && printf '%s' "$HUMAN_SUB" | grep -qF 'to the main thread' \
   && ! printf '%s' "$HUMAN_SUB" | grep -qF '/zensu:' \
   && ! printf '%s' "$HUMAN_SUB" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B43b subagent human-decision deny reason sends the decision to the main thread" PASS
else
  check "B43b subagent human-decision deny reason (got '$(printf '%s' "$HUMAN_SUB" | cut -c1-200)')" FAIL
fi
WO_REASON="$(payload 'zensu work heartbeat o1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$WO_REASON" | grep -qF '"permissionDecision":"deny"' \
   && printf '%s' "$WO_REASON" | grep -qF "maps to 'send_work_order_heartbeat'" \
   && printf '%s' "$WO_REASON" | grep -qF 'It belongs to the Zensu work-order protocol' \
   && printf '%s' "$WO_REASON" | grep -qF 'the worker sends' \
   && printf '%s' "$WO_REASON" | grep -qF '/zensu:work helper' \
   && ! printf '%s' "$WO_REASON" | grep -qF 'A subagent never sends it' \
   && ! printf '%s' "$WO_REASON" | grep -qF '/zensu:bootstrap' \
   && ! printf '%s' "$WO_REASON" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B43c work-order protocol deny reason names the worker and the /zensu:work helper, not a skill window" PASS
else
  check "B43c work-order protocol deny reason (got '$(printf '%s' "$WO_REASON" | cut -c1-200)')" FAIL
fi
MIXED_REASON="$(payload 'zensu features update f1 --priority high && zensu plan approve p1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$MIXED_REASON" | grep -qF '"permissionDecision":"deny"' \
   && printf '%s' "$MIXED_REASON" | grep -qF "maps to 'approve_work_plan'" \
   && printf '%s' "$MIXED_REASON" | grep -qF 'It records a decision that the person makes' \
   && ! printf '%s' "$MIXED_REASON" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B43d a human decision after an ordinary mutation still gets the human-decision reason and no escape" PASS
else
  check "B43d mixed command deny reason (got '$(printf '%s' "$MIXED_REASON" | cut -c1-200)')" FAIL
fi
WO_SUB="$(payload 'zensu work heartbeat o1' general-purpose gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$WO_SUB" | grep -qF '"permissionDecision":"deny"' \
   && printf '%s' "$WO_SUB" | grep -qF 'It belongs to the Zensu work-order protocol' \
   && printf '%s' "$WO_SUB" | grep -qF 'A subagent never sends it: report what you need to the main thread' \
   && ! printf '%s' "$WO_SUB" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B43e a subagent's work-order protocol deny sends the need to the main thread" PASS
else
  check "B43e subagent work-order deny reason (got '$(printf '%s' "$WO_SUB" | cut -c1-200)')" FAIL
fi

run "B44a inline off still lets a human-decision command through" "ZENSU_MCP_GATE=off zensu plan approve p1" '' ALLOW
OUT="$(payload 'zensu work approve o1' '' gate-test | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B44b env ZENSU_MCP_GATE=off still lets a human-decision command through" PASS || check "B44b env escape for a human decision (got '$OUT')" FAIL

run "B45a value flag between noun and verb"          "zensu features --product p1 create --title T"              '' DENY
run "B45b value flag between group verb and leaf"    "zensu work policy --product p1 set --max-attempts 2"       '' DENY
run "B45c global flag, then a value flag"            "zensu --api-url https://h features --product p1 create"   '' DENY
run "B45d empty word before the verb"                "zensu features '' create --title T"                        '' DENY
run "B45e value flag before a read stays a read"     "zensu features --product p1 list"                          '' ALLOW
run "B45f -- ends the subcommand search, so nothing runs" "zensu features -- create"                             '' ALLOW
run "B45g a flag with = takes no next word"          "zensu features --product=p1 create --title T"              '' DENY
run "B45h a two-character flag takes the next word"  "zensu features -p p1 create"                                '' DENY
run "B45i a longer single-dash word takes no next word" "zensu features -abc create"                             '' DENY
run "B45j a flag with = before a leaf"               "zensu work policy --product=p1 set"                         '' DENY
run "B45k an expansion before the verb"              'zensu features $FLAGS create --title T'                     '' DENY
run "B45l an expansion before the noun"              'zensu $X features create'                                   '' DENY
run "B45m an expansion before the leaf"              'zensu work policy "$X" set'                                 '' DENY
run "B45n an expansion that ends in a value flag"    'zensu features $F p1 create'                                '' DENY
run "B45o a command substitution before the verb"    'zensu features $(true) create'                              '' DENY
run "B45p an expansion before a read stays a read"   'zensu features $FLAGS list'                                 '' ALLOW

WO_ORDER="99999999-9999-4999-8999-999999999999"
WO_OUT="$(
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" wo-gate-sess || { echo UNBOUND; exit 0; }
  WO_MARKER="$(node -e 'process.stdout.write(require(process.argv[1]).sessionFiles(process.argv[2], process.argv[3]).marker)' "$PLUGIN_DIR/hooks/lib/work-order-v1.js" "$ZENSU_PROJECT_ROOT" "$ZENSU_SESSION_KEY")" || { echo NOMARKER; exit 0; }
  node -e '
    const m = require(process.argv[1]);
    const key = process.argv[3];
    m.writeState(process.argv[2], process.argv[5], { sessionKey: key, clientSessionKey: key, orderId: process.argv[4], attempt: 1 });
  ' "$PLUGIN_DIR/hooks/lib/work-order-v1.js" "$ZENSU_PROJECT_ROOT" "$ZENSU_SESSION_KEY" "$WO_ORDER" "$WO_MARKER" || { echo NOMARKER; exit 0; }
  wo_run() {
    payload "$1" "$2" wo-gate-sess | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_SESSION_TOKEN="$3" bash "$HOOK" 2>/dev/null | classify
    echo
  }
  wo_run "zensu work ask $WO_ORDER --category scope --question q" '' zst_gate_test_token
  wo_run "zensu work followup $WO_ORDER --title t --rationale r" '' zst_gate_test_token
  wo_run "zensu work approve $WO_ORDER" '' zst_gate_test_token
  wo_run "zensu work heartbeat $WO_ORDER" '' zst_gate_test_token
  wo_run "zensu work ask $WO_ORDER --question q" general-purpose zst_gate_test_token
  wo_run "zensu work ask $WO_ORDER --question q" '' ''
  rm -f "$WO_MARKER"
  wo_run "zensu work ask $WO_ORDER --question q" '' zst_gate_test_token
  wo_write() {
    node -e '
      const m = require(process.argv[1]);
      m.writeState(process.argv[2], process.argv[5], { sessionKey: process.argv[3], clientSessionKey: process.argv[6], orderId: process.argv[4], attempt: 1 });
    ' "$PLUGIN_DIR/hooks/lib/work-order-v1.js" "$ZENSU_PROJECT_ROOT" "$ZENSU_SESSION_KEY" "$WO_ORDER" "$WO_MARKER" "$1"
  }
  wo_write "$ZENSU_SESSION_KEY"
  wo_run "zensu work ask $WO_ORDER --question q && zensu features create --title T" '' zst_gate_test_token
  wo_run "zensu work ask $WO_ORDER --question q && zensu plan push p.md" '' zst_gate_test_token
  payload "zensu plan approve p1" '' wo-gate-sess | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_SESSION_TOKEN=zst_gate_test_token bash "$HOOK" 2>/dev/null | grep -qF 'without a person' && echo PERSONLESS || echo PLAIN
  wo_write "scv1_$(printf '%064d' 0 | tr 0 e)"
  wo_run "zensu work ask $WO_ORDER --question q" '' zst_gate_test_token
  printf '{' > "$WO_MARKER"
  wo_run "zensu work ask $WO_ORDER --question q" '' zst_gate_test_token
)"
WO_LINE() { printf '%s\n' "$WO_OUT" | sed -n "${1}p"; }
if [ "$(WO_LINE 1)" = ALLOW ] && [ "$(WO_LINE 2)" = ALLOW ]; then
  check "B46a a bound work-order session leaves zensu work ask and followup to the work-order gate" PASS
else
  check "B46a bound work-order session ask/followup (got '$(WO_LINE 1)' '$(WO_LINE 2)')" FAIL
fi
if [ "$(WO_LINE 3)" = DENY ] && [ "$(WO_LINE 4)" = DENY ]; then
  check "B46b a bound work-order session still denies a human decision and a helper-only verb" PASS
else
  check "B46b bound work-order session approve/heartbeat (got '$(WO_LINE 3)' '$(WO_LINE 4)')" FAIL
fi
if [ "$(WO_LINE 5)" = DENY ]; then
  check "B46c a subagent in a bound work-order session gets no work-order exemption" PASS
else
  check "B46c subagent in a bound work-order session (got '$(WO_LINE 5)')" FAIL
fi
if [ "$(WO_LINE 6)" = DENY ] && [ "$(WO_LINE 7)" = DENY ]; then
  check "B46d without the session token or without this session's marker zensu work ask is a mutation like the rest" PASS
else
  check "B46d unbound zensu work ask (no token '$(WO_LINE 6)', no marker '$(WO_LINE 7)')" FAIL
fi
if [ "$(WO_LINE 8)" = DENY ] && [ "$(WO_LINE 9)" = DENY ]; then
  check "B46e the exemption covers the ask alone, so a mutation chained after it is still denied" PASS
else
  check "B46e chained mutation in a bound session (got '$(WO_LINE 8)' '$(WO_LINE 9)')" FAIL
fi
if [ "$(WO_LINE 10)" = PERSONLESS ]; then
  check "B46f in a bound work-order session the human-decision reason sends the decision to a work-order question" PASS
else
  check "B46f bound-session human-decision reason (got '$(WO_LINE 10)')" FAIL
fi
if [ "$(WO_LINE 11)" = DENY ] && [ "$(WO_LINE 12)" = DENY ]; then
  check "B46g a marker that binds another session or cannot be read gives no exemption" PASS
else
  check "B46g non-binding marker (foreign '$(WO_LINE 11)', unreadable '$(WO_LINE 12)')" FAIL
fi
psrun() {
  local label="$1" cmd="$2" at="$3" exp="$4" cfg="${5:-$CFG_ON}"
  local out
  out="$(payload "$cmd" "$at" gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$cfg" bash "$HOOK" 2>/dev/null | classify)"
  [ "$out" = "$exp" ] && check "$label -> $exp" PASS || check "$label (got '$out' want '$exp')" FAIL
}
BT='`'
psrun "B40a PowerShell read"                              "zensu features get f1"                                         '' ALLOW
psrun "B40b PowerShell freelance mutation"                "zensu security classify f1"                                    '' DENY
psrun "B40c PowerShell mutation in any letter case"       "ZENSU Security Classify f1"                                    '' DENY
psrun "B40d PowerShell call operator on zensu.exe"        "& 'C:\\Program Files\\Zensu\\zensu.exe' security classify f1"   '' DENY
psrun "B40e PowerShell backtick inside the name"          "zen${BT}su security classify f1"                               '' DENY
psrun "B40f PowerShell nested pwsh -Command"              "pwsh -NoProfile -Command 'zensu security classify f1'"         '' DENY
psrun "B40g PowerShell Invoke-Expression naming zensu"    "iex 'zensu features get f1'"                                   '' DENY
psrun "B40h PowerShell noun built at run time"            "zensu \$noun classify f1"                                      '' DENY
psrun "B40i PowerShell verb built at run time"            "zensu security \$verb f1"                                      '' DENY
psrun "B40j PowerShell text without zensu"                "Get-ChildItem -Recurse | Select-String foo"                    '' ALLOW
psrun "B40k PowerShell .zensu path is not the CLI"        "Get-Content .zensu/plans/a.md"                                 '' ALLOW
psrun "B40l PowerShell plugin helper script through bash" "bash C:/Users/me/.claude/plugins/cache/zensu/zensu/0.27.0/hooks/lib/zensu-log.sh --phase x" '' ALLOW
psrun "B40m PowerShell env statement is no inline escape" "\$env:ZENSU_MCP_GATE = 'off'; zensu security classify f1"     '' DENY
psrun "B40n PowerShell inline ZENSU_API_URL is no escape" "\$env:ZENSU_API_URL = 'http://localhost:8090'; zensu security classify f1" '' DENY
psrun "B40o PowerShell --api-url localhost"               "zensu --api-url http://localhost:8090 security classify f1"   '' ALLOW
psrun "B40p PowerShell --help"                            "zensu security classify f1 --help"                             '' ALLOW
psrun "B40q PowerShell subagent mutation"                 "zensu security classify f1"                                    general-purpose DENY
psrun "B40r PowerShell subagent read"                     "zensu features get f1"                                         general-purpose ALLOW
psrun "B40s PowerShell mutation with mcpGate false"       "zensu security classify f1"                                    '' ALLOW "$CFG_FALSE"
psrun "B40t PowerShell payload without a command"         ""                                                              '' ALLOW
OUT="$(payload 'zensu security classify f1' '' gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B40u PowerShell mutation + session ZENSU_MCP_GATE=off -> ALLOW" PASS || check "B40u PowerShell session env escape (got '$OUT')" FAIL
OUT="$(payload "iex 'zensu security classify f1'" '' gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_MCP_GATE=off bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B40v PowerShell unjudged construct + session ZENSU_MCP_GATE=off -> ALLOW" PASS || check "B40v PowerShell session env escape on an unjudged construct (got '$OUT')" FAIL
OUT="$(payload 'zensu security classify f1' '' gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" ZENSU_API_URL=http://localhost:8090 bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "ALLOW" ] && check "B40w PowerShell mutation + process-env ZENSU_API_URL=localhost -> ALLOW" PASS || check "B40w PowerShell process-env localhost (got '$OUT')" FAIL
OUT="$(payload "zensu security \"classify${BT}n__bypass__${BT}tZENSU_MCP_GATE\" f1" '' gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT" = "DENY" ] && check "B40x a PowerShell verb that holds an escaped line break is classified by its first line" PASS || check "B40x PowerShell verb with an escaped line break (got '$OUT')" FAIL
psrun "B40x2 PowerShell 5.1 reads a quoted backtick-e as e"  "& \"z${BT}ensu\" security classify f1"                         '' DENY
psrun "B40x3 PowerShell 5.1 reading of a noun"              "zensu \"s${BT}ecurity\" classify f1"                           '' DENY
psrun "B40x4 PowerShell empty argument before the noun"     "zensu '' security classify f1"                                 '' DENY
psrun "B40x5 PowerShell double quote in a zensu argument"   "zensu features get 'a\"b'"                                     '' DENY
psrun "B40x6 PowerShell cmd.exe operator in a zensu argument" "zensu features get 'x&zensu'"                                '' DENY
psrun "B40x7 PowerShell spaced cmd.exe operator is quoted"  "zensu features get 'a & b'"                                    '' ALLOW

PS_MAIN="$(payload 'zensu security classify f1' '' gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$PS_MAIN" | grep -qF "maps to 'set_security_classification'" \
   && printf '%s' "$PS_MAIN" | grep -qF '/zensu:security-review' \
   && printf '%s' "$PS_MAIN" | grep -qF 'A PowerShell command has no inline gate escape' \
   && ! printf '%s' "$PS_MAIN" | grep -qF 'prefix the command with ZENSU_MCP_GATE=off' \
   && ! printf '%s' "$PS_MAIN" | grep -qF '(honored inline)'; then
  check "B40y PowerShell main-thread deny names the skills and no inline escape" PASS
else
  check "B40y PowerShell main-thread deny wording" FAIL
fi
PS_UNJUDGED="$(payload "iex 'zensu features get f1'" '' gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$PS_UNJUDGED" | grep -qF 'cannot judge it: iex' \
   && printf '%s' "$PS_UNJUDGED" | grep -qF 'Run the zensu call through the Bash tool' \
   && ! printf '%s' "$PS_UNJUDGED" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B40z PowerShell unjudged deny names the construct and the Bash tool" PASS
else
  check "B40z PowerShell unjudged deny wording" FAIL
fi
PS_CHILD="$(payload "iex 'zensu features get f1'" general-purpose gate-test PowerShell | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$PS_CHILD" | grep -qF 'Report the operation you need to the main thread' \
   && ! printf '%s' "$PS_CHILD" | grep -qF 'Bash tool' \
   && ! printf '%s' "$PS_CHILD" | grep -qF 'ZENSU_MCP_GATE'; then
  check "B40z2 PowerShell unjudged subagent deny reports to the main thread" PASS
else
  check "B40z2 PowerShell unjudged subagent deny wording" FAIL
fi

PS_BASE="$(mktemp -d -t bashgate-psfallback-XXXXXX)"
PS_ROOT="$PS_BASE/plugin"
mkdir -p "$PS_ROOT" "$PS_BASE/project"
for part in hooks agents skills docs templates scripts .claude-plugin; do
  [ -e "$PLUGIN_DIR/$part" ] && cp -R "$PLUGIN_DIR/$part" "$PS_ROOT/$part"
done
rm -f "$PS_ROOT/hooks/lib/powershell-command-v1.js"
PS_OUT="$(
  export CLAUDE_PROJECT_DIR="$PS_BASE/project"
  ZENSU_TEST_PLUGIN_DATA="$PS_BASE/plugin-data" source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" ps-fallback-gate "$PS_ROOT" || exit 1
  printf 'BOUND\n'
  for spec in 'PowerShell|zensu features get f1' 'PowerShell|Get-ChildItem -Recurse' 'Bash|zensu security classify f1' 'Bash|zensu features get f1'; do
    payload "${spec#*|}" '' ps-fallback-gate "${spec%%|*}" | env CLAUDE_PLUGIN_ROOT="$PS_ROOT" ZENSU_CONFIG="$CFG_ON" bash "$PS_ROOT/hooks/pre-bash-zensu-gate.sh" 2>/dev/null | tr -d '\n'
    printf '\n<<%s>>\n' "$spec"
  done
)"
PS_BOUND="$(printf '%s\n' "$PS_OUT" | sed -n '1p')"
PS_FB_READ="$(printf '%s\n' "$PS_OUT" | sed -n '2p')"
PS_FB_PLAIN="$(printf '%s\n' "$PS_OUT" | sed -n '4p')"
PS_FB_BASH_DENY="$(printf '%s\n' "$PS_OUT" | sed -n '6p')"
PS_FB_BASH_READ="$(printf '%s\n' "$PS_OUT" | sed -n '8p')"
if [ "$PS_BOUND" = "BOUND" ] && [ ! -e "$PS_ROOT/hooks/lib/powershell-command-v1.js" ] \
   && printf '%s' "$PS_FB_READ" | grep -qF 'the PowerShell analyzer could not be loaded'; then
  check "B41a without the analyzer a PowerShell command naming zensu denies" PASS
else
  check "B41a analyzer-less PowerShell zensu command (bound='$PS_BOUND' got '$PS_FB_READ')" FAIL
fi
[ "$PS_BOUND" = "BOUND" ] && [ -z "$PS_FB_PLAIN" ] && check "B41b without the analyzer a PowerShell command without zensu passes" PASS \
  || check "B41b analyzer-less PowerShell plain command (bound='$PS_BOUND' got '$PS_FB_PLAIN')" FAIL
if [ "$PS_BOUND" = "BOUND" ] && printf '%s' "$PS_FB_BASH_DENY" | grep -qF "maps to 'set_security_classification'" && [ -z "$PS_FB_BASH_READ" ]; then
  check "B41c without the analyzer the Bash verdicts are unchanged" PASS
else
  check "B41c analyzer-less Bash verdicts (bound='$PS_BOUND' deny='$PS_FB_BASH_DENY' read='$PS_FB_BASH_READ')" FAIL
fi
rm -rf "$PS_BASE"
psrun "B41d PowerShell group subcommand built at run time"   "zensu work policy \$sub"                                     '' DENY
psrun "B41e PowerShell read whose argument is built at run time" "zensu features get \$id"                                    '' ALLOW

rm -f "$CFG_ON" "$CFG_OFF" "$CFG_FALSE"
rm -rf "$PROJECT"

echo "----"
echo "test-bash-zensu-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
