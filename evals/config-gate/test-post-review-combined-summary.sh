#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/post-review-tdd-delegate.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -x "$SCRIPT" ]; then
  check "hook script exists and is executable" FAIL
  echo "----"
  echo "test-post-review-combined-summary: $PASS PASS / $FAIL FAIL"
  exit 1
fi

# Syntax check first, mirroring D1 in test-plan-approved-delegate.sh: without it
# a syntax fault in the hook surfaces as twenty unrelated content failures below
# instead of as the one-line cause.
if bash -n "$SCRIPT" 2>/dev/null; then
  check "hook parses (bash -n)" PASS
else
  check "hook parses (bash -n)" FAIL
fi

TMP_DIR="$(mktemp -d)"
TMP_CFG="$TMP_DIR/config.json"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
export CLAUDE_PROJECT_DIR="$TMP_DIR/project"
export STATE_DIR="$TMP_DIR/state"
mkdir -p "$CLAUDE_PROJECT_DIR" "$STATE_DIR"
export ZENSU_CONFIG="$TMP_CFG"

arm_review() {
  # shellcheck disable=SC1090
  source "$BASELINE" "$1"
  bash "$LOG" --tdd-begin --session "$1" >/dev/null
  bash "$LOG" --tdd-complete --session "$1" >/dev/null
}

review_payload() {
  local session_id="$1" ticket
  ticket="$(bash "$LOG" --review-ticket --session "$session_id")" || return 1
  node -e '
    const sessionId = process.argv[1];
    const ticket = process.argv[2];
    process.stdout.write(JSON.stringify({
      hook_event_name: "PostToolUse",
      tool_name: "Agent",
      tool_input: {
        subagent_type: "zensu:code-reviewer",
        prompt: `PRE-MERGED FINDINGS (fan-out)\nREVIEW-TICKET: ${ticket}\nfixture`
      },
      session_id: sessionId
    }));
  ' "$session_id" "$ticket"
}

prime_review_rounds() {
  local session_id="$1" rounds="$2" payload _round
  _round=0
  while [ "$_round" -lt "$rounds" ]; do
    payload="$(review_payload "$session_id")" || return 1
    printf '%s' "$payload" | "$SCRIPT" >/dev/null 2>/dev/null || return 1
    _round=$((_round + 1))
  done
}

# selfReview:false routes the CHAIN-END SUMMARY inline through this hook
# (TAIL_DIRECTIVE). With selfReview enabled (the 0.5.0 default) the summary is
# instead rendered by the terminal /zensu:self-review stage, so the hook emits
# only the handoff directive — these cases assert the hook's own inline summary.
cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "selfReview": false}}
EOF

arm_review sess-summary-a-001
STDIN_A="$(review_payload sess-summary-a-001)"
OUT="$(printf '%s' "$STDIN_A" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case A/B legacy + flag on (default): output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "case A/B legacy + flag on (default): output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

case "$OUT" in
  *"## Problem"*)
    check "case A/B legacy + flag on: output contains '## Problem' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Problem' heading" FAIL ;;
esac

case "$OUT" in
  *"## What I built"*)
    check "case A/B legacy + flag on: output contains '## What I built' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## What I built' heading" FAIL ;;
esac

case "$OUT" in
  *"## How I built it"*)
    check "case A/B legacy + flag on: output contains '## How I built it' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## How I built it' heading" FAIL ;;
esac

case "$OUT" in
  *"## Open"*)
    check "case A/B legacy + flag on: output contains '## Open' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## Open' heading" FAIL ;;
esac

case "$OUT" in
  *"## TL;DR"*)
    check "case A/B legacy + flag on: output contains '## TL;DR' heading" PASS ;;
  *)
    check "case A/B legacy + flag on: output contains '## TL;DR' heading" FAIL ;;
esac

HOOK_SEQ="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s).hookSpecificOutput.additionalContext;process.stdout.write([...c.matchAll(/^## .*/gm)].map(m=>m[0].trim()).join("|"));})')"
EXPECTED_HOOK_SEQ="## Problem|## What I built|## How I built it|## Open|## TL;DR"
[ "$HOOK_SEQ" = "$EXPECTED_HOOK_SEQ" ] && check "case A/B legacy + flag on: hook emits exact ordered heading sequence" PASS || check "case A/B legacy + flag on: hook ordered sequence (got: $HOOK_SEQ)" FAIL

LAST_HOOK_HEADING="${HOOK_SEQ##*|}"
[ "$LAST_HOOK_HEADING" = "## TL;DR" ] && check "case A/B legacy + flag on: '## TL;DR' is the LAST section heading" PASS || check "case A/B legacy + flag on: '## TL;DR' last heading (got: $LAST_HOOK_HEADING)" FAIL

