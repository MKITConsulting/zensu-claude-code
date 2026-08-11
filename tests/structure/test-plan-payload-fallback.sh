#!/bin/bash
# Pins how plan-approved-delegate.sh reads the approved plan out of the
# ExitPlanMode payload, and that each way of failing gets its own receipt.
#
#   F1  plan only                    -> approves, digest over the inline text
#   F2  planFilePath only            -> approves, digest over the file bytes
#   F3  both, differing              -> plan wins; the file's bytes never land
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
#   F21a non-string planFilePath     -> PLAN_PAYLOAD_FIELD_TYPE_REJECTED
#   F22 multi-byte UTF-8 plan file   -> digest still equals the file bytes
#   F23 invalid-UTF-8 plan file      -> digest over the raw bytes
#   F24 tool_response.plan only      -> approves, digest over the response bytes
#   F25 tool_response.filePath only  -> approves, digest over the file bytes
#   F26 input plan vs response plan  -> tool_input.plan still wins
#   F27 response plan vs filePath    -> response plan wins; the file is never opened
#   F28 response plan, no marker     -> PLAN_MARKER_MISSING_OR_AMBIGUOUS
#   F29 response plan, foreign run   -> PLAN_MARKER_RUN_MISMATCH
#   F30 non-string response fields   -> PLAN_PAYLOAD_FIELD_TYPE_REJECTED
#   F31 null/array/string response   -> INVALID_PLAN_PAYLOAD (never text-scanned)
#   F32 foreign session + response   -> OWNER_SESSION_MISMATCH, file untouched
#   F33 captured real harness shape  -> approves through the response source
#   F34 "saved to:" line in the plan -> that path is never used
#   F35-F41 response filePath refusals -> the hardened reader guards source 4 too
#   F42 empty response plan          -> falls through to the response filePath
#   F43 empty input filePath         -> falls through to the response
#   F44 both response fields agree   -> either byte source yields one digest
#
# F18/F19 matter because they prove file-fed bytes face the same run-binding
# checks as inline text. F20 pins that authorization is decided BEFORE the
# payload's path is touched at all, so an unauthorized payload can neither
# make the hook open an arbitrary path nor learn whether it exists.
#
# F24-F34 cover the contract of the current Claude Code harness, which strips
# ExitPlanMode fields its schema does not declare and delivers the approved plan
# in the tool response instead. F31 and F34 are the security half: the response
# is read from NAMED object fields only, so neither a rendered string response
# nor a "Your plan has been saved to:" line inside the model-authored plan body
# can steer the hook at a path of its choosing.
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

PLAN_MAX_BYTES="$(PLAN_LIB_PATH="$PLUGIN_DIR/hooks/lib/plan-payload-v1.js" node -e '
  process.stdout.write(String(require(process.env.PLAN_LIB_PATH).PLAN_FILE_MAX_BYTES));
' 2>/dev/null)"
[ -n "$PLAN_MAX_BYTES" ] || { echo "plan-payload module did not expose PLAN_FILE_MAX_BYTES" >&2; exit 1; }

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

# The harness delivers the approved plan in the tool RESPONSE, and strips the
# ExitPlanMode input fields its schema does not declare — hence the _targetMode
# input, which is what a real payload carries in place of plan/planFilePath.
# $1 raw session id, $2 response plan text or __ABSENT__, $3 response filePath or __ABSENT__
payload_response() {
  MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID="$1" RPLAN="$2" PLAN_PATH="$3" node -e '
    const tr={isAgent:false,hasTaskTool:true};
    if (process.env.RPLAN!=="__ABSENT__") tr.plan=process.env.RPLAN;
    if (process.env.PLAN_PATH!=="__ABSENT__") tr.filePath=process.env.PLAN_PATH;
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"}, tool_response:tr
    }));
  '
}

# $1 raw session id, $2 tool_input.plan, $3 tool_response.plan
payload_input_and_response() {
  SID="$1" IPLAN="$2" RPLAN="$3" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode", tool_input:{plan:process.env.IPLAN},
      tool_response:{plan:process.env.RPLAN,isAgent:false,hasTaskTool:true}
    }));
  '
}

# A response field of the wrong type must be refused, never silently skipped.
# $1 raw session id, $2 plan|filePath
payload_response_nonstring() {
  SID="$1" KIND="$2" node -e '
    const tr={isAgent:false,hasTaskTool:true};
    if (process.env.KIND==="plan") tr.plan={unexpected:"object"};
    else tr.filePath=["not","a","string"];
    process.stdout.write(JSON.stringify({
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"}, tool_response:tr
    }));
  '
}

