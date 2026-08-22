#!/bin/bash
# Structure regression for the Finding Verification Gate — the step that grades a
# fan-out's merged findings against the real source before anything routes to a
# fix, a published forge review, or a GO/NO-GO verdict. Pins the model-free
# grader's behavior end to end, that the gate sits AFTER the judge (a JUDGE-*
# delta is agent output too), that its neutralization is annotate-and-downgrade
# rather than delete, that every fix-routing consumer honors the annotation, and
# that all three fan-outs plus the config surface carry it.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/finding-verify-v1.js"
UNIT="$ROOT/tests/structure/finding-verify-v1.test.js"
# Shared, locale-independent `node --test` summary parse (see the file header for
# why the count matters and why it is not hand-copied here).
. "$(dirname "$0")/lib-unit-summary.sh"

TDD_MD="$ROOT/skills/tdd/SKILL.md"
PR_MD="$ROOT/skills/pr-team-review/SKILL.md"
PR_RULES="$ROOT/skills/pr-team-review/rules/workflow.md"
PLAN_MD="$ROOT/skills/plan-review/SKILL.md"
DELEGATE="$ROOT/hooks/post-review-tdd-delegate.sh"
ENFORCER="$ROOT/hooks/stop-chain-enforcer.sh"
REVIEWER="$ROOT/agents/code-reviewer.md"
CONFIG_EX="$ROOT/config.example.json"
CONFIG_DOC="$ROOT/docs/configuration.md"
WORKFLOW_DOC="$ROOT/docs/tdd-manager-workflow.md"
INVENTORY="$ROOT/tests/profiles/promptfoo-local-only.v1.json"
MARKER='[Unverified — do not fix]'
PASS=0; FAIL=0
check() {
  local label="$1" result="$2"
  if [ "$result" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$LIB" "$UNIT" "$TDD_MD" "$PR_MD" "$PR_RULES" "$PLAN_MD" "$DELEGATE" \
         "$ENFORCER" "$REVIEWER" "$CONFIG_EX" "$CONFIG_DOC" "$WORKFLOW_DOC" "$INVENTORY"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-finding-verification: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM HUP

# ── P1 the model-free grader ─────────────────────────────────────────
if node --test "$UNIT" >"$WORK/unit.out" 2>&1 \
  && unit_cases_meet_floor "$WORK/unit.out" 28; then
  check "P1 the grader unit suite passes ($(unit_cases_report "$WORK/unit.out"))" PASS
else
  check "P1 the grader unit suite passes ($(unit_cases_report "$WORK/unit.out"), want >= 28 registered; $(grep -c '^not ok' "$WORK/unit.out" 2>/dev/null) failing)" FAIL
  grep -B2 -A 20 '^not ok' "$WORK/unit.out" | sed 's/^/        /'
fi

mkdir -p "$WORK/repo/src"
printf 'one\ntwo\nthree\n' > "$WORK/repo/src/a.js"
printf 'only\n' > "$WORK/repo/src/b.js"
OUT="$(node "$LIB" --root "$WORK/repo" <<'ZENSU_VERIFY' 2>"$WORK/err.out"
CHANGED-FILES
src/a.js
FINDINGS
- [CRITICAL] src/a.js:2 — real anchor.
- [IMPORTANT] src/nope.js:1 — invented path.
- [IMPORTANT] src/a.js:99 — past EOF.
- [CRITICAL] ../../etc/passwd:1 — traversal.
- [SUGGESTION] Panel-FP: meta verdict, no anchor.
- [SUGGESTION] src/b.js:1 — real but unchanged.
ZENSU_VERIFY
)"
RC=$?
if [ "$RC" -eq 0 ]; then
  check "P1a the CLI exits 0 — a verdict is data, not a gate" PASS
else
  check "P1a the CLI exits 0 (got $RC)" FAIL
fi
EXPECTED='1 anchor-ok src/a.js:2
2 phantom-path src/nope.js:1
3 line-out-of-range src/a.js:99 lines=3
4 out-of-root ../../etc/passwd:1
5 no-anchor -
6 off-changeset src/b.js:1
summary ok=1 off-changeset=1 out-of-range=1 phantom=1 out-of-root=1 no-anchor=1 total=6'
if [ "$OUT" = "$EXPECTED" ]; then
  check "P1b every verdict of the lattice is reachable in one invocation" PASS
else
  check "P1b every verdict of the lattice is reachable in one invocation" FAIL
  printf '%s\n' "$OUT" | sed 's/^/        got: /'
fi

# A phantom verdict must never depend on reading anything outside the root.
#
# `ln -s` exiting 0 is not evidence of a symlink: Git Bash satisfies it with a copy
# unless MSYS is set to winsymlinks:nativestrict. link.txt would then be an ordinary
# in-root file, the grader would rightly call it off-changeset, and this check would
# fail on a correct implementation. Create the link through Node and confirm it.
IS_WINDOWS="$(node -p 'process.platform === "win32" ? "true" : "false"')"
make_file_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}
printf 'secret\n' > "$WORK/outside.txt"
if make_file_symlink "$WORK/outside.txt" "$WORK/repo/link.txt"; then
  OUT="$(node "$LIB" --root "$WORK/repo" <<'ZENSU_VERIFY'
