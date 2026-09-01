#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALL_FIXTURE="$ROOT/tests/structure/fixtures/install-claude-runtime-fixture.js"
PASS=0
FAIL=0
SKIPPED=0

# SKIP is a THIRD verdict, not a quiet PASS. The tally already carried a SKIPPED
# counter that nothing incremented, so a row that could not run on this host had only
# two options: claim a pass it had not earned, or fail for a reason unrelated to the
# contract it names. Both are worse than saying so. Anything that is neither PASS nor
# SKIP is still a failure — the default stays fail-closed.
check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  elif [ "$2" = SKIP ]; then
    printf '  SKIP  %s\n' "$1"
    SKIPPED=$((SKIPPED + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

# HOISTED to the very front on purpose - before the mktemp, before the first
# synthetic install. These two pins need no fixture, no synthetic install and no
# session lifecycle: they read $ROOT and compare two strings. They were the LAST
# checks in the file, behind eleven full tree installs and five session lifecycles,
# on a Windows ceiling CLAUDE.md records as UNMEASURED. That is the shape in which
# the source-write-gate suite lost its tail at check ~210 and the plan-payload
# suite at ~61 of 70, both green for everything before the kill. Same placement,
# same reason, as the routing suite's unit driver.
# THE SEAM, replacing two byte-for-byte hand-copy pins that used to stand here.
# Those pins asserted that `LEASE_RECORD_ID_RE` and `LEASE_RECORD_MAX_BYTES` in the
# core still equalled their owners in review-evidence-lease-v1.js. Review of PR #252
# recorded what that bought and what it did not: both compared source SPELLINGS
# rather than behaviour (`8388608` in the owner turned them red with nothing wrong),
# neither checked that the two sides applied the constant to the same quantity, and
# three FURTHER copied elements — the store layout, ensurePrivateDirectory and the
# ownership predicate — were never pinned at all. CLAUDE.md's own rule for that
# function ("if it needs a fourth correction, take the seam") had already fired.
#
# So the copies are gone. The core cannot require the owner — review-evidence-lease-v1.js
# requires claude-hook-session-v1.js, which requires session-control-core-v1.js, so
# that direction is a CYCLE — and the sweep therefore moved OUT of the core into
# review-evidence-sweep-v1.js, which may require the owner freely. What is pinned now
# is that arrangement, not a pair of strings: the core defines neither literal and no
# longer carries the sweep, and the sweep gets both from the owner.
#
# WORKING TREE, not HEAD: every side of this pin is read from $ROOT.
CORE_SRC="$ROOT/hooks/lib/session-control-core-v1.js"
SWEEP_SRC="$ROOT/hooks/lib/review-evidence-sweep-v1.js"
OWNER_SRC="$ROOT/hooks/lib/review-evidence-lease-v1.js"
if [ -f "$SWEEP_SRC" ] \
  && ! grep -qF 'rel1_[a-f0-9]{32}' "$CORE_SRC" \
  && ! grep -qF 'rel1_[a-f0-9]{32}' "$SWEEP_SRC" \
  && ! grep -qE '8 \* 1024 \* 1024' "$CORE_SRC" \
  && ! grep -qE '8 \* 1024 \* 1024' "$SWEEP_SRC" \
  && grep -qF "require('./review-evidence-lease-v1.js')" "$SWEEP_SRC"; then
  check "the sweep consumes the lease-store literals from their owner instead of copying them" PASS
else
  check "the sweep consumes the lease-store literals from their owner instead of copying them" FAIL
fi

# The other half of the seam: the owner actually EXPORTS what the sweep consumes.
# Without this a copy could come back as a re-declaration in the sweep and the pin
# above would still pass on the core alone.
if grep -qE '^  LEASE_ID_RE,' "$OWNER_SRC" \
  && grep -qE '^  MAX_RECORD_BYTES,' "$OWNER_SRC" \
  && grep -qE '^  REVIEW_EVIDENCE_SEGMENTS,' "$OWNER_SRC" \
  && grep -qE '^  ensurePrivateDirectory,' "$OWNER_SRC" \
  && grep -qE '^  leaseRecordIsOwned,' "$OWNER_SRC"; then
  check "review-evidence-lease-v1.js exports all five elements the sweep used to copy" PASS
else
  check "review-evidence-lease-v1.js exports all five elements the sweep used to copy" FAIL
fi

# The sweep is no longer part of adoptContext, so an adoption is only complete once
# the ENTRY POINT has also run it. A host that takes the core delta alone gets a
# re-minted record with the superseded leases still wedging every lease operation.
#
# The caller is the REPORT MODULE, not the shell script: the payload that invokes it
# moved out of the `node -e` string in the same change. Both halves are pinned, so
# neither the call nor the script that runs it can quietly disappear.
REPORT_SRC="$ROOT/hooks/lib/session-adopt-report-v1.js"
if ! grep -qF 'discardSupersededLeases' "$CORE_SRC" \
  && grep -qF 'sweepLeases.discardSupersededLeases' "$REPORT_SRC" \
  && grep -qF 'session-adopt-report-v1.js' "$ROOT/hooks/lib/zensu-session-adopt.sh"; then
  check "the adoption entry point owns the sweep call now that the core does not" PASS
else
  check "the adoption entry point owns the sweep call now that the core does not" FAIL
fi

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

# This offline structure test materializes both roots from the COMMITTED revision:
# `ROOT_REVISION` captures `git rev-parse HEAD` above and the install fixture reads
# the tree with `git ls-tree`. (No line number here on purpose — the previous wording
# named one and the next hoist made it stale, which is the same drift this comment is
# warning about.) That split is load-bearing to know: anything reached through a
# $SYNTHETIC_*_ROOT path — every behavioural row, and the copies of
# skills/adopt-session/SKILL.md that AC-C04 and CONV-1 read — grades the LAST COMMIT,
# while a handful of rows read $ROOT, the working tree, directly. Each of those is
# labelled `WORKING TREE, not HEAD` in place; the count is deliberately NOT written
# out here, because a hand-maintained number is exactly what a driven loop cannot
# catch when a row is removed.
#
# An uncommitted change under hooks/ or skills/ therefore reports green against the
# previous commit everywhere except those rows. It cost a full review round here
# once, so it is now an executable check rather than a warning in prose — see the
# row immediately below. This suite proves create-once, root-binding, and fail-closed
# invariants only. The Promptfoo upgrade profile supplies the authoritative
# real-v0.16.1 provenance and long-lived Claude process evidence.
#
# Placed beside the two hoisted pins and for the same reason: it needs no fixture and
# no session lifecycle, and a Windows timeout that kills the tail must not be able to
# take the one row that tells you the rest graded the wrong tree.
if git -C "$ROOT" diff --quiet HEAD -- hooks skills 2>/dev/null; then
  check "the tree under test is committed (behavioural rows grade $ROOT_REVISION)" PASS
else
  check "UNCOMMITTED hooks/ or skills/ changes: behavioural rows grade $ROOT_REVISION, not your edits" FAIL
  git -C "$ROOT" diff --name-only HEAD -- hooks skills 2>/dev/null | head -10
fi
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
#
# WORKING TREE, not HEAD: this greps $ROOT directly, unlike the behavioural rows.
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
  # Read the previous release's artifacts with the WORKING TREE core — one of the
  # six rows that do, against a suite whose behavioural rows all grade HEAD. That is
  # the direction that matters here, and readContext revalidates the digest, the
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
# WORKING TREE, not HEAD: this requires ../../hooks/lib directly, unlike every
# behavioural row above, which reaches the fixture-installed copy of that file.
. "$(dirname "$0")/lib-unit-summary.sh"   # shared, locale-independent summary parse
RECOGNIZER_UNIT="$ROOT/tests/structure/zensu-doctor-invocation.test.js"
if [ -f "$RECOGNIZER_UNIT" ] && node --test "$RECOGNIZER_UNIT" >"$TMP/recognizer-unit.out" 2>&1 \
  && unit_cases_registered_floor "$TMP/recognizer-unit.out" 26; then
  check "the recognizer unit suite passes ($(unit_cases_report "$TMP/recognizer-unit.out"), driven from here — nothing else referenced it)" PASS
else
  check "the recognizer unit suite passes ($(unit_cases_report "$TMP/recognizer-unit.out"), want >= 26 registered — driven from here, nothing else referenced it)" FAIL
  # The FAILING lines, not the first forty. node --test emits every passing case
  # before any failure, so a head-style dump of a 26-case suite showed only
  # successes and the verdict never reached the log — exactly what happened on
  # windows-shard-2, where it cost a CI round to notice the dump was truncated.
  grep -E "^not ok|^# (fail|pass|tests) |Error|expected:|actual:|operator:" \
    "$TMP/recognizer-unit.out" 2>/dev/null | head -40
fi

# WORKING TREE, not HEAD — same split as the recognizer unit row above.
LINEAGE_UNIT="$ROOT/tests/structure/session-control-lineage.test.js"
if [ -f "$LINEAGE_UNIT" ] && node --test "$LINEAGE_UNIT" >"$TMP/lineage-unit.out" 2>&1 \
  && unit_cases_registered_floor "$TMP/lineage-unit.out" 13; then
  check "AC-011 runtimeLineageCompatible unit suite passes ($(unit_cases_report "$TMP/lineage-unit.out"))" PASS
else
  check "AC-011 runtimeLineageCompatible unit suite passes ($(unit_cases_report "$TMP/lineage-unit.out"), want >= 13 registered)" FAIL
  sed -n '1,40p' "$TMP/lineage-unit.out" 2>/dev/null
fi

# WORKING TREE, not HEAD — same split again. The superseded-lease sweep moved out
# of session-control-core-v1.js into its own module (requiring the lease owner from
# the core is a require cycle), which finally gives it a unit driver: its refusal
# arms used to cost a full synthetic install plus a session lifecycle each, and
# three of its return shapes were not reachable from here at all. Driven from this
# file for the same reason the two above are — tests/run-all.sh discovers only
# test-*.sh, so an undriven *.test.js never executes anywhere.
SWEEP_UNIT="$ROOT/tests/structure/review-evidence-sweep-v1.test.js"
if [ -f "$SWEEP_UNIT" ] && node --test "$SWEEP_UNIT" >"$TMP/sweep-unit.out" 2>&1 \
  && unit_cases_registered_floor "$TMP/sweep-unit.out" 32; then
  check "the superseded-lease sweep unit suite passes ($(unit_cases_report "$TMP/sweep-unit.out"), driven from here)" PASS
else
  check "the superseded-lease sweep unit suite passes ($(unit_cases_report "$TMP/sweep-unit.out"), want >= 32 registered — driven from here)" FAIL
  grep -E "^not ok|^# (fail|pass|tests) |Error|expected:|actual:|operator:" \
    "$TMP/sweep-unit.out" 2>/dev/null | head -40
fi

# WORKING TREE, not HEAD — same split. The adoption REPORT moved out of a
# single-quoted `node -e` shell payload into its own module, which is what finally
# gives safe() a driver: it had no test in either direction, so deleting its whole
# guard condition and returning the text unchanged left the suite green.
REPORT_UNIT="$ROOT/tests/structure/session-adopt-report-v1.test.js"
if [ -f "$REPORT_UNIT" ] && node --test "$REPORT_UNIT" >"$TMP/report-unit.out" 2>&1 \
  && unit_cases_registered_floor "$TMP/report-unit.out" 36; then
  check "the adoption report unit suite passes ($(unit_cases_report "$TMP/report-unit.out"), driven from here)" PASS
else
  check "the adoption report unit suite passes ($(unit_cases_report "$TMP/report-unit.out"), want >= 36 registered — driven from here)" FAIL
  grep -E "^not ok|^# (fail|pass|tests) |Error|expected:|actual:|operator:" \
    "$TMP/report-unit.out" 2>/dev/null | head -40
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
# The doctor renderer resolves the user-scoped zensu config AND the reviewer-spawn
# permission check out of HOME, so an unsandboxed run here would read whatever the
# developer running the suite happens to have. Same guard test-doctor.sh applies.
DOCTOR_HOME="$TMP/doctor-home"; mkdir -p "$DOCTOR_HOME"
CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" HOME="$DOCTOR_HOME" \
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
# The shape the SKILL emits, so this enumeration grades what a real invocation
# looks like. It carries no CLAUDE_PROJECT_DIR: the adoption never reads it, and
# passing it would put a value nobody consumes in front of the recognizer's
# rooted-literal check — which refuses an empty value, so a harness that rendered
# the placeholder empty would make the repair unreachable.
ADOPT_CMD="CLAUDE_PLUGIN_DATA=$SHARED_DATA bash $SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh --confirm"
# And the correspondence is PINNED, not asserted in prose. Without this the skill
# could re-add the assignment and every row below would stay green while the real
# invocation was refused — a green enumeration over a command that never runs. The
# skill is the only producer of that shape and no other suite reads it.
ADOPT_SKILL_COMMANDS="$(grep -c 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session-adopt.sh"' \
  "$SYNTHETIC_BREAKING_ROOT/skills/adopt-session/SKILL.md" 2>/dev/null || printf 0)"
if [ "$ADOPT_SKILL_COMMANDS" = 2 ] \
    && ! grep -q 'CLAUDE_PROJECT_DIR.*zensu-session-adopt\.sh' \
      "$SYNTHETIC_BREAKING_ROOT/skills/adopt-session/SKILL.md"; then
  check "AC-C04 the skill emits both adoption forms, neither carrying CLAUDE_PROJECT_DIR" PASS
else
  check "AC-C04 the skill emits both adoption forms, neither carrying CLAUDE_PROJECT_DIR (found $ADOPT_SKILL_COMMANDS)" FAIL
fi
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

# The LEGACY shape, which is the one property that decides whether an in-flight
# session survives the upgrade.
#
# $ADOPT_CMD used to carry CLAUDE_PROJECT_DIR and went through this same
# enumeration. It no longer does, and the rows above therefore grade only the NEW
# shape — so nothing graded the command an older, still-running skill copy emits. It
# is still admitted (ASSIGNMENTS is unchanged and a rooted literal passes), but that
# property was left resting on an allowlist entry whose own comment called it free,
# which is exactly the setup for a future narrowing that turns this green suite into
# a silently broken remedy for anyone mid-upgrade. A model does not reload its skill
# body when the plugin updates underneath it.
ADOPT_LEGACY_CMD="CLAUDE_PLUGIN_DATA=$SHARED_DATA CLAUDE_PROJECT_DIR=$SYNTHETIC_BREAKING_ROOT bash $SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh --confirm"
ADOPT_LEGACY_PAYLOAD="$(bash_payload "$ADOPT_SESSION" "$ADOPT_LEGACY_CMD")"
ADOPT_LEGACY_FAILURES=''
while IFS= read -r hook_name; do
  [ -n "$hook_name" ] || continue
  hook_expected="$ADOPT_EXPECTED"
  if [ "$hook_name" = pre-bash-zensu-gate.sh ]; then
    hook_expected=allow
  fi
  if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" "$hook_name" "$ADOPT_LEGACY_PAYLOAD")" != "$hook_expected" ]; then
    ADOPT_LEGACY_FAILURES="$ADOPT_LEGACY_FAILURES $hook_name"
  fi
done <<EOF
$ADOPT_MATCHER_HOOKS
EOF
if [ -n "$ADOPT_MATCHER_HOOKS" ] && [ -z "$ADOPT_LEGACY_FAILURES" ]; then
  check "AC-C04 the previous release's adoption shape, carrying CLAUDE_PROJECT_DIR, is still admitted" PASS
else
  check "AC-C04 the previous release's adoption shape, carrying CLAUDE_PROJECT_DIR, is still admitted (unexpected:$ADOPT_LEGACY_FAILURES)" FAIL
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

# AC-C04 — the SHAPE the skill actually emits, at the GATE layer. AC-C11 below
# drives the same shapes at the script layer, which cannot see this: the
# recognizer consumes assignments as an optional whitelist PREFIX, so the form
# without CLAUDE_PROJECT_DIR — the one the skill emits now that the script never
# reads it — has to be admitted here or the repair is unreachable no matter what
# the script does. The empty-value row is the reason the assignment was dropped
# rather than kept: `isRootedLiteralPath("")` is false, so a harness that rendered
# the placeholder empty would refuse the whole invocation over a variable nobody
# reads. Both rows are graded through the ".*" capability gate for the same reason
# the discrimination test above is.
# Graded against $ADOPT_EXPECTED, never a hardcoded `allow`: the recognizer refuses
# on win32 BY DESIGN, so a literal would make these rows unpassable on the Windows
# shard — the same defect class the block above was corrected for. The empty-value
# row below asserts `deny` on every platform and therefore discriminates only on
# POSIX, where the platform refusal is not already supplying that verdict.
ADOPT_SHAPE_FAILURES=''
ADOPT_NO_PROJECT="CLAUDE_PLUGIN_DATA=$SHARED_DATA bash $SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh"
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh \
    "$(bash_payload "$ADOPT_SESSION" "$ADOPT_NO_PROJECT")")" != "$ADOPT_EXPECTED" ]; then
  ADOPT_SHAPE_FAILURES="$ADOPT_SHAPE_FAILURES no-project-dir"
