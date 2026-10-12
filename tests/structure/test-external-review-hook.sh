#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOK="$PLUGIN_DIR/hooks/post-workflow-launch.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LIB="$PLUGIN_DIR/hooks/lib/external-review-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/external-review-v1.test.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
REGISTRATION="$PLUGIN_DIR/hooks/lib/hook-registration-v1.js"
CAPABILITY="$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"
source "$PLUGIN_DIR/tests/structure/lib-unit-registry.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-external-review-hook: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$HOOK" "$STOP" "$LOG" "$LIB" "$UNIT" "$HOOKS_JSON" "$REGISTRATION" "$CAPABILITY" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "X0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "X0 node and git are available" FAIL
  finish
  exit 1
fi
check "X0 required files, node and git are present" PASS

if node -e 'const m = require(process.argv[1]); process.exit(m.ciStructureTests.includes("test-external-review-hook.sh") ? 0 : 1)' "$PROFILE"; then
  check "X0a the suite is classified as a CI structure test" PASS
else
  check "X0a the suite is classified as a CI structure test" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "X0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

unit_check "X0b the external-review unit file passes" "$UNIT"

REG="$(node -e '
  const reg = require(process.argv[1]);
  const manifest = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
  const names = (command) => command.includes("hooks/post-workflow-launch.sh");
  const ask = (event, tools) => reg.registration(manifest, { event, tools, names, reading: reg.READINGS.HOST });
  const groups = manifest.hooks.PostToolUse.filter((group) => group.hooks.some((hook) => names(hook.command)));
  const agentGroup = manifest.hooks.PostToolUse.find((group) => group.matcher === "Agent|Task");
  const agentOnlyDelegate = agentGroup && agentGroup.hooks.length === 1 && agentGroup.hooks[0].command.includes("post-review-tdd-delegate.sh");
  const preTool = ask("PreToolUse", ["Workflow"]);
  process.stdout.write([ask("PostToolUse", ["Workflow"]), ask("PostToolUse", ["Agent"]), ask("PostToolUse", ["Bash"]), preTool, groups.length, groups[0] && groups[0].matcher, agentOnlyDelegate].join(" "));
' "$REGISTRATION" "$HOOKS_JSON" 2>/dev/null)"
if [ "$REG" = "registered unregistered unregistered unregistered 1 Workflow true" ]; then
  check "X1 the recorder is registered once, on PostToolUse Workflow only, and the Agent|Task group is unchanged" PASS
else
  check "X1 recorder registration ($REG)" FAIL
fi

if [ "$(grep -c "path.join(trusted.pluginData, 'external-review')" "$CAPABILITY")" = "2" ]; then
  check "X1a the external-review store is in both protected-root lists of the capability gate" PASS
else
  check "X1a the external-review store is in both protected-root lists of the capability gate" FAIL
fi

if bash -n "$HOOK" && bash -n "$STOP" && bash -n "$LOG" && node --check "$LIB"; then
  check "X1b the hook, the Stop hook, zensu-log.sh and the module parse" PASS
else
  check "X1b the hook, the Stop hook, zensu-log.sh and the module parse" FAIL
fi

source "$PLUGIN_DIR/tests/structure/lib-skill-text.sh"
SKILL_FILE="$(skill_text_file "$PLUGIN_DIR/skills/tdd")" || SKILL_FILE="$WORK/missing-skill-text"
if grep -qF 'and an `EXT-<n>` finding the merge kept with the anchor `-` is never neutralized either, because a missing anchor is not a hallucinated one; nothing can grade it, so retitle it `[Deferred — do not fix]` with its original severity in its text, set it to SUGGESTION so no severity mode routes it, ledger it with the anchor `-`' "$SKILL_FILE" \
  && grep -qF 'keep a finding without a `file:line` anchor in the merged list with the anchor `-`' "$SKILL_FILE"; then
  check "X26 the verification gate defers an unanchored imported finding to ## Open instead of neutralizing or routing it" PASS
else
  check "X26 the verification gate defers an unanchored imported finding to ## Open instead of neutralizing or routing it" FAIL
fi
rm -f "$SKILL_FILE"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$WORK/config.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":5}}' > "$ZENSU_CONFIG"
OFF_CONFIG="$WORK/off.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":5,"externalReviewImport":false}}' > "$OFF_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true

DATA="$WORK/hook-data"
mkdir -p "$DATA"
chmod 700 "$DATA"
HOOK_PROJECT="$WORK/hook-project"
mkdir -p "$HOOK_PROJECT"

