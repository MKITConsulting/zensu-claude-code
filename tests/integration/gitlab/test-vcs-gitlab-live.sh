#!/bin/bash
set -u

SUITE=test-vcs-gitlab-live
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="${ZENSU_GITLAB_IT_LIB:-$PLUGIN_DIR/hooks/lib/zensu-vcs.sh}"
STATE="$ZENSU_GITLAB_IT_STATE"
GLAB_BIN="${ZENSU_GITLAB_IT_GLAB:-}"

refuse() {
  printf '%s: not configured: %s\n' "$SUITE" "$*" >&2
  exit 2
}

[ -f "$LIB" ] || refuse "driver $LIB is missing"
[ -n "$GLAB_BIN" ] && [ -x "$GLAB_BIN" ] || refuse 'ZENSU_GITLAB_IT_GLAB must name an executable glab binary'
[ -f "$STATE/url" ] && [ -f "$STATE/header" ] && [ -f "$STATE/token" ] \
  || refuse "no GitLab state in $STATE; run gitlab-up.sh first"
for tool in node curl git; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is not installed"
done

URL="$(cat "$STATE/url")"
SCHEME="${URL%%://*}"
HOSTPORT="${URL#*://}"

PASS=0
FAIL=0
XFAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
eq() {
  local l="$1" g="$2" w="$3" detail="${4:-}"
  if [ "$g" = "$w" ]; then
    check "$l" PASS
  else
    check "$l (got '$g' want '$w')" FAIL
    [ -n "$detail" ] && [ -f "$detail" ] && tail -n 20 "$detail" | sed 's/^/        /'
  fi
  return 0
}
has() { local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l" PASS ;; *) check "$l (missing '$n')" FAIL ;; esac; }
xeq() {
  local l="$1" g="$2" w="$3" sig="$4" bug="$5"
  if [ "$g" = "$w" ]; then
    printf '  XPASS %s (known bug no longer reproduces: %s; turn this check into eq)\n' "$l" "$bug"
    FAIL=$((FAIL+1))
  elif [ "$g" = "$sig" ]; then
    printf "  XFAIL %s (known bug: %s; got '%s' want '%s')\n" "$l" "$bug" "$g" "$w"
    XFAIL=$((XFAIL+1))
  else
    check "$l (got '$g', neither the fixed result '$w' nor the known bug's '$sig')" FAIL
  fi
  return 0
}
plus() {
  case "$1" in
    (''|*[!0-9]*) printf '<not a count: %s>' "$1" ;;
    (*) printf '%s' "$(( $1 + $2 ))" ;;
  esac
}

finish() {
  echo "----"
  echo "$SUITE: $PASS PASS / $FAIL FAIL / $XFAIL XFAIL"
  [ "$FAIL" -eq 0 ] && exit 0
  exit 1
}
abort() {
  check "$1" FAIL
  [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -n 20 | sed 's/^/        /'
  finish
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zensu-gitlab-live.XXXXXX")"
PROJECT_ID=""

api() {
  local method="$1" path="$2"
  if [ $# -ge 3 ]; then
    printf '%s' "$3" | curl -sS --fail-with-body --max-time 60 -X "$method" -H @"$STATE/header" \
      -H 'Content-Type: application/json' --data-binary @- "$URL/api/v4/$path"
  else
    curl -sS --fail-with-body --max-time 60 -X "$method" -H @"$STATE/header" "$URL/api/v4/$path"
  fi
}

json() {
  EXPR="$1" ARG="${2:-}" node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let value;
      try {
        value = new Function("d", `return (${process.env.EXPR});`)(JSON.parse(raw));
      } catch (error) {
        process.stdout.write("<error>");
        return;
      }
      if (value === undefined) process.stdout.write("<absent>");
      else process.stdout.write(typeof value === "string" ? value : JSON.stringify(value));
    });
  '
}

cleanup() {
  if [ -n "$PROJECT_ID" ] && [ "${ZENSU_GITLAB_IT_KEEP:-0}" != 1 ]; then
    api DELETE "projects/$PROJECT_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/home/.config/glab-cli" "$WORK/repo"
ln -s "$GLAB_BIN" "$WORK/bin/glab"
(
  umask 077
  cat > "$WORK/home/.config/glab-cli/config.yml" <<YAML
check_update: false
hosts:
  "$HOSTPORT":
    api_protocol: $SCHEME
    api_host: "$HOSTPORT"
    git_protocol: $SCHEME
YAML
)

isolated() {
  (
    cd "$WORK/repo" || exit 97
    unset ZENSU_VCS_TEST ZENSU_VCS_PRINT_ARGV ZENSU_VCS_REMOTE GITLAB_URI GL_HOST GL_TOKEN OAUTH_TOKEN
    export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GLAB_CONFIG_DIR="$WORK/home/.config/glab-cli"
    export GITLAB_HOST="$HOSTPORT"
    GITLAB_TOKEN="$(cat "$STATE/token")"
    export GITLAB_TOKEN
    export PATH="$WORK/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
    "$@"
  )
}
vcs() { isolated bash "$LIB" "$@"; }

NAME="zensu-it-$(date +%s)-$(node -e 'process.stdout.write(require("crypto").randomBytes(3).toString("hex"))')"
RID="root%2F$NAME"
git -C "$WORK/repo" init -q || refuse "git init failed in $WORK/repo"
git -C "$WORK/repo" remote add origin "$URL/root/$NAME.git" || refuse 'git remote add failed'

RESOLVED_GLAB="$(isolated sh -c 'command -v glab')"
GLAB_VERSION="$("$GLAB_BIN" --version 2>/dev/null | head -n 1)"
echo "$SUITE against $URL with ${GLAB_VERSION:-an unknown glab}"
eq "GL1 the driver resolves glab to the binary under test" "$RESOLVED_GLAB" "$WORK/bin/glab"
WHOAMI="$(isolated glab api user 2>"$WORK/whoami.err")"
[ "$(printf '%s' "$WHOAMI" | json 'd.username')" = root ] \
  || abort "GL2 glab authenticates against $URL as root" "$WHOAMI$(cat "$WORK/whoami.err")"
check "GL2 glab authenticates against $URL as root" PASS

created="$(api POST projects "{\"name\":\"$NAME\",\"path\":\"$NAME\",\"initialize_with_readme\":true,\"default_branch\":\"main\",\"visibility\":\"private\"}" 2>&1)" \
  || abort "GL3 the seed project is created" "$created"
PROJECT_ID="$(printf '%s' "$created" | json 'd.id')"
printf '%s' "$PROJECT_ID" | grep -Eq '^[0-9]+$' || abort "GL3 the seed project is created" "$created"
check "GL3 the seed project is created" PASS

node -e '
  const fs = require("fs");
  const dir = process.argv[1];
  const text = (list) => `${list.join("\n")}\n`;
  const run = (prefix, from, to) => Array.from({ length: to - from + 1 }, (_, i) => `${prefix}${from + i}`);
  const aBase = [...run("line", 1, 9), "ctx", "ctx2", "ctx3", ...run("line", 13, 15)];
  const aHead = [...run("line", 1, 9), "added10", "ctx", "ctx2", "ctx3", ...run("line", 13, 15)];
  const bBase = ["keep1", "keep2", "keep3", "keep4", "removed5", "keep6", "keep7", "keep8"];
  const bHead = bBase.filter((line) => line !== "removed5");
  const oldBase = ["one", "two", "three", "four", "five", "six"];
  const newHead = ["one", "TWO", "three", "four", "five", "six"];
  fs.writeFileSync(`${dir}/base.json`, JSON.stringify({
    branch: "main",
    commit_message: "Seed the base files",
    actions: [
      { action: "create", file_path: "src/a.js", content: text(aBase) },
      { action: "create", file_path: "src/b.js", content: text(bBase) },
      { action: "create", file_path: "src/old.js", content: text(oldBase) },
    ],
  }));
  fs.writeFileSync(`${dir}/head.json`, JSON.stringify({
    branch: "feature",
    start_branch: "main",
    commit_message: "Add, remove and rename lines",
    actions: [
      { action: "update", file_path: "src/a.js", content: text(aHead) },
      { action: "update", file_path: "src/b.js", content: text(bHead) },
      { action: "move", previous_path: "src/old.js", file_path: "src/new.js", content: text(newHead) },
    ],
  }));
  fs.writeFileSync(`${dir}/threads.json`, JSON.stringify({
    branch: "threads",
    start_branch: "main",
    commit_message: "Add a file and remove a line",
    actions: [
      { action: "create", file_path: "src/c.js", content: text(["one", "two", "three"]) },
      { action: "update", file_path: "src/b.js", content: text(bBase.filter((line) => line !== "keep2")) },
    ],
  }));
' "$WORK"

base_commit="$(api POST "projects/$PROJECT_ID/repository/commits" "$(cat "$WORK/base.json")" 2>&1)" \
  || abort "GL4 the base and feature commits are created" "$base_commit"
head_commit="$(api POST "projects/$PROJECT_ID/repository/commits" "$(cat "$WORK/head.json")" 2>&1)" \
  || abort "GL4 the base and feature commits are created" "$head_commit"
HEAD_SHA="$(printf '%s' "$head_commit" | json 'd.id')"
printf '%s' "$HEAD_SHA" | grep -Eq '^[0-9a-f]{40}$' || abort "GL4 the base and feature commits are created" "$head_commit"
check "GL4 the base and feature commits are created" PASS

mr="$(api POST "projects/$PROJECT_ID/merge_requests" '{"source_branch":"feature","target_branch":"main","title":"Zensu live check","description":"Live check body.","labels":"zensu-live,area/vcs"}' 2>&1)" \
  || abort "GL5 the merge request is opened" "$mr"
IID="$(printf '%s' "$mr" | json 'd.iid')"
printf '%s' "$IID" | grep -Eq '^[0-9]+$' || abort "GL5 the merge request is opened" "$mr"
check "GL5 the merge request is opened" PASS

diff_ready() {
  local iid="$1" sha="$2" count="$3" refs files deadline
  deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    refs="$(api GET "projects/$PROJECT_ID/merge_requests/$iid" 2>/dev/null | json 'd.diff_refs && d.diff_refs.head_sha')"
    files="$(api GET "projects/$PROJECT_ID/merge_requests/$iid/diffs?per_page=100" 2>/dev/null | json 'd.length')"
    [ "$refs" = "$sha" ] && [ "$files" = "$count" ] && return 0
    sleep 2
  done
  return 1
}
diff_ready "$IID" "$HEAD_SHA" 3 || abort "GL6 GitLab computes the merge request diff within 180s"
check "GL6 GitLab computes the merge request diff within 180s" PASS

cat > "$WORK/review.json" <<JSON
{"commit_id":"$HEAD_SHA","event":"COMMENT","body":"Live review body.","comments":[{"path":"src/a.js","line":10,"side":"RIGHT","body":"added line note"},{"path":"src/b.js","line":5,"side":"LEFT","body":"removed line note"},{"path":"src/a.js","line":12,"side":"RIGHT","body":"context line note"},{"path":"src/new.js","line":3,"side":"RIGHT","body":"renamed file note"},{"path":"src/a.js","line":99,"side":"RIGHT","body":"outside the diff note"}]}
JSON
cat > "$WORK/reconcile.json" <<JSON
{"commit_id":"$HEAD_SHA","event":"COMMENT","body":"Reconcile summary.","comments":[{"path":"src/a.js","line":10,"side":"RIGHT","body":"reconcile added note"},{"path":"src/b.js","line":5,"side":"LEFT","body":"reconcile removed note"}]}
JSON

discussions() { api GET "projects/$PROJECT_ID/merge_requests/$IID/discussions?per_page=100"; }
notes() { api GET "projects/$PROJECT_ID/merge_requests/$IID/notes?per_page=100"; }

POSITION_OF='(() => {
  const hits = d.filter((x) => !x.individual_note && x.notes.length > 0 && x.notes[0].body.includes(process.env.ARG));
  if (hits.length !== 1) return `count=${hits.length}`;
  const note = hits[0].notes[0];
  const p = note.position;
  return p ? [note.type, p.position_type, p.old_path, p.new_path, p.old_line, p.new_line] : [note.type, null];
})()'
COUNT_OF='d.filter((x) => !x.individual_note && x.notes.length > 0 && x.notes[0].body.includes(process.env.ARG)).length'
FIRST_NOTE_ID='(() => {
  const hit = d.find((x) => !x.individual_note && x.notes.length > 0 && x.notes[0].body.includes(process.env.ARG));
  return hit ? String(hit.notes[0].id) : "<none>";
})()'
DISCUSSION_ID='(() => {
  const hit = d.find((x) => !x.individual_note && x.notes.length > 0 && x.notes[0].body.includes(process.env.ARG));
  return hit ? String(hit.id) : "<none>";
})()'
USER_NOTES='d.filter((n) => !n.system).length'
SUMMARY_COUNT='d.filter((n) => !n.system && n.body.includes(process.env.ARG)).length'
REVIEW_TEXTS="added line note|removed line note|context line note|renamed file note|outside the diff note"
REVIEW_COUNT='d.filter((x) => !x.individual_note && x.notes.length > 0 && process.env.ARG.split("|").some((t) => x.notes[0].body.includes(t))).length'
THREAD_LINES='d.map((t) => `${t.path}:${t.line}`).sort().join(" ")'

