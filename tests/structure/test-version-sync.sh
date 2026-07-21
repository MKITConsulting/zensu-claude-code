#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
README="$ROOT/README.md"
CHANGELOG="$ROOT/CHANGELOG.md"
EXPECTED_VERSION="${1:-}"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

for file in "$PLUGIN" "$MARKETPLACE" "$README" "$CHANGELOG"; do
  [ -f "$file" ] && [ ! -L "$file" ] \
    && check "$(basename "$file") is a real file" PASS \
    || check "$(basename "$file") is a real file" FAIL
done

PLUGIN_VERSION="$(jq -er '.version' "$PLUGIN" 2>/dev/null || true)"
MARKETPLACE_VERSION="$(jq -er '.plugins | select(length == 1) | .[0].version' "$MARKETPLACE" 2>/dev/null || true)"
MARKETPLACE_REF="$(jq -er '.plugins[0].source.ref' "$MARKETPLACE" 2>/dev/null || true)"

[[ "$PLUGIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  && check "Plugin version is strict SemVer" PASS \
  || check "Plugin version is strict SemVer" FAIL

[ "$MARKETPLACE_VERSION" = "$PLUGIN_VERSION" ] \
  && check "Marketplace version matches plugin version" PASS \
  || check "Marketplace version matches plugin version" FAIL

[ "$MARKETPLACE_REF" = "v$PLUGIN_VERSION" ] \
  && check "Marketplace source ref matches plugin version" PASS \
  || check "Marketplace source ref matches plugin version" FAIL

if [ -z "$EXPECTED_VERSION" ] || [ "$PLUGIN_VERSION" = "$EXPECTED_VERSION" ]; then
  check "Plugin version matches the requested release version" PASS
else
  check "Plugin version matches the requested release version" FAIL
fi

BADGE_LITERAL="version-${PLUGIN_VERSION}-green"
if [ "$(grep -Fc -- "$BADGE_LITERAL" "$README" 2>/dev/null || true)" -eq 1 ]; then
  check "README has exactly one matching version badge" PASS
else
  check "README has exactly one matching version badge" FAIL
fi

if [ "$(grep -Ec 'version-[0-9]+\.[0-9]+\.[0-9]+-green' "$README" 2>/dev/null || true)" -eq 1 ]; then
  check "README has no stale release badge" PASS
else
  check "README has no stale release badge" FAIL
fi

if [ "$(grep -Fc '## [Unreleased]' "$CHANGELOG" 2>/dev/null || true)" -eq 1 ]; then
  check "CHANGELOG has exactly one Unreleased heading" PASS
else
  check "CHANGELOG has exactly one Unreleased heading" FAIL
fi

FIRST_RELEASE_VERSION="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$/\1/p' "$CHANGELOG" | head -1)"
if [ "$FIRST_RELEASE_VERSION" = "$PLUGIN_VERSION" ]; then
  check "First released CHANGELOG section matches plugin version" PASS
else
  check "First released CHANGELOG section matches plugin version" FAIL
fi

VERSION_RE="${PLUGIN_VERSION//./\\.}"
if [ "$(grep -Ec "^## \\[$VERSION_RE\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG" 2>/dev/null || true)" -eq 1 ]; then
  check "CHANGELOG has exactly one dated section for plugin version" PASS
else
  check "CHANGELOG has exactly one dated section for plugin version" FAIL
fi

UNRELEASED_LINE="$(grep -nF '## [Unreleased]' "$CHANGELOG" | head -1 | cut -d: -f1)"
RELEASE_LINE="$(grep -nE "^## \\[$VERSION_RE\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$CHANGELOG" | head -1 | cut -d: -f1)"
if [ -n "$UNRELEASED_LINE" ] && [ -n "$RELEASE_LINE" ] && [ "$UNRELEASED_LINE" -lt "$RELEASE_LINE" ]; then
  check "Current release section follows Unreleased" PASS
else
  check "Current release section follows Unreleased" FAIL
fi

if awk -v version="$PLUGIN_VERSION" '
  $0 ~ "^## \\[" version "\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" { in_release = 1; next }
  in_release && /^## \[/ { exit }
  in_release && $0 !~ /^[[:space:]]*$/ { content = 1 }
  END { exit(content ? 0 : 1) }
' "$CHANGELOG"; then
  check "Current CHANGELOG release section is non-empty" PASS
else
  check "Current CHANGELOG release section is non-empty" FAIL
fi

printf '%s\n' '----' "test-version-sync: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