# A response that is not a plain object carries no named fields to read. The
# string shape is the rendered text the MODEL sees; mining it for a plan would
# be exactly the text-scanning this hook must not do.
# $1 raw session id, $2 null|array|string, $3 path named by the rendered string
payload_response_shape() {
  MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID="$1" SHAPE="$2" PLAN_PATH="$3" node -e '
    const body={
      hook_event_name:"PostToolUse", session_id:process.env.SID,
      tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"}
    };
    if (process.env.SHAPE==="null") body.tool_response=null;
    else if (process.env.SHAPE==="array") body.tool_response=["# plan"];
    else if (process.env.SHAPE==="string") body.tool_response=
      "User has approved your plan.\n\nYour plan has been saved to: "
      + process.env.PLAN_PATH + "\n\n## Approved Plan:\n# Rendered plan\n";
    process.stdout.write(JSON.stringify(body));
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
if printf '%s' "$OUT1" | grep -qF 'PLAN_APPROVED runId=' \
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
if printf '%s' "$OUT2" | grep -qF 'PLAN_APPROVED runId='; then
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
if printf '%s' "$OUT9" | grep -qF 'PLAN_APPROVED runId=' \
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
if printf '%s' "$OUT22" | grep -qF 'PLAN_APPROVED runId=' \
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
if printf '%s' "$OUT23" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$RAW_ACTUAL" = "$(file_sha "$RAW_FILE")" ]; then
  check "F23 an invalid-UTF-8 plan file digests to its raw bytes, not a re-encoding" PASS
else
  check "F23 raw-byte digest (got=$RAW_ACTUAL want=$(file_sha "$RAW_FILE"))" FAIL
fi

# --- F14 a file exactly at the size limit is still accepted ---
arm_run atlimit atlimit_session atlimit_run || { echo "F14 fixture failed" >&2; exit 1; }
LIMIT_FILE="$TMP/at-limit-plan.md"
MAX_BYTES="$PLAN_MAX_BYTES" node -e '
  const fs=require("fs");
  const marker="\n<!-- zensu-autopilot:atlimit_run -->\n";
  const total=Number(process.env.MAX_BYTES);
  const filler=Buffer.alloc(total-Buffer.byteLength(marker),0x61);
  fs.writeFileSync(process.argv[1],Buffer.concat([filler,Buffer.from(marker)]));
' "$LIMIT_FILE"
OUT14="$(invoke "$(payload atlimit_session __ABSENT__ "$LIMIT_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT14" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$LIMIT_FILE")" ]; then
  check "F14 a plan file exactly at the 4 MiB limit is accepted" PASS
else
  check "F14 at-limit file rejected (out='$(printf '%s' "$OUT14" | head -c 120)')" FAIL
fi

# --- F3 both fields present: the inline plan supplies the approved bytes. The
# decoy is a REAL, readable file carrying the same active marker, so it would
# satisfy every downstream check and only the digest reveals which source won.
arm_run bothfields both_session both_run || { echo "F3 fixture failed" >&2; exit 1; }
BOTH_DECOY="$TMP/decoy-plan.md"
printf '# Decoy at the input planFilePath\n\n<!-- zensu-autopilot:both_run -->\n' > "$BOTH_DECOY"
BOTH_PLAN="# Inline wins

<!-- zensu-autopilot:both_run -->"
OUT3="$(invoke "$(payload both_session "$BOTH_PLAN" "$BOTH_DECOY")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
BOTH_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT3" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$BOTH_SHA_ACTUAL" = "$(text_sha "$BOTH_PLAN")" ] \
  && [ "$BOTH_SHA_ACTUAL" != "$(file_sha "$BOTH_DECOY")" ]; then
  check "F3 tool_input.plan supplies the approved bytes, not its planFilePath" PASS
else
  check "F3 precedence (sha=$BOTH_SHA_ACTUAL out='$(printf '%s' "$OUT3" | head -c 120)')" FAIL
fi

# --- F8 an empty plan string is treated as absent, not as a block ---
arm_run emptyplan emptyplan_session emptyplan_run || { echo "F8 fixture failed" >&2; exit 1; }
EMPTY_PLAN_FILE="$TMP/emptyplan-plan.md"
printf '# Fallback used\n\n<!-- zensu-autopilot:emptyplan_run -->\n' > "$EMPTY_PLAN_FILE"
OUT8="$(invoke "$(payload emptyplan_session "" "$EMPTY_PLAN_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT8" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$EMPTY_PLAN_FILE")" ]; then
  check "F8 an empty plan string falls back to the file instead of blocking" PASS
else
  check "F8 empty plan string did not fall back (out='$OUT8')" FAIL
fi

# --- F24 the response plan alone: the source a stripped tool_input leaves ---
arm_run resplan resplan_session resplan_run || { echo "F24 fixture failed" >&2; exit 1; }
RESPONSE_PLAN="# Plan from the tool response

Implement it.