THREADS_BUG='the GitLab thread normalizer demands a boolean resolved on every note, and plain comments and system notes such as an approval carry none'
THREADS_SIG='rc=1; glab returned the discussions; the normalizer printed nothing'
POSTREVIEW_BUG='post-review looks for its raw marker in GitLab JSON, which escapes the angle brackets as unicode escapes'
LOCATE_BUG='locate-pr matches the no-merge-request message of glab case-sensitively, and this glab capitalizes it'

fetch_threads() {
  local iid="$1" expr="$2" arg="${3:-}" out rc raw
  out="$(vcs --fetch-threads --provider gitlab --repo-id "$RID" "$iid" 2>"$WORK/threads.err")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | json "$expr" "$arg"
    return 0
  fi
  raw="$(isolated glab api --paginate --output json "projects/$RID/merge_requests/$iid/discussions" 2>/dev/null)"
  if [ -z "$out" ] && [ "$(printf '%s' "$raw" | json 'Array.isArray(d) && d.length > 0')" = true ]; then
    printf 'rc=%s; glab returned the discussions; the normalizer printed nothing' "$rc"
  else
    printf 'rc=%s out=%s err=%s' "$rc" "$out" "$(head -c 300 "$WORK/threads.err")"
  fi
}

post_out="$(vcs --post-review --provider gitlab --repo-id "$RID" "$IID" "$WORK/review.json" 2>&1)"
post_rc=$?
eq "GL10 --post-review publishes the review" "$post_rc" "0"
[ "$post_rc" -eq 0 ] || printf '%s\n' "$post_out" | tail -n 20 | sed 's/^/        /'