FINDINGS
- link.txt:1 — symlink escaping the root.
ZENSU_VERIFY
)"
  case "$OUT" in
    '1 out-of-root link.txt:1'*) check "P1c a symlink escaping the root is rejected, never read" PASS ;;
    *) check "P1c a symlink escaping the root is rejected (got: $OUT)" FAIL ;;
  esac
elif [ "$IS_WINDOWS" = true ]; then
  check "P1c escaping-symlink rejection (native file symlinks unavailable)" PASS
else
  check "P1c symlink fixture creation failed" FAIL
fi

OUT="$(node "$LIB" --root "$WORK/repo" </dev/null)"
case "$OUT" in
  'summary ok=0 off-changeset=0 out-of-range=0 phantom=0 out-of-root=0 no-anchor=0 total=0')
    check "P1d unusable input degrades to a total=0 summary, never a silent pass" PASS ;;
  *) check "P1d unusable input degrades to a total=0 summary (got: $OUT)" FAIL ;;
esac

# ── P2 /zensu:tdd step 4c ────────────────────────────────────────────
if grep -qF '4c. **Finding Verification Gate' "$TDD_MD"; then
  check "P2a /zensu:tdd carries step 4c" PASS
else
  check "P2a /zensu:tdd carries step 4c" FAIL
fi
JUDGE_LINE="$(grep -n '4b\. \*\*Judge second pass' "$TDD_MD" | head -1 | cut -d: -f1)"
VERIFY_LINE="$(grep -n '4c\. \*\*Finding Verification Gate' "$TDD_MD" | head -1 | cut -d: -f1)"
SPAWN_LINE="$(grep -n '5\. \*\*Thin consume-mode spawn' "$TDD_MD" | head -1 | cut -d: -f1)"
if [ -n "$JUDGE_LINE" ] && [ -n "$VERIFY_LINE" ] && [ -n "$SPAWN_LINE" ] \
   && [ "$JUDGE_LINE" -lt "$VERIFY_LINE" ] && [ "$VERIFY_LINE" -lt "$SPAWN_LINE" ]; then
  check "P2b the gate sits AFTER the judge and BEFORE the consume reviewer" PASS
else
  check "P2b the gate sits AFTER the judge and BEFORE the consume reviewer (4b=$JUDGE_LINE 4c=$VERIFY_LINE 5=$SPAWN_LINE)" FAIL
fi
if grep -qF 'zensu_hook_enabled findingVerification' "$TDD_MD"; then
  check "P2c the gate resolves hooks.findingVerification with the real merge semantics" PASS
else
  check "P2c the gate resolves hooks.findingVerification with the real merge semantics" FAIL
fi
if grep -qF 'hooks/lib/finding-verify-v1.js' "$TDD_MD"; then
  check "P2d step 4c invokes the model-free grader" PASS
else
  check "P2d step 4c invokes the model-free grader" FAIL
fi
if grep -qF 'JUDGE-*` deltas, because a judge delta is agent output too' "$TDD_MD"; then
  check "P2e the gate grades the judge's own deltas, not just the panel's" PASS
