#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$PLUGIN_DIR/hooks/lib/evidence-run-v1.js"
UNIT="$PLUGIN_DIR/tests/structure/evidence-run-v1.test.js"
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
  echo "test-evidence-run: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$LIB" "$UNIT" "$PROFILE"; do
  if [ ! -f "$f" ]; then
    check "E0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
check "E0 all required files exist" PASS

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  check "E0 node and git are available" FAIL
  finish
  exit 1
fi
check "E0 node and git are available" PASS

WORK="$(mktemp -d 2>/dev/null)" || { check "E0 scratch dir" FAIL; finish; exit 1; }
trap 'rm -rf "$WORK"' EXIT

unit_check "E1 the evidence-run unit file passes" "$UNIT"

if node -e '
  const m = require(process.argv[1]);
  process.exit(m.ciStructureTests.includes("test-evidence-run.sh") ? 0 : 1);
' "$PROFILE"; then
  check "E2 the suite is classified as a CI structure test" PASS
else
  check "E2 the suite is classified as a CI structure test" FAIL
fi

LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_TEST_PLUGIN_DATA="$WORK/plugin-data"
export ZENSU_CONFIG="$WORK/config.json"
printf '{}\n' > "$ZENSU_CONFIG"
PROJ="$WORK/project"
mkdir -p "$PROJ"
PROJ="$(cd -P "$PROJ" && pwd -P)"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.invalid
git -C "$PROJ" config user.name tester
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
printf 'baseline\n' > "$PROJ/tracked.txt"
git -C "$PROJ" add .gitignore tracked.txt
git -C "$PROJ" -c commit.gpgsign=false commit -qm baseline
unset CLAUDE_AGENT_TYPE 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$PROJ"
cd "$PROJ" || { check "E3 project directory" FAIL; finish; exit 1; }

if source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "evidence-run-cli"; then
  check "E3 a Session Control baseline binds the test session" PASS
else
  check "E3 a Session Control baseline binds the test session" FAIL
  finish
  exit 1
fi
RECORDS="$ZENSU_TEST_PLUGIN_DATA/evidence-run/v1/records/${ZENSU_SESSION_KEY:-missing}"

OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'echo suite-ok' 2>"$WORK/e4.err")"; RC=$?
if [ "$RC" -eq 0 ] \
  && printf '%s' "$OUT" | grep -q 'full output: ' \
  && printf '%s' "$OUT" | grep -q '^suite-ok$' \
  && printf '%s' "$OUT" | grep -q 'zensu evidence-run: scope=full exit=0 ' \
  && [ "$(ls "$RECORDS" 2>/dev/null | grep -c '\.json$')" = "1" ]; then
  check "E4 a green full run exits 0, prints the tail and summary, and writes one record" PASS
else
  check "E4 a green full run exits 0, prints the tail and summary, and writes one record (rc=$RC)" FAIL
  printf '%s\n' "$OUT"; cat "$WORK/e4.err"
fi

OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'echo broken; exit 5' 2>/dev/null)"; RC=$?
if [ "$RC" -eq 5 ] && printf '%s' "$OUT" | grep -q 'exit=5 '; then
  check "E5 a red run passes the suite's exit code through" PASS
else
  check "E5 a red run passes the suite's exit code through (rc=$RC)" FAIL
fi

OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'false | cat' 2>/dev/null)"; RC=$?
if [ "$RC" -eq 1 ]; then
  check "E6 a failing pipeline fails under the runner's pipefail" PASS
else
  check "E6 a failing pipeline fails under the runner's pipefail (rc=$RC)" FAIL
fi

PROBE='echo "k=${ZENSU_SESSION_KEY-unset} d=${CLAUDE_PLUGIN_DATA-unset} r=${CLAUDE_PLUGIN_ROOT-unset} pd=${CLAUDE_PROJECT_DIR-unset}"'
OUT="$(CLAUDE_PROJECT_DIR="$PROJ" bash "$LOG" --evidence-run --scope scoped --cmd "$PROBE" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF "k=unset d=unset r=unset pd=$PROJ"; then
  check "E7 the suite sees no plugin bindings and the caller's CLAUDE_PROJECT_DIR" PASS
