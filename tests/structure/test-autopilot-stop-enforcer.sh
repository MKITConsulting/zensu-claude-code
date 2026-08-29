#!/bin/bash
# The inner review chain routes first; the outer run releases only at a terminal.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }
source "$LIB"
review_marker() {
  local operation_key="$1" head_sha="$2" payload_digest="$3"
  OPERATION_KEY="$operation_key" HEAD_SHA="$head_sha" PAYLOAD_DIGEST="$payload_digest" node -e '
    const crypto=require("crypto");
    const op=crypto.createHash("sha256").update(process.env.OPERATION_KEY).digest("hex");
    process.stdout.write(`<!-- zensu-review:v1:${op}:${process.env.PAYLOAD_DIGEST}:${process.env.HEAD_SHA.toLowerCase()}:1:part=1/1 -->`);
  '
}
TMP="$(mktemp -d -t zensu-autopilot-stop-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

activate_session() {
  local project="$1" raw_session="$2" project_root session_key
  project_root="$(cd "$project" && pwd -P)" || return 1
  session_key="$(node "$CORE" session-key "$raw_session")" || return 1
  export CLAUDE_PROJECT_DIR="$project"
  if [ "${ZENSU_PROJECT_ROOT:-}" = "$project_root" ] \
      && [ "${ZENSU_SESSION_KEY:-}" = "$session_key" ] \
      && [ "${ZENSU_CLAUDE_PLUGIN_ROOT:-}" = "$PLUGIN_DIR" ] \
      && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] \
      && [ "$(node "$CORE" session-key "$CLAUDE_CODE_SESSION_ID" 2>/dev/null)" = "$session_key" ] \
      && [ -f "${ZENSU_SESSION_CONTEXT:-}" ]; then
    return 0
  fi
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session"
}
start() {
  mkdir -p "$1"
  activate_session "$1" "$3" || return 1
  autopilot_begin_run "$2" "$ZENSU_SESSION_KEY" "$1" >/dev/null
}
# The active pointer is keyed by the run owner, which is the resolved session
# key rather than the raw session id the fixtures pass around.
pointer() {
  local key
  key="$(node "$CORE" session-key "$2")" || return 1
  autopilot_active_file "$1" "$key"
}
invoke() {
  local project="$1" sid="$2" cfg="${3:-$TMP/missing.json}" chain="${4:-}" autopilot="${5:-}"
  activate_session "$project" "$sid" || return 1
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$sid" | CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$cfg" \
    ZENSU_CHAIN="$chain" ZENSU_AUTOPILOT="$autopilot" bash "$STOP" 2>/dev/null
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).decision||"allow")}catch(_){console.log("allow")}})'; }
context() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(s).reason||"")}catch(_){process.exit(1)}})'; }
field_ok() { FILE="$1" EXPR="$2" node -e 'const j=require(process.env.FILE);process.exit(Function("j",`return Boolean(${process.env.EXPR})`)(j)?0:1)' 2>/dev/null; }
# A missing file must NOT digest to the empty string: six "owner state unmutated"
# conjuncts compare two digests, and "" = "" would pass vacuously if the run file
# were ever renamed or never published.
digest() { node -e 'const fs=require("fs"),crypto=require("crypto");try{process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));}catch(_){process.stdout.write("MISSING:"+process.argv[1]);process.exit(1);}' "$1"; }

copy_runtime() {
  local destination="$1" runtime_entry
  mkdir -p "$destination"
  destination="$(cd "$destination" && pwd -P)" || return 1
  for runtime_entry in .claude-plugin .mcp.json hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
    cp -R "$PLUGIN_DIR/$runtime_entry" "$destination/$runtime_entry" || return 1
  done
  mkdir -p "$destination/mcp-runtime"
  cp "$PLUGIN_DIR/mcp-runtime/package.json" "$PLUGIN_DIR/mcp-runtime/package-lock.json" \
    "$destination/mcp-runtime/" || return 1
}

bind_runtime_session() {
  local plugin_root="$1" project="$2" raw_session="$3" label="$4"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/$label-plugin-data"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session" "$plugin_root"
  unset ZENSU_TEST_PLUGIN_DATA
}

P1="$TMP/planning"; start "$P1" stop_run_01 stop_session_01
OUT1="$(invoke "$P1" stop_session_01)"
if [ "$(printf '%s' "$OUT1" | decision)" = block ] && printf '%s' "$OUT1" | grep -qF 'nextActionCode=AWAIT_PLAN_APPROVAL'; then
  check "S1 non-terminal outer stage blocks Stop with its closed next action" PASS
else check "S1 non-terminal outer stage blocks Stop" FAIL; fi

P1H="$TMP/head-prerequisite"; start "$P1H" stop_run_head stop_session_head
HEAD_SESSION_KEY="$ZENSU_SESSION_KEY"
HEAD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_READY=true
head_event() {
  autopilot_apply_event stop_run_head "$1" "$2" "$3" "$P1H" >/dev/null 2>&1 || HEAD_READY=false
}
head_event stop-head-plan PLAN_APPROVED '{"approvedPlanSha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
head_event stop-head-tdd-start-1 TDD_STARTED "{\"attempt\":1,\"chainId\":\"stop-head-chain-01\",\"sessionId\":\"$HEAD_SESSION_KEY\"}"
head_event stop-head-tdd-done-1 TDD_CHAIN_DONE "{\"attempt\":1,\"chainId\":\"stop-head-chain-01\",\"sessionId\":\"$HEAD_SESSION_KEY\",\"outcome\":\"pass\"}"
head_event stop-head-gates GATES_PASSED "{\"headSha\":\"$HEAD_SHA\"}"
head_event stop-head-converge CONVERGENCE_PASSED '{}'
head_event stop-head-pr-request PR_OPEN_REQUESTED '{"operationKey":"pr:stop-head"}'
head_event stop-head-pr-open PR_OPENED "{\"operationKey\":\"pr:stop-head\",\"pr\":{\"number\":714,\"url\":\"https://github.com/acme/repo/pull/714\",\"headSha\":\"$HEAD_SHA\"}}"
HEAD_REVIEW_KEY="$(autopilot_team_review_operation_key stop_run_head "$HEAD_SHA")"
head_event stop-head-review-request TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$HEAD_REVIEW_KEY\",\"provider\":\"github\"}"
HEAD_REVIEW_PAYLOAD="$TMP/stop-head-review-payload.json"
printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Stop fixture review\",\"commit_id\":\"$HEAD_SHA\",\"comments\":[]}" > "$HEAD_REVIEW_PAYLOAD"
HEAD_REVIEW_SNAPSHOT="$(autopilot_store_team_review_payload stop_run_head "$HEAD_REVIEW_KEY" \
  "$HEAD_SHA" "$HEAD_REVIEW_PAYLOAD" github "$P1H" 2>/dev/null || true)"
[ -n "$HEAD_REVIEW_SNAPSHOT" ] || HEAD_READY=false
HEAD_REVIEW_DIGEST="$(_autopilot_team_review_payload_inspect \
  "$HEAD_REVIEW_SNAPSHOT" "$HEAD_SHA" true canonical 2>/dev/null || true)"
HEAD_REVIEW_MARKER="$(review_marker "$HEAD_REVIEW_KEY" "$HEAD_SHA" "$HEAD_REVIEW_DIGEST")"
head_event stop-head-review-published TEAM_REVIEW_PUBLISHED "{\"operationKey\":\"$HEAD_REVIEW_KEY\",\"marker\":\"$HEAD_REVIEW_MARKER\",\"headSha\":\"$HEAD_SHA\",\"provider\":\"github\"}"
head_event stop-head-fix-required FIX_REQUIRED "{\"headSha\":\"$HEAD_SHA\",\"unresolvedCount\":1}"
head_event stop-head-tdd-start-2 TDD_STARTED "{\"attempt\":2,\"chainId\":\"stop-head-chain-02\",\"sessionId\":\"$HEAD_SESSION_KEY\"}"
head_event stop-head-tdd-done-2 TDD_CHAIN_DONE "{\"attempt\":2,\"chainId\":\"stop-head-chain-02\",\"sessionId\":\"$HEAD_SESSION_KEY\",\"outcome\":\"pass\"}"
OUT1H="$(invoke "$P1H" stop_session_head)"
if [ "$HEAD_READY" = true ] \
  && [ "$(printf '%s' "$OUT1H" | decision)" = block ] \
  && printf '%s' "$OUT1H" | grep -qF 'prerequisiteActionCode=UPDATE_PR_HEAD; nextActionCode=FIX_REVIEW_FINDINGS' \
  && printf '%s' "$OUT1H" | grep -qF 'FIRST execute prerequisite action UPDATE_PR_HEAD' \
  && printf '%s' "$OUT1H" | grep -qF 'Only after that succeeds continue the static stage action FIX_REVIEW_FINDINGS'; then
  check "S1b head-update prerequisite precedes the static outer action" PASS
else check "S1b head-update prerequisite is explicit and ordered" FAIL; fi

CFG_INNER_OFF="$TMP/inner-off.json"; printf '%s\n' '{"hooks":{"chainEnforcer":false}}' > "$CFG_INNER_OFF"
OUT2="$(invoke "$P1" stop_session_01 "$CFG_INNER_OFF")"
[ "$(printf '%s' "$OUT2" | decision)" = block ] \
  && check "S2 chainEnforcer=false disables only the inner chain" PASS \
  || check "S2 chainEnforcer=false disables only the inner chain" FAIL
OUT3="$(invoke "$P1" stop_session_01 "$TMP/missing.json" off)"
[ "$(printf '%s' "$OUT3" | decision)" = block ] \
  && check "S3 ZENSU_CHAIN=off cannot bypass the outer run" PASS \
  || check "S3 ZENSU_CHAIN=off cannot bypass the outer run" FAIL

P2="$TMP/escape-env"; start "$P2" stop_run_escape_env stop_session_escape_env
OUT4="$(invoke "$P2" stop_session_escape_env "$TMP/missing.json" '' off)"
RF2="$(autopilot_run_file stop_run_escape_env "$P2")"
if [ -z "$OUT4" ] && field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="ZENSU_AUTOPILOT_OFF"&&j.events.some(e=>e.eventType==="BLOCK")&&!j.events.some(e=>e.eventType==="DELIVERY_COMPLETE")'; then
  check "S4 env escape is audited as BLOCKED and never DONE" PASS
else check "S4 env escape is audited as BLOCKED and never DONE" FAIL; fi
autopilot_apply_event stop_run_escape_env resume-escape-env RESUME '{}' "$P2" >/dev/null
OUT4B="$(invoke "$P2" stop_session_escape_env "$TMP/missing.json" '' off)"
if [ -z "$OUT4B" ] \
  && field_ok "$RF2" 'j.stage==="BLOCKED"&&j.blocked.code==="ZENSU_AUTOPILOT_OFF"&&j.events.filter(e=>e.eventType==="BLOCK").length===2&&new Set(j.events.filter(e=>e.eventType==="BLOCK").map(e=>e.eventId)).size===2'; then
  check "S4b repeated escape after RESUME records a fresh BLOCK generation" PASS
else check "S4b repeated escape cannot reuse a stale idempotency event" FAIL; fi

P3="$TMP/escape-config"; start "$P3" stop_run_escape_cfg stop_session_escape_cfg
CFG_OUTER_OFF="$TMP/outer-off.json"; printf '%s\n' '{"hooks":{"autopilotEnforcer":false}}' > "$CFG_OUTER_OFF"
OUT5="$(invoke "$P3" stop_session_escape_cfg "$CFG_OUTER_OFF")"
RF3="$(autopilot_run_file stop_run_escape_cfg "$P3")"
if [ -z "$OUT5" ] && field_ok "$RF3" 'j.stage==="BLOCKED"&&j.blocked.code==="AUTOPILOT_ENFORCER_DISABLED"'; then
  check "S5 config escape is audited as BLOCKED" PASS
else check "S5 config escape is audited as BLOCKED" FAIL; fi

P4="$TMP/cancel"; start "$P4" stop_run_cancel stop_session_cancel
autopilot_apply_event stop_run_cancel cancel-stop CANCEL '{}' "$P4" >/dev/null
OUT6="$(invoke "$P4" stop_session_cancel)"
[ -z "$OUT6" ] && check "S6 CANCELLED is terminal and permits Stop" PASS || check "S6 CANCELLED permits Stop" FAIL
rm -f "$(pointer "$P4" stop_session_cancel)"
OUT6B="$(invoke "$P4" stop_session_cancel)"
[ -z "$OUT6B" ] \
  && check "S6b terminal history without a pointer remains compatible with Stop" PASS \
  || check "S6b terminal-only history is treated as absent" FAIL

# A foreign session sharing this working tree with someone else's durable run
# has nothing to adopt while no pending review exists here. The occupancy fence
# ran BEFORE any pending artifact was consulted, so it denied that session's
# Stop -- and told it to retry, which can never succeed while the foreign run
# stays nonterminal. It must release now, and must still not mutate the owner's
# run. S7d is the discriminator that the refusal returns once work IS pending;
# S8g is the control that an OWN active generation still fails closed here.
P5="$TMP/owner"; start "$P5" stop_run_owner stop_session_owner
RF5="$(autopilot_run_file stop_run_owner "$P5")"; BEFORE5="$(digest "$RF5")"
# `[ -z "$OUT7" ]` alone is satisfied by every fail-open early exit in the hook
# and by `invoke` itself failing in `activate_session`, so the release arm needs
# a positive control: the invoke must SUCCEED, and S7d below must then block in
# THIS SAME project once a marker exists. Same tree, same foreign session, one
# variable changed -- that pair is what proves the fence was reached at all.
OUT7="$(invoke "$P5" foreign_session)"; RC7=$?; AFTER5="$(digest "$RF5")"
if [ "$RC7" -eq 0 ] && [ -z "$OUT7" ] && [ "$BEFORE5" = "$AFTER5" ]; then
  check "S7 foreign hold with nothing to adopt releases without mutating owner state" PASS
else check "S7 foreign hold must release when no deferred review is pending (rc=$RC7 out=$OUT7 digest_changed=$( [ "$BEFORE5" = "$AFTER5" ] && echo no || echo yes))" FAIL; fi

# Discriminator for S7, deliberately in the SAME project P5 with the SAME
# foreign session: with a deferred review actually queued in this tree the
# foreign run CAN interleave with the adoption, so the fence must still refuse
# -- and the refusal must NAME the holding run and its release remedy, because
# `--autopilot-status` is owner-scoped and structurally cannot show it. The
# needle is the FULL release command, not the bare word, so this cannot be
# satisfied by the unnamed fallback sentence S8g exercises.
activate_session "$P5" stop_session_owner || exit 1
CLAUDE_PROJECT_DIR="$P5" bash "$LOG" --pending-review --files 'src/foreign-pending.ts' \
  --summary 'review queued while a foreign durable run holds the tree' >/dev/null
PF5="$P5/.zensu/state/pending-review.json"
BEFORE5P="$(digest "$RF5")"; BEFORE5M="$(digest "$PF5")"
OUT7D="$(invoke "$P5" foreign_session)"; AFTER5P="$(digest "$RF5")"
if [ "$(printf '%s' "$OUT7D" | decision)" = block ] \
  && printf '%s' "$OUT7D" | grep -qF 'holds this working tree' \
  && printf '%s' "$OUT7D" | grep -qF 'stop_run_owner' \
  && printf '%s' "$OUT7D" | grep -qF 'run /zensu:autopilot-release' \
  && ! printf '%s' "$OUT7D" | grep -qF -- '--confirm' \
  && printf '%s' "$OUT7D" | grep -qF 'Retrying Stop cannot clear the hold' \
  && [ "$BEFORE5P" = "$AFTER5P" ] \
  && [ -f "$PF5" ] && [ "$BEFORE5M" = "$(digest "$PF5")" ] \
  && [ ! -e "${PF5}.claim" ]; then
  check "S7d a queued deferred review keeps the foreign-hold refusal, names the run, and leaves the marker queued" PASS