launch_payload() {
  RAW="$1" EXTRA="${2:-}" node -e '
    const payload = {
      hook_event_name: "PostToolUse",
      session_id: process.env.RAW,
      tool_name: "Workflow",
      cwd: process.cwd(),
      tool_input: { script: "export const meta = { name: \"review-changes\", description: \"Review\" }\nphase(\"Review\")" },
      tool_response: "Started workflow run wf_abc12345-run in the background",
    };
    if (process.env.EXTRA === "subagent") { payload.agent_id = "a1"; payload.agent_type = "general-purpose"; }
    if (process.env.EXTRA === "run") {
      payload.tool_input = { scriptPath: process.env.TEMPLATE_PATH };
      payload.tool_response = { status: "async_launched", taskId: process.env.RUN_TASK, runId: "wf_abc12345-run", transcriptDir: process.env.RUN_DIR };
    }
    process.stdout.write(JSON.stringify(payload));
  '
}

records_for() {
  local key
  key="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" "$1")"
  ls "$2/external-review/v1/records/$key" 2>/dev/null | grep -c '\.json$'
}

OUT="$(launch_payload hook-main | CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PROJECT_DIR="$HOOK_PROJECT" bash "$HOOK" 2>"$WORK/h2.err")"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$WORK/h2.err" ] && [ "$(records_for hook-main "$DATA")" = "1" ]; then
  check "X2 a main-thread Workflow launch writes one record and prints nothing" PASS
else
  check "X2 main-thread launch (rc=$RC out=$OUT records=$(records_for hook-main "$DATA"))" FAIL
fi

OUT="$(launch_payload hook-sub subagent | CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PROJECT_DIR="$HOOK_PROJECT" bash "$HOOK" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(records_for hook-sub "$DATA")" = "0" ]; then
  check "X3 a subagent's Workflow launch writes nothing" PASS
else
  check "X3 subagent launch (rc=$RC out=$OUT)" FAIL
fi

OUT="$(launch_payload hook-off | ZENSU_CONFIG="$OFF_CONFIG" CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PROJECT_DIR="$HOOK_PROJECT" bash "$HOOK" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(records_for hook-off "$DATA")" = "0" ]; then
  check "X4 hooks.externalReviewImport=false records nothing" PASS
else
  check "X4 flag off (rc=$RC out=$OUT)" FAIL
fi

GARBAGE_OK=true
for input in 'not json' '' '[]' '{"tool_name":"Workflow"}'; do
  OUT="$(printf '%s' "$input" | CLAUDE_PLUGIN_DATA="$DATA" bash "$HOOK" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then GARBAGE_OK=false; fi
done
OUT="$(launch_payload hook-nodata | CLAUDE_PLUGIN_DATA="$WORK/absent" bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then GARBAGE_OK=false; fi
OUT="$(launch_payload hook-nodata | env -u CLAUDE_PLUGIN_DATA bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then GARBAGE_OK=false; fi
if [ "$GARBAGE_OK" = "true" ] && [ ! -e "$WORK/absent" ]; then
  check "X5 malformed payloads and a missing plugin data directory exit 0 without output" PASS
else
  check "X5 fail-open (last rc=$RC out=$OUT)" FAIL
fi

PROJ="$WORK/project"
mkdir -p "$PROJ/src"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'one\n' > "$PROJ/src/a.js"
git -C "$PROJ" add -A
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline
printf 'two\n' > "$PROJ/src/a.js"

export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || exit 1
VERB_RAW="external-review-verb"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$VERB_RAW" || { check "X6 session baseline" FAIL; finish; exit 1; }
VERB_DATA="$CLAUDE_PLUGIN_DATA"

verb() {
  printf '%s' "$1" | bash "$LOG" --external-review --root "$PROJ" "${@:2}" 2>"$WORK/verb.err"
}

OUT="$(verb $'src/a.js\n')"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^EXTERNAL REVIEW — status=none launches=0/0 changed=1 '; then
  check "X6 --external-review answers none before any launch was recorded" PASS
else
  check "X6 none (rc=$RC out=$OUT err=$(cat "$WORK/verb.err"))" FAIL
fi

TREE_LINE="$(bash "$LOG" --external-review --tree --root "$PROJ" </dev/null 2>"$WORK/tree.err")"; RC=$?
TREE_ID="$(printf '%s\n' "$TREE_LINE" | sed -n 's/^EXTERNAL REVIEW — tree=\([0-9a-f][0-9a-f]*\)$/\1/p')"
if [ "$RC" -eq 0 ] && [ "${#TREE_ID}" -ge 40 ]; then
  check "X7a --external-review --tree prints the tree id of the working tree" PASS
