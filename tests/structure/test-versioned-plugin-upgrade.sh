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
ROOT_REVISION="$(git -C "$ROOT" rev-parse HEAD)"

PROVENANCE_SOURCE="$TMP/provenance-source"
PROVENANCE_CACHE_PARENT="$TMP/provenance-cache"
mkdir -p "$PROVENANCE_SOURCE/.claude-plugin" "$PROVENANCE_SOURCE/hooks"
git -C "$PROVENANCE_SOURCE" init -q
git -C "$PROVENANCE_SOURCE" config user.name 'Versioned Upgrade Test'
git -C "$PROVENANCE_SOURCE" config user.email 'versioned-upgrade@zensu.invalid'
git -C "$PROVENANCE_SOURCE" config core.hooksPath \
  "$(if [ "$(uname -s)" = MINGW* ] || [ "$(uname -s)" = MSYS* ]; then printf NUL; else printf /dev/null; fi)"
printf '%s\n' '{"name":"zensu","version":"0.16.1"}' \
  > "$PROVENANCE_SOURCE/.claude-plugin/plugin.json"
printf '%s\n' '{"name":"zensu","plugins":[{"name":"zensu","source":{"source":"github","repo":"MKITConsulting/zensu-claude-code","ref":"v0.16.1"},"version":"0.16.1"}]}' \
  > "$PROVENANCE_SOURCE/.claude-plugin/marketplace.json"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$PROVENANCE_SOURCE/hooks/example.sh"
printf '%s\n' '*.key' > "$PROVENANCE_SOURCE/.gitignore"
git -C "$PROVENANCE_SOURCE" add .
git -C "$PROVENANCE_SOURCE" -c commit.gpgsign=false commit -qm 'test: seed provenance source'
PROVENANCE_REVISION="$(git -C "$PROVENANCE_SOURCE" rev-parse HEAD)"
PROVENANCE_COMMITTED_HOOK="$TMP/provenance-committed-example.sh"
git -C "$PROVENANCE_SOURCE" show "$PROVENANCE_REVISION:hooks/example.sh" \
  > "$PROVENANCE_COMMITTED_HOOK"
PROVENANCE_ORIGINAL_BLOB="$(
  git -C "$PROVENANCE_SOURCE" rev-parse "$PROVENANCE_REVISION:hooks/example.sh"
)"
PROVENANCE_REPLACEMENT_BLOB="$(
  printf '%s\n' '#!/bin/bash' 'printf "replacement refs must not affect installation\n"' \
    | git -C "$PROVENANCE_SOURCE" hash-object -w --stdin
)"
git -C "$PROVENANCE_SOURCE" replace \
  "$PROVENANCE_ORIGINAL_BLOB" "$PROVENANCE_REPLACEMENT_BLOB"
printf '%s\n' '#!/bin/bash' 'printf "dirty worktree bytes must not be installed\n"' \
  > "$PROVENANCE_SOURCE/hooks/example.sh"
printf '%s\n' 'ignored worktree bytes must never enter an attested runtime' \
  > "$PROVENANCE_SOURCE/hooks/local-secret.key"

if PROVENANCE_RUNTIME="$(
    node "$INSTALL_FIXTURE" "$PROVENANCE_SOURCE" "$PROVENANCE_CACHE_PARENT" 0.17.0 \
      "$PROVENANCE_REVISION" 2>/dev/null
  )" \
    && git -C "$PROVENANCE_SOURCE" cat-file blob "$PROVENANCE_ORIGINAL_BLOB" \
      | grep -Fq 'replacement refs must not affect installation' \
    && [ ! -e "$PROVENANCE_RUNTIME/hooks/local-secret.key" ] \
    && cmp -s "$PROVENANCE_COMMITTED_HOOK" "$PROVENANCE_RUNTIME/hooks/example.sh" \
    && ! cmp -s "$PROVENANCE_SOURCE/hooks/example.sh" "$PROVENANCE_RUNTIME/hooks/example.sh"; then
  check "fixture installer ignores replacement refs and excludes dirty worktree data" PASS
else
  check "fixture installer ignores replacement refs and excludes dirty worktree data" FAIL
fi

