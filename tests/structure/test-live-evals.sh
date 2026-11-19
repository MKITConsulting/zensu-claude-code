#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LEDGER_JS="$ROOT/scripts/eval-usage-ledger.js"
RUN_LEDGER_JS="$ROOT/.github/scripts/live-evals-ledger.js"
WRAPPER="$ROOT/scripts/claude-promptfoo-wrapper.sh"
ZEN_PROVIDER="$ROOT/evals/zen-mode-reaction/provider.sh"
RUNNER="$ROOT/.github/scripts/live-evals.sh"
INSTALLER="$ROOT/.github/scripts/live-evals-install-claude-code.sh"
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

finish() {
  printf '%s\n' '----' "test-live-evals: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit
}

for tool in node jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    check "$tool is on PATH" FAIL
    finish
  fi
done
for file in "$LEDGER_JS" "$RUN_LEDGER_JS" "$WRAPPER" "$ZEN_PROVIDER" "$RUNNER" "$INSTALLER"; do
  if [ ! -f "$file" ]; then
    check "${file#"$ROOT"/} exists" FAIL
    finish
  fi
done

case "$(uname -s)" in
  (MINGW*|MSYS*|CYGWIN*)
    check "every executed check (skipped: live-evals.yml runs on ubuntu-latest only, and these checks need O_NOFOLLOW, real symbolic links, a named pipe and extensionless stubs started without a shell)" PASS
    finish
    ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/live-evals-test-XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/fixture" "$WORK/tmp"
BASE_PATH="/usr/bin:/bin:$(dirname "$(command -v node)"):$(dirname "$(command -v jq)")"
TOKEN='sk-ant-oat01-live-evals-test-credential'

