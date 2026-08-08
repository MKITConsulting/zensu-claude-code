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
#   F21 non-string plan              -> PLAN_PAYLOAD_FIELD_TYPE_REJECTED, no fallback
#   F22 multi-byte UTF-8 plan file   -> digest still equals the file bytes
#   F23 invalid-UTF-8 plan file      -> digest is the raw bytes, not a re-encoding
#   F24 tool_response.plan only      -> approves, digest over the response text
#   F25 tool_response.filePath only  -> approves, digest over the file bytes
#   F26 response plan vs input plan  -> response wins
#   F27 response path vs input plan  -> response path wins
#   F28 response plan, no marker     -> PLAN_MARKER_MISSING_OR_AMBIGUOUS
#   F29 response plan, foreign run   -> PLAN_MARKER_RUN_MISMATCH
#   F30 non-string response plan     -> PLAN_PAYLOAD_FIELD_TYPE_REJECTED
#   F31 non-string response filePath -> PLAN_PAYLOAD_FIELD_TYPE_REJECTED
#   F32 foreign session + response   -> OWNER_SESSION_MISMATCH, file untouched
#   F33/F33a/F33b replays of the REAL captured payload -> marker check, approval,
#                                      and approval through the captured filePath
#   F34 response without either field-> INVALID_PLAN_PAYLOAD
#   F35/F35a non-object tool_response-> PLAN_RESPONSE_SHAPE_REJECTED (drift)
#   F35b null tool_response          -> INVALID_PLAN_PAYLOAD (absence, not drift)
#   F36 empty response plan string   -> falls back to the response file path
#   F37-F43 hostile tool_response.filePath -> the SAME lattice as F5/F6/F7/F13/F15/F16/F17
#   F44 invalid-UTF-8 response file  -> digest still equals the raw file bytes
#   F45 missing losing path          -> never opened
#   F45a readable, differing losing path -> never wins
#   F10 every emitted block code     -> has cause prose in the causes map
#   F10a every module refusal code   -> has a case arm AND cause prose
#   F11 throw and no-verdict paths   -> map to their own block codes
#   F11a neither hook nor module     -> ever scans a plans directory
#   F12 outside Autopilot            -> routing is payload-shape independent
#   F46 marker only on the loser     -> refused; precedence is authorization
#   F47 wrong tool_name / F47a absent tool_name -> the gate is unreachable;
#       F47b the same payload with the right tool_name -> approves (positive control)
#   F48 unreadable response path     -> hard block, never a silent fallback
#   F49/F50 absent or non-object tool_input -> absence, not drift
#   F51 tool_response.isAgent true   -> PLAN_RESPONSE_AGENT_ORIGIN_REJECTED
#   F51a non-boolean isAgent         -> PLAN_RESPONSE_ORIGIN_TYPE_REJECTED
#   F51b agent origin + unreadable path -> the ORIGIN refusal, proving 17 still
#                                       precedes the source loop
#   F51c non-boolean isAgent + unreadable path -> the same for 19
#   F11b/F11c in-evaluator tool binding -> PLAN_TOOL_BINDING_MISMATCH, and it
#                                      precedes every shape and origin refusal
#   F11d evaluator stage refusal     -> stays wired to PLAN_STAGE_MISMATCH
#   F52 empty response tier          -> still descends to the legacy sources
#   F53 two markers, one of them ours-> PLAN_MARKER_MISSING_OR_AMBIGUOUS
#   F54/F54a hard-linked plan file   -> PLAN_FILE_SYMLINK_REJECTED, both containers
#   F55 run past the planning stages -> PLAN_STAGE_MISMATCH
#   F56 hooks/lib/plan-payload-v1.js -> its own node --test unit suite passes
#   F57 the reader module            -> preflighted, and transported through the
#                                       environment rather than through argv
#   F58/F58a a plugin without the module refuses the gate; the same copy
#       approves once the module is restored, so F58 cannot pass by accident
#
# Sub-lettered cases (F2a, F10a, F11a/b/c/d, F20a, F21a, F33a/b, F35a/b, F45a,
# F47a/b, F51a/b/c, F54a, F58a) are variants of the row above them. F0 is the
# hook parse preflight and F0a the fixture-shape preflight.
#
# The reader itself now lives in hooks/lib/plan-payload-v1.js. The cases that
# assert the MODULE's contract scan both files (F10a, F11, F11a, F11c); the ones
# that assert the hook ENVELOPE still scan the hook alone (F10, F11b, F11d, F57).
# The split is the same one the code makes: the hook owns ownership, stage, tool
# binding, caller origin, the run marker and the single numeric-to-BLOCK_CODE
# case table, while the module owns the source table, the field typing, and the
# hardened plan-file read.
#
# F18/F19 matter because they prove file-fed bytes face the same run-binding
# checks as inline text. F20 pins that authorization is decided BEFORE the
# payload's path is touched at all, so an unauthorized payload can neither
# make the hook open an arbitrary path nor learn whether it exists.
# Every refusal is checked to leave the run record byte-identical. The
# additional "no standalone ask-first directive" assertion belongs to the
# refuses_with helper; the cases that carry their own oracle (F20, F32, F33,
# F46, F51, F51a, F51b, F51c) do not assert it — several of them assert MORE
# than the code and the run record instead (F33 an absence, F51/F51a receipt
# prose, F51b/F51c the absence of PLAN_FILE_UNREADABLE) — while F55 and F58
# assert the directive explicitly. F20a is narrower still: its whole oracle is
# byte-equality with F20's receipt, so it inherits F20's code assertion and does
# not re-check the run record itself.
#
# F24-F51 exist because the harness stopped populating tool_input for
# ExitPlanMode: the approved plan now arrives as tool_response.plan, with
# tool_response.filePath naming the same bytes on disk. F33 replays the
# captured real payload (tests/structure/fixtures/) so the suite pins the
# measured contract rather than a guess about it.
#
# Source precedence is tool_response.plan -> tool_response.filePath ->
# tool_input.plan -> tool_input.planFilePath. The harness-produced response
# outranks tool_input because the winning source feeds the run-marker match as
# well as the digest, so precedence decides which run the gate opens (F46).
# Within the response the transported STRING outranks the file: the string is
# the value delivered with the approval event, while the file is read strictly
# later, in a PostToolUse hook, where it is exposed to any post-approval change
# and where every read failure is a hard block (F48).
#
# Two things the capture did NOT establish, recorded so the rationale is not
# read as more than it is. The captured response carries no field naming the
# user's decision, and no declined-plan payload was ever captured, so "the
# approved plan" rests on the premise that this PostToolUse does not fire for a
# declined plan. And `isAgent` was only ever observed as false, on the main
# thread; the hook nevertheless REFUSES a response declaring `isAgent === true`
# (F51) and refuses a non-boolean `isAgent` as origin-type drift with its own
# receipt (F51a), so a renamed or missing field changes nothing while a positive
# agent claim, or an unreadable one, fails closed.
#
# The two containers are deliberately NOT symmetric: a present-but-non-object
# tool_response is drift (F35/F35a), while a non-object or absent tool_input is
# treated as plain absence (F49/F50). Blocking on tool_input's shape would
# refuse a payload whose plan arrived intact in the response, which is a new way
# to wedge the one gate this whole change exists to unwedge.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/plan-approved-delegate.sh"
MODULE="$PLUGIN_DIR/hooks/lib/plan-payload-v1.js"
MODULE_TEST="$PLUGIN_DIR/tests/structure/plan-payload-v1.test.js"
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

MSYS_EXCL="PLAN_PATH;RESPONSE_PATH"
[ -z "${MSYS2_ENV_CONV_EXCL:-}" ] || MSYS_EXCL="${MSYS2_ENV_CONV_EXCL};PLAN_PATH;RESPONSE_PATH"

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

# The measured harness payload: tool_input carries only an internal mode flag,
# and the approved plan rides in tool_response.
# $1 raw session id, $2..$5 tool_input.plan, tool_input.planFilePath,
# tool_response.plan, tool_response.filePath — each text or __ABSENT__
payload_mixed() {
  MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID="$1" PLAN="$2" PLAN_PATH="$3" \
    RESPONSE_PLAN="$4" RESPONSE_PATH="$5" node -e '
    const ti={_targetMode:"auto"};
    if (process.env.PLAN!=="__ABSENT__") ti.plan=process.env.PLAN;
    if (process.env.PLAN_PATH!=="__ABSENT__") ti.planFilePath=process.env.PLAN_PATH;
    const tr={isAgent:false, hasTaskTool:true};
    if (process.env.RESPONSE_PLAN!=="__ABSENT__") tr.plan=process.env.RESPONSE_PLAN;
    if (process.env.RESPONSE_PATH!=="__ABSENT__") tr.filePath=process.env.RESPONSE_PATH;
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode", tool_input:ti, tool_response:tr
    }));
  '
}

