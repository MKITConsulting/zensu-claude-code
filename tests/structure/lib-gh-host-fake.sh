#!/bin/bash

gh_host_fake_header() {
  cat <<'HEADER'
#!/bin/bash
gh_host_fake_selected() {
  local seen=0 host="" repo="" previous="" arg
  for arg in "$@"; do
    case "$previous" in
      --hostname) seen=1; host="$arg" ;;
      -R|--repo) repo="$arg" ;;
    esac
    case "$arg" in
      --hostname=*) seen=1; host="${arg#--hostname=}" ;;
      --repo=*) repo="${arg#--repo=}" ;;
    esac
    previous="$arg"
  done
  if [ "$seen" = 0 ] && [ -z "$repo" ] && [ "${1:-}" = pr ]; then repo="${GH_REPO:-}"; fi
  if [ "$seen" = 0 ]; then
    case "$repo" in
      */*/*) seen=1; host="${repo%%/*}" ;;
    esac
  fi
  if [ "$seen" = 1 ]; then printf '%s' "$host"; else printf '%s' "${GH_HOST:-github.com}"; fi
}
case "${1:-}" in
  config)
    if [ "${2:-}" = get ] && [ "${3:-}" = user ]; then
      gh_host_fake_login="" gh_host_fake_previous=""
      for gh_host_fake_arg in "$@"; do
        case "$gh_host_fake_previous" in -h|--host) gh_host_fake_login="$gh_host_fake_arg" ;; esac
        gh_host_fake_previous="$gh_host_fake_arg"
      done
      [ -z "${FAKE_GH_CONFIG_LOG:-}" ] || printf '%s\n' "$gh_host_fake_login" >> "$FAKE_GH_CONFIG_LOG"
      if [ -n "$gh_host_fake_login" ]; then
        case " ${FAKE_GH_EMPTY_LOGINS:-} " in *" $gh_host_fake_login "*) exit 0 ;; esac
        case " ${FAKE_GH_LOGINS:-} " in *" $gh_host_fake_login "*) printf 'fake-user\n'; exit 0 ;; esac
      fi
      printf 'could not find key "user"\n' >&2
      exit 1
    fi
    ;;
  api|pr)
    gh_host_fake_host="$(gh_host_fake_selected "$@")"
    [ -z "${FAKE_GH_HOSTS_LOG:-}" ] || printf '%s %s %s\n' "$gh_host_fake_host" "${1:-}" "${2:-}" >> "$FAKE_GH_HOSTS_LOG"
    if [ -n "${FAKE_GH_ENV_LOG:-}" ]; then
      gh_host_fake_tokens=""
      [ -z "${GH_TOKEN:-}" ] || gh_host_fake_tokens="$gh_host_fake_tokens GH_TOKEN"
      [ -z "${GITHUB_TOKEN:-}" ] || gh_host_fake_tokens="$gh_host_fake_tokens GITHUB_TOKEN"
      [ -z "${GH_ENTERPRISE_TOKEN:-}" ] || gh_host_fake_tokens="$gh_host_fake_tokens GH_ENTERPRISE_TOKEN"
      [ -z "${GITHUB_ENTERPRISE_TOKEN:-}" ] || gh_host_fake_tokens="$gh_host_fake_tokens GITHUB_ENTERPRISE_TOKEN"
      printf '%s%s\n' "$gh_host_fake_host" "$gh_host_fake_tokens" >> "$FAKE_GH_ENV_LOG"
    fi
    if [ "$gh_host_fake_host" != "${FAKE_GH_PR_HOST:-github.com}" ]; then
      printf 'error connecting to %s\n' "$gh_host_fake_host" >&2
      exit 1
    fi
    ;;
esac
HEADER
}

gh_host_fake_write() {
  local target="${1:-}"
  [ -n "$target" ] || return 1
  { gh_host_fake_header; cat; } > "$target" || return 1
  chmod +x "$target"
}

GH_HOST_FAKE_TOKENS=(GH_TOKEN=t1 GITHUB_TOKEN=t2 GH_ENTERPRISE_TOKEN=t3 GITHUB_ENTERPRISE_TOKEN=t4)

gh_host_fake_env_all() {
  local log="${1:-}" want="${2:-}" lines bad
  [ -n "$want" ] || return 1
  lines="$(printf '%s\n' "$log" | grep -c .)"
  bad="$(printf '%s\n' "$log" | grep -v -x -F -e "$want" | grep -c .)"
  [ "$lines" -ge 1 ] && [ "$bad" = 0 ]
}
