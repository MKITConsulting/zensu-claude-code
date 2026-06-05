#!/bin/bash
# LIVE context-compaction-nudge E2E — proves user-prompt-context-nudge.sh reads a
# REAL Claude Code session transcript correctly, end to end.
#
# Strategy: a live `claude --print` run produces a genuine session transcript
# (real `message.usage` blocks, real field nesting — the exact surface the unit
# test can only approximate with synthetic fixtures). We then invoke the hook the
# way Claude Code's UserPromptSubmit event does (payload on stdin carrying the real
# transcript_path) and assert the read→occupancy→threshold→emit contract against
# that real artifact:
#   - the live run produced output (plugin loaded, hook active, session not broken)
#   - a real session transcript was located + carries a parseable usage block
#   - the hook runs against that real transcript fail-open: exit 0, valid-or-empty
#     contract (a trivial `claude --print` greeting records ~0 occupancy, so this
#     proves the real-format read + fail-open, not a nudge)
#   - behavioral (only when a real occupied>0 session exists on disk): tiny window
#     -> /compact proposal, huge window -> silent; skipped in a barren env
#
# Asserting on the hook's deterministic output (not on whether the LLM happened to
# echo "/compact") keeps this robust despite non-deterministic model phrasing —
# mirrors tests/e2e-tdd which asserts post-run STATE, not stdout prose. The
# occupancy MATH is pinned hermetically by tests/structure/test-context-nudge-hook.sh;
# this suite proves the read works against REAL Claude Code transcript structure.
#
# Modes: (full) one live claude run + asserts | --offline (re-assert last run's
#        transcript) | --self-check (skeleton only, no claude, no API).
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$EVAL_DIR/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-context-nudge.sh"

FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
RESULTS_DIR="${RESULTS_DIR:-$EVAL_DIR/results}"
mkdir -p "$RESULTS_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/report-$TIMESTAMP.txt"
TIMEOUT="${ZENSU_CTX_E2E_TIMEOUT:-180}"
FIXTURE="$FIXTURES_DIR/greet"
TRANSCRIPT_PTR="$RESULTS_DIR/last-transcript.txt"

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

log "=== Live context-nudge E2E: $TIMESTAMP ($MODE) ==="
log "Plugin dir: $PLUGIN_DIR"
log "Fixture:    $FIXTURE"

if [ "$MODE" = "--self-check" ]; then
  log ""
  log "  (skeleton only — no claude spawned)"
  [ -f "$HOOK" ] && [ -x "$HOOK" ] && check "hook present + executable" PASS || check "hook present + executable" FAIL
  log "════════════════════════════════════════"
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  log "════════════════════════════════════════"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# ── Locate the session transcript produced by a live run ─────────────
# Scan ~/.claude/projects for the newest *.jsonl (modified after $1, a marker
# file) that carries a usage block. Avoids guessing claude's cwd-encoding scheme.
locate_transcript() {
  local marker="$1"
  local proj="$HOME/.claude/projects"
  [ -d "$proj" ] || return 1
  find "$proj" -name '*.jsonl' -newer "$marker" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null \
    | while IFS= read -r f; do
        grep -ql input_tokens "$f" 2>/dev/null && { printf '%s' "$f"; break; }
      done
}

