#!/bin/bash

# Rendering values into hook directives. A hook directive is a QUOTED heredoc whose
# additionalContext carries `__<NAME>__` placeholders, and the substitution below fills
# them on the PARSED JSON, so a value carrying `printf %q` backslashes arrives
# JSON-escaped, which a shell substitution into the raw text cannot do.
#
# This is one of TWO substitution conventions in this plugin, and the other one is
# deliberate: user-prompt-zen-mode.sh fills `{{ZENSU_CHAIN_ANCHOR}}` by shell parameter
# expansion on the raw body, with no process, because its value is a closed vocabulary
# that never needs JSON escaping. A value that can carry a path or a backslash belongs
# here.
#
# Nothing in this file reads config or a session marker; zensu-config.sh does. What it
# opens or spawns: it sources zensu-msys-env.sh from its own directory when that is a
# regular file and not a symlink, `zensu_delivery_route_record_command` probes
# CLAUDE_PLUGIN_DATA with `-d` / `-L`, and `zensu_directive_substitute` runs one node
# child fed over stdin. Consumers: session-start-primer.sh and both ask-hooks
# (plan-approved-delegate.sh, user-prompt-tdd-reminder.sh), each of which sources this
# file itself.

# The MSYS exclusion helper is loaded the way zensu-session.sh loads it: from this
# library's own directory, never through a symlink, and replacing any definition the
# environment carried in. The primer never sources zensu-session.sh, so without this
# load it would always fall back to the hand-rolled append in zensu_directive_substitute.
_ZENSU_DIRECTIVE_MSYS_ENV_READY=false
_ZENSU_DIRECTIVE_MSYS_ENV=''
if _ZENSU_DIRECTIVE_MSYS_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/zensu-msys-env.sh" \
  && [ -f "$_ZENSU_DIRECTIVE_MSYS_ENV" ] && [ ! -L "$_ZENSU_DIRECTIVE_MSYS_ENV" ]; then
  unset -f zensu_msys_env_exclusions 2>/dev/null || true
  # shellcheck disable=SC1090
  if source "$_ZENSU_DIRECTIVE_MSYS_ENV" \
    && declare -F zensu_msys_env_exclusions >/dev/null 2>&1; then
    _ZENSU_DIRECTIVE_MSYS_ENV_READY=true
  fi
fi

# The command the directives tell the model to run right after the user answers the
# route question, rendered the way session-start-primer.sh renders its log command:
# `printf %q` on both the data root and the helper path. When CLAUDE_PLUGIN_DATA is
# unusable the helper could not bind anyway, so the directive names the skill instead
# of a command that would refuse. This is the one renderer of this command; the other
# hooks that render a `CLAUDE_PLUGIN_DATA=… bash …` command for zensu-log.sh keep their
# own copies and their own policy for an unusable data root (the primer stays silent,
# the durable plan-gate branch renders it unconditionally).
ZENSU_DELIVERY_ROUTE_SKILL_FALLBACK="the Skill tool with skill='zensu:delivery-route' and the matching argument"
zensu_delivery_route_record_command() {
  case "${CLAUDE_PLUGIN_DATA:-}" in
    (""|*$'\r'*|*$'\n'*) ;;
    (*)
      if [ -d "$CLAUDE_PLUGIN_DATA" ] && [ ! -L "$CLAUDE_PLUGIN_DATA" ]; then
        printf 'CLAUDE_PLUGIN_DATA=%s bash %s\n' "$(printf '%q' "$CLAUDE_PLUGIN_DATA")" "$(printf '%q' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-delivery-route.sh")"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$ZENSU_DELIVERY_ROUTE_SKILL_FALLBACK"
}

