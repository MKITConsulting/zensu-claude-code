#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-mcp-tools.sh" 2>/dev/null || true
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh" 2>/dev/null || true
source "${CLAUDE_PLUGIN_ROOT}/tests/structure/lib-skill-text.sh" 2>/dev/null || true
CLI_NOUN_ALIASES="$(node -e 'process.stdout.write(Object.entries(require(process.argv[1]).NOUN_ALIASES).map((pair) => pair.join("=")).join(" "))' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-words-v1.js" 2>/dev/null)"
CLI_VERB_ALIASES="$(node -e 'process.stdout.write(Object.entries(require(process.argv[1]).VERB_ALIASES).flatMap(([noun, aliases]) => Object.entries(aliases).map(([alias, verb]) => noun + ":" + alias + "=" + verb)).join(" "))' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-words-v1.js" 2>/dev/null)"

# Flags a skill that calls a Zensu mutation outside the --workflow-begin/-end
# markers. Detects two forms: a `zensu <noun> <verb>` CLI invocation that maps to
# a mutation tool (the primary form post-rehome), and a legacy backticked bare
# mutation tool name. Echoes the offending tool name; silent + return 0 when the
# skill is properly workflow-wrapped.
skill_cli_mutations() {
  local tool
  for tool in $(skill_cli_tools "$1"); do
    if zensu_is_mutation_tool "$tool" && ! zensu_is_work_order_tool "$tool" && ! zensu_is_human_decision_tool "$tool"; then echo "$tool"; fi
  done
}

skill_cli_tools() {
  local f="$1" line rest noun verb third pair
  for line in $(grep -oE 'zensu +[a-z][a-z-]+ +[a-z][a-z-]+( +[a-z][a-z-]+)?' "$f" | sed -E 's/ +/=/g'); do
    rest="${line#zensu=}"; noun="${rest%%=*}"; rest="${rest#*=}"; verb="${rest%%=*}"; third=""
    case "$rest" in *=*) third="${rest#*=}" ;; esac
    for pair in $CLI_NOUN_ALIASES; do
      if [ "${pair%%=*}" = "$noun" ]; then noun="${pair#*=}"; break; fi
    done
    for pair in $CLI_VERB_ALIASES; do
      if [ "${pair%%=*}" = "$noun:$verb" ]; then verb="${pair#*=}"; break; fi
    done
    zensu_cli_to_tool "$noun" "$verb" "$third"
  done
}

skill_unwrapped_mutation() {
  local f="$1" tok tool
  if grep -qF -- '--workflow-begin' "$f" && grep -qF -- '--workflow-end' "$f"; then
    return 0
  fi
  tool="$(skill_cli_mutations "$f" | head -n 1)"
  if [ -n "$tool" ]; then echo "$tool"; return 0; fi
  for tok in $(grep -oE '`[^`]+`' "$f" | grep -oE '[a-z][a-z0-9_]+' | sort -u); do
    if zensu_is_mutation_tool "$tok" && ! zensu_is_work_order_tool "$tok" && ! zensu_is_human_decision_tool "$tok"; then echo "$tok"; return 0; fi
  done
}

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for t in get_feature list_features search_knowledge suggest_workflow analyze_journey_health validate_feature_security ghost_get_candidates pulse_start_session pulse_end_session pulse_session_summary analyze_feature_security generate_threat_model generate_claude_md list_mocks get_mock get_design_context get_automation_policy list_product_repositories list_work_plan_followups; do
  if zensu_is_read_tool "$t" 2>/dev/null && ! zensu_is_mutation_tool "$t" 2>/dev/null; then
    check "T-read $t -> read, not mutation" PASS
  else
    check "T-read $t -> read, not mutation" FAIL
  fi
done

for t in set_security_classification create_feature complete_security_review link_test ghost_apply apply_bootstrap update_feature bootstrap_from_vision create_mock update_journey_step delete_journey_step approve_work_plan set_automation_policy ask_work_order_question push_work_plan; do
  if zensu_is_mutation_tool "$t" 2>/dev/null && ! zensu_is_read_tool "$t" 2>/dev/null; then
    check "T-mut $t -> mutation, not read" PASS
  else
    check "T-mut $t -> mutation, not read" FAIL
  fi
done

if zensu_is_zensu_tool "mcpGate" 2>/dev/null || zensu_is_mutation_tool "hooks" 2>/dev/null; then
  check "T-nontool non-tool token not classified as tool/mutation" FAIL
else
  check "T-nontool non-tool token not classified as tool/mutation" PASS
fi

case " $CLI_NOUN_ALIASES " in
  *" sec=security "*) check "T-alias the CLI noun aliases come from hooks/lib/zensu-cli-words-v1.js" PASS ;;
  *) check "T-alias the CLI noun aliases could not be read from hooks/lib/zensu-cli-words-v1.js (got '$CLI_NOUN_ALIASES')" FAIL ;;
esac
case " $CLI_VERB_ALIASES " in
  *" work:repos=repositories "*) check "T-verbalias the CLI verb aliases come from hooks/lib/zensu-cli-words-v1.js" PASS ;;
  *) check "T-verbalias the CLI verb aliases could not be read from hooks/lib/zensu-cli-words-v1.js (got '$CLI_VERB_ALIASES')" FAIL ;;
esac
VA_FX="$(mktemp -t skillverb-XXXXXX)"
printf 'Run `zensu work pol set p1` here.\n' > "$VA_FX"
VA_PLANTED="$(CLI_VERB_ALIASES="work:pol=policy" skill_cli_tools "$VA_FX")"
VA_BARE="$(CLI_VERB_ALIASES="" skill_cli_tools "$VA_FX")"
rm -f "$VA_FX"
if [ "$VA_PLANTED" = "set_automation_policy" ] && [ -z "$VA_BARE" ]; then
  check "T-verbalias-apply a verb alias in the module's table reaches the map in its canonical spelling" PASS
else
  check "T-verbalias-apply verb alias normalization (planted='$VA_PLANTED' bare='$VA_BARE')" FAIL
fi

FXD="$(mktemp -d -t skillmark-XXXXXX)"
mkdir -p "$FXD/bad"
printf '# bad\n\nStep 1: use `create_feature` to make it.\n' > "$FXD/bad/SKILL.md"
NEG="$(skill_unwrapped_mutation "$FXD/bad/SKILL.md" 2>/dev/null)"
[ -n "$NEG" ] && check "I3-neg unwrapped mutation skill flagged (got '$NEG')" PASS || check "I3-neg unwrapped mutation skill flagged (got '$NEG')" FAIL
rm -rf "$FXD"

