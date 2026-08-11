#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
if [ -d "$ROOT/plugins/zensu" ]; then PLUGIN="$ROOT/plugins/zensu"; else PLUGIN="$ROOT"; fi
HELPER="$PLUGIN/hooks/lib/zensu-review-evidence.sh"
HOST_PATH="$PLUGIN/hooks/lib/zensu-host-path.sh"
START="$PLUGIN/hooks/review-evidence-subagent-start.sh"
STOP="$PLUGIN/hooks/review-evidence-subagent-stop.sh"
GATE="$PLUGIN/hooks/pre-reviewer-capability-gate.sh"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$HELPER" "$HOST_PATH" "$START" "$STOP" "$GATE" \
  "$PLUGIN/hooks/lib/review-evidence-lease-v1.js" \
  "$PLUGIN/hooks/lib/review-evidence-hook-v1.js" \
  "$PLUGIN/agents/plan-review-worker.md" "$PLUGIN/agents/pr-review-worker.md"; do
  [ -f "$artifact" ] && check "artifact exists: ${artifact#$PLUGIN/}" PASS \
    || check "artifact exists: ${artifact#$PLUGIN/}" FAIL
done
if PLUGIN_MANIFEST="$PLUGIN/.claude-plugin/plugin.json" HOOK_MANIFEST="$PLUGIN/hooks/hooks.json" node -e '
  const plugin=require(process.env.PLUGIN_MANIFEST);
  const hooks=require(process.env.HOOK_MANIFEST).hooks;
  const agents=new Set(plugin.agents);
  if (!agents.has("./agents/plan-review-worker.md") || !agents.has("./agents/pr-review-worker.md")) process.exit(1);
  const commands=[
    ...hooks.PreToolUse.flatMap(g=>g.hooks).filter(h=>h.command.includes("pre-reviewer-capability-gate")),
    ...hooks.SubagentStart.flatMap(g=>g.hooks).filter(h=>h.command.includes("review-evidence-subagent-start")),
    ...hooks.SubagentStop.flatMap(g=>g.hooks).filter(h=>h.command.includes("review-evidence-subagent-stop")),
  ];
  if (commands.length !== 3 || commands.some(h=>h.timeout !== 60)) process.exit(1);
'; then
  check "plugin agents and 60-second capability/evidence hook timeouts are registered" PASS
else
  check "plugin agents and 60-second capability/evidence hook timeouts are registered" FAIL
fi
AGENT_FRONTMATTER_OK=true
for agent_file in "$PLUGIN/agents/plan-review-worker.md" "$PLUGIN/agents/pr-review-worker.md"; do
  frontmatter="$(sed -n '2,/^---$/p' "$agent_file")"
  printf '%s\n' "$frontmatter" | grep -qxF 'tools: Read, Grep, Glob' || AGENT_FRONTMATTER_OK=false
  printf '%s\n' "$frontmatter" | grep -qxF 'maxTurns: 24' || AGENT_FRONTMATTER_OK=false
  printf '%s\n' "$frontmatter" | grep -qxF 'background: true' || AGENT_FRONTMATTER_OK=false
  if printf '%s\n' "$frontmatter" | grep -Eq '^(skills|mcpServers|memory|permissionMode):'; then
    AGENT_FRONTMATTER_OK=false
  fi
done
[ "$AGENT_FRONTMATTER_OK" = true ] \
  && check "worker frontmatter is bounded, background, and read-trio only" PASS \
  || check "worker frontmatter is bounded, background, and read-trio only" FAIL
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-review-worker-evidence-lease: $PASS PASS / $FAIL FAIL"
  exit 1
fi

RAW_TMP="$(mktemp -d "${TMPDIR:-/tmp}/evidence-lease-XXXXXX")"
RAW_TMP="$(cd -P -- "$RAW_TMP" && pwd -P)"
TMP="$(bash "$HOST_PATH" "$RAW_TMP")" || {
  rm -rf -- "$RAW_TMP"
  printf '%s\n' 'evidence lease fixture could not render its native host path' >&2
  exit 1
}
PLUGIN_SCOPE_WORKSPACE=''
SYSTEM_FILES=''
SYSTEM_ROOTS=''
trap 'rm -rf "$RAW_TMP"; [ -z "$PLUGIN_SCOPE_WORKSPACE" ] || rm -rf "$PLUGIN_SCOPE_WORKSPACE"; [ -z "$SYSTEM_FILES" ] || rm -f "$SYSTEM_FILES"; [ -z "$SYSTEM_ROOTS" ] || rm -f "$SYSTEM_ROOTS"' EXIT
RAW_PROJECT="$RAW_TMP/project"
WORKSPACE="$TMP/review-workspace"
DATA="$TMP/plugin-data"
SESSION='evidence-lease-session'
mkdir -p "$RAW_PROJECT/src/nested" "$WORKSPACE" "$DATA"
PROJECT="$(bash "$HOST_PATH" "$RAW_PROJECT")" || exit 1
chmod 700 "$WORKSPACE"
if [ -d "$TMP" ] && [ -d "$PROJECT" ] \
    && node -e 'const fs=require("node:fs");fs.realpathSync.native(process.argv[1]);fs.realpathSync.native(process.argv[2])' \
      "$TMP" "$PROJECT"; then
  check "mktemp workspace and shell-spelled source project convert before native Session Control/lease reads" PASS
else
  check "mktemp workspace and shell-spelled source project convert before native Session Control/lease reads" FAIL
fi
printf '%s\n' '# project' > "$PROJECT/README.md"
printf '%s\n' 'const value = 1;' > "$PROJECT/src/app.js"
printf '%s\n' 'evidence packet' > "$WORKSPACE/EVIDENCE.md"
printf '%s\n' "$PROJECT/README.md" "$PROJECT/src/app.js" > "$WORKSPACE/FILES.txt"
printf '%s\n' "$PROJECT/src" > "$WORKSPACE/ROOTS.txt"

session_start() {
  local data="$1" session="$2" project="$3"
  SESSION_VALUE="$session" PROJECT_VALUE="$project" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "SessionStart", source: "startup",
      session_id: process.env.SESSION_VALUE, cwd: process.env.PROJECT_VALUE,
    }));
  ' | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$data" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$PLUGIN/hooks/session-start-session-control.sh" >/dev/null
}

helper() {
  local data="$1" session="$2"
  shift 2
  CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$data" \
    CLAUDE_CODE_SESSION_ID="$session" bash "$HELPER" "$@"
}

hook_payload() {
  local event="$1" session="$2" agent_id="$3" agent_type="$4" message="${5:-}"
  EVENT="$event" SESSION_VALUE="$session" AGENT_ID="$agent_id" AGENT_TYPE="$agent_type" \
    MESSAGE="$message" PROJECT_VALUE="$PROJECT" node -e '
      const payload = {
        hook_event_name: process.env.EVENT,
        session_id: process.env.SESSION_VALUE,
        cwd: process.env.PROJECT_VALUE,
        agent_id: process.env.AGENT_ID,
        agent_type: process.env.AGENT_TYPE,
      };
      if (process.env.EVENT === "SubagentStop") {
        payload.last_assistant_message = process.env.MESSAGE;
      }
      process.stdout.write(JSON.stringify(payload));
    '
}

bind_worker() {
  local data="$1" session="$2" agent_id="$3" agent_type="$4"
  hook_payload SubagentStart "$session" "$agent_id" "$agent_type" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$data" bash "$START"
}

stop_worker() {
  local data="$1" session="$2" agent_id="$3" agent_type="$4" message="$5"
  hook_payload SubagentStop "$session" "$agent_id" "$agent_type" "$message" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$data" bash "$STOP"
}

pre_payload() {
  local session="$1" agent_id="$2" agent_type="$3" tool="$4" input="$5"
  SESSION_VALUE="$session" AGENT_ID="$agent_id" AGENT_TYPE="$agent_type" \
    TOOL="$tool" INPUT="$input" PROJECT_VALUE="$PROJECT" node -e '
      process.stdout.write(JSON.stringify({
        hook_event_name: "PreToolUse",
        session_id: process.env.SESSION_VALUE,
        cwd: process.env.PROJECT_VALUE,
        agent_id: process.env.AGENT_ID,
        agent_type: process.env.AGENT_TYPE,
        tool_name: process.env.TOOL,
        tool_input: JSON.parse(process.env.INPUT),
      }));
    '
}

decision() {
  local data="$1" out status
  out="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$data" bash "$GATE" 2>/dev/null)"
  status=$?
  if [ "$status" -ne 0 ]; then printf deny; return; fi
  if [ -z "$out" ]; then printf allow; return; fi
  printf '%s' "$out" | node -e '
    let s=""; process.stdin.on("data",c=>s+=c); process.stdin.on("end",()=>{
      try { const j=JSON.parse(s); process.stdout.write(
        j.hookSpecificOutput?.permissionDecision === "deny" ? "deny" : "other"); }
      catch { process.stdout.write("invalid"); }
    });
  '
}

assert_gate() {
  local label="$1" expected="$2" data="$3" session="$4" agent_id="$5" \
    agent_type="$6" tool="$7" input="$8" actual
  actual="$(pre_payload "$session" "$agent_id" "$agent_type" "$tool" "$input" | decision "$data")"
  [ "$actual" = "$expected" ] && check "$label" PASS \
    || check "$label (expected $expected, got $actual)" FAIL
}

valid_plan_result() {
  local role="$1"
  ROLE="$role" node -e 'process.stdout.write(JSON.stringify({
    kind:"plan-review", role:process.env.ROLE, verdict:"go", confidence:"high",
    summary:"The evidence supports the plan.", blockers:[], improvements:[],
    questions:[], strengths:["Scoped evidence is complete."]
  }))'
}

valid_pr_result() {
  local role="$1" path_value="${2:-src/app.js}"
  ROLE="$role" PATH_VALUE="$path_value" node -e 'process.stdout.write(JSON.stringify({
    kind:"pr-review", role:process.env.ROLE, verdict_hint:"approve",
    summary:"No blocking issue found.", inline_findings:[{
      path:process.env.PATH_VALUE,line:1,side:"RIGHT",severity:"P3",
      category:"clarity",body:"Consider a clearer name."
    }], overall_notes:[], positives:["Small focused change."]
  }))'
}

valid_coverage_result() {
  local path_value="${1:-src/app.js}"
  PATH_VALUE="$path_value" node -e 'process.stdout.write(JSON.stringify({
    kind:"pr-review", role:"coverage-audit", verdict_hint:"approve",
    summary:"Coverage evidence was mapped.", inline_findings:[], overall_notes:[], positives:[],
    coverage_report:{coverage_source:"static",summary:"One changed production file.",
      changed_production_files:1,
      uncovered_files:[{path:process.env.PATH_VALUE,reason:"No supplied test reference.",risk:"P2"}],
      partial_files:[],covered_files:[],notes:[]}
  }))'
}

