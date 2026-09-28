#!/bin/bash

zensu_browser_consent_marked() {
  local _zensu_pair _zensu_scan _zensu_marked
  _zensu_pair=$'\001'
  _zensu_scan="$(printf '%s' "$1" | LC_ALL=C sed -e 's/\\\\/'"$_zensu_pair"'/g' -e 's/'"$_zensu_pair"'\\r\\n//g' -e 's/'"$_zensu_pair"'\\n//g' 2>/dev/null | LC_ALL=C tr -d "\"'\\\\$_zensu_pair" 2>/dev/null)" || _zensu_scan="$1"
  [ -n "$_zensu_scan" ] || _zensu_scan="$1"
  _zensu_marked=1
  shopt -s nocasematch
  case "$_zensu_scan" in
    *playwright-cli*|*@playwright/cli*|*@playwright\\/cli*)
      case "$_zensu_scan" in
        *zensu-verify-*) _zensu_marked=0 ;;
        *)
          case "${PLAYWRIGHT_CLI_SESSION:-}" in
            *zensu-verify-*) _zensu_marked=0 ;;
          esac
          ;;
      esac
      ;;
  esac
  shopt -u nocasematch
  return "$_zensu_marked"
}
