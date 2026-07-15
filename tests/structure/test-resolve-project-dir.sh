#!/bin/bash
# Covers hooks/lib/resolve-project-dir.js + the zensu_resolve_project_dir wrapper
# + the zensu-log.sh CLAUDE_PROJECT_DIR recovery that together fix the git-worktree
# chain-enforcer deadlock: a non-hook Bash `--chain-done` (CLAUDE_PROJECT_DIR unset,
# cwd = a worktree) must land its state file where the Stop hook (which HAS
# CLAUDE_PROJECT_DIR) reads it, by recovering the launch/project dir from the active
# transcript's cwd rather than from cwd/gitToplevel.
set -u

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  SKIP  test-resolve-project-dir on Windows — POSIX-path harness"
    exit 0 ;;
esac

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/resolve-project-dir.js"
SESSION_HELPER="$PLUGIN_DIR/hooks/lib/zensu-session.sh"
LOG_SH="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP  node not on PATH"
  echo "test-resolve-project-dir: skipped"
  exit 0
fi

if [ ! -f "$HELPER" ]; then
  check "P0 hooks/lib/resolve-project-dir.js exists" FAIL
  echo "----"
  echo "test-resolve-project-dir: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P0 hooks/lib/resolve-project-dir.js exists" PASS

TMP_ROOT="$(mktemp -d -t "resolve-pd-XXXXXX")"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# Pin HOME into the temp tree so config resolution (zensu-config.sh reads
# $HOME/.zensu/config.json) is fully hermetic and cannot pick up the developer's
# real global config in the E1/W1 end-to-end paths.
export HOME="$TMP_ROOT/home"
mkdir -p "$HOME"

PROJECTS="$TMP_ROOT/projects"
mkdir -p "$PROJECTS"

sanitize_pd() { node -e 'process.stdout.write(String(process.argv[1]).replace(/[^A-Za-z0-9_-]/g,"-"))' "$1"; }

# plant <cwd> <uuid> [command-marker] -> creates $PROJECTS/<sanitize(cwd)>/<uuid>.jsonl
# with a queue-operation preamble (no cwd), a cwd-bearing entry, and an optional
# Bash tool_use line carrying a command needle. Echoes the file path.
plant() {
  local cwd="$1" uuid="$2" cmd="${3:-}"
  local sub dir f
  sub="$(sanitize_pd "$cwd")"
  dir="$PROJECTS/$sub"
  mkdir -p "$dir"
  f="$dir/$uuid.jsonl"
  {
    printf '%s\n' '{"type":"queue-operation","sessionId":"'"$uuid"'"}'
    printf '%s\n' '{"type":"attachment","cwd":"'"$cwd"'","sessionId":"'"$uuid"'"}'
    if [ -n "$cmd" ]; then
      printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"'"$cmd"'"}}'
    fi
  } > "$f"
  echo "$f"
}

# ── P1 — active transcript cwd wins over the process cwd ──────────────────────
P1_CWD="$TMP_ROOT/p1-launch-root"; mkdir -p "$P1_CWD"
P1_WT="$TMP_ROOT/p1-worktree"; mkdir -p "$P1_WT"
P1_UUID="aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
P1_NEEDLE="node resolve-project-dir P1-UNIQUE-NEEDLE-Q7"
plant "$P1_CWD" "$P1_UUID" "$P1_NEEDLE" >/dev/null
P1_OUT="$(cd "$P1_WT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$PROJECTS" ZENSU_OWN_CMD="$P1_NEEDLE" node "$HELPER")"
if [ "$P1_OUT" = "$P1_CWD" ]; then
  check "P1 CLAUDE_PROJECT_DIR unset + cwd=worktree -> prints active transcript cwd (not process cwd)" PASS
else
  check "P1 transcript cwd wins (got '$P1_OUT' expected '$P1_CWD')" FAIL
fi

