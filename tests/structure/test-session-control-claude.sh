#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session-start-session-control.sh"
ADAPTER="$ROOT/hooks/lib/claude-session-control-v1.js"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
SESSION="$ROOT/hooks/lib/zensu-session.sh"
README="$ROOT/README.md"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$HOOK" "$ADAPTER" "$CORE" "$SESSION"; do
  [ -f "$artifact" ] && check "artifact exists: ${artifact#$ROOT/}" PASS || check "artifact exists: ${artifact#$ROOT/}" FAIL
done

SAFE_LOG_COMMAND='bash "${ZENSU_CLAUDE_PLUGIN_ROOT:?FATAL: plugin root unavailable; start a fresh Claude Code session}/hooks/lib/zensu-log.sh"'
if [ "$(grep -cF "$SAFE_LOG_COMMAND" "$README" 2>/dev/null || true)" -ge 2 ] \
  && ! grep -qF 'bash "$ZENSU_CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh"' "$README"; then
  check "README phase and recovery directives positively pin the guarded session-bound helper path" PASS
else
  check "README phase and recovery directives positively pin the guarded session-bound helper path" FAIL
fi
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-session-control-claude: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PLUGIN_DATA="$TMP/plugin-data"
PLUGIN_DATA_B="$TMP/plugin-data-b"
PLUGIN_COPY="$TMP/plugin-copy"
PROJECT_A="$TMP/project-a"
PROJECT_B="$TMP/project-b"
ENV_FILE="$TMP/session-env"
SOURCE_ENV_FILE="$TMP/source-env"
mkdir -p "$PLUGIN_DATA" "$PROJECT_A" "$PROJECT_B"
: > "$ENV_FILE"
: > "$SOURCE_ENV_FILE"
SID_A='claude/raw session alpha'
SID_B='claude/raw session beta'
KEY_A="$(node "$CORE" session-key "$SID_A")"
KEY_B="$(node "$CORE" session-key "$SID_B")"
CONTROL="$PLUGIN_DATA/session-control/v1"
RECORD_A="$CONTROL/records/$KEY_A.json"
RECORD_B="$CONTROL/records/$KEY_B.json"

payload() {
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name: process.argv[1],
    session_id: process.argv[2],
    cwd: process.argv[3],
    agent_id: process.argv[4] || undefined,
    agent_type: process.argv[5] || undefined
  }))' "$@"
}

run_hook() {
  CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$ENV_FILE" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK"
}

run_copy_hook() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN_COPY" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$ENV_FILE" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$PLUGIN_COPY/hooks/session-start-session-control.sh"
}

OUT_A="$(payload SessionStart "$SID_A" "$PROJECT_A" | run_hook 2>"$TMP/start.err")"
if printf '%s' "$OUT_A" | grep -qF '[zensu-session-context]' && [ -f "$RECORD_A" ]; then
  check "SessionStart registers immutable context and returns main additionalContext" PASS
else
  check "SessionStart registers immutable context and returns main additionalContext" FAIL
fi

BASELINE_A="$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json"
if [ -f "$BASELINE_A" ] && node -e '
  const core = require(process.argv[1]);
  const state = core.readWorkflowState({projectRoot: process.argv[2], sessionId: process.argv[3]});
  process.exit(state.revision === 1 && state.active === false
    && state.phase === "UNINITIALIZED" && state.reviewRound === 0
    && state.stopBlocks === 0 && Array.isArray(state.history) && state.history.length === 0 ? 0 : 1);
' "$CORE" "$PROJECT_A" "$SID_A"; then
  check "SessionStart creates the mandatory project-bound baseline CAS state" PASS
else
  check "SessionStart creates the mandatory project-bound baseline CAS state" FAIL
fi

if node -e '
  const record = require(process.argv[1]);
  process.exit(record.source_revision === record.runtime_digest && record.source_revision !== "unknown" ? 0 : 1);
' "$RECORD_A"; then
  check "normal SessionStart binds source revision to the exact runtime digest" PASS
else
  check "normal SessionStart binds source revision to the exact runtime digest" FAIL
