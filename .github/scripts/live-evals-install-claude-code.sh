#!/bin/bash
set -euo pipefail

PACKAGE='@anthropic-ai/claude-code'
WANT="$(npm view "$PACKAGE" version 2>/dev/null)" || {
  echo "::error::npm view could not resolve the newest $PACKAGE release"
  exit 1
}
if ! [[ "$WANT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::npm view reported no plain release version for $PACKAGE: ${WANT:-<none>}"
  exit 1
fi

DEST="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/claude-code-newest-XXXXXX")"
DEST="$(cd "$DEST" && pwd -P)"
node -e '
  const fs = require("fs");
  const [dir, name, version] = process.argv.slice(1);
  const manifest = { private: true, dependencies: { [name]: version } };
  fs.writeFileSync(dir + "/package.json", JSON.stringify(manifest, null, 2) + "\n");
' "$DEST" "$PACKAGE" "$WANT"
(cd "$DEST" && npm install --ignore-scripts --no-fund --no-audit)

SCRIPTED="$(node -e '
  const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const names = Object.entries(lock.packages || {}).filter(([, p]) => p.hasInstallScript).map(([k]) => k);
  process.stdout.write(names.join(" "));
' "$DEST/package-lock.json")"
if [ "$SCRIPTED" != "node_modules/@anthropic-ai/claude-code" ]; then
  echo "::error::the newest $PACKAGE ($WANT) gives an install script to: ${SCRIPTED:-<none>}; only $PACKAGE may carry one"
  exit 1
fi
FOREIGN="$(node -e '
  const lock = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const names = Object.entries(lock.packages || {})
    .filter(([key, p]) => key !== "" && !String(p.resolved || "").startsWith("https://registry.npmjs.org/@anthropic-ai/claude-code"))
    .map(([key]) => key);
  process.stdout.write(names.join(" "));
' "$DEST/package-lock.json")"
if [ -n "$FOREIGN" ]; then
  echo "::error::the newest $PACKAGE ($WANT) pulls packages that are not $PACKAGE packages on the npm registry: $FOREIGN"
  exit 1
fi
(cd "$DEST" && node node_modules/@anthropic-ai/claude-code/install.cjs)

PUBLISH="$DEST/path"
mkdir "$PUBLISH"
ln -s "$DEST/node_modules/.bin/claude" "$PUBLISH/claude"
FOUND="$(env DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$PUBLISH/claude" --version < /dev/null)"
if [ "$FOUND" != "$WANT (Claude Code)" ]; then
  echo "::error::the newest $PACKAGE installed as \"$FOUND\", not $WANT"
  exit 1
fi
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$PUBLISH" >> "$GITHUB_PATH"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'version=%s\n' "$WANT" >> "$GITHUB_OUTPUT"
fi
echo "Claude Code $WANT, the newest release, installed; $PUBLISH puts only its claude command on PATH"