else
  check "X7a tree (rc=$RC out=$TREE_LINE err=$(cat "$WORK/tree.err"))" FAIL
fi

RUN_TASK="wabc1234"
RUN_DIR="$WORK/runs/projects/session/subagents/workflows/wf_abc12345-run"
RUN_RECORD="$WORK/runs/projects/session/workflows/wf_abc12345-run.json"
RUN_OUTPUT="$WORK/runs/tasks/$RUN_TASK.output"
mkdir -p "$RUN_DIR" "$WORK/runs/tasks" "$(dirname "$RUN_RECORD")"
write_run_record() {
  RUN_STATUS="$1" RUN_TREE="$TREE_ID" RUN_TASK="$RUN_TASK" RUN_RECORD="$RUN_RECORD" TEMPLATE_PATH="$PLUGIN_DIR/templates/workflows/zensu-review-v1.js" node -e '
    const fs = require("fs");
    const finding = {
      id: "correctness-1", lens: "correctness", title: "Off-by-one in the loader", severity: "IMPORTANT", file: "src/a.js", line: 1,
      evidence: "two", failure_scenario: "the last entry is skipped", fix: "compare with <=", confidence: 90, duplicates: [],
      verification: { status: "upheld", reason: "the refuter could not refute it", votes: [{ verifier: "refute", outcome: "real", severity: "IMPORTANT", reasoning: "src/a.js:1" }] },
    };
    const result = {
      schema: "zensu-review-result/v1", tree: process.env.RUN_TREE, lenses: ["correctness"], ceiling: 10,
      agents: { started: 2, finished: 2, failed: 0 }, dropped: [], findings: [finding],
    };
    const done = process.env.RUN_STATUS === "completed";
    fs.writeFileSync(process.env.RUN_RECORD, JSON.stringify({
      runId: "wf_abc12345-run", taskId: process.env.RUN_TASK, status: process.env.RUN_STATUS,
      script: fs.readFileSync(process.env.TEMPLATE_PATH, "utf8"), scriptPath: process.env.TEMPLATE_PATH,
      args: { tree: process.env.RUN_TREE, lenses: ["correctness"], changedFiles: ["src/a.js"] },
      result: done ? result : null, workflowProgress: [],
    }));
  '
}
RUN_DIR="$RUN_DIR" RUN_OUTPUT="$RUN_OUTPUT" node -e '
  const fs = require("fs");
  const path = require("path");
  const labels = ["find:correctness", "refute:correctness#1"];
  const journal = [{ type: "launched" }];
  labels.forEach((label, index) => {
    journal.push({ type: "started", key: `k${index}`, agentId: `a${index}`, label, phase: "Find" });
    journal.push({ type: "result", key: `k${index}`, agentId: `a${index}`, result: {} });
  });
  fs.writeFileSync(path.join(process.env.RUN_DIR, "journal.jsonl"), `${journal.map((line) => JSON.stringify(line)).join("\n")}\n`);
  fs.writeFileSync(process.env.RUN_OUTPUT, JSON.stringify({ summary: "done", result: null, workflowProgress: [] }));
'
write_run_record running

sleep 1
TEMPLATE_PATH="$PLUGIN_DIR/templates/workflows/zensu-review-v1.js" RUN_TASK="$RUN_TASK" RUN_DIR="$RUN_DIR" launch_payload "$VERB_RAW" run | CLAUDE_PLUGIN_DATA="$VERB_DATA" bash "$HOOK" >/dev/null 2>&1
OUT="$(verb $'src/a.js\n.zensu/state/x.json\n')"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^EXTERNAL REVIEW — status=unavailable reason=run-not-completed launches=1/1 selected=zensu-review-v1@[^ ]+ id=xr1_[0-9]{13}_[0-9a-f]{12} .* excluded=1 .* detail=run-status-running$' \
  && printf '%s' "$OUT" | grep -qE " task=$RUN_TASK fresh$" \
  && ! printf '%s' "$OUT" | grep -qF ' begin nonce='; then
  check "X7 a launch after the last change is not imported while its run has not completed" PASS
else
  check "X7 running (rc=$RC out=$OUT err=$(cat "$WORK/verb.err"))" FAIL
fi

