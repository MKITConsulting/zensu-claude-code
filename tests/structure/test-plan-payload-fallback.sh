#!/bin/bash
# Pins how plan-approved-delegate.sh reads the approved plan out of the
# ExitPlanMode payload, and that each way of failing gets its own receipt.
#
#   F1  plan only                    -> approves, digest over the inline text
#   F2  planFilePath only            -> approves, digest over the file bytes
#   F3  both, differing              -> plan wins; the file is never opened
#   F4  neither                      -> INVALID_PLAN_PAYLOAD
#   F5  nonexistent path             -> PLAN_FILE_UNREADABLE
#   F6  directory                    -> PLAN_FILE_NOT_REGULAR
#   F7  empty file                   -> PLAN_FILE_EMPTY
#   F8  empty plan string            -> falls back rather than blocking
#   F9  padded file                  -> bytes digested verbatim, no trimming
#   F13 oversize file                -> PLAN_FILE_TOO_LARGE
#   F14 exactly at the limit         -> approves
#   F15 relative path                -> PLAN_FILE_PATH_REJECTED
#   F16 UNC-style path               -> PLAN_FILE_PATH_REJECTED
#   F17 symlink (POSIX)              -> PLAN_FILE_SYMLINK_REJECTED
#   F18 file plan, marker missing    -> PLAN_MARKER_MISSING_OR_AMBIGUOUS
#   F19 file plan, foreign marker    -> PLAN_MARKER_RUN_MISMATCH
#   F20 foreign session, path only   -> OWNER_SESSION_MISMATCH, file untouched
#   F21 non-string plan              -> INVALID_PLAN_PAYLOAD, no fallback
#   F22 multi-byte UTF-8 plan file   -> digest still equals the file bytes
#
# F18/F19 matter because they prove file-fed bytes face the same run-binding
# checks as inline text. F20 pins that authorization is decided BEFORE the
# payload's path is touched at all, so an unauthorized payload can neither
# make the hook open an arbitrary path nor learn whether it exists.
# Every refusal is additionally checked to leave the run record byte-identical
# and to emit no standalone ask-first directive.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-autopilot-state.sh"
BASELINE="$PLUGIN_DIR/tests/session-control/initialize-baseline.sh"
HOST_PATH="$PLUGIN_DIR/hooks/lib/zensu-host-path.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then echo "  PASS  $1"; PASS=$((PASS + 1));
  else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}

[ -f "$HOOK" ] && bash -n "$HOOK" 2>/dev/null \
  && check "F0 plan hook exists and parses" PASS \
  || { check "F0 plan hook exists and parses" FAIL; exit 1; }
# shellcheck disable=SC1090
source "$LIB" || exit 1

RAW_TMP="$(mktemp -d -t zensu-plan-payload-XXXXXX)"
RAW_TMP="$(cd -P -- "$RAW_TMP" && pwd -P)"
TMP="$(bash "$HOST_PATH" "$RAW_TMP")" || exit 1
trap 'rm -rf "$RAW_TMP"' EXIT

CFG_OFF="$TMP/off.json"
printf '%s\n' '{"hooks":{"autoTdd":false}}' > "$CFG_OFF"
CFG_ON="$TMP/on.json"
printf '%s\n' '{"hooks":{"autoTdd":true}}' > "$CFG_ON"

PROVISIONED_KEY=""
PROVISIONED_DATA=""
provision_session() {
  export CLAUDE_PROJECT_DIR="$1"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data/$3"
  # shellcheck disable=SC1090
  source "$BASELINE" "$2" || return 1
  PROVISIONED_KEY="$ZENSU_SESSION_KEY"
  PROVISIONED_DATA="$CLAUDE_PLUGIN_DATA"
}

MSYS_EXCL="PLAN_PATH"
[ -z "${MSYS2_ENV_CONV_EXCL:-}" ] || MSYS_EXCL="${MSYS2_ENV_CONV_EXCL};PLAN_PATH"

