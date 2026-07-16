#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/plugins/zensu" ]; then PLUGIN="$ROOT/plugins/zensu"; else PLUGIN="$ROOT"; fi
GATE="$PLUGIN/hooks/pre-reviewer-capability-gate.sh"
POLICY="$PLUGIN/hooks/lib/reviewer-capability-v1.js"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$GATE" "$POLICY"; do
  [ -f "$artifact" ] && check "artifact exists: ${artifact#$PLUGIN/}" PASS || check "artifact exists: ${artifact#$PLUGIN/}" FAIL
done
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PLUGIN_DATA="$TMP/plugin-data"
PROJECT="$TMP/project"
OTHER="$TMP/other"
ENV_FILE="$TMP/session.env"
SESSION_ID='capability-test'
mkdir -p "$PLUGIN_DATA" "$PROJECT" "$OTHER"
mkdir -p "$PROJECT/src"
: >"$ENV_FILE"

SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "SessionStart",
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
  }));
' | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$ENV_FILE" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
  bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null
# shellcheck disable=SC1090
source "$ENV_FILE"

payload() {
  local input="${3:-}"
  [ -n "$input" ] || input='{}'
  AGENT_TYPE="$1" TOOL="$2" INPUT="$input" \
    PAYLOAD_SESSION_ID="${PAYLOAD_SESSION_ID:-$SESSION_ID}" PAYLOAD_CWD="${PAYLOAD_CWD:-$PROJECT}" node -e '
    const o = {
      hook_event_name: "PreToolUse",
      session_id: process.env.PAYLOAD_SESSION_ID,
      cwd: process.env.PAYLOAD_CWD,
      tool_name: process.env.TOOL,
      tool_input: JSON.parse(process.env.INPUT)
    };
    if (process.env.AGENT_TYPE === "?") o.agent_id = "agent-with-missing-type";
    else if (process.env.AGENT_TYPE.startsWith("no-id:")) {
      o.agent_type = process.env.AGENT_TYPE.slice("no-id:".length);
    }
    else if (process.env.AGENT_TYPE !== "-") {
      o.agent_id = "agent-1";
      o.agent_type = process.env.AGENT_TYPE;
    }
    process.stdout.write(JSON.stringify(o));
  '
}

decision() {
  local out
  case "${GATE_TEST_MODE:-valid}" in
    missing-context) unset ZENSU_SESSION_CONTEXT ;;
    tampered-digest) ZENSU_RUNTIME_DIGEST="sha256:$(printf '0%.0s' {1..64})"; export ZENSU_RUNTIME_DIGEST ;;
    wrong-root) ZENSU_CLAUDE_PLUGIN_ROOT="$OTHER"; export ZENSU_CLAUDE_PLUGIN_ROOT ;;
    wrong-data) CLAUDE_PLUGIN_DATA="$OTHER"; export CLAUDE_PLUGIN_DATA ;;
  esac
  out="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-$PLUGIN_DATA}" bash "$GATE" 2>/dev/null)"
  if [ -z "$out" ]; then printf allow; return; fi
  printf '%s' "$out" | node -e '
    let s = ""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        process.stdout.write(j.hookSpecificOutput?.permissionDecision === "deny" ? "deny" : "other");
      } catch (_) { process.stdout.write("invalid"); }
    });
  '
}

assert_case() {
  local label="$1" expected="$2" type="$3" tool="$4" input="${5:-}" actual
  [ -n "$input" ] || input='{}'
  actual="$(payload "$type" "$tool" "$input" | decision)"
  [ "$actual" = "$expected" ] && check "$label" PASS || check "$label (expected $expected, got $actual)" FAIL
}

