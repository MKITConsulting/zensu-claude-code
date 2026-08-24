#!/bin/bash
set -u

# Pins the best-solution-first option-quality rule:
#   - docs/best-solution-first.md is the single source of truth and carries the
#     delimited one-line injection block. It lives under docs/ because
#     manifestRuntimeEntries in session-control-core-v1.js folds
#     hooks/agents/skills/docs/templates into the Session Control runtime digest.
#   - hooks/user-prompt-best-solution-first.sh READS that block at run time (it
#     must not carry its own copy, or the hook silently drifts from the canonical
#     text), injects it on BOTH UserPromptSubmit — every prompt, no de-bounce —
#     and SubagentStart, and fails silent on everything it does not understand.
#   - unlike session-start-evidence-discipline.sh the rule IS switchable, via
#     hooks.bestSolutionFirst, because it directs how a decision is presented
#     rather than asserting a correctness invariant.
#
# Anti-vacuity is a first-class concern here, and three defects found in review
# shaped how it is done:
#
#   - The exit code is captured through a file, NOT through `OUT="$(drive …)"`.
#     Command substitution runs the helper in a SUBSHELL, so an `RC=$?` set inside
#     it never reaches the parent — every `[ "$RC" -eq 0 ]` would then compare
#     against a stale global and pass without testing anything. P2 drives the real
#     helper against a stub that exits 3, so the control covers `drive` itself and
#     runs before the first RC assertion.
#   - Every silence check is paired with a positive control, and ZENSU_CONFIG is
#     pinned to an empty object for the whole suite. Without that, a host carrying
#     hooks.bestSolutionFirst:false would make B5 and B6 pass because the hook
#     exited at the config gate, not because it classified the payload.
#   - A SubagentStart payload carrying no agent_id/agent_type classifies as
#     main-v1 (hooks/lib/claude-principal-v1.js). Driving that shape cannot tell a
#     working second leg from one silenced by a principal gate, so B4/B4a use a
#     real subagent shape and B4d pins the absence of any principal filter.
#
# The five malformed-block shapes the hook refuses (B7c-B7g; B7b is their positive
# control) are driven against the hook itself, not against this suite's own extractor:
# the run-time consequence of a malformed block is a DROPPED injection that nothing
# reports, so the build-time pins are the only place it can be caught.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RULES="$PLUGIN_DIR/docs/best-solution-first.md"
HOOK="$PLUGIN_DIR/hooks/user-prompt-best-solution-first.sh"
# The hardened read, the size and short-read bounds, MAX_BLOCK and the marker
# parse have ONE owner now. Every pin that used to grep a carrier's inline copy
# greps this instead, which is what makes the cross-carrier equality checks the
# review flagged unnecessary rather than merely satisfied.
RULE_BLOCK_LIB="$PLUGIN_DIR/hooks/lib/rule-block-v1.js"

HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
HOOK_BASENAME="user-prompt-best-solution-first.sh"
OPEN_MARKER='<!-- zensu:best-solution-first -->'
CLOSE_MARKER='<!-- /zensu:best-solution-first -->'
# The hook's run-time refusal is a fail-safe at `MAX_BLOCK`; REVIEW_CEILING is the real control.
# The criterion is ABSOLUTE headroom of roughly one clause, IDENTICAL on both carriers — not a
# preserved percentage, which would hand the larger slack to whichever block happens to be
# bigger and would widen with every legitimate growth. 1741 = the 1652-character block plus the
# same 89 characters test-evidence-discipline.sh allows over its 811. The equality is not left
# to prose: the cross-carrier check in tests/structure/test-windows-portability-guards.sh
# asserts it, because that suite already owns everything the two carriers must share.
MAX_BLOCK=4000
# REVIEW_HEADROOM is load-bearing, not decorative: the arm below asserts the remaining slack
# never EXCEEDS it, in the suite that owns the ceiling. One-sided and per-suite on purpose —
# block growth only shrinks the slack and stays green, while a unilateral ceiling raise fails
# HERE, where the edit was made, rather than in a third suite. Round 3 derived the ceiling from
# the live block and was over-constrained; round 4 compared two inert literals and constrained
# nothing. Accepted consequence: a block that SHRINKS a lot also trips this, which is correct —
# the tripwire stops being a tripwire if the ceiling drifts away from the text.
REVIEW_CEILING=1741
REVIEW_HEADROOM=89

# The hook binds its own plugin root; without this a stray ambient value makes
# every drive-the-hook check fail with a misleading label. Sibling suites
# (test-evidence-discipline.sh, test-session-start-banner.sh) do the same.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

