#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
NO_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/user-prompt-tdd-reminder.sh exists" FAIL
  echo "----"
  echo "test-tdd-reminder-hook: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "C1 hook exists + executable" PASS || check "C1 hook exists + executable" FAIL

bash -n "$HOOK" 2>/dev/null && check "C2 bash -n syntax check passes" PASS || check "C2 bash -n syntax check passes" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");
  process.exit(ups.some(c=>/user-prompt-tdd-reminder\.sh/.test(c))?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "C3 registered in hooks.json UserPromptSubmit" PASS
else
  check "C3 registered in hooks.json UserPromptSubmit" FAIL
fi

if grep -qF 'zensu_hook_enabled' "$HOOK" && grep -qF 'tddReminder' "$HOOK"; then
  check "C4 gated by hooks.tddReminder (zensu_hook_enabled tddReminder)" PASS
else
  check "C4 gated by hooks.tddReminder (zensu_hook_enabled tddReminder)" FAIL
fi

if grep -qF 'UserPromptSubmit' "$HOOK" && grep -qF 'hookEventName' "$HOOK" && grep -qF 'additionalContext' "$HOOK"; then
  check "C5 builds UserPromptSubmit additionalContext" PASS
else
  check "C5 builds UserPromptSubmit additionalContext" FAIL
fi

payload() {
  local prompt="$1" session_id="${2:-t}" project="${3:-${CLAUDE_PROJECT_DIR:-}}"
  local plugin_data="$project/plugin-data"
  mkdir -p "$project" "$plugin_data"
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"SessionStart", source:"startup",
    session_id:process.argv[1], cwd:process.argv[2]
  }))' "$session_id" "$project" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$plugin_data" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null || return 1
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"UserPromptSubmit", prompt:process.argv[1], session_id:process.argv[2]
  }))' "$prompt" "$session_id"
}

# Reduce the hook output to FIRED (TDD directive present) / EMPTY (silent) /
# NOMATCH (fired but missing the expected directive) / BADJSON (malformed).
fired() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        const ac=o.additionalContext||"";
        const ok=(o.hookEventName==="UserPromptSubmit")&&/zensu:tdd/.test(ac)&&/AskUserQuestion/.test(ac);
        process.stdout.write(ok?"FIRED":"NOMATCH");
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

# C6 — a non-planning code prompt (the intent-router stays SILENT on this one)
# must FIRE here: every-turn, no keyword filter.
P6="$(mktemp -d -t tddrem-XXXXXX)"
OUT6="$(payload "fix the auth token expiry bug" "s6" "$P6" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P6/plugin-data" CLAUDE_PROJECT_DIR="$P6" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT6" = "FIRED" ] && check "C6 non-planning code prompt fires the TDD directive" PASS || check "C6 non-planning fires (got '$OUT6')" FAIL
rm -rf "$P6"

# C7 — a German prompt fires IDENTICALLY (proves language-independence: no regex).
P7="$(mktemp -d -t tddrem-XXXXXX)"
OUT7="$(payload "behebe den Login-Fehler im Auth-Service" "s7" "$P7" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P7/plugin-data" CLAUDE_PROJECT_DIR="$P7" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT7" = "FIRED" ] && check "C7 German prompt fires identically (language-independent, no regex)" PASS || check "C7 German fires (got '$OUT7')" FAIL
rm -rf "$P7"

# C8 — empty prompt -> silent, exit 0 (fail-open).
P8="$(mktemp -d -t tddrem-XXXXXX)"
OUT8="$(printf '%s' '{"prompt":"","session_id":"s8"}' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P8" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC8=$?
if [ "$RC8" = "0" ] && [ -z "$OUT8" ]; then
  check "C8 empty prompt -> exit 0, silent (fail-open)" PASS
else
  check "C8 empty prompt (rc=$RC8 out='$OUT8')" FAIL
fi
rm -rf "$P8"