fi
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh \
    "$(bash_payload "$ADOPT_SESSION" "$ADOPT_NO_PROJECT --confirm")")" != "$ADOPT_EXPECTED" ]; then
  ADOPT_SHAPE_FAILURES="$ADOPT_SHAPE_FAILURES no-project-dir-confirm"
fi
if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" pre-reviewer-capability-gate.sh \
    "$(bash_payload "$ADOPT_SESSION" "CLAUDE_PLUGIN_DATA=$SHARED_DATA CLAUDE_PROJECT_DIR= bash $SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh")")" != deny ]; then
  ADOPT_SHAPE_FAILURES="$ADOPT_SHAPE_FAILURES empty-project-dir:allowed"
fi
# The label follows the grading, exactly as $ADOPT_LABEL does above: on win32 all
# three rows assert `deny`, and a fixed "is admitted" label would then report the
# opposite of what was verified.
if [ "$ADOPT_EXPECTED" = allow ]; then
  ADOPT_SHAPE_LABEL="the emitted shape without CLAUDE_PROJECT_DIR is admitted; an empty value still is not"
else
  ADOPT_SHAPE_LABEL="refuses every emitted shape on win32 (documented MSYS spelling gap; the empty-value row does not discriminate here)"
fi
if [ -z "$ADOPT_SHAPE_FAILURES" ]; then
  check "AC-C04 $ADOPT_SHAPE_LABEL" PASS
else
  check "AC-C04 $ADOPT_SHAPE_LABEL ($ADOPT_SHAPE_FAILURES)" FAIL
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
  # reason and the principal assertion below would stay green. That argument only
  # holds where the bare form is admitted at all — see the win32 skip below it.
  # Graded against $ADOPT_EXPECTED, never a hardcoded `allow`: the recognizer
  # refuses on win32 by design, so a fixed expectation is unpassable on the
  # Windows shard — the same defect class AC-C04 was corrected for.
  if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" "$shell_gate" \
      "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --confirm")")" != "$ADOPT_EXPECTED" ]; then
    RECOGNIZER_FAILURES="$RECOGNIZER_FAILURES bare-form-control:$shell_gate"
  fi
  # Only meaningful where the recognizer ADMITS the bare form. On win32 it refuses
  # every payload before the principal is ever consulted (zensu_doctor_allowed
  # returns at zensu_doctor_invocation, ahead of zensu_hook_is_main_principal), so
  # the platform refusal alone satisfies this `deny` and the principal conjunct is
  # never exercised — a row reporting verified while testing nothing, which is the
  # exact vacuity the positive control above exists to prevent. Skipped explicitly
  # rather than left silently green.
  if [ "$ADOPT_EXPECTED" = allow ]; then
    if [ "$(gate_decision_from "$SYNTHETIC_BREAKING_ROOT" "$shell_gate" \
        "$(bash_payload "$ADOPT_SESSION" "bash $ADOPT_SCRIPT --confirm" 'zensu:review-aspect')")" != deny ]; then
      RECOGNIZER_FAILURES="$RECOGNIZER_FAILURES shell-principal:$shell_gate"
    fi
  fi
done
# The label follows the grading, exactly as $ADOPT_LABEL and $ADOPT_SHAPE_LABEL do:
# on win32 every row above asserts deny, the shape-narrowness clause is supplied by
# the platform refusal and the main-thread conjunct is skipped outright, so a fixed
# "admitted in exactly one shape, for the main thread only" would report the
# opposite of what ran.
if [ "$ADOPT_EXPECTED" = allow ]; then
  RECOGNIZER_LABEL="the second recognized command is admitted in exactly one shape, for the main thread only"
else
  RECOGNIZER_LABEL="refuses every adoption payload on win32 (documented MSYS spelling gap; neither the shape narrowness nor the main-thread conjunct discriminates here)"
fi
if [ -z "$RECOGNIZER_FAILURES" ]; then
  check "FR-C03 $RECOGNIZER_LABEL" PASS
else
  check "FR-C03 $RECOGNIZER_LABEL (allowed:$RECOGNIZER_FAILURES)" FAIL
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

# Defined HERE rather than beside the lease fixture that motivated it, because
# AC-C11 below is the first consumer. The full account of why reaching a recorded
# path from a shell variable takes BOTH steps — and what each one costs when it is
# skipped on Windows — is the comment block above the lease fixture further down;
# do not re-state it, and do not inline either step at a call site.
native_root() {
  local rendered
  rendered="$(bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-host-path.sh" "$1")" || return 1
  ROOT_IN="$rendered" node -e '
    process.stdout.write(require("node:fs").realpathSync.native(process.env.ROOT_IN));
  ' || return 1
}
# Also hoisted above its original site: AC-C11b below is the first consumer, and it
# has to run BEFORE the adoption, because that is the only window in which `ok` is
# a reachable verdict at all.
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
# Every comparison of a report line or a record field against the shell's own
# $PROJECT goes through this. On POSIX it is identity; on Git Bash the shell holds
# /d/a/... while the record and the report hold D:\a\..., so a raw comparison can
# only ever fail there — silently, since a POSIX run stays green.
# Asserted as the CORRESPONDENCE its label claims, not as mere non-emptiness: the
# helper returns an empty string on either failure step, and an empty needle would
# turn every grep below into a match on the report's fixed label — a row that
# reports PASS while testing nothing. Compared against the record the adoption is
# about to be graded on, which is the only thing that makes the rendering right
# rather than merely present.
NATIVE_PROJECT="$(native_root "$PROJECT")"
if [ -n "$NATIVE_PROJECT" ] \
    && [ "$(node -p 'require(process.argv[1]).project_root' "$ADOPT_RECORD")" = "$NATIVE_PROJECT" ]; then
  check "the project fixture renders to the spelling the record holds" PASS
else
  check "the project fixture renders to the spelling the record holds" FAIL
fi

# AC-C11 — the three CLAUDE_PROJECT_DIR shapes the entry point used to die on,
# driven through the shipped script rather than through adoptableRecord, because
# two of them never reached that function: the script required the variable and
# then rendered it through zensu-host-path.sh, which refuses a path that is not a
# directory. Both exits happened BEFORE any report, so the one command that can
# repair the session printed nothing at all in the state it exists for — and
# neither shape is exotic: the record is minted from the SessionStart payload
# cwd, so a fork whose cwd was a worktree records that worktree while the harness
# still reports somewhere else, and a deleted worktree is the harness value gone.
# The record is still at 0.17.0 here, so ADOPTABLE is the answer in all three. This
# row owns the SCRIPT's environment handling and nothing else — the `ok` verdict at
# the function boundary belongs to AC-C11b below, which drives the parameter the
# entry point no longer passes at all.
# `env -u` rather than an empty assignment: the suite inherits a real
# CLAUDE_PROJECT_DIR from the session running it, and `VAR= cmd` is a SET empty
# value that the `-n` guard would have caught for the wrong reason.
ABSENT_PROJECT="$TMP/adopt-project-that-was-deleted"
rm -rf "$ABSENT_PROJECT"
# Only the CLAUDE_PROJECT_DIR spelling varies, so it is the only thing the caller
# passes; everything else is fixed here. `env "$@"` keeps each spelling a single
# quoted word — a word-split variable would break on any path with a space and a
# leading assignment before a FUNCTION name has shell-dependent persistence.
adopt_report_shape() {
  env "$@" \
    CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" 2>&1
}
# The RETAINED precondition, which got no test when the CLAUDE_PROJECT_DIR one was
# removed. A bare `|| exit 1` here once made this command — the last reachable
# diagnosis in a wedged session — print NOTHING at all for a plugin-data store that
# had been pruned, replaced by a file or symlinked, because zensu-host-path.sh exits
# silently for anything that is not an existing non-symlink directory.
#
# Asserted on the MESSAGE, never on the exit status: the pre-change tree also exited
# non-zero here, so a status-only assertion would not discriminate.
PLUGIN_DATA_IS_A_FILE="$TMP/plugin-data-is-a-file"
printf x > "$PLUGIN_DATA_IS_A_FILE"
CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_IS_A_FILE" \
  bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" \
  >"$TMP/plugin-data-file.out" 2>"$TMP/plugin-data-file.err"
