#!/bin/bash
set -u

# Pins the zen-mode focused response mode: the state helper
# (hooks/lib/zensu-zen-mode.sh), the UserPromptSubmit re-injection hook
# (hooks/user-prompt-zen-mode.sh), and the skill contract
# (skills/zen-mode/SKILL.md).
#
# The properties that make the mode trustworthy are pinned behaviorally: the mode
# resolves marker-first and falls back to hooks.zenModeDefault (default TRUE), an
# explicit off is RECORDED rather than deleted so the true default cannot silently
# undo it, and deactivation is performed by the HOOK (not the model), so an
# off-phrase still works after the model has drifted away from the mode.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-zen-mode.sh"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-zen-mode.sh"
SKILL="$PLUGIN_DIR/skills/zen-mode/SKILL.md"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
CONTROL_TMP="$(mktemp -d -t zenmode-control-XXXXXX)"
NO_CONFIG="$CONTROL_TMP/no-such-config.json"
CFG_DEFAULT_OFF="$CONTROL_TMP/default-off.json"
printf '%s' '{"hooks":{"zenModeDefault":false}}' > "$CFG_DEFAULT_OFF"
export CLAUDE_PLUGIN_DATA="$CONTROL_TMP/plugin-data"
mkdir -p "$CLAUDE_PLUGIN_DATA"
trap 'rm -rf "$CONTROL_TMP"' EXIT

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

# AN ENVIRONMENT SKIP IS NOT A PASS. Five arms in this file recorded one as PASS -
# `mkfifo` unavailable, hard links unavailable, running as root - so a host that
# cannot build those fixtures reported green while the property went unmeasured,
# which is exactly what this file already forbids for Z29. The count reaches the
# summary line, so the difference is visible without reading the body.
SKIP=0
skipcheck() {
  local label="$1"
  echo "  SKIP  $label"
  SKIP=$((SKIP+1))
}

if [ ! -f "$HOOK" ] || [ ! -f "$HELPER" ] || [ ! -f "$SKILL" ]; then
  check "Z0 hook + helper + SKILL.md all exist" FAIL
  echo "----"
  echo "test-zen-mode: $PASS PASS / $FAIL FAIL"
  exit 1
fi

[ -x "$HOOK" ] && check "Z1 hook exists + executable" PASS || check "Z1 hook exists + executable" FAIL
[ -x "$HELPER" ] && check "Z2 helper exists + executable" PASS || check "Z2 helper exists + executable" FAIL

bash -n "$HOOK" 2>/dev/null && check "Z3 hook bash -n syntax check passes" PASS || check "Z3 hook bash -n syntax check passes" FAIL
bash -n "$HELPER" 2>/dev/null && check "Z4 helper bash -n syntax check passes" PASS || check "Z4 helper bash -n syntax check passes" FAIL

# Z5 registered in hooks.json under UserPromptSubmit
if node -e '
  const h=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const ups=(h.hooks.UserPromptSubmit||[]).flatMap(x=>x.hooks||[]).map(z=>z.command||"");
  process.exit(ups.some(c=>/user-prompt-zen-mode\.sh/.test(c))?0:1);
' "$HOOKS_JSON" 2>/dev/null; then
  check "Z5 registered in hooks.json UserPromptSubmit" PASS
else
  check "Z5 registered in hooks.json UserPromptSubmit" FAIL
fi

# Z6 skill registered in plugin.json
if node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit((p.skills||[]).includes("./skills/zen-mode")?0:1);
' "$PLUGIN_JSON" 2>/dev/null; then
  check "Z6 ./skills/zen-mode registered in plugin.json" PASS
else
  check "Z6 ./skills/zen-mode registered in plugin.json" FAIL
fi

# Z7 config-gated by hooks.zenMode
grep -qF 'zensu_hook_enabled zenMode' "$HOOK" \
  && check "Z7 gated by hooks.zenMode (zensu_hook_enabled zenMode)" PASS \
  || check "Z7 gated by hooks.zenMode (zensu_hook_enabled zenMode)" FAIL

# Z7b the session default is read through the dedicated getter, never folded into
# zensu_hook_enabled — that helper answers "may this hook run at all", which is a
# different question with a different marker consequence
if grep -qF 'zensu_zen_mode_default_on' "$HOOK" \
  && grep -qF 'zensu_zen_mode_default_on' "$PLUGIN_DIR/hooks/lib/zensu-config.sh" \
  && ! grep -qF 'zensu_hook_enabled zenModeDefault' "$HOOK"; then
  check "Z7b session default resolved via zensu_zen_mode_default_on (hooks.zenModeDefault)" PASS
else
  check "Z7b session default getter missing or folded into zensu_hook_enabled" FAIL
fi

# Z8 marker lives under the gitignored ephemeral state dir. The directory and the
# file stem are matched separately because both files now build the path in two
# steps — the state dir is needed on its own for the symlink guard and the mkdir.
Z8_BAD=""
for F8 in "$HOOK" "$HELPER"; do
  grep -qF '.zensu/state' "$F8" || Z8_BAD="$Z8_BAD $(basename "$F8"):state-dir"
  grep -qF '/zen-mode-' "$F8" || Z8_BAD="$Z8_BAD $(basename "$F8"):marker-stem"
done
[ -z "$Z8_BAD" ] && check "Z8 marker path is .zensu/state/zen-mode-<session> (gitignored, ephemeral)" PASS \
  || check "Z8 marker path wrong:$Z8_BAD" FAIL

# ── Behavioral helpers ───────────────────────────────────────────────
# Creates the Session Control record the helper and hook both bind against.
new_session() {
  local project="$1" session_id="$2"
  node -e 'process.stdout.write(JSON.stringify({
    hook_event_name:"SessionStart", source:"startup",
    session_id:process.argv[1], cwd:process.argv[2]
  }))' "$session_id" "$project" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
      env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null
}
# helper <project> <session_id> <verb> [config]
# ZENSU_CONFIG is always pinned so --status resolves its default against the test's
# own config, never against whatever ~/.zensu/config.json the developer happens to
# have.
helper() {
  CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$1" \
    ZENSU_CONFIG="${4:-$NO_CONFIG}" \
    bash "$HELPER" "$3" 2>/dev/null
}
# fire <project> <session_id> <prompt> [config] [agent_type]
fire() {
  node -e '
    const p={hook_event_name:"UserPromptSubmit",session_id:process.argv[1],prompt:process.argv[2]};
    if(process.argv[3])p.agent_type=process.argv[3];
    process.stdout.write(JSON.stringify(p));
  ' "$2" "$3" "${5:-}" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$1" \
      ZENSU_CONFIG="${4:-$NO_CONFIG}" bash "$HOOK" 2>"${ZEN_ERRFILE:-/dev/null}"
}
# The same invocation with the channels swapped: stdout dropped, stderr captured.
# `fire` discards stderr, so nothing above can observe a disclosure line, which
# is how a fault that degrades silently stays invisible to every check.
fire_err() { # <project> <session> <prompt>  -> stderr only
  node -e '
    const p={hook_event_name:"UserPromptSubmit",session_id:process.argv[1],prompt:process.argv[2]};
    process.stdout.write(JSON.stringify(p));
  ' "$2" "$3" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$1" \
      ZENSU_CONFIG="${4:-$NO_CONFIG}" bash "$HOOK" 2>&1 >/dev/null
}
# A payload with NO `prompt` field, stderr captured. The two `payloadFault`
# classes had no executed case anywhere: every fixture above builds a
# well-formed payload carrying `prompt`, so the branches that cost the user the
# in-band `zen off` escape were pinned only by a source-level vocabulary check.
fire_noprompt_err() { # <project> <session> -> stderr only
  node -e '
    const p={hook_event_name:"UserPromptSubmit",session_id:process.argv[1]};
    process.stdout.write(JSON.stringify(p));
  ' "$2" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$1" \
      ZENSU_CONFIG="${3:-$NO_CONFIG}" bash "$HOOK" 2>&1 >/dev/null
}
# A payload with no `prompt` field, stdout captured, so the directive can be
# checked as still injected with the mode ACTIVE.
fire_noprompt() { # <project> <session> -> stdout only
  node -e '
    const p={hook_event_name:"UserPromptSubmit",session_id:process.argv[1]};
    process.stdout.write(JSON.stringify(p));
  ' "$2" \
    | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$1" \
      ZENSU_CONFIG="${3:-$NO_CONFIG}" bash "$HOOK" 2>/dev/null
}
# emits "EVENT|ON", "EVENT|OFF", "EMPTY" or "BADJSON"
classify() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      s=s.trim();
      if(!s){process.stdout.write("EMPTY");return;}
      try{
        const o=JSON.parse(s).hookSpecificOutput||{};
        const a=o.additionalContext||"";
        const kind=/zen-mode is ACTIVE/.test(a)?"ON":/zen-mode is now OFF/.test(a)?"OFF":"?";
        process.stdout.write((o.hookEventName||"?")+"|"+kind);
      }catch(_){process.stdout.write("BADJSON");}
    });
  '
}
marker_count() { find "$1/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' 2>/dev/null | grep -c . || true; }

# Z9 helper round-trip under an explicit zenModeDefault:false: off -> on -> off.
# --off must RECORD the choice (marker still present, resolving to off), never
# delete it: under the true default a deleted marker re-enables the mode the user
# just left.
P9="$(mktemp -d -t zenmode-XXXXXX)"; S9="z9-$$"
new_session "$P9" "$S9"
ST9A="$(helper "$P9" "$S9" --status "$CFG_DEFAULT_OFF")"
helper "$P9" "$S9" --on "$CFG_DEFAULT_OFF" >/dev/null
ST9B="$(helper "$P9" "$S9" --status "$CFG_DEFAULT_OFF")"; M9B="$(marker_count "$P9")"
helper "$P9" "$S9" --off "$CFG_DEFAULT_OFF" >/dev/null
ST9C="$(helper "$P9" "$S9" --status "$CFG_DEFAULT_OFF")"; M9C="$(marker_count "$P9")"
if [ "$ST9A" = "off" ] && [ "$ST9B" = "on" ] && [ "$M9B" = "1" ] && [ "$ST9C" = "off" ] && [ "$M9C" = "1" ]; then
  check "Z9 helper --status/--on/--off round-trip records both choices in the marker" PASS
else
  check "Z9 helper round-trip (a=$ST9A b=$ST9B/$M9B c=$ST9C/$M9C)" FAIL
fi
rm -rf "$P9"

# Z9b the marker outranks the config default in BOTH directions, so neither
# setting can override a choice the session actually made.
P9B="$(mktemp -d -t zenmode-XXXXXX)"; S9B="z9b-$$"
new_session "$P9B" "$S9B"
ST9B1="$(helper "$P9B" "$S9B" --status)"
helper "$P9B" "$S9B" --off >/dev/null
ST9B2="$(helper "$P9B" "$S9B" --status)"
helper "$P9B" "$S9B" --on "$CFG_DEFAULT_OFF" >/dev/null
ST9B3="$(helper "$P9B" "$S9B" --status "$CFG_DEFAULT_OFF")"
if [ "$ST9B1" = "on" ] && [ "$ST9B2" = "off" ] && [ "$ST9B3" = "on" ]; then
  check "Z9b explicit marker outranks zenModeDefault in both directions" PASS
else
  check "Z9b marker precedence (default-on=$ST9B1 off-marker=$ST9B2 on-marker-under-default-off=$ST9B3)" FAIL
fi
rm -rf "$P9B"

# Z9c a marker whose content is unreadable resolves to OFF, never on. An
# unparsable state file must not impose the mode on a user who may have just left
# it — the same one-directional safety the off-phrase matcher has.
P9C="$(mktemp -d -t zenmode-XXXXXX)"; S9C="z9c-$$"
new_session "$P9C" "$S9C"
helper "$P9C" "$S9C" --on >/dev/null
MARKER9C="$(find "$P9C/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
printf '%s' 'not json at all' > "$MARKER9C"
ST9C1="$(helper "$P9C" "$S9C" --status)"
OUT9C="$(fire "$P9C" "$S9C" "do a thing" | classify)"
if [ "$ST9C1" = "off" ] && [ "$OUT9C" = "EMPTY" ]; then
  check "Z9c unparsable marker resolves to off in helper and hook (never on)" PASS
else
  check "Z9c unparsable marker (status=$ST9C1 hook='$OUT9C')" FAIL
fi
rm -rf "$P9C"

# Z10 unknown verb is rejected, no marker written
P10="$(mktemp -d -t zenmode-XXXXXX)"; S10="z10-$$"
new_session "$P10" "$S10"
helper "$P10" "$S10" --bogus >/dev/null 2>&1
RC10=$?
if [ "$RC10" != "0" ] && [ "$(marker_count "$P10")" = "0" ]; then
  check "Z10 unknown verb exits non-zero and writes no marker" PASS
else
  check "Z10 unknown verb (rc=$RC10 markers=$(marker_count "$P10"))" FAIL
fi
rm -rf "$P10"

# Z11 no marker + no config -> the mode is ON, because zenModeDefault defaults to
# true. This is the shipped out-of-the-box behavior; a fresh install is low-noise
# without the user running anything.
P11="$(mktemp -d -t zenmode-XXXXXX)"; S11="z11-$$"
new_session "$P11" "$S11"
OUT11="$(fire "$P11" "$S11" "do a thing" | classify)"
ST11="$(helper "$P11" "$S11" --status)"
if [ "$OUT11" = "UserPromptSubmit|ON" ] && [ "$ST11" = "on" ] && [ "$(marker_count "$P11")" = "0" ]; then
  check "Z11 no marker -> mode ON by default (zenModeDefault defaults to true, no marker written)" PASS
else
  check "Z11 default-on (hook='$OUT11' status=$ST11 markers=$(marker_count "$P11"))" FAIL
fi
rm -rf "$P11"

# Z11b hooks.zenModeDefault:false restores the opt-in behavior — no marker means
# silent, and the hook short-circuits before it ever reads the prompt.
P11B="$(mktemp -d -t zenmode-XXXXXX)"; S11B="z11b-$$"
new_session "$P11B" "$S11B"
OUT11B="$(fire "$P11B" "$S11B" "do a thing" "$CFG_DEFAULT_OFF" | classify)"
ST11B="$(helper "$P11B" "$S11B" --status "$CFG_DEFAULT_OFF")"
if [ "$OUT11B" = "EMPTY" ] && [ "$ST11B" = "off" ]; then
  check "Z11b hooks.zenModeDefault:false -> no marker means silent (opt-in restored)" PASS
else
  check "Z11b default-off (hook='$OUT11B' status=$ST11B)" FAIL
fi
rm -rf "$P11B"

# Z12 marker present -> hook injects the mode contract
P12="$(mktemp -d -t zenmode-XXXXXX)"; S12="z12-$$"
new_session "$P12" "$S12"; helper "$P12" "$S12" --on >/dev/null
OUT12="$(fire "$P12" "$S12" "do a thing" | classify)"
[ "$OUT12" = "UserPromptSubmit|ON" ] && check "Z12 marker present -> UserPromptSubmit additionalContext re-injects the contract" PASS \
  || check "Z12 marker present (got '$OUT12')" FAIL
rm -rf "$P12"

# Z13 hooks.zenMode:false -> silent even with a marker, and must NOT delete state
P13="$(mktemp -d -t zenmode-XXXXXX)"; S13="z13-$$"
new_session "$P13" "$S13"; helper "$P13" "$S13" --on >/dev/null
CFG13="$P13/config.json"; printf '%s' '{"hooks":{"zenMode":false}}' > "$CFG13"
OUT13="$(fire "$P13" "$S13" "normal mode" "$CFG13" | classify)"
if [ "$OUT13" = "EMPTY" ] && [ "$(marker_count "$P13")" = "1" ]; then
  check "Z13 hooks.zenMode:false -> silent despite marker AND leaves state untouched" PASS
else
  check "Z13 opt-out (out='$OUT13' markers=$(marker_count "$P13"))" FAIL
fi
rm -rf "$P13"

# Z14 non-main principals never receive the reminder
P14="$(mktemp -d -t zenmode-XXXXXX)"; S14="z14-$$"
new_session "$P14" "$S14"; helper "$P14" "$S14" --on >/dev/null
OUT14=""
for KIND14 in zensu:code-reviewer zensu:review-aspect zensu:zensu-plm custom-agent; do
  OUT14="${OUT14}$(fire "$P14" "$S14" "do a thing" "$NO_CONFIG" "$KIND14")"
done
[ -z "$OUT14" ] && check "Z14 reviewer/aspect/PLM/neutral subagents get no zen-mode reminder" PASS \
  || check "Z14 subagent principals (got '$OUT14')" FAIL
rm -rf "$P14"

# Z14b a SUBAGENT prompt carrying an off-phrase must not deactivate the user's mode.
# Silence alone would not catch a principal check ordered after the off-branch.
P14B="$(mktemp -d -t zenmode-XXXXXX)"; S14B="z14b-$$"
new_session "$P14B" "$S14B"; helper "$P14B" "$S14B" --on >/dev/null
OUT14B=""
for PHRASE14B in "normal mode" "stop zen" "zen off"; do
  OUT14B="${OUT14B}$(fire "$P14B" "$S14B" "$PHRASE14B" "$NO_CONFIG" "zensu:code-reviewer")"
done
if [ -z "$OUT14B" ] && [ "$(marker_count "$P14B")" = "1" ] && [ "$(helper "$P14B" "$S14B" --status)" = "on" ]; then
  check "Z14b subagent off-phrase cannot deactivate the user's mode (state survives)" PASS
else
  check "Z14b subagent deactivation (out='$OUT14B' markers=$(marker_count "$P14B"))" FAIL
fi
rm -rf "$P14B"

# Z15 the HOOK performs deactivation itself — the off choice is recorded in the
# marker (not deleted) and the OFF context is emitted
P15="$(mktemp -d -t zenmode-XXXXXX)"; S15="z15-$$"
new_session "$P15" "$S15"; helper "$P15" "$S15" --on >/dev/null
OUT15="$(fire "$P15" "$S15" "normal mode" | classify)"
M15="$(marker_count "$P15")"
ST15="$(helper "$P15" "$S15" --status)"
if [ "$OUT15" = "UserPromptSubmit|OFF" ] && [ "$M15" = "1" ] && [ "$ST15" = "off" ]; then
  check "Z15 off-phrase records the off choice in the hook (works after model drift)" PASS
else
  check "Z15 hook-side deactivation (out='$OUT15' markers=$M15 status=$ST15)" FAIL
fi
rm -rf "$P15"

# Z15b the regression the true default creates: leaving the mode when NO marker
# exists yet must stick. A hook that deleted instead of recorded would emit OFF and
# then re-enable the mode on the very next prompt, trapping the user for good.
P15B="$(mktemp -d -t zenmode-XXXXXX)"; S15B="z15b-$$"
new_session "$P15B" "$S15B"
OUT15B1="$(fire "$P15B" "$S15B" "zen off" | classify)"
OUT15B2="$(fire "$P15B" "$S15B" "do a thing" | classify)"
ST15B="$(helper "$P15B" "$S15B" --status)"
if [ "$OUT15B1" = "UserPromptSubmit|OFF" ] && [ "$OUT15B2" = "EMPTY" ] && [ "$ST15B" = "off" ]; then
  check "Z15b leaving the mode under the true default sticks across the next prompt" PASS
else
  check "Z15b off under default-on (first='$OUT15B1' next='$OUT15B2' status=$ST15B)" FAIL
fi
rm -rf "$P15B"

# Z16 every documented off-phrase deactivates
for PHRASE16 in "normal mode" "zen off" "zen-mode off" "turn off zen" "stop zen"; do
  P16="$(mktemp -d -t zenmode-XXXXXX)"; S16="z16-$$-$(printf '%s' "$PHRASE16" | tr -cd 'a-z')"
  new_session "$P16" "$S16"; helper "$P16" "$S16" --on >/dev/null
  OUT16="$(fire "$P16" "$S16" "$PHRASE16" | classify)"
  [ "$OUT16" = "UserPromptSubmit|OFF" ] \
    && check "Z16 off-phrase '$PHRASE16' deactivates" PASS \
    || check "Z16 off-phrase '$PHRASE16' (got '$OUT16')" FAIL
  rm -rf "$P16"
done

# Z16b near-misses and ordinary vocabulary must NOT deactivate. `normal mode` is
# real editor vocabulary, so it only counts as the whole prompt (SKILL.md pins the
# same promise in prose).
for PHRASE16B in "add a vim normal mode keybinding" "in normal mode the cursor moves" "normal modes are fine" "zenith offset calculation" "zen mode is nice" "$(printf 'here are my notes\nnormal mode\nend of notes')"; do
  P16B="$(mktemp -d -t zenmode-XXXXXX)"; S16B="z16b-$$-$(printf '%s' "$PHRASE16B" | tr -cd 'a-z' | cut -c1-12)"
  new_session "$P16B" "$S16B"; helper "$P16B" "$S16B" --on >/dev/null
  OUT16B="$(fire "$P16B" "$S16B" "$PHRASE16B" | classify)"
  if [ "$OUT16B" = "UserPromptSubmit|ON" ] && [ "$(marker_count "$P16B")" = "1" ]; then
    check "Z16b '$PHRASE16B' does NOT deactivate" PASS
  else
    check "Z16b '$PHRASE16B' wrongly deactivated (got '$OUT16B')" FAIL
  fi
  rm -rf "$P16B"
done

# Z17 off-phrase while the mode is already off -> silent (no noise, idempotent).
# Covered for both ways of being off: a recorded off marker, and zenModeDefault:false.
P17="$(mktemp -d -t zenmode-XXXXXX)"; S17="z17-$$"
new_session "$P17" "$S17"
helper "$P17" "$S17" --off >/dev/null
OUT17A="$(fire "$P17" "$S17" "normal mode" | classify)"
OUT17B="$(fire "$P17" "$S17" "normal mode" "$CFG_DEFAULT_OFF" | classify)"
P17D="$(mktemp -d -t zenmode-XXXXXX)"; S17D="z17d-$$"
new_session "$P17D" "$S17D"
OUT17C="$(fire "$P17D" "$S17D" "normal mode" "$CFG_DEFAULT_OFF" | classify)"
if [ "$OUT17A" = "EMPTY" ] && [ "$OUT17B" = "EMPTY" ] && [ "$OUT17C" = "EMPTY" ]; then
  check "Z17 off-phrase while already off -> silent (idempotent, marker and config paths)" PASS
else
  check "Z17 idempotent off (marker='$OUT17A' marker+cfg='$OUT17B' cfg-only='$OUT17C')" FAIL
fi
rm -rf "$P17" "$P17D"

# Z17b the helper's session-binding failure paths write no marker and exit non-zero.
# Without this, a regression falling back to a fixed unkeyed path would stay green.
P17B="$(mktemp -d -t zenmode-XXXXXX)"; S17B="z17b-$$"
new_session "$P17B" "$S17B"
BIND_BAD=""
OUT_A="$(CLAUDE_CODE_SESSION_ID="$S17B" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P17B" \
  env -u CLAUDE_PLUGIN_DATA bash "$HELPER" --on 2>/dev/null)"; RC_A=$?
[ "$RC_A" != "0" ] && [ -z "$OUT_A" ] || BIND_BAD="$BIND_BAD missing-plugin-data(rc=$RC_A)"
OUT_B="$(CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P17B" \
  env -u CLAUDE_CODE_SESSION_ID bash "$HELPER" --on 2>/dev/null)"; RC_B=$?
[ "$RC_B" != "0" ] && [ -z "$OUT_B" ] || BIND_BAD="$BIND_BAD missing-session-id(rc=$RC_B)"
[ "$(marker_count "$P17B")" = "0" ] || BIND_BAD="$BIND_BAD marker-written"
[ -z "$BIND_BAD" ] && check "Z17b helper binding failures exit non-zero and write no marker" PASS \
  || check "Z17b binding failure:$BIND_BAD" FAIL
rm -rf "$P17B"

# Z17c a symlinked marker is refused by the writer and ignored by the hook, so a
# pre-planted link cannot be truncated through --on.
#
# `ln -s` exiting 0 is not evidence of a symlink: Git Bash satisfies it with a
# copy unless MSYS is set to winsymlinks:nativestrict. The marker would then be a
# regular file, the writer would rightly accept it, and this check would fail on a
# correct implementation. Create the link through Node and confirm it with lstat.
IS_WINDOWS="$(node -p 'process.platform === "win32" ? "true" : "false"')"
make_file_symlink() {
  node -e '
    const fs=require("fs"),target=process.argv[1],link=process.argv[2];
    try {
      fs.symlinkSync(target,link,process.platform==="win32"?"file":undefined);
      process.exit(fs.lstatSync(link).isSymbolicLink()?0:1);
    } catch (_) { process.exit(1); }
  ' "$1" "$2"
}
P17C="$(mktemp -d -t zenmode-XXXXXX)"; S17C="z17c-$$"
new_session "$P17C" "$S17C"
helper "$P17C" "$S17C" --on >/dev/null
MARKER17C="$(find "$P17C/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
VICTIM17C="$P17C/victim.txt"; printf 'untouched\n' > "$VICTIM17C"
rm -f "$MARKER17C"
if make_file_symlink "$VICTIM17C" "$MARKER17C"; then
  helper "$P17C" "$S17C" --on >/dev/null 2>&1; RC17C=$?
  OUT17C="$(fire "$P17C" "$S17C" "do a thing" | classify)"
  if [ "$RC17C" != "0" ] && [ "$(cat "$VICTIM17C")" = "untouched" ] && [ "$OUT17C" = "EMPTY" ]; then
    check "Z17c symlinked marker refused by writer, ignored by hook, target untouched" PASS
  else
    check "Z17c symlink guard (rc=$RC17C victim='$(cat "$VICTIM17C")' hook='$OUT17C')" FAIL
  fi
elif [ "$IS_WINDOWS" = true ]; then
  skipcheck "Z17c symlinked marker refusal — native file symlinks are unavailable on this host"
else
  check "Z17c symlink fixture creation failed" FAIL
fi
rm -rf "$P17C"

# Z18 the recorded choice is per session — one session leaving the mode must not
# drag a sibling in the same project out of it. Under the true default the sibling
# is the one that stays ON, which is the direction that actually exercises keying:
# a shared unkeyed marker would silence both.
P18="$(mktemp -d -t zenmode-XXXXXX)"; S18A="z18a-$$"; S18B="z18b-$$"
new_session "$P18" "$S18A"; new_session "$P18" "$S18B"
helper "$P18" "$S18A" --off >/dev/null
OUT18A="$(fire "$P18" "$S18A" "do a thing" | classify)"
OUT18B="$(fire "$P18" "$S18B" "do a thing" | classify)"
if [ "$OUT18A" = "EMPTY" ] && [ "$OUT18B" = "UserPromptSubmit|ON" ]; then
  check "Z18 recorded choice is session-scoped: sibling session in same project is unaffected" PASS
else
  check "Z18 session scoping (a='$OUT18A' b='$OUT18B')" FAIL
fi
rm -rf "$P18"

# Z19 the injected reminder actually carries the contract rules it promises
P19="$(mktemp -d -t zenmode-XXXXXX)"; S19="z19-$$"
new_session "$P19" "$S19"; helper "$P19" "$S19" --on >/dev/null
RAW19="$(fire "$P19" "$S19" "do a thing")"
MISSING19=""
for FRAG19 in "recap" "first sentence" "OVERRIDES" "one next step" "ONE question" "chain-progress" "user's own language"; do
  printf '%s' "$RAW19" | grep -qiF "$FRAG19" || MISSING19="$MISSING19 '$FRAG19'"
done
[ -z "$MISSING19" ] && check "Z19 reminder carries recap/result-first/precedence/one-step/one-question/anchor/language rules" PASS \
  || check "Z19 reminder missing:$MISSING19" FAIL
rm -rf "$P19"

