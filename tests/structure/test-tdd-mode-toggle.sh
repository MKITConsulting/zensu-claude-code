#!/bin/bash
# Situational TDD mode — the session toggle (hooks/lib/zensu-tdd-mode.sh), the
# caller-supplied `--tdd-begin --tdd-mode` default, and the precedence between
# them. Hermetic walk (no live claude, no API).
#
# The whole feature is one decision made at ONE point: `--tdd-begin` freezes a
# mode into the chain's `vanilla` flag. Everything here pins who wins that
# decision:
#   session marker  >  caller flag  >  hooks.tddImplementation  >  vanilla
# The middle rank exists because the shipped config default is `false`: without
# it, a skill's own strict default (`/zensu:pr-fix-findings`) could never take
# effect. The top rank exists so a user who switched the mode by hand is never
# overruled by a skill — T14 is that bite.
#
# Fail-safety is pinned in the other direction: an absent, malformed, or
# symlinked marker must resolve to `auto` (no override) rather than imposing a
# mode, because the marker is read on every arm.
#
# Two properties are deliberately NOT covered here, so a green run is not read as
# more than it is:
#   - The SECOND freeze point — the Stop-hook adoption of a deferred review, which
#     seeds the same `vanilla` flag — is pinned only structurally (T22c, on the
#     exact argument spelling). A behavioral probe needs the full pending-review
#     adoption fixture that `test-deferred-review-claim.sh` owns.
#   - The writer's pre-rename symlink re-check is TOCTOU defense against a race no
#     deterministic test can win; T9 bites the first guard, not that one.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-tdd-mode.sh"
PHASE_LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"
CONFIG_LIB="$PLUGIN_DIR/hooks/lib/zensu-config.sh"
SKILL="$PLUGIN_DIR/skills/tdd-mode/SKILL.md"
TDD_SKILL="$PLUGIN_DIR/skills/tdd/SKILL.md"
FIX_SKILL="$PLUGIN_DIR/skills/pr-fix-findings/SKILL.md"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
REMINDER="$PLUGIN_DIR/hooks/user-prompt-tdd-reminder.sh"
PLANHOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
STOP="$PLUGIN_DIR/hooks/stop-chain-enforcer.sh"
BANNER="$PLUGIN_DIR/hooks/session-start-banner.sh"
PRIMER="$PLUGIN_DIR/hooks/session-start-primer.sh"

PASS=0; FAIL=0; SKIP=0
check() {
  local label="$1" cond="$2"
  case "$cond" in
    PASS) echo "  PASS  $label"; PASS=$((PASS+1)) ;;
    # A host that cannot create a symlink cannot exercise the symlink guards. That
    # is not a defect, and it is not a verified property either — counted apart so
    # a green line never implies a check that did not run.
    SKIP) echo "  SKIP  $label"; SKIP=$((SKIP+1)) ;;
    *) echo "  FAIL  $label"; FAIL=$((FAIL+1)) ;;
  esac
}

if [ ! -f "$HELPER" ] || [ ! -f "$SKILL" ]; then
  check "T0 helper + SKILL.md exist" FAIL
  echo "----"
  echo "test-tdd-mode-toggle: $PASS PASS / $FAIL FAIL"
  exit 1
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
PROJ="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$PROJ"
STATE_DIR="$PROJ/.zensu/state"
for BASELINE_SID in \
  tddmode-helper tddmode-helper-strict tddmode-iso-a tddmode-iso-b \
  tddmode-flag-strict tddmode-flag-vanilla tddmode-session-strict \
  tddmode-session-vanilla tddmode-session-vanilla-strictcfg tddmode-auto \
  tddmode-default tddmode-reject tddmode-wording tddmode-plan; do
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$BASELINE_SID"
done
mkdir -p "$STATE_DIR"
CFG_DEFAULT="$STATE_DIR/no-such-config.json"
CFG_VANILLA="$STATE_DIR/vanilla-config.json"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$CFG_VANILLA"
CFG_STRICT="$STATE_DIR/strict-config.json"
printf '%s' '{"hooks":{"tddImplementation":true}}' > "$CFG_STRICT"
export ZENSU_CONFIG="$CFG_DEFAULT"
unset CLAUDE_AGENT_TYPE ZENSU_TDD_GATE ZENSU_TEST_WITNESS ZENSU_CHAIN 2>/dev/null || true
cleanup() { rm -rf "$PROJ"; }
trap cleanup EXIT

activate_session() {
  export CLAUDE_CODE_SESSION_ID="$1"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/hooks/lib/zensu-session.sh"
  zensu_bind_model_session
}
# shellcheck disable=SC1090
source "$PHASE_LIB"

# toggle <session> <verb> [config] — runs the helper the way the skill renders it
toggle() {
  CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$PROJ" \
    ZENSU_CONFIG="${3:-$CFG_DEFAULT}" bash "$HELPER" "$2" 2>/dev/null
}
marker_count() { find "$STATE_DIR" -maxdepth 1 -name 'tdd-mode-*.json' 2>/dev/null | grep -c . || true; }
# Resolved through the shared template, never hand-spelled — the same rule T4 pins
# for production code applies to the suite that reads the marker.
marker_path() {
  CLAUDE_PROJECT_DIR="$PROJ" bash -c 'source "$0"; zensu_tdd_mode_marker_path "$1" "$2"' \
    "$CONFIG_LIB" "$PROJ" "$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key "$1")"
}
vanilla_flag() { tdd_get_flag "$(tdd_state_file "$1")" vanilla; }
hook_ctx() {  # stdin payload, $1 hook script, $2 optional config -> additionalContext
  local payload
  payload="$(cat)"
  printf '%s' "$payload" | ZENSU_CONFIG="${2:-$ZENSU_CONFIG}" bash "$1" 2>/dev/null | node -e '
    let s="";process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hookSpecificOutput.additionalContext||"")}catch(_){console.log("")}});'
}