SYMLINK_SOURCE="$TMP/symlink-source"
SYMLINK_CACHE_PARENT="$TMP/symlink-cache"
SYMLINK_VICTIM="$TMP/symlink-victim.json"
SYMLINK_ERR="$TMP/symlink-installer.err"
mkdir -p "$SYMLINK_SOURCE/.claude-plugin" "$SYMLINK_SOURCE/hooks"
git -C "$SYMLINK_SOURCE" init -q
git -C "$SYMLINK_SOURCE" config user.name 'Versioned Upgrade Test'
git -C "$SYMLINK_SOURCE" config user.email 'versioned-upgrade@zensu.invalid'
git -C "$SYMLINK_SOURCE" config core.hooksPath \
  "$(if [ "$(uname -s)" = MINGW* ] || [ "$(uname -s)" = MSYS* ]; then printf NUL; else printf /dev/null; fi)"
printf '%s\n' '{"name":"zensu","version":"0.16.1"}' \
  > "$SYMLINK_SOURCE/.claude-plugin/plugin.json"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$SYMLINK_SOURCE/hooks/example.sh"
printf '%s\n' '{"name":"zensu","plugins":[{"name":"zensu","source":{"source":"github","repo":"MKITConsulting/zensu-claude-code","ref":"v0.16.1"},"version":"0.16.1"}]}' \
  > "$SYMLINK_VICTIM"
SYMLINK_BLOB="$(printf '%s' "$SYMLINK_VICTIM" | git -C "$SYMLINK_SOURCE" hash-object -w --stdin)"
git -C "$SYMLINK_SOURCE" add .
git -C "$SYMLINK_SOURCE" update-index --add --cacheinfo \
  "120000,$SYMLINK_BLOB,.claude-plugin/marketplace.json"
git -C "$SYMLINK_SOURCE" -c commit.gpgsign=false commit -qm 'test: seed tracked symlink source'
SYMLINK_REVISION="$(git -C "$SYMLINK_SOURCE" rev-parse HEAD)"
if ln -s "$SYMLINK_VICTIM" "$SYMLINK_SOURCE/.claude-plugin/marketplace.json" 2>/dev/null; then
  :
fi
SYMLINK_VICTIM_CONTENT="$(cat "$SYMLINK_VICTIM")"
if ! node "$INSTALL_FIXTURE" "$SYMLINK_SOURCE" "$SYMLINK_CACHE_PARENT" 0.17.0 \
    "$SYMLINK_REVISION" >/dev/null 2>"$SYMLINK_ERR" \
    && grep -Fq 'tracked symlink is forbidden' "$SYMLINK_ERR" \
    && [ "$(cat "$SYMLINK_VICTIM")" = "$SYMLINK_VICTIM_CONTENT" ]; then
  check "fixture installer rejects tracked symlinks before any external write" PASS
else
  check "fixture installer rejects tracked symlinks before any external write" FAIL
fi

# This offline structure test intentionally materializes both roots from the
# current checkout. It proves create-once, root-binding, and fail-closed
# invariants only. The Promptfoo upgrade profile supplies the authoritative
# real-v0.16.1 provenance and long-lived Claude process evidence.
SYNTHETIC_CACHE_PARENT="$TMP/cache/zensu/zensu"
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

runtime_roots_are_safe() {
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const [parentInput, ...rootPairs] = process.argv.slice(1);
    const normalize = (value) => {
      const normalized = path.normalize(value);
      return process.platform === "win32" ? normalized.toLowerCase() : normalized;
    };
    const captureDirectory = (input) => {
      const absolute = path.resolve(input);
      const before = fs.lstatSync(absolute, { bigint: true });
      const canonical = fs.realpathSync.native(absolute);
      const after = fs.lstatSync(absolute, { bigint: true });
      if (!before.isDirectory() || before.isSymbolicLink()
          || !after.isDirectory() || after.isSymbolicLink()
          || before.dev !== after.dev || before.ino !== after.ino
          || normalize(canonical) !== normalize(absolute)) {
        throw new Error("unsafe runtime directory identity");
      }
      return canonical;
    };
    try {
      if (!parentInput || rootPairs.length === 0 || rootPairs.length % 2 !== 0) {
        throw new Error("invalid runtime-root arguments");
      }
      const parent = captureDirectory(parentInput);
      const roots = [];
      for (let index = 0; index < rootPairs.length; index += 2) {
        const root = captureDirectory(rootPairs[index]);
        const version = rootPairs[index + 1];
        const relative = path.relative(parent, root);
        const basename = path.basename(root);
        const escapedVersion = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        if (!relative || relative !== basename || path.isAbsolute(relative)
            || !new RegExp(`^\\.zensu-runtime-v${escapedVersion}-[a-f0-9]{48}$`).test(basename)) {
          throw new Error("runtime root is not one unpredictable direct child");
        }
        roots.push(normalize(root));
      }
      if (new Set(roots).size !== roots.length) {
        throw new Error("runtime roots are not distinct");
      }
    } catch (_error) {
      process.exitCode = 1;
    }
  ' "$@"
}

