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

case "${1:-}" in
  --?*) _ZENSU_WO_VERB="${1#--}"; shift ;;
  *)
    echo "zensu-work-order.sh: usage: zensu-work-order.sh --<verb> [options]" >&2
    exit 2
    ;;
esac

command -v node >/dev/null 2>&1 || {
  echo "zensu-work-order.sh: node is not on PATH" >&2
  exit 2
}

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
if ! zensu_bind_model_session; then
  echo "zensu-work-order.sh: rendered Session Control binding unavailable" >&2
  if [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    echo "zensu-work-order.sh: CLAUDE_CODE_SESSION_ID is not set — this helper must run from Claude Code's own Bash tool." >&2
  fi
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    echo "zensu-work-order.sh: CLAUDE_PLUGIN_DATA is not set — run this helper exactly as the Zensu skill renders it, including its leading plugin-data assignment." >&2
  fi
  exit 2
fi
if ! _ZENSU_WO_PD="$(zensu_resolve_project_dir)" || [ -z "$_ZENSU_WO_PD" ]; then
  echo "zensu-work-order.sh: Session Control project context unavailable" >&2
  exit 2
fi
if ! _ZENSU_WO_KEY="$(zensu_resolve_session_id "")" || [ -z "$_ZENSU_WO_KEY" ]; then
  echo "zensu-work-order.sh: Session Control session identity unavailable" >&2
  exit 2
fi
_ZENSU_WO_EXCL="$(zensu_msys_env_exclusions WO_PROJECT_ROOT WO_PLUGIN_DATA 2>/dev/null)" || _ZENSU_WO_EXCL=""

_wo_node() {
  (
    cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" 2>/dev/null || exit 2
    export WO_PROJECT_ROOT="$ZENSU_PROJECT_ROOT" WO_SESSION_KEY="$_ZENSU_WO_KEY"
    export WO_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-}" WO_MODEL_PROJECT_DIR="$_ZENSU_WO_PD"
    if [ -n "$_ZENSU_WO_EXCL" ]; then export MSYS2_ENV_CONV_EXCL="$_ZENSU_WO_EXCL"; fi
    exec node ./work-order-v1.js "$@"
  )
}

_wo_cancel_run() {
  local run_id="$1"
  [ -n "$run_id" ] || return 0
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh" || return 1
  autopilot_apply_event "$run_id" work-order-end CANCEL '{}' "$_ZENSU_WO_PD" "$_ZENSU_WO_KEY"
}

