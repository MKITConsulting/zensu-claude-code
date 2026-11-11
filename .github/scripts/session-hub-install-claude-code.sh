#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TOOL="${1:-}"
WANT="$(bash "$REPO_ROOT/.github/scripts/session-hub-claude-code-pin.sh" "$TOOL")" || {
  echo "::error::session-hub-install-claude-code.sh needs a Claude Code tool directory with an exact pin, got: ${TOOL:-<none>}"
  exit 1
}

DEST="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/claude-code-${TOOL##*/}-XXXXXX")"
DEST="$(cd "$DEST" && pwd -P)"
cp "$REPO_ROOT/$TOOL/package.json" "$REPO_ROOT/$TOOL/package-lock.json" "$DEST/"
(cd "$DEST" && npm ci --ignore-scripts --no-fund --no-audit)

SCRIPTED="$(node -e '
  const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const names = Object.entries(lock.packages || {}).filter(([, p]) => p.hasInstallScript).map(([k]) => k);
  process.stdout.write(names.join(" "));
' "$DEST/package-lock.json")"
if [ "$SCRIPTED" != "node_modules/@anthropic-ai/claude-code" ]; then
  echo "::error::$TOOL/package-lock.json gives an install script to: ${SCRIPTED:-<none>}; only @anthropic-ai/claude-code may carry one"
  exit 1
fi
(cd "$DEST" && node node_modules/@anthropic-ai/claude-code/install.cjs)

BIN="$DEST/node_modules/.bin"
FOUND="$(env DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$BIN/claude" --version < /dev/null)"
if [ "$FOUND" != "$WANT (Claude Code)" ]; then
  echo "::error::$TOOL installed Claude Code \"$FOUND\", not $WANT"
  exit 1
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$BIN" >> "$GITHUB_PATH"
fi
echo "Claude Code $WANT installed from $TOOL/package-lock.json into $BIN"
