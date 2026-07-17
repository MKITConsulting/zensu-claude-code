#!/bin/bash
set -u

# Pins the UserPromptSubmit context-compaction nudge (user-prompt-context-nudge.sh):
# fires a model-facing /compact proposal once transcript occupancy reaches the
# threshold, gated by context.compactionNudge, threshold/window overridable under
# the context node, band-debounced per session, fail-open (never blocks the prompt).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-context-nudge.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
NO_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"
CONTROL_TMP="$(mktemp -d -t ctxnudge-control-XXXXXX)"
export CLAUDE_PLUGIN_DATA="$CONTROL_TMP/plugin-data"
mkdir -p "$CLAUDE_PLUGIN_DATA"
trap 'rm -rf "$CONTROL_TMP"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/user-prompt-context-nudge.sh exists" FAIL
  echo "----"
  echo "test-context-nudge-hook: $PASS PASS / $FAIL FAIL"
  exit 1
fi
[ -x "$HOOK" ] && check "C1 hook exists + executable" PASS || check "C1 hook exists + executable" FAIL

bash -n "$HOOK" 2>/dev/null && check "C2 bash -n syntax check passes" PASS || check "C2 bash -n syntax check passes" FAIL

# C3 registered in hooks.json under UserPromptSubmit
if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>[z.command||"",...(z.args||[])].join(" "));
  process.exit(ups.some(c=>/user-prompt-context-nudge\.sh/.test(c))?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "C3 registered in hooks.json UserPromptSubmit" PASS
else
  check "C3 registered in hooks.json UserPromptSubmit" FAIL
fi

# C4 config-gated
grep -qF 'zensu_context_nudge_enabled' "$HOOK" \
  && check "C4 gated by context.compactionNudge (zensu_context_nudge_enabled)" PASS \
  || check "C4 gated by context.compactionNudge (zensu_context_nudge_enabled)" FAIL

# C5 emits a UserPromptSubmit /compact proposal
if grep -qF 'UserPromptSubmit' "$HOOK" && grep -qF 'hookEventName' "$HOOK" && grep -qF '/compact' "$HOOK"; then
  check "C5 builds UserPromptSubmit additionalContext proposing /compact" PASS
else
  check "C5 builds UserPromptSubmit additionalContext proposing /compact" FAIL
fi

# ── Behavioral helpers ───────────────────────────────────────────────
# Transcript with an assistant usage block of <input_tokens> tokens.
make_transcript() {
  node -e '
    const fs=require("fs");
    const u={input_tokens:Number(process.argv[3]),cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tokens:42};
    const lines=[
      JSON.stringify({type:"user",message:{role:"user",content:"hi"}}),
      JSON.stringify({type:"assistant",message:{role:"assistant",usage:u}})
    ];
    fs.writeFileSync(process.argv[1], lines.join("\n")+"\n");
  ' "$1" _ "$2"
}
payload() {
  local transcript="$1" session_id="$2" project
  project="$(dirname "$transcript")"
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"SessionStart", source:"startup",
    session_id:process.argv[1], cwd:process.argv[2]
  }))' "$session_id" "$project" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null || return 1
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"UserPromptSubmit", transcript_path:process.argv[1],
    session_id:process.argv[2], prompt:"do a thing"
  }))' "$transcript" "$session_id"
}
# emits "EVENT|HASCOMPACT|PCT" or "EMPTY"
classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const j=JSON.parse(s);
        const o=j.hookSpecificOutput||{};
        const ac=o.additionalContext||"";
        process.stdout.write((o.hookEventName||"?")+"|"+(/\/compact/.test(ac)?"compact":"nocompact")+"|"+((ac.match(/~(\d+)%/)||[])[1]||"?"));
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}

