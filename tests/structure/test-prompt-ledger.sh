#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
LIB="$PLUGIN_DIR/hooks/lib/zensu-prompt-ledger.sh"
RESET_HOOK="$PLUGIN_DIR/hooks/session-start-prompt-ledger.sh"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
WORK="$(mktemp -d -t prompt-ledger-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; SKIP=0
skip() { echo "  SKIP  $1"; SKIP=$((SKIP+1)); }
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
finish() {
  echo "----"
  echo "test-prompt-ledger: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
  [ "$FAIL" -eq 0 ]
}

if ! command -v node >/dev/null 2>&1 || [ ! -f "$LIB" ] || [ ! -f "$RESET_HOOK" ]; then
  check "L0 node is on PATH and both ledger files exist" FAIL
  finish
  exit 1
fi

{ bash -n "$LIB" && bash -n "$RESET_HOOK"; } 2>/dev/null \
  && check "L1 the ledger library and the reset hook pass bash -n" PASS \
  || check "L1 the ledger library or the reset hook fails bash -n" FAIL

session_key() {
  ( cd -P -- "$PLUGIN_DIR/hooks/lib" && node ./session-control-core-v1.js session-key "$1" )
}

ledger() {
  local data="$1" root="$2"
  shift 2
  ( export CLAUDE_PLUGIN_DATA="$data" CLAUDE_PLUGIN_ROOT="$root"
    source "$PLUGIN_DIR/hooks/lib/zensu-session.sh"
    source "$LIB"
    "$@" )
}

entry_name() {
  ( export CLAUDE_PLUGIN_ROOT="$1"
    source "$LIB"
    _zensu_prompt_ledger_entry_name "$2" && printf '%s' "$_ZENSU_PROMPT_LEDGER_ENTRY" )
}

reset_hook() {
  local data="$1" payload="$2"
  printf '%s' "$payload" | env CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$data" \
    bash "$RESET_HOOK" 2>/dev/null
}

DATA="$WORK/data"
mkdir -p "$DATA"
KEY_A="$(session_key ledger-session-a)"
KEY_B="$(session_key ledger-session-b)"

L2_BAD=""
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" tdd-vanilla && L2_BAD="$L2_BAD [has before mark]"
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" tdd-vanilla || L2_BAD="$L2_BAD [mark refused]"
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" tdd-vanilla || L2_BAD="$L2_BAD [no has after mark]"
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" tdd-strict && L2_BAD="$L2_BAD [other contract reads delivered]"
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_B" tdd-vanilla && L2_BAD="$L2_BAD [other session reads delivered]"
for CONTRACT in tdd-strict router zen-none zen-armed; do
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" "$CONTRACT" \
    && ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" "$CONTRACT" \
    || L2_BAD="$L2_BAD [$CONTRACT]"
done
for BOGUS in bogus '' '../escape' 'tdd-vanilla/..'; do
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" "$BOGUS" && L2_BAD="$L2_BAD [marked '$BOGUS']"
done
[ -z "$L2_BAD" ] \
  && check "L2 a mark is read back for its own session and contract only, and only the five known contracts can be marked" PASS \
  || check "L2 ledger round trip broken:$L2_BAD" FAIL

L3_BAD=""
ROOT_OTHER="$WORK/plugins/9.9.9"
mkdir -p "$ROOT_OTHER"
ledger "$DATA" "$ROOT_OTHER" zensu_prompt_ledger_has "$KEY_A" tdd-vanilla && L3_BAD="$L3_BAD [another plugin root reads delivered]"
ENTRY_NAMES="$(ls "$DATA/prompt-ledger/v1/$KEY_A" 2>/dev/null | tr '\n' ' ')"
case "$ENTRY_NAMES" in
  *"$(entry_name "$PLUGIN_DIR" tdd-vanilla) "*) ;;
  *) L3_BAD="$L3_BAD [entry names: $ENTRY_NAMES]" ;;
