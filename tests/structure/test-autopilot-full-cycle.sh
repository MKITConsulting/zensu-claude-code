#!/bin/bash
# Composed Autopilot lifecycle: approval, two TDD generations, durable review
# recovery, finding repair, validation, and terminal delivery.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
LOG_HELPER="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PLAN_HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
VCS_DRIVER="$PLUGIN_DIR/hooks/lib/zensu-vcs.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

for required in "$STATE_LIB" "$LOG_HELPER" "$PLAN_HOOK" "$VCS_DRIVER" "$BASELINE"; do
  if [ ! -f "$required" ] || ! bash -n "$required" 2>/dev/null; then
    check "F1 composed lifecycle dependencies exist and parse" FAIL
    printf '%s\n' "----" "test-autopilot-full-cycle: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "F1 composed lifecycle dependencies exist and parse" PASS

# shellcheck disable=SC1090
source "$STATE_LIB"

ROOT="$(mktemp -d -t zensu-autopilot-full-cycle-XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
PROJECT="$ROOT/project"
FAKE_BIN="$ROOT/bin"
FAKE_STATE="$ROOT/fake-github"
mkdir -p "$PROJECT" "$FAKE_BIN" "$FAKE_STATE"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$PROJECT"
export ZENSU_CONFIG="$ROOT/config.json"
printf '%s\n' '{"hooks":{"autoTdd":false}}' > "$ZENSU_CONFIG"

RUN="full_cycle_run_001"
SESSION="full_cycle_session_001"
CHAIN_1="full-cycle-chain-001"
CHAIN_2="full-cycle-chain-002"
HEAD_1="1111111111111111111111111111111111111111"
HEAD_2="2222222222222222222222222222222222222222"
PR_NUMBER=42
RUN_FILE="$PROJECT/.zensu/state/autopilot-run-${RUN}.json"

# Exercise the composed lifecycle with the same immutable project/session
# binding that a real Claude SessionStart supplies. The durable Outer owner is
# the canonical Session Control key, while hook payloads may keep the raw host
# session id because the resolver proves that it maps to this exact binding.
# shellcheck disable=SC1090
source "$BASELINE" "$SESSION" || exit 1

json_ok() {
  local file="$1" expression="$2"
  FILE="$file" EXPR="$expression" node -e '
    const value=require(process.env.FILE);
    process.exit(Function("value", `return Boolean(${process.env.EXPR})`)(value) ? 0 : 1);
  ' >/dev/null 2>&1
}

json_field() {
  local field="$1"
  FIELD="$field" node -e '
    let input="";
    process.stdin.on("data", chunk => input += chunk);
    process.stdin.on("end", () => {
      try {
        const value=JSON.parse(input)[process.env.FIELD];
        if (value === undefined || value === null || typeof value === "object") process.exit(1);
        process.stdout.write(String(value));
      } catch (_) { process.exit(1); }
    });
  '
}

