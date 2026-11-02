#!/bin/bash
set -u

# Structure test for the /zensu:autopilot skill.
# Pins: the skill exists with its SKILL.md + four rules files, follows the namespaced
# title-line convention, carries the orchestration essentials (one planning gate, the
# strict build order delegating to the sibling Zensu skills, team-review-once, the
# validate↔fix loop, never auto-merge/deploy, worktree-only), enforces the credential-blind
# security invariants (AI never sees a secret, login-script not endpoint, artifacts handled
# as credentials, secret-free config), is English-only, uses the namespaced command form,
# leaks no ~/.claude/skills home path, and is registered in plugin.json. It intentionally
# does NOT assert the shared README "### Skills (N)" heading — that count is owned by the
# sibling skill tests; bumping it here would couple this test to four unrelated ones.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/autopilot"
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
  check "P1 skills/autopilot/SKILL.md exists" FAIL
  echo "----"
  echo "test-autopilot-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 skills/autopilot/SKILL.md exists" PASS

# P2 — the four rules files ship alongside the skill
for r in probe auth drivers config; do
  if [ -f "$SKILL_DIR/rules/$r.md" ]; then
    check "P2 skills/autopilot/rules/$r.md exists" PASS
  else
    check "P2 skills/autopilot/rules/$r.md exists" FAIL
  fi
done

# P3 — namespaced H1 title + frontmatter name (drives invocation + auto-trigger)
if grep -qxF '# /zensu:autopilot' "$SKILL_MD"; then
  check "P3a SKILL.md has the namespaced H1 '# /zensu:autopilot'" PASS
else
  check "P3a SKILL.md has the namespaced H1 '# /zensu:autopilot'" FAIL
fi
if grep -qE '^name: *autopilot *$' "$SKILL_MD"; then
  check "P3b SKILL.md frontmatter declares 'name: autopilot'" PASS
else
  check "P3b SKILL.md frontmatter declares 'name: autopilot'" FAIL
fi

# P4 — orchestration essentials
# Indexed array of "label|needle" pairs (bash 3.2-safe — no `declare -A`, which Apple's
# /bin/bash 3.2 cannot parse; the associative form aborts this suite locally yet exits 0,
# silently skipping every check below while run-all.sh scores a false PASS).
ESSENTIALS=(
  "P4a one interactive planning gate|the ONLY interactive gate"
  "P4b implements via /zensu:build|/zensu:build"
  "P4c team review via /zensu:pr-team-review|/zensu:pr-team-review"
  "P4d fixes via /zensu:pr-fix-findings|/zensu:pr-fix-findings"
  "P4e team review runs ONCE, not in the loop|ONCE"
  "P4f validate <-> fix loop|Validate ↔ fix LOOP"
  "P4g never auto-merge / auto-deploy|Never auto-merge"
  "P4h worktree-only build|Worktree only"
)
for entry in "${ESSENTIALS[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF "$needle" "$SKILL_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done

# P5 — credential-blind security invariants (the skill's most important property)
if grep -qiF 'credential-blind' "$SKILL_MD"; then
  check "P5a SKILL.md states the credential-blind property" PASS
else
  check "P5a SKILL.md states the credential-blind property" FAIL
fi
AUTH_MD="$SKILL_DIR/rules/auth.md"
if grep -qiF 'never sees a password' "$AUTH_MD"; then
  check "P5b auth.md: the AI never sees a password or token" PASS
else
  check "P5b auth.md: the AI never sees a password or token" FAIL
fi
# Script convention, not an auth-bypass endpoint (prod backdoor risk).
if grep -qiF 'Do not introduce an endpoint' "$AUTH_MD"; then
  check "P5c auth.md: no test-login endpoint is introduced (script convention)" PASS
else
  check "P5c auth.md: no test-login endpoint is introduced (script convention)" FAIL
fi
# Session artifacts are credentials → temp + chmod 600 + deleted.
if grep -qF 'chmod 600' "$AUTH_MD"; then
  check "P5d auth.md: artifacts handled as credentials (chmod 600)" PASS
else
  check "P5d auth.md: artifacts handled as credentials (chmod 600)" FAIL
fi
# Committed config carries no secret values.
if grep -rqiF 'secret-free' "$SKILL_DIR"; then
  check "P5e config is committed but secret-free" PASS
else
  check "P5e config is committed but secret-free" FAIL
fi