else
  check "E7 the suite sees no plugin bindings and the caller's CLAUDE_PROJECT_DIR (rc=$RC)" FAIL
  printf '%s\n' "$OUT"
fi

OUT="$(bash "$LOG" --evidence-run --scope scoped --cmd 'pwd' 2>/dev/null)"; RC=$?
mkdir -p "$PROJ/nested"
OUT_NESTED="$(cd "$PROJ/nested" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd' 2>/dev/null)"; RC_NESTED=$?
if [ "$RC" -eq 0 ] && [ "$RC_NESTED" -eq 0 ] && printf '%s' "$OUT_NESTED" | grep -q '/nested$'; then
  check "E8 the suite runs in the caller's working directory" PASS
else
  check "E8 the suite runs in the caller's working directory (rc=$RC/$RC_NESTED)" FAIL
fi

ELSEWHERE="$WORK/elsewhere"
mkdir -p "$ELSEWHERE"
ELSEWHERE="$(cd -P "$ELSEWHERE" && pwd -P)"
git -C "$ELSEWHERE" init -q
OUT_AWAY="$(cd "$ELSEWHERE" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>"$WORK/e8b.err")"; RC_AWAY=$?
if [ "$RC_AWAY" -eq 0 ] && printf '%s\n' "$OUT_AWAY" | grep -qxF "$PROJ" \
  && ! printf '%s\n' "$OUT_AWAY" | grep -qxF "$ELSEWHERE" \
  && grep -qF 'the working directory is not in the work tree of the bound project root, so the command runs in' "$WORK/e8b.err"; then
  check "E8b from another work tree the suite runs in the bound project root and says so" PASS
else
  check "E8b from another work tree the suite runs in the bound project root and says so (rc=$RC_AWAY)" FAIL
  printf '%s\n' "$OUT_AWAY" | tail -5
fi

INNER="$PROJ/inner-repo"
mkdir -p "$INNER"
git -C "$INNER" init -q
OUT_INNER="$(cd "$INNER" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>"$WORK/e8c.err")"; RC_INNER=$?
rm -rf "$INNER"
if [ "$RC_INNER" -eq 0 ] && printf '%s\n' "$OUT_INNER" | grep -qxF "$PROJ" \
  && ! printf '%s\n' "$OUT_INNER" | grep -qxF "$INNER" \
  && grep -qF 'the working directory is not in the work tree of the bound project root, so the command runs in' "$WORK/e8c.err"; then
  check "E8c from a nested work tree inside the project root the suite runs in the bound project root and says so" PASS
else
  check "E8c from a nested work tree inside the project root the suite runs in the bound project root and says so (rc=$RC_INNER)" FAIL
  printf '%s\n' "$OUT_INNER" | tail -5
fi

printf '{"evidence":{"fullSuiteCommand":"echo configured-suite"}}\n' > "$ZENSU_CONFIG"
OUT="$(bash "$LOG" --evidence-run --scope full 2>/dev/null)"; RC=$?
ERR="$(bash "$LOG" --evidence-run --scope full --cmd 'true' 2>&1 >/dev/null)"; RC_MISMATCH=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^configured-suite$' \
  && [ "$RC_MISMATCH" -eq 2 ] && printf '%s' "$ERR" | grep -q 'differs from evidence.fullSuiteCommand'; then
  check "E9 evidence.fullSuiteCommand is the default and a different --cmd is refused" PASS
else
  check "E9 evidence.fullSuiteCommand is the default and a different --cmd is refused (rc=$RC/$RC_MISMATCH)" FAIL
fi
printf '{}\n' > "$ZENSU_CONFIG"