CFG_OFF=""; CFG_ON=""; SUITE_CFG=""; FAKE_MISSING=""; FAKE_LINK=""; FAKE_BLOCK=""
DRIVE_TMP=""; STUB=""; NODELESS_BIN=""; FAKE_LIB=""; P0A_OFF=""; CFG_QUOTED=""
cleanup() {
  for f in "$CFG_OFF" "$CFG_ON" "$SUITE_CFG" "$DRIVE_TMP" "$STUB" "$P0A_OFF" "$CFG_QUOTED"; do
    [ -n "$f" ] && rm -f "$f"
  done
  for d in "$FAKE_MISSING" "$FAKE_LINK" "$FAKE_BLOCK" "$NODELESS_BIN" "$FAKE_LIB"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT

# A suite file that ends up containing a spliced copy of its own prologue re-executes this
# line, resetting the counters — the summary then reports only the checks after the last reset
# and looks entirely plausible. That is not hypothetical: it happened during this change (a
# JS `$`-pattern replacement spliced ~485 lines of a suite into itself, and the file still
# reported its normal total). An expected-total pin would not have caught it; a re-entry guard
# does, and costs nothing per added check. It detects a splice that INCLUDES these lines, which
# is the whole-prologue shape; a splice starting strictly below them is not covered.
if [ -n "${ZENSU_SUITE_PROLOGUE_ENTERED:-}" ]; then
  printf 'prologue re-entered — this suite file is corrupt\n' >&2
  exit 1
fi
ZENSU_SUITE_PROLOGUE_ENTERED=1
PASS=0; FAIL=0
# Arity is checked because a label that word-splits is not a cosmetic defect: check() reads
# position 2 unconditionally, so an over-supplied call whose second word happens to read PASS
# scores a FAILING check as a success. That happened in this change — an unquoted expansion in
# a FAIL label — and was fixed at its call site. This makes the class unrepeatable instead of
# re-swept by hand.
check() {
  if [ "$#" -ne 2 ]; then
    printf '  FAIL  check() called with %s arguments, expected 2 — a label word-split: %s\n' "$#" "${1:-}"
    FAIL=$((FAIL + 1)); return 0
  fi
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-best-solution-first: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

# mktemp results are guarded: an unguarded failure would make build_fake write to
# /hooks and /docs while cleanup silently skipped it.
mk_file() { local v; v="$(mktemp -t zensu-bsf-XXXXXX)" || v=""; printf '%s' "$v"; }
mk_dir()  { local v; v="$(mktemp -d -t zensu-bsf-XXXXXX)" || v=""; printf '%s' "$v"; }

DRIVE_TMP="$(mk_file)"
if [ -z "$DRIVE_TMP" ]; then
  echo "  FAIL  P0 could not create the driver temp file"
  echo "----"; echo "test-best-solution-first: 0 PASS / 1 FAIL"
  exit 1
fi

OUT=""; RC=0
# Drive the hook with a payload. Sets OUT (stdout) and RC (exit code) in the
# CALLER's scope — never call this inside `$( )`, see the header note.
drive() {
  local payload="$1" hook_path="${2:-$HOOK}"
  printf '%s' "$payload" | bash "$hook_path" >"$DRIVE_TMP" 2>/dev/null
  RC=$?
  OUT="$(cat "$DRIVE_TMP")"
}

# Decode hookSpecificOutput out of the hook's JSON. Grepping the raw envelope
# would compare against JSON-escaped bytes, which silently never match.
field() {
  PAYLOAD="$1" FIELD="$2" node -e '
    try {
      const j = JSON.parse(process.env.PAYLOAD || "{}");
      const v = (j.hookSpecificOutput || {})[process.env.FIELD];
      process.stdout.write(typeof v === "string" ? v : "");
    } catch (_) { process.stdout.write(""); }
  ' 2>/dev/null
}

for f in "$RULES" "$HOOK" "$HOOKS_JSON"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    finish
    exit 1
  fi
done
check "P0 all target files exist" PASS

if ! command -v node >/dev/null 2>&1; then
  check "P0 node available" FAIL
  finish
  exit 1
fi

# Host config must not decide any verdict below. B5 and B6 are the two silence
# checks with no positive control of their own; on a host carrying
# hooks.bestSolutionFirst:false they would pass for the wrong reason.
SUITE_CFG="$(mk_file)"
if [ -n "$SUITE_CFG" ] && printf '{}' > "$SUITE_CFG"; then
  export ZENSU_CONFIG="$SUITE_CFG"
else
  check "P0a could not pin ZENSU_CONFIG — host config could decide verdicts below" FAIL
  finish
  exit 1
fi

# P0a is a DISCRIMINATION probe, not "a file was written": if the hook ever stopped
# honouring ZENSU_CONFIG, B5 and B6 — the two silence checks with no positive control of
# their own — would silently become host-decidable again while a write-only check passed.
P0A_OFF="$(mk_file)"
if [ -n "$P0A_OFF" ] && printf '{"hooks":{"bestSolutionFirst":false}}' > "$P0A_OFF"; then
  ZENSU_CONFIG="$P0A_OFF" drive '{"hook_event_name":"UserPromptSubmit"}'
  P0A_SILENT=$([ "$RC" -eq 0 ] && [ -z "$OUT" ] && echo 1 || echo 0)
  drive '{"hook_event_name":"UserPromptSubmit"}'
  P0A_LOUD=$([ "$RC" -eq 0 ] && [ -n "$OUT" ] && echo 1 || echo 0)
  rm -f "$P0A_OFF"
  [ "$P0A_SILENT" = 1 ] && [ "$P0A_LOUD" = 1 ] \
    && check "P0a ZENSU_CONFIG demonstrably decides the hook (off silences, pinned {} emits)" PASS \
    || check "P0a ZENSU_CONFIG does not decide the hook (off=$P0A_SILENT pinned=$P0A_LOUD) — B5/B6 are host-decidable" FAIL
else
  check "P0a could not build the ZENSU_CONFIG discrimination fixture" FAIL
fi

if grep -qE "for \(const directory of \[.*'docs'.*\]\)" "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"; then
  check "P1 canonical file lives under docs/, which the runtime digest covers" PASS
else
  check "P1 docs/ is no longer in the runtime-digest directory list" FAIL
fi

# P2 proves the harness observes a non-zero exit THROUGH `drive` — the helper that
# carried the original subshell defect. Testing an inline pipeline instead would
# leave a reintroduced `OUT="$(drive …)"` at the call sites undetected.
STUB="$(mk_file)"
if [ -n "$STUB" ] && printf '#!/bin/bash\nexit 3\n' > "$STUB"; then
  drive '{"hook_event_name":"UserPromptSubmit"}' "$STUB"
  [ "$RC" -eq 3 ] \
    && check "P2 drive() propagates a non-zero hook exit code to the caller" PASS \
    || check "P2 drive() lost the exit code (got $RC, want 3) — every RC assertion below is vacuous" FAIL
else
  check "P2 could not create the exit-code stub" FAIL
fi

# ── B2: the canonical block ─────────────────────────────────────────────────
OPEN_N="$(grep -cxF "$OPEN_MARKER" "$RULES")"
CLOSE_N="$(grep -cxF "$CLOSE_MARKER" "$RULES")"
if [ "$OPEN_N" = "1" ] && [ "$CLOSE_N" = "1" ]; then
  check "B2 canonical file carries exactly one open and one close marker" PASS
else
  check "B2 marker pair not unique (open: $OPEN_N, close: $CLOSE_N)" FAIL
fi

BLOCK_RAW="$(awk -v o="$OPEN_MARKER" -v c="$CLOSE_MARKER" '
  $0 == o { inb = 1; next }
  inb && $0 == c { exit }
  inb { print }
' "$RULES")"
BLOCK_LINES="$(printf '%s\n' "$BLOCK_RAW" | grep -c '')"

# Hard abort, never degrade: an empty or multi-line block would turn every
# emission assertion below into a no-op that still prints PASS.
if [ -z "$BLOCK_RAW" ]; then
  check "B2 condensed block extracted between the markers" FAIL
  finish
  exit 1
fi
if [ "$BLOCK_LINES" != "1" ]; then
  check "B2 condensed block is exactly one line (got: $BLOCK_LINES) — the hook DROPS the injection entirely for anything else" FAIL
  finish
  exit 1
fi
case "$BLOCK_RAW" in
  '> **Best solution first (option quality).**'*)
    check "B2 block is a single line between the markers and opens with the pinned lede" PASS ;;
  *)
    check "B2 block does not open with the pinned lede" FAIL
    finish
    exit 1 ;;
esac

# Mirror the hook's own transformation — `.replace(/^>\s*/, "").trim()`. Stripping
# only the literal "> " would fail a correct hook over an invisible trailing space.
BLOCK="$(printf '%s' "$BLOCK_RAW" | sed -e 's/^>[[:space:]]*//' -e 's/[[:space:]]*$//')"

# The rule is worthless if it stops naming both halves of what it demands, and
# actively harmful if it keeps only the prohibition — a block carrying no
# anti-inflation carve-out pushes every agent toward inflating scope.
case "$BLOCK" in
  *'must CONTAIN'*) check "B2a block demands the best option be PRESENT in the set" PASS ;;
  *) check "B2a block no longer demands the best option be present" FAIL ;;
esac
case "$BLOCK" in
  *'must come FIRST'*) check "B2b block demands the best option be ranked FIRST" PASS ;;
  *) check "B2b block no longer demands the best option be ranked first" FAIL ;;
esac
case "$BLOCK" in
  *'never licenses inflating scope'*)
    check "B2c block carries the anti-inflation carve-out (doing less can be the best answer)" PASS ;;
  *)
    check "B2c block lost the anti-inflation carve-out — it would carry only the prohibition" FAIL ;;
esac
case "$BLOCK" in
  *'This block is complete as written'*)
    check "B2d block is self-closing against a workspace file claiming to be this rule" PASS ;;
  *)
    check "B2d block lost its self-closing clause" FAIL ;;
esac
case "$BLOCK" in
  *'fixes an option order by contract'*)
    check "B2e block yields to a skill that fixes an option order by contract" PASS ;;
  *)
    check "B2e block no longer declares precedence against a contract-fixed order" FAIL ;;
esac
# The block must name NO file, so no reader can be pointed at a project-resolvable path
# claiming to be an expanded version of it — a reviewer principal resolves reads against
# the PROJECT root, so a hostile repository can plant any path the block names. Rejecting
# only this file's own name would let any OTHER path through while the label still read
# "names no file path", so the predicate is path-SHAPED rather than one literal.
if printf '%s' "$BLOCK" | grep -qE '[A-Za-z0-9_-]+\.(md|json|sh|js|mjs|cjs|txt|ya?ml)|/'; then
  check "B2f block names a file path or a slash-separated location — a hostile repo could plant it" FAIL
