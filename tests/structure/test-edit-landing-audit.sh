#!/bin/bash
# Edit Landing Audit — the library, and the skill's reaction to it.
#
# A mechanical or bulk replacement (sed / perl -pi, a codemod script, an Edit
# with replace_all) that matches NOTHING produces no diff. The changed-file list
# the review chain consumes comes from git, so such a claim reaches no reviewer,
# and the suite stays green because it was green before the edit.
#
# The recipe used to live as prose in skills/tdd/SKILL.md, re-implemented from
# scratch on every run and testable only by grepping for its own wording. It now
# lives in hooks/lib/zensu-edit-landing.sh, so this suite DRIVES it against
# hermetic git fixtures. What remains pinned in the skill is only what a model
# must still decide: how to react to each verdict.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_TDD="$PLUGIN_DIR/skills/tdd/SKILL.md"
LIB="$PLUGIN_DIR/hooks/lib/zensu-edit-landing.sh"

T_PASS=0; T_FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; T_PASS=$((T_PASS+1));
  else echo "  FAIL  $label"; T_FAIL=$((T_FAIL+1)); fi
}
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo FAIL; fi; }

WORK=""
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM
WORK="$(mktemp -d)" || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1

audit_block() {
  awk '/^5b\. \*\*Edit Landing Audit\*\*/{inb=1; print; next}
       inb && /^[0-9]+[a-z]?\. \*\*/{exit}
       inb' "$SKILL_TDD"
}

# Build a fresh hermetic repo. Ambient git config must never decide the verdict.
new_repo() {
  local d="$1"
  mkdir -p "$d" || return 1
  git init -q --template= "$d" >/dev/null 2>&1
}
# Hermetic through real empty paths, not /dev/null. Git for Windows maps
# /dev/null to `nul` and then rejects it outright -- `fatal: cannot use nul as an
# exclude file` -- which failed the fixture on the scheduled Windows run. An empty
# file and an empty directory express "no global excludes" and "no hooks" on every
# platform.
ZENSU_GIT_NOWHERE_DIR="$WORK/git-nowhere"
ZENSU_GIT_NOWHERE_FILE="$WORK/git-nowhere/empty"
mkdir -p "$ZENSU_GIT_NOWHERE_DIR" && : > "$ZENSU_GIT_NOWHERE_FILE"
G() {
  local d="$1"; shift
  [ -n "$d" ] && [ -d "$d" ] || return 1
  git -C "$d" -c user.email=t@example.invalid -c user.name=zensu-test \
    -c commit.gpgsign=false -c "core.hooksPath=$ZENSU_GIT_NOWHERE_DIR" \
    -c "core.excludesFile=$ZENSU_GIT_NOWHERE_FILE" "$@"
}
run_audit() { bash "$LIB" "$@" 2>&1; }

echo "== Library exists and validates its input =="
[ -f "$LIB" ]
check "L1 hooks/lib/zensu-edit-landing.sh exists" "$(verdict $?)"
run_audit --log "$WORK/nope.log" >/dev/null 2>&1
[ $? -eq 2 ]
check "L2 a missing run log is a usage error (exit 2), not a silent pass" "$(verdict $?)"
run_audit --bogus >/dev/null 2>&1
[ $? -eq 2 ]
check "L3 an unknown argument is rejected" "$(verdict $?)"

echo "== Grading against a hermetic git fixture =="
R="$WORK/repo"
new_repo "$R"
mkdir -p "$R/src/nested"
printf 'v1\n' > "$R/src/nested/deep.txt"
printf 'v1\n' > "$R/untouched.txt"
printf 'v1\n' > "$R/tracked.txt"
printf 'ignored.txt\n' > "$R/.gitignore"
# Both git invocations are captured rather than discarded: this fixture failed on
# the scheduled Windows run and every word of the reason went to /dev/null, so the
# suite could report only that HEAD was absent.
F0_ADD="$(G "$R" add -A 2>&1)"; F0_ADD_RC=$?
F0_COMMIT="$(G "$R" commit -qm base 2>&1)"; F0_COMMIT_RC=$?
if ! G "$R" rev-parse HEAD >/dev/null 2>&1; then
  check "F0 hermetic git fixture committed a baseline" FAIL
  printf '        add rc=%s: %s\n' "$F0_ADD_RC" "$F0_ADD"
  printf '        commit rc=%s: %s\n' "$F0_COMMIT_RC" "$F0_COMMIT"
  printf '        git version: %s\n' "$(git --version 2>&1)"
  echo "----"; echo "test-edit-landing-audit: $T_PASS PASS / $T_FAIL FAIL"; exit 1
