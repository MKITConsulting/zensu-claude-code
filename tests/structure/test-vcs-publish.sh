#!/bin/bash
set -u

# Hermetic structure test for the VCS driver's team-review publish ops (Phase 3):
# --scout-pr / --fetch-pr-ref / --diff-refs / --post-review. No gh/glab execution —
# every op is a pure argv-builder (dry-printed under ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1)
# plus node normalizers fed fixture JSON. The GitLab publish path is a LOOP (spec §7:
# summary note + N inline discussions + position object + idempotency marker); its dry
# output is the ordered argv sequence, asserted below.

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
  echo "test-vcs-publish: $PASS PASS / $FAIL FAIL"
  exit 1
fi

check "P1 lib exists" PASS
bash -n "$LIB" 2>/dev/null && check "P2 bash -n syntax check passes" PASS || check "P2 bash -n syntax check passes" FAIL

# The lib must be plain text — a stray NUL byte flips `file`/grep into binary mode and the
# structure tests that grep it silently stop matching. Guard against a regression where the
# emit delimiter becomes a literal 0x00 NUL instead of being produced at runtime. `tr -d` strips NULs;
# if the stripped stream still equals the file there were none (portable — no reliance on
# grep's BSD-vs-GNU binary-file heuristics).
if LC_ALL=C tr -d '\000' < "$LIB" | cmp -s - "$LIB"; then
  check "P3 lib is NUL-free (ASCII text, greppable)" PASS
else
  check "P3 lib is NUL-free (ASCII text, greppable)" FAIL
fi

eq()   { local l="$1" g="$2" w="$3"; [ "$g" = "$w" ] && check "$l" PASS || check "$l (got '$g' want '$w')" FAIL; }
has()  { local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l" PASS ;; *) check "$l (missing '$n')" FAIL ;; esac; }
nothas(){ local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l (unexpected '$n')" FAIL ;; *) check "$l" PASS ;; esac; }
before(){ local l="$1" g="$2" a="$3" b="$4"; local pre="${g%%"$b"*}"; case "$g" in *"$b"*) case "$pre" in *"$a"*) check "$l" PASS ;; *) check "$l ('$a' not before '$b')" FAIL ;; esac ;; *) check "$l ('$b' absent)" FAIL ;; esac; }

argv() { env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1 bash "$LIB" "$@" 2>/dev/null; }
fails() { local l="$1"; shift; local o rc; o="$(argv "$@" 2>/dev/null)"; rc=$?; { [ -z "$o" ] && [ "$rc" -ne 0 ]; } && check "$l" PASS || check "$l (out='$o' rc=$rc)" FAIL; }

# ---- payload fixture (read by the GitLab publish planner) ----
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vcs-publish.XXXXXXXX")"
PAY="$WORK/synth.json"
cat > "$PAY" <<'JSON'
{"commit_id":"abc123","event":"REQUEST_CHANGES","body":"Overall review body.","comments":[{"path":"src/a.js","line":10,"side":"RIGHT","body":"fix new line"},{"path":"src/b.js","line":5,"side":"LEFT","body":"removed line note"}]}
JSON

# ---- scout-pr argv ----
eq "A1 scout github branch"  "$(argv --scout-pr --provider github)"   "gh pr view --json number,url,state,title,body,headRefName,baseRefName,author,labels"
eq "A2 scout github num"     "$(argv --scout-pr --provider github 42)" "gh pr view --json number,url,state,title,body,headRefName,baseRefName,author,labels -- 42"
eq "A3 scout gitlab branch"  "$(argv --scout-pr --provider gitlab)"   "glab mr view --output json"
eq "A4 scout gitlab num"     "$(argv --scout-pr --provider gitlab 7)"  "glab mr view --output json -- 7"

# ---- fetch-pr-ref refspec (pure string; not dry-gated) ----
eq "A5 fetch-pr-ref github"  "$(argv --fetch-pr-ref --provider github 42)" "pull/42/head"
eq "A6 fetch-pr-ref gitlab"  "$(argv --fetch-pr-ref --provider gitlab 7)"  "merge-requests/7/head"

# ---- diff-refs argv ----
eq "A7 diff-refs github num" "$(argv --diff-refs --provider github 42)" "gh pr view --json headRefOid -- 42"
eq "A8 diff-refs gitlab"     "$(argv --diff-refs --provider gitlab --repo-id grp%2Fproj 7)" "glab api projects/grp%2Fproj/merge_requests/7"

