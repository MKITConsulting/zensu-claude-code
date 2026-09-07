#!/bin/bash
# E2E eval for the plan-approval PostToolUse hook on ExitPlanMode.
# Drives an interactive Claude Code session via expect, approves the
# presented plan, then asserts the hook's behavior in the resulting output.

set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$EVAL_DIR/results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
mkdir -p "$RESULTS_DIR"

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 1; }
}
require expect
require claude

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

# EXTRACTED BY TEXT: D31/D32 in tests/structure/test-plan-approved-delegate.sh pull
# these three helpers out with `sed -n '/^name()/p'` and source them on their own,
# because this file cannot be sourced (it `require`s expect and claude above and
# then drives a real session). They must stay SINGLE-LINE definitions at column 0.
# A reformat is caught loudly — the extraction count arm names it — not silently.
strip_ansi()   { sed -E "s/\x1b\[[0-9;]*[A-Za-z]//g; s/\[[0-9]+[A-Z]//g; s/\[[?][0-9;]+[hl]//g" "$1"; }
contains()     { strip_ansi "$1" | grep -qiE "$2" && echo PASS || echo FAIL; }
not_contains() { strip_ansi "$1" | grep -qiE "$2" && echo FAIL || echo PASS; }
# A not_contains assertion is satisfied by an EMPTY transcript, so every absence
# check in this file is gated on evidence that the session actually produced one.
nonempty()     { [ -s "$1" ] && echo PASS || echo FAIL; }

# Resolve the subprocess watchdog ONCE. `timeout` is GNU coreutils and is absent
# on a base macOS install; `gtimeout` is the spelling a Homebrew coreutils install
# puts on PATH. Neither was required at the top of this file, so on such a host
# both expect invocations below exited 127 before doing anything, `|| true`
# swallowed it, every transcript stayed empty — and each not_contains assertion
# then reported PASS over a session that never started. Measured on base macOS:
# both binaries MISSING. The expect scripts bound themselves (`set timeout 90` and
# `set timeout 240`), so running without the outer wrapper is safe; running
# without SAYING SO is not.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout"
fi
run_bounded() { # $1 seconds, rest: the command to run
  local secs="$1"; shift
  # Zero-argument guard, the same one hooks/lib/zensu-bounded-run.sh carries: with
  # no command left after the shift, `"$@"` expands to nothing and the wrapper
  # becomes a SILENT no-op whose caller then grades an empty transcript. Both call
  # sites below pass a command, so this is latent — but the property must not
  # depend on every future caller getting it right.
  [ "$#" -gt 0 ] || return 1
  if [ -n "$TIMEOUT_CMD" ]; then "$TIMEOUT_CMD" "$secs" "$@"; else "$@"; fi
}

echo "=== Plan-Approval Hook Eval: $TIMESTAMP ===" | tee "$REPORT"
# The watchdog disclosure is emitted AFTER the header, because that header write is
# a truncating `tee` — announcing the unwrapped fallback above it wrote the NOTE
# into a file the next line erased, on exactly the host the fallback exists for.
if [ -z "$TIMEOUT_CMD" ]; then
  echo "  NOTE  no timeout/gtimeout on PATH — the expect scripts' own 'set timeout' is the only bound" | tee -a "$REPORT"
fi

# Plugin root = parent of evals/. expect scripts pass it as --plugin-dir
# so claude loads our LOCAL hooks/hooks.json instead of the marketplace cache.
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
echo "Plugin dir: $PLUGIN_DIR" | tee -a "$REPORT"
cd "$PLUGIN_DIR"

# ─── Test 1: Doc-only plan → escape-hatch (fast-path, NO TDD question) ──────
echo "" | tee -a "$REPORT"
echo "▸ Test 1: Doc-only plan (escape-hatch path)" | tee -a "$REPORT"
DOC_OUT="$RESULTS_DIR/doc-${TIMESTAMP}.out"
DOC_LOG="$RESULTS_DIR/doc-${TIMESTAMP}.debug.log"
run_bounded 180 "$EVAL_DIR/test-doc-plan.exp" "$DOC_LOG" "$PLUGIN_DIR" > "$DOC_OUT" 2>&1 || true
DOC_RAN="$(nonempty "$DOC_LOG")"
check "T1.0 the driven session produced a debug log" "$DOC_RAN"

# Deterministic assertions read from the debug log (TUI output is brittle).
# The debug log records "Hooks: Processing prompt hook with prompt: <text>"
# verbatim when a prompt-type hook fires.
check "T1.1 Plugin loaded hooks.json"        "$(contains "$DOC_LOG" "Loaded hooks.*plugin zensu")"
check "T1.2 Hook fired on approval"           "$(contains "$DOC_LOG" "Hook PostToolUse:ExitPlanMode|provided additionalContext")"
check "T1.3 ExitPlanMode tool succeeded"      "$(contains "$DOC_LOG" "tool=ExitPlanMode.*outcome=ok")"
check "T1.4 Escape-hatch path indicated"      "$(contains "$DOC_LOG" "Skipping TDD|escape.?hatch|doc.only|README|CHANGELOG|markdown only|non-executable")"
if [ "$DOC_RAN" = PASS ]; then
  check "T1.5 No tdd-manager Agent dispatch"  "$(not_contains "$DOC_LOG" "source=agent:custom:zensu:tdd-manager")"