fi
check "F0 hermetic git fixture committed a baseline" PASS

printf 'v2\n' > "$R/tracked.txt"
printf 'v2\n' > "$R/src/nested/deep.txt"
printf 'new\n' > "$R/fresh.txt"
printf 'x\n'   > "$R/ignored.txt"
cat > "$R/run.log" <<'EOF'
[10:00:01] S1 IMPL completed — files: tracked.txt
[10:00:02] S2 IMPL completed — files: untouched.txt
[10:00:03] S3 IMPL completed — files: fresh.txt, src/nested/deep.txt
[10:00:04] S4 IMPL completed — files: ignored.txt
[10:00:05] S5 WIRED — files: tracked.txt | glob already covered it
[10:00:06] S6 WIRED — legacy entry naming no files
[10:00:07] S7 WIRED (verified, no change) — tests/run-all.sh: glob picks it up
EOF
OUT="$(run_audit --log "$R/run.log" --project "$R" --receipt "$R/receipt.json")"
RC=$?

[ "$RC" -ne 0 ]
check "F1 a run containing an unlanded claim exits non-zero" "$(verdict $?)"
printf '%s' "$OUT" | grep -qF 'EDIT NOT LANDED — S2: claimed untouched.txt, git shows no change'
check "F2 a claimed-but-unchanged file is reported with the exact marker and its step id" "$(verdict $?)"
printf '%s' "$OUT" | grep -qF 'EDIT LANDED — S1: tracked.txt'
check "F3 a real tracked change is reported as landed" "$(verdict $?)"
printf '%s' "$OUT" | grep -qF 'EDIT LANDED — S3: fresh.txt'
check "F4 a new untracked file counts as landed" "$(verdict $?)"
printf '%s' "$OUT" | grep -qF 'EDIT LANDED — S3: src/nested/deep.txt'
check "F5 a subdirectory path is graded repo-root-relative" "$(verdict $?)"
printf '%s' "$OUT" | grep -qF 'EDIT LANDED (untracked-by-design) — ignored.txt'
check "F6 a gitignored claim is exempt only via the check-ignore proof" "$(verdict $?)"
printf '%s' "$OUT" | grep -q 'UNVERIFIED.*S6 WIRED'
check "F7 a legacy WIRED entry with no files list is UNVERIFIED, never passing" "$(verdict $?)"
printf '%s' "$OUT" | grep -qF 'exempt_verified=1'
check "F8 a WIRED (verified, no change) step is counted as an exemption, not a claim" "$(verdict $?)"
printf '%s' "$OUT" | grep -qE 'EDIT LANDING AUDIT — claims=[0-9]+ landed=[0-9]+ not_landed=1'
check "F9 the close marker carries the tallies" "$(verdict $?)"
[ -f "$R/receipt.json" ] && grep -qF '"clean":false' "$R/receipt.json"
check "F10 the receipt records a non-clean audit" "$(verdict $?)"

echo "== Claim scoping: membership is not evidence for an already-dirty file =="
printf 'tracked.txt\n' > "$R/dirty-before.txt"
OUT2="$(run_audit --log "$R/run.log" --project "$R" --dirty-before "$R/dirty-before.txt" --receipt -)"
printf '%s' "$OUT2" | grep -qF 'PENDING PREDICATE — S1: tracked.txt'
check "C1 a file already dirty before the round is PENDING, not landed" "$(verdict $?)"
printf '%s' "$OUT2" | grep -qF 'EDIT LANDED — S3: fresh.txt'
check "C2 a file that was NOT dirty before is still graded normally" "$(verdict $?)"