FXP="$(mktemp -d -t skillmarkp-XXXXXX)"
mkdir -p "$FXP/good"
printf '# good\n\nFirst run `--workflow-begin`. Step: use `create_feature`. Last run `--workflow-end`.\n' > "$FXP/good/SKILL.md"
POS="$(skill_unwrapped_mutation "$FXP/good/SKILL.md" 2>/dev/null)"
[ -z "$POS" ] && check "I3-pos wrapped mutation skill NOT flagged" PASS || check "I3-pos wrapped skill flagged wrongly (got '$POS')" FAIL
rm -rf "$FXP"

FXR="$(mktemp -d -t skillmarkr-XXXXXX)"
mkdir -p "$FXR/split/references"
printf '# split\n\nRead `references/run.md` at step 1.\n' > "$FXR/split/SKILL.md"
printf '# run\n\nStep 1: use `create_feature` to make it.\n' > "$FXR/split/references/run.md"
REFT="$(skill_text_file "$FXR/split" 2>/dev/null)" || REFT=""
REF=""
[ -n "$REFT" ] && REF="$(skill_unwrapped_mutation "$REFT" 2>/dev/null)"
[ -n "$REFT" ] && rm -f "$REFT"
[ "$REF" = "create_feature" ] && check "I3-ref a mutation moved into references/ is flagged" PASS || check "I3-ref a mutation moved into references/ is flagged (got '$REF')" FAIL
rm -rf "$FXR"

# CLI form (post-rehome): a `zensu <noun> <verb>` mutation call must be detected.
FXC="$(mktemp -d -t skillmarkc-XXXXXX)"
mkdir -p "$FXC/cli"
printf '# cli\n\nStep: run `zensu security classify <feature-id> --classification confidential`.\n' > "$FXC/cli/SKILL.md"
CLI="$(skill_unwrapped_mutation "$FXC/cli/SKILL.md" 2>/dev/null)"
[ "$CLI" = "set_security_classification" ] && check "I3-cli unwrapped CLI mutation flagged (maps via cli-map)" PASS || check "I3-cli CLI mutation flagged (got '$CLI')" FAIL
rm -rf "$FXC"

# CLI form read must NOT be flagged.
FXR="$(mktemp -d -t skillmarkr-XXXXXX)"
mkdir -p "$FXR/read"
printf '# read\n\nStep: run `zensu features get <feature-id>` and `zensu knowledge search --query x`.\n' > "$FXR/read/SKILL.md"
RD="$(skill_unwrapped_mutation "$FXR/read/SKILL.md" 2>/dev/null)"
[ -z "$RD" ] && check "I3-cliread CLI read NOT flagged" PASS || check "I3-cliread CLI read flagged wrongly (got '$RD')" FAIL
rm -rf "$FXR"

# CLI alias noun form must also be detected (sec -> security via normalization).
FXA="$(mktemp -d -t skillmarka-XXXXXX)"
mkdir -p "$FXA/alias"
printf '# alias\n\nStep: run `zensu sec classify <feature-id> --classification confidential`.\n' > "$FXA/alias/SKILL.md"
ALI="$(skill_unwrapped_mutation "$FXA/alias/SKILL.md" 2>/dev/null)"
[ "$ALI" = "set_security_classification" ] && check "I3-clialias alias noun (sec->security) CLI mutation flagged" PASS || check "I3-clialias alias CLI mutation flagged (got '$ALI')" FAIL
rm -rf "$FXA"

