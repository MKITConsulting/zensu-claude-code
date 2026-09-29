#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
UNIT="$PLUGIN_DIR/tests/structure/session-reanchor-v1.test.js"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
REANCHOR="$PLUGIN_DIR/hooks/lib/zensu-session-reanchor.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
RECOGNIZER="$PLUGIN_DIR/hooks/lib/zensu-doctor-invocation.js"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
expect_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then check "$label" PASS;
  else check "$label" FAIL; echo "        want: $want"; echo "        got : $got"; fi
}
contains() { case "$1" in (*"$2"*) return 0 ;; (*) return 1 ;; esac; }

echo "=== E0: unit layer ==="
UNIT_OUT="$(node --test --test-reporter=tap "$UNIT" 2>&1)"
UNIT_PASS="$(printf '%s\n' "$UNIT_OUT" | grep -E '^# pass ' | grep -oE '[0-9]+' | tail -1)"
UNIT_FAIL="$(printf '%s\n' "$UNIT_OUT" | grep -E '^# fail ' | grep -oE '[0-9]+' | tail -1)"
UNIT_SKIPPED="$(printf '%s\n' "$UNIT_OUT" | grep -E '^# skipped ' | grep -oE '[0-9]+' | tail -1)"
UNIT_FLOOR=67
UNIT_MAX_SKIPPED=0
if [ "${UNIT_FAIL:-1}" = "0" ] && [ "${UNIT_SKIPPED:-1}" -le "$UNIT_MAX_SKIPPED" ] && [ "${UNIT_PASS:-0}" -ge "$UNIT_FLOOR" ]; then
  check "E0a session-reanchor-v1.test.js green with at least $UNIT_FLOOR cases (pass=$UNIT_PASS)" PASS
else
  check "E0a session-reanchor-v1.test.js (pass=${UNIT_PASS:-?} fail=${UNIT_FAIL:-?} skipped=${UNIT_SKIPPED:-?}, floor $UNIT_FLOOR)" FAIL
  printf '%s\n' "$UNIT_OUT" | grep -E '^not ok|# SKIP' | head -5
fi

unset CLAUDE_AGENT_TYPE ZENSU_CHAIN ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE ZENSU_SESSION_KEY ZENSU_PROJECT_ROOT \
  ZENSU_SESSION_CONTEXT ZENSU_RUNTIME_DIGEST ZENSU_CLAUDE_PLUGIN_ROOT CLAUDE_CODE_SESSION_ID \
  ZENSU_SOURCE_REVISION ZENSU_SOURCE_REVISION_AUTHORITY CLAUDE_CONFIG_DIR 2>/dev/null || true
STATE_DIR="$(cd "$(mktemp -d)" && pwd -P)"
SLEEPER_JOB=""
cleanup() {
  [ -n "$SLEEPER_JOB" ] && kill "$SLEEPER_JOB" 2>/dev/null
  chmod -R u+w "$STATE_DIR" 2>/dev/null; rm -rf "$STATE_DIR"
}
trap cleanup EXIT
node -e 'require("fs").writeFileSync(process.argv[1], String(process.pid)); setInterval(() => {}, 1000); setTimeout(() => process.exit(0), 10800000);' "$STATE_DIR/live.pid" &
SLEEPER_JOB=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$STATE_DIR/live.pid" ] && break; sleep 0.25; done
LIVE_PID="$(cat "$STATE_DIR/live.pid" 2>/dev/null)"
export ZENSU_CONFIG="$STATE_DIR/no-config.json"
GATE_ON_CONFIG="$STATE_DIR/gate-on-config.json"
printf '%s' '{"hooks":{"bashWriteGate":true}}' > "$GATE_ON_CONFIG"

REPO="$STATE_DIR/repo"
OTHER="$STATE_DIR/other"
PLAIN="$STATE_DIR/plain"
DATA="$STATE_DIR/plugin-data"
CONFIG="$STATE_DIR/config"
EMPTY_CONFIG="$STATE_DIR/empty-config"
mkdir -p "$REPO" "$OTHER" "$PLAIN" "$DATA" "$CONFIG/sessions" "$EMPTY_CONFIG/sessions"
chmod 700 "$DATA"
g() { git -c user.email=e2e@example.invalid -c user.name=e2e -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
g -C "$REPO" init -q
printf '.claude/\n.zensu/\n' > "$REPO/.gitignore"
printf 'seed\n' > "$REPO/README.md"
g -C "$REPO" add .gitignore README.md
g -C "$REPO" commit -q -m seed
A="$REPO/.claude/worktrees/haptic-feedback-design-0c47fc"
B="$REPO/.claude/worktrees/logging-followups"
C="$REPO/.claude/worktrees/claimed-elsewhere"
D="$REPO/.claude/worktrees/idle-anchor"
g -C "$REPO" worktree add -q -b claude/haptic "$A"
g -C "$REPO" worktree add -q -b claude/logging-followups "$B"
g -C "$REPO" worktree add -q -b claude/claimed "$C"
g -C "$REPO" worktree add -q -b claude/idle "$D"
mkdir -p "$B/Sources"
printf 'change\n' > "$B/Sources/logging.swift"
g -C "$OTHER" init -q
g -C "$OTHER" commit -q --allow-empty -m seed

SID="8aac5644-a7db-4cd4-a76e-2c47c46ee59e"
start_payload() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",source:"startup",session_id:process.argv[1],cwd:process.argv[2]}))' "$1" "$2"
}
start_payload "$SID" "$A" | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$DATA" \
  bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null 2>&1
start_payload "$SID" "$A" | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$DATA" \
  bash "$PLUGIN_DIR/hooks/session-start-worktree-keep.sh" >/dev/null 2>&1
KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' "$CORE" "$SID")"
RECORD="$DATA/session-control/v1/records/$KEY.json"
record_root() { node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).project_root)' "$RECORD" 2>/dev/null; }
expect_eq "E0b the record is anchored at the worktree the session started in" "$A" "$(record_root)"
[ -f "$A/.zensu/state/worktree-anchor-$KEY.json" ] \
  && check "E0c the worktree-keep anchor of the start worktree exists" PASS \
  || check "E0c the worktree-keep anchor of the start worktree exists" FAIL
[ -n "$LIVE_PID" ] && check "E0d a live native process stands in for the host session" PASS \
  || check "E0d a live native process stands in for the host session" FAIL
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}' "$LIVE_PID" "$SID" "$B" > "$CONFIG/sessions/$LIVE_PID.json"

run_hook() {
  printf '%s' "$2" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PROJECT_DIR="$A" \
    ZENSU_BSWGATE_TEMP_DIRS="$STATE_DIR/no-temp" bash "$PLUGIN_DIR/hooks/$1" 2>/dev/null
}
decision() {
  node -e 'let r="";process.stdin.on("data",(c)=>{r+=c;}).on("end",()=>{const t=r.trim();if(!t){process.stdout.write("ALLOW");return;}
    try{const o=JSON.parse(t.split("\n").pop()).hookSpecificOutput||{};process.stdout.write(String(o.permissionDecision).toUpperCase()+": "+String(o.permissionDecisionReason));}
    catch(e){process.stdout.write("UNPARSEABLE");}});'
}
bash_payload() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],cwd:process.argv[2],tool_name:"Bash",tool_input:{command:process.argv[3]}}))' "$SID" "$1" "$2"
}
read_payload() {
  node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",session_id:process.argv[1],cwd:process.argv[2],agent_id:"e2e-aspect",agent_type:"zensu:review-aspect",tool_name:"Read",tool_input:{file_path:process.argv[3]}}))' "$SID" "$1" "$2"
}
git_add_in() { ZENSU_CONFIG="$GATE_ON_CONFIG" run_hook pre-bash-source-write-gate.sh "$(bash_payload "$1" "git add $2")" | decision; }
reviewer_read() { run_hook pre-reviewer-capability-gate.sh "$(read_payload "$1" "$2")" | decision; }
RA_OUT=""; RA_RC=0; RA_ZENSU_CONFIG=""
reanchor_from() {
  local dir="$1" config="$2"
  shift 2
  RA_OUT="$(cd "$dir" && env CLAUDE_CONFIG_DIR="$config" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PLUGIN_DATA="$DATA" \
    ZENSU_CONFIG="${RA_ZENSU_CONFIG:-$ZENSU_CONFIG}" bash "$REANCHOR" "$@" 2>&1)"
  RA_RC=$?
}
autopilot_call() {
  env -u ZENSU_PROJECT_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$A" \
    bash -c 'source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-autopilot-state.sh" && "$@"' zensu-e2e "$@" >/dev/null 2>&1
}
row_is() { printf '%s\n' "$RA_OUT" | grep -Fxq "  $(printf '%-17s' "$1"): $2"; }
refusal_is() {
  local label="$1" token="$2"
  if [ "$RA_RC" -eq 1 ] && contains "$RA_OUT" "NOT MOVABLE ($token)" && contains "$RA_OUT" "Nothing was changed."; then
    check "$label" PASS
  else
    check "$label (rc=$RA_RC)" FAIL
    printf '%s\n' "$RA_OUT" | head -4 | sed 's/^/        /'
  fi
}

echo "=== E1: the reproduced state ==="
E1="$(git_add_in "$B/Sources" logging.swift)"
case "$E1" in
  (DENY:*) check "E1a git add in the sibling worktree is denied while the record names the start worktree" PASS ;;
  (*) check "E1a git add in the sibling worktree (got '$E1')" FAIL ;;
esac
contains "$E1" "/zensu:adopt-session --reanchor" \
  && check "E1b the deny names the re-anchor route" PASS \
  || check "E1b the deny names the re-anchor route (got '$E1')" FAIL
contains "$E1" "$A" \
  && check "E1c the deny names no worktree other than the command's own target (got '$E1')" FAIL \
  || check "E1c the deny names no worktree other than the command's own target" PASS
E1D="$(reviewer_read "$B" "$B/Sources/logging.swift")"
case "$E1D" in
  (DENY:*) check "E1d a review-aspect reviewer cannot read the sibling worktree yet" PASS ;;
  (*) check "E1d reviewer read of the sibling worktree (got '$E1D')" FAIL ;;
esac
E1E="$(ZENSU_CONFIG="$GATE_ON_CONFIG" run_hook pre-bash-source-write-gate.sh"$(bash_payload "$B" "CLAUDE_PLUGIN_DATA=\"$DATA\" bash \"$REANCHOR\" --confirm")" | decision)"
expect_eq "E1e the bound session's Bash gate admits the re-anchor command itself" "ALLOW" "$E1E"

echo "=== E2: the read-only report ==="
BEFORE="$STATE_DIR/record.before"
cp -p "$RECORD" "$BEFORE"
reanchor_from "$B/Sources" "$CONFIG"
if [ "$RA_RC" -eq 0 ] && contains "$RA_OUT" "re-anchor — MOVABLE" && row_is "recorded root" "$A" && row_is "new anchor" "$B"; then
  check "E2a the report from inside the sibling worktree names both roots and exits 0" PASS
else
  check "E2a report (rc=$RA_RC)" FAIL
  printf '%s\n' "$RA_OUT" | head -6 | sed 's/^/        /'
fi
cmp -s "$RECORD" "$BEFORE" && check "E2b the report leaves the record byte-identical" PASS || check "E2b the report changed the record" FAIL
[ ! -e "$B/.zensu" ] && check "E2c the report creates nothing under the target worktree" PASS || check "E2c the report created $B/.zensu" FAIL