# ── P2 — ZENSU_OWN_CMD tail-match disambiguates across subdirs, beats mtime ───
P2_CWD_NEW="$TMP_ROOT/p2-newer"; mkdir -p "$P2_CWD_NEW"
P2_CWD_OLD="$TMP_ROOT/p2-older"; mkdir -p "$P2_CWD_OLD"
P2_UUID_NEW="bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"
P2_UUID_OLD="bbbbbbbb-4444-5555-6666-bbbbbbbbbbbb"
P2_NEEDLE="bash zensu-log.sh --chain-done P2-UNIQUE-NEEDLE-Z9"
P2_NEW_F="$(plant "$P2_CWD_NEW" "$P2_UUID_NEW" "echo unrelated")"
P2_OLD_F="$(plant "$P2_CWD_OLD" "$P2_UUID_OLD" "$P2_NEEDLE")"
# make NEW strictly newer than OLD so a pure-mtime pick would (wrongly) choose NEW
P2_NEW_FULL="$P2_NEW_F" P2_OLD_FULL="$P2_OLD_F" node -e '
  const fs = require("fs");
  const now = Date.now();
  fs.utimesSync(process.env.P2_OLD_FULL, (now-4000)/1000, (now-4000)/1000);
  fs.utimesSync(process.env.P2_NEW_FULL, (now-500)/1000, (now-500)/1000);
'
P2_OUT="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$PROJECTS" ZENSU_OWN_CMD="$P2_NEEDLE" node "$HELPER")"
if [ "$P2_OUT" = "$P2_CWD_OLD" ]; then
  check "P2 ZENSU_OWN_CMD tail-match picks the needle-bearing transcript across subdirs (over newest mtime)" PASS
else
  check "P2 cross-subdir tail-match (got '$P2_OUT' expected '$P2_CWD_OLD')" FAIL
fi

