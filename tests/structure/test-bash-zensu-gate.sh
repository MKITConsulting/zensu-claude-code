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
[ -n "$PAYLOAD_LIMIT" ] && check "B41 the binder exports the payload limit it enforces" PASS \
  || check "B41 the binder exports the payload limit it enforces" FAIL
LIMIT="${PAYLOAD_LIMIT:-1048576}"
sized_payload() {
  node -e '
    const [file, total, prefix, agent] = process.argv.slice(1);
    const base = { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: prefix + " && : " }, session_id: "gate-test", cwd: "/tmp" };
    if (agent) { base.agent_id = "gate-subagent-1"; base.agent_type = agent; }
    base.tool_input.command += "a".repeat(Number(total) - Buffer.byteLength(JSON.stringify(base)));
    require("fs").writeFileSync(file, JSON.stringify(base));
  ' "$1" "$2" "$3" "${4:-}"
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
[ "$OUT" = ALLOW ] && check "B41a a read in a payload of exactly the limit is bound and allowed" PASS \
  || check "B41a read at the payload limit (got '$OUT')" FAIL
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_OVER" 2>/dev/null)"
size_denied "$OUT" "$((LIMIT + 1))" \
  && check "B41b a read one byte over the limit is denied with a reason that names its size and the limit, not a broken binding" PASS \
  || check "B41b read one byte over the limit (got '$(printf '%s' "$OUT" | cut -c1-200)')" FAIL
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_MUTATION" 2>/dev/null)"
OUT_SUB="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_SUBAGENT" 2>/dev/null)"
if size_denied "$OUT" "$((LIMIT + 150000))" && size_denied "$OUT_SUB" "$((LIMIT + 150000))"; then
  check "B41c an oversized mutation gets the same size deny on the main thread and in a subagent" PASS
else
  check "B41c oversized mutation (main '$(printf '%s' "$OUT" | cut -c1-120)' subagent '$(printf '%s' "$OUT_SUB" | cut -c1-120)')" FAIL
fi
OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$CFG_ON" bash "$HOOK" < "$SIZED_PLAIN" 2>/dev/null | classify)"
[ "$OUT" = ALLOW ] && check "B41e an oversized command that names no zensu invocation stays outside this gate" PASS \
  || check "B41e oversized non-zensu command (got '$OUT')" FAIL

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
  check "B43 three workflow-allowed mutations of two tools spawn as many node children as one, so the workflow is read once per run" PASS
else
  check "B43 workflow read once per run (decision:node-spawns one=$SPAWNS_ONE three=$SPAWNS_THREE)" FAIL
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
  check "B41d the size is compared before the parser runs: an oversized payload never loads the shell-model module, an ordinary one does" PASS
else
  check "B41d size check before the parser (oversized loaded=$PARSER_LOADED_OVERSIZED small loaded=$PARSER_LOADED_SMALL got '$(printf '%s' "$FALLBACK_OVERSIZED" | cut -c1-120)')" FAIL
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
if [ "$LINES_ONE" = "features${TAB}get" ] && [ "$LINES_MIXED" = "features${TAB}get
security${TAB}classify" ]; then
  check "B42 the parser emits each distinct invocation once, although the walker and the token scan both find it" PASS
else
  check "B42 deduplicated invocation lines (one='$LINES_ONE' mixed='$LINES_MIXED')" FAIL
fi
NO_GUARD="$PROJECT/no-shell-model.js"
LINES_TOKEN="$(node -e 'process.stdout.write("zensu features get f1; x" + "\x27".repeat(600000) + "y")' | parser_lines "$NO_GUARD")"
LINES_PREFIX="$(node -e 'process.stdout.write("A=x" + "\x27".repeat(600000) + "y zensu features get f1")' | parser_lines "$NO_GUARD")"
LINES_URL="$(node -e 'process.stdout.write("zensu --api-url x" + "\x27".repeat(600000) + "y features get f1")' | parser_lines "$NO_GUARD")"
if [ "$LINES_TOKEN" = "features${TAB}get" ] && [ "$LINES_PREFIX" = "features${TAB}get" ] && [ "$LINES_URL" = "features${TAB}get" ]; then
  check "B44 the token scan trims quotes in linear time: a 600000-quote command word, assignment value and --api-url value each finish within 15 s" PASS
else
  check "B44 linear quote trim (word='$LINES_TOKEN' prefix='$LINES_PREFIX' url='$LINES_URL')" FAIL
fi

rm -f "$CFG_ON" "$CFG_OFF" "$CFG_FALSE"
rm -rf "$PROJECT"

echo "----"
echo "test-bash-zensu-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
