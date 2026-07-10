#!/bin/bash

_zensu_vcs_remote_url() {
  if [ -n "${ZENSU_VCS_REMOTE:-}" ]; then
    printf '%s' "$ZENSU_VCS_REMOTE"
    return 0
  fi
  local repo="${1:-.}"
  command -v git >/dev/null 2>&1 || return 0
  local rn
  rn="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  rn="${rn%%/*}"
  [ -n "$rn" ] || rn="origin"
  git -C "$repo" remote get-url "$rn" 2>/dev/null
}

_zensu_vcs_split_url() {
  local url="${1:-}"
  if ! command -v node >/dev/null 2>&1; then
    printf '\t'
    return 0
  fi
  U="$url" node -e '
    var u=(process.env.U||"").trim().replace(/\.git$/,"");
    var host="",path="",m;
    if(m=u.match(/^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^@\/]*@)?([^\/:]+)(?::[0-9]+)?\/(.*)$/)){host=m[2];path=m[3];}
    else if(m=u.match(/^([^@\/]*@)?([^\/:]+):(.*)$/)){host=m[2];path=m[3];}
    process.stdout.write(host+"\t"+path);
  '
}

_zensu_vcs_classify_host() {
  case "${1:-}" in
    github.com) printf 'github cloud' ;;
    gitlab.com) printf 'gitlab cloud' ;;
    *)          printf '' ;;
  esac
}

_zensu_vcs_probeable_host() {
  local h="${1:-}"
  [ -n "$h" ] || return 1
  case "$h" in
    *:*) return 1 ;;
    localhost|*.local|*.localhost|*.internal) return 1 ;;
    0.*|127.*|10.*|192.168.*|169.254.*|255.255.255.255) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
  esac
  case "$h" in
    *[!0-9.]*) : ;;
    *.*.*.*)   return 1 ;;
    *)         return 1 ;;
  esac
  case "$h" in
    *.*) return 0 ;;
    *)   return 1 ;;
  esac
}

_zensu_vcs_http_present() {
  command -v curl >/dev/null 2>&1 || return 1
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "https://${1}${2}" 2>/dev/null)"
  case "$code" in
    200|401|403) return 0 ;;
    *)           return 1 ;;
  esac
}

_zensu_vcs_probe() {
  if [ "${ZENSU_VCS_TEST:-}" = "1" ] && [ -n "${ZENSU_VCS_PROBE_RESULT:-}" ]; then
    printf '%s' "$ZENSU_VCS_PROBE_RESULT"
    return 0
  fi
  local host="${1:-}"
  _zensu_vcs_probeable_host "$host" || { printf 'none'; return 0; }
  if _zensu_vcs_http_present "$host" "/api/v4/version"; then
    printf 'gitlab'
  elif _zensu_vcs_http_present "$host" "/api/v3/meta"; then
    printf 'github-enterprise'
  else
    printf 'none'
  fi
}

_zensu_vcs_marker() {
  local repo="${1:-.}"
  if [ -f "$repo/.gitlab-ci.yml" ]; then
    printf 'gitlab'
  elif [ -d "$repo/.github/workflows" ]; then
    printf 'github'
  else
    printf 'none'
  fi
}

_zensu_vcs_api_base() {
  local host="${3:-}"
  case "${1:-}:${2:-}" in
    github:cloud)      printf 'https://api.github.com' ;;
    github:enterprise) [ -n "$host" ] && printf 'https://%s/api/v3' "$host" || printf '' ;;
    gitlab:cloud)      printf 'https://gitlab.com/api/v4' ;;
    gitlab:selfhosted) [ -n "$host" ] && printf 'https://%s/api/v4' "$host" || printf '' ;;
    *)                 printf '' ;;
  esac
}

_zensu_vcs_repo_id() {
  local provider="${1:-}" path="${2:-}"
  [ -n "$path" ] || { printf ''; return 0; }
  case "$provider" in
    gitlab)
      if command -v node >/dev/null 2>&1; then
        P="$path" node -e 'process.stdout.write(encodeURIComponent(process.env.P||""))'
      else
        printf ''
      fi
      ;;
    github)
      printf '%s' "$path"
      ;;
    *)
      printf ''
      ;;
  esac
}

_zensu_vcs_cli_for() {
  case "${1:-}" in
    github) printf 'gh' ;;
    gitlab) printf 'glab' ;;
    *)      printf '' ;;
  esac
}

_zensu_vcs_auth_state() {
  if [ "${ZENSU_VCS_TEST:-}" = "1" ] && [ -n "${ZENSU_VCS_FAKE_AUTH:-}" ]; then
    printf '%s' "$ZENSU_VCS_FAKE_AUTH"
    return 0
  fi
  local cli="${1:-}"
  [ -n "$cli" ] || { printf 'missing'; return 0; }
  command -v "$cli" >/dev/null 2>&1 || { printf 'missing'; return 0; }
  if "$cli" auth status >/dev/null 2>&1; then
    printf 'ready'
  else
    printf 'unauthed'
  fi
}

_zensu_vcs_detect() {
  local repo="." o_provider="${ZENSU_VCS_PROVIDER:-}" o_apibase="${ZENSU_VCS_API_BASE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) o_provider="${2:-}"; shift ;;
      --api-base) o_apibase="${2:-}"; shift ;;
      --repo)     repo="${2:-.}"; shift ;;
      *) ;;
    esac
    shift
  done

  local url host path
  url="$(_zensu_vcs_remote_url "$repo")"
  IFS="$(printf '\t')" read -r host path <<EOF
$(_zensu_vcs_split_url "$url")
EOF

  local provider="" edition=""
  if [ -n "$o_provider" ]; then
    provider="$o_provider"
    case "$host" in
      github.com|gitlab.com|"") edition="cloud" ;;
      *) if [ "$provider" = "gitlab" ]; then edition="selfhosted"; else edition="enterprise"; fi ;;
    esac
  elif [ -z "$host" ]; then
    provider="unknown"; edition=""
  else
    read -r provider edition <<EOF
$(_zensu_vcs_classify_host "$host")
EOF
    if [ -z "$provider" ]; then
      case "$(_zensu_vcs_probe "$host")" in
        gitlab)            provider="gitlab"; edition="selfhosted" ;;
        github-enterprise) provider="github"; edition="enterprise" ;;
        *)
          case "$(_zensu_vcs_marker "$repo")" in
            gitlab) provider="gitlab"; edition="selfhosted" ;;
            github) provider="github"; edition="enterprise" ;;
            *)      provider="unknown"; edition="" ;;
          esac
          ;;
      esac
    fi
  fi

  local api_base
  if [ -n "$o_apibase" ]; then
    api_base="$o_apibase"
  else
    api_base="$(_zensu_vcs_api_base "$provider" "$edition" "$host")"
  fi

  local repo_id cli cli_state cli_ready
  repo_id="$(_zensu_vcs_repo_id "$provider" "$path")"
  cli="$(_zensu_vcs_cli_for "$provider")"
  cli_state="$(_zensu_vcs_auth_state "$cli")"
  if [ "$cli_state" = "ready" ]; then cli_ready="true"; else cli_ready="false"; fi

  printf 'provider=%s\n' "$provider"
  printf 'edition=%s\n' "$edition"
  printf 'apiBase=%s\n' "$api_base"
  printf 'repo=%s\n' "$repo_id"
  printf 'cliReady=%s\n' "$cli_ready"
  printf 'cliName=%s\n' "$cli"
  printf 'cliState=%s\n' "$cli_state"
}

export -f _zensu_vcs_remote_url _zensu_vcs_split_url _zensu_vcs_classify_host _zensu_vcs_probeable_host _zensu_vcs_http_present _zensu_vcs_probe _zensu_vcs_marker _zensu_vcs_api_base _zensu_vcs_repo_id _zensu_vcs_cli_for _zensu_vcs_auth_state _zensu_vcs_detect 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --detect) _zensu_vcs_detect "$@" ;;
    *) printf 'usage: zensu-vcs.sh --detect [--provider github|gitlab] [--api-base URL] [--repo DIR]\n' >&2; exit 2 ;;
  esac
fi
