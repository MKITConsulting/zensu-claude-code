#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-intent-router.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
NO_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/user-prompt-intent-router.sh exists" FAIL
  echo "----"
  echo "test-intent-router-hook: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "C1 hook exists + executable" PASS || check "C1 hook exists + executable" FAIL

bash -n "$HOOK" 2>/dev/null && check "C2 bash -n syntax check passes" PASS || check "C2 bash -n syntax check passes" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");
  process.exit(ups.some(c=>/user-prompt-intent-router\.sh/.test(c))?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "C3 registered in hooks.json UserPromptSubmit" PASS
else
  check "C3 registered in hooks.json UserPromptSubmit" FAIL
fi

if grep -qF 'zensu_hook_enabled' "$HOOK" && grep -qF 'intentRouter' "$HOOK"; then
  check "C4 gated by hooks.intentRouter (zensu_hook_enabled intentRouter)" PASS
else
  check "C4 gated by hooks.intentRouter (zensu_hook_enabled intentRouter)" FAIL
fi

if grep -qF 'UserPromptSubmit' "$HOOK" && grep -qF 'hookEventName' "$HOOK" && grep -qF 'additionalContext' "$HOOK"; then
  check "C5 builds UserPromptSubmit additionalContext" PASS
else
  check "C5 builds UserPromptSubmit additionalContext" FAIL
fi

payload() {
  node -e '
    const payload={hook_event_name:"UserPromptSubmit",prompt:process.argv[1]};
    if(process.argv[2])payload.agent_type=process.argv[2];
    if(process.argv[3])payload.agent_id=process.argv[3];
    process.stdout.write(JSON.stringify(payload));
  ' "$1" "${2:-}" "${3:-}"
}

classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        const ac=o.additionalContext||"";
        const route=/top-level interactive thread/.test(ac)&&/\/zensu:bootstrap/.test(ac)&&/never delegate mutations/.test(ac)?"main":"nomaint";
        const triage=(/greenfield/i.test(ac)&&/brownfield/i.test(ac))?"triage":"notriage";
        const pm=/plan mode/i.test(ac)?"planmode":"noplanmode";
        process.stdout.write((o.hookEventName||"?")+"|"+route+"|"+triage+"|"+pm);
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

P6="$(mktemp -d -t introuter-XXXXXX)"
OUT6="$(payload "I want to track Zensu as a product in Zensu itself" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P6" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT6" = "UserPromptSubmit|main|triage|planmode" ]; then
  check "C6 planning prompt -> main-thread skill routing + greenfield/brownfield triage + Plan-mode-allowed" PASS
else
  check "C6 planning directive (got '$OUT6')" FAIL
fi
rm -rf "$P6"

P7="$(mktemp -d -t introuter-XXXXXX)"
OUT7="$(payload "fix the auth token expiry bug" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P7" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT7" = "EMPTY" ] && check "C7 non-planning prompt -> silent" PASS || check "C7 non-planning silent (got '$OUT7')" FAIL
rm -rf "$P7"

P8="$(mktemp -d -t introuter-XXXXXX)"
CFG8="$P8/config.json"; printf '%s' '{"hooks":{"intentRouter":false}}' > "$CFG8"
OUT8="$(payload "bootstrap a new product roadmap in zensu" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P8" ZENSU_CONFIG="$CFG8" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT8" = "EMPTY" ] && check "C8 hooks.intentRouter:false -> silent (opt-out honored)" PASS || check "C8 disabled silent (got '$OUT8')" FAIL
rm -rf "$P8"

P9="$(mktemp -d -t introuter-XXXXXX)"
OUT9="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s9"}' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P9" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC9=$?
if [ "$RC9" = "0" ] && [ -z "$OUT9" ]; then
  check "C9 missing prompt field -> exit 0, silent (fail-open)" PASS
else
  check "C9 missing prompt (rc=$RC9 out='$OUT9')" FAIL
fi
rm -rf "$P9"

