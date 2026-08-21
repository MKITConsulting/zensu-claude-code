#!/bin/bash
# --tdd-complete refuses when the session's TDD plan has no usable Requirements table.
#
# /zensu:converge anchors its whole flow-back audit on that table. Without one it
# takes its documented legacy stop and reports nothing — and in /zensu:autopilot
# the CONVERGE stage is the ONLY edge into OPEN_PR, so the mandatory gate passes
# on an audit that examined nothing. Both ends stay green, which is why nobody
# noticed: measured across the real plan corpus on the author's machine, a third
# of plans written after the feature shipped carry no table at all.
#
# The load-bearing cases are the resolution ones. A gate that judges the WRONG
# plan is worse than no gate: the project accumulates plans, so "newest by mtime"
# would let a stale plan from an earlier session satisfy this one forever. The
# derivation therefore runs through the edit-landing receipt's record of the run
# log it audited. D1/D2 exercise that derivation against a receipt this suite
# writes; WS1 is the one check that drives the REAL writer into it, which is what
# would catch a renamed `log` key or a writer that stopped absolutizing the path.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
REQ="$PLUGIN_DIR/hooks/lib/zensu-plan-requirements.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

T_PASS=0; T_FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; T_PASS=$((T_PASS+1));
  else echo "  FAIL  $label"; T_FAIL=$((T_FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PROJ="$(mktemp -d)" || exit 1
export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$PROJ/.zensu/state"; export STATE_DIR
cleanup() { [ -n "${PROJ:-}" ] && rm -rf "$PROJ"; return 0; }
trap cleanup EXIT INT TERM
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN \
  ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

echo "== FR-001: the library judges a plan on its own =="
FIX="$(mktemp -d)" || exit 1
cat > "$FIX/filled.md" <<'PLAN'
# TDD Plan: filled

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the gate refuses a plan with no table | spec |
| FR-001 | the library is callable standalone | spec |

## Preconditions
PLAN
cat > "$FIX/placeholder.md" <<'PLAN'
# TDD Plan: placeholder

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | {acceptance criterion — machine-checkable} | spec |
| FR-001 | {functional requirement} | spec |

## Preconditions
PLAN
cat > "$FIX/none.md" <<'PLAN'
# TDD Plan: none

## Steps
| Step | Type |
|------|------|
PLAN
# A row whose text merely MENTIONS braces is filled in. The requirement that
# describes this very check reads "...still carries {placeholder} braces", and a
# brace-anywhere rule would reject it.
cat > "$FIX/quotes-braces.md" <<'PLAN'
# TDD Plan: quotes braces

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-002 | it refuses when the cell still carries {placeholder} braces | spec |

## Preconditions
PLAN
# `### Step ...` must NOT close the section: its third character is `#`, not a
# space. A section-end rule that fired on it would drop every row written below
# a step subsection.
cat > "$FIX/rows-after-subheading.md" <<'PLAN'
# TDD Plan: subheading

## Requirements
### Group A
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | a real requirement below a level-3 subheading | spec |

## Preconditions
PLAN
# Rows that sit OUTSIDE the section are not the section's rows.
cat > "$FIX/rows-outside.md" <<'PLAN'
# TDD Plan: outside

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|

## Notes
| AC-001 | a row that is not in the Requirements section | spec |
PLAN

bash "$REQ" --plan "$FIX/filled.md" >/dev/null 2>&1
check "L1 exit 0 for a filled table" "$(verdict $?)"
bash "$REQ" --plan "$FIX/none.md" >/dev/null 2>&1
[ $? -eq 3 ]
check "L2 exit 3 when there is no ## Requirements section" "$(verdict $?)"
bash "$REQ" --plan "$FIX/placeholder.md" >/dev/null 2>&1
[ $? -eq 4 ]
check "L3 exit 4 when every row still holds the template placeholder" "$(verdict $?)"
bash "$REQ" --plan "$FIX/missing.md" >/dev/null 2>&1
[ $? -eq 2 ]
check "L4 exit 2 when the plan file does not exist" "$(verdict $?)"
bash "$REQ" >/dev/null 2>&1
[ $? -eq 2 ]
check "L5 exit 2 when --plan is omitted" "$(verdict $?)"
bash "$REQ" --plan "$FIX/quotes-braces.md" >/dev/null 2>&1
check "L6 a requirement that merely quotes {braces} counts as filled" "$(verdict $?)"
bash "$REQ" --plan "$FIX/rows-after-subheading.md" >/dev/null 2>&1
check "L7 a '### ' subheading does not close the Requirements section" "$(verdict $?)"
bash "$REQ" --plan "$FIX/rows-outside.md" >/dev/null 2>&1
[ $? -eq 4 ]
check "L8 an AC row under a LATER '## ' section is not counted" "$(verdict $?)"
bash "$REQ" --plan "$FIX/filled.md" 2>/dev/null | grep -qF 'PLAN REQUIREMENTS OK'
check "L9 the verdict line names the outcome in one line" "$(verdict $?)"
# CRLF must not hide the heading behind an unmatched `$`.
sed $'s/$/\r/' "$FIX/filled.md" > "$FIX/filled-crlf.md"
# Confirm the fixture really carries CRLF before asserting anything about it: a
# sed that treated the replacement literally would give `## Requirementsr`, and
# L10 would then fail on a premise unrelated to the contract it names.
grep -q $'\r$' "$FIX/filled-crlf.md"
check "L10pre the CRLF fixture really contains carriage returns" "$(verdict $?)"
bash "$REQ" --plan "$FIX/filled-crlf.md" >/dev/null 2>&1
check "L10 a CRLF plan is judged the same as an LF plan" "$(verdict $?)"
# The Requirement column is located from the header row, and a row is recognized
# by an id in ANY cell. Both rules are dead-equivalent to their fallbacks unless a
# fixture actually re-orders the columns — deleting them would otherwise leave the
# whole suite green. In the re-ordered shape the fallback (split index 3) holds
# the ID cell, so a placeholder table would score as FILLED without the rules.
cat > "$FIX/reordered.md" <<'PLAN'
# TDD Plan: reordered

## Requirements
| Requirement | ID | Source |
|-------------|----|--------|
| a real requirement in the FIRST visible column | AC-001 | spec |

## Preconditions
PLAN
cat > "$FIX/reordered-placeholder.md" <<'PLAN'
# TDD Plan: reordered placeholder

## Requirements
| Requirement | ID | Source |
|-------------|----|--------|
| {acceptance criterion — machine-checkable} | AC-001 | spec |

## Preconditions
PLAN
bash "$REQ" --plan "$FIX/reordered.md" >/dev/null 2>&1
check "L11 a re-ordered header locates the Requirement column (id not in cell 1)" "$(verdict $?)"
bash "$REQ" --plan "$FIX/reordered-placeholder.md" >/dev/null 2>&1
[ $? -eq 4 ]
check "L12 a re-ordered placeholder table is still EMPTY (split index 3 holds AC-001, which the fallback would score as filled)" "$(verdict $?)"
# The symlink refusal and the size cap are the two guards that exist because the
# plan path can be DERIVED; neither is observable from any other check.
ln -s "$FIX/filled.md" "$FIX/linked.md" 2>/dev/null
if [ -L "$FIX/linked.md" ] && [ "$(readlink "$FIX/linked.md")" = "$FIX/filled.md" ]; then
  ERR_L13="$(bash "$REQ" --plan "$FIX/linked.md" 2>&1 >/dev/null)"
  [ $? -eq 2 ] && printf '%s' "$ERR_L13" | grep -qF 'is a symlink'
  check "L13 a symlinked plan is refused, not followed" "$(verdict $?)"
else
  check "L13 SKIPPED — this filesystem produced no real symlink" PASS
fi
# `mkfile`-free, portable, and fast: seek past the cap rather than writing 4 MiB.
if dd if=/dev/zero of="$FIX/big.md" bs=1 count=1 seek=4194304 >/dev/null 2>&1 \
   && [ "$(wc -c < "$FIX/big.md" | tr -d '[:space:]')" -gt 4194304 ]; then
  ERR_L14="$(bash "$REQ" --plan "$FIX/big.md" 2>&1 >/dev/null)"
  [ $? -eq 2 ] && printf '%s' "$ERR_L14" | grep -qF 'exceeds 4 MiB'
  check "L14 an oversized plan is refused by the cap, not streamed through awk" "$(verdict $?)"
else
  check "L14 SKIPPED — could not create an oversized fixture" PASS
fi
# A fenced code block is DATA. Without the fence rule a plan that merely
# ILLUSTRATES the table (this repo's own docs do) reads as having a real one,
# and an H2 quoted inside a fence closes a real section. Both directions silent.
cat > "$FIX/fenced-only.md" <<'PLAN'
# TDD Plan: fenced only

## Steps
Example of the shape a plan must carry:

```
## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | an illustration, not a real requirement | spec |
```
PLAN
cat > "$FIX/fenced-inside.md" <<'PLAN'
# TDD Plan: fenced inside

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | a real requirement | spec |

```
## Not A Real Heading
| AC-999 | an illustration inside a fence | spec |
```

## Preconditions
PLAN
bash "$REQ" --plan "$FIX/fenced-only.md" >/dev/null 2>&1
[ $? -eq 3 ]
check "L16 a table that exists only inside a fence is not a table" "$(verdict $?)"
OUT_L17="$(bash "$REQ" --plan "$FIX/fenced-inside.md" 2>/dev/null)"
[ $? -eq 0 ] && printf '%s' "$OUT_L17" | grep -qF '1/1 AC/FR row'
check "L17 a fenced block after the table neither closes it nor adds rows" "$(verdict $?)"
# The documented fallback (split index 3) when no header row is recognizable.
cat > "$FIX/no-header.md" <<'PLAN'
# TDD Plan: no header

## Requirements
| AC-001 | a real requirement with no header row above it | spec |

## Preconditions
PLAN
cat > "$FIX/fence-unterminated.md" <<'PLAN'
# TDD Plan: unterminated

## Context
```
an opening fence that is never closed

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | a real requirement the fence swallows | spec |
PLAN
ERR_L19="$(bash "$REQ" --plan "$FIX/fence-unterminated.md" 2>&1 >/dev/null)"
[ $? -eq 2 ] && printf '%s' "$ERR_L19" | grep -qF 'unterminated code fence'
check "L19 an unterminated fence is a parse failure, not a verdict about the table" "$(verdict $?)"
bash "$REQ" --plan "$FIX/no-header.md" >/dev/null 2>&1
check "L18 a table with no recognizable header row falls back to split index 3" "$(verdict $?)"
# The cap is a hand-copy of plan-payload-v1.js's exported PLAN_FILE_MAX_BYTES,
# and this suite would be a third copy. Derive it from the module instead, so a
# change to the exported constant fails here rather than drifting silently.
CAP_EXPORTED="$(node -e 'process.stdout.write(String(require(process.argv[1]).PLAN_FILE_MAX_BYTES))' "$PLUGIN_DIR/hooks/lib/plan-payload-v1.js" 2>/dev/null)"
CAP_LIB="$(grep -oE '\-le [0-9]+' "$REQ" | head -1 | tr -dc '0-9')"
[ -n "$CAP_EXPORTED" ] && [ "$CAP_EXPORTED" = "$CAP_LIB" ]
check "L15 the library's size cap equals plan-payload-v1.js's exported PLAN_FILE_MAX_BYTES" "$(verdict $?)"
rm -rf "$FIX"

echo "== AC-004: a chain that changed nothing is out of scope =="
# Same construction as the edit-landing receipt gate's own suite: Session Control
# binds the project, so a live clean-tree session cannot be staged here. What IS
# verifiable is the predicate the gate scopes on.
CLEAN_FIX="$(mktemp -d)" || exit 1
git init -q --template= "$CLEAN_FIX" >/dev/null 2>&1
printf 'v1\n' > "$CLEAN_FIX/a.txt"
printf '.zensu/\n' > "$CLEAN_FIX/.gitignore"
git -C "$CLEAN_FIX" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$CLEAN_FIX" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
mkdir -p "$CLEAN_FIX/.zensu/state"; printf '{}' > "$CLEAN_FIX/.zensu/state/probe.json"
CLEAN_COUNT="$( { git -C "$CLEAN_FIX" diff --name-only HEAD 2>/dev/null
                  git -C "$CLEAN_FIX" ls-files --others --exclude-standard 2>/dev/null; } \
                | sort -u | grep -c . )"
rm -rf "$CLEAN_FIX"
[ "$CLEAN_COUNT" -eq 0 ]
check "Z1 the scoping predicate reports zero changes for a clean project" "$(verdict $?)"
# Anchored on the LIBRARY INVOCATION, not on the switch name. The switch is also
# named by the change-set hoist the two gates share, which sits above the gate
# block — so a window that only proves the switch appears stays green with the
# whole gate deleted. The invocation is the one line that cannot survive that.
grep -qF 'bash "$_rq_lib" --plan "$_rq_plan"' "$LOG"
check "Z2 the gate really invokes the validation library" "$(verdict $?)"
# The gate and the receipt gate must scope on ONE change count, not two.
# One computation, and every consumer conjoins on it: the two gates and the two
# bypass-ledger records (an escape from a gate that never ran is not an escape).
[ "$(grep -c '_tc_changes="\$(' "$LOG")" -eq 1 ] \
  && [ "$(grep -c '\${_tc_changes:-0}" -gt 0' "$LOG")" -eq 4 ]
check "Z3 both gates AND both ledger records scope on the same single change count" "$(verdict $?)"
# The count is computed UNCONDITIONALLY once a git HEAD resolves — not gated on
# either switch. Gating it on "either gate armed" left the count at 0 when BOTH
# were off, and the two bypass-ledger records conjoin on it, so neither escape
# was recorded while both docs promise the recording unconditionally.
# Line ORDER, not a proximity window: a distance window has to be widened every
# time a comment lands in between, and it silently stops discriminating when the
# regression fits inside the slack.
COUNT_LN="$(grep -n '_tc_changes="\$(' "$LOG" | head -1 | cut -d: -f1)"
SWITCH_LN="$(grep -nE 'ZENSU_(EDIT_LANDING|REQUIREMENTS)_GATE:-on' "$LOG" | head -1 | cut -d: -f1)"
HEAD_LN="$(grep -n 'if _tc_git -C "\$_tc_root" rev-parse --verify --quiet HEAD' "$LOG" | head -1 | cut -d: -f1)"
[ -n "$COUNT_LN" ] && [ -n "$SWITCH_LN" ] && [ -n "$HEAD_LN" ] \
  && [ "$HEAD_LN" -lt "$COUNT_LN" ] && [ "$COUNT_LN" -lt "$SWITCH_LN" ]
check "Z4 the change count is computed on a resolvable HEAD BEFORE any switch is consulted" "$(verdict $?)"
! awk '/--tdd-complete\)/,/^        ;;/' "$LOG" \
  | grep -qF 'ZENSU_EDIT_LANDING_GATE:-on}" != "off" ] || [ "${ZENSU_REQUIREMENTS_GATE:-on}" != "off"'
check "Z4b the count is no longer conditioned on either switch being armed" "$(verdict $?)"
# ... and the root it is measured on is the session-bound one, not the ambient env.
! awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF 'git -C "${CLAUDE_PROJECT_DIR:-.}"'
check "Z5 the change set is measured on the session-bound root" "$(verdict $?)"
# GIT_DIR and friends override `-C`, so an unscrubbed call would let a one-token
# prefix zero the count and disarm both gates AND both ledger records at once.
# The DEFINITION alone proves nothing — reverting only the call sites to bare
# `git -C` would leave a definition-only pin green while restoring the defect. Pin
# that all three scope calls go through the wrapper, and that none is bare.
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF 'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE'
Z6DEF=$?
[ "$(awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -c '_tc_git -C "\$_tc_root"')" -eq 3 ]
Z6USE=$?
! awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qE '(^|[^_])git -C "\$_tc_root"'
Z6BARE=$?
[ "$Z6DEF" -eq 0 ] && [ "$Z6USE" -eq 0 ] && [ "$Z6BARE" -eq 0 ]
check "Z6 all three scope git calls go through the environment-scrubbing wrapper" "$(verdict $?)"

echo "== Session fixtures =="
git init -q --template= "$PROJ" >/dev/null 2>&1
printf 'v1\n' > "$PROJ/tracked.txt"
# `.session-control-test/` matters as much as `.zensu/`: initialize-baseline.sh
# defaults its plugin data to `$CLAUDE_PROJECT_DIR/.session-control-test/plugin-data`,
# so leaving it untracked makes the project dirty from the baseline loop onward —
# and every "the project is clean here" claim below would be false while every
# check still passed.
printf '.zensu/\n.session-control-test/\n' > "$PROJ/.gitignore"
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm base >/dev/null 2>&1
for SID in rq-missing rq-placeholder rq-filled rq-explicit rq-explicit-absent \
           rq-escape rq-landing-off rq-no-receipt rq-converse rq-explicit-relative \
           rq-explicit-outside rq-explicit-stem rq-relative-log rq-outside-log \
           rq-wrong-schema rq-malformed rq-clean-tree rq-symlink-plans \
           rq-symlink-logs rq-no-stem rq-stem-unchecked rq-writer-seam rq-both-off; do
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$SID"
done
activate_session() {
  export CLAUDE_CODE_SESSION_ID="$1"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-session.sh"
  zensu_bind_model_session
}
# shellcheck disable=SC1090
source "$PHASE_LIB"

receipt_for() {  # echo the path the GATE will look at for session $1
  local sf key
  sf="$(tdd_state_file "$1")"
  key="$(basename "$sf")"; key="${key#tdd-phase-}"; key="${key%.json}"
  printf '%s' "$(dirname "$sf")/edit-landing-${key}.json"
}
# Stage one session: arm it, plant a run log with the given plan body beside a
# same-stem plan, and deposit a receipt naming that log — the exact shape the
# edit-landing library writes.
stage() {  # stage <session> <stem> <plan-body-file|->
  local sid="$1" stem="$2" body="$3" rp
  # A silently failed arming would make every refusal check below pass for the
  # wrong reason, so the helper reports it instead of discarding the status.
  if ! bash "$LOG" --tdd-begin --session "$sid" >/dev/null 2>&1; then
    check "stage(): --tdd-begin failed for session $sid" FAIL
    return 1
  fi
  mkdir -p "$PROJ/.zensu/logs" "$PROJ/.zensu/plans"
  printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/${stem}.log"
  if [ "$body" != "-" ]; then cp "$body" "$PROJ/.zensu/plans/${stem}.md"; fi
  rp="$(receipt_for "$sid")"
  mkdir -p "$(dirname "$rp")"
  printf '{"schema":"edit-landing-v1","session":"%s","log":"%s","claims":1,"landed":1,"notLanded":0,"unverified":0,"pending":0,"exemptIgnored":0,"exemptVerified":0,"clean":true}\n' \
    "$sid" "$PROJ/.zensu/logs/${stem}.log" > "$rp"
}
BODIES="$(mktemp -d)" || exit 1
cat > "$BODIES/filled.md" <<'PLAN'
## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | the gate refuses a plan with no table | spec |
PLAN
cat > "$BODIES/placeholder.md" <<'PLAN'
## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | {acceptance criterion — machine-checkable} | spec |
PLAN
cat > "$BODIES/none.md" <<'PLAN'
## Steps
| Step | Type |
|------|------|
PLAN

# From here on the project really changed, so both gates are in scope.
printf 'v2\n' > "$PROJ/tracked.txt"

echo "== AC-001: no Requirements section =="
SID_M="rq-missing"
activate_session "$SID_M"
stage "$SID_M" "2026-01-01-0101_tdd-missing" "$BODIES/none.md"
ERR_M="$(bash "$LOG" --tdd-complete --session "$SID_M" 2>&1 >/dev/null)"
RC_M=$?
[ "$RC_M" -ne 0 ]
check "M1 --tdd-complete exits non-zero when the plan has no Requirements table" "$(verdict $?)"
printf '%s' "$ERR_M" | grep -qF 'no usable `## Requirements` table'
check "M2 the refusal names the missing table" "$(verdict $?)"
printf '%s' "$ERR_M" | grep -qF '/zensu:converge'
check "M3 the refusal explains what the table is for, not just that it failed" "$(verdict $?)"
printf '%s' "$ERR_M" | grep -qF 'ZENSU_REQUIREMENTS_GATE=off'
check "M4 the refusal documents the escape hatch instead of hiding it" "$(verdict $?)"
printf '%s' "$ERR_M" | grep -qF '2026-01-01-0101_tdd-missing.md'
check "M5 the refusal names the plan path it judged" "$(verdict $?)"
[ "$(tdd_get_flag "$(tdd_state_file "$SID_M")" implComplete)" != "true" ]
check "M6 a refused completion leaves implComplete unset" "$(verdict $?)"

echo "== AC-002: placeholder-only table =="
SID_P="rq-placeholder"
activate_session "$SID_P"
stage "$SID_P" "2026-01-01-0202_tdd-placeholder" "$BODIES/placeholder.md"
ERR_P="$(bash "$LOG" --tdd-complete --session "$SID_P" 2>&1 >/dev/null)"
RC_P=$?
# A bare non-zero status cannot tell THIS refusal from the session-state refusal,
# the edit-landing refusal or a usage error, all of which exit non-zero on the
# same path. Grep the library's own verdict vocabulary instead.
[ "$RC_P" -ne 0 ] && printf '%s' "$ERR_P" | grep -qF 'PLAN REQUIREMENTS EMPTY'
check "P1 a table whose rows are still template placeholders is refused BY THIS GATE" "$(verdict $?)"
[ "$(tdd_get_flag "$(tdd_state_file "$SID_P")" implComplete)" != "true" ]
check "P2 the placeholder refusal leaves implComplete unset" "$(verdict $?)"

echo "== AC-003 / AC-005: a filled table, resolved through the receipt =="
SID_F="rq-filled"
activate_session "$SID_F"
stage "$SID_F" "2026-01-01-0303_tdd-filled" "$BODIES/filled.md"
bash "$LOG" --tdd-complete --session "$SID_F" >/dev/null 2>&1
[ $? -eq 0 ]
check "D1 completion is accepted when the derived plan carries a filled table" "$(verdict $?)"
[ "$(tdd_get_flag "$(tdd_state_file "$SID_F")" implComplete)" = "true" ]
check "D2 the accepted completion actually marks implComplete" "$(verdict $?)"
# Negative control for E5, read while THIS session is bound: a chain that never
# took the escape records nothing, so E5 observes the escape rather than a name
# the ledger always carries.
! tdd_bypasses "$(tdd_state_file "$SID_F")" 2>/dev/null | grep -qF 'ZENSU_REQUIREMENTS_GATE'
check "E5b a session that never took the escape records no such entry" "$(verdict $?)"
# D1/D2 pass only if the derivation found the plan at all — a gate that resolved
# nothing would also "accept". The discriminator is the diagnostic the gate emits
# in exactly that case: an accepted completion that judged NOTHING says so.
ERR_D="$(bash "$LOG" --tdd-complete --session "$SID_F" 2>&1 >/dev/null)"
RC_D=$?
# The exit status is conjoined: an absence assertion alone is satisfied by a run
# that never reached the gate at all (a session-state refusal exits above it).
[ "$RC_D" -eq 0 ] && ! printf '%s' "$ERR_D" | grep -qF 'REQUIREMENTS GATE UNRESOLVED'
check "D3 the accepted completion judged a plan rather than skipping (no UNRESOLVED line)" "$(verdict $?)"

echo "== AC-005: the explicit --plan channel =="
SID_X="rq-explicit"
activate_session "$SID_X"
# The flag names the session's OWN plan, whose body is unusable: if the flag were
# ignored the derived sibling is the same file, so the discriminator is the
# verdict text, not merely a non-zero status.
stage "$SID_X" "2026-01-01-0404_tdd-explicit" "$BODIES/none.md"
ERR_X="$(bash "$LOG" --tdd-complete --session "$SID_X" --plan "$PROJ/.zensu/plans/2026-01-01-0404_tdd-explicit.md" 2>&1 >/dev/null)"
RC_X=$?
[ "$RC_X" -ne 0 ] && printf '%s' "$ERR_X" | grep -qF 'PLAN REQUIREMENTS MISSING'
check "X1 an explicit --plan is judged by this gate" "$(verdict $?)"
# A relative --plan must be anchored on the project, not on the caller's cwd:
# the skill teaches the project-relative spelling, and this channel is fail-closed.
SID_XR="rq-explicit-relative"
activate_session "$SID_XR"
stage "$SID_XR" "2026-01-01-0909_tdd-relative" "$BODIES/filled.md"
( cd / && bash "$LOG" --tdd-complete --session "$SID_XR" --plan ".zensu/plans/2026-01-01-0909_tdd-relative.md" >/dev/null 2>&1 )
[ $? -eq 0 ]
check "X1b a project-relative --plan resolves from a foreign cwd" "$(verdict $?)"
# A --plan outside the project's own plans directory is refused: without this the
# flag silently defeats the session anchoring the derivation exists to provide.
SID_XO="rq-explicit-outside"
activate_session "$SID_XO"
stage "$SID_XO" "2026-01-01-1010_tdd-outside" "$BODIES/filled.md"
OUTSIDE="$(mktemp -d)/foreign.md"; cp "$BODIES/filled.md" "$OUTSIDE"
ERR_XO="$(bash "$LOG" --tdd-complete --session "$SID_XO" --plan "$OUTSIDE" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_XO" | grep -qF 'outside'
check "X1c a --plan outside .zensu/plans/ is refused, naming the containment" "$(verdict $?)"
rm -rf "$(dirname "$OUTSIDE")"
# A plan under .zensu/plans/ but from another session is refused on the stem.
SID_XS="rq-explicit-stem"
activate_session "$SID_XS"
stage "$SID_XS" "2026-01-01-1111_tdd-stem" "$BODIES/filled.md"
cp "$BODIES/filled.md" "$PROJ/.zensu/plans/2020-01-01-0000_tdd-someone-else.md"
ERR_XS="$(bash "$LOG" --tdd-complete --session "$SID_XS" --plan "$PROJ/.zensu/plans/2020-01-01-0000_tdd-someone-else.md" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_XS" | grep -qF 'run log sibling'
check "X1d a stale plan from another session cannot satisfy the gate through --plan" "$(verdict $?)"
SID_XA="rq-explicit-absent"
activate_session "$SID_XA"
stage "$SID_XA" "2026-01-01-0505_tdd-explicit-absent" "$BODIES/filled.md"
rm -f "$PROJ/.zensu/plans/2026-01-01-0505_tdd-explicit-absent.md"
ERR_XA="$(bash "$LOG" --tdd-complete --session "$SID_XA" --plan "$PROJ/.zensu/plans/2026-01-01-0505_tdd-explicit-absent.md" 2>&1 >/dev/null)"
RC_XA=$?
[ "$RC_XA" -ne 0 ] && printf '%s' "$ERR_XA" | grep -qF 'could not judge the plan'
check "X2 an explicit --plan that names nothing refuses, and does NOT claim the table was read" "$(verdict $?)"
# `grep -qv` inverts per LINE, and both refusal texts are multi-line, so it would
# pass either way. The assertion has to be absence over the WHOLE payload.
! printf '%s' "$ERR_XA" | grep -qF 'carries no usable'
check "X2b the unreadable-plan refusal is distinguishable from the empty-table refusal" "$(verdict $?)"
# Positive control: the empty-table refusal DOES carry that phrase, so X2b is
# asserting a real difference rather than a phrase nothing ever emits.
printf '%s' "$ERR_P" | grep -qF 'carries no usable'
check "X2c the empty-table refusal really does carry the phrase X2b excludes" "$(verdict $?)"
ERR_X3="$(bash "$LOG" --tdd-begin --session "$SID_XA" --plan "$PROJ/x.md" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_X3" | grep -qF 'option is not valid for this verb'
check "X3 --plan is refused on a verb that cannot act on it" "$(verdict $?)"
ERR_X4="$(bash "$LOG" --tdd-complete --session "$SID_XA" --plan "" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_X4" | grep -qF 'must not be empty'
check "X4 an empty --plan is a usage error, not a plan-content verdict" "$(verdict $?)"

echo "== AC-006: the escape hatch, and its independence =="
SID_E="rq-escape"
activate_session "$SID_E"
stage "$SID_E" "2026-01-01-0606_tdd-escape" "$BODIES/none.md"
ZENSU_REQUIREMENTS_GATE=off bash "$LOG" --tdd-complete --session "$SID_E" >/dev/null 2>&1
[ $? -eq 0 ]
check "E1 ZENSU_REQUIREMENTS_GATE=off bypasses the gate for an exempted session" "$(verdict $?)"
# Read the ledger HERE, while this session is still the bound one: the validated
# state read is ownership-checked, so doing it after a later activate_session
# returns empty for the wrong reason — which is exactly what happened first.
BYPASSES_E="$(tdd_bypasses "$(tdd_state_file "$SID_E")" 2>/dev/null)"
printf '%s' "$BYPASSES_E" | grep -qF 'ZENSU_REQUIREMENTS_GATE'
check "E5 taking this gate's escape records a real ledger entry" "$(verdict $?)"
# The two gates share a change-set computation but must not share a switch:
# exempting a session from the edit-landing receipt must not silently disarm the
# requirements table as well.
SID_L="rq-landing-off"
activate_session "$SID_L"
stage "$SID_L" "2026-01-01-0707_tdd-landing-off" "$BODIES/none.md"
ERR_L="$(ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --tdd-complete --session "$SID_L" \
  --plan "$PROJ/.zensu/plans/2026-01-01-0707_tdd-landing-off.md" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_L" | grep -qF 'PLAN REQUIREMENTS MISSING'
check "E2 ZENSU_EDIT_LANDING_GATE=off does NOT disable the requirements gate" "$(verdict $?)"
# The converse: this gate's own switch must not disarm the edit-landing one.
SID_C="rq-converse"
activate_session "$SID_C"
bash "$LOG" --tdd-begin --session "$SID_C" >/dev/null 2>&1
ERR_C="$(ZENSU_REQUIREMENTS_GATE=off bash "$LOG" --tdd-complete --session "$SID_C" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_C" | grep -qF 'no edit-landing receipt'
check "E3 ZENSU_REQUIREMENTS_GATE=off leaves the edit-landing gate armed" "$(verdict $?)"
# Both escapes are ledgered: everything a chain renders under "Gates bypassed"
# has to be true, and an unrecordable name would make that silently incomplete.
# Scoped to the ALLOWLIST ASSIGNMENT, not to the file: the names appear in
# comments too, and a grep that matches those would pass with the allowlist
# unchanged — which is the whole failure this check exists to catch.
grep -E '^ZENSU_BYPASS_GATE_ALLOWLIST=' "$PHASE_LIB" | grep -qF 'ZENSU_REQUIREMENTS_GATE' \
  && grep -E '^ZENSU_BYPASS_GATE_ALLOWLIST=' "$PHASE_LIB" | grep -qF 'ZENSU_EDIT_LANDING_GATE'
check "E4 both escape names are in the bypass-ledger ALLOWLIST assignment" "$(verdict $?)"
# E5 reads the ledger the escape actually produced, rather than grepping for the
# call site. E1 above took the escape on this session with a real change set.

# Both switches off must still record BOTH escapes. This is the exact shape a
# round-3 change broke: the change count was gated on "either gate armed", so
# with both off it stayed 0 and the two records — which conjoin on it — were
# skipped, while both docs promise the recording unconditionally.
SID_BOTH="rq-both-off"
activate_session "$SID_BOTH"
stage "$SID_BOTH" "2026-01-01-2121_tdd-both-off" "$BODIES/none.md"
ZENSU_EDIT_LANDING_GATE=off ZENSU_REQUIREMENTS_GATE=off bash "$LOG" --tdd-complete --session "$SID_BOTH" >/dev/null 2>&1
BYPASSES_BOTH="$(tdd_bypasses "$(tdd_state_file "$SID_BOTH")" 2>/dev/null)"
printf '%s' "$BYPASSES_BOTH" | grep -qF 'ZENSU_REQUIREMENTS_GATE' \
  && printf '%s' "$BYPASSES_BOTH" | grep -qF 'ZENSU_EDIT_LANDING_GATE'
check "E6 both switches off still records BOTH ledger escapes" "$(verdict $?)"

# The STEM UNCHECKED branch DROPS a documented bound, so it is the one that most
# needs a check: no receipt (the landing gate is off), an explicit --plan naming a
# STALE plan, and the run is accepted with the weaker state disclosed.
SID_SU="rq-stem-unchecked"
activate_session "$SID_SU"
bash "$LOG" --tdd-begin --session "$SID_SU" >/dev/null 2>&1
mkdir -p "$PROJ/.zensu/plans"
cp "$BODIES/filled.md" "$PROJ/.zensu/plans/2019-01-01-0000_tdd-stale-but-filled.md"
ERR_SU="$(ZENSU_EDIT_LANDING_GATE=off bash "$LOG" --tdd-complete --session "$SID_SU" \
  --plan "$PROJ/.zensu/plans/2019-01-01-0000_tdd-stale-but-filled.md" 2>&1 >/dev/null)"
[ $? -eq 0 ] && printf '%s' "$ERR_SU" | grep -qF 'REQUIREMENTS GATE STEM UNCHECKED'
check "E7 with the receipt gate off the stem bound is dropped AND disclosed" "$(verdict $?)"

echo "== Derivation branches =="
# Nothing was asserted about where the plan is and nothing could be derived, so
# there is no claim to hold against the chain — but the gate must SAY what it
# judged, or "passed" and "never ran" are indistinguishable. Here the receipt's
# log resolves, so a plan is derived and simply absent.
SID_N="rq-no-receipt"
activate_session "$SID_N"
bash "$LOG" --tdd-begin --session "$SID_N" >/dev/null 2>&1
RP_N="$(receipt_for "$SID_N")"
mkdir -p "$(dirname "$RP_N")"
printf '{"schema":"edit-landing-v1","session":"%s","log":"%s","clean":true}\n' \
  "$SID_N" "$PROJ/.zensu/logs/never-written.log" > "$RP_N"
ERR_N="$(bash "$LOG" --tdd-complete --session "$SID_N" 2>&1 >/dev/null)"
[ $? -eq 0 ]
check "N1 a receipt whose log has no sibling plan does not refuse" "$(verdict $?)"
# This receipt's log resolves cleanly, so a plan IS derived — it just does not
# exist. That is the FIRST arm of the split message, and nothing else pins it.
printf '%s' "$ERR_N" | grep -qF 'the plan derived for this session does not exist'
check "N1b it names the derived-but-missing cause, not the generic one" "$(verdict $?)"
# A relative `log` is re-anchored on the project rather than on the caller's cwd.
SID_NR="rq-relative-log"
activate_session "$SID_NR"
stage "$SID_NR" "2026-01-01-1212_tdd-relative-log" "$BODIES/none.md"
printf '{"schema":"edit-landing-v1","session":"%s","log":".zensu/logs/2026-01-01-1212_tdd-relative-log.log","clean":true}\n' \
  "$SID_NR" > "$(receipt_for "$SID_NR")"
ERR_NR="$(bash "$LOG" --tdd-complete --session "$SID_NR" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_NR" | grep -qF 'PLAN REQUIREMENTS MISSING'
check "N2 a relative log path in the receipt still derives the plan" "$(verdict $?)"
# A `log` outside the project's logs directory derives nothing — the containment
# check is what stops a receipt from aiming the read anywhere on the host.
SID_NO="rq-outside-log"
activate_session "$SID_NO"
stage "$SID_NO" "2026-01-01-1313_tdd-outside-log" "$BODIES/none.md"
printf '{"schema":"edit-landing-v1","session":"%s","log":"%s","clean":true}\n' \
  "$SID_NO" "/tmp/elsewhere/.zensu/logs/2026-01-01-1313_tdd-outside-log.log" > "$(receipt_for "$SID_NO")"
# The discriminator is the in-project same-stem plan `stage` already wrote: a gate
# that resolved the foreign log would derive THAT plan (the derived path is always
# project-rooted) and refuse. The needle is the cause-specific half of the split
# message, because the shared prefix is emitted by the other branch too.
ERR_NO="$(bash "$LOG" --tdd-complete --session "$SID_NO" 2>&1 >/dev/null)"
[ $? -eq 0 ] && printf '%s' "$ERR_NO" | grep -qF 'no --plan was passed and no plan could be derived'
check "N3 a log path outside the project's .zensu/logs derives nothing" "$(verdict $?)"
# A receipt this plugin did not write is not read: the schema discriminator binds.
SID_NS="rq-wrong-schema"
activate_session "$SID_NS"
stage "$SID_NS" "2026-01-01-1414_tdd-wrong-schema" "$BODIES/none.md"
printf '{"schema":"something-else","log":"%s"}\n' \
  "$PROJ/.zensu/logs/2026-01-01-1414_tdd-wrong-schema.log" > "$(receipt_for "$SID_NS")"
ERR_NS="$(bash "$LOG" --tdd-complete --session "$SID_NS" 2>&1 >/dev/null)"
[ $? -eq 0 ] && printf '%s' "$ERR_NS" | grep -qF 'REQUIREMENTS GATE UNRESOLVED'
check "N4 a receipt with a foreign schema is not mined for a plan path" "$(verdict $?)"
# Malformed JSON degrades to "nothing derived", never to a crash or a pass claim.
SID_NM="rq-malformed"
activate_session "$SID_NM"
stage "$SID_NM" "2026-01-01-1515_tdd-malformed" "$BODIES/none.md"
printf '{"schema":"edit-landing-v1","log":"broken\n' > "$(receipt_for "$SID_NM")"
ERR_NM="$(bash "$LOG" --tdd-complete --session "$SID_NM" 2>&1 >/dev/null)"
[ $? -eq 0 ] && printf '%s' "$ERR_NM" | grep -qF 'REQUIREMENTS GATE UNRESOLVED'
check "N5 an unparseable receipt derives nothing and says so" "$(verdict $?)"

echo "== AC-004: the not-gated states, driven through the real verb =="
# Z1 above only proves the predicate arithmetic. These drive --tdd-complete
# itself with an unusable plan staged, so a gate that ignored its scope would
# refuse here — the shape mirrors test-chain-terminus-zero-change-gate.sh.
SID_G1="rq-clean-tree"
activate_session "$SID_G1"
stage "$SID_G1" "2026-01-01-1616_tdd-clean-tree" "$BODIES/none.md"
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null add -A >/dev/null 2>&1
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=zensu-test \
  -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm "clean for G1" >/dev/null 2>&1
CLEAN_NOW="$( { git -C "$PROJ" diff --name-only HEAD 2>/dev/null
                git -C "$PROJ" ls-files --others --exclude-standard 2>/dev/null; } | sort -u | grep -c . )"