fi

AMBIENT_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
OLD_SOURCE_AUTHORITY='verified-runtime-provenance-v1'
if payload SessionStart 'claude/source retired authority pair' "$PROJECT_A" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$SOURCE_ENV_FILE" \
    ZENSU_SOURCE_REVISION="$AMBIENT_SHA" ZENSU_SOURCE_REVISION_AUTHORITY="$OLD_SOURCE_AUTHORITY" \
    bash "$HOOK" >"$TMP/source-retired-pair.out" 2>"$TMP/source-retired-pair.err"; then
  check "retired SHA plus authority pair cannot relabel session provenance" FAIL
else
  check "retired SHA plus authority pair cannot relabel session provenance" PASS
fi

if payload SessionStart 'claude/source revision only' "$PROJECT_A" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$SOURCE_ENV_FILE" \
    ZENSU_SOURCE_REVISION="$AMBIENT_SHA" env -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$HOOK" >"$TMP/source-revision-only.out" 2>"$TMP/source-revision-only.err"; then
  check "ambient source revision without authority fails closed" FAIL
else
  check "ambient source revision without authority fails closed" PASS
fi

if payload SessionStart 'claude/source bad format' "$PROJECT_A" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$SOURCE_ENV_FILE" \
    ZENSU_SOURCE_REVISION='not-a-revision' ZENSU_SOURCE_REVISION_AUTHORITY="$OLD_SOURCE_AUTHORITY" \
    bash "$HOOK" >"$TMP/source-bad.out" 2>"$TMP/source-bad.err"; then
  check "malformed source revision fails closed" FAIL
else
  check "malformed source revision fails closed" PASS
fi

if payload SessionStart 'claude/source authority only' "$PROJECT_A" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$SOURCE_ENV_FILE" \
    ZENSU_SOURCE_REVISION_AUTHORITY="$OLD_SOURCE_AUTHORITY" env -u ZENSU_SOURCE_REVISION \
    bash "$HOOK" >"$TMP/source-authority-only.out" 2>"$TMP/source-authority-only.err"; then
  check "source authority without a revision fails closed" FAIL
else
  check "source authority without a revision fails closed" PASS
fi

if ! grep -F -q "$SID_A" "$ENV_FILE" && ! grep -R -F -q "$SID_A" "$PLUGIN_DATA"; then
  check "neither plugin data nor session environment persists the raw session id" PASS
else
  check "neither plugin data nor session environment persists the raw session id" FAIL
fi

ENV_VALUES="$(ENV_FILE="$ENV_FILE" bash -c 'source "$ENV_FILE"; printf "%s\n" "$ZENSU_CLAUDE_PLUGIN_ROOT" "$ZENSU_SESSION_KEY" "$ZENSU_SESSION_CONTEXT" "$ZENSU_RUNTIME_DIGEST" "$ZENSU_PROJECT_ROOT"')"
ENV_ROOT="$(printf '%s\n' "$ENV_VALUES" | sed -n '1p')"
ENV_KEY="$(printf '%s\n' "$ENV_VALUES" | sed -n '2p')"
ENV_CONTEXT="$(printf '%s\n' "$ENV_VALUES" | sed -n '3p')"
ENV_DIGEST="$(printf '%s\n' "$ENV_VALUES" | sed -n '4p')"
ENV_PROJECT="$(printf '%s\n' "$ENV_VALUES" | sed -n '5p')"
if [ "$ENV_ROOT" = "$(cd "$ROOT" && pwd -P)" ] && [ "$ENV_KEY" = "$KEY_A" ] && [ "$ENV_CONTEXT" = "$(cd "$CONTROL/records" && pwd -P)/$KEY_A.json" ] && [ "$ENV_PROJECT" = "$(cd "$PROJECT_A" && pwd -P)" ]; then
  check "SessionStart exports exact root, hashed key, immutable context and project" PASS
else
  check "SessionStart exports exact root, hashed key, immutable context and project" FAIL