else check "S7d pending deferred review must still refuse under a foreign hold (decision=$(printf '%s' "$OUT7D" | decision) marker=$( [ -f "$PF5" ] && echo present || echo gone) claim=$( [ -e "${PF5}.claim" ] && echo minted || echo none))" FAIL; fi

# A marker past the TTL is what the OWNING module calls "no work" -- it deletes
# it and returns 2. Blocking on it would rebuild the permanent wedge, and the
# fence returns before that deleter ever runs, so nothing would reap it either.
P5S="$TMP/owner-stale"; start "$P5S" stop_run_owner_stale stop_session_owner_stale
CLAUDE_PROJECT_DIR="$P5S" bash "$LOG" --pending-review --files 'src/stale-pending.ts' \
  --summary 'review queued long ago' >/dev/null
PF5S="$P5S/.zensu/state/pending-review.json"
node -e '
  const fs=require("fs"); const f=process.argv[1];
  const j=JSON.parse(fs.readFileSync(f,"utf8"));
  j.ts=new Date(Date.now()-48*3600*1000).toISOString();
  fs.writeFileSync(f, JSON.stringify(j));
' "$PF5S"
# Without these two premises the check passes for the wrong reason: a marker
# that was never written, or a backdate that threw, both release as "no marker
# at all" -- which is exactly what this fixture must NOT be measuring.
S7E_PREMISE=1
[ -f "$PF5S" ] || S7E_PREMISE=0
S7E_TTL="$(ZENSU_CONFIG="$TMP/missing.json" zensu_pending_review_ttl_hours 2>/dev/null)"
case "$S7E_TTL" in ''|*[!0-9]*) S7E_TTL=6 ;; esac
# At 0 the staleness test is disabled, so the conclusion below would not follow.
[ "$S7E_TTL" -gt 0 ] || S7E_PREMISE=0
TTL_HOURS="$S7E_TTL" field_ok "$PF5S" 'Date.now()-Date.parse(j.ts) > Number(process.env.TTL_HOURS)*3600*1000' || S7E_PREMISE=0
OUT7S="$(invoke "$P5S" foreign_stale_session)"; RC7S=$?
if [ "$S7E_PREMISE" -eq 1 ] && [ "$RC7S" -eq 0 ] && [ -z "$OUT7S" ]; then
  check "S7e an expired deferred-review marker does not keep the foreign-hold refusal alive" PASS
else check "S7e expired marker must not wedge a foreign session under a hold (premise=$S7E_PREMISE rc=$RC7S)" FAIL; fi

# The fence's own guards, driven directly: every unreadable input must answer
# BLOCKING, and the work discrimination must be visible without a Stop. None of
# these arms is reachable through the hook fixtures above, so inverting any one
# of them would otherwise leave every suite green.
#
# The ORDER here is load-bearing. The WORK arm is LAST in the fence's ladder and
# every arm above it returns the same value -- 0, blocking -- so while `P5` still
# carries S7d's marker a `blocks` result is UNATTRIBUTABLE to any single arm, and
# a check that drives the guards then proves nothing about them. So S7f keeps
# ONLY the arm the marker itself decides, `rm -f "$PF5"` disarms it, and S7f2
# re-drives every guard in the state where each is the only thing that can
# produce a block.
activate_session "$P5" stop_session_owner || exit 1
# Run ids are three characters minimum in the product (`_autopilot_identifier_ok`
# and the worker's `identifier`), so the fixtures use ids a real record could
# carry — otherwise tightening the renderer's shape test to match the product's
# own floor would turn these checks red for a correct change.
HOLD_SELF="$(printf '{"runId":"hold_run_self","stage":"PLANNING","ownerSessionId":"%s"}' "$ZENSU_SESSION_KEY")"
HOLD_FOREIGN='{"runId":"hold_run_foreign","stage":"PLANNING","ownerSessionId":"scv1_deadbeef"}'
guard_blocks() {
  local label="$1"; shift
  if _autopilot_workspace_hold_blocks_adoption "$@"; then return 0; fi
  GUARD_FAILED="${GUARD_FAILED:+$GUARD_FAILED,}$label"
  return 1
}
GUARD_FAILED=""
guard_blocks queued-marker "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" 0 "$P5" || true
if [ -z "$GUARD_FAILED" ]; then
  check "S7f a queued marker alone makes a foreign hold block" PASS
else check "S7f queued marker must block under a foreign hold (failed: $GUARD_FAILED)" FAIL; fi

rm -f "$PF5"
GUARD_FAILED=""
# The disarm is a PREMISE of everything below: with the marker still there the
# work arm blocks on its own and every guard above it stays green under
# inversion.
[ ! -e "$PF5" ] || GUARD_FAILED="marker-not-disarmed"
guard_blocks empty-holder "" "$ZENSU_SESSION_KEY" 0 "$P5" || true
guard_blocks malformed-holder 'not json' "$ZENSU_SESSION_KEY" 0 "$P5" || true
guard_blocks holder-without-owner '{"runId":"hold_run_x","stage":"PLANNING"}' "$ZENSU_SESSION_KEY" 0 "$P5" || true
guard_blocks own-owner "$HOLD_SELF" "$ZENSU_SESSION_KEY" 0 "$P5" || true
guard_blocks empty-session "$HOLD_FOREIGN" "" 0 "$P5" || true
# The two halves of the ladder the marker itself does not decide. A CLAIM is
# unconditional work (the owner reconciles a claim rather than dropping it), and
# an UNSAFE marker is tamper evidence the owner refuses on -- a bare `[ -f ]`
# would read both of the latter as absent and RELAX the fence.
: > "${PF5}.claim"
guard_blocks claim-only "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" 0 "$P5" || true
rm -f "${PF5}.claim"
[ ! -e "${PF5}.claim" ] || GUARD_FAILED="${GUARD_FAILED:+$GUARD_FAILED,}claim-not-disarmed"
# A DIRECTORY at the marker path, not a symlink: `_tdd_path_safe`'s
# regular-or-absent mode rejects it on every host, while `[ -f ]` reads it as
# absent -- so it still discriminates against a bare existence test. Git Bash
# can satisfy `ln -s` with a copy, which would have made the symlink shape fail
# for an environment reason on the weekly Windows structure shards.
mkdir -p "$PF5"
guard_blocks unsafe-marker "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" 0 "$P5" || true
rm -rf "$PF5"
# NOT PINNED HERE, deliberately: the `root` argument. Asserting BLOCK pins
# nothing, because the predicate fails CLOSED and every failure mode produces
# that same answer. The discriminating shape would need the ANCHOR alone to
# decide — a symlinked `.zensu` component that the anchored `_tdd_path_safe`
# refuses while the unanchored fallback accepts — and an attempt at it did NOT
# reproduce that split (the marker path is resolved through
# `zensu_resolve_project_dir`, so it does not travel through the symlinked
# component the fixture plants). There is a SECOND, structural half: every
# fixture here lives under `$TMP`, and `_tdd_paths_safe` always trusts
# `${TMPDIR:-/tmp}` as an anchor, so the `root` argument can never be the
# deciding one in this suite at all. A discriminating check needs a fixture
# rooted OUTSIDE both `TMPDIR` and `HOME`. Rather than ship a check that passes
# for a reason nobody established, the gap is recorded here and in CLAUDE.md.
if [ -z "$GUARD_FAILED" ]; then
  check "S7f2 with the marker gone, every fence guard plus the claim and unsafe-marker arms is the sole reason a hold still blocks" PASS
else check "S7f2 marker-independent guards must block (failed: $GUARD_FAILED)" FAIL; fi

# S7s -- the work predicate's COST and its READ ORDER, plus the three exact-arity
# guards nothing executed.
#
# Cost: this predicate runs inside the project-wide Outer lease on a path the
# repository itself calls a steady state reached at every turn end, and before
# this it spent every one of its `_tdd_path_safe` spawns before the first builtin
# ran. When NEITHER file exists in any form the verdict is already decided, so
# the spawns cannot change it. The short-circuit tests existence with builtins
# and returns.
#
# `-e` alone is not "absent": a DANGLING symlink is false for `-e` and true for
# `-L`, and it is exactly the tamper shape `_tdd_path_safe` refuses on. Short-
# circuiting on `-e` alone would answer NO WORK for it and RELAX the fence, which
# is the one direction this predicate may never fail in.
#
# Order: the rename an adoption performs moves the marker ONTO the claim, so a
# reader that tests the claim FIRST can see it absent (marker still there) and
# then see the marker absent (rename landed in between) -- both reads reporting
# absent while the work is live. Testing the MARKER first removes the window
# without a second read: if the marker is gone the rename has already happened,
# so the claim read that follows finds it. The ladder below holds that order, and
# its semantics are unchanged -- a claim is still unconditional work, and the TTL
# still applies to the marker alone.
#
# The ordering half is pinned at SOURCE, and that is a real limit rather than a
# shortcut: the distinguishing state is a rename landing BETWEEN two adjacent
# builtins with no call site in between, so no shell fixture can drive it. The
# four ladder states below are driven behaviourally instead, which is what proves
# the reordering preserved the verdicts.
WORK_FAILED=""
# Count `_tdd_paths_safe`, the multi-pair entry point the predicate calls. The
# counter used to wrap `_tdd_path_safe`, which the predicate no longer reaches --
# so every cost arm below would have read zero spawns for a predicate that does
# spawn, and the bound they exist to hold would have been vacuous.
eval "$(declare -f _tdd_paths_safe | sed '1s/_tdd_paths_safe/_tdd_paths_safe_real/')"
_tdd_paths_safe() { WORK_SAFE_CALLS=$((WORK_SAFE_CALLS+1)); _tdd_paths_safe_real "$@"; }
work_verdict() {
  WORK_SAFE_CALLS=0
  if _autopilot_deferred_work_present "$@"; then WORK_RC=0; else WORK_RC=$?; fi
}
# Both absent: the verdict is "no work", and the guard STILL runs -- exactly once
# for the pair. The builtin short-circuit that used to answer here with no spawn
# at all tested the two LEAVES only, so it relaxed the fence under a symlinked
# ANCESTOR (the arm further down). What survives of that cost property is the
# BOUND: one spawn validates both paths, never two.
rm -f "$PF5" "${PF5}.claim"
work_verdict 0 "$P5"
[ "$WORK_RC" -eq 1 ] && [ "$WORK_SAFE_CALLS" -eq 1 ] \
  || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}absent-both:rc=$WORK_RC,spawns=$WORK_SAFE_CALLS"
# A fresh marker is work, and the guard runs here too -- one call, not two. This
# arm is also what keeps the bound above from being satisfied by a predicate that
# never validates anything at all.
: > "$PF5"
work_verdict 0 "$P5"
[ "$WORK_RC" -eq 0 ] && [ "$WORK_SAFE_CALLS" -eq 1 ] \
  || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}fresh-marker:rc=$WORK_RC,spawns=$WORK_SAFE_CALLS"
# A claim alone is unconditional work: the owner reconciles a claim rather than
# dropping it, and no TTL applies to it.
rm -f "$PF5"; : > "${PF5}.claim"
work_verdict 0 "$P5"
[ "$WORK_RC" -eq 0 ] || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}claim-only:rc=$WORK_RC"
# A marker past the TTL with nothing claimed is NOT work -- the owner deletes it
# and reports none, so reporting it present would rebuild the permanent wedge.
# `ttl_hours` of 1 against a marker backdated two hours is the discriminating
# pair; at 0 the TTL is disabled and this arm would read as fresh.
rm -f "${PF5}.claim"
# The marker must be VALID JSON carrying a `ts`: the staleness reader parses the
# file and an empty one throws, which its catch reports as NOT stale -- so an
# empty fixture could never reach this arm at all.
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({ts:new Date(Date.now()-7200000).toISOString()}));' "$PF5"
work_verdict 1 "$P5"
[ "$WORK_RC" -eq 1 ] || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}stale-marker:rc=$WORK_RC"
# ... but a stale marker beside a CLAIM is still work. This is the arm the
# reordering had to preserve: the marker test now runs first and must fall
# THROUGH to the claim rather than returning on the stale verdict.
: > "${PF5}.claim"
work_verdict 1 "$P5"
[ "$WORK_RC" -eq 0 ] || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}stale-marker-with-claim:rc=$WORK_RC"
rm -f "$PF5" "${PF5}.claim"
# A DANGLING symlink is the shape a bare `-e` short-circuit would misread as
# absent. `_tdd_path_safe` refuses it, so the verdict must be work-present.
ln -s "$TMP/no-such-target-for-s7s" "$PF5" 2>/dev/null && {
  work_verdict 0 "$P5"
  [ "$WORK_RC" -eq 0 ] || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}dangling-symlink:rc=$WORK_RC"
}
rm -f "$PF5"
# A symlinked ANCESTOR is the shape the removed builtin short-circuit misread,
# and this arm is the finding it exists for. With the state DIRECTORY replaced by
# a symlink to a directory holding no marker, `-e` on the marker follows the link
# to an absent leaf and is false, while `-L` lstats that same absent leaf and is
# false too -- so a leaf-only pair answers "absent in every form" and the fence
# RELAXES. `_tdd_paths_safe` walks every component and refuses on the link, so
# the verdict must be work-present. Note this differs from the dangling-symlink
# arm above, where the LEAF itself carries the link and `-L` already catches it.
WORK_STATE_DIR="$(dirname "$PF5")"
rm -f "$PF5" "${PF5}.claim"
if mv "$WORK_STATE_DIR" "${WORK_STATE_DIR}.real" 2>/dev/null; then
  # `ln -s` exiting 0 is not evidence of a symlink on every host -- Git Bash can
  # satisfy it with a copy -- so the assertion is gated on `-L` and SKIPPED
  # rather than failed where no real link was created.
  if ln -s "${WORK_STATE_DIR}.real" "$WORK_STATE_DIR" 2>/dev/null && [ -L "$WORK_STATE_DIR" ]; then
    work_verdict 0 "$P5"
    [ "$WORK_RC" -eq 0 ] \
      || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}symlinked-ancestor:rc=$WORK_RC"
  fi
  rm -rf "$WORK_STATE_DIR"
  mv "${WORK_STATE_DIR}.real" "$WORK_STATE_DIR"
fi
eval "$(declare -f _tdd_paths_safe_real | sed '1s/_tdd_paths_safe_real/_tdd_paths_safe/')"
# Source half: the marker test must precede the claim test in BOTH places.
WORK_BODY="$(awk '/^_autopilot_deferred_work_present\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LIB")"
# Compare CHARACTER OFFSETS, not line numbers: the short-circuit spells both
# tests on one `if` line, and a line-number comparison reports them equal and
# can never discriminate. The needles are literal, so nothing has to be escaped
# for a regex either.
work_offset() {
  local pre
  case "$1" in
    *"$2"*) pre="${1%%"$2"*}"; printf '%s' "${#pre}" ;;
    *) printf '' ;;
  esac
}
work_order() {
  local first second
  first="$(work_offset "$3" "$1")"
  second="$(work_offset "$3" "$2")"
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] && return 0
  WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}order/$4:pending=$first,claim=$second"
}
# The short-circuit order pin went with the short-circuit itself: the guard now
# validates both paths in one call, so the marker-before-claim order survives
# only in the ladder, which is the place the rename race could actually be seen.
work_order '[ -f "$pending_file" ]' '[ -f "$claim_file" ]' "$WORK_BODY" ladder
# ...and the leaf-only helper must not come back. A `[ ! -e ] && [ ! -L ]` pair
# ahead of the guard is the defect this arm records, not a style preference, and
# a source test is the only thing that catches its REINTRODUCTION -- a behavioural
# arm can only catch the shapes someone thought to write a fixture for.
case "$WORK_BODY" in
  *_autopilot_path_absent*)
    WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}leaf-only-shortcut-returned" ;;
