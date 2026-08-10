#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -d "$ROOT/plugins/zensu" ]; then PLUGIN="$ROOT/plugins/zensu"; else PLUGIN="$ROOT"; fi
GATE="$PLUGIN/hooks/pre-reviewer-capability-gate.sh"
POLICY="$PLUGIN/hooks/lib/reviewer-capability-v1.js"
HOST_PATH="$PLUGIN/hooks/lib/zensu-host-path.sh"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$GATE" "$POLICY" "$HOST_PATH"; do
  [ -f "$artifact" ] && check "artifact exists: ${artifact#$PLUGIN/}" PASS || check "artifact exists: ${artifact#$PLUGIN/}" FAIL
done
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi

RAW_TMP="$(mktemp -d "${TMPDIR:-/tmp}/reviewer-capability-XXXXXX")"
RAW_TMP="$(cd -P -- "$RAW_TMP" && pwd -P)"
TMP="$(bash "$HOST_PATH" "$RAW_TMP")" || {
  rm -rf -- "$RAW_TMP"
  printf '%s\n' 'reviewer capability fixture could not render its native host path' >&2
  exit 1
}
trap 'rm -rf "$RAW_TMP"' EXIT
PLUGIN_DATA="$TMP/plugin-data"
MISSING_DATA="$TMP/missing-plugin-data"
TAMPERED_DATA="$TMP/tampered-plugin-data"
PROJECT="$TMP/project"
OTHER="$TMP/other"
SESSION_ID='capability-test'
mkdir -p "$PLUGIN_DATA" "$MISSING_DATA" "$TAMPERED_DATA" "$PROJECT" "$OTHER"
mkdir -p "$PROJECT/src/nested"
touch "$PROJECT/existing-neutral.txt" "$OTHER/existing-report.md" "$PLUGIN_DATA/private-hardlink-source"

SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "SessionStart",
    source: "startup",
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
  }));
' | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
  bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null
SESSION_KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' \
  "$PLUGIN/hooks/lib/session-control-core-v1.js" "$SESSION_ID")"
SESSION_CONTEXT="$PLUGIN_DATA/session-control/v1/records/${SESSION_KEY}.json"

SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "SessionStart",
    source: "startup",
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
  }));
' | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$TAMPERED_DATA" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
  bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null