esac
SAME_LEN=$(( ${#PLUGIN_DIR} - ${#WORK} - 1 ))
if [ "$SAME_LEN" -gt 0 ] && [ "$SAME_LEN" -lt 200 ]; then
  ROOT_SAME="$WORK/$(printf '%*s' "$SAME_LEN" '' | tr ' ' 'q')"
  mkdir -p "$ROOT_SAME"
  [ "${#ROOT_SAME}" -eq "${#PLUGIN_DIR}" ] || L3_BAD="$L3_BAD [same-length root is ${#ROOT_SAME}, want ${#PLUGIN_DIR}]"
  ledger "$DATA" "$ROOT_SAME" zensu_prompt_ledger_has "$KEY_A" tdd-vanilla && L3_BAD="$L3_BAD [a root of the same length reads delivered]"
else
  L3_BAD="$L3_BAD [cannot build a same-length root: $SAME_LEN]"
fi
ODD_ROOT="$WORK/odd root:x"
mkdir -p "$ODD_ROOT"
case "$(entry_name "$ODD_ROOT" router)" in
  "router--${#ODD_ROOT}-odd_root_x") ;;
  *) L3_BAD="$L3_BAD [unsanitized entry name: $(entry_name "$ODD_ROOT" router)]" ;;
esac
[ -z "$L3_BAD" ] \
  && check "L3 an entry is tagged with the executing plugin root, so an update served from another root sends the full text again" PASS \
  || check "L3 plugin-root tag broken:$L3_BAD" FAIL

L4_BAD=""
for BADKEY in '' 'ledger-session-a' "scv1_$(printf '%064d' 0)x" "../$KEY_A"; do
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$BADKEY" router && L4_BAD="$L4_BAD [marked key '$BADKEY']"
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$BADKEY" router && L4_BAD="$L4_BAD [has key '$BADKEY']"
done
NO_SESSION_LIB="$( export CLAUDE_PLUGIN_DATA="$DATA" CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
  source "$LIB"; zensu_prompt_ledger_has "$KEY_A" tdd-vanilla && echo has || echo refused )"
[ "$NO_SESSION_LIB" = "refused" ] || L4_BAD="$L4_BAD [read without the session key validator]"
[ -z "$L4_BAD" ] \
  && check "L4 a non-canonical session key, or a caller that did not load the key validator, reads as not delivered and marks nothing" PASS \
  || check "L4 key validation broken:$L4_BAD" FAIL

L5_BAD=""
for BADDATA in '' "$WORK/missing" "$WORK/nl"$'\n'"x"; do
  ledger "$BADDATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router && L5_BAD="$L5_BAD [marked under '$BADDATA']"
  ledger "$BADDATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router && L5_BAD="$L5_BAD [has under '$BADDATA']"
done
[ -e "$WORK/missing" ] && L5_BAD="$L5_BAD [created a missing data root]"
ln -s "$DATA" "$WORK/data-link" 2>/dev/null
if [ -L "$WORK/data-link" ]; then
  ledger "$WORK/data-link" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" tdd-vanilla && L5_BAD="$L5_BAD [has through a symlinked data root]"
fi
[ -z "$L5_BAD" ] \
  && check "L5 an unusable CLAUDE_PLUGIN_DATA reads as not delivered and is never created" PASS \
  || check "L5 data root handling broken:$L5_BAD" FAIL