case "$OUT" in
  *"## Self-Review Summary"*)
    check "case A/B legacy + flag on: hook must NOT emit '## Self-Review Summary' (skill-only)" FAIL ;;
  *)
    check "case A/B legacy + flag on: hook must NOT emit '## Self-Review Summary' (skill-only)" PASS ;;
esac

SKILL_MD_PARITY="$PLUGIN_DIR/skills/self-review/SKILL.md"
SKILL_SEQ="$(awk '/^### Final report/{f=1} f&&/^```/{c++; if(c>=2) exit} f&&c>=1{print}' "$SKILL_MD_PARITY" | grep -E '^## ' | sed 's/[[:space:]]*$//' | paste -sd'|' -)"
SKILL_SEQ_NO_SR="${SKILL_SEQ/|## Self-Review Summary/}"
[ "$HOOK_SEQ" = "$SKILL_SEQ_NO_SR" ] && check "cross-renderer parity: hook seq == skill Final-report seq minus '## Self-Review Summary'" PASS || check "cross-renderer parity (hook: $HOOK_SEQ | skill-noSR: $SKILL_SEQ_NO_SR)" FAIL

# ── Marker legend parity ────────────────────────────────────────────────
# The status-marker legend is a HAND COPY: the hook's rendered directive and
# skills/self-review/SKILL.md must carry it byte for byte. The heading-sequence
# arm above cannot see it — it compares '^## ' lines only — so a one-sided
# reword would otherwise leave the two renderers disagreeing with every check
# green. Both extractions carry a non-empty control, because a derivation that
# can silently derive nothing passes vacuously.
LEGEND_RE='Mark every status and verdict cell with a leading marker:[\s\S]*?takes no marker\.'
HOOK_LEGEND="$(printf '%s' "$OUT" | LEGEND_RE="$LEGEND_RE" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s).hookSpecificOutput.additionalContext;const m=c.match(new RegExp(process.env.LEGEND_RE));process.stdout.write(m?m[0]:"");})')"
SKILL_LEGEND="$(LEGEND_RE="$LEGEND_RE" node -e 'const fs=require("fs");const c=fs.readFileSync(process.argv[1],"utf8");const m=c.match(new RegExp(process.env.LEGEND_RE));process.stdout.write(m?m[0]:"");' "$SKILL_MD_PARITY")"

[ -n "$HOOK_LEGEND" ] && check "legend control: the marker legend is extractable from the hook directive" PASS || check "legend control: the marker legend is extractable from the hook directive" FAIL
[ -n "$SKILL_LEGEND" ] && check "legend control: the marker legend is extractable from the self-review skill" PASS || check "legend control: the marker legend is extractable from the self-review skill" FAIL
[ -n "$HOOK_LEGEND" ] && [ "$HOOK_LEGEND" = "$SKILL_LEGEND" ] && check "cross-renderer parity: the marker legend is byte-identical in both owners" PASS || check "cross-renderer parity: the marker legend is byte-identical in both owners" FAIL

# ── Verbatim-carry literals survive the marker prefix ───────────────────
# The marker PREFIXES a cell value and never replaces it. A future edit that
# reduced a non-clean evidence literal to a bare coloured dot would delete the
# disclosure while leaving the colour, which is the failure this feature must
# not introduce. Both loops are SCOPED to the summary schema — a file-wide
# presence grep is satisfied by occurrences elsewhere in the same carrier (the
# hook repeats `EDIT NOT LANDED` in its fix-round MSG, and the skill repeats
# every evidence literal in its Phase-4 prose), so an unscoped check cannot
# fail for the reason stated above.
# The two carriers legitimately carry DIFFERENT literal sets: the delegate
# renderer has a `Mtime audit` row where the self-review renderer has
# `Evidence cross-check`, so the evidence literals live only in the latter.
HOOK_CTX="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.stdout.write(JSON.parse(s).hookSpecificOutput.additionalContext);})')"
HOOK_SCHEMA="$(printf '%s' "$HOOK_CTX" | awk '/^## What I built/{f=1} /^## TL;DR/{f=0} f{print}')"
SKILL_SCHEMA="$(awk '/^### Final report/{f=1} f&&/^```/{c++; if(c>=2) exit} f&&c>=1{print}' "$SKILL_MD_PARITY")"
[ -n "$HOOK_SCHEMA" ] && check "literal control: the hook summary schema is extractable" PASS || check "literal control: the hook summary schema is extractable" FAIL
[ -n "$SKILL_SCHEMA" ] && check "literal control: the self-review Final report is extractable" PASS || check "literal control: the self-review Final report is extractable" FAIL
for lit in 'EDIT NOT LANDED' 'UNVERIFIED (no claims logged)' 'PENDING PREDICATE' 'FINDING VERIFICATION DEGRADED' 'UNREADABLE — ' 'PASS — 0 findings, nothing to fix'; do
  case "$HOOK_SCHEMA" in
    *"$lit"*) check "verbatim literal survives in the hook summary schema: $lit" PASS ;;
    *)        check "verbatim literal survives in the hook summary schema: $lit" FAIL ;;
  esac
