#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/session-start-session-control.sh"
ADAPTER="$ROOT/hooks/lib/claude-session-control-v1.js"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
SESSION="$ROOT/hooks/lib/zensu-session.sh"
HOST_PATH="$ROOT/hooks/lib/zensu-host-path.sh"
README="$ROOT/README.md"
CHANGELOG="$ROOT/CHANGELOG.md"
PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$HOOK" "$ADAPTER" "$CORE" "$SESSION" "$HOST_PATH"; do
  [ -f "$artifact" ] && check "artifact exists: ${artifact#$ROOT/}" PASS || check "artifact exists: ${artifact#$ROOT/}" FAIL
done

CURRENT_CYCLE_CHANGELOG="$(awk '
  /^## \[Unreleased\]/ { in_section = 1; next }
  in_section && /^## \[/ { released += 1; if (released > 1) exit; next }
  in_section { print }
' "$CHANGELOG")"
CURRENT_CYCLE_CHANGELOG_ONELINE="$(printf '%s\n' "$CURRENT_CYCLE_CHANGELOG" | tr '\n' ' ' | tr -s ' ')"
for requirement in \
  'every published plugin change to use a new SemVer version and distinct immutable tag/cache path' \
  'already-running Claude Code sessions keep using their previous plugin root' \
  'Do not overwrite an existing cache version or run `/reload-plugins`' \
  '`~/.zensu/plugin-root` locator is no longer consulted or updated' \
  'the plugin never deletes it automatically'
do
  if printf '%s\n' "$CURRENT_CYCLE_CHANGELOG_ONELINE" | grep -qF -- "$requirement"; then
    check "Current-cycle upgrade note: $requirement" PASS
  else
    check "Current-cycle upgrade note: $requirement" FAIL
  fi
done

README_UPDATING="$(awk '
  /^## Updating$/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section { print }
' "$README")"
README_UPDATING_ONELINE="$(printf '%s\n' "$README_UPDATING" | tr '\n' ' ' | tr -s ' ')"
for requirement in \
  'already-running session keeps its previous `CLAUDE_PLUGIN_ROOT`' \
  'fresh sessions load the new version' \
  'Never replace bytes under an already-published version/cache directory' \
  'do not run `/reload-plugins`' \
  '`~/.zensu/plugin-root` locator is neither read, migrated, nor rewritten' \
  'Delete it only once no Claude Code session from an older Zensu plugin installation is still running in the same home' \
  'the plugin never deletes it automatically'
do
  if printf '%s\n' "$README_UPDATING_ONELINE" | grep -qF -- "$requirement"; then
    check "README upgrade note: $requirement" PASS
  else
    check "README upgrade note: $requirement" FAIL
  fi
done

README_TROUBLESHOOTING="$(awk '
  /^## Troubleshooting$/ { in_section = 1; next }
  in_section && /^## / { exit }
  in_section { print }
' "$README")"
README_TROUBLESHOOTING_ONELINE="$(printf '%s\n' "$README_TROUBLESHOOTING" | tr '\n' ' ' | tr -s ' ')"
for requirement in \
  'keep already-running sessions on their previous version' \
  'Do not run `/reload-plugins` or overwrite a loaded cache directory' \
  'The retired `~/.zensu/plugin-root` locator is never consulted by the updated plugin' \
  'Delete it only once no Claude Code session from an older installation is still running' \
  'the plugin never deletes it automatically'
do
  if printf '%s\n' "$README_TROUBLESHOOTING_ONELINE" | grep -qF -- "$requirement"; then
    check "README troubleshooting note: $requirement" PASS
  else
    check "README troubleshooting note: $requirement" FAIL
  fi
done
if ! grep -qF 'may be deleted' "$README"; then
  check "README has no unqualified legacy-locator deletion advice" PASS
else
  check "README has no unqualified legacy-locator deletion advice" FAIL
fi

SAFE_LOG_COMMAND='CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh"'
if [ "$(grep -cF "$SAFE_LOG_COMMAND" "$README" 2>/dev/null || true)" -ge 2 ] \
  && ! grep -qF 'ZENSU_CLAUDE_PLUGIN_ROOT' "$README"; then
  check "every README helper directive uses native plugin/session substitutions" PASS
else
  check "every README helper directive uses native plugin/session substitutions" FAIL
fi
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-session-control-claude: $PASS PASS / $FAIL FAIL"
  exit 1
fi

RAW_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-session-control-XXXXXX")"
RAW_TMP="$(cd -P -- "$RAW_TMP" && pwd -P)"
TMP="$(bash "$HOST_PATH" "$RAW_TMP")" || exit 1
trap 'rm -rf "$RAW_TMP"' EXIT
PLUGIN_DATA="$TMP/plugin-data"
PLUGIN_DATA_B="$TMP/plugin-data-b"
PLUGIN_COPY="$TMP/plugin-copy"
PROJECT_A="$TMP/project-a"
PROJECT_B="$TMP/project-b"
ENV_FAILURE_DATA="$TMP/env-failure-data"
ENV_FAILURE_PROJECT="$TMP/env-failure-project"
ENV_FILE="$TMP/session-env"
SOURCE_ENV_FILE="$TMP/source-env"
AGENT_ENV_FILE="$TMP/agent-session-env"
mkdir -p "$PLUGIN_DATA" "$PROJECT_A" "$PROJECT_B" "$ENV_FAILURE_DATA" "$ENV_FAILURE_PROJECT"
printf '%s\n' \
  'export ZENSU_CLAUDE_PLUGIN_ROOT=stale-root' \
  'export ZENSU_SESSION_KEY=stale-key' \
  'export ZENSU_SESSION_CONTEXT=stale-context' \
  'export ZENSU_RUNTIME_DIGEST=stale-digest' \
  'export ZENSU_PROJECT_ROOT=stale-project' > "$ENV_FILE"
ENV_FILE_BEFORE="$(cat "$ENV_FILE")"
: > "$SOURCE_ENV_FILE"
: > "$AGENT_ENV_FILE"
SID_A='claude/raw session alpha'
SID_B='claude/raw session beta'
KEY_A="$(node "$CORE" session-key "$SID_A")"
KEY_B="$(node "$CORE" session-key "$SID_B")"
HASH_A="sha256:${KEY_A#scv1_}"
CONTROL="$PLUGIN_DATA/session-control/v1"
RECORD_A="$CONTROL/records/$KEY_A.json"
RECORD_B="$CONTROL/records/$KEY_B.json"

payload() {
  local msys_env_exclusions="PAYLOAD_SESSION_ID"
  if [ -n "${MSYS2_ENV_CONV_EXCL:-}" ]; then
    msys_env_exclusions="${MSYS2_ENV_CONV_EXCL};${msys_env_exclusions}"
  fi
  MSYS2_ENV_CONV_EXCL="$msys_env_exclusions" PAYLOAD_SESSION_ID="$2" node -e 'process.stdout.write(JSON.stringify({
    hook_event_name: process.argv[1],
    session_id: process.env.PAYLOAD_SESSION_ID,
    cwd: process.argv[2],
    agent_id: process.argv[3] || undefined,
    agent_type: process.argv[4] || undefined,
    source: process.argv[5] || (process.argv[1] === "SessionStart" ? "startup" : undefined)
  }))' "$1" "$3" "${4:-}" "${5:-}" "${6:-}"
}

