#!/bin/bash

# Effective Zensu config = a per-key DEEP MERGE of the global and project-local
# config files (no jq in this repo — parsing is inline `node -e`).
#
# Precedence, lowest to highest:
#   1. $HOME/.zensu/config.json              (global base)
#   2. $CLAUDE_PROJECT_DIR/.zensu/config.json (project overlay — wins per key;
#                                             keys it omits fall through to global)
#   3. $ZENSU_CONFIG                          (full override — used verbatim, NOT
#                                             merged; the explicit escape hatch)
#
# A missing or malformed file degrades to {} (so a broken project file can no
# longer blank a valid global). When a key is absent from the merged object the
# getters apply the same hardcoded defaults they always have, so a no-config
# install behaves exactly as before.
#
# ONE exception to "this file only reads config": the session-marker helpers that
# follow `zensu_tdd_strict_enabled` also read TWO session-scoped markers under
# `<project>/.zensu/state/` — the tdd-mode marker and the delivery-route marker. Every
# config getter spawns node through `_zensu_config_node`; the getters after the marker
# section do too. Beyond those config reads, an auditor asking "what in
# the marker section opens something" must get exactly these names and no others:
# `zensu_tdd_mode_state_linked` (the `-L` probes, shared by both marker pairs) and
# `_zensu_marker_one_line_value` (the ONE bounded read behind both marker readers).
# `zensu_default_delivery_route` is one more config getter. `zensu_tdd_mode_marker_path`
# / `zensu_delivery_route_marker_path` only spell a path, `zensu_tdd_mode_marker_state`
# / `zensu_delivery_route_marker_state` only map what the shared reader returned onto
# their own vocabularies, and `zensu_tdd_mode_override` / `zensu_tdd_strict_effective` /
# `zensu_delivery_route_resolve` / `zensu_delivery_route_field` /
# `zensu_delivery_route_status_line` only reduce those answers. The marker reads are
# node-free and outside the merge machinery above. Rendering a value INTO a hook
# directive is not a read of anything and lives in `hooks/lib/zensu-directive.sh`. The
# marker section lives here so each writer (`hooks/lib/zensu-tdd-mode.sh`,
# `hooks/lib/zensu-delivery-route.sh`) and every reader share ONE path template and
# ONE parse; zen-mode hand-copies its template into its reader hook, and that is the
# drift this placement avoids.
#
# _ZENSU_CFG_JS holds the shared reader/merge/select JS. It uses only
# double-quoted JS string literals so each getter can embed it inside a
# single-quoted extraction snippet and keep a single `node -e` spawn:
#   node -e "$_ZENSU_CFG_JS"' <extraction reading the cfg() object> '
_ZENSU_CFG_JS='function rd(p){try{return JSON.parse(require("fs").readFileSync(p,"utf8"))}catch(e){return {}}}function dm(b,o){if(o===null||typeof o!=="object"||Array.isArray(o))return o;var r=(b&&typeof b==="object"&&!Array.isArray(b))?Object.assign({},b):{};for(var k of Object.keys(o)){if(k==="__proto__"||k==="constructor"||k==="prototype")continue;r[k]=Object.prototype.hasOwnProperty.call(r,k)?dm(r[k],o[k]):o[k]}return r}function cfg(){var e=process.env.ZENSU_CONFIG;if(e)return rd(e);var g=rd((process.env.HOME||"")+"/.zensu/config.json");var pd=process.env.CLAUDE_PROJECT_DIR;var p=pd?rd(pd+"/.zensu/config.json"):{};return dm(g,p)}'

# Native Windows Node cannot reliably consume an MSYS path through its
# quote-sensitive automatic environment conversion. Render only the three
# path-valued config inputs explicitly; all other environment remains intact.
_zensu_config_native_path() {
  local value="${1:-}" native
  [ "$#" -eq 1 ] || return 1
  [ -n "$value" ] || { printf '\n'; return 0; }
  case "$value" in *$'\r'*|*$'\n'*) return 1 ;; esac
  case "${OSTYPE:-}" in
    msys*|cygwin*|mingw*|MSYS*|CYGWIN*|MINGW*)
      command -v cygpath >/dev/null 2>&1 || return 1
      native="$(cygpath -am "$value" 2>/dev/null)" || return 1
      case "$native" in ""|*$'\r'*|*$'\n'*) return 1 ;; esac
      case "$native" in [A-Za-z]:/*|//?*/*) ;; *) return 1 ;; esac
      printf '%s\n' "$native"
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