[ "$CLEAN_NOW" -eq 0 ]
check "G0 the fixture really is clean (the .gitignore covers the test's own state dirs)" "$(verdict $?)"
bash "$LOG" --tdd-complete --session "$SID_G1" >/dev/null 2>&1
[ $? -eq 0 ]
check "G1 a live clean-tree chain is not gated, even with an unusable plan staged" "$(verdict $?)"
printf 'v3\n' > "$PROJ/tracked.txt"
# The other half of the scope rule — no resolvable git HEAD — cannot be staged
# against a Session-Control-bound project from here, so it is pinned at its
# source: the same guard the receipt gate relies on.
# Scoped through the verb window: the same string also appears in the --chain-done
# gate, so a file-wide grep would stay green with this verb's guard deleted.
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF 'rev-parse --verify --quiet HEAD'
check "G2 the scope still requires a resolvable git HEAD" "$(verdict $?)"

echo "== Directory-level symlink guards and the unconditional stem bound =="
# The two DIRECTORY guards are what keep a plan anchored to the project; L13
# covers only the library's file-level refusal, so deleting either of these
# would leave every other check green.
SID_SP="rq-symlink-plans"
activate_session "$SID_SP"
stage "$SID_SP" "2026-01-01-1818_tdd-symlink-plans" "$BODIES/filled.md"
REALPLANS="$PROJ/.zensu/plans"
ALTPLANS="$PROJ/.zensu/plans-real"
mv "$REALPLANS" "$ALTPLANS" && ln -s "$ALTPLANS" "$REALPLANS" 2>/dev/null
if [ -L "$REALPLANS" ] && [ -n "$(readlink "$REALPLANS")" ]; then
  ERR_SP="$(bash "$LOG" --tdd-complete --session "$SID_SP" --plan "$REALPLANS/2026-01-01-1818_tdd-symlink-plans.md" 2>&1 >/dev/null)"
  [ $? -ne 0 ] && printf '%s' "$ERR_SP" | grep -qF 'is a symlink'
  check "SL1 a symlinked .zensu/plans is refused, not resolved through" "$(verdict $?)"
