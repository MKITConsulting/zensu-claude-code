#!/bin/bash
set -euo pipefail

TOOL="${1:-}"
case "$TOOL" in
  (.github/tools/claude-code|.github/tools/claude-code-floor) ;;
  (*)
    echo "::error::usage: session-hub-claude-code-pin.sh .github/tools/claude-code|.github/tools/claude-code-floor, got: ${TOOL:-<none>}" >&2
    exit 1
    ;;
esac
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const v = (m.dependencies || {})["@anthropic-ai/claude-code"];
  if (typeof v !== "string" || !/^[0-9]+\.[0-9]+\.[0-9]+$/.test(v)) process.exit(1);
  process.stdout.write(v);
' "$REPO_ROOT/$TOOL/package.json" || {
  echo "::error::$TOOL/package.json pins no exact @anthropic-ai/claude-code version" >&2
  exit 1
}
