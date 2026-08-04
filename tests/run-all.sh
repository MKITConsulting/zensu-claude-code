#!/bin/bash
# Master test runner for the zensu plugin.
#
#   (no arg)      DETERMINISTIC suites only — no API spend:
#                   - every tests/structure/test-*.sh
#                   - evals/config-gate/run-eval.sh --self-check (~60 offline gate evals)
#                   - evals/session-control/run-self-check.sh (Promptfoo contract/wrapper checks)
#                   - evals/tdd-review-chain/run-self-check.sh
#                   - evals/reset-review-limit/run-self-check.sh
#   --ci          deterministic non-Promptfoo suites used by GitHub Actions.
#                 Promptfoo suites are local-only and are intentionally skipped.
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
LOCAL_ONLY_MANIFEST="$TESTS_DIR/profiles/promptfoo-local-only.v1.json"

case "$MODE" in
  ""|--ci|--self-check|--live) ;;
  *)
    printf "unknown mode '%s' — accepted: (no arg), --ci, --self-check, --live\n" "$MODE" >&2
    exit 2
    ;;
esac

load_local_only_inventory() {
  local field="$1"
  node - "$LOCAL_ONLY_MANIFEST" "$field" <<'NODE'
const fs = require('node:fs');
const [file, field] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
if (value.schemaVersion !== 1 || !Array.isArray(value[field])
    || value[field].some((entry) => typeof entry !== 'string' || entry.length === 0)) {
  throw new Error(`invalid Promptfoo local-only inventory field: ${field}`);
}
process.stdout.write(value[field].join('\n'));
NODE
}

CI_STRUCTURE="$(load_local_only_inventory ciStructureTests)" || exit 2
LOCAL_ONLY_STRUCTURE="$(load_local_only_inventory localStructureTests)" || exit 2

is_local_only() {
  local inventory="$1" entry="$2"
  printf '%s\n' "$inventory" | grep -Fxq -- "$entry"
}

node - "$ROOT" "$LOCAL_ONLY_MANIFEST" <<'NODE' || exit 2
const fs = require('node:fs');
const path = require('node:path');
const [root, file] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const uniqueSorted = (entries) => [...new Set(entries)].sort();
const actualStructure = fs.readdirSync(path.join(root, 'tests', 'structure'))
  .filter((name) => /^test-.*\.sh$/.test(name))
  .sort();
const classified = [...value.ciStructureTests, ...value.localStructureTests];
if (JSON.stringify(uniqueSorted(classified)) !== JSON.stringify(actualStructure)
    || classified.length !== new Set(classified).size
    || !Array.isArray(value.ciOfflineSuites)
    || value.ciOfflineSuites.some((suite) => !suite || typeof suite.label !== 'string'
      || typeof suite.path !== 'string' || !Array.isArray(suite.args)
      || !Array.isArray(suite.ciArgs)
      || typeof suite.needsNodeDeps !== 'boolean'
      || typeof suite.windowsSafety !== 'boolean'
      || suite.label.length === 0 || /[\t\r\n]/.test(suite.label)
      || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(suite.path)
      || [...suite.args, ...suite.ciArgs].some(
        (argument) => typeof argument !== 'string' || argument.length === 0
          || /[\t\r\n ]/.test(argument),
      )
      || !fs.existsSync(path.join(root, suite.path)))) {
  throw new Error('suite classification inventory is incomplete; refusing execution');
}
NODE

RESULTS_DIR="$TESTS_DIR/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/run-all-$TIMESTAMP.txt"

PASS=0; FAIL=0; HANG=0; BLOCKED=0
log() { printf "%s\n" "$1" | tee -a "$REPORT"; }

# Per-suite watchdog. GNU `timeout` is not present on macOS, so bound each suite
# with a portable poll on the child pid.
SUITE_TIMEOUT="${ZENSU_SUITE_TIMEOUT:-3600}"

