#!/bin/bash
# Durable outer Autopilot state: schema, transitions, idempotency, and storage.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
VCS_LIB="$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"

PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$label"
    FAIL=$((FAIL + 1))
  fi
}

if [ ! -f "$LIB" ]; then
  check "S1 durable state library exists" FAIL
  printf '%s\n' "----" "test-autopilot-state-machine: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "S1 durable state library exists" PASS
if bash -n "$LIB" 2>/dev/null; then
  check "S2 library passes bash syntax validation" PASS
else
  check "S2 library passes bash syntax validation" FAIL
fi

if grep -qF 'fd = fs.openSync(file, "r+");' "$LIB" \
  && grep -qF 'fs.fsyncSync(fd);' "$LIB" \
  && grep -qF 'fs.closeSync(fd);' "$LIB"; then
  check "S2b durable state fsync uses a writable descriptor and closes it" PASS
else
  check "S2b durable state fsync uses a writable descriptor and closes it" FAIL
fi

if grep -qF 'if (process.platform !== "win32") {' "$LIB" \
  && grep -qF 'directoryFd = fs.openSync(directory, fs.constants.O_RDONLY);' "$LIB"; then
  check "S2c directory fsync remains POSIX-only" PASS
else
  check "S2c directory fsync remains POSIX-only" FAIL
fi

# shellcheck disable=SC1090
source "$LIB"
# shellcheck disable=SC1090
source "$VCS_LIB"

ROOT="$(mktemp -d -t zensu-autopilot-state-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
PROJECT="$ROOT/project"
mkdir -p "$PROJECT"
PROJECT_PHYSICAL="$(cd "$PROJECT" && pwd -P)"
export CLAUDE_PROJECT_DIR="$PROJECT"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$ROOT/no-config.json"

RUN="run_primary_001"
OWNER="session_owner_001"
PLAN_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
HEAD_SHA_2="cccccccccccccccccccccccccccccccccccccccc"
HEAD_SHA_3="dddddddddddddddddddddddddddddddddddddddd"
HEAD_SHA_4="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
RUN_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN}.json"
ACTIVE_FILE="$PROJECT/.zensu/state/autopilot-active.json"

json_ok() {
  local file="$1" expression="$2"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const expression = process.argv[2];
    process.exit(Function("value", `return Boolean(${expression})`)(value) ? 0 : 1);
  ' "$file" "$expression" >/dev/null 2>&1
}

file_digest() {
  node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

private_mode_ok() {
  node -e 'const fs=require("fs");process.exit(process.platform==="win32"||(fs.statSync(process.argv[1]).mode&0o777)===0o600?0:1);' "$1"
}

IS_WINDOWS="$(node -p 'process.platform === "win32" ? "true" : "false"')"
make_file_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}
make_directory_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"junction":"dir");
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}

json_field_stdin() {
  FIELD="$1" node -e '
    let value;try{value=JSON.parse(require("fs").readFileSync(0,"utf8"));}catch(_){process.exit(1);}
    const field=value[process.env.FIELD];
    if(typeof field!=="string")process.exit(1);
    process.stdout.write(field);
  '
}

