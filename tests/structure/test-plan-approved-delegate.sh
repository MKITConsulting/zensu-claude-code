#!/bin/bash
# Pins plan-approved-delegate.sh (PostToolUse:ExitPlanMode) behavioral output:
#   default (autoTdd on) -> emits SessionStart-style additionalContext JSON that
#     directs the MAIN thread to ASK the user ONE AskUserQuestion naming four
#     mutually exclusive delivery routes — /zensu:autopilot, /zensu:tdd,
#     /zensu:pilot, implement directly — ordered so the route fitting the plan
#     leads and 'implement directly' never does, with the 'Executing via
#     /zensu:tdd' / 'Skipping TDD' status-line contract and the doc-only
#     (README/CHANGELOG/markdown) escape exception. Every route assertion is
#     graded in BOTH emitted heredocs (strict and vanilla), because the two are
#     hand-maintained and a one-sided edit is the drift these checks exist for.
#     The non-interactive fast-path must never select /zensu:autopilot: that
#     route pushes a branch and opens a pull request (D13).
#   hooks.autoTdd=false  -> silent (no output), so the hook can be disabled.
#   MUST NOT reference the removed pre-0.4.0 'tdd-manager' subagent.
# This is the deterministic counterpart to evals/plan-approval-hook (interactive
# expect+API) — it proves the hook's emitted directive without spawning a session.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HOOK" ]; then
  check "hooks/plan-approved-delegate.sh exists" FAIL
  echo "----"; echo "test-plan-approved-delegate: $PASS PASS / $FAIL FAIL"; exit 1
fi
check "D0 hooks/plan-approved-delegate.sh exists" PASS

if bash -n "$HOOK" 2>/dev/null; then
  check "D1 bash -n syntax check passes" PASS
else
  check "D1 bash -n syntax check passes" FAIL
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
mkdir -p "$CLAUDE_PROJECT_DIR"
# Exercise the hook with the same sealed context a real SessionStart supplies.
# shellcheck disable=SC1090
SESSION_ID="plan-approved-session"
source "$BASELINE" "$SESSION_ID"
# Force defaults (autoTdd enabled) by pointing config resolution at a missing file.
export ZENSU_CONFIG="$TMP_DIR/no-such-config.json"

OUT="$(SESSION_ID="$SESSION_ID" node -e 'process.stdout.write(JSON.stringify({
  hook_event_name: "PostToolUse", session_id: process.env.SESSION_ID,
  tool_name: "ExitPlanMode", tool_input: {plan: "add a function"}
}))' | bash "$HOOK" 2>/dev/null)"

# D2 valid additionalContext JSON for PostToolUse
if printf '%s' "$OUT" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c);
  process.stdin.on("end",()=>{ try { const j=JSON.parse(s);
    const o=j.hookSpecificOutput;
    const ok = o && o.hookEventName==="PostToolUse" && typeof o.additionalContext==="string" && o.additionalContext.length>0;
    process.exit(ok?0:1); } catch(_){ process.exit(1); } });
'; then
  check "D2 emits valid PostToolUse additionalContext JSON on default (autoTdd on)" PASS
else
  check "D2 emits valid PostToolUse additionalContext JSON on default (autoTdd on)" FAIL
fi

# D3 directive routes to the /zensu:tdd Skill in the main thread
if printf '%s' "$OUT" | grep -qF "skill='zensu:tdd'"; then
  check "D3 directive names skill='zensu:tdd' (main-thread routing)" PASS
else
  check "D3 directive names skill='zensu:tdd'" FAIL
fi

# D4 status-line contract present (Executing via /zensu:tdd | Skipping TDD)
if printf '%s' "$OUT" | grep -qF 'Executing via /zensu:tdd' \
   && printf '%s' "$OUT" | grep -qF 'Skipping TDD'; then
  check "D4 status-line contract present (Executing via /zensu:tdd | Skipping TDD)" PASS
else
  check "D4 status-line contract present" FAIL
fi

