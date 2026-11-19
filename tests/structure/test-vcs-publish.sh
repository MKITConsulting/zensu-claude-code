#!/bin/bash
set -u

# Hermetic structure test for the VCS driver's team-review publish ops. The GitLab publish
# path is a LOOP (spec §7: summary note + N inline discussions + position object + idempotency
# marker); its dry output is the ordered argv sequence, each POST followed by its JSON request
# line, asserted below.

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
nth_json() {
  TEXT="$1" N="$2" FIELD="$3" node -e '
    var lines=process.env.TEXT.split("\n").filter(function(l){return l.charAt(0)==="{";});
    var v;try{v=JSON.parse(lines[Number(process.env.N)-1]);}catch(_){process.exit(1);}
    process.env.FIELD.split(".").forEach(function(p){if(p&&v!=null)v=Object.prototype.hasOwnProperty.call(v,p)?v[p]:undefined;});
    process.stdout.write(v===undefined?"<absent>":JSON.stringify(v));'
}

# ---- payload fixture (read by the GitLab publish planner) ----
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vcs-publish.XXXXXXXX")"
SPECIAL_PAYLOAD_DIR="$WORK/review path's boundary"
mkdir -p "$SPECIAL_PAYLOAD_DIR"
PAY="$SPECIAL_PAYLOAD_DIR/synth payload's copy.json"
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
eq     "A10f gitlab RIGHT position is one nested JSON object" "$(nth_json "$GLP" 2 position)" \
  '{"position_type":"text","base_sha":"BBB","start_sha":"SSS","head_sha":"HHH","old_path":"src/a.js","new_path":"src/a.js","new_line":10}'
eq     "A10g gitlab LEFT position is one nested JSON object"  "$(nth_json "$GLP" 3 position)" \
  '{"position_type":"text","base_sha":"BBB","start_sha":"SSS","head_sha":"HHH","old_path":"src/b.js","new_path":"src/b.js","old_line":5}'
eq     "A10h gitlab summary note request carries no position" "$(nth_json "$GLP" 1 position)" "<absent>"
nothas "A10i gitlab sends no bracketed field names"          "$GLP" "position["
nothas "A10j gitlab passes no -f field flags"                "$GLP" " -f "
eq     "A10k every gitlab POST declares a JSON Content-Type before its stdin body" \
  "$(printf '%s\n' "$GLP" | grep -c -- '--header Content-Type: application/json --input -$')" "3"
eq     "A10l every gitlab POST is followed by exactly one JSON request line" "$(printf '%s\n' "$GLP" | grep -c '^{')" "3"
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
RM_HEX_A="$(printf '%064d' 0 | tr 0 a)"
RM_HEX_B="$(printf '%064d' 0 | tr 0 b)"
RM_FIRST="<!-- zensu-review:v1:$RM_HEX_A:$RM_HEX_B:abcdef0:3:part=1/3 -->"
RM_JSON="$(RM_FIRST="$RM_FIRST" node -e 'var m=process.env.RM_FIRST;process.stdout.write(JSON.stringify({notes:[{id:1,body:m+"\n\nsummary"},{id:2,body:"quoted "+m}],discussions:[[{id:"d1",notes:[{id:3,body:m.replace("part=1/3","part=2/3")}]}]]}))')"
eq "N12 the shared body-marker walk lists each first-part review marker once" "$(printf '%s' "$RM_JSON" | _zensu_vcs_body_markers review)" "$RM_FIRST"
if printf '%s' "$RM_JSON" | _zensu_vcs_body_markers bogus >/dev/null 2>&1; then
  check "N13 the body-marker walk refuses an unknown marker kind" FAIL
else
  check "N13 the body-marker walk refuses an unknown marker kind" PASS
fi
has "N13b the body-marker walk names an unknown marker kind on stderr" "$(printf '%s' "$RM_JSON" | _zensu_vcs_body_markers bogus 2>&1 >/dev/null)" "zensu-vcs: marker walk failed: unknown marker kind"
if printf '%s' 'not json' | _zensu_vcs_body_markers review >/dev/null 2>&1; then
  check "N14 the body-marker walk fails closed on malformed JSON" FAIL
else
  check "N14 the body-marker walk fails closed on malformed JSON" PASS
fi
has "N14b the body-marker walk names malformed input on stderr" "$(printf '%s' 'not json' | _zensu_vcs_body_markers review 2>&1 >/dev/null)" "zensu-vcs: review marker walk failed: the input is not JSON"
has "N14c the body-marker walk names an input over 32 MiB on stderr" "$(head -c 33554433 /dev/zero | tr '\0' ' ' | _zensu_vcs_body_markers review 2>&1 >/dev/null)" "zensu-vcs: review marker walk failed: the input exceeds 32 MiB"
PM() { printf '<!-- zensu:pr7:%08x -->' "$1"; }
PM_JSON="$(M1="$(PM 1)" M2="$(PM 2)" M3="$(PM 3)" M4="$(PM 4)" M5="$(PM 5)" node -e 'var e=process.env;process.stdout.write(JSON.stringify({notes:[{id:1,body:e.M1+"\n\nsummary",system:false,author:{id:42}},{id:2,body:e.M2,system:false,author:{id:7}},{id:3,body:"quoting "+e.M3,system:false,author:{id:42}},{id:4,body:e.M4,system:true,author:{id:42}}],discussions:[{id:"d5",individual_note:false,notes:[{id:5,body:e.M5+"\n\nfinding",system:false,author:{id:42}}]}]}))')"
PM_WANT="$(printf '%s\n' "$(PM 1)" "$(PM 2)" "$(PM 3)" "$(PM 4)" "$(PM 5)" "$(PM 6)")"
eq "N15 the post walk lists only wanted markers that open a non-system note by the publisher" \
  "$(printf '%s' "$PM_JSON" | _zensu_vcs_body_markers post 42 "$PM_WANT")" "$(printf '%s\n%s' "$(PM 1)" "$(PM 5)")"
if printf '%s' "$PM_JSON" | _zensu_vcs_body_markers post '' "$PM_WANT" >/dev/null 2>&1; then
  check "N16 the post walk refuses to run without a publisher id" FAIL
else
  check "N16 the post walk refuses to run without a publisher id" PASS
fi
has "N16b the post walk names the missing publisher id on stderr" "$(printf '%s' "$PM_JSON" | _zensu_vcs_body_markers post '' "$PM_WANT" 2>&1 >/dev/null)" "zensu-vcs: post marker walk failed: no publisher id"
if printf '%s' "$PM_JSON" | _zensu_vcs_body_markers post 42 '' >/dev/null 2>&1; then
  check "N17 the post walk refuses to run without markers to look for" FAIL
else
  check "N17 the post walk refuses to run without markers to look for" PASS
fi
has "N17b the post walk names the missing markers on stderr" "$(printf '%s' "$PM_JSON" | _zensu_vcs_body_markers post 42 '' 2>&1 >/dev/null)" "zensu-vcs: post marker walk failed: no markers to look for"

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
eq "A13a start_sha mapped" "$(nth_json "$GLP" 2 position.start_sha)" '"SSS"'
eq "A13b head_sha mapped"  "$(nth_json "$GLP" 2 position.head_sha)" '"HHH"'

# ---- RIGHT is the default side + no old_* leak on a RIGHT comment ----
cat > "$WORK/rightdef.json" <<'JSON'
{"event":"COMMENT","body":"b","comments":[{"path":"z.js","line":3,"body":"no side field"}]}
JSON
GLD="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/rightdef.json")"
eq "A14a side omitted -> RIGHT/new_path" "$(nth_json "$GLD" 2 position.new_path)" '"z.js"'
eq "A14b RIGHT comment has no old_line"  "$(nth_json "$GLD" 2 position.old_line)" "<absent>"

# ---- placeholder diff-refs branch (no --diff-refs-json in dry mode) ----
GLP2="$(argv --post-review --provider gitlab --repo-id grp%2Fproj 7 "$PAY")"
eq "A15 placeholder diff-refs when json omitted" "$(nth_json "$GLP2" 2 position.base_sha)" '"BASE_SHA"'