review_operation_key() {
  local run_id="$1" head_sha="$2"
  RUN_ID="$run_id" HEAD_SHA="$head_sha" node -e '
    const crypto = require("crypto");
    const canonical = value => value && typeof value === "object" && !Array.isArray(value)
      ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`
      : JSON.stringify(value);
    const seed = {headSha: process.env.HEAD_SHA.toLowerCase(), runId: process.env.RUN_ID};
    process.stdout.write(`team-review:v1:${crypto.createHash("sha256").update(canonical(seed)).digest("hex")}`);
  '
}

review_marker() {
  local operation_key="$1" head_sha="$2" payload_digest="$3" part_count="${4:-1}"
  OPERATION_KEY="$operation_key" HEAD_SHA="$head_sha" PAYLOAD_DIGEST="$payload_digest" \
    PART_COUNT="$part_count" node -e '
      const crypto = require("crypto");
      const opDigest = crypto.createHash("sha256").update(process.env.OPERATION_KEY).digest("hex");
      process.stdout.write(`<!-- zensu-review:v1:${opDigest}:${process.env.PAYLOAD_DIGEST}:${process.env.HEAD_SHA.toLowerCase()}:${process.env.PART_COUNT}:part=1/${process.env.PART_COUNT} -->`);
    '
}

apply() {
  autopilot_apply_event "$RUN" "$1" "$2" "$3" "$PROJECT" >/dev/null
}

if autopilot_begin_run "$RUN" "$OWNER" "$PROJECT" >/dev/null \
  && [ -f "$RUN_FILE" ] && [ -f "$ACTIVE_FILE" ] \
  && autopilot_read_active "$PROJECT" > "$ROOT/active-read.json" \
  && json_ok "$ROOT/active-read.json" 'value.schemaVersion === 1 && value.runId === "run_primary_001" && value.ownerSessionId === "session_owner_001" && value.stage === "PLANNING" && value.nextActionCode === "AWAIT_PLAN_APPROVAL" && value.stopBudget.stage === "PLANNING" && value.stopBudget.count === 0 && value.tdd.attempt === 0 && value.tdd.returnStage === null'; then
  check "B1 begin writes a valid project-local PLANNING state" PASS
else
  check "B1 begin writes a valid project-local PLANNING state" FAIL
fi

# Project root is asserted independently to keep json_ok intentionally tiny.
if node -e 'const j=require(process.argv[1]);process.exit(j.projectRoot===process.argv[2]?0:1)' "$RUN_FILE" "$PROJECT_PHYSICAL"; then
  check "B2 state binds the canonical project root" PASS
else
  check "B2 state binds the canonical project root" FAIL
fi

BEFORE_BEGIN="$(file_digest "$RUN_FILE")"
if autopilot_begin_run "$RUN" "$OWNER" "$PROJECT" >/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_BEGIN" ]; then
  check "B3 identical begin is a byte-stable no-op" PASS
else
  check "B3 identical begin is a byte-stable no-op" FAIL
fi

if ! autopilot_begin_run "run_competing_001" "session_owner_002" "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_BEGIN" ]; then
  check "B4 a live active run rejects a competing begin" PASS
else
  check "B4 a live active run rejects a competing begin" FAIL
fi

BEFORE_BAD_TRANSITION="$(file_digest "$RUN_FILE")"
if ! apply "evt_bad_001" "GATES_PASSED" "{\"headSha\":\"$HEAD_SHA\"}" 2>/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_BAD_TRANSITION" ]; then
  check "T1 the closed transition table rejects an event from the wrong stage" PASS
else
  check "T1 the closed transition table rejects an event from the wrong stage" FAIL
fi

if apply "evt_plan_001" "PLAN_APPROVED" "{\"approvedPlanSha256\":\"$PLAN_SHA\"}" \
  && json_ok "$RUN_FILE" 'value.stage === "AWAIT_TDD" && value.nextActionCode === "START_TDD" && value.approvedPlanSha256 === "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && value.tdd.returnStage === "GATES"'; then
  check "T2 plan approval enters AWAIT_TDD with a GATES return stage" PASS
else
  check "T2 plan approval enters AWAIT_TDD with a GATES return stage" FAIL
fi

if apply "evt_tdd_start_001" "TDD_STARTED" '{"attempt":1,"chainId":"chain-001","sessionId":"session-tdd-001"}' \
  && json_ok "$RUN_FILE" 'value.stage === "TDD_RUNNING" && value.tdd.attempt === 1 && value.tdd.chainId === "chain-001" && value.tdd.sessionId === "session-tdd-001" && value.tdd.returnStage === "GATES"'; then
  check "T3 TDD start binds the exact attempt, chain, session, and return stage" PASS
else
  check "T3 TDD start binds the exact attempt, chain, session, and return stage" FAIL
fi

BEFORE_WRONG_CHAIN="$(file_digest "$RUN_FILE")"
if ! apply "evt_tdd_done_wrong" "TDD_CHAIN_DONE" '{"attempt":1,"chainId":"chain-other","sessionId":"session-tdd-001","outcome":"pass"}' 2>/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_WRONG_CHAIN" ]; then
  check "T4 TDD completion rejects a stale or foreign chain" PASS
else
  check "T4 TDD completion rejects a stale or foreign chain" FAIL
fi

DONE_PAYLOAD='{"attempt":1,"chainId":"chain-001","sessionId":"session-tdd-001","outcome":"pass"}'
if apply "evt_tdd_done_001" "TDD_CHAIN_DONE" "$DONE_PAYLOAD" \
  && json_ok "$RUN_FILE" 'value.stage === "GATES" && value.nextActionCode === "RUN_GATES" && value.tdd.outcome === "pass" && value.stopBudget.stage === "GATES" && value.stopBudget.count === 0'; then
  check "T5 matching TDD completion returns to the recorded stage" PASS
else
  check "T5 matching TDD completion returns to the recorded stage" FAIL
fi

BEFORE_DUPLICATE="$(file_digest "$RUN_FILE")"
if apply "evt_tdd_done_001" "TDD_CHAIN_DONE" "$DONE_PAYLOAD" \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_DUPLICATE" ]; then
  check "I1 duplicate eventId plus payload digest is a byte-stable no-op" PASS
else
  check "I1 duplicate eventId plus payload digest is a byte-stable no-op" FAIL
fi

if ! apply "evt_tdd_done_001" "TDD_CHAIN_DONE" '{"attempt":1,"chainId":"chain-001","sessionId":"session-tdd-001","outcome":"no-changes"}' 2>/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_DUPLICATE" ]; then
  check "I2 duplicate eventId with a different payload is a conflict" PASS
else
  check "I2 duplicate eventId with a different payload is a conflict" FAIL
fi

if ! apply "evt_payload_extra" "GATES_PASSED" "{\"headSha\":\"$HEAD_SHA\",\"extra\":true}" 2>/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_DUPLICATE" ]; then
  check "I3 event payload schemas reject unknown fields without mutation" PASS
else
  check "I3 event payload schemas reject unknown fields without mutation" FAIL
fi

apply "evt_gates_001" "GATES_PASSED" "{\"headSha\":\"$HEAD_SHA\"}" || true
apply "evt_converge_001" "CONVERGENCE_PASSED" '{}' || true
apply "evt_pr_request_001" "PR_OPEN_REQUESTED" '{"operationKey":"pr:run_primary_001"}' || true
apply "evt_pr_open_001" "PR_OPENED" "{\"operationKey\":\"pr:run_primary_001\",\"pr\":{\"number\":712,\"url\":\"https://github.com/acme/repo/pull/712\",\"headSha\":\"$HEAD_SHA\"}}" || true
REVIEW_KEY="$(review_operation_key "$RUN" "$HEAD_SHA")"
if command -v autopilot_team_review_operation_key >/dev/null 2>&1 \
  && [ "$(autopilot_team_review_operation_key "$RUN" "$HEAD_SHA")" = "$REVIEW_KEY" ] \
  && [ "$(autopilot_team_review_operation_key "$RUN" "$HEAD_SHA_2")" != "$REVIEW_KEY" ]; then
  check "R1 team-review operation keys are deterministic functions of run plus original head" PASS
else
  check "R1 deterministic team-review operation key helper" FAIL
fi

BEFORE_REVIEW_REQUEST="$(file_digest "$RUN_FILE")"
WRONG_REVIEW_KEY="$(review_operation_key "$RUN" "$HEAD_SHA_2")"
if ! apply "evt_review_wrong_key" "TEAM_REVIEW_REQUESTED" \
    "{\"operationKey\":\"$WRONG_REVIEW_KEY\",\"provider\":\"github\"}" 2>/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_REVIEW_REQUEST" ]; then
  check "R2 TEAM_REVIEW_REQUESTED rejects a key not bound to this run and original PR head byte-stably" PASS
else
  check "R2 mismatched team-review operation key rejection" FAIL
fi
apply "evt_review_request_001" "TEAM_REVIEW_REQUESTED" \
  "{\"operationKey\":\"$REVIEW_KEY\",\"provider\":\"github\"}" || true

REVIEW_PAYLOAD_SOURCE="$ROOT/review-payload.json"
cat > "$REVIEW_PAYLOAD_SOURCE" <<JSON
{
  "comments": [{
    "path": "hooks/lib/example.sh",
    "line": 7,
    "side": "RIGHT",
    "body": "Durable inline finding"
  }],
  "body": "Durable review body",
  "event": "COMMENT",
  "commit_id": "$HEAD_SHA"
}
JSON

if ! autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" \
    >/dev/null 2>&1; then
  check "R3 review payload read reports an absent pre-publication snapshot" PASS
else
  check "R3 review payload read reports an absent pre-publication snapshot" FAIL
fi

REVIEW_PAYLOAD_SNAPSHOT="$(autopilot_store_team_review_payload \
  "$RUN" "$REVIEW_KEY" "$HEAD_SHA" "$REVIEW_PAYLOAD_SOURCE" github "$PROJECT" 2>/dev/null || true)"
if [ -n "$REVIEW_PAYLOAD_SNAPSHOT" ] \
  && [ "$(autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" 2>/dev/null)" = "$REVIEW_PAYLOAD_SNAPSHOT" ] \
  && cmp -s "$REVIEW_PAYLOAD_SOURCE" "$REVIEW_PAYLOAD_SNAPSHOT" \
  && private_mode_ok "$REVIEW_PAYLOAD_SNAPSHOT" \
  && [ "$(stat -c %h "$REVIEW_PAYLOAD_SNAPSHOT" 2>/dev/null || stat -f %l "$REVIEW_PAYLOAD_SNAPSHOT")" = 1 ]; then
  check "R4 requested review atomically stores one private operation/head-bound payload" PASS
else
  check "R4 requested review atomically stores one private operation/head-bound payload" FAIL
fi

REVIEW_VCS_META="$(_zensu_vcs_review_payload_meta github "$REVIEW_PAYLOAD_SNAPSHOT" "$HEAD_SHA" "$REVIEW_KEY" 2>/dev/null || true)"
REVIEW_PAYLOAD_DIGEST="$(printf '%s' "$REVIEW_VCS_META" | json_field_stdin payloadDigest 2>/dev/null || true)"
REVIEW_CANONICAL_DIGEST="$(_autopilot_team_review_payload_inspect \
  "$REVIEW_PAYLOAD_SNAPSHOT" "$HEAD_SHA" true canonical 2>/dev/null || true)"
REVIEW_RAW_DIGEST="$(file_digest "$REVIEW_PAYLOAD_SNAPSHOT" 2>/dev/null || true)"
REVIEW_MARKER="$(review_marker "$REVIEW_KEY" "$HEAD_SHA" "$REVIEW_PAYLOAD_DIGEST" 1)"
if [ -n "$REVIEW_CANONICAL_DIGEST" ] \
  && [ "$REVIEW_CANONICAL_DIGEST" = "$REVIEW_PAYLOAD_DIGEST" ] \
  && [ "$REVIEW_CANONICAL_DIGEST" != "$REVIEW_RAW_DIGEST" ]; then
  check "R4a durable payload inspection uses the same canonical digest as remote publication" PASS
else
  check "R4a canonical receipt digest parity with the VCS publisher" FAIL
fi

# This is the crash window: the remote write may already have succeeded while
# TEAM_REVIEW_PUBLISHED is not durable yet. A resumed skill must load the exact
# immutable snapshot instead of synthesizing a second payload.
REVIEW_SNAPSHOT_DIGEST="$(file_digest "$REVIEW_PAYLOAD_SNAPSHOT" 2>/dev/null || true)"
printf '%s\n' "{\"commit_id\":\"$HEAD_SHA\",\"event\":\"COMMENT\",\"body\":\"Regenerated and different\",\"comments\":[]}" > "$REVIEW_PAYLOAD_SOURCE"
if [ "$(autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" 2>/dev/null)" = "$REVIEW_PAYLOAD_SNAPSHOT" ] \
  && ! autopilot_store_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" \
      "$REVIEW_PAYLOAD_SOURCE" github "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$REVIEW_PAYLOAD_SNAPSHOT" 2>/dev/null)" = "$REVIEW_SNAPSHOT_DIGEST" ] \
  && grep -qF 'Durable review body' "$REVIEW_PAYLOAD_SNAPSHOT" \
  && ! grep -qF 'Regenerated and different' "$REVIEW_PAYLOAD_SNAPSHOT"; then
  check "R5 crash retry reuses the byte-identical snapshot and rejects overwrite conflict" PASS
else
  check "R5 crash retry reuses the byte-identical snapshot and rejects overwrite conflict" FAIL
fi

# link(2) publishes the complete temp inode without replacement. A kill in the
# tiny window before unlink(temp) leaves exactly the target plus its own
# `${target}.tmp.XXXXXXXX` alias. A prior kill before link(temp,target) can also
# leave a separate same-prefix temp inode; recovery must preserve that orphan
# while accounting for and removing the one true target alias.
UNRELATED_REVIEW_TEMP="$(mktemp "${REVIEW_PAYLOAD_SNAPSHOT}.tmp.XXXXXXXX")"
cp "$REVIEW_PAYLOAD_SNAPSHOT" "$UNRELATED_REVIEW_TEMP"
OWNED_REVIEW_TEMP="$(mktemp "${REVIEW_PAYLOAD_SNAPSHOT}.tmp.XXXXXXXX")"
rm -f "$OWNED_REVIEW_TEMP"
ln "$REVIEW_PAYLOAD_SNAPSHOT" "$OWNED_REVIEW_TEMP"
if [ "$(autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" 2>/dev/null)" = "$REVIEW_PAYLOAD_SNAPSHOT" ] \
  && [ ! -e "$OWNED_REVIEW_TEMP" ] \
  && [ -f "$UNRELATED_REVIEW_TEMP" ] \
  && [ "$(stat -c %h "$UNRELATED_REVIEW_TEMP" 2>/dev/null || stat -f %l "$UNRELATED_REVIEW_TEMP")" = 1 ] \
  && [ "$(stat -c %h "$REVIEW_PAYLOAD_SNAPSHOT" 2>/dev/null || stat -f %l "$REVIEW_PAYLOAD_SNAPSHOT")" = 1 ]; then
  check "R5a resume heals the real owned alias while preserving an unrelated pre-link temp orphan" PASS
else
  check "R5a resume heals the real owned alias while preserving an unrelated pre-link temp orphan" FAIL
fi
rm -f "$OWNED_REVIEW_TEMP" "$UNRELATED_REVIEW_TEMP"

MULTI_REVIEW_TEMP_A="$(mktemp "${REVIEW_PAYLOAD_SNAPSHOT}.tmp.XXXXXXXX")"
MULTI_REVIEW_TEMP_B="$(mktemp "${REVIEW_PAYLOAD_SNAPSHOT}.tmp.XXXXXXXX")"
rm -f "$MULTI_REVIEW_TEMP_A" "$MULTI_REVIEW_TEMP_B"
ln "$REVIEW_PAYLOAD_SNAPSHOT" "$MULTI_REVIEW_TEMP_A"
ln "$REVIEW_PAYLOAD_SNAPSHOT" "$MULTI_REVIEW_TEMP_B"
if ! autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" \
    >/dev/null 2>&1 \
  && [ -e "$MULTI_REVIEW_TEMP_A" ] && [ -e "$MULTI_REVIEW_TEMP_B" ] \
  && [ "$(stat -c %h "$REVIEW_PAYLOAD_SNAPSHOT" 2>/dev/null || stat -f %l "$REVIEW_PAYLOAD_SNAPSHOT")" = 3 ]; then
  check "R5b multiple owned-looking aliases remain fail-closed and untouched" PASS
else
  check "R5b multiple owned-looking aliases remain fail-closed and untouched" FAIL
fi
rm -f "$MULTI_REVIEW_TEMP_A" "$MULTI_REVIEW_TEMP_B"

if autopilot_read_team_review_payload "$RUN" "$WRONG_REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" \
    >/dev/null 2>&1 \
  || autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA_2" github "$PROJECT" \
    >/dev/null 2>&1; then
  check "R6 payload snapshots reject operation/head identity mismatches" FAIL
else
  check "R6 payload snapshots reject operation/head identity mismatches" PASS
fi

REVIEW_PAYLOAD_BACKUP="$ROOT/review-payload-backup.json"
REVIEW_LINK_GUARDS=false
if [ -n "$REVIEW_PAYLOAD_SNAPSHOT" ] \
  && cp "$REVIEW_PAYLOAD_SNAPSHOT" "$REVIEW_PAYLOAD_BACKUP" \
  && rm -f "$REVIEW_PAYLOAD_SNAPSHOT"; then
  if make_file_symlink "$REVIEW_PAYLOAD_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"; then
    if autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" \
        >/dev/null 2>&1; then
      REVIEW_LINK_GUARDS=false
    else
      REVIEW_LINK_GUARDS=true
    fi
  elif [ "$IS_WINDOWS" = true ]; then
    REVIEW_LINK_GUARDS=true
  fi
  rm -f "$REVIEW_PAYLOAD_SNAPSHOT"
  if ! ln "$REVIEW_PAYLOAD_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT" \
    || autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" \
      >/dev/null 2>&1; then
    REVIEW_LINK_GUARDS=false
  fi
  rm -f "$REVIEW_PAYLOAD_SNAPSHOT"
  mv "$REVIEW_PAYLOAD_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"
fi
if [ -n "$REVIEW_PAYLOAD_SNAPSHOT" ] \
  && [ "$REVIEW_LINK_GUARDS" = true ] \
  && [ "$(autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" github "$PROJECT" 2>/dev/null)" = "$REVIEW_PAYLOAD_SNAPSHOT" ]; then
  check "R7 payload snapshot reads fail closed on symlink and hardlink substitution" PASS
else
  check "R7 payload snapshot reads fail closed on symlink and hardlink substitution" FAIL
fi

receipt_rejected_byte_stably() {
  local event_id="$1" marker="$2" provider="${3:-github}" before backup accepted=false
  backup="$ROOT/${event_id}-run-backup.json"
  cp "$RUN_FILE" "$backup" || return 1
  before="$(file_digest "$RUN_FILE")"
  if apply "$event_id" TEAM_REVIEW_PUBLISHED \
      "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$marker\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"$provider\"}" \
      >/dev/null 2>&1; then
    accepted=true
  fi
  local unchanged=false
  [ "$(file_digest "$RUN_FILE")" = "$before" ] && unchanged=true
  cp "$backup" "$RUN_FILE"
  [ "$accepted" = false ] && [ "$unchanged" = true ]
}

UNRELATED_PAYLOAD_DIGEST="$(printf '%064d' 0)"
[ "$UNRELATED_PAYLOAD_DIGEST" != "$REVIEW_PAYLOAD_DIGEST" ] || UNRELATED_PAYLOAD_DIGEST="$(printf '%064d' 1)"
UNRELATED_PAYLOAD_MARKER="$(review_marker "$REVIEW_KEY" "$HEAD_SHA" "$UNRELATED_PAYLOAD_DIGEST" 1)"
if receipt_rejected_byte_stably evt_review_unrelated_payload "$UNRELATED_PAYLOAD_MARKER"; then
  check "R7a publication rejects a receipt digest unrelated to the durable payload" PASS
else
  check "R7a publication digest is not bound to the durable payload" FAIL
fi

# The same immutable payload has one GitHub review object but two GitLab
# publication parts (summary plus one inline discussion). A caller cannot
# relabel the valid 1/1 GitHub marker as a GitLab receipt and skip that part.
if receipt_rejected_byte_stably evt_review_wrong_provider_count "$REVIEW_MARKER" gitlab; then
  check "R7aa publication provider must match the durable review request" PASS
else
  check "R7aa publication can relabel a GitHub request as GitLab" FAIL
fi

# Build a complete requested-state clone, including its private durable
# payload, so provider tests cannot pass merely because attestation later finds
# a missing snapshot.
prepare_provider_project() {
  local target="$1" provider="$2" state_dir="$1/.zensu/state" run_file source physical
  run_file="$state_dir/autopilot-run-${RUN}.json"
  mkdir -p "$state_dir" || return 1
  cp "$ACTIVE_FILE" "$state_dir/autopilot-active.json" || return 1
  cp "$RUN_FILE" "$run_file" || return 1
  physical="$(cd "$target" && pwd -P)" || return 1
  PROJECT_PHYSICAL="$physical" REQUEST_PROVIDER="$provider" node -e '
  const fs=require("fs"),crypto=require("crypto"),file=process.argv[1],state=JSON.parse(fs.readFileSync(file,"utf8"));
  const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(",")}]`:
    value&&typeof value==="object"?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`:
    JSON.stringify(value);
  state.projectRoot=process.env.PROJECT_PHYSICAL;
  state.effects.teamReview.provider=process.env.REQUEST_PROVIDER;
  const event=state.events.find(item=>item.eventType==="TEAM_REVIEW_REQUESTED");
  event.payload.provider=process.env.REQUEST_PROVIDER;
  event.payloadDigest=crypto.createHash("sha256").update(canonical(event.payload)).digest("hex");
  fs.writeFileSync(file,JSON.stringify(state,null,2)+"\n");
' "$run_file" || return 1
  source="$target/provider-review-source.json"
  cp "$REVIEW_PAYLOAD_SNAPSHOT" "$source" || return 1
  chmod 600 "$source" || return 1
  autopilot_store_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" \
    "$source" "$provider" "$target" >/dev/null
}

# A genuinely GitLab-bound request with one inline finding has a valid two-part
# receipt. This control proves the cloned state and snapshot are complete.
GITLAB_CONTROL_PROJECT="$ROOT/gitlab-provider-control"
GITLAB_MARKER="$(review_marker "$REVIEW_KEY" "$HEAD_SHA" "$REVIEW_PAYLOAD_DIGEST" 2)"
GITLAB_CONTROL_OK=false
if prepare_provider_project "$GITLAB_CONTROL_PROJECT" gitlab \
  && autopilot_apply_event "$RUN" evt_review_gitlab_valid TEAM_REVIEW_PUBLISHED \
    "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$GITLAB_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"gitlab\"}" \
    "$GITLAB_CONTROL_PROJECT" >/dev/null 2>&1 \
  && autopilot_read_run "$RUN" "$GITLAB_CONTROL_PROJECT" > "$ROOT/gitlab-provider-control.json" 2>/dev/null \
  && json_ok "$ROOT/gitlab-provider-control.json" \
    'value.stage === "FIX_FINDINGS" && value.effects.teamReview.provider === "gitlab" && value.evidence.review.provider === "gitlab" && value.evidence.review.partCount === 2'; then
  GITLAB_CONTROL_OK=true
fi
if [ "$GITLAB_CONTROL_OK" = true ]; then
  check "R7ab exact provider binding accepts a complete two-part GitLab receipt" PASS
else
  check "R7ab exact provider binding rejects its valid GitLab control" FAIL
fi

# The byte-identical requested state and payload cannot be relabeled as a
# one-part GitHub publication.
GITLAB_SPOOF_PROJECT="$ROOT/gitlab-provider-spoof"
GITLAB_SPOOF_FILE="$GITLAB_SPOOF_PROJECT/.zensu/state/autopilot-run-${RUN}.json"
GITLAB_SPOOF_READY=false
if prepare_provider_project "$GITLAB_SPOOF_PROJECT" gitlab \
  && autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" \
    gitlab "$GITLAB_SPOOF_PROJECT" >/dev/null 2>&1 \
  && ! autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_SHA" \
    github "$GITLAB_SPOOF_PROJECT" >/dev/null 2>&1; then
  GITLAB_SPOOF_READY=true
fi
GITLAB_BEFORE="$(file_digest "$GITLAB_SPOOF_FILE" 2>/dev/null || true)"
if [ "$GITLAB_SPOOF_READY" = true ] \
  && ! autopilot_apply_event "$RUN" evt_review_gitlab_as_github TEAM_REVIEW_PUBLISHED \
    "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" \
    "$GITLAB_SPOOF_PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$GITLAB_SPOOF_FILE")" = "$GITLAB_BEFORE" ]; then
  check "R7ac GitLab request cannot be relabeled as a one-part GitHub receipt" PASS
else
  check "R7ac caller-selected GitHub count bypasses a complete GitLab request" FAIL
fi

# Deployed v1 completed receipts remain readable below, but an in-flight v1
# request never had a trusted provider. It must fail closed instead of learning
# the forge from a new publication event.
LEGACY_REQUEST_PROJECT="$ROOT/legacy-requested-providerless"
LEGACY_REQUEST_FILE="$LEGACY_REQUEST_PROJECT/.zensu/state/autopilot-run-${RUN}.json"
LEGACY_REQUEST_READY=false
if prepare_provider_project "$LEGACY_REQUEST_PROJECT" github; then
  node -e '
    const fs=require("fs"),crypto=require("crypto"),file=process.argv[1],state=JSON.parse(fs.readFileSync(file,"utf8"));
    const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(",")}]`:
      value&&typeof value==="object"?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`:
      JSON.stringify(value);
    delete state.effects.teamReview.provider;
    const event=state.events.find(item=>item.eventType==="TEAM_REVIEW_REQUESTED");
    delete event.payload.provider;
    event.payloadDigest=crypto.createHash("sha256").update(canonical(event.payload)).digest("hex");
    fs.writeFileSync(file,JSON.stringify(state,null,2)+"\n");
  ' "$LEGACY_REQUEST_FILE" && LEGACY_REQUEST_READY=true
fi
LEGACY_REQUEST_BEFORE="$(file_digest "$LEGACY_REQUEST_FILE" 2>/dev/null || true)"
if [ "$LEGACY_REQUEST_READY" = true ] \
  && ! autopilot_apply_event "$RUN" evt_legacy_request_provider_choice TEAM_REVIEW_PUBLISHED \
    "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" \
    "$LEGACY_REQUEST_PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$LEGACY_REQUEST_FILE")" = "$LEGACY_REQUEST_BEFORE" ]; then
  check "R7ad providerless in-flight v1 request fails closed without learning a forge" PASS
else
  check "R7ad providerless in-flight v1 request adopted the publication provider" FAIL
fi

RECEIPT_GUARDS=true
RECEIPT_BACKUP="$ROOT/receipt-payload-backup.json"
mv "$REVIEW_PAYLOAD_SNAPSHOT" "$RECEIPT_BACKUP"
receipt_rejected_byte_stably evt_review_missing_payload "$REVIEW_MARKER" || RECEIPT_GUARDS=false
mv "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"

mv "$REVIEW_PAYLOAD_SNAPSHOT" "$RECEIPT_BACKUP"
if make_file_symlink "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"; then
  receipt_rejected_byte_stably evt_review_symlink_payload "$REVIEW_MARKER" || RECEIPT_GUARDS=false
elif [ "$IS_WINDOWS" != true ]; then
  RECEIPT_GUARDS=false
fi
rm -f "$REVIEW_PAYLOAD_SNAPSHOT"
mv "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"

cp "$REVIEW_PAYLOAD_SNAPSHOT" "$RECEIPT_BACKUP"
rm -f "$REVIEW_PAYLOAD_SNAPSHOT"
ln "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"
receipt_rejected_byte_stably evt_review_hardlink_payload "$REVIEW_MARKER" || RECEIPT_GUARDS=false
rm -f "$REVIEW_PAYLOAD_SNAPSHOT"
mv "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"

mv "$REVIEW_PAYLOAD_SNAPSHOT" "$RECEIPT_BACKUP"
printf '%s\n' "{\"commit_id\":\"$HEAD_SHA_2\",\"event\":\"COMMENT\",\"body\":\"stale\",\"comments\":[]}" > "$REVIEW_PAYLOAD_SNAPSHOT"
chmod 600 "$REVIEW_PAYLOAD_SNAPSHOT"
receipt_rejected_byte_stably evt_review_stale_payload "$REVIEW_MARKER" || RECEIPT_GUARDS=false
rm -f "$REVIEW_PAYLOAD_SNAPSHOT"
mv "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"
if [ "$RECEIPT_GUARDS" = true ]; then
  check "R7b publication rejects missing, linked, and stale-head payload snapshots byte-stably" PASS
else
  check "R7b unsafe or stale receipt payload snapshots reached durable state" FAIL
fi

BEFORE_REVIEW_PUBLISH="$(file_digest "$RUN_FILE")"
WRONG_OP_MARKER="$(review_marker "$WRONG_REVIEW_KEY" "$HEAD_SHA" "$REVIEW_PAYLOAD_DIGEST" 1)"
WRONG_HEAD_MARKER="$(review_marker "$REVIEW_KEY" "$HEAD_SHA_2" "$REVIEW_PAYLOAD_DIGEST" 1)"
BAD_PART_MARKER="${REVIEW_MARKER%part=1/1 -->}part=2/2 -->"
BAD_COUNT_MARKER="${REVIEW_MARKER%:1:part=1/1 -->}:2:part=1/3 -->"
REVIEW_REJECTIONS=true
if apply "evt_review_bad_operation" TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$WRONG_REVIEW_KEY\",\"marker\":\"$WRONG_OP_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" >/dev/null 2>&1; then REVIEW_REJECTIONS=false; fi
if apply "evt_review_legacy_marker" TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"zensu-autopilot-review:legacy\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" >/dev/null 2>&1; then REVIEW_REJECTIONS=false; fi
if apply "evt_review_wrong_op_digest" TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$WRONG_OP_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" >/dev/null 2>&1; then REVIEW_REJECTIONS=false; fi
if apply "evt_review_wrong_marker_head" TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$WRONG_HEAD_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" >/dev/null 2>&1; then REVIEW_REJECTIONS=false; fi
if apply "evt_review_nonfirst_part" TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$BAD_PART_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" >/dev/null 2>&1; then REVIEW_REJECTIONS=false; fi
if apply "evt_review_part_count_mismatch" TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$BAD_COUNT_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" >/dev/null 2>&1; then REVIEW_REJECTIONS=false; fi
if [ "$REVIEW_REJECTIONS" = true ] \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_REVIEW_PUBLISH" ]; then
  check "R8 publication requires one exact v1 part-1 marker bound to operation and head, byte-stably" PASS
else
  check "R8 strict structured team-review marker validation" FAIL
fi
apply "evt_review_publish_001" "TEAM_REVIEW_PUBLISHED" \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" || true

# Compatibility fixture for the schemaVersion 1 state emitted by PR #174:
# its publication event had no provider and evidence.review had only three
# fields. The reader must normalize it from the marker, and the next ordinary
# mutation must persist the normalized shape without rewriting history.
LEGACY_PROJECT="$ROOT/legacy-v1-project"
LEGACY_STATE_DIR="$LEGACY_PROJECT/.zensu/state"
LEGACY_RUN_FILE="$LEGACY_STATE_DIR/autopilot-run-${RUN}.json"
mkdir -p "$LEGACY_STATE_DIR"
cp "$ACTIVE_FILE" "$LEGACY_STATE_DIR/autopilot-active.json"
cp "$RUN_FILE" "$LEGACY_RUN_FILE"
LEGACY_PROJECT_PHYSICAL="$(cd "$LEGACY_PROJECT" && pwd -P)"
LEGACY_PROJECT_PHYSICAL="$LEGACY_PROJECT_PHYSICAL" node -e '
  const fs=require("fs"),crypto=require("crypto"),file=process.argv[1],state=JSON.parse(fs.readFileSync(file,"utf8"));
  const canonical=value=>Array.isArray(value)?`[${value.map(canonical).join(",")}]`:
    value&&typeof value==="object"?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`:
    JSON.stringify(value);
  state.projectRoot=process.env.LEGACY_PROJECT_PHYSICAL;
  const review=state.evidence.review;
  state.evidence.review={published:review.published,marker:review.marker,headSha:review.headSha};
  delete state.effects.teamReview.provider;
  const request=state.events.find(item=>item.eventType==="TEAM_REVIEW_REQUESTED");
  delete request.payload.provider;
  request.payloadDigest=crypto.createHash("sha256").update(canonical(request.payload)).digest("hex");
  const event=state.events.find(item=>item.eventType==="TEAM_REVIEW_PUBLISHED");
  delete event.payload.provider;
  event.payloadDigest=crypto.createHash("sha256").update(canonical(event.payload)).digest("hex");
  fs.writeFileSync(file,JSON.stringify(state,null,2)+"\n");
' "$LEGACY_RUN_FILE"
LEGACY_READ="$ROOT/legacy-v1-read.json"
LEGACY_OK=true
autopilot_read_run "$RUN" "$LEGACY_PROJECT" > "$LEGACY_READ" 2>/dev/null || LEGACY_OK=false
LEGACY_BEFORE_REPLAY="$(file_digest "$LEGACY_RUN_FILE")"
autopilot_apply_event "$RUN" evt_review_publish_001 TEAM_REVIEW_PUBLISHED \
  "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\"}" \
  "$LEGACY_PROJECT" >/dev/null 2>&1 || LEGACY_OK=false
[ "$(file_digest "$LEGACY_RUN_FILE")" = "$LEGACY_BEFORE_REPLAY" ] || LEGACY_OK=false
autopilot_apply_event "$RUN" legacy-review-normalized BYPASS_RECORDED \
  '{"gate":"legacy-review-migration"}' "$LEGACY_PROJECT" >/dev/null 2>&1 || LEGACY_OK=false
if [ "$LEGACY_OK" = true ] \
  && json_ok "$LEGACY_READ" 'value.evidence.review.provider === null && value.evidence.review.payloadDigest === value.evidence.review.marker.split(":")[3] && value.evidence.review.partCount === 1' \
  && json_ok "$LEGACY_RUN_FILE" 'value.schemaVersion === 1 && value.evidence.review.provider === null && value.evidence.review.payloadDigest === value.evidence.review.marker.split(":")[3] && value.evidence.review.partCount === 1 && value.events.some(event => event.eventId === "legacy-review-normalized")'; then
  check "R8a legacy schemaVersion 1 review receipt replays, normalizes, and persists safely" PASS
else
  check "R8a legacy review evidence becomes corrupt under the current reader" FAIL
fi
AFTER_REVIEW_PUBLISH="$(file_digest "$RUN_FILE")"
mv "$REVIEW_PAYLOAD_SNAPSHOT" "$RECEIPT_BACKUP"
if apply "evt_review_publish_001" "TEAM_REVIEW_PUBLISHED" \
    "{\"operationKey\":\"$REVIEW_KEY\",\"marker\":\"$REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}" \
    && [ "$(file_digest "$RUN_FILE")" = "$AFTER_REVIEW_PUBLISH" ]; then
  check "R9 exact publication replay stays byte-stable after the snapshot is unavailable" PASS
else
  check "R9 duplicate publication replay incorrectly re-attests an advanced stage" FAIL
fi
mv "$RECEIPT_BACKUP" "$REVIEW_PAYLOAD_SNAPSHOT"
apply "evt_findings_clear_001" "FINDINGS_CLEARED" "{\"headSha\":\"$HEAD_SHA\",\"unresolvedCount\":0}" || true
apply "evt_validate_001" "VALIDATION_PASSED" "{\"headSha\":\"$HEAD_SHA\"}" || true

if autopilot_read_active "$PROJECT" > "$ROOT/review-status.json" \
  && json_ok "$ROOT/review-status.json" 'value.runId === "run_primary_001" && value.ownerSessionId === "session_owner_001" && value.stage === "DELIVER" && value.nextActionCode === "DELIVER_PR" && value.tdd.attempt === 1 && value.tdd.returnStage === "GATES" && value.effects.prOpen.status === "completed" && value.effects.teamReview.status === "completed" && value.effects.teamReview.operationKey.startsWith("team-review:v1:") && value.evidence.pr.headSha === "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" && value.evidence.review.marker.startsWith("<!-- zensu-review:v1:") && value.evidence.review.headSha === value.evidence.pr.headSha && value.evidence.review.payloadDigest === value.evidence.review.marker.split(":")[3] && value.evidence.review.partCount === 1 && value.evidence.review.provider === "github" && value.evidence.gates.passed === true && value.evidence.validation.passed === true'; then
  check "T6 happy path reaches DELIVER with durable evidence" PASS
else
  check "T6 happy path reaches DELIVER with durable evidence" FAIL
fi

cp "$RUN_FILE" "$ROOT/pre-invariant.json"
node -e 'const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p));j.effects.teamReview={status:"none",operationKey:null};fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n");' "$RUN_FILE"
BEFORE_INVARIANT="$(file_digest "$RUN_FILE")"
if ! apply "evt_deliver_invalid" "DELIVERY_COMPLETE" "{\"headSha\":\"$HEAD_SHA\"}" 2>/dev/null \
  && [ "$(file_digest "$RUN_FILE")" = "$BEFORE_INVARIANT" ]; then
  check "T7 DONE is denied until every delivery invariant is present" PASS
else
  check "T7 DONE is denied until every delivery invariant is present" FAIL
fi
cp "$ROOT/pre-invariant.json" "$RUN_FILE"

if apply "evt_deliver_001" "DELIVERY_COMPLETE" "{\"headSha\":\"$HEAD_SHA\"}" \
  && json_ok "$RUN_FILE" 'value.stage === "DONE" && value.nextActionCode === "NONE" && value.stopBudget.stage === "DONE" && value.stopBudget.count === 0'; then
  check "T8 delivery closes only as terminal DONE" PASS
else
  check "T8 delivery closes only as terminal DONE" FAIL
fi

# Exercise every fix-loop return target with one monotonically increasing TDD
# attempt sequence. This catches accidental "continue to the next stage" logic.
LOOP_RUN="run_return_stages_002"
LOOP_OWNER="session_return_stages_002"
LOOP_FILE="$PROJECT/.zensu/state/autopilot-run-${LOOP_RUN}.json"
LOOP_OK=true
loop_event() {
  autopilot_apply_event "$LOOP_RUN" "$1" "$2" "$3" "$PROJECT" >/dev/null || LOOP_OK=false
}
loop_tdd() {
  local attempt="$1" chain="loop-chain-$1"
  loop_event "loop-tdd-start-$attempt" TDD_STARTED \
    "{\"attempt\":$attempt,\"chainId\":\"$chain\",\"sessionId\":\"$LOOP_OWNER\"}"
  loop_event "loop-tdd-done-$attempt" TDD_CHAIN_DONE \
    "{\"attempt\":$attempt,\"chainId\":\"$chain\",\"sessionId\":\"$LOOP_OWNER\",\"outcome\":\"pass\"}"
}

autopilot_begin_run "$LOOP_RUN" "$LOOP_OWNER" "$PROJECT" true true >/dev/null || LOOP_OK=false
loop_event loop-plan PLAN_APPROVED "{\"approvedPlanSha256\":\"$PLAN_SHA\"}"
loop_tdd 1
loop_event loop-gates-fail GATES_FAILED "{\"headSha\":\"$HEAD_SHA\",\"reason\":\"quality gate failed\"}"
json_ok "$LOOP_FILE" 'value.stage === "AWAIT_TDD" && value.tdd.returnStage === "GATES"' || LOOP_OK=false
loop_tdd 2
loop_event loop-gates-pass GATES_PASSED "{\"headSha\":\"$HEAD_SHA\"}"
loop_event loop-converge-fail CONVERGENCE_FAILED '{"reason":"convergence check failed","limitReached":false}'
json_ok "$LOOP_FILE" 'value.stage === "AWAIT_TDD" && value.tdd.returnStage === "CONVERGE"' || LOOP_OK=false
loop_tdd 3
loop_event loop-converge-pass CONVERGENCE_PASSED '{}'
loop_event loop-pr-request PR_OPEN_REQUESTED '{"operationKey":"pr:return-stages"}'
loop_event loop-pr-open PR_OPENED "{\"operationKey\":\"pr:return-stages\",\"pr\":{\"number\":713,\"url\":\"https://github.com/acme/repo/pull/713\",\"headSha\":\"$HEAD_SHA\"}}"
LOOP_REVIEW_KEY="$(review_operation_key "$LOOP_RUN" "$HEAD_SHA")"
loop_event loop-review-request TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$LOOP_REVIEW_KEY\",\"provider\":\"github\"}"
LOOP_REVIEW_PAYLOAD="$ROOT/loop-review-payload.json"
printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Loop review\",\"commit_id\":\"$HEAD_SHA\",\"comments\":[]}" > "$LOOP_REVIEW_PAYLOAD"
autopilot_store_team_review_payload "$LOOP_RUN" "$LOOP_REVIEW_KEY" "$HEAD_SHA" \
  "$LOOP_REVIEW_PAYLOAD" github "$PROJECT" >/dev/null || LOOP_OK=false
LOOP_REVIEW_META="$(_zensu_vcs_review_payload_meta github "$LOOP_REVIEW_PAYLOAD" "$HEAD_SHA" "$LOOP_REVIEW_KEY" 2>/dev/null || true)"
LOOP_REVIEW_DIGEST="$(printf '%s' "$LOOP_REVIEW_META" | json_field_stdin payloadDigest 2>/dev/null || true)"
LOOP_REVIEW_MARKER="$(review_marker "$LOOP_REVIEW_KEY" "$HEAD_SHA" "$LOOP_REVIEW_DIGEST" 1)"
loop_event loop-review-published TEAM_REVIEW_PUBLISHED "{\"operationKey\":\"$LOOP_REVIEW_KEY\",\"marker\":\"$LOOP_REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}"
loop_event loop-fix-required FIX_REQUIRED "{\"headSha\":\"$HEAD_SHA\",\"unresolvedCount\":2}"
json_ok "$LOOP_FILE" 'value.stage === "AWAIT_TDD" && value.tdd.returnStage === "FIX_FINDINGS"' || LOOP_OK=false
loop_tdd 4

BEFORE_REQUIRED_HEAD_UPDATE="$(file_digest "$LOOP_FILE")"
if ! autopilot_apply_event "$LOOP_RUN" loop-stale-findings-clear FINDINGS_CLEARED \
  "{\"headSha\":\"$HEAD_SHA\",\"unresolvedCount\":0}" "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$LOOP_FILE")" = "$BEFORE_REQUIRED_HEAD_UPDATE" ]; then
  check "H1 a successful findings fix cannot reuse evidence from the pre-fix head" PASS