# Z19b the two carriers of rule 6 must describe the SAME anchor. Nothing pinned
# them against each other before: Z19/Z20 read the hook only, Z22-Z25 read
# SKILL.md only, and the Z20 comment records that the two files deliberately
# number their rules differently, so no numbering pin exists either. That was
# tolerable while the rule was one five-word literal; the chain-progress anchor
# is a rendered SHAPE, so a one-sided reword now leaves the injected reminder and
# the skill contract asking for different lines with every check still green.
# Both sides are whitespace-normalized first, exactly as test-promptfoo-zen-mode
# P8 does — SKILL.md is prose and gets rewrapped, so a line-anchored grep would
# fail on a reflow that changed no meaning.
if command -v node >/dev/null 2>&1; then
  MISS19B="$(PLUGIN_DIR="$PLUGIN_DIR" HOOK="$HOOK" SKILL="$SKILL" EVALS="$PLUGIN_DIR/evals/zen-mode-reaction/scenarios" node -e '
    const fs = require("fs");
    const path = require("path");
    const norm = (s) => s.replace(/\s+/g, " ").trim();
    const hook = fs.readFileSync(process.env.HOOK, "utf8");
    const blocks = [...hook.matchAll(/"additionalContext":\s*"((?:[^"\\]|\\.)*)"/g)]
      .map((m) => { try { return JSON.parse("\"" + m[1] + "\""); } catch (_) { return ""; } });
    const active = blocks.find((s) => s.startsWith("zen-mode is ACTIVE"));
    if (!active) { process.stdout.write("hook-has-no-ACTIVE-directive"); process.exit(0); }
    const want = norm(active);
    const bad = [];
    // The one dynamic field in the directive, and the two halves that make the
    // substitution possible at all. A carrier that lost either would emit a
    // directive whose anchor sentence names a value nothing ever fills in.
    const MARKER = "ZENSU CHAIN ANCHOR: ";
    if (!want.includes(MARKER)) bad.push("hook:directive-carries-no-anchor-marker");
    if (!active.includes("{{ZENSU_CHAIN_ANCHOR}}")) bad.push("hook:directive-carries-no-anchor-placeholder");
    // Derived from the OWNER, never re-spelled here: a grammar copy in this file
    // would drift from the module the hook actually validates against.
    let producible = [];
    try {
      const mod = require(path.join(process.env.PLUGIN_DIR, "hooks", "lib", "zen-anchor-v1.js"));
      // ONE reading per shape, PLUS the report-only positions. An earlier
      // spelling asked for two readings per shape under a `reviewed` option that
      // no longer exists; what replaced that option is the classifier REPORT as
      // the first argument, and the two outcome-dependent shapes are producible
      // only through it. Deriving from `SHAPE_POSITION` alone therefore left both
      // report-only tokens outside every producible set in this file, so a
      // carrier legitimately holding one was reported as not producible. This
      // derivation is the one that is supposed to track the owner.
      producible = mod.producibleTokens();
    } catch (_) { bad.push("anchor-module:unloadable"); }
    if (!producible.length) bad.push("anchor-module:no-producible-token");
    // The SKILL.md side is SLICED to rule 6. Comparing the whole file would let
    // rule 6 be gutted while the literals survive anywhere else in the document,
    // which is agreement about the file and not about the rule.
    const skillAll = fs.readFileSync(process.env.SKILL, "utf8");
    const from = skillAll.indexOf("**Anchor multi-step work.**");
    // The slice END must not name a DIFFERENT rule. Keying it on rule 7 title
    // meant that renaming rule 7 — an edit with nothing to do with the anchor —
    // reported the anchor slice as unlocatable, which is a misleading cause.
    // The next top-level numbered item is the boundary the content actually has.
    const nextItem = from >= 0 ? skillAll.slice(from).search(/\n\d+\. \*\*/) : -1;
    const to = from >= 0 && nextItem > 0 ? from + nextItem : -1;
    if (from < 0 || to < 0 || to <= from) bad.push("skill:rule-6-slice-not-locatable");
    const carriers = { hook: norm(active) };
    if (from >= 0 && to > from) carriers.skill = norm(skillAll.slice(from, to));
    // The eval scenarios embed this directive verbatim and are enforced
    // only by test-promptfoo-zen-mode.sh, which is a LOCAL-only suite that CI
    // never runs. That is exactly how their copies drifted unnoticed once
    // before, so this CI-run suite covers them too.
    // The roster is DERIVED, not hand-listed: a fourth scenario added to
    // evals/zen-mode-reaction/ would otherwise carry an unchecked directive copy
    // with this suite green. The floor keeps an emptied or moved directory loud.
    let scenarios = [];
    try { scenarios = fs.readdirSync(process.env.EVALS).filter((f) => f.endsWith(".yaml")).sort(); }
    catch (_) { bad.push("eval-dir:unreadable"); }
    if (scenarios.length < 5) bad.push("eval-dir:expected-at-least-5-scenarios-got-" + scenarios.length);
    // The floor above is an absolute one and cannot see the loss of a scenario
    // added AFTER it was written: deleting one together with its registration
    // used to leave a consistent smaller world in which nothing turned red, and
    // this is the ONLY CI-run check that reads this directory (the sibling that
    // compares against the config is local-only). So take the real floor from
    // the count the config REGISTERS, which rises on its own with the next
    // scenario. The sibling suite states this same reasoning at its own DERIVED
    // floor; its absolute one is stated nowhere, so do not read the reference as
    // agreement about both halves.
    let registered = 0;
    try {
      const cfgText = fs.readFileSync(path.join(process.env.EVALS, "..", "promptfooconfig.yaml"), "utf8");
      registered = (cfgText.match(/file:\/\/scenarios\/[^\s]+\.yaml/g) || []).length;
    } catch (_) { bad.push("eval-config:unreadable"); }
    // The derivation must be able to fail LOUDLY when it derives nothing. A
    // `registered > 0` conjunct here silently dropped the derived floor back to
    // the absolute one whenever the registration spelling moved: measured
    // against a fixture, deleting a scenario reported
    // `eval-dir:4-scenarios-but-config-registers-5` with an intact config and
    // reported NOTHING once the spelling changed, for the same real loss.
    //
    // The derived comparison catches an UNCOORDINATED loss only: `registered`
    // falls in lockstep with `scenarios.length`, so deleting a scenario TOGETHER
    // with its registration leaves a consistent smaller world. The absolute
    // floor is what closes that, and it is therefore the CURRENT scenario count
    // rather than a round number below it — raising it is the registration step
    // for a new scenario, exactly as `Z29_FLOOR` and `Z31_FLOOR` work.
    if (registered < 5) {
      bad.push("eval-config:registers-only-" + registered + "-the-registration-spelling-moved");
    }
    if (scenarios.length < registered) {
      bad.push("eval-dir:" + scenarios.length + "-scenarios-but-config-registers-" + registered);
    }
    // Each scenario is SLICED to its spec_block for the same reason SKILL.md is
    // sliced: a scenario carries several JavaScript assertion bodies with
    // free-text reason strings, any of which could satisfy a needle while the
    // embedded directive itself had drifted.
    for (const f of scenarios) {
      const p = path.join(process.env.EVALS, f);
      let raw;
      try { raw = fs.readFileSync(p, "utf8"); }
      catch (_) { bad.push("eval:" + f + ":unreadable"); continue; }
      const start = raw.indexOf("spec_block: |");
      if (start < 0) { bad.push("eval:" + f + ":no-spec-block"); continue; }
      const rest = raw.slice(start);
      const end = rest.search(/\n[A-Za-z_][A-Za-z0-9_]*:/);
      carriers["eval:" + f] = norm(end < 0 ? rest : rest.slice(0, end));
    }
    // One distinguishing literal per anchor requirement. State the reach
    // honestly: for the EVAL carriers this list is belt on top of a verbatim
    // comparison of the whole directive, so nothing there can be deleted
    // silently. The SKILL carrier gets no such comparison — it is sliced to
    // rule 6 and judged by these literals ALONE — so a rule-6 sentence with no
    // literal here CAN be reworded on that carrier with this check still green.
    // The rule, stated WITHOUT a per-requirement index: one distinguishing
    // literal for every clause of rule 6 that carries weight, and add one
    // whenever a clause starts carrying weight. The previous wording mapped the
    // needles onto AC-001..AC-006 of the contract this rewrite retired, and it
    // named a label-casing rule and a separator disclaimer that no longer exist
    // in any carrier — a maintainer consulting it looked for a mapping that had
    // stopped being true. An index over a list that is edited more often than
    // the comment is exactly the drift this suite exists to catch elsewhere.
    const shared = [
      "chain-progress",
      // The prefix and the marker the hook substitutes into. Every live
      // assertion in the two anchor scenarios keys on /^Zensu:/, so renaming it
      // in the hook and regenerating the copies together would once again leave
      // every structure check green while every grader became unsatisfiable.
      // The bare glyphs below stay bare on purpose: the two carriers quote them
      // differently (single quotes in the hook, backticks in the skill), and
      // their discriminating neighbours are pinned separately as "for one not
      // yet reached" and "for one that failed or is blocked".
      "Zensu:",
      "ZENSU CHAIN ANCHOR",
      // The contract itself: the line is SUPPLIED, so the model renders it and
      // never derives one. A carrier that drops either clause has reverted to
      // the previous contract, in which the anchor rendered for ad-hoc work
      // with no Zensu process behind it.
      "render that line verbatim",
      "no anchor can be justified this turn",
      "invent steps",
      "carry an anchor over from an earlier turn",
      "Zensu-driven development process",
      "never from the plan",
      "canonical pipeline",
      "✗",
      "·",
      "for a step that finished and passed",
      "for the step running now",
      "for one not yet reached",
      "for one that failed or is blocked",
      "above the closing next step",
      "when the one-next-step rule is suspended",
      "add no separate",
      "a position, not a history",
      "prose of the turn it happened in",
      // Disambiguated on purpose. The earlier wording read two ways — step
      // names are exempt from translation, or the words around the line are
      // what gets translated — and the two give a non-English reader a
      // different line. The supplied line is fixed, so only the second reading
      // survives. (No apostrophes in this block: it lives inside a
      // single-quoted node -e program, where one would end the shell string.)
      "translate only the words around",
      "spans several turns",
      "not a mark",
    ];
    // The safety carve-out travels in the SAME verbatim directive string as the
    // anchor, and the only full-fidelity check on the eval copies (P8) is
    // local-only, so CI never runs it. Without these, a reworded carve-out would
    // leave safety-carve-out.yaml — the one live-model check that a warning is
    // never compressed — grading a directive no session receives, with every CI
    // suite green. They apply ONLY to carriers that hold the WHOLE directive:
    // the SKILL carrier is sliced to rule 6, and the carve-out is rule 9.
    const wholeDirectiveOnly = [
      "EXCEPTION — for security warnings, irreversible or destructive actions",
      "full-sentence rule is NEVER suspended",
      "never treated as a routine decision you may settle yourself",
    ];
    for (const name of Object.keys(carriers)) {
      const text = carriers[name];
      // An eval carrier embeds the WHOLE directive, so the verbatim containment
      // check below already subsumes every needle: a string containing `want`
      // contains each of its substrings. Running the lists over them as well
      // proved nothing and cost legibility — one reworded clause in the hook
      // changes `want`, so a single edit emitted well over a hundred
      // missing<...> entries concatenated into one check label, from which the
      // reader had to work out that the news was "regenerate the eval copies".
      if (name.startsWith("eval:")) {
        // The directive carries exactly ONE dynamic field — the anchor token the
        // hook substitutes at emit time — so the comparison is verbatim up to
        // that marker and then asks the OWNER whether the value after it is one
        // it can produce. Comparing the whole string would fail on every
        // scenario for a reason that is not drift; skipping the tail would let a
        // scenario carry an anchor no hook could ever emit, which is exactly the
        // ungraded copy this check exists to prevent.
        const head = want.slice(0, want.indexOf(MARKER) + MARKER.length);
        if (!text.includes(head)) { bad.push(name + ":directive-not-verbatim"); continue; }
        const rest = text.slice(text.indexOf(head) + head.length).trim();
        if (!producible.some((t) => rest.startsWith(t))) {
          bad.push(name + ":anchor-token-not-producible");
        }
        // The bare-marker regression pins below still apply to every carrier.
        if (/anchor multi-step work with a .?Step N of M/.test(text)) bad.push(name + ":still-instructs-bare-marker");
        if (/Carry a .?Step N of M.? marker/.test(text)) bad.push(name + ":still-instructs-bare-marker");
        continue;
      }
      for (const s of shared) if (!text.includes(norm(s))) bad.push(name + ":missing<" + s.slice(0, 28) + ">");
      if (name !== "skill") {
        for (const s of wholeDirectiveOnly) {
          if (!text.includes(norm(s))) bad.push(name + ":missing-carve-out<" + s.slice(0, 28) + ">");
        }
      }
      // The eval carriers took their verbatim comparison in the branch above and
      // continued; what follows applies to the hook and the skill.
      //
      // The anchor REPLACED the bare marker. Every carrier still names it, but
      // only inside the prohibition — never again as the instruction.
      if (/anchor multi-step work with a .?Step N of M/.test(text)) bad.push(name + ":still-instructs-bare-marker");
      if (/Carry a .?Step N of M.? marker/.test(text)) bad.push(name + ":still-instructs-bare-marker");
    }
    // The SKILL carrier is judged by the `shared` literals ALONE, and that list
    // deliberately holds no step name — so the worked example there was a second
    // copy of the module vocabulary that nothing compared against the owner.
    // Renaming a step moved the module, the hook (which derives at runtime) and
    // every eval carrier while that one line kept teaching the old words.
    // `producible` is already derived above; one branch closes it.
    if (carriers.skill !== undefined && producible.length
        && !producible.some((t) => t !== "none" && carriers.skill.includes(norm(t)))) {
      bad.push("skill:worked-example-is-not-a-producible-anchor");
    }
    // The hook re-spells the token grammar of the module on purpose — that
    // second reader is what stops a swapped module from blessing its own bad
    // token — but nothing held the two in step. The end-to-end arm renders only
    // `▶` and `·`, so deleting `✓` or `✗` from the character class in the hook
    // degraded every affected shape to `none` with the whole suite green.
    // Extract that regex SOURCE and drive it against what the owner produces.
    // THE LOCATOR TOLERATES FLAGS, and until it did the capture below was dead
    // code advertising a property it could not deliver. Anchoring on a bare
    // `/.test(token)` meant a shipped literal carrying `i` was not LOCATED at
    // all: the check then reported `token-grammar-not-locatable` - the reason
    // for a DELETED grammar - while the widened one it was written to catch went
    // unexamined. One character class, and the flag capture becomes reachable.
    const hookReRaw = hook.match(/\/\^\(\?:none\|Zensu:[^\n]*?\/[a-z]*\.test\(token\)/);
    if (!hookReRaw) {
      bad.push("hook:token-grammar-not-locatable");
    } else {
      // THE FLAGS ARE CAPTURED, not discarded. Slicing to the closing / threw
      // them away, so adding `i` to the shipped literal widened the second
      // reader while this check kept building a flagless copy and passing.
      const hookFlags = (hookReRaw[0].match(/\/([a-z]*)\.test\(token\)$/) || [null, ""])[1];
      const lit = hookReRaw[0].slice(0, hookReRaw[0].lastIndexOf("/" + hookFlags + ".test(token)") + 1);
      let re = null;
      try { re = new RegExp(lit.slice(1, -1), hookFlags); } catch (_) { bad.push("hook:token-grammar-not-a-regex"); }
      if (re) {
        for (const t of producible) {
          if (!re.test(t)) bad.push("hook:token-grammar-rejects<" + t + ">");
        }
        // Negative control: without it the branch passes for a grammar that
        // accepts everything, which is the same blindness in the other
        // direction.
        for (const t of ["Zensu:", "Zensu: implement", "zensu: ✓implement", "Zensu: ✓Implement", "Zensu: ✓implement extra"]) {
          if (re.test(t)) bad.push("hook:token-grammar-accepts<" + t + ">");
        }
      }
    }
    // Positive sentinel: this program writes to stdout only when it FINDS
    // something, so an empty capture used to be indistinguishable from a throw
    // and reported PASS. The caller requires this exact token.
    process.stdout.write(bad.length ? bad.join(",") : "OK");
  ' 2>/dev/null)"
  RC19B=$?
  if [ "$RC19B" -ne 0 ]; then
    check "Z19b cross-carrier pin could not run (node exit $RC19B) — not an all-clear" FAIL
  elif [ "$MISS19B" = "OK" ]; then
    check "Z19b every directive carrier agrees on the chain-progress anchor (trigger, position, marks, prohibition, observation rule)" PASS
  else
    check "Z19b directive carriers disagree about the anchor: ${MISS19B:-<empty output, program produced no verdict>}" FAIL
  fi
else
  # The suite already invokes node unconditionally (Z5, Z6, new_session, classify),
  # so a nodeless host cannot reach a green run anyway. Recording a PASS here would
  # credit a check that did not execute.
  check "Z19b cross-carrier pin did not run — node is not on PATH" FAIL
fi

# Z19c the hook-directive extractor above is a hand-copy of the one P8 uses in
# test-promptfoo-zen-mode.sh. Two copies of a parser that both fail by returning
# nothing is the shape that lets a change to the hook's emission silently
# neutralize both suites, so they are pinned against each other by source.
# An earlier spelling of this check could not fail: it grepped THIS file for a
# literal that its own pattern argument contained, so the count stayed >= 1 even
# with the extractor deleted, and the regex it is named for was assigned to a
# variable nothing read. It now extracts the regex SOURCE from each suite and
# compares the strings.
# A later spelling took only the FIRST extractor range per file, which held only
# while there was one copy per file. Z30 below added a second copy to THIS file,
# and a behaviour-preserving edit to it then left this check and Z30 both green:
# the copy the pin is named for was invisible to it. `collect()` gathers EVERY
# range in every file now and the whole set must agree, so a copy added later is
# covered without editing this check. The count is reported in the verdict, and
# a file yielding none is a failure rather than an absent contribution.
if command -v node >/dev/null 2>&1; then
  MISS19C="$(A="$0" B="$PLUGIN_DIR/tests/structure/test-promptfoo-zen-mode.sh" node -e '
    const fs = require("fs");
    // Compare the WHOLE extractor statement range, not just the regex line. A
    // line-scoped comparison left the two other hand-copied halves — the
    // JSON.parse unescape and the ACTIVE selector — free to diverge, which is
    // exactly the drift this check is named for; it also reported a false red
    // when both suites were improved identically, because it pinned the current
    // spelling rather than the two copies against each other.
    // Built by concatenation so this check does not match its OWN declarations:
    // spelling either marker whole here makes the scanner report a third,
    // nonsense "copy" made of this very block. The file records the same trap
    // for an earlier spelling of Z19c.
    const FROM = "const " + "blocks = ";
    const TO = "const " + "active = ";
    // EVERY range in the file, not the first. Normalize whitespace so
    // indentation differences between the two suites are not read as a
    // divergence; the STATEMENTS are what must agree.
    const collect = (p) => {
      const src = fs.readFileSync(p, "utf8");
      const out = [];
      let a = src.indexOf(FROM);
      while (a >= 0) {
        const b = src.indexOf(TO, a);
        if (b < 0) break;
        const end = src.indexOf("\n", b);
        out.push(src.slice(a, end < 0 ? src.length : end).replace(/\s+/g, " ").trim());
        a = src.indexOf(FROM, end < 0 ? src.length : end);
      }
      return out;
    };
    const bad = [];
    const named = [["test-zen-mode", process.env.A], ["test-promptfoo-zen-mode", process.env.B]];
    const all = [];
    for (const [label, file] of named) {
      const found = collect(file);
      if (!found.length) bad.push(label + ":extractor-not-locatable");
      for (const f of found) all.push([label, f]);
    }
    // Two copies live in test-zen-mode.sh (Z19b and Z30) and one in the sibling.
    // A floor keeps a silently shrinking set from reading as agreement.
    if (all.length < 3) bad.push("only-" + all.length + "-extractor-copies-found");
    const differing = all.filter(([, f]) => f !== all[0][1]);
    if (all.length && differing.length) {
      bad.push("extractor-source-differs:" + [...new Set(differing.map(([l]) => l))].join("+"));
    }
    process.stdout.write(bad.length ? bad.join(",") : "OK");
  ' 2>/dev/null)"
  RC19C=$?
  if [ "$RC19C" -ne 0 ]; then
    check "Z19c extractor comparison could not run (node exit $RC19C) — not an all-clear" FAIL
  elif [ "$MISS19C" = "OK" ]; then
    check "Z19c every ACTIVE-directive extractor copy is identical across both zen-mode suites" PASS
  else
    check "Z19c the ACTIVE-directive extractor has diverged: ${MISS19C:-<empty output, program produced no verdict>}" FAIL
  fi
else
  check "Z19c extractor comparison did not run — node is not on PATH" FAIL
fi

# Z19d docs/configuration.md carries the anchor for OPERATORS and is read by no
# other suite, while sibling features pin their own config-doc rows. A reworded
# rule 6 must not leave the operator doc describing a different line.
if command -v node >/dev/null 2>&1; then
  MISS19D="$(CFG="$PLUGIN_DIR/docs/configuration.md" node -e '
    const fs = require("fs");
    // The hook ROW is the one whose FIRST cell names the hook. The config-key
    // rows below it name the same file in their second cell, and a further row
    // mentions it in prose, so a bare substring match selects four lines.
    const rows = fs.readFileSync(process.env.CFG, "utf8").split("\n")
      .filter((l) => /^\|\s*`user-prompt-zen-mode\.sh`\s*\|/.test(l));
    if (rows.length !== 1) { process.stdout.write("expected-exactly-one-zen-hook-row-got-" + rows.length); process.exit(0); }
    const row = rows[0];
    // The operator row is held to a DEFINED SUBSET, and the subset was CUT to
    // this size on purpose. An earlier one required eighteen literals, which
    // forced the cell to reproduce most of rule 6 — roughly 1,300 characters
    // inside one table cell — and made every reword of the rule a mandatory
    // two-file edit. That is the very thing the comment beside it claimed to
    // prevent: a config table is a summary, not a second copy of the directive.
    //
    // What an OPERATOR deciding whether to set `zenMode: false` actually needs:
    // what the line is, when it appears, what the four glyphs are, where it
    // sits, that a mark asserts an observation rather than a plan, and that it
    // replaces the old counter. Everything finer — the carve-out fallback, the
    // retry rule, the pass qualification, the only-the-steps and
    // no-canonical-pipeline rules, the casing rule, the omission exception —
    // belongs to the skill, which the row links, and stays pinned across the
    // real carriers by Z19b.
    const need = [
      "chain-progress", "✓", "▶", "·", "✗",
      "spans several turns",
      // The contract the row must not misdescribe: the anchor is SUPPLIED by
      // the hook and read out of the workflow document this session owns, and
      // its absence is a statement rather than a gap. (No apostrophes in this
      // block: it lives inside a single-quoted node -e program.)
      "ZENSU CHAIN ANCHOR",
      "never from the plan",
      "no anchor can be justified this turn",
      "above the closing next step",
      "add no separate",
    ];
    const bad = need.filter((n) => !row.includes(n)).map((n) => "missing<" + n.slice(0, 24) + ">");
    process.stdout.write(bad.length ? bad.join(",") : "OK");
  ' 2>/dev/null)"
  RC19D=$?
  if [ "$RC19D" -ne 0 ]; then
    check "Z19d config-doc row check could not run (node exit $RC19D) — not an all-clear" FAIL
  elif [ "$MISS19D" = "OK" ]; then
    check "Z19d docs/configuration.md zen-mode row describes the anchor, all four marks and the observation rule" PASS
  else
    check "Z19d docs/configuration.md zen-mode row is out of step: ${MISS19D:-<empty output, program produced no verdict>}" FAIL
  fi
else
  check "Z19d config-doc row check did not run — node is not on PATH" FAIL
fi

# Z20 the safety carve-out survives into the per-prompt reminder, not just the skill.
# The carve-out must also lift the one-question and one-next-step caps, or a
# confirmation before an irreversible action could be suppressed by them.
P20="$(mktemp -d -t zenmode-XXXXXX)"; S20="z20-$$"
new_session "$P20" "$S20"; helper "$P20" "$S20" --on >/dev/null
RAW20="$(fire "$P20" "$S20" "do a thing")"
MISSING20=""
for FRAG20 in "security warnings" "irreversible" "credentials" "every required step" "one-question cap"; do
  printf '%s' "$RAW20" | grep -qiF "$FRAG20" || MISSING20="$MISSING20 '$FRAG20'"
done
# The carve-out must NOT suspend the full-sentence / precedence rule: a safety
# warning is the last place for fragments. Naming rules by number here would be a
# drift hazard, since the hook's numbering differs from SKILL.md's.
printf '%s' "$RAW20" | grep -qiF 'full-sentence rule is NEVER suspended' \
  || MISSING20="$MISSING20 'full-sentence rule is NEVER suspended'"
printf '%s' "$RAW20" | grep -qE 'rules? [0-9], *[0-9].*do not apply' \
  && MISSING20="$MISSING20 (carve-out names rule NUMBERS — hook and SKILL.md number differently)"
# SKILL.md rule 9 asserts a property OF THIS DIRECTIVE — "the jargon gloss is
# NOT [suspended] ... and the injected directive keeps it too" — and nothing
# compared the two. Z23 greps the skill without the hook, Z19b excludes the
# skill carrier from the whole-directive needles, and this check greps the hook
# without the gloss. So a one-sided edit to the hook suspension list would make
# that sentence a false statement about the shipped directive with every check
# green. The list is enumerated by description, so the absence of a gloss word
# in it is the checkable form of the claim.
# The list is pinned EXACTLY rather than scanned for a forbidden word. Forbidding
# only `gloss|jargon` left every OTHER safety rule free to join the suspension
# list unnoticed, which is a widening of the carve-out and the more dangerous
# direction. The extraction is also no longer `[^.]*`: that stops at the first
# period, so a list that ever grows an internal one would silently be compared in
# part. It takes everything up to the sentence-ending period followed by a space
# and a capital, and the comparison is whitespace-normalized.
SUSPEND20_WANT="the length target, the depth-on-demand rule, the one-question cap, the one-next-step rule, and the changed-lines-only rule"
SUSPEND20="$(printf '%s' "$RAW20" \
  | sed -n 's/.*the following are suspended: \(.*\)/\1/p' \
  | sed 's/\. [A-Z].*$//' \
  | head -1 | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//;s/\.$//')"
if [ -z "$SUSPEND20" ]; then
  MISSING20="$MISSING20 (no enumerated suspension list found — the gloss claim cannot be checked)"
elif [ "$SUSPEND20" != "$SUSPEND20_WANT" ]; then
  MISSING20="$MISSING20 (the hook suspension list is not the pinned five: got '$SUSPEND20')"
fi
[ -z "$MISSING20" ] && check "Z20 carve-out lifts the caps but never the full-sentence rule, and names no rule numbers" PASS \
  || check "Z20 reminder carve-out:$MISSING20" FAIL
rm -rf "$P20"

# Z20c the off-switch literals are English while the mode answers in the user's
# language, so the reminder must tell the model to honor any other phrasing too —
# otherwise a non-English user cannot leave the mode at all.
P20C="$(mktemp -d -t zenmode-XXXXXX)"; S20C="z20c-$$"
new_session "$P20C" "$S20C"; helper "$P20C" "$S20C" --on >/dev/null
RAW20C="$(fire "$P20C" "$S20C" "do a thing")"
if printf '%s' "$RAW20C" | grep -qiF 'another language' \
  && printf '%s' "$RAW20C" | grep -qiF -- '--off' \
  && printf '%s' "$RAW20C" | grep -qiF 'stuck in this mode'; then
  check "Z20c reminder honors non-literal / non-English off-requests via the --off verb" PASS
else
  check "Z20c reminder has no escape for non-English off-requests" FAIL
fi
rm -rf "$P20C"

# Z20b the anti-omission scope clause is the guard that must NOT decay with the
# skill, so it has to live in the per-prompt reminder too — not only in SKILL.md.
P20B="$(mktemp -d -t zenmode-XXXXXX)"; S20B="z20b-$$"
new_session "$P20B" "$S20B"; helper "$P20B" "$S20B" --on >/dev/null
RAW20B="$(fire "$P20B" "$S20B" "do a thing")"
MISSING20B=""
for FRAG20B in "failing test" "risk" "limitation" "never the findings"; do
  printf '%s' "$RAW20B" | grep -qiF "$FRAG20B" || MISSING20B="$MISSING20B '$FRAG20B'"
done
[ -z "$MISSING20B" ] && check "Z20b reminder carries the scope clause (never drop findings to shorten)" PASS \
  || check "Z20b reminder scope clause missing:$MISSING20B" FAIL
rm -rf "$P20B"

# Z21 malformed payload -> exit 0, silent (never blocks a prompt)
P21="$(mktemp -d -t zenmode-XXXXXX)"
OUT21="$(printf '%s' 'not json at all' | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P21" ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
RC21=$?
if [ "$RC21" = "0" ] && [ -z "$OUT21" ]; then
  check "Z21 malformed payload -> exit 0, silent (fail-open, never blocks the prompt)" PASS
else
  check "Z21 malformed payload (rc=$RC21 out='$OUT21')" FAIL
fi
rm -rf "$P21"

# Z22 SKILL.md pins the precedence clause over compressed style modes.
# Prose is line-wrapped, so the clause is matched against a whitespace-normalized
# copy — the pin survives a reflow of the paragraph.
SKILL_FLAT="$(tr '\n' ' ' < "$SKILL" | tr -s ' ')"
if printf '%s' "$SKILL_FLAT" | grep -qiF 'overrides any other compressed or telegraphic style mode' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'no sentence fragments'; then
  check "Z22 SKILL.md states precedence over compressed/telegraphic style modes" PASS
else
  check "Z22 SKILL.md precedence clause missing" FAIL
fi

# Z23 SKILL.md pins the never-compress safety carve-out, including the rule
# numbers it lifts (5 and 8 gate confirmation questions before destructive work)
if printf '%s' "$SKILL_FLAT" | grep -qiF 'Never compress a warning' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'irreversible or destructive' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'credentials' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'Rules 3, 4, 5 and 8, and rule 7' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'jargon gloss is NOT' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'never suspended'; then
  check "Z23 SKILL.md carve-out lifts rules 3/4/5/8 and rule 7's changed-lines half, keeps the gloss and the full-sentence rule" PASS
else
  check "Z23 SKILL.md safety carve-out missing, or does not lift 5/8, or lifts the gloss or the precedence rule" FAIL
fi

# Z24 SKILL.md forbids trading findings for brevity
if printf '%s' "$SKILL_FLAT" | grep -qiF 'Shorten the prose, never the findings'; then
  check "Z24 SKILL.md forbids dropping findings to shorten an answer" PASS
else
  check "Z24 SKILL.md scope clause missing" FAIL
fi

# Z25 SKILL.md frontmatter: name, [Zensu] description, trigger phrases
if node -e '
  const t=require("fs").readFileSync(process.argv[1],"utf8");
  const m=t.match(/^---\n([\s\S]*?)\n---\n/);
  if(!m) process.exit(1);
  const fm=m[1];
  if(!/^name:\s*zen-mode\s*$/m.test(fm)) process.exit(1);
  if(!/\[Zensu\]/.test(fm)) process.exit(1);
  for(const p of ["zen mode","tired","keep it simple","low energy","less detail","/zensu:zen-mode"]){
    if(!fm.includes(p)) process.exit(1);
  }
  process.exit(0);
' "$SKILL" 2>/dev/null; then
  check "Z25 SKILL.md frontmatter has name, [Zensu] description, all trigger phrases" PASS
else
  check "Z25 SKILL.md frontmatter incomplete" FAIL
fi

# Z26 English-only (repo convention): no German umlauts / eszett, no German stems.
# The scan deliberately excludes this file: it carries both the stem list and the
# umlaut class as literals and would always match itself.
# Stems that are also English words (der/die/das/mit) are excluded on purpose —
# "let the process die" and "MIT license" are legitimate English prose, and a
# case-insensitive scan would flag them.
#
# The roster is DERIVED, never hand-listed. It was the skill/hook/helper triple
# while this feature owned three files, and the guard that exists to catch a
# German fixture could then not see the two carriers this change added: with
# German prose planted in a canned reply of the unit file, Z26 reported PASS and
# the suite stayed green. Every zen-mode-owned carrier is scanned now — the
# triple, every eval scenario, and the grader unit file.
#
# ONE allowance, and it is the CLAUDE.md §Language carve-out spelled
# mechanically rather than by filename: a match is exempt only when it sits
# inside a `/.../` regex literal on its line. That is what makes the failure
# alternation in anchor-failed-step.yaml legal — it matches text whose language
# the product does not control — while prose, a comment and a canned fixture in
# the very same file stay violations. Keying the allowance to a file name would
# have exempted all three.
Z26_LIST="$SKILL
$HOOK
$HELPER
$PLUGIN_DIR/tests/structure/zen-anchor-assertions.test.js
$PLUGIN_DIR/hooks/lib/zen-anchor-v1.js
$PLUGIN_DIR/tests/structure/zen-anchor-v1.test.js"
Z26_FIXED=6
Z26_SCEN=0
for Z26_F in "$PLUGIN_DIR"/evals/zen-mode-reaction/scenarios/*.yaml; do
  [ -f "$Z26_F" ] || continue
  Z26_LIST="$Z26_LIST
$Z26_F"
  Z26_SCEN=$(( Z26_SCEN + 1 ))
done
# The floor used to be a bare `scanned < 4`, which is exactly the size of the
# hand-listed half — so a glob that matched nothing (a path typo, a `.yml`
# extension, a host where the `-f` guard mis-fires) silently dropped every eval
# scenario and Z26 still reported PASS, back to the blindness the rewrite was
# made to remove. The derived half is counted HERE, where the roster is built,
# and the expected TOTAL is passed in, so both halves are covered by one
# equality rather than by a constant that only ever described one of them.
if [ "$Z26_SCEN" -lt 5 ]; then
  check "Z26 the derived half of the English-only roster matched only $Z26_SCEN scenario file(s) — the glob has moved" FAIL
elif ! command -v node >/dev/null 2>&1; then
  check "Z26 English-only scan did not run — node is not on PATH" FAIL
else
  LANG_BAD="$(printf '%s\n' "$Z26_LIST" | Z26_WANT=$(( Z26_FIXED + Z26_SCEN )) node -e '
    const fs = require("fs"), path = require("path");
    // Stems that are also English words are excluded on purpose; see above.
    // BOTH carry `g`: a non-global regex returns only the FIRST match on a
    // line, so a violation sitting outside a regex literal went unreported
    // whenever an exempt match happened to come first — which is the ordinary
    // shape of the one line this scan deliberately exempts.
    // The roster rewrite widened WHICH files are scanned and left the vocabulary
    // alone, and a German canned reply then sat in the unit file with Z26 green:
    // "Der Adapter ist umgeschrieben." contains no umlaut and no member of the
    // original list. The high-frequency German function words are in now — the
    // articles and copulas that no German sentence avoids — which is what makes
    // the scan a check on the LANGUAGE rather than on one word list.
    // `sie`, `war`, `den`, `dem`, `am`, `im`, `so`, `will`, `hat` and `alle` are
    // deliberately OUT: each is an ordinary English word, a proper-name fragment
    // or a common identifier fragment, and the sibling reason for excluding
    // der/die/das applies to them too. Do NOT trust this sentence — Z26b below
    // DRIVES the list against an English probe corpus, because an earlier
    // revision made exactly this claim while `hat` and `alle` were still in it.
    const STEM = /\b(und|oder|nicht|Datei|Dateien|werden|kann|muss|sollte|wenn|dann|aber|auch|noch|schon|bitte|ohne|ist|sind|wurde|wurden|einen|eine|einem|einer|eines|nach|durch|über|unter|zwischen|beim|vom|zum|zur|diese|dieser|dieses|jede|jeder|keine|kein|sich|wird|haben|dass|weil|damit|sondern|jedoch|bereits|immer|niemals)\b/gi;
    const UML = /[äöüÄÖÜß]/g;
    // Spans of a line that sit inside a /.../ regex literal. Deliberately crude:
    // it over-approximates toward EXEMPTING, so a false exemption is possible and
    // a false violation is not — and the roster is what makes the check bite.
    const literalSpans = (line) => {
      const spans = [];
      const re = /\/(?![*\/])(?:\\.|\[(?:\\.|[^\]\\])*\]|[^\/\\\n])+\/[a-z]*/g;
      let m;
      while ((m = re.exec(line))) spans.push([m.index, m.index + m[0].length]);
      return spans;
    };
    const inLiteral = (spans, i) => spans.some(([a, b]) => i >= a && i < b);
    let input = "";
    process.stdin.on("data", (c) => { input += c; });
    process.stdin.on("end", () => {
      const bad = [];
      let scanned = 0;
      for (const f of input.split("\n").map((x) => x.trim()).filter(Boolean)) {
        let text;
        try { text = fs.readFileSync(f, "utf8"); } catch (_) { bad.push(path.basename(f) + ":unreadable"); continue; }
        scanned += 1;
        text.split("\n").forEach((line, n) => {
          const spans = literalSpans(line);
          for (const re of [UML, STEM]) {
            re.lastIndex = 0;
            let hit;
            while ((hit = re.exec(line))) {
              if (inLiteral(spans, hit.index)) continue;
              bad.push(path.basename(f) + ":" + (n + 1) + ":" + (re === UML ? "umlaut" : "german-stem"));
              break;
            }
          }
        });
      }
      // An EQUALITY against the roster the shell actually built, never a bare
      // floor: a file that cannot be read is already reported above, and this
      // catches the rest — a roster that shrank between being built and being
      // scanned reads as a failure rather than as an all-clear.
      const want = Number(process.env.Z26_WANT);
      if (!Number.isInteger(want) || want < 4) bad.push("roster-size-unresolved");
      else if (scanned !== want) bad.push("roster-scanned-" + scanned + "-of-" + want + "-files");
      process.stdout.write(bad.length ? bad.slice(0, 6).join(" ") : "OK");
    });
  ' 2>/dev/null)"
  LANG_RC=$?
  if [ "$LANG_RC" -ne 0 ]; then
    check "Z26 English-only scan could not run (node exit $LANG_RC) — not an all-clear" FAIL
  elif [ "$LANG_BAD" = "OK" ]; then
    check "Z26 every zen-mode carrier is English-only outside a regex literal (skill, hook, helper, unit file, every eval scenario)" PASS
  else
    check "Z26 English-only violated: ${LANG_BAD:-<empty output, program produced no verdict>}" FAIL
  fi
fi

# ── Z26b: no stem may be an ordinary English word ────────────────────────────
# The list started with der/die/das/mit EXCLUDED on exactly this ground — "let
# the process die" and "MIT license" are legitimate English prose. Widening it to
# catch a German sentence with no umlaut re-introduced the defect: `hat` is an
# English noun and `alle` heads a proper name, so an ordinary English line would
# have been reported as a violation. A false red in the guard that gates every
# carrier is worse than a missed stem, so the list is driven against an English
# probe corpus rather than trusted to a comment claiming the exclusion was made.
if ! command -v node >/dev/null 2>&1; then
  check "Z26b stem-list English probe did not run — node is not on PATH" FAIL
else
  STEM_BAD="$(SUITE="$0" node -e '
    const fs = require("fs");
    const src = fs.readFileSync(process.env.SUITE, "utf8");
    const m = src.match(/const STEM = \/\\b\(([^)]*)\)\\b\/gi;/);
    if (!m) { process.stdout.write("stem-list-not-locatable"); }
    else {
      const stems = m[1].split("|");
      // Ordinary English prose a maintainer could legitimately write in any of
      // the scanned carriers. Each line must scan CLEAN.
      const ENGLISH = [
        "The hat is on the table and the coat is on the hook.",
        "Alle Corporation ships a linter we do not use.",
        "Return the value under the key, then check it once more.",
        "This is an ordinary sentence about a step list and a next step.",
        "The suite is green, nothing failed, and no case was skipped.",
        "Read the file, then write it back without the trailing newline.",
        "A wide-brimmed hat, a die-cast model, and an MIT license.",
      ];
      const bad = [];
      for (const stem of stems) {
        const re = new RegExp("\\b" + stem + "\\b", "i");
        for (const line of ENGLISH) {
          if (re.test(line)) { bad.push(stem); break; }
        }
      }
      process.stdout.write(bad.length ? bad.join(",") : "OK");
    }
  ' 2>/dev/null)"
  STEM_RC=$?
  if [ "$STEM_RC" -ne 0 ]; then
    check "Z26b stem-list probe could not run (node exit $STEM_RC) — not an all-clear" FAIL
  elif [ "$STEM_BAD" = "OK" ]; then
    check "Z26b no German stem in the English-only list is also an ordinary English word" PASS
  else
    check "Z26b these stems match ordinary English prose and would false-red a legitimate edit: ${STEM_BAD:-<empty output, program produced no verdict>}" FAIL
  fi
fi

