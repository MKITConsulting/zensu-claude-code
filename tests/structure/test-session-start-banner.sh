#!/bin/bash
set -u

# Pins the SessionStart "Zensu active" banner + agent primer (0.4.0):
# user banner via stdout, agent primer via additionalContext, both gated by
# hooks.sessionBanner and firing only on fresh starts (startup/clear).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"
PRIMER="$PLUGIN_DIR/hooks/session-start-primer.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

[ -f "$BANNER" ] && [ -x "$BANNER" ] && check "B1 banner hook exists + executable" PASS || check "B1 banner hook exists + executable" FAIL
[ -f "$PRIMER" ] && [ -x "$PRIMER" ] && check "B2 primer hook exists + executable" PASS || check "B2 primer hook exists + executable" FAIL

if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ss=(h.hooks.SessionStart||[]).flatMap(x=>x.hooks||[]).map(z=>[z.command||"",...(z.args||[])].join(" "));
  const hasB=ss.some(c=>/session-start-banner\.sh/.test(c));
  const hasP=ss.some(c=>/session-start-primer\.sh/.test(c));
  process.exit(hasB && hasP ? 0 : 1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "B3 both hooks registered in hooks.json SessionStart" PASS
else
  check "B3 both hooks registered in hooks.json SessionStart" FAIL
fi

if grep -qF 'zensu_hook_enabled sessionBanner' "$BANNER" && grep -qF 'zensu_hook_enabled sessionBanner' "$PRIMER"; then
  check "B4 both gated by hooks.sessionBanner" PASS
else
  check "B4 both gated by hooks.sessionBanner" FAIL
fi

if grep -qF 'resume|compact' "$BANNER" && grep -qF 'resume|compact' "$PRIMER"; then
  check "B5 fresh-start source filter (skip resume/compact)" PASS
else
  check "B5 fresh-start source filter (skip resume/compact)" FAIL
fi

if grep -qF '/zensu:tdd' "$BANNER" && grep -qF 'Zensu PLM' "$BANNER" && grep -qF 'hooks.sessionBanner=false' "$BANNER"; then
  check "B6 banner mentions Zensu PLM + /zensu:tdd + opt-out hint" PASS
else
  check "B6 banner mentions Zensu PLM + /zensu:tdd + opt-out hint" FAIL
fi
if grep -qF '/zensu:tdd-manager' "$BANNER"; then
  check "B7 banner has NO stale /zensu:tdd-manager" FAIL
else
  check "B7 banner has NO stale /zensu:tdd-manager" PASS
fi

if grep -qF 'Plan mode' "$PRIMER" && grep -qF '/zensu:tdd' "$PRIMER"; then
  check "B8 primer mentions Plan mode + /zensu:tdd" PASS
else
  check "B8 primer mentions Plan mode + /zensu:tdd" FAIL
fi
if grep -qF '/zensu:tdd-manager' "$PRIMER"; then
  check "B9 primer has NO stale /zensu:tdd-manager" FAIL
else
  check "B9 primer has NO stale /zensu:tdd-manager" PASS
fi

# Behavioral (hermetic: force default-enabled via a non-existent config path).
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export ZENSU_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

OUT_START="$(printf '%s' '{"source":"startup"}' | bash "$BANNER" 2>/dev/null)"
[ -n "$OUT_START" ] && check "B10 banner emits on source=startup" PASS || check "B10 banner emits on source=startup" FAIL

OUT_RESUME="$(printf '%s' '{"source":"resume"}' | bash "$BANNER" 2>/dev/null)"
[ -z "$OUT_RESUME" ] && check "B11 banner silent on source=resume" PASS || check "B11 banner silent on source=resume" FAIL

if printf '%s' '{"source":"startup"}' | bash "$PRIMER" 2>/dev/null | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s);
    const ok = j.hookSpecificOutput && j.hookSpecificOutput.hookEventName==="SessionStart"
      && typeof j.hookSpecificOutput.additionalContext==="string"
      && j.hookSpecificOutput.additionalContext.length>0;
    process.exit(ok?0:1); } catch(_){ process.exit(1); } });
'; then
  check "B12 primer emits valid SessionStart additionalContext JSON on startup" PASS
else
  check "B12 primer emits valid SessionStart additionalContext JSON on startup" FAIL
fi

PRIMER_COMPACT="$(printf '%s' '{"source":"compact"}' | bash "$PRIMER" 2>/dev/null)"
[ -z "$PRIMER_COMPACT" ] && check "B13 primer silent on source=compact" PASS || check "B13 primer silent on source=compact" FAIL

echo "----"
echo "test-session-start-banner: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