cat > "$WORK/ok.jsonl" <<'JSON'
{"type":"system","subtype":"init","model":"claude-haiku-5-5"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-haiku-5-5","content":[{"type":"text","text":"OK"}]}}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1500,"num_turns":2,"result":"OK","total_cost_usd":0.0125,"usage":{"input_tokens":4,"cache_creation_input_tokens":40000,"cache_read_input_tokens":36000,"output_tokens":20},"modelUsage":{"claude-haiku-5-5":{}}}
JSON
cat > "$WORK/limit.jsonl" <<'JSON'
{"type":"assistant","message":{"id":"msg_2","model":"<synthetic>","content":[{"type":"text","text":"You've hit your weekly limit - resets Nov 16 at 5pm (Europe/Berlin)"}]}}
{"type":"result","subtype":"success","is_error":true,"result":"You've hit your weekly limit - resets Nov 16 at 5pm (Europe/Berlin)","total_cost_usd":0}
JSON
cat > "$WORK/error.jsonl" <<'JSON'
{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key - Please run /login","total_cost_usd":0}
JSON
: > "$WORK/empty.jsonl"

L="$WORK/ledger.jsonl"
node "$LEDGER_JS" append "$WORK/ok.jsonl" "$L" zen-mode-reaction 0
node "$LEDGER_JS" append "$WORK/limit.jsonl" "$L" zen-mode-reaction 1
GOT_OK="$(sed -n 1p "$L" | jq -c '{schema,suite,exit,result,is_error,limit_hit,cost_usd,duration_ms,num_turns,input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens,models}')"
WANT_OK='{"schema":"zensu-eval-usage-v1","suite":"zen-mode-reaction","exit":0,"result":true,"is_error":false,"limit_hit":false,"cost_usd":0.0125,"duration_ms":1500,"num_turns":2,"input_tokens":4,"output_tokens":20,"cache_read_input_tokens":36000,"cache_creation_input_tokens":40000,"models":["claude-haiku-5-5"]}'
if [ "$GOT_OK" = "$WANT_OK" ]; then
  check "L1 append records the suite, exit code, cost, tokens, turns and models of a result event" PASS
else
  check "L1 append records the result event (got: $GOT_OK)" FAIL
fi
if [ "$(sed -n 2p "$L" | jq -c '{exit,is_error,limit_hit,models}')" = '{"exit":1,"is_error":true,"limit_hit":true,"models":[]}' ]; then
  check "L2 append flags a synthetic usage-limit reply and keeps the synthetic model out of the models" PASS
else
  check "L2 append flags a synthetic usage-limit reply (got: $(sed -n 2p "$L"))" FAIL
fi

V_OK="$(node "$RUN_LEDGER_JS" probe "$WORK/ok.jsonl")"
V_LIMIT="$(node "$RUN_LEDGER_JS" probe "$WORK/limit.jsonl")"
V_ERROR="$(node "$RUN_LEDGER_JS" probe "$WORK/error.jsonl")"
V_EMPTY="$(node "$RUN_LEDGER_JS" probe "$WORK/empty.jsonl")"
if [ "$(printf '%s\n' "$V_OK" | sed -n 1p)" = verdict=ready ] \
  && [ "$(printf '%s\n' "$V_LIMIT" | sed -n 1p)" = verdict=limit ] \
  && printf '%s\n' "$V_LIMIT" | grep -qF 'reason=You'"'"'ve hit your weekly limit' \
  && [ "$(printf '%s\n' "$V_ERROR" | sed -n 1p)" = verdict=error ] \
  && printf '%s\n' "$V_ERROR" | grep -qF 'reason=Invalid API key' \
  && [ "$V_EMPTY" = "$(printf 'verdict=error\nreason=the probe printed no result event')" ]; then
  check "L3 probe reads a clean reply as ready, a usage limit as limit, and an error or an empty stream as error" PASS
else
  check "L3 probe verdicts (ok: $V_OK | limit: $V_LIMIT | error: $V_ERROR | empty: $V_EMPTY)" FAIL
fi

node "$LEDGER_JS" append "$WORK/ok.jsonl" relative.jsonl zen-mode-reaction 0 2>/dev/null
REL_RC=$?
printf 'untouched\n' > "$WORK/target.txt"
ln -s "$WORK/target.txt" "$WORK/link.jsonl"
node "$LEDGER_JS" append "$WORK/ok.jsonl" "$WORK/link.jsonl" zen-mode-reaction 0 2>/dev/null
LINK_RC=$?
node "$LEDGER_JS" append "$WORK/ok.jsonl" "$WORK/other.jsonl" '../escape' 0 2>/dev/null
NAME_RC=$?
node "$LEDGER_JS" probe "$WORK/ok.jsonl" >/dev/null 2>&1
VERB_RC=$?
if [ "$REL_RC" = 2 ] && [ "$LINK_RC" = 2 ] && [ "$NAME_RC" = 2 ] && [ "$VERB_RC" = 2 ] \
  && [ "$(cat "$WORK/target.txt")" = untouched ] && [ ! -e "$WORK/other.jsonl" ]; then
  check "L4 append refuses a relative ledger, a symbolic link and a suite name that is not a short token, and the plugin's ledger knows no verb but append" PASS
else
  check "L4 append refusals (relative=$REL_RC link=$LINK_RC name=$NAME_RC verb=$VERB_RC)" FAIL
fi

FIRST_BYTES="$(sed -n 1p "$L" | wc -c | tr -d ' ')"
TOTAL_BYTES="$(wc -c < "$L" | tr -d ' ')"
TALLY="$(node "$RUN_LEDGER_JS" tally "$L" zen-mode-reaction)"
TALLY_TAIL="$(node "$RUN_LEDGER_JS" tally "$L" zen-mode-reaction "$FIRST_BYTES")"
TALLY_END="$(node "$RUN_LEDGER_JS" tally "$L" zen-mode-reaction "$TOTAL_BYTES")"
node "$RUN_LEDGER_JS" tally "$L" zen-mode-reaction -1 >/dev/null 2>&1
BAD_OFFSET_RC=$?
if [ "$TALLY" = "$(printf 'calls=2\nlimit_hits=1')" ] && [ "$TALLY_TAIL" = "$(printf 'calls=1\nlimit_hits=1')" ] \
  && [ "$TALLY_END" = "$(printf 'calls=0\nlimit_hits=0')" ] && [ "$BAD_OFFSET_RC" = 2 ] \
  && [ "$(node "$RUN_LEDGER_JS" tally "$L" context-nudge-reaction)" = "$(printf 'calls=0\nlimit_hits=0')" ]; then
  check "L5 tally counts the calls and usage-limit hits of one suite from a byte offset and refuses a malformed offset" PASS
else
  check "L5 tally (all: $TALLY | tail: $TALLY_TAIL | end: $TALLY_END | bad offset rc=$BAD_OFFSET_RC)" FAIL
fi

SUMMARY="$(node "$RUN_LEDGER_JS" summarize "$L")"
if printf '%s\n' "$SUMMARY" | grep -qF '| zen-mode-reaction | 2 | 1 | 1 | 2 | 4 | 20 | 36,000 | 40,000 | $0.0125 |' \
  && printf '%s\n' "$SUMMARY" | grep -qF '| **Total** | 2 | 1 | 1 |' \
  && printf '%s\n' "$SUMMARY" | grep -qF 'Models seen: `claude-haiku-5-5`.' \
  && [ "$(node "$RUN_LEDGER_JS" summarize "$WORK/missing.jsonl")" = 'No eval calls were recorded.' ]; then
  check "L6 summarize renders a row per suite, a total row and the models, and says when nothing was recorded" PASS
else
  check "L6 summarize (got: $SUMMARY)" FAIL
fi

R="$WORK/results"
mkdir -p "$R/nested"
printf 'token=%s\n' "$TOKEN" > "$R/nested/leak.json"
printf '{"nested":true}\n' > "$R/nested/kept.json"
printf '{"clean":true}\n' > "$R/clean.json"
printf 'abc\n' > "$R/short.json"
ln -s "$WORK/target.txt" "$R/link.json"
mkfifo "$R/pipe"
STAGE_OUT="$(env -i PATH="$BASE_PATH" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" ANTHROPIC_API_KEY=abc node "$RUN_LEDGER_JS" stage "$R" "$WORK/staged")"
STAGE_RC=$?
STAGED="$(cd "$WORK/staged" 2>/dev/null && find . -print | LC_ALL=C sort | tr '\n' ' ')"
if [ "$STAGE_RC" = 1 ] && [ "$STAGED" = '. ./clean.json ./nested ./nested/kept.json ./short.json ' ] \
  && cmp -s "$R/clean.json" "$WORK/staged/clean.json" && cmp -s "$R/nested/kept.json" "$WORK/staged/nested/kept.json" \
  && [ -f "$R/nested/leak.json" ] && [ -L "$R/link.json" ] && [ "$(cat "$WORK/target.txt")" = untouched ] \
  && printf '%s\n' "$STAGE_OUT" | grep -qxF 'removed=nested/leak.json (held a credential value)' \
  && printf '%s\n' "$STAGE_OUT" | grep -qxF 'removed=link.json (symbolic link)' \
  && printf '%s\n' "$STAGE_OUT" | grep -qxF 'removed=pipe (not a regular file)' \
  && printf '%s\n' "$STAGE_OUT" | grep -qxF 'staged=complete' \
  && ! printf '%s\n' "$STAGE_OUT" | grep -qF "$TOKEN"; then
  check "L7 stage copies clean regular files, leaves out files that hold a credential value, symbolic links and other non-regular files, ignores a value too short to be a credential and never prints the value" PASS
else
  check "L7 stage (rc=$STAGE_RC, staged: $STAGED, out: $STAGE_OUT)" FAIL
fi

EMPTY_OUT="$(env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage "$WORK/no-results" "$WORK/empty-staged")"
EMPTY_RC=$?
env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage "$R" "$WORK/staged" >/dev/null 2>&1
AGAIN_RC=$?
env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage "$R" "$R/nested/up" >/dev/null 2>&1
INSIDE_RC=$?
env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage "$R" "$R/..up" >/dev/null 2>&1
DOTS_RC=$?
DOTS_SIBLING="$(env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage "$WORK/no-results" "$WORK/..dots-staged")"
DOTS_SIBLING_RC=$?
env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage results "$WORK/relative-staged" >/dev/null 2>&1
RELATIVE_RC=$?
LOCK_STATE=skipped
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$WORK/locked/sub"
  printf '{}\n' > "$WORK/locked/file.json"
  chmod 000 "$WORK/locked/sub" "$WORK/locked/file.json"
  LOCK_OUT="$(env -i PATH="$BASE_PATH" node "$RUN_LEDGER_JS" stage "$WORK/locked" "$WORK/locked-staged" 2>/dev/null)"
  LOCK_RC=$?
  chmod 700 "$WORK/locked/sub"
  chmod 600 "$WORK/locked/file.json"
  LOCK_STATE=bad
  if [ "$LOCK_RC" = 2 ] && printf '%s\n' "$LOCK_OUT" | grep -qxF 'refused=sub (EACCES)' \
    && printf '%s\n' "$LOCK_OUT" | grep -qxF 'refused=file.json (EACCES)' \
    && ! printf '%s\n' "$LOCK_OUT" | grep -qF 'staged=complete'; then
    LOCK_STATE=ok
  fi
fi
if [ "$EMPTY_RC" = 0 ] && [ "$EMPTY_OUT" = staged=complete ] && [ -d "$WORK/empty-staged" ] \
  && [ -z "$(ls -A "$WORK/empty-staged")" ] && [ "$AGAIN_RC" = 2 ] && [ "$INSIDE_RC" = 2 ] && [ ! -e "$R/nested/up" ] \
  && [ "$RELATIVE_RC" = 2 ] && [ ! -e "$WORK/relative-staged" ] && [ "$LOCK_STATE" != bad ] \
  && [ "$DOTS_RC" = 2 ] && [ ! -e "$R/..up" ] && [ "$DOTS_SIBLING_RC" = 0 ] && [ "$DOTS_SIBLING" = staged=complete ]; then
  check "L8 stage reports a missing results directory as complete and empty, refuses an existing, nested or relative upload directory, a nested one named with two leading dots included, accepts such a name beside the results, and reports an unreadable entry without completing (unreadable case: $LOCK_STATE)" PASS
else
  check "L8 stage refusals (empty=$EMPTY_RC again=$AGAIN_RC inside=$INSIDE_RC relative=$RELATIVE_RC dots=$DOTS_RC dots-sibling=$DOTS_SIBLING_RC unreadable=$LOCK_STATE)" FAIL
fi

printf '%s\n' '{"results":{"results":[{"success":true,"failureReason":0},{"success":false,"failureReason":1,"response":{"output":"wrong answer"}},{"success":false,"failureReason":1,"response":{"output":"Claude usage limit reached"}},{"success":false,"failureReason":2,"error":"Claude usage limit reached"},{"success":false,"failureReason":2,"error":"spawn failed"}]}}' > "$WORK/results.json"
printf 'not json\n' > "$WORK/broken.json"
RES="$(node "$RUN_LEDGER_JS" results "$WORK/results.json")"
RES_MISSING="$(node "$RUN_LEDGER_JS" results "$WORK/missing-results.json")"
RES_BROKEN="$(node "$RUN_LEDGER_JS" results "$WORK/broken.json")"
node "$RUN_LEDGER_JS" results relative.json >/dev/null 2>&1
RES_REL_RC=$?
RES_NONE="$(printf 'results=missing\npassed=0\nasserts_failed=0\nlimit_rows=0\nerrors=0')"
if [ "$RES" = "$(printf 'results=read\npassed=1\nasserts_failed=1\nlimit_rows=2\nerrors=1')" ] \
  && [ "$RES_MISSING" = "$RES_NONE" ] && [ "$RES_BROKEN" = "$RES_NONE" ] && [ "$RES_REL_RC" = 2 ]; then
  check "L9 results counts passed rows, assertion failures, usage-limit rows by their output or error text, and other errors, and reads a missing or broken file as missing" PASS
else
  check "L9 results (read: $RES | missing: $RES_MISSING | broken: $RES_BROKEN | relative rc=$RES_REL_RC)" FAIL
fi

mkdir -p "$WORK/race"
mkfifo "$WORK/race/swapped.json"
cat > "$WORK/race-listing.js" <<'JS'
const fs = require('node:fs');
const list = fs.readdirSync;
fs.readdirSync = (dir, options) => list(dir, options).map((entry) => (entry.name === 'swapped.json'
  ? { name: entry.name, isSymbolicLink: () => false, isDirectory: () => false, isFile: () => true }
  : entry));
JS
cat > "$WORK/race-run.js" <<'JS'
const { spawnSync } = require('node:child_process');
const [listing, ledger, from, to] = process.argv.slice(2);
const run = spawnSync(process.execPath, ['--require', listing, ledger, 'stage', from, to],
  { encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL' });
process.stdout.write(run.error ? `error=${run.error.code}\n` : `rc=${run.status}\n${run.stdout}`);
JS
RACE_OUT="$(env -i PATH="$BASE_PATH" node "$WORK/race-run.js" "$WORK/race-listing.js" "$RUN_LEDGER_JS" "$WORK/race" "$WORK/race-staged")"
if [ "$RACE_OUT" = "$(printf 'rc=1\nremoved=swapped.json (not a regular file)\nstaged=complete')" ] \
  && [ -d "$WORK/race-staged" ] && [ -z "$(ls -A "$WORK/race-staged")" ]; then
  check "L10 stage opens each file without blocking, so a named pipe that the directory listing reported as a regular file is left out instead of hanging the step" PASS
else
  check "L10 named pipe behind a regular-file listing (got: $RACE_OUT)" FAIL
fi

dry_run() {
  env -i PATH="$BASE_PATH" HOME="$WORK/home" DRY_RUN=1 "$@" bash "$WRAPPER" 'p' '{}' 2>&1
}
W_OUT="$(dry_run EVAL_CLAUDE_MODEL=claude-haiku-5-5)"
W_RC=$?
W_PLAIN="$(dry_run)"
if [ "$W_RC" = 0 ] && printf '%s\n' "$W_OUT" | grep -qE -- '--model +claude-haiku-5-5' \
  && ! printf '%s\n' "$W_PLAIN" | grep -qF -- '--model'; then
  check "W1 the wrapper passes EVAL_CLAUDE_MODEL as --model and passes no --model without it" PASS
else
  check "W1 wrapper model flag (rc=$W_RC, preview: ${W_OUT:0:300})" FAIL
fi
W_BAD=""
for value in '-x' 'a b' '$(id)' 'x;y' "$(printf 'm%.0s' $(seq 1 65))"; do
  OUT="$(dry_run EVAL_CLAUDE_MODEL="$value")"
  RC=$?
  if [ "$RC" != 64 ] || printf '%s\n' "$OUT" | grep -qF 'would execute'; then W_BAD="$W_BAD [$value rc=$RC]"; fi
done
if [ -z "$W_BAD" ]; then
  check "W2 the wrapper refuses a malformed or overlong model before it builds a command" PASS
else
  check "W2 wrapper model refusals:$W_BAD" FAIL
fi
OUT="$(dry_run EVAL_USAGE_LEDGER=relative.jsonl)"
if [ $? = 64 ] && printf '%s\n' "$OUT" | grep -qF 'EVAL_USAGE_LEDGER must be an absolute path'; then
  check "W3 the wrapper refuses a relative usage ledger" PASS
else
  check "W3 wrapper ledger refusal (got: ${OUT:0:200})" FAIL
fi

cat > "$WORK/bin/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_ARGS"
printf 'api_key=%s\n' "${ANTHROPIC_API_KEY+set}" > "$STUB_ARGS.env"
printf 'planted=%s\n' "${ZENSU_PLANTED+set}" > "$STUB_ARGS.zensu"
cat "$STUB_STREAM"
exit "${STUB_EXIT:-0}"
STUB
chmod 755 "$WORK/bin/claude"
W_LEDGER="$WORK/wrapper-ledger.jsonl"
W_RUN="$(env -i PATH="$WORK/bin:$BASE_PATH" HOME="$WORK/home" STUB_ARGS="$WORK/wrapper-args" STUB_STREAM="$WORK/ok.jsonl" \
  EVAL_CLAUDE_MODEL=claude-haiku-5-5 EVAL_USAGE_LEDGER="$W_LEDGER" EVAL_SUITE=context-nudge-reaction \
  bash "$WRAPPER" 'probe prompt' "{\"config\":{\"working_dir\":\"$WORK/fixture\"}}" 2>/dev/null)"
W_RUN_RC=$?
if [ "$W_RUN_RC" = 0 ] && printf '%s\n' "$W_RUN" | grep -qF '[result] OK' \
  && grep -qF -- '--model claude-haiku-5-5' "$WORK/wrapper-args" \
  && [ "$(jq -c '{suite,exit,cost_usd}' "$W_LEDGER")" = '{"suite":"context-nudge-reaction","exit":0,"cost_usd":0.0125}' ]; then
  check "W4 a wrapper run hands --model to claude and appends one ledger line for its suite" PASS
else
  check "W4 wrapper run (rc=$W_RUN_RC, ledger: $(cat "$W_LEDGER" 2>/dev/null))" FAIL
fi

W5_BAD=""
for value in claude-haiku-5-5 haiku 'claude-opus-5-5[1m]' 'us.anthropic.claude:1' '-x' '.x' 'a b' 'a/b' '$(id)' 'x;y' \
  "$(printf 'm%.0s' $(seq 1 64))" "$(printf 'm%.0s' $(seq 1 65))"; do
  dry_run EVAL_CLAUDE_MODEL="$value" >/dev/null
  RC=$?
  LINE="$(env -i PATH="$BASE_PATH" LIVE_EVALS_OUT="$WORK/none" EVAL_CLAUDE_MODEL="$value" bash "$RUNNER" summary | grep -F -- '- Model: ')"
  case "$RC:$LINE" in
    ("0:- Model: $value"|"64:- Model: invalid value") ;;
    (*) W5_BAD="$W5_BAD [$value: wrapper rc=$RC, runner '$LINE']" ;;
  esac
done
if [ -z "$W5_BAD" ]; then
  check "W5 the wrapper and the runner accept and refuse the same model names" PASS
else
  check "W5 the model name grammars disagree:$W5_BAD" FAIL
fi

Z_LEDGER="$WORK/zen-ledger.jsonl"
Z_RUN="$(env -i PATH="$WORK/bin:$BASE_PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" STUB_ARGS="$WORK/zen-args" \
  STUB_STREAM="$WORK/ok.jsonl" ZENSU_PLANTED=1 EVAL_CLAUDE_MODEL=claude-haiku-5-5 EVAL_USAGE_LEDGER="$Z_LEDGER" \
  EVAL_SUITE=zen-mode-reaction bash "$ZEN_PROVIDER" 'zen prompt' "{\"config\":{\"working_dir\":\"$WORK/fixture\"}}" 2>&1)"
Z_RC=$?
if [ "$Z_RC" = 0 ] && grep -qF -- '--model claude-haiku-5-5' "$WORK/zen-args" && grep -qF -- '--settings' "$WORK/zen-args" \
  && [ "$(cat "$WORK/zen-args.zensu")" = planted= ] \
  && [ "$(jq -c '{suite,exit}' "$Z_LEDGER")" = '{"suite":"zen-mode-reaction","exit":0}' ]; then
  check "W6 the zen-mode provider scrubs ZENSU_ variables but keeps the eval model, ledger and suite, so its wrapper run passes --model and records one ledger line" PASS
else
  check "W6 zen-mode provider (rc=$Z_RC, out: ${Z_RUN:0:300}, args: $(cat "$WORK/zen-args" 2>/dev/null))" FAIL
fi

runner() {
  env -i PATH="$WORK/bin:$BASE_PATH" HOME="$WORK/home" LIVE_EVALS_OUT="$WORK/out" GITHUB_OUTPUT="$WORK/gh-output" \
    STUB_ARGS="$WORK/stub-args" "$@" bash "$RUNNER" probe 2>&1
}
reset_runner() {
  rm -rf "$WORK/out" "$WORK/gh-output" "$WORK/stub-args" "$WORK/stub-args.env" "$WORK/stub-args.zensu"
}

reset_runner
P_OUT="$(runner)"
P_RC=$?
if [ "$P_RC" = 1 ] && printf '%s\n' "$P_OUT" | grep -qF 'CLAUDE_CODE_OAUTH_TOKEN' \
  && printf '%s\n' "$P_OUT" | grep -qF 'ANTHROPIC_API_KEY' && [ ! -e "$WORK/gh-output" ] && [ ! -e "$WORK/stub-args" ]; then
  check "P1 the probe stops with an error naming both secrets when neither is set" PASS
else
  check "P1 probe without credentials (rc=$P_RC, out: $P_OUT)" FAIL
fi

reset_runner
P_OUT="$(runner CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" STUB_STREAM="$WORK/limit.jsonl" STUB_EXIT=1)"
P_RC=$?
if [ "$P_RC" = 0 ] && [ "$(cat "$WORK/gh-output")" = 'ready=false' ] \
  && printf '%s\n' "$P_OUT" | grep -qF '::warning::Claude usage limit reached, suites skipped' \
  && grep -qF 'Usage limit reached before the run' "$WORK/out/notice.md"; then
  check "P2 a usage limit in the probe writes ready=false, a warning and a notice, and exits 0" PASS
else
  check "P2 probe at the usage limit (rc=$P_RC, out: $P_OUT)" FAIL
fi

reset_runner
P_OUT="$(runner CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" ANTHROPIC_API_KEY= EVAL_CLAUDE_MODEL=haiku STUB_STREAM="$WORK/ok.jsonl")"
P_RC=$?
if [ "$P_RC" = 0 ] && [ "$(cat "$WORK/gh-output")" = 'ready=true' ] \
  && grep -qF -- '--no-session-persistence' "$WORK/stub-args" && grep -qF -- '--model haiku' "$WORK/stub-args" \
  && [ "$(cat "$WORK/stub-args.env")" = 'api_key=' ] \
  && [ "$(jq -r .suite "$WORK/out/usage.jsonl")" = probe ]; then
  check "P3 a clean probe writes ready=true, passes the model, drops an empty API key and records itself in the ledger" PASS
else
  check "P3 clean probe (rc=$P_RC, out: $P_OUT, args: $(cat "$WORK/stub-args" 2>/dev/null))" FAIL
fi

reset_runner
P_OUT="$(runner ANTHROPIC_API_KEY="$TOKEN" STUB_STREAM="$WORK/error.jsonl" STUB_EXIT=1)"
P_RC=$?
if [ "$P_RC" = 1 ] && printf '%s\n' "$P_OUT" | grep -qF '::error::the Claude probe failed with exit 1: Invalid API key' \
  && ! grep -qF 'ready=' "$WORK/gh-output" 2>/dev/null; then
  check "P4 any other probe error fails the step and writes no ready output" PASS
else
  check "P4 failing probe (rc=$P_RC, out: $P_OUT)" FAIL
fi

reset_runner
P_OUT="$(runner CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" EVAL_CLAUDE_MODEL='x y' STUB_STREAM="$WORK/ok.jsonl")"
P_RC=$?
if [ "$P_RC" = 1 ] && printf '%s\n' "$P_OUT" | grep -qF 'EVAL_CLAUDE_MODEL must be a model alias' && [ ! -e "$WORK/stub-args" ]; then
  check "P5 the probe refuses a malformed model before claude starts" PASS
