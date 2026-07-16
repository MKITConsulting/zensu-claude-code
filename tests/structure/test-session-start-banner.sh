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

if grep -qF 'MSYS2_ENV_CONV_EXCL=' "$PRIMER" \
  && grep -qF 'ZENSU_LOG_HELPER_Q' "$PRIMER"; then
  check "B5a primer preserves its pre-quoted helper token across MSYS env conversion" PASS
else
  check "B5a primer preserves its pre-quoted helper token across MSYS env conversion" FAIL
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

PRIMER_START="$(printf '%s' '{"source":"startup"}' | bash "$PRIMER" 2>/dev/null)"
if printf '%s' "$PRIMER_START" | node -e '
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
EXPECTED_START_HELPER_Q="$(printf '%q' "$PLUGIN_DIR/hooks/lib/zensu-log.sh")"
if printf '%s' "$PRIMER_START" | grep -qF "bash $EXPECTED_START_HELPER_Q --tdd-begin" \
  && ! printf '%s' "$PRIMER_START" | grep -qF '__ZENSU_LOG_HELPER_Q__' \
  && ! printf '%s' "$PRIMER_START" | grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT}'; then
  check "B12b primer output embeds one concrete inert helper token" PASS
else
  check "B12b primer output embeds one concrete inert helper token" FAIL
fi

PRIMER_COMPACT="$(printf '%s' '{"source":"compact"}' | bash "$PRIMER" 2>/dev/null)"
[ -z "$PRIMER_COMPACT" ] && check "B13 primer silent on source=compact" PASS || check "B13 primer silent on source=compact" FAIL

STRICT_CONFIG="$(mktemp -t zensu-primer-strict-XXXXXX)"
printf '%s\n' '{"hooks":{"tddImplementation":true}}' > "$STRICT_CONFIG"
PRIMER_STRICT="$(printf '%s' '{"source":"startup"}' | ZENSU_CONFIG="$STRICT_CONFIG" bash "$PRIMER" 2>/dev/null)"
rm -f "$STRICT_CONFIG"
if printf '%s' "$PRIMER_STRICT" | grep -qF "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  && ! printf '%s' "$PRIMER_STRICT" | grep -qF '${CLAUDE_PLUGIN_ROOT}'; then
  check "B14 strict primer embeds the concrete session plugin root" PASS
else
  check "B14 strict primer embeds the concrete session plugin root" FAIL
fi

# Regression: the concrete root is serialized through JSON and then shown as a
# runnable shell token. Spaces, command substitutions, backticks, semicolons,
# quotes, and backslashes must stay data rather than becoming shell syntax.
SPECIAL_BASE="$(mktemp -d -t zensu-primer-root-XXXXXX)"
SPECIAL_ROOT="$SPECIAL_BASE/"'plugin root $(touch PRIMER_PWNED) `touch PRIMER_TICKED`;touch PRIMER_SEMI; apostrophe'"'"'value quote"back\slash'$'\nnewline'
mkdir -p "$SPECIAL_ROOT/hooks/lib" "$SPECIAL_BASE/run"
SPECIAL_CANONICAL_ROOT="$(cd "$SPECIAL_ROOT" && pwd -P)"
cp "$PRIMER" "$SPECIAL_ROOT/hooks/session-start-primer.sh"
cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$SPECIAL_ROOT/hooks/lib/zensu-config.sh"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
chmod +x "$SPECIAL_ROOT/hooks/lib/zensu-log.sh"
printf '%s\n' '{"hooks":{"tddImplementation":true}}' > "$SPECIAL_BASE/strict.json"
PRIMER_SPECIAL="$(printf '%s' '{"source":"startup"}' | CLAUDE_PLUGIN_ROOT="$SPECIAL_CANONICAL_ROOT" \
  ZENSU_CONFIG="$SPECIAL_BASE/strict.json" bash "$SPECIAL_ROOT/hooks/session-start-primer.sh" 2>/dev/null)"
EXPECTED_Q="$(printf '%q' "$SPECIAL_CANONICAL_ROOT/hooks/lib/zensu-log.sh")"
SPECIAL_CTX="$(printf '%s' "$PRIMER_SPECIAL" | node -e '
  let s=""; process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const out = j.hookSpecificOutput || {};
      if (out.hookEventName !== "SessionStart" || typeof out.additionalContext !== "string") process.exit(2);
      process.stdout.write(out.additionalContext);
    } catch (_) { process.exit(1); }
  });
' 2>/dev/null)"
SPECIAL_PARSE_RC=$?
(
  cd "$SPECIAL_BASE/run" || exit 1
  eval "bash $EXPECTED_Q --tdd-begin" >/dev/null 2>&1
)
SPECIAL_EXEC_RC=$?
if [ "$SPECIAL_PARSE_RC" = "0" ] && [ "$SPECIAL_EXEC_RC" = "0" ] \
  && printf '%s' "$SPECIAL_CTX" | grep -qF "bash $EXPECTED_Q --tdd-begin" \
  && ! printf '%s' "$SPECIAL_CTX" | grep -qF '${CLAUDE_PLUGIN_ROOT}' \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_PWNED" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_TICKED" ] \
  && [ ! -e "$SPECIAL_BASE/run/PRIMER_SEMI" ]; then
  check "B15 special-character root stays valid JSON and one inert shell token" PASS
else
  check "B15 special-character root stays valid JSON and one inert shell token" FAIL
fi
rm -rf "$SPECIAL_BASE"

echo "----"
echo "test-session-start-banner: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