if grep -qF 'CLAUDE_PLUGIN_DATA does not name a readable directory' "$TMP/plugin-data-file.err"; then
  check "a plugin-data store that is a file names its cause instead of exiting silently" PASS
else
  check "a plugin-data store that is a file names its cause instead of exiting silently" FAIL
  sed -n '1,10p' "$TMP/plugin-data-file.err" 2>/dev/null
fi

# The same precondition through a SYMLINK, which is the shape the renderer rejects
# for a different reason than a file does — and the one an operator is most likely to
# have created on purpose.
PLUGIN_DATA_LINK="$TMP/plugin-data-is-a-link"
rm -rf "$PLUGIN_DATA_LINK"
ln -s "$SHARED_DATA" "$PLUGIN_DATA_LINK" 2>/dev/null
# ln -s exiting 0 is not evidence of a symlink: Git Bash satisfies it with a copy or
# a shortcut native Node does not follow. Confirm before asserting on it.
if [ -L "$PLUGIN_DATA_LINK" ]; then
  CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_LINK" \
    bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" \
    >"$TMP/plugin-data-link.out" 2>"$TMP/plugin-data-link.err"
  if grep -qF 'CLAUDE_PLUGIN_DATA does not name a readable directory' "$TMP/plugin-data-link.err"; then
    check "a symlinked plugin-data store names its cause instead of exiting silently" PASS
  else
    check "a symlinked plugin-data store names its cause instead of exiting silently" FAIL
    sed -n '1,10p' "$TMP/plugin-data-link.err" 2>/dev/null
  fi
else
  check "a symlinked plugin-data store names its cause instead of exiting silently" SKIP
fi

# The ENTRY-POINT-ONLY refusal, which CONV-1's ENTRY_ONLY list now REQUIRES to be
# documented while nothing checked the code still emits it. It is raised before
# adoptableRecord runs, when privateRecordsDirectory refuses the store — here a
# records leaf that is group- and world-accessible. Platform-gated: the binder's
# mode and ownership checks are POSIX-only.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    check "the entry point still emits private-record-store-unsafe (win32: mode checks are no-ops)" SKIP
    ;;
  *)
    UNSAFE_STORE="$TMP/unsafe-record-store"
    mkdir -p "$UNSAFE_STORE/session-control/v1/records" 2>/dev/null
    chmod 0777 "$UNSAFE_STORE/session-control/v1/records" 2>/dev/null
    env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" \
      CLAUDE_PLUGIN_DATA="$UNSAFE_STORE" \
      bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" \
      >"$TMP/unsafe-store.out" 2>&1
    if grep -qF 'NOT adoptable (private-record-store-unsafe)' "$TMP/unsafe-store.out"; then
      check "the entry point still emits private-record-store-unsafe" PASS
    else
      check "the entry point still emits private-record-store-unsafe" FAIL
      sed -n '1,10p' "$TMP/unsafe-store.out" 2>/dev/null
    fi
    ;;
esac

PROJECT_SHAPE_FAILURES=''
adopt_report_shape -u CLAUDE_PROJECT_DIR >"$TMP/adopt-projectdir-unset.out" \
  || PROJECT_SHAPE_FAILURES="$PROJECT_SHAPE_FAILURES unset"
adopt_report_shape CLAUDE_PROJECT_DIR="$ABSENT_PROJECT" >"$TMP/adopt-projectdir-absent.out" \
  || PROJECT_SHAPE_FAILURES="$PROJECT_SHAPE_FAILURES absent"
adopt_report_shape CLAUDE_PROJECT_DIR="$SYNTHETIC_BREAKING_ROOT" >"$TMP/adopt-projectdir-different.out" \
  || PROJECT_SHAPE_FAILURES="$PROJECT_SHAPE_FAILURES different"
for shape in unset absent different; do
  shape_out="$TMP/adopt-projectdir-$shape.out"
  # The -n guard is load-bearing, not defensive: an empty NATIVE_PROJECT makes the
  # third needle the report's own fixed label, which every ADOPTABLE report carries.
  [ -n "$NATIVE_PROJECT" ] \
    && grep -qF 'ADOPTABLE' "$shape_out" \
    && grep -qF 'Nothing has been changed' "$shape_out" \
    && grep -qF "project          : $NATIVE_PROJECT" "$shape_out" \
    || PROJECT_SHAPE_FAILURES="$PROJECT_SHAPE_FAILURES $shape"
done
# One token per shape, appended at most once: the exit-status arm above and this
# grep arm both fire for a broken shape, and a duplicate made the dump below print
# the same capture twice.
PROJECT_SHAPE_FAILURES="$(printf '%s' "$PROJECT_SHAPE_FAILURES" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
# The record must still be untouched: without --confirm every shape is read-only.
if [ -z "$PROJECT_SHAPE_FAILURES" ] \
    && [ "$(node -p 'require(process.argv[1]).plugin_version' "$ADOPT_RECORD")" = 0.17.0 ]; then
  check "AC-C11 the entry point reports on an unset, deleted or differing CLAUDE_PROJECT_DIR" PASS
else
  check "AC-C11 the entry point reports on an unset, deleted or differing CLAUDE_PROJECT_DIR (failed:$PROJECT_SHAPE_FAILURES)" FAIL
  # Dump what actually failed. A hardcoded shape here once printed a PASSING run
  # beside a FAIL verdict, which is worse than printing nothing.
  for failed in $PROJECT_SHAPE_FAILURES; do
    printf '  --- %s ---\n' "$failed"
    head -c 300 "$TMP/adopt-projectdir-$failed.out" 2>/dev/null
    printf '\n'
  done
fi

# AC-C11b — the `ok` verdict, at the FUNCTION boundary, under a project root that
# is not the recorded one. AC-C11 above cannot supply this and must not be read as
# if it did: it varies CLAUDE_PROJECT_DIR, and the entry point no longer passes any
# projectRoot into adoptableRecord at all, so those three shapes exercise the
# script's environment handling and nothing about the parameter. This row is the
# only place the parameter itself is driven while `ok` is still reachable — after
# the --confirm below, $SYNTHETIC_BREAKING_ROOT serves the record and every call
# stops at already-served, which would leave a reintroduced comparison placed after
# that condition completely invisible.
REASON_FRESH_FOREIGN="$(adoption_reason "$SHARED_DATA/session-control/v1/records" "$ADOPT_SESSION" "$SHARED_DATA" "$SYNTHETIC_BREAKING_ROOT" "$SYNTHETIC_BREAKING_ROOT")"
REASON_FRESH_OWN="$(adoption_reason "$SHARED_DATA/session-control/v1/records" "$ADOPT_SESSION" "$SHARED_DATA" "$PROJECT" "$SYNTHETIC_BREAKING_ROOT")"
if [ "$REASON_FRESH_FOREIGN" = ok ] && [ "$REASON_FRESH_OWN" = ok ]; then
  check "AC-C11b an adoptable record answers ok whatever project root the caller supplies" PASS
else
  check "AC-C11b an adoptable record answers ok whatever project root the caller supplies (foreign='$REASON_FRESH_FOREIGN' own='$REASON_FRESH_OWN')" FAIL
fi

ADOPT_RECORD_BEFORE="$(cat "$ADOPT_RECORD")"
cp "$ADOPT_RECORD" "$TMP/adopt-record-before.json"

# AC-C08 — seed the lease store so the sweep has something to sweep. Without this
# the whole moving branch never runs: discardSupersededLeases returns 0 through
# its lstat ENOENT branch when the per-session records directory does not exist,
# so a --confirm assertion on an empty store proves nothing about the discard.
# Two leases with exactly one difference: the root they name.
# Canonicalized: the sweep resolves plugin data through canonicalDirectory, so on
# a host where the temp root is a symlink (/var -> /private/var on macOS) a
# seeded path built from the raw value would be a different directory and the
# sweep would read an empty one.
CANONICAL_SHARED_DATA="$(cd -P -- "$SHARED_DATA" && pwd -P)"
ADOPT_LEASE_DIR="$CANONICAL_SHARED_DATA/review-evidence/v1/records/$ADOPT_KEY"
ADOPT_LEASE_ASIDE="$CANONICAL_SHARED_DATA/review-evidence/v1/superseded/$ADOPT_KEY"
mkdir -p "$ADOPT_LEASE_DIR"
# The two SHARED ancestors are forced 0755 rather than left to the ambient umask,
# which makes this row the pin for a split that is otherwise only prose:
# asideIsSafe() checks the SHAPE of every component but the PERMISSIONS of the leaf
# alone. `review-evidence` and `v1` belong to ensurePrivateDirectory, which repairs
# them; this guard may only look, and extending the mode check up the chain turns a
# store an older version created at 0755 into a permanent destination refusal. That
# is not hypothetical — it shipped for one round and `leases set aside : 3` below is
# what caught it.
#
# Under umask 077 the ancestors would land at 0700 and the row would pass with the
# ancestor check restored, so the chmod is what makes the bite umask-independent.
# It is safe for every row after it: AC-C12 refuses through the per-segment shape lstat,
# AC-C12a through the source lstat, AC-C12b through the leaf mode, and the no-lease
# sweep returns on ENOENT before asideIsSafe() runs — none consults the mode of these
# two. Note the asymmetry this chmod does NOT cover: `superseded` IS mode-checked,
# because nothing in the lease module owns or repairs it. Its 0700 comes from
# asideIsSafe()'s own per-segment mkdir during the AC-C07 --confirm below; the chmods
# at AC-C12 and AC-C12b are defensive re-sets so that no row depends on that
# ordering. No check grades that mode directly.
chmod 0755 "$CANONICAL_SHARED_DATA/review-evidence" "$CANONICAL_SHARED_DATA/review-evidence/v1"
# Rendered NATIVE, not with `pwd -P`. discardSupersededLeases compares the lease's
# recorded plugin_root against the value in the adopted RECORD, which Session
# Control stores host-natively — `D:\a\...` on Windows. `pwd -P` in Git Bash
# yields the MSYS spelling `/d/a/...`, so a fixture built from it never matched
# and the keep-lease was swept with the rest: 4 set aside where 3 were expected.
# Production leases are written from the same native value this renders.
# The record stores what canonicalDirectory produces, and reaching that string
# from a shell variable takes BOTH steps, in this order — three CI rounds were
# spent finding that out, one spelling at a time:
#
#   1. zensu-host-path.sh renders the shell's MSYS spelling (/d/a/...) into a
#      host-native one. Skipping it hands node a path it reads as drive-RELATIVE,
#      so realpathSync resolves D:\d\a\..., throws on the missing directory,
#      and the helper returns an EMPTY string — a fixture root that can never
#      match, which looks exactly like a sweep bug.
#   2. fs.realpathSync.native then produces the separator form the record holds
#      (D:\a\...). The renderer alone stops at drive-qualified forward slashes
#      (D:/a/...), which is still not the recorded string.
#
# On POSIX both steps are identity, which is why every one of these failures was
# invisible locally.
#
# `native_root` itself is defined ABOVE, beside AC-C11, which is now its first
# consumer; this block stays here because it is the fixture that paid for it.
CANONICAL_BREAKING_ROOT="$(native_root "$SYNTHETIC_BREAKING_ROOT")"
CANONICAL_CANDIDATE_ROOT="$(native_root "$SYNTHETIC_CANDIDATE_ROOT")"
# An empty root would silently make every fixture unmatchable and grade the sweep
# as broken. Fail loudly on the fixture instead of quietly on the feature.
if [ -z "$CANONICAL_BREAKING_ROOT" ] || [ -z "$CANONICAL_CANDIDATE_ROOT" ]; then
  check "AC-C08 lease fixture roots resolve to the recorded spelling" FAIL
