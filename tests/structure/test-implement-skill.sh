#!/bin/bash
set -u

# Structure test for the Zensu record steps of the /zensu:implement skill.
# Pins: Step 1's feature read names the feature_scope and estimated_effort that
# Step 6 picks the doc type from; Step 6 takes the required doc type(s) from the
# shared guide's "Required doc types (the release gate)" table (owned and pinned by
# test-doc-generation-guidance.sh), documents once per required type and reads
# docs_complete after linking; Step 7 reads the active revision before it creates
# one, creates nothing while a revision is open (the backend refuses a new revision
# until the latest one is shipped or superseded), treats that refusal as an open
# revision without a retry, and the summary and the CLI table report both outcomes.
# M11 bites the order check of M7 on fixture texts.
# Deliberately bash-3.2 compatible: no associative arrays (macOS /bin/bash is 3.2).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/implement/SKILL.md"
SCOPE_TITLE='Required doc types (the release gate)'
REFUSAL='previous revision must be released or superseded before creating a new one'

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "M1 skills/implement/SKILL.md exists" FAIL
  echo "----"
  echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "M1 skills/implement/SKILL.md exists" PASS

# section START STOP — the lines from the line that starts with START up to the next
# line that starts with STOP, whitespace-normalized to one line.
section() {
  awk -v start="$1" -v stop="$2" 'index($0, start) == 1 {p = 1} p && index($0, stop) == 1 {exit} p' "$SKILL_MD" \
    | tr -s '[:space:]' ' '
}
# has TEXT NEEDLE — PASS iff NEEDLE (fixed string) occurs in TEXT.
has() { printf '%s' "$1" | grep -qF -- "$2" && echo PASS || echo FAIL; }
# before TEXT FIRST THEN — PASS iff FIRST occurs in TEXT and its first occurrence
# comes before the first occurrence of THEN.
before() {
  T="$1" A="$2" B="$3" awk 'BEGIN {
    i = index(ENVIRON["T"], ENVIRON["A"]); j = index(ENVIRON["T"], ENVIRON["B"])
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}
all() { for v in "$@"; do [ "$v" = PASS ] || { echo FAIL; return; }; done; echo PASS; }

STEP1="$(section '### Step 1:' '### Step 2:')"
STEP6="$(section '### Step 6:' '### Step 7:')"
STEP7="$(section '### Step 7:' '### Step 8:')"
SUMMARY="$(section '### Summary' '## Important Notes')"
CLI_TABLE="$(section '## CLI Commands Used' '## Agents & Skills Used')"

check "M2 Step 1's feature read names the feature_scope and estimated_effort Step 6 picks the doc type from" \
  "$(has "$STEP1" '`feature_scope` and `estimated_effort` that Step 6 picks the doc type from')"

check "M3 Step 6 takes the required doc type(s) from the guide's '$SCOPE_TITLE' table" "$(all \
  "$(has "$STEP6" "The table under \"$SCOPE_TITLE\" in that guide maps the \`feature_scope\` and \`estimated_effort\`")" \
  "$(has "$STEP6" 'a feature with an unset scope needs `user_facing`, even a confidential backend feature')" \
  "$(has "$STEP6" 'Run the items below once per required type, with that type as every `<type>` and `--doc-type`')" \
  "$(has "$STEP6" '`--doc-type` (required): the required type this pass documents')")"

check "M4 Step 6 reads docs_complete after linking and never reports open docs as complete" "$(all \
  "$(has "$STEP6" 'read `docs_complete` from `zensu features get <feature-uuid>`')" \
  "$(has "$STEP6" 'report the docs as open, never as complete')" \
  "$(before "$STEP6" 'zensu link docs <feature-id>' 'read `docs_complete` from')")"

check "M5 Step 7 states the backend's one-open-revision rule with its refusal text" "$(all \
  "$(has "$STEP7" "it refuses a new one with HTTP 400 \`$REFUSAL\`")" \
  "$(has "$STEP7" 'A new top-level feature starts with an open `v1`')")"

check "M6 Step 7 calls a revision open when active_revision_id is set and stage is neither shipped nor superseded" \
  "$(has "$STEP7" '**A revision is open** when `active_revision_id` is set and `stage` is neither `shipped` nor `superseded`')"

check "M7 Step 7 reads the feature before it runs zensu features revision" "$(all \
  "$(has "$STEP7" 'Re-read the feature with `zensu features get <feature-uuid>` and take `active_revision_id` and `stage` from it')" \
  "$(before "$STEP7" 'zensu features get <feature-uuid>' 'zensu features revision <feature-id>')")"

check "M8 Step 7 creates nothing for an open revision and reports which one holds the work" "$(all \
  "$(has "$STEP7" 'Create nothing: this work belongs to that revision')" \
  "$(has "$STEP7" '(stage `<stage>`) holds this work; no new revision created')")"

check "M9 Step 7 creates a revision only when none is open and answers the refusal without a retry" "$(all \
  "$(has "$STEP7" '**No revision is open** (`stage` is `shipped` or `superseded`, or `active_revision_id` is null): run `zensu features revision <feature-id>`')" \
  "$(has "$STEP7" "If it still answers \`$REFUSAL\`, a revision opened in the meantime: report it as in item 2 and do not retry")")"

check "M10 the summary and the CLI table report the docs gate and both revision outcomes" "$(all \
  "$(has "$SUMMARY" 'Documentation linked (doc type(s) and whether `docs_complete` is `true`)')" \
  "$(has "$SUMMARY" 'Revision: the one created (version number), or the open revision this work belongs to (id and stage)')" \
  "$(has "$CLI_TABLE" '| `zensu features get` | 1, 6, 7 |')" \
  "$(has "$CLI_TABLE" '| `zensu features revision` | 7 | Create a feature revision when none is open |')")"

M11_GOOD='1. Re-read with `zensu features get <feature-uuid>`. 3. Run `zensu features revision <feature-id>`.'
M11_LATE='Run `zensu features revision <feature-id>`, then check `zensu features get <feature-uuid>`.'
M11_NONE='Run `zensu features revision <feature-id>`.'
check "M11 the order check passes the read-first text and fails a late or a missing read" "$(all \
  "$(before "$M11_GOOD" 'zensu features get <feature-uuid>' 'zensu features revision <feature-id>')" \
  "$([ "$(before "$M11_LATE" 'zensu features get <feature-uuid>' 'zensu features revision <feature-id>')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$M11_NONE" 'zensu features get <feature-uuid>' 'zensu features revision <feature-id>')" = FAIL ] && echo PASS || echo FAIL)")"

echo "----"
echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
