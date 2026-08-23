#!/bin/bash
# The CLI surface of workspace scoping and the audited release.
#
# The state-machine suite drives the shell FUNCTIONS. Everything here drives the
# `zensu-log.sh` verbs a model actually types, because that is where the
# `--confirm` interlock, the argument parsing, the session resolution and the
# derived `release-` event id live — none of which a function-level call reaches.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
SKILL="$PLUGIN_DIR/skills/autopilot-release/SKILL.md"

PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

for required in "$LIB" "$LOG" "$CORE" "$BASELINE" "$PLUGIN_JSON" "$SKILL"; do
  if [ ! -r "$required" ]; then
    check "A0 required artifact missing: $required" FAIL
    printf '%s\n' "----" "test-autopilot-release-cli: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$LIB"

TMP="$(mktemp -d -t zensu-release-cli-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
# An inherited repository environment would let `rev-parse -C` answer for a tree
# the fixtures never named, and a TMPDIR inside a work tree would collapse the
# sibling trees onto one workspace. Both are premises the fixtures rest on.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES GIT_OBJECT_DIRECTORY
if git -C "$TMP" rev-parse --show-toplevel >/dev/null 2>&1; then
  check "A0 the fixture root must not sit inside a git work tree" FAIL
  printf '%s\n' "----" "test-autopilot-release-cli: $PASS PASS / $FAIL FAIL"
  exit 1
fi
mkdir -p "$TMP/plugin-data"
ZENSU_TEST_PLUGIN_DATA="$(cd "$TMP/plugin-data" && pwd -P)"
export ZENSU_TEST_PLUGIN_DATA

activate_session() {
  local project="$1" raw_session="$2"
  mkdir -p "$project" || return 1
  export CLAUDE_PROJECT_DIR="$project"
  # shellcheck disable=SC1090
  source "$BASELINE" "$raw_session" || return 1
}

session_key() { node "$CORE" session-key "$1"; }

run_verb() {
  # Every verb runs exactly as the skills render it: through the helper, with
  # the plugin-data assignment, from an activated session.
  local project="$1" raw_session="$2"; shift 2
  activate_session "$project" "$raw_session" || return 90
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$TMP/missing-config.json" \
      bash "$LOG" "$@" )
}