done
for lit in 'EDIT NOT LANDED' 'UNVERIFIED (no claims logged)' 'PENDING PREDICATE' 'EVIDENCE GAP' 'EVIDENCE CONTRADICTION' 'EVIDENCE CROSS-CHECK UNAVAILABLE' 'FINDING VERIFICATION DEGRADED' 'UNREADABLE — '; do
  case "$SKILL_SCHEMA" in
    *"$lit"*) check "verbatim literal survives in the self-review Final report: $lit" PASS ;;
    *)        check "verbatim literal survives in the self-review Final report: $lit" FAIL ;;
  esac
done

# ── Shared vocabulary parity across both renderers ─────────────────────
# The legend-parity arm above terminates at `takes no marker.`, so EVERY
# marker-bearing rule the two carriers share sits AFTER that point and is
# matched by nothing: the deliverable Status vocabulary, the ID | Status
# vocabulary and the no-Requirements fallback line could each be reworded or
# deleted on ONE side and leave the two renderers disagreeing with every other
# check in this file green. That is the same drift class the per-row anchoring
# of P5a3 and the schema scoping of the two literal loops were raised for; this
# arm closes it for the vocabularies. Both schemas are whitespace-FLATTENED
# first, because the skill wraps the ID | Status vocabulary across two physical
# lines while the hook carries it on one, so an unflattened needle would fail
# on the skill for a reason unrelated to drift.
# The fallback needle carries its BACKTICK DELIMITERS on purpose: both carriers
# delimit that literal so the model knows where the emitted line ends, and the
# hook's copy sits inside a $'...' segment where a backtick is literal. Asserting
# the delimited form over the RENDERED directive therefore proves in one check
# that the delimiter is present AND that it was not eaten by command substitution.
HOOK_SCHEMA_FLAT="$(printf '%s' "$HOOK_SCHEMA" | tr '\n' ' ' | tr -s ' ')"
SKILL_SCHEMA_FLAT="$(printf '%s' "$SKILL_SCHEMA" | tr '\n' ' ' | tr -s ' ')"
[ -n "$HOOK_SCHEMA_FLAT" ] && check "vocabulary control: the hook summary schema flattens to a non-empty string" PASS || check "vocabulary control: the hook summary schema flattens to a non-empty string" FAIL
[ -n "$SKILL_SCHEMA_FLAT" ] && check "vocabulary control: the self-review Final report flattens to a non-empty string" PASS || check "vocabulary control: the self-review Final report flattens to a non-empty string" FAIL
for voc in '🟢 done / 🟢 merged / 🟢 built-tested / 🔴 blocked' '🟢 met / 🟡 partial / 🔴 contradicted / 🔴 dropped / ⚪ deprecated' '`🟡 Requirements: no ## Requirements table in the session plan — per-requirement status not tracked`'; do
  case "$HOOK_SCHEMA_FLAT" in
    *"$voc"*) check "shared vocabulary survives in the hook summary schema: $voc" PASS ;;
    *)        check "shared vocabulary survives in the hook summary schema: $voc" FAIL ;;
  esac
  case "$SKILL_SCHEMA_FLAT" in
    *"$voc"*) check "shared vocabulary survives in the self-review Final report: $voc" PASS ;;
    *)        check "shared vocabulary survives in the self-review Final report: $voc" FAIL ;;
  esac
done

# ── A marker is never orphaned at end of line ──────────────────────────
# A marker separated from its value by a line break renders as a dot with no
# word, which is exactly the disclosure loss the prefix rule forbids. The scan
# must run over the RENDERED directive: in the hook SOURCE the whole directive
# is one physical line whose breaks are `\n` escapes, so a source-side scan can
# never observe the property for that carrier. The program prints a sentinel on
# a clean scan, so a throw (which yields empty stdout) is distinguishable from
# "no orphans found" — the same vacuity hazard the legend controls above guard.
printf '%s' "$HOOK_CTX" > "$TMP_DIR/hook-ctx.txt"
ORPHANS="$(node -e '
const fs=require("fs");
const glyphs=["\u{1F7E2}","\u{1F7E1}","\u{1F534}","\u{26AA}"];
let bad=[], seen=0;
for (const f of process.argv.slice(1)) {
  fs.readFileSync(f,"utf8").split("\n").forEach((line,i)=>{
    const t=line.replace(/[\s\u{FE0F}]+$/u,"");
    for (const g of glyphs) { if (t.includes(g)) seen++; }
    if (glyphs.some(g=>t.endsWith(g))) bad.push(f.replace(/^.*\//,"")+":"+(i+1));
  });
}
process.stdout.write(bad.length ? bad.join(" ") : (seen>0 ? "OK-SCANNED" : "NO-GLYPHS-FOUND"));
' "$TMP_DIR/hook-ctx.txt" "$SKILL_MD_PARITY")"
[ "$ORPHANS" = "OK-SCANNED" ] && check "no marker is orphaned at end of line in either carrier" PASS || check "no marker is orphaned at end of line in either carrier (got: ${ORPHANS:-<node threw>})" FAIL

case "$OUT" in
  *"including rounds that fixed nothing"*)
    check "case A/B legacy + flag on: auto-fix history lists no-fix/verification rounds" PASS ;;
  *)
    check "case A/B legacy + flag on: auto-fix history lists no-fix/verification rounds" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "combinedSummary": false, "selfReview": false}}
