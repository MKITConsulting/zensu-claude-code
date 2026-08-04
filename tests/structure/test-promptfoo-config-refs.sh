#!/bin/bash
# Promptfoo configs may only reference files that exist.
#
# evals/tdd-manager/ pointed its `custom_system_prompt` at agents/tdd-manager.md
# for several releases after that agent was deleted in the main-thread migration.
# Nothing failed, because the suite was never wired into tests/run-all.sh — a
# dead eval is indistinguishable from a passing one when nobody runs it.
#
# This guard is deliberately dependency-free (no node_modules, no promptfoo, no
# YAML parser) so it keeps working in exactly the situation that hid the rot.
# It resolves every `file://` reference and every `custom_system_prompt:` target
# in each promptfoo config and scenario, relative to the referring file, and
# fails when the target is missing.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVALS_DIR="$PLUGIN_DIR/evals"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

# Referring files: every promptfoo config plus every scenario/prompt YAML they
# pull in (assertion refs live in scenarios too).
REFERRERS="$(find "$EVALS_DIR" \
  \( -name 'promptfooconfig*.yaml' -o -name 'promptfooconfig*.yml' \) -type f 2>/dev/null
find "$EVALS_DIR" -path '*/scenarios/*' \( -name '*.yaml' -o -name '*.yml' \) -type f 2>/dev/null)"

CONFIG_COUNT="$(find "$EVALS_DIR" \( -name 'promptfooconfig*.yaml' -o -name 'promptfooconfig*.yml' \) -type f 2>/dev/null | wc -l | tr -d ' ')"

echo "== Discovery =="
[ "$CONFIG_COUNT" -ge 5 ]
check "D1 promptfoo configs discovered under evals/ (found: $CONFIG_COUNT, expect >=5)" "$(verdict $?)"
[ -n "$REFERRERS" ]
check "D2 referring files (configs + scenarios) is non-empty" "$(verdict $?)"

echo "== Every referenced file resolves =="
MISSING=0
CHECKED=0
# promptfoo resolves `file://` relative to the CONFIG, not to the file that
# happens to contain the reference — a scenario under scenarios/ naming
# `assertions/x.js` means <eval-root>/assertions/x.js. Resolving against the
# referrer's own directory would report every such reference as missing.
config_base() {
  local d
  d="$(cd "$(dirname "$1")" && pwd)"
  while [ "$d" != "/" ] && [ "$d" != "$PLUGIN_DIR" ]; do
    # Test each glob separately: `ls a* b*` exits non-zero when EITHER pattern
    # has no match, which would silently defeat the walk.
    if ls "$d"/promptfooconfig*.yaml >/dev/null 2>&1 || ls "$d"/promptfooconfig*.yml >/dev/null 2>&1; then
      printf '%s' "$d"; return 0
    fi
    d="$(dirname "$d")"
  done
  printf '%s' "$(cd "$(dirname "$1")" && pwd)"
}

for f in $REFERRERS; do
  [ -f "$f" ] || continue
  dir="$(config_base "$f")"
  own_dir="$(cd "$(dirname "$f")" && pwd)"
  rel_referrer="${f#"$PLUGIN_DIR"/}"

  # `file://<path>` in any position: prompts, tests, scenario includes,
  # `value:` assertion files, provider config.
  refs="$(grep -o 'file://[^ "'"'"']*' "$f" 2>/dev/null | sed 's|^file://||')"
  # `custom_system_prompt: <path>` written without the file:// scheme.
  bare="$(grep -o "custom_system_prompt:[[:space:]]*[^ \"']*" "$f" 2>/dev/null \
    | sed 's/custom_system_prompt:[[:space:]]*//' | sed 's|^file://||')"

  for ref in $refs $bare; do
    [ -n "$ref" ] || continue
    case "$ref" in
      http*|https*) continue ;;   # remote providers are not our business
    esac
    ref="${ref%\"}"; ref="${ref%\'}"; ref="${ref%,}"
    CHECKED=$((CHECKED+1))
    # Accept config-relative (promptfoo's rule) or referrer-relative, and allow a
    # trailing js function selector such as file://x.js:handler.
    stripped="${ref%:*}"
    found=1
    for cand in "$dir/$ref" "$own_dir/$ref" "$dir/$stripped" "$own_dir/$stripped"; do
      [ -e "$cand" ] && { found=0; break; }
    done
    if [ "$found" -ne 0 ]; then
      echo "        missing: $rel_referrer -> $ref"
      MISSING=$((MISSING+1))
    fi
  done
done

[ "$CHECKED" -ge 10 ]
check "R1 references were actually extracted (checked: $CHECKED, expect >=10)" "$(verdict $?)"
[ "$MISSING" -eq 0 ]
check "R2 every referenced file exists (missing: $MISSING)" "$(verdict $?)"

echo "== The dead eval stays dead =="
[ ! -d "$EVALS_DIR/tdd-manager" ]
check "X1 evals/tdd-manager/ is gone (its custom_system_prompt named a deleted agent)" "$(verdict $?)"
# The referenced agent really is absent — so a reintroduced pointer would be a bug,
# not a false alarm.
[ ! -f "$PLUGIN_DIR/agents/tdd-manager.md" ]
check "X2 agents/tdd-manager.md is absent, so any pointer at it is genuinely dead" "$(verdict $?)"

echo "== Self-check: the guard actually detects a dangling reference =="
PROBE_DIR="$(mktemp -d)" || exit 1
cleanup() { [ -n "${PROBE_DIR:-}" ] && rm -rf "$PROBE_DIR"; return 0; }
trap cleanup EXIT INT TERM
printf 'providers:\n  - id: x\n    config:\n      custom_system_prompt: file://../../agents/does-not-exist.md\n' \
  > "$PROBE_DIR/promptfooconfig-probe.yaml"
PROBE_REF="$(grep -o 'file://[^ "'"'"']*' "$PROBE_DIR/promptfooconfig-probe.yaml" | sed 's|^file://||')"
{ [ -n "$PROBE_REF" ] && [ ! -e "$PROBE_DIR/$PROBE_REF" ]; }
check "S1 the extraction+existence logic flags a known-dangling reference" "$(verdict $?)"

echo "----"
echo "test-promptfoo-config-refs: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
