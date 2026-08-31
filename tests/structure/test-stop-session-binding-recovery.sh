#!/bin/bash
# Pins the recovery paths of stop-chain-enforcer.sh when the immutable session
# binding cannot be resolved:
#   B0 healthy bound session                   -> still blocks (control)
#   B1 recorded project root deleted           -> RELEASE, cause and both remedies on stderr,
#                                                 dead path named, no bypass advertised
#   B4 root replaced by a symlink, no opt-out  -> block, cause named, no bypass in the reason;
#                                                 B4c pins that chainEnforcer=false releases it
#                                                 (skipped where directory symlinks are unavailable)
#   B5 block reasons stay field-free           -> no interpolation in any emit payload
#   B6 session with no record at all           -> release, missing-record cause routed to a fresh
#                                                 session and to /zensu:doctor
#
# TWO bind failures release, and only two. Both mean the same thing — no
# workflow state is reachable, so nothing is being waived: B6 has no record at
# all, and B1 has an intact record whose project root is gone, which took
# <project_root>/.zensu/state/ with it. Everything else still blocks, because a
# record that disagrees about anything ELSE may own state whose completion is
# unproven. B4 is the discrimination pin for that line: a root that still exists
# but no longer matches is NOT the released state. B1d pins the other half —
# a second disagreement is never relaxed alongside the first.
#
# B1 used to pin the opposite (deleted root -> block, releasable only via
# ZENSU_CHAIN=off). That left a session whose worktree the harness recycled
# unable to end a turn at all, with every tool including /zensu:doctor denied,
# and the operator-facing switch reachable only from a terminal the model
# cannot see. The release replaces the switch for that state.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN 2>/dev/null || true
PROJECTS="$STATE_DIR/projects"
mkdir -p "$PROJECTS"
cleanup() { chmod -R u+w "$STATE_DIR" 2>/dev/null; rm -rf "$STATE_DIR"; }
trap cleanup EXIT

decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{console.log(JSON.parse(s).decision==="block"?"block":"allow")}catch(_){console.log("allow")}});'; }
reason()   { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).reason||"")}catch(_){console.log("")}});'; }

# Arm a blocking standalone chain in a fresh project root (never in a subshell:
# the baseline exports the plugin-data path the hook binds against).
ARMED_ROOT=""
ARMED_RECORD=""
arm() {
  local label="$1"
  local project="$PROJECTS/$label"
  mkdir -p "$project"
  project="$(cd "$project" && pwd -P)"
  export CLAUDE_PROJECT_DIR="$project"
  export ZENSU_TEST_PLUGIN_DATA="$STATE_DIR/plugin-data/$label"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$label" || return 1
  bash "$LOG" --tdd-begin --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  bash "$LOG" --tdd-complete --session "$ZENSU_SESSION_KEY" >/dev/null 2>&1 || return 1
  ARMED_ROOT="$ZENSU_PROJECT_ROOT"
  ARMED_RECORD="$CLAUDE_PLUGIN_DATA/session-control/v1/records/$ZENSU_SESSION_KEY.json"
}

stop_run() {
  local raw="$1" errfile="$2"
  shift 2
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$raw" | env "$@" bash "$STOP" 2>"$errfile"
}

# --- B0 control: a healthy bound session still blocks ---
arm stop-bind-control || { echo "B0 fixture failed" >&2; exit 1; }
ROOT0="$ARMED_ROOT"
ERR0="$STATE_DIR/b0.err"
OUT0="$(stop_run stop-bind-control "$ERR0" IGNORE=1)"
REASON0="$(printf '%s' "$OUT0" | reason)"
if [ "$(printf '%s' "$OUT0" | decision)" = "block" ] \
  && printf '%s' "$REASON0" | grep -qF 'zensu:code-reviewer'; then
  check "B0 healthy bound session still blocks on the chain reason" PASS
else
  check "B0 healthy bound session (out=$OUT0)" FAIL
fi

# --- B1 recorded project root deleted -> released, with the cause and remedies ---
# The workflow document lived at <project_root>/.zensu/state/, so it is gone
# with the directory: no review chain and no Autopilot run remain to enforce and
# none is waived. Binding still FAILS here — the record is immutable and its
# recorded root really is missing — so the release must come from the hook
# recognizing that specific bind failure, not from a successful bind.
arm stop-bind-deleted || { echo "B1 fixture failed" >&2; exit 1; }
ROOT1="$ARMED_ROOT"
rm -rf "$ROOT1"
[ ! -d "$ROOT1" ] || { echo "B1 fixture: project root still present" >&2; exit 1; }
ERR1="$STATE_DIR/b1.err"
OUT1="$(stop_run stop-bind-deleted "$ERR1" IGNORE=1)"
if [ "$(printf '%s' "$OUT1" | decision)" = "allow" ] \
  && grep -qF "context project root does not exist" "$ERR1"; then
  check "B1 a deleted project root releases Stop instead of wedging the session forever" PASS
