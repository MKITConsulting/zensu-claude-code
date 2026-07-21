#!/bin/bash
# Current main-thread review-chain wiring contract.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
HOOKS="$ROOT/hooks/hooks.json"
PASS=0; FAIL=0
check() { if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi; }

node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const blocks=(j.hooks?.PostToolUse||[]).filter(x=>x.matcher==="Agent");
  const commands=blocks.flatMap(x=>x.hooks||[]).map(x=>x.command||"");
  process.exit(blocks.length===1
    && commands.length===1
    && /post-review-tdd-delegate\.sh/.test(commands[0])
    && !commands.some(x=>/post-tdd-review-delegate/.test(x)) ? 0 : 1);
' "$HOOKS" && check "PostToolUse:Agent owns only reviewer-to-main routing" PASS \
  || check "PostToolUse:Agent wiring drifted" FAIL

node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const commands=(j.hooks?.Stop||[]).flatMap(x=>x.hooks||[]).map(x=>x.command||"");
  process.exit(commands.length===1 && /stop-chain-enforcer\.sh/.test(commands[0]) ? 0 : 1);
' "$HOOKS" && check "Stop hook owns the main-thread chain guarantee" PASS \
  || check "Stop-hook chain guarantee wiring drifted" FAIL

[ -x "$ROOT/hooks/post-review-tdd-delegate.sh" ] \
  && check "post-review main-thread delegate is executable" PASS \
  || check "post-review main-thread delegate is executable" FAIL
[ -x "$ROOT/hooks/stop-chain-enforcer.sh" ] \
  && check "Stop chain enforcer is executable" PASS \
  || check "Stop chain enforcer is executable" FAIL
[ ! -e "$ROOT/hooks/post-tdd-review-delegate.sh" ] \
  && check "retired tdd-manager delegate is absent" PASS \
  || check "retired tdd-manager delegate is absent" FAIL

echo "----"
echo "assert-config: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
