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
# G8-G11 and G15 pin six load-bearing runtime claims the skill's "Inside the Zensu
# plugin" section makes. Two review rounds found FALSE claims there — that an
# active TDD chain gates a spawned builder's edits, and that a code-reviewer
# spawn consumes a review ticket — and prose that is wrong about a gate is
# worse than prose that is silent, because the model acts on it. Each check
# asserts the skill's claim against the hook that decides it, so a change to
# either side fails here rather than in a user's session. The claim half matches an
# anchored phrase rather than a bare keyword, so an INVERTED claim fails instead of
# still matching the word it inverted.
#
# Negative checks come in two shapes and carry DIFFERENT obligations:
#   - REGEX-alternation negatives (G3, G12) need an INDEPENDENT control corpus plus
#     an arity or drift cross-check. A control derived from the pattern itself is a
#     closed loop whose FAIL arm cannot fire; both of these had that defect and both
#     were rebuilt.
#   - LITERAL-substring negatives (G16, G17, G18, G19) have no alternation to decay,
#     so they need no corpus — but each is an EXACT-SENTENCE tripwire, not a proof
#     that no contradiction exists. A near-miss rewording restores the refuted
#     instruction silently. Pair every one with a positive conjunct asserting the
#     replacement text, and read the check labels as "this one wording cannot return",
#     never as "the file is free of contradictions".

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
  # The control corpus is an INDEPENDENT literal list, NOT a split of GERMAN_RE.
  # Deriving both the corpus and the expected count from the same string makes the
  # check tautological: lose a `|` and two stems merge into one line that still
  # matches itself, so the count falls on both sides and G3 reports PASS while the
  # pattern detects neither word. tests/structure/test-session-trail-skill.sh states
  # this rule with the same rationale and carries the same arity cross-check; the
  # first version of G3 had the defect that rule exists to prevent.
  : > "$TMP_DIR/control.md"
  GERMAN_STEMS='und oder nicht wird werden dieser diese kann muss sollte beim einen eine durch damit wenn dann auch noch schon jetzt bitte kein keine ohne zwischen'
  GERMAN_TOTAL=0
  for stem in $GERMAN_STEMS; do
    printf 'token %s token\n' "$stem" >> "$TMP_DIR/control.md"
    GERMAN_TOTAL=$((GERMAN_TOTAL+1))
  done
  GERMAN_HITS="$(grep -ciE "$GERMAN_RE" "$TMP_DIR/control.md" || true)"
  # Arity: the alternation and the independent list must describe the same number of
  # stems. This is what a lost `|` breaks, and nothing else in the check can see it.
  GERMAN_ARITY="$(printf '%s' "$GERMAN_RE" | sed -e 's/^\\b(//' -e 's/)\\b$//' | tr '|' '\n' | grep -c .)"
  if [ "$GERMAN_ARITY" != "$GERMAN_TOTAL" ]; then
    check "G3 alternation describes $GERMAN_ARITY stems but the control list carries $GERMAN_TOTAL — they have drifted" FAIL
  elif [ "$GERMAN_TOTAL" -gt 0 ] && [ "$GERMAN_HITS" = "$GERMAN_TOTAL" ]; then
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
# Each pairs the skill's claim with the hook that decides it, and the claim side
# carries the decision-bearing token rather than a connective — an inverted claim
# must fail, not still match the word it inverted.
#
# The skill side matches against SKILL_FLAT, the file with newlines collapsed to
# single spaces, NOT against the file. grep is line-based and this prose is hard
# wrapped, so a line-scoped anchor is coupled to where a paragraph happens to break:
# reflowing a sentence silently breaks the pin, and an anchor long enough to carry a
# real claim usually spans a wrap and can never match at all. Both failure modes were
# observed while fixing this file. Flattening removes the coupling, so anchors can be
# chosen for what they assert instead of for what fits on a line.
SKILL_FLAT="$(tr '\n' ' ' < "$SKILL_MD" | tr -s ' ')"
HARNESS_FLAT="$(tr '\n' ' ' < "$HARNESS_MD" | tr -s ' ')"
flat_has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# G8 asserts the WHOLE enumeration on both sides. Pinning only 'Bash' let the module
# be narrowed to a single name while the skill kept promising six.
COMMAND_TOOL_NAMES='Bash shell exec exec_command terminal command'
G8_MISS=""
grep -qF "host-profile-v1 cannot invoke command-execution tools" "$CAPABILITY_LIB" \
  || G8_MISS="$G8_MISS deny-reason"