case "$_ZENSU_WO_VERB" in
  bind-spec)
    _ZENSU_WO_RUN=""
    _ZENSU_WO_ARGS=("$@")
    while [ $# -gt 0 ]; do
      case "$1" in
        --run) [ $# -ge 2 ] || { echo "zensu-work-order.sh --bind-spec: missing --run value" >&2; exit 2; }; _ZENSU_WO_RUN="$2"; shift 2 ;;
        *) echo "zensu-work-order.sh --bind-spec: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    [ -n "$_ZENSU_WO_RUN" ] || { echo "zensu-work-order.sh --bind-spec requires --run <id>" >&2; exit 2; }
    _ZENSU_WO_PAYLOAD="$(WO_EMIT=value _wo_node bind-spec "${_ZENSU_WO_ARGS[@]}")"
    _ZENSU_WO_RC=$?
    if [ "$_ZENSU_WO_RC" -ne 0 ]; then
      exit "$_ZENSU_WO_RC"
    fi
    [ -n "$_ZENSU_WO_PAYLOAD" ] || { echo "zensu-work-order.sh --bind-spec: the runtime returned no binding" >&2; exit 2; }
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh" || exit 2
    autopilot_apply_event "$_ZENSU_WO_RUN" order-spec-bound ORDER_SPEC_BOUND "$_ZENSU_WO_PAYLOAD" \
      "$_ZENSU_WO_PD" "$_ZENSU_WO_KEY" || {
      _ZENSU_WO_RC=$?
      echo "zensu-work-order.sh --bind-spec: Zensu accepted the implementing stage but the run did not record ORDER_SPEC_BOUND (exit $_ZENSU_WO_RC); run --bind-spec again" >&2
      exit 7
    }
    echo "work-order: spec bound, Autopilot run $_ZENSU_WO_RUN is at AWAIT_TDD"
    exit 0
    ;;
  review-import)
    _ZENSU_WO_RUN=""
    _ZENSU_WO_ARGS=("$@")
    while [ $# -gt 0 ]; do
      case "$1" in
        --run) [ $# -ge 2 ] || { echo "zensu-work-order.sh --review-import: missing --run value" >&2; exit 2; }; _ZENSU_WO_RUN="$2"; shift 2 ;;
        *) echo "zensu-work-order.sh --review-import: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    [ -n "$_ZENSU_WO_RUN" ] || { echo "zensu-work-order.sh --review-import requires --run <id>" >&2; exit 2; }
    _ZENSU_WO_OUT="$(WO_EMIT=value _wo_node review-import "${_ZENSU_WO_ARGS[@]}")"
    _ZENSU_WO_RC=$?
    if [ "$_ZENSU_WO_RC" -ne 0 ]; then
      exit "$_ZENSU_WO_RC"
    fi
    _ZENSU_WO_PAYLOAD="$(printf '%s' "$_ZENSU_WO_OUT" | node -e '
      let input = "";
      process.stdin.on("data", (chunk) => { input += chunk; });
      process.stdin.on("end", () => {
        try {
          const body = JSON.parse(input);
          if (body && body.payload && typeof body.payload === "object") process.stdout.write(JSON.stringify(body.payload));
        } catch (_) {}
      });
    ' 2>/dev/null)"
    if [ -n "$_ZENSU_WO_PAYLOAD" ]; then
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh" || exit 2
      autopilot_apply_event "$_ZENSU_WO_RUN" team-review-imported TEAM_REVIEW_IMPORTED "$_ZENSU_WO_PAYLOAD" \
        "$_ZENSU_WO_PD" "$_ZENSU_WO_KEY" || {
        _ZENSU_WO_RC=$?
        echo "zensu-work-order.sh --review-import: the run did not record the imported team review (exit $_ZENSU_WO_RC); run --review-import again" >&2
        exit 7
      }
    fi
    printf '%s\n' "$_ZENSU_WO_OUT"
    exit 0
    ;;
  start)
    _ZENSU_WO_OUT="$(_wo_node start "$@")"
    _ZENSU_WO_RC=$?
    if [ -n "$_ZENSU_WO_OUT" ]; then printf '%s\n' "$_ZENSU_WO_OUT"; fi
    if [ "$_ZENSU_WO_RC" -eq 0 ]; then
      _ZENSU_WO_RELEASE="$(_wo_node release-plan 2>/dev/null)" || _ZENSU_WO_RELEASE=""
      if [ -n "$_ZENSU_WO_RELEASE" ]; then
        _ZENSU_WO_ORDER_ID="$(printf '%s' "$_ZENSU_WO_OUT" | node -e '
          let input = "";
          process.stdin.on("data", (chunk) => { input += chunk; });
          process.stdin.on("end", () => {
            try {
              const body = JSON.parse(input);
              if (body && typeof body.orderId === "string" && Number.isSafeInteger(body.attempt)) process.stdout.write(`${body.orderId} ${body.attempt}`);
            } catch (_) {}
          });
        ' 2>/dev/null)"
        if [ -n "$_ZENSU_WO_ORDER_ID" ] && source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-autopilot-state.sh"; then
          while IFS= read -r _ZENSU_WO_STALE_RUN; do
            [ -n "$_ZENSU_WO_STALE_RUN" ] || continue
            autopilot_release_work_order_run "$_ZENSU_WO_STALE_RUN" "${_ZENSU_WO_ORDER_ID% *}" "${_ZENSU_WO_ORDER_ID#* }" "$_ZENSU_WO_PD" \
              || echo "zensu-work-order.sh --start: the Autopilot run $_ZENSU_WO_STALE_RUN of an earlier attempt could not be released; a new run in this checkout will be refused" >&2
          done <<EOF_RELEASE
$_ZENSU_WO_RELEASE
EOF_RELEASE
        fi
      fi
    fi
    exit "$_ZENSU_WO_RC"
    ;;
  finish|ask|plan-approval)
    _ZENSU_WO_OUT="$(_wo_node "$_ZENSU_WO_VERB" "$@")"
    _ZENSU_WO_RC=$?
    _ZENSU_WO_CANCEL="$(printf '%s' "$_ZENSU_WO_OUT" | node -e '
      let input = "";
      process.stdin.on("data", (chunk) => { input += chunk; });
      process.stdin.on("end", () => {
        try {
          const body = JSON.parse(input);
          if (body && typeof body.cancelRun === "string") process.stdout.write(body.cancelRun);
        } catch (_) {}
      });
    ' 2>/dev/null)"
    if [ -n "$_ZENSU_WO_OUT" ]; then printf '%s\n' "$_ZENSU_WO_OUT"; fi
    if [ -n "$_ZENSU_WO_CANCEL" ]; then
      _wo_cancel_run "$_ZENSU_WO_CANCEL" \
        || echo "zensu-work-order.sh --$_ZENSU_WO_VERB: the local Autopilot run $_ZENSU_WO_CANCEL could not be cancelled; run --finish" >&2
    fi
    exit "$_ZENSU_WO_RC"
    ;;
  *)
    _wo_node "$_ZENSU_WO_VERB" "$@"
    exit $?
    ;;
esac
