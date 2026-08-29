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
# ONE exception to "this file only reads config": the five TDD-mode helpers at the
# bottom also read the session-scoped mode marker under `<project>/.zensu/state/`.
# Two of them TOUCH THE FILESYSTEM — `zensu_tdd_mode_state_linked` (the `-L` probes)
# and `zensu_tdd_mode_marker_state` (the bounded read) — while
# `zensu_tdd_mode_marker_path` only spells the path and `zensu_tdd_mode_override` /
# `zensu_tdd_strict_effective` only reduce what the reader returned. An auditor asking
# "what in this file opens something" must get the first two names, not the others;
# node-free and outside the merge machinery above. It lives here so the writer
# (`hooks/lib/zensu-tdd-mode.sh`) and every reader share ONE path template and ONE
# parse; zen-mode hand-copies its template into its reader hook, and that is the
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

# The symlink refusal, spelled ONCE. Reader and writer both guard the same three
# components — `.zensu`, the state directory, the marker leaf — and the writer
# additionally guards its `mktemp` temp leaf, which is what the optional third
# argument is for. It lives here beside the path template for the same reason the
# template does: three hand-synced copies of the component list would diverge
# silently, and the tests that would catch a divergence (T9/T9b/T9d) are exactly
# the ones that skip themselves on a host without symlink support.
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