# Scope the module assertion to the COMMAND_TOOLS declaration. A whole-file grep
# stays green when five names are parked in an unused constant while the denial
# itself narrows to one.
COMMAND_TOOLS_DECL="$(grep -F 'const COMMAND_TOOLS' "$CAPABILITY_LIB")"
for t in $COMMAND_TOOL_NAMES; do
  case "$COMMAND_TOOLS_DECL" in *"'$t'"*) ;; *) G8_MISS="$G8_MISS module:$t" ;; esac
  flat_has "\`$t\`" "$SKILL_FLAT" || G8_MISS="$G8_MISS skill:$t"
done
flat_has 'no builder and no critic in this loop can run' "$SKILL_FLAT" \
  || G8_MISS="$G8_MISS skill-claim"
flat_has 'command-execution tool' "$SKILL_FLAT" || G8_MISS="$G8_MISS skill-category"
if [ -z "$G8_MISS" ]; then
  check "G8 skill states the command-tool denial the capability gate enforces" PASS
else
  check "G8 capability gate denies command tools to host-profile-v1 —$G8_MISS" FAIL
fi

# G9's claim payload is WHICH principals the gate binds. 'and no spawned' carried
# none of it: inverting the sentence to '... is always main-v1' still matched.
G9_MISS=""
grep -qF 'zensu_hook_is_main_principal "$PAYLOAD" PreToolUse' "$EDIT_GATE" \
  || G9_MISS="$G9_MISS edit-gate-guard"
grep -qF 'zensu_hook_is_main_principal "$INPUT" PostToolUse' "$WITNESS" \
  || G9_MISS="$G9_MISS witness-guard"
flat_has 'binds the LEAD ONLY' "$SKILL_FLAT" || G9_MISS="$G9_MISS skill-scope"
flat_has 'no spawned agent is ever `main-v1`' "$SKILL_FLAT" || G9_MISS="$G9_MISS skill-principal"
flat_has 'is NOT phase-gated' "$SKILL_FLAT" || G9_MISS="$G9_MISS skill-consequence"
if [ -z "$G9_MISS" ]; then
  check "G9 skill states the main-v1-only scope of the edit gate and the witness" PASS
else
  check "G9 edit gate and witness are main-v1 only —$G9_MISS" FAIL
fi

if grep -qF 'PRE-MERGED FINDINGS (fan-out)' "$REVIEW_DELEGATE" \
  && flat_has 'is a no-op, not a stolen ticket' "$SKILL_FLAT"; then
  check "G10 skill states that an out-of-protocol code-reviewer spawn is a no-op" PASS
else
  check "G10 the review delegate keys on its header protocol — the skill must say so" FAIL
fi

# G11 asserted only that the literal "ExitPlanMode" occurred somewhere in the
# manifest. Unregistering the delegate, or moving it to another event, left that
# true. Parse the manifest and assert the REGISTRATION, the way G4 does.
G11_REGISTERED="$(node -e '
const h = require(process.argv[1]);
const post = (h.hooks && h.hooks.PostToolUse) || [];
const entry = post.find((e) => e.matcher === "ExitPlanMode");
const hit = entry && (entry.hooks || []).some(
  (x) => typeof x.command === "string" && x.command.includes("plan-approved-delegate.sh"));
