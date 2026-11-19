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

export ZENSU_VCS_REMOTE=https://github.com/acme/widget.git
argv() { env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1 bash "$LIB" "$@" 2>/dev/null; }

# ---- argv builders (hermetic; no gh/glab execution) ----
eq  "A1 pr-state github"        "$(argv --pr-state --provider github 42)"  "env GH_HOST=github.com GH_REPO= gh pr view --json state -- 42"
eq  "A2 pr-state gitlab"        "$(argv --pr-state --provider gitlab 42)"  "glab mr view --output json -- 42"
eq  "A3 locate-pr github num"   "$(argv --locate-pr --provider github 42)" "env GH_HOST=github.com GH_REPO= gh pr view --json number,url,state,headRefName,baseRefName -- 42"
eq  "A4 locate-pr github branch" "$(argv --locate-pr --provider github)"   "env GH_HOST=github.com GH_REPO= gh pr view --json number,url,state,headRefName,baseRefName"
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
has "A6i fetch github pins the remote's host after the fields" "$GHF" " -F num=42 --hostname github.com"
eq  "A7 fetch gitlab -> paginated JSON discussions" "$(argv --fetch-threads --provider gitlab --repo-id grp%2Fproj 7)" "glab api --paginate --output json projects/grp%2Fproj/merge_requests/7/discussions"

GHR="$(argv --resolve-thread --provider github --repo-id acme/widget --reply 'fixed in abc' 42 RT_1 111)"
has "A8a resolve github mutation"        "$GHR" "resolveReviewThread"
has "A8b resolve github thread var"      "$GHR" "t=RT_1"
has "A8c resolve github reply endpoint"  "$GHR" "pulls/42/comments/111/replies"
nothas "A8d resolve github not glab"     "$GHR" "glab"
eq "A8e resolve github pins the remote's host on the reply and on the mutation" \
  "$(printf '%s\n' "$GHR" | grep -c -- ' --hostname github.com$')" "2"

GLR="$(argv --resolve-thread --provider gitlab --repo-id grp%2Fproj 7 d1)"
has "A9a resolve gitlab PUT resolved"    "$GLR" "--method PUT"
has "A9b resolve gitlab discussion path" "$GLR" "discussions/d1?resolved=true"
nothas "A9c resolve gitlab no reply note (no --reply)" "$GLR" "/notes"
nothas "A9d resolve gitlab not gh"       "$GLR" "gh api"

GLR2="$(argv --resolve-thread --provider gitlab --repo-id grp%2Fproj --reply 'ok' 7 d1)"
has "A9e resolve gitlab WITH reply -> notes POST" "$GLR2" "discussions/d1/notes"
has "A9f resolve gitlab reply body travels as one JSON request" "$GLR2" '{"body":"ok"}'
has "A9g resolve gitlab reply declares a JSON Content-Type before its stdin body" "$GLR2" "discussions/d1/notes --header Content-Type: application/json --input -"
nothas "A9h resolve gitlab reply passes no -f field" "$GLR2" " -f "
eq "A9i resolve gitlab posts the reply before it resolves the thread" \
  "$(printf '%s\n' "$GLR2" | awk '/discussions\/d1\/notes/{n=NR} /resolved=true/{p=NR} END{if (n && p && n < p) print "ordered"; else print "unordered"}')" "ordered"

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
eq     "O1 open-pr github argv"              "$GHOP" "env GH_HOST=github.com GH_REPO= gh pr create --title My PR --body-file $OPBF --base main --head feat"
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

refused() { local l="$1"; shift; local o rc; o="$(argv "$@" 2>/dev/null)"; rc=$?; { [ -z "$o" ] && [ "$rc" -eq 1 ]; } && check "$l" PASS || check "$l (out='$o' rc=$rc)" FAIL; }
eq "D1 pr-diff github reads the diff in the repository context, on the remote's host" \
  "$(argv --pr-diff --provider github 42)" "env GH_HOST=github.com GH_REPO= gh pr diff --color never -- 42"
eq "D2 pr-diff github pins the repository given as --repo-id, on the remote's host" \
  "$(argv --pr-diff --provider github --repo-id acme/widget 42)" "gh pr diff -R github.com/acme/widget --color never -- 42"
eq "D3 pr-diff gitlab reads every page of the merge request's diffs" \
  "$(argv --pr-diff --provider gitlab --repo-id grp%2Fproj 7)" "glab api --paginate --output json projects/grp%2Fproj/merge_requests/7/diffs"
refused "D4 pr-diff requires --provider"                      --pr-diff 42
refused "D4b pr-diff unknown provider"                        --pr-diff --provider bogus 42
refused "D4c pr-diff rejects a non-numeric id"                --pr-diff --provider github 'x?y'
refused "D4d pr-diff requires an id"                          --pr-diff --provider github
refused "D4e pr-diff github refuses an invalid repo-id"       --pr-diff --provider github --repo-id 'acme/widget;id' 42
refused "D4f pr-diff gitlab requires a valid repo-id"         --pr-diff --provider gitlab 7
refused "D4g pr-diff refuses an unknown flag"                 --pr-diff --provider github --patch 42
refused "D4h pr-diff refuses a second id"                     --pr-diff --provider github 42 43
refused "D4i pr-diff refuses a repeated flag"                 --pr-diff --provider github --provider gitlab 42

EBF="$(mktemp)"; printf 'PR body content\n' > "$EBF"
EBE="$(mktemp)"; : > "$EBE"
eq "E1 edit-pr-body github edits the body in the repository context, on the remote's host" \
  "$(argv --edit-pr-body --provider github --body-file "$EBF" 42)" "env GH_HOST=github.com GH_REPO= gh pr edit --body-file $EBF -- 42"
eq "E2 edit-pr-body github pins the repository given as --repo-id, on the remote's host" \
  "$(argv --edit-pr-body --provider github --repo-id acme/widget --body-file "$EBF" 42)" "gh pr edit -R github.com/acme/widget --body-file $EBF -- 42"
GLEB="$(argv --edit-pr-body --provider gitlab --repo-id grp%2Fproj --body-file "$EBF" 7)"
eq "E3 edit-pr-body gitlab sends one JSON PUT with a JSON Content-Type" \
  "$(printf '%s\n' "$GLEB" | sed -n 1p)" "glab api --method PUT projects/grp%2Fproj/merge_requests/7 --header Content-Type: application/json --input -"
eq "E3b edit-pr-body gitlab carries the body file as the description" \
  "$(printf '%s\n' "$GLEB" | sed -n 2p)" '{"description":"PR body content\n"}'
