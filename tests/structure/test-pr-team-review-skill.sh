#!/bin/bash
set -u

# Structure test for the /zensu:pr-team-review skill.
# Pins: the skill exists with its SKILL.md + four rules files, follows the namespaced
# title-line convention, carries the orchestration essentials (worktree isolation,
# single-message parallel spawn, run_in_background reviewers, one consolidated review
# published through the VCS driver (GitHub or GitLab, via --post-review/--detect),
# the 25-persona pool, the always-on holistic core (coverage-audit + bug-hunter +
# maintainability + adversarial) + the anti-groupthink challenge round + mandatory Test
# Coverage section), is English-only, uses the namespaced command form and
# the ${CLAUDE_PLUGIN_ROOT} path (no leaked ~/.claude/skills home path), is registered
# in plugin.json, and that the version is in sync across plugin.json + marketplace.json
# + the README badge with the skills-count heading bumped to 12.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/pr-team-review"
SKILL_MD="$SKILL_DIR/SKILL.md"
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
  check "P1 skills/pr-team-review/SKILL.md exists" FAIL
  echo "----"
  echo "test-pr-team-review-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/pr-team-review/SKILL.md exists" PASS

# P2 — the rules files ship alongside the skill (incl. the GitLab publish sibling)
for r in reviewer-personas workflow github-publish gitlab-publish; do
  if [ -f "$SKILL_DIR/rules/$r.md" ]; then
    check "P2 skills/pr-team-review/rules/$r.md exists" PASS
  else
    check "P2 skills/pr-team-review/rules/$r.md exists" FAIL
  fi
done

# P3 — namespaced H1 title present, plus the frontmatter that drives invocation + auto-trigger.
# Unlike its slash-only siblings, this skill keeps YAML frontmatter so the description's
# trigger phrases ("team review", "multi-agent PR review", ...) can auto-select it.
if grep -qxF '# /zensu:pr-team-review' "$SKILL_MD"; then
  check "P3a SKILL.md has the namespaced H1 '# /zensu:pr-team-review'" PASS
else
  check "P3a SKILL.md has the namespaced H1 '# /zensu:pr-team-review'" FAIL
fi
if grep -qE '^name: *pr-team-review *$' "$SKILL_MD"; then
  check "P3b SKILL.md frontmatter declares 'name: pr-team-review'" PASS
else
  check "P3b SKILL.md frontmatter declares 'name: pr-team-review'" FAIL
fi

# P4 — orchestration essentials
# Indexed array of "label|needle" pairs (bash 3.2-safe — no `declare -A`, which
# Apple's /bin/bash 3.2 cannot parse; associative arrays would abort this suite
# locally while still exiting 0, silently skipping every check below).
ESSENTIALS=(
  "P4a worktree isolation (git worktree add)|worktree add"
  "P4b single-message parallel spawn|single message"
  "P4c reviewers run in background|run_in_background"
  "P4d one consolidated review (Submit ONE review)|Submit ONE review"
  "P4e publishes through the VCS driver publish op|--post-review"
  "P4g every git-host call goes through the VCS driver|zensu-vcs.sh"
  "P4h detects the forge (GitHub or GitLab)|--detect"
  "P4f casts from the 25-persona pool|25-persona"
)
for entry in "${ESSENTIALS[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF -- "$needle" "$SKILL_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P5 — English-only guard: German tokens MUST be ABSENT across the skill tree.
# Word stems carry their own umlauts; a bare [äöüßÄÖÜ] class is intentionally omitted
# because, under a byte-wise locale, it false-matches multibyte punctuation (em-dash, arrows).
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P5 skill is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P5 skill is English-only (no German tokens)" PASS
fi

# P6 — command refs are namespaced: a backtick-prefixed bare '/pr-team-review' must be ABSENT
if grep -rqF '`/pr-team-review' "$SKILL_DIR"; then
  check "P6 command refs are namespaced (found bare backticked '/pr-team-review')" FAIL
else
  check "P6 command refs are namespaced /zensu:pr-team-review (no bare command ref)" PASS
