#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/change"
SKILL_MD="$SKILL_DIR/SKILL.md"
COMMANDS_MD="$SKILL_DIR/references/commands.md"
CLI_MAP="$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
source "$PLUGIN_DIR/hooks/lib/zensu-mcp-tools.sh"
source "$CLI_MAP"

ONBOARDING_TOOLS="create_product create_product_vision bootstrap_from_vision apply_bootstrap update_bootstrap_step ghost_scan ghost_apply ghost_batch_review complete_security_review"
CONFIRM_COMMANDS="features deprecate|features merge|features split|subfeatures promote|roadmap delete|roadmap milestone-delete|journeys step-delete|tiers set-feature"
CREATE_COMMANDS="features create|features revision|features merge|features split|subfeatures add|roadmap create|roadmap milestone-create|tiers create|journeys create|journeys step|mocks create|wiki create"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-change-skill: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
}

if [ ! -f "$SKILL_MD" ] || [ ! -f "$COMMANDS_MD" ]; then
  check "S0 skills/change/SKILL.md and skills/change/references/commands.md exist" FAIL
  finish
fi
check "S0 skills/change/SKILL.md and skills/change/references/commands.md exist" PASS

FRONT="$(awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f' "$SKILL_MD")"
if printf '%s\n' "$FRONT" | grep -qx 'name: change' \
  && printf '%s\n' "$FRONT" | grep -qx 'description: >' \
  && printf '%s\n' "$FRONT" | grep -qE '^  \[Zensu\] ' \
  && printf '%s\n' "$FRONT" | tr '\n' ' ' | grep -qF 'Use when'; then
  check "S1 frontmatter names the skill change and folds a [Zensu] description that says when to use it" PASS
else
  check "S1 frontmatter of skills/change/SKILL.md" FAIL
fi

node -e '
  const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.exit((p.skills || []).includes("./skills/change") ? 0 : 1);
' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null \
  && check "S2 .claude-plugin/plugin.json registers ./skills/change" PASS \
  || check "S2 .claude-plugin/plugin.json registers ./skills/change" FAIL

grep -qE '^\| `/zensu:change` \|' "$PLUGIN_DIR/README.md" \
  && check "S3 README.md lists /zensu:change in a skill table" PASS \
  || check "S3 README.md lists /zensu:change in a skill table" FAIL

DECLARED="$(grep -oE -- '--workflow-begin --tools "[^"]*"' "$SKILL_MD" | sed -E 's/.*"([^"]*)"/\1/' | tr ',' '\n' | grep -v '^$' | LC_ALL=C sort)"
EXPECTED=""
for t in $(grep -oE 'echo "[a-z_]+"' "$CLI_MAP" | sed -E 's/echo "([a-z_]+)"/\1/' | LC_ALL=C sort -u); do
  zensu_is_mutation_tool "$t" || continue
  zensu_is_human_decision_tool "$t" && continue
  zensu_is_work_order_tool "$t" && continue
  zensu_tool_in_list "$t" "$ZENSU_AI_WORK_CAPTURE_TOOL_NAMES" && continue
  zensu_tool_in_list "$t" "$ONBOARDING_TOOLS" && continue
  EXPECTED="$EXPECTED$t