# Z27 config.example.json documents both flags, and documents zenModeDefault at
# its real shipped value — an example showing false would misstate the default.
if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const h=j.hooks||{};
  process.exit(h.zenMode===true&&h.zenModeDefault===true?0:1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "Z27 config.example.json documents hooks.zenMode + hooks.zenModeDefault:true" PASS
else
  check "Z27 config.example.json missing hooks.zenMode or hooks.zenModeDefault:true" FAIL
fi

# Z28 no version bump rode along with this feature
if node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const m=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8"));
  const e=(m.plugins||[]).find(x=>x.name==="zensu")||{};
  process.exit(p.version===e.version && e.source && e.source.ref==="v"+p.version?0:1);
' "$PLUGIN_JSON" "$PLUGIN_DIR/.claude-plugin/marketplace.json" 2>/dev/null; then
  check "Z28 plugin.json / marketplace version + ref stay in sync (no stray bump)" PASS
else
  check "Z28 version sync broken" FAIL
fi

# ── Z30: a ceiling on the always-on per-prompt injection ────────────────────
# This hook is the plugin's largest always-on carrier and the only one with no
# length bound: its two marker-block siblings each ship a MAX_BLOCK plus a
# review-ceiling tripwire precisely so a rule block cannot grow unnoticed. This
# one had neither, and rule 6 grew the directive from 2951 to 4664 characters —
# then SHRANK it to 4208 when the anchor stopped being derived by the model and
# started being supplied by this hook. Both moves were invisible until this
# window existed, which is the argument for keeping it one-sided in BOTH
# directions: a ceiling that has drifted away from its text is not a tripwire.
# a 57% rise on a channel that fires on EVERY prompt of every zen-mode session,
# with zenModeDefault shipping true. Nothing observed it, and docs/architecture.md
# still derived a per-turn total from the old figure.
#
# The bound is ONE-SIDED and is a tripwire, not a budget: the remaining slack
# under the ceiling may not EXCEED the declared headroom. Growth past the ceiling
# fails, and so does a shrink far below it — a ceiling that has drifted away from
# its text has stopped being a tripwire. The headroom is absolute, never a
# preserved percentage. The sibling marker-block carriers use 89 for "roughly one
# clause"; this suite uses 95, which is NOT that figure — see the constant below
# for why the window was re-derived rather than copied.
#
# Measured through node, never ${#var}: bash counts bytes under LC_ALL=C and code
# points otherwise, while the emitted value is a JSON string carrying four
# non-ASCII marks.
# One implementation of "is this a plain non-negative integer", driven by Z30a
# below. `case` matches the WHOLE string, unlike a line-scoped grep.
zen_is_plain_number() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# The headroom was BORROWED from the two marker-block carriers at 89 and is no
# longer: the supplied-anchor rewrite shrank the directive from 4664 to 4208, so
# the window was RE-DERIVED against the new text — ceiling 4300, headroom 95 —
# rather than carried over. Keeping 89 would have pinned a window around a length
# that no longer exists, which is the drift this tripwire is for. State what the
# figure does NOT buy: this constant is enrolled in neither of the guarantees the
# two marker-block carriers have. It is not compared against the
# sibling headrooms by the cross-carrier equality arm in
# test-windows-portability-guards.sh, which covers only that pair, and there is
# no run-time fail-safe beneath it — nothing in hooks/user-prompt-zen-mode.sh
# refuses an over-long directive the way rule-block-v1.js refuses an over-long
# block. So this is a build-time tripwire and nothing else; a directive that grew
# past the ceiling would still be injected in full by an installed plugin.
# RAISED 4300 -> 4520, and the growth is argued rather than absorbed, which is
# what this check`s own failure text asks for. The delta buys two things and both
# are safety rather than prose. First, the `ZENSU CHAIN ANCHOR:` field is now
# emitted between `<!-- zensu:chain-anchor -->` markers and the directive names
# that pair as the ONLY form it may trust: the field name alone is fixed and
# guessable, the directive ASSERTS provenance for it, and the same literal occurs
# in this repository`s own tree - so content read later in the same turn could
# impersonate the field and inherit that assertion, putting a false completion
# signal in front of a user this very directive describes as working at low
# capacity. Second, the off-verb stopped being named by a bare relative path.
# That half made the directive SHORTER; the delimiters and the sentence naming
# them are what cost the bytes.
ZEN_DIRECTIVE_CEILING=4520
ZEN_DIRECTIVE_HEADROOM=95
if ! command -v node >/dev/null 2>&1; then
  check "Z30 directive length bound did not run — node is not on PATH" FAIL
else
  # MEASURE WHAT A SESSION RECEIVES, not the template. The source literal still
  # holds the {{ZENSU_CHAIN_ANCHOR}} placeholder, which the hook replaces at emit
  # time; measuring the template understated the emitted worst case by the
  # difference between the placeholder and the longest token the module can
  # produce. The token set is derived from that module, never re-spelled here.
  ZEN_LEN="$(PLUGIN_DIR="$PLUGIN_DIR" HOOK="$HOOK" node -e '
    const fs = require("fs");
    const path = require("path");
    const hook = fs.readFileSync(process.env.HOOK, "utf8");
    const blocks = [...hook.matchAll(/"additionalContext":\s*"((?:[^"\\]|\\.)*)"/g)]
      .map((m) => { try { return JSON.parse("\"" + m[1] + "\""); } catch (_) { return ""; } });
    const active = blocks.find((s) => s.startsWith("zen-mode is ACTIVE"));
    if (active === undefined) { process.stdout.write("NONE"); process.exit(0); }
    const MARKER = "{{ZENSU_CHAIN_ANCHOR}}";
    if (!active.includes(MARKER)) { process.stdout.write(String(active.length)); process.exit(0); }
    let longest = "";
    try {
      const mod = require(path.join(process.env.PLUGIN_DIR, "hooks", "lib", "zen-anchor-v1.js"));
      for (const t of mod.producibleTokens()) {
        if (t.length > longest.length) longest = t;
      }
    } catch (_) { process.stdout.write("NONE"); process.exit(0); }
    if (!longest) { process.stdout.write("NONE"); process.exit(0); }
    process.stdout.write(String(active.replace(MARKER, longest).length));
  ' 2>/dev/null)"
  ZEN_LEN_RC=$?
  if [ "$ZEN_LEN_RC" -ne 0 ] || ! zen_is_plain_number "$ZEN_LEN"; then
    check "Z30 directive length could not be measured (rc=$ZEN_LEN_RC, got '${ZEN_LEN:-<empty>}') — not an all-clear" FAIL
  else
    ZEN_SLACK=$(( ZEN_DIRECTIVE_CEILING - ZEN_LEN ))
    if [ "$ZEN_SLACK" -lt 0 ]; then
      check "Z30 the injected directive is $ZEN_LEN chars, past the declared ceiling of $ZEN_DIRECTIVE_CEILING — argue the growth and raise the ceiling deliberately" FAIL
    elif [ "$ZEN_SLACK" -gt "$ZEN_DIRECTIVE_HEADROOM" ]; then
      check "Z30 the directive is $ZEN_LEN chars, $ZEN_SLACK below the ceiling of $ZEN_DIRECTIVE_CEILING (headroom $ZEN_DIRECTIVE_HEADROOM) — the ceiling has drifted away from the text" FAIL
    else
      check "Z30 injected directive is $ZEN_LEN chars, $ZEN_SLACK under its declared ceiling" PASS
    fi
  fi
fi

# ── Z30a: the numeric guard above is itself driven ──────────────────────────
# Z30's guard used `grep -qE '^[0-9]+$'`, which matches per LINE, over a value
# captured with `2>&1`. A node warning printed beside the number satisfied that
# guard, and the arithmetic on the next line then received a multi-line operand.
# Measured on bash 3.2: `$(( CEILING - ZEN_LEN ))` reads the first word as a
# variable name, `set -u` aborts the shell there, and the abort exits 0 — so the
# suite reports SUCCESS to run-all.sh having never printed its summary and never
# run Z29 below. A silent green is the one verdict this suite may not give, so
# the predicate is a named function driven by its own negative cases rather than
# an inline expression nothing exercises.
Z30A_FAIL=""
for Z30A_BAD in "Warning: some node notice
4664" "" "4664 " "12x" "-5"; do
  if zen_is_plain_number "$Z30A_BAD" 2>/dev/null; then
    Z30A_FAIL="$Z30A_FAIL [accepted '$(printf '%s' "$Z30A_BAD" | tr '\n' '/')']"
  fi
done
if ! zen_is_plain_number "4664" 2>/dev/null; then
  Z30A_FAIL="$Z30A_FAIL [rejected a plain number]"
fi
if [ -n "$Z30A_FAIL" ]; then
  check "Z30a the directive-length numeric guard is not whole-string:$Z30A_FAIL" FAIL
else
  check "Z30a the directive-length numeric guard rejects a multi-line, empty, padded, mixed and signed value" PASS
fi

# ── Z29: the eval graders' own unit contract ────────────────────────────────
# The scenarios under evals/zen-mode-reaction/ are the only place the emitted
# anchor is ever graded against a model, and that suite is local-only — so the
# grader BODIES were executed by nothing at all. The sibling suite's P6/P7/P9b
# are presence checks (a `type: javascript` key, no llm-rubric, an envelope
# extractor), all of which a logically broken grader satisfies. Two real defects
# lived behind that: a step-list branch that could never match a `-` bullet, so
# a compliant reply was graded as a violation, and a tick guard that only fired
# on three hardcoded English step names while the directive tells the model to
# choose its own. The unit file runs every grader against canned replies and
# pins the pass/fail vector, so a grader that stops catching what it is named
# for turns THIS suite — which is in ciStructureTests — red.
Z29_UNIT="$PLUGIN_DIR/tests/structure/zen-anchor-assertions.test.js"
if [ ! -f "$Z29_UNIT" ]; then
  check "Z29 the eval graders' unit contract is missing from disk" FAIL
elif ! command -v node >/dev/null 2>&1; then
  # FAIL, not a skip: recording a PASS here would credit a check that did not
  # execute, which is the one verdict this suite may not give.
  check "Z29 eval-grader unit contract did not run — node is not on PATH" FAIL
else
  Z29_OUT="$(node --test "$Z29_UNIT" 2>&1)"
  Z29_RC=$?
  # A case-count floor as well as the exit status: `node --test` exits 0 for a
  # file that registers ZERO cases, so the status alone cannot tell a green run
  # from a file that stopped being discovered.
  Z29_PASS_N="$(printf '%s\n' "$Z29_OUT" | sed -n 's/^# pass \([0-9]*\)$/\1/p;s/^. pass \([0-9]*\)$/\1/p' | head -1)"
  Z29_SKIP_N="$(printf '%s\n' "$Z29_OUT" | sed -n 's/^# skipped \([0-9]*\)$/\1/p;s/^. skipped \([0-9]*\)$/\1/p' | head -1)"
  [ -n "$Z29_SKIP_N" ] || Z29_SKIP_N=0
  Z29_FAIL_N="$(printf '%s\n' "$Z29_OUT" | sed -n 's/^# fail \([0-9]*\)$/\1/p;s/^. fail \([0-9]*\)$/\1/p' | head -1)"
  [ -n "$Z29_FAIL_N" ] || Z29_FAIL_N=unknown
  Z29_SEEN=$(( ${Z29_PASS_N:-0} + Z29_SKIP_N ))
  # The floors are the REGISTRATION step for a new case, the convention this repo
  # records for test-session-trail-skill.sh T22. At 3 against a file of 6 they
  # admitted the deletion of every case that actually executes a grader — the
  # vector tests and the both-directions test — while staying green. Raise this
  # number in the same commit that adds a case.
  Z29_FLOOR=11
  # ONE floor, over REGISTRATIONS. The pair `Z29_SEEN >= FLOOR && Z29_PASS_N >=
  # FLOOR` could never fail independently — skips are non-negative, so the first
  # conjunct held whenever the second did — and it defeated the stated intent:
  # marking a case `test.skip` left it registered but reported FAIL. `Z29_SEEN`
  # is the registration count, and a non-zero `# fail` is what turns this red.
  if [ "$Z29_RC" -eq 0 ] && [ -n "$Z29_PASS_N" ] && [ "$Z29_FAIL_N" = "0" ] && [ "$Z29_SEEN" -ge "$Z29_FLOOR" ]; then
    check "Z29 the eval graders' unit contract passes ($Z29_PASS_N cases)" PASS
  else
    check "Z29 eval-grader unit contract: rc=$Z29_RC pass=${Z29_PASS_N:-none} skipped=$Z29_SKIP_N (want registered >= $Z29_FLOOR and fail 0, got fail=$Z29_FAIL_N): $(printf '%s' "$Z29_OUT" | grep -E '^.?[[:space:]]*(not ok|✖)' | head -2 | tr '\n' ' ')" FAIL
  fi
fi


# ── Z31: the anchor module's own unit contract ──────────────────────────────
# tests/run-all.sh discovers only test-*.sh, so the node --test file that pins
# the shape -> line mapping needs a driver here. Same shape as Z29, and for the
# same reason: node --test exits 0 for a file registering zero cases, so a floor
# over REGISTRATIONS is what keeps a silently emptied file from reading as
# agreement. Raise it in the same commit that adds a case.
Z31_UNIT="$PLUGIN_DIR/tests/structure/zen-anchor-v1.test.js"
Z31_FLOOR=25
if [ ! -f "$Z31_UNIT" ]; then
  check "Z31 the anchor module's unit contract is missing from disk" FAIL
elif ! command -v node >/dev/null 2>&1; then
  check "Z31 anchor-module unit contract did not run — node is not on PATH" FAIL
else
  Z31_OUT="$(node --test "$Z31_UNIT" 2>&1)"
  Z31_RC=$?
  Z31_PASS_N="$(printf '%s\n' "$Z31_OUT" | sed -n 's/^# pass \([0-9]*\)$/\1/p;s/^. pass \([0-9]*\)$/\1/p' | head -1)"
  Z31_SKIP_N="$(printf '%s\n' "$Z31_OUT" | sed -n 's/^# skipped \([0-9]*\)$/\1/p;s/^. skipped \([0-9]*\)$/\1/p' | head -1)"
  [ -n "$Z31_SKIP_N" ] || Z31_SKIP_N=0
  Z31_FAIL_N="$(printf '%s\n' "$Z31_OUT" | sed -n 's/^# fail \([0-9]*\)$/\1/p;s/^. fail \([0-9]*\)$/\1/p' | head -1)"
  [ -n "$Z31_FAIL_N" ] || Z31_FAIL_N=unknown
  Z31_SEEN=$(( ${Z31_PASS_N:-0} + Z31_SKIP_N ))
  if [ "$Z31_RC" -eq 0 ] && [ -n "$Z31_PASS_N" ] && [ "$Z31_FAIL_N" = "0" ] && [ "$Z31_SEEN" -ge "$Z31_FLOOR" ]; then
    check "Z31 the anchor module's unit contract passes ($Z31_PASS_N cases)" PASS
  else
    check "Z31 anchor-module unit contract: rc=$Z31_RC pass=${Z31_PASS_N:-none} skipped=$Z31_SKIP_N (want registered >= $Z31_FLOOR and fail 0, got fail=$Z31_FAIL_N)" FAIL
  fi
fi

# ── Z32: the anchor the hook actually EMITS ─────────────────────────────────
# Z19b compares the carriers and Z31 pins the mapping; neither observes the one
# thing a session sees, which is the token that reaches the injected directive.
# All three arms below drive the real hook against a real Session Control record.
#
# The fail-open arm is the load-bearing one: every fault must leave the mode
# ACTIVE and the anchor absent, because a missing anchor costs a line of
# presentation while a wrong one misreports where the session stands.
arm_chain() { # <project> <session_id>
  # ZENSU_CONFIG is pinned here for the reason stated at the `helper` definition
  # above: --tdd-begin resolves hooks.tddImplementation, and without the pin it
  # would read whatever ~/.zensu/config.json the developer happens to have.
  CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$1" \
    ZENSU_CONFIG="$NO_CONFIG" \
    bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" --tdd-begin >/dev/null 2>&1
}
# Reads the hook's JSON on stdin and prints the token after the marker.
anchor_of() {
  node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{
      try{
        const a=(JSON.parse(s).hookSpecificOutput||{}).additionalContext||"";
        const M="ZENSU CHAIN ANCHOR: ";
        const i=a.indexOf(M);
        if(i<0){process.stdout.write("<no-marker>");return;}
        // TERMINATED AT THE LINE, not at the end of the block. The field is
        // emitted between `<!-- zensu:chain-anchor -->` markers now, so slicing
        // to the end of the string swept the closing marker into the value and
        // every anchor assertion in this file compared against a token the hook
        // never produced.
        const rest=a.slice(i+M.length);
        const nl=rest.indexOf("\n");
        process.stdout.write((nl<0?rest:rest.slice(0,nl)).trim());
      }catch(_){process.stdout.write("<badjson>");}
    });
  '
}

P32="$(mktemp -d -t zenmode-anchor-XXXXXX)"; S32="z32-$$"
new_session "$P32" "$S32"
A32_NONE="$(fire "$P32" "$S32" "where are we?" | anchor_of)"
arm_chain "$P32" "$S32"
A32_ARMED="$(fire "$P32" "$S32" "where are we?" | anchor_of)"
if [ "$A32_NONE" = "none" ]; then
  check "Z32a no chain armed -> the directive says none, so no anchor is rendered" PASS
else
  check "Z32a expected none with no chain armed, got '$A32_NONE'" FAIL
fi
if [ "$A32_ARMED" = "Zensu: ▶implement ·review ·self-review" ]; then
  check "Z32b an armed chain -> the directive carries the position read from the workflow document" PASS
else
  check "Z32b expected the implementing anchor, got '$A32_ARMED'" FAIL
fi

# Z36-control: a HEALTHY armed chain must disclose NOTHING. A disclosure that
# fires on the ordinary path is noise on every prompt of every zen-mode session,
# and it would satisfy Z36 below without proving anything about a fault.
# BOTH channels from ONE run. Taking the absence of a disclosure from a second
# invocation proved nothing: the control passes whenever the hook writes no
# stderr, including when it exits ABOVE the anchor block entirely, and its
# discriminator then lives in a different `fire`. One run has to show the armed
# anchor on stdout AND the silence on stderr.
Z36C_ERRFILE="$P32/.z36c-err"
Z36C_OUT="$(ZEN_ERRFILE="$Z36C_ERRFILE" fire "$P32" "$S32" "where are we?")"
Z36C_ANCHOR="$(printf '%s' "$Z36C_OUT" | anchor_of)"
Z36C_ERR="$(cat "$Z36C_ERRFILE" 2>/dev/null)"
if [ "$Z36C_ANCHOR" != "$A32_ARMED" ]; then
  check "Z36-control the run did not reach the anchor at all (anchor='$Z36C_ANCHOR') — its silence proves nothing" FAIL
else
  case "$Z36C_ERR" in
    *'zen-mode anchor unavailable'*)
      check "Z36-control a healthy armed chain disclosed a fault it does not have — <$Z36C_ERR>" FAIL ;;
    *)
      check "Z36-control one run yields the armed anchor AND no fault disclosure" PASS ;;
  esac
fi

# Z39 the two fields must both survive a MULTI-LINE prompt.
#
# One child produces the anchor and the prompt over one pipe, split on the first
# newline. Every other fixture in this block sends a single-line prompt, so the
# split has only ever been exercised where it cannot go wrong. Both halves need
# their own observable: the anchor half is the token, and the prompt half is
# only visible through the off-phrase branch, which reads the text AFTER the
# first newline. A second session keeps the OFF write off $S32's marker.
#
# It gets its OWN project, not just its own session: the fail-open arms below
# locate the workflow document with `find … | head -1`, so a second document in
# $P32 would let them corrupt one session's state while firing another's — which
# is exactly what happened, and it turned Z32c/Z32d/Z32e green-to-red for a
# reason that had nothing to do with them.
P39="$(mktemp -d -t zenmode-multiline-XXXXXX)"; S39="zen-multiline-$$"
new_session "$P39" "$S39"
arm_chain "$P39" "$S39"
Z39_ON="$(fire "$P39" "$S39" "$(printf 'line one\nline two\nline three')")"
Z39_ON_ANCHOR="$(printf '%s' "$Z39_ON" | anchor_of)"
Z39_ON_KIND="$(printf '%s' "$Z39_ON" | classify)"
case "$A32_ARMED" in 'Zensu: '*) Z39_BASE_OK=1 ;; *) Z39_BASE_OK=0 ;; esac
if [ "$Z39_BASE_OK" -eq 0 ]; then
  check "Z39 the armed baseline is '$A32_ARMED', not a real token, so the multi-line comparison would agree with a degenerate hook" FAIL
elif [ "$Z39_ON_ANCHOR" = "$A32_ARMED" ] && [ "$Z39_ON_KIND" = "UserPromptSubmit|ON" ]; then
  check "Z39 a multi-line prompt still yields the armed anchor on the first line" PASS
else
  check "Z39 multi-line split broke the anchor half (anchor='$Z39_ON_ANCHOR' kind='$Z39_ON_KIND', wanted '$A32_ARMED')" FAIL
fi
Z39_OFF_KIND="$(fire "$P39" "$S39" "$(printf 'please stop now\nzen off')" | classify)"
if [ "$Z39_OFF_KIND" = "UserPromptSubmit|OFF" ]; then
  check "Z39a the prompt half survives past the anchor line — an off phrase on line two is still seen" PASS
else
  check "Z39a the off phrase on line two was NOT seen (kind='$Z39_OFF_KIND') — the prompt half of the split is lost" FAIL
fi

# Z32e a CLOSED chain must render NO anchor through the real hook.
#
# This is the arm nothing had. The end-to-end coverage was `none` (no chain),
# `implementing`, and two fail-open shapes — so the hook's own handling of the one
# shape that used to make a completion claim was proven only at the unit layer,
# where the mapping is called directly. A regression that reintroduced a rendered
# `chain-closed` line would have passed every check in this suite.
#
# The document is mutated in place rather than driven through a terminus verb,
# because closing a chain properly needs a consumed review ticket and a real
# reviewer spawn, which no structure suite can perform. `validateWorkflowState`
# judges shape plus a self-derivable hash, so a shape-valid edit is readable.
Z32E_DOC="$(find "$P32/.zensu/state" -maxdepth 1 -name 'tdd-phase-*.json' 2>/dev/null | head -1)"
if [ -z "$Z32E_DOC" ]; then
  check "Z32e closed-chain arm could not run — arming wrote no workflow document" FAIL
elif ! node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.implComplete = true;
    j.chainDone = true;
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$Z32E_DOC" 2>/dev/null; then
  check "Z32e closed-chain arm could not run — the workflow document could not be rewritten" FAIL
else
  Z32E_OUT="$(fire "$P32" "$S32" "where are we?")"
  Z32E_ANCHOR="$(printf '%s' "$Z32E_OUT" | anchor_of)"
  Z32E_KIND="$(printf '%s' "$Z32E_OUT" | classify)"
  # THE STDERR IS PART OF THE ASSERTION, because without it this check is
  # byte-identical to Z32c's and Z32d's FAIL-OPEN assertions: all three require
  # `none` plus an active mode, so nothing here could tell "the closed chain
  # mapped to null" from "the rewritten document became a fault". Z36-control
  # already owns this discriminator; it is reused rather than re-invented.
  Z32E_ERRFILE="$P32/.z32e-err"
  : > "$Z32E_ERRFILE"
  ZEN_ERRFILE="$Z32E_ERRFILE" fire "$P32" "$S32" "where are we?" >/dev/null 2>/dev/null || true
  Z32E_ERR="$(cat "$Z32E_ERRFILE" 2>/dev/null)"
  if [ -n "$Z32E_ERR" ]; then
    check "Z32e a closed chain disclosed a fault on stderr <$Z32E_ERR> — it must MAP to no anchor, not fail into one" FAIL
  elif [ "$Z32E_ANCHOR" = "none" ] && [ "$Z32E_KIND" = "UserPromptSubmit|ON" ]; then
    check "Z32e a closed chain renders no anchor, and the mode stays active" PASS
  else
    check "Z32e a closed chain rendered '$Z32E_ANCHOR' (kind '$Z32E_KIND') — a terminated chain must carry no progress line" FAIL
  fi
fi

# Fail-open: a workflow document the reader cannot classify must cost the
# anchor, never the mode. Corrupting the document is the cheapest fault that
# reaches the same catch as a missing module or a dead node.
Z32_DOC="$(find "$P32/.zensu/state" -maxdepth 1 -name 'tdd-phase-*.json' 2>/dev/null | head -1)"
if [ -z "$Z32_DOC" ]; then
  check "Z32c fail-open arm could not run — arming wrote no workflow document" FAIL
else
  printf '{ not json' > "$Z32_DOC"
  Z32C_OUT="$(fire "$P32" "$S32" "where are we?")"
  Z32C_ANCHOR="$(printf '%s' "$Z32C_OUT" | anchor_of)"
  Z32C_KIND="$(printf '%s' "$Z32C_OUT" | classify)"
  if [ "$Z32C_ANCHOR" = "none" ] && [ "$Z32C_KIND" = "UserPromptSubmit|ON" ]; then
    check "Z32c an unreadable workflow document costs the anchor, not the mode" PASS
  else
    check "Z32c fail-open broke (anchor='$Z32C_ANCHOR' kind='$Z32C_KIND')" FAIL
  fi

  # Z36 a fault must DISCLOSE, not just degrade.
  #
  # Every fault on this path answers `none`, and `none` is also what a session
  # with no chain armed legitimately renders — so an absent document, a corrupt
  # one, a module that will not load and a dead child were byte-identical to
  # ordinary healthy output, on every channel. This repository's own rule is
  # that a silent failure is a lie. The disclosure goes to stderr, the operator
  # channel, and must never change the exit status or the injected directive.
  #
  # `fire` discards stderr, so this arm needs its own invocation — the same
  # reason the Stop-enforcer suite captures its fence line separately.
  Z36_ERR="$(fire_err "$P32" "$S32" "where are we?")"
  # THE CLASS IS ASSERTED, not only the lead-in. AC-102 says the line NAMES the
  # class; asserting the fixed prefix alone let the emitted line drop
  # `classes.join(", ")` entirely, after which a corrupt document and an
  # unloadable module read identically while Z36, Z42 and Z46 all stayed green.
  # The fixture corrupts the workflow document, so `workflow document` is the
  # class this path sets.
  case "$Z36_ERR" in
    *'zen-mode anchor unavailable (workflow document)'*)
      check "Z36 an unreadable workflow document is disclosed on stderr" PASS ;;
    *)
      check "Z36 a fault degraded SILENTLY — stderr carried <$Z36_ERR>, so a corrupt document is indistinguishable from no chain" FAIL ;;
  esac

  # Z32d a workflow document that is not a REGULAR file must not be opened at
  # all. `.zensu/state/` is writable from inside a session and no gate covers it
  # while the chain is inactive, so a FIFO there is reachable. The shared reader
  # now opens O_RDONLY|O_NOFOLLOW|O_NONBLOCK and fstats for isFile(), so the open
  # returns and the descriptor check rejects it; this arm predates that flag and
  # is kept because the hook's own lstat is still the first refusal and because a
  # regression in either place has the same observable. On a hook that fires on EVERY prompt
  # that wedges the session with no escape from inside — the prompt never
  # reaches the model and the off-phrase branch is never evaluated. The hook
  # therefore lstats the document before the reader can open it.
  #
  # THE BOUND IS THE CHECK. A regression here does not produce a wrong value, it
  # produces no value at all, so the arm has to time the hook out and report
  # rather than wait for it. The first spelling ran `fire` inside a command
  # substitution with a background killer, and MEASURED against a hook with the
  # guard removed it hung past two minutes anyway: a command substitution reads
  # until every writer closes the pipe, and killing the shell leaves the blocked
  # `node` holding it open. So the output goes to a FILE, `set -m` puts the job
  # in its own process group, and the timeout kills that GROUP.
  rm -f "$Z32_DOC"
  if ! mkfifo "$Z32_DOC" 2>/dev/null; then
    check "Z32d FIFO arm could not run — mkfifo is unavailable on this host" FAIL
  else
    Z32D_FILE="$P32/.z32d-out"
    : > "$Z32D_FILE"
    set -m
    ( fire "$P32" "$S32" "where are we?" > "$Z32D_FILE" 2>/dev/null ) &
    Z32D_PID=$!
    set +m
    Z32D_WAITED=0
    while kill -0 "$Z32D_PID" 2>/dev/null && [ "$Z32D_WAITED" -lt 20 ]; do
      sleep 1
      Z32D_WAITED=$(( Z32D_WAITED + 1 ))
    done
    if kill -0 "$Z32D_PID" 2>/dev/null; then
      kill -9 -"$Z32D_PID" 2>/dev/null || kill -9 "$Z32D_PID" 2>/dev/null
      check "Z32d the hook did not complete within ${Z32D_WAITED}s with a FIFO at the workflow document — either the lstat guard is gone, in which case every prompt of such a session wedges, or this host is slower than the bound" FAIL
    else
      Z32D_OUT="$(cat "$Z32D_FILE")"
      Z32D_ANCHOR="$(printf '%s' "$Z32D_OUT" | anchor_of)"
      Z32D_KIND="$(printf '%s' "$Z32D_OUT" | classify)"
      if [ "$Z32D_ANCHOR" = "none" ] && [ "$Z32D_KIND" = "UserPromptSubmit|ON" ]; then
        check "Z32d a FIFO at the workflow document costs the anchor and never blocks the prompt" PASS
      else
        check "Z32d FIFO guard broke (anchor='$Z32D_ANCHOR' kind='$Z32D_KIND')" FAIL
      fi
    fi
    rm -f "$Z32D_FILE" "$Z32_DOC"
  fi
fi

# Z33 the byte tests that guard the substituted token, driven directly.
#
# They are the LAST reader before the value is spliced into the emitted JSON, and
# nothing exercised them: by the time they run, $ZEN_ANCHOR can only be `none`, a
# module-produced token, or empty — the node program re-checks the grammar
# itself — so every fixture in this file drives the accepting path only. All
# three could be deleted with the whole suite green, which is the same
# guard-with-no-negative-case shape the sibling unit file records as a defect.
# They are hoisted into `zen_anchor_sanitized` so a check can reach them at all,
# and the function is EXTRACTED from the shipped hook rather than copied here, so
# this pins the text that actually runs.
Z33_GRAMMAR="$(awk '/^zen_anchor_grammar_ok\(\) \{/,/^\}$/' "$HOOK")"
Z33_BYTES="$(awk '/^zen_anchor_bytes_ok\(\) \{/,/^\}$/' "$HOOK")"
Z33_SANITIZE="$(awk '/^zen_anchor_sanitized\(\) \{/,/^\}$/' "$HOOK")"
Z33_SRC="$Z33_SANITIZE
$Z33_GRAMMAR
$Z33_BYTES"
if [ -z "$(printf '%s' "$Z33_SRC" | tr -d '[:space:]')" ]; then
  check "Z33 the anchor sanitizer could not be extracted from the hook — the pin is not measuring anything" FAIL
elif [ -z "$(printf '%s' "$Z33_GRAMMAR" | tr -d '[:space:]')" ]; then
  check "Z33 the grammar reader could not be extracted from the hook — the pin is not measuring anything" FAIL
elif [ -z "$(printf '%s' "$Z33_BYTES" | tr -d '[:space:]')" ]; then
  check "Z33 the byte reader could not be extracted from the hook — the pin is not measuring anything" FAIL
else
  Z33_BAD=""
  z33_expect() { # <input> <expected>
    Z33_GOT="$(eval "$Z33_SRC"; zen_anchor_sanitized "$1")"
    [ "$Z33_GOT" = "$2" ] || Z33_BAD="$Z33_BAD in<$1>got<$Z33_GOT>want<$2>"
  }
  # Positive controls first: without them a function that answered `none` for
  # everything would satisfy every rejection case below.
  z33_expect 'none' 'none'
  z33_expect 'Zensu: ✓implement ▶review ·self-review' 'Zensu: ✓implement ▶review ·self-review'
  z33_expect 'Zensu: ✓implement ✓review ✗self-review' 'Zensu: ✓implement ✓review ✗self-review'
  # Prefix test: anything that is neither `none` nor a `Zensu: ` line.
  z33_expect '' 'none'
  z33_expect 'Ablauf: ✓a' 'none'
  z33_expect 'zensu: ✓a' 'none'
  # The metacharacter test. `"` and `\` would break the JSON string; `&`, `|` and
  # `$` and the backtick are what the substitution and the surrounding shell
  # would otherwise reinterpret.
  z33_expect 'Zensu: ✓a"b' 'none'
  z33_expect 'Zensu: ✓a\b' 'none'
  z33_expect 'Zensu: ✓a&b' 'none'
  z33_expect 'Zensu: ✓a|b' 'none'
  z33_expect 'Zensu: ✓a$b' 'none'
  z33_expect 'Zensu: ✓a`b' 'none'
  # The control-byte test. A CR or a TAB inside a JSON string makes the whole
  # directive unparseable, which loses the mode silently rather than the anchor.
  z33_expect "$(printf 'Zensu: \342\234\223a\tb')" 'none'
  z33_expect "$(printf 'Zensu: \342\234\223a\rb')" 'none'
  # The GRAMMAR test. The three cases below are what a prefix arm cannot see, and
  # the middle one is not hypothetical: the child writes `anchor + "\n" + prompt`
  # in one call, so a child killed mid-write puts a PREFIX of a valid token on the
  # wire — after the node program's own grammar check has already passed on the
  # whole one. That reader validated a string these bytes are only the start of,
  # so this is the only reader left that can refuse them.
  z33_expect 'Zensu: arbitrary prose with no mark' 'none'
  z33_expect 'Zensu: ✓implement ▶' 'none'
  z33_expect 'Zensu: ✓implement ▶review ·self-review trailing' 'none'
  # A partial multi-byte mark — the other shape a truncated write produces.
  z33_expect "$(printf 'Zensu: \342\234\223implement \342\226')" 'none'
  # Separator shapes the grammar must also refuse, kept beside the truncation
  # cases because a loop that peels fields is exactly where they go wrong.
  z33_expect 'Zensu:  ✓implement' 'none'
  z33_expect 'Zensu: ✓implement ' 'none'
  z33_expect 'Zensu: ✓' 'none'
  z33_expect 'Zensu: implement' 'none'
  z33_expect 'Zensu: ✓Implement' 'none'
  # Z33b drives the BYTE reader alone. Composed behind the grammar walk it is
  # unreachable — measured: none of the eight inputs below survives the grammar,
  # so before this split the byte `case` blocks could be deleted with the
  # suite green, which is verbatim the defect Z33 exists to close.
  Z33B_BAD=""
  z33b_expect() { # <input> <expected>
    Z33B_GOT="$(eval "$Z33_BYTES"; zen_anchor_bytes_ok "$1" && printf 'ok' || printf 'no')"
    [ "$Z33B_GOT" = "$2" ] || Z33B_BAD="$Z33B_BAD in<$1>got<$Z33B_GOT>want<$2>"
  }
  z33b_expect 'none' 'ok'
  z33b_expect 'Zensu: ✓implement ▶review ·self-review' 'ok'
  z33b_expect 'Zensu: ✓a"b' 'no'
  z33b_expect 'Zensu: ✓a\b' 'no'
  z33b_expect 'Zensu: ✓a&b' 'no'
  z33b_expect 'Zensu: ✓a|b' 'no'
  z33b_expect 'Zensu: ✓a$b' 'no'
  z33b_expect 'Zensu: ✓a`b' 'no'
  z33b_expect "$(printf 'Zensu: \342\234\223a\tb')" 'no'
  z33b_expect "$(printf 'Zensu: \342\234\223a\rb')" 'no'
  if [ -z "$Z33B_BAD" ]; then
    check "Z33b the byte reader accepts a producible token and refuses every byte the emission cannot carry" PASS
  else
    check "Z33b byte reader:$Z33B_BAD" FAIL
  fi

  if [ -z "$Z33_BAD" ]; then
    check "Z33 the token sanitizer accepts the producible vocabulary and refuses every byte the emission cannot carry" PASS
  else
    check "Z33 token sanitizer:$Z33_BAD" FAIL
  fi

  # Z34 the sanitizer must not depend on the CALLER's locale.
  #
  # `[[:cntrl:]]` is locale-dependent, and three of the four marks carry a byte in
  # the C1 range 0x80-0x9F, which a single-byte ISO8859 locale classifies as a
  # control character: 0x9C in ✓ and ✗, 0x96 in ▶, and none in ·. An earlier
  # wording said all three carried 0x9C, which is false.
  # Under such a locale the byte arm therefore rejects a token the module itself
  # produced — the one reader on this path that can refuse a VALID anchor. The
  # step-name class has the mirror exposure: a range collates case-insensitively
  # in some locales, which is measured in Z33 above.
  #
  # Two arms, and ONLY the source arm is a bite — say so, because the obvious
  # reading of the pair is wrong. MEASURED before the fix: the behavioural arm
  # below did NOT reject the token under en_SG.ISO8859-1 on macOS, so it never
  # reproduced the exposure it is named for. It is kept as a POSITIVE CONTROL on
  # the fix's direction — pinning LC_ALL=C must not start refusing a producible
  # token — and a host where the rejection does reproduce would make it a bite
  # too. The source arm is what CI grades, since a single-byte locale is not
  # generated on every host.
  # PER SLICE, not over the concatenation: one match anywhere used to satisfy
  # this, so deleting the pin from either reader alone left it green while
  # reopening the exposure that reader is named for.
  Z34_MISSING=""
  printf '%s' "$Z33_GRAMMAR"  | grep -q 'LC_ALL=C' || Z34_MISSING="$Z34_MISSING zen_anchor_grammar_ok"
  printf '%s' "$Z33_BYTES"    | grep -q 'LC_ALL=C' || Z34_MISSING="$Z34_MISSING zen_anchor_bytes_ok"
  if [ -z "$Z34_MISSING" ]; then
    check "Z34 every token reader pins the locale for its own classes" PASS
  else
    check "Z34 the locale is not pinned in:$Z34_MISSING — those classes follow the caller's locale" FAIL
  fi

  Z34_LOC="$(locale -a 2>/dev/null | grep -iE 'ISO8859-1$' | head -1)"
  if [ -z "$Z34_LOC" ]; then
    skipcheck "Z34a no single-byte locale on this host — the locale-independence arm cannot run"
  else
    Z34_TOKEN='Zensu: ✓implement ▶review ·self-review'
    Z34_GOT="$(LC_ALL="$Z34_LOC"; eval "$Z33_SRC"; zen_anchor_sanitized "$Z34_TOKEN")"
    if [ "$Z34_GOT" = "$Z34_TOKEN" ]; then
      check "Z34a a producible token survives a single-byte locale ($Z34_LOC)" PASS
    else
      check "Z34a a producible token was REJECTED under $Z34_LOC — got <$Z34_GOT>" FAIL
    fi
  fi