_zensu_config_node() {
  local native_config native_home native_project
  native_config="$(_zensu_config_native_path "${ZENSU_CONFIG:-}")" || return 1
  native_home="$(_zensu_config_native_path "${HOME:-}")" || return 1
  native_project="$(_zensu_config_native_path "${CLAUDE_PROJECT_DIR:-}")" || return 1
  ZENSU_CONFIG="$native_config" HOME="$native_home" CLAUDE_PROJECT_DIR="$native_project" node "$@"
}

# Emit the effective (merged) config as a JSON string. Testable seam + handy for
# debugging "what config does a hook actually see here?".
_zensu_config_json() {
  command -v node >/dev/null 2>&1 || { echo '{}'; return 0; }
  _zensu_config_node -e "$_ZENSU_CFG_JS"' process.stdout.write(JSON.stringify(cfg()))' 2>/dev/null || echo '{}'
}

zensu_hook_enabled() {
  local key="$1"
  command -v node >/dev/null 2>&1 || return 0   # node missing → fall back to enabled
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks[process.argv[1]]===false?"0":"1")' "$key" 2>/dev/null)
  [ -z "$val" ] && return 0                      # any other failure → enabled
  [ "$val" = "1" ]
}

# Fail-CLOSED twin of zensu_hook_enabled, for a flag whose "enabled" state GRANTS a
# capability instead of running a protection. zensu_hook_enabled returns enabled when
# `node` is missing and again when the read produces no value, because for every
# ordinary flag that direction keeps a protection running. `reviewerSpawnAutoAllow`
# inverts the stakes: there "enabled" means the host permission layer is bypassed, so
# the same fallback would silently restore a capability the user explicitly withdrew.
# This reader grants only when NO candidate says false and no candidate is present but
# unusable. An ABSENT candidate is skipped, because a no-config install is the documented
# default-on case — but an EMPTY candidate list is refused outright, since then nothing was
# consulted at all and "nothing said false" would be vacuous. Only a clean ENOENT counts as
# absent: every other stat failure (EACCES, ENOTDIR, ELOOP) is a config the reader could not
# REACH, and reading that as "no config here" is what let a withdrawal the user recorded
# survive unseen. one() returns a TAGGED result rather than either a parsed value or a
# sentinel string, because those two domains collided: JSON.parse('"absent"') is the string
# absent, so a config whose whole content was that literal took the not-present branch.
# Do NOT fold it into zensu_hook_enabled — that helper's default is right for its own
# callers, and one shared default cannot serve both directions.
# It deliberately does NOT go through cfg(). Two properties the merged read cannot give:
#
#   1. rd() swallows every read error and returns {}, so a config that is PRESENT but
#      unreadable or malformed is indistinguishable from one that is absent — and for this
#      flag "indistinguishable" means the grant survives a state the user cannot see. A
#      present candidate that will not parse DECLINES here.
#   2. cfg() lets the project overlay REPLACE the global value, so a `.zensu/config.json`
#      inside a checked-out repository could re-arm a bypass the user withdrew globally.
#      Withdrawal is STICKY instead: `false` in ANY candidate disables, whichever file
#      carries it. That is the right precedence for a switch that governs a permission
#      bypass and the wrong one for an ordinary feature flag, which is the whole reason
#      this reader is separate rather than a parameter on the one above.
#
# ZENSU_CONFIG still overrides the pair outright, matching cfg()'s own contract.
_ZENSU_STRICT_JS='function one(p){var fs=require("fs");try{fs.statSync(p)}catch(e){return {s:(e&&e.code==="ENOENT")?"absent":"bad"}}try{return {s:"ok",v:JSON.parse(fs.readFileSync(p,"utf8"))}}catch(e){return {s:"bad"}}}function cands(){var e=process.env.ZENSU_CONFIG;if(e)return [e];var o=[];if(process.env.HOME)o.push(process.env.HOME+"/.zensu/config.json");if(process.env.CLAUDE_PROJECT_DIR)o.push(process.env.CLAUDE_PROJECT_DIR+"/.zensu/config.json");return o}function verdict(k){var list=cands();if(!list.length)return "0";for(var i=0;i<list.length;i++){var r=one(list[i]);if(r.s==="absent")continue;if(r.s==="bad")return "0";var v=r.v;if(!v||typeof v!=="object"||Array.isArray(v))return "0";var h=v.hooks;if(h===undefined)continue;if(!h||typeof h!=="object"||Array.isArray(h))return "0";if(h[k]===false)return "0"}return "1"}'
zensu_hook_enabled_strict() {
  local key="$1"
  command -v node >/dev/null 2>&1 || return 1
  local val
  val=$(_zensu_config_node -e "$_ZENSU_STRICT_JS"' process.stdout.write(verdict(process.argv[1]))' "$key" 2>/dev/null)
  [ "$val" = "1" ]
}

