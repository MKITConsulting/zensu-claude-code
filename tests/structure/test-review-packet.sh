#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/review-packet-v1.js"
GATE_LIB="$ROOT/hooks/lib/review-gate-v1.js"
UNIT="$ROOT/tests/structure/review-packet-v1.test.js"
GATE_UNIT="$ROOT/tests/structure/review-gate-v1.test.js"
LOG="$ROOT/hooks/lib/zensu-log.sh"
AUDIT="$ROOT/hooks/lib/zensu-edit-landing.sh"
TDD_LIB="$ROOT/hooks/lib/zensu-tdd-phase.sh"
POSTREV="$ROOT/hooks/post-review-tdd-delegate.sh"
. "$(dirname "$0")/lib-unit-registry.sh"
source "$ROOT/tests/structure/lib-skill-text.sh"
TDD_MD="$(skill_text_file "$ROOT/skills/build")"
SELF_REVIEW="$ROOT/skills/self-review/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

for f in "$LIB" "$GATE_LIB" "$UNIT" "$GATE_UNIT" "$LOG" "$AUDIT" "$TDD_LIB" "$POSTREV" "$TDD_MD" "$SELF_REVIEW"; do
  [ -f "$f" ]
  check "RP0 required file exists: ${f#"$ROOT"/}" "$(verdict $?)"
done

echo "== The canonical change-set and packet helper =="
node --check "$LIB" >/dev/null 2>&1
check "RP1 hooks/lib/review-packet-v1.js parses" "$(verdict $?)"
unit_check "RP2 the review-packet unit file passes" "$UNIT"
node --check "$GATE_LIB" >/dev/null 2>&1
check "RP3 hooks/lib/review-gate-v1.js parses" "$(verdict $?)"
unit_check "RP4 the review-gate unit file passes" "$GATE_UNIT"