else
  check "H1 a successful findings fix cannot reuse evidence from the pre-fix head" FAIL
  LOOP_OK=false
fi

INVALID_HEAD_UPDATES=true
if autopilot_apply_event "$LOOP_RUN" loop-head-extra PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA\",\"headSha\":\"$HEAD_SHA_2\",\"gatesPassed\":true,\"pushCompleted\":true,\"extra\":true}" "$PROJECT" >/dev/null 2>&1; then
  INVALID_HEAD_UPDATES=false
fi
if autopilot_apply_event "$LOOP_RUN" loop-head-unchanged PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA\",\"headSha\":\"$HEAD_SHA\",\"gatesPassed\":true,\"pushCompleted\":true}" "$PROJECT" >/dev/null 2>&1; then
  INVALID_HEAD_UPDATES=false
fi
if autopilot_apply_event "$LOOP_RUN" loop-head-stale PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA_2\",\"headSha\":\"$HEAD_SHA_3\",\"gatesPassed\":true,\"pushCompleted\":true}" "$PROJECT" >/dev/null 2>&1; then
  INVALID_HEAD_UPDATES=false
fi
if autopilot_apply_event "$LOOP_RUN" loop-head-no-gates PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA\",\"headSha\":\"$HEAD_SHA_2\",\"gatesPassed\":false,\"pushCompleted\":true}" "$PROJECT" >/dev/null 2>&1; then
  INVALID_HEAD_UPDATES=false
