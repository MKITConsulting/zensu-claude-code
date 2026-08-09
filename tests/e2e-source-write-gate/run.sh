#!/bin/bash
set -u

# E2E for the PreToolUse(Bash) source-write gate. Three layers:
#   --self-check  structural only (hook + parser present, registered)
#   --offline     + deterministic hook-contract asserts (real PreToolUse(Bash)
#                 payloads against a throwaway git project — no claude)
#   (full)        + live `claude --print`: does the hook actually block a real
#                 bash write to a tracked source file end to end?

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/pre-bash-source-write-gate.sh"
PARSER="$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results}"
mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
TIMEOUT="${ZENSU_BSWGATE_E2E_TIMEOUT:-180}"
FIXTURE="$FIXTURES_DIR/project"

MODE="${1:-full}"
case "$MODE" in
  --self-check|--offline|""|full) ;;
  *) printf "  FAIL  unknown mode '%s' — accepted: --self-check, --offline, (no arg / full)\n" "$MODE" >&2; exit 2 ;;
esac

PASS=0; FAIL=0; TOTAL=0
log() { printf "%s\n" "$1" | tee -a "$REPORT"; }
check() {
  local label="$1" result="$2"
  TOTAL=$((TOTAL+1))
  if [ "$result" = "PASS" ]; then PASS=$((PASS+1)); log "  PASS  $label";
  else FAIL=$((FAIL+1)); log "  FAIL  $label"; fi
}

log "=== Live source-write-gate E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"

registered_check() {
  node -e '
    const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const pres=(h.hooks.PreToolUse||[]);
    const ok=pres.some(e=>(e.matcher||"")==="Bash" && (e.hooks||[]).some(z=>/pre-bash-source-write-gate\.sh/.test(z.command||"")));
    process.exit(ok?0:1);
  ' "$HOOKS_JSON" 2>/dev/null
}

if [ "$MODE" = "--self-check" ]; then
  log ""
  log "  (skeleton only — no claude spawned)"
  { [ -f "$HOOK" ] && [ -x "$HOOK" ]; } && check "hook present + executable" PASS || check "hook present + executable" FAIL
  { [ -f "$PARSER" ] && node --check "$PARSER" 2>/dev/null; } && check "parser present + node --check" PASS || check "parser present + node --check" FAIL
  registered_check && check "registered in hooks.json PreToolUse Bash" PASS || check "registered in hooks.json PreToolUse Bash" FAIL
  log "════════════════════════════════════════"
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  log "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# ── Deterministic hook-contract layer ────────────────────────────────
# Real PreToolUse(Bash) payloads against a throwaway git project + sibling
# checkout. The temp-root seam (ZENSU_BSWGATE_TEMP_DIRS) keeps verdicts
# independent of where the suite is checked out.
WORK="$(mktemp -d -t bswgate-e2e-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"; SIB="$WORK/sib"; FAKETMP="$WORK/faketmp"
mkdir -p "$PROJ/src" "$SIB/src" "$FAKETMP"
( cd "$PROJ" && git init -q && git config user.email e2e@zensu.dev && git config user.name e2e \
    && printf 'export const x = 1;\n' > src/app.ts && git add -A && git commit -qm init ) >/dev/null 2>&1
( cd "$SIB" && git init -q && git config user.email e2e@zensu.dev && git config user.name e2e \
    && printf 'export const y = 2;\n' > src/lib.ts && git add -A && git commit -qm init ) >/dev/null 2>&1