<!-- zensu-autopilot:resplan_run -->"
OUT24="$(invoke "$(payload_response resplan_session "$RESPONSE_PLAN" __ABSENT__)" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
RESPONSE_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT24" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$RESPONSE_SHA_ACTUAL" = "$(text_sha "$RESPONSE_PLAN")" ]; then
  check "F24 a tool_response.plan approves and digests the response text" PASS
else
  check "F24 response plan (sha=$RESPONSE_SHA_ACTUAL out='$(printf '%s' "$OUT24" | head -c 160)')" FAIL
fi

# --- F25 the response file path: same hardened reader as planFilePath ---
arm_run respath respath_session respath_run || { echo "F25 fixture failed" >&2; exit 1; }
RESPONSE_FILE="$TMP/response-plan.md"
printf '# Plan on disk via the response\n\n<!-- zensu-autopilot:respath_run -->\n' > "$RESPONSE_FILE"
OUT25="$(invoke "$(payload_response respath_session __ABSENT__ "$RESPONSE_FILE")" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT25" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$RESPONSE_FILE")" ]; then
  check "F25 a tool_response.filePath approves and digests the file bytes" PASS
else
  check "F25 response path (out='$(printf '%s' "$OUT25" | head -c 160)')" FAIL
fi

# --- F26 an input plan still outranks the response ---
arm_run inputwins inputwins_session inputwins_run || { echo "F26 fixture failed" >&2; exit 1; }
INPUT_WINS_PLAN="# Input plan wins

<!-- zensu-autopilot:inputwins_run -->"
RESPONSE_LOSES_PLAN="# Response plan loses

<!-- zensu-autopilot:inputwins_run -->"
OUT26="$(invoke "$(payload_input_and_response inputwins_session "$INPUT_WINS_PLAN" "$RESPONSE_LOSES_PLAN")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
OUT26_SHA="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT26" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$OUT26_SHA" = "$(text_sha "$INPUT_WINS_PLAN")" ] \
  && [ "$OUT26_SHA" != "$(text_sha "$RESPONSE_LOSES_PLAN")" ]; then
  check "F26 tool_input.plan still outranks a differing tool_response.plan" PASS
else
  check "F26 precedence (sha=$OUT26_SHA)" FAIL
fi

# --- F27 the response plan outranks its own filePath. The decoy is a REAL,
# readable file carrying the same active marker, so it would pass every
# downstream check: only the persisted digest says which byte source won. A
# nonexistent decoy could not discriminate, because an implementation that opens
# it and discards the result would look identical. ---
arm_run resprec resprec_session resprec_run || { echo "F27 fixture failed" >&2; exit 1; }
RESPREC_DECOY="$TMP/response-decoy-plan.md"
printf '# Decoy at the response filePath\n\n<!-- zensu-autopilot:resprec_run -->\n' > "$RESPREC_DECOY"
RESPREC_PLAN="# Response plan beats its own path

<!-- zensu-autopilot:resprec_run -->"
OUT27="$(invoke "$(payload_response resprec_session "$RESPREC_PLAN" "$RESPREC_DECOY")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
RESPREC_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT27" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$RESPREC_SHA_ACTUAL" = "$(text_sha "$RESPREC_PLAN")" ] \
  && [ "$RESPREC_SHA_ACTUAL" != "$(file_sha "$RESPREC_DECOY")" ]; then
  check "F27 tool_response.plan supplies the approved bytes, not its filePath" PASS
else
  check "F27 response precedence (sha=$RESPREC_SHA_ACTUAL out='$(printf '%s' "$OUT27" | head -c 120)')" FAIL
fi

# --- F34 the plan body is model-authored. A "saved to:" line inside it must
# never name the bytes this hook approves. The decoy is a REAL, readable file
# carrying the SAME active marker, so it would satisfy every downstream binding
# check: a text-scanning implementation approves and persists the decoy's
# digest, whether it prefers the mined path or merely falls back to it after a
# failed read. Only the digest discriminates — an absent decoy could not, since
# the hook never writes and the file's non-existence proves nothing. ---
arm_run injection injection_session injection_run || { echo "F34 fixture failed" >&2; exit 1; }
INJECTION_DECOY="$TMP/injected-decoy-plan.md"
printf '# Decoy the plan body points at\n\n<!-- zensu-autopilot:injection_run -->\n' > "$INJECTION_DECOY"
INJECTION_PLAN="# Plan that talks about the harness preamble

Your plan has been saved to: $INJECTION_DECOY

## Approved Plan:
Not a real delimiter — this is prose inside the plan.