# C6 120k no-config -> SILENT (<=200k, tier unprovable; no false 60% nudge)
P6="$(mktemp -d -t ctxnudge-XXXXXX)"; T6="$P6/t.jsonl"; make_transcript "$T6" 120000
OUT6="$(payload "$T6" "s6-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P6" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT6" = "EMPTY" ] && check "C6 120k no-config -> SILENT (<=200k, tier unprovable)" PASS || check "C6 120k silent (got '$OUT6')" FAIL
rm -rf "$P6"

# C7 default-enabled, 10% -> silent
P7="$(mktemp -d -t ctxnudge-XXXXXX)"; T7="$P7/t.jsonl"; make_transcript "$T7" 20000
OUT7="$(payload "$T7" "s7-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P7" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT7" = "EMPTY" ] && check "C7 10% occupancy -> silent (below threshold)" PASS || check "C7 10% silent (got '$OUT7')" FAIL
rm -rf "$P7"

# C8 disabled via config -> silent even at 60%
P8="$(mktemp -d -t ctxnudge-XXXXXX)"; T8="$P8/t.jsonl"; make_transcript "$T8" 120000
CFG8="$P8/config.json"; printf '%s' '{"context":{"compactionNudge":false}}' > "$CFG8"
OUT8="$(payload "$T8" "s8-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P8" ZENSU_CONFIG="$CFG8" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT8" = "EMPTY" ] && check "C8 context.compactionNudge:false -> silent (opt-out honored)" PASS || check "C8 disabled silent (got '$OUT8')" FAIL
rm -rf "$P8"

# C9 threshold override 90 -> 60% stays silent
P9="$(mktemp -d -t ctxnudge-XXXXXX)"; T9="$P9/t.jsonl"; make_transcript "$T9" 120000
CFG9="$P9/config.json"; printf '%s' '{"context":{"nudgeThreshold":90}}' > "$CFG9"
OUT9="$(payload "$T9" "s9-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P9" ZENSU_CONFIG="$CFG9" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT9" = "EMPTY" ] && check "C9 context.nudgeThreshold:90 -> 60% below custom threshold, silent" PASS || check "C9 custom threshold (got '$OUT9')" FAIL
rm -rf "$P9"

# C10 band de-bounce on the firing path: 600k (1M 60%) twice, 2nd silent
P10="$(mktemp -d -t ctxnudge-XXXXXX)"; T10="$P10/t.jsonl"; make_transcript "$T10" 600000
S10="s10-$$"
OUT10A="$(payload "$T10" "$S10" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P10" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
OUT10B="$(payload "$T10" "$S10" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P10" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT10A" = "UserPromptSubmit|compact|60" ] && [ "$OUT10B" = "EMPTY" ]; then
  check "C10 band de-bounce: nudge once per band (2nd prompt at same band silent)" PASS
else
  check "C10 de-bounce (1st='$OUT10A' 2nd='$OUT10B')" FAIL
fi
rm -rf "$P10"

# C11 re-arm: 600k (1M 60% fires) -> 180k (<=200k silent, re-arms) -> 600k (fires again)
P11="$(mktemp -d -t ctxnudge-XXXXXX)"; T11="$P11/t.jsonl"; S11="s11-$$"
make_transcript "$T11" 600000
OUT11A="$(payload "$T11" "$S11" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
make_transcript "$T11" 180000
OUT11B="$(payload "$T11" "$S11" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
make_transcript "$T11" 600000
OUT11C="$(payload "$T11" "$S11" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT11A" = "UserPromptSubmit|compact|60" ] && [ "$OUT11B" = "EMPTY" ] && [ "$OUT11C" = "UserPromptSubmit|compact|60" ]; then
  check "C11 re-arm after compaction shrink: nudge -> shrink(silent) -> nudge again" PASS
else
  check "C11 re-arm (a='$OUT11A' b='$OUT11B' c='$OUT11C')" FAIL
fi
rm -rf "$P11"