# ---- C0 sanitization: a NUL in a body never reaches the request ----
node -e 'var fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({event:"COMMENT",body:"ok",comments:[{path:"a.js",line:1,side:"RIGHT",body:"x"+String.fromCharCode(0)+"--host"+String.fromCharCode(0)+"evil"}]}));' "$WORK/nul.json"
GLN="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/nul.json")"
# A16a is the real guard: without san() JSON.stringify would carry the embedded NUL as an
# escape, so the dry output would read "x\u0000--host\u0000evil" instead of the fused
# "x--hostevil". (A prior "output has no NUL" check was dropped — $() capture strips
# NUL before the assertion could ever observe one, making it tautological.)
has "A16a NUL stripped from body (tokens fused, no smuggle)" "$GLN" "x--hostevil"
nothas "A16b no escaped NUL reaches the JSON request" "$GLN" '\u0000'

# ---- line-less comment (e.g. a file-level coverage finding) posts as a general thread ----
# GitLab rejects an inline position with an empty line; rather than post the summary note and
# then abort mid-loop, a comment with no line becomes a positionless discussion (path in body).
cat > "$WORK/noline.json" <<'JSON'
{"event":"COMMENT","body":"s","comments":[{"path":"uncovered/File.java","body":"no test exercises this file"}]}
JSON
GLL="$(argv --post-review --provider gitlab --repo-id grp%2Fproj --diff-refs-json '{"base_sha":"B","start_sha":"S","head_sha":"H"}' 7 "$WORK/noline.json")"
has    "A17a line-less comment still posts a discussion" "$GLL" "merge_requests/7/discussions"
eq     "A17b line-less comment has NO position object"   "$(nth_json "$GLL" 2 position)" "<absent>"
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

mkdir -p "$WORK/live/bin" "$WORK/live/state"
cat > "$WORK/live/payload.json" <<'JSON'
{"commit_id":"abcdef0","event":"COMMENT","body":"Live review body.","comments":[{"path":"src/a.js","line":10,"side":"RIGHT","body":"added line note"},{"path":"src/b.js","line":5,"side":"LEFT","body":"removed line note"},{"path":"src/a.js","line":12,"side":"RIGHT","body":"context line note"},{"path":"src/new.js","line":3,"side":"RIGHT","body":"renamed file note"},{"path":"src/a.js","line":99,"side":"RIGHT","body":"outside the diff note"}]}
JSON
cat > "$WORK/live/diffs.json" <<'JSON'
[[{"old_path":"src/a.js","new_path":"src/a.js","diff":"@@ -9,4 +9,5 @@\n line9\n+added10\n ctx\n ctx2\n ctx3\n"},{"old_path":"src/b.js","new_path":"src/b.js","diff":"@@ -4,3 +4,2 @@\n keep4\n-removed5\n keep6\n"},{"old_path":"src/old.js","new_path":"src/new.js","diff":"@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n"}]]
JSON
cat > "$WORK/live/lines.json" <<'JSON'
[["src/a.js","src/a.js",9,9],["src/a.js","src/a.js",null,10],["src/a.js","src/a.js",10,11],["src/a.js","src/a.js",11,12],["src/a.js","src/a.js",12,13],["src/b.js","src/b.js",4,4],["src/b.js","src/b.js",5,null],["src/b.js","src/b.js",6,5],["src/old.js","src/new.js",1,1],["src/old.js","src/new.js",2,null],["src/old.js","src/new.js",null,2],["src/old.js","src/new.js",3,3]]
JSON
cat > "$WORK/live/bin/glab" <<'FAKE'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
path="${*: -1}"
if [ "${1:-}" = api ] && [ "$path" = 'projects/grp%2Fproj/merge_requests/7' ]; then
  printf '%s' '{"diff_refs":{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0"}}'
  exit 0
fi
if [ "${1:-}" = api ] && [ "$path" = 'projects/grp%2Fproj/merge_requests/7/diffs' ]; then
  case "${FAKE_DIFFS:-ok}" in
    fail)
      printf '%s\n' '{"message":"500 Internal Server Error"}' 'glab: HTTP 500' >&2
      exit 1 ;;
    truncated)
      printf '%s' '[[{"old_path":"src/a.js","new_path":"src/a.js","diff":"@@ -9,4 +9,5 @@\n line9\n+added10\n"}]]'
      exit 0 ;;
  esac
  cat "${FAKE_DIR%/*}/diffs.json"
  exit 0
fi
if [ "${1:-}" = api ] && [ "$path" = user ]; then
  case "${FAKE_USER:-ok}" in
    fail)
      printf '%s\n' '{"message":"401 Unauthorized"}' 'glab: HTTP 401' >&2
      exit 1 ;;
    noid)
      printf '%s' '{"username":"zensu-bot"}'
      exit 0 ;;
    html)
      printf '%s' '<html><body>Sign in</body></html>'
      exit 0 ;;
  esac
  printf '%s' '{"id":42,"username":"zensu-bot"}'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --paginate ]; then
  case "${FAKE_LISTING:-ok}" in
    fail)
      printf '%s\n' '{"message":"500 Internal Server Error"}' 'glab: HTTP 500' >&2
      exit 1 ;;
    malformed)
      printf '%s' '[{'
      exit 0 ;;
    huge)
      if [ "${path##*/}" = notes ]; then head -c 33554433 /dev/zero | tr '\0' ' '; else printf '%s' '[]'; fi
      exit 0 ;;
  esac
  FAKE_DIR="$FAKE_DIR" KIND="${path##*/}" node -e '
    var fs=require("fs"),f=process.env.FAKE_DIR+"/posted",g=process.env.FAKE_DIR+"/foreign",a=[];
    function put(kind,note){a.push(kind==="discussions"?{id:"d"+(a.length+1),individual_note:false,notes:[note]}:note);}
    if(fs.existsSync(g))fs.readFileSync(g,"utf8").split("\n").forEach(function(l){if(!l)return;var r=JSON.parse(l);if(r.kind!==process.env.KIND)return;
      put(r.kind,{id:a.length+1,body:r.body,system:r.system===true,author:{id:r.authorId}});});
    if(fs.existsSync(f))fs.readFileSync(f,"utf8").split("\n").forEach(function(l){if(!l)return;var r=JSON.parse(l);if(r.kind!==process.env.KIND)return;
      put(r.kind,{id:a.length+1,body:r.request.body,system:false,author:{id:42}});});
    process.stdout.write(JSON.stringify(a).replace(/[<>]/g,function(c){return "\\u00"+c.charCodeAt(0).toString(16);}));'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = --method ] && [ "${3:-}" = POST ]; then
  input=""; content_type=""; prev=""
  for arg in "$@"; do
    case "$arg" in -f|-F|--field|--raw-field) exit 2 ;; esac
    [ "$prev" = --input ] && input="$arg"
    if [ "$prev" = --header ] || [ "$prev" = -H ]; then
      if [ "$(printf '%s' "${arg%%:*}" | tr '[:upper:]' '[:lower:]')" = content-type ]; then
        content_type="$(printf '%s' "${arg#*:}" | tr -d ' ')"
      fi
    fi
    prev="$arg"
  done
  [ "$input" = - ] || exit 2
  case "$content_type" in
    application/json|application/json\;*) ;;
    *)
      printf '%s\n' "{\"error\":\"The provided content-type '$content_type' is not supported.\"}" 'glab: HTTP 415' >&2
      exit 1 ;;
  esac
  if [ -n "${FAKE_REFUSE_AT:-}" ] && [ "$(grep -c -- '--method POST' "$FAKE_DIR/calls")" = "$FAKE_REFUSE_AT" ]; then
    cat >/dev/null
    printf '%s\n' '{"message":"400 Bad request - refused by the fixture"}' 'glab: HTTP 400' >&2
    exit 1
  fi
  FAKE_DIR="$FAKE_DIR" KIND="${4##*/}" node -e '
    var fs=require("fs"),raw="";
    process.stdin.on("data",function(c){raw+=c;});process.stdin.on("end",function(){
      var r;try{r=JSON.parse(raw);}catch(_){process.exit(2);}
      if(!r||typeof r!=="object"||Array.isArray(r)||typeof r.body!=="string"
          ||!Object.keys(r).every(function(k){return k==="body"||k==="position";}))process.exit(2);
      if(Object.prototype.hasOwnProperty.call(r,"position")){
        var p=r.position,dir=process.env.FAKE_DIR;
        var lines=JSON.parse(fs.readFileSync(dir.slice(0,dir.lastIndexOf("/"))+"/lines.json","utf8"));
        var ol=p&&p.old_line!=null?p.old_line:null,nl=p&&p.new_line!=null?p.new_line:null;
        if(!p||p.position_type!=="text"||p.base_sha!=="ba5e000"||p.start_sha!=="57a2700"||p.head_sha!=="abcdef0"
            ||!lines.some(function(l){return l[0]===p.old_path&&l[1]===p.new_path&&l[2]===ol&&l[3]===nl;})){
          process.stderr.write("{\"message\":\"400 Bad request - the position names no line of the merge request diff\"}\nglab: HTTP 400\n");
          process.exit(1);
        }
      }
      fs.appendFileSync(process.env.FAKE_DIR+"/posted",JSON.stringify({kind:process.env.KIND,request:r})+"\n");
      process.stdout.write("{\"id\":1}");
    });'
  exit $?
