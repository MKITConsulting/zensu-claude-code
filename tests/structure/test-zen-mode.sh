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
      ZENSU_CONFIG="${4:-$NO_CONFIG}" bash "$HOOK" 2>/dev/null
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
  check "Z17c symlinked marker refusal (native file symlinks unavailable)" PASS
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
  MISS19B="$(HOOK="$HOOK" SKILL="$SKILL" EVALS="$PLUGIN_DIR/evals/zen-mode-reaction/scenarios" node -e '
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
    // The SKILL.md side is SLICED to rule 6. Comparing the whole file would let
    // rule 6 be gutted while the literals survive anywhere else in the document,
    // which is agreement about the file and not about the rule.
    const skillAll = fs.readFileSync(process.env.SKILL, "utf8");
    const from = skillAll.indexOf("**Anchor multi-step work.**");
    const to = skillAll.indexOf("7. **Gloss the jargon.**");
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
    if (scenarios.length < 3) bad.push("eval-dir:expected-at-least-3-scenarios-got-" + scenarios.length);
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
    // One distinguishing literal per anchor requirement, so no clause can be
    // deleted from a carrier with this check still green. In requirement order:
    // AC-001 position (with its carve-out fallback), AC-002 the four marks via
    // the example path plus the failed/blocked mark named in prose, AC-003 the
    // no-counter prohibition, AC-004 the observation rule stated
    // unconditionally AND its consequence, AC-005 only-the-steps, AC-006 the
    // label casing rule, plus the ACTIVATION TRIGGER, which the two carriers
    // once spelled differently, and the separator disclaimer.
    const shared = [
      "chain-progress",
      "✓fetch ✓parse ▶render",
      "✗",
      "·",
      "observed finish AND pass",
      "for the step running now",
      "for one not yet reached",
      "failing or unresolved outcome",
      "for one that failed or is blocked",
      "above the closing next step",
      "when the one-next-step rule is suspended",
      "add no separate",
      "A step is marked done from an observation, never from the plan",
      "a step you did not see finish stays",
      "steps this run actually has",
      "pad with steps nobody planned",
      "drop one the run traversed",
      "a position, not a history",
      "mark of its current attempt",
      "deliberately did not perform",
      "canonical pipeline",
      "short lower-case step names",
      "the words around them follow the user",
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
      for (const s of shared) if (!text.includes(norm(s))) bad.push(name + ":missing<" + s.slice(0, 28) + ">");
      if (name !== "skill") {
        for (const s of wholeDirectiveOnly) {
          if (!text.includes(norm(s))) bad.push(name + ":missing-carve-out<" + s.slice(0, 28) + ">");
        }
      }
      // An eval carrier embeds the WHOLE directive, so compare the whole thing
      // rather than a needle list. Three carve-out needles cannot cover the
      // credentials trigger, the enumerated suspension list or the
      // code-context clause; P8 does compare in full, but that suite is
      // local-only and CI never runs it. This is the CI-side equivalent.
      if (name.startsWith("eval:") && !text.includes(want)) {
        bad.push(name + ":directive-not-verbatim");
      }
      // The anchor REPLACED the bare marker. Every carrier still names it, but
      // only inside the prohibition — never again as the instruction.
      if (/anchor multi-step work with a .?Step N of M/.test(text)) bad.push(name + ":still-instructs-bare-marker");
      if (/Carry a .?Step N of M.? marker/.test(text)) bad.push(name + ":still-instructs-bare-marker");
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
# compares the two strings, with each file's own comparison lines excluded so a
# pattern argument cannot satisfy the check it belongs to.
if command -v node >/dev/null 2>&1; then
  MISS19C="$(A="$0" B="$PLUGIN_DIR/tests/structure/test-promptfoo-zen-mode.sh" node -e '
    const fs = require("fs");
    // Compare the WHOLE extractor statement range, not just the regex line. A
    // line-scoped comparison left the two other hand-copied halves — the
    // JSON.parse unescape and the ACTIVE selector — free to diverge, which is
    // exactly the drift this check is named for; it also reported a false red
    // when both suites were improved identically, because it pinned the current
    // spelling rather than the two copies against each other.
    const FROM = "const blocks = ";
    const TO = "const active = ";
    const pick = (p) => {
      const src = fs.readFileSync(p, "utf8");
      const a = src.indexOf(FROM);
      if (a < 0) return null;
      const b = src.indexOf(TO, a);
      if (b < 0) return null;
      const end = src.indexOf("\n", b);
      // Normalize whitespace so indentation differences between the two suites
      // are not read as a divergence; the STATEMENTS are what must agree.
      return src.slice(a, end < 0 ? src.length : end).replace(/\s+/g, " ").trim();
    };
    const a = pick(process.env.A);
    const b = pick(process.env.B);
    const bad = [];
    if (a === null) bad.push("test-zen-mode:extractor-not-locatable");
    if (b === null) bad.push("test-promptfoo-zen-mode:extractor-not-locatable");
    if (a !== null && b !== null && a !== b) bad.push("extractor-source-differs");
    process.stdout.write(bad.length ? bad.join(",") : "OK");
  ' 2>/dev/null)"
  RC19C=$?
  if [ "$RC19C" -ne 0 ]; then
    check "Z19c extractor comparison could not run (node exit $RC19C) — not an all-clear" FAIL
  elif [ "$MISS19C" = "OK" ]; then
    check "Z19c the whole ACTIVE-directive extractor is identical in both zen-mode suites" PASS
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
    // The operator row is held to a DEFINED SUBSET of the Z19b clause set, not to
    // parity — an earlier comment here claimed parity and a grep disproved it.
    // What the row must carry: the activation trigger, the placement and its
    // carve-out fallback, all four marks, the pass qualification, the
    // unresolved half, the observation rule, the retry rule, the
    // only-the-steps rule, the no-canonical-pipeline rule, the casing rule, the
    // omission exception, the not-a-mark declaration and the counter
    // prohibition. What it deliberately omits, because a config table is a
    // summary and not a second copy of the directive: the step-source and
    // planless-fallback sentences, and the per-mark definition phrases beyond
    // the glyphs themselves.
    const need = [
      "chain-progress", "✓", "▶", "·", "✗",
      "spans several turns",
      "marked from an observation and never from the plan",
      "above the closing next step",
      "when the one-next-step rule is suspended",
      "mark of its current attempt",
      "observed finish AND pass",
      "failing or unresolved outcome",
      "this run actually has",
      "canonical pipeline",
      "short lower-case step names",
      "deliberately did not perform",
      "not a mark",
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
# case-insensitive scan would flag them. A grep error (rc >= 2) is a FAIL, never a
# silent "no match".
GERMAN_RE='\b(und|oder|nicht|Datei|Dateien|werden|kann|muss|sollte|wenn|dann|aber|auch|noch|schon|bitte|ohne)\b'
LANG_BAD=""
for F26 in "$SKILL" "$HOOK" "$HELPER"; do
  if node -e 'process.exit(/[äöüÄÖÜß]/.test(require("fs").readFileSync(process.argv[1],"utf8"))?1:0)' "$F26" 2>/dev/null; then :; else
    LANG_BAD="$LANG_BAD $(basename "$F26"):umlaut"
  fi
  grep -qiE "$GERMAN_RE" "$F26"; RC26=$?
  [ "$RC26" -eq 0 ] && LANG_BAD="$LANG_BAD $(basename "$F26"):german-stem"
  [ "$RC26" -ge 2 ] && LANG_BAD="$LANG_BAD $(basename "$F26"):grep-error-rc$RC26"
done
[ -z "$LANG_BAD" ] && check "Z26 skill/hook/helper are English-only (no umlauts, no German stems)" PASS \
  || check "Z26 English-only violated:$LANG_BAD" FAIL

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

echo "----"
echo "test-zen-mode: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
