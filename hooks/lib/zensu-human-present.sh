#!/bin/bash

zensu_human_present() {
  local payload="${1:-}" mode='' pattern='"permission_mode"[[:space:]]*:[[:space:]]*"([A-Za-z]+)"'
  if [[ "$payload" =~ $pattern ]]; then
    mode="${BASH_REMATCH[1]}"
  fi
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    (sdk-cli|claude-code-github-action) printf 'no\n'; return 0 ;;
  esac
  if [ "$mode" = dontAsk ]; then
    printf 'no\n'
    return 0
  fi
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    (cli|claude-desktop|claude-vscode) printf 'yes\n' ;;
    (*) printf 'unknown\n' ;;
  esac
}

zensu_human_present_substitute() {
  local value body
  case "${1:-}" in
    (yes|no|unknown) value="$1" ;;
    (*) value=unknown ;;
  esac
  body="$(cat)"
  printf '%s\n' "${body//__ZENSU_HUMAN_PRESENT__/$value}"
}