# Run a script; suite PASS iff exit 0. Streams the script's own output indented.
#
# Output goes to a FILE, never through a command substitution: `out="$(cmd)"`
# blocks until every writer closes the pipe, so one suite leaving a background
# child alive hangs the whole runner with no indication of which suite did it.
# A suite that outlives SUITE_TIMEOUT is reported as HANG — distinct from FAIL,
# because "never returned" and "asserted false" need different fixes.
run_suite() {
  local label="$1"; shift
  local out_file rc pid waited
  out_file="$(mktemp)" || { FAIL=$((FAIL+1)); log "  FAIL  $label — mktemp failed"; return; }

  "$@" >"$out_file" 2>&1 </dev/null &
  pid=$!
  waited=0
  while [ "$waited" -lt "$SUITE_TIMEOUT" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sed 's/^/      /' "$out_file" | tee -a "$REPORT" >/dev/null
    rm -f "$out_file"
    HANG=$((HANG + 1))
    log "  HANG  $label — no exit after ${SUITE_TIMEOUT}s, killed (a hang, not a failing assertion)"
    return
  fi

  wait "$pid"; rc=$?
  sed 's/^/      /' "$out_file" | tee -a "$REPORT" >/dev/null
  rm -f "$out_file"
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1)); log "  PASS  $label"
  else
    FAIL=$((FAIL+1)); log "  FAIL  $label (exit $rc)"
  fi
}

# Suites that need the npm devDependencies. Without node_modules they fail in a
# way that reads like a code regression, which is how three of them sat red and
# unexplained. Report them as BLOCKED with the command that fixes it — visibly
# not-run, never silently skipped.
NODE_DEPS_OK=1
[ -d "$ROOT/node_modules" ] || NODE_DEPS_OK=0
deps_ready() { [ "$NODE_DEPS_OK" -eq 1 ]; }
block_suite() {
  BLOCKED=$((BLOCKED + 1))
  log "  BLOCK $1 — needs the npm devDependencies; run: npm ci"
}

# Offline eval runners are part of the deterministic contract. A missing file
# is a failed suite, never an optional skip that can silently erase coverage.
# The canonical manifest also declares dependency requirements so local runs
# report missing npm devDependencies as BLOCKED rather than code regressions.
run_required_suite() {
  local label="$1" runner="$2"; shift 2
  local needs_deps="${NEEDS_NODE_DEPS:-0}"
  NEEDS_NODE_DEPS=0
  if [ "$needs_deps" -eq 1 ] && ! deps_ready; then
    block_suite "$label"
    return
  fi
  if [ -f "$runner" ]; then
    run_suite "$label" "$@"
  else
    FAIL=$((FAIL+1)); log "  FAIL  $label — runner missing at $runner"
  fi
}

offline_inventory() {
  node - "$LOCAL_ONLY_MANIFEST" "$MODE" <<'NODE'
const fs = require('node:fs');
const [file, mode] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
for (const suite of value.ciOfflineSuites) {
  const args = mode === '--ci' ? suite.ciArgs : suite.args;
  if (suite.label.length === 0 || /[\t\r\n]/.test(suite.label)
      || !/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(suite.path)
      || args.some((argument) => typeof argument !== 'string' || argument.length === 0
        || /[\t\r\n ]/.test(argument))) {
    throw new Error('offline suite inventory contains an unsafe field');
  }
  process.stdout.write(
    `${suite.label}\t${suite.path}\t${suite.needsNodeDeps ? '1' : '0'}\t${args.join(' ')}\n`,
  );
}
NODE
}

log "════════════════════════════════════════════════════════════"
log "  zensu plugin — run-all  ($TIMESTAMP)  mode=${MODE:-default}"
log "  plugin v$(node -e 'process.stdout.write(require(process.argv[1]).version)' -- "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo '?')"
log "════════════════════════════════════════════════════════════"

if ! deps_ready; then
  log ""
  log "  ⚠  node_modules is absent. Dependency-backed deterministic suites cannot run."
  log "     Fix with:  npm ci"
  log "     They are reported below as BLOCK, not as FAIL — a missing dependency"
  log "     is not a code regression."
fi