# D5 doc-only escape exception documented (README/CHANGELOG/markdown)
if printf '%s' "$OUT" | grep -qiE 'README|CHANGELOG|markdown'; then
  check "D5 doc-only escape exception documented" PASS
else
  check "D5 doc-only escape exception documented" FAIL
fi

# D6 routes in main thread, NOT via the removed pre-0.4.0 tdd-manager subagent.
# ('tdd-manager' may still appear as a user TDD-negation phrase, e.g. 'no tdd-manager';
#  what must be gone is any Agent dispatch to subagent_type='zensu:tdd-manager'.)
if printf '%s' "$OUT" | grep -qiF 'main thread' \
   && ! printf '%s' "$OUT" | grep -qF "subagent_type='zensu:tdd-manager'"; then
  check "D6 routes in main thread, not via removed tdd-manager subagent dispatch" PASS
else
  check "D6 routes in main thread, not via removed tdd-manager subagent dispatch" FAIL
fi

# D8 ask-first: default directive routes through the AskUserQuestion tool
if printf '%s' "$OUT" | grep -qF 'AskUserQuestion'; then
  check "D8 default directive asks the user (AskUserQuestion) before TDD" PASS
else
  check "D8 default directive asks the user (AskUserQuestion) before TDD" FAIL
fi

# --- Delivery-route question (four mutually exclusive routes) ----------------
# The default config resolves to the VANILLA branch, so $OUT alone grades one of
# the two heredocs. Force the strict branch as well: every route assertion below
# must hold in BOTH, because the two directives are hand-kept in lockstep and a
# one-sided edit is exactly the drift these checks exist to catch.
CFG_STRICT="$TMP_DIR/tdd-strict.json"
printf '{"hooks":{"tddImplementation":true}}' > "$CFG_STRICT"
OUT_STRICT="$(SESSION_ID="$SESSION_ID" node -e 'process.stdout.write(JSON.stringify({
  hook_event_name: "PostToolUse", session_id: process.env.SESSION_ID,
  tool_name: "ExitPlanMode", tool_input: {plan: "add a function"}
}))' | ZENSU_CONFIG="$CFG_STRICT" bash "$HOOK" 2>/dev/null)"
rm -f "$CFG_STRICT"

# D9pre control AND gate: without it the paired checks below could be grading the
# same directive twice and passing for the wrong reason, so a failure here must
# stop them reporting PASS rather than merely record its own FAIL beside them.
# The emptiness conjunct matters too: the negative half is satisfied by an empty
# $OUT, which would make every needle check below fail for the wrong reason.
BRANCHES_DISTINCT=no
if [ -n "$OUT" ] && [ -n "$OUT_STRICT" ] \
   && printf '%s' "$OUT_STRICT" | grep -qF 'strict TDD flow' \
   && ! printf '%s' "$OUT" | grep -qF 'strict TDD flow'; then
  BRANCHES_DISTINCT=yes
  check "D9pre strict and vanilla branches resolve to different non-empty directives" PASS
else
  check "D9pre strict and vanilla branches resolve to different non-empty directives" FAIL
fi

# every needle must be present in BOTH emitted directives
both_have() {
  local label="$1"; shift
  local n
  if [ "$BRANCHES_DISTINCT" != yes ]; then
    check "$label (not graded: D9pre failed, the two branches are not distinct)" FAIL
    return
  fi
  for n in "$@"; do
    if ! printf '%s' "$OUT" | grep -qF -- "$n"; then
      check "$label (vanilla branch missing: $n)" FAIL
      return
    fi
    if ! printf '%s' "$OUT_STRICT" | grep -qF -- "$n"; then
      check "$label (strict branch missing: $n)" FAIL
      return
    fi
  done
  check "$label" PASS
}

# D9 all three delegating routes name the skill they hand off to
both_have "D9 directive names all three delivery skills" \
  "skill='zensu:autopilot'" "skill='zensu:tdd'" "skill='zensu:pilot'"

