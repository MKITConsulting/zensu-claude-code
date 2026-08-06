#!/bin/bash
set -u

# Pins the zen-mode focused response mode: the state helper
# (hooks/lib/zensu-zen-mode.sh), the UserPromptSubmit re-injection hook
# (hooks/user-prompt-zen-mode.sh), and the skill contract
# (skills/zen-mode/SKILL.md).
#
# The two properties that make the mode trustworthy are pinned behaviorally:
# the hook is a total no-op unless the current session carries a marker, and
# deactivation is performed by the HOOK (not the model), so an off-phrase still
# works after the model has drifted away from the mode.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/user-prompt-zen-mode.sh"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-zen-mode.sh"
SKILL="$PLUGIN_DIR/skills/zen-mode/SKILL.md"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
CONTROL_TMP="$(mktemp -d -t zenmode-control-XXXXXX)"
NO_CONFIG="$CONTROL_TMP/no-such-config.json"
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

# Z8 marker lives under the gitignored ephemeral state dir
if grep -qF '.zensu/state/zen-mode-' "$HOOK" && grep -qF '.zensu/state' "$HELPER"; then
  check "Z8 marker path is .zensu/state/zen-mode-<session> (gitignored, ephemeral)" PASS
else
  check "Z8 marker path is .zensu/state/zen-mode-<session>" FAIL