echo "=== E3: refusals leave the record alone ==="
reanchor_from "$A" "$CONFIG" --confirm
refusal_is "E3a the start worktree itself refuses as already-anchored" "already-anchored"
reanchor_from "$OTHER" "$CONFIG" --confirm
refusal_is "E3b a worktree of another repository refuses" "different-repository"
reanchor_from "$PLAIN" "$CONFIG" --confirm
refusal_is "E3c a directory outside any worktree refuses" "target-not-in-a-worktree"
printf '{"pid":%s,"sessionId":"%s","cwd":"%s"}' "$LIVE_PID" "foreign-e2e-session" "$C/src" > "$CONFIG/sessions/900001.json"
reanchor_from "$C" "$CONFIG" --confirm
refusal_is "E3d a worktree another live session works in refuses" "claimed-by-live-session"
reanchor_from "$B" "$EMPTY_CONFIG" --confirm
refusal_is "E3e a registry that does not list this session fails closed" "live-sessions-unverifiable"
set_active() {
  CORE="$CORE" ROOT="$A" SID="$SID" V="$1" node -e '
    const core = require(process.env.CORE);
    core.mutateWorkflowState({ projectRoot: process.env.ROOT, sessionId: process.env.SID, workflowState: "e2e", event: "e2e" },
      (s) => { s.active = process.env.V === "1"; s.chainDone = false; return s; });
  ' 2>/dev/null
}
set_active 1
reanchor_from "$B" "$CONFIG" --confirm
refusal_is "E3f an armed chain under the start worktree refuses" "workflow-in-progress"
set_active 0
if autopilot_call autopilot_begin_run e2e-open-run "$KEY" "$A"; then
  reanchor_from "$B" "$CONFIG" --confirm
  refusal_is "E3i an Autopilot run this session owns refuses although no chain links it" "workflow-in-progress"
  contains "$RA_OUT" "an Autopilot run this session owns (e2e-open-run, stage PLANNING)" \
    && check "E3j the refusal names the run and its stage" PASS \
    || check "E3j the refusal names the run and its stage" FAIL
  autopilot_call autopilot_apply_event e2e-open-run e2e-cancel CANCEL '{}' "$A" \
    && check "E3k the fixture run is cancelled" PASS || check "E3k the fixture run is cancelled" FAIL
  reanchor_from "$B" "$CONFIG"
  if [ "$RA_RC" -eq 0 ] && contains "$RA_OUT" "re-anchor — MOVABLE"; then
    check "E3l a cancelled run no longer blocks the move" PASS
  else
    check "E3l a cancelled run no longer blocks the move (rc=$RA_RC)" FAIL
    printf '%s\n' "$RA_OUT" | head -4 | sed 's/^/        /'
  fi
else
  check "E3i the fixture Autopilot run could not be started" FAIL
fi
reanchor_from "$REPO" "$CONFIG" --confirm
refusal_is "E3m the checkout that contains the start worktree refuses" "target-contains-recorded-root"
WK="$PLUGIN_DIR/hooks/lib/worktree-keep-v1.js" CORE="$CORE" ROOT="$D" node -e '
  const wk = require(process.env.WK);
  const key = require(process.env.CORE).sessionKey("foreign-idle-e2e");
  const at = Date.now() - 2 * 3600 * 1000;
  const r = wk.writeAnchor(process.env.ROOT, key, { schemaVersion: 1, sessionKey: key, worktreeRoot: process.env.ROOT,
    branch: null, head: null, recordedAt: at, lastSeenAt: at, drift: null, endedAt: null });
  process.exit(r.ok ? 0 : 1);
' 2>/dev/null || check "E3n the fixture anchor could not be written" FAIL
reanchor_from "$D" "$CONFIG"
refusal_is "E3n a two-hour-old foreign keep anchor claims its worktree under the default idle window" "claimed-by-live-session"
printf '{"hooks":{"worktreeKeepIdleHours":1}}' > "$STATE_DIR/idle-1h.json"
RA_ZENSU_CONFIG="$STATE_DIR/idle-1h.json"
reanchor_from "$D" "$CONFIG"
RA_ZENSU_CONFIG=""
if [ "$RA_RC" -eq 0 ] && contains "$RA_OUT" "re-anchor — MOVABLE"; then
  check "E3o a configured one-hour idle window reaches the verdict and releases that claim" PASS
else
  check "E3o configured idle window (rc=$RA_RC)" FAIL
  printf '%s\n' "$RA_OUT" | head -4 | sed 's/^/        /'
fi
cmp -s "$RECORD" "$BEFORE" && check "E3g every refusal left the record byte-identical" PASS || check "E3g a refusal changed the record" FAIL
ls "$DATA/session-control/v1/records" | grep -q 'superseded' \
  && check "E3h no refusal set a record aside" FAIL \
  || check "E3h no refusal set a record aside" PASS

echo "=== E4: argv ==="
reanchor_from "$B" "$CONFIG" --confirm --confirm
expect_eq "E4a a repeated --confirm exits 2" "2" "$RA_RC"
reanchor_from "$B" "$CONFIG" "$A"
expect_eq "E4b a path argument is refused" "2" "$RA_RC"
reanchor_from "$B" "$CONFIG" --restore-root
expect_eq "E4c a foreign mode literal is refused" "2" "$RA_RC"
cmp -s "$RECORD" "$BEFORE" && check "E4d argv refusals left the record byte-identical" PASS || check "E4d an argv refusal changed the record" FAIL

echo "=== E5: the move ==="
reanchor_from "$B/Sources" "$CONFIG" --confirm
if [ "$RA_RC" -eq 0 ] && contains "$RA_OUT" "re-anchor — MOVED"; then
  check "E5a --confirm from inside the sibling worktree moves the anchor" PASS
else
  check "E5a move (rc=$RA_RC)" FAIL
  printf '%s\n' "$RA_OUT" | head -12 | sed 's/^/        /'
fi
expect_eq "E5b the record now names the sibling worktree" "$B" "$(record_root)"
SUPERSEDED="$(ls "$DATA/session-control/v1/records" | grep "^$KEY\.superseded-reanchor-" | head -1)"
if [ -n "$SUPERSEDED" ] && cmp -s "$DATA/session-control/v1/records/$SUPERSEDED" "$BEFORE"; then
  check "E5c the previous record is set aside byte-identical" PASS