else
  check "SL1 SKIPPED — this filesystem produced no real symlink" PASS
fi
# The same fixture WITHOUT --plan: SL1's needle comes from the explicit guard, so
# only this run can observe the derived channel's own refusal.
if [ -L "$REALPLANS" ]; then
  ERR_SP2="$(bash "$LOG" --tdd-complete --session "$SID_SP" 2>&1 >/dev/null)"
  [ $? -eq 0 ] && printf '%s' "$ERR_SP2" | grep -qF 'no plan could be derived'
  check "SL1b the DERIVED channel also refuses a symlinked .zensu/plans" "$(verdict $?)"
else
  check "SL1b SKIPPED — this filesystem produced no real symlink" PASS
fi
rm -f "$REALPLANS" 2>/dev/null; mv "$ALTPLANS" "$REALPLANS" 2>/dev/null
# The logs-dir guard, with a target INSIDE the project: an outside target would
# be rejected by the containment check instead and prove nothing about the lstat.
SID_SLG="rq-symlink-logs"
activate_session "$SID_SLG"
stage "$SID_SLG" "2026-01-01-1919_tdd-symlink-logs" "$BODIES/none.md"
REALLOGS="$PROJ/.zensu/logs"
ALTLOGS="$PROJ/.zensu/logs-real"
mv "$REALLOGS" "$ALTLOGS" && ln -s "$ALTLOGS" "$REALLOGS" 2>/dev/null
if [ -L "$REALLOGS" ] && [ -n "$(readlink "$REALLOGS")" ]; then
  ERR_SLG="$(bash "$LOG" --tdd-complete --session "$SID_SLG" 2>&1 >/dev/null)"
  [ $? -eq 0 ] && printf '%s' "$ERR_SLG" | grep -qF 'no --plan was passed and no plan could be derived'
  check "SL2 a symlinked .zensu/logs derives nothing, even pointing inside the project" "$(verdict $?)"
