#!/bin/bash
set -u

SUITE=test-vcs-github-live
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="${ZENSU_GITHUB_IT_LIB:-$PLUGIN_DIR/hooks/lib/zensu-vcs.sh}"
STATE="$ZENSU_GITHUB_IT_STATE"
GH_BIN="${ZENSU_GITHUB_IT_GH:-}"
API=https://api.github.com
WEB=https://github.com
STALE_SECONDS=21600

refuse() {
  printf '%s: not configured: %s\n' "$SUITE" "$*" >&2
  exit 2
}

[ -f "$LIB" ] || refuse "driver $LIB is missing"
[ -n "$GH_BIN" ] && [ -x "$GH_BIN" ] || refuse 'ZENSU_GITHUB_IT_GH must name an executable gh binary'
[ -f "$STATE/repo" ] && [ -f "$STATE/header" ] && [ -f "$STATE/token" ] \
  || refuse "no GitHub state in $STATE; run github-token.sh first"
for tool in node curl git; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is not installed"
done
REPO="$(tr -d '[:space:]' < "$STATE/repo")"
printf '%s' "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || refuse "$STATE/repo names no owner/name repository"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

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
has() { local l="$1" g="$2" n="$3"; case "$g" in *"$n"*) check "$l" PASS ;; *) check "$l (missing '$n' in '$g')" FAIL ;; esac; }
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zensu-github-live.XXXXXX")"
RUN="$(date +%s)-$(node -e 'process.stdout.write(require("crypto").randomBytes(3).toString("hex"))')"
PREFIX="zensu-it/$RUN"
BASE="$PREFIX/base"
FEATURE="$PREFIX/feature"
THREADS="$PREFIX/threads"
LONELY="$PREFIX/lonely"
PRS=""
BRANCHES=""
TORN=0

