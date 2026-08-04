#!/bin/bash
# Deterministic current-contract self-check; no Claude spawn and no API spend.
set -u

DIR="$(cd "$(dirname "$0")" && pwd -P)"
PASS=0; FAIL=0
run() {
  if bash "$1" >/dev/null 2>&1; then
    echo "  PASS  $(basename "$1")"; PASS=$((PASS+1))
  else
    echo "  FAIL  $(basename "$1")"; FAIL=$((FAIL+1))
  fi
}

run "$DIR/assert-config.sh"
run "$DIR/assert-agent.sh"
run "$DIR/assert-version.sh"
run "$DIR/assert-changelog.sh"
run "$DIR/assert-severity-routing.sh"

COMPLIANCE="$DIR/assert-tdd-log-compliance.sh"
if bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-good.log" >/dev/null 2>&1 \
  && ! bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-missing-red.log" >/dev/null 2>&1 \
  && ! bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-bulk-shortcut.log" >/dev/null 2>&1 \
  && ! bash "$COMPLIANCE" --log "$DIR/fixtures/tdd-log-ordering.log" >/dev/null 2>&1; then
  echo "  PASS  assert-tdd-log-compliance fixtures"; PASS=$((PASS+1))
else
  echo "  FAIL  assert-tdd-log-compliance fixtures"; FAIL=$((FAIL+1))
fi

# --impl-dir path: exercises the mtime audit AND the " | " commentary strip the
# logging contract allows. Without this arm the strip is only ever text-pinned.
IMPL_TMP=""
trap 'rm -rf "${IMPL_TMP:-}"' EXIT
trap 'rm -rf "${IMPL_TMP:-}"; exit 130' INT TERM
IMPL_TMP="$(mktemp -d)" || IMPL_TMP=""
if [ -n "$IMPL_TMP" ] && [ -d "$IMPL_TMP" ]; then
  # Two SEPARATE roots: the checker resolves the test file with `find` over the
  # whole --impl-dir tree, so a nested second fixture would poison the first.
  mkdir -p "$IMPL_TMP/ok/src" "$IMPL_TMP/after/src"
  printf 'test\n' > "$IMPL_TMP/ok/src/WidgetTest.java"
  sleep 1
  printf 'impl\n' > "$IMPL_TMP/ok/src/Widget.java"
  LOGF="$IMPL_TMP/2026-01-01-0000_tdd-widget.log"
  {
    printf '[00:00:00] TDD STARTED — Widget | steps: 1\n'
    printf '[00:00:01] EXECUTION STARTED\n'
    printf '[00:00:02] BE-1 RED WidgetTest — FAIL: class Widget does not exist\n'
    printf '[00:00:03] BE-1 IMPL completed — files: src/Widget.java | extracted the parser\n'
    printf '[00:00:04] BE-1 GREEN — PASS (1 attempt, 1 test)\n'
    printf '[00:00:05] TDD COMPLETE — 1/1 GREEN | Integration: 0 WIRED | 1/1 tests pass\n'
  } > "$LOGF"
  # Discriminating arm: a test-after violation is only DETECTED when the
  # commentary is stripped and the path resolves. Without the strip the file
  # never resolves and the step is silently skipped — which would pass a
  # positive-only check, so the negative case is the one that matters.
  printf 'impl\n' > "$IMPL_TMP/after/src/Widget.java"
  sleep 1
  printf 'test\n' > "$IMPL_TMP/after/src/WidgetTest.java"
  LOGF_AFTER="$IMPL_TMP/2026-01-01-0001_tdd-widget-after.log"
  cp "$LOGF" "$LOGF_AFTER"
  AFTER_OUT="$(bash "$COMPLIANCE" --log "$LOGF_AFTER" --impl-dir "$IMPL_TMP/after" 2>&1)"
  AFTER_RC=$?
  if bash "$COMPLIANCE" --log "$LOGF" --impl-dir "$IMPL_TMP/ok" >/dev/null 2>&1 \
    && [ "$AFTER_RC" -eq 1 ] \
    && printf '%s' "$AFTER_OUT" | grep -qF "is test-after"; then
    echo "  PASS  assert-tdd-log-compliance --impl-dir resolves paths past ' | ' commentary"; PASS=$((PASS+1))
  else
    echo "  FAIL  assert-tdd-log-compliance --impl-dir resolves paths past ' | ' commentary"; FAIL=$((FAIL+1))
  fi
else
  echo "  FAIL  assert-tdd-log-compliance --impl-dir (mktemp failed)"; FAIL=$((FAIL+1))
fi

echo "----"
echo "tdd-review-chain self-check: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