esac
# The three EXACT-arity guards. Each fails toward BLOCKING, so a relaxation of
# `-eq` to `-ge` -- the exact change the code comments forbid -- left every check
# in this file green. Coverage of an existing guard, not a fixed defect.
GUARD_FAILED=""
guard_blocks arity-three "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" 0 || true
guard_blocks arity-five "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" 0 "$P5" extra || true
_autopilot_deferred_work_present 0 \
  || WORK_FAILED="${WORK_FAILED:+$WORK_FAILED,}work-arity-one-relaxed"
if [ -z "$WORK_FAILED" ] && [ -z "$GUARD_FAILED" ]; then
  check "S7s the work predicate validates both paths in ONE guard call, reports work present under a symlinked ancestor, reads the marker before the claim, keeps all four ladder verdicts, and refuses a wrong arity" PASS
else check "S7s work predicate cost, ancestor safety, read order and arity (failed: $WORK_FAILED${GUARD_FAILED:+ guards=$GUARD_FAILED})" FAIL; fi

# S7u -- `RENDERABLE_STAGES` is a hand copy of the worker's module-scope `STAGES`,
# and the comment at that site says THIS suite compares them. It did not, so the
# claim was false for as long as it stood: the renderer runs in its own `node -e`
# program and cannot see the upstream set, and a guard whose only job is to hold
# when the upstream stops holding must never be looser than it. Both literals are
# extracted from the library SOURCE and compared as sets, in both directions --
# a missing member makes the renderer refuse a stage the state machine accepts,
# and an extra one admits a stage into a model-facing block reason that
# `stateValid` would have rejected.
#
# The `STAGES` needle is anchored at line start: the module-scope declaration is
# unindented while `RENDERABLE_STAGES` is nested, and an unanchored match would
# find the copy and compare it with itself.
STAGE_SETS="$(node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.argv[1], "utf8");
  const grab = (re) => {
    const m = src.match(re);
    if (!m) return null;
    return m[1].match(/"[A-Z_]+"/g)?.map(s => s.slice(1, -1)).sort() ?? [];
  };
  const stages = grab(/^const STAGES = new Set\(\[([^\]]*)\]\)/m);
  const renderable = grab(/const RENDERABLE_STAGES = new Set\(\[([^\]]*)\]\)/);
  if (!stages || !stages.length) { console.log("no-stages-literal"); process.exit(0); }
  if (!renderable || !renderable.length) { console.log("no-renderable-literal"); process.exit(0); }
  const missing = stages.filter(s => !renderable.includes(s));
  const extra = renderable.filter(s => !stages.includes(s));
  if (missing.length || extra.length) {
    console.log(`missing=${missing.join("|") || "-"},extra=${extra.join("|") || "-"}`);
  }
' "$LIB" 2>&1)"
if [ -z "$STAGE_SETS" ]; then
  check "S7u RENDERABLE_STAGES and the module-scope STAGES hold the same members, which is the comparison the renderer's own comment claims this suite performs" PASS
else check "S7u RENDERABLE_STAGES diverges from STAGES ($STAGE_SETS)" FAIL; fi

# S7t -- the claim accessor takes a pre-resolved pending path, and the `.claim`
# suffix is spelled exactly once inside its owning module.
#
# Cost: without the parameter the accessor resolves the project root a SECOND
# time, through `zensu_resolve_project_dir` and its own `node -e`, for a value
# every caller has just computed. The Autopilot fence runs it inside the
# project-wide lease on a path reached at every turn end.
#
# Correctness: an EMPTY argument must REFUSE rather than be treated as omitted.
# A caller passing empty is one whose own resolution failed, and answering
# `.claim` for it would name a file relative to whatever directory the process
# happens to sit in -- a path outside the project the fence then tests.
CLAIM_FAILED=""
CLAIM_OUT="$(zensu_pending_review_claim_file "$TMP/pending-review.json" 2>/dev/null </dev/null)"
[ "$CLAIM_OUT" = "$TMP/pending-review.json.claim" ] \
  || CLAIM_FAILED="${CLAIM_FAILED:+$CLAIM_FAILED,}supplied:$CLAIM_OUT"