fi
if autopilot_apply_event "$LOOP_RUN" loop-head-no-push PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA\",\"headSha\":\"$HEAD_SHA_2\",\"gatesPassed\":true,\"pushCompleted\":false}" "$PROJECT" >/dev/null 2>&1; then
  INVALID_HEAD_UPDATES=false
fi
if [ "$INVALID_HEAD_UPDATES" = true ] \
  && [ "$(file_digest "$LOOP_FILE")" = "$BEFORE_REQUIRED_HEAD_UPDATE" ]; then
  check "H2 head updates reject unknown, unchanged, stale, ungated, and unpushed payloads" PASS
else
  check "H2 head updates reject unknown, unchanged, stale, ungated, and unpushed payloads" FAIL
  LOOP_OK=false
fi

loop_event loop-head-findings PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA\",\"headSha\":\"$HEAD_SHA_2\",\"gatesPassed\":true,\"pushCompleted\":true}"
if json_ok "$LOOP_FILE" 'value.stage === "FIX_FINDINGS" && value.tdd.headUpdateRequired === false && value.evidence.pr.headSha === "cccccccccccccccccccccccccccccccccccccccc" && value.evidence.gates.passed === true && value.evidence.gates.headSha === "cccccccccccccccccccccccccccccccccccccccc" && value.evidence.review.headSha === "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" && value.evidence.findings === null && value.evidence.validation === null && value.evidence.coverage === null && value.evidence.delivery === null'; then
  check "H3 a findings fix advances the current PR head while preserving the once-only review" PASS