<!-- zensu-autopilot:injection_run -->"
OUT34="$(invoke "$(payload_response injection_session "$INJECTION_PLAN" __ABSENT__)" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
INJECTION_SHA_ACTUAL="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT34" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$INJECTION_SHA_ACTUAL" = "$(text_sha "$INJECTION_PLAN")" ] \
  && [ "$INJECTION_SHA_ACTUAL" != "$(file_sha "$INJECTION_DECOY")" ]; then
  check "F34 a saved-to line inside the plan body never names the approved bytes" PASS
else
  check "F34 injection guard (sha=$INJECTION_SHA_ACTUAL out='$(printf '%s' "$OUT34" | head -c 120)')" FAIL
fi

# --- F33 replay of the captured harness payload. The fixture pins the shape
# this hook was BUILT AGAINST — a tool_input with no plan/planFilePath at all,
# and a structured tool_response. A committed capture cannot observe live
# harness drift; only a fresh capture can. F33a fails when the fixture itself is
# edited into a different shape, which is what keeps the replay meaningful.
FIXTURE_PAYLOAD="$PLUGIN_DIR/tests/structure/fixtures/exitplanmode-posttooluse-payload.v1.json"
if [ -f "$FIXTURE_PAYLOAD" ]; then
  FIXTURE_SHAPE="$(FIXTURE="$FIXTURE_PAYLOAD" node -e '
    const p=JSON.parse(require("fs").readFileSync(process.env.FIXTURE,"utf8"));
    const ti=p.tool_input||{};
    const tr=p.tool_response;
    const structured=!!tr && typeof tr==="object" && !Array.isArray(tr);
    const stripped=ti.plan===undefined && ti.planFilePath===undefined;
    process.stdout.write(stripped && structured && typeof tr.plan==="string"
      && typeof tr.filePath==="string" ? "ok" : "drifted");
  ' 2>/dev/null)"
else
  FIXTURE_SHAPE="missing"
fi

arm_run replay replay_session replay_run || { echo "F33 fixture failed" >&2; exit 1; }
REPLAY_PLAN="# Replayed harness payload

<!-- zensu-autopilot:replay_run -->"
REPLAY_PAYLOAD="$(FIXTURE="$FIXTURE_PAYLOAD" SID=replay_session RPLAN="$REPLAY_PLAN" node -e '
  const p=JSON.parse(require("fs").readFileSync(process.env.FIXTURE,"utf8"));
  delete p.__provenance;
  p.session_id=process.env.SID;
  p.tool_response.plan=process.env.RPLAN;
  process.stdout.write(JSON.stringify(p));
')"
OUT33="$(invoke "$REPLAY_PAYLOAD" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT33" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$REPLAY_PLAN")" ]; then
  check "F33 the captured harness payload approves through the response source" PASS
else
  check "F33 captured payload replay (out='$(printf '%s' "$OUT33" | head -c 160)')" FAIL
fi
if [ "$FIXTURE_SHAPE" = ok ]; then
  check "F33a the captured fixture still has a stripped input and a structured response" PASS
else
  check "F33a captured fixture shape (got=$FIXTURE_SHAPE)" FAIL
fi

# --- F42 an empty tool_response.plan is absent, not a block: the chain must
# reach the response's own filePath. Without this the `if (!value) continue`
# guard could be deleted with the whole suite green. ---
arm_run emptyresp emptyresp_session emptyresp_run || { echo "F42 fixture failed" >&2; exit 1; }
EMPTY_RESP_FILE="$TMP/emptyresp-plan.md"
printf '# Reached through the response filePath\n\n<!-- zensu-autopilot:emptyresp_run -->\n' > "$EMPTY_RESP_FILE"
OUT42="$(invoke "$(payload_response emptyresp_session "" "$EMPTY_RESP_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT42" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(file_sha "$EMPTY_RESP_FILE")" ]; then
  check "F42 an empty tool_response.plan falls through to the response filePath" PASS
else
  check "F42 empty response plan (out='$(printf '%s' "$OUT42" | head -c 160)')" FAIL
fi

# --- F43 an empty tool_input.planFilePath must fall through to the response
# rather than being judged a non-absolute path. ---
arm_run emptyinpath emptyinpath_session emptyinpath_run || { echo "F43 fixture failed" >&2; exit 1; }
EMPTY_PATH_PLAN="# Reached through the response after an empty input path

<!-- zensu-autopilot:emptyinpath_run -->"
OUT43_PAYLOAD="$(SID=emptyinpath_session RPLAN="$EMPTY_PATH_PLAN" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{planFilePath:""},
    tool_response:{plan:process.env.RPLAN,isAgent:false,hasTaskTool:true}
  }));
')"
OUT43="$(invoke "$OUT43_PAYLOAD" "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
if printf '%s' "$OUT43" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)" = "$(text_sha "$EMPTY_PATH_PLAN")" ]; then
  check "F43 an empty tool_input.planFilePath falls through to the response" PASS
