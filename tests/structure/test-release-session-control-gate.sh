#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKFLOW="$ROOT/.github/workflows/release.yml"
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

contains() {
  local label="$1" text="$2" literal="$3"
  printf '%s\n' "$text" | grep -Fq -- "$literal" \
    && check "$label" PASS || check "$label" FAIL
}

not_contains() {
  local label="$1" text="$2" literal="$3"
  if printf '%s\n' "$text" | grep -Fq -- "$literal"; then
    check "$label" FAIL
  else
    check "$label" PASS
  fi
}

line_of() {
  grep -nF -- "$2" "$1" | head -1 | cut -d: -f1
}

if [ ! -f "$WORKFLOW" ]; then
  check "Release workflow exists" FAIL
  printf '%s\n' '----' "test-release-session-control-gate: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "Release workflow exists" PASS

PREPARE="$(awk '/^  prepare:/{active=1} /^  publish:/{active=0} active{print}' "$WORKFLOW")"
PUBLISH="$(awk '/^  publish:/{active=1} active{print}' "$WORKFLOW")"

contains "Prepare paid gate has a bounded job timeout" "$PREPARE" 'timeout-minutes: 120'
contains "Publish paid gate has a bounded job timeout" "$PUBLISH" 'timeout-minutes: 120'

CREATE_LINE="$(line_of "$WORKFLOW" '- name: Create release commit')"
INSTALL_LINE="$(line_of "$WORKFLOW" '- name: Install pinned Claude Code CLI for release gate')"
GATE_LINE="$(line_of "$WORKFLOW" '- name: Session Control release gate (created commit SHA)')"
EVIDENCE_LINE="$(line_of "$WORKFLOW" '- name: Upload created-commit release evidence')"
PUSH_LINE="$(line_of "$WORKFLOW" '- name: Push release branch + print PR link')"

if [ -n "$CREATE_LINE" ] && [ -n "$INSTALL_LINE" ] && [ -n "$GATE_LINE" ] \
  && [ -n "$EVIDENCE_LINE" ] && [ -n "$PUSH_LINE" ] \
  && [ "$CREATE_LINE" -lt "$INSTALL_LINE" ] \
  && [ "$INSTALL_LINE" -lt "$GATE_LINE" ] \
  && [ "$GATE_LINE" -lt "$EVIDENCE_LINE" ] \
  && [ "$EVIDENCE_LINE" -lt "$PUSH_LINE" ]; then
  check "Prepare orders commit, pinned CLI, full gate, evidence, then push" PASS
else
  check "Prepare orders commit, pinned CLI, full gate, evidence, then push" FAIL
fi

contains "Release commit exposes a stable step id" "$PREPARE" 'id: release_commit'
contains "Release commit exports its exact SHA" "$PREPARE" 'echo "sha=$RELEASE_SHA" >> "$GITHUB_OUTPUT"'
contains "Release commit must be clean" "$PREPARE" 'test -z "$(git status --porcelain=v1 --untracked-files=all)"'
contains "Prepare installs the exact Claude Code CLI" "$PREPARE" 'npm install --global @anthropic-ai/claude-code@2.1.211'
contains "Prepare verifies the exact Claude Code CLI" "$PREPARE" '= 2.1.211'
contains "Prepare gate targets the created commit output" "$PREPARE" 'ZENSU_EXPECTED_SOURCE_REVISION: ${{ steps.release_commit.outputs.sha }}'
contains "Prepare gate writes sanitized suite receipts into its SHA-bound artifact" "$PREPARE" 'ZENSU_SESSION_CONTROL_EVIDENCE_DIR: ${{ runner.temp }}/session-control-release-evidence/suites'
not_contains "Prepare gate never substitutes the dispatch SHA" "$PREPARE" 'ZENSU_EXPECTED_SOURCE_REVISION: ${{ github.sha }}'
contains "Prepare maps the API-key secret explicitly" "$PREPARE" 'ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}'
contains "Prepare maps the OAuth-token secret explicitly" "$PREPARE" 'CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}'
contains "Prepare gate requires an explicit credential" "$PREPARE" 'if [ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then'
contains "Prepare gate acknowledges a disposable environment" "$PREPARE" "ZENSU_E2E_DISPOSABLE_ENVIRONMENT: '1'"
contains "Prepare runs the complete release profile" "$PREPARE" 'npm run session-control:release'
contains "Prepare revalidates version sync for the computed release" "$PREPARE" 'bash tests/structure/test-version-sync.sh "${{ steps.ver.outputs.version }}"'
contains "Prepare revalidates immutable release invariants after bump" "$PREPARE" 'bash tests/structure/test-immutable-marketplace-release.sh'
CHANGELOG_LINE="$(line_of "$WORKFLOW" '- name: Prepend section into CHANGELOG.md')"
VERSION_SYNC_LINE="$(line_of "$WORKFLOW" '- name: Revalidate generated release and immutable-source invariants')"
if [ -n "$CHANGELOG_LINE" ] && [ -n "$VERSION_SYNC_LINE" ] \
  && [ "$CHANGELOG_LINE" -lt "$VERSION_SYNC_LINE" ] && [ "$VERSION_SYNC_LINE" -lt "$CREATE_LINE" ]; then
  check "Full version and CHANGELOG invariant runs after prepend and before commit" PASS