echo "== The packet and the consume gate through the shipped hook =="
WORK="$(mktemp -d 2>/dev/null)" || { check "RP5 scratch directory" FAIL; WORK=""; }
if [ -n "$WORK" ]; then
  trap 'rm -rf "$WORK"' EXIT
  WORK="$(cd -P "$WORK" && pwd -P)"
  export CLAUDE_PLUGIN_ROOT="$ROOT"
  export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
  export ZENSU_CONFIG="$WORK/config.json"
  printf '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
  GATE_OFF_CONFIG="$WORK/config-gate-off.json"
  printf '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"advisory"},"hooks":{"reviewPacketGate":false}}\n' > "$GATE_OFF_CONFIG"
  unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_EDIT_LANDING_GATE 2>/dev/null || true
  source "$TDD_LIB"

  new_project() {
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email t@example.invalid
    git -C "$1" config user.name tester
    printf '.zensu/\n.session-control-test/\n' > "$1/.gitignore"
    printf 'v1\n' > "$1/tracked.txt"
    git -C "$1" add .gitignore tracked.txt
    git -C "$1" -c commit.gpgsign=false commit -qm baseline
  }
  arm_review() {
    SID="$1"; PROJECT="$2"
    export CLAUDE_PROJECT_DIR="$PROJECT"
    cd "$PROJECT" || return 1
    source "$ROOT/tests/session-control/initialize-baseline.sh" "$SID" || return 1
    SF="$(tdd_state_file "$SID")" || return 1
    mkdir -p "$PROJECT/.zensu/logs" "$PROJECT/.zensu/reviews"
    RUN_LOG="$PROJECT/.zensu/logs/2026-10-20-0000_build-$SID.log"
    bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
    bash "$LOG" --tdd-complete >/dev/null 2>&1 || return 1
    printf 'v2\n' > "$PROJECT/tracked.txt"
    printf 'S1 IMPL completed — files: tracked.txt\n' >> "$RUN_LOG"
    bash "$AUDIT" --log "$RUN_LOG" --project "$PROJECT" --session "$SID" >/dev/null 2>&1 || return 1
    INPUT_JSON="$PROJECT/.zensu/reviews/packet-input-round-1.json"
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({
      implementation_summary: "Changes tracked.txt to v2.", requirements_baseline: "none",
      diff_summary: "tracked.txt: v1 -> v2", test_evidence: "not run — fixture", build_evidence: "not run — fixture",
      coverage_evidence: "not run — fixture", edit_landing_evidence: "EDIT LANDING AUDIT — claims=1 landed=1" }))' "$INPUT_JSON"
  }
  agent_payload() {
    TYPE="$1" PROMPT="$2" REPORT="$3" SID_VALUE="$SID" node -e '
      process.stdout.write(JSON.stringify({ hook_event_name: "PostToolUse", tool_name: "Agent", session_id: process.env.SID_VALUE,
        tool_input: { subagent_type: process.env.TYPE, prompt: process.env.PROMPT, run_in_background: false },
        tool_response: { status: "completed", content: [{ type: "text", text: process.env.REPORT }] } }));'
  }
  state_field() {
    FIELD="$1" node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(s[process.env.FIELD]))' "$SF"
  }
  store_records() {
    find "$PROJECT/.zensu/state" -path "*review-gate-*" -name 'record-r*.json' 2>/dev/null | wc -l | tr -d ' '
  }
  launch_payload() {
    TYPE="$1" PROMPT="$2" AGENT="$3" SID_VALUE="$SID" node -e '
      process.stdout.write(JSON.stringify({ hook_event_name: "PostToolUse", tool_name: "Agent", session_id: process.env.SID_VALUE,
        tool_input: { subagent_type: process.env.TYPE, prompt: process.env.PROMPT },
        tool_response: { status: "async_launched", isAsync: true, agentId: process.env.AGENT } }));'
  }
  handback_payload() {
    AGENT="$1" REPORT="$2" SID_VALUE="$SID" node -e '
      const body = process.env.REPORT.split("\n").map((line) => `  ${line}`);
      const prompt = [`<agent-message from="${process.env.AGENT}">`,
        "[Subagent hand-back] The text below is the final report of a subagent this session delegated to. The report follows:",
        ...body, "</agent-message>"].join("\n");
      process.stdout.write(JSON.stringify({ hook_event_name: "UserPromptSubmit", session_id: process.env.SID_VALUE, prompt }));'
  }
  notification_payload() {
    AGENT="$1" STATUS="$2" SID_VALUE="$SID" node -e '
      const prompt = ["<task-notification>", `<task-id>${process.env.AGENT}</task-id>`, "<tool-use-id>toolu_01WPhqY4dh2LFbaugtAn6Kg8</tool-use-id>",
        `<status>${process.env.STATUS}</status>`, "<summary>Agent consume review finished</summary>", "</task-notification>"].join("\n");
      process.stdout.write(JSON.stringify({ hook_event_name: "UserPromptSubmit", session_id: process.env.SID_VALUE, prompt }));'
  }
  hook_event_of() {
    node -e 'let s = ""; process.stdin.on("data", (c) => s += c); process.stdin.on("end", () => {
      try { process.stdout.write(JSON.parse(s).hookSpecificOutput.hookEventName); } catch (_) { process.stdout.write("none"); } });' < "$1"
  }
  consume_record() {
    if [ -f "$CLAUDE_PLUGIN_DATA/background-review/v1/records/$ZENSU_SESSION_KEY.json" ]; then echo present; else echo absent; fi
  }

  bash "$AUDIT" --log /dev/null --allow-unclean >"$WORK/out" 2>&1; RC=$?
  if [ "$RC" -eq 2 ] && grep -qF -- "--allow-unclean applies only to --check-receipt" "$WORK/out"; then
    check "RP5 --allow-unclean is refused outside --check-receipt" PASS
  else
    check "RP5 --allow-unclean outside --check-receipt (rc=$RC)" FAIL
  fi

  new_project "$WORK/p-unclean"
  if arm_review "rp-unclean" "$WORK/p-unclean"; then
    printf 'S2 IMPL completed — files: never-written.txt\n' >> "$RUN_LOG"
    bash "$AUDIT" --log "$RUN_LOG" --project "$PROJECT" --session "$SID" >/dev/null 2>&1
    bash "$AUDIT" --check-receipt --allow-unclean --project "$PROJECT" --session "$SID" >"$WORK/out" 2>&1; RC_ALLOW=$?
    bash "$AUDIT" --check-receipt --project "$PROJECT" --session "$SID" >"$WORK/out2" 2>&1; RC_STRICT=$?
    if [ "$RC_ALLOW" -eq 0 ] && grep -qF "EDIT LANDING RECEIPT CURRENT — " "$WORK/out" && grep -qF "it records clean=false." "$WORK/out" \
      && [ "$RC_STRICT" -eq 1 ] && grep -qF "the receipt is not clean" "$WORK/out2"; then
      check "RP6 a current nonclean receipt passes --check-receipt --allow-unclean and still refuses without it" PASS
    else
      check "RP6 nonclean receipt check (allow=$RC_ALLOW strict=$RC_STRICT)" FAIL
      cat "$WORK/out" "$WORK/out2"
    fi
    printf 'v3\n' > "$PROJECT/tracked.txt"
    bash "$AUDIT" --check-receipt --allow-unclean --project "$PROJECT" --session "$SID" >"$WORK/out" 2>&1; RC=$?
    if [ "$RC" -eq 1 ] && grep -qF "EDIT LANDING RECEIPT STALE — " "$WORK/out"; then
      check "RP7 a tree change after the receipt is stale with --allow-unclean too" PASS
    else
      check "RP7 stale receipt with --allow-unclean (rc=$RC)" FAIL
      cat "$WORK/out"
    fi
  else
    check "RP6 arm a review chain with a nonclean receipt" FAIL
  fi

  new_project "$WORK/p-gate"
  if arm_review "rp-gate" "$WORK/p-gate"; then
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"; RC=$?
    PACKET="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created")"
    if [ "$RC" -eq 0 ] && head -n 1 "$WORK/created" | grep -q '^REVIEW PACKET CREATED — round=0 sha256=[0-9a-f]\{64\} files=1 ' \
      && printf '%s\n' "$PACKET" | grep -qx -- '- tracked.txt' \
      && printf '%s\n' "$PACKET" | grep -q '^edit_landing_receipt: schema=edit-landing-v[0-9] clean=true claims=1 landed=1 '; then
      check "RP8 create checks the real receipt and prints the round's canonical packet for a bound chain" PASS
    else
      check "RP8 create through the real receipt check (rc=$RC)" FAIL
      cat "$WORK/created" "$WORK/created.err"
    fi
    if [ "$RC" -eq 0 ] && [ ! -e "$INPUT_JSON" ]; then
      check "RP8a create removes its input from .zensu/reviews once it has read it" PASS
    else
      check "RP8a consumed input removal (rc=$RC)" FAIL
    fi
    WRITTEN="$(find "$PROJECT/.zensu/state" -maxdepth 1 -name 'edit-landing-*.json' ! -name '*.tmp.*' 2>/dev/null)"
    SHELL_RECEIPT="$(tdd_edit_landing_receipt "$SID" 2>/dev/null)"
    JS_RECEIPT="$(node -e 'const r = require(process.argv[1]); const c = require(process.argv[2]);
      process.stdout.write(r.receiptFile(process.argv[3], c.sessionKey(process.argv[4])))' \
      "$ROOT/hooks/lib/edit-landing-receipt-v1.js" "$ROOT/hooks/lib/session-control-core-v1.js" "$PROJECT" "$SID" 2>/dev/null)"
    PACKET_RECEIPT="$(node -e 'process.stdout.write(require(process.argv[1]).receiptPath(process.argv[2], process.argv[3]))' "$LIB" "$PROJECT" "$SID" 2>/dev/null)"
    if [ -n "$WRITTEN" ] && [ "$(printf '%s\n' "$WRITTEN" | wc -l | tr -d ' ')" = "1" ] && [ "$WRITTEN" = "$SHELL_RECEIPT" ] \
      && [ "$WRITTEN" = "$JS_RECEIPT" ] && [ "$WRITTEN" = "$PACKET_RECEIPT" ]; then
      check "RP19 the audit writes the receipt where tdd_edit_landing_receipt, receiptFile and the packet's receiptPath name it" PASS
    else
      check "RP19 receipt path spellings (written='$WRITTEN' shell='$SHELL_RECEIPT' js='$JS_RECEIPT' packet='$PACKET_RECEIPT')" FAIL
    fi
    agent_payload zensu:review-aspect "perspective: correctness