echo "== Clean run =="
CR="$WORK/clean"
new_repo "$CR"
printf 'v1\n' > "$CR/a.txt"
G "$CR" add -A >/dev/null 2>&1; G "$CR" commit -qm base >/dev/null 2>&1
printf 'v2\n' > "$CR/a.txt"
printf 'S1 IMPL completed — files: a.txt\n' > "$CR/run.log"
OUT3="$(run_audit --log "$CR/run.log" --project "$CR" --receipt "$CR/receipt.json")"
RC3=$?
{ [ "$RC3" -eq 0 ] && printf '%s' "$OUT3" | grep -qF 'not_landed=0'; }
check "K1 a run where every claim landed exits 0" "$(verdict $?)"
grep -qF '"clean":true' "$CR/receipt.json"
check "K2 the receipt records a clean audit" "$(verdict $?)"

echo "== No claims at all is not a pass =="
NC="$WORK/noclaims"
new_repo "$NC"
printf 'nothing to see\n' > "$NC/run.log"
OUT4="$(run_audit --log "$NC/run.log" --project "$NC" --receipt -)"
RC4=$?
{ [ "$RC4" -ne 0 ] && printf '%s' "$OUT4" | grep -qF 'UNVERIFIED (no claims logged)'; }
check "N1 an empty claim set is UNVERIFIED, never a silent green" "$(verdict $?)"

echo "== Unborn HEAD =="
UB="$WORK/unborn"
new_repo "$UB"
printf 'x\n' > "$UB/first.txt"
printf 'S1 IMPL completed — files: first.txt\n' > "$UB/run.log"
OUT5="$(run_audit --log "$UB/run.log" --project "$UB" --receipt -)"
RC5=$?
{ [ "$RC5" -eq 0 ] && printf '%s' "$OUT5" | grep -qF 'EDIT LANDED — S1: first.txt'; }
check "U1 on an unborn HEAD the audit still grades (diff HEAD would be fatal)" "$(verdict $?)"

echo "== Mid-run commit: the baseline range keeps claims verifiable =="
MC="$WORK/midrun"
new_repo "$MC"
printf 'v1\n' > "$MC/b.txt"
G "$MC" add -A >/dev/null 2>&1; G "$MC" commit -qm base >/dev/null 2>&1
BASE="$(G "$MC" rev-parse HEAD)"
printf 'v2\n' > "$MC/b.txt"
G "$MC" add -A >/dev/null 2>&1; G "$MC" commit -qm session >/dev/null 2>&1
printf 'S1 IMPL completed — files: b.txt\n' > "$MC/run.log"
OUT6="$(run_audit --log "$MC/run.log" --project "$MC" --receipt -)"
printf '%s' "$OUT6" | grep -qF 'EDIT NOT LANDED'
check "M1 without the baseline a committed change reads as NOT LANDED (why --baseline exists)" "$(verdict $?)"
OUT7="$(run_audit --log "$MC/run.log" --project "$MC" --baseline "$BASE" --receipt -)"
RC7=$?
{ [ "$RC7" -eq 0 ] && printf '%s' "$OUT7" | grep -qF 'EDIT LANDED — S1: b.txt'; }
check "M2 with --baseline the committed change is correctly landed" "$(verdict $?)"

echo "== Outside a git work tree =="
NG="$WORK/nogit"
mkdir -p "$NG"
printf 'x\n' > "$NG/c.txt"
printf 'S1 IMPL completed — files: c.txt\n' > "$NG/run.log"
OUT8="$(run_audit --log "$NG/run.log" --project "$NG" --session-epoch 1 --receipt -)"
RC8=$?
{ [ "$RC8" -ne 0 ] && printf '%s' "$OUT8" | grep -qE 'PENDING PREDICATE|UNVERIFIED'; }
check "G1 outside git the verdict stays pending/unverified — never a silent landed" "$(verdict $?)"

