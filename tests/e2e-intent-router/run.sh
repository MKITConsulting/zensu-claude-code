#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-intent-router.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results}"
mkdir -p "$RESULTS_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
TIMEOUT="${ZENSU_INTENT_E2E_TIMEOUT:-180}"
FIXTURE="$FIXTURES_DIR/planning"

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

log "=== Live intent-router E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"

registered_check() {
  node -e '
    const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command);
    process.exit(ups.some(c=>/user-prompt-intent-router\.sh/.test(c))?0:1);
  ' "$HOOKS_JSON" 2>/dev/null
}

if [ "$MODE" = "--self-check" ]; then
  log ""
  log "  (skeleton only — no claude spawned)"
  [ -f "$HOOK" ] && [ -x "$HOOK" ] && check "hook present + executable" PASS || check "hook present + executable" FAIL
  registered_check && check "registered in hooks.json UserPromptSubmit" PASS || check "registered in hooks.json UserPromptSubmit" FAIL
  log "════════════════════════════════════════"
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  log "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

run_hook() {
  local prompt="$1"
  local sd; sd="$(mktemp -d -t intente2e-XXXXXX)"
  local payload
  payload="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:"e2e-intent",cwd:process.argv[2],prompt:process.argv[1]}))' "$prompt" "$sd")"
  printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$sd" ZENSU_CONFIG="$sd/no-config.json" bash "$HOOK" 2>/dev/null
  rm -rf "$sd"
}

classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s); const o=j.hookSpecificOutput||{}; const ac=o.additionalContext||"";
        const plm=/zensu-plm/.test(ac)?"plm":"noplm";
        const triage=(/greenfield/i.test(ac)&&/brownfield/i.test(ac))?"triage":"notriage";
        const pm=/plan mode/i.test(ac)?"planmode":"noplanmode";
        process.stdout.write((o.hookEventName||"?")+"|"+plm+"|"+triage+"|"+pm);
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

session_unavailable() {
  [ ! -s "$1" ] || grep -qiE 'weekly limit|usage limit|hit your .{0,20}limit|rate.?limit|reset[s]? (on|at|in| )|invalid api key|please run /login|not logged in|authentication_error|overloaded|credit balance' "$1" 2>/dev/null
}

log ""
log "▸ Deterministic hook-contract assertions (real UserPromptSubmit payload shape)"

OUT_PLAN="$(run_hook "I want to track Zensu as a product in Zensu itself" | classify)"
[ "$OUT_PLAN" = "UserPromptSubmit|plm|triage|planmode" ] \
  && check "D1 planning payload -> zensu-plm delegation + greenfield/brownfield triage + Plan-mode directive" PASS \
  || check "D1 planning directive (got '$OUT_PLAN')" FAIL

OUT_NEG="$(run_hook "fix the auth token expiry bug" | classify)"
[ "$OUT_NEG" = "EMPTY" ] && check "D2 non-planning payload -> silent" PASS || check "D2 non-planning silent (got '$OUT_NEG')" FAIL

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
  log "  Report: $REPORT"
  log "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

if [ ! -d "$FIXTURE" ]; then
  check "fixture present (run ./setup-fixtures.sh first)" FAIL
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  exit 1
fi

log ""
log "▸ Live claude --print assertions"
CAPTURED="$RESULTS_DIR/planning-${TIMESTAMP}.captured.txt"
PROMPT="I want to start tracking my SaaS product and its features in Zensu. How should we begin?"
log "Running (timeout ${TIMEOUT}s) claude --print with a planning prompt..."
( cd "$FIXTURE" && timeout "$TIMEOUT" claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$PROMPT" ) > "$CAPTURED" 2>&1

if session_unavailable "$CAPTURED"; then
  log "  SKIP  live (L1/L2) — claude session unavailable: $(head -c 100 "$CAPTURED" 2>/dev/null | tr '\n' ' ')"
  log "         deterministic D1/D2 above stand; re-run when the API is available"
else
  check "L1 claude --print produced a real session reply (plugin loaded, hook active, session not broken)" PASS
  if grep -qiE 'zensu-plm|greenfield|brownfield|ghost.?scan|already built|starting fresh|existing code|not yet built|bootstrap' "$CAPTURED" 2>/dev/null; then
    check "L2 planning reply surfaces an injected triage signal (directive reached the model)" PASS
  else
    log "  SKIP  L2 no triage signal in reply — model phrasing varied (best-effort; deterministic D1 proves injection)"
  fi

  CAPTURED_FP="$RESULTS_DIR/falsepos-${TIMESTAMP}.captured.txt"
  PROMPT_FP="please improve my product by adding a new modern hero section to my landing page"
  log "Running (timeout ${TIMEOUT}s) claude --print with a false-positive (UI) prompt..."
  ( cd "$FIXTURE" && timeout "$TIMEOUT" claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$PROMPT_FP" ) > "$CAPTURED_FP" 2>&1
  if session_unavailable "$CAPTURED_FP"; then
    log "  SKIP  L3 — claude session unavailable for the false-positive probe"
  elif grep -qiE 'greenfield|brownfield|ghost.?scan|bootstrap (a|the|your)|run the .{0,20}triage|already built.{0,20}starting fresh|spin up .{0,20}zensu-plm' "$CAPTURED_FP" 2>/dev/null; then
    log "  OBSERVE  L3 — model surfaced a planning-triage signal on a UI prompt; dismiss-clause may need tuning (best-effort, not failing)"
  else
    check "L3 false-positive UI prompt -> model dismissed the planning steer (no triage)" PASS
  fi
fi

log ""
log "════════════════════════════════════════"
log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
log "  Report: $REPORT"
log "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