mkdir -p "$PROJ/.zensu/logs"
RUN_LOG="$PROJ/.zensu/logs/2026-01-01-0000_build-evidence.log"
: > "$RUN_LOG"
bash "$LOG" --evidence-run --scope lint --cmd 'echo lint-ok' --log "$RUN_LOG" >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'EVIDENCE RUN — scope=lint exit=0 .* | cmd: echo lint-ok$' "$RUN_LOG"; then
  check "E10 --log appends one machine-authored run-log line" PASS
else
  check "E10 --log appends one machine-authored run-log line (rc=$RC)" FAIL
  cat "$RUN_LOG"
fi

bash "$LOG" --evidence-run --scope full --cmd 'true' >/dev/null 2>&1
OUT="$(bash "$LOG" --evidence-run --scope full --cmd 'true' --if-stale 2>/dev/null)"; RC=$?
BEFORE="$(ls "$RECORDS" | grep -c '\.json$')"
printf 'edited\n' > "$PROJ/tracked.txt"
bash "$LOG" --evidence-run --scope full --cmd 'true' --if-stale >/dev/null 2>&1
AFTER="$(ls "$RECORDS" | grep -c '\.json$')"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'skipped (--if-stale)' && [ "$AFTER" -eq $((BEFORE + 1)) ]; then
  check "E11 --if-stale skips a fresh green record and runs after an edit" PASS
else
  check "E11 --if-stale skips a fresh green record and runs after an edit (rc=$RC before=$BEFORE after=$AFTER)" FAIL
fi

bash "$LOG" --evidence-run --scope everything --cmd 'true' >/dev/null 2>&1; RC_SCOPE=$?
bash "$LOG" --evidence-run --scope full --bogus >/dev/null 2>&1; RC_ARG=$?
bash "$LOG" --evidence-run --scope lint >/dev/null 2>&1; RC_CMD=$?
if [ "$RC_SCOPE" -eq 2 ] && [ "$RC_ARG" -eq 2 ] && [ "$RC_CMD" -eq 2 ]; then
  check "E12 an unknown scope, an unknown argument and a missing --cmd are usage errors" PASS
else
  check "E12 an unknown scope, an unknown argument and a missing --cmd are usage errors ($RC_SCOPE/$RC_ARG/$RC_CMD)" FAIL
fi

OUT_PD="$(bash "$LOG" --chain-work-tree --project-dir 2>/dev/null)"; RC_PD=$?
OUT_PR="$(bash "$LOG" --project-root 2>/dev/null)"
if [ "$RC_PD" -eq 0 ] && [ -n "$OUT_PD" ] && [ "$OUT_PD" = "$OUT_PR" ]; then
  check "E13 without an Autopilot binding --chain-work-tree --project-dir prints the project root --project-root prints" PASS
else
  check "E13 without an Autopilot binding --chain-work-tree --project-dir prints the project root (rc=$RC_PD got '$OUT_PD' want '$OUT_PR')" FAIL
fi

LIB_PROBE='echo "core=${_ZENSU_TDD_CONTROL_CORE-unset} fn=$(declare -F tdd_state_file >/dev/null 2>&1 && echo set || echo unset)"'
OUT_LIB="$(bash "$LOG" --evidence-run --scope scoped --cmd "$LIB_PROBE" 2>/dev/null)"; RC_LIB=$?
if [ "$RC_LIB" -eq 0 ] && printf '%s\n' "$OUT_LIB" | grep -qxF "core=unset fn=unset"; then
  check "E22 the suite of a standalone chain inherits none of the phase library's exports" PASS
else
  check "E22 the suite of a standalone chain inherits none of the phase library's exports (rc=$RC_LIB)" FAIL
  printf '%s\n' "$OUT_LIB"
fi

