#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
LEDGER_JS="$ROOT/scripts/eval-usage-ledger.js"
RUN_LEDGER_JS="$ROOT/.github/scripts/live-evals-ledger.js"
PROMPTFOO="${LIVE_EVALS_PROMPTFOO:-$ROOT/node_modules/.bin/promptfoo}"
OUT="${LIVE_EVALS_OUT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/live-evals}"
UPLOAD="${LIVE_EVALS_UPLOAD:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/live-evals-upload}"
LEDGER="$OUT/usage.jsonl"
STATUS="$OUT/suites.tsv"
NOTICE="$OUT/notice.md"
SUITES='zen-mode-reaction context-nudge-reaction'
PROBE_PROMPT='Reply with the single word OK.'

die() {
  printf '::error::%s\n' "$1"
  exit "${2:-1}"
}

absolute() {
  case "$1" in
    (/*) return 0 ;;
  esac
  return 1
}

model_ok() {
  case "$1" in
    ([!A-Za-z0-9]*|*[!]A-Za-z0-9._:[-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

check_model() {
  if [ -z "${EVAL_CLAUDE_MODEL:-}" ]; then
    unset EVAL_CLAUDE_MODEL
    return 0
  fi
  model_ok "$EVAL_CLAUDE_MODEL" \
    || die 'EVAL_CLAUDE_MODEL must be a model alias or id of at most 64 letters, digits and . _ : - [ ]'
  export EVAL_CLAUDE_MODEL
}

check_credentials() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || unset CLAUDE_CODE_OAUTH_TOKEN
  [ -n "${ANTHROPIC_API_KEY:-}" ] || unset ANTHROPIC_API_KEY
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] \
    || die 'No Claude credential: set the live-evals environment secret CLAUDE_CODE_OAUTH_TOKEN (from claude setup-token) or ANTHROPIC_API_KEY.'
}

prepare_out() {
  absolute "$OUT" || die "the results directory must be an absolute path: $OUT" 2
  if ! mkdir -p "$OUT" || ! chmod 700 "$OUT"; then
    die "cannot prepare the results directory $OUT"
  fi
}

gh_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  else
    printf '%s\n' "$1"
  fi
}

field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

ledger_size() {
  if [ -f "$LEDGER" ]; then
    wc -c < "$LEDGER" | tr -d ' '
  else
    echo 0
  fi
}

cmd_probe() {
  check_credentials
  check_model
  prepare_out
  rm -f "$LEDGER" "$NOTICE" "$STATUS" "$OUT/probe.jsonl" "$OUT/probe.stderr" \
    || die "cannot reset the results directory $OUT"
  command -v claude >/dev/null 2>&1 || die 'claude is not on PATH; the install step did not run'
  local work rc result verdict reason
  local cmd=(claude --print --output-format stream-json --verbose --no-session-persistence)
  if [ -n "${EVAL_CLAUDE_MODEL:-}" ]; then
    cmd+=(--model "$EVAL_CLAUDE_MODEL")
  fi
  cmd+=("$PROBE_PROMPT")
  work="$(mktemp -d "$OUT/probe-cwd-XXXXXX")" || die 'cannot create the probe directory'
  (cd "$work" && "${cmd[@]}" < /dev/null) > "$OUT/probe.jsonl" 2> "$OUT/probe.stderr"
  rc=$?
  rm -rf "$work"
  node "$LEDGER_JS" append "$OUT/probe.jsonl" "$LEDGER" probe "$rc" \
    || die 'cannot record the probe in the usage ledger'
  result="$(node "$RUN_LEDGER_JS" probe "$OUT/probe.jsonl")" || die 'cannot read the probe output'
  verdict="$(field "$result" verdict)"
  reason="$(field "$result" reason)"
  case "$verdict" in
    (ready)
      [ "$rc" -eq 0 ] || die "the Claude probe exited $rc: ${reason:-no reason given}"
      gh_output 'ready=true'
      printf 'Claude probe ready with %s.\n' "${EVAL_CLAUDE_MODEL:-the account default model}"
      ;;
    (limit)
      gh_output 'ready=false'
      printf -- '- Usage limit reached before the run: %s. The suites were skipped.\n' "$reason" >> "$NOTICE"
      printf '::warning::Claude usage limit reached, suites skipped: %s\n' "$reason"
      ;;
    (*)
      tail -n 20 "$OUT/probe.stderr" >&2
      die "the Claude probe failed with exit $rc: ${reason:-no reason given}"
      ;;
  esac
}

cmd_run() {
  check_credentials
  check_model
  prepare_out
  [ -x "$PROMPTFOO" ] || die "promptfoo is not installed at $PROMPTFOO; run npm ci first"
  local selection="${EVAL_SUITES:-all}" chosen suite rc offset tally hits report asserts status
  local stopped="" failures=0
  if [ "$selection" = all ]; then
    chosen="$SUITES"
  else
    case " $SUITES " in
      (*" $selection "*) chosen="$selection" ;;
      (*) die "unknown suite '$selection'; pick all or one of: $SUITES" ;;
    esac
  fi
  export EVAL_USAGE_LEDGER="$LEDGER"
  export PROMPTFOO_CONFIG_DIR="$OUT/promptfoo-home"
  export PROMPTFOO_DISABLE_TELEMETRY=1
  export PROMPTFOO_DISABLE_UPDATE=1
  mkdir -p "$PROMPTFOO_CONFIG_DIR" || die 'cannot create the promptfoo home'
  : > "$STATUS"
  for suite in $chosen; do
    if [ -n "$stopped" ]; then
      printf '%s\tskipped\t-\n' "$suite" >> "$STATUS"
      continue
    fi
    offset="$(ledger_size)"
    rm -f "$OUT/$suite.json" || die "cannot remove the earlier results of $suite"
    echo "::group::$suite"
    (cd "$ROOT/evals/$suite" && EVAL_SUITE="$suite" "$PROMPTFOO" eval -c promptfooconfig.yaml \
      --no-cache --no-share --no-write --no-progress-bar --output "$OUT/$suite.json")
    rc=$?
    echo '::endgroup::'
    tally="$(node "$RUN_LEDGER_JS" tally "$LEDGER" "$suite" "$offset")" \
      || die "cannot read the usage ledger for $suite"
    report="$(node "$RUN_LEDGER_JS" results "$OUT/$suite.json")" || die "cannot read the results of $suite"
    hits="$(field "$tally" limit_hits)"
    asserts="$(field "$report" asserts_failed)"
    if [ "${hits:-0}" -gt 0 ]; then
      printf -- '- Usage limit reached during %s (%s calls); later suites were skipped.\n' \
        "$suite" "$hits" >> "$NOTICE"
      printf '::warning::Claude usage limit reached during %s; later suites skipped\n' "$suite"
      stopped=1
    fi
    if [ "${asserts:-0}" -gt 0 ]; then
      status=failed
    elif [ "${hits:-0}" -gt 0 ]; then
      status=inconclusive
    elif [ "$rc" -eq 0 ]; then
      status=passed
    else
      status=failed
    fi
    printf '%s\t%s\t%s\n' "$suite" "$status" "$rc" >> "$STATUS"
    if [ "$status" = failed ]; then
      printf '::error::%s failed with promptfoo exit %s\n' "$suite" "$rc"
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ]
}

cmd_summary() {
  local target="${GITHUB_STEP_SUMMARY:-/dev/stdout}" version model suites suite status rc
  version="${CLAUDE_CODE_VERSION:-}"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    version="$version, the newest release at run time"
  else
    version='not installed'
  fi
  model="${EVAL_CLAUDE_MODEL:-}"
  if [ -z "$model" ]; then
    model='account default'
  elif ! model_ok "$model"; then
    model='invalid value'
  fi
  suites="${EVAL_SUITES:-all}"
  case " all $SUITES " in
    (*" $suites "*) ;;
    (*) suites='invalid value' ;;
  esac
  {
    echo '## Live evals'
    echo
    echo "- Claude Code: $version"
    echo "- Model: $model"
    echo "- Suites requested: $suites"
    if [ -s "$NOTICE" ]; then cat "$NOTICE"; fi
    echo
    if [ -s "$STATUS" ]; then
      echo '| Suite | Status | promptfoo exit |'
      echo '|---|---|---|'
      while IFS="$(printf '\t')" read -r suite status rc; do
        printf '| %s | %s | %s |\n' "$suite" "$status" "$rc"
      done < "$STATUS"
    else
      echo 'No suite ran.'
    fi
    echo
    node "$RUN_LEDGER_JS" summarize "$LEDGER"
  } >> "$target"
}

cmd_scrub() {
  absolute "$OUT" || die "the results directory must be an absolute path: $OUT" 2
  absolute "$UPLOAD" || die "the upload directory must be an absolute path: $UPLOAD" 2
  if [ -e "$UPLOAD" ] || [ -L "$UPLOAD" ]; then
    die "the upload directory already exists: $UPLOAD"
  fi
  local report rc
  report="$(node "$RUN_LEDGER_JS" stage "$OUT" "$UPLOAD")"
  rc=$?
  printf '%s\n' "$report" \
    | sed -n -e 's/^removed=/::error::Removed from the results: /p' -e 's/^refused=/::error::Could not scrub: /p'
  if [ "$rc" -gt 1 ] || ! printf '%s\n' "$report" | grep -qx 'staged=complete'; then
    die 'the results were not scrubbed completely, so nothing is uploaded'
  fi
  gh_output 'scrubbed=true'
  [ "$rc" -eq 0 ]
}

case "${1:-}" in
  (probe) cmd_probe ;;
  (run) cmd_run ;;
  (summary) cmd_summary ;;
  (scrub) cmd_scrub ;;
  (*) die 'usage: live-evals.sh probe|run|summary|scrub' 2 ;;
esac