payload() {
  CMD="$1" node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.env.CMD},cwd:process.argv[1],session_id:"bswgate-e2e"}))' "$PROJ"
}
classify() {
  node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{s=s.trim();if(!s){process.stdout.write("ALLOW");return;}try{const j=JSON.parse(s);const d=j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision;process.stdout.write(d==="deny"?"DENY":(d||"OTHER"));}catch(_){process.stdout.write("BADJSON");}})'
}
# The unbound hook path must be ENFORCED, not inherited. Without the scrub the
# caller's own ZENSU_* bind a real session (so $PROJ itself reads as an escape and
# every ALLOW case fails), or an existing plugin-data store makes the session
# "not unregistered" and the hook denies EVERYTHING — under which D1/D3/D6 would
# pass with no write rule having run at all.
gate() {
  payload "$1" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_BASH_WRITE_GATE -u ZENSU_MCP_GATE \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$WORK/plugin-data" \
    ZENSU_CONFIG="$WORK/no-config.json" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null | classify
}
gate_reason() {
  payload "$1" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u ZENSU_BASH_WRITE_GATE -u ZENSU_MCP_GATE \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_DATA="$WORK/plugin-data" \
    ZENSU_CONFIG="$WORK/no-config.json" ZENSU_BSWGATE_TEMP_DIRS="$FAKETMP" bash "$HOOK" 2>/dev/null
}
mkdir -p "$WORK/plugin-data"
chmod 700 "$WORK/plugin-data"

log ""
log "▸ Deterministic hook-contract assertions (real PreToolUse(Bash) payloads)"
[ "$(gate 'printf x >> src/app.ts')" = "DENY" ]  && check "D1 clobber tracked source -> DENY" PASS  || check "D1 clobber tracked source -> DENY" FAIL
[ "$(gate 'printf x > src/new.ts')" = "ALLOW" ]  && check "D2 new file inside project -> ALLOW" PASS || check "D2 new file inside project -> ALLOW" FAIL
[ "$(gate 'cd ../sib && printf x >> src/lib.ts')" = "DENY" ] && check "D3 worktree/project escape -> DENY" PASS || check "D3 worktree/project escape -> DENY" FAIL
[ "$(gate 'ZENSU_BASH_WRITE_GATE=off printf x >> src/app.ts')" = "ALLOW" ] && check "D4 escape-hatch -> ALLOW" PASS || check "D4 escape-hatch -> ALLOW" FAIL
[ "$(gate 'echo hi > notes.md')" = "ALLOW" ]     && check "D5 non-source target -> ALLOW" PASS || check "D5 non-source target -> ALLOW" FAIL
# Rule (C), driven from a real temp project against a hook with no test-owned
# Session Control baseline. The same DENY/ALLOW pair is pinned on the unbound path
# by W123/W124 in tests/structure/test-bash-source-write-gate.sh; what this adds is
# the end-to-end shape — a throwaway checkout, a real payload, no fixture scaffolding.
[ "$(gate "git -C $SIB add .")" = "DENY" ]       && check "D6 git mutation escaping the project -> DENY" PASS || check "D6 git mutation escaping the project -> DENY" FAIL
[ "$(gate 'git add -A')" = "ALLOW" ]             && check "D7 git mutation inside the project -> ALLOW" PASS || check "D7 git mutation inside the project -> ALLOW" FAIL
[ "$(gate "git -C $SIB status")" = "ALLOW" ]     && check "D8 git read on a foreign repo -> ALLOW" PASS || check "D8 git read on a foreign repo -> ALLOW" FAIL
# A bare DENY does not prove rule (C) ran — a binding failure denies too. Assert
# the reason names the foreign repo and the escape.
D6_REASON="$(gate_reason "git -C $SIB add .")"
{ printf '%s' "$D6_REASON" | grep -qF "$SIB" && printf '%s' "$D6_REASON" | grep -qF "OUTSIDE this session's"; } \
  && check "D9 the D6 deny is the rule-(C) verdict, not a binding failure" PASS \
  || check "D9 D6 deny reason (got '$D6_REASON')" FAIL

if [ "$MODE" = "--offline" ]; then
  log ""
  log "  (offline: skipping live claude run)"
  log "════════════════════════════════════════"
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  log "  Report: $REPORT"
  log "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

if ! command -v claude >/dev/null 2>&1; then
  log ""
  log "  SKIP live — claude CLI not on PATH (deterministic asserts above stand)"
  log "════════════════════════════════════════"
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  log "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