# ---- post-review GitHub: one atomic reviews --input call ----
eq "A9 post-review github atomic" "$(argv --post-review --provider github --repo-id acme/widget 42 "$PAY")" "gh api -X POST repos/acme/widget/pulls/42/reviews --input $PAY"

# ---- post-review GitLab: the ordered LOOP sequence (summary note THEN discussions) ----
GLP="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"BBB","start_sha":"SSS","head_sha":"HHH"}' 7 "$PAY")"
has    "A10a gitlab summary note POST"        "$GLP" "glab api --method POST projects/grp%2Fproj/merge_requests/7/notes"
has    "A10b gitlab inline discussions POST"  "$GLP" "glab api --method POST projects/grp%2Fproj/merge_requests/7/discussions"
before "A10c gitlab summary note BEFORE discussions" "$GLP" "merge_requests/7/notes" "merge_requests/7/discussions"
has    "A10d gitlab idempotency marker (pr7)" "$GLP" "<!-- zensu:pr7:"
has    "A10e gitlab verdict carried in body"  "$GLP" "_Verdict: REQUEST_CHANGES_"
has    "A10f gitlab position_type text"       "$GLP" "position[position_type]=text"
has    "A10g gitlab position diff refs"       "$GLP" "position[base_sha]=BBB"
has    "A10h gitlab RIGHT->new_path"          "$GLP" "position[new_path]=src/a.js"
has    "A10i gitlab RIGHT->new_line"          "$GLP" "position[new_line]=10"
has    "A10j gitlab LEFT->old_path"           "$GLP" "position[old_path]=src/b.js"
has    "A10k gitlab LEFT->old_line"           "$GLP" "position[old_line]=5"
nothas "A10l gitlab LEFT has no new_path"     "$GLP" "position[new_path]=src/b.js"
nothas "A10m gitlab never auto-approves"      "$GLP" "mr approve"
eq     "A10n gitlab exactly 1 summary note"   "$(printf '%s' "$GLP" | grep -c 'merge_requests/7/notes')" "1"
eq     "A10o gitlab exactly 2 discussions"    "$(printf '%s' "$GLP" | grep -c 'merge_requests/7/discussions')" "2"

# ---- fail-loud guards ----
fails "G1 scout requires --provider"            --scout-pr 42
fails "G2 scout non-numeric num rejected"       --scout-pr --provider github 'ev?a=b'
fails "G3 fetch-pr-ref requires --provider"     --fetch-pr-ref 42
fails "G4 fetch-pr-ref non-numeric rejected"    --fetch-pr-ref --provider github notanum
fails "G5 diff-refs gitlab requires repo-id"    --diff-refs --provider gitlab 7
fails "G6 diff-refs unknown provider"           --diff-refs --provider bogus 7
fails "G7 post-review requires --provider"      --post-review --repo-id acme/widget 42 "$PAY"
fails "G8 post-review requires repo-id"         --post-review --provider github 42 "$PAY"
fails "G9 post-review github repo-id needs slash" --post-review --provider github --repo-id noslash 42 "$PAY"
fails "G10 post-review non-numeric id rejected" --post-review --provider github --repo-id acme/widget abc "$PAY"
fails "G11 post-review unknown provider"        --post-review --provider bogus --repo-id x/y 1 "$PAY"

# ---- normalizers (source + fixtures) ----
source "$LIB" >/dev/null 2>&1

GH_SCOUT='{"number":42,"url":"https://github.test/acme/widget/pull/42","state":"OPEN","title":"T","body":"B","headRefName":"feat","baseRefName":"main","author":{"login":"alice"},"labels":[{"name":"bug"},{"name":"p1"}]}'
eq "N1 normalize_scout github" "$(printf '%s' "$GH_SCOUT" | _zensu_vcs_normalize_scout github)" '{"id":"42","url":"https://github.test/acme/widget/pull/42","state":"OPEN","title":"T","body":"B","base":"main","head":"feat","author":"alice","labels":["bug","p1"]}'

GL_SCOUT='{"iid":7,"web_url":"https://gitlab.test/grp/proj/-/merge_requests/7","state":"opened","title":"T","description":"D","source_branch":"s","target_branch":"t","author":{"username":"carol"},"labels":["nit","backend"]}'
eq "N2 normalize_scout gitlab" "$(printf '%s' "$GL_SCOUT" | _zensu_vcs_normalize_scout gitlab)" '{"id":"7","url":"https://gitlab.test/grp/proj/-/merge_requests/7","state":"OPEN","title":"T","body":"D","base":"t","head":"s","author":"carol","labels":["nit","backend"]}'

