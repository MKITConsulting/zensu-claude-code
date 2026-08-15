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
# Anti-vacuity is a first-class concern here: the block extraction hard-aborts
# rather than degrading to an empty pattern, every silence check is paired with a
# positive control proving the same invocation emits when the condition is lifted,
# and the content assertions run against the hook's EMITTED context rather than
# against its source text.
#
# The exit code is captured through a file, NOT through `OUT="$(drive …)"`.
# Command substitution runs the helper in a SUBSHELL, so an `RC=$?` set inside it
# never reaches the parent — every `[ "$RC" -eq 0 ]` would then compare against a
# stale global and pass without testing anything. That is exactly how the
# plugin-root check was caught reading `RC=0` while the hook exited 2.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RULES="$PLUGIN_DIR/docs/best-solution-first.md"
HOOK="$PLUGIN_DIR/hooks/user-prompt-best-solution-first.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
HOOK_BASENAME="user-prompt-best-solution-first.sh"
OPEN_MARKER='<!-- zensu:best-solution-first -->'
CLOSE_MARKER='<!-- /zensu:best-solution-first -->'

# The hook binds its own plugin root; without this a stray ambient value makes
# every drive-the-hook check fail with a misleading label. Sibling suites
# (test-evidence-discipline.sh, test-session-start-banner.sh) do the same.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"

CFG_OFF=""; CFG_ON=""; FAKE_MISSING=""; FAKE_LINK=""; DRIVE_TMP=""
cleanup() {
  [ -n "$CFG_OFF" ] && rm -f "$CFG_OFF"
  [ -n "$CFG_ON" ] && rm -f "$CFG_ON"
  [ -n "$DRIVE_TMP" ] && rm -f "$DRIVE_TMP"
  [ -n "$FAKE_MISSING" ] && rm -rf "$FAKE_MISSING"
  [ -n "$FAKE_LINK" ] && rm -rf "$FAKE_LINK"
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
  echo "test-best-solution-first: $PASS PASS / $FAIL FAIL"
  [ "$FAIL" -eq 0 ]
}

DRIVE_TMP="$(mktemp)"
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

if grep -qE "for \(const directory of \[.*'docs'.*\]\)" "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"; then
  check "P1 canonical file lives under docs/, which the runtime digest covers" PASS
else
  check "P1 docs/ is no longer in the runtime-digest directory list" FAIL
fi

# P2 proves the harness can observe a non-zero exit at all. Without it every
# RC assertion below could be reading a stale global and reporting a pass.
printf '' | bash -c 'exit 3' >"$DRIVE_TMP" 2>/dev/null
[ "$?" -eq 3 ] \
  && check "P2 harness observes a non-zero hook exit code" PASS \
  || check "P2 harness cannot observe exit codes — every RC assertion would be vacuous" FAIL

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
  check "B2 condensed block is exactly one line (got: $BLOCK_LINES) — the hook reads one line, so the rest would be silently dropped" FAIL
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

# What the hook actually injects: the leading blockquote marker is stripped.
BLOCK="${BLOCK_RAW#> }"

# The rule is worthless if it stops naming both halves of what it demands.
case "$BLOCK" in
  *'must CONTAIN'*) check "B2a block demands the best option be PRESENT in the set" PASS ;;
  *) check "B2a block no longer demands the best option be present" FAIL ;;
esac
case "$BLOCK" in
  *'must come FIRST'*) check "B2b block demands the best option be ranked FIRST" PASS ;;
  *) check "B2b block no longer demands the best option be ranked first" FAIL ;;
esac

# ── B1: registration on both events ─────────────────────────────────────────
REG="$(HOOKS_JSON="$HOOKS_JSON" BASE="$HOOK_BASENAME" node -e '
  const h = JSON.parse(require("fs").readFileSync(process.env.HOOKS_JSON, "utf8"));
  const base = process.env.BASE;
  const legs = (ev) => (h.hooks[ev] || [])
    .flatMap((m) => (m.hooks || []).map((x) => String(x.command || "")))
    .filter((c) => c.includes(base)).length;
  process.stdout.write(legs("UserPromptSubmit") + ":" + legs("SubagentStart"));
' 2>/dev/null)"
if [ "$REG" = "1:1" ]; then
  check "B1 hooks.json registers the hook exactly once on UserPromptSubmit and once on SubagentStart" PASS
else
  check "B1 registration wrong (UserPromptSubmit:SubagentStart = ${REG:-<unreadable>}, want 1:1)" FAIL
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

