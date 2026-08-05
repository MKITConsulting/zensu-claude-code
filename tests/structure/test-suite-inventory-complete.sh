#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
MANIFEST="${ZENSU_SUITE_INVENTORY:-$ROOT/tests/profiles/promptfoo-local-only.v1.json}"
STRUCTURE_DIR="${ZENSU_SUITE_STRUCTURE_DIR:-$ROOT/tests/structure}"
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

check_detail() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    [ -n "$3" ] && printf '        %s\n' "$3"
    FAIL=$((FAIL + 1))
  fi
}

if [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ]; then
  check "Suite inventory is a real file" PASS
else
  check "Suite inventory is a real file" FAIL
  printf '%s\n' '----' "test-suite-inventory-complete: $PASS PASS / $FAIL FAIL"
  exit 1
fi

REPORT="$(node - "$MANIFEST" "$STRUCTURE_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [manifest, structureDir] = process.argv.slice(2);
const emit = (key, ok, detail) =>
  process.stdout.write(`${key}\t${ok ? 'PASS' : 'FAIL'}\t${detail || ''}\n`);

let value;
try {
  value = JSON.parse(fs.readFileSync(manifest, 'utf8'));
} catch (error) {
  emit('parses', false, error.message);
  process.exit(0);
}
emit('parses', true);
emit('schema', value.schemaVersion === 1, `schemaVersion=${JSON.stringify(value.schemaVersion)}`);

const wellFormed = (field) =>
  Array.isArray(value[field])
  && value[field].every((entry) => typeof entry === 'string' && entry.length > 0);
const fieldsOk = wellFormed('ciStructureTests') && wellFormed('localStructureTests');
emit('fields', fieldsOk, 'both arrays must hold non-empty strings');
if (!fieldsOk) process.exit(0);

const ci = value.ciStructureTests;
const local = value.localStructureTests;
const classified = [...ci, ...local];
const actual = fs.readdirSync(structureDir)
  .filter((name) => /^test-.*\.sh$/.test(name))
  .sort();

const seen = new Set();
const duplicates = [...new Set(classified.filter((n) => seen.size === seen.add(n).size))].sort();
emit('duplicates', duplicates.length === 0, duplicates.join(', '));

const known = new Set(classified);
const missing = actual.filter((name) => !known.has(name));
emit('missing', missing.length === 0, missing.join(', '));

const present = new Set(actual);
const stale = classified.filter((name) => !present.has(name)).sort();
emit('stale', stale.length === 0, stale.join(', '));

const notPromptfoo = local.filter((name) => !name.includes('promptfoo')).sort();
emit('localScope', notPromptfoo.length === 0, notPromptfoo.join(', '));

const notRegular = classified.filter((name) => {
  const target = path.join(structureDir, name);
  if (!present.has(name)) return false;
  const stats = fs.lstatSync(target);
  return !stats.isFile() || stats.isSymbolicLink();
}).sort();
emit('regularFiles', notRegular.length === 0, notRegular.join(', '));
NODE
)"

verdict() {
  printf '%s\n' "$REPORT" | awk -F'\t' -v key="$1" '$1 == key { print $2; exit }'
}

detail() {
  printf '%s\n' "$REPORT" | awk -F'\t' -v key="$1" '$1 == key { print $3; exit }'
}

for probe in \
  "parses|Suite inventory parses as JSON" \
  "schema|Suite inventory declares schemaVersion 1" \
  "fields|Both classification arrays hold non-empty strings" \
  "duplicates|No suite is classified twice" \
  "missing|Every tests/structure suite is classified" \
  "stale|No classified suite is missing from disk" \
  "localScope|Local-only classification holds Promptfoo suites only" \
  "regularFiles|Every classified suite is a regular file"
do
  key="${probe%%|*}"
  label="${probe#*|}"
  result="$(verdict "$key")"
  if [ "$result" = PASS ]; then
    check "$label" PASS
  else
    check_detail "$label" FAIL "$(detail "$key")"
  fi
done

printf '%s\n' '----' "test-suite-inventory-complete: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
