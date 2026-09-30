#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

FS_USAGE="usage: zensu-full-suite.sh --ci|--local|--auto --repo|--session [--workflow <file>] [--job <name pattern>] | --status [--refresh]"
FS_RUNNER=""
FS_SCOPE=""
FS_STATUS=false
FS_REFRESH=0
FS_WORKFLOW=""
FS_JOB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ci|--local|--auto)
      [ -z "$FS_RUNNER" ] || { echo "$FS_USAGE" >&2; exit 2; }
      FS_RUNNER="${1#--}"; shift ;;
    --repo|--session)
      [ -z "$FS_SCOPE" ] || { echo "$FS_USAGE" >&2; exit 2; }
      FS_SCOPE="${1#--}"; shift ;;
    --status) FS_STATUS=true; shift ;;
    --refresh) FS_REFRESH=1; shift ;;
    --workflow)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "$FS_USAGE" >&2; exit 2; }
      FS_WORKFLOW="$2"; shift 2 ;;
    --job)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "$FS_USAGE" >&2; exit 2; }
      FS_JOB="$2"; shift 2 ;;
    *) echo "$FS_USAGE" >&2; exit 2 ;;
  esac
done
if [ "$FS_STATUS" = true ]; then
  [ -z "$FS_RUNNER$FS_SCOPE$FS_WORKFLOW$FS_JOB" ] || { echo "$FS_USAGE" >&2; exit 2; }
else
  [ -n "$FS_RUNNER" ] && [ -n "$FS_SCOPE" ] && [ "$FS_REFRESH" = 0 ] || { echo "$FS_USAGE" >&2; exit 2; }
  if [ -n "$FS_WORKFLOW$FS_JOB" ] && { [ "$FS_RUNNER" != ci ] || [ "$FS_SCOPE" != repo ]; }; then
    echo "zensu-full-suite.sh: --workflow and --job belong to --ci --repo only" >&2
    exit 2
  fi
fi

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-marker-write.sh" && declare -F zensu_write_session_marker >/dev/null || {
  echo "zensu-full-suite.sh: cannot load hooks/lib/zensu-marker-write.sh" >&2
  exit 2
}
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if ! zensu_bind_model_session; then
  echo "zensu-full-suite.sh: rendered Session Control binding unavailable" >&2
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "zensu-full-suite.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool, which supplies the host session id." >&2
  fi
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "zensu-full-suite.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the full-suite skill renders it, including its leading 'CLAUDE_PLUGIN_DATA=...' assignment; never hand-build the command." >&2
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "zensu-full-suite.sh: node is not on PATH — Session Control cannot bind without it." >&2
  fi
  exit 2
fi
if ! _zensu_pd="$(zensu_resolve_project_dir)" || [ -z "$_zensu_pd" ]; then
  echo "zensu-full-suite.sh: Session Control project context unavailable" >&2
  exit 2
fi
if ! _zensu_sid="$(zensu_resolve_session_id)" || [ -z "$_zensu_sid" ]; then
  echo "zensu-full-suite.sh: Session Control session identity unavailable" >&2
  exit 2
fi
export CLAUDE_PROJECT_DIR="$_zensu_pd"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-full-suite-transport.sh"

FS_PROJECT_DIR="$_zensu_pd"
if ! FS_MARKER="$(zensu_full_suite_marker_path "$_zensu_pd" "$_zensu_sid")" || [ -z "$FS_MARKER" ]; then
  echo "zensu-full-suite.sh: cannot resolve the session marker path" >&2
  exit 2
fi
unset _zensu_pd _zensu_sid

if [ "$FS_STATUS" = true ]; then
  zensu_full_suite_policy_node "zensu-full-suite.sh" status "$FS_REFRESH"
  exit $?
fi

case "$FS_SCOPE" in
  session)
    zensu_write_session_marker zensu-full-suite.sh "$FS_PROJECT_DIR" "$FS_MARKER" "{\"runner\":\"$FS_RUNNER\"}"
    case "$FS_RUNNER" in
      ci)    echo "full-suite: ci for this session only; later sessions ask again" ;;
      local) echo "full-suite: local for this session" ;;
      auto)  echo "full-suite: the session choice is released; the clone and config decide again" ;;
    esac
    ;;
  repo)
    case "$FS_RUNNER" in
      auto) export ZENSU_FSP_RUNNER=clear ;;
      *)    export ZENSU_FSP_RUNNER="$FS_RUNNER" ;;
    esac
    export ZENSU_FSP_WORKFLOW="$FS_WORKFLOW" ZENSU_FSP_JOB="$FS_JOB"
    zensu_full_suite_policy_node "zensu-full-suite.sh" set-clone || exit $?
    ;;
esac
zensu_full_suite_policy_node "zensu-full-suite.sh" status
exit $?