$PACKET" "## Aspect: correctness
- (no findings)" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && [ ! -s "$WORK/hook" ] && [ "$(store_records)" = "1" ]; then
      check "RP9 the hook records an aspect run on the canonical packet and stays silent" PASS
    else
      check "RP9 aspect record (rc=$RC records=$(store_records))" FAIL
      cat "$WORK/hook"
    fi
    agent_payload zensu:review-aspect "perspective: design
$(printf '%s\n' "$PACKET" | sed 's/^policy: reviewer-readonly-v1$/policy: reviewer-readonly/')" "## Aspect: design
- (no findings)" | bash "$POSTREV" >"$WORK/hook" 2>&1
    if grep -qF "REVIEW PACKET MISMATCH — the zensu:review-aspect reviewer" "$WORK/hook" && grep -qF 'at packet line 2.' "$WORK/hook"; then
      check "RP9a an aspect run on an edited packet gets the mismatch advice" PASS
    else
      check "RP9a mismatch advice" FAIL
      cat "$WORK/hook"
    fi
    agent_payload zensu:review-aspect "perspective: design
$PACKET" "## Aspect: design
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    CONSUME="PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none"
    agent_payload zensu:code-reviewer "$CONSUME" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && grep -qF "REVIEW INCOMPLETE — no primary zensu:review-judge run completed a substantive report on review round 0's canonical packet" "$WORK/hook" \
      && grep -qF "The review ticket was NOT consumed" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP10 a consume completion without a primary judge keeps the ticket and the round unchanged" PASS
    else
      check "RP10 consume without judge (rc=$RC consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
    agent_payload zensu:review-judge "$PACKET
merged_panel_findings: none
judge_run: second" "## Aspect: judge (second run)
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    agent_payload zensu:code-reviewer "$CONSUME" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1
    if grep -qF "no primary zensu:review-judge run completed" "$WORK/hook" && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP10a the second judge run does not stand in for the primary" PASS
    else
      check "RP10a second run substitution (round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
    agent_payload zensu:review-judge "$PACKET
merged_panel_findings: none" "## Aspect: judge
- (no findings)" | bash "$POSTREV" >"$WORK/hook" 2>&1
    agent_payload zensu:code-reviewer "$CONSUME" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ]; then
      check "RP11 the canonical packet and a substantive primary judge let the consume completion claim the ticket" PASS
    else
      check "RP11 consume with judge (rc=$RC consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
    REARM_STORE="$(find "$PROJECT/.zensu/state" -maxdepth 1 -type d -name 'review-gate-*' | head -n 1)"
    bash "$LOG" --code-review-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1
    bash "$LOG" --review-rearm --claimed-review-ticket "$TICKET" >"$WORK/rearm" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && [ -n "$REARM_STORE" ] && [ ! -e "$REARM_STORE" ] && [ "$(state_field reviewRound)" = "0" ] \
      && [ "$(state_field codeReviewDone)" = "false" ] && ! grep -qF "REVIEW GATE RESET UNAVAILABLE" "$WORK/rearm"; then
      check "RP23 --review-rearm restarts the review at round 0 and removes the earlier rounds' packets and reviewer records" PASS
    else
      check "RP23 store reset at --review-rearm (rc=$RC store='$REARM_STORE' round=$(state_field reviewRound))" FAIL
      cat "$WORK/rearm"
    fi
    printf 'v3\n' > "$PROJECT/tracked.txt"
    printf 'S2 IMPL completed — files: tracked.txt\n' >> "$RUN_LOG"
    bash "$AUDIT" --log "$RUN_LOG" --project "$PROJECT" --session "$SID" >/dev/null 2>&1
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({
      implementation_summary: "Changes tracked.txt to v3 after a review rearm.", requirements_baseline: "none",
      diff_summary: "tracked.txt: v1 -> v3", test_evidence: "not run — fixture", build_evidence: "not run — fixture",
      coverage_evidence: "not run — fixture", edit_landing_evidence: "EDIT LANDING AUDIT — claims=2 landed=2" }))' "$INPUT_JSON"
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created2" 2>"$WORK/created2.err"
    PACKET2="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created2")"
    agent_payload zensu:review-judge "$PACKET2