coverage_case_result() {
  local case_name="$1"
  CASE_NAME="$case_name" node -e '
    const report={coverage_source:"static",summary:"Bound inventory check.",
      changed_production_files:1,uncovered_files:[],partial_files:[],covered_files:[],notes:[]};
    const uncovered=(path)=>({path,reason:"No supplied test reference.",risk:"P2"});
    if(process.env.CASE_NAME==="zero") report.changed_production_files=0;
    else if(process.env.CASE_NAME==="missing") report.uncovered_files=[uncovered("src/app.js")];
    else if(process.env.CASE_NAME==="extra") {
      report.changed_production_files=2;
      report.uncovered_files=[uncovered("src/app.js"),uncovered("README.md")];
    } else if(process.env.CASE_NAME==="duplicate") {
      report.changed_production_files=2;
      report.uncovered_files=[uncovered("src/app.js")]; report.covered_files=["src/app.js"];
    } else if(process.env.CASE_NAME==="alias-duplicate") {
      report.changed_production_files=2;
      report.uncovered_files=[uncovered("src/app.js")]; report.covered_files=["src\\app.js"];
    } else if(process.env.CASE_NAME==="count-mismatch") {
      report.changed_production_files=0; report.uncovered_files=[uncovered("src/app.js")];
    }
    process.stdout.write(JSON.stringify({kind:"pr-review",role:"coverage-audit",
      verdict_hint:"approve",summary:"Coverage inventory.",inline_findings:[],
      overall_notes:[],positives:[],coverage_report:report}));
  '
}

session_start "$DATA" "$SESSION" "$PROJECT"
CREATE_OUT="$(helper "$DATA" "$SESSION" create --kind plan-review \
  --files-manifest "$WORKSPACE/FILES.txt" \
  --safe-subtrees-manifest "$WORKSPACE/ROOTS.txt" \
  --required-file "$WORKSPACE/EVIDENCE.md" --max-workers 2 --ttl-seconds 600 2>/dev/null)"
case "$CREATE_OUT" in lease_id=rel1_????????????????????????????????) check "create returns one opaque lease id" PASS ;; \
  *) check "create returns one opaque lease id (got $CREATE_OUT)" FAIL ;; esac
LEASE_ID="${CREATE_OUT#lease_id=}"

if helper "$DATA" "$SESSION" create --kind plan-review \
    --files-manifest "$WORKSPACE/FILES.txt" --safe-subtrees-manifest "$WORKSPACE/ROOTS.txt" \
    --max-workers 1 >/dev/null 2>&1; then
  check "duplicate active lease fails closed instead of superseding" FAIL
else
  check "duplicate active lease fails closed instead of superseding" PASS
fi

START_OUT="$(bind_worker "$DATA" "$SESSION" plan-agent-1 zensu:plan-review-worker 2>/dev/null)"
if printf '%s' "$START_OUT" | grep -qF 'evidence-worker-v1 bound' \
  && ! printf '%s' "$START_OUT" | grep -qE 'rel1_|session_id_hash|scv1_' \
  && ! printf '%s' "$START_OUT" | grep -qF "$DATA"; then
  check "SubagentStart binds without exposing lease or session selectors" PASS
else
  check "SubagentStart binds without exposing lease or session selectors" FAIL
fi

SESSION_CONTEXT_OUT="$(hook_payload SubagentStart "$SESSION" plan-agent-context zensu:plan-review-worker \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$DATA" \
    bash "$PLUGIN/hooks/session-start-session-control.sh" 2>/dev/null)"
if printf '%s' "$SESSION_CONTEXT_OUT" | grep -qF 'principal=evidence-worker-v1' \
  && ! printf '%s' "$SESSION_CONTEXT_OUT" | grep -qE 'rel1_|session_id_hash|scv1_' \
  && ! printf '%s' "$SESSION_CONTEXT_OUT" | grep -qF "$DATA"; then
  check "Session Control renders the distinct evidence-worker principal without selectors" PASS
else
  check "Session Control renders the distinct evidence-worker principal without selectors" FAIL
fi

