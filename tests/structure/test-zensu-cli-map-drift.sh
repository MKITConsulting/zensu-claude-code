#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TREE="$PLUGIN_DIR/tests/structure/fixtures/zensu-cli-tree.txt"
RECORDER="$PLUGIN_DIR/tests/structure/fixtures/record-zensu-cli-tree.sh"
GATE_BODY="$PLUGIN_DIR/hooks/checks/pre-bash-zensu-gate.sh"
source "$PLUGIN_DIR/hooks/lib/zensu-mcp-tools.sh"
source "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"

NEUTRAL_GROUPS="auth completion help"
INTENTIONALLY_UNMAPPED="meta scaffold-agent"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

GATE_SETS="$(node -e '
  const text = require("fs").readFileSync(process.argv[1], "utf8");
  const alias = text.match(/const ALIAS = \{([^}]*)\};/);
  const nouns = text.match(/const NOUNS = new Set\("([^"]*)"\.split\(" "\)\);/);
  const groups = text.match(/const GROUPS = new Set\(\[([^\]]*)\]\);/);
  if (!alias || !nouns || !groups) process.exit(3);
  const out = [];
  for (const m of alias[1].matchAll(/(?:"([^"]+)"|([A-Za-z-]+)):"([^"]+)"/g)) out.push("alias " + (m[1] || m[2]) + " " + m[3]);
  for (const n of nouns[1].split(" ")) if (n) out.push("noun " + n);
  for (const m of groups[1].matchAll(/"([^"]*)"/g)) out.push("group " + m[1].replace(/\\t/g, " "));
  process.stdout.write(out.join("\n"));
' "$GATE_BODY" 2>/dev/null)"
GATE_STATUS=$?

gate_has() { printf '%s\n' "$GATE_SETS" | grep -qxF -- "$1"; }
neutral() { case " $NEUTRAL_GROUPS " in (*" $1 "*) return 0 ;; esac; return 1; }
intentionally_unmapped() { [ "$1" = "$INTENTIONALLY_UNMAPPED" ]; }

leaf_scan() {
  local g="${1:-}" v="${2:-}" s="${3:-}"
  neutral "$g" && return 0
  gate_has "noun $g" || echo "group-not-parsed $g"
  [ -n "$v" ] || { echo "group-without-verbs $g"; return 0; }
  [ "$#" -le 3 ] || { echo "leaf-too-deep $*"; return 0; }
  intentionally_unmapped "$*" && return 0
  [ -n "$(zensu_cli_to_tool "$g" "$v" "$s")" ] || echo "unmapped $*"
  [ -z "$s" ] || gate_has "group $g $v" || echo "group-not-in-GROUPS $g $v"
}

alias_scan() {
  local tree="$1" g="${2:-}" v line sub
  shift
  neutral "$g" && return 0
  case "$#" in
    (2)
      gate_has "alias $2 $g" || echo "alias-not-in-ALIAS $2 $g"
      gate_has "noun $2" || echo "alias-not-in-NOUNS $2"
      ;;
    (3)
      v="$2"
      while IFS= read -r line; do
        sub="$(printf '%s\n' "$line" | awk '{ print $4 }')"
        [ "$(zensu_cli_to_tool "$g" "$v" "$sub")" = "$(zensu_cli_to_tool "$g" "$3" "$sub")" ] || echo "verb-alias-unmapped $g $3${sub:+ $sub}"
      done <<EOF
$(grep -E "^leaf $g $v( |\$)" "$tree")
EOF
      if gate_has "group $g $v"; then gate_has "group $g $3" || echo "alias-not-in-GROUPS $g $3"; fi
      ;;
    (4)
      [ "$(zensu_cli_to_tool "$g" "$2" "$3")" = "$(zensu_cli_to_tool "$g" "$2" "$4")" ] || echo "verb-alias-unmapped $g $2 $4"
      ;;
    (*) echo "alias-too-deep $*" ;;
  esac
}

drift_scan() {
  local tree="$1" line kind
  set -f
  while IFS= read -r line; do
    set -- $line
    kind="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$kind" in
      (version|'') ;;
      (leaf) leaf_scan "$@" ;;
      (alias) alias_scan "$tree" "$@" ;;
      (*) echo "unreadable-line $line" ;;
    esac
  done < "$tree"
  set +f
}

[ "$GATE_STATUS" -eq 0 ] && gate_has "noun features" && gate_has "alias sec security" && gate_has "group work policy" \
  && check "Z0 the gate's NOUNS, ALIAS and GROUPS sets are read from hooks/checks/pre-bash-zensu-gate.sh" PASS \
  || check "Z0 the gate's NOUNS, ALIAS and GROUPS sets could not be read (status $GATE_STATUS)" FAIL

TREE_VERSION="$(sed -n 's/^version //p' "$TREE" 2>/dev/null | head -n 1)"
TREE_LEAVES="$(grep -c '^leaf ' "$TREE" 2>/dev/null)"
if [ -n "$TREE_VERSION" ] && [ "${TREE_LEAVES:-0}" -ge 100 ]; then
  check "Z1 the recorded command tree names zensu-cli $TREE_VERSION and holds $TREE_LEAVES leaves" PASS
else
  check "Z1 the recorded command tree is missing or too small (version '$TREE_VERSION', ${TREE_LEAVES:-0} leaves)" FAIL
fi

DRIFT="$(drift_scan "$TREE" | awk '!seen[$0]++')"
if [ -z "$DRIFT" ]; then
  check "Z2 every leaf, group alias and verb alias of zensu-cli $TREE_VERSION outside auth, completion and help is mapped, parsed and grouped the way the gate reads it" PASS
else
  printf '%s\n' "$DRIFT" | sed 's/^/      /'
  check "Z2 the gate drifts from the recorded command tree of zensu-cli $TREE_VERSION; map each new leaf in hooks/lib/zensu-cli-map.sh and classify its tool, or list it as intentionally unmapped here" FAIL
fi

if grep -qxF "leaf $INTENTIONALLY_UNMAPPED" "$TREE" && [ -z "$(zensu_cli_to_tool meta scaffold-agent)" ]; then
  check "Z3 the intentionally unmapped leaf ($INTENTIONALLY_UNMAPPED) is still in the tree and still maps to nothing" PASS
else
  check "Z3 the intentionally unmapped entry is stale: drop it or remove its map entry" FAIL
fi

FIX="$(mktemp -t zensu-cli-tree-XXXXXX)"
cat > "$FIX" <<'TREE'
version 9.9.9
leaf features create
leaf features teleport
leaf wiki snapshots take
alias features feat
alias work policy pol
leaf work policy get
leaf meta scaffold-agent
leaf auth login
alias auth au
TREE
GOT="$(drift_scan "$FIX" | LC_ALL=C sort)"
WANT="$(printf '%s\n' 'alias-not-in-ALIAS feat features' 'alias-not-in-GROUPS work pol' 'alias-not-in-NOUNS feat' 'group-not-in-GROUPS wiki snapshots' 'unmapped features teleport' 'unmapped wiki snapshots take' 'verb-alias-unmapped work pol get' | LC_ALL=C sort)"
rm -f "$FIX"
if [ "$GOT" = "$WANT" ]; then
  check "Z4 a tree with an unmapped leaf, an unread group, an unknown alias and an unread verb alias fails and names each one, while the exempt and neutral lines stay quiet" PASS
else
  printf '%s\n' "$GOT" | sed 's/^/      got: /'
  check "Z4 the drift scan did not name exactly the planted drift" FAIL
fi

LOCAL_ZENSU="$(command -v zensu 2>/dev/null || true)"
case "$LOCAL_ZENSU" in
  (/*) LOCAL_VERSION="$(ZENSU_NO_UPDATE_CHECK=1 "$LOCAL_ZENSU" --version 2>/dev/null </dev/null | awk 'NR == 1 { print $2 }')" ;;
  (*) LOCAL_VERSION="" ;;
esac
if [ -n "$LOCAL_VERSION" ] && [ "$LOCAL_VERSION" = "$TREE_VERSION" ]; then
  if [ "$(bash "$RECORDER" "$LOCAL_ZENSU" 2>/dev/null)" = "$(cat "$TREE")" ]; then
    check "Z5 the recorder reproduces the recorded tree from the installed zensu-cli $LOCAL_VERSION" PASS
  else
    check "Z5 the recorded tree differs from what the recorder prints for zensu-cli $LOCAL_VERSION; re-record it with tests/structure/fixtures/record-zensu-cli-tree.sh" FAIL
  fi
else
  echo "  SKIP  Z5 no installed zensu-cli $TREE_VERSION to re-record from (found '${LOCAL_VERSION:-none}')"
fi

echo "----"
echo "test-zensu-cli-map-drift: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
