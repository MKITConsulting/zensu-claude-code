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

_zensu_log_style() {
  command -v node >/dev/null 2>&1 || { echo "wall"; return 0; }
  local val
  val=$(_zensu_config_node -e "$_ZENSU_CFG_JS"' var j=cfg();var s=j.logging&&j.logging.timestampStyle;console.log(s==="relative"||s==="none"?s:"wall")' 2>/dev/null)
  [ -z "$val" ] && { echo "wall"; return 0; }
  echo "$val"
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
