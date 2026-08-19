#!/bin/bash
set -u

# Structure contract for skills/gauntlet-loop.
#
# The skill was ported in from a personal ~/.claude/skills installation, so the
# checks that matter are the relocation ones: it must be registered and listed
# like every sibling skill, and the plugin-residency prose it gained in the move
# must keep saying what the runtime actually does.
#
# G4-G7 exist because the count pins elsewhere cannot see this skill by name.
# test-evidence-discipline.sh C2 globs skills/*/SKILL.md against EXPECTED_SKILLS,
# and T39 in test-chain-recover.sh compares README rows against plugin.json's
# skills[] length. A COORDINATED de-registration — drop the plugin.json entry,
# drop the README row, decrement both README numbers — keeps every one of those
# green while shipping an in-tree skill the plugin can no longer load. Only a
# per-skill registration pin catches that, which is why every sibling has one.
#
# G8-G11 pin the four load-bearing runtime claims the skill's "Inside the Zensu
# plugin" section makes. Two review rounds found FALSE claims there — that an
# active TDD chain gates a spawned builder's edits, and that a code-reviewer
# spawn consumes a review ticket — and prose that is wrong about a gate is
# worse than prose that is silent, because the model acts on it. Each check
# asserts the skill's claim against the hook that decides it, so a change to
# either side fails here rather than in a user's session. The claim half matches an
# anchored phrase rather than a bare keyword, so an INVERTED claim fails instead of
# still matching the word it inverted.
#
# Every negative check (G3, G12 — the ones that PASS by finding nothing) is
# paired with a control fixture it MUST match, so a pattern that stops matching
# fails the suite instead of degrading into an unconditional PASS. The pattern
# is borrowed from test-evidence-discipline.sh.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_DIR="$PLUGIN_DIR/skills/gauntlet-loop"
SKILL_MD="$SKILL_DIR/SKILL.md"
HARNESS_MD="$SKILL_DIR/references/harness.md"
BARS_MD="$SKILL_DIR/references/quality-bars.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
README_MD="$PLUGIN_DIR/README.md"

CAPABILITY_LIB="$PLUGIN_DIR/hooks/lib/reviewer-capability-v1.js"
PRINCIPAL_LIB="$PLUGIN_DIR/hooks/lib/claude-principal-v1.js"
EDIT_GATE="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
WITNESS="$PLUGIN_DIR/hooks/post-bash-witness.sh"
REVIEW_DELEGATE="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"

GERMAN_RE='\b(und|oder|nicht|wird|werden|dieser|diese|kann|muss|sollte|beim|einen|eine|durch|damit|wenn|dann|auch|noch|schon|jetzt|bitte|kein|keine|ohne|zwischen)\b'