# D10 every one of the four routes carries its own status line
both_have "D10 four route status lines present" \
  'Executing via /zensu:autopilot' 'Executing via /zensu:pilot' \
  'Executing via /zensu:tdd' 'Skipping TDD: user declined'

# D11 the option-ordering rule, including the clause that keeps the do-nothing
# route out of the first slot
both_have "D11 ordering rule present, direct-implement never first" \
  'mark the first one as recommended' \
  "'No — implement directly' is NEVER in the first slot" \
  'Autopilot first when the plan is a whole user-visible feature' \
  'Pilot first when the work belongs to a feature already tracked in Zensu' \
  'the Zensu workflow first' \
  'Rank on your OWN reading of what the change does'

# D12 fast-path precedence: 'pilot' is a substring of 'autopilot', so the longer
# literal has to be tested first or an autopilot request routes to the wrong skill.
# The literals carry the order words, but presence alone would still pass on a
# directive that emitted the two arms the other way round — so the offsets are
# compared as well.
both_have "D12 fast-path names the autopilot-before-pilot rule" \
  "is a substring of 'autopilot'" "FIRST 'use autopilot'" "THEN 'use pilot'"
# Needles carrying an apostrophe travel through the ENVIRONMENT, never inside the
# single-quoted node program: a bare ' closes the shell argument and truncates the
# needle silently, which leaves the check passing for the wrong reason.
arm_order() {
  printf '%s' "$1" | N_FIRST="FIRST 'use autopilot'" N_THEN="THEN 'use pilot'" node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      const a=s.indexOf(process.env.N_FIRST);
      const b=s.indexOf(process.env.N_THEN);
      process.stdout.write(a>=0 && b>a ? "OK" : "BAD(a="+a+",b="+b+")");
    });' 2>/dev/null
}
D12B="$(arm_order "$OUT")/$(arm_order "$OUT_STRICT")"
if [ "$BRANCHES_DISTINCT" != yes ]; then
  check "D12b (not graded: D9pre failed, the two branches are not distinct)" FAIL
elif [ "$D12B" = "OK/OK" ]; then
  check "D12b the autopilot arm really precedes the pilot arm in both branches" PASS
else
  check "D12b autopilot/pilot arm order ($D12B)" FAIL
fi

# D13 the non-interactive path must NEVER select the PR-opening route: that route
# pushes a branch and opens a pull request, and no outward-facing step may be
# taken without a human choosing it. Graded as a PROPERTY, not as a list of
# hand-picked spellings — an earlier form rejected two literals, so a reworded
# escalation ("default to running /zensu:autopilot") passed it. Both the (B) and
# the (C) clause are sliced: (B) is where the escalation is actually reachable,
# and the earlier slice could not see it at all.
route_clause_verdict() {
  printf '%s' "$1" | N_DISPATCH="skill='zensu:autopilot'" \
    N_REFUSAL="REMOVE that route from consideration and keep testing" \
    N_FIRST="FIRST 'use autopilot'" node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      const ib=s.indexOf("(B) the user");
      const ic=s.indexOf("(C) you are running non-interactively");
      const ie=s.indexOf("In EVERY OTHER case");
      if(ib<0||ic<=ib||ie<=ic){ process.stdout.write("SLICE_FAILED"); return; }
      // Slices are non-empty by construction once the guard above passes, so no
      // emptiness arm is written here — one would read as a control that cannot fire.
      const b=s.slice(ib,ic), c=s.slice(ic,ie), tail=s.slice(ie);
      const n=(c.match(/\/zensu:autopilot/g)||[]).length;
      const bad=[];
      if(n!==1) bad.push("c-autopilot-mentions="+n);
      if(c.indexOf("is NEVER selected")<0) bad.push("c-no-never-clause");
      if(c.indexOf("(C) OVERRIDES (B)")<0) bad.push("c-no-override-clause");
      if(c.indexOf(process.env.N_DISPATCH)>=0) bad.push("c-dispatches-autopilot");
      if(b.indexOf(process.env.N_REFUSAL)<0) bad.push("b-no-refusal-guard");
      if(b.indexOf("ONLY those multi-word forms count")<0) bad.push("b-no-multiword-rule");
      if(b.indexOf("in ANY language")<0) bad.push("b-refusal-not-open-set");
      // The refusal must be tested BEFORE the preference arms, or a refused route
      // matches the preference literal first. Presence alone cannot see that, so
      // compare offsets the way arm_order does for the two route arms. NOTE: no
      // apostrophe may appear anywhere in this program, comments included — a bare
      // one closes the surrounding single-quoted shell argument and truncates it.
      const r=b.indexOf(process.env.N_REFUSAL), pf=b.indexOf(process.env.N_FIRST);
      if(r<0||pf<0||r>pf) bad.push("b-refusal-not-first");
      // Everything AFTER the two clauses — the option list and the act-on-the-answer
      // paragraph — carries three further /zensu:autopilot mentions that only presence
      // needles grade. Guard the one property that matters there: no clause may tie a
      // non-interactive run to a route. The single sanctioned mention is the
      // parenthetical stating the opposite.
      if(!tail.length) bad.push("tail-empty");
      const ni=(tail.match(/non-interactiv/g)||[]).length;
      if(ni!==1) bad.push("tail-noninteractive-mentions="+ni);
      if(tail.indexOf("which clause (C) makes unreachable non-interactively")<0) bad.push("tail-no-sanctioned-parenthetical");
      if(/Auto Mode|headless/.test(tail)) bad.push("tail-names-auto-mode");
      process.stdout.write(bad.length?bad.join(","):"OK");
    });' 2>/dev/null
}
D13V="$(route_clause_verdict "$OUT")/$(route_clause_verdict "$OUT_STRICT")"
if [ "$BRANCHES_DISTINCT" != yes ]; then
  check "D13 (not graded: D9pre failed, the two branches are not distinct)" FAIL