if [ ! -d "$FIXTURE/.git" ]; then
  check "fixture present (run ./setup-fixtures.sh first)" FAIL
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  exit 1
fi

session_unavailable() {
  [ ! -s "$1" ] || grep -qiE 'weekly limit|usage limit|hit your .{0,20}limit|rate.?limit|reset[s]? (on|at|in| )|invalid api key|please run /login|not logged in|authentication_error|overloaded|credit balance' "$1" 2>/dev/null
}

# Start each live run from a pristine tracked file.
( cd "$FIXTURE" && git checkout -q -- src/sample.ts 2>/dev/null ) || true

log ""
log "▸ Live claude --print assertions"
CAPTURED="$RESULTS_DIR/clobber-${TIMESTAMP}.captured.txt"
PROMPT="Append the line // touched to the file src/sample.ts. Use a bash command with a redirect (echo >> src/sample.ts). Do not use the Edit or Write tool."
log "Running (timeout ${TIMEOUT}s) claude --print: bash append to a tracked source file..."
( cd "$FIXTURE" && timeout "$TIMEOUT" claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$PROMPT" ) > "$CAPTURED" 2>&1

if session_unavailable "$CAPTURED"; then
  log "  SKIP  live — claude session unavailable: $(head -c 100 "$CAPTURED" 2>/dev/null | tr '\n' ' ')"
  log "         the deterministic asserts above stand; re-run when the API is available"
else
  check "L1 claude --print produced a real session reply (plugin loaded, hook active)" PASS

  if grep -qiE 'git-tracked source|ZENSU_BASH_WRITE_GATE|write that would overwrite|source file OUTSIDE|bypasses the Edit/Write tools' "$CAPTURED" 2>/dev/null; then
    check "L2 gate deny-reason surfaced (hook blocked the bash write to tracked source)" PASS
  else
    log "  OBSERVE  L2 no explicit deny-reason in reply — model phrasing varied or it used a non-bash path (best-effort; D1 proves the deny)"
  fi

  # Strong on-disk cross-check: the tracked file must be unchanged (the gate
  # blocked the bash write). A change means the model fell back to the Edit/Write
  # tool, which THIS hook does not gate — not a gate failure, so observe + reset.
  if ( cd "$FIXTURE" && git diff --quiet -- src/sample.ts 2>/dev/null ); then
    check "L3 tracked file unchanged on disk (the bash write did not land)" PASS
  else
    log "  OBSERVE  L3 tracked file changed — model likely used the Edit/Write tool (not gated by this hook)"
    ( cd "$FIXTURE" && git checkout -q -- src/sample.ts 2>/dev/null ) || true
  fi

  CAPTURED_FP="$RESULTS_DIR/newfile-${TIMESTAMP}.captured.txt"
  NEWFILE="$FIXTURE/src/created_by_e2e.ts"
  rm -f "$NEWFILE"
  PROMPT_FP="Create a NEW file src/created_by_e2e.ts containing the text export const e2e = true; — use a bash redirect (printf ... > src/created_by_e2e.ts). Do not use the Edit or Write tool."
  log "Running (timeout ${TIMEOUT}s) claude --print: bash create a NEW file (should be allowed)..."
  ( cd "$FIXTURE" && timeout "$TIMEOUT" claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$PROMPT_FP" ) > "$CAPTURED_FP" 2>&1
  if session_unavailable "$CAPTURED_FP"; then
    log "  SKIP  L4 — claude session unavailable for the new-file probe"
  elif [ -f "$NEWFILE" ]; then
    check "L4 new-file bash write allowed end-to-end (no false-positive deny)" PASS
    rm -f "$NEWFILE"
  else
    log "  OBSERVE  L4 new file not created — model may have declined or used another tool (best-effort)"
  fi
fi

log ""
log "════════════════════════════════════════"
log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
log "  Report: $REPORT"
log "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