else
  check "B2f block names no file path of any shape" PASS
fi

# The clause pins above cover a lede and five substrings; the rest of the directive could
# still be rewritten in a docs-only commit with no test literal changing. That is the
# low-visibility channel this digest closes: the bytes that reach every prompt and every
# spawn cannot change without a matching literal here, in the same commit.
# Hashed through node, not shasum/sha256sum: node is already required at P0, while
# neither hashing binary is guaranteed on every supported host. This suite runs in
# windows-shard-4, and a check that goes red because a tool is missing fails for a
# reason unrelated to what it tests — the exact defect class this suite was written
# to catch.
BLOCK_SHA="$(BLOCK_TEXT="$BLOCK" node -e '
  try {
    process.stdout.write(require("crypto").createHash("sha256")
      .update(process.env.BLOCK_TEXT || "", "utf8").digest("hex"));
  } catch (_) { process.stdout.write(""); }
' 2>/dev/null)"
EXPECTED_BLOCK_SHA='3bfc50602b524b7ca37e96504c11409f2d72fbc8ed908c137e7efc566cd77420'
if [ -z "$BLOCK_SHA" ]; then
  check "B2f1 node could not hash the injected block" FAIL
elif [ "$BLOCK_SHA" = "$EXPECTED_BLOCK_SHA" ]; then
  check "B2f1 injected block matches its pinned digest" PASS
else
  check "B2f1 injected block CHANGED ($BLOCK_SHA != $EXPECTED_BLOCK_SHA) — update this literal deliberately, in the same commit" FAIL
fi
# node, not ${#BLOCK}: bash counts bytes under LC_ALL=C and this block carries em dashes,
# while the hook compares String.length. Same measure as test-evidence-discipline.sh H7a.
B2G_LEN="$(S="$BLOCK" node -e 'process.stdout.write(String((process.env.S || "").length))')"
if [ "$B2G_LEN" -le "$REVIEW_CEILING" ]; then
  check "B2g block is within the ${REVIEW_CEILING}-char review ceiling ($B2G_LEN)" PASS
else
  check "B2g block exceeds the review ceiling ($B2G_LEN > $REVIEW_CEILING) — argue the new clause or raise it deliberately" FAIL
fi
if [ "$(( REVIEW_CEILING - B2G_LEN ))" -le "$REVIEW_HEADROOM" ]; then
  check "B2g1 the review ceiling sits within the declared ${REVIEW_HEADROOM}-char headroom of the block (slack $(( REVIEW_CEILING - B2G_LEN )))" PASS
else
  check "B2g1 the review ceiling is $(( REVIEW_CEILING - B2G_LEN )) chars above the block, more than the declared ${REVIEW_HEADROOM} — raise the headroom deliberately or lower the ceiling" FAIL
fi
# The suite's fail-safe number is a hand copy; bind it to the OWNER's literal.
# There is one owner now — hooks/lib/rule-block-v1.js — so this no longer has to
# police two carriers against each other, and B2h asserts that neither carrier
# reintroduces a declaration of its own.
B2H_CODE="$(grep -v '^[[:space:]]*//' "$RULE_BLOCK_LIB")"
B2H_CARRIERS_CLEAN=1
for carrier in "$HOOK" "$PLUGIN_DIR/hooks/session-start-evidence-discipline.sh"; do
  grep -qE 'MAX_BLOCK[[:space:]]*=[[:space:]]*[0-9]' "$carrier" && B2H_CARRIERS_CLEAN=0
done
if printf '%s\n' "$B2H_CODE" | grep -qF "const MAX_BLOCK = $MAX_BLOCK;" \
   && printf '%s\n' "$B2H_CODE" | grep -qF 'block.length > MAX_BLOCK' \
   && [ "$B2H_CARRIERS_CLEAN" = 1 ]; then
  check "B2h MAX_BLOCK = $MAX_BLOCK has ONE definition, in the shared reader, and no carrier redeclares it" PASS
else
  check "B2h MAX_BLOCK is no longer $MAX_BLOCK in the shared reader, is not compared, or a carrier redeclared it" FAIL
fi
# MAX_FILE, the short-read refusal and the guarded close are one-line additions.
# They now have executed cases in tests/structure/rule-block-v1.test.js as well;
# these greps stay because a deletion should fail loudly at both layers.
if printf '%s\n' "$B2H_CODE" | grep -qF 'const MAX_FILE =' \
   && printf '%s\n' "$B2H_CODE" | grep -qF 'post.size > MAX_FILE' \
   && printf '%s\n' "$B2H_CODE" | grep -qF 'if (filled !== post.size) return { text: null, reason: REASONS.SHORT_READ };' \
   && printf '%s\n' "$B2H_CODE" | grep -qF 'try { fs.closeSync(fd); } catch (_)'; then
  check "B2i the shared reader keeps its file-size ceiling, short-read refusal and non-throwing close" PASS
else
  check "B2i the shared reader lost its size ceiling, short-read refusal or guarded close" FAIL
fi

# B0 — the unit contract for the shared reader, driven FIRST. tests/run-all.sh
# discovers only test-*.sh, so a *.test.js with no driver is never executed by the
# tree runner. It runs at the head of this file on purpose: it needs nothing this
# suite builds, and at the tail a Windows shard timeout would cost the only
# coverage the reader's own refusal branches have anywhere.
RULE_BLOCK_UNIT="$PLUGIN_DIR/tests/structure/rule-block-v1.test.js"
if [ ! -f "$RULE_BLOCK_UNIT" ]; then
  check "B0 the shared reader's unit contract is missing from disk" FAIL
elif ! command -v node >/dev/null 2>&1; then
  skip "B0 rule-block unit contract (node unavailable)"
else
  B0_OUT="$(node --test "$RULE_BLOCK_UNIT" 2>&1)"
  B0_RC=$?
  # A case-count floor as well as the exit status: `node --test` exits 0 for a file
  # that registers ZERO cases, so the status alone cannot tell a green run from a
  # suite that stopped being discovered.
  B0_PASS="$(printf '%s\n' "$B0_OUT" | sed -n 's/^# pass \([0-9]*\)$/\1/p;s/^. pass \([0-9]*\)$/\1/p' | head -1)"
  if [ "$B0_RC" -eq 0 ] && [ -n "$B0_PASS" ] && [ "$B0_PASS" -ge 9 ]; then
    check "B0 the shared reader's unit contract passes ($B0_PASS cases)" PASS
  else
    check "B0 rule-block unit contract: rc=$B0_RC pass=${B0_PASS:-none} (want >= 9): $(printf '%s' "$B0_OUT" | grep -E '^.?[[:space:]]*(not ok|✖)' | head -2 | tr '\n' ' ')" FAIL
  fi
fi

# ── B1: registration on both events ─────────────────────────────────────────
# The reducer also reports a matcher on either carrying block: a matcher would
# silence some sources while the leg counts stayed green.
REG="$(HOOKS_JSON="$HOOKS_JSON" BASE="$HOOK_BASENAME" node -e '
  const h = JSON.parse(require("fs").readFileSync(process.env.HOOKS_JSON, "utf8"));
  const base = process.env.BASE;
  const carrying = (ev) => (h.hooks[ev] || [])
    .filter((m) => (m.hooks || []).some((x) => String(x.command || "").includes(base)));
  for (const ev of ["UserPromptSubmit", "SubagentStart"]) {
    if (carrying(ev).some((m) => Object.prototype.hasOwnProperty.call(m, "matcher"))) {
      process.stdout.write("matcher:" + ev);
      process.exit(0);
    }
  }
  const legs = (ev) => (h.hooks[ev] || [])
    .flatMap((m) => (m.hooks || []).map((x) => String(x.command || "")))
    .filter((c) => c.includes(base)).length;
  process.stdout.write(legs("UserPromptSubmit") + ":" + legs("SubagentStart"));