else
  check "P5 malformed model (rc=$P_RC, out: $P_OUT)" FAIL
fi

reset_runner
mkdir -p "$WORK/out"
printf '{"schema":"zensu-eval-usage-v1","suite":"zen-mode-reaction","limit_hit":true}\n' > "$WORK/out/usage.jsonl"
printf -- '- An earlier notice.\n' > "$WORK/out/notice.md"
printf 'zen-mode-reaction\tpassed\t0\n' > "$WORK/out/suites.tsv"
P_OUT="$(runner CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" STUB_STREAM="$WORK/ok.jsonl")"
P_RC=$?
if [ "$P_RC" = 0 ] && [ "$(wc -l < "$WORK/out/usage.jsonl" | tr -d ' ')" = 1 ] \
  && [ "$(jq -r .suite "$WORK/out/usage.jsonl")" = probe ] && [ ! -e "$WORK/out/notice.md" ] && [ ! -e "$WORK/out/suites.tsv" ]; then
  check "P6 the probe starts a run: it drops the ledger, notice and suite table an earlier run left in the results directory" PASS
else
  check "P6 probe reset (rc=$P_RC, out: $P_OUT, ledger: $(cat "$WORK/out/usage.jsonl" 2>/dev/null))" FAIL
fi

cat > "$WORK/bin/promptfoo" <<'STUB'
#!/bin/bash
suite="$(basename "$PWD")"
home="${PROMPTFOO_CONFIG_DIR:-unset}"
[ -d "$home" ] || home="$home(missing)"
printf '%s %s %s %s %s\n' "$suite" "${EVAL_SUITE:-}" "$home" "${PROMPTFOO_DISABLE_TELEMETRY:-unset}" \
  "${PROMPTFOO_DISABLE_UPDATE:-unset}" >> "$STUB_CALLS"
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then out="$2"; shift; fi
  shift