process.stdout.write(hit ? "yes" : "no");
' "$HOOKS_JSON" 2>/dev/null)"
G11_MISS=""
[ "$G11_REGISTERED" = yes ] || G11_MISS="$G11_MISS manifest-registration"
flat_has 'Charter approval is intercepted' "$SKILL_FLAT" || G11_MISS="$G11_MISS skill-claim"
flat_has 'plan-approved-delegate.sh' "$SKILL_FLAT" || G11_MISS="$G11_MISS skill-names-hook"
if [ -z "$G11_MISS" ]; then
  check "G11 skill names the ExitPlanMode interception of charter approval" PASS
else
  check "G11 plan approval is intercepted on ExitPlanMode —$G11_MISS" FAIL
fi

# ── G12: no gate-disable prefix is ever taught ──────────────────────────────
# The stem list is the source of truth and the alternation is BUILT from it, so the
# two cannot drift — the reverse of G3, which decomposes its regex with sed and is
# therefore coupled to that regex's shape. Enumerated from the tree, not from memory:
#   grep -rhoE 'ZENSU_[A-Z_]+=off' docs/ hooks/ CLAUDE.md | sort -u
# The first version covered three of these, so a skill teaching ZENSU_CHAIN=off —
# the most tempting one for a long unattended loop, since it silences the chain
# enforcer — passed with the label "pattern proven live".
ESCAPE_STEMS='TDD_GATE BASH_WRITE_GATE TEST_WITNESS CHAIN MCP_GATE SECRET_SCAN EDIT_LANDING_GATE AUTOPILOT'
# Quote tolerance: the gates decide the escape AFTER shell quote removal
# (pre-edit-tdd-reminder.sh compares "${ZENSU_TDD_GATE:-}" = "off"), so prose
# teaching ZENSU_CHAIN='off' disables the gate at runtime. A bare =off pattern
# would not see it.
ESCAPE_RE="ZENSU_($(printf '%s|' $ESCAPE_STEMS | sed 's/|$//'))=[\"']?off"
# DRIFT CHECK against the tree, not against the list itself. Building the control
# from ESCAPE_STEMS and the pattern from ESCAPE_STEMS is a closed loop: hits can
# only differ from total on an ERE syntax break, so the FAIL arm is unreachable and
# the real failure — a stem MISSING from the list, which is how ZENSU_CHAIN=off
# slipped the first version — stays invisible. Re-derive the set from the sources
# the comment used to only name.
ESCAPE_TREE="$(grep -rhoE 'ZENSU_[A-Z_]+=off' "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/docs" "$PLUGIN_DIR/CLAUDE.md" 2>/dev/null \
  | sed -e 's/^ZENSU_//' -e 's/=off$//' | sort -u | tr '\n' ' ')"
ESCAPE_LIST_SORTED="$(printf '%s\n' $ESCAPE_STEMS | sort -u | tr '\n' ' ')"
if [ -n "$ESCAPE_TREE" ] && [ "$ESCAPE_TREE" != "$ESCAPE_LIST_SORTED" ]; then
  check "G12 gate-disable stems have drifted — tree has [$ESCAPE_TREE], list has [$ESCAPE_LIST_SORTED]" FAIL