eq "N3 scout gitlab state merged" "$(printf '%s' "${GL_SCOUT/\"opened\"/\"merged\"}" | _zensu_vcs_normalize_scout gitlab | sed 's/.*"state":"\([A-Z]*\)".*/\1/')" "MERGED"
eq "N4 scout gitlab state closed" "$(printf '%s' "${GL_SCOUT/\"opened\"/\"closed\"}" | _zensu_vcs_normalize_scout gitlab | sed 's/.*"state":"\([A-Z]*\)".*/\1/')" "CLOSED"
eq "N5 scout gitlab state locked->OPEN" "$(printf '%s' "${GL_SCOUT/\"opened\"/\"locked\"}" | _zensu_vcs_normalize_scout gitlab | sed 's/.*"state":"\([A-Z]*\)".*/\1/')" "OPEN"

eq "N6 normalize_diff_refs github (headRefOid)" "$(printf '%s' '{"headRefOid":"deadbeef"}' | _zensu_vcs_normalize_diff_refs github)" '{"base_sha":"","start_sha":"","head_sha":"deadbeef"}'
eq "N7 normalize_diff_refs gitlab (diff_refs)"  "$(printf '%s' '{"diff_refs":{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}}' | _zensu_vcs_normalize_diff_refs gitlab)" '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}'

if printf '%s' 'not json' | _zensu_vcs_normalize_scout github >/dev/null 2>&1; then check "N8 normalize_scout malformed -> non-zero" FAIL; else check "N8 normalize_scout malformed -> non-zero" PASS; fi
if printf '%s' 'not json' | _zensu_vcs_normalize_diff_refs gitlab >/dev/null 2>&1; then check "N9 normalize_diff_refs malformed -> non-zero" FAIL; else check "N9 normalize_diff_refs malformed -> non-zero" PASS; fi
if printf '%s' '{"number":42,"url":{},"state":"OPEN","title":[],"body":"B","headRefName":"feat","baseRefName":"main","author":{},"labels":[]}' | _zensu_vcs_normalize_scout github >/dev/null 2>&1; then
  check "N9a scout normalization rejects composite remote fields" FAIL
else
  check "N9a scout normalization rejects composite remote fields" PASS
fi
if printf '%s' '{"headRefOid":{}}' | _zensu_vcs_normalize_diff_refs github >/dev/null 2>&1; then
  check "N9b diff-ref normalization rejects composite SHA values" FAIL
else
  check "N9b diff-ref normalization rejects composite SHA values" PASS
fi
if node -e 'process.stdout.write(JSON.stringify({iid:7,web_url:"https://gitlab.test/g/p/-/merge_requests/7",state:"opened",title:"T",description:"x".repeat(70000),source_branch:"s",target_branch:"t",author:{username:"a"},labels:[]}))' \
  | _zensu_vcs_normalize_scout gitlab >/dev/null 2>&1; then
  check "N9c valid GitLab descriptions above 64 KiB remain scoutable" PASS
else
  check "N9c valid GitLab descriptions above 64 KiB remain scoutable" FAIL
fi

BASH_ABS="$(command -v bash)"
if PATH=/dev/null "$BASH_ABS" -c 'source '"$LIB"'; printf "%s" "{}" | _zensu_vcs_normalize_scout github' >/dev/null 2>&1; then
  check "N10 normalize_scout without Node fails closed" FAIL
else
  check "N10 normalize_scout without Node fails closed" PASS
fi
if PATH=/dev/null "$BASH_ABS" -c 'source '"$LIB"'; printf "%s" "{}" | _zensu_vcs_normalize_diff_refs gitlab' >/dev/null 2>&1; then
  check "N11 normalize_diff_refs without Node fails closed" FAIL
else
  check "N11 normalize_diff_refs without Node fails closed" PASS
fi

# ---- summary-note-only path (comments:[]) — the common COMMENT verdict with zero inline ----
cat > "$WORK/empty.json" <<'JSON'
{"event":"COMMENT","body":"summary only","comments":[]}
JSON
GLE="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/empty.json")"
eq "A11a gitlab empty-comments -> exactly 1 note"     "$(printf '%s' "$GLE" | grep -c 'merge_requests/7/notes')" "1"
eq "A11b gitlab empty-comments -> 0 discussions"      "$(printf '%s' "$GLE" | grep -c 'merge_requests/7/discussions')" "0"