else
  check "SL2 SKIPPED — this filesystem produced no real symlink" PASS
fi
rm -f "$REALLOGS" 2>/dev/null; mv "$ALTLOGS" "$REALLOGS" 2>/dev/null
# The unconditional stem bound: an explicit --plan with NO derivable stem is
# refused rather than accepted on the directory bound alone. Every other --plan
# case is staged with a receipt, so this branch is otherwise never entered.
SID_NS2="rq-no-stem"
activate_session "$SID_NS2"
bash "$LOG" --tdd-begin --session "$SID_NS2" >/dev/null 2>&1
mkdir -p "$PROJ/.zensu/plans"
cp "$BODIES/filled.md" "$PROJ/.zensu/plans/2020-02-02-0000_tdd-old-but-filled.md"
RP_NS2="$(receipt_for "$SID_NS2")"; mkdir -p "$(dirname "$RP_NS2")"
printf '{"schema":"edit-landing-v1","session":"%s","log":"/outside/.zensu/logs/x.log","clean":true}\n' "$SID_NS2" > "$RP_NS2"
ERR_NS2="$(bash "$LOG" --tdd-complete --session "$SID_NS2" --plan "$PROJ/.zensu/plans/2020-02-02-0000_tdd-old-but-filled.md" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_NS2" | grep -qF 'no run-log stem could be derived'
check "SB1 an explicit --plan with no derivable stem is REFUSED, not accepted on the directory bound" "$(verdict $?)"

