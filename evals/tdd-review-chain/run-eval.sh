#!/bin/bash
# E2E eval for the SubagentStop review-chain hook.
#
# Tests the chain: zensu:tdd-manager finishes  ->  SubagentStop prompt-type
# hook fires  ->  main agent invokes @zensu:code-reviewer.
#
# Modes:
#   ./run-eval.sh              full suite (T1-T4)
#   ./run-eval.sh --self-check fast structural check (no Claude spawn)
#
# Tests:
#   T1 positive          — tdd-manager completion triggers code-reviewer dispatch
#   T2 isolation         — non-tdd-manager subagent does NOT trigger reviewer
#   T3 judge-pass        — hook prompt expansion preserves the literal tdd-manager→reviewer directive
#   T4 posttool          — empirical: report whether PostToolUse:Task fires after subagent return
#   T6 severity-route(C) — reviewer findings Critical/Important → dispatch tdd-manager (offline)
#   T7 severity-route(B) — reviewer findings Suggestions-only → no dispatch, present to user (offline)
#   T8 severity-route(A) — reviewer PASS / no findings → no dispatch (offline)
#
# Slow tests (T1, T2) spawn real interactive Claude sessions via expect and
# can take 2-8 minutes each. Run T3 + structural checks via --self-check.

set -u

export CLAUDE_PLUGIN_DATA="$(mktemp -d)"
cleanup() { rm -rf "$CLAUDE_PLUGIN_DATA"; }
trap cleanup EXIT

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
RESULTS_DIR="$EVAL_DIR/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
mkdir -p "$RESULTS_DIR"

MODE="${1:-full}"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}

check() {
  local label="$1" result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS  $label" | tee -a "$REPORT"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL  $label" | tee -a "$REPORT"
  fi
}

strip_ansi()   { sed -E "s/\x1b\[[0-9;]*[A-Za-z]//g; s/\[[0-9]+[A-Z]//g; s/\[[?][0-9;]+[hl]//g" "$1"; }
contains()     { strip_ansi "$1" | grep -qiE "$2" && echo PASS || echo FAIL; }
not_contains() { strip_ansi "$1" | grep -qiE "$2" && echo FAIL || echo PASS; }

echo "=== TDD Review-Chain Hook Eval: $TIMESTAMP ($MODE) ===" | tee "$REPORT"
echo "Plugin dir: $PLUGIN_DIR" | tee -a "$REPORT"
cd "$PLUGIN_DIR"

# ─── Structural pre-checks (always run) ────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ Structural checks" | tee -a "$REPORT"

if node -e 'JSON.parse(require("fs").readFileSync("hooks/hooks.json","utf8"))' 2>/dev/null; then
  check "hooks.json is valid JSON" PASS
else
  check "hooks.json is valid JSON" FAIL
fi

# Use the dedicated assertion helpers as authoritative checks.
if "$EVAL_DIR/assert-config.sh"            >/dev/null 2>&1; then check "assert-config.sh"            PASS; else check "assert-config.sh"            FAIL; fi
if "$EVAL_DIR/assert-agent.sh"             >/dev/null 2>&1; then check "assert-agent.sh"             PASS; else check "assert-agent.sh"             FAIL; fi
if "$EVAL_DIR/assert-version.sh"           >/dev/null 2>&1; then check "assert-version.sh"           PASS; else check "assert-version.sh"           FAIL; fi
if "$EVAL_DIR/assert-changelog.sh"          >/dev/null 2>&1; then check "assert-changelog.sh"          PASS; else check "assert-changelog.sh"          FAIL; fi
if "$EVAL_DIR/assert-severity-routing.sh"  >/dev/null 2>&1; then check "assert-severity-routing.sh"  PASS; else check "assert-severity-routing.sh"  FAIL; fi

# ─── T3 directive integrity (offline: script output inspection) ────
echo "" | tee -a "$REPORT"
echo "▸ T3 directive integrity (offline script-output check)" | tee -a "$REPORT"
SCRIPT="$PLUGIN_DIR/hooks/post-tdd-review-delegate.sh"
DIRECTIVE_OUT="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:tdd-manager","prompt":"x"}}' | "$SCRIPT" 2>/dev/null)"