# $1 raw session id, $2 plan text or __ABSENT__, $3 planFilePath or __ABSENT__
payload() {
  MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID="$1" PLAN="$2" PLAN_PATH="$3" node -e '
    const ti={};
    if (process.env.PLAN!=="__ABSENT__") ti.plan=process.env.PLAN;
    if (process.env.PLAN_PATH!=="__ABSENT__") ti.planFilePath=process.env.PLAN_PATH;
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode", tool_input:ti
    }));
  '
}

# A plan field that is present but not a string must never reach the fallback.
payload_nonstring_plan() {
  MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID="$1" PLAN_PATH="$2" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode",
      tool_input:{plan:{unexpected:"object"}, planFilePath:process.env.PLAN_PATH}
    }));
  '
}

invoke() {
  (
    printf '%s' "$1" | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY \
      -u ZENSU_SESSION_CONTEXT -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$4" \
      CLAUDE_PROJECT_DIR="$2" ZENSU_CONFIG="${3:-$CFG_OFF}" bash "$HOOK" 2>/dev/null
  )
}

digest() {
  node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$1"
}
file_sha() { digest "$1"; }
text_sha() {
  printf '%s' "$1" | node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(0)).digest("hex"));'
}
run_field() {
  RUN_FILE="$1" FIELD="$2" node -e '
    try { const j=require(process.env.RUN_FILE); const v=j[process.env.FIELD];
      process.stdout.write(typeof v==="string"?v:""); } catch (_) { process.exit(1); }
  ' 2>/dev/null
}

ARMED_PROJECT=""
ARMED_DATA=""
ARMED_RUN_FILE=""
arm_run() {
  local project="$TMP/$1"
  mkdir -p "$project"
  provision_session "$project" "$2" "$1" || return 1
  autopilot_begin_run "$3" "$PROVISIONED_KEY" "$project" >/dev/null || return 1
  ARMED_PROJECT="$project"
  ARMED_DATA="$PROVISIONED_DATA"
  ARMED_RUN_FILE="$(autopilot_run_file "$3" "$project")"
}

# --- F1 inline plan: the pre-existing path, unchanged ---
arm_run inline inline_session inline_run || { echo "F1 fixture failed" >&2; exit 1; }
INLINE_PLAN="# Inline plan

Implement it.

<!-- zensu-autopilot:inline_run -->"
OUT1="$(invoke "$(payload inline_session "$INLINE_PLAN" __ABSENT__)" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
INLINE_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT1" | grep -qF 'PLAN_APPROVED' \
  && [ "$INLINE_SHA_ACTUAL" = "$(text_sha "$INLINE_PLAN")" ]; then
  check "F1 an inline tool_input.plan still approves and digests the plan text" PASS
else
  check "F1 inline plan (sha=$INLINE_SHA_ACTUAL)" FAIL
fi

