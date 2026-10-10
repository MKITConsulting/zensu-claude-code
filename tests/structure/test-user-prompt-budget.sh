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
if [ -z "$ORIGIN_BAD" ]; then
  check "U2 zensu_prompt_origin classifies by leading tag after the system reminders, and unknown counts as typed" PASS
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
SID="prompt-budget-$$"
mkdir -p "$PROJ"
node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJ" \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null 2>&1

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

BUDGETED="user-prompt-context-nudge.sh user-prompt-intent-router.sh user-prompt-tdd-reminder.sh user-prompt-zen-mode.sh user-prompt-best-solution-first.sh user-prompt-worktree-keep.sh"

budget() {
  case "$1:$2" in
    user-prompt-context-nudge.sh:*) echo "0 0" ;;
    user-prompt-intent-router.sh:typed) echo "1 2200" ;;
    user-prompt-intent-router.sh:*) echo "0 0" ;;
    user-prompt-tdd-reminder.sh:typed) echo "1 5600" ;;
    user-prompt-tdd-reminder.sh:ci) echo "1 400" ;;
    user-prompt-tdd-reminder.sh:*) echo "0 0" ;;
    user-prompt-zen-mode.sh:*) echo "1 3200" ;;
    user-prompt-best-solution-first.sh:*) echo "1 1800" ;;
    user-prompt-worktree-keep.sh:*) echo "0 0" ;;
    *) echo "" ;;
  esac
}

total_budget() {
  case "$1" in
    typed) echo 12600 ;;
    ci) echo 5300 ;;
    *) echo 4950 ;;
  esac
}

ROSTER_BAD=""
[ -n "$ROSTER" ] || ROSTER_BAD=" no-UserPromptSubmit-entry-found"
for HOOK in $ROSTER; do
  [ -f "$PLUGIN_DIR/hooks/$HOOK" ] || ROSTER_BAD="$ROSTER_BAD $HOOK:missing-on-disk"
  [ -n "$(budget "$HOOK" typed)" ] || ROSTER_BAD="$ROSTER_BAD $HOOK:no-declared-budget"
done
for HOOK in $BUDGETED; do
  printf '%s\n' "$ROSTER" | grep -qxF "$HOOK" || ROSTER_BAD="$ROSTER_BAD $HOOK:budgeted-but-not-registered"
done
if [ -z "$ROSTER_BAD" ]; then
  check "U5 every UserPromptSubmit entry in hooks.json has a declared budget, and every budget names a registered hook" PASS
else
  check "U5 budget roster out of step with hooks.json:$ROSTER_BAD" FAIL
fi

for KIND in typed task bash ci; do
  case "$KIND" in
    typed) PROMPT="$TYPED" ;;
    task) PROMPT="$TASK" ;;
    bash) PROMPT="$BASH_INPUT" ;;
    ci) PROMPT="$CI_EVENT" ;;
  esac
  SUM=0
  KIND_BAD=""
  KIND_SEEN=""
  for HOOK in $ROSTER; do
    LIMITS="$(budget "$HOOK" "$KIND")"
    [ -n "$LIMITS" ] || continue
    MIN="${LIMITS%% *}"
    MAX="${LIMITS##* }"
    LEN="$(run_hook "$HOOK" "$PROMPT" | ctx_len)"
    case "$LEN" in
      ''|*[!0-9]*) KIND_BAD="$KIND_BAD $HOOK:${LEN:-no-verdict}"; continue ;;
    esac
    KIND_SEEN="$KIND_SEEN ${HOOK%.sh}=$LEN"
    SUM=$(( SUM + LEN ))
    if [ "$LEN" -lt "$MIN" ] || [ "$LEN" -gt "$MAX" ]; then
      KIND_BAD="$KIND_BAD $HOOK:$LEN-outside-$MIN..$MAX"
    fi
  done
  if [ -z "$KIND_BAD" ]; then
    check "U6-$KIND every hook stays inside its own budget on a $KIND prompt (route command normalized):$KIND_SEEN" PASS
  else
    check "U6-$KIND per-hook budget broken on a $KIND prompt:$KIND_BAD" FAIL
  fi
  TOTAL="$(total_budget "$KIND")"
  if [ "$SUM" -le "$TOTAL" ]; then
    check "U7-$KIND a $KIND prompt receives $SUM characters in total, ceiling $TOTAL" PASS
  else
    check "U7-$KIND a $KIND prompt receives $SUM characters in total, past the ceiling of $TOTAL" FAIL
  fi
done

U8_BAD=""
U8_MAX="$(budget user-prompt-tdd-reminder.sh typed)"
U8_MAX="${U8_MAX##* }"
for U8_CFG in "$CFG_STRICT" "$CFG_VANILLA"; do
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

echo "----"
echo "test-user-prompt-budget: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