eq "E3c edit-pr-body gitlab prints nothing else" "$(printf '%s\n' "$GLEB" | grep -c .)" "2"
refused "E4 edit-pr-body requires --body-file"                --edit-pr-body --provider github 42
refused "E4b edit-pr-body requires --provider"                --edit-pr-body --body-file "$EBF" 42
refused "E4c edit-pr-body rejects a non-numeric id"           --edit-pr-body --provider github --body-file "$EBF" 'x?y'
refused "E4d edit-pr-body gitlab requires a valid repo-id"    --edit-pr-body --provider gitlab --body-file "$EBF" 7
refused "E4e edit-pr-body github refuses an invalid repo-id"  --edit-pr-body --provider github --repo-id noslash --body-file "$EBF" 42
refused "E4f edit-pr-body refuses an unknown flag"            --edit-pr-body --provider github --title T --body-file "$EBF" 42
refused "E4g edit-pr-body gitlab refuses an empty body file"  --edit-pr-body --provider gitlab --repo-id grp%2Fproj --body-file "$EBE" 7
refused "E4h edit-pr-body unknown provider"                   --edit-pr-body --provider bogus --body-file "$EBF" 42
rm -f "$EBF" "$EBE"

eq    "R1 review-summary github argv" "$(argv --review-summary --provider github 42)" "env GH_HOST=github.com GH_REPO= gh pr view --json reviewDecision,latestReviews -- 42"
eq    "R1b review-summary github pins the repository given as --repo-id, on the remote's host" "$(argv --review-summary --provider github --repo-id acme/widgets 42)" "gh pr view -R github.com/acme/widgets --json reviewDecision,latestReviews -- 42"
eq    "R2 review-summary gitlab argv reads the approvals, then the MR" "$(argv --review-summary --provider gitlab --repo-id grp%2Fproj 7)" "glab api projects/grp%2Fproj/merge_requests/7/approvals
glab api projects/grp%2Fproj/merge_requests/7"
fails "R3 review-summary requires --provider"         --review-summary 42
fails "R4 review-summary gitlab requires a valid repo-id" --review-summary --provider gitlab 7
fails "R4b review-summary github refuses an invalid repo-id" --review-summary --provider github --repo-id 'acme/widgets;id' 42
fails "R5 review-summary rejects a non-numeric id"    --review-summary --provider github 'x?y'
fails "R5b review-summary unknown provider"           --review-summary --provider bogus 42

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
GL_PLAIN_AND_SYSTEM='[[{"id":"d-diff","individual_note":false,"notes":[{"id":1001,"type":"DiffNote","body":"fix the added line","system":false,"resolvable":true,"resolved":false,"author":{"username":"root"},"position":{"position_type":"text","old_path":"src/a.js","new_path":"src/a.js","old_line":null,"new_line":10}}]},{"id":"d-done","individual_note":false,"notes":[{"id":1002,"type":"DiscussionNote","body":"already fixed","system":false,"resolvable":true,"resolved":true,"author":{"username":"root"}}]},{"id":"d-summary","individual_note":true,"notes":[{"id":1003,"type":null,"body":"review summary","system":false,"resolvable":false,"author":{"username":"root"}}]},{"id":"d-approval","individual_note":true,"notes":[{"id":1004,"type":null,"body":"approved this merge request","system":true,"resolvable":false,"author":{"username":"root"}}]}]]'
N2E="$(printf '%s' "$GL_PLAIN_AND_SYSTEM" | _zensu_vcs_normalize_threads gitlab 2>/dev/null)"; N2E_RC=$?
eq     "N2e gitlab plain comments and system notes without a resolved flag leave the unresolved thread listed" "$N2E_RC $N2E" \
  '0 [{"threadId":"d-diff","replyTo":"d-diff","path":"src/a.js","line":10,"body":"fix the added line","author":"root"}]'
GL_THREAD_WITH_SYSTEM='[[{"id":"d-diff","individual_note":false,"notes":[{"id":1101,"type":"DiffNote","body":"fix the added line","system":false,"resolvable":true,"resolved":false,"author":{"username":"root"},"position":{"position_type":"text","old_path":"src/a.js","new_path":"src/a.js","old_line":null,"new_line":10}},{"id":1102,"type":"DiffNote","body":"changed this line in version 2 of the diff","system":true,"resolvable":false,"author":{"username":"root"},"position":{"position_type":"text","old_path":"src/a.js","new_path":"src/a.js","old_line":null,"new_line":10}}]}]]'
N2F="$(printf '%s' "$GL_THREAD_WITH_SYSTEM" | _zensu_vcs_normalize_threads gitlab 2>/dev/null)"; N2F_RC=$?
eq     "N2f a non-resolvable system note inside a resolvable thread leaves the root thread listed" "$N2F_RC $N2F" \
  '0 [{"threadId":"d-diff","replyTo":"d-diff","path":"src/a.js","line":10,"body":"fix the added line","author":"root"}]'

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
GL_RESOLVABLE_NO_FLAG='[[{"id":"d-open","notes":[{"id":913,"resolvable":true,"body":"hidden"}]}]]'
if printf '%s' "$GL_RESOLVABLE_NO_FLAG" | _zensu_vcs_normalize_threads gitlab >/dev/null 2>&1; then
  check "N13n a resolvable GitLab note without a resolved flag fails closed" FAIL
else
  check "N13n a resolvable GitLab note without a resolved flag fails closed" PASS
fi

rs() { { printf '%s' "$2"; printf '\0'; printf '%s' "${3:-}"; } | _zensu_vcs_normalize_review_summary "$1"; }
eq "R6 github approved decision" "$(rs github '{"reviewDecision":"APPROVED","latestReviews":[{"state":"COMMENTED"},{"state":"APPROVED"}]}')" '{"reviewed":true,"approved":true,"changesRequested":false}'
eq "R7 github changes requested" "$(rs github '{"reviewDecision":"CHANGES_REQUESTED","latestReviews":[{"state":"CHANGES_REQUESTED"}]}')" '{"reviewed":true,"approved":false,"changesRequested":true}'
eq "R8 github review required and no review yet" "$(rs github '{"reviewDecision":"REVIEW_REQUIRED","latestReviews":[]}')" '{"reviewed":false,"approved":false,"changesRequested":false}'
eq "R9 github without branch protection counts an approval" "$(rs github '{"reviewDecision":"","latestReviews":[{"state":"APPROVED"}]}')" '{"reviewed":true,"approved":true,"changesRequested":false}'
eq "R10 github approval that does not satisfy the rules is reviewed, not approved" "$(rs github '{"reviewDecision":"REVIEW_REQUIRED","latestReviews":[{"state":"COMMENTED"},{"state":"APPROVED"}]}')" '{"reviewed":true,"approved":false,"changesRequested":false}'
eq "R11 github dismissed or pending reviews are no review" "$(rs github '{"reviewDecision":null,"latestReviews":[{"state":"DISMISSED"},{"state":"PENDING"}]}')" '{"reviewed":false,"approved":false,"changesRequested":false}'
eq "R12 github open change request without protection" "$(rs github '{"reviewDecision":"","latestReviews":[{"state":"APPROVED"},{"state":"CHANGES_REQUESTED"}]}')" '{"reviewed":true,"approved":false,"changesRequested":true}'
eq "R13 gitlab approved by one reviewer" "$(rs gitlab '{"approved":true,"approved_by":[{"user":{"username":"a"}}]}' '{"detailed_merge_status":"mergeable"}')" '{"reviewed":true,"approved":true,"changesRequested":false}'
eq "R14 gitlab rules satisfied by nobody is not an approval" "$(rs gitlab '{"approved":true,"approved_by":[]}' '{"detailed_merge_status":"mergeable"}')" '{"reviewed":false,"approved":false,"changesRequested":false}'
eq "R15 gitlab requested changes" "$(rs gitlab '{"approved":false,"approved_by":[]}' '{"detailed_merge_status":"requested_changes"}')" '{"reviewed":true,"approved":false,"changesRequested":true}'
eq "R16 gitlab approval short of the rules" "$(rs gitlab '{"approved":false,"approved_by":[{"user":{"username":"a"}}]}' '{}')" '{"reviewed":true,"approved":false,"changesRequested":false}'
R_BAD=""
rs github 'not json' >/dev/null 2>&1 && R_BAD="$R_BAD github-malformed"
rs github '{"reviewDecision":"APPROVED","latestReviews":{}}' >/dev/null 2>&1 && R_BAD="$R_BAD github-reviews-shape"
rs github '{"reviewDecision":"APPROVED","latestReviews":[{"state":1}]}' >/dev/null 2>&1 && R_BAD="$R_BAD github-state-type"
rs gitlab '{"approved":"yes","approved_by":[]}' '{}' >/dev/null 2>&1 && R_BAD="$R_BAD gitlab-approved-type"
rs gitlab '{"approved":true,"approved_by":[]}' '' >/dev/null 2>&1 && R_BAD="$R_BAD gitlab-missing-mr"
rs gitlab '{"approved":true,"approved_by":[]}' '{"detailed_merge_status":3}' >/dev/null 2>&1 && R_BAD="$R_BAD gitlab-status-type"
rs bogus '{}' >/dev/null 2>&1 && R_BAD="$R_BAD unknown-provider"
[ -z "$R_BAD" ] && check "R17 review-summary normalizer fails closed on malformed input" PASS \
  || check "R17 review-summary normalizer accepted malformed input:$R_BAD" FAIL