fi
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
# per-session records directory at all, so the sweep returns through its lstat
# ENOENT branch. That path once returned a scalar while every other path returned
# an object, which made the reporter throw AFTER the record swap had already
# succeeded — a completed adoption reported as a failure. Named precisely: the
# readdir catch below it is NOT this case, it is a directory that exists and
# cannot be read, and it reports unsafe. Driven on its own session, because the
# seeded one above can never reach it.
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
# CLAUDE_PROJECT_DIR is deliberately NOT the recorded root here — see AC-C11a
# below, which grades the anchor this same run produced. It changes nothing about
# what AC-C08 itself pins: the sweep and the report are located from the record,
# never from where the command was invoked.
if [ ! -e "$CANONICAL_SHARED_DATA/review-evidence/v1/records/$NOLEASE_KEY" ] \
    && CLAUDE_CODE_SESSION_ID="$NOLEASE_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$SYNTHETIC_BREAKING_ROOT" \
      bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
      >"$NOLEASE_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$NOLEASE_OUT" \
    && grep -qF 'leases set aside : 0' "$NOLEASE_OUT" \
    && grep -qF 'leases stuck     : 0' "$NOLEASE_OUT" \
    && grep -qF 'bound again from the next tool call' "$NOLEASE_OUT" \
    && ! grep -qF 'WARNING' "$NOLEASE_OUT"; then
  check "AC-C08 a session with no lease store adopts cleanly and exits 0" PASS
else
  # Names the second cause on purpose: this run also supplies AC-C11a's foreign
  # project dir, so a reintroduced CLAUDE_PROJECT_DIR precondition in the entry
  # script fails HERE first, under a label that would otherwise send the reader
  # to the lease sweep.
  check "AC-C08 a session with no lease store adopts cleanly and exits 0 (also the foreign-project-dir input AC-C11a grades)" FAIL
  head -c 400 "$NOLEASE_OUT" 2>/dev/null
fi

# The EXISTING-BUT-EMPTY records directory, which no scenario produced. The no-lease
# row above reaches the lstat ENOENT arm instead — its directory does not exist at
# all — and every other row seeds at least one entry.
#
# The second-order effect is what makes this worth a row rather than only a unit
# case: AC-C12 and AC-C12b are armed-fixture-safe ONLY because this early return
# fires before the destination guard. If write_lease ever wrote to the wrong path the
# directory would be empty, this return would fire, no WARNING would print, and both
# rows would go red instead of passing against an unarmed fixture. That positive
# control was itself supplied by untested code.
EMPTY_RECORDS_DIR="$SHARED_DATA/review-evidence/v1/records/$(node -p '
  require(process.argv[1]).sessionKey(process.argv[2])
' "$CANONICAL_BREAKING_ROOT/hooks/lib/session-control-core-v1.js" "$NOLEASE_SESSION" 2>/dev/null)"
EMPTY_ASIDE_DIR="$SHARED_DATA/review-evidence/v1/superseded/$(node -p '
  require(process.argv[1]).sessionKey(process.argv[2])
' "$CANONICAL_BREAKING_ROOT/hooks/lib/session-control-core-v1.js" "$NOLEASE_SESSION" 2>/dev/null)"
if [ -n "${EMPTY_RECORDS_DIR##*/}" ] && mkdir -p "$EMPTY_RECORDS_DIR" 2>/dev/null; then
  rm -rf "$EMPTY_ASIDE_DIR"
  # The record is already adopted by the row above, so this takes the in-place repair
  # branch — which runs the same sweep against the same store.
  env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$NOLEASE_SESSION" \
    CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    bash "$CANONICAL_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
    >"$TMP/empty-records.out" 2>&1
  if grep -qF 'leases set aside : 0' "$TMP/empty-records.out" \
      && ! grep -qF 'WARNING' "$TMP/empty-records.out" \
      && [ ! -e "$EMPTY_ASIDE_DIR" ]; then
    check "an existing-but-empty records directory sweeps nothing and creates no superseded leaf" PASS
  else
    check "an existing-but-empty records directory sweeps nothing and creates no superseded leaf" FAIL
    sed -n '1,12p' "$TMP/empty-records.out" 2>/dev/null
    ls -1d "$EMPTY_ASIDE_DIR" 2>/dev/null
  fi
else
  # FAIL, not SKIP: reaching here means the sessionKey substitution produced nothing
  # or the mkdir failed, and this file states the rule twenty lines earlier — fail
  # loudly on the fixture rather than quietly on the feature.
  check "an existing-but-empty records directory sweeps nothing and creates no superseded leaf (FIXTURE could not be built)" FAIL
fi

# AC-C12 — the DESTINATION refusal, and the only check that reaches either scope
# string. Both existing sweeps are clean paths: the seeded one passes asideIsSafe()
# and the no-lease one returns through the lstat ENOENT branch, so before this row
# nothing in the tree distinguished `source` from `destination`, or either from the
# bare boolean they replaced. The counts cannot stand in for it — they print BEFORE
# the unsafe branch, so a refused sweep still reports `set aside : 0`.
#
# A regular FILE at the destination, not a symlink: CLAUDE.md §Git Mutation Tables
# records that `ln -s` exiting 0 is no evidence of a symlink under Git Bash (W167/
# W168), and the guard's per-segment lstat refuses a file just as usefully. It
# costs one session lifecycle, which is what makes the scope strings observable.
DESTUNSAFE_SESSION='versioned-upgrade-adoption-dest-unsafe'
DESTUNSAFE_START="$(EVENT=SessionStart SESSION="$DESTUNSAFE_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
printf '%s' "$DESTUNSAFE_START" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" >/dev/null 2>&1
DESTUNSAFE_KEY="$(node "$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/session-control-core-v1.js" session-key "$DESTUNSAFE_SESSION")"
DESTUNSAFE_RECORDS="$CANONICAL_SHARED_DATA/review-evidence/v1/records/$DESTUNSAFE_KEY"
DESTUNSAFE_ASIDE="$CANONICAL_SHARED_DATA/review-evidence/v1/superseded/$DESTUNSAFE_KEY"
mkdir -p "$DESTUNSAFE_RECORDS" "$(dirname "$DESTUNSAFE_ASIDE")"
# `superseded` IS mode-checked by asideIsSafe(), unlike its two ancestors, so this
# mkdir must not be what leaves it at the ambient umask. Today the product code
# creates it first at 0700 during the AC-C07 --confirm above and this is a no-op —
# but that makes every later clean sweep depend on row ORDER, and a reorder would
# turn AC-C08's `leases set aside : 3` red for a reason unrelated to the sweep.
chmod 0700 "$(dirname "$DESTUNSAFE_ASIDE")"
DESTUNSAFE_LEASE='rel1_00112233445566778899aabbccddeeff'
write_lease "$DESTUNSAFE_RECORDS/$DESTUNSAFE_LEASE.json" "$DESTUNSAFE_LEASE" "$CANONICAL_CANDIDATE_ROOT"
printf 'not a directory\n' > "$DESTUNSAFE_ASIDE"
DESTUNSAFE_OUT="$TMP/adopt-dest-unsafe.out"
if env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$DESTUNSAFE_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
      >"$DESTUNSAFE_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$DESTUNSAFE_OUT" \
    && grep -qF 'SUPERSEDED directory could not be opened safely' "$DESTUNSAFE_OUT" \
    && ! grep -qF 'lease RECORDS directory of this session could not be' "$DESTUNSAFE_OUT" \
    && grep -qF 'leases set aside : 0' "$DESTUNSAFE_OUT" \
    && grep -qF 'leases stuck     : 0' "$DESTUNSAFE_OUT" \
    && [ -f "$DESTUNSAFE_RECORDS/$DESTUNSAFE_LEASE.json" ]; then
  check "AC-C12 a refused destination is named as the destination, and no lease is moved" PASS
else
  check "AC-C12 a refused destination is named as the destination, and no lease is moved" FAIL
  head -c 400 "$DESTUNSAFE_OUT" 2>/dev/null
fi

# AC-C12a — the SOURCE refusal, which AC-C12 can only assert the absence of. An
# absence passes more easily when the text is wrong, so it cannot stand in for the
# positive case: without this row the `source` scope and one of the two warning arms
# are never executed at all. It reaches ONE of the four statements that can return
# `source` — the symlink-or-non-directory refusal. The other three (a non-canonical
# records path, a non-ENOENT lstat error, a readdir error) are executed by no row in
# this suite; that is a stated gap, not an implied covered set. Same technique, one component up — a
# regular FILE where the per-session records directory belongs makes the lstat
# guard's `!stat.isDirectory()` fire, with no symlink and no ln -s involved.
SRCUNSAFE_SESSION='versioned-upgrade-adoption-src-unsafe'
SRCUNSAFE_START="$(EVENT=SessionStart SESSION="$SRCUNSAFE_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
printf '%s' "$SRCUNSAFE_START" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" >/dev/null 2>&1
SRCUNSAFE_KEY="$(node "$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/session-control-core-v1.js" session-key "$SRCUNSAFE_SESSION")"
mkdir -p "$CANONICAL_SHARED_DATA/review-evidence/v1/records"
printf 'not a directory\n' > "$CANONICAL_SHARED_DATA/review-evidence/v1/records/$SRCUNSAFE_KEY"
SRCUNSAFE_OUT="$TMP/adopt-src-unsafe.out"
if env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$SRCUNSAFE_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
      >"$SRCUNSAFE_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$SRCUNSAFE_OUT" \
    && grep -qF 'lease RECORDS directory of this session could not be' "$SRCUNSAFE_OUT" \
    && ! grep -qF 'SUPERSEDED directory could not be opened safely' "$SRCUNSAFE_OUT" \
    && grep -qF 'leases set aside : 0' "$SRCUNSAFE_OUT" \
    && grep -qF 'leases stuck     : 0' "$SRCUNSAFE_OUT"; then
  check "AC-C12a a refused source is named as the records directory, not the destination" PASS
else
  check "AC-C12a a refused source is named as the records directory, not the destination" FAIL
  head -c 400 "$SRCUNSAFE_OUT" 2>/dev/null
fi

# AC-C12b — the LEAF permission arm, which neither row above reaches: AC-C12 plants
# a FILE at the leaf, and the mkdir there raises EEXIST, which the loop tolerates —
# so the per-segment lstat refuses the non-directory before the leaf mode/uid pair
# or the realpath check ever run. A pre-existing DIRECTORY at 0777 is what reaches
# the leaf mode/uid pair: the mkdir neither chmods nor fails on it, so the guard
# meets a leaf it did not create, which is exactly the case the check exists for.
# The realpath check below that pair is NOT reached on this arm — the mode check
# returns first — only on the win32 arm, where privateEnough short-circuits to true.
# Delete the mode/uid pair and this row is what goes red.
LEAFUNSAFE_SESSION='versioned-upgrade-adoption-leaf-unsafe'
LEAFUNSAFE_START="$(EVENT=SessionStart SESSION="$LEAFUNSAFE_SESSION" CWD="$PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: process.env.EVENT,
    source: "startup",
    session_id: process.env.SESSION,
    cwd: process.env.CWD,
  }));
')"
printf '%s' "$LEAFUNSAFE_START" \
  | CLAUDE_PLUGIN_ROOT="$SYNTHETIC_CANDIDATE_ROOT" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" \
    bash "$SYNTHETIC_CANDIDATE_ROOT/hooks/session-start-session-control.sh" >/dev/null 2>&1
