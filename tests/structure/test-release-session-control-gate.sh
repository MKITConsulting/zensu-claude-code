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
  grep -Fq -- "$2" "$WORKFLOW" && check "$1" PASS || check "$1" FAIL
}

rejects() {
  if grep -Eqi -- "$2" "$WORKFLOW"; then check "$1" FAIL
  else check "$1" PASS; fi
}

line_of() {
  grep -nF -- "$1" "$WORKFLOW" | head -1 | cut -d: -f1
}

[ -f "$WORKFLOW" ] && check "Release workflow exists" PASS \
  || check "Release workflow exists" FAIL

rejects "Prepare runs no pre-bump gate on a tree that is never released" \
  '^ +run: bash tests/run-all\.sh --ci$'
if [ "$(grep -Fc 'bash tests/run-all.sh --ci' "$WORKFLOW")" -eq 2 ]; then
  check "Exact release commit and publish run the non-Promptfoo CI gate" PASS
else
  check "Exact release commit and publish run the non-Promptfoo CI gate" FAIL
fi

rejects "Release workflow contains no Promptfoo or model credentials" \
  'promptfoo|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|session-control:(selfcheck|contract|upgrade|live|concurrency|adversarial|release)'
rejects "Release workflow installs no Claude Code runtime" \
  '@anthropic-ai/claude-code|claude --version'

contains "Release commit exposes a stable step id" 'id: release_commit'
contains "Release commit exports its exact SHA" \
  'echo "sha=$RELEASE_SHA" >> "$GITHUB_OUTPUT"'
contains "Prepare evidence targets the created commit" \
  'EXPECTED_SHA="${{ steps.release_commit.outputs.sha }}"'
contains "Prepare rechecks the exact release HEAD" \
  'test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"'
contains "Prepare requires a clean release commit" \
  'test -z "$(git status --porcelain=v1 --untracked-files=all)"'
contains "Prepare records the Claude runtime digest" \
  'runtime-digest --plugin-root "$GITHUB_WORKSPACE" --host claude'
contains "Prepare rejects malformed runtime digests" \
  '[[ "$RUNTIME_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]]'
contains "Deterministic evidence binds exact SHA, runtime, and plugin version" \
  'zensu-deterministic-release-evidence-v1'
contains "Prepare artifact is bound to the created commit" \
  'name: deterministic-release-${{ steps.release_commit.outputs.sha }}'
contains "Push rechecks the created commit" \
  'test "$(git rev-parse HEAD)" = "${{ steps.release_commit.outputs.sha }}"'

CREATE_LINE="$(line_of '- name: Create release commit')"
GATE_LINE="$(line_of '- name: Record deterministic exact-commit runtime evidence')"
UPLOAD_LINE="$(line_of '- name: Upload deterministic created-commit evidence')"
PUSH_LINE="$(line_of '- name: Push release branch + print PR link')"
if [ -n "$CREATE_LINE" ] && [ -n "$GATE_LINE" ] && [ -n "$UPLOAD_LINE" ] \
  && [ -n "$PUSH_LINE" ] && [ "$CREATE_LINE" -lt "$GATE_LINE" ] \
  && [ "$GATE_LINE" -lt "$UPLOAD_LINE" ] && [ "$UPLOAD_LINE" -lt "$PUSH_LINE" ]; then
  check "Prepare orders commit, deterministic evidence, upload, then push" PASS
else
  check "Prepare orders commit, deterministic evidence, upload, then push" FAIL
fi

contains "Prepare revalidates version sync after the generated bump" \
  'bash tests/structure/test-version-sync.sh "${{ steps.ver.outputs.version }}"'
contains "Prepare revalidates immutable marketplace invariants" \
  'bash tests/structure/test-immutable-marketplace-release.sh'
contains "Dry run documents that no release commit or branch is created" \
  'Offline preview only: no release commit was created and no branch was pushed.'