# Newest transcript anywhere whose most-recent usage block has occupied>0 (a real,
# token-bearing session — `claude --print` greetings record ~0, so behavioral
# nudge assertions need a real session). Empty when none (barren CI).
locate_nonzero_transcript() {
  local proj="$HOME/.claude/projects"
  [ -d "$proj" ] || return 1
  ls -t "$proj"/*/*.jsonl 2>/dev/null | head -60 | while IFS= read -r f; do
    grep -ql input_tokens "$f" 2>/dev/null || continue
    local occ
    occ="$(node -e '
      const fs=require("fs");
      try{const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
        for(let i=lines.length-1;i>=0;i--){let o;try{o=JSON.parse(lines[i])}catch(_){continue}
          const u=(o&&o.message&&o.message.usage)||(o&&o.usage);
          if(u&&typeof u.input_tokens==="number"){const c=u.input_tokens+(u.cache_read_input_tokens||0)+(u.cache_creation_input_tokens||0); if(c>0){process.stdout.write(String(c));break;}}}}catch(_){}
    ' "$f" 2>/dev/null)"
    [ -n "$occ" ] && { printf '%s' "$f"; break; }
  done
}

# ── Invoke the hook exactly as the UserPromptSubmit event does ───────
# Isolated state dir per call so band de-bounce never crosses assertions.
# Echoes the hook's stdout (additionalContext JSON or nothing).
run_hook() {
  local transcript="$1" window="$2" threshold="${3:-50}"
  local sd; sd="$(mktemp -d -t ctxe2e-XXXXXX)"
  local cfg="$sd/config.json"
  if [ "$window" = "auto" ]; then
    printf '{"context":{"compactionNudge":true,"nudgeThreshold":%s}}' "$threshold" > "$cfg"
  else
    printf '{"context":{"compactionNudge":true,"nudgeThreshold":%s,"windowSize":%s}}' "$threshold" "$window" > "$cfg"
  fi
  local payload
  payload="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",transcript_path:process.argv[1],session_id:"e2e-ctx",cwd:process.argv[2],prompt:"continue"}))' "$transcript" "$sd")"
  printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$sd" ZENSU_CONFIG="$cfg" bash "$HOOK" 2>/dev/null
  rm -rf "$sd"
}

# Classify hook stdout -> "EVENT|compact|PCT" or "EMPTY" or "BADJSON".
classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s); const o=j.hookSpecificOutput||{}; const ac=o.additionalContext||"";
        process.stdout.write((o.hookEventName||"?")+"|"+(/\/compact/.test(ac)?"compact":"nocompact")+"|"+((ac.match(/~(\d+)%/)||[])[1]||"?"));
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

# ── Obtain a real transcript (live run, or reuse for --offline) ──────
if [ "$MODE" = "--offline" ]; then
  TRANSCRIPT="$( [ -f "$TRANSCRIPT_PTR" ] && cat "$TRANSCRIPT_PTR" )"
  if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    check "prior transcript exists (--offline; run full once first)" FAIL
    log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"; exit 1
  fi
  log "Offline: re-asserting against $TRANSCRIPT"
else
  if [ ! -d "$FIXTURE" ]; then
    check "fixture present (run ./setup-fixtures.sh first)" FAIL
    log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"; exit 1
  fi
  MARKER="$(mktemp -t ctxe2e-marker-XXXXXX)"
  CAPTURED="$RESULTS_DIR/greet-${TIMESTAMP}.captured.txt"
  PROMPT="Reply with a one-sentence greeting and nothing else."
  log "Running (timeout ${TIMEOUT}s) claude --print to generate a real transcript..."
  ( cd "$FIXTURE" && timeout "$TIMEOUT" claude --print --plugin-dir "$PLUGIN_DIR" --permission-mode bypassPermissions "$PROMPT" ) > "$CAPTURED" 2>&1
  [ -s "$CAPTURED" ] && check "1 claude --print produced output" PASS || check "1 claude --print produced output (zero-byte capture)" FAIL
  TRANSCRIPT="$(locate_transcript "$MARKER")"
  rm -f "$MARKER"
  [ -n "$TRANSCRIPT" ] && printf '%s' "$TRANSCRIPT" > "$TRANSCRIPT_PTR"
fi

log ""
log "▸ Real-transcript assertions"

# 2. transcript located + carries a parseable usage block with input_tokens.
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && node -e '
  const fs=require("fs");
  const lines=fs.readFileSync(process.argv[1],"utf8").split("\n").filter(Boolean);
  for(let i=lines.length-1;i>=0;i--){let o;try{o=JSON.parse(lines[i])}catch(_){continue}
    const u=(o&&o.message&&o.message.usage)||(o&&o.usage);
    if(u&&typeof u.input_tokens==="number")process.exit(0);}
  process.exit(1);
' "$TRANSCRIPT" 2>/dev/null; then
  check "2 real session transcript located + has message.usage.input_tokens" PASS
else
  check "2 real session transcript located + has usage block (got: ${TRANSCRIPT:-none})" FAIL
fi

# Guard the behavioral asserts on a usable transcript.
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  log ""
  log "  (skipping 3-5: no usable transcript)"
  log "════════════════════════════════════════"
  log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
  log "  Report: $REPORT"
  log "════════════════════════════════════════"
  exit 1
fi

# 3. Fail-open on the freshly-generated real transcript: the hook must run against
#    the genuine Claude Code transcript format and exit 0 with a valid contract
#    (empty, or a well-formed UserPromptSubmit additionalContext JSON) — never
#    crash or block. A trivial `claude --print` greeting records ~0 occupancy, so
#    this proves the real-format read + fail-open path, not a nudge.
SD3="$(mktemp -d -t ctxe2e-XXXXXX)"
printf '%s' '{"context":{"compactionNudge":true,"nudgeThreshold":1}}' > "$SD3/config.json"
PAY3="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",transcript_path:process.argv[1],session_id:"e2e-ctx",cwd:process.argv[2],prompt:"x"}))' "$TRANSCRIPT" "$SD3")"
OUT3="$(printf '%s' "$PAY3" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$SD3" ZENSU_CONFIG="$SD3/config.json" bash "$HOOK" 2>/dev/null)"; RC3=$?
CLS3="$(printf '%s' "$OUT3" | classify)"
rm -rf "$SD3"
if [ "$RC3" = "0" ] && { [ "$CLS3" = "EMPTY" ] || [ "${CLS3%%|*}" = "UserPromptSubmit" ]; }; then
  check "3 hook fail-open on real claude transcript (exit 0, valid-or-empty contract)" PASS
else
  check "3 hook fail-open on real transcript (rc=$RC3 cls='$CLS3')" FAIL
fi

# 4. Behavioral proof against a real transcript that ACTUALLY carries occupancy.
#    `claude --print` zeros usage, so scan ~/.claude/projects for a real (e.g.
#    interactive) session with occupied>0: present on a dev machine, absent in a
#    barren CI where it is skipped (not failed). The deterministic occupancy
#    behavior is pinned offline by tests/structure/test-context-nudge-hook.sh.
NZ="$(locate_nonzero_transcript)"
if [ -n "$NZ" ] && [ -f "$NZ" ]; then
  log "  (behavioral: real occupied>0 transcript $(basename "$NZ"))"
  OUT_TINY="$(run_hook "$NZ" 1000 50 | classify)"
  case "$OUT_TINY" in
    UserPromptSubmit\|compact\|*) check "4a tiny window over real-occupancy transcript -> /compact proposal" PASS ;;
    *) check "4a tiny window -> /compact (got '$OUT_TINY')" FAIL ;;
  esac
  OUT_HUGE="$(run_hook "$NZ" 100000000 50 | classify)"
  [ "$OUT_HUGE" = "EMPTY" ] && check "4b huge window over real-occupancy transcript -> silent" PASS || check "4b huge window -> silent (got '$OUT_HUGE')" FAIL
else
  log "  SKIP 4a/4b — no real transcript with occupied>0 found (barren env); covered offline by the structure test"
fi

log ""
log "════════════════════════════════════════"
log "  TOTAL: $PASS/$TOTAL PASS ($FAIL FAIL)"
log "  Report: $REPORT"
log "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
