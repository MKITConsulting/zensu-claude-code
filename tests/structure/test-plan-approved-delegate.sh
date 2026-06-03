#!/bin/bash
# Pins plan-approved-delegate.sh (PostToolUse:ExitPlanMode) behavioral output (0.4.0):
#   default (autoTdd on) -> emits SessionStart-style additionalContext JSON that
#     routes the MAIN thread to the /zensu:tdd Skill (skill='zensu:tdd'), with the
#     'Executing via /zensu:tdd' / 'Skipping TDD' status-line contract and the
#     doc-only (README/CHANGELOG/markdown) escape exception.
#   hooks.autoTdd=false  -> silent (no output), so the hook can be disabled.
#   MUST NOT reference the removed pre-0.4.0 'tdd-manager' subagent.
# This is the deterministic counterpart to evals/plan-approval-hook (interactive
# expect+API) — it proves the hook's emitted directive without spawning a session.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/plan-approved-delegate.sh exists" FAIL
  echo "----"; echo "test-plan-approved-delegate: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "D0 hooks/plan-approved-delegate.sh exists" PASS

if bash -n "$HOOK" 2>/dev/null; then
  check "D1 bash -n syntax check passes" PASS
else
  check "D1 bash -n syntax check passes" FAIL
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
# Force defaults (autoTdd enabled) by pointing config resolution at a missing file.
export ZENSU_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"

OUT="$(printf '%s' '{"tool_name":"ExitPlanMode","tool_input":{"plan":"add a function"}}' | bash "$HOOK" 2>/dev/null)"

# D2 valid additionalContext JSON for PostToolUse
if printf '%s' "$OUT" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s);
    const o=j.hookSpecificOutput;
    const ok = o && o.hookEventName==="PostToolUse" && typeof o.additionalContext==="string" && o.additionalContext.length>0;
    process.exit(ok?0:1); } catch(_){ process.exit(1); } });
'; then
  check "D2 emits valid PostToolUse additionalContext JSON on default (autoTdd on)" PASS
else
  check "D2 emits valid PostToolUse additionalContext JSON on default (autoTdd on)" FAIL
fi

# D3 directive routes to the /zensu:tdd Skill in the main thread
if printf '%s' "$OUT" | grep -qF "skill='zensu:tdd'"; then
  check "D3 directive names skill='zensu:tdd' (main-thread routing)" PASS
else
  check "D3 directive names skill='zensu:tdd'" FAIL
fi

# D4 status-line contract present (Executing via /zensu:tdd | Skipping TDD)
if printf '%s' "$OUT" | grep -qF 'Executing via /zensu:tdd' \
   && printf '%s' "$OUT" | grep -qF 'Skipping TDD'; then
  check "D4 status-line contract present (Executing via /zensu:tdd | Skipping TDD)" PASS
else
  check "D4 status-line contract present" FAIL
fi

# D5 doc-only escape exception documented (README/CHANGELOG/markdown)
if printf '%s' "$OUT" | grep -qiE 'README|CHANGELOG|markdown'; then
  check "D5 doc-only escape exception documented" PASS
else
  check "D5 doc-only escape exception documented" FAIL
fi

# D6 routes in main thread, NOT via the removed pre-0.4.0 tdd-manager subagent.
# ('tdd-manager' may still appear as a user TDD-negation phrase, e.g. 'no tdd-manager';
#  what must be gone is any Agent dispatch to subagent_type='zensu:tdd-manager'.)
if printf '%s' "$OUT" | grep -qiF 'main thread' \
   && ! printf '%s' "$OUT" | grep -qF "subagent_type='zensu:tdd-manager'"; then
  check "D6 routes in main thread, not via removed tdd-manager subagent dispatch" PASS
else
  check "D6 routes in main thread, not via removed tdd-manager subagent dispatch" FAIL
fi

# D7 hooks.autoTdd=false -> silent (hook can be disabled)
CFG_OFF="$PLUGIN_DIR/.autotdd-off-$$.json"
printf '{"hooks":{"autoTdd":false}}' > "$CFG_OFF"
OUT_OFF="$(printf '%s' '{"tool_name":"ExitPlanMode"}' | ZENSU_CONFIG="$CFG_OFF" bash "$HOOK" 2>/dev/null)"
rm -f "$CFG_OFF"
if [ -z "$OUT_OFF" ]; then
  check "D7 hooks.autoTdd=false -> silent (no output)" PASS
else
  check "D7 hooks.autoTdd=false -> silent (got: $OUT_OFF)" FAIL
fi

echo "----"
echo "test-plan-approved-delegate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