D="$(discussions)"
N="$(notes)"
eq "GL11 GitLab stores exactly one summary note" "$(printf '%s' "$N" | json "$SUMMARY_COUNT" 'Live review body.')" "1"
eq "GL12 GitLab stores one discussion per review comment" "$(printf '%s' "$D" | json "$REVIEW_COUNT" "$REVIEW_TEXTS")" "5"
eq "GL13 an added line is stored as a diff note with new_line only" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'added line note')" '["DiffNote","text","src/a.js","src/a.js",null,10]'
eq "GL14 a removed line is stored as a diff note with old_line only" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'removed line note')" '["DiffNote","text","src/b.js","src/b.js",5,null]'
eq "GL15 an unchanged context line is stored as a diff note with both line numbers" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'context line note')" '["DiffNote","text","src/a.js","src/a.js",11,12]'
eq "GL16 a line of a renamed file is stored with its old and new path" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'renamed file note')" '["DiffNote","text","src/old.js","src/new.js",3,3]'
eq "GL17 an anchor outside the diff is stored as a discussion without a position" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'outside the diff note')" '["DiscussionNote",null]'
has "GL18 the positionless discussion names the path in its body" \
  "$(printf '%s' "$D" | json '(d.find((x) => !x.individual_note && x.notes[0].body.includes(process.env.ARG)) || { notes: [{ body: "" }] }).notes[0].body' 'outside the diff note')" \
  '`src/a.js`: outside the diff note'

