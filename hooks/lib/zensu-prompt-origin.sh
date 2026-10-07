#!/bin/bash

zensu_prompt_origin_kind() {
  case "${1-}" in
    *'"origin"'*) ;;
    *) return 0 ;;
  esac
  command -v node >/dev/null 2>&1 || return 0
  printf '%s' "$1" | node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}");
      const o = j && typeof j === "object" ? j.origin : null;
      const k = o && typeof o === "object" ? o.kind : null;
      if (typeof k === "string" && /^[a-z][a-z-]{0,63}$/.test(k)) process.stdout.write(k);
    } catch (_) {}
  ' 2>/dev/null
  return 0
}

zensu_prompt_origin_slash() {
  local body="$1" name rest
  case "$body" in
    '<command-name>'*|'<command-message>'*)
      case "$body" in
        *'<command-args>'*)
          rest="${body#*"<command-args>"}"
          rest="${rest%%"</command-args>"*}"
          rest="${rest#"${rest%%[![:space:]]*}"}"
          [ -n "$rest" ] && { printf 'slash-command-args'; return 0; }
          ;;
      esac
      printf 'slash-command'
      return 0
      ;;
  esac
  name="${body%%[[:space:]]*}"
  case "$name" in
    /[[:alnum:]]*) ;;
    *) printf 'typed'; return 0 ;;
  esac
  case "${name#/}" in
    *[![:alnum:]_.:-]*) printf 'typed'; return 0 ;;
  esac
  rest="${body#"$name"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  if [ -n "$rest" ]; then
    printf 'slash-command-args'
  else
    printf 'slash-command'
  fi
}

zensu_prompt_origin() {
  local body="${1-}" kind head close='</system-reminder>'
  body="${body:0:16384}"
  kind="$(zensu_prompt_origin_kind "${2-}")"
  if [ "$kind" = "task-notification" ]; then
    printf 'task-notification'
    return 0
  fi
  while :; do
    body="${body#"${body%%[![:space:]]*}"}"
    case "$body" in
      '<system-reminder>'*) ;;
      *) break ;;
    esac
    head="${body%%"$close"*}"
    [ "$head" = "$body" ] && break
    body="${body:$(( ${#head} + ${#close} ))}"
  done
  if [ "$kind" != "human" ]; then
    case "$body" in
      '<task-notification>'*) printf 'task-notification'; return 0 ;;
      '<ci-monitor-event>'*|'<ci-monitor-event '*) printf 'ci-monitor-event'; return 0 ;;
    esac
  fi
  case "$body" in
    '<bash-input>'*) printf 'bash-input'; return 0 ;;
    '/'*|'<command-name>'*|'<command-message>'*) zensu_prompt_origin_slash "$body"; return 0 ;;
  esac
  printf 'typed'
}