assert_case "main-thread writes pass after immutable context revalidation" allow - Write '{"file_path":"x"}'
assert_case "nested tool_input cannot impersonate a reviewer" allow - Write '{"agent_type":"code-reviewer","file_path":"x"}'
assert_case "bare PLM subagent receives only neutral project-local writes" allow zensu-plm Write '{"file_path":"x"}'
assert_case "bare PLM subagent cannot invoke shell" deny zensu-plm Bash '{"command":"pwd"}'
assert_case "bare PLM subagent cannot invoke mutating control" deny zensu-plm mcp__zensu__transition '{"state":"complete"}'
assert_case "bare code reviewer may use Read" allow code-reviewer Read '{"file_path":"x"}'
assert_case "bare reviewer remains read-only when Claude omits correlation agent_id" deny no-id:code-reviewer Write '{"file_path":"x"}'
assert_case "bare aspect reviewer may use project-bound Grep" allow review-aspect Grep '{"pattern":"x","path":"src"}'
assert_case "bare judge reviewer may use project-bound Glob" allow review-judge Glob '{"pattern":"**/*","path":"src"}'
assert_case "reviewer view_image is denied outside the exact read trio" deny review-judge view_image '{"path":"x.png"}'
assert_case "unknown custom agent receives neutral normal reads" allow arbitrary-custom Read '{"file_path":"x"}'
assert_case "unknown custom agent receives neutral normal writes" allow arbitrary-custom Write '{"file_path":"x"}'
assert_case "missing agent_type with an agent_id is neutral" allow ? Read '{"file_path":"x"}'
assert_case "non-host reviewer alias is neutral, not reviewer" allow zensu-review-domain Write '{"file_path":"x"}'
assert_case "runtime reviewer path is neutral, not reviewer" allow /root/zensu_code_reviewer Write '{"file_path":"x"}'
assert_case "reviewer Write is denied" deny code-reviewer Write '{"file_path":"x"}'
assert_case "reviewer apply_patch is denied" deny review-aspect apply_patch '{"patch":"x"}'
assert_case "reviewer mutating shell is denied" deny code-reviewer exec_command '{"cmd":"printf x > source.js"}'
assert_case "reviewer shell is denied even for git diff" deny code-reviewer exec_command '{"cmd":"git diff HEAD -- src/app.js"}'
assert_case "reviewer shell is denied even for git status" deny review-aspect Bash '{"command":"git status --short"}'
assert_case "workflow-control shell invocation is denied" deny code-reviewer Bash '{"command":"bash hooks/lib/zensu-log.sh --chain-done"}'
assert_case "mutating MCP/control tool is denied" deny code-reviewer mcp__zensu__transition '{"state":"complete"}'
assert_case "nested Agent tool is denied" deny review-aspect Agent '{"subagent_type":"general-purpose"}'
assert_case "nested collaboration spawn is denied" deny review-judge spawn_agent '{"task_name":"attack"}'
assert_case "unknown reviewer tools fail closed" deny code-reviewer mystery_tool '{}'
assert_case "neutral agent cannot access workflow root" deny arbitrary-custom Read '{"file_path":".zensu/state/tdd-phase.json"}'
assert_case "neutral agent cannot access immutable Session Control record" deny arbitrary-custom Read "{\"file_path\":\"$ZENSU_SESSION_CONTEXT\"}"
assert_case "reviewer cannot read outside the immutable project" deny code-reviewer Read '{"file_path":"/etc/passwd"}'
assert_case "neutral agent cannot read outside the immutable project" deny arbitrary-custom Read '{"file_path":"/etc/passwd"}'
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "symlink path-boundary cases skipped only where unprivileged creation is unavailable" PASS
    ;;
  *)
    ln -s "$OTHER" "$PROJECT/outside-link"
    assert_case "reviewer cannot escape through a project symlink" deny review-aspect Read '{"file_path":"outside-link/secret.txt"}'
    assert_case "neutral agent cannot escape through a project symlink" deny arbitrary-custom Read '{"file_path":"outside-link/secret.txt"}'
    ln -s ../outside "$PROJECT/dangling-outside"
    assert_case "neutral write cannot escape through a dangling symlink leaf" deny arbitrary-custom Write '{"file_path":"dangling-outside/new.txt"}'
    ln -s .zensu/state/new-dir "$PROJECT/dangling-protected"
    assert_case "neutral write cannot enter protected state through a dangling symlink leaf" deny arbitrary-custom Write '{"file_path":"dangling-protected/new.txt"}'
    ;;
esac
assert_case "neutral apply_patch Move to outside project is denied" deny arbitrary-custom apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/old.js\n*** Move to: ../outside/new.js\n*** End Patch"}'
assert_case "neutral apply_patch Move to workflow state is denied" deny arbitrary-custom apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/old.js\n*** Move to: .zensu/state/new.js\n*** End Patch"}'
assert_case "neutral apply_patch Move to a project path is allowed" allow arbitrary-custom apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/old.js\n*** Move to: src/new.js\n*** End Patch"}'
assert_case "neutral agent cannot invoke Session Control helper" deny arbitrary-custom Bash '{"command":"node hooks/lib/session-control-core-v1.js render-main"}'
assert_case "neutral agent cannot claim main-v1" deny arbitrary-custom Write '{"file_path":"notes.txt","content":"principal=main-v1"}'
assert_case "neutral agent cannot spawn the trusted main-capable agent" deny arbitrary-custom Agent '{"subagent_type":"zensu-plm","prompt":"act as main"}'