eq "GL19 GitLab stores the summary as a plain note without a resolution state" \
  "$(printf '%s' "$D" | json 'd.some((x) => x.individual_note && x.notes.some((n) => !n.system && typeof n.resolved !== "boolean"))')" "true"
xeq "GL20 --fetch-threads lists the five unresolved review threads" \
  "$(fetch_threads "$IID" "$THREAD_LINES")" ":null src/a.js:10 src/a.js:12 src/b.js:5 src/new.js:3" "$THREADS_SIG" "$THREADS_BUG"

added_thread="$(printf '%s' "$D" | json "$DISCUSSION_ID" 'added line note')"
resolve_out="$(vcs --resolve-thread --provider gitlab --repo-id "$RID" --reply 'Fixed by the live check.' "$IID" "$added_thread" 2>&1)"
resolve_rc=$?
eq "GL21 --resolve-thread --reply succeeds" "$resolve_rc" "0"
[ "$resolve_rc" -eq 0 ] || printf '%s\n' "$resolve_out" | tail -n 20 | sed 's/^/        /'
thread="$(api GET "projects/$PROJECT_ID/merge_requests/$IID/discussions/$added_thread" 2>&1)"
eq "GL22 the reply is stored in the resolved thread" \
  "$(printf '%s' "$thread" | json 'd.notes.map((n) => n.body.split("\n")[0]).slice(1).join("|")')" "Fixed by the live check."