done
mode="$(printf '%s\n' "${STUB_MODES:-}" | tr ' ' '\n' | sed -n "s/^$suite=//p")"
case "$mode" in
  (limit|limitassert|limitcrash) node "$STUB_LEDGER_JS" append "$STUB_LIMIT" "$EVAL_USAGE_LEDGER" "$EVAL_SUITE" 1 ;;
  (mixed)
    node "$STUB_LEDGER_JS" append "$STUB_OK" "$EVAL_USAGE_LEDGER" "$EVAL_SUITE" 0
    node "$STUB_LEDGER_JS" append "$STUB_LIMIT" "$EVAL_USAGE_LEDGER" "$EVAL_SUITE" 1
    ;;
  (*) node "$STUB_LEDGER_JS" append "$STUB_OK" "$EVAL_USAGE_LEDGER" "$EVAL_SUITE" 0 ;;
esac
pass='{"success":true,"failureReason":0,"response":{"output":"OK"}}'
wrong='{"success":false,"failureReason":1,"response":{"output":"wrong answer"}}'
limited='{"success":false,"failureReason":2,"error":"Claude usage limit reached"}'
case "$mode" in
  (limitcrash) exit 1 ;;
  (fail) rows="$wrong" ;;
  (limit) rows="$limited" ;;
  (limitassert|limittext) rows='{"success":false,"failureReason":1,"response":{"output":"Claude usage limit reached"}}' ;;
  (mixed) rows="$wrong,$limited" ;;
  (leak) rows="{\"success\":true,\"failureReason\":0,\"response\":{\"output\":\"$CLAUDE_CODE_OAUTH_TOKEN\"}}" ;;
  (*) rows="$pass" ;;