# --- F2 path-only payload: the fallback ---
arm_run pathonly pathonly_session pathonly_run || { echo "F2 fixture failed" >&2; exit 1; }
PLAN_FILE="$TMP/pathonly-plan.md"
printf '# Plan on disk\n\nImplement it.\n\n<!-- zensu-autopilot:pathonly_run -->\n' > "$PLAN_FILE"
OUT2="$(invoke "$(payload pathonly_session __ABSENT__ "$PLAN_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
FILE_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT2" | grep -qF 'PLAN_APPROVED'; then
  check "F2 a payload carrying only planFilePath approves from the file" PASS
else
  check "F2 path-only payload did not approve (out='$OUT2')" FAIL
fi
if [ -n "$FILE_SHA_ACTUAL" ] && [ "$FILE_SHA_ACTUAL" = "$(file_sha "$PLAN_FILE")" ]; then
  check "F2a the persisted digest is sha256 of the file bytes, verbatim" PASS
else
  check "F2a file digest (got=$FILE_SHA_ACTUAL)" FAIL
fi

# --- F9 no normalisation: whitespace a trim would eat survives into the digest ---
arm_run verbatim verbatim_session verbatim_run || { echo "F9 fixture failed" >&2; exit 1; }
VERBATIM_FILE="$TMP/verbatim-plan.md"
printf '\n\n   # Padded plan   \n\n<!-- zensu-autopilot:verbatim_run -->\n   \n\n' > "$VERBATIM_FILE"
OUT9="$(invoke "$(payload verbatim_session __ABSENT__ "$VERBATIM_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
VERBATIM_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT9" | grep -qF 'PLAN_APPROVED' \
  && [ "$VERBATIM_ACTUAL" = "$(file_sha "$VERBATIM_FILE")" ] \
  && [ "$VERBATIM_ACTUAL" != "$(text_sha "$(cat "$VERBATIM_FILE")")" ]; then
  check "F9 the fallback digests the file bytes verbatim, with no trimming" PASS
else
  check "F9 verbatim bytes (got=$VERBATIM_ACTUAL)" FAIL
fi

# --- F22 a multi-byte UTF-8 plan still digests to the file bytes ---
arm_run utf8plan utf8_session utf8_run || { echo "F22 fixture failed" >&2; exit 1; }
UTF8_FILE="$TMP/utf8-plan.md"
printf '# Pl\xc3\xa4ne \xe2\x80\x94 caf\xc3\xa9 \xf0\x9f\x9a\x80\n\n<!-- zensu-autopilot:utf8_run -->\n' > "$UTF8_FILE"
OUT22="$(invoke "$(payload utf8_session __ABSENT__ "$UTF8_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT22" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$UTF8_FILE")" ]; then
  check "F22 a multi-byte UTF-8 plan file round-trips to the same digest" PASS
else
  check "F22 multi-byte UTF-8 digest mismatch" FAIL
fi

# --- F23 a plan file that is NOT valid UTF-8 must still digest to its own
# bytes. Decoding to a string and re-encoding would replace the bad bytes with
# U+FFFD, so the durable digest would no longer identify the approved file.
arm_run rawbytes rawbytes_session rawbytes_run || { echo "F23 fixture failed" >&2; exit 1; }
RAW_FILE="$TMP/raw-bytes-plan.md"
node -e '
  const fs=require("fs");
  fs.writeFileSync(process.argv[1],Buffer.concat([
    Buffer.from("# Latin-1 byte: "),
    Buffer.from([0xff, 0xfe]),
    Buffer.from("\n\n<!-- zensu-autopilot:rawbytes_run -->\n")
  ]));
' "$RAW_FILE"
OUT23="$(invoke "$(payload rawbytes_session __ABSENT__ "$RAW_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
RAW_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT23" | grep -qF 'PLAN_APPROVED' \
  && [ "$RAW_ACTUAL" = "$(file_sha "$RAW_FILE")" ]; then
  check "F23 an invalid-UTF-8 plan file digests to its raw bytes, not a re-encoding" PASS
else
  check "F23 raw-byte digest (got=$RAW_ACTUAL want=$(file_sha "$RAW_FILE"))" FAIL
fi

# --- F14 a file exactly at the size limit is still accepted ---
arm_run atlimit atlimit_session atlimit_run || { echo "F14 fixture failed" >&2; exit 1; }
LIMIT_FILE="$TMP/at-limit-plan.md"
node -e '
  const fs=require("fs");
  const marker="\n<!-- zensu-autopilot:atlimit_run -->\n";
  const total=4*1024*1024;
  const filler=Buffer.alloc(total-Buffer.byteLength(marker),0x61);
  fs.writeFileSync(process.argv[1],Buffer.concat([filler,Buffer.from(marker)]));
' "$LIMIT_FILE"
OUT14="$(invoke "$(payload atlimit_session __ABSENT__ "$LIMIT_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT14" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$LIMIT_FILE")" ]; then
  check "F14 a plan file exactly at the 4 MiB limit is accepted" PASS
else
  check "F14 at-limit file rejected (out='$(printf '%s' "$OUT14" | head -c 120)')" FAIL
fi

# --- F3 both fields present: the inline plan wins and the file is never opened.
# The decoy path does not exist, so a read-then-prefer implementation blocks.
arm_run bothfields both_session both_run || { echo "F3 fixture failed" >&2; exit 1; }
BOTH_PLAN="# Inline wins

<!-- zensu-autopilot:both_run -->"
OUT3="$(invoke "$(payload both_session "$BOTH_PLAN" "$TMP/decoy-never-created.md")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT3" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$BOTH_PLAN")" ]; then
  check "F3 tool_input.plan short-circuits before the path is ever touched" PASS
else
  check "F3 precedence (out='$(printf '%s' "$OUT3" | head -c 160)')" FAIL
fi

# --- F8 an empty plan string is treated as absent, not as a block ---
arm_run emptyplan emptyplan_session emptyplan_run || { echo "F8 fixture failed" >&2; exit 1; }
EMPTY_PLAN_FILE="$TMP/emptyplan-plan.md"
printf '# Fallback used\n\n<!-- zensu-autopilot:emptyplan_run -->\n' > "$EMPTY_PLAN_FILE"
OUT8="$(invoke "$(payload emptyplan_session "" "$EMPTY_PLAN_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT8" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$EMPTY_PLAN_FILE")" ]; then
  check "F8 an empty plan string falls back to the file instead of blocking" PASS
else
  check "F8 empty plan string did not fall back (out='$OUT8')" FAIL
fi

# --- Every refusal shares one run: none of them may mutate it by a single byte ---
arm_run refuse refuse_session refuse_run || { echo "refuse fixture failed" >&2; exit 1; }
REFUSE_PROJECT="$ARMED_PROJECT"
REFUSE_DATA="$ARMED_DATA"
REFUSE_RUN_FILE="$ARMED_RUN_FILE"
REFUSE_BEFORE="$(digest "$REFUSE_RUN_FILE")"

# A refusal must name its code, leave the run record byte-identical, and never
# fall through to the standalone ask-first directive.
refuses_with() {
  local label="$1" code="$2" out="$3"
  if printf '%s' "$out" | grep -qF "code=$code" \
    && [ "$(digest "$REFUSE_RUN_FILE")" = "$REFUSE_BEFORE" ] \
    && ! printf '%s' "$out" | grep -qF 'AskUserQuestion'; then
    check "$label" PASS
  else
    check "$label (out='$(printf '%s' "$out" | head -c 200)')" FAIL
  fi
}

refuses_with "F4 a payload with neither field blocks as INVALID_PLAN_PAYLOAD" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$(payload refuse_session __ABSENT__ __ABSENT__)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F5 a nonexistent planFilePath reports PLAN_FILE_UNREADABLE" \
  PLAN_FILE_UNREADABLE \
  "$(invoke "$(payload refuse_session __ABSENT__ "$TMP/no-such-plan.md")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

DIR_PATH="$TMP/plan-as-directory"
mkdir -p "$DIR_PATH"
refuses_with "F6 a directory at planFilePath reports PLAN_FILE_NOT_REGULAR" \
  PLAN_FILE_NOT_REGULAR \
  "$(invoke "$(payload refuse_session __ABSENT__ "$DIR_PATH")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

EMPTY_FILE="$TMP/empty-plan.md"
: > "$EMPTY_FILE"
refuses_with "F7 an empty plan file reports PLAN_FILE_EMPTY, not a generic failure" \
  PLAN_FILE_EMPTY \
  "$(invoke "$(payload refuse_session __ABSENT__ "$EMPTY_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# Sparse: the size guard rejects this before any read, so allocating real bytes
# would only cost Windows CI time.
OVERSIZE_FILE="$TMP/oversize-plan.md"
node -e '
  const fs=require("fs");
  fs.closeSync(fs.openSync(process.argv[1],"w"));
  fs.truncateSync(process.argv[1],4*1024*1024+1);
' "$OVERSIZE_FILE"
refuses_with "F13 a file past the 4 MiB limit reports PLAN_FILE_TOO_LARGE" \
  PLAN_FILE_TOO_LARGE \
  "$(invoke "$(payload refuse_session __ABSENT__ "$OVERSIZE_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F15 a relative planFilePath is rejected before any filesystem access" \
  PLAN_FILE_PATH_REJECTED \
  "$(invoke "$(payload refuse_session __ABSENT__ 'relative/plan.md')" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# A UNC path would make a Windows stat authenticate against a remote host.
refuses_with "F16 a UNC-style planFilePath is rejected before any filesystem access" \
  PLAN_FILE_PATH_REJECTED \
  "$(invoke "$(payload refuse_session __ABSENT__ '//attacker.example.com/share/plan.md')" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F17 symlinks are refused where the platform can make one ---
LINK_TARGET="$TMP/symlink-target-plan.md"
printf '# Linked plan\n\n<!-- zensu-autopilot:refuse_run -->\n' > "$LINK_TARGET"
LINK_PATH="$TMP/symlinked-plan.md"
if ln -s "$LINK_TARGET" "$LINK_PATH" 2>/dev/null && [ -L "$LINK_PATH" ]; then
  refuses_with "F17 a symlinked planFilePath is refused, not silently followed" \
    PLAN_FILE_SYMLINK_REJECTED \
    "$(invoke "$(payload refuse_session __ABSENT__ "$LINK_PATH")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"
else
  check "F17 symlink refusal (skipped: this platform cannot create one)" PASS
fi

# --- F18/F19 file-fed bytes face the same run-binding checks as inline text ---
NOMARKER_FILE="$TMP/no-marker-plan.md"
printf '# A plan with no autopilot marker at all\n' > "$NOMARKER_FILE"
refuses_with "F18 a marker-free plan FILE still reports PLAN_MARKER_MISSING_OR_AMBIGUOUS" \
  PLAN_MARKER_MISSING_OR_AMBIGUOUS \
  "$(invoke "$(payload refuse_session __ABSENT__ "$NOMARKER_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

FOREIGN_MARKER_FILE="$TMP/foreign-marker-plan.md"
printf '# Someone else run\n\n<!-- zensu-autopilot:a_foreign_run -->\n' > "$FOREIGN_MARKER_FILE"
refuses_with "F19 a plan FILE naming a foreign run reports PLAN_MARKER_RUN_MISMATCH" \
  PLAN_MARKER_RUN_MISMATCH \
  "$(invoke "$(payload refuse_session __ABSENT__ "$FOREIGN_MARKER_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F21 a present-but-non-string plan must not silently reach the fallback.
# It gets its own code: reporting "carried neither plan text nor a plan file
# path" would be a lie, because this payload carries a perfectly good path.
refuses_with "F21 a non-string tool_input.plan blocks instead of falling back to the file" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$(payload_nonstring_plan refuse_session "$PLAN_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

F21B_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{planFilePath:["not","a","string"]}
  }));
')"
refuses_with "F21a a non-string planFilePath is a field-type refusal, not a missing payload" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$F21B_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F20 authorization is decided before the payload's path is touched.
# A foreign session naming an existing readable file must still be refused for
# ownership, so the hook is not an existence oracle for unauthorized callers.
provision_session "$REFUSE_PROJECT" foreign_plan_session foreign || { echo "F20 fixture failed" >&2; exit 1; }
OUT20="$(invoke "$(payload foreign_plan_session __ABSENT__ "$PLAN_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$PROVISIONED_DATA")"
if printf '%s' "$OUT20" | grep -qF 'code=OWNER_SESSION_MISMATCH' \
  && [ "$(digest "$REFUSE_RUN_FILE")" = "$REFUSE_BEFORE" ]; then
  check "F20 a foreign session is refused on ownership, before the path is read" PASS
else
  check "F20 foreign session (out='$(printf '%s' "$OUT20" | head -c 200)')" FAIL
fi
OUT20B="$(invoke "$(payload foreign_plan_session __ABSENT__ "$TMP/no-such-plan.md")" "$REFUSE_PROJECT" "$CFG_OFF" "$PROVISIONED_DATA")"
if [ "$OUT20B" = "$OUT20" ]; then
  check "F20a an unauthorized caller learns nothing about whether the path exists" PASS
else
  check "F20a receipt differs by path existence for an unauthorized caller" FAIL
fi

# --- F10 every code this hook can emit carries prose naming its cause ---
CAUSE_KEYS="$(node -e '
  const src=require("fs").readFileSync(process.argv[1],"utf8");
  const block=src.slice(src.indexOf("const causes={"),src.indexOf("};",src.indexOf("const causes={")));
  const keys=[...block.matchAll(/^\s{6}([A-Z_]+):/gm)].map(m=>m[1]);
  process.stdout.write(keys.sort().join(" "));
' "$HOOK")"
EMITTED_CODES="$(node -e '
  const src=require("fs").readFileSync(process.argv[1],"utf8");
  const codes=new Set([...src.matchAll(/BLOCK_CODE=([A-Z_]+)/g)].map(m=>m[1]));
  for (const m of src.matchAll(/emit_autopilot_blocked ([A-Z_]+)/g)) codes.add(m[1]);
  process.stdout.write([...codes].sort().join(" "));
' "$HOOK")"
MISSING_CAUSE=""
for code in $EMITTED_CODES; do
  case " $CAUSE_KEYS " in *" $code "*) ;; *) MISSING_CAUSE="$MISSING_CAUSE $code" ;; esac
done
if [ -z "$MISSING_CAUSE" ]; then
  check "F10 every emitted block code has cause prose in the causes map" PASS
else
  check "F10 codes emitted with no cause prose:$MISSING_CAUSE" FAIL
fi

# --- F11 the codes no fixture can provoke are still wired ---
if grep -Eq 'catch \(_\) \{ process\.exit\(9\); \}' "$HOOK" \
  && grep -Eq '9\)[[:space:]]*BLOCK_CODE=PLAN_PAYLOAD_EVALUATION_FAILED' "$HOOK" \
  && grep -Eq '\*\)[[:space:]]*BLOCK_CODE=PLAN_EVALUATION_UNAVAILABLE' "$HOOK" \
  && grep -Eq '3\)[[:space:]]*BLOCK_CODE=INVALID_PLAN_PAYLOAD' "$HOOK"; then
  check "F11 the throw and no-verdict paths map to their own block codes" PASS
else
  check "F11 exception and no-verdict codes are not distinctly wired" FAIL
fi

# The plan is only ever read from the payload — never guessed by scanning a
# plans directory, which would race concurrent sessions onto the wrong digest.
if ! grep -Eq 'zensu/plans|claude/plans|plans/\*|readdirSync|opendirSync|globSync' "$HOOK"; then
  check "F11a the hook never scans a plans directory to guess the plan" PASS
else
  check "F11a the hook scans a plans directory" FAIL
fi

# --- F12 outside Autopilot the payload shape must not change the routing ---
STANDALONE_PROJECT="$TMP/standalone"
mkdir -p "$STANDALONE_PROJECT"
provision_session "$STANDALONE_PROJECT" standalone_session standalone \
  || { echo "F12 fixture failed" >&2; exit 1; }
OUT12_PATH="$(invoke "$(payload standalone_session __ABSENT__ "$PLAN_FILE")" \
  "$STANDALONE_PROJECT" "$CFG_ON" "$PROVISIONED_DATA")"
OUT12_NONE="$(invoke "$(payload standalone_session __ABSENT__ __ABSENT__)" \
  "$STANDALONE_PROJECT" "$CFG_ON" "$PROVISIONED_DATA")"
if printf '%s' "$OUT12_PATH" | grep -qF 'AskUserQuestion' \
  && ! printf '%s' "$OUT12_PATH" | grep -qF 'PLAN_GATE_BLOCKED' \
  && [ "$OUT12_PATH" = "$OUT12_NONE" ]; then
  check "F12 outside Autopilot the routing is identical regardless of payload shape" PASS
else
  check "F12 standalone fall-through changed" FAIL
fi

echo "----"
echo "test-plan-payload-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