# The supplied path must be used VERBATIM -- a value that merely happens to end
# in `.claim` could also come from the accessor resolving the project root and
# ignoring the argument. This path is outside the project root, so only a
# verbatim use can produce it.
case "$CLAIM_OUT" in "$TMP"/*) ;; *) CLAIM_FAILED="${CLAIM_FAILED:+$CLAIM_FAILED,}not-verbatim:$CLAIM_OUT" ;; esac
zensu_pending_review_claim_file "" >/dev/null 2>&1 </dev/null \
  && CLAIM_FAILED="${CLAIM_FAILED:+$CLAIM_FAILED,}empty-accepted"
# Control: omitting the argument entirely must still resolve, or every caller
# outside this module breaks.
CLAIM_DERIVED="$(zensu_pending_review_claim_file 2>/dev/null </dev/null)"
case "$CLAIM_DERIVED" in *.claim) ;; *) CLAIM_FAILED="${CLAIM_FAILED:+$CLAIM_FAILED,}omitted:$CLAIM_DERIVED" ;; esac
# The owning module must spell the suffix exactly ONCE, inside the accessor. A
# hand-spelled copy fails OPEN: adoption RENAMES the marker onto the claim, so a
# reader looking for a drifted name sees neither file and answers "no work"
# while a deferred review is live.
CLAIM_SPELLINGS="$(grep -c '{pf}\.claim\|}\.claim"' "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh")"
[ "$CLAIM_SPELLINGS" -eq 1 ] \
  || CLAIM_FAILED="${CLAIM_FAILED:+$CLAIM_FAILED,}suffix-spellings:$CLAIM_SPELLINGS"
# ... and every site that needs one must call the accessor. Counting only the
# spellings would also pass for a module that stopped resolving a claim at all.
CLAIM_CALLS="$(grep -c 'zensu_pending_review_claim_file "\$pf"' "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh")"
[ "$CLAIM_CALLS" -eq 5 ] \
  || CLAIM_FAILED="${CLAIM_FAILED:+$CLAIM_FAILED,}accessor-calls:$CLAIM_CALLS"
if [ -z "$CLAIM_FAILED" ]; then
  check "S7t the claim accessor honours a pre-resolved path, refuses an empty one, still derives when omitted, and is the module's only spelling of the suffix" PASS
else check "S7t claim accessor contract (failed: $CLAIM_FAILED)" FAIL; fi

# `autopilot_read_workspace` is a READ: it must answer "free" on a project that
# has no state directory without creating one. Only the mkdir side effect
# distinguishes the two storage checks, so nothing else would observe a revert.
P5N="$TMP/read-does-not-create"; mkdir -p "$P5N"
activate_session "$P5N" stop_session_read_only || exit 1
P5N_REAL="$(cd "$P5N" && pwd -P)"
# Binding a session may itself materialize the directory; clear it so the read
# is measured against a project that genuinely has none.
rm -rf "$P5N/.zensu"
autopilot_read_workspace "$P5N_REAL" "$P5N_REAL" >/dev/null 2>&1; RC7N=$?
if [ "$RC7N" -eq 1 ] && [ ! -d "$P5N/.zensu/state" ]; then
  check "S7l reading the workspace of a project with no state directory answers free without creating one" PASS
else check "S7l the workspace read must not create the state directory (rc=$RC7N dir=$( [ -d "$P5N/.zensu/state" ] && echo created || echo absent))" FAIL; fi
# S7l bound a different session; the checks below compare against `$P5`'s key,
# which `HOLD_SELF` was built from, so restore it before they run.
activate_session "$P5" stop_session_owner || exit 1

# The release arm, plus the stderr disclosure that is the only signal a seen
# hold was deliberately not enforced. Capture stderr separately: silence here
# would be indistinguishable from "no run held the tree at all".
ERR7G="$(_autopilot_workspace_hold_blocks_adoption "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" 0 "$P5" 2>&1 >/dev/null)"; RC7G=$?
# The disclosure must NAME the holder: a fixed string cannot be correlated with
# the refusal or `--autopilot-status` output that does name one, which is the
# stated reason the run-id reader exists.
if [ "$RC7G" -ne 0 ] \
  && printf '%s' "$ERR7G" | grep -qF 'no deferred review to interleave with' \
  && printf '%s' "$ERR7G" | grep -qF 'hold_run_foreign' \
  && ! printf '%s' "$ERR7G" | grep -qF '(unnamed)'; then
  check "S7g a foreign holder with no queued marker does not block, and discloses by name that it stood down" PASS
else check "S7g foreign holder without work must release and disclose by name (rc=$RC7G err=$ERR7G)" FAIL; fi

# The renderer's own shape tests, in the rejecting direction. Every other check
# reaches it with `stateValid` output, so loosening either regex is otherwise
# invisible -- and a rejection matters: it makes the fence treat the holder as
# unreadable, which is the fail-closed side.
# The newline case must reach the REGEX, not `JSON.parse`. A raw newline inside
# a JSON string is invalid JSON, so building it with `printf '...\n...'` would
# be rejected one guard too early and the check would pass while the regex was
# unpinned. The single-quoted literal keeps `\n` as the two-character JSON
# escape, which parses cleanly into a runId that really contains a newline.
REND_FAILED=""
rend_rejects() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then REND_FAILED="${REND_FAILED:+$REND_FAILED,}$label"; fi
}
rend_rejects runid-newline _autopilot_workspace_refusal '{"runId":"ok_run\nInjected: line","stage":"PLANNING","ownerSessionId":"xyz"}' '' operator
rend_rejects stage-lowercase _autopilot_workspace_refusal '{"runId":"ok_run","stage":"planning","ownerSessionId":"xyz"}' '' operator
# The stage test must be MEMBERSHIP, not shape. A guard whose only job is to hold
# when the upstream stops holding must not be looser than that upstream:
# `stateValid` gates this field on the closed `STAGES` set, so an uppercase token
# outside it (`IGNORE_PRIOR`, `SEE_BELOW`) reaching a model-facing block reason is
# exactly what a shape-only rule would admit. Unreachable through a valid record
# today -- the inventory refuses one first -- which is precisely why the backstop
# has to be checked directly.
rend_rejects stage-not-a-member _autopilot_workspace_refusal '{"runId":"ok_run","stage":"IGNORE_PRIOR","ownerSessionId":"xyz"}' '' operator
# The RUN-ID reader's own shape test, in the rejecting direction. It had no
# executed case at all, and its output is interpolated straight into the stderr
# disclosure the release arm prints -- so a loosened regex there puts a newline
# into a line the operator reads as one diagnostic.
rend_rejects runid-reader-newline _autopilot_holder_run_id '{"runId":"ok_run\nInjected: line","stage":"PLANNING"}'
rend_rejects runid-reader-absent _autopilot_holder_run_id '{"stage":"PLANNING"}'
rend_rejects runid-reader-arity _autopilot_holder_run_id '{"runId":"ok_run"}' extra
rend_rejects owner-spaced _autopilot_holder_owner '{"ownerSessionId":"has space"}'
rend_rejects owner-leading-underscore _autopilot_holder_owner '{"ownerSessionId":"_leading"}'
# The audience is REQUIRED and closed: an omission or an unknown value must
# refuse rather than fall through to the form quoting the audited command.
rend_rejects audience-omitted _autopilot_workspace_refusal '{"runId":"ok_run","stage":"PLANNING","ownerSessionId":"xyz"}'
rend_rejects audience-unknown _autopilot_workspace_refusal '{"runId":"ok_run","stage":"PLANNING","ownerSessionId":"xyz"}' '' Operator
_autopilot_workspace_refusal '{"runId":"ok_run","stage":"PLANNING","ownerSessionId":"xyz"}' '' operator >/dev/null 2>&1 \
  || REND_FAILED="${REND_FAILED:+$REND_FAILED,}positive-control"
# `identifier` admits `.` and `:` in an ownerSessionId, so the reader must too --
# a narrower class would report a product-minted record as unreadable and block.
_autopilot_holder_owner '{"ownerSessionId":"a.b:c-d_e"}' >/dev/null 2>&1 \
  || REND_FAILED="${REND_FAILED:+$REND_FAILED,}owner-dotted-control"
# Control for the run-id reader: without it every rejection above is satisfied by
# a reader that refuses everything.
[ "$(_autopilot_holder_run_id '{"runId":"ok_run","stage":"PLANNING"}' 2>/dev/null)" = ok_run ] \
  || REND_FAILED="${REND_FAILED:+$REND_FAILED,}runid-reader-control"
if [ -z "$REND_FAILED" ]; then
  check "S7j the holder renderers refuse a newline in runId, a lowercase stage and a spaced owner, and still accept a valid record" PASS
else check "S7j holder renderer shape tests must reject malformed fields (failed: $REND_FAILED)" FAIL; fi

# S7p — the piped readers must survive a record that arrives in MORE THAN ONE
# stdin chunk without corrupting it. A `data` handler that does `input += chunk`
# coerces each Buffer on its own, so a UTF-8 sequence straddling the boundary
# decodes to U+FFFD.
#
# **State the impact precisely, because it was MEASURED and it is NARROWER than
# the finding that prompted it.** U+FFFD is a legal character inside a JSON
# string, so `JSON.parse` still SUCCEEDS, and every field these three readers
# emit (`ownerSessionId`, `runId`, `stage`) is ASCII-constrained by its own shape
# test and therefore cannot be corrupted. Measured on the probe below: 6
# replacement characters land in `projectRoot` while the owner and run id come
# back intact. So this is NOT a spurious "holder unreadable" block -- it is
# silent corruption of a field none of the three readers returns today. The fix
# is one line and unambiguously correct, and it matters because the reader idiom
# is shared and the next field routed through it may be one that IS emitted.
#
# That measurement is also why this cannot be an output assertion: the correct
# and the defective code agree on every value these readers expose. It drives
# the IDIOM instead, with an unguarded control proving the probe really crosses
# a pipe read on this host, and pairs that with a source pin so a reader added
# later without the call is caught. Both halves are load-bearing -- the
# behavioural half proves the rule is real, the source half proves every reader
# follows it.
ENCODING_FAILED=""
ENCODING_PROBE="$(node -e '
  const pad = "ä".repeat(120000);
  process.stdout.write(JSON.stringify({
    runId: "hold_run_wide", stage: "PLANNING", ownerSessionId: "scv1_widerecord",
    projectRoot: "/tmp/" + pad
  }));
')"
encoding_damage() {
  printf '%s' "$ENCODING_PROBE" | node -e "
    let input = \"\";
    ${1}
    process.stdin.on(\"data\", chunk => { input += chunk; });
    process.stdin.on(\"end\", () => {
      let value;
      try { value = JSON.parse(input); } catch (_) { process.stdout.write(\"parse-failed\"); return; }
      process.stdout.write(String((String(value.projectRoot || \"\").match(/�/g) || []).length));
    });
  "
}
ENCODING_GUARDED_DAMAGE="$(encoding_damage 'process.stdin.setEncoding("utf8");')"
[ "$ENCODING_GUARDED_DAMAGE" = "0" ] \
  || ENCODING_FAILED="${ENCODING_FAILED:+$ENCODING_FAILED,}guarded-damaged:$ENCODING_GUARDED_DAMAGE"
# Control: the UNguarded idiom must damage the same record. Without this the
# behavioural half would pass on a host whose pipe delivers the probe in one
# read, proving nothing at all.
ENCODING_CONTROL_DAMAGE="$(encoding_damage '')"
case "$ENCODING_CONTROL_DAMAGE" in
  ""|0|parse-failed) ENCODING_FAILED="${ENCODING_FAILED:+$ENCODING_FAILED,}control-undamaged:$ENCODING_CONTROL_DAMAGE" ;;
esac
# Source half: every piped reader in the library must carry the call.
ENCODING_PIPED="$(grep -c 'process.stdin.on("data"' "$LIB")"
ENCODING_GUARDED="$(grep -c 'process.stdin.setEncoding("utf8")' "$LIB")"
[ "$ENCODING_PIPED" -gt 0 ] && [ "$ENCODING_GUARDED" -eq "$ENCODING_PIPED" ] \
  || ENCODING_FAILED="${ENCODING_FAILED:+$ENCODING_FAILED,}unguarded-readers:$ENCODING_GUARDED/$ENCODING_PIPED"
if [ -z "$ENCODING_FAILED" ]; then
  check "S7p every piped holder reader sets a stdin encoding, and the guarded idiom round-trips a multi-chunk record the unguarded one corrupts" PASS
else check "S7p multi-chunk stdin must not corrupt the record (failed: $ENCODING_FAILED)" FAIL; fi

# S7q -- the PUBLISHER's own guards, and the render accounting behind them. Both
# guard arms returned 0, so a caller could not tell a refusal from a successful
# publish; and the two forms were rendered INDEPENDENTLY for the operator
# audience, so a transient spawn failure on either one left the operator line
# naming the run while the block reason fell back to the unnamed sentence --
# the two channels contradicting each other one stream apart.
#
# The model form is therefore rendered FIRST and exactly once. The operator form
# is attempted only when that succeeded, and falls back to the model text when it
# does not: a degradation (the audited command is withheld) that cannot
# contradict, because it is the same sentence the block reason carries.
#
# Every probe writes its streams to FILES rather than a command substitution.
# The published sentence is a shell variable this function assigns, and a
# substitution would run the assignment in a subshell -- the check would then
# read the seeded value back and pass no matter what the publisher did.
PUB_FAILED=""
eval "$(declare -f _autopilot_workspace_refusal | sed '1s/_autopilot_workspace_refusal/_autopilot_workspace_refusal_real/')"
pub_probe() {
  ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT="seeded"
  PUB_RC=0
  _autopilot_publish_workspace_refusal "$@" >"$TMP/pub-out" 2>"$TMP/pub-err" || PUB_RC=$?
  PUB_OUT="$(cat "$TMP/pub-out")"
  PUB_ERR="$(cat "$TMP/pub-err")"
}
pub_silent_refusal() {
  [ "$PUB_RC" -ne 0 ] && [ -z "$PUB_OUT" ] && [ -z "$PUB_ERR" ] \
    && [ -z "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" ] && return 0
  PUB_FAILED="${PUB_FAILED:+$PUB_FAILED,}$1:rc=$PUB_RC,out=$PUB_OUT,err=$PUB_ERR,text=$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT"
}
# Arity: a two-argument call names no audience, so it must refuse rather than
# pick a form. An omission is the surviving axis on which a new call site could
# silently emit the runnable `--confirm` invocation.
pub_probe "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY"
pub_silent_refusal arity
# Audience: an unrecognized value is a typo, never a request for a default.
pub_probe "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" Operator
pub_silent_refusal audience
# Render accounting, through a stub that records one line per call so the ORDER
# is observable too -- the model form must come FIRST, which is what lets its
# failure short-circuit the operator one.
_autopilot_workspace_refusal() {
  printf '%s\n' "${3:-(none)}" >>"$TMP/pub-calls"
  printf 'rendered-%s\n' "${3:-none}"
}
: >"$TMP/pub-calls"
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT=""
_autopilot_publish_workspace_refusal "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" operator 2>/dev/null
PUB_MODEL_CALLS="$(grep -c '^model$' "$TMP/pub-calls" || true)"
PUB_FIRST_CALL="$(head -1 "$TMP/pub-calls")"
[ "$PUB_MODEL_CALLS" = 1 ] && [ "$PUB_FIRST_CALL" = model ] \
  || PUB_FAILED="${PUB_FAILED:+$PUB_FAILED,}model-renders:$PUB_MODEL_CALLS,first=$PUB_FIRST_CALL"
# A failed MODEL render must leave BOTH channels silent, not just the published
# one. Without the short-circuit the operator form still renders and stderr names
# a run the block reason cannot.
_autopilot_workspace_refusal() {
  printf '%s\n' "${3:-(none)}" >>"$TMP/pub-calls"
  [ "${3:-}" = model ] && return 1
  printf 'rendered-%s\n' "${3:-none}"
}
: >"$TMP/pub-calls"
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT="seeded"
_autopilot_publish_workspace_refusal "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" operator \
  >"$TMP/pub-out" 2>"$TMP/pub-err"
PUB_FAIL_ERR="$(cat "$TMP/pub-err")"
[ -z "$PUB_FAIL_ERR" ] && [ -z "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" ] \
  && ! grep -qx operator "$TMP/pub-calls" \
  || PUB_FAILED="${PUB_FAILED:+$PUB_FAILED,}model-failure:err=$PUB_FAIL_ERR,text=$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT,calls=$(tr '\n' ' ' <"$TMP/pub-calls")"
eval "$(declare -f _autopilot_workspace_refusal_real | sed '1s/_autopilot_workspace_refusal_real/_autopilot_workspace_refusal/')"
# Positive control on the RESTORED renderer: a foreign holder still publishes the
# model form and still prints the audited operator form on stderr. Without it
# every assertion above is satisfied by a publisher that does nothing at all.
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT=""
_autopilot_publish_workspace_refusal "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" operator \
  >"$TMP/pub-out" 2>"$TMP/pub-err"
PUB_OK_ERR="$(cat "$TMP/pub-err")"
printf '%s' "$PUB_OK_ERR" | grep -qF -- '--autopilot-release --run hold_run_foreign --confirm' \
  && printf '%s' "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" | grep -qF '/zensu:autopilot-release' \
  && ! printf '%s' "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" | grep -qF -- '--confirm' \
  || PUB_FAILED="${PUB_FAILED:+$PUB_FAILED,}positive-control:err=$PUB_OK_ERR,text=$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT"
if [ -z "$PUB_FAILED" ]; then
  check "S7q the publisher refuses a wrong arity and an unknown audience non-zero and silently, renders the model form once and first, and leaves both channels silent when that render fails" PASS
else check "S7q publisher guards must refuse non-zero and render the model form exactly once (failed: $PUB_FAILED)" FAIL; fi

# S7r -- clear-on-entry, at BOTH public entry points. The published sentence is a
# module-scope variable the Stop hook reads by name after the fence returns, so a
# sentence left over from an earlier refusal would be re-read as though it named
# the run this call judged -- pointing a release command at the wrong run.
#
# CHARACTERIZATION, not a fixed defect: both entry points already clear first and
# this check found no RED. It exists because the property is invisible at every
# call site and is defended only by the STATEMENT ORDER inside two functions --
# moving the clear one line down, below a guard, silently reinstates the leak.
#
# The probe seeds the variable and then drives each entry point through its
# EARLIEST refusal (a wrong arity). That is the discriminating shape: the arity
# guard is the first thing after the clear, so a check that only exercised a
# successful call could not tell a first-line clear from a late one.
ENTRY_FAILED=""
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT="stale sentence from an earlier hold"
autopilot_begin_standalone_tdd >/dev/null 2>&1
[ -z "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" ] \
  || ENTRY_FAILED="${ENTRY_FAILED:+$ENTRY_FAILED,}begin:$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT"
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT="stale sentence from an earlier hold"
autopilot_adopt_pending_review >/dev/null 2>&1
[ -z "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" ] \
  || ENTRY_FAILED="${ENTRY_FAILED:+$ENTRY_FAILED,}adopt:$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT"
# Source half: the clear must be the FIRST statement of each entry point, not
# merely present somewhere in it. The behavioural half above proves it precedes
# the arity guard; this proves nothing was inserted ahead of it either.
for ENTRY_FN in autopilot_begin_standalone_tdd autopilot_adopt_pending_review; do
  ENTRY_FIRST="$(awk -v fn="$ENTRY_FN" '$0 == fn "() {" {getline; print; exit}' "$LIB")"
  [ "$ENTRY_FIRST" = '  ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT=""' ] \
    || ENTRY_FAILED="${ENTRY_FAILED:+$ENTRY_FAILED,}first-stmt/$ENTRY_FN:$ENTRY_FIRST"
done
# Control: the seed really survives a call that is NOT one of the two entry
# points. Without it the check would pass on a harness that clears the variable
# for some unrelated reason, proving nothing about either function.
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT="stale sentence from an earlier hold"
_autopilot_holder_owner "$HOLD_FOREIGN" >/dev/null 2>&1
[ -n "$ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT" ] \
  || ENTRY_FAILED="${ENTRY_FAILED:+$ENTRY_FAILED,}seed-control"
ZENSU_AUTOPILOT_WORKSPACE_HOLD_TEXT=""
if [ -z "$ENTRY_FAILED" ]; then
  check "S7r both public entry points clear the published refusal before their own arity guard, so a stale sentence can never be re-read" PASS
else check "S7r clear-on-entry must precede every return path (failed: $ENTRY_FAILED)" FAIL; fi

# The own-run remedy: the renderer must NOT quote the release command when the
# holder belongs to the calling session, because that verb skips its
# self-release guard in exactly that state.
OWN7K="$(_autopilot_workspace_refusal "$HOLD_SELF" "$ZENSU_SESSION_KEY" operator 2>/dev/null)"
OWN7K_MODEL="$(_autopilot_workspace_refusal "$HOLD_SELF" "$ZENSU_SESSION_KEY" model 2>/dev/null)"
FOREIGN7K="$(_autopilot_workspace_refusal "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" operator 2>/dev/null)"
# The MODEL form must never carry a ready-to-run release invocation: --confirm is
# the consent control, and a complete command hands the model a way around it.
MODEL7K="$(_autopilot_workspace_refusal "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" model 2>/dev/null)"
# The exclusion needle is the BARE stem: `--autopilot-release` is not a substring
# of `/zensu:autopilot-release`, so an own-run render that offered the guided form
# would have passed the narrower spelling. Both audiences are checked.
if printf '%s' "$OWN7K" | grep -qF 'belongs to this session' \
  && printf '%s' "$OWN7K_MODEL" | grep -qF 'belongs to this session' \
  && ! printf '%s' "$OWN7K" | grep -qF 'autopilot-release' \
  && ! printf '%s' "$OWN7K_MODEL" | grep -qF 'autopilot-release' \
  && printf '%s' "$OWN7K_MODEL" | grep -qF 'finish or repair that run' \
  && printf '%s' "$FOREIGN7K" | grep -qF -- '--autopilot-release --run hold_run_foreign --confirm' \
  && printf '%s' "$MODEL7K" | grep -qF 'hold_run_foreign' \
  && printf '%s' "$MODEL7K" | grep -qF 'run /zensu:autopilot-release' \
  && ! printf '%s' "$MODEL7K" | grep -qF -- '--confirm' \
  && ! printf '%s' "$MODEL7K" | grep -qF 'zensu-log.sh'; then
  check "S7k the operator form quotes the audited command, the model form names only the guided skill, and an own-run holder gets neither" PASS
else check "S7k own-run refusal must withhold the release command (own=$OWN7K own_model=$OWN7K_MODEL foreign=$FOREIGN7K model=$MODEL7K)" FAIL; fi

# The holder PREFERENCE decides which of several holders the fence judges, and
# the own-run arm rests on it. A record carrying no `workspaceRoot` holds every
# tree in its project, so a legacy foreign one can sort ahead of this session's
# own live run; without the preference the fence would weigh the foreign record
# and release while an own generation is still active.
# The second holder is hand-written rather than begun: `autopilot_begin_run`
# refuses a second run over the same tree, which is the very rule that makes a
# legacy record — one carrying no `workspaceRoot`, and so holding every tree in
# its project — the realistic way two holders coexist.
P5W="$TMP/holder-preference"; start "$P5W" zz_own_run stop_session_pref_own
OWN5W="$(autopilot_run_file zz_own_run "$P5W")"
LEGACY5W="$(dirname "$OWN5W")/$(basename "$OWN5W" | sed 's/zz_own_run/aa_legacy_foreign/')"
node -e '
  const fs=require("fs");
  const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  j.runId="aa_legacy_foreign";
  j.ownerSessionId="scv1_"+"f".repeat(64);
  delete j.workspaceRoot;
  fs.writeFileSync(process.argv[2], JSON.stringify(j, null, 2));
' "$OWN5W" "$LEGACY5W"
activate_session "$P5W" stop_session_pref_own || exit 1
P5W_REAL="$(cd "$P5W" && pwd -P)"
PREF_OWN="$(_autopilot_read_workspace_critical "$P5W_REAL" "$P5W_REAL" "$ZENSU_SESSION_KEY" 2>/dev/null | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).runId')"
PREF_NONE="$(_autopilot_read_workspace_critical "$P5W_REAL" "$P5W_REAL" 2>/dev/null | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).runId')"
if [ "$PREF_OWN" = zz_own_run ] && [ "$PREF_NONE" = aa_legacy_foreign ]; then
  check "S7h the holder preference reports this session's own run where sort order would report the legacy foreign one" PASS
else check "S7h holder preference must outrank sort order (preferred=$PREF_OWN unpreferenced=$PREF_NONE)" FAIL; fi

# The same property through the PUBLIC wrapper. S7h drives the private critical
# function, so without this the wrapper could stop forwarding the argument with
# every check still green. Note what this does NOT claim: after the Stop hook's
# re-read was deleted, the wrapper's preference parameter has no production
# caller at all -- `post-review-tdd-delegate.sh` passes one argument. This guards
# it for the next caller, not a live path.
PUB_OWN="$(autopilot_read_workspace "$P5W_REAL" "$P5W_REAL" "$ZENSU_SESSION_KEY" 2>/dev/null | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).runId' 2>/dev/null)"
PUB_NONE="$(autopilot_read_workspace "$P5W_REAL" "$P5W_REAL" 2>/dev/null | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).runId' 2>/dev/null)"
if [ "$PUB_OWN" = zz_own_run ] && [ "$PUB_NONE" = aa_legacy_foreign ]; then
  check "S7h2 the public workspace read forwards the holder preference the Stop hook passes it" PASS
else check "S7h2 the public wrapper must forward the preference (preferred=$PUB_OWN unpreferenced=$PUB_NONE)" FAIL; fi

# The unnamed fallback is unreachable from a fixture — the fence blocks for every
# holder it cannot read, and a `stateValid` record always satisfies the
# renderer's shape tests — so a SOURCE pin is the only available control. The
# hazard its own comment names is a future edit appending a release command
# there, which would otherwise ship green.
FALLBACK_LINE="$(grep -F 'the holding run could not be identified from here' "$PLUGIN_DIR/hooks/stop-chain-enforcer.sh" | head -1)"
if [ -n "$FALLBACK_LINE" ] \
  && ! printf '%s' "$FALLBACK_LINE" | grep -qF -- '--confirm' \
  && ! printf '%s' "$FALLBACK_LINE" | grep -qF 'zensu-log.sh' \
  && printf '%s' "$FALLBACK_LINE" | grep -qF 'another session' \
  && printf '%s' "$FALLBACK_LINE" | grep -qF "this session's own run"; then
  check "S7n the unnamed fallback names both ownership possibilities and quotes no runnable release" PASS
else check "S7n the unnamed fallback must not gain a release command (line=$FALLBACK_LINE)" FAIL; fi

# The rc=4 arm must derive its sentence from the published value and take no
# second holder read: a read after the fence returned is a fresh chance to name
# a run the fence never judged, with a remedy that cancels.
if ! grep -qE 'autopilot_read_workspace|_autopilot_read_workspace_critical|_autopilot_workspace_refusal' "$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"; then
  check "S7n2 the Stop hook derives the holder sentence from the published value and re-reads nothing" PASS
else check "S7n2 the rc=4 arm must not re-read the holder" FAIL; fi

# `skills/autopilot-release/SKILL.md` teaches the model to recognize the own-run
# case by two literals of this renderer. Nothing compared them, so a reword of
# either side would leave the model reading an own-run hold as foreign — and
# pointing a cancel at this session's own live generation.
SKILL_OWN="$PLUGIN_DIR/skills/autopilot-release/SKILL.md"
# Build the holder from the CURRENT session key: earlier checks re-bind the
# session, so `$HOLD_SELF` was minted against a key that is no longer active and
# the own-run branch would not fire.
HOLD_SELF_NOW="$(printf '{"runId":"hold_run_self","stage":"PLANNING","ownerSessionId":"%s"}' "$ZENSU_SESSION_KEY")"
OWN_RENDER="$(_autopilot_workspace_refusal "$HOLD_SELF_NOW" "$ZENSU_SESSION_KEY" model 2>/dev/null)"
# The skill teaches the FOREIGN case by a literal too, and it is the one the
# model keys on to decide that a release IS appropriate. Pinning only the own-run
# side left the more consequential direction free to drift: a reworded foreign
# form would stop matching, the model would fall through to the own-run reading,
# and a genuinely foreign hold would never be released.
FOREIGN_RENDER="$(_autopilot_workspace_refusal "$HOLD_FOREIGN" "$ZENSU_SESSION_KEY" model 2>/dev/null)"
SKILL_OK=1
for needle in 'which belongs to this session' 'finish or repair that run'; do
  printf '%s' "$OWN_RENDER" | grep -qF "$needle" || SKILL_OK=0
  grep -qF "$needle" "$SKILL_OWN" || SKILL_OK=0
done
for needle in 'run /zensu:autopilot-release'; do
  printf '%s' "$FOREIGN_RENDER" | grep -qF "$needle" || SKILL_OK=0
  grep -qF "$needle" "$SKILL_OWN" || SKILL_OK=0
done
# ... and the two recognizers must stay DISJOINT, or keying on either one reads
# both cases the same way.
printf '%s' "$FOREIGN_RENDER" | grep -qF 'which belongs to this session' && SKILL_OK=0
printf '%s' "$OWN_RENDER" | grep -qF 'run /zensu:autopilot-release' && SKILL_OK=0
if [ "$SKILL_OK" -eq 1 ]; then
  check "S7o every own-run literal the release skill teaches is one the renderer actually emits" PASS
else check "S7o the skill's own-run recognizer must match the renderer (render=$OWN_RENDER)" FAIL; fi

# The `begin` worker mode emits its own copy of the foreign sentence. Nothing
# compared the two, so a reword of the renderer left them silently divergent --
# and the worker copy is what a MODEL sees when `--autopilot-begin` refuses,
# which is why it is compared against the renderer's MODEL form.
TWIN_RENDERER="$(_autopilot_workspace_refusal '{"runId":"twin_run","stage":"PLANNING","ownerSessionId":"scv1_deadbeef"}' '' model 2>/dev/null)"
TWIN_WORKER="$(grep -A 2 'workspace held by nonterminal run \${workspaceHolder.runId}' "$LIB" \
  | sed -e 's/^ *+ *//' -e 's/^ *//' -e 's/`//g' -e 's/\${workspaceHolder.runId}/twin_run/g' -e 's/\${workspaceHolder.stage}/PLANNING/g' \
  | tr -d '\n' | sed -e 's/^fail(4, *//' -e 's/);* *$//' -e 's/^ *//')"
