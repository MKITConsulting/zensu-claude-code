#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALL_FIXTURE="$ROOT/tests/structure/fixtures/install-claude-runtime-fixture.js"
PASS=0
FAIL=0
SKIPPED=0

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

bash_matcher_hooks() {
  # ONE spelling of "which hooks match the Bash tool". A matcher is a REGEX, and
  # it is ANCHORED here: an exact-string filter silently drops the ".*" capability
  # gate — the hook that is decision-bearing for a Bash payload — and any future
  # "Bash|Edit" alternation, so the caller would report a working feature while
  # never testing the gate that decides it. A malformed regex falls back to exact
  # string equality rather than to "matches everything".
  HOOKS_FILE="$1" node -e '
    const fs = require("node:fs");
    const config = JSON.parse(fs.readFileSync(process.env.HOOKS_FILE, "utf8"));
    const names = new Set();
    for (const entry of config.hooks?.PreToolUse || []) {
      let matches = false;
      try {
        matches = new RegExp(`^(?:${entry.matcher ?? ".*"})$`).test("Bash");
      } catch {
        matches = entry.matcher === "Bash";
      }
      if (!matches) continue;
      for (const hook of entry.hooks || []) {
        const found = /hooks\/([A-Za-z0-9._-]+\.sh)/.exec(String(hook.command || ""));
        if (found) names.add(found[1]);
      }
    }
    process.stdout.write([...names].sort().join("\n"));
  '
}

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

# Prints the gate's permission decision, or "allow" when it emitted none, for a
# gate executed from an ARBITRARY runtime root. gate_decision below pins the
# 0.16.1 root every Part A check uses; the Part B checks vary the root, and both
# share this one implementation so the stderr and decision handling cannot drift
# apart between them.
gate_decision_from() {
  local root="$1" hook="$2" payload="$3" out="$TMP/doctor-gate.out" err="$TMP/doctor-gate.err"
  if printf '%s' "$payload" \
      | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
        CLAUDE_PROJECT_DIR="$PROJECT" \
        bash "$root/hooks/$hook" >"$out" 2>"$err"; then
    :
  else
    printf 'hook-exit-nonzero\n'
    return
  fi
  # stdout is the decision channel; stderr is NOT empty here by design. A failed
  # bind makes the binder print its "context plugin root is neither the
  # executing plugin nor a compatible upgrade of it" diagnostic before any gate
  # decides, so requiring an empty stderr would grade every allow as a failure.
  # Anything OTHER than that diagnostic — a crash, a node stack — still fails,
  # so a real regression stays visible.
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

gate_decision() {
  gate_decision_from "$SYNTHETIC_EXISTING_ROOT" "$1" "$2"
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

# ---------------------------------------------------------------------------
# Part B — compatible-lineage binding.
#
# $SESSION above is bound to the 0.17.0 candidate root. Every check here serves
# that same record from a DIFFERENT executing root and asks whether the session
# survives. The 0.16.1 case is already pinned above and must keep denying; these
# add the two directions it cannot observe.
#
# The synthetic roots carry identical bytes and differ only in their declared
# version, which is the point: the verdict must come from the declared lineage,
# never from the code happening to match.
# ---------------------------------------------------------------------------

# Snapshot the record BYTES before any Part B call touches it. Comparing two
# fields after the first binding would miss a rewrite of any other field, and
# would miss one performed by the SubagentStart calls further down entirely.
RECORD_BEFORE_PART_B="$(cat "$RECORD")"

SYNTHETIC_COMPATIBLE_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.17.1 "$ROOT_REVISION"
)"
SYNTHETIC_BREAKING_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.18.0 "$ROOT_REVISION"
)"

if runtime_roots_are_safe \
      "$SYNTHETIC_CACHE_PARENT" \
      "$SYNTHETIC_COMPATIBLE_ROOT" 0.17.1 \
      "$SYNTHETIC_BREAKING_ROOT" 0.18.0 \
    && [ "$SYNTHETIC_COMPATIBLE_ROOT" != "$SYNTHETIC_CANDIDATE_ROOT" ] \
    && [ "$SYNTHETIC_BREAKING_ROOT" != "$SYNTHETIC_CANDIDATE_ROOT" ] \
    && [ "$(tree_digest "$SYNTHETIC_COMPATIBLE_ROOT")" != "$(tree_digest "$SYNTHETIC_CANDIDATE_ROOT")" ]; then
  check "Part B synthetic 0.17.1 and 0.18.0 runtimes occupy distinct roots" PASS
else
  check "Part B synthetic 0.17.1 and 0.18.0 runtimes occupy distinct roots" FAIL
fi

# AC-008 — the whole point of Part B: a patch-forward runtime serves the record.
if [ "$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" pre-reviewer-capability-gate.sh "$TOOL_PAYLOAD")" = allow ]; then
  check "AC-008 a 0.17.0 record binds to an executing 0.17.1 runtime" PASS
else
  check "AC-008 a 0.17.0 record binds to an executing 0.17.1 runtime" FAIL
fi

# AC-009 — the zero-major minor is the breaking axis, so this must still deny.
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh "$TOOL_PAYLOAD")" = deny ]; then
  check "AC-009 a 0.17.0 record denies an executing 0.18.0 runtime" PASS
else
  check "AC-009 a 0.17.0 record denies an executing 0.18.0 runtime" FAIL
fi

# An ordinary Bash command is the discrimination test for AC-008: the doctor
# allowance would let a Bash call through even on a denied bind, so a Bash
# check that passed for THAT reason would prove nothing about the binding.
COMPATIBLE_BASH="$(bash_payload "$SESSION" 'ls -la')"
if [ "$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")" = allow ] \
    && [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")" = deny ]; then
  check "AC-008 an ordinary Bash command runs again under a compatible upgrade, and only there" PASS
else
  check "AC-008 an ordinary Bash command runs again under a compatible upgrade, and only there" FAIL
fi

# Every hook on the Bash matcher has to agree, for the same reason Part A
# enumerates them: a deny from any one of them wins.
BASH_MATCHER_HOOKS="$(bash_matcher_hooks "$SYNTHETIC_COMPATIBLE_ROOT/hooks/hooks.json")"
if [ -z "$BASH_MATCHER_HOOKS" ]; then
  check "AC-008 every Bash-matcher hook allows under a compatible upgrade (no hooks enumerated)" FAIL
else
  BASH_MATCHER_OK=1
  for BASH_HOOK in $BASH_MATCHER_HOOKS; do
    if [ "$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" "$BASH_HOOK" "$COMPATIBLE_BASH")" != allow ]; then
      BASH_MATCHER_OK=0
      printf '    hook %s did not allow\n' "$BASH_HOOK"
    fi
  done
  if [ "$BASH_MATCHER_OK" -eq 1 ]; then
    check "AC-008 every Bash-matcher hook allows under a compatible upgrade" PASS
  else
    check "AC-008 every Bash-matcher hook allows under a compatible upgrade" FAIL
  fi
fi

# AC-014 — the session has to survive its next compaction too, not only its
# tool calls. A resume SessionStart re-reads the record from the new root.
resume_payload() {
  EVENT=SessionStart SESSION="$1" CWD="$PROJECT" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: process.env.EVENT,
      source: "resume",
      session_id: process.env.SESSION,
      cwd: process.env.CWD,
    }));
  '
}
# Prints "bound" on a clean success, "refused" ONLY when the hook failed with the
# lineage diagnostic, and "other:<rc>" for any other nonzero exit. A bare `!= 0`
# would be satisfied by a node crash or a missing fixture root, so the negative
# arms below would pass while proving nothing about the version rule.
session_start_verdict() {
  local root="$1" payload="$2" rc=0
  # The status is captured from the pipeline itself, NOT after an `if` compound:
  # an `if` whose condition fails and which has no `else` exits 0, so `$?` read
  # after `fi` would report 0 for every refusal and the other:<rc> label would
  # never carry a real code.
  printf '%s' "$payload" \
    | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$root/hooks/session-start-session-control.sh" \
      >"$TMP/partb-start.out" 2>"$TMP/partb-start.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    if [ -s "$TMP/partb-start.err" ]; then
      printf 'bound-with-stderr\n'
    else
      printf 'bound\n'
    fi
    return
  fi
  if grep -qF 'plugin nor a compatible upgrade of it' "$TMP/partb-start.err"; then
    printf 'refused\n'
  else
    printf 'other:%s\n' "$rc"
  fi
}
RESUME_PAYLOAD="$(resume_payload "$SESSION")"
RESUME_COMPATIBLE="$(session_start_verdict "$SYNTHETIC_COMPATIBLE_ROOT" "$RESUME_PAYLOAD")"
RESUME_BREAKING="$(session_start_verdict "$SYNTHETIC_BREAKING_ROOT" "$RESUME_PAYLOAD")"
if [ "$RESUME_COMPATIBLE" = bound ] && [ "$RESUME_BREAKING" = refused ]; then
  check "AC-014 a resume SessionStart reuses the record under a compatible upgrade only" PASS