fi

# P7 — bundled-path: no hardcoded ~/.claude/skills home path; sibling files via ${CLAUDE_PLUGIN_ROOT}
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "P7 no hardcoded ~/.claude/skills home path (use \${CLAUDE_PLUGIN_ROOT})" FAIL
else
  check "P7 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi
WORKFLOW_RULE="$SKILL_DIR/rules/workflow.md"
PUBLISH_RULE="$SKILL_DIR/rules/github-publish.md"
if grep -qF '`{ACTIVE_PLUGIN_ROOT}` in any bundled file loaded later with `Read`' "$SKILL_MD" \
  && grep -qF 'concrete `${CLAUDE_PLUGIN_ROOT}`' "$SKILL_MD" \
  && grep -qF '{ACTIVE_PLUGIN_ROOT}' "$WORKFLOW_RULE" \
  && grep -qF '{ACTIVE_PLUGIN_ROOT}' "$PUBLISH_RULE" \
  && ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$WORKFLOW_RULE" \
  && ! grep -qF '${CLAUDE_PLUGIN_ROOT}' "$PUBLISH_RULE"; then
  check "P7a registered skill maps native root into raw Read rules" PASS
else
  check "P7a registered skill maps native root into raw Read rules" FAIL
fi

# P8 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/pr-team-review")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P8 plugin.json skills[] contains './skills/pr-team-review'" PASS
else
  check "P8 plugin.json skills[] contains './skills/pr-team-review'" FAIL
fi

# P9 — version sync across plugin.json, marketplace.json, README badge
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P9a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P9a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi

EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P9b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P9b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

# P10 — README skills section: count bumped to 12 and the skill is listed
if grep -qE '^### Skills \([0-9]+\)$' "$README_MD"; then
  check "P10a README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" PASS
else
  check "P10a README.md has a '### Skills (N)' heading (count owned by test-converge-skill P4c)" FAIL
fi

if grep -qF "/zensu:pr-team-review" "$README_MD"; then
  check "P10b README.md mentions /zensu:pr-team-review in the skills table" PASS
else
  check "P10b README.md mentions /zensu:pr-team-review in the skills table" FAIL
fi

# P11 — per-run workspace must be race-safe (mirrors plan-review's P9 mktemp mandate).
# A predictable world-writable /tmp name invites a symlink / pre-creation race on
# shared hosts, so the working dir is materialized with `mktemp -d` and no fixed
# /tmp/pr* path may survive anywhere in the skill tree.
if grep -qF 'mktemp -d' "$SKILL_MD"; then
  check "P11a SKILL.md materializes the working dir with mktemp -d" PASS
else
  check "P11a SKILL.md materializes the working dir with mktemp -d" FAIL
fi

if grep -rqF '/tmp/pr' "$SKILL_DIR"; then
  check "P11b no predictable '/tmp/pr*' path remains (race-safe)" FAIL
else
  check "P11b no predictable '/tmp/pr*' path remains (race-safe)" PASS
fi

if grep -qF -- '--detach' "$SKILL_MD"; then
  check "P11c worktree is created detached (re-run never collides on the branch ref)" PASS
else
  check "P11c worktree is created detached (re-run never collides on the branch ref)" FAIL
fi

if grep -qF 'worktree list --porcelain' "$SKILL_MD" \
  && grep -qF 'grep -Fqx "branch $LOCAL_REVIEW_REF"' "$SKILL_MD" \
  && grep -qF 'fetch origin "+$REF:$LOCAL_REVIEW_REF"' "$SKILL_MD"; then
  check "P11d retained review refs refresh safely after force-pushes" PASS
else
  check "P11d retained review refs refresh safely after force-pushes" FAIL
fi

# P12 — always-on test-coverage evaluation. The skill MUST guarantee a coverage
# assessment on every run: an always-cast `coverage-audit` persona + a mandatory
# `### Test Coverage` synthesis section that inventories uncovered files/paths.
PERSONAS_MD="$SKILL_DIR/rules/reviewer-personas.md"