# ---- marker well-formedness (8-hex) + summary/comment markers are distinct ----
MK_FIRST="$(printf '%s' "$GLP" | grep -oE '<!-- zensu:pr7:[0-9a-f]{8} -->' | head -1)"
MK_DISTINCT="$(printf '%s' "$GLP" | grep -oE '<!-- zensu:pr7:[0-9a-f]{8} -->' | sort -u | grep -c .)"
has "A12a marker is 8-hex well-formed"                "$MK_FIRST" "<!-- zensu:pr7:"
eq  "A12b summary + 2 comments -> 3 distinct markers" "$MK_DISTINCT" "3"

# ---- all three diff-ref SHAs mapped (not just base_sha) ----
has "A13a start_sha mapped" "$GLP" "position[start_sha]=SSS"
has "A13b head_sha mapped"  "$GLP" "position[head_sha]=HHH"

# ---- RIGHT is the default side + no old_* leak on a RIGHT comment ----
cat > "$WORK/rightdef.json" <<'JSON'
{"event":"COMMENT","body":"b","comments":[{"path":"z.js","line":3,"body":"no side field"}]}
JSON
GLD="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/rightdef.json")"
has    "A14a side omitted -> RIGHT/new_path" "$GLD" "position[new_path]=z.js"
nothas "A14b RIGHT comment has no old_path"  "$GLD" "position[old_path]=z.js"

# ---- placeholder diff-refs branch (no --diff-refs-json in dry mode) ----
GLP2="$(argv --post-review --provider gitlab --repo-id grp%2Fproj 7 "$PAY")"
has "A15 placeholder diff-refs when json omitted" "$GLP2" "position[base_sha]=BASE_SHA"

# ---- C0 sanitization: a NUL in a body must NOT smuggle an extra argv token ----
node -e 'var fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({event:"COMMENT",body:"ok",comments:[{path:"a.js",line:1,side:"RIGHT",body:"x"+String.fromCharCode(0)+"--host"+String.fromCharCode(0)+"evil"}]}));' "$WORK/nul.json"
GLN="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/nul.json")"
# A16a is the real guard: without san() the embedded NUL would split the body into extra
# argv tokens, so the dry output would read "x --host evil" (space-separated) instead of the
# fused "x--hostevil". (A prior "output has no NUL" check was dropped — $() capture strips
# NUL before the assertion could ever observe one, making it tautological.)
has "A16a NUL stripped from body (tokens fused, no smuggle)" "$GLN" "x--hostevil"
nothas "A16b un-sanitized split would leak a bare --host token" "$GLN" " --host"

# ---- line-less comment (e.g. a file-level coverage finding) posts as a general thread ----
# GitLab rejects an inline position with an empty line; rather than post the summary note and
# then abort mid-loop, a comment with no line becomes a positionless discussion (path in body).
cat > "$WORK/noline.json" <<'JSON'
{"event":"COMMENT","body":"s","comments":[{"path":"uncovered/File.java","body":"no test exercises this file"}]}
JSON
GLL="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/noline.json")"
has    "A17a line-less comment still posts a discussion" "$GLL" "merge_requests/7/discussions"
nothas "A17b line-less comment has NO position object"   "$GLL" "position["
has    "A17c line-less comment keeps the path in body"    "$GLL" "uncovered/File.java"

# ---- more fail-loud guards for the new ops ----
fails "G12 post-review requires payload"    --post-review --provider github --repo-id acme/widget 42
fails "G13 diff-refs github non-numeric id"  --diff-refs --provider github abc
fails "G14 diff-refs gitlab bad repo-id charset" --diff-refs --provider gitlab --repo-id 'grp/proj' 7
fails "G15 post-review github rejects extra repo path" --post-review --provider github --repo-id acme/widget/extra 42 "$PAY"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/glab" <<'FAKE'
#!/bin/bash
printf '%s' '{"diff_refs":{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}}'
exit 23
FAKE
chmod +x "$WORK/bin/glab"
if PATH="$WORK/bin:$PATH" _zensu_vcs_post_review_gitlab grp%2Fproj 7 "$PAY" "" >/dev/null 2>&1; then
  check "G16 legacy GitLab diff-ref read preserves producer failure" FAIL
else
  check "G16 legacy GitLab diff-ref read preserves producer failure" PASS
fi

rm -rf "$WORK"

echo "----"
echo "test-vcs-publish: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