fi
exit 2
FAKE
chmod +x "$WORK/live/bin/glab"
live_post() {
  FAKE_DIR="$WORK/live/state" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1
}
if live_post; then
  check "LV1 live gitlab post-review succeeds against a glab that enforces the JSON Content-Type and GitLab's position rules" PASS
else
  check "LV1 live gitlab post-review succeeds against a glab that enforces the JSON Content-Type and GitLab's position rules" FAIL
fi
eq "LV2 live run posts the summary note and all five discussions" "$(grep -c -- '--method POST' "$WORK/live/state/calls" || true)" "6"
eq "LV3 every live POST declares the JSON Content-Type before its stdin body" \
  "$(grep -c -- '--method POST .* --header Content-Type: application/json --input -$' "$WORK/live/state/calls" || true)" "6"
LIVE_POSTED="$(cat "$WORK/live/state/posted" 2>/dev/null)"
eq "LV4 live summary note is a body-only JSON request" "$(nth_json "$LIVE_POSTED" 1 request.position)" "<absent>"
eq "LV5 an added line carries new_line and both paths from the MR diff" "$(nth_json "$LIVE_POSTED" 2 request.position)" \
  '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"src/a.js","new_path":"src/a.js","new_line":10}'
eq "LV6 a removed line carries old_line and both paths from the MR diff" "$(nth_json "$LIVE_POSTED" 3 request.position)" \
  '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"src/b.js","new_path":"src/b.js","old_line":5}'
eq "LV10 an unchanged context line carries both line numbers from the MR diff" "$(nth_json "$LIVE_POSTED" 4 request.position)" \
  '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"src/a.js","new_path":"src/a.js","old_line":11,"new_line":12}'
eq "LV11 a context line of a renamed file carries the old and the new path from the MR diff" "$(nth_json "$LIVE_POSTED" 5 request.position)" \
  '{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"src/old.js","new_path":"src/new.js","old_line":3,"new_line":3}'
eq "LV12a an anchor outside the MR diff posts as a positionless discussion" "$(nth_json "$LIVE_POSTED" 6 request.position)" "<absent>"
has "LV12b the positionless discussion keeps the path in its body" "$(nth_json "$LIVE_POSTED" 6 request.body)" '`src/a.js`: outside the diff note'
eq "LV13 the MR diff is read before the first POST" \
  "$(awk '/merge_requests\/7\/diffs$/{if(!d)d=NR} /--method POST/{if(!p)p=NR} END{if (d && p && d < p) print "ordered"; else print "unordered"}' "$WORK/live/state/calls")" "ordered"
if live_post; then check "LV7 a live re-run succeeds" PASS; else check "LV7 a live re-run succeeds" FAIL; fi
eq "LV8 a live re-run finds every marker and posts nothing new" "$(grep -c -- '--method POST' "$WORK/live/state/calls" || true)" "6"
LIVE_LISTING="$(FAKE_DIR="$WORK/live/state" "$WORK/live/bin/glab" api --paginate --output json projects/grp%2Fproj/merge_requests/7/discussions 2>/dev/null)"
has    "LV24a the fake glab lists a stored marker with JSON-escaped angle brackets, as GitLab does" "$LIVE_LISTING" '\u003c!-- zensu:pr7:'
nothas "LV24b the fake glab lists no raw angle bracket" "$LIVE_LISTING" '<!--'
has    "LV24c the fake glab nests each discussion's notes, as GitLab does" "$LIVE_LISTING" '"individual_note":false,"notes":[{"id":'
LIVE_ERR="$(printf '%s' '{"body":"probe"}' \
  | FAKE_DIR="$WORK/live/state" "$WORK/live/bin/glab" api --method POST projects/grp%2Fproj/merge_requests/7/notes --input - 2>&1 >/dev/null)"
LIVE_RC=$?
if [ "$LIVE_RC" -ne 0 ] && printf '%s' "$LIVE_ERR" | grep -qF 'HTTP 415' \
  && [ "$(grep -c . "$WORK/live/state/posted")" = 6 ]; then
  check "LV9 the fake glab refuses a stdin body without a JSON Content-Type, as GitLab does" PASS
else
  check "LV9 the fake glab refuses a stdin body without a JSON Content-Type, as GitLab does" FAIL
fi
LIVE_ONE_SIDED_ERR="$(printf '%s' '{"body":"probe","position":{"position_type":"text","base_sha":"ba5e000","start_sha":"57a2700","head_sha":"abcdef0","old_path":"src/a.js","new_path":"src/a.js","new_line":12}}' \
  | FAKE_DIR="$WORK/live/state" "$WORK/live/bin/glab" api --method POST projects/grp%2Fproj/merge_requests/7/discussions \
      --header 'Content-Type: application/json' --input - 2>&1 >/dev/null)"
LIVE_ONE_SIDED_RC=$?
if [ "$LIVE_ONE_SIDED_RC" -ne 0 ] && printf '%s' "$LIVE_ONE_SIDED_ERR" | grep -qF 'HTTP 400' \
  && [ "$(grep -c . "$WORK/live/state/posted")" = 6 ]; then
  check "LV14 the fake glab refuses a one-sided position on an unchanged context line, as GitLab does" PASS
else
  check "LV14 the fake glab refuses a one-sided position on an unchanged context line, as GitLab does" FAIL
fi

mkdir -p "$WORK/live/refuse"
if FAKE_REFUSE_AT=3 FAKE_DIR="$WORK/live/refuse" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/refuse/stderr"; then
  check "LV15 a discussion GitLab refuses mid-loop makes post-review exit non-zero" FAIL
else
  check "LV15 a discussion GitLab refuses mid-loop makes post-review exit non-zero" PASS
fi
LIVE_REFUSE_ERR="$(cat "$WORK/live/refuse/stderr" 2>/dev/null)"
has "LV16a the refusal is reported under the post-review POST label" "$LIVE_REFUSE_ERR" "zensu-vcs: post-review POST (glab api) failed (rc=1): "
has "LV16b the refusal report carries the forge status" "$LIVE_REFUSE_ERR" "glab: HTTP 400"
eq "LV17 the run stops at the refused POST with only the parts before it posted" "$(grep -c . "$WORK/live/refuse/posted")" "2"
if FAKE_DIR="$WORK/live/refuse" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV18 a re-run after the refusal succeeds" PASS
else
  check "LV18 a re-run after the refusal succeeds" FAIL
fi
eq "LV19a the re-run posts exactly the four missing discussions" "$(grep -c -- '--method POST' "$WORK/live/refuse/calls")" "7"
eq "LV19b the merge request ends with one summary note and five discussions" \
  "$(grep -c '"kind":"notes"' "$WORK/live/refuse/posted"):$(grep -c '"kind":"discussions"' "$WORK/live/refuse/posted")" "1:5"

mkdir -p "$WORK/live/pf-fail"
if FAKE_DIFFS=fail FAKE_DIR="$WORK/live/pf-fail" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV20a a failed MR diff read makes post-review exit non-zero" FAIL
else
  check "LV20a a failed MR diff read makes post-review exit non-zero" PASS
fi
eq "LV20b a failed MR diff read posts nothing" "$(grep -c -- '--method POST' "$WORK/live/pf-fail/calls" || true)" "0"

mkdir -p "$WORK/live/pf-trunc"
if FAKE_DIFFS=truncated FAKE_DIR="$WORK/live/pf-trunc" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV21a a truncated MR diff hunk makes post-review exit non-zero" FAIL
else
  check "LV21a a truncated MR diff hunk makes post-review exit non-zero" PASS
fi
eq "LV21b a truncated MR diff hunk posts nothing" "$(grep -c -- '--method POST' "$WORK/live/pf-trunc/calls" || true)" "0"