else
  check "B1 deleted project root (out=$OUT1 err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
# Naming the dead path is the whole point of the remedy: "re-create exactly that
# directory" is unusable advice if the user is not told which directory.
#
# The claim must also stay within what an ENOENT proves. A MOVED or renamed root
# — and an unmounted volume — produce the same ENOENT while the workflow state
# survives intact somewhere else, so the message may say no completion was
# proven, but must NOT claim nothing existed to prove. Pinning the negative here
# is what stops that overclaim from creeping back in.
if grep -qF "Re-create exactly that directory" "$ERR1" \
  && grep -qF "start a new session" "$ERR1" \
  && grep -qF "no completion was proven" "$ERR1" \
  && grep -qF "moved rather than deleted" "$ERR1" \
  && ! grep -qF "none was waived" "$ERR1" \
  && grep -qF "$ROOT1" "$ERR1"; then
  check "B1a the release names the dead path, both remedies, and claims only what an ENOENT proves" PASS
else
  check "B1a release diagnostic (err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
# Same rule as B6c: a release needs no opt-out, so it must not teach one either.
if [ -z "$(printf '%s' "$OUT1" | reason)" ] \
  && ! grep -qF 'ZENSU_CHAIN=off' "$ERR1" \
  && ! grep -qF 'chainEnforcer' "$ERR1"; then
  check "B1b the release emits no block reason and advertises no bypass" PASS
else
  check "B1b release payload (out=$OUT1 err='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
# The release is bound to ONE disagreement. Break a second thing about the same
# record — here the runtime digest — and it must go back to blocking, or the
# relaxation would launder every other integrity failure that happens to arrive
# with a missing directory.
arm stop-bind-deleted-tampered || { echo "B1d fixture failed" >&2; exit 1; }
ROOT1D="$ARMED_ROOT"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const record = JSON.parse(fs.readFileSync(file, "utf8"));
  record.runtime_digest = "sha256:" + "0".repeat(64);
  record.source_revision = record.runtime_digest;
  fs.writeFileSync(file, JSON.stringify(record));
' "$ARMED_RECORD" || { echo "B1d fixture: could not tamper the record" >&2; exit 1; }
rm -rf "$ROOT1D"
ERR1D="$STATE_DIR/b1d.err"
OUT1D="$(stop_run stop-bind-deleted-tampered "$ERR1D" IGNORE=1)"
if [ "$(printf '%s' "$OUT1D" | decision)" = "block" ]; then
  check "B1d a deleted root PLUS a second disagreement still blocks — one relaxation, never two" PASS
else
  check "B1d two disagreements (out=$OUT1D err='$(cat "$ERR1D" 2>/dev/null)')" FAIL
fi
# The opt-out switches must stay proven on a state that blocks — and on EVERY
# platform. B4c below covers them too, but it sits inside the symlink-gated
# block, so on a runner without directory symlinks (Git Bash on Windows, where
# this suite is sharded) the bind-failure opt-out would have zero behavioral
# coverage. This fixture blocks platform-independently, so it carries the proof.
ERR1E="$STATE_DIR/b1e.err"
OUT1E="$(stop_run stop-bind-deleted-tampered "$ERR1E" ZENSU_CHAIN=off)"
CFG_OFF="$STATE_DIR/enforcer-off.json"
printf '{"hooks":{"chainEnforcer":false}}' > "$CFG_OFF"
ERR1F="$STATE_DIR/b1f.err"
OUT1F="$(stop_run stop-bind-deleted-tampered "$ERR1F" "ZENSU_CONFIG=$CFG_OFF")"
if [ "$(printf '%s' "$OUT1E" | decision)" = "allow" ] \
  && grep -qF "ZENSU_CHAIN=off is set explicitly" "$ERR1E" \
  && [ "$(printf '%s' "$OUT1F" | decision)" = "allow" ] \
  && grep -qF "hooks.chainEnforcer=false is configured" "$ERR1F"; then
  check "B1e both opt-out switches release a blocking bind failure, on every platform" PASS
else
  check "B1e opt-out switches (env=$OUT1E cfg=$OUT1F)" FAIL
fi