if [ -z "$DIRECTIVE_OUT" ]; then
  check "T3.0 script emits output for tdd-manager" FAIL
else
  check "T3.0 script emits output for tdd-manager" PASS
fi
case "$DIRECTIVE_OUT" in
  *'"additionalContext"'*) check "T3.1 directive uses additionalContext (command-type)" PASS ;;
  *)                        check "T3.1 directive uses additionalContext (command-type)" FAIL ;;
esac
case "$DIRECTIVE_OUT" in
  *'zensu:code-reviewer'*) check "T3.2 directive names zensu:code-reviewer" PASS ;;
  *)                        check "T3.2 directive names zensu:code-reviewer" FAIL ;;
esac
case "$DIRECTIVE_OUT" in
  *"VERY NEXT TOOL CALL"*|*"STOP."*) check "T3.3 directive is imperative" PASS ;;
  *)                                  check "T3.3 directive is imperative" FAIL ;;
esac
SILENT_OUT="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:zensu-plm","prompt":"x"}}' | "$SCRIPT" 2>/dev/null)"
if [ -z "$SILENT_OUT" ]; then
  check "T3.4 script silent for non-tdd-manager subagent" PASS
else
  check "T3.4 script silent for non-tdd-manager subagent" FAIL
fi

# ─── T5 TDD logging contract (offline fixture-based) ───────────────
# Asserts assert-tdd-log-compliance.sh enforces the Per-Step Logging
# Contract and mtime Discipline Audit defined in agents/tdd-manager.md:
#   T5.1 good fixture — proper RED/IMPL/GREEN trio per step → PASS
#   T5.2 missing-red fixture — GREEN without prior RED → reject
#   T5.3 bulk-shortcut fixture — collective RED for many steps → reject
#   T5.4 test-after fixture — test mtime > impl mtime → reject (with --impl-dir)
#   T5.5 ordering fixture — GREEN before RED → reject (line-number ordering)
#   T5.6 grammar fixture — TDD-marker log without recognizable step entries → reject
#   T5.7 test-collision fixture — heuristic resolves test→impl file → WARN (no hard fail)
echo "" | tee -a "$REPORT"
echo "▸ T5 TDD logging contract (Per-Step + mtime audit, offline)" | tee -a "$REPORT"
COMPLIANCE_SCRIPT="$EVAL_DIR/assert-tdd-log-compliance.sh"

if "$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-good.log" >/dev/null 2>&1; then
  check "T5.1 good fixture passes compliance" PASS
else
  check "T5.1 good fixture passes compliance" FAIL
fi

if ! "$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-missing-red.log" >/dev/null 2>&1; then
  check "T5.2 missing-red fixture correctly rejected" PASS
else
  check "T5.2 missing-red fixture correctly rejected" FAIL
fi

if ! "$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-bulk-shortcut.log" >/dev/null 2>&1; then
  check "T5.3 bulk-shortcut fixture correctly rejected" PASS
else
  check "T5.3 bulk-shortcut fixture correctly rejected" FAIL
fi

# Re-seed mtimes deterministically — git does not preserve them across clones.
# Impl file must be OLDER than test file to trigger the test-after detection.
touch -t 202604171200 "$EVAL_DIR/fixtures/test-after-tree/Foo.java"
touch -t 202604171210 "$EVAL_DIR/fixtures/test-after-tree/FooTest.java"

if ! "$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-test-after.log" \
                          --impl-dir "$EVAL_DIR/fixtures/test-after-tree" >/dev/null 2>&1; then
  check "T5.4 test-after mtime fixture correctly rejected" PASS
else
  check "T5.4 test-after mtime fixture correctly rejected" FAIL
fi

# T5.5 — ordering enforcement: GREEN appearing before RED in the log file
# (existence-only checks would silently pass; the fix enforces line-number
# ordering RED < IMPL < GREEN per step).
if ! "$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-ordering.log" >/dev/null 2>&1; then
  check "T5.5 ordering fixture (GREEN before RED) correctly rejected" PASS
else
  check "T5.5 ordering fixture (GREEN before RED) correctly rejected" FAIL
fi