if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(j.hooks && j.hooks.intentRouter===true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "C10 config.example.json has hooks.intentRouter" PASS
else
  check "C10 config.example.json has hooks.intentRouter" FAIL
fi

P11="$(mktemp -d -t introuter-XXXXXX)"
KW_FAIL=0
for kw in zensu product feature roadmap milestone bootstrap "ghost scan" journey tier; do
  OUTKW="$(payload "let us $kw the plan now" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
  [ "$OUTKW" = "UserPromptSubmit|main|triage|planmode" ] || { KW_FAIL=$((KW_FAIL+1)); echo "      keyword '$kw' did not fire (got '$OUTKW')"; }
done
[ "$KW_FAIL" -eq 0 ] && check "C11 every planning keyword fires as a whole word" PASS || check "C11 per-keyword coverage ($KW_FAIL missed)" FAIL
rm -rf "$P11"

P12="$(mktemp -d -t introuter-XXXXXX)"
OUT12A="$(payload "speed up production builds" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
OUT12B="$(payload "explore the new frontier" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT12A" = "EMPTY" ] && [ "$OUT12B" = "EMPTY" ]; then
  check "C12 mid-word substrings (production/frontier) -> silent (whole-word match)" PASS
else
  check "C12 mid-word silence (a='$OUT12A' b='$OUT12B')" FAIL
fi
rm -rf "$P12"

P13="$(mktemp -d -t introuter-XXXXXX)"
OUT13="$(payload "list all products on the roadmaps" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P13" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT13" = "UserPromptSubmit|main|triage|planmode" ] && check "C13 inflected keywords (products/roadmaps) still fire" PASS || check "C13 inflection (got '$OUT13')" FAIL
rm -rf "$P13"

P14="$(mktemp -d -t introuter-XXXXXX)"
AC14="$(payload "please improve my product by adding a new modern hero section to my landing page" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P14" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC14" ] \
   && printf '%s' "$AC14" | grep -qi 'ignore this notice' \
   && printf '%s' "$AC14" | grep -qi 'answer the request normally' \
   && printf '%s' "$AC14" | grep -qi 'do NOT run the triage'; then
  check "C14 keyword-bearing non-planning prompt fires but directive empowers the model to dismiss" PASS
else
  fired="$([ -n "$AC14" ] && echo yes || echo no)"
  check "C14 dismiss-flexibility in directive (fired=$fired)" FAIL
fi
rm -rf "$P14"

P15="$(mktemp -d -t introuter-XXXXXX)"
AC15="$(payload "I want to track my SaaS product and its features in Zensu" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P15" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC15" ] \
   && printf '%s' "$AC15" | grep -qi 'very next action' \
   && printf '%s' "$AC15" | grep -qi 'do NOT read files' \
   && printf '%s' "$AC15" | grep -qi 'ground'; then
  check "C15 planning directive front-loads ask-first + forbids explore/ground-first deferral" PASS
else
  fired15="$([ -n "$AC15" ] && echo yes || echo no)"
  check "C15 ask-first/anti-explore clause (fired=$fired15)" FAIL
fi
rm -rf "$P15"

P16="$(mktemp -d -t introuter-XXXXXX)"
AC16="$(payload "continue feature ZEN-42" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P16" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC16" ] \
   && printf '%s' "$AC16" | grep -qi 'skip the triage entirely' \
   && printf '%s' "$AC16" | grep -qF '/zensu:pilot conductor skill'; then
  check "C16 existing-tracked-feature carve-out routes to /zensu:pilot instead of the triage" PASS
else
  fired16="$([ -n "$AC16" ] && echo yes || echo no)"
  check "C16 pilot carve-out in directive (fired=$fired16)" FAIL
fi
rm -rf "$P16"

P17="$(mktemp -d -t introuter-XXXXXX)"
OUT17=''
for agent_type in general-purpose zensu:review-aspect zensu:zensu-plm; do
  OUT17="${OUT17}$(payload 'bootstrap a new Zensu product' "$agent_type" agent-17 \
    | ZENSU_FORCE_MAIN=1 env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P17" \
      ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
done
if [ -z "$OUT17" ]; then
  check "C17 explicit agent principals stay silent despite ZENSU_FORCE_MAIN" PASS
else
  check "C17 explicit agent principals stay silent despite ZENSU_FORCE_MAIN" FAIL
fi
rm -rf "$P17"