echo "== The real receipt writer drives the real derivation =="
# D1/D2 read a receipt this suite hand-writes. Without this check a renamed `log`
# key, or a writer that stopped absolutizing it, would break the gate in
# production with every suite green.
SID_W="rq-writer-seam"
activate_session "$SID_W"
bash "$LOG" --tdd-begin --session "$SID_W" >/dev/null 2>&1
mkdir -p "$PROJ/.zensu/logs" "$PROJ/.zensu/plans"
W_STEM="2026-01-01-2020_tdd-writer-seam"
printf 'S1 IMPL completed — files: tracked.txt\n' > "$PROJ/.zensu/logs/${W_STEM}.log"
cp "$BODIES/none.md" "$PROJ/.zensu/plans/${W_STEM}.md"
bash "$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh" --log "$PROJ/.zensu/logs/${W_STEM}.log" \
  --project "$PROJ" --session "$SID_W" >/dev/null 2>&1
ERR_W="$(bash "$LOG" --tdd-complete --session "$SID_W" 2>&1 >/dev/null)"
[ $? -ne 0 ] && printf '%s' "$ERR_W" | grep -qF 'PLAN REQUIREMENTS MISSING'
check "WS1 a receipt written by the real library drives the derivation end to end" "$(verdict $?)"
# The persisted shape itself: absolute would work on POSIX and break on MSYS, so
# WS1 alone cannot see a revert. Assert the value is project-relative.
W_LOGVAL="$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.log||""))' "$(receipt_for "$SID_W")" 2>/dev/null)"
[ -n "$W_LOGVAL" ] && [ "${W_LOGVAL#/}" = "$W_LOGVAL" ] && [ "${W_LOGVAL#*:}" = "$W_LOGVAL" ]
check "WS1b the receipt persists its log PROJECT-RELATIVE, not absolute" "$(verdict $?)"