canonical_node_path() {
  node -e 'process.stdout.write(require("node:fs").realpathSync.native(process.argv[1]))' -- "$1"
}

canonical_shell_path() {
  (cd -P -- "$1" && pwd -P)
}

session_context_has_project() {
  EXPECTED_PROJECT="$1" node -e '
    let input = "";
    process.stdin.on("data", chunk => { input += chunk; });
    process.stdin.on("end", () => {
      try {
        const value = JSON.parse(input);
        const text = value.hookSpecificOutput?.additionalContext;
        const project = require("node:fs").realpathSync.native(process.env.EXPECTED_PROJECT);
        process.exit(typeof text === "string"
          && text.includes(`project_root=${JSON.stringify(project)}`) ? 0 : 1);
      } catch (_) { process.exit(1); }
    });
  '
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

run_agent_hook() {
  CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$AGENT_ENV_FILE" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK"
}

if payload SessionStart 'claude/missing-env-variable' "$ENV_FAILURE_PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$ENV_FAILURE_DATA" \
    env -u CLAUDE_ENV_FILE -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$HOOK" >"$TMP/missing-env-variable.out" 2>"$TMP/missing-env-variable.err"; then
  check "SessionStart is independent of a missing CLAUDE_ENV_FILE" PASS
else
  check "SessionStart is independent of a missing CLAUDE_ENV_FILE" FAIL
fi

if payload SessionStart 'claude/empty-env-variable' "$ENV_FAILURE_PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$ENV_FAILURE_DATA" CLAUDE_ENV_FILE='' \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$HOOK" >"$TMP/empty-env-variable.out" 2>"$TMP/empty-env-variable.err"; then
  check "SessionStart is independent of an empty CLAUDE_ENV_FILE" PASS
else
  check "SessionStart is independent of an empty CLAUDE_ENV_FILE" FAIL
fi

if payload SessionStart 'claude/missing-env-path' "$ENV_FAILURE_PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$ENV_FAILURE_DATA" \
    CLAUDE_ENV_FILE="$TMP/does-not-exist/session-env" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$HOOK" >"$TMP/missing-env-path.out" 2>"$TMP/missing-env-path.err"; then
  [ ! -e "$TMP/does-not-exist" ] \
    && check "SessionStart neither requires nor creates CLAUDE_ENV_FILE" PASS \
    || check "SessionStart neither requires nor creates CLAUDE_ENV_FILE" FAIL
else
  check "SessionStart neither requires nor creates CLAUDE_ENV_FILE" FAIL
fi

READ_ONLY_ENV="$TMP/read-only-session-env"
printf '%s\n' sentinel >"$READ_ONLY_ENV"
chmod 400 "$READ_ONLY_ENV"
if payload SessionStart 'claude/unwritable-env-file' "$ENV_FAILURE_PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$ENV_FAILURE_DATA" CLAUDE_ENV_FILE="$READ_ONLY_ENV" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$HOOK" >"$TMP/unwritable-env-file.out" 2>"$TMP/unwritable-env-file.err" \
  && [ "$(cat "$READ_ONLY_ENV")" = sentinel ]; then
  check "SessionStart leaves an unwritable CLAUDE_ENV_FILE byte-identical" PASS
else
  check "SessionStart leaves an unwritable CLAUDE_ENV_FILE byte-identical" FAIL
fi
chmod 600 "$READ_ONLY_ENV"

OUT_A="$(payload SessionStart "$SID_A" "$PROJECT_A" | run_hook 2>"$TMP/start.err")"
if printf '%s' "$OUT_A" | grep -qF '[zensu-session-context]' && [ -f "$RECORD_A" ]; then
  check "SessionStart registers immutable context and returns main additionalContext" PASS
else
  check "SessionStart registers immutable context and returns main additionalContext" FAIL
fi

RECORD_A_DIGEST_BEFORE_DERIVED_IDS="$(node -e '
  const fs = require("node:fs"); const crypto = require("node:crypto");
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$RECORD_A")"
RECORD_COUNT_BEFORE_DERIVED_IDS="$(find "$CONTROL/records" -type f -name 'scv1_*.json' | wc -l | tr -d ' ')"
for DERIVED_ID_KIND in record-key record-hash; do
  case "$DERIVED_ID_KIND" in
    record-key) DERIVED_ID="$KEY_A" ;;
    record-hash) DERIVED_ID="$HASH_A" ;;
  esac
  if payload SessionStart "$DERIVED_ID" "$PROJECT_A" \
    | run_hook >"$TMP/derived-$DERIVED_ID_KIND.out" 2>"$TMP/derived-$DERIVED_ID_KIND.err"; then
    check "SessionStart rejects a derived $DERIVED_ID_KIND as its host session id" FAIL
  else
    RECORD_A_DIGEST_AFTER_DERIVED_ID="$(node -e '
      const fs = require("node:fs"); const crypto = require("node:crypto");
      process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
    ' "$RECORD_A")"
    RECORD_COUNT_AFTER_DERIVED_ID="$(find "$CONTROL/records" -type f -name 'scv1_*.json' | wc -l | tr -d ' ')"
    if grep -qF 'host session id must be raw, not a derived Session Control identifier' \
      "$TMP/derived-$DERIVED_ID_KIND.err" \
      && [ ! -s "$TMP/derived-$DERIVED_ID_KIND.out" ] \
      && [ "$RECORD_COUNT_AFTER_DERIVED_ID" = "$RECORD_COUNT_BEFORE_DERIVED_IDS" ] \
      && [ "$RECORD_A_DIGEST_AFTER_DERIVED_ID" = "$RECORD_A_DIGEST_BEFORE_DERIVED_IDS" ]; then
      check "SessionStart rejects a derived $DERIVED_ID_KIND as its host session id" PASS
    else
      check "SessionStart rejects a derived $DERIVED_ID_KIND as its host session id" FAIL
    fi
  fi
done
unset DERIVED_ID DERIVED_ID_KIND RECORD_A_DIGEST_AFTER_DERIVED_ID RECORD_COUNT_AFTER_DERIVED_ID

if printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"claude/missing-source\",\"cwd\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$PROJECT_A")}" \
  | run_hook >"$TMP/missing-source.out" 2>"$TMP/missing-source.err"; then
  check "SessionStart rejects a missing lifecycle source" FAIL
elif grep -qF 'SessionStart source is unavailable or unsupported' "$TMP/missing-source.err"; then
  check "SessionStart rejects a missing lifecycle source" PASS
else
  check "SessionStart rejects a missing lifecycle source" FAIL
fi

if printf '%s' "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"claude/blank-source\",\"source\":\"   \",\"cwd\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$PROJECT_A")}" \
  | run_hook >"$TMP/blank-source.out" 2>"$TMP/blank-source.err"; then
  check "SessionStart rejects a blank lifecycle source" FAIL