# C12 missing transcript_path -> exit 0, silent
P12="$(mktemp -d -t ctxnudge-XXXXXX)"
OUT12="$(printf '%s' '{"session_id":"s12","prompt":"hi"}' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P12" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC12=$?
if [ "$RC12" = "0" ] && [ -z "$OUT12" ]; then
  check "C12 missing transcript_path -> exit 0, silent (fail-open)" PASS
else
  check "C12 missing transcript_path (rc=$RC12 out='$OUT12')" FAIL
fi
rm -rf "$P12"

# C13 transcript_path points to a nonexistent file -> exit 0, silent
P13="$(mktemp -d -t ctxnudge-XXXXXX)"
OUT13="$(payload "$P13/nope.jsonl" "s13-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P13" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC13=$?
if [ "$RC13" = "0" ] && [ -z "$OUT13" ]; then
  check "C13 nonexistent transcript file -> exit 0, silent (fail-open)" PASS
else
  check "C13 nonexistent transcript (rc=$RC13 out='$OUT13')" FAIL
fi
rm -rf "$P13"

# C14 config.example.json carries the top-level context node (windowSize optional)
if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const c=j.context||{};
  process.exit(c.compactionNudge===true && Number.isInteger(c.nudgeThreshold) ? 0 : 1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "C14 config.example.json has context.{compactionNudge,nudgeThreshold}" PASS
else
  check "C14 config.example.json has context node" FAIL
fi

# C15 large-context auto-tier: 600k occupied, no windowSize -> denominator 1M -> 60% nudge (not 300%)
P15="$(mktemp -d -t ctxnudge-XXXXXX)"; T15="$P15/t.jsonl"; make_transcript "$T15" 600000
OUT15="$(payload "$T15" "s15-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P15" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT15" = "UserPromptSubmit|compact|60" ]; then
  check "C15 600k occupied (no windowSize) -> auto-tier 1M -> ~60% nudge (not >100%)" PASS
else
  check "C15 1M auto-tier (got '$OUT15')" FAIL
fi
rm -rf "$P15"

# C16 just over 200k, no windowSize -> 1M tier -> 25% -> silent (no false nag past 200k)
P16="$(mktemp -d -t ctxnudge-XXXXXX)"; T16="$P16/t.jsonl"; make_transcript "$T16" 250000
OUT16="$(payload "$T16" "s16-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P16" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT16" = "EMPTY" ] && check "C16 250k occupied -> auto-tier 1M -> 25%, silent (no false nag just past 200k)" PASS || check "C16 just-past-200k (got '$OUT16')" FAIL
rm -rf "$P16"

# Builds a transcript: real 120k usage assistant line + a trailing ALL-ZERO usage
# line (as real `claude --print` transcripts end). Hook must skip the zero record.
make_transcript_trailing_zero() {
  node -e '
    const fs=require("fs");
    const big={input_tokens:Number(process.argv[2]),cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tokens:50};
    const zero={input_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tokens:0};
    const L=[
      JSON.stringify({type:"user",message:{role:"user",content:"hi"}}),
      JSON.stringify({type:"assistant",message:{role:"assistant",usage:big}}),
      JSON.stringify({type:"assistant",message:{role:"assistant",usage:zero}})
    ];
    fs.writeFileSync(process.argv[1], L.join("\n")+"\n");
  ' "$1" "$2"
}

# C17 trailing zero-usage record -> hook skips it, uses the real 600k line -> 1M 60% nudge
P17="$(mktemp -d -t ctxnudge-XXXXXX)"; T17="$P17/t.jsonl"; make_transcript_trailing_zero "$T17" 600000
OUT17="$(payload "$T17" "s17-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P17" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT17" = "UserPromptSubmit|compact|60" ]; then
  check "C17 trailing all-zero usage record skipped -> uses real 600k line -> 1M 60% nudge" PASS
else
  check "C17 zero-usage skip (got '$OUT17')" FAIL
fi
rm -rf "$P17"