( export ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1; _zensu_vcs_dry ) && check "N14a dry: both set -> dry" PASS || check "N14a dry: both set -> dry" FAIL
( export ZENSU_VCS_PRINT_ARGV=1; _zensu_vcs_dry ) && check "N14b dry: TEST unset -> NOT dry" FAIL || check "N14b dry: TEST unset -> NOT dry" PASS
( export ZENSU_VCS_TEST=1; _zensu_vcs_dry ) && check "N14c dry: PRINT unset -> NOT dry" FAIL || check "N14c dry: PRINT unset -> NOT dry" PASS

# A producer that emits valid JSON and then exits non-zero must never be
# laundered into success by a downstream normalizer.
. "$PLUGIN_DIR/tests/structure/lib-gh-host-fake.sh"
PIPE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vcs-pipeline.XXXXXXXX")"
gh_host_fake_write "$PIPE_WORK/gh" <<'FAKE'
printf '%s' '{"state":"OPEN","number":42,"url":"https://github.test/acme/widget/pull/42","headRefName":"feat","baseRefName":"main","headRefOid":"abcdef0","title":"T","body":"B","author":{"login":"a"},"labels":[]}'
exit 23
FAKE
producer_failure() {
  local label="$1"; shift
  if PATH="$PIPE_WORK:$PATH" "$@" >/dev/null 2>&1; then check "$label" FAIL; else check "$label" PASS; fi
}
producer_failure "N15 pr-state preserves CLI failure after valid JSON" _zensu_vcs_pr_state --provider github 42
producer_failure "N16 locate-pr preserves CLI failure after valid JSON" _zensu_vcs_locate_pr --provider github 42
producer_failure "N17 scout-pr preserves CLI failure after valid JSON" _zensu_vcs_scout_pr --provider github 42
producer_failure "N18 diff-refs preserves CLI failure after valid JSON" _zensu_vcs_diff_refs --provider github 42
producer_failure "N19 review-summary preserves CLI failure after valid JSON" _zensu_vcs_review_summary --provider github 42
rm -rf "$PIPE_WORK"

NOPR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vcs-nopr.XXXXXXXX")"
gh_host_fake_write "$NOPR_WORK/gh" <<'FAKE'
printf 'no pull requests found for branch "feat"\n' >&2
exit 1
FAKE
cat > "$NOPR_WORK/glab" <<'FAKE'
#!/bin/bash
printf 'no open merge request available for "feat"\n' >&2
exit 1
FAKE
chmod +x "$NOPR_WORK/glab"
locate_rc() { PATH="$NOPR_WORK:$PATH" bash "$LIB" --locate-pr "$@" >/dev/null 2>&1; printf '%s' "$?"; }
eq "L1 github: no PR for the current branch exits 3"  "$(locate_rc --provider github)" "3"
eq "L2 gitlab: no MR for the current branch exits 3"  "$(locate_rc --provider gitlab)" "3"
mkdir -p "$NOPR_WORK/caps"
gh_host_fake_write "$NOPR_WORK/caps/gh" <<'FAKE'
printf 'No pull requests found for branch "feat"\n' >&2
exit 1
FAKE
cat > "$NOPR_WORK/caps/glab" <<'FAKE'
#!/bin/bash
printf 'No open merge request available for "feat"\n' >&2
exit 1
FAKE
chmod +x "$NOPR_WORK/caps/glab"
caps_locate_rc() { PATH="$NOPR_WORK/caps:$PATH" bash "$LIB" --locate-pr "$@" >/dev/null 2>&1; printf '%s' "$?"; }
eq "L2b gitlab: the capitalized no-MR message of glab 1.113 and 1.122 exits 3" "$(caps_locate_rc --provider gitlab)" "3"
eq "L1b github: a capitalized no-PR message exits 3" "$(caps_locate_rc --provider github)" "3"
notmp_locate_rc() { TMPDIR="$NOPR_WORK/no-such-dir" PATH="$NOPR_WORK/caps:$PATH" bash "$LIB" --locate-pr "$@" >/dev/null 2>&1; printf '%s' "$?"; }
eq "L2c gitlab: the no-MR message still exits 3 when no temporary file can be created" "$(notmp_locate_rc --provider gitlab)" "3"
notmp_locate_err() { TMPDIR="$NOPR_WORK/no-such-dir" PATH="$NOPR_WORK/caps:$PATH" bash "$LIB" --locate-pr "$@" 2>&1 >/dev/null; }
has "L2d gitlab: a numbered lookup without a temporary file reports the forge CLI's message" "$(notmp_locate_err --provider gitlab 42)" "No open merge request available for"
eq "L3 a not-found for an explicit number stays exit 1" "$(locate_rc --provider github 42)" "1"
eq "L4 the other forge's not-found wording is an error" "$(cp "$NOPR_WORK/glab" "$NOPR_WORK/gh"; locate_rc --provider github)" "1"
gh_host_fake_write "$NOPR_WORK/gh" <<'FAKE'
printf 'HTTP 401: Bad credentials (https://api.github.com/graphql)\n' >&2
exit 1
FAKE
eq  "L5 any other failure stays exit 1" "$(locate_rc --provider github)" "1"
has "L6 the error names the forge CLI's message on stderr" "$(PATH="$NOPR_WORK:$PATH" bash "$LIB" --locate-pr --provider github 2>&1 >/dev/null)" "locate-pr failed (rc=1): HTTP 401: Bad credentials"
rm -rf "$NOPR_WORK"

