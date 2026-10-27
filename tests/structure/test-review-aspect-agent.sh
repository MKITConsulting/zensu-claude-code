#!/bin/bash
# Pins agents/review-aspect.md: the read-only, single-perspective reviewer that the
# /zensu:build review chain fans out in parallel (one spawn per perspective). It MUST be
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

# reviewer-readonly-v1 exposes dedicated repository reads only.
if printf '%s' "$TOOLS_LINE" | grep -qw Bash || ! grep -qF 'use Bash' "$AGENT_MD"; then
  check "A6 excludes Bash and states the shell ban" FAIL
else
  check "A6 excludes Bash and states the shell ban" PASS
fi

# Hard prohibition on running build/test commands (five run in parallel; suite already ran).
grep -qiE 'never .*run builds?/tests?|do not re-run.*build.*tests|no (shell/)?build/test' "$AGENT_MD" \
  && check "A7 prose forbids build/test execution" PASS || check "A7 prose forbids build/test execution" FAIL

# Single-perspective: the perspective is a spawn-time parameter, and all seven are named.
grep -qF '{PERSPECTIVE}' "$AGENT_MD" \
  && check "A8 takes a {PERSPECTIVE} spawn parameter" PASS || check "A8 {PERSPECTIVE} parameter" FAIL
for p in correctness design conventions bugs architecture tests security; do
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

SECURITY_LINE="$(grep -E '^   - security: ' "$AGENT_MD")"
printf '%s' "$SECURITY_LINE" | grep -qF -- 'plus every guarantee a query or call inherits from session or connection state instead of stating it (row-level security, a tenant setting, the connecting role): name what enforces it instead of assuming it, check it under each connection mode the code still supports, fallbacks included, and check whether the query or call states the guarantee itself (an account predicate, an explicit tenant or role); a missing one is a finding when a supported mode leaves the guarantee unenforced' \
  && check "A13 security perspective checks inherited guarantees under every supported connection mode" PASS \
  || check "A13 security perspective checks inherited guarantees under every supported connection mode" FAIL

REVIEW_SECTION="$(awk '$0 == "## Review"{f=1;next} f && /^## /{exit} f{print}' "$AGENT_MD")"
printf '%s\n' "$REVIEW_SECTION" | grep -qxF -- '6. A defect reachable through a mode the code still supports (a fallback connection, a flag, an environment variable, a deployment option) is a finding: report it with the condition that reaches it. Committed configuration that disables that mode may lower its severity by one level, never below IMPORTANT, and never drops the finding, because the code still ships the mode and any deployment can enable it. This is the only case in which a defect that fits CRITICAL may be rated IMPORTANT.' \
  && check "A14 review step 6 reports a deployment-dependent defect with its condition, at least IMPORTANT, never dropped" PASS \
  || check "A14 review step 6 reports a deployment-dependent defect with its condition, at least IMPORTANT, never dropped" FAIL

VERIFY_SECTION="$(awk '$0 == "## Verify mode"{f=1;next} f && /^## /{exit} f{print}' "$AGENT_MD")"
printf '%s' "$VERIFY_SECTION" | grep -qF -- 'A failure that needs a mode the code still supports is `real` by step 6 of the review even when committed configuration disables that mode; that configuration may lower the severity you rate by one level, never below IMPORTANT, and never the outcome.' \
  && check "A15 verify mode keeps a deployment-dependent finding real and at least IMPORTANT" PASS \
  || check "A15 verify mode keeps a deployment-dependent finding real and at least IMPORTANT" FAIL

grep -qxF -- '- For `Grep`/`Glob`, always pass the smallest explicit safe repository subtree (for example `src` or `tests`) derived from `changed_files`, or from the code a check below traces from them (callers, entry points, connection setup, configuration, migrations); never omit `path` or search the repository root, because traversal ancestors of `.zensu` and Session Control are denied.' "$AGENT_MD" \
  && check "A16 the search rule admits the subtrees an inherited-guarantee check traces, never the root" PASS \
  || check "A16 the search rule admits the subtrees an inherited-guarantee check traces, never the root" FAIL

echo "----"
echo "test-review-aspect-agent: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
