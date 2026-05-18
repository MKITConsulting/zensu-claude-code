#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"

FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
EXPECTED_DIR="${EXPECTED_DIR:-$EVAL_DIR/expected}"
RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results}"
mkdir -p "$RESULTS_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"

MODE="${1:-full}"

case "$MODE" in
  --self-check|--offline|""|full) ;;
  *)
    mkdir -p "$RESULTS_DIR"
    printf "  FAIL  unknown mode '%s' — accepted: --self-check, --offline, (no arg / full)\n" "$MODE" | tee -a "$REPORT" >&2
    exit 2
    ;;
esac

PASS_COUNT=0
FAIL_COUNT=0
TOTAL=0

log() {
  printf "%s\n" "$1" | tee -a "$REPORT"
}

check() {
  local label="$1" result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "PASS" ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    log "  PASS  $label"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "  FAIL  $label"
  fi
}

match_pattern() {
  local pattern_file="$1" captured_file="$2"
  [ -f "$pattern_file" ] || return 1
  [ -f "$captured_file" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      "# "*) continue ;;
    esac
    if ! grep -Eqi -- "$line" "$captured_file"; then
      return 1
    fi
  done < "$pattern_file"
  return 0
}

invoke_reviewer() {
  local fixture_dir="$1" captured_file="$2"
  local fixture_name
  fixture_name="$(basename "$fixture_dir")"

  local changed=""
  if [ -d "$fixture_dir/.git" ]; then
    changed="$(cd "$fixture_dir" && git diff --name-only main..feature 2>/dev/null | tr '\n' ' ')"
  fi

  local claim_context=""
  if [ -f "$fixture_dir/tdd-claim.txt" ]; then
    claim_context=" Context: $(cat "$fixture_dir/tdd-claim.txt")"
  fi

  local prompt="Files changed: [${changed}].${claim_context}"

  (
    cd "$fixture_dir" 2>/dev/null || cd "$EVAL_DIR" || exit 1
    claude --print --plugin-dir "$PLUGIN_DIR" --agent code-reviewer --permission-mode bypassPermissions "$prompt"
  ) > "$captured_file" 2>&1
}

log "=== Reviewer/tdd-manager Anti-Loop Guardrails E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"
log "Fixtures:   $FIXTURES_DIR"

if [ ! -d "$FIXTURES_DIR" ]; then
  log "  (no fixtures directory at $FIXTURES_DIR — treating as empty)"
fi

log ""
log "▸ Fixture evaluations"

if [ -d "$FIXTURES_DIR" ]; then
  for fixture in "$FIXTURES_DIR"/*/; do
    [ -d "$fixture" ] || continue
    fixture_name="$(basename "$fixture")"
    pattern_file="$EXPECTED_DIR/${fixture_name}.pattern"

    captured_file=""
    case "$MODE" in
      --self-check)
        continue
        ;;
      --offline)
        captured_file="$(ls -t "$RESULTS_DIR/${fixture_name}-"*.captured.txt 2>/dev/null | head -1)"
        if [ -z "$captured_file" ] || [ ! -f "$captured_file" ]; then
          check "$fixture_name (no prior capture in $RESULTS_DIR matching ${fixture_name}-*.captured.txt)" FAIL
          continue
        fi
        ;;
      ""|full)
        captured_file="$RESULTS_DIR/${fixture_name}-${TIMESTAMP}.captured.txt"
        invoke_reviewer "$fixture" "$captured_file"
        ;;
    esac

    if [ ! -s "$captured_file" ]; then
      check "$fixture_name (zero-byte capture — claude --print produced no output)" FAIL
      continue
    fi

    if [ ! -f "$pattern_file" ]; then
      check "$fixture_name (missing pattern file $pattern_file)" FAIL
      continue
    fi

    if match_pattern "$pattern_file" "$captured_file"; then
      check "$fixture_name" PASS
    else
      check "$fixture_name" FAIL
    fi
  done
fi

log ""
log "════════════════════════════════════════"
log "  TOTAL: $PASS_COUNT/$TOTAL PASS ($FAIL_COUNT FAIL)"
log "  Report: $REPORT"
log "════════════════════════════════════════"

[ "$FAIL_COUNT" -eq 0 ]
