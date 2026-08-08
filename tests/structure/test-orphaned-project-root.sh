#!/bin/bash
# Pins the orphaned-project-root state: a Session Control record that is valid
# in every respect except that the directory it recorded is gone, because the
# harness recycled or the user deleted that worktree.
#
# It is the SECOND relaxable bind failure, next to "no record at all". Both mean
# no workflow state is reachable — the document lives at
# <project_root>/.zensu/state/ and died with the directory — so nothing is being
# waived by relaxing either. Before this existed, such a session could not end a
# turn and could not run /zensu:doctor either, so it could not even learn why.
#
#   O1x predicate truth table — exactly one disagreement is relaxed, never two
#   O2x the Bash gate lets the read-only diagnostic through, write rules intact
#   O3x mutating tools stay denied — the relaxation is for diagnosis, not work
#   O4x /zensu:doctor classifies and renders this state instead of "no record"
#
# The Stop-hook half of the contract lives in
# tests/structure/test-stop-session-binding-recovery.sh (B1, B1d, B4).
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BINDER="$PLUGIN_DIR/hooks/lib/claude-hook-session-v1.js"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
BASH_GATE="$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"
EDIT_GATE="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
DOCTOR="$PLUGIN_DIR/hooks/lib/zensu-doctor.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
STATE_DIR="$(mktemp -d)"; export STATE_DIR
export ZENSU_CONFIG="$STATE_DIR/no-such-config.json"
unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE 2>/dev/null || true
PROJECTS="$STATE_DIR/projects"
mkdir -p "$PROJECTS"
cleanup() { chmod -R u+w "$STATE_DIR" 2>/dev/null; rm -rf "$STATE_DIR"; }
trap cleanup EXIT

# Same fixture shape as test-stop-session-binding-recovery.sh: a real record
# minted by the real SessionStart path, never a hand-written JSON file, so the
# predicate is exercised against records it will actually meet.
ARMED_ROOT=""; ARMED_RECORD=""; ARMED_DATA=""
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
  ARMED_ROOT="$ZENSU_PROJECT_ROOT"
  ARMED_DATA="$CLAUDE_PLUGIN_DATA"
  ARMED_RECORD="$CLAUDE_PLUGIN_DATA/session-control/v1/records/$ZENSU_SESSION_KEY.json"
}

# Answers by exit status only; stdout (the dead path) is discarded here.
orphaned() {
  local session="$1" data="$2"
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$session" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$data" \
      node "$BINDER" orphaned-project-root >/dev/null 2>&1
}
unregistered() {
  local session="$1" data="$2"
  printf '{"hook_event_name":"Stop","session_id":"%s"}' "$session" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$data" \
      node "$BINDER" unregistered >/dev/null 2>&1
}
decision() { node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){console.log("allow");return}try{const j=JSON.parse(s);const d=(j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision)||j.permissionDecision||j.decision;console.log(d==="deny"||d==="block"?"deny":"allow")}catch(_){console.log("allow")}});'; }

# --- O1 predicate truth table -----------------------------------------------
arm orphan-gone || { echo "O1 fixture failed" >&2; exit 1; }
GONE_ROOT="$ARMED_ROOT"; GONE_DATA="$ARMED_DATA"
rm -rf "$GONE_ROOT"
[ ! -d "$GONE_ROOT" ] || { echo "O1 fixture: project root still present" >&2; exit 1; }
if orphaned orphan-gone "$GONE_DATA"; then
  check "O11 a record whose project root was deleted IS the orphaned state" PASS
else
  check "O11 deleted project root" FAIL
fi
if ! unregistered orphan-gone "$GONE_DATA"; then
  check "O12 the same record is NOT unregistered — the two predicates stay distinct" PASS
else
  check "O12 predicate overlap" FAIL
fi
# The dead path is what makes "re-create exactly that directory" actionable.
ORPHAN_PATH="$(printf '{"hook_event_name":"Stop","session_id":"orphan-gone"}' \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$GONE_DATA" \
    node "$BINDER" orphaned-project-root 2>/dev/null)"
if [ "$ORPHAN_PATH" = "$GONE_ROOT" ]; then
  check "O13 the predicate prints the dead recorded path on a match" PASS
else
  check "O13 printed path (got='$ORPHAN_PATH' want='$GONE_ROOT')" FAIL
fi

arm orphan-healthy || { echo "O14 fixture failed" >&2; exit 1; }
if ! orphaned orphan-healthy "$ARMED_DATA"; then
  check "O14 a healthy record whose root exists is NOT the orphaned state" PASS
else
  check "O14 healthy record misclassified" FAIL
fi

# A record that ALSO disagrees about something else must never be relaxed: the
# state is defined by having exactly one disagreement, not by having this one.
arm orphan-tampered || { echo "O15 fixture failed" >&2; exit 1; }
TAMPERED_ROOT="$ARMED_ROOT"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const record = JSON.parse(fs.readFileSync(file, "utf8"));
  record.runtime_digest = "sha256:" + "0".repeat(64);
  record.source_revision = record.runtime_digest;
  fs.writeFileSync(file, JSON.stringify(record));