# Strict RED→GREEN TDD enable check — the INVERSE default of zensu_hook_enabled.
# tddImplementation defaults to FALSE (vanilla mode): strict runs ONLY on an
# explicit boolean `true`; absent / false / non-boolean all resolve to vanilla,
# and node-missing degrades to vanilla (the new default). Do NOT fold this into
# zensu_hook_enabled — that helper defaults every other flag to enabled.
zensu_tdd_strict_enabled() {
  command -v node >/dev/null 2>&1 || return 1   # node missing → vanilla (default off)
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks.tddImplementation===true?"1":"0")' 2>/dev/null)
  [ "$val" = "1" ]
}

# Session-scoped strict/vanilla OVERRIDE — the recorded choice that
# hooks/lib/zensu-tdd-mode.sh writes for `/zensu:tdd-mode`. It outranks BOTH the
# caller-supplied `--tdd-begin --tdd-mode` flag and hooks.tddImplementation, so a
# user who switched the mode for this session is never overruled by a skill's own
# default. Echoes `strict`, `vanilla`, or `auto`.
#
# Everything that is not an explicit, parsable mode resolves to `auto` (= no
# override, fall through to caller/config): an absent, unreadable, or malformed
# marker must never impose a mode, and a symlinked state path is refused here for
# the same reason the writer refuses to create one. Deliberately node-free — the
# override has to keep working on a host without node, where the config reader
# already degrades to vanilla.
#
# The marker path template lives HERE, in zensu_tdd_mode_marker_path, and the
# writer sources this file rather than re-spelling it: zen-mode's template is
# hand-copied into its reader hook, and a divergence there would silently split
# the writer's file from the reader's.
zensu_tdd_mode_marker_path() {
  local project_dir="${1:-}" session_key="${2:-}"
  [ -n "$project_dir" ] && [ -n "$session_key" ] || return 1
  printf '%s\n' "$project_dir/.zensu/state/tdd-mode-$session_key.json"
}

# The symlink refusal, spelled ONCE, for BOTH session markers this file owns: the
# tdd-mode pair (reader `zensu_tdd_mode_marker_state`, helper zensu-tdd-mode.sh) and
# the delivery-route pair (reader `zensu_delivery_route_marker_state`, helper
# zensu-delivery-route.sh). Both helpers write through `zensu_write_session_marker`
# in zensu-marker-write.sh, the one writer that calls this guard. The name predates
# the second pair and is kept because every caller spells it — read it as "marker
# state linked". Each reader and the writer guard the same three components —
# `.zensu`, the state directory, the marker leaf — and the writer additionally guards
# its `mktemp` temp leaf, which is what the optional third argument is for. It lives
# here beside the path templates for the same reason they do: hand-synced copies of
# the component list would diverge silently, and the tests that would catch a
# divergence (T9/T9b/T9d in test-tdd-mode-toggle.sh, R8/R8b/R8e in
# test-delivery-route.sh) are exactly the ones that skip themselves on a host
# without symlink support.
#
# The writer calls this TWICE on purpose — once before the write and again
# immediately before the rename. That duplication is the TOCTOU defense and must
# stay two separate calls; only the component list is shared.
zensu_tdd_mode_state_linked() {
  local project_dir="${1:-}" marker="${2:-}" extra_leaf="${3:-}"
  [ -L "$project_dir/.zensu" ] && return 0
  [ -L "$(dirname "$marker")" ] && return 0
  [ -L "$marker" ] && return 0
  [ -n "$extra_leaf" ] && [ -L "$extra_leaf" ] && return 0
  return 1
}

