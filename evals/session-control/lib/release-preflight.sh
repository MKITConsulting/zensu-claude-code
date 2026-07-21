#!/bin/bash
set -euo pipefail

ROOT="${1:-}"
EXPECTED_REVISION="${2:-}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo 'release preflight: repository root is unavailable' >&2; exit 1; }
[ -n "$EXPECTED_REVISION" ] || { echo 'release preflight: expected source revision is mandatory' >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd -P)"
HEAD_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" \
  || { echo 'release preflight: repository has no HEAD revision' >&2; exit 1; }
[ "$HEAD_REVISION" = "$EXPECTED_REVISION" ] \
  || { echo 'release preflight: HEAD does not match the exact expected source revision' >&2; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain)" ] \
  || { echo 'release preflight: release requires a completely clean worktree' >&2; exit 1; }
