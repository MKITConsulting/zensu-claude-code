#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

FILES=(
  hooks/lib/acceptance-verify-v1.js
  hooks/lib/zensu-log.sh
  hooks/post-review-tdd-delegate.sh
  skills/self-review/SKILL.md
  skills/self-review/references/acceptance.md
  skills/verify-feature/SKILL.md
  skills/verify-feature/rules/acceptance-consent.md
  skills/verify-feature/rules/acceptance-evidence.md
  skills/autopilot/rules/validate.md
)
for f in "$PLUGIN_DIR"/skills/build/references/*.md; do
  [ -f "$f" ] && FILES+=("${f#"$PLUGIN_DIR"/}")
done

scan() {
  node - "$@" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [root, ...files] = process.argv.slice(2);
const NAME = String.raw`(?:ZENSU_(?:[A-Z]+_)*GATE|ZENSU_CHAIN|ZENSU_SECRET_SCAN|ZENSU_TEST_WITNESS)(?![A-Z0-9_])`;
const ESCAPE = new RegExp(String.raw`\b${NAME}|\bevidence\.(?:acceptance|fullSuite)Gate\b`);
const CODE_READS = [
  new RegExp(String.raw`\$\{${NAME}[^}]*\}`, 'g'),
  new RegExp(String.raw`\$${NAME}`, 'g'),
  new RegExp(String.raw`\b(?:process\.)?env\.${NAME}`, 'g'),
  new RegExp(String.raw`\benv\[(['"])${NAME}\1\]`, 'g'),
];
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
const LEDGER_ARGUMENT = new RegExp(String.raw`\b((?:tdd_record_bypass|tdd_bypass_recorded)\s+(?:"[^"]*"|'[^']*'|\S+))\s+${NAME}`, 'g');
const DISCLOSURES = [
  /ACCEPTANCE — escaped \|/,
  /FULL SUITE — escaped \|/,
  /STEM UNCHECKED — ZENSU_EDIT_LANDING_GATE=off leaves no receipt/,
  /ZENSU_EDIT_LANDING_GATE=off left no receipt to name this chain/,
  /evidence\.acceptanceGate value .* is not recognized/,
];
const findings = [];
let scanned = 0;
let disclosed = 0;
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
  const code = /\.(?:sh|js|mjs|cjs)$/.test(rel);
  text.split(/\r?\n/).forEach((line, index) => {
    if (!ESCAPE.test(line)) return;
    let judged = line;
    if (code) {
      const trimmed = line.trim();
      if (trimmed.startsWith('#') || trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*')) return;
      judged = judged.replace(LEDGER_ARGUMENT, '$1');
      for (const pattern of CODE_READS) judged = judged.replace(pattern, '');
      judged = stripLookupNames(judged);
      if (!ESCAPE.test(judged)) return;
    }
    if (DISCLOSURES.some((pattern) => pattern.test(line))) {
      disclosed += 1;
      return;
    }
    findings.push(`${rel}:${index + 1}: ${line.trim().slice(0, 200)}`);
  });
}
process.stdout.write(`scanned=${scanned} disclosed=${disclosed}\n`);
for (const finding of findings) process.stdout.write(`${finding}\n`);
NODE
}

REAL="$(scan "$PLUGIN_DIR" "${FILES[@]}")" || REAL=""
REAL_HEAD="$(printf '%s\n' "$REAL" | head -n 1)"
REAL_FINDINGS="$(printf '%s\n' "$REAL" | sed '1d')"
SCANNED="$(printf '%s\n' "$REAL_HEAD" | sed -n 's/^scanned=\([0-9]*\) .*/\1/p')"
DISCLOSED="$(printf '%s\n' "$REAL_HEAD" | sed -n 's/.* disclosed=\([0-9]*\)$/\1/p')"

if [ -n "$SCANNED" ] && [ "$SCANNED" -eq "${#FILES[@]}" ] && [ "${#FILES[@]}" -ge 10 ]; then
  check "W0 the scan read every listed file ($SCANNED of ${#FILES[@]})" PASS
else
  check "W0 the scan read every listed file (scanned=${SCANNED:-none} of ${#FILES[@]})" FAIL
fi

if [ -z "$REAL_FINDINGS" ]; then
  check "W1 no listed file names a gate escape outside a disclosure line" PASS
else
  check "W1 listed files name a gate escape outside a disclosure line: $(printf '%s' "$REAL_FINDINGS" | tr '\n' ';')" FAIL
fi

if [ -n "$DISCLOSED" ] && [ "$DISCLOSED" -ge 5 ]; then
  check "W2 the disclosure allowlist matches the shipped disclosure lines ($DISCLOSED)" PASS
