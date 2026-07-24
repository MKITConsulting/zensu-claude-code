#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PROVIDER="$ROOT/evals/session-control/lib/upgrade-provider.js"

grep -qF -- '--setenv CLAUDE_PLUGIN_DATA ' "$PROVIDER"
grep -qF -- '--setenv CLAUDE_PROJECT_DIR ' "$PROVIDER"

if [ "${ZENSU_RUN_LINUX_SANDBOX_HOOK_INTEGRATION:-0}" != 1 ]; then
  printf '%s\n' \
    'PASS: contained hook integration is statically pinned; dedicated Linux runtime gate not requested'
  exit 0
fi
if [ "$(uname -s)" != Linux ] || [ ! -x /usr/bin/bwrap ] || [ ! -x /usr/bin/timeout ]; then
  printf '%s\n' \
    'FAIL: dedicated contained hook integration requires Linux, bwrap, and timeout' >&2
  exit 1
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zensu-contained-hooks.XXXXXX")"
TEST_ROOT="$(cd -P -- "$TEST_ROOT" && pwd -P)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

HOME_DIR="$TEST_ROOT/home"
PROJECT="$TEST_ROOT/project"
CONTROL="$TEST_ROOT/control"
PLUGIN_DATA="$HOME_DIR/.claude/plugins/data/zensu-zensu"
CONFIG="$HOME_DIR/.zensu-upgrade-config.json"
mkdir -p "$HOME_DIR" "$PROJECT" "$CONTROL" "$PLUGIN_DATA"
chmod 700 "$TEST_ROOT" "$HOME_DIR" "$PROJECT" "$CONTROL" "$PLUGIN_DATA"
printf '%s\n' '{}' >"$CONFIG"
chmod 600 "$CONFIG"

SESSION_ID="contained-hook-$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')"
SESSION_PAYLOAD="$TEST_ROOT/session-start.json"
TOOL_PAYLOAD="$TEST_ROOT/pre-tool-use.json"
SESSION_OUTPUT="$TEST_ROOT/session-start.out"
SESSION_ERROR="$TEST_ROOT/session-start.err"
TOOL_OUTPUT="$TEST_ROOT/pre-tool-use.out"
TOOL_ERROR="$TEST_ROOT/pre-tool-use.err"

SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "SessionStart",
    source: "startup",
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
  }));
' >"$SESSION_PAYLOAD"

SESSION_ID="$SESSION_ID" PROJECT="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "PreToolUse",
    session_id: process.env.SESSION_ID,
    cwd: process.env.PROJECT,
    tool_name: "Read",
    tool_input: { file_path: "README.md" },
  }));
' >"$TOOL_PAYLOAD"

create_production_boundary() {
  local control="$1"
  local plugin_root="$2"
  local cache_base="$3"
  env -u ZENSU_UPGRADE_TEST_MODE node - \
    "$PROVIDER" \
    "$control" \
    "$cache_base" \
    "$HOME_DIR" \
    "$PROJECT" \
    "$PLUGIN_DATA" \
    "$CONFIG" <<'NODE'
const [
  provider,
  control,
  cacheBase,
  home,
  project,
  pluginData,
  config,
] = process.argv.slice(2);
const { createTraceBoundary } = require(provider);
const boundary = createTraceBoundary(
  control,
  cacheBase,
  home,
  project,
  pluginData,
  config,
);
process.stdout.write(boundary.bin);
NODE
  test -d "$plugin_root"
}

BOUNDARY_BIN="$(
  create_production_boundary "$CONTROL" "$ROOT" "$(dirname "$ROOT")"
)"
BOUNDARY_WRAPPER="$BOUNDARY_BIN/bash"
test -x "$BOUNDARY_WRAPPER"

run_contained_hook() {
  local wrapper="$1"
  local plugin_root="$2"
  local hook="$3"
  local input="$4"
  local output="$5"
  local error="$6"
  env -u ZENSU_UPGRADE_TEST_MODE \
    CLAUDE_PLUGIN_ROOT="$plugin_root" \
    /usr/bin/timeout --signal=TERM --kill-after=5s 30s \
      "$wrapper" "$hook" \
    <"$input" >"$output" 2>"$error"
}

