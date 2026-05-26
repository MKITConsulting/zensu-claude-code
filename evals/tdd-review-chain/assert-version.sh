#!/bin/bash
# Asserts plugin.json carries a valid semver version string.
# Intentionally version-agnostic: this eval ships with the plugin and the
# version moves with every release, so a hardcoded pin would rot immediately.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$PLUGIN_DIR/.claude-plugin/plugin.json"

VERSION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$MANIFEST")"

if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "  PASS  plugin.json version is valid semver: $VERSION"
  exit 0
else
  echo "  FAIL  plugin.json version is not semver-shaped: '$VERSION'"
  exit 1
fi
