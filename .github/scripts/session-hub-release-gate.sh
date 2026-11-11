#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"

CLAUDE_CODE_VERSION="2.1.317"
SUITES=(
  test-session-hub-plugin
  test-session-hub-receipt
  test-session-hub-usage-feed
  test-session-trail-skill
  test-session-trail-lineage
  test-session-trail-verdict
  test-version-sync
  test-immutable-marketplace-release
)

for suite in "${SUITES[@]}"; do
  if [ ! -f "tests/structure/$suite.sh" ]; then
    echo "::error::the release gate names tests/structure/$suite.sh, which does not exist"
    exit 1
  fi
done
echo "::group::install probe (Claude Code $CLAUDE_CODE_VERSION)"
bash .github/scripts/session-hub-install-probe.sh "$CLAUDE_CODE_VERSION"
echo "::endgroup::"
for suite in "${SUITES[@]}"; do
  echo "::group::$suite"
  env -u CLAUDE_CONFIG_DIR bash "tests/structure/$suite.sh"
  echo "::endgroup::"
done