echo "== The library-missing branch is a RUNTIME fault, not a plan verdict =="
# NOT tested behaviorally, and the reason is structural rather than an omission:
# Session Control binds the executing plugin root by RUNTIME DIGEST, so removing
# or renaming the library inside the executing tree makes every stateful command
# refuse with "context runtime digest mismatch" BEFORE the verb runs, and running
# the verb against a copied plugin root is refused for the same reason. Measured,
# not assumed: both shapes were tried here and both failed on the binding. What
# remains checkable is that the branch exists, guards the load, and never claims
# a verdict about the table — `test-plan-payload-fallback.sh` F47/F47a covers the
# same class where the hook under test does no binding.
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF 'The plan was NOT judged'
check "LM1 the load-fault branch refuses with wording that denies a verdict" "$(verdict $?)"
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF '[ ! -f "$_rq_lib" ] || [ -L "$_rq_lib" ] || [ ! -r "$_rq_lib" ]'
check "LM2 the library path is guarded for absence, symlink and readability" "$(verdict $?)"
rm -rf "$BODIES"

echo "== The shell/node boundary is translated in both directions =="
# No POSIX host can observe this: the two namespaces coincide here. Pinned at
# source instead, because an untranslated crossing would refuse every
# skill-supplied --plan on MSYS while every check on this host stayed green.
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF '_tdd_native_path "$_tc_root"'
check "MB1 the root is translated into the native namespace before it crosses into node" "$(verdict $?)"
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF '_tdd_native_path "$_tc_receipt"'
check "MB2 the receipt path is translated too" "$(verdict $?)"
awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qF 'path.relative(root, resolved).split(path.sep).join("/")'
check "MB3 what comes back is project-relative, never a native absolute path" "$(verdict $?)"
# The only basename inside the derivation operates on `_rq_rel`, the
# project-relative suffix — never on a native path handed back from node.
[ "$(awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -c 'basename "\$_rq_rel"')" -eq 1 ] \
  && ! awk '/--tdd-complete\)/,/^        ;;/' "$LOG" | grep -qE 'basename "\$(_rq_native|_tc_receipt|_tc_root)'