# C18 ONLY a zero-usage record -> no real occupancy -> silent
P18="$(mktemp -d -t ctxnudge-XXXXXX)"; T18="$P18/t.jsonl"
node -e 'const fs=require("fs");
  const zero={input_tokens:0,cache_read_input_tokens:0,cache_creation_input_tokens:0,output_tokens:0};
  fs.writeFileSync(process.argv[1], JSON.stringify({type:"assistant",message:{role:"assistant",usage:zero}})+"\n");' "$T18"
OUT18="$(payload "$T18" "s18-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P18" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT18" = "EMPTY" ] && check "C18 only zero-usage records -> silent (no real occupancy)" PASS || check "C18 all-zero silent (got '$OUT18')" FAIL
rm -rf "$P18"

P19="$(mktemp -d -t ctxnudge-XXXXXX)"; T19="$P19/t.jsonl"; make_transcript "$T19" 200000
OUT19="$(payload "$T19" "s19-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P19" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT19" = "EMPTY" ] && check "C19 exact 200000 no-config -> SILENT (gate is strict >200000)" PASS || check "C19 exact-200000 (got '$OUT19')" FAIL
rm -rf "$P19"

P20="$(mktemp -d -t ctxnudge-XXXXXX)"; T20="$P20/t.jsonl"; make_transcript "$T20" 600000
RAW20="$(payload "$T20" "s20-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P20" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$RAW20" | grep -qF '600k' && printf '%s' "$RAW20" | grep -qF '~60%' && printf '%s' "$RAW20" | grep -qF '1M' && printf '%s' "$RAW20" | grep -qF '/compact' && ! printf '%s' "$RAW20" | grep -qF 'Verify against Claude Code' && ! printf '%s' "$RAW20" | grep -qF 'may be wrong'; then
  check "C20 unset>200k message: confident token count + ~60% + 1M + /compact, NO hedge" PASS
else
  check "C20 confident message (got '$RAW20')" FAIL
fi
rm -rf "$P20"

P21="$(mktemp -d -t ctxnudge-XXXXXX)"; T21="$P21/t.jsonl"; make_transcript "$T21" 120000
CFG21="$P21/config.json"; printf '%s' '{"context":{"windowSize":200000}}' > "$CFG21"
RAW21="$(payload "$T21" "s21-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P21" ZENSU_CONFIG="$CFG21" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$RAW21" | grep -qF '120k' && printf '%s' "$RAW21" | grep -qF '~60%' && printf '%s' "$RAW21" | grep -qF 'configured' && ! printf '%s' "$RAW21" | grep -qF 'Verify against Claude Code'; then
  check "C21 configured-window message: token count + ~60% + 'configured', no auto-detect hedge" PASS
else
  check "C21 confident message (got '$RAW21')" FAIL
fi
rm -rf "$P21"

P22="$(mktemp -d -t ctxnudge-XXXXXX)"; T22="$P22/t.jsonl"; make_transcript "$T22" 600000
RAW22="$(payload "$T22" "s22-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P22" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$RAW22" | grep -qF 'the 1M window' && ! printf '%s' "$RAW22" | grep -qF 'configured'; then
  check "C22 unset>200k message says confident 'the 1M window', not 'configured'" PASS
else
  check "C22 unset-1M wording (got '$RAW22')" FAIL
fi
rm -rf "$P22"

P23="$(mktemp -d -t ctxnudge-XXXXXX)"; T23="$P23/t.jsonl"; make_transcript "$T23" 600000
CFG23="$P23/config.json"; printf '%s' '{"context":{"windowSize":1000000}}' > "$CFG23"
RAW23="$(payload "$T23" "s23-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P23" ZENSU_CONFIG="$CFG23" bash "$HOOK" 2>/dev/null)"
if printf '%s' "$RAW23" | grep -qF '600k' && printf '%s' "$RAW23" | grep -qF 'configured 1M window' && ! printf '%s' "$RAW23" | grep -qF 'Verify against Claude Code'; then
  check "C23 configured 1M window: 'configured 1M window' label, no auto-detect hedge" PASS