elif grep -qF 'SessionStart source is unavailable or unsupported' "$TMP/blank-source.err"; then
  check "SessionStart rejects a blank lifecycle source" PASS
else
  check "SessionStart rejects a blank lifecycle source" FAIL
fi

UNKNOWN_SOURCE_SID='claude/unsupported-source'
UNKNOWN_SOURCE_KEY="$(node "$CORE" session-key "$UNKNOWN_SOURCE_SID")"
if payload SessionStart "$UNKNOWN_SOURCE_SID" "$PROJECT_A" '' '' future-source \
  | run_hook >"$TMP/unsupported-source.out" 2>"$TMP/unsupported-source.err" \
  && grep -qF '[zensu-session-context]' "$TMP/unsupported-source.out" \
  && [ -f "$CONTROL/records/$UNKNOWN_SOURCE_KEY.json" ]; then
  check "an unknown lifecycle source registers a fresh session instead of bricking it" PASS
else
  check "an unknown lifecycle source registers a fresh session instead of bricking it" FAIL
fi

FORK_SID='claude/forked session child'
FORK_KEY="$(node "$CORE" session-key "$FORK_SID")"
if payload SessionStart "$FORK_SID" "$PROJECT_A" '' '' fork \
  | run_hook >"$TMP/fork.out" 2>"$TMP/fork.err" \
  && printf '%s' "$(cat "$TMP/fork.out")" | session_context_has_project "$PROJECT_A" \
  && [ -f "$CONTROL/records/$FORK_KEY.json" ] \
  && [ -f "$PROJECT_A/.zensu/state/tdd-phase-$FORK_KEY.json" ]; then
  check "a forked session registers its own record and baseline workflow state" PASS
else
  check "a forked session registers its own record and baseline workflow state" FAIL
fi

SELF_HEAL_SID='claude/resume without a record'
SELF_HEAL_KEY="$(node "$CORE" session-key "$SELF_HEAL_SID")"
if payload SessionStart "$SELF_HEAL_SID" "$PROJECT_A" '' '' resume \
  | run_hook >"$TMP/self-heal.out" 2>"$TMP/self-heal.err" \
  && printf '%s' "$(cat "$TMP/self-heal.out")" | session_context_has_project "$PROJECT_A" \
  && [ -f "$CONTROL/records/$SELF_HEAL_KEY.json" ] \
  && [ -f "$PROJECT_A/.zensu/state/tdd-phase-$SELF_HEAL_KEY.json" ]; then
  check "a continuation whose record is missing self-heals into a fresh session" PASS
else
  check "a continuation whose record is missing self-heals into a fresh session" FAIL
fi

if payload SessionStart "$SID_A" "$PROJECT_B" '' '' fork \
  | run_hook >"$TMP/fork-rebind.out" 2>"$TMP/fork-rebind.err"; then
  check "a fresh source cannot rebind an existing session to another project" FAIL
elif grep -qF 'fresh SessionStart cwd does not match the existing session project' "$TMP/fork-rebind.err"; then
  check "a fresh source cannot rebind an existing session to another project" PASS
else
  check "a fresh source cannot rebind an existing session to another project" FAIL
fi

RECORD_A_DIGEST_BEFORE_RESUME="$(node -e '
  const fs = require("node:fs"); const crypto = require("node:crypto");
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$RECORD_A")"
STATE_A_DIGEST_BEFORE_RESUME="$(node -e '
  const fs = require("node:fs"); const crypto = require("node:crypto");
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json")"
mkdir -p "$PROJECT_A/src/nested" "$TMP/external-review-worktree"
OUT_COMPACT_DESCENDANT="$(payload SessionStart "$SID_A" "$PROJECT_A/src/nested" '' '' compact | run_hook 2>"$TMP/compact-descendant.err")"
OUT_RESUME_EXTERNAL="$(payload SessionStart "$SID_A" "$TMP/external-review-worktree" '' '' resume | run_hook 2>"$TMP/resume-external.err")"
RECORD_A_DIGEST_AFTER_RESUME="$(node -e '
  const fs = require("node:fs"); const crypto = require("node:crypto");
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$RECORD_A")"
STATE_A_DIGEST_AFTER_RESUME="$(node -e '
  const fs = require("node:fs"); const crypto = require("node:crypto");
  process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));
' "$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json")"
if printf '%s' "$OUT_COMPACT_DESCENDANT$OUT_RESUME_EXTERNAL" | grep -qF '[zensu-session-context]' \
  && printf '%s' "$OUT_COMPACT_DESCENDANT" | session_context_has_project "$PROJECT_A" \
  && printf '%s' "$OUT_RESUME_EXTERNAL" | session_context_has_project "$PROJECT_A" \
  && [ "$RECORD_A_DIGEST_BEFORE_RESUME" = "$RECORD_A_DIGEST_AFTER_RESUME" ] \
  && [ "$STATE_A_DIGEST_BEFORE_RESUME" = "$STATE_A_DIGEST_AFTER_RESUME" ]; then
  check "compact/resume preserve the immutable project anchor after CwdChanged" PASS
else
  check "compact/resume preserve the immutable project anchor after CwdChanged" FAIL
fi

BASELINE_A="$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json"
if [ -f "$BASELINE_A" ] && node -e '
  const core = require(process.argv[1]);
  const state = core.readWorkflowState({projectRoot: process.argv[2], sessionId: process.argv[3]});
  process.exit(state.revision === 1 && state.active === false
    && state.phase === "UNINITIALIZED" && state.reviewRound === 0
    && state.stopBlockCount === 0 && Array.isArray(state.history) && state.history.length === 0 ? 0 : 1);
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

if [ "$ENV_FILE_BEFORE" = "$(cat "$ENV_FILE")" ]; then
  check "SessionStart leaves a pre-seeded CLAUDE_ENV_FILE byte-identical" PASS
else
  check "SessionStart leaves a pre-seeded CLAUDE_ENV_FILE byte-identical" FAIL
fi
if ! grep -qF 'CLAUDE_ENV_FILE' "$ADAPTER"; then
  check "Session Control has no CLAUDE_ENV_FILE runtime dependency" PASS
else
  check "Session Control has no CLAUDE_ENV_FILE runtime dependency" FAIL
fi

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
if [ "$PARALLEL_OK" = 1 ] && [ "$PARALLEL_RECORDS" = "$PARALLEL_COUNT" ] \
  && [ ! -s "$PARALLEL_ENV" ]; then
  check "parallel cold starts create all records without touching CLAUDE_ENV_FILE" PASS
else
  check "parallel cold starts create all records without touching CLAUDE_ENV_FILE" FAIL
fi