HP="$(mktemp -d "${TMPDIR:-/tmp}/vcs-host-pin.XXXXXXXX")"
mkdir -p "$HP/bin"
printf 'PR body\n' > "$HP/body.md"
gh_host_fake_write "$HP/bin/gh" <<'FAKE'
set -u
case "${1:-} ${2:-}" in
  "pr view")
    case "$*" in
      *reviewDecision*) printf '%s' '{"reviewDecision":"APPROVED","latestReviews":[{"state":"APPROVED"}]}' ;;
      *"--json state "*) printf '%s' '{"state":"OPEN"}' ;;
      *) printf '%s' '{"number":42,"url":"https://github.test/acme/widget/pull/42","state":"OPEN","headRefName":"feat","baseRefName":"main"}' ;;
    esac
    exit 0 ;;
  "pr create") printf 'https://github.test/acme/widget/pull/43\n'; exit 0 ;;
  "pr diff")
    if [ -n "${FAKE_GH_DIFF_FAIL:-}" ]; then
      printf 'diff --git a/a.js b/a.js\n'
      printf 'HTTP 406: the diff exceeded the maximum number of lines\n' >&2
      exit 1
    fi
    printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-old\n+new\n'
    exit 0 ;;
  "pr edit")
    body_file="" previous=""
    for arg in "$@"; do
      [ "$previous" = --body-file ] && body_file="$arg"
      previous="$arg"
    done
    [ -n "$body_file" ] && [ -s "$body_file" ] || exit 3
    [ -z "${FAKE_GH_BODY_LOG:-}" ] || cat -- "$body_file" > "$FAKE_GH_BODY_LOG"
    printf 'https://github.test/acme/widget/pull/42\n'
    exit 0 ;;
  "api graphql")
    case "$*" in
      *resolveReviewThread*) printf '%s' '{"data":{"resolveReviewThread":{"thread":{"id":"RT_1"}}}}' ;;
      *) printf '%s' '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"RT_1","isResolved":false,"comments":{"nodes":[{"databaseId":111,"body":"fix this","path":"a.js","line":10,"author":{"login":"alice"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]' ;;
    esac
    exit 0 ;;
  "api repos/acme/widget/pulls/42/comments/111/replies") printf '%s' '{"id":5}'; exit 0 ;;
esac
exit 2
FAKE
hp_run() {
  : > "$HP/hosts"; : > "$HP/env"
  HP_OUT="$(env PATH="$HP/bin:$PATH" GH_HOST=example.invalid FAKE_GH_HOSTS_LOG="$HP/hosts" FAKE_GH_ENV_LOG="$HP/env" \
    ZENSU_VCS_REMOTE=https://github.com/acme/widget.git "$@" 2>"$HP/err")"
  HP_RC=$?
  HP_ERR="$(cat "$HP/err")"; HP_HOSTS="$(cat "$HP/hosts")"; HP_ENV="$(cat "$HP/env")"
}
hp_reached() {
  local label="$1" want="$2" host="$3" calls="$4" count stray
  count="$(printf '%s\n' "$HP_HOSTS" | grep -c .)"
  stray="$(printf '%s\n' "$HP_HOSTS" | grep -v "^$host " | grep -c .)"
  if [ "$HP_RC" -eq 0 ] && [ "$HP_OUT" = "$want" ] && [ "$count" = "$calls" ] && [ "$stray" = 0 ]; then check "$label" PASS
  else check "$label (rc=$HP_RC out='$HP_OUT' hosts='$HP_HOSTS' err='$HP_ERR')" FAIL; fi
}
PR_JSON='{"id":"42","url":"https://github.test/acme/widget/pull/42","state":"OPEN","base":"main","head":"feat"}'
THREADS_JSON='[{"threadId":"RT_1","replyTo":"111","path":"a.js","line":10,"body":"fix this","author":"alice"}]'
SUMMARY_JSON='{"reviewed":true,"approved":true,"changesRequested":false}'
hp_run bash "$LIB" --pr-state --provider github 42
hp_reached "HP1 --pr-state reaches the remote's github.com while GH_HOST names another host" OPEN github.com 1
hp_run bash "$LIB" --locate-pr --provider github
hp_reached "HP2 --locate-pr of the current branch reaches github.com while GH_HOST names another host" "$PR_JSON" github.com 1
hp_run bash "$LIB" --review-summary --provider github --repo-id acme/widget 42
hp_reached "HP3 --review-summary with --repo-id reaches github.com while GH_HOST names another host" "$SUMMARY_JSON" github.com 1
hp_run bash "$LIB" --review-summary --provider github 42
hp_reached "HP4 --review-summary without --repo-id reaches github.com while GH_HOST names another host" "$SUMMARY_JSON" github.com 1
hp_run bash "$LIB" --fetch-threads --provider github --repo-id acme/widget 42
hp_reached "HP5 --fetch-threads reaches github.com while GH_HOST names another host" "$THREADS_JSON" github.com 1
hp_run bash "$LIB" --resolve-thread --provider github --repo-id acme/widget --reply 'fixed in abc' 42 RT_1 111
hp_reached "HP6 --resolve-thread sends the reply and the resolve to github.com while GH_HOST names another host" "" github.com 2
hp_run bash "$LIB" --open-pr --provider github --base main --head feat --title T --body-file "$HP/body.md"
hp_reached "HP7 --open-pr reaches github.com while GH_HOST names another host" https://github.test/acme/widget/pull/43 github.com 1
hp_run ZENSU_VCS_REMOTE=https://ghe.example.com/acme/widget.git FAKE_GH_PR_HOST=ghe.example.com FAKE_GH_LOGINS=ghe.example.com \
  bash "$LIB" --fetch-threads --provider github --repo-id acme/widget 42
hp_reached "HP8 --fetch-threads reaches the GitHub Enterprise host of the remote while GH_HOST names another host" "$THREADS_JSON" ghe.example.com 1
hp_run ZENSU_VCS_REMOTE=https://ghe.example.com/acme/widget.git FAKE_GH_PR_HOST=ghe.example.com FAKE_GH_LOGINS=ghe.example.com \
  bash "$LIB" --resolve-thread --provider github --repo-id acme/widget --reply 'fixed in abc' 42 RT_1 111
hp_reached "HP9 --resolve-thread writes to the GitHub Enterprise host of the remote while GH_HOST names another host" "" ghe.example.com 2
hp_run ZENSU_VCS_REMOTE=https://ghe.example.com/acme/widget.git FAKE_GH_PR_HOST=ghe.example.com \
  bash "$LIB" --fetch-threads --provider github --repo-id acme/widget 42
if [ "$HP_RC" -ne 0 ] && [ -z "$HP_OUT" ] && [ -z "$HP_HOSTS" ]; then
  case "$HP_ERR" in
    *GH_HOST*) check "HP10 a remote host gh knows no login for refuses before any gh api call and names only the login command (err='$HP_ERR')" FAIL ;;
    *"gh auth login --hostname ghe.example.com"*) check "HP10 a remote host gh knows no login for refuses before any gh api call and names only the login command" PASS ;;
    *) check "HP10 a remote host gh knows no login for refuses before any gh api call and names only the login command (err='$HP_ERR')" FAIL ;;
  esac