SYNTHETIC_EXISTING_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.16.1 "$ROOT_REVISION"
)"
EXISTING_BEFORE="$(tree_digest "$SYNTHETIC_EXISTING_ROOT")"
SYNTHETIC_CANDIDATE_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.17.0 "$ROOT_REVISION"
)"
EXISTING_AFTER="$(tree_digest "$SYNTHETIC_EXISTING_ROOT")"

if runtime_roots_are_safe \
      "$SYNTHETIC_CACHE_PARENT" \
      "$SYNTHETIC_EXISTING_ROOT" 0.16.1 \
      "$SYNTHETIC_CANDIDATE_ROOT" 0.17.0 \
    && [ "$EXISTING_BEFORE" = "$EXISTING_AFTER" ] \
    && [ "$(node -p 'require(process.argv[1]).version' "$SYNTHETIC_EXISTING_ROOT/.claude-plugin/plugin.json")" = 0.16.1 ] \
    && [ "$(node -p 'require(process.argv[1]).version' "$SYNTHETIC_CANDIDATE_ROOT/.claude-plugin/plugin.json")" = 0.17.0 ] \
    && [ "$(node -p 'require(process.argv[1]).plugins[0].source.ref' "$SYNTHETIC_CANDIDATE_ROOT/.claude-plugin/marketplace.json")" = v0.17.0 ]; then
  check "synthetic runtimes occupy distinct unpredictable immutable roots" PASS
else
  check "synthetic runtimes occupy distinct unpredictable immutable roots" FAIL
fi

SECOND_EXISTING_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.16.1 "$ROOT_REVISION"
)"
if runtime_roots_are_safe \
      "$SYNTHETIC_CACHE_PARENT" \
      "$SYNTHETIC_EXISTING_ROOT" 0.16.1 \
      "$SECOND_EXISTING_ROOT" 0.16.1 \
    && [ "$EXISTING_BEFORE" = "$(tree_digest "$SYNTHETIC_EXISTING_ROOT")" ] \
    && [ "$(node -p 'require(process.argv[1]).version' "$SECOND_EXISTING_ROOT/.claude-plugin/plugin.json")" = 0.16.1 ]; then
  check "repeated installs allocate a new root without replacing an existing runtime" PASS
else
  check "repeated installs allocate a new root without replacing an existing runtime" FAIL
fi

ALIAS_ROOT="$TMP/existing-runtime-alias"
if SOURCE_INPUT="$SYNTHETIC_EXISTING_ROOT" ALIAS_INPUT="$ALIAS_ROOT" node -e '
  const fs = require("node:fs");
  fs.symlinkSync(
    process.env.SOURCE_INPUT,
    process.env.ALIAS_INPUT,
    process.platform === "win32" ? "junction" : "dir",
  );
' && ! node "$INSTALL_FIXTURE" "$SYNTHETIC_EXISTING_ROOT" "$ALIAS_ROOT/nested-cache" 0.17.0 \
  "$ROOT_REVISION" \
  >/dev/null 2>&1 && [ ! -e "$SYNTHETIC_EXISTING_ROOT/nested-cache" ]; then
  check "fixture installer rejects a cache parent hidden inside the source by a symlink" PASS