L6_BAD=""
L6_SKIP=""
L6_ROUTER="$(entry_name "$PLUGIN_DIR" router)"
L6_ZEN="$(entry_name "$PLUGIN_DIR" zen-none)"
for L6_AT in prompt-ledger v1 key entry; do
  L6_DATA="$WORK/data-l6-$L6_AT"
  L6_TARGET="$WORK/elsewhere-$L6_AT"
  case "$L6_AT" in
    (prompt-ledger) L6_LINK="$L6_DATA/prompt-ledger"; L6_HELD="$L6_TARGET/v1/$KEY_A/$L6_ROUTER" ;;
    (v1) L6_LINK="$L6_DATA/prompt-ledger/v1"; L6_HELD="$L6_TARGET/$KEY_A/$L6_ROUTER" ;;
    (key) L6_LINK="$L6_DATA/prompt-ledger/v1/$KEY_A"; L6_HELD="$L6_TARGET/$L6_ROUTER" ;;
    (entry) L6_LINK="$L6_DATA/prompt-ledger/v1/$KEY_A/$L6_ROUTER"; L6_HELD="$L6_TARGET/keep" ;;
  esac
  mkdir -p "$(dirname "$L6_LINK")" "$L6_HELD"
  ln -s "$L6_TARGET" "$L6_LINK" 2>/dev/null
  if [ ! -L "$L6_LINK" ]; then
    L6_SKIP=1
    break
  fi
  ledger "$L6_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router && L6_BAD="$L6_BAD [$L6_AT: has through the link]"
  ledger "$L6_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router && L6_BAD="$L6_BAD [$L6_AT: marked through the link]"
  ledger "$L6_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" zen-none
  [ -n "$(find "$L6_TARGET" -name "$L6_ZEN" 2>/dev/null)" ] && L6_BAD="$L6_BAD [$L6_AT: wrote through the link]"
  ledger "$L6_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_reset "$KEY_A"
  [ -L "$L6_LINK" ] && L6_BAD="$L6_BAD [$L6_AT: reset kept the link]"
  [ -d "$L6_HELD" ] || L6_BAD="$L6_BAD [$L6_AT: reset deleted through the link]"
done
if [ -n "$L6_SKIP" ]; then
  skip "L6 this host did not create a symbolic link"
elif [ -z "$L6_BAD" ]; then
  check "L6 a symlink at the ledger root, at v1, at the session key or at an entry reads as not delivered even with an entry behind it, is never written through, and a reset removes only the link" PASS
else
  check "L6 symlink handling broken:$L6_BAD" FAIL
fi

L7_BAD=""
L7_DATA="$WORK/data-l7"
mkdir -p "$L7_DATA/prompt-ledger/v1/$KEY_A"
L7_ENTRY="$L7_DATA/prompt-ledger/v1/$KEY_A/$(entry_name "$PLUGIN_DIR" zen-none)"
: > "$L7_ENTRY"
ledger "$L7_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" zen-none && L7_BAD="$L7_BAD [a regular file reads delivered]"
ledger "$L7_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" zen-none && L7_BAD="$L7_BAD [marked over a regular file]"
rm -f "$L7_ENTRY"
if mkfifo "$L7_ENTRY" 2>/dev/null && [ -p "$L7_ENTRY" ]; then
  L7_START=$SECONDS
  ledger "$L7_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" zen-none && L7_BAD="$L7_BAD [a FIFO reads delivered]"
  [ $(( SECONDS - L7_START )) -le 5 ] || L7_BAD="$L7_BAD [blocked on a FIFO]"
else
  skip "L7 FIFO arm: this host did not create a FIFO"
fi
[ -z "$L7_BAD" ] \
  && check "L7 an entry path held by a regular file or a FIFO reads as not delivered without opening it" PASS \
  || check "L7 occupied entry handling broken:$L7_BAD" FAIL

L8_BAD=""
for SOURCE in startup resume clear compact fork; do
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_B" router
  L8_OUT="$(reset_hook "$DATA" "{\"hook_event_name\":\"SessionStart\",\"source\":\"$SOURCE\",\"session_id\":\"ledger-session-a\"}")"
  L8_RC=$?
  [ "$L8_RC" -eq 0 ] && [ -z "$L8_OUT" ] || L8_BAD="$L8_BAD [$SOURCE exit=$L8_RC bytes=${#L8_OUT}]"
  [ -e "$DATA/prompt-ledger/v1/$KEY_A" ] && L8_BAD="$L8_BAD [$SOURCE kept the session ledger]"
  ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_B" router || L8_BAD="$L8_BAD [$SOURCE reset another session]"
done
[ -z "$L8_BAD" ] \
  && check "L8 every SessionStart source clears that session's ledger, silently, and leaves other sessions alone" PASS \
  || check "L8 reset broken:$L8_BAD" FAIL

