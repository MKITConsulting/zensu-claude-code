#!/bin/bash

# Add exact environment-variable names to MSYS2's native-process conversion
# exclusion set without normalizing or replacing the caller's ambient policy.
# Every added name is reserved for a value that was already rendered in the
# native host namespace (or is intentionally opaque data). MSYS2 matches each
# selector as a prefix of KEY=VALUE, so the trailing '=' is required for exact
# name matching. The documented standalone '*' value remains dominant; an
# ambient list containing a literal '*' token is preserved conservatively but
# does not suppress the exact selectors required by this call.
zensu_msys_env_exclusions() {
  [ "$#" -gt 0 ] || return 1
  local existing="${MSYS2_ENV_CONV_EXCL:-}" result name selector
  case "$existing" in *$'\r'*|*$'\n'*) return 1 ;; esac
  result="$existing"

  for name in "$@"; do
    case "$name" in
      ''|[!A-Z_]*|*[!A-Z0-9_]*) return 1 ;;
    esac
  done

  if [ "$existing" = '*' ]; then
    printf '%s\n' "$existing"
    return 0
  fi

  for name in "$@"; do
    selector="${name}="
    case ";$result;" in
      *";$selector;"*) ;;
      *) result="${result}${result:+;}${selector}" ;;
    esac
  done
  printf '%s\n' "$result"
}

export -f zensu_msys_env_exclusions 2>/dev/null || true