merged_panel_findings: none" "## Aspect: judge
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    TICKET2="$(bash "$LOG" --review-ticket 2>/dev/null)"
    agent_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET2
$PACKET2
merged findings: none" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && [ -n "$PACKET2" ] && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ]; then
      check "RP23a after a rearm the restarted round is judged on its own packet and reviewer records alone" PASS
    else
      check "RP23a consume after a rearm (rc=$RC consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/created2" "$WORK/created2.err" "$WORK/hook"
    fi
    STORE_DIR="$(find "$PROJECT/.zensu/state" -maxdepth 1 -type d -name 'review-gate-*' | head -n 1)"
    bash "$LOG" --tdd-begin >/dev/null 2>&1
    if [ -n "$STORE_DIR" ] && [ ! -e "$STORE_DIR" ]; then
      check "RP13 --tdd-begin removes the previous generation's packets and reviewer records" PASS
    else
      check "RP13 store reset at --tdd-begin (store='$STORE_DIR')" FAIL
    fi
  else
    check "RP8 arm a review chain with a clean receipt" FAIL
  fi

  new_project "$WORK/p-off"
  if arm_review "rp-off" "$WORK/p-off"; then
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    agent_payload zensu:review-aspect "perspective: correctness" "## Aspect: correctness
- (no findings)" | ZENSU_CONFIG="$GATE_OFF_CONFIG" bash "$POSTREV" >"$WORK/hook" 2>&1
    REC_OFF="$(store_records)"
    agent_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
REVIEW PACKET v1
END REVIEW PACKET v1" "- Verdict: PASS" | ZENSU_CONFIG="$GATE_OFF_CONFIG" bash "$POSTREV" >"$WORK/hook" 2>&1
    if [ "$REC_OFF" = "0" ] && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" && [ "$(state_field reviewRound)" = "1" ]; then
      check "RP12 hooks.reviewPacketGate false records nothing and consumes as before" PASS
    else
      check "RP12 gate off (records=$REC_OFF round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
  else
    check "RP12 arm a review chain" FAIL
  fi

  new_project "$WORK/p-plain"
  if arm_review "rp-plain" "$WORK/p-plain"; then
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    agent_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
fixture" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1
    if ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" && [ "$(state_field reviewRound)" = "1" ] && [ "$(store_records)" = "0" ]; then
      check "RP14 a generation with no packet, no reviewer record and no packet block consumes as before" PASS
    else
      check "RP14 unengaged consume (round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
  else
    check "RP14 arm a review chain" FAIL
  fi

  new_project "$WORK/p-repro"
  if arm_review "rp-repro" "$WORK/p-repro"; then
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"
    PACKET="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created")"
    agent_payload zensu:review-aspect "perspective: correctness
$PACKET" "## Aspect: correctness
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    agent_payload zensu:review-judge "$PACKET
merged_panel_findings: none" "## Aspect: judge
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    printf 'reproduction\n' > "$PROJECT/repro.test.js"
    agent_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1
    if grep -qF "REVIEW INCOMPLETE — the change set changed since review round 0's packet was created" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
      check "RP21 a reproduction test written into the project between create and consume refuses the round, which is why step 4c writes it outside the tree" PASS
    else
      check "RP21 file written between create and consume (consumed=$(state_field reviewTicketConsumed))" FAIL
      cat "$WORK/hook"
    fi
    rm -f "$PROJECT/repro.test.js"
    agent_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: rt_stale_completion
$PACKET
merged findings: none" "REVIEW PACKET INVALID: policy" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP22 a completion that carries a stale ticket is a silent no-op, never a refusal of the live round" PASS
    else
      check "RP22 stale-ticket completion (rc=$RC consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
    agent_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1
    if ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" && [ "$(state_field reviewRound)" = "1" ]; then
      check "RP22a the live ticket is still claimed after the stale completion" PASS
    else
      check "RP22a live ticket after a stale completion (round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
  else
    check "RP21 arm a review chain" FAIL
  fi

  echo "== Background reviewers through the launch and the hand-back =="
  HANDBACK_HOOK="$ROOT/hooks/user-prompt-review-handback.sh"
  new_project "$WORK/p-background"
  if arm_review "rp-background" "$WORK/p-background"; then
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"
    PACKET="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created")"
    launch_payload zensu:review-aspect "perspective: correctness
$PACKET" aspectbg1 | bash "$POSTREV" >"$WORK/hook-aspect" 2>&1
    launch_payload zensu:review-judge "$PACKET
merged_panel_findings: none" judgebg1 | bash "$POSTREV" >"$WORK/hook-judge" 2>&1
    if [ ! -s "$WORK/hook-aspect" ] && [ ! -s "$WORK/hook-judge" ] && [ "$(store_records)" = "2" ]; then
      check "RP24 a background aspect or judge launch is recorded silently and never reads as a failed judge" PASS
    else
      check "RP24 background reviewer launches (records=$(store_records))" FAIL
      cat "$WORK/hook-aspect" "$WORK/hook-judge"
    fi
    handback_payload aspectbg1 "## Aspect: correctness
- (no findings)" | bash "$HANDBACK_HOOK" >"$WORK/hook-aspect" 2>&1
    handback_payload judgebg1 "## Aspect: judge
