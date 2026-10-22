#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
AUDIT="$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh"
RECEIPT_LIB="$PLUGIN_DIR/hooks/lib/edit-landing-receipt-v1.js"
TDD_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
POSTREV="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
PROFILE="$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

finish() {
  echo "----"
  echo "test-terminal-edit-landing-gate: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LOG" "$AUDIT" "$RECEIPT_LIB" "$TDD_LIB" "$STATE_LIB" "$POSTREV" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "T0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "T0 node and git are available" FAIL
  finish
  exit 1
fi
check "T0 required files, node and git are present" PASS

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-terminal-edit-landing-gate.sh") ? 0 : 1);
' "$PROFILE"; then
  check "T0a the suite is classified as a CI structure test" PASS
else
  check "T0a the suite is classified as a CI structure test" FAIL
fi

single_line() {
  local hits
  hits="$(grep -nF "$1" "$LOG" | cut -d: -f1)"
  case "$hits" in
    (''|*[!0-9]*) printf '' ;;
    (*) printf '%s' "$hits" ;;
  esac
}
S_EL="$(single_line '_zensu_terminal_edit_landing_gate "$session_val" || chain_gate_rc=1')"
S_FS="$(single_line '_zensu_full_suite_gate "$session_val" || chain_gate_rc=1')"
S_AC="$(single_line '_zensu_acceptance_gate "$session_val" || chain_gate_rc=1')"
if [ -n "$S_EL" ] && [ -n "$S_FS" ] && [ -n "$S_AC" ] \
  && [ $((S_FS - S_EL)) -eq 1 ] && [ $((S_AC - S_FS)) -eq 1 ]; then
  check "T1 the ticket-bound standalone terminus evaluates the edit-landing gate together with the full-suite and acceptance gates" PASS
else
  check "T1 standalone gate order (edit-landing=$S_EL full-suite=$S_FS acceptance=$S_AC)" FAIL
fi
U_EL="$(single_line '(0|unknown) _zensu_terminal_edit_landing_gate "$session_val" || exit 1 ;;')"
U_MARK="$(single_line 'tdd_mark_unclaimed_review "$session_val" chainDone "$chain_change_count" || {')"
if [ -n "$U_EL" ] && [ -n "$U_MARK" ] && [ $((U_MARK - U_EL)) -eq 2 ]; then
  check "T1a the unqualified terminus asks the gate only for a zero or unknown count, before it marks the chain" PASS
else
  check "T1a unqualified gate position (gate=$U_EL mark=$U_MARK)" FAIL
fi
OUTCOME_BLOCK="$(awk '/case "\$done_outcome" in/{on=1} on{print} on&&/^[[:space:]]*esac$/{exit}' "$LOG")"
PASS_ARM="$(printf '%s\n' "$OUTCOME_BLOCK" | awk '/^[[:space:]]*pass\)$/{on=1;next} on&&/^[[:space:]]*;;$/{exit} on{print}')"
MAX_ARM="$(printf '%s\n' "$OUTCOME_BLOCK" | awk '/^[[:space:]]*max-rounds\)$/{on=1;next} on&&/^[[:space:]]*;;$/{exit} on{print}')"
B_EL="$(printf '%s\n' "$PASS_ARM" | grep -nF '_zensu_terminal_edit_landing_gate "$session_val" || exit 1' | cut -d: -f1)"
B_FS="$(printf '%s\n' "$PASS_ARM" | grep -nF '_zensu_full_suite_gate "$session_val" || exit 1' | cut -d: -f1)"
if [ -n "$B_EL" ] && [ -n "$B_FS" ] && [ "$B_EL" -lt "$B_FS" ] && [ -n "$MAX_ARM" ] \
  && ! printf '%s\n' "$MAX_ARM" | grep -qF '_zensu_terminal_edit_landing_gate'; then
  check "T1b an Autopilot pass runs the gate before the full-suite gate, and a max-rounds outcome is not gated" PASS
else
  check "T1b bound gate position (pass-arm gate=$B_EL full-suite=$B_FS)" FAIL
fi

WORK="$(mktemp -d 2>/dev/null)" || { check "T0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd -P "$WORK" && pwd -P)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{"evidence":{"fullSuiteGate":"advisory","acceptanceGate":"advisory"}}\n' > "$ZENSU_CONFIG"
REQUIRED_CONFIG="$WORK/config-required.json"
printf '{"evidence":{"fullSuiteGate":"required","acceptanceGate":"advisory"}}\n' > "$REQUIRED_CONFIG"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_FULL_SUITE_GATE ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE ZENSU_ACCEPTANCE_GATE 2>/dev/null || true
source "$TDD_LIB"
source "$STATE_LIB"

HEAD_LINE="EDIT LANDING RECEIPT STALE — "
MISSING="no edit-landing receipt exists for this session; run the audit"
NOT_CLEAN="the receipt is not clean; resolve its pending, unverified or unlanded claims"
UNGRADED="the run log holds edit claims the receipt has not graded; re-run the audit"
CLAIMED_CHANGED="a claimed file changed after the receipt; re-run the audit with current predicate proofs"
TREE_CHANGED="the working tree changed after the receipt; re-run the audit"
STAYS_OPEN="the chain stays open; re-run the edit-landing audit named above with current predicate proofs, then run --chain-done again."
GIT_PHRASE="git could not list this worktree's changes against HEAD, so whether the chain changed files cannot be checked"

new_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name tester
  printf '.zensu/\n.session-control-test/\n' > "$dir/.gitignore"
  printf 'v1\n' > "$dir/tracked.txt"
  git -C "$dir" add .gitignore tracked.txt
  git -C "$dir" -c commit.gpgsign=false commit -qm baseline
}

bind() {
  local sid="$1" project="$2" stem="${3:-2026-10-20-0000_tdd-$1}"
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  SID="$sid"
  PROJECT="$project"
  SF="$(tdd_state_file "$sid")" || return 1
  RECEIPT="$(tdd_edit_landing_receipt "$sid")" || return 1
  mkdir -p "$project/.zensu/logs"
  RUN_LOG="$project/.zensu/logs/$stem.log"
}

arm() {
  local ctx
  bind "$1" "$2" || return 1
  bash "$LOG" --tdd-begin >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete >/dev/null 2>&1 || return 1
  TICKET="$(bash "$LOG" --review-ticket 2>/dev/null)"
  [ -n "$TICKET" ] || return 1
  ctx="$(SID_VALUE="$SID" TICKET="$TICKET" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${process.env.TICKET}\nfixture`
      },
      session_id: process.env.SID_VALUE
    }));
  ')"
  printf '%s' "$ctx" | bash "$POSTREV" >/dev/null 2>&1
  bash "$LOG" --code-review-done --claimed-review-ticket "$TICKET" >/dev/null 2>&1 || return 1
}