# The four-state marker reader `zensu_tdd_mode_override` is built on. It answers
# `strict`, `vanilla`, `released` (the marker is PRESENT and holds `{"mode":"auto"}`),
# or `none` (absent, symlinked, unreadable, oversized, or not a marker this plugin
# wrote). The `released` / `none` split is why `--auto` writes a file instead of
# deleting one: it is what lets `/zensu:tdd-mode --status` tell a deliberate release
# from a choice that was never made. `zensu_tdd_mode_override` collapses both back to
# `auto`, so every mode-resolving caller keeps its three-value contract unchanged.
zensu_tdd_mode_marker_state() {
  # Byte semantics, pinned for the whole function. `${#body}` is CHARACTER-counted in a
  # multibyte locale and `[[:space:]]` is locale-defined, so without this a marker
  # padded with multibyte spaces measures short, passes the 512 ceiling, and has its
  # tail swallowed by the whitespace class — a >513-byte file answered as a mode with
  # the remainder unexamined. `local` restores the caller's locale on return.
  local LC_ALL=C LC_CTYPE=C
  local project_dir="${1:-}" session_key="${2:-}" marker
  [ -n "$project_dir" ] && [ -n "$session_key" ] || { echo "none"; return 0; }
  marker="$(zensu_tdd_mode_marker_path "$project_dir" "$session_key")" || { echo "none"; return 0; }
  if zensu_tdd_mode_state_linked "$project_dir" "$marker" || [ ! -f "$marker" ]; then
    echo "none"
    return 0
  fi
  # The marker the writer emits is exactly one line: `{"mode":"<value>"}`. Match the
  # FIRST line, as a whole, and only when the file holds nothing after it.
  #
  # Both halves are load-bearing. A grep over the FILE would let a body contradict
  # its own key — `{"mode":"vanilla"} "mode":"strict"` on one line, or a second line
  # spelling the other mode — because `grep`'s `^`/`$` anchor a LINE, not the file.
  # Anything this rejects is by definition not a marker this plugin wrote, and falls
  # through to `auto`. The remainder is DRAINED, not sampled one line deep: reading
  # only line 2 would let `{"mode":"strict"}` + a blank line + `{"mode":"vanilla"}`
  # through unexamined. Trailing whitespace of any shape is tolerated; any other
  # content is not.
  # Bound the bytes that are actually CONSUMED, in ONE open. The writer's own
  # output is at most 19 bytes, so a small ceiling refuses nothing legitimate.
  # This used to be a `wc -c` pass followed by a separate `$(cat)` drain — two
  # opens, so a marker that GREW between them passed the ceiling and was then
  # slurped unbounded into a shell variable, on a path that runs on every prompt.
  # `head -c` caps the read itself, so the memory bound holds no matter what the
  # file does between calls; the length check below only decides the verdict.
  #
  # The `X` sentinel is load-bearing: `$(...)` strips trailing newlines, so
  # without it a 1000-byte file whose first 513 bytes end in newlines would
  # measure short, pass the ceiling, and have its tail go unexamined.
  local body="" first="" rest=""
  # Two different shells can complain here, and they need two different suppressions.
  # The redirect failure (an unreadable marker) is reported by the shell running the
  # GROUP, so the inner `2>/dev/null` covers it. The "ignored null byte in input"
  # warning on bash >= 4.4 is emitted by the shell PERFORMING the substitution, which
  # is outside that group — hence the outer redirect. Without either, a session with a
  # mode-0 or NUL-bearing marker would print on every prompt while the reader silently
  # answers `none` anyway. (macOS bash 3.2 drops NULs without a warning, so the second
  # case is invisible on this repo's usual host.)
  { body="$( { head -c 513 < "$marker"; printf 'X'; } 2>/dev/null )"; } 2>/dev/null
  body="${body%X}"
  [ "${#body}" -le 512 ] || { echo "none"; return 0; }
  first="${body%%$'\n'*}"
  if [ "$first" = "$body" ]; then rest=""; else rest="${body#*$'\n'}"; fi
  case "$rest" in *[![:space:]]*) echo "none"; return 0 ;; esac
  # `LC_ALL=C` is repeated on each grep, not inherited from the `local` above: a shell
  # local is not exported, so on a host that never exported LC_ALL these children would
  # classify `[[:space:]]` in their own locale. The in-shell halves (the length check
  # and the remainder scan) do get C semantics from the local; these three would not.
  if printf '%s\n' "$first" | LC_ALL=C grep -Eq '^[[:space:]]*\{[[:space:]]*"mode"[[:space:]]*:[[:space:]]*"strict"[[:space:]]*\}[[:space:]]*$'; then
    echo "strict"
  elif printf '%s\n' "$first" | LC_ALL=C grep -Eq '^[[:space:]]*\{[[:space:]]*"mode"[[:space:]]*:[[:space:]]*"vanilla"[[:space:]]*\}[[:space:]]*$'; then
    echo "vanilla"
  elif printf '%s\n' "$first" | LC_ALL=C grep -Eq '^[[:space:]]*\{[[:space:]]*"mode"[[:space:]]*:[[:space:]]*"auto"[[:space:]]*\}[[:space:]]*$'; then
    echo "released"
  else
    echo "none"
  fi
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
# session key. Callers that cannot resolve one — SessionStart, where no marker for
# the new session can exist yet — call zensu_tdd_strict_enabled directly instead;
# passing empty arguments here is equivalent and stays config-only.
zensu_tdd_strict_effective() {
  case "$(zensu_tdd_mode_override "${1:-}" "${2:-}")" in
    strict)  return 0 ;;
    vanilla) return 1 ;;
  esac
  zensu_tdd_strict_enabled
}

_zensu_log_style() {
  command -v node >/dev/null 2>&1 || { echo "wall"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var s=j.logging&&j.logging.timestampStyle;console.log(s==="relative"||s==="none"?s:"wall")' 2>/dev/null)
  [ -z "$val" ] && { echo "wall"; return 0; }
  echo "$val"
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

zensu_autofix_max_rounds() {
  local default=5
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var n=j.hooks&&j.hooks.autoFixMaxRounds;console.log(Number.isInteger(n)&&n>0&&n<=99?String(n):process.argv[1])' "$default" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

zensu_pending_review_ttl_hours() {
  local default=6
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var n=j.hooks&&j.hooks.pendingReviewTtlHours;console.log(Number.isInteger(n)&&n>=0&&n<=8760?String(n):process.argv[1])' "$default" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

zensu_impl_stop_nudge_after() {
  local default=12
  command -v node >/dev/null 2>&1 || { echo "$default"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var n=j.hooks&&j.hooks.implStopNudgeAfter;console.log(Number.isInteger(n)&&n>=0&&n<=1000000?String(n):process.argv[1])' "$default" 2>/dev/null)
  [ -z "$val" ] && { echo "$default"; return 0; }
  echo "$val"
}

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
