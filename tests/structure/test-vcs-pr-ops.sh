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
has "A6f fetch github exhausts pagination" "$GHF" "--paginate --slurp"
has "A6g fetch github query exposes pageInfo" "$GHF" "pageInfo{hasNextPage endCursor}"
has "A6h fetch github query accepts cursor" "$GHF" 'after:$endCursor'
eq  "A7 fetch gitlab -> paginated JSON discussions" "$(argv --fetch-threads --provider gitlab --repo-id grp%2Fproj 7)" "glab api --paginate --output json projects/grp%2Fproj/merge_requests/7/discussions"

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
fails "G6 github repo-id rejects extra path segments" --fetch-threads --provider github --repo-id acme/widget/extra 42
fails "G7 gitlab repo-id rejects malformed percent escapes" --fetch-threads --provider gitlab --repo-id 'grp%ZZproj' 7
fails "G8 gitlab repo-id rejects traversal-like dot pairs" --resolve-thread --provider gitlab --repo-id 'grp..proj' 7 d1

GHRN="$(argv --resolve-thread --provider github --repo-id acme/widget 42 RT_1 111)"
has    "A10 resolve github no-reply -> mutation"     "$GHRN" "resolveReviewThread"
nothas "A10b resolve github no-reply -> no /replies" "$GHRN" "/replies"

GHRF="$(argv --resolve-thread --provider github --repo-id acme/widget --reply x 42 RT_1)"
has    "A11 resolve github reply_to defaults to threadId" "$GHRF" "comments/RT_1/replies"

# ---- open-pr (autopilot; hermetic, no gh/glab execution) ----
OPBF="$(mktemp)"; printf 'PR body content\n' > "$OPBF"
GHOP="$(argv --open-pr --provider github --base main --head feat --title 'My PR' --body-file "$OPBF")"
eq     "O1 open-pr github argv"              "$GHOP" "gh pr create --title My PR --body-file $OPBF --base main --head feat"
nothas "O1b open-pr github not glab"         "$GHOP" "glab"

GLOP="$(argv --open-pr --provider gitlab --base main --head feat --title 'My PR' --body-file "$OPBF")"
eq     "O2 open-pr gitlab argv"              "$GLOP" "glab mr create --title My PR --description PR body content --source-branch feat --target-branch main --yes"
has    "O2a open-pr gitlab -> glab mr create" "$GLOP" "glab mr create"
has    "O2b open-pr gitlab description inline (body content)" "$GLOP" "--description PR body content"
has    "O2c open-pr gitlab head->source-branch"   "$GLOP" "--source-branch feat"
has    "O2d open-pr gitlab base->target-branch"   "$GLOP" "--target-branch main"
has    "O2e open-pr gitlab non-interactive --yes" "$GLOP" "--yes"
nothas "O2f open-pr gitlab not gh pr create"      "$GLOP" "gh pr create"

fails "O3 open-pr requires --provider"   --open-pr --base main --head feat --title T --body-file "$OPBF"
fails "O4 open-pr unknown provider"      --open-pr --provider bogus --base main --head feat --title T --body-file "$OPBF"
fails "O5 open-pr requires --base"       --open-pr --provider github --head feat --title T --body-file "$OPBF"
fails "O6 open-pr requires --head"       --open-pr --provider github --base main --title T --body-file "$OPBF"
fails "O7 open-pr requires --body-file"  --open-pr --provider github --base main --head feat --title T
fails "O8 open-pr requires --title"      --open-pr --provider github --base main --head feat --body-file "$OPBF"
rm -f "$OPBF"

# ---- normalizers (source + fixtures) ----
source "$LIB" >/dev/null 2>&1

# ---- open-pr URL normalizer (_zensu_vcs_extract_url; pure fn, the --open-pr return value) ----
eq "U1 extract github pull url"     "$(printf 'https://github.com/acme/widget/pull/42\n' | _zensu_vcs_extract_url)" "https://github.com/acme/widget/pull/42"
eq "U2 extract gitlab mr url"       "$(printf 'https://gitlab.com/grp/proj/-/merge_requests/7\n' | _zensu_vcs_extract_url)" "https://gitlab.com/grp/proj/-/merge_requests/7"
eq "U3 extract prefers PR url over preceding non-PR url" "$(printf 'Run: https://github.com/acme/widget/actions/runs/9\nhttps://github.com/acme/widget/pull/42\n' | _zensu_vcs_extract_url)" "https://github.com/acme/widget/pull/42"
eq "U4 extract https fallback (no PR url)" "$(printf 'created: https://example.test/x/y\n' | _zensu_vcs_extract_url)" "https://example.test/x/y"
eq "U5 extract strips control/ANSI bytes"  "$(printf 'https://github.com/acme/widget/pull/9%b[0m\n' '\033' | _zensu_vcs_extract_url)" "https://github.com/acme/widget/pull/9[0m"
eq "U6 extract empty on no url"     "$(printf 'no url here\n' | _zensu_vcs_extract_url)" ""