echo "== Static: helper, skill, registration =="
[ -x "$HELPER" ] && check "T1 helper exists + executable" PASS || check "T1 helper exists + executable" FAIL
bash -n "$HELPER" 2>/dev/null && check "T2 helper bash -n syntax check passes" PASS || check "T2 helper bash -n" FAIL

if node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit((p.skills||[]).includes("./skills/tdd-mode")?0:1);
' "$PLUGIN_JSON" 2>/dev/null; then
  check "T3 ./skills/tdd-mode registered in plugin.json" PASS
else
  check "T3 ./skills/tdd-mode registered in plugin.json" FAIL
fi

# T4 the marker path template exists ONCE, in the config lib. zen-mode hand-copies
# its template into the reader hook; a divergence there splits the writer's file
# from the reader's, so this feature keeps exactly one spelling and the writer
# sources it.
if grep -qF 'zensu_tdd_mode_marker_path' "$CONFIG_LIB" \
  && grep -qF '.zensu/state/tdd-mode-' "$CONFIG_LIB" \
  && grep -qF 'zensu_tdd_mode_marker_path' "$HELPER" \
  && ! grep -qF '.zensu/state/tdd-mode-' "$HELPER"; then
  check "T4 marker path template lives once in zensu-config.sh; the writer sources it" PASS
else
  check "T4 marker path template duplicated or missing" FAIL
fi

OUT_T5="$(toggle tddmode-helper --bogus)"; RC_T5=$?
{ [ "$RC_T5" -eq 2 ] && [ "$(marker_count)" = "0" ]; } \
  && check "T5 unknown verb exits 2 and writes no marker" PASS \
  || check "T5 unknown verb (rc=$RC_T5 markers=$(marker_count))" FAIL

# T5b choosing vanilla is a MODE choice, not a gate escape: the bypass ledger must
# stay a record of gate escapes only, or everything it renders under "Gates
# bypassed" stops being true.
if ! grep -qF -- '--bypass-note' "$HELPER" && ! grep -qF 'tdd_record_bypass' "$HELPER"; then
  check "T5b the toggle records no bypass-ledger entry" PASS
else
  check "T5b the toggle writes a bypass-ledger entry" FAIL
fi

echo "== Helper: round-trip, fallback, isolation =="
S_H="tddmode-helper"
ST_A="$(toggle "$S_H" --status)"
toggle "$S_H" --strict >/dev/null
ST_B="$(toggle "$S_H" --status)"; M_B="$(marker_count)"
toggle "$S_H" --vanilla >/dev/null
ST_C="$(toggle "$S_H" --status)"
toggle "$S_H" --auto >/dev/null
ST_D="$(toggle "$S_H" --status)"; M_D="$(marker_count)"
if [ "$ST_A" = "vanilla (config)" ] && [ "$ST_B" = "strict (session)" ] && [ "$M_B" = "1" ] \
  && [ "$ST_C" = "vanilla (session)" ] && [ "$ST_D" = "vanilla (config)" ] && [ "$M_D" = "1" ]; then
  check "T6 --strict/--vanilla/--auto round-trip; --auto releases without deleting the marker" PASS
else
  check "T6 round-trip (A='$ST_A' B='$ST_B' C='$ST_C' D='$ST_D' markers=$M_D)" FAIL
fi

S_HS="tddmode-helper-strict"
ST_E="$(toggle "$S_HS" --status "$CFG_STRICT")"
toggle "$S_HS" --vanilla "$CFG_STRICT" >/dev/null
ST_F="$(toggle "$S_HS" --status "$CFG_STRICT")"
{ [ "$ST_E" = "strict (config)" ] && [ "$ST_F" = "vanilla (session)" ]; } \
  && check "T7 --status names its source; a session choice outranks a strict config" PASS \
  || check "T7 status source (E='$ST_E' F='$ST_F')" FAIL

# T8 a malformed marker resolves to auto — never to a mode nobody chose. The
# corruption has to be OBSERVABLE: it is applied to a marker that currently reads
# `strict (session)`, so the fall-through cannot be confused with the `auto` state
# the previous check left behind. The path is resolved through the shared helper,
# never by picking whatever `find` returns first — two sessions have markers here.
MARKER_H="$(marker_path "$S_H")"
toggle "$S_H" --strict "$CFG_STRICT" >/dev/null
ST_G_PRE="$(toggle "$S_H" --status "$CFG_STRICT")"
printf '%s' '{"mode":' > "$MARKER_H"
ST_G="$(toggle "$S_H" --status "$CFG_STRICT")"
{ [ "$ST_G_PRE" = "strict (session)" ] && [ "$ST_G" = "strict (config)" ]; } \
  && check "T8 a malformed marker falls through to the config (no forced mode)" PASS \
  || check "T8 malformed marker (pre='$ST_G_PRE' post='$ST_G')" FAIL
rm -f "$MARKER_H"