# C9 — hooks.tddReminder:false -> silent (opt-out honored).
P9="$(mktemp -d -t tddrem-XXXXXX)"
CFG9="$P9/config.json"; printf '%s' '{"hooks":{"tddReminder":false}}' > "$CFG9"
OUT9="$(payload "implement a debounce helper" "s9" "$P9" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P9/plugin-data" CLAUDE_PROJECT_DIR="$P9" ZENSU_CONFIG="$CFG9" bash "$HOOK" 2>/dev/null | fired)"
[ "$OUT9" = "EMPTY" ] && check "C9 hooks.tddReminder:false -> silent (opt-out honored)" PASS || check "C9 disabled silent (got '$OUT9')" FAIL
rm -rf "$P9"

# C10 — an active TDD session -> silent (the TDD flow owns the reminder there).
P10="$(mktemp -d -t tddrem-XXXXXX)"
OUT10="$(
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P10" ZENSU_CONFIG="$NO_CONFIG"
  export ZENSU_TEST_PLUGIN_DATA="$P10/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" s10
  bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin --session s10 >/dev/null 2>&1
  payload "add validation to the parser" "s10" "$P10" | bash "$HOOK" 2>/dev/null | fired
)"
[ "$OUT10" = "EMPTY" ] && check "C10 active TDD session -> silent" PASS || check "C10 active-session silence (got '$OUT10')" FAIL
rm -rf "$P10"

# C11 — config.example.json registers the flag.
if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit(j.hooks && j.hooks.tddReminder===true ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "C11 config.example.json has hooks.tddReminder" PASS
else
  check "C11 config.example.json has hooks.tddReminder" FAIL
fi

# C12 — the directive front-loads ask-first, the fast-paths, and the dismiss clauses.
P12="$(mktemp -d -t tddrem-XXXXXX)"
AC12="$(payload "build a rate limiter" "s12" "$P12" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P12/plugin-data" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if [ -n "$AC12" ] \
   && printf '%s' "$AC12" | grep -qi 'AskUserQuestion' \
   && printf '%s' "$AC12" | grep -qi 'use tdd' \
   && printf '%s' "$AC12" | grep -qi 'no tdd' \
   && printf '%s' "$AC12" | grep -qi 'Auto Mode' \
   && printf '%s' "$AC12" | grep -qi 'Plan mode' \
   && printf '%s' "$AC12" | grep -qi 'IGNORE' \
   && printf '%s' "$AC12" | grep -qF 'ZENSU DELIVERY ROUTE:' \
   && printf '%s' "$AC12" | grep -qF '/zensu:delivery-route'; then
  check "C12 directive carries ask-first + fast-paths (use/no tdd, Auto Mode) + dismiss clauses (Plan mode, IGNORE) + the delivery-route field" PASS
else
  fired12="$([ -n "$AC12" ] && echo yes || echo no)"
  check "C12 directive content (fired=$fired12)" FAIL
fi
rm -rf "$P12"

# Explicit and partial subagent metadata must be a total no-op before the
# reminder can expose main-thread steering. Ambient force-main cannot override
# the trusted payload classifier.
P13="$(mktemp -d -t tddrem-XXXXXX)"
BASE13="$(payload "implement a privileged helper" "s13" "$P13")"
OUT13=""
for KIND13 in reviewer plm neutral partial; do
  PAYLOAD13="$(BASE="$BASE13" KIND="$KIND13" node -e '
    const p=JSON.parse(process.env.BASE);
    if(process.env.KIND==="reviewer")p.agent_type="zensu:code-reviewer";
    if(process.env.KIND==="plm")p.agent_type="zensu:zensu-plm";
    if(process.env.KIND==="neutral")p.agent_type="custom-agent";
    if(process.env.KIND==="partial")p.agent_id="child-only";
    process.stdout.write(JSON.stringify(p));
  ')"
  OUT13="${OUT13}$(printf '%s' "$PAYLOAD13" | ZENSU_FORCE_MAIN=1 CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$P13/plugin-data" CLAUDE_PROJECT_DIR="$P13" ZENSU_CONFIG="$NO_CONFIG" \
    bash "$HOOK" 2>/dev/null)"