else
  check "E5c the previous record is set aside byte-identical (found '$SUPERSEDED')" FAIL
fi
FIELDS="$(node -e '
  const fs = require("fs");
  const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const b = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const moved = Object.keys({ ...a, ...b }).filter((k) => JSON.stringify(a[k]) !== JSON.stringify(b[k]));
  process.stdout.write(moved.join(","));
' "$BEFORE" "$RECORD" 2>&1)"
expect_eq "E5d project_root is the only record field that changed" "project_root" "$FIELDS"
history_count() {
  CORE="$CORE" ROOT="$1" SID="$SID" node -e '
    const core = require(process.env.CORE);
    const s = core.readWorkflowState({ projectRoot: process.env.ROOT, sessionId: process.env.SID });
    process.stdout.write(String((s.history || []).filter((h) => h && h.phase === "PROJECT_ROOT_REANCHORED").length));
  ' 2>/dev/null
}
expect_eq "E5e one PROJECT_ROOT_REANCHORED entry under the new root" "1" "$(history_count "$B")"
expect_eq "E5f one PROJECT_ROOT_REANCHORED entry under the previous root" "1" "$(history_count "$A")"
KEEP_STATE="$(node -e '
  const fs = require("fs");
  const read = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { return null; } };
  const old = read(process.argv[1]); const now = read(process.argv[2]);
  process.stdout.write([old && typeof old.endedAt === "number" ? "aged" : "not-aged",
    now && now.endedAt === null ? "live" : "not-live"].join(" "));
' "$A/.zensu/state/worktree-anchor-$KEY.json" "$B/.zensu/state/worktree-anchor-$KEY.json" 2>&1)"
expect_eq "E5g the keep anchor is aged in the previous worktree and live in the new one" "aged live" "$KEEP_STATE"
[ -f "$B/.worktree-keep" ] && check "E5h the new worktree carries the keep marker" PASS || check "E5h the new worktree carries the keep marker" FAIL

echo "=== E6: gates and reviewers follow the new anchor ==="
expect_eq "E6a git add in the new anchor is allowed" "ALLOW" "$(git_add_in "$B/Sources" logging.swift)"
E6B="$(git_add_in "$A" README.md)"
case "$E6B" in
  (DENY:*) check "E6b git add in the previous worktree is denied now" PASS ;;
  (*) check "E6b git add in the previous worktree (got '$E6B')" FAIL ;;
esac
contains "$E6B" "$B" \
  && check "E6c that deny names no worktree other than the command's own target (got '$E6B')" FAIL \
  || check "E6c that deny names no worktree other than the command's own target" PASS
expect_eq "E6d a review-aspect reviewer reads the new anchor" "ALLOW" "$(reviewer_read "$B" "$B/Sources/logging.swift")"
E6E="$(reviewer_read "$A" "$A/README.md")"
case "$E6E" in
  (DENY:*) check "E6e a review-aspect reviewer cannot read the previous worktree" PASS ;;
  (*) check "E6e reviewer read of the previous worktree (got '$E6E')" FAIL ;;
esac
reanchor_from "$B" "$CONFIG" --confirm
refusal_is "E6f a second move to the same worktree refuses" "already-anchored"

echo "=== E7: the provenance phase is reserved ==="
PV_OUT=""; PV_RC=0
phase_verb() {
  PV_OUT="$(cd "$B" && env CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR="$B" \
    bash "$LOG" --phase "$@" 2>&1)"
  PV_RC=$?
}
phase_verb PROJECT_ROOT_REANCHORED --step x
if [ "$PV_RC" -eq 2 ] && contains "$PV_OUT" "PROJECT_ROOT_REANCHORED is written only by the session re-anchor"; then
  check "E7a --phase PROJECT_ROOT_REANCHORED is refused by its own guard" PASS
else check "E7a --phase PROJECT_ROOT_REANCHORED (rc=$PV_RC: $PV_OUT)" FAIL; fi
phase_verb project_root_reanchoreD --step x
if [ "$PV_RC" -eq 2 ] && contains "$PV_OUT" "is written only by the session re-anchor"; then
  check "E7b the refusal is case-insensitive" PASS
else check "E7b case-insensitive refusal (rc=$PV_RC: $PV_OUT)" FAIL; fi
phase_verb IMPL --step x --reason "project-root-reanchored: forged"
if [ "$PV_RC" -eq 2 ] && contains "$PV_OUT" "reserved for the session re-anchor"; then
  check "E7c a reserved reason prefix is refused by its own guard" PASS
else check "E7c reserved reason prefix (rc=$PV_RC: $PV_OUT)" FAIL; fi
phase_verb IMPL --step x --reason "Project-Root-Reanchored: forged"
if [ "$PV_RC" -eq 2 ] && contains "$PV_OUT" "reserved for the session re-anchor"; then
  check "E7c2 the reserved reason prefix is refused in any letter case" PASS
else check "E7c2 mixed-case reserved reason prefix (rc=$PV_RC: $PV_OUT)" FAIL; fi
phase_verb IMPL --step x --reason "ordinary"
if contains "$PV_OUT" "session re-anchor" || contains "$PV_OUT" "binding unavailable"; then
  check "E7c-control an ordinary phase reaches past both guards (got: $PV_OUT)" FAIL
else check "E7c-control an ordinary phase reaches past both guards" PASS; fi
LIB="$(PHASE_LIB="$PHASE_LIB" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash -c '
  source "$PHASE_LIB" >/dev/null 2>&1 || { printf "NO-SOURCE"; exit 0; }
  r() { if _tdd_reserved_provenance "$1" "$2"; then printf "R"; else printf "-"; fi; }
  r PROJECT_ROOT_REANCHORED ""; r Project_Root_Reanchored ""; r IMPL "project-root-reanchored: x"
  r IMPL "PROJECT-ROOT-Reanchored: x"; r IMPL ""