TAMPERED_CONTEXT="$TAMPERED_DATA/session-control/v1/records/${SESSION_KEY}.json"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.runtime_digest = `sha256:${"0".repeat(64)}`;
  value.source_revision = value.runtime_digest;
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`);
' "$TAMPERED_CONTEXT"

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
  local out status hook_root="$PLUGIN" hook_data="$PLUGIN_DATA"
  case "${GATE_TEST_MODE:-valid}" in
    missing-context) hook_data="$MISSING_DATA" ;;
    tampered-digest) hook_data="$TAMPERED_DATA" ;;
    wrong-root) hook_root="$OTHER" ;;
    wrong-data) hook_data="$OTHER" ;;
  esac
  out="$(env \
    -u ZENSU_CLAUDE_PLUGIN_ROOT \
    -u ZENSU_SESSION_KEY \
    -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST \
    -u ZENSU_PROJECT_ROOT \
    CLAUDE_PLUGIN_ROOT="$hook_root" \
    CLAUDE_PLUGIN_DATA="$hook_data" \
    bash "$GATE" 2>/dev/null)"
  status=$?
  if [ "$status" -eq 2 ]; then printf deny; return; fi
  if [ "$status" -ne 0 ]; then printf invalid; return; fi
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
assert_case "production hook path needs no SessionStart-exported ZENSU variables" allow arbitrary-custom Read '{"file_path":"README.md"}'
assert_case "nested tool_input cannot impersonate a reviewer" allow - Write '{"agent_type":"code-reviewer","file_path":"x"}'
assert_case "bare PLM subagent is denied project-local writes in depth" deny zensu-plm Write '{"file_path":"x"}'
assert_case "scoped plugin PLM is denied project-local writes" deny zensu:zensu-plm Write '{"file_path":"x"}'
assert_case "bare PLM remains read-only when Claude omits correlation agent_id" deny no-id:zensu-plm Write '{"file_path":"x"}'
assert_case "bare PLM may read inside the immutable project" allow zensu-plm Read '{"file_path":"README.md"}'
assert_case "bare PLM cannot edit project files" deny zensu-plm Edit '{"file_path":"README.md","old_string":"x","new_string":"y"}'
assert_case "bare PLM cannot apply patches" deny zensu-plm apply_patch '{"patch":"*** Begin Patch\n*** Add File: ATTACK.txt\n+attack\n*** End Patch"}'
assert_case "bare PLM subagent cannot invoke shell" deny zensu-plm Bash '{"command":"pwd"}'
assert_case "bare PLM subagent cannot invoke mutating control" deny zensu-plm mcp__zensu__transition '{"state":"complete"}'
assert_case "bare PLM may Grep a safe project subtree" allow zensu-plm Grep '{"pattern":"x","path":"src"}'
assert_case "bare PLM cannot Grep a project ancestor of workflow state" deny zensu-plm Grep '{"pattern":"x","path":"."}'
assert_case "bare PLM cannot Glob a project ancestor of workflow state" deny zensu-plm Glob '{"pattern":"**/*","path":"."}'
assert_case "bare PLM cannot use host-default Grep at a protected ancestor cwd" deny zensu-plm Grep '{"pattern":"x"}'
assert_case "bare code reviewer may use Read" allow code-reviewer Read '{"file_path":"x"}'
assert_case "scoped plugin code reviewer may use Read" allow zensu:code-reviewer Read '{"file_path":"x"}'
assert_case "scoped plugin aspect reviewer remains read-only" deny zensu:review-aspect Write '{"file_path":"x"}'
assert_case "scoped plugin judge reviewer may use Glob" allow zensu:review-judge Glob '{"pattern":"**/*","path":"src"}'
assert_case "bare reviewer remains read-only when Claude omits correlation agent_id" deny no-id:code-reviewer Write '{"file_path":"x"}'
assert_case "bare aspect reviewer may use project-bound Grep" allow review-aspect Grep '{"pattern":"x","path":"src"}'
assert_case "bare judge reviewer may use project-bound Glob" allow review-judge Glob '{"pattern":"**/*","path":"src"}'
assert_case "reviewer may Grep protected terminology in a safe subtree" allow review-aspect Grep '{"pattern":"session-control|main-v1","path":"src"}'
assert_case "reviewer cannot Grep a project ancestor of workflow state" deny review-aspect Grep '{"pattern":"session-control|main-v1","path":"."}'
assert_case "reviewer cannot use host-default Grep at a protected ancestor cwd" deny review-aspect Grep '{"pattern":"session-control"}'
assert_case "reviewer cannot Glob a project ancestor of workflow state" deny review-judge Glob '{"pattern":"**/*","path":"."}'
assert_case "reviewer cannot use host-default Glob at a protected ancestor cwd" deny review-judge Glob '{"pattern":"**/*"}'
assert_case "reviewer Grep path filters cannot escape a safe subtree" deny review-aspect Grep '{"pattern":"session-control|main-v1","path":"src","glob":"../.zensu/**"}'
assert_case "reviewer Glob patterns cannot escape a safe subtree" deny review-judge Glob '{"pattern":"../.zensu/**","path":"src"}'
assert_case "reviewer view_image is denied outside the exact read trio" deny review-judge view_image '{"path":"x.png"}'
assert_case "unknown custom agent receives neutral normal reads" allow arbitrary-custom Read '{"file_path":"x"}'
assert_case "neutral agent may read ordinary installed plugin documentation" allow arbitrary-custom Read "{\"file_path\":\"$PLUGIN/README.md\"}"
assert_case "neutral agent cannot Grep a project ancestor of workflow state" deny arbitrary-custom Grep '{"pattern":"main-v1","path":"."}'
assert_case "neutral agent may Grep a safe project subtree" allow arbitrary-custom Grep '{"pattern":"main-v1","path":"src"}'
assert_case "neutral agent may Glob a safe project subtree" allow arbitrary-custom Glob '{"pattern":"**/*","path":"src"}'
assert_case "neutral agent may Grep an external safe subtree" allow arbitrary-custom Grep "{\"pattern\":\"main-v1\",\"path\":\"$OTHER\"}"
assert_case "neutral agent may Glob an external safe subtree" allow arbitrary-custom Glob "{\"pattern\":\"**/*\",\"path\":\"$OTHER\"}"
assert_case "unknown custom agent receives neutral normal writes" allow arbitrary-custom Write '{"file_path":"x"}'
assert_case "neutral Edit keeps an ordinary nlink=1 project file" allow arbitrary-custom Edit '{"file_path":"existing-neutral.txt","old_string":"x","new_string":"y"}'
assert_case "neutral Write keeps an ordinary nlink=1 external report file" allow arbitrary-custom Write "{\"file_path\":\"$OTHER/existing-report.md\",\"content\":\"report\"}"
assert_case "neutral Write cannot mutate the installed plugin runtime" deny arbitrary-custom Write "{\"file_path\":\"$PLUGIN/ATTACK.txt\",\"content\":\"attack\"}"
assert_case "neutral Edit cannot mutate an installed plugin file" deny arbitrary-custom Edit "{\"file_path\":\"$PLUGIN/README.md\",\"old_string\":\"x\",\"new_string\":\"y\"}"
assert_case "neutral MultiEdit cannot mutate an installed plugin file" deny arbitrary-custom MultiEdit "{\"file_path\":\"$PLUGIN/README.md\",\"edits\":[{\"old_string\":\"x\",\"new_string\":\"y\"}]}"
assert_case "neutral NotebookEdit cannot mutate private plugin data" deny arbitrary-custom NotebookEdit "{\"notebook_path\":\"$PLUGIN_DATA/ATTACK.ipynb\",\"new_source\":\"attack\"}"
assert_case "neutral apply_patch cannot add installed plugin runtime files" deny arbitrary-custom apply_patch "{\"patch\":\"*** Begin Patch\\n*** Add File: $PLUGIN/ATTACK.js\\n+attack\\n*** End Patch\"}"
assert_case "neutral Write cannot persist arbitrary private plugin data" deny arbitrary-custom Write "{\"file_path\":\"$PLUGIN_DATA/ATTACK\",\"content\":\"attack\"}"
PLUGIN_CASE_ALIAS="$(node -e '
  const value = process.argv[1];
  const slash = Math.max(value.lastIndexOf("/"), value.lastIndexOf("\\"));
  const chars = [...value];
  for (let index = slash + 1; index < chars.length; index += 1) {
    if (/[a-z]/.test(chars[index])) { chars[index] = chars[index].toUpperCase(); break; }
    if (/[A-Z]/.test(chars[index])) { chars[index] = chars[index].toLowerCase(); break; }
  }
  process.stdout.write(chars.join(""));
' "$PLUGIN")"
if [ "$PLUGIN_CASE_ALIAS" != "$PLUGIN" ] && [ -e "$PLUGIN_CASE_ALIAS" ]; then
  assert_case "neutral Write cannot mutate plugin runtime through a case-variant root alias" deny arbitrary-custom Write "{\"file_path\":\"$PLUGIN_CASE_ALIAS/CASE-ATTACK.txt\",\"content\":\"attack\"}"
else
  check "case-variant plugin-root alias is exercised only on a case-insensitive filesystem" PASS
fi
assert_case "neutral agent cannot invoke Bash even for git status" deny arbitrary-custom Bash '{"command":"git status --short"}'
assert_case "neutral agent cannot invoke Bash in an external review worktree" deny arbitrary-custom Bash "{\"command\":\"git -C $OTHER diff --stat\"}"
assert_case "neutral agent cannot enumerate the inherited shell environment" deny arbitrary-custom Bash '{"command":"env"}'
assert_case "neutral agent cannot obfuscate a workflow-root path" deny arbitrary-custom Bash '{"command":"d=.zen; ls \"$d\"su/state"}'
assert_case "neutral agent cannot obfuscate a helper name" deny arbitrary-custom Bash '{"command":"n=zensu-log; printf %s \"$n.sh\""}'
assert_case "neutral agent cannot invoke an interpreter shell" deny arbitrary-custom Bash '{"command":"sh -c true"}'
assert_case "neutral agent cannot invoke shell tool aliases" deny arbitrary-custom shell '{"command":"pwd"}'
assert_case "neutral agent cannot invoke exec tool aliases" deny arbitrary-custom exec '{"cmd":"pwd"}'
assert_case "neutral agent cannot invoke exec_command tool aliases" deny arbitrary-custom exec_command '{"cmd":"pwd"}'
assert_case "neutral agent cannot invoke terminal tool aliases" deny arbitrary-custom terminal '{"script":"pwd"}'
assert_case "neutral agent cannot invoke command tool aliases" deny arbitrary-custom command '{"command":"pwd"}'
assert_case "neutral agent keeps external report writes" allow arbitrary-custom Write "{\"file_path\":\"$OTHER/report.md\"}"
assert_case "neutral report content may discuss protected architecture" allow arbitrary-custom Write "{\"file_path\":\"$OTHER/report.md\",\"content\":\"session-control main-v1 ZENSU_SESSION_KEY\"}"
assert_case "neutral agent keeps host task updates" allow arbitrary-custom TaskUpdate '{"taskId":"review-1","status":"completed"}'
assert_case "neutral agent keeps unrelated MCP tools" allow arbitrary-custom mcp__github__get_pull_request '{"pull_number":172}'
assert_case "neutral agent keeps read-only Zensu MCP tools" allow arbitrary-custom mcp__zensu__get_feature '{"feature_id":"F-1"}'
assert_case "neutral nested-agent capability stays host-governed" allow arbitrary-custom Agent '{"subagent_type":"general-purpose","prompt":"review session-control and main-v1"}'
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
assert_case "neutral agent cannot access immutable Session Control record" deny arbitrary-custom Read "{\"file_path\":\"$SESSION_CONTEXT\"}"
assert_case "neutral Grep cannot traverse the project root into workflow state" deny arbitrary-custom Grep '{"pattern":"phase","path":"."}'
assert_case "neutral Glob cannot traverse the project root into workflow state" deny arbitrary-custom Glob '{"pattern":"**/*","path":"."}'
assert_case "neutral Grep without path uses and rejects a protected ancestor cwd" deny arbitrary-custom Grep '{"pattern":"phase"}'
assert_case "neutral Glob without path uses and rejects a protected ancestor cwd" deny arbitrary-custom Glob '{"pattern":"**/*"}'
assert_case "neutral Grep cannot traverse a plugin-data ancestor" deny arbitrary-custom Grep "{\"pattern\":\"session\",\"path\":\"$PLUGIN_DATA\"}"
assert_case "neutral Glob cannot traverse an executed-plugin ancestor" deny arbitrary-custom Glob "{\"pattern\":\"**/*\",\"path\":\"$PLUGIN\"}"
assert_case "neutral Grep cannot escape a safe subtree through its glob" deny arbitrary-custom Grep '{"pattern":"phase","path":"src","glob":"../.zensu/**"}'
assert_case "neutral Glob cannot escape a safe subtree through its pattern" deny arbitrary-custom Glob '{"pattern":"../.zensu/**","path":"src"}'
PAYLOAD_CWD="$OTHER" assert_case "neutral Grep may use an omitted path in an external safe cwd" allow arbitrary-custom Grep '{"pattern":"main-v1"}'
PAYLOAD_CWD="$OTHER" assert_case "neutral Glob may use an omitted path in an external safe cwd" allow arbitrary-custom Glob '{"pattern":"**/*"}'
assert_case "reviewer cannot read outside the immutable project" deny code-reviewer Read '{"file_path":"/etc/passwd"}'
assert_case "neutral agent may read an external host-governed path" allow arbitrary-custom Read "{\"file_path\":\"$OTHER/existing-report.md\"}"
PAYLOAD_CWD="$PROJECT/src/nested" assert_case "descendant cwd remains bound to the immutable project" allow arbitrary-custom Read '{"file_path":"../../README.md"}'
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "symlink path-boundary cases skipped only where unprivileged creation is unavailable" PASS
    ;;
  *)
    ln -s "$OTHER" "$PROJECT/outside-link"
    assert_case "reviewer cannot escape through a project symlink" deny review-aspect Read '{"file_path":"outside-link/secret.txt"}'
    assert_case "neutral agent may follow an external host-governed symlink" allow arbitrary-custom Read '{"file_path":"outside-link/secret.txt"}'
    ln -s "$PLUGIN" "$PROJECT/plugin-runtime-link"
    assert_case "neutral Write cannot mutate plugin runtime through a directory symlink" deny arbitrary-custom Write '{"file_path":"plugin-runtime-link/README.md","content":"attack"}'
    ln -s "$PLUGIN_DATA" "$PROJECT/plugin-data-link"
    assert_case "neutral Edit cannot mutate plugin data through a directory symlink" deny arbitrary-custom Edit '{"file_path":"plugin-data-link/ATTACK","old_string":"x","new_string":"y"}'
    ln -s "$PLUGIN/hooks/lib/future-runtime.js" "$PROJECT/dangling-plugin-runtime"
    assert_case "neutral Write cannot mutate plugin runtime through a dangling symlink leaf" deny arbitrary-custom Write '{"file_path":"dangling-plugin-runtime","content":"attack"}'
    ln -s "$PLUGIN_DATA/future-private-record.json" "$PROJECT/dangling-plugin-data"
    assert_case "neutral Write cannot mutate plugin data through a dangling symlink leaf" deny arbitrary-custom Write '{"file_path":"dangling-plugin-data","content":"attack"}'
    ln "$PLUGIN/README.md" "$PROJECT/plugin-runtime-hardlink"
    assert_case "neutral Edit cannot mutate plugin runtime through a project hard link" deny arbitrary-custom Edit '{"file_path":"plugin-runtime-hardlink","old_string":"x","new_string":"y"}'
    rm -f "$PROJECT/plugin-runtime-hardlink"
    ln "$PLUGIN_DATA/private-hardlink-source" "$PROJECT/plugin-data-hardlink"
    assert_case "neutral Write cannot mutate plugin data through a project hard link" deny arbitrary-custom Write '{"file_path":"plugin-data-hardlink","content":"attack"}'
    ln -s .zensu/state/new-dir "$PROJECT/dangling-protected"
    assert_case "neutral write cannot enter protected state through a dangling symlink leaf" deny arbitrary-custom Write '{"file_path":"dangling-protected/new.txt"}'
    ;;
esac
assert_case "neutral apply_patch Move to external host path is allowed" allow arbitrary-custom apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/old.js\n*** Move to: ../outside/new.js\n*** End Patch"}'
assert_case "neutral apply_patch Move to workflow state is denied" deny arbitrary-custom apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/old.js\n*** Move to: .zensu/state/new.js\n*** End Patch"}'
assert_case "neutral apply_patch Move to a project path is allowed" allow arbitrary-custom apply_patch '{"patch":"*** Begin Patch\n*** Update File: src/old.js\n*** Move to: src/new.js\n*** End Patch"}'
assert_case "neutral agent cannot invoke Session Control helper" deny arbitrary-custom Bash '{"command":"node hooks/lib/session-control-core-v1.js render-main"}'
assert_case "neutral agent cannot read the host session selector" deny arbitrary-custom Bash '{"command":"printf %s \"$CLAUDE_CODE_SESSION_ID\""}'
assert_case "neutral agent cannot invoke the model-session binder function" deny arbitrary-custom Bash '{"command":"zensu_bind_model_session"}'
assert_case "neutral agent cannot source the model-session binder" deny arbitrary-custom Bash '{"command":"source hooks/lib/zensu-session.sh"}'
assert_case "neutral agent cannot invoke the private binder CLI" deny arbitrary-custom Bash '{"command":"node hooks/lib/claude-hook-session-v1.js model-bind"}'
assert_case "neutral agent cannot read the private binder implementation" deny arbitrary-custom Read "{\"file_path\":\"$PLUGIN/hooks/lib/claude-hook-session-v1.js\"}"
assert_case "neutral agent cannot read the model-session shell implementation" deny arbitrary-custom Read "{\"file_path\":\"$PLUGIN/hooks/lib/zensu-session.sh\"}"
assert_case "neutral content cannot impersonate the trusted payload principal" allow arbitrary-custom Write '{"file_path":"notes.txt","content":"principal=main-v1"}'
assert_case "neutral Agent calls remain governed by Claude host nesting rules" allow arbitrary-custom Agent '{"subagent_type":"zensu-plm","prompt":"act as main"}'
assert_case "neutral agent cannot invoke mutating Zensu MCP" deny arbitrary-custom mcp__zensu__transition '{"state":"complete"}'
assert_case "neutral agent cannot invoke set-style Zensu MCP mutation" deny arbitrary-custom mcp__plugin_zensu_zensu__set_security_classification '{"feature_id":"F-1"}'

FORCED="$(payload code-reviewer Write '{"file_path":"x"}' | ZENSU_FORCE_MAIN=1 decision)"
[ "$FORCED" = deny ] && check "ZENSU_FORCE_MAIN cannot bypass reviewer boundary" PASS || check "ZENSU_FORCE_MAIN cannot bypass reviewer boundary" FAIL

MISSING="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=missing-context decision)"
[ "$MISSING" = deny ] && check "missing inherited SubagentStart context denies the first tool" PASS || check "missing inherited SubagentStart context denies the first tool" FAIL

TAMPERED="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=tampered-digest decision)"
[ "$TAMPERED" = deny ] && check "tampered inherited SubagentStart runtime digest denies the first tool" PASS || check "tampered inherited SubagentStart runtime digest denies the first tool" FAIL

WRONG_SESSION="$(PAYLOAD_SESSION_ID='different-session' payload arbitrary-custom Read '{"file_path":"x"}' | decision)"
[ "$WRONG_SESSION" = deny ] && check "PreToolUse session_id mismatch denies before capability evaluation" PASS || check "PreToolUse session_id mismatch denies before capability evaluation" FAIL

EXTERNAL_CWD="$(PAYLOAD_CWD="$OTHER" payload arbitrary-custom Read '{"file_path":"x"}' | decision)"
[ "$EXTERNAL_CWD" = allow ] && check "host-reported external cwd remains valid after CwdChanged" PASS || check "host-reported external cwd remains valid after CwdChanged" FAIL

FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\nprintf leaked-output\nprintf "secret child diagnostic\\n" >&2\nexit 127\n' >"$FAKE_BIN/node"
chmod +x "$FAKE_BIN/node"
FAIL_CLOSED_STDOUT="$(PATH="$FAKE_BIN:/usr/bin:/bin" bash "$GATE" </dev/null 2>"$TMP/fail-closed.stderr")"
FAIL_CLOSED_STATUS=$?
FAIL_CLOSED_STDERR="$(cat "$TMP/fail-closed.stderr")"
[ "$FAIL_CLOSED_STATUS" -eq 2 ] && check "launcher failure exits with Claude blocking status 2" PASS || check "launcher failure exits with Claude blocking status 2 (got $FAIL_CLOSED_STATUS)" FAIL
[ -z "$FAIL_CLOSED_STDOUT" ] && check "launcher failure suppresses child stdout" PASS || check "launcher failure suppresses child stdout" FAIL
[ "$FAIL_CLOSED_STDERR" = 'zensu: reviewer capability gate unavailable' ] && check "launcher failure emits only a sanitized diagnostic" PASS || check "launcher failure emits only a sanitized diagnostic" FAIL

WRONG_ROOT="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=wrong-root decision)"
[ "$WRONG_ROOT" = deny ] && check "PreToolUse plugin-root mismatch denies before capability evaluation" PASS || check "PreToolUse plugin-root mismatch denies before capability evaluation" FAIL

# Root mismatches are rejected before policy evaluation, but the hook must
# still consume a payload larger than the pipe buffer. Otherwise an upstream
# producer can receive EPIPE while Claude is handling the blocking exit.
DRAIN_STATUS_FILE="$TMP/drain-pipe-status"
DRAIN_PRODUCER_ERR="$TMP/drain-producer.stderr"
DRAIN_HOOK_ERR="$TMP/drain-hook.stderr"
(
  set +e
  set -o pipefail
  node -e 'process.stdout.write("x".repeat(2 * 1024 * 1024))' 2>"$DRAIN_PRODUCER_ERR" \
    | CLAUDE_PLUGIN_ROOT="$OTHER" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
        bash "$GATE" >/dev/null 2>"$DRAIN_HOOK_ERR"
  statuses=("${PIPESTATUS[@]}")
  printf '%s %s\n' "${statuses[0]:-missing}" "${statuses[1]:-missing}" >"$DRAIN_STATUS_FILE"
)
read -r DRAIN_PRODUCER_STATUS DRAIN_HOOK_STATUS <"$DRAIN_STATUS_FILE"
DRAIN_HOOK_MESSAGE="$(cat "$DRAIN_HOOK_ERR")"
if [ "$DRAIN_PRODUCER_STATUS" = 0 ] && [ "$DRAIN_HOOK_STATUS" = 2 ] \
  && [ ! -s "$DRAIN_PRODUCER_ERR" ] \
  && [ "$DRAIN_HOOK_MESSAGE" = 'zensu: reviewer capability gate unavailable' ]; then
  check "plugin-root mismatch drains a large payload without producer EPIPE" PASS
else
  check "plugin-root mismatch drains payload (producer=$DRAIN_PRODUCER_STATUS hook=$DRAIN_HOOK_STATUS)" FAIL
fi

WRONG_DATA="$(payload arbitrary-custom Read '{"file_path":"x"}' | GATE_TEST_MODE=wrong-data decision)"
[ "$WRONG_DATA" = deny ] && check "unbound host plugin-data denies before capability evaluation" PASS || check "unbound host plugin-data denies before capability evaluation" FAIL

STATE_FILE="$PROJECT/.zensu/state/tdd-phase-${SESSION_KEY}.json"
BASELINE_REVISION="$(node -e 'process.stdout.write(String(require(process.argv[1]).revision))' "$STATE_FILE")"
[ "$BASELINE_REVISION" = 1 ] \
  && check "SessionStart baseline CAS state exists before any workflow activation" PASS \
  || check "SessionStart baseline CAS state exists before any workflow activation" FAIL

CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SESSION_ID" bash "$PLUGIN/hooks/lib/zensu-log.sh" \
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

MISSING_EVENT="$(SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
    tool_name: "Read",
    tool_input: { file_path: "README.md" },
  }));
' | decision)"
[ "$MISSING_EVENT" = deny ] \
  && check "missing hook_event_name fails closed" PASS \
  || check "missing hook_event_name fails closed" FAIL

WRONG_EVENT="$(SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "PostToolUse",
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
    tool_name: "Read",
    tool_input: { file_path: "README.md" },
  }));
' | decision)"
[ "$WRONG_EVENT" = deny ] \
  && check "wrong hook_event_name fails closed" PASS \
  || check "wrong hook_event_name fails closed" FAIL

# --- unregistered session (the 0.17.0 upgrade state) -----------------------
# Session Control shipped in 0.17.0 and a resume/compact SessionStart requires a
# record it never mints, so every session predating the update is unbindable
# forever. This gate matches every tool, so denying there left the user unable to
# run even /zensu:doctor and read why. The main thread — which this gate returns
# unrestricted anyway once revalidation succeeds — keeps the capabilities it had
# before Session Control existed.
#
# This gate relaxes TWO states, both MAIN-only: the one below, and a record whose
# recorded project root no longer exists (a deleted or recycled worktree). The
# orphaned half is pinned in tests/structure/test-orphaned-project-root.sh
# (O25/O25a/O26/O27) against a real minted record, which this suite's synthetic
# GATE_TEST_MODE fixtures cannot produce. Nothing beyond those two is relaxed.
GATE_TEST_MODE=missing-context assert_case \
  "unregistered session: the main thread keeps Bash so /zensu:doctor stays reachable" \
  allow - Bash '{"command":"bash hooks/lib/zensu-doctor.sh"}'
GATE_TEST_MODE=missing-context assert_case \
  "unregistered session: the main thread keeps Read" \
  allow - Read '{"file_path":"README.md"}'
GATE_TEST_MODE=missing-context assert_case \
  "unregistered session: an exact reviewer still fails closed" \
  deny zensu:code-reviewer Read '{"file_path":"README.md"}'
GATE_TEST_MODE=missing-context assert_case \
  "unregistered session: a neutral child still fails closed" \
  deny general-purpose Read '{"file_path":"README.md"}'
GATE_TEST_MODE=missing-context assert_case \
  "unregistered session: a neutral child gets no shell either" \
  deny general-purpose Bash '{"command":"git status"}'

# Neither relaxable state covers this one. A record that EXISTS but was minted
# against another installation is what a plugin update leaves behind, and it is a
# security signal: it must keep denying for every principal, main thread included.
FOREIGN_DATA="$TMP/foreign-plugin-data"
FOREIGN_PLUG="$TMP/foreign-plugin"
mkdir -p "$FOREIGN_DATA/session-control/v1/records" "$FOREIGN_DATA/session-control/v1/locks" \
  "$FOREIGN_PLUG/.claude-plugin" "$FOREIGN_PLUG/hooks"
chmod 700 "$FOREIGN_DATA" "$FOREIGN_DATA/session-control" "$FOREIGN_DATA/session-control/v1" \
  "$FOREIGN_DATA/session-control/v1/records" "$FOREIGN_DATA/session-control/v1/locks"
printf '{"name":"zensu","version":"9.9.9"}\n' > "$FOREIGN_PLUG/.claude-plugin/plugin.json"
printf '{"hooks":{}}\n' > "$FOREIGN_PLUG/hooks/hooks.json"
if node -e '
  const path = require("path");
  const [corePath, data, plug, project, sessionId] = process.argv.slice(1);
  require(corePath).registerContext({
    recordsDir: path.join(data, "session-control", "v1", "records"),
    host: "claude", sessionId, projectRoot: project, pluginRoot: plug, pluginData: data,
  });
' "$PLUGIN/hooks/lib/session-control-core-v1.js" "$FOREIGN_DATA" "$FOREIGN_PLUG" "$PROJECT" "$SESSION_ID" 2>/dev/null; then
  FOREIGN_DECISION="$(payload - Bash '{"command":"git status"}' | env \
    -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
    CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$FOREIGN_DATA" \
    bash "$GATE" 2>/dev/null | node -e '
      let s = ""; process.stdin.on("data", c => s += c); process.stdin.on("end", () => {
        s = s.trim();
        if (!s) { process.stdout.write("allow"); return; }
        try { process.stdout.write(JSON.parse(s).hookSpecificOutput?.permissionDecision === "deny" ? "deny" : "other"); }
        catch (_) { process.stdout.write("invalid"); }
      });
    ')"
  [ "$FOREIGN_DECISION" = deny ] \
    && check "a record from another installation stays fail-closed even for the main thread" PASS \
    || check "foreign-installation record (expected deny, got $FOREIGN_DECISION)" FAIL
else
  check "foreign-installation fixture could not be minted" FAIL
fi

printf '%s\n' "----" "test-reviewer-capability-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
