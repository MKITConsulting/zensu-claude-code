#!/bin/bash
set -u

# Structure test for the /zensu:plan-review skill.
# Pins: the skill exists as a single self-contained SKILL.md, follows the title-line
# convention, carries the orchestration essentials (dedicated worker, private lease,
# default team size 6, the four core personas, the verdict enum), is English-only and
# stack-agnostic (no leaked stack names from any specific product), is registered in
# plugin.json, and that the version is in sync across plugin.json + marketplace.json +
# the README badge.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/plan-review"
SKILL_MD="$SKILL_DIR/SKILL.md"
WORKER_MD="$PLUGIN_DIR/agents/plan-review-worker.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PLUGIN_DIR/.claude-plugin/marketplace.json"
README_MD="$PLUGIN_DIR/README.md"
EXPECTED_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# P1 — SKILL.md exists
if [ ! -f "$SKILL_MD" ]; then
  check "P1 skills/plan-review/SKILL.md exists" FAIL
  echo "----"
  echo "test-plan-review-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/plan-review/SKILL.md exists" PASS

# P2 — namespaced H1 title + frontmatter name (drives invocation + auto-trigger)
if grep -qxF '# /zensu:plan-review' "$SKILL_MD"; then
  check "P2 SKILL.md has the namespaced H1 '# /zensu:plan-review'" PASS
else
  check "P2 SKILL.md has the namespaced H1 '# /zensu:plan-review'" FAIL
fi
if grep -qE '^name: *plan-review *$' "$SKILL_MD"; then
  check "P2b SKILL.md frontmatter declares 'name: plan-review'" PASS
else
  check "P2b SKILL.md frontmatter declares 'name: plan-review'" FAIL
fi

# P3 — orchestration essentials
if grep -qF 'subagent_type: zensu:plan-review-worker' "$SKILL_MD" \
   && [ -f "$WORKER_MD" ] \
   && grep -qE '^name: *plan-review-worker *$' "$WORKER_MD" \
   && grep -qE '^tools: *Read, Grep, Glob *$' "$WORKER_MD" \
   && grep -qF 'Your entire final assistant message must be exactly one raw JSON object' "$WORKER_MD" \
   && grep -qF 'with `kind` exactly `plan-review` and `role`' "$WORKER_MD" \
   && grep -qF '≤ 6 blockers, ≤ 12 improvements, ≤ 16 questions, and ≤ 16 strengths' "$SKILL_MD" \
   && grep -qF 'You have no command, write, task, messaging, team,' "$WORKER_MD" \
   && ! grep -qF 'subagent_type: general-purpose' "$SKILL_MD" \
   && ! grep -qF 'TeamCreate' "$SKILL_MD"; then
  check "P3a SKILL.md and agent file define the exact capability-confined plan worker" PASS
else
  check "P3a SKILL.md and agent file define the exact capability-confined plan worker" FAIL
fi

if grep -qiE 'read-only' "$SKILL_MD"; then
  check "P3b SKILL.md states the READ-ONLY validator mandate" PASS
else
  check "P3b SKILL.md states the READ-ONLY validator mandate" FAIL
fi

if grep -qiE 'default[^0-9]{0,15}6' "$SKILL_MD"; then
  check "P3c SKILL.md documents the default team size of 6" PASS
else
  check "P3c SKILL.md documents the default team size of 6" FAIL
fi

CORE_PERSONAS=(requirements-completeness feasibility-soundness testing-tdd devils-advocate)
for p in "${CORE_PERSONAS[@]}"; do
  if grep -qF "$p" "$SKILL_MD"; then
    check "P3d SKILL.md defines core persona '$p'" PASS
  else
    check "P3d SKILL.md defines core persona '$p'" FAIL
  fi
done

for v in 'go-with-changes' 'no-go'; do
  if grep -qF "$v" "$SKILL_MD"; then
    check "P3e SKILL.md output schema includes verdict '$v'" PASS
  else
    check "P3e SKILL.md output schema includes verdict '$v'" FAIL
  fi
done

# P4 — English-only + generic guard: these patterns MUST be ABSENT from SKILL.md
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -qiE "$GERMAN_RE" "$SKILL_MD"; then
  check "P4a SKILL.md is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P4a SKILL.md is English-only (no German tokens)" PASS
fi

STACK_RE='pro-cloud|hermes|ppsharedlibrary|spring modulith|flyway|@require(tenant|global)|PPS-[0-9]'
if grep -qiE "$STACK_RE" "$SKILL_MD"; then
  check "P4b SKILL.md is stack-agnostic (found leaked stack names matching: $STACK_RE)" FAIL
else
  check "P4b SKILL.md is stack-agnostic (no leaked stack names)" PASS
fi