EOF

arm_review sess-summary-off-001
STDIN_OFF="$(review_payload sess-summary-off-001)"
OUT="$(printf '%s' "$STDIN_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case A/B legacy + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "case A/B legacy + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

case "$OUT" in
  *"EXCLUDE all Suggestions"*)
    check "case A/B legacy + flag off: existing 'EXCLUDE all Suggestions' directive preserved" PASS ;;
  *)
    check "case A/B legacy + flag off: existing 'EXCLUDE all Suggestions' directive preserved" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": true, "selfReview": false}}
EOF

arm_review sess-summary-sugg-001
STDIN_SUGG_ON="$(review_payload sess-summary-sugg-001)"
OUT="$(printf '%s' "$STDIN_SUGG_ON" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Include EVERY finding the reviewer raised"*)
    check "case B suggestions-on + flag on: existing all-findings directive preserved" PASS ;;
  *)
    check "case B suggestions-on + flag on: existing all-findings directive preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case B suggestions-on + flag on: output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "case B suggestions-on + flag on: output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixIncludeSuggestions": true, "combinedSummary": false, "selfReview": false}}
EOF

arm_review sess-summary-sugg-off-001
STDIN_SUGG_OFF="$(review_payload sess-summary-sugg-off-001)"
OUT="$(printf '%s' "$STDIN_SUGG_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "case B suggestions-on + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "case B suggestions-on + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

case "$OUT" in
  *"Include EVERY finding the reviewer raised"*)
    check "case B suggestions-on + flag off: all-findings directive preserved" PASS ;;
  *)
    check "case B suggestions-on + flag off: all-findings directive preserved" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5, "selfReview": false}}
EOF
SID_MR_ON="sess-summary-mr-on-001"
arm_review "$SID_MR_ON"
prime_review_rounds "$SID_MR_ON" 5
STDIN_MR_ON="$(review_payload "$SID_MR_ON")"
OUT="$(printf '%s' "$STDIN_MR_ON" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 5 rounds reached"*)
    check "max-rounds + flag on: existing convergence message preserved" PASS ;;
  *)
    check "max-rounds + flag on: existing convergence message preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "max-rounds + flag on: output contains 'CHAIN-END SUMMARY'" PASS ;;
  *)
    check "max-rounds + flag on: output contains 'CHAIN-END SUMMARY'" FAIL ;;
esac

case "$OUT" in
  *"including rounds that fixed nothing"*)
    check "max-rounds + flag on: auto-fix history lists no-fix/verification rounds" PASS ;;
  *)
    check "max-rounds + flag on: auto-fix history lists no-fix/verification rounds" FAIL ;;
esac

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true, "autoFixMaxRounds": 5, "combinedSummary": false, "selfReview": false}}
EOF
SID_MR_OFF="sess-summary-mr-off-001"
arm_review "$SID_MR_OFF"
prime_review_rounds "$SID_MR_OFF" 5
STDIN_MR_OFF="$(review_payload "$SID_MR_OFF")"
OUT="$(printf '%s' "$STDIN_MR_OFF" | "$SCRIPT" 2>/dev/null)"

case "$OUT" in
  *"Auto-fix convergence: max 5 rounds reached"*)
    check "max-rounds + flag off: existing convergence message preserved" PASS ;;
  *)
    check "max-rounds + flag off: existing convergence message preserved" FAIL ;;
esac

case "$OUT" in
  *"CHAIN-END SUMMARY"*)
    check "max-rounds + flag off: output must NOT contain 'CHAIN-END SUMMARY'" FAIL ;;
  *)
    check "max-rounds + flag off: output must NOT contain 'CHAIN-END SUMMARY'" PASS ;;
esac

echo "----"
echo "test-post-review-combined-summary: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