claim() {
  printf '%s IMPL completed — files: %s\n' "$1" "$2" >> "$RUN_LOG"
}

audit() {
  bash "$AUDIT" --log "$RUN_LOG" --project "$PROJECT" --session "$SID" "$@" >"$WORK/aout" 2>"$WORK/aerr"
}

proof() {
  local out="$WORK/proof-$SID.json"
  STEP="$1" FILE="$2" LITERAL="$3" ROOT="$PROJECT" node -e '
    const fs = require("fs");
    const path = require("path");
    const bytes = fs.readFileSync(path.join(process.env.ROOT, process.env.FILE));
    const sha256 = require("crypto").createHash("sha256").update(bytes).digest("hex");
    process.stdout.write(JSON.stringify({ schema: "edit-landing-predicates-v1", claims: [
      { step: process.env.STEP, path: process.env.FILE, sha256, present: [process.env.LITERAL] },
    ] }));
  ' > "$out"
  printf '%s' "$out"
}

chain_done() {
  bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"
}

bound_done() {
  bash "$LOG" --chain-done --session "$SID" --autopilot-run tel_run --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id tel-chain --outcome pass >"$WORK/out" 2>"$WORK/err"
}

done_flag() {
  tdd_chain_done "$SF" 2>/dev/null
}

ledgered() {
  tdd_bypass_recorded "$SF" ZENSU_EDIT_LANDING_GATE
}

ERR() { cat "$WORK/err" 2>/dev/null; }
AUDIT_OUT() { cat "$WORK/aout" "$WORK/aerr" 2>/dev/null; }