# The ONE bounded reader behind both session markers this file owns — the tdd-mode
# marker (`{"mode":"<value>"}`) and the delivery-route marker (`{"route":"<value>"}`).
# It echoes the lowercase VALUE when the file holds exactly that one line (plus
# trailing whitespace) and nothing else, and echoes nothing otherwise; the callers
# map the value onto their own vocabulary and treat an empty answer as `none`.
#
# Byte semantics, pinned for the whole function. `${#body}` is CHARACTER-counted in a
# multibyte locale and `[[:space:]]` is locale-defined, so without this a marker
# padded with multibyte spaces measures short, passes the 512 ceiling, and has its
# tail swallowed by the whitespace class — a >513-byte file answered as a value with
# the remainder unexamined. `local` restores the caller's locale on return.
#
# The marker a writer emits is exactly one line. Match the FIRST line, as a whole,
# and only when the file holds nothing after it. Both halves are load-bearing. A
# grep over the FILE would let a body contradict its own key —
# `{"mode":"vanilla"} "mode":"strict"` on one line, or a second line spelling the
# other value — because `^`/`$` anchor a LINE, not the file. Anything this rejects is
# by definition not a marker this plugin wrote. The remainder is DRAINED, not sampled
# one line deep: reading only line 2 would let `{"mode":"strict"}` + a blank line +
# `{"mode":"vanilla"}` through unexamined. Trailing whitespace of any shape is
# tolerated; any other content is not.
#
# Bound the bytes that are actually CONSUMED, in ONE open. A writer's own output is
# at most 21 bytes, so a small ceiling refuses nothing legitimate. This used to be a
# `wc -c` pass followed by a separate `$(cat)` drain — two opens, so a marker that
# GREW between them passed the ceiling and was then slurped unbounded into a shell
# variable, on a path that runs on every prompt. `head -c` caps the read itself, so
# the memory bound holds no matter what the file does between calls; the length
# check below only decides the verdict. The `X` sentinel is load-bearing: `$(...)`
# strips trailing newlines, so without it a 1000-byte file whose first 513 bytes end
# in newlines would measure short, pass the ceiling, and have its tail go unexamined.
_zensu_marker_one_line_value() {
  local LC_ALL=C LC_CTYPE=C
  local marker="${1:-}" key="${2:-}"
  [ -n "$marker" ] && [ -n "$key" ] || return 0
  [ -f "$marker" ] || return 0
  local body="" first="" rest=""
  # A NUL byte is translated to \001 inside the same open, before the bytes reach the
  # substitution. Bash drops NULs from `$(...)` output, so an untranslated NUL made
  # `${#body}` undercount the 513-byte read: a file padded with NULs passed the ceiling
  # with its tail unexamined, and `{"route":"tdd"}<NUL>` read as `tdd`. Translated, every
  # byte counts toward the ceiling and a \001 fails the whole-line match. `tr` gets
  # `LC_ALL=C` of its own for the reason the `sed` below does, and because BSD `tr`
  # refuses an invalid byte sequence in a UTF-8 locale. The redirect failure (an
  # unreadable marker) is reported by the shell running the GROUP, so the inner
  # `2>/dev/null` covers it; the outer one covers any warning the substitution itself
  # prints. Without them a mode-0 marker would print on every prompt while the reader
  # silently answers nothing anyway.
  { body="$( { head -c 513 < "$marker" | LC_ALL=C tr '\000' '\001'; printf 'X'; } 2>/dev/null )"; } 2>/dev/null
  body="${body%X}"
  [ "${#body}" -le 512 ] || return 0
  first="${body%%$'\n'*}"
  if [ "$first" = "$body" ]; then rest=""; else rest="${body#*$'\n'}"; fi
  case "$rest" in (*[![:space:]]*) return 0 ;; esac
  # `LC_ALL=C` is repeated on the child, not inherited from the `local` above: a shell
  # local is not exported, so on a host that never exported LC_ALL the child would
  # classify `[[:space:]]` in its own locale. The in-shell halves (the length check
  # and the remainder scan) do get C semantics from the local; the child would not.
  printf '%s\n' "$first" | LC_ALL=C sed -nE 's/^[[:space:]]*\{[[:space:]]*"'"$key"'"[[:space:]]*:[[:space:]]*"([a-z]+)"[[:space:]]*\}[[:space:]]*$/\1/p'
}