' 2>/dev/null)"
expect_eq "E7d the phase library reserves the phase and the prefix in any letter case and admits an ordinary phase" "RRRR-" "$LIB"

echo "=== E8: the bind-failure recognizer does not admit the re-anchor ==="
E8="$(ROOT="$PLUGIN_DIR" RECOG="$RECOGNIZER" node -e '
  const m = require(process.env.RECOG);
  const root = process.env.ROOT;
  const mk = (cmd) => ({ tool_name: "Bash", tool_input: { command: cmd } });
  const r = root + "/hooks/lib/zensu-session-reanchor.sh";
  const a = root + "/hooks/lib/zensu-session-adopt.sh";
  const refused = ["bash " + r, "bash " + r + " --confirm", "bash " + a + " --reanchor", "bash " + a + " --reanchor --confirm"]
    .filter((c) => m.isRecognizedInvocation(mk(c), root));
  const control = m.isRecognizedInvocation(mk("bash " + a + " --restore-root"), root);
  process.stdout.write((refused.length === 0 ? "refused" : "ADMITTED " + refused.join(" | ")) + " " + (control ? "control-admitted" : "control-refused"));
' 2>&1)"
E8_WANT="refused control-admitted"
[ "$(node -p 'process.platform' 2>/dev/null)" = "win32" ] && E8_WANT="refused control-refused"
expect_eq "E8a the recognizer refuses every re-anchor spelling and still admits the restore mode" "$E8_WANT" "$E8"

echo "=== E9: a second move, back to the start worktree, with worktree keep off ==="
printf '{"hooks":{"worktreeKeep":false}}' > "$STATE_DIR/keep-off.json"
anchors_digest() { cat "$A/.zensu/state/worktree-anchor-$KEY.json" "$B/.zensu/state/worktree-anchor-$KEY.json" 2>/dev/null | cksum; }
ANCHORS_BEFORE="$(anchors_digest)"
printf '{"mode":"strict"}\n' > "$B/.zensu/state/tdd-mode-$KEY.json"
RA_ZENSU_CONFIG="$STATE_DIR/keep-off.json"
reanchor_from "$A" "$CONFIG" --confirm
RA_ZENSU_CONFIG=""
if [ "$RA_RC" -eq 0 ] && contains "$RA_OUT" "re-anchor — MOVED"; then
  check "E9a the anchor moves back to the start worktree" PASS
else
  check "E9a move back (rc=$RA_RC)" FAIL
  printf '%s\n' "$RA_OUT" | head -12 | sed 's/^/        /'
fi
expect_eq "E9b the record names the start worktree again" "$A" "$(record_root)"
row_is "workflow document" "present" && check "E9c the intact workflow document under the start worktree is reused" PASS \
  || check "E9c the intact workflow document under the start worktree is reused" FAIL
row_is "worktree keep" "disabled" && check "E9d hooks.worktreeKeep false reaches the move as disabled" PASS \
  || check "E9d hooks.worktreeKeep false reaches the move as disabled" FAIL
expect_eq "E9e with worktree keep off neither keep anchor changed" "$ANCHORS_BEFORE" "$(anchors_digest)"
expect_eq "E9f one superseded record per move" "2" "$(ls "$DATA/session-control/v1/records" | grep -c "^$KEY\.superseded-reanchor-")"
expect_eq "E9g two PROJECT_ROOT_REANCHORED entries under each root" "2 2" "$(history_count "$A") $(history_count "$B")"
row_is "session markers" "moved (tdd-mode)" && check "E9h the report names the moved tdd-mode marker" PASS \
  || check "E9h the report names the moved tdd-mode marker" FAIL
MODE="$(CFG="$PLUGIN_DIR/hooks/lib/zensu-config.sh" bash -c 'source "$CFG" >/dev/null 2>&1 && zensu_tdd_mode_override "$1" "$2"' _ "$A" "$KEY" 2>/dev/null)"
if [ "$MODE" = "strict" ] && [ ! -e "$B/.zensu/state/tdd-mode-$KEY.json" ]; then
  check "E9i the session's /zensu:tdd-mode choice is read under the new anchor and left nowhere else" PASS
else
  check "E9i tdd-mode marker after the move (mode='$MODE')" FAIL
fi