SKILL_FAIL=0
for d in "${CLAUDE_PLUGIN_ROOT}"/skills/*/; do
  [ -f "${d}SKILL.md" ] || continue
  F="$(skill_text_file "${d%/}" 2>/dev/null)" || F=""
  if [ -z "$F" ]; then
    SKILL_FAIL=$((SKILL_FAIL+1)); echo "      skill '$(basename "$d")' text could not be read"; continue
  fi
  off="$(skill_unwrapped_mutation "$F")"
  rm -f "$F"
  if [ -n "$off" ]; then
    SKILL_FAIL=$((SKILL_FAIL+1)); echo "      skill '$(basename "$d")' calls mutation tool '$off' but lacks --workflow-begin/--workflow-end"
  fi
done
[ "$SKILL_FAIL" -eq 0 ] && check "I3 every skill calling a mutation tool is workflow-wrapped" PASS || check "I3 unwrapped mutating skills ($SKILL_FAIL)" FAIL

FXH="$(mktemp -d -t skillmarkh-XXXXXX)"
mkdir -p "$FXH/half"
printf '# half\n\nFirst run `--workflow-begin`. Step: use `create_feature`.\n' > "$FXH/half/SKILL.md"
HALF="$(skill_unwrapped_mutation "$FXH/half/SKILL.md" 2>/dev/null)"
[ -n "$HALF" ] && check "I4-half begin-only (missing --workflow-end) flagged" PASS || check "I4-half half-wrapped flagged (got '$HALF')" FAIL
rm -rf "$FXH"

FXS="$(mktemp -d -t skillmarks-XXXXXX)"
mkdir -p "$FXS/sec"
printf '# sec\n\nStep: use `set_security_classification` on the feature.\n' > "$FXS/sec/SKILL.md"
SEC="$(skill_unwrapped_mutation "$FXS/sec/SKILL.md" 2>/dev/null)"
[ "$SEC" = "set_security_classification" ] && check "I4-2nd distinct mutation tool flagged" PASS || check "I4-2nd second tool flagged (got '$SEC')" FAIL
rm -rf "$FXS"

FXM="$(mktemp -d -t skillmarkm-XXXXXX)"
mkdir -p "$FXM/multi"
printf '# multi\n\nStep: call `create_feature(name, component)` to add it.\n' > "$FXM/multi/SKILL.md"
MULTI="$(skill_unwrapped_mutation "$FXM/multi/SKILL.md" 2>/dev/null)"
[ "$MULTI" = "create_feature" ] && check "I4-multi multi-token backtick span flagged" PASS || check "I4-multi multi-token flagged (got '$MULTI')" FAIL
rm -rf "$FXM"

FXT="$(mktemp -d -t skillmarkt-XXXXXX)"
mkdir -p "$FXT/third" "$FXT/mock" "$FXT/order" "$FXT/human"
printf '# third\n\nStep: run `zensu work policy set --product <product-id> --max-attempts 2`.\n' > "$FXT/third/SKILL.md"
printf '# mock\n\nStep: run `zensu mock create <feature-id> <file>`.\n' > "$FXT/mock/SKILL.md"
printf '# order\n\nThe helper sends `zensu work ask <order-id>` and never `zensu work heartbeat <order-id>`.\n' > "$FXT/order/SKILL.md"
THIRD="$(skill_cli_tools "$FXT/third/SKILL.md" 2>/dev/null | grep -v '^$' | head -n 1)"
MOCK="$(skill_unwrapped_mutation "$FXT/mock/SKILL.md" 2>/dev/null)"
ORDER="$(skill_unwrapped_mutation "$FXT/order/SKILL.md" 2>/dev/null)"
printf '# human\n\nTell the user to run `zensu plan approve <plan-id>` or `zensu work policy set --product <product-id>` themselves.\n' > "$FXT/human/SKILL.md"
HUMAN="$(skill_unwrapped_mutation "$FXT/human/SKILL.md" 2>/dev/null)"
[ "$THIRD" = "set_automation_policy" ] && check "I5-third a group verb resolves through its third word" PASS || check "I5-third group verb third word (got '$THIRD')" FAIL
[ "$MOCK" = "create_mock" ] && check "I5-mock the mock alias resolves to mocks" PASS || check "I5-mock alias (got '$MOCK')" FAIL
[ -z "$ORDER" ] && check "I5-order work-order protocol verbs need no skill window" PASS || check "I5-order work-order verbs flagged (got '$ORDER')" FAIL
[ -z "$HUMAN" ] && check "I5-human a decision the person runs needs no skill window" PASS || check "I5-human human-decision verbs flagged (got '$HUMAN')" FAIL
rm -rf "$FXT"

C_FAIL=0
for t in $ZENSU_MUTATION_TOOL_NAMES; do
  zensu_is_read_tool "$t" && { C_FAIL=$((C_FAIL+1)); echo "      mutation '$t' also classifies as a read, so the gate would pass it"; }
done
for t in $ZENSU_HUMAN_DECISION_TOOL_NAMES $ZENSU_WORK_ORDER_TOOL_NAMES; do
  zensu_is_mutation_tool "$t" || { C_FAIL=$((C_FAIL+1)); echo "      '$t' is not in ZENSU_MUTATION_TOOL_NAMES"; }
done
for t in $ZENSU_WORK_ORDER_SESSION_TOOL_NAMES; do
  zensu_is_work_order_tool "$t" || { C_FAIL=$((C_FAIL+1)); echo "      session tool '$t' is not a work-order tool"; }
done
for t in $ZENSU_HUMAN_DECISION_TOOL_NAMES; do
  zensu_is_work_order_tool "$t" && { C_FAIL=$((C_FAIL+1)); echo "      '$t' is both a human decision and a work-order tool"; }
done
[ "$C_FAIL" -eq 0 ] && check "C1 no mutation classifies as a read; human-decision and work-order names are mutations; session names are work-order names; the two families are disjoint" PASS || check "C1 classification invariants ($C_FAIL)" FAIL

M_FAIL=0
for t in $(grep -oE 'echo "[a-z_]+"' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh" | sed -E 's/echo "([a-z_]+)"/\1/' | sort -u); do
  zensu_is_zensu_tool "$t" || { M_FAIL=$((M_FAIL+1)); echo "      the CLI map emits '$t', which is neither a read nor a mutation"; }
done
[ "$M_FAIL" -eq 0 ] && check "C2 every tool the CLI map emits is classified as a read or a mutation" PASS || check "C2 unclassified CLI map outputs ($M_FAIL)" FAIL

D_FAIL=0; W_FAIL=0
for d in "${CLAUDE_PLUGIN_ROOT}"/skills/*/; do
  [ -f "${d}SKILL.md" ] || continue
  F="$(skill_text_file "${d%/}" 2>/dev/null)" || F=""
  [ -n "$F" ] || continue
  declared="$(grep -oE -- '--workflow-begin --tools "[^"]*"' "$F" | sed -E 's/.*"([^"]*)"/\1/' | tr ',\n' '  ')"
  for t in $declared; do
    zensu_is_mutation_tool "$t" || { D_FAIL=$((D_FAIL+1)); echo "      skill '$(basename "$d")' declares '$t', which is not a mutation"; }
    if zensu_is_human_decision_tool "$t" || zensu_is_work_order_tool "$t"; then
      D_FAIL=$((D_FAIL+1)); echo "      skill '$(basename "$d")' declares '$t', which no skill window may let through"
    fi
  done
  if [ -n "$declared" ]; then
    for t in $(skill_cli_mutations "$F" | sort -u); do
      case " $declared " in
        *" $t "*) ;;
        *) W_FAIL=$((W_FAIL+1)); echo "      skill '$(basename "$d")' runs '$t' but its --workflow-begin --tools window does not declare it" ;;
      esac
    done
  fi
  rm -f "$F"
done
[ "$D_FAIL" -eq 0 ] && check "C3 every --workflow-begin --tools declaration names mutations only, and never a human decision or a work-order verb" PASS || check "C3 non-mutation, human-decision or work-order declarations ($D_FAIL)" FAIL
[ "$W_FAIL" -eq 0 ] && check "C4 every CLI mutation a skill with a window runs is declared in that window" PASS || check "C4 undeclared skill mutations ($W_FAIL)" FAIL

WO_VERBS="$(node -e 'process.stdout.write([...require(process.argv[1]).SESSION_WORK_VERBS].join(" "))' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/work-order-v1.js" 2>/dev/null)"
S_FAIL=0; S_SEEN=""
[ -n "$WO_VERBS" ] || { S_FAIL=1; echo "      SESSION_WORK_VERBS could not be read from hooks/lib/work-order-v1.js"; }
for v in $WO_VERBS; do
  t="$(zensu_cli_to_tool work "$v")"
  if zensu_is_read_tool "$t"; then continue; fi
  if zensu_is_work_order_session_tool "$t"; then S_SEEN="$S_SEEN $t"; continue; fi
  S_FAIL=$((S_FAIL+1)); echo "      the work-order gate lets zensu work $v through, but '$t' is neither a read nor a work-order session tool"
done
for t in $ZENSU_WORK_ORDER_SESSION_TOOL_NAMES; do
  case " $S_SEEN " in
    *" $t "*) ;;
    *) S_FAIL=$((S_FAIL+1)); echo "      work-order session tool '$t' is not a verb the work-order gate lets through" ;;
  esac
done
[ "$S_FAIL" -eq 0 ] && check "C5 the write-gate's work-order session tools are exactly the mutations among the verbs the work-order gate lets through" PASS || check "C5 work-order session tools drift from SESSION_WORK_VERBS ($S_FAIL)" FAIL