# The four-state marker reader `zensu_tdd_mode_override` is built on. It answers
# `strict`, `vanilla`, `released` (the marker is PRESENT and holds `{"mode":"auto"}`),
# or `none` (absent, symlinked, unreadable, oversized, or not a marker this plugin
# wrote). The `released` / `none` split is why `--auto` writes a file instead of
# deleting one: it is what lets `/zensu:tdd-mode --status` tell a deliberate release
# from a choice that was never made. `zensu_tdd_mode_override` collapses both back to
# `auto`, so every mode-resolving caller keeps its three-value contract unchanged.
zensu_tdd_mode_marker_state() {
  local project_dir="${1:-}" session_key="${2:-}" marker
  [ -n "$project_dir" ] && [ -n "$session_key" ] || { echo "none"; return 0; }
  marker="$(zensu_tdd_mode_marker_path "$project_dir" "$session_key")" || { echo "none"; return 0; }
  if zensu_tdd_mode_state_linked "$project_dir" "$marker" || [ ! -f "$marker" ]; then
    echo "none"
    return 0
  fi
  case "$(_zensu_marker_one_line_value "$marker" mode)" in
    (strict)  echo "strict" ;;
    (vanilla) echo "vanilla" ;;
    (auto)    echo "released" ;;
    (*)       echo "none" ;;
  esac
}

zensu_tdd_mode_override() {
  case "$(zensu_tdd_mode_marker_state "${1:-}" "${2:-}")" in
    strict)  echo "strict" ;;
    vanilla) echo "vanilla" ;;
    *)       echo "auto" ;;
  esac
}

# Effective strict check = the session override layered over the config flag.
# Callers that can resolve a session pass its project dir and Session Control
# session key. The SessionStart banner and primer stay on the configured mode by
# design and call zensu_tdd_strict_enabled directly: a session with a new key has no
# marker yet, and a marker a `clear` keeps under the same key is reported by
# `/zensu:tdd-mode --status` and the `mode:` echo at `--tdd-begin`. Passing empty
# arguments here is equivalent and stays config-only.
zensu_tdd_strict_effective() {
  case "$(zensu_tdd_mode_override "${1:-}" "${2:-}")" in
    strict)  return 0 ;;
    vanilla) return 1 ;;
  esac
  zensu_tdd_strict_enabled
}

# Session-scoped DELIVERY ROUTE — the answer to the question both ask-hooks
# (plan-approved-delegate.sh, user-prompt-tdd-reminder.sh) would otherwise put to the
# user on every approval and every code request. hooks/lib/zensu-delivery-route.sh
# writes the marker for /zensu:delivery-route, and the model writes `tdd` right after the
# user answers the question with the Zensu workflow. The vocabulary is `tdd` | `direct` only: /zensu:autopilot
# and /zensu:pilot push branches, open pull requests or mutate tracked feature state,
# so they stay per-plan choices that neither a marker nor a config key can pre-select.
# The path template lives HERE and the writer sources it, for the reason the tdd-mode
# template gives above. The symlink guard is shared with the tdd-mode marker: the
# component list is identical, so a second copy would only be a second thing to drift.
zensu_delivery_route_marker_path() {
  local project_dir="${1:-}" session_key="${2:-}"
  [ -n "$project_dir" ] && [ -n "$session_key" ] || return 1
  printf '%s\n' "$project_dir/.zensu/state/delivery-route-$session_key.json"
}

# `tdd` / `direct` / `released` (a present `{"route":"auto"}`) / `none` (absent,
# symlinked, unreadable, oversized, or not a marker this plugin wrote).
zensu_delivery_route_marker_state() {
  local project_dir="${1:-}" session_key="${2:-}" marker
  [ -n "$project_dir" ] && [ -n "$session_key" ] || { echo "none"; return 0; }
  marker="$(zensu_delivery_route_marker_path "$project_dir" "$session_key")" || { echo "none"; return 0; }
  if zensu_tdd_mode_state_linked "$project_dir" "$marker" || [ ! -f "$marker" ]; then
    echo "none"
    return 0
  fi
  case "$(_zensu_marker_one_line_value "$marker" route)" in
    (tdd)    echo "tdd" ;;
    (direct) echo "direct" ;;
    (auto)   echo "released" ;;
    (*)      echo "none" ;;
  esac
}