# T8b the reader's own fail-safe branches. No behavioral path reaches them: every
# caller supplies a resolved project dir and session key, and T9 stops at the
# WRITER's guard before any read happens. Driven directly against the sourced lib.
read_override() {
  CLAUDE_PROJECT_DIR="$PROJ" bash -c 'source "$0"; zensu_tdd_mode_override "$1" "$2"' "$CONFIG_LIB" "$1" "$2" 2>/dev/null
}
SAFE_BAD=""
# Bodies that CONTRADICT their own `mode` key. Each spelling below carries the
# UNESCAPED other mode, so a grep over the file — with `^`/`$` anchoring a LINE
# rather than the object — answers a mode the key does not name. The writer emits
# exactly `{"mode":"<value>"}` on one line, so every one of these falls through.
DECOY_MARKER="$(marker_path "$S_H")"
DECOY_KEY="$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key "$S_H")"
decoy_is_auto() {  # $1 label, $2 body (printf %s, no trailing newline unless given)
  printf '%s' "$2" > "$DECOY_MARKER"
  # A decoy that never landed would read `auto` for the wrong reason — absence.
  [ -s "$DECOY_MARKER" ] || { SAFE_BAD="$SAFE_BAD $1:not-written"; return; }
  [ "$(read_override "$PROJ" "$DECOY_KEY")" = "auto" ] || SAFE_BAD="$SAFE_BAD $1"
}
# Positive control first: the writer's own shape at this path still reads strict,
# so an `auto` below is the anchor rejecting the body, not the path being wrong.
printf '%s\n' '{"mode":"strict"}' > "$DECOY_MARKER"
[ "$(read_override "$PROJ" "$DECOY_KEY")" = "strict" ] || SAFE_BAD="$SAFE_BAD control-not-strict"
decoy_is_auto same-line-both '{"mode":"vanilla"} "mode":"strict"'
decoy_is_auto trailing-junk '{"mode":"strict"} trailing junk'
decoy_is_auto second-line-strict '{"mode":"vanilla"}
{"mode":"strict"}'
decoy_is_auto second-line-vanilla '{"mode":"strict","note":"
{"mode":"vanilla"}
"}'
# A blank line must not end the inspection: a reader that sampled a fixed number of
# lines would accept these and answer the mode on line 1, never seeing the one below.
# Both orderings are covered, and the last case sits two blank lines down so no fixed
# sample depth satisfies the block.
decoy_is_auto blank-then-vanilla '{"mode":"strict"}

{"mode":"vanilla"}'
decoy_is_auto blank-then-strict '{"mode":"vanilla"}

{"mode":"strict"}'
decoy_is_auto blank-blank-then-vanilla '{"mode":"strict"}


{"mode":"vanilla"}'
# A NUL byte must not truncate the drain into a false "nothing follows".
decoy_is_auto nul-then-strict "$(printf '{"mode":"vanilla"}\n\000{"mode":"strict"}')"
# ...while trailing whitespace stays tolerated, as the reader documents. Spaces and a
# tab, not bare newlines: command substitution strips trailing newlines, so a
# newline-only remainder would leave `$rest` empty and pin nothing.
printf '%s\n \t \n' '{"mode":"vanilla"}' > "$DECOY_MARKER"
[ "$(read_override "$PROJ" "$DECOY_KEY")" = "vanilla" ] || SAFE_BAD="$SAFE_BAD trailing-whitespace-rejected"
# A file far larger than any marker is refused rather than slurped.
{ printf '%s\n' '{"mode":"strict"}'; head -c 4096 /dev/zero | tr '\0' 'x'; } > "$DECOY_MARKER"
[ "$(read_override "$PROJ" "$DECOY_KEY")" = "auto" ] || SAFE_BAD="$SAFE_BAD oversized-accepted"
rm -f "$DECOY_MARKER"
[ "$(read_override "" "")" = "auto" ] || SAFE_BAD="$SAFE_BAD empty-args"
[ "$(read_override "$PROJ" "")" = "auto" ] || SAFE_BAD="$SAFE_BAD empty-session"
[ "$(read_override "" "some-key")" = "auto" ] || SAFE_BAD="$SAFE_BAD empty-project"
[ "$(read_override "$PROJ/no-such-project" "some-key")" = "auto" ] || SAFE_BAD="$SAFE_BAD missing-root"
[ -z "$SAFE_BAD" ] \
  && check "T8b the reader answers auto for every unresolvable input (never a mode)" PASS \
  || check "T8b reader fail-safe:$SAFE_BAD" FAIL

# T9 a symlinked marker is refused rather than followed — by the writer AND by the
# reader. `ln -s` exiting 0 is not evidence of a link (a host may satisfy it with a
# copy), so the link is confirmed with -L before anything is asserted; a host that
# cannot make one is reported as unsupported, not as a defect.
S_SYM="$STATE_DIR/tdd-mode-symlink-target.json"
# Seeded with the OPPOSITE mode and probed with --strict, so a write that followed
# the link would be visible in the target's own bytes.
printf '%s' '{"mode":"vanilla"}' > "$S_SYM"
MARKER_PATH="$(marker_path "$S_H")"
[ -n "$MARKER_PATH" ] || check "T9 marker path unresolvable — the probe below would test nothing" FAIL
rm -f "$MARKER_PATH"
if [ -n "$MARKER_PATH" ] && ln -s "$S_SYM" "$MARKER_PATH" 2>/dev/null && [ -L "$MARKER_PATH" ]; then
  ERR_T9="$STATE_DIR/t9.err"
  OUT_T9="$(CLAUDE_CODE_SESSION_ID="$S_H" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$PROJ" \
    ZENSU_CONFIG="$CFG_DEFAULT" bash "$HELPER" --strict 2>"$ERR_T9")"; RC_T9=$?
  { [ "$RC_T9" -eq 2 ] && [ -z "$OUT_T9" ] \
    && grep -qF 'refusing to follow a symlinked state path' "$ERR_T9" \
    && [ -L "$MARKER_PATH" ] && grep -qF '"vanilla"' "$S_SYM"; } \
    && check "T9 a symlinked marker is refused by the writer with its own message; the target is untouched" PASS \
    || check "T9 symlink refusal (rc=$RC_T9 out='$OUT_T9' err='$(cat "$ERR_T9" 2>/dev/null)')" FAIL
  [ "$(read_override "$PROJ" "$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key "$S_H")")" = "auto" ] \
    && check "T9b the reader answers auto for a symlinked marker (never follows it)" PASS \
    || check "T9b reader symlink fall-through" FAIL
  rm -f "$MARKER_PATH"