- (no findings)" | bash "$HANDBACK_HOOK" >"$WORK/hook-judge" 2>&1
    if [ ! -s "$WORK/hook-aspect" ] && [ ! -s "$WORK/hook-judge" ] && [ "$(store_records)" = "4" ]; then
      check "RP24a the hand-backs of the background aspect and judge are recorded through the hand-back hook" PASS
    else
      check "RP24a background reviewer hand-backs (records=$(store_records))" FAIL
      cat "$WORK/hook-aspect" "$WORK/hook-judge"
    fi
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    launch_payload zensu:code-reviewer "PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
merged findings: none" consumebg0 | bash "$POSTREV" >"$WORK/hook" 2>&1
    if [ "$(hook_event_of "$WORK/hook")" = PostToolUse ] \
      && grep -qF "REVIEW INCOMPLETE — the consume prompt carries no REVIEW PACKET v1 block" "$WORK/hook" \
      && grep -qF "spawn zensu:code-reviewer again with the same two header lines" "$WORK/hook" \
      && [ "$(consume_record)" = absent ] && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
      check "RP25 a background consume launch without the canonical packet is refused at its launch and records no launch" PASS
    else
      check "RP25 refused background consume launch (record=$(consume_record) consumed=$(state_field reviewTicketConsumed))" FAIL
      cat "$WORK/hook"
    fi
    CONSUME="PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none"
    launch_payload zensu:code-reviewer "$CONSUME" consumebg1 | bash "$POSTREV" >"$WORK/hook" 2>&1
    if grep -qF "returned status async_launched" "$WORK/hook" && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" \
      && [ "$(consume_record)" = present ] && [ "$(state_field reviewTicketConsumed)" = "false" ]; then
      check "RP25a a background consume launch on the canonical packet passes the gate and is recorded for its arrival" PASS
    else
      check "RP25a background consume launch (record=$(consume_record))" FAIL
      cat "$WORK/hook"
    fi
    printf 'v3\n' > "$PROJECT/tracked.txt"
    handback_payload consumebg1 "# Code Review Report

- Verdict: PASS" | bash "$HANDBACK_HOOK" >"$WORK/hook" 2>&1
    if [ "$(hook_event_of "$WORK/hook")" = UserPromptSubmit ] \
      && grep -qF "REVIEW INCOMPLETE — the working tree changed since review round 0's packet was created" "$WORK/hook" \
      && grep -qF "spawn zensu:code-reviewer again with the same two header lines" "$WORK/hook" \
      && ! grep -qF "BACKGROUND REVIEW REPORT" "$WORK/hook" && [ "$(consume_record)" = absent ] \
      && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP26 a hand-back after the tree changed is refused in the hand-back's own event, claims nothing and retires the launch" PASS
    else
      check "RP26 refused hand-back (event=$(hook_event_of "$WORK/hook") record=$(consume_record) consumed=$(state_field reviewTicketConsumed))" FAIL
      cat "$WORK/hook"
    fi
    printf 'v2\n' > "$PROJECT/tracked.txt"
    launch_payload zensu:code-reviewer "$CONSUME" consumebg2 | bash "$POSTREV" >/dev/null 2>&1
    handback_payload consumebg2 "# Code Review Report

- Verdict: PASS" | bash "$HANDBACK_HOOK" >"$WORK/hook" 2>&1
    if [ "$(hook_event_of "$WORK/hook")" = UserPromptSubmit ] && grep -qF "BACKGROUND REVIEW REPORT" "$WORK/hook" \
      && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ] && [ "$(consume_record)" = absent ]; then
      check "RP26a a consume reviewer launched again on the unchanged tree claims the ticket when its hand-back arrives" PASS
    else
      check "RP26a hand-back claim (event=$(hook_event_of "$WORK/hook") consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
  else
    check "RP24 arm a review chain" FAIL
  fi

  echo "== A stale receipt, repo personas, a gate that cannot check, and notification arrivals =="
  new_project "$WORK/p-stale"
  if arm_review "rp-stale" "$WORK/p-stale"; then
    printf 'v3\n' > "$PROJECT/tracked.txt"
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"; RC=$?
    if [ "$RC" -eq 2 ] && grep -qF "review-packet-v1: EDIT LANDING RECEIPT STALE — " "$WORK/created.err" \
      && [ -z "$(find "$PROJECT/.zensu/state" -path '*review-gate-*' -name 'packet-r*.json' 2>/dev/null)" ] && [ -f "$INPUT_JSON" ]; then
      check "RP27 create refuses through the real receipt check once the claimed file changed after the audit, and writes no packet" PASS
    else
      check "RP27 create on a stale receipt (rc=$RC)" FAIL
      cat "$WORK/created" "$WORK/created.err"
    fi
  else
    check "RP27 arm a review chain" FAIL
  fi

  new_project "$WORK/p-persona"
  if arm_review "rp-persona" "$WORK/p-persona"; then
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"
    PACKET="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created")"
    EDITED="$(printf '%s\n' "$PACKET" | sed 's/^policy: reviewer-readonly-v1$/policy: reviewer-readonly/')"
    PERSONA_REPORT="## Aspect: zensu-review-api
- (no findings)"
    agent_payload zensu-review-api "$EDITED" "$PERSONA_REPORT" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && grep -qF 'REVIEW PACKET MISMATCH — the zensu-review-api reviewer \"zensu-review-api\" prompt differs' "$WORK/hook" \
      && [ "$(store_records)" = "1" ]; then
      check "RP28 a repo persona's completion is recorded through the hook's record arm and gets the mismatch advice" PASS
    else
      check "RP28 persona record arm (rc=$RC records=$(store_records))" FAIL
      cat "$WORK/hook"
    fi
    agent_payload zensu-review-api "$PACKET" "$PERSONA_REPORT" | bash "$POSTREV" >/dev/null 2>&1
    agent_payload zensu:review-aspect "perspective: correctness