# $1 raw session id, $2 tool_response.plan or __ABSENT__, $3 tool_response.filePath or __ABSENT__
payload_response() {
  payload_mixed "$1" __ABSENT__ __ABSENT__ "$2" "$3"
}

# Replays the committed capture of a real PostToolUse:ExitPlanMode payload, so
# the key set under test is the measured one and not a hand-written guess.
# The abort here is only a stderr note on purpose: every call site runs this in
# a command substitution, where an exit would end the subshell and not the
# suite. An unreadable fixture already fails loudly at F0a, and an empty payload
# makes the replays fail rather than pass.
# $1 raw session id, $2 replacement plan text or __KEEP__,
# $3 replacement filePath or __KEEP__ (optional)
FIXTURE_PAYLOAD_FILE="$PLUGIN_DIR/tests/structure/fixtures/exitplanmode-posttooluse-payload.json"
payload_fixture() {
  MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" FIXTURE="$FIXTURE_PAYLOAD_FILE" SID="$1" \
    RESPONSE_PLAN="$2" RESPONSE_PATH="${3:-__KEEP__}" node -e '
    const fs=require("fs");
    const j=JSON.parse(fs.readFileSync(process.env.FIXTURE,"utf8"));
    delete j._fixture;
    j.session_id=process.env.SID;
    if (process.env.RESPONSE_PLAN!=="__KEEP__") j.tool_response.plan=process.env.RESPONSE_PLAN;
    if (process.env.RESPONSE_PATH!=="__KEEP__") j.tool_response.filePath=process.env.RESPONSE_PATH;
    process.stdout.write(JSON.stringify(j));
  ' || echo "fixture payload unreadable: $FIXTURE_PAYLOAD_FILE" >&2
}

# The fixture is the repo's only record of the measured contract, so its shape
# is asserted rather than assumed: a later edit that quietly adds a tool_input
# plan field would make F33 pass for the wrong reason.
FIXTURE_SHAPE="$(FIXTURE="$FIXTURE_PAYLOAD_FILE" node -e '
  try {
    const j=JSON.parse(require("fs").readFileSync(process.env.FIXTURE,"utf8"));
    const ti=j.tool_input, tr=j.tool_response;
    const isPlainObject=(v)=>!!v && typeof v==="object" && !Array.isArray(v);
    const ok = j.tool_name==="ExitPlanMode" && j.hook_event_name==="PostToolUse"
      && isPlainObject(ti) && ti.plan===undefined && ti.planFilePath===undefined
      && isPlainObject(tr)
      && typeof tr.plan==="string" && tr.plan.length>0
      && typeof tr.filePath==="string" && tr.filePath.length>0
      && tr.isAgent===false;
    process.stdout.write(ok?"ok":"shape-mismatch");
  } catch (_) { process.stdout.write("unreadable"); }
')"
if [ "$FIXTURE_SHAPE" = ok ]; then
  check "F0a the captured fixture still carries the measured key set" PASS
else
  check "F0a captured fixture shape ($FIXTURE_SHAPE)" FAIL
fi

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
printf '# Caf\xc3\xa9 plan \xe2\x80\x94 na\xc3\xafve \xf0\x9f\x9a\x80\n\n<!-- zensu-autopilot:utf8_run -->\n' > "$UTF8_FILE"
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

# --- F24 the current harness shape: nothing in tool_input, plan in the response ---
arm_run responseplan responseplan_session responseplan_run || { echo "F24 fixture failed" >&2; exit 1; }
RESPONSE_PLAN="# Plan from the response

Implement it.

<!-- zensu-autopilot:responseplan_run -->"
OUT24="$(invoke "$(payload_response responseplan_session "$RESPONSE_PLAN" __ABSENT__)" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
RESPONSE_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT24" | grep -qF 'PLAN_APPROVED' \
  && [ "$RESPONSE_SHA_ACTUAL" = "$(text_sha "$RESPONSE_PLAN")" ]; then
  check "F24 a tool_response.plan approves and digests the response text" PASS
else
  check "F24 response plan (sha=$RESPONSE_SHA_ACTUAL out='$(printf '%s' "$OUT24" | head -c 160)')" FAIL
fi

# --- F25 the response names the plan file instead of carrying the bytes ---
arm_run responsepath responsepath_session responsepath_run || { echo "F25 fixture failed" >&2; exit 1; }
RESPONSE_FILE="$TMP/responsepath-plan.md"
printf '# Plan named by the response\n\n<!-- zensu-autopilot:responsepath_run -->\n' > "$RESPONSE_FILE"
OUT25="$(invoke "$(payload_response responsepath_session __ABSENT__ "$RESPONSE_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT25" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$RESPONSE_FILE")" ]; then
  check "F25 a tool_response.filePath approves and digests the file bytes" PASS
else
  check "F25 response path (out='$(printf '%s' "$OUT25" | head -c 160)')" FAIL
fi

# --- F26/F27 precedence: the harness-produced tool_response outranks
# tool_input. The winning source decides more than the recorded digest — the
# same string feeds the run-marker match, so precedence is an authorization
# decision. tool_input survives only as the legacy source for harness versions
# that populated it; on the measured contract it carries no plan at all.
# The decoy names a FOREIGN run, so preferring it would surface as a
# PLAN_MARKER_RUN_MISMATCH rather than as a silently different digest.
FOREIGN_MARKER_PLAN="# Decoy

<!-- zensu-autopilot:a_foreign_run -->"

arm_run responsewins responsewins_session responsewins_run || { echo "F26 fixture failed" >&2; exit 1; }
RESPONSE_WINS_PLAN="# Response plan wins

<!-- zensu-autopilot:responsewins_run -->"
OUT26="$(invoke "$(payload_mixed responsewins_session "$FOREIGN_MARKER_PLAN" __ABSENT__ "$RESPONSE_WINS_PLAN" __ABSENT__)" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT26" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$RESPONSE_WINS_PLAN")" ]; then
  check "F26 tool_response.plan outranks tool_input.plan" PASS
else
  check "F26 precedence (out='$(printf '%s' "$OUT26" | head -c 160)')" FAIL
fi

arm_run respathwins respathwins_session respathwins_run || { echo "F27 fixture failed" >&2; exit 1; }
RESPONSE_WINS_FILE="$TMP/respathwins-plan.md"
printf '# Response path wins\n\n<!-- zensu-autopilot:respathwins_run -->\n' > "$RESPONSE_WINS_FILE"
OUT27="$(invoke "$(payload_mixed respathwins_session "$FOREIGN_MARKER_PLAN" __ABSENT__ __ABSENT__ "$RESPONSE_WINS_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT27" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$RESPONSE_WINS_FILE")" ]; then
  check "F27 tool_response.filePath outranks tool_input.plan" PASS
else
  check "F27 precedence (out='$(printf '%s' "$OUT27" | head -c 160)')" FAIL
fi

# --- F45 the losing source is never opened. The decoy path does not exist, so
# any implementation that reads before it decides would block instead.
arm_run neveropened neveropened_session neveropened_run || { echo "F45 fixture failed" >&2; exit 1; }
NEVEROPENED_PLAN="# Response text wins outright

<!-- zensu-autopilot:neveropened_run -->"
OUT45="$(invoke "$(payload_mixed neveropened_session __ABSENT__ "$TMP/decoy-input-never-created.md" \
  "$NEVEROPENED_PLAN" "$TMP/decoy-response-never-created.md")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT45" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$NEVEROPENED_PLAN")" ]; then
  check "F45 a winning tool_response.plan leaves both losing paths unopened" PASS
else
  check "F45 losing paths were touched (out='$(printf '%s' "$OUT45" | head -c 160)')" FAIL
fi