' 2>/dev/null)"
if [ "$REG" = "1:1" ]; then
  check "B1 hooks.json registers the hook exactly once on UserPromptSubmit and once on SubagentStart, both matcher-free" PASS
else
  check "B1 registration wrong (${REG:-<unreadable>}, want 1:1 with no matcher)" FAIL
fi

# No SessionStart leg: UserPromptSubmit already covers turn 1, so registering it
# there too would inject the same rule twice on the first turn.
SS="$(HOOKS_JSON="$HOOKS_JSON" BASE="$HOOK_BASENAME" node -e '
  const h = JSON.parse(require("fs").readFileSync(process.env.HOOKS_JSON, "utf8"));
  const legs = (h.hooks.SessionStart || [])
    .flatMap((m) => (m.hooks || []).map((x) => String(x.command || "")))
    .filter((c) => c.includes(process.env.BASE)).length;
  process.stdout.write(String(legs));
' 2>/dev/null)"
[ "$SS" = "0" ] \
  && check "B1a hook is NOT registered on SessionStart (would double-inject on turn 1)" PASS \
  || check "B1a hook is registered on SessionStart (${SS} legs) — double-injects on turn 1" FAIL

# ── B3 / B4: both live events emit the block verbatim ───────────────────────
drive '{"hook_event_name":"UserPromptSubmit"}'
UP_RC="$RC"
UP_EVENT="$(field "$OUT" hookEventName)"
UP_CTX="$(field "$OUT" additionalContext)"
if [ "$UP_RC" -eq 0 ] && [ "$UP_EVENT" = "UserPromptSubmit" ]; then
  check "B3 UserPromptSubmit emits hookEventName=UserPromptSubmit (exit 0)" PASS
else
  check "B3 UserPromptSubmit emission wrong (exit=$UP_RC event='${UP_EVENT}')" FAIL
fi
case "$UP_CTX" in
  *"$BLOCK"*) check "B3a UserPromptSubmit additionalContext carries the canonical block VERBATIM" PASS ;;
  *) check "B3a UserPromptSubmit additionalContext does not carry the canonical block" FAIL ;;
esac
# The framing prefix is what tells the reader the rule binds every process; without
# this the prefix could be dropped with B3a still green.
case "$UP_CTX" in
  'Zensu best-solution-first — binding for every process in this session, main thread and subagents alike. '*)
    check "B3b emitted context OPENS with the full framing prefix, then the block" PASS ;;
  *)
    check "B3b emitted context lost or reordered its framing prefix (len ${#UP_CTX} vs block ${#BLOCK})" FAIL ;;
esac
# The hook's central claim is that it can never block a prompt or a spawn. Any other
# top-level key — decision, continue, permissionDecision — would make that false.
UP_KEYS="$(PAYLOAD="$OUT" node -e '
  try { process.stdout.write(Object.keys(JSON.parse(process.env.PAYLOAD || "{}")).sort().join(",")); }
  catch (_) { process.stdout.write("unparseable"); }
' 2>/dev/null)"
[ "$UP_KEYS" = "hookSpecificOutput" ] \
  && check "B3c emitted object carries hookSpecificOutput and nothing else — it cannot block" PASS \
  || check "B3c emitted object carries extra top-level keys ($UP_KEYS) — it could block a prompt" FAIL

# A REAL subagent payload: one carrying neither agent_id nor agent_type classifies
# as main-v1 (hooks/lib/claude-principal-v1.js), so the bare shape cannot tell a
# working second leg from one silenced by a principal gate.
drive '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"zensu:review-aspect"}'
SA_RC="$RC"
SA_EVENT="$(field "$OUT" hookEventName)"
SA_CTX="$(field "$OUT" additionalContext)"
if [ "$SA_RC" -eq 0 ] && [ "$SA_EVENT" = "SubagentStart" ]; then
  check "B4 a real subagent-shaped SubagentStart payload emits hookEventName=SubagentStart (exit 0)" PASS
else
  check "B4 SubagentStart emission wrong (exit=$SA_RC event='${SA_EVENT}')" FAIL
fi
case "$SA_CTX" in
  *"$BLOCK"*) check "B4a SubagentStart additionalContext carries the canonical block VERBATIM" PASS ;;
  *) check "B4a SubagentStart additionalContext does not carry the canonical block" FAIL ;;
esac

# The hook must echo the event it was handed, not a hardcoded one. Requiring both
# values non-empty keeps this from passing when the second leg emitted nothing.
if [ -n "$UP_EVENT" ] && [ -n "$SA_EVENT" ] && [ "$UP_EVENT" != "$SA_EVENT" ]; then
  check "B4b hookEventName mirrors the incoming event rather than being hardcoded" PASS
else
  check "B4b hookEventName does not track the incoming event (up='$UP_EVENT' sa='$SA_EVENT')" FAIL
fi

# The hook must never claim the rule cannot be switched off — it can.
case "$UP_CTX" in
  *'not switchable off'*) check "B4c injected directive falsely claims the rule is not switchable" FAIL ;;
  *) check "B4c injected directive does not claim the rule is unswitchable" PASS ;;
esac

# Structural pin for the design decision B4 can only test behaviorally: the hook
# carries no principal filter at all, so the SubagentStart leg cannot be narrowed
# to main-v1 by a later edit.
if grep -v '^[[:space:]]*#' "$HOOK" | grep -qE 'zensu_hook_is_main_principal|zensu-agent-context|claude-principal-v1'; then
  check "B4d hook gained a principal filter — the SubagentStart leg would be silenced" FAIL
else
  check "B4d hook carries no principal filter, so both legs stay reachable" PASS
fi

# ── B5: every other event is silent ─────────────────────────────────────────
B5_OK=1
for ev in SessionStart PreToolUse PostToolUse Stop SubagentStop; do
  drive "{\"hook_event_name\":\"$ev\"}"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then
    B5_OK=0
    echo "        (event $ev: exit=$RC bytes=${#OUT})"
  fi
done
[ "$B5_OK" -eq 1 ] \
  && check "B5 unrelated events emit nothing and exit 0" PASS \
  || check "B5 an unrelated event emitted output or a non-zero exit" FAIL

# ── B6: malformed payloads are silent ───────────────────────────────────────
B6_OK=1
B6_LABEL=""
while IFS= read -r bad; do
  drive "$bad"
  if [ "$RC" -ne 0 ] || [ -n "$OUT" ]; then
    B6_OK=0
    B6_LABEL="$B6_LABEL [${bad:-<empty>} exit=$RC bytes=${#OUT}]"
  fi
done <<'PAYLOADS'

not json at all
[]
"bare string"
null
{"hook_event_name":42}
{}
PAYLOADS
[ "$B6_OK" -eq 1 ] \
  && check "B6 empty / malformed / non-object / event-less payloads emit nothing and exit 0" PASS \
  || check "B6 a malformed payload was not handled silently:$B6_LABEL" FAIL