write_run_record completed
OUT="$(verb $'src/a.js\n.zensu/state/x.json\n' --result "$RUN_OUTPUT")"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^EXTERNAL REVIEW — status=ok launches=1/1 selected=zensu-review-v1@[^ ]+ id=xr1_[0-9]{13}_[0-9a-f]{12} .* excluded=1 .* lenses=correctness tree=match runtime=journal agents=2/2 findings=1 dropped=0$' \
  && printf '%s' "$OUT" | grep -qE '^EXT-1 IMPORTANT "src/a\.js:1" lens=correctness id=correctness-1 verification=upheld confidence=90$' \
  && printf '%s' "$OUT" | tail -n 1 | grep -qE '^findings xr1_[0-9]{13}_[0-9a-f]{12} end nonce=[0-9a-f]{16}$' \
  && ! printf '%s' "$OUT" | grep -qE '^script '; then
  check "X7b the completed run's template result on the current tree is imported from its run record with every finding" PASS
else
  check "X7b ok (rc=$RC out=$OUT err=$(cat "$WORK/verb.err"))" FAIL
fi

FIRST_ID="$(ls "$VERB_DATA/external-review/v1/records/$ZENSU_SESSION_KEY" | sed -n 's/^\(xr1_[0-9]*_[0-9a-f]*\)\.json$/\1/p' | head -n 1)"
launch_payload "$VERB_RAW" | CLAUDE_PLUGIN_DATA="$VERB_DATA" bash "$HOOK" >/dev/null 2>&1
AMBIGUOUS="$(verb $'src/a.js\n')"
NAMED="$(verb $'src/a.js\n' --launch "$FIRST_ID")"
UNKNOWN="$(verb $'src/a.js\n' --launch xr1_0000000000000_000000000000)"
if [ -n "$FIRST_ID" ] && printf '%s' "$AMBIGUOUS" | grep -qE '^EXTERNAL REVIEW — status=unavailable reason=ambiguous-launch launches=2/2 ' \
  && printf '%s' "$NAMED" | grep -qE "^EXTERNAL REVIEW — status=ok launches=2/2 selected=zensu-review-v1@[^ ]+ id=$FIRST_ID " \
  && [ "$UNKNOWN" = "EXTERNAL REVIEW — status=unavailable reason=launch-not-fresh" ]; then
  check "X7c --launch selects one of several fresh launches and refuses a launch that is not fresh" PASS
else
  check "X7c launch selection (first=$FIRST_ID ambiguous=$AMBIGUOUS named=$NAMED unknown=$UNKNOWN)" FAIL
fi

sleep 1
printf 'three\n' > "$PROJ/src/a.js"
OUT="$(verb $'src/a.js\n')"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^EXTERNAL REVIEW — status=stale launches=0/2 ' \
  && ! printf '%s' "$OUT" | grep -qF ' begin nonce='; then
  check "X8 an edit after the launch answers stale and prints no finding" PASS
else
  check "X8 stale (rc=$RC out=$OUT)" FAIL
fi

OUT="$(printf 'src/a.js\n' | ZENSU_CONFIG="$OFF_CONFIG" bash "$LOG" --external-review --root "$PROJ" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'EXTERNAL REVIEW — status=off reason=disabled'; then
  check "X9 hooks.externalReviewImport=false answers off" PASS
else
  check "X9 off (rc=$RC out=$OUT)" FAIL
fi

JUDGE_OFF_CONFIG="$WORK/judge-off.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":5,"reviewJudge":false}}' > "$JUDGE_OFF_CONFIG"
OUT="$(printf 'src/a.js\n' | ZENSU_CONFIG="$JUDGE_OFF_CONFIG" bash "$LOG" --external-review --root "$PROJ" --launch "$FIRST_ID" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] \
  && printf '%s' "$OUT" | grep -qE '^EXTERNAL REVIEW — status=off reason=review-judge-disabled ' \
  && ! printf '%s' "$OUT" | grep -qE '^EXT-|begin nonce='; then
  check "X9b hooks.reviewJudge=false in the config answers off and imports nothing" PASS
else
  check "X9b judge off (rc=$RC out=$OUT)" FAIL
fi