assert_gate "worker may Read an exact leased file" allow "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Read "{\"file_path\":\"$PROJECT/README.md\"}"
assert_gate "worker cannot Read an unleased project file" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Read "{\"file_path\":\"$PROJECT/not-leased.md\"}"
CASE_ALIAS="$(node -e '
  const value=process.argv[1]; const chars=[...value];
  const slash=Math.max(value.lastIndexOf("/"),value.lastIndexOf("\\\\"));
  for(let i=slash+1;i<chars.length;i+=1){
    if(/[a-z]/.test(chars[i])){chars[i]=chars[i].toUpperCase();break;}
    if(/[A-Z]/.test(chars[i])){chars[i]=chars[i].toLowerCase();break;}
  }
  process.stdout.write(chars.join(""));
' "$PROJECT/README.md")"
if [ "$CASE_ALIAS" != "$PROJECT/README.md" ] && [ -e "$CASE_ALIAS" ]; then
  assert_gate "worker cannot Read through a case-variant exact-file alias" deny "$DATA" "$SESSION" \
    plan-agent-1 zensu:plan-review-worker Read "{\"file_path\":\"$CASE_ALIAS\"}"
else
  check "case-variant exact-file alias is exercised only on a case-insensitive filesystem" PASS
fi
assert_gate "worker may Grep the exact leased root" allow "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Grep "{\"pattern\":\"value\",\"path\":\"$PROJECT/src\"}"
assert_gate "worker may Glob the exact leased root" allow "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Glob "{\"pattern\":\"**/*.js\",\"path\":\"$PROJECT/src\"}"
assert_gate "worker cannot omit a traversal root" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Grep '{"pattern":"value"}'
assert_gate "worker cannot traverse from a leased-root descendant" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Grep "{\"pattern\":\"value\",\"path\":\"$PROJECT/src/nested\"}"
assert_gate "worker cannot escape through a traversal pattern" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Glob "{\"pattern\":\"../.zensu/**\",\"path\":\"$PROJECT/src\"}"
for ESCAPE_PATTERN in \
  '{..,x}/secret' '[.][.]/secret' '@(../x|*)' '\.\./secret' \
  'nested/{..,x}/secret' 'nested/[.][.]/secret' \
  'nested/@(../x|*)' 'nested/\.\./secret'; do
  ESCAPE_INPUT="$(FILTER_PATTERN="$ESCAPE_PATTERN" FILTER_PATH="$PROJECT/src" node -e '
    process.stdout.write(JSON.stringify({
      pattern: process.env.FILTER_PATTERN,
      path: process.env.FILTER_PATH,
    }));
  ')"
  assert_gate "Glob rejects ambiguous path-filter syntax: $ESCAPE_PATTERN" deny \
    "$DATA" "$SESSION" plan-agent-1 zensu:plan-review-worker Glob "$ESCAPE_INPUT"
done
for FILTER_FIELD in glob include exclude; do
  ESCAPE_INPUT="$(FILTER_FIELD="$FILTER_FIELD" FILTER_PATH="$PROJECT/src" node -e '
    process.stdout.write(JSON.stringify({
      pattern: "content regex remains unrestricted: @(../x|*)",
      path: process.env.FILTER_PATH,
      [process.env.FILTER_FIELD]: "safe/{..,x}/secret",
    }));
  ')"
  assert_gate "Grep rejects unsafe $FILTER_FIELD path-filter syntax" deny \
    "$DATA" "$SESSION" plan-agent-1 zensu:plan-review-worker Grep "$ESCAPE_INPUT"
done
FREE_GREP_INPUT="$(FILTER_PATH="$PROJECT/src" node -e '
  process.stdout.write(JSON.stringify({
    pattern: String.raw`{..,x}|[.][.]|@(../x|*)|\.\./secret`,
    path: process.env.FILTER_PATH,
  }));
')"
assert_gate "Grep content pattern remains unrestricted by path-filter grammar" allow \
  "$DATA" "$SESSION" plan-agent-1 zensu:plan-review-worker Grep "$FREE_GREP_INPUT"
assert_gate "worker cannot invoke Bash" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Bash '{"command":"env"}'
assert_gate "worker cannot invoke Write" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Write '{"file_path":"report.json","content":"{}"}'
assert_gate "worker cannot invoke messaging" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker SendMessage '{"recipient":"lead","content":"x"}'
assert_gate "worker cannot invoke task mutation" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker TaskUpdate '{"taskId":"1","status":"completed"}'
assert_gate "unbound agent id cannot use a worker lease" deny "$DATA" "$SESSION" unbound-agent \
  zensu:plan-review-worker Read "{\"file_path\":\"$PROJECT/README.md\"}"
assert_gate "wrong exact worker type cannot reuse another binding" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:pr-review-worker Read "{\"file_path\":\"$PROJECT/README.md\"}"
assert_gate "wrong host session cannot reuse another binding" deny "$DATA" other-session plan-agent-1 \
  zensu:plan-review-worker Read "{\"file_path\":\"$PROJECT/README.md\"}"

PLAN_JSON="$(valid_plan_result feasibility-soundness)"
STOP_OUT="$(stop_worker "$DATA" "$SESSION" plan-agent-1 zensu:plan-review-worker "$PLAN_JSON" 2>/dev/null)"
[ -z "$STOP_OUT" ] && check "valid SubagentStop stores result without model-visible output" PASS \
  || check "valid SubagentStop stores result without model-visible output" FAIL
if helper "$DATA" "$SESSION" collect --kind plan-review --agent-id plan-agent-1 \
    --expected-role feasibility-soundness > /dev/null 2> "$TMP/collect-before-finalize.err"; then
  check "collect before finalize is denied" FAIL
elif grep -qF 'evidence lease must be finalized before collect' "$TMP/collect-before-finalize.err"; then
  check "collect before finalize is denied" PASS
else
  check "collect before finalize uses the stable denial contract" FAIL
fi
if helper "$DATA" "$SESSION" finalize --lease-id "$LEASE_ID" >/dev/null 2>&1; then
  check "finalize requires exactly max_workers completed results" FAIL
else
  check "finalize requires exactly max_workers completed results" PASS
fi

bind_worker "$DATA" "$SESSION" plan-agent-2 zensu:plan-review-worker >/dev/null 2>&1
if bind_worker "$DATA" "$SESSION" plan-agent-3 zensu:plan-review-worker >/dev/null 2>&1; then
  check "SubagentStart enforces max_workers across completed and live bindings" FAIL
else
  check "SubagentStart enforces max_workers across completed and live bindings" PASS
fi
PLAN_JSON_2="$(valid_plan_result testing-tdd)"
stop_worker "$DATA" "$SESSION" plan-agent-2 zensu:plan-review-worker "$PLAN_JSON_2" >/dev/null 2>&1
FINALIZE_OUT="$(helper "$DATA" "$SESSION" finalize --lease-id "$LEASE_ID" 2>/dev/null)"
[ "$FINALIZE_OUT" = "sealed=$LEASE_ID" ] \
  && check "finalize seals exactly max_workers completed results after full revalidation" PASS \
  || check "finalize seals exactly max_workers completed results after full revalidation" FAIL
if stop_worker "$DATA" "$SESSION" plan-agent-1 zensu:plan-review-worker "$PLAN_JSON" \
    >/dev/null 2>&1; then
  check "SubagentStop is denied after finalize" FAIL
else
  check "SubagentStop is denied after finalize" PASS
fi
COLLECTED="$(helper "$DATA" "$SESSION" collect --kind plan-review --agent-id plan-agent-1 \
  --expected-role feasibility-soundness 2>/dev/null)"
[ "$COLLECTED" = "$PLAN_JSON" ] && check "collect returns only sealed canonical JSON" PASS \
  || check "collect returns only sealed canonical JSON" FAIL
if helper "$DATA" "$SESSION" collect --kind plan-review --agent-id plan-agent-1 \
    --expected-role testing-tdd >/dev/null 2>&1; then
  check "collect enforces the main thread agent-id to role binding" FAIL
else
  check "collect enforces the main thread agent-id to role binding" PASS
fi
assert_gate "completed binding is revoked before another tool" deny "$DATA" "$SESSION" plan-agent-1 \
  zensu:plan-review-worker Read "{\"file_path\":\"$PROJECT/README.md\"}"

CLOSE_OUT="$(helper "$DATA" "$SESSION" close --lease-id "$LEASE_ID" 2>/dev/null)"
[ "$CLOSE_OUT" = "closed=$LEASE_ID" ] && check "close returns the exact closed lease id" PASS \
  || check "close returns the exact closed lease id" FAIL
assert_gate "closed sealed lease keeps worker tools revoked" deny "$DATA" "$SESSION" plan-agent-2 \
  zensu:plan-review-worker Read "{\"file_path\":\"$PROJECT/README.md\"}"

# A closed lease remains auditable after the external review workspace is gone,
# and it does not poison the next generation in the same host session.
rm -rf "$WORKSPACE"
COLLECT_AFTER_RM="$(helper "$DATA" "$SESSION" collect --lease-id "$LEASE_ID" \
  --agent-id plan-agent-1 --expected-role feasibility-soundness 2>/dev/null)"
[ "$COLLECT_AFTER_RM" = "$PLAN_JSON" ] && check "closed result survives workspace cleanup" PASS \
  || check "closed result survives workspace cleanup" FAIL
WORKSPACE="$TMP/review-workspace-2"
mkdir -p "$WORKSPACE"
chmod 700 "$WORKSPACE"
printf '%s\n' 'new evidence' > "$WORKSPACE/EVIDENCE.md"
printf '%s\n' "$PROJECT/README.md" > "$WORKSPACE/FILES.txt"
: > "$WORKSPACE/ROOTS.txt"
NEW_OUT="$(helper "$DATA" "$SESSION" create --kind plan-review \
  --files-manifest "$WORKSPACE/FILES.txt" --safe-subtrees-manifest "$WORKSPACE/ROOTS.txt" \
  --required-file "$WORKSPACE/EVIDENCE.md" --max-workers 1 2>/dev/null)"
case "$NEW_OUT" in lease_id=rel1_*) check "new generation succeeds after close and workspace removal" PASS ;; \
  *) check "new generation succeeds after close and workspace removal" FAIL ;; esac
NEW_ID="${NEW_OUT#lease_id=}"
bind_worker "$DATA" "$SESSION" invalid-agent zensu:plan-review-worker >/dev/null 2>&1
FIRST_INVALID="$(stop_worker "$DATA" "$SESSION" invalid-agent zensu:plan-review-worker \
  '```json {"kind":"plan-review"} ```' 2>/dev/null)"
if printf '%s' "$FIRST_INVALID" | grep -q '"decision":"block"'; then
  check "first malformed final result blocks exactly one correction" PASS
else
  check "first malformed final result blocks exactly one correction" FAIL
fi
SECOND_INVALID="$(stop_worker "$DATA" "$SESSION" invalid-agent zensu:plan-review-worker \
  '{"kind":"plan-review","role":"x","extra":true}' 2>/dev/null)"
[ -z "$SECOND_INVALID" ] && check "second malformed result records failure without a stop loop" PASS \
  || check "second malformed result records failure without a stop loop" FAIL
if helper "$DATA" "$SESSION" collect --kind plan-review --agent-id invalid-agent \
    --expected-role x >/dev/null 2>&1; then
  check "failed result cannot be collected" FAIL
else
  check "failed result cannot be collected" PASS
fi
helper "$DATA" "$SESSION" close --lease-id "$NEW_ID" >/dev/null

# Duplicate object keys must be rejected from the raw token stream before
# JSON.parse can silently keep the last value. Both payloads are otherwise
# valid, so a parse-first implementation would incorrectly accept them.
DUP_OUT="$(helper "$DATA" "$SESSION" create --kind plan-review \
  --files-manifest "$WORKSPACE/FILES.txt" --safe-subtrees-manifest "$WORKSPACE/ROOTS.txt" \
  --max-workers 2 2>/dev/null)"
DUP_ID="${DUP_OUT#lease_id=}"
bind_worker "$DATA" "$SESSION" duplicate-top-agent zensu:plan-review-worker >/dev/null 2>&1
DUPLICATE_TOP='{"kind":"plan-review","role":"duplicate-top","verdict":"go","confidence":"high","summary":"first","\u0073ummary":"second","blockers":[],"improvements":[],"questions":[],"strengths":["valid"]}'
DUPLICATE_TOP_OUT="$(stop_worker "$DATA" "$SESSION" duplicate-top-agent \
  zensu:plan-review-worker "$DUPLICATE_TOP" 2>/dev/null)"
if printf '%s' "$DUPLICATE_TOP_OUT" | grep -qF 'duplicate JSON object keys'; then
  check "raw top-level duplicate JSON key is rejected before JSON.parse" PASS
else
  check "raw top-level duplicate JSON key is rejected before JSON.parse" FAIL
fi
bind_worker "$DATA" "$SESSION" duplicate-nested-agent zensu:plan-review-worker >/dev/null 2>&1
DUPLICATE_NESTED='{"kind":"plan-review","role":"duplicate-nested","verdict":"revise","confidence":"high","summary":"valid","blockers":[{"issue":"first","issue":"second","why":"valid","plan_ref":"step 1","plan_amendment":"fix it"}],"improvements":[],"questions":[],"strengths":[]}'
DUPLICATE_NESTED_OUT="$(stop_worker "$DATA" "$SESSION" duplicate-nested-agent \
  zensu:plan-review-worker "$DUPLICATE_NESTED" 2>/dev/null)"
if printf '%s' "$DUPLICATE_NESTED_OUT" | grep -qF 'duplicate JSON object keys'; then
  check "raw nested duplicate JSON key is rejected before JSON.parse" PASS
else
  check "raw nested duplicate JSON key is rejected before JSON.parse" FAIL
fi
helper "$DATA" "$SESSION" close --lease-id "$DUP_ID" >/dev/null

# PR results are additionally bound to the immutable name-status inventory.
PRSPACE="$TMP/pr-review-workspace"
mkdir -p "$PRSPACE"
chmod 700 "$PRSPACE"
printf 'other\n' > "$PROJECT/src/other.js"
printf '%s\n' "$PROJECT/src/app.js" > "$PRSPACE/FILES.txt"
: > "$PRSPACE/ROOTS.txt"
printf 'M\tsrc/app.js\nM\tsrc/other.js\nM\tREADME.md\n' > "$PRSPACE/NAME_STATUS.txt"
printf 'src/app.js\n' > "$PRSPACE/CHANGED_PRODUCTION.txt"
PR_OUT="$(helper "$DATA" "$SESSION" create --kind pr-review \
  --files-manifest "$PRSPACE/FILES.txt" --safe-subtrees-manifest "$PRSPACE/ROOTS.txt" \
  --name-status-file "$PRSPACE/NAME_STATUS.txt" \
  --changed-production-files-file "$PRSPACE/CHANGED_PRODUCTION.txt" \
  --max-workers 1 2>/dev/null)"
PR_ID="${PR_OUT#lease_id=}"
bind_worker "$DATA" "$SESSION" pr-agent zensu:pr-review-worker >/dev/null 2>&1
OUTSIDE_JSON="$(valid_pr_result bug-hunter src/not-changed.js)"
PR_BLOCK="$(stop_worker "$DATA" "$SESSION" pr-agent zensu:pr-review-worker "$OUTSIDE_JSON" 2>/dev/null)"
if printf '%s' "$PR_BLOCK" | grep -q '"decision":"block"'; then
  check "SubagentStop rejects inline paths outside name-status" PASS
else
  check "SubagentStop rejects inline paths outside name-status" FAIL
fi
PR_JSON="$(valid_pr_result bug-hunter src/app.js)"
stop_worker "$DATA" "$SESSION" pr-agent zensu:pr-review-worker "$PR_JSON" >/dev/null 2>&1
helper "$DATA" "$SESSION" finalize --lease-id "$PR_ID" >/dev/null
PR_COLLECT="$(helper "$DATA" "$SESSION" collect --kind pr-review --agent-id pr-agent \
  --expected-role bug-hunter 2>/dev/null)"
[ "$PR_COLLECT" = "$PR_JSON" ] && check "corrected PR result validates and collects" PASS \
  || check "corrected PR result validates and collects" FAIL
helper "$DATA" "$SESSION" close --lease-id "$PR_ID" >/dev/null

# A code fence inside a finding body is content, not a wrapper. The pr-team-review personas
# are instructed to emit fenced snippets in an inline finding's `body`, so a guard that
# scanned the whole payload for a fence rejected every review carrying a concrete
# suggestion. Only a payload that is itself fenced may fail.
FENCE_OUT="$(helper "$DATA" "$SESSION" create --kind pr-review \
  --files-manifest "$PRSPACE/FILES.txt" --safe-subtrees-manifest "$PRSPACE/ROOTS.txt" \
  --name-status-file "$PRSPACE/NAME_STATUS.txt" \
  --changed-production-files-file "$PRSPACE/CHANGED_PRODUCTION.txt" \
  --max-workers 1 2>/dev/null)"
FENCE_ID="${FENCE_OUT#lease_id=}"
bind_worker "$DATA" "$SESSION" fence-agent zensu:pr-review-worker >/dev/null 2>&1
FENCED_JSON="$(node -e 'process.stdout.write(JSON.stringify({
  kind: "pr-review", role: "bug-hunter", verdict_hint: "minor-changes",
  summary: "A fenced snippet belongs in the body.", inline_findings: [{
    path: "src/app.js", line: 1, side: "RIGHT", severity: "P2", category: "correctness",
    body: "Guard the empty case:\n\n```js\nif (!x) return;\n```\n"
  }], overall_notes: [], positives: ["Focused change."]
}))')"
stop_worker "$DATA" "$SESSION" fence-agent zensu:pr-review-worker "$FENCED_JSON" >/dev/null 2>&1
helper "$DATA" "$SESSION" finalize --lease-id "$FENCE_ID" >/dev/null
FENCE_COLLECT="$(helper "$DATA" "$SESSION" collect --kind pr-review --agent-id fence-agent \
  --expected-role bug-hunter 2>/dev/null)"