# hooks.defaultDeliveryRoute, read PERMISSIVELY: `tdd` or `direct` verbatim, and `ask`
# for everything else — absent, the explicit `ask`, an empty string, a quoted or
# capitalized spelling, a boolean, or a host without node. An unknown value never
# selects a route; it only keeps the question. With a PROJECT_DIR argument the project
# overlay is read from that root, and an empty argument means no root and answers
# `ask`; without an argument it is read from the ambient CLAUDE_PROJECT_DIR, like every
# getter above.
zensu_default_delivery_route() {
  command -v node >/dev/null 2>&1 || { echo "ask"; return 0; }
  local root val
  if [ "$#" -gt 0 ]; then
    root="$1"
    [ -n "$root" ] || { echo "ask"; return 0; }
  else
    root="${CLAUDE_PROJECT_DIR:-}"
  fi
  val=$(CLAUDE_PROJECT_DIR="$root" _zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var s=j.hooks&&j.hooks.defaultDeliveryRoute;console.log(s==="tdd"||s==="direct"?s:"ask")' 2>/dev/null)
  case "$val" in
    (tdd|direct) echo "$val" ;;
    (*)          echo "ask" ;;
  esac
}

# The ladder both ask-hooks, `--status` and the /zensu:doctor row resolve: the session
# marker outranks the config key, and neither outranks an explicit preference in the
# user's own text — that rank is judged by the model from the directive, so it never
# reaches this function. Both mechanical ranks are read under the ONE project root the
# caller passes: the marker lives there, and the config overlay is read from there
# rather than from the ambient CLAUDE_PROJECT_DIR, so no caller can pair a recorded
# session's marker with another tree's config. No root means no decision: `ask`.
# Prints `<route>\t<source>` with route ∈ tdd|direct|ask and source ∈
# session|config|none.
zensu_delivery_route_resolve() {
  local project_dir="${1:-}" session_key="${2:-}" route
  [ -n "$project_dir" ] || { printf 'ask\tnone\n'; return 0; }
  route="$(zensu_delivery_route_marker_state "$project_dir" "$session_key")"
  case "$route" in
    (tdd|direct) printf '%s\t%s\n' "$route" session; return 0 ;;
  esac
  route="$(zensu_default_delivery_route "$project_dir")"
  case "$route" in
    (tdd|direct) printf '%s\t%s\n' "$route" config; return 0 ;;
  esac
  printf 'ask\tnone\n'
}

# The provenance line `/zensu:delivery-route --status` prints. It is rendered from the
# resolver's answer, so the ladder ORDER lives in zensu_delivery_route_resolve alone;
# the one fact the resolver does not carry — a RELEASED session choice, which it
# treats as no marker — is read beside it and only qualifies the source word.
zensu_delivery_route_status_line() {
  local project_dir="${1:-}" session_key="${2:-}" pair route source released=""
  pair="$(zensu_delivery_route_resolve "$project_dir" "$session_key")"
  route="${pair%%$'\t'*}"
  source="${pair#*$'\t'}"
  if [ "$(zensu_delivery_route_marker_state "$project_dir" "$session_key")" = "released" ]; then
    released=", session choice released"
  fi
  case "$source" in
    (session) printf '%s (session)\n' "$route" ;;
    (config)  printf '%s (config%s)\n' "$route" "$released" ;;
    (*)       printf 'ask (default%s)\n' "$released" ;;
  esac
}

# The rendered field both directives carry after `ZENSU DELIVERY ROUTE: `. One
# renderer, so the plan hook, the reminder and the doctor cannot spell it apart.
zensu_delivery_route_field() {
  local pair route source
  pair="$(zensu_delivery_route_resolve "${1:-}" "${2:-}")"
  route="${pair%%$'\t'*}"
  source="${pair#*$'\t'}"
  case "$source" in
    (session) printf '%s (session marker)\n' "$route" ;;
    (config)  printf '%s (hooks.defaultDeliveryRoute)\n' "$route" ;;
    (*)       printf 'ask\n' ;;
  esac
}

_zensu_log_style() {
  command -v node >/dev/null 2>&1 || { echo "wall"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var s=j.logging&&j.logging.timestampStyle;console.log(s==="relative"||s==="none"?s:"wall")' 2>/dev/null)
  [ -z "$val" ] && { echo "wall"; return 0; }
  echo "$val"
}

zensu_evidence_full_suite_command() {
  command -v node >/dev/null 2>&1 || return 0
  _zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var e=j.evidence;var c=(e&&typeof e==="object"&&!Array.isArray(e))?e.fullSuiteCommand:undefined;if(typeof c==="string"&&c.trim()!==""&&c.indexOf(String.fromCharCode(0))===-1)process.stdout.write(c)' 2>/dev/null
  return 0
}

zensu_evidence_full_suite_gate() {
  command -v node >/dev/null 2>&1 || { printf 'required'; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var e=j.evidence;var g=(e&&typeof e==="object"&&!Array.isArray(e))?e.fullSuiteGate:undefined;process.stdout.write(g===undefined||g===null||g===""?"required":(typeof g==="string"?g:JSON.stringify(g)).slice(0,200))' 2>/dev/null)
  [ -z "$val" ] && val="required"
  printf '%s' "$val"
}

# zen-mode's SESSION DEFAULT — what the mode resolves to before the session has
# recorded an explicit choice. Defaults to TRUE (zen-mode on), so a fresh install
# is low-noise out of the box; set hooks.zenModeDefault:false to restore the
# opt-in behavior. This is NOT hooks.zenMode: that flag decides whether the
# re-injection hook runs at all, and switching it off leaves the session marker
# untouched, while this one only supplies the value used when no marker exists.
zensu_zen_mode_default_on() {
  command -v node >/dev/null 2>&1 || return 0
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks.zenModeDefault===false?"0":"1")' 2>/dev/null)
  [ -z "$val" ] && return 0
  [ "$val" = "1" ]
}

zensu_autofix_include_suggestions() {
  command -v node >/dev/null 2>&1 || return 1
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks.autoFixIncludeSuggestions===true?"1":"0")' 2>/dev/null)
  [ "$val" = "1" ]
}

zensu_combined_summary_enabled() {
  command -v node >/dev/null 2>&1 || return 0
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.hooks&&j.hooks.combinedSummary===false?"0":"1")' 2>/dev/null)
  [ "$val" = "1" ]
}