# --- B6 the session has NO record at all -----------------------------------
# The 0.17.0 mass failure: Session Control shipped in that release, and a
# resume/compact SessionStart requires a record it never mints, so every session
# predating the update is unbindable. Same hook path as B1, different cause —
# the stderr line must distinguish them instead of sending the user worktree
# hunting, and the escape must still work so the session can end its turn.
arm stop-bind-norecord || { echo "B6 fixture failed" >&2; exit 1; }
ERR6="$STATE_DIR/b6.err"
OUT6="$(stop_run "a-session-that-was-never-registered" "$ERR6" IGNORE=1)"
# Such a session has no workflow document, so there is no review chain and no
# Autopilot run to enforce and nothing is waived. The PreToolUse gates relax the
# same state, so blocking here would leave the user with tools but no way to end
# a turn — strictly worse than the deadlock this release fixes.
if [ "$(printf '%s' "$OUT6" | decision)" = "allow" ]; then
  check "B6 a session with no Session Control record releases Stop instead of wedging" PASS
else
  check "B6 unregistered session (out=$OUT6 err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi
if grep -qF "no record for this session" "$ERR6" \
  && grep -qF "none was waived" "$ERR6" \
  && grep -qF "without --continue/--resume" "$ERR6" \
  && grep -qF "/zensu:doctor" "$ERR6"; then
  check "B6a the release states no completion was proven and routes to a fresh session" PASS
else
  check "B6a missing-record diagnostic (err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi
# Both states release, but they are different diagnoses with different remedies,
# so their diagnostics must never collapse into one: B6 must not talk about a
# project root, and B1 must not talk about a missing record.
if ! grep -qF "context project root does not exist" "$ERR6" \
  && ! grep -qF "missing file" "$ERR1" \
  && ! grep -qF "no record for this session" "$ERR1" \
  && ! grep -qF "Re-create exactly that directory" "$ERR6"; then
  check "B6b the no-record and deleted-root diagnostics never collapse into one" PASS
else
  check "B6b diagnostic distinction (b6='$(cat "$ERR6" 2>/dev/null)' b1='$(cat "$ERR1" 2>/dev/null)')" FAIL
fi
# Releasing must not require an opt-out switch, and must not teach one either.
if ! grep -qF 'ZENSU_CHAIN=off' "$ERR6" && ! grep -qF 'chainEnforcer' "$ERR6"; then
  check "B6c the no-record release needs no bypass and advertises none" PASS
else
  check "B6c no-record release advertises a bypass (err='$(cat "$ERR6" 2>/dev/null)')" FAIL
fi

# --- root replaced by a symlink: a resolvable path with an unusable record.
# Windows without developer mode cannot create one, so probe before relying on it.
SYMLINK_OK=true
if ! ln -s "$STATE_DIR" "$STATE_DIR/symlink-probe" 2>/dev/null || [ ! -L "$STATE_DIR/symlink-probe" ]; then
  SYMLINK_OK=false
fi
rm -f "$STATE_DIR/symlink-probe" 2>/dev/null

replace_root_with_symlink() {
  local root="$1"
  mv "$root" "${root}.real" || return 1
  ln -s "${root}.real" "$root" || return 1
  [ -L "$root" ] && [ -d "$root" ]
}

# --- B4 without an opt-out it still blocks, but says which cause and how to fix ---
if [ "$SYMLINK_OK" != true ]; then
  check "B4 unusable-record branch skipped: this platform cannot create directory symlinks" PASS
else
arm stop-bind-record || { echo "B4 fixture failed" >&2; exit 1; }
ROOT4="$ARMED_ROOT"
replace_root_with_symlink "$ROOT4" || { echo "B4 fixture: symlink swap failed" >&2; exit 1; }
ERR4="$STATE_DIR/b4.err"
OUT4="$(stop_run stop-bind-record "$ERR4" IGNORE=1)"
REASON4="$(printf '%s' "$OUT4" | reason)"
if [ "$(printf '%s' "$OUT4" | decision)" = "block" ] \
  && printf '%s' "$REASON4" | grep -qF 'no longer resolves against its recorded project root' \
  && printf '%s' "$REASON4" | grep -qF 'Restore that path'; then
  check "B4 unusable record blocks with its own cause and remedy" PASS
else
  check "B4 unusable record (out=$OUT4)" FAIL
fi
if ! printf '%s' "$REASON4" | grep -qF 'ZENSU_CHAIN' \
  && ! printf '%s' "$REASON4" | grep -qF 'chainEnforcer' \
  && grep -qF 'ZENSU_CHAIN=off or hooks.chainEnforcer=false' "$ERR4" \
  && grep -qF "$ROOT4" "$ERR4"; then
  check "B4a release switches stay operator-facing, never in the model reason" PASS
else
  check "B4a switch placement (reason='$REASON4' err='$(cat "$ERR4" 2>/dev/null)')" FAIL
fi
if printf '%s' "$REASON4" | grep -qF 'Zensu Stop denied: the immutable Session Control record' \
  && ! printf '%s' "$REASON4" | grep -qF 'the immutable main-session binding is unavailable'; then
  check "B4b the single all-causes reason was replaced by a specific one" PASS