# P6 — English-only guard: German tokens MUST be ABSENT across the skill tree.
# Word stems carry their own umlauts; a bare [äöüßÄÖÜ] class is intentionally omitted
# because, under a byte-wise locale, it false-matches multibyte punctuation (em-dash, arrows).
GERMAN_RE='revalidier|köpfig|prüf|änder|überarbeit|konsens|konvergenz'
if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
  check "P6 skill is English-only (found German tokens matching: $GERMAN_RE)" FAIL
else
  check "P6 skill is English-only (no German tokens)" PASS
fi

# P7 — command refs are namespaced: a backtick-prefixed bare '/autopilot' must be ABSENT
if grep -rqF '`/autopilot' "$SKILL_DIR"; then
  check "P7 command refs are namespaced (found bare backticked '/autopilot')" FAIL
else
  check "P7 command refs are namespaced /zensu:autopilot (no bare command ref)" PASS
fi

# P8 — bundled-path: no hardcoded ~/.claude/skills home path
if grep -rqF '~/.claude/skills' "$SKILL_DIR"; then
  check "P8 no hardcoded ~/.claude/skills home path (use \${CLAUDE_PLUGIN_ROOT})" FAIL
else
  check "P8 no hardcoded ~/.claude/skills home path (bundled-path safe)" PASS
fi

# P9 — plugin.json skills[] registration
if jq -e '.skills | index("./skills/autopilot")' "$PLUGIN_JSON" >/dev/null 2>&1; then
  check "P9 plugin.json skills[] contains './skills/autopilot'" PASS
else
  check "P9 plugin.json skills[] contains './skills/autopilot'" FAIL
fi

# P10 — version stays in sync across plugin.json + marketplace.json + README badge.
# Adding a skill does NOT bump the version; this guards against an accidental drift.
MARKET_VERSION="$(jq -r '.plugins[0].version' "$MARKETPLACE_JSON" 2>/dev/null)"
if [ "$MARKET_VERSION" = "$EXPECTED_VERSION" ]; then
  check "P10a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" PASS
else
  check "P10a marketplace.json version ($MARKET_VERSION) == plugin.json ($EXPECTED_VERSION)" FAIL
fi
EXPECTED_VERSION_RE="$(printf '%s' "$EXPECTED_VERSION" | sed 's/[.]/\\./g')"
if grep -qE "version-${EXPECTED_VERSION_RE}-green" "$README_MD"; then
  check "P10b README badge shows version-$EXPECTED_VERSION-green" PASS
else
  check "P10b README badge shows version-$EXPECTED_VERSION-green" FAIL
fi

# P11 — VCS driver wiring (Phase 4): PR-open + pre-push guard go through the driver so
# autopilot works on GitHub AND GitLab, not hard-wired to gh. Needles start with '--', so
# grep with '--' end-of-options (a bare `grep -qF "--open-pr"` treats it as a flag).
VCS_PINS=(
  "P11a Step 0 resolves the VCS driver|## Step 0 — Resolve the VCS driver"
  "P11b driver lib referenced|hooks/lib/zensu-vcs.sh"
  "P11c forge detected via --detect|--detect --repo"
  "P11d PR opened via the driver --open-pr invocation|--open-pr --provider"
  "P11e pre-push guard via --pr-state|--pr-state --provider"
  "P11f forge-agnostic (GitHub or GitLab)|GitHub or GitLab"
)
for entry in "${VCS_PINS[@]}"; do
  label="${entry%%|*}"; needle="${entry#*|}"
  if grep -qF -- "$needle" "$SKILL_MD"; then
    check "$label" PASS
  else
    check "$label" FAIL
  fi
done
# The preflight guard itself must validate the helper it executes. A broad skill-
# wide reference is insufficient because zensu-log.sh also appears later for the
# bypass ledger and previously masked this mismatch.
STEP0_SECTION="$(awk '/^## Step 0 — Resolve the VCS driver$/{inside=1} inside{print} /^## Workflow$/{exit}' "$SKILL_MD")"
if printf '%s' "$STEP0_SECTION" | grep -qF '[ -f "$ROOT/hooks/lib/zensu-vcs.sh" ]' \
  && ! printf '%s' "$STEP0_SECTION" | grep -qF '[ -f "$ROOT/hooks/lib/zensu-log.sh" ]'; then
  check "P11g Step 0 preflight validates zensu-vcs.sh, not zensu-log.sh" PASS
else
  check "P11g Step 0 preflight validates zensu-vcs.sh, not zensu-log.sh" FAIL
fi
# P11g — the raw pre-push `gh pr view <n>` guard must be GONE (routed through --pr-state)
if grep -qF -- 'gh pr view <n> --json state,mergedAt' "$SKILL_MD"; then
  check "P11h pre-push guard no longer raw 'gh pr view <n>' (driver-routed)" FAIL