L9_BAD=""
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
for PAYLOAD in '{"hook_event_name":"UserPromptSubmit","session_id":"ledger-session-a","prompt":"x"}' \
  '{"hook_event_name":"SubagentStart","session_id":"ledger-session-a"}' '{"hook_event_name":"SessionStart"}' 'not json' ''; do
  L9_OUT="$(reset_hook "$DATA" "$PAYLOAD")"
  L9_RC=$?
  [ "$L9_RC" -eq 0 ] && [ -z "$L9_OUT" ] || L9_BAD="$L9_BAD [payload '$PAYLOAD' exit=$L9_RC]"
done
ledger "$DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router || L9_BAD="$L9_BAD [a non-SessionStart payload reset the ledger]"
[ -z "$L9_BAD" ] \
  && check "L9 the reset hook acts only on a SessionStart payload with a session id and exits 0 silently on anything else" PASS \
  || check "L9 reset event handling broken:$L9_BAD" FAIL

L10_BAD=""
L10_DATA="$WORK/data-l10"
mkdir -p "$L10_DATA/prompt-ledger/v1"
KEY_OLD="$(session_key ledger-session-old)"
KEY_NEW="$(session_key ledger-session-new)"
mkdir -p "$L10_DATA/prompt-ledger/v1/$KEY_OLD" "$L10_DATA/prompt-ledger/v1/$KEY_NEW" "$L10_DATA/prompt-ledger/v1/not-a-key"
touch -t 202001010000 "$L10_DATA/prompt-ledger/v1/$KEY_OLD" "$L10_DATA/prompt-ledger/v1/not-a-key"
reset_hook "$L10_DATA" '{"hook_event_name":"SessionStart","source":"startup","session_id":"ledger-session-fresh"}' >/dev/null
[ -e "$L10_DATA/prompt-ledger/v1/$KEY_OLD" ] && L10_BAD="$L10_BAD [kept a ledger idle since 2020]"
[ -d "$L10_DATA/prompt-ledger/v1/$KEY_NEW" ] || L10_BAD="$L10_BAD [swept a fresh ledger]"
[ -d "$L10_DATA/prompt-ledger/v1/not-a-key" ] || L10_BAD="$L10_BAD [swept a name that is not a session key]"
[ -z "$L10_BAD" ] \
  && check "L10 a SessionStart sweeps session ledgers idle for more than 14 days and nothing else" PASS \
  || check "L10 sweep broken:$L10_BAD" FAIL

L12_DATA="$WORK/data-l12"
mkdir -p "$L12_DATA"
ledger "$L12_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
chmod 500 "$L12_DATA/prompt-ledger/v1/$KEY_A" 2>/dev/null
if [ ! -w "$L12_DATA/prompt-ledger/v1/$KEY_A" ]; then
  if ledger "$L12_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router; then
    check "L12 a session ledger the reset could not delete still reads as delivered" FAIL
  else
    check "L12 a session ledger the reset could not delete reads as not delivered, so the full text goes out" PASS
  fi
else
  skip "L12 this host does not enforce directory write permission"
fi
chmod 700 "$L12_DATA/prompt-ledger/v1/$KEY_A" 2>/dev/null

L13_BAD=""
L13_DATA="$WORK/data-l13"
L13_DIR="$L13_DATA/prompt-ledger/v1/$KEY_A"
L13_PAYLOAD='{"hook_event_name":"SessionStart","source":"compact","session_id":"ledger-session-a"}'
mkdir -p "$L13_DATA"
ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
chmod 300 "$L13_DIR" 2>/dev/null
if ls "$L13_DIR" >/dev/null 2>&1; then
  chmod 700 "$L13_DIR" 2>/dev/null
  skip "L13 this host does not enforce directory read permission"