run_contained_hook \
  "$BOUNDARY_WRAPPER" \
  "$ROOT" \
  "$ROOT/hooks/session-start-session-control.sh" \
  "$SESSION_PAYLOAD" \
  "$SESSION_OUTPUT" \
  "$SESSION_ERROR"

test ! -s "$SESSION_ERROR"
node -e '
  const fs = require("node:fs");
  const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (value?.hookSpecificOutput?.hookEventName !== "SessionStart"
      || !String(value.hookSpecificOutput.additionalContext || "")
        .includes("[zensu-session-context]")) {
    process.exit(1);
  }
' "$SESSION_OUTPUT"

RECORD_COUNT="$(find "$PLUGIN_DATA/session-control/v1/records" -type f -name 'scv1_*.json' | wc -l | tr -d ' ')"
WORKFLOW_COUNT="$(find "$PROJECT/.zensu/state" -type f -name 'tdd-phase-scv1_*.json' | wc -l | tr -d ' ')"
test "$RECORD_COUNT" = 1
test "$WORKFLOW_COUNT" = 1

run_contained_hook \
  "$BOUNDARY_WRAPPER" \
  "$ROOT" \
  "$ROOT/hooks/pre-reviewer-capability-gate.sh" \
  "$TOOL_PAYLOAD" \
  "$TOOL_OUTPUT" \
  "$TOOL_ERROR"

test ! -s "$TOOL_ERROR"
if [ -s "$TOOL_OUTPUT" ]; then
  node -e '
    const fs = require("node:fs");
    const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (value?.hookSpecificOutput?.permissionDecision === "deny") process.exit(1);
  ' "$TOOL_OUTPUT"
fi

CANARY_CACHE_BASE="$HOME_DIR/canary-cache"
CANARY_ROOT="$CANARY_CACHE_BASE/runtime"
CANARY_CONTROL="$TEST_ROOT/canary-control"
CANARY_HOOK="$CANARY_ROOT/hooks/environment-canary.sh"
CANARY_SECRET="$CANARY_CONTROL/host-secret"
CANARY_INPUT="$TEST_ROOT/canary.json"
CANARY_OUTPUT="$TEST_ROOT/canary.out"
CANARY_ERROR="$TEST_ROOT/canary.err"
mkdir -p "$CANARY_ROOT/hooks" "$CANARY_CONTROL"
chmod 700 "$CANARY_CACHE_BASE" "$CANARY_ROOT" "$CANARY_ROOT/hooks" "$CANARY_CONTROL"
printf '%s\n' host-only >"$CANARY_SECRET"
printf '%s\n' '{}' >"$CANARY_INPUT"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  "[ \"\${CLAUDE_PLUGIN_ROOT:-}\" = \"$CANARY_ROOT\" ]" \
  "[ \"\${CLAUDE_PLUGIN_DATA:-}\" = \"$PLUGIN_DATA\" ]" \
  "[ \"\${CLAUDE_PROJECT_DIR:-}\" = \"$PROJECT\" ]" \
  "[ \"\$(pwd -P)\" = \"$PROJECT\" ]" \
  "[ ! -e \"$CANARY_SECRET\" ]" \
  "printf '%s\\n' BOUNDARY_ENVIRONMENT_OK" \
  >"$CANARY_HOOK"
chmod 500 "$CANARY_HOOK"

CANARY_BOUNDARY_BIN="$(
  create_production_boundary "$CANARY_CONTROL" "$CANARY_ROOT" "$CANARY_CACHE_BASE"
)"
CANARY_BOUNDARY_WRAPPER="$CANARY_BOUNDARY_BIN/bash"
test -x "$CANARY_BOUNDARY_WRAPPER"
run_contained_hook \
  "$CANARY_BOUNDARY_WRAPPER" \
  "$CANARY_ROOT" \
  "$CANARY_HOOK" \
  "$CANARY_INPUT" \
  "$CANARY_OUTPUT" \
  "$CANARY_ERROR"
test ! -s "$CANARY_ERROR"
test "$(cat "$CANARY_OUTPUT")" = BOUNDARY_ENVIRONMENT_OK

TRACE_COUNT="$(find "$CONTROL" "$CANARY_CONTROL" -type f -name 'hook-trace.jsonl' \
  -exec cat {} + | wc -l | tr -d ' ')"
test "$TRACE_COUNT" = 6

printf '%s\n' \
  'PASS: actual hooks and environment canary run through the production Bubblewrap wrapper'