api() {
  local method="$1" path="$2"
  if [ $# -ge 3 ]; then
    printf '%s' "$3" | curl -sS --fail-with-body --max-time 60 -X "$method" -H @"$STATE/header" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H 'Content-Type: application/json' --data-binary @- "$API/$path"
  else
    curl -sS --fail-with-body --max-time 60 -X "$method" -H @"$STATE/header" \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$API/$path"
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

body() {
  node -e 'process.stdout.write(JSON.stringify(new Function(`return (${process.argv[1]});`)()))' "$1"
}

graphql() {
  local vars="${2:-}"
  [ -n "$vars" ] || vars='{}'
  api POST graphql "$(QUERY="$1" VARS="$vars" node -e '
    process.stdout.write(JSON.stringify({ query: process.env.QUERY, variables: JSON.parse(process.env.VARS) }));
  ')"
}

encode() {
  node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$1"
}

teardown() {
  [ "$TORN" = 1 ] && return 0
  TORN=1
  if [ "${ZENSU_GITHUB_IT_KEEP:-0}" = 1 ]; then
    echo "  KEEP  the pull requests and branches under $PREFIX stay in $REPO"
    return 0
  fi
  local number branch
  for number in $PRS; do
    api PATCH "repos/$REPO/pulls/$number" '{"state":"closed"}' >/dev/null 2>&1 \
      || echo "  WARN  pull request #$number could not be closed"
  done
  for branch in $BRANCHES; do
    api DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null 2>&1 \
      || echo "  WARN  branch $branch could not be deleted"
  done
}
cleanup() {
  teardown
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORK/bin" "$WORK/home/.config/gh" "$WORK/repo" "$WORK/elsewhere"
ln -s "$GH_BIN" "$WORK/bin/gh"

isolated() {
  (
    cd "${ISO_CWD:-$WORK/repo}" || exit 97
    unset ZENSU_VCS_TEST ZENSU_VCS_PRINT_ARGV ZENSU_VCS_REMOTE ZENSU_VCS_PROVIDER ZENSU_VCS_API_BASE ZENSU_VCS_NO_PROBE \
      GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_REPO GH_DEBUG GH_PAGER GH_FORCE_TTY \
      GH_EDITOR GH_BROWSER GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE ZENSU_GITHUB_IT_APP_KEY ZENSU_GITHUB_IT_APP_KEY_FILE
    export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GH_CONFIG_DIR="$WORK/home/.config/gh" \
      XDG_STATE_HOME="$WORK/home/.local/state" XDG_DATA_HOME="$WORK/home/.local/share" XDG_CACHE_HOME="$WORK/home/.cache"
    export GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 NO_COLOR=1 GIT_TERMINAL_PROMPT=0
    GH_TOKEN="$(cat "$STATE/token")"
    export GH_TOKEN
    export PATH="$WORK/bin:$PATH"
    "$@"
  )
}
vcs() { isolated bash "$LIB" "$@"; }

RESOLVED_GH="$(isolated sh -c 'command -v gh')"
GH_VERSION="$(GH_CONFIG_DIR="$WORK/home/.config/gh" GH_NO_UPDATE_NOTIFIER=1 "$GH_BIN" --version 2>/dev/null | head -n 1)"
echo "$SUITE against $REPO with ${GH_VERSION:-an unknown gh}, run $RUN"
eq "GH1 the driver resolves gh to the binary under test" "$RESOLVED_GH" "$WORK/bin/gh"
seen="$(isolated gh api "repos/$REPO" 2>"$WORK/repo.err")"
[ "$(printf '%s' "$seen" | json 'String(d.full_name).toLowerCase()')" = "$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')" ] \
  || abort "GH2 gh reads the sandbox repository with the installation token" "$seen$(cat "$WORK/repo.err")"
check "GH2 gh reads the sandbox repository with the installation token" PASS
[ "$(printf '%s' "$seen" | json 'd.private === true')" = true ] \
  || abort "GH2a the sandbox repository is private, so the run writes nothing into a public one" "$(printf '%s' "$seen" | json '[d.private, d.visibility]')"
check "GH2a the sandbox repository is private, so the run writes nothing into a public one" PASS

sweep() {
  local refs stale branch numbers number count=0
  refs="$(api GET "repos/$REPO/git/matching-refs/heads/zensu-it/" 2>&1)" || { printf 'listing failed: %s' "$refs"; return 1; }
  stale="$(printf '%s' "$refs" | CUTOFF="$(( $(date +%s) - STALE_SECONDS ))" node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      const cutoff = Number(process.env.CUTOFF);
      const out = [];
      for (const ref of JSON.parse(raw)) {
        const match = /^refs\/heads\/(zensu-it\/([0-9]+)-[0-9a-f]+\/[a-z]+)$/.exec(ref.ref || "");
        if (match && Number(match[2]) < cutoff) out.push(match[1]);
      }
      process.stdout.write(out.join(" "));
    });
  ')" || { printf 'the ref listing did not parse'; return 1; }
  for branch in $stale; do
    numbers="$(api GET "repos/$REPO/pulls?state=open&per_page=100&head=$(encode "$OWNER:$branch")" | json 'd.map((p) => p.number).join(" ")')"
    case "$numbers" in
      ('<error>'|'<absent>') printf 'listing the pull requests of %s failed' "$branch"; return 1 ;;
    esac
    for number in $numbers; do
      api PATCH "repos/$REPO/pulls/$number" '{"state":"closed"}' >/dev/null || { printf 'closing #%s failed' "$number"; return 1; }
    done
    api DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null || { printf 'deleting %s failed' "$branch"; return 1; }
    count=$((count + 1))
  done
  printf 'swept %s branches' "$count"
}
swept="$(sweep)"
sweep_rc=$?
echo "        $swept"
[ "$sweep_rc" -eq 0 ] && check "GH3 the leftovers of runs older than six hours are removed" PASS \
  || check "GH3 the leftovers of runs older than six hours are removed" FAIL

node -e '
  const fs = require("fs");
  const dir = process.argv[1];
  const text = (list) => `${list.join("\n")}\n`;
  const run = (prefix, from, to) => Array.from({ length: to - from + 1 }, (_, i) => `${prefix}${from + i}`);
  const file = (path, content) => ({ path, mode: "100644", type: "blob", content });
  const aBase = [...run("line", 1, 9), "ctx", "ctx2", "ctx3", ...run("line", 13, 15)];
  const aHead = [...run("line", 1, 9), "added10", "ctx", "ctx2", "ctx3", ...run("line", 13, 15)];
  const bBase = ["keep1", "keep2", "keep3", "keep4", "removed5", "keep6", "keep7", "keep8"];
  const oldBase = ["one", "two", "three", "four", "five", "six"];
  const newHead = ["one", "TWO", "three", "four", "five", "six"];
  fs.writeFileSync(`${dir}/tree-base.json`, JSON.stringify({ tree: [
    file("src/a.js", text(aBase)), file("src/b.js", text(bBase)), file("src/old.js", text(oldBase)),
  ] }));
  fs.writeFileSync(`${dir}/tree-feature.json`, JSON.stringify({ tree: [
    file("src/a.js", text(aHead)), file("src/b.js", text(bBase.filter((line) => line !== "removed5"))),
    { path: "src/old.js", mode: "100644", type: "blob", sha: null }, file("src/new.js", text(newHead)),
  ] }));
  fs.writeFileSync(`${dir}/tree-threads.json`, JSON.stringify({ tree: [
    file("src/c.js", text(["one", "two", "three"])), file("src/b.js", text(bBase.filter((line) => line !== "keep2"))),
  ] }));
' "$WORK"

tree() {
  local spec="$WORK/tree-$1.json" base_tree="${2:-}" request
  request="$(SPEC="$spec" BASE_TREE="$base_tree" node -e '
    const spec = JSON.parse(require("fs").readFileSync(process.env.SPEC, "utf8"));
    if (process.env.BASE_TREE) spec.base_tree = process.env.BASE_TREE;
    process.stdout.write(JSON.stringify(spec));
  ')"
  api POST "repos/$REPO/git/trees" "$request" | json 'd.sha'
}
commit() {
  local message="$1" tree_sha="$2" parent="${3:-}"
  api POST "repos/$REPO/git/commits" "$(MESSAGE="$message" TREE="$tree_sha" PARENT="$parent" node -e '
    process.stdout.write(JSON.stringify({ message: process.env.MESSAGE, tree: process.env.TREE,
      parents: process.env.PARENT ? [process.env.PARENT] : [] }));
  ')" | json 'd.sha'
}
branch() {
  local name="$1" sha="$2" made
  made="$(api POST "repos/$REPO/git/refs" "$(REF="refs/heads/$name" SHA="$sha" node -e '
    process.stdout.write(JSON.stringify({ ref: process.env.REF, sha: process.env.SHA }));
  ')" | json 'd.object && d.object.sha')"
  [ "$made" = "$sha" ] || return 1
  BRANCHES="$BRANCHES $name"
}
is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

BASE_TREE="$(tree base)"
is_sha "$BASE_TREE" || abort "GH4 the base and feature commits are created" "base tree: $BASE_TREE"
BASE_SHA="$(commit 'Seed the base files' "$BASE_TREE")"
is_sha "$BASE_SHA" && branch "$BASE" "$BASE_SHA" || abort "GH4 the base and feature commits are created" "base commit: $BASE_SHA"
FEATURE_TREE="$(tree feature "$BASE_TREE")"
HEAD_SHA="$(commit 'Add, remove and rename lines' "$FEATURE_TREE" "$BASE_SHA")"
is_sha "$HEAD_SHA" && branch "$FEATURE" "$HEAD_SHA" || abort "GH4 the base and feature commits are created" "feature commit: $HEAD_SHA"
check "GH4 the base and feature commits are created" PASS

ensure_label() {
  local name="$1" color="$2" encoded
  encoded="$(encode "$name")"
  api GET "repos/$REPO/labels/$encoded" >/dev/null 2>&1 && return 0
  api POST "repos/$REPO/labels" "$(body "{ name: '$name', color: '$color' }")" >/dev/null 2>&1 && return 0
  api GET "repos/$REPO/labels/$encoded" >/dev/null 2>&1
}
pr="$(api POST "repos/$REPO/pulls" "$(HEAD="$FEATURE" BASE="$BASE" node -e '
  process.stdout.write(JSON.stringify({ title: "Zensu live check", head: process.env.HEAD, base: process.env.BASE,
    body: "Live check body." }));
')" 2>&1)" || abort "GH5 the pull request is opened with its labels" "$pr"
N1="$(printf '%s' "$pr" | json 'String(d.number)')"
printf '%s' "$N1" | grep -Eq '^[0-9]+$' || abort "GH5 the pull request is opened with its labels" "$pr"
PRS="$PRS $N1"
AUTHOR_REST="$(printf '%s' "$pr" | json 'd.user.type === "Bot" ? "app/" + d.user.login.replace(/\[bot\]$/, "") : d.user.login')"
ensure_label zensu-live 0e8a16 && ensure_label area/vcs 1d76db \
  || abort "GH5 the pull request is opened with its labels" 'the labels zensu-live and area/vcs could not be created'
labelled="$(api POST "repos/$REPO/issues/$N1/labels" '{"labels":["zensu-live","area/vcs"]}' 2>&1)" \
  || abort "GH5 the pull request is opened with its labels" "$labelled"
check "GH5 the pull request is opened with its labels" PASS

diff_ready() {
  local number="$1" sha="$2" count="$3" head files deadline
  deadline=$(( $(date +%s) + 120 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    head="$(api GET "repos/$REPO/pulls/$number" 2>/dev/null | json 'd.head && d.head.sha')"
    files="$(api GET "repos/$REPO/pulls/$number/files?per_page=100" 2>/dev/null | json 'd.length')"
    [ "$head" = "$sha" ] && [ "$files" = "$count" ] && return 0
    sleep 2
  done
  return 1
}
diff_ready "$N1" "$HEAD_SHA" 3 || abort "GH6 GitHub computes the pull request diff within 120s"
check "GH6 GitHub computes the pull request diff within 120s" PASS
eq "GH7 GitHub reports the fixture as two modified files and one rename" \
  "$(api GET "repos/$REPO/pulls/$N1/files?per_page=100" | json 'd.map((f) => [f.filename, f.status, f.previous_filename || null].join(":")).sort().join(" ")')" \
  "src/a.js:modified: src/b.js:modified: src/new.js:renamed:src/old.js"

node -e '
  const fs = require("fs");
  const [dir, head] = process.argv.slice(1);
  const review = (body, comments) => JSON.stringify({ commit_id: head, event: "COMMENT", body, comments });
  const valid = [
    { path: "src/a.js", line: 10, side: "RIGHT", body: "added line note" },
    { path: "src/b.js", line: 5, side: "LEFT", body: "removed line note" },
    { path: "src/a.js", line: 12, side: "RIGHT", body: "context line note" },
    { path: "src/new.js", line: 3, side: "RIGHT", body: "renamed file note" },
  ];
  fs.writeFileSync(`${dir}/review.json`, review("Live review body.", valid));
  fs.writeFileSync(`${dir}/outside.json`, review("Refused review body.",
    [...valid, { path: "src/a.js", line: 99, side: "RIGHT", body: "outside the diff note" }]));
  fs.writeFileSync(`${dir}/reconcile.json`, review("Reconcile summary.", [
    { path: "src/a.js", line: 10, side: "RIGHT", body: "reconcile added note" },
    { path: "src/b.js", line: 5, side: "LEFT", body: "reconcile removed note" },
  ]));
' "$WORK" "$HEAD_SHA"

reviews() { api GET "repos/$REPO/pulls/$1/reviews?per_page=100"; }
comments() { api GET "repos/$REPO/pulls/$1/comments?per_page=100"; }
REVIEW_COUNT='d.filter((r) => r.body.includes(process.env.ARG)).length'
POSITION_OF='(() => {
  const hits = d.filter((c) => c.body === process.env.ARG);
  if (hits.length < 1) return "count=0";
  const c = hits[0];
  return [c.path, c.line, c.side, c.start_line, c.commit_id];
})()'

outside_out="$(vcs --post-review --provider github --repo-id "$REPO" "$N1" "$WORK/outside.json" 2>&1)"
outside_rc=$?
case "$outside_out" in
  (*'post-review POST (gh api pulls reviews) failed (rc=1)'*'HTTP 422'*) outside_seen=reported ;;
  (*) outside_seen="unreported: $(printf '%s' "$outside_out" | tr '\n' ' ' | head -c 300)" ;;
esac
eq "GH10 --post-review exits 1 and reports GitHub's 422 when one anchor lies outside the diff" \
  "$outside_rc $outside_seen" "1 reported"
eq "GH11 GitHub refuses the whole review and stores none of its comments" \
  "$(reviews "$N1" | json 'd.length') $(comments "$N1" | json 'd.length')" "0 0"

post_out="$(vcs --post-review --provider github --repo-id "$REPO" "$N1" "$WORK/review.json" 2>&1)"
post_rc=$?
REVIEWS="$(reviews "$N1")"
FIRST_REVIEW="$(printf '%s' "$REVIEWS" | json 'String((d.find((r) => r.body === "Live review body.") || {}).id)')"
eq "GH12 --post-review publishes the review and prints its URL" \
  "$post_rc $post_out" "0 $WEB/$REPO/pull/$N1#pullrequestreview-$FIRST_REVIEW"
eq "GH13 GitHub stores one review with the summary body, the COMMENT event and the reviewed head" \
  "$(printf '%s' "$REVIEWS" | json 'd.map((r) => [r.body, r.state, r.commit_id].join("|")).join(" ")')" \
  "Live review body.|COMMENTED|$HEAD_SHA"
C="$(comments "$N1")"
eq "GH14 an added line is stored on the right side" "$(printf '%s' "$C" | json "$POSITION_OF" 'added line note')" "[\"src/a.js\",10,\"RIGHT\",null,\"$HEAD_SHA\"]"
eq "GH15 a removed line is stored on the left side" "$(printf '%s' "$C" | json "$POSITION_OF" 'removed line note')" "[\"src/b.js\",5,\"LEFT\",null,\"$HEAD_SHA\"]"
eq "GH16 an unchanged context line is stored on the right side" "$(printf '%s' "$C" | json "$POSITION_OF" 'context line note')" "[\"src/a.js\",12,\"RIGHT\",null,\"$HEAD_SHA\"]"
eq "GH17 a line of a renamed file is stored under its new path" "$(printf '%s' "$C" | json "$POSITION_OF" 'renamed file note')" "[\"src/new.js\",3,\"RIGHT\",null,\"$HEAD_SHA\"]"
eq "GH18 every inline comment belongs to the published review" \
  "$(printf '%s' "$C" | json 'd.map((c) => String(c.pull_request_review_id)).filter((v, i, a) => a.indexOf(v) === i).join(" ") + " " + d.length')" \
  "$FIRST_REVIEW 4"

rerun_out="$(vcs --post-review --provider github --repo-id "$REPO" "$N1" "$WORK/review.json" 2>&1)"
rerun_rc=$?
eq "GH20 a standalone re-run succeeds" "$rerun_rc" "0"
[ "$rerun_rc" -eq 0 ] || printf '%s\n' "$rerun_out" | tail -n 20 | sed 's/^/        /'
eq "GH21 a standalone re-run adds exactly one more review with its comments, as the publish rules document" \
  "$(reviews "$N1" | json "$REVIEW_COUNT" 'Live review body.') $(comments "$N1" | json 'd.length')" "2 8"

THREADS_Q='query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{databaseId body path line author{login}}}}}}}}'
truth() {
  graphql "$THREADS_Q" "$(OWNER="$OWNER" NAME="$NAME" NUM="$1" node -e '
    process.stdout.write(JSON.stringify({ owner: process.env.OWNER, name: process.env.NAME, num: Number(process.env.NUM) }));
  ')"
}
TRUTH_PAIRS='d.data.repository.pullRequest.reviewThreads.nodes.filter((t) => !t.isResolved).map((t) => `${t.id}=${t.comments.nodes[0].databaseId}`).sort().join(" ")'
TRUTH_AUTHOR='[...new Set(d.data.repository.pullRequest.reviewThreads.nodes.map((t) => t.comments.nodes[0].author.login))].join(" ")'
THREAD_LINES='d.map((t) => `${t.path}:${t.line}`).sort().join(" ")'

fetch_threads() {
  local number="$1" expr="$2" arg="${3:-}" out rc
  out="$(vcs --fetch-threads --provider github --repo-id "$REPO" "$number" 2>"$WORK/threads.err")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | json "$expr" "$arg"
  else
    printf 'rc=%s out=%s err=%s' "$rc" "$out" "$(head -c 300 "$WORK/threads.err")"
  fi
}

eq "GH30 --fetch-threads lists the eight unresolved threads with their path and line" \
  "$(fetch_threads "$N1" "$THREAD_LINES")" \
  "src/a.js:10 src/a.js:10 src/a.js:12 src/a.js:12 src/b.js:5 src/b.js:5 src/new.js:3 src/new.js:3"
T1="$(truth "$N1")"
eq "GH31 every listed thread carries the GraphQL thread id and the REST id of its first comment" \
  "$(fetch_threads "$N1" 'd.map((t) => `${t.threadId}=${t.replyTo}`).sort().join(" ")')" \
  "$(printf '%s' "$T1" | json "$TRUTH_PAIRS")"
BOT="$(printf '%s' "$T1" | json "$TRUTH_AUTHOR")"
eq "GH32 every listed thread names the author and the body of its first comment" \
  "$(fetch_threads "$N1" '[...new Set(d.map((t) => `${t.author}|${t.body}`))].sort().join(" ")')" \
  "$BOT|added line note $BOT|context line note $BOT|removed line note $BOT|renamed file note"

ADDED_THREAD="$(fetch_threads "$N1" '(() => { const t = d.filter((x) => x.body === "added line note").sort((a, b) => Number(a.replyTo) - Number(b.replyTo))[0]; return t ? `${t.threadId} ${t.replyTo}` : "<none>"; })()')"
thread_id="${ADDED_THREAD% *}"
reply_to="${ADDED_THREAD#* }"
resolve_out="$(vcs --resolve-thread --provider github --repo-id "$REPO" --reply 'Fixed by the live check.' "$N1" "$thread_id" "$reply_to" 2>&1)"
resolve_rc=$?
eq "GH40 --resolve-thread --reply succeeds" "$resolve_rc" "0"
[ "$resolve_rc" -eq 0 ] || printf '%s\n' "$resolve_out" | tail -n 20 | sed 's/^/        /'
eq "GH41 the reply is stored as an answer to the first comment of the thread" \
  "$(comments "$N1" | json 'd.filter((c) => String(c.in_reply_to_id) === process.env.ARG).map((c) => c.body).join("|")' "$reply_to")" \
  "Fixed by the live check."
NODE_Q='query($id:ID!){node(id:$id){... on PullRequestReviewThread{isResolved comments(first:20){totalCount}}}}'
node_state() {
  graphql "$NODE_Q" "$(ID="$1" node -e 'process.stdout.write(JSON.stringify({ id: process.env.ID }))')" \
    | json '[d.data.node.isResolved, d.data.node.comments.totalCount]'
}
eq "GH42 GitHub marks the thread resolved and holds the reply in it" "$(node_state "$thread_id")" "[true,2]"
eq "GH43 --fetch-threads drops the resolved thread" \
  "$(fetch_threads "$N1" 'd.some((t) => t.threadId === process.env.ARG) ? "listed" : d.length' "$thread_id")" "7"

OP="team-review:v1:live-$RUN"
reconcile() {
  local head="$1" payload="$2"
  vcs --reconcile-review --provider github --repo-id "$REPO" --expected-head "$head" --operation-key "$OP" \
    "$N1" "$payload" 2>"$WORK/reconcile.err"
}
R1="$(reconcile "$HEAD_SHA" "$WORK/reconcile.json")"
eq "GH50 --reconcile-review posts the review as one part" \
  "$(printf '%s' "$R1" | json '[d.status, d.partCount, d.postedCount, d.provider]')" '["posted",1,1,"github"]' "$WORK/reconcile.err"
REVIEWS="$(reviews "$N1")"
RECONCILED="$(printf '%s' "$REVIEWS" | json 'String((d.find((r) => r.body.includes("Reconcile summary.")) || {}).id)')"
eq "GH51 the reconcile result names the stored review" \
  "$(printf '%s' "$R1" | json 'd.url')" "$WEB/$REPO/pull/$N1#pullrequestreview-$RECONCILED"
eq "GH52 GitHub stores the summary once, behind the first-part marker for the reviewed head" \
  "$(printf '%s' "$REVIEWS" | json '(() => {
    const hits = d.filter((r) => r.body.includes("Reconcile summary."));
    return hits.length + " " + hits.map((r) => /^<!-- zensu-review:v1:[0-9a-f]{64}:[0-9a-f]{64}:([0-9a-f]{40}):1:part=1\/1 -->\n\nReconcile summary\.$/.exec(r.body)?.[1] || "unmarked").join(" ");
  })()')" "1 $HEAD_SHA"
C="$(comments "$N1")"
eq "GH53 the reconciled comments keep their sides" \
  "$(printf '%s' "$C" | json "$POSITION_OF" 'reconcile added note') $(printf '%s' "$C" | json "$POSITION_OF" 'reconcile removed note')" \
  "[\"src/a.js\",10,\"RIGHT\",null,\"$HEAD_SHA\"] [\"src/b.js\",5,\"LEFT\",null,\"$HEAD_SHA\"]"
stored_before="$(reviews "$N1" | json 'd.length') $(comments "$N1" | json 'd.length')"
R2="$(reconcile "$HEAD_SHA" "$WORK/reconcile.json")"
eq "GH54 a second reconcile finds the review present" "$(printf '%s' "$R2" | json '[d.status, d.postedCount]')" '["present",0]' "$WORK/reconcile.err"
eq "GH55 a second reconcile stores nothing on GitHub" "$(reviews "$N1" | json 'd.length') $(comments "$N1" | json 'd.length')" "$stored_before"
node -e '
  const fs = require("fs");
  const [dir, base] = process.argv.slice(1);
  const payload = JSON.parse(fs.readFileSync(`${dir}/reconcile.json`, "utf8"));
  payload.commit_id = base;
  payload.body = "Stale head summary.";
  fs.writeFileSync(`${dir}/stale.json`, JSON.stringify(payload));
' "$WORK" "$BASE_SHA"
R3="$(reconcile "$BASE_SHA" "$WORK/stale.json")"
stale_rc=$?
eq "GH56 a reconcile bound to another head refuses and stores nothing" \
  "$stale_rc [$R3] $(reviews "$N1" | json 'd.length') $(comments "$N1" | json 'd.length')" "1 [] $stored_before"

markers="$(vcs --review-markers --provider github --repo-id "$REPO" "$N1" 2>&1)"
markers_rc=$?
eq "GH57 --review-markers lists exactly one marker, the reconciled review's" \
  "$markers_rc $(printf '%s\n' "$markers" | grep -c 'zensu-review:v1:')" "0 1"
has "GH58 the marker names the reviewed head and one part" "$markers" ":$HEAD_SHA:1:part=1/1 -->"

isolated git init -q >/dev/null 2>&1 \
  && isolated git remote add origin "$WEB/$REPO.git" >/dev/null 2>&1 \
  && isolated git -c user.name=zensu -c user.email=zensu@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --allow-empty -m 'Seed the local checkout' >/dev/null 2>&1 \
  || abort "GH60 the local checkout points at the sandbox"
check "GH60 the local checkout points at the sandbox" PASS
eq "GH61 --diff-refs reads the head of the pull request through the repository remote" \
  "$(vcs --diff-refs --provider github "$N1" 2>&1)" "{\"base_sha\":\"\",\"start_sha\":\"\",\"head_sha\":\"$HEAD_SHA\"}"
eq "GH62 --pr-state reads the open pull request through the repository remote" "$(vcs --pr-state --provider github "$N1" 2>&1)" "OPEN"
PR_URL="$WEB/$REPO/pull/$N1"
eq "GH63 --scout-pr reads the pull request with its labels as strings" \
  "$(vcs --scout-pr --provider github "$N1" 2>&1 | json '[d.id, d.url, d.state, d.title, d.body, d.base, d.head, d.author, d.labels.slice().sort()]')" \
  "[\"$N1\",\"$PR_URL\",\"OPEN\",\"Zensu live check\",\"Live check body.\",\"$BASE\",\"$FEATURE\",\"$AUTHOR_REST\",[\"area/vcs\",\"zensu-live\"]]"
LOCATED="{\"id\":\"$N1\",\"url\":\"$PR_URL\",\"state\":\"OPEN\",\"base\":\"$BASE\",\"head\":\"$FEATURE\"}"
eq "GH64 --locate-pr reads the pull request by its number" "$(vcs --locate-pr --provider github "$N1" 2>&1)" "$LOCATED"
isolated git checkout -q -b "$FEATURE" >/dev/null 2>&1 || abort "GH65 the local checkout switches to the pull request branch"
eq "GH65 --locate-pr finds the pull request of the checked-out branch" "$(vcs --locate-pr --provider github 2>&1)" "$LOCATED"
isolated git checkout -q -b "$LONELY" >/dev/null 2>&1 || abort "GH66 the local checkout switches to a branch without a pull request"
lonely_err="$(isolated gh pr view --json number 2>&1 >/dev/null)"
vcs --locate-pr --provider github >/dev/null 2>"$WORK/locate.err"
locate_rc=$?
has "GH66 gh reports that the branch has no pull request" "$lonely_err" "no pull requests found for branch"
eq "GH67 --locate-pr exits 3 on a branch without a pull request" "$locate_rc" "3" "$WORK/locate.err"
detected="$(vcs --detect 2>&1)"
eq "GH68 --detect classifies the sandbox remote as github cloud" \
  "$(printf '%s\n' "$detected" | grep -E '^(provider|edition|apiBase|repo|cliName)=' | tr '\n' ' ')" \
  "provider=github edition=cloud apiBase=https://api.github.com repo=$REPO cliName=gh "
eq "GH69 --detect finds gh ready with the installation token" \
  "$(printf '%s\n' "$detected" | grep -E '^(cliReady|cliState)=' | tr '\n' ' ')" "cliReady=true cliState=ready "

THREADS_TREE="$(tree threads "$BASE_TREE")"
THREADS_SHA="$(commit 'Add a file and remove a line' "$THREADS_TREE" "$BASE_SHA")"
is_sha "$THREADS_SHA" && branch "$THREADS" "$THREADS_SHA" || abort "GH70 --open-pr opens the pull request and prints its URL" "threads commit: $THREADS_SHA"
printf 'Opened by the live check.\n\n- keeps `code` and $HOME literal\n' > "$WORK/pr2-body.md"
opened="$(vcs --open-pr --provider github --base "$BASE" --head "$THREADS" --title 'Zensu live threads' --body-file "$WORK/pr2-body.md" 2>"$WORK/open.err")"
open_rc=$?
pr2="$(api GET "repos/$REPO/pulls?state=open&per_page=100&head=$(encode "$OWNER:$THREADS")" 2>&1)"
N2="$(printf '%s' "$pr2" | json 'd.length === 1 ? String(d[0].number) : "<none>"')"
[ "$N2" = "<none>" ] || PRS="$PRS $N2"
eq "GH70 --open-pr opens the pull request and prints its URL" \
  "$open_rc $opened" "0 $(printf '%s' "$pr2" | json 'd.length === 1 ? d[0].html_url : `count=${d.length}`')" "$WORK/open.err"
eq "GH71 the opened pull request keeps the title, the base and the body file verbatim" \
  "$(printf '%s' "$pr2" | json 'd.length === 1 ? [d[0].title, d[0].base.ref, d[0].body] : null')" \
  "[\"Zensu live threads\",\"$BASE\",\"Opened by the live check.\\n\\n- keeps \`code\` and \$HOME literal\"]"
if [ "$N2" = "<none>" ]; then
  pr2="$(api POST "repos/$REPO/pulls" "$(HEAD="$THREADS" BASE="$BASE" node -e '
    process.stdout.write(JSON.stringify({ title: "Zensu live threads", head: process.env.HEAD, base: process.env.BASE }));
  ')" 2>&1)" || abort "GH72 the thread pull request exists" "$pr2"
  N2="$(printf '%s' "$pr2" | json 'String(d.number)')"
  printf '%s' "$N2" | grep -Eq '^[0-9]+$' || abort "GH72 the thread pull request exists" "$pr2"
  PRS="$PRS $N2"
fi
diff_ready "$N2" "$THREADS_SHA" 2 || abort "GH72 GitHub computes the second pull request diff within 120s"
check "GH72 GitHub computes the second pull request diff within 120s" PASS

eq "GH73 --review-summary reports an unreviewed pull request, pinned to --repo-id from any directory" \
  "$(ISO_CWD="$WORK/elsewhere" vcs --review-summary --provider github --repo-id "$REPO" "$N2" 2>&1)" \
  '{"reviewed":false,"approved":false,"changesRequested":false}'

seed_comment() {
  api POST "repos/$REPO/pulls/$N2/comments" "$(BODY="$1" PATH_="$2" LINE="$3" SIDE="$4" SHA="$THREADS_SHA" node -e '
    process.stdout.write(JSON.stringify({ body: process.env.BODY, commit_id: process.env.SHA, path: process.env.PATH_,
      line: Number(process.env.LINE), side: process.env.SIDE }));
  ')" | json 'String(d.id)'
}
seeded_added="$(seed_comment 'thread on an added line' src/c.js 2 RIGHT)"
seeded_removed="$(seed_comment 'thread on a removed line' src/b.js 2 LEFT)"
plain="$(api POST "repos/$REPO/issues/$N2/comments" '{"body":"plain pull request comment"}' 2>&1 | json 'String(d.id)')"
for seeded in "$seeded_added" "$seeded_removed" "$plain"; do
  printf '%s' "$seeded" | grep -Eq '^[0-9]+$' || abort "GH74 two review threads and one plain comment are seeded" "seeded: $seeded_added $seeded_removed $plain"
done
check "GH74 two review threads and one plain comment are seeded" PASS

eq "GH75 --fetch-threads lists only the review threads, with path, line, author and body" \
  "$(fetch_threads "$N2" 'd.map((t) => `${t.path}:${t.line}:${t.author}:${t.body}`).sort().join("|")')" \
  "src/b.js:2:$BOT:thread on a removed line|src/c.js:2:$BOT:thread on an added line"
eq "GH76 every listed thread carries the GraphQL thread id and the REST id of its first comment" \
  "$(fetch_threads "$N2" 'd.map((t) => `${t.threadId}=${t.replyTo}`).sort().join(" ")')" \
  "$(truth "$N2" | json "$TRUTH_PAIRS")"
added2="$(fetch_threads "$N2" '(d.find((t) => t.body === "thread on an added line") || { threadId: "<none>" }).threadId')"
resolve2_out="$(vcs --resolve-thread --provider github --repo-id "$REPO" "$N2" "$added2" 2>&1)"
resolve2_rc=$?
eq "GH77 --resolve-thread without --reply succeeds" "$resolve2_rc" "0"
[ "$resolve2_rc" -eq 0 ] || printf '%s\n' "$resolve2_out" | tail -n 20 | sed 's/^/        /'
eq "GH78 GitHub marks the thread resolved and stores no reply" "$(node_state "$added2")" "[true,1]"
eq "GH79 --fetch-threads drops the resolved thread" "$(fetch_threads "$N2" "$THREAD_LINES")" "src/b.js:2"
eq "GH80 --review-summary reports the commented pull request as reviewed, from the repository remote" \
  "$(vcs --review-summary --provider github "$N2" 2>&1)" '{"reviewed":true,"approved":false,"changesRequested":false}'

if [ "${ZENSU_GITHUB_IT_KEEP:-0}" != 1 ]; then
  teardown
  eq "GH90 every pull request of this run is closed" \
    "$(api GET "repos/$REPO/pulls?state=open&per_page=100" | json 'd.filter((p) => p.head.ref.startsWith(process.env.ARG + "/")).length' "$PREFIX")" "0"
  eq "GH91 no branch of this run remains" "$(api GET "repos/$REPO/git/matching-refs/heads/$PREFIX/" | json 'd.length')" "0"
fi

finish