new_project "$WORK/p-missing"
if arm "tel-missing" "$WORK/p-missing"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$MISSING." "$WORK/err" \
    && grep -q "^Run: bash .*zensu-edit-landing.sh --log '<run log>' --project $PROJECT --session $ZENSU_SESSION_KEY$" "$WORK/err" \
    && grep -qF "$STAYS_OPEN" "$WORK/err" && ! ledgered; then
    check "E1 a changed tree without a receipt refuses the ticket-bound terminus and names the audit to run" PASS
  else
    check "E1 missing receipt on a changed tree (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  claim S1 tracked.txt
  RUN_CMD="$(sed -n 's/^Run: //p' "$WORK/err" | head -n 1)"
  PLACEHOLDER="'<run log>'"
  RUN_CMD="${RUN_CMD/"$PLACEHOLDER"/$RUN_LOG}"
  bash -c "$RUN_CMD" >"$WORK/aout" 2>"$WORK/aerr"; ARC=$?
  if [ "$ARC" -eq 0 ] && [ -f "$RECEIPT" ] && grep -qF '"clean":true' "$RECEIPT" \
    && grep -qF '"auditScope":{' "$RECEIPT"; then
    check "E2a the printed remedy, given the run log, writes a clean scoped receipt where the terminus reads it" PASS
  else
    check "E2a printed remedy (rc=$ARC cmd='$RUN_CMD')" FAIL
    AUDIT_OUT
  fi
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && ! grep -qF "EDIT LANDING" "$WORK/err"; then
    check "E2 a fresh clean receipt closes the chain without an edit-landing line" PASS
  else
    check "E2 fresh receipt closes (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E1 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-stale"
if arm "tel-stale" "$WORK/p-stale"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  claim S1 tracked.txt
  audit; ARC=$?
  printf 'v3\n' > "$PROJECT/tracked.txt"
  chain_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$CLAIMED_CHANGED." "$WORK/err" \
    && grep -qF -- "--log $RUN_LOG --project $PROJECT --session $ZENSU_SESSION_KEY" "$WORK/err"; then
    check "E3 a claimed file edited after a clean receipt refuses and names the bound run log" PASS
  else
    check "E3 claimed file edited after the receipt (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  audit; ARC=$?
  chain_done; RC=$?
  if [ "$ARC" -eq 1 ] && AUDIT_OUT | grep -qF 'PENDING PREDICATE' \
    && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && grep -qF "$HEAD_LINE$NOT_CLEAN." "$WORK/err"; then
    check "E3b re-auditing the changed certified claim without a proof leaves it pending and the chain open" PASS
  else
    check "E3b re-audit without a proof (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
  audit --predicates "$(proof S1 tracked.txt v3)"; ARC=$?
  chain_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ]; then
    check "E3c a current literal/hash proof makes the receipt fresh and the chain closes" PASS
  else
    check "E3c proof closes (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E3 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-tree"
if arm "tel-tree" "$WORK/p-tree"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  claim S1 tracked.txt
  audit; ARC=$?
  printf 'unclaimed\n' > "$PROJECT/other.txt"
  chain_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$TREE_CHANGED." "$WORK/err"; then
    check "E4 an unclaimed edit after the receipt refuses as a changed working tree" PASS
  else
    check "E4 unclaimed edit after the receipt (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  audit; ARC=$?
  chain_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ]; then
    check "E4a re-running the audit re-measures the tree and the chain closes" PASS
  else
    check "E4a re-audit closes (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E4 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-bulk"
if arm "tel-bulk" "$WORK/p-bulk"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  claim S1 tracked.txt
  mkdir -p "$PROJECT/bulk"
  node -e 'const fs = require("fs"); for (let i = 0; i <= 20000; i += 1) fs.writeFileSync(`${process.argv[1]}/f${i}`, "");' "$PROJECT/bulk"
  audit; ARC=$?
  chain_done; RC=$?
  BULK_LINE="TREE UNVERIFIED — more than 20000 untracked files; the receipt binds the run log and the claimed files, not the rest of the working tree."
  if [ "$ARC" -eq 0 ] && grep -qF "$BULK_LINE" "$WORK/aout" && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] \
    && grep -qF "$BULK_LINE" "$WORK/err"; then
    check "E4b a tree beyond the fingerprint closes on its claims, and the audit and the terminus both disclose it" PASS
  else
    check "E4b unmeasured tree (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E4b arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-claim"
if arm "tel-claim" "$WORK/p-claim"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  claim S1 tracked.txt
  audit; ARC=$?
  printf 'added\n' > "$PROJECT/other.txt"
  claim S2 other.txt
  chain_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$UNGRADED." "$WORK/err"; then
    check "E5 a claim logged after the receipt refuses until the audit grades it" PASS
  else
    check "E5 claim logged after the receipt (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E5 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-unqualified"