HARDLINK_ENV="$TMP/hardlink-session-env"
HARDLINK_ALIAS="$TMP/hardlink-session-env-alias"
printf 'sentinel\n' >"$HARDLINK_ENV"
ln "$HARDLINK_ENV" "$HARDLINK_ALIAS"
if payload SessionStart 'claude/hardlink-env' "$PROJECT_A" \
  | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$HARDLINK_ENV" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY bash "$HOOK" \
    >"$TMP/hardlink.out" 2>"$TMP/hardlink.err" \
  && [ "$(cat "$HARDLINK_ENV")" = sentinel ] && [ "$(cat "$HARDLINK_ALIAS")" = sentinel ]; then
  check "hard-linked CLAUDE_ENV_FILE is ignored and remains byte-identical" PASS
else
  check "hard-linked CLAUDE_ENV_FILE is ignored and remains byte-identical" FAIL
fi

HELPER_KEY="$(CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$SID_A" bash -c "source '$SESSION'; zensu_bind_model_session; zensu_resolve_session_id ''" 2>/dev/null)"
HELPER_PROJECT="$(CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$SID_A" bash -c "source '$SESSION'; zensu_bind_model_session; zensu_resolve_project_dir" 2>/dev/null)"
if [ "$HELPER_KEY" = "$KEY_A" ] \
  && [ "$HELPER_PROJECT" = "$(canonical_shell_path "$PROJECT_A")" ] \
  && [ -d "$HELPER_PROJECT" ]; then
  check "model-side helpers resolve the native rendered session in the shell path namespace" PASS
else
  check "model-side helpers resolve the native rendered session in the shell path namespace" FAIL
fi

RAW_LOG_KEY="$(CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SID_A" bash "$ROOT/hooks/lib/zensu-log.sh" --session-key 2>/dev/null)"
if [ "$RAW_LOG_KEY" = "$KEY_A" ]; then
  check "model-bind and zensu-log accept Claude's raw host session id" PASS
else
  check "model-bind and zensu-log accept Claude's raw host session id" FAIL
fi

if CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$KEY_A" \
  node "$ROOT/hooks/lib/claude-hook-session-v1.js" model-bind \
    >"$TMP/derived-model-bind.out" 2>"$TMP/derived-model-bind.err"; then
  check "model-bind rejects a discoverable derived record key as CLAUDE_CODE_SESSION_ID" FAIL
elif grep -qF 'host session id must be raw, not a derived Session Control identifier' "$TMP/derived-model-bind.err" \
  && [ ! -s "$TMP/derived-model-bind.out" ]; then
  check "model-bind rejects a discoverable derived record key as CLAUDE_CODE_SESSION_ID" PASS
else
  check "model-bind rejects a discoverable derived record key as CLAUDE_CODE_SESSION_ID" FAIL
fi

if CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$KEY_A" \
  bash "$ROOT/hooks/lib/zensu-log.sh" --session-key \
    >"$TMP/derived-zensu-log.out" 2>"$TMP/derived-zensu-log.err"; then
  check "zensu-log rejects a discoverable derived record key as CLAUDE_CODE_SESSION_ID" FAIL
elif grep -qF 'host session id must be raw, not a derived Session Control identifier' "$TMP/derived-zensu-log.err" \
  && grep -qF 'rendered Session Control binding unavailable' "$TMP/derived-zensu-log.err" \
  && [ ! -s "$TMP/derived-zensu-log.out" ]; then
  check "zensu-log rejects a discoverable derived record key as CLAUDE_CODE_SESSION_ID" PASS
else
  check "zensu-log rejects a discoverable derived record key as CLAUDE_CODE_SESSION_ID" FAIL
fi

env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_CODE_SESSION_ID="$SID_A" \
  bash "$ROOT/hooks/lib/zensu-log.sh" --session-key \
    >"$TMP/no-plugin-data.out" 2>"$TMP/no-plugin-data.err"
NO_PLUGIN_DATA_RC=$?
if [ "$NO_PLUGIN_DATA_RC" -eq 2 ] \
  && grep -qF 'rendered Session Control binding unavailable' "$TMP/no-plugin-data.err" \
  && grep -qF 'CLAUDE_PLUGIN_DATA is not set' "$TMP/no-plugin-data.err" \
  && ! grep -qF 'CLAUDE_CODE_SESSION_ID is not set' "$TMP/no-plugin-data.err" \
  && [ ! -s "$TMP/no-plugin-data.out" ]; then
  check "zensu-log names CLAUDE_PLUGIN_DATA when the rendered prefix is missing" PASS
else
  check "zensu-log names CLAUDE_PLUGIN_DATA when the rendered prefix is missing" FAIL
fi

env -u CLAUDE_CODE_SESSION_ID CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  bash "$ROOT/hooks/lib/zensu-log.sh" --session-key \
    >"$TMP/no-session-id.out" 2>"$TMP/no-session-id.err"
NO_SESSION_ID_RC=$?
if [ "$NO_SESSION_ID_RC" -eq 2 ] \
  && grep -qF 'rendered Session Control binding unavailable' "$TMP/no-session-id.err" \
  && grep -qF 'CLAUDE_CODE_SESSION_ID is not set' "$TMP/no-session-id.err" \
  && ! grep -qF 'CLAUDE_PLUGIN_DATA is not set' "$TMP/no-session-id.err" \
  && [ ! -s "$TMP/no-session-id.out" ]; then
  check "zensu-log names CLAUDE_CODE_SESSION_ID when the host session id is missing" PASS
else
  check "zensu-log names CLAUDE_CODE_SESSION_ID when the host session id is missing" FAIL
fi

if [ -s "$TMP/derived-zensu-log.err" ] \
  && ! grep -qE 'is not set|is not on PATH' "$TMP/derived-zensu-log.err"; then
  check "zensu-log adds no precondition hint when every precondition is present" PASS
else
  check "zensu-log adds no precondition hint when every precondition is present" FAIL
fi

env -u CLAUDE_PLUGIN_DATA -u CLAUDE_CODE_SESSION_ID CLAUDE_PLUGIN_ROOT="$ROOT" \
  bash "$ROOT/hooks/lib/zensu-log.sh" --session-key \
    >"$TMP/no-both.out" 2>"$TMP/no-both.err"
NO_BOTH_RC=$?
NO_BOTH_ORDER="$(grep -oE 'CLAUDE_CODE_SESSION_ID is not set|CLAUDE_PLUGIN_DATA is not set' \
  "$TMP/no-both.err" | tr '\n' ',')"
if [ "$NO_BOTH_RC" -eq 2 ] \
  && [ "$NO_BOTH_ORDER" = 'CLAUDE_CODE_SESSION_ID is not set,CLAUDE_PLUGIN_DATA is not set,' ] \
  && [ ! -s "$TMP/no-both.out" ]; then
  check "zensu-log reports every missing precondition, in the binder's order" PASS
else
  check "zensu-log reports every missing precondition, in the binder's order" FAIL
fi

NODELESS_PATH=""
NODELESS_OLD_IFS="$IFS"
IFS=:
for NODELESS_DIR in $PATH; do
  [ -n "$NODELESS_DIR" ] || continue
  if [ -x "$NODELESS_DIR/node" ] || [ -x "$NODELESS_DIR/node.exe" ] \
    || [ -x "$NODELESS_DIR/node.cmd" ] || [ -x "$NODELESS_DIR/node.bat" ]; then
    continue
  fi
  NODELESS_PATH="${NODELESS_PATH:+$NODELESS_PATH:}$NODELESS_DIR"