else
  check "AC-014 a resume SessionStart reuses the record under a compatible upgrade only (compatible=$RESUME_COMPATIBLE breaking=$RESUME_BREAKING)" FAIL
fi

# The rule compares DECLARED versions and never content, so a compatible-version
# root whose hook bytes differ binds too. That is the accepted trade, and it is
# pinned here so a later narrowing is deliberate rather than accidental.
SYNTHETIC_ALTERED_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.17.1 "$ROOT_REVISION"
)"
printf '%s\n' '# altered runtime byte: the rule is version-declared, not content-addressed' \
  >> "$SYNTHETIC_ALTERED_ROOT/hooks/lib/zensu-session.sh"
if [ "$(tree_digest "$SYNTHETIC_ALTERED_ROOT")" != "$(tree_digest "$SYNTHETIC_COMPATIBLE_ROOT")" ] \
    && [ "$(gate_decision_from "$SYNTHETIC_ALTERED_ROOT" pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")" = allow ]; then
  check "a compatible-version root with ALTERED bytes still binds (accepted content-blindness)" PASS
else
  check "a compatible-version root with ALTERED bytes still binds (accepted content-blindness)" FAIL
fi

# AC-015 — the review chain fans out subagents, so SubagentStart has to bind too.
subagent_payload() {
  EVENT=SubagentStart SESSION="$1" CWD="$PROJECT" AGENT="$2" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: process.env.EVENT,
      session_id: process.env.SESSION,
      cwd: process.env.CWD,
      agent_type: process.env.AGENT,
      agent_id: "agent-partb-1",
    }));
  '
}
SUBAGENT_PAYLOAD="$(subagent_payload "$SESSION" 'zensu:review-aspect')"
SUB_COMPATIBLE="$(session_start_verdict "$SYNTHETIC_COMPATIBLE_ROOT" "$SUBAGENT_PAYLOAD")"
SUB_BREAKING="$(session_start_verdict "$SYNTHETIC_BREAKING_ROOT" "$SUBAGENT_PAYLOAD")"
if [ "$SUB_COMPATIBLE" = bound ] && [ "$SUB_BREAKING" = refused ]; then
  check "AC-015 a SubagentStart binds to the parent record under a compatible upgrade only" PASS
else
  check "AC-015 a SubagentStart binds to the parent record under a compatible upgrade only (compatible=$SUB_COMPATIBLE breaking=$SUB_BREAKING)" FAIL
fi

# The record is an immutable anchor: nothing above may have rewritten it — not
# the gate calls, not the resume, not the SubagentStart binds. Whole-file byte
# comparison, and placed AFTER the last binding call rather than before it.
if [ "$RECORD_BEFORE_PART_B" = "$(cat "$RECORD")" ]; then
  check "AC-014 surviving a compatible upgrade never rewrites the record (byte-identical)" PASS
else
  check "AC-014 surviving a compatible upgrade never rewrites the record (byte-identical)" FAIL
fi

# The orphan predicate's own copy of the comparison (claude-hook-session-v1.js
# resolveOrphanedProjectRoot) is lineage-relaxed too, and nothing else exercises
# it across versions: test-orphaned-project-root.sh has no multi-version fixture,
# so the case lives here where the synthetic roots already exist. Under an equal
# root servesRecordedRuntime short-circuits before any manifest read, so that
# suite alone cannot tell the new comparison from the old byte equality.
ORPHAN_SESSION='versioned-upgrade-orphan-session'
ORPHAN_PROJECT="$TMP/orphan-project"
mkdir -p "$ORPHAN_PROJECT"
ORPHAN_START="$(EVENT=SessionStart SESSION="$ORPHAN_SESSION" CWD="$ORPHAN_PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
printf '%s' "$ORPHAN_START" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$ORPHAN_PROJECT" \
    bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" \
    >/dev/null 2>&1
rm -rf "$ORPHAN_PROJECT"
orphan_predicate() {
  local root="$1"
  EVENT=PreToolUse SESSION="$ORPHAN_SESSION" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: process.env.EVENT,
      session_id: process.env.SESSION,
      tool_name: "Read",
      tool_input: {file_path: "README.md"},
    }));
  ' | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      node "$root/hooks/lib/claude-hook-session-v1.js" orphaned-project-root \
      >/dev/null 2>&1 && printf 'orphaned\n' || printf 'not-orphaned\n'
}
if [ "$(orphan_predicate "$SYNTHETIC_CANDIDATE_ROOT")" = orphaned ] \
    && [ "$(orphan_predicate "$SYNTHETIC_COMPATIBLE_ROOT")" = orphaned ] \
    && [ "$(orphan_predicate "$SYNTHETIC_BREAKING_ROOT")" = not-orphaned ]; then
  check "the orphaned-project-root predicate follows the same lineage rule" PASS
else
  check "the orphaned-project-root predicate follows the same lineage rule (equal=$(orphan_predicate "$SYNTHETIC_CANDIDATE_ROOT") compatible=$(orphan_predicate "$SYNTHETIC_COMPATIBLE_ROOT") breaking=$(orphan_predicate "$SYNTHETIC_BREAKING_ROOT"))" FAIL
fi

# Known gap 1, pinned as the CURRENT behavior rather than left accidental: the
# review-evidence lease still compares its recorded plugin_root strictly, so a
# lease minted before the upgrade is refused after it — and because listRecords
# validates every record and propagates the first failure, that one record fails
# every later lease operation for the session. Closing it needs a lease-schema
# change (the record carries no plugin_version), so this asserts the refusal
# exists and will fail loudly the day someone changes it silently.
if grep -qF 'if (record.plugin_root !== binding.pluginRoot) fail(' \
      "$ROOT/hooks/lib/review-evidence-lease-v1.js" \
    && ! grep -qF 'servesRecordedRuntime' "$ROOT/hooks/lib/review-evidence-lease-v1.js" \
    && grep -qF 'Known gap 1' "$ROOT/CLAUDE.md"; then
  check "the review-evidence lease keeps the strict comparison, documented as gap 1" PASS
else
  check "the review-evidence lease keeps the strict comparison, documented as gap 1" FAIL
fi

# AC-013 — a record and workflow document minted by the PREVIOUS RELEASE, from
# that release's own committed bytes, must still validate under the current
# tree. The synthetic roots above all carry the current tree at a relabelled
# version, so none of them can observe schema drift across a real release.
PREVIOUS_RELEASE_TAG=v0.17.3
PREVIOUS_RELEASE_REVISION="$(
  git -C "$ROOT" rev-parse --verify --quiet "${PREVIOUS_RELEASE_TAG}^{commit}" 2>/dev/null
)"
if [ -z "$PREVIOUS_RELEASE_REVISION" ]; then
  # Not a PASS: reporting a skip as a pass makes "29 PASS" unable to distinguish
  # "the cross-release schema check ran" from "it silently retired itself in a
  # shallow clone". CI fetches with depth 0, so the tag is present there.
  printf '  SKIP  %s\n' \
    "AC-013 previous-release record validates under the current tree ($PREVIOUS_RELEASE_TAG not present)"
  SKIPPED=$((SKIPPED + 1))
else
  GOLDEN_DATA="$TMP/golden-data/zensu-zensu"
  GOLDEN_PROJECT="$TMP/golden-project"
  GOLDEN_SESSION='versioned-upgrade-previous-release-session'
  mkdir -p "$GOLDEN_DATA" "$GOLDEN_PROJECT"
  GOLDEN_ROOT="$(
    node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.17.3 \
      "$PREVIOUS_RELEASE_REVISION"
  )"
  GOLDEN_START="$(EVENT=SessionStart SESSION="$GOLDEN_SESSION" CWD="$GOLDEN_PROJECT" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: process.env.EVENT,
      source: "startup",
      session_id: process.env.SESSION,
      cwd: process.env.CWD,
    }));
  ')"
  if printf '%s' "$GOLDEN_START" \
      | CLAUDE_PLUGIN_ROOT="$GOLDEN_ROOT" CLAUDE_PLUGIN_DATA="$GOLDEN_DATA" \
        CLAUDE_PROJECT_DIR="$GOLDEN_PROJECT" \
        bash "$GOLDEN_ROOT/hooks/session-start-session-control.sh" \
        >"$TMP/golden-start.out" 2>"$TMP/golden-start.err"; then
    GOLDEN_START_RC=0
  else
    GOLDEN_START_RC=$?
  fi
  GOLDEN_KEY="$(
    node "$GOLDEN_ROOT/hooks/lib/session-control-core-v1.js" session-key "$GOLDEN_SESSION"
  )"
  GOLDEN_RECORD="$GOLDEN_DATA/session-control/v1/records/$GOLDEN_KEY.json"
  # Read the previous release's artifacts with the CURRENT tree's core: that is
  # the direction that matters, and readContext revalidates the digest, the
  # manifest version, the schema and the principal profiles as it goes.
  if [ "$GOLDEN_START_RC" -eq 0 ] && [ -f "$GOLDEN_RECORD" ] \
      && CORE="$ROOT/hooks/lib/session-control-core-v1.js" \
         RECORDS_DIR="$GOLDEN_DATA/session-control/v1/records" \
         SESSION_INPUT="$GOLDEN_SESSION" PROJECT_INPUT="$GOLDEN_PROJECT" node -e '
        const core = require(process.env.CORE);
        const context = core.readContext({
          recordsDir: process.env.RECORDS_DIR,
          sessionId: process.env.SESSION_INPUT,
          expectedHost: "claude",
        });
        if (context.plugin_version !== "0.17.3") process.exit(1);
        const state = core.readWorkflowState({
          projectRoot: process.env.PROJECT_INPUT,
          sessionId: process.env.SESSION_INPUT,
        });
        if (!state || typeof state.workflow_state !== "string") process.exit(1);
      '; then
    check "AC-013 a $PREVIOUS_RELEASE_TAG record and workflow document validate under the current tree" PASS
  else
    check "AC-013 a $PREVIOUS_RELEASE_TAG record and workflow document validate under the current tree" FAIL
  fi