else
  check "B4b cause-specific reason (reason='$REASON4')" FAIL
fi
# The symlink-specific extra: B1e already proves the switches release a blocking
# bind failure on every platform, so this one only adds the unusable-record
# state, which needs directory symlinks and is therefore skipped where they are
# unavailable.
ERR4C="$STATE_DIR/b4c.err"
OUT4C="$(stop_run stop-bind-record "$ERR4C" "ZENSU_CONFIG=$CFG_OFF")"
ERR4D="$STATE_DIR/b4d.err"
OUT4D="$(stop_run stop-bind-record "$ERR4D" ZENSU_CHAIN=off)"
if [ "$(printf '%s' "$OUT4C" | decision)" = "allow" ] \
  && grep -qF "hooks.chainEnforcer=false is configured" "$ERR4C" \
  && [ "$(printf '%s' "$OUT4D" | decision)" = "allow" ] \
  && grep -qF "ZENSU_CHAIN=off is set explicitly" "$ERR4D"; then
  check "B4c both opt-out switches still release a session that genuinely blocks" PASS
else
  check "B4c opt-out switches (cfg=$OUT4C env=$OUT4D)" FAIL
fi
fi

# --- B5 every binding block payload stays field-free ---
BLOCK_BODIES="$(sed -n '/^emit_session_runtime_missing_block()/,/^}/p;/^emit_session_bind_failed_block()/,/^}/p;/^emit_session_record_unusable_block()/,/^}/p' "$STOP")"
BLOCK_COUNT="$(printf '%s\n' "$BLOCK_BODIES" | grep -c "^  printf '%s")"
if [ "$BLOCK_COUNT" -eq 3 ] && ! printf '%s\n' "$BLOCK_BODIES" | grep -q '\$'; then
  check "B5 all three binding block reasons are static literals" PASS
else
  check "B5 static block reasons (literals=$BLOCK_COUNT)" FAIL
fi

# --- B7 the residual TOCTOU release branch -----------------------------------
# It fires only when the root existed during the bind and was gone by the time
# resolution asked again, so it is not inducible from a test. Pin it statically
# the way B5 pins the block payloads: it must release (exit 0, no decision
# payload) and its message must still name the recorded root, or a future edit
# could delete it and turn that race back into the wedge this hook no longer has.
TOCTOU_BRANCH="$(sed -n '/^if ! PROJECT_ROOT=/,/^fi$/p' "$STOP")"
if printf '%s\n' "$TOCTOU_BRANCH" | grep -qF 'ZENSU_PROJECT_ROOT' \
  && printf '%s\n' "$TOCTOU_BRANCH" | grep -qF 'no longer exists' \
  && printf '%s\n' "$TOCTOU_BRANCH" | grep -qF 'releasing Stop' \
  && ! printf '%s\n' "$TOCTOU_BRANCH" | grep -q 'emit_session_bind_failed_block'; then
  check "B7 the residual TOCTOU branch still releases and still names the recorded root" PASS
else
  check "B7 TOCTOU branch missing or no longer releasing" FAIL
fi

# --- B8 the workflow document is gone while the record is intact and served ---
# A DIFFERENT state from B1, and the contrast is the point. There the recorded
# project ROOT is missing and the hook RELEASES, because nothing remains to
# enforce. Here the root is present and only the document is gone, so nothing
# proves completion and the hook must keep BLOCKING.
#
# What changed is the remedy. "repair the Session Control state" named no
# command, in a state where the capability gate denies every tool and only the
# two commands the Bash recognizer admits are reachable at all.
arm stop-bind-baseline || { echo "B8 fixture failed" >&2; exit 1; }
BASELINE_DOC8="$ARMED_ROOT/.zensu/state/tdd-phase-$ZENSU_SESSION_KEY.json"
[ -f "$BASELINE_DOC8" ] || { echo "B8 fixture: no workflow document to remove" >&2; exit 1; }
rm -f "$BASELINE_DOC8"
ERR8="$STATE_DIR/b8.err"
OUT8="$(stop_run stop-bind-baseline "$ERR8" IGNORE=1)"
REASON8="$(printf '%s' "$OUT8" | reason)"
if [ "$(printf '%s' "$OUT8" | decision)" = "block" ] \
  && printf '%s' "$REASON8" | grep -qF 'workflow baseline is missing' \
  && printf '%s' "$REASON8" | grep -qF '/zensu:adopt-session --confirm' \
  && ! printf '%s' "$REASON8" | grep -qF 'repair the Session Control state'; then
  check "B8 a missing workflow baseline still blocks, and now names a remedy that exists" PASS
else
  check "B8 missing workflow baseline (out=$OUT8)" FAIL
fi

echo "----"
echo "test-stop-session-binding-recovery: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