fi
printf '%s' "$ENV_DIGEST" | grep -Eq '^sha256:[a-f0-9]{64}$' && check "SessionStart exports the runtime digest" PASS || check "SessionStart exports the runtime digest" FAIL

PARALLEL_DATA="$TMP/parallel-plugin-data"
PARALLEL_ENV="$TMP/parallel-session-env"
PARALLEL_COUNT=8
mkdir -p "$PARALLEL_DATA"
: >"$PARALLEL_ENV"
PIDS=''
for index in $(seq 1 "$PARALLEL_COUNT"); do
  payload SessionStart "claude/parallel-$index" "$PROJECT_A" \
    | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PARALLEL_DATA" CLAUDE_ENV_FILE="$PARALLEL_ENV" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK" \
      >"$TMP/parallel-$index.out" 2>"$TMP/parallel-$index.err" &
  PIDS="$PIDS $!"
done
PARALLEL_OK=1
for pid in $PIDS; do
  wait "$pid" || PARALLEL_OK=0
done
PARALLEL_RECORDS="$(find "$PARALLEL_DATA/session-control/v1/records" -type f -name 'scv1_*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$PARALLEL_OK" = 1 ] && [ "$PARALLEL_RECORDS" = "$PARALLEL_COUNT" ] && \
  node - "$PARALLEL_ENV" "$PARALLEL_COUNT" <<'NODE'
const fs = require('node:fs');
const [file, countText] = process.argv.slice(2);
const keys = [
  'ZENSU_CLAUDE_PLUGIN_ROOT',
  'ZENSU_SESSION_KEY',
  'ZENSU_SESSION_CONTEXT',
  'ZENSU_RUNTIME_DIGEST',
  'ZENSU_PROJECT_ROOT',
];
const lines = fs.readFileSync(file, 'utf8').trimEnd().split('\n');
const width = keys.length * 2;
if (lines.length !== Number(countText) * width) process.exit(1);
for (let offset = 0; offset < lines.length; offset += width) {
  for (let index = 0; index < keys.length; index += 1) {
    if (lines[offset + index] !== `unset ${keys[index]}`) process.exit(1);
    if (!lines[offset + keys.length + index].startsWith(`export ${keys[index]}=`)) process.exit(1);
  }
}
NODE
then
  check "parallel cold starts create all records and append only complete environment blocks" PASS
else
  check "parallel cold starts create all records and append only complete environment blocks" FAIL
fi

HARDLINK_ENV="$TMP/hardlink-session-env"
HARDLINK_ALIAS="$TMP/hardlink-session-env-alias"
printf 'sentinel\n' >"$HARDLINK_ENV"
ln "$HARDLINK_ENV" "$HARDLINK_ALIAS"
if payload SessionStart 'claude/hardlink-env' "$PROJECT_A" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$HARDLINK_ENV" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK" \
    >"$TMP/hardlink.out" 2>"$TMP/hardlink.err"; then
  check "hard-linked CLAUDE_ENV_FILE fails closed without appending" FAIL
elif [ "$(cat "$HARDLINK_ENV")" = sentinel ] && [ "$(cat "$HARDLINK_ALIAS")" = sentinel ]; then
  check "hard-linked CLAUDE_ENV_FILE fails closed without appending" PASS
else
  check "hard-linked CLAUDE_ENV_FILE fails closed without appending" FAIL
fi

HELPER_KEY="$(bash -c "source '$ENV_FILE'; source '$SESSION'; zensu_resolve_session_id ''" 2>/dev/null)"
HELPER_PROJECT="$(bash -c "source '$ENV_FILE'; source '$SESSION'; zensu_resolve_project_dir" 2>/dev/null)"
if [ "$HELPER_KEY" = "$KEY_A" ] && [ "$HELPER_PROJECT" = "$(cd "$PROJECT_A" && pwd -P)" ]; then
  check "model-side helpers consume only the exported session contract" PASS
else
  check "model-side helpers consume only the exported session contract" FAIL
fi