mkdir -p "$WORK/live/pf-head"
if FAKE_DIR="$WORK/live/pf-head" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj \
      --diff-refs-json '{"base_sha":"ba5e000","start_sha":"57a2700","head_sha":"ABCDEF0"}' 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV22a an anchor plan the diff-plan guard refuses makes post-review exit non-zero" FAIL
else
  check "LV22a an anchor plan the diff-plan guard refuses makes post-review exit non-zero" PASS
fi
eq "LV22b a refused anchor plan posts nothing" "$(grep -c -- '--method POST' "$WORK/live/pf-head/calls" || true)" "0"

cat > "$WORK/live/noline.json" <<'JSON'
{"event":"COMMENT","body":"Line-less review.","comments":[{"path":"src/a.js","body":"file-level note"}]}
JSON
mkdir -p "$WORK/live/pf-noline"
if FAKE_DIR="$WORK/live/pf-noline" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/noline.json" >/dev/null 2>&1; then
  check "LV23a a review without line comments posts" PASS
else
  check "LV23a a review without line comments posts" FAIL
fi
eq "LV23b a review without line comments never reads the MR diff" "$(grep -c 'merge_requests/7/diffs$' "$WORK/live/pf-noline/calls" || true)" "0"

mkdir -p "$WORK/live/listing"
FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1
eq "LV25 a complete first post leaves the summary note and all five discussions" "$(grep -c -- '--method POST' "$WORK/live/listing/calls" || true)" "6"
if FAKE_LISTING=fail FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/listing/stderr"; then
  check "LV26a a failed existing-marker listing makes a re-run exit non-zero" FAIL
else
  check "LV26a a failed existing-marker listing makes a re-run exit non-zero" PASS
fi
eq "LV26b a failed existing-marker listing posts nothing again" "$(grep -c -- '--method POST' "$WORK/live/listing/calls" || true)" "6"
has "LV26c the failed listing is reported under the post-review existing label" "$(cat "$WORK/live/listing/stderr" 2>/dev/null)" "zensu-vcs: post-review existing (glab api notes) failed (rc=1): "
if FAKE_LISTING=malformed FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/listing/stderr-malformed"; then
  check "LV27a an existing-marker listing that is not JSON makes a re-run exit non-zero" FAIL
else
  check "LV27a an existing-marker listing that is not JSON makes a re-run exit non-zero" PASS
fi
eq "LV27b an existing-marker listing that is not JSON posts nothing again" "$(grep -c -- '--method POST' "$WORK/live/listing/calls" || true)" "6"
has "LV27c the unparseable listing is reported under the post-review existing label" "$(cat "$WORK/live/listing/stderr-malformed" 2>/dev/null)" "zensu-vcs: post-review existing failed: the notes or discussions listing is not JSON"
if FAKE_LISTING=huge FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/listing/stderr-huge"; then
  check "LV27d an existing-marker listing over 32 MiB makes a re-run exit non-zero" FAIL
else
  check "LV27d an existing-marker listing over 32 MiB makes a re-run exit non-zero" PASS
fi
eq "LV27e an existing-marker listing over 32 MiB posts nothing again" "$(grep -c -- '--method POST' "$WORK/live/listing/calls" || true)" "6"
has "LV27f the oversized listing is reported under the post-review existing label" "$(cat "$WORK/live/listing/stderr-huge" 2>/dev/null)" "zensu-vcs: post-review existing failed: the notes and discussions listings exceed 32 MiB"
RM_FAIL_ERR="$(FAKE_LISTING=fail FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" \
  bash "$LIB" --review-markers --provider gitlab --repo-id grp%2Fproj 7 2>&1 >/dev/null)"
has "LV28 a failed --review-markers listing is reported under the review-markers inventory label" "$RM_FAIL_ERR" "zensu-vcs: review-markers inventory (glab api notes) failed (rc=1): "
if FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" "$BASH_ABS" -c 'source "$1"; _zensu_vcs_review_fetch_inventory gitlab grp%2Fproj 7' _ "$LIB" >/dev/null 2>&1; then
  check "LV29 the inventory fetch refuses a call without a failure label" FAIL
else
  check "LV29 the inventory fetch refuses a call without a failure label" PASS
fi
if FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" "$BASH_ABS" -c 'source "$1"; _zensu_vcs_review_gitlab_publisher_id' _ "$LIB" >/dev/null 2>&1; then
  check "LV30 the publisher lookup refuses a call without a failure label" FAIL
else
  check "LV30 the publisher lookup refuses a call without a failure label" PASS
fi
eq "LV31 a labelled publisher lookup reads the account id" \
  "$(FAKE_DIR="$WORK/live/listing" PATH="$WORK/live/bin:$PATH" "$BASH_ABS" -c 'source "$1"; _zensu_vcs_review_gitlab_publisher_id "post-review publisher id"' _ "$LIB" 2>/dev/null)" "42"

mkdir -p "$WORK/live/user"
if FAKE_USER=fail FAKE_DIR="$WORK/live/user" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/user/stderr-fail"; then
  check "LV33a a failed publisher lookup makes --post-review exit non-zero" FAIL
else
  check "LV33a a failed publisher lookup makes --post-review exit non-zero" PASS
fi
has "LV33b the failed lookup is reported under the post-review publisher id label" "$(cat "$WORK/live/user/stderr-fail" 2>/dev/null)" "zensu-vcs: post-review publisher id (glab api user) failed (rc=1): "
if FAKE_USER=noid FAKE_DIR="$WORK/live/user" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/user/stderr-noid"; then
  check "LV34a a publisher answer without an account id makes --post-review exit non-zero" FAIL
else
  check "LV34a a publisher answer without an account id makes --post-review exit non-zero" PASS
fi
has "LV34b the answer without an account id is reported under the post-review publisher id label" "$(cat "$WORK/live/user/stderr-noid" 2>/dev/null)" "zensu-vcs: post-review publisher id failed: the glab api user answer carries no account id"
if FAKE_USER=html FAKE_DIR="$WORK/live/user" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>"$WORK/live/user/stderr-html"; then
  check "LV35a a publisher answer that is not JSON makes --post-review exit non-zero" FAIL
else
  check "LV35a a publisher answer that is not JSON makes --post-review exit non-zero" PASS
fi
has "LV35b the unparseable answer is reported under the post-review publisher id label" "$(cat "$WORK/live/user/stderr-html" 2>/dev/null)" "zensu-vcs: post-review publisher id failed: the glab api user answer is not JSON"
eq "LV36 a refused publisher lookup posts nothing" "$(grep -c -- '--method POST' "$WORK/live/user/calls" || true)" "0"

mkdir -p "$WORK/live/foreign-src" "$WORK/live/foreign"
if FAKE_DIR="$WORK/live/foreign-src" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV32c the foreign-source post succeeds" PASS
else
  check "LV32c the foreign-source post succeeds" FAIL
fi
SRC="$WORK/live/foreign-src/posted" OUT="$WORK/live/foreign/foreign" node -e '
  var fs=require("fs"),rows=fs.readFileSync(process.env.SRC,"utf8").split("\n").filter(Boolean).map(function(l){return JSON.parse(l);});
  function mk(i){return rows[i].request.body.split("\n")[0];}
  fs.writeFileSync(process.env.OUT,[
    JSON.stringify({kind:"notes",body:mk(0)+"\n\nquoted by another reviewer",authorId:7,system:false}),
    JSON.stringify({kind:"discussions",body:mk(1)+"\n\ncopied into a system note",authorId:42,system:true}),
    JSON.stringify({kind:"discussions",body:"quoting "+mk(2),authorId:42,system:false})
  ].join("\n")+"\n");'
eq "LV32d the foreign fixture carries the markers of parts 1 to 3" \
  "$(SRC="$WORK/live/foreign-src/posted" OUT="$WORK/live/foreign/foreign" node -e '
    var fs=require("fs");
    function rows(p){return fs.readFileSync(p,"utf8").split("\n").filter(Boolean).map(function(l){return JSON.parse(l);});}
    var src=rows(process.env.SRC),out=rows(process.env.OUT),n=0;
    out.forEach(function(r,i){var m=src[i].request.body.split("\n")[0];if(/^<!-- zensu:pr7:[0-9a-f]{8} -->$/.test(m)&&r.body.indexOf(m)>=0)n++;});
    process.stdout.write(String(out.length===3?n:-1));' 2>/dev/null)" "3"