else
  check "T9 writer symlink refusal — this host cannot create a symlink to probe with" SKIP
  check "T9b reader symlink fall-through — no symlink support" SKIP
fi
rm -f "$S_SYM"

# T9d the OTHER disjuncts of the writer's guard: a symlinked state directory and,
# one component higher, a symlinked `.zensu` — plus the reader's answer for both.
# Probed against throwaway projects so the suite's own state stays intact. Each one
# gets its OWN registered session: the helper binds Session Control BEFORE it reaches
# the guard, so an unregistered project would refuse for the wrong reason.
sym_session() {  # $1 project, $2 session id -> registers a baseline in that project
  ( export CLAUDE_PROJECT_DIR="$1"
    # shellcheck disable=SC1091
    source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$2" ) >/dev/null 2>&1
}
writer_refuses() {  # $1 project, $2 session id
  local project="$1" sid="$2" err
  err="$(CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$project/.session-control-test/plugin-data" CLAUDE_PROJECT_DIR="$project" \
    ZENSU_CONFIG="$CFG_DEFAULT" bash "$HELPER" --strict 2>&1 >/dev/null)"
  printf '%s' "$err" | grep -qF 'refusing to follow a symlinked state path'
}
SYM_PROJ="$(mktemp -d)"; SYM_SID="tddmode-sym-state"
SYM_PROJ2="$(mktemp -d)"; SYM_SID2="tddmode-sym-zensu"
sym_session "$SYM_PROJ" "$SYM_SID"
sym_session "$SYM_PROJ2" "$SYM_SID2"
mkdir -p "$SYM_PROJ/real-state" "$SYM_PROJ/.zensu" "$SYM_PROJ2/real-zensu"
rm -rf "$SYM_PROJ/.zensu/state"
mv "$SYM_PROJ2/.zensu" "$SYM_PROJ2/real-zensu-moved" 2>/dev/null || true
if ln -s "$SYM_PROJ/real-state" "$SYM_PROJ/.zensu/state" 2>/dev/null && [ -L "$SYM_PROJ/.zensu/state" ] \
  && ln -s "$SYM_PROJ2/real-zensu" "$SYM_PROJ2/.zensu" 2>/dev/null && [ -L "$SYM_PROJ2/.zensu" ]; then
  SYM_BAD=""
  [ "$(read_override "$SYM_PROJ" "any-key")" = "auto" ] || SYM_BAD="$SYM_BAD reader-state-dir"
  [ "$(read_override "$SYM_PROJ2" "any-key")" = "auto" ] || SYM_BAD="$SYM_BAD reader-zensu-dir"
  # The WRITER half: without these two calls the state-dir and `.zensu` disjuncts of
  # its guard are dead — T9 plants its link at the marker leaf, so the surviving
  # marker disjunct alone would keep the suite green.
  writer_refuses "$SYM_PROJ" "$SYM_SID" || SYM_BAD="$SYM_BAD writer-state-dir"
  writer_refuses "$SYM_PROJ2" "$SYM_SID2" || SYM_BAD="$SYM_BAD writer-zensu-dir"
  [ -z "$(find "$SYM_PROJ/real-state" "$SYM_PROJ2/real-zensu" -type f 2>/dev/null)" ] \
    || SYM_BAD="$SYM_BAD wrote-through-link"
  [ -z "$SYM_BAD" ] \
    && check "T9d writer AND reader refuse a symlinked state dir and a symlinked .zensu; nothing is written through the link" PASS \
    || check "T9d directory-symlink guard:$SYM_BAD" FAIL
else
  check "T9d symlinked state/.zensu directory — no symlink support" SKIP
fi
rm -rf "$SYM_PROJ" "$SYM_PROJ2"

# T9e a marker path that exists as a DIRECTORY: `mv -f` would move the temp file
# into it and report success, so the user would be told a choice landed that the
# reader can never see. Refused before the rename, with no temp left behind.
DIR_PROJ="$(mktemp -d)"
DIR_SID="tddmode-dirmarker-$$"
DIR_OUT=""; DIR_ERR=""; DIR_RC=0
(
  export CLAUDE_PROJECT_DIR="$DIR_PROJ"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$DIR_SID"
) >/dev/null 2>&1
DIR_MARKER="$(CLAUDE_PROJECT_DIR="$DIR_PROJ" bash -c 'source "$0"; zensu_tdd_mode_marker_path "$1" "$2"' \
  "$CONFIG_LIB" "$DIR_PROJ" "$(node "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" session-key "$DIR_SID")")"
mkdir -p "$DIR_MARKER"
DIR_ERR="$(CLAUDE_CODE_SESSION_ID="$DIR_SID" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PLUGIN_DATA="$DIR_PROJ/.session-control-test/plugin-data" CLAUDE_PROJECT_DIR="$DIR_PROJ" \
  ZENSU_CONFIG="$CFG_DEFAULT" bash "$HELPER" --strict 2>&1 >/dev/null)"; DIR_RC=$?
DIR_TMP="$(find "$(dirname "$DIR_MARKER")" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | grep -c . || true)"
{ [ "$DIR_RC" -eq 2 ] && printf '%s' "$DIR_ERR" | grep -qF 'is not a regular file' \
  && [ "$DIR_TMP" = "0" ] && [ -z "$(find "$DIR_MARKER" -type f 2>/dev/null)" ]; } \
  && check "T9e a marker path that is a directory is refused before the rename, leaving no temp" PASS \
  || check "T9e non-regular marker (rc=$DIR_RC tmp=$DIR_TMP err='${DIR_ERR:0:70}')" FAIL
rm -rf "$DIR_PROJ"