else
  check "T1.5 (not graded: T1.0 did not pass — empty transcript, nothing was measured)" FAIL
fi

# ─── Test 2: Code-change plan → ask the route, then /zensu:tdd on that label ─────
echo "" | tee -a "$REPORT"
echo "▸ Test 2: Code-change plan (delegation path)" | tee -a "$REPORT"
CODE_OUT="$RESULTS_DIR/code-${TIMESTAMP}.out"
CODE_LOG="$RESULTS_DIR/code-${TIMESTAMP}.debug.log"
mkdir -p "$EVAL_DIR/fixtures"
[ -f "$EVAL_DIR/fixtures/sample.ts" ] || echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"
run_bounded 360 "$EVAL_DIR/test-code-plan.exp" "$CODE_LOG" "$PLUGIN_DIR" > "$CODE_OUT" 2>&1 || true
T2_0_VERDICT="$(nonempty "$CODE_LOG")"
check "T2.0 the driven session produced a debug log" "$T2_0_VERDICT"

check "T2.1 Plugin loaded hooks.json"        "$(contains "$CODE_LOG" "Loaded hooks.*plugin zensu")"
check "T2.2 Hook fired on approval"           "$(contains "$CODE_LOG" "Hook PostToolUse:ExitPlanMode|provided additionalContext")"
check "T2.3 ExitPlanMode tool succeeded"      "$(contains "$CODE_LOG" "tool=ExitPlanMode.*outcome=ok")"
T2_4_VERDICT="$(contains "$CODE_OUT" "Executing via /zensu:tdd")"
check "T2.4 /zensu:tdd skill execution indicated" "$T2_4_VERDICT"
# T2.6 grades rendered OPTION LABELS, not the bare phrase "implement directly":
# that substring also matches a model which SKIPPED the question and narrated its
# intent ("I'll implement directly and then add the tests"), and this check is
# named for the question having been ASKED. Two labels are required so a
# two-option question cannot satisfy it either. Both are labels the expect script
# never types, so this still measures the rendered question rather than the
# harness's own send_user trace.
if [ "$(contains "$CODE_OUT" "No — implement directly")" = PASS ] \
  && [ "$(contains "$CODE_OUT" "Zensu workflow — /zensu:tdd")" = PASS ]; then
  check "T2.6 the four-route question was actually asked" PASS
else
  check "T2.6 the four-route question was actually asked" FAIL
fi
# T2.7/T2.8 are ABSENCE assertions and not_contains returns PASS on absence, while
# the expect script above runs under `timeout ... || true` and its own timeout arm
# only prints and falls through. A run that died before the question ever rendered
# therefore reported both green — the two checks that read as the outward-facing
# safety evidence were PASS precisely when the property was not exercised. Gate
# them on the routing signal: with no T2.4 there was no run to judge, and a
# not-graded arm is recorded as FAIL, never as PASS.
if [ "$T2_4_VERDICT" = PASS ]; then
  check "T2.7 no outward-facing route taken" "$(not_contains "$CODE_OUT" "Executing via /zensu:autopilot")"
  check "T2.8 no pilot route taken" "$(not_contains "$CODE_OUT" "Executing via /zensu:pilot")"
else
  check "T2.7 (not graded: T2.4 did not pass — no routing signal, nothing was measured)" FAIL
  check "T2.8 (not graded: T2.4 did not pass — no routing signal, nothing was measured)" FAIL
fi
# T2.5 is an ABSENCE assertion too. It inlines its own grep instead of calling
# not_contains, which is how it escaped the first sweep — but an empty or missing
# $CODE_LOG satisfies it exactly the same way, so it is gated on T2.0 like the rest.
if [ "$T2_0_VERDICT" = PASS ]; then
  check "T2.5 No doc-only escape-hatch"       "$(grep -v 'additionalContext' "$CODE_LOG" | grep -qiE 'Skipping TDD' && echo FAIL || echo PASS)"
else
  check "T2.5 (not graded: T2.0 did not pass — empty transcript, nothing was measured)" FAIL
fi

# Reset fixtures + README marker so repeat runs are deterministic.
echo "export const noop = () => {};" > "$EVAL_DIR/fixtures/sample.ts"
rm -f "$EVAL_DIR/fixtures/sample.test."*
# Doc-only test asks Claude to add an HTML comment marker to README.md.
# Strip it back out so the repo stays clean between runs.
if grep -q '<!-- hook-eval-marker -->' "$PLUGIN_DIR/README.md" 2>/dev/null; then
  sed -i.bak '/<!-- hook-eval-marker -->/d' "$PLUGIN_DIR/README.md"
  rm -f "$PLUGIN_DIR/README.md.bak"
fi

echo "" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"
echo "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)" | tee -a "$REPORT"
echo "  Report: $REPORT" | tee -a "$REPORT"
echo "════════════════════════════════════════" | tee -a "$REPORT"

[ "$FAIL_COUNT" -eq 0 ]
