#!/bin/bash

zensu_hook_enabled() {
  local key="$1"
  local config="${ZENSU_CONFIG:-$HOME/.zensu/config.json}"
  [ ! -f "$config" ] && return 0
  command -v node >/dev/null 2>&1 || return 0   # node missing → fall back to enabled
  local val
  val=$(node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
      console.log(j.hooks && j.hooks[process.argv[2]] === false ? '0' : '1');
    } catch (_) { console.log('1'); }
  " "$config" "$key" 2>/dev/null)
  [ -z "$val" ] && return 0                      # any other failure → enabled
  [ "$val" = "1" ]
}