# T9f the accepted gap, pinned rather than left implicit: while no chain is armed the
# PreToolUse edit gate passes an Edit of the marker through. CLAUDE.md documents this
# as narrowed-not-closed; pinning today's verdict makes any change to it deliberate.
GAP_PAYLOAD="$(SIDV="$S_H" MARKERV="$(marker_path "$S_H")" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PreToolUse", tool_name:"Edit",
    tool_input:{file_path:process.env.MARKERV}, session_id:process.env.SIDV
  }));')"
GAP_OUT="$(printf '%s' "$GAP_PAYLOAD" | ZENSU_CONFIG="$CFG_DEFAULT" bash "$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh" 2>/dev/null)"
case "$GAP_OUT" in
  *'"permissionDecision":"deny"'*) check "T9f the edit gate now DENIES an inactive-chain write to the marker — CLAUDE.md's narrowed-not-closed note is stale" FAIL ;;
  *) check "T9f documented gap holds: with no armed chain the edit gate passes a marker write through" PASS ;;
esac


toggle tddmode-iso-a --strict >/dev/null
ST_ISO_A="$(toggle tddmode-iso-a --status)"
ST_ISO_B="$(toggle tddmode-iso-b --status)"
{ [ "$ST_ISO_A" = "strict (session)" ] && [ "$ST_ISO_B" = "vanilla (config)" ]; } \
  && check "T10 the choice is session-scoped; one session cannot set another's mode" PASS \
  || check "T10 session isolation (A='$ST_ISO_A' B='$ST_ISO_B')" FAIL

echo "== Begin: precedence at the freeze point =="
S_FS="tddmode-flag-strict"
activate_session "$S_FS"
OUT_T11="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$S_FS" --tdd-mode strict 2>/dev/null)"
{ [ "$OUT_T11" = "mode: strict" ] && [ "$(vanilla_flag "$S_FS")" = "false" ]; } \
  && check "T11 --tdd-mode strict outranks tddImplementation:false and freezes strict" PASS \
  || check "T11 caller flag strict (got '$OUT_T11' flag=$(vanilla_flag "$S_FS"))" FAIL

# T12 the caller channel is ESCALATION-ONLY. The value travels through a
# `TDD-MODE:` line in a model-read specification, and /zensu:pr-fix-findings builds
# that specification out of PR review-comment bodies — text a commenter controls. An
# accepted `vanilla` there would relax a project that set tddImplementation:true,
# with no bypass-ledger entry. Refusal must be total, not merely ignored.
S_FV="tddmode-flag-vanilla"
activate_session "$S_FV"
ERR_T12="$STATE_DIR/t12.err"
OUT_T12="$(ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$S_FV" --tdd-mode vanilla 2>"$ERR_T12")"; RC_T12=$?
ACT_T12="$(tdd_session_active "$(tdd_state_file "$S_FV")")"
{ [ "$RC_T12" -eq 2 ] && [ -z "$OUT_T12" ] && [ "$ACT_T12" != "true" ] \
  && grep -qF "accepts only 'strict'" "$ERR_T12"; } \
  && check "T12 --tdd-mode vanilla is refused: a caller may raise the discipline, never lower it" PASS \
  || check "T12 caller flag vanilla (rc=$RC_T12 out='$OUT_T12' active=$ACT_T12)" FAIL
# T12b the positive control for the same run shape: the accepted value still arms.
OUT_T12B="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$S_FV" --tdd-mode strict 2>/dev/null)"
[ "$OUT_T12B" = "mode: strict" ] \
  && check "T12b the same session arms strict through the accepted value (control)" PASS \
  || check "T12b caller flag strict control (got '$OUT_T12B')" FAIL

S_SS="tddmode-session-strict"
toggle "$S_SS" --strict >/dev/null
activate_session "$S_SS"
OUT_T13="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$S_SS" 2>/dev/null)"
{ [ "$OUT_T13" = "mode: strict" ] && [ "$(vanilla_flag "$S_SS")" = "false" ]; } \
  && check "T13 a strict session marker outranks tddImplementation:false with no flag" PASS \
  || check "T13 session marker vs config (got '$OUT_T13')" FAIL

# T14 is the bite the whole toggle exists for: the user's own choice must survive a
# skill that asks for the opposite. /zensu:pr-fix-findings passes strict; a user who
# ran `--vanilla` still gets vanilla.
S_SV="tddmode-session-vanilla"
toggle "$S_SV" --vanilla >/dev/null
activate_session "$S_SV"
OUT_T14="$(ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$S_SV" --tdd-mode strict 2>/dev/null)"
{ [ "$OUT_T14" = "mode: vanilla" ] && [ "$(vanilla_flag "$S_SV")" = "true" ]; } \
  && check "T14 a vanilla session marker outranks a caller's --tdd-mode strict" PASS \
  || check "T14 session marker vs caller flag (got '$OUT_T14')" FAIL

# T14b the other direction of rank 1 over rank 3: a vanilla marker beats a STRICT
# config with no flag in play. T7 proves this at `--status`; this proves it lands in
# the frozen flag, which is what the edit gate actually reads.
S_SV2="tddmode-session-vanilla-strictcfg"
toggle "$S_SV2" --vanilla "$CFG_STRICT" >/dev/null
activate_session "$S_SV2"
OUT_T14B="$(ZENSU_CONFIG="$CFG_STRICT" bash "$LOG" --tdd-begin --session "$S_SV2" 2>/dev/null)"
{ [ "$OUT_T14B" = "mode: vanilla" ] && [ "$(vanilla_flag "$S_SV2")" = "true" ]; } \
  && check "T14b a vanilla session marker outranks tddImplementation:true" PASS \
  || check "T14b marker vs strict config (got '$OUT_T14B')" FAIL

