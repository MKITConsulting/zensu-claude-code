#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-session.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "hooks/lib/zensu-session.sh exists" FAIL
  echo "----"
  echo "test-session-id-fallback: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S2-C0 hooks/lib/zensu-session.sh exists" PASS

if bash -n "$HELPER" 2>/dev/null; then
  check "S2-C0a bash -n syntax check on zensu-session.sh" PASS
else
  check "S2-C0a bash -n syntax check on zensu-session.sh" FAIL
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
PROJECT_DIR="$TMP_DIR/proj"
mkdir -p "$PROJECT_DIR/.zensu/state"

# Case 1 — stdin id present → returned verbatim sanitized.
OUT1=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash -c "source '$HELPER'; zensu_resolve_session_id 'abc-123_real'")
if [ "$OUT1" = "abc-123_real" ]; then
  check "S2-C1 stdin session_id present and sanitization-safe -> returned verbatim" PASS
else
  check "S2-C1 stdin session_id (got '$OUT1')" FAIL
fi

# Case 4 — sanitization strips dangerous chars.
OUT4=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash -c "source '$HELPER'; zensu_resolve_session_id '../foo/bar baz'")
case "$OUT4" in
  *../*|*/*|*' '*)
    check "S2-C4 dangerous chars stripped (got '$OUT4')" FAIL ;;
  *)
    if [ -n "$OUT4" ]; then
      check "S2-C4 dangerous chars (../, /, space) stripped from sanitized result" PASS
    else
      check "S2-C4 sanitized id non-empty after stripping" FAIL
    fi
    ;;
esac

# Case 6 — zensu_session_key returns stable ${PPID}_${cksum_of_lstart} shape.
KEY1=$(bash -c "source '$HELPER'; zensu_session_key")
case "$KEY1" in
  [0-9]*_[0-9]*)
    check "S2-C6 zensu_session_key shape matches '<pid>_<cksum>' (got '$KEY1')" PASS ;;
  [0-9]*)
    check "S2-C6 zensu_session_key shape matches bare pid fallback (got '$KEY1')" PASS ;;
  *)
    check "S2-C6 zensu_session_key shape (got '$KEY1')" FAIL ;;
esac

PAIR_OUT=$(bash -c "source '$HELPER'; zensu_session_key; zensu_session_key")
KEY1A=$(echo "$PAIR_OUT" | head -1)
KEY1B=$(echo "$PAIR_OUT" | tail -1)
if [ "$KEY1A" = "$KEY1B" ] && [ -n "$KEY1A" ]; then
  check "S2-C6b zensu_session_key stable across two calls in same shell" PASS
else
  check "S2-C6b zensu_session_key stable (a='$KEY1A' b='$KEY1B')" FAIL
fi

# Case 2 — stdin empty + cache file present at PPID+proc_hash key → cache value returned.
# We compute the key from a wrapper subshell so we know which file to seed.
SEED_SCRIPT="$TMP_DIR/seed-case2.sh"
cat > "$SEED_SCRIPT" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
mkdir -p "$PROJECT_DIR/.zensu/state"
echo "cached-sid-value" > "$PROJECT_DIR/.zensu/state/session-id-\${KEY}.txt"
RESOLVED=\$(zensu_resolve_session_id "")
echo "RESOLVED=\${RESOLVED}"
echo "KEY=\${KEY}"
EOF
chmod +x "$SEED_SCRIPT"
OUT2_RAW=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$SEED_SCRIPT" 2>&1)
OUT2=$(echo "$OUT2_RAW" | grep '^RESOLVED=' | cut -d= -f2-)
if [ "$OUT2" = "cached-sid-value" ]; then
  check "S2-C2 stdin empty + cache file present -> cache value returned" PASS
else
  check "S2-C2 stdin empty + cache file (got '$OUT2' raw='$OUT2_RAW')" FAIL
fi

# Case 5 — cache file with empty contents falls to tier-3 deterministic fallback.
SEED5_SCRIPT="$TMP_DIR/seed-case5.sh"
PROJECT_DIR5="$TMP_DIR/proj5"
mkdir -p "$PROJECT_DIR5/.zensu/state"
cat > "$SEED5_SCRIPT" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
mkdir -p "$PROJECT_DIR5/.zensu/state"
: > "$PROJECT_DIR5/.zensu/state/session-id-\${KEY}.txt"
RESOLVED=\$(zensu_resolve_session_id "")
echo "RESOLVED=\${RESOLVED}"
echo "KEY=\${KEY}"
EOF
chmod +x "$SEED5_SCRIPT"
OUT5_RAW=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR5" "$SEED5_SCRIPT" 2>&1)
OUT5=$(echo "$OUT5_RAW" | grep '^RESOLVED=' | cut -d= -f2-)
KEY5=$(echo "$OUT5_RAW" | grep '^KEY=' | cut -d= -f2-)
EXPECTED5="fallback_${KEY5}"
if [ "$OUT5" = "$EXPECTED5" ]; then
  check "S2-C5 cache file with empty contents -> deterministic tier-3 fallback (fallback_<key>)" PASS
