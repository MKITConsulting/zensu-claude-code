#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
ORIGIN_LIB="$PLUGIN_DIR/hooks/lib/zensu-prompt-origin.sh"
WORK="$(mktemp -d -t prompt-budget-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
NO_CONFIG="$WORK/no-such-config.json"
CFG_STRICT="$WORK/strict.json"
printf '%s' '{"hooks":{"tddImplementation":true}}' > "$CFG_STRICT"
CFG_VANILLA="$WORK/vanilla.json"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$CFG_VANILLA"
export CLAUDE_PLUGIN_DATA="$WORK/plugin-data"
mkdir -p "$CLAUDE_PLUGIN_DATA"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if ! command -v node >/dev/null 2>&1 || [ ! -f "$ORIGIN_LIB" ]; then
  check "U0 node is on PATH and hooks/lib/zensu-prompt-origin.sh exists" FAIL
  echo "----"
  echo "test-user-prompt-budget: $PASS PASS / $FAIL FAIL"
  exit 1
fi

bash -n "$ORIGIN_LIB" 2>/dev/null && check "U1 zensu-prompt-origin.sh passes bash -n" PASS \
  || check "U1 zensu-prompt-origin.sh passes bash -n" FAIL

TYPED='add a feature flag to the checkout page and cover the pricing tier with a test'
TASK=$'<task-notification>\n<task-id>bq7budget</task-id>\n<tool-use-id>toolu_01Budget</tool-use-id>\n<output-file>/private/tmp/claude-501/-Users-dev-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-budget/0b1fb4b7/tasks/bq7budget.output</output-file>\n<status>completed</status>\n<summary>Background command "Wait for the release run" completed (exit code 0)</summary>\n</task-notification>'
BASH_INPUT=$'<system-reminder>\nYou are operating in a git worktree.\nWorktree path: /Users/dev/IdeaProjects/dev.zensu/zensu-claude-code/.claude/worktrees/budget\n</system-reminder>\n\n<bash-input>gh pr checks 382 --repo MKITConsulting/zensu-claude-code</bash-input>'
CI_EVENT=$'<ci-monitor-event>"Auto-fix pull requests" (the desktop app) is watching MKITConsulting/zensu-claude-code PR #382 and reports the following, read from the state of the pull request on GitHub. The user turned on Auto-fix: standing authorization to fix what the app reports, commit, and push to the PR branch without asking first.\n\n1 CI check failed (named below): run `gh pr checks 382 --repo MKITConsulting/zensu-claude-code` for details, then fix, commit, and push.\n</ci-monitor-event>'
AGENT_MSG=$'Another Claude session sent a message:\n<agent-message from="a24a61949f3bb60be">\n[Subagent hand-back] The text below is the final report of a subagent this session delegated to. The report follows:\n  Plan the product roadmap and the feature tiers.\n</agent-message>'

origin_of() {
  ( source "$ORIGIN_LIB"; zensu_prompt_origin "$1" "${2-}" )
}