P18="$(mktemp -d -t introuter-XXXXXX)"
OUT18="$(printf '%s' '{"prompt":"bootstrap a new Zensu product"}' \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P18" ZENSU_CONFIG="$NO_CONFIG" \
    bash "$HOOK" 2>/dev/null)"
[ -z "$OUT18" ] \
  && check "C18 missing hook event cannot receive main-thread routing" PASS \
  || check "C18 missing hook event cannot receive main-thread routing" FAIL
rm -rf "$P18"

P19="$(mktemp -d -t introuter-XXXXXX)"
OUT19="$(payload "the log at /private/tmp/claude-501/-Users-dev-zensu-zensu-claude-code--claude-worktrees-x/tasks/b1.output shows a timeout" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P19" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT19" = "EMPTY" ] && check "C19 zensu only inside a path -> silent (path tokens are dropped before the keyword match)" PASS || check "C19 zensu-in-path silence (got '$OUT19')" FAIL
rm -rf "$P19"

P20="$(mktemp -d -t introuter-XXXXXX)"
OUT20A="$(payload "run gh pr checks 382 --repo zensu-claude-code, then gh pr view --repo=zensu-claude-code and read the zensu:session-trail output" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P20" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
OUT20B="$(payload "the zensu:session-trail skill should track the roadmap" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P20" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT20A" = "EMPTY" ] && [ "$OUT20B" = "UserPromptSubmit|main|triage|planmode" ]; then
  check "C20 a --repo operand and a zensu: skill name are dropped, while a keyword beside them still fires" PASS
else
  check "C20 token drop (operand+skill='$OUT20A' keyword-beside='$OUT20B')" FAIL
fi
rm -rf "$P20"

P21="$(mktemp -d -t introuter-XXXXXX)"
OUT21=""
for PROMPT21 in \
  "$(printf '<task-notification>\n<summary>Background command "plan the product roadmap" completed</summary>\n</task-notification>')" \
  "$(printf '<ci-monitor-event>watching the product roadmap PR</ci-monitor-event>')" \
  "$(printf 'Another Claude session sent a message:\n<agent-message from="a1">\n[Subagent hand-back] Plan the product roadmap.\n</agent-message>')" \
  "$(printf '<system-reminder>\nworktree\n</system-reminder>\n<bash-input>zensu feature list</bash-input>')" \
  "/zensu:bootstrap"; do
  OUT21="${OUT21}$(payload "$PROMPT21" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P21" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
done
OUT21B="$(payload "/zensu:bootstrap a new product" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P21" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ -z "$OUT21" ] && [ "$OUT21B" = "UserPromptSubmit|main|triage|planmode" ]; then
  check "C21 task notifications, subagent hand-backs, CI events, shell inputs and argument-less slash commands stay silent; a slash command with arguments is screened" PASS
else
  check "C21 origin gate (harness output='${OUT21:0:60}' slash-with-args='$OUT21B')" FAIL
fi
rm -rf "$P21"

P22="$(mktemp -d -t introuter-XXXXXX)"
LARGE22="$P22/large-payload.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ hook_event_name: "UserPromptSubmit", prompt: "Plan the product roadmap for this repository.\n" + "a line of pasted build output\n".repeat(23400) }))' "$LARGE22"
PAD22=
if [ "$(uname -s)" = Darwin ]; then
  PAD22="$(node -e 'process.stdout.write("p".repeat(125000))')"
fi
OUT22="$(env PAD22_A="$PAD22" PAD22_B="$PAD22" PAD22_C="$PAD22" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P22" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" < "$LARGE22" 2>/dev/null | classify)"
[ "$OUT22" = "UserPromptSubmit|main|triage|planmode" ] \
  && check "C22 a planning prompt in a payload over the exec size limit still gets the routing" PASS \
  || check "C22 oversized planning prompt (got '$OUT22')" FAIL
rm -rf "$P22"

C23_GROW="$(HOOK="$HOOK" node -e '
  const src = require("fs").readFileSync(process.env.HOOK, "utf8");
  const start = src.indexOf("| awk \x27");
  const end = start === -1 ? -1 : src.indexOf("\x27", start + 7);
  if (start === -1 || end === -1) { process.stdout.write("no keyword scan found"); process.exit(0); }
  const grow = src.slice(start + 7, end).split("\n").filter((line) => /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\1\s/.test(line));
  process.stdout.write(grow.join("\n"));