else
  check "S2-C5 empty cache file (got '$OUT5' expected '$EXPECTED5' raw='$OUT5_RAW')" FAIL
fi

# Case 3 — stdin empty + cache MISSING → claude_${PPID}_${proc_hash} returned.
PROJECT_DIR3="$TMP_DIR/proj3"
mkdir -p "$PROJECT_DIR3/.zensu/state"
SEED3_SCRIPT="$TMP_DIR/seed-case3.sh"
cat > "$SEED3_SCRIPT" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
RESOLVED=\$(zensu_resolve_session_id "")
echo "RESOLVED=\${RESOLVED}"
echo "KEY=\${KEY}"
EOF
chmod +x "$SEED3_SCRIPT"
OUT3_RAW=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR3" "$SEED3_SCRIPT" 2>&1)
OUT3=$(echo "$OUT3_RAW" | grep '^RESOLVED=' | cut -d= -f2-)
KEY3=$(echo "$OUT3_RAW" | grep '^KEY=' | cut -d= -f2-)
EXPECTED3="fallback_${KEY3}"
if [ "$OUT3" = "$EXPECTED3" ]; then
  check "S2-C3 stdin empty + cache missing -> fallback_<key> deterministic fallback" PASS
else
  check "S2-C3 cache-missing fallback (got '$OUT3' expected '$EXPECTED3')" FAIL
fi

case "$OUT3" in
  *unknown*)
    check "S2-C3b fallback never contains literal 'unknown' string" FAIL ;;
  *)
    check "S2-C3b fallback never contains literal 'unknown' string" PASS ;;
esac

# Case 7 — graceful degradation when ps/cksum missing → bare ${PPID}.
DEGRADE_DIR="$TMP_DIR/degraded-path"
mkdir -p "$DEGRADE_DIR"
cat > "$DEGRADE_DIR/ps" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$DEGRADE_DIR/cksum" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$DEGRADE_DIR/ps" "$DEGRADE_DIR/cksum"
DEGRADED_KEY=$(env PATH="$DEGRADE_DIR:/usr/bin:/bin" bash -c "source '$HELPER'; zensu_session_key")
case "$DEGRADED_KEY" in
  [0-9]*_*)
    check "S2-C7 ps + cksum failing but key still contains underscore (unexpected, ps stub did not block)" FAIL ;;
  [0-9]*)
    check "S2-C7 ps/cksum stubbed-failing -> bare numeric PPID fallback" PASS ;;
  *)
    check "S2-C7 ps/cksum stubbed-failing (got '$DEGRADED_KEY')" FAIL ;;
esac

DEGRADED_RESOLVE=$(env PATH="$DEGRADE_DIR:/usr/bin:/bin" CLAUDE_PROJECT_DIR="$PROJECT_DIR3" bash -c "source '$HELPER'; zensu_resolve_session_id ''")
case "$DEGRADED_RESOLVE" in
  fallback_[0-9]*)
    check "S2-C7b ps/cksum failing -> resolve returns fallback_<bare-pid>" PASS ;;
  *)
    check "S2-C7b ps/cksum failing resolve (got '$DEGRADED_RESOLVE')" FAIL ;;
esac

PROJECT_DIR8="$TMP_DIR/proj8"
mkdir -p "$PROJECT_DIR8/.zensu/state"
SEED8_SCRIPT="$TMP_DIR/seed-case8.sh"
cat > "$SEED8_SCRIPT" <<EOF
#!/bin/bash
set -u
source "$HELPER"
KEY=\$(zensu_session_key)
echo "cached-sid-c8" > "$PROJECT_DIR8/.zensu/state/session-id-\${KEY}.txt"
unset CLAUDE_SESSION_ID
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT_DIR8"
( source "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --phase IMPL --step demo ) >/dev/null 2>&1
echo "KEY=\${KEY}"
EOF
chmod +x "$SEED8_SCRIPT"
OUT8_RAW=$("$SEED8_SCRIPT" 2>&1)
KEY8=$(echo "$OUT8_RAW" | grep '^KEY=' | cut -d= -f2-)
if [ -f "$PROJECT_DIR8/.zensu/state/tdd-phase-cached-sid-c8.json" ]; then
  check "S2-C8 zensu-log.sh routes phase write to cached session id (3-tier resolver)" PASS
else
  check "S2-C8 zensu-log.sh tdd-phase-cached-sid-c8.json missing (raw='$OUT8_RAW' key='$KEY8')" FAIL
fi
if [ ! -f "$PROJECT_DIR8/.zensu/state/tdd-phase-fallback_${KEY8}.json" ]; then
  check "S2-C8b zensu-log.sh does NOT write tier-3 fallback bucket when cache present" PASS
else
  check "S2-C8b zensu-log.sh leaked tier-3 fallback file despite cache hit" FAIL
fi

echo "----"
echo "test-session-id-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
