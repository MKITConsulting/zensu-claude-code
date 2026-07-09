#!/bin/bash
set -u

# Structure test for additive-only repo skill overlays. Pins per supporting
# skill (tdd, cover, pr-team-review): the anchor comment exists exactly once,
# the injection instruction (overlays path, additive-only wording,
# never-disable list, conflict-wins + surfaced line, missing/empty no-op) and
# the trust-boundary sentence sit at the anchor. Pins the README section
# (names, path, additive-only contract, trust boundary, example overlay).
# NEGATIVE guards: stable mandatory-phase sentences of each skill stay
# present, so an overlay-motivated edit weakening enforcement fails the suite.
# Also guards the tdd 430-line cap (same constant pinned by
# test-review-personas.sh and test-tdd-manager-patches.sh — bump all three).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TDD_MD="$PLUGIN_DIR/skills/tdd/SKILL.md"
COVER_MD="$PLUGIN_DIR/skills/cover/SKILL.md"
PRTR_MD="$PLUGIN_DIR/skills/pr-team-review/SKILL.md"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$TDD_MD" "$COVER_MD" "$PRTR_MD" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-skill-overlays: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

overlay_pins() {
  local key="$1" file="$2"
  local n
  n="$(grep -cxF "<!-- zensu:overlay $key -->" "$file")"
  if [ "$n" = "1" ]; then
    check "P1 $key anchor comment exists exactly once" PASS
  else
    check "P1 $key anchor comment exists exactly once (got: $n)" FAIL
  fi
  if grep -qF ".zensu/overlays/$key.md" "$file"; then
    check "P1 $key resolves the overlays path" PASS
  else
    check "P1 $key resolves the overlays path" FAIL
  fi
  if grep -A1 -xF "<!-- zensu:overlay $key -->" "$file" | grep -qF '> **Repo overlay (additive-only).**'; then
    check "P1 $key instruction block adjacent to the anchor" PASS
  else
    check "P1 $key instruction block adjacent to the anchor" FAIL
  fi
  if grep -qF 'it may ADD conventions, extra checks, and stack particularities' "$file" && grep -qF 'NEVER disable, replace, weaken, or reorder' "$file"; then
    check "P1 $key additive-only + never-disable rules pinned" PASS
  else
    check "P1 $key additive-only + never-disable rules pinned" FAIL
  fi
  if grep -qF 'the skill text wins' "$file" && grep -qF 'naming the ignored overlay directive' "$file"; then
    check "P1 $key conflict-wins + surfaced line pinned" PASS
  else
    check "P1 $key conflict-wins + surfaced line pinned" FAIL
  fi
  if grep -qF 'Missing or empty file = no-op' "$file" && grep -qF 'repo-controlled prompts' "$file"; then
    check "P1 $key no-op + trust boundary at the anchor" PASS
  else
    check "P1 $key no-op + trust boundary at the anchor" FAIL
  fi
}
overlay_pins tdd "$TDD_MD"
overlay_pins cover "$COVER_MD"
overlay_pins pr-team-review "$PRTR_MD"

# P2 — README section
if grep -qF '#### Skill overlays (additive-only)' "$README" && grep -qF '.zensu/overlays/<name>.md' "$README"; then
  check "P2a README documents the overlay path + section" PASS
else
  check "P2a README documents the overlay path + section" FAIL
fi
if grep -qF 'NEVER disable, replace, weaken, or reorder' "$README" && grep -qiF 'not enforced by code' "$README"; then
  check "P2b README states additive-only + trust boundary" PASS
else
  check "P2b README states additive-only + trust boundary" FAIL
fi
if grep -qF '.zensu/overlays/tdd.md' "$README" && grep -qF 'Team convention:' "$README"; then
  check "P2c README carries an example overlay" PASS
else
  check "P2c README carries an example overlay" FAIL
fi

# P3 — NEGATIVE guards: mandatory-phase sentences stay intact
if grep -qF -- '`--tdd-complete` arms the review-chain Stop backstop' "$TDD_MD"; then
  check "P3a tdd review-chain backstop sentence intact" PASS
else
  check "P3a tdd review-chain backstop sentence intact" FAIL
fi
if grep -qF 'Reuse the Zensu review chain' "$COVER_MD"; then
  check "P3b cover Phase-3 review-chain contract intact" PASS
else
  check "P3b cover Phase-3 review-chain contract intact" FAIL
fi
if grep -qF 'Mandatory `### Test Coverage` section.' "$PRTR_MD"; then
  check "P3c pr-team-review mandatory coverage sentence intact" PASS
else
  check "P3c pr-team-review mandatory coverage sentence intact" FAIL
fi
LINES="$(wc -l < "$TDD_MD" | tr -d '[:space:]')"
if [ "$LINES" -le 430 ]; then
  check "P3d tdd skill stays under the 430-line cap (actual: $LINES)" PASS
else
  check "P3d tdd skill stays under the 430-line cap (actual: $LINES)" FAIL
fi

echo "----"
echo "test-skill-overlays: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