GH_THREADS='[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_1","isResolved":false,"comments":{"nodes":[{"databaseId":111,"body":"fix this","path":"a.js","line":10,"author":{"login":"alice"}}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}}},{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_2","isResolved":true,"comments":{"nodes":[{"databaseId":222,"body":"done","path":"b.js","line":5,"author":{"login":"bob"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
N1="$(printf '%s' "$GH_THREADS" | _zensu_vcs_normalize_threads github)"
eq     "N1 github normalize (unresolved only)" "$N1" '[{"threadId":"RT_1","replyTo":"111","path":"a.js","line":10,"body":"fix this","author":"alice"}]'
nothas "N1b github filters resolved RT_2"      "$N1" "RT_2"
has    "N1c github surfaces threadId"          "$N1" '"threadId":"RT_1"'
has    "N1d github surfaces replyTo"           "$N1" '"replyTo":"111"'

GL_THREADS='[[{"id":"d1","notes":[{"id":101,"resolvable":true,"resolved":false,"body":"nit","author":{"username":"carol"},"position":{"old_path":"c.rb","old_line":7}}]},{"id":"d2","notes":[{"id":202,"resolvable":true,"resolved":true,"body":"ok"}]},{"id":"d3","notes":[{"id":303,"resolvable":false,"resolved":false,"body":"x"}]}],[{"id":"d1","notes":[{"id":101,"resolvable":true,"resolved":false,"body":"nit","author":{"username":"carol"},"position":{"old_path":"c.rb","old_line":7}}]}]]'
N2="$(printf '%s' "$GL_THREADS" | _zensu_vcs_normalize_threads gitlab)"
eq     "N2 gitlab normalize (resolvable & unresolved)" "$N2" '[{"threadId":"d1","replyTo":"d1","path":"c.rb","line":7,"body":"nit","author":"carol"}]'
nothas "N2b gitlab filters resolved d2"        "$N2" '"d2"'
nothas "N2c gitlab filters non-resolvable d3"  "$N2" '"d3"'
has    "N2d gitlab threadId==replyTo (discussion id)" "$N2" '"threadId":"d1","replyTo":"d1"'

eq "N3 map_state github MERGED"  "$(printf '%s' '{"state":"MERGED"}'  | _zensu_vcs_map_state github)" "MERGED"
eq "N4 map_state gitlab opened"  "$(printf '%s' '{"state":"opened"}'  | _zensu_vcs_map_state gitlab)" "OPEN"
eq "N5 map_state gitlab closed"  "$(printf '%s' '{"state":"closed"}'  | _zensu_vcs_map_state gitlab)" "CLOSED"
eq "N5b map_state gitlab locked" "$(printf '%s' '{"state":"locked"}'  | _zensu_vcs_map_state gitlab)" "OPEN"

eq "N6 normalize_pr github" "$(printf '%s' '{"number":42,"url":"https://github.test/acme/widget/pull/42","state":"OPEN","headRefName":"feat","baseRefName":"main"}' | _zensu_vcs_normalize_pr github)" '{"id":"42","url":"https://github.test/acme/widget/pull/42","state":"OPEN","base":"main","head":"feat"}'
eq "N7 normalize_pr gitlab" "$(printf '%s' '{"iid":7,"web_url":"https://gitlab.test/grp/proj/-/merge_requests/7","state":"merged","source_branch":"s","target_branch":"t"}' | _zensu_vcs_normalize_pr gitlab)" '{"id":"7","url":"https://gitlab.test/grp/proj/-/merge_requests/7","state":"MERGED","base":"t","head":"s"}'

BASH_ABS="$(command -v bash)"
if PATH=/dev/null "$BASH_ABS" -c 'source '"$LIB"'; printf "%s" "{}" | _zensu_vcs_normalize_threads github' >/dev/null 2>&1; then
  check "N8 normalize_threads without Node fails closed" FAIL
else
  check "N8 normalize_threads without Node fails closed" PASS
fi
if PATH=/dev/null "$BASH_ABS" -c 'source '"$LIB"'; printf "%s" "{\"state\":\"OPEN\"}" | _zensu_vcs_map_state github' >/dev/null 2>&1; then
  check "N8b map_state without Node fails closed" FAIL
else
  check "N8b map_state without Node fails closed" PASS
