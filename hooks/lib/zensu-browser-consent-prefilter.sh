#!/bin/bash

zensu_browser_consent_marked() {
  local _zensu_pair _zensu_scan _zensu_marked _zensu_drop _zensu_join
  _zensu_pair=$'\001'
  _zensu_drop="\"'\\\\\`$_zensu_pair"
  _zensu_join='s/'"$_zensu_pair"'\\n//g'
  case "$1" in
    *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*)
      _zensu_drop="$_zensu_drop+()\$ "$'\t\342\200\230\231\232\233\234\235\236'
      _zensu_join="$_zensu_join"';s/\\[nrt]//g;s/\\u201[89a-eA-E]//g'
      ;;
  esac
  _zensu_scan="$(printf '%s' "$1" | LC_ALL=C sed -e 's/\\\\/'"$_zensu_pair"'/g' -e 's/'"$_zensu_pair"'\\r\\n//g' -e "$_zensu_join" 2>/dev/null | LC_ALL=C tr -d "$_zensu_drop" 2>/dev/null)" || _zensu_scan="$1"
  [ -n "$_zensu_scan" ] || _zensu_scan="$1"
  _zensu_marked=1
  shopt -s nocasematch
  case "$_zensu_scan" in
    *playwright-cli*|*@playwright/cli*|*@playwright\\/cli*)
      case "$_zensu_scan" in
        *zensu-verify-*|*verify-feature-runs*|*--config*|*playwright_mcp_config*) _zensu_marked=0 ;;
        *)
          case "${PLAYWRIGHT_CLI_SESSION:-}" in
            *zensu-verify-*) _zensu_marked=0 ;;
          esac
          ;;
      esac
      ;;
  esac
  if [ "$_zensu_marked" = 1 ]; then
    case "$1" in
      *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*)
        case "$_zensu_scan" in
          *u{*|*verify*|*config*) _zensu_marked=0 ;;
          *)
            case "${PLAYWRIGHT_CLI_SESSION:-}" in
              *zensu-verify-*) _zensu_marked=0 ;;
            esac
            ;;
        esac
        ;;
    esac
  fi
  shopt -u nocasematch
  return "$_zensu_marked"
}