eq "GL23 GitLab marks the thread resolved" "$(printf '%s' "$thread" | json 'd.notes[0].resolved')" "true"
xeq "GL24 --fetch-threads drops the resolved thread" \
  "$(fetch_threads "$IID" 'd.some((t) => t.threadId === process.env.ARG) ? "listed" : d.length' "$added_thread")" "4" "$THREADS_SIG" "$THREADS_BUG"

EACH_COUNT='process.env.ARG.split("|").map((t) => d.filter((x) => !x.individual_note && x.notes.length > 0 && x.notes[0].body.includes(t)).length).join(" ")'
context_note="$(printf '%s' "$(discussions)" | json "$FIRST_NOTE_ID" 'context line note')"
deleted="$(api DELETE "projects/$PROJECT_ID/merge_requests/$IID/notes/$context_note" 2>&1)" \
  || abort "GL30 one review discussion is deleted on GitLab" "$deleted"
eq "GL30 one review discussion is deleted on GitLab" "$(discussions | json "$COUNT_OF" 'context line note')" "0"
partial_out="$(vcs --post-review --provider gitlab --repo-id "$RID" "$IID" "$WORK/review.json" 2>&1)"
partial_rc=$?
eq "GL31 a re-run after a lost discussion succeeds" "$partial_rc" "0"
[ "$partial_rc" -eq 0 ] || printf '%s\n' "$partial_out" | tail -n 20 | sed 's/^/        /'
D="$(discussions)"
xeq "GL32 the re-run restores the lost discussion without repeating the others" \
  "$(printf '%s' "$D" | json "$EACH_COUNT" "$REVIEW_TEXTS")" "1 1 1 1 1" "2 2 1 2 2" "$POSTREVIEW_BUG"
eq "GL33 the restored discussion keeps its context-line position" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'context line note')" '["DiffNote","text","src/a.js","src/a.js",11,12]'
xeq "GL34 the re-run adds no summary note" "$(notes | json "$SUMMARY_COUNT" 'Live review body.')" "1" "2" "$POSTREVIEW_BUG"

discussions_before="$(discussions | json 'd.length')"
notes_before="$(notes | json "$USER_NOTES")"
rerun_out="$(vcs --post-review --provider gitlab --repo-id "$RID" "$IID" "$WORK/review.json" 2>&1)"
rerun_rc=$?
eq "GL35 a re-run on a complete review succeeds" "$rerun_rc" "0"
[ "$rerun_rc" -eq 0 ] || printf '%s\n' "$rerun_out" | tail -n 20 | sed 's/^/        /'
xeq "GL36 a re-run on a complete review adds no discussion" "$(discussions | json 'd.length')" "$discussions_before" \
  "$(plus "$discussions_before" 6)" "$POSTREVIEW_BUG"