else
  check "H3 a findings fix advances the current PR head while preserving the once-only review" FAIL
  LOOP_OK=false
fi

loop_event loop-findings-clear FINDINGS_CLEARED "{\"headSha\":\"$HEAD_SHA_2\",\"unresolvedCount\":0}"
loop_event loop-validation-fail VALIDATION_FAILED "{\"headSha\":\"$HEAD_SHA_2\",\"reason\":\"acceptance criterion failed\"}"
json_ok "$LOOP_FILE" 'value.stage === "AWAIT_TDD" && value.tdd.returnStage === "VALIDATE"' || LOOP_OK=false
loop_tdd 5

BEFORE_VALIDATION_HEAD_UPDATE="$(file_digest "$LOOP_FILE")"
if ! autopilot_apply_event "$LOOP_RUN" loop-stale-validation-pass VALIDATION_PASSED \
  "{\"headSha\":\"$HEAD_SHA_2\"}" "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$LOOP_FILE")" = "$BEFORE_VALIDATION_HEAD_UPDATE" ]; then
  check "H4 a validation fix requires a pushed, gated head update before revalidation" PASS
else
  check "H4 a validation fix requires a pushed, gated head update before revalidation" FAIL
  LOOP_OK=false
fi

loop_event loop-head-validation PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA_2\",\"headSha\":\"$HEAD_SHA_3\",\"gatesPassed\":true,\"pushCompleted\":true}"
json_ok "$LOOP_FILE" 'value.stage === "FIX_FINDINGS" && value.evidence.pr.headSha === "dddddddddddddddddddddddddddddddddddddddd" && value.evidence.gates.headSha === "dddddddddddddddddddddddddddddddddddddddd" && value.evidence.findings === null && value.evidence.validation === null' || LOOP_OK=false
loop_event loop-findings-clear-after-validation FINDINGS_CLEARED "{\"headSha\":\"$HEAD_SHA_3\",\"unresolvedCount\":0}"
loop_event loop-validation-pass VALIDATION_PASSED "{\"headSha\":\"$HEAD_SHA_3\"}"
loop_event loop-coverage-fail COVERAGE_FAILED "{\"headSha\":\"$HEAD_SHA_3\",\"reason\":\"coverage threshold failed\"}"
json_ok "$LOOP_FILE" 'value.stage === "AWAIT_TDD" && value.tdd.returnStage === "COVER"' || LOOP_OK=false
loop_tdd 6