echo "=== E10: a /zensu:tdd chain in the new anchor, driven from the start directory ==="
SKILL_TDD="$PLUGIN_DIR/skills/tdd/SKILL.md"
SKILL_SR="$PLUGIN_DIR/skills/self-review/SKILL.md"
SKILL_VF="$PLUGIN_DIR/skills/verify-feature/SKILL.md"
span_in() {
  node -e '
    let text = require("fs").readFileSync(process.argv[1], "utf8");
    if (process.argv[4] !== "") {
      const at = text.indexOf(process.argv[4]);
      text = at === -1 ? "" : text.slice(at);
    }
    const spans = (text.match(/`[^`\n]*`/g) || []).map((s) => s.slice(1, -1));
    const hit = spans.find((s) => s.includes(process.argv[2]) && (process.argv[3] === "" || s.endsWith(process.argv[3])));
    process.stdout.write(hit || "");
  ' "$1" "$2" "${3:-}" "${4:-}" 2>/dev/null
}
skill_span() { span_in "$SKILL_TDD" "$@"; }
spans_agree() {
  node -e '
    const text = require("fs").readFileSync(process.argv[1], "utf8");
    const spans = (text.match(/`[^`\n]*`/g) || []).map((s) => s.slice(1, -1))
      .filter((s) => s.includes(process.argv[2]) && s.endsWith(process.argv[3]));
    process.stdout.write(spans.length >= 2 && spans.every((s) => s === spans[0]) ? String(spans.length) : "0");
  ' "$SKILL_TDD" "$1" "$2" 2>/dev/null
}
E10_TS="2026-09-30-0000"
E10_SLUG="reanchor-e2e"
E10_LOG_DEF="$(skill_span '/.zensu/logs/{SESSION_TS}_tdd-{slug}.log')"
E10_PLAN_DEF="$(skill_span '/.zensu/plans/{SESSION_TS}_tdd-{slug}.md')"
E10_ROOT_CMD="$(skill_span 'zensu-log.sh" --project-root')"
E10_BASE_CMD="$(skill_span 'BASELINE_SHA=$(git -C')"
E10_BEGIN="$(skill_span 'hooks/lib/zensu-log.sh" --tdd-begin' '--tdd-begin')"
E10_RECIPE="$(skill_span 'append --truncate --log {log_file}')"
E10_AUDIT="$(skill_span 'zensu-edit-landing.sh" --log {log_file}')"
E10_COMPLETE="$(skill_span 'zensu-log.sh" --tdd-complete --plan {plan_file}' '{plan_file}' '10. **Close implementation')"
E10_COMPLETE_AGREE="$(spans_agree 'zensu-log.sh" --tdd-complete --plan {plan_file}' '{plan_file}')"
E10_CD="$(skill_span 'cd "{project_root}" && ' '<command>')"
E10_EVR="$(skill_span "--evidence-run --scope full --cmd '{full_test_cmd}' --log {log_file}")"
E10_SR_ROOT="$(span_in "$SKILL_SR" 'PROJECT_ROOT="$(CLAUDE_PLUGIN_DATA=' '--project-root)"')"
E10_SR_TOP="$(span_in "$SKILL_SR" 'TOP="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel)"')"
E10_VF_ROOT="$(span_in "$SKILL_VF" 'GIT_ROOT="$(git -C "$ANCHOR" rev-parse --show-toplevel)"')"
if [ -n "$E10_LOG_DEF" ] && [ -n "$E10_PLAN_DEF" ] && [ -n "$E10_ROOT_CMD" ] && [ -n "$E10_BASE_CMD" ] \
  && [ -n "$E10_BEGIN" ] && [ -n "$E10_RECIPE" ] && [ -n "$E10_AUDIT" ] && [ -n "$E10_COMPLETE" ] \
  && [ "${E10_COMPLETE_AGREE:-0}" -ge 2 ] && [ -n "$E10_CD" ] && [ -n "$E10_EVR" ] \
  && [ -n "$E10_SR_ROOT" ] && [ -n "$E10_SR_TOP" ] && [ -n "$E10_VF_ROOT" ]; then
  check "E10a every path and command the chain needs is extracted from the tdd, self-review and verify-feature skills" PASS
else
  check "E10a extraction (log='$E10_LOG_DEF' plan='$E10_PLAN_DEF' root='$E10_ROOT_CMD' base='$E10_BASE_CMD' begin='$E10_BEGIN' recipe='$E10_RECIPE' audit='$E10_AUDIT' complete='$E10_COMPLETE' agree='$E10_COMPLETE_AGREE' cd='$E10_CD' evr='$E10_EVR' sr-root='$E10_SR_ROOT' sr-top='$E10_SR_TOP' vf-root='$E10_VF_ROOT')" FAIL
fi
E10_ROOT=""
render() {
  local c="$1"
  c="${c//\{log_file\}/$E10_LOG_DEF}"
  c="${c//\{plan_file\}/$E10_PLAN_DEF}"
  c="${c//\{project_root\}/$E10_ROOT}"
  c="${c//\{SESSION_TS\}/$E10_TS}"
  c="${c//\{slug\}/$E10_SLUG}"
  c="${c//\{session_id\}/$SID}"
  c="${c//\{title\}/re-anchor end to end}"
  c="${c//\{N\}/1}"
  printf '%s' "$c"
}
unrendered() {
  case "$1" in
    (*'{log_file}'*|*'{plan_file}'*|*'{project_root}'*|*'{SESSION_TS}'*|*'{slug}'*|*'{session_id}'*|*'{title}'*|*'{N}'*|*'{full_test_cmd}'*|*'<command>'*) return 0 ;;
    (*) return 1 ;;
  esac
}
E10_OUT=""; E10_ERR=""; E10_RC=0; E10_BASE=""; E10_EPOCH="$(date +%s)"
from_start() {
  E10_OUT="$(cd "$A" && env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$DATA" BASELINE_SHA="$E10_BASE" SESSION_EPOCH="$E10_EPOCH" bash -c "$1" 2>"$STATE_DIR/e10.err")"
  E10_RC=$?
  E10_ERR="$(head -c 600 "$STATE_DIR/e10.err" 2>/dev/null)"
}
e10_fail() { check "$1 (rc=$E10_RC)" FAIL; printf '%s\n' "$E10_OUT" "$E10_ERR" | head -8 | sed 's/^/        /'; }
chain_state() {
  CORE="$CORE" ROOT="$1" SID="$SID" node -e '
    const core = require(process.env.CORE);
    const s = core.readWorkflowState({ projectRoot: process.env.ROOT, sessionId: process.env.SID });
    process.stdout.write(s && s.active === true ? "armed" : "idle");
  ' 2>/dev/null
}
state_digest() { { cat "$RECORD"; find "$A/.zensu/state" "$B/.zensu/state" -type f -exec cksum {} + | LC_ALL=C sort; } | cksum; }

printf '{"mode":"vanilla"}\n' > "$A/.zensu/state/tdd-mode-$KEY.json"
reanchor_from "$B" "$CONFIG" --confirm
if [ "$RA_RC" -eq 0 ] && contains "$RA_OUT" "re-anchor — MOVED" && [ "$(record_root)" = "$B" ]; then
  check "E10b a third move anchors the session in the sibling worktree again" PASS
else
  check "E10b third move (rc=$RA_RC)" FAIL
  printf '%s\n' "$RA_OUT" | head -12 | sed 's/^/        /'
fi
g -C "$B" commit -q --allow-empty -m b-only