# F45 alone only refutes a reader that HARD-fails on the losing path; one that
# reads opportunistically and ignores failures would still pass it. F45a closes
# that: the losing path is READABLE and carries different bytes with a foreign
# marker, so preferring it is visible either as a different digest or as a
# PLAN_MARKER_RUN_MISMATCH.
arm_run readabledecoy readabledecoy_session readabledecoy_run || { echo "F45a fixture failed" >&2; exit 1; }
READABLE_DECOY_FILE="$TMP/readable-decoy-plan.md"
printf '# Readable decoy that must lose\n\n<!-- zensu-autopilot:a_foreign_run -->\n' > "$READABLE_DECOY_FILE"
READABLE_DECOY_PLAN="# Response text still wins

<!-- zensu-autopilot:readabledecoy_run -->"
OUT45A="$(invoke "$(payload_response readabledecoy_session "$READABLE_DECOY_PLAN" "$READABLE_DECOY_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT45A" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$READABLE_DECOY_PLAN")" ]; then
  check "F45a a readable, differing tool_response.filePath still loses to the response text" PASS
else
  check "F45a readable decoy (out='$(printf '%s' "$OUT45A" | head -c 160)')" FAIL
fi

# --- F46 precedence decides AUTHORIZATION, not just the digest: when only the
# LOSING source carries the active run marker, the gate must refuse.
arm_run markerloser markerloser_session markerloser_run || { echo "F46 fixture failed" >&2; exit 1; }
MARKERLOSER_BEFORE="$(digest "$ARMED_RUN_FILE")"
OUT46="$(invoke "$(payload_mixed markerloser_session '# Only the loser is bound

<!-- zensu-autopilot:markerloser_run -->' __ABSENT__ "$FOREIGN_MARKER_PLAN" __ABSENT__)" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT46" | grep -qF 'code=PLAN_MARKER_RUN_MISMATCH' \
  && [ "$(digest "$ARMED_RUN_FILE")" = "$MARKERLOSER_BEFORE" ]; then
  check "F46 a marker on the losing source cannot open the gate" PASS
else
  check "F46 marker selection (out='$(printf '%s' "$OUT46" | head -c 160)')" FAIL
fi

# --- F47 the tool binding is re-verified inside the payload, not left to the
# hooks.json matcher: tool_response.filePath is a field name other tools use.
arm_run wrongtool wrongtool_session wrongtool_run || { echo "F47 fixture failed" >&2; exit 1; }
WRONGTOOL_FILE="$TMP/wrongtool-plan.md"
printf '# Not an approved plan\n\n<!-- zensu-autopilot:wrongtool_run -->\n' > "$WRONGTOOL_FILE"
WRONGTOOL_BEFORE="$(digest "$ARMED_RUN_FILE")"
WRONGTOOL_PAYLOAD="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=wrongtool_session RESPONSE_PATH="$WRONGTOOL_FILE" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"Write", tool_input:{},
    tool_response:{filePath:process.env.RESPONSE_PATH}
  }));
')"
OUT47="$(invoke "$WRONGTOOL_PAYLOAD" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if [ -z "$OUT47" ] && [ "$(digest "$ARMED_RUN_FILE")" = "$WRONGTOOL_BEFORE" ]; then
  check "F47 a non-ExitPlanMode payload cannot reach the plan gate" PASS
else
  check "F47 wrong tool_name reached the gate (out='$(printf '%s' "$OUT47" | head -c 160)')" FAIL
fi

# An absent tool_name must fail the same way. The guard is tri-state: a payload
# that PARSED and named another tool, or no tool, yields "mismatch" and exits 0,
# while an empty verdict means the verdict could not be computed at all and
# falls through to the fail-closed runtime path. Restoring a plain equality
# compare here would turn that fall-through back into silence, which is the
# regression P12/P12b in test-autopilot-plan-delegate.sh catches.
NOTOOL_PAYLOAD="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=wrongtool_session RESPONSE_PATH="$WRONGTOOL_FILE" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_input:{}, tool_response:{filePath:process.env.RESPONSE_PATH}
  }));
')"
OUT47A="$(invoke "$NOTOOL_PAYLOAD" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if [ -z "$OUT47A" ] && [ "$(digest "$ARMED_RUN_FILE")" = "$WRONGTOOL_BEFORE" ]; then
  check "F47a a payload with no tool_name at all cannot reach the plan gate" PASS
else
  check "F47a absent tool_name reached the gate (out='$(printf '%s' "$OUT47A" | head -c 160)')" FAIL
fi

# Positive control: silence only proves the guard if the SAME payload approves
# once its tool_name is right. Without this, any unrelated early exit would
# keep F47/F47a green.
WRONGTOOL_CONTROL="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=wrongtool_session RESPONSE_PATH="$WRONGTOOL_FILE" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{},
    tool_response:{filePath:process.env.RESPONSE_PATH}
  }));
')"
OUT47B="$(invoke "$WRONGTOOL_CONTROL" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT47B" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$WRONGTOOL_FILE")" ]; then
  check "F47b the same payload with tool_name=ExitPlanMode does approve" PASS
else
  check "F47b positive control (out='$(printf '%s' "$OUT47B" | head -c 160)')" FAIL
fi

# --- F51 a response that declares an agent origin is refused outright. The
# test is strict === true, so a missing or renamed field changes nothing; this
# is a positive origin assertion on top of the absence-based principal check.
arm_run agentorigin agentorigin_session agentorigin_run || { echo "F51 fixture failed" >&2; exit 1; }
AGENT_ORIGIN_BEFORE="$(digest "$ARMED_RUN_FILE")"
AGENT_ORIGIN_PAYLOAD="$(SID=agentorigin_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{plan:"# Agent-authored\n\n<!-- zensu-autopilot:agentorigin_run -->\n",
      isAgent:true, hasTaskTool:true}
  }));
')"
OUT51="$(invoke "$AGENT_ORIGIN_PAYLOAD" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT51" | grep -qF 'code=PLAN_RESPONSE_AGENT_ORIGIN_REJECTED' \
  && printf '%s' "$OUT51" | grep -qF 'declares an agent origin' \
  && [ "$(digest "$ARMED_RUN_FILE")" = "$AGENT_ORIGIN_BEFORE" ]; then
  check "F51 a tool_response declaring an agent origin cannot approve a run" PASS
else
  check "F51 agent-origin response (out='$(printf '%s' "$OUT51" | head -c 160)')" FAIL
fi

# A non-boolean origin field is drift, not a human caller.
AGENT_ORIGIN_DRIFT="$(SID=agentorigin_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{plan:"# Drifted origin field\n\n<!-- zensu-autopilot:agentorigin_run -->\n",
      isAgent:"true", hasTaskTool:true}
  }));
')"
OUT51A="$(invoke "$AGENT_ORIGIN_DRIFT" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT51A" | grep -qF 'code=PLAN_RESPONSE_ORIGIN_TYPE_REJECTED' \
  && printf '%s' "$OUT51A" | grep -qF 'isAgent field that is not a boolean' \
  && [ "$(digest "$ARMED_RUN_FILE")" = "$AGENT_ORIGIN_BEFORE" ]; then
  check "F51a a non-boolean isAgent gets its own receipt, not the shape one" PASS
else
  check "F51a origin field drift (out='$(printf '%s' "$OUT51A" | head -c 160)')" FAIL
fi

# F51/F51a both carry a readable plan string, so neither can tell whether the
# origin check still runs BEFORE the source loop. This one can: its only plan
# source is a path that cannot be read, so the source loop would answer
# PLAN_FILE_UNREADABLE while the origin check answers its own code. That makes
# the receipt the oracle for the last leg of the 18 -> 16 -> {19, 17} -> sources
# order. F11c pins that same leg textually; this case proves it behaviorally.
AGENT_ORIGIN_UNREADABLE="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=agentorigin_session \
  RESPONSE_PATH="$TMP/agent-origin-never-read.md" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{filePath:process.env.RESPONSE_PATH, isAgent:true, hasTaskTool:true}
  }));
')"
OUT51B="$(invoke "$AGENT_ORIGIN_UNREADABLE" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT51B" | grep -qF 'code=PLAN_RESPONSE_AGENT_ORIGIN_REJECTED' \
  && ! printf '%s' "$OUT51B" | grep -qF 'PLAN_FILE_UNREADABLE' \
  && [ "$(digest "$ARMED_RUN_FILE")" = "$AGENT_ORIGIN_BEFORE" ]; then
  check "F51b the origin refusal precedes the source loop, not just the shape check" PASS