xeq "GL37 a re-run on a complete review adds no note" "$(notes | json "$USER_NOTES")" "$notes_before" \
  "$(plus "$notes_before" 6)" "$POSTREVIEW_BUG"

OP="team-review:v1:live-$NAME"
reconcile() {
  vcs --reconcile-review --provider gitlab --repo-id "$RID" --expected-head "$HEAD_SHA" --operation-key "$OP" \
    "$IID" "$WORK/reconcile.json" 2>"$WORK/reconcile.err"
}
R1="$(reconcile)"
eq "GL40 --reconcile-review posts every part" "$(printf '%s' "$R1" | json '[d.status, d.partCount, d.postedCount]')" '["posted",3,3]' "$WORK/reconcile.err"
has "GL41 the reconcile result names the merge request" "$(printf '%s' "$R1" | json 'd.url')" "$URL/root/$NAME/-/merge_requests/$IID"
D="$(discussions)"
eq "GL42 GitLab stores the reconcile summary note" "$(notes | json "$SUMMARY_COUNT" 'Reconcile summary.')" "1"
eq "GL43 the reconciled added line is stored as a diff note" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'reconcile added note')" '["DiffNote","text","src/a.js","src/a.js",null,10]'
eq "GL44 the reconciled removed line is stored as a diff note" \
  "$(printf '%s' "$D" | json "$POSITION_OF" 'reconcile removed note')" '["DiffNote","text","src/b.js","src/b.js",5,null]'
stored_before="$(printf '%s' "$D" | json 'd.length') $(notes | json "$USER_NOTES")"
R2="$(reconcile)"
eq "GL45 a second reconcile finds every part present" "$(printf '%s' "$R2" | json '[d.status, d.postedCount]')" '["present",0]' "$WORK/reconcile.err"
eq "GL46 a second reconcile stores nothing on GitLab" "$(discussions | json 'd.length') $(notes | json "$USER_NOTES")" "$stored_before"
removed_note="$(printf '%s' "$D" | json "$FIRST_NOTE_ID" 'reconcile removed note')"
deleted="$(api DELETE "projects/$PROJECT_ID/merge_requests/$IID/notes/$removed_note" 2>&1)" \
  || abort "GL47 one reconcile part is deleted on GitLab" "$deleted"
R3="$(reconcile)"
eq "GL47 a reconcile after a lost part posts only that part" "$(printf '%s' "$R3" | json '[d.status, d.postedCount]')" '["reconciled",1]' "$WORK/reconcile.err"
eq "GL48 the lost part exists exactly once again" "$(discussions | json "$COUNT_OF" 'reconcile removed note')" "1"
eq "GL49 the summary and the other part still exist exactly once" \
  "$(notes | json "$SUMMARY_COUNT" 'Reconcile summary.') $(discussions | json "$COUNT_OF" 'reconcile added note')" "1 1"

api_refs="$(api GET "projects/$PROJECT_ID/merge_requests/$IID" | json 'JSON.stringify({ base_sha: d.diff_refs.base_sha, start_sha: d.diff_refs.start_sha, head_sha: d.diff_refs.head_sha })')"
eq "GL50 --diff-refs matches the diff refs GitLab reports" "$(vcs --diff-refs --provider gitlab --repo-id "$RID" "$IID" 2>&1)" "$api_refs"
eq "GL51 --pr-state reads the open merge request through the repository remote" \
  "$(vcs --pr-state --provider gitlab "$IID" 2>&1)" "OPEN"

MR_URL="$URL/root/$NAME/-/merge_requests/$IID"
eq "GL52 --scout-pr reads the merge request with its labels as strings" \
  "$(vcs --scout-pr --provider gitlab "$IID" 2>&1 | json '[d.id, d.url, d.state, d.title, d.body, d.base, d.head, d.author, d.labels.slice().sort()]')" \
  "[\"$IID\",\"$MR_URL\",\"OPEN\",\"Zensu live check\",\"Live check body.\",\"main\",\"feature\",\"root\",[\"area/vcs\",\"zensu-live\"]]"