loop_event loop-head-coverage PR_HEAD_UPDATED \
  "{\"previousHeadSha\":\"$HEAD_SHA_3\",\"headSha\":\"$HEAD_SHA_4\",\"gatesPassed\":true,\"pushCompleted\":true}"
if json_ok "$LOOP_FILE" 'value.stage === "FIX_FINDINGS" && value.evidence.pr.headSha === "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" && value.evidence.gates.headSha === "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" && value.evidence.review.headSha === "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" && value.evidence.findings === null && value.evidence.validation === null && value.evidence.coverage === null && value.evidence.delivery === null'; then
  check "H5 a coverage fix invalidates every final-head proof but the original review" PASS
else
  check "H5 a coverage fix invalidates every final-head proof but the original review" FAIL
  LOOP_OK=false
fi
loop_event loop-findings-clear-final FINDINGS_CLEARED "{\"headSha\":\"$HEAD_SHA_4\",\"unresolvedCount\":0}"
loop_event loop-validation-pass-final VALIDATION_PASSED "{\"headSha\":\"$HEAD_SHA_4\"}"
loop_event loop-coverage-pass COVERAGE_PASSED "{\"headSha\":\"$HEAD_SHA_4\"}"
if [ "$LOOP_OK" = true ] \
  && json_ok "$LOOP_FILE" 'value.stage === "DELIVER" && value.tdd.attempt === 6 && value.tdd.returnStage === "COVER" && value.tdd.headUpdateRequired === false && value.options.cover === true && value.options.validate === true && value.evidence.pr.headSha === "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" && value.evidence.gates.headSha === value.evidence.pr.headSha && value.evidence.findings.headSha === value.evidence.pr.headSha && value.evidence.validation.headSha === value.evidence.pr.headSha && value.evidence.coverage.headSha === value.evidence.pr.headSha && value.evidence.review.headSha === "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; then
  check "T9 every fix loop rebuilds final-head evidence after advancing the PR head" PASS
else
  check "T9 every fix loop rebuilds final-head evidence after advancing the PR head" FAIL
fi

cp "$LOOP_FILE" "$ROOT/pre-stale-final-evidence.json"
node -e 'const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p));j.evidence.validation.headSha=process.argv[2];fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n");' "$LOOP_FILE" "$HEAD_SHA_3"
BEFORE_STALE_DELIVERY="$(file_digest "$LOOP_FILE")"
if ! autopilot_apply_event "$LOOP_RUN" loop-stale-delivery DELIVERY_COMPLETE \
  "{\"headSha\":\"$HEAD_SHA_4\"}" "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$LOOP_FILE")" = "$BEFORE_STALE_DELIVERY" ]; then
  check "H6 DONE rejects stale validation evidence from an earlier PR head" PASS
else
  check "H6 DONE rejects stale validation evidence from an earlier PR head" FAIL
  LOOP_OK=false
fi
cp "$ROOT/pre-stale-final-evidence.json" "$LOOP_FILE"

loop_event loop-delivery DELIVERY_COMPLETE "{\"headSha\":\"$HEAD_SHA_4\"}"
if [ "$LOOP_OK" = true ] \
  && json_ok "$LOOP_FILE" 'value.stage === "DONE" && value.evidence.delivery.headSha === "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" && value.evidence.review.headSha === "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; then
  check "H7 delivery accepts the once-only review on its original head after final-head proofs pass" PASS
else
  check "H7 delivery accepts the once-only review on its original head after final-head proofs pass" FAIL
fi

RUN2="run_blocking_002"
RUN2_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN2}.json"
if autopilot_begin_run "$RUN2" "session_owner_002" "$PROJECT" >/dev/null \
  && autopilot_apply_event "$RUN2" "evt_block_002" "BLOCK" '{"code":"MANUAL_PAUSE"}' "$PROJECT" >/dev/null \
  && json_ok "$RUN2_FILE" 'value.stage === "BLOCKED" && value.nextActionCode === "AWAIT_RESUME" && value.blocked.from === "PLANNING" && value.blocked.code === "MANUAL_PAUSE"' \
  && autopilot_apply_event "$RUN2" "evt_resume_002" "RESUME" '{}' "$PROJECT" >/dev/null \
  && json_ok "$RUN2_FILE" 'value.stage === "PLANNING" && value.blocked.from === null && value.blocked.code === null'; then
  check "T10 BLOCK and RESUME preserve the exact suspended stage" PASS
else
  check "T10 BLOCK and RESUME preserve the exact suspended stage" FAIL
fi

FIRST_BUDGET="$(autopilot_increment_stop_budget "$RUN2" "PLANNING" "$PROJECT")"
SECOND_BUDGET="$(autopilot_increment_stop_budget "$RUN2" "PLANNING" "$PROJECT")"
if [ "$FIRST_BUDGET" = "1" ] && [ "$SECOND_BUDGET" = "2" ] \
  && json_ok "$RUN2_FILE" 'value.stopBudget.stage === "PLANNING" && value.stopBudget.count === 2'; then
  check "B5 stop budget increments atomically within its stage" PASS
else
  check "B5 stop budget increments atomically within its stage" FAIL
fi

CONCURRENT_OK=true
PIDS=""
for worker in 1 2 3 4 5 6 7 8; do
  (
    AUTOPILOT_DISABLE_FLOCK=1 autopilot_increment_stop_budget \
      "$RUN2" "PLANNING" "$PROJECT" >"$ROOT/budget-worker-$worker.out"
  ) &
  PIDS="$PIDS $!"
done
for worker_pid in $PIDS; do
  wait "$worker_pid" || CONCURRENT_OK=false
done
if [ "$CONCURRENT_OK" = true ] \
  && json_ok "$RUN2_FILE" 'value.stopBudget.stage === "PLANNING" && value.stopBudget.count === 10'; then
  check "B6 the mkdir-lock fallback serializes concurrent state updates" PASS
else
  check "B6 the mkdir-lock fallback serializes concurrent state updates" FAIL
fi

BEFORE_WRONG_BUDGET="$(file_digest "$RUN2_FILE")"
if ! autopilot_increment_stop_budget "$RUN2" "GATES" "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$RUN2_FILE")" = "$BEFORE_WRONG_BUDGET" ]; then
  check "B7 stop budget rejects a stale expected stage" PASS
else
  check "B7 stop budget rejects a stale expected stage" FAIL
fi

if autopilot_apply_event "$RUN2" "evt_cancel_002" "CANCEL" '{}' "$PROJECT" >/dev/null \
  && json_ok "$RUN2_FILE" 'value.stage === "CANCELLED" && value.nextActionCode === "NONE"'; then
  check "T11 cancellation is terminal" PASS
else
  check "T11 cancellation is terminal" FAIL
fi