TREE_OFF="$(ZENSU_CONFIG="$OFF_CONFIG" bash "$LOG" --external-review --tree --root "$PROJ" </dev/null 2>/dev/null)"
TREE_JUDGE_OFF="$(ZENSU_CONFIG="$JUDGE_OFF_CONFIG" bash "$LOG" --external-review --tree --root "$PROJ" </dev/null 2>/dev/null)"
if [ "$TREE_OFF" = "EXTERNAL REVIEW — tree=unavailable reason=disabled" ] \
  && [ "$TREE_JUDGE_OFF" = "EXTERNAL REVIEW — tree=unavailable reason=review-judge-disabled" ]; then
  check "X9c --tree answers tree=unavailable while the import or the judge is off, so no template is launched" PASS
else
  check "X9c tree off (off=$TREE_OFF judge-off=$TREE_JUDGE_OFF)" FAIL
fi

OUT="$(printf 'src/a.js\n' | bash "$LOG" --external-review 2>"$WORK/usage.err")"; RC=$?
OUT2="$(printf 'src/a.js\n' | bash "$LOG" --external-review --root "$PROJ" --bogus 2>/dev/null)"; RC2=$?
OUT3="$(bash "$LOG" --external-review --tree --root "$PROJ" --result "$RUN_OUTPUT" </dev/null 2>"$WORK/usage3.err")"; RC3=$?
OUT4="$(bash "$LOG" --external-review --tree --root "$PROJ" --launch "$FIRST_ID" </dev/null 2>"$WORK/usage4.err")"; RC4=$?
if [ "$RC" -eq 2 ] && grep -qF -- '--root <repository top level> is required' "$WORK/usage.err" && [ "$RC2" -eq 2 ] \
  && [ "$RC3" -eq 2 ] && grep -qF -- '--tree takes only --root' "$WORK/usage3.err" \
  && [ "$RC4" -eq 2 ] && grep -qF -- '--tree takes only --root' "$WORK/usage4.err"; then
  check "X10 a missing --root, an unknown argument and --tree with a result or a launch are usage errors (exit 2)" PASS
else
  check "X10 usage (rc=$RC rc2=$RC2 rc3=$RC3 rc4=$RC4)" FAIL
fi

OUT="$(printf 'src/a.js\n' | bash "$LOG" --external-review --root "$PROJ/src" 2>/dev/null)"; RC=$?
OUT2="$(printf '../escape.js\n' | bash "$LOG" --external-review --root "$PROJ" 2>/dev/null)"
if [ "$RC" -eq 0 ] && [ "$OUT" = "EXTERNAL REVIEW — status=unavailable reason=root" ] \
  && [ "$OUT2" = "EXTERNAL REVIEW — status=unavailable reason=unsafe-path" ]; then
  check "X11 a root that does not contain the project and an escaping path answer unavailable" PASS
else
  check "X11 unavailable (out=$OUT out2=$OUT2)" FAIL
fi

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).reason||"")}catch(_){}});'; }

stop_payload() {
  RAW="$1" TASKS="${2:-absent}" TRANSCRIPT="${3:-}" node -e '
    const payload = { hook_event_name: "Stop", session_id: process.env.RAW };
    if (process.env.TASKS !== "absent") payload.background_tasks = JSON.parse(process.env.TASKS);
    if (process.env.TRANSCRIPT) payload.transcript_path = process.env.TRANSCRIPT;
    process.stdout.write(JSON.stringify(payload));
  '
}

WORKFLOW_TASKS='[{"id":"t1","type":"workflow","status":"running","description":"review","name":"review-changes"}]'
SHELL_TASKS='[{"id":"t2","type":"shell","status":"running","description":"tail","command":"tail -f x"}]'

arm() {
  local raw="$1"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/stop-data/$raw"
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$raw" || return 1
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  ARMED_KEY="$ZENSU_SESSION_KEY"
  ARMED_DATA="$CLAUDE_PLUGIN_DATA"
}

stop_count() {
  bash -c 'source "$1"; tdd_get_counter "$(tdd_state_file "$2")" stopBlockCount' _ "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" "$1" 2>/dev/null
}

STOP_PROJECT="$WORK/stop-project"
mkdir -p "$STOP_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$STOP_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1

arm stop-control || { check "X12 arm" FAIL; finish; exit 1; }
CONTROL_OUT="$(stop_payload stop-control | bash "$STOP" 2>/dev/null)"
CONTROL_REASON="$(printf '%s' "$CONTROL_OUT" | reason)"
if [ "$(printf '%s' "$CONTROL_OUT" | decision)" = "block" ] \
  && printf '%s' "$CONTROL_REASON" | grep -qF "fan out the review panel's zensu:review-aspect agents" \
  && printf '%s' "$CONTROL_REASON" | grep -qF -- '--external-review'; then
  check "X12 control: an armed chain without background work blocks and names the panel and the import path" PASS