else
  check "F51b origin before sources (out='$(printf '%s' "$OUT51B" | head -c 160)')" FAIL
fi

# F51b covers exit 17 only. The origin-TYPE refusal is a separate statement and
# could be relocated below the source loop on its own, so it gets its own oracle.
ORIGIN_TYPE_UNREADABLE="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=agentorigin_session \
  RESPONSE_PATH="$TMP/origin-type-never-read.md" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{filePath:process.env.RESPONSE_PATH, isAgent:"true", hasTaskTool:true}
  }));
')"
OUT51C="$(invoke "$ORIGIN_TYPE_UNREADABLE" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT51C" | grep -qF 'code=PLAN_RESPONSE_ORIGIN_TYPE_REJECTED' \
  && ! printf '%s' "$OUT51C" | grep -qF 'PLAN_FILE_UNREADABLE' \
  && [ "$(digest "$ARMED_RUN_FILE")" = "$AGENT_ORIGIN_BEFORE" ]; then
  check "F51c the origin-type refusal also precedes the source loop" PASS
else
  check "F51c origin type before sources (out='$(printf '%s' "$OUT51C" | head -c 160)')" FAIL
fi

# --- F36 an empty response plan is absent, not a block: the response path is
# the next source, exactly as F8 pins for the tool_input pair.
arm_run emptyresponse emptyresponse_session emptyresponse_run || { echo "F36 fixture failed" >&2; exit 1; }
EMPTY_RESPONSE_FILE="$TMP/emptyresponse-plan.md"
printf '# Response fallback used\n\n<!-- zensu-autopilot:emptyresponse_run -->\n' > "$EMPTY_RESPONSE_FILE"
OUT36="$(invoke "$(payload_response emptyresponse_session "" "$EMPTY_RESPONSE_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT36" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$EMPTY_RESPONSE_FILE")" ]; then
  check "F36 an empty tool_response.plan falls back to tool_response.filePath" PASS
else
  check "F36 empty response plan did not fall back (out='$(printf '%s' "$OUT36" | head -c 160)')" FAIL
fi

# --- F44 the response path digests raw bytes too. F23 pins this for the
# tool_input path; without the analog, dropping the buffer on the response
# branch would re-encode invalid UTF-8 to U+FFFD and silently change the digest.
arm_run responseraw responseraw_session responseraw_run || { echo "F44 fixture failed" >&2; exit 1; }
RESPONSE_RAW_FILE="$TMP/response-raw-bytes-plan.md"
node -e '
  const fs=require("fs");
  fs.writeFileSync(process.argv[1],Buffer.concat([
    Buffer.from("# Latin-1 byte: "),
    Buffer.from([0xff, 0xfe]),
    Buffer.from("\n\n<!-- zensu-autopilot:responseraw_run -->\n")
  ]));
' "$RESPONSE_RAW_FILE"
OUT44="$(invoke "$(payload_response responseraw_session __ABSENT__ "$RESPONSE_RAW_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
RESPONSE_RAW_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT44" | grep -qF 'PLAN_APPROVED' \
  && [ "$RESPONSE_RAW_ACTUAL" = "$(file_sha "$RESPONSE_RAW_FILE")" ]; then
  check "F44 an invalid-UTF-8 response plan file digests to its raw bytes" PASS
else
  check "F44 response raw-byte digest (got=$RESPONSE_RAW_ACTUAL want=$(file_sha "$RESPONSE_RAW_FILE"))" FAIL
fi

# --- Every refusal shares one run: none of them may mutate it by a single byte ---
arm_run refuse refuse_session refuse_run || { echo "refuse fixture failed" >&2; exit 1; }
REFUSE_PROJECT="$ARMED_PROJECT"
REFUSE_DATA="$ARMED_DATA"
REFUSE_RUN_FILE="$ARMED_RUN_FILE"
REFUSE_BEFORE="$(digest "$REFUSE_RUN_FILE")"

# A refusal must name its code, leave the run record byte-identical, and never
# fall through to the standalone ask-first directive. The optional fourth
# argument pins a fragment of the cause prose: the code alone cannot detect a
# receipt whose text still names only the source it used to have.
refuses_with() {
  local label="$1" code="$2" out="$3" prose="${4:-}"
  if printf '%s' "$out" | grep -qF "code=$code" \
    && { [ -z "$prose" ] || printf '%s' "$out" | grep -qF "$prose"; } \
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
  "$(invoke "$(payload refuse_session __ABSENT__ "$TMP/no-such-plan.md")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'named a plan file path, but opening or reading it failed'

DIR_PATH="$TMP/plan-as-directory"
mkdir -p "$DIR_PATH"
refuses_with "F6 a directory at planFilePath reports PLAN_FILE_NOT_REGULAR" \
  PLAN_FILE_NOT_REGULAR \
  "$(invoke "$(payload refuse_session __ABSENT__ "$DIR_PATH")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'does not name a regular file'

EMPTY_FILE="$TMP/empty-plan.md"
: > "$EMPTY_FILE"
refuses_with "F7 an empty plan file reports PLAN_FILE_EMPTY, not a generic failure" \
  PLAN_FILE_EMPTY \
  "$(invoke "$(payload refuse_session __ABSENT__ "$EMPTY_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'exists but is empty, so there is no plan to approve'

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

# --- F28/F29 response-fed bytes face the same run binding as every other source ---
refuses_with "F28 a marker-free tool_response.plan reports PLAN_MARKER_MISSING_OR_AMBIGUOUS" \
  PLAN_MARKER_MISSING_OR_AMBIGUOUS \
  "$(invoke "$(payload_response refuse_session '# A response plan with no autopilot marker' __ABSENT__)" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F29 a tool_response.plan naming a foreign run reports PLAN_MARKER_RUN_MISMATCH" \
  PLAN_MARKER_RUN_MISMATCH \
  "$(invoke "$(payload_response refuse_session "$FOREIGN_MARKER_PLAN" __ABSENT__)" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F30/F31 a present-but-wrongly-typed response field is a type refusal, the
# same way F21/F21a pin it for tool_input. A silent fall-through would let a
# malformed field masquerade as an absent one.
F30_PAYLOAD="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=refuse_session PLAN_PATH="$PLAN_FILE" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{plan:{unexpected:"object"}, filePath:process.env.PLAN_PATH,
      isAgent:false, hasTaskTool:true}
  }));
')"
refuses_with "F30 a non-string tool_response.plan blocks instead of falling back to the file" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$F30_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'The payload or its tool response carries a plan'

F31_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{filePath:["not","a","string"], isAgent:false, hasTaskTool:true}
  }));
')"
refuses_with "F31 a non-string tool_response.filePath is a field-type refusal, not a missing payload" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$F31_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'The payload or its tool response carries a plan'

# --- F34/F35 a response that carries no plan at all is still a missing payload,
# but a response of the wrong SHAPE is contract drift and gets its own code:
# folding it into "there was no plan" is exactly the diagnostic blindness that
# hid the harness change this whole source exists to answer.
refuses_with "F34 a tool_response without plan or filePath blocks as INVALID_PLAN_PAYLOAD" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$(payload_response refuse_session __ABSENT__ __ABSENT__)" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'Neither the ExitPlanMode payload nor its tool response'

F35_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:"User has approved your plan."
  }));
')"
refuses_with "F35 a non-object tool_response is contract drift, not an empty payload" \
  PLAN_RESPONSE_SHAPE_REJECTED \
  "$(invoke "$F35_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'is present but is not an object'

F35A_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:["not","an","object"]
  }));
')"
refuses_with "F35a an array tool_response is the same contract drift as a string" \
  PLAN_RESPONSE_SHAPE_REJECTED \
  "$(invoke "$F35A_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# JSON null is an explicit absence, not a shape the hook failed to recognise.
F35B_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:null
  }));