if [ -n "$TWIN_RENDERER" ] && [ -n "$TWIN_WORKER" ] \
  && [ "$(printf '%s' "$TWIN_RENDERER" | tr -d '\n')" = "$TWIN_WORKER" ]; then
  check "S7m the begin worker's refusal sentence is byte-identical to the renderer's foreign wording" PASS
else check "S7m the two refusal spellings must not drift (renderer=$TWIN_RENDERER worker=$TWIN_WORKER)" FAIL; fi

# CONTAINMENT, the premise the refusal states to the user. Every fixture above
# is a plain directory, so holder and stopper resolve the SAME workspace key and
# only equality is exercised. Here the run drives a git worktree NESTED under the
# project, and the Stop comes from the containing tree — the shape that produced
# the reported defect. Both directions of the A/B run in this one tree.
P5C="$TMP/containment"
mkdir -p "$P5C" && ( cd "$P5C" && git init -q . && git -c user.email=a@b -c user.name=t commit -q --allow-empty -m base ) >/dev/null 2>&1
P5C_REAL="$(cd "$P5C" && pwd -P)"
NESTED5C="$P5C_REAL/nested-wt"
( cd "$P5C_REAL" && git worktree add -q -b nested-branch "$NESTED5C" ) >/dev/null 2>&1
if ! command -v git >/dev/null 2>&1 || [ ! -d "$NESTED5C" ]; then
  check "S7i containment fixture needs git and a usable worktree — environment, not product" FAIL
else
  activate_session "$P5C" stop_session_contain_owner || exit 1
  autopilot_begin_run contain_run "$ZENSU_SESSION_KEY" "$P5C" false true "$NESTED5C" >/dev/null
  RF5C="$(autopilot_run_file contain_run "$P5C")"
  # Anti-vacuity: without these the fixture passes under plain EQUALITY. If the
  # workspace override were ignored the run would record the project root, the
  # holder would hold its own tree by contains(x,x), and every assertion below
  # would still pass while the containment branch was never taken.
  TOP_ROOT5C="$(cd "$P5C_REAL" && git rev-parse --show-toplevel 2>/dev/null)"
  TOP_NEST5C="$(cd "$NESTED5C" && git rev-parse --show-toplevel 2>/dev/null)"
  S7I_PREMISE=1
  [ -n "$TOP_ROOT5C" ] && [ -n "$TOP_NEST5C" ] && [ "$TOP_ROOT5C" != "$TOP_NEST5C" ] || S7I_PREMISE=0
  field_ok "$RF5C" 'typeof j.workspaceRoot==="string" && j.workspaceRoot!==j.projectRoot' || S7I_PREMISE=0
  HELD5C="$(autopilot_read_workspace "$P5C_REAL" "$P5C_REAL" 2>/dev/null | node -pe 'JSON.parse(require("fs").readFileSync(0,"utf8")).runId' 2>/dev/null)"
  BEFORE5C="$(digest "$RF5C")"
  OUT7C="$(invoke "$P5C" foreign_contain_session)"; RC7C=$?
  activate_session "$P5C" stop_session_contain_owner || exit 1
  CLAUDE_PROJECT_DIR="$P5C" bash "$LOG" --pending-review --files 'src/contained.ts' \
    --summary 'review queued in the containing tree' >/dev/null
  OUT7C2="$(invoke "$P5C" foreign_contain_session)"
  if [ "$S7I_PREMISE" -eq 1 ] && [ "$HELD5C" = contain_run ] \
    && [ "$RC7C" -eq 0 ] && [ -z "$OUT7C" ] \
    && [ "$(printf '%s' "$OUT7C2" | decision)" = block ] \
    && printf '%s' "$OUT7C2" | grep -qF 'contain_run' \
    && printf '%s' "$OUT7C2" | grep -qF 'run /zensu:autopilot-release' \
    && [ "$BEFORE5C" = "$(digest "$RF5C")" ]; then
    check "S7i a run driving a NESTED worktree holds the containing tree: release with nothing queued, refusal naming it once a marker exists" PASS
  else check "S7i containment hold must release without work and refuse with it (premise=$S7I_PREMISE held=$HELD5C rc=$RC7C)" FAIL; fi
fi

P5T="$TMP/owner-terminal"; start "$P5T" stop_run_owner_terminal stop_session_owner_terminal
autopilot_apply_event stop_run_owner_terminal cancel-owner-terminal CANCEL '{}' "$P5T" >/dev/null
OUT7T="$(invoke "$P5T" foreign_terminal_session)"
[ -z "$OUT7T" ] \
  && check "S7b foreign-session terminal permits Stop before owner mismatch" PASS \
  || check "S7b foreign-session terminal permits Stop" FAIL
OUT7TE="$(invoke "$P5T" foreign_terminal_session "$TMP/missing.json" '' off)"
[ -z "$OUT7TE" ] \
  && check "S7c foreign-session terminal also permits the explicit escape path" PASS \
  || check "S7c foreign terminal escape permits Stop" FAIL

P6="$TMP/corrupt"; start "$P6" stop_run_corrupt stop_session_corrupt
AF6="$(pointer "$P6" stop_session_corrupt)"
AF6="$AF6" node -e 'const fs=require("fs"),p=process.env.AF6,j=JSON.parse(fs.readFileSync(p));j.extra=true;fs.writeFileSync(p,JSON.stringify(j))'
OUT8="$(invoke "$P6" stop_session_corrupt)"
if [ "$(printf '%s' "$OUT8" | decision)" = block ] && printf '%s' "$OUT8" | grep -qi 'corrupt'; then
  check "S8 corrupt active pointer fails closed" PASS
else check "S8 corrupt active pointer fails closed" FAIL; fi

P6B="$TMP/dangling"; start "$P6B" stop_run_dangling stop_session_dangling
rm -f "$(autopilot_run_file stop_run_dangling "$P6B")"
OUT8B="$(invoke "$P6B" stop_session_dangling)"
if [ "$(printf '%s' "$OUT8B" | decision)" = block ] && printf '%s' "$OUT8B" | grep -qi 'corrupt'; then
  check "S8b dangling active pointer fails closed instead of looking absent" PASS
else check "S8b dangling active pointer fails closed" FAIL; fi

P6D="$TMP/orphan-no-pointer"; start "$P6D" stop_run_orphan stop_session_orphan
rm -f "$(pointer "$P6D" stop_session_orphan)"
OUT8D="$(invoke "$P6D" stop_session_orphan)"
if [ "$(printf '%s' "$OUT8D" | decision)" = block ] && printf '%s' "$OUT8D" | grep -qi 'corrupt'; then
  check "S8d nonterminal run without a pointer blocks Stop" PASS
else check "S8d orphan nonterminal run cannot look absent" FAIL; fi

# Model the exact adoption race: the initial locked read reports absent, the
# adoption lease stays contended, and its descriptor-backed fallback proves a
# nonterminal run is active. That proof must block this Stop directly; a second
# contended read must never turn the active generation back into "absent".
P6G="$TMP/adoption-active-contention"; start "$P6G" stop_run_contention stop_session_contention
RF6G="$(autopilot_run_file stop_run_contention "$P6G")"
BEFORE8G="$(digest "$RF6G")"
CONTENTION_PLUGIN="$TMP/adoption-contention-plugin"; copy_runtime "$CONTENTION_PLUGIN"
CONTENTION_PLUGIN="$(cd "$CONTENTION_PLUGIN" && pwd -P)"
CONTENTION_STATE_LIB="$CONTENTION_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'autopilot_read_active() { printf '\''read\n'\'' >> "$ZENSU_CONTENTION_READ_MARKER"; return 1; }' \
  '_autopilot_locked_run() { printf '\''lock\n'\'' >> "$ZENSU_CONTENTION_LOCK_MARKER"; return 1; }' \
  > "$CONTENTION_STATE_LIB"
bind_runtime_session "$CONTENTION_PLUGIN" "$P6G" stop_session_contention adoption-contention
OUT8G="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_contention"}' \
  | CLAUDE_PROJECT_DIR="$P6G" CLAUDE_PLUGIN_ROOT="$CONTENTION_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" \
    ZENSU_CONTENTION_READ_MARKER="$TMP/adoption-contention-read" \
    ZENSU_CONTENTION_LOCK_MARKER="$TMP/adoption-contention-lock" \
    bash "$CONTENTION_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
AFTER8G="$(digest "$RF6G")"
if [ "$(printf '%s' "$OUT8G" | decision)" = block ] \
  && printf '%s' "$OUT8G" | grep -qF 'nonterminal durable Autopilot run holds this working tree' \
  && printf '%s' "$OUT8G" | grep -qF 'stop_run_contention' \
  && printf '%s' "$OUT8G" | grep -qF 'belongs to this session' \
  && ! printf '%s' "$OUT8G" | grep -qF 'autopilot-release' \
  && [ -s "$TMP/adoption-contention-read" ] \
  && [ -s "$TMP/adoption-contention-lock" ] \
  && [ "$BEFORE8G" = "$AFTER8G" ]; then
  check "S8g active Outer proof cannot degrade to absent after adoption contention" PASS
else check "S8g adoption contention must fail closed on the proven active Outer" FAIL; fi

# The same contention path, but the holder belongs to ANOTHER session and no
# deferred review is queued. S8g proves the own-generation arm still fails
# closed; this is the only fixture that reaches the contention fence's release
# arm at all, so without it that arm could be deleted with every suite green.
P6H="$TMP/adoption-foreign-contention"
start "$P6H" stop_run_foreign_contention stop_session_foreign_owner
RF6H="$(autopilot_run_file stop_run_foreign_contention "$P6H")"
BEFORE8H="$(digest "$RF6H")"
bind_runtime_session "$CONTENTION_PLUGIN" "$P6H" stop_session_foreign_stopper foreign-contention
OUT8H="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_foreign_stopper"}' \
  | CLAUDE_PROJECT_DIR="$P6H" CLAUDE_PLUGIN_ROOT="$CONTENTION_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" \
    ZENSU_CONTENTION_READ_MARKER="$TMP/foreign-contention-read" \
    ZENSU_CONTENTION_LOCK_MARKER="$TMP/foreign-contention-lock" \
    bash "$CONTENTION_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
AFTER8H="$(digest "$RF6H")"
if [ -z "$OUT8H" ] \
  && [ -s "$TMP/foreign-contention-lock" ] \
  && [ "$BEFORE8H" = "$AFTER8H" ]; then
  check "S8h contended foreign hold with nothing queued releases without mutating the owner's run" PASS
else check "S8h contended foreign hold must release when nothing is pending (out=$OUT8H lock=$( [ -s "$TMP/foreign-contention-lock" ] && echo yes || echo no) digest_changed=$( [ "$BEFORE8H" = "$AFTER8H" ] && echo no || echo yes))" FAIL; fi

# The contention fence's foreign-holder-WITH-WORK arm: S8h covers its release
# arm and S8g its own-run arm, so without this the rc=4 branch on that path had
# no executed case at all. Same fixture as S8h plus a queued marker.
activate_session "$P6H" stop_session_foreign_owner || exit 1
CLAUDE_PROJECT_DIR="$P6H" bash "$LOG" --pending-review --files 'src/contended-pending.ts' \
  --summary 'review queued while a contended foreign hold stands' >/dev/null