else
  check "X12 control (out=$CONTROL_OUT)" FAIL
fi

arm stop-wait || { check "X13 arm" FAIL; finish; exit 1; }
WAIT_KEY="$ARMED_KEY"
BEFORE="$(stop_count "$WAIT_KEY")"
OUT="$(stop_payload stop-wait "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/wait.err")"; RC=$?
AFTER="$(stop_count "$WAIT_KEY")"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && grep -qF 'releasing this Stop while 1 background workflow(s) run (review-changes); wait 1 of 3' "$WORK/wait.err" \
  && case "$BEFORE" in ''|*[!0-9]*) false ;; *) true ;; esac && [ "$BEFORE" = "$AFTER" ]; then
  check "X13 a workflow in flight releases the Stop, names it, and charges no inner Stop budget" PASS
else
  check "X13 wait (rc=$RC out=$OUT before=$BEFORE after=$AFTER err=$(cat "$WORK/wait.err"))" FAIL
fi

DECISIONS=""
for _ in 2 3 4; do
  OUT="$(stop_payload stop-wait "$WORKFLOW_TASKS" | bash "$STOP" 2>/dev/null)"
  DECISIONS="$DECISIONS $(printf '%s' "$OUT" | decision)"
done
OUT="$(stop_payload stop-wait "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/wait5.err")"
DECISIONS="$DECISIONS $(printf '%s' "$OUT" | decision)"
OUT="$(stop_payload stop-wait | bash "$STOP" 2>/dev/null)"
RESET_DECISION="$(printf '%s' "$OUT" | decision)"
OUT="$(stop_payload stop-wait "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/wait7.err")"
AGAIN_DECISION="$(printf '%s' "$OUT" | decision)"
if [ "$DECISIONS" = " allow allow block block" ] && ! grep -qF 'releasing this Stop while' "$WORK/wait5.err" \
  && [ "$RESET_DECISION" = "block" ] && [ "$AGAIN_DECISION" = "allow" ] && grep -qF 'wait 1 of 3' "$WORK/wait7.err" \
  && [ "$(stop_count "$WAIT_KEY")" = "$((AFTER + 3))" ]; then
  check "X14 at most three waits; the limit holds every later Stop until one sees no workflow, which resets it" PASS
else
  check "X14 bounded waits (decisions=$DECISIONS reset=$RESET_DECISION again=$AGAIN_DECISION count=$(stop_count "$WAIT_KEY"))" FAIL
fi

WAIT_FILE="$ARMED_DATA/external-review/v1/waits/$WAIT_KEY.json"
WAIT_PRESENT=false
[ -f "$WAIT_FILE" ] && WAIT_PRESENT=true
bash "$LOG" --tdd-begin --session "$WAIT_KEY" >/dev/null 2>&1; BEGIN_RC=$?
if [ "$WAIT_PRESENT" = true ] && [ "$BEGIN_RC" -eq 0 ] && [ ! -e "$WAIT_FILE" ] && [ ! -L "$WAIT_FILE" ]; then
  check "X25 arming a new chain generation deletes the session's wait counter" PASS
else
  check "X25 generation reset (present=$WAIT_PRESENT rc=$BEGIN_RC left=$(ls "$(dirname "$WAIT_FILE")" 2>/dev/null))" FAIL
fi