else
  check "P2e the gate grades the judge's own deltas, not just the panel's" FAIL
fi
if grep -qF "$MARKER" "$TDD_MD" && grep -qF 'Neutralize, never delete' "$TDD_MD"; then
  check "P2f a failed finding is annotated + downgraded, never deleted" PASS
else
  check "P2f a failed finding is annotated + downgraded, never deleted" FAIL
fi
if grep -qF 'FINDING VERIFICATION DEGRADED' "$TDD_MD" && grep -qF 'Never fail the gate closed' "$TDD_MD"; then
  check "P2g the gate is fail-soft and says so" PASS
else
  check "P2g the gate is fail-soft and says so" FAIL
fi
if grep -qF 'FINDING VERIFICATION — {n} verified' "$TDD_MD"; then
  check "P2h the verdict is logged and carried into the CHAIN-END SUMMARY" PASS
else
  check "P2h the verdict is logged and carried into the CHAIN-END SUMMARY" FAIL
fi
if grep -qF 're-run the step-4c Finding Verification Gate over THAT round' "$TDD_MD" \
   && grep -qF 'or verification verdicts forward' "$TDD_MD"; then
  check "P2i every fix round re-runs the gate and carries no prior verdict forward" PASS
else
  check "P2i every fix round re-runs the gate and carries no prior verdict forward" FAIL
fi
if grep -qF 'judge second pass → Finding Verification Gate → consume-mode reviewer' "$TDD_MD" \
   && grep -qF 'step-4c Finding Verification Gate + consume-mode reviewer per round' "$TDD_MD"; then
  check "P2j vanilla mode keeps the gate" PASS
else
  check "P2j vanilla mode keeps the gate" FAIL
fi

# ── P3 fix-routing consumers ─────────────────────────────────────────
if grep -qF "items annotated '$MARKER' failed the Finding Verification Gate" "$DELEGATE"; then
  check "P3a the include-suggestions route exempts an unverified finding from fixing" PASS
else
  check "P3a the include-suggestions route exempts an unverified finding from fixing" FAIL
fi
if [ "$(grep -c 'step 4c Finding Verification Gate' "$DELEGATE")" -eq 2 ]; then
  check "P3b BOTH post-review directives re-run the gate before re-verifying" PASS
else
  check "P3b BOTH post-review directives re-run the gate before re-verifying (got $(grep -c 'step 4c Finding Verification Gate' "$DELEGATE"))" FAIL
fi
if grep -qF 'step 4c Finding Verification Gate' "$ENFORCER" && grep -qF "$MARKER" "$ENFORCER"; then
  check "P3c the Stop-hook resume directive names the gate and its marker" PASS
else
  check "P3c the Stop-hook resume directive names the gate and its marker" FAIL
fi
if grep -qF "$MARKER" "$REVIEWER" && grep -qF 'never restore a neutralized or unverified finding to fix routing' "$REVIEWER"; then
  check "P3d consume mode keeps the annotation visible and out of fix routing" PASS
else
  check "P3d consume mode keeps the annotation visible and out of fix routing" FAIL
fi
for f in "$DELEGATE" "$ENFORCER"; do
  if bash -n "$f" 2>/dev/null; then
    check "P3e $(basename "$f") still parses" PASS
  else
    check "P3e $(basename "$f") still parses" FAIL
  fi
done

# ── P4 the other two fan-outs ────────────────────────────────────────
if grep -qF '4b. **Finding Verification Gate (lead-run, config-gated).**' "$PR_MD"; then
  check "P4a /zensu:pr-team-review carries the Phase C gate" PASS
else
  check "P4a /zensu:pr-team-review carries the Phase C gate" FAIL
fi
CHALLENGE_LINE="$(grep -n '4\. \*\*Challenge Round' "$PR_MD" | head -1 | cut -d: -f1)"
PRVERIFY_LINE="$(grep -n '4b\. \*\*Finding Verification Gate' "$PR_MD" | head -1 | cut -d: -f1)"
DEBATE_LINE="$(grep -n '5\. Write `\$WORKDIR/_debate.json`' "$PR_MD" | head -1 | cut -d: -f1)"
if [ -n "$CHALLENGE_LINE" ] && [ -n "$PRVERIFY_LINE" ] && [ -n "$DEBATE_LINE" ] \
   && [ "$CHALLENGE_LINE" -lt "$PRVERIFY_LINE" ] && [ "$PRVERIFY_LINE" -lt "$DEBATE_LINE" ]; then
  check "P4b the PR gate runs after the Challenge Round and before _debate.json" PASS