PF6H="$P6H/.zensu/state/pending-review.json"
BEFORE8J="$(digest "$RF6H")"
bind_runtime_session "$CONTENTION_PLUGIN" "$P6H" stop_session_foreign_stopper foreign-contention-work
OUT8J="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_foreign_stopper"}' \
  | CLAUDE_PROJECT_DIR="$P6H" CLAUDE_PLUGIN_ROOT="$CONTENTION_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" \
    ZENSU_CONTENTION_READ_MARKER="$TMP/foreign-contention-work-read" \
    ZENSU_CONTENTION_LOCK_MARKER="$TMP/foreign-contention-work-lock" \
    bash "$CONTENTION_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT8J" | decision)" = block ] \
  && [ -s "$TMP/foreign-contention-work-lock" ] \
  && printf '%s' "$OUT8J" | grep -qF 'stop_run_foreign_contention' \
  && printf '%s' "$OUT8J" | grep -qF 'run /zensu:autopilot-release' \
  && ! printf '%s' "$OUT8J" | grep -qF -- '--confirm' \
  && [ -f "$PF6H" ] \
  && [ "$BEFORE8J" = "$(digest "$RF6H")" ]; then
  check "S8j the contended foreign hold still refuses once a review is queued, naming the run without a runnable cancel" PASS
else check "S8j contended foreign hold with work must refuse (out=$OUT8J marker=$( [ -f "$PF6H" ] && echo present || echo gone))" FAIL; fi

# S8k -- the SECOND contention fence's publish call. S8g, S8h and S8j all return
# at the FIRST fence, so the rc=4 branch below `tdd_pending_review_owned_by_other`
# had no executed case anywhere: it could be deleted, taking the run id off both
# channels, with every suite still green.
#
# Reaching it needs the two occupancy reads to DISAGREE -- the first answering
# "free" and the second finding a holder. That is the run-to-pointer publication
# window the fence's own header names, and it cannot be produced by timing, so
# the read is stubbed to answer free exactly once and hold thereafter.
# `tdd_pending_review_owned_by_other` is stubbed to succeed because a proven
# foreign claim is the precondition of that branch: it is the state in which the
# fence refuses unconditionally.
SECOND_PLUGIN="$TMP/second-fence-plugin"; copy_runtime "$SECOND_PLUGIN"
SECOND_PLUGIN="$(cd "$SECOND_PLUGIN" && pwd -P)"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'autopilot_read_active() { return 1; }' \
  '_autopilot_locked_run() { printf '\''lock\n'\'' >> "$ZENSU_SECOND_FENCE_LOCK"; return 1; }' \
  '_autopilot_read_workspace_critical() {' \
  '  printf '\''r\n'\'' >> "$ZENSU_SECOND_FENCE_READS"' \
  '  if [ "$(wc -l < "$ZENSU_SECOND_FENCE_READS" | tr -d " ")" -le 1 ]; then return 1; fi' \
  '  printf '\''%s'\'' "$ZENSU_SECOND_FENCE_HOLDER"' \
  '}' \
  'tdd_pending_review_owned_by_other() { return 0; }' \
  > "$SECOND_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
P6K="$TMP/second-fence"; start "$P6K" stop_run_second_fence stop_session_second_owner
RF6K="$(autopilot_run_file stop_run_second_fence "$P6K")"
BEFORE8K="$(digest "$RF6K")"
bind_runtime_session "$SECOND_PLUGIN" "$P6K" stop_session_second_stopper second-fence
OUT8K="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_second_stopper"}' \
  | CLAUDE_PROJECT_DIR="$P6K" CLAUDE_PLUGIN_ROOT="$SECOND_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" \
    ZENSU_SECOND_FENCE_LOCK="$TMP/second-fence-lock" \
    ZENSU_SECOND_FENCE_READS="$TMP/second-fence-reads" \
    ZENSU_SECOND_FENCE_HOLDER='{"runId":"stop_run_second_fence","stage":"PLANNING","ownerSessionId":"scv1_deadbeef"}' \
    bash "$SECOND_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
# The read count is the PREMISE: with fewer than two reads the fixture returned
# at the FIRST fence and this check would be passing for the branch it is not
# about -- the exact blindness it exists to remove.
SECOND_READS="$(wc -l < "$TMP/second-fence-reads" 2>/dev/null | tr -d ' ')"
if [ "$(printf '%s' "$OUT8K" | decision)" = block ] \
  && [ "${SECOND_READS:-0}" -ge 2 ] \
  && printf '%s' "$OUT8K" | grep -qF 'stop_run_second_fence' \
  && printf '%s' "$OUT8K" | grep -qF 'run /zensu:autopilot-release' \
  && ! printf '%s' "$OUT8K" | grep -qF -- '--confirm' \
  && [ "$BEFORE8K" = "$(digest "$RF6K")" ]; then
  check "S8k the second contention fence publishes its holder, naming the run without a runnable cancel" PASS
else check "S8k second contention fence must publish its holder (out=$OUT8K reads=${SECOND_READS:-0})" FAIL; fi

# The own-run remedy END TO END through the LOCKED fence. S8g reaches the same
# wording through the CONTENTION fence (its stub kills `_autopilot_locked_run`),
# so the two cover the two publish paths rather than one path twice. Stubbing
# only `autopilot_read_active` here keeps the lease real, so the locked fence is
# the one that renders and publishes.
OWN_PLUGIN="$TMP/own-run-remedy-plugin"; copy_runtime "$OWN_PLUGIN"
OWN_PLUGIN="$(cd "$OWN_PLUGIN" && pwd -P)"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'autopilot_read_active() { return 1; }' \
  > "$OWN_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
P6I="$TMP/own-run-remedy"; start "$P6I" own_remedy_run stop_session_own_remedy
RF6I="$(autopilot_run_file own_remedy_run "$P6I")"; BEFORE8I="$(digest "$RF6I")"
bind_runtime_session "$OWN_PLUGIN" "$P6I" stop_session_own_remedy own-run-remedy
OUT8I="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_own_remedy"}' \
  | CLAUDE_PROJECT_DIR="$P6I" CLAUDE_PLUGIN_ROOT="$OWN_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" \
    bash "$OWN_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT8I" | decision)" = block ] \
  && printf '%s' "$OUT8I" | grep -qF 'own_remedy_run' \
  && printf '%s' "$OUT8I" | grep -qF 'belongs to this session' \
  && ! printf '%s' "$OUT8I" | grep -qF 'autopilot-release' \
  && [ "$BEFORE8I" = "$(digest "$RF6I")" ]; then
  check "S8i an own-run holder is named in the block reason but never offered the release command" PASS
else check "S8i own-run rc=4 must name the run and withhold the release command (reason=$(printf '%s' "$OUT8I" | context))" FAIL; fi

P6E="$TMP/hidden-orphan"; start "$P6E" stop_run_old_terminal stop_session_old_terminal
autopilot_apply_event stop_run_old_terminal cancel-old-terminal CANCEL '{}' "$P6E" >/dev/null
OLD_POINTER8E="$TMP/old-terminal-pointer.json"
cp "$(pointer "$P6E" stop_session_old_terminal)" "$OLD_POINTER8E"
start "$P6E" stop_run_hidden stop_session_old_terminal
cp "$OLD_POINTER8E" "$(pointer "$P6E" stop_session_old_terminal)"
OUT8E="$(invoke "$P6E" stop_session_old_terminal)"
if [ "$(printf '%s' "$OUT8E" | decision)" = block ] && printf '%s' "$OUT8E" | grep -qi 'corrupt'; then
  check "S8e terminal pointer cannot hide a newer nonterminal run from Stop" PASS
else check "S8e hidden nonterminal run cannot inherit terminal release" FAIL; fi

P6F="$TMP/orphan-blocked"; start "$P6F" stop_run_orphan_blocked stop_session_orphan_blocked
autopilot_apply_event stop_run_orphan_blocked block-orphan-fixture BLOCK \
  '{"code":"MANUAL_ORPHAN_BLOCK"}' "$P6F" >/dev/null
rm -f "$(pointer "$P6F" stop_session_orphan_blocked)"
OUT8F="$(invoke "$P6F" stop_session_orphan_blocked)"
if [ "$(printf '%s' "$OUT8F" | decision)" = block ] && printf '%s' "$OUT8F" | grep -qi 'corrupt'; then
  check "S8f orphan BLOCKED run remains nonterminal for inventory safety" PASS
else check "S8f orphan BLOCKED run cannot look terminal or absent" FAIL; fi

P6C="$TMP/corrupt-inner-cap"; start "$P6C" stop_run_corrupt_cap stop_session_corrupt_cap
autopilot_apply_event stop_run_corrupt_cap plan-corrupt-cap PLAN_APPROVED \
  '{"approvedPlanSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' "$P6C" >/dev/null
CLAUDE_PROJECT_DIR="$P6C" bash "$LOG" --tdd-begin --session stop_session_corrupt_cap \
  --autopilot-run stop_run_corrupt_cap --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-corrupt-cap-001 >/dev/null
CLAUDE_PROJECT_DIR="$P6C" bash "$LOG" --tdd-complete --session stop_session_corrupt_cap \
  --autopilot-run stop_run_corrupt_cap --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-corrupt-cap-001 >/dev/null
AF6C="$(pointer "$P6C" stop_session_corrupt_cap)"
AF6C="$AF6C" node -e 'const fs=require("fs"),p=process.env.AF6C,j=JSON.parse(fs.readFileSync(p));j.extra=true;fs.writeFileSync(p,JSON.stringify(j))'
CAP_CORRUPT_BLOCKS=true
for _ in 1 2 3 4 5 6 7 8 9; do
  current="$(invoke "$P6C" stop_session_corrupt_cap)"
  [ "$(printf '%s' "$current" | decision)" = block ] || CAP_CORRUPT_BLOCKS=false
done
if [ "$CAP_CORRUPT_BLOCKS" = true ] && printf '%s' "$current" | grep -qi 'corrupt'; then
  check "S8c corrupt outer remains fail-closed after the inner Stop budget is exhausted" PASS
else check "S8c inner cap cannot bypass corrupt outer state" FAIL; fi

P7="$TMP/priority"; start "$P7" stop_run_priority stop_session_priority
SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
autopilot_apply_event stop_run_priority plan-priority PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7" >/dev/null
CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-begin --session stop_session_priority --autopilot-run stop_run_priority --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-priority-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7" bash "$LOG" --tdd-complete --session stop_session_priority \
  --autopilot-run stop_run_priority --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-priority-001 >/dev/null
OUT9="$(invoke "$P7" stop_session_priority)"
CTX9="$(printf '%s' "$OUT9" | context)"
if [ "$(printf '%s' "$OUT9" | decision)" = block ] \
  && printf '%s' "$OUT9" | grep -qF 'zensu:code-reviewer' \
  && printf '%s' "$OUT9" | grep -qF -- '--outcome no-changes' \
  && [ "$(printf '%s\n' "$CTX9" | grep -cFx 'ZENSU-DELEGATED-CALLER: autopilot')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9" | grep -cFx 'AUTOPILOT-BINDING: run=stop_run_priority attempt=1 chain=chain-priority-001')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9" | grep -cFx 'AUTOPILOT-STAGE: GATES')" -eq 1 ] \
  && ! printf '%s' "$OUT9" | grep -qF 'nextActionCode=AWAIT_TDD_CHAIN'; then
  check "S9 inner review routing has priority over outer-stage routing" PASS
else check "S9 inner review routing has priority" FAIL; fi

# Complete the matching reviewer ticket in the narrow window after the bound
# budget CAS but before the fresh prompt snapshot. Stop must route from that
# fresh codeReviewDone value, never from its initial snapshot.
P7F="$TMP/fresh-review-routing"; start "$P7F" stop_run_fresh stop_session_fresh
autopilot_apply_event stop_run_fresh plan-fresh PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7F" >/dev/null
CLAUDE_PROJECT_DIR="$P7F" bash "$LOG" --tdd-begin --session stop_session_fresh \
  --autopilot-run stop_run_fresh --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-fresh-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7F" bash "$LOG" --tdd-complete --session stop_session_fresh \
  --autopilot-run stop_run_fresh --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-fresh-001 >/dev/null
TICKET9F="$(CLAUDE_PROJECT_DIR="$P7F" bash "$LOG" --review-ticket --session stop_session_fresh)"
CLAUDE_PROJECT_DIR="$P7F" tdd_consume_review_ticket "$ZENSU_SESSION_KEY" "$TICKET9F" >/dev/null
FRESH_PLUGIN="$TMP/fresh-prompt-plugin"; mkdir -p "$FRESH_PLUGIN"
FRESH_PLUGIN="$(cd "$FRESH_PLUGIN" && pwd -P)"
for runtime_entry in .claude-plugin .mcp.json hooks agents skills docs templates scripts README.md CHANGELOG.md LICENSE; do
  cp -R "$PLUGIN_DIR/$runtime_entry" "$FRESH_PLUGIN/$runtime_entry"
done
mkdir -p "$FRESH_PLUGIN/mcp-runtime"
cp "$PLUGIN_DIR/mcp-runtime/package.json" "$PLUGIN_DIR/mcp-runtime/package-lock.json" \
  "$FRESH_PLUGIN/mcp-runtime/"
FRESH_STATE_LIB="$FRESH_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_increment_inner_stop_budget_capped | sed '\''1s/autopilot_increment_inner_stop_budget_capped/_autopilot_increment_inner_stop_budget_capped_real/'\'')"' \
  'autopilot_increment_inner_stop_budget_capped() {' \
  '  local result rc' \
  '  result="$(_autopilot_increment_inner_stop_budget_capped_real "$@")"; rc=$?' \
  '  [ "$rc" -eq 0 ] || return "$rc"' \
  '  CLAUDE_PROJECT_DIR="$7" tdd_mark_review_converged "$8" "$ZENSU_FRESH_REVIEW_TICKET" codeReviewDone || return 5' \
  '  printf '\''%s\n'\'' "$result"' \
  '}' > "$FRESH_STATE_LIB"
ZENSU_TEST_PLUGIN_DATA="$TMP/fresh-prompt-plugin-data"
export ZENSU_TEST_PLUGIN_DATA
# The instrumented runtime is a distinct installation. Bootstrap its own
# authenticated session context so the handoff acknowledgement exercises the
# real plugin-root boundary instead of relying on the original fixture's root.
# shellcheck disable=SC1090
source "$BASELINE" stop_session_fresh "$FRESH_PLUGIN"
unset ZENSU_TEST_PLUGIN_DATA
OUT9F="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_fresh"}' \
  | CLAUDE_PROJECT_DIR="$P7F" CLAUDE_PLUGIN_ROOT="$FRESH_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_FRESH_REVIEW_TICKET="$TICKET9F" \
    bash "$FRESH_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
CTX9F="$(printf '%s' "$OUT9F" | context)"
if [ "$(printf '%s' "$OUT9F" | decision)" = block ] \
  && printf '%s' "$OUT9F" | grep -qF "skill='zensu:self-review'" \
  && [ "$(printf '%s\n' "$CTX9F" | grep -cFx 'ZENSU-DELEGATED-CALLER: autopilot')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9F" | grep -cFx 'AUTOPILOT-BINDING: run=stop_run_fresh attempt=1 chain=chain-fresh-001')" -eq 1 ] \
  && [ "$(printf '%s\n' "$CTX9F" | grep -cFx 'AUTOPILOT-STAGE: GATES')" -eq 1 ] \
  && ! printf '%s' "$OUT9F" | grep -qF "subagent_type='zensu:code-reviewer'"; then
  check "S9a fresh codeReviewDone routes self-review after the budget CAS" PASS
else check "S9a fresh prompt snapshot owns reviewer vs self-review routing" FAIL; fi