# Same contract as run_verb, but the verb runs from a directory INSIDE the
# project instead of from its root — the only way to drive the resolver's own
# cwd branch through the CLI.
run_verb_in() {
  local project="$1" raw_session="$2" cwd="$3"; shift 3
  activate_session "$project" "$raw_session" || return 90
  ( cd "$cwd" && CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$TMP/missing-config.json" \
      bash "$LOG" "$@" )
}

json_ok() {
  FILE="$1" EXPR="$2" node -e '
    const value = JSON.parse(require("fs").readFileSync(process.env.FILE, "utf8"));
    process.exit(Function("value", `return Boolean(${process.env.EXPR})`)(value) ? 0 : 1);
  ' 2>/dev/null
}

# There are THREE spellings of one directory on Windows and each expectation
# has to pick the right one. Measured on windows-shard-3: MSYS `pwd -P` answers
# /c/Users/..., this renderer answers C:/Users/..., and node's
# `fs.realpathSync.native` answers C:\Users\... . Which one is correct depends
# on WHICH LAYER produced the value being compared: the shell resolver
# (`autopilot_workspace_root`) ends in this renderer, while a value that reached
# the run record was canonicalized inside node and is therefore backslashed.
# Collapsing the two onto one helper broke A6 on Windows while every POSIX host
# stayed green.
native_dir() {
  bash "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$1" 2>/dev/null </dev/null \
    || (cd -P -- "$1" 2>/dev/null && pwd -P)
}

digest() {
  node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}

# --- Fixture: an owner holds a run; a second session is the releaser ----------
PROJECT="$TMP/project"; mkdir -p "$PROJECT"
PROJECT="$(cd "$PROJECT" && pwd -P)"
activate_session "$PROJECT" release_cli_owner || exit 1
OWNER_KEY="$ZENSU_SESSION_KEY"
autopilot_begin_run release_cli_run "$OWNER_KEY" "$PROJECT" >/dev/null 2>&1 \
  || { check "A1 fixture run could not be started" FAIL; exit 1; }
RUN_FILE="$(autopilot_run_file release_cli_run "$PROJECT")"

# --- A1 --confirm is required, and its absence changes nothing ---------------
BEFORE_A1="$(digest "$RUN_FILE")"
run_verb "$PROJECT" release_cli_releaser --autopilot-release --run release_cli_run >/dev/null 2>&1
A1_RC=$?
if [ "$A1_RC" -eq 2 ] \
  && [ "$(digest "$RUN_FILE")" = "$BEFORE_A1" ] \
  && json_ok "$RUN_FILE" 'value.stage !== "CANCELLED"'; then
  check "A1 the release refuses without --confirm and mutates nothing" PASS
else
  check "A1 release without --confirm (rc=$A1_RC)" FAIL
fi

# --- A2 the argument parser rejects every malformed spelling -----------------
A2_OK=true
run_verb "$PROJECT" release_cli_releaser --autopilot-release --confirm >/dev/null 2>&1
[ "$?" -eq 2 ] || A2_OK=false
run_verb "$PROJECT" release_cli_releaser --autopilot-release --run release_cli_run --confirm --confirm >/dev/null 2>&1
[ "$?" -eq 2 ] || A2_OK=false
run_verb "$PROJECT" release_cli_releaser --autopilot-release --run release_cli_run --run other --confirm >/dev/null 2>&1
[ "$?" -eq 2 ] || A2_OK=false
run_verb "$PROJECT" release_cli_releaser --autopilot-release --run release_cli_run --confirm --bogus >/dev/null 2>&1
[ "$?" -eq 2 ] || A2_OK=false
[ "$(digest "$RUN_FILE")" = "$BEFORE_A1" ] || A2_OK=false
if [ "$A2_OK" = true ]; then
  check "A2 missing --run, duplicate flags and unknown arguments all exit 2 without mutation" PASS
else
  check "A2 release argument parsing" FAIL
fi

# --- A3 the confirmed release cancels and mints the derived event id ---------
# The release refuses a live owner, so a fixture that means "the owning session
# is gone" has to say so. `activate_session` minted the owner's workflow document
# seconds ago; backdate it past any staleness bound instead of releasing a run
# whose owner is, as far as the code can tell, still working.
find "$PROJECT/.zensu/state" -name 'tdd-phase-*.json' -exec touch -t 200001010000 {} + 2>/dev/null
run_verb "$PROJECT" release_cli_releaser --autopilot-release --run release_cli_run --confirm >/dev/null 2>&1
A3_RC=$?
if [ "$A3_RC" -eq 0 ] \
  && json_ok "$RUN_FILE" 'value.stage === "CANCELLED"' \
  && json_ok "$RUN_FILE" '/^release-[a-f0-9]{64}$/.test(value.events[value.events.length - 1].eventId)' \
  && json_ok "$RUN_FILE" 'value.events[value.events.length - 1].eventType === "CANCEL"' \
  && json_ok "$RUN_FILE" 'Object.keys(value.events[value.events.length - 1].payload).length === 0'; then
  check "A3 the confirmed release cancels the foreign run under a derived release- event id" PASS
else
  check "A3 confirmed release (rc=$A3_RC)" FAIL
fi

# --- A4 a repeat is a byte-stable no-op, from any caller ---------------------
AFTER_A3="$(digest "$RUN_FILE")"
A4_OK=true
# A3's cancellation is A4's precondition; assert it so an A3 failure does not
# surface here as a second, unexplained one.
A4_RELEASED=false
json_ok "$RUN_FILE" 'value.stage === "CANCELLED"' && A4_RELEASED=true
[ "$A4_RELEASED" = true ] || A4_OK=false
run_verb "$PROJECT" release_cli_releaser --autopilot-release --run release_cli_run --confirm >/dev/null 2>&1
[ "$?" -eq 0 ] || A4_OK=false
# A DIFFERENT releaser must also land on exit 0: the event id is derived from
# the run, not from the caller, so the second session finds the prior record
# instead of meeting "terminal run cannot be released".
run_verb "$PROJECT" release_cli_second --autopilot-release --run release_cli_run --confirm >/dev/null 2>&1
[ "$?" -eq 0 ] || A4_OK=false
[ "$(digest "$RUN_FILE")" = "$AFTER_A3" ] || A4_OK=false
if [ "$A4_OK" = true ]; then
  check "A4 a repeat release is a byte-stable no-op for the original and for a second caller" PASS
else
  check "A4 release idempotency across callers (precondition released=$A4_RELEASED)" FAIL
fi

# --- A5 the owner is refused: its own run is cancelled the ordinary way ------
OWNER_PROJECT="$TMP/owner-project"; mkdir -p "$OWNER_PROJECT"
OWNER_PROJECT="$(cd "$OWNER_PROJECT" && pwd -P)"
activate_session "$OWNER_PROJECT" release_cli_self || exit 1
SELF_KEY="$ZENSU_SESSION_KEY"
autopilot_begin_run release_self_run "$SELF_KEY" "$OWNER_PROJECT" >/dev/null 2>&1 || exit 1
SELF_FILE="$(autopilot_run_file release_self_run "$OWNER_PROJECT")"
BEFORE_A5="$(digest "$SELF_FILE")"
run_verb "$OWNER_PROJECT" release_cli_self --autopilot-release --run release_self_run --confirm >/dev/null 2>&1
A5_RC=$?
if [ "$A5_RC" -eq 4 ] && [ "$(digest "$SELF_FILE")" = "$BEFORE_A5" ]; then
  check "A5 the owning session is refused its own run and nothing is written" PASS
else
  check "A5 owner refusal (rc=$A5_RC)" FAIL
fi

# --- A6 --autopilot-begin --workspace records the declared tree --------------
WS_PROJECT="$TMP/ws-project"; mkdir -p "$WS_PROJECT/tree-a"
WS_PROJECT="$(cd "$WS_PROJECT" && pwd -P)"
WS_TREE_A="$WS_PROJECT/tree-a"
run_verb "$WS_PROJECT" ws_cli_owner --autopilot-begin --run ws_cli_run --workspace "$WS_TREE_A" >/dev/null 2>&1
A6_RC=$?
WS_RUN_FILE="$WS_PROJECT/.zensu/state/autopilot-run-ws_cli_run.json"
# The RECORD is canonicalized in node, so this expectation stays in node's
# namespace. Do not "unify" it with native_dir — see the note beside that helper.
WS_TREE_A_JSON="$(node -e 'process.stdout.write(JSON.stringify(require("fs").realpathSync.native(process.argv[1])))' "$WS_TREE_A")"
if [ "$A6_RC" -eq 0 ] && [ -f "$WS_RUN_FILE" ] \
  && json_ok "$WS_RUN_FILE" "value.workspaceRoot === $WS_TREE_A_JSON"; then
  check "A6 --workspace reaches the record as the run's working tree" PASS
else
  check "A6 --workspace recorded (rc=$A6_RC recorded=$(node -e 'try{process.stdout.write(String(require(process.argv[1]).workspaceRoot))}catch(e){process.stdout.write("<absent>")}' "$WS_RUN_FILE" 2>/dev/null) expected=$WS_TREE_A_JSON)" FAIL
fi

# --- A7 the flag rejects a missing directory and a duplicate spelling --------
A7_OK=true
run_verb "$WS_PROJECT" ws_cli_second --autopilot-begin --run ws_cli_missing --workspace "$WS_PROJECT/no-such-tree" >/dev/null 2>&1
[ "$?" -eq 2 ] || A7_OK=false
[ ! -e "$WS_PROJECT/.zensu/state/autopilot-run-ws_cli_missing.json" ] || A7_OK=false
run_verb "$WS_PROJECT" ws_cli_second --autopilot-begin --run ws_cli_dup --workspace "$WS_TREE_A" --workspace "$WS_TREE_A" >/dev/null 2>&1
[ "$?" -eq 2 ] || A7_OK=false
[ ! -e "$WS_PROJECT/.zensu/state/autopilot-run-ws_cli_dup.json" ] || A7_OK=false
if [ "$A7_OK" = true ]; then
  check "A7 a nonexistent or duplicated --workspace exits 2 without writing a run" PASS
else
  check "A7 --workspace argument validation" FAIL
fi

# --- A8 a declared workspace outside the project is refused ------------------
OUTSIDE="$TMP/outside-tree"; mkdir -p "$OUTSIDE"
run_verb "$WS_PROJECT" ws_cli_outside --autopilot-begin --run ws_cli_outside --workspace "$OUTSIDE" >/dev/null 2>&1
A8_RC=$?
if [ "$A8_RC" -eq 3 ] \
  && [ ! -e "$WS_PROJECT/.zensu/state/autopilot-run-ws_cli_outside.json" ]; then
  check "A8 a workspace that is neither this session's tree nor inside the project is refused" PASS
else
  check "A8 outside workspace refusal (rc=$A8_RC)" FAIL
fi

# --- A9 the git toplevel branch actually runs ---------------------------------
# Every other workspace fixture is a plain directory, so `rev-parse` fails there
# and the resolver returns its fallback. This is the only place the toplevel
# branch executes, and therefore the only place that would fail if it were
# deleted.
GIT_TREE="$TMP/git-tree"
mkdir -p "$GIT_TREE/nested/deeper"
if git -C "$GIT_TREE" init --quiet >/dev/null 2>&1; then
  GIT_TOP="$(native_dir "$GIT_TREE")"
  RESOLVED_DEEP="$(autopilot_workspace_root "$GIT_TREE/nested/deeper")"
  RESOLVED_TOP="$(autopilot_workspace_root "$GIT_TREE")"
  if [ "$RESOLVED_DEEP" = "$GIT_TOP" ] && [ "$RESOLVED_TOP" = "$GIT_TOP" ]; then
    check "A9 a subdirectory of a work tree resolves to the tree root, not to itself" PASS
  else
    check "A9 git toplevel resolution (deep=$RESOLVED_DEEP top=$GIT_TOP)" FAIL
  fi

  # A subdirectory is no longer an accepted SPELLING of the tree — a declared
  # workspace must be a toplevel — so the collision is driven the way it
  # actually occurs: a session standing in a subdirectory of the held tree.
  GIT_PROJECT="$GIT_TREE"
  run_verb "$GIT_PROJECT" git_ws_owner --autopilot-begin --run git_ws_run --workspace "$GIT_TREE" >/dev/null 2>&1
  GIT_BEGIN_RC=$?
  run_verb_in "$GIT_PROJECT" git_ws_other "$GIT_TREE/nested/deeper" --autopilot-begin --run git_ws_second >/dev/null 2>&1
  GIT_SECOND_RC=$?
  if [ "$GIT_BEGIN_RC" -eq 0 ] && [ "$GIT_SECOND_RC" -eq 4 ] \
    && [ ! -e "$GIT_PROJECT/.zensu/state/autopilot-run-git_ws_second.json" ]; then
    check "A10 a begin from a subdirectory is refused while the tree root is held" PASS
  else
    check "A10 subdirectory begin refused (first=$GIT_BEGIN_RC second=$GIT_SECOND_RC)" FAIL
  fi

  # FR-004. Before this the declaration resolved to the tree root and was
  # accepted, so the run recorded occupancy of the whole tree while the caller
  # had named one directory inside it. The refusal must also write nothing:
  # a refusal that still minted the run would leave the wider claim standing.
  run_verb "$GIT_PROJECT" git_ws_declared --autopilot-begin --run git_ws_declared_run \
    --workspace "$GIT_TREE/nested/deeper" >/dev/null 2>&1
  GIT_DECLARED_RC=$?
  if [ "$GIT_DECLARED_RC" -eq 3 ] \
    && [ ! -e "$GIT_PROJECT/.zensu/state/autopilot-run-git_ws_declared_run.json" ]; then
    check "A10b a declared workspace that is not a git toplevel is refused and writes nothing" PASS
  else
    check "A10b non-toplevel --workspace must be refused (rc=$GIT_DECLARED_RC, want 3)" FAIL
  fi
else
  check "A9 git is unavailable, so the toplevel branch could not be exercised" FAIL
  check "A10 git is unavailable, so the subdirectory collision could not be exercised" FAIL
fi

# --- A11 the skill contract: registration and the exact command spellings ----
A11_OK=true
grep -qF '"./skills/autopilot-release"' "$PLUGIN_JSON" || A11_OK=false
grep -qE '^name: autopilot-release$' "$SKILL" || A11_OK=false
grep -qF '# /zensu:autopilot-release' "$SKILL" || A11_OK=false
grep -qF 'bash "$LOG" --autopilot-status' "$SKILL" || A11_OK=false
grep -qF 'bash "$LOG" --autopilot-release --run "<RUN_ID>" --confirm' "$SKILL" || A11_OK=false
# Every runnable reference must resolve: the file has to assign what it uses.
grep -qF 'ROOT="${CLAUDE_PLUGIN_ROOT}"' "$SKILL" || A11_OK=false
grep -qF 'LOG="$ROOT/hooks/lib/zensu-log.sh"' "$SKILL" || A11_OK=false
# The exit-code row must name 2 for a malformed invocation, which is what A1/A2
# actually observe. A table that says otherwise sends a model hunting for
# corrupt state after a typo.
grep -qF '`2` a malformed' "$SKILL" || A11_OK=false
if [ "$A11_OK" = true ]; then
  check "A11 the release skill is registered and every command it prints is runnable" PASS
else
  check "A11 release skill contract" FAIL
fi

# --- A12 release-id child hygiene (source pin) --------------------------------
# Both properties are unreachable behaviourally from here: the arm needs node
# for session resolution BEFORE it derives the id, so a stub that silences the
# derivation never gets that far, and an inherited descriptor only surfaces as
# an unrelated suite hanging minutes later. Pinned at source instead, which is
# what this suite already does for branches a fixture cannot enter.
A12_OK=true
grep -qF "2>/dev/null </dev/null)" "$LOG" || A12_OK=false
grep -qF 'event_digest="${event_val#release-}"' "$LOG" || A12_OK=false
grep -qF '"${#event_digest}" -ne 64' "$LOG" || A12_OK=false
grep -qF 'derived release event id has an unexpected shape' "$LOG" || A12_OK=false
if [ "$A12_OK" = true ]; then
  check "A12 the release-id child redirects stdin and its output shape is asserted" PASS
else
  check "A12 release-id child hygiene" FAIL
fi

printf '%s\n' "----" "test-autopilot-release-cli: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