if FAKE_DIR="$WORK/live/foreign" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV32e the run over the foreign notes succeeds" PASS
else
  check "LV32e the run over the foreign notes succeeds" FAIL
fi
eq "LV32a a part marker in another author's note, a system note or a quoting note does not stop that part from being posted" \
  "$(grep -c -- '--method POST' "$WORK/live/foreign/calls" || true)" "6"
if FAKE_DIR="$WORK/live/foreign" PATH="$WORK/live/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LIB" --post-review --provider gitlab --repo-id grp%2Fproj 7 "$WORK/live/payload.json" >/dev/null 2>&1; then
  check "LV32f the re-run over the publisher's own notes succeeds" PASS
else
  check "LV32f the re-run over the publisher's own notes succeeds" FAIL
fi
eq "LV32b a re-run finds every part in the publisher's own notes and posts nothing new" \
  "$(grep -c -- '--method POST' "$WORK/live/foreign/calls" || true)" "6"

mkdir -p "$WORK/gh/bin" "$WORK/gh/fixture" "$WORK/gh/listing" "$WORK/gh/fail" "$WORK/gh/reject" "$WORK/gh/empty" "$WORK/gh/inventory"
RM_HEX_C="$(printf '%064d' 0 | tr 0 c)"
RM_HEX_D="$(printf '%064d' 0 | tr 0 d)"
RM_HEX_E="$(printf '%064d' 0 | tr 0 e)"
RM_HEX_F="$(printf '%064d' 0 | tr 0 f)"
GH_A1="<!-- zensu-review:v1:$RM_HEX_A:$RM_HEX_B:abcdef0:2:part=1/2 -->"
GH_A2="<!-- zensu-review:v1:$RM_HEX_A:$RM_HEX_B:abcdef0:2:part=2/2 -->"
GH_B1="<!-- zensu-review:v1:$RM_HEX_C:$RM_HEX_D:1234567:1:part=1/1 -->"
GH_C1="<!-- zensu-review:v1:$RM_HEX_E:$RM_HEX_F:7654321:1:part=1/1 -->"
A1="$GH_A1" A2="$GH_A2" B1="$GH_B1" C1="$GH_C1" DIR="$WORK/gh" node -e '
  var fs=require("fs"),e=process.env;
  function review(n,body){return {id:"PRR_"+n,author:{login:"reviewer-"+n},body:body,url:"https://github.test/acme/widget/pull/42#pullrequestreview-"+n};}
  function page(nodes,next,cursor,previous){return JSON.stringify({data:{repository:{pullRequest:{reviews:{nodes:nodes,pageInfo:{startCursor:nodes.length?"start-"+nodes[0].id:null,hasNextPage:next,endCursor:cursor,hasPreviousPage:previous}}}}}});}
  var first=[review(1,e.A1+"\n\nFirst part of the review."),review(2,e.A2+"\n\nSecond part of the review."),review(3,"Looks good to me."),review(4,e.C1+"\n\nA review only the first page carries.")];
  fs.writeFileSync(e.DIR+"/page1.json",page(first,true,"cursor-4",false));
  fs.writeFileSync(e.DIR+"/last.json",page(first,false,"cursor-4",false));
  fs.writeFileSync(e.DIR+"/nocursor.json",page(first,true,null,false));
  fs.writeFileSync(e.DIR+"/blankcursor.json",page(first,true,"",false));
  fs.writeFileSync(e.DIR+"/middle.json",page([review(7,"A review between the two pages.")],true,"cursor-7",true));
  fs.writeFileSync(e.DIR+"/page2.json",page([review(5,e.A1+"\n\nThe first part, posted again."),review(6,e.B1+"\n\nA review only the second page carries.")],false,"cursor-6",true));
  fs.writeFileSync(e.DIR+"/empty.json",page([],false,null,false));'
RM_MODEL="$PLUGIN_DIR/tests/structure/lib-fake-gh-graphql.js"
{
  printf '%s\n' '#!/bin/bash' 'set -u' "printf '%s\\n' \"\$*\" >> \"\$FAKE_DIR/calls\""
  printf 'exec node %q %q "$@"\n' "$RM_MODEL" "$WORK/gh"
} > "$WORK/gh/bin/gh"
chmod +x "$WORK/gh/bin/gh"
rm_pages() {
  FAKE_DIR="$WORK/gh/fixture" "$WORK/gh/bin/gh" "$@" 2>/dev/null | node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var doc;try{doc=JSON.parse(s);}catch(_){process.stdout.write("not one JSON document");return;}
      var pages=Array.isArray(doc)?doc:[doc];
      process.stdout.write((Array.isArray(doc)?pages.length+" page(s) ":"one document ")+pages.map(function(p){
        return p.data.repository.pullRequest.reviews.nodes.map(function(r){return r.id+(r.body===undefined?"":"+body");}).join(",");
      }).join(" / "));
    });' 2>/dev/null
}
rm_probe() {
  rm_pages "$@" -f owner=acme -f name=widget -F num=42
}
rm_run() {
  local err rc=0
  err="$(FAKE_DIR="$WORK/gh/fixture" "$WORK/gh/bin/gh" "$@" 2>&1 >/dev/null)" || rc=$?
  printf 'rc=%s %s' "$rc" "$err"
}
rm_refusal() {
  rm_run api graphql --paginate --slurp -f "$1" -f owner=acme -f name=widget -F num=42
}
rm_unmodelled() {
  local got
  got="$(rm_run "$@")"
  if [ "$got" = "rc=2 fake gh: unmodelled call: $*" ]; then printf 'named'; else printf '%s' "$got"; fi
}
rm_query() {
  local connection="$2"
  case "$connection" in
    ("("*) connection="(first:100,${connection#\(}" ;;
    (*) connection="(first:100)$connection" ;;
  esac
  printf 'query=query($owner:String!,$name:String!,$num:Int!%s){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews%s}}}' "$1" "$connection"
}
rm_connection() {
  printf 'query=query($owner:String!,$name:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(%s){nodes{id}pageInfo{hasNextPage endCursor}}}}}' "$1"
}
GH_PAGE1="PRR_1,PRR_2,PRR_3,PRR_4"
GH_BOTH="2 page(s) $GH_PAGE1 / PRR_5,PRR_6"
GH_BODIES="PRR_1+body,PRR_2+body,PRR_3+body,PRR_4+body"
RM_PAGING_QUERY="$(rm_query ',$endCursor:String' '(after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}')"
GH_PAGED="$(FAKE_DIR="$WORK/gh/fixture" "$WORK/gh/bin/gh" api graphql --paginate --slurp -f "$(rm_query ',$endCursor:String' '(after:$endCursor){nodes{id body url}pageInfo{hasNextPage endCursor}}')" -f owner=acme -f name=widget -F num=42 2>/dev/null)"
eq "RM1 the fake gh slurps two review pages for a query that pages: a cross-page duplicate, a later part, a marker only each page carries, an unmarked review and each page's pageInfo" \
  "$(printf '%s' "$GH_PAGED" | A1="$GH_A1" A2="$GH_A2" B1="$GH_B1" C1="$GH_C1" node -e '
    var e=process.env,s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var pages;try{pages=JSON.parse(s);}catch(_){process.stdout.write("not one JSON document");return;}
      function count(test){return pages.map(function(p){return p.data.repository.pullRequest.reviews.nodes.filter(function(r){return test(r.body);}).length;}).join("+");}
      function marker(m){return count(function(b){return b.indexOf(m)>=0;});}
      process.stdout.write(pages.length+" pages | A part 1/2: "+marker(e.A1)+" | A part 2/2: "+marker(e.A2)+" | B part 1/1: "+marker(e.B1)
        +" | C part 1/1: "+marker(e.C1)+" | unmarked: "+count(function(b){return b.indexOf("zensu-review:")<0;})
        +" | pageInfo: "+pages.map(function(p){var i=p.data.repository.pullRequest.reviews.pageInfo;return i.hasNextPage+" "+i.endCursor;}).join(" + "));
    });' 2>/dev/null)" \
  "2 pages | A part 1/2: 1+1 | A part 2/2: 1+0 | B part 1/1: 0+1 | C part 1/1: 1+0 | unmarked: 1+0 | pageInfo: true cursor-4 + false cursor-6"