# ── P3 — no candidates -> empty stdout, exit 0 (caller leaves CPD untouched) ──
P3_OUT_FILE="$TMP_ROOT/p3.out"; P3_EXIT_FILE="$TMP_ROOT/p3.exit"
( cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$TMP_ROOT/does-not-exist" node "$HELPER" ) > "$P3_OUT_FILE" 2>/dev/null
echo "$?" > "$P3_EXIT_FILE"
if [ -z "$(cat "$P3_OUT_FILE")" ] && [ "$(cat "$P3_EXIT_FILE")" = "0" ]; then
  check "P3 no active transcript -> empty stdout + exit 0" PASS
else
  check "P3 empty-on-miss (out='$(cat "$P3_OUT_FILE")' exit='$(cat "$P3_EXIT_FILE")')" FAIL
fi

# ── P4 — Tier-1 ZENSU_TRANSCRIPT_PATH parses that file's cwd directly ─────────
P4_CWD="$TMP_ROOT/p4-launch-root"; mkdir -p "$P4_CWD"
P4_UUID="cccccccc-1111-2222-3333-cccccccccccc"
P4_F="$(plant "$P4_CWD" "$P4_UUID")"
mkdir -p "$TMP_ROOT/empty-projects"
P4_OUT="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_TRANSCRIPT_PATH="$P4_F" ZENSU_PROJECTS_DIR="$TMP_ROOT/empty-projects" node "$HELPER")"
if [ "$P4_OUT" = "$P4_CWD" ]; then
  check "P4 ZENSU_TRANSCRIPT_PATH (Tier-1) parses the transcript cwd directly, bypassing the scan" PASS
else
  check "P4 Tier-1 transcript-path cwd (got '$P4_OUT' expected '$P4_CWD')" FAIL
fi

# ── E1 — end to end: a valid zero-review chain closes in the recovered project ─
# Regression for the reported deadlock. CLAUDE_PROJECT_DIR + CLAUDE_SESSION_ID unset,
# cwd = a worktree that is NOT the project dir. The recovery must anchor the state
# file to the transcript cwd, and an enforcer-style read (CLAUDE_PROJECT_DIR = that
# dir) must observe chainDone=true.
E1_CWD="$TMP_ROOT/e1-launch-root"; mkdir -p "$E1_CWD"
E1_WT="$TMP_ROOT/e1-worktree"; mkdir -p "$E1_WT"
E1_UUID="dddddddd-1111-2222-3333-dddddddddddd"
E1_NEEDLE="bash $LOG_SH --chain-done"
plant "$E1_CWD" "$E1_UUID" "$E1_NEEDLE" >/dev/null

( cd "$E1_WT" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_SESSION_ID \
    ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    ZENSU_OWN_CMD="$E1_NEEDLE" bash "$LOG_SH" --tdd-begin >/dev/null 2>&1 )
( cd "$E1_WT" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_SESSION_ID \
    ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    ZENSU_OWN_CMD="$E1_NEEDLE" bash "$LOG_SH" --tdd-complete >/dev/null 2>&1 )
( cd "$E1_WT" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_SESSION_ID \
    ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    ZENSU_OWN_CMD="$E1_NEEDLE" bash "$LOG_SH" --chain-done >/dev/null 2>&1 )

E1_STATE="$E1_CWD/.zensu/state/tdd-phase-${E1_UUID}.json"
if [ -f "$E1_STATE" ]; then
  check "E1a valid zero-review chain anchors state to transcript cwd (not worktree cwd)" PASS
else
  ACTUAL="$(find "$E1_CWD" "$E1_WT" -name 'tdd-phase-*.json' 2>/dev/null | tr '\n' ' ')"
  check "E1a state-file anchored to transcript cwd (expected $E1_STATE; found: ${ACTUAL:-none})" FAIL
fi

if [ -f "$E1_STATE" ] && grep -q '"chainDone": true' "$E1_STATE"; then
  check "E1b recovered --chain-done wrote chainDone=true" PASS
else
  check "E1b chainDone=true in recovered state file" FAIL
fi

# Enforcer-side read: exactly what stop-chain-enforcer.sh does — resolve the state
# file with CLAUDE_PROJECT_DIR set (as a hook sees it) + the session UUID, then
# read the chainDone flag. Pre-fix this reads a different file and returns false.
E1_VERDICT="$(CLAUDE_PROJECT_DIR="$E1_CWD" bash -c '
  source "'"$PHASE_LIB"'"
  sf="$(tdd_state_file "'"$E1_UUID"'")"
  tdd_chain_done "$sf"
' 2>/dev/null)"
if [ "$E1_VERDICT" = "true" ]; then
  check "E1c enforcer-style read (CLAUDE_PROJECT_DIR + session_id) observes chainDone=true" PASS
else
  check "E1c enforcer observes chainDone (got '$E1_VERDICT' expected 'true')" FAIL
fi

# The worktree cwd must NOT have accumulated any chain state (proves cwd was ignored).
if [ ! -d "$E1_WT/.zensu/state" ] || [ -z "$(ls -A "$E1_WT/.zensu/state" 2>/dev/null)" ]; then
  check "E1d no chain state written under the worktree cwd" PASS
else
  check "E1d worktree cwd polluted with chain state ($(ls -A "$E1_WT/.zensu/state" 2>/dev/null | tr '\n' ' '))" FAIL
fi

# ── W1 — wrapper returns the transcript dir; validates it must exist ──────────
W1_CWD="$TMP_ROOT/w1-launch-root"; mkdir -p "$W1_CWD"
W1_UUID="eeeeeeee-1111-2222-3333-eeeeeeeeeeee"
W1_NEEDLE="bash zensu-log.sh --tdd-complete W1-NEEDLE-Q4"
plant "$W1_CWD" "$W1_UUID" "$W1_NEEDLE" >/dev/null
W1_OUT="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR \
  ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" ZENSU_OWN_CMD="$W1_NEEDLE" \
  bash -c "source '$SESSION_HELPER'; zensu_resolve_project_dir")"
if [ "$W1_OUT" = "$W1_CWD" ]; then
  check "W1 zensu_resolve_project_dir wraps the helper and returns the transcript cwd" PASS
else
  check "W1 wrapper resolves project dir (got '$W1_OUT' expected '$W1_CWD')" FAIL
fi

# ── PH — --phase with a quoted --reason: the recovery needle must stay reason-free ─
# Locks the fix for the unquoted-$* needle bug. The transcript stores --reason
# QUOTED (\"...\"); a raw "$*" needle would collapse the quotes and never match,
# falling through to the newer decoy. The reason-free needle must still match.
PH_CWD="$TMP_ROOT/ph-launch-root"; mkdir -p "$PH_CWD"
PH_WT="$TMP_ROOT/ph-worktree"; mkdir -p "$PH_WT"
PH_DECOY="$TMP_ROOT/ph-decoy-root"; mkdir -p "$PH_DECOY"
PH_UUID="ffffffff-1111-2222-3333-ffffffffffff"
PH_DECOY_UUID="ffffffff-4444-5555-6666-ffffffffffff"
PH_SUB="$(sanitize_pd "$PH_CWD")"; mkdir -p "$PROJECTS/$PH_SUB"
{
  printf '%s\n' '{"type":"attachment","cwd":"'"$PH_CWD"'","sessionId":"'"$PH_UUID"'"}'
  printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"bash '"$LOG_SH"' --phase IMPL --step PHX --reason \"why it failed here\""}}'
} > "$PROJECTS/$PH_SUB/$PH_UUID.jsonl"
PH_DECOY_F="$(plant "$PH_DECOY" "$PH_DECOY_UUID" "echo ph decoy noise")"
PH_REAL_F="$PROJECTS/$PH_SUB/$PH_UUID.jsonl"
PH_REAL_E="$PH_REAL_F" PH_DECOY_E="$PH_DECOY_F" node -e '
  const fs=require("fs"); const now=Date.now();
  fs.utimesSync(process.env.PH_REAL_E,(now-4000)/1000,(now-4000)/1000);
  fs.utimesSync(process.env.PH_DECOY_E,(now-200)/1000,(now-200)/1000);