[ "$FENCE_COLLECT" = "$FENCED_JSON" ] \
  && check "code fence inside a finding body collects" PASS \
  || check "code fence inside a finding body collects" FAIL
helper "$DATA" "$SESSION" close --lease-id "$FENCE_ID" >/dev/null

WRAPPED_OUT="$(helper "$DATA" "$SESSION" create --kind pr-review \
  --files-manifest "$PRSPACE/FILES.txt" --safe-subtrees-manifest "$PRSPACE/ROOTS.txt" \
  --name-status-file "$PRSPACE/NAME_STATUS.txt" \
  --changed-production-files-file "$PRSPACE/CHANGED_PRODUCTION.txt" \
  --max-workers 1 2>/dev/null)"
WRAPPED_ID="${WRAPPED_OUT#lease_id=}"
bind_worker "$DATA" "$SESSION" wrapped-agent zensu:pr-review-worker >/dev/null 2>&1
WRAPPED_JSON="$(printf '```json\n%s\n```' "$FENCED_JSON")"
WRAPPED_BLOCK="$(stop_worker "$DATA" "$SESSION" wrapped-agent zensu:pr-review-worker \
  "$WRAPPED_JSON" 2>/dev/null)"
if printf '%s' "$WRAPPED_BLOCK" | grep -qF 'without fences or prose'; then
  check "fence-wrapped payload is still rejected" PASS
else
  check "fence-wrapped payload is still rejected" FAIL
fi
helper "$DATA" "$SESSION" close --lease-id "$WRAPPED_ID" >/dev/null

COVERAGE_OUT="$(helper "$DATA" "$SESSION" create --kind pr-review \
  --files-manifest "$PRSPACE/FILES.txt" --safe-subtrees-manifest "$PRSPACE/ROOTS.txt" \
  --name-status-file "$PRSPACE/NAME_STATUS.txt" \
  --changed-production-files-file "$PRSPACE/CHANGED_PRODUCTION.txt" \
  --max-workers 1 2>/dev/null)"
COVERAGE_ID="${COVERAGE_OUT#lease_id=}"
bind_worker "$DATA" "$SESSION" coverage-agent zensu:pr-review-worker >/dev/null 2>&1
COVERAGE_BLOCK="$(stop_worker "$DATA" "$SESSION" coverage-agent zensu:pr-review-worker \
  "$(valid_coverage_result src/not-changed.js)" 2>/dev/null)"
if printf '%s' "$COVERAGE_BLOCK" | grep -q '"decision":"block"'; then
  check "coverage_report paths are bound to name-status" PASS
else
  check "coverage_report paths are bound to name-status" FAIL
fi
COVERAGE_JSON="$(valid_coverage_result src/app.js)"
stop_worker "$DATA" "$SESSION" coverage-agent zensu:pr-review-worker "$COVERAGE_JSON" >/dev/null 2>&1
helper "$DATA" "$SESSION" finalize --lease-id "$COVERAGE_ID" >/dev/null
COVERAGE_COLLECT="$(helper "$DATA" "$SESSION" collect --kind pr-review \
  --agent-id coverage-agent --expected-role coverage-audit 2>/dev/null)"
[ "$COVERAGE_COLLECT" = "$COVERAGE_JSON" ] \
  && check "coverage-audit exact schema collects after path correction" PASS \
  || check "coverage-audit exact schema collects after path correction" FAIL
helper "$DATA" "$SESSION" close --lease-id "$COVERAGE_ID" >/dev/null

for COVERAGE_CASE in zero missing extra duplicate alias-duplicate count-mismatch; do
  if [ "$COVERAGE_CASE" = missing ]; then
    printf 'src/app.js\nsrc/other.js\n' > "$PRSPACE/CHANGED_PRODUCTION.txt"
  else
    printf 'src/app.js\n' > "$PRSPACE/CHANGED_PRODUCTION.txt"
  fi
  CASE_OUT="$(helper "$DATA" "$SESSION" create --kind pr-review \
    --files-manifest "$PRSPACE/FILES.txt" --safe-subtrees-manifest "$PRSPACE/ROOTS.txt" \
    --name-status-file "$PRSPACE/NAME_STATUS.txt" \
    --changed-production-files-file "$PRSPACE/CHANGED_PRODUCTION.txt" \
    --max-workers 1 2>/dev/null)"
  CASE_ID="${CASE_OUT#lease_id=}"
  bind_worker "$DATA" "$SESSION" "coverage-$COVERAGE_CASE-agent" \
    zensu:pr-review-worker >/dev/null 2>&1
  CASE_BLOCK="$(stop_worker "$DATA" "$SESSION" "coverage-$COVERAGE_CASE-agent" \
    zensu:pr-review-worker "$(coverage_case_result "$COVERAGE_CASE")" 2>/dev/null)"
  if printf '%s' "$CASE_BLOCK" | grep -qF '"decision":"block"'; then
    check "coverage completeness rejects $COVERAGE_CASE inventory" PASS
  else
    check "coverage completeness rejects $COVERAGE_CASE inventory" FAIL
  fi
  if [ "$COVERAGE_CASE" = alias-duplicate ]; then
    if helper "$DATA" "$SESSION" finalize --lease-id "$CASE_ID" >/dev/null 2>&1; then
      check "cross-bucket path alias cannot produce a sealed result" FAIL
    else
      check "cross-bucket path alias cannot produce a sealed result" PASS
    fi
  fi
  helper "$DATA" "$SESSION" close --lease-id "$CASE_ID" >/dev/null
done
printf 'src/app.js\nsrc/app.js\n' > "$PRSPACE/CHANGED_PRODUCTION.txt"
if helper "$DATA" "$SESSION" create --kind pr-review \
    --files-manifest "$PRSPACE/FILES.txt" --safe-subtrees-manifest "$PRSPACE/ROOTS.txt" \
    --name-status-file "$PRSPACE/NAME_STATUS.txt" \
    --changed-production-files-file "$PRSPACE/CHANGED_PRODUCTION.txt" \
    --max-workers 1 >/dev/null 2>&1; then
  check "changed-production manifest rejects duplicate paths" FAIL
else
  check "changed-production manifest rejects duplicate paths" PASS
fi
printf 'src/app.js\n' > "$PRSPACE/CHANGED_PRODUCTION.txt"

# Creation rejects scope expansion and common secret/key path classes.
UNSAFE="$TMP/unsafe-workspace"
mkdir -p "$UNSAFE/.config/gh"
chmod 700 "$UNSAFE"
: > "$UNSAFE/ROOTS.txt"
printf '%s\n' '/etc/passwd' > "$UNSAFE/FILES.txt"
if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
    --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
  check "arbitrary external exact file is rejected" FAIL
else
  check "arbitrary external exact file is rejected" PASS
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "POSIX workspace ownership/mode cases are skipped only on Windows shell" PASS
    ;;
  *)
PERMISSIVE_WORKSPACE="$TMP/permissive-workspace"
mkdir -p "$PERMISSIVE_WORKSPACE"
chmod 777 "$PERMISSIVE_WORKSPACE"
printf '%s\n' "$PROJECT/README.md" > "$PERMISSIVE_WORKSPACE/FILES.txt"
: > "$PERMISSIVE_WORKSPACE/ROOTS.txt"
if helper "$DATA" "$SESSION" create --kind plan-review \
    --files-manifest "$PERMISSIVE_WORKSPACE/FILES.txt" \
    --safe-subtrees-manifest "$PERMISSIVE_WORKSPACE/ROOTS.txt" --max-workers 1 \
    > /dev/null 2> "$TMP/permissive-workspace.err"; then
  check "group/world-accessible review workspace leaf is rejected" FAIL
elif grep -qF 'owned by the current user with mode 0700' "$TMP/permissive-workspace.err"; then
  check "group/world-accessible review workspace leaf is rejected" PASS
else
  check "group/world-accessible review workspace leaf uses the stable denial" FAIL
fi

NONSTICKY_PARENT="$TMP/nonsticky-parent"
NONSTICKY_WORKSPACE="$NONSTICKY_PARENT/review"
mkdir -p "$NONSTICKY_WORKSPACE"
chmod 777 "$NONSTICKY_PARENT"
chmod 700 "$NONSTICKY_WORKSPACE"
printf '%s\n' "$PROJECT/README.md" > "$NONSTICKY_WORKSPACE/FILES.txt"
: > "$NONSTICKY_WORKSPACE/ROOTS.txt"
if helper "$DATA" "$SESSION" create --kind plan-review \
    --files-manifest "$NONSTICKY_WORKSPACE/FILES.txt" \
    --safe-subtrees-manifest "$NONSTICKY_WORKSPACE/ROOTS.txt" --max-workers 1 \
    > /dev/null 2> "$TMP/nonsticky-workspace.err"; then
  check "non-sticky group/world-writable workspace ancestor is rejected" FAIL
elif grep -qF 'writable without a trusted sticky-bit owner' "$TMP/nonsticky-workspace.err"; then
  check "non-sticky group/world-writable workspace ancestor is rejected" PASS
else
  check "non-sticky group/world-writable workspace ancestor uses the stable denial" FAIL
fi