fi

# Z44 the module require CLOSURE must be complete, not hand-maintained.
#
# "Every module is verified before any is required" holds only while the hook
# lists every module the three can pull in. The closure is exactly those three
# today, but nothing said so: a sibling `require('./...')` added to any of them
# drops silently out of the guard and makes the guarantee false.
Z44_MISSING="$(PLUGIN_DIR="$PLUGIN_DIR" HOOK="$HOOK" node -e '
  const fs = require("fs"), path = require("path");
  const lib = path.join(process.env.PLUGIN_DIR, "hooks", "lib");
  const hook = fs.readFileSync(process.env.HOOK, "utf8");
  const listed = (hook.match(/"[a-z0-9-]+-v1\.js"/g) || []).map((q) => q.slice(1, -1));
  const missing = [];
  for (const name of listed) {
    const file = path.join(lib, name);
    if (!fs.existsSync(file)) continue;
    for (const m of fs.readFileSync(file, "utf8").matchAll(/require\(["\x27]\.\/([^"\x27]+)["\x27]\)/g)) {
      if (!listed.includes(m[1])) missing.push(name + " -> " + m[1]);
    }
  }
  process.stdout.write(listed.length ? (missing.length ? missing.join(" ") : "OK") : "NO-LIST");
' 2>/dev/null)"; Z44_RC=$?
if [ "$Z44_RC" -ne 0 ] || [ -z "$Z44_MISSING" ]; then
  check "Z44 the require-closure scan produced no verdict (rc=$Z44_RC) — a check that did not execute is not a pass" FAIL
elif [ "$Z44_MISSING" = "NO-LIST" ]; then
  check "Z44 the hook lists no modules to verify — the pin is not measuring anything" FAIL
elif [ "$Z44_MISSING" != "OK" ]; then
  check "Z44 a module the hook loads requires a sibling it never verifies:$Z44_MISSING" FAIL
else
  check "Z44 the verified module list is closed under the siblings those modules require" PASS
fi

# ---------------------------------------------------------------------------
# The checks below read the hook SOURCE and hooks.json, not the extracted token
# readers, and they used to sit inside the Z33 extraction `else`. A rename of
# either reader, or a moved closing brace, took the FAIL arm there and silently
# dropped all of them from the run — coverage loss with no record. They are
# hoisted so an extraction failure costs the sanitizer arms and nothing else.
# ---------------------------------------------------------------------------

# The child-spawning function, extracted once for every source pin below.
Z35_PROG="$(awk '/^zen_prompt_and_anchor\(\) \{/,/^\}$/' "$HOOK")"
if [ -z "$Z35_PROG" ]; then
  check "Z35/Z37/Z38 the child-spawning function could not be extracted from the hook — no source pin below is measuring anything" FAIL
fi

# Z38 the module guard, pinned at SOURCE — and the reason it cannot be
# behavioural is worth stating, because the obvious fixture does not work.
#
# Making a module unloadable means editing the tree `CLAUDE_PLUGIN_ROOT` names,
# which here is the live repository. A COPY does not help either: Session
# Control binds the executing plugin root by runtime digest, so a copied or
# modified root makes `zensu_bind_hook_session` refuse and the hook exits 0
# before it reaches the anchor at all — the arm would then measure the binding,
# not the guard. CLAUDE.md records the same conclusion for the requirements
# gate's load-fault branch, and takes the same route.
#
# THE ORDER is the property, not the presence. Verifying and requiring one
# module at a time was the first spelling and did not hold: `zen-anchor-v1.js`
# requires `chain-recovery-v1.js` at top level, so the sibling was executed by
# the FIRST require, before its own check could refuse it. A guard that runs
# after the file has executed is not a guard.
# TWO conditions, because the line-order arm alone passes the shape it exists
# to forbid: verify-then-require inside ONE loop keeps the verification line
# lexically first while iteration 1 executes a module before iteration 2 checks
# it. So the loop BODY must also contain no require at all.
Z38_LOOP="$(printf '%s' "$Z35_PROG" | sed -n '/resolved\.forEach(/,/^[[:space:]]*});$/p')"
Z38_VERIFY="$(printf '%s' "$Z35_PROG" | grep -n 'lstatSync(p).isFile()' | head -1 | cut -d: -f1)"
Z38_REQUIRE="$(printf '%s' "$Z35_PROG" | grep -n 'require(resolved\[' | head -1 | cut -d: -f1)"
if [ -z "$Z38_LOOP" ]; then
  check "Z38 the module verification loop could not be sliced — the pin is not measuring anything" FAIL
elif printf '%s' "$Z38_LOOP" | grep -q 'require('; then
  check "Z38 the verification loop REQUIRES a module inside its own body — a sibling executes before the next iteration checks it" FAIL
elif [ -z "$Z38_VERIFY" ] || [ -z "$Z38_REQUIRE" ]; then
  check "Z38 the verification or the require could not be located — the pin is not measuring anything" FAIL
elif [ "$Z38_VERIFY" -lt "$Z38_REQUIRE" ]; then
  check "Z38 every module is verified before ANY of them is required" PASS
else
  check "Z38 a module is required at line $Z38_REQUIRE before the check at line $Z38_VERIFY — the sibling executes before its own guard" FAIL
fi
if printf '%s' "$Z35_PROG" | grep -q 'fault = "modules"'; then
  check "Z38a a module fault is disclosed under its own class" PASS
else
  check "Z38a a module fault carries no named class, so it is indistinguishable from a document fault" FAIL
fi

# Z43 every MARK the module declares must appear in both hook-side copies.
#
# The mark set exists in three places: `zen-anchor-v1.js` derives its own regex
# from its constants, the `node -e` program hand-spells it as \uXXXX escapes,
# and the shell grammar walk hand-spells it a third time. Only the module half
# was ever pinned.
#
# IT COMPARES THE MARK SET, NOT A RENDERED TOKEN, and that distinction was
# MEASURED. The first spelling rendered every producible token and required
# both hook readers to accept it — and a probe that added a fifth mark to the
# module left it GREEN, because `anchorTokenSafe` refuses a token carrying an
# unknown mark and `anchorToken` therefore answers `none`, so no token bearing
# the new mark ever reached the check. The module censors its own divergence;
# only the declared constants expose it.
Z43_REPORT="$(PLUGIN_DIR="$PLUGIN_DIR" \
  Z43_NODE_CLASS="$(printf '%s' "$Z35_PROG" | grep -o '/\^(?:none.*\$/' | head -1)" \
  Z43_SHELL_WALK="$Z33_GRAMMAR" \
  node -e '
  const mod = require(process.env.PLUGIN_DIR + "/hooks/lib/zen-anchor-v1.js");
  // DERIVED, with a floor. A closed four-element hand list caught a DELETED
  // constant and a hook copy carrying an undeclared mark, and was blind to the
  // symmetric case: a mark ADDED to the module, admitted by `anchorTokenSafe`
  // and accepted by neither hook-side reader, reported OK.
  const names = Object.keys(mod).filter(function (k) { return /^MARK_/.test(k); }).sort();
  if (names.length < 4) {
    process.stdout.write("mark-export-surface-short<" + names.length + ">");
    process.exit(0);
  }
  const bad = [];
  const declared = [];
  // ARITY IS CHECKED, never filtered. `filter(Boolean)` was the first spelling
  // and it made a DELETED constant invisible: the surviving marks all matched,
  // the loop ran fewer times, and the check reported green over a module that
  // had lost a mark. A missing or non-string constant is the finding.
  names.forEach(function (n) {
    const v = mod[n];
    if (typeof v !== "string" || v.length === 0) { bad.push("undeclared<" + n + ">"); return; }
    const cp = v.codePointAt(0);
    // NON-BMP IS REFUSED, not silently mis-checked. The node-side class spells a
    // mark as a four-digit \\uXXXX, which cannot express a codepoint above
    // U+FFFF at all — that needs a surrogate pair or a \\u{...}. Looking for a
    // five-digit `uXXXXX` that no such class can contain would report a spurious
    // absence; looking for its first four digits would report a spurious match.
    if (cp > 0xFFFF) { bad.push("non-bmp<" + n + "/U+" + cp.toString(16).toUpperCase() + ">"); return; }
    if (Array.from(v).length !== 1) { bad.push("not-one-char<" + n + ">"); return; }
    declared.push({ name: n, mark: v, hex: cp.toString(16).toUpperCase().padStart(4, "0") });
  });
  const nodeClass = process.env.Z43_NODE_CLASS || "";
  const shellWalk = process.env.Z43_SHELL_WALK || "";
  if (!nodeClass) bad.push("node-grammar-unextractable");
  if (!shellWalk) bad.push("shell-walk-unextractable");
  if (declared.length && nodeClass && shellWalk) {
    declared.forEach(function (d) {
      if (nodeClass.toUpperCase().indexOf("U" + d.hex) === -1) {
        bad.push("node-class-missing<" + d.name + "/U+" + d.hex + ">");
      }
      if (shellWalk.indexOf("\u0027" + d.mark + "\u0027") === -1) {
        bad.push("shell-walk-missing<" + d.name + ">");
      }
    });
    // THE REVERSE DIRECTION. The forward arm alone leaves a hook copy free to
    // carry a mark the module never produces, which is a reader accepting a
    // token no writer can mint — the same divergence, pointing the other way.
    const declaredHex = declared.map(function (d) { return d.hex; });
    const declaredMark = declared.map(function (d) { return d.mark; });
    (nodeClass.toUpperCase().match(/\\U[0-9A-F]{4}/g) || []).forEach(function (esc) {
      const hex = esc.slice(2);
      if (declaredHex.indexOf(hex) === -1) bad.push("node-class-undeclared<U+" + hex + ">");
    });
    // ANCHORED ON THE MARK DISPATCH, not on any `\u0027X\u0027*)` in the walk:
    // the field loop also opens with a leading-space guard of exactly that shape,
    // and an unanchored scan reported the SPACE as an undeclared mark. Both the
    // case pattern and the prefix the arm strips are captured, because an arm
    // that matches one mark and strips another would pass a pattern-only scan
    // while silently mangling every field it accepts.
    const armRe = /\u0027(.)\u0027\*\)[ \t]*_zag_body="\$\{_zag_field#(.)\}"/g;
    let arm;
    let armCount = 0;
    while ((arm = armRe.exec(shellWalk)) !== null) {
      armCount += 1;
      if (arm[1] !== arm[2]) { bad.push("shell-walk-arm-mismatch<" + arm[1] + "/" + arm[2] + ">"); continue; }
      if (declaredMark.indexOf(arm[1]) === -1) bad.push("shell-walk-undeclared<" + arm[1] + ">");
    }
    if (armCount === 0) bad.push("shell-walk-no-mark-arms");
  }
  process.stdout.write(bad.length ? bad.join(" ") : "OK");
' 2>&1)"
if [ "$Z43_REPORT" = "OK" ]; then
  check "Z43 the module mark set and both hook-side copies agree in both directions" PASS
else
  check "Z43 mark-set divergence or an unusable input: $Z43_REPORT" FAIL
fi


# Z48 the hook's own pre-open guard on the workflow document must survive.
#
# It does TWO jobs and only one of them is now belt. The shared reader's
# `O_NONBLOCK` closed the blocking half for every caller, so deleting this guard
# leaves every behavioural arm in this suite green — Z32a still yields `none`,
# Z32b the implementing anchor, Z32c/Z32d/Z32e `none` plus an active mode. What
# would go unnoticed is the OTHER job: `readWorkflowState` reaches
# `ensureDescendantDirectory`, which CREATES the missing components, so an
# unguarded read makes a per-prompt hook mkdir `<project>/.zensu/state` in every
# project that has none. No observable in this suite distinguishes that, so the
# pin is at source, and it pins the ORDER rather than mere presence.
Z48_BODY="$(printf '%s' "$Z35_PROG" | grep -v '^[[:space:]]*//')"
Z48_LSTAT="$(printf '%s' "$Z48_BODY" | grep -n 'fs\.lstatSync(doc)' | head -1 | cut -d: -f1)"
Z48_READ="$(printf '%s' "$Z48_BODY" | grep -n 'readWorkflowState(' | head -1 | cut -d: -f1)"
if [ -z "$Z48_LSTAT" ]; then
  check "Z48 the document is read with no lstat pre-check - an unguarded read CREATES .zensu/state on every prompt" FAIL
elif [ -z "$Z48_READ" ]; then
  check "Z48 no readWorkflowState call was found - the pin is not measuring anything" FAIL
elif [ "$Z48_LSTAT" -lt "$Z48_READ" ]; then
  check "Z48 the document is lstat-ed before it is read" PASS
else
  check "Z48 the lstat does not precede the read, so the directory-creating path runs first" FAIL
fi


# Z50 the marker-resolution guards and the hardened marker write are pinned.
#
# FOUR of round 3`s production fixes shipped with no check of any kind, which is
# the same class this suite exists to close. The round that found four defects
# inside round 2`s own code shipped its own fixes with the same exposure.
# BOTH comment syntaxes are stripped. `grep -v '^[[:space:]]*#'` removes full-line
# SHELL comments only, so a `// fs.renameSync(...)` inside either embedded node
# program survived it and satisfied even a call-anchored grep with the call gone -
# measured, not argued: commenting the call out left this check green.
Z50_HOOK_SRC="$(grep -vE '^[[:space:]]*(#|//)' "$HOOK")"
Z50_OOB="$PLUGIN_DIR/hooks/lib/zensu-zen-mode.sh"
Z50_BAD=""
# (a) a present-but-not-regular marker resolves OFF. Without this arm a FIFO is
#     neither a symlink nor a regular file, so resolution fell through to the
#     configured default - which ships TRUE - and unreadable state IMPOSED the
#     mode, then the off-phrase write opened that FIFO blocking.
# THE RULE MOVED TO THE SHARED LIBRARY, so these two arms grade the CALL rather
# than a copy of the ladder. Both files spelled it themselves, which is why Z50
# caught a deletion and never a one-sided addition; Z89 owns the single-owner
# property and drives the predicate itself, and what is left here is that each
# reader still consults it with its own three paths.
printf '%s' "$Z50_HOOK_SRC" \
  | grep -qF 'zen_marker_shape_fault "$ZEN_ROOT/.zensu" "$ZEN_STATE_DIR" "$MARKER"' \
  || Z50_BAD="$Z50_BAD hook:does-not-consult-the-shared-shape-rule"
# (c) a non-traversable state directory does not fall through to the default.
# THE WALK, not a named pair. Naming components has been wrong twice here, so
# what is pinned is that the ladder consults a predicate which walks them.
# THE PREDICATE IS SHARED, so it is asserted where it LIVES and consumed where
# it is used. Both readers of the marker call one implementation in
# `zensu-session.sh`; a private copy in either is the drift this replaces.
Z50_ZEN_LIB="$PLUGIN_DIR/hooks/lib/zensu-zen-shared.sh"
grep -qE '^zen_path_untraversable\(\) \{' "$Z50_ZEN_LIB" \
  || Z50_BAD="$Z50_BAD lib:no-untraversable-predicate"
printf '%s' "$Z50_HOOK_SRC" | grep -qE '^elif zen_path_untraversable ' \
  || Z50_BAD="$Z50_BAD hook:untraversable-predicate-not-in-ladder"
# (d) the marker is PUBLISHED BY RENAME, never truncated in place.
# ANCHORED ON A CALL POSITION. The comment strip removes full-line SHELL
# comments only, so a `// renameSync` inside either embedded node program
# survives it and satisfied a bare name grep with the call gone - the class
# Z47 was rewritten to close.
printf '%s' "$Z50_HOOK_SRC" | grep -qE '(^|[^A-Za-z_.])fs\.renameSync\(' \
  || Z50_BAD="$Z50_BAD hook:marker-write-not-rename"
# ANY truncating redirect at the marker, not one historical spelling. The
# first arm matched only the `&& { printf ... }` lead-in, so the ordinary
# regression shape - a plain `printf ... > "$MARKER"` on its own line -
# matched nothing.
printf '%s' "$Z50_HOOK_SRC" | grep -qE '>[[:space:]]*"\$(MARKER|ZEN_MARKER)"' \
  && Z50_BAD="$Z50_BAD hook:truncating-redirect-returned"
# (e) THE OUT-OF-BAND WRITER carries the same three guards. It is the remedy the
#     hook NAMES when the in-band escape is unavailable, so hardening one of two
#     writers to one file leaves the guarantee false.
if [ ! -f "$Z50_OOB" ]; then
  Z50_BAD="$Z50_BAD oob:missing"
else
  Z50_OOB_SRC="$(grep -vE '^[[:space:]]*(#|//)' "$Z50_OOB")"
  # An empty slice makes every FORBIDDING arm below it agree, so it is checked
  # rather than assumed. Z98 derives this obligation; it is not a local habit.
  [ -n "$Z50_OOB_SRC" ] || Z50_BAD="$Z50_BAD oob:source-slice-is-empty"
  printf '%s' "$Z50_OOB_SRC" \
    | grep -qF 'zen_marker_shape_fault "$ZEN_ZENSU_DIR" "$ZEN_STATE_DIR" "$ZEN_MARKER"' \
    || Z50_BAD="$Z50_BAD oob:does-not-consult-the-shared-shape-rule"
  printf '%s' "$Z50_OOB_SRC" | grep -qE '(^|[^A-Za-z_.])fs\.renameSync\(' \
    || Z50_BAD="$Z50_BAD oob:write-not-rename"
  printf '%s' "$Z50_OOB_SRC" | grep -qE '>[[:space:]]*"\$(MARKER|ZEN_MARKER)"' \
    && Z50_BAD="$Z50_BAD oob:truncating-redirect-returned"
  printf '%s' "$Z50_OOB_SRC" | grep -qE 'zen_path_untraversable ' \
    || Z50_BAD="$Z50_BAD oob:no-untraversable-arm"
fi
if [ -z "$Z50_BAD" ]; then
  check "Z50 both marker writers carry the component guard, the non-regular arm and a rename landing" PASS
else
  check "Z50 a marker guard is missing:$Z50_BAD" FAIL
fi

# Z51 the fault-path prompt recovery is pinned, including the branch that does
# NOT run it. Three 5 s ladders are reachable in series against a 20 s
# registration, and the elapsed < 3 s gate is what holds the worst case at the
# hook header`s 3 + 5 + 5 = 13 s; a killed HOOK loses the whole directive, which
# is strictly worse than the anchor loss the recovery repairs. Nothing graded any
# of it. (Z87 is what keeps this sentence and the manifest in step - an earlier
# spelling here named a 10 s registration the manifest had stopped carrying.)  # zensu-retired-figure
Z51_BAD=""
# THE SKIP IS DECIDED ON ELAPSED TIME, not on a two-literal status table.
# `124` is GNU timeout's status and `137` is 128+SIGKILL; a child TERMed by
# anything else reports 143, matched neither, and spawned a second full ladder -
# the exact outcome the arm exists to prevent. And on a host with neither
# `timeout` nor `gtimeout` - base macOS - nothing ever reports 124 at all, so the
# arm was dead code on the platform where the worst case is unbounded. A
# wall-clock test is true for every implementation and covers the third ladder
# too. The status test is KEPT as an independent second trigger, widened to a
# comparison so 143 and every other kill status reach it.
printf '%s' "$Z50_HOOK_SRC" | grep -qF 'ZEN_T0=$SECONDS' \
  || Z51_BAD="$Z51_BAD no-elapsed-baseline"
printf '%s' "$Z50_HOOK_SRC" | grep -qE '\$\(\([[:space:]]*SECONDS - ZEN_T0[[:space:]]*\)\)' \
  || Z51_BAD="$Z51_BAD no-elapsed-measurement"
printf '%s' "$Z50_HOOK_SRC" | grep -qE 'ZEN_ELAPSED"?[[:space:]]+-ge' \
  || Z51_BAD="$Z51_BAD no-elapsed-skip-test"
printf '%s' "$Z50_HOOK_SRC" | grep -qE 'ZEN_CHILD_RC"?[[:space:]]+-ge[[:space:]]+124' \
  || Z51_BAD="$Z51_BAD no-status-skip-test"
printf '%s' "$Z50_HOOK_SRC" | grep -qE '^[[:space:]]*124\|137\)' \
  && Z51_BAD="$Z51_BAD two-literal-status-table-returned"
for Z51_W in 'recovery skipped' 'recovery failed' 'the recovery read no prompt'; do
  printf '%s' "$Z50_HOOK_SRC" | grep -qF "$Z51_W" || Z51_BAD="$Z51_BAD <$Z51_W>"
done
printf '%s' "$Z50_HOOK_SRC" | grep -qE 'zen_prompt_only[^(]' \
  || Z51_BAD="$Z51_BAD recovery-never-called"
if [ -z "$Z51_BAD" ]; then
  check "Z51 the recovery skip is decided on elapsed time, and all three distinct causes survive" PASS
else
  check "Z51 the recovery ladder lost a branch:$Z51_BAD" FAIL
fi

# Z52 EVERY node child in this hook is scanned, not only the one in
# zen_prompt_and_anchor.
#
# Z35, Z41, Z46 and Z48 all derive from that ONE function, and round 3 added two
# further `node -e` programs outside it - so writing `PAYLOAD="$INPUT" node -e ...`
# in the recovery child would put the verbatim user prompt back into
# /proc/<pid>/cmdline with Z41 green.
#
# TWO CORRECTIONS over the first spelling, and CI found both because the check
# itself could not fail here. It scanned the WHOLE FILE for non-ASCII, so it
# reported the em dash inside the OFF directive - ordinary directive prose that
# reaches no argv - as an argv leak. And it did that through `grep -nP`, which is
# a GNU extension: the two hosts disagreed, so the same tree was green on macOS
# and red on ubuntu. The scan is in `node` now, which has one answer everywhere,
# and it is bounded to the PROGRAM TEXT of each child rather than the file.
Z52_REPORT="$(HOOK="$HOOK" node -e '
  const fs = require("fs");
  const src = fs.readFileSync(process.env.HOOK, "utf8");
  const bad = [];
  // Each child is `node -e '"'"'` ... `'"'"'` - a single-quoted shell string, so the
  // program ends at the next apostrophe and no apostrophe may appear inside it.
  // That is the same property the hook states about itself.
  const starts = [];
  const marker = "node -e " + String.fromCharCode(39);
  for (let i = src.indexOf(marker); i !== -1; i = src.indexOf(marker, i + 1)) starts.push(i);
  // THE FLOOR IS THE CHILD COUNT, not a token above zero. At 2 against three
  // children the scan reported agreement after one child had been deleted or
  // its locator had stopped matching - the same "zero-match reads as agreement"
  // shape this file already carries as the G12a and Z19b precedents. Z37 derives
  // the same roster and floors it identically; the two must move together.
  if (starts.length < 3) {
    process.stdout.write("too-few-children<" + starts.length + ">");
    process.exit(0);
  }
  starts.forEach(function (at) {
    const from = at + marker.length;
    const to = src.indexOf(String.fromCharCode(39), from);
    if (to === -1) { bad.push("unterminated-program"); return; }
    const body = src.slice(from, to);
    const line = src.slice(0, from).split("\n").length;
    body.split("\n").forEach(function (l, k) {
      if (/^\s*\/\//.test(l)) return;
      for (const ch of l) {
        if (ch.codePointAt(0) > 0x7F) {
          bad.push("non-ascii<line " + (line + k) + "/" + JSON.stringify(ch) + ">");
          return;
        }
      }
    });
  });
  // NO ASSIGNMENT MAY FOLLOW A COMMAND WORD on a spawn line, and the position is
  // the whole point. A LEADING `NAME=v cmd` sets NAME in that command`s
  // environment and appears in no argv. The same token written AFTER a command
  // word is an ordinary ARGUMENT to it - which is the historical leak here:
  // `zensu_run_bounded PAYLOAD="$INPUT" node -e ...` made the ladder exec
  // `timeout 5 PAYLOAD=... node -e ...`, putting the verbatim user prompt into
  // timeout`s own argv for the child`s whole life. Matching `NAME= node -e`
  // adjacently would miss exactly that shape, so the tokens are walked instead.
  // CONTINUATIONS ARE JOINED FIRST. The shipped spawn spans two physical lines
  // (`... zensu_run_bounded \\` then `node -e ...`), so a per-line walk skipped
  // the very line carrying the assignment - the historical leak shape passed.
  const joined = [];
  src.split("\n").forEach(function (l, i) {
    const prev = joined.length ? joined[joined.length - 1] : null;
    if (prev && /\\$/.test(prev.text)) {
      prev.text = prev.text.replace(/\\$/, " ") + l.trim();
      return;
    }
    joined.push({ text: l, line: i + 1 });
  });
  joined.forEach(function (entry) {
    const l = entry.text;
    const i = entry.line - 1;
    if (l.indexOf("node -e") === -1) return;
    if (/^\s*#/.test(l)) return;
    const tokens = l.replace(/^\s*[^|]*\|\s*/, "").trim().split(/\s+/);
    let seenCommandWord = false;
    for (const t of tokens) {
      // AN OPERATOR RESETS the walk, it does not merely get skipped. A new
      // command starts after `&&`, so an assignment there is LEADING again and
      // sets an environment rather than passing an argument. Skipping without
      // resetting reported the hook`s own `mkdir ... && ZEN_MARKER=... node`
      // as a leak, because `mkdir` had already been seen on the same line.
      // `if` resets for the same reason: it opens a command, it is not one.
      if (/^(&&|\|\||;|\(|\)|\{|\}|!|\\|if|then|else|elif|do|while|until)$/.test(t)) {
        seenCommandWord = false;
        continue;
      }
      const assign = /^([A-Za-z_][A-Za-z0-9_]*)=/.exec(t);
      if (assign) {
        if (seenCommandWord) bad.push("argv-assignment<line " + (i + 1) + "/" + assign[1] + ">");
        continue;
      }
      seenCommandWord = true;
    }
  });
  process.stdout.write(bad.length ? bad.join(" ") : "OK n=" + starts.length);
' 2>&1)"
case "$Z52_REPORT" in
  OK\ n=*) check "Z52 every node child is free of argv-borne inputs and literal non-ASCII (${Z52_REPORT#OK })" PASS ;;
  *)       check "Z52 a node child carries an argv assignment or literal non-ASCII: $Z52_REPORT" FAIL ;;
esac


# Z53 a non-regular MARKER resolves the mode OFF, driven end to end.
#
# Z50 pins the arm`s source literal and nothing pinned its BEHAVIOUR, in a suite
# that already plants a FIFO for Z32d - on the workflow document, never on the
# marker. Without this arm a FIFO here is neither a symlink nor a regular file,
# so the ladder falls through to the configured default, which ships TRUE:
# unreadable state IMPOSES the mode, and the off-phrase write then opens that
# FIFO BLOCKING. The hook must inject NOTHING instead.
P53="$(mktemp -d -t zenmode-fifo-XXXXXX)"; S53="z53-$$"
new_session "$P53" "$S53"
helper "$P53" "$S53" --on >/dev/null 2>&1
MARKER53="$(find "$P53/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
Z53_CONTROL="$(fire "$P53" "$S53" "control" | classify)"
if [ "$Z53_CONTROL" != "UserPromptSubmit|ON" ]; then
  check "Z53 the fixture does not reach ON before the FIFO - an EMPTY later would prove nothing" FAIL
elif [ -z "$MARKER53" ]; then
  check "Z53 no marker was produced - the fixture is not measuring anything" FAIL
elif ! rm -f "$MARKER53" || ! mkfifo "$MARKER53" 2>/dev/null; then
  skipcheck "Z53 mkfifo is unavailable on this host"
else
  Z53_OUT="$(fire "$P53" "$S53" "where are we?" | classify)"
  case "$Z53_OUT" in
    *ON) check "Z53 a FIFO at the marker still resolved the mode ON - unreadable state imposed it" FAIL ;;
    EMPTY) check "Z53 a FIFO at the marker resolves the mode OFF and the hook injects nothing" PASS ;;
    *)     check "Z53 a FIFO at the marker produced an unexpected result <$Z53_OUT>" FAIL ;;
  esac
  rm -f "$MARKER53"
fi
rm -rf "$P53"

# Z54 a NON-TRAVERSABLE state directory resolves the mode OFF, at BOTH components.
#
# Every test in the ladder fails with EACCES rather than for its own reason, so
# before the arm the fall-through took the configured default and a recorded
# `{"active":false}` was ignored on every prompt. The `.zensu` case is the one a
# leaf-only arm could never catch: its own `[ -d "$ZEN_STATE_DIR" ]` cannot stat
# through an unsearchable parent either.
if [ "$(id -u)" = "0" ]; then
  skipcheck "Z54 running as root, which bypasses the search-permission check"
else
  Z54_BAD=""
  # THREE levels, and the third is why the pair was replaced by a walk: an
  # unsearchable PROJECT ROOT also makes every test in the ladder fail for
  # EACCES, and a hand-listed pair could never see it.
  for Z54_LEVEL in state zensu root; do
    P54="$(mktemp -d -t zenmode-eacces-XXXXXX)"; S54="z54-$$-$Z54_LEVEL"
    new_session "$P54" "$S54"
    helper "$P54" "$S54" --on >/dev/null 2>&1
    case "$Z54_LEVEL" in
      state) Z54_DIR="$P54/.zensu/state" ;;
      zensu) Z54_DIR="$P54/.zensu" ;;
      root)  Z54_DIR="$P54" ;;
    esac
    # POSITIVE CONTROL. Both new checks accept "the hook emitted nothing", which
    # any unrelated fixture fault also produces. Prove the fixture reaches ON
    # BEFORE the directory is broken, so an EMPTY afterwards means the arm.
    if [ "$(fire "$P54" "$S54" "control" | classify)" != "UserPromptSubmit|ON" ]; then
      Z54_BAD="$Z54_BAD fixture-not-on<$Z54_LEVEL>"
      rm -rf "$P54"; continue
    fi
    if ! chmod 000 "$Z54_DIR" 2>/dev/null; then
      Z54_BAD="$Z54_BAD chmod-failed<$Z54_LEVEL>"
    else
      Z54_OUT="$(fire "$P54" "$S54" "where are we?" | classify)"
      case "$Z54_OUT" in
        *ON) Z54_BAD="$Z54_BAD imposed-at<$Z54_LEVEL/$Z54_OUT>" ;;
      esac
      # THE OUT-OF-BAND READER MUST AGREE. Its own `.zensu` half was pinned by
      # nothing - the exact leaf-only defect this work fixed, surviving one file
      # over - and `--status` is the surface a user consults when the mode
      # misbehaves, so a confident wrong `on` there is the worst answer it has.
      Z54_ST="$(helper "$P54" "$S54" --status 2>/dev/null)"
      case "$Z54_ST" in
        *on*) Z54_BAD="$Z54_BAD status-says-on-at<$Z54_LEVEL>" ;;
      esac
      chmod 755 "$Z54_DIR" 2>/dev/null || true
    fi
    rm -rf "$P54"
  done
  if [ -z "$Z54_BAD" ]; then
    check "Z54 an unsearchable state directory resolves OFF at both components" PASS
  else
    check "Z54 an unsearchable directory still imposed the mode:$Z54_BAD" FAIL
  fi
fi