if bind "tel-unqualified" "$WORK/p-unqualified" && bash "$LOG" --tdd-begin >/dev/null 2>&1; then
  BASE="$(git -C "$PROJECT" rev-parse HEAD)"
  printf 'v2\n' > "$PROJECT/tracked.txt"
  claim S1 tracked.txt
  audit --baseline "$BASE"; ARC=$?
  printf 'added\n' > "$PROJECT/other.txt"
  git -C "$PROJECT" add -A
  git -C "$PROJECT" -c commit.gpgsign=false commit -qm "committed work"
  bash "$LOG" --tdd-complete >/dev/null 2>&1; TRC=$?
  claim S2 other.txt
  bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$TRC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$UNGRADED." "$WORK/err"; then
    check "E6 the unqualified terminus of committed work refuses a receipt that misses a later claim" PASS
  else
    check "E6 unqualified terminus with a later claim (audit=$ARC complete=$TRC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  audit; ARC=$?
  bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && ! grep -qF "EDIT LANDING" "$WORK/err"; then
    check "E6a the unqualified terminus closes once the audit graded every claim of the committed work" PASS
  else
    check "E6a unqualified terminus after the re-audit (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E6 arm an unqualified chain" FAIL
fi

new_project "$WORK/p-escape"
if arm "tel-escape" "$WORK/p-escape"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --chain-done --claimed-review-ticket "rt_00000000000000000000000000000000" \
    >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(done_flag)" = "false" ] && ! ledgered && ! grep -qF "EDIT LANDING" "$WORK/err"; then
    check "E7 an escape on a wrong ticket is refused by the ticket check and never ledgered" PASS
  else
    check "E7 escape on a wrong ticket (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  ZENSU_EDIT_LANDING_GATE=off chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && ledgered \
    && grep -q '^Gates bypassed during this session: .*ZENSU_EDIT_LANDING_GATE' "$WORK/err"; then
    check "E7a the escape closes a changed tree without a receipt and is ledgered and disclosed" PASS
  else
    check "E7a escape where the gate applies (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E7 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-escape-zero"
if arm "tel-escape-zero" "$WORK/p-escape-zero"; then
  ZENSU_EDIT_LANDING_GATE=off chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && ! ledgered && ! grep -qF "EDIT LANDING" "$WORK/err"; then
    check "E7b a zero-change chain without a receipt closes silently and an escape there is not ledgered" PASS
  else
    check "E7b escape outside the gate's scope (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E7b arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-noted"
if arm "tel-noted" "$WORK/p-noted" && bash "$LOG" --bypass-note ZENSU_EDIT_LANDING_GATE >/dev/null 2>&1; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  chain_done; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && ! grep -qF "$HEAD_LINE" "$WORK/err" \
    && grep -q '^Gates bypassed during this session: .*ZENSU_EDIT_LANDING_GATE' "$WORK/err"; then
    check "E7c an escape the chain's ledger already records exempts the terminus without the environment switch" PASS
  else
    check "E7c ledgered escape at the terminus (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E7c arm a ticket-bound chain with a ledgered escape" FAIL
fi