fi

# AC-011 — the predicate's own truth table. Driven from here rather than
# registered separately: this suite is already in every profile, so the unit
# file cannot be silently left out of a shard.
RECOGNIZER_UNIT="$ROOT/tests/structure/zensu-doctor-invocation.test.js"
if [ -f "$RECOGNIZER_UNIT" ] && node --test "$RECOGNIZER_UNIT" >"$TMP/recognizer-unit.out" 2>&1; then
  check "the recognizer unit suite passes (driven from here — nothing else referenced it)" PASS
else
  check "the recognizer unit suite passes (driven from here — nothing else referenced it)" FAIL
  sed -n '1,40p' "$TMP/recognizer-unit.out" 2>/dev/null
fi

LINEAGE_UNIT="$ROOT/tests/structure/session-control-lineage.test.js"
if [ -f "$LINEAGE_UNIT" ] && node --test "$LINEAGE_UNIT" >"$TMP/lineage-unit.out" 2>&1; then
  check "AC-011 runtimeLineageCompatible unit suite passes" PASS
else
  check "AC-011 runtimeLineageCompatible unit suite passes" FAIL
  sed -n '1,40p' "$TMP/lineage-unit.out" 2>/dev/null
fi

# The non-sibling case is the one that cannot be inferred from the version
# numbers: it is what keeps a working checkout declaring a compatible version
# from adopting an installed session's record. servesRecordedRuntime requires
# the executing root to sit beside the recorded one — every marketplace install
# lands there, a development checkout does not.
DETACHED_CACHE_PARENT="$TMP/checkout/zensu/zensu"
DETACHED_COMPATIBLE_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$DETACHED_CACHE_PARENT" 0.17.1 "$ROOT_REVISION"
)"
if [ "$(gate_decision_from "$DETACHED_COMPATIBLE_ROOT" pre-reviewer-capability-gate.sh "$TOOL_PAYLOAD")" = deny ]; then
  check "a compatible version outside the install parent is denied" PASS
else
  check "a compatible version outside the install parent is denied" FAIL
fi

# Serving a record is not re-binding it. The record stays write-once and keeps
# naming the runtime the session was bound to, which is what every attestation,
# every cross-session comparison and the digest check all still read.
if RECORD_INPUT="$RECORD" ROOT_INPUT="$SYNTHETIC_CANDIDATE_ROOT" node -e '
      const fs = require("node:fs");
      const record = JSON.parse(fs.readFileSync(process.env.RECORD_INPUT, "utf8"));
      const root = fs.realpathSync.native(process.env.ROOT_INPUT);
      if (record.plugin_root !== root || record.plugin_version !== "0.17.0") process.exit(1);
    '; then
  check "a compatible runtime serves the record without rewriting it" PASS
else
  check "a compatible runtime serves the record without rewriting it" FAIL
fi

# ---------------------------------------------------------------------------
# Part C — naming the incompatible-lineage state, and adopting out of it.
#
# Requirement labels here are namespaced AC-C##/FR-C## on purpose: Parts A and B
# already own AC-008/AC-014/AC-015 for unrelated assertions, and this repo never
# recycles an id. Grep by an id and you get exactly one check.
#
# Part B pins that a breaking-boundary runtime DENIES. Everything here is about
# what the user is then told and what they can do about it. The session below is
# its OWN record on purpose: adoption mutates the record it acts on, and every
# Part A/B check above reads the shared one.
# ---------------------------------------------------------------------------

ADOPT_SESSION='versioned-upgrade-adoption-session'
ADOPT_START_PAYLOAD="$(EVENT=SessionStart SESSION="$ADOPT_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
if printf '%s' "$ADOPT_START_PAYLOAD" \
    | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" \
      >/dev/null 2>&1; then
  ADOPT_START_RC=0
else
  ADOPT_START_RC=$?
fi
ADOPT_KEY="$(node "$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/session-control-core-v1.js" session-key "$ADOPT_SESSION")"
ADOPT_RECORD="$SHARED_DATA/session-control/v1/records/$ADOPT_KEY.json"
if [ "$ADOPT_START_RC" -eq 0 ] && [ -f "$ADOPT_RECORD" ]; then
  check "Part C a second 0.17.0 session registers for the adoption checks" PASS
else
  check "Part C a second 0.17.0 session registers for the adoption checks" FAIL
fi

ADOPT_TOOL_PAYLOAD="$(EVENT=PreToolUse SESSION="$ADOPT_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
    tool_name: "Read",
    tool_input: {file_path: "README.md"},
  }));
')"

# AC-C01 — the state is NAMED, and named only here. The two relaxable predicates
# must both answer no: this is a third diagnosis, never a widening of either.
ADOPT_VERSIONS="$(
  printf '%s' "$ADOPT_TOOL_PAYLOAD" \
    | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_BREAKING_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      node "$SYNTHETIC_BREAKING_ROOT/hooks/lib/claude-hook-session-v1.js" incompatible-runtime 2>/dev/null
)" || ADOPT_VERSIONS=''
if [ "$ADOPT_VERSIONS" = "$(printf '0.17.0\t0.18.0')" ]; then
  check "AC-C01 the incompatible-runtime predicate names both declared versions" PASS
else
  check "AC-C01 the incompatible-runtime predicate names both declared versions (got '$ADOPT_VERSIONS')" FAIL
fi
if ! printf '%s' "$ADOPT_TOOL_PAYLOAD" \
      | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_BREAKING_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
        node "$SYNTHETIC_BREAKING_ROOT/hooks/lib/claude-hook-session-v1.js" unregistered >/dev/null 2>&1 \
    && ! printf '%s' "$ADOPT_TOOL_PAYLOAD" \
      | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_BREAKING_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
        node "$SYNTHETIC_BREAKING_ROOT/hooks/lib/claude-hook-session-v1.js" orphaned-project-root >/dev/null 2>&1; then
  check "AC-C01 the two relaxable predicates stay false for the lineage state" PASS
else
  check "AC-C01 the two relaxable predicates stay false for the lineage state" FAIL
fi

# AC-C02 — the doctor row. The bite is the ABSENCE of the old wording: before the
# fourth branch existed this state fell through to a line asserting the session
# has no record, which is false.
DOCTOR_OUT="$TMP/adopt-doctor.out"
CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" \
  bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-doctor.sh" >"$DOCTOR_OUT" 2>/dev/null
if grep -qF 'declares an incompatible lineage' "$DOCTOR_OUT" \
    && grep -qF 'record minted by 0.17.0, executing 0.18.0' "$DOCTOR_OUT" \
    && ! grep -qF 'no valid Session Control record' "$DOCTOR_OUT"; then
  check "AC-C02 the doctor row names both versions and never claims 'no valid record'" PASS
else
  check "AC-C02 the doctor row names both versions and never claims 'no valid record'" FAIL
  grep -F 'binding:' "$DOCTOR_OUT" 2>/dev/null
fi

# AC-C03 — the Stop hook RELEASES. Blocking here loops a session whose Edit and
# Bash channels are already denied, so the remedy never reaches the user.
ADOPT_STOP_PAYLOAD="$(EVENT=Stop SESSION="$ADOPT_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
STOP_OUT="$TMP/adopt-stop.out"
STOP_ERR="$TMP/adopt-stop.err"
printf '%s' "$ADOPT_STOP_PAYLOAD" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_BREAKING_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_BREAKING_ROOT/hooks/stop-chain-enforcer.sh" >"$STOP_OUT" 2>"$STOP_ERR"
# The greps name literals ONLY the third release emits. "releasing Stop" and "no
# completion was proven" also appear in the two opt-out releases (ZENSU_CHAIN=off,
# hooks.chainEnforcer=false), which read the ambient environment — so on a host
# with either set this check would have gone green while the new branch was dead.
if [ ! -s "$STOP_OUT" ] \
    && grep -qF 'record minted by 0.17.0, executing 0.18.0' "$STOP_ERR" \
    && grep -qF '/zensu:adopt-session --confirm' "$STOP_ERR" \
    && grep -qF 'no completion was proven' "$STOP_ERR"; then
  check "AC-C03 the Stop hook releases the lineage state instead of blocking" PASS