digest() {
  node -e 'const fs=require("fs"),crypto=require("crypto");process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

apply_event() {
  autopilot_apply_event "$RUN" "$1" "$2" "$3" "$PROJECT" >/dev/null
}

tdd_cycle() {
  local attempt="$1" return_stage="$2" chain_id="$3"
  CLAUDE_PROJECT_DIR="$PROJECT" bash "$LOG_HELPER" --tdd-begin \
    --session "$SESSION" --autopilot-run "$RUN" --autopilot-attempt "$attempt" \
    --autopilot-return-stage "$return_stage" --chain-id "$chain_id" >/dev/null \
    && CLAUDE_PROJECT_DIR="$PROJECT" bash "$LOG_HELPER" --tdd-complete \
      --session "$SESSION" --autopilot-run "$RUN" --autopilot-attempt "$attempt" \
      --autopilot-return-stage "$return_stage" --chain-id "$chain_id" >/dev/null \
    && CLAUDE_PROJECT_DIR="$PROJECT" bash "$LOG_HELPER" --chain-done \
      --session "$SESSION" --autopilot-run "$RUN" --autopilot-attempt "$attempt" \
      --autopilot-return-stage "$return_stage" --chain-id "$chain_id" \
      --outcome pass >/dev/null
}

cat > "$FAKE_BIN/gh" <<'FAKE_GH'
#!/bin/bash
set -u
printf '%s\n' "$*" >> "$FAKE_DIR/calls"
args="$*"

if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  case "$args" in
    *resolveReviewThread*)
      thread_id=""
      for argument in "$@"; do
        case "$argument" in t=*) thread_id="${argument#t=}" ;; esac
      done
      THREAD_ID="$thread_id" REVIEW_FILE="$FAKE_DIR/posted-review.json" \
        REPLY_FILE="$FAKE_DIR/reply.json" RESOLUTION_FILE="$FAKE_DIR/resolution.json" node -e '
        const fs=require("fs");
        function fail(){process.exit(1);}
        function load(path){try{return JSON.parse(fs.readFileSync(path,"utf8"));}catch(_){fail();}}
        function atomicWrite(path,value){
          const tmp=path+".tmp-"+process.pid;let fd;
          try{
            const noFollow=process.platform!=="win32"&&Number.isInteger(fs.constants.O_NOFOLLOW)?fs.constants.O_NOFOLLOW:0;
            fd=fs.openSync(tmp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|noFollow,0o600);
            fs.writeFileSync(fd,JSON.stringify(value));fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
            fs.renameSync(tmp,path);
          }catch(_){if(fd!==undefined){try{fs.closeSync(fd);}catch(__){}}try{fs.unlinkSync(tmp);}catch(__){}fail();}
        }
        const review=load(process.env.REVIEW_FILE),reply=load(process.env.REPLY_FILE);
        const root=review.comments&&review.comments[0],threadId="THREAD_full_cycle_1",replyTo="777";
        if(process.env.THREAD_ID!==threadId||!root||reply.threadId!==threadId||reply.replyTo!==replyTo
            ||JSON.stringify(reply.rootComment)!==JSON.stringify(root)||typeof reply.body!=="string"||!reply.body)fail();
        atomicWrite(process.env.RESOLUTION_FILE,{threadId,replyTo,rootComment:root,reply:reply.body});
        process.stdout.write(JSON.stringify({data:{resolveReviewThread:{thread:{id:threadId}}}}));
      '
      ;;
    *reviewThreads*)
      if [ -f "$FAKE_DIR/posted-review.json" ] && [ ! -f "$FAKE_DIR/resolution.json" ]; then
        REVIEW_FILE="$FAKE_DIR/posted-review.json" node -e '
          const fs=require("fs");function fail(){process.exit(1);}
          let review;try{review=JSON.parse(fs.readFileSync(process.env.REVIEW_FILE,"utf8"));}catch(_){fail();}
          const comment=review.comments&&review.comments[0];
          if(!comment||typeof comment.body!=="string"||typeof comment.path!=="string"
              ||!Number.isSafeInteger(comment.line)||comment.line<1)fail();
          process.stdout.write(JSON.stringify([{data:{repository:{pullRequest:{reviewThreads:{
            nodes:[{id:"THREAD_full_cycle_1",isResolved:false,comments:{nodes:[{
              databaseId:777,body:comment.body,path:comment.path,line:comment.line,author:{login:"reviewer"}
            }]}}],pageInfo:{hasNextPage:false,endCursor:null}
          }}}}}]));
        '
      else
        printf '%s' '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
      fi
      ;;
    *)
      if [ -f "$FAKE_DIR/posted-review.json" ]; then
        REVIEW_FILE="$FAKE_DIR/posted-review.json" node -e '
          const fs=require("fs");let review;
          try{review=JSON.parse(fs.readFileSync(process.env.REVIEW_FILE,"utf8"));}catch(_){process.exit(1);}
          if(!review||typeof review.body!=="string")process.exit(1);
          process.stdout.write(JSON.stringify([{data:{repository:{pullRequest:{reviews:{
            nodes:[{id:"review-1",url:"https://github.test/acme/widget/pull/42#pullrequestreview-1",body:review.body}],
            pageInfo:{hasNextPage:false,endCursor:null}
          }}}}}]));
        '
      else
        printf '%s' '[{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]'
      fi
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = api ] && [ "${2:-}" = 'repos/acme/widget/pulls/42' ]; then
  head_sha="$(cat "$FAKE_DIR/head")"
  printf '{"state":"open","html_url":"https://github.test/acme/widget/pull/42","head":{"sha":"%s"}}' "$head_sha"
  exit 0