else
  reset_hook "$L13_DATA" "$L13_PAYLOAD" >/dev/null
  [ -e "$L13_DIR" ] || L13_BAD="$L13_BAD [the unlistable ledger was deleted after all]"
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router && L13_BAD="$L13_BAD [a ledger the reset could not list reads delivered]"
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router && L13_BAD="$L13_BAD [a mark after a failed reset reads delivered]"
  touch -t 202001010000 "$L13_DIR" "$L13_DIR.stale" 2>/dev/null
  reset_hook "$L13_DATA" '{"hook_event_name":"SessionStart","source":"startup","session_id":"ledger-session-fresh"}' >/dev/null
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router && L13_BAD="$L13_BAD [another session's sweep cleared the failed reset]"
  chmod 700 "$L13_DIR" 2>/dev/null
  reset_hook "$L13_DATA" "$L13_PAYLOAD" >/dev/null
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router || L13_BAD="$L13_BAD [no recovery after a reset that succeeded]"
  L13_ENTRY="$L13_DIR/$(entry_name "$PLUGIN_DIR" zen-none)"
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" zen-none
  : > "$L13_ENTRY/held"
  chmod 500 "$L13_ENTRY" 2>/dev/null
  reset_hook "$L13_DATA" "$L13_PAYLOAD" >/dev/null
  [ -d "$L13_ENTRY" ] || L13_BAD="$L13_BAD [the read-only entry was deleted after all]"
  ledger "$L13_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" zen-none && L13_BAD="$L13_BAD [an entry the reset could not delete reads delivered]"
  chmod 700 "$L13_ENTRY" 2>/dev/null
  [ -z "$L13_BAD" ] \
    && check "L13 a reset that cannot delete the session ledger records that, so every contract reads as not delivered until a later reset succeeds, and another session's sweep keeps that record" PASS \
    || check "L13 failed reset handling broken:$L13_BAD" FAIL
fi

L14_BAD=""
L14_DATA="$WORK/data-l14"
L14_ROOT="$L14_DATA/prompt-ledger/v1"
KEY_ORPHAN="$(session_key ledger-session-orphan)"
mkdir -p "$L14_ROOT/$KEY_ORPHAN.stale" "$L14_ROOT/$KEY_A.stale"
ledger "$L14_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
reset_hook "$L14_DATA" '{"hook_event_name":"SessionStart","source":"startup","session_id":"ledger-session-fresh"}' >/dev/null
[ -e "$L14_ROOT/$KEY_ORPHAN.stale" ] && L14_BAD="$L14_BAD [kept a record whose ledger is gone]"
[ -e "$L14_ROOT/$KEY_A.stale" ] || L14_BAD="$L14_BAD [swept a record whose ledger exists]"
ledger "$L14_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router && L14_BAD="$L14_BAD [a recorded failed reset reads delivered]"
reset_hook "$L14_DATA" '{"hook_event_name":"SessionStart","source":"clear","session_id":"ledger-session-a"}' >/dev/null
[ -e "$L14_ROOT/$KEY_A.stale" ] && L14_BAD="$L14_BAD [a reset that succeeded kept the record]"
ledger "$L14_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_mark "$KEY_A" router
ledger "$L14_DATA" "$PLUGIN_DIR" zensu_prompt_ledger_has "$KEY_A" router || L14_BAD="$L14_BAD [no recovery after a reset that succeeded]"
[ -z "$L14_BAD" ] \
  && check "L14 a failed-reset record outlives the sweep while its ledger exists, an orphaned one is swept, and the next reset that succeeds clears it" PASS \
  || check "L14 failed-reset record lifecycle broken:$L14_BAD" FAIL

L11="$(HOOKS_JSON="$HOOKS_JSON" node -e '
  const h = JSON.parse(require("fs").readFileSync(process.env.HOOKS_JSON, "utf8"));
  const out = [];
  for (const [event, groups] of Object.entries(h.hooks || {})) {
    for (const group of groups || []) {
      for (const hook of group.hooks || []) {
        if (String(hook.command || "").includes("session-start-prompt-ledger.sh")) {
          out.push(event + ":" + (Object.prototype.hasOwnProperty.call(group, "matcher") ? "matcher" : "none") + ":" + hook.timeout);
        }
      }
    }
  }
  process.stdout.write(out.join(","));
' 2>/dev/null)"
[ "$L11" = "SessionStart:none:10" ] \
  && check "L11 hooks.json registers the reset hook once, on SessionStart, without a matcher, with a 10 s timeout" PASS \
  || check "L11 reset hook registration is '${L11:-none}', want SessionStart:none:10" FAIL

finish