eq "RM1b the fake gh pages a query whose pageInfo selects other fields beside hasNextPage and endCursor, as gh 2.101.0 does" \
  "$(rm_probe api graphql --paginate --slurp -f "$(rm_query ',$endCursor:String' '(after:$endCursor){nodes{id}pageInfo{startCursor hasNextPage endCursor hasPreviousPage}}')")" "$GH_BOTH"
eq "RM1c the fake gh takes a flag before the endpoint, as gh 2.101.0 does" \
  "$(rm_probe api --hostname github.com graphql --paginate --slurp -f "$RM_PAGING_QUERY")" "$GH_BOTH"
GH_MISS="no cursor fields: $(rm_probe api graphql --paginate --slurp -f "$(rm_query '' '{nodes{id}}')")"
GH_MISS="$GH_MISS | no pageInfo: $(rm_probe api graphql --paginate --slurp -f "$(rm_query ',$endCursor:String' '(after:$endCursor){nodes{id}}')")"
GH_MISS="$GH_MISS | no endCursor: $(rm_probe api graphql --paginate --slurp -f "$(rm_query ',$endCursor:String' '(after:$endCursor){nodes{id}pageInfo{hasNextPage}}')")"
GH_MISS="$GH_MISS | no hasNextPage: $(rm_probe api graphql --paginate --slurp -f "$(rm_query ',$endCursor:String' '(after:$endCursor){nodes{id}pageInfo{endCursor}}')")"
GH_MISS="$GH_MISS | no --paginate: $(rm_probe api graphql -f "$RM_PAGING_QUERY")"
eq "RM2 the fake gh serves only the first page to a query that misses one paging term and to a call without --paginate, as gh 2.101.0 does" "$GH_MISS" \
  "no cursor fields: 1 page(s) $GH_PAGE1 | no pageInfo: 1 page(s) $GH_PAGE1 | no endCursor: 1 page(s) $GH_PAGE1 | no hasNextPage: 1 page(s) $GH_PAGE1 | no --paginate: one document $GH_PAGE1"
GH_REFUSED="$(rm_refusal "$(rm_query ',$endCursor:String' '{nodes{id}pageInfo{hasNextPage endCursor}}')")"
GH_REFUSED="$GH_REFUSED | $(rm_refusal "$(rm_query '' '(after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}')")"
GH_REFUSED="$GH_REFUSED | $(rm_refusal "$(rm_query ',$endCursor:String!' '(after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}')")"
eq "RM2b the fake gh refuses a cursor variable that is declared but unused, used but undeclared or declared String!, with the message of gh 2.101.0" "$GH_REFUSED" \
  'rc=1 gh: Variable $endCursor is declared by anonymous query but not used | rc=1 gh: Variable $endCursor is used by anonymous query but not declared | rc=1 gh: Variable $endCursor of type String! was provided invalid value'
GH_SELECTED="$(rm_probe api graphql -f "$(rm_query '' '{nodes{id url}}')")"
GH_SELECTED="$GH_SELECTED | $(rm_probe api graphql -f "$(rm_query '' '{nodes{id body url}}')")"
GH_SELECTED="$GH_SELECTED | $(rm_probe api graphql -f "$(rm_query '' '{nodes{id author{login} body}}')")"
GH_SELECTED="$GH_SELECTED | $(rm_probe api graphql -f "$(rm_query '' '{nodes{id author{login}body}}')")"
eq "RM2c the fake gh serves a review body only when the query selects it, also after a nested selection, spaced or compact" "$GH_SELECTED" \
  "one document $GH_PAGE1 | one document $GH_BODIES | one document $GH_BODIES | one document $GH_BODIES"
GH_UNMODELLED="$(rm_unmodelled api repos/acme/widget/pulls/42/reviews -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42)"
GH_UNMODELLED="$GH_UNMODELLED | $(rm_unmodelled api graphql -f 'query=query Listing($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100){nodes{id}}}}}' -f owner=acme -f name=widget -F num=42)"
GH_UNMODELLED="$GH_UNMODELLED | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_query '' '{nodes{id}pageInfo{hasNextPage endCursor}}')" -f owner=acme -f name=widget -F num=42)"
eq "RM2d the fake gh names a call it does not model on stderr and exits 2: another endpoint, a named operation and a paging query that never passes its cursor on" "$GH_UNMODELLED" \
  "named | named | named"
GH_NUM="-F num: $(rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY")"
GH_NUM="$GH_NUM | -f num: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -f num=42)"
GH_NUM="$GH_NUM | no num: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget)"
eq "RM2e the fake gh serves a query that declares \$num as Int! for -F num and refuses a num sent with -f and a call without num, with the message of gh 2.101.0" "$GH_NUM" \
  "-F num: $GH_BOTH"' | -f num: rc=1 gh: Variable $num of type Int! was provided invalid value | no num: rc=1 gh: Variable $num of type Int! was provided invalid value'
GH_VARS="$(rm_refusal 'query=query($owner:String!,$login:String!,$name:String!,$num:Int!,$endCursor:String){repository(owner:$login,name:$name){pullRequest(number:$num){reviews(first:100,after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}}}}')"
GH_VARS="$GH_VARS | $(rm_refusal 'query=query($name:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100,after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}}}}')"
GH_VARS="$GH_VARS | $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -F num=42)"
eq "RM2f the fake gh applies the declared, used and value rules to every variable: \$owner declared but unused, \$owner used but undeclared, \$name declared String! without a value" "$GH_VARS" \
  'rc=1 gh: Variable $owner is declared by anonymous query but not used | rc=1 gh: Variable $owner is used by anonymous query but not declared | rc=1 gh: Variable $name of type String! was provided invalid value'
GH_PHASES="$(rm_refusal "$(rm_query ',$zeta:String,$endCursor:String' '(after:$endCursor,before:$alpha){nodes{id}pageInfo{hasNextPage endCursor}}')")"
GH_PHASES="$GH_PHASES | $(rm_refusal "$(rm_query ',$zeta:String,$endCursor:String!' '(after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}')")"
GH_PHASES="$GH_PHASES | $(rm_run api graphql --paginate --slurp -f 'query=query($num:Int!,$name:String!,$owner:String!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100,after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}}}}' -f owner=acme)"
eq "RM2g the fake gh reports every problem of one phase on its own line, the unused declaration first, and checks values only once the declarations hold, in declaration order, as gh 2.101.0 does" "$GH_PHASES" \
  "$(printf '%s\n%s | %s | %s\n%s' 'rc=1 gh: Variable $zeta is declared by anonymous query but not used' 'Variable $alpha is used by anonymous query but not declared' 'rc=1 gh: Variable $zeta is declared by anonymous query but not used' 'rc=1 gh: Variable $num of type Int! was provided invalid value' 'Variable $name of type String! was provided invalid value')"
GH_FOLLOW="first page ends: $(FAKE_PAGES='last.json page2.json' rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY")"
GH_FOLLOW="$GH_FOLLOW | null cursor: $(FAKE_PAGES='nocursor.json page2.json' rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY")"
GH_FOLLOW="$GH_FOLLOW | empty cursor: $(FAKE_PAGES='blankcursor.json page2.json' rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY")"
GH_FOLLOW="$GH_FOLLOW | three pages: $(FAKE_PAGES='page1.json middle.json page2.json' rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY")"
GH_FOLLOW="$GH_FOLLOW | own cursor: $(rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f endCursor=cursor-4)"
eq "RM2h the fake gh asks for another page only while the served page carries hasNextPage true and a non-empty endCursor, and serves the fixture page after that cursor" "$GH_FOLLOW" \
  "first page ends: 1 page(s) $GH_PAGE1 | null cursor: 1 page(s) $GH_PAGE1 | empty cursor: 1 page(s) $GH_PAGE1 | three pages: 3 page(s) $GH_PAGE1 / PRR_7 / PRR_5,PRR_6 | own cursor: 1 page(s) PRR_5,PRR_6"
GH_SHAPE="$(rm_unmodelled pr graphql -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql --paginate -f)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 --hostname)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 -f =acme)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql -f "$RM_PAGING_QUERY" -F "owner=@$WORK/gh/owner.txt" -f name=widget -F num=42)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql --jq .data -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql graphql -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42)"
GH_SHAPE="$GH_SHAPE | $(rm_unmodelled api graphql --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42)"
eq "RM2i the fake gh names a call shape it does not model and exits 2: another subcommand, a field flag or --hostname without its value, a field without a name, an @file value, an unknown flag, a second endpoint and --slurp without --paginate" "$GH_SHAPE" \
  "named | named | named | named | named | named | named | named"