CLI_MAP="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh"
WO_PLAN_VERBS="$(node -e 'process.stdout.write([...require(process.argv[1]).HUMAN_PLAN_VERBS].join(" "))' "${CLAUDE_PLUGIN_ROOT}/hooks/lib/work-order-v1.js" 2>/dev/null)"
MAP_PLAN_VERBS="$(grep -oE '"plan [a-z-]+"' "$CLI_MAP" | sed -E 's/"plan ([a-z-]+)"/\1/' | sort -u | tr '\n' ' ')"
MAP_THIRDS="$(grep -oE '^[[:space:]]+[a-z-]+\)[[:space:]]+echo' "$CLI_MAP" | sed -E 's/^[[:space:]]+([a-z-]+)\).*/\1/' | sort -u | tr '\n' ' ')"
H_FAIL=0
[ -n "$WO_PLAN_VERBS" ] || { H_FAIL=1; echo "      HUMAN_PLAN_VERBS could not be read from hooks/lib/work-order-v1.js"; }
[ -n "$MAP_PLAN_VERBS" ] && [ -n "$MAP_THIRDS" ] || { H_FAIL=1; echo "      the plan verbs or the group subcommands could not be read from hooks/lib/zensu-cli-map.sh"; }
for v in $(printf '%s\n' $WO_PLAN_VERBS $MAP_PLAN_VERBS | sort -u); do
  human=no
  for third in "" $MAP_THIRDS; do
    zensu_is_human_decision_tool "$(zensu_cli_to_tool plan "$v" "$third")" && human=yes
  done
  listed=no
  case " $WO_PLAN_VERBS " in
    *" $v "*) listed=yes ;;
  esac
  [ "$human" = "$listed" ] || { H_FAIL=$((H_FAIL+1)); echo "      zensu plan $v: records a person's decision=$human, in HUMAN_PLAN_VERBS=$listed"; }
done
[ "$H_FAIL" -eq 0 ] && check "C6 the work-order gate's HUMAN_PLAN_VERBS are exactly the plan verbs that record a person's decision" PASS || check "C6 HUMAN_PLAN_VERBS drift from the human-decision plan tools ($H_FAIL)" FAIL

window_rows() {
  local d f t
  for d in "$1"/skills/*/; do
    [ -f "${d}SKILL.md" ] || continue
    f="$(skill_text_file "${d%/}" 2>/dev/null)" || continue
    for t in $(grep -oE -- '--workflow-begin --tools "[^"]*"' "$f" | sed -E 's/.*"([^"]*)"/\1/' | tr ',\n' '  '); do
      printf '%s %s\n' "$(basename "$d")" "$t"
    done
    rm -f "$f"
  done
}

agent_tools() {
  local t
  for t in $(grep -oE 'echo "[a-z_]+"' "$1" | sed -E 's/echo "([a-z_]+)"/\1/' | LC_ALL=C sort -u); do
    zensu_is_mutation_tool "$t" || continue
    zensu_is_human_decision_tool "$t" && continue
    zensu_is_work_order_tool "$t" && continue
    zensu_tool_in_list "$t" "$ZENSU_AI_WORK_CAPTURE_TOOL_NAMES" && continue
    printf '%s\n' "$t"
  done
}

undeclared_tools() {
  local t
  for t in $2; do
    printf '%s\n' "$1" | grep -q " $t\$" || printf '%s\n' "$t"
  done
}

route_drift() {
  local t routes skill entry known=" $(printf '%s ' $2)"
  for t in $2; do
    routes="$(zensu_tool_routes "$t")" || { printf 'no-route %s\n' "$t"; continue; }
    for skill in ${routes//,/ }; do
      printf '%s\n' "$1" | grep -qxF "$skill $t" || printf 'undeclared-route %s %s\n' "$t" "$skill"
    done
  done
  for entry in $ZENSU_TOOL_ROUTES; do
    case "$known" in
      (*" ${entry%%=*} "*) ;;
      (*) printf 'stale-route %s\n' "${entry%%=*}" ;;
    esac
  done
  for t in $(printf '%s\n' $ZENSU_TOOL_ROUTES | sed 's/=.*//' | LC_ALL=C sort | uniq -d); do
    printf 'duplicate-route %s\n' "$t"
  done
}

WINDOW_ROWS="$(window_rows "$CLAUDE_PLUGIN_ROOT")"
AGENT_TOOLS="$(agent_tools "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh")"
AGENT_N="$(printf '%s\n' "$AGENT_TOOLS" | grep -c .)"
C7_OUT="$(undeclared_tools "$WINDOW_ROWS" "$AGENT_TOOLS")"
if [ "$AGENT_N" -gt 0 ] && [ -n "$WINDOW_ROWS" ] && [ -z "$C7_OUT" ]; then
  check "C7 every agent-runnable mutation the CLI map emits ($AGENT_N tools, without person-only decisions, work-order verbs and AI-work capture) is declared by at least one skill window" PASS
else
  printf '%s\n' "$C7_OUT" | sed 's/^/      no skill window declares /'
  check "C7 agent-runnable mutations without a skill window" FAIL
fi
C8_OUT="$(route_drift "$WINDOW_ROWS" "$AGENT_TOOLS")"
if [ "$AGENT_N" -gt 0 ] && [ -z "$C8_OUT" ]; then
  check "C8 zensu_tool_routes names at least one skill for every agent-runnable mutation, every skill it names declares that tool, and ZENSU_TOOL_ROUTES holds no stale or duplicate entry" PASS
else
  printf '%s\n' "$C8_OUT" | sed 's/^/      /'
  check "C8 the route table drifts from the skill windows" FAIL
fi
C7_BITE="$(undeclared_tools "$(printf '%s\n' "$WINDOW_ROWS" | grep -vxF 'change create_roadmap')" "$AGENT_TOOLS")"
[ "$C7_BITE" = create_roadmap ] \
  && check "C7b dropping create_roadmap from the /zensu:change window makes C7 name it" PASS \
  || check "C7b C7 did not name the dropped window tool (got '$C7_BITE')" FAIL
C8_BITE_MISSING="$(ZENSU_TOOL_ROUTES="${ZENSU_TOOL_ROUTES/create_roadmap=change /}"; route_drift "$WINDOW_ROWS" "$AGENT_TOOLS")"
C8_BITE_WRONG="$(ZENSU_TOOL_ROUTES="${ZENSU_TOOL_ROUTES/create_roadmap=change /create_roadmap=change,bootstrap }"; route_drift "$WINDOW_ROWS" "$AGENT_TOOLS")"
C8_BITE_STALE="$(ZENSU_TOOL_ROUTES="$ZENSU_TOOL_ROUTES retired_tool=change create_mock=change"; route_drift "$WINDOW_ROWS" "$AGENT_TOOLS")"
if [ "$C8_BITE_MISSING" = "no-route create_roadmap" ] \
  && [ "$C8_BITE_WRONG" = "undeclared-route create_roadmap bootstrap" ] \
  && [ "$C8_BITE_STALE" = "$(printf '%s\n' 'stale-route retired_tool' 'duplicate-route create_mock')" ]; then
  check "C8b a dropped route entry, a route to a skill whose window lacks the tool, a stale entry and a duplicate entry each make C8 name it" PASS
