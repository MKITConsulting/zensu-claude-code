#!/bin/bash
# Pins agents/review-aspect.md: the read-only, single-perspective reviewer that the
# /zensu:tdd review chain fans out in parallel (one spawn per perspective). It MUST be
# strictly read-only — no Write/Edit/MultiEdit, no build/test execution — because five of
# them run at once and the suite already ran once in the Phase 6 audit.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_MD="$PLUGIN_DIR/agents/review-aspect.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$AGENT_MD" ]; then
  check "A1 agents/review-aspect.md exists" FAIL
  echo "----"
  echo "test-review-aspect-agent: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "A1 agents/review-aspect.md exists" PASS

# Frontmatter is the first fenced block delimited by '---' lines.
FRONTMATTER="$(awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{exit} f{print}' "$AGENT_MD")"

printf '%s\n' "$FRONTMATTER" | grep -qE '^name:[[:space:]]*review-aspect[[:space:]]*$' \
  && check "A2 frontmatter name: review-aspect" PASS || check "A2 frontmatter name: review-aspect" FAIL

printf '%s\n' "$FRONTMATTER" | grep -qE '^model:[[:space:]]*inherit[[:space:]]*$' \
  && check "A3 frontmatter model: inherit" PASS || check "A3 frontmatter model: inherit" FAIL

TOOLS_LINE="$(printf '%s\n' "$FRONTMATTER" | grep -E '^tools:')"
for t in Read Grep Glob; do
  printf '%s' "$TOOLS_LINE" | grep -qw "$t" \
    && check "A4 tools grants read-only '$t'" PASS || check "A4 tools grants read-only '$t'" FAIL
done

# Strictly read-only: no mutation tools in the tools: line.
DENIED=0
for t in Write Edit MultiEdit NotebookEdit; do
  if printf '%s' "$TOOLS_LINE" | grep -qw "$t"; then DENIED=1; echo "    (offending tool: $t)"; fi
done
[ "$DENIED" -eq 0 ] && check "A5 tools line grants NO write/edit tools (read-only)" PASS \
  || check "A5 tools line grants NO write/edit tools (read-only)" FAIL

# Bash, if present, is restricted by prose to git diff only (mirror code-reviewer discipline).
grep -qF 'git diff HEAD --' "$AGENT_MD" \
  && check "A6 restricts Bash to 'git diff HEAD -- <file>'" PASS || check "A6 restricts Bash to git diff" FAIL

# Hard prohibition on running build/test commands (five run in parallel; suite already ran).
grep -qiE 'never run (any )?(build|test)|do not run (any )?(build|test)|MUST NOT run (any )?(build|test)|no build|no test (commands|execution)' "$AGENT_MD" \
  && check "A7 prose forbids build/test execution" PASS || check "A7 prose forbids build/test execution" FAIL

# Single-perspective: the perspective is a spawn-time parameter, and all five are named.
grep -qF '{PERSPECTIVE}' "$AGENT_MD" \
  && check "A8 takes a {PERSPECTIVE} spawn parameter" PASS || check "A8 {PERSPECTIVE} parameter" FAIL
for p in conventions bugs architecture tests security; do
  grep -qiw "$p" "$AGENT_MD" \
    && check "A9 names perspective '$p'" PASS || check "A9 names perspective '$p'" FAIL
done

# Read-only promise stated explicitly (mirror code-reviewer line 17).
grep -qiF 'READ-ONLY' "$AGENT_MD" \
  && check "A10 states READ-ONLY promise" PASS || check "A10 READ-ONLY promise" FAIL

# Registration in plugin.json agents[].
jq -e '.agents | index("./agents/review-aspect.md")' "$PLUGIN_JSON" >/dev/null 2>&1 \
  && check "A11 plugin.json agents[] contains './agents/review-aspect.md'" PASS \
  || check "A11 plugin.json agents[] registration" FAIL

# English-only (repo convention): no German umlauts / eszett.
if node -e 'const t=require("fs").readFileSync(process.argv[1],"utf8");process.exit(/[äöüÄÖÜß]/.test(t)?1:0)' "$AGENT_MD"; then
  check "A12 review-aspect.md is English-only (no umlauts/eszett)" PASS
else
  check "A12 review-aspect.md is English-only (no umlauts/eszett)" FAIL
fi

echo "----"
echo "test-review-aspect-agent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