echo "== A chain bound to an Autopilot run that drives a worktree below the anchor =="
source "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
source "$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
APPROVED_SHA="$(printf 'a%.0s' $(seq 1 64))"
bound_repo() {
  mkdir -p "$1/pkg"
  git -C "$1" init -q
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name tester
  printf '.zensu/\n.session-control-test/\n.claude/worktrees/\n' > "$1/.gitignore"
  printf '.claude/worktrees/\n' > "$1/pkg/.gitignore"
  printf 'baseline\n' > "$1/tracked.txt"
  printf 'package\n' > "$1/pkg/inside.txt"
  git -C "$1" add .gitignore tracked.txt pkg/.gitignore pkg/inside.txt
  git -C "$1" -c commit.gpgsign=false commit -qm baseline
}
bound_arm() {
  local sid="$1" project="$2" run="$3" chain="$4" workspace="$5"
  export CLAUDE_PROJECT_DIR="$project"
  cd "$project" || return 1
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$sid" || return 1
  autopilot_begin_run "$run" "$ZENSU_SESSION_KEY" "$project" false true "$workspace" >/dev/null 2>&1 || return 1
  autopilot_apply_event "$run" "plan-$run" PLAN_APPROVED "{\"approvedPlanSha256\":\"$APPROVED_SHA\"}" "$project" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-begin --session "$sid" --autopilot-run "$run" --autopilot-attempt 1 \
    --autopilot-return-stage GATES --chain-id "$chain" >/dev/null 2>&1
}
record_count() { ls "$ZENSU_TEST_PLUGIN_DATA/evidence-run/v1/records/${ZENSU_SESSION_KEY:-missing}" 2>/dev/null | grep -c '\.json$'; }

BOUND="$WORK/bound"
bound_repo "$BOUND"
BOUND="$(cd -P "$BOUND" && pwd -P)"
git -C "$BOUND" worktree add -q "$BOUND/.claude/worktrees/wt" -b wt-bound >/dev/null 2>&1
BWT="$(cd -P "$BOUND/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
if [ -n "$BWT" ] && bound_arm evidence-run-bound "$BOUND" er_run er-chain "$BWT"; then
  check "E14 an Autopilot run that drives a worktree below the anchor arms a bound chain" PASS
else
  check "E14 an Autopilot run that drives a worktree below the anchor arms a bound chain" FAIL
fi

OUT_PD="$(bash "$LOG" --chain-work-tree --project-dir 2>/dev/null)"; RC_PD=$?
OUT_WT="$(bash "$LOG" --chain-work-tree 2>/dev/null)"
if [ "$RC_PD" -eq 0 ] && [ "$OUT_PD" = "$BWT" ] && [ "$OUT_WT" = "$BWT" ]; then
  check "E15 for the bound chain --chain-work-tree --project-dir prints the run's worktree" PASS
else
  check "E15 for the bound chain --chain-work-tree --project-dir prints the run's worktree (rc=$RC_PD got '$OUT_PD' / '$OUT_WT')" FAIL
fi

OUT_B="$(cd "$BOUND" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>"$WORK/e16.err")"; RC_B=$?
if [ "$RC_B" -eq 0 ] && printf '%s\n' "$OUT_B" | grep -qxF "$BWT" \
  && ! printf '%s\n' "$OUT_B" | grep -qxF "$BOUND" \
  && grep -qF "the working directory is not in the work tree of this Autopilot-bound chain, so the command runs in $BWT" "$WORK/e16.err"; then
  check "E16 from the anchor the bound chain's suite runs in its worktree and says so" PASS
else
  check "E16 from the anchor the bound chain's suite runs in its worktree and says so (rc=$RC_B)" FAIL
  printf '%s\n' "$OUT_B" | tail -3; cat "$WORK/e16.err"
fi

