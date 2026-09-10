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

# WORKING TREE, not HEAD. Driven first: tests/run-all.sh discovers only
# test-*.sh, so this is the only path by which the wrapper's executable coverage
# runs at all, and a later timeout must not be able to drop it.
RUN_STEP_TEST="$ROOT/tests/structure/release-run-step.test.js"
if [ -f "$RUN_STEP_TEST" ]; then
  RUN_STEP_OUT="$(node --test "$RUN_STEP_TEST" 2>&1)"
  RUN_STEP_RC=$?
  RUN_STEP_CASES="$(printf '%s\n' "$RUN_STEP_OUT" | sed -n 's/^. tests \([0-9]*\)$/\1/p' | head -1)"
  # The floor is the REGISTRATION step for a new case: raise this number in the
  # same commit that adds one. Without it a case can be added and then deleted
  # again with this driver still green.
  if [ "$RUN_STEP_RC" -eq 0 ] && [ "${RUN_STEP_CASES:-0}" -ge 11 ]; then
    check "run_step behavioural suite passes ($RUN_STEP_CASES cases)" PASS
  else
    check "run_step behavioural suite passes (rc=$RUN_STEP_RC cases=${RUN_STEP_CASES:-none})" FAIL
    printf '%s\n' "$RUN_STEP_OUT" | tail -20
  fi
else
  check "run_step behavioural suite exists" FAIL
fi

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
expect_text "Publish verifies the immutable source before deterministic validation" "$WORKFLOW" \
  '- name: Verify immutable marketplace release target'
expect_text "Publish rejects a malformed plugin version before go-live" "$WORKFLOW" \
  '[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]'
expect_text "A pre-existing tag at another commit fails closed" "$WORKFLOW" \
  'already exists at $TAG_SHA, not exact main SHA'
expect_text "Repository Immutable Releases are required before deterministic validation" "$WORKFLOW" \
  '- name: Require repository Immutable Releases before deterministic validation'
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
# Publication used to run `gh release edit "$TAG" --draft=false`. gh exposes no
# by-id form for that subcommand, so the one call that flips the release live
# depended on tag resolution while the release still carried no tag. The id is
# already inside the verified draft object, so the PATCH addresses it directly.
expect_text "Draft publication is explicit" "$WORKFLOW" \
  'gh api --method PATCH -H '"'"'Accept: application/vnd.github+json'"'"''
expect_text "Draft publication addresses the release by id" "$WORKFLOW" \
  '"repos/$GITHUB_REPOSITORY/releases/$PUBLISH_ID"'
expect_text "Draft publication clears the draft flag" "$WORKFLOW" \
  '-F draft=false'
expect_text "Publication refuses a draft that carries no release id" "$WORKFLOW" \
  'verified draft carries no release id; refusing to publish'
reject_text "Publication is not addressed through the tag-only gh subcommand" "$WORKFLOW" \
  'release edit "$TAG"'

# Release run 33397732337 died in this step after emitting exactly one line — the
# draft URL — with no ::error:: and no stderr, which made the cause unrecoverable.
# Every command that can fail under `set -euo pipefail` without annotating itself
# now runs through run_step.
expect_text "A failing release command annotates itself" "$WORKFLOW" \
  'echo "::error::${label} failed (exit ${rc}): ${first:-no stderr output}"'
expect_text "A failing release command replays its own stderr" "$WORKFLOW" \
  'printf '"'"'%s\n'"'"' "--- stderr of: $* ---" >&2'
expect_text "The diagnostic wrapper captures the failed command's exit status" "$WORKFLOW" \
  '"$@" 2>"$err_file" || rc=$?'
expect_text "The diagnostic wrapper returns that status to its caller" "$WORKFLOW" \
  'return "$rc"'
expect_text "The diagnostic wrapper owns the stdout sink through --quiet" "$WORKFLOW" \
  '"$@" >/dev/null 2>"$err_file" || rc=$?'
expect_text "Draft creation runs through the diagnostic wrapper" "$WORKFLOW" \
  'run_step "draft release creation for $TAG" \'
expect_text "Existing-draft asset upload runs through the diagnostic wrapper" "$WORKFLOW" \
  'run_step "asset upload to the existing draft $TAG" \'
expect_text "New-draft asset upload runs through the diagnostic wrapper" "$WORKFLOW" \
  'run_step "asset upload to the new draft $TAG" \'
expect_text "Metadata normalization runs through the diagnostic wrapper" "$WORKFLOW" \
  'run_step --quiet "draft metadata normalization for $TAG (id $release_id)" \'
expect_text "Publication runs through the diagnostic wrapper" "$WORKFLOW" \
  'run_step --quiet "publishing draft release $TAG (id $PUBLISH_ID)" \'
expect_text "The publish id is type-checked, matching its sibling extraction" "$WORKFLOW" \
  'PUBLISH_ID="$(printf '"'"'%s'"'"' "$RELEASE" | jq -er '"'"'.id | select(type == "number")'"'"')"'
expect_text "The diagnostic temp file is anchored under the runner temp dir" "$WORKFLOW" \
  'err_file="$(mktemp "${RUNNER_TEMP:-/tmp}/release-run-step.XXXXXX")"'