' "$ARMED_RECORD" || { echo "O15 fixture: could not tamper the record" >&2; exit 1; }
rm -rf "$TAMPERED_ROOT"
if ! orphaned orphan-tampered "$ARMED_DATA"; then
  check "O15 a deleted root plus a drifted runtime digest is NOT relaxed" PASS
else
  check "O15 two disagreements relaxed" FAIL
fi

# realpath would follow the link and report the target, quietly turning a
# present-but-wrong root into the relaxable state; lstat must not.
SYMLINK_OK=true
if ! ln -s "$STATE_DIR" "$STATE_DIR/symlink-probe" 2>/dev/null || [ ! -L "$STATE_DIR/symlink-probe" ]; then
  SYMLINK_OK=false
fi
rm -f "$STATE_DIR/symlink-probe" 2>/dev/null
if [ "$SYMLINK_OK" != true ]; then
  check "O16 symlink cases skipped: this platform cannot create directory symlinks" PASS
else
  arm orphan-symlinked || { echo "O16 fixture failed" >&2; exit 1; }
  SYM_ROOT="$ARMED_ROOT"; SYM_DATA="$ARMED_DATA"
  mv "$SYM_ROOT" "${SYM_ROOT}.real" && ln -s "${SYM_ROOT}.real" "$SYM_ROOT" \
    || { echo "O16 fixture: symlink swap failed" >&2; exit 1; }
  if ! orphaned orphan-symlinked "$SYM_DATA"; then
    check "O16 a root replaced by a symlink to it is NOT the orphaned state" PASS
  else
    check "O16 symlinked root relaxed" FAIL
  fi
  arm orphan-dangling || { echo "O17 fixture failed" >&2; exit 1; }
  DANGLING_ROOT="$ARMED_ROOT"; DANGLING_DATA="$ARMED_DATA"
  rm -rf "$DANGLING_ROOT"
  ln -s "$STATE_DIR/no-such-target" "$DANGLING_ROOT" \
    || { echo "O17 fixture: dangling symlink failed" >&2; exit 1; }
  if ! orphaned orphan-dangling "$DANGLING_DATA"; then
    check "O17 a DANGLING symlink at the recorded path is NOT the orphaned state" PASS
  else
    check "O17 dangling symlink relaxed" FAIL
  fi
fi

if ! orphaned a-session-that-was-never-registered "$GONE_DATA" \
  && unregistered a-session-that-was-never-registered "$GONE_DATA"; then
  check "O18 a missing record still routes to the unregistered predicate, not this one" PASS
else
  check "O18 missing record routing" FAIL
fi
if orphaned orphan-gone "$GONE_DATA" \
  && ! printf '{"hook_event_name":"Stop","session_id":"orphan-gone"}' \
    | env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      node "$BINDER" orphaned-project-root >/dev/null 2>&1; then
  check "O19 an unset CLAUDE_PLUGIN_DATA is not the orphaned state either" PASS
else
  check "O19 unset plugin data" FAIL
fi
if ! printf '{"hook_event_name":"Stop","session_id":"orphan-gone"}' \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$GONE_DATA" \
    node "$BINDER" orphaned-project-root extra-arg >/dev/null 2>&1; then
  check "O1A the CLI mode rejects extra arguments" PASS
else
  check "O1A extra arguments accepted" FAIL
fi

# --- O2 the Bash gate lets the diagnostic through ---------------------------
# This is the whole point of the relaxation: /zensu:doctor runs through Bash, so
# without it the one command that names the cause was denied by the cause.
bash_gate() {
  local command="$1" data="$2" project="$3"
  CMD="$command" node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"PreToolUse", tool_name:"Bash",
    tool_input:{command:process.env.CMD}, session_id:"orphan-gone"
  }))' \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$data" \
      CLAUDE_PROJECT_DIR="$project" ZENSU_CONFIG="$STATE_DIR/no-such-config.json" \
      bash "$BASH_GATE" 2>/dev/null | decision
}
GATE_PROJECT="$PROJECTS/gate-anchor"
mkdir -p "$GATE_PROJECT"
GATE_PROJECT="$(cd "$GATE_PROJECT" && pwd -P)"
if [ "$(bash_gate "bash $PLUGIN_DIR/hooks/lib/zensu-doctor.sh" "$GONE_DATA" "$GATE_PROJECT")" = "allow" ]; then
  check "O21 the orphaned session may still run the read-only diagnostic" PASS
else
  check "O21 doctor denied in the orphaned state" FAIL
fi
if [ "$(bash_gate "git status" "$GONE_DATA" "$GATE_PROJECT")" = "allow" ]; then
  check "O22 an ordinary read-only command is not collateral damage" PASS
else
  check "O22 read-only command denied" FAIL