# Z49 the missing `prompt` field is disclosed under its OWN lead-in, and the
# directive still ships.
#
# This is the one fault the hook says costs the user the in-band escape, and it
# had no executed case: `fire` and `fire_err` both build a payload carrying
# `prompt`, so the two `payloadFault` branches were never entered. It also pins
# the SPLIT lead-in - announcing a lost prompt as an unavailable ANCHOR told the
# user the one thing that was still working.
Z49_ERR="$(fire_noprompt_err "$P32" "$S32")"
Z49_OUT="$(fire_noprompt "$P32" "$S32")"
Z49_KIND="$(printf '%s' "$Z49_OUT" | classify)"
case "$Z49_ERR" in
  *'zen-mode prompt unavailable (prompt field)'*)
    if [ "$Z49_KIND" = "UserPromptSubmit|ON" ]; then
      check "Z49 a payload with no prompt field discloses under its own lead-in and still injects the directive" PASS
    else
      check "Z49 a payload with no prompt field cost the whole directive (kind '$Z49_KIND')" FAIL
    fi ;;
  *'zen-mode anchor unavailable'*)
    check "Z49 a lost PROMPT was announced as an unavailable ANCHOR - the wrong loss is named" FAIL ;;
  *)
    check "Z49 a payload with no prompt field degraded SILENTLY - stderr carried <$Z49_ERR>" FAIL ;;
esac

# Z47 the sanitizer must invoke BOTH readers, and the hook must still call it.
#
# `zen_anchor_grammar_ok` subsumes `zen_anchor_bytes_ok` on the language the
# grammar ACCEPTS, so deleting the byte call leaves every behavioural table in
# this suite green: Z33 and Z33b each drive their own reader directly, and the
# composition itself was graded by nothing.
#
# ANCHORED ON A COMMAND POSITION, the way Z37 is, and for the same measured
# reason: the comment strip removes only FULL-LINE comments, so a trailing
# `# zen_anchor_bytes_ok retired` on a surviving line satisfied a bare name grep
# while the call itself was gone.
Z47_MISSING=""
if [ -z "$(printf '%s' "$Z33_SANITIZE" | tr -d '[:space:]')" ]; then
  check "Z47 the sanitizer body could not be extracted - the pin is not measuring anything" FAIL
else
  for Z47_F in zen_anchor_grammar_ok zen_anchor_bytes_ok; do
    printf '%s' "$Z33_SANITIZE" | grep -v '^[[:space:]]*#' \
      | grep -qE "^[[:space:]]*$Z47_F[[:space:]]" \
      || Z47_MISSING="$Z47_MISSING <$Z47_F>"
  done
  if [ -z "$Z47_MISSING" ]; then
    check "Z47 the sanitizer consults both the grammar reader and the byte reader" PASS
  else
    check "Z47 the sanitizer no longer consults a reader:$Z47_MISSING" FAIL
  fi
fi

# Z47a THE HOOK MUST STILL CALL IT. Every check that grades this function - Z33,
# Z33b, Z34, Z47 - extracts the text and drives it directly, so deleting the
# single production call site left all four grading a function nothing invokes,
# with every behavioural arm green because the child had already validated the
# same token against its own grammar. That deletes exactly the reader positioned
# to refuse a truncated mid-write token.
Z47A_REST="$(awk '/^zen_anchor_sanitized\(\) \{/{skip=1} skip!=1{print} skip==1 && /^\}$/{skip=0}' "$HOOK")"
if [ -z "$(printf '%s' "$Z47A_REST" | tr -d '[:space:]')" ]; then
  check "Z47a the hook minus the sanitizer definition came back empty - the pin is not measuring anything" FAIL
elif printf '%s' "$Z47A_REST" | grep -q 'zen_anchor_sanitized() {'; then
  check "Z47a the definition survived the slice - the pin cannot tell a definition from a call" FAIL
elif printf '%s' "$Z47A_REST" | grep -v '^[[:space:]]*#' \
     | grep -qE 'ZEN_ANCHOR="\$\(zen_anchor_sanitized'; then
  check "Z47a the hook still routes the arrived token through the sanitizer" PASS
else
  check "Z47a the sanitizer is defined and never called - the third reader is unwired" FAIL
fi

# Z41 NO child input may travel in an ARGUMENT VECTOR, and the payload may not
# travel in the environment either.
#
# THREE corrections over the first spelling, and each closed a real hole. It
# judged `PAYLOAD` alone, so the session key could have moved back onto the
# command line with the check green. Its argv arm was POSITIONAL, so
# `zensu_run_bounded env FOO=1 PAYLOAD="$INPUT" node ...` matched neither
# pattern while the export was still present, and the verbatim prompt sat in
# two argument vectors under a PASS. And its name list was hand-spelled, so a
# fourth input added only on the command line was judged by nothing.
#
# What it pins now is TOTAL: the spawn lines carry no `NAME=value` token at all,
# whatever the name; the payload is PIPED rather than exported, which is what
# both sibling consumers of this payload already do; and every name the child
# actually reads from the environment is one the spawn actually exports.
Z41_CODE="$(printf '%s' "$Z35_PROG" | grep -v '^[[:space:]]*#')"
Z41_SPAWN="$(printf '%s' "$Z41_CODE" | grep -nE 'zensu_run_bounded' | cut -d: -f1)"
Z41_ARGV="$(printf '%s' "$Z41_CODE" \
  | grep -E 'zensu_run_bounded' \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*=' | sort -u | tr '\n' ' ')"
# Every name the child READS, derived from the program rather than listed here.
Z41_READS="$(printf '%s' "$Z41_CODE" | grep -oE 'process\.env\.[A-Za-z_][A-Za-z0-9_]*' \
  | sed 's/process\.env\.//' | sort -u)"
Z41_UNEXPORTED=""
while IFS= read -r Z41_V; do
  [ -n "$Z41_V" ] || continue
  printf '%s' "$Z41_CODE" \
    | grep -qE "export([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)*[[:space:]]+$Z41_V=" \
    || Z41_UNEXPORTED="$Z41_UNEXPORTED <$Z41_V>"
done <<Z41EOF
$Z41_READS
Z41EOF
if [ -z "$Z41_SPAWN" ]; then
  check "Z41 no spawn line was found in the child-spawning function — the pin is not measuring anything" FAIL
elif [ -z "$Z41_READS" ]; then
  check "Z41 the child reads no environment name — the derivation found nothing and the pin is not measuring anything" FAIL
elif [ -n "$Z41_ARGV" ]; then
  check "Z41 a NAME=value token sits on the spawn command line — /proc/<pid>/cmdline is world-readable on Linux: $Z41_ARGV" FAIL
elif printf '%s' "$Z41_CODE" | grep -qE '(export|env)[[:space:]][^|]*PAYLOAD='; then
  check "Z41 the payload travels in the environment, which process listings and crash reporters capture and stdin is not" FAIL
elif ! printf '%s' "$Z41_CODE" | grep -qE "printf '%s' \"\\\$INPUT\" \| zensu_run_bounded"; then
  check "Z41 the payload is not piped to the bounded child — the stdin channel the sibling consumers use is not in force" FAIL
elif [ -n "$Z41_UNEXPORTED" ]; then
  check "Z41 the child reads an environment name the spawn never exports:$Z41_UNEXPORTED" FAIL
else
  check "Z41 no child input travels in an argv, the payload is piped, and every name the child reads is exported" PASS
fi

# Z42 a fault the CHILD cannot see must still be disclosed.
#
# The child owns the named fault classes `Z46_DECLARED` enumerates, but its writer runs inside the child:
# a watchdog kill and a failed `cd -P` produce no line at all, which is exactly
# the "dead child" case the disclosure was written for. The guarantee therefore
# has to be stated at the layer that observes every outcome — the parent, on an
# empty capture or a non-zero child status. Source pins, because neither outcome
# is reachable from a fixture: the `cd` target is the live plugin tree that the
# plugin-root identity check validates, and a watchdog kill needs a child that
# hangs, which the O_NONBLOCK fix removed.
if grep -q 'anchor unavailable (child failed or was bounded' "$HOOK" \
   && grep -q 'anchor unavailable (child produced nothing)' "$HOOK" \
   && grep -qE 'echo "zensu: zen-mode anchor unavailable \(child failed or was bounded[^"]*" >&2' "$HOOK" \
   && grep -qE 'echo "zensu: zen-mode anchor unavailable \(child produced nothing\)" >&2' "$HOOK"; then
  check "Z42 the parent discloses a child that produced nothing, on stderr" PASS
else
  check "Z42 a killed child or an unreachable hooks/lib is SILENT — the disclosure guarantee is not total" FAIL
fi
if printf '%s' "$Z35_PROG" | grep -q 'cd -P -- .* || exit 1'; then
  check "Z42a an unreachable hooks/lib exits non-zero so the parent can see it" PASS
else
  check "Z42a the cd arm exits 0, so an unreachable hooks/lib is indistinguishable from success" FAIL
fi

# Z37 the child must run under the SHARED watchdog ladder.
#
# This hook spawns a `node` child on every prompt of every zen-mode session,
# and that child reads outside the process — which is the criterion
# `zensu_run_bounded` states for the two Stop-path children it already serves.
# A hand-copied ladder is what this repository records as the defect that
# created the shared one: the `gtimeout` arm reached one copy and not the
# other. So the pin is the SYMBOL, not a spelling of `timeout`.
#
# NOT a bite for a hang: the ladder falls through to an UNBOUNDED arm when
# neither `timeout` nor `gtimeout` exists, which is base macOS, so on this host
# the wrapper changes nothing at run time. It is a source pin for that reason
# and the limitation is stated at the call site rather than implied here.
# Z40 the registration must carry a host-side deadline of its own.
#
# It is the OUTER bound: `zensu_run_bounded` above bounds the child, and on a
# host with neither `timeout` nor `gtimeout` it bounds nothing, so this is what
# remains. Nothing read it — `test-readme-hook-count-sync.sh` extracts hook
# FILENAMES and never looks at the value, so it could be deleted with the whole
# tree green. State its cost rather than only its presence: it kills the whole
# hook, so a turn that hits it loses the entire directive, not just the anchor.
Z40_T="$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  let out = ""; let seen = 0;
  for (const groups of Object.values(d.hooks || {})) {
    for (const g of groups) {
      for (const h of (g.hooks || [])) {
        if (String(h.command || "").includes("user-prompt-zen-mode.sh")) {
          seen += 1;
          out = Number.isInteger(h.timeout) && h.timeout > 0 ? String(h.timeout) : "invalid";
        }
      }
    }
  }
  process.stdout.write(seen > 1 ? "multiple" : (out || "unregistered"));
' "$PLUGIN_DIR/hooks/hooks.json" 2>/dev/null)"
case "$Z40_T" in
  ''|unregistered) check "Z40 the zen-mode hook is not registered in hooks.json — the pin is not measuring anything" FAIL ;;
  invalid)         check "Z40 the zen-mode registration carries no usable timeout — null, 0 and false all read as absent here" FAIL ;;
  multiple)        check "Z40 the zen-mode hook is registered more than once — the last registration would silently decide" FAIL ;;
  *)               check "Z40 the zen-mode registration carries a timeout ($Z40_T s)" PASS ;;
esac

# EVERY child, derived from the hook, not the one this file happened to slice.
#
# It asserted over `$Z35_PROG` alone - the child inside `zen_prompt_and_anchor` -
# while the hook spawns THREE. Dropping the wrapper from either of the other two
# passed this check, and one of them is the child whose unbounded run forced the
# registration budget from 10 s to 20 s in the first place. Z52 already derives
# its roster from the hook for exactly this reason; this one now does the same.
#
# Over the STRIPPED body and anchored on a command position: the literal also
# appears in the rationale comment above each call, so a whole-slice grep was
# satisfied by prose and the wrapper could be deleted with this check green.
# The command position may follow a PIPE, because one payload travels on stdin
# rather than through the environment. Both forms are accepted; what stays
# pinned is that the wrapper occupies a command position and is not merely named
# in prose.
#
# A ZERO-MATCH DERIVATION FAILS: no child found means the locator broke, which
# reads exactly like "every child is wrapped" unless it is checked.
Z37_FLOOR=3
Z37_BAD=""
Z37_JS="$CONTROL_TMP/z37-children.js"
cat > "$Z37_JS" <<'Z37EOF'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
const marker = "node -e " + String.fromCharCode(39);
let found = 0;
const bare = [];
lines.forEach(function (line, i) {
  if (line.indexOf(marker) === -1) return;
  if (/^\s*#/.test(line)) return;
  found += 1;
  // The wrapper may sit on this line or on a continued command line above it.
  // Walk back over continuations and blank/comment lines only.
  let text = line;
  for (let k = i - 1; k >= 0 && i - k <= 4; k--) {
    const prev = lines[k];
    if (/^\s*#/.test(prev) || prev.trim() === "") continue;
    text = prev + "\n" + text;
    if (!/\\$/.test(prev.trim()) && !/\|\s*$/.test(prev.trim())) break;
  }
  const commandPosition = text
    .split("\n")
    .filter(function (l) { return !/^\s*#/.test(l); })
    .some(function (l) { return /(^|\|)\s*zensu_run_bounded(\s|\\|$)/.test(l); });
  if (!commandPosition) bare.push(String(i + 1));
});
process.stdout.write("FOUND " + found + "\n");
if (bare.length) process.stdout.write("BARE " + bare.join(",") + "\n");
Z37EOF
Z37_OUT="$(node "$Z37_JS" "$HOOK" 2>&1)"
Z37_RC=$?
Z37_FOUND="$(printf '%s\n' "$Z37_OUT" | sed -n 's/^FOUND \([0-9]*\)$/\1/p' | head -1)"
Z37_BARE="$(printf '%s\n' "$Z37_OUT" | sed -n 's/^BARE //p')"
if [ "$Z37_RC" -ne 0 ] || [ -z "$Z37_FOUND" ]; then
  Z37_BAD="$Z37_BAD locator-did-not-run<$(printf '%s' "$Z37_OUT" | head -2 | tr '\n' ';')>"
else
  [ "$Z37_FOUND" -ge "$Z37_FLOOR" ] \
    || Z37_BAD="$Z37_BAD found-only-$Z37_FOUND-children-want-at-least-$Z37_FLOOR"
  [ -z "$Z37_BARE" ] || Z37_BAD="$Z37_BAD unwrapped-child-at-line<$Z37_BARE>"
fi
if [ -z "$Z37_BAD" ]; then
  check "Z37 every node child in the hook runs under the shared watchdog ladder" PASS
else
  check "Z37 a child is spawned with no deadline — it reads outside the process and must go through zensu_run_bounded:$Z37_BAD" FAIL
fi
if grep -q 'zensu-bounded-run.sh' "$HOOK"; then
  check "Z37a the hook sources the ladder rather than hand-copying one" PASS
else
  check "Z37a zensu_run_bounded is named but hooks/lib/zensu-bounded-run.sh is never sourced" FAIL
fi

# Z35 the node program must carry no literal non-ASCII in its argv.
#
# The four marks sat in the `node -e` program text as literal UTF-8, so the
# anchor grammar travelled through the argument vector as bytes above 0x7F. On
# a path that is not UTF-8 clean those bytes are mangled, the grammar stops
# matching its own vocabulary and the anchor dies SILENTLY — and only on that
# host, which is the failure mode this repository already records for the MSYS
# argv namespace. `\uXXXX` escapes carry the identical set with no such byte.
#
# It scans the WHOLE function rather than the `node -e` argument alone, which is
# a deliberate over-reach: a shell comment never reaches argv, so the extra rule
# this imposes is that comments inside this one function stay ASCII. That is
# cheaper than a parse that has to find where the quoted program begins and
# ends, and it has already caught two em dashes added by later edits.
if ! printf '%s' "$Z35_PROG" | grep -q 'anchorToken'; then
  check "Z35 the extracted slice does not contain the node program — a negative scan over it would pass vacuously" FAIL
elif printf '%s' "$Z35_PROG" | LC_ALL=C grep -q '[^ -~	]'; then
  check "Z35 the child-spawning function carries literal non-ASCII: inside the node program it reaches argv, and in a comment it fails this scan by the over-reach stated above" FAIL
else
  check "Z35 the child-spawning function carries no literal non-ASCII, so none can reach the node argv" PASS
fi


# Z45 the inner watchdog must be stricter than the outer registration timeout.
#
# The ladder bounds the child, the registration bounds the whole hook. If the
# inner bound were the larger of the two, the hook would be killed first and the
# child would never reach its own deadline, so the ladder would buy nothing. The
# relation is correct today and was asserted nowhere.
Z45_INNER="$(grep -oE '\b(g?timeout) [0-9]+' "$PLUGIN_DIR/hooks/lib/zensu-bounded-run.sh" | grep -oE '[0-9]+' | sort -n | tail -1)"
Z45_OUTER="$Z40_T"
case "${Z45_OUTER:-}" in ''|*[!0-9]*) Z45_OUTER="" ;; esac
if [ -z "$Z45_INNER" ] || [ -z "$Z45_OUTER" ]; then
  check "Z45 one of the two bounds could not be read — the pin is not measuring anything" FAIL
elif [ "$Z45_INNER" -lt "$Z45_OUTER" ]; then
  check "Z45 WHERE A WATCHDOG EXISTS the shared ladder ($Z45_INNER s) bounds the child inside the registration timeout ($Z45_OUTER s); with neither timeout nor gtimeout the ladder bounds nothing and the registration kills the whole hook" PASS
else
  check "Z45 the ladder ($Z45_INNER s) is not stricter than the registration timeout ($Z45_OUTER s), so the hook dies before the child does" FAIL
fi

# Z46 the fault-class vocabulary is pinned in BOTH directions.
#
# The classes cannot live in `zen-anchor-v1.js`, which a reviewer suggested:
# one of them exists precisely for the case where that module cannot be loaded,
# so the vocabulary has to survive its absence. Pinning the set here is the half
# that is achievable.
#
# TWO CORRECTIONS over the first spelling, both of which made it weaker than it
# read. It grepped the RAW slice, so a class name occurring only in a COMMENT
# satisfied it — the body could stop emitting a class entirely and the check
# stayed green. And it was a one-way hand list, so a class ADDED to the child
# was pinned by nothing. The set is now derived from the assignment sites in the
# comment-stripped body and compared against the declared list both ways.
Z46_BODY="$(printf '%s' "$Z35_PROG" | sed 's,//.*,,')"
# THE CARRIER SET IS DERIVED TOO. Hardcoding `payloadFault|fault` bounded the
# derivation to two identifiers, so a third carrier — `let readFault = ""` folded
# into the emission — would ship unpinned in both directions while this check
# reported agreement. The identifiers come from the emission sites themselves:
# every `process.stderr.write` argument in the child body, plus any `.filter(
# Boolean)` array feeding one. A derivation that finds nothing FAILS.
Z46_CARRIERS="$(printf '%s' "$Z46_BODY" \
  | grep -oE '\b[a-zA-Z_][a-zA-Z0-9_]*Fault\b|\bfault\b' \
  | sort -u | tr '\n' '|' | sed 's/|$//')"
if [ -z "$Z46_CARRIERS" ]; then
  Z46_CARRIERS='payloadFault|fault'
  Z46_CARRIER_DERIVATION=fallback
else
  Z46_CARRIER_DERIVATION=derived
fi
Z46_EMITTED="$(printf '%s' "$Z46_BODY" \
  | grep -oE "($Z46_CARRIERS) = \"[^\"]+\"" \
  | sed 's/.*= "//; s/"$//' \
  | sort -u)"
Z46_DECLARED="$(printf '%s\n' 'no session anchor' 'modules' 'workflow document' \
  'anchor render' 'token rejected' 'anchor unmapped' 'internal' 'prompt field' 'payload' | sort -u)"
if [ -z "$Z46_EMITTED" ]; then
  check "Z46 no fault-class assignment was found in the child body — the pin is not measuring anything" FAIL
elif [ "$Z46_EMITTED" = "$Z46_DECLARED" ]; then
  check "Z46 the child emits exactly the declared fault-class vocabulary" PASS
else
  Z46_MISSING=""
  Z46_EXTRA=""
  while IFS= read -r Z46_C; do
    [ -n "$Z46_C" ] || continue
    printf '%s\n' "$Z46_EMITTED" | grep -qxF "$Z46_C" || Z46_MISSING="$Z46_MISSING <$Z46_C>"
  done <<Z46DECL
$Z46_DECLARED
Z46DECL
  while IFS= read -r Z46_C; do
    [ -n "$Z46_C" ] || continue
    printf '%s\n' "$Z46_DECLARED" | grep -qxF "$Z46_C" || Z46_EXTRA="$Z46_EXTRA <$Z46_C>"
  done <<Z46EMIT
$Z46_EMITTED
Z46EMIT
  check "Z46 fault-class vocabulary diverges — declared-but-unemitted:[$Z46_MISSING] emitted-but-undeclared:[$Z46_EXTRA]" FAIL
fi

# --- Z60..Z63 PR #285 review findings -------------------------------------
#
# Z60 the hook hands the CLASSIFIER REPORT to the anchor module, not the bare
# shape. `awaiting-self-review` and `self-review-unbindable` are reached from
# `codeReviewDone === true`, and that flag does not mean the review passed: the
# bound max-round handoff sets it with `outcome=max-rounds`. The module can only
# tell those apart from the report, so passing `report.shape` alone renders the
# passed mark for a review that ran out of budget.
P60="$(mktemp -d -t zenmode-outcome-XXXXXX)"; S60="z60-$$"
new_session "$P60" "$S60"
arm_chain "$P60" "$S60"
Z60_DOC="$(find "$P60/.zensu/state" -maxdepth 1 -name 'tdd-phase-*.json' 2>/dev/null | head -1)"
z60_patch() { # <outcome|-> ; '-' means standalone (no link fields at all)
  node -e '
    const fs = require("fs");
    const f = process.argv[1];
    const outcome = process.argv[2];
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    j.implComplete = true;
    j.codeReviewDone = true;
    j.reviewTicket = "t1";
    j.reviewTicketConsumed = true;
    j.reviewRound = 1;
    if (outcome === "-") {
      delete j.autopilotRunId; delete j.autopilotAttempt;
      delete j.autopilotReturnStage; delete j.chainId; delete j.chainOutcome;
    } else {
      j.autopilotRunId = "run-z60";
      j.autopilotAttempt = 1;
      j.autopilotReturnStage = "GATES";
      j.chainId = "chain-z60";
      j.chainOutcome = outcome;
    }
    fs.writeFileSync(f, JSON.stringify(j));
  ' "$Z60_DOC" "$1" 2>/dev/null
}
if [ -z "$Z60_DOC" ]; then
  check "Z60 outcome arm could not run - arming wrote no workflow document" FAIL
  check "Z60a outcome arm could not run - arming wrote no workflow document" FAIL
  check "Z60b outcome arm could not run - arming wrote no workflow document" FAIL
else
  Z60_ERRFILE="$P60/.z60-err"
  : > "$Z60_ERRFILE"
  if ! z60_patch max-rounds; then
    check "Z60 the workflow document could not be rewritten" FAIL
  else
    Z60_OUT="$(ZEN_ERRFILE="$Z60_ERRFILE" fire "$P60" "$S60" "where are we?")"
    Z60_ANCHOR="$(printf '%s' "$Z60_OUT" | anchor_of)"
    Z60_ERR="$(cat "$Z60_ERRFILE" 2>/dev/null || true)"
    if [ "$Z60_ANCHOR" = "Zensu: ✓implement ✗review ·self-review" ] && [ -z "$Z60_ERR" ]; then
      check "Z60 a review that ended max-rounds renders the failed mark, silently" PASS
    else
      check "Z60 expected the max-rounds anchor, got '$Z60_ANCHOR' (stderr <$Z60_ERR>)" FAIL
    fi
  fi
  : > "$Z60_ERRFILE"
  if ! z60_patch ""; then
    check "Z60a the workflow document could not be rewritten" FAIL
  else
    Z60A_OUT="$(ZEN_ERRFILE="$Z60_ERRFILE" fire "$P60" "$S60" "where are we?")"
    Z60A_ANCHOR="$(printf '%s' "$Z60A_OUT" | anchor_of)"
    Z60A_ERR="$(cat "$Z60_ERRFILE" 2>/dev/null || true)"
    if [ "$Z60A_ANCHOR" = "Zensu: ✓implement ✓review ▶self-review" ] && [ -z "$Z60A_ERR" ]; then
      check "Z60a a bound review with no max-rounds stamp still renders as passed" PASS
    else
      check "Z60a expected the converged anchor, got '$Z60A_ANCHOR' (stderr <$Z60A_ERR>)" FAIL
    fi
  fi
  # Z60b the standalone residual, asserted rather than left implicit: with no
  # outcome field in the document neither mark is justified, so the stage renders
  # NOTHING - and that is not a fault, so nothing is disclosed either. This is the
  # discriminator that separates "mapped to null" from "degraded into a fault".
  : > "$Z60_ERRFILE"
  if ! z60_patch -; then
    check "Z60b the workflow document could not be rewritten" FAIL
  else
    Z60B_OUT="$(ZEN_ERRFILE="$Z60_ERRFILE" fire "$P60" "$S60" "where are we?")"
    Z60B_ANCHOR="$(printf '%s' "$Z60B_OUT" | anchor_of)"
    Z60B_KIND="$(printf '%s' "$Z60B_OUT" | classify)"
    Z60B_ERR="$(cat "$Z60_ERRFILE" 2>/dev/null || true)"
    if [ "$Z60B_ANCHOR" = "none" ] && [ "$Z60B_KIND" = "UserPromptSubmit|ON" ] && [ -z "$Z60B_ERR" ]; then
      check "Z60b a standalone chain at the self-review stage renders no anchor and no fault" PASS
    else
      check "Z60b expected a silent none, got '$Z60B_ANCHOR' (kind '$Z60B_KIND', stderr <$Z60B_ERR>)" FAIL
    fi
  fi
fi
rm -rf "$P60"

# Z61 the out-of-band remedy must be RUNNABLE as printed. skills/zen-mode/SKILL.md
# demands the leading CLAUDE_PLUGIN_DATA assignment and an absolute plugin-root
# path, and zensu-zen-mode.sh itself refuses without the former. The sentence is
# emitted exactly where it is the user's only exit, so a hand-built spelling that
# exits 2 leaves no working way out at all.
Z61_MISSING=""
printf '%s' "$Z35_PROG" | grep -q 'ZEN_OFF_REMEDY' || Z61_MISSING="$Z61_MISSING child-copy-not-rendered"
grep -q 'ZEN_OFF_REMEDY=' "$HOOK" || Z61_MISSING="$Z61_MISSING parent-does-not-render"
# RENDERED, not grepped. The two source needles here pinned one SPELLING of the
# interpolation and went red when the values were routed through a quoting helper
# - a correct change failing a check that names the wrong property. What the
# sentence has to satisfy is that it PARSES as a command carrying the assignment,
# an interpreter, an absolute helper path and the verb, with values that would
# otherwise be shell-active neutralised.
Z61_RENDER="$(
  eval "$(awk '/^zen_shell_quote\(\) \{/,/^\}$/' "$HOOK")" 2>/dev/null
  CLAUDE_PLUGIN_DATA='/tmp/d$(id -u) x' CLAUDE_PLUGIN_ROOT='/tmp/r`id -u`'
  eval "$(grep -m1 '^ZEN_OFF_REMEDY=' "$HOOK")" 2>/dev/null
  printf '%s' "${ZEN_OFF_REMEDY:-}"
)"
case "$Z61_RENDER" in
  "CLAUDE_PLUGIN_DATA="*" bash "*"/hooks/lib/zensu-zen-mode.sh"*" --off") : ;;
  *) Z61_MISSING="$Z61_MISSING remedy-shape<$Z61_RENDER>" ;;
esac
# The two shell-active values must survive as LITERALS through one round trip.
Z61_ROUNDTRIP="$(eval "printf '%s\n' ${Z61_RENDER%% bash *}" 2>/dev/null | tail -1)"
[ "$Z61_ROUNDTRIP" = 'CLAUDE_PLUGIN_DATA=/tmp/d$(id -u) x' ] \
  || Z61_MISSING="$Z61_MISSING store-value-not-neutralised<$Z61_ROUNDTRIP>"
grep -cE 'run hooks/lib/zensu-zen-mode\.sh --off' "$HOOK" | grep -qx 0 || Z61_MISSING="$Z61_MISSING bare-relative-spelling-survives"
if [ -z "$Z61_MISSING" ]; then
  check "Z61 both remedy emissions carry the runnable SKILL.md spelling from one rendered variable" PASS
else
  check "Z61 the printed remedy cannot be run as written:$Z61_MISSING" FAIL
fi

# ── Shared source predicates for Z62/Z64/Z65, bite-graded by Z78 ────────────
# Each of these three checks protects exactly ONE production line, and each
# shipped as a needle loose enough to be satisfied by an unrelated site — so the
# line could be deleted with the check green. They are functions rather than
# inline greps so that Z78 can re-run the SAME predicate over a mutated source
# and prove it bites; a hand-copied bite harness drifts away from the check it
# grades and then proves nothing.
#
# Every predicate takes the hook source on $1 and is LINE-SCOPED where the
# property is: a needle whose two halves may sit on different lines is exactly
# the defect Z65 shipped with.

zen_probe_z62() {  # the state-directory probe that keeps three modules unloaded
  printf '%s\n' "$1" | grep -qE '\[ -d "\$ZEN_STATE_DIR" \][^#]*ZEN_ANCHOR_SKIP=1'
}

zen_probe_z64() {  # the setter AND the fold that makes the in-band fallback bite
  printf '%s\n' "$1" | grep -qE '^[[:space:]]*ZEN_OFF_INBAND=1' || return 1
  printf '%s\n' "$1" | grep -qE 'ZEN_OFF_INBAND[^#]*ZEN_OFF=1'
}

zen_probe_z65() {  # the field-separator arm that keeps a complete capture
  printf '%s\n' "$1" | grep -qF -- '*$'"'"'\n'"'"'*)'
}

# Z62 a project with no state directory must not pay for the anchor at all.
# The three requires land BEFORE the document is lstat'ed, and
# session-control-core-v1.js is the largest module in hooks/lib - loaded, parsed
# and executed to read two string constants, on a hook that fires on EVERY
# prompt. The parent already has the directory path in hand from the marker
# ladder, so the probe costs nothing.
if zen_probe_z62 "$(cat "$HOOK")"; then
  check "Z62 the parent skips the anchor child when the state directory is absent" PASS
else
  check "Z62 every prompt loads three modules before the document is even lstat'ed" FAIL
fi

# Z63 the recovery child's comment must not assert the transport this file spends
# thirteen lines rejecting. The security thesis of the merged child is that the
# verbatim prompt never travels in argv or the environment; a maintainer taking
# that clause as the spec would reintroduce all three hazards on the one path
# that carries the user prompt.
if grep -q 'payload out of the environment' "$HOOK"; then
  check "Z63 a comment still claims the recovery child reads the payload out of the environment" FAIL
else
  check "Z63 no comment asserts the environment transport the file rejects" PASS
fi


# Z64 a skipped recovery still leaves an in-band escape.
#
# A workflow document on stalled storage yields the same kill on EVERY prompt, so
# the skip fires every time, the prompt is lost every turn regardless of what the
# user types, and `zen off` can never be seen again this session. The raw payload
# is already in this shell; scanning it for the off phrases costs no child and no
# watchdog budget. A false positive only turns off a presentation mode, while the
# behaviour it replaces can trap the user inside one.
Z64_BAD=""
zen_probe_z64 "$Z50_HOOK_SRC" || Z64_BAD=" the setter or the fold into ZEN_OFF is gone"
if [ -z "$Z64_BAD" ]; then
  check "Z64 a lost prompt still lets the off phrase be seen from the raw payload" PASS
else
  check "Z64 the skip branch leaves no in-band exit:$Z64_BAD" FAIL
fi

# Z65 a complete capture is not discarded because the child exited non-zero.
#
# `timeout` reports its kill status for a command killed at ANY point, including
# after the child has already written `anchor + "\n" + prompt` and is only failing
# to exit - so the capture can be whole. Keeping the prompt half strictly dominates
# discarding it and costs no second process, which is exactly the budget the skip
# exists to protect; the anchor half is already distrusted downstream, because the
# sanitizer answers `none` for anything that fails the grammar walk.
if zen_probe_z65 "$Z50_HOOK_SRC"; then
  check "Z65 a non-zero status keeps a capture that carries the field separator" PASS
else
  check "Z65 every non-zero status blanks the capture, including one that already holds the whole prompt" FAIL
fi


# Z66 a HARD LINK at the marker must not deny deactivation.
#
# The landing never opens the target: it creates a fresh inode with O_EXCL and
# publishes with `renameSync`, and `rename(2)` operates on the directory entry -
# it unlinks the name and leaves any other hard link pointing at the old inode
# with its old content untouched. So the destroy primitive this block was written
# against is closed by the rename ALONE, and the `nlink !== 1` conjunct defends
# nothing the rename does not. What it adds is a refusal that is persistent and
# cheap to trigger: `.zensu/state/` is writable from inside the session, so one
# `ln` made every subsequent off-attempt fail - in-band AND out-of-band, because
# the twin carries the identical conjunct. That is an availability REGRESSION
# against a plain truncating write, which had the destroy hazard but deactivated.
P66="$(mktemp -d -t zenmode-hardlink-XXXXXX)"; S66="z66-$$"
new_session "$P66" "$S66"
# THE MARKER IS ARMED THROUGH THE HELPER, never hand-named: the file is keyed by
# the RESOLVED Session Control key, not by the raw host session id, so a fixture
# that spells the path itself plants its link beside the file the hook writes and
# measures nothing. Z53 arms the same way for the same reason.
helper "$P66" "$S66" --on >/dev/null 2>&1
M66="$(find "$P66/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
if [ -z "$M66" ]; then
  check "Z66 the fixture could not arm a marker - the check is not measuring anything" FAIL
elif ! ln "$M66" "$P66/.zensu/state/.z66-extra-link" 2>/dev/null; then
  skipcheck "Z66 hard links are unavailable on this filesystem"
else
  Z66_OUT="$(fire "$P66" "$S66" "zen off" | classify)"
  Z66_MARKER="$(cat "$M66" 2>/dev/null || true)"
  case "$Z66_MARKER" in
    *'"active"'*false*) Z66_RECORDED=1 ;;
    *) Z66_RECORDED=0 ;;
  esac
  if [ "$Z66_OUT" = "UserPromptSubmit|OFF" ] && [ "$Z66_RECORDED" -eq 1 ]; then
    check "Z66 a hard-linked marker still deactivates, and the choice is recorded" PASS
  else
    check "Z66 one hard link disables the in-band exit (kind '$Z66_OUT', marker <$Z66_MARKER>)" FAIL
  fi
fi
rm -rf "$P66"

# Z67 the off-write verification must be POSITIVE.
#
# `grep -q '"active".*true' || ZEN_OFF_RECORDED=1` establishes only "the marker
# does not say true". An ABSENT, unreadable or truncated marker satisfies that
# exactly as a correct `{"active":false}` does - and the resolution ladder treats
# an absent marker as "fall through to the configured default", which ships TRUE.
# So the one outcome this check exists to catch, the write not landing, scored as
# success: the user was told the mode is now off and the next prompt re-injected it.
Z67_BAD=""
printf '%s' "$Z50_HOOK_SRC" | grep -qE 'ZEN_OFF_RECORDED=1' \
  || Z67_BAD="$Z67_BAD flag-never-set"