# A trailing redirect on a run_step INVOCATION used to bind to the function and
# discard the ::error:: annotation. The annotation now lives on fd 3, so that class
# is closed BY CONSTRUCTION and this scan is defence in depth, not the guarantee.
# It is kept because it is cheap and because it names the hazard for a reader.
# The pattern is deliberately wider than the literal that shipped: `> /dev/null`,
# `1>/dev/null`, `&>/dev/null` and `>"$f"` all bind the same way.
RUN_STEP_SCAN="$(awk '
  /^[[:space:]]*#/ { next }
  /(^|[;&|(]|[[:space:]])run_step[[:space:]]/ { inv = 1 }
  inv { print }
  inv && !/\\$/ { inv = 0 }
' "$WORKFLOW")"
RUN_STEP_SEEN="$(printf '%s\n' "$RUN_STEP_SCAN" | grep -cE '(^|[^[:alnum:]_])run_step[[:space:]]' || true)"
RUN_STEP_REDIRECTED="$(printf '%s\n' "$RUN_STEP_SCAN" | grep -cE '[0-9]*&?>[[:space:]]*("?/dev/null"?|&[0-9])' || true)"
# An EMPTY derivation is a FAIL, not a skip: a negative scan whose extractor stops
# matching reports zero and passes having examined nothing. Same rule as G12a.
if [ "$RUN_STEP_SEEN" -lt 5 ]; then
  check "run_step invocation scan finds every call site (saw $RUN_STEP_SEEN, expected >= 5)" FAIL
else
  check "run_step invocation scan finds every call site ($RUN_STEP_SEEN)" PASS
fi
if [ "$RUN_STEP_REDIRECTED" -eq 0 ]; then
  check "No run_step invocation carries its own stdout redirect" PASS
else
  check "No run_step invocation carries its own stdout redirect" FAIL
fi
expect_text "Workflow annotations are written on a dedicated descriptor" "$WORKFLOW" \
  'exec 3>&1'
expect_text "The wrapper writes its annotation to that descriptor" "$WORKFLOW" \
  'no stderr output}" >&3'
expect_text "The wrapper refuses a call with no command" "$WORKFLOW" \
  'run_step called without a label and a command'
expect_text "The release lookup distinguishes not-found from an API failure" "$WORKFLOW" \
  'could not read the release list for $TAG; refusing to create a second draft'
expect_text "The pre-publish asset check names its own failure" "$WORKFLOW" \
  'draft asset for $TAG is incomplete or has the wrong digest immediately before publish'
expect_text "The closing asset check re-reads rather than re-deriving" "$WORKFLOW" \
  'published asset for $TAG is incomplete or has the wrong digest on a fresh read'
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
# A draft carries no git tag, so /releases/tags/{tag} 404s on it. Addressing the
# release by tag broke the read-back after creation and made the existing-draft
# retry branch unreachable; the id lookup below is what keeps both working.
reject_text "Drafts are not addressed through the published-only tag endpoint" "$WORKFLOW" \
  'RELEASE_API="repos/$GITHUB_REPOSITORY/releases/tags/$TAG"'
expect_text "Draft lookup matches the release list by tag name" "$WORKFLOW" \
  'map(select(.tag_name == \"$TAG\")) | .[0].id // empty'
expect_text "The release is addressed by id once resolved" "$WORKFLOW" \
  '"repos/$GITHUB_REPOSITORY/releases/$id"'
expect_text "A missing release makes the lookup fail instead of returning empty" "$WORKFLOW" \
  '[ -n "$id" ] || return 1'
expect_text "Publication can be retried through a dispatch" "$WORKFLOW" \
  "(github.event_name == 'workflow_dispatch' && inputs.mode == 'publish')"
expect_text "Branch preparation stays bound to prepare mode" "$WORKFLOW" \
  "github.event_name == 'workflow_dispatch' && inputs.mode == 'prepare'"
expect_text "A publish dispatch outside main is rejected" "$WORKFLOW" \
  'publish mode may only be dispatched on main'
reject_text "Mutable action wrapper is not used for publication" "$WORKFLOW" \
  'softprops/action-gh-release'
expect_text "Release documentation identifies tag creation as go-live" "$WORKFLOW" \
  'Only successful tag creation makes the new plugin source resolvable'
expect_text "Repository conventions require version and source-ref lockstep" "$CONVENTIONS" \
  'marketplace version + marketplace `ref`'
reject_text "Repository conventions do not call a main merge go-live" "$CONVENTIONS" \
  'go-live is the merge itself'

GATE_LINE="$(grep -nF -- '- name: Deterministic exact-main-SHA gate' "$WORKFLOW" | head -1 | cut -d: -f1)"
DRAFT_LINE="$(grep -nF -- '- name: Draft, attach, publish, and verify immutable release' "$WORKFLOW" | head -1 | cut -d: -f1)"
EARLY_SETTING_LINE="$(grep -nF -- '- name: Require repository Immutable Releases before deterministic validation' "$WORKFLOW" | head -1 | cut -d: -f1)"
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