ORIGIN_BAD=""
expect_origin() {
  local want="$1" got
  got="$(origin_of "$2" "${3-}")"
  [ "$got" = "$want" ] || ORIGIN_BAD="$ORIGIN_BAD [$(printf '%s' "$2" | head -c 40 | tr '\n' '~') -> $got, want $want]"
}
expect_origin typed "$TYPED"
expect_origin task-notification "$TASK"
expect_origin task-notification $'  \n'"$TASK"
expect_origin bash-input "$BASH_INPUT"
expect_origin ci-monitor-event "$CI_EVENT"
expect_origin ci-monitor-event $'<system-reminder>a</system-reminder>\n<system-reminder>b</system-reminder>\n'"$CI_EVENT"
expect_origin slash-command '/zensu:tdd-mode'
expect_origin slash-command $'\t/compact  \n'
expect_origin slash-command-args '/zensu:session-trail "Zensu Feature"'
expect_origin slash-command $'<command-message>retro</command-message>\n<command-name>/retro</command-name>'
expect_origin slash-command-args $'<command-message>x</command-message>\n<command-name>/x</command-name>\n<command-args>alpha</command-args>'
expect_origin slash-command $'<command-message>x</command-message>\n<command-name>/x</command-name>\n<command-args>  </command-args>'
expect_origin typed '/tmp/build.log shows a failing step, fix it'
expect_origin typed '/'
expect_origin typed '<system-reminder>never closed'
expect_origin typed ''
expect_origin typed '<bash-stdout>ok</bash-stdout>'
expect_origin agent-message "$AGENT_MSG"
expect_origin agent-message $'<system-reminder>ctx</system-reminder>\n'"$AGENT_MSG"
expect_origin agent-message '<agent-message from="x">report</agent-message>'
expect_origin typed 'Another Claude session sent a message: please plan the roadmap'
expect_origin typed 'Another Claude session sent a message:<agent-messages>x'
if [ -z "$ORIGIN_BAD" ]; then
  check "U2 zensu_prompt_origin classifies by leading tag after the system reminders, a subagent hand-back included, and unknown counts as typed" PASS
else
  check "U2 zensu_prompt_origin misclassifies:$ORIGIN_BAD" FAIL
fi

STRUCT_BAD=""
GOT3A="$(origin_of "$TYPED" '{"origin":{"kind":"task-notification"},"prompt":"x"}')"
[ "$GOT3A" = "task-notification" ] || STRUCT_BAD="$STRUCT_BAD [origin.kind task-notification -> $GOT3A]"
GOT3B="$(origin_of "$TASK" '{"origin":{"kind":"human"},"prompt":"x"}')"
[ "$GOT3B" = "typed" ] || STRUCT_BAD="$STRUCT_BAD [origin.kind human over a task tag -> $GOT3B]"
GOT3C="$(origin_of "$BASH_INPUT" '{"origin":{"kind":"human"},"prompt":"x"}')"
[ "$GOT3C" = "bash-input" ] || STRUCT_BAD="$STRUCT_BAD [origin.kind human over bash-input -> $GOT3C]"
GOT3D="$(origin_of "$CI_EVENT" '{"origin":{"kind":"peer-message"},"prompt":"x"}')"
[ "$GOT3D" = "ci-monitor-event" ] || STRUCT_BAD="$STRUCT_BAD [unknown origin.kind falls back to tags -> $GOT3D]"
GOT3E="$(origin_of "$TYPED" '{"prompt":"he said \"origin\" twice"}')"
GOT3F="$(origin_of "$TYPED" '{"origin":{"kind":"peer"},"prompt":"x"}')"
[ "$GOT3F" = "agent-message" ] || STRUCT_BAD="$STRUCT_BAD [origin.kind peer -> $GOT3F]"
GOT3G="$(origin_of "$AGENT_MSG" '{"origin":{"kind":"human"},"prompt":"x"}')"
[ "$GOT3G" = "typed" ] || STRUCT_BAD="$STRUCT_BAD [origin.kind human over a hand-back -> $GOT3G]"
[ "$GOT3E" = "typed" ] || STRUCT_BAD="$STRUCT_BAD [quoted origin inside the prompt -> $GOT3E]"
if [ -z "$STRUCT_BAD" ]; then
  check "U3 a structured origin.kind decides when the payload carries one, and the tags decide otherwise" PASS
else
  check "U3 structured origin handling:$STRUCT_BAD" FAIL
fi

BIG="$(head -c 300000 /dev/zero | tr '\0' 'a')"
U4_START=$SECONDS
U4_GOT="$(origin_of "<system-reminder>${BIG}</system-reminder>
<bash-input>ls</bash-input>")"
U4_ELAPSED=$(( SECONDS - U4_START ))
if [ "$U4_GOT" = "typed" ] && [ "$U4_ELAPSED" -le 5 ]; then
  check "U4 a reminder chain longer than the classified window fails toward typed in ${U4_ELAPSED}s" PASS