GIT_HOME="$WORK/git-home"
GIT_SAFE_HOME="$WORK/git-safe-home"
mkdir -p "$GIT_HOME" "$GIT_SAFE_HOME"
printf '[safe]\n\tdirectory = *\n' > "$GIT_SAFE_HOME/.gitconfig"
foreign_owner() {
  HOME="$GIT_HOME" XDG_CONFIG_HOME="$GIT_HOME/.config" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$@"
}
foreign_owner_excepted() {
  HOME="$GIT_SAFE_HOME" XDG_CONFIG_HOME="$GIT_SAFE_HOME/.config" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$@"
}
new_project "$WORK/p-git"
if arm "tel-git" "$WORK/p-git"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  GIT_ERR="$(foreign_owner env LC_ALL=C git -C "$PROJECT" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"
  if printf '%s\n' "$GIT_ERR" | grep -qF "dubious ownership" \
    && [ "$(foreign_owner_excepted git -C "$PROJECT" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
    check "E8-control real git refuses the fixture as owned by another user, and a safe.directory exception clears it" PASS
  else
    check "E8-control dubious-ownership refusal (err='$GIT_ERR')" FAIL
  fi
  foreign_owner bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && grep -qF "$GIT_PHRASE" "$WORK/err" \
    && ! grep -qF "$HEAD_LINE" "$WORK/err"; then
    check "E8 without a receipt, a git refusal names git as the cause instead of the audit" PASS
  else
    check "E8 git refusal without a receipt (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  foreign_owner_excepted bash "$LOG" --chain-done --claimed-review-ticket "$TICKET" >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && grep -qF "$HEAD_LINE$MISSING." "$WORK/err" \
    && ! grep -qF "$GIT_PHRASE" "$WORK/err"; then
    check "E8a with the exception in place the same chain asks for the audit (control for E8)" PASS
  else
    check "E8a control under the safe.directory exception (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E8 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-together"
if arm "tel-together" "$WORK/p-together"; then
  printf 'v2\n' > "$PROJECT/tracked.txt"
  ZENSU_CONFIG="$REQUIRED_CONFIG" chain_done; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && grep -qF "$HEAD_LINE$MISSING." "$WORK/err" \
    && grep -q '^FULL SUITE — missing | ' "$WORK/err"; then
    check "E9 one terminus call names the edit-landing refusal and the full-suite refusal together" PASS
  else
    check "E9 refusals named together (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E9 arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-zero-audit"
if bind "tel-zero-audit" "$WORK/p-zero-audit" && bash "$LOG" --tdd-begin >/dev/null 2>&1; then
  printf 'TDD START — fixture\n' > "$RUN_LOG"
  audit; ARC=$?
  bash "$LOG" --tdd-complete >/dev/null 2>&1; TRC=$?
  bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ -f "$RECEIPT" ] && grep -qF '"claims":0' "$RECEIPT" && [ "$TRC" -eq 0 ] \
    && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ ! -s "$WORK/err" ]; then
    check "E11 the unqualified zero-change terminus closes silently after a step 5b audit that graded no claim" PASS
  else
    check "E11 zero-claim audit before the unqualified terminus (audit=$ARC complete=$TRC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E11 arm an unqualified chain" FAIL
fi

new_project "$WORK/p-zero-ticket"
if arm "tel-zero-ticket" "$WORK/p-zero-ticket"; then
  printf 'TDD START — fixture\n' > "$RUN_LOG"
  audit; ARC=$?
  chain_done; RC=$?
  if [ -f "$RECEIPT" ] && grep -qF '"claims":0' "$RECEIPT" \
    && [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && ! grep -qF "EDIT LANDING" "$WORK/err"; then
    check "E11a the ticket-bound terminus of a zero-change chain closes after an audit that graded no claim" PASS
  else
    check "E11a zero-claim audit before the ticket-bound terminus (audit=$ARC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E11a arm a ticket-bound chain" FAIL
fi

new_project "$WORK/p-zero-late"
if bind "tel-zero-late" "$WORK/p-zero-late" && bash "$LOG" --tdd-begin >/dev/null 2>&1; then
  printf 'TDD START — fixture\n' > "$RUN_LOG"
  audit; ARC=$?
  bash "$LOG" --tdd-complete >/dev/null 2>&1; TRC=$?
  claim S1 tracked.txt
  bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$TRC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$UNGRADED." "$WORK/err" && grep -qF "$STAYS_OPEN" "$WORK/err"; then
    check "E11b a claim logged after a zero-claim audit arms the gate and refuses until the audit grades it" PASS
  else
    check "E11b claim after a zero-claim audit (audit=$ARC complete=$TRC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E11b arm an unqualified chain" FAIL
fi

new_project "$WORK/p-zero-wired"
if bind "tel-zero-wired" "$WORK/p-zero-wired" && bash "$LOG" --tdd-begin >/dev/null 2>&1; then
  printf 'TDD START — fixture\n' > "$RUN_LOG"
  bash "$LOG" --tdd-complete >/dev/null 2>&1; TRC=$?
  printf 'S2 WIRED\n' >> "$RUN_LOG"
  audit; ARC=$?
  bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$TRC" -eq 0 ] && grep -qF '"claims":1' "$RECEIPT" && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$NOT_CLEAN." "$WORK/err"; then
    check "E11c a receipt that counts a bare WIRED entry arms the gate as it arms --tdd-complete, and names the unverified claim" PASS
  else
    check "E11c bare WIRED receipt on a zero-change tree (audit=$ARC complete=$TRC rc=$RC done=$(done_flag))" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E11c arm an unqualified chain" FAIL
fi

TIMEOUT_BIN="$WORK/timeout-bin"
mkdir -p "$TIMEOUT_BIN"
printf '#!/bin/sh\nexit 124\n' > "$TIMEOUT_BIN/timeout"
chmod 755 "$TIMEOUT_BIN/timeout"
PARTIAL_BIN="$WORK/partial-bin"
mkdir -p "$PARTIAL_BIN"
printf '#!/bin/sh\necho claimed-files=1\nexit 124\n' > "$PARTIAL_BIN/timeout"
chmod 755 "$PARTIAL_BIN/timeout"
INCOMPLETE="the claim inventory over its run log did not complete, so a claim logged after that audit cannot be ruled out; the chain stays open."
new_project "$WORK/p-zero-timeout"
if bind "tel-zero-timeout" "$WORK/p-zero-timeout" && bash "$LOG" --tdd-begin >/dev/null 2>&1; then
  printf 'TDD START — fixture\n' > "$RUN_LOG"
  audit; ARC=$?
  bash "$LOG" --tdd-complete >/dev/null 2>&1; TRC=$?
  PATH="$TIMEOUT_BIN:$PATH" bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ -f "$RECEIPT" ] && grep -qF '"claims":0' "$RECEIPT" && [ "$TRC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$INCOMPLETE" "$WORK/err" && grep -qF -- "--inventory --log" "$WORK/err" && ! grep -qF "$NOT_CLEAN" "$WORK/err"; then
    check "E11d an inventory that does not complete refuses the zero-claim exemption with its own cause, never as not clean" PASS
  else
    check "E11d inventory timeout on a zero-claim receipt (audit=$ARC complete=$TRC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  PATH="$PARTIAL_BIN:$PATH" bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] && grep -qF "$HEAD_LINE$NOT_CLEAN." "$WORK/err" && ! grep -qF "$INCOMPLETE" "$WORK/err"; then
    check "E11e a partial inventory that already counts a claimed file arms the gate, and the receipt check decides" PASS
  else
    check "E11e partial inventory (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  bash "$LOG" --chain-done >"$WORK/out" 2>"$WORK/err"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$(done_flag)" = "true" ] && [ ! -s "$WORK/err" ]; then
    check "E11f once the inventory completes the same chain closes silently" PASS
  else
    check "E11f completed inventory after two refusals (rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
