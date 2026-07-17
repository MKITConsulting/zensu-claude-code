#!/bin/bash
# Test-only fresh-session bootstrap. SessionStart creates the real private
# record/CAS without touching CLAUDE_ENV_FILE; then the same per-Bash binder
# used by model-side helpers populates this test shell only.

_ZENSU_TEST_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 1
_ZENSU_TEST_ROOT="${2:-$_ZENSU_TEST_SOURCE_ROOT}"
_ZENSU_TEST_ROOT="$(cd "$_ZENSU_TEST_ROOT" && pwd -P)" || return 1
_ZENSU_TEST_HOST_PATH="$_ZENSU_TEST_SOURCE_ROOT/hooks/lib/zensu-host-path.sh"
_ZENSU_TEST_RAW_PROJECT="${CLAUDE_PROJECT_DIR:?test baseline requires CLAUDE_PROJECT_DIR}"
_ZENSU_TEST_SESSION="${1:?usage: source initialize-baseline.sh SESSION_ID [PLUGIN_ROOT]}"
_ZENSU_TEST_RAW_DATA="${ZENSU_TEST_PLUGIN_DATA:-$_ZENSU_TEST_RAW_PROJECT/.session-control-test/plugin-data}"
mkdir -p "$_ZENSU_TEST_RAW_DATA" || return 1
_ZENSU_TEST_PROJECT="$(bash "$_ZENSU_TEST_HOST_PATH" "$_ZENSU_TEST_RAW_PROJECT")" || return 1
_ZENSU_TEST_DATA="$(bash "$_ZENSU_TEST_HOST_PATH" "$_ZENSU_TEST_RAW_DATA")" || return 1

_ZENSU_TEST_PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({
  hook_event_name:"SessionStart", source:"startup", session_id:process.argv[1], cwd:process.argv[2]
}))' "$_ZENSU_TEST_SESSION" "$_ZENSU_TEST_PROJECT")" || return 1
printf '%s' "$_ZENSU_TEST_PAYLOAD" | \
  CLAUDE_PLUGIN_ROOT="$_ZENSU_TEST_ROOT" CLAUDE_PLUGIN_DATA="$_ZENSU_TEST_DATA" \
  env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
  bash "$_ZENSU_TEST_ROOT/hooks/session-start-session-control.sh" >/dev/null || return 1

export CLAUDE_PLUGIN_DATA="$_ZENSU_TEST_DATA"
export CLAUDE_CODE_SESSION_ID="$_ZENSU_TEST_SESSION"
# shellcheck disable=SC1090
. "$_ZENSU_TEST_ROOT/hooks/lib/zensu-session.sh" || return 1
zensu_bind_model_session || return 1
unset _ZENSU_TEST_SOURCE_ROOT _ZENSU_TEST_ROOT _ZENSU_TEST_HOST_PATH \
  _ZENSU_TEST_RAW_PROJECT _ZENSU_TEST_PROJECT _ZENSU_TEST_SESSION \
  _ZENSU_TEST_RAW_DATA _ZENSU_TEST_DATA _ZENSU_TEST_PAYLOAD