"
done
EXPECTED="$(printf '%s' "$EXPECTED" | LC_ALL=C sort)"
if [ "$(grep -cF -- '--workflow-begin --tools "' "$SKILL_MD")" = 1 ] && [ -n "$DECLARED" ] && [ "$DECLARED" = "$EXPECTED" ]; then
  check "S4 the one window declares exactly the agent-runnable mutations the CLI map emits, without the onboarding flows and the security-review terminus ($(printf '%s\n' "$DECLARED" | wc -l | tr -d ' ') tools)" PASS
else
  diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$DECLARED") | sed 's/^/      /'
  check "S4 the window of /zensu:change drifts from the agent-runnable mutations of the CLI map (< expected, > declared)" FAIL
fi

STEP_WINDOW="$(awk '/^### Step 5/ { f = 1 } /^### Step 6/ { f = 0 } f' "$SKILL_MD")"
STEP7="$(awk '/^### Step 7/ { f = 1 } /^### Step 8/ { f = 0 } f' "$SKILL_MD")"
if printf '%s' "$STEP_WINDOW" | grep -qF -- '--workflow-begin --tools "' \
  && printf '%s' "$STEP_WINDOW" | grep -qF 'as its own Bash call, with no `zensu` call in the same command' \
  && printf '%s' "$STEP_WINDOW" | grep -qF 'after Steps 2 to 4 resolved every ID and received every answer' \
  && printf '%s' "$STEP7" | grep -qF -- '--workflow-end' \
  && printf '%s' "$STEP7" | grep -qF 'also after an early stop'; then
  check "S5 the window opens in a Bash call of its own only after the reads and questions of Steps 2 to 4, and closes on every way out, an early stop included" PASS
else
  check "S5 the window open/close steps lost their order, own-call or every-exit rule" FAIL
fi

ROWS="$(node -e '
  const lines = require("fs").readFileSync(process.argv[1], "utf8").split("\n");
  for (const line of lines) {
    if (!/^\| /.test(line) || /^\|\s*-/.test(line) || /^\| Change \|/.test(line)) continue;
    const cells = line.replace(/^\|\s*/, "").replace(/\s*\|\s*$/, "").split(/\s+\|\s+/);
    if (cells.length !== 4) { console.log("BAD|" + line.replace(/\|/g, " ")); continue; }
    const cmd = cells[1].match(/`zensu ([a-z][a-z-]*) ([a-z][a-z-]*)(?: ([a-z][a-z-]*))?/);
    const tool = cells[2].replace(/`/g, "").trim();
    const conv = cells[3];
    const dup = /^duplicate check: /.test(conv) ? "duplicate" : "";
    const conf = /(?:^|; )confirm: /.test(conv) ? "confirm" : "";
    const read = dup ? conv.match(/^duplicate check: `zensu ([a-z][a-z-]*) ([a-z][a-z-]*)/) : null;
    console.log([cmd ? cmd[1] : "", cmd ? cmd[2] : "", cmd && cmd[3] ? cmd[3] : "", tool, dup, conf, read ? read[1] : "", read ? read[2] : ""].join("|"));
  }
' "$COMMANDS_MD" 2>/dev/null)"
ROW_BAD=""; ROW_TOOLS=""; CONFIRM_SEEN=""; CREATE_SEEN=""; READ_BAD=""
while IFS="|" read -r noun verb third tool dup conf rnoun rverb; do
  [ -n "$noun$verb$tool" ] || continue
  if [ "$noun" = BAD ] || [ -z "$noun" ]; then ROW_BAD="$ROW_BAD [unreadable row]"; continue; fi
  mapped="$(zensu_cli_to_tool "$noun" "$verb" "$third")"
  [ "$mapped" = "$tool" ] || ROW_BAD="$ROW_BAD [zensu $noun $verb${third:+ $third} maps to '$mapped', row says '$tool']"
  ROW_TOOLS="$ROW_TOOLS
$tool"
  [ -n "$conf" ] && CONFIRM_SEEN="$CONFIRM_SEEN|$noun $verb"
  if [ -n "$dup" ]; then
    CREATE_SEEN="$CREATE_SEEN|$noun $verb"
    read_tool="$(zensu_cli_to_tool "$rnoun" "$rverb")"
    { [ -n "$read_tool" ] && zensu_is_read_tool "$read_tool"; } || READ_BAD="$READ_BAD [zensu $noun $verb: '$rnoun $rverb' is no read]"
  fi
done <<EOF
$ROWS
EOF
ROW_TOOLS="$(printf '%s\n' "$ROW_TOOLS" | grep -v '^$' | LC_ALL=C sort -u)"
if [ -z "$ROW_BAD" ] && [ -n "$ROW_TOOLS" ] && [ "$ROW_TOOLS" = "$DECLARED" ]; then
  check "S6 every row of the command table maps to the tool it names, and the table covers exactly the declared window" PASS
else
  [ "$ROW_TOOLS" = "$DECLARED" ] || diff <(printf '%s\n' "$DECLARED") <(printf '%s\n' "$ROW_TOOLS") | sed 's/^/      /'
  check "S6 command table drifts from the CLI map or the window:$ROW_BAD" FAIL
fi

sorted_set() { printf '%s\n' "$1" | tr '|' '\n' | grep -v '^$' | LC_ALL=C sort -u; }
STEP_CONFIRM="$(awk '/^### Step 4/ { f = 1 } /^### Step 5/ { f = 0 } f' "$SKILL_MD")"
STEP_CONFIRM_BAD=""
OLDIFS="$IFS"; IFS='|'
for c in $CONFIRM_COMMANDS; do
  printf '%s' "$STEP_CONFIRM" | grep -qF "\`zensu $c\`" || STEP_CONFIRM_BAD="$STEP_CONFIRM_BAD [$c]"
done
IFS="$OLDIFS"
if [ "$(sorted_set "$CONFIRM_SEEN")" = "$(sorted_set "$CONFIRM_COMMANDS")" ] && [ -z "$STEP_CONFIRM_BAD" ] \
  && printf '%s' "$STEP_CONFIRM" | grep -qF 'ask with AskUserQuestion' \
  && printf '%s' "$STEP_CONFIRM" | grep -qF 'names the entity' \
  && printf '%s' "$STEP_CONFIRM" | grep -qF 'the consequence from the row' \
  && printf '%s' "$STEP_CONFIRM" | grep -qF 'Run the command only after "Yes, run it"' \
  && printf '%s' "$STEP_CONFIRM" | grep -qF 'replaces every tier assignment' \
  && printf '%s' "$STEP_CONFIRM" | grep -qF 'copy every entry the feature keeps into the new `--tiers` list unchanged'; then
  check "S7 exactly the removing or replacing commands of D4(b) carry a confirm row, and Step 4 asks for each one by name with the entity and the consequence before it runs" PASS
else
  check "S7 confirmation pin broken (rows: $(sorted_set "$CONFIRM_SEEN" | tr '\n' ',') step 4 missing:${STEP_CONFIRM_BAD:- none})" FAIL
fi

STEP_DUP="$(awk '/^### Step 3/ { f = 1 } /^### Step 4/ { f = 0 } f' "$SKILL_MD")"
if [ "$(sorted_set "$CREATE_SEEN")" = "$(sorted_set "$CREATE_COMMANDS")" ] && [ -z "$READ_BAD" ] \
  && printf '%s' "$STEP_DUP" | grep -qF 'compare the new title and slug with every entry it returns' \
  && printf '%s' "$STEP_DUP" | grep -qF "compare the merged feature's \`--title\` and \`--slug\` and each child's \`title\` and \`slug\` the same way" \
  && printf '%s' "$STEP_DUP" | grep -qF 'On a match, do not create'; then
  check "S8 every create command, merge and split included, carries a duplicate check through a list read before any confirmation, and Step 3 compares title and slug and stops on a match" PASS
else
  check "S8 duplicate-check pin broken (rows: $(sorted_set "$CREATE_SEEN" | tr '\n' ',')${READ_BAD})" FAIL
fi

STEP6="$(awk '/^### Step 6/ { f = 1 } /^### Step 7/ { f = 0 } f' "$SKILL_MD")"
S9="$(printf '%s' "$STEP6" | node -e '
  const t = require("fs").readFileSync(0, "utf8");
  const a = t.indexOf("After `zensu features create`");
  const b = t.indexOf("`zensu features update <feature-id> --priority <priority> --description \"$(cat \"$f\")\"`");
  const c = t.indexOf("`zensu security classify <feature-id> --classification <level>`");
  process.stdout.write(a !== -1 && a < b && b < c && /structured Markdown/.test(t) && /report each result/.test(t) ? "ok" : "bad");
')"
[ "$S9" = ok ] \
  && check "S9 after features create the skill sets priority and a Markdown description, then the classification, and reports each" PASS \
  || check "S9 the features create follow-ups lost their order or their report" FAIL

ONB_BAD=""
for t in $DECLARED; do
  zensu_tool_in_list "$t" "$ONBOARDING_TOOLS" && ONB_BAD="$ONB_BAD $t"
done
STRAY="$(grep -ohE 'zensu +(products +(create|vision-create|bootstrap-apply|bootstrap-step)|ghost +(scan|apply|batch)|security +review)' "$SKILL_MD" "$COMMANDS_MD" | sort -u | tr '\n' ',')"
[ -z "$ONB_BAD" ] && [ -z "$STRAY" ] \
  && check "S10 the skill neither declares nor names an onboarding command or the security-review terminus" PASS \
  || check "S10 onboarding leak (declared:${ONB_BAD:- none} named: ${STRAY:-none})" FAIL

grep -qF 'Never answer a deny with the `ZENSU_MCP_GATE=off` prefix' "$SKILL_MD" \
  && ! grep -qE 'ZENSU_MCP_GATE=off +zensu' "$SKILL_MD" "$COMMANDS_MD" \
  && check "S11 the skill forbids the inline gate escape and never uses it" PASS \
  || check "S11 the skill uses or allows the inline gate escape" FAIL

RULES="$(awk '/^## Rules/ { f = 1 } f' "$SKILL_MD")"
if printf '%s' "$RULES" | grep -qF 'One window per session, never nested' \
  && printf '%s' "$RULES" | grep -qF "While another skill's window is open, do not run this skill" \
  && printf '%s' "$RULES" | grep -qF 'ends the run before Step 5: run no command, and report the change as one that needs a person'; then
  check "S12 the rules forbid a window over another skill's window and end a run that cannot get an answer before the window opens" PASS
else
  check "S12 the nested-window or no-answer rule is missing from the Rules" FAIL
fi

finish
