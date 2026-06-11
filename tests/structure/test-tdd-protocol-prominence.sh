#!/usr/bin/env bash
# The TDD command protocol (arm with --tdd-begin; declare every phase with
# --phase <P> --step <id>) must be carried prominently by the PLUGIN itself.
# Live evidence from the zensu-kiro port (kiro-cli 2.6.1, eval B5): a headless
# model following this same skill skipped arming entirely in run 1 and omitted
# --step on the markers in run 2 — the contract was documented but buried at
# Phase 4 of a ~380-line skill. A compact mandatory block at the TOP of the
# skill plus the arming/per-step contract in the session primer fixed it,
# proven by a neutral-prompt live re-run. Pin both carriers here so the
# prominence never regresses.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

SKILL="$ROOT/skills/tdd/SKILL.md"
PRIMER="$ROOT/hooks/session-start-primer.sh"

# ── 1) zensu:tdd skill: mandatory command block ABOVE "## When to Use" ──────
TOP="$(awk '/^## When to Use/{exit} {print}' "$SKILL")"

printf '%s' "$TOP" | grep -qi "command protocol" \
  && ok "skill top: command-protocol heading present" \
  || bad "skill top: no command-protocol heading before '## When to Use'"

printf '%s' "$TOP" | grep -q -- "--tdd-begin" \
  && ok "skill top: arming command (--tdd-begin) present" \
  || bad "skill top: --tdd-begin missing"

for M in RED_WRITE RED_RUN RED_FAIL IMPL GREEN_RUN GREEN_PASS; do
  printf '%s' "$TOP" | grep -q -- "--phase $M --step" \
    && ok "skill top: marker $M carries --step" \
    || bad "skill top: --phase $M --step missing"
done

printf '%s' "$TOP" | grep -qi "REQUIRED on every marker" \
  && ok "skill top: --step REQUIRED-on-every-marker rule stated" \
  || bad "skill top: per-marker --step requirement not stated"

printf '%s' "$TOP" | grep -qi "per step" \
  && ok "skill top: IMPL-matches-RED_FAIL-per-step rule stated" \
  || bad "skill top: per-step gate matching not stated"

# ── 2) session primer: arming + per-step contract reach EVERY session ───────
grep -q -- "--tdd-begin" "$PRIMER" \
  && ok "primer: names the --tdd-begin arming command" \
  || bad "primer: --tdd-begin missing"

grep -q -- "--step" "$PRIMER" \
  && ok "primer: names the per-marker --step requirement" \
  || bad "primer: --step missing"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