fi
if PATH=/dev/null "$BASH_ABS" -c 'source '"$LIB"'; printf "%s" "{\"html_url\":\"https://x\"}" | _zensu_vcs_json_field html_url' >/dev/null 2>&1; then
  check "N8c JSON extraction without Node fails closed" FAIL
else
  check "N8c JSON extraction without Node fails closed" PASS
fi

if printf '%s' '{"state":"draft"}' | _zensu_vcs_map_state github >/dev/null 2>&1; then check "N9 map_state unknown -> non-zero" FAIL; else check "N9 map_state unknown -> non-zero" PASS; fi
if printf '%s' '{}' | _zensu_vcs_map_state gitlab >/dev/null 2>&1; then check "N10 map_state missing state -> non-zero" FAIL; else check "N10 map_state missing state -> non-zero" PASS; fi
eq "N11 normalize_pr closed"       "$(printf '%s' '{"number":9,"url":"https://github.test/acme/widget/pull/9","state":"closed","headRefName":"h","baseRefName":"b"}' | _zensu_vcs_normalize_pr github)" '{"id":"9","url":"https://github.test/acme/widget/pull/9","state":"CLOSED","base":"b","head":"h"}'
if printf '%s' '{}' | _zensu_vcs_normalize_pr github >/dev/null 2>&1; then check "N12 normalize_pr incomplete input -> non-zero" FAIL; else check "N12 normalize_pr incomplete input -> non-zero" PASS; fi
if printf '%s' 'not json' | _zensu_vcs_normalize_threads github >/dev/null 2>&1; then
  check "N13 normalize_threads malformed -> non-zero" FAIL
else
  check "N13 normalize_threads malformed -> non-zero" PASS
fi
GH_THREADS_TRUNCATED='[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}}]'
if printf '%s' "$GH_THREADS_TRUNCATED" | _zensu_vcs_normalize_threads github >/dev/null 2>&1; then
  check "N13b normalize_threads rejects a truncated final page" FAIL
else
  check "N13b normalize_threads rejects a truncated final page" PASS
fi
GH_THREADS_DUP_CONFLICT='[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_DUP","isResolved":false,"comments":{"nodes":[{"databaseId":1,"body":"first","path":"a.js","line":1,"author":{"login":"alice"}}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}},{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_DUP","isResolved":false,"comments":{"nodes":[{"databaseId":1,"body":"changed","path":"a.js","line":1,"author":{"login":"alice"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
if printf '%s' "$GH_THREADS_DUP_CONFLICT" | _zensu_vcs_normalize_threads github >/dev/null 2>&1; then
  check "N13c conflicting duplicate GitHub thread fails closed" FAIL
else
  check "N13c conflicting duplicate GitHub thread fails closed" PASS
fi
GL_THREADS_DUP_CONFLICT='[[{"id":"d-conflict-a","notes":[{"id":707,"resolvable":true,"resolved":false,"body":"first","position":{"new_path":"a.rb","new_line":7}}]},{"id":"d-conflict-b","notes":[{"id":707,"resolvable":true,"resolved":false,"body":"changed","position":{"new_path":"b.rb","new_line":8}}]}]]'
if printf '%s' "$GL_THREADS_DUP_CONFLICT" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13d conflicting duplicate GitLab note fails closed" FAIL
else
  check "N13d conflicting duplicate GitLab note fails closed" PASS
fi
GL_DISCUSSION_STATE_CONFLICT='[[{"id":"d-state","resolvable":true,"resolved":false,"notes":[{"id":808,"body":"same","position":{"new_path":"a.rb","new_line":8}}]},{"id":"d-state","resolvable":true,"resolved":true,"notes":[{"id":808,"body":"same","position":{"new_path":"a.rb","new_line":8}}]}]]'
if printf '%s' "$GL_DISCUSSION_STATE_CONFLICT" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13e conflicting duplicate GitLab discussion state fails closed" FAIL
else
  check "N13e conflicting duplicate GitLab discussion state fails closed" PASS
fi
if printf '%s' '{"html_url":{}}' | _zensu_vcs_json_field html_url >/dev/null 2>&1 \
  || printf '%s' '{"html_url":[]}' | _zensu_vcs_json_field html_url >/dev/null 2>&1; then
  check "N13f JSON field extraction rejects composite values" FAIL
else
  check "N13f JSON field extraction rejects composite values" PASS
fi
GH_THREADS_ERRORS='[{"errors":[{"message":"partial data"}],"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
if printf '%s' "$GH_THREADS_ERRORS" | _zensu_vcs_normalize_threads github >/dev/null 2>&1; then
  check "N13g GitHub GraphQL errors fail closed despite partial data" FAIL