# THE PROPERTY, NOT THE SPELLING. This arm required a positive `false` needle,
# which was ONE way to make an absent marker score as failure; the shipped way is
# now the `[ -f "$MARKER" ]` conjunct, because the verification had to become the
# NEGATED resolution predicate so the two readers of this file ask one question
# (Z86 owns that half). An absent marker fails `-f` either way, which is what this
# check is actually about, so it is asserted directly.
# FLATTENED, because the statement spans a line continuation and `$Z50_HOOK_SRC`
# is comment-stripped, so neither a comment anchor nor a line-scoped needle can
# address it.
Z67_FLAT="$(printf '%s\n' "$Z50_HOOK_SRC" | tr '\n' ' ' | tr -s ' ')"
printf '%s' "$Z67_FLAT" \
  | grep -qE '\[ -f "\$MARKER" \] && \[ ! -L "\$MARKER" \][^;]*! zen_marker_active' \
  || Z67_BAD="$Z67_BAD absent-marker-can-score-as-success"
printf '%s' "$Z67_FLAT" | grep -qE 'grep -q .\"active\"[^|]*true[^|]*\|\| *ZEN_OFF_RECORDED=1' \
  && Z67_BAD="$Z67_BAD bare-negative-verification-returned"
if [ -z "$Z67_BAD" ]; then
  check "Z67 the off-write is verified positively, so an absent marker scores as failure" PASS
else
  check "Z67 the off-write verification passes on an absent marker:$Z67_BAD" FAIL
fi

# Z68 a killed write must not leak a temp file forever. The suffix is random
# rather than the pid - correctly, because a pid collision turns one crash into a
# permanent refusal of the in-band exit - but the consequence of randomness is
# that every killed write leaks a DISTINCT file and nothing reaps it. The sweep
# runs where `mkdir -p -m 700` already does, so it costs no extra path resolution.
if printf '%s' "$Z50_HOOK_SRC" | grep -qE '\.tmp-' \
   && printf '%s' "$Z50_HOOK_SRC" | grep -qE 'find .*\.tmp-\*|-name .*\.tmp-'; then
  check "Z68 stale temp siblings of the marker are swept where the state directory is created" PASS
else
  check "Z68 every killed off-write leaks a distinct temp file that nothing reaps" FAIL
fi

# Z69 the off-write child uses the sibling`s subshell-export shape.
#
# POSIX leaves a prefix assignment on a FUNCTION invocation unspecified, and in
# bash outside POSIX mode it also leaks the variable past the call. The sibling
# child 270 lines above uses an explicit `export` inside a subshell and carries a
# comment explaining why; two shapes for one job in one file is what drifts.
if printf '%s' "$Z50_HOOK_SRC" | grep -qE 'ZEN_MARKER="\$MARKER" zensu_run_bounded'; then
  check "Z69 the off-write still uses a prefix assignment on a shell function" FAIL
else
  check "Z69 the off-write child uses the same subshell-export shape as its sibling" PASS
fi


# --- Z70..Z75 the OUT-OF-BAND writer, which the hook NAMES as the remedy -------
#
# Z50(e) pins this script`s three guards at SOURCE only, while the hook`s twins
# are driven end to end. The asymmetry is in the EVIDENCE, not in the code: every
# `helper` invocation in the new block is `--on` (Z53/Z54 fixture setup) or
# `--status` (Z54), so the non-regular refusal, the nlink arm and every failure
# arm of the node writer had no executed case at all.
Z70_CFG="$CONTROL_TMP/zenmode-off.json"
printf '%s' '{"hooks":{"zenMode":false}}' > "$Z70_CFG"
P70="$(mktemp -d -t zenmode-oob-XXXXXX)"; S70="z70-$$"
new_session "$P70" "$S70"
# THE ARMING STDERR IS KEPT. "could not arm a marker" named no cause, so a fixture
# that stopped working reported a wall rather than a diagnosis - the same class
# this round is fixing in the product.
Z70_ARM="$(CLAUDE_CODE_SESSION_ID="$S70" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
  CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P70" \
  ZENSU_CONFIG="$NO_CONFIG" bash "$HELPER" --on 2>&1 >/dev/null)"
M70="$(find "$P70/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
if [ -z "$M70" ]; then
  check "Z70 the out-of-band fixture could not arm a marker: <$Z70_ARM>" FAIL
  check "Z71 the out-of-band fixture could not arm a marker" FAIL
  check "Z74 the out-of-band fixture could not arm a marker" FAIL
else
  # Z70 a FIFO at the marker: the helper must REFUSE with a nameable message and
  # leave the FIFO untouched. A plain redirect opens one BLOCKING with no reader,
  # which is the wedge this whole class exists to remove - and this script is what
  # the hook points at when the in-band escape is already unavailable.
  rm -f "$M70"
  if ! mkfifo "$M70" 2>/dev/null; then
    skipcheck "Z70 mkfifo is unavailable on this host"
  else
    Z70_ERR="$(CLAUDE_CODE_SESSION_ID="$S70" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P70" \
      ZENSU_CONFIG="$NO_CONFIG" bash "$HELPER" --off 2>&1 >/dev/null)"
    Z70_RC=$?
    if [ -p "$M70" ] && [ "$Z70_RC" -ne 0 ] && printf '%s' "$Z70_ERR" | grep -q 'not a regular file'; then
      check "Z70 a FIFO at the marker makes the out-of-band writer refuse, by name, without touching it" PASS
    else
      check "Z70 the out-of-band writer did not refuse a FIFO nameably (rc=$Z70_RC, err <$Z70_ERR>)" FAIL
    fi
    rm -f "$M70"
  fi

  # Z71 a HARD LINK must not deny the out-of-band exit either. Same argument as
  # Z66 one file over: the landing publishes by rename, so the destroy primitive
  # is closed by the rename alone and the nlink conjunct only costs the remedy.
  helper "$P70" "$S70" --on >/dev/null 2>&1
  if ! ln "$M70" "$P70/.zensu/state/.z71-extra-link" 2>/dev/null; then
    skipcheck "Z71 hard links are unavailable on this filesystem"
  else
    Z71_ERR="$(CLAUDE_CODE_SESSION_ID="$S70" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P70" \
      ZENSU_CONFIG="$NO_CONFIG" bash "$HELPER" --off 2>&1 >/dev/null)"
    if grep -q '"active"[[:space:]]*:[[:space:]]*false' "$M70" 2>/dev/null; then
      check "Z71 a hard-linked marker still deactivates out of band" PASS
    else
      check "Z71 one hard link disables the out-of-band remedy too <$(cat "$M70" 2>/dev/null)> stderr <$Z71_ERR>" FAIL
    fi
    rm -f "$P70/.zensu/state/.z71-extra-link"
  fi

  # Z74 `--status` must not report `on` for a session whose hook is disabled.
  # zensu_zen_mode_default_on reads only zenModeDefault and never hooks.zenMode,
  # while the hook exits on zenMode before any marker is read - so with the hook
  # disabled and no marker this verb printed `on` while the user saw no zen-mode
  # behaviour at all, which is exactly the state that sends someone to --status.
  rm -f "$M70"
  Z74_OUT="$(CLAUDE_CODE_SESSION_ID="$S70" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P70" \
    ZENSU_CONFIG="$Z70_CFG" bash "$HELPER" --status 2>/dev/null)"
  Z74_ERR="$(CLAUDE_CODE_SESSION_ID="$S70" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P70" \
    ZENSU_CONFIG="$Z70_CFG" bash "$HELPER" --status 2>&1 >/dev/null)"
  if [ "$Z74_OUT" = "off" ] && printf '%s' "$Z74_ERR" | grep -q 'zenMode'; then
    check "Z74 --status reports off and names hooks.zenMode when the hook is disabled" PASS
  else
    check "Z74 --status reports '$Z74_OUT' for a session the hook never injects into (stderr <$Z74_ERR>)" FAIL
  fi
fi
rm -rf "$P70"

# Z72 the out-of-band writer runs under the SAME watchdog as its in-band twin.
# The asymmetry points the wrong way: this script is named as the remedy exactly
# when the in-band path has already failed, and the conditions that make that
# path fail - lstatSync, the O_EXCL open, fsyncSync and renameSync on stalled
# storage - stall here too. RESIDUAL: on a host with neither `timeout` nor
# `gtimeout` the shared ladder falls through to an unbounded arm, so this buys a
# bound only where the host supplies one.
Z72_BAD=""
grep -q 'zensu-bounded-run.sh' "$Z50_OOB" || Z72_BAD="$Z72_BAD ladder-not-sourced"
grep -qE 'zensu_run_bounded[[:space:]]+node' "$Z50_OOB" || Z72_BAD="$Z72_BAD writer-not-wrapped"
if [ -z "$Z72_BAD" ]; then
  check "Z72 the out-of-band writer runs under the shared watchdog ladder" PASS
else
  check "Z72 the out-of-band remedy has no deadline while its in-band twin does:$Z72_BAD" FAIL
fi

# Z73 a SHORT WRITE must not be reported as success. For --off it is harmless
# (the reader greps for an active mode, misses, resolves OFF); for --on the same
# truncation also fails that grep, so the mode reads OFF while this script has
# already printed `zen-mode: on` and exited 0 - the user is told the mode is on
# and it is not, with nothing on any channel.
if grep -qE 'while[[:space:]]*\(.*written|written[[:space:]]*<[[:space:]]*buf' "$Z50_OOB"; then
  check "Z73 the out-of-band write loops until the whole buffer is written" PASS
else
  check "Z73 fs.writeSync return value is ignored, so a short write reports success" FAIL
fi

# Z75 four independent refusals must not collapse into one message. The nlink arm
# was a SECURITY refusal reported as a generic write failure: an operator reading
# `cannot write` checks permissions and disk and never looks for the extra link.
Z75_BAD=""
grep -qE 'process\.exit\(2\)' "$Z50_OOB" || Z75_BAD="$Z75_BAD no-shape-status"
grep -qE 'process\.exit\(3\)' "$Z50_OOB" || Z75_BAD="$Z75_BAD no-open-status"
grep -qE 'process\.exit\(4\)' "$Z50_OOB" || Z75_BAD="$Z75_BAD no-rename-status"
grep -qE 'case[[:space:]]+"?\$ZEN_WRITE_RC' "$Z50_OOB" || Z75_BAD="$Z75_BAD message-not-branched"
if [ -z "$Z75_BAD" ]; then
  check "Z75 the out-of-band writer's refusals are nameable, and the shell branches on them" PASS
else
  check "Z75 four distinct refusals collapse into one undifferentiated message:$Z75_BAD" FAIL
fi


# Z76 the registered timeout is pinned EXACTLY, and its provenance is recorded.
#
# Nothing pinned the value: Z40 accepts any positive integer and Z45 only requires
# it to exceed the ladder`s 5, so `6` and `600` both passed every check in the
# tree. And the number has to cover this hook`s own worst case: THREE ladders are
# reachable in SERIES on one invocation - the merged prompt-and-anchor child, the
# prompt-only recovery child and the off-phrase write, 5 s each - on top of the
# `node` spawns paid before any of them (principal check, session bind, config
# read). The recovery is gated on elapsed < 3 s, so the realized worst case is
# about 13 s of ladder budget rather than the full 15. At 10 the off-phrase
# path alone consumed the whole budget, and the cost lands on the escape hatch:
# the hook is killed while the write child is between its O_EXCL open and its
# rename, the marker never lands, the mode stays on, and the COULD NOT BE
# DEACTIVATED branch never prints because the hook is dead.
#
# The provenance convention is this repository`s own - DENIAL_MARKERS_SOURCE_BUILD,
# SETTINGS_SOURCE_BUILD, ALLOW_BYPASS_SOURCE_BUILD all pin the build a host
# literal was read against. What is recorded here is the build the SIZING was
# derived on; what the host does to the prompt at the deadline stays UNVERIFIED,
# and the header must keep saying so rather than implying a measurement.
Z76_BAD=""
[ "${Z40_T:-}" = "20" ] || Z76_BAD="$Z76_BAD timeout-is-<${Z40_T:-unset}>-not-20"
grep -q 'ZEN_REGISTRATION_TIMEOUT_SOURCE_BUILD' "$HOOK" || Z76_BAD="$Z76_BAD no-provenance-constant"
grep -qE 'ZEN_REGISTRATION_TIMEOUT_SOURCE_BUILD[^0-9]*2\.1\.[0-9]+' "$HOOK" \
  || Z76_BAD="$Z76_BAD provenance-carries-no-build"
# SCOPED to the paragraph that carries the constant. A file-wide needle was
# satisfied by an unrelated comment elsewhere in the hook, so the provenance
# sentence this arm exists to hold could be deleted with Z76 green.
Z76_PROV="$(awk '/ZEN_REGISTRATION_TIMEOUT_SOURCE_BUILD/,/^$/' "$HOOK")"
printf '%s\n' "$Z76_PROV" | grep -qiE '# .*(UNVERIFIED|unverified)' \
  || Z76_BAD="$Z76_BAD deadline-behaviour-claim-lost"
if [ -z "$Z76_BAD" ]; then
  check "Z76 the registration timeout is exactly 20 s and carries its provenance build" PASS
else
  check "Z76 the registration timeout is unpinned or unattributed:$Z76_BAD" FAIL
fi


# Z77 the REMEDY is asserted on the child`s own emitted stderr, not only at source.
#
# Z61 pins both carriers` source and cannot see what actually reaches the user:
# the child interpolates `process.env.ZEN_OFF_REMEDY`, so a spawn that stopped
# exporting it would emit the fallback with every source pin green. This is the
# seam of the S3 cross-layer pairing - the value is rendered in the parent and
# consumed by an unchanged layer - so it is graded where it lands. The fault is
# induced with a payload carrying NO `prompt` field, which is the one path that
# emits the prompt-unavailable sentence.
P77="$(mktemp -d -t zenmode-remedy-XXXXXX)"; S77="z77-$$"
new_session "$P77" "$S77"
Z77_ERR="$(node -e '
    process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:process.argv[1]}));
  ' "$S77" \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P77" \
    ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>&1 >/dev/null)"
Z77_BAD=""
printf '%s' "$Z77_ERR" | grep -q 'prompt unavailable' || Z77_BAD="$Z77_BAD no-prompt-fault-line"
printf '%s' "$Z77_ERR" | grep -q 'CLAUDE_PLUGIN_DATA=' || Z77_BAD="$Z77_BAD no-plugin-data-assignment"
printf '%s' "$Z77_ERR" | grep -qE 'bash .*/hooks/lib/zensu-zen-mode\.sh. --off' || Z77_BAD="$Z77_BAD no-interpreter-or-absolute-path"
printf '%s' "$Z77_ERR" | grep -q 'run hooks/lib/zensu-zen-mode.sh --off' && Z77_BAD="$Z77_BAD bare-relative-spelling-emitted"
if [ -z "$Z77_BAD" ]; then
  check "Z77 the emitted remedy is the runnable SKILL.md spelling, carrying an interpreter and the data assignment" PASS
else
  check "Z77 the remedy the user actually receives is not runnable:$Z77_BAD <$Z77_ERR>" FAIL
fi
rm -rf "$P77"

# Z78 the three source-needle checks above must BITE, and the two unit floors
# must equal the registration counts they guard.
#
# A grep needle that also matches an unrelated site cannot fail for the property
# it names, and this suite shipped three of them: Z62's `[ -d "$ZEN_STATE_DIR" ]`
# also occurs at the positive-verification site, Z64's `ZEN_OFF=1` also occurs at
# the two ordinary off-phrase arms, and Z65's second alternative spans two
# physical lines while grep is line-scoped. All three therefore reduced to "some
# unrelated line exists". This harness deletes the ONE production line each check
# exists to protect and re-runs THAT CHECK'S OWN predicate over the mutated
# source, so the bite is proven here rather than discovered when the line is
# deleted for real. The predicates are shared functions rather than a second copy
# of each pattern: a hand-copied bite harness drifts away from the check it grades
# and then proves nothing, which is the same class this check exists to close.
#
# The floors are held the same way. A floor below the registration count admits
# the deletion of every case the commit added, so it is compared against the
# count rather than asserted as a literal.
Z78_BAD=""
Z78_SRC="$(cat "$HOOK")"

for Z78_FN in zen_probe_z62 zen_probe_z64 zen_probe_z65; do
  if ! command -v "$Z78_FN" >/dev/null 2>&1; then
    Z78_BAD="$Z78_BAD missing-predicate:$Z78_FN"
  fi
done

if [ -z "$Z78_BAD" ]; then
  # Each mutation removes exactly the line the paired check protects.
  Z78_M62="$(printf '%s\n' "$Z78_SRC" | grep -vF -- 'ZEN_ANCHOR_SKIP=1')"
  Z78_M64="$(printf '%s\n' "$Z78_SRC" | grep -vF -- '[ "$ZEN_OFF_INBAND" -eq 1 ] && ZEN_OFF=1')"
  Z78_M65="$(printf '%s\n' "$Z78_SRC" | grep -vF -- '*$'"'"'\n'"'"'*)')"

  zen_probe_z62 "$Z78_SRC" || Z78_BAD="$Z78_BAD z62-rejects-the-real-hook"
  zen_probe_z64 "$Z78_SRC" || Z78_BAD="$Z78_BAD z64-rejects-the-real-hook"
  zen_probe_z65 "$Z78_SRC" || Z78_BAD="$Z78_BAD z65-rejects-the-real-hook"

  zen_probe_z62 "$Z78_M62" && Z78_BAD="$Z78_BAD z62-does-not-bite"
  zen_probe_z64 "$Z78_M64" && Z78_BAD="$Z78_BAD z64-does-not-bite"
  zen_probe_z65 "$Z78_M65" && Z78_BAD="$Z78_BAD z65-does-not-bite"
fi

Z78_N31="$(grep -cE '^[[:space:]]*test\(' "$PLUGIN_DIR/tests/structure/zen-anchor-v1.test.js" 2>/dev/null || echo 0)"
Z78_N29="$(grep -cE '^[[:space:]]*test\(' "$PLUGIN_DIR/tests/structure/zen-anchor-assertions.test.js" 2>/dev/null || echo 0)"
[ "${Z31_FLOOR:-0}" = "$Z78_N31" ] || Z78_BAD="$Z78_BAD z31-floor-${Z31_FLOOR:-unset}-against-$Z78_N31"
# THE OVERVIEW ROWS TOO. Both counts were correct and held by nothing, while this
# check already computes them - so the row could drift the moment a case landed.
Z78_OV="$PLUGIN_DIR/tests/SUITE-OVERVIEW.md"
for Z78_PAIR in "zen-anchor-v1.test.js:$Z78_N31" "zen-anchor-assertions.test.js:$Z78_N29"; do
  Z78_FILE="${Z78_PAIR%%:*}"; Z78_WANT="${Z78_PAIR##*:}"
  Z78_ROW="$(grep -F "\`$Z78_FILE\`" "$Z78_OV" | head -1)"
  if [ -z "$Z78_ROW" ]; then
    Z78_BAD="$Z78_BAD overview-row-missing-for-$Z78_FILE"
  else
    Z78_GOT="$(printf '%s' "$Z78_ROW" | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
    [ "$Z78_GOT" = "$Z78_WANT" ] \
      || Z78_BAD="$Z78_BAD overview-row-$Z78_FILE-says-${Z78_GOT:-none}-want-$Z78_WANT"
  fi
done
[ "${Z29_FLOOR:-0}" = "$Z78_N29" ] || Z78_BAD="$Z78_BAD z29-floor-${Z29_FLOOR:-unset}-against-$Z78_N29"

if [ -z "$Z78_BAD" ]; then
  check "Z78 the source-needle checks bite and both unit floors equal their registration counts" PASS
else
  check "Z78 a check above cannot fail for the property it names:$Z78_BAD" FAIL
fi

# Z79 the off-phrase landing carries no unhardened read and loses no short write.
#
# Three properties of one path, held together because they are one story: the
# in-band `zen off` landing is the ONLY escape from the mode, so every failure
# here re-injects the mode on the next prompt with the user having asked twice.
#
#  (a) THE PRE-RENAME CONTENT COMPARE IS GONE. It re-opened a session-writable
#      path after its own lstat with no O_NOFOLLOW, no O_NONBLOCK and no size
#      bound, so a raced FIFO blocked the child and a hard link to a large file
#      burned the whole off-phrase budget - and on a host with neither `timeout`
#      nor `gtimeout` the ladder runs unbounded, so the registration timeout kills
#      the hook and the marker never lands. It bought only a distinguishable exit
#      for "already off", which the parent already treats as success, while the
#      rename it guarded is idempotent.
#  (b) THE WRITE LOOPS. `writeSync` may write short; the out-of-band twin already
#      loops, and a short write here lands a truncated marker that fails the
#      verification and reports COULD NOT BE DEACTIVATED for a mode that is off.
#  (c) IS GONE, and removal is the fix rather than a loss. It forbade ONE
#      retired spelling of the writer-status gate, while Z86 arm (b) forbids
#      `ZEN_WRITE_RC` from surviving in the hook AT ALL - so the arm could only
#      ever fire in a tree where its owner had already failed, and re-gating in
#      any other spelling passed it. One guarantee, one owner.
#  (d) THE PARENT'S VERIFICATION READ IS BOUNDED AND REFUSES A SYMLINK, and the
#      residual it still carries is named where it is taken. It is the second
#      unguarded read of that path in this hook and the resolution ladder's
#      residual paragraph covered only the first.
Z79_BAD=""
Z79_SRC="$(cat "$HOOK")"
Z79_WRITER="$(printf '%s\n' "$Z79_SRC" | sed -n '/zen_write_off_marker() {/,/^  }$/p')"
[ -n "$Z79_WRITER" ] || Z79_BAD="$Z79_BAD writer-slice-empty"

printf '%s\n' "$Z79_WRITER" | grep -qF 'readFileSync' \
  && Z79_BAD="$Z79_BAD (a)-unhardened-content-read-still-present"
# SLICE-SCOPED, not line-scoped: the loop spans lines, and a line-scoped needle
# here would be the same defect Z65 shipped with.
printf '%s\n' "$Z79_WRITER" | grep -qE '^[[:space:]]*while \(off < buf\.length\)' \
  || Z79_BAD="$Z79_BAD (b)-short-write-not-looped"
printf '%s\n' "$Z79_WRITER" | grep -qE 'const n = fs\.writeSync\(fd, buf' \
  || Z79_BAD="$Z79_BAD (b)-writeSync-return-ignored"
printf '%s\n' "$Z79_SRC" | grep -qE '\[ ! -L "\$MARKER" \]' \
  || Z79_BAD="$Z79_BAD (d)-verification-read-follows-a-symlink"
# THE BYTE CAP IS RETIRED and this arm went with it. Capping the verification
# read while the resolution read is uncapped was itself the divergence that let
# one document satisfy both predicates; Z86 now owns the complement property.
# What remains here is the symlink refusal, which is orthogonal to the cap.
printf '%s\n' "$Z79_SRC" | grep -qF 'SECOND UNGUARDED READ' \
  || Z79_BAD="$Z79_BAD (d)-second-read-residual-unnamed"

# (e) EVERY `node -e` PROGRAM IN THIS HOOK MUST PARSE. The programs are carried in
# SINGLE-quoted shell strings, so one apostrophe in a JS comment - `file's`, the
# ordinary English possessive - closes the string early and hands the remainder to
# the SHELL. The observable is a subshell that exits 126 with the comment text
# reported as a command, which the `2>/dev/null` on the writer call swallows
# whole; the in-band `zen off` escape then dies silently on every prompt. Measured
# in this file, not hypothesised. `bash -n` cannot see it, because the truncated
# string is still valid shell.
Z79_PARSE="$(node -e '
  const fs = require("fs");
  const Q = String.fromCharCode(39);
  const src = fs.readFileSync(process.argv[1], "utf8");
  const marker = "node -e " + Q;
  let i = 0, n = 0, bad = [];
  for (;;) {
    const a = src.indexOf(marker, i);
    if (a < 0) break;
    const s0 = a + marker.length;
    const b = src.indexOf(Q, s0);
    if (b < 0) { bad.push("unterminated-program-" + n); break; }
    const body = src.slice(s0, b);
    n += 1;
    try { new (require("vm").Script)(body); }
    catch (e) { bad.push("program-" + n + "-does-not-parse"); }
    // THE TERMINATOR, because a parsing body is not proof the string closed where
    // the author meant. An apostrophe inside a trailing `//` comment truncates the
    // body to a prefix that is still syntactically complete, so `vm.Script`
    // accepts it while the shell string really did close early. What the shell
    // semantics turn on is what FOLLOWS the closing quote: in this hook every
    // program is closed on its own line, so anything else is the truncation.
    const after = src.slice(b + 1, b + 1 + 40);
    if (!/^[\s]*$|^\s*(\)|&&|\|\||;|\n)/.test(after.split("\n")[0])) {
      bad.push("program-" + n + "-closes-mid-line");
    }
    i = b + 1;
  }
  if (n === 0) bad.push("no-node-programs-found");
  process.stdout.write(bad.join(" "));
' "$HOOK" 2>&1)"
[ -z "$Z79_PARSE" ] || Z79_BAD="$Z79_BAD (e)-$Z79_PARSE"

if [ -z "$Z79_BAD" ]; then
  check "Z79 the off-phrase landing carries no unhardened read and loses no short write" PASS
else
  check "Z79 the in-band escape can still fail silently:$Z79_BAD" FAIL
fi

# Z80 the prose carriers must describe the tree that shipped.
#
# This feature's own ledger section, its hook header, its module comment, its unit
# test title and its suite-overview row are all COUPLED CARRIERS: a maintainer
# navigating by any of them takes an action. Four claims in the ledger, one in the
# hook header, one in the module, one in the unit file and one in the overview
# survived edits that made them false, and one of them is INVERTED against the
# check it cites - it tells a reader to restore an arm the check forbids, which is
# strictly worse than saying nothing. Two censuses are simply wrong: the sibling
# registration count and the number of bounded children reachable in series.
#
# Every arm here is NEGATIVE on a retired literal plus POSITIVE on its
# replacement, because deleting a false sentence and writing nothing leaves the
# next reader with no account at all.
Z80_BAD=""
Z80_MD="$PLUGIN_DIR/CLAUDE.md"
Z80_OVERVIEW="$PLUGIN_DIR/tests/SUITE-OVERVIEW.md"
Z80_ANCHOR_MOD="$PLUGIN_DIR/hooks/lib/zen-anchor-v1.js"
Z80_UNIT="$PLUGIN_DIR/tests/structure/zen-anchor-v1.test.js"
Z80_CFG="$PLUGIN_DIR/docs/configuration.md"

# (1) the nlink refusal the writers no longer make
grep -qF 'the `nlink` check makes the writer REFUSE' "$Z80_MD" \
  && Z80_BAD="$Z80_BAD md-claims-an-nlink-refusal"
# (2) INVERTED: Z51 forbids that arm, it does not pin it
grep -qF 'including its `124|137` watchdog-skip arm' "$Z80_MD" \
  && Z80_BAD="$Z80_BAD md-inverts-what-Z51-pins"
# (3) the retired input contract, in all five carriers
# COMMENT LINES ONLY, and the phrase may be line-wrapped. A bare fixed-string
# scan matched THIS CHECK'S OWN NEEDLE - the self-match class this check exists to
# catch, reproduced inside it on the first spelling.
for Z80_F in "$Z80_MD" "$PLUGIN_DIR/tests/structure/test-zen-mode.sh" "$Z80_UNIT"; do
  grep -qE '^[[:space:]]*(#|//).*takes a shape and' "$Z80_F" \
    && Z80_BAD="$Z80_BAD retired-contract-in-$(basename "$Z80_F")"
done
grep -qF 'does not put on its report' "$Z80_ANCHOR_MOD" \
  && Z80_BAD="$Z80_BAD module-contradicts-its-own-outcome-read"
grep -qF 'accepts no caller-supplied options' "$Z80_OVERVIEW" \
  && Z80_BAD="$Z80_BAD overview-states-the-retired-contract"
grep -qF 'a caller cannot influence a shape' "$Z80_UNIT" \
  && Z80_BAD="$Z80_BAD unit-title-states-the-retired-contract"
# (4) the max-rounds residual, stated as not fixed while the code fixes it
grep -qF 'The real fix is to surface `chainOutcome` on the classifier report' "$Z80_MD" \
  && Z80_BAD="$Z80_BAD md-calls-the-shipped-fix-unimplemented"
# (5) the retired POSIX wording, corrected in the module and not in the hook
grep -qF 'gives the flag no effect on a REGULAR file' "$HOOK" \
  && Z80_BAD="$Z80_BAD hook-header-keeps-the-retired-POSIX-claim"
grep -qF 'LEAVES the flag UNSPECIFIED' "$HOOK" \
  || Z80_BAD="$Z80_BAD hook-header-states-no-replacement"
# (6) and (7) the two censuses, in BOTH carriers
for Z80_F in "$HOOK" "$Z80_CFG"; do
  grep -qE 'five sibling' "$Z80_F" \
    && Z80_BAD="$Z80_BAD wrong-sibling-census-in-$(basename "$Z80_F")"
  grep -qE 'two `zensu_run_bounded` children are reachable in SERIES|two bounded children' "$Z80_F" \
    && Z80_BAD="$Z80_BAD wrong-series-census-in-$(basename "$Z80_F")"
  grep -qE 'three `zensu_run_bounded` children|three bounded children' "$Z80_F" \
    || Z80_BAD="$Z80_BAD no-corrected-series-census-in-$(basename "$Z80_F")"
done
# the census must agree with hooks.json
Z80_TIMEOUT10="$(grep -c '"timeout": 10' "$PLUGIN_DIR/hooks/hooks.json" 2>/dev/null || echo 0)"
grep -qF "$Z80_TIMEOUT10 sibling entries" "$HOOK" \
  || Z80_BAD="$Z80_BAD sibling-census-disagrees-with-hooks.json($Z80_TIMEOUT10)"
# (8) the spliced untraversable comment
# FLATTENED, because the sentence is line-wrapped across the comment prefix and a
# line-scoped needle here would be the very defect this arm grades: the splice put
# an unrelated paragraph BETWEEN the two halves of one sentence.
Z80_FLAT="$(sed 's/^[[:space:]]*#[[:space:]]*//' "$HOOK" | tr '\n' ' ' | tr -s ' ')"
printf '%s' "$Z80_FLAT" | grep -qF 'the fall-through then took the configured default' \
  || Z80_BAD="$Z80_BAD untraversable-comment-still-spliced"
grep -qF "including this arm" "$HOOK" \
  && grep -qF 'BOTH COMPONENTS are tested, exactly as the symlink arm above tests both' "$HOOK" \
  && grep -qF 'walks EVERY component' "$HOOK" \
  || Z80_BAD="$Z80_BAD untraversable-comment-names-the-wrong-mechanism"

if [ -z "$Z80_BAD" ]; then
  check "Z80 every prose carrier of this feature describes the tree that shipped" PASS
else
  check "Z80 a coupled carrier still describes a tree that does not exist:$Z80_BAD" FAIL
fi

# Z81 `none` must not be stated as a biconditional, and the two anchor fault
# classes must be named as the hook actually emits them.
#
# (a) THE `none` SENTENCE. The directive told the model that `none` means "no
#     Zensu chain is armed in this session". It does not: `awaiting-self-review`
#     and `self-review-unbindable` map to null in SHAPE_POSITION, and
#     `outcomePosition` returns null for any report that is not `bound`, so a
#     STANDALONE chain that reaches the self-review stage is armed and still
#     receives `none`. The rendered action is the same either way, so the cost is
#     not a wrong anchor - it is a false premise about its own session handed to
#     the model on every prompt, which is exactly what this feature was built to
#     stop doing. Every carrier of the directive states it, so every carrier moves.
# (b) THE FAULT CLASSES. The operator row claimed BOTH an unmapped shape and a
#     degraded module are disclosed as `anchor unmapped`. In the hook, `fault` is
#     set to `anchor render` BEFORE `mod.anchorToken(report)` and the catch
#     preserves it, so a module that raises discloses `anchor render`;
#     `anchor unmapped` is reached only when the call RETURNED. An operator
#     grepping stderr for the class the row names finds nothing.
Z81_BAD=""
Z81_SKILL="$PLUGIN_DIR/skills/zen-mode/SKILL.md"
Z81_CFG="$PLUGIN_DIR/docs/configuration.md"

# (a) every directive carrier: hook, skill, operator row, and every eval scenario
for Z81_F in "$HOOK" "$Z81_SKILL" "$Z81_CFG" "$PLUGIN_DIR"/evals/zen-mode-reaction/scenarios/*.yaml; do
  [ -f "$Z81_F" ] || continue
  grep -qE "no Zensu chain is armed in this session" "$Z81_F" \
    && Z81_BAD="$Z81_BAD biconditional-in-$(basename "$Z81_F")"
done
grep -qF 'no anchor can be justified this turn' "$HOOK" \
  || Z81_BAD="$Z81_BAD hook-states-no-replacement"
grep -qF 'no anchor can be justified this turn' "$Z81_SKILL" \
  || Z81_BAD="$Z81_BAD skill-states-no-replacement"
grep -qF 'no anchor can be justified this turn' "$Z81_CFG" \
  || Z81_BAD="$Z81_BAD operator-row-states-no-replacement"

# (b) the operator row must split the two classes and must not conflate them
grep -qF 'both disclosed as `anchor unmapped`' "$Z81_CFG" \
  && Z81_BAD="$Z81_BAD operator-row-conflates-the-two-fault-classes"
grep -qF 'a degraded module RAISES and is disclosed as `anchor render`' "$Z81_CFG" \
  || Z81_BAD="$Z81_BAD operator-row-does-not-name-the-render-class"

# The claim is CHECKED against the hook rather than trusted: `anchor render` must
# be assigned before the anchorToken call and `anchor unmapped` after it.
Z81_ORDER="$(grep -n 'fault = "anchor render"\|mod.anchorToken(report)\|fault = "anchor unmapped"' "$HOOK" \
  | sed 's/:.*fault = "anchor render".*/ render/;s/:.*mod\.anchorToken(report).*/ call/;s/:.*fault = "anchor unmapped".*/ unmapped/' \
  | awk '{print $2}' | tr '\n' ' ')"
case "$Z81_ORDER" in
  "render call unmapped "*) : ;;
  *) Z81_BAD="$Z81_BAD hook-order-is-<$Z81_ORDER>-not-render-call-unmapped" ;;
esac

if [ -z "$Z81_BAD" ]; then
  check "Z81 none is stated as a disjunction and both anchor fault classes are named as emitted" PASS
else
  check "Z81 the directive or the operator row states something the hook does not do:$Z81_BAD" FAIL
fi

