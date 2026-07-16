#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
WORKFLOW="$ROOT/.github/workflows/release.yml"
CONVENTIONS="$ROOT/CLAUDE.md"
PROVISIONER="$ROOT/evals/session-control/lib/provision-installed-plugin.sh"
GENERATOR="$ROOT/evals/session-control/lib/create-local-marketplace-fixture.js"
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

expect_jq() {
  local label="$1" file="$2" expression="$3"
  jq -e "$expression" "$file" >/dev/null 2>&1 \
    && check "$label" PASS || check "$label" FAIL
}

expect_text() {
  local label="$1" file="$2" literal="$3"
  grep -Fq -- "$literal" "$file" \
    && check "$label" PASS || check "$label" FAIL
}

reject_text() {
  local label="$1" file="$2" literal="$3"
  if grep -Fq -- "$literal" "$file"; then
    check "$label" FAIL
  else
    check "$label" PASS
  fi
}

VERSION="$(jq -r '.version' "$PLUGIN" 2>/dev/null)"
expect_jq "Production source uses the official GitHub source type" "$MARKETPLACE" \
  '.plugins | length == 1 and .[0].source.source == "github"'
expect_jq "Production source pins the canonical repository" "$MARKETPLACE" \
  '.plugins[0].source.repo == "MKITConsulting/zensu-claude-code"'
if jq -e --arg version "$VERSION" \
  '.plugins[0].source.ref == ("v" + $version)' "$MARKETPLACE" >/dev/null 2>&1; then
  check "Production source ref is the immutable plugin release tag" PASS
else
  check "Production source ref is the immutable plugin release tag" FAIL
fi

[ -f "$GENERATOR" ] && check "Local marketplace fixture generator exists" PASS \
  || check "Local marketplace fixture generator exists" FAIL
expect_text "Provisioner builds an exact-checkout fixture" "$PROVISIONER" \
  'create-local-marketplace-fixture.js'
expect_text "Provisioner registers the fixture, not the source checkout" "$PROVISIONER" \
  'plugin marketplace add "$MARKETPLACE_ROOT"'

expect_text "Release bump updates the immutable source ref" "$WORKFLOW" \
  'marketplace source ref -> $TAG'
expect_text "Release validates source ref equals the release tag" "$WORKFLOW" \
  'test "$(jq -r '\''.plugins[0].source.ref'\'' .claude-plugin/marketplace.json)" = "$TAG"'
expect_text "Publish verifies the immutable source before its paid gate" "$WORKFLOW" \
  '- name: Verify immutable marketplace release target'
expect_text "Publish rejects a malformed plugin version before go-live" "$WORKFLOW" \
  '[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
expect_text "A pre-existing tag at another commit fails closed" "$WORKFLOW" \
  'already exists at $TAG_SHA, not exact main SHA'
expect_text "Repository Immutable Releases are required before paid validation" "$WORKFLOW" \
  '- name: Require repository Immutable Releases before paid validation'
expect_text "Repository Immutable Releases are rechecked immediately before publish" "$WORKFLOW" \
  '- name: Recheck Immutable Releases immediately before publish'
expect_text "Settings checks use a separate administrative token" "$WORKFLOW" \
  'GH_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_ADMIN_TOKEN }}'
expect_text "Immutable Releases setting must be enabled" "$WORKFLOW" \
  '"repos/$GITHUB_REPOSITORY/immutable-releases"'
expect_text "Immutable Release APIs pin the current contract version" "$WORKFLOW" \
  "X-GitHub-Api-Version: 2026-03-10"
reject_text "Release workflow does not use the retired API contract" "$WORKFLOW" \
  "X-GitHub-Api-Version: 2022-11-28"
expect_text "New releases are created as drafts" "$WORKFLOW" \
  'gh release create "$TAG" --repo "$GITHUB_REPOSITORY" \
              --draft --title "$TAG" --target "${{ github.sha }}"'
expect_text "Draft asset upload is explicit" "$WORKFLOW" \
  'gh release upload "$TAG" "$ASSET" --repo "$GITHUB_REPOSITORY"'
expect_text "Draft publication is explicit" "$WORKFLOW" \
  'gh release edit "$TAG" --repo "$GITHUB_REPOSITORY" --draft=false'
expect_text "Published releases must report immutable=true" "$WORKFLOW" \
  'verify_metadata "$CANDIDATE" false true'
expect_text "Publication polls a bounded ten attempts" "$WORKFLOW" \
  'for ATTEMPT in $(seq 1 10); do'
expect_text "Publication poll waits two seconds between attempts" "$WORKFLOW" \
  'sleep 2'
expect_text "Publication poll waits for the asset digest too" "$WORKFLOW" \
  'verify_metadata "$CANDIDATE" false true && verify_asset "$CANDIDATE"; then'
expect_text "Release asset verification pins name, uploaded state, and digest" "$WORKFLOW" \
  'and .assets[0].state == "uploaded"'
expect_text "Mutable published releases fail instead of being repaired" "$WORKFLOW" \
  'existing published release metadata is not the exact immutable contract; refusing repair'
expect_text "Draft metadata is normalized through the release REST object" "$WORKFLOW" \
  'normalize_draft_metadata "$RELEASE"'
expect_text "Draft metadata binds exact title and generated notes" "$WORKFLOW" \
  'and .name == $title'
expect_text "Draft metadata compares the exact generated body" "$WORKFLOW" \
  'and .body == $body'
expect_text "Draft metadata is re-read immediately before publication" "$WORKFLOW" \
  'verify_metadata "$RELEASE" true false'
reject_text "Mutable action wrapper is not used for publication" "$WORKFLOW" \
  'softprops/action-gh-release'
expect_text "Release documentation identifies tag creation as go-live" "$WORKFLOW" \
  'Only successful tag creation makes the new plugin source resolvable'
expect_text "Repository conventions require version and source-ref lockstep" "$CONVENTIONS" \
  'marketplace version + marketplace `ref`'
reject_text "Repository conventions do not call a main merge go-live" "$CONVENTIONS" \
  'go-live is the merge itself'

GATE_LINE="$(grep -nF -- '- name: Session Control publish gate (exact main SHA)' "$WORKFLOW" | head -1 | cut -d: -f1)"
DRAFT_LINE="$(grep -nF -- '- name: Draft, attach, publish, and verify immutable release' "$WORKFLOW" | head -1 | cut -d: -f1)"
EARLY_SETTING_LINE="$(grep -nF -- '- name: Require repository Immutable Releases before paid validation' "$WORKFLOW" | head -1 | cut -d: -f1)"
LATE_SETTING_LINE="$(grep -nF -- '- name: Recheck Immutable Releases immediately before publish' "$WORKFLOW" | head -1 | cut -d: -f1)"
if [ -n "$EARLY_SETTING_LINE" ] && [ -n "$GATE_LINE" ] && [ -n "$LATE_SETTING_LINE" ] && [ -n "$DRAFT_LINE" ] \
  && [ "$EARLY_SETTING_LINE" -lt "$GATE_LINE" ] && [ "$GATE_LINE" -lt "$LATE_SETTING_LINE" ] \
  && [ "$LATE_SETTING_LINE" -lt "$DRAFT_LINE" ]; then
  check "Settings check, exact-main gate, final settings check, and publication are ordered" PASS
else
  check "Settings check, exact-main gate, final settings check, and publication are ordered" FAIL
fi

printf '%s\n' '----' "test-immutable-marketplace-release: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