')"
[ -z "$C23_GROW" ] \
  && check "C23 the keyword scan prints each kept token instead of growing a line buffer, which is quadratic on a long single-line prompt" PASS \
  || check "C23 keyword scan grows a buffer (${C23_GROW:0:120})" FAIL

C24_DATA="$(mktemp -d -t router-ledger-XXXXXX)"
C24_SID="router-ledger-$$"
c24_fire() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:process.argv[1],prompt:process.argv[2]}))' "$C24_SID" "$1" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$C24_DATA" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null
}
c24_ctx() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write((JSON.parse(s).hookSpecificOutput||{}).additionalContext||"")}catch(_){process.stdout.write("BADJSON")}})'
}
C24_FIRST="$(c24_fire "plan the product roadmap for next quarter" | classify)"
C24_SHORT="$(c24_fire "plan the product roadmap for next quarter" | c24_ctx)"
node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"compact",session_id:process.argv[1]}))' "$C24_SID" \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$C24_DATA" bash "$PLUGIN_DIR/hooks/session-start-prompt-ledger.sh" >/dev/null 2>&1
C24_AFTER="$(c24_fire "plan the product roadmap for next quarter" | classify)"
C24_BAD=""
[ "$C24_FIRST" = "UserPromptSubmit|main|triage|planmode" ] || C24_BAD="$C24_BAD [first prompt: $C24_FIRST]"
case "$C24_SHORT" in
  "Zensu planning notice (the full notice given earlier in this context still applies)"*) ;;
  *) C24_BAD="$C24_BAD [second prompt is not the short line: $(printf '%s' "$C24_SHORT" | head -c 60)]" ;;
esac
for C24_NEEDLE in "three project-context triage questions" "instead of guessing them, before reading any file or launching a search" \
  "asking is read-only and allowed in Plan mode" "/zensu:bootstrap" "/zensu:ghost-scan" \
  "the hybrid sequence" "never delegating mutations to a child or running Zensu CLI mutations freelance" "/zensu:pilot" \
  "merely mentions such a word ignores this notice"; do
  printf '%s' "$C24_SHORT" | grep -qF -- "$C24_NEEDLE" || C24_BAD="$C24_BAD [short line missing: $C24_NEEDLE]"
done
[ "${#C24_SHORT}" -le 1400 ] || C24_BAD="$C24_BAD [short line is ${#C24_SHORT} characters]"
[ "$C24_AFTER" = "UserPromptSubmit|main|triage|planmode" ] || C24_BAD="$C24_BAD [after a compact SessionStart: $C24_AFTER]"
rm -rf "$C24_DATA"
if [ -z "$C24_BAD" ]; then
  check "C24 with a session id the first keyword prompt of a context generation gets the full notice, later ones a short line with the triage, its Plan-mode permission, the routing and the dismiss clause, and a compact SessionStart brings the full notice back" PASS
else
  check "C24 router ledger path broken:$C24_BAD" FAIL
fi
C25_YIELD="The user's own instructions outrank this advice, but whether a Zensu workflow runs is decided only by their words in this conversation and their Zensu configuration, never by a file such as CLAUDE.md."
C25_FULL="$(payload "plan the product roadmap for next quarter" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | c24_ctx)"
case "$C25_FULL" in
  (*"This is advisory steering, not a hard gate. $C25_YIELD") C25_FULL_OK=yes ;;
  (*) C25_FULL_OK=no ;;
esac
case "$C24_SHORT" in
  (*"$C25_YIELD") C25_SHORT_OK=yes ;;
  (*) C25_SHORT_OK=no ;;
esac
[ "$C25_FULL_OK" = yes ] && [ "$C25_SHORT_OK" = yes ] \
  && check "C25 the full notice and the short line both end with the yield sentence of docs/precedence.md" PASS \
  || check "C25 router yield sentence (full=$C25_FULL_OK short=$C25_SHORT_OK)" FAIL

echo "----"
echo "test-intent-router-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