esac
printf '{"results":{"results":[%s]}}\n' "$rows" > "$out"
case "$mode" in
  (fail|limit|limitassert|limittext|mixed) exit 100 ;;
esac
exit 0
STUB
chmod 755 "$WORK/bin/promptfoo"
PF_ENV="$WORK/out/promptfoo-home 1 1"

run_in_out() {
  rm -f "$WORK/stub-calls"
  env -i PATH="$WORK/bin:$BASE_PATH" HOME="$WORK/home" LIVE_EVALS_OUT="$WORK/out" \
    LIVE_EVALS_PROMPTFOO="$WORK/bin/promptfoo" STUB_CALLS="$WORK/stub-calls" STUB_OK="$WORK/ok.jsonl" \
    STUB_LIMIT="$WORK/limit.jsonl" STUB_LEDGER_JS="$LEDGER_JS" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" "$@" \
    bash "$RUNNER" run 2>&1
}
run_suites() {
  rm -rf "$WORK/out"
  run_in_out "$@"
}

R_OUT="$(run_suites PROMPTFOO_CONFIG_DIR="$WORK/home/.promptfoo" PROMPTFOO_DISABLE_TELEMETRY=0 PROMPTFOO_DISABLE_UPDATE=0)"
R_RC=$?
R_CALLS="$(cat "$WORK/stub-calls" 2>/dev/null)"
if [ "$R_RC" = 0 ] \
  && [ "$(cat "$WORK/out/suites.tsv")" = "$(printf 'zen-mode-reaction\tpassed\t0\ncontext-nudge-reaction\tpassed\t0')" ] \
  && [ "$R_CALLS" = "$(printf 'zen-mode-reaction zen-mode-reaction %s\ncontext-nudge-reaction context-nudge-reaction %s' "$PF_ENV" "$PF_ENV")" ] \
  && [ -f "$WORK/out/zen-mode-reaction.json" ] && [ -f "$WORK/out/context-nudge-reaction.json" ]; then
  check "R1 the run executes every registered suite from its own directory with its suite name and a results file, in a promptfoo home inside the results directory with telemetry and update checks off, whatever the caller set" PASS