else
  check "E11d arm an unqualified chain" FAIL
fi

BOUND_STEM="2026-10-20-0001_tdd-terminal-bound"
APPROVED_SHA="$(printf 'a%.0s' $(seq 1 64))"
new_project "$WORK/p-bound"
if bind "tel-bound" "$WORK/p-bound" "$BOUND_STEM" \
  && autopilot_begin_run tel_run "$ZENSU_SESSION_KEY" "$PROJECT" false true >/dev/null 2>&1 \
  && autopilot_apply_event tel_run plan-tel_run PLAN_APPROVED "{\"approvedPlanSha256\":\"$APPROVED_SHA\"}" "$PROJECT" >/dev/null 2>&1 \
  && bash "$LOG" --tdd-begin --session "$SID" --autopilot-run tel_run --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id tel-chain >/dev/null 2>&1; then
  mkdir -p "$PROJECT/.zensu/plans"
  cat > "$PROJECT/.zensu/plans/$BOUND_STEM.md" <<'PLAN'
# Fixture plan

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the fixture file carries the bound value | spec |
PLAN
  printf 'v2\n' > "$PROJECT/tracked.txt"
  claim S1 tracked.txt
  audit; ARC=$?
  bash "$LOG" --tdd-complete --session "$SID" --plan "./.zensu/plans/$BOUND_STEM.md" --autopilot-run tel_run \
    --autopilot-attempt 1 --chain-id tel-chain >/dev/null 2>&1; TRC=$?
  printf 'v3\n' > "$PROJECT/tracked.txt"
  bound_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$TRC" -eq 0 ] && [ "$RC" -eq 1 ] && [ "$(done_flag)" = "false" ] \
    && grep -qF "$HEAD_LINE$CLAIMED_CHANGED." "$WORK/err" && grep -qF "$STAYS_OPEN" "$WORK/err"; then
    check "E10 an Autopilot pass refuses a receipt whose claimed file changed afterwards" PASS
  else
    check "E10 bound pass on a stale receipt (audit=$ARC complete=$TRC rc=$RC done=$(done_flag))" FAIL
    ERR
  fi
  audit --predicates "$(proof S1 tracked.txt v3)"; ARC=$?
  bound_done; RC=$?
  if [ "$ARC" -eq 0 ] && [ "$RC" -eq 0 ]; then
    check "E10a the Autopilot pass closes once the audit proves the current claim" PASS
  else
    check "E10a bound pass after the proof (audit=$ARC rc=$RC)" FAIL
    AUDIT_OUT
    ERR
  fi
else
  check "E10 arm an Autopilot-bound chain" FAIL
fi

finish