# Capture attempt 1 in Stop, then deterministically advance both Outer and Inner
# to attempt 2 during the first Outer read. The stale Stop invocation must lose
# its generation CAS before touching either attempt-2's inner Stop budget or the
# current Outer budget, and must fail closed from the changed generation.
P7G="$TMP/stale-inner-budget-generation"; start "$P7G" stop_run_generation stop_session_generation
autopilot_apply_event stop_run_generation plan-generation PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7G" >/dev/null
CLAUDE_PROJECT_DIR="$P7G" bash "$LOG" --tdd-begin --session stop_session_generation \
  --autopilot-run stop_run_generation --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-generation-stop-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7G" bash "$LOG" --tdd-complete --session stop_session_generation \
  --autopilot-run stop_run_generation --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-generation-stop-001 >/dev/null
TF7G="$(tdd_state_file stop_session_generation)"
RF7G="$(autopilot_run_file stop_run_generation "$P7G")"
INITIAL7G=false
field_ok "$TF7G" \
  'j.autopilotAttempt===1&&j.chainId==="chain-generation-stop-001"&&j.implComplete===true&&j.stopBlockCount===0' \
  && INITIAL7G=true
GENERATION_PLUGIN="$TMP/stale-inner-budget-plugin"; copy_runtime "$GENERATION_PLUGIN"
GENERATION_PLUGIN="$(cd "$GENERATION_PLUGIN" && pwd -P)"
GENERATION_STATE_LIB="$GENERATION_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_read_active | sed '\''1s/autopilot_read_active/_autopilot_read_active_real/'\'')"' \
  'autopilot_read_active() {' \
  '  local root="${1:-${CLAUDE_PROJECT_DIR:-.}}"' \
  '  if [ ! -e "$ZENSU_GENERATION_RACE_MARKER" ]; then' \
  '    : > "$ZENSU_GENERATION_RACE_MARKER"' \
  '    CLAUDE_PROJECT_DIR="$root" autopilot_finish_tdd_attempt "$ZENSU_GENERATION_RUN" generation-stop-done-1 "$root" "$ZENSU_GENERATION_SID" 1 "$ZENSU_GENERATION_CHAIN_1" no-changes false >/dev/null || return 5' \
  '    autopilot_apply_event "$ZENSU_GENERATION_RUN" generation-gates-failed GATES_FAILED '\''{"headSha":"dddddddddddddddddddddddddddddddddddddddd","reason":"deterministic Stop generation race"}'\'' "$root" "$ZENSU_GENERATION_SID" >/dev/null || return 5' \
  '    CLAUDE_PROJECT_DIR="$root" autopilot_begin_tdd_attempt "$ZENSU_GENERATION_RUN" generation-stop-start-2 "$root" "$ZENSU_GENERATION_SID" false 2 GATES "$ZENSU_GENERATION_CHAIN_2" >/dev/null || return 5' \
  '    CLAUDE_PROJECT_DIR="$root" tdd_mark_impl_complete_bound "$ZENSU_GENERATION_SID" "$ZENSU_GENERATION_RUN" 2 "$ZENSU_GENERATION_CHAIN_2" >/dev/null || return 5' \
  '  fi' \
  '  _autopilot_read_active_real "$@"' \
  '}' > "$GENERATION_STATE_LIB"
bind_runtime_session "$GENERATION_PLUGIN" "$P7G" stop_session_generation generation-race
OUT9G="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_generation"}' \
  | CLAUDE_PROJECT_DIR="$P7G" CLAUDE_PLUGIN_ROOT="$GENERATION_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_GENERATION_RACE_MARKER="$TMP/generation-race-fired" \
    ZENSU_GENERATION_RUN=stop_run_generation ZENSU_GENERATION_SID="$ZENSU_SESSION_KEY" \
    ZENSU_GENERATION_CHAIN_1=chain-generation-stop-001 \
    ZENSU_GENERATION_CHAIN_2=chain-generation-stop-002 \
    bash "$GENERATION_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$INITIAL7G" = true ] && [ -e "$TMP/generation-race-fired" ] \
  && [ "$(printf '%s' "$OUT9G" | decision)" = block ] \
  && printf '%s' "$OUT9G" | grep -qF 'generation changed' \
  && field_ok "$TF7G" \
    'j.autopilotAttempt===2&&j.chainId==="chain-generation-stop-002"&&j.implComplete===true&&j.chainDone===false&&j.stopBlockCount===0' \
  && field_ok "$RF7G" \
    'j.stage==="TDD_RUNNING"&&j.tdd.attempt===2&&j.tdd.chainId==="chain-generation-stop-002"&&j.stopBudget.count===0'; then
  check "S9f stale attempt-1 Stop cannot charge attempt 2 before fresh routing" PASS
else check "S9f stale attempt-1 Stop leaves attempt-2 Inner and Outer budgets untouched" FAIL; fi

P7T="$TMP/bound-terminal"; start "$P7T" stop_run_bound stop_session_bound
autopilot_apply_event stop_run_bound plan-bound PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7T" >/dev/null
CLAUDE_PROJECT_DIR="$P7T" bash "$LOG" --tdd-begin --session stop_session_bound --autopilot-run stop_run_bound --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-bound-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7T" bash "$LOG" --tdd-complete --session stop_session_bound \
  --autopilot-run stop_run_bound --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-bound-001 >/dev/null
autopilot_apply_event stop_run_bound block-bound BLOCK '{"code":"MANUAL_BLOCK"}' "$P7T" >/dev/null
OUT9T="$(invoke "$P7T" stop_session_bound)"
[ -z "$OUT9T" ] \
  && check "S9b terminal outer run wins over its same-bound unfinished inner chain" PASS \
  || check "S9b same-bound terminal permits Stop" FAIL

# Return a cached R1/CANCELLED snapshot from the first Outer read, but publish a
# new R2/PLANNING pointer before Stop evaluates that terminal snapshot. Stop may
# release only after revalidating the current pointer; stale R1 must not permit
# the turn while R2 is active.
P7U="$TMP/stale-terminal-release"; start "$P7U" stop_run_terminal_old stop_session_terminal_race
autopilot_apply_event stop_run_terminal_old plan-terminal-old PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7U" >/dev/null
CLAUDE_PROJECT_DIR="$P7U" bash "$LOG" --tdd-begin --session stop_session_terminal_race \
  --autopilot-run stop_run_terminal_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-terminal-old-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7U" bash "$LOG" --tdd-complete --session stop_session_terminal_race \
  --autopilot-run stop_run_terminal_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-terminal-old-001 >/dev/null
autopilot_apply_event stop_run_terminal_old cancel-terminal-old CANCEL '{}' "$P7U" >/dev/null
TERMINAL_PLUGIN="$TMP/stale-terminal-plugin"; copy_runtime "$TERMINAL_PLUGIN"
TERMINAL_PLUGIN="$(cd "$TERMINAL_PLUGIN" && pwd -P)"
TERMINAL_STATE_LIB="$TERMINAL_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_read_active | sed '\''1s/autopilot_read_active/_autopilot_read_active_real/'\'')"' \
  'autopilot_read_active() {' \
  '  local cached rc root="${1:-${CLAUDE_PROJECT_DIR:-.}}"' \
  '  cached="$(_autopilot_read_active_real "$@")"; rc=$?' \
  '  [ "$rc" -eq 0 ] || return "$rc"' \
  '  if [ ! -e "$ZENSU_TERMINAL_RACE_MARKER" ]; then' \
  '    : > "$ZENSU_TERMINAL_RACE_MARKER"' \
  '    autopilot_begin_run "$ZENSU_TERMINAL_NEW_RUN" "$ZENSU_TERMINAL_SID" "$root" >/dev/null || return 5' \
  '  fi' \
  '  printf '\''%s\n'\'' "$cached"' \
  '}' > "$TERMINAL_STATE_LIB"
bind_runtime_session "$TERMINAL_PLUGIN" "$P7U" stop_session_terminal_race terminal-race
OUT9U="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_terminal_race"}' \
  | CLAUDE_PROJECT_DIR="$P7U" CLAUDE_PLUGIN_ROOT="$TERMINAL_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_TERMINAL_RACE_MARKER="$TMP/terminal-race-fired" \
    ZENSU_TERMINAL_NEW_RUN=stop_run_terminal_new ZENSU_TERMINAL_SID="$ZENSU_SESSION_KEY" \
    bash "$TERMINAL_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
RF7U_NEW="$(autopilot_run_file stop_run_terminal_new "$P7U")"
if [ -e "$TMP/terminal-race-fired" ] \
  && [ "$(printf '%s' "$OUT9U" | decision)" = block ] \
  && printf '%s' "$OUT9U" | grep -qF 'run stop_run_terminal_new' \
  && printf '%s' "$OUT9U" | grep -qF 'stage=PLANNING; nextActionCode=AWAIT_PLAN_APPROVAL' \
  && field_ok "$RF7U_NEW" 'j.stage==="PLANNING"'; then
  check "S9g stale terminal snapshot cannot release Stop after a new run begins" PASS
else check "S9g terminal release revalidates and blocks the current Outer run" FAIL; fi

# The explicit escape branch must use the same current-pointer proof. Return a
# cached terminal R1 snapshot while publishing R2/PLANNING, then request the
# supported ZENSU_AUTOPILOT=off escape. R2 must receive its own audited BLOCK;
# stale R1 must never make the hook release an unaudited active generation.
P7V="$TMP/stale-terminal-escape"; start "$P7V" stop_run_escape_old stop_session_escape_race
autopilot_apply_event stop_run_escape_old plan-escape-old PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7V" >/dev/null
CLAUDE_PROJECT_DIR="$P7V" bash "$LOG" --tdd-begin --session stop_session_escape_race \
  --autopilot-run stop_run_escape_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-escape-old-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7V" bash "$LOG" --tdd-complete --session stop_session_escape_race \
  --autopilot-run stop_run_escape_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-escape-old-001 >/dev/null
autopilot_apply_event stop_run_escape_old cancel-escape-old CANCEL '{}' "$P7V" >/dev/null
bind_runtime_session "$TERMINAL_PLUGIN" "$P7V" stop_session_escape_race terminal-race
OUT9V="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_escape_race"}' \
  | CLAUDE_PROJECT_DIR="$P7V" CLAUDE_PLUGIN_ROOT="$TERMINAL_PLUGIN" ZENSU_AUTOPILOT=off \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_TERMINAL_RACE_MARKER="$TMP/terminal-escape-race-fired" \
    ZENSU_TERMINAL_NEW_RUN=stop_run_escape_new ZENSU_TERMINAL_SID="$ZENSU_SESSION_KEY" \
    bash "$TERMINAL_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
RF7V_NEW="$(autopilot_run_file stop_run_escape_new "$P7V")"
if [ -e "$TMP/terminal-escape-race-fired" ] && [ -z "$OUT9V" ] \
  && field_ok "$RF7V_NEW" \
    'j.stage==="BLOCKED"&&j.blocked.code==="ZENSU_AUTOPILOT_OFF"&&j.events.some(e=>e.eventType==="BLOCK"&&e.payload.code==="ZENSU_AUTOPILOT_OFF")'; then
  check "S9i stale terminal escape audits the newly active Outer generation" PASS
else check "S9i explicit escape cannot release a new active run from stale terminal state" FAIL; fi

P7S="$TMP/stale-terminal"; start "$P7S" stop_run_stale stop_session_stale
autopilot_apply_event stop_run_stale cancel-stale CANCEL '{}' "$P7S" >/dev/null
activate_session "$P7S" later_standalone || exit 1
CLAUDE_PROJECT_DIR="$P7S" bash "$LOG" --tdd-begin --session later_standalone >/dev/null
CLAUDE_PROJECT_DIR="$P7S" bash "$LOG" --tdd-complete --session later_standalone >/dev/null
OUT9S="$(invoke "$P7S" later_standalone)"
if [ "$(printf '%s' "$OUT9S" | decision)" = block ] && printf '%s' "$OUT9S" | grep -qF 'zensu:code-reviewer'; then
  check "S9c old terminal pointer cannot bypass a later standalone TDD chain" PASS
else check "S9c old terminal does not bypass standalone inner chain" FAIL; fi

CLAUDE_PROJECT_DIR="$P7S" bash "$LOG" --pending-review --files 'src/pending.ts' \
  --summary 'review queued after terminal autopilot' >/dev/null
OUT9SP="$(invoke "$P7S" pending_after_terminal)"
activate_session "$P7S" pending_after_terminal || exit 1
TF9SP="$(tdd_state_file pending_after_terminal)"
if [ "$(printf '%s' "$OUT9SP" | decision)" = block ] \
  && printf '%s' "$OUT9SP" | grep -qF 'zensu:code-reviewer' \
  && field_ok "$TF9SP" 'j.active===true&&j.implComplete===true&&j.chainDone===false'; then
  check "S9c2 terminal pointer does not suppress a later deferred review adoption" PASS
else check "S9c2 terminal pointer preserves deferred review compatibility" FAIL; fi

# CANCELLED relinquishes ownership even when its exact old Inner remains armed
# in the same session. A new pending review must retire that historical binding
# and become the current standalone deferred-review chain; it may not remain
# queued forever behind the stale terminal ownership shortcut. The existing
# S9e assertion below keeps resumable BLOCKED deliberately conservative.
P7P="$TMP/cancelled-pending-same-session"; start "$P7P" stop_run_pending_old stop_session_pending_same
activate_session "$P7P" stop_session_pending_same || exit 1
autopilot_apply_event stop_run_pending_old plan-pending-old PLAN_APPROVED \
  "{\"approvedPlanSha256\":\"$SHA\"}" "$P7P" >/dev/null
CLAUDE_PROJECT_DIR="$P7P" bash "$LOG" --tdd-begin --session stop_session_pending_same \
  --autopilot-run stop_run_pending_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-pending-old-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7P" bash "$LOG" --tdd-complete --session stop_session_pending_same \
  --autopilot-run stop_run_pending_old --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-pending-old-001 >/dev/null
autopilot_apply_event stop_run_pending_old cancel-pending-old CANCEL '{}' "$P7P" >/dev/null
CLAUDE_PROJECT_DIR="$P7P" bash "$LOG" --pending-review --files 'src/same-session-pending.ts' \
  --summary 'must supersede cancelled exact inner binding' >/dev/null
PF7P="$P7P/.zensu/state/pending-review.json"
OUT9P="$(invoke "$P7P" stop_session_pending_same)"
TF7P="$(tdd_state_file stop_session_pending_same)"
if [ "$(printf '%s' "$OUT9P" | decision)" = block ] \
  && printf '%s' "$OUT9P" | grep -qF 'zensu:code-reviewer' \
  && [ ! -e "$PF7P" ] && [ -f "$PF7P.claim" ] \
  && field_ok "$TF7P" \
    'j.active===true&&j.implComplete===true&&j.chainDone===false&&j.deferredReviewClaim&&!("autopilotRunId" in j)&&!("autopilotAttempt" in j)&&!("chainId" in j)' \
  && field_ok "$(autopilot_run_file stop_run_pending_old "$P7P")" 'j.stage==="CANCELLED"'; then
  check "S9h CANCELLED exact old Inner cannot starve same-session pending adoption" PASS
else check "S9h terminal same-session pending review remains adoptable while BLOCKED stays conservative" FAIL; fi

P7R="$TMP/reconciled-terminal"; start "$P7R" stop_run_reconcile stop_session_reconcile
autopilot_apply_event stop_run_reconcile plan-reconcile PLAN_APPROVED "{\"approvedPlanSha256\":\"$SHA\"}" "$P7R" >/dev/null
CLAUDE_PROJECT_DIR="$P7R" bash "$LOG" --tdd-begin --session stop_session_reconcile --autopilot-run stop_run_reconcile --autopilot-attempt 1 --autopilot-return-stage GATES --chain-id chain-reconcile-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7R" bash "$LOG" --tdd-complete --session stop_session_reconcile \
  --autopilot-run stop_run_reconcile --autopilot-attempt 1 --autopilot-return-stage GATES \
  --chain-id chain-reconcile-001 >/dev/null