'
( cd "$PH_WT" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_SESSION_ID \
    ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LOG_SH" --phase IMPL --step PHX --reason "why it failed here" >/dev/null 2>&1 )
PH_STATE="$PH_CWD/.zensu/state/tdd-phase-${PH_UUID}.json"
if [ -f "$PH_STATE" ]; then
  check "PH --phase w/ quoted --reason: reason-free needle matches, state anchored to correct transcript cwd (beats newer decoy)" PASS
else
  PH_FOUND="$(find "$PH_CWD" "$PH_DECOY" "$PH_WT" -name 'tdd-phase-*.json' 2>/dev/null | tr '\n' ' ')"
  check "PH reason-free needle (expected $PH_STATE; found: ${PH_FOUND:-none})" FAIL
fi

# ── G — the case --*) gate: the hot timestamp/style path must NOT spawn recovery ─
# A node shim on PATH logs every node argv; we assert `timestamp` never invokes
# resolve-project-dir.js while a `--` state verb does (positive control).
G_BIN="$TMP_ROOT/g-bin"; mkdir -p "$G_BIN"
G_LOG="$TMP_ROOT/g-node-argv.log"
G_REAL_NODE="$(command -v node)"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'printf "%s\n" "$*" >> "'"$G_LOG"'"'
  printf '%s\n' 'exec "'"$G_REAL_NODE"'" "$@"'
} > "$G_BIN/node"
chmod +x "$G_BIN/node"
G_CWD="$TMP_ROOT/g-launch-root"; mkdir -p "$G_CWD"
G_WT="$TMP_ROOT/g-worktree"; mkdir -p "$G_WT"
G_UUID="99999999-1111-2222-3333-999999999999"
plant "$G_CWD" "$G_UUID" "bash $LOG_SH --chain-done G-K5" >/dev/null
: > "$G_LOG"
( cd "$G_WT" && env -u CLAUDE_PROJECT_DIR PATH="$G_BIN:$PATH" \
    ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LOG_SH" timestamp 123 >/dev/null 2>&1 )
if ! grep -q 'resolve-project-dir' "$G_LOG"; then
  check "G gate: 'timestamp' (hot path) does NOT spawn resolve-project-dir recovery" PASS
else
  check "G gate: 'timestamp' wrongly triggered resolve-project-dir recovery" FAIL
fi
: > "$G_LOG"
( cd "$G_WT" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_SESSION_ID PATH="$G_BIN:$PATH" \
    ZENSU_PROJECTS_DIR="$PROJECTS" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    bash "$LOG_SH" --chain-done >/dev/null 2>&1 )
if grep -q 'resolve-project-dir' "$G_LOG"; then
  check "G gate: a '--' state verb DOES spawn resolve-project-dir recovery (positive control)" PASS
else
  check "G gate: '--chain-done' failed to trigger recovery (positive control)" FAIL
fi

# ── M — concurrent sessions: each ZENSU_OWN_CMD needle resolves its own cwd ────
M_CWD_A="$TMP_ROOT/m-sess-a"; mkdir -p "$M_CWD_A"
M_CWD_B="$TMP_ROOT/m-sess-b"; mkdir -p "$M_CWD_B"
M_UUID_A="a9a9a9a9-1111-2222-3333-a9a9a9a9a9a9"
M_UUID_B="b9b9b9b9-1111-2222-3333-b9b9b9b9b9b9"
M_NEEDLE_A="bash zensu-log.sh --chain-done M-SESSION-A-K1"
M_NEEDLE_B="bash zensu-log.sh --chain-done M-SESSION-B-K2"
plant "$M_CWD_A" "$M_UUID_A" "$M_NEEDLE_A" >/dev/null
plant "$M_CWD_B" "$M_UUID_B" "$M_NEEDLE_B" >/dev/null
M_OUT_A="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$PROJECTS" ZENSU_OWN_CMD="$M_NEEDLE_A" node "$HELPER")"
M_OUT_B="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$PROJECTS" ZENSU_OWN_CMD="$M_NEEDLE_B" node "$HELPER")"
if [ "$M_OUT_A" = "$M_CWD_A" ] && [ "$M_OUT_B" = "$M_CWD_B" ]; then
  check "M concurrent sessions: each needle resolves ITS OWN transcript cwd" PASS
