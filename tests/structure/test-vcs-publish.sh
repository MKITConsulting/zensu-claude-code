#!/bin/bash
set -u

# Hermetic structure test for the VCS driver's team-review publish ops (Phase 3):
# --scout-pr / --fetch-pr-ref / --diff-refs / --post-review. No gh/glab execution —
# every op is a pure argv-builder (dry-printed under ZENSU_VCS_TEST=1 ZENSU_VCS_PRINT_ARGV=1)
# plus node normalizers fed fixture JSON. The GitLab publish path is a LOOP (spec §7:
# summary note + N inline discussions + position object + idempotency marker); its dry
# output is the ordered argv sequence, each POST followed by its JSON request line, asserted
# below.

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
if [ "${1:-}" = api ] && [ "${2:-}" = --paginate ]; then
  FAKE_DIR="$FAKE_DIR" KIND="${path##*/}" node -e '
    var fs=require("fs"),f=process.env.FAKE_DIR+"/posted",a=[];
    if(fs.existsSync(f))fs.readFileSync(f,"utf8").split("\n").forEach(function(l){if(!l)return;var r=JSON.parse(l);if(r.kind===process.env.KIND)a.push({id:a.length+1,body:r.request.body});});
    process.stdout.write(JSON.stringify(a));'
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

rm -rf "$WORK"

echo "----"
echo "test-vcs-publish: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