STICKY_PARENT="$TMP/trusted-sticky-parent"
STICKY_WORKSPACE="$STICKY_PARENT/review"
mkdir -p "$STICKY_WORKSPACE"
chmod 1777 "$STICKY_PARENT"
chmod 700 "$STICKY_WORKSPACE"
printf '%s\n' "$PROJECT/README.md" > "$STICKY_WORKSPACE/FILES.txt"
: > "$STICKY_WORKSPACE/ROOTS.txt"
STICKY_OUT="$(helper "$DATA" "$SESSION" create --kind plan-review \
  --files-manifest "$STICKY_WORKSPACE/FILES.txt" \
  --safe-subtrees-manifest "$STICKY_WORKSPACE/ROOTS.txt" --max-workers 1 2>/dev/null)"
case "$STICKY_OUT" in
  lease_id=rel1_*)
    check "current-user-owned sticky writable ancestor remains allowed" PASS
    helper "$DATA" "$SESSION" close --lease-id "${STICKY_OUT#lease_id=}" >/dev/null
    ;;
  *) check "current-user-owned sticky writable ancestor remains allowed" FAIL ;;
esac

FOREIGN_PARENT="$TMP/foreign-sticky-parent"
FOREIGN_WORKSPACE="$FOREIGN_PARENT/review"
mkdir -p "$FOREIGN_WORKSPACE"
chmod 1777 "$FOREIGN_PARENT"
chmod 700 "$FOREIGN_WORKSPACE"
printf '%s\n' "$PROJECT/README.md" > "$FOREIGN_WORKSPACE/FILES.txt"
: > "$FOREIGN_WORKSPACE/ROOTS.txt"
if chown 1 "$FOREIGN_PARENT" 2>/dev/null; then
  if helper "$DATA" "$SESSION" create --kind plan-review \
      --files-manifest "$FOREIGN_WORKSPACE/FILES.txt" \
      --safe-subtrees-manifest "$FOREIGN_WORKSPACE/ROOTS.txt" --max-workers 1 \
      > /dev/null 2> "$TMP/foreign-sticky.err"; then
    check "foreign non-root sticky writable ancestor is rejected" FAIL
  elif grep -qF 'writable without a trusted sticky-bit owner' "$TMP/foreign-sticky.err"; then
    check "foreign non-root sticky writable ancestor is rejected" PASS
  else
    check "foreign non-root sticky writable ancestor uses the stable denial" FAIL
  fi
elif grep -qF 'stat.uid === 0 || stat.uid === currentUid' \
    "$PLUGIN/hooks/lib/review-evidence-lease-v1.js"; then
  check "foreign sticky-owner guard is structurally verified when chown is unavailable" PASS
else
  check "foreign sticky-owner guard is structurally verified when chown is unavailable" FAIL
fi

FOREIGN_READONLY_PARENT="$TMP/foreign-readonly-parent"
FOREIGN_READONLY_WORKSPACE="$FOREIGN_READONLY_PARENT/review"
mkdir -p "$FOREIGN_READONLY_WORKSPACE"
chmod 700 "$FOREIGN_READONLY_WORKSPACE"
printf '%s\n' "$PROJECT/README.md" > "$FOREIGN_READONLY_WORKSPACE/FILES.txt"
: > "$FOREIGN_READONLY_WORKSPACE/ROOTS.txt"
if chown 1 "$FOREIGN_READONLY_PARENT" 2>/dev/null; then
  chmod 0555 "$FOREIGN_READONLY_PARENT"
  if helper "$DATA" "$SESSION" create --kind plan-review \
      --files-manifest "$FOREIGN_READONLY_WORKSPACE/FILES.txt" \
      --safe-subtrees-manifest "$FOREIGN_READONLY_WORKSPACE/ROOTS.txt" --max-workers 1 \
      > /dev/null 2> "$TMP/foreign-readonly.err"; then
    check "foreign-owned non-writable workspace ancestor is rejected" FAIL
  elif grep -qF 'review workspace ancestor has an untrusted owner' \
      "$TMP/foreign-readonly.err"; then
    check "foreign-owned non-writable workspace ancestor is rejected" PASS
  else
    check "foreign-owned non-writable workspace ancestor uses the stable denial" FAIL
  fi
elif grep -qF '!leaf && currentUid !== null && stat.uid !== 0 && stat.uid !== currentUid' \
    "$PLUGIN/hooks/lib/review-evidence-lease-v1.js"; then
  check "foreign non-writable ancestor guard is structurally verified when chown is unavailable" PASS
else
  check "foreign non-writable ancestor guard is structurally verified when chown is unavailable" FAIL
fi

SYSTEM_TMP="$(cd -P -- /tmp && pwd -P)"
SYSTEM_FILES="$(mktemp "$SYSTEM_TMP/zensu-evidence-files.XXXXXX")"
SYSTEM_ROOTS="$(mktemp "$SYSTEM_TMP/zensu-evidence-roots.XXXXXX")"
printf '%s\n' "$PROJECT/README.md" > "$SYSTEM_FILES"
: > "$SYSTEM_ROOTS"
if helper "$DATA" "$SESSION" create --kind plan-review \
    --files-manifest "$SYSTEM_FILES" --safe-subtrees-manifest "$SYSTEM_ROOTS" \
    --max-workers 1 > /dev/null 2> "$TMP/system-workspace.err"; then
  check "shared system temp root cannot be used as the private workspace leaf" FAIL
elif grep -qF 'owned by the current user with mode 0700' "$TMP/system-workspace.err" \
    || { grep -qF 'must not overlap plugin runtime or private plugin data' \
           "$TMP/system-workspace.err" \
         && grep -qF 'stat.uid !== process.getuid()' \
           "$PLUGIN/hooks/lib/review-evidence-lease-v1.js"; }; then
  check "shared system temp root cannot be used as the private workspace leaf" PASS
else
  check "shared system temp root rejection is portable and fail-closed" FAIL
fi
    ;;
esac

PRIVATE_WORKSPACE="$DATA/reviewer-workspace"
mkdir -p "$PRIVATE_WORKSPACE"
printf '%s\n' "$PROJECT/README.md" > "$PRIVATE_WORKSPACE/FILES.txt"
: > "$PRIVATE_WORKSPACE/ROOTS.txt"
if helper "$DATA" "$SESSION" create --kind plan-review \
    --files-manifest "$PRIVATE_WORKSPACE/FILES.txt" \
    --safe-subtrees-manifest "$PRIVATE_WORKSPACE/ROOTS.txt" --max-workers 1 \
    > /dev/null 2> "$TMP/private-workspace.err"; then
  check "workspace below CLAUDE_PLUGIN_DATA is rejected" FAIL
elif grep -qF 'review workspace root must not overlap plugin runtime or private plugin data' \
    "$TMP/private-workspace.err"; then
  check "workspace below CLAUDE_PLUGIN_DATA is rejected" PASS
else
  check "workspace below CLAUDE_PLUGIN_DATA is rejected with the expected boundary" FAIL
fi

printf 'private plugin data\n' > "$DATA/ordinary-private.txt"
printf '%s\n' "$DATA/ordinary-private.txt" > "$UNSAFE/FILES.txt"
if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
    --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
  check "external workspace cannot lease an exact plugin-data file" FAIL
else
  check "external workspace cannot lease an exact plugin-data file" PASS
fi

mkdir -p "$PLUGIN/tests/results"
PLUGIN_SCOPE_WORKSPACE="$(mktemp -d "$PLUGIN/tests/results/evidence-scope.XXXXXX")"
PLUGIN_SCOPE_WORKSPACE="$(cd -P -- "$PLUGIN_SCOPE_WORKSPACE" && pwd -P)"
printf '%s\n' "$PROJECT/README.md" > "$PLUGIN_SCOPE_WORKSPACE/FILES.txt"
: > "$PLUGIN_SCOPE_WORKSPACE/ROOTS.txt"
if helper "$DATA" "$SESSION" create --kind plan-review \
    --files-manifest "$PLUGIN_SCOPE_WORKSPACE/FILES.txt" \
    --safe-subtrees-manifest "$PLUGIN_SCOPE_WORKSPACE/ROOTS.txt" --max-workers 1 \
    > /dev/null 2> "$TMP/plugin-workspace.err"; then
  check "workspace below pluginRoot is rejected" FAIL
elif grep -qF 'review workspace root must not overlap plugin runtime or private plugin data' \
    "$TMP/plugin-workspace.err"; then
  check "workspace below pluginRoot is rejected" PASS
else
  sed 's/^/    plugin workspace stderr: /' "$TMP/plugin-workspace.err" >&2
  check "workspace below pluginRoot is rejected with the expected boundary" FAIL
fi

printf '%s\n' "$PLUGIN/README.md" > "$UNSAFE/FILES.txt"
if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
    --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
  check "external workspace cannot lease a non-skill pluginRoot file" FAIL
else
  check "external workspace cannot lease a non-skill pluginRoot file" PASS
fi

printf '%s\n' "$PLUGIN/skills/pr-team-review/rules/reviewer-personas.md" > "$UNSAFE/FILES.txt"
SKILL_RULE_OUT="$(helper "$DATA" "$SESSION" create --kind plan-review \
  --files-manifest "$UNSAFE/FILES.txt" --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" \
  --max-workers 1 2>/dev/null)"
case "$SKILL_RULE_OUT" in
  lease_id=rel1_*)
    check "explicit exact persona rule below pluginRoot/skills remains allowed" PASS
    helper "$DATA" "$SESSION" close --lease-id "${SKILL_RULE_OUT#lease_id=}" >/dev/null
    ;;
  *) check "explicit exact persona rule below pluginRoot/skills remains allowed" FAIL ;;
esac

printf 'SECRET=value\n' > "$UNSAFE/.env.production"
printf '%s\n' "$UNSAFE/.env.production" > "$UNSAFE/FILES.txt"
if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
    --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
  check ".env variants are rejected" FAIL
else
  check ".env variants are rejected" PASS
fi
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'fake' '-----END PRIVATE KEY-----' > "$UNSAFE/source.txt"
printf '%s\n' "$UNSAFE/source.txt" > "$UNSAFE/FILES.txt"
if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
    --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
  check "private-key content is rejected independent of filename" FAIL
else
  check "private-key content is rejected independent of filename" PASS
fi
printf 'oauth_token: fake\n' > "$UNSAFE/.config/gh/hosts.yml"
printf '%s\n' "$UNSAFE/.config/gh/hosts.yml" > "$UNSAFE/FILES.txt"
if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
    --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
  check "home-config authentication paths are rejected" FAIL