DIFF_OK=true
for tasks in absent '[]' "$SHELL_TASKS" '"workflow"' '[{"type":"workflow","status":"completed","name":"old"}]'; do
  arm "stop-diff-$RANDOM" || DIFF_OK=false
  RAW_NOW="$(basename "$ZENSU_TEST_PLUGIN_DATA")"
  OUT="$(stop_payload "$RAW_NOW" "$tasks" | bash "$STOP" 2>"$WORK/diff.err")"
  if [ "$(printf '%s' "$OUT" | decision)" != "block" ] || grep -qF 'releasing this Stop while' "$WORK/diff.err"; then DIFF_OK=false; fi
  if [ "$(printf '%s' "$OUT" | reason | sed "s#$ARMED_DATA#DATA#g")" != "$(printf '%s' "$CONTROL_REASON" | sed "s#$WORK/stop-data/stop-control#DATA#g")" ]; then DIFF_OK=false; fi
done
if [ "$DIFF_OK" = "true" ]; then
  check "X15 an absent, empty, non-workflow, malformed or finished background field renders exactly the control block" PASS
else
  check "X15 differential render" FAIL
fi

arm stop-flag-off || { check "X16 arm" FAIL; finish; exit 1; }
OUT="$(stop_payload stop-flag-off "$WORKFLOW_TASKS" | ZENSU_CONFIG="$OFF_CONFIG" bash "$STOP" 2>"$WORK/off.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && ! grep -qF 'releasing this Stop while' "$WORK/off.err"; then
  check "X16 hooks.externalReviewImport=false keeps blocking while a workflow runs" PASS
else
  check "X16 flag off (out=$OUT)" FAIL
fi

arm stop-converged || { check "X17 arm" FAIL; finish; exit 1; }
bash "$LOG" --code-review-done --session "$ARMED_KEY" >/dev/null 2>&1
OUT="$(stop_payload stop-converged "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/conv.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && printf '%s' "$OUT" | reason | grep -qF "skill='zensu:self-review'" \
  && ! grep -qF 'releasing this Stop while' "$WORK/conv.err"; then
  check "X17 a converged chain keeps its self-review directive while a workflow runs" PASS
else
  check "X17 converged (out=$OUT)" FAIL
fi

DENIED_TRANSCRIPT="$WORK/denied.jsonl"
cat >"$DENIED_TRANSCRIPT" <<'DENIED_EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"zensu:code-reviewer","prompt":"PRE-MERGED FINDINGS (fan-out)"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier."}]}}
DENIED_EOF
arm stop-denied || { check "X18 arm" FAIL; finish; exit 1; }
OUT="$(stop_payload stop-denied "$WORKFLOW_TASKS" "$DENIED_TRANSCRIPT" | bash "$STOP" 2>"$WORK/denied.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && ! grep -qF 'releasing this Stop while' "$WORK/denied.err"; then
  check "X18 a refused reviewer spawn keeps its block while a workflow runs" PASS
else
  check "X18 refused spawn (out=$OUT)" FAIL
fi

export ZENSU_TEST_PLUGIN_DATA="$WORK/stop-data/stop-implementing"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" stop-implementing || { check "X19 baseline" FAIL; finish; exit 1; }
bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1
OUT="$(stop_payload stop-implementing "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/impl.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "allow" ] && ! grep -qF 'releasing this Stop while' "$WORK/impl.err"; then
  check "X19 a chain still implementing is released by its own path, not by the wait" PASS
else
  check "X19 implementing (out=$OUT)" FAIL
fi

arm stop-fix-round || { check "X20 arm" FAIL; finish; exit 1; }
node -e '
  const fs = require("fs");
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  s.reviewRound = 1;
  fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
' "$CLAUDE_PROJECT_DIR/.zensu/state/tdd-phase-$ARMED_KEY.json"
OUT="$(stop_payload stop-fix-round "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/fix.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && ! grep -qF 'releasing this Stop while' "$WORK/fix.err"; then
  check "X20 a fix round keeps its block while a workflow runs; only the first review waits" PASS
else
  check "X20 fix round (out=$OUT err=$(cat "$WORK/fix.err"))" FAIL
fi

OUTER_PROJECT="$WORK/outer-project"
mkdir -p "$OUTER_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$OUTER_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
arm stop-outer || { check "X21 arm" FAIL; finish; exit 1; }
bash -c 'source "$1"; autopilot_begin_run run-xr-outer "$2" "$3"' _ "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh" "$ARMED_KEY" "$CLAUDE_PROJECT_DIR" >/dev/null 2>&1 || { check "X21 the Autopilot run fixture begins" FAIL; finish; exit 1; }
OUT="$(stop_payload stop-outer "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/outer.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && ! grep -qF 'releasing this Stop while' "$WORK/outer.err" \
  && [ ! -e "$ARMED_DATA/external-review/v1/waits/$ARMED_KEY.json" ]; then
  check "X21 a session that owns a live Autopilot run neither waits nor spends a wait" PASS
else
  check "X21 own Autopilot run (out=$OUT err=$(cat "$WORK/outer.err"))" FAIL
fi