# ── Deterministic: structure tests ───────────────────────────────────
log ""
log "▸ Structure tests (deterministic)"
for t in "$TESTS_DIR"/structure/test-*.sh; do
  [ -f "$t" ] || continue
  base="$(basename "$t")"
  if [ "$MODE" = "--ci" ]; then
    if is_local_only "$LOCAL_ONLY_STRUCTURE" "$base"; then
      log "  LOCAL tests/structure/$base (Promptfoo local-only)"
      continue
    fi
    if ! is_local_only "$CI_STRUCTURE" "$base"; then
      FAIL=$((FAIL+1)); log "  FAIL  unclassified structure suite: $base"
      continue
    fi
  fi
  case "$base" in
    test-workflow-checkout-credentials.sh)
      deps_ready || { block_suite "structure/$base"; continue; }
      ;;
  esac
  run_suite "structure/$base" bash "$t"
done

# ── Deterministic: config-gate offline evals ─────────────────────────
log ""
log "▸ Offline evals"
export ZENSU_PRETOOL_SKIP_NESTED=1
OFFLINE_LINES="$(offline_inventory)" || exit 2
OFFLINE_EXPECTED="$(
  node -e 'process.stdout.write(String(require(process.argv[1]).ciOfflineSuites.length))' \
    "$LOCAL_ONLY_MANIFEST"
)" || exit 2
OFFLINE_EXECUTED=0
while IFS=$'\t' read -r label relative needs_deps argument_line; do
  [ -n "$label" ] || continue
  runner="$ROOT/$relative"
  case "$needs_deps" in
    0|1) ;;
    *) FAIL=$((FAIL+1)); log "  FAIL  $label — invalid dependency flag"; continue ;;
  esac
  suite_args=()
  if [ -n "$argument_line" ]; then
    read -r -a suite_args <<< "$argument_line"
  fi
  NEEDS_NODE_DEPS="$needs_deps"
  if [ -n "$argument_line" ]; then
    run_required_suite "$label" "$runner" bash "$runner" "${suite_args[@]}"
  else
    run_required_suite "$label" "$runner" bash "$runner"
  fi
  OFFLINE_EXECUTED=$((OFFLINE_EXECUTED + 1))
done <<< "$OFFLINE_LINES"
if [ "$OFFLINE_EXECUTED" -ne "$OFFLINE_EXPECTED" ]; then
  FAIL=$((FAIL+1))
  log "  FAIL  offline inventory executed $OFFLINE_EXECUTED/$OFFLINE_EXPECTED suites"
fi

# ── Live suites ──────────────────────────────────────────────────────
if [ "$MODE" = "--live" ]; then
  log ""
  log "▸ Live claude --print suites (API)"
  for s in e2e e2e-plm e2e-skills e2e-tdd e2e-context-nudge e2e-intent-router e2e-source-write-gate; do
    setup="$TESTS_DIR/$s/setup-fixtures.sh"
    [ -f "$setup" ] && bash "$setup" >/dev/null 2>&1
    run_suite "$s/run.sh (live)" bash "$TESTS_DIR/$s/run.sh"
  done
elif [ "$MODE" = "--self-check" ]; then
  log ""
  log "▸ Live suite skeletons (--self-check, no API)"
  for s in e2e e2e-plm e2e-skills e2e-tdd e2e-context-nudge e2e-intent-router e2e-source-write-gate; do
    run_suite "$s/run.sh (--self-check)" bash "$TESTS_DIR/$s/run.sh" --self-check
  done
fi

log ""
log "════════════════════════════════════════════════════════════"
log "  SUITES: $PASS passed / $FAIL failed / $HANG hung / $BLOCKED blocked"
if [ "$HANG" -gt 0 ]; then
  log "  A hung suite never returned within ${SUITE_TIMEOUT}s — it was killed."
  log "  Raise the bound with ZENSU_SUITE_TIMEOUT=<seconds> to confirm a slow"
  log "  suite, but a suite that hangs indefinitely is a defect in that suite."
fi
if [ "$BLOCKED" -gt 0 ]; then
  log "  $BLOCKED suite(s) did NOT run for want of the npm devDependencies."
  log "  Run 'npm ci', then re-run — this result does not certify them."
fi
log "  Report: $REPORT"
log "════════════════════════════════════════════════════════════"

# Blocked counts against the run: a suite that never executed must never read as
# a green result.
[ "$FAIL" -eq 0 ] && [ "$HANG" -eq 0 ] && [ "$BLOCKED" -eq 0 ]