# ── Relocated plugin trees ──────────────────────────────────────────────────
# These need a tree the hook binds as its OWN root, so CLAUDE_PLUGIN_ROOT travels
# with the fake tree — the ambient export would otherwise trip the identity guard
# and turn every one of them into a vacuous exit-2 check.
build_fake() {
  local dest="$1"
  [ -n "$dest" ] || return 1
  mkdir -p "$dest/hooks/lib" "$dest/docs" || return 1
  cp "$HOOK" "$dest/hooks/$HOOK_BASENAME" || return 1
  cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$dest/hooks/lib/zensu-config.sh" || return 1
  # The hardened read and the marker parse moved into a shared module, so a tree
  # that carries the hook without it is a PARTIAL install and the hook exits 0 on
  # its own guard — which would make every positive control here vacuous rather
  # than measuring the branch it names.
  cp "$PLUGIN_DIR/hooks/lib/rule-block-v1.js" "$dest/hooks/lib/rule-block-v1.js" || return 1
  cp "$PLUGIN_DIR/hooks/lib/zensu-host-path.sh" "$dest/hooks/lib/zensu-host-path.sh" || return 1
  return 0
}

FAKE_MISSING="$(mk_dir)"
if [ -n "$FAKE_MISSING" ] && build_fake "$FAKE_MISSING"; then
  # Positive control first: with the rule file present, this same tree emits.
  cp "$RULES" "$FAKE_MISSING/docs/best-solution-first.md"
  CLAUDE_PLUGIN_ROOT="$FAKE_MISSING" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_MISSING/hooks/$HOOK_BASENAME"
  if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
    check "B7a positive control: the relocated tree emits while its rule file exists" PASS
  else
    check "B7a relocated tree does not emit even with its rule file present (exit=$RC bytes=${#OUT}) — B7 would be vacuous" FAIL
  fi
  rm -f "$FAKE_MISSING/docs/best-solution-first.md"
  CLAUDE_PLUGIN_ROOT="$FAKE_MISSING" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_MISSING/hooks/$HOOK_BASENAME"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
    && check "B7 a missing rule file emits nothing and exits 0" PASS \
    || check "B7 missing rule file not handled silently (exit=$RC bytes=${#OUT})" FAIL
else
  check "B7 could not build the relocated plugin tree" FAIL
fi

# B7b-B7g: the hook's five malformed-block refusals, driven against the HOOK.
# B2 above tests this suite's own awk extractor; only these reach the hook's
# parser, and a malformed block is exactly the shape whose run-time consequence is
# an injection that is dropped with nothing reporting it.
FAKE_BLOCK="$(mk_dir)"
if [ -n "$FAKE_BLOCK" ] && build_fake "$FAKE_BLOCK"; then
  BLOCK_FILE="$FAKE_BLOCK/docs/best-solution-first.md"
  block_case() {
    local label="$1"
    CLAUDE_PLUGIN_ROOT="$FAKE_BLOCK" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_BLOCK/hooks/$HOOK_BASENAME"
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
      && check "$label" PASS \
      || check "${label} — NOT refused (exit=$RC bytes=${#OUT})" FAIL
  }

  cp "$RULES" "$BLOCK_FILE"
  CLAUDE_PLUGIN_ROOT="$FAKE_BLOCK" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_BLOCK/hooks/$HOOK_BASENAME"
  [ "$RC" -eq 0 ] && [ -n "$OUT" ] \
    && check "B7b positive control: the block tree emits with an intact block" PASS \
    || check "B7b block tree does not emit with an intact block — B7c-B7g would be vacuous" FAIL

  grep -vxF "$OPEN_MARKER" "$RULES" > "$BLOCK_FILE"
  block_case "B7c a missing open marker drops the injection (exit 0, no output)"

  # INVERTED, and it is the finding rather than a relaxation: refusing on a second
  # OPEN made append-only access a silent kill switch, and on the sibling carrier
  # that directive is documented as not switchable off. The FIRST pair wins, so the
  # shipped block stays authoritative and an appended one cannot displace it.
  {
    cat "$RULES"
    printf '%s\n' "$OPEN_MARKER"
    printf '%s\n' '> appended rule that must never be injected'
    printf '%s\n' "$CLOSE_MARKER"
  } > "$BLOCK_FILE"
  CLAUDE_PLUGIN_ROOT="$FAKE_BLOCK" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_BLOCK/hooks/$HOOK_BASENAME"
  if [ "$RC" -eq 0 ] && [ -n "$OUT" ] \
     && ! printf '%s' "$OUT" | grep -qF 'appended rule that must never be injected'; then
    check "B7d a duplicate open marker leaves the SHIPPED block injected, not the appended one" PASS
  else
    check "B7d a duplicate open marker changed the injection (exit=$RC bytes=${#OUT})" FAIL
  fi
  cp "$RULES" "$BLOCK_FILE"

  awk -v o="$OPEN_MARKER" '{ print } $0 == o { print "> spliced second line" }' "$RULES" > "$BLOCK_FILE"
  block_case "B7e a block spanning two lines drops the injection (exit 0, no output)"

  awk -v o="$OPEN_MARKER" -v c="$CLOSE_MARKER" '
    $0 == o { print; print ""; skip = 1; next }
    skip && $0 != c { next }
    { skip = 0; print }
  ' "$RULES" > "$BLOCK_FILE"
  block_case "B7f a blank line between the markers drops the injection (exit 0, no output)"

  # The fifth refusal branch. Two independent reviewers caught the first version of this
  # fixture leaving the original block line in place, which made it a TWO-line block — so
  # the hook refused at the close-marker-position check and this case silently duplicated
  # B7e while claiming to cover the length guard. The builder below REPLACES the block
  # instead of splicing before it, and the guard asserts the SHAPE (close marker exactly
  # two lines below open) as well as the size, so a fixture that degrades into a different
  # refusal fails loudly rather than passing for the wrong reason.
  awk -v o="$OPEN_MARKER" -v c="$CLOSE_MARKER" -v n="$MAX_BLOCK" '
    $0 == o { print; pad = "> "; for (i = 0; i < n + 200; i++) pad = pad "x"; print pad; skip = 1; next }
    skip && $0 == c { skip = 0 }
    skip { next }
    { print }
  ' "$RULES" > "$BLOCK_FILE"
  BSZ="$(awk -v o="$OPEN_MARKER" '$0==o{getline; print length($0); exit}' "$BLOCK_FILE")"
  BCLOSE="$(awk -v o="$OPEN_MARKER" '$0==o{getline; getline; print; exit}' "$BLOCK_FILE")"
  if [ -n "$BSZ" ] && [ "$BSZ" -gt "$MAX_BLOCK" ] && [ "$BCLOSE" = "$CLOSE_MARKER" ]; then
    block_case "B7g a block longer than $MAX_BLOCK chars drops the injection (built ${BSZ}, close marker at open+2)"
  else
    check "B7g fixture is not an oversized ONE-line block (size=${BSZ:-none} need > $MAX_BLOCK; open+2='${BCLOSE:-none}' need the close marker) — it would test a different refusal" FAIL
  fi
else
  check "B7b could not build the malformed-block plugin tree" FAIL
fi

# ── B8: the rule file must not be a symlink ─────────────────────────────────
# `ln -s` exiting 0 is not evidence of a symlink on every host, so the behavioral
# case runs only when the link is real. A fixture failure is a FAIL, never a skip:
# reporting PASS for a check that executed nothing is how a guard goes unwatched.
FAKE_LINK="$(mk_dir)"
if [ -z "$FAKE_LINK" ] || ! build_fake "$FAKE_LINK" || ! cat "$RULES" > "$FAKE_LINK/real-rules.md"; then
  check "B8 could not build the symlink fixture tree" FAIL