S_AUTO="tddmode-auto"
toggle "$S_AUTO" --auto >/dev/null
activate_session "$S_AUTO"
OUT_T15="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$S_AUTO" --tdd-mode strict 2>/dev/null)"
[ "$OUT_T15" = "mode: strict" ] \
  && check "T15 an auto marker releases the decision back to the caller flag" PASS \
  || check "T15 auto marker falls through (got '$OUT_T15')" FAIL

S_DEF="tddmode-default"
activate_session "$S_DEF"
OUT_T16="$(ZENSU_CONFIG="$CFG_DEFAULT" bash "$LOG" --tdd-begin --session "$S_DEF" 2>/dev/null)"
[ "$OUT_T16" = "mode: vanilla" ] \
  && check "T16 no marker, no flag, no config key still freezes vanilla (control)" PASS \
  || check "T16 default control (got '$OUT_T16')" FAIL

echo "== Begin: flag validation and per-verb rejection =="
S_REJ="tddmode-reject"
activate_session "$S_REJ"
OUT_T17="$(ZENSU_CONFIG="$CFG_VANILLA" bash "$LOG" --tdd-begin --session "$S_REJ" --tdd-mode strictish 2>/dev/null)"; RC_T17=$?
# SessionStart already minted the workflow document, so "armed nothing" is the
# `active` flag staying false — not the file's absence.
ACT_T17="$(tdd_session_active "$(tdd_state_file "$S_REJ")")"
{ [ "$RC_T17" -eq 2 ] && [ -z "$OUT_T17" ] && [ "$ACT_T17" != "true" ]; } \
  && check "T17 an unknown --tdd-mode value exits 2 and arms nothing" PASS \
  || check "T17 invalid value (rc=$RC_T17 out='$OUT_T17' active=$ACT_T17)" FAIL

# T18 the rejection must be THIS rejection: several of these verbs exit 2 for
# unrelated reasons against an inactive chain, so a bare status check would pass
# without the flag ever being examined. The verb list is also pinned against the
# parser's own list, so a verb added later cannot go silently uncovered.
REJ_MSG="option is not valid for this verb"
REJ_BAD=""
REJ_VERBS="--tdd-complete --review-ticket --current-review-ticket --review-rearm
--chain-done --code-review-done --self-review-fixed --tdd-reset
--chain-status --chain-recover --workflow-end --workflow-begin"
for V in $REJ_VERBS; do
  if [ "$V" = "--workflow-begin" ]; then
    ERR_V="$(bash "$LOG" "$V" --session "$S_REJ" --tools Bash --tdd-mode strict 2>&1 >/dev/null)"
  else
    ERR_V="$(bash "$LOG" "$V" --session "$S_REJ" --tdd-mode strict 2>&1 >/dev/null)"
  fi
  printf '%s' "$ERR_V" | grep -qF "$REJ_MSG" || REJ_BAD="$REJ_BAD $V"
done
# Control: the same verb WITHOUT the flag must not emit that message, so the check
# above cannot be satisfied by an unrelated refusal.
CTRL_T18="$(bash "$LOG" --chain-status --session "$S_REJ" 2>&1 >/dev/null)"
printf '%s' "$CTRL_T18" | grep -qF "$REJ_MSG" && REJ_BAD="$REJ_BAD control-emits-same-message"
# Every chain verb the parser accepts, minus the one that owns the flag, must be
# covered by the loop above.
PARSER_VERBS="$(awk '/^ *--tdd-begin\|--tdd-complete\|/ { gsub(/^ +| *\)$/,""); print; exit }' "$LOG" | tr '|' '\n' | grep -v '^--tdd-begin$')"
PARSER_VERB_N="$(printf '%s\n' "$PARSER_VERBS" | grep -c .)"
# An extraction that silently matched nothing would make the loop below vacuous —
# exactly the failure the repo's own W164 verb-count pin exists to catch. The
# literal is what catches a REMOVED verb; the loop catches an added one.
[ "$PARSER_VERB_N" = "12" ] || REJ_BAD="$REJ_BAD parser-verbs=$PARSER_VERB_N(expected 12)"
for V in $PARSER_VERBS; do
  printf '%s\n' $REJ_VERBS | grep -Fxq -- "$V" || REJ_BAD="$REJ_BAD uncovered:$V"
done
[ -z "$REJ_BAD" ] \
  && check "T18 --tdd-mode is rejected with its own message on every chain verb except --tdd-begin" PASS \
  || check "T18 verbs that accepted --tdd-mode:$REJ_BAD" FAIL

# Both values ACCEPTED, so only the duplicate guard can produce the refusal — a
# `strict vanilla` probe would still exit 2 through the escalation-only check.
ERR_T19="$STATE_DIR/t19.err"
bash "$LOG" --tdd-begin --session "$S_REJ" --tdd-mode strict --tdd-mode strict >/dev/null 2>"$ERR_T19"
RC_T19=$?
{ [ "$RC_T19" -eq 2 ] && grep -qF 'duplicate/missing --tdd-mode' "$ERR_T19"; } \
  && check "T19 a duplicate --tdd-mode exits 2 with the duplicate message" PASS \
  || check "T19 duplicate flag (rc=$RC_T19 err='$(cat "$ERR_T19" 2>/dev/null)')" FAIL

# Returns the child's status in NO_HANG_RC so a caller can assert the REFUSAL, not
# merely that the process came back: an implementation that treated a dangling flag
# as absent and armed the chain would also terminate.
NO_HANG_RC=""
no_hang() {
  bash "$LOG" "$@" >/dev/null 2>&1 &
  local pid=$!
  local hung=1 i=0
  while [ "$i" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || { hung=0; break; }
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i+1))
  done
  [ "$hung" = "1" ] && kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  NO_HANG_RC=$?
  [ "$hung" = "0" ]
}
no_hang --tdd-begin --session "$S_REJ" --tdd-mode
HUNG_T20=$?
ACT_T20="$(tdd_session_active "$(tdd_state_file "$S_REJ")")"
{ [ "$HUNG_T20" -eq 0 ] && [ "$NO_HANG_RC" -eq 2 ] && [ "$ACT_T20" != "true" ]; } \
  && check "T20 a dangling --tdd-mode terminates, exits 2, and arms nothing" PASS \
  || check "T20 dangling --tdd-mode (hung=$HUNG_T20 rc=$NO_HANG_RC active=$ACT_T20)" FAIL

