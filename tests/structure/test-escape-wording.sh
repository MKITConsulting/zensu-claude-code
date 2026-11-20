#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

ANCHORS=(
  hooks/lib/acceptance-verify-v1.js
  hooks/lib/zensu-log.sh
  hooks/post-review-tdd-delegate.sh
  skills/self-review/SKILL.md
  skills/self-review/references/acceptance.md
  skills/verify-feature/SKILL.md
  skills/verify-feature/rules/acceptance-consent.md
  skills/verify-feature/rules/acceptance-evidence.md
  skills/autopilot/rules/validate.md
  skills/build/references/audit.md
  skills/build/references/review-chain.md
  hooks/checks/pre-bash-zensu-gate.sh
  hooks/checks/pre-edit-tdd-reminder.sh
  hooks/checks/pre-bash-source-write-gate.sh
  hooks/lib/bash-source-write-parse.js
  hooks/plan-approved-delegate.sh
  hooks/stop-chain-enforcer.sh
  skills/build/SKILL.md
  skills/change/SKILL.md
  skills/pilot/SKILL.md
  skills/zensu-help/SKILL.md
  plugins/session-hub/skills/session-trail/SKILL.md
)

scan() {
  UNIT_REGISTRY_LIB="$PLUGIN_DIR/tests/structure/lib-unit-registry.js" node - "$@" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { shellLines } = require(process.env.UNIT_REGISTRY_LIB);
const [root, ...rest] = process.argv.slice(2);
const walking = rest[0] === '--walk';
const anchors = walking ? rest.slice(1) : [];
const RUNTIME_ROOTS = ['hooks', 'skills', 'agents', 'templates', 'scripts'];
const NAME = String.raw`(?:ZENSU_(?:[A-Z]+_)*GATE|ZENSU_CHAIN|ZENSU_SECRET_SCAN|ZENSU_TEST_WITNESS)(?![A-Z0-9_])`;
const NAME_EXCLUDED = ['AUTOPILOT', 'SESSION_LINEAGE'];
if (rest[0] === '--stems') {
  const stems = (process.env.ESCAPE_STEMS_LIST || '').split(/\s+/).filter(Boolean);
  const whole = new RegExp(String.raw`^${NAME}$`);
  const unmatched = stems.filter((stem) => !NAME_EXCLUDED.includes(stem) && !whole.test(`ZENSU_${stem}`));
  const stale = NAME_EXCLUDED.filter((stem) => !stems.includes(stem));
  process.stdout.write(`stems=${stems.length}\nunmatched=${unmatched.join(',') || '-'}\nexcluded_stale=${stale.join(',') || '-'}\n`);
  process.exit(0);
}
const ESCAPE = new RegExp(String.raw`\b${NAME}|\bevidence\.(?:acceptance|fullSuite)Gate\b`);
const DOLLAR_READS = [
  [new RegExp(String.raw`\$\{${NAME}[^}]*\}`, 'g'), true],
  [new RegExp(String.raw`\$${NAME}`, 'g'), false],
];
const ENV_READS = [
  new RegExp(String.raw`\b(?:process\.)?env\.${NAME}`, 'g'),
  new RegExp(String.raw`\benv\[(['"])${NAME}\1\]`, 'g'),
];
const COMMENT_LEAD = /^(?:#|\/\/|\/\*|\*(?:\s|\/|$))/;
const SHELL_CASE_ARM = /^\(?[^\s'"()]+\)/;
const PROPERTY_READ = new RegExp(String.raw`(?<=[\w$\])])\.${NAME}`, 'g');
const CASE_ARM = new RegExp(String.raw`^\s*\(?['"]?${NAME}['"]?(?:\s*\|\s*['"]?${NAME}['"]?)*\)`);
const BYPASS_MARKER = new RegExp(String.raw`__bypass__(?::|\\t|\t)${NAME}`, 'g');
const WHOLE_NAME = new RegExp(String.raw`^${NAME}$`);
const topLevelLiterals = (line) => {
  const literals = [];
  let index = 0;
  while (index < line.length) {
    const quote = line[index];
    if (quote !== "'" && quote !== '"' && quote !== '`') {
      index += 1;
      continue;
    }
    let end = index + 1;
    while (end < line.length && line[end] !== quote) end += line[end] === '\\' ? 2 : 1;
    if (end >= line.length) break;
    literals.push({ start: index, end, body: line.slice(index + 1, end) });
    index = end + 1;
  }
  return literals;
};
const lookupToken = (line, start, end) => {
  const before = line.slice(0, start);
  const after = line.slice(end + 1);
  if (/(?:===|!==|==|!=)\s*$/.test(before) || /^\s*(?:===|!==|==|!=)/.test(after)) return true;
  if (/(?:^|[\s;(&|])[A-Za-z_][A-Za-z0-9_]*=$/.test(before)) return true;
  if (/\b(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*=\s*$/.test(before) && /^\s*;?\s*$/.test(after)) return true;
  if (/\.(?:includes|indexOf|has)\(\s*$/.test(before) && /^\s*\)/.test(after)) return true;
  return /[[,]\s*$/.test(before) && /^(?:\s*,\s*(?:'[^']*'|"[^"]*"))*\s*\]\.(?:includes|indexOf|has)\(/.test(after);
};
const stripLookupNames = (line) => {
  let judged = '';
  let cursor = 0;
  for (const literal of topLevelLiterals(line)) {
    if (!WHOLE_NAME.test(literal.body) || !lookupToken(line, literal.start, literal.end)) continue;
    judged += line.slice(cursor, literal.start);
    cursor = literal.end + 1;
  }
  return judged + line.slice(cursor);
};
const stripOutsideLiterals = (line, pattern) => {
  let judged = '';
  let cursor = 0;
  for (const literal of topLevelLiterals(line)) {
    judged += line.slice(cursor, literal.start).replace(pattern, '') + line.slice(literal.start, literal.end + 1);
    cursor = literal.end + 1;
  }
  const tail = line.slice(cursor);
  const open = tail.search(/['"`]/);
  if (open < 0) return judged + tail.replace(pattern, '');
  return judged + tail.slice(0, open).replace(pattern, '') + tail.slice(open);
};
const shellQuoted = (line) => {
  const quoted = new Array(line.length + 1).fill(false);
  let single = false;
  let double = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (single) {
      quoted[i] = true;
      if (ch === "'") single = false;
    } else if (ch === '\\') {
      quoted[i + 1] = true;
      i += 1;
    } else if (ch === "'" && !double) {
      single = true;
      quoted[i] = true;
    } else if (ch === '"') {
      double = !double;
    }
  }
  return quoted;
};
const stripDollarReads = (line, shell) => {
  const quoted = shell ? shellQuoted(line) : [];
  const literals = shell ? [] : topLevelLiterals(line);
  const after = literals.length > 0 ? literals[literals.length - 1].end + 1 : 0;
  const tailOpen = shell ? -1 : line.slice(after).search(/['"`]/);
  const unterminated = tailOpen < 0 ? -1 : after + tailOpen;
  const isRead = (index, braced) => {
    if (shell) return !quoted[index];
    if (unterminated >= 0 && index > unterminated) return braced && line[unterminated] === '`';
    const literal = literals.find((entry) => index > entry.start && index < entry.end);
    if (!literal) return true;
    return braced && line[literal.start] === '`';
  };
  let judged = line;
  for (const [pattern, braced] of DOLLAR_READS) {
    judged = judged.replace(pattern, (match, ...rest) => (isRead(rest[rest.length - 2], braced) ? ' '.repeat(match.length) : match));
  }
  return judged;
};
const REGEX_PREFIX = /[(,=:[!&|?{};+\-*%<>~^]$/;
const REGEX_WORDS = /(?:^|[^\w$])(?:return|typeof|case|in|of|delete|void|new|throw|yield|await|else|do)$/;
const templateLines = (text) => {
  const inside = new Set();
  const stack = [];
  let line = 0;
  let recent = '';
  const newline = () => {
    line += 1;
    if (stack.length > 0 && stack[stack.length - 1] === 'template') inside.add(line);
  };
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const top = stack.length > 0 ? stack[stack.length - 1] : 'code';
    if (ch === '\n') {
      newline();
      continue;
    }
    if (top === 'template') {
      if (ch === '\\') {
        i += 1;
        if (text[i] === '\n') newline();
      } else if (ch === '`') {
        stack.pop();
        recent = 'x';
      } else if (ch === '$' && text[i + 1] === '{') {
        stack.push(0);
        i += 1;
        recent = '{';
      }
      continue;
    }
    if (ch === '/' && text[i + 1] === '/') {
      while (i + 1 < text.length && text[i + 1] !== '\n') i += 1;
      continue;
    }
    if (ch === '/' && text[i + 1] === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) {
        if (text[i] === '\n') newline();
        i += 1;
      }
      i += 1;
      continue;
    }
    if (ch === "'" || ch === '"') {
      i += 1;
      while (i < text.length && text[i] !== ch && text[i] !== '\n') {
        if (text[i] === '\\') {
          i += 1;
          if (text[i] === '\n') newline();
        }
        i += 1;
      }
      recent = 'x';
      continue;
    }
    if (ch === '`') {
      stack.push('template');
      continue;
    }
    if (ch === '/' && (recent === '' || REGEX_PREFIX.test(recent) || REGEX_WORDS.test(recent))) {
      let klass = false;
      i += 1;
      while (i < text.length && text[i] !== '\n' && (klass || text[i] !== '/')) {
        if (text[i] === '\\') i += 1;
        else if (text[i] === '[') klass = true;
        else if (text[i] === ']') klass = false;
        i += 1;
      }
      recent = 'x';
      continue;
    }
    if (typeof top === 'number') {
      if (ch === '{') stack[stack.length - 1] += 1;
      if (ch === '}') {
        if (top === 0) {
          stack.pop();
          recent = 'x';
          continue;
        }
        stack[stack.length - 1] -= 1;
      }
    }
    if (!/\s/.test(ch)) recent = (recent + ch).slice(-12);
  }
  return inside;
};
const CODE_FILE = /\.(?:sh|js|mjs|cjs|ts)$/;
const proseLines = (rel, text) => {
  if (/\.sh$/.test(rel)) {
    const lines = new Set();
    shellLines(text).forEach((entry, index) => { if (entry.heredoc === true) lines.add(index); });
    return lines;
  }
  return /\.(?:js|mjs|cjs|ts)$/.test(rel) ? templateLines(text) : new Set();
};
const LEDGER_ARGUMENT = new RegExp(String.raw`\b((?:tdd_record_bypass(?:_payload)?|tdd_bypass_recorded)\s+(?:"[^"]*"|'[^']*'|\S+))\s+${NAME}`, 'g');
const ACCEPTANCE_LIB = 'hooks/lib/acceptance-verify-v1.js';
const EVIDENCE_LIB = 'hooks/lib/evidence-run-v1.js';
const LOG_LIB = 'hooks/lib/zensu-log.sh';
const DISCLOSURES = [
  ['D1', [ACCEPTANCE_LIB, LOG_LIB], /ACCEPTANCE — escaped \|/],
  ['D2', [EVIDENCE_LIB, LOG_LIB], /FULL SUITE — escaped \|/],
  ['D3', [ACCEPTANCE_LIB, LOG_LIB], /STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt/],
  ['D4', [ACCEPTANCE_LIB], /ZENSU_EDIT_LANDING_GATE=off left no receipt to name this chain/],
  ['D5', [ACCEPTANCE_LIB, EVIDENCE_LIB], /evidence\.(?:acceptance|fullSuite)Gate value .* is not recognized/],
];
const SCOPED = [
  ['O1', 'hooks/stop-chain-enforcer.sh', /^\s*stop_notice "zensu chain-enforcer: releasing Stop because ZENSU_CHAIN=off is set explicitly\. /],
  ['O2', 'hooks/stop-chain-enforcer.sh', /^\s*echo "zensu chain-enforcer: .*ZENSU_CHAIN=off or hooks\.chainEnforcer=false releases this guard explicitly\." >&2$/],
  ['O3', 'hooks/stop-chain-enforcer.sh', /^\s*stop_notice "zensu chain-enforcer: .* blocked Stops, the Stop cap for this whole chain .*, or set ZENSU_CHAIN=off explicitly\. Any durable Outer run remains enforced\."$/],
  ['R1', 'skills/zensu-help/SKILL.md', /^\| Environment variables and native placeholders \(`ZENSU_API_KEY`, /],
  ['L1', 'hooks/lib/zensu-tdd-phase.sh', /^ZENSU_BYPASS_GATE_ALLOWLIST="[A-Za-z_ -]+"$/],
  ['L2', 'hooks/lib/bash-source-write-parse.js', /\bbypassed\.push\("ZENSU_(?:BASH_WRITE|MCP)_GATE"\);$/],
];
const walked = [];
const links = [];
const rootCounts = [];
let unwalked = 'unchecked';
if (walking) {
  const roots = [...RUNTIME_ROOTS];
  let plugins = [];
  try {
    plugins = fs.readdirSync(path.join(root, 'plugins'), { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort();
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  for (const plugin of plugins) {
    for (const sub of RUNTIME_ROOTS) {
      if (fs.existsSync(path.join(root, 'plugins', plugin, sub))) roots.push(`plugins/${plugin}/${sub}`);
    }
  }
  const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const visit = (rel) => {
    for (const entry of fs.readdirSync(path.join(root, rel), { withFileTypes: true }).sort(byName)) {
      const child = `${rel}/${entry.name}`;
      if (entry.isSymbolicLink()) links.push(child);
      else if (entry.isDirectory()) visit(child);
      else if (entry.isFile()) walked.push(child);
    }
  };
  for (const rel of roots) {
    const before = walked.length;
    let stat = null;
    try {
      stat = fs.lstatSync(path.join(root, rel));
    } catch {
      stat = null;
    }
    if (stat && stat.isSymbolicLink()) links.push(rel);
    else if (stat && stat.isDirectory()) visit(rel);
    rootCounts.push(`${rel}:${walked.length - before}`);
  }
  const environment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  let tracked = [];
  try {
    tracked = execFileSync('git', ['-C', root, 'ls-files', '-z', '--', ...roots], {
      encoding: 'utf8',
      env: environment,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).split('\0').filter(Boolean);
  } catch {
    tracked = [];
  }
  if (tracked.length > 0) {
    const seen = new Set(walked);
    const lost = tracked.filter((rel) => !seen.has(rel));
    unwalked = lost.length === 0 ? '-' : lost.slice(0, 10).join(',');
  }
}
const files = walking ? walked : rest;
const findings = [];
const matched = new Set();
let scanned = 0;
let disclosed = 0;
let allowed = 0;
const allowance = (rel, line) => {
  for (const [id, files, pattern] of DISCLOSURES) if (files.includes(rel) && pattern.test(line)) return ['disclosed', id];
  for (const [id, file, pattern] of SCOPED) if (file === rel && pattern.test(line)) return ['allowed', id];
  return null;
};
for (const rel of files) {
  const file = path.resolve(root, rel);
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (error) {
    findings.push(`${rel}:0: unreadable (${error.code || error.message})`);
    continue;
  }
  scanned += 1;
  const code = CODE_FILE.test(rel);
  const shell = /\.sh$/.test(rel);
  const prose = proseLines(rel, text);
  text.split(/\r?\n/).forEach((line, index) => {
    if (!ESCAPE.test(line)) return;
    let judged = line;
    if (code && !prose.has(index)) {
      const trimmed = line.trim();
      if (COMMENT_LEAD.test(trimmed) && !(shell && SHELL_CASE_ARM.test(trimmed))) return;
      judged = judged.replace(LEDGER_ARGUMENT, '$1');
      judged = judged.replace(BYPASS_MARKER, '__bypass__');
      if (shell) judged = judged.replace(CASE_ARM, '');
      judged = stripOutsideLiterals(judged, PROPERTY_READ);
      for (const pattern of ENV_READS) judged = judged.replace(pattern, '');
      judged = stripDollarReads(judged, shell);
      judged = stripLookupNames(judged);
      if (!ESCAPE.test(judged)) return;
    }
    const allowedBy = allowance(rel, line);
    if (allowedBy) {
      matched.add(allowedBy[1]);
      if (allowedBy[0] === 'disclosed') disclosed += 1;
      else allowed += 1;
      return;
    }
    findings.push(`${rel}:${index + 1}: ${line.trim().slice(0, 200)}`);
  });
}
const stale = [...DISCLOSURES, ...SCOPED].map((entry) => entry[0]).filter((id) => !matched.has(id));
const missing = anchors.filter((rel) => !walked.includes(rel));
const out = [
  `scanned=${scanned}`,
  `walked=${walking ? walked.length : '-'}`,
  `disclosed=${disclosed}`,
  `allowed=${allowed}`,
  `stale=${stale.length > 0 ? stale.join(',') : '-'}`,
  `missing=${missing.length > 0 ? missing.join(',') : '-'}`,
  `unwalked=${unwalked}`,
  `links=${links.length > 0 ? links.join(',') : '-'}`,
  `roots=${rootCounts.join(',')}`,
  `findings=${findings.length}`,
  ...findings.map((finding) => `finding: ${finding}`),
];
process.stdout.write(`${out.join('\n')}\n`);
NODE
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
findings_of() { printf '%s\n' "$1" | sed -n 's/^finding: //p'; }
finding_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
is_count() { case "$1" in (''|*[!0-9]*) return 1 ;; esac; return 0; }

REAL="$(scan "$PLUGIN_DIR" --walk "${ANCHORS[@]}")" || REAL=""
SCANNED="$(field "$REAL" scanned)"
WALKED="$(field "$REAL" walked)"
DISCLOSED="$(field "$REAL" disclosed)"
ALLOWED="$(field "$REAL" allowed)"
STALE="$(field "$REAL" stale)"
MISSING="$(field "$REAL" missing)"
UNWALKED="$(field "$REAL" unwalked)"
LINKS="$(field "$REAL" links)"
ROOTS="$(field "$REAL" roots)"
REAL_FINDINGS="$(findings_of "$REAL")"
REAL_COUNT="$(field "$REAL" findings)"

ROOTS_OK=yes
for root_name in hooks skills agents templates scripts; do
  printf '%s' ",$ROOTS," | grep -qE ",$root_name:[1-9][0-9]*," || ROOTS_OK=no
done
printf '%s' ",$ROOTS," | grep -qE ',plugins/[^,:/]+/(hooks|skills|agents|templates|scripts):[1-9][0-9]*,' || ROOTS_OK=no

if is_count "$SCANNED" && [ "$SCANNED" = "$WALKED" ] && [ "$SCANNED" -ge 250 ] && [ "$ROOTS_OK" = yes ] \
  && [ "$MISSING" = "-" ] && [ "$LINKS" = "-" ] && { [ "$UNWALKED" = "-" ] || [ "$UNWALKED" = "unchecked" ]; }; then
  if [ "$UNWALKED" = "-" ]; then W0_TRACKED="every tracked file among them"; else W0_TRACKED="no git to compare tracked files"; fi
  check "W0 the walk read every file under hooks/, skills/, agents/, templates/, scripts/ and each plugin's roots of those names ($SCANNED files, $W0_TRACKED), the former file list and the reworded sites included" PASS
else
  check "W0 walk coverage (scanned=${SCANNED:-none} walked=${WALKED:-none} roots=${ROOTS:-none} missing=${MISSING:-none} unwalked=${UNWALKED:-none} links=${LINKS:-none})" FAIL
fi

if [ -z "$REAL_FINDINGS" ] && [ "$REAL_COUNT" = 0 ]; then
  check "W1 no runtime file names a gate escape outside a disclosure line or a reviewed allowlist entry" PASS
else
  check "W1 runtime files name a gate escape outside a disclosure line or a reviewed allowlist entry: $(printf '%s' "$REAL_FINDINGS" | tr '\n' ';') (findings=${REAL_COUNT:-none})" FAIL
fi

if [ "$STALE" = "-" ] && is_count "$DISCLOSED" && [ "$DISCLOSED" -ge 5 ] && is_count "$ALLOWED" && [ "$ALLOWED" -ge 6 ]; then
  check "W2 every disclosure and allowlist entry matches a shipped line ($DISCLOSED disclosure lines, $ALLOWED operator, routing and ledger lines)" PASS
else
  check "W2 allowlist entries that match no shipped line: ${STALE:-unknown} (disclosed=${DISCLOSED:-none} allowed=${ALLOWED:-none})" FAIL
fi

STEMS="$(sed -n "s/^ESCAPE_STEMS='\(.*\)'\$/\1/p" "$PLUGIN_DIR/tests/structure/test-gauntlet-loop-skill.sh" | head -n 1)"
STEM_REAL="$(ESCAPE_STEMS_LIST="$STEMS" scan "$PLUGIN_DIR" --stems)"
STEM_BITE="$(ESCAPE_STEMS_LIST="$STEMS NEW_ESCAPE" scan "$PLUGIN_DIR" --stems)"
STEM_STALE="$(ESCAPE_STEMS_LIST="TDD_GATE" scan "$PLUGIN_DIR" --stems)"
STEM_COUNT="$(field "$STEM_REAL" stems)"
if is_count "$STEM_COUNT" && [ "$STEM_COUNT" -ge 1 ] \
  && [ "$(field "$STEM_REAL" unmatched)" = "-" ] && [ "$(field "$STEM_REAL" excluded_stale)" = "-" ] \
  && [ "$(field "$STEM_BITE" unmatched)" = "NEW_ESCAPE" ] \
  && [ "$(field "$STEM_STALE" excluded_stale)" = "AUTOPILOT,SESSION_LINEAGE" ]; then
  check "W9 every escape stem test-gauntlet-loop-skill.sh lists is in the lint's vocabulary or on its named exclusions (AUTOPILOT, SESSION_LINEAGE), and an unmatched stem or a stale exclusion is reported ($STEM_COUNT stems)" PASS
else
  check "W9 escape stems against the lint's vocabulary (real: $(printf '%s' "$STEM_REAL" | tr '\n' ' '); bite: $(printf '%s' "$STEM_BITE" | tr '\n' ' '); stale: $(printf '%s' "$STEM_STALE" | tr '\n' ' '))" FAIL
fi

FIX="$(mktemp -d "${TMPDIR:-/tmp}/escape-wording.XXXXXX")" || FIX=""
if [ -n "$FIX" ] && [ -d "$FIX" ]; then
  mkdir -p "$FIX/hooks/lib"
  cat > "$FIX/bad.md" <<'EOF'
- `add:` give the plan a criterion, or set `ZENSU_ACCEPTANCE_GATE=off` to close the chain.
EOF
  cat > "$FIX/bad.sh" <<'EOF'
echo "zensu-log.sh: refusing. Set ZENSU_FULL_SUITE_GATE=off to skip this check." >&2
cat >&2 <<'MSG'
Leave `ZENSU_ACCEPTANCE_GATE` to the user to close the chain.
# or set ZENSU_CHAIN=off to close it
MSG
  ZENSU_MCP_GATE) echo "or prefix the call with ZENSU_MCP_GATE=off" ;;
tdd_record_bypass_payload "$INPUT" "$gate"; echo "or set ZENSU_TDD_GATE=off" >&2
echo "set config.ZENSU_CHAIN to off" >&2
    echo "zensu chain-enforcer: x. ZENSU_CHAIN=off or hooks.chainEnforcer=false releases this guard explicitly." >&2
  *) echo "or set ZENSU_CHAIN=off" >&2 ;;
  /*) echo "set ZENSU_TDD_GATE=off" ;;
echo 'or set $ZENSU_CHAIN=off'
echo "or set \$ZENSU_CHAIN=off"
EOF
  cat > "$FIX/bad name=x.md" <<'EOF'
Set ZENSU_CHAIN=off to close the chain.
EOF
  cat > "$FIX/bad.js" <<'EOF'
  listed.push('restore: a dropped criterion needs a pass, or leave ZENSU_ACCEPTANCE_GATE to the user');
  return ['add: no criterion; set evidence.acceptanceGate to advisory to close'];
  lines.push('restore: a dropped criterion needs a pass, or leave `ZENSU_ACCEPTANCE_GATE` to the user');
  return 'restore: a dropped criterion needs a pass, or switch the gate off (`ZENSU_ACCEPTANCE_GATE`)';
  lines.push(['restore: or set', 'ZENSU_ACCEPTANCE_GATE', 'to off'].join(' '));
  return { remedy: 'ZENSU_ACCEPTANCE_GATE' };
  lines.push(`set ${'ZENSU_ACCEPTANCE_GATE'}=off`);
  const FENCE_RE = /^ {0,3}(`{3,}|~{3,})/;
  const help = `the chain stays open:
  * or set ZENSU_ACCEPTANCE_GATE=off and close it
  `;
  return '__bypass__ or set ZENSU_SECRET_SCAN=off';
  lines.push('ZENSU_CHAIN');
  if (seen.indexOf('ZENSU_CHAIN or off') < 0) return;
  const tip = 'run config.ZENSU_CHAIN=off';
  lines.push('or set $ZENSU_CHAIN=off');
  const joined = "first \
second";
  const more = `x
  * or set ZENSU_CHAIN=off`;
  lines.push(`ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record was read | gate`);
EOF
  cat > "$FIX/bad.ts" <<'EOF'
const help = `remedy:
  set ZENSU_ACCEPTANCE_GATE=off
`;
EOF
  cat > "$FIX/good.sh" <<'EOF'
[ "${ZENSU_ACCEPTANCE_GATE:-on}" = "off" ] && _avr_escape=1
tdd_record_bypass "$session" ZENSU_ACCEPTANCE_GATE >/dev/null 2>&1 || true
# A comment may explain ZENSU_CHAIN=off to a maintainer.
  (escaped) apv_gate="ZENSU_ACCEPTANCE_GATE" ;;
[ "${ZENSU_BASH_WRITE_GATE:-}" = "off" ] && { tdd_record_bypass_payload "$INPUT" ZENSU_BASH_WRITE_GATE 2>/dev/null || true; exit 0; }
        ZENSU_BASH_WRITE_GATE|ZENSU_MCP_GATE)
      ZENSU_MCP_GATE) tdd_record_bypass_payload "$INPUT" "$gate" 2>/dev/null || true ;;
if [ "$VERDICT" = "__bypass__:ZENSU_SECRET_SCAN" ]; then
node -e '
  // ZENSU_CHAIN is read below and never offered
  process.exit(process.env.ZENSU_CHAIN === "off" ? 0 : 1);
'
[ "$ZENSU_CHAIN" = off ] && exit 0
EOF
  cat > "$FIX/good.js" <<'EOF'
  if (process.env.ZENSU_SECRET_SCAN !== "off") {
  const ESCAPE_NAME = 'ZENSU_EDIT_LANDING_GATE';
  if (gate === 'ZENSU_ACCEPTANCE_GATE' || ["ZENSU_FULL_SUITE_GATE", 'ZENSU_CHAIN'].includes(gate)) {
  const FENCE_RE = /^ {0,3}(`{3,}|~{3,})/;
  // ZENSU_CHAIN is read by the hook and never offered
  const note = `a note that spans
  two lines`;
  // a maintainer may read about ZENSU_ACCEPTANCE_GATE here
  if (envp.ZENSU_MCP_GATE === "off" && bypassed.indexOf("ZENSU_MCP_GATE") < 0) flagged = true;
  if (context.environment.ZENSU_TDD_GATE === 'off') return false;
  if (escaped) return "__bypass__:ZENSU_SECRET_SCAN";
EOF
  cat > "$FIX/good.ts" <<'EOF'
if (process.env.ZENSU_CHAIN === 'off') process.exit(0);
const label = env['ZENSU_CHAIN'];
EOF
  cat > "$FIX/hooks/stop-chain-enforcer.sh" <<'EOF'
    echo "zensu chain-enforcer: x. ZENSU_CHAIN=off or hooks.chainEnforcer=false releases this guard explicitly." >&2
EOF
  cat > "$FIX/hooks/lib/acceptance-verify-v1.js" <<'EOF'
    lines.push(`ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record was read | gate`);
EOF
  BAD_RAW="$(scan "$FIX" bad.md bad.sh bad.js bad.ts 'bad name=x.md')"
  BAD="$(findings_of "$BAD_RAW")"
  GOOD="$(scan "$FIX" good.sh good.js good.ts hooks/stop-chain-enforcer.sh hooks/lib/acceptance-verify-v1.js)"
  BAD_COUNT="$(field "$BAD_RAW" findings)"
  BAD_LINES="$(finding_lines "$BAD")"
  BAD_MISSED=""
  for expected in bad.md:1 bad.sh:1 bad.sh:3 bad.sh:4 bad.sh:6 bad.sh:7 bad.sh:8 bad.sh:9 bad.sh:10 bad.sh:11 bad.sh:12 bad.sh:13 \
    bad.js:1 bad.js:2 bad.js:3 bad.js:4 bad.js:5 bad.js:6 bad.js:7 bad.js:10 bad.js:12 bad.js:13 bad.js:14 bad.js:15 \
    bad.js:16 bad.js:20 bad.js:21 bad.ts:2; do
    printf '%s\n' "$BAD" | grep -qF "$expected: " || BAD_MISSED="$BAD_MISSED $expected"
  done
  printf '%s\n' "$BAD" | grep -qF 'bad name=x.md:1: ' || BAD_MISSED="$BAD_MISSED bad-name=x.md:1"
  if [ "$BAD_COUNT" = 29 ] && [ "$BAD_LINES" = 29 ] && [ -z "$BAD_MISSED" ]; then
    check "W3 a fixture that names an env-var escape as a remedy fails the scan, a name quoted inside prose, joined from pieces, used or pushed as a value, interpolated, read as a property inside a string, after a named, default or path case arm or a ledger call, beside a marker word, as a single-quoted or escaped dollar spelling, on the closing line of a template after a backslash-continued string, in a .ts template literal or in a file whose name holds a space and an equals sign included, and a disclosure or an allowlisted operator line outside its own file (29 findings, the count line agreeing)" PASS
  else
    check "W3 fixture escape remedies were not all found (count=${BAD_COUNT:-none} lines=$BAD_LINES, missed:${BAD_MISSED:- none}): $(printf '%s' "$BAD" | tr '\n' ';')" FAIL
  fi
  GOOD_FINDINGS="$(findings_of "$GOOD")"
  if [ -z "$GOOD_FINDINGS" ] && [ "$(field "$GOOD" findings)" = 0 ] && [ "$(field "$GOOD" scanned)" = 5 ] \
    && [ "$(field "$GOOD" disclosed)" = 1 ] && [ "$(field "$GOOD" allowed)" = 1 ]; then
    check "W4 variable and property reads, ledger arguments and markers, case arms, comments, name literals compared, assigned or looked up, disclosures and an allowlisted operator line in its own file pass the scan, a comment after a regex literal holding a backtick and after a closed template literal included" PASS
  else
    check "W4 the scan flagged code reads, disclosures or allowlisted lines: $(printf '%s' "$GOOD" | tr '\n' ';')" FAIL
  fi
  GOOD_STALE=",$(field "$GOOD" stale),"
  W8_BAD=""
  for entry_id in D2 D3 D4 D5 O1 O3 R1 L1 L2; do
    case "$GOOD_STALE" in (*",$entry_id,"*) ;; (*) W8_BAD="$W8_BAD unreported:$entry_id" ;; esac
  done
  for entry_id in D1 O2; do
    case "$GOOD_STALE" in (*",$entry_id,"*) W8_BAD="$W8_BAD matched-but-reported:$entry_id" ;; esac
  done
  if [ -z "$W8_BAD" ]; then
    check "W8 an allowlist entry that matches no scanned line is reported stale, and one that matched is not" PASS
  else
    check "W8 stale report ($GOOD_STALE):$W8_BAD" FAIL
  fi
  rm -rf "$FIX"
else
  check "W3 fixture directory could not be created" FAIL
fi

drive_remedies() {
  node - "$PLUGIN_DIR" <<'NODE'
const avr = require(`${process.argv[2]}/hooks/lib/acceptance-verify-v1.js`);
const row = (id, state) => ({ criterion: { id, text: `criterion ${id}` }, state });
const combos = [
  [],
  [row('AC-001', 'partial')],
  [row('AC-001', 'partial'), row('AC-002', 'partial')],
  [row('AC-001', 'fail')],
  [row('AC-001', 'missing')],
  [row('AC-001', 'stale')],
  [row('AC-001', 'dropped')],
  [row('AC-001', 'partial'), row('AC-002', 'fail'), row('AC-003', 'dropped'), row('AC-004', 'missing')],
  [row('AC-001', 'pass'), row('AC-002', 'partial'), row('AC-003', 'deprecated')],
];
const chains = [null, { stem: '2026-11-10-2322_build-x' }, { runId: 'run_0123456789abcdef' }];
const states = ['incomplete', 'no-criteria', 'unresolved', 'invalid', 'unavailable'];
const contexts = [{}, { zeroChangeTicket: true }, { currentTree: { tree: null, reason: 'the tree could not be fingerprinted' } }, { consented: ['AC-001', 'AC-002', 'AC-003', 'AC-004'] }, { unapproved: true }];
const segments = [];
const runPrefixes = new Set();
for (const chain of chains) {
  for (const state of states) {
    for (const rows of combos) {
      for (const context of contexts) {
        const listed = avr.remedies(state, rows, chain, '/project', context);
        segments.push(...listed);
        if (chain && chain.runId) for (const segment of listed) runPrefixes.add(String(segment).slice(0, String(segment).indexOf(':')));
      }
    }
  }
}
segments.push(avr.acceptOpenRows(['AC-007'], [row('AC-001', 'partial'), row('AC-002', 'fail')]).refusal);
segments.push(avr.parseAcceptIds('x').error);
segments.push(...avr.ACCEPT_CONTEXT_REFUSALS.values());
const escaped = segments.filter((segment) => /ZENSU_|evidence\.(?:acceptance|fullSuite)Gate/.test(String(segment)));
const accept = avr.remedies('incomplete', [row('AC-001', 'partial'), row('AC-002', 'partial')], { stem: 's' }, '/project');
const acceptLine = accept.find((segment) => segment.startsWith('accept:')) || '';
process.stdout.write(`segments=${segments.length} escaped=${escaped.length}\n`);
process.stdout.write(`runPrefixes=${[...runPrefixes].sort().join(',')}\n`);
process.stdout.write(`accept=${/AC-001, AC-002/.test(acceptLine) && /--accept-partial AC-001,AC-002/.test(acceptLine) && /the user's consent for exactly these criteria/.test(acceptLine) && /acceptance-consent\.md/.test(acceptLine) && /## Manual Acceptance row/.test(acceptLine) ? 'ok' : 'missing'}\n`);
for (const segment of escaped) process.stdout.write(`escaped: ${segment}\n`);
NODE
}

REMEDIES="$(drive_remedies)" || REMEDIES=""
SEGMENTS="$(printf '%s\n' "$REMEDIES" | sed -n 's/^segments=\([0-9]*\) .*/\1/p')"
if [ -n "$SEGMENTS" ] && [ "$SEGMENTS" -ge 20 ] && printf '%s\n' "$REMEDIES" | grep -qF 'escaped=0'; then
  check "W5 no remedy or --accept-partial refusal of the gate names an escape ($SEGMENTS segments)" PASS
else
  check "W5 remedies name an escape or were not driven: $(printf '%s' "$REMEDIES" | tr '\n' ';')" FAIL
fi
if printf '%s\n' "$REMEDIES" | grep -qxF 'accept=ok'; then
  check "W6 an all-partial standalone refusal ends with an accept: segment that names the ids and the consent" PASS
else
  check "W6 the all-partial accept: segment is missing or incomplete: $(printf '%s' "$REMEDIES" | tr '\n' ';')" FAIL
fi

RUN_PREFIXES="$(printf '%s\n' "$REMEDIES" | sed -n 's/^runPrefixes=//p')"
VALIDATE_SECTION="$(awk '/^## 3\. Validate$/ { on = 1; next } /^## / { on = 0 } on' "$PLUGIN_DIR/skills/autopilot/rules/validate.md")"
W7_MISSING=""
for prefix in $(printf '%s' "$RUN_PREFIXES" | tr ',' ' '); do
  printf '%s\n' "$VALIDATE_SECTION" | grep -qF "\`$prefix:\`" || W7_MISSING="$W7_MISSING $prefix"
done
if [ -n "$VALIDATE_SECTION" ] && [ "$RUN_PREFIXES" = "accept,add,consent,fix,restore,run" ] && [ -z "$W7_MISSING" ]; then
  check "W7 every remedy prefix the run mode emits ($RUN_PREFIXES) is handled in section 3 of skills/autopilot/rules/validate.md" PASS
else
  check "W7 the run-mode remedy prefixes ($RUN_PREFIXES) are not all handled in section 3 of skills/autopilot/rules/validate.md:${W7_MISSING:- the section was not found}" FAIL
fi

echo "----"
echo "test-escape-wording: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