DIGEST_BEFORE="$(state_digest)"
from_start "$E10_ROOT_CMD"
E10_ROOT="$E10_OUT"
if [ "$E10_RC" -eq 0 ] && [ "$E10_ROOT" = "$B" ] && [ "$(cd "$A" && pwd -P)" != "$B" ]; then
  check "E10c --project-root, run from the start directory with CLAUDE_PROJECT_DIR unset, prints the new anchor" PASS
else
  e10_fail "E10c --project-root from the start directory (printed '$E10_ROOT')"
fi
expect_eq "E10d --project-root writes nothing: the record and both state directories are unchanged" "$DIGEST_BEFORE" "$(state_digest)"
from_start "$E10_ROOT_CMD --session x"
if [ "$E10_RC" -eq 2 ] && [ -z "$E10_OUT" ] && contains "$E10_ERR" "takes no arguments"; then
  check "E10e --project-root refuses an extra argument with exit 2 and prints no root" PASS
else
  e10_fail "E10e --project-root with an extra argument"
fi
E10F_OUT="$(cd "$A" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SESSION_ID CLAUDE_PLUGIN_DATA="$DATA" bash "$LOG" --project-root 2>/dev/null)"
E10F_RC=$?
if [ "$E10F_RC" -ne 0 ] && [ -z "$E10F_OUT" ]; then
  check "E10f without a bindable session --project-root fails and prints no root" PASS
else
  check "E10f unbound --project-root (rc=$E10F_RC out='$E10F_OUT')" FAIL
fi

E10_BASE_RUN="$(render "$E10_BASE_CMD")"
from_start "$E10_BASE_RUN; printf '%s' \"\$BASELINE_SHA\""
E10_BASE="$E10_OUT"
B_HEAD="$(git -C "$B" rev-parse HEAD 2>/dev/null)"
A_HEAD="$(git -C "$A" rev-parse HEAD 2>/dev/null)"
if [ "$E10_RC" -eq 0 ] && ! unrendered "$E10_BASE_RUN" && [ -n "$E10_BASE" ] && [ "$E10_BASE" = "$B_HEAD" ] && [ "$E10_BASE" != "$A_HEAD" ]; then
  check "E10g the skill's baseline capture reads the new anchor's HEAD, not the start directory's" PASS
else
  e10_fail "E10g baseline capture (got '$E10_BASE', new anchor '$B_HEAD', start '$A_HEAD')"
fi

from_start "$E10_BEGIN"
if [ "$E10_RC" -eq 0 ] && contains "$E10_OUT" "mode: vanilla" \
  && [ "$(chain_state "$B") $(chain_state "$A")" = "armed idle" ]; then
  check "E10h --tdd-begin from the start directory arms the chain under the new anchor" PASS
else
  e10_fail "E10h --tdd-begin from the start directory"
fi

