#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$LIB" ]; then
  check "hooks/lib/zensu-vcs.sh exists" FAIL
  echo "----"
  echo "test-vcs-pr-ops: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "P1 lib exists" PASS
bash -n "$LIB" 2>/dev/null && check "P2 bash -n syntax check passes" PASS || check "P2 bash -n syntax check passes" FAIL

eq()  { local l="$1" g="$2" w="$3"; [ "$g" = "$w" ] && check "$l" PASS || check "$l (got '$g' want '$w')" FAIL; }
has() { local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l" PASS ;; *) check "$l (missing '$n')" FAIL ;; esac; }
nothas() { local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l (unexpected '$n')" FAIL ;; *) check "$l" PASS ;; esac; }

argv() { env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1 bash "$LIB" "$@" 2>/dev/null; }

# ---- argv builders (hermetic; no gh/glab execution) ----
eq  "A1 pr-state github"        "$(argv --pr-state --provider github 42)"  "gh pr view --json state -- 42"
eq  "A2 pr-state gitlab"        "$(argv --pr-state --provider gitlab 42)"  "glab mr view --output json -- 42"
eq  "A3 locate-pr github num"   "$(argv --locate-pr --provider github 42)" "gh pr view --json number,url,state,headRefName,baseRefName -- 42"
eq  "A4 locate-pr github branch" "$(argv --locate-pr --provider github)"   "gh pr view --json number,url,state,headRefName,baseRefName"
eq  "A5 locate-pr gitlab branch" "$(argv --locate-pr --provider gitlab)"   "glab mr view --output json"
eq  "A5b locate-pr gitlab num"  "$(argv --locate-pr --provider gitlab 7)"  "glab mr view --output json -- 7"

GHF="$(argv --fetch-threads --provider github --repo-id acme/widget 42)"
has "A6a fetch github -> gh api graphql" "$GHF" "gh api graphql"
has "A6b fetch github reviewThreads"     "$GHF" "reviewThreads"
has "A6c fetch github owner var"         "$GHF" "owner=acme"
has "A6d fetch github name var"          "$GHF" "name=widget"
has "A6e fetch github num var"           "$GHF" "num=42"
eq  "A7 fetch gitlab -> discussions"     "$(argv --fetch-threads --provider gitlab --repo-id grp%2Fproj 7)" "glab api --paginate projects/grp%2Fproj/merge_requests/7/discussions"

GHR="$(argv --resolve-thread --provider github --repo-id acme/widget --reply 'fixed in abc' 42 RT_1 111)"
has "A8a resolve github mutation"        "$GHR" "resolveReviewThread"
has "A8b resolve github thread var"      "$GHR" "t=RT_1"
has "A8c resolve github reply endpoint"  "$GHR" "pulls/42/comments/111/replies"
nothas "A8d resolve github not glab"     "$GHR" "glab"

GLR="$(argv --resolve-thread --provider gitlab --repo-id grp%2Fproj 7 d1)"
has "A9a resolve gitlab PUT resolved"    "$GLR" "--method PUT"
has "A9b resolve gitlab discussion path" "$GLR" "discussions/d1?resolved=true"
nothas "A9c resolve gitlab no reply note (no --reply)" "$GLR" "/notes"
nothas "A9d resolve gitlab not gh"       "$GLR" "gh api"

GLR2="$(argv --resolve-thread --provider gitlab --repo-id grp%2Fproj --reply 'ok' 7 d1)"
has "A9e resolve gitlab WITH reply -> notes POST" "$GLR2" "discussions/d1/notes"
has "A9f resolve gitlab reply body"      "$GLR2" "body=ok"

# ---- guards (fail-loud) + resolve-no-reply + reply_to fallback ----
fails() { local l="$1"; shift; local o rc; o="$(argv "$@" 2>/dev/null)"; rc=$?; { [ -z "$o" ] && [ "$rc" -ne 0 ]; } && check "$l" PASS || check "$l (out='$o' rc=$rc)" FAIL; }
fails "G1 op requires --provider (fail loud)"    --pr-state 42
fails "G2 unknown provider -> non-zero"          --pr-state --provider bogus 42
fails "G3 non-numeric id rejected (fetch)"       --fetch-threads --provider gitlab --repo-id x 'ev?a=b'
fails "G4 github repo-id without slash rejected" --fetch-threads --provider github --repo-id noslash 42
fails "G5 non-id thread rejected (resolve)"      --resolve-thread --provider gitlab --repo-id x 7 'd?x=1'

GHRN="$(argv --resolve-thread --provider github --repo-id acme/widget 42 RT_1 111)"
has    "A10 resolve github no-reply -> mutation"     "$GHRN" "resolveReviewThread"
nothas "A10b resolve github no-reply -> no /replies" "$GHRN" "/replies"

GHRF="$(argv --resolve-thread --provider github --repo-id acme/widget --reply x 42 RT_1)"
has    "A11 resolve github reply_to defaults to threadId" "$GHRF" "comments/RT_1/replies"

# ---- normalizers (source + fixtures) ----
source "$LIB" >/dev/null 2>&1

GH_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_1","isResolved":false,"comments":{"nodes":[{"databaseId":111,"body":"fix this","path":"a.js","line":10,"author":{"login":"alice"}}]}},{"id":"RT_2","isResolved":true,"comments":{"nodes":[{"databaseId":222,"body":"done","path":"b.js","line":5,"author":{"login":"bob"}}]}}]}}}}}'
N1="$(printf '%s' "$GH_THREADS" | _zensu_vcs_normalize_threads github)"
eq     "N1 github normalize (unresolved only)" "$N1" '[{"threadId":"RT_1","replyTo":"111","path":"a.js","line":10,"body":"fix this","author":"alice"}]'
nothas "N1b github filters resolved RT_2"      "$N1" "RT_2"
has    "N1c github surfaces threadId"          "$N1" '"threadId":"RT_1"'
has    "N1d github surfaces replyTo"           "$N1" '"replyTo":"111"'

GL_THREADS='[{"id":"d1","resolvable":true,"resolved":false,"notes":[{"body":"nit","author":{"username":"carol"},"position":{"new_path":"c.rb","new_line":7}}]},{"id":"d2","resolvable":true,"resolved":true,"notes":[{"body":"ok"}]},{"id":"d3","resolvable":false,"resolved":false,"notes":[{"body":"x"}]}]'
N2="$(printf '%s' "$GL_THREADS" | _zensu_vcs_normalize_threads gitlab)"
eq     "N2 gitlab normalize (resolvable & unresolved)" "$N2" '[{"threadId":"d1","replyTo":"d1","path":"c.rb","line":7,"body":"nit","author":"carol"}]'
nothas "N2b gitlab filters resolved d2"        "$N2" '"d2"'
nothas "N2c gitlab filters non-resolvable d3"  "$N2" '"d3"'
has    "N2d gitlab threadId==replyTo (discussion id)" "$N2" '"threadId":"d1","replyTo":"d1"'

eq "N3 map_state github MERGED"  "$(printf '%s' '{"state":"MERGED"}'  | _zensu_vcs_map_state github)" "MERGED"
eq "N4 map_state gitlab opened"  "$(printf '%s' '{"state":"opened"}'  | _zensu_vcs_map_state gitlab)" "OPEN"
eq "N5 map_state gitlab closed"  "$(printf '%s' '{"state":"closed"}'  | _zensu_vcs_map_state gitlab)" "CLOSED"
eq "N5b map_state gitlab locked" "$(printf '%s' '{"state":"locked"}'  | _zensu_vcs_map_state gitlab)" "OPEN"

eq "N6 normalize_pr github" "$(printf '%s' '{"number":42,"url":"u","state":"OPEN","headRefName":"feat","baseRefName":"main"}' | _zensu_vcs_normalize_pr github)" '{"id":"42","url":"u","state":"OPEN","base":"main","head":"feat"}'
eq "N7 normalize_pr gitlab" "$(printf '%s' '{"iid":7,"web_url":"w","state":"merged","source_branch":"s","target_branch":"t"}' | _zensu_vcs_normalize_pr gitlab)" '{"id":"7","url":"w","state":"MERGED","base":"t","head":"s"}'

BASH_ABS="$(command -v bash)"
N8="$(PATH=/dev/null "$BASH_ABS" -c 'source '"$LIB"'; printf "%s" "{}" | _zensu_vcs_normalize_threads github' 2>/dev/null)"
eq "N8 normalize_threads no-node -> []" "$N8" "[]"

eq "N9 map_state unknown -> empty" "$(printf '%s' '{"state":"draft"}' | _zensu_vcs_map_state github)" ""
eq "N10 map_state empty -> empty"  "$(printf '%s' '{}' | _zensu_vcs_map_state gitlab)" ""
eq "N11 normalize_pr closed"       "$(printf '%s' '{"number":9,"url":"u","state":"closed","headRefName":"h","baseRefName":"b"}' | _zensu_vcs_normalize_pr github)" '{"id":"9","url":"u","state":"CLOSED","base":"b","head":"h"}'
eq "N12 normalize_pr empty input"  "$(printf '%s' '{}' | _zensu_vcs_normalize_pr github)" '{"id":"","url":"","state":"","base":"","head":""}'
eq "N13 normalize_threads malformed -> []" "$(printf '%s' 'not json' | _zensu_vcs_normalize_threads github)" "[]"

( export ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1; _zensu_vcs_dry ) && check "N14a dry: both set -> dry" PASS || check "N14a dry: both set -> dry" FAIL
( export ZENSU_VCS_PRINT_ARGV=1; _zensu_vcs_dry ) && check "N14b dry: TEST unset -> NOT dry" FAIL || check "N14b dry: TEST unset -> NOT dry" PASS
( export ZENSU_VCS_TEST=1; _zensu_vcs_dry ) && check "N14c dry: PRINT unset -> NOT dry" FAIL || check "N14c dry: PRINT unset -> NOT dry" PASS

echo "----"
echo "test-vcs-pr-ops: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
