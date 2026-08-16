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
BASH_MATCHER_HOOKS="$(
  HOOKS_FILE="$SYNTHETIC_COMPATIBLE_ROOT/hooks/hooks.json" node -e '
    const fs = require("node:fs");
    const config = JSON.parse(fs.readFileSync(process.env.HOOKS_FILE, "utf8"));
    const names = new Set();
    // A matcher is a REGEX, and a deny from any hook that matches "Bash" wins.
    // An exact-string filter silently drops the ".*" capability gate — the very
    // hook Part A above proves is decision-bearing for a Bash payload — and any
    // future "Bash|Edit" alternation, so the check would report a working
    // feature while never testing the gate that decides it.
    for (const entry of config.hooks?.PreToolUse || []) {
      let matches = false;
      try {
        matches = new RegExp(`^(?:${entry.matcher})$`).test("Bash");
      } catch (_error) {
        matches = entry.matcher === "Bash";
      }
      if (!matches) continue;
      for (const hook of entry.hooks || []) {
        const match = /hooks\/([A-Za-z0-9._-]+\.sh)/.exec(hook.command || "");
        if (match) names.add(match[1]);
      }
    }
    process.stdout.write([...names].join("\n"));
  '
)"
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

printf '%s\n' '----' \
  "test-versioned-plugin-upgrade: $PASS PASS / $FAIL FAIL / $SKIPPED SKIP"
[ "$FAIL" -eq 0 ]