else
  check "AC-C03 the Stop hook releases the lineage state instead of blocking" FAIL
  head -c 400 "$STOP_ERR" 2>/dev/null
fi

# AC-C04 — the remedy has to be INVOCABLE, and a deny from any hook on the Bash
# matcher wins. Enumerated from hooks.json for the same reason Part A and B do:
# a hook added later is covered without editing this check.
ADOPT_CMD="CLAUDE_PLUGIN_DATA=$SHARED_DATA CLAUDE_PROJECT_DIR=$PROJECT bash $SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh --confirm"
ADOPT_BASH_PAYLOAD="$(bash_payload "$ADOPT_SESSION" "$ADOPT_CMD")"
# The SAME enumerator Part B uses, called rather than re-spelled: two copies
# already disagreed on anchoring, and a matcher regex is exactly the thing whose
# semantics must not drift between two checks that both claim "every Bash hook".
ADOPT_MATCHER_HOOKS="$(bash_matcher_hooks "$SYNTHETIC_BREAKING_ROOT/hooks/hooks.json")"
# The recognizer refuses on win32 BY DESIGN (the MSYS spelling gap the module
# header documents), so the expected verdict is platform-dependent — exactly as
# Part A branches for the diagnostic. Hardcoding `allow` would make this check
# unpassable on the Windows shard where the suite is registered, and the gap would
# stop being a verified contract.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    ADOPT_EXPECTED=deny
    ADOPT_LABEL="refuses the adoption command on win32 (documented MSYS spelling gap)"
    ;;
  *)
    ADOPT_EXPECTED=allow
    ADOPT_LABEL="lets the adoption command through"
    ;;
esac
# Required membership, not just non-emptiness: a matcher or regex change that
# quietly enumerated fewer hooks would otherwise leave this green while covering
# a subset. Same rule as O21b in test-orphaned-project-root.sh.
ADOPT_ENUMERATION_MISSING=''
for required in pre-bash-zensu-gate.sh pre-bash-source-write-gate.sh pre-write-secret-scan.sh pre-reviewer-capability-gate.sh; do
  case "$ADOPT_MATCHER_HOOKS" in
    *"$required"*) ;;
    *) ADOPT_ENUMERATION_MISSING="$ADOPT_ENUMERATION_MISSING $required" ;;
  esac
done
ADOPT_GATE_FAILURES=''
while IFS= read -r hook_name; do
  [ -n "$hook_name" ] || continue
  # pre-bash-zensu-gate.sh is the ONE exception on win32, and not because of the
  # recognizer: it exits 0 before it ever binds when the command carries no
  # `zensu` CLI verb (`[ -z "$INVOCATIONS" ] && exit 0`), and the adoption command
  # carries none. So it allows on EVERY platform, for a reason that has nothing to
  # do with the MSYS spelling gap the other three are refused by. Expecting deny
  # from it graded the early exit as a regression.
  hook_expected="$ADOPT_EXPECTED"
  if [ "$hook_name" = pre-bash-zensu-gate.sh ]; then
    hook_expected=allow
  fi
  if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" "$hook_name" "$ADOPT_BASH_PAYLOAD")" != "$hook_expected" ]; then
    ADOPT_GATE_FAILURES="$ADOPT_GATE_FAILURES $hook_name"
  fi
done <<EOF
$ADOPT_MATCHER_HOOKS
EOF
if [ -n "$ADOPT_MATCHER_HOOKS" ] && [ -z "$ADOPT_ENUMERATION_MISSING" ] && [ -z "$ADOPT_GATE_FAILURES" ]; then
  check "AC-C04 every hook on the Bash matcher $ADOPT_LABEL" PASS
else
  check "AC-C04 every hook on the Bash matcher $ADOPT_LABEL (unexpected:$ADOPT_GATE_FAILURES missing-from-enumeration:$ADOPT_ENUMERATION_MISSING)" FAIL
fi

# The discrimination test for AC-C04: the recognizer must stay exactly this
# narrow. An ordinary Bash command in the same state still denies, so an allow
# above cannot have come from the bind succeeding.
#
# Graded through the ".*" capability gate, NOT pre-bash-zensu-gate.sh: that gate
# exits 0 before it ever binds when the command carries no zensu invocation
# (`[ -z "$INVOCATIONS" ] && exit 0`), so `ls -la` is allowed there in EVERY
# state and would grade this discrimination as a failure for a reason that has
# nothing to do with binding. Part B above compares the same way.
ADOPT_ORDINARY="$(bash_payload "$ADOPT_SESSION" 'ls -la')"
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh "$ADOPT_ORDINARY")" = deny ]; then
  check "AC-C04 an ordinary Bash command in the same state still denies" PASS
else
  check "AC-C04 an ordinary Bash command in the same state still denies" FAIL
fi

# FR-C01 — the deny REASON, not just the decision. gate_decision_from discards
# permissionDecisionReason, so every check above would stay green with the
# `incompatible-runtime` scope deleted — which is exactly how that scope shipped
# with no caller at all in the first place.
gate_reason_from() {
  local root="$1" hook="$2" payload="$3" out="$TMP/reason-gate.out"
  # ZENSU_API_URL is neutralized and nothing else is: a local backend makes
  # pre-bash-zensu-gate.sh drop every invocation and exit BEFORE its bind, so the
  # reason would be empty for a cause unrelated to the scope under test.
  # ZENSU_MCP_GATE is neutralized too. It IS read ambiently — pre-bash-zensu-gate.sh
  # and pre-bash-source-write-gate.sh both honour the exported escape — and a
  # developer running the suite from a shell that exported it would get an empty
  # reason and a failure misdiagnosed as the scope being gone.
  printf '%s' "$payload" \
    | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_API_URL= ZENSU_MCP_GATE= \
      bash "$root/hooks/$hook" >"$out" 2>/dev/null
  OUT_FILE="$out" node -e '
    const fs = require("node:fs");
    const raw = fs.readFileSync(process.env.OUT_FILE, "utf8").trim();
    if (raw === "") process.exit(0);
    try {
      const parsed = JSON.parse(raw);
      process.stdout.write(String(parsed?.hookSpecificOutput?.permissionDecisionReason || ""));
    } catch { process.stdout.write("UNPARSEABLE"); }
  '
}
ADOPT_EDIT_PAYLOAD="$(EVENT=PreToolUse SESSION="$ADOPT_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
    tool_name: "Edit",
    tool_input: {file_path: "README.md", old_string: "a", new_string: "b"},
  }));
')"
# The fourth emitter, pre-bash-zensu-gate.sh, needs a DIFFERENT payload: it exits
# before its bind for any command without a `zensu <noun> <verb>` form, so an Edit
# never reaches it. Pairing each hook with a payload it can actually see is what
# keeps this loop from silently covering three of four.
LINEAGE_REASON_FAILURES=''
ADOPT_ZENSU_PAYLOAD="$(bash_payload "$ADOPT_SESSION" 'zensu features list')"
# All FIVE deniers, including pre-reviewer-capability-gate.sh, which spells the
# lineage cause in JS rather than through zensu_emit_hook_session_deny — without
# it the whole branch could be deleted with this loop green.
for reason_hook in pre-edit-tdd-reminder.sh pre-bash-source-write-gate.sh pre-write-secret-scan.sh pre-bash-zensu-gate.sh pre-reviewer-capability-gate.sh; do
  # Each gate gets a payload its own matcher accepts in production:
  # pre-bash-source-write-gate.sh is registered on `Bash` ONLY, so grading it with
  # an Edit payload would test a shape it never receives.
  case "$reason_hook" in
    pre-bash-zensu-gate.sh) reason_payload="$ADOPT_ZENSU_PAYLOAD" ;;
    pre-bash-source-write-gate.sh) reason_payload="$ADOPT_ORDINARY" ;;
    *) reason_payload="$ADOPT_EDIT_PAYLOAD" ;;
  esac
  reason_text="$(gate_reason_from "$SYNTHETIC_BREAKING_ROOT" "$reason_hook" "$reason_payload")"
  case "$reason_text" in
    *"record was minted by 0.17.0 and 0.18.0 is executing"*"/zensu:adopt-session"*) ;;
    *) LINEAGE_REASON_FAILURES="$LINEAGE_REASON_FAILURES $reason_hook" ;;
  esac
