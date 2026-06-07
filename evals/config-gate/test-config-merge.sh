#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-config-merge: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
PROJECT_CFG_DIR="$PROJECT_DIR/.zensu"
PROJECT_CFG="$PROJECT_CFG_DIR/config.json"
HOME_DIR="$TMP_DIR/home"
HOME_CFG_DIR="$HOME_DIR/.zensu"
HOME_CFG="$HOME_CFG_DIR/config.json"
mkdir -p "$PROJECT_CFG_DIR" "$HOME_CFG_DIR"

source "$HELPER"

# ---- (b) THE BUG: global sets the flag, project omits it -> must fall through ----
unset ZENSU_CONFIG
export HOME="$HOME_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
printf '{"hooks":{"autoFixIncludeSuggestions":true}}' > "$HOME_CFG"
printf '{"logging":{"timestampStyle":"none"}}' > "$PROJECT_CFG"

if zensu_autofix_include_suggestions; then
  check "(b) global autoFixIncludeSuggestions:true honored when project omits the key" PASS
else
  check "(b) global autoFixIncludeSuggestions:true honored when project omits the key" FAIL
fi

if [ "$(_zensu_log_style)" = "none" ]; then
  check "(b) project timestampStyle:none still wins over global" PASS
else
  check "(b) project timestampStyle:none still wins (got '$(_zensu_log_style)')" FAIL
fi

# ---- (a) project overrides global on a conflicting key ----
printf '{"hooks":{"combinedSummary":true}}'  > "$HOME_CFG"
printf '{"hooks":{"combinedSummary":false}}' > "$PROJECT_CFG"
if zensu_combined_summary_enabled; then
  check "(a) project combinedSummary:false overrides global true" FAIL
else
  check "(a) project combinedSummary:false overrides global true" PASS
fi

# ---- (c) nested hooks.* merge: global one key, project another, both survive ----
printf '{"hooks":{"autoFixIncludeSuggestions":true}}' > "$HOME_CFG"
printf '{"hooks":{"combinedSummary":false}}'          > "$PROJECT_CFG"
if zensu_autofix_include_suggestions; then
  check "(c) nested merge: global hooks.autoFixIncludeSuggestions survives project hooks override" PASS
else
  check "(c) nested merge: global hooks.autoFixIncludeSuggestions survives project hooks override" FAIL
fi
if zensu_combined_summary_enabled; then
  check "(c) nested merge: project hooks.combinedSummary:false survives" FAIL
else
  check "(c) nested merge: project hooks.combinedSummary:false survives" PASS
fi

merged="$(_zensu_config_json)"
if printf '%s' "$merged" | node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));process.exit(j.hooks&&j.hooks.autoFixIncludeSuggestions===true&&j.hooks.combinedSummary===false?0:1)' 2>/dev/null; then
  check "(c) _zensu_config_json merges global+project hooks keys" PASS
else
  check "(c) _zensu_config_json merges global+project hooks keys" FAIL
fi

# ---- (d) ZENSU_CONFIG full override (no merge) ----
ENV_CFG="$TMP_DIR/env.json"
printf '{"hooks":{"autoFixIncludeSuggestions":true}}' > "$HOME_CFG"
printf '{"hooks":{"combinedSummary":false}}'          > "$PROJECT_CFG"
printf '{"hooks":{"combinedSummary":true}}'           > "$ENV_CFG"
export ZENSU_CONFIG="$ENV_CFG"
if zensu_combined_summary_enabled; then
  check "(d) ZENSU_CONFIG overrides project combinedSummary" PASS
else
  check "(d) ZENSU_CONFIG overrides project combinedSummary" FAIL
fi
if zensu_autofix_include_suggestions; then
  check "(d) ZENSU_CONFIG is a full override — global autoFix flag not merged in" FAIL
else
  check "(d) ZENSU_CONFIG is a full override — global autoFix flag not merged in" PASS
fi

# ---- (e) neither file present -> hardcoded defaults ----
unset ZENSU_CONFIG
rm -f "$HOME_CFG" "$PROJECT_CFG"
if [ "$(_zensu_log_style)" = "wall" ]; then
  check "(e) no config -> _zensu_log_style default 'wall'" PASS
else
  check "(e) no config -> _zensu_log_style default 'wall' (got '$(_zensu_log_style)')" FAIL
fi
if [ "$(zensu_autofix_max_rounds)" = "5" ]; then
  check "(e) no config -> zensu_autofix_max_rounds default 5" PASS
else
  check "(e) no config -> zensu_autofix_max_rounds default 5 (got '$(zensu_autofix_max_rounds)')" FAIL
fi
if zensu_autofix_include_suggestions; then
  check "(e) no config -> autofix suggestions disabled (default)" FAIL
else
  check "(e) no config -> autofix suggestions disabled (default)" PASS
fi

# ---- (f) SECURITY: a project __proto__ key must NOT flip a gated default ----
# Requires a global hooks node so the merge recurses into the hooks object.
unset ZENSU_CONFIG
printf '{"hooks":{"autoFixMaxRounds":5}}'                  > "$HOME_CFG"
printf '{"hooks":{"__proto__":{"combinedSummary":false}}}' > "$PROJECT_CFG"
if zensu_combined_summary_enabled; then
  check "(f) project __proto__ injection does not flip combinedSummary default" PASS
else
  check "(f) project __proto__ injection does not flip combinedSummary default" FAIL
fi

# ---- (g) zensu_hook_enabled (gate getter) under two-file merge ----
printf '{"hooks":{"autoTdd":false}}'        > "$HOME_CFG"
printf '{"hooks":{"combinedSummary":true}}' > "$PROJECT_CFG"
if zensu_hook_enabled autoTdd; then
  check "(g) global hooks.autoTdd:false survives project overlay (gate disabled)" FAIL
else
  check "(g) global hooks.autoTdd:false survives project overlay (gate disabled)" PASS
fi
printf '{"hooks":{"autoTdd":true}}'  > "$HOME_CFG"
printf '{"hooks":{"autoTdd":false}}' > "$PROJECT_CFG"
if zensu_hook_enabled autoTdd; then
  check "(g) project hooks.autoTdd:false overrides global true (gate disabled)" FAIL
else
  check "(g) project hooks.autoTdd:false overrides global true (gate disabled)" PASS
fi

# ---- (h) context.* node merges across files (second top-level node) ----
printf '{"context":{"compactionNudge":false}}' > "$HOME_CFG"
printf '{"context":{"nudgeThreshold":80}}'      > "$PROJECT_CFG"
if zensu_context_nudge_enabled; then
  check "(h) global context.compactionNudge:false survives project overlay" FAIL
else
  check "(h) global context.compactionNudge:false survives project overlay" PASS
fi
if [ "$(zensu_context_nudge_threshold)" = "80" ]; then
  check "(h) project context.nudgeThreshold:80 survives global overlay" PASS
else
  check "(h) project context.nudgeThreshold:80 survives (got '$(zensu_context_nudge_threshold)')" FAIL
fi

echo "----"
echo "test-config-merge: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