fi

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
# helper <project> <session_id> <verb>
helper() {
  CLAUDE_CODE_SESSION_ID="$2" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" \
    CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" CLAUDE_PROJECT_DIR="$1" \
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

# Z9 helper round-trip: off -> on -> off, marker appears and disappears
P9="$(mktemp -d -t zenmode-XXXXXX)"; S9="z9-$$"
new_session "$P9" "$S9"
ST9A="$(helper "$P9" "$S9" --status)"
helper "$P9" "$S9" --on >/dev/null
ST9B="$(helper "$P9" "$S9" --status)"; M9B="$(marker_count "$P9")"
helper "$P9" "$S9" --off >/dev/null
ST9C="$(helper "$P9" "$S9" --status)"; M9C="$(marker_count "$P9")"
if [ "$ST9A" = "off" ] && [ "$ST9B" = "on" ] && [ "$M9B" = "1" ] && [ "$ST9C" = "off" ] && [ "$M9C" = "0" ]; then
  check "Z9 helper --status/--on/--off round-trip writes and removes the marker" PASS
else
  check "Z9 helper round-trip (a=$ST9A b=$ST9B/$M9B c=$ST9C/$M9C)" FAIL
fi
rm -rf "$P9"

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

# Z11 no marker -> hook is silent
P11="$(mktemp -d -t zenmode-XXXXXX)"; S11="z11-$$"
new_session "$P11" "$S11"
OUT11="$(fire "$P11" "$S11" "do a thing" | classify)"
[ "$OUT11" = "EMPTY" ] && check "Z11 no marker -> hook silent (zero cost when mode is off)" PASS \
  || check "Z11 no marker silent (got '$OUT11')" FAIL
rm -rf "$P11"

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

# Z15 the HOOK performs deactivation itself — marker removed, OFF context emitted
P15="$(mktemp -d -t zenmode-XXXXXX)"; S15="z15-$$"
new_session "$P15" "$S15"; helper "$P15" "$S15" --on >/dev/null
OUT15="$(fire "$P15" "$S15" "normal mode" | classify)"
M15="$(marker_count "$P15")"
ST15="$(helper "$P15" "$S15" --status)"
if [ "$OUT15" = "UserPromptSubmit|OFF" ] && [ "$M15" = "0" ] && [ "$ST15" = "off" ]; then
  check "Z15 off-phrase removes the marker in the hook (works after model drift)" PASS
else
  check "Z15 hook-side deactivation (out='$OUT15' markers=$M15 status=$ST15)" FAIL
fi
rm -rf "$P15"

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

# Z17 off-phrase with no active marker -> silent (no noise when already off)
P17="$(mktemp -d -t zenmode-XXXXXX)"; S17="z17-$$"
new_session "$P17" "$S17"
OUT17="$(fire "$P17" "$S17" "normal mode" | classify)"
[ "$OUT17" = "EMPTY" ] && check "Z17 off-phrase while already off -> silent (idempotent)" PASS \
  || check "Z17 idempotent off (got '$OUT17')" FAIL
rm -rf "$P17"

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
P17C="$(mktemp -d -t zenmode-XXXXXX)"; S17C="z17c-$$"
new_session "$P17C" "$S17C"
helper "$P17C" "$S17C" --on >/dev/null
MARKER17C="$(find "$P17C/.zensu/state" -maxdepth 1 -name 'zen-mode-*.json' | head -1)"
VICTIM17C="$P17C/victim.txt"; printf 'untouched\n' > "$VICTIM17C"
rm -f "$MARKER17C"; ln -s "$VICTIM17C" "$MARKER17C"
helper "$P17C" "$S17C" --on >/dev/null 2>&1; RC17C=$?
OUT17C="$(fire "$P17C" "$S17C" "do a thing" | classify)"
if [ "$RC17C" != "0" ] && [ "$(cat "$VICTIM17C")" = "untouched" ] && [ "$OUT17C" = "EMPTY" ]; then
  check "Z17c symlinked marker refused by writer, ignored by hook, target untouched" PASS
else
  check "Z17c symlink guard (rc=$RC17C victim='$(cat "$VICTIM17C")' hook='$OUT17C')" FAIL
fi
rm -rf "$P17C"

# Z18 marker is per session — a second session in the same project stays off
P18="$(mktemp -d -t zenmode-XXXXXX)"; S18A="z18a-$$"; S18B="z18b-$$"
new_session "$P18" "$S18A"; new_session "$P18" "$S18B"
helper "$P18" "$S18A" --on >/dev/null
OUT18A="$(fire "$P18" "$S18A" "do a thing" | classify)"
OUT18B="$(fire "$P18" "$S18B" "do a thing" | classify)"
if [ "$OUT18A" = "UserPromptSubmit|ON" ] && [ "$OUT18B" = "EMPTY" ]; then
  check "Z18 marker is session-scoped: sibling session in same project stays off" PASS
else
  check "Z18 session scoping (a='$OUT18A' b='$OUT18B')" FAIL
fi
rm -rf "$P18"

# Z19 the injected reminder actually carries the contract rules it promises
P19="$(mktemp -d -t zenmode-XXXXXX)"; S19="z19-$$"
new_session "$P19" "$S19"; helper "$P19" "$S19" --on >/dev/null
RAW19="$(fire "$P19" "$S19" "do a thing")"
MISSING19=""
for FRAG19 in "recap" "first sentence" "OVERRIDES" "one next step" "ONE question" "Step N of M" "user's own language"; do
  printf '%s' "$RAW19" | grep -qiF "$FRAG19" || MISSING19="$MISSING19 '$FRAG19'"
done
[ -z "$MISSING19" ] && check "Z19 reminder carries recap/result-first/precedence/one-step/one-question/anchor/language rules" PASS \
  || check "Z19 reminder missing:$MISSING19" FAIL
rm -rf "$P19"

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
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'Rules 3, 4, 5, 7 and 8 are suspended' \
  && printf '%s' "$SKILL_FLAT" | grep -qiF 'never suspended'; then
  check "Z23 SKILL.md carve-out lifts rules 3/4/5/7/8 but keeps the full-sentence rule" PASS
else
  check "Z23 SKILL.md safety carve-out missing, or does not lift 5/8, or lifts the precedence rule" FAIL
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

# Z27 config.example.json documents the hooks.zenMode flag
if node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  process.exit((j.hooks||{}).zenMode===true?0:1);
' "$PLUGIN_DIR/config.example.json" 2>/dev/null; then
  check "Z27 config.example.json documents hooks.zenMode" PASS
else
  check "Z27 config.example.json missing hooks.zenMode" FAIL
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