')"
refuses_with "F35b a null tool_response is absent, not drift" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$F35B_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F53 the AMBIGUOUS half of PLAN_MARKER_MISSING_OR_AMBIGUOUS. A plan naming
# the active run AND another one must not open the gate on the first match:
# marker selection is authorization, so "one marker exactly" is the rule.
refuses_with "F53 a plan carrying two markers is ambiguous, even when one is the active run" \
  PLAN_MARKER_MISSING_OR_AMBIGUOUS \
  "$(invoke "$(payload_response refuse_session '# Two runs claimed

<!-- zensu-autopilot:refuse_run -->

<!-- zensu-autopilot:a_foreign_run -->' __ABSENT__)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'or more than one, so no single run could be named'

# --- F54 a hard link is refused like a symlink. O_NOFOLLOW does not see one, so
# the nlink check is the only guard the receipt prose promises.
HARDLINK_PATH="$TMP/hardlinked-plan.md"
if ln "$LINK_TARGET" "$HARDLINK_PATH" 2>/dev/null && [ -f "$HARDLINK_PATH" ]; then
  refuses_with "F54 a multiply-linked tool_input.planFilePath is refused" \
    PLAN_FILE_SYMLINK_REJECTED \
    "$(invoke "$(payload refuse_session __ABSENT__ "$HARDLINK_PATH")" \
      "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
    'or a multiply-linked file'
  refuses_with "F54a a multiply-linked tool_response.filePath is refused too" \
    PLAN_FILE_SYMLINK_REJECTED \
    "$(invoke "$(payload_response refuse_session __ABSENT__ "$HARDLINK_PATH")" \
      "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"
else
  check "F54 hard-link refusal (skipped: this platform cannot create one)" PASS
  check "F54a hard-link refusal via the response (skipped: this platform cannot create one)" PASS
fi

# --- F49/F50 the two containers are deliberately asymmetric. A non-object
# tool_response is drift (F35), but a non-object or absent tool_input is plain
# absence: refusing on its shape would block a payload whose plan arrived
# intact in the response, which is a new way to wedge the one gate this change
# exists to unwedge. Both shapes must still produce the honest receipt.
F49_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_response:{isAgent:false, hasTaskTool:true}
  }));
')"
refuses_with "F49 a payload with no tool_input key at all is absence, not drift" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$F49_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'Neither the ExitPlanMode payload nor its tool response'

F50_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:"a string",
    tool_response:{isAgent:false, hasTaskTool:true}
  }));
')"
refuses_with "F50 a non-object tool_input is absence, not drift" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$F50_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'Neither the ExitPlanMode payload nor its tool response'

# --- F37-F43 the response path faces the SAME hardening lattice as the
# tool_input path. Without these, a regression that gave source 2 its own read
# would break every protection while the suite stayed green.
refuses_with "F37 a nonexistent tool_response.filePath reports PLAN_FILE_UNREADABLE" \
  PLAN_FILE_UNREADABLE \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$TMP/no-such-plan.md")" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  'The payload or its tool response named a plan file path'