else
  check "home-config authentication paths are rejected" PASS
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    check "symlink/hardlink/special-file negatives skipped only on Windows shell" PASS
    ;;
  *)
    printf 'ordinary\n' > "$UNSAFE/ordinary.txt"
    printf '%s\n' "$UNSAFE/ordinary.txt" > "$UNSAFE/FILES.txt"
    for EXACT_UNSAFE_KIND in tab bidi; do
      ROOT_PATH="$UNSAFE" FILES_PATH="$UNSAFE/FILES.txt" NAME_KIND="$EXACT_UNSAFE_KIND" node -e '
        const fs=require("node:fs"); const path=require("node:path");
        const name=process.env.NAME_KIND === "tab" ? `exact\tname.js` : `exact\u202ename.js`;
        const target=path.join(process.env.ROOT_PATH,name);
        fs.writeFileSync(target,"unsafe exact name\n");
        fs.writeFileSync(process.env.FILES_PATH,`${target}\n`);
      '
      : > "$UNSAFE/ROOTS.txt"
      if helper "$DATA" "$SESSION" create --kind plan-review \
          --files-manifest "$UNSAFE/FILES.txt" --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" \
          --max-workers 1 >/dev/null 2> "$TMP/exact-unsafe-$EXACT_UNSAFE_KIND.err"; then
        check "exact manifest rejects $EXACT_UNSAFE_KIND control characters in a path" FAIL
      elif grep -qF 'contains a non-canonical path line' \
          "$TMP/exact-unsafe-$EXACT_UNSAFE_KIND.err"; then
        check "exact manifest rejects $EXACT_UNSAFE_KIND control characters in a path" PASS
      else
        check "exact manifest rejects $EXACT_UNSAFE_KIND path with sanitized diagnostics" FAIL
      fi
    done
    printf '%s\n' "$UNSAFE/ordinary.txt" > "$UNSAFE/FILES.txt"
    UNSAFE_NAME_INDEX=0
    for UNSAFE_NAME_KIND in c0 tab newline del bidi ansi; do
      UNSAFE_NAME_INDEX=$((UNSAFE_NAME_INDEX + 1))
      UNSAFE_NAME_TREE="$UNSAFE/unsafe-name-$UNSAFE_NAME_INDEX"
      mkdir -p "$UNSAFE_NAME_TREE"
      TREE="$UNSAFE_NAME_TREE" NAME_KIND="$UNSAFE_NAME_KIND" node -e '
        const fs=require("node:fs"); const path=require("node:path");
        const names={
          c0:`bell\u0007name.js`, tab:`tab\tname.js`, newline:`line\nname.js`,
          del:`del\u007fname.js`, bidi:`bidi\u202ename.js`, ansi:`ansi\u001b[31mname.js`,
        };
        fs.writeFileSync(path.join(process.env.TREE, names[process.env.NAME_KIND]), "unsafe\n");
      '
      printf '%s\n' "$UNSAFE_NAME_TREE" > "$UNSAFE/ROOTS.txt"
      if helper "$DATA" "$SESSION" create --kind plan-review \
          --files-manifest "$UNSAFE/FILES.txt" --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" \
          --max-workers 1 > /dev/null 2> "$TMP/unsafe-name-$UNSAFE_NAME_INDEX.err"; then
        check "safe subtree rejects $UNSAFE_NAME_KIND control characters in descendant names" FAIL
      elif grep -qF 'contains an unsafe entry name' "$TMP/unsafe-name-$UNSAFE_NAME_INDEX.err" \
          && ERROR_FILE="$TMP/unsafe-name-$UNSAFE_NAME_INDEX.err" node -e '
            const fs=require("node:fs"); let text=fs.readFileSync(process.env.ERROR_FILE,"utf8");
            if (text.endsWith("\n")) text=text.slice(0,-1);
            if (/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/u.test(text)) process.exit(1);
          '; then
        check "safe subtree rejects $UNSAFE_NAME_KIND control characters in descendant names" PASS
      else
        check "safe subtree rejects $UNSAFE_NAME_KIND names with sanitized diagnostics" FAIL
      fi
    done
    printf '%s\n' "$PROJECT" > "$UNSAFE/ROOTS.txt"
    if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
        --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
      check "project-root traversal ancestor is rejected at create" FAIL
    else check "project-root traversal ancestor is rejected at create" PASS; fi
    : > "$UNSAFE/ROOTS.txt"
    ln -s "$UNSAFE/ordinary.txt" "$UNSAFE/alias.txt"
    printf '%s\n' "$UNSAFE/alias.txt" > "$UNSAFE/FILES.txt"
    if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
        --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
      check "symlink exact file is rejected" FAIL
    else check "symlink exact file is rejected" PASS; fi
    ln "$UNSAFE/ordinary.txt" "$UNSAFE/hardlink.txt"
    printf '%s\n' "$UNSAFE/hardlink.txt" > "$UNSAFE/FILES.txt"
    if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
        --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
      check "hardlink exact file is rejected" FAIL
    else check "hardlink exact file is rejected" PASS; fi
    TREE="$UNSAFE/tree"
    mkdir -p "$TREE"
    printf 'safe\n' > "$TREE/safe.txt"
    ln -s /etc/passwd "$TREE/escape"
    printf '%s\n' "$UNSAFE/ordinary.txt" > "$UNSAFE/FILES.txt"
    printf '%s\n' "$TREE" > "$UNSAFE/ROOTS.txt"
    if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
        --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
      check "safe subtree containing descendant symlink is rejected" FAIL
    else check "safe subtree containing descendant symlink is rejected" PASS; fi
    rm "$TREE/escape"
    mkfifo "$TREE/special.pipe"
    if helper "$DATA" "$SESSION" create --kind plan-review --files-manifest "$UNSAFE/FILES.txt" \
        --safe-subtrees-manifest "$UNSAFE/ROOTS.txt" --max-workers 1 >/dev/null 2>&1; then
      check "safe subtree containing a special file is rejected" FAIL
    else check "safe subtree containing a special file is rejected" PASS; fi
    ;;
esac

# Finalization is the generation-wide snapshot-integrity barrier. A worker can
# finish without reading every exact file, and evidence can drift after its last
# allowed tool call; neither case may become collectable.
SEAL_DATA="$TMP/seal-data"
SEAL_PROJECT="$TMP/seal-project"
SEAL_SPACE="$TMP/seal-workspace"
SEAL_SESSION='seal-integrity-session'
mkdir -p "$SEAL_DATA" "$SEAL_PROJECT/tree" "$SEAL_SPACE"
chmod 700 "$SEAL_SPACE"
printf 'exact-v1\n' > "$SEAL_PROJECT/exact.txt"
printf 'tree-v1\n' > "$SEAL_PROJECT/tree/item.txt"
printf '%s\n' "$SEAL_PROJECT/exact.txt" > "$SEAL_SPACE/FILES.txt"
printf '%s\n' "$SEAL_PROJECT/tree" > "$SEAL_SPACE/ROOTS.txt"
session_start "$SEAL_DATA" "$SEAL_SESSION" "$SEAL_PROJECT"

SEAL_UNREAD_OUT="$(helper "$SEAL_DATA" "$SEAL_SESSION" create --kind plan-review \
  --files-manifest "$SEAL_SPACE/FILES.txt" --safe-subtrees-manifest "$SEAL_SPACE/ROOTS.txt" \
  --max-workers 1 2>/dev/null)"
SEAL_UNREAD_ID="${SEAL_UNREAD_OUT#lease_id=}"
bind_worker "$SEAL_DATA" "$SEAL_SESSION" seal-unread-agent zensu:plan-review-worker >/dev/null 2>&1
stop_worker "$SEAL_DATA" "$SEAL_SESSION" seal-unread-agent zensu:plan-review-worker \
  "$(valid_plan_result architecture-fit)" >/dev/null 2>&1
printf 'exact-v2\n' > "$SEAL_PROJECT/exact.txt"
if helper "$SEAL_DATA" "$SEAL_SESSION" finalize --lease-id "$SEAL_UNREAD_ID" \
    >/dev/null 2>&1; then
  check "finalize rejects drift in an unread exact evidence file" FAIL
else
  check "finalize rejects drift in an unread exact evidence file" PASS
fi
helper "$SEAL_DATA" "$SEAL_SESSION" close --lease-id "$SEAL_UNREAD_ID" >/dev/null

SEAL_READ_OUT="$(helper "$SEAL_DATA" "$SEAL_SESSION" create --kind plan-review \
  --files-manifest "$SEAL_SPACE/FILES.txt" --safe-subtrees-manifest "$SEAL_SPACE/ROOTS.txt" \
  --max-workers 1 2>/dev/null)"
SEAL_READ_ID="${SEAL_READ_OUT#lease_id=}"
bind_worker "$SEAL_DATA" "$SEAL_SESSION" seal-read-agent zensu:plan-review-worker >/dev/null 2>&1
assert_gate "exact evidence is valid at the worker's last Read" allow "$SEAL_DATA" "$SEAL_SESSION" \
  seal-read-agent zensu:plan-review-worker Read "{\"file_path\":\"$SEAL_PROJECT/exact.txt\"}"
stop_worker "$SEAL_DATA" "$SEAL_SESSION" seal-read-agent zensu:plan-review-worker \
  "$(valid_plan_result risk-rollout)" >/dev/null 2>&1
printf 'exact-v3\n' > "$SEAL_PROJECT/exact.txt"
if helper "$SEAL_DATA" "$SEAL_SESSION" finalize --lease-id "$SEAL_READ_ID" \
    >/dev/null 2>&1; then
  check "finalize rejects exact-file drift after the last successful Read" FAIL
else
  check "finalize rejects exact-file drift after the last successful Read" PASS
fi
helper "$SEAL_DATA" "$SEAL_SESSION" close --lease-id "$SEAL_READ_ID" >/dev/null

SEAL_ROOT_OUT="$(helper "$SEAL_DATA" "$SEAL_SESSION" create --kind plan-review \
  --files-manifest "$SEAL_SPACE/FILES.txt" --safe-subtrees-manifest "$SEAL_SPACE/ROOTS.txt" \
  --max-workers 1 2>/dev/null)"
SEAL_ROOT_ID="${SEAL_ROOT_OUT#lease_id=}"
bind_worker "$SEAL_DATA" "$SEAL_SESSION" seal-root-agent zensu:plan-review-worker >/dev/null 2>&1
assert_gate "safe root is valid at the worker's last Grep" allow "$SEAL_DATA" "$SEAL_SESSION" \
  seal-root-agent zensu:plan-review-worker Grep \
  "{\"pattern\":\"tree-v1\",\"path\":\"$SEAL_PROJECT/tree\"}"
stop_worker "$SEAL_DATA" "$SEAL_SESSION" seal-root-agent zensu:plan-review-worker \
  "$(valid_plan_result testing-tdd)" >/dev/null 2>&1