else
  check "P4b the PR gate runs after the Challenge Round and before _debate.json (4=$CHALLENGE_LINE 4b=$PRVERIFY_LINE 5=$DEBATE_LINE)" FAIL
fi
if grep -qF 'never becomes an inline comment' "$PR_MD"; then
  check "P4c an unverified PR finding never reaches the forge as an inline comment" PASS
else
  check "P4c an unverified PR finding never reaches the forge as an inline comment" FAIL
fi
if grep -qF 'different question from the Phase D pre-publish anchor validation' "$PR_MD"; then
  check "P4d the gate is distinguished from pre-publish anchor validation" PASS
else
  check "P4d the gate is distinguished from pre-publish anchor validation" FAIL
fi
if grep -qF 'Finding Verification Gate — MANDATORY after the Challenge Round' "$PR_RULES"; then
  check "P4e rules/workflow.md documents the gate beside the Debate Strategy" PASS
else
  check "P4e rules/workflow.md documents the gate beside the Debate Strategy" FAIL
fi
if grep -qF '3b. **Finding Verification Gate (lead-run, config-gated).**' "$PLAN_MD"; then
  check "P4f /zensu:plan-review carries the Phase D gate" PASS
else
  check "P4f /zensu:plan-review carries the Phase D gate" FAIL
fi
if grep -qF 'an `[Unverified]` item never carries a NO-GO' "$PLAN_MD"; then
  check "P4g the plan verdict is computed from the post-verification list" PASS
else
  check "P4g the plan verdict is computed from the post-verification list" FAIL
fi
if grep -qF 'never drop a demoted item silently' "$PLAN_MD"; then
  check "P4h a demoted plan blocker is named in the report, never dropped" PASS
else
  check "P4h a demoted plan blocker is named in the report, never dropped" FAIL
fi
for f in "$PR_MD" "$PLAN_MD"; do
  if grep -qF 'zensu_hook_enabled findingVerification' "$f"; then
    check "P4i $(basename "$(dirname "$f")") resolves the same config flag" PASS
  else
    check "P4i $(basename "$(dirname "$f")") resolves the same config flag" FAIL
  fi
done

# ── P5 config + docs surface ─────────────────────────────────────────
if node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(c.hooks && c.hooks.findingVerification===true?0:1)' "$CONFIG_EX" 2>/dev/null; then
  check "P5a config.example.json ships hooks.findingVerification:true" PASS
else
  check "P5a config.example.json ships hooks.findingVerification:true" FAIL
fi
if grep -qF '| `findingVerification` |' "$CONFIG_DOC"; then
  check "P5b docs/configuration.md config table carries the findingVerification row" PASS
else
  check "P5b docs/configuration.md config table carries the findingVerification row" FAIL
fi
if grep -qF 'Finding Verification Gate (gated by `hooks.findingVerification`, default on)' "$CONFIG_DOC"; then
  check "P5c docs/configuration.md chain description places the gate in the chain" PASS
else
  check "P5c docs/configuration.md chain description places the gate in the chain" FAIL
fi
if grep -qF 'Finding Verification Gate (step 4c, gated by `hooks.findingVerification`' "$WORKFLOW_DOC"; then
  check "P5d the workflow doc places the gate in the chain" PASS
else
  check "P5d the workflow doc places the gate in the chain" FAIL
fi

# ── P6 suite classification ──────────────────────────────────────────
if node -e '
const fs = require("node:fs");
const inv = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const classified = [...inv.ciStructureTests, ...inv.localStructureTests];
process.exit(classified.includes("test-finding-verification.sh") ? 0 : 1);
' "$INVENTORY" 2>/dev/null; then
  check "P6 this suite is registered in the run-all classification inventory" PASS
else
  check "P6 this suite is registered in the run-all classification inventory" FAIL
fi

echo "----"
echo "test-finding-verification: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