done
if [ -z "$LINEAGE_REASON_FAILURES" ]; then
  check "FR-C01 every gate denying an Edit in the lineage state names both versions and the remedy" PASS
else
  check "FR-C01 every gate denying an Edit in the lineage state names both versions and the remedy (generic:$LINEAGE_REASON_FAILURES)" FAIL
fi

# FR-C02 — the Edit matcher itself. pre-edit-tdd-reminder.sh is what denies
# writes in this state, and no check exercised its matcher at all: a regression
# that made it ALLOW a write here would have been invisible.
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-edit-tdd-reminder.sh "$ADOPT_EDIT_PAYLOAD")" = deny ]; then
  check "FR-C02 the Edit gate denies a write in the lineage state" PASS
else
  check "FR-C02 the Edit gate denies a write in the lineage state" FAIL
fi

# FR-C03 — negative controls for the WRITE-capable second recognized command.
# It had exactly one positive assertion; widening the argument whitelist,
# dropping the main-principal conjunct, or admitting the script under a foreign
# root all left the suite green.
ADOPT_SCRIPT="$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh"
RECOGNIZER_FAILURES=''
recognizer_denies() {
  [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh "$1")" = deny ] \
    || RECOGNIZER_FAILURES="$RECOGNIZER_FAILURES $2"
}
recognizer_denies "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --forge")" undeclared-flag
recognizer_denies "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --confirm --confirm")" repeated-flag
recognizer_denies "$(bash_payload "$ADOPT_SESSION" "bash $SYNTHETIC_CANDIDATE_ROOT/hooks/lib/zensu-session-adopt.sh --confirm")" foreign-root
recognizer_denies "$(bash_payload "$ADOPT_SESSION" "EVIL=1 bash $ADOPT_SCRIPT")" undeclared-assignment
recognizer_denies "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --confirm" 'zensu:review-aspect')" reviewer-principal
# The reviewer case above is graded through the JS gate, whose own principal
# check short-circuits before the recognizer — so it cannot pin the INDEPENDENT
# shell conjunct in zensu_doctor_allowed. Grade it through two Bash gates too.
for shell_gate in pre-bash-source-write-gate.sh pre-write-secret-scan.sh; do
  # Positive control on the SAME bare shape first: without it, a recognizer that
  # stopped accepting the bare form would make both gates deny for the wrong
  # reason and the principal assertion below would stay green.
  # Graded against $ADOPT_EXPECTED, never a hardcoded `allow`: the recognizer
  # refuses on win32 by design, so a fixed expectation is unpassable on the
  # Windows shard — the same defect class AC-C04 was corrected for.
  if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" "$shell_gate" \
      "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --confirm")")" != "$ADOPT_EXPECTED" ]; then
    RECOGNIZER_FAILURES="$RECOGNIZER_FAILURES bare-form-control:$shell_gate"
  fi
  if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" "$shell_gate" \
      "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --confirm" 'zensu:review-aspect')")" != deny ]; then
    RECOGNIZER_FAILURES="$RECOGNIZER_FAILURES shell-principal:$shell_gate"
  fi
done
if [ -z "$RECOGNIZER_FAILURES" ]; then
  check "FR-C03 the second recognized command is admitted in exactly one shape, for the main thread only" PASS
else
  check "FR-C03 the second recognized command is admitted in exactly one shape, for the main thread only (allowed:$RECOGNIZER_FAILURES)" FAIL
fi

# AC-C05 — the self-closing gate, and the single most important check here: a
# workflow document this runtime cannot read must REFUSE adoption. Driven by
# corrupting the document's schema, which is exactly what a real persisted-shape
# break would look like to the reader.
ADOPT_STATE_FILE="$PROJECT/.zensu/state/tdd-phase-$ADOPT_KEY.json"
ADOPT_STATE_BACKUP="$TMP/adopt-state-backup.json"
if [ -f "$ADOPT_STATE_FILE" ]; then
  cp "$ADOPT_STATE_FILE" "$ADOPT_STATE_BACKUP"
  STATE_FILE="$ADOPT_STATE_FILE" node -e '
    const fs = require("node:fs");
    const state = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
    state.schema_version = 999;
    fs.writeFileSync(process.env.STATE_FILE, JSON.stringify(state));
  '
  SCHEMA_VERDICT="$(
    RECORDS="$SHARED_DATA/session-control/v1/records" SID="$ADOPT_SESSION" \
    DATA="$SHARED_DATA" PROJECT_IN="$PROJECT" EXEC_ROOT="$SYNTHETIC_BREAKING_ROOT" \
    node -e '
      const core = require(process.env.EXEC_ROOT + "/hooks/lib/session-control-core-v1.js");
      const verdict = core.adoptableRecord({
        recordsDir: process.env.RECORDS, sessionId: process.env.SID, host: "claude",
        pluginData: process.env.DATA, projectRoot: process.env.PROJECT_IN,
        executingPluginRoot: process.env.EXEC_ROOT,
      });
      process.stdout.write(verdict.ok ? "ok" : verdict.reason);
    ' 2>/dev/null
  )" || SCHEMA_VERDICT='threw'
  cp "$ADOPT_STATE_BACKUP" "$ADOPT_STATE_FILE"
  if [ "$SCHEMA_VERDICT" = workflow-schema-mismatch ]; then
    check "AC-C05 a workflow document this runtime cannot read refuses adoption" PASS
  else
    check "AC-C05 a workflow document this runtime cannot read refuses adoption (got '$SCHEMA_VERDICT')" FAIL
  fi
else
  check "AC-C05 a workflow document this runtime cannot read refuses adoption" FAIL
fi

# AC-C06 — two disagreements are never one diagnosis. A record whose plugin_data
# points elsewhere is not adoptable no matter how the lineage compares.
FOREIGN_DATA="$TMP/foreign-plugin-data"
mkdir -p "$FOREIGN_DATA" && chmod 700 "$FOREIGN_DATA"
FOREIGN_VERDICT="$(
  RECORDS="$SHARED_DATA/session-control/v1/records" SID="$ADOPT_SESSION" \
  DATA="$FOREIGN_DATA" PROJECT_IN="$PROJECT" EXEC_ROOT="$SYNTHETIC_BREAKING_ROOT" \
  node -e '
    const core = require(process.env.EXEC_ROOT + "/hooks/lib/session-control-core-v1.js");
    const verdict = core.adoptableRecord({
      recordsDir: process.env.RECORDS, sessionId: process.env.SID, host: "claude",
      pluginData: process.env.DATA, projectRoot: process.env.PROJECT_IN,
      executingPluginRoot: process.env.EXEC_ROOT,
    });
    process.stdout.write(verdict.ok ? "ok" : verdict.reason);
  ' 2>/dev/null
)" || FOREIGN_VERDICT='threw'
if [ "$FOREIGN_VERDICT" = plugin-data-mismatch ]; then
  check "AC-C06 a second disagreement is never relaxed alongside the lineage" PASS
else
  check "AC-C06 a second disagreement is never relaxed alongside the lineage (got '$FOREIGN_VERDICT')" FAIL
fi

# AC-C07 — the repair itself, end to end through the shipped entry point. This
# runs LAST of the adoption checks because it mutates the record.
ADOPT_REPORT_OUT="$TMP/adopt-report.out"
if CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" >"$ADOPT_REPORT_OUT" 2>&1 \
    && grep -qF 'ADOPTABLE' "$ADOPT_REPORT_OUT" \
    && grep -qF 'Nothing has been changed' "$ADOPT_REPORT_OUT" \
    && [ "$(node -p 'require(process.argv[1]).plugin_version' "$ADOPT_RECORD")" = 0.17.0 ]; then
  check "AC-C07 the bare entry point reports adoptable and changes nothing" PASS
else
  check "AC-C07 the bare entry point reports adoptable and changes nothing" FAIL
  head -c 400 "$ADOPT_REPORT_OUT" 2>/dev/null
fi

ADOPT_RECORD_BEFORE="$(cat "$ADOPT_RECORD")"
cp "$ADOPT_RECORD" "$TMP/adopt-record-before.json"