else
  check "M multi-session tie-break (A='$M_OUT_A' exp '$M_CWD_A' | B='$M_OUT_B' exp '$M_CWD_B')" FAIL
fi

# ── C — ZENSU_BASH_START cutoff excludes a future-mtime transcript ─────────────
C_CWD_PAST="$TMP_ROOT/c-past"; mkdir -p "$C_CWD_PAST"
C_CWD_FUTURE="$TMP_ROOT/c-future"; mkdir -p "$C_CWD_FUTURE"
C_UUID_PAST="c1c1c1c1-1111-2222-3333-c1c1c1c1c1c1"
C_UUID_FUTURE="c2c2c2c2-1111-2222-3333-c2c2c2c2c2c2"
C_NEEDLE="bash zensu-log.sh --chain-done C-CUTOFF-K3"
C_PAST_F="$(plant "$C_CWD_PAST" "$C_UUID_PAST" "$C_NEEDLE")"
C_FUTURE_F="$(plant "$C_CWD_FUTURE" "$C_UUID_FUTURE" "$C_NEEDLE")"
C_BASH_START="$(C_PAST_E="$C_PAST_F" C_FUTURE_E="$C_FUTURE_F" node -e '
  const fs=require("fs"); const now=Date.now();
  const past=now-100000, fut=now+100000;
  fs.utimesSync(process.env.C_PAST_E, past/1000, past/1000);
  fs.utimesSync(process.env.C_FUTURE_E, fut/1000, fut/1000);
  process.stdout.write(String(BigInt(now)*1000000n));
')"
C_OUT="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$PROJECTS" ZENSU_OWN_CMD="$C_NEEDLE" node "$HELPER" "$C_BASH_START")"
if [ "$C_OUT" = "$C_CWD_PAST" ]; then
  check "C ZENSU_BASH_START cutoff excludes the future-mtime transcript (past wins despite identical needle)" PASS
else
  check "C cutoff filter (got '$C_OUT' expected '$C_CWD_PAST')" FAIL
fi

# ── SYM — a symlinked project subdir under the projects base is still scanned ──
SYM_CWD="$TMP_ROOT/sym-launch-root"; mkdir -p "$SYM_CWD"
SYM_REAL="$TMP_ROOT/sym-real-store"; mkdir -p "$SYM_REAL"
SYM_UUID="d1d1d1d1-1111-2222-3333-d1d1d1d1d1d1"
SYM_NEEDLE="bash zensu-log.sh --chain-done SYM-K4"
{
  printf '%s\n' '{"type":"attachment","cwd":"'"$SYM_CWD"'","sessionId":"'"$SYM_UUID"'"}'
  printf '%s\n' '{"type":"tool_use","name":"Bash","input":{"command":"'"$SYM_NEEDLE"'"}}'
} > "$SYM_REAL/$SYM_UUID.jsonl"
ln -s "$SYM_REAL" "$PROJECTS/sym-linked-subdir"
SYM_OUT="$(cd "$TMP_ROOT" && env -u CLAUDE_PROJECT_DIR ZENSU_PROJECTS_DIR="$PROJECTS" ZENSU_OWN_CMD="$SYM_NEEDLE" node "$HELPER")"
if [ "$SYM_OUT" = "$SYM_CWD" ]; then
  check "SYM symlinked project subdir is scanned (listAllCandidates isSymbolicLink branch)" PASS
else
  check "SYM symlinked subdir scan (got '$SYM_OUT' expected '$SYM_CWD')" FAIL
fi

echo "----"
echo "test-resolve-project-dir: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