else
  check "HP10 a remote host gh knows no login for refuses before any gh api call and names only the login command (rc=$HP_RC out='$HP_OUT' hosts='$HP_HOSTS')" FAIL
fi
HP_GHE=(ZENSU_VCS_REMOTE=https://ghe.example.com/acme/widget.git FAKE_GH_PR_HOST=ghe.example.com FAKE_GH_LOGINS=ghe.example.com)
hp_run "${HP_GHE[@]}" bash "$LIB" --pr-state --provider github 42
hp_reached "HP11 --pr-state reaches the GitHub Enterprise host of the remote while GH_HOST names another host" OPEN ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --locate-pr --provider github
hp_reached "HP12 --locate-pr of the current branch reaches the GitHub Enterprise host of the remote" "$PR_JSON" ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --locate-pr --provider github 42
hp_reached "HP13 --locate-pr by number reaches the GitHub Enterprise host of the remote" "$PR_JSON" ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --review-summary --provider github --repo-id acme/widget 42
hp_reached "HP14 --review-summary with --repo-id reaches the GitHub Enterprise host of the remote" "$SUMMARY_JSON" ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --review-summary --provider github 42
hp_reached "HP15 --review-summary without --repo-id reaches the GitHub Enterprise host of the remote" "$SUMMARY_JSON" ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --open-pr --provider github --base main --head feat --title T --body-file "$HP/body.md"
hp_reached "HP16 --open-pr reaches the GitHub Enterprise host of the remote" https://github.test/acme/widget/pull/43 ghe.example.com 1
hp_tokens() {
  local label="$1" want="$2" lines bad
  lines="$(printf '%s\n' "$HP_ENV" | grep -c .)"
  bad="$(printf '%s\n' "$HP_ENV" | grep -v -x -F -e "$want" | grep -c .)"
  if [ "$HP_RC" -eq 0 ] && [ "$lines" -ge 1 ] && [ "$bad" = 0 ]; then check "$label" PASS
  else check "$label (rc=$HP_RC env='$HP_ENV' err='$HP_ERR')" FAIL; fi
}
HP_TOKENS=(GH_TOKEN=t1 GITHUB_TOKEN=t2 GH_ENTERPRISE_TOKEN=t3 GITHUB_ENTERPRISE_TOKEN=t4)
hp_run "${HP_GHE[@]}" "${HP_TOKENS[@]}" bash "$LIB" --resolve-thread --provider github --repo-id acme/widget --reply 'fixed in abc' 42 RT_1 111
hp_tokens "HP17 a host accepted for its stored gh login gets every write without the environment tokens" ghe.example.com
hp_run "${HP_GHE[@]}" "${HP_TOKENS[@]}" bash "$LIB" --pr-state --provider github 42
hp_tokens "HP17b a repo-context call to that host runs without the environment tokens too" ghe.example.com
hp_run "${HP_TOKENS[@]}" bash "$LIB" --fetch-threads --provider github --repo-id acme/widget 42
hp_tokens "HP18 a github.com call keeps the environment tokens" "github.com GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN"
hp_run ZENSU_VCS_REMOTE=https://ghe.example.com/acme/widget.git FAKE_GH_PR_HOST=ghe.example.com GH_HOST=ghe.example.com "${HP_TOKENS[@]}" \
  bash "$LIB" --fetch-threads --provider github --repo-id acme/widget 42
hp_tokens "HP19 the host GH_HOST names keeps the environment tokens" "ghe.example.com GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN"
hp_run GH_REPO=other.example/acme/x bash "$LIB" --pr-state --provider github 42
hp_reached "HP20 a GH_REPO in the environment does not move --pr-state off the host of the remote" OPEN github.com 1
hp_run "${HP_GHE[@]}" GH_REPO=other.example/acme/x bash "$LIB" --open-pr --provider github --base main --head feat --title T --body-file "$HP/body.md"
hp_reached "HP20b a GH_REPO in the environment does not move --open-pr off the GitHub Enterprise host of the remote" https://github.test/acme/widget/pull/43 ghe.example.com 1
HP_DIFF="$(printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-old\n+new\n')"
HP_PR_URL=https://github.test/acme/widget/pull/42
hp_run bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42
hp_reached "HP21 --pr-diff with --repo-id reaches the remote's github.com while GH_HOST names another host" "$HP_DIFF" github.com 1
hp_run bash "$LIB" --pr-diff --provider github 42
hp_reached "HP22 --pr-diff in the repository context reaches github.com while GH_HOST names another host" "$HP_DIFF" github.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42
hp_reached "HP23 --pr-diff with --repo-id reaches the GitHub Enterprise host of the remote" "$HP_DIFF" ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --pr-diff --provider github 42
hp_reached "HP23b --pr-diff in the repository context reaches the GitHub Enterprise host of the remote" "$HP_DIFF" ghe.example.com 1
hp_run bash "$LIB" --edit-pr-body --provider github --body-file "$HP/body.md" 42
hp_reached "HP24 --edit-pr-body reaches github.com while GH_HOST names another host and prints the pull request URL" "$HP_PR_URL" github.com 1
hp_run bash "$LIB" --edit-pr-body --provider github --repo-id acme/widget --body-file "$HP/body.md" 42
hp_reached "HP24b --edit-pr-body with --repo-id reaches github.com while GH_HOST names another host" "$HP_PR_URL" github.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --edit-pr-body --provider github --body-file "$HP/body.md" 42
hp_reached "HP25 --edit-pr-body reaches the GitHub Enterprise host of the remote" "$HP_PR_URL" ghe.example.com 1
hp_run "${HP_GHE[@]}" bash "$LIB" --edit-pr-body --provider github --repo-id acme/widget --body-file "$HP/body.md" 42
hp_reached "HP25b --edit-pr-body with --repo-id reaches the GitHub Enterprise host of the remote" "$HP_PR_URL" ghe.example.com 1
hp_run "${HP_GHE[@]}" "${HP_TOKENS[@]}" bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42
hp_tokens "HP26 --pr-diff to a host accepted for its stored gh login runs without the environment tokens" ghe.example.com
hp_run "${HP_GHE[@]}" "${HP_TOKENS[@]}" bash "$LIB" --pr-diff --provider github 42
hp_tokens "HP26b a repo-context --pr-diff to that host runs without the environment tokens" ghe.example.com
hp_run "${HP_GHE[@]}" "${HP_TOKENS[@]}" bash "$LIB" --edit-pr-body --provider github --body-file "$HP/body.md" 42
hp_tokens "HP26c --edit-pr-body to that host runs without the environment tokens" ghe.example.com
hp_run "${HP_GHE[@]}" "${HP_TOKENS[@]}" bash "$LIB" --edit-pr-body --provider github --repo-id acme/widget --body-file "$HP/body.md" 42
hp_tokens "HP26d --edit-pr-body with --repo-id to that host runs without the environment tokens" ghe.example.com
hp_run "${HP_TOKENS[@]}" bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42
hp_tokens "HP26e a --pr-diff to github.com keeps the environment tokens" "github.com GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN"
hp_run GH_REPO=other.example/acme/x bash "$LIB" --pr-diff --provider github 42
hp_reached "HP27 a GH_REPO in the environment does not move --pr-diff off the host of the remote" "$HP_DIFF" github.com 1
hp_run "${HP_GHE[@]}" GH_REPO=other.example/acme/x bash "$LIB" --edit-pr-body --provider github --body-file "$HP/body.md" 42
hp_reached "HP27b a GH_REPO in the environment does not move --edit-pr-body off the GitHub Enterprise host of the remote" "$HP_PR_URL" ghe.example.com 1
printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-old\n+new\n' > "$HP/want.diff"
env PATH="$HP/bin:$PATH" GH_HOST=example.invalid ZENSU_VCS_REMOTE=https://github.com/acme/widget.git \
  bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42 > "$HP/got.diff" 2>/dev/null
HP_BYTES_RC=$?
if [ "$HP_BYTES_RC" -eq 0 ] && cmp -s "$HP/want.diff" "$HP/got.diff"; then
  check "HP28 --pr-diff prints the diff gh served byte for byte, its final newline included" PASS
else
  check "HP28 --pr-diff prints the diff gh served byte for byte, its final newline included (rc=$HP_BYTES_RC)" FAIL
fi
hp_run FAKE_GH_DIFF_FAIL=1 bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42
if [ "$HP_RC" -ne 0 ] && [ -z "$HP_OUT" ]; then
  case "$HP_ERR" in
    *"pr-diff"*"HTTP 406: the diff exceeded the maximum number of lines"*) check "HP29 a failed gh pr diff prints none of its partial output and names gh's message" PASS ;;
    *) check "HP29 a failed gh pr diff prints none of its partial output and names gh's message (err='$HP_ERR')" FAIL ;;
  esac