if ZENSU_PROJECT_ROOT="$PROJECT_B" ZENSU_SESSION_KEY="$KEY_A" ZENSU_SESSION_CONTEXT="$RECORD_A" \
  bash -c "source '$SESSION'; zensu_resolve_project_dir" >"$TMP/project-tamper.out" 2>/dev/null; then
  check "project helper rejects ZENSU_PROJECT_ROOT that disagrees with immutable context" FAIL
else
  check "project helper rejects ZENSU_PROJECT_ROOT that disagrees with immutable context" PASS
fi

if CLAUDE_PROJECT_DIR="$PROJECT_A" ZENSU_PROJECT_ROOT='' ZENSU_SESSION_KEY="$KEY_A" ZENSU_SESSION_CONTEXT="$RECORD_A" \
  bash -c "source '$SESSION'; zensu_resolve_project_dir" >"$TMP/claude-project-fallback.out" 2>/dev/null; then
  check "project helper has no CLAUDE_PROJECT_DIR fallback" FAIL
else
  check "project helper has no CLAUDE_PROJECT_DIR fallback" PASS
fi

WRONG_HELPER_ROOT="$TMP/not-plugin-helper"
mkdir -p "$WRONG_HELPER_ROOT"
if ENV_FILE="$ENV_FILE" WRONG_ROOT="$WRONG_HELPER_ROOT" ROOT="$ROOT" bash -c '
  source "$ENV_FILE"
  CLAUDE_PLUGIN_ROOT="$WRONG_ROOT" bash "$ROOT/hooks/lib/zensu-log.sh" --mode
' >"$TMP/wrong-helper-root.out" 2>"$TMP/wrong-helper-root.err"; then
  check "zensu-log rejects an inherited plugin root that differs from its executable" FAIL
else
  grep -qF 'does not match the executing plugin' "$TMP/wrong-helper-root.err" \
    && check "zensu-log rejects an inherited plugin root that differs from its executable" PASS \
    || check "zensu-log rejects an inherited plugin root that differs from its executable" FAIL
fi

ENV_FILE="$ENV_FILE" ROOT="$ROOT" bash -c 'source "$ENV_FILE"; CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks/lib/zensu-log.sh" --phase RED_WRITE --step adapter-test' >/dev/null
STATE_A="$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json"
if [ -f "$STATE_A" ] && [ "$(node -e 'process.stdout.write(String(require(process.argv[1]).revision))' "$STATE_A")" = 2 ]; then
  check "model-side zensu-log uses the exported key and exact project state" PASS
else
  check "model-side zensu-log uses the exported key and exact project state" FAIL
fi

if CLAUDE_SESSION_ID='transcript-shaped' ZENSU_TRANSCRIPT_PATH="$TMP/fake.jsonl" ZENSU_SESSION_KEY='' bash -c "source '$SESSION'; zensu_resolve_session_id ''" >"$TMP/missing.out" 2>/dev/null; then
  check "missing exported key fails closed without transcript or PPID fallback" FAIL
else
  [ ! -s "$TMP/missing.out" ] && check "missing exported key fails closed without transcript or PPID fallback" PASS || check "missing exported key fails closed without transcript or PPID fallback" FAIL
fi

OUT_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-1 code-reviewer | run_hook 2>"$TMP/reviewer.err")"
OUT_ASPECT="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-2 review-aspect | run_hook 2>"$TMP/aspect.err")"
OUT_JUDGE="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-3 review-judge | run_hook 2>"$TMP/judge.err")"
if printf '%s' "$OUT_REVIEW$OUT_ASPECT$OUT_JUDGE" | grep -qF '[zensu-reviewer-context]' \
  && [ "$(printf '%s' "$OUT_REVIEW$OUT_ASPECT$OUT_JUDGE" | grep -oF 'reviewer-readonly-v1' | wc -l | tr -d ' ')" -ge 3 ] \
  && ! printf '%s' "$OUT_REVIEW$OUT_ASPECT$OUT_JUDGE" | grep -qF 'principal=main-v1'; then
  check "SubagentStart recognizes all three real bare reviewer agent_type names" PASS
else
  check "SubagentStart recognizes all three real bare reviewer agent_type names" FAIL