OUT_IN="$(cd "$BWT/pkg" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>"$WORK/e17.err")"; RC_IN=$?
INNER_B="$BOUND/inner-repo"
mkdir -p "$INNER_B"
git -C "$INNER_B" init -q
OUT_NEST="$(cd "$INNER_B" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>"$WORK/e17b.err")"; RC_NEST=$?
rm -rf "$INNER_B"
if [ "$RC_IN" -eq 0 ] && printf '%s\n' "$OUT_IN" | grep -qxF "$BWT/pkg" && ! grep -qF 'so the command runs in' "$WORK/e17.err" \
  && [ "$RC_NEST" -eq 0 ] && printf '%s\n' "$OUT_NEST" | grep -qxF "$BWT" \
  && grep -qF "so the command runs in $BWT" "$WORK/e17b.err"; then
  check "E17 a cwd inside the worktree is kept, and one in another repository nested in the anchor moves to the worktree" PASS
else
  check "E17 a cwd inside the worktree is kept, and one in another repository nested in the anchor moves to the worktree (rc=$RC_IN/$RC_NEST)" FAIL
fi

(cd "$BOUND" && bash "$LOG" --evidence-run --scope scoped --cmd 'true' >/dev/null 2>&1)
SKIP_OUT="$(cd "$BOUND" && bash "$LOG" --evidence-run --scope scoped --cmd 'true' --if-stale 2>/dev/null)"
BEFORE_B="$(record_count)"
printf 'edited in the worktree\n' > "$BWT/tracked.txt"
(cd "$BOUND" && bash "$LOG" --evidence-run --scope scoped --cmd 'true' --if-stale >/dev/null 2>&1)
AFTER_B="$(record_count)"
git -C "$BWT" checkout -q -- tracked.txt
if printf '%s' "$SKIP_OUT" | grep -qF 'skipped (--if-stale)' && [ "$AFTER_B" -eq $((BEFORE_B + 1)) ]; then
  check "E18 the bound run's record covers the worktree: --if-stale skips it until an edit there" PASS
else
  check "E18 the bound run's record covers the worktree (before=$BEFORE_B after=$AFTER_B)" FAIL
fi

BOUND_RUN_FILE="$(autopilot_run_file er_run "$BOUND")"
cp "$BOUND_RUN_FILE" "$WORK/bound-run.pre"
BAD_WS="$BOUND/pkg" node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.workspaceRoot = process.env.BAD_WS; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$BOUND_RUN_FILE"
BEFORE_F="$(record_count)"
FAULT_ERR="$(cd "$BOUND" && bash "$LOG" --evidence-run --scope scoped --cmd 'true' 2>&1 >/dev/null)"; RC_F=$?
AFTER_F="$(record_count)"
bash "$LOG" --chain-work-tree --project-dir >/dev/null 2>&1; RC_FPD=$?
cp "$WORK/bound-run.pre" "$BOUND_RUN_FILE"
if [ "$RC_F" -eq 2 ] && [ "$AFTER_F" -eq "$BEFORE_F" ] && [ "$RC_FPD" -eq 2 ] \
  && printf '%s' "$FAULT_ERR" | grep -qF "the chain's work tree could not be determined, so the command was not run: "; then
  check "E19 a bound chain whose worktree cannot be resolved refuses the run with exit 2 and writes no record" PASS
else
  check "E19 a bound chain whose worktree cannot be resolved refuses the run (rc=$RC_F/$RC_FPD before=$BEFORE_F after=$AFTER_F)" FAIL
  printf '%s\n' "$FAULT_ERR"
fi

SUBREPO="$WORK/subrepo"
bound_repo "$SUBREPO"
SUBREPO="$(cd -P "$SUBREPO" && pwd -P)"
git -C "$SUBREPO" worktree add -q "$SUBREPO/pkg/.claude/worktrees/wt" -b wt-sub >/dev/null 2>&1
SWT="$(cd -P "$SUBREPO/pkg/.claude/worktrees/wt" 2>/dev/null && pwd -P)"
if [ -n "$SWT" ] && bound_arm evidence-run-subdir "$SUBREPO/pkg" er_sub er-sub-chain "$SWT"; then
  OUT_SPD="$(bash "$LOG" --chain-work-tree --project-dir 2>/dev/null)"
  OUT_SWT="$(bash "$LOG" --chain-work-tree 2>/dev/null)"
  OUT_SRUN="$(cd "$SUBREPO/pkg" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>/dev/null)"; RC_SRUN=$?
  if [ "$OUT_SPD" = "$SWT/pkg" ] && [ "$OUT_SWT" = "$SWT" ] && [ "$RC_SRUN" -eq 0 ] \
    && printf '%s\n' "$OUT_SRUN" | grep -qxF "$SWT/pkg"; then
    check "E20 a session bound to a subdirectory runs its suite in the matching subdirectory of the worktree" PASS
  else
    check "E20 a session bound to a subdirectory runs in the worktree's subdirectory (dir='$OUT_SPD' tree='$OUT_SWT' rc=$RC_SRUN)" FAIL
  fi