drive '{"hook_event_name":"SubagentStart"}'
SA_RC="$RC"
SA_EVENT="$(field "$OUT" hookEventName)"
SA_CTX="$(field "$OUT" additionalContext)"
if [ "$SA_RC" -eq 0 ] && [ "$SA_EVENT" = "SubagentStart" ]; then
  check "B4 SubagentStart emits hookEventName=SubagentStart (exit 0)" PASS
else
  check "B4 SubagentStart emission wrong (exit=$SA_RC event='${SA_EVENT}')" FAIL
fi
case "$SA_CTX" in
  *"$BLOCK"*) check "B4a SubagentStart additionalContext carries the canonical block VERBATIM" PASS ;;
  *) check "B4a SubagentStart additionalContext does not carry the canonical block" FAIL ;;
esac

# The hook must echo the event it was handed, not a hardcoded one: a wrong
# hookEventName is rejected by the host and the injection is silently lost.
if [ -n "$UP_EVENT" ] && [ "$UP_EVENT" != "$SA_EVENT" ]; then
  check "B4b hookEventName mirrors the incoming event rather than being hardcoded" PASS
else
  check "B4b hookEventName does not track the incoming event" FAIL
fi

# The hook must never claim the rule cannot be switched off — it can.
case "$UP_CTX" in
  *'not switchable off'*) check "B4c injected directive falsely claims the rule is not switchable" FAIL ;;
  *) check "B4c injected directive does not claim the rule is unswitchable" PASS ;;
esac

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
    B6_LABEL="$B6_LABEL [$bad exit=$RC bytes=${#OUT}]"
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
  && check "B6 malformed / non-object / event-less payloads emit nothing and exit 0" PASS \
  || check "B6 a malformed payload was not handled silently:$B6_LABEL" FAIL

# ── B7 / B8: the rule file must be present and must not be a symlink ────────
# Both need a plugin tree the hook binds as its OWN root, so CLAUDE_PLUGIN_ROOT
# travels with the fake tree — the ambient export would otherwise trip the
# identity guard and turn these into vacuous exit-2 checks.
build_fake() {
  local dest="$1"
  mkdir -p "$dest/hooks/lib" "$dest/docs" || return 1
  cp "$HOOK" "$dest/hooks/$HOOK_BASENAME" || return 1
  cp "$PLUGIN_DIR/hooks/lib/zensu-config.sh" "$dest/hooks/lib/zensu-config.sh" || return 1
  return 0
}

FAKE_MISSING="$(mktemp -d)"
if build_fake "$FAKE_MISSING"; then
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

FAKE_LINK="$(mktemp -d)"
if build_fake "$FAKE_LINK" \
   && cat "$RULES" > "$FAKE_LINK/real-rules.md" \
   && ln -s "$FAKE_LINK/real-rules.md" "$FAKE_LINK/docs/best-solution-first.md" 2>/dev/null \
   && [ -L "$FAKE_LINK/docs/best-solution-first.md" ]; then
  CLAUDE_PLUGIN_ROOT="$FAKE_LINK" drive '{"hook_event_name":"UserPromptSubmit"}' "$FAKE_LINK/hooks/$HOOK_BASENAME"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] \
    && check "B8 a symlinked rule file is refused: emits nothing and exits 0" PASS \
    || check "B8 symlinked rule file was read (exit=$RC bytes=${#OUT})" FAIL
else
  # ln -s exiting 0 is not evidence of a symlink on every host; only claim the
  # check when the link is real, so a copy-fallback never reports a false PASS.
  check "B8 SKIPPED — host did not produce a real symlink" PASS
fi

# ── B9 / B10: the opt-out flag ──────────────────────────────────────────────
CFG_OFF="$(mktemp)"; printf '{"hooks":{"bestSolutionFirst":false}}' > "$CFG_OFF"
ZENSU_CONFIG="$CFG_OFF" drive '{"hook_event_name":"UserPromptSubmit"}'
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && check "B9 hooks.bestSolutionFirst:false suppresses the UserPromptSubmit injection" PASS \
  || check "B9 opt-out did not suppress the injection (exit=$RC bytes=${#OUT})" FAIL

ZENSU_CONFIG="$CFG_OFF" drive '{"hook_event_name":"SubagentStart"}'
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && check "B9a the opt-out covers the SubagentStart leg too" PASS \
  || check "B9a opt-out leaves the SubagentStart leg emitting (exit=$RC bytes=${#OUT})" FAIL

CFG_ON="$(mktemp)"; printf '{"hooks":{"bestSolutionFirst":true}}' > "$CFG_ON"
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

finish