# AC-C08 — seed the lease store so the sweep has something to sweep. Without this
# the whole moving branch never runs: discardSupersededLeases returns 0 through
# its readdir catch when the per-session records directory does not exist, so a
# --confirm assertion on an empty store proves nothing about the discard.
# Two leases with exactly one difference: the root they name.
# Canonicalized: the sweep resolves plugin data through canonicalDirectory, so on
# a host where the temp root is a symlink (/var -> /private/var on macOS) a
# seeded path built from the raw value would be a different directory and the
# sweep would read an empty one.
CANONICAL_SHARED_DATA="$(cd -P -- "$SHARED_DATA" && pwd -P)"
ADOPT_LEASE_DIR="$CANONICAL_SHARED_DATA/review-evidence/v1/records/$ADOPT_KEY"
ADOPT_LEASE_ASIDE="$CANONICAL_SHARED_DATA/review-evidence/v1/superseded/$ADOPT_KEY"
mkdir -p "$ADOPT_LEASE_DIR"
# Rendered NATIVE, not with `pwd -P`. discardSupersededLeases compares the lease's
# recorded plugin_root against the value in the adopted RECORD, which Session
# Control stores host-natively — `D:\a\...` on Windows. `pwd -P` in Git Bash
# yields the MSYS spelling `/d/a/...`, so a fixture built from it never matched
# and the keep-lease was swept with the rest: 4 set aside where 3 were expected.
# Production leases are written from the same native value this renders.
# Derived with fs.realpathSync.native, which is EXACTLY what canonicalDirectory
# stores in the record — and what discardSupersededLeases compares a lease
# against. Neither `pwd -P` nor zensu-host-path.sh produces that string on
# Windows: the first yields the MSYS spelling `/d/a/...`, the second a
# drive-qualified FORWARD-slash `D:/a/...`, while the record holds `D:\a\...`.
# Both earlier spellings made the keep-lease fixture miss and be swept with the
# rest — 4 set aside where 3 were expected.
native_root() {
  ROOT_IN="$1" node -e 'process.stdout.write(require("node:fs").realpathSync.native(process.env.ROOT_IN))'
}
CANONICAL_BREAKING_ROOT="$(native_root "$SYNTHETIC_BREAKING_ROOT")"
CANONICAL_CANDIDATE_ROOT="$(native_root "$SYNTHETIC_CANDIDATE_ROOT")"
# The fixtures are shaped as listRecords would accept them — a `rel1_<32 hex>`
# stem whose `lease_id` matches the filename — because the keep-branch mirrors
# that acceptance. Stubs named `stale.json`/`current.json` would BOTH be swept,
# and the check would then pass or fail for a reason unrelated to plugin_root.
LEASE_KEEP_ID="rel1_$(printf 'a%.0s' $(seq 1 32))"
LEASE_STALE_ID="rel1_$(printf 'b%.0s' $(seq 1 32))"
LEASE_MISMATCH_ID="rel1_$(printf 'c%.0s' $(seq 1 32))"
# Written through node, never printf: a native Windows root carries backslashes,
# and splicing one into JSON by hand produces an invalid document. The sweep would
# then fail to parse it, treat it as unreadable and set it aside — the keep-lease
# would "pass" its move for the wrong reason and the count would still be wrong.
write_lease() {
  LEASE_FILE="$1" LEASE_ID="$2" LEASE_ROOT="$3" node -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.env.LEASE_FILE, JSON.stringify({
      lease_id: process.env.LEASE_ID,
      plugin_root: process.env.LEASE_ROOT,
    }) + "\n");
  '
}
write_lease "$ADOPT_LEASE_DIR/$LEASE_STALE_ID.json" "$LEASE_STALE_ID" "$CANONICAL_CANDIDATE_ROOT"
write_lease "$ADOPT_LEASE_DIR/$LEASE_KEEP_ID.json" "$LEASE_KEEP_ID" "$CANONICAL_BREAKING_ROOT"
# Two entries that exercise the conjuncts the plugin_root check alone cannot: a
# body whose lease_id disagrees with its filename, and a leftover .tmp of the
# kind a killed lease write leaves behind. listRecords rejects both, so both must
# be swept even though one names the CURRENT installation.
write_lease "$ADOPT_LEASE_DIR/$LEASE_MISMATCH_ID.json" "$LEASE_STALE_ID" "$CANONICAL_BREAKING_ROOT"
printf '{"lease_id":"%s"}\n' "$LEASE_KEEP_ID" > "$ADOPT_LEASE_DIR/.partial.tmp"

ADOPT_CONFIRM_OUT="$TMP/adopt-confirm.out"
if CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
    >"$ADOPT_CONFIRM_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$ADOPT_CONFIRM_OUT" \
    && grep -qF 'provenance       : recorded' "$ADOPT_CONFIRM_OUT"; then
  check "AC-C07 --confirm performs the adoption" PASS
else
  check "AC-C07 --confirm performs the adoption" FAIL
  head -c 400 "$ADOPT_CONFIRM_OUT" 2>/dev/null
fi

# The ORDINARY case: a session that never minted a review-evidence lease has no
# per-session records directory at all, so the sweep takes its readdir-failure
# path. That path returned a scalar while every other path returned an object,
# which made the reporter throw AFTER the record swap had already succeeded — a
# completed adoption reported as a failure. Driven on its own session, because
# the seeded one above can never reach it.
NOLEASE_SESSION='versioned-upgrade-adoption-no-lease'
NOLEASE_START="$(EVENT=SessionStart SESSION="$NOLEASE_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
printf '%s' "$NOLEASE_START" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" >/dev/null 2>&1
NOLEASE_KEY="$(node "$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/session-control-core-v1.js" session-key "$NOLEASE_SESSION")"
NOLEASE_OUT="$TMP/adopt-nolease.out"
if [ ! -e "$CANONICAL_SHARED_DATA/review-evidence/v1/records/$NOLEASE_KEY" ] \
    && CLAUDE_CODE_SESSION_ID="$NOLEASE_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" \
      bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
      >"$NOLEASE_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$NOLEASE_OUT" \
    && grep -qF 'leases set aside : 0' "$NOLEASE_OUT" \
    && grep -qF 'leases stuck     : 0' "$NOLEASE_OUT" \
    && grep -qF 'bound again from the next tool call' "$NOLEASE_OUT"; then
  check "AC-C08 a session with no lease store adopts cleanly and exits 0" PASS
else
  check "AC-C08 a session with no lease store adopts cleanly and exits 0" FAIL
  head -c 400 "$NOLEASE_OUT" 2>/dev/null
fi

# AC-C08 — exactly the stale lease moves, the current one stays, none is deleted,
# and the count is reported rather than absorbed.
if grep -qF 'leases set aside : 3' "$ADOPT_CONFIRM_OUT" \
    && grep -qF 'leases stuck     : 0' "$ADOPT_CONFIRM_OUT" \
    && [ ! -e "$ADOPT_LEASE_DIR/$LEASE_STALE_ID.json" ] \
    && [ -f "$ADOPT_LEASE_ASIDE/$LEASE_STALE_ID.json" ] \
    && [ ! -e "$ADOPT_LEASE_DIR/$LEASE_MISMATCH_ID.json" ] \
    && [ -f "$ADOPT_LEASE_ASIDE/$LEASE_MISMATCH_ID.json" ] \
    && [ ! -e "$ADOPT_LEASE_DIR/.partial.tmp" ] \
    && [ -f "$ADOPT_LEASE_ASIDE/.partial.tmp" ] \
    && [ -f "$ADOPT_LEASE_DIR/$LEASE_KEEP_ID.json" ]; then
  check "AC-C08 every entry listRecords rejects is set aside; only a valid current lease is kept" PASS
else
  check "AC-C08 every entry listRecords rejects is set aside; only a valid current lease is kept" FAIL
  grep -F 'leases' "$ADOPT_CONFIRM_OUT" 2>/dev/null
  ls -1 "$ADOPT_LEASE_DIR" "$ADOPT_LEASE_ASIDE" 2>/dev/null | head -12
fi

# The point of the whole feature: the session works again, in place. Both are
# graded through the capability gate, the one that actually denied before.
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh "$ADOPT_TOOL_PAYLOAD")" = allow ] \
    && [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh "$ADOPT_ORDINARY")" = allow ]; then
  check "AC-C07 after adoption the same session binds and ordinary commands run again" PASS
else
  check "AC-C07 after adoption the same session binds and ordinary commands run again" FAIL
fi

# The previous record is set aside, never overwritten, and stays readable.
ADOPT_SUPERSEDED="$SHARED_DATA/session-control/v1/records/$ADOPT_KEY.superseded-0.17.0.json"
if [ -f "$ADOPT_SUPERSEDED" ] \
    && [ "$ADOPT_RECORD_BEFORE" = "$(cat "$ADOPT_SUPERSEDED")" ] \
    && [ "$(node -p 'require(process.argv[1]).plugin_version' "$ADOPT_RECORD")" = 0.18.0 ]; then
  check "AC-C07 the superseded record is set aside byte-for-byte, never rewritten" PASS
else
  check "AC-C07 the superseded record is set aside byte-for-byte, never rewritten" FAIL
fi

