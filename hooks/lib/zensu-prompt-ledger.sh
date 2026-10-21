#!/bin/bash

_zensu_prompt_ledger_entry_name() {
  local contract="${1:-}" root="${CLAUDE_PLUGIN_ROOT:-}" name
  case "$contract" in
    (tdd-strict|tdd-vanilla|router|zen-none|zen-armed) ;;
    (*) return 1 ;;
  esac
  [ -n "$root" ] || return 1
  name="${root##*/}"
  name="${name//[^A-Za-z0-9._-]/_}"
  name="${name:0:40}"
  [ -n "$name" ] || return 1
  _ZENSU_PROMPT_LEDGER_ENTRY="${contract}--${#root}-${name}"
}

_zensu_prompt_ledger_paths() {
  local key="${1:-}" data="${CLAUDE_PLUGIN_DATA:-}"
  case "$data" in
    (""|*$'\r'*|*$'\n'*) return 1 ;;
  esac
  [ -d "$data" ] && [ ! -L "$data" ] || return 1
  declare -F zensu_session_key_canonical >/dev/null 2>&1 || return 1
  zensu_session_key_canonical "$key" || return 1
  _ZENSU_PROMPT_LEDGER_BASE="$data/prompt-ledger"
  _ZENSU_PROMPT_LEDGER_ROOT="$data/prompt-ledger/v1"
  _ZENSU_PROMPT_LEDGER_DIR="$data/prompt-ledger/v1/$key"
}

zensu_prompt_ledger_has() {
  local path
  _zensu_prompt_ledger_entry_name "${2:-}" || return 1
  _zensu_prompt_ledger_paths "${1:-}" || return 1
  for path in "$_ZENSU_PROMPT_LEDGER_BASE" "$_ZENSU_PROMPT_LEDGER_ROOT" \
      "$_ZENSU_PROMPT_LEDGER_DIR" "$_ZENSU_PROMPT_LEDGER_DIR/$_ZENSU_PROMPT_LEDGER_ENTRY"; do
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
  done
  [ ! -e "$_ZENSU_PROMPT_LEDGER_DIR.stale" ] && [ ! -L "$_ZENSU_PROMPT_LEDGER_DIR.stale" ] || return 1
  [ -w "$_ZENSU_PROMPT_LEDGER_ROOT" ] && [ -w "$_ZENSU_PROMPT_LEDGER_DIR" ]
}

zensu_prompt_ledger_mark() {
  local path
  _zensu_prompt_ledger_entry_name "${2:-}" || return 1
  _zensu_prompt_ledger_paths "${1:-}" || return 1
  for path in "$_ZENSU_PROMPT_LEDGER_BASE" "$_ZENSU_PROMPT_LEDGER_ROOT" \
      "$_ZENSU_PROMPT_LEDGER_DIR" "$_ZENSU_PROMPT_LEDGER_DIR/$_ZENSU_PROMPT_LEDGER_ENTRY"; do
    [ ! -L "$path" ] || return 1
    if [ ! -e "$path" ]; then
      mkdir -m 700 -- "$path" 2>/dev/null || { [ -d "$path" ] && [ ! -L "$path" ]; } || return 1
    fi
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
  done
}

zensu_prompt_ledger_reset() {
  local path
  _zensu_prompt_ledger_paths "${1:-}" || return 1
  for path in "$_ZENSU_PROMPT_LEDGER_BASE" "$_ZENSU_PROMPT_LEDGER_ROOT"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
      rm -f -- "$path" 2>/dev/null
      return 0
    fi
    [ -e "$path" ] || return 0
  done
  rm -rf -- "$_ZENSU_PROMPT_LEDGER_DIR" 2>/dev/null
  if [ -e "$_ZENSU_PROMPT_LEDGER_DIR" ] || [ -L "$_ZENSU_PROMPT_LEDGER_DIR" ]; then
    mkdir -m 700 -- "$_ZENSU_PROMPT_LEDGER_DIR.stale" 2>/dev/null
    return 1
  fi
  rm -rf -- "$_ZENSU_PROMPT_LEDGER_DIR.stale" 2>/dev/null
  [ ! -e "$_ZENSU_PROMPT_LEDGER_DIR.stale" ] && [ ! -L "$_ZENSU_PROMPT_LEDGER_DIR.stale" ]
}

zensu_prompt_ledger_sweep() {
  local data="${CLAUDE_PLUGIN_DATA:-}" root path
  case "$data" in
    (""|*$'\r'*|*$'\n'*) return 1 ;;
  esac
  root="$data/prompt-ledger/v1"
  for path in "$data" "$data/prompt-ledger" "$root"; do
    [ -d "$path" ] && [ ! -L "$path" ] || return 0
  done
  find "$root" -mindepth 1 -maxdepth 1 -type d -name 'scv1_*' ! -name '*.stale' -mtime +14 \
    -exec rm -rf -- {} + 2>/dev/null
  for path in "$root"/scv1_*.stale; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -e "${path%.stale}" ] || [ -L "${path%.stale}" ] || rm -rf -- "$path" 2>/dev/null
  done
  return 0
}