check "MB4 no basename is applied to a native-namespace value" "$(verdict $?)"

echo "== AC-007 / source pins =="
# A bound chain cannot be staged from this suite (it needs a durable Autopilot
# run), so the property is pinned where it is decided: the gate sits ABOVE the
# standalone/bound split, so both paths pass through it. If the gate ever moves
# below that branch it silently stops covering bound chains.
# Anchored on the REFUSAL, not on the switch: the change-set computation the two
# gates share names ZENSU_REQUIREMENTS_GATE above the receipt refusal, so the
# switch is the wrong landmark for an ordering claim.
# Matched on a fragment with no escaped backticks: the refusal spells the section
# name as \`## Requirements\` inside a double-quoted echo, so the on-disk bytes
# carry backslashes the decoded message does not.
GATE_LINE="$(grep -nF 'would audit nothing and still close clean' "$LOG" | head -1 | cut -d: -f1)"
SPLIT_LINE="$(grep -n 'Autopilot binding was supplied for a standalone chain' "$LOG" | head -1 | cut -d: -f1)"
[ -n "$GATE_LINE" ] && [ -n "$SPLIT_LINE" ] && [ "$GATE_LINE" -lt "$SPLIT_LINE" ]
check "B1 the gate runs before the standalone/bound split, so bound chains are gated too" "$(verdict $?)"
# The receipt gate must still be reported FIRST: a session with neither artifact
# should hear about the audit it skipped, not about a plan it never reached.
RECEIPT_LINE="$(grep -n 'no edit-landing receipt' "$LOG" | head -1 | cut -d: -f1)"
[ -n "$RECEIPT_LINE" ] && [ "$RECEIPT_LINE" -lt "$GATE_LINE" ]
check "B2 the edit-landing refusal still precedes this gate" "$(verdict $?)"
[ -f "$REQ" ]
check "S1 the validation library ships with the plugin" "$(verdict $?)"
grep -qF 'zensu-plan-requirements.sh' "$LOG"
check "S2 the gate calls the library rather than re-implementing the rule" "$(verdict $?)"
grep -qF 'corrupt, inactive, or foreign session state' "$LOG"
check "S3 the pre-existing session-state refusal is intact" "$(verdict $?)"
grep -qF 'refusing the unqualified standalone terminus' "$LOG"
check "S4 the --chain-done dirty-tree refusal is intact" "$(verdict $?)"
grep -qF 'PLAN REQUIREMENTS MISSING' "$REQ"
check "S5 the library's own verdict vocabulary is intact" "$(verdict $?)"

echo "----"
echo "test-requirements-table-gate: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