else
  check "fixture installer rejects a cache parent hidden inside the source by a symlink" FAIL
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
      const raw = fs.readFileSync(process.argv[1], "utf8").trim();
      if (raw === "") process.exit(0);
      const value = JSON.parse(raw);
      if (value.hookSpecificOutput?.permissionDecision === "deny") process.exit(1);
    ' "$UNKNOWN_OUT"; then
  check "a recordless interactive session reaches the diagnostic instead of being denied" PASS
else
  check "a recordless interactive session reaches the diagnostic instead of being denied" FAIL
fi

for RECORDLESS_AGENT in zensu:review-aspect zensu:pr-review-worker; do
  AGENT_PAYLOAD="$(EVENT=PreToolUse SESSION="$UNKNOWN" CWD="$PROJECT" AGENT="$RECORDLESS_AGENT" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: process.env.EVENT,
      session_id: process.env.SESSION,
      agent_type: process.env.AGENT,
      cwd: process.env.CWD,
      tool_name: "Read",
      tool_input: {file_path: "README.md"},
    }));
  ')"
  AGENT_OUT="$TMP/recordless-agent.out"
  AGENT_ERR="$TMP/recordless-agent.err"
  if printf '%s' "$AGENT_PAYLOAD" \
      | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
        CLAUDE_PROJECT_DIR="$PROJECT" \
        bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/pre-reviewer-capability-gate.sh" \
        >"$AGENT_OUT" 2>"$AGENT_ERR"; then
    AGENT_RC=0
  else
    AGENT_RC=$?
  fi
  if [ "$AGENT_RC" -eq 0 ] && [ ! -s "$AGENT_ERR" ] \
      && node -e '
        const fs = require("node:fs");
        const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        if (value.hookSpecificOutput?.permissionDecision !== "deny") process.exit(1);
      ' "$AGENT_OUT"; then
    check "recordless $RECORDLESS_AGENT stays fail-closed" PASS
  else
    check "recordless $RECORDLESS_AGENT stays fail-closed" FAIL
  fi
done

# Doctor reachability in the "record present but wrong" state.
#
# $SESSION is bound to the 0.17.0 candidate root above; running a gate from the
# 0.16.1 existing root reproduces exactly what a mid-session plugin update does
# to a live session. That state is NOT relaxable and must keep denying — the
# check above pins that — but the read-only diagnostic has to stay reachable, or
# /zensu:doctor is denied by the very defect it reports.
#
# Every hook on the Bash matcher is exercised, not just one: a deny from any of
# them wins, so a single-gate check would report a working feature that does not
# work. The reviewer and rider cases are the bites that keep the allowance from
# being a general escape.
DOCTOR_CMD="CLAUDE_PLUGIN_DATA=\"$SHARED_DATA\" CLAUDE_PROJECT_DIR=\"$PROJECT\" bash \"$SYNTHETIC_EXISTING_ROOT/hooks/lib/zensu-doctor.sh\""

bash_payload() {
  EVENT=PreToolUse SESSION="$1" CWD="$PROJECT" CMD="$2" AGENT="${3:-}" node -e '
    const payload = {
      hook_event_name: process.env.EVENT,
      session_id: process.env.SESSION,
      cwd: process.env.CWD,
      tool_name: "Bash",
      tool_input: {command: process.env.CMD},
    };
    if (process.env.AGENT) payload.agent_type = process.env.AGENT;
    process.stdout.write(JSON.stringify(payload));
  '
}

# Prints the gate's permission decision, or "allow" when it emitted none.
gate_decision() {
  local hook="$1" payload="$2" out="$TMP/doctor-gate.out" err="$TMP/doctor-gate.err"
  if printf '%s' "$payload" \
      | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_EXISTING_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
        CLAUDE_PROJECT_DIR="$PROJECT" \
        bash "$SYNTHETIC_EXISTING_ROOT/hooks/$hook" >"$out" 2>"$err"; then
    :
  else
    printf 'hook-exit-nonzero\n'
    return
  fi
  # stdout is the decision channel; stderr is NOT empty here by design. A failed
  # bind makes the binder print "context plugin root does not match the executing
  # plugin" before any gate decides, so requiring an empty stderr would grade
  # every allow as a failure. Anything OTHER than that diagnostic — a crash, a
  # node stack — still fails, so a real regression stays visible.
  if [ -s "$err" ] && grep -qv '^claude hook session binder: ' "$err"; then
    printf 'hook-stderr\n'
    return
  fi
  OUT_FILE="$out" node -e '
    const fs = require("node:fs");
    const raw = fs.readFileSync(process.env.OUT_FILE, "utf8").trim();
    if (raw === "") { process.stdout.write("allow\n"); process.exit(0); }
    try {
      process.stdout.write(`${JSON.parse(raw).hookSpecificOutput?.permissionDecision || "allow"}\n`);
    } catch (_error) { process.stdout.write("unparseable\n"); }
  '
}