done
IFS="$NODELESS_OLD_IFS"
NODELESS_BASH="$(command -v bash)"
env PATH="$NODELESS_PATH" CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SID_A" "$NODELESS_BASH" "$ROOT/hooks/lib/zensu-log.sh" --session-key \
    >"$TMP/no-node.out" 2>"$TMP/no-node.err"
NO_NODE_RC=$?
if env PATH="$NODELESS_PATH" "$NODELESS_BASH" -c 'command -v node' >/dev/null 2>&1; then
  check "nodeless PATH fixture actually removes node" FAIL
else
  check "nodeless PATH fixture actually removes node" PASS
fi
if [ "$NO_NODE_RC" -eq 2 ] \
  && grep -qF 'rendered Session Control binding unavailable' "$TMP/no-node.err" \
  && grep -qF 'node is not on PATH' "$TMP/no-node.err" \
  && ! grep -qF 'is not set' "$TMP/no-node.err" \
  && [ ! -s "$TMP/no-node.out" ]; then
  check "zensu-log names node when it is not on PATH" PASS
else
  check "zensu-log names node when it is not on PATH" FAIL
fi

BIND_GUARD_ORDER="$(sed -n '/^zensu_bind_model_session()/,/^}/p' "$SESSION" \
  | grep -E '^  \[ -n "\$\{[A-Z_]+:-\}" \] \|\| return 1|^  command -v [a-z]+ >/dev/null 2>&1 \|\| return 1' \
  | sed -e 's/^  \[ -n "\${\([A-Z_]*\):-}" \].*/\1/' -e 's/^  command -v \([a-z]*\).*/command -v \1/' \
  | tr '\n' ',')"
HINT_ORDER="$(grep -oE 'CLAUDE_CODE_SESSION_ID is not set|CLAUDE_PLUGIN_DATA is not set|node is not on PATH' \
  "$ROOT/hooks/lib/zensu-log.sh" | sed -e 's/ is not set//' -e 's/node is not on PATH/command -v node/' | tr '\n' ',')"
if [ "$BIND_GUARD_ORDER" = 'CLAUDE_CODE_SESSION_ID,CLAUDE_PLUGIN_DATA,command -v node,' ] \
  && [ "$HINT_ORDER" = "$BIND_GUARD_ORDER" ]; then
  check "zensu-log precondition hints mirror zensu_bind_model_session's guards in order" PASS
else
  check "zensu-log precondition hints mirror zensu_bind_model_session's guards in order (guards='$BIND_GUARD_ORDER' hints='$HINT_ORDER')" FAIL
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
if CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$SID_A" WRONG_ROOT="$WRONG_HELPER_ROOT" ROOT="$ROOT" bash -c '
  CLAUDE_PLUGIN_ROOT="$WRONG_ROOT" bash "$ROOT/hooks/lib/zensu-log.sh" --mode
' >"$TMP/wrong-helper-root.out" 2>"$TMP/wrong-helper-root.err"; then
  check "zensu-log rejects an inherited plugin root that differs from its executable" FAIL
else
  grep -qF 'does not match the executing plugin' "$TMP/wrong-helper-root.err" \
    && check "zensu-log rejects an inherited plugin root that differs from its executable" PASS \
    || check "zensu-log rejects an inherited plugin root that differs from its executable" FAIL
fi

CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_CODE_SESSION_ID="$SID_A" ROOT="$ROOT" \
  bash -c 'CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/hooks/lib/zensu-log.sh" --phase RED_WRITE --step adapter-test' >/dev/null
STATE_A="$PROJECT_A/.zensu/state/tdd-phase-$KEY_A.json"
if [ -f "$STATE_A" ] && [ "$(node -e 'process.stdout.write(String(require(process.argv[1]).revision))' "$STATE_A")" = 2 ]; then
  check "model-side zensu-log uses the rendered session and exact project state" PASS
else
  check "model-side zensu-log uses the rendered session and exact project state" FAIL
fi

# Exercise the complete SessionStart -> persisted host-native path -> Bash
# helper -> TDD lifecycle route with both plugin and project names that require
# careful shell handling. On Git Bash, the persisted values and the helper
# results deliberately use different (Windows and MSYS) path namespaces. The
# lifecycle intentionally covers Core-backed mutations, direct JSON CAS,
# lock-keeper paths, validated reads, and the pending-review marker.
SHELL_PLUGIN="$TMP/plugin root (mixed) apostrophe'value"
SHELL_PROJECT="$TMP/project root (mixed) apostrophe'value"
SHELL_PLUGIN_DATA="$TMP/shell-plugin-data"
SHELL_ENV="$TMP/shell-project-session-env"
SHELL_FOREIGN_PROJECT="$TMP/foreign project (mixed) apostrophe'value"
SHELL_SID='claude/shell project path'
SHELL_KEY="$(node "$CORE" session-key "$SHELL_SID")"
mkdir -p "$SHELL_PLUGIN" "$SHELL_PROJECT" "$SHELL_PLUGIN_DATA" "$SHELL_FOREIGN_PROJECT"
cp -R "$ROOT/.claude-plugin" "$ROOT/.mcp.json" "$ROOT/hooks" "$ROOT/agents" \
  "$ROOT/skills" "$ROOT/scripts" "$ROOT/mcp-runtime" "$SHELL_PLUGIN/"
SHELL_COPY_RC=$?
: > "$SHELL_ENV"
payload SessionStart "$SHELL_SID" "$SHELL_PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$SHELL_PLUGIN" CLAUDE_PLUGIN_DATA="$SHELL_PLUGIN_DATA" CLAUDE_ENV_FILE="$SHELL_ENV" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$SHELL_PLUGIN/hooks/session-start-session-control.sh" \
    >"$TMP/shell-project-start.out" 2>"$TMP/shell-project-start.err"
SHELL_START_RC=$?
payload SessionStart "$SHELL_SID" "$SHELL_PROJECT" \
  | CLAUDE_PLUGIN_ROOT="$SHELL_PLUGIN" CLAUDE_PLUGIN_DATA="$SHELL_PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$SHELL_PROJECT" \
    bash "$SHELL_PLUGIN/hooks/session-start-autopilot-resume.sh" \
    >"$TMP/shell-project-resume.out" 2>"$TMP/shell-project-resume.err"