else
  check "R1 run of all suites (rc=$R_RC, calls: $R_CALLS, out: $R_OUT)" FAIL
fi

R_OUT="$(run_suites STUB_MODES=zen-mode-reaction=limit)"
R_RC=$?
if [ "$R_RC" = 0 ] \
  && [ "$(cat "$WORK/out/suites.tsv")" = "$(printf 'zen-mode-reaction\tinconclusive\t100\ncontext-nudge-reaction\tskipped\t-')" ] \
  && [ "$(wc -l < "$WORK/stub-calls" | tr -d ' ')" = 1 ] \
  && grep -qF 'Usage limit reached during zen-mode-reaction' "$WORK/out/notice.md" \
  && printf '%s\n' "$R_OUT" | grep -qF '::warning::Claude usage limit reached during zen-mode-reaction'; then
  check "R2 a usage limit inside a suite marks it inconclusive, skips the later suites and keeps the step green" PASS
else
  check "R2 usage limit mid-run (rc=$R_RC, out: $R_OUT)" FAIL
fi

R_OUT="$(run_suites STUB_MODES=zen-mode-reaction=fail)"
R_RC=$?
if [ "$R_RC" = 1 ] \
  && [ "$(cat "$WORK/out/suites.tsv")" = "$(printf 'zen-mode-reaction\tfailed\t100\ncontext-nudge-reaction\tpassed\t0')" ] \
  && printf '%s\n' "$R_OUT" | grep -qF '::error::zen-mode-reaction failed with promptfoo exit 100'; then
  check "R3 a real eval failure runs the remaining suites and fails the step" PASS
else
  check "R3 failing suite (rc=$R_RC, out: $R_OUT)" FAIL
fi

R_OUT="$(run_suites EVAL_SUITES=context-nudge-reaction)"
R_RC=$?
R_ONE_CALLS="$(cat "$WORK/stub-calls" 2>/dev/null)"
R_BOGUS="$(run_suites EVAL_SUITES=bogus)"
R_BOGUS_RC=$?
if [ "$R_RC" = 0 ] && [ "$R_ONE_CALLS" = "context-nudge-reaction context-nudge-reaction $PF_ENV" ] \
  && [ "$R_BOGUS_RC" = 1 ] && printf '%s\n' "$R_BOGUS" | grep -qF "unknown suite 'bogus'" && [ ! -e "$WORK/stub-calls" ]; then
  check "R4 a dispatch can run one suite, and an unknown suite stops the step before any suite runs" PASS
else
  check "R4 suite selection (rc=$R_RC/$R_BOGUS_RC, out: $R_OUT $R_BOGUS)" FAIL
fi

R_OUT="$(run_suites LIVE_EVALS_PROMPTFOO="$WORK/bin/missing-promptfoo")"
R_RC=$?
if [ "$R_RC" = 1 ] && printf '%s\n' "$R_OUT" | grep -qF 'promptfoo is not installed'; then
  check "R5 the run stops when the pinned promptfoo is missing" PASS
else
  check "R5 missing promptfoo (rc=$R_RC, out: $R_OUT)" FAIL
fi

R_OUT="$(run_suites STUB_MODES=zen-mode-reaction=mixed)"
R_RC=$?
if [ "$R_RC" = 1 ] \
  && [ "$(cat "$WORK/out/suites.tsv")" = "$(printf 'zen-mode-reaction\tfailed\t100\ncontext-nudge-reaction\tskipped\t-')" ] \
  && printf '%s\n' "$R_OUT" | grep -qF '::error::zen-mode-reaction failed with promptfoo exit 100' \
  && printf '%s\n' "$R_OUT" | grep -qF '::warning::Claude usage limit reached during zen-mode-reaction'; then
  check "R6 an assertion failure in a suite that also hit the usage limit fails the step, and the later suites are still skipped" PASS
else
  check "R6 failure beside a usage limit (rc=$R_RC, out: $R_OUT)" FAIL
fi

R_OUT="$(run_suites STUB_MODES=zen-mode-reaction=limitassert)"
R_RC=$?
if [ "$R_RC" = 0 ] \
  && [ "$(cat "$WORK/out/suites.tsv")" = "$(printf 'zen-mode-reaction\tinconclusive\t100\ncontext-nudge-reaction\tskipped\t-')" ]; then
  check "R7 an assertion that failed on usage-limit text counts as inconclusive, not as an eval failure" PASS
else
  check "R7 limit text in a failed assertion (rc=$R_RC, out: $R_OUT)" FAIL
fi

run_suites STUB_MODES=zen-mode-reaction=limit >/dev/null 2>&1
R_OUT="$(run_in_out)"
R_RC=$?
R8_FIRST="$(cat "$WORK/out/suites.tsv")"
run_suites STUB_MODES=zen-mode-reaction=fail >/dev/null 2>&1
R_OUT2="$(run_in_out STUB_MODES=zen-mode-reaction=limitcrash)"
R_RC2=$?
R8_SECOND="$(cat "$WORK/out/suites.tsv")"
if [ "$R_RC" = 0 ] && [ "$R8_FIRST" = "$(printf 'zen-mode-reaction\tpassed\t0\ncontext-nudge-reaction\tpassed\t0')" ] \
  && [ "$R_RC2" = 0 ] && [ "$R8_SECOND" = "$(printf 'zen-mode-reaction\tinconclusive\t1\ncontext-nudge-reaction\tskipped\t-')" ]; then
  check "R8 a second run in the same results directory judges each suite by its own ledger lines and its own results file" PASS
else
  check "R8 rerun in one results directory (rc=$R_RC/$R_RC2, first: $R8_FIRST, second: $R8_SECOND, out: $R_OUT $R_OUT2)" FAIL
fi

R_OUT="$(run_suites STUB_MODES=zen-mode-reaction=limittext)"
R_RC=$?
if [ "$R_RC" = 1 ] \
  && [ "$(cat "$WORK/out/suites.tsv")" = "$(printf 'zen-mode-reaction\tfailed\t100\ncontext-nudge-reaction\tpassed\t0')" ] \
  && printf '%s\n' "$R_OUT" | grep -qF '::error::zen-mode-reaction failed with promptfoo exit 100' \
  && ! grep -qF 'Usage limit reached during' "$WORK/out/notice.md" 2>/dev/null; then
  check "R9 usage-limit text in a failed answer, without a limit hit in the ledger, fails the suite and skips no later suite" PASS