fi

mkdir -p "$PLUGIN_COPY"
cp -R "$ROOT/.claude-plugin" "$ROOT/hooks" "$ROOT/agents" "$ROOT/skills" "$PLUGIN_COPY/"
if payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-cross-root code-reviewer \
  | run_copy_hook >"$TMP/cross-root.out" 2>"$TMP/cross-root.err"; then
  check "SubagentStart rejects a byte-identical second plugin copy sharing the parent store" FAIL
else
  grep -qF 'plugin root does not match the parent session' "$TMP/cross-root.err" \
    && check "SubagentStart rejects a byte-identical second plugin copy sharing the parent store" PASS \
    || check "SubagentStart rejects a byte-identical second plugin copy sharing the parent store" FAIL
fi

mkdir -p "$PLUGIN_DATA_B/session-control/v1/records" "$PLUGIN_DATA_B/session-control/v1/locks"
chmod 700 "$PLUGIN_DATA_B" "$PLUGIN_DATA_B/session-control" "$PLUGIN_DATA_B/session-control/v1" \
  "$PLUGIN_DATA_B/session-control/v1/records" "$PLUGIN_DATA_B/session-control/v1/locks"
cp "$RECORD_A" "$PLUGIN_DATA_B/session-control/v1/records/$KEY_A.json"
chmod 600 "$PLUGIN_DATA_B/session-control/v1/records/$KEY_A.json"
if payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-cross-data code-reviewer \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_B" CLAUDE_ENV_FILE="$ENV_FILE" bash "$HOOK" \
    >"$TMP/cross-data.out" 2>"$TMP/cross-data.err"; then
  check "SubagentStart rejects a copied parent record from different plugin data" FAIL
else
  grep -qF 'plugin data does not match the parent session' "$TMP/cross-data.err" \
    && check "SubagentStart rejects a copied parent record from different plugin data" PASS \
    || check "SubagentStart rejects a copied parent record from different plugin data" FAIL
fi

OUT_CUSTOM_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-custom zensu-review-domain | run_hook 2>"$TMP/review-custom.err")"
OUT_UNKNOWN="$(payload SubagentStart "$SID_A" "$PROJECT_A" unknown-custom arbitrary-custom-agent | run_hook 2>"$TMP/unknown-custom.err")"
if printf '%s' "$OUT_CUSTOM_REVIEW$OUT_UNKNOWN" | grep -qF '[zensu-host-context]' \
  && [ "$(printf '%s' "$OUT_CUSTOM_REVIEW$OUT_UNKNOWN" | grep -oF 'principal=host-profile-v1' | wc -l | tr -d ' ')" -eq 2 ] \
  && ! printf '%s' "$OUT_CUSTOM_REVIEW$OUT_UNKNOWN" | grep -Eq 'principal=(main-v1|reviewer-readonly-v1)'; then
  check "unknown and repo-local custom agents receive only neutral host-profile-v1" PASS
else
  check "unknown and repo-local custom agents receive only neutral host-profile-v1" FAIL
fi

OUT_PATH_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-path /root/zensu_code_reviewer | run_hook 2>"$TMP/review-path.err")"
OUT_UNDERSCORE_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-underscore zensu_review_aspect | run_hook 2>"$TMP/review-underscore.err")"
if printf '%s' "$OUT_PATH_REVIEW$OUT_UNDERSCORE_REVIEW" | grep -qF 'principal=host-profile-v1' \
  && ! printf '%s' "$OUT_PATH_REVIEW$OUT_UNDERSCORE_REVIEW" | grep -Eq 'principal=(main-v1|reviewer-readonly-v1)'; then
  check "non-host reviewer aliases are not promoted to a trusted principal" PASS
else
  check "non-host reviewer aliases are not promoted to a trusted principal" FAIL
fi