CLAUDE_PROJECT_DIR="$P7R" tdd_finish_autopilot_chain "$ZENSU_SESSION_KEY" \
  stop_run_reconcile 1 chain-reconcile-001 max-rounds
OUT9R="$(invoke "$P7R" stop_session_reconcile)"; RF7R="$(autopilot_run_file stop_run_reconcile "$P7R")"
if [ -z "$OUT9R" ] && field_ok "$RF7R" 'j.stage==="BLOCKED"&&j.blocked.code==="TDD_MAX_ROUNDS"'; then
  check "S9d crash-window reconciliation re-applies terminal release after BLOCKED" PASS
else check "S9d reconciled terminal permits Stop" FAIL; fi

# BLOCKED is resumable and still owns its exact Inner generation. A deferred
# review marker must remain queued; Stop must never overwrite that binding with
# an unbound seed merely because chainDone already released the hook.
TF7R="$(tdd_state_file stop_session_reconcile)"
BEFORE9RB="$(digest "$TF7R")"
CLAUDE_PROJECT_DIR="$P7R" bash "$LOG" --pending-review --files 'src/blocked-pending.ts' \
  --summary 'must remain queued behind blocked outer' >/dev/null
PENDING9RB="$(CLAUDE_PROJECT_DIR="$P7R" zensu_pending_review_file)"
OUT9RB="$(invoke "$P7R" stop_session_reconcile)"
AFTER9RB="$(digest "$TF7R")"
if [ -z "$OUT9RB" ] && [ "$BEFORE9RB" = "$AFTER9RB" ] && [ -f "$PENDING9RB" ] \
  && field_ok "$TF7R" 'j.autopilotRunId==="stop_run_reconcile"&&j.autopilotAttempt===1&&j.chainId==="chain-reconcile-001"'; then
  check "S9e BLOCKED outer preserves binding and queued deferred review" PASS
else check "S9e BLOCKED outer cannot seed an unbound deferred review" FAIL; fi

# A standalone unfinished Inner can legitimately predate a later Outer in the
# same session. BLOCKED owns only an exact bound Inner generation, so it must
# leave this Outer byte-stable while the unrelated standalone review routes.
P7W="$TMP/blocked-after-standalone"; mkdir -p "$P7W"
S7W=stop_session_blocked_after_standalone
R7W=stop_run_blocked_after_standalone
activate_session "$P7W" "$S7W" || exit 1
CLAUDE_PROJECT_DIR="$P7W" bash "$LOG" --tdd-begin --session "$S7W" >/dev/null
CLAUDE_PROJECT_DIR="$P7W" bash "$LOG" --tdd-complete --session "$S7W" >/dev/null
start "$P7W" "$R7W" "$S7W"
autopilot_apply_event "$R7W" block-after-standalone BLOCK \
  '{"code":"MANUAL_BLOCK"}' "$P7W" >/dev/null
TF7W="$(tdd_state_file "$S7W")"
RF7W="$(autopilot_run_file "$R7W" "$P7W")"
BEFORE9W="$(digest "$RF7W")"
OUT9W="$(invoke "$P7W" "$S7W")"
AFTER9W="$(digest "$RF7W")"
if [ "$(printf '%s' "$OUT9W" | decision)" = block ] \
  && printf '%s' "$OUT9W" | grep -qF 'zensu:code-reviewer' \
  && [ "$BEFORE9W" = "$AFTER9W" ] \
  && field_ok "$TF7W" \
    'j.active===true&&j.implComplete===true&&j.chainDone===false&&j.stopBlockCount===1&&!("autopilotRunId" in j)' \
  && field_ok "$RF7W" \
    'j.stage==="BLOCKED"&&j.blocked.code==="MANUAL_BLOCK"&&j.stopBudget.count===0'; then
  check "S9j BLOCKED outer cannot suppress an unrelated standalone review chain" PASS
else check "S9j unrelated standalone review wins while BLOCKED outer remains byte-stable" FAIL; fi

P8="$TMP/cap"; start "$P8" stop_run_cap stop_session_cap
CAP_BLOCKS=true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  current="$(invoke "$P8" stop_session_cap)"
  [ "$(printf '%s' "$current" | decision)" = block ] || CAP_BLOCKS=false
done
OUT10="$(invoke "$P8" stop_session_cap)"; RF8="$(autopilot_run_file stop_run_cap "$P8")"
if [ "$CAP_BLOCKS" = true ] && [ -z "$OUT10" ] && field_ok "$RF8" 'j.stage==="BLOCKED"&&j.blocked.code==="STOP_BUDGET_EXHAUSTED"'; then
  check "S10 exhausted outer budget moves to audited BLOCKED then permits Stop" PASS
else check "S10 outer budget cap blocks safely" FAIL; fi

# A standalone Inner may predate a later durable Outer in the same session.
# Exhausting only the Inner guard must never release Stop while that Outer is
# still nonterminal; the final decision must pass through outer_finish.
P8C="$TMP/standalone-cap-with-outer"; mkdir -p "$P8C"
S8C=stop_session_standalone_cap; R8C=stop_run_after_standalone
CFG8C="$TMP/standalone-cap-one.json"
printf '%s\n' '{"hooks":{"autoFixMaxRounds":1}}' > "$CFG8C"
activate_session "$P8C" "$S8C" || exit 1
CLAUDE_PROJECT_DIR="$P8C" bash "$LOG" --tdd-begin --session "$S8C" >/dev/null
CLAUDE_PROJECT_DIR="$P8C" bash "$LOG" --tdd-complete --session "$S8C" >/dev/null
start "$P8C" "$R8C" "$S8C"
PRECAP8C=true
for _ in 1 2 3 4; do
  CURRENT8C="$(invoke "$P8C" "$S8C" "$CFG8C")"
  [ "$(printf '%s' "$CURRENT8C" | decision)" = block ] || PRECAP8C=false
done
OUT10C="$(invoke "$P8C" "$S8C" "$CFG8C")"
RF8C="$(autopilot_run_file "$R8C" "$P8C")"
if [ "$PRECAP8C" = true ] \
  && [ "$(printf '%s' "$OUT10C" | decision)" = block ] \
  && printf '%s' "$OUT10C" | grep -qF 'run stop_run_after_standalone' \
  && printf '%s' "$OUT10C" | grep -qF 'stage=PLANNING; nextActionCode=AWAIT_PLAN_APPROVAL' \
  && field_ok "$RF8C" 'j.stage==="PLANNING"&&j.stopBudget.count===1'; then
  check "S10c standalone Inner cap cannot release a later active Outer" PASS
else check "S10c standalone cap must still enforce the durable Outer" FAIL; fi

# Deterministically advance the stage in the narrow window after locked
# reconciliation but before the capped budget CAS. The first capped call
# simulates that concurrent transition and returns the helper's stale rc=4;
# Stop must re-read, route the new action, and increment only that generation.
P8B="$TMP/cap-stale-stage"; start "$P8B" stop_run_cap_stale stop_session_cap_stale
STALE_PLUGIN="$TMP/stale-cap-plugin"; copy_runtime "$STALE_PLUGIN"
STALE_PLUGIN="$(cd "$STALE_PLUGIN" && pwd -P)"
STALE_STATE_LIB="$STALE_PLUGIN/hooks/lib/zensu-autopilot-state.sh"
printf '%s\n' \
  'source "$REAL_AUTOPILOT_STATE_LIB"' \
  'eval "$(declare -f autopilot_increment_stop_budget_capped | sed '\''1s/autopilot_increment_stop_budget_capped/_autopilot_increment_stop_budget_capped_real/'\'')"' \
  'autopilot_increment_stop_budget_capped() {' \
  '  if [ ! -e "$ZENSU_STALE_CAP_MARKER" ]; then' \
  '    : > "$ZENSU_STALE_CAP_MARKER"' \
  '    autopilot_apply_event "$1" stale-cap-plan-approved PLAN_APPROVED '\''{"approvedPlanSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'\'' "$3" "$4" >/dev/null 2>&1 || return 5' \
  '    return 4' \
  '  fi' \
  '  _autopilot_increment_stop_budget_capped_real "$@"' \
  '}' > "$STALE_STATE_LIB"
bind_runtime_session "$STALE_PLUGIN" "$P8B" stop_session_cap_stale stale-cap
OUT10B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_cap_stale"}' \
  | CLAUDE_PROJECT_DIR="$P8B" CLAUDE_PLUGIN_ROOT="$STALE_PLUGIN" \
    REAL_AUTOPILOT_STATE_LIB="$LIB" ZENSU_STALE_CAP_MARKER="$TMP/stale-cap-fired" \
    bash "$STALE_PLUGIN/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
RF8B="$(autopilot_run_file stop_run_cap_stale "$P8B")"
if [ "$(printf '%s' "$OUT10B" | decision)" = block ] \
  && printf '%s' "$OUT10B" | grep -qF 'stage=AWAIT_TDD; nextActionCode=START_TDD' \
  && ! printf '%s' "$OUT10B" | grep -qF 'nextActionCode=AWAIT_PLAN_APPROVAL' \
  && field_ok "$RF8B" 'j.stage==="AWAIT_TDD"&&j.stopBudget.count===1&&j.events.filter(e=>e.eventType==="PLAN_APPROVED").length===1'; then
  check "S10b stale outer-cap CAS re-routes once from the new stage" PASS
else check "S10b stale outer-cap CAS cannot mutate or describe the old stage" FAIL; fi

P9="$TMP/runtime-missing"; start "$P9" stop_run_runtime stop_session_runtime
NO_NODE_PATH="$TMP/no-node-path"; mkdir -p "$NO_NODE_PATH"
ln -s "$(command -v dirname)" "$NO_NODE_PATH/dirname"
OUT11="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_runtime"}' | CLAUDE_PROJECT_DIR="$P9" PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
if [ -z "$OUT11" ]; then
  check "S11 missing Node stays silent before principal/state authentication" PASS
else check "S11 missing Node must not guess a main-thread Stop decision" FAIL; fi
OUT11B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_orphan"}' | CLAUDE_PROJECT_DIR="$P6D" \
  PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
if [ -z "$OUT11B" ]; then
  check "S11b orphan missing-Node path also stays unauthenticated and silent" PASS
else check "S11b orphan missing-Node path must not guess a Stop principal" FAIL; fi

MISSING_LIB_ROOT="$TMP/missing-state-lib"; copy_runtime "$MISSING_LIB_ROOT"
MISSING_LIB_ROOT="$(cd "$MISSING_LIB_ROOT" && pwd -P)"
rm -f "$MISSING_LIB_ROOT/hooks/lib/zensu-autopilot-state.sh"
bind_runtime_session "$MISSING_LIB_ROOT" "$P9" stop_session_runtime missing-state
OUT12="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_runtime"}' | CLAUDE_PROJECT_DIR="$P9" CLAUDE_PLUGIN_ROOT="$MISSING_LIB_ROOT" bash "$MISSING_LIB_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT12" | decision)" = block ] && printf '%s' "$OUT12" | grep -qF 'durable state runtime is unavailable'; then
  check "S12 missing outer-state library with an active pointer fails closed" PASS
else check "S12 missing state library fails closed" FAIL; fi
bind_runtime_session "$MISSING_LIB_ROOT" "$P6D" stop_session_orphan missing-state
OUT12B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_orphan"}' | CLAUDE_PROJECT_DIR="$P6D" \
  CLAUDE_PLUGIN_ROOT="$MISSING_LIB_ROOT" bash "$MISSING_LIB_ROOT/hooks/stop-chain-enforcer.sh" 2>/dev/null)"
if [ "$(printf '%s' "$OUT12B" | decision)" = block ] \
  && printf '%s' "$OUT12B" | grep -qF 'durable state runtime is unavailable'; then
  check "S12b missing state library with an orphan run fails closed" PASS
else check "S12b orphan run cannot look absent without the state library" FAIL; fi

OUT13="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_runtime","agent_id":"spawned-no-runtime"}' | CLAUDE_PROJECT_DIR="$P9" PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
[ -z "$OUT13" ] \
  && check "S13 spawned-agent no-op still precedes missing-runtime enforcement" PASS \
  || check "S13 spawned agent remains first no-op" FAIL
OUT13B="$(printf '%s' '{"hook_event_name":"Stop","session_id":"stop_session_orphan","agent_id":"spawned-orphan-no-runtime"}' \
  | CLAUDE_PROJECT_DIR="$P6D" PATH="$NO_NODE_PATH" /bin/bash "$STOP" 2>/dev/null)"
[ -z "$OUT13B" ] \
  && check "S13b spawned-agent no-op precedes orphan runtime enforcement" PASS \
  || check "S13b orphan hint must not deadlock a spawned agent" FAIL

# Two note-retire sites inside the Autopilot escape branch. The routing suite
# cannot reach either — the branch needs a durable run and that suite builds none
# — so both were unpinned. They matter for the same reason the inner-guard
# escapes do: once an escape releases Stop, this session never routes the inner
# chain again, so nothing else can remove a note minted before it and
# /zensu:doctor would keep reporting a refusal that no longer describes anything.
plant_denial_note() {
  printf '{"schemaVersion":1,"kind":"auto-mode-classifier","subagentType":"zensu:code-reviewer","detectedAtMs":1}\n' > "$1"
}

# Site 1: the escape finds the run already at a terminal stage and exits without
# auditing anything.
P14="$TMP/escape-note-terminal"; start "$P14" stop_run_esc_term stop_session_esc_term
CLAUDE_PROJECT_DIR="$P14" bash "$LOG" --tdd-begin --session stop_session_esc_term >/dev/null
CLAUDE_PROJECT_DIR="$P14" bash "$LOG" --tdd-complete --session stop_session_esc_term >/dev/null
autopilot_apply_event stop_run_esc_term cancel-esc-term CANCEL '{}' "$P14" >/dev/null
activate_session "$P14" stop_session_esc_term || exit 1
NOTE14="$P14/.zensu/state/reviewer-spawn-denied-$ZENSU_SESSION_KEY.json"
plant_denial_note "$NOTE14"
invoke "$P14" stop_session_esc_term "$TMP/missing.json" '' off >/dev/null
[ ! -f "$NOTE14" ] \
  && check "S14 a terminal-stage Autopilot escape retires a leftover refusal note" PASS \
  || check "S14 terminal-stage escape leaves the refusal note behind" FAIL

# Site 2: a DIFFERENT line — the escape audits an ACTIVE run to BLOCKED first and
# releases afterwards. Asserting the audit too keeps this from passing on an
# escape that never happened.
P15="$TMP/escape-note-active"; start "$P15" stop_run_esc_active stop_session_esc_active
CLAUDE_PROJECT_DIR="$P15" bash "$LOG" --tdd-begin --session stop_session_esc_active >/dev/null
CLAUDE_PROJECT_DIR="$P15" bash "$LOG" --tdd-complete --session stop_session_esc_active >/dev/null
activate_session "$P15" stop_session_esc_active || exit 1
NOTE15="$P15/.zensu/state/reviewer-spawn-denied-$ZENSU_SESSION_KEY.json"
plant_denial_note "$NOTE15"
invoke "$P15" stop_session_esc_active "$TMP/missing.json" '' off >/dev/null
RF15="$(autopilot_run_file stop_run_esc_active "$P15")"
if [ ! -f "$NOTE15" ] && field_ok "$RF15" 'j.stage==="BLOCKED"'; then
  check "S15 an audited Autopilot escape retires the note and still records BLOCKED" PASS
else
  check "S15 audited escape retires the note and records BLOCKED" FAIL
fi

echo "----"; echo "test-autopilot-stop-enforcer: $PASS PASS / $FAIL FAIL"; [ "$FAIL" -eq 0 ]