else
  check "F43 empty input path (out='$(printf '%s' "$OUT43" | head -c 160)')" FAIL
fi

# --- F44 the digest binds the bytes that TRAVELLED, and source 3 outranks
# source 4. When the two agree — as they did in the capture this was built
# against — either byte source yields the same digest, so the precedence choice
# is invisible downstream. This is the pin that would break first if a host ever
# delivered a response whose plan string and saved file disagree. ---
arm_run bothagree bothagree_session bothagree_run || { echo "F44 fixture failed" >&2; exit 1; }
AGREE_FILE="$TMP/agreeing-plan.md"
printf '# Response plan and file agree\n\n<!-- zensu-autopilot:bothagree_run -->\n' > "$AGREE_FILE"
AGREE_PLAN="$(cat "$AGREE_FILE")
"
OUT44="$(invoke "$(payload_response bothagree_session "$AGREE_PLAN" "$AGREE_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
AGREE_VIA_TEXT="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
# Source 3 answered above and never opened the file. Re-deliver the SAME bytes
# through source 4 alone so the file is actually read, and require both routes to
# land the same digest — that is the claim, and it needs both invocations.
OUT44B="$(invoke "$(payload_response bothagree_session __ABSENT__ "$AGREE_FILE")" \
  "$ARMED_PROJECT" "$CFG_OFF" "$ARMED_DATA")"
AGREE_VIA_FILE="$(run_field "$ARMED_RUN_FILE" approvedPlanSha256)"
if printf '%s' "$OUT44" | grep -qF 'PLAN_APPROVED runId=' \
  && printf '%s' "$OUT44B" | grep -qF 'PLAN_APPROVED runId=' \
  && [ "$AGREE_VIA_TEXT" = "$(text_sha "$AGREE_PLAN")" ] \
  && [ "$AGREE_VIA_FILE" = "$(file_sha "$AGREE_FILE")" ] \
  && [ "$AGREE_VIA_TEXT" = "$AGREE_VIA_FILE" ]; then
  check "F44 agreeing response fields yield one digest through either source" PASS
else
  check "F44 response byte agreement (text=$AGREE_VIA_TEXT file=$AGREE_VIA_FILE)" FAIL
fi

# --- Every refusal shares one run: none of them may mutate it by a single byte ---
arm_run refuse refuse_session refuse_run || { echo "refuse fixture failed" >&2; exit 1; }
REFUSE_PROJECT="$ARMED_PROJECT"
REFUSE_DATA="$ARMED_DATA"
REFUSE_RUN_FILE="$ARMED_RUN_FILE"
REFUSE_BEFORE="$(digest "$REFUSE_RUN_FILE")"

# A refusal must name its code, leave the run record byte-identical, and never
# fall through to the standalone ask-first directive.
# $4 is optional: the payload field the receipt must name, or __NONE__ to assert
# the receipt names no field at all. The source clause is the only operator-
# facing difference between a bad path the tool call named and one the harness
# owns, and their repairs differ, so it is asserted rather than assumed.
refuses_with() {
  local label="$1" code="$2" out="$3" want_source="${4:-}"
  local clause='The payload field carrying the plan was'
  local source_ok=true
  if [ -n "$want_source" ]; then
    if [ "$want_source" = __NONE__ ]; then
      printf '%s' "$out" | grep -qF "$clause" && source_ok=false
    else
      printf '%s' "$out" | grep -qF "$clause $want_source." || source_ok=false
    fi
  fi
  if printf '%s' "$out" | grep -qF "code=$code" \
    && [ "$source_ok" = true ] \
    && [ "$(digest "$REFUSE_RUN_FILE")" = "$REFUSE_BEFORE" ] \
    && ! printf '%s' "$out" | grep -qF 'AskUserQuestion'; then
    check "$label" PASS
  else
    check "$label (out='$(printf '%s' "$out" | head -c 200)')" FAIL
  fi
}

refuses_with "F4 a payload with neither field blocks as INVALID_PLAN_PAYLOAD" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$(payload refuse_session __ABSENT__ __ABSENT__)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  __NONE__

refuses_with "F5 a nonexistent planFilePath reports PLAN_FILE_UNREADABLE" \
  PLAN_FILE_UNREADABLE \
  "$(invoke "$(payload refuse_session __ABSENT__ "$TMP/no-such-plan.md")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  tool_input.planFilePath

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
MAX_BYTES="$PLAN_MAX_BYTES" node -e '
  const fs=require("fs");
  fs.closeSync(fs.openSync(process.argv[1],"w"));
  fs.truncateSync(process.argv[1],Number(process.env.MAX_BYTES)+1);
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
# `ln -s` exiting 0 is not evidence of a symlink — Git Bash satisfies it with a
# copy native Node does not follow. Confirm through the same primitive the
# module decides with, or the refusal is graded against a fixture that is not a
# link at all.
SYMLINK_READY=false
if ln -s "$LINK_TARGET" "$LINK_PATH" 2>/dev/null \
  && LINK_PATH="$LINK_PATH" node -e 'process.exit(require("fs").lstatSync(process.env.LINK_PATH).isSymbolicLink()?0:1)' 2>/dev/null; then
  SYMLINK_READY=true
fi
SKIPPED=0
skipped() { echo "  SKIP  $1"; SKIPPED=$((SKIPPED + 1)); }
if [ "$SYMLINK_READY" = true ]; then
  refuses_with "F17 a symlinked planFilePath is refused, not silently followed" \
    PLAN_FILE_SYMLINK_REJECTED \
    "$(invoke "$(payload refuse_session __ABSENT__ "$LINK_PATH")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"
else
  skipped "F17 symlink refusal: this platform cannot create a symlink"
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
  "$(invoke "$(payload_nonstring_plan refuse_session "$PLAN_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  tool_input.plan

F21B_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{planFilePath:["not","a","string"]}
  }));