# AC-C10 — provenance is a history entry and the record gains NO field. This is
# what keeps the release a patch: a record shape change would itself be the
# breaking bump this feature exists to survive.
if STATE_IN="$PROJECT/.zensu/state/tdd-phase-$ADOPT_KEY.json" \
    BEFORE_IN="$TMP/adopt-record-before.json" AFTER_IN="$ADOPT_RECORD" node -e '
      const fs = require("node:fs");
      const state = JSON.parse(fs.readFileSync(process.env.STATE_IN, "utf8"));
      const entry = (state.history || []).find((h) => h.phase === "RUNTIME_ADOPTED");
      if (!entry) process.exit(1);
      if (entry.reason !== "runtime-adopted: 0.17.0 -> 0.18.0") process.exit(1);
      const before = JSON.parse(fs.readFileSync(process.env.BEFORE_IN, "utf8"));
      const after = JSON.parse(fs.readFileSync(process.env.AFTER_IN, "utf8"));
      const beforeKeys = Object.keys(before).sort().join(",");
      const afterKeys = Object.keys(after).sort().join(",");
      if (beforeKeys !== afterKeys) process.exit(1);
      if (before.created_at !== after.created_at) process.exit(1);
    ' 2>/dev/null; then
  check "AC-C10 provenance is a history entry, the record keeps its exact field set" PASS
else
  check "AC-C10 provenance is a history entry, the record keeps its exact field set" FAIL
fi

# AC-C09 — the rest of the refusal truth table, one check per condition, each
# with exactly ONE thing wrong. Run after the adoption because they reuse the
# record it produced: it now declares 0.18.0, which is what makes the backwards
# and non-sibling cases expressible from the roots this suite already built.
adoption_reason() {
  RECORDS="${1}" SID="${2}" DATA="${3}" PROJECT_IN="${4}" EXEC_ROOT="${5}" node -e '
    const core = require(process.env.EXEC_ROOT + "/hooks/lib/session-control-core-v1.js");
    const verdict = core.adoptableRecord({
      recordsDir: process.env.RECORDS, sessionId: process.env.SID, host: "claude",
      pluginData: process.env.DATA, projectRoot: process.env.PROJECT_IN,
      executingPluginRoot: process.env.EXEC_ROOT,
    });
    process.stdout.write(verdict.ok ? "ok" : verdict.reason);
  ' 2>/dev/null || printf 'threw'
}
ADOPT_RECORDS_DIR="$SHARED_DATA/session-control/v1/records"

REASON_BACKWARDS="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$PROJECT" "$SYNTHETIC_CANDIDATE_ROOT")"
if [ "$REASON_BACKWARDS" = executing-runtime-older ]; then
  check "AC-C09 an OLDER installation may not adopt a newer record" PASS
else
  check "AC-C09 an OLDER installation may not adopt a newer record (got '$REASON_BACKWARDS')" FAIL
fi

REASON_DETACHED="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$PROJECT" "$DETACHED_COMPATIBLE_ROOT")"
if [ "$REASON_DETACHED" = not-a-sibling-installation ]; then
  check "AC-C09 an installation outside the install parent may not adopt" PASS
else
  check "AC-C09 an installation outside the install parent may not adopt (got '$REASON_DETACHED')" FAIL
fi

FOREIGN_PROJECT="$TMP/foreign-project"
mkdir -p "$FOREIGN_PROJECT"
REASON_PROJECT="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$FOREIGN_PROJECT" "$SYNTHETIC_BREAKING_ROOT")"
if [ "$REASON_PROJECT" = project-root-mismatch ]; then
  check "AC-C09 a record for another project may not be adopted" PASS
else
  check "AC-C09 a record for another project may not be adopted (got '$REASON_PROJECT')" FAIL
fi

REASON_ABSENT="$(adoption_reason "$ADOPT_RECORDS_DIR" 'versioned-upgrade-no-such-session' "$SHARED_DATA" "$PROJECT" "$SYNTHETIC_BREAKING_ROOT")"
if [ "$REASON_ABSENT" = record-unreadable ]; then
  check "AC-C09 a session with no record is not adoptable" PASS
else
  check "AC-C09 a session with no record is not adoptable (got '$REASON_ABSENT')" FAIL
fi

# The record now names $SYNTHETIC_BREAKING_ROOT, so that root has nothing left to
# adopt. Without this refusal the adoption would be a way to re-mint a HEALTHY
# session's record, which is the one thing immutability exists to prevent.
REASON_SERVED="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$PROJECT" "$SYNTHETIC_BREAKING_ROOT")"
if [ "$REASON_SERVED" = already-served ]; then
  check "AC-C09 a record this installation already serves is not adoptable" PASS
else
  check "AC-C09 a record this installation already serves is not adoptable (got '$REASON_SERVED')" FAIL
fi

# A sibling root whose manifest declares no usable version is not a lineage claim
# at all — it is a root that cannot be identified, and it must refuse under its
# own reason rather than being compared as if it had one.
UNIDENTIFIED_ROOT="$(
  node "$INSTALL_FIXTURE" "$ROOT" "$SYNTHETIC_CACHE_PARENT" 0.19.0 "$ROOT_REVISION" 2>/dev/null
)"
if [ -n "$UNIDENTIFIED_ROOT" ] && [ -d "$UNIDENTIFIED_ROOT" ] \
    && MANIFEST="$UNIDENTIFIED_ROOT/.claude-plugin/plugin.json" node -e '
      const fs = require("node:fs");
      const file = process.env.MANIFEST;
      const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
      manifest.version = "not a version";
      fs.writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
    '; then
  REASON_UNIDENTIFIED="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$PROJECT" "$UNIDENTIFIED_ROOT")"
  if [ "$REASON_UNIDENTIFIED" = executing-runtime-unidentified ]; then
    check "AC-C09 an installation that declares no usable version may not adopt" PASS
  else
    check "AC-C09 an installation that declares no usable version may not adopt (got '$REASON_UNIDENTIFIED')" FAIL
  fi
else
  check "AC-C09 an installation that declares no usable version may not adopt (fixture unavailable)" FAIL
fi

# TEST-2 (second half) — after the adoption the same Edit is no longer denied by
# the binding. This is the pair that makes the first half a discrimination rather
# than a constant.
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-edit-tdd-reminder.sh "$ADOPT_EDIT_PAYLOAD")" = allow ]; then
  check "FR-C02 the Edit gate allows the same write once the session is adopted" PASS
else
  check "FR-C02 the Edit gate allows the same write once the session is adopted" FAIL
fi

# FR-C04 — the bare entry point must be filesystem-inert. That claim is the
# premise the whole gate widening rests on, and $PROJECT always already has
# .zensu/state, so no check above could observe a regression. Driven on a project
# that has none.
INERT_PROJECT="$TMP/inert-project"
mkdir -p "$INERT_PROJECT"
INERT_SESSION='versioned-upgrade-adoption-inert'
INERT_START="$(EVENT=SessionStart SESSION="$INERT_SESSION" CWD="$INERT_PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
printf '%s' "$INERT_START" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$INERT_PROJECT" \
    bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" >/dev/null 2>&1
rm -rf "$INERT_PROJECT/.zensu"
INERT_OUT="$TMP/adopt-inert.out"
CLAUDE_CODE_SESSION_ID="$INERT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$INERT_PROJECT" \
  bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" >"$INERT_OUT" 2>&1
if grep -qF 'ADOPTABLE' "$INERT_OUT" && [ ! -e "$INERT_PROJECT/.zensu" ]; then
  check "FR-C04 the bare entry point creates nothing in the project" PASS
else
  check "FR-C04 the bare entry point creates nothing in the project (.zensu present: $([ -e "$INERT_PROJECT/.zensu" ] && echo yes || echo no))" FAIL
  head -c 300 "$INERT_OUT" 2>/dev/null
fi

# AC-C10 — the no-workflow-document provenance branch, which adoptableRecord
# explicitly blesses. Before this it was reachable by no check, so a regression
# routing it back through the FAILURE branch — reporting a completed adoption as
# an anomaly — would have been invisible. The fixture already exists: the same
# .zensu-less project TEST-4 just proved the bare form leaves alone.
INERT_CONFIRM_OUT="$TMP/adopt-inert-confirm.out"
if CLAUDE_CODE_SESSION_ID="$INERT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$INERT_PROJECT" \
    bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
    >"$INERT_CONFIRM_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$INERT_CONFIRM_OUT" \
    && grep -qF 'provenance       : no-workflow-document' "$INERT_CONFIRM_OUT" \
    && grep -qF 'had no workflow document' "$INERT_CONFIRM_OUT"; then
  check "AC-C10 a session with no workflow document adopts and says so, rather than reporting a fault" PASS
else
  check "AC-C10 a session with no workflow document adopts and says so, rather than reporting a fault" FAIL
  head -c 400 "$INERT_CONFIRM_OUT" 2>/dev/null
fi