# T5.6 — grammar enforcement: TDD-marker log without recognizable step entries
# must be rejected with a clear "no step entries detected" message rather than
# silently passing (previous behavior: empty step list → exit 0).
T56_STDERR=$("$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-grammar.log" 2>&1 >/dev/null)
T56_EXIT=$?
if [ "$T56_EXIT" -ne 0 ] && echo "$T56_STDERR" | grep -q "no step entries detected"; then
  check "T5.6 grammar fixture (no recognizable steps) correctly rejected" PASS
else
  check "T5.6 grammar fixture (no recognizable steps) correctly rejected" FAIL
fi

# T5.7 — test-file/IMPL collision: heuristic falls back to wildcard match
# and resolves the "test" to the same impl file, neutralizing the mtime audit.
# The fix emits a WARN on stderr and skips the mtime check for that step.
# This is a positive-warning test: exit code must be 0 (no other violations)
# AND stderr must contain "cannot resolve test file".
T57_STDERR=$("$COMPLIANCE_SCRIPT" --log "$EVAL_DIR/fixtures/tdd-log-test-collision.log" \
                                  --impl-dir "$EVAL_DIR/fixtures/test-after-tree" 2>&1 >/dev/null)
T57_EXIT=$?
if [ "$T57_EXIT" -eq 0 ] && echo "$T57_STDERR" | grep -q "cannot resolve test file"; then
  check "T5.7 test-collision fixture emits WARN and exits 0" PASS
else
  check "T5.7 test-collision fixture emits WARN and exits 0" FAIL
fi

# ─── T6/T7/T8 severity-routing directive integrity (offline) ────────
# These tests verify the reviewer→tdd-manager severity-routing hook
# (hooks/post-review-tdd-delegate.sh). The script does not parse reviewer
# findings itself — it emits a directive that tells the main agent how to
# classify findings and choose between three response modes:
#   T6 (case C): ANY Critical OR Important present → spawn tdd-manager
#   T7 (case B): ONLY Suggestions / Minor / Nits → buffer for user, no spawn
#   T8 (case A): PASS / zero findings → reply 'No fixes needed'
# Each test asserts the trigger phrase for its case is present in the
# directive so the main agent has unambiguous routing instructions.
echo "" | tee -a "$REPORT"
echo "▸ T6/T7/T8 reviewer→tdd-manager severity-routing directive (offline)" | tee -a "$REPORT"
REVIEW_SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
REVIEW_OUT="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:code-reviewer","prompt":"x"}}' | "$REVIEW_SCRIPT" 2>/dev/null)"

if [ -z "$REVIEW_OUT" ]; then
  check "T6.0 severity-routing script emits output for code-reviewer" FAIL
  check "T6.1 case C dispatches zensu:tdd-manager (Critical+Important)" FAIL
  check "T7.1 case B presents Suggestions without spawning"            FAIL
  check "T8.1 case A 'No fixes needed' branch present"                  FAIL