if grep -qF '### Test Coverage' "$SKILL_MD"; then
  check "P12a SKILL.md mandates the '### Test Coverage' synthesis section" PASS
else
  check "P12a SKILL.md mandates the '### Test Coverage' synthesis section" FAIL
fi

if grep -qF 'coverage-audit' "$PERSONAS_MD"; then
  check "P12b reviewer-personas.md defines the 'coverage-audit' persona" PASS
else
  check "P12b reviewer-personas.md defines the 'coverage-audit' persona" FAIL
fi

if grep -qF 'Always cast `coverage-audit`' "$PERSONAS_MD"; then
  check "P12c coverage-audit is always cast (guaranteed every run)" PASS
else
  check "P12c coverage-audit is always cast (guaranteed every run)" FAIL
fi

if grep -riqF 'uncovered' "$SKILL_DIR"; then
  check "P12d skill flags uncovered files/paths" PASS
else
  check "P12d skill flags uncovered files/paths" FAIL
fi

if grep -qF -- '--coverage-gate' "$SKILL_MD" && grep -qF -- '--run-coverage' "$SKILL_MD"; then
  check "P12e SKILL.md documents --coverage-gate + --run-coverage flags" PASS
else
  check "P12e SKILL.md documents --coverage-gate + --run-coverage flags" FAIL
fi

# P13 — persona-pool expansion 15 → 25. Every new persona must be defined with its own
# section, the always-on holistic core must be documented (correctness/design/anti-groupthink
# beyond coverage-audit), and the anti-groupthink debate challenge round must be wired.
WORKFLOW_MD="$SKILL_DIR/rules/workflow.md"

for p in bug-hunter maintainability adversarial observability supply-chain resilience api-compat data-privacy accessibility concurrency; do
  if grep -qF "### \`$p\`" "$PERSONAS_MD"; then
    check "P13 reviewer-personas.md defines the new '$p' persona" PASS
  else
    check "P13 reviewer-personas.md defines the new '$p' persona" FAIL
  fi
done

# P13k — exactly 25 persona sections (### `id`) in the pool. Complements the per-persona
# loop above (which pins the 10 named new ids) by catching an accidental duplicate/extra
# section OR a silent removal of one of the 15 pre-existing personas the loop never names.
# On any future pool resize this literal `25` must move in lockstep with the P4f `25-persona`
# needle and the header comment.
PERSONA_COUNT="$(grep -cE '^### `[a-z-]+`$' "$PERSONAS_MD")"
if [ "$PERSONA_COUNT" -eq 25 ]; then
  check "P13k reviewer-personas.md has exactly 25 persona sections" PASS
else
  check "P13k reviewer-personas.md has exactly 25 persona sections (found $PERSONA_COUNT)" FAIL
fi

# P13l — always-on holistic core documented in both the skill body and the persona rules
if grep -qF 'holistic core' "$SKILL_MD" && grep -qF 'holistic core' "$PERSONAS_MD"; then
  check "P13l always-on holistic core documented in SKILL.md + reviewer-personas.md" PASS
else
  check "P13l always-on holistic core documented in SKILL.md + reviewer-personas.md" FAIL
fi

# P13m — anti-groupthink debate challenge round wired in SKILL.md + workflow.md
if grep -qF 'Challenge Round' "$SKILL_MD" && grep -qF 'Challenge Round' "$WORKFLOW_MD"; then
  check "P13m Phase C Challenge Round documented in SKILL.md + workflow.md" PASS
else
  check "P13m Phase C Challenge Round documented in SKILL.md + workflow.md" FAIL
fi

# P13n — accessibility split cleanly out of frontend-ux (no duplicate WCAG ownership):
# frontend-ux must explicitly defer a11y to the accessibility persona.
if grep -qF 'owned by the `accessibility` persona' "$PERSONAS_MD"; then
  check "P13n frontend-ux defers WCAG/a11y to the accessibility persona (clean split)" PASS