echo "== Multi-root: a claim outside the audited root is named, never silently graded =="
# Stage 1 of docs/multi-repo-chains-spec.md: one audit run grades ONE root. A claim
# that resolves into a sibling repository used to read as "could not be resolved",
# which names neither the topology nor the repository the work actually landed in.
MR="$WORK/multiroot"
mkdir -p "$MR"
new_repo "$MR/anchor"
printf 'v1\n' > "$MR/anchor/src.txt"
G "$MR/anchor" add -A >/dev/null 2>&1; G "$MR/anchor" commit -qm base >/dev/null 2>&1
printf 'v2\n' > "$MR/anchor/src.txt"
new_repo "$MR/sibling"
mkdir -p "$MR/sibling/src"
printf 'v1\n' > "$MR/sibling/src/app.ts"
MR_ANCHOR_ABS="$(cd "$MR/anchor" && pwd -P)"
MR_SIB_ABS="$(cd "$MR/sibling" && pwd -P)"
ln -s "$MR_ANCHOR_ABS" "$MR/anchor-link" 2>/dev/null || true
cat > "$MR/run.log" <<EOF
[10:00:01] S1 IMPL completed — files: ${MR_SIB_ABS}/src/app.ts
[10:00:02] S2 IMPL completed — files: ${MR_ANCHOR_ABS}/src.txt
[10:00:03] S3 IMPL completed — files: ${MR}/anchor-link/src.txt
EOF
OUT9="$(run_audit --log "$MR/run.log" --project "$MR/anchor" --receipt -)"
RC9=$?
[ "$RC9" -ne 0 ]
check "X1 a claim resolving outside the audited root fails the audit" "$(verdict $?)"
printf '%s' "$OUT9" | grep -qF 'UNVERIFIED (foreign root) — S1:'
check "X2 the foreign claim carries its own verdict, not the generic unresolvable one" "$(verdict $?)"
printf '%s' "$OUT9" | grep -qF "it belongs to ${MR_SIB_ABS}"
check "X3 the failure NAMES the foreign root" "$(verdict $?)"
printf '%s' "$OUT9" | grep -qF 'EDIT LANDED — S2: src.txt'
check "X4 an absolute claim inside the audited root still grades normally" "$(verdict $?)"
# The claim is spelled through a SYMLINK to the anchor, so the raw `$REPO_ROOT/*`
# prefix cannot match on any host and only the canonicalizing arm can resolve it.
# Spelling it `${MR}/anchor/...` instead left the check byte-identical to X4
# wherever `mktemp -d` already returns a canonical path.
if [ -L "$MR/anchor-link" ]; then
  printf '%s' "$OUT9" | grep -qF 'EDIT LANDED — S3: src.txt'
  check "X5 a non-canonical absolute spelling of the anchor is judged by where it RESOLVES" "$(verdict $?)"
else
  check "X5 a non-canonical absolute spelling of the anchor is judged by where it RESOLVES" SKIP
fi

echo "== Aliasing: a relative foreign claim is ungradeable before the Stage 2 label =="
# The documented Stage 1 gap (spec §5). `src.txt` from a sibling repository is
# textually identical to an anchor claim, and the anchor holds a dirty file of that
# name, so it grades as LANDED. Pinned as CURRENT behaviour so the gap cannot be
# mistaken for detection — only the §6.1 root label closes it.
printf '%s\n' "[10:00:04] S4 IMPL completed — files: src.txt" > "$MR/alias.log"
OUT10="$(run_audit --log "$MR/alias.log" --project "$MR/anchor" --receipt -)"
RC10=$?
{ [ "$RC10" -eq 0 ] && printf '%s' "$OUT10" | grep -qF 'EDIT LANDED — S4: src.txt'; }
check "X6 a RELATIVE claim colliding with a dirty anchor file still grades as landed (Stage 1 gap, named not fixed)" "$(verdict $?)"