fi
if [ -n "$TMP_DIR" ]; then
  # One control line per stem, and the hit count must equal the stem count. A single
  # hand-written line proved only the branch it happened to use, so a decayed branch
  # kept reporting PASS while no longer checking anything.
  : > "$TMP_DIR/escape.md"
  ESCAPE_TOTAL=0
  for stem in $ESCAPE_STEMS; do
    printf 'run it with ZENSU_%s=off to get past the gate\n' "$stem" >> "$TMP_DIR/escape.md"
    ESCAPE_TOTAL=$((ESCAPE_TOTAL+1))
  done
  ESCAPE_HITS="$(grep -cE "$ESCAPE_RE" "$TMP_DIR/escape.md" || true)"
  if [ "$ESCAPE_TOTAL" -gt 0 ] && [ "$ESCAPE_HITS" = "$ESCAPE_TOTAL" ]; then
    if grep -rqE "$ESCAPE_RE" "$SKILL_DIR"; then
      check "G12 skill must never ship a gate-disable prefix:$(grep -rlE "$ESCAPE_RE" "$SKILL_DIR" | tr '\n' ' ')" FAIL
    else
      check "G12 no gate-disable prefix anywhere in the skill (all $ESCAPE_TOTAL stems proven live on a derived control)" PASS
    fi
  else
    check "G12 escape control matched $ESCAPE_HITS of $ESCAPE_TOTAL stems — the alternation has decayed" FAIL
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
    test-*.sh) [ -f "$PLUGIN_DIR/tests/structure/$h" ] || HOOK_MISS="$HOOK_MISS $h" ;;
    *.sh)    [ -f "$PLUGIN_DIR/hooks/$h" ] || HOOK_MISS="$HOOK_MISS $h" ;;
    *.js)    { [ -f "$PLUGIN_DIR/hooks/lib/$h" ] || [ -f "$PLUGIN_DIR/hooks/$h" ]; } \
               || HOOK_MISS="$HOOK_MISS $h" ;;
  esac
  HOOK_N=$((HOOK_N+1))
done
# The set is derived from the file under test, so an emptied section would leave
# HOOK_MISS empty and pass vacuously. A numeric floor is the wrong guard for that: it
# was set to 5 against an actual 6, so any ONE named hook could be dropped with the
# suite green, and every prose addition makes the slack larger. Assert the four
# claim-bearing paths BY NAME instead — these are the files G8, G9 and G11 pair their
# claims against, so losing one silently unmoors a claim from its enforcement.
REQUIRED_HOOKS='hooks/lib/reviewer-capability-v1.js hooks/pre-edit-tdd-reminder.sh hooks/post-bash-witness.sh plan-approved-delegate.sh'
HOOK_UNNAMED=""
for req in $REQUIRED_HOOKS; do
  flat_has "$req" "$SKILL_FLAT" || HOOK_UNNAMED="$HOOK_UNNAMED $req"
done
if [ -n "$HOOK_UNNAMED" ]; then
  check "G13 the residency section no longer names:$HOOK_UNNAMED" FAIL
elif [ -z "$HOOK_MISS" ]; then
  check "G13 all $HOOK_N hook and lib names in the skill resolve on disk" PASS
else
  check "G13 skill names hook paths that do not exist:$HOOK_MISS" FAIL
fi

# ── G14: registered in the CI structure manifest ────────────────────────────
# Local tripwire, NOT a CI gate — say so rather than implying enforcement this
# check cannot deliver. run-all.sh compares the manifest against the directory
# listing and refuses to execute at all when they disagree, so the unclassified
# arm below can never print in CI: the run aborts before this suite starts. The
# local arm cannot print under --ci either, because a Promptfoo-local suite is
# skipped there. Both arms are reachable from a local full run or a direct
# invocation of this file, which is where they earn their keep.
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

# ── G15: the containment bullet states the bound the gate actually keeps ─────
# G8 pairs the denial with the module. This pairs the RESIDUE with it: the gate's
# second tool-name branch matches only mcp__*zensu*, so a code-executing MCP tool
# from any other server is not denied, and classifyPreToolPayload returns main-v1
# for a payload carrying neither agent_type nor agent_id. Both are load-bearing
# for a reader deciding what a critic can reach, and neither is implied by the
# six-name list. The module probe below is a line-scoped grep over JS source; the
# skill-side anchors go through flat_has/SKILL_FLAT and are wrap-independent.
MCP_SCOPE_RE='mcp__\.\*zensu'
G15_MISS=""
grep -qE "$MCP_SCOPE_RE" "$CAPABILITY_LIB" || G15_MISS="$G15_MISS module-mcp-scope"
# The agent_type premise is decided HERE, not in the capability module. Without this
# conjunct PRINCIPAL_LIB was existence-gated by G0 and asserted against by nothing.
grep -qF 'if (!hasAgentId && !hasAgentType) return PRINCIPALS.MAIN;' "$PRINCIPAL_LIB" \
  || G15_MISS="$G15_MISS module-main-fallthrough"