else
  check "P13n frontend-ux defers WCAG/a11y to the accessibility persona (clean split)" FAIL
fi

# P13o — the always-on guarantee lives on the casting-rules line, not just the phrase:
# all four core personas must be named on the "Always cast the holistic core" line, so a
# regression that drops one from the enumeration (the line that makes it always-on) fails.
CORE_LINE="$(grep -F 'Always cast the holistic core' "$PERSONAS_MD" | head -1)"
if printf '%s' "$CORE_LINE" | grep -qF 'coverage-audit' \
   && printf '%s' "$CORE_LINE" | grep -qF 'bug-hunter' \
   && printf '%s' "$CORE_LINE" | grep -qF 'maintainability' \
   && printf '%s' "$CORE_LINE" | grep -qF 'adversarial'; then
  check "P13o casting rule names all 4 holistic-core personas on one line" PASS
else
  check "P13o casting rule names all 4 holistic-core personas on one line" FAIL
fi

# P13p — docs-only PRs must stay lean (docs-only + coverage-audit only, rest of core skipped)
if grep -qF 'Docs-only PRs stay lean' "$PERSONAS_MD"; then
  check "P13p docs-only lean cast documented (docs-only + coverage-audit)" PASS
else
  check "P13p docs-only lean cast documented (docs-only + coverage-audit)" FAIL
fi

# P13q — accessibility split is complete: frontend-component must NOT still claim a11y
# (the 'accessibility basics' ownership phrase was removed so only `accessibility` owns WCAG)
if grep -qF 'accessibility basics' "$PERSONAS_MD"; then
  check "P13q frontend-component no longer owns a11y (no 'accessibility basics')" FAIL
else
  check "P13q frontend-component no longer owns a11y (no 'accessibility basics')" PASS
fi

# P14 — an Autopilot delegation is a strict, durable capability envelope. Any
# envelope header activates delegated parsing; all four lines must then occur
# exactly once and bind the remote review to the current durable run generation.
DELEGATED_NEEDLES=(
  'ZENSU-DELEGATED-CALLER: autopilot'
  'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>'
  'AUTOPILOT-STAGE: <outer-stage>'
  'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>'
  'any delegated-envelope header'
  'partial, duplicate, malformed, or conflicting'
  'bash "$LOG" --autopilot-status'
  '`ownerSessionId`'
  '`tdd.sessionId` equals that same current session id'
  '`runId`'
  '`tdd.attempt`'
  '`tdd.chainId`'
  '`stage`'
  '`evidence.pr.number`'
  '`evidence.pr.url`'
  '`evidence.pr.headSha`'
  '`effects.prOpen.status == "completed"`'
  '`effects.teamReview.status == "requested"`'
  '`effects.teamReview.operationKey`'
  '`effects.teamReview.provider`'
)
P14A=true
for needle in "${DELEGATED_NEEDLES[@]}"; do
  grep -qF -- "$needle" "$SKILL_MD" || P14A=false
done
if [ "$P14A" = true ]; then
  check "P14a delegated review validates an exact durable envelope and fresh state" PASS
else
  check "P14a delegated review validates an exact durable envelope and fresh state" FAIL
fi