echo "== Read-only inventory =="
cat > "$MR/inv.log" <<EOF
[10:00:01] S1 IMPL completed — files: ${MR_SIB_ABS}/src/app.ts
[10:00:02] S2 IMPL completed — files: src.txt, other.txt
[10:00:03] S3 IMPL completed — files:
[10:00:04] S4 WIRED (verified, no change) — docs/x.md: nothing to change
[10:00:05] S5 WIRED — legacy entry naming no files
EOF
INV="$(run_audit --inventory --log "$MR/inv.log" --project "$MR/anchor")"
RCI=$?
[ "$RCI" -eq 0 ]
check "V1 the inventory mode exits 0 — it reports, it never grades" "$(verdict $?)"
printf '%s' "$INV" | grep -qxF 'claimed-files=3'
check "V2 one claim per NAMED file: an empty list, a verified-no-change line and a bare WIRED entry count none" "$(verdict $?)"
printf '%s' "$INV" | grep -qF "foreign-root$(printf '\t')${MR_SIB_ABS}"
check "V3 the inventory names the distinct foreign roots" "$(verdict $?)"
! printf '%s' "$INV" | grep -qE 'EDIT LANDED|EDIT NOT LANDED|EDIT LANDING AUDIT'
check "V4 the inventory emits no grading verdict" "$(verdict $?)"
INV_SESSION="scv1_$(printf '0%.0s' $(seq 1 64))"
INV_REFUSE="$(run_audit --inventory --log "$MR/inv.log" --project "$MR/anchor" --session "$INV_SESSION")"
RCIR=$?
{ [ "$RCIR" -eq 2 ] && printf '%s' "$INV_REFUSE" | grep -qF 'read-only and does not accept --session'; }
check "V6 --inventory REFUSES a write-mode operand rather than parsing and ignoring it" "$(verdict $?)"
[ ! -e "$MR/anchor/.zensu/state" ]
check "V6a the refused inventory run wrote nothing" "$(verdict $?)"
# The positive control: the SAME operand without --inventory really does derive a
# receipt path, so V5/V6 are not passing because --session is inert.
run_audit --log "$MR/inv.log" --project "$MR/anchor" --session "$INV_SESSION" >/dev/null 2>&1
[ -f "$MR/anchor/.zensu/state/edit-landing-${INV_SESSION}.json" ]
check "V6b the same --session WITHOUT --inventory does write a receipt" "$(verdict $?)"
rm -rf "$MR/anchor/.zensu/state"
for _empty_flag in --baseline --session-epoch --dirty-before; do
  EMPTY_OUT="$(run_audit --inventory --log "$MR/inv.log" --project "$MR/anchor" "$_empty_flag" "")"
  EMPTY_RC=$?
  { [ "$EMPTY_RC" -eq 2 ] && printf '%s' "$EMPTY_OUT" | grep -qF "does not accept ${_empty_flag}"; }
  check "V5b --inventory refuses an EMPTY ${_empty_flag} — presence, never emptiness" "$(verdict $?)"
done
EMPTY_OK="$(run_audit --inventory --log "$MR/inv.log" --project "$MR/anchor")"
EMPTY_OK_RC=$?
{ [ "$EMPTY_OK_RC" -eq 0 ] && printf '%s' "$EMPTY_OK" | grep -qxF 'claimed-files=3'; }
check "V5b-control the same invocation without those operands still reports" "$(verdict $?)"