flat_has 'from a non-Zensu server is not denied' "$SKILL_FLAT" || G15_MISS="$G15_MISS skill-mcp-residue"
# The anchor spans the CONDITION and the CONSEQUENCE. The first version matched
# only the hinge between them, so inverting the premise left it green — the exact
# defect this file exists to prevent, committed inside the fix for it.
flat_has 'neither `agent_type` nor `agent_id` classifies as `main-v1` and is unrestricted by this gate' "$SKILL_FLAT" \
  || G15_MISS="$G15_MISS skill-agent-type-premise"
flat_has 'a six-name DENYLIST, not an' "$SKILL_FLAT" || G15_MISS="$G15_MISS skill-denylist-shape"
if [ -z "$G15_MISS" ]; then
  check "G15 skill states the residue the six-name denylist does not cover" PASS
else
  check "G15 containment claim is unbounded —$G15_MISS" FAIL
fi

# ── G16: the review-chain rationale names a reason that discriminates ────────
# The first version said the chain is not reused "because its critics must run the
# artifact". G8 establishes that NO subagent in this plugin can run anything, so
# that reason applied equally to the Explore critics this skill mandates instead —
# it chose between two options on a property both share. The reason that actually
# discriminates is the packet protocol, which post-review-tdd-delegate.sh enforces.
G16_MISS=""
# The claim is the PACKET protocol, which lives in the agent definitions — not in
# post-review-tdd-delegate.sh, whose literal is G10's consume-mode first-line check.
# Pairing G16 with that literal duplicated G10 and evidenced a different mechanism.
for agent_md in code-reviewer review-aspect review-judge; do
  grep -qF 'REVIEW PACKET v1 (required)' "$PLUGIN_DIR/agents/$agent_md.md" \
    || G16_MISS="$G16_MISS agent-packet-rule:$agent_md"
done
flat_has 'cannot be pointed at an arbitrary artifact' "$SKILL_FLAT" || G16_MISS="$G16_MISS skill-discriminator"
flat_has 'because its critics must run the artifact' "$SKILL_FLAT" && G16_MISS="$G16_MISS skill-keeps-refuted-reason"
# harness.md spelled the same non-discriminator differently — "they hold no shell,
# so they cannot execute an inspection recipe" — so matching the SKILL.md literal
# here would be an inert conjunct that can never fire. Match what that file says.
flat_has 'so they cannot execute an inspection' "$HARNESS_FLAT" && G16_MISS="$G16_MISS harness-keeps-refuted-reason"
if [ -z "$G16_MISS" ]; then
  check "G16 the review-chain rationale names the protocol; the one refuted wording cannot return" PASS
else
  check "G16 review-chain rationale does not discriminate —$G16_MISS" FAIL
fi

# ── G17: external publishing is approved per evidence class, not once ────────
# SKILL.md puts external writes under "Prohibited without new approval". The
# harness file gated Artifact on approval "at charter time" and then republished
# every round with screenshots, console output and network-derived evidence that
# did not exist when approval was given — the reference resolving the same question
# the other way, in the file the model is reading at the moment it publishes.
G17_MISS=""
flat_has 'Prohibited without new approval:' "$SKILL_FLAT" || G17_MISS="$G17_MISS skill-authority-bound"
flat_has 'needs a fresh confirmation naming that class' "$HARNESS_FLAT" || G17_MISS="$G17_MISS harness-per-class-rule"
flat_has 'approval at charter time' "$HARNESS_FLAT" && G17_MISS="$G17_MISS harness-keeps-standing-approval"
if [ -z "$G17_MISS" ]; then
  check "G17 per-class publish approval is stated; the one refuted wording cannot return" PASS