refuses_with "F38 a directory at tool_response.filePath reports PLAN_FILE_NOT_REGULAR" \
  PLAN_FILE_NOT_REGULAR \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$DIR_PATH")" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F39 an empty file at tool_response.filePath reports PLAN_FILE_EMPTY" \
  PLAN_FILE_EMPTY \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$EMPTY_FILE")" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F40 an oversize file at tool_response.filePath reports PLAN_FILE_TOO_LARGE" \
  PLAN_FILE_TOO_LARGE \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$OVERSIZE_FILE")" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F41 a relative tool_response.filePath is rejected before any filesystem access" \
  PLAN_FILE_PATH_REJECTED \
  "$(invoke "$(payload_response refuse_session __ABSENT__ 'relative/plan.md')" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F42 a UNC-style tool_response.filePath is rejected before any filesystem access" \
  PLAN_FILE_PATH_REJECTED \
  "$(invoke "$(payload_response refuse_session __ABSENT__ '//attacker.example.com/share/plan.md')" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

if [ -L "$LINK_PATH" ]; then
  refuses_with "F43 a symlinked tool_response.filePath is refused, not silently followed" \
    PLAN_FILE_SYMLINK_REJECTED \
    "$(invoke "$(payload_response refuse_session __ABSENT__ "$LINK_PATH")" \
      "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"
else
  check "F43 response symlink refusal (skipped: this platform cannot create one)" PASS
fi

# --- F48 a named path that fails to read is a hard block, deliberately: it is
# never silently swapped for a lower-precedence source that happens to work.
refuses_with "F48 an unreadable response path blocks rather than falling back to tool_input" \
  PLAN_FILE_UNREADABLE \
  "$(invoke "$(payload_mixed refuse_session '# Fallback that must NOT be used

<!-- zensu-autopilot:refuse_run -->' __ABSENT__ __ABSENT__ "$TMP/no-such-plan.md")" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

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

# --- F32 the response path is subject to the same ordering: ownership first.
# Re-provisions the foreign session explicitly rather than inheriting F20's.
provision_session "$REFUSE_PROJECT" foreign_plan_session foreign || { echo "F32 fixture failed" >&2; exit 1; }
OUT32="$(invoke "$(payload_response foreign_plan_session __ABSENT__ "$PLAN_FILE")" \
  "$REFUSE_PROJECT" "$CFG_OFF" "$PROVISIONED_DATA")"
OUT32B="$(invoke "$(payload_response foreign_plan_session __ABSENT__ "$TMP/no-such-plan.md")" \
  "$REFUSE_PROJECT" "$CFG_OFF" "$PROVISIONED_DATA")"
if printf '%s' "$OUT32" | grep -qF 'code=OWNER_SESSION_MISMATCH' \
  && [ "$OUT32" = "$OUT32B" ] \
  && [ "$(digest "$REFUSE_RUN_FILE")" = "$REFUSE_BEFORE" ]; then
  check "F32 a foreign session is refused before tool_response.filePath is read" PASS
else
  check "F32 foreign session via response (out='$(printf '%s' "$OUT32" | head -c 200)')" FAIL
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

# The reader now lives in hooks/lib/plan-payload-v1.js, so F10's hook-only scan
# would no longer notice a code the module can refuse with. The module names its
# codes after the very BLOCK_CODE they must translate into, which makes the
# invariant checkable in both directions: every EXIT_CODES entry needs a case arm
# carrying its own name AND cause prose under that name.
# The probe prints an explicit verdict rather than staying silent on success:
# an empty stdout would otherwise make a require failure or an EXIT_CODES rename
# look like a clean pass, which is the one way this guard could stop guarding.
MODULE_CODE_GAP="$(HOOK="$HOOK" MODULE="$MODULE" node -e '
  const verdict=(()=>{
    try {
      const hook=require("fs").readFileSync(process.env.HOOK,"utf8");
      const codes=require(process.env.MODULE).EXIT_CODES;
      const causesAt=hook.indexOf("const causes={");
      if (causesAt<0) return "causes-map-lost";
      const causes=hook.slice(causesAt,hook.indexOf("};",causesAt));
      const gaps=[];
      const armNumbers=[...hook.matchAll(/^\s*([0-9]+)\) BLOCK_CODE=[A-Z_]+ ;;$/gm)].map((m)=>m[1]);
      if (armNumbers.length<1) return "case-arms-lost";
      const duplicated=[...new Set(armNumbers.filter((n,i)=>armNumbers.indexOf(n)!==i))];
      if (duplicated.length) gaps.push("duplicate-case-arms:"+duplicated.join(","));
      const start=hook.lastIndexOf("process.stdin.on(\"end\"");
      const end=start<0 ? -1 : hook.indexOf("} catch (error)",start);
      if (start<0 || end<0) return "evaluator-slice-lost";
      const evaluator=hook.slice(start,end);
      const inline=new Set([...evaluator.matchAll(/process\.exit\(([0-9]+)\)/g)].map((m)=>Number(m[1])));
      if (inline.size<1) return "evaluator-literals-empty";
      for (const [name,value] of Object.entries(codes)) {
        if (inline.has(value)) gaps.push(name+"="+value+":collides-with-an-evaluator-literal");
        if (!new RegExp("^\\s*"+value+"\\) BLOCK_CODE="+name+" ;;$","m").test(hook)) gaps.push(name+"="+value+":no-case-arm");
        else if (!new RegExp("^\\s{6}"+name+":","m").test(causes)) gaps.push(name+":no-cause");
      }
      return gaps.length ? gaps.join(" ") : "ok";
    } catch (error) {
      return "probe-failed:"+((error && error.message) || "unknown");
    }
  })();
  process.stdout.write(verdict);
')"
if [ "$MODULE_CODE_GAP" = ok ]; then
  check "F10a every module code is translated, explained, and disjoint from the evaluator literals" PASS
else
  check "F10a module code translation gap: $MODULE_CODE_GAP" FAIL
fi

# --- F11 the codes no fixture can provoke are still wired ---
# The evaluator no longer owns the reader, so the untyped-throw fallback now
# lives in the catch that maps a typed module refusal back to its number. Both
# halves are pinned: the hook keeps the single numeric-to-BLOCK_CODE case table,
# and the module keeps 3 while never terminating the host process itself.
if grep -Eq 'catch \(error\) \{ process\.exit\(planPayload\.exitCodeOf\(error\) \|\| 9\); \}' "$HOOK" \
  && grep -Eq '9\)[[:space:]]*BLOCK_CODE=PLAN_PAYLOAD_EVALUATION_FAILED' "$HOOK" \
  && grep -Eq '\*\)[[:space:]]*BLOCK_CODE=PLAN_EVALUATION_UNAVAILABLE' "$HOOK" \
  && grep -Eq '3\)[[:space:]]*BLOCK_CODE=INVALID_PLAN_PAYLOAD' "$HOOK" \
  && grep -Eq '^  INVALID_PLAN_PAYLOAD: 3,$' "$MODULE" \
  && ! grep -Eq 'process\.(exit|abort)\(' "$MODULE"; then
  check "F11 the throw and no-verdict paths map to their own block codes" PASS
else
  check "F11 exception and no-verdict codes are not distinctly wired" FAIL
fi

# The in-evaluator tool binding re-check cannot be provoked from outside: the
# bash verdict above it already dismisses any payload naming another tool. It
# exists so the binding is atomic with the read of the fields whose names other
# tools share, so its wiring is asserted at the source level instead.
if grep -Eq 'input\.tool_name!=="ExitPlanMode"\) process\.exit\(18\)' "$HOOK" \
  && grep -Eq '18\)[[:space:]]*BLOCK_CODE=PLAN_TOOL_BINDING_MISMATCH' "$HOOK"; then
  check "F11b the in-evaluator tool binding re-check has its own block code" PASS
else
  check "F11b in-evaluator tool binding re-check is not distinctly wired" FAIL
fi

# The evaluator's stage refusal is unreachable the same way: the bash case only
# admits PLANNING and AWAIT_TDD, and ACTIVE_STAGE is re-derived from the same
# document. F55 exercises the bash arm; this pins the evaluator twin so a rename
# on either side cannot pass unnoticed.
if grep -Eq 'ACTIVE_STAGE!=="PLANNING".*process\.exit\(7\)' "$HOOK" \
  && grep -Eq '7\)[[:space:]]*BLOCK_CODE=PLAN_STAGE_MISMATCH' "$HOOK"; then
  check "F11d the evaluator stage refusal stays wired to PLAN_STAGE_MISMATCH" PASS
else
  check "F11d evaluator stage refusal is not distinctly wired" FAIL
fi

# The re-check must run BEFORE the shape and origin checks, or a foreign payload
# is described by a receipt written for an ExitPlanMode one. The branch cannot be
# provoked from outside (the bash verdict dismisses it first), so the ordering is
# asserted at the source level, the same way F11/F11a are.
# This is a TEXTUAL pin, and text is only a proxy for execution order while the
# refusals stay straight-line statements of the evaluator. So it also requires
# each of them to remain a top-level statement at the evaluator's own
# indentation: a check hoisted into a helper could otherwise keep the textual
# order while inverting the runtime one.
# Code 16 is now raised by the module, so the evaluator's shape step is the
# normalizeToolResponse call rather than a bare exit. The call is therefore held
# to the same top-level shape, and the module is required to raise 16 from that
# one function only — otherwise the shape refusal could drift to a later step
# while this slice still looked ordered.
ORDER_VERDICT="$(HOOK="$HOOK" MODULE="$MODULE" node -e '
  const fs=require("fs");
  const src=fs.readFileSync(process.env.HOOK,"utf8");
  const mod=fs.readFileSync(process.env.MODULE,"utf8");
  const SHAPE_CALL="const toolResponse=planPayload.normalizeToolResponse(input.tool_response);";
  const verdict=(()=>{
    const start=src.lastIndexOf("process.stdin.on(\"end\"");
    const end=src.indexOf("const matches=");
    if (start<0 || end<0 || end<start) return "slice";
    const slice=src.slice(start,end);
    const at=(needle)=>slice.indexOf(needle);
    const binding=at("process.exit(18)");
    const shape=at(SHAPE_CALL);
    if (binding<0) return "missing-binding";
    if (shape<0) return "missing-shape";
    if (shape<binding) return "shape-before-binding";
    const offenders=[["19",at("process.exit(19)")],["17",at("process.exit(17)")]]
      .filter(([,pos])=>pos>=0 && pos<shape).map(([code])=>code);
    if (offenders.length) return "origin-before-shape:"+offenders.join(",");
    const reader=at("planPayload.readPlanPayload(");
    if (reader<0) return "missing-reader";
    const late=[["19",at("process.exit(19)")],["17",at("process.exit(17)")]]
      .filter(([,pos])=>pos<0 || pos>reader).map(([code])=>code);
    if (late.length) return "reader-before-origin:"+late.join(",");
    const lines=slice.split("\n");
    const nested=["18","19","17"].filter((code)=>!lines.some((line)=>
      new RegExp("^ {8}if \\(.*process\\.exit\\("+code+"\\);$").test(line)));
    if (nested.length) return "not-top-level:"+nested.join(",");
    if (!lines.some((line)=>line==="        "+SHAPE_CALL)) return "shape-not-top-level";
    const raises=[...mod.matchAll(/refuse\(EXIT_CODES\.PLAN_RESPONSE_SHAPE_REJECTED\)/g)].length;
    if (raises!==1) return "module-shape-refusals:"+raises;
    const fn=mod.slice(mod.indexOf("function normalizeToolResponse("),mod.indexOf("function readStringField("));
    if (fn.indexOf("PLAN_RESPONSE_SHAPE_REJECTED")<0) return "module-shape-misplaced";
    return "ok";
  })();
  process.stdout.write(verdict);
')"
if [ "$ORDER_VERDICT" = ok ]; then
  check "F11c the tool binding re-check precedes every shape and origin refusal" PASS
else
  check "F11c tool binding re-check ordering ($ORDER_VERDICT)" FAIL
fi

# The plan is only ever read from the payload — never guessed by scanning a
# plans directory, which would race concurrent sessions onto the wrong digest.
# The reader module is scanned too: moving the filesystem access out of the hook
# would otherwise move it out of this guard's reach as well.
if ! grep -Eq 'zensu/plans|claude/plans|plans/\*|readdirSync|opendirSync|globSync' "$HOOK" "$MODULE"; then
  check "F11a neither the hook nor the payload module scans a plans directory" PASS
else
  check "F11a a plans directory is scanned to guess the plan" FAIL
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

# --- F33 the captured REAL payload, replayed byte-shape-faithfully. The
# placeholder run first: it must fail on the MARKER, because failing on a
# missing payload is exactly the regression this source exists to prevent.
arm_run realshape realshape_session realshape_run || { echo "F33 fixture failed" >&2; exit 1; }
REALSHAPE_BEFORE="$(digest "$ARMED_RUN_FILE")"
OUT33A="$(invoke "$(payload_fixture realshape_session __KEEP__)" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT33A" | grep -qF 'code=PLAN_MARKER_MISSING_OR_AMBIGUOUS' \
  && ! printf '%s' "$OUT33A" | grep -qF 'INVALID_PLAN_PAYLOAD' \
  && [ "$(digest "$ARMED_RUN_FILE")" = "$REALSHAPE_BEFORE" ]; then
  check "F33 the real captured payload reaches the marker check, not INVALID_PLAN_PAYLOAD" PASS
else
  check "F33 real payload (out='$(printf '%s' "$OUT33A" | head -c 200)')" FAIL
fi

REALSHAPE_PLAN="# Replayed real payload

<!-- zensu-autopilot:realshape_run -->"
OUT33B="$(invoke "$(payload_fixture realshape_session "$REALSHAPE_PLAN")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT33B" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$REALSHAPE_PLAN")" ]; then
  check "F33a the real captured payload approves its bound run" PASS
else
  check "F33a real payload approval (out='$(printf '%s' "$OUT33B" | head -c 200)')" FAIL
fi

# The capture justifies BOTH response source entries, so the filePath entry is
# replayed from the same captured key set rather than only from a hand-built one.
arm_run realshapefile realshapefile_session realshapefile_run || { echo "F33b fixture failed" >&2; exit 1; }
REALSHAPE_FILE="$TMP/realshape-plan.md"
printf '# Replayed real payload, file source\n\n<!-- zensu-autopilot:realshapefile_run -->\n' > "$REALSHAPE_FILE"
OUT33C="$(invoke "$(payload_fixture realshapefile_session '' "$REALSHAPE_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT33C" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$REALSHAPE_FILE")" ]; then
  check "F33b the captured payload approves through its own filePath entry" PASS
else
  check "F33b real payload file source (out='$(printf '%s' "$OUT33C" | head -c 200)')" FAIL
fi

# --- F52 a present-but-empty response tier still descends to the legacy
# tool_input sources. This is a deliberate availability choice, not an
# oversight: refusing here would invent a new way to wedge the very gate this
# source exists to unwedge, for a payload shape nobody has measured. It is safe
# only while tool_input is harness-controlled.
arm_run legacydescent legacydescent_session legacydescent_run || { echo "F52 fixture failed" >&2; exit 1; }
LEGACY_DESCENT_PLAN="# Legacy source still reachable

<!-- zensu-autopilot:legacydescent_run -->"
OUT52="$(invoke "$(payload_mixed legacydescent_session "$LEGACY_DESCENT_PLAN" __ABSENT__ '' __ABSENT__)" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT52" | grep -qF 'PLAN_APPROVED' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$LEGACY_DESCENT_PLAN")" ]; then
  check "F52 an empty response tier still descends to the legacy tool_input sources" PASS