elif ln -s "$FAKE_LINK/real-rules.md" "$FAKE_LINK/docs/best-solution-first.md" 2>/dev/null \
     && [ -L "$FAKE_LINK/docs/best-solution-first.md" ]; then
  CLAUDE_PLUGIN_ROOT="$FAKE_LINK" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_LINK/hooks/$HOOK_BASENAME"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
    && check "B8 a symlinked rule file is refused: emits nothing and exits 0" PASS \
    || check "B8 symlinked rule file was read (exit=$RC bytes=${#OUT})" FAIL
else
  # Host produced no real symlink — fall back to the source-level pin, which works
  # everywhere, rather than claiming a behavioral PASS that never ran.
  if grep -qF '[ ! -L "$ZENSU_BEST_SOLUTION_RULE_FILE" ]' "$HOOK"; then
    check "B8 host produced no real symlink; source-level pin confirms the ! -L guard" PASS
  else
    check "B8 host produced no real symlink AND the ! -L guard is gone from the hook" FAIL
  fi
fi

# B8a: the reader re-checks the file it actually opened, so the shell pre-check
# cannot be won by a swap between check and open.
# Comments are stripped first: the hook's own header names O_NOFOLLOW in prose, so a bare
# token-presence grep would stay green after the flag was deleted from the open. The
# composition and the order are pinned, not the vocabulary.
HOOK_CODE="$(grep -v '^[[:space:]]*//' "$RULE_BLOCK_LIB")"
B8A_FSTAT="$(printf '%s\n' "$HOOK_CODE" | grep -n 'fs.fstatSync(fd)' | head -1 | cut -d: -f1)"
B8A_READ="$(printf '%s\n' "$HOOK_CODE" | grep -n 'fs.readSync(fd' | head -1 | cut -d: -f1)"
if printf '%s\n' "$HOOK_CODE" | grep -qF 'fs.openSync(rulePath, fs.constants.O_RDONLY | platformNoFollow() | platformNonBlock())' \
   && printf '%s\n' "$HOOK_CODE" | grep -qF "process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)" \
   && printf '%s\n' "$HOOK_CODE" | grep -qF 'if (!post.isFile() || post.dev !== pre.dev || post.ino !== pre.ino) {' \
   && [ -n "$B8A_FSTAT" ] && [ -n "$B8A_READ" ] && [ "$B8A_FSTAT" -lt "$B8A_READ" ]; then
  check "B8a reader opens O_NOFOLLOW|O_NONBLOCK and re-checks dev/ino BEFORE reading" PASS
else
  check "B8a hardened-open sequence broken (fstat line ${B8A_FSTAT:-?} vs read line ${B8A_READ:-?})" FAIL
fi

# B8c — the two symlink guards, which B8's behavioural arm cannot discriminate.
# On POSIX `openSync(..., O_NOFOLLOW)` on a symlink throws ELOOP, the outer catch
# swallows it and the hook exits 0 — byte-identical to a correct refusal. So B8
# stays green with BOTH the shell `[ ! -L ]` pre-check and the `!pre.isFile()`
# check deleted. Each is therefore pinned where it lives, and the module half
# additionally has an EXECUTED case in tests/structure/rule-block-v1.test.js that
# drives a real symlink through `readRuleBlock` — the arm B8 cannot be.
B8C_MISS=""
grep -qF '[ ! -L "$ZENSU_BEST_SOLUTION_RULE_FILE" ]' "$HOOK" \
  || B8C_MISS="$B8C_MISS [shell-symlink-precheck-gone]"
grep -qF '[ ! -L "$ZENSU_RULE_BLOCK_LIB" ]' "$HOOK" \
  || B8C_MISS="$B8C_MISS [module-symlink-guard-gone]"
grep -qF 'if (!pre.isFile()) return { text: null, reason: REASONS.NOT_A_FILE };' "$RULE_BLOCK_LIB" \
  || B8C_MISS="$B8C_MISS [reader-type-check-gone]"
grep -qF 'a symlinked rule file is refused by the open itself' "$PLUGIN_DIR/tests/structure/rule-block-v1.test.js" \
  || B8C_MISS="$B8C_MISS [executed-symlink-case-gone]"
if [ -z "$B8C_MISS" ]; then
  check "B8c both symlink guards and the reader's type check are pinned where they live, with an executed case for the module half" PASS
else
  check "B8c symlink guard coverage:$B8C_MISS" FAIL
fi
# The nlink clause is deliberately ABSENT: the path is fixed under the executing plugin
# root, so a hard link is not a way to reach a file the symlink check refuses, and
# refusing one would silently disable the rule on a hard-link-materializing install.
if printf '%s\n' "$HOOK_CODE" | grep -qF 'nlink'; then
  check "B8b the nlink refusal came back — it silently disables the rule on cp -al installs" FAIL
else
  check "B8b reader carries no nlink refusal (deliberate divergence from plan-payload-v1)" PASS
fi

# ── B9 / B10: the opt-out flag ──────────────────────────────────────────────
CFG_OFF="$(mk_file)"
if [ -n "$CFG_OFF" ] && printf '{"hooks":{"bestSolutionFirst":false}}' > "$CFG_OFF"; then
  ZENSU_CONFIG="$CFG_OFF" drive '{"hook_event_name":"UserPromptSubmit"}'
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
    && check "B9 hooks.bestSolutionFirst:false suppresses the UserPromptSubmit injection" PASS \
    || check "B9 opt-out did not suppress the injection (exit=$RC bytes=${#OUT})" FAIL

  # INVERTED, and the asymmetry is the point. `zensu_hook_enabled` resolves the
  # MERGED config and a project-local `.zensu/config.json` wins per key, so one
  # `hooks.bestSolutionFirst: false` in a repository used to silence both legs. For
  # the main thread that is the documented bargain — the user chose to open the
  # project. It does not transfer to a confined reviewer spawned to review that
  # repository: the reviewer is exactly the process whose instructions must not be
  # editable by its subject.
  ZENSU_CONFIG="$CFG_OFF" drive '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"zensu:review-aspect"}'
  [ "$RC" -eq 0 ] && [ -n "$OUT" ] \
    && check "B9a the opt-out does NOT reach the SubagentStart leg — a repo cannot silence its own reviewer" PASS \
    || check "B9a opt-out silenced the SubagentStart leg (exit=$RC bytes=${#OUT})" FAIL
else
  check "B9 could not write the opt-out config fixture" FAIL
fi

CFG_ON="$(mk_file)"
if [ -n "$CFG_ON" ] && printf '{"hooks":{"bestSolutionFirst":true}}' > "$CFG_ON"; then
  ZENSU_CONFIG="$CFG_ON" drive '{"hook_event_name":"UserPromptSubmit"}'
  [ "$RC" -eq 0 ] && [ -n "$(field "$OUT" additionalContext)" ] \
    && check "B10 an explicit bestSolutionFirst:true still emits" PASS \
    || check "B10 explicit true did not emit (exit=$RC bytes=${#OUT})" FAIL

  # Default-on: an empty config object must behave exactly like the explicit true.
  printf '{}' > "$CFG_ON"
  ZENSU_CONFIG="$CFG_ON" drive '{"hook_event_name":"UserPromptSubmit"}'
  [ "$RC" -eq 0 ] && [ -n "$(field "$OUT" additionalContext)" ] \
    && check "B10a absent flag defaults to enabled" PASS \
    || check "B10a absent flag did not default to enabled (exit=$RC bytes=${#OUT})" FAIL
else
  check "B10 could not write the enabled config fixture" FAIL
fi

# The flag must go through the shared helper, not a private re-read: a bespoke
# parser would miss the global/project merge and the ZENSU_CONFIG override.
if grep -q 'zensu_hook_enabled bestSolutionFirst' "$HOOK"; then
  check "B10b opt-out resolves through the shared zensu_hook_enabled helper" PASS