else
  check "C8b C8 bites (missing '$C8_BITE_MISSING' wrong '$C8_BITE_WRONG' stale '$C8_BITE_STALE')" FAIL
fi

if command -v node >/dev/null 2>&1; then
  check "AP0 node is available for the argument-placeholder lint" PASS
else
  check "AP0 node is available for the argument-placeholder lint" FAIL
fi

PH_PROBE="$(mktemp -t skillph-XXXXXX)"
cat > "$PH_PROBE" <<'NODE'
'use strict';
const fs = require('fs');

const allowed = new Map();
for (const row of (process.env.PH_ALLOW || '').split('\n')) {
  const cells = row.trim().split(/\s+/);
  if (cells.length === 3) allowed.set(cells[0] + ' ' + cells[1], Number(cells[2]));
}

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const declaredNames = (frontmatter) => {
  const lines = frontmatter.split('\n');
  const at = lines.findIndex((line) => /^arguments\s*:/.test(line));
  if (at < 0) return [];
  const inline = lines[at].replace(/^arguments\s*:\s*/, '').trim();
  let names = [];
  if (inline.startsWith('[')) {
    names = inline.replace(/^\[|\]$/g, '').split(',');
  } else if (inline !== '') {
    names = inline.split(/\s+/);
  } else {
    for (let k = at + 1; k < lines.length; k++) {
      const item = lines[k].match(/^\s*-\s+(.+)$/);
      if (!item) break;
      names.push(item[1]);
    }
  }
  return names
    .map((name) => name.trim().replace(/^["']|["']$/g, ''))
    .filter((name) => name !== '' && !/^\d+$/.test(name));
};

const codeMask = (body) => {
  const mask = new Uint8Array(body.length);
  const blockStart = /^\s*([-*+]\s|\d+[.)]\s|#{1,6}\s|>|\|)/;
  let fence = null;
  let unit = null;
  const closeUnit = () => {
    if (!unit) return;
    const runs = [...body.slice(unit.start, unit.end).matchAll(/`+/g)].map((m) => [m.index, m[0].length]);
    let i = 0;
    while (i < runs.length) {
      let j = i + 1;
      while (j < runs.length && runs[j][1] !== runs[i][1]) j++;
      if (j === runs.length) {
        i++;
      } else {
        mask.fill(1, unit.start + runs[i][0] + runs[i][1], unit.start + runs[j][0]);
        i = j + 1;
      }
    }
    unit = null;
  };
  let start = 0;
  for (const text of body.split('\n')) {
    const end = start + text.length;
    if (fence) {
      const close = text.match(/^\s*(`{3,}|~{3,})\s*$/);
      if (close && close[1][0] === fence.mark && close[1].length >= fence.size) fence = null;
      else mask.fill(1, start, end);
    } else {
      const open = text.match(/^\s*(`{3,}(?=[^`]*$)|~{3,})/);
      if (open) {
        closeUnit();
        fence = { mark: open[1][0], size: open[1].length };
      } else if (text.trim() === '') {
        closeUnit();
      } else if (unit && !blockStart.test(text)) {
        unit.end = end;
      } else {
        closeUnit();
        unit = { start, end };
      }
    }
    start = end + 1;
  }
  closeUnit();
  return mask;
};

const placeholderPatterns = (names) => [
  /\$ARGUMENTS(?:\[\d+\])?/g,
  /\$\d+(?!\w)/g,
  ...names.map((name) => new RegExp('\\$' + escapeRegExp(name) + '(?![\\[\\w])', 'g')),
];

const counts = new Map();
const hits = [];
let scanned = 0;
for (const file of process.argv.slice(2)) {
  const raw = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const front = raw.match(/^---\n([\s\S]*?)\n---(?:\n|$)/);
  const body = front ? raw.slice(front[0].length) : raw;
  const skipped = front ? front[0].split('\n').length - 1 : 0;
  const mask = codeMask(body);
  for (const pattern of placeholderPatterns(front ? declaredNames(front[1]) : [])) {
    for (const m of body.matchAll(pattern)) {
      if (!mask[m.index]) continue;
      const key = file + ' ' + m[0];
      counts.set(key, (counts.get(key) || 0) + 1);
      hits.push([key, file + ':' + (skipped + body.slice(0, m.index).split('\n').length) + ' ' + m[0]]);
    }
  }
  scanned++;
}
for (const [key, where] of hits) {
  if (allowed.get(key) !== counts.get(key)) console.log('HIT ' + where);
}
for (const [key, expected] of allowed) {
  const found = counts.get(key) || 0;
  if (found !== expected) console.log('ALLOW-MISMATCH ' + key + ' expected ' + expected + ' found ' + found);
}
console.log('SCANNED ' + scanned);
NODE

ph_scan() {
  local dir="$1" allow="$2"
  shift 2
  (cd "$dir" && PH_ALLOW="$allow" node "$PH_PROBE" "$@") 2>&1
}

