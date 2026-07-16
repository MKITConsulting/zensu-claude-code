#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
PREFLIGHT="$EVAL_DIR/lib/release-preflight.sh"
RUNNER="$EVAL_DIR/run-eval.sh"
TEMPORARY="$(mktemp -d -t zensu-release-preflight-XXXXXX)"
trap 'rm -rf "$TEMPORARY"' EXIT

git -C "$TEMPORARY" init -q -b main 2>/dev/null || {
  git -C "$TEMPORARY" init -q
  git -C "$TEMPORARY" symbolic-ref HEAD refs/heads/main
}
git -C "$TEMPORARY" config user.name 'Zensu Preflight Eval'
git -C "$TEMPORARY" config user.email 'preflight@zensu.invalid'
printf 'seed\n' >"$TEMPORARY/tracked.txt"
git -C "$TEMPORARY" add tracked.txt
git -C "$TEMPORARY" -c commit.gpgsign=false commit -qm 'test: seed preflight repository'
REVISION="$(git -C "$TEMPORARY" rev-parse HEAD)"

bash "$PREFLIGHT" "$TEMPORARY" "$REVISION"
case "$REVISION" in *0) WRONG_REVISION="${REVISION%?}1" ;; *) WRONG_REVISION="${REVISION%?}0" ;; esac
if bash "$PREFLIGHT" "$TEMPORARY" "$WRONG_REVISION" >/dev/null 2>&1; then
  echo 'release preflight accepted a wrong source revision' >&2; exit 1
fi

printf 'untracked\n' >"$TEMPORARY/untracked.txt"
if bash "$PREFLIGHT" "$TEMPORARY" "$REVISION" >/dev/null 2>&1; then
  echo 'release preflight accepted an untracked runtime file' >&2; exit 1
fi
rm "$TEMPORARY/untracked.txt"

printf 'dirty\n' >>"$TEMPORARY/tracked.txt"
if bash "$PREFLIGHT" "$TEMPORARY" "$REVISION" >/dev/null 2>&1; then
  echo 'release preflight accepted a dirty tracked file' >&2; exit 1
fi
git -C "$TEMPORARY" checkout -- tracked.txt

MISSING_OUTPUT="$(env -u ZENSU_EXPECTED_SOURCE_ROOT -u ZENSU_EXPECTED_SOURCE_REVISION \
  bash "$RUNNER" live 2>&1 || true)"
printf '%s' "$MISSING_OUTPUT" | grep -q 'ZENSU_EXPECTED_SOURCE_ROOT is mandatory' \
  || { echo 'live runner did not fail closed on missing target and SHA' >&2; exit 1; }

CURRENT_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
WRONG_ROOT_OUTPUT="$(ZENSU_EXPECTED_SOURCE_ROOT="$TEMPORARY" ZENSU_EXPECTED_SOURCE_REVISION="$CURRENT_REVISION" \
  bash "$RUNNER" live 2>&1 || true)"
printf '%s' "$WRONG_ROOT_OUTPUT" | grep -q 'expected source root does not target this checkout' \
  || { echo 'live runner did not fail closed on a mistargeted root' >&2; exit 1; }

printf 'preflight-selftest.sh: PASS\n'