else
  check "HP29 a failed gh pr diff prints none of its partial output and names gh's message (rc=$HP_RC out='$HP_OUT')" FAIL
fi
printf 'Body with `code`, $HOME, a quote '"'"' and an umlaut \303\244\n' > "$HP/rich.md"
hp_run FAKE_GH_BODY_LOG="$HP/sent.md" bash "$LIB" --edit-pr-body --provider github --body-file "$HP/rich.md" 42
if [ "$HP_RC" -eq 0 ] && cmp -s "$HP/rich.md" "$HP/sent.md"; then
  check "HP30 --edit-pr-body hands gh the body file it was given" PASS
else
  check "HP30 --edit-pr-body hands gh the body file it was given (rc=$HP_RC err='$HP_ERR')" FAIL
fi
: > "$HP/empty.md"
hp_run bash "$LIB" --edit-pr-body --provider github --body-file "$HP/empty.md" 42
if [ "$HP_RC" -eq 1 ] && [ -z "$HP_HOSTS" ]; then
  check "HP30b an empty body file is refused before any gh pr call" PASS
else
  check "HP30b an empty body file is refused before any gh pr call (rc=$HP_RC hosts='$HP_HOSTS')" FAIL
fi
hp_run bash "$LIB" --edit-pr-body --provider github --body-file "$HP/no-such-body.md" 42
if [ "$HP_RC" -eq 1 ] && [ -z "$HP_HOSTS" ]; then
  check "HP30c a missing body file is refused before any gh pr call" PASS
else
  check "HP30c a missing body file is refused before any gh pr call (rc=$HP_RC hosts='$HP_HOSTS')" FAIL
fi
rm -rf "$HP"

GD="$(mktemp -d "${TMPDIR:-/tmp}/vcs-gitlab-diff.XXXXXXXX")"
mkdir -p "$GD/bin"
cat > "$GD/bin/glab" <<'FAKE'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$GD_LOG"
case "$*" in
  "api --paginate --output json projects/grp%2Fproj/merge_requests/7/diffs")
    [ -z "${GD_FAIL:-}" ] || { printf 'glab: 404 Not Found\n' >&2; exit 1; }
    cat -- "$GD_DIFFS"
    exit 0 ;;
  "api --method PUT projects/grp%2Fproj/merge_requests/7 --header Content-Type: application/json --input -")
    cat > "$GD_STDIN"
    [ -z "${GD_FAIL:-}" ] || { printf 'glab: 403 Forbidden\n' >&2; exit 1; }
    if [ -n "${GD_NO_URL:-}" ]; then printf '%s' '{"iid":7}'; else printf '%s' '{"iid":7,"web_url":"https://gitlab.test/grp/proj/-/merge_requests/7"}'; fi
    exit 0 ;;
esac
printf 'unexpected glab call: %s\n' "$*" >&2
exit 2
FAKE
chmod +x "$GD/bin/glab"
gd_run() {
  : > "$GD/log"; : > "$GD/stdin"
  GD_OUT="$(env PATH="$GD/bin:$PATH" GD_LOG="$GD/log" GD_STDIN="$GD/stdin" "$@" 2>"$GD/err")"
  GD_RC=$?
  GD_ERR="$(cat "$GD/err")"
}
cat > "$GD/diffs.json" <<'JSON'
[[{"old_path":"src/a.js","new_path":"src/a.js","a_mode":"100644","b_mode":"100644","new_file":false,"renamed_file":false,"deleted_file":false,"diff":"@@ -1,2 +1,3 @@\n one\n+two\n three\n"},{"old_path":"src/new.js","new_path":"src/new.js","a_mode":"0","b_mode":"100644","new_file":true,"renamed_file":false,"deleted_file":false,"diff":"@@ -0,0 +1 @@\n+fresh\n"},{"old_path":"src/gone.js","new_path":"src/gone.js","a_mode":"100644","b_mode":"0","new_file":false,"renamed_file":false,"deleted_file":true,"diff":"@@ -1 +0,0 @@\n-bye\n"}],[{"old_path":"src/old.js","new_path":"src/renamed.js","a_mode":"100644","b_mode":"100644","new_file":false,"renamed_file":true,"deleted_file":false,"diff":"@@ -1 +1 @@\n-two\n+TWO"},{"old_path":"docs/x.md","new_path":"docs/y.md","a_mode":"100644","b_mode":"100644","new_file":false,"renamed_file":true,"deleted_file":false,"diff":""},{"old_path":"bin/run","new_path":"bin/run","a_mode":"100644","b_mode":"100755","new_file":false,"renamed_file":false,"deleted_file":false,"collapsed":false,"too_large":false,"diff":""}]]
JSON
cat > "$GD/want.diff" <<'DIFF'
diff --git a/src/a.js b/src/a.js
--- a/src/a.js
+++ b/src/a.js
@@ -1,2 +1,3 @@
 one
+two
 three
