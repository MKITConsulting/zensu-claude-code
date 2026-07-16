#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SESSION="$ROOT/hooks/lib/zensu-session.sh"
PHASE="$ROOT/hooks/lib/zensu-tdd-phase.sh"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
mkdir -p "$PROJECT/.zensu/state"
RAW='claude/raw session id'
EXPECTED="$(node "$CORE" session-key "$RAW")"

EXPLICIT="$(bash -c "source '$SESSION'; zensu_resolve_session_id '$RAW'" 2>/dev/null)"
[ "$EXPLICIT" = "$EXPECTED" ] && check "explicit hook id becomes the domain-separated key" PASS || check "explicit hook id becomes the domain-separated key" FAIL

ENV_KEY="$(ZENSU_SESSION_KEY="$EXPECTED" CLAUDE_SESSION_ID='untrusted-raw' bash -c "source '$SESSION'; zensu_resolve_session_id ''" 2>/dev/null)"
[ "$ENV_KEY" = "$EXPECTED" ] && check "exported Session Control key wins over ambient Claude identity" PASS || check "exported Session Control key wins over ambient Claude identity" FAIL

BOUND_RAW="$(ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; zensu_resolve_session_id '$RAW'" 2>/dev/null)"
[ "$BOUND_RAW" = "$EXPECTED" ] && check "matching explicit raw id remains bound to the injected session" PASS || check "matching explicit raw id remains bound to the injected session" FAIL

BOUND_KEY="$(ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; zensu_resolve_session_id '$EXPECTED'" 2>/dev/null)"
[ "$BOUND_KEY" = "$EXPECTED" ] && check "matching explicit session key remains bound to the injected session" PASS || check "matching explicit session key remains bound to the injected session" FAIL

FOREIGN_RAW='claude/foreign session id'
FOREIGN_KEY="$(node "$CORE" session-key "$FOREIGN_RAW")"
if ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; zensu_resolve_session_id '$FOREIGN_RAW'" >"$TMP/foreign-raw.out" 2>/dev/null; then
  check "foreign explicit raw id fails closed under an injected session" FAIL
else
  [ ! -s "$TMP/foreign-raw.out" ] && check "foreign explicit raw id fails closed under an injected session" PASS || check "foreign explicit raw id fails closed under an injected session" FAIL
fi
if ZENSU_SESSION_KEY="$EXPECTED" bash -c "source '$SESSION'; zensu_resolve_session_id '$FOREIGN_KEY'" >"$TMP/foreign-key.out" 2>/dev/null; then
  check "foreign explicit session key fails closed under an injected session" FAIL
else
  [ ! -s "$TMP/foreign-key.out" ] && check "foreign explicit session key fails closed under an injected session" PASS || check "foreign explicit session key fails closed under an injected session" FAIL
fi

ROUNDTRIP="$(bash -c "source '$SESSION'; zensu_resolve_session_id '$EXPECTED'" 2>/dev/null)"
[ "$ROUNDTRIP" = "$EXPECTED" ] && check "an existing v1 key is not double-hashed" PASS || check "an existing v1 key is not double-hashed" FAIL

if ZENSU_SESSION_KEY='' CLAUDE_SESSION_ID='transcript-shaped' ZENSU_TRANSCRIPT_PATH="$TMP/fake.jsonl" bash -c "source '$SESSION'; zensu_resolve_session_id ''" >"$TMP/missing.out" 2>/dev/null; then
  check "missing exported key fails closed without transcript or PPID fallback" FAIL
else
  [ ! -s "$TMP/missing.out" ] && check "missing exported key fails closed without transcript or PPID fallback" PASS || check "missing exported key fails closed without transcript or PPID fallback" FAIL
fi

# Production phase mutations are valid only after the real SessionStart hook
# has registered the immutable context and created revision zero.
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data"
# shellcheck disable=SC1091
source "$ROOT/tests/session-control/initialize-baseline.sh" "$RAW"
# SessionStart canonicalizes the project path (notably /var -> /private/var on
# macOS); all exact path assertions must use that authority.
PROJECT="$ZENSU_PROJECT_ROOT"

STATE_PATH="$(CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION'; source '$PHASE'; tdd_state_file '$RAW'")"
EXPECTED_STATE="$PROJECT/.zensu/state/tdd-phase-$EXPECTED.json"
[ "$STATE_PATH" = "$EXPECTED_STATE" ] && check "workflow state is keyed only by the hashed session id" PASS || check "workflow state is keyed only by the hashed session id" FAIL

CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION'; source '$PHASE'; tdd_write_phase '$RAW' one RED_WRITE ''; tdd_write_phase '$RAW' one RED_FAIL expected"
[ -f "$EXPECTED_STATE" ] && check "phase writes converge on the hashed state file" PASS || check "phase writes converge on the hashed state file" FAIL

REVISION="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.revision))' "$EXPECTED_STATE" 2>/dev/null)"
SCHEMA="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.schema))' "$EXPECTED_STATE" 2>/dev/null)"
HASH="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.session_id_hash))' "$EXPECTED_STATE" 2>/dev/null)"
if [ "$REVISION" = 3 ] && [ "$SCHEMA" = zensu.workflow-state ] && printf '%s' "$HASH" | grep -Eq '^sha256:[a-f0-9]{64}$'; then
  check "each atomic phase mutation increments the schema-versioned revision" PASS
else
  check "each atomic phase mutation increments the schema-versioned revision" FAIL
fi

FOREIGN_STATE="$PROJECT/.zensu/state/tdd-phase-$FOREIGN_KEY.json"
if ZENSU_SESSION_KEY="$EXPECTED" CLAUDE_PROJECT_DIR="$PROJECT" \
  bash -c "source '$SESSION'; source '$PHASE'; tdd_set_flag '$FOREIGN_RAW' active true" \
  >"$TMP/foreign-mutation.out" 2>/dev/null; then
  check "bound workflow helper rejects a foreign-session state mutation" FAIL
else
  [ ! -e "$FOREIGN_STATE" ] && check "bound workflow helper rejects a foreign-session state mutation" PASS || check "bound workflow helper rejects a foreign-session state mutation" FAIL
fi

CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION'; source '$PHASE'; tdd_set_flag '$RAW' active true; tdd_workflow_begin '$RAW' 'Read,Grep'"
REVISION_WORKFLOW="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.revision))' "$EXPECTED_STATE" 2>/dev/null)"
[ "$REVISION_WORKFLOW" = 5 ] && check "flag and workflow mutations increment the same revision" PASS || check "flag and workflow mutations increment the same revision" FAIL

CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION'; source '$PHASE'; tdd_reset_chain_flags '$RAW'; tdd_clear_session '$RAW'"
REVISION_RESET="$(node -e 'const j=require(process.argv[1]); process.stdout.write(String(j.revision))' "$EXPECTED_STATE" 2>/dev/null)"
[ "$REVISION_RESET" = 7 ] && check "chain reset and session clear each increment revision" PASS || check "chain reset and session clear each increment revision" FAIL

CONCURRENT='claude/concurrent workflow state'
CONCURRENT_KEY="$(node "$CORE" session-key "$CONCURRENT")"
CONCURRENT_STATE="$PROJECT/.zensu/state/tdd-phase-$CONCURRENT_KEY.json"
# Switch the immutable test context to the concurrent raw session before
# launching its 24 writers.
source "$ROOT/tests/session-control/initialize-baseline.sh" "$CONCURRENT"
PIDS=""
for lane in $(seq 1 24); do
  CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION'; source '$PHASE'; tdd_set_flag '$CONCURRENT' 'lane_$lane' true" &
  PIDS="$PIDS $!"
done
CONCURRENT_FAIL=0
for pid in $PIDS; do wait "$pid" || CONCURRENT_FAIL=1; done
CONCURRENT_RESULT="$(node -e '
  const s=require(process.argv[1]);
  const lanes=Object.keys(s).filter(k => /^lane_[0-9]+$/.test(k) && s[k]===true).length;
  process.stdout.write(`${s.revision}:${lanes}`);
' "$CONCURRENT_STATE" 2>/dev/null)"
if [ "$CONCURRENT_FAIL" -eq 0 ] && [ "$CONCURRENT_RESULT" = "25:24" ] && ! find "$PROJECT/.zensu/state" -maxdepth 1 \( -name '*.lock' -o -name '*.recovery' \) | grep -q .; then
  check "24 real shell mutations share the Core CAS lock without lost revisions" PASS
else
  check "24 real shell mutations share the Core CAS lock without lost revisions (got $CONCURRENT_RESULT)" FAIL
fi

if grep -R -F -q "$RAW" "$PROJECT/.zensu/state"; then
  check "workflow state never persists the raw host session id" FAIL
else
  check "workflow state never persists the raw host session id" PASS
fi

printf '%s\n' "----" "test-session-id-v1: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