# Saturate the audit ledger without hundreds of shell/lock round trips. The
# seeded BLOCK/RESUME pairs are individually schema-valid and leave the run in
# AWAIT_TDD at the normal-event cutoff. Two slots must remain: BLOCK, then the
# explicit CANCEL that retires an exhausted blocked generation.
CAP_RUN="run_event_cap_003"
CAP_OWNER="session_event_cap_003"
CAP_FILE="$PROJECT/.zensu/state/autopilot-run-${CAP_RUN}.json"
if autopilot_begin_run "$CAP_RUN" "$CAP_OWNER" "$PROJECT" >/dev/null \
  && autopilot_apply_event "$CAP_RUN" cap_plan PLAN_APPROVED \
    "{\"approvedPlanSha256\":\"$PLAN_SHA\"}" "$PROJECT" >/dev/null; then
  FILE="$CAP_FILE" node -e '
    const crypto=require("crypto"),fs=require("fs"),s=JSON.parse(fs.readFileSync(process.env.FILE,"utf8"));
    const digest=p=>crypto.createHash("sha256").update(JSON.stringify(p)).digest("hex");
    for(let i=0;i<254;i+=1){
      const block={code:`cap_code_${i}`};
      s.events.push({eventId:`cap_block_${i}`,eventType:"BLOCK",payloadDigest:digest(block),payload:block,fromStage:"AWAIT_TDD",toStage:"BLOCKED"});
      const resume={};
      s.events.push({eventId:`cap_resume_${i}`,eventType:"RESUME",payloadDigest:digest(resume),payload:resume,fromStage:"BLOCKED",toStage:"AWAIT_TDD"});
    }
    fs.writeFileSync(process.env.FILE,JSON.stringify(s,null,2)+"\n");
  '
fi
CAP_BEFORE="$(file_digest "$CAP_FILE")"
if ! autopilot_apply_event "$CAP_RUN" cap_normal BYPASS_RECORDED '{"gate":"cap_gate"}' "$PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$CAP_FILE")" = "$CAP_BEFORE" ] \
  && autopilot_apply_event "$CAP_RUN" cap_final_block BLOCK '{"code":"EVENT_LEDGER_EXHAUSTED"}' "$PROJECT" >/dev/null \
  && ! autopilot_apply_event "$CAP_RUN" cap_unsafe_resume RESUME '{}' "$PROJECT" >/dev/null 2>&1 \
  && autopilot_apply_event "$CAP_RUN" cap_final_cancel CANCEL '{}' "$PROJECT" >/dev/null \
  && json_ok "$CAP_FILE" 'value.events.length===512&&value.stage==="CANCELLED"&&value.nextActionCode==="NONE"'; then
  check "B8 event cap preserves a fail-closed BLOCK plus terminal CANCEL path" PASS
else
  check "B8 event cap preserves a fail-closed BLOCK plus terminal CANCEL path" FAIL
fi

cp "$ACTIVE_FILE" "$ROOT/active-valid.json"
node -e 'const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p));j.unexpected=true;fs.writeFileSync(p,JSON.stringify(j));' "$ACTIVE_FILE"
autopilot_read_active "$PROJECT" >/dev/null 2>&1
READ_CORRUPT_RC=$?
cp "$ROOT/active-valid.json" "$ACTIVE_FILE"
if [ "$READ_CORRUPT_RC" -eq 2 ]; then
  check "S3 strict active-pointer schema reports corruption distinctly" PASS
else
  check "S3 strict active-pointer schema reports corruption distinctly (rc=$READ_CORRUPT_RC)" FAIL
fi

