#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN_DIR/agents/zensu-plm.md"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$AGENT" ]; then
  check "agents/zensu-plm.md exists" FAIL
  echo "test-zensu-plm-arg-guidance: $PASS PASS / $FAIL FAIL"
  exit 1
fi

FRONTMATTER="$(awk 'NR == 1 && $0 == "---" { active = 1; next } active && $0 == "---" { exit } active { print }' "$AGENT")"
if [ "$(printf '%s\n' "$FRONTMATTER" | grep -cxF 'tools: Read, Grep, Glob')" -eq 1 ]; then
  check "C0 read-only role exposes exactly Read, Grep, and Glob" PASS
else
  check "C0 read-only role exposes exactly Read, Grep, and Glob" FAIL
fi

CP_LINE="$(grep -F 'products create` — Create a new product' "$AGENT" 2>/dev/null)"
if printf '%s' "$CP_LINE" | grep -qF -- '--slug' && printf '%s' "$CP_LINE" | grep -qF -- '--name'; then
  check "C1 create_product entry names required --name + --slug flags" PASS
else
  check "C1 create_product entry names required --name + --slug flags" FAIL
fi

RULE_LINE="$(grep -iF 'kebab-case' "$AGENT" 2>/dev/null)"
if printf '%s' "$RULE_LINE" | grep -qF -- '--slug' && printf '%s' "$RULE_LINE" | grep -qiF 'required'; then
  check "C2 CLI flag rule present (kebab-case + --slug + required on one line)" PASS
else
  check "C2 CLI flag rule present (kebab-case + --slug + required on one line)" FAIL
fi

source "$PLUGIN_DIR/hooks/lib/zensu-mcp-tools.sh"
source "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
plm_marked() {
  awk -v prefix="$1 " -v word="$2" -v mark="$3" '
    index($0, "- `") == 1 {
      span = substr($0, 4)
      end = index(span, "`")
      if (end == 0) next
      span = substr(span, 1, end - 1)
      if (index(span, prefix) != 1) next
      n = split(substr(span, length(prefix) + 1), parts, /[ |]/)
      for (i = 1; i <= n; i++) if (parts[i] == word && index($0, mark) > 0) found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$AGENT"
}
MARK_ROWS="work|create|
work|approve|
work|requeue|
work|cancel|
work|confirm-merge|
work|answer|
work|overturn|
work|policy|set
work|repositories|add
work|repositories|update
work|repositories|remove
plan|push|
plan|approve|
plan|finalize|
plan|abandon|
plan|confirm-merge|
plan|followup|accept
plan|followup|dismiss
work|claim|
work|confirm|
work|release|
work|usage|
work|heartbeat|
work|event|
work|ask|
work|followup|"
M_FAIL=0; M_SEEN=" "
while IFS='|' read -r noun verb third; do
  [ -n "$noun" ] || continue
  tool="$(zensu_cli_to_tool "$noun" "$verb" "$third")"
  if [ -n "$third" ]; then prefix="zensu $noun $verb"; word="$third"; else prefix="zensu $noun"; word="$verb"; fi
  M_SEEN="$M_SEEN$tool "
  if zensu_is_human_decision_tool "$tool"; then
    plm_marked "$prefix" "$word" "**person**" || { M_FAIL=$((M_FAIL+1)); echo "      no catalog line for '$prefix' names '$word' and marks it **person** ($tool)"; }
  elif zensu_is_work_order_tool "$tool"; then
    plm_marked "$prefix" "$word" "**worker**" || plm_marked "$prefix" "$word" "**session**" || { M_FAIL=$((M_FAIL+1)); echo "      no catalog line for '$prefix' names '$word' and marks it **worker** or **session** ($tool)"; }
  else
    M_FAIL=$((M_FAIL+1)); echo "      '$prefix $word' maps to '$tool', which is neither a human decision nor a work-order verb"
  fi
done <<EOF
$MARK_ROWS
EOF
for t in $ZENSU_HUMAN_DECISION_TOOL_NAMES $ZENSU_WORK_ORDER_TOOL_NAMES; do
  case "$M_SEEN" in
    (*" $t "*) ;;
    (*) M_FAIL=$((M_FAIL+1)); echo "      '$t' has no row in MARK_ROWS, so its catalog mark goes unchecked" ;;
  esac
done
[ "$M_FAIL" -eq 0 ] && check "C3 every human-decision verb is marked **person** and every work-order verb **worker** or **session** in the catalog" PASS || check "C3 catalog marks drift from the classification lists ($M_FAIL)" FAIL

echo "----"
echo "test-zensu-plm-arg-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