elif [ "$D13V" = "OK/OK" ]; then
  check "D13 non-interactive path cannot select autopilot; (B) guards refusals and bare mentions" PASS
else
  check "D13 route-clause property ($D13V)" FAIL
fi

# D14/D15 the two prerequisite disclosures (AC-004, AC-005). A route offered
# without its cost is a dead end the user only discovers inside the skill.
both_have "D14 autopilot option states its planning gate and forge-CLI cost" \
  'MUST state the cost' 'runs its OWN planning gate first' \
  'authenticated forge CLI (gh or glab), without which the Zensu workflow is the route'
both_have "D15 pilot option states its zensu-CLI and tracked-feature prerequisite" \
  'MUST state the prerequisite' 'ALREADY tracked in Zensu'

# D16 the four OPTION LABELS themselves. Every other route check grades the
# act-on-the-answer paragraph, so without this one an option could be deleted
# from the question while the routing prose kept every check green.
both_have "D16 all four option labels present in the question" \
  "(1) 'Autopilot — /zensu:autopilot'" "(2) 'Zensu workflow — /zensu:tdd'" \
  "(3) 'Pilot — /zensu:pilot'" "(4) 'No — implement directly'" \
  'carrying exactly these four mutually exclusive options and no others'

# D7 hooks.autoTdd=false -> silent (hook can be disabled)
CFG_OFF="$TMP_DIR/autotdd-off.json"
printf '{"hooks":{"autoTdd":false}}' > "$CFG_OFF"
OUT_OFF="$(SESSION_ID="$SESSION_ID" node -e 'process.stdout.write(JSON.stringify({
  hook_event_name: "PostToolUse", session_id: process.env.SESSION_ID,
  tool_name: "ExitPlanMode"
}))' | ZENSU_CONFIG="$CFG_OFF" bash "$HOOK" 2>/dev/null)"
rm -f "$CFG_OFF"
if [ -z "$OUT_OFF" ]; then
  check "D7 hooks.autoTdd=false -> silent (no output)" PASS
else
  check "D7 hooks.autoTdd=false -> silent (got: $OUT_OFF)" FAIL
fi

echo "----"
echo "test-plan-approved-delegate: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