GH_HEADER="$(rm_unmodelled api graphql --paginate --slurp -f "$(rm_query ',$endCursor:String="cursor-4"' '(after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}')" -f owner=acme -f name=widget -F num=42)"
GH_HEADER="$GH_HEADER | $(rm_unmodelled api graphql -f "$(rm_query ',$ids:[String]' '{nodes{id}}')" -f owner=acme -f name=widget -F num=42)"
GH_HEADER="$GH_HEADER | $(rm_unmodelled api graphql -f "$(rm_query ',$first:Boolean' '{nodes{id}}')" -f owner=acme -f name=widget -F num=42)"
eq "RM2j the fake gh names a query header it does not model and exits 2: a default value, a list type and a Boolean variable" "$GH_HEADER" \
  "named | named | named"
GH_PATH="$(rm_unmodelled api graphql -f 'query=query{viewer{login}}')"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f 'query=query($name:String!,$num:Int!){repository(owner:"acme",name:$name){pullRequest(number:$num){reviews(first:100){nodes{id}}}}}' -f name=widget -F num=42)"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f 'query=query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100){nodes{id}}}}}' -f owner=acme -f name=widget -F num=42)"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f 'query=query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num,id:$num){reviews(first:100){nodes{id}}}}}' -f owner=acme -f name=widget -F num=42)"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f "$(rm_query '' '{nodes{id}}title')" -f owner=acme -f name=widget -F num=42)"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f 'query=query($owner:String,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100){nodes{id}}}}}' -f owner=acme -f name=widget -F num=42)"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f 'query=query($owner:String!,$name:Int!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100){nodes{id}}}}}' -f owner=acme -F name=7 -F num=42)"
GH_PATH="$GH_PATH | $(rm_unmodelled api graphql -f 'query=query($owner:String!,$name:String!,$num:String!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100){nodes{id}}}}}' -f owner=acme -f name=widget -f num=42)"
eq "RM2k the fake gh names a query outside its repository path and exits 2: no repository path, a literal owner, a repeated owner, another pull request argument, a field beside reviews, and an owner, name or number variable of another type" "$GH_PATH" \
  "named | named | named | named | named | named | named | named"
GH_SELECT="$(rm_unmodelled api graphql -f "$(rm_query '' '{totalCount nodes{id}}')" -f owner=acme -f name=widget -F num=42)"
GH_SELECT="$GH_SELECT | $(rm_unmodelled api graphql -f "$(rm_query '' '{nodes{id}nodes{body}}')" -f owner=acme -f name=widget -F num=42)"
GH_SELECT="$GH_SELECT | $(rm_unmodelled api graphql -f "$(rm_query '' '{nodes}')" -f owner=acme -f name=widget -F num=42)"
GH_SELECT="$GH_SELECT | $(rm_unmodelled api graphql -f "$(rm_query '' '{nodes{id text:body}}')" -f owner=acme -f name=widget -F num=42)"
GH_SELECT="$GH_SELECT | $(rm_unmodelled api graphql -f "$(rm_query '' '{nodes{id ... on PullRequestReview{body}}}')" -f owner=acme -f name=widget -F num=42)"
GH_SELECT="$GH_SELECT | $(rm_unmodelled api graphql -f "$(rm_query '' '{nodes{id title}}')" -f owner=acme -f name=widget -F num=42)"
GH_SELECT="$GH_SELECT | $(rm_unmodelled api graphql -f 'query=query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100){nodes{id' -f owner=acme -f name=widget -F num=42)"
eq "RM2l the fake gh names a selection it does not model and exits 2: a reviews field other than nodes and pageInfo, a repeated field, nodes without a selection, an alias, a fragment, a field the fixture lacks and an unterminated selection" "$GH_SELECT" \
  "named | named | named | named | named | named | named"
GH_PAGING="$(rm_unmodelled api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 -f endCursor=cursor-9)"
GH_PAGING="$GH_PAGING | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_query ',$endCursor:Int' '(after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}')" -f owner=acme -f name=widget -F num=42)"
eq "RM2m the fake gh names a paging call it does not model and exits 2: an own cursor the fixture lacks and a cursor variable that cannot take the next page's endCursor" "$GH_PAGING" \
  "named | named"
GH_TYPED="5: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 -F endCursor=5)"
GH_TYPED="$GH_TYPED | true: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 -F endCursor=true)"
GH_TYPED="$GH_TYPED | false: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 -F endCursor=false)"
GH_TYPED="$GH_TYPED | null: $(rm_probe api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -F endCursor=null)"
eq "RM2n the fake gh types -F true, false, null and integers as gh 2.101.0 does: a String variable refuses an integer, true and false and takes null" "$GH_TYPED" \
  '5: rc=1 gh: Variable $endCursor of type String was provided invalid value | true: rc=1 gh: Variable $endCursor of type String was provided invalid value | false: rc=1 gh: Variable $endCursor of type String was provided invalid value | null: '"$GH_BOTH"
GH_INT="$(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=-2147483648)"
GH_INT="$GH_INT | $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=2147483648)"
GH_INT="$GH_INT | $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=9223372036854775807)"
GH_INT="$GH_INT | $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=9223372036854775808)"
eq "RM2o the fake gh types an -F integer up to the 64-bit limit as a number that an Int takes past 32 bits and a larger one as a string, as gh 2.101.0 and GitHub do" "$GH_INT" \
  'rc=1 gh: Could not resolve to a PullRequest with the number of -2147483648. | rc=1 gh: Could not resolve to a PullRequest with the number of 2147483648. | rc=1 gh: Could not resolve to a PullRequest with the number of 9223372036854775807. | rc=1 gh: Variable $num of type Int! was provided invalid value'
GH_WHO="swapped: $(rm_refusal 'query=query($owner:String!,$name:String!,$num:Int!,$endCursor:String){repository(owner:$name,name:$owner){pullRequest(number:$num){reviews(first:100,after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}}}}')"
GH_WHO="$GH_WHO | other owner: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=octo -f name=widget -F num=42)"
GH_WHO="$GH_WHO | other name: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=gadget -F num=42)"
GH_WHO="$GH_WHO | other number: $(rm_run api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=43)"
GH_WHO="$GH_WHO | renamed: $(rm_pages api graphql --paginate --slurp -f 'query=query($login:String!,$repo:String!,$number:Int!,$endCursor:String){repository(owner:$login,name:$repo){pullRequest(number:$number){reviews(first:100,after:$endCursor){nodes{id}pageInfo{hasNextPage endCursor}}}}}' -f login=acme -f repo=widget -F number=42 -f owner=octo -f name=gadget -F num=43)"
eq "RM2p the fake gh resolves the pull request from the variables the query binds to repository and pullRequest and fails for another one with the message of GitHub: a swapped owner and name, another owner, name or number, and renamed variables beside unbound wrong ones" "$GH_WHO" \
  "swapped: rc=1 gh: Could not resolve to a Repository with the name 'widget/acme'. | other owner: rc=1 gh: Could not resolve to a Repository with the name 'octo/widget'. | other name: rc=1 gh: Could not resolve to a Repository with the name 'acme/gadget'. | other number: rc=1 gh: Could not resolve to a PullRequest with the number of 43. | renamed: $GH_BOTH"
GH_ALONE="$(FAKE_DIR="$WORK/gh/fixture" "$WORK/gh/bin/gh" api graphql --paginate -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 2>/dev/null)"
GH_SLURPED="$(FAKE_DIR="$WORK/gh/fixture" "$WORK/gh/bin/gh" api graphql --paginate --slurp -f "$RM_PAGING_QUERY" -f owner=acme -f name=widget -F num=42 2>/dev/null)"
eq "RM2q the fake gh prints the pages back to back for --paginate without --slurp, as gh 2.101.0 does" \
  "$(ALONE="$GH_ALONE" SLURPED="$GH_SLURPED" node -e '
    var e=process.env,pages;try{pages=JSON.parse(e.SLURPED);}catch(_){pages=[];}
    process.stdout.write(pages.length+" pages, back to back: "+(pages.map(function(p){return JSON.stringify(p);}).join("")===e.ALONE));' 2>/dev/null)" \
  "2 pages, back to back: true"