PH_ALLOW='skills/pilot/SKILL.md $ARGUMENTS 1
skills/pr-fix-findings/SKILL.md $ARGUMENTS 2'
PH_SKILLS=()
for d in "${CLAUDE_PLUGIN_ROOT}"/skills/*/; do
  [ -f "${d}SKILL.md" ] || continue
  PH_SKILLS+=("skills/$(basename "$d")/SKILL.md")
done
PH_OUT="$(ph_scan "$CLAUDE_PLUGIN_ROOT" "$PH_ALLOW" ${PH_SKILLS[@]+"${PH_SKILLS[@]}"})"
PH_BAD="$(printf '%s\n' "$PH_OUT" | grep -E '^(HIT|ALLOW-MISMATCH) ')"
PH_SCANNED="$(printf '%s\n' "$PH_OUT" | sed -n 's/^SCANNED //p')"
if [ -z "$PH_BAD" ] && [ "${#PH_SKILLS[@]}" -gt 1 ] && [ "$PH_SCANNED" = "${#PH_SKILLS[@]}" ]; then
  check "AP1 no skill body carries an argument placeholder in a code span or fenced block beyond the allowlist ($PH_SCANNED skills scanned)" PASS
else
  printf '%s\n' "${PH_BAD:-$PH_OUT}" | sed 's/^/      /'
  echo "      pass a value into a shell snippet through a named environment variable, or allowlist a deliberate use in PH_ALLOW"
  check "AP1 skill bodies carry argument placeholders in code (scanned ${PH_SCANNED:-0} of ${#PH_SKILLS[@]})" FAIL
fi

PH_FIX="$(mktemp -d -t skillphfix-XXXXXX)"
ph_fixture() { mkdir -p "$PH_FIX/$1" && cat > "$PH_FIX/$1/SKILL.md"; }
ph_fixture old-probe <<'EOF'
---
name: old-probe
---
Resolve it with `CLAUDE_PROJECT_DIR="$TOP" bash -c 'source "$1/hooks/lib/zensu-config.sh"; zensu_hook_enabled reviewConvergence && echo on || echo off' _ "${CLAUDE_PLUGIN_ROOT}"`.
EOF
ph_fixture env-probe <<'EOF'
---
name: env-probe
---
Resolve it with `ZENSU_ROOT="${CLAUDE_PLUGIN_ROOT}" CLAUDE_PROJECT_DIR="$TOP" bash -c 'source "$ZENSU_ROOT/hooks/lib/zensu-config.sh"; zensu_hook_enabled reviewConvergence && echo on || echo off'`.
EOF
ph_fixture fences <<'EOF'
---
name: fences
---
Run:

```bash
bash -c 'echo "$0"' plugin
```

~~~
gh issue view $ARGUMENTS[2]
~~~
EOF
ph_fixture prose <<'EOF'
---
name: prose
---
Fix issue $ARGUMENTS now and charge $12 for it.
EOF
ph_fixture near-miss <<'EOF'
---
name: near-miss
description: Mentions `$1` in the frontmatter only.
---
Keep `${1}`, `$1abc`, `$12_x`, `$ZENSU_ROOT` and `$issue` as they are.
EOF
ph_fixture edge <<'EOF'
---
name: edge
---
A price in code: `"$12"`.
An escaped one: `\$1`.
A wrapped span: `bash -c 'echo
"$2"'` ends here.
EOF
ph_fixture named <<'EOF'
---
name: named
arguments: [issue, "branch"]
---
Run `gh issue view $issue` on `$branch`, but keep `$issue_id`, `$branchy` and `$issue[0]`.
EOF
ph_fixture named-block <<'EOF'
---
name: named-block
arguments:
  - target
---
Deploy with `deploy $target`.
EOF
ph_fixture consumer <<'EOF'
---
name: consumer
---
Target: `$ARGUMENTS`.
Probe: `bash -c 'echo "$1"' _ x`.
EOF
ph_fixture surplus <<'EOF'
---
name: surplus
---
Target: `$ARGUMENTS`, again `$ARGUMENTS`.
EOF
PH_FX_OUT="$(ph_scan "$PH_FIX" 'consumer/SKILL.md $ARGUMENTS 1
surplus/SKILL.md $ARGUMENTS 1
env-probe/SKILL.md $ARGUMENTS 1' old-probe/SKILL.md env-probe/SKILL.md fences/SKILL.md prose/SKILL.md near-miss/SKILL.md edge/SKILL.md named/SKILL.md named-block/SKILL.md consumer/SKILL.md surplus/SKILL.md)"
ph_has() { printf '%s\n' "$PH_FX_OUT" | grep -qxF -- "$1"; }
ph_quiet() { ! printf '%s\n' "$PH_FX_OUT" | grep -qF -- "HIT $1/"; }
ph_count() { printf '%s\n' "$PH_FX_OUT" | grep -c -- "$1"; }

ph_has 'HIT old-probe/SKILL.md:4 $1' \
  && check "AP2 the pre-fix self-review probe is flagged at its positional parameter" PASS \
  || check "AP2 the pre-fix self-review probe is flagged at its positional parameter" FAIL
ph_quiet env-probe \
  && check "AP3 the probe that passes the plugin root through ZENSU_ROOT is not flagged" PASS \
  || check "AP3 the probe that passes the plugin root through ZENSU_ROOT is not flagged" FAIL
ph_has 'HIT fences/SKILL.md:7 $0' && ph_has 'HIT fences/SKILL.md:11 $ARGUMENTS[2]' \
  && check "AP4 a backtick fence and a tilde fence are scanned" PASS \
  || check "AP4 a backtick fence and a tilde fence are scanned" FAIL
ph_quiet prose \
  && check "AP5 a placeholder in prose stays outside the lint" PASS \
  || check "AP5 a placeholder in prose stays outside the lint" FAIL
ph_quiet near-miss \
  && check "AP6 frontmatter, a braced parameter, a digit run before a word character, an environment variable and an undeclared name are not flagged" PASS \
  || check "AP6 frontmatter, a braced parameter, a digit run before a word character, an environment variable and an undeclared name are not flagged" FAIL
ph_has 'HIT edge/SKILL.md:4 $12' && ph_has 'HIT edge/SKILL.md:5 $1' && ph_has 'HIT edge/SKILL.md:7 $2' \
  && check "AP7 a multi-digit, a backslash-escaped and a two-line code-span placeholder are flagged" PASS \
  || check "AP7 a multi-digit, a backslash-escaped and a two-line code-span placeholder are flagged" FAIL
ph_has 'HIT named/SKILL.md:5 $issue' && ph_has 'HIT named/SKILL.md:5 $branch' && ph_has 'HIT named-block/SKILL.md:6 $target' \
  && [ "$(ph_count '^HIT named')" = 3 ] \
  && check "AP8 declared argument names are flagged, inline and as a block list, and their longer neighbours are not" PASS \
  || check "AP8 declared argument names are flagged, inline and as a block list, and their longer neighbours are not" FAIL
! printf '%s\n' "$PH_FX_OUT" | grep -qF 'HIT consumer/SKILL.md:4 ' && ph_has 'HIT consumer/SKILL.md:5 $1' \
  && [ "$(ph_count '^HIT surplus/SKILL.md:4 \$ARGUMENTS$')" = 2 ] \
  && ph_has 'ALLOW-MISMATCH surplus/SKILL.md $ARGUMENTS expected 1 found 2' \
  && ph_has 'ALLOW-MISMATCH env-probe/SKILL.md $ARGUMENTS expected 1 found 0' \
  && check "AP9 the allowlist is exact per file and token and never excuses another placeholder in the same skill" PASS \
  || check "AP9 the allowlist is exact per file and token and never excuses another placeholder in the same skill" FAIL
ph_has 'SCANNED 10' && [ "$(ph_count '^HIT ')" = 12 ] && [ "$(ph_count '^ALLOW-MISMATCH ')" = 2 ] \
  && check "AP10 the fixture scan reports exactly the expected findings" PASS \
  || { printf '%s\n' "$PH_FX_OUT" | sed 's/^/      /'; check "AP10 the fixture scan reports exactly the expected findings" FAIL; }
rm -rf "$PH_FIX" "$PH_PROBE"

FT_PROBE="$(mktemp -t skillft-XXXXXX)"
cat > "$FT_PROBE" <<'NODE'
'use strict';
const fs = require('fs');
const FREE_TEXT = /markdown|json|document|description|findings|conditions/i;
const ARGUMENT = /--[A-Za-z][\w-]*(?:=|[ \t]+)(["']?)<([^<>\n]+)>\1/g;
let scanned = 0;
for (const file of process.argv.slice(2)) {
  const raw = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
  const front = raw.match(/^---\n([\s\S]*?)\n---(?:\n|$)/);
  const body = front ? raw.slice(front[0].length) : raw;
  const skipped = front ? front[0].split('\n').length - 1 : 0;
  for (const m of body.matchAll(ARGUMENT)) {
    if (!FREE_TEXT.test(m[2])) continue;
    console.log('HIT ' + file + ':' + (skipped + body.slice(0, m.index).split('\n').length) + ' ' + m[0]);
  }
  scanned++;
}
console.log('SCANNED ' + scanned);
NODE

ft_scan() {
  local dir="$1"
  shift
  (cd "$dir" && node "$FT_PROBE" "$@") 2>&1
}

FT_FILES=()
while IFS= read -r ft_file; do
  FT_FILES+=("${ft_file#"$CLAUDE_PLUGIN_ROOT"/}")
done < <(find "$CLAUDE_PLUGIN_ROOT/skills" -type f -name '*.md' | LC_ALL=C sort)
FT_OUT="$(ft_scan "$CLAUDE_PLUGIN_ROOT" ${FT_FILES[@]+"${FT_FILES[@]}"})"
FT_BAD="$(printf '%s\n' "$FT_OUT" | grep -E '^HIT ')"
FT_SCANNED="$(printf '%s\n' "$FT_OUT" | sed -n 's/^SCANNED //p')"
if [ -z "$FT_BAD" ] && [ "${#FT_FILES[@]}" -gt 1 ] && [ "$FT_SCANNED" = "${#FT_FILES[@]}" ]; then
  check "FT1 no skill file passes a Markdown, JSON, document, description or findings placeholder as a quoted or unquoted flag value ($FT_SCANNED files scanned)" PASS
else
  printf '%s\n' "${FT_BAD:-$FT_OUT}" | sed 's/^/      /'
  echo "      write free text to a temporary file through a heredoc with a quoted delimiter and pass \"\$(cat \"\$f\")\""
  check "FT1 skill files pass free-text placeholders on the command line (scanned ${FT_SCANNED:-0} of ${#FT_FILES[@]})" FAIL
fi

FT_MISSING=""
for ft_skill in docs implement bootstrap ghost-scan security-review autopilot change; do
  ft_md="$CLAUDE_PLUGIN_ROOT/skills/$ft_skill/SKILL.md"
  grep -qF "cat >| \"\$f\" <<'ZENSU_TEXT_<hex>'" "$ft_md" && grep -qxF 'ZENSU_TEXT_<hex>' <(sed 's/^ *//' "$ft_md") \
    && grep -qxF "grep -qI '[^[:space:]]' -- \"\$f\" || exit 1" <(sed 's/^ *//' "$ft_md") \
    && grep -qF '"$(cat "$f")"' "$ft_md" && grep -qF "trap 'rm -f \"\$f\"" "$ft_md" \
    || FT_MISSING="$FT_MISSING $ft_skill"