LEAFUNSAFE_KEY="$(node "$SYNTHETIC_CANDIDATE_ROOT/hooks/lib/session-control-core-v1.js" session-key "$LEAFUNSAFE_SESSION")"
LEAFUNSAFE_RECORDS="$CANONICAL_SHARED_DATA/review-evidence/v1/records/$LEAFUNSAFE_KEY"
LEAFUNSAFE_ASIDE="$CANONICAL_SHARED_DATA/review-evidence/v1/superseded/$LEAFUNSAFE_KEY"
mkdir -p "$LEAFUNSAFE_RECORDS" "$LEAFUNSAFE_ASIDE"
# Same rule as AC-C12 above, and this mkdir creates `superseded` as an implicit
# parent: that segment is mode-checked, so leaving it at the ambient umask would let
# this row pass through the SEGMENT refusal while claiming the LEAF one — both emit
# the same text — and would make every later clean sweep order-dependent.
chmod 0700 "$(dirname "$LEAFUNSAFE_ASIDE")"
LEAFUNSAFE_LEASE='rel1_0123456789abcdef0123456789abcdef'
write_lease "$LEAFUNSAFE_RECORDS/$LEAFUNSAFE_LEASE.json" "$LEAFUNSAFE_LEASE" "$CANONICAL_CANDIDATE_ROOT"
chmod 0777 "$LEAFUNSAFE_ASIDE"
# The mode/uid pair is platform-gated in the guard (`process.platform !== 'win32'`),
# so on win32 the only defect this row plants is invisible BY DESIGN and the sweep
# proceeds normally. Asserting a refusal there would be unpassable — the same class
# the four $ADOPT_LABEL / $RECOGNIZER_LABEL branches above exist for — and it would
# also contradict AC-C08, which needs asideIsSafe() to return true on that host.
# So both arms are graded, and the label follows the grading.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    LEAFUNSAFE_EXPECT=swept
    LEAFUNSAFE_LABEL="a world-writable destination leaf is NOT refused on win32 (the mode/uid arm is platform-gated by design)"
    ;;
  *)
    LEAFUNSAFE_EXPECT=refused
    LEAFUNSAFE_LABEL="a world-writable pre-existing destination leaf is refused"
    ;;
esac
LEAFUNSAFE_OUT="$TMP/adopt-leaf-unsafe.out"
if env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$LEAFUNSAFE_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
      >"$LEAFUNSAFE_OUT" 2>&1 \
    && grep -qF 'ADOPTED' "$LEAFUNSAFE_OUT"; then
  if [ "$LEAFUNSAFE_EXPECT" = refused ]; then
    grep -qF 'SUPERSEDED directory could not be opened safely' "$LEAFUNSAFE_OUT" \
      && grep -qF 'leases set aside : 0' "$LEAFUNSAFE_OUT" \
      && [ -f "$LEAFUNSAFE_RECORDS/$LEAFUNSAFE_LEASE.json" ] \
      && LEAFUNSAFE_OK=1 || LEAFUNSAFE_OK=0
  else
    # The positive control on the other arm: the sweep must actually RUN, not merely
    # avoid warning, or a guard that refused for some other reason would read green.
    ! grep -qF 'could not be opened safely' "$LEAFUNSAFE_OUT" \
      && grep -qF 'leases set aside : 1' "$LEAFUNSAFE_OUT" \
      && [ ! -e "$LEAFUNSAFE_RECORDS/$LEAFUNSAFE_LEASE.json" ] \
      && LEAFUNSAFE_OK=1 || LEAFUNSAFE_OK=0
  fi
else
  LEAFUNSAFE_OK=0
fi
if [ "$LEAFUNSAFE_OK" = 1 ]; then
  check "AC-C12b $LEAFUNSAFE_LABEL" PASS
else
  check "AC-C12b $LEAFUNSAFE_LABEL" FAIL
  head -c 400 "$LEAFUNSAFE_OUT" 2>/dev/null
fi

# AC-C11a — the anchor is CARRIED, and this is the end-to-end half of AC-C09. The
# run above passed a project dir that is not the recorded one, so an adoption that
# re-anchored to the caller's value would be visible in both the report line and
# the minted record. Neither may move: adoptContext builds the new record from
# verdict.context.project_root, which is the whole reason dropping the caller-side
# comparison relaxes nothing. Graded off the SAME run rather than a fresh one — a
# second adoption of an adopted record can only answer already-served.
NOLEASE_RECORD="$SHARED_DATA/session-control/v1/records/$NOLEASE_KEY.json"
if grep -qF "project          : $NATIVE_PROJECT" "$NOLEASE_OUT" \
    && [ -f "$NOLEASE_RECORD" ] \
    && [ "$(node -p 'require(process.argv[1]).project_root' "$NOLEASE_RECORD")" = "$NATIVE_PROJECT" ]; then
  check "AC-C11a adoption from a differing project dir still anchors on the record" PASS
else
  check "AC-C11a adoption from a differing project dir still anchors on the record" FAIL
  head -c 400 "$NOLEASE_OUT" 2>/dev/null
fi

# AC-C08 — exactly the stale lease moves, the current one stays, none is deleted,
# and the count is reported rather than absorbed.
# The absence of a WARNING is defence in depth on THIS row: `set aside : 3` already
# excludes a refused sweep, because every unsafe return discards 0. It is the
# no-lease row above where the conjunct is load-bearing — there the count is 0
# either way.
if grep -qF 'leases set aside : 3' "$ADOPT_CONFIRM_OUT" \
    && grep -qF 'leases stuck     : 0' "$ADOPT_CONFIRM_OUT" \
    && ! grep -qF 'WARNING' "$ADOPT_CONFIRM_OUT" \
    && [ ! -e "$ADOPT_LEASE_DIR/$LEASE_STALE_ID.json" ] \
    && [ -f "$ADOPT_LEASE_ASIDE/$LEASE_STALE_ID.json" ] \
    && [ ! -e "$ADOPT_LEASE_DIR/$LEASE_MISMATCH_ID.json" ] \
    && [ -f "$ADOPT_LEASE_ASIDE/$LEASE_MISMATCH_ID.json" ] \
    && [ ! -e "$ADOPT_LEASE_DIR/.partial.tmp" ] \
    && [ -f "$ADOPT_LEASE_ASIDE/.partial.tmp" ] \
    && [ -f "$ADOPT_LEASE_DIR/$LEASE_KEEP_ID.json" ]; then
  check "AC-C08 every entry the mirrored conjuncts reject is set aside; only a valid current lease is kept" PASS
else
  check "AC-C08 every entry the mirrored conjuncts reject is set aside; only a valid current lease is kept" FAIL
  # Name the two strings that had to match. Every failure of this check so far was
  # a path-SPELLING mismatch invisible from a POSIX host, and each round cost a
  # full CI cycle to identify. Printing them turns the next one into a read.
  printf '    fixture keep root : %s\n' "$CANONICAL_BREAKING_ROOT"
  printf '    recorded root     : %s\n' \
    "$(node -p 'require(process.argv[1]).plugin_root' "$ADOPT_RECORD" 2>/dev/null)"
  grep -F 'leases' "$ADOPT_CONFIRM_OUT" 2>/dev/null
  ls -1 "$ADOPT_LEASE_DIR" "$ADOPT_LEASE_ASIDE" 2>/dev/null | head -12
fi

# The IN-PLACE LEASE-STORE REPAIR. adoptContext commits the record and only then
# sweeps, and the two are not transactional together — so a run that died in between
# leaves a committed adoption with the store still wedged, and every later run
# refused as already-served. The documented remedy was unreachable for exactly the
# state it repairs.
#
# Simulated the way it actually happens: the record is already adopted (the run
# above did that), and a superseded lease is present that the sweep has not seen.
REPAIR_LEASE_ID="rel1_$(printf 'e%.0s' $(seq 1 32))"
node -e '
const fs = require("node:fs");
const path = require("node:path");
fs.writeFileSync(path.join(process.argv[1], process.argv[2] + ".json"), JSON.stringify({
  schema: "zensu.review-evidence-lease",
  schema_version: 1,
  lease_id: process.argv[2],
  plugin_root: process.argv[3],
}), { mode: 0o600 });
' "$ADOPT_LEASE_DIR" "$REPAIR_LEASE_ID" '/previous/zensu/installation' 2>/dev/null
if [ -f "$ADOPT_LEASE_DIR/$REPAIR_LEASE_ID.json" ]; then
  env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" \
    CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    bash "$CANONICAL_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
    >"$TMP/adopt-repair.out" 2>&1
  REPAIR_STATUS=$?
  # exit 0, not 1: this is a successful repair, not a refusal.
  if [ "$REPAIR_STATUS" -eq 0 ] \
      && grep -qF 'ALREADY SERVED (lease store repaired)' "$TMP/adopt-repair.out" \
      && grep -qF 'leases set aside : 1' "$TMP/adopt-repair.out" \
      && [ ! -e "$ADOPT_LEASE_DIR/$REPAIR_LEASE_ID.json" ] \
      && [ -f "$ADOPT_LEASE_ASIDE/$REPAIR_LEASE_ID.json" ] \
      && [ -f "$ADOPT_LEASE_DIR/$LEASE_KEEP_ID.json" ]; then
    check "an already-served record re-runs the sweep as an in-place repair under --confirm" PASS
  else
    check "an already-served record re-runs the sweep as an in-place repair under --confirm" FAIL
    printf '    exit: %s\n' "$REPAIR_STATUS"
    sed -n '1,14p' "$TMP/adopt-repair.out" 2>/dev/null
  fi

  # The read-only form must stay read-only, which is what the recognizer's own
  # justification for admitting this write-capable command rests on. Same session,
  # a fresh superseded lease, and NO --confirm: it must refuse and move nothing.
  REPAIR_RO_ID="rel1_$(printf 'f%.0s' $(seq 1 32))"
  node -e '
const fs = require("node:fs");
const path = require("node:path");
fs.writeFileSync(path.join(process.argv[1], process.argv[2] + ".json"), JSON.stringify({
  schema: "zensu.review-evidence-lease",
  schema_version: 1,
  lease_id: process.argv[2],
  plugin_root: process.argv[3],
}), { mode: 0o600 });
' "$ADOPT_LEASE_DIR" "$REPAIR_RO_ID" '/previous/zensu/installation' 2>/dev/null
  env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" \
    CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    bash "$CANONICAL_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" \
    >"$TMP/adopt-repair-readonly.out" 2>&1
  if grep -qF 'NOT adoptable (already-served)' "$TMP/adopt-repair-readonly.out" \
      && [ -f "$ADOPT_LEASE_DIR/$REPAIR_RO_ID.json" ] \
      && [ ! -e "$ADOPT_LEASE_ASIDE/$REPAIR_RO_ID.json" ]; then
    check "the report-only form still refuses already-served and sweeps nothing" PASS
  else
    check "the report-only form still refuses already-served and sweeps nothing" FAIL
    sed -n '1,10p' "$TMP/adopt-repair-readonly.out" 2>/dev/null
  fi
  rm -f "$ADOPT_LEASE_DIR/$REPAIR_RO_ID.json"

  # A NON-EMPTY `failed`. Every adoption row asserts `leases stuck     : 0`, so the
  # catch arm and the warning block it feeds were never observed — and that warning
  # is the only place safe() is applied to a LIST. The partial sweep is also the one
  # state the report has to describe correctly while still claiming the adoption
  # succeeded.
  #
  # Driven through a COLLISION, which is now the shape that produces it: the move is
  # a link/unlink pair, so an entry already sitting in the superseded directory is
  # refused rather than overwritten.
  REPAIR_STUCK_ID="rel1_$(printf 'd%.0s' $(seq 1 32))"
  node -e '
const fs = require("node:fs");
const path = require("node:path");
fs.writeFileSync(path.join(process.argv[1], process.argv[2] + ".json"), JSON.stringify({
  schema: "zensu.review-evidence-lease",
  schema_version: 1,
  lease_id: process.argv[2],
  plugin_root: "/previous/zensu/installation",
}), { mode: 0o600 });
' "$ADOPT_LEASE_DIR" "$REPAIR_STUCK_ID" 2>/dev/null
  mkdir -p "$ADOPT_LEASE_ASIDE" 2>/dev/null
  printf 'ALREADY SET ASIDE\n' > "$ADOPT_LEASE_ASIDE/$REPAIR_STUCK_ID.json"
  env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$ADOPT_SESSION" \
    CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
    bash "$CANONICAL_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
    >"$TMP/adopt-stuck.out" 2>&1
  if grep -qF 'leases stuck     : 1' "$TMP/adopt-stuck.out" \
      && grep -qF 'could NOT be set aside' "$TMP/adopt-stuck.out" \
      && grep -qF "$REPAIR_STUCK_ID" "$TMP/adopt-stuck.out" \
      && [ -f "$ADOPT_LEASE_DIR/$REPAIR_STUCK_ID.json" ] \
      && [ "$(cat "$ADOPT_LEASE_ASIDE/$REPAIR_STUCK_ID.json")" = 'ALREADY SET ASIDE' ]; then
    check "a colliding entry is reported stuck and what was already set aside survives" PASS
  else
    check "a colliding entry is reported stuck and what was already set aside survives" FAIL
    sed -n '1,16p' "$TMP/adopt-stuck.out" 2>/dev/null
  fi
  rm -f "$ADOPT_LEASE_DIR/$REPAIR_STUCK_ID.json" "$ADOPT_LEASE_ASIDE/$REPAIR_STUCK_ID.json"