LOCATED="{\"id\":\"$IID\",\"url\":\"$MR_URL\",\"state\":\"OPEN\",\"base\":\"main\",\"head\":\"feature\"}"
eq "GL53 --locate-pr reads the merge request by its number" "$(vcs --locate-pr --provider gitlab "$IID" 2>&1)" "$LOCATED"
isolated git -c user.name=zensu -c user.email=zensu@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -q --allow-empty -m 'Seed the local checkout' >/dev/null 2>&1 \
  && isolated git checkout -q -b feature >/dev/null 2>&1 \
  || abort "GL54 the local checkout switches to the merge request branch"
eq "GL54 --locate-pr finds the merge request of the checked-out branch" "$(vcs --locate-pr --provider gitlab 2>&1)" "$LOCATED"
isolated git checkout -q -b lonely >/dev/null 2>&1 || abort "GL55 the local checkout switches to a branch without a merge request"
lonely_err="$(isolated glab mr view --output json 2>&1 >/dev/null)"
vcs --locate-pr --provider gitlab >/dev/null 2>"$WORK/locate.err"
locate_rc=$?
case "$lonely_err" in
  *"No open merge request available for"*)
    located="$locate_rc"
    if [ "$locate_rc" != 3 ] && ! grep -Fq 'No open merge request available for' "$WORK/locate.err"; then
      located="$locate_rc ($(tr '\n' ' ' < "$WORK/locate.err" | head -c 200))"
    fi
    xeq "GL55 --locate-pr exits 3 on a branch without a merge request" "$located" "3" "1" "$LOCATE_BUG"
    ;;
  *)
    eq "GL55 --locate-pr exits 3 on a branch without a merge request" "$locate_rc" "3" "$WORK/locate.err"
    ;;
esac
markers="$(vcs --review-markers --provider gitlab --repo-id "$RID" "$IID" 2>&1)"
markers_rc=$?
eq "GL56 --review-markers lists exactly one marker, the first part of the reconciled review" \
  "$markers_rc $(printf '%s\n' "$markers" | grep -c 'zensu-review:v1:')" "0 1"
has "GL57 the marker names the reviewed head and the part count" "$markers" ":$HEAD_SHA:3:part=1/3 -->"

threads_commit="$(api POST "projects/$PROJECT_ID/repository/commits" "$(cat "$WORK/threads.json")" 2>&1)" \
  || abort "GL60 --open-pr opens the merge request and prints its URL" "$threads_commit"
THREADS_SHA="$(printf '%s' "$threads_commit" | json 'd.id')"
printf 'Opened by the live check.\n\n- keeps `code` and $HOME literal\n' > "$WORK/mr2-body.md"
opened="$(vcs --open-pr --provider gitlab --base main --head threads --title 'Zensu live threads' --body-file "$WORK/mr2-body.md" 2>"$WORK/open.err")"
open_rc=$?
mr2="$(api GET "projects/$PROJECT_ID/merge_requests?source_branch=threads&state=opened" 2>&1)"
eq "GL60 --open-pr opens the merge request and prints its URL" \
  "$open_rc $opened" "0 $(printf '%s' "$mr2" | json 'd.length === 1 ? d[0].web_url : `count=${d.length}`')" "$WORK/open.err"
eq "GL61 the opened merge request keeps the title, the target and the body file verbatim" \
  "$(printf '%s' "$mr2" | json 'd.length === 1 ? [d[0].title, d[0].target_branch, d[0].description] : null')" \
  '["Zensu live threads","main","Opened by the live check.\n\n- keeps `code` and $HOME literal"]'
IID2="$(printf '%s' "$mr2" | json 'd.length === 1 ? String(d[0].iid) : "<none>"')"
if [ "$IID2" = "<none>" ]; then
  mr2="$(api POST "projects/$PROJECT_ID/merge_requests" '{"source_branch":"threads","target_branch":"main","title":"Zensu live threads"}' 2>&1)" \
    || abort "GL62 the thread merge request exists" "$mr2"
  IID2="$(printf '%s' "$mr2" | json 'String(d.iid)')"
fi
diff_ready "$IID2" "$THREADS_SHA" 2 || abort "GL62 GitLab computes the second merge request diff within 180s"
check "GL62 GitLab computes the second merge request diff within 180s" PASS

