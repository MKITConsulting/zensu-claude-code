#!/bin/bash
# Test-only fresh-session bootstrap. Source this file so the caller receives
# the exact exports written by the real Claude SessionStart hook.

_ZENSU_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 1
_ZENSU_TEST_PROJECT="${CLAUDE_PROJECT_DIR:?test baseline requires CLAUDE_PROJECT_DIR}"
_ZENSU_TEST_SESSION="${1:?usage: source initialize-baseline.sh SESSION_ID}"
_ZENSU_TEST_DATA="${ZENSU_TEST_PLUGIN_DATA:-$_ZENSU_TEST_PROJECT/.session-control-test/plugin-data}"
_ZENSU_TEST_ENV="$_ZENSU_TEST_PROJECT/.session-control-test/session.env"
mkdir -p "$_ZENSU_TEST_DATA" "$(dirname "$_ZENSU_TEST_ENV")" || return 1
: >"$_ZENSU_TEST_ENV" || return 1

_ZENSU_TEST_PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({
  hook_event_name:"SessionStart", session_id:process.argv[1], cwd:process.argv[2]
}))' "$_ZENSU_TEST_SESSION" "$_ZENSU_TEST_PROJECT")" || return 1
printf '%s' "$_ZENSU_TEST_PAYLOAD" | \
  CLAUDE_PLUGIN_ROOT="$_ZENSU_TEST_ROOT" CLAUDE_PLUGIN_DATA="$_ZENSU_TEST_DATA" \
  CLAUDE_ENV_FILE="$_ZENSU_TEST_ENV" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
  bash "$_ZENSU_TEST_ROOT/hooks/session-start-session-control.sh" >/dev/null || return 1

# shellcheck disable=SC1090
. "$_ZENSU_TEST_ENV" || return 1
export CLAUDE_PLUGIN_DATA="$_ZENSU_TEST_DATA"
unset _ZENSU_TEST_ROOT _ZENSU_TEST_PROJECT _ZENSU_TEST_SESSION _ZENSU_TEST_DATA \
  _ZENSU_TEST_ENV _ZENSU_TEST_PAYLOAD
