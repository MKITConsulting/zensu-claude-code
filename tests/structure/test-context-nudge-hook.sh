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
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command);
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
# Transcript with an assistant usage block of <input_tokens> (window default 200000).
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
  node -e 'process.stdout.write(JSON.stringify({transcript_path:process.argv[1],session_id:process.argv[2],prompt:"do a thing"}))' "$1" "$2"
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

# C6 default-enabled, 60% -> nudge
P6="$(mktemp -d -t ctxnudge-XXXXXX)"; T6="$P6/t.jsonl"; make_transcript "$T6" 120000
OUT6="$(payload "$T6" "s6-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P6" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT6" = "UserPromptSubmit|compact|60" ]; then
  check "C6 60% occupancy -> UserPromptSubmit /compact nudge at ~60%" PASS
else
  check "C6 60% nudge (got '$OUT6')" FAIL
fi
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

# C10 band de-bounce: same session+project, second 60% prompt -> silent
P10="$(mktemp -d -t ctxnudge-XXXXXX)"; T10="$P10/t.jsonl"; make_transcript "$T10" 120000
S10="s10-$$"
OUT10A="$(payload "$T10" "$S10" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P10" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
OUT10B="$(payload "$T10" "$S10" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P10" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT10A" = "UserPromptSubmit|compact|60" ] && [ "$OUT10B" = "EMPTY" ]; then
  check "C10 band de-bounce: nudge once per band (2nd prompt at same band silent)" PASS
else
  check "C10 de-bounce (1st='$OUT10A' 2nd='$OUT10B')" FAIL
fi
rm -rf "$P10"

# C11 re-arm after shrink: 60% -> drop to 10% (silent, resets) -> 60% again nudges
P11="$(mktemp -d -t ctxnudge-XXXXXX)"; T11="$P11/t.jsonl"; S11="s11-$$"
make_transcript "$T11" 120000
OUT11A="$(payload "$T11" "$S11" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
make_transcript "$T11" 20000
OUT11B="$(payload "$T11" "$S11" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P11" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
make_transcript "$T11" 120000
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

# C17 trailing zero-usage record -> hook skips it, uses the real 120k line -> 60% nudge
P17="$(mktemp -d -t ctxnudge-XXXXXX)"; T17="$P17/t.jsonl"; make_transcript_trailing_zero "$T17" 120000
OUT17="$(payload "$T17" "s17-$$" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P17" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null | classify)"
if [ "$OUT17" = "UserPromptSubmit|compact|60" ]; then
  check "C17 trailing all-zero usage record skipped -> uses real 120k line -> 60% nudge" PASS
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

echo "----"
echo "test-context-nudge-hook: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