else
  check "T6.0 severity-routing script emits output for code-reviewer" PASS

  # T6 — case C: Critical or Important → spawn tdd-manager
  case "$REVIEW_OUT" in
    *"Delegating critical+important findings"*"zensu:tdd-manager"*)
      check "T6.1 case C dispatches zensu:tdd-manager (Critical+Important)" PASS ;;
    *"zensu:tdd-manager"*"Delegating critical+important findings"*)
      check "T6.1 case C dispatches zensu:tdd-manager (Critical+Important)" PASS ;;
    *)
      check "T6.1 case C dispatches zensu:tdd-manager (Critical+Important)" FAIL ;;
  esac
  case "$REVIEW_OUT" in
    *"EXCLUDE all Suggestions"*|*"NOT auto-fixed"*|*"not auto-fixed"*)
      check "T6.2 case C excludes Suggestions from spec" PASS ;;
    *)
      check "T6.2 case C excludes Suggestions from spec" FAIL ;;
  esac

  # T7 — case B: ONLY Suggestions → no spawn, present to user
  case "$REVIEW_OUT" in
    *"No critical/important findings"*"suggestions only"*)
      check "T7.1 case B status line 'No critical/important findings — suggestions only'" PASS ;;
    *)
      check "T7.1 case B status line 'No critical/important findings — suggestions only'" FAIL ;;
  esac
  case "$REVIEW_OUT" in
    *"### Suggestions (not auto-fixed)"*)
      check "T7.2 case B presents Suggestions under '### Suggestions (not auto-fixed)' heading" PASS ;;
    *)
      check "T7.2 case B presents Suggestions under '### Suggestions (not auto-fixed)' heading" FAIL ;;
  esac
  case "$REVIEW_OUT" in
    *"do NOT spawn tdd-manager"*|*"do not spawn tdd-manager"*|*"Do NOT spawn"*)
      check "T7.3 case B explicitly forbids tdd-manager spawn for suggestions-only" PASS ;;
    *)
      check "T7.3 case B explicitly forbids tdd-manager spawn for suggestions-only" FAIL ;;
  esac

  # T8 — case A: PASS / zero findings → no spawn at all
  case "$REVIEW_OUT" in
    *"No fixes needed: review passed"*)
      check "T8.1 case A status line 'No fixes needed: review passed'" PASS ;;
    *)
      check "T8.1 case A status line 'No fixes needed: review passed'" FAIL ;;
  esac
  case "$REVIEW_OUT" in
    *"Do NOT spawn anything"*|*"do not spawn anything"*|*"do NOT spawn anything"*)
      check "T8.2 case A explicitly forbids spawning anything" PASS ;;
    *)
      check "T8.2 case A explicitly forbids spawning anything" FAIL ;;
  esac

  # Cross-case: the directive must define ALL THREE status lines so the
  # main agent picks the right one without ambiguity.
  case "$REVIEW_OUT" in
    *"Delegating critical+important findings"*"No critical/important findings"*"No fixes needed: review passed"*)
      check "T6/T7/T8 directive defines all three status lines in order" PASS ;;
    *)
      check "T6/T7/T8 directive defines all three status lines in order" FAIL ;;
  esac
fi

# Isolation: severity-routing script must stay silent for tdd-manager
# subagent input (the other PostToolUse:Agent hook handles that case).
REVIEW_SILENT="$(echo '{"tool_name":"Task","tool_input":{"subagent_type":"zensu:tdd-manager","prompt":"x"}}' | "$REVIEW_SCRIPT" 2>/dev/null)"
if [ -z "$REVIEW_SILENT" ]; then
  check "T6/T7/T8 isolation: severity-routing silent for tdd-manager input" PASS
else
  check "T6/T7/T8 isolation: severity-routing silent for tdd-manager input" FAIL
fi

if [ "$MODE" = "--self-check" ]; then
  echo "" | tee -a "$REPORT"
  echo "════════════════════════════════════════" | tee -a "$REPORT"
  echo "  SELF-CHECK: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
  echo "  Slow tests T1, T2 skipped; T4 data-probe skipped (run without --self-check for full suite)" | tee -a "$REPORT"
  echo "  Report: $REPORT" | tee -a "$REPORT"
  echo "════════════════════════════════════════" | tee -a "$REPORT"
  [ "$FAIL_COUNT" -eq 0 ]
  exit $?
fi

# ─── Slow tests need expect + claude ───────────────────────────────
require expect
require claude

# Reset fixtures for deterministic runs (drop test file the spec creates).
mkdir -p "$EVAL_DIR/fixtures"
echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"
rm -f "$EVAL_DIR/fixtures/sample.test.ts"

# ─── T1: positive review-chain ─────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "▸ T1 positive (tdd-manager → code-reviewer chain)" | tee -a "$REPORT"
T1_OUT="$RESULTS_DIR/t1-${TIMESTAMP}.out"
T1_LOG="$RESULTS_DIR/t1-${TIMESTAMP}.debug.log"
timeout 480 "$EVAL_DIR/test-tdd-positive.exp" "$T1_LOG" "$PLUGIN_DIR" > "$T1_OUT" 2>&1 || true