printf 'tree-v2\n' > "$SEAL_PROJECT/tree/item.txt"
if helper "$SEAL_DATA" "$SEAL_SESSION" finalize --lease-id "$SEAL_ROOT_ID" \
    >/dev/null 2>&1; then
  check "finalize rejects safe-root drift after the last successful Grep" FAIL
else
  check "finalize rejects safe-root drift after the last successful Grep" PASS
fi
helper "$SEAL_DATA" "$SEAL_SESSION" close --lease-id "$SEAL_ROOT_ID" >/dev/null

# Close is the authenticated recovery path even when the external active
# workspace vanished or its permissions drifted. It must still reject a wrong
# host context or a record whose integrity seal no longer matches.
RECOVERY_DATA="$TMP/recovery-data"
RECOVERY_PROJECT="$TMP/recovery-project"
RECOVERY_SESSION='close-recovery-session'
mkdir -p "$RECOVERY_DATA" "$RECOVERY_PROJECT"
printf 'recovery\n' > "$RECOVERY_PROJECT/source.js"
session_start "$RECOVERY_DATA" "$RECOVERY_SESSION" "$RECOVERY_PROJECT"

RECOVERY_SPACE="$TMP/recovery-workspace-deleted"
mkdir -p "$RECOVERY_SPACE"
chmod 700 "$RECOVERY_SPACE"
printf '%s\n' "$RECOVERY_PROJECT/source.js" > "$RECOVERY_SPACE/FILES.txt"
: > "$RECOVERY_SPACE/ROOTS.txt"
RECOVERY_OUT="$(helper "$RECOVERY_DATA" "$RECOVERY_SESSION" create --kind plan-review \
  --files-manifest "$RECOVERY_SPACE/FILES.txt" \
  --safe-subtrees-manifest "$RECOVERY_SPACE/ROOTS.txt" --max-workers 1 2>/dev/null)"
RECOVERY_ID="${RECOVERY_OUT#lease_id=}"
if helper "$RECOVERY_DATA" wrong-close-session close --lease-id "$RECOVERY_ID" \
    >/dev/null 2>&1; then
  check "wrong host context cannot close an authentic lease" FAIL
else
  check "wrong host context cannot close an authentic lease" PASS
fi
rm -rf "$RECOVERY_SPACE"
RECOVERY_CLOSE="$(helper "$RECOVERY_DATA" "$RECOVERY_SESSION" close \
  --lease-id "$RECOVERY_ID" 2>/dev/null)"
[ "$RECOVERY_CLOSE" = "closed=$RECOVERY_ID" ] \
  && check "close recovers an active lease after workspace deletion" PASS \
  || check "close recovers an active lease after workspace deletion" FAIL

RECOVERY_SPACE="$TMP/recovery-workspace-next"
mkdir -p "$RECOVERY_SPACE"
chmod 700 "$RECOVERY_SPACE"
printf '%s\n' "$RECOVERY_PROJECT/source.js" > "$RECOVERY_SPACE/FILES.txt"
: > "$RECOVERY_SPACE/ROOTS.txt"
RECOVERY_NEXT="$(helper "$RECOVERY_DATA" "$RECOVERY_SESSION" create --kind plan-review \
  --files-manifest "$RECOVERY_SPACE/FILES.txt" \
  --safe-subtrees-manifest "$RECOVERY_SPACE/ROOTS.txt" --max-workers 1 2>/dev/null)"
case "$RECOVERY_NEXT" in
  lease_id=rel1_*) check "new generation starts immediately after deleted-workspace close" PASS ;;
  *) check "new generation starts immediately after deleted-workspace close" FAIL ;;
esac
helper "$RECOVERY_DATA" "$RECOVERY_SESSION" close \
  --lease-id "${RECOVERY_NEXT#lease_id=}" >/dev/null

RECOVERY_SPACE="$TMP/recovery-workspace-mode"
mkdir -p "$RECOVERY_SPACE"
chmod 700 "$RECOVERY_SPACE"
printf '%s\n' "$RECOVERY_PROJECT/source.js" > "$RECOVERY_SPACE/FILES.txt"
: > "$RECOVERY_SPACE/ROOTS.txt"
RECOVERY_MODE="$(helper "$RECOVERY_DATA" "$RECOVERY_SESSION" create --kind plan-review \
  --files-manifest "$RECOVERY_SPACE/FILES.txt" \
  --safe-subtrees-manifest "$RECOVERY_SPACE/ROOTS.txt" --max-workers 1 2>/dev/null)"
RECOVERY_MODE_ID="${RECOVERY_MODE#lease_id=}"
chmod 755 "$RECOVERY_SPACE"
if helper "$RECOVERY_DATA" "$RECOVERY_SESSION" close --lease-id "$RECOVERY_MODE_ID" \
    >/dev/null 2>&1; then
  check "close recovers an active lease after workspace mode drift" PASS
else
  check "close recovers an active lease after workspace mode drift" FAIL
fi

RECOVERY_SPACE="$TMP/recovery-workspace-after-mode"
mkdir -p "$RECOVERY_SPACE"
chmod 700 "$RECOVERY_SPACE"
printf '%s\n' "$RECOVERY_PROJECT/source.js" > "$RECOVERY_SPACE/FILES.txt"
: > "$RECOVERY_SPACE/ROOTS.txt"
RECOVERY_AFTER_MODE="$(helper "$RECOVERY_DATA" "$RECOVERY_SESSION" create --kind plan-review \
  --files-manifest "$RECOVERY_SPACE/FILES.txt" \
  --safe-subtrees-manifest "$RECOVERY_SPACE/ROOTS.txt" --max-workers 1 2>/dev/null)"
case "$RECOVERY_AFTER_MODE" in
  lease_id=rel1_*) check "new generation starts immediately after mode-drift close" PASS ;;
  *) check "new generation starts immediately after mode-drift close" FAIL ;;
esac
helper "$RECOVERY_DATA" "$RECOVERY_SESSION" close \
  --lease-id "${RECOVERY_AFTER_MODE#lease_id=}" >/dev/null

RECOVERY_SPACE="$TMP/recovery-workspace-tamper"
mkdir -p "$RECOVERY_SPACE"
chmod 700 "$RECOVERY_SPACE"
printf '%s\n' "$RECOVERY_PROJECT/source.js" > "$RECOVERY_SPACE/FILES.txt"
: > "$RECOVERY_SPACE/ROOTS.txt"
RECOVERY_TAMPER="$(helper "$RECOVERY_DATA" "$RECOVERY_SESSION" create --kind plan-review \
  --files-manifest "$RECOVERY_SPACE/FILES.txt" \
  --safe-subtrees-manifest "$RECOVERY_SPACE/ROOTS.txt" --max-workers 1 2>/dev/null)"
RECOVERY_TAMPER_ID="${RECOVERY_TAMPER#lease_id=}"
RECOVERY_KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' \
  "$PLUGIN/hooks/lib/session-control-core-v1.js" "$RECOVERY_SESSION")"
RECOVERY_RECORD="$RECOVERY_DATA/review-evidence/v1/records/$RECOVERY_KEY/$RECOVERY_TAMPER_ID.json"
cp "$RECOVERY_RECORD" "$RECOVERY_RECORD.backup"
RECORD="$RECOVERY_RECORD" node -e '
  const fs=require("node:fs"); const value=JSON.parse(fs.readFileSync(process.env.RECORD,"utf8"));
  value.revision+=1; fs.writeFileSync(process.env.RECORD,`${JSON.stringify(value)}\n`);
'
if helper "$RECOVERY_DATA" "$RECOVERY_SESSION" close --lease-id "$RECOVERY_TAMPER_ID" \
    >/dev/null 2>&1; then
  check "relaxed recovery close still rejects a tampered private record" FAIL
else
  check "relaxed recovery close still rejects a tampered private record" PASS
fi
mv "$RECOVERY_RECORD.backup" "$RECOVERY_RECORD"
helper "$RECOVERY_DATA" "$RECOVERY_SESSION" close --lease-id "$RECOVERY_TAMPER_ID" >/dev/null

# Snapshot and record-integrity revalidation on every tool call.
HASH_DATA="$TMP/hash-data"
HASH_PROJECT="$TMP/hash-project"
HASH_SPACE="$TMP/hash-workspace"
HASH_SESSION='hash-session'
mkdir -p "$HASH_DATA" "$HASH_PROJECT/src" "$HASH_SPACE"
chmod 700 "$HASH_SPACE"
printf 'immutable\n' > "$HASH_PROJECT/source.js"
printf 'tree\n' > "$HASH_PROJECT/src/tree.js"
printf '%s\n' "$HASH_PROJECT/source.js" > "$HASH_SPACE/FILES.txt"
printf '%s\n' "$HASH_PROJECT/src" > "$HASH_SPACE/ROOTS.txt"
session_start "$HASH_DATA" "$HASH_SESSION" "$HASH_PROJECT"
HASH_OUT="$(helper "$HASH_DATA" "$HASH_SESSION" create --kind plan-review \
  --files-manifest "$HASH_SPACE/FILES.txt" --safe-subtrees-manifest "$HASH_SPACE/ROOTS.txt" \
  --max-workers 1 2>/dev/null)"
HASH_ID="${HASH_OUT#lease_id=}"
bind_worker "$HASH_DATA" "$HASH_SESSION" hash-agent zensu:plan-review-worker >/dev/null 2>&1
printf 'mutated\n' > "$HASH_PROJECT/source.js"
assert_gate "exact-file content/metadata mutation invalidates Read" deny "$HASH_DATA" "$HASH_SESSION" \
  hash-agent zensu:plan-review-worker Read "{\"file_path\":\"$HASH_PROJECT/source.js\"}"
printf 'mutated-tree\n' > "$HASH_PROJECT/src/tree.js"
assert_gate "safe-root tree mutation invalidates traversal" deny "$HASH_DATA" "$HASH_SESSION" \
  hash-agent zensu:plan-review-worker Grep "{\"pattern\":\"tree\",\"path\":\"$HASH_PROJECT/src\"}"

HASH_KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' \
  "$PLUGIN/hooks/lib/session-control-core-v1.js" "$HASH_SESSION")"
HASH_RECORD="$HASH_DATA/review-evidence/v1/records/$HASH_KEY/$HASH_ID.json"
cp "$HASH_RECORD" "$HASH_RECORD.backup"
RECORD="$HASH_RECORD" node -e '
  const fs=require("node:fs"); const p=process.env.RECORD;
  const j=JSON.parse(fs.readFileSync(p,"utf8")); j.max_workers=32;
  fs.writeFileSync(p, `${JSON.stringify(j)}\n`);