echo "== A claim that resolves nowhere names no repository =="
# The failure text of `claim_root_of` used to be captured in a command
# substitution whose status was discarded, so the prose travelled into the
# `foreign-root<TAB><root>` wire format as a VALUE and /zensu:doctor rendered it
# in backticks as a repository to run the chain in.
NR="$WORK/norepo"
mkdir -p "$NR/scratch"
printf 'v1\n' > "$NR/scratch/loose.txt"
printf '%s\n' "[10:00:01] S1 IMPL completed — files: ${NR}/scratch/loose.txt" > "$MR/norepo.log"
OUT_NR="$(run_audit --log "$MR/norepo.log" --project "$MR/anchor" --receipt -)"
RC_NR=$?
{ [ "$RC_NR" -ne 0 ] && printf '%s' "$OUT_NR" | grep -qF 'UNVERIFIED (no work tree) — S1:'; }
check "X7 a claim with no work tree above it gets its own verdict, not a foreign-root one" "$(verdict $?)"
ROOT_SHAPE_OK=1
while IFS= read -r _fr_line; do
  case "${_fr_line#foreign-root$(printf '\t')}" in
    (/*) ;;
    (*) ROOT_SHAPE_OK=0 ;;
  esac
done <<EOF
$(printf '%s\n' "$INV" | grep '^foreign-root' || true)
EOF
[ "$ROOT_SHAPE_OK" -eq 1 ]
check "X7a every foreign-root VALUE is an absolute path, never a diagnostic sentence" "$(verdict $?)"
INV_NR="$(run_audit --inventory --log "$MR/norepo.log" --project "$MR/anchor")"
RC_INR=$?
{ [ "$RC_INR" -eq 0 ] && printf '%s' "$INV_NR" | grep -qxF 'claimed-files=1'; }
check "X7b-pre the inventory over that log ran and reported" "$(verdict $?)"
! printf '%s' "$INV_NR" | grep -q '^foreign-root'
check "X7b the inventory emits no foreign-root line for a claim that names no repository" "$(verdict $?)"

echo "== A work tree NESTED under the anchor is foreign =="
# The lexical `$REPO_ROOT/*` prefix answered before the work tree was consulted,
# so a nested worktree — this repository's own mandated session layout, under an
# ignored directory — graded as landed while the anchor's git could not see it.
NEST_OK=0
if git -C "$MR/anchor" worktree add -q -b nested-probe "$MR/anchor/nested" >/dev/null 2>&1; then NEST_OK=1; fi
if [ "$NEST_OK" -eq 1 ]; then
  printf 'v1\n' > "$MR/anchor/nested/app.ts"
  NEST_ABS="$(cd "$MR/anchor/nested" && pwd -P)"
  printf '%s\n' "[10:00:01] S1 IMPL completed — files: ${NEST_ABS}/app.ts" > "$MR/nested.log"
  OUT_NEST="$(run_audit --log "$MR/nested.log" --project "$MR/anchor" --receipt -)"
  RC_NEST=$?
  { [ "$RC_NEST" -ne 0 ] && printf '%s' "$OUT_NEST" | grep -qF 'UNVERIFIED (foreign root) — S1:'; }
  check "X8 a claim into a work tree NESTED under the anchor is named foreign, not landed" "$(verdict $?)"
  printf '%s' "$OUT_NEST" | grep -qF "it belongs to ${NEST_ABS}"
  check "X8a the nested work tree is named as the root" "$(verdict $?)"
  INV_NEST="$(run_audit --inventory --log "$MR/nested.log" --project "$MR/anchor")"
  printf '%s' "$INV_NEST" | grep -qF "foreign-root$(printf '\t')${NEST_ABS}"
  check "X8b the inventory reports the nested work tree so the doctor row can fire" "$(verdict $?)"
else
  check "X8 a claim into a work tree NESTED under the anchor is named foreign, not landed" SKIP
  check "X8a the nested work tree is named as the root" SKIP
  check "X8b the inventory reports the nested work tree so the doctor row can fire" SKIP
fi

echo "== The strict-mode step 8 summary line is not a claim =="
# `*"WIRED"*` also matched `TDD COMPLETE — … | Integration: 1 WIRED | …`, which
# skills/tdd/SKILL.md step 8 logs BEFORE --tdd-complete runs. That counted the
# summary as an ungradeable claim, so every audit re-run after step 8 wrote
# `clean: false` — and once the terminus read the VERDICT, the refusal's own
# remedy could never clear it. A bare claim is `<step> WIRED …` and nothing else.
cat > "$MR/strict.log" <<EOF
[10:00:01] S1 IMPL completed — files: src.txt
[10:00:02] TDD COMPLETE — 5/5 GREEN | Integration: 1 WIRED | Build: – n/a
EOF
OUT_ST="$(run_audit --log "$MR/strict.log" --project "$MR/anchor" --receipt -)"
RC_ST=$?
{ [ "$RC_ST" -eq 0 ] && printf '%s' "$OUT_ST" | grep -qF 'EDIT LANDED — S1: src.txt'; }
check "X9 a run log carrying the step 8 summary line still audits CLEAN" "$(verdict $?)"
! printf '%s' "$OUT_ST" | grep -qF 'a WIRED entry names no files'
check "X9a the summary line is not reported as an ungradeable claim" "$(verdict $?)"
printf '%s' "$OUT_ST" | grep -qF 'claims=1 landed=1'
check "X9b the summary line is not counted as a claim" "$(verdict $?)"
# The discriminator: a REAL bare WIRED entry is still ungradeable.
printf '%s\n' "[10:00:03] S9 WIRED — legacy entry naming no files" >> "$MR/strict.log"
OUT_ST2="$(run_audit --log "$MR/strict.log" --project "$MR/anchor" --receipt -)"
RC_ST2=$?
{ [ "$RC_ST2" -ne 0 ] && printf '%s' "$OUT_ST2" | grep -qF 'a WIRED entry names no files'; }
check "X9c a genuine bare WIRED entry is still UNVERIFIED (the arm is narrowed, not deleted)" "$(verdict $?)"

echo "== Skill: reacts to the library, does not re-implement it =="
BLOCK="$(audit_block)"
[ -n "$BLOCK" ]
check "S1 SKILL.md still carries a named 5b step" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'hooks/lib/zensu-edit-landing.sh'
check "S2 step 5b invokes the library rather than restating the recipe" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'runs in BOTH strict and vanilla mode'
check "S3 the audit declares it runs in both modes" "$(verdict $?)"
for marker in 'EDIT NOT LANDED' 'PENDING PREDICATE' 'UNVERIFIED'; do
  printf '%s' "$BLOCK" | grep -qF "$marker"
  check "S4 the skill tells the model how to react to $marker" "$(verdict $?)"
done
printf '%s' "$BLOCK" | grep -qF 'CHAIN-END SUMMARY'
check "S5 a non-clean verdict is carried into the CHAIN-END SUMMARY" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'Do NOT auto-fix'
check "S6 the audit forbids auto-fixing its own findings" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'CLAIM WITHDRAWN — {step_id}: {file}'
check "S7 withdrawing a claim is a recorded state change" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'A green test run is never the evidence'
check "S8 a green run is explicitly not the evidence" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF 'must already hold when the audit runs'
check "S9 neither exemption may be granted after the audit found the miss" "$(verdict $?)"
printf '%s' "$BLOCK" | grep -qF -- '--dirty-before'
check "S10 a review-fix round passes the round's pre-existing dirty set" "$(verdict $?)"
# The recipe must NOT creep back into the prose.
printf '%s' "$BLOCK" | grep -qF 'ls-files --others --exclude-standard'
[ $? -ne 0 ]
check "S11 the enumeration recipe is gone from the prose (the library owns it)" "$(verdict $?)"

echo "== Skill: surrounding contract intact =="
grep -qF 'BASELINE_SHA=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --verify --quiet HEAD)' "$SKILL_TDD"
check "P1 Phase 0 still captures the baseline SHA the library consumes" "$(verdict $?)"
grep -F 'On Critical/Important findings' "$SKILL_TDD" | grep -qF 'Edit Landing Audit'
check "P2 every review-fix round re-runs the audit over that round's claims" "$(verdict $?)"
grep -qF 'Mechanical or bulk replacement — confirm by RE-READING the result, never by the test run.' "$SKILL_TDD"
check "P3 Phase 4 keeps the mechanical-replacement re-read rule" "$(verdict $?)"
grep -qF '{step_id} WIRED — files: {list} | {description}' "$SKILL_TDD"
check "P4 the logging contract still types the WIRED file list" "$(verdict $?)"
V_SKIP="$(grep -F -- '- Phase 6: only the' "$SKILL_TDD" | head -n1)"
printf '%s' "$V_SKIP" | grep -qF 'the Precondition Drift Audit and the Edit Landing Audit still run'
check "P5 vanilla mode keeps the audit" "$(verdict $?)"
V_SKIPPED_ONLY="$(printf '%s' "$V_SKIP" | sed -n 's/.*only the \(.*\) are skipped.*/\1/p')"
{ [ -n "$V_SKIPPED_ONLY" ] && ! printf '%s' "$V_SKIPPED_ONLY" | grep -qF 'Edit Landing'; }
check "P6 the audit has not leaked into the vanilla skip list" "$(verdict $?)"


echo "== Receipt never escapes the project state dir =="
ESC="$WORK/escape"; mkdir -p "$ESC"
printf 'S1 IMPL completed — files: a.txt\n' > "$ESC/run.log"
: > "$ESC/a.txt"
( cd "$ESC" && run_audit --log "$ESC/run.log" --project "$ESC" --receipt "edit-landing-.json" >/dev/null 2>&1 )
[ ! -e "$ESC/edit-landing-.json" ]
check "L90 an empty-key receipt name is refused, not written" "$(verdict $?)"
( cd "$ESC" && run_audit --log "$ESC/run.log" --project "$ESC" --receipt "relative-receipt.json" >/dev/null 2>&1 )
[ ! -e "$ESC/relative-receipt.json" ]
check "L91 a relative receipt path is refused, not written" "$(verdict $?)"
STRAY="$(find "$PLUGIN_DIR" -maxdepth 1 -name 'edit-landing-*.json' 2>/dev/null | head -1)"
[ -z "$STRAY" ]
check "L92 the suite leaves no edit-landing receipt in the repo root" "$(verdict $?)"

echo "----"
echo "test-edit-landing-audit: $T_PASS PASS / $T_FAIL FAIL"
[ "$T_FAIL" -eq 0 ]