ADOPT_PROJECT="$WORK/adopt-project"
mkdir -p "$ADOPT_PROJECT"
export CLAUDE_PROJECT_DIR="$(cd -P "$ADOPT_PROJECT" && pwd -P)"
cd "$CLAUDE_PROJECT_DIR" || exit 1
export ZENSU_TEST_PLUGIN_DATA="$WORK/stop-data/stop-adopt"
source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" stop-adopt || { check "X22 baseline" FAIL; finish; exit 1; }
bash "$LOG" --pending-review --files "src/x.ts" --summary "queued work" >/dev/null 2>&1
OUT="$(stop_payload stop-adopt "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/adopt.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && printf '%s' "$OUT" | reason | grep -qF 'zensu:code-reviewer' \
  && ! grep -qF 'releasing this Stop while' "$WORK/adopt.err" && [ -e "$CLAUDE_PROJECT_DIR/.zensu/state/pending-review.json.claim" ]; then
  check "X22 a Stop that adopts a deferred review blocks with its handoff while a workflow runs" PASS
else
  check "X22 adopting Stop (out=$OUT err=$(cat "$WORK/adopt.err"))" FAIL
fi
OUT="$(stop_payload stop-adopt "$WORKFLOW_TASKS" | bash "$STOP" 2>"$WORK/adopt2.err")"
if [ "$(printf '%s' "$OUT" | decision)" = "block" ] && ! grep -qF 'releasing this Stop while' "$WORK/adopt2.err"; then
  check "X23 a chain that holds a deferred-review claim never waits on a later Stop" PASS
else
  check "X23 claimed chain (out=$OUT err=$(cat "$WORK/adopt2.err"))" FAIL
fi

WAIT_FN="$(sed -n '/^external_review_workflow_wait() {/,/^}/p' "$STOP")"
probe_wait() {
  BOUND="$1" MARK="$2" ADOPTED="${3:-false}" WAIT_FN="$WAIT_FN" PLUGIN_DIR="$PLUGIN_DIR" PROBE_DATA="$WORK/probe-data" bash -c '
    eval "$WAIT_FN"
    INPUT="{\"background_tasks\":[{\"type\":\"workflow\",\"status\":\"running\",\"name\":\"review-changes\"}]}"
    OUTER_PRESENT=false
    DEFERRED_ADOPTED="$ADOPTED"
    INNER_BOUND_RUN="$BOUND"
    SESSION_ID="scv1_0000000000000000000000000000000000000000000000000000000000000000"
    STATE_FILE=/dev/null
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
    CLAUDE_PLUGIN_DATA="$PROBE_DATA"
    zensu_external_review_wait_reset() { return 0; }
    zensu_session_key_canonical() { return 0; }
    zensu_hook_enabled() { return 0; }
    reviewer_spawn_denied() { return 1; }
    zensu_pending_review_file() { printf "%s\n" "$PROBE_DATA/pending-review.json"; }
    zensu_pending_review_claim_file() { printf "%s\n" "$1.claim"; }
    tdd_get_counter() { printf "0\n"; }
    zensu_msys_env_exclusions() { printf "\n"; }
    zensu_run_bounded() { : >"$MARK"; printf "wait count=1 max=3 workflows=1 names=review-changes\n"; }
    if external_review_workflow_wait; then printf "released\n"; else printf "kept\n"; fi
  '
}
mkdir -p "$WORK/probe-data"
UNBOUND_PROBE="$(probe_wait "" "$WORK/probe-unbound.mark" 2>"$WORK/probe-unbound.err")"
BOUND_PROBE="$(probe_wait "run-xr-bound" "$WORK/probe-bound.mark" 2>"$WORK/probe-bound.err")"
ADOPTED_PROBE="$(probe_wait "" "$WORK/probe-adopted.mark" true 2>"$WORK/probe-adopted.err")"
if [ -n "$WAIT_FN" ] && [ "$UNBOUND_PROBE" = "released" ] && [ -e "$WORK/probe-unbound.mark" ] \
  && [ "$BOUND_PROBE" = "kept" ] && [ ! -e "$WORK/probe-bound.mark" ] \
  && [ "$ADOPTED_PROBE" = "kept" ] && [ ! -e "$WORK/probe-adopted.mark" ] && [ ! -e "$WORK/probe-data/pending-review.json.claim" ]; then
  check "X24 the shipped wait function refuses an Autopilot-bound chain and a Stop that adopted a deferred review before it consults the wait counter" PASS
else
  check "X24 bound or adopting chain (unbound=$UNBOUND_PROBE bound=$BOUND_PROBE adopted=$ADOPTED_PROBE err=$(cat "$WORK/probe-bound.err" "$WORK/probe-unbound.err" "$WORK/probe-adopted.err"))" FAIL
fi

unit_check_done "X0z every unit file the registry gives this suite was graded"
finish