else
  check "Full version and CHANGELOG invariant runs after prepend and before commit" FAIL
fi
contains "Prepare rechecks the exact HEAD" "$PREPARE" 'test "$(git rev-parse HEAD)" = "$ZENSU_EXPECTED_SOURCE_REVISION"'
contains "Prepare receipt records the runtime digest" "$PREPARE" 'runtime_digest:$runtime_digest'
contains "Prepare artifact name is bound to the created commit" "$PREPARE" 'name: session-control-release-${{ steps.release_commit.outputs.sha }}'
contains "Push rechecks the created commit" "$PREPARE" 'test "$(git rev-parse HEAD)" = "${{ steps.release_commit.outputs.sha }}"'

contains "Dry run is documented as offline" "$PREPARE" 'Offline preview only:'
contains "Dry run reports no paid live gate" "$PREPARE" 'no paid Session Control live gate ran'
if [ "$(printf '%s\n' "$PREPARE" | grep -Fc 'if: ${{ !inputs.dry_run }}')" -eq 5 ]; then
  check "Commit, CLI, gate, evidence, and push are all disabled for dry runs" PASS
else
  check "Commit, CLI, gate, evidence, and push are all disabled for dry runs" FAIL
fi

contains "Publish installs the exact Claude Code CLI" "$PUBLISH" 'npm install --global @anthropic-ai/claude-code@2.1.211'
contains "Publish gate targets the exact main SHA" "$PUBLISH" 'ZENSU_EXPECTED_SOURCE_REVISION: ${{ github.sha }}'
contains "Publish gate writes sanitized suite receipts into its SHA-bound artifact" "$PUBLISH" 'ZENSU_SESSION_CONTROL_EVIDENCE_DIR: ${{ runner.temp }}/session-control-publish-evidence/suites'
contains "Publish gate requires an explicit credential" "$PUBLISH" 'if [ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then'
contains "Publish gate acknowledges a disposable environment" "$PUBLISH" "ZENSU_E2E_DISPOSABLE_ENVIRONMENT: '1'"
contains "Publish runs the complete release profile" "$PUBLISH" 'npm run session-control:release'
contains "Publish artifact name is bound to the exact main SHA" "$PUBLISH" 'name: session-control-publish-${{ github.sha }}'
contains "Publish requires Immutable Releases before paid validation" "$PUBLISH" '- name: Require repository Immutable Releases before paid validation'
contains "Publish rechecks Immutable Releases immediately before publication" "$PUBLISH" '- name: Recheck Immutable Releases immediately before publish'
contains "Immutable settings checks use the dedicated admin token" "$PUBLISH" 'GH_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_ADMIN_TOKEN }}'
contains "Release REST calls pin API version 2026-03-10" "$PUBLISH" 'X-GitHub-Api-Version: 2026-03-10'
not_contains "Release REST calls reject the old API contract" "$PUBLISH" 'X-GitHub-Api-Version: 2022-11-28'
contains "Draft publication targets the exact main SHA" "$PUBLISH" '--draft --title "$TAG" --target "${{ github.sha }}"'
contains "Published release validates the exact tag SHA" "$PUBLISH" '"repos/$GITHUB_REPOSITORY/commits/$TAG" --jq .sha'
contains "Published release validates immutable=true through the exact metadata helper" "$PUBLISH" 'verify_metadata "$CANDIDATE" false true'
contains "Published release validates the expected asset digest" "$PUBLISH" 'and .assets[0].digest == $digest'
contains "Publish performs a bounded immutable/digest poll" "$PUBLISH" 'for ATTEMPT in $(seq 1 10); do'
contains "Published release rejects mutable retries" "$PUBLISH" 'existing published release metadata is not the exact immutable contract; refusing repair'
contains "Draft metadata binds exact tag and target" "$PUBLISH" 'and .target_commitish == $sha'
contains "Draft metadata binds exact title" "$PUBLISH" 'and .name == $title'
contains "Draft metadata binds exact generated notes body" "$PUBLISH" 'and .body == $body'
contains "Draft metadata is normalized then re-read immediately before publish" "$PUBLISH" 'verify_metadata "$RELEASE" true false'
not_contains "Release does not rely on a mutable third-party release action" "$PUBLISH" 'softprops/action-gh-release'

UPLOAD_PIN='actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4'
if [ "$(grep -Fc -- "$UPLOAD_PIN" "$WORKFLOW")" -eq 2 ]; then
  check "Both exact-SHA evidence uploads use the pinned artifact action" PASS
else
  check "Both exact-SHA evidence uploads use the pinned artifact action" FAIL
fi

printf '%s\n' '----' "test-release-session-control-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
