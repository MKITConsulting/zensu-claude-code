#!/bin/bash
# Structure contract for standalone and Autopilot-delegated PR finding fixes.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/pr-fix-findings/SKILL.md"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
has() { grep -qF -- "$2" "$1"; }

if [ -f "$SKILL" ]; then check "F1 skill exists" PASS; else check "F1 skill exists" FAIL; fi

FIX_ENVELOPE="$(awk '
  $0 == "ZENSU-DELEGATED-CALLER: autopilot" { capture=1 }
  capture && $0 == "```" { exit }
  capture { print }
' "$SKILL")"
EXPECTED_FIX_ENVELOPE="$(printf '%s\n' \
  'ZENSU-DELEGATED-CALLER: autopilot' \
  'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' \
  'AUTOPILOT-STAGE: <outer-stage>')"

if [ "$FIX_ENVELOPE" = "$EXPECTED_FIX_ENVELOPE" ] \
   && [ "$(grep -cFx -- 'ZENSU-DELEGATED-CALLER: autopilot' "$SKILL")" -eq 1 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' "$SKILL")" -eq 1 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-STAGE: <outer-stage>' "$SKILL")" -eq 1 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>' "$SKILL")" -eq 0 ] \
   && has "$SKILL" 'three contiguous lines with no intervening or additional delegated headers' \
   && has "$SKILL" 'any delegated-envelope header' \
   && has "$SKILL" 'partial, duplicate, malformed, or conflicting'; then
  check "F2 delegated fix envelope is exact and fail-closed" PASS
else
  check "F2 delegated fix envelope is exact and fail-closed" FAIL
fi

FRESH_NEEDLES=(
  'bash "$LOG" --autopilot-status'
  '`ownerSessionId`'
  '`tdd.sessionId`'
  '`runId`'
  '`tdd.attempt`'
  '`tdd.chainId`'
  '`stage`'
  '`evidence.pr.number`'
  '`evidence.pr.url`'
  '`evidence.pr.headSha`'
  '`effects.prOpen.status == "completed"`'
  '`effects.teamReview.status == "completed"`'
  '`evidence.review.published == true`'
)
FRESH=true
for needle in "${FRESH_NEEDLES[@]}"; do has "$SKILL" "$needle" || FRESH=false; done
if [ "$FRESH" = true ]; then
  check "F3 delegated fix revalidates owner, generation, stage, and PR binding" PASS
else
  check "F3 delegated fix revalidates owner, generation, stage, and PR binding" FAIL
fi

if has "$SKILL" 'complete paginated thread fetch' \
   && has "$SKILL" 'fail closed on pagination' \
   && has "$SKILL" 'one aggregate bound `/zensu:tdd` fix run' \
   && has "$SKILL" 'AUTOPILOT-RUN: <runId>' \
   && has "$SKILL" 'serially in the main task' \
   && has "$SKILL" 'no parallel editing agents or editing worktrees'; then
  check "F4 delegated fixes are complete, serial, and generation-bound" PASS
else
  check "F4 delegated fixes are complete, serial, and generation-bound" FAIL
fi

if has "$SKILL" 'immediately before every remote mutation' \
   && has "$SKILL" 'immediately before every push' \
   && has "$SKILL" 'state is `OPEN`' \
   && has "$SKILL" 'remote head equals `evidence.pr.headSha`'; then
  check "F5 delegated remote writes are guarded by OPEN/current-head checks" PASS
else
  check "F5 delegated remote writes are guarded by OPEN/current-head checks" FAIL
fi

if has "$SKILL" 'Standalone mode keeps the interactive parallelism policy above' \
   && has "$SKILL" 'Next step' \
   && has "$SKILL" 'not delegated' \
   && has "$SKILL" 'In standalone mode only, stop early and ask the user'; then
  check "F6 standalone behavior and next-step prompt remain available" PASS
else
  check "F6 standalone behavior and next-step prompt remain available" FAIL
fi

UNQUALIFIED_ASKS="$(SKILL_MD="$SKILL" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.env.SKILL_MD, "utf8").split(/\r?\n/);
  const interactive = /AskUserQuestion|ask (?:the )?user|ask again|ask anyway|always asks|pause and wait|escalate to (?:the )?user/i;
  const qualified = /standalone/i;
  const prohibition = /(?:do not|never|without)\b.*\bask/i;
  lines.forEach((line, index) => {
    if (interactive.test(line) && !qualified.test(line) && !prohibition.test(line)) {
      process.stdout.write(`${index + 1}:${line}\n`);
    }
  });
')"
if [ -z "$UNQUALIFIED_ASKS" ] \
   && has "$SKILL" 'fix-provider-unknown' \
   && has "$SKILL" 'fix-auth-unavailable' \
   && has "$SKILL" 'persist `BLOCK`'; then
  check "F7 delegated provider/auth blockers never enter an interactive ask path" PASS
else
  [ -z "$UNQUALIFIED_ASKS" ] || printf '%s\n' "$UNQUALIFIED_ASKS" >&2
  check "F7 delegated provider/auth blockers never enter an interactive ask path" FAIL
fi

echo "----"
echo "test-pr-fix-findings-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