done
if [ -z "$OUT13" ]; then
  check "C13 reviewer/PLM/neutral/partial principals receive no TDD reminder" PASS
else
  check "C13 non-main principals receive no TDD reminder" FAIL
fi
rm -rf "$P13"

P14="$(mktemp -d -t tddrem-XXXXXX)"
OUT14=""
N14=0
for PROMPT14 in \
  "$(printf '<task-notification>\n<task-id>b14</task-id>\n<status>completed</status>\n</task-notification>')" \
  "$(printf '<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>\n\n<bash-input>git status</bash-input>')" \
  "/zensu:tdd-mode"; do
  N14=$((N14 + 1))
  PAYLOAD14="$(payload "$PROMPT14" "s14-$N14" "$P14")" || PAYLOAD14=""
  [ -n "$PAYLOAD14" ] || OUT14="${OUT14}[no-payload-$N14]"
  OUT14="${OUT14}$(printf '%s' "$PAYLOAD14" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P14/plugin-data" CLAUDE_PROJECT_DIR="$P14" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
done
OUT14B="$(payload "/zensu:tdd add a retry helper" "s14-args" "$P14" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P14/plugin-data" CLAUDE_PROJECT_DIR="$P14" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | fired)"
if [ -z "$OUT14" ] && [ "$OUT14B" = "FIRED" ]; then
  check "C14 task notifications, shell inputs and argument-less slash commands get no reminder; a slash command with arguments does" PASS
else
  check "C14 origin gate (harness output='${OUT14:0:60}' slash-with-args='$OUT14B')" FAIL
fi
rm -rf "$P14"

P15="$(mktemp -d -t tddrem-XXXXXX)"
CI15="$(printf '<ci-monitor-event>"Auto-fix pull requests" is watching owner/repo PR #7: standing authorization to fix, commit, and push.\n1 CI check failed: run `gh pr checks 7 --repo owner/repo`, then fix, commit, and push.\n</ci-monitor-event>')"
AC15="$(payload "$CI15" "s15" "$P15" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$P15/plugin-data" CLAUDE_PROJECT_DIR="$P15" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
CTX15="$(printf '%s' "$AC15" | node -e '
  let s = "";
  process.stdin.on("data", (c) => { s += c; });
  process.stdin.on("end", () => {
    try {
      const o = JSON.parse(s).hookSpecificOutput || {};
      process.stdout.write(o.hookEventName === "UserPromptSubmit" ? String(o.additionalContext || "") : "");
    } catch (_) {}
  });
')"
LEN15="$(printf '%s' "$CTX15" | node -e 'let s = ""; process.stdin.on("data", (c) => { s += c; }); process.stdin.on("end", () => process.stdout.write(String(s.length)));')"
if [ -n "$CTX15" ] && [ "$LEN15" -le 400 ] \
   && printf '%s' "$CTX15" | grep -qF 'CI-monitor event' \
   && printf '%s' "$CTX15" | grep -qF 'standing authorization' \
   && printf '%s' "$CTX15" | grep -qF 'within the scope of that pull request' \
   && printf '%s' "$CTX15" | grep -qF 'ZENSU DELIVERY ROUTE: ask' \
   && ! printf '%s' "$CTX15" | grep -qF 'AskUserQuestion'; then
  check "C15 a CI event gets the route field and one standing-authorization sentence ($LEN15 chars), never the ask-first directive" PASS
else
  check "C15 CI-event note (len=${LEN15:-none}: ${CTX15:0:80})" FAIL
fi
rm -rf "$P15"

echo "----"
echo "test-tdd-reminder-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