fi

if [ "${1:-}" = api ] && [ "${2:-}" = -X ] && [ "${3:-}" = POST ]; then
  input=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = --input ]; then input="$argument"; fi
    previous="$argument"
  done
  [ "$input" = - ] || exit 2
  REVIEW_FILE="$FAKE_DIR/posted-review.json" HEAD_FILE="$FAKE_DIR/head" node -e '
    const fs=require("fs"),max=1024*1024;
    function fail(){process.exit(1);}
    function exactKeys(value,allowed){return JSON.stringify(Object.keys(value).sort())===JSON.stringify(allowed.slice().sort());}
    let raw="";
    process.stdin.on("data",chunk=>{raw+=chunk;if(Buffer.byteLength(raw)>max)fail();});
    process.stdin.on("end",()=>{
      let payload;try{payload=JSON.parse(raw);}catch(_){fail();}
      const expectedHead=fs.readFileSync(process.env.HEAD_FILE,"utf8").trim();
      if(!payload||typeof payload!=="object"||Array.isArray(payload)
          ||!exactKeys(payload,["event","commit_id","body","comments"])
          ||!["COMMENT","APPROVE","REQUEST_CHANGES"].includes(payload.event)
          ||payload.commit_id!==expectedHead||typeof payload.body!=="string"||!payload.body
          ||!Array.isArray(payload.comments)||payload.comments.length<1)fail();
      payload.comments.forEach(comment=>{
        if(!comment||typeof comment!=="object"||Array.isArray(comment)
            ||!exactKeys(comment,["path","line","side","body"])
            ||typeof comment.path!=="string"||!comment.path||!Number.isSafeInteger(comment.line)||comment.line<1
            ||!["LEFT","RIGHT"].includes(comment.side)||typeof comment.body!=="string"||!comment.body)fail();
      });
      const tmp=process.env.REVIEW_FILE+".tmp-"+process.pid;let fd;
      try{
        const noFollow=process.platform!=="win32"&&Number.isInteger(fs.constants.O_NOFOLLOW)?fs.constants.O_NOFOLLOW:0;
        fd=fs.openSync(tmp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|noFollow,0o600);
        fs.writeFileSync(fd,JSON.stringify(payload));fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
        if(fs.existsSync(process.env.REVIEW_FILE))fail();
        fs.renameSync(tmp,process.env.REVIEW_FILE);
      }catch(_){if(fd!==undefined){try{fs.closeSync(fd);}catch(__){}}try{fs.unlinkSync(tmp);}catch(__){}fail();}
    });
  '
  printf '%s' '{"html_url":"https://github.test/acme/widget/pull/42#pullrequestreview-1"}'
  exit 0
fi