$PACKET" "## Aspect: correctness
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    agent_payload zensu:review-judge "$PACKET
merged_panel_findings: none" "## Aspect: judge
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    PERSONA_ENTRY="$CLAUDE_PLUGIN_DATA/background-review/v1/fanout/$ZENSU_SESSION_KEY/personabg1.json"
    launch_payload zensu-review-api "$EDITED" personabg1 | bash "$POSTREV" >"$WORK/hook" 2>&1
    if [ -f "$PERSONA_ENTRY" ] && grep -qF "REVIEW PACKET MISMATCH — the zensu-review-api reviewer prompt differs" "$WORK/hook" \
      && [ "$(store_records)" = "5" ]; then
      check "RP28a a background persona launch gets a fan-out entry beside its launch record" PASS
    else
      check "RP28a background persona launch (entry=$([ -f "$PERSONA_ENTRY" ] && echo present || echo absent) records=$(store_records))" FAIL
      cat "$WORK/hook"
    fi
    handback_payload personabg1 "$PERSONA_REPORT" | bash "$HANDBACK_HOOK" >"$WORK/hook" 2>&1
    if [ "$(hook_event_of "$WORK/hook")" = UserPromptSubmit ] \
      && grep -qF 'REVIEW PACKET MISMATCH — the zensu-review-api reviewer \"zensu-review-api\" prompt differs' "$WORK/hook" \
      && [ ! -e "$PERSONA_ENTRY" ] && [ "$(store_records)" = "6" ]; then
      check "RP28b a persona that hands back after every built-in reviewer still reaches the gate and retires its entry" PASS
    else
      check "RP28b late persona hand-back (event=$(hook_event_of "$WORK/hook") records=$(store_records))" FAIL
      cat "$WORK/hook"
    fi
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    CONSUME="PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none"
    agent_payload zensu:code-reviewer "$CONSUME" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1
    if grep -qF 'REVIEW INCOMPLETE — the latest zensu-review-api reviewer \"zensu-review-api\" run of review round 0 saw another packet than the canonical one' "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP28c the late persona's run on another block refuses the consume review" PASS
    else
      check "RP28c consume after a late persona mismatch (consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
    STORE_DIR="$(find "$PROJECT/.zensu/state" -maxdepth 1 -type d -name 'review-gate-*' | head -n 1)"
    printf 'not json\n' > "$STORE_DIR/packet-r0.json"
    agent_payload zensu:code-reviewer "$CONSUME" "- Verdict: PASS" | bash "$POSTREV" >"$WORK/hook" 2>&1; RC=$?
    if [ "$RC" -eq 0 ] && grep -qF "REVIEW INCOMPLETE — the review gate could not check this consume review (the canonical packet of review round 0 is not JSON)" "$WORK/hook" \
      && grep -qF "The review ticket was NOT consumed" "$WORK/hook" \
      && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP29 a gate that errs on an invalid canonical packet keeps the ticket and the round unchanged" PASS
    else
      check "RP29 gate error (rc=$RC consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
  else
    check "RP28 arm a review chain" FAIL
  fi

  new_project "$WORK/p-arrival"
  if arm_review "rp-arrival" "$WORK/p-arrival"; then
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"
    PACKET="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created")"
    agent_payload zensu:review-aspect "perspective: correctness
$PACKET" "## Aspect: correctness
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    agent_payload zensu:review-judge "$PACKET
merged_panel_findings: none" "## Aspect: judge
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    CONSUME="PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none"
    launch_payload zensu:code-reviewer "$CONSUME" consumeend1 | bash "$POSTREV" >/dev/null 2>&1
    notification_payload consumeend1 failed | bash "$HANDBACK_HOOK" >"$WORK/hook" 2>&1
    if [ "$(hook_event_of "$WORK/hook")" = UserPromptSubmit ] \
      && grep -qF "The background zensu:code-reviewer (agent consumeend1) ended with status failed before it completed its review" "$WORK/hook" \
      && [ "$(consume_record)" = absent ] && [ "$(state_field reviewTicketConsumed)" = "false" ] && [ "$(state_field reviewRound)" = "0" ]; then
      check "RP30 with the gate on, a consume reviewer that ended without completing claims nothing and retires its launch" PASS
    else
      check "RP30 ended notification (event=$(hook_event_of "$WORK/hook") record=$(consume_record) consumed=$(state_field reviewTicketConsumed))" FAIL
      cat "$WORK/hook"
    fi
    launch_payload zensu:code-reviewer "$CONSUME" consumenote1 | bash "$POSTREV" >/dev/null 2>&1
    notification_payload consumenote1 completed | bash "$HANDBACK_HOOK" >"$WORK/hook" 2>&1
    if [ "$(hook_event_of "$WORK/hook")" = UserPromptSubmit ] && grep -qF "BACKGROUND REVIEW REPORT" "$WORK/hook" \
      && ! grep -qF "REVIEW INCOMPLETE" "$WORK/hook" && [ "$(consume_record)" = absent ] \
      && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ]; then
      check "RP30a with the gate on, a completion notification alone claims the ticket on the round's records" PASS
    else
      check "RP30a notification-only claim (event=$(hook_event_of "$WORK/hook") record=$(consume_record) consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/hook"
    fi
  else
    check "RP30 arm a review chain" FAIL
  fi

  STOP_HOOK="$ROOT/hooks/stop-chain-enforcer.sh"
  new_project "$WORK/p-recovery"
  if arm_review "rp-recovery" "$WORK/p-recovery"; then
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"
    PACKET="$(awk '$0=="REVIEW PACKET v1"{on=1} on{print} $0=="END REVIEW PACKET v1"{exit}' "$WORK/created")"
    agent_payload zensu:review-aspect "perspective: correctness