OUT_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-1 zensu-plm | run_hook 2>"$TMP/plm.err")"
if printf '%s' "$OUT_PLM" | grep -qF '[zensu-host-context]' \
  && printf '%s' "$OUT_PLM" | grep -qF 'principal=host-profile-v1' \
  && ! printf '%s' "$OUT_PLM" | grep -Eq 'principal=(main-v1|reviewer-readonly-v1)'; then
  check "bare PLM subagent is neutral; mutating workflows stay in main-thread skills" PASS
else
  check "bare PLM subagent is neutral; mutating workflows stay in main-thread skills" FAIL
fi

OUT_PATH_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-path /root/zensu_plm | run_hook 2>"$TMP/plm-path.err")"
if printf '%s' "$OUT_PATH_PLM" | grep -qF 'principal=host-profile-v1' && ! printf '%s' "$OUT_PATH_PLM" | grep -Eq 'principal=(main-v1|reviewer-readonly-v1)'; then
  check "PLM path aliases remain neutral" PASS
else
  check "PLM path aliases remain neutral" FAIL
fi

if payload SubagentStart unknown "$PROJECT_A" reviewer-2 zensu-review-aspect | run_hook >"$TMP/unknown.out" 2>/dev/null; then
  check "SubagentStart cannot self-register an unknown parent" FAIL
else
  check "SubagentStart cannot self-register an unknown parent" PASS
fi

if payload SessionStart "$SID_A" "$PROJECT_B" | run_hook >"$TMP/rebind.out" 2>/dev/null; then
  check "an active Claude session cannot be rebound to another project" FAIL
else
  check "an active Claude session cannot be rebound to another project" PASS
fi

payload SessionStart "$SID_B" "$PROJECT_B" | run_hook >"$TMP/start-b.out" 2>"$TMP/start-b.err"
if [ -f "$RECORD_A" ] && [ -f "$RECORD_B" ]; then
  check "distinct Claude sessions retain independent records" PASS
else
  check "distinct Claude sessions retain independent records" FAIL
fi

if ZENSU_PROJECT_ROOT="$PROJECT_A" ZENSU_SESSION_KEY="$KEY_A" ZENSU_SESSION_CONTEXT="$RECORD_B" \
  bash -c "source '$SESSION'; zensu_resolve_project_dir" >"$TMP/context-mismatch.out" 2>/dev/null; then
  check "project helper rejects a context record from another session" FAIL
else
  check "project helper rejects a context record from another session" PASS
fi

if ! find "$PLUGIN_DATA" -type l -print -quit | grep -q .; then
  check "Claude control records are symlink-free" PASS
else
  check "Claude control records are symlink-free" FAIL
fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) check "POSIX 0600 record-mode assertion skipped only on Windows" PASS ;;
  *)
    [ "$(stat -f '%Lp' "$RECORD_A" 2>/dev/null || stat -c '%a' "$RECORD_A")" = 600 ] \
      && check "Claude control records are private (0600)" PASS \
      || check "Claude control records are private (0600)" FAIL
    ;;
esac

MISMATCH="$TMP/not-plugin"
mkdir -p "$MISMATCH"
if payload SessionStart mismatch "$PROJECT_A" | CLAUDE_PLUGIN_ROOT="$MISMATCH" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$ENV_FILE" bash "$HOOK" >"$TMP/mismatch.out" 2>/dev/null; then
  check "ambient Claude plugin-root mismatch fails closed" FAIL
else
  check "ambient Claude plugin-root mismatch fails closed" PASS
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) check "CLAUDE_PLUGIN_DATA symlink rejection skipped only on Windows" PASS ;;
  *)
    SYMLINK_DATA="$TMP/plugin-data-link"
    ln -s "$PLUGIN_DATA" "$SYMLINK_DATA"
    if payload SessionStart symlinked "$PROJECT_A" | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$SYMLINK_DATA" CLAUDE_ENV_FILE="$ENV_FILE" bash "$HOOK" >"$TMP/symlink.out" 2>/dev/null; then
      check "symlinked CLAUDE_PLUGIN_DATA fails closed" FAIL
    else
      check "symlinked CLAUDE_PLUGIN_DATA fails closed" PASS
    fi
    ;;
esac

printf '%s\n' "----" "test-session-control-claude: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