E10_LOG_PATH="$(render '{log_file}')"; E10_LOG_PATH="${E10_LOG_PATH#\"}"; E10_LOG_PATH="${E10_LOG_PATH%\"}"
E10_PLAN_PATH="$(render '{plan_file}')"; E10_PLAN_PATH="${E10_PLAN_PATH#\"}"; E10_PLAN_PATH="${E10_PLAN_PATH%\"}"
case "$E10_PLAN_PATH" in
  ("$B"/.zensu/plans/*)
    mkdir -p "$(dirname "$E10_PLAN_PATH")"
    printf '# TDD Plan: re-anchor end to end\n\n## Requirements\n| ID | Requirement | Source |\n|----|-------------|--------|\n| AC-001 | The chain completes in the new anchor | spec |\n' > "$E10_PLAN_PATH"
    ;;
  (*) check "E10 the rendered {plan_file} lies under the new anchor (got '$E10_PLAN_PATH')" FAIL ;;
esac
E10_RECIPE_RUN="$(render "$E10_RECIPE")"
from_start "$E10_RECIPE_RUN"
if [ "$E10_RC" -eq 0 ] && ! unrendered "$E10_RECIPE_RUN" && [ "$E10_LOG_PATH" = "$B/.zensu/logs/${E10_TS}_tdd-${E10_SLUG}.log" ] \
  && grep -qF 'TDD STARTED — re-anchor end to end' "$E10_LOG_PATH" 2>/dev/null \
  && [ ! -e "$A/.zensu/logs/${E10_TS}_tdd-${E10_SLUG}.log" ]; then
  check "E10i the Phase 2 log recipe creates the run log under the new anchor and nothing under the start directory" PASS
else
  e10_fail "E10i Phase 2 log recipe (log '$E10_LOG_PATH')"
fi

printf 'reanchored\n' >> "$B/README.md"
from_start "bash \"\$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-log.sh\" append --log $(render '{log_file}') --message 'S1 IMPL completed — files: README.md'"
E10_AUDIT_RUN="$(render "$E10_AUDIT")"
from_start "$E10_AUDIT_RUN"
if [ "$E10_RC" -eq 0 ] && ! unrendered "$E10_AUDIT_RUN" && contains "$E10_OUT" "EDIT LANDED" \
  && [ -f "$B/.zensu/state/edit-landing-$KEY.json" ] && [ ! -e "$A/.zensu/state/edit-landing-$KEY.json" ]; then
  check "E10j the skill-rendered edit-landing audit grades the claim in the new anchor and writes its receipt there" PASS
else
  e10_fail "E10j edit-landing audit from the start directory"
fi

E10_COMPLETE_RUN="$(render "$E10_COMPLETE")"
from_start "$E10_COMPLETE_RUN"
if [ "$E10_RC" -eq 0 ] && ! unrendered "$E10_COMPLETE_RUN"; then
  check "E10k --tdd-complete --plan {plan_file} from the start directory accepts the chain in the new anchor" PASS
else
  e10_fail "E10k --tdd-complete --plan from the start directory"
fi

E10_CD_RUN="$(render "$E10_CD")"; E10_CD_RUN="${E10_CD_RUN//<command>/pwd -P}"
from_start "$E10_CD_RUN"
if [ "$E10_RC" -eq 0 ] && ! unrendered "$E10_CD_RUN" && [ "$E10_OUT" = "$B" ]; then
  check "E10l the Phase 1 rule runs a project command from the start directory inside the new anchor" PASS
else
  e10_fail "E10l the Phase 1 cd rule (printed '$E10_OUT')"
fi

E10_EVR_RUN="$(render "$E10_EVR")"; E10_EVR_RUN="${E10_EVR_RUN//\{full_test_cmd\}/pwd -P}"
from_start "$E10_EVR_RUN"
if [ "$E10_RC" -eq 0 ] && ! unrendered "$E10_EVR_RUN" && printf '%s\n' "$E10_OUT" | grep -qxF "$B" \
  && ! printf '%s\n' "$E10_OUT" | grep -qxF "$(cd "$A" && pwd -P)" \
  && contains "$E10_ERR" "so the command runs in $B" \
  && grep -qF 'EVIDENCE RUN — scope=full exit=0' "$E10_LOG_PATH" 2>/dev/null; then
  check "E10m the Phase 6 step 1 evidence run from the start directory runs the suite in the new anchor" PASS
else
  e10_fail "E10m Phase 6 step 1 evidence run from the start directory"
fi

from_start "ROOT=\"\$CLAUDE_PLUGIN_ROOT\"; $E10_SR_ROOT; $E10_SR_TOP; printf '%s' \"\$TOP\""
if [ "$E10_RC" -eq 0 ] && [ "$E10_OUT" = "$B" ]; then
  check "E10n /zensu:self-review derives its TOP from the new anchor when run from the start directory" PASS
else
  e10_fail "E10n self-review root derivation (printed '$E10_OUT')"
fi

from_start "$E10_VF_ROOT; printf '%s' \"\$GIT_ROOT\""
if [ "$E10_RC" -eq 0 ] && [ "$E10_OUT" = "$B" ]; then
  check "E10o /zensu:verify-feature --chain resolves its git root in the new anchor when run from the start directory" PASS
else
  e10_fail "E10o verify-feature git root (printed '$E10_OUT')"
fi

bound_root_verb() {
  mkdir -p "$2"
  start_payload "$1" "$2" | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$DATA" \
    bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null 2>&1
  VERB_OUT="$(cd "$2" && env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$DATA" bash "$LOG" --project-root 2>"$STATE_DIR/unsafe.err")"
  VERB_RC=$?
}

reanchor_promise() {
  node -e '
    const m = require(process.argv[1]);
    const root = process.argv[2];
    const report = m.renderReanchorVerdict({ ok: true, recordedRoot: "/r", targetRoot: root, targetDocument: "missing", uncommitted: [] }, false).text;
    const outcome = m.renderReanchorOutcome({ ok: true, previousRoot: "/r", projectRoot: root, supersededFile: "/s", documentCreated: true, provenance: "recorded", previousProvenance: "recorded", leases: { discarded: 0, failed: [] }, keep: { state: "moved", faults: [] } }).text;
    const say = (text) => (/can start in this session/.test(text) ? "promise" : /cannot\s+run there/.test(text) ? "withheld" : "neither");
    process.stdout.write(`${say(report)} ${say(outcome)}`);
  ' "$PLUGIN_DIR/hooks/lib/session-reanchor-v1.js" "$1"
}

E10P_BAD=""
E10Q_BAD=""
E10P_N=0
for UNSAFE_NAME in 'root-with-"-in-it' 'root-with-$HOME-in-it' 'root-with-`-in-it' 'root-with-\-in-it'; do
  E10P_N=$((E10P_N + 1))
  bound_root_verb "c0ffee0$E10P_N-a7db-4cd4-a76e-2c47c46ee59e" "$STATE_DIR/$UNSAFE_NAME"
  if [ "$VERB_RC" -ne 2 ] || [ -n "$VERB_OUT" ] \
    || ! grep -qF 'contains a double quote, a dollar sign, a backtick or a backslash' "$STATE_DIR/unsafe.err"; then
    E10P_BAD="$E10P_BAD [$UNSAFE_NAME rc=$VERB_RC out='$VERB_OUT' err='$(head -1 "$STATE_DIR/unsafe.err")']"
  fi
  PROMISE="$(reanchor_promise "$STATE_DIR/$UNSAFE_NAME")"
  [ "$PROMISE" = "withheld withheld" ] || E10Q_BAD="$E10Q_BAD [$UNSAFE_NAME: $PROMISE]"
done
SAFE_ROOT="$STATE_DIR/root with 'quote' and space"
bound_root_verb "c0ffee05-a7db-4cd4-a76e-2c47c46ee59e" "$SAFE_ROOT"
if [ "$VERB_RC" -ne 0 ] || [ "$VERB_OUT" != "$SAFE_ROOT" ]; then
  E10P_BAD="$E10P_BAD [control rc=$VERB_RC out='$VERB_OUT' err='$(head -1 "$STATE_DIR/unsafe.err")']"
fi
PROMISE="$(reanchor_promise "$SAFE_ROOT")"
[ "$PROMISE" = "promise promise" ] || E10Q_BAD="$E10Q_BAD [control: $PROMISE]"
if [ -z "$E10P_BAD" ] && [ "$E10P_N" -eq 4 ]; then
  check "E10p --project-root refuses a bound root holding each of the four characters the shell re-parses in double quotes, and prints a root with a space and a single quote" PASS
else
  check "E10p --project-root refusal of the four characters and the control root:$E10P_BAD" FAIL
fi
if [ -z "$E10Q_BAD" ]; then
  check "E10q the re-anchor report and outcome withhold the chain promise for exactly the roots --project-root refuses" PASS
else
  check "E10q the re-anchor report and outcome withhold the chain promise for exactly the roots --project-root refuses:$E10Q_BAD" FAIL
fi

echo "session-reanchor: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