# Z82 the producible-token set is derived from the MODULE, never re-derived from
# `SHAPE_POSITION` by a consumer.
#
# Four sites derived "every token this module can produce" as
# a map of `anchorToken` over the shape table's own key set, and after the report
# input landed that expression is INCOMPLETE: the two outcome-dependent shapes map to
# null in `SHAPE_POSITION` and are producible only through a bound report, so both
# of their tokens fell outside every derived set. The observable is a carrier
# legitimately holding one being reported `anchor-token-not-producible`, and a
# length ceiling measured against a token that is not the longest.
#
# A consumer cannot check a producer it does not own - the `INERT_SHAPES`
# precedent in CLAUDE.md - so the set moved to the module and the consumers call
# it. This check pins that no consumer grows the derivation back.
Z82_BAD=""
Z82_TOKENS="$(PLUGIN_DIR="$PLUGIN_DIR" node -e '
  const path = require("path");
  const mod = require(path.join(process.env.PLUGIN_DIR, "hooks", "lib", "zen-anchor-v1.js"));
  if (typeof mod.producibleTokens !== "function") { process.stdout.write("NOFN"); process.exit(0); }
  process.stdout.write(mod.producibleTokens().join("\n"));
' 2>/dev/null)"
case "$Z82_TOKENS" in
  NOFN|"") Z82_BAD="$Z82_BAD module-exports-no-producibleTokens" ;;
esac
if [ "$Z82_TOKENS" != "NOFN" ] && [ -n "$Z82_TOKENS" ]; then
  # A report-only token must be in it. Both outcome-dependent shapes render the
  # same step names, so the discriminator is the MARK VECTOR: `✓implement ✗review`
  # is reachable only through a bound `max-rounds` report.
  printf '%s\n' "$Z82_TOKENS" | grep -qF '✓implement ✗review' \
    || Z82_BAD="$Z82_BAD report-only-token-missing-from-the-set"
  # `none` IS producible and a carrier may legitimately hold it: every scenario
  # with no chain armed renders exactly that.
  printf '%s\n' "$Z82_TOKENS" | grep -qx 'none' \
    || Z82_BAD="$Z82_BAD ANCHOR_NONE-missing-from-the-producible-set"
fi
# No consumer may re-derive it. The module's own file is excluded, because the
# derivation has to live somewhere.
Z82_HEAD='Object.keys('
Z82_TAIL='SHAPE_POSITION'
for Z82_F in "$PLUGIN_DIR/tests/structure/test-zen-mode.sh" \
             "$PLUGIN_DIR/tests/structure/test-promptfoo-zen-mode.sh" \
             "$PLUGIN_DIR/tests/structure/zen-anchor-assertions.test.js"; do
  [ -f "$Z82_F" ] || continue
  # THE NEEDLE IS SPLIT ACROSS TWO VARIABLES so the literal never appears whole on
  # any line of this file. Both a regex and a fixed-string spelling matched THIS
  # CHECK'S OWN LINE - the self-match class Z78 exists to close, reproduced twice
  # in one file before it was split.
  # FLATTENED, so a re-derivation wrapped across two physical lines cannot slip
  # through a line-scoped match - the rule Z79 states for itself and Z80 already
  # implements. And SLICED for this file, because a flattened whole-file scan
  # matches this check's own two needle variables, which is the self-match class
  # Z78, Z80, Z82, Z85 and Z87 each hit in turn.
  if [ "$Z82_F" = "$PLUGIN_DIR/tests/structure/test-zen-mode.sh" ]; then
    Z82_TEXT="$(sed -n '1,/^# Z82 the producible-token set is derived/p' "$Z82_F")"
  else
    Z82_TEXT="$(cat "$Z82_F" 2>/dev/null)"
  fi
  Z82_FLAT="$(printf '%s\n' "$Z82_TEXT" | tr '\n' ' ' | tr -s ' ')"
  if printf '%s' "$Z82_FLAT" | grep -qE 'Object\.keys\([^)]*SHAPE_POSITION'; then
    Z82_BAD="$Z82_BAD re-derived-in-$(basename "$Z82_F")"
  fi
done

if [ -z "$Z82_BAD" ]; then
  check "Z82 every consumer reads the producible-token set from the module that owns it" PASS
else
  check "Z82 the producible-token set is re-derived and therefore incomplete:$Z82_BAD" FAIL
fi

# Z83 the in-band escape survives a recovery that RAN and returned nothing, and
# the raw scan no longer matches a filesystem path.
#
# (a) The last-resort scan sat only on the budget-spent arm. The OTHER way to lose
#     the prompt is a recovery that runs and reads nothing - an unparseable
#     payload, a missing or non-string `prompt` - and there `$INPUT` is still in
#     scope and the scan costs no process, so the escape was thrown away for
#     nothing. Both arms must reach it.
# (b) Widening the scan's reach re-opens its accepted false positive, so it is
#     bounded now rather than left as prose: the raw payload carries `cwd` and
#     `transcript_path`, and a worktree or transcript path containing `zen-off`
#     switched the mode off for a user who never asked. Those two values are
#     stripped before the match. RESIDUAL, and it stays one: a future
#     path-bearing field is not covered, and the scan is still over raw JSON
#     rather than the `prompt` field, because in this branch the prompt is
#     precisely what could not be read.
Z83_BAD=""
Z83_SRC="$(cat "$HOOK")"
# EXTRACTED from the shipped hook, never copied here, so this drives the text that
# actually runs - the Z33 pattern.
# THE SHARED ALTERNATION TRAVELS WITH THE FUNCTION. It consumes
# `$ZEN_OFF_PHRASES`, so extracting the body alone leaves an unbound variable -
# which under this suite`s `set -u` aborts the run and fires the EXIT trap that
# removes the shared control store, so every later fixture then fails with a
# misleading "could not arm a marker". Measured in this file.
Z83_FN="$(grep -E '^ZEN_OFF_PHRASES=' "$HOOK"
awk '/^zen_offphrase_in_payload\(\) \{/,/^\}$/' "$HOOK")"
if [ -z "$(printf '%s' "$Z83_FN" | tr -d '[:space:]')" ]; then
  Z83_BAD="$Z83_BAD missing-predicate:zen_offphrase_in_payload"
else
  eval "$Z83_FN"
  command -v zen_offphrase_in_payload >/dev/null 2>&1 \
    || Z83_BAD="$Z83_BAD predicate-did-not-eval"
fi
# TWO call sites: the budget-spent arm and the recovery-returned-nothing arm.
Z83_CALLS="$(printf '%s\n' "$Z83_SRC" | grep -cE '^[[:space:]]*(if|elif) zen_offphrase_in_payload' || true)"
[ "${Z83_CALLS:-0}" -ge 2 ] \
  || Z83_BAD="$Z83_BAD only-${Z83_CALLS:-0}-call-site(s)-want-2"
# SCOPED to the extracted function. A file-wide needle was satisfied by the
# hook's own comment naming the field, so deleting the strip left it green.
printf '%s\n' "$Z83_FN" | grep -qF '"transcript_path"' \
  || Z83_BAD="$Z83_BAD scan-does-not-strip-transcript_path"

if command -v zen_offphrase_in_payload >/dev/null 2>&1; then
  # A path that merely CONTAINS an off phrase must not fire.
  zen_offphrase_in_payload '{"cwd":"/Users/x/zen-off-experiments","prompt":"add a test"}' \
    && Z83_BAD="$Z83_BAD cwd-path-still-switches-the-mode-off"
  zen_offphrase_in_payload '{"transcript_path":"/t/zen off/x.jsonl","prompt":"add a test"}' \
    && Z83_BAD="$Z83_BAD transcript-path-still-switches-the-mode-off"
  # A real off phrase anywhere else must still fire - that is the whole point of
  # the last resort.
  zen_offphrase_in_payload '{"cwd":"/Users/x/p","prompt":"zen off"}' \
    || Z83_BAD="$Z83_BAD a-real-off-phrase-is-no-longer-seen"
  zen_offphrase_in_payload '{"prompt":"please turn off zen"}' \
    || Z83_BAD="$Z83_BAD turn-off-zen-is-no-longer-seen"
  zen_offphrase_in_payload '{"prompt":"add a test"}' \
    && Z83_BAD="$Z83_BAD an-ordinary-prompt-switches-the-mode-off"
fi

if [ -z "$Z83_BAD" ]; then
  check "Z83 both lost-prompt arms reach the in-band escape and the raw scan ignores filesystem paths" PASS
else
  check "Z83 the last-resort in-band escape is missing or over-eager:$Z83_BAD" FAIL
fi

# Z84 `--status` answers `off` for a marker shape the hook resolves to OFF,
# instead of exiting 2 with nothing on stdout.
#
# The two writer guards - a symlinked `.zensu`/state dir/marker, and a
# present-but-non-regular marker - sat at FILE SCOPE, above the verb dispatch, so
# they gated `--status` too. In exactly those states the hook resolves the mode
# OFF and injects nothing, while this verb answered neither `on` nor `off`; and
# `--status` is the surface a user consults when the mode misbehaves. The file`s
# own two other degraded arms already do the opposite and say why: bare `off` on
# stdout, the cause on stderr, because a consumer may compare stdout for equality.
# Coverage was one-sided before this - Z70 drove the non-regular marker through
# `--off` only, Z74 drove `--status` against the config-disabled fixture, and
# nothing drove `--status` against a FIFO or a symlink.
P84="$(mktemp -d -t zenmode-status-shape-XXXXXX)"; S84="z84-$$"
new_session "$P84" "$S84"
# ARMED THROUGH THE HELPER, never hand-named: the marker is keyed by the RESOLVED
# Session Control key, so a fixture that spells the path itself plants its file
# beside the one the helper reads and measures nothing. Z66 and Z53 arm the same
# way for the same reason.
helper "$P84" "$S84" --on >/dev/null 2>&1
M84="$(find "$P84/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
if [ -z "$M84" ]; then
  check "Z84 the marker-shape fixture could not arm a marker" FAIL
else
  Z84_BAD=""
  Z84_RAN=0
  # DIRECT, not through `helper`: that wrapper hardcodes `2>/dev/null`, and the
  # whole contract under test is bare `off` on stdout WITH the cause on stderr.
  z84_run() {  # $1 = verb; sets Z84_OUT / Z84_RC / Z84_ERR
    Z84_OUT="$(CLAUDE_CODE_SESSION_ID="$S84" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P84" \
      ZENSU_CONFIG="$NO_CONFIG" bash "$HELPER" "$1" 2>/dev/null)"
    Z84_RC=$?
    Z84_ERR="$(CLAUDE_CODE_SESSION_ID="$S84" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
      CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$P84" \
      ZENSU_CONFIG="$NO_CONFIG" bash "$HELPER" "$1" 2>&1 >/dev/null)"
  }
  z84_status() { z84_run --status; }

  # (1) a SYMLINKED marker
  # THE FILE'S OWN HELPER, not a raw `ln -s`: this suite states at its top that
  # `ln -s` exiting 0 is not evidence of a symlink, because Git Bash satisfies it
  # with a copy. And an environment that cannot build the fixture is a SKIP, not a
  # failure - Z70/Z71 route the identical unavailability that way.
  rm -f "$M84"; printf 'x' > "$P84/.z84-victim"
  make_file_symlink "$P84/.z84-victim" "$M84" 2>/dev/null || true
  if [ -L "$M84" ]; then
    Z84_RAN=$((Z84_RAN+1))
    z84_status
    [ "$Z84_OUT" = "off" ] || Z84_BAD="$Z84_BAD symlink-stdout<$Z84_OUT>"
    [ "$Z84_RC" -eq 0 ] || Z84_BAD="$Z84_BAD symlink-rc=$Z84_RC"
    printf '%s' "$Z84_ERR" | grep -qi 'symlink' || Z84_BAD="$Z84_BAD symlink-stderr-names-no-cause"
  else
    skipcheck "Z84 native file symlinks are unavailable on this host"
  fi

  # (2) a present-but-NON-REGULAR marker
  rm -f "$M84"
  if mkfifo "$M84" 2>/dev/null; then
    Z84_RAN=$((Z84_RAN+1))
    z84_status
    [ "$Z84_OUT" = "off" ] || Z84_BAD="$Z84_BAD fifo-stdout<$Z84_OUT>"
    [ "$Z84_RC" -eq 0 ] || Z84_BAD="$Z84_BAD fifo-rc=$Z84_RC"
    printf '%s' "$Z84_ERR" | grep -qi 'regular file' || Z84_BAD="$Z84_BAD fifo-stderr-names-no-cause"

    # (3) THE WRITE VERBS STILL REFUSE. Relaxing `--status` must not relax
    # `--off`: a corrupt marker shape is still a refusal there, exit 2, cause named.
    z84_run --off
    Z84_OFF_ERR="$Z84_ERR"
    Z84_OFF_RC="$Z84_RC"
    [ "$Z84_OFF_RC" -eq 2 ] || Z84_BAD="$Z84_BAD off-rc=$Z84_OFF_RC-want-2"
    printf '%s' "$Z84_OFF_ERR" | grep -qi 'regular file' \
      || Z84_BAD="$Z84_BAD off-stderr-names-no-cause"
    rm -f "$M84"
  else
    skipcheck "Z84 mkfifo is unavailable on this host"
  fi

  # MEASURED-NOTHING IS A SKIP, NOT A PASS. `Z84_BAD` is empty both when every arm
  # ran clean and when every arm skipped out, and the terminal reported PASS for
  # both. Five siblings in this file already route that state to `skipcheck`;
  # The instrument that was supposed to catch this - Z90 clause 1, since DELETED -
  # could not, because it keyed on the LABEL wording and this label carries none
  # of its words. That is why the guard here is a COUNTER rather than another
  # phrase to match, and it is why Z97 reads no label at all.
  if [ "${Z84_RAN:-0}" -eq 0 ]; then
    skipcheck "Z84 neither fixture could be built on this host - nothing was measured"
  elif [ -z "$Z84_BAD" ]; then
    check "Z84 --status answers off for a corrupt marker shape while the write verbs still refuse" PASS
  else
    check "Z84 --status and the hook disagree about a corrupt marker shape:$Z84_BAD" FAIL
  fi
fi
rm -rf "$P84"

# Z91 the ledger`s zen-mode account describes the tree that shipped.
#
# CLAUDE.md is the coupled carrier a maintainer navigates by, and this round`s
# panel found eight separate sentences in it that the code contradicts - one of
# them a SAFETY justification the module had explicitly retracted in this same
# PR, and one an export census the bullet contradicts four lines later. Z80
# already grades the hook`s prose; it never scanned CLAUDE.md`s own spellings,
# which is why every one of these survived a round that was fixing exactly this.
Z91_BAD=""
Z91_MD="$PLUGIN_DIR/CLAUDE.md"
Z91_FLAT="$(tr '\n' ' ' < "$Z91_MD" | tr -s ' ')"
# `z91_forbid` below is a presence test, so an empty flattening would report
# every ledger sentence as absent - agreement, from a derivation that broke.
[ -n "$Z91_FLAT" ] || Z91_BAD="$Z91_BAD claude-md-flattening-is-empty"

z91_forbid() {  # $1 = needle, $2 = label
  printf '%s' "$Z91_FLAT" | grep -qF "$1" && Z91_BAD="$Z91_BAD $2"
}
z91_require() {
  printf '%s' "$Z91_FLAT" | grep -qF "$1" || Z91_BAD="$Z91_BAD $2"
}

# R2-01 the retired POSIX safety claim, in CLAUDE.md's own spelling
z91_forbid 'POSIX specifies the flag has no effect on the open of a REGULAR file' md-keeps-the-retracted-POSIX-claim
z91_require 'EAGAIN' md-never-mentions-the-arm-the-guarantee-rests-on
# R2-07 the stale owner-export statement
z91_forbid 'the FAILED mark comes from `RECOVERABLE_SHAPES` / `DEAD_END_SHAPES`' md-names-the-wrong-owner-exports
# R2-08 / R2-13 / JUDGE-5 the export census
z91_forbid 'owes this feature TWO exports' md-export-census-says-two-over-three
z91_forbid 'Removing either leaves the chain-recovery suite green' md-two-way-word-over-a-three-member-list
# R2-14 the Language census
z91_forbid 'the two members named above are a census' md-language-census-says-two-over-three
# R2-29 the worked-example contradiction
z91_forbid 'The worked EXAMPLE in both carriers' md-example-said-to-live-in-both-carriers
# JUDGE-4 the process count
z91_forbid 'checked in THREE PROCESSES by FOUR readers' md-token-reader-process-count-wrong
# R2-09 / R3-22 the chain-recovery consumer clause must name what the MODULE reads.
# It required the disjunction `STUCK_SHAPES` or `ALL_SHAPES`, which was the clause's own
# defect: the module body reads the first and never the second, whose only appearance
# under `hooks/` outside the owner is a comment. Keyed on the corrected POSITIVE form.
z91_require "consumed by that module's UNIT CONTRACT and never by the module" \
  md-consumer-clause-still-credits-the-module-with-ALL_SHAPES
# R3-05 the same roster owes FOUR exports; CHAIN_OUTCOMES was the omitted one
z91_require 'FOUR exports it did not have' md-export-census-says-three-over-four
# R3-07 removing STUCK_SHAPES THROWS; it does not render `none`
z91_require 'refusing to guess the anchor' md-roster-states-the-wrong-removal-mechanism
# R3-08 the module runs INSIDE the node child, so those two are one process
z91_require 'are ONE process' md-process-census-contradicts-its-own-lead
# R3-20 the port host half is SEVEN obligations; the call shape was the omitted one
z91_require 'SEVEN obligations' md-port-host-half-omits-the-call-shape
# R2-10 the port-relevant core half
z91_require 'anchorNoneIsExpected' md-port-core-half-omits-the-new-exports
z91_forbid 'whose stuck sets it reads' md-port-half-keeps-the-plural-framing
# R2-27 residual: the owner seam sentence
z91_forbid 'its optional `owner` parameter is what makes the two `return null` guards reachable' md-owner-seam-claim-overstated
# JUDGE-6 the watchdog roster must still name the out-of-band writer - but NOT in the
# `path.sh:` form it used, which sits one character from the `<file>:<line>` anchor C41
# forbids. Both halves are pinned: the caller by name, and the SHAPE by a rule rather
# than by the retired spelling, so any file name written that way anywhere in the ledger
# is caught rather than only this one.
z91_require 'hooks/lib/zensu-zen-mode.sh` holds the out-of-band writer' \
  md-bounded-run-roster-omits-the-out-of-band-writer
grep -qE '\.(sh|js|mjs|json|md):`' "$Z91_MD" \
  && Z91_BAD="$Z91_BAD md-writes-a-file-name-one-character-from-the-C41-anchor-form"
# R2-30 the patch walk must enumerate what this round actually changed in a module
# every gate loads. The VERDICT is unaffected - none of it is a breaking entry -
# but a walk that omits the change cannot be re-derived by the next reader.
z91_require 'open flag and the paced' md-patch-walk-omits-the-shared-reader-change

if [ -z "$Z91_BAD" ]; then
  check "Z91 the ledger's zen-mode account matches the shipped tree" PASS
else
  check "Z91 a ledger sentence still describes a tree that does not exist:$Z91_BAD" FAIL
fi



# Z89 the marker-shape rule has ONE owner, in the library both readers source.
#
# It was a named predicate in `hooks/lib/zensu-zen-mode.sh` and an inline ladder
# in the hook - two readers of one state, with nothing comparing them. Z50 greps
# each file for its own literals, so a DELETION is caught and a one-sided ADDITION
# is not: a fourth shape rule added to the helper would leave the hook honouring a
# marker the helper refuses, or falling through to the configured default, which
# ships TRUE. Unreadable state imposing the mode is exactly what this file`s
# header forbids.
#
# The seam was already there: the THIRD arm of the same ladder,
# `zen_path_untraversable`, lives in `hooks/lib/zensu-session.sh`, and BOTH files
# source that library. The predicate belongs beside it, parameterized on the three
# paths rather than reading either file`s globals, so each caller applies its own
# consequence - the hook resolves OFF, `--on`/`--off` refuse with exit 2, and
# `--status` prints bare `off` with the cause on stderr.
Z89_BAD=""
Z89_LIB="$PLUGIN_DIR/hooks/lib/zensu-zen-shared.sh"
grep -qE '^zen_marker_shape_fault\(\)' "$Z89_LIB" \
  || Z89_BAD="$Z89_BAD predicate-not-in-the-shared-library"
grep -qE '^zen_marker_shape_fault\(\)' "$PLUGIN_DIR/hooks/lib/zensu-zen-mode.sh" \
  && Z89_BAD="$Z89_BAD helper-keeps-a-private-copy"
# The hook must CALL it rather than spell the ladder inline.
grep -qF 'zen_marker_shape_fault' "$HOOK" \
  || Z89_BAD="$Z89_BAD hook-does-not-call-the-shared-predicate"
Z89_FLAT="$(sed 's/^[[:space:]]*#[[:space:]]*//' "$HOOK" | tr '\n' ' ' | tr -s ' ')"
printf '%s' "$Z89_FLAT" | grep -qE '\[ -L "\$ZEN_ROOT/\.zensu" \] \|\| \[ -L "\$ZEN_STATE_DIR" \]' \
  && Z89_BAD="$Z89_BAD hook-still-spells-the-symlink-ladder-inline"
# PARAMETERIZED, not reading a caller's globals: the two files name their paths
# differently, so a predicate reading `ZEN_ZENSU_DIR` cannot serve both.
Z89_FN="$(awk '/^zen_marker_shape_fault\(\) \{/,/^\}$/' "$Z89_LIB")"
if [ -z "$Z89_FN" ]; then
  Z89_BAD="$Z89_BAD shared-predicate-slice-empty"
else
  printf '%s\n' "$Z89_FN" | grep -qE '\$1|\$2|\$3' \
    || Z89_BAD="$Z89_BAD shared-predicate-takes-no-arguments"
  printf '%s\n' "$Z89_FN" | grep -qF 'ZEN_ZENSU_DIR' \
    && Z89_BAD="$Z89_BAD shared-predicate-still-reads-a-callers-global"
  # It must BITE on both shapes and stay quiet on a healthy one.
  eval "$Z89_FN"
  Z89_T="$(mktemp -d -t zenshape-XXXXXX)"; mkdir -p "$Z89_T/.zensu/state"
  Z89_M="$Z89_T/.zensu/state/m.json"; printf '{"active":true}\n' > "$Z89_M"
  zen_marker_shape_fault "$Z89_T/.zensu" "$Z89_T/.zensu/state" "$Z89_M" >/dev/null \
    && Z89_BAD="$Z89_BAD healthy-marker-reported-as-faulty"
  rm -f "$Z89_M"
  if mkfifo "$Z89_M" 2>/dev/null; then
    zen_marker_shape_fault "$Z89_T/.zensu" "$Z89_T/.zensu/state" "$Z89_M" >/dev/null \
      || Z89_BAD="$Z89_BAD fifo-marker-not-reported"
    rm -f "$Z89_M"
  fi
  ln -s /dev/null "$Z89_M" 2>/dev/null
  if [ -L "$Z89_M" ]; then
    zen_marker_shape_fault "$Z89_T/.zensu" "$Z89_T/.zensu/state" "$Z89_M" >/dev/null \
      || Z89_BAD="$Z89_BAD symlinked-marker-not-reported"
  fi
  rm -rf "$Z89_T"
fi

if [ -z "$Z89_BAD" ]; then
  check "Z89 the marker-shape rule lives once, in the library both readers source" PASS
else
  check "Z89 the marker-shape rule is still spelled twice:$Z89_BAD" FAIL
fi


# Z88 the off-phrase vocabulary has ONE owner, the payload strip is escape-aware,
# and the pasted remedy names its real audience.
#
# (a) ONE ALTERNATION. This round created a SECOND byte-identical copy of the
#     off-phrase pattern, and nothing compared them: a sixth phrase added to one
#     arm would narrow the only in-band escape on the other with every check
#     green - the drift shape this repository already tracks for `WRAP`.
# (b) THE `normal mode` BOUND IS STATED. It is a whole-prompt reduction, so it is
#     structurally out of reach of a scan over raw JSON, while the directive and
#     the operator row advertise it as an escape without qualification. An
#     omission a reader has to infer from two call sites is not recorded.
# (c) THE STRIP IS ESCAPE-AWARE. `"[^"]*"` stops at the first `"` byte, including
#     the `"` of a JSON `\"`, so `{"cwd":"/w/a\"zen off","prompt":"x"}` leaves
#     `zen off"` in the scanned text and the mode is switched off for a user who
#     never asked - while the comment above it asserted the strip UNCONDITIONALLY.
# (d) THE REMEDY NAMES ITS AUDIENCE. The line is labelled as pasted by a human,
#     but the helper it names refuses without `CLAUDE_CODE_SESSION_ID`, which an
#     ordinary shell does not carry. The command is the shipped SKILL.md spelling
#     and is addressed to the MODEL; the label is what misled.
Z88_BAD=""
Z88_SRC="$(cat "$HOOK")"
# Guarded because (b) below is a FORBIDDING scan over this slice, and Z98 derives
# the obligation rather than trusting a habit - it caught this one the moment the
# (a) arm stopped deriving a count from the same variable.
[ -n "$Z88_SRC" ] || Z88_BAD="$Z88_BAD hook-source-slice-is-empty"

# (a) exactly one spelling of the alternation, held in one place.
#
# ORDER-INDEPENDENT, and it has to be: the old arm counted occurrences of ONE
# ORDERING - the literal `stop zen|turn off zen` - so a second copy written with
# the same phrases in any other order counted 0 and the total still read 1.
# That is agreement reported for the exact drift the arm exists to catch. The
# phrases are now DERIVED from the owner assignment and matched as a SET.
Z88_JS="$CONTROL_TMP/z88-alternation.js"
cat > "$Z88_JS" <<'Z88EOF'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
const owners = [];
lines.forEach(function (l, i) { if (/^ZEN_OFF_PHRASES=/.test(l)) owners.push(i); });
process.stdout.write("OWNERS " + owners.length + "\n");
if (owners.length !== 1) process.exit(0);
const owner = lines[owners[0]];
const open = owner.indexOf(String.fromCharCode(39));
const close = owner.lastIndexOf(String.fromCharCode(39));
const value = open === -1 || close <= open ? "" : owner.slice(open + 1, close);
// Split the alternation and keep the parts that name a phrase, stripping the
// boundary groups the pattern wraps them in on both sides.
const alts = value
  .split("|")
  .map(function (a) { return a.replace(/^[^)]*\)\(/, "").replace(/\)\([^)]*$/, "").trim(); })
  .filter(function (a) { return a.indexOf("zen") !== -1 && a.length > 3; });
process.stdout.write("ALTS " + alts.length + "\n");
lines.forEach(function (l, i) {
  if (i === owners[0]) return;
  if (l.indexOf("|") === -1) return;
  let hit = 0;
  alts.forEach(function (a) { if (l.indexOf(a) !== -1) hit += 1; });
  if (hit >= 2) process.stdout.write("COPY " + (i + 1) + "\n");
});
Z88EOF
Z88_OUT="$(node "$Z88_JS" "$HOOK" 2>&1)"
Z88_RC=$?
Z88_OWNERS="$(printf '%s\n' "$Z88_OUT" | sed -n 's/^OWNERS \([0-9]*\)$/\1/p' | head -1)"
Z88_ALTS="$(printf '%s\n' "$Z88_OUT" | sed -n 's/^ALTS \([0-9]*\)$/\1/p' | head -1)"
Z88_COPIES="$(printf '%s\n' "$Z88_OUT" | sed -n 's/^COPY //p' | tr '\n' ',')"
if [ "$Z88_RC" -ne 0 ] || [ -z "$Z88_OWNERS" ]; then
  Z88_BAD="$Z88_BAD alternation-scan-did-not-run<$(printf '%s' "$Z88_OUT" | head -2 | tr '\n' ';')>"
else
  [ "$Z88_OWNERS" -eq 1 ] \
    || Z88_BAD="$Z88_BAD alternation-owner-assigned-$Z88_OWNERS-times-want-1"
  [ "${Z88_ALTS:-0}" -ge 3 ] \
    || Z88_BAD="$Z88_BAD alternation-derivation-found-${Z88_ALTS:-0}-phrases-want-at-least-3"
  [ -z "$Z88_COPIES" ] \
    || Z88_BAD="$Z88_BAD second-alternation-at-line<$Z88_COPIES>"
fi
# (b)
printf '%s\n' "$Z88_SRC" | sed 's/^[[:space:]]*#[[:space:]]*//' | tr '\n' ' ' | tr -s ' ' \
  | grep -qF 'out of reach of a scan over raw JSON' \
  || Z88_BAD="$Z88_BAD normal-mode-bound-unstated"
# (c) the strip must consume escaped quotes, and its claim must be qualified
Z88_FN="$(grep -E '^ZEN_OFF_PHRASES=' "$HOOK"
awk '/^zen_offphrase_in_payload\(\) \{/,/^\}$/' "$HOOK")"
[ -n "$Z88_FN" ] || Z88_BAD="$Z88_BAD strip-function-missing"
printf '%s\n' "$Z88_FN" | grep -qF 'sed -E' \
  || Z88_BAD="$Z88_BAD strip-is-not-escape-aware"
if [ -n "$Z88_FN" ]; then
  eval "$Z88_FN"
  command -v zen_offphrase_in_payload >/dev/null 2>&1 \
    || Z88_BAD="$Z88_BAD strip-function-did-not-eval"
  if command -v zen_offphrase_in_payload >/dev/null 2>&1; then
    # THE ESCAPED-QUOTE PAYLOAD, which is the case the five existing drives miss.
    zen_offphrase_in_payload '{"cwd":"/w/a\"zen off","prompt":"add a test"}' \
      && Z88_BAD="$Z88_BAD escaped-quote-in-cwd-still-switches-the-mode-off"
    zen_offphrase_in_payload '{"transcript_path":"/t/a\"stop zen","prompt":"add a test"}' \
      && Z88_BAD="$Z88_BAD escaped-quote-in-transcript-still-switches-the-mode-off"
    # and the ordinary cases must still behave
    zen_offphrase_in_payload '{"cwd":"/w/p","prompt":"zen off"}' \
      || Z88_BAD="$Z88_BAD a-real-off-phrase-is-no-longer-seen"
    zen_offphrase_in_payload '{"prompt":"add a test"}' \
      && Z88_BAD="$Z88_BAD an-ordinary-prompt-switches-the-mode-off"
  fi
fi
# (d)
printf '%s\n' "$Z88_SRC" | grep -qF 'PASTED BY A HUMAN' \
  && Z88_BAD="$Z88_BAD remedy-still-claims-a-human-audience"
printf '%s\n' "$Z88_SRC" | grep -qF 'hand it to the assistant' \
  || Z88_BAD="$Z88_BAD remedy-does-not-name-its-real-audience"

if [ -z "$Z88_BAD" ]; then
  check "Z88 one off-phrase owner, an escape-aware strip, and a remedy that names its audience" PASS
else
  check "Z88 the escape vocabulary or the pasted remedy still misleads:$Z88_BAD" FAIL
fi


# Z87 the registration budget is stated once, derived from the manifest, and no
# carrier names a value the manifest contradicts.
#
# THREE carriers justified a live guard with a registration budget the manifest
# had stopped carrying, while the hook`s own header computes 3 + 5 + 5 = 13 s -
# the retired figure is deliberately NOT quoted here, because this check scans the
# file it lives in and quoting it would make the check match itself, which is the
# class Z78, Z80, Z82 and Z85 each hit in turn -
# the file contradicted itself twelve lines apart. The consequence is not
# cosmetic: a maintainer working from 10 could DELETE the elapsed<3 gate as
# unnecessary or TIGHTEN it, in opposite directions, from a number nothing holds.
#
# DERIVED, never spelled: the expected value comes from the manifest, so a
# retimed registration reddens every carrier at once instead of leaving one of
# them asserting a number the manifest disagrees with. The sibling census is
# looped over BOTH prose carriers for the same reason - Z80 derived it and then
# checked only the hook.
Z87_BAD=""
Z87_T="$(HOOKS_JSON="$HOOKS_JSON" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.env.HOOKS_JSON, "utf8"));
  const want = "user-prompt-zen-mode.sh";
  let found = "";
  const walk = (n) => {
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!n || typeof n !== "object") return;
    if (typeof n.command === "string" && n.command.indexOf(want) >= 0
        && Object.prototype.hasOwnProperty.call(n, "timeout")) found = String(n.timeout);
    Object.keys(n).forEach((k) => walk(n[k]));
  };
  walk(j);
  process.stdout.write(found);
' 2>/dev/null)"
if ! zen_is_plain_number "${Z87_T:-}"; then
  Z87_BAD="$Z87_BAD registration-timeout-underivable<${Z87_T:-empty}>"
else
  # KEYED ON THE POSITIVE FORM, and VACUITY IS A FAILURE.
  #
  # The previous arm matched a phrasing that occurs in NONE of the carriers, so it
  # could not fail for the property it names: the extraction came back empty on
  # every file, no BAD was appended, and the check reported PASS over exactly the
  # three-carrier drift its own comment says it closes. Editing a carrier to name
  # a budget the manifest contradicts left it green. That is the class this file
  # keeps hitting, so the repair is not a better needle - it is (1) match how the
  # value is ACTUALLY written, and (2) FAIL when a carrier yields no figure at
  # all, because an empty extraction is what silence looks like from inside.
  #
  # The RETIRED figure is deliberately not quoted anywhere here: this check scans
  # the file it lives in, so quoting it would make the check match itself.
  # A line that MARKS a figure as retired is the one exemption, keyed on the
  # marker rather than on the number, so the exemption cannot widen by accident.
  for Z87_F in "$HOOK" "$PLUGIN_DIR/CLAUDE.md" \
               "$PLUGIN_DIR/tests/structure/test-zen-mode.sh" \
               "$PLUGIN_DIR/docs/configuration.md"; do
    Z87_FIGS="$(sed 's/^[[:space:]]*#[[:space:]]*//' "$Z87_F" \
      | grep -v 'zensu-retired-figure' \
      | tr '\n' ' ' | tr -s ' ' \
      | grep -oE "[^.]*registration[^.]*\.|[^.]*[0-9]+ s registration[^.]*\." \
      | grep -oE "[0-9]+ s registration|registration budget of [0-9]+ s" \
      | grep -oE '[0-9]+' | sort -u)"
    if [ -z "$Z87_FIGS" ]; then
      Z87_BAD="$Z87_BAD $(basename "$Z87_F"):names-no-registration-budget"
      continue
    fi
    for Z87_N in $Z87_FIGS; do
      [ "$Z87_N" = "$Z87_T" ] \
        || Z87_BAD="$Z87_BAD $(basename "$Z87_F"):says-${Z87_N}s-manifest-says-${Z87_T}s"
    done
  done
