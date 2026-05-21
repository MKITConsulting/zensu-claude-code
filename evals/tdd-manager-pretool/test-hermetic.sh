#!/bin/bash
set -u
EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$EVAL_DIR/test-projects/react-go-fullstack"

cleanup() {
  rm -rf "$PROJECT_DIR/.zensu/state" "$PROJECT_DIR/.zensu/logs" 2>/dev/null || true
  cd "$PROJECT_DIR" && git checkout -- . 2>/dev/null || true
  cd "$PROJECT_DIR" && git clean -fd -- frontend/src/utils frontend/src/__tests__ backend/internal >/dev/null 2>&1 || true
}

ROUNDS="${1:-3}"
for i in $(seq 1 "$ROUNDS"); do
  echo "── hermetic round $i/$ROUNDS ──"
  cleanup
  bash "$EVAL_DIR/run-eval.sh" "${2:-full}"
done
