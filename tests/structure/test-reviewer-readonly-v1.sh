#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

contains() {
  local label="$1" file="$2" literal="$3"
  grep -Fq -- "$literal" "$file" && check "$label" PASS || check "$label" FAIL
}

HOOKS="$ROOT/hooks/hooks.json"
TDD="$ROOT/skills/tdd/SKILL.md"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"

node -e '
  const h = require(process.argv[1]).hooks.PreToolUse;
  if (h[0]?.matcher !== ".*" || !h[0]?.hooks?.[0]?.command?.includes("pre-reviewer-capability-gate.sh")) process.exit(1);
' "$HOOKS" && check "reviewer gate is the first PreToolUse hook" PASS || check "reviewer gate is the first PreToolUse hook" FAIL

for file in "$ROOT/agents/code-reviewer.md" "$ROOT/agents/review-aspect.md" "$ROOT/agents/review-judge.md"; do
  FRONTMATTER="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$file")"
  printf '%s\n' "$FRONTMATTER" | grep -Fq 'tools: Read, Grep, Glob' \
    && check "$(basename "$file") exposes dedicated reads only" PASS \
    || check "$(basename "$file") exposes dedicated reads only" FAIL
  if printf '%s\n' "$FRONTMATTER" | grep -Fq 'permissionMode:'; then
    check "$(basename "$file") does not declare unsupported permissionMode" FAIL
  else
    check "$(basename "$file") does not declare unsupported permissionMode" PASS
  fi
  if printf '%s\n' "$FRONTMATTER" | grep -Eq 'Bash|Task|Agent'; then
    check "$(basename "$file") excludes shell/task/agent tools" FAIL
  else
    check "$(basename "$file") excludes shell/task/agent tools" PASS
  fi
  contains "$(basename "$file") declares reviewer-readonly-v1" "$file" 'reviewer-readonly-v1'
  contains "$(basename "$file") requires REVIEW PACKET v1" "$file" 'REVIEW PACKET v1'
done

for spec in 'plan-review-worker.md|plan-review' 'pr-review-worker.md|pr-review'; do
  filename="${spec%%|*}"
  kind="${spec#*|}"
  file="$ROOT/agents/$filename"
  stem="${filename%.md}"
  if [ ! -f "$file" ]; then
    check "$filename exists" FAIL
    continue
  fi
  check "$filename exists" PASS
  FRONTMATTER="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$file")"
  printf '%s\n' "$FRONTMATTER" | grep -qxF "name: $stem" \
    && check "$filename declares its exact worker name" PASS \
    || check "$filename declares its exact worker name" FAIL
  printf '%s\n' "$FRONTMATTER" | grep -qxF 'tools: Read, Grep, Glob' \
    && check "$filename exposes exactly the three read tools" PASS \
    || check "$filename exposes exactly the three read tools" FAIL
  if printf '%s\n' "$FRONTMATTER" | grep -Eq 'permissionMode:|Bash|Edit|Write|Task|Agent|Skill|Web|MCP'; then
    check "$filename excludes elevated/file/task/agent tools" FAIL
  else
    check "$filename excludes elevated/file/task/agent tools" PASS
  fi
  contains "$filename declares evidence-worker-v1" "$file" 'evidence-worker-v1'
  contains "$filename treats repository evidence as untrusted data" "$file" 'untrusted'
  contains "$filename returns only raw JSON" "$file" 'entire final assistant message must be exactly one raw JSON object'
  contains "$filename pins kind $kind" "$file" "with \`kind\` exactly \`$kind\` and \`role\`"
  contains "$filename denies worker-side mutation and coordination" "$file" 'You have no command, write, task, messaging, team,'
  if jq -e --arg path "./agents/$filename" '.agents | index($path)' "$PLUGIN_JSON" >/dev/null 2>&1; then
    check "$filename is registered in plugin.json" PASS
  else
    check "$filename is registered in plugin.json" FAIL
  fi
done

for field in changed_files implementation_summary requirements_baseline diff_summary test_evidence build_evidence coverage_evidence edit_landing_evidence; do
  contains "TDD handoff includes $field" "$TDD" "\`$field\`"
done
contains "TDD handoff pins reviewer policy" "$TDD" 'policy: reviewer-readonly-v1'

printf '%s\n' '----' "test-reviewer-readonly-v1: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