else
  check "N13g GitHub GraphQL errors fail closed despite partial data" PASS
fi
GH_THREAD_NO_ROOT='[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_EMPTY","isResolved":false,"comments":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
if printf '%s' "$GH_THREAD_NO_ROOT" | _zensu_vcs_normalize_threads github >/dev/null 2>&1; then
  check "N13h unresolved GitHub thread without a valid root comment fails closed" FAIL
else
  check "N13h unresolved GitHub thread without a valid root comment fails closed" PASS
fi
GL_LATE_BAD_NOTE='[[{"id":"d-late","notes":[{"id":901,"resolvable":true,"resolved":false,"body":"valid","position":{"new_path":"a.rb","new_line":9}},{"id":902,"resolvable":true,"resolved":false,"body":{"bad":true},"position":{"new_path":"b.rb","new_line":10}}]}]]'
if printf '%s' "$GL_LATE_BAD_NOTE" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13i later malformed GitLab note cannot hide behind the chosen root" FAIL
else
  check "N13i later malformed GitLab note cannot hide behind the chosen root" PASS
fi
if printf '%s' '{"number":42,"url":{},"state":"OPEN","headRefName":[],"baseRefName":"main"}' | _zensu_vcs_normalize_pr github >/dev/null 2>&1; then
  check "N13j PR normalization rejects composite URL and branch values" FAIL
else
  check "N13j PR normalization rejects composite URL and branch values" PASS
fi
GL_STRING_STATE='[[{"id":"d-string","notes":[{"id":910,"resolvable":"true","resolved":"false","body":"hidden"}]}]]'
if printf '%s' "$GL_STRING_STATE" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13k GitLab resolution flags must be booleans" FAIL
else
  check "N13k GitLab resolution flags must be booleans" PASS
fi
GL_MISSING_STATE='[[{"id":"d-missing","notes":[{"id":911,"body":"hidden"}]}]]'
if printf '%s' "$GL_MISSING_STATE" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13l GitLab findings cannot hide behind absent resolution state" FAIL
else
  check "N13l GitLab findings cannot hide behind absent resolution state" PASS
fi
GL_CROSS_DISCUSSION_NOTE='[[{"id":"d-one","notes":[{"id":912,"resolvable":true,"resolved":false,"body":"same"}]},{"id":"d-two","notes":[{"id":912,"resolvable":true,"resolved":false,"body":"same"}]}]]'
if printf '%s' "$GL_CROSS_DISCUSSION_NOTE" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13m one GitLab note ID cannot belong to two discussions" FAIL
else
  check "N13m one GitLab note ID cannot belong to two discussions" PASS
fi

( export ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1; _zensu_vcs_dry ) && check "N14a dry: both set -> dry" PASS || check "N14a dry: both set -> dry" FAIL
( export ZENSU_VCS_PRINT_ARGV=1; _zensu_vcs_dry ) && check "N14b dry: TEST unset -> NOT dry" FAIL || check "N14b dry: TEST unset -> NOT dry" PASS
( export ZENSU_VCS_TEST=1; _zensu_vcs_dry ) && check "N14c dry: PRINT unset -> NOT dry" FAIL || check "N14c dry: PRINT unset -> NOT dry" PASS

# A producer that emits valid JSON and then exits non-zero must never be
# laundered into success by a downstream normalizer.
PIPE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vcs-pipeline.XXXXXXXX")"
cat > "$PIPE_WORK/gh" <<'FAKE'
#!/bin/bash
printf '%s' '{"state":"OPEN","number":42,"url":"https://github.test/acme/widget/pull/42","headRefName":"feat","baseRefName":"main","headRefOid":"abcdef0","title":"T","body":"B","author":{"login":"a"},"labels":[]}'
exit 23
FAKE
chmod +x "$PIPE_WORK/gh"
producer_failure() {
  local label="$1"; shift
  if PATH="$PIPE_WORK:$PATH" "$@" >/dev/null 2>&1; then check "$label" FAIL; else check "$label" PASS; fi
}
producer_failure "N15 pr-state preserves CLI failure after valid JSON" _zensu_vcs_pr_state --provider github 42
producer_failure "N16 locate-pr preserves CLI failure after valid JSON" _zensu_vcs_locate_pr --provider github 42
producer_failure "N17 scout-pr preserves CLI failure after valid JSON" _zensu_vcs_scout_pr --provider github 42
producer_failure "N18 diff-refs preserves CLI failure after valid JSON" _zensu_vcs_diff_refs --provider github 42
rm -rf "$PIPE_WORK"

echo "----"
echo "test-vcs-pr-ops: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
