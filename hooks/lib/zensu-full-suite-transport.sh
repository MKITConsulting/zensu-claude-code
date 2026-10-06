#!/bin/bash

zensu_full_suite_policy_node() {
  local label="${1:-zensu full-suite}" mode="${2:-}" refresh="${3:-0}"
  local session_key="${ZENSU_SESSION_KEY:-}" project_dir="${CLAUDE_PROJECT_DIR:-}"
  local lib data dir dir_native exclusions rc=0
  if ! command -v node >/dev/null 2>&1; then
    echo "$label: node is required for the full-suite policy" >&2
    return 2
  fi
  lib="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/lib")" || {
    echo "$label: the full-suite policy module cannot be resolved" >&2
    return 2
  }
  data="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "${CLAUDE_PLUGIN_DATA:-}")" || {
    echo "$label: CLAUDE_PLUGIN_DATA does not name a usable directory" >&2
    return 2
  }
  dir="$(mktemp -d 2>/dev/null)" || {
    echo "$label: no temporary directory available" >&2
    return 2
  }
  dir_native="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "$dir")" || {
    rm -rf "$dir"
    echo "$label: the temporary directory cannot be resolved" >&2
    return 2
  }
  printf '%s' "$(zensu_full_suite_marker_state "$project_dir" "$session_key")" > "$dir/marker-state"
  printf '%s' "$(zensu_evidence_ci_config_json)" > "$dir/ci-config.json"
  printf '%s' "$(zensu_evidence_full_suite_command)" > "$dir/full-suite-command"
  exclusions="${MSYS2_ENV_CONV_EXCL:-}"
  if command -v zensu_msys_env_exclusions >/dev/null 2>&1; then
    exclusions="$(zensu_msys_env_exclusions ZENSU_FSP_LIB ZENSU_FSP_DIR ZENSU_FSP_PLUGIN_DATA ZENSU_FSP_PROJECT_ROOT)" || exclusions="${MSYS2_ENV_CONV_EXCL:-}"
  fi
  MSYS2_ENV_CONV_EXCL="$exclusions" \
  ZENSU_FSP_LIB="$lib/full-suite-policy-v1.js" \
  ZENSU_FSP_DIR="$dir_native" \
  ZENSU_FSP_PLUGIN_DATA="$data" \
  ZENSU_FSP_SESSION_KEY="$session_key" \
  ZENSU_FSP_PROJECT_ROOT="${ZENSU_PROJECT_ROOT:-}" \
  ZENSU_FSP_REFRESH="$refresh" \
  ZENSU_FSP_MODE="$mode" \
  ZENSU_FSP_LABEL="$label" \
    node -e 'require(process.env.ZENSU_FSP_LIB).main([process.env.ZENSU_FSP_MODE]).then((code) => { process.exitCode = code; }, (error) => { process.stderr.write(process.env.ZENSU_FSP_LABEL + ": " + (error && error.message ? error.message : String(error)) + "\n"); process.exitCode = 2; })' || rc=$?
  rm -rf "$dir"
  return "$rc"
}