# Substitute `__<NAME>__` placeholders into the additionalContext of a hook directive
# read from stdin, on the PARSED JSON. Arguments are NAME VALUE pairs; each NAME is an
# upper-case environment name that carries its VALUE to node and is excluded from
# MSYS's environment conversion, so a pre-quoted host path arrives unchanged. A
# rendered command carries `printf %q` backslashes that must be JSON-escaped, which a
# shell substitution into the raw text cannot do — that is why a directive carrying a
# rendered value keeps its heredoc QUOTED and substitutes afterwards. One pass: a value
# is never scanned for another placeholder. Prints the directive and returns 0, or
# prints nothing and returns 1 (no node, a malformed argument list, unparseable JSON);
# the caller owns the fallback. Shared by session-start-primer.sh and, through
# zensu_delivery_route_substitute, by both ask-hooks.
zensu_directive_substitute() {
  [ "$#" -gt 0 ] && [ $(( $# % 2 )) -eq 0 ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  (
    names=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        (ZENSU_*) ;;
        (*) exit 1 ;;
      esac
      case "$1" in
        (*[!A-Z0-9_]*) exit 1 ;;
      esac
      export "$1=$2"
      names="${names}${names:+ }$1"
      shift 2
    done
    export ZENSU_DIRECTIVE_PLACEHOLDERS="$names"
    # The shipped helper appends each exact-name selector and keeps a dominant
    # standalone '*' intact, neither of which the hand-rolled append does. The append
    # is only the fallback for a library whose own load of zensu-msys-env.sh failed; a
    # helper that refuses the ambient value leaves that value as it is, as the plan
    # hook's own calls do.
    if [ "$_ZENSU_DIRECTIVE_MSYS_ENV_READY" = true ]; then
      # shellcheck disable=SC2086
      msys_env_exclusions="$(zensu_msys_env_exclusions $names ZENSU_DIRECTIVE_PLACEHOLDERS)" \
        || msys_env_exclusions="${MSYS2_ENV_CONV_EXCL:-}"
    else
      msys_env_exclusions="${names// /;};ZENSU_DIRECTIVE_PLACEHOLDERS"
      if [ -n "${MSYS2_ENV_CONV_EXCL:-}" ]; then
        msys_env_exclusions="${MSYS2_ENV_CONV_EXCL};${msys_env_exclusions}"
      fi
    fi
    MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" node -e '
      process.stdin.setEncoding("utf8");
      let s = "";
      process.stdin.on("data", c => s += c);
      process.stdin.on("end", () => {
        try {
          const names = String(process.env.ZENSU_DIRECTIVE_PLACEHOLDERS || "").split(" ").filter(Boolean);
          const j = JSON.parse(s);
          const out = j.hookSpecificOutput || {};
          const text = String(out.additionalContext || "");
          out.additionalContext = names.length === 0 ? text : text.replace(
            new RegExp("__(" + names.join("|") + ")__", "g"),
            (_, name) => process.env[name] || ""
          );
          process.stdout.write(JSON.stringify(j));
        } catch (_) { process.exitCode = 1; }
      });
    ' 2>/dev/null
  )
}

# Substitute `__ZENSU_DELIVERY_ROUTE__` and `__ZENSU_ROUTE_COMMAND__` into a directive
# read from stdin. Both ask-hooks keep their heredocs QUOTED and keep exactly TWO of
# them — the parity pins count them — so the values travel through placeholders. When
# node cannot perform the substitution the fallback still emits valid JSON: the field
# is a closed vocabulary (always JSON-safe) and the command becomes the skill sentence,
# so the directive is never routed to silence.
zensu_delivery_route_substitute() {
  local field="${1:-ask}" command="${2:-}" body out
  body="$(cat)"
  out="$(printf '%s\n' "$body" | zensu_directive_substitute ZENSU_DELIVERY_ROUTE "$field" ZENSU_ROUTE_COMMAND "$command")"
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  body="${body//__ZENSU_DELIVERY_ROUTE__/$field}"
  body="${body//__ZENSU_ROUTE_COMMAND__/$ZENSU_DELIVERY_ROUTE_SKILL_FALLBACK}"
  printf '%s\n' "$body"
}