else
  check "B10b hook no longer resolves its flag through zensu_hook_enabled" FAIL
fi

# ── B11: plugin-root identity guard ─────────────────────────────────────────
CLAUDE_PLUGIN_ROOT=/ drive '{"hook_event_name":"UserPromptSubmit"}'
[ "$RC" -eq 2 ] && [ -z "$OUT" ] \
  && check "B11 a mismatched inherited CLAUDE_PLUGIN_ROOT refuses with exit 2" PASS \
  || check "B11 plugin-root mismatch not refused (exit=$RC bytes=${#OUT})" FAIL

CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR/hooks" drive '{"hook_event_name":"UserPromptSubmit"}'
[ "$RC" -eq 2 ] && [ -z "$OUT" ] \
  && check "B11a a sibling-directory CLAUDE_PLUGIN_ROOT is refused too" PASS \
  || check "B11a sibling-directory root not refused (exit=$RC bytes=${#OUT})" FAIL

# ── B12: the hook carries no private copy of the rule ───────────────────────
# A copy pasted into the hook would keep every emission check green while the
# canonical file silently stopped being the source of truth.
if grep -qF 'option set must CONTAIN' "$HOOK"; then
  check "B12 hook carries its own copy of the rule text instead of reading docs/" FAIL
else
  check "B12 hook carries no private copy of the rule text" PASS
fi

# ── B13: a host without node fails silent ───────────────────────────────────
# The PATH must stay USABLE: the hook still needs `dirname` to resolve its own
# root, and blanking PATH would test the shebang rather than the node guard.
# Git Bash is where this degenerates — `ln -s` falls back to a copy of
# dirname.exe under a name Windows will not load, so the hook cannot resolve its
# root and refuses with exit 2 long before the node probe. Scoring that as a
# fail-silent defect is exactly what turned this suite's Windows shard red once (it
# ran in windows-shard-7 then, windows-shard-4 now); the guard
# below detects it instead, mirroring test-evidence-discipline.sh H10.
NODELESS_BIN="$(mk_dir)"
if [ -n "$NODELESS_BIN" ]; then
  mkdir -p "$NODELESS_BIN/bin"
  for helper in dirname; do
    src="$(command -v "$helper" 2>/dev/null)"
    [ -n "$src" ] && ln -s "$src" "$NODELESS_BIN/bin/$helper" 2>/dev/null
  done
  ABS_BASH="$(command -v bash 2>/dev/null)"
  ABS_NODE="$(command -v node 2>/dev/null)"
  if PATH="$NODELESS_BIN/bin" command -v node >/dev/null 2>&1; then
    check "B13 could not build a node-free PATH" FAIL
  elif [ -z "$ABS_BASH" ]; then
    check "B13 could not resolve an absolute bash path" FAIL
  elif ! PATH="$NODELESS_BIN/bin" dirname -- /a/b >/dev/null 2>&1; then
    # Only a host whose `ln -s` cannot produce a runnable helper reaches this. On
    # such a host the hook cannot resolve its own root and refuses at the
    # plugin-root guard with exit 2, LONG before the node probe — so nothing about
    # fail-silence was observed. Reporting PASS there claimed coverage the arm did
    # not have, which is the exact class this suite's header sets out to remove.
    # It SKIPS instead, and says which branch went unmeasured.
    if [ "$(node -p 'process.platform === "win32" ? "true" : "false"' 2>/dev/null)" = true ]; then
      skip "B13 missing-node fail-silence (this host's ln -s yields no runnable dirname, so the hook refuses at the plugin-root guard before the node probe)"
    else
      check "B13 could not keep dirname runnable on the node-free PATH" FAIL
    fi
  else
    # Positive control on the SAME stripped PATH: with node linked in, it emits.
    if [ -n "$ABS_NODE" ] && ln -s "$ABS_NODE" "$NODELESS_BIN/bin/node" 2>/dev/null \
       && PATH="$NODELESS_BIN/bin" command -v node >/dev/null 2>&1; then
      CTRL_OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit"}' | PATH="$NODELESS_BIN/bin" "$ABS_BASH" "$HOOK" 2>/dev/null)"; CTRL_RC=$?
      [ "$CTRL_RC" = 0 ] && [ -n "$CTRL_OUT" ] \
        && check "B13a positive control: the stripped PATH still emits while node is present" PASS \
        || check "B13a stripped PATH does not emit even with node present (exit=$CTRL_RC bytes=${#CTRL_OUT}) — B13 would be vacuous" FAIL
      rm -f "$NODELESS_BIN/bin/node"
    else
      check "B13a could not link node onto the stripped PATH — B13 runs without a positive control" FAIL
    fi
    NODELESS_OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit"}' | PATH="$NODELESS_BIN/bin" "$ABS_BASH" "$HOOK" 2>/dev/null)"; NODELESS_RC=$?
    [ "$NODELESS_RC" = 0 ] && [ -z "$NODELESS_OUT" ] \
      && check "B13 a host without node emits nothing and exits 0" PASS \
      || check "B13 node-free host not handled silently (exit=$NODELESS_RC bytes=${#NODELESS_OUT})" FAIL
  fi
else
  check "B13 could not create a fixture dir for the node-free PATH" FAIL
fi

# ── B13b: the shipped example config ───────────────────────────────────────
# README advertises config.example.json as carrying every flag, and five sibling suites
# pin their own flag there. Without this the new flag is the first to skip that file.
EXAMPLE_CFG="$PLUGIN_DIR/config.example.json"
if [ -f "$EXAMPLE_CFG" ]; then
  EX="$(EXAMPLE_CFG="$EXAMPLE_CFG" node -e '
    try {
      const c = JSON.parse(require("fs").readFileSync(process.env.EXAMPLE_CFG, "utf8"));
      process.stdout.write(String((c.hooks || {}).bestSolutionFirst));
    } catch (_) { process.stdout.write("unreadable"); }
  ' 2>/dev/null)"
  [ "$EX" = "true" ] \
    && check "B13b config.example.json ships hooks.bestSolutionFirst: true" PASS \
    || check "B13b config.example.json is missing hooks.bestSolutionFirst (got: ${EX:-absent})" FAIL
else
  check "B13b config.example.json not found" FAIL
fi

# ── B14: the zen-mode carrier of this rule ─────────────────────────────────
# hooks.bestSolutionFirst:false silences THIS hook but not the rule: zen-mode's SCOPE
# clause carries the ranking obligation, because its brevity contract would otherwise
# license exactly the omission this rule forbids. That clause is hand-written in another
# hook and gated on a different flag, so it is pinned here — the suite that owns the rule
# — rather than left to drift.
ZEN_HOOK="$PLUGIN_DIR/hooks/user-prompt-zen-mode.sh"
# The SHIPPED directive, not the whole file. That hook emits three different
# `additionalContext` payloads — the active contract, a `zen-mode is now OFF`
# message and a deactivation-failure message — plus a shell header, and a
# whole-file grep cannot tell which one carries the clause. Moving all three
# literals into the OFF payload, or into a comment, left every check below green
# while the active contract had lost them. The payload is recovered by EXECUTING
# the hook on an active session, so what is asserted is what a model actually
# receives; if it cannot be driven, the arms say so rather than falling back to a
# file-wide grep that cannot discriminate.
ZEN_ACTIVE=""
if [ -f "$ZEN_HOOK" ] && command -v node >/dev/null 2>&1; then
  ZEN_STATE_DIR="$(mk_dir)"
  if [ -n "$ZEN_STATE_DIR" ]; then
    ZEN_ACTIVE="$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"zen-probe","prompt":"zen mode"}' \
      | CLAUDE_PROJECT_DIR="$ZEN_STATE_DIR" bash "$ZEN_HOOK" 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);process.stdout.write(String((o.hookSpecificOutput||{}).additionalContext||""))}catch{}})' 2>/dev/null)"
  fi