PROVIDER_GUARD_LINE="$(grep -nF -- '[ "$DELEGATED" = true ] && [ "$PROVIDER" != "$BOUND_PROVIDER" ]; then' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
SCOUT_LINE="$(grep -nF -- 'bash "$VCS" --scout-pr --provider "$PROVIDER" <n>' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
RECONCILE_LINE="$(grep -nF -- 'bash "$VCS" --reconcile-review --provider "$PROVIDER"' "$SKILL_MD" | head -n 1 | cut -d: -f1)"
if grep -qF -- 'Set `BOUND_PROVIDER` to the validated `effects.teamReview.provider`' "$SKILL_MD" \
   && grep -qF -- 'require `PROVIDER == BOUND_PROVIDER` immediately after detection' "$SKILL_MD" \
   && grep -qF -- 'before scout, worktree creation, payload access, or any remote write' "$SKILL_MD" \
   && grep -qF -- 'review-provider-mismatch' "$SKILL_MD" \
   && grep -qF -- '"$BOUND_HEAD" "$BOUND_PROVIDER" "$REPO"' "$SKILL_MD" \
   && grep -qF -- '"$REVIEW_PAYLOAD" "$BOUND_PROVIDER" "$REPO"' "$SKILL_MD" \
   && [ -n "$PROVIDER_GUARD_LINE" ] && [ -n "$SCOUT_LINE" ] && [ -n "$RECONCILE_LINE" ] \
   && [ "$PROVIDER_GUARD_LINE" -lt "$SCOUT_LINE" ] && [ "$PROVIDER_GUARD_LINE" -lt "$RECONCILE_LINE" ]; then
  check "P14aa delegated review binds the provider before every remote write and payload access" PASS
else
  check "P14aa delegated provider drift can reach reconciliation" FAIL
fi

TEAM_ENVELOPE="$(awk '
  $0 == "ZENSU-DELEGATED-CALLER: autopilot" { capture=1 }
  capture && $0 == "```" { exit }
  capture { print }
' "$SKILL_MD")"
EXPECTED_TEAM_ENVELOPE="$(printf '%s\n' \
  'ZENSU-DELEGATED-CALLER: autopilot' \
  'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' \
  'AUTOPILOT-STAGE: <outer-stage>' \
  'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>')"
if [ "$TEAM_ENVELOPE" = "$EXPECTED_TEAM_ENVELOPE" ] \
   && [ "$(grep -cFx -- 'ZENSU-DELEGATED-CALLER: autopilot' "$SKILL_MD")" -eq 1 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-BINDING: run=<runId> attempt=<attempt> chain=<chainId>' "$SKILL_MD")" -eq 1 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-STAGE: <outer-stage>' "$SKILL_MD")" -eq 1 ] \
   && [ "$(grep -cFx -- 'AUTOPILOT-REVIEW-OP: key=<operationKey> head=<headSha>' "$SKILL_MD")" -eq 1 ] \
   && grep -qF -- 'four contiguous lines with no intervening or additional delegated headers' "$SKILL_MD"; then
  check "P14b delegated review envelope is contiguous, ordered, unique, and closed" PASS
else
  check "P14b delegated review envelope is contiguous, ordered, unique, and closed" FAIL
fi

if grep -qF -- '--reconcile-review --provider "$PROVIDER" --repo-id "$REPOID"' "$SKILL_MD" \
   && grep -qF -- '--expected-head "$BOUND_HEAD"' "$SKILL_MD" \
   && grep -qF -- '<n> "$REVIEW_PAYLOAD" "$OPERATION_KEY"' "$SKILL_MD" \
   && grep -qF -- '`{status,marker,headSha,partCount,postedCount,url,provider}`' "$SKILL_MD" \
   && grep -qF -- 'Require `provider == PROVIDER`' "$SKILL_MD" \
   && grep -qF -- '`present|posted|reconciled`' "$SKILL_MD" \
   && grep -qF -- '`posted` requires `postedCount == partCount`' "$SKILL_MD" \
   && grep -qF -- '`reconciled` requires `0 < postedCount < partCount`' "$SKILL_MD" \
   && grep -qF -- 'GitHub requires `partCount == 1` and rejects `reconciled`' "$SKILL_MD" \
   && grep -qF -- 'GitLab requires `partCount == 1 + comments.length`' "$SKILL_MD"; then
  check "P14c delegated publish validates the exact structured reconcile receipt" PASS
else
  check "P14c delegated publish validates the exact structured reconcile receipt" FAIL
fi

