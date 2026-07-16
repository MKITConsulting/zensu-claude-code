#!/bin/bash
set -euo pipefail

[ "${ZENSU_RESET_REVIEW_LIMIT_ATTESTATION:-0}" = 1 ] || { cat >/dev/null; exit 0; }
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
SEEDER="$ROOT/evals/reset-review-limit/lib/seed-state.js"
SCENARIO="${ZENSU_RESET_REVIEW_LIMIT_SCENARIO:?missing reset scenario}"
READY="${ZENSU_RESET_REVIEW_LIMIT_READY:?missing reset barrier ready path}"
ACK="${ZENSU_RESET_REVIEW_LIMIT_ACK:?missing reset barrier ack path}"
PAYLOAD="$(cat)"
SESSION_ID="$(printf '%s' "$PAYLOAD" | node -e '
  let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{
    const p=JSON.parse(s); if(p.hook_event_name!=="SessionStart") process.exit(2);
    process.stdout.write(p.session_id);
  })')"
PROJECT_ROOT="$(printf '%s' "$PAYLOAD" | node -e '
  let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(JSON.parse(s).cwd))')"
SESSION_KEY="$(node "$CORE" session-key "$SESSION_ID")"

# This settings-level hook may start concurrently with plugin hooks. Wait until
# the real Session Control hook has validated the still-valid provider seed and
# appended the exact session binding, then perform the invalid-state tamper.
for _ in $(seq 1 1000); do
  if [ -f "${CLAUDE_ENV_FILE:-}" ] \
    && grep -Fq "export ZENSU_SESSION_KEY='$SESSION_KEY'" "$CLAUDE_ENV_FILE"; then
    break
  fi
  sleep 0.01
done
[ -f "${CLAUDE_ENV_FILE:-}" ] \
  && grep -Fq "export ZENSU_SESSION_KEY='$SESSION_KEY'" "$CLAUDE_ENV_FILE" \
  || { echo 'reset-review-limit barrier: Session Control startup did not complete' >&2; exit 1; }

node "$SEEDER" barrier "$PROJECT_ROOT" "$SCENARIO" "$SESSION_ID" "$CORE"
node -e 'const fs=require("node:fs");const fd=fs.openSync(process.argv[1],"wx",0o600);fs.closeSync(fd)' "$READY"
for _ in $(seq 1 1000); do
  [ -f "$ACK" ] && exit 0
  sleep 0.01
done
echo 'reset-review-limit barrier: provider acknowledgement timed out' >&2
exit 1