SHELL_RESUME_RC=$?
SHELL_LIFECYCLE="$(CLAUDE_PLUGIN_ROOT="$SHELL_PLUGIN" CLAUDE_PLUGIN_DATA="$SHELL_PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SHELL_SID" EXPECTED_PROJECT="$SHELL_PROJECT" bash -c '
  set -eu
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  hook_payload="$(SESSION_VALUE="$CLAUDE_CODE_SESSION_ID" PROJECT_VALUE="$EXPECTED_PROJECT" node -e '\''
    process.stdout.write(JSON.stringify({
      hook_event_name: "PreToolUse", session_id: process.env.SESSION_VALUE,
      cwd: process.env.PROJECT_VALUE, tool_name: "Read", tool_input: {file_path: "README.md"}
    }));
  '\'')"
  zensu_bind_hook_session "$hook_payload"
  [ -n "$ZENSU_SESSION_KEY" ]
  zensu_bind_model_session
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

  sid="$ZENSU_SESSION_KEY"
  resolved="$(zensu_resolve_project_dir)"
  expected="$(cd -P -- "$EXPECTED_PROJECT" && pwd -P)"
  [ "$resolved" = "$expected" ]
  state="$(tdd_state_file "$sid")"

  tdd_begin_session "$sid" true false false "" msys-special-run 1 GATES msys-special-chain
  [ "$(tdd_state_status "$state")" = valid ]
  [ "$(tdd_session_active "$state")" = true ]
  tdd_write_phase "$sid" MSYS-P1 RED_WRITE shell-special-path
  [ "$(tdd_phase "$state")" = RED_WRITE ]

  tdd_mark_impl_complete_bound "$sid" msys-special-run 1 msys-special-chain
  [ "$(tdd_impl_complete "$state")" = true ]
  ticket="$(tdd_issue_review_ticket "$sid")"
  round="$(tdd_consume_review_ticket "$sid" "$ticket")"
  [ "$round" = 1 ]
  [ "$(tdd_get_counter "$state" reviewRound)" = 1 ]
  [ "$(tdd_claimed_review_ticket "$state")" = "$ticket" ]

  # This is the direct JSON generation-CAS path; it seals outcome and chain
  # completion together beneath the same project-state lock.
  tdd_finish_autopilot_chain "$sid" msys-special-run 1 msys-special-chain pass "$ticket"
  [ "$(tdd_chain_done "$state")" = true ]
  snapshot="$(tdd_chain_snapshot "$state" "$sid")"
  SNAPSHOT="$snapshot" node -e '\''
    const value = JSON.parse(process.env.SNAPSHOT);
    process.exit(value.active === true && value.implComplete === true
      && value.chainDone === true && value.autopilot
      && value.autopilot.runId === "msys-special-run"
      && value.autopilot.attempt === 1
      && value.autopilot.chainId === "msys-special-chain"
      && value.autopilot.outcome === "pass" ? 0 : 1);
  '\''

  tdd_write_pending_review "src/a.ts,src/b.ts" "shell-special pending marker"
  pending="$(zensu_pending_review_file)"
  [ -f "$pending" ]
  [ "$(tdd_pending_review_stale 24)" = false ]
  tdd_clear_pending_review
  [ ! -e "$pending" ]
  printf "ok:%s\\n" "$round"
' 2>"$TMP/shell-project-lifecycle.err")"
SHELL_LIFECYCLE_RC=$?
SHELL_STATE="$SHELL_PROJECT/.zensu/state/tdd-phase-$SHELL_KEY.json"
if [ "$SHELL_COPY_RC" -eq 0 ] && [ "$SHELL_START_RC" -eq 0 ] && [ "$SHELL_RESUME_RC" -eq 0 ] \
  && [ "$SHELL_LIFECYCLE_RC" -eq 0 ] && [ "$SHELL_LIFECYCLE" = ok:1 ] \
  && [ -f "$SHELL_STATE" ]; then
  check "Windows/MSYS shell-special plugin and project survive full TDD state lifecycle" PASS
else
  printf '    diagnostic copy=%s start=%s resume=%s lifecycle=%s output=%q plugin=%q project=%q state=%q\n' \
    "$SHELL_COPY_RC" "$SHELL_START_RC" "$SHELL_RESUME_RC" "$SHELL_LIFECYCLE_RC" "$SHELL_LIFECYCLE" \
    "$SHELL_PLUGIN" "$SHELL_PROJECT" "$SHELL_STATE" >&2
  if [ -s "$TMP/shell-project-start.err" ]; then
    sed 's/^/    SessionStart stderr: /' "$TMP/shell-project-start.err" >&2
  fi
  if [ -s "$TMP/shell-project-lifecycle.err" ]; then
    sed 's/^/    TDD lifecycle stderr: /' "$TMP/shell-project-lifecycle.err" >&2
  fi
  if [ -s "$TMP/shell-project-resume.err" ]; then
    sed 's/^/    Autopilot resume stderr: /' "$TMP/shell-project-resume.err" >&2
  fi
  check "Windows/MSYS shell-special plugin and project survive full TDD state lifecycle" FAIL
fi

# The shell-to-native mapper is itself a trust boundary, not merely a path
# formatter. Exercise foreign roots, lexical traversal, and each incomplete
# immutable-binding shape directly under the same special-path session.
SHELL_NATIVE_GUARDS="$(CLAUDE_PLUGIN_ROOT="$SHELL_PLUGIN" CLAUDE_PLUGIN_DATA="$SHELL_PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SHELL_SID" EXPECTED_PROJECT="$SHELL_PROJECT" \
  FOREIGN_PROJECT="$SHELL_FOREIGN_PROJECT" bash -c '
  set -eu
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
  zensu_bind_model_session
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  shell_root="$(zensu_resolve_project_dir)"
  state="$(tdd_state_file "$ZENSU_SESSION_KEY")"
  if _tdd_native_project_path "$FOREIGN_PROJECT" >/dev/null 2>&1; then exit 31; fi
  if _tdd_native_project_path "$shell_root/../$(basename "$FOREIGN_PROJECT")" >/dev/null 2>&1; then exit 32; fi
  saved_root="$ZENSU_PROJECT_ROOT"
  saved_key="$ZENSU_SESSION_KEY"
  saved_context="$ZENSU_SESSION_CONTEXT"
  unset ZENSU_PROJECT_ROOT
  if _tdd_native_project_path "$state" >/dev/null 2>&1; then exit 33; fi
  ZENSU_PROJECT_ROOT="$saved_root"; export ZENSU_PROJECT_ROOT
  unset ZENSU_SESSION_KEY
  if _tdd_native_project_path "$state" >/dev/null 2>&1; then exit 34; fi
  ZENSU_SESSION_KEY="$saved_key"; export ZENSU_SESSION_KEY
  unset ZENSU_SESSION_CONTEXT
  if _tdd_native_project_path "$state" >/dev/null 2>&1; then exit 35; fi
  ZENSU_SESSION_CONTEXT="$saved_context"; export ZENSU_SESSION_CONTEXT
  [ -n "$(_tdd_native_project_path "$state")" ]
  printf native-guards-ok
' 2>"$TMP/shell-native-guards.err")"
SHELL_NATIVE_GUARDS_RC=$?
if [ "$SHELL_NATIVE_GUARDS_RC" -eq 0 ] && [ "$SHELL_NATIVE_GUARDS" = native-guards-ok ]; then
  check "TDD native project mapper rejects foreign, traversal, and partial bindings" PASS
