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

ZENSU_ENTRY='[.plugins[] | select(.name == "zensu")] | select(length == 1) | .[0]'
PLUGIN_VERSION="$(jq -er '.version' "$PLUGIN" 2>/dev/null || true)"
MARKETPLACE_VERSION="$(jq -er "$ZENSU_ENTRY.version" "$MARKETPLACE" 2>/dev/null || true)"
MARKETPLACE_REF="$(jq -er "$ZENSU_ENTRY.source.ref" "$MARKETPLACE" 2>/dev/null || true)"

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

BUMP="$ROOT/.github/scripts/bump-marketplace-entry.js"
CLIFF="$ROOT/cliff.toml"
SECOND_NAME="session-hub"
TARGET_VERSION="999.0.0"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/zensu-version-sync-XXXXXX")" \
  || { printf '%s\n' 'test-version-sync: cannot create a temp directory' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

if node -e '
  const fs = require("node:fs");
  const text = fs.readFileSync(process.argv[1], "utf8");
  process.exit(`${JSON.stringify(JSON.parse(text), null, 2)}\n` === text ? 0 : 1);
' "$MARKETPLACE" 2>/dev/null; then
  check "Marketplace is in the canonical form the release bump requires" PASS
else
  check "Marketplace is in the canonical form the release bump requires" FAIL
fi

marketplace_fixture() {
  node -e '
    const fs = require("node:fs");
    const [source, target, shape, secondName] = process.argv.slice(1);
    const marketplace = JSON.parse(fs.readFileSync(source, "utf8"));
    const second = {
      name: secondName,
      source: {
        source: "git-subdir",
        url: "https://github.com/MKITConsulting/zensu-claude-code.git",
        path: "plugins/session-hub",
        ref: "session-hub--v7.7.7",
      },
      version: "7.7.7",
    };
    const zensu = marketplace.plugins.find((entry) => entry.name === "zensu");
    if (shape === "first") marketplace.plugins.unshift(second);
    if (shape === "last" || shape === "twice") marketplace.plugins.push(second);
    if (shape === "renamed") zensu.name = "zensu-renamed";
    if (shape === "sourceless") zensu.source = "./plugin";
    if (shape === "versionless") delete zensu.version;
    fs.writeFileSync(target, `${JSON.stringify(marketplace, null, 2)}\n`);
  ' "$MARKETPLACE" "$1" "$2" "${3:-$SECOND_NAME}"
}

for POSITION in first last; do
  FIXTURE="$TMP/second-entry-$POSITION.json"
  marketplace_fixture "$FIXTURE" "$POSITION"
  cp "$FIXTURE" "$TMP/before.json"
  BUMP_RC=0
  node "$BUMP" "$FIXTURE" zensu "$TARGET_VERSION" "v$TARGET_VERSION" >"$TMP/bump.out" 2>&1 || BUMP_RC=$?
  SECOND_BEFORE="$(jq -c --arg name "$SECOND_NAME" '[.plugins[] | select(.name == $name)]' "$TMP/before.json" 2>/dev/null)"
  SECOND_AFTER="$(jq -c --arg name "$SECOND_NAME" '[.plugins[] | select(.name == $name)]' "$FIXTURE" 2>/dev/null)"
  ORDER_BEFORE="$(jq -c '[.plugins[].name]' "$TMP/before.json" 2>/dev/null)"
  ORDER_AFTER="$(jq -c '[.plugins[].name]' "$FIXTURE" 2>/dev/null)"
  DIFF_LINES="$(diff "$TMP/before.json" "$FIXTURE" | grep -c '^[<>]')"
  ADDED_LINES="$(diff "$TMP/before.json" "$FIXTURE" | sed -n 's/^> *//p' | sort | tr '\n' '|')"
  if [ "$BUMP_RC" -eq 0 ] \
    && [ "$(jq -r "$ZENSU_ENTRY.version" "$FIXTURE" 2>/dev/null)" = "$TARGET_VERSION" ] \
    && [ "$(jq -r "$ZENSU_ENTRY.source.ref" "$FIXTURE" 2>/dev/null)" = "v$TARGET_VERSION" ] \
    && [ -n "$SECOND_BEFORE" ] && [ "$SECOND_BEFORE" != "[]" ] && [ "$SECOND_BEFORE" = "$SECOND_AFTER" ] \
    && [ "$ORDER_BEFORE" = "$ORDER_AFTER" ] \
    && [ "$DIFF_LINES" -eq 4 ] \
    && [ "$ADDED_LINES" = "\"ref\": \"v$TARGET_VERSION\"|\"version\": \"$TARGET_VERSION\"|" ]; then
    check "Release bump changes only the zensu version and ref when a git-subdir entry is listed $POSITION" PASS
  else
    check "Release bump changes only the zensu version and ref when a git-subdir entry is listed $POSITION (rc=$BUMP_RC changed lines=$DIFF_LINES)" FAIL
  fi
done

refusal_check() {
  local label="$1" token="$2" file="$3" rc=0
  shift 3
  cp "$file" "$TMP/refusal-before.json"
  node "$BUMP" "$file" "$@" >"$TMP/refusal.out" 2>"$TMP/refusal.err" || rc=$?
  if [ "$rc" -ne 0 ] && cmp -s "$file" "$TMP/refusal-before.json" \
    && grep -Fq -- "$token" "$TMP/refusal.err"; then
    check "$label" PASS
  else
    check "$label (rc=$rc)" FAIL
  fi
}

jq -c . "$MARKETPLACE" > "$TMP/minified.json"
refusal_check "Release bump refuses a marketplace that is not in canonical form and leaves it byte-identical" \
  "refused (not-canonical)" "$TMP/minified.json" zensu "$TARGET_VERSION" "v$TARGET_VERSION"
marketplace_fixture "$TMP/renamed.json" renamed
refusal_check "Release bump refuses a marketplace without an entry named zensu and leaves it byte-identical" \
  "refused (entry-count)" "$TMP/renamed.json" zensu "$TARGET_VERSION" "v$TARGET_VERSION"
marketplace_fixture "$TMP/twice.json" twice zensu
refusal_check "Release bump refuses a marketplace with two entries named zensu and leaves it byte-identical" \
  "refused (entry-count)" "$TMP/twice.json" zensu "$TARGET_VERSION" "v$TARGET_VERSION"
marketplace_fixture "$TMP/sourceless.json" sourceless
refusal_check "Release bump refuses a zensu entry whose source carries no ref and leaves it byte-identical" \
  "refused (no-source-ref)" "$TMP/sourceless.json" zensu "$TARGET_VERSION" "v$TARGET_VERSION"
marketplace_fixture "$TMP/versionless.json" versionless
refusal_check "Release bump refuses a zensu entry without a version and leaves it byte-identical" \
  "refused (no-version)" "$TMP/versionless.json" zensu "$TARGET_VERSION" "v$TARGET_VERSION"
marketplace_fixture "$TMP/valid.json" last
refusal_check "Release bump refuses a version that is not MAJOR.MINOR.PATCH and leaves the file byte-identical" \
  "refused (bad-version)" "$TMP/valid.json" zensu 9.8 v9.8
refusal_check "Release bump refuses a ref that is not a plain tag name and leaves the file byte-identical" \
  "refused (bad-ref)" "$TMP/valid.json" zensu "$TARGET_VERSION" "v$TARGET_VERSION; true"
refusal_check "Release bump refuses a call without all four operands and leaves the file byte-identical" \
  "usage:" "$TMP/valid.json" zensu "$TARGET_VERSION"

TAG_PATTERN="$(sed -nE "s/^tag_pattern[[:space:]]*=[[:space:]]*'([^']+)'[[:space:]]*$/\1/p" "$CLIFF")"
if [ -n "$TAG_PATTERN" ] && node -e '
  const pattern = new RegExp(process.argv[1]);
  const accepted = ["v0.35.0", "v1.0.0", "v10.20.30"];
  const refused = ["session-hub--v1.0.0", "zensu--v0.35.0", "v0.35.0-rc.1", "release/v0.35.0", "v0.35"];
  process.exit(accepted.every((tag) => pattern.test(tag)) && !refused.some((tag) => pattern.test(tag)) ? 0 : 1);
' "$TAG_PATTERN" 2>/dev/null; then
  check "git-cliff counts only vX.Y.Z tags as releases of this plugin, never a companion's name--vX.Y.Z tag" PASS
else
  check "git-cliff counts only vX.Y.Z tags as releases of this plugin (tag_pattern: ${TAG_PATTERN:-unreadable})" FAIL
fi

printf '%s\n' '----' "test-version-sync: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