else
  check "R9 limit text without a ledger limit hit (rc=$R_RC, out: $R_OUT)" FAIL
fi

run_suites >/dev/null 2>&1
S_OUT="$(env -i PATH="$BASE_PATH" LIVE_EVALS_OUT="$WORK/out" CLAUDE_CODE_VERSION=2.1.400 bash "$RUNNER" summary)"
S_BAD="$(env -i PATH="$BASE_PATH" LIVE_EVALS_OUT="$WORK/none" CLAUDE_CODE_VERSION='9; rm' EVAL_CLAUDE_MODEL='$(id)' EVAL_SUITES='<b>' bash "$RUNNER" summary)"
if printf '%s\n' "$S_OUT" | grep -qxF -- '- Claude Code: 2.1.400, the newest release at run time' \
  && printf '%s\n' "$S_OUT" | grep -qxF -- '- Model: account default' \
  && printf '%s\n' "$S_OUT" | grep -qxF '| zen-mode-reaction | passed | 0 |' \
  && printf '%s\n' "$S_OUT" | grep -qF '| **Total** | 2 |' \
  && printf '%s\n' "$S_BAD" | grep -qxF -- '- Claude Code: not installed' \
  && printf '%s\n' "$S_BAD" | grep -qxF -- '- Model: invalid value' \
  && printf '%s\n' "$S_BAD" | grep -qxF -- '- Suites requested: invalid value' \
  && printf '%s\n' "$S_BAD" | grep -qxF 'No suite ran.' \
  && printf '%s\n' "$S_BAD" | grep -qxF 'No eval calls were recorded.'; then
  check "S1 the summary names the Claude Code version, the model and every suite, and never prints an unvalidated value" PASS
else
  check "S1 summary (got: $S_OUT || $S_BAD)" FAIL
fi

scrub() {
  rm -f "$WORK/gh-output"
  env -i PATH="$BASE_PATH" HOME="$WORK/home" LIVE_EVALS_OUT="$WORK/out" LIVE_EVALS_UPLOAD="$WORK/upload" \
    GITHUB_OUTPUT="$WORK/gh-output" CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" "$@" bash "$RUNNER" scrub 2>&1
}

run_suites STUB_MODES=zen-mode-reaction=leak >/dev/null 2>&1
ln -s "$WORK/target.txt" "$WORK/out/link.json"
rm -rf "$WORK/upload"
C_OUT="$(scrub)"
C_RC=$?
if [ "$C_RC" = 1 ] && [ "$(cat "$WORK/gh-output" 2>/dev/null)" = scrubbed=true ] \
  && [ -f "$WORK/upload/context-nudge-reaction.json" ] && [ -f "$WORK/upload/usage.jsonl" ] \
  && [ ! -e "$WORK/upload/zen-mode-reaction.json" ] && [ ! -e "$WORK/upload/link.json" ] && [ ! -L "$WORK/upload/link.json" ] \
  && printf '%s\n' "$C_OUT" | grep -qxF '::error::Removed from the results: zen-mode-reaction.json (held a credential value)' \
  && printf '%s\n' "$C_OUT" | grep -qxF '::error::Removed from the results: link.json (symbolic link)' \
  && ! printf '%s\n' "$C_OUT" | grep -qF "$TOKEN" && ! grep -rqF "$TOKEN" "$WORK/upload"; then
  check "C1 the scrub stages every clean file for upload, leaves out a results file that holds a credential value and a symbolic link, writes scrubbed=true and fails the step" PASS
else
  check "C1 scrub of a leaked credential (rc=$C_RC, out: $C_OUT)" FAIL
fi

C2_STATE=skipped
if [ "$(id -u)" != 0 ]; then
  run_suites >/dev/null 2>&1
  mkdir -p "$WORK/out/locked"
  chmod 000 "$WORK/out/locked"
  rm -rf "$WORK/upload"
  C_OUT="$(scrub)"
  C_RC=$?
  chmod 700 "$WORK/out/locked"
  C2_STATE=bad
  if [ "$C_RC" = 1 ] && ! grep -qF scrubbed "$WORK/gh-output" 2>/dev/null \
    && printf '%s\n' "$C_OUT" | grep -qxF '::error::Could not scrub: locked (EACCES)' \
    && printf '%s\n' "$C_OUT" | grep -qxF '::error::the results were not scrubbed completely, so nothing is uploaded'; then
    C2_STATE=ok
  fi
fi
if [ "$C2_STATE" != bad ]; then
  check "C2 an entry the scrub cannot read fails the step without scrubbed=true, so nothing is uploaded ($C2_STATE)" PASS
else
  check "C2 unreadable entry (rc=$C_RC, out: $C_OUT)" FAIL
fi

run_suites >/dev/null 2>&1
rm -rf "$WORK/upload"
C_OUT="$(scrub)"
C_RC=$?
C_GH="$(cat "$WORK/gh-output" 2>/dev/null)"
C_AGAIN="$(scrub)"
C_AGAIN_RC=$?
C_AGAIN_GH="$(cat "$WORK/gh-output" 2>/dev/null)"
C_INSIDE="$(scrub LIVE_EVALS_UPLOAD="$WORK/out/upload")"
C_INSIDE_RC=$?
C_INSIDE_GH="$(cat "$WORK/gh-output" 2>/dev/null)"
C_RELATIVE="$(scrub LIVE_EVALS_UPLOAD=upload)"
C_RELATIVE_RC=$?
if [ "$C_RC" = 0 ] && [ "$C_GH" = scrubbed=true ] && [ -f "$WORK/upload/zen-mode-reaction.json" ] \
  && [ -f "$WORK/upload/context-nudge-reaction.json" ] && ! printf '%s\n' "$C_OUT" | grep -qF '::error::' \
  && [ "$C_AGAIN_RC" = 1 ] && [ -z "$C_AGAIN_GH" ] && printf '%s\n' "$C_AGAIN" | grep -qF 'the upload directory already exists' \
  && [ "$C_INSIDE_RC" = 1 ] && [ -z "$C_INSIDE_GH" ] && [ ! -e "$WORK/out/upload" ] \
  && [ "$C_RELATIVE_RC" = 2 ] && printf '%s\n' "$C_RELATIVE" | grep -qF 'the upload directory must be an absolute path'; then
  check "C3 a clean scrub stages every file, writes scrubbed=true and passes, and an existing, nested or relative upload directory is refused" PASS