else
  check "an already-served record re-runs the sweep as an in-place repair under --confirm" FAIL
  check "the report-only form still refuses already-served and sweeps nothing" FAIL
  check "a colliding entry is reported stuck and what was already set aside survives" FAIL
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
# `adoption_reason` is defined ABOVE, beside native_root: AC-C11b is its first
# consumer and it runs before the adoption.
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

# AC-C09 — the caller's project root is NOT one of the conditions, and this is the
# check that says so. It was the inverse once: a supplied directory that was not
# the recorded one refused as `project-root-mismatch`, which made the repair
# unreachable in the state it exists for — the record is minted from the
# SessionStart payload cwd while the adoption is handed CLAUDE_PROJECT_DIR, and a
# session cannot change the latter. Nothing is relaxed by removing it: the anchor
# is carried from the record (pinned end to end at AC-C11a above), and the write
# bound is readContext plus the sibling-root and plugin_data checks, all of which
# the neighbouring rows still exercise.
#
# The record here already declares 0.18.0, so $SYNTHETIC_BREAKING_ROOT is the
# runtime that already serves it and `ok` is not reachable from this row — AC-C11b
# above owns that verdict, at the function boundary, before the adoption. What this
# row adds is the property at the OTHER end of the walk: the project argument must
# change nothing even once an earlier condition answers first. Both halves are
# needed, and neither alone is sufficient: a comparison reintroduced after
# already-served is invisible here, and one reintroduced before it is invisible at
# AC-C11b only if it happens to agree for both arguments — which comparing the two
# reasons is what rules out.
FOREIGN_PROJECT="$TMP/foreign-project"
mkdir -p "$FOREIGN_PROJECT"
REASON_PROJECT="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$FOREIGN_PROJECT" "$SYNTHETIC_BREAKING_ROOT")"
REASON_OWN_PROJECT="$(adoption_reason "$ADOPT_RECORDS_DIR" "$ADOPT_SESSION" "$SHARED_DATA" "$PROJECT" "$SYNTHETIC_BREAKING_ROOT")"
if [ "$REASON_PROJECT" = already-served ] && [ "$REASON_PROJECT" = "$REASON_OWN_PROJECT" ]; then
  check "AC-C09 a caller-supplied project root that differs is not an authority" PASS
else
  check "AC-C09 a caller-supplied project root that differs is not an authority (foreign='$REASON_PROJECT' own='$REASON_OWN_PROJECT')" FAIL
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
# Graded off the call the row above already made with these exact five arguments —
# a second identical node process buys nothing and this suite's Windows ceiling is
# explicitly unmeasured.
REASON_SERVED="$REASON_OWN_PROJECT"
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
#
# The EXPECTATION moved with the workflow-baseline repair, and the move is the
# point rather than a rename. This branch used to close with "That is a normal
# state, not a fault", which adoptableRecord condition 6 makes reachable together
# with a MISSING baseline — so the report read fully successful while the
# capability gate then denied every later tool call for the one reason the report
# had just called normal. The adoption is still NOT a fault and must still be
# announced as ADOPTED; what changed is that the missing document is now named as
# the wedge it is, with the command that clears it.
#
# The needles are matched against a NEWLINE-FLATTENED copy of the report rather
# than against the file, and that is load-bearing rather than tidy: the renderer
# hard-wraps its warning paragraph, so "denies EVERY tool" is split across two
# lines and a line-scoped `grep -F` can NEVER match it. Written line-scoped, this
# check could only ever fail — and it did, silently pinning wording that had
# already moved ("has NO workflow document" became "no usable workflow document"
# when the UNSAFE branch landed). Pinning the SENTENCE keeps the assertion honest
# across a re-wrap; pinning the line breaks pins the typography instead.
INERT_CONFIRM_OUT="$TMP/adopt-inert-confirm.out"
CLAUDE_CODE_SESSION_ID="$INERT_SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$INERT_PROJECT" \
  bash "$SYNTHETIC_BREAKING_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
  >"$INERT_CONFIRM_OUT" 2>&1
INERT_CONFIRM_RC=$?
INERT_CONFIRM_FLAT="$(tr '\n' ' ' <"$INERT_CONFIRM_OUT" 2>/dev/null || printf '')"
if [ "$INERT_CONFIRM_RC" -eq 0 ] \
    && printf '%s' "$INERT_CONFIRM_FLAT" | grep -qF 'ADOPTED' \
    && printf '%s' "$INERT_CONFIRM_FLAT" | grep -qF 'provenance       : no-workflow-document' \
    && printf '%s' "$INERT_CONFIRM_FLAT" | grep -qF 'no usable workflow document' \
    && printf '%s' "$INERT_CONFIRM_FLAT" | grep -qF 'denies EVERY tool in this session' \
    && printf '%s' "$INERT_CONFIRM_FLAT" | grep -qF -- '--confirm to rebuild the document' \
    && ! printf '%s' "$INERT_CONFIRM_FLAT" | grep -qF 'normal state, not a fault'; then
  check "AC-C10 a session with no workflow document adopts, and the missing document is named as a wedge rather than as normal" PASS
else
  check "AC-C10 a session with no workflow document adopts, and the missing document is named as a wedge rather than as normal" FAIL
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
    if (reasons.length !== 7) { process.stdout.write("count:" + reasons.length); process.exit(0); }
    // BOTH directions read the same parsed row set, never the whole file. Prose
    // elsewhere in the skill mentions several of these reasons, so a forward check
    // against `skill.includes` would stay green after the TABLE ROW was deleted —
    // which is the drift it exists to catch. The character class is deliberately
    // wider than any current value: a reason is a kebab-case identifier, and a
    // future one carrying a digit must not slip past unnoticed in either direction.
    const rows = skill.split("\n")
      .map((l) => l.match(/^\|\s*`([a-z0-9_-]+)`\s*\|/))
      .filter(Boolean)
      .map((m) => m[1]);
    // ENTRY-POINT-ONLY refusals. The adoption script emits `private-record-store-unsafe`
    // itself, before adoptableRecord is ever reached, so it is a refusal a user sees
    // and the model has to recognize — but it is not an ADOPTION_REFUSALS value. The
    // stale arm used to reject it, which meant the refusal TABLE had to stay
    // incomplete in order to keep this pin simple: the test dictated what could be
    // documented instead of checking that what exists is documented. Naming the
    // exception explicitly inverts that back.
    const ENTRY_ONLY = ["private-record-store-unsafe"];
    const known = reasons.concat(ENTRY_ONLY);
    const stale = rows.filter((r) => !known.includes(r));
    if (stale.length) { process.stdout.write("stale:" + stale.join(",")); process.exit(0); }
    const missing = known.filter((r) => !rows.includes(r));
    process.stdout.write(missing.length ? missing.join(",") : "ok");
  ' 2>/dev/null
)" || REFUSAL_GAPS=threw
if [ "$REFUSAL_GAPS" = ok ]; then
  check "CONV-1 every ADOPTION_REFUSALS value is documented in the adoption skill" PASS
else
  check "CONV-1 every ADOPTION_REFUSALS value is documented in the adoption skill (missing: $REFUSAL_GAPS)" FAIL
fi

# CONV-2 — the doctor skill must not hand the recognizer an EMPTY assignment.
#
# isRootedLiteralPath("") is false, so a harness that renders the placeholder empty
# makes parseAssignment reject and the ENTIRE invocation is denied — and the command
# it denies is /zensu:doctor, the FIRST of the two exempt commands and the one a
# wedged user is told to run first, in exactly the bind-failure state it exists to
# diagnose. The user gets a gate deny, not the script's own message, because the
# recognizer runs before it. `CLAUDE_PROJECT_DIR= bash <doctor>` is already pinned as
# ASSIGNMENT-refused in zensu-doctor-invocation.test.js; what is pinned HERE is that
# the shipped skill body tells the model to omit the assignment rather than render it
# empty, the way ZDOC_PLAYWRIGHT_TOOLS already is.
#
# Graded on what the skill OFFERS, not on a sentence: at least one shipped doctor
# invocation must carry no CLAUDE_PROJECT_DIR at all, so the model has a form to
# reach for. A prose-only pin would go red on a rewording that changed nothing and
# green on guidance with no command behind it — the first draft of this row did
# exactly the former.
DOCTOR_SKILL="$ROOT/skills/doctor/SKILL.md"
DOCTOR_CMDS_TOTAL="$(grep -c 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$DOCTOR_SKILL" 2>/dev/null || printf 0)"
DOCTOR_CMDS_WITHOUT_PROJECT="$(grep 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-doctor.sh"' "$DOCTOR_SKILL" 2>/dev/null \
  | grep -cv 'CLAUDE_PROJECT_DIR' || printf 0)"
if [ "$DOCTOR_CMDS_TOTAL" -ge 2 ] && [ "$DOCTOR_CMDS_WITHOUT_PROJECT" -ge 1 ] \
  && grep -qiE 'render(ed)? EMPTY' "$DOCTOR_SKILL"; then
  check "CONV-2 the doctor skill ships a form with no CLAUDE_PROJECT_DIR for the empty-render case" PASS
else
  check "CONV-2 the doctor skill ships a form with no CLAUDE_PROJECT_DIR for the empty-render case (total=$DOCTOR_CMDS_TOTAL without=$DOCTOR_CMDS_WITHOUT_PROJECT)" FAIL
fi

# CONV-3 — the recognizer must SAY why it still accepts the assignment at all. It is
# not a harmless leftover: it is what keeps a model still holding the PREVIOUS
# release's skill body from having its command refused, which is not exotic, because
# a mid-session upgrade is the state the whole feature exists for.
RECOGNIZER_SRC="$ROOT/hooks/lib/zensu-doctor-invocation.js"
# ANCHORED to the ASSIGNMENTS entry, not the whole file: a whole-file grep is
# satisfied by any unrelated occurrence anywhere, so it would grade prose that had
# drifted away from the entry it explains.
if sed -n '/NOT a harmless leftover/,+18p' "$RECOGNIZER_SRC" \
  | grep -qE 'previous release|older skill|mid-session upgrade'; then
  check "CONV-3 the recognizer states why the legacy assignment stays admitted" PASS
else
  check "CONV-3 the recognizer states why the legacy assignment stays admitted" FAIL
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

# ---------------------------------------------------------------------------
# Part D — the workflow-baseline repair
#
# A DIFFERENT wedge from the one Part C exits. There the runtime may not SERVE
# the record; here it serves it perfectly well and the workflow document the
# record anchors is gone — a worktree deleted and re-created loses it, because
# .zensu/state/ is gitignored. While it is gone the ".*" capability gate denies
# every tool, which is deliberate and stays: a deleted document must never be
# read as "no chain was ever active".
#
# It is driven against $SYNTHETIC_COMPATIBLE_ROOT rather than the breaking one,
# because "served" is the precondition of the whole repair — AC-008 above already
# proved that root binds this record.
# ---------------------------------------------------------------------------

# The DECISION channel alone is not enough here: the point of the change is WHICH
# reason a deny carries, and a generic "immutable context revalidation failed"
# would satisfy any check that only reads the word `deny`.
# NAMED apart from the gate_reason_from at :1338 on purpose. This used to reuse
# that name, which SHADOWED the earlier definition for every call below this line
# — and the copy silently dropped the two env neutralizations the original's own
# comment calls load-bearing, so a developer with ZENSU_API_URL or ZENSU_MCP_GATE
# exported would have got an empty reason and a failure misdiagnosed as the scope
# being gone. It carries them now, reads the ONE field the hook actually emits
# (`permissionDecisionReason`; `permissionDecision_reason` existed nowhere in
# hooks/ and made the first disjunct dead), and parses the payload once.
baseline_gate_reason_from() {
  local root="$1" hook="$2" payload="$3" out="$TMP/baseline-gate.out"
  printf '%s' "$payload" \
    | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
      CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_API_URL= ZENSU_MCP_GATE= \
      bash "$root/hooks/$hook" >"$out" 2>/dev/null || true
  OUT_FILE="$out" node -e '
    const fs = require("node:fs");
    const raw = fs.readFileSync(process.env.OUT_FILE, "utf8").trim();
    if (raw === "") { process.stdout.write("\n"); process.exit(0); }
    try {
      const parsed = JSON.parse(raw);
      process.stdout.write(`${parsed?.hookSpecificOutput?.permissionDecisionReason || ""}\n`);
    } catch (_error) { process.stdout.write("unparseable\n"); }
  '
}

