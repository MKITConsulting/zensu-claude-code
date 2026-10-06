#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-mcp-tools.sh" 2>/dev/null || true
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-cli-map.sh" 2>/dev/null || true

# Flags a skill that calls a Zensu mutation outside the --workflow-begin/-end
# markers. Detects two forms: a `zensu <noun> <verb>` CLI invocation that maps to
# a mutation tool (the primary form post-rehome), and a legacy backticked bare
# mutation tool name. Echoes the offending tool name; silent + return 0 when the
# skill is properly workflow-wrapped.
skill_unwrapped_mutation() {
  local f="$1" tok line noun verb tool
  if grep -qF -- '--workflow-begin' "$f" && grep -qF -- '--workflow-end' "$f"; then
    return 0
  fi
  for line in $(grep -oE 'zensu +[a-z][a-z-]+ +[a-z][a-z-]+' "$f" | sed -E 's/ +/=/g'); do
    noun="${line#zensu=}"; verb="${noun#*=}"; noun="${noun%%=*}"
    case "$noun" in                                                # normalize CLI noun aliases (mirror the gate's ALIAS map)
      product) noun=products ;; feature) noun=features ;; subfeature) noun=subfeatures ;;
      roadmaps) noun=roadmap ;; tier) noun=tiers ;; sec) noun=security ;;
      journey) noun=journeys ;; docs) noun=doc ;; kb) noun=knowledge ;; wiki-pages) noun=wiki ;;
    esac
    tool="$(zensu_cli_to_tool "$noun" "$verb")"
    if [ -n "$tool" ] && zensu_is_mutation_tool "$tool"; then echo "$tool"; return 0; fi
  done
  for tok in $(grep -oE '`[^`]+`' "$f" | grep -oE '[a-z][a-z0-9_]+' | sort -u); do
    if zensu_is_mutation_tool "$tok"; then echo "$tok"; return 0; fi
  done
}

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for t in get_feature list_features search_knowledge suggest_workflow analyze_journey_health validate_feature_security ghost_get_candidates pulse_start_session pulse_end_session pulse_session_summary; do
  if zensu_is_read_tool "$t" 2>/dev/null && ! zensu_is_mutation_tool "$t" 2>/dev/null; then
    check "T-read $t -> read, not mutation" PASS
  else
    check "T-read $t -> read, not mutation" FAIL
  fi
done

for t in set_security_classification create_feature analyze_feature_security complete_security_review link_test generate_threat_model ghost_apply apply_bootstrap update_feature bootstrap_from_vision; do
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
  F="${d}SKILL.md"
  [ -f "$F" ] || continue
  off="$(skill_unwrapped_mutation "$F")"
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

echo "----"
echo "test-skill-workflow-markers: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
