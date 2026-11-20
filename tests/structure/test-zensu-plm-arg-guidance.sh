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

MAP_FORMS="$(awk '
  /^[[:space:]]*"[a-z][a-z -]*"(\|"[a-z][a-z -]*")*\)/ {
    line = $0
    sub(/^[[:space:]]*"/, "", line)
    label = substr(line, 1, index(line, "\"") - 1)
    group = index($0, "echo") ? "" : label
    if (group == "") print label
    next
  }
  group != "" && /^[[:space:]]*[a-z][a-z-]*\)/ { word = $1; sub(/\)$/, "", word); print group " " word; next }
  group != "" && /esac/ { group = "" }
' "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh")"
catalog_spans() {
  awk '
    /^## Available CLI Commands$/ { on = 1; next }
    /^## / { on = 0 }
    on && index($0, "- `") == 1 {
      rest = $0
      cut = index(rest, " — ")
      if (cut > 0) rest = substr(rest, 1, cut - 1)
      while ((opening = index(rest, "`")) > 0) {
        rest = substr(rest, opening + 1)
        closing = index(rest, "`")
        if (closing == 0) break
        print substr(rest, 1, closing - 1)
        rest = substr(rest, closing + 1)
      }
    }
  ' "$1"
}
CATALOG_SPANS="$(catalog_spans "$AGENT")"
catalog_names() {
  printf '%s\n' "$1" | awk -v prefix="zensu ${2% *} " -v word="${2##* }" '
    index($0, prefix) == 1 {
      verb = substr($0, length(prefix) + 1)
      sub(/ .*/, "", verb)
      n = split(verb, parts, "|")
      for (i = 1; i <= n; i++) if (parts[i] == word) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}
C4_FORMS=0; C4_MISSING=""
while IFS= read -r form; do
  [ -n "$form" ] || continue
  C4_FORMS=$((C4_FORMS+1))
  catalog_names "$CATALOG_SPANS" "$form" || C4_MISSING="$C4_MISSING '$form'"
done <<EOF
$MAP_FORMS
EOF
if [ "$C4_FORMS" -ge 100 ] && [ -z "$C4_MISSING" ]; then
  check "C4 every one of the $C4_FORMS commands the CLI map knows has a catalog line" PASS
else
  check "C4 the catalog lacks a line for a command the CLI map knows ($C4_FORMS read):$C4_MISSING" FAIL
fi
if catalog_names 'zensu work list|get <id>' 'work get' \
  && ! catalog_names 'zensu work order list' 'work list' \
  && ! catalog_names 'zensu work events <id> --kind get' 'work get'; then
  check "C4b the catalog match reads only the word right after the noun, split on |" PASS
else
  check "C4b the catalog match accepts a verb that does not follow the noun" FAIL
fi
C4C_FIXTURE="$(mktemp)" || exit 1
trap 'rm -f "$C4C_FIXTURE"' EXIT
printf '%s\n' \
  '## Available CLI Commands' \
  '- `zensu alpha one <id>` — Show one, then run `zensu beta two`' \
  '- `zensu gamma three` / `zensu gamma four <id>` — Run either command' \
  '## Next' \
  '- `zensu delta five` — A line outside the catalog section' >| "$C4C_FIXTURE"
C4C_SPANS="$(catalog_spans "$C4C_FIXTURE")"
if catalog_names "$C4C_SPANS" 'alpha one' \
  && catalog_names "$C4C_SPANS" 'gamma three' \
  && catalog_names "$C4C_SPANS" 'gamma four' \
  && ! catalog_names "$C4C_SPANS" 'beta two' \
  && ! catalog_names "$C4C_SPANS" 'delta five'; then
  check "C4c a catalog line counts only by the command spans before its description, inside the catalog section" PASS
else
  check "C4c a catalog line counts by a span in its description or outside the catalog section" FAIL
fi

PULSE_START_LINE="$(grep -F -- '- `zensu pulse start`' "$AGENT")"
PULSE_END_LINE="$(grep -F -- '- `zensu pulse end <id>`' "$AGENT")"
DEV_SESSION="$(awk '/^### When the user asks about their dev session$/ { on = 1; next } /^#/ { on = 0 } on' "$AGENT")"
if printf '%s' "$PULSE_START_LINE" | grep -qF -- '--minimal-json' \
  && printf '%s' "$PULSE_START_LINE" | grep -qF 'tracking_disabled' \
  && printf '%s' "$PULSE_END_LINE" | grep -qF -- '--changed-file' \
  && printf '%s' "$PULSE_END_LINE" | grep -qF -- '--minimal-json' \
  && printf '%s' "$DEV_SESSION" | grep -qF '/zensu:pulse' \
  && printf '%s' "$DEV_SESSION" | grep -qF 'tracking_disabled' \
  && grep -qF -- "While Pulse tracking is off in the user's Zensu privacy settings, as it is for every new account until the user turns it on," "$AGENT" \
  && ! grep -qF -- 'When the user turned Pulse tracking off' "$AGENT"; then
  check "C5 the Pulse catalog and the dev-session workflow name --minimal-json and the tracking_disabled no-op, and new accounts start with tracking off" PASS
else
  check "C5 the Pulse catalog or the dev-session workflow lacks --minimal-json, the tracking_disabled no-op or the new-account default" FAIL
fi

source "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
CHANGE_WINDOW="$(sed -n 's/.*--workflow-begin --tools "\([^"]*\)".*/\1/p' "$PLUGIN_DIR/skills/change/SKILL.md")"
C6_WRITES=0; C6_UNDECLARED=""
for verb in $(printf '%s\n' "$MAP_FORMS" | awk '$1 == "roadmap" { print $2 }'); do
  tool="$(zensu_cli_to_tool roadmap "$verb")"
  zensu_is_mutation_tool "$tool" || continue
  C6_WRITES=$((C6_WRITES+1))
  case ",$CHANGE_WINDOW," in
    (*",$tool,"*) ;;
    (*) C6_UNDECLARED="$C6_UNDECLARED $tool" ;;
  esac
done
ROADMAPS="$(awk '/^### Roadmaps & Milestones$/ { on = 1; next } /^#/ { on = 0 } on' "$AGENT")"
if [ "$C6_WRITES" -ge 7 ] && [ -z "$C6_UNDECLARED" ] \
  && printf '%s' "$ROADMAPS" | grep -qF 'Every write below goes through **change** (`/zensu:change`), which declares these writes in its window' \
  && ! printf '%s' "$ROADMAPS" | grep -qiF 'no skill window'; then
  check "C6 the roadmap section sends its $C6_WRITES writes through /zensu:change, whose window declares each" PASS
else
  check "C6 the roadmap section and the /zensu:change window disagree (writes=$C6_WRITES, undeclared:${C6_UNDECLARED:- none})" FAIL
fi

echo "----"
echo "test-zensu-plm-arg-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