if [ "${1:-}" = api ]; then
  case "${2:-}" in
    repos/acme/widget/pulls/42/comments/*/replies)
      reply_to="${2#repos/acme/widget/pulls/42/comments/}"
      reply_to="${reply_to%/replies}"
      reply_body=""
      for argument in "$@"; do
        case "$argument" in body=*) reply_body="${argument#body=}" ;; esac
      done
      REPLY_TO="$reply_to" REPLY_BODY="$reply_body" REVIEW_FILE="$FAKE_DIR/posted-review.json" \
        REPLY_FILE="$FAKE_DIR/reply.json" node -e '
        const fs=require("fs");function fail(){process.exit(1);}
        let review;try{review=JSON.parse(fs.readFileSync(process.env.REVIEW_FILE,"utf8"));}catch(_){fail();}
        const root=review.comments&&review.comments[0],threadId="THREAD_full_cycle_1",replyTo="777";
        if(process.env.REPLY_TO!==replyTo||!root||typeof root.body!=="string"||typeof root.path!=="string"
            ||!Number.isSafeInteger(root.line)||root.line<1||!process.env.REPLY_BODY)fail();
        const value={threadId,replyTo,rootComment:root,body:process.env.REPLY_BODY};
        const tmp=process.env.REPLY_FILE+".tmp-"+process.pid;let fd;
        try{
          const noFollow=process.platform!=="win32"&&Number.isInteger(fs.constants.O_NOFOLLOW)?fs.constants.O_NOFOLLOW:0;
          fd=fs.openSync(tmp,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL|noFollow,0o600);
          fs.writeFileSync(fd,JSON.stringify(value));fs.fsyncSync(fd);fs.closeSync(fd);fd=undefined;
          fs.renameSync(tmp,process.env.REPLY_FILE);
        }catch(_){if(fd!==undefined){try{fs.closeSync(fd);}catch(__){}}try{fs.unlinkSync(tmp);}catch(__){}fail();}
        process.stdout.write('{"id":778}');
      '
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  head_sha="$(cat "$FAKE_DIR/head")"
  printf '{"headRefOid":"%s"}' "$head_sha"
  exit 0
fi

exit 2
FAKE_GH
chmod +x "$FAKE_BIN/gh"
printf '%s' "$HEAD_1" > "$FAKE_STATE/head"

PLAN="# Full-cycle fixture

Exercise the complete durable lifecycle.

<!-- zensu-autopilot:${RUN} -->"
# The shape the CURRENT harness delivers: it strips the ExitPlanMode fields its
# schema does not declare, so the approved plan arrives in the tool response.
# Driving the whole cycle through it is what proves the stage transition and the
# delegation envelope on the payload production actually produces.
PLAN_INPUT="$(PLAN="$PLAN" SESSION="$SESSION" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse",
    session_id:process.env.SESSION,
    tool_name:"ExitPlanMode",
    tool_input:{_targetMode:"auto"},
    tool_response:{plan:process.env.PLAN,isAgent:false,hasTaskTool:true}
  }));
')"

READY=true
autopilot_begin_run "$RUN" "$ZENSU_SESSION_KEY" "$PROJECT" false true >/dev/null || READY=false
APPROVAL_OUT="$(printf '%s' "$PLAN_INPUT" | CLAUDE_PROJECT_DIR="$PROJECT" \
  bash "$PLAN_HOOK" 2>/dev/null)"
if [ "$READY" = true ] \
  && printf '%s' "$APPROVAL_OUT" | grep -qF 'PLAN_APPROVED' \
  && json_ok "$RUN_FILE" 'value.stage==="AWAIT_TDD"&&value.nextActionCode==="START_TDD"' \
  && tdd_cycle 1 GATES "$CHAIN_1" \
  && json_ok "$RUN_FILE" 'value.stage==="GATES"&&value.tdd.attempt===1&&value.tdd.outcome==="pass"'; then
  check "F2 approval hook delegates one bound TDD generation back to GATES" PASS
else
  check "F2 approval hook delegates one bound TDD generation back to GATES" FAIL
  READY=false
fi

PR_KEY="pr:${RUN}"
if [ "$READY" = true ] \
  && apply_event full-gates GATES_PASSED "{\"headSha\":\"$HEAD_1\"}" \
  && apply_event full-convergence CONVERGENCE_PASSED '{}' \
  && apply_event full-pr-request PR_OPEN_REQUESTED "{\"operationKey\":\"$PR_KEY\"}" \
  && apply_event full-pr-open PR_OPENED "{\"operationKey\":\"$PR_KEY\",\"pr\":{\"number\":$PR_NUMBER,\"url\":\"https://github.test/acme/widget/pull/$PR_NUMBER\",\"headSha\":\"$HEAD_1\"}}"; then
  check "F3 gates and convergence durably open the PR at the tested head" PASS
else
  check "F3 gates and convergence durably open the PR at the tested head" FAIL
  READY=false
fi

REVIEW_KEY="$(autopilot_team_review_operation_key "$RUN" "$HEAD_1" 2>/dev/null || true)"
PAYLOAD_SOURCE="$ROOT/team-review.json"
printf '%s\n' "{\"event\":\"COMMENT\",\"body\":\"Full-cycle team review\",\"commit_id\":\"$HEAD_1\",\"comments\":[{\"path\":\"hooks/lib/example.sh\",\"line\":17,\"side\":\"RIGHT\",\"body\":\"Fix the durable retry edge\"}]}" > "$PAYLOAD_SOURCE"
SNAPSHOT=""
if [ "$READY" = true ] \
  && [ -n "$REVIEW_KEY" ] \
  && apply_event full-review-request TEAM_REVIEW_REQUESTED "{\"operationKey\":\"$REVIEW_KEY\",\"provider\":\"github\"}"; then
  SNAPSHOT="$(autopilot_store_team_review_payload "$RUN" "$REVIEW_KEY" "$HEAD_1" \
    "$PAYLOAD_SOURCE" github "$PROJECT" 2>/dev/null || true)"
fi
if [ -n "$SNAPSHOT" ] && [ -f "$SNAPSHOT" ] \
  && json_ok "$RUN_FILE" 'value.stage==="TEAM_REVIEW"&&value.effects.teamReview.status==="requested"&&value.evidence.review===null'; then
  check "F4 review request stores one immutable operation/head-bound payload" PASS
else
  check "F4 review request stores one immutable operation/head-bound payload" FAIL
  READY=false
fi

reconcile_review() {
  local payload="$1"
  FAKE_DIR="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" \
    bash "$VCS_DRIVER" --reconcile-review --provider github --repo-id acme/widget \
      --expected-head "$HEAD_1" --operation-key "$REVIEW_KEY" \
      "$PR_NUMBER" "$payload" 2>/dev/null
}

POST_RESULT=""
RETRY_RESULT=""
SNAPSHOT_BEFORE=""
SNAPSHOT_AFTER=""
if [ "$READY" = true ]; then
  SNAPSHOT_BEFORE="$(digest "$SNAPSHOT")"
  POST_RESULT="$(reconcile_review "$SNAPSHOT" || true)"
  # Crash window: the remote POST succeeded, but no TEAM_REVIEW_PUBLISHED event
  # was durably applied. The mutable source disappears before recovery.
  printf '%s\n' '{"event":"COMMENT","body":"regenerated and wrong","comments":[]}' > "$PAYLOAD_SOURCE"
  rm -f "$PAYLOAD_SOURCE"
  RECOVERED_SNAPSHOT="$(autopilot_read_team_review_payload "$RUN" "$REVIEW_KEY" \
    "$HEAD_1" github "$PROJECT" 2>/dev/null || true)"
  [ -n "$RECOVERED_SNAPSHOT" ] && RETRY_RESULT="$(reconcile_review "$RECOVERED_SNAPSHOT" || true)"
  SNAPSHOT_AFTER="$(digest "$SNAPSHOT" 2>/dev/null || true)"
fi
POST_STATUS="$(printf '%s' "$POST_RESULT" | json_field status 2>/dev/null || true)"
RETRY_STATUS="$(printf '%s' "$RETRY_RESULT" | json_field status 2>/dev/null || true)"
POST_COUNT="$(grep -c -- '-X POST repos/acme/widget/pulls/42/reviews' "$FAKE_STATE/calls" 2>/dev/null || true)"
if [ "$POST_STATUS" = posted ] && [ "$RETRY_STATUS" = present ] \
  && [ "$POST_COUNT" = 1 ] && [ -n "$SNAPSHOT_BEFORE" ] \
  && [ "$SNAPSHOT_BEFORE" = "$SNAPSHOT_AFTER" ] \
  && json_ok "$FAKE_STATE/posted-review.json" \
    'value.event==="COMMENT"&&value.commit_id==="1111111111111111111111111111111111111111"&&value.body.includes("Full-cycle team review")&&value.comments.length===1&&value.comments[0].body==="Fix the durable retry edge"&&value.comments[0].path==="hooks/lib/example.sh"&&value.comments[0].line===17' \
  && json_ok "$RUN_FILE" 'value.stage==="TEAM_REVIEW"&&value.evidence.review===null'; then
  check "F5 crash recovery reuses the durable payload and never duplicates the review POST" PASS
else
  check "F5 crash recovery reuses the durable payload and never duplicates the review POST" FAIL
  READY=false
fi

REVIEW_MARKER="$(printf '%s' "$RETRY_RESULT" | json_field marker 2>/dev/null || true)"
if [ "$READY" = true ] \
  && apply_event full-review-published TEAM_REVIEW_PUBLISHED \
    "{\"operationKey\":\"$REVIEW_KEY\",\"provider\":\"github\",\"marker\":\"$REVIEW_MARKER\",\"headSha\":\"$HEAD_1\"}"; then
  :
else
  READY=false
fi

OPEN_THREADS=""
if [ "$READY" = true ]; then
  OPEN_THREADS="$(FAKE_DIR="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" \
    bash "$VCS_DRIVER" --fetch-threads --provider github --repo-id acme/widget \
      "$PR_NUMBER" 2>/dev/null || true)"
fi
if printf '%s' "$OPEN_THREADS" | node -e '
  let input="";process.stdin.on("data",c=>input+=c);process.stdin.on("end",()=>{
    try { const value=JSON.parse(input); process.exit(value.length===1
      && value[0].threadId==="THREAD_full_cycle_1" && value[0].replyTo==="777"
      && value[0].body==="Fix the durable retry edge" && value[0].path==="hooks/lib/example.sh"
      && value[0].line===17 ? 0 : 1); }
    catch (_) { process.exit(1); }
  });
' >/dev/null 2>&1 \
  && apply_event full-fix-required FIX_REQUIRED "{\"headSha\":\"$HEAD_1\",\"unresolvedCount\":1}" \
  && tdd_cycle 2 FIX_FINDINGS "$CHAIN_2" \
  && json_ok "$RUN_FILE" 'value.stage==="FIX_FINDINGS"&&value.tdd.attempt===2&&value.tdd.headUpdateRequired===true'; then
  check "F6 one fetched finding drives exactly one second bound TDD generation" PASS
else
  check "F6 one fetched finding drives exactly one second bound TDD generation" FAIL
  READY=false
fi

printf '%s' "$HEAD_2" > "$FAKE_STATE/head"
REMOTE_HEAD="$(FAKE_DIR="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" \
  bash "$VCS_DRIVER" --diff-refs --provider github --repo-id acme/widget \
    "$PR_NUMBER" 2>/dev/null | json_field head_sha 2>/dev/null || true)"
if [ "$READY" = true ] && [ "$REMOTE_HEAD" = "$HEAD_2" ] \
  && apply_event full-head-update PR_HEAD_UPDATED \
    "{\"previousHeadSha\":\"$HEAD_1\",\"headSha\":\"$HEAD_2\",\"gatesPassed\":true,\"pushCompleted\":true}" \
  && FAKE_DIR="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" \
    bash "$VCS_DRIVER" --resolve-thread --provider github --repo-id acme/widget \
      --reply 'Fixed by the second TDD generation.' "$PR_NUMBER" \
      THREAD_full_cycle_1 777 >/dev/null 2>&1; then
  :
else
  READY=false
fi

AFTER_THREADS="$(FAKE_DIR="$FAKE_STATE" PATH="$FAKE_BIN:$PATH" \
  bash "$VCS_DRIVER" --fetch-threads --provider github --repo-id acme/widget \
    "$PR_NUMBER" 2>/dev/null || true)"
if [ "$READY" = true ] && [ "$AFTER_THREADS" = '[]' ] \
  && apply_event full-findings-clear FINDINGS_CLEARED \
    "{\"headSha\":\"$HEAD_2\",\"unresolvedCount\":0}"; then
  BEFORE_EARLY_DELIVERY="$(digest "$RUN_FILE")"
  if ! apply_event full-early-delivery DELIVERY_COMPLETE \
      "{\"headSha\":\"$HEAD_2\"}" 2>/dev/null \
    && [ "$(digest "$RUN_FILE")" = "$BEFORE_EARLY_DELIVERY" ] \
    && json_ok "$RUN_FILE" 'value.stage==="VALIDATE"&&value.evidence.findings.headSha===value.evidence.pr.headSha&&value.evidence.validation===null'; then
    check "F7 resolved findings advance the head, while delivery still waits for validation" PASS
  else
    check "F7 resolved findings advance the head, while delivery still waits for validation" FAIL
    READY=false
  fi
else
  check "F7 resolved findings advance the head, while delivery still waits for validation" FAIL
  READY=false
fi

if [ "$READY" = true ] \
  && apply_event full-validation VALIDATION_PASSED "{\"headSha\":\"$HEAD_2\"}" \
  && apply_event full-delivery DELIVERY_COMPLETE "{\"headSha\":\"$HEAD_2\"}" \
  && RUN_FILE="$RUN_FILE" HEAD_1="$HEAD_1" HEAD_2="$HEAD_2" node -e '
    const value=require(process.env.RUN_FILE);
    const marker=/^<!-- zensu-review:v1:[0-9a-f]{64}:([0-9a-f]{64}):[0-9a-f]{7,64}:([1-9][0-9]*):part=1\/\2 -->$/.exec(value.evidence.review.marker||"");
    const events=type=>value.events.filter(event=>event.eventType===type);
    const ok=value.stage==="DONE" && value.nextActionCode==="NONE"
      && value.tdd.attempt===2
      && events("TDD_STARTED").length===2 && events("TDD_CHAIN_DONE").length===2
      && events("TEAM_REVIEW_REQUESTED").length===1 && events("TEAM_REVIEW_PUBLISHED").length===1
      && value.evidence.review.provider==="github"
      && value.evidence.review.headSha===process.env.HEAD_1
      && value.evidence.pr.headSha===process.env.HEAD_2
      && value.evidence.gates.headSha===process.env.HEAD_2
      && value.evidence.findings.headSha===process.env.HEAD_2
      && value.evidence.validation.headSha===process.env.HEAD_2
      && value.evidence.delivery.headSha===process.env.HEAD_2
      && marker && value.evidence.review.payloadDigest===marker[1]
      && value.evidence.review.partCount===Number(marker[2]);
    process.exit(ok ? 0 : 1);
  ' >/dev/null 2>&1; then
  check "F8 validated final head reaches DONE with two TDD receipts and one attested review" PASS
else
  check "F8 validated final head reaches DONE with two TDD receipts and one attested review" FAIL
  READY=false
fi

if [ "$POST_COUNT" = 1 ] \
  && grep -qF 'resolveReviewThread' "$FAKE_STATE/calls" \
  && POSTED_REVIEW_FILE="$FAKE_STATE/posted-review.json" \
    REPLY_FILE="$FAKE_STATE/reply.json" RESOLUTION_FILE="$FAKE_STATE/resolution.json" node -e '
      const review=require(process.env.POSTED_REVIEW_FILE),reply=require(process.env.REPLY_FILE),resolution=require(process.env.RESOLUTION_FILE);
      const root=review.comments&&review.comments[0];
      const sameRoot=value=>JSON.stringify(value.rootComment)===JSON.stringify(root)
        && value.threadId==="THREAD_full_cycle_1"&&value.replyTo==="777";
      process.exit(root&&sameRoot(reply)&&sameRoot(resolution)
        &&reply.body==="Fixed by the second TDD generation."
        &&resolution.reply===reply.body?0:1);
    ' \
  && ! grep -Eq '(^| )pr merge( |$)|(^| )release( |$)|(^| )deploy( |$)|(^| )workflow run( |$)' \
      "$FAKE_STATE/calls"; then
  check "F9 composed run performs one review write and no merge, release, or deploy" PASS
else
  check "F9 composed run performs one review write and no merge, release, or deploy" FAIL
fi

printf '%s\n' "----" "test-autopilot-full-cycle: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