# P5 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/plan-review")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P5 plugin.json skills[] contains './skills/plan-review'" PASS
else
  check "P5 plugin.json skills[] contains './skills/plan-review'" FAIL
fi
if jq -e '.agents | index("./agents/plan-review-worker.md")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P5b plugin.json agents[] contains './agents/plan-review-worker.md'" PASS
else
  check "P5b plugin.json agents[] contains './agents/plan-review-worker.md'" FAIL
fi

# P6 — version sync across plugin.json, marketplace.json, README badge
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P6a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P6a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi

EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P6b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P6b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

# P8 — in-body command references use the namespaced form (no bare backticked `/plan-review`).
# A backtick immediately followed by /plan-review is the inline command reference; the /tmp
# / mktemp working-dir paths are inside a fenced code block and are NOT backtick-prefixed,
# so this uniquely catches a bare (non-namespaced) command ref.
if grep -qF '`/plan-review' "$SKILL_MD"; then
  check "P8 SKILL.md command refs are namespaced (found bare backticked '/plan-review')" FAIL
else
  check "P8 SKILL.md command refs are namespaced /zensu:plan-review (no bare command ref)" PASS
fi

# P9 — the per-run working dir is created unpredictably with mktemp -d (not a predictable /tmp path)
if grep -qF 'mktemp -d' "$SKILL_MD"; then
  check "P9 SKILL.md materializes the working dir with mktemp -d (no predictable /tmp path)" PASS
else
  check "P9 SKILL.md materializes the working dir with mktemp -d (no predictable /tmp path)" FAIL
fi

# P10 — dedicated plan-review workers consume a private evidence lease and return
# one raw JSON final message. Only the main thread may materialize accepted results.
INJECTION_BLOCK="$(awk '
  /^\*\*Injection block — put this in every reviewer prompt/ { capture=1 }
  capture { print }
  capture && /^### Phase D/ { exit }
' "$SKILL_MD")"

if grep -qF 'Main-thread evidence packet (mandatory before spawn)' "$SKILL_MD" \
   && grep -qF '<DIR>/EVIDENCE.md' "$SKILL_MD" \
   && grep -qF '<DIR>/CANDIDATE_FILES.txt' "$SKILL_MD" \
   && grep -qF '<DIR>/SAFE_SUBTREES.txt' "$SKILL_MD" \
   && grep -qF 'repository root and every ancestor of it are forbidden entries' "$SKILL_MD"; then
  check "P10a main thread materializes evidence, exact candidates, and narrow safe subtrees" PASS
else
  check "P10a main thread materializes evidence, exact candidates, and narrow safe subtrees" FAIL
fi

if printf '%s' "$INJECTION_BLOCK" | grep -qF 'you may use `Read`' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'you may use `Grep` and `Glob` only' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'You have no write, task, messaging, nested-agent, Skill, MCP, Web, or command capability' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'entire final assistant message' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'one raw JSON object' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'Set `kind` exactly to `plan-review` and `role` exactly to `<persona-id>`'; then
  check "P10b worker contract is leased Read/Grep/Glob plus exact raw JSON final output" PASS
else
  check "P10b worker contract is leased Read/Grep/Glob plus exact raw JSON final output" FAIL
fi

if printf '%s' "$INJECTION_BLOCK" | grep -qF 'do not call `Bash`, `shell`, `exec`, `exec_command`, `terminal`, or `command`' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'Do not invoke command-line `git`, `find`, or `grep`' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'There is no shell exception' \
   && ! printf '%s' "$INJECTION_BLOCK" | grep -qF 'use `grep`, `find`, `Read`, and read-only `git`' \
   && ! printf '%s' "$INJECTION_BLOCK" | grep -qF 'at the start of your bash calls'; then
  check "P10c reviewer prompt denies every command tool and legacy CLI guidance" PASS
else
  check "P10c reviewer prompt denies every command tool and legacy CLI guidance" FAIL
fi

if printf '%s' "$INJECTION_BLOCK" | grep -qF 'Never search or traverse `<REPO>`, an ancestor of `<REPO>`' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'If evidence is insufficient, record the gap in `questions`; do not broaden the search scope' \
   && printf '%s' "$INJECTION_BLOCK" | grep -qF 'Untrusted-data boundary' \
   && grep -qF 'fully expanded absolute path before spawning' "$SKILL_MD"; then
  check "P10d worker cannot follow untrusted instructions, widen scope, or rely on placeholder expansion" PASS
else
  check "P10d worker cannot follow untrusted instructions, widen scope, or rely on placeholder expansion" FAIL
fi

CAST_LINE="$(grep -n '^### Phase B — Cast' "$SKILL_MD" | head -1 | cut -d: -f1)"
CONFIRM_LINE="$(grep -n 'ask the user to approve it before any lease is created' "$SKILL_MD" \
  | head -1 | cut -d: -f1)"