else
  check "C3 clean scrub and refusals (rc=$C_RC/$C_AGAIN_RC/$C_INSIDE_RC/$C_RELATIVE_RC, out: $C_OUT | $C_AGAIN | $C_INSIDE | $C_RELATIVE)" FAIL
fi

mkdir -p "$WORK/npm-bin"
cat > "$WORK/npm-bin/npm" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_NPM_LOG"
if [ "$1" = view ]; then
  printf '%s\n' "$STUB_VERSION"
  exit 0
fi
if [ "$1" = install ]; then
  mkdir -p node_modules/@anthropic-ai/claude-code node_modules/.bin
  printf '#!/bin/sh\necho other\n' > node_modules/.bin/other-tool
  chmod 755 node_modules/.bin/other-tool
  cat > node_modules/@anthropic-ai/claude-code/install.cjs <<'JS'
const fs = require("fs");
const body = "#!/bin/sh\necho \"" + process.env.STUB_REPORTED + " (Claude Code)\"\n";
fs.writeFileSync("node_modules/.bin/claude", body, { mode: 0o755 });
JS
  node -e '
    const fs = require("fs");
    const v = process.env.STUB_VERSION;
    const npm = "https://registry.npmjs.org/";
    const packages = {
      "": { dependencies: {} },
      "node_modules/@anthropic-ai/claude-code": { version: v, resolved: npm + "@anthropic-ai/claude-code/-/claude-code-" + v + ".tgz", hasInstallScript: true },
      "node_modules/@anthropic-ai/claude-code-linux-x64": { version: v, resolved: npm + "@anthropic-ai/claude-code-linux-x64/-/claude-code-linux-x64-" + v + ".tgz", optional: true },
    };
    if (process.env.STUB_SECOND_SCRIPT === "1") packages["node_modules/evil"] = { version: "1.0.0", resolved: npm + "evil/-/evil-1.0.0.tgz", hasInstallScript: true };
    if (process.env.STUB_FOREIGN === "1") packages["node_modules/left-pad"] = { version: "1.3.0", resolved: "https://registry.example.invalid/left-pad/-/left-pad-1.3.0.tgz" };
    fs.writeFileSync("package-lock.json", JSON.stringify({ lockfileVersion: 3, packages }));
  '
  exit 0
fi
exit 1
STUB
chmod 755 "$WORK/npm-bin/npm"

install_canary() {
  rm -rf "$WORK/runner-temp" "$WORK/gh-path" "$WORK/gh-output" "$WORK/npm-log"
  mkdir -p "$WORK/runner-temp"
  env -i PATH="$WORK/npm-bin:$BASE_PATH" HOME="$WORK/home" RUNNER_TEMP="$WORK/runner-temp" GITHUB_PATH="$WORK/gh-path" \
    GITHUB_OUTPUT="$WORK/gh-output" STUB_NPM_LOG="$WORK/npm-log" "$@" bash "$INSTALLER" 2>&1
}
canary_ran_install() {
  for dest in "$WORK/runner-temp"/claude-code-newest-*; do
    [ -e "$dest/node_modules/.bin/claude" ] && return 0
  done
  return 1
}

I_OUT="$(install_canary STUB_VERSION=2.1.400 STUB_REPORTED=2.1.400)"
I_RC=$?
I_BIN="$(cat "$WORK/gh-path" 2>/dev/null)"
if [ "$I_RC" = 0 ] && [ "$(cat "$WORK/gh-output")" = 'version=2.1.400' ] && [ -n "$I_BIN" ] \
  && [ "$(ls -A "$I_BIN")" = claude ] && [ -L "$I_BIN/claude" ] && [ "$("$I_BIN/claude" --version)" = '2.1.400 (Claude Code)' ] \
  && [ "$(sed -n 1p "$WORK/npm-log")" = 'view @anthropic-ai/claude-code version' ] \
  && [ "$(sed -n 2p "$WORK/npm-log")" = 'install --ignore-scripts --no-fund --no-audit' ] \
  && [ "$(jq -c .dependencies "$(dirname "$I_BIN")/package.json")" = '{"@anthropic-ai/claude-code":"2.1.400"}' ]; then
  check "I1 the canary installs exactly the newest release with install scripts off, runs install.cjs, and puts only the claude command on PATH with its version as output" PASS
else
  check "I1 canary install (rc=$I_RC, path: $I_BIN, out: $I_OUT)" FAIL
fi

I_BAD=""
OUT="$(install_canary STUB_VERSION=2.1.400 STUB_REPORTED=2.1.400 STUB_SECOND_SCRIPT=1)"
RC=$?
if [ "$RC" != 1 ] || ! printf '%s\n' "$OUT" | grep -qF 'node_modules/evil' || [ -s "$WORK/gh-path" ] || canary_ran_install; then
  I_BAD="$I_BAD [second install script rc=$RC]"
fi
OUT="$(install_canary STUB_VERSION=2.1.400 STUB_REPORTED=2.1.400 STUB_FOREIGN=1)"
RC=$?
if [ "$RC" != 1 ] || ! printf '%s\n' "$OUT" | grep -qF 'that are not @anthropic-ai/claude-code packages on the npm registry: node_modules/left-pad' \
  || [ -s "$WORK/gh-path" ] || canary_ran_install; then
  I_BAD="$I_BAD [foreign registry rc=$RC]"
fi
OUT="$(install_canary STUB_VERSION=2.1.400 STUB_REPORTED=2.1.399)"
RC=$?
if [ "$RC" != 1 ] || ! printf '%s\n' "$OUT" | grep -qF 'installed as "2.1.399 (Claude Code)", not 2.1.400' || [ -s "$WORK/gh-path" ]; then
  I_BAD="$I_BAD [version mismatch rc=$RC]"
fi
for version in latest '' '2.1.400-beta.1'; do
  OUT="$(install_canary STUB_VERSION="$version" STUB_REPORTED=2.1.400)"
  RC=$?
  if [ "$RC" != 1 ] || ! printf '%s\n' "$OUT" | grep -qF 'reported no plain release version' \
    || grep -qF install "$WORK/npm-log"; then I_BAD="$I_BAD [version '$version' rc=$RC]"; fi
done
if [ -z "$I_BAD" ]; then
  check "I2 the canary refuses a second install script and a package from outside the Claude Code packages on the npm registry before install.cjs runs, a version mismatch, and anything but a plain release version" PASS
else
  check "I2 canary refusals:$I_BAD" FAIL
fi

finish