done
[ -z "$FT_MISSING" ] \
  && check "FT2 every skill that uploads free text writes it with >| through a quoted heredoc with a random <hex> delimiter, stops on an empty, blank or binary file and passes \"\$(cat \"\$f\")\"" PASS \
  || check "FT2 skills without the free-text file form (>|, a <hex> delimiter, the content check, the trap and \"\$(cat \"\$f\")\"):$FT_MISSING" FAIL

FT_FIX="$(mktemp -d -t skillftfix-XXXXXX)"
mkdir -p "$FT_FIX/bad" "$FT_FIX/good"
cat > "$FT_FIX/bad/SKILL.md" <<'EOF'
---
name: bad
description: --content "<frontmatter-markdown>"
---
zensu link docs <id> --content "<authored-markdown>"
zensu ghost scan --candidates '<json>'
zensu products vision-create --content <plan-document> --source claude-code
zensu security review <id> --findings="<findings-summary>"
zensu journeys create --product <id> --description "<journey-description>"
EOF
cat > "$FT_FIX/good/SKILL.md" <<'EOF'
---
name: good
---
f="$(mktemp)" || exit 1
cat >| "$f" <<'ZENSU_TEXT_<hex>'
<authored-markdown>
ZENSU_TEXT_<hex>
zensu link docs <feature-id> --title "<title>" --content "$(cat "$f")"
bash "$LOG" --payload '{"headSha":"<sha>"}'
Return the `<markdown>` you authored, never a `<json>` dump.
EOF
FT_FX_OUT="$(ft_scan "$FT_FIX" bad/SKILL.md good/SKILL.md)"
ft_has() { printf '%s\n' "$FT_FX_OUT" | grep -qxF -- "$1"; }
ft_has 'HIT bad/SKILL.md:5 --content "<authored-markdown>"' \
  && ft_has "HIT bad/SKILL.md:6 --candidates '<json>'" \
  && ft_has 'HIT bad/SKILL.md:7 --content <plan-document>' \
  && ft_has 'HIT bad/SKILL.md:8 --findings="<findings-summary>"' \
  && ft_has 'HIT bad/SKILL.md:9 --description "<journey-description>"' \
  && check "FT3 a double-quoted, a single-quoted, an unquoted, an equals-joined and a description free-text placeholder are flagged at their lines" PASS \
  || check "FT3 a double-quoted, a single-quoted, an unquoted, an equals-joined and a description free-text placeholder are flagged at their lines" FAIL
ft_has 'SCANNED 2' && [ "$(printf '%s\n' "$FT_FX_OUT" | grep -c '^HIT ')" = 5 ] \
  && ! printf '%s\n' "$FT_FX_OUT" | grep -qF 'HIT good/' \
  && check "FT4 frontmatter, a heredoc body, a short placeholder, a JSON literal and prose stay outside the lint" PASS \
  || { printf '%s\n' "$FT_FX_OUT" | sed 's/^/      /'; check "FT4 frontmatter, a heredoc body, a short placeholder, a JSON literal and prose stay outside the lint" FAIL; }
rm -rf "$FT_FIX" "$FT_PROBE"