echo "== Consumers: effective mode vs configured mode =="
# The advisory hooks must name the discipline the NEXT chain will actually arm.
S_W="tddmode-wording"
toggle "$S_W" --strict >/dev/null
CTX_T21="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"add a helper function"}' "$S_W" \
  | hook_ctx "$REMINDER" "$CFG_VANILLA")"
case "$CTX_T21" in
  *"strict TDD flow"*) check "T21 the prompt reminder follows the session choice, not the config" PASS ;;
  *) check "T21 reminder wording under a strict session marker (got: ${CTX_T21:0:60})" FAIL ;;
esac
toggle "$S_W" --auto >/dev/null
CTX_T21B="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"add a helper function"}' "$S_W" \
  | hook_ctx "$REMINDER" "$CFG_VANILLA")"
case "$CTX_T21B" in
  *"vanilla implementation mode"*) check "T21b released, the reminder is back on the configured mode" PASS ;;
  *) check "T21b reminder wording after --auto (got: ${CTX_T21B:0:60})" FAIL ;;
esac

# T22 the plan-approval directive, driven for real. A name grep alone would still
# match if the call lost its arguments, and `zensu_tdd_strict_effective` with empty
# arguments silently degrades to config-only.
S_PL="tddmode-plan"
toggle "$S_PL" --strict >/dev/null
CTX_T22="$(printf '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","session_id":"%s"}' "$S_PL" \
  | hook_ctx "$PLANHOOK" "$CFG_VANILLA")"
case "$CTX_T22" in
  *"strict TDD flow"*) check "T22 the plan-approval directive follows the session choice, not the config" PASS ;;
  *) check "T22 plan-approval wording under a strict session marker (got: ${CTX_T22:0:60})" FAIL ;;
esac
toggle "$S_PL" --auto >/dev/null
CTX_T22B="$(printf '{"hook_event_name":"PostToolUse","tool_name":"ExitPlanMode","session_id":"%s"}' "$S_PL" \
  | hook_ctx "$PLANHOOK" "$CFG_VANILLA")"
case "$CTX_T22B" in
  *"Vanilla implementation mode is in effect for this session"*)
    check "T22b released, plan-approval is back on the configured mode" PASS ;;
  *) check "T22b released, plan-approval vanilla directive (got: ${CTX_T22B:0:60})" FAIL ;;
esac

CONS_BAD=""
for F in "$PLANHOOK" "$REMINDER" "$STOP"; do
  grep -qF 'zensu_tdd_strict_effective' "$F" || CONS_BAD="$CONS_BAD $(basename "$F")"
done
# The Stop seed is the behavioral one and it must pass a REAL project dir and
# session key — an argument-less call would compile, match this grep, and quietly
# resolve config-only.
grep -qF 'zensu_tdd_strict_effective "$PROJECT_ROOT" "${ZENSU_SESSION_KEY:-}"' "$STOP" \
  || CONS_BAD="$CONS_BAD stop-seed-args"
[ -z "$CONS_BAD" ] \
  && check "T22c plan-approval, prompt reminder and Stop seed read the effective mode with real arguments" PASS \
  || check "T22c consumers still on the configured mode:$CONS_BAD" FAIL

# T23 SessionStart is the deliberate exception: no marker for a session that is
# only now starting can exist, so those two stay config-only. Pinning it keeps a
# later "consistency" edit from inventing a read that can never hit.
if grep -qF 'zensu_tdd_strict_enabled' "$BANNER" && grep -qF 'zensu_tdd_strict_enabled' "$PRIMER" \
  && ! grep -qF 'zensu_tdd_strict_effective' "$BANNER" && ! grep -qF 'zensu_tdd_strict_effective' "$PRIMER"; then
  check "T23 SessionStart banner + primer stay config-only (no marker can exist yet)" PASS
else
  check "T23 SessionStart hooks changed mode source" FAIL
fi

# T28 the writer leaves no temp file behind, and creates its state directory 0700
# when it does not exist yet. `marker_count` cannot see a leaked `*.json.tmp.*`, so
# the leak needs its own probe.
TMP_LEFT="$(find "$STATE_DIR" -maxdepth 1 -name 'tdd-mode-*.json.tmp.*' 2>/dev/null | grep -c . || true)"
FRESH_PROJ="$(mktemp -d)"
FRESH_SID="tddmode-fresh-$$"
(
  export CLAUDE_PROJECT_DIR="$FRESH_PROJ"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$FRESH_SID"
  CLAUDE_CODE_SESSION_ID="$FRESH_SID" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$FRESH_PROJ" \
    ZENSU_CONFIG="$CFG_DEFAULT" bash "$HELPER" --strict >/dev/null 2>&1
) >/dev/null 2>&1
FRESH_MODE="$(ls -ld "$FRESH_PROJ/.zensu/state" 2>/dev/null | cut -c1-10)"
FRESH_TMP="$(find "$FRESH_PROJ/.zensu/state" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | grep -c . || true)"
{ [ "$TMP_LEFT" = "0" ] && [ "$FRESH_TMP" = "0" ] && [ "$FRESH_MODE" = "drwx------" ]; } \
  && check "T28 the writer leaves no temp file behind and creates the state dir 0700" PASS \
  || check "T28 temp/mode (suite_leftovers=$TMP_LEFT fresh_leftovers=$FRESH_TMP mode='$FRESH_MODE')" FAIL