else
  check "C23 configured 1M (got '$RAW23')" FAIL
fi
rm -rf "$P23"

P24="$(mktemp -d -t ctxnudge-XXXXXX)"; T24="$P24/t.jsonl"; S24="s24-$$"
CFG24="$P24/config.json"; printf '%s' '{"context":{"nudgeThreshold":10}}' > "$CFG24"
make_transcript "$T24" 150000
OUT24A="$(payload "$T24" "$S24" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P24" ZENSU_CONFIG="$CFG24" bash "$HOOK" 2>/dev/null | classify)"
make_transcript "$T24" 250000
OUT24B="$(payload "$T24" "$S24" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P24" ZENSU_CONFIG="$CFG24" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT24A" = "EMPTY" ] && [ "$OUT24B" = "UserPromptSubmit|compact|25" ]; then
  check "C24 >200k gate is threshold-independent: thr10 150k->silent, 250k->1M 25% nudge" PASS
else
  check "C24 gate (a='$OUT24A' b='$OUT24B')" FAIL
fi
rm -rf "$P24"

P25="$(mktemp -d -t ctxnudge-XXXXXX)"; T25="$P25/t.jsonl"; make_transcript "$T25" 80000
CFG25="$P25/config.json"; printf '%s' '{"context":{"windowSize":100000}}' > "$CFG25"
OUT25="$(payload "$T25" "s25-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P25" ZENSU_CONFIG="$CFG25" bash "$HOOK" 2>/dev/null | classify)"
[ "$OUT25" = "UserPromptSubmit|compact|80" ] && check "C25 configured windowSize<200k fires sub-200k occupancy (100k window @80k -> 80%)" PASS || check "C25 configured sub-200k (got '$OUT25')" FAIL
rm -rf "$P25"

P26="$(mktemp -d -t ctxnudge-XXXXXX)"; T26="$P26/t.jsonl"; make_transcript "$T26" 600000
OUT26A="$(payload "$T26" "s26a-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P26" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
OUT26B="$(payload "$T26" "s26b-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P26" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT26A" = "UserPromptSubmit|compact|60" ] && [ "$OUT26B" = "UserPromptSubmit|compact|60" ]; then
  check "C26 per-session state isolation: two session ids in one project dir both fire" PASS
else
  check "C26 cross-session (a='$OUT26A' b='$OUT26B')" FAIL
fi
rm -rf "$P26"

P27="$(mktemp -d -t ctxnudge-XXXXXX)"; T27="$P27/t.jsonl"; make_transcript "$T27" 600000
BASE27="$(payload "$T27" "s27-$$")"
OUT27=""
for KIND27 in reviewer plm neutral partial; do
  PAYLOAD27="$(BASE="$BASE27" KIND="$KIND27" node -e '
    const p=JSON.parse(process.env.BASE);
    if(process.env.KIND==="reviewer")p.agent_type="zensu:code-reviewer";
    if(process.env.KIND==="plm")p.agent_type="zensu:zensu-plm";
    if(process.env.KIND==="neutral")p.agent_type="custom-agent";
    if(process.env.KIND==="partial")p.agent_id="child-only";
    process.stdout.write(JSON.stringify(p));
  ')"
  OUT27="${OUT27}$(printf '%s' "$PAYLOAD27" | ZENSU_FORCE_MAIN=1 CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PROJECT_DIR="$P27" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
done
NUDGE_FILES27="$(find "$P27/.zensu/state" -maxdepth 1 -name 'context-nudge-*.txt' -print 2>/dev/null)"
if [ -z "$OUT27" ] && [ -z "$NUDGE_FILES27" ]; then
  check "C27 reviewer/PLM/neutral/partial principals emit no nudge and write no debounce state" PASS
else
  check "C27 non-main principals are a total context-nudge no-op" FAIL
fi
rm -rf "$P27"

echo "----"
echo "test-context-nudge-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