ROLE_COUNT_LINE="$(grep -n 'ROLE_COUNT=<exact-number-of-personas-in-final-accepted-list>' \
  "$SKILL_MD" | head -1 | cut -d: -f1)"
CREATE_LINE="$(grep -n 'zensu-review-evidence.sh" create' "$SKILL_MD" | head -1 | cut -d: -f1)"
SPAWN_LINE="$(grep -n '^### Phase C — Confined Parallel Spawn' "$SKILL_MD" | head -1 | cut -d: -f1)"
if [ -n "$CAST_LINE" ] && [ -n "$CONFIRM_LINE" ] && [ -n "$ROLE_COUNT_LINE" ] \
   && [ -n "$CREATE_LINE" ] && [ -n "$SPAWN_LINE" ] \
   && [ "$CAST_LINE" -lt "$CONFIRM_LINE" ] \
   && [ "$CONFIRM_LINE" -lt "$ROLE_COUNT_LINE" ] \
   && [ "$ROLE_COUNT_LINE" -lt "$CREATE_LINE" ] \
   && [ "$CREATE_LINE" -lt "$SPAWN_LINE" ] \
   && grep -qF -- '--max-workers "$ROLE_COUNT"' "$SKILL_MD" \
   && ! grep -qF -- '--max-workers "$N"' "$SKILL_MD"; then
  check "P10da lease creation follows final confirmation and uses exact ROLE_COUNT" PASS
else
  check "P10da lease creation follows final confirmation and uses exact ROLE_COUNT" FAIL
fi

if grep -qF 'Resolve every reduce, expand, or custom response into a final deduplicated persona list' \
     "$SKILL_MD" \
   && grep -qF 'No-padding can make the final list smaller than N' "$SKILL_MD" \
   && grep -qF 'If the user rejects or cancels without accepting a final list' "$SKILL_MD" \
   && grep -qF 'no evidence lease may exist' "$SKILL_MD" \
   && grep -qF 'Set `ROLE_COUNT` to the exact number of unique personas in the final accepted list' \
     "$SKILL_MD" \
   && grep -qF 'After this point do not alter the cast' "$SKILL_MD"; then
  check "P10db reduced/custom/no-padding/rejected confirmation contracts are explicit" PASS
else
  check "P10db reduced/custom/no-padding/rejected confirmation contracts are explicit" FAIL
fi

if grep -qF 'zensu-review-evidence.sh" create' "$SKILL_MD" \
   && grep -qF -- '--kind plan-review' "$SKILL_MD" \
   && grep -qF 'zensu-review-evidence.sh finalize --lease-id "<captured-lease-id>"' "$SKILL_MD" \
   && grep -qF 'Stdout must be exactly `sealed=<captured-lease-id>`' "$SKILL_MD" \
   && grep -qF 'collect --kind plan-review --agent-id "<agent-id>" --expected-role "<persona-id>"' "$SKILL_MD" \
   && grep -qF 'Stdout must be exactly one canonical JSON object with `kind:"plan-review"`' "$SKILL_MD" \
   && grep -qF 'Only the main thread writes accepted debug files' "$SKILL_MD" \
   && grep -qF 'zensu-review-evidence.sh" close --lease-id' "$SKILL_MD" \
   && grep -qF 'including error paths' "$SKILL_MD"; then
  check "P10e private lease create/finalize/collect/close and main-only materialization are complete" PASS
else
  check "P10e private lease create/finalize/collect/close and main-only materialization are complete" FAIL
fi

if grep -qF 'rejects a tree containing symlinks, special files, protected scope, or another unsafe alias' "$SKILL_MD" \
   && grep -qF 'snapshots the complete allowed tree and revalidates it before every traversal call' "$SKILL_MD" \
   && grep -qF "including an unread file or drift after a worker's last tool call" "$SKILL_MD" \
   && grep -qF 'A failed worker may be retried only after closing the current lease and creating a fresh lease generation' "$SKILL_MD"; then
  check "P10f symlink/TOCTOU drift and failed generations fail closed" PASS
else
  check "P10f symlink/TOCTOU drift and failed generations fail closed" FAIL
fi

if grep -qF 'Do not create an agent team' "$SKILL_MD" \
   && ! grep -qF 'TaskUpdate' "$SKILL_MD" \
   && ! grep -qF 'SendMessage' "$SKILL_MD" \
   && ! grep -qF 'use `Write`' "$SKILL_MD" \
   && ! grep -qF 'Write your verdict' "$SKILL_MD"; then
  check "P10g workers receive no team, task, messaging, or file-mutation instruction" PASS
else
  check "P10g workers receive no team, task, messaging, or file-mutation instruction" FAIL
fi

echo "----"
echo "test-plan-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