rm -rf "$FRESH_PROJ"

# T29 the config getters see the BOUND project, not an ambient CLAUDE_PROJECT_DIR.
# Without the helper's own export, `--status` would report a decoy project's config
# — a file `--tdd-begin` will never consult. ZENSU_CONFIG is deliberately unset
# here: it is a full override and would mask the overlay this check is about.
DECOY="$(mktemp -d)"; mkdir -p "$DECOY/.zensu" "$PROJ/.zensu"
printf '%s' '{"hooks":{"tddImplementation":false}}' > "$DECOY/.zensu/config.json"
printf '%s' '{"hooks":{"tddImplementation":true}}' > "$PROJ/.zensu/config.json"
toggle "$S_H" --auto >/dev/null
ST_T29="$(env -u ZENSU_CONFIG CLAUDE_CODE_SESSION_ID="$S_H" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$DECOY" \
  HOME="$DECOY" bash "$HELPER" --status 2>/dev/null)"
[ "$ST_T29" = "strict (config)" ] \
  && check "T29 --status reads the bound project's config, not an ambient CLAUDE_PROJECT_DIR" PASS \
  || check "T29 status config anchoring (got '$ST_T29')" FAIL
rm -rf "$DECOY" "$PROJ/.zensu/config.json"

echo "== Skill contracts =="
# Anchored on the implementation step that owns the contract, not on a substring
# the untrusted-input paragraph would also satisfy: the carrier and the stripping
# rule are separate obligations and both have to be present.
FIX_STEP="$(awk '/^4\. \*\*Implement each fix/ { inside=1 } inside { print } inside && /^5\. \*\*Land the changes/ { exit }' "$FIX_SKILL")"
FIX_BAD=""
[ -n "$FIX_STEP" ] || FIX_BAD="$FIX_BAD no-step"
for LIT in 'TDD-MODE: strict' 'untrusted input' 'strip it' '/zensu:tdd-mode'; do
  printf '%s' "$FIX_STEP" | grep -qF -- "$LIT" || FIX_BAD="$FIX_BAD ${LIT// /_}"
done
[ -z "$FIX_BAD" ] \
  && check "T24 /zensu:pr-fix-findings carries TDD-MODE: strict and treats a spec-borne TDD-MODE line as untrusted" PASS \
  || check "T24 pr-fix-findings strict default:$FIX_BAD" FAIL

if grep -qF 'TDD-MODE: strict' "$TDD_SKILL" && grep -qF -- '--tdd-mode strict' "$TDD_SKILL" \
  && grep -qiF 'escalation-only' "$TDD_SKILL"; then
  check "T25 /zensu:tdd documents the TDD-MODE carrier, the flag, and that it is escalation-only" PASS
else
  check "T25 /zensu:tdd carrier contract missing" FAIL
fi

SKILL_BAD=""
for LIT in '--strict' '--vanilla' '--auto' '--status' 'zensu-tdd-mode.sh' 'CLAUDE_PLUGIN_DATA'; do
  grep -qF -- "$LIT" "$SKILL" || SKILL_BAD="$SKILL_BAD $LIT"
done
# The literals alone would survive a skill that rendered a WRONG path or dropped the
# mandatory data prefix, so the rendered command lines are extracted and resolved:
# every one must name this helper and carry the prefix the helper demands.
RENDERED="$(grep -F 'zensu-tdd-mode.sh' "$SKILL" | grep -F 'bash ')"
[ -n "$RENDERED" ] || SKILL_BAD="$SKILL_BAD no-rendered-command"
RENDER_N=0
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  RENDER_N=$((RENDER_N+1))
  case "$LINE" in
    'CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-mode.sh" '*) ;;
    *) SKILL_BAD="$SKILL_BAD bad-render" ;;
  esac
done <<RENDERED_EOF
$RENDERED
RENDERED_EOF
[ "$RENDER_N" -ge 3 ] || SKILL_BAD="$SKILL_BAD rendered=$RENDER_N(expected>=3)"
# ...and the path those lines name must be the file this suite drives.
[ "$PLUGIN_DIR/hooks/lib/zensu-tdd-mode.sh" = "$HELPER" ] || SKILL_BAD="$SKILL_BAD helper-path-drift"
[ -z "$SKILL_BAD" ] \
  && check "T26 the tdd-mode skill renders every verb, the mandatory data prefix, and this exact helper path" PASS \
  || check "T26 tdd-mode skill:$SKILL_BAD" FAIL

# T27 the two properties a user gets wrong first: what outranks what, and that a
# running chain keeps the mode it froze. Anchored on the section that carries them,
# not on free-floating substrings the frontmatter also satisfies — deleting the
# whole `## Precedence` block must fail this check.
PREC_BLOCK="$(awk '/^## Precedence$/ { inside=1; next } inside && /^## / { exit } inside { print }' "$SKILL")"
PREC_BAD=""
[ -n "$PREC_BLOCK" ] || PREC_BAD="$PREC_BAD no-section"
for LIT in 'this session'"'"'s marker' 'hooks.tddImplementation' 'outranks' 'NEXT chain' 'escalation'; do
  printf '%s' "$PREC_BLOCK" | grep -qiF -- "$LIT" || PREC_BAD="$PREC_BAD ${LIT// /_}"
done
[ -z "$PREC_BAD" ] \
  && check "T27 the ## Precedence section states the ranks, the escalation-only rule and the freeze caveat" PASS \
  || check "T27 precedence section incomplete:$PREC_BAD" FAIL

echo "----"
echo "test-tdd-mode-toggle: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
[ "$FAIL" -eq 0 ]
