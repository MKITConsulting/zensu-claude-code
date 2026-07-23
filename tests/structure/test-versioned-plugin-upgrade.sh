#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALL_FIXTURE="$ROOT/tests/structure/fixtures/install-claude-runtime-fixture.js"
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

TMP_RAW="$(mktemp -d "${TMPDIR:-/tmp}/zensu-versioned-upgrade-XXXXXX")" \
  || { printf '%s\n' 'test-versioned-plugin-upgrade: cannot create isolated temp directory' >&2; exit 1; }
[ -n "$TMP_RAW" ] && [ -d "$TMP_RAW" ] && [ ! -L "$TMP_RAW" ] \
  || { printf '%s\n' 'test-versioned-plugin-upgrade: temp directory is unsafe' >&2; exit 1; }
TMP="$(cd -P -- "$TMP_RAW" && pwd -P)" \
  || { printf '%s\n' 'test-versioned-plugin-upgrade: cannot canonicalize temp directory' >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# This offline structure test intentionally materializes both roots from the
# current checkout. It proves create-once, root-binding, and fail-closed
# invariants only. The Promptfoo upgrade profile supplies the authoritative
# real-v0.16.1 provenance and long-lived Claude process evidence.
SYNTHETIC_EXISTING_ROOT="$TMP/cache/zensu/zensu/0.16.1"
SYNTHETIC_CANDIDATE_ROOT="$TMP/cache/zensu/zensu/0.17.0"
SHARED_DATA="$TMP/data/zensu-zensu"
PROJECT="$TMP/project"
mkdir -p "$SHARED_DATA" "$PROJECT"

tree_digest() {
  ROOT_INPUT="$1" node -e '
    const crypto = require("node:crypto");
    const fs = require("node:fs");
    const path = require("node:path");
    const root = fs.realpathSync.native(process.env.ROOT_INPUT);
    const entries = [];
    function walk(directory) {
      for (const name of fs.readdirSync(directory).sort()) {
        const file = path.join(directory, name);
        const stat = fs.lstatSync(file);
        if (stat.isSymbolicLink()) throw new Error("fixture contains a symlink");
        if (stat.isDirectory()) walk(file);
        else if (stat.isFile()) {
          entries.push(path.relative(root, file).split(path.sep).join("/"));
          entries.push(crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex"));
        } else throw new Error("fixture contains an unsupported entry");
      }
    }
    walk(root);
    process.stdout.write(crypto.createHash("sha256").update(JSON.stringify(entries)).digest("hex"));
  '
}

node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_EXISTING_ROOT" 0.16.1 >/dev/null
EXISTING_BEFORE="$(tree_digest "$SYNTHETIC_EXISTING_ROOT")"
node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CANDIDATE_ROOT" 0.17.0 >/dev/null
EXISTING_AFTER="$(tree_digest "$SYNTHETIC_EXISTING_ROOT")"

if [ "$SYNTHETIC_EXISTING_ROOT" != "$SYNTHETIC_CANDIDATE_ROOT" ] \
    && [ "$EXISTING_BEFORE" = "$EXISTING_AFTER" ] \
    && [ "$(node -p 'require(process.argv[1]).version' "$SYNTHETIC_EXISTING_ROOT/.claude-plugin/plugin.json")" = 0.16.1 ] \
    && [ "$(node -p 'require(process.argv[1]).version' "$SYNTHETIC_CANDIDATE_ROOT/.claude-plugin/plugin.json")" = 0.17.0 ] \
    && [ "$(node -p 'require(process.argv[1]).plugins[0].source.ref' "$SYNTHETIC_CANDIDATE_ROOT/.claude-plugin/marketplace.json")" = v0.17.0 ]; then
  check "synthetic existing and candidate runtimes occupy distinct immutable SemVer roots" PASS
else
  check "synthetic existing and candidate runtimes occupy distinct immutable SemVer roots" FAIL
fi

if node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_EXISTING_ROOT" 0.17.0 >/dev/null 2>&1; then
  check "fixture installer rejects same-path replacement" FAIL
elif [ "$EXISTING_BEFORE" = "$(tree_digest "$SYNTHETIC_EXISTING_ROOT")" ]; then
  check "fixture installer rejects same-path replacement" PASS
else
  check "fixture installer rejects same-path replacement" FAIL
fi

ALIAS_ROOT="$TMP/existing-runtime-alias"
if SOURCE_INPUT="$SYNTHETIC_EXISTING_ROOT" ALIAS_INPUT="$ALIAS_ROOT" node -e '
  const fs = require("node:fs");
  fs.symlinkSync(
    process.env.SOURCE_INPUT,
    process.env.ALIAS_INPUT,
    process.platform === "win32" ? "junction" : "dir",
  );
' && ! node "$INSTALL_FIXTURE" "$SYNTHETIC_EXISTING_ROOT" "$ALIAS_ROOT/nested-runtime" 0.17.0 \
  >/dev/null 2>&1 && [ ! -e "$SYNTHETIC_EXISTING_ROOT/nested-runtime" ]; then
  check "fixture installer rejects a destination hidden beneath a symlinked parent" PASS
else
  check "fixture installer rejects a destination hidden beneath a symlinked parent" FAIL
fi

SESSION='versioned-upgrade-fresh-session'
START_PAYLOAD="$(EVENT=SessionStart SESSION="$SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
START_OUT="$TMP/start.out"
START_ERR="$TMP/start.err"
if printf '%s' "$START_PAYLOAD" \
    | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" \
      >"$START_OUT" 2>"$START_ERR"; then
  START_RC=0
else
  START_RC=$?
fi

KEY="$(node "$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/session-control-core-v1.js" session-key "$SESSION")"
RECORD="$SHARED_DATA/session-control/v1/records/$KEY.json"
BASELINE="$PROJECT/.zensu/state/tdd-phase-$KEY.json"
if [ "$START_RC" -eq 0 ] && [ ! -s "$START_ERR" ] \
    && grep -qF 'principal=main-v1' "$START_OUT" \
    && [ -f "$RECORD" ] && [ -f "$BASELINE" ] \
    && RECORD_INPUT="$RECORD" ROOT_INPUT="$SYNTHETIC_CANDIDATE_ROOT" node -e '
      const fs = require("node:fs");
      const record = require(process.env.RECORD_INPUT);
      const root = fs.realpathSync.native(process.env.ROOT_INPUT);
      if (record.plugin_root !== root || record.plugin_version !== "0.17.0") process.exit(1);
    '; then
  check "fresh candidate session binds only to the candidate root" PASS
else
  check "fresh candidate session binds only to the candidate root" FAIL
fi

TOOL_PAYLOAD="$(EVENT=PreToolUse SESSION="$SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
    tool_name: "Read",
    tool_input: {file_path: "README.md"},
  }));