else
  check "E20 arm a chain bound to a subdirectory whose run drives a worktree below it" FAIL
fi

SUB_STATE="$(tdd_state_file evidence-run-subdir)"
cp "$SUB_STATE" "$WORK/sub-state.pre"
printf '{"not":"a workflow document"}\n' > "$SUB_STATE"
BEFORE_L="$(record_count)"
LINK_ERR="$(cd "$SUBREPO/pkg" && bash "$LOG" --evidence-run --scope scoped --cmd 'true' 2>&1 >/dev/null)"; RC_L=$?
AFTER_L="$(record_count)"
cp "$WORK/sub-state.pre" "$SUB_STATE"
if [ "$RC_L" -eq 2 ] && [ "$AFTER_L" -eq "$BEFORE_L" ] \
  && printf '%s' "$LINK_ERR" | grep -qF "the chain's work tree could not be determined, so the command was not run: this chain's workflow document cannot be read, so whether it is bound to an Autopilot worktree is unknown"; then
  check "E21 a workflow document whose Autopilot linkage cannot be read refuses the run instead of falling back to the anchor" PASS
else
  check "E21 an unreadable Autopilot linkage refuses the run (rc=$RC_L before=$BEFORE_L after=$AFTER_L)" FAIL
  printf '%s\n' "$LINK_ERR"
fi

OUT_BLIB="$(cd "$SUBREPO/pkg" && unset -f tdd_state_file tdd_autopilot_context && unset _ZENSU_TDD_CONTROL_CORE && bash "$LOG" --evidence-run --scope scoped --cmd "$LIB_PROBE" 2>/dev/null)"; RC_BLIB=$?
if [ "$RC_BLIB" -eq 0 ] && printf '%s\n' "$OUT_BLIB" | grep -qxF "core=unset fn=unset"; then
  check "E23 the suite of a bound chain inherits none of the phase library's exports" PASS
else
  check "E23 the suite of a bound chain inherits none of the phase library's exports (rc=$RC_BLIB)" FAIL
  printf '%s\n' "$OUT_BLIB"
fi

cp "$SUB_STATE" "$WORK/sub-state.open"
node -e 'const fs = require("fs"); const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); s.implComplete = true; s.chainDone = true; s.chainOutcome = "pass"; fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2) + "\n");' "$SUB_STATE"
OUT_DONE="$(cd "$SUBREPO/pkg" && bash "$LOG" --evidence-run --scope scoped --cmd 'pwd -P' 2>"$WORK/e24.err")"; RC_DONE=$?
cp "$WORK/sub-state.open" "$SUB_STATE"
if [ "$RC_DONE" -eq 0 ] && printf '%s\n' "$OUT_DONE" | grep -qxF "$SUBREPO/pkg" && ! grep -qF 'so the command runs in' "$WORK/e24.err"; then
  check "E24 once the bound chain is done, --evidence-run runs in the anchor again" PASS
else
  check "E24 once the bound chain is done, --evidence-run runs in the anchor again (rc=$RC_DONE)" FAIL
  printf '%s\n' "$OUT_DONE"
  cat "$WORK/e24.err"
fi

unit_check_done "E1z every unit file the registry gives this suite was graded"
finish