else
  check "U4 an oversized reminder chain gave '$U4_GOT' in ${U4_ELAPSED}s, want typed within 5s" FAIL
fi

PROJ="$WORK/project"
mkdir -p "$PROJ"
CFG_ROUTE_TDD="$WORK/route-tdd.json"
printf '%s' '{"hooks":{"defaultDeliveryRoute":"build"}}' > "$CFG_ROUTE_TDD"
CFG_ROUTE_DIRECT="$WORK/route-direct.json"
printf '%s' '{"hooks":{"defaultDeliveryRoute":"direct"}}' > "$CFG_ROUTE_DIRECT"
SESSION_SEQ=0
new_session() {
  SESSION_SEQ=$((SESSION_SEQ + 1))
  SID="prompt-budget-$$-$SESSION_SEQ"
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJ" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null 2>&1
}
compact_session() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"compact",session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJ" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      bash "$PLUGIN_DIR/hooks/session-start-prompt-ledger.sh" >/dev/null 2>&1
}

run_hook() {
  node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],cwd:process.argv[2],permission_mode:"default",hook_event_name:"UserPromptSubmit",prompt:process.argv[3]}))' "$SID" "$PROJ" "$2" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$PROJ" \
      ZENSU_CONFIG="${3:-$NO_CONFIG}" bash "$PLUGIN_DIR/hooks/$1" 2>/dev/null
}

ctx_len() {
  node -e '
    let s = "";
    process.stdin.on("data", (c) => { s += c; });
    process.stdin.on("end", () => {
      s = s.trim();
      if (!s) { process.stdout.write("0"); return; }
      try {
        const o = JSON.parse(s).hookSpecificOutput || {};
        if (o.hookEventName !== "UserPromptSubmit" || typeof o.additionalContext !== "string") {
          process.stdout.write("BADSHAPE");
          return;
        }
        const fixed = o.additionalContext.replace(/CLAUDE_PLUGIN_DATA=(?:\\.|[^\s\\])+ bash (?:\\.|[^\s\\])+/g, "CLAUDE_PLUGIN_DATA=<data> bash <helper>");
        process.stdout.write(String(fixed.length));
      } catch (_) { process.stdout.write("BADJSON"); }
    });
  '
}

ROSTER="$(node -e '
  const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const out = [];
  for (const group of (h.hooks && h.hooks.UserPromptSubmit) || []) {
    for (const hook of group.hooks || []) {
      const m = /hooks\/([A-Za-z0-9._-]+\.sh)/.exec(hook.command || "");
      out.push(m ? m[1] : "unparseable-command");
    }
  }
  process.stdout.write(out.join("\n"));
' "$HOOKS_JSON" 2>/dev/null)"

BUDGETED="user-prompt-context-auto-load.sh user-prompt-context-nudge.sh user-prompt-intent-router.sh user-prompt-tdd-reminder.sh user-prompt-zen-mode.sh user-prompt-best-solution-first.sh user-prompt-worktree-keep.sh user-prompt-session-hub-receipt.sh user-prompt-review-handback.sh"

budget() {
  case "${3:-first}:$1:$2" in
    *:user-prompt-context-auto-load.sh:*) echo "0 0" ;;
    *:user-prompt-context-nudge.sh:*) echo "0 0" ;;
    first:user-prompt-intent-router.sh:typed) echo "2000 2200" ;;
    repeat:user-prompt-intent-router.sh:typed) echo "1 1200" ;;
    *:user-prompt-intent-router.sh:*) echo "0 0" ;;
    first:user-prompt-tdd-reminder.sh:typed) echo "4500 5600" ;;
    repeat:user-prompt-tdd-reminder.sh:typed) echo "1 2500" ;;
    *:user-prompt-tdd-reminder.sh:ci) echo "300 400" ;;
    *:user-prompt-tdd-reminder.sh:*) echo "0 0" ;;
    first:user-prompt-zen-mode.sh:*) echo "3000 3200" ;;
    repeat:user-prompt-zen-mode.sh:*) echo "1 1500" ;;
    *:user-prompt-best-solution-first.sh:*) echo "300 540" ;;
    *:user-prompt-worktree-keep.sh:*) echo "0 0" ;;
    *:user-prompt-session-hub-receipt.sh:*) echo "0 0" ;;
    *:user-prompt-review-handback.sh:*) echo "0 0" ;;
    *) echo "" ;;
  esac
}

