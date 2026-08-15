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
# ONE exception to "this file only reads config": the TDD-mode trio at the bottom
# (`zensu_tdd_mode_marker_path`, `zensu_tdd_mode_override`, `zensu_tdd_strict_effective`)
# also reads the session-scoped mode marker under `<project>/.zensu/state/`,
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

zensu_tdd_mode_override() {
  local project_dir="${1:-}" session_key="${2:-}" state_dir marker
  [ -n "$project_dir" ] && [ -n "$session_key" ] || { echo "auto"; return 0; }
  marker="$(zensu_tdd_mode_marker_path "$project_dir" "$session_key")" || { echo "auto"; return 0; }
  # Derived, never re-spelled — the writer derives its own state dir the same way.
  state_dir="$(dirname "$marker")"
  # `.zensu` is checked with them: a link there relocates the state directory
  # while both leaf checks stay false, and the writer refuses the same shape.
  if [ -L "$project_dir/.zensu" ] || [ -L "$state_dir" ] || [ -L "$marker" ] || [ ! -f "$marker" ]; then
    echo "auto"
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
  # Bound the file before draining it. The writer's own output is 19 bytes, so a
  # small ceiling refuses nothing legitimate — while an unbounded `$(cat)` would
  # pull an arbitrarily large file into a shell variable on a path that runs on
  # every prompt, and the marker is writable in-session (see the T9f gap).
  local size=""
  size="$(wc -c < "$marker" 2>/dev/null | tr -d '[:space:]')"
  case "$size" in ''|*[!0-9]*) echo "auto"; return 0 ;; esac
  [ "$size" -le 512 ] || { echo "auto"; return 0; }
  local first="" rest=""
  { IFS= read -r first || true; rest="$(cat)"; } < "$marker" 2>/dev/null
  case "$rest" in *[![:space:]]*) echo "auto"; return 0 ;; esac
  if printf '%s\n' "$first" | grep -Eq '^[[:space:]]*\{[[:space:]]*"mode"[[:space:]]*:[[:space:]]*"strict"[[:space:]]*\}[[:space:]]*$'; then
    echo "strict"
  elif printf '%s\n' "$first" | grep -Eq '^[[:space:]]*\{[[:space:]]*"mode"[[:space:]]*:[[:space:]]*"vanilla"[[:space:]]*\}[[:space:]]*$'; then
    echo "vanilla"
  else
    echo "auto"
  fi
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
