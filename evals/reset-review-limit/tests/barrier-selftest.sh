#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
SEEDER="$ROOT/evals/reset-review-limit/lib/seed-state.js"
BARRIER="$ROOT/evals/reset-review-limit/lib/session-start-barrier.sh"
TMP="$(mktemp -d -t zensu-reset-barrier-test-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
ENV_FILE="$TMP/claude.env"
READY="$TMP/ready"
ACK="$TMP/ack"
BEFORE="$TMP/before.json"
SID="11111111-1111-4111-8111-111111111111"
mkdir -p "$PROJECT"
node "$SEEDER" seed "$PROJECT" reset-invalid-state "$SID" "$CORE"
KEY="$(node "$CORE" session-key "$SID")"
printf "export ZENSU_SESSION_KEY='%s'\n" "$KEY" >"$ENV_FILE"

PAYLOAD="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",session_id:process.argv[1],cwd:process.argv[2]}))' "$SID" "$PROJECT")"
printf '%s' "$PAYLOAD" | \
  CLAUDE_ENV_FILE="$ENV_FILE" \
  ZENSU_RESET_REVIEW_LIMIT_ATTESTATION=1 \
  ZENSU_RESET_REVIEW_LIMIT_SCENARIO=reset-invalid-state \
  ZENSU_RESET_REVIEW_LIMIT_READY="$READY" \
  ZENSU_RESET_REVIEW_LIMIT_ACK="$ACK" \
  bash "$BARRIER" &
BARRIER_PID=$!

for _ in $(seq 1 500); do [ -f "$READY" ] && break; sleep 0.01; done
[ -f "$READY" ]
if CONTROL_CORE="$CORE" PROJECT="$PROJECT" SID="$SID" node -e '
  const core=require(process.env.CONTROL_CORE);
  core.readWorkflowState({projectRoot:process.env.PROJECT,sessionId:process.env.SID});
' 2>/dev/null; then
  echo 'barrier-selftest: invalid state stayed valid after ready' >&2
  exit 1
fi
kill -0 "$BARRIER_PID"
node "$SEEDER" snapshot "$PROJECT" reset-invalid-state "$SID" "$BEFORE" "$CORE"
node -e 'const fs=require("node:fs");const fd=fs.openSync(process.argv[1],"wx",0o600);fs.closeSync(fd)' "$ACK"
wait "$BARRIER_PID"
node -e '
  const fs=require("node:fs"), before=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  if(before.snapshot.status!=="invalid" || before.snapshot.state.reviewRound!=="3") process.exit(1);
' "$BEFORE"
printf 'barrier-selftest.sh: PASS\n'
