#!/bin/bash
# Asserts plugin.json version is bumped to 0.3.10.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"

VERSION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$MANIFEST")"

if [ "$VERSION" = "0.3.10" ]; then
  echo "  PASS  plugin.json version is 0.3.10"
  exit 0
else
  echo "  FAIL  plugin.json version is '$VERSION', expected '0.3.10'"
  exit 1
fi