else
  check "G17 external publishing runs on a standing approval —$G17_MISS" FAIL
fi

# ── G18: redaction is stated where the write happens, and covers every path ──
# The rule lived only in references/harness.md, scoped to progress writes, while
# the packet channel was instructed to carry RAW console/log/network output — and
# those verdicts travel on into resolutions, write-capable builder spawns and the
# ledger. Same bytes, redacted on one path and copied raw on three. This is the one
# control between a session bearer token and a published page, so it belongs at the
# step that writes, in the normative file, not behind a cross-reference.
G18_MISS=""
flat_has 'Redact before every outbound write' "$SKILL_FLAT" || G18_MISS="$G18_MISS skill-inline-rule"
flat_has 'never raw request or response headers' "$SKILL_FLAT" || G18_MISS="$G18_MISS skill-network-clause"
flat_has 'packet, ledger, resolution attachment' "$SKILL_FLAT" || G18_MISS="$G18_MISS skill-covers-every-path"
flat_has 'put the redacted output in the packet' "$HARNESS_FLAT" || G18_MISS="$G18_MISS harness-packet-channel"
# NEGATIVE half. The first version of this check was purely positive, so it saw the
# new rule arrive and never noticed that SIX sites kept ordering RAW capture bytes
# down the very paths the rule names — four of them reached BEFORE it in a
# top-to-bottom read. A redaction rule that competes with a raw instruction the
# model hits first is not a rule.
for raw in 'raw output into the packet' 'raw hard-gate evidence' 'raw critic verdicts' 'raw gate output'; do
  flat_has "$raw" "$SKILL_FLAT" && G18_MISS="$G18_MISS skill-raw:${raw// /-}"
  flat_has "$raw" "$HARNESS_FLAT" && G18_MISS="$G18_MISS harness-raw:${raw// /-}"
done
# Round-2 additions. Each pairs a claim the review found overstated with the
# corrected wording, so the overstatement cannot come back.
flat_has 'including outside the project root' "$SKILL_FLAT" || G18_MISS="$G18_MISS skill-write-reach"
flat_has 'They may still read and write project files.' "$SKILL_FLAT" && G18_MISS="$G18_MISS skill-write-reach-understated"
flat_has 'unrestricted by this gate' "$SKILL_FLAT" || G18_MISS="$G18_MISS skill-gate-scope"
flat_has 'only other tool-name branch matches' "$SKILL_FLAT" && G18_MISS="$G18_MISS skill-branch-overclaim"
flat_has 'or any excerpt of product source or a diff' "$HARNESS_FLAT" || G18_MISS="$G18_MISS harness-publish-classes"
flat_has 'Redact before every progress write.' "$HARNESS_FLAT" && G18_MISS="$G18_MISS harness-progress-scoped-heading"
# The self-declaration carries NO count on purpose. It read "four anchors" while the
# three checks anchored eleven sentences in that file, and nothing here can check a
# figure — so a count in prose is a claim that only ever drifts further.
flat_has 'G16, G17 and G18 anchor exact sentences in THIS file' "$HARNESS_FLAT" || G18_MISS="$G18_MISS harness-self-declaration"
flat_has 'pin four anchors in THIS file' "$HARNESS_FLAT" && G18_MISS="$G18_MISS harness-stale-anchor-count"
if [ -z "$G18_MISS" ]; then
  check "G18 redaction is unconditional and stated at the writing step" PASS
else
  check "G18 redaction does not cover every outbound path —$G18_MISS" FAIL
fi

