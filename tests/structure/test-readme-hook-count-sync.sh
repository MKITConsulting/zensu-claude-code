#!/bin/bash
set -u

# Guards the "Hooks (N)" sync convention: the header count in the hook
# reference (docs/configuration.md), every `Hooks (N)`/`#hooks-N` reference in
# it or in README.md, and the number of hook scripts actually registered in
# hooks.json must agree. Catches the drift where a hook is added (header
# bumped) but the prose count / intra-doc anchor is left stale.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_DOC="$PLUGIN_DIR/docs/configuration.md"
README="$PLUGIN_DIR/README.md"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

HDR_N="$(grep -oE '^### Hooks \([0-9]+\)' "$HOOKS_DOC" | grep -oE '[0-9]+' | head -1)"
[ -n "$HDR_N" ] && check "H1 '### Hooks (N)' header present" PASS || check "H1 '### Hooks (N)' header present" FAIL

REG_N="$(node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const s=new Set();
  const walk=(o)=>{
    if(Array.isArray(o)){o.forEach(walk);return;}
    if(o&&typeof o==="object"){
      if(typeof o.command==="string"){const m=o.command.match(/hooks\/([A-Za-z0-9._-]+\.sh)/);if(m)s.add(m[1]);}
      Object.values(o).forEach(walk);
    }
  };
  walk(h); process.stdout.write(String(s.size));
' "$HOOKS_JSON" 2>/dev/null)"

[ -n "$HDR_N" ] && [ "$HDR_N" = "$REG_N" ] \
  && check "H2 header count ($HDR_N) == registered hook scripts ($REG_N)" PASS \
  || check "H2 header ($HDR_N) == registered hook scripts ($REG_N)" FAIL

# Every 'Hooks (N)' and '#hooks-N' reference must use the header's N.
BAD="$(grep -hoE 'Hooks \([0-9]+\)|#hooks-[0-9]+' "$HOOKS_DOC" "$README" | grep -oE '[0-9]+' | sort -u | grep -vx "${HDR_N:-x}" | tr '\n' ' ')"
[ -z "$BAD" ] && check "H3 all 'Hooks (N)'/'#hooks-N' refs use N=$HDR_N" PASS \
  || check "H3 inconsistent hook-count refs (stray: $BAD vs header $HDR_N)" FAIL

echo "----"
echo "test-readme-hook-count-sync: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