fi
# Relaxing the BINDING must not relax the write RULES the gate exists for.
if [ "$(bash_gate "printf x > $GATE_PROJECT/../escaped.ts" "$GONE_DATA" "$GATE_PROJECT")" = "deny" ]; then
  check "O23 the source-write rules still apply — a write outside the project is denied" PASS
else
  check "O23 write rules lost in the orphaned state" FAIL
fi
# The relaxation must be bound to the state, not granted to any unbound session.
arm orphan-still-there || { echo "O24 fixture failed" >&2; exit 1; }
STILL_DATA="$ARMED_DATA"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const record = JSON.parse(fs.readFileSync(file, "utf8"));
  record.runtime_digest = "sha256:" + "1".repeat(64);
  record.source_revision = record.runtime_digest;
  fs.writeFileSync(file, JSON.stringify(record));
' "$ARMED_RECORD" || { echo "O24 fixture: could not tamper the record" >&2; exit 1; }
DENY_OUT="$(CMD="git status" node -e 'process.stdout.write(JSON.stringify({
  hook_event_name:"PreToolUse", tool_name:"Bash",
  tool_input:{command:process.env.CMD}, session_id:"orphan-still-there"
}))' \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$STILL_DATA" \
    CLAUDE_PROJECT_DIR="$GATE_PROJECT" ZENSU_CONFIG="$STATE_DIR/no-such-config.json" \
    bash "$BASH_GATE" 2>/dev/null | decision)"
if [ "$DENY_OUT" = "deny" ]; then
  check "O24 a record that disagrees for any OTHER reason is still denied every Bash call" PASS
else
  check "O24 relaxation leaked to a disagreeing record (out=$DENY_OUT)" FAIL
fi

# --- O3 mutating tools stay denied ------------------------------------------
# The relaxation buys diagnosis, not work: nothing in this state can anchor an
# edit to a project, so Edit/Write must keep failing closed.
EDIT_OUT="$(node -e 'process.stdout.write(JSON.stringify({
  hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"orphan-gone",
  tool_input:{file_path:process.env.TARGET, old_string:"a", new_string:"b"}
}))' \
  | env TARGET="$GATE_PROJECT/some-source.ts" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$GONE_DATA" CLAUDE_PROJECT_DIR="$GATE_PROJECT" \
    ZENSU_CONFIG="$STATE_DIR/no-such-config.json" bash "$EDIT_GATE" 2>/dev/null | decision)"
if [ "$EDIT_OUT" = "deny" ]; then
  check "O31 Edit stays denied in the orphaned state — read-only relief only" PASS
else
  check "O31 Edit allowed in the orphaned state (out=$EDIT_OUT)" FAIL
fi

# --- O4 the doctor names this state instead of "no record" ------------------
DOCTOR_OUT="$(env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$GONE_DATA" \
  CLAUDE_CODE_SESSION_ID="orphan-gone" CLAUDE_PROJECT_DIR="$GATE_PROJECT" \
  ZENSU_CONFIG="$STATE_DIR/no-such-config.json" bash "$DOCTOR" 2>/dev/null)"
if printf '%s' "$DOCTOR_OUT" | grep -qF 'the project root recorded for this session no longer exists' \
  && printf '%s' "$DOCTOR_OUT" | grep -qF "$GONE_ROOT"; then
  check "O41 the doctor classifies the orphaned state and names the dead path" PASS
else
  check "O41 doctor orphaned line (out='$(printf '%s' "$DOCTOR_OUT" | grep -F 'binding:')')" FAIL
fi
if ! printf '%s' "$DOCTOR_OUT" | grep -qF 'has no valid Session Control record'; then
  check "O42 it no longer reports the record as missing when the record is right there" PASS
else
  check "O42 doctor still claims no record" FAIL
fi
if printf '%s' "$DOCTOR_OUT" | grep -qF 'Re-create exactly that directory' \
  || printf '%s' "$DOCTOR_OUT" | grep -qF 're-create exactly that directory'; then
  check "O43 the doctor line carries the actionable remedy" PASS
else
  check "O43 doctor remedy missing" FAIL
fi
# A session that is merely unbound for another reason must keep the old line.
UNBOUND_OUT="$(env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$GONE_DATA" \
  CLAUDE_CODE_SESSION_ID="a-session-that-was-never-registered" \
  CLAUDE_PROJECT_DIR="$GATE_PROJECT" ZENSU_CONFIG="$STATE_DIR/no-such-config.json" \
  bash "$DOCTOR" 2>/dev/null)"
if printf '%s' "$UNBOUND_OUT" | grep -qF 'has no valid Session Control record' \
  && ! printf '%s' "$UNBOUND_OUT" | grep -qF 'no longer exists'; then
  check "O44 an ordinarily unbound session keeps the generic binding line" PASS
else
  check "O44 unbound line drifted (out='$(printf '%s' "$UNBOUND_OUT" | grep -F 'binding:')')" FAIL
fi

echo "----"
echo "test-orphaned-project-root: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