GH_PAGE_SIZE="no first: $(rm_refusal "$(rm_connection 'after:$endCursor')")"
GH_PAGE_SIZE="$GH_PAGE_SIZE | first and last: $(rm_refusal "$(rm_connection 'first:5,last:5,after:$endCursor')")"
GH_PAGE_SIZE="$GH_PAGE_SIZE | first -1: $(rm_refusal "$(rm_connection 'first:-1,after:$endCursor')")"
GH_PAGE_SIZE="$GH_PAGE_SIZE | first 101: $(rm_refusal "$(rm_connection 'first:101,after:$endCursor')")"
GH_PAGE_SIZE="$GH_PAGE_SIZE | no first, other number: $(rm_run api graphql --paginate --slurp -f "$(rm_connection 'after:$endCursor')" -f owner=acme -f name=widget -F num=43)"
GH_PAGE_SIZE="$GH_PAGE_SIZE | no first, no num: $(rm_run api graphql --paginate --slurp -f "$(rm_connection 'after:$endCursor')" -f owner=acme -f name=widget)"
GH_PAGE_SIZE="$GH_PAGE_SIZE | first 0, no reviews: $(FAKE_PAGES=empty.json rm_refusal "$(rm_connection 'first:0,after:$endCursor')")"
eq "RM2r the fake gh checks the reviews connection after the values and the pull request and fails like GitHub, as measured with gh 2.101.0: no first or last, both, a first below zero or above 100, and first 0" "$GH_PAGE_SIZE" \
  'no first: rc=1 gh: You must provide a `first` or `last` value to properly paginate the `reviews` connection. | first and last: rc=1 gh: Passing both `first` and `last` to paginate the `reviews` connection is not supported. | first -1: rc=1 gh: `first` on the `reviews` connection cannot be less than zero. | first 101: rc=1 gh: Requesting 101 records on the `reviews` connection exceeds the `first` limit of 100 records. | no first, other number: rc=1 gh: Could not resolve to a PullRequest with the number of 43. | no first, no num: rc=1 gh: Variable $num of type Int! was provided invalid value | first 0, no reviews: rc=0 '
GH_CONNECTION="$(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection 'last:5,after:$endCursor')" -f owner=acme -f name=widget -F num=42)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection 'first:$num,after:$endCursor')" -f owner=acme -f name=widget -F num=42)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection 'first:100,after:$endCursor,states:$endCursor')" -f owner=acme -f name=widget -F num=42)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection '')" -f owner=acme -f name=widget -F num=42)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection 'first:100,first:100,after:$endCursor')" -f owner=acme -f name=widget -F num=42)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection 'first:2,after:$endCursor')" -f owner=acme -f name=widget -F num=42)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql -f 'query=query($owner:String!,$name:String!,$num:Int!,$before:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100,before:$before){nodes{id}pageInfo{hasNextPage endCursor}}}}}' -f owner=acme -f name=widget -F num=42 -f before=cursor-6)"
GH_CONNECTION="$GH_CONNECTION | $(rm_unmodelled api graphql --paginate --slurp -f "$(rm_connection 'first:100,after:$endCursor,before:$endCursor')" -f owner=acme -f name=widget -F num=42)"
eq "RM2s the fake gh names a reviews argument it does not model and exits 2: last alone, a variable first, another argument, empty arguments, a repeated argument, a first below the size of a served page and a before cursor with a value on the first or a later page" "$GH_CONNECTION" \
  "named | named | named | named | named | named | named | named"
GH_OUT="$(FAKE_DIR="$WORK/gh/listing" PATH="$WORK/gh/bin:$PATH" bash "$LIB" --review-markers --provider github --repo-id acme/widget 42 2>/dev/null)"
GH_RC=$?
if [ "$GH_RC" -eq 0 ]; then
  check "RM3 --review-markers on GitHub succeeds against a gh that serves the reviews in two pages" PASS
else
  check "RM3 --review-markers on GitHub succeeds against a gh that serves the reviews in two pages (rc=$GH_RC)" FAIL
fi
eq "RM4 --review-markers on GitHub lists each distinct first-part marker of both pages once, one per line" \
  "$(printf '%s\n' "$GH_OUT" | LC_ALL=C sort)" "$(printf '%s\n' "$GH_A1" "$GH_B1" "$GH_C1" | LC_ALL=C sort)"
GH_CALLS="$(cat "$WORK/gh/listing/calls" 2>/dev/null)"
has "RM5 the GitHub listing passes --paginate to gh" " $GH_CALLS " " --paginate "
has "RM5b the GitHub listing passes --slurp to gh" " $GH_CALLS " " --slurp "
has "RM6a the GitHub listing passes the pull request number as the typed field -F num" " $GH_CALLS " " -F num=42 "
has "RM6b the GitHub listing sends the owner as a raw -f string" " $GH_CALLS " " -f owner=acme "
has "RM6c the GitHub listing sends the repository name as a raw -f string" " $GH_CALLS " " -f name=widget "
GH_FAIL_ERR="$(FAKE_REVIEWS=fail FAKE_DIR="$WORK/gh/fail" PATH="$WORK/gh/bin:$PATH" \
  bash "$LIB" --review-markers --provider github --repo-id acme/widget 42 2>&1 >/dev/null)"
GH_FAIL_RC=$?
if [ "$GH_FAIL_RC" -ne 0 ]; then
  check "RM7 a failed GitHub listing makes --review-markers exit non-zero" PASS
else
  check "RM7 a failed GitHub listing makes --review-markers exit non-zero" FAIL
fi
has "RM8 the failed GitHub listing is reported under the review-markers inventory label" "$GH_FAIL_ERR" "zensu-vcs: review-markers inventory (gh api graphql reviews) failed (rc=1): "
GH_REJECT_RC=0
FAKE_DIR="$WORK/gh/reject" PATH="$WORK/gh/bin:$PATH" bash "$LIB" --review-markers --provider github --repo-id acme/widget "@$WORK/gh/num" >/dev/null 2>&1 || GH_REJECT_RC=$?
if [ "$GH_REJECT_RC" -ne 0 ] && [ ! -e "$WORK/gh/reject/calls" ]; then
  check "RM9 a non-numeric pull request id makes --review-markers exit non-zero before gh runs" PASS
else
  check "RM9 a non-numeric pull request id makes --review-markers exit non-zero before gh runs (rc=$GH_REJECT_RC)" FAIL
fi
GH_EMPTY_RC=0
FAKE_PAGES=empty.json FAKE_DIR="$WORK/gh/empty" PATH="$WORK/gh/bin:$PATH" bash "$LIB" --review-markers --provider github --repo-id acme/widget 42 >"$WORK/gh/empty/stdout" 2>/dev/null || GH_EMPTY_RC=$?
if [ "$GH_EMPTY_RC" -eq 0 ] && [ -s "$WORK/gh/empty/calls" ] && [ -f "$WORK/gh/empty/stdout" ] && [ ! -s "$WORK/gh/empty/stdout" ]; then
  check "RM10 --review-markers on GitHub exits 0 and prints nothing for a pull request without reviews" PASS
else
  check "RM10 --review-markers on GitHub exits 0 and prints nothing for a pull request without reviews (rc=$GH_EMPTY_RC)" FAIL
fi
GH_INVENTORY="$(FAKE_DIR="$WORK/gh/inventory" PATH="$WORK/gh/bin:$PATH" "$BASH_ABS" -c 'source "$1"; _zensu_vcs_review_fetch_inventory github acme/widget 42 "reconcile inventory" github.com' _ "$LIB" 2>/dev/null)"
eq "RM11 the GitHub inventory fetch that --reconcile-review shares selects id, body and url: every review the fake serves on both pages carries all three as strings" \
  "$(printf '%s' "$GH_INVENTORY" | node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var pages;try{pages=JSON.parse(s);}catch(_){process.stdout.write("not one JSON document");return;}
      var nodes=[].concat.apply([],pages.map(function(p){return p.data.repository.pullRequest.reviews.nodes;}));
      process.stdout.write(pages.length+" pages | "+nodes.length+" reviews | "+nodes.filter(function(r){return typeof r.id==="string"&&typeof r.body==="string"&&typeof r.url==="string";}).length+" with id, body and url");
    });' 2>/dev/null)" \
  "2 pages | 6 reviews | 6 with id, body and url"

rm -rf "$WORK"

echo "----"
echo "test-vcs-publish: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
