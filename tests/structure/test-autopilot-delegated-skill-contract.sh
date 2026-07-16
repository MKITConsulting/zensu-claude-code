#!/bin/bash
# Pin Autopilot's exact delegated caller envelopes and deterministic review identity.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUTO="$ROOT/skills/autopilot/SKILL.md"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
has() { grep -qF -- "$2" "$1"; }

TEAM_ENVELOPE="$(awk '
  $0 == "/zensu:pr-team-review <pr-url>" { capture=1 }
  capture && $0 == "```" { exit }
  capture { print }
' "$AUTO")"
EXPECTED_TEAM_ENVELOPE="$(printf '%s\n' \
  '/zensu:pr-team-review <pr-url>' \
  'ZENSU-DELEGATED-CALLER: autopilot' \
  'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' \
  'AUTOPILOT-STAGE: <outer-stage>' \
  'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>')"

if [ "$TEAM_ENVELOPE" = "$EXPECTED_TEAM_ENVELOPE" ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>' "$AUTO")" -eq 1 ]; then
  check "A1 Autopilot defines the exact delegated review envelope" PASS
else
  check "A1 Autopilot defines the exact delegated review envelope" FAIL
fi

if has "$AUTO" 'team-review:v1:<sha256(canonical({headSha,runId}))>' \
   && has "$AUTO" 'autopilot_team_review_operation_key "$RUN_ID" "$PR_HEAD_SHA"' \
   && has "$AUTO" 'The operation key is deterministic' \
   && has "$AUTO" 'TEAM_REVIEW_REQUESTED' \
   && has "$AUTO" 'same exact operation key'; then
  check "A2 review operation identity is deterministic and write-ahead bound" PASS
else
  check "A2 review operation identity is deterministic and write-ahead bound" FAIL
fi

if has "$AUTO" 'bash "$LOG" --autopilot-status' \
   && has "$AUTO" 'current durable `tdd.attempt` and `tdd.chainId`' \
   && has "$AUTO" 'current durable PR number, URL, and head SHA'; then
  check "A3 Autopilot renders envelopes from fresh durable state" PASS
else
  check "A3 Autopilot renders envelopes from fresh durable state" FAIL
fi

if has "$AUTO" '/zensu:pr-team-review <pr-url>' \
   && has "$AUTO" 'AUTOPILOT-STAGE: TEAM_REVIEW' \
   && has "$AUTO" 'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>'; then
  check "A4 team-review invocation carries all four exact lines" PASS
else
  check "A4 team-review invocation carries all four exact lines" FAIL
fi

FIX_ENVELOPE="$(awk '
  $0 == "/zensu:pr-fix-findings <pr-url>" { capture=1 }
  capture && $0 == "```" { exit }
  capture { print }
' "$AUTO")"
EXPECTED_FIX_ENVELOPE="$(printf '%s\n' \
  '/zensu:pr-fix-findings <pr-url>' \
  'ZENSU-DELEGATED-CALLER: autopilot' \
  'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' \
  'AUTOPILOT-STAGE: <outer-stage>')"

if [ "$FIX_ENVELOPE" = "$EXPECTED_FIX_ENVELOPE" ] \
   && [ "$(grep -cFx -- 'ZENSU-DELEGATED-CALLER: autopilot' "$AUTO")" -eq 2 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' "$AUTO")" -eq 2 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-STAGE: <outer-stage>' "$AUTO")" -eq 2 ] \
   && has "$AUTO" 'Fix-findings receives exactly the first three lines' \
   && has "$AUTO" 'never receives `AUTOPILOT-REVIEW-OP`'; then
  check "A5 fix-findings invocation carries only the three-line envelope" PASS
else
  check "A5 fix-findings invocation carries only the three-line envelope" FAIL
fi

echo "----"
echo "test-autopilot-delegated-skill-contract: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
