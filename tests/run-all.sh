#!/bin/bash
# Master test runner for the zensu plugin.
#
#   (no arg)      DETERMINISTIC suites only — no API spend:
#                   - every tests/structure/test-*.sh
#                   - evals/config-gate/run-eval.sh --self-check (~60 offline gate evals)
#   --self-check  deterministic suites + each live suite's --self-check skeleton (no API)
#   --live        deterministic suites + LIVE claude --print suites (COSTS API CREDITS):
#                   - tests/e2e          (code-reviewer guardrails)
#                   - tests/e2e-plm      (zensu-plm agent)
#                   - tests/e2e-skills   (zensu-help / plan-review / self-review / review-aspect)
#
# Exit 0 iff every selected suite passed. A "suite" = one script; it passes iff it
# exits 0. Per-script internal tallies are streamed; this runner tallies suites.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
MODE="${1:-}"

case "$MODE" in
  ""|--self-check|--live) ;;
  *)
    printf "unknown mode '%s' — accepted: (no arg), --self-check, --live\n" "$MODE" >&2
    exit 2
    ;;
esac

RESULTS_DIR="$TESTS_DIR/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/run-all-$TIMESTAMP.txt"

PASS=0; FAIL=0
log() { printf "%s\n" "$1" | tee -a "$REPORT"; }

# Run a script; suite PASS iff exit 0. Streams the script's own output indented.
run_suite() {
  local label="$1"; shift
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tee -a "$REPORT" >/dev/null
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1)); log "  PASS  $label"
  else
    FAIL=$((FAIL+1)); log "  FAIL  $label (exit $rc)"
  fi
}

log "════════════════════════════════════════════════════════════"
log "  zensu plugin — run-all  ($TIMESTAMP)  mode=${MODE:-default}"
log "  plugin v$(node -e 'process.stdout.write(require("'"$ROOT"'/.claude-plugin/plugin.json").version)' 2>/dev/null || echo '?')"
log "════════════════════════════════════════════════════════════"

# ── Deterministic: structure tests ───────────────────────────────────
log ""
log "▸ Structure tests (deterministic)"
for t in "$TESTS_DIR"/structure/test-*.sh; do
  [ -f "$t" ] || continue
  run_suite "structure/$(basename "$t")" bash "$t"
done

# ── Deterministic: config-gate offline evals ─────────────────────────
log ""
log "▸ Offline evals"
CG="$ROOT/evals/config-gate/run-eval.sh"
[ -f "$CG" ] && run_suite "evals/config-gate (--self-check)" bash "$CG" --self-check

# ── Live suites ──────────────────────────────────────────────────────
if [ "$MODE" = "--live" ]; then
  log ""
  log "▸ Live claude --print suites (API)"
  for s in e2e e2e-plm e2e-skills e2e-tdd e2e-context-nudge; do
    setup="$TESTS_DIR/$s/setup-fixtures.sh"
    [ -f "$setup" ] && bash "$setup" >/dev/null 2>&1
    run_suite "$s/run.sh (live)" bash "$TESTS_DIR/$s/run.sh"
  done
elif [ "$MODE" = "--self-check" ]; then
  log ""
  log "▸ Live suite skeletons (--self-check, no API)"
  for s in e2e e2e-plm e2e-skills e2e-tdd e2e-context-nudge; do
    run_suite "$s/run.sh (--self-check)" bash "$TESTS_DIR/$s/run.sh" --self-check
  done
fi

log ""
log "════════════════════════════════════════════════════════════"
log "  SUITES: $PASS passed / $FAIL failed"
log "  Report: $REPORT"
log "════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