else
  check "P11h pre-push guard no longer raw 'gh pr view <n>' (driver-routed)" PASS
fi

CONVENTIONS_MD="$SKILL_DIR/rules/conventions.md"
CONFIG_MD="$SKILL_DIR/rules/config.md"
CONV_BAD=""
[ -f "$CONVENTIONS_MD" ] || CONV_BAD="$CONV_BAD missing"
for LIT in 'CONVENTIONS="$(bash "$VCS" --conventions --repo "$REPO" --provider "$PROVIDER")"' \
           '1. **The config value**' \
           '2. **The repository finding**' \
           "3. **The user's own instruction**" \
           'Zensu adds no rule of its own.' \
           'The AC table is never missing' \
           '`attribution: none` adds no AI attribution line or trailer'; do
  grep -qF -- "$LIT" "$CONVENTIONS_MD" 2>/dev/null || CONV_BAD="$CONV_BAD ${LIT// /_}"
done
if [ -z "$CONV_BAD" ]; then
  check "P12a rules/conventions.md states the probe, the precedence and no rule of Zensu's own" PASS
else
  check "P12a rules/conventions.md:$CONV_BAD" FAIL
fi
PRODUCER_BAD=""
for producer in pilot pr-fix-findings cover implement; do
  grep -qF '${CLAUDE_PLUGIN_ROOT}/skills/autopilot/rules/conventions.md' "$PLUGIN_DIR/skills/$producer/SKILL.md" 2>/dev/null \
    || PRODUCER_BAD="$PRODUCER_BAD $producer"
done
grep -qF '**The repository'"'"'s conventions.** Commits and PR text follow `rules/conventions.md`.' "$SKILL_MD" \
  || PRODUCER_BAD="$PRODUCER_BAD autopilot"
if [ -z "$PRODUCER_BAD" ]; then
  check "P12b every commit and PR producer follows rules/conventions.md" PASS
else
  check "P12b producers missing the conventions contract:$PRODUCER_BAD" FAIL
fi
VCS_KEYS_BAD=""
for LIT in 'prBase: auto' 'commitStyle: auto' 'attribution: auto' 'language: auto' 'prTemplate: auto' 'worktreeOnly: true'; do
  grep -qF -- "$LIT" "$CONFIG_MD" || VCS_KEYS_BAD="$VCS_KEYS_BAD ${LIT// /_}"
done
if [ -z "$VCS_KEYS_BAD" ]; then
  check "P12c the vcs block documents the convention keys and their defaults" PASS
else
  check "P12c vcs block keys:$VCS_KEYS_BAD" FAIL
fi
CONV_FLAT="$(tr -s '[:space:]' ' ' < "$CONVENTIONS_MD")"
CONV_FIX_BAD=""
for LIT in 'A skill that sets none of them runs the probe command its own text names.' \
           'It is a consent, not a convention, so it falls outside the order of §2: add it (`git commit -s`) only when the user asked for it in this session' \
           'and the line names the AI tool, never a person.' \
           'still has it with `git ls-remote --exit-code --heads <remote> <base>`.' \
           '`worktreeOnly: true` is the default and the only value it honors; it ignores `false` and says so in its report' \
           'So do the tokens tools read back from those sections: the `AC-###` and `FR-###` ids'; do
  printf '%s' "$CONV_FLAT" | grep -qF -- "$LIT" || CONV_FIX_BAD="$CONV_FIX_BAD ${LIT:0:32}"
done
for producer in implement cover; do
  tr -s '[:space:]' ' ' < "$PLUGIN_DIR/skills/$producer/SKILL.md" \
    | grep -qF -- 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-vcs.sh" --conventions --repo "$(git rev-parse --show-toplevel)"' \
    || CONV_FIX_BAD="$CONV_FIX_BAD $producer-probe"
done
grep -qF 'worktreeOnly: false` relaxes' "$SKILL_MD" && CONV_FIX_BAD="$CONV_FIX_BAD autopilot-relaxation"
grep -qF '`<base>` is the base `rules/conventions.md` §5 resolves first.' "$SKILL_MD" || CONV_FIX_BAD="$CONV_FIX_BAD autopilot-base"
if [ -z "$CONV_FIX_BAD" ]; then
  check "P12d sign-off by consent, base check, fixed worktree guard, English tokens, probe in implement and cover" PASS
else
  check "P12d conventions contract:$CONV_FIX_BAD" FAIL
fi

echo "----"
echo "test-autopilot-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