diff --git a/src/new.js b/src/new.js
new file mode 100644
--- /dev/null
+++ b/src/new.js
@@ -0,0 +1 @@
+fresh
diff --git a/src/gone.js b/src/gone.js
deleted file mode 100644
--- a/src/gone.js
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/src/old.js b/src/renamed.js
rename from src/old.js
rename to src/renamed.js
--- a/src/old.js
+++ b/src/renamed.js
@@ -1 +1 @@
-two
+TWO
diff --git a/docs/x.md b/docs/y.md
rename from docs/x.md
rename to docs/y.md
diff --git a/bin/run b/bin/run
old mode 100644
new mode 100755
DIFF
env PATH="$GD/bin:$PATH" GD_LOG="$GD/log" GD_DIFFS="$GD/diffs.json" \
  bash "$LIB" --pr-diff --provider gitlab --repo-id grp%2Fproj 7 > "$GD/got.diff" 2>"$GD/err"
GD_BYTES_RC=$?
if [ "$GD_BYTES_RC" -eq 0 ] && cmp -s "$GD/want.diff" "$GD/got.diff"; then
  check "GD1 gitlab --pr-diff rebuilds a unified diff from every page: headers, new, deleted, renamed and mode-changed files" PASS
else
  check "GD1 gitlab --pr-diff rebuilds a unified diff from every page (rc=$GD_BYTES_RC err='$(cat "$GD/err")' diff='$(diff "$GD/want.diff" "$GD/got.diff" 2>&1 | head -n 12)')" FAIL
fi
eq "GD1b gitlab --pr-diff reads the listing in one paginated call" "$(cat "$GD/log")" "api --paginate --output json projects/grp%2Fproj/merge_requests/7/diffs"
gd_refuses() {
  local label="$1" listing="$2" needle="${3:-}"
  printf '%s' "$listing" > "$GD/bad.json"
  gd_run GD_DIFFS="$GD/bad.json" bash "$LIB" --pr-diff --provider gitlab --repo-id grp%2Fproj 7
  if [ "$GD_RC" -eq 1 ] && [ -z "$GD_OUT" ]; then
    case "$GD_ERR" in
      *"$needle"*) check "$label" PASS ;;
      *) check "$label (err='$GD_ERR' missing '$needle')" FAIL ;;
    esac
  else
    check "$label (rc=$GD_RC out='$GD_OUT')" FAIL
  fi
}
gd_refuses "GD2 a listing that is not JSON fails closed and prints nothing" 'not json' "pr-diff failed: the diffs listing is not JSON"
gd_refuses "GD2b an entry without a new path fails closed" '[[{"old_path":"a.js","diff":"@@ -1 +1 @@\n-a\n+b\n"}]]' "names no valid path"
gd_refuses "GD2c an entry whose diff is not text fails closed" '[[{"old_path":"a.js","new_path":"a.js","diff":{"x":1}}]]' "diff that is not text"
gd_refuses "GD2d a path with a line break fails closed" '[[{"old_path":"a.js","new_path":"a.js\n+++ b/evil","diff":""}]]' "names no valid path"
gd_refuses "GD2e a flag that is not a boolean fails closed" '[[{"old_path":"a.js","new_path":"a.js","new_file":"yes","diff":""}]]' "flag that is not a boolean"
gd_refuses "GD3 a file GitLab marks too large fails the verb and names the file" '[[{"old_path":"big.lock","new_path":"big.lock","too_large":true,"diff":""}]]' "big.lock"
gd_refuses "GD3b a collapsed file sent without its diff fails the verb and names the file" '[[{"old_path":"huge.js","new_path":"huge.js","collapsed":true,"diff":""}]]' "huge.js"
gd_run GD_DIFFS="$GD/diffs.json" GD_FAIL=1 bash "$LIB" --pr-diff --provider gitlab --repo-id grp%2Fproj 7
if [ "$GD_RC" -ne 0 ] && [ -z "$GD_OUT" ]; then
  case "$GD_ERR" in
    *"pr-diff"*"404 Not Found"*) check "GD4 a failed glab read fails the verb with glab's message" PASS ;;
    *) check "GD4 a failed glab read fails the verb with glab's message (err='$GD_ERR')" FAIL ;;
  esac
else
  check "GD4 a failed glab read fails the verb with glab's message (rc=$GD_RC out='$GD_OUT')" FAIL
fi
printf 'Body with `code`, $HOME, a quote '"'"', a "double" one and an umlaut \303\244\n\n- item\n' > "$GD/body.md"
gd_run bash "$LIB" --edit-pr-body --provider gitlab --repo-id grp%2Fproj --body-file "$GD/body.md" 7
eq "GB1 gitlab --edit-pr-body prints the merge request URL" "$GD_RC $GD_OUT" "0 https://gitlab.test/grp/proj/-/merge_requests/7"
eq "GB1b gitlab --edit-pr-body sends one PUT with a JSON Content-Type" "$(cat "$GD/log")" \
  "api --method PUT projects/grp%2Fproj/merge_requests/7 --header Content-Type: application/json --input -"
GB_SENT="$(SENT="$GD/stdin" BODY="$GD/body.md" node -e '
  var fs=require("fs"),j;try{j=JSON.parse(fs.readFileSync(process.env.SENT,"utf8"));}catch(_){process.stdout.write("not json");process.exit(0);}
  var keys=Object.keys(j).join(",");
  process.stdout.write(keys+" "+(j.description===fs.readFileSync(process.env.BODY,"utf8")?"verbatim":"changed"));')"
eq "GB2 gitlab --edit-pr-body sends exactly the description, byte for byte" "$GB_SENT" "description verbatim"
gd_run GD_FAIL=1 bash "$LIB" --edit-pr-body --provider gitlab --repo-id grp%2Fproj --body-file "$GD/body.md" 7
if [ "$GD_RC" -ne 0 ] && [ -z "$GD_OUT" ]; then
  case "$GD_ERR" in
    *"edit-pr-body"*"403 Forbidden"*) check "GB3 a refused PUT fails the verb with glab's message" PASS ;;
    *) check "GB3 a refused PUT fails the verb with glab's message (err='$GD_ERR')" FAIL ;;
  esac
else
  check "GB3 a refused PUT fails the verb with glab's message (rc=$GD_RC out='$GD_OUT')" FAIL
fi
gd_run GD_NO_URL=1 bash "$LIB" --edit-pr-body --provider gitlab --repo-id grp%2Fproj --body-file "$GD/body.md" 7
if [ "$GD_RC" -eq 1 ] && [ -z "$GD_OUT" ]; then
  check "GB4 an answer without the merge request URL fails the verb" PASS
else
  check "GB4 an answer without the merge request URL fails the verb (rc=$GD_RC out='$GD_OUT')" FAIL
fi
rm -rf "$GD"

SK_PATTERN='(^|[^A-Za-z0-9_./-])gh (api|pr [a-z][a-z-]*)([^A-Za-z0-9_-]|$)'
SK_ALLOW='skills/autopilot/SKILL.md|   GitHub → `gh pr create`, GitLab → `glab mr create` with `--source-branch`/`--target-branch`,'
sk_unallowed() {
  awk -v allow="$SK_ALLOW" '{ p = index($0, ":"); f = substr($0, 1, p - 1); r = substr($0, p + 1); q = index(r, ":"); if (f "|" substr(r, q + 1) != allow) print }'
}
SK_ALL="$(cd "$PLUGIN_DIR" && grep -rnE --include='*.md' -e "$SK_PATTERN" \
  skills/pr-team-review skills/autopilot skills/cover skills/pr-fix-findings skills/pilot 2>&1)"