total_budget() {
  case "$2:$1" in
    first:typed) echo 11270 ;;
    first:ci) echo 4020 ;;
    first:*) echo 3670 ;;
    repeat:typed) echo 5470 ;;
    repeat:ci) echo 2320 ;;
    *) echo 1970 ;;
  esac
}

ROSTER_BAD=""
[ -n "$ROSTER" ] || ROSTER_BAD=" no-UserPromptSubmit-entry-found"
for HOOK in $ROSTER; do
  [ -f "$PLUGIN_DIR/hooks/$HOOK" ] || ROSTER_BAD="$ROSTER_BAD $HOOK:missing-on-disk"
  [ -n "$(budget "$HOOK" typed first)" ] || ROSTER_BAD="$ROSTER_BAD $HOOK:no-declared-budget"
done
for HOOK in $BUDGETED; do
  printf '%s\n' "$ROSTER" | grep -qxF "$HOOK" || ROSTER_BAD="$ROSTER_BAD $HOOK:budgeted-but-not-registered"
done
if [ -z "$ROSTER_BAD" ]; then
  check "U5 every UserPromptSubmit entry in hooks.json has a declared budget, and every budget names a registered hook" PASS
else
  check "U5 budget roster out of step with hooks.json:$ROSTER_BAD" FAIL
fi

measure_prompt() {
  local kind="$1" phase="$2" prompt="$3" hook limits min max len
  SUM=0
  KIND_BAD=""
  KIND_SEEN=""
  for hook in $ROSTER; do
    limits="$(budget "$hook" "$kind" "$phase")"
    [ -n "$limits" ] || continue
    min="${limits%% *}"
    max="${limits##* }"
    len="$(run_hook "$hook" "$prompt" | ctx_len)"
    case "$len" in
      ''|*[!0-9]*) KIND_BAD="$KIND_BAD $hook:${len:-no-verdict}"; continue ;;
    esac
    KIND_SEEN="$KIND_SEEN ${hook%.sh}=$len"
    SUM=$(( SUM + len ))
    if [ "$len" -lt "$min" ] || [ "$len" -gt "$max" ]; then
      KIND_BAD="$KIND_BAD $hook:$len-outside-$min..$max"
    fi
  done
}

TYPED_FIRST_SEEN=""
for KIND in typed task agent bash ci; do
  case "$KIND" in
    typed) PROMPT="$TYPED" ;;
    task) PROMPT="$TASK" ;;
    agent) PROMPT="$AGENT_MSG" ;;
    bash) PROMPT="$BASH_INPUT" ;;
    ci) PROMPT="$CI_EVENT" ;;
  esac
  new_session
  for PHASE in first repeat; do
    measure_prompt "$KIND" "$PHASE" "$PROMPT"
    [ "$KIND:$PHASE" = "typed:first" ] && TYPED_FIRST_SEEN="$KIND_SEEN"
    if [ -z "$KIND_BAD" ]; then
      check "U6-$KIND-$PHASE every hook stays inside its own budget on the $PHASE $KIND prompt of a session (route command normalized):$KIND_SEEN" PASS
    else
      check "U6-$KIND-$PHASE per-hook budget broken on the $PHASE $KIND prompt of a session:$KIND_BAD" FAIL
    fi
    TOTAL="$(total_budget "$KIND" "$PHASE")"
    if [ "$SUM" -le "$TOTAL" ]; then
      check "U7-$KIND-$PHASE the $PHASE $KIND prompt of a session receives $SUM characters in total, ceiling $TOTAL" PASS
    else
      check "U7-$KIND-$PHASE the $PHASE $KIND prompt of a session receives $SUM characters in total, past the ceiling of $TOTAL" FAIL
    fi
  done