fi
# The sibling census must be checked in BOTH prose carriers, not only the hook.
Z87_T10="$(grep -c '"timeout": 10' "$HOOKS_JSON" 2>/dev/null || echo 0)"
for Z87_F in "$HOOK" "$PLUGIN_DIR/docs/configuration.md"; do
  grep -qF "$Z87_T10 sibling entries" "$Z87_F" \
    || Z87_BAD="$Z87_BAD sibling-census-missing-or-wrong-in-$(basename "$Z87_F")"
done
if [ -z "$Z87_BAD" ]; then
  check "Z87 every carrier states the registration budget the manifest actually holds" PASS
else
  check "Z87 a carrier justifies a guard with a budget the manifest contradicts:$Z87_BAD" FAIL
fi


# Z86 the two readers of the marker agree, the writer's cause survives, and the
# anchor-lost line is emitted only on the path that loses it.
#
# (a) THE VERIFICATION IS THE COMPLEMENT OF THE RESOLUTION, not a second
#     independent predicate. Resolution greps the WHOLE file for `"active":true`;
#     verification greped the first 4096 bytes for `"active":false`. Two
#     predicates over one document can BOTH hold - a crafted marker, or any file
#     whose first 4096 bytes carry `false` while `true` sits past the window - so
#     a landing that failed could score as success while the next prompt
#     re-injected the mode, which is the exact outcome the block's own comment
#     says it exists to catch. This file's stated invariant is that two readers of
#     one state must not disagree; the only way to hold it is to ask the SAME
#     question. The byte cap goes with it: the resolution read is uncapped, so a
#     cap here would BE the divergence.
# (b) `ZEN_WRITE_RC` IS GONE. It was assigned three times and read nowhere -
#     residue of the fix that made the verification unconditional - while its
#     `2>/dev/null` discarded the writer's stderr, so the child's four distinct
#     exits collapsed to one unread value and the emitted fallback could name no
#     cause. Asserting the TOKEN is absent holds the property; the previous arm
#     forbade one retired spelling of the gate and a re-gating in any other
#     spelling passed it.
# (c) THE ANCHOR-LOST LINE BELONGS TO THE ARM THAT LOSES THE ANCHOR. It was
#     emitted for every non-zero child status, including the arm that
#     deliberately KEEPS a complete capture and renders its anchor - a diagnostic
#     stating the opposite of what happened, the same class as the retired
#     `token rejected on arrival`.
Z86_BAD=""
Z86_SRC="$(cat "$HOOK")"

# (a) the verification block, sliced from its own comment to the flag it sets
Z86_VERIFY="$(printf '%s\n' "$Z86_SRC" | sed -n '/# POSITIVE VERIFICATION/,/ZEN_OFF_RECORDED=1/p')"
[ -n "$Z86_VERIFY" ] || Z86_BAD="$Z86_BAD verification-slice-empty"
# POSITIVE, not a list of retired spellings. `head -c` was one way to cap the
# read and `cut -c1-4096` is another, so forbidding the first left the second
# free. What the property actually says is that the verification asks the SHARED
# predicate and reads nothing else from the marker, so that is what is asserted:
# exactly one command touches `$MARKER` here, and it is the owner.
Z86_MARKER_READS="$(printf '%s\n' "$Z86_VERIFY" | grep -v '^[[:space:]]*#' \
  | grep -oE '(zen_marker_active|grep|head|cut|sed|awk|read|cat)[^|]*"\$MARKER"' | wc -l | tr -d ' ')"
[ "${Z86_MARKER_READS:-0}" = "1" ] \
  || Z86_BAD="$Z86_BAD (a)-verification-reads-the-marker-${Z86_MARKER_READS:-0}-times-want-1"
printf '%s\n' "$Z86_VERIFY" | grep -qE '! zen_marker_active' \
  || Z86_BAD="$Z86_BAD (a)-verification-is-not-the-negated-resolution-predicate"
printf '%s\n' "$Z86_VERIFY" | grep -qF ':[[:space:]]*false' \
  && Z86_BAD="$Z86_BAD (a)-verification-still-asks-a-second-question"

# (b) the dead store and the swallowed stderr
printf '%s\n' "$Z86_SRC" | grep -qF 'ZEN_WRITE_RC' \
  && Z86_BAD="$Z86_BAD (b)-ZEN_WRITE_RC-survives"
printf '%s\n' "$Z86_SRC" | grep -qF 'zen_write_off_marker 2>/dev/null' \
  && Z86_BAD="$Z86_BAD (b)-writer-stderr-still-discarded"

# (c) THE WHOLE BRANCH, sliced and guarded, then asserted PER ARM.
#
# This inspected ONE FIXED LINE POSITION - `grep -A1 ... | tail -1` - and the line
# below the branch opener is a COMMENT, so the arm graded a comment. Two edits
# survived it: re-inserting the echo one line lower, and respelling the opener
# `!= 0`, which emptied the capture and made the forbid vacuous with no guard to
# notice. Slicing the branch and asserting where each line MAY appear holds the
# property instead of one of its spellings.
Z86_BRANCH="$(printf '%s\n' "$Z86_SRC" \
  | sed -n '/^if \[ "\$ZEN_CHILD_RC"/,/^fi$/p')"
if [ -z "$(printf '%s' "$Z86_BRANCH" | tr -d '[:space:]')" ]; then
  Z86_BAD="$Z86_BAD (c)-child-status-branch-slice-empty"
else
  # The anchor-lost line belongs to the catch-all arm, never above the `case`.
  Z86_PRECASE="$(printf '%s\n' "$Z86_BRANCH" | sed -n '1,/case /p')"
  printf '%s\n' "$Z86_PRECASE" | grep -v '^[[:space:]]*#' | grep -qF 'anchor unavailable' \
    && Z86_BAD="$Z86_BAD (c)-anchor-lost-line-fires-before-the-arms-are-distinguished"
  printf '%s\n' "$Z86_BRANCH" | grep -qF 'anchor unavailable' \
    || Z86_BAD="$Z86_BAD (c)-no-arm-reports-a-lost-anchor-at-all"
  printf '%s\n' "$Z86_BRANCH" | grep -qF 'capture retained' \
    || Z86_BAD="$Z86_BAD (c)-retained-capture-arm-emits-no-distinct-line"
fi

if [ -z "$Z86_BAD" ]; then
  check "Z86 the marker readers agree, the writer's cause survives, and the anchor-lost line is arm-scoped" PASS
else
  check "Z86 a reader, a cause or a diagnostic still reports something that did not happen:$Z86_BAD" FAIL
fi


# Z85 the provenance needle is scoped and the copy-pasteable remedy is
# shell-quoted.
#
# (a) IS GONE, and its removal is the fix rather than a loss. It asserted that no
#     PASS label carries the token `SKIP`, that the helper exists, and that the
#     summary can print a count - all three INFERRED from label prose, and the
#     first of them requiring an uppercase `SKIP` inside a PASS label that no live
#     guard has ever written, so that needle could not fire. Z97 owns the same
#     guarantee structurally: it reads no label at all, and asserts instead that
#     the counter increment and the verdict line exist exactly once each and both
#     live inside `skipcheck`. Two spellings of one rule is what round 3 found
#     here; one owner is the answer, and the weaker spelling is the one to drop.
# (b) Z76's `unverified` needle was FILE-WIDE and satisfied by an unrelated
#     comment elsewhere in the hook, so the provenance sentence it exists to hold
#     could be deleted with Z76 green.
# (c) THE REMEDY IS PASTED BY A HUMAN. `CLAUDE_PLUGIN_DATA` came from the host
#     process and was interpolated into a DOUBLE-quoted assignment, where a
#     `$`, a backtick or an embedded quote changes what the pasted line runs -
#     while the sibling plugin root in the same string is validated by a `cd -P`.
#     Single-quoting is total, and the sentence is emitted, not evaluated here.
Z85_BAD=""
# THE SELF-SCAN IS SLICED to everything ABOVE this check. Z85 scans the file it
# lives in, so every needle it spells is also a line it would match - the
# self-match class Z78, Z80 and Z82 each hit in turn. The summary block below this
# point is appended back, because two arms are about the summary.
# ANCHORED ON THE VARIABLE, not on the prose above it: a reworded header would
# silently empty the slice, and an empty slice makes the one surviving arm below
# - a FORBIDDEN-presence test - pass for the wrong reason. `Z76_BAD` sets the
# same precedent two blocks down. The emptiness is checked rather than trusted.
Z85_SELF="$(sed -n '1,/^Z85_BAD=""$/p' \
  "$PLUGIN_DIR/tests/structure/test-zen-mode.sh"; \
  sed -n '/^echo "----"$/,$p' "$PLUGIN_DIR/tests/structure/test-zen-mode.sh")"
[ -n "$Z85_SELF" ] || Z85_BAD="$Z85_BAD self-scan-slice-is-empty"
# (b) the provenance needle must be scoped to the sentence it holds
printf '%s\n' "$Z85_SELF" | grep -qF "grep -qiE '# .*(UNVERIFIED|unverified)' \"\$HOOK\"" \
  && Z85_BAD="$Z85_BAD Z76-unverified-needle-is-file-wide"
# (c) the remedy must be built through a quoting helper, not interpolated raw
grep -qE '^zen_shell_quote\(\) \{' "$HOOK" \
  || Z85_BAD="$Z85_BAD no-shell-quoting-helper"
grep -qF 'CLAUDE_PLUGIN_DATA=\"${CLAUDE_PLUGIN_DATA:-}\"' "$HOOK" \
  && Z85_BAD="$Z85_BAD remedy-still-interpolates-the-store-unquoted"
if grep -qE '^zen_shell_quote\(\) \{' "$HOOK"; then
  eval "$(awk '/^zen_shell_quote\(\) \{/,/^\}$/' "$HOOK")"
  [ "$(zen_shell_quote "/a/b")" = "'/a/b'" ] || Z85_BAD="$Z85_BAD quote-plain<$(zen_shell_quote /a/b)>"
  [ "$(zen_shell_quote "a'b")" = "'a'\\''b'" ] || Z85_BAD="$Z85_BAD quote-apostrophe<$(zen_shell_quote "a'b")>"
  Z85_EVAL="$(eval "printf '%s' $(zen_shell_quote 'x$(id -u)`id -u`y')")"
  [ "$Z85_EVAL" = 'x$(id -u)`id -u`y' ] || Z85_BAD="$Z85_BAD quote-does-not-neutralize-substitution<$Z85_EVAL>"
fi
# (d) the Z76 comment carries the same stale census the operator carriers did
Z85_Z76="$(awk '/^# Z76 the registered timeout is pinned EXACTLY/,/^Z76_BAD=""$/' \
  "$PLUGIN_DIR/tests/structure/test-zen-mode.sh")"
printf '%s' "$Z85_Z76" | grep -qF 'rather than two' \
  && Z85_BAD="$Z85_BAD Z76-comment-keeps-the-two-child-census"

if [ -z "$Z85_BAD" ]; then
  check "Z85 the provenance needle is scoped and the remedy is shell-quoted" PASS
else
  check "Z85 a needle cannot hold the sentence it names:$Z85_BAD" FAIL
fi
# Z97 `skipcheck` is the SOLE route to the third verdict.
#
# JUDGE-2(c) of round 3. Z90 clause 1 misses Z84's own measured-nothing PASS
# label, and Z85 arm (a) required an uppercase `SKIP` token that no live guard
# writes - BOTH because the property was inferred from LABEL PROSE. This check
# reads no label. It asserts that the two statements which PRODUCE the third
# verdict - the counter increment and the report line - exist exactly ONCE each
# and both live inside `skipcheck`, so a hand-rolled skip cannot exist anywhere
# in this file. Z34a carried exactly that second route until this check existed:
# it incremented the counter and echoed the verdict itself, so `skipcheck` was
# the CONVENTIONAL route and never the only one.
#
# THE NEEDLES CANNOT MATCH THEMSELVES, and that is why they are `^`-anchored on
# the STATEMENT form rather than spelled as plain substrings: the lines carrying
# them begin with an assignment or with `grep`, never with the statement they
# describe. Z78, Z80 and Z82 each hit the self-match class in turn; this one is
# closed by construction instead of by a slice that has to be maintained.
#
# A ZERO-MATCH DERIVATION FAILS. An empty slice reading as agreement is a defect
# this repository has already shipped twice (the G12a and Z19b precedents), so
# every arm below separates "nothing found" from "found and correct".
Z97_BAD=""
Z97_SELF="$PLUGIN_DIR/tests/structure/test-zen-mode.sh"
Z97_BODY="$(awk '/^skipcheck\(\) \{/,/^\}$/' "$Z97_SELF")"
if [ -z "$Z97_BODY" ]; then
  Z97_BAD="$Z97_BAD skipcheck-helper-not-found"
else
  Z97_INC="$(grep -cE '^[[:space:]]*SKIP=\$\(\(SKIP\+1\)\)' "$Z97_SELF")"
  Z97_EMIT="$(grep -cE '^[[:space:]]*echo "  SKIP  ' "$Z97_SELF")"
  [ "$Z97_INC" -eq 1 ] \
    || Z97_BAD="$Z97_BAD skip-counter-incremented-at-$Z97_INC-sites-want-1"
  [ "$Z97_EMIT" -eq 1 ] \
    || Z97_BAD="$Z97_BAD skip-verdict-emitted-at-$Z97_EMIT-sites-want-1"
  printf '%s\n' "$Z97_BODY" | grep -qE '^[[:space:]]*SKIP=\$\(\(SKIP\+1\)\)' \
    || Z97_BAD="$Z97_BAD skipcheck-does-not-own-the-counter"
  printf '%s\n' "$Z97_BODY" | grep -qE '^[[:space:]]*echo "  SKIP  ' \
    || Z97_BAD="$Z97_BAD skipcheck-does-not-own-the-verdict-line"
fi
# `check` must not be able to EXPRESS the third verdict: a caller that hands it
# one has to land on FAIL, never on PASS. DRIVEN, not grepped - the helper is
# evaluated inside a subshell so this file's own counters are untouched.
Z97_CHECK="$(awk '/^check\(\) \{/,/^\}$/' "$Z97_SELF")"
if [ -z "$Z97_CHECK" ]; then
  Z97_BAD="$Z97_BAD check-helper-not-found"
elif ! (
  PASS=0; FAIL=0
  eval "$Z97_CHECK"
  check "Z97 probe" SKIP >/dev/null 2>&1
  [ "$FAIL" -eq 1 ] && [ "$PASS" -eq 0 ]
); then
  Z97_BAD="$Z97_BAD check-accepts-a-third-verdict"
fi
# The summary must be able to REPORT a skip. Without it a skipped run and a clean
# run are the same bytes on the one line CI reads.
grep -qE '^[[:space:]]*echo "test-zen-mode: \$PASS PASS / \$FAIL FAIL / \$SKIP SKIP"' \
  "$Z97_SELF" || Z97_BAD="$Z97_BAD summary-cannot-report-a-skip-count"

if [ -z "$Z97_BAD" ]; then
  check "Z97 skipcheck is the only route to the third verdict, and check cannot express it" PASS
else
  check "Z97 a non-measuring pass has a route that bypasses skipcheck:$Z97_BAD" FAIL
fi


# Z92 a NON-STRING `prompt` must not swallow the in-band `zen off` escape.
#
# THE CHILD DOES NOT FAIL ON THIS PATH, which is the whole defect. On a
# `payloadFault` the child still writes `anchor + "\n" + prompt` with an empty
# prompt and exits 0, so the capture is `none\n`, which command substitution
# trims to `none` - NON-EMPTY. Neither `[ "$ZEN_CHILD_RC" -ne 0 ]` nor
# `[ -z "$ZEN_FIELDS" ]` fires, `ZEN_LOST_PROMPT` stays 0, and the whole
# raw-payload last resort is gated on that flag. The derived `PROMPT` is then
# empty and the off-phrase test on it is skipped, so a user who typed the escape
# stays in the mode - and stays in it for every later turn with the same payload
# shape.
#
# Z49 does not cover this: it drives the SAME `payloadFault` branch but asserts
# only the disclosure lead-in and that the directive still ships. Nothing asked
# whether the escape survived.
#
# The phrase is carried in a field the payload scan does NOT strip. `cwd` and
# `transcript_path` are stripped by design, so planting it there would test the
# stripper rather than this path.
Z92_OUT="$(node -e '
  const p = {
    hook_event_name: "UserPromptSubmit",
    session_id: process.argv[1],
    prompt: { text: "zen off" },
  };
  process.stdout.write(JSON.stringify(p));
' "$S32" \
  | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PROJECT_DIR="$P32" \
    ZENSU_CONFIG="$NO_CONFIG" bash "$HOOK" 2>/dev/null)"
Z92_KIND="$(printf '%s' "$Z92_OUT" | classify)"
case "$Z92_KIND" in
  *'|OFF')
    check "Z92 an off phrase in a raw payload whose prompt is not a string still turns the mode off" PASS ;;
  *'|ON')
    check "Z92 the in-band escape is UNREACHABLE on the payloadFault path - the mode stays on ($Z92_KIND)" FAIL ;;
  *)
    check "Z92 the payloadFault path cost the whole directive (kind '$Z92_KIND')" FAIL ;;
esac

# Z93 the two fail-safe arms must DISCLOSE, not deactivate in silence.
#
# Z53 and Z54 already drive these states end to end, but both assert only the
# RESOLUTION - that nothing is injected. Neither captures stderr, so the arms
# could stay mute with both green. `zen_marker_shape_fault` returns its reason on
# STDOUT and the hook sends that to /dev/null, because stdout is its own JSON
# decision channel; the value has to be captured into a variable first or it is
# lost. The sibling writer prints the same cause on every verb, so today the only
# surface naming it is a `--status` invocation the user has no reason to run.
#
# Why silence is the aggravator rather than a cosmetic gap: `.zensu/state/` is
# writable from inside any session in the project and no gate covers it while the
# chain is inactive, so one `mkfifo` turns the user-chosen mode off on every
# prompt for the rest of the session - and the file's own invariant says every
# fault discloses under a named class, because a silent failure is a lie.
P93="$(mktemp -d -t zenmode-disclose-XXXXXX)"; S93="z93-$$"
new_session "$P93" "$S93"
helper "$P93" "$S93" --on >/dev/null 2>&1
MARKER93="$(find "$P93/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
if [ -z "$MARKER93" ]; then
  check "Z93 no marker was produced - the fixture is not measuring anything" FAIL
elif ! rm -f "$MARKER93" || ! mkfifo "$MARKER93" 2>/dev/null; then
  skipcheck "Z93 mkfifo is unavailable on this host"
else
  Z93_ERR="$(fire_err "$P93" "$S93" "where are we?")"
  rm -f "$MARKER93"
  case "$Z93_ERR" in
    *'zen-mode'*'regular file'*)
      check "Z93 a non-regular marker resolves the mode OFF and names the cause on stderr" PASS ;;
    '')
      check "Z93 the mode was deactivated SILENTLY - stderr carried nothing" FAIL ;;
    *)
      check "Z93 the mode was deactivated without naming the shape fault - stderr carried <$Z93_ERR>" FAIL ;;
  esac
fi
rm -rf "$P93"

# Z94 an owner-exported constant this hook interpolates must be shape-asserted.
#
# `WORKFLOW_STATE_PREFIX` reaches a filename by concatenation, so an absent or
# renamed export yields `undefined...` rather than throwing - the `lstat` then
# fails ENOENT and the ENOENT branch CLEARS the fault class, so the anchor
# degrades to a silent `none`, byte-identical to a healthy session with no chain
# armed. Its sibling `WORKFLOW_STATE_SEGMENTS` fails LOUDLY on the same input,
# because `.reduce` on a missing export throws while `fault` is still `modules`,
# and `zen-anchor-v1.js` deliberately throws on a degraded owner for exactly this
# reason. Two owner-exported constants on one path with opposite failure
# directions is the defect; the assertion is what aligns them.
#
# A SOURCE PIN, and the reason is stated rather than left as convenience: reaching
# the branch behaviourally needs a copied plugin tree carrying a stubbed core
# module, which this suite builds nowhere, and the assertion has to sit ABOVE the
# `lstat` that swallows the fault.
Z94_PROG="$(awk '/^zen_prompt_and_anchor\(\) \{/,/^\}$/' "$HOOK")"
if [ -z "$(printf '%s' "$Z94_PROG" | tr -d '[:space:]')" ]; then
  check "Z94 the child program could not be extracted - the pin is not measuring anything" FAIL
elif printf '%s\n' "$Z94_PROG" | grep -q 'typeof core.WORKFLOW_STATE_PREFIX'; then
  check "Z94 WORKFLOW_STATE_PREFIX is shape-asserted before it reaches a filename" PASS
else
  check "Z94 an absent WORKFLOW_STATE_PREFIX degrades to a silent none - the sibling constant throws instead" FAIL
fi

# Z95 the zen-only predicates live in a zen-only library, and the marker`s
# ACTIVE question has one owner.
#
# TWO PROPERTIES, one check, because they are one refactor. First, blast radius:
# `zensu-session.sh` is the Session Control binding library and is sourced by
# every stateful gate in the tree, so a syntax fault introduced while editing a
# PRESENTATION feature fails every PreToolUse Bash gate CLOSED. The two
# predicates have exactly two callers, both zen. Second, the `active` question
# was spelled THREE times by hand - the resolution ladder, the off-write
# verification, and the helper`s `--status` - with nothing comparing them, so a
# one-sided widening would make the verification report COULD NOT BE DEACTIVATED
# for a marker the resolution honours, or make `--status` disagree with the hook.
#
# Note what this check does NOT rest on: an earlier draft argued the two
# predicates were the only functions omitted from that file`s `export -f` list.
# That is false - the list names 11 and the file defines 15 - so the case is
# blast radius alone.
Z95_BAD=""
Z95_SHARED="$PLUGIN_DIR/hooks/lib/zensu-zen-shared.sh"
[ -f "$Z95_SHARED" ] || Z95_BAD="$Z95_BAD no-zensu-zen-shared.sh"
for Z95_FN in zen_marker_shape_fault zen_path_untraversable zen_marker_active; do
  grep -qE "^$Z95_FN\(\) \{" "$Z95_SHARED" 2>/dev/null \
    || Z95_BAD="$Z95_BAD $Z95_FN-not-in-the-zen-library"
  grep -qE "^$Z95_FN\(\) \{" "$PLUGIN_DIR/hooks/lib/zensu-session.sh" \
    && Z95_BAD="$Z95_BAD $Z95_FN-still-in-the-binding-library"
done
# ONE spelling of the active question under hooks/, and it is the owner`s.
Z95_SPELLINGS="$(grep -rlF '"active"[[:space:]]*:[[:space:]]*true' "$PLUGIN_DIR/hooks" 2>/dev/null | sort)"
Z95_N="$(printf '%s' "$Z95_SPELLINGS" | grep -c . || true)"
if [ "${Z95_N:-0}" -ne 1 ]; then
  Z95_BAD="$Z95_BAD active-pattern-in-${Z95_N:-0}-files-want-1<$(printf '%s' "$Z95_SPELLINGS" | tr '\n' ' ')>"
elif [ "$Z95_SPELLINGS" != "$Z95_SHARED" ]; then
  Z95_BAD="$Z95_BAD active-pattern-owner-is-$(basename "$Z95_SPELLINGS")"
fi
# and all three former sites must go through the owner
Z95_CALLS="$(grep -c 'zen_marker_active' "$HOOK" 2>/dev/null || echo 0)"
[ "${Z95_CALLS:-0}" -ge 2 ] \
  || Z95_BAD="$Z95_BAD hook-calls-zen_marker_active-${Z95_CALLS:-0}-times-want-2"
grep -q 'zen_marker_active' "$PLUGIN_DIR/hooks/lib/zensu-zen-mode.sh" \
  || Z95_BAD="$Z95_BAD status-verb-does-not-call-zen_marker_active"
if [ -z "$Z95_BAD" ]; then
  check "Z95 the zen predicates live in a zen-only library and the active question has one owner" PASS
else
  check "Z95 zen-only state predicates still sit in the binding library, or the active question is hand-copied:$Z95_BAD" FAIL
fi

# Z96 the anchor field is DELIMITED, and the off-verb is not named by a bare
# relative path.
#
# TWO PROPERTIES OF ONE STRING, so one check. Both are about content the model
# reads LATER in the same turn competing with what the hook injected.
#
# (a) `ZENSU CHAIN ANCHOR:` was a fixed, guessable, UNDELIMITED literal, and the
# directive ASSERTS PROVENANCE for it - "derived from the session`s own Zensu
# workflow document", "render that line verbatim". A repo file, a pasted diff or
# a fetched page carrying the same literal therefore competes with the injected
# field and inherits that assertion, putting a false completion signal in front
# of a user the same directive describes as working at low capacity. The literal
# already occurs in this repository`s own tree, so a session reading these files
# is a live trigger. This repo already ships the answer for its other injected
# rule blocks: a unique open/close marker pair the directive names as the only
# form it may trust.
#
# (b) the off-verb was named as `hooks/lib/zensu-zen-mode.sh`, a RELATIVE path, in
# a channel a model reads. A model that resolves it against the session cwd
# executes a repo-planted file of that name; self-testing masks it, because this
# repository really does contain that path. The same hazard is settled policy
# elsewhere in this tree, where the model-facing remedy names a slash command
# instead of a bare script.
#
# DECODED, never grepped off the source line. The directive is one physical line
# whose breaks are `\n` escapes inside a JSON string, so a source-side needle
# reads the ENCODED bytes - which is how a sibling check once passed while the
# rendered text said something else.
Z96_BAD=""
Z96_DIRECTIVE="$(HOOK="$HOOK" node -e '
  const fs = require("fs");
  const hook = fs.readFileSync(process.env.HOOK, "utf8");
  const blocks = [...hook.matchAll(/"additionalContext":\s*"((?:[^"\\]|\\.)*)"/g)]
    .map((m) => { try { return JSON.parse("\"" + m[1] + "\""); } catch (_) { return ""; } });
  const active = blocks.find((s) => s.startsWith("zen-mode is ACTIVE"));
  process.stdout.write(active === undefined ? "" : active);
' 2>/dev/null)"
[ -n "$Z96_DIRECTIVE" ] || Z96_BAD="$Z96_BAD directive-not-extractable"
printf '%s' "$Z96_DIRECTIVE" | grep -qF 'zensu:chain-anchor' \
  || Z96_BAD="$Z96_BAD anchor-field-carries-no-delimiter"
printf '%s' "$Z96_DIRECTIVE" | grep -qF '/zensu:chain-anchor' \
  || Z96_BAD="$Z96_BAD anchor-field-carries-no-closing-delimiter"
# The directive must say the delimiters are what makes the field trustworthy,
# not merely carry them.
printf '%s' "$Z96_DIRECTIVE" | grep -qiE 'only.{0,40}between|between.{0,40}markers' \
  || Z96_BAD="$Z96_BAD delimiters-carried-but-not-named-as-the-trusted-form"
# (b) no bare relative script path in the model-facing remedy.
printf '%s' "$Z96_DIRECTIVE" | grep -qF 'hooks/lib/zensu-zen-mode.sh' \
  && Z96_BAD="$Z96_BAD off-verb-named-by-a-relative-path"
if [ -z "$Z96_BAD" ]; then
  check "Z96 the anchor field is delimited and named as the only trusted form, and the off-verb is not a relative path" PASS
else
  check "Z96 the injected directive can be impersonated or resolved against the session cwd:$Z96_BAD" FAIL
fi

# Z98 every DERIVED SOURCE SLICE used as a haystack is emptiness-guarded.
#
# THE REPLACEMENT FOR Z90, which was deleted in the same change rather than kept
# beside this. Z90 was a hand-listed roster of five per-check needles grepped over
# a slice of its own source: it caught only what somebody had enumerated, each
# needle was itself the presence grep it forbids, and its clause-1 alternation did
# not match Z84's own measured-nothing PASS label - the very shape that clause
# names. Two of its own arms were findings in round 3. An enumerative instrument
# cannot close a class; this one enumerates nothing.
#
# THE PROPERTY. A forbidding arm of the shape
#     printf '%s\n' "$SLICE" | grep -q ... && X_BAD="$X_BAD ..."
# reports agreement when `$SLICE` is EMPTY, because an empty haystack matches
# nothing. So a derivation that silently stops producing bytes - a reworded
# anchor, a renamed function, a moved section - turns every forbidding arm over
# it into a check that cannot fail. This repository has shipped that defect
# twice already under its own names (the G12a and Z19b precedents), and round 3
# found it a third time here, in Z85.
#
# THE DERIVATION IS MECHANICAL. For every accumulator block - opened by
# `X_BAD=""` and closed by the `[ -z "$X_BAD" ]` verdict - it collects the
# variables piped into `grep` as haystacks, keeps those ASSIGNED IN THAT BLOCK
# from a static source read (`sed`/`awk`/`grep`/`tr`/`cat`), and requires each to
# be emptiness-guarded. Three guard forms are accepted, because all three make an
# empty slice observable: a direct `[ -z ]`/`[ -n ]` test, a numeric comparison
# against a count derived from it, and a guard on every variable it is itself
# derived from.
#
# A ZERO-MATCH DERIVATION FAILS. `Z98_FLOOR` is a floor rather than the exact
# count on purpose: the exact number moves whenever a check is added or removed,
# while zero means the derivation itself broke and every arm below it went quiet.
#
# IT CANNOT MATCH ITSELF. The program is JavaScript in a quoted heredoc, so the
# shell shapes it looks for - an `X_BAD=""` opener and a literal
# `printf '%s\n' "$VAR" | grep` - appear in it only as ESCAPED regex source and
# never as the statements themselves. Z78, Z80 and Z82 each hit the self-match
# class in turn; this one is closed by construction rather than by a slice.
#
# KNOWN BOUND, stated rather than implied: the count form accepts any numeric
# comparison, including one an empty slice would satisfy (`-eq 0`). The shape it
# is written for is the `-ne 1` / `-ge N` idiom this file already uses.
Z98_FLOOR=20
Z98_BAD=""
Z98_JS="$CONTROL_TMP/z98-slice-guard.js"
cat > "$Z98_JS" <<'Z98EOF'
const fs = require("fs");
const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
const opener = /^\s*([A-Za-z_][A-Za-z0-9_]*_BAD)=""\s*$/;
const problems = [];
let total = 0;
let blocks = 0;
for (let i = 0; i < lines.length; i++) {
  const m = opener.exec(lines[i]);
  if (!m) continue;
  const acc = m[1];
  blocks += 1;
  const verdict = new RegExp("\\[ -z \"\\$" + acc + "\" \\]");
  let end = lines.length - 1;
  for (let j = i + 1; j < lines.length; j++) {
    if (!verdict.test(lines[j])) continue;
    end = j;
    for (let k = j; k < Math.min(j + 12, lines.length); k++) {
      if (lines[k].trim() === "fi") { end = k; break; }
    }
    break;
  }
  const body = lines.slice(i, end + 1).join("\n");
  const hay = new Set();
  const hayRe = /printf\s+'%s(?:\\n)?'\s+"\$([A-Za-z_][A-Za-z0-9_]*)"\s*\|\s*grep/g;
  let h;
  while ((h = hayRe.exec(body)) !== null) {
    if (!/_BAD$/.test(h[1])) hay.add(h[1]);
  }
  const assignment = (name) => {
    const re = new RegExp("^[ \\t]*" + name + "=\"\\$\\(", "m");
    const at = body.search(re);
    return at < 0 ? null : body.slice(at, at + 700);
  };
  const isStatic = (name) => {
    const seg = assignment(name);
    if (seg === null) return false;
    const head = seg.split("\n").slice(0, 4).join(" ");
    return /\$\(\s*(sed|awk|grep|tr|cat)\b/.test(head) || /\|\s*(sed|awk|tr)\b/.test(head);
  };
  const counted = (name) => {
    const re = new RegExp("^[ \\t]*([A-Za-z_][A-Za-z0-9_]*)=\"\\$\\([^\\n]*\"\\$" + name + "\"", "gm");
    let c;
    while ((c = re.exec(body)) !== null) {
      const cmp = new RegExp("\\$\\{?" + c[1] + "[^\\n]*\"? -(ne|eq|ge|gt|le|lt) ");
      if (cmp.test(body)) return true;
    }
    return false;
  };
  const guarded = (name, seen) => {
    seen = seen || new Set();
    if (seen.has(name)) return false;
    seen.add(name);
    if (new RegExp("\\[ -[zn] \"\\$" + name + "\" \\]").test(body)) return true;
    if (counted(name)) return true;
    const seg = assignment(name);
    if (seg === null) return false;
    const deps = new Set();
    const depRe = /"\$([A-Za-z_][A-Za-z0-9_]*)"/g;
    let d;
    while ((d = depRe.exec(seg.slice(0, 600))) !== null) {
      if (d[1] !== name) deps.add(d[1]);
    }
    for (const dep of deps) if (guarded(dep, seen)) return true;
    return false;
  };
  for (const name of Array.from(hay).sort()) {
    if (!isStatic(name)) continue;
    total += 1;
    if (!guarded(name)) problems.push(acc + ":" + name);
  }
}
process.stdout.write("TOTAL " + total + " BLOCKS " + blocks + "\n");
for (const p of problems) process.stdout.write("UNGUARDED " + p + "\n");
Z98EOF
Z98_OUT="$(node "$Z98_JS" "$PLUGIN_DIR/tests/structure/test-zen-mode.sh" 2>&1)"
Z98_RC=$?
Z98_TOTAL="$(printf '%s\n' "$Z98_OUT" | sed -n 's/^TOTAL \([0-9]*\) .*/\1/p' | head -1)"
Z98_LIST="$(printf '%s\n' "$Z98_OUT" | sed -n 's/^UNGUARDED //p' | tr '\n' ' ')"
if [ "$Z98_RC" -ne 0 ] || [ -z "$Z98_TOTAL" ]; then
  Z98_BAD="$Z98_BAD derivation-did-not-run<$(printf '%s' "$Z98_OUT" | head -2 | tr '\n' ';')>"
else
  [ "$Z98_TOTAL" -ge "$Z98_FLOOR" ] \
    || Z98_BAD="$Z98_BAD derivation-found-only-$Z98_TOTAL-slices-want-at-least-$Z98_FLOOR"
  [ -z "$Z98_LIST" ] || Z98_BAD="$Z98_BAD unguarded:<$Z98_LIST>"
fi

if [ -z "$Z98_BAD" ]; then
  check "Z98 every derived source slice used as a haystack is emptiness-guarded" PASS
else
  check "Z98 an empty derivation can read as agreement:$Z98_BAD" FAIL
fi


# The anchor fixtures are the only project directories this suite created and
# never removed. Every other fixture above is torn down at its own site; these
# two are torn down here because the fail-open arms need them alive until the
# last check that reads them.
rm -rf "$P32" "$P39"

echo "----"
if [ "${SKIP:-0}" -gt 0 ]; then
  echo "test-zen-mode: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
else
  echo "test-zen-mode: $PASS PASS / $FAIL FAIL"
fi
[ "$FAIL" -eq 0 ]