# A ledger is not valid merely because adjacent from/to labels line up. Forge a
# formally well-shaped PLAN_APPROVED event that jumps directly from PLANNING to
# TEAM_REVIEW while leaving the plan evidence unset. Both the direct reader and
# the public status command must classify that semantic history as corruption.
SEMANTIC_PROJECT="$ROOT/semantic-history-project"
mkdir -p "$SEMANTIC_PROJECT"
SEMANTIC_RUN="run_semantic_history_003"
SEMANTIC_OWNER="session_semantic_history_003"
autopilot_begin_run "$SEMANTIC_RUN" "$SEMANTIC_OWNER" "$SEMANTIC_PROJECT" >/dev/null
SEMANTIC_FILE="$(autopilot_run_file "$SEMANTIC_RUN" "$SEMANTIC_PROJECT")"
FILE="$SEMANTIC_FILE" PLAN_SHA="$PLAN_SHA" node -e '
  const crypto=require("crypto"),fs=require("fs"),p=process.env.FILE;
  const s=JSON.parse(fs.readFileSync(p,"utf8"));
  const payload={approvedPlanSha256:process.env.PLAN_SHA};
  const canonical=value => Array.isArray(value)
    ? `[${value.map(canonical).join(",")}]`
    : value && typeof value === "object"
      ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`
      : JSON.stringify(value);
  s.stage="TEAM_REVIEW";
  s.nextActionCode="RECONCILE_TEAM_REVIEW";
  s.stopBudget={stage:"TEAM_REVIEW",count:0};
  s.events.push({
    eventId:"forged_plan_jump",
    eventType:"PLAN_APPROVED",
    payloadDigest:crypto.createHash("sha256").update(canonical(payload)).digest("hex"),
    payload,
    fromStage:"PLANNING",
    toStage:"TEAM_REVIEW",
  });
  fs.writeFileSync(p,JSON.stringify(s,null,2)+"\n");
'
autopilot_read_run "$SEMANTIC_RUN" "$SEMANTIC_PROJECT" >/dev/null 2>&1
SEMANTIC_READ_RC=$?
CLAUDE_PROJECT_DIR="$SEMANTIC_PROJECT" CLAUDE_SESSION_ID="$SEMANTIC_OWNER" \
  bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --autopilot-status >/dev/null 2>&1
SEMANTIC_STATUS_RC=$?
if [ "$SEMANTIC_READ_RC" -eq 2 ] && [ "$SEMANTIC_STATUS_RC" -eq 2 ]; then
  check "S3b impossible event-history jumps fail closed on read and status" PASS
else
  check "S3b semantic history corruption is rejected (read=$SEMANTIC_READ_RC status=$SEMANTIC_STATUS_RC)" FAIL
fi

MISSING_PROJECT="$ROOT/missing-project"
mkdir -p "$MISSING_PROJECT"
autopilot_read_active "$MISSING_PROJECT" >/dev/null 2>&1
READ_MISSING_RC=$?
if [ "$READ_MISSING_RC" -eq 1 ]; then
  check "S4 read_active distinguishes an absent run from corruption" PASS
else
  check "S4 read_active distinguishes an absent run from corruption (rc=$READ_MISSING_RC)" FAIL
fi

DANGLING_PROJECT="$ROOT/dangling-project"
mkdir -p "$DANGLING_PROJECT"
autopilot_begin_run run_dangling_003 session_dangling_003 "$DANGLING_PROJECT" >/dev/null
rm -f "$(autopilot_run_file run_dangling_003 "$DANGLING_PROJECT")"
autopilot_read_active "$DANGLING_PROJECT" >/dev/null 2>&1
DANGLING_RC=$?
if [ "$DANGLING_RC" -eq 2 ]; then
  check "S4b a valid pointer with a missing run file is corrupt, never absent" PASS
else
  check "S4b dangling active pointer is corrupt (rc=$DANGLING_RC)" FAIL
fi

# begin publishes the run file before its pointer while holding the project-wide
# lock. A concurrent reader must wait for the second rename, not classify that
# healthy in-flight publication as a durable orphan.
publish_begin_window() {
  local root="$1" run_id="$2" owner="$3" ready="$4" release="$5"
  local state_dir="$root/.zensu/state"
  local run_file="$state_dir/autopilot-run-${run_id}.json"
  local active_file="$state_dir/autopilot-active.json"
  local run_tmp active_tmp
  run_tmp="$(mktemp "${run_file}.XXXXXX" 2>/dev/null)" || return 1
  active_tmp="$(mktemp "${active_file}.XXXXXX" 2>/dev/null)" || { rm -f "$run_tmp"; return 1; }
  _autopilot_node begin "$active_file" "$run_file" "$run_tmp" "$active_tmp" \
    "$run_id" "$owner" "$root" false true || { rm -f "$run_tmp" "$active_tmp"; return 1; }
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp" "$active_tmp"; return 1; }
  printf '%s\n' ready > "$ready"
  while [ ! -f "$release" ]; do sleep 0.01; done
  _tdd_atomic_replace_regular "$active_tmp" "$active_file" || { rm -f "$active_tmp"; return 1; }
}

WINDOW_PROJECT="$ROOT/begin-window-project"
WINDOW_RUN=run_begin_window_003
WINDOW_OWNER=session_begin_window_003
WINDOW_READY="$ROOT/begin-window.ready"
WINDOW_RELEASE="$ROOT/begin-window.release"
WINDOW_READ="$ROOT/begin-window-read.json"
mkdir -p "$WINDOW_PROJECT"
WINDOW_PROJECT="$(cd "$WINDOW_PROJECT" && pwd -P)"
_autopilot_prepare_storage "$WINDOW_PROJECT" || exit 1
(
  _autopilot_locked_run "$WINDOW_PROJECT" "$WINDOW_RUN" publish_begin_window \
    "$WINDOW_PROJECT" "$WINDOW_RUN" "$WINDOW_OWNER" "$WINDOW_READY" "$WINDOW_RELEASE"
) &
WINDOW_PUBLISH_PID=$!
WINDOW_TRIES=0
while [ ! -f "$WINDOW_READY" ] && kill -0 "$WINDOW_PUBLISH_PID" 2>/dev/null \
    && [ "$WINDOW_TRIES" -lt 200 ]; do
  WINDOW_TRIES=$((WINDOW_TRIES + 1))
  sleep 0.01
done
WINDOW_OK=true
if [ ! -f "$WINDOW_READY" ]; then
  WINDOW_OK=false
else
  autopilot_read_active "$WINDOW_PROJECT" > "$WINDOW_READ" 2>/dev/null &
  WINDOW_READ_PID=$!
  sleep 0.1
  kill -0 "$WINDOW_READ_PID" 2>/dev/null || WINDOW_OK=false
  printf '%s\n' release > "$WINDOW_RELEASE"
  wait "$WINDOW_PUBLISH_PID" || WINDOW_OK=false
  wait "$WINDOW_READ_PID" || WINDOW_OK=false
  json_ok "$WINDOW_READ" \
    'value.runId === "run_begin_window_003" && value.stage === "PLANNING"' || WINDOW_OK=false
fi
if [ "$WINDOW_OK" = true ]; then
  check "S4c read_active waits across the healthy two-rename begin window" PASS
else
  printf '%s\n' release > "$WINDOW_RELEASE"
  wait "$WINDOW_PUBLISH_PID" 2>/dev/null || true
  check "S4c read_active waits across the healthy two-rename begin window" FAIL
fi

BEGIN_ORPHAN_PROJECT="$ROOT/begin-orphan-project"
BEGIN_ORPHAN_RUN=run_begin_orphan_003
BEGIN_ORPHAN_OWNER=session_begin_orphan_003
mkdir -p "$BEGIN_ORPHAN_PROJECT"
autopilot_begin_run "$BEGIN_ORPHAN_RUN" "$BEGIN_ORPHAN_OWNER" "$BEGIN_ORPHAN_PROJECT" >/dev/null
BEGIN_ORPHAN_FILE="$(autopilot_run_file "$BEGIN_ORPHAN_RUN" "$BEGIN_ORPHAN_PROJECT")"
rm -f "$(autopilot_active_file "$BEGIN_ORPHAN_PROJECT")"
BEGIN_ORPHAN_BEFORE="$(file_digest "$BEGIN_ORPHAN_FILE")"
if ! autopilot_begin_run run_competing_orphan_003 session_competing_orphan_003 \
    "$BEGIN_ORPHAN_PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$BEGIN_ORPHAN_FILE")" = "$BEGIN_ORPHAN_BEFORE" ] \
  && [ ! -e "$BEGIN_ORPHAN_PROJECT/.zensu/state/autopilot-active.json" ] \
  && [ ! -e "$BEGIN_ORPHAN_PROJECT/.zensu/state/autopilot-run-run_competing_orphan_003.json" ]; then
  check "S4d a different begin cannot hide a pointerless nonterminal orphan" PASS
else
  check "S4d competing begin rejects without durable mutation" FAIL
fi

BEGIN_RETRY_REJECTS=true
autopilot_begin_run "$BEGIN_ORPHAN_RUN" session_wrong_orphan_003 \
  "$BEGIN_ORPHAN_PROJECT" >/dev/null 2>&1 && BEGIN_RETRY_REJECTS=false
autopilot_begin_run "$BEGIN_ORPHAN_RUN" "$BEGIN_ORPHAN_OWNER" \
  "$BEGIN_ORPHAN_PROJECT" true true >/dev/null 2>&1 && BEGIN_RETRY_REJECTS=false
if [ "$BEGIN_RETRY_REJECTS" = true ] \
  && [ "$(file_digest "$BEGIN_ORPHAN_FILE")" = "$BEGIN_ORPHAN_BEFORE" ] \
  && [ ! -e "$BEGIN_ORPHAN_PROJECT/.zensu/state/autopilot-active.json" ] \
  && autopilot_begin_run "$BEGIN_ORPHAN_RUN" "$BEGIN_ORPHAN_OWNER" \
    "$BEGIN_ORPHAN_PROJECT" >/dev/null \
  && [ "$(file_digest "$BEGIN_ORPHAN_FILE")" = "$BEGIN_ORPHAN_BEFORE" ] \
  && autopilot_read_active "$BEGIN_ORPHAN_PROJECT" > "$ROOT/begin-orphan-healed.json" \
  && json_ok "$ROOT/begin-orphan-healed.json" \
    'value.runId === "run_begin_orphan_003" && value.stage === "PLANNING"'; then
  check "S4e only an identity- and option-exact retry heals a pointerless orphan" PASS
else
  check "S4e exact orphan retry reconstructs the pointer byte-stably" FAIL
fi

HIDDEN_BEGIN_PROJECT="$ROOT/hidden-begin-project"
HIDDEN_OLD_RUN=run_hidden_old_terminal_003
HIDDEN_NEW_RUN=run_hidden_orphan_003
mkdir -p "$HIDDEN_BEGIN_PROJECT"
autopilot_begin_run "$HIDDEN_OLD_RUN" session_hidden_old_003 "$HIDDEN_BEGIN_PROJECT" >/dev/null
autopilot_apply_event "$HIDDEN_OLD_RUN" cancel-hidden-old CANCEL '{}' \
  "$HIDDEN_BEGIN_PROJECT" >/dev/null
HIDDEN_OLD_POINTER="$ROOT/hidden-old-pointer.json"
cp "$(autopilot_active_file "$HIDDEN_BEGIN_PROJECT")" "$HIDDEN_OLD_POINTER"
autopilot_begin_run "$HIDDEN_NEW_RUN" session_hidden_new_003 "$HIDDEN_BEGIN_PROJECT" >/dev/null
HIDDEN_NEW_FILE="$(autopilot_run_file "$HIDDEN_NEW_RUN" "$HIDDEN_BEGIN_PROJECT")"
cp "$HIDDEN_OLD_POINTER" "$(autopilot_active_file "$HIDDEN_BEGIN_PROJECT")"
HIDDEN_POINTER_BEFORE="$(file_digest "$(autopilot_active_file "$HIDDEN_BEGIN_PROJECT")")"
HIDDEN_RUN_BEFORE="$(file_digest "$HIDDEN_NEW_FILE")"
if ! autopilot_begin_run run_hidden_competing_003 session_hidden_competing_003 \
    "$HIDDEN_BEGIN_PROJECT" >/dev/null 2>&1 \
  && [ "$(file_digest "$(autopilot_active_file "$HIDDEN_BEGIN_PROJECT")")" = "$HIDDEN_POINTER_BEFORE" ] \
  && [ "$(file_digest "$HIDDEN_NEW_FILE")" = "$HIDDEN_RUN_BEFORE" ] \
  && [ ! -e "$HIDDEN_BEGIN_PROJECT/.zensu/state/autopilot-run-run_hidden_competing_003.json" ] \
  && autopilot_begin_run "$HIDDEN_NEW_RUN" session_hidden_new_003 \
    "$HIDDEN_BEGIN_PROJECT" >/dev/null \
  && [ "$(file_digest "$HIDDEN_NEW_FILE")" = "$HIDDEN_RUN_BEFORE" ] \
  && autopilot_read_active "$HIDDEN_BEGIN_PROJECT" > "$ROOT/hidden-begin-healed.json" \
  && json_ok "$ROOT/hidden-begin-healed.json" \
    'value.runId === "run_hidden_orphan_003" && value.stage === "PLANNING"'; then
  check "S4f exact retry heals an orphan hidden behind terminal history" PASS
else
  check "S4f terminal history cannot conceal or replace its nonterminal orphan" FAIL
fi

VICTIM="$ROOT/victim"
LINK_PROJECT="$ROOT/link-project"
mkdir -p "$VICTIM" "$LINK_PROJECT"
if make_directory_symlink "$VICTIM" "$LINK_PROJECT/.zensu" \
  && ! autopilot_begin_run "run_symlink_003" "session_owner_003" "$LINK_PROJECT" >/dev/null 2>&1 \
  && [ -z "$(find "$VICTIM" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  check "S5 symlinked project-state ancestors cannot escape the project" PASS
else
  check "S5 symlinked project-state ancestors cannot escape the project" FAIL
fi

ACTIVE_HARDLINK="$ROOT/active-hardlink.json"
ln "$ACTIVE_FILE" "$ACTIVE_HARDLINK"
autopilot_read_active "$PROJECT" >/dev/null 2>&1
READ_HARDLINK_RC=$?
rm -f "$ACTIVE_HARDLINK"
if [ "$READ_HARDLINK_RC" -eq 2 ]; then
  check "S6 hard-linked state leaves are rejected" PASS
else
  check "S6 hard-linked state leaves are rejected (rc=$READ_HARDLINK_RC)" FAIL
fi

if ! autopilot_begin_run '../escape' 'session_owner_004' "$PROJECT" >/dev/null 2>&1 \
  && [ ! -e "$PROJECT/.zensu/escape.json" ]; then
  check "S7 traversal-shaped run identifiers are rejected" PASS
else
  check "S7 traversal-shaped run identifiers are rejected" FAIL
fi

COPIED_PROJECT="$ROOT/copied-project"
mkdir -p "$COPIED_PROJECT"
cp -R "$PROJECT/.zensu" "$COPIED_PROJECT/.zensu"
autopilot_read_active "$COPIED_PROJECT" >/dev/null 2>&1
COPIED_ACTIVE_RC=$?
autopilot_read_run "$RUN2" "$COPIED_PROJECT" >/dev/null 2>&1
COPIED_RUN_RC=$?
if [ "$COPIED_ACTIVE_RC" -eq 2 ] && [ "$COPIED_RUN_RC" -eq 2 ]; then
  check "S8 copied state cannot be replayed from a different physical project root" PASS
else
  check "S8 copied state cannot be replayed from a different physical project root (active=$COPIED_ACTIVE_RC run=$COPIED_RUN_RC)" FAIL
fi

INVALID_ARTIFACT_PROJECT="$ROOT/invalid-run-artifact"
mkdir -p "$INVALID_ARTIFACT_PROJECT/.zensu/state"
printf '%s\n' '{}' > "$INVALID_ARTIFACT_PROJECT/.zensu/state/autopilot-run-xx.json"
autopilot_read_active "$INVALID_ARTIFACT_PROJECT" >/dev/null 2>&1
INVALID_ARTIFACT_RC=$?
if [ "$INVALID_ARTIFACT_RC" -eq 2 ]; then
  check "S9 exact run-file envelope with an invalid id is corrupt inventory" PASS
else
  check "S9 invalid-id run artifact cannot be ignored as absent (rc=$INVALID_ARTIFACT_RC)" FAIL
fi

printf '%s\n' "----" "test-autopilot-state-machine: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