# JUDGE-3 — the whole feature needs the SUPERSEDED installation to still exist.
# Remove the recorded root and the diagnosis degrades to the `unbound` row whose
# wording this work exists to remove. Pinned so the boundary is a stated contract
# rather than an unnoticed fallback.
PRUNED_CACHE_PARENT="$TMP/pruned/zensu/zensu"
PRUNED_ROOT="$(node "$INSTALL_FIXTURE" "$ROOT" "$PRUNED_CACHE_PARENT" 0.17.0 "$ROOT_REVISION" 2>/dev/null)"
PRUNED_SUCCESSOR="$(node "$INSTALL_FIXTURE" "$ROOT" "$PRUNED_CACHE_PARENT" 0.18.0 "$ROOT_REVISION" 2>/dev/null)"
PRUNED_DATA="$TMP/pruned-data"
mkdir -p "$PRUNED_DATA" && chmod 700 "$PRUNED_DATA"
PRUNED_SESSION='versioned-upgrade-pruned-root'
PRUNED_START="$(EVENT=SessionStart SESSION="$PRUNED_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
if [ -n "$PRUNED_ROOT" ] && [ -n "$PRUNED_SUCCESSOR" ] \
    && printf '%s' "$PRUNED_START" \
      | CLAUDE_PLUGIN_ROOT="$PRUNED_ROOT" CLAUDE_PLUGIN_DATA="$PRUNED_DATA" \
        CLAUDE_PROJECT_DIR="$PROJECT" \
        bash "$PRUNED_ROOT/hooks/session-start-session-control.sh" >/dev/null 2>&1; then
  # Positive control FIRST: without it both assertions below are absences that a
  # fixture which never worked would satisfy just as well.
  PRUNED_KEY="$(node "$PRUNED_SUCCESSOR/hooks/lib/session-control-core-v1.js" session-key "$PRUNED_SESSION")"
  PRUNED_BEFORE="$(adoption_reason "$PRUNED_DATA/session-control/v1/records" "$PRUNED_SESSION" "$PRUNED_DATA" "$PROJECT" "$PRUNED_SUCCESSOR")"
  PRUNED_CONTROL=no
  [ -f "$PRUNED_DATA/session-control/v1/records/$PRUNED_KEY.json" ] \
    && [ "$PRUNED_BEFORE" = ok ] && PRUNED_CONTROL=yes
  rm -rf "$PRUNED_ROOT"
  PRUNED_VERDICT="$(adoption_reason "$PRUNED_DATA/session-control/v1/records" "$PRUNED_SESSION" "$PRUNED_DATA" "$PROJECT" "$PRUNED_SUCCESSOR")"
  PRUNED_TOOL_PAYLOAD="$(EVENT=PreToolUse SESSION="$PRUNED_SESSION" CWD="$PROJECT" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: process.env.EVENT,
      session_id: process.env.SESSION,
      cwd: process.env.CWD,
      tool_name: "Read",
      tool_input: {file_path: "README.md"},
    }));
  ')"
  PRUNED_NAMED=no
  if printf '%s' "$PRUNED_TOOL_PAYLOAD" \
      | CLAUDE_PLUGIN_ROOT="$PRUNED_SUCCESSOR" CLAUDE_PLUGIN_DATA="$PRUNED_DATA" \
        node "$PRUNED_SUCCESSOR/hooks/lib/claude-hook-session-v1.js" incompatible-runtime >/dev/null 2>&1; then
    PRUNED_NAMED=yes
  fi
  if [ "$PRUNED_CONTROL" = yes ] && [ "$PRUNED_VERDICT" = record-unreadable ] && [ "$PRUNED_NAMED" = no ]; then
    check "JUDGE-3 a pruned recorded installation is neither named nor adoptable (documented boundary)" PASS
  else
    check "JUDGE-3 a pruned recorded installation is neither named nor adoptable (control=$PRUNED_CONTROL before='$PRUNED_BEFORE' verdict='$PRUNED_VERDICT' named=$PRUNED_NAMED)" FAIL
  fi
else
  check "JUDGE-3 a pruned recorded installation is neither named nor adoptable (fixture unavailable)" FAIL
fi

# CONV-1 — the skill's refusal table is the one independent re-encoding of
# ADOPTION_REFUSALS (the REMEDY map uses computed keys off the constant and
# cannot drift on the key side). Pinned here, the T42 analogue for this feature.
# Both sides come from the SAME tree, and the probe cannot pass by crashing: an
# empty stdout was its success signal, so a renamed skill, an unloadable core or a
# removed constant set all read as "no gaps" — the exact drift it exists to catch.
ADOPT_SKILL="$SYNTHETIC_BREAKING_ROOT/skills/adopt-session/SKILL.md"
REFUSAL_GAPS="$(
  CORE="$SYNTHETIC_BREAKING_ROOT/hooks/lib/session-control-core-v1.js" SKILL="$ADOPT_SKILL" node -e '
    const fs = require("node:fs");
    const core = require(process.env.CORE);
    const skill = fs.readFileSync(process.env.SKILL, "utf8");
    const reasons = Object.values(core.ADOPTION_REFUSALS);
    if (reasons.length !== 8) { process.stdout.write("count:" + reasons.length); process.exit(0); }
    const missing = reasons.filter((r) => !skill.includes(r));
    process.stdout.write(missing.length ? missing.join(",") : "ok");
  ' 2>/dev/null
)" || REFUSAL_GAPS=threw
if [ "$REFUSAL_GAPS" = ok ]; then
  check "CONV-1 every ADOPTION_REFUSALS value is documented in the adoption skill" PASS
else
  check "CONV-1 every ADOPTION_REFUSALS value is documented in the adoption skill (missing: $REFUSAL_GAPS)" FAIL
fi

# The lease-id hand-copy. `LEASE_RECORD_ID_RE` in the core must equal `LEASE_ID_RE`
# in review-evidence-lease-v1.js: the core cannot require that module (it requires
# the binder, which requires the core), so the two are held in step by hand — and
# by this pin, the way within() <-> isInside is held. Without it a widened lease id
# shape would make the sweep silently set aside every new-format lease, green.
CORE_LEASE_RE="$(grep -oE "const LEASE_RECORD_ID_RE = /[^;]*/" "$ROOT/hooks/lib/session-control-core-v1.js" | sed 's/.*= //')"
OWNER_LEASE_RE="$(grep -oE "const LEASE_ID_RE = /[^;]*/" "$ROOT/hooks/lib/review-evidence-lease-v1.js" | sed 's/.*= //')"
if [ -n "$CORE_LEASE_RE" ] && [ "$CORE_LEASE_RE" = "$OWNER_LEASE_RE" ]; then
  check "the LEASE_ID_RE hand-copy in the core matches its owner byte-for-byte" PASS
else
  check "the LEASE_ID_RE hand-copy in the core matches its owner byte-for-byte (core='$CORE_LEASE_RE' owner='$OWNER_LEASE_RE')" FAIL
fi

# The reserved phase cannot be minted by a caller — the same protection
# CHAIN_RECOVERED has, for the same reason: a forgeable provenance entry is worse
# than none, because it is believed.
#
# CLAUDE_CODE_SESSION_ID is REQUIRED here, and its absence is what made an earlier
# version of this check vacuous: zensu-log.sh binds the model session before it
# reaches the --phase case, so without it the helper exits 2 on the binding and
# the guard never runs — green in a tree with the guard deleted. The session binds
# now because the adoption above re-pointed its record at $SYNTHETIC_BREAKING_ROOT.
# Both reserved spellings are probed, and the assertion is on the guard's own
# message, not merely on a non-zero exit.
FORGE_ERR="$TMP/forge-phase.err"
CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_ROOT="$SYNTHETIC_BREAKING_ROOT" \
  bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-log.sh" --phase RUNTIME_ADOPTED --step forged \
  >/dev/null 2>"$FORGE_ERR"
FORGE_PHASE_RC=$?
FORGE_REASON_ERR="$TMP/forge-reason.err"
CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_ROOT="$SYNTHETIC_BREAKING_ROOT" \
  bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-log.sh" --phase IMPL --step forged \
  --reason "runtime-adopted: 0.1.0 -> 9.9.9" >/dev/null 2>"$FORGE_REASON_ERR"
FORGE_REASON_RC=$?
if [ "$FORGE_PHASE_RC" -ne 0 ] \
    && grep -qF 'RUNTIME_ADOPTED is written only by the session adoption' "$FORGE_ERR" \
    && [ "$FORGE_REASON_RC" -ne 0 ] \
    && grep -qF "a 'runtime-adopted: ' reason is reserved for the session adoption" "$FORGE_REASON_ERR"; then
  check "the RUNTIME_ADOPTED provenance phase and reason cannot be minted through --phase" PASS
else
  check "the RUNTIME_ADOPTED provenance phase and reason cannot be minted through --phase (phase_rc=$FORGE_PHASE_RC reason_rc=$FORGE_REASON_RC)" FAIL
  head -c 200 "$FORGE_ERR" 2>/dev/null; head -c 200 "$FORGE_REASON_ERR" 2>/dev/null
fi

printf '%s\n' '----' \
  "test-versioned-plugin-upgrade: $PASS PASS / $FAIL FAIL / $SKIPPED SKIP"
[ "$FAIL" -eq 0 ]