$PACKET" "## Aspect: correctness
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    agent_payload zensu:review-judge "$PACKET
merged_panel_findings: none" "## Aspect: judge
- (no findings)" | bash "$POSTREV" >/dev/null 2>&1
    TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
    CONSUME="PRE-MERGED FINDINGS (fan-out)
REVIEW-TICKET: $TICKET
$PACKET
merged findings: none"
    launch_payload zensu:code-reviewer "$CONSUME" consumerec1 | bash "$POSTREV" >/dev/null 2>&1
    handback_payload consumerec1 "# Code Review Report

- Verdict: PASS" | ZENSU_BR_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" node "$ROOT/hooks/lib/background-review-v1.js" arrive >"$WORK/arrive" 2>&1
    : > "$WORK/stop"
    ATTEMPT=0
    while [ "$ATTEMPT" -lt 4 ] && [ "$(state_field reviewTicketConsumed)" = "false" ]; do
      ATTEMPT=$((ATTEMPT + 1))
      SID_VALUE="$SID" node -e 'process.stdout.write(JSON.stringify({ hook_event_name: "Stop", session_id: process.env.SID_VALUE }))' \
        | ZENSU_STOP_DEADLINE_SECONDS=75 bash "$STOP_HOOK" >"$WORK/stop" 2>/dev/null
    done
    if grep -qF "pending agent=consumerec1 source=prompt" "$WORK/arrive" \
      && grep -qF "BACKGROUND REVIEW REPORT. The background zensu:code-reviewer (agent consumerec1) delivered its report earlier in this conversation as its hand-back" "$WORK/stop" \
      && ! grep -qF "REVIEW INCOMPLETE" "$WORK/stop" && [ "$(consume_record)" = absent ] \
      && [ "$(state_field reviewTicketConsumed)" = "true" ] && [ "$(state_field reviewRound)" = "1" ]; then
      check "RP31 with the gate on, a Stop completes a cut-off hand-back's claim from its arrival note on the round's records" PASS
    else
      check "RP31 Stop recovery claim (arrive=$(cat "$WORK/arrive") attempts=$ATTEMPT record=$(consume_record) consumed=$(state_field reviewTicketConsumed) round=$(state_field reviewRound))" FAIL
      cat "$WORK/stop"
    fi
  else
    check "RP31 arm a review chain" FAIL
  fi

  echo "== The review chain's config probes read the project config =="
  PROBE_PROJECT="$WORK/p-probe"
  mkdir -p "$PROBE_PROJECT/.zensu" "$WORK/probe-home"
  printf '{"hooks":{"reviewPanel":"full","reviewJudge":false,"findingVerification":false,"aspectActivation":false}}\n' > "$PROBE_PROJECT/.zensu/config.json"
  PROBES_OK=1; PROBE_COUNT=0
  while IFS= read -r probe; do
    PROBE_COUNT=$((PROBE_COUNT+1))
    cmd="$(printf '%s' "$probe" | sed -e "s|{plugin_root}|$ROOT|g" -e "s|{project_root}|$PROBE_PROJECT|g")"
    out="$(cd "$WORK" && env -u CLAUDE_PROJECT_DIR -u ZENSU_CONFIG HOME="$WORK/probe-home" bash -c "$cmd" 2>/dev/null)"
    case "$probe" in
      (*zensu_review_panel*) [ "$out" = full ] || PROBES_OK=0 ;;
      (*) [ "$out" = off ] || PROBES_OK=0 ;;
    esac
  done < <(grep -o 'ZENSU_ROOT="{plugin_root}"[^`]*' "$ROOT/skills/build/references/review-chain.md")
  if [ "$PROBE_COUNT" -eq 4 ] && [ "$PROBES_OK" -eq 1 ]; then
    check "RP20 every review-chain config probe reads the project config" PASS
  else
    check "RP20 review-chain probes (count=$PROBE_COUNT ok=$PROBES_OK)" FAIL
  fi

  receipt_line() {
    awk '$0=="REVIEW PACKET v1"{on=1} on&&/^edit_landing_receipt: /{print; exit}' "$1"
  }

  new_project "$WORK/p-escape"
  SID="rp-escape"; PROJECT="$WORK/p-escape"
  export CLAUDE_PROJECT_DIR="$PROJECT"
  if cd "$PROJECT" && source "$ROOT/tests/session-control/initialize-baseline.sh" "$SID" && SF="$(tdd_state_file "$SID")" \
    && bash "$LOG" --tdd-begin >/dev/null 2>&1; then
    printf 'v2\n' > "$PROJECT/tracked.txt"
    ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --tdd-complete >/dev/null 2>&1; TRC=$?
    INPUT_JSON="$WORK/rp-escape-input.json"
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({
      implementation_summary: "Changes tracked.txt to v2.", requirements_baseline: "none",
      diff_summary: "tracked.txt: v1 -> v2", test_evidence: "not run — fixture", build_evidence: "not run — fixture",
      coverage_evidence: "not run — fixture", edit_landing_evidence: "not run — ZENSU_EDIT_LANDING_GATE=off" }))' "$INPUT_JSON"
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"; RC=$?
    if [ "$TRC" -eq 0 ] && tdd_bypass_recorded "$SF" ZENSU_EDIT_LANDING_GATE && [ "$RC" -eq 0 ] \
      && [ "$(receipt_line "$WORK/created")" = "edit_landing_receipt: escaped (ZENSU_EDIT_LANDING_GATE=off; no edit-landing receipt binds this review)" ]; then
      check "RP15 a chain whose ledger records the edit-landing escape gets its packet without a receipt" PASS
    else
      check "RP15 escaped chain packet (complete=$TRC rc=$RC)" FAIL
      cat "$WORK/created" "$WORK/created.err"
    fi
  else
    check "RP15 arm an escaped chain" FAIL
  fi

  new_project "$WORK/p-deferred"
  SID="rp-deferred"; PROJECT="$WORK/p-deferred"
  export CLAUDE_PROJECT_DIR="$PROJECT"
  if cd "$PROJECT" && source "$ROOT/tests/session-control/initialize-baseline.sh" "$SID" && SF="$(tdd_state_file "$SID")"; then
    OLD_STORE="$PROJECT/.zensu/state/review-gate-$ZENSU_SESSION_KEY"
    mkdir -p "$OLD_STORE" && printf '{}\n' > "$OLD_STORE/packet-r0.json"
    tdd_seed_deferred_review "$SID" false "dc_rp16claim" >/dev/null 2>&1; SRC=$?
    STORE_GONE=no
    [ -e "$OLD_STORE" ] || STORE_GONE=yes
    printf 'v2\n' > "$PROJECT/tracked.txt"
    INPUT_JSON="$WORK/rp-deferred-input.json"
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({
      implementation_summary: "not run — a deferred review", requirements_baseline: "none",
      diff_summary: "tracked.txt: v1 -> v2", test_evidence: "not run — a deferred review", build_evidence: "not run — a deferred review",
      coverage_evidence: "not run — a deferred review", edit_landing_evidence: "not run — a deferred review" }))' "$INPUT_JSON"
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"; RC=$?
    if [ "$SRC" -eq 0 ] && [ "$(state_field deferredReviewClaim)" = "dc_rp16claim" ] && [ "$(state_field implComplete)" = "true" ] \
      && [ "$RC" -eq 0 ] && [ ! -e "$PROJECT/.zensu/state/edit-landing-$ZENSU_SESSION_KEY.json" ] \
      && [ "$(receipt_line "$WORK/created")" = "edit_landing_receipt: none (not run — this chain is a deferred review the Stop hook adopted, and no edit-landing audit ran in it)" ]; then
      check "RP16 a deferred review the Stop hook seeded gets its packet without a receipt" PASS
    else
      check "RP16 deferred review packet (seed=$SRC rc=$RC claim=$(state_field deferredReviewClaim))" FAIL
      cat "$WORK/created" "$WORK/created.err"
    fi
    if [ "$SRC" -eq 0 ] && [ "$STORE_GONE" = yes ]; then
      check "RP16a seeding the deferred generation removed the previous generation's packet store" PASS
    else
      check "RP16a store reset at the deferred seed (seed=$SRC gone=$STORE_GONE)" FAIL
    fi
  else
    check "RP16 arm a chain to seed a deferred review over" FAIL
  fi

  new_project "$WORK/p-wired"
  if arm_review "rp-wired" "$WORK/p-wired"; then
    printf 'S2 WIRED\n' >> "$RUN_LOG"
    bash "$AUDIT" --log "$RUN_LOG" --project "$PROJECT" --session "$SID" >/dev/null 2>&1
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"; RC=$?
    if [ "$RC" -eq 0 ] && receipt_line "$WORK/created" | grep -q '^edit_landing_receipt: schema=edit-landing-v2 clean=false claims=2 landed=1 not_landed=0 unverified=1 pending=0 sha256=[0-9a-f]\{64\}$'; then
      check "RP17 a fix round's bare WIRED entry, once audited, is carried in the packet as an unverified claim" PASS
    else
      check "RP17 bare WIRED packet (rc=$RC)" FAIL
      cat "$WORK/created" "$WORK/created.err"
    fi
  else
    check "RP17 arm a review chain" FAIL
  fi

  new_project "$WORK/p-fault"
  if arm_review "rp-fault" "$WORK/p-fault"; then
    FAULT_BIN="$WORK/fault-bin"
    mkdir -p "$FAULT_BIN"
    printf '#!/bin/sh\necho "fatal: synthetic git failure" >&2\nexit 128\n' > "$FAULT_BIN/git"
    chmod 755 "$FAULT_BIN/git"
    PATH="$FAULT_BIN:$PATH" bash "$AUDIT" --log "$RUN_LOG" --project "$PROJECT" --session "$SID" >/dev/null 2>&1; ARC=$?
    node "$LIB" create --root "$PROJECT" --session "$SID" --input "$INPUT_JSON" >"$WORK/created" 2>"$WORK/created.err"; RC=$?
    if [ "$ARC" -eq 2 ] && [ "$RC" -eq 0 ] && receipt_line "$WORK/created" | grep -q ' audit=incomplete$' \
      && receipt_line "$WORK/created" | grep -qF ' clean=false '; then
      check "RP18 a receipt whose latest audit hit a git fault is carried in the packet as incomplete" PASS
    else
      check "RP18 incomplete audit packet (audit=$ARC rc=$RC)" FAIL
      cat "$WORK/created" "$WORK/created.err"
    fi
  else
    check "RP18 arm a review chain" FAIL
  fi
  cd "$ROOT" || true
fi

echo "----"
unit_check_done "RPz every unit file the registry gives this suite was graded"
echo "test-review-packet: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