fi
# Fall back to the file only when the hook could not be driven at all, and label
# the arms so a reader can tell which evidence they rest on.
ZEN_SRC="$ZEN_ACTIVE"
ZEN_WHERE="the emitted active contract"
if [ -z "$ZEN_SRC" ] && [ -f "$ZEN_HOOK" ]; then
  ZEN_SRC="$(cat "$ZEN_HOOK")"
  ZEN_WHERE="the hook source (the active contract could not be emitted here)"
fi
if [ -f "$ZEN_HOOK" ]; then
  if printf '%s' "$ZEN_SRC" | grep -qF 'never drop an option the user is choosing between' \
     && printf '%s' "$ZEN_SRC" | grep -qF 'demote the one you would defend as best'; then
    check "B14 zen-mode's SCOPE clause still carries the ranking obligation (checked against $ZEN_WHERE)" PASS
  else
    check "B14 zen-mode lost the ranking clause — bestSolutionFirst:false is no longer the only switch that matters" FAIL
  fi
  # zen-mode's brevity clause must not re-license dropping an option under decision.
  if printf '%s' "$ZEN_SRC" | grep -qF 'alternatives you were NOT asked to choose between'; then
    check "B14a zen-mode's brevity clause exempts options actually under decision" PASS
  else
    check "B14a zen-mode's brevity clause again licenses dropping alternatives wholesale" FAIL
  fi
  # A fallback carrying only the prohibition reconstitutes the exact bias the block's
  # anti-inflation carve-out exists to prevent, so the counterweight is pinned too.
  if printf '%s' "$ZEN_SRC" | grep -qF 'never licenses inflating scope'; then
    check "B14b zen-mode's clause carries the anti-inflation counterweight, not the prohibition alone" PASS
  else
    check "B14b zen-mode carries only the prohibition — it would bias every agent toward inflating scope" FAIL
  fi
else
  check "B14 zen-mode hook not found" FAIL
fi

# ── B15: the guard on the sourced library ──────────────────────────────────
# The library is EXECUTED, so it earns at least the data file's guard. Driven, not
# grepped: a symlinked lib in a relocated tree must make the hook exit 0 silently.
FAKE_LIB="$(mk_dir)"
if [ -n "$FAKE_LIB" ] && build_fake "$FAKE_LIB" && cp "$RULES" "$FAKE_LIB/docs/best-solution-first.md"; then
  CLAUDE_PLUGIN_ROOT="$FAKE_LIB" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_LIB/hooks/$HOOK_BASENAME"
  if [ "$RC" -eq 0 ] && [ -n "$OUT" ]; then
    check "B15a positive control: the lib-guard tree emits with a regular zensu-config.sh" PASS
  else
    check "B15a lib-guard tree does not emit with a regular library (exit=$RC bytes=${#OUT}) — B15 would be vacuous" FAIL
  fi
  mv "$FAKE_LIB/hooks/lib/zensu-config.sh" "$FAKE_LIB/real-config.sh"
  if ln -s "$FAKE_LIB/real-config.sh" "$FAKE_LIB/hooks/lib/zensu-config.sh" 2>/dev/null \
     && [ -L "$FAKE_LIB/hooks/lib/zensu-config.sh" ]; then
    CLAUDE_PLUGIN_ROOT="$FAKE_LIB" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_LIB/hooks/$HOOK_BASENAME"
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
      && check "B15 a symlinked zensu-config.sh is refused before it is sourced" PASS \
      || check "B15 symlinked library was sourced anyway (exit=$RC bytes=${#OUT})" FAIL
  else
    # Same policy as B8: a host that cannot make a real symlink falls back to the
    # source-level pin rather than failing for a reason unrelated to the guard.
    # Git Bash on Windows is that host, and this suite runs in a Windows shard.
    if grep -qF '[ ! -L "$ZENSU_BEST_SOLUTION_CONFIG_LIB" ]' "$HOOK"; then
      check "B15 host produced no real symlink; source-level pin confirms the library ! -L guard" PASS
    else
      check "B15 host produced no real symlink AND the library ! -L guard is gone from the hook" FAIL
    fi
  fi
  rm -rf "$FAKE_LIB"; FAKE_LIB=""
else
  check "B15 could not build the lib-guard fixture tree" FAIL
fi

# ── B16: no de-bounce ──────────────────────────────────────────────────────
# The hook-over-skill argument rests entirely on "every prompt, no de-bounce". A
# de-bounce added later would leave every other check green, since none drives twice.
drive '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
B16_FIRST="${#OUT}"
drive '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'
B16_SECOND="${#OUT}"
if [ "$B16_FIRST" -gt 0 ] && [ "$B16_SECOND" = "$B16_FIRST" ]; then
  check "B16 consecutive prompts in one session both emit — no de-bounce band" PASS
else
  check "B16 a second consecutive prompt emitted differently ($B16_FIRST then $B16_SECOND)" FAIL
fi

# B16a is the structural half: a de-bounce modelled on user-prompt-context-nudge.sh needs
# a state path and a bound session. If such a band failed OPEN when it could not resolve
# one — the fail-silent convention this hook otherwise follows — B16's two drives would
# emit identically and the de-bounce would slip through.
#
# NARROWED, because the previous alternation pinned the hook into being both
# unconditional AND stateless, and the second half foreclosed a remedy this PR's own
# `docs/architecture.md` proposes: nothing can tell an operator the rule stopped
# injecting in their installation, and the proposal is a read-only diagnostic
# surface. A `/zensu:doctor` row that READS a state path is not a de-bounce band —
# what makes a band is a WRITE that a later invocation reads back. So the pin keys
# on the write, and B16's two behavioural drives remain the arm that catches a band
# built some other way.
B16A_HIT="$(grep -v '^[[:space:]]*//' "$HOOK" \
  | grep -oE 'zensu_bind_hook_session|transcript_path|>[[:space:]]*"?\$?\{?[A-Za-z_/][^|]*\.zensu/state|mkdir[[:space:]]+-p[^|]*\.zensu/state|writeFileSync|appendFileSync' \
  | head -2 | tr '\n' ' ')"
if [ -n "$B16A_HIT" ]; then
  check "B16a hook gained a session bind or a state WRITE — a de-bounce band may now be present ($B16A_HIT)" FAIL
else
  check "B16a hook performs no session bind and no state write, so no de-bounce can exist; a read-only diagnostic surface is not foreclosed" PASS
fi

# ── B17: the quoted-boolean trap ───────────────────────────────────────────
# zensu_hook_enabled compares with === false, so the STRING "false" does not disable the
# hook. That is repo-wide behaviour (docs/configuration.md documents the trap); pinned
# here so the surprise is deliberate rather than discovered in a support thread.
CFG_QUOTED="$(mk_file)"
if [ -n "$CFG_QUOTED" ] && printf '{"hooks":{"bestSolutionFirst":"false"}}' > "$CFG_QUOTED"; then
  ZENSU_CONFIG="$CFG_QUOTED" drive '{"hook_event_name":"UserPromptSubmit"}'
  [ "$RC" -eq 0 ] && [ -n "$OUT" ] \
    && check "B17 the quoted string \"false\" does NOT disable the hook (documented trap)" PASS \
    || check "B17 quoted \"false\" now disables the hook — diverges from every sibling flag" FAIL
  rm -f "$CFG_QUOTED"
else
  check "B17 could not build the quoted-boolean fixture" FAIL
fi


finish