SK_HITS="$(printf '%s\n' "$SK_ALL" | grep . | sk_unallowed)"
eq "SK1 no PR-facing skill spells a gh api call or any gh pr subcommand; each runs a pinned driver verb" "$SK_HITS" ""
eq "SK1d the one exemption, the line naming what --open-pr runs, still matches exactly one line" \
  "$(printf '%s\n' "$SK_ALL" | grep . | grep -c 'gh pr create')" "1"
SK_PROBE="$(mktemp -d "${TMPDIR:-/tmp}/vcs-skill-probe.XXXXXXXX")"
printf 'Run `gh pr diff 7 --repo o/r` first.\n' > "$SK_PROBE/probe.md"
printf 'Then `gh pr list --state open` and `gh pr merge 7`.\n' > "$SK_PROBE/list.md"
SK_BITE="$(grep -rnE --include='*.md' -e "$SK_PATTERN" "$SK_PROBE" 2>&1 | sk_unallowed)"
rm -rf "$SK_PROBE"
has "SK1b the skill scan finds a planted gh pr diff call" "$SK_BITE" "gh pr diff 7"
has "SK1c the skill scan finds a planted gh pr list call, not only the six original subcommands" "$SK_BITE" "gh pr list"

PD_ERR="$(env ZENSU_VCS_TEST=1 bash "$LIB" --pr-diff --provider unknown 42 2>&1 >/dev/null)"; PD_RC=$?
if [ "$PD_RC" -eq 1 ]; then has "PD1 --pr-diff names its refusal of an unknown provider" "$PD_ERR" "pr-diff refused: --provider must be github or gitlab"
else check "PD1 --pr-diff names its refusal of an unknown provider (rc=$PD_RC)" FAIL; fi
PD_ERR="$(env ZENSU_VCS_TEST=1 bash "$LIB" --pr-diff --provider gitlab 7 2>&1 >/dev/null)"; PD_RC=$?
if [ "$PD_RC" -eq 1 ]; then has "PD2 gitlab --pr-diff names its refusal of a missing --repo-id" "$PD_ERR" "pr-diff refused: GitLab needs --repo-id"
else check "PD2 gitlab --pr-diff names its refusal of a missing --repo-id (rc=$PD_RC)" FAIL; fi

EB="$(mktemp -d "${TMPDIR:-/tmp}/vcs-edit-refusal.XXXXXXXX")"
mkdir -p "$EB/bin"
: > "$EB/empty.md"
gh_host_fake_write "$EB/bin/gh" <<'FAKE'
exit 2
FAKE
EB_ERR="$(env PATH="$EB/bin:$PATH" GH_HOST=example.invalid ZENSU_VCS_REMOTE=https://ghe.example.com/acme/widget.git \
  FAKE_GH_LOGINS=ghe.example.com FAKE_GH_CONFIG_LOG="$EB/config" FAKE_GH_HOSTS_LOG="$EB/hosts" \
  bash "$LIB" --edit-pr-body --provider github --body-file "$EB/empty.md" 42 2>&1 >/dev/null)"; EB_RC=$?
if [ "$EB_RC" -eq 1 ] && [ ! -s "$EB/config" ] && [ ! -s "$EB/hosts" ]; then
  has "EB1 an empty body file is refused with a reason before any gh call, the login lookup included" "$EB_ERR" "edit-pr-body refused: the body file is missing or empty"
else
  check "EB1 an empty body file is refused with a reason before any gh call, the login lookup included (rc=$EB_RC config='$(cat "$EB/config" 2>/dev/null)')" FAIL
fi
rm -rf "$EB"

eq "GB5 the driver spells the GitLab JSON-body argv once, in _zensu_vcs_gitlab_send_json" \
  "$(grep -c -- "--header 'Content-Type: application/json' --input -" "$LIB")" "1"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) echo "  SKIP  ST1 an interrupted stream removes its temporary files (POSIX signals only)" ;;
  *)
    ST="$(mktemp -d "${TMPDIR:-/tmp}/vcs-stream-trap.XXXXXXXX")"
    mkdir -p "$ST/bin" "$ST/tmp"
    gh_host_fake_write "$ST/bin/gh" <<'FAKE'
case "${1:-} ${2:-}" in
  "pr diff") printf 'diff --git a/a b/a\n'; : > "$FAKE_ST_FLAG"; kill -TERM "$PPID"; exit 0 ;;
esac
exit 2
FAKE
    env PATH="$ST/bin:$PATH" TMPDIR="$ST/tmp" GH_HOST=example.invalid ZENSU_VCS_REMOTE=https://github.com/acme/widget.git \
      FAKE_ST_FLAG="$ST/term-sent" bash "$LIB" --pr-diff --provider github --repo-id acme/widget 42 >"$ST/out" 2>/dev/null
    ST_RC=$?
    ST_LEFT="$(find "$ST/tmp" -name 'zensu-vcs-*' | grep -c .)"
    if [ "$ST_RC" -eq 143 ] && [ -f "$ST/term-sent" ] && [ "$ST_LEFT" = 0 ] && [ ! -s "$ST/out" ]; then
      check "ST1 a stream interrupted by TERM exits 143, removes both temporary files and prints nothing" PASS
    else
      check "ST1 a stream interrupted by TERM exits 143, removes both temporary files and prints nothing (rc=$ST_RC term-sent=$([ -f "$ST/term-sent" ] && echo yes || echo no) left=$ST_LEFT)" FAIL
    fi
    rm -rf "$ST" ;;
esac

EX_LIST="$(grep '^export -f' "$LIB" | tr ' ' '\n' | grep -E '^_zensu_vcs_[A-Za-z0-9_]+$' | tr '\n' ' ')"
EX_ABSENT=""
for EX_F in _zensu_vcs_stream _zensu_vcs_render_gitlab_diff _zensu_vcs_pr_diff _zensu_vcs_edit_pr_body \
            _zensu_vcs_post_comment _zensu_vcs_normalize_review _zensu_vcs_fetch_review _zensu_vcs_gitlab_send_json \
            _zensu_vcs_require_file; do
  case " $EX_LIST" in *" $EX_F "*) ;; *) EX_ABSENT="$EX_ABSENT $EX_F" ;; esac
done
eq "EX1 the export line names the four new verbs and their helpers" "$EX_ABSENT" ""
EX_MISSING="$(EX_LIST="$EX_LIST" bash -c 'for f in $EX_LIST; do type "$f" >/dev/null 2>&1 || printf "%s " "$f"; done')"
eq "EX2 a child shell sees every function the export line names" "$EX_MISSING" ""
EX_CTRL="$( (export -fn _zensu_vcs_pr_diff; EX_LIST="$EX_LIST" bash -c 'for f in $EX_LIST; do type "$f" >/dev/null 2>&1 || printf "%s " "$f"; done') )"
eq "EX2b control: a function taken off the export shows up as missing in the child" "$EX_CTRL" "_zensu_vcs_pr_diff "

echo "----"
echo "test-vcs-pr-ops: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
