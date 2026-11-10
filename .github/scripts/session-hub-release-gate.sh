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

CLAUDE_HOME="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/session-hub-gate-XXXXXX")"
trap 'rm -rf "$CLAUDE_HOME"' EXIT
pinned_claude() {
  env CLAUDE_CONFIG_DIR="$CLAUDE_HOME" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 claude "$@"
}

FOUND="$(pinned_claude --version)"
if [ "$FOUND" != "$CLAUDE_CODE_VERSION (Claude Code)" ]; then
  echo "::error::the release gate needs Claude Code $CLAUDE_CODE_VERSION, found: $FOUND"
  exit 1
fi
pinned_claude plugin validate .
pinned_claude plugin validate plugins/session-hub
for suite in "${SUITES[@]}"; do
  echo "::group::$suite"
  env -u CLAUDE_CONFIG_DIR bash "tests/structure/$suite.sh"
  echo "::endgroup::"
done