TMP_DIR=""
cleanup() {
  [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
  return 0
}
trap cleanup EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-gauntlet-loop-skill: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

for f in "$SKILL_MD" "$HARNESS_MD" "$BARS_MD" "$PLUGIN_JSON" "$README_MD" \
  "$CAPABILITY_LIB" "$PRINCIPAL_LIB" "$EDIT_GATE" "$WITNESS" "$REVIEW_DELEGATE" "$HOOKS_JSON"; do
  if [ ! -f "$f" ]; then
    check "G0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
check "G0 all target files exist" PASS

if ! command -v node >/dev/null 2>&1; then
  check "G0 node available" FAIL
  finish
  exit 1
fi

# ── G1-G3: frontmatter and house conventions ────────────────────────────────
if grep -qxF 'description: >' "$SKILL_MD" && grep -qE '^ +\[Zensu\] ' "$SKILL_MD"; then
  check "G1 folded description carrying the [Zensu] prefix" PASS
else
  check "G1 frontmatter must use 'description: >' with a '[Zensu] ' prefixed body" FAIL
fi

if grep -qxF '# /zensu:gauntlet-loop' "$SKILL_MD"; then
  check "G2 H1 names the slash command" PASS
else
  check "G2 H1 must be '# /zensu:gauntlet-loop'" FAIL
fi

TMP_DIR="$(mktemp -d -t zensu-gauntlet-XXXXXX)" || TMP_DIR=""
if [ -n "$TMP_DIR" ]; then
  # The control is DERIVED from the alternation, one line per stem, and the hit
  # count must equal the stem count. A hand-written sentence would exercise only
  # the few stems it happened to use, so a stem that stopped matching would go
  # unnoticed while G3 still reported PASS.
  : > "$TMP_DIR/control.md"
  GERMAN_STEMS="$(printf '%s' "$GERMAN_RE" | sed -e 's/^\\b(//' -e 's/)\\b$//' -e 's/|/ /g')"
  GERMAN_TOTAL=0
  for stem in $GERMAN_STEMS; do
    printf 'token %s token\n' "$stem" >> "$TMP_DIR/control.md"
    GERMAN_TOTAL=$((GERMAN_TOTAL+1))
  done
  GERMAN_HITS="$(grep -ciE "$GERMAN_RE" "$TMP_DIR/control.md" || true)"
  if [ "$GERMAN_TOTAL" -gt 0 ] && [ "$GERMAN_HITS" = "$GERMAN_TOTAL" ]; then
    if grep -rqiE "$GERMAN_RE" "$SKILL_DIR"; then
      check "G3 skill directory is English only:$(grep -rliE "$GERMAN_RE" "$SKILL_DIR" | tr '\n' ' ')" FAIL
    else
      check "G3 skill directory is English only (all $GERMAN_TOTAL stems proven live on a derived control)" PASS
    fi
  else
    check "G3 German control matched $GERMAN_HITS of $GERMAN_TOTAL stems — the alternation has decayed" FAIL
  fi
else
  check "G3 could not create the control fixture directory" FAIL
fi

# ── G4-G7: registration, the checks no count pin can make ───────────────────
if node -e '
const m = require(process.argv[1]);
process.exit(Array.isArray(m.skills) && m.skills.includes("./skills/gauntlet-loop") ? 0 : 1);
' "$PLUGIN_JSON" 2>/dev/null; then
  check "G4 plugin.json skills[] registers ./skills/gauntlet-loop" PASS
else
  check "G4 plugin.json skills[] must register ./skills/gauntlet-loop" FAIL
fi

if grep -qF '| `/zensu:gauntlet-loop` |' "$README_MD"; then
  check "G5 README skills table carries a /zensu:gauntlet-loop row" PASS
else
  check "G5 README skills table must carry a /zensu:gauntlet-loop row" FAIL
fi

LINK_MISS=""
for rel in references/harness.md references/quality-bars.md; do
  grep -qF "($rel)" "$SKILL_MD" || LINK_MISS="$LINK_MISS $rel(unlinked)"
  [ -f "$SKILL_DIR/$rel" ] || LINK_MISS="$LINK_MISS $rel(missing)"
done
if [ -z "$LINK_MISS" ]; then
  check "G6 both reference links are present and resolve" PASS
else
  check "G6 reference link problems:$LINK_MISS" FAIL
fi

if grep -qF '](../SKILL.md)' "$HARNESS_MD" && [ -f "$SKILL_DIR/SKILL.md" ]; then
  check "G7 harness.md back-pointer to ../SKILL.md resolves" PASS
else
  check "G7 harness.md must point back at ../SKILL.md for the normative statement" FAIL
fi

# ── G8-G11: the runtime claims the residency section makes ──────────────────
# Each pairs the skill's claim with the hook that decides it. The claim side is an
# anchored phrase, not a bare keyword, so an inverted claim fails rather than still
# matching the word it inverted. Keep every anchor short enough to sit on ONE wrapped
# markdown line — grep is line-based, so a phrase that spans a wrap never matches.

if grep -qF "host-profile-v1 cannot invoke command-execution tools" "$CAPABILITY_LIB" \
  && grep -qF "'Bash'" "$CAPABILITY_LIB" \
  && grep -qF 'no builder and no critic in this loop can run' "$SKILL_MD" \
  && grep -qF 'command-execution tool' "$SKILL_MD"; then
  check "G8 skill states the command-tool denial the capability gate enforces" PASS
else
  check "G8 capability gate denies command tools to host-profile-v1 — the skill must say so" FAIL
fi

if grep -qF 'zensu_hook_is_main_principal "$PAYLOAD" PreToolUse' "$EDIT_GATE" \
  && grep -qF 'zensu_hook_is_main_principal "$INPUT" PostToolUse' "$WITNESS" \
  && grep -qF 'binds the LEAD ONLY' "$SKILL_MD" \
  && grep -qF 'and no spawned' "$SKILL_MD"; then
  check "G9 skill states the main-v1-only scope of the edit gate and the witness" PASS
else
  check "G9 edit gate and witness are main-v1 only — the skill must say so" FAIL
fi

if grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$REVIEW_DELEGATE" \
  && grep -qF 'is a no-op, not a stolen ticket' "$SKILL_MD"; then
  check "G10 skill states that an out-of-protocol code-reviewer spawn is a no-op" PASS
else
  check "G10 the review delegate keys on its header protocol — the skill must say so" FAIL
fi

if grep -qF '"ExitPlanMode"' "$HOOKS_JSON" \
  && grep -qF 'Charter approval is intercepted' "$SKILL_MD" \
  && grep -qF 'plan-approved-delegate.sh' "$SKILL_MD"; then
  check "G11 skill names the ExitPlanMode interception of charter approval" PASS
else
  check "G11 plan approval is intercepted on ExitPlanMode — the skill must say so" FAIL
fi

# ── G12: no gate-disable prefix is ever taught ──────────────────────────────
ESCAPE_RE='ZENSU_(TDD_GATE|BASH_WRITE_GATE|TEST_WITNESS)=off'
if [ -n "$TMP_DIR" ]; then
  printf '%s\n' 'run it with ZENSU_TDD_GATE=off to get past the gate' > "$TMP_DIR/escape.md"
  if grep -rqE "$ESCAPE_RE" "$TMP_DIR/escape.md"; then
    if grep -rqE "$ESCAPE_RE" "$SKILL_DIR"; then
      check "G12 skill must never ship a gate-disable prefix:$(grep -rlE "$ESCAPE_RE" "$SKILL_DIR" | tr '\n' ' ')" FAIL
    else
      check "G12 no gate-disable prefix anywhere in the skill (pattern proven live)" PASS
    fi
  else
    check "G12 escape control fixture no longer matches its own pattern" FAIL
  fi
else
  check "G12 could not create the control fixture directory" FAIL
fi

# ── G13: every hook path the skill names still resolves ─────────────────────
HOOK_MISS=""; HOOK_N=0
# `json` is listed FIRST so POSIX leftmost-longest consumes `hooks.json` whole;
# without it the alternation matches `hooks.js` inside it and invents a missing file.
for h in $(grep -oE '(hooks/(lib/)?)?[a-z0-9-]+\.(json|sh|js)' "$SKILL_MD" \
  | grep -v '\.json$' | sort -u); do
  case "$h" in
    hooks/*) [ -f "$PLUGIN_DIR/$h" ] || HOOK_MISS="$HOOK_MISS $h" ;;
    *.sh)    [ -f "$PLUGIN_DIR/hooks/$h" ] || HOOK_MISS="$HOOK_MISS $h" ;;
    *.js)    { [ -f "$PLUGIN_DIR/hooks/lib/$h" ] || [ -f "$PLUGIN_DIR/hooks/$h" ]; } \
               || HOOK_MISS="$HOOK_MISS $h" ;;
  esac
  HOOK_N=$((HOOK_N+1))
done
# The set is derived from the file under test, so an emptied section would leave
# HOOK_MISS empty and pass vacuously. The floor is what makes the check a bite.
if [ "$HOOK_N" -lt 5 ]; then
  check "G13 only $HOOK_N hook/lib names found in the skill — expected at least 5; the residency section names them" FAIL
elif [ -z "$HOOK_MISS" ]; then
  check "G13 all $HOOK_N hook and lib names in the skill resolve on disk" PASS
else
  check "G13 skill names hook paths that do not exist:$HOOK_MISS" FAIL
fi

# ── G14: registered in the CI structure manifest ────────────────────────────
CLASSIFICATION="$(node -e '
const m = require(process.argv[1]);
const name = "test-gauntlet-loop-skill.sh";
if ((m.ciStructureTests || []).includes(name)) { process.stdout.write("ci"); }
else if ((m.localStructureTests || []).includes(name)) { process.stdout.write("local"); }
else { process.stdout.write("none"); }
' "$PLUGIN_DIR/tests/profiles/promptfoo-local-only.v1.json" 2>/dev/null)"
case "$CLASSIFICATION" in
  ci)    check "G14 classified as a CI-blocking structure suite" PASS ;;
  local) check "G14 classified Promptfoo-local-only — that silently drops it from --ci" FAIL ;;
  *)     check "G14 unclassified in promptfoo-local-only.v1.json — run-all refuses the whole run" FAIL ;;
esac

finish