else
  sed 's/^/    native mapper stderr: /' "$TMP/shell-native-guards.err" >&2
  check "TDD native project mapper rejects foreign, traversal, and partial bindings" FAIL
fi

if CLAUDE_SESSION_ID='transcript-shaped' ZENSU_TRANSCRIPT_PATH="$TMP/fake.jsonl" ZENSU_SESSION_KEY='' bash -c "source '$SESSION'; zensu_bind_model_session" >"$TMP/missing.out" 2>/dev/null; then
  check "missing rendered and host session ids fail closed without transcript or PPID fallback" FAIL
else
  [ ! -s "$TMP/missing.out" ] && check "missing rendered and host session ids fail closed without transcript or PPID fallback" PASS || check "missing rendered and host session ids fail closed without transcript or PPID fallback" FAIL
fi

# Claude documents agent_type on SessionStart for top-level `claude --agent`
# sessions. The same trusted payload fields must select the same principal as
# PreToolUse; only a SessionStart with neither agent field is the main thread.
TOP_BARE_REVIEWER_SID='claude/top-agent-bare-reviewer'
TOP_SCOPED_REVIEWER_SID='claude/top-agent-scoped-reviewer'
TOP_UNKNOWN_SID='claude/top-agent-unknown'
TOP_PLM_SID='claude/top-agent-plm'
TOP_ID_ONLY_SID='claude/top-agent-id-only'
OUT_TOP_BARE_REVIEWER="$(payload SessionStart "$TOP_BARE_REVIEWER_SID" "$PROJECT_A" '' code-reviewer startup \
  | run_agent_hook 2>"$TMP/top-bare-reviewer.err")"
OUT_TOP_SCOPED_REVIEWER="$(payload SessionStart "$TOP_SCOPED_REVIEWER_SID" "$PROJECT_A" '' zensu:review-aspect startup \
  | run_agent_hook 2>"$TMP/top-scoped-reviewer.err")"
if [ "$(printf '%s' "$OUT_TOP_BARE_REVIEWER$OUT_TOP_SCOPED_REVIEWER" | grep -oF 'principal=reviewer-readonly-v1' | wc -l | tr -d ' ')" -eq 2 ] \
  && ! printf '%s' "$OUT_TOP_BARE_REVIEWER$OUT_TOP_SCOPED_REVIEWER" | grep -qF 'principal=main-v1'; then
  check "SessionStart --agent exact reviewer identities receive reviewer-readonly-v1" PASS
else
  check "SessionStart --agent exact reviewer identities receive reviewer-readonly-v1" FAIL
fi

OUT_TOP_UNKNOWN="$(payload SessionStart "$TOP_UNKNOWN_SID" "$PROJECT_A" '' repo-custom-agent startup \
  | run_agent_hook 2>"$TMP/top-unknown.err")"
OUT_TOP_PLM="$(payload SessionStart "$TOP_PLM_SID" "$PROJECT_A" '' zensu-plm startup \
  | run_agent_hook 2>"$TMP/top-plm.err")"
OUT_TOP_ID_ONLY="$(payload SessionStart "$TOP_ID_ONLY_SID" "$PROJECT_A" top-agent-id '' startup \
  | run_agent_hook 2>"$TMP/top-id-only.err")"
if [ "$(printf '%s' "$OUT_TOP_UNKNOWN$OUT_TOP_PLM$OUT_TOP_ID_ONLY" | grep -oF 'principal=host-profile-v1' | wc -l | tr -d ' ')" -eq 3 ] \
  && ! printf '%s' "$OUT_TOP_UNKNOWN$OUT_TOP_PLM$OUT_TOP_ID_ONLY" | grep -Eq 'principal=(main-v1|reviewer-readonly-v1)'; then
  check "SessionStart --agent unknown, PLM, and partial identities stay host-profile-v1" PASS
else
  check "SessionStart --agent unknown, PLM, and partial identities stay host-profile-v1" FAIL
fi

TOP_REVIEWER_KEY="$(node "$CORE" session-key "$TOP_BARE_REVIEWER_SID")"
TOP_REVIEWER_RECORD="$CONTROL/records/$TOP_REVIEWER_KEY.json"
TOP_REVIEWER_RECORD_BEFORE="$(cat "$TOP_REVIEWER_RECORD")"
TOP_REVIEWER_STATE="$PROJECT_A/.zensu/state/tdd-phase-$TOP_REVIEWER_KEY.json"
TOP_REVIEWER_STATE_BEFORE="$(cat "$TOP_REVIEWER_STATE")"
mkdir -p "$TMP/top-agent-external-cwd"
OUT_TOP_REVIEWER_RESUME="$(payload SessionStart "$TOP_BARE_REVIEWER_SID" "$TMP/top-agent-external-cwd" '' code-reviewer resume \
  | run_agent_hook 2>"$TMP/top-reviewer-resume.err")"
if printf '%s' "$OUT_TOP_REVIEWER_RESUME" | grep -qF 'principal=reviewer-readonly-v1' \
  && ! printf '%s' "$OUT_TOP_REVIEWER_RESUME" | grep -qF 'principal=main-v1' \
  && [ "$TOP_REVIEWER_RECORD_BEFORE" = "$(cat "$TOP_REVIEWER_RECORD")" ] \
  && [ "$TOP_REVIEWER_STATE_BEFORE" = "$(cat "$TOP_REVIEWER_STATE")" ]; then
  check "SessionStart --agent resume preserves principal and immutable record/CAS bytes" PASS
else
  check "SessionStart --agent resume preserves principal and immutable record/CAS bytes" FAIL
fi
if [ ! -s "$AGENT_ENV_FILE" ]; then
  check "SessionStart --agent leaves CLAUDE_ENV_FILE byte-identical" PASS
else
  check "SessionStart --agent leaves CLAUDE_ENV_FILE byte-identical" FAIL
fi

OUT_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-1 zensu:code-reviewer | run_hook 2>"$TMP/reviewer.err")"
OUT_ASPECT="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-2 zensu:review-aspect | run_hook 2>"$TMP/aspect.err")"
OUT_JUDGE="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-3 zensu:review-judge | run_hook 2>"$TMP/judge.err")"
if printf '%s' "$OUT_REVIEW$OUT_ASPECT$OUT_JUDGE" | grep -qF '[zensu-reviewer-context]' \
  && [ "$(printf '%s' "$OUT_REVIEW$OUT_ASPECT$OUT_JUDGE" | grep -oF 'reviewer-readonly-v1' | wc -l | tr -d ' ')" -ge 3 ] \
  && ! printf '%s' "$OUT_REVIEW$OUT_ASPECT$OUT_JUDGE" | grep -qF 'principal=main-v1'; then
  check "SubagentStart recognizes all three plugin-scoped reviewer agent_type names" PASS
else
  check "SubagentStart recognizes all three plugin-scoped reviewer agent_type names" FAIL
fi