')"
OLD_GATE_OUT="$TMP/old-gate.out"
OLD_GATE_ERR="$TMP/old-gate.err"
if printf '%s' "$TOOL_PAYLOAD" \
    | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_EXISTING_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$SYNTHETIC_EXISTING_ROOT/hooks/pre-reviewer-capability-gate.sh" \
      >"$OLD_GATE_OUT" 2>"$OLD_GATE_ERR"; then
  OLD_GATE_RC=0
else
  OLD_GATE_RC=$?
fi
if [ "$OLD_GATE_RC" -eq 0 ] && [ ! -s "$OLD_GATE_ERR" ] \
    && node -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (value.hookSpecificOutput?.permissionDecision !== "deny") process.exit(1);
    ' "$OLD_GATE_OUT"; then
  check "a bound session cannot be migrated to a different runtime root" PASS
else
  check "a bound session cannot be migrated to a different runtime root" FAIL
fi

UNKNOWN='recordless-candidate-session'
UNKNOWN_PAYLOAD="$(EVENT=PreToolUse SESSION="$UNKNOWN" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
    tool_name: "Read",
    tool_input: {file_path: "README.md"},
  }));
')"
UNKNOWN_OUT="$TMP/unknown.out"
UNKNOWN_ERR="$TMP/unknown.err"
if printf '%s' "$UNKNOWN_PAYLOAD" \
    | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/pre-reviewer-capability-gate.sh" \
      >"$UNKNOWN_OUT" 2>"$UNKNOWN_ERR"; then
  UNKNOWN_RC=0
else
  UNKNOWN_RC=$?
fi
if [ "$UNKNOWN_RC" -eq 0 ] && [ ! -s "$UNKNOWN_ERR" ] \
    && node -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (value.hookSpecificOutput?.permissionDecision !== "deny") process.exit(1);
    ' "$UNKNOWN_OUT"; then
  check "recordless candidate sessions remain fail-closed" PASS
else
  check "recordless candidate sessions remain fail-closed" FAIL
fi

printf '%s\n' '----' "test-versioned-plugin-upgrade: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
