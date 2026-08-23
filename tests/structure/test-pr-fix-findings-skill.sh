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

# F8 — the standalone completion contract. A run that pushes and then asks whether to
# resolve the threads it just fixed is the failure this section exists to remove, so the
# closed list of legal stops and the prohibition on permission questions are both pinned.
# The negative half ("These are NOT stops") is pinned separately: keeping only the closed
# list would leave a reader free to invent a stop the list does not mention.
CONTRACT="$(awk '
  /^## Completion contract \(standalone\)/ { inside=1 }
  inside && /^## Procedure/ { exit }
  inside { print }
' "$SKILL")"
CONTRACT_BAD=""
[ -n "$CONTRACT" ] || CONTRACT_BAD="$CONTRACT_BAD no-section"
for LIT in 'Steps 4–7 are ONE unit' \
           'Never ask permission for a step this procedure already prescribes' \
           'Legal early stops are a CLOSED list' \
           'These are NOT stops' \
           'A legal stop still lands what is already finished' \
           'At most one question per run'; do
  printf '%s' "$CONTRACT" | grep -qF -- "$LIT" || CONTRACT_BAD="$CONTRACT_BAD ${LIT// /_}"
done
if [ -z "$CONTRACT_BAD" ]; then
  check "F8 standalone completion contract closes the mid-run stop channel" PASS
else
  check "F8 standalone completion contract:$CONTRACT_BAD" FAIL
fi

# F9 — push → resolve continuity, pinned at the two steps that own it plus the loop
# clause that used to sanction an open-ended early stop. Anchored on the step bodies
# rather than on the file, so moving a sentence out of its step fails here.
LAND_STEP="$(awk '/^5\. \*\*Land the changes/ { inside=1 } inside { print } inside && /^6\. \*\*Resolve the threads/ { exit }' "$SKILL")"
RESOLVE_STEP="$(awk '/^6\. \*\*Resolve the threads/ { inside=1 } inside { print } inside && /^7\. \*\*Report back/ { exit }' "$SKILL")"
CONTINUITY_BAD=""
printf '%s' "$LAND_STEP" | grep -qF -- 'The push is not a checkpoint' \
  || CONTINUITY_BAD="$CONTINUITY_BAD land-step"
printf '%s' "$RESOLVE_STEP" | grep -qF -- 'A pushed-but-unresolved' \
  || CONTINUITY_BAD="$CONTINUITY_BAD resolve-step"
has "$SKILL" 'Never end a turn between the push and' \
  || CONTINUITY_BAD="$CONTINUITY_BAD turn-boundary"
has "$SKILL" 'Nothing else is a legal stop' \
  || CONTINUITY_BAD="$CONTINUITY_BAD loop-clause"
has "$SKILL" 'this offer is the ONLY user-facing prompt' \
  || CONTINUITY_BAD="$CONTINUITY_BAD next-step"
if [ -z "$CONTINUITY_BAD" ]; then
  check "F9 push and thread resolution stay one uninterrupted unit" PASS
else
  check "F9 push/resolve continuity:$CONTINUITY_BAD" FAIL
fi

echo "----"
echo "test-pr-fix-findings-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