discussions2() { api GET "projects/$PROJECT_ID/merge_requests/$IID2/discussions?per_page=100"; }
REFS="$(api GET "projects/$PROJECT_ID/merge_requests/$IID2" | json 'd.diff_refs')" node -e '
  const fs = require("fs");
  const dir = process.argv[1];
  const r = JSON.parse(process.env.REFS);
  const at = (path, side, line) => ({ position_type: "text", base_sha: r.base_sha, start_sha: r.start_sha,
    head_sha: r.head_sha, old_path: path, new_path: path, [side]: line });
  fs.writeFileSync(`${dir}/t-added.json`, JSON.stringify({ body: "thread on an added line", position: at("src/c.js", "new_line", 2) }));
  fs.writeFileSync(`${dir}/t-removed.json`, JSON.stringify({ body: "thread on a removed line", position: at("src/b.js", "old_line", 2) }));
  fs.writeFileSync(`${dir}/t-plain.json`, JSON.stringify({ body: "thread without a position" }));
' "$WORK" || abort "GL63 three resolvable discussions are seeded"
for kind in added removed plain; do
  seeded="$(api POST "projects/$PROJECT_ID/merge_requests/$IID2/discussions" "$(cat "$WORK/t-$kind.json")" 2>&1)" \
    || abort "GL63 three resolvable discussions are seeded" "$seeded"
  [ "$(printf '%s' "$seeded" | json 'd.notes[0].resolvable === true && d.notes[0].resolved === false')" = true ] \
    || abort "GL63 three resolvable discussions are seeded" "$seeded"
done
check "GL63 three resolvable discussions are seeded" PASS

eq "GL64 --fetch-threads lists every unresolved thread with its path, line, author and body" \
  "$(fetch_threads "$IID2" 'd.map((t) => `${t.path}:${t.line}:${t.author}:${t.body}`).sort().join("|")')" \
  ":null:root:thread without a position|src/b.js:2:root:thread on a removed line|src/c.js:2:root:thread on an added line"
eq "GL65 every listed thread carries its GitLab discussion id" \
  "$(fetch_threads "$IID2" 'd.map((t) => `${t.threadId}=${t.replyTo}`).sort().join(" ")')" \
  "$(discussions2 | json 'd.filter((x) => !x.individual_note).map((x) => `${x.id}=${x.id}`).sort().join(" ")')"
added2="$(discussions2 | json "$DISCUSSION_ID" 'thread on an added line')"
resolve2_out="$(vcs --resolve-thread --provider gitlab --repo-id "$RID" "$IID2" "$added2" 2>&1)"
resolve2_rc=$?
eq "GL66 --resolve-thread without --reply succeeds" "$resolve2_rc" "0"
[ "$resolve2_rc" -eq 0 ] || printf '%s\n' "$resolve2_out" | tail -n 20 | sed 's/^/        /'
eq "GL67 GitLab marks the thread resolved and stores no reply" \
  "$(api GET "projects/$PROJECT_ID/merge_requests/$IID2/discussions/$added2" 2>&1 | json '[d.notes[0].resolved, d.notes.length]')" "[true,1]"
eq "GL68 --fetch-threads drops the resolved thread" "$(fetch_threads "$IID2" "$THREAD_LINES")" ":null src/b.js:2"

eq "GL69 --review-summary reports an unreviewed merge request" \
  "$(vcs --review-summary --provider gitlab --repo-id "$RID" "$IID2" 2>&1)" '{"reviewed":false,"approved":false,"changesRequested":false}'
approved="$(api POST "projects/$PROJECT_ID/merge_requests/$IID2/approve" '{}' 2>&1)" \
  || abort "GL70 --review-summary reports the approval" "$approved"
eq "GL70 --review-summary reports the approval" \
  "$(vcs --review-summary --provider gitlab --repo-id "$RID" "$IID2" 2>&1)" '{"reviewed":true,"approved":true,"changesRequested":false}'
eq "GL71 the approval leaves a system note without a resolution state" \
  "$(discussions2 | json 'd.some((x) => x.notes.some((n) => n.system && typeof n.resolved !== "boolean"))')" "true"
xeq "GL72 --fetch-threads still lists the unresolved threads after the approval" \
  "$(fetch_threads "$IID2" "$THREAD_LINES")" ":null src/b.js:2" "$THREADS_SIG" "$THREADS_BUG"

finish