')"
refuses_with "F21a a non-string planFilePath is a field-type refusal, not a missing payload" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$F21B_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F28/F29 response-fed bytes face the same run-binding checks as inline text ---
refuses_with "F28 a marker-free tool_response.plan still reports PLAN_MARKER_MISSING_OR_AMBIGUOUS" \
  PLAN_MARKER_MISSING_OR_AMBIGUOUS \
  "$(invoke "$(payload_response refuse_session '# A response plan with no autopilot marker' __ABSENT__)" \
    "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  tool_response.plan

refuses_with "F29 a tool_response.plan naming a foreign run reports PLAN_MARKER_RUN_MISMATCH" \
  PLAN_MARKER_RUN_MISMATCH \
  "$(invoke "$(payload_response refuse_session '# Someone else run

<!-- zensu-autopilot:a_foreign_run -->' __ABSENT__)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F30 a response field of the wrong type is refused, not skipped past ---
refuses_with "F30 a non-string tool_response.plan is a field-type refusal" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$(payload_response_nonstring refuse_session plan)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F30a a non-string tool_response.filePath is a field-type refusal" \
  PLAN_PAYLOAD_FIELD_TYPE_REJECTED \
  "$(invoke "$(payload_response_nonstring refuse_session filePath)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F31 a response that carries no named plan field is simply absent. The
# string shape is the decisive one: it is the rendered text the model sees, and
# it names an EXISTING readable plan file whose marker belongs to another run.
# Mining that text would surface PLAN_MARKER_RUN_MISMATCH; refusing to mine it
# is what keeps the receipt at INVALID_PLAN_PAYLOAD. ---
refuses_with "F31 a null tool_response leaves the missing-payload receipt" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$(payload_response_shape refuse_session null __ABSENT__)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F31a an array tool_response leaves the missing-payload receipt" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$(payload_response_shape refuse_session array __ABSENT__)" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# F31b's discrimination depends on the named path being readable AND carrying a
# marker for a different run: a miner would then surface PLAN_MARKER_RUN_MISMATCH
# instead of the missing-payload receipt. Assert the premise rather than trusting
# a fixture built earlier in the file.
if [ -f "$PLAN_FILE" ] && grep -qF 'zensu-autopilot:pathonly_run' "$PLAN_FILE"; then
  check "F31b-pre the decoy named by the rendered response exists and names a foreign run" PASS
else
  check "F31b-pre decoy premise broken ($PLAN_FILE)" FAIL
fi
refuses_with "F31b a rendered string tool_response is never mined for a plan or a path" \
  INVALID_PLAN_PAYLOAD \
  "$(invoke "$(payload_response_shape refuse_session string "$PLAN_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# F31c carries an unrelated STRING-valued field naming a real plan file, so an
# implementation that scans the response's values instead of its named fields is
# caught here too — a response with no string at all could not catch it.
F31C_PAYLOAD="$(MSYS2_ENV_CONV_EXCL="$MSYS_EXCL" SID=refuse_session PLAN_PATH="$PLAN_FILE" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"ExitPlanMode", tool_input:{_targetMode:"auto"},
    tool_response:{isAgent:false,hasTaskTool:true,
      message:"Your plan has been saved to: "+process.env.PLAN_PATH}
  }));
')"
refuses_with "F31c a response object with neither named field leaves the missing-payload receipt" \
  INVALID_PLAN_PAYLOAD "$(invoke "$F31C_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# --- F35-F41 the hardened reader guards source 4 exactly as it guards source 2.