FF_PROBE="$(mktemp -t skillff-XXXXXX)"
cat > "$FF_PROBE" <<'NODE'
'use strict';
const fs = require('fs');
const path = require('path');
const MD = 'renders headings, lists and code, so write structured Markdown, not one unformatted paragraph';
const PLAIN = 'plain text: Zensu does not render Markdown there, so do not use Markdown syntax';
const FILE_FORM = '"$(cat "$';
const SITES = [
  ['skills/bootstrap/SKILL.md', 'with name, slug, and product type', MD, true],
  ['skills/bootstrap/SKILL.md', 'with the structured JSON containing components and features', MD, false],
  ['skills/bootstrap/SKILL.md', 'Rewrite a vague or unformatted description with', MD, true],
  ['skills/bootstrap/SKILL.md', 'Create approved journeys with', MD, true],
  ['skills/bootstrap/SKILL.md', '`--expected-result` are plain text', PLAIN, true],
  ['skills/bootstrap/SKILL.md', 'for each tier (`--tier-order` ascending', PLAIN, true],
  ['skills/ghost-scan/SKILL.md', "A candidate's optional `description`", MD, false],
  ['skills/ghost-scan/SKILL.md', 'per approved journey', MD, true],
  ['skills/ghost-scan/SKILL.md', 'per step (`--title` and a 1-based', PLAIN, true],
  ['skills/ghost-scan/SKILL.md', '`--reject-reason` gives every rejected candidate one reason', PLAIN, true],
  ['skills/ghost-scan/references/cross-component-journeys.md', 'citation into the step `--description`', PLAIN, true],
  ['skills/security-review/SKILL.md', '`--findings`: the findings summary', MD, false],
  ['skills/implement/SKILL.md', '`--scope-details` are plain text', PLAIN, true],
];
const blocksOf = (raw) => {
  const blocks = [];
  let cur = [];
  for (const line of raw.replace(/\r\n/g, '\n').split('\n')) {
    const starts = /^\s*$/.test(line) || /^\s*([-*]|\d+\.)\s/.test(line) || /^#/.test(line) || /^\s*```/.test(line);
    if (starts && cur.length) { blocks.push(cur.join(' ')); cur = []; }
    if (!/^\s*$/.test(line)) cur.push(line.trim());
  }
  if (cur.length) blocks.push(cur.join(' '));
  return blocks;
};
let checked = 0;
for (const [file, anchor, phrase, fileForm] of SITES) {
  const blocks = blocksOf(fs.readFileSync(path.join(process.argv[2], file), 'utf8')).filter((b) => b.includes(anchor));
  const ok = blocks.length === 1 && blocks[0].includes(phrase) && (!fileForm || blocks[0].includes(FILE_FORM));
  if (!ok) console.log('MISS ' + file + ' ' + anchor + ' (blocks=' + blocks.length + ')');
  checked++;
}
console.log('CHECKED ' + checked);
NODE
FF_OUT="$(node "$FF_PROBE" "$CLAUDE_PLUGIN_ROOT" 2>&1)"
if ! printf '%s\n' "$FF_OUT" | grep -q '^MISS ' && printf '%s\n' "$FF_OUT" | grep -qx 'CHECKED 13'; then
  check "FT5 each of the 13 free-text field sites of bootstrap, ghost-scan, security-review and implement states its text format, and each flag site passes its value through the file form" PASS
else
  printf '%s\n' "$FF_OUT" | sed 's/^/      /'
  check "FT5 a free-text field site lost its text-format sentence or its file form" FAIL
fi
rm -f "$FF_PROBE"

ft6_scan() {
  grep -rnF --include='*.md' 'ZENSU_TEXT_END' "$1" | sed 's/^/FIXED /'
  grep -rnE --include='*.md' 'cat[[:space:]]+>[[:space:]]*"\$[A-Za-z_][A-Za-z0-9_]*"[[:space:]]*<<' "$1" | sed 's/^/PLAIN /'
  grep -rnE --include='*.md' '\[ -s "\$[A-Za-z_][A-Za-z0-9_]*" \] \|\| exit 1' "$1" | sed 's/^/WEAK /'
}
FT6_OUT="$(ft6_scan "$CLAUDE_PLUGIN_ROOT/skills")"
FT6_FIX="$(mktemp -d -t skillft6-XXXXXX)"
mkdir -p "$FT6_FIX/old" "$FT6_FIX/new"
printf '%s\n' 'f="$(mktemp)" || exit 1' "cat > \"\$f\" <<'ZENSU_TEXT_END'" '<text>' 'ZENSU_TEXT_END' '[ -s "$f" ] || exit 1' > "$FT6_FIX/old/SKILL.md"
printf '%s\n' 'f="$(mktemp)" || exit 1' "cat >| \"\$f\" <<'ZENSU_TEXT_<hex>'" '<text>' 'ZENSU_TEXT_<hex>' "grep -qI '[^[:space:]]' -- \"\$f\" || exit 1" > "$FT6_FIX/new/SKILL.md"
FT6_OLD="$(ft6_scan "$FT6_FIX/old")"
FT6_NEW="$(ft6_scan "$FT6_FIX/new")"
rm -rf "$FT6_FIX"
if [ -z "$FT6_OUT" ] && [ "$(printf '%s\n' "$FT6_OLD" | grep -c '^FIXED ')" = 2 ] \
  && [ "$(printf '%s\n' "$FT6_OLD" | grep -c '^PLAIN ')" = 1 ] \
  && [ "$(printf '%s\n' "$FT6_OLD" | grep -c '^WEAK ')" = 1 ] && [ -z "$FT6_NEW" ]; then
  check "FT6 no skill file spells the fixed delimiter ZENSU_TEXT_END, writes a heredoc into a temporary file with a plain > or checks it with the weaker [ -s ], and a fixture with all three is flagged" PASS
else
  printf '%s\n' "$FT6_OUT" | sed 's/^/      /'
  check "FT6 a skill file keeps the fixed delimiter, a plain > heredoc write or the weaker [ -s ] check (fixture old='$FT6_OLD' new='$FT6_NEW')" FAIL
fi

FT7_MD="$CLAUDE_PLUGIN_ROOT/skills/bootstrap/SKILL.md"
if grep -qxF "[ -f \"\$p\" ] && grep -qI '[^[:space:]]' -- \"\$p\" || exit 1" <(sed 's/^ *//' "$FT7_MD") \
  && grep -qF -- '--content "$(cat "$p")"' "$FT7_MD" && ! grep -qF '"~/' "$FT7_MD"; then
  check "FT7 bootstrap passes a plan file by path only after its regular-file and content check, and spells no ~/ path inside double quotes" PASS
else
  check "FT7 bootstrap's by-path plan form lacks its regular-file and content check, or spells a ~/ path inside double quotes" FAIL
fi

echo "----"
echo "test-skill-workflow-markers: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