# The allowance is POSIX-only, and that is pinned per platform rather than
# skipped. On win32 the command token arrives in MSYS spelling while the module's
# __dirname is native; a Git Bash mount path like /tmp/... carries no drive letter
# to map and this repository does not probe the MSYS mount table, so the
# recognizer refuses there by design. Asserting DENY on Windows keeps that gap a
# verified contract instead of an unverified claim — and keeps THIS suite honest
# about the fact that Windows users see no change.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    DOCTOR_EXPECTED=deny
    DOCTOR_LABEL="refuses the diagnostic on win32 (documented MSYS spelling gap)"
    ;;
  *)
    DOCTOR_EXPECTED=allow
    DOCTOR_LABEL="lets the diagnostic through a disagreeing record"
    ;;
esac
DOCTOR_PAYLOAD="$(bash_payload "$SESSION" "$DOCTOR_CMD")"
for BASH_GATE in pre-reviewer-capability-gate.sh pre-bash-zensu-gate.sh \
  pre-bash-source-write-gate.sh pre-write-secret-scan.sh; do
  GATE_SEEN="$(gate_decision "$BASH_GATE" "$DOCTOR_PAYLOAD")"
  # pre-bash-zensu-gate.sh exits before its bind when the command runs no zensu
  # CLI binary, so it allows on every platform and cannot show the gap.
  if [ "$BASH_GATE" = pre-bash-zensu-gate.sh ]; then
    GATE_EXPECTED=allow
  else
    GATE_EXPECTED="$DOCTOR_EXPECTED"
  fi
  if [ "$GATE_SEEN" = "$GATE_EXPECTED" ]; then
    check "$BASH_GATE $DOCTOR_LABEL" PASS
  else
    check "$BASH_GATE $DOCTOR_LABEL (got $GATE_SEEN, wanted $GATE_EXPECTED)" FAIL
  fi
done

OTHER_PAYLOAD="$(bash_payload "$SESSION" 'ls -la')"
if [ "$(gate_decision pre-reviewer-capability-gate.sh "$OTHER_PAYLOAD")" = deny ]; then
  check "an ordinary Bash command still denies on a disagreeing record" PASS
else
  check "an ordinary Bash command still denies on a disagreeing record" FAIL
fi

RIDER_PAYLOAD="$(bash_payload "$SESSION" "$DOCTOR_CMD; whoami")"
if [ "$(gate_decision pre-reviewer-capability-gate.sh "$RIDER_PAYLOAD")" = deny ]; then
  check "a second command riding on the diagnostic is refused" PASS
else
  check "a second command riding on the diagnostic is refused" FAIL
fi

FOREIGN_PAYLOAD="$(bash_payload "$SESSION" "bash \"$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/zensu-doctor.sh\"")"
if [ "$(gate_decision pre-reviewer-capability-gate.sh "$FOREIGN_PAYLOAD")" = deny ]; then
  check "a doctor script outside the executing root is refused" PASS
else
  check "a doctor script outside the executing root is refused" FAIL
fi

for DOCTOR_AGENT in zensu:review-aspect zensu:pr-review-worker; do
  AGENT_DOCTOR_PAYLOAD="$(bash_payload "$SESSION" "$DOCTOR_CMD" "$DOCTOR_AGENT")"
  if [ "$(gate_decision pre-reviewer-capability-gate.sh "$AGENT_DOCTOR_PAYLOAD")" = deny ]; then
    check "$DOCTOR_AGENT never receives the diagnostic allowance" PASS
  else
    check "$DOCTOR_AGENT never receives the diagnostic allowance" FAIL
  fi
done

printf '%s\n' '----' "test-versioned-plugin-upgrade: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