check "T1.1 plugin loaded hooks.json"                "$(contains "$T1_LOG" "Loaded hooks.*plugin zensu")"
check "T1.2 PostToolUse:Agent hook fired"            "$(contains "$T1_LOG" "Hook PostToolUse:Agent.*success|PostToolUse.*post-tdd-review-delegate.*provided additionalContext")"
check "T1.3 main agent dispatched code-reviewer"     "$(contains "$T1_LOG" "subagent_type.*zensu:code-reviewer|tool_name.*Task.*code-reviewer|agent_type.*zensu:code-reviewer")"
check "T1.4 SubagentStop fired for code-reviewer"    "$(contains "$T1_LOG" "Hook SubagentStop.*zensu:code-reviewer|SubagentStop.*matcher.*code-reviewer|agent_type.*zensu:code-reviewer")"
check "T1.5 reviewer produced report (debug log)"    "$(contains "$T1_LOG" "Code Review Report|review.*report|Findings.*[0-9]|Verdict.*PASS|Verdict.*NEEDS")"

# ─── T2: isolation (non-tdd-manager must NOT trigger chain) ────────
echo "" | tee -a "$REPORT"
echo "▸ T2 isolation (zensu-plm spawn must NOT trigger reviewer)" | tee -a "$REPORT"
T2_OUT="$RESULTS_DIR/t2-${TIMESTAMP}.out"
T2_LOG="$RESULTS_DIR/t2-${TIMESTAMP}.debug.log"
timeout 240 "$EVAL_DIR/test-tdd-isolation.exp" "$T2_LOG" "$PLUGIN_DIR" > "$T2_OUT" 2>&1 || true

check "T2.1 plugin loaded hooks.json"          "$(contains "$T2_LOG" "Loaded hooks.*plugin zensu")"
check "T2.2 directive NOT injected for plm"    "$(not_contains "$T2_LOG" "VERY NEXT TOOL CALL.*zensu:code-reviewer")"
check "T2.3 reviewer NOT dispatched"           "$(not_contains "$T2_LOG" "subagent_type.*zensu:code-reviewer|tool_name.*Task.*code-reviewer")"

# ─── T9: TDD compliance E2E (real spawn → assert log compliance) ───
# Spawns a real zensu:tdd-manager run that should add TWO functions via
# two RED→IMPL→GREEN cycles, then validates the produced log file with
# assert-tdd-log-compliance.sh. Slow-lane only — skipped by --self-check
# (which already gates this above via the early exit).
echo "" | tee -a "$REPORT"
echo "▸ T9 TDD compliance E2E (real spawn, asserts log compliance)" | tee -a "$REPORT"
T9_OUT="$RESULTS_DIR/t9-${TIMESTAMP}.out"
T9_LOG="$RESULTS_DIR/t9-${TIMESTAMP}.debug.log"
timeout 600 "$EVAL_DIR/test-tdd-compliance.exp" "$T9_LOG" "$PLUGIN_DIR" > "$T9_OUT" 2>&1 || true

# Pick the most recent tdd-manager log produced during the spawn.
GENERATED_LOG=$(ls -t "$PLUGIN_DIR"/.zensu/logs/*_tdd-*.log 2>/dev/null | head -1)
if [ -z "$GENERATED_LOG" ]; then
  check "T9.1 tdd-manager produced a log file"        FAIL
  check "T9.2 generated log passes compliance check"  FAIL
else
  check "T9.1 tdd-manager produced a log file"        PASS
  if "$COMPLIANCE_SCRIPT" --log "$GENERATED_LOG" --impl-dir "$EVAL_DIR/fixtures" >/dev/null 2>&1; then
    check "T9.2 generated log passes compliance check" PASS
  else
    check "T9.2 generated log passes compliance check" FAIL
  fi
fi

# ─── T4: empirical PostToolUse:Task probe (data report only) ───────
echo "" | tee -a "$REPORT"
echo "▸ T4 PostToolUse:Task empirical probe (data report)" | tee -a "$REPORT"
echo "  SKIP: T4 implementation pending — fabricated CLAUDE_PLUGIN_ROOT_OVERRIDE"  | tee -a "$REPORT"
echo "        env var has no Claude consumer; experiment hook never loads."         | tee -a "$REPORT"
echo "        Re-enable once stacked --plugin-dir or temp hook injection lands."     | tee -a "$REPORT"

echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"

# Post-run cleanup: revert fixtures so repeat runs + commits stay clean.
echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"
rm -f "$EVAL_DIR/fixtures/sample.test."*

[ "$FAIL_COUNT" -eq 0 ]