if grep -qF -- 'autopilot_read_team_review_payload' "$SKILL_MD" \
   && grep -qF -- 'autopilot_store_team_review_payload' "$SKILL_MD" \
   && grep -qF -- 'REUSE_DURABLE_PAYLOAD=true' "$SKILL_MD" \
   && grep -qF -- 'REVIEW_PAYLOAD="$WORKDIR/_synthesis.json"' "$SKILL_MD" \
   && grep -qF -- 'before the first `--reconcile-review` call' "$SKILL_MD" \
   && grep -qF -- 'must not re-synthesize or overwrite' "$SKILL_MD" \
   && grep -qF -- 'skip Phases B, C, and the synthesis portion of Phase D' "$SKILL_MD"; then
  check "P14d delegated retry reuses one durable payload and never re-synthesizes it" PASS
else
  check "P14d delegated retry reuses one durable payload and never re-synthesizes it" FAIL
fi

if grep -qF -- 'Delegated mode MUST NOT ask' "$SKILL_MD" \
   && grep -qF -- 'cast confirmation' "$SKILL_MD" \
   && grep -qF -- 'body preview' "$SKILL_MD" \
   && grep -qF -- 'cleanup/ref deletion' "$SKILL_MD" \
   && grep -qF -- 'next-step' "$SKILL_MD" \
   && grep -qF -- 'Standalone mode remains interactive' "$SKILL_MD" \
   && grep -qF -- '--post-review' "$SKILL_MD"; then
  check "P14e delegated mode is unattended while standalone publish stays unchanged" PASS
else
  check "P14e delegated mode is unattended while standalone publish stays unchanged" FAIL
fi

# Interactive branches are allowed only when the same line explicitly scopes
# them to standalone mode. This catches future mid-run auth/provider/repository
# prompts that would silently break Autopilot's unattended contract.
UNQUALIFIED_ASKS="$(SKILL_MD="$SKILL_MD" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.env.SKILL_MD, "utf8").split(/\r?\n/);
  const interactive = /AskUserQuestion|ask (?:the )?user|ask again|ask anyway|always asks|pause and wait|escalate to (?:the )?user/i;
  const qualified = /standalone/i;
  const prohibition = /(?:do not|never|without)\b.*\bask/i;
  lines.forEach((line, index) => {
    if (interactive.test(line) && !qualified.test(line) && !prohibition.test(line)) {
      process.stdout.write(`${index + 1}:${line}\n`);
    }
  });
')"
if [ -z "$UNQUALIFIED_ASKS" ] \
   && grep -qF -- 'review-repo-unavailable' "$SKILL_MD" \
   && grep -qF -- 'review-provider-unknown' "$SKILL_MD" \
   && grep -qF -- 'review-auth-unavailable' "$SKILL_MD" \
   && grep -qF -- 'persist `BLOCK`' "$SKILL_MD"; then
  check "P14f delegated repository/provider/auth blockers never enter an interactive ask path" PASS
else
  [ -z "$UNQUALIFIED_ASKS" ] || printf '%s\n' "$UNQUALIFIED_ASKS" >&2
  check "P14f delegated repository/provider/auth blockers never enter an interactive ask path" FAIL
fi

if grep -qF -- 'hexadecimal head between 7 and 64 characters' "$SKILL_MD" \
   && grep -qF -- '[ "$SHA" = "$BOUND_HEAD" ]' "$SKILL_MD" \
   && grep -qF -- 'never substitute the freshly fetched SHA for the capability-bound head' "$SKILL_MD"; then
  check "P14g delegated review keeps the state SHA domain and bound head" PASS
else
  check "P14g delegated review keeps the state SHA domain and bound head" FAIL
fi

if grep -qF -- 'Delegated mode fails closed on every non-zero or malformed `--reconcile-review` result' "$PUBLISH_RULE" \
   && grep -qF -- 'retry the complete `--reconcile-review` call' "$PUBLISH_RULE" \
   && grep -qF -- 'never update the bound head or payload' "$PUBLISH_RULE" \
   && grep -qF -- '## Standalone-only fallback: Per-comment posting' "$PUBLISH_RULE"; then
  check "P14h delegated GitHub publication never escapes reconciliation" PASS
else
  check "P14h delegated GitHub publication never escapes reconciliation" FAIL
fi

echo "----"
echo "test-pr-team-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