'
assert_gate "unsealed private record tamper fails closed" deny "$HASH_DATA" "$HASH_SESSION" hash-agent \
  zensu:plan-review-worker Read "{\"file_path\":\"$HASH_PROJECT/source.js\"}"
mv "$HASH_RECORD.backup" "$HASH_RECORD"

# A validly sealed expired record is still denied; create may close it and move
# to a new generation instead of leaving a permanent dead record.
RECORD="$HASH_RECORD" MODULE="$PLUGIN/hooks/lib/review-evidence-lease-v1.js" node -e '
  const fs=require("node:fs"); const lease=require(process.env.MODULE);
  const j=JSON.parse(fs.readFileSync(process.env.RECORD,"utf8"));
  j.expires_at_ms=Date.now()-1; j.revision+=1;
  fs.writeFileSync(process.env.RECORD, `${JSON.stringify(lease.sealRecord(j))}\n`);
'
assert_gate "expired worker lease is denied" deny "$HASH_DATA" "$HASH_SESSION" hash-agent \
  zensu:plan-review-worker Read "{\"file_path\":\"$HASH_PROJECT/source.js\"}"
rm -rf "$HASH_SPACE"
HASH_SPACE="$TMP/hash-workspace-next"
mkdir -p "$HASH_SPACE"
chmod 700 "$HASH_SPACE"
printf '%s\n' "$HASH_PROJECT/source.js" > "$HASH_SPACE/FILES.txt"
: > "$HASH_SPACE/ROOTS.txt"
if helper "$HASH_DATA" "$HASH_SESSION" create --kind plan-review \
    --files-manifest "$HASH_SPACE/FILES.txt" --safe-subtrees-manifest "$HASH_SPACE/ROOTS.txt" \
    --max-workers 1 >/dev/null 2>&1; then
  check "expired lease closes atomically and permits a new generation" PASS
else
  check "expired lease closes atomically and permits a new generation" FAIL
fi

# Concurrent create/bind contenders are serialized by the private token lock:
# exactly one generation and at most max_workers bindings win.
RACE_DATA="$TMP/race-data"
RACE_PROJECT="$TMP/race-project"
RACE_SPACE="$TMP/race-workspace"
RACE_SESSION='race-session'
mkdir -p "$RACE_DATA" "$RACE_PROJECT" "$RACE_SPACE"
chmod 700 "$RACE_SPACE"
printf 'race\n' > "$RACE_PROJECT/source.js"
printf '%s\n' "$RACE_PROJECT/source.js" > "$RACE_SPACE/FILES.txt"
: > "$RACE_SPACE/ROOTS.txt"
session_start "$RACE_DATA" "$RACE_SESSION" "$RACE_PROJECT"
(
  helper "$RACE_DATA" "$RACE_SESSION" create --kind plan-review \
    --files-manifest "$RACE_SPACE/FILES.txt" --safe-subtrees-manifest "$RACE_SPACE/ROOTS.txt" \
    --max-workers 1 > "$TMP/race-create-1.out" 2>/dev/null
  printf '%s\n' "$?" > "$TMP/race-create-1.status"
) & RACE_CREATE_PID_1=$!
(
  helper "$RACE_DATA" "$RACE_SESSION" create --kind plan-review \
    --files-manifest "$RACE_SPACE/FILES.txt" --safe-subtrees-manifest "$RACE_SPACE/ROOTS.txt" \
    --max-workers 1 > "$TMP/race-create-2.out" 2>/dev/null
  printf '%s\n' "$?" > "$TMP/race-create-2.status"
) & RACE_CREATE_PID_2=$!
wait "$RACE_CREATE_PID_1" "$RACE_CREATE_PID_2"
RACE_CREATE_SUCCESS=0
[ "$(cat "$TMP/race-create-1.status")" -eq 0 ] && RACE_CREATE_SUCCESS=$((RACE_CREATE_SUCCESS + 1))
[ "$(cat "$TMP/race-create-2.status")" -eq 0 ] && RACE_CREATE_SUCCESS=$((RACE_CREATE_SUCCESS + 1))
[ "$RACE_CREATE_SUCCESS" -eq 1 ] \
  && check "concurrent duplicate creates yield exactly one active lease" PASS \
  || check "concurrent duplicate creates yield exactly one active lease" FAIL
RACE_ID="$(cat "$TMP/race-create-1.out" "$TMP/race-create-2.out")"
RACE_ID="${RACE_ID#lease_id=}"
(
  bind_worker "$RACE_DATA" "$RACE_SESSION" race-agent-1 zensu:plan-review-worker \
    > "$TMP/race-bind-1.out" 2>/dev/null
  printf '%s\n' "$?" > "$TMP/race-bind-1.status"
) & RACE_BIND_PID_1=$!
(
  bind_worker "$RACE_DATA" "$RACE_SESSION" race-agent-2 zensu:plan-review-worker \
    > "$TMP/race-bind-2.out" 2>/dev/null
  printf '%s\n' "$?" > "$TMP/race-bind-2.status"
) & RACE_BIND_PID_2=$!
wait "$RACE_BIND_PID_1" "$RACE_BIND_PID_2"
RACE_BIND_SUCCESS=0
[ "$(cat "$TMP/race-bind-1.status")" -eq 0 ] && RACE_BIND_SUCCESS=$((RACE_BIND_SUCCESS + 1))
[ "$(cat "$TMP/race-bind-2.status")" -eq 0 ] && RACE_BIND_SUCCESS=$((RACE_BIND_SUCCESS + 1))
[ "$RACE_BIND_SUCCESS" -eq 1 ] \
  && check "concurrent SubagentStart contenders enforce max_workers atomically" PASS \
  || check "concurrent SubagentStart contenders enforce max_workers atomically" FAIL
helper "$RACE_DATA" "$RACE_SESSION" close --lease-id "$RACE_ID" >/dev/null

# An abandoned lock is never reclaimed in-place. While a contender is waiting,
# replace the dead/stale token atomically with a live owner's token. The
# contender must neither delete the replacement nor enter a second critical
# section; a fresh host session is the fail-closed recovery path.
LOCK_DATA="$TMP/lock-data"
LOCK_PROJECT="$TMP/lock-project"
LOCK_SPACE="$TMP/lock-workspace"
LOCK_SESSION='abandoned-lock-session'
mkdir -p "$LOCK_DATA" "$LOCK_PROJECT" "$LOCK_SPACE"
chmod 700 "$LOCK_SPACE"
printf 'locked\n' > "$LOCK_PROJECT/source.js"
printf '%s\n' "$LOCK_PROJECT/source.js" > "$LOCK_SPACE/FILES.txt"
: > "$LOCK_SPACE/ROOTS.txt"
session_start "$LOCK_DATA" "$LOCK_SESSION" "$LOCK_PROJECT"
LOCK_INIT_OUT="$(helper "$LOCK_DATA" "$LOCK_SESSION" create --kind plan-review \
  --files-manifest "$LOCK_SPACE/FILES.txt" --safe-subtrees-manifest "$LOCK_SPACE/ROOTS.txt" \
  --max-workers 1 2>/dev/null)"
helper "$LOCK_DATA" "$LOCK_SESSION" close --lease-id "${LOCK_INIT_OUT#lease_id=}" >/dev/null
LOCK_KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' \
  "$PLUGIN/hooks/lib/session-control-core-v1.js" "$LOCK_SESSION")"
LOCK_FILE="$LOCK_DATA/review-evidence/v1/locks/$LOCK_KEY.lock"
printf '%s\n' '2147483647:aaaaaaaaaaaaaaaaaaaaaaaa' > "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
LOCK_FILE_VALUE="$LOCK_FILE" node -e '
  const fs=require("node:fs");
  fs.utimesSync(process.env.LOCK_FILE_VALUE, new Date(0), new Date(0));
'
(
  helper "$LOCK_DATA" "$LOCK_SESSION" create --kind plan-review \
    --files-manifest "$LOCK_SPACE/FILES.txt" --safe-subtrees-manifest "$LOCK_SPACE/ROOTS.txt" \
    --max-workers 1 > "$TMP/abandoned-lock.out" 2> "$TMP/abandoned-lock.err"
  printf '%s\n' "$?" > "$TMP/abandoned-lock.status"
) & LOCK_CONTENDER_PID=$!
sleep 0.1
LIVE_LOCK_VALUE="$$:bbbbbbbbbbbbbbbbbbbbbbbb"
LOCK_REPLACEMENT="$LOCK_FILE.replacement"
printf '%s\n' "$LIVE_LOCK_VALUE" > "$LOCK_REPLACEMENT"
chmod 600 "$LOCK_REPLACEMENT"
mv "$LOCK_REPLACEMENT" "$LOCK_FILE"
wait "$LOCK_CONTENDER_PID"

if [ "$(cat "$TMP/abandoned-lock.status")" -ne 0 ] \
    && grep -qF 'private lease lock is busy or abandoned' "$TMP/abandoned-lock.err" \
    && grep -qF 'fresh session' "$TMP/abandoned-lock.err" \
    && ! grep -qF "$LOCK_FILE" "$TMP/abandoned-lock.err" \
    && ! grep -qF "$LOCK_KEY" "$TMP/abandoned-lock.err" \
    && ! grep -qF "$LOCK_DATA" "$TMP/abandoned-lock.err"; then
  check "abandoned lock fails closed with a sanitized fresh-session recovery" PASS
else
  check "abandoned lock fails closed with a sanitized fresh-session recovery" FAIL
fi
if [ "$(cat "$LOCK_FILE")" = "$LIVE_LOCK_VALUE" ]; then
  check "waiting contender never deletes an atomically replaced live lock" PASS
else
  check "waiting contender never deletes an atomically replaced live lock" FAIL
fi
LOCK_ACTIVE_COUNT="$(RECORDS="$LOCK_DATA/review-evidence/v1/records/$LOCK_KEY" node -e '
  const fs=require("node:fs");
  const records=fs.readdirSync(process.env.RECORDS)
    .filter((entry)=>entry.endsWith(".json"))
    .map((entry)=>JSON.parse(fs.readFileSync(`${process.env.RECORDS}/${entry}`, "utf8")));
  process.stdout.write(String(records.filter((record)=>record.status === "active").length));
')"
[ "$LOCK_ACTIVE_COUNT" -eq 0 ] \
  && check "abandoned lock never admits a second critical section" PASS \
  || check "abandoned lock never admits a second critical section" FAIL
rm "$LOCK_FILE"

printf '%s\n' "----" "test-review-worker-evidence-lease: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