BASELINE_DOC="$(
  CORE="$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/session-control-core-v1.js" \
  PROJECT_ROOT="$PROJECT" SID="$SESSION" node -e '
    const core = require(process.env.CORE);
    process.stdout.write(
      core.adoptionWorkflowStatePath(process.env.PROJECT_ROOT, process.env.SID),
    );
  '
)"

# Precondition, asserted rather than assumed: the document has to be THERE before
# deleting it can mean anything. SessionStart writes it, but this suite has run a
# long way by now and a check that passes because the file was already absent
# would prove nothing.
if [ -f "$BASELINE_DOC" ]; then
  check "Part D the session's workflow document exists before it is removed" PASS
else
  check "Part D the session's workflow document exists before it is removed" FAIL
fi

# The control: with the document in place this root allows an ordinary Bash call.
# Without it, the deny below could be the lineage state rather than this one.
BASELINE_CONTROL="$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
if [ "$BASELINE_CONTROL" = allow ]; then
  check "Part D control: a served record with its document allows an ordinary command" PASS
else
  check "Part D control: a served record with its document allows an ordinary command (saw $BASELINE_CONTROL)" FAIL
fi

rm -f "$BASELINE_DOC"

# AC-D07 — the deny NAMES the cause and the command. The generic wording is what
# this row exists to keep out: it is accurate and names no way out, in a state
# where this hook denies every tool.
BASELINE_DENY="$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
BASELINE_REASON="$(baseline_gate_reason_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
if [ "$BASELINE_DENY" = deny ] \
    && printf '%s' "$BASELINE_REASON" | grep -qF 'the workflow document it anchors is missing' \
    && printf '%s' "$BASELINE_REASON" | grep -qF '/zensu:adopt-session --confirm' \
    && ! printf '%s' "$BASELINE_REASON" | grep -qF 'immutable context revalidation failed'; then
  check "AC-D07 a missing workflow document denies with a named cause and a reachable remedy" PASS
else
  check "AC-D07 a missing workflow document denies with a named cause and a reachable remedy (decision=$BASELINE_DENY)" FAIL
  printf '%s\n' "$BASELINE_REASON" | head -c 300
fi

# AC-D07b — the DISCRIMINATION half, and the half AC-D07 alone cannot establish.
# A document that is PRESENT but tampered must keep the GENERIC wording: something
# IS at that path, the repair refuses it by design, and recommending a rebuild
# there tells the user to build over the evidence. Without this row, tagging the
# `is unsafe` throw with baselineMissing() leaves the whole tree green while the
# gate names the one remedy that cannot work — which is the contradiction this
# change set exists to remove, reintroduced from the other side.
BASELINE_LINK_SRC="$TMP/baseline-link-src.json"
printf '{}' >"$BASELINE_LINK_SRC"
ln "$BASELINE_LINK_SRC" "$BASELINE_DOC"
BASELINE_TAMPER_REASON="$(baseline_gate_reason_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
BASELINE_TAMPER_DENY="$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
rm -f "$BASELINE_DOC"
# The SPECIFIC cause is required, not only the generic lead. `immutable context
# revalidation failed` is emitted for EVERY untagged throw from
# revalidateWorkflowState, including ones raised before the document is reached —
# so a hard link that failed to be created, or a deny from earlier in the walk,
# would satisfy the generic needle alone and this row would pass without ever
# exercising the tamper branch it is named for.
if [ "$BASELINE_TAMPER_DENY" = deny ] \
    && printf '%s' "$BASELINE_TAMPER_REASON" | grep -qF 'immutable context revalidation failed' \
    && printf '%s' "$BASELINE_TAMPER_REASON" | grep -qF 'activated workflow CAS state is unsafe' \
    && ! printf '%s' "$BASELINE_TAMPER_REASON" | grep -qF 'the workflow document it anchors is missing'; then
  check "AC-D07b a hard-linked document keeps the generic wording and is offered no rebuild" PASS
else
  check "AC-D07b a hard-linked document keeps the generic wording and is offered no rebuild (decision=$BASELINE_TAMPER_DENY)" FAIL
  printf '%s\n' "$BASELINE_TAMPER_REASON" | head -c 300
fi

# AC-D07c/AC-D07d — the absent DIRECTORY, which is the shape this whole feature
# exists for and which AC-D07 does not reach. That row deletes the leaf while
# `.zensu` and `.zensu/state` stay in place, so the component arm of
# revalidateWorkflowState's ENOENT tagging was exercised by nothing — and a
# deleted and re-created worktree loses the whole DIRECTORY, because
# `.zensu/state/` is gitignored. The doctor row needed its own fixture (P6e in
# test-doctor.sh) for exactly this reason; the GATE that actually denies had none.
# Untagging either component arm leaves the flagship session denied with the
# generic wording that names no way out, and every other row here green.
#
# The two arms are checked separately because the loop runs twice with different
# labels; the deny TEXT is identical for both, so what discriminates is that the
# component ENOENT is tagged at all.
BASELINE_STATE_DIR="$(dirname -- "$BASELINE_DOC")"
BASELINE_ZENSU_DIR="$(dirname -- "$BASELINE_STATE_DIR")"
BASELINE_ZENSU_BAK="$TMP/baseline-zensu-bak"

rm -rf "$BASELINE_STATE_DIR"
BASELINE_NOSTATE_DENY="$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
BASELINE_NOSTATE_REASON="$(baseline_gate_reason_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
if [ "$BASELINE_NOSTATE_DENY" = deny ] \
    && printf '%s' "$BASELINE_NOSTATE_REASON" | grep -qF 'the workflow document it anchors is missing' \
    && printf '%s' "$BASELINE_NOSTATE_REASON" | grep -qF '/zensu:adopt-session --confirm' \
    && ! printf '%s' "$BASELINE_NOSTATE_REASON" | grep -qF 'immutable context revalidation failed'; then
  check "AC-D07c an absent .zensu/state denies with the named cause, not the generic wording" PASS
else
  check "AC-D07c an absent .zensu/state denies with the named cause (decision=$BASELINE_NOSTATE_DENY)" FAIL
  printf '%s\n' "$BASELINE_NOSTATE_REASON" | head -c 300
fi

# The component ABOVE it. Moved aside rather than deleted, so nothing else the
# fixture keeps under `.zensu` is destroyed by a check about its absence.
mv "$BASELINE_ZENSU_DIR" "$BASELINE_ZENSU_BAK"
BASELINE_NOZENSU_DENY="$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
BASELINE_NOZENSU_REASON="$(baseline_gate_reason_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
mv "$BASELINE_ZENSU_BAK" "$BASELINE_ZENSU_DIR"
mkdir -p "$BASELINE_STATE_DIR"
if [ "$BASELINE_NOZENSU_DENY" = deny ] \
    && printf '%s' "$BASELINE_NOZENSU_REASON" | grep -qF 'the workflow document it anchors is missing' \
    && printf '%s' "$BASELINE_NOZENSU_REASON" | grep -qF '/zensu:adopt-session --confirm' \
    && ! printf '%s' "$BASELINE_NOZENSU_REASON" | grep -qF 'immutable context revalidation failed'; then
  check "AC-D07d an absent .zensu denies with the named cause, not the generic wording" PASS
else
  check "AC-D07d an absent .zensu denies with the named cause (decision=$BASELINE_NOZENSU_DENY)" FAIL
  printf '%s\n' "$BASELINE_NOZENSU_REASON" | head -c 300
fi

# AC-D09 — the doctor row is ARMED and never silent, which is the property that
# matters most in a diagnostic and the only one this fixture can establish.
#
# BOTH arms are accepted, and that is a correction rather than a weakening. This
# row used to require the DISCLOSURE arm alone, on the stated premise that "the
# wrapper's own bind does not resolve in this suite's synthetic installs". That
# premise was taken from a macOS observation and is FALSE on Linux and on Windows,
# where the bind DOES resolve: the row then correctly renders the ❌ MISSING
# finding for a document this block has just deleted, and a check demanding the
# other wording failed for a reason that had nothing to do with the renderer.
# Measured, not argued — ubuntu-latest and windows-shard-2 both reported the
# MISSING row here while macOS reported the disclosure.
#
# Silence is the one verdict this row refuses, so silence is what it tests for.
# Each arm is ONE ordered pattern rather than two independent greps: `missing
# check, not an all-clear` occurs at six other sites in zensu-doctor-report.js and
# `own workflow document` occurs on the BAD row too, so separate -qF calls could be
# satisfied by two unrelated lines while the disclosure itself was gone.
#
# The ❌ arm is ALSO driven where the renderer is driven directly, with the
# ZDOC_BINDING/ZDOC_SESSION_KEY pair: tests/structure/test-doctor.sh P6a, which is
# where its wording, its glyph and its remedy are pinned. This row pins neither
# arm's text beyond what distinguishes it from silence.
BASELINE_DOCTOR_OUT="$TMP/baseline-doctor.out"
BASELINE_DOCTOR_HOME="$TMP/baseline-doctor-home"; mkdir -p "$BASELINE_DOCTOR_HOME"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" HOME="$BASELINE_DOCTOR_HOME" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-doctor.sh" \
  >"$BASELINE_DOCTOR_OUT" 2>/dev/null || true
if grep -q "own workflow document was not checked.*missing check, not an all-clear" \
    "$BASELINE_DOCTOR_OUT" \
  || grep -q "own workflow document is MISSING.*/zensu:adopt-session --confirm" \
    "$BASELINE_DOCTOR_OUT"; then
  check "AC-D09 the doctor's own-document check is armed and never silent" PASS
else
  check "AC-D09 the doctor's own-document check is armed and never silent" FAIL
  grep -F 'state:' "$BASELINE_DOCTOR_OUT" 2>/dev/null | head -3
fi

# AC-D05 — the report-only run diagnoses it and WRITES NOTHING. Proven by the
# file still being absent, never by the output alone: "it is read-only" is the
# premise the PreToolUse recognizer's admission of this command rests on.
BASELINE_REPORT_OUT="$TMP/baseline-report.out"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-session-adopt.sh" \
  >"$BASELINE_REPORT_OUT" 2>/dev/null || true
# `grep -qF --` is REQUIRED for the flag needle: without the `--` terminator grep
# parses `--confirm` as its own option. It fails loudly here rather than passing
# vacuously, but it is the same class of defect CLAUDE.md records for S7k.
if grep -qF 'workflow document is MISSING' "$BASELINE_REPORT_OUT" \
    && grep -qF -- '--confirm' "$BASELINE_REPORT_OUT" \
    && grep -qF 'loss, not a restore' "$BASELINE_REPORT_OUT" \
    && [ ! -f "$BASELINE_DOC" ]; then
  check "AC-D05 the report-only run names the missing document and writes nothing" PASS
else
  check "AC-D05 the report-only run names the missing document and writes nothing" FAIL
  head -c 300 "$BASELINE_REPORT_OUT" 2>/dev/null
fi

# AC-D06 / AC-D11 — --confirm rebuilds it, and the session can run tools again.
BASELINE_CONFIRM_OUT="$TMP/baseline-confirm.out"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
  >"$BASELINE_CONFIRM_OUT" 2>/dev/null
BASELINE_CONFIRM_RC=$?
if [ "$BASELINE_CONFIRM_RC" -eq 0 ] \
    && grep -qF 'workflow baseline rebuilt' "$BASELINE_CONFIRM_OUT" \
    && [ -f "$BASELINE_DOC" ]; then
  check "AC-D06 --confirm rebuilds the missing workflow document and exits 0" PASS
else
  check "AC-D06 --confirm rebuilds the missing workflow document and exits 0 (rc=$BASELINE_CONFIRM_RC)" FAIL
  head -c 300 "$BASELINE_CONFIRM_OUT" 2>/dev/null
fi