# Without these, replacing the response path's read with a bare readFileSync
# would leave F25/F27/F33 green: the only other response-path cases refuse on
# ownership before the reader is ever reached. ---
refuses_with "F35 a nonexistent tool_response.filePath reports PLAN_FILE_UNREADABLE" \
  PLAN_FILE_UNREADABLE \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$TMP/no-such-plan.md")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")" \
  tool_response.filePath

refuses_with "F36 a directory at tool_response.filePath reports PLAN_FILE_NOT_REGULAR" \
  PLAN_FILE_NOT_REGULAR \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$DIR_PATH")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F37 an empty file at tool_response.filePath reports PLAN_FILE_EMPTY" \
  PLAN_FILE_EMPTY \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$EMPTY_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F38 a relative tool_response.filePath is rejected before any filesystem access" \
  PLAN_FILE_PATH_REJECTED \
  "$(invoke "$(payload_response refuse_session __ABSENT__ 'relative/plan.md')" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F39 a UNC-style tool_response.filePath is rejected before any filesystem access" \
  PLAN_FILE_PATH_REJECTED \
  "$(invoke "$(payload_response refuse_session __ABSENT__ '//attacker.example.com/share/plan.md')" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

refuses_with "F40 an oversize file at tool_response.filePath reports PLAN_FILE_TOO_LARGE" \
  PLAN_FILE_TOO_LARGE \
  "$(invoke "$(payload_response refuse_session __ABSENT__ "$OVERSIZE_FILE")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

if [ "$SYMLINK_READY" = true ]; then
  refuses_with "F41 a symlinked tool_response.filePath is refused, not silently followed" \
    PLAN_FILE_SYMLINK_REJECTED \
    "$(invoke "$(payload_response refuse_session __ABSENT__ "$LINK_PATH")" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"
else
  skipped "F41 symlink refusal via the response: this platform cannot create a symlink"
fi

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

# --- F32 the response source does not reopen the ownership hole F20 closes ---
OUT32="$(invoke "$(payload_response foreign_plan_session __ABSENT__ "$PLAN_FILE")" \
  "$REFUSE_PROJECT" "$CFG_OFF" "$PROVISIONED_DATA")"
if printf '%s' "$OUT32" | grep -qF 'code=OWNER_SESSION_MISMATCH' \
  && [ "$(digest "$REFUSE_RUN_FILE")" = "$REFUSE_BEFORE" ]; then
  check "F32 a foreign session naming a response filePath is refused on ownership" PASS
else
  check "F32 foreign response session (out='$(printf '%s' "$OUT32" | head -c 200)')" FAIL
fi
OUT32B="$(invoke "$(payload_response foreign_plan_session __ABSENT__ "$TMP/no-such-plan.md")" \
  "$REFUSE_PROJECT" "$CFG_OFF" "$PROVISIONED_DATA")"
if [ "$OUT32B" = "$OUT32" ]; then
  check "F32a the response source is no existence oracle either" PASS
else
  check "F32a response receipt differs by path existence for an unauthorized caller" FAIL
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

# --- F11b the module's own decision table and reader, pinned by BEHAVIOR in a
# node --test sibling rather than by grepping its source text. The shell layer
# cannot reach a NUL-byte path, a bare-string carrier, or a hard link; the unit
# suite can. Driven from here the way test-chain-recover.sh drives its own.
PLAN_LIB="$PLUGIN_DIR/hooks/lib/plan-payload-v1.js"
PLAN_UNIT="$PLUGIN_DIR/tests/structure/plan-payload-v1.test.js"
PLAN_UNIT_OUT="$TMP/plan-unit.out"
if [ -f "$PLAN_LIB" ] && [ -f "$PLAN_UNIT" ] \
  && ZENSU_PLAN_PAYLOAD_UNIT_TARGET="$PLAN_LIB" node --test "$PLAN_UNIT" > "$PLAN_UNIT_OUT" 2>&1; then
  check "F11b the plan-payload module unit suite passes" PASS
else
  check "F11b the plan-payload module unit suite failed or is missing" FAIL
  [ -f "$PLAN_UNIT_OUT" ] && grep -B2 -A 20 '^not ok' "$PLAN_UNIT_OUT" | head -40
fi

# --- F11b-tool the tool-name guard, pinned behaviorally. A payload from another
# tool carrying an otherwise perfect plan must refuse AND leave the run record
# untouched — without the guard it would approve and mutate it.
F11B_PAYLOAD="$(SID=refuse_session node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name:"PostToolUse", session_id:process.env.SID,
    tool_name:"Read", tool_input:{_targetMode:"auto"},
    tool_response:{plan:"# Not from ExitPlanMode\n\n<!-- zensu-autopilot:refuse_run -->",
      isAgent:false,hasTaskTool:true}
  }));
')"
refuses_with "F11b-tool a payload from another tool never reaches the plan reader" \
  PLAN_PAYLOAD_TOOL_MISMATCH "$(invoke "$F11B_PAYLOAD" "$REFUSE_PROJECT" "$CFG_OFF" "$REFUSE_DATA")"