else
  check "W2 the disclosure allowlist matched ${DISCLOSED:-no} shipped lines, so it no longer reads the real texts" FAIL
fi

FIX="$(mktemp -d "${TMPDIR:-/tmp}/escape-wording.XXXXXX")" || FIX=""
if [ -n "$FIX" ] && [ -d "$FIX" ]; then
  cat > "$FIX/bad.md" <<'EOF'
- `add:` give the plan a criterion, or set `ZENSU_ACCEPTANCE_GATE=off` to close the chain.
EOF
  cat > "$FIX/bad.sh" <<'EOF'
echo "zensu-log.sh: refusing. Set ZENSU_FULL_SUITE_GATE=off to skip this check." >&2
cat >&2 <<'MSG'
Leave `ZENSU_ACCEPTANCE_GATE` to the user to close the chain.
MSG
EOF
  cat > "$FIX/bad.js" <<'EOF'
  listed.push('restore: a dropped criterion needs a pass, or leave ZENSU_ACCEPTANCE_GATE to the user');
  return ['add: no criterion; set evidence.acceptanceGate to advisory to close'];
  lines.push('restore: a dropped criterion needs a pass, or leave `ZENSU_ACCEPTANCE_GATE` to the user');
  return 'restore: a dropped criterion needs a pass, or switch the gate off (`ZENSU_ACCEPTANCE_GATE`)';
  lines.push(['restore: or set', 'ZENSU_ACCEPTANCE_GATE', 'to off'].join(' '));
  return { remedy: 'ZENSU_ACCEPTANCE_GATE' };
  lines.push(`set ${'ZENSU_ACCEPTANCE_GATE'}=off`);
EOF
  cat > "$FIX/good.sh" <<'EOF'
[ "${ZENSU_ACCEPTANCE_GATE:-on}" = "off" ] && _avr_escape=1
tdd_record_bypass "$session" ZENSU_ACCEPTANCE_GATE >/dev/null 2>&1 || true
# A comment may explain ZENSU_CHAIN=off to a maintainer.
  (escaped) apv_gate="ZENSU_ACCEPTANCE_GATE" ;;
EOF
  cat > "$FIX/good.js" <<'EOF'
  if (process.env.ZENSU_SECRET_SCAN !== "off") {
  const ESCAPE_NAME = 'ZENSU_EDIT_LANDING_GATE';
  if (gate === 'ZENSU_ACCEPTANCE_GATE' || ["ZENSU_FULL_SUITE_GATE", 'ZENSU_CHAIN'].includes(gate)) {
    lines.push(`ACCEPTANCE — escaped | ZENSU_ACCEPTANCE_GATE=off switched this check off, so no acceptance record was read | gate`);
EOF
  BAD="$(scan "$FIX" bad.md bad.sh bad.js | sed '1d')"
  GOOD="$(scan "$FIX" good.sh good.js)"
  BAD_COUNT="$(printf '%s\n' "$BAD" | grep -c ':[0-9][0-9]*: ')"
  if [ "$BAD_COUNT" -eq 10 ] \
    && printf '%s\n' "$BAD" | grep -qF 'bad.md:1:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.sh:1:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.sh:3:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:1:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:2:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:3:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:4:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:5:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:6:' \
    && printf '%s\n' "$BAD" | grep -qF 'bad.js:7:'; then
    check "W3 a fixture that names an env-var escape as a remedy fails the scan, a name quoted inside prose, joined from pieces, used as a value or interpolated included (10 findings)" PASS
  else
    check "W3 fixture escape remedies were not all found ($BAD_COUNT): $(printf '%s' "$BAD" | tr '\n' ';')" FAIL
  fi
  if [ "$(printf '%s\n' "$GOOD" | sed '1d' | grep -c .)" -eq 0 ] \
    && printf '%s\n' "$GOOD" | grep -qF 'scanned=2 disclosed=1'; then
    check "W4 variable reads, ledger arguments, comments, name literals compared, assigned or looked up, and disclosures pass the scan" PASS
  else
    check "W4 the scan flagged code reads or disclosures: $(printf '%s' "$GOOD" | tr '\n' ';')" FAIL
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
const contexts = [{}, { zeroChangeTicket: true }, { currentTree: { tree: null, reason: 'the tree could not be fingerprinted' } }];
const segments = [];
for (const chain of chains) {
  for (const state of states) {
    for (const rows of combos) {
      for (const context of contexts) segments.push(...avr.remedies(state, rows, chain, '/project', context));
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

echo "----"
echo "test-escape-wording: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
