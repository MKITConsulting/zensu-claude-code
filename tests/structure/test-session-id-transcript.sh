#!/bin/bash
# Pins the cross-contamination fix (0.8.x): resolve-session-id.js prefers the
# hook-input transcript_path (each agent's OWN transcript) over the newest
# .jsonl by mtime in the shared projects dir, so concurrent Workflow agents do
# not cross-resolve to each other's TDD state. The session_id field stays
# primary. Complements test-resolve-session-id.sh.
set -u

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  SKIP  test-session-id-transcript on Windows — POSIX-path harness"
    exit 0 ;;
esac

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/resolve-session-id.js"
SESSION_HELPER="$PLUGIN_DIR/hooks/lib/zensu-session.sh"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

TMP="$(mktemp -d -t "sid-transcript-XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PROJECT="/users/wf/repo"
SAN="$(printf '%s' "$PROJECT" | tr '/\\:.' '-')"
PDIR="$TMP/projects/$SAN"
mkdir -p "$PDIR"
OWN="aaaaaaaa-own0-1111-2222-aaaaaaaaaaaa"
NEWEST="zzzzzzzz-new0-1111-2222-zzzzzzzzzzzz"
: > "$PDIR/$OWN.jsonl"
: > "$PDIR/$NEWEST.jsonl"
OWN_FULL="$PDIR/$OWN.jsonl" NEWEST_FULL="$PDIR/$NEWEST.jsonl" node -e '
  const fs = require("fs");
  const n = Date.now();
  fs.utimesSync(process.env.OWN_FULL, (n-5000)/1000, (n-5000)/1000);
  fs.utimesSync(process.env.NEWEST_FULL, (n-100)/1000, (n-100)/1000);
'

OUT="$(ZENSU_PROJECTS_DIR="$TMP/projects" CLAUDE_PROJECT_DIR="$PROJECT" node "$HELPER")"
[ "$OUT" = "$NEWEST" ] \
  && check "T1 no transcript_path -> newest by mtime (baseline preserved)" PASS \
  || check "T1 baseline newest (got '$OUT' expected '$NEWEST')" FAIL

OUT="$(ZENSU_TRANSCRIPT_PATH="$PDIR/$OWN.jsonl" ZENSU_PROJECTS_DIR="$TMP/projects" CLAUDE_PROJECT_DIR="$PROJECT" node "$HELPER")"
[ "$OUT" = "$OWN" ] \
  && check "T2 transcript_path wins over newest mtime (no crosstalk to sibling agent)" PASS \
  || check "T2 transcript wins (got '$OUT' expected '$OWN')" FAIL

OUT="$(ZENSU_TRANSCRIPT_PATH="/some/where/not-a-transcript.txt" ZENSU_PROJECTS_DIR="$TMP/projects" CLAUDE_PROJECT_DIR="$PROJECT" node "$HELPER")"
[ "$OUT" = "$NEWEST" ] \
  && check "T3 non-.jsonl transcript_path -> mtime fallback" PASS \
  || check "T3 non-jsonl fallback (got '$OUT' expected '$NEWEST')" FAIL

OUT="$(ZENSU_TRANSCRIPT_PATH="$PDIR/$OWN.jsonl" ZENSU_PROJECTS_DIR="$TMP/projects" CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION_HELPER'; zensu_resolve_session_id ''")"
[ "$OUT" = "$OWN" ] \
  && check "T4 zensu_resolve_session_id threads transcript_path to helper" PASS \
  || check "T4 wired transcript (got '$OUT' expected '$OWN')" FAIL

OUT="$(ZENSU_TRANSCRIPT_PATH="$PDIR/$OWN.jsonl" ZENSU_PROJECTS_DIR="$TMP/projects" CLAUDE_PROJECT_DIR="$PROJECT" bash -c "source '$SESSION_HELPER'; zensu_resolve_session_id 'explicit-session-id'")"
[ "$OUT" = "explicit-session-id" ] \
  && check "T5 session_id field stays primary over transcript_path" PASS \
  || check "T5 field primary (got '$OUT' expected 'explicit-session-id')" FAIL

echo "----"
echo "test-session-id-transcript: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