else
  check "F52 legacy descent (out='$(printf '%s' "$OUT52" | head -c 160)')" FAIL
fi

# --- F55 a run that has left the planning stages is refused, not re-approved.
# The hook accepts only PLANNING and AWAIT_TDD; every other durable stage lands
# on PLAN_STAGE_MISMATCH, and nothing else in the repo exercises that arm.
arm_run stagemismatch stagemismatch_session stagemismatch_run || { echo "F55 fixture failed" >&2; exit 1; }
STAGE_OWNER="$PROVISIONED_KEY"
STAGE_SHA="$(text_sha '# Stage fixture')"
if autopilot_apply_event stagemismatch_run stage-plan PLAN_APPROVED \
    "{\"approvedPlanSha256\":\"$STAGE_SHA\"}" "$ARMED_PROJECT" >/dev/null 2>&1 \
  && autopilot_apply_event stagemismatch_run stage-tdd TDD_STARTED \
    "{\"attempt\":1,\"chainId\":\"stage-chain-01\",\"sessionId\":\"$STAGE_OWNER\"}" \
    "$ARMED_PROJECT" >/dev/null 2>&1; then
  STAGE_BEFORE="$(digest "$ARMED_RUN_FILE")"
  OUT55="$(invoke "$(payload_response stagemismatch_session '# Too late

<!-- zensu-autopilot:stagemismatch_run -->' __ABSENT__)" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
  if printf '%s' "$OUT55" | grep -qF 'code=PLAN_STAGE_MISMATCH' \
    && printf '%s' "$OUT55" | grep -qF 'not in a stage that accepts a plan approval' \
    && ! printf '%s' "$OUT55" | grep -qF 'AskUserQuestion' \
    && [ "$(digest "$ARMED_RUN_FILE")" = "$STAGE_BEFORE" ]; then
    check "F55 a run past the planning stages reports PLAN_STAGE_MISMATCH" PASS
  else
    check "F55 stage mismatch (out='$(printf '%s' "$OUT55" | head -c 200)')" FAIL
  fi
else
  check "F55 stage fixture could not reach a post-planning stage" FAIL
fi

# --- F56 the reader module carries its own unit suite ---
# A skipped arm is legitimate on a platform without symlinks, hard links or
# FIFOs, but it must be VISIBLE rather than indistinguishable from a full run.
# The unit suite marks each gap with an `ARM-SKIPPED <name>:` diagnostic and
# calls t.skip only when a whole case is unrunnable, so both tokens are counted.
# --test-reporter=tap pins the output format both this count and the failure
# dump below depend on.
# F56 is the ONLY gate on the unit file — run-all discovers test-*.sh only — so
# an exit status is not enough: node --test exits 0 for a file with no cases at
# all. The TAP trailer supplies a case floor, and the floor counts `# tests`
# rather than `# pass` so a legitimate platform skip does not fail the gate.
MODULE_TEST_FLOOR=22
if node --test --test-reporter=tap "$MODULE_TEST" >"$RAW_TMP/module-unit.out" 2>&1; then
  UNIT_TESTS="$(awk '/^# tests /{print $3; exit}' "$RAW_TMP/module-unit.out")"
  UNIT_FAIL="$(awk '/^# fail /{print $3; exit}' "$RAW_TMP/module-unit.out")"
  UNIT_CANCELLED="$(awk '/^# cancelled /{print $3; exit}' "$RAW_TMP/module-unit.out")"
  # grep -c prints the count and still exits 1 on zero matches, so tolerate the
  # status instead of appending a second count with a || fallback.
  UNIT_SKIPS="$(grep -cE '# SKIP|ARM-SKIPPED' "$RAW_TMP/module-unit.out" 2>/dev/null)" || true
  for _f56_counter in UNIT_TESTS UNIT_FAIL UNIT_CANCELLED UNIT_SKIPS; do
    eval "case \"\$$_f56_counter\" in ''|*[!0-9]*) $_f56_counter=-1 ;; esac"
  done
  if [ "$UNIT_TESTS" -lt "$MODULE_TEST_FLOOR" ] || [ "$UNIT_FAIL" -ne 0 ] || [ "$UNIT_CANCELLED" -ne 0 ]; then
    check "F56 unit trailer below the floor (tests=$UNIT_TESTS floor=$MODULE_TEST_FLOOR fail=$UNIT_FAIL cancelled=$UNIT_CANCELLED)" FAIL
  elif ! grep -qF 'ARM-PROBE ok' "$RAW_TMP/module-unit.out"; then
    check "F56 the unit suite's diagnostic channel is broken: ARM-PROBE token absent" FAIL
  elif [ "$UNIT_SKIPS" -eq 0 ]; then
    check "F56 the payload reader unit suite passes ($UNIT_TESTS cases, node --test plan-payload-v1.test.js)" PASS
  else
    check "F56 the payload reader unit suite passes ($UNIT_TESTS cases) with $UNIT_SKIPS platform gap(s): $(grep -hoE '(# SKIP|ARM-SKIPPED) [^ ]*' "$RAW_TMP/module-unit.out" | tr '\n' ' ' | head -c 160)" PASS
  fi
else
  grep -B2 -A 20 '^not ok' "$RAW_TMP/module-unit.out" | sed 's/^/        /'
  check "F56 payload reader unit suite ($(grep -c '^not ok' "$RAW_TMP/module-unit.out" 2>/dev/null) failures)" FAIL
fi

# --- F57 the module reaches node as an environment value, never as argv ---
# A plugin root spelled with whitespace or an apostrophe cannot be transported
# through argv. That constraint originates in
# tests/structure/test-msys-special-plugin-module-boundaries.sh, but that canary
# does NOT execute this hook, so THIS case is the enforcer for the plan gate.
# The preflight is part of the same contract: an absent or symlinked module must
# be refused before the evaluator runs, not discovered as a require throw.
# A line-scoped negative grep is not enough: the evaluator invocation spans ~30
# lines, so an argv token appended to its CLOSING line would carry no `node` on
# that line and evade one. Every line naming the module is therefore matched
# against a closed allowlist of forms instead.
TRANSPORT_VERDICT="$(HOOK="$HOOK" node -e '
  const verdict=(()=>{
    try {
      const lines=require("fs").readFileSync(process.env.HOOK,"utf8").split("\n");
      const allowed=[
        /^    PLAN_PAYLOAD_MODULE="\$\{NATIVE_PLUGIN_ROOT\}\/hooks\/lib\/plan-payload-v1\.js"$/,
        /^    if \[ ! -f "\$PLAN_PAYLOAD_MODULE" \] \|\| \[ ! -r "\$PLAN_PAYLOAD_MODULE" \] \|\| \[ -L "\$PLAN_PAYLOAD_MODULE" \]; then$/,
        /^    PLAN_PAYLOAD_MSYS_EXCL="\$\(zensu_msys_env_exclusions PLAN_PAYLOAD_MODULE\)" \|\| \{$/,
        /^      PLAN_PAYLOAD_MODULE="\$PLAN_PAYLOAD_MODULE" node -e .$/,
        /^      const planPayload=require\(process\.env\.PLAN_PAYLOAD_MODULE\);$/
      ];
      const offenders=[];
      lines.forEach((line,index)=>{
        if (!/PLAN_PAYLOAD_MODULE|plan-payload-v1\.js/.test(line)) return;
        if (/^\s*#/.test(line)) return;
        if (!allowed.some((pattern)=>pattern.test(line))) offenders.push(String(index+1));
      });
      if (offenders.length) return "unexpected-module-line:"+offenders.join(",");
      const matched=allowed.filter((pattern)=>lines.some((line)=>pattern.test(line))).length;
      return matched===allowed.length ? "ok" : "missing-forms:"+(allowed.length-matched);
    } catch (error) {
      return "probe-failed:"+((error && error.message) || "unknown");
    }
  })();
  process.stdout.write(verdict);
')"
if grep -Fq 'PLAN_PAYLOAD_MODULE="${NATIVE_PLUGIN_ROOT}/hooks/lib/plan-payload-v1.js"' "$HOOK" \
  && grep -Fq 'zensu-host-path.sh" "$CLAUDE_PLUGIN_ROOT"' "$HOOK" \
  && grep -Fq '[ ! -f "$PLAN_PAYLOAD_MODULE" ] || [ ! -r "$PLAN_PAYLOAD_MODULE" ] || [ -L "$PLAN_PAYLOAD_MODULE" ]' "$HOOK" \
  && grep -Fq 'PLAN_PAYLOAD_MODULE="$PLAN_PAYLOAD_MODULE" node -e' "$HOOK" \
  && grep -Fq 'PLAN_PAYLOAD_MSYS_EXCL="$(zensu_msys_env_exclusions PLAN_PAYLOAD_MODULE)" || {' "$HOOK" \
  && grep -Fq 'MSYS2_ENV_CONV_EXCL="$PLAN_PAYLOAD_MSYS_EXCL"' "$HOOK" \
  && grep -Fq 'require(process.env.PLAN_PAYLOAD_MODULE)' "$HOOK" \
  && [ "$TRANSPORT_VERDICT" = ok ]; then
  check "F57 the reader module is preflighted and transported through the environment" PASS
else
  check "F57 reader module transport or preflight is not wired ($TRANSPORT_VERDICT)" FAIL
fi

# --- F58 a plugin missing the reader module fails closed, it never approves ---
# F57 pins the wiring; this pins the consequence. The module is removed BEFORE
# the session is provisioned, so the Session Control runtime digest matches the
# copied plugin and the refusal proves the hook's own preflight rather than a
# digest mismatch. This case runs last because provisioning exports
# CLAUDE_PROJECT_DIR and CLAUDE_PLUGIN_DATA for the remainder of the shell.
NO_MODULE_PLUGIN="$RAW_TMP/plugin-without-reader"
mkdir -p "$NO_MODULE_PLUGIN"
NO_MODULE_READY=false
if cp -R "$PLUGIN_DIR/.claude-plugin" "$PLUGIN_DIR/hooks" "$PLUGIN_DIR/agents" \
    "$PLUGIN_DIR/skills" "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/mcp-runtime" "$NO_MODULE_PLUGIN/" \
    && cp "$PLUGIN_DIR/.mcp.json" "$NO_MODULE_PLUGIN/.mcp.json" \
    && rm -f "$NO_MODULE_PLUGIN/hooks/lib/plan-payload-v1.js"; then
  NO_MODULE_PROJECT="$TMP/nomodule"
  mkdir -p "$NO_MODULE_PROJECT"
  export CLAUDE_PROJECT_DIR="$NO_MODULE_PROJECT"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data/nomodule"
  # shellcheck disable=SC1090
  if source "$BASELINE" nomodule_session "$NO_MODULE_PLUGIN" >/dev/null 2>&1 \
      && autopilot_begin_run nomodule_run "$ZENSU_SESSION_KEY" "$NO_MODULE_PROJECT" >/dev/null 2>&1; then
    NO_MODULE_READY=true
    NO_MODULE_DATA="$CLAUDE_PLUGIN_DATA"
    NO_MODULE_RUN_FILE="$(autopilot_run_file nomodule_run "$NO_MODULE_PROJECT")"
  fi
fi
if [ "$NO_MODULE_READY" = true ] && [ -f "$NO_MODULE_RUN_FILE" ]; then
  NO_MODULE_BEFORE="$(digest "$NO_MODULE_RUN_FILE")"
  OUT58="$(payload_response nomodule_session '# Plan

<!-- zensu-autopilot:nomodule_run -->' __ABSENT__ \
    | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
      -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
      CLAUDE_PLUGIN_ROOT="$NO_MODULE_PLUGIN" CLAUDE_PLUGIN_DATA="$NO_MODULE_DATA" \
      CLAUDE_PROJECT_DIR="$NO_MODULE_PROJECT" ZENSU_CONFIG="$CFG_OFF" \
      bash "$NO_MODULE_PLUGIN/hooks/plan-approved-delegate.sh" 2>/dev/null)"
  if printf '%s' "$OUT58" | grep -qF 'code=RUNTIME_UNAVAILABLE' \
    && ! printf '%s' "$OUT58" | grep -qF 'PLAN_APPROVED' \
    && ! printf '%s' "$OUT58" | grep -qF 'AskUserQuestion' \
    && [ "$(digest "$NO_MODULE_RUN_FILE")" = "$NO_MODULE_BEFORE" ]; then
    check "F58 a plugin without the reader module refuses the gate instead of approving" PASS
  else
    check "F58 missing reader module (out='$(printf '%s' "$OUT58" | head -c 200)')" FAIL
  fi
else
  check "F58 reader-less plugin fixture could not be provisioned" FAIL
fi

# --- F58a positive control: the same copied plugin approves once the module is back ---
# Without this, F58 would also pass if the copied plugin refused for an unrelated
# reason. The module is restored and a FRESH session is provisioned so the
# runtime digest is recomputed over the now-complete copy.
if [ "$NO_MODULE_READY" = true ] \
    && cp "$MODULE" "$NO_MODULE_PLUGIN/hooks/lib/plan-payload-v1.js"; then
  RESTORED_PROJECT="$TMP/restoredmodule"
  mkdir -p "$RESTORED_PROJECT"
  export CLAUDE_PROJECT_DIR="$RESTORED_PROJECT"
  export ZENSU_TEST_PLUGIN_DATA="$TMP/plugin-data/restoredmodule"
  # shellcheck disable=SC1090
  if source "$BASELINE" restored_session "$NO_MODULE_PLUGIN" >/dev/null 2>&1 \
      && autopilot_begin_run restored_run "$ZENSU_SESSION_KEY" "$RESTORED_PROJECT" >/dev/null 2>&1; then
    RESTORED_PLAN='# Plan

<!-- zensu-autopilot:restored_run -->'
    OUT58A="$(payload_response restored_session "$RESTORED_PLAN" __ABSENT__ \
      | env -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
        -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT \
        CLAUDE_PLUGIN_ROOT="$NO_MODULE_PLUGIN" CLAUDE_PLUGIN_DATA="$CLAUDE_PLUGIN_DATA" \
        CLAUDE_PROJECT_DIR="$RESTORED_PROJECT" ZENSU_CONFIG="$CFG_OFF" \
        bash "$NO_MODULE_PLUGIN/hooks/plan-approved-delegate.sh" 2>/dev/null)"
    RESTORED_SHA="$(run_field "$(autopilot_run_file restored_run "$RESTORED_PROJECT")" approvedPlanSha256)"
    if printf '%s' "$OUT58A" | grep -qF 'PLAN_APPROVED runId=restored_run' \
      && ! printf '%s' "$OUT58A" | grep -qF 'RUNTIME_UNAVAILABLE' \
      && [ "$RESTORED_SHA" = "$(text_sha "$RESTORED_PLAN")" ]; then
      check "F58a the same copied plugin approves once the reader module is restored" PASS
    else
      check "F58a restored reader module (out='$(printf '%s' "$OUT58A" | head -c 200)')" FAIL
    fi
  else
    check "F58a restored-module fixture could not be provisioned" FAIL
  fi
else
  check "F58a restored-module fixture could not be prepared" FAIL
fi

echo "----"
echo "test-plan-payload-fallback: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