# AC-D03 end to end — exactly one provenance entry, and NO bypass-ledger entry.
# The ledger records gate ESCAPES so that everything under "Gates bypassed" is
# true; this escaped no gate, because the document a gate would have read was
# already gone.
if BASELINE_DOC="$BASELINE_DOC" node -e '
    const fs = require("node:fs");
    const state = JSON.parse(fs.readFileSync(process.env.BASELINE_DOC, "utf8"));
    const rebuilt = (state.history || []).filter((h) => h.phase === "BASELINE_REBUILT");
    if (rebuilt.length !== 1) process.exit(1);
    if (!rebuilt[0].ts) process.exit(1);
    if (!String(rebuilt[0].reason || "").startsWith("baseline-rebuilt: ")) process.exit(1);
    if (!Array.isArray(state.bypasses) || state.bypasses.length !== 0) process.exit(1);
  '; then
  check "AC-D03 the rebuilt document carries one BASELINE_REBUILT entry and an empty ledger" PASS
else
  check "AC-D03 the rebuilt document carries one BASELINE_REBUILT entry and an empty ledger" FAIL
fi

BASELINE_AFTER="$(gate_decision_from "$SYNTHETIC_COMPATIBLE_ROOT" \
  pre-reviewer-capability-gate.sh "$COMPATIBLE_BASH")"
if [ "$BASELINE_AFTER" = allow ]; then
  check "AC-D11 the session runs ordinary commands again after the repair" PASS
else
  check "AC-D11 the session runs ordinary commands again after the repair (saw $BASELINE_AFTER)" FAIL
fi

# AC-D06 second half — a second --confirm is a no-op on the baseline rather than
# a second rebuild, and must not report one.
BASELINE_SECOND_OUT="$TMP/baseline-second.out"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
  >"$BASELINE_SECOND_OUT" 2>/dev/null
BASELINE_SECOND_RC=$?
if [ "$BASELINE_SECOND_RC" -eq 0 ] \
    && ! grep -qF 'workflow baseline rebuilt' "$BASELINE_SECOND_OUT" \
    && grep -qF 'workflow baseline: present' "$BASELINE_SECOND_OUT"; then
  check "AC-D06 a second --confirm reports the document as present, not rebuilt again" PASS
else
  check "AC-D06 a second --confirm reports the document as present, not rebuilt again (rc=$BASELINE_SECOND_RC)" FAIL
  head -c 300 "$BASELINE_SECOND_OUT" 2>/dev/null
fi

# AC-D04 — the provenance phase and its reason prefix cannot be minted by a
# caller, the same protection CHAIN_RECOVERED and RUNTIME_ADOPTED carry, for the
# same reason: a forgeable provenance entry is worse than none, because it is
# believed. CLAUDE_CODE_SESSION_ID is REQUIRED — zensu-log.sh binds the model
# session before it reaches the --phase case, so without it the helper exits 2 on
# the binding and the guard never runs, green in a tree with the guard deleted.
BASELINE_FORGE_ERR="$TMP/baseline-forge-phase.err"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_ROOT="$SYNTHETIC_COMPATIBLE_ROOT" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-log.sh" --phase BASELINE_REBUILT --step forged \
  >/dev/null 2>"$BASELINE_FORGE_ERR"
BASELINE_FORGE_PHASE_RC=$?
BASELINE_FORGE_REASON_ERR="$TMP/baseline-forge-reason.err"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_ROOT="$SYNTHETIC_COMPATIBLE_ROOT" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-log.sh" --phase IMPL --step forged \
  --reason "baseline-rebuilt: missing" >/dev/null 2>"$BASELINE_FORGE_REASON_ERR"
BASELINE_FORGE_REASON_RC=$?
if [ "$BASELINE_FORGE_PHASE_RC" -ne 0 ] \
    && grep -qF 'BASELINE_REBUILT is written only by the workflow-baseline repair' "$BASELINE_FORGE_ERR" \
    && [ "$BASELINE_FORGE_REASON_RC" -ne 0 ] \
    && grep -qF "a 'baseline-rebuilt: ' reason is reserved for the workflow-baseline repair" "$BASELINE_FORGE_REASON_ERR"; then
  check "AC-D04 the BASELINE_REBUILT phase and reason cannot be minted through --phase" PASS
else
  check "AC-D04 the BASELINE_REBUILT phase and reason cannot be minted through --phase (phase_rc=$BASELINE_FORGE_PHASE_RC reason_rc=$BASELINE_FORGE_REASON_RC)" FAIL
  head -c 200 "$BASELINE_FORGE_ERR" 2>/dev/null; head -c 200 "$BASELINE_FORGE_REASON_ERR" 2>/dev/null
fi

# AC-D04b — the OTHER TWO guard sites, and the reason this row exists at all.
# AC-D04 above goes through zensu-log.sh, which refuses at its own --phase guards
# and exits 2 BEFORE tdd_write_phase is ever reached — so the guards inside
# zensu-tdd-phase.sh (tdd_write_phase and _tdd_write_phase_critical) were driven
# by NOTHING and all four lines could be deleted with the whole tree green, while
# any caller that sources the phase library could then forge a BASELINE_REBUILT
# provenance entry. T12h2 in test-chain-recover.sh is the sibling precedent.
#
# THE BIND IS THE WHOLE POINT, and a first version of this row got it wrong in a
# way worth recording. It sourced zensu-session.sh and called only
# zensu_resolve_session_id, which is a pure hash and exports nothing. Without
# ZENSU_SESSION_KEY / ZENSU_PROJECT_ROOT / ZENSU_SESSION_CONTEXT, tdd_state_file
# and _tdd_bound_project_root both fail — so with the guards DELETED the four
# calls still returned non-zero, for a reason unrelated to the guards, and the
# row passed while observing nothing at all. zensu_bind_model_session is what
# supplies them; the session is already registered by the Part D fixture.
#
# TWO controls, because one axis is not enough. A POSITIVE call must SUCCEED
# through the same entry point, which proves the fixture can write at all; and
# the FULL history must grow by exactly that one entry with no forged entry in
# it. Counting only BASELINE_REBUILT phases was blind to the two REASON-guard
# calls, which pass phase IMPL: a forged write through a deleted reason guard
# would land an IMPL entry that filter never counted.
BASELINE_HIST_BEFORE="$(
  DOC="$BASELINE_DOC" node -e '
    const fs = require("node:fs");
    try {
      const d = JSON.parse(fs.readFileSync(process.env.DOC, "utf8"));
      process.stdout.write(String(Array.isArray(d.history) ? d.history.length : -1));
    } catch (_e) { process.stdout.write("-1"); }
  ' 2>/dev/null
)"
BASELINE_DIRECT_OUT="$(
  CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_ROOT="$SYNTHETIC_COMPATIBLE_ROOT" \
  bash -c '
    . "$1/hooks/lib/zensu-session.sh" || { echo "source-failed"; exit 0; }
    zensu_bind_model_session >/dev/null 2>&1 || { echo "bind-failed"; exit 0; }
    . "$1/hooks/lib/zensu-tdd-phase.sh" || { echo "phase-source-failed"; exit 0; }
    sid="$ZENSU_SESSION_KEY"
    sf="$3"
    rc_pub_phase=0;  tdd_write_phase "$sid" forged BASELINE_REBUILT >/dev/null 2>&1 || rc_pub_phase=$?
    rc_pub_reason=0; tdd_write_phase "$sid" forged IMPL "baseline-rebuilt: forged" >/dev/null 2>&1 || rc_pub_reason=$?
    rc_crit_phase=0
    # SIX arguments, not five. The function reads the sixth (a timestamp) AFTER its
    # six guard returns, and the library runs under set -u — so a five-argument
    # call on a tree with the guard DELETED aborts the subshell at the unbound
    # expansion before any write is attempted. The mutation probe showed exactly
    # that: the rcs line came back EMPTY and only the public writer forged an
    # entry. With the sixth argument a removed guard really reaches
    # mutateWorkflowState, which is what the history assertion below can see.
    _tdd_write_phase_critical "$sf" "$sid" forged BASELINE_REBUILT "" "" >/dev/null 2>&1 || rc_crit_phase=$?
    rc_crit_reason=0
    _tdd_write_phase_critical "$sf" "$sid" forged IMPL "baseline-rebuilt: forged" "" >/dev/null 2>&1 || rc_crit_reason=$?
    rc_control=0
    tdd_write_phase "$sid" control IMPL "ordinary reason" >/dev/null 2>&1 || rc_control=$?
    echo "$rc_pub_phase:$rc_pub_reason:$rc_crit_phase:$rc_crit_reason:$rc_control"
  ' _ "$SYNTHETIC_COMPATIBLE_ROOT" "$SESSION" "$BASELINE_DOC" 2>"$TMP/baseline-direct.err"
)"
BASELINE_HIST_AFTER="$(
  DOC="$BASELINE_DOC" node -e '
    const fs = require("node:fs");
    try {
      const d = JSON.parse(fs.readFileSync(process.env.DOC, "utf8"));
      const h = Array.isArray(d.history) ? d.history : [];
      const forged = h.filter((e) => e && (e.phase === "BASELINE_REBUILT"
        || (typeof e.reason === "string" && e.reason.indexOf("baseline-rebuilt: ") === 0))).length;
      process.stdout.write(h.length + ":" + forged);
    } catch (_e) { process.stdout.write("-1:-1"); }
  ' 2>/dev/null
)"
# A delimited read rather than `set --`: clobbering the script's positional
# parameters at file scope would reach any row appended below, and Part D is the
# file's tail, which is exactly where new rows land.
BD_RC1=""; BD_RC2=""; BD_RC3=""; BD_RC4=""; BD_RC5=""
IFS=':' read -r BD_RC1 BD_RC2 BD_RC3 BD_RC4 BD_RC5 <<<"$BASELINE_DIRECT_OUT"
BASELINE_DIRECT_OK=false
if [ -n "$BD_RC5" ] \
    && [ "$BD_RC1" -ne 0 ] 2>/dev/null && [ "$BD_RC2" -ne 0 ] \
    && [ "$BD_RC3" -ne 0 ] && [ "$BD_RC4" -ne 0 ] && [ "$BD_RC5" -eq 0 ] \
    && [ "$BASELINE_HIST_AFTER" = "$((BASELINE_HIST_BEFORE + 1)):1" ]; then
  BASELINE_DIRECT_OK=true
fi
if [ "$BASELINE_DIRECT_OK" = true ]; then
  check "AC-D04b both exported writers refuse the reserved phase AND the reserved reason, an ordinary phase still writes, and no forged provenance entry landed" PASS
else
  check "AC-D04b both exported writers refuse the reserved phase and reason (rcs=$BASELINE_DIRECT_OUT history=$BASELINE_HIST_BEFORE->$BASELINE_HIST_AFTER)" FAIL
  head -c 400 "$TMP/baseline-direct.err" 2>/dev/null
fi

# AC-D02 end to end — a document that is PRESENT but unreadable is never rebuilt
# over. This is the discrimination test for the whole feature: without it, "the
# repair rebuilds a missing document" and "the repair rebuilds anything it cannot
# read" pass exactly the same checks.
cp "$BASELINE_DOC" "$TMP/baseline-doc.bak"
printf '%s' '{not json' > "$BASELINE_DOC"
BASELINE_TAMPER_OUT="$TMP/baseline-tamper.out"
CLAUDE_CODE_SESSION_ID="$SESSION" CLAUDE_PLUGIN_DATA="$SHARED_DATA" \
  bash "$SYNTHETIC_COMPATIBLE_ROOT/hooks/lib/zensu-session-adopt.sh" --confirm \
  >"$BASELINE_TAMPER_OUT" 2>/dev/null
BASELINE_TAMPER_RC=$?
if [ "$BASELINE_TAMPER_RC" -ne 0 ] \
    && grep -qF 'workflow baseline NOT repaired' "$BASELINE_TAMPER_OUT" \
    && [ "$(cat "$BASELINE_DOC")" = '{not json' ]; then
  check "AC-D02 an unreadable document is refused and its bytes are left alone" PASS
else
  check "AC-D02 an unreadable document is refused and its bytes are left alone (rc=$BASELINE_TAMPER_RC)" FAIL
  head -c 300 "$BASELINE_TAMPER_OUT" 2>/dev/null
fi
cp "$TMP/baseline-doc.bak" "$BASELINE_DOC"

printf '%s\n' '----' \
  "test-versioned-plugin-upgrade: $PASS PASS / $FAIL FAIL / $SKIPPED SKIP"
[ "$FAIL" -eq 0 ]
