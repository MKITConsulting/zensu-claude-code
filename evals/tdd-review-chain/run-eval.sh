#!/bin/bash
# Compatibility entrypoint for the current deterministic main-thread contract.
# The retired tdd-manager live-spawn experiment is intentionally gone.
set -u

case "${1:-}" in
  ""|--self-check) exec bash "$(cd "$(dirname "$0")" && pwd -P)/run-self-check.sh" ;;
  *) echo "usage: run-eval.sh [--self-check]" >&2; exit 2 ;;
esac
