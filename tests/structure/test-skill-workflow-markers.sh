#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-mcp-tools.sh" 2>/dev/null || true

skill_unwrapped_mutation() {
  local f="$1" tok
  if grep -qF -- '--workflow-begin' "$f" && grep -qF -- '--workflow-end' "$f"; then
    return 0
  fi
  for tok in $(grep -oE '`[^`]+`' "$f" | grep -oE '[a-z][a-z0-9_]+' | sort -u); do
    if zensu_is_mutation_tool "$tok"; then echo "$tok"; return 0; fi
  done
}

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for t in get_feature list_features search_knowledge suggest_workflow analyze_journey_health validate_feature_security ghost_get_candidates pulse_start_session pulse_end_session pulse_session_summary; do
  if zensu_is_read_tool "$t" 2>/dev/null && ! zensu_is_mutation_tool "$t" 2>/dev/null; then
    check "T-read $t -> read, not mutation" PASS
  else
    check "T-read $t -> read, not mutation" FAIL
  fi
done

for t in set_security_classification create_feature analyze_feature_security complete_security_review link_test generate_threat_model ghost_apply apply_bootstrap update_feature bootstrap_from_vision; do
  if zensu_is_mutation_tool "$t" 2>/dev/null && ! zensu_is_read_tool "$t" 2>/dev/null; then
    check "T-mut $t -> mutation, not read" PASS
  else
    check "T-mut $t -> mutation, not read" FAIL
  fi
done

if zensu_is_zensu_tool "mcpGate" 2>/dev/null || zensu_is_mutation_tool "hooks" 2>/dev/null; then
  check "T-nontool non-tool token not classified as tool/mutation" FAIL
else
  check "T-nontool non-tool token not classified as tool/mutation" PASS
fi

FXD="$(mktemp -d -t skillmark-XXXXXX)"
mkdir -p "$FXD/bad"
printf '# bad\n\nStep 1: use `create_feature` to make it.\n' > "$FXD/bad/SKILL.md"
NEG="$(skill_unwrapped_mutation "$FXD/bad/SKILL.md" 2>/dev/null)"
[ -n "$NEG" ] && check "I3-neg unwrapped mutation skill flagged (got '$NEG')" PASS || check "I3-neg unwrapped mutation skill flagged (got '$NEG')" FAIL
rm -rf "$FXD"

FXP="$(mktemp -d -t skillmarkp-XXXXXX)"
mkdir -p "$FXP/good"
printf '# good\n\nFirst run `--workflow-begin`. Step: use `create_feature`. Last run `--workflow-end`.\n' > "$FXP/good/SKILL.md"
POS="$(skill_unwrapped_mutation "$FXP/good/SKILL.md" 2>/dev/null)"
[ -z "$POS" ] && check "I3-pos wrapped mutation skill NOT flagged" PASS || check "I3-pos wrapped skill flagged wrongly (got '$POS')" FAIL
rm -rf "$FXP"

SKILL_FAIL=0
for d in "${CLAUDE_PLUGIN_ROOT}"/skills/*/; do
  F="${d}SKILL.md"
  [ -f "$F" ] || continue
  off="$(skill_unwrapped_mutation "$F")"
  if [ -n "$off" ]; then
    SKILL_FAIL=$((SKILL_FAIL+1)); echo "      skill '$(basename "$d")' calls mutation tool '$off' but lacks --workflow-begin/--workflow-end"
  fi
done
[ "$SKILL_FAIL" -eq 0 ] && check "I3 every skill calling a mutation tool is workflow-wrapped" PASS || check "I3 unwrapped mutating skills ($SKILL_FAIL)" FAIL

FXH="$(mktemp -d -t skillmarkh-XXXXXX)"
mkdir -p "$FXH/half"
printf '# half\n\nFirst run `--workflow-begin`. Step: use `create_feature`.\n' > "$FXH/half/SKILL.md"
HALF="$(skill_unwrapped_mutation "$FXH/half/SKILL.md" 2>/dev/null)"
[ -n "$HALF" ] && check "I4-half begin-only (missing --workflow-end) flagged" PASS || check "I4-half half-wrapped flagged (got '$HALF')" FAIL
rm -rf "$FXH"

FXS="$(mktemp -d -t skillmarks-XXXXXX)"
mkdir -p "$FXS/sec"
printf '# sec\n\nStep: use `set_security_classification` on the feature.\n' > "$FXS/sec/SKILL.md"
SEC="$(skill_unwrapped_mutation "$FXS/sec/SKILL.md" 2>/dev/null)"
[ "$SEC" = "set_security_classification" ] && check "I4-2nd distinct mutation tool flagged" PASS || check "I4-2nd second tool flagged (got '$SEC')" FAIL
rm -rf "$FXS"

FXM="$(mktemp -d -t skillmarkm-XXXXXX)"
mkdir -p "$FXM/multi"
printf '# multi\n\nStep: call `create_feature(name, component)` to add it.\n' > "$FXM/multi/SKILL.md"
MULTI="$(skill_unwrapped_mutation "$FXM/multi/SKILL.md" 2>/dev/null)"
[ "$MULTI" = "create_feature" ] && check "I4-multi multi-token backtick span flagged" PASS || check "I4-multi multi-token flagged (got '$MULTI')" FAIL
rm -rf "$FXM"

echo "----"
echo "test-skill-workflow-markers: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