contains "Publish requires Immutable Releases before deterministic validation" \
  '- name: Require repository Immutable Releases before deterministic validation'
contains "Publish uses the dedicated settings token" \
  'GH_TOKEN: ${{ secrets.IMMUTABLE_RELEASES_ADMIN_TOKEN }}'
contains "Publish deterministic gate targets exact main SHA" \
  'test "$(git rev-parse HEAD)" = "${{ github.sha }}"'
contains "Publish artifact is bound to exact main SHA" \
  'name: deterministic-publish-${{ github.sha }}'
contains "Publish rechecks Immutable Releases immediately before publication" \
  '- name: Recheck Immutable Releases immediately before publish'
contains "Release REST calls pin API version 2026-03-10" \
  'X-GitHub-Api-Version: 2026-03-10'
contains "Draft publication targets exact main SHA" \
  '--draft --title "$TAG" --target "${{ github.sha }}"'
contains "Published release validates exact tag SHA" \
  '"repos/$GITHUB_REPOSITORY/commits/$TAG" --jq .sha'
contains "Published release validates immutable metadata" \
  'verify_metadata "$CANDIDATE" false true'
contains "Published release validates asset digest" \
  'and .assets[0].digest == $digest'
rejects "Release avoids mutable third-party publication actions" \
  'softprops/action-gh-release'

PUBLISH_GATE_LINE="$(line_of '- name: Deterministic exact-main-SHA gate')"
PUBLISH_UPLOAD_LINE="$(line_of '- name: Upload deterministic exact-main-SHA evidence')"
PUBLISH_MUTATION_LINE="$(line_of '- name: Draft, attach, publish, and verify immutable release')"
if [ -n "$PUBLISH_GATE_LINE" ] && [ -n "$PUBLISH_UPLOAD_LINE" ] \
  && [ -n "$PUBLISH_MUTATION_LINE" ] \
  && [ "$PUBLISH_GATE_LINE" -lt "$PUBLISH_UPLOAD_LINE" ] \
  && [ "$PUBLISH_UPLOAD_LINE" -lt "$PUBLISH_MUTATION_LINE" ]; then
  check "Publish orders deterministic gate and evidence before mutation" PASS
else
  check "Publish orders deterministic gate and evidence before mutation" FAIL
fi

UPLOAD_PIN='actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4'
if [ "$(grep -Fc -- "$UPLOAD_PIN" "$WORKFLOW")" -eq 2 ]; then
  check "Both deterministic evidence uploads use the pinned artifact action" PASS
else
  check "Both deterministic evidence uploads use the pinned artifact action" FAIL
fi

# v0.18.0 stranded as an untagged draft because `RELEASE="$(release_json)"` ran
# straight after `gh release create --draft`, lost the race against the release
# LIST endpoint, and — being a bare assignment under `set -e` — killed the step
# with no message. The class is grep-able even though the behaviour is not: a
# read-back assignment must go through the bounded retry, never through the raw
# resolver. The retry loop's own read is the ONE exemption and is spelled with an
# explicit `|| true`, so it cannot be confused with an unguarded assignment.
RAW_READBACK="$(grep -nE '^[[:space:]]*(RELEASE|CANDIDATE)="\$\(release_json\)"' \
  "$WORKFLOW" 2>/dev/null || true)"
if [ -z "$RAW_READBACK" ]; then
  check "Release read-backs use the bounded retry, never a bare release_json assignment" PASS
else
  check "Release read-backs use the bounded retry (unguarded:$RAW_READBACK)" FAIL
fi

if grep -qE '^[[:space:]]*release_json_retry\(\) \{' "$WORKFLOW" \
  && grep -qE 'could not read back the release after' "$WORKFLOW"; then
  check "The bounded read-back retry exists and names its failure" PASS
else
  check "The bounded read-back retry exists and names its failure" FAIL
fi

printf '%s\n' '----' "test-release-session-control-gate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