# ── G19: four instructions that pulled against each other ───────────────────
# A prompt carrier with two rules that conflict is the equivalent of dead code
# that silently changes behavior, and in each of these four the wrong one is
# reached FIRST by a model reading top to bottom.
#   (a) step 2 told critics to reproduce the capture, which the first bullet says
#       they cannot do;
#   (b) the charter step prescribed plan mode, which the residency section says is
#       intercepted;
#   (c) the hard-gate veto offered BAR_MET as a DECISION value, but the resolution
#       vocabulary is CHANGE|NO_CHANGE|RETEST|BLOCKED and no downstream arm handles
#       it — a model that emits it stalls;
#   (d) the charter amendment said "the charter", which includes scope and budget,
#       so an unattended run could widen its own authority.
G19_MISS=""
flat_has 'so every critic reproduces the same' "$SKILL_FLAT" && G19_MISS="$G19_MISS a-critic-reproduces"
flat_has 'The lead runs it every round' "$SKILL_FLAT" || G19_MISS="$G19_MISS a-lead-runs-it"
flat_has 'Use plan mode' "$SKILL_FLAT" && G19_MISS="$G19_MISS b-prescribes-plan-mode"
flat_has 'Approve it with `AskUserQuestion`' "$SKILL_FLAT" || G19_MISS="$G19_MISS b-single-rule"
flat_has '`NO_CHANGE` or `BAR_MET`' "$SKILL_FLAT" && G19_MISS="$G19_MISS c-bar-met-as-decision"
flat_has 'never a `DECISION:` value' "$SKILL_FLAT" || G19_MISS="$G19_MISS c-vocabularies-separated"
# Pin the DECLARATION, not only the prose about it, and pin it WHOLE-LINE. A
# substring match is satisfied by an EXTENDED declaration: appending `| BAR_MET`
# leaves 'CHANGE | NO_CHANGE | RETEST | BLOCKED' present. This is the one anchor in
# the file that must stay line-scoped, because its property is the absence of a
# fifth value, not the presence of four.
grep -qxF 'DECISION: CHANGE | NO_CHANGE | RETEST | BLOCKED' "$SKILL_MD" || G19_MISS="$G19_MISS c-declaration"
flat_has 'at least one ceiling you can evaluate' "$SKILL_FLAT" || G19_MISS="$G19_MISS d-countable-ceiling"
flat_has 'amend only the bar or the measurement' "$SKILL_FLAT" || G19_MISS="$G19_MISS d-amendment-scoped"
if [ -z "$G19_MISS" ]; then
  check "G19 four instruction pairs resolved; each refuted wording cannot return verbatim" PASS
else
  check "G19 conflicting instructions remain —$G19_MISS" FAIL
fi

# ── G20: quality-bars.md carries content, not just a filename ───────────────
# G0 is an existence check, G6 checks the link, and G3/G12 are negative scans that
# PASS by finding nothing — so a 0-byte references/quality-bars.md kept every check
# in this file green while SKILL.md consumed its vocabulary by name. Pin the terms
# the skill actually depends on rather than a byte count, so the file can be
# rewritten freely but cannot be emptied out from under its consumer.
BARS_FLAT="$(tr '\n' ' ' < "$BARS_MD" | tr -s ' ')"
G20_MISS=""
for lit in 'Hard gates' 'Outcome gate' 'Reference bar' 'Holdouts' '`hard`' '`directional`'; do
  flat_has "$lit" "$BARS_FLAT" || G20_MISS="$G20_MISS ${lit}"
done
flat_has 'Separate hard gates from directional' "$SKILL_FLAT" || G20_MISS="$G20_MISS skill-consumer"
# README cites these two headings by name; pin them so a rename cannot leave that
# citation stale with the suite green.
grep -qxF '## Method sources' "$BARS_MD" || G20_MISS="$G20_MISS bars-method-sources-heading"
grep -qxF '## Provenance' "$SKILL_MD" || G20_MISS="$G20_MISS skill-provenance-heading"
if [ -z "$G20_MISS" ]; then
  check "G20 quality-bars.md defines the vocabulary SKILL.md consumes" PASS
else
  check "G20 quality-bars.md is missing vocabulary its consumer relies on —$G20_MISS" FAIL
fi

finish