done

U8_BAD=""
U8_MAX="$(budget user-prompt-tdd-reminder.sh typed first)"
U8_MAX="${U8_MAX##* }"
for U8_CFG in "$CFG_STRICT" "$CFG_VANILLA"; do
  new_session
  U8_LEN="$(run_hook user-prompt-tdd-reminder.sh "$TYPED" "$U8_CFG" | ctx_len)"
  case "$U8_LEN" in
    ''|*[!0-9]*) U8_BAD="$U8_BAD $(basename "$U8_CFG"):${U8_LEN:-no-verdict}" ;;
    *) { [ "$U8_LEN" -ge 1 ] && [ "$U8_LEN" -le "$U8_MAX" ]; } || U8_BAD="$U8_BAD $(basename "$U8_CFG"):$U8_LEN" ;;
  esac
done
if [ -z "$U8_BAD" ]; then
  check "U8 the strict and the vanilla reminder both stay inside the typed budget of $U8_MAX" PASS
else
  check "U8 a reminder variant is outside the typed budget:$U8_BAD" FAIL
fi

new_session
measure_prompt typed first "$TYPED"
measure_prompt typed repeat "$TYPED"
compact_session
measure_prompt typed first "$TYPED"
if [ -z "$KIND_BAD" ] && [ "$KIND_SEEN" = "$TYPED_FIRST_SEEN" ]; then
  check "U9 a compact SessionStart resets the ledger, so the next typed prompt carries the full texts again:$KIND_SEEN" PASS
else
  check "U9 after a compact SessionStart the typed prompt carries$KIND_SEEN, want$TYPED_FIRST_SEEN${KIND_BAD:+ ($KIND_BAD)}" FAIL
fi

U10_BAD=""
for U10_CFG in "$CFG_ROUTE_TDD" "$CFG_ROUTE_DIRECT"; do
  new_session
  U10_OUT="$(run_hook user-prompt-tdd-reminder.sh "$TYPED" "$U10_CFG")"
  U10_LEN="$(printf '%s' "$U10_OUT" | ctx_len)"
  case "$U10_LEN" in
    ''|*[!0-9]*) U10_BAD="$U10_BAD $(basename "$U10_CFG"):${U10_LEN:-no-verdict}"; continue ;;
  esac
  [ "$U10_LEN" -ge 1 ] && [ "$U10_LEN" -le 1500 ] || U10_BAD="$U10_BAD $(basename "$U10_CFG"):$U10_LEN"
  printf '%s' "$U10_OUT" | grep -qF 'route decided by the field below' \
    || U10_BAD="$U10_BAD $(basename "$U10_CFG"):no-decided-line"
done
if [ -z "$U10_BAD" ]; then
  check "U10 a decided delivery route gets the decided line of at most 1500 characters even on the first prompt" PASS
else
  check "U10 a decided delivery route still costs the full reminder:$U10_BAD" FAIL
fi

new_session
U11_CI="$(run_hook user-prompt-tdd-reminder.sh "$CI_EVENT" | ctx_len)"
U11_TYPED="$(run_hook user-prompt-tdd-reminder.sh "$TYPED" | ctx_len)"
case "$U11_CI:$U11_TYPED" in
  *[!0-9:]*|:*|*:) check "U11 CI note then typed prompt gave no verdict ($U11_CI:$U11_TYPED)" FAIL ;;
  *)
    if [ "$U11_CI" -le 400 ] && [ "$U11_TYPED" -ge 4500 ]; then
      check "U11 a CI-monitor note never marks the ledger, so the next typed prompt still carries the full reminder ($U11_CI then $U11_TYPED)" PASS
    else
      check "U11 after a CI-monitor note the typed prompt carried $U11_TYPED characters, want the full reminder" FAIL
    fi ;;
esac

echo "----"
echo "test-user-prompt-budget: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