# One bounded-integer reader behind every `hooks.<key>` that is a number with a
# range. There were three character-identical copies with four literals swapped,
# which is the hand-copy shape this repository treats as a first-class hazard
# everywhere else — and it had already cost something concrete: the newest copy's
# upper bound shipped unpinned against its own hand-copy in the doctor renderer.
#
# The MIN is inclusive here. `zensu_autofix_max_rounds` spelled its own as `n>0`;
# for a value that has already passed `Number.isInteger`, `n>0` and `n>=1` are the
# same predicate, so the collapse is behaviour-preserving rather than a widening.
# C58 in tests/structure/test-impl-stop-counter.sh drives every getter against
# their own min, max, one-below-min, one-above-max, a non-integer, a quoted number and
# an absent key, and it is what any future change to this helper owes the call sites
# below. It replaced a claim about a hand-run matrix that was committed nowhere —
# naming evidence the suite does not carry is the same defect as a stale comment.
#
# Argument order is (key, default, min, max) and reaches node as argv 2..4 with the
# default at argv[1], which is the position the previous three copies already used.
_zensu_config_bounded_int() {
  local key="$1" default="$2" min="$3" max="$4" val
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  # `hasOwnProperty` plus the object/array test, matching the strict reader above. Every
  # caller today passes a literal key, so nothing inherited is reachable in practice — but
  # this is now a reusable primitive whose three previous copies used static dot access,
  # and the contract that its key must be a trusted literal is not one a future caller can
  # see. The `typeof`/`Array.isArray` conjunct is not cosmetic: with `hasOwnProperty`
  # alone, a `"hooks": "abcde"` or `"hooks": [1,2,3]` makes `hooks.length` an own integer
  # property that can pass the bounds below.
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var h=j.hooks;var k=process.argv[2];var n=(h&&typeof h==="object"&&!Array.isArray(h)&&Object.prototype.hasOwnProperty.call(h,k))?h[k]:undefined;console.log(Number.isInteger(n)&&n>=Number(process.argv[3])&&n<=Number(process.argv[4])?String(n):process.argv[1])' "$default" "$key" "$min" "$max" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

# key default min max — the positional-literal contract binds EVERY getter line below.
# `getter_operand` in tests/structure/test-impl-stop-counter.sh reads operands straight out of
# FOUR getter calls for the constant-mirror pins — `implStopNudgeAfter` (C31, C31a),
# `pendingReviewTtlHours` (C57), `autopilotOwnerActivityTtlHours` (C57b) and
# `autopilotReleaseOwnerActivityTtlHours` (C57e) — and out of every getter for C58's bound
# matrix, which fails with `operands-unreadable` when any of them stops parsing. Keep the four
# operands as positional literals on one line in each.
#
# C29 reads those same operands and is NOT one of the mirror pins: it is a BEHAVIOURAL
# fallback check, driving the getter rather than comparing two constants. Listing it among
# them was wrong in this file exactly as it was wrong in the renderer, which records the
# same correction beside `IMPL_STOP_NUDGE_MAX`.
#
# State the COUNT against the pins that exist, not against the pins this comment was written
# beside. It named only the first two of them for two releases: C57b had already joined, and
# C57e arrived with the per-verb window split, so the roster a maintainer reads here disagreed
# with CLAUDE.md. A hand-maintained census next to a derived check is this repository's own
# recurring defect; re-derive it by grep before trusting the number.
#
# The helper is `hooks.<key>`-only BY CONSTRUCTION: its node program spells the
# namespace itself. `zensu_context_nudge_threshold` and `zensu_context_window_size`
# read `j.context.*` and are therefore not omitted members of this family — folding
# them in would mean widening this contract with a namespace parameter, which is a
# different decision from the one taken here.
zensu_autofix_max_rounds()        { _zensu_config_bounded_int autoFixMaxRounds 5 1 99; }
zensu_pending_review_ttl_hours()  { _zensu_config_bounded_int pendingReviewTtlHours 6 0 8760; }
zensu_impl_stop_nudge_after()     { _zensu_config_bounded_int implStopNudgeAfter 12 0 999999; }
zensu_worktree_keep_idle_hours()  { _zensu_config_bounded_int worktreeKeepIdleHours 72 1 8760; }
# Owner liveness asks "could this session still act", which `pendingReviewTtlHours` was never
# sized for — it answers how long a deferred-review marker stays meaningful. The Stop hook
# writes the owner's workflow document at every turn end, so its mtime is already a per-turn
# heartbeat and one hour is generous for it. `0` disables the check, with the disclosure the
# worker already writes to stderr.
# It governs `--autopilot-adopt` only. The two run verbs are not symmetric: adoption is
# constructive (the run continues under a new owner) while `--autopilot-release` CANCELS
# another session's run, so the destructive verb reads its own window below, with the six
# hours of benefit of the doubt it had before either key existed. See CLAUDE.md
# §"Autopilot Run Scope".
zensu_autopilot_owner_activity_ttl_hours() { _zensu_config_bounded_int autopilotOwnerActivityTtlHours 1 0 8760; }
zensu_autopilot_release_owner_activity_ttl_hours() { _zensu_config_bounded_int autopilotReleaseOwnerActivityTtlHours 6 0 8760; }

zensu_context_nudge_enabled() {
  command -v node >/dev/null 2>&1 || return 0
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();console.log(j.context&&j.context.compactionNudge===false?"0":"1")' 2>/dev/null)
  [ -z "$val" ] && return 0
  [ "$val" = "1" ]
}

zensu_context_nudge_threshold() {
  local default=50
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var n=j.context&&j.context.nudgeThreshold;console.log(Number.isInteger(n)&&n>=1&&n<=99?String(n):process.argv[1])' "$default" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

zensu_context_window_size() {
  # Echoes the configured context.windowSize, or empty when unset/invalid so the
  # caller stays silent at/below 200k and treats occupancy past 200k as a 1M window. Hooks are
  # not handed the real window size, so there is no safe numeric default here.
  command -v node >/dev/null 2>&1 || return 0
  _zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var n=j.context&&j.context.windowSize;if(Number.isInteger(n)&&n>=1000&&n<=100000000)console.log(String(n))' 2>/dev/null
}