# The module decides WHICH field is read; the hook owns the exit ladder and the
# emission. Pin the delegation itself, not a mention of the file name, and ban
# every reader primitive rather than one flag spelling.
if grep -Eq 'require\(process\.env\.PLAN_PAYLOAD_LIB\)' "$HOOK" \
  && grep -Eq 'PLAN_PAYLOAD_LIB=' "$HOOK" \
  && ! grep -Eq 'openSync|fstatSync|lstatSync|isSymbolicLink|O_NOFOLLOW|readFileSync\(process|readSync|realpathSync' "$HOOK"; then
  check "F11c the hook delegates plan resolution instead of re-implementing the reader" PASS
else
  check "F11c the hook still carries its own plan reader" FAIL
fi

# --- F11d every reason the module can return must map to an exit code the hook
# claims, and that code must map back to the identically named BLOCK_CODE. The
# integer hop is invisible to every behavioral case, so a ninth reason would
# otherwise ship a misattributing receipt with the suite green.
if PLAN_LIB="$PLAN_LIB" HOOK="$HOOK" node -e '
  const fs=require("fs");
  const {REASONS}=require(process.env.PLAN_LIB);
  const src=fs.readFileSync(process.env.HOOK,"utf8");
  const exits=new Map();
  for (const m of src.matchAll(/EXITS\[REASONS\.([A-Z_]+)\]=(\d+);/g)) exits.set(m[1],m[2]);
  const arms=new Map();
  for (const m of src.matchAll(/^\s*(\d+)\)\s*BLOCK_CODE=([A-Z_]+)\s*;;/gm)) arms.set(m[1],m[2]);
  for (const [key,value] of Object.entries(REASONS)) {
    const code=exits.get(key);
    if (!code) { console.error("unmapped reason "+key); process.exit(1); }
    if (arms.get(code)!==value) { console.error("exit "+code+" is not "+value); process.exit(1); }
  }
' 2>/dev/null; then
  check "F11d every module reason maps to an exit code and back to its own block code" PASS
else
  check "F11d the reason/exit/block-code mapping has drifted" FAIL
fi

# The plan is only ever read from the payload — never guessed by scanning a
# plans directory, which would race concurrent sessions onto the wrong digest.
# --- F11e an apostrophe inside a single-quoted `node -e '...'` program ends the
# shell string; the rest of the JS is then parsed as shell. `bash -n` still
# passes, so F0 cannot catch it — the whole suite went to 12 PASS / 48 FAIL once
# for exactly this, from one word in a comment. Fail at the site instead.
APOSTROPHE_REPORT="$(HOOK="$HOOK" node -e '
  const src=require("fs").readFileSync(process.env.HOOK,"utf8");
  const opened=(src.match(/node -e \x27/g)||[]).length;
  // Two terminator layouts: the closing quote on its own line, or on the same
  // line as the last statement. Both must be recognized — a body the extractor
  // silently misses would make an apostrophe count of 0 mean nothing.
  const bodies=[...src.matchAll(/node -e \x27([\s\S]*?)\x27[^\x27\n]*$/gm)].map(m=>m[1]);
  const bad=bodies.filter(b=>b.includes(String.fromCharCode(39))).length;
  process.stdout.write(opened+" "+bodies.length+" "+bad);
' 2>/dev/null)"
read -r APOS_OPENED APOS_FOUND APOS_BAD <<<"$APOSTROPHE_REPORT"
if [ -n "${APOS_BAD:-}" ] && [ "$APOS_OPENED" = "$APOS_FOUND" ] && [ "$APOS_BAD" = 0 ]; then
  check "F11e every single-quoted node program in the hook was scanned and none carries an apostrophe" PASS
else
  check "F11e apostrophe scan (opened=${APOS_OPENED:-?} scanned=${APOS_FOUND:-?} carrying=${APOS_BAD:-?})" FAIL
fi

# The reader now lives in the module, so the pin has to follow it there. Require
# the module to EXIST: a negative grep is also true for a file that is gone.
if [ -f "$PLAN_LIB" ] \
  && ! grep -Eq 'zensu/plans|claude/plans|plans/\*|readdirSync|opendirSync|globSync' "$HOOK" \
  && ! grep -Eq 'zensu/plans|claude/plans|plans/\*|readdirSync|opendirSync|globSync' "$PLAN_LIB"; then
  check "F11a neither the hook nor the module scans a plans directory to guess the plan" PASS
else
  check "F11a a plans directory is scanned" FAIL
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
echo "test-plan-payload-fallback: $PASS PASS / $FAIL FAIL / $SKIPPED SKIP"
[ "$FAIL" -eq 0 ]