FORCED="$(payload code-reviewer Write '{"file_path":"x"}' | ZENSU_FORCE_MAIN=1 decision)"
[ "$FORCED" = deny ] && check "ZENSU_FORCE_MAIN cannot bypass reviewer boundary" PASS || check "ZENSU_FORCE_MAIN cannot bypass reviewer boundary" FAIL

MISSING="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=missing-context decision)"
[ "$MISSING" = deny ] && check "missing inherited SubagentStart context denies the first tool" PASS || check "missing inherited SubagentStart context denies the first tool" FAIL

TAMPERED="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=tampered-digest decision)"
[ "$TAMPERED" = deny ] && check "tampered inherited SubagentStart runtime digest denies the first tool" PASS || check "tampered inherited SubagentStart runtime digest denies the first tool" FAIL

WRONG_SESSION="$(PAYLOAD_SESSION_ID='different-session' payload arbitrary-custom Read '{"file_path":"x"}' | decision)"
[ "$WRONG_SESSION" = deny ] && check "PreToolUse session_id mismatch denies before capability evaluation" PASS || check "PreToolUse session_id mismatch denies before capability evaluation" FAIL

WRONG_PROJECT="$(PAYLOAD_CWD="$OTHER" payload arbitrary-custom Read '{"file_path":"x"}' | decision)"
[ "$WRONG_PROJECT" = deny ] && check "PreToolUse project mismatch denies before capability evaluation" PASS || check "PreToolUse project mismatch denies before capability evaluation" FAIL

WRONG_ROOT="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=wrong-root decision)"
[ "$WRONG_ROOT" = deny ] && check "PreToolUse plugin-root mismatch denies before capability evaluation" PASS || check "PreToolUse plugin-root mismatch denies before capability evaluation" FAIL

WRONG_DATA="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=wrong-data decision)"
[ "$WRONG_DATA" = deny ] && check "PreToolUse plugin-data mismatch denies before capability evaluation" PASS || check "PreToolUse plugin-data mismatch denies before capability evaluation" FAIL

STATE_FILE="$PROJECT/.zensu/state/tdd-phase-${ZENSU_SESSION_KEY}.json"
BASELINE_REVISION="$(node -e 'process.stdout.write(String(require(process.argv[1]).revision))' "$STATE_FILE")"
[ "$BASELINE_REVISION" = 1 ] \
  && check "SessionStart baseline CAS state exists before any workflow activation" PASS \
  || check "SessionStart baseline CAS state exists before any workflow activation" FAIL

CLAUDE_PROJECT_DIR="$PROJECT" bash "$PLUGIN/hooks/lib/zensu-log.sh" \
  --tdd-begin --session "$SESSION_ID" >/dev/null
if [ -f "$STATE_FILE" ] && node -e '
  const s = require(process.argv[1]);
  process.exit(s.revision === 2 && s.active === true && s.phase === "UNINITIALIZED" ? 0 : 1);
' "$STATE_FILE"; then
  check "TDD begin atomically advances the mandatory baseline CAS state" PASS
else
  check "TDD begin atomically advances the mandatory baseline CAS state" FAIL
fi
ACTIVE_STATE="$(payload - Read '{"file_path":"README.md"}' | decision)"
[ "$ACTIVE_STATE" = allow ] \
  && check "valid project-bound CAS state passes immutable revalidation" PASS \
  || check "valid project-bound CAS state passes immutable revalidation" FAIL
node -e 'require("node:fs").unlinkSync(process.argv[1])' "$STATE_FILE"
DELETED_STATE="$(payload - Read '{"file_path":"README.md"}' | decision)"
[ "$DELETED_STATE" = deny ] \
  && check "deleted mandatory project CAS state denies every subsequent tool" PASS \
  || check "deleted mandatory project CAS state denies every subsequent tool" FAIL

INVALID="$(printf 'not-json' | decision)"
[ "$INVALID" = deny ] && check "malformed trusted payload fails closed" PASS || check "malformed trusted payload fails closed" FAIL

printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