OUT_BARE_REVIEW="$(payload SubagentStart "$SID_A" "$PROJECT_A" reviewer-fixture code-reviewer | run_hook 2>"$TMP/reviewer-fixture.err")"
if printf '%s' "$OUT_BARE_REVIEW" | grep -qF 'principal=reviewer-readonly-v1'; then
  check "exact bare --agents reviewer fixture remains read-only" PASS
else
  check "exact bare --agents reviewer fixture remains read-only" FAIL
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
  && printf '%s' "$OUT_CUSTOM_REVIEW$OUT_UNKNOWN" | grep -qF 'Non-command tools remain governed by this agent definition and Claude Code host permissions; every command-execution tool is denied by the Zensu capability gate.' \
  && ! printf '%s' "$OUT_CUSTOM_REVIEW$OUT_UNKNOWN" | grep -qF 'must not use shell/control tools' \
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

OUT_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-1 zensu:zensu-plm | run_hook 2>"$TMP/plm.err")"
if printf '%s' "$OUT_PLM" | grep -qF '[zensu-host-context]' \
  && printf '%s' "$OUT_PLM" | grep -qF 'principal=host-profile-v1' \
  && ! printf '%s' "$OUT_PLM" | grep -Eq 'principal=(main-v1|reviewer-readonly-v1)'; then
  check "plugin-scoped PLM subagent is neutral; its tool allowlist remains read-only" PASS
else
  check "plugin-scoped PLM subagent is neutral; its tool allowlist remains read-only" FAIL
fi


OUT_BARE_PLM="$(payload SubagentStart "$SID_A" "$PROJECT_A" plm-fixture zensu-plm | run_hook 2>"$TMP/plm-fixture.err")"
if printf '%s' "$OUT_BARE_PLM" | grep -qF 'principal=host-profile-v1'; then
  check "exact bare --agents PLM fixture remains neutral" PASS
else
  check "exact bare --agents PLM fixture remains neutral" FAIL
fi

mkdir -p "$PROJECT_A/src/nested"
OUT_DESCENDANT="$(payload SubagentStart "$SID_A" "$PROJECT_A/src/nested" child-descendant arbitrary-custom-agent | run_hook 2>"$TMP/descendant.err")"
if printf '%s' "$OUT_DESCENDANT" | grep -qF 'principal=host-profile-v1'; then
  check "SubagentStart accepts a canonical cwd beneath the bound project" PASS
else
  check "SubagentStart accepts a canonical cwd beneath the bound project" FAIL
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

OUT_EXTERNAL_CHILD="$(payload SubagentStart "$SID_A" "$PROJECT_B" child-sibling arbitrary-custom-agent \
  | run_hook 2>"$TMP/sibling-child.err")"
if printf '%s' "$OUT_EXTERNAL_CHILD" | grep -qF 'principal=host-profile-v1'; then
  check "SubagentStart accepts host-reported cwd in an external detached worktree" PASS
else
  check "SubagentStart accepts host-reported cwd in an external detached worktree" FAIL
fi

RECORD_A_BEFORE_REBIND="$(cat "$RECORD_A")"
if OUT_REBIND="$(payload SessionStart "$SID_A" "$PROJECT_B" '' '' startup | run_hook 2>"$TMP/rebind.err")"; then
  REBIND_RC=0
else
  REBIND_RC=$?
fi
RECORD_A_AFTER_REBIND="$(cat "$RECORD_A")"
if [ "$REBIND_RC" -ne 0 ] \
  && [ "$RECORD_A_BEFORE_REBIND" = "$RECORD_A_AFTER_REBIND" ] \
  && grep -qF 'fresh SessionStart cwd does not match the existing session project' "$TMP/rebind.err"; then
  check "cross-project startup cannot reuse or rebind an existing session" PASS
else
  check "cross-project startup cannot reuse or rebind an existing session" FAIL
fi


MISSING_RECORD_SID='claude/missing continuation record'
MISSING_RECORD_KEY="$(node "$CORE" session-key "$MISSING_RECORD_SID")"
MISSING_RECORD_FILE="$CONTROL/records/$MISSING_RECORD_KEY.json"
payload SessionStart "$MISSING_RECORD_SID" "$PROJECT_A" '' '' startup | run_hook >/dev/null 2>"$TMP/missing-record-start.err"
MISSING_RECORD_STATE="$PROJECT_A/.zensu/state/tdd-phase-$MISSING_RECORD_KEY.json"
MISSING_RECORD_STATE_BEFORE="$(cksum "$MISSING_RECORD_STATE")"
rm -f "$MISSING_RECORD_FILE"
if payload SessionStart "$MISSING_RECORD_SID" "$TMP/external-review-worktree" '' '' resume \
  | run_hook >"$TMP/missing-record-resume.out" 2>"$TMP/missing-record-resume.err" \
  && [ -f "$MISSING_RECORD_FILE" ] \
  && node -e '
    const fs = require("node:fs");
    const record = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.exit(record.project_root === fs.realpathSync.native(process.argv[2]) ? 0 : 1);
  ' "$MISSING_RECORD_FILE" "$TMP/external-review-worktree" \
  && [ "$MISSING_RECORD_STATE_BEFORE" = "$(cksum "$MISSING_RECORD_STATE")" ]; then
  check "resume with a missing immutable record self-heals and never edits the old project state" PASS
else
  check "resume with a missing immutable record self-heals and never edits the old project state" FAIL
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
    RECORD_PATH="$RECORD_A" node -e '
      const fs = require("node:fs");
      process.exit((fs.lstatSync(process.env.RECORD_PATH).mode & 0o777) === 0o600 ? 0 : 1);
    ' \
      && check "Claude control records are private (0600)" PASS \
      || check "Claude control records are private (0600)" FAIL
    ;;
esac

MISMATCH="$TMP/not-plugin"
mkdir -p "$MISMATCH"
MISMATCH_PAYLOAD="$(payload SessionStart mismatch "$PROJECT_A")"
if printf '%s' "$MISMATCH_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$MISMATCH" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" CLAUDE_ENV_FILE="$ENV_FILE" bash "$HOOK" >"$TMP/mismatch.out" 2>/dev/null; then
  check "ambient Claude plugin-root mismatch fails closed" FAIL
else
  check "ambient Claude plugin-root mismatch fails closed" PASS
fi

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) check "CLAUDE_PLUGIN_DATA symlink rejection skipped only on Windows" PASS ;;
  *)
    SYMLINK_DATA="$TMP/plugin-data-link"
    ln -s "$PLUGIN_DATA" "$SYMLINK_DATA"
    SYMLINK_PAYLOAD="$(payload SessionStart symlinked "$PROJECT_A")"
    if printf '%s' "$SYMLINK_PAYLOAD" | CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$SYMLINK_DATA" CLAUDE_ENV_FILE="$ENV_FILE" bash "$HOOK" >"$TMP/symlink.out" 2>/dev/null; then
      check "symlinked CLAUDE_PLUGIN_DATA fails closed" FAIL
    else
      check "symlinked CLAUDE_PLUGIN_DATA fails closed" PASS
    fi
    ;;
esac

printf '%s\n' "----" "test-session-control-claude: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
