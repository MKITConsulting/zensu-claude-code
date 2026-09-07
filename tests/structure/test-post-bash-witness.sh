#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/post-bash-witness.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"
SESSION_CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"
XCHK="$PLUGIN_DIR/hooks/lib/zensu-evidence-crosscheck.js"; export XCHK

ZENSU_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"; export ZENSU_CONFIG

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

session_key() {
  node "$SESSION_CORE" session-key "$1"
}

witness_file() {
  printf '%s/.zensu/logs/witness-%s.log' "$1" "$(session_key "$2")"
}

if [ ! -f "$HOOK" ]; then
  check "hooks/post-bash-witness.sh exists" FAIL
  echo "----"
  echo "test-post-bash-witness: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "hooks/post-bash-witness.sh exists" PASS

if bash -n "$HOOK" 2>/dev/null; then
  check "P12-H1 bash -n syntax check passes" PASS
else
  check "P12-H1 bash -n syntax check passes" FAIL
fi

activate() {
  export CLAUDE_PROJECT_DIR="$1"
  export ZENSU_TEST_PLUGIN_DATA="$1/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$2" || return 1
  bash "$LOG" --tdd-begin --session "$2" >/dev/null 2>&1
}

baseline() {
  export CLAUDE_PROJECT_DIR="$1"
  export ZENSU_TEST_PLUGIN_DATA="$1/plugin-data"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/tests/session-control/initialize-baseline.sh" "$2"
}

make_payload() {
  local cmd="$1" exit_code="$2" stdout="$3" session_id="$4" interrupted="${5:-false}"
  local cmd_json exit_json stdout_json session_json
  cmd_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$cmd")"
  stdout_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$stdout")"
  session_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$session_id")"
  if [ "$exit_code" = "null" ]; then exit_json="null"; else exit_json="$exit_code"; fi
  printf '{"hook_event_name":"PostToolUse","tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":%s,"interrupted":%s},"session_id":%s}' \
    "$cmd_json" "$exit_json" "$stdout_json" "$interrupted" "$session_json"
}

PROJECT_TMP="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION="sess-h2-$$"
activate "$PROJECT_TMP" "$SESSION"
PAYLOAD1=$(make_payload "npm test" 0 "PASS root/test.js" "$SESSION")
PAYLOAD2=$(make_payload "pytest -v" 0 "1 passed" "$SESSION")
PAYLOAD3=$(make_payload "go test ./..." 0 "ok    pkg/foo" "$SESSION")
PAYLOAD4=$(make_payload "bash tests/structure/test-foo.sh" 0 "PASS" "$SESSION")
for P in "$PAYLOAD1" "$PAYLOAD2" "$PAYLOAD3" "$PAYLOAD4"; do
  echo "$P" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP" STATE_DIR="$PROJECT_TMP/.zensu/state" bash "$HOOK" >/dev/null 2>&1
done
WITNESS="$(witness_file "$PROJECT_TMP" "$SESSION")"
COUNT_NPM=$(grep -cF 'cmd="npm test"' "$WITNESS" 2>/dev/null || echo 0)
COUNT_PYT=$(grep -cF 'cmd="pytest -v"' "$WITNESS" 2>/dev/null || echo 0)
COUNT_GO=$(grep -cF 'cmd="go test ./..."' "$WITNESS" 2>/dev/null || echo 0)
COUNT_BASH=$(grep -cF 'cmd="bash tests/structure/test-foo.sh"' "$WITNESS" 2>/dev/null || echo 0)
if [ "$COUNT_NPM" = "1" ] && [ "$COUNT_PYT" = "1" ] && [ "$COUNT_GO" = "1" ] && [ "$COUNT_BASH" = "1" ]; then
  check "P12-H2 active session + 4 distinct commands -> 4 witness entries (no pattern filter)" PASS
else
  check "P12-H2 4 entries (npm=$COUNT_NPM pyt=$COUNT_PYT go=$COUNT_GO bash=$COUNT_BASH)" FAIL
fi
rm -rf "$PROJECT_TMP"

PROJECT_TMP_H3="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H3="sess-h3-$$"
baseline "$PROJECT_TMP_H3" "$SESSION_H3"
P_H3=$(make_payload "npm test" 0 "PASS" "$SESSION_H3")
echo "$P_H3" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H3" STATE_DIR="$PROJECT_TMP_H3/.zensu/state" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$(witness_file "$PROJECT_TMP_H3" "$SESSION_H3")" ]; then
  check "P12-H3 session not activated -> no witness log written (chain-state scope guard)" PASS
else
  check "P12-H3 session not activated -> no witness log (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H3"

PROJECT_TMP_H4="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H4="sess-h4-$$"
baseline "$PROJECT_TMP_H4" "$SESSION_H4"
P_H4=$(make_payload "npm test" 0 "PASS" "$SESSION_H4")
echo "$P_H4" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP_H4" STATE_DIR="$PROJECT_TMP_H4/.zensu/state" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$(witness_file "$PROJECT_TMP_H4" "$SESSION_H4")" ]; then
  check "P12-H4 CLAUDE_AGENT_TYPE set but session not activated -> no witness (legacy CAT no longer activates)" PASS
else
  check "P12-H4 CLAUDE_AGENT_TYPE set without activation -> no witness (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H4"

PROJECT_TMP_H5="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H5="sess-h5-$$"
activate "$PROJECT_TMP_H5" "$SESSION_H5"
P_H5=$(make_payload "npm test" 0 "PASS" "$SESSION_H5")
echo "$P_H5" | env ZENSU_TEST_WITNESS=off CLAUDE_PROJECT_DIR="$PROJECT_TMP_H5" STATE_DIR="$PROJECT_TMP_H5/.zensu/state" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$(witness_file "$PROJECT_TMP_H5" "$SESSION_H5")" ]; then
  check "P12-H5 ZENSU_TEST_WITNESS=off + active session -> no witness log (opt-out overrides active)" PASS
else
  check "P12-H5 ZENSU_TEST_WITNESS=off -> no witness log (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H5"

PROJECT_TMP_H6="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H6="sess-h6-$$"
activate "$PROJECT_TMP_H6" "$SESSION_H6"
P_H6A=$(make_payload "cmd1" 0 "out1" "$SESSION_H6")
P_H6B=$(make_payload "cmd2" 1 "out2" "$SESSION_H6")
P_H6C=$(make_payload "cmd3" 0 "out3" "$SESSION_H6")
for P in "$P_H6A" "$P_H6B" "$P_H6C"; do
  echo "$P" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H6" STATE_DIR="$PROJECT_TMP_H6/.zensu/state" bash "$HOOK" >/dev/null 2>&1
done
WITNESS_H6="$(witness_file "$PROJECT_TMP_H6" "$SESSION_H6")"
LINE_COUNT=$(wc -l <"$WITNESS_H6" 2>/dev/null | tr -d ' ')
if [ "$LINE_COUNT" = "3" ] \
   && grep -qF 'cmd="cmd1"' "$WITNESS_H6" \
   && grep -qF 'cmd="cmd2"' "$WITNESS_H6" \
   && grep -qF 'cmd="cmd3"' "$WITNESS_H6"; then
  check "P12-H6 multiple invocations same session -> single accumulating witness log (3 lines)" PASS
else
  check "P12-H6 accumulation (got lines=$LINE_COUNT)" FAIL
fi
rm -rf "$PROJECT_TMP_H6"

PROJECT_TMP_H7="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H7="sess-h7-$$"
activate "$PROJECT_TMP_H7" "$SESSION_H7"
TRICKY_CMD='echo "hello \"world\"" && printf "a\nb"'
P_H7=$(make_payload "$TRICKY_CMD" 0 "ok" "$SESSION_H7")
printf '%s\n' "$P_H7" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H7" STATE_DIR="$PROJECT_TMP_H7/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H7="$(witness_file "$PROJECT_TMP_H7" "$SESSION_H7")"
EXTRACTED_CMD=$(node -e '
  const fs = require("fs");
  const raw = fs.readFileSync(process.argv[1], "utf8").split("\n")[0];
  const m = raw.match(/cmd=(".*?(?<!\\)") exit=/);
  if (m) process.stdout.write(JSON.parse(m[1]));
  else process.stdout.write("UNPARSEABLE");
' "$WITNESS_H7" 2>/dev/null)
if [ "$EXTRACTED_CMD" = "$TRICKY_CMD" ]; then
  check "P12-H7 quote-safe JSON-escape: tricky cmd round-trips through JSON.parse" PASS
else
  check "P12-H7 round-trip (expected=$TRICKY_CMD, got=$EXTRACTED_CMD)" FAIL
fi
rm -rf "$PROJECT_TMP_H7"

PROJECT_TMP_H8="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H8="sess-h8-$$"
activate "$PROJECT_TMP_H8" "$SESSION_H8"
NO_RESPONSE_PAYLOAD=$(printf '{"hook_event_name":"PostToolUse","tool_input":{"command":"echo hi"},"session_id":"%s"}' "$SESSION_H8")
echo "$NO_RESPONSE_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H8" STATE_DIR="$PROJECT_TMP_H8/.zensu/state" bash "$HOOK" >/dev/null 2>&1
RC_H8=$?
WITNESS_H8="$(witness_file "$PROJECT_TMP_H8" "$SESSION_H8")"
if [ "$RC_H8" = "0" ] && [ -f "$WITNESS_H8" ] && grep -qF 'cmd="echo hi"' "$WITNESS_H8" && grep -qF 'exit=?' "$WITNESS_H8"; then
  check "P12-H8 missing tool_response: graceful (exit 0, exit=? placeholder, still logs)" PASS
else
  check "P12-H8 missing tool_response (rc=$RC_H8, witness contents below)" FAIL
fi
rm -rf "$PROJECT_TMP_H8"

ORIG_PWD="$PWD"
PROJECT_TMP_H9="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H9="sess-h9-$$"
activate "$PROJECT_TMP_H9" "$SESSION_H9"
P_H9=$(make_payload "echo h9" 0 "ok" "$SESSION_H9")
echo "$P_H9" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H9" STATE_DIR="$PROJECT_TMP_H9/.zensu/state" bash "$HOOK" >/dev/null 2>&1
H9_OVERRIDE=$([ -f "$(witness_file "$PROJECT_TMP_H9" "$SESSION_H9")" ] && echo "yes" || echo "no")
CWD_TMP="$(mktemp -d -t "witness-cwd-XXXXXX")"
cd "$CWD_TMP"
SESSION_H9B="sess-h9b-$$"
env CLAUDE_PROJECT_DIR="." bash "$LOG" --tdd-begin --session "$SESSION_H9B" >/dev/null 2>&1
P_H9B=$(make_payload "echo h9b" 0 "ok" "$SESSION_H9B")
echo "$P_H9B" | env -i PATH="$PATH" bash "$HOOK" >/dev/null 2>&1
H9_FALLBACK=$([ -f "$(witness_file . "$SESSION_H9B")" ] && echo "yes" || echo "no")
cd "$ORIG_PWD"
if [ "$H9_OVERRIDE" = "yes" ] && [ "$H9_FALLBACK" = "no" ]; then
  check "P12-H9 Session Control project context is honored; ambient cwd fallback is rejected" PASS
else
  check "P12-H9 context-only path resolution (context=$H9_OVERRIDE ambient_fallback=$H9_FALLBACK)" FAIL
fi
rm -rf "$PROJECT_TMP_H9" "$CWD_TMP"

PROJECT_TMP_H10="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H10="sess-h10-$$"
activate "$PROJECT_TMP_H10" "$SESSION_H10"
P_H10=$(make_payload "npm test" 0 "PASS root/test.js" "$SESSION_H10")
echo "$P_H10" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H10" STATE_DIR="$PROJECT_TMP_H10/.zensu/state" bash --posix "$HOOK" >/dev/null 2>&1
WITNESS_H10="$(witness_file "$PROJECT_TMP_H10" "$SESSION_H10")"
H10_LINE="$(head -n1 "$WITNESS_H10" 2>/dev/null)"
if printf '%s' "$H10_LINE" | grep -qE 'cmd="npm test" exit=0' \
   && printf '%s' "$H10_LINE" | grep -qF 'tail="PASS root/test.js"' \
   && ! printf '%s' "$H10_LINE" | grep -qF "$SESSION_H10"; then
  check "P12-H10 hook under bash --posix -> correct exit=0, tail= present, no session-id leak" PASS
else
  check "P12-H10 bash --posix field-split (line='${H10_LINE}')" FAIL
fi
rm -rf "$PROJECT_TMP_H10"

PROJECT_TMP_H11="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H11="sess-h11-$$"
activate "$PROJECT_TMP_H11" "$SESSION_H11"
P_H11=$(make_payload "npm test" 0 "PASS root/test.js" "$SESSION_H11")
echo "$P_H11" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H11" STATE_DIR="$PROJECT_TMP_H11/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H11="$(witness_file "$PROJECT_TMP_H11" "$SESSION_H11")"
H11_LINE="$(head -n1 "$WITNESS_H11" 2>/dev/null)"
if printf '%s' "$H11_LINE" | grep -qF 'cmd="npm test"' \
   && printf '%s' "$H11_LINE" | grep -qE 'exit=0' \
   && printf '%s' "$H11_LINE" | grep -qF 'tail="PASS root/test.js"' \
   && printf '%s' "$H11_LINE" | grep -qF 'interrupted=false'; then
  check "P12-H11 witness line carries tail= (stdout) + interrupted= fields" PASS
else
  check "P12-H11 tail+interrupted present (line='${H11_LINE}')" FAIL
fi
rm -rf "$PROJECT_TMP_H11"

PROJECT_TMP_H12="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H12="sess-h12-$$"
activate "$PROJECT_TMP_H12" "$SESSION_H12"
# Production-shaped Bash tool_response: stdout/stderr/interrupted/isImage, NO exit_code key
# (mirrors the real Claude Code payload, where exit_code is never present -> exit=?). Built
# with node so the JSON is guaranteed valid and omits exit_code exactly as production does.
H12_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PostToolUse",tool_input:{command:"node --test"},tool_response:{stdout:"tests 1\npass 1\nfail 0",stderr:"",interrupted:false,isImage:false},session_id:process.argv[1]}))' "$SESSION_H12")
printf '%s\n' "$H12_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H12" STATE_DIR="$PROJECT_TMP_H12/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H12="$(witness_file "$PROJECT_TMP_H12" "$SESSION_H12")"
H12_LINE="$(head -n1 "$WITNESS_H12" 2>/dev/null)"
if printf '%s' "$H12_LINE" | grep -qF 'cmd="node --test"' \
   && printf '%s' "$H12_LINE" | grep -qF 'exit=?' \
   && printf '%s' "$H12_LINE" | grep -qF 'tail="' \
   && printf '%s' "$H12_LINE" | grep -qF 'pass 1' \
   && printf '%s' "$H12_LINE" | grep -qF 'interrupted=false'; then
  check "P12-H12 production payload (no exit_code) -> exit=? AND tail= captured from real stdout" PASS
else
  check "P12-H12 production-shape tail capture (line='${H12_LINE}')" FAIL
fi
rm -rf "$PROJECT_TMP_H12"

PROJECT_TMP_H13="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H13="sess-h13-$$"
activate "$PROJECT_TMP_H13" "$SESSION_H13"
# Long multiline stdout (>200 chars). tail= must be the JSON-escaped last 200 chars on
# ONE physical line — proves the newline-delimited 5-field read never desyncs (bash 3.2 safe).
BIG_STDOUT="$(node -e 'let s="";for(let i=0;i<60;i++)s+="L"+i+"\n";process.stdout.write(s+"END-MARKER-ZZZ")')"
H13_PAYLOAD=$(make_payload "long-cmd" 0 "$BIG_STDOUT" "$SESSION_H13")
printf '%s\n' "$H13_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H13" STATE_DIR="$PROJECT_TMP_H13/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H13="$(witness_file "$PROJECT_TMP_H13" "$SESSION_H13")"
H13_PHYS_LINES=$(wc -l <"$WITNESS_H13" 2>/dev/null | tr -d ' ')
H13_LINE="$(head -n1 "$WITNESS_H13" 2>/dev/null)"
if [ "$H13_PHYS_LINES" = "1" ] \
   && printf '%s' "$H13_LINE" | grep -qF 'cmd="long-cmd"' \
   && printf '%s' "$H13_LINE" | grep -qF 'END-MARKER-ZZZ'; then
  check "P12-H13 long multiline stdout -> tail JSON-escaped onto ONE physical line (last-200 retained)" PASS
else
  check "P12-H13 long-stdout one-line tail (phys_lines=$H13_PHYS_LINES line='${H13_LINE}')" FAIL
fi
rm -rf "$PROJECT_TMP_H13"

PROJECT_TMP_H13B="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H13B="sess-h13b-$$"
activate "$PROJECT_TMP_H13B" "$SESSION_H13B"
# Multiline stdout fed to the hook running under bash --posix (posix mode). Proves the
# newline-delimited 5-field read keeps the whole record on ONE physical line in posix mode —
# the desync the old IFS=$'\x01' parser caused. printf '%s\n' feed avoids echo mangling.
H13B_PAYLOAD=$(make_payload "ml-cmd" 0 "$BIG_STDOUT" "$SESSION_H13B")
printf '%s\n' "$H13B_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H13B" STATE_DIR="$PROJECT_TMP_H13B/.zensu/state" bash --posix "$HOOK" >/dev/null 2>&1
WITNESS_H13B="$(witness_file "$PROJECT_TMP_H13B" "$SESSION_H13B")"
H13B_PHYS_LINES=$(wc -l <"$WITNESS_H13B" 2>/dev/null | tr -d ' ')
H13B_LINE="$(head -n1 "$WITNESS_H13B" 2>/dev/null)"
if [ "$H13B_PHYS_LINES" = "1" ] \
   && printf '%s' "$H13B_LINE" | grep -qF 'cmd="ml-cmd"' \
   && printf '%s' "$H13B_LINE" | grep -qF 'END-MARKER-ZZZ' \
   && printf '%s' "$H13B_LINE" | grep -qF 'interrupted=false'; then
  check "P12-H13b multiline stdout, hook under bash --posix -> tail= on ONE physical line, no desync" PASS
else
  check "P12-H13b bash --posix multiline tail (phys_lines=$H13B_PHYS_LINES line='${H13B_LINE}')" FAIL
fi
rm -rf "$PROJECT_TMP_H13B"

PROJECT_TMP_H13C="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H13C="sess-h13c-$$"
activate "$PROJECT_TMP_H13C" "$SESSION_H13C"
# Characterization: stdout.slice(-200) must DROP the head. HEAD-MARKER sits at the very start
# (well beyond 200 chars from the end), END-MARKER at the very end (within the last 200). The
# JSON-decoded tail= value must be <=200 chars, exclude the head, and retain END.
BIG2="$(node -e 'let s="HEAD-MARKER-AAA";for(let i=0;i<80;i++)s+="L"+i+"\n";process.stdout.write(s+"END-MARKER-ZZZ")')"
H13C_PAYLOAD=$(make_payload "trunc-cmd" 0 "$BIG2" "$SESSION_H13C")
printf '%s\n' "$H13C_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H13C" STATE_DIR="$PROJECT_TMP_H13C/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H13C="$(witness_file "$PROJECT_TMP_H13C" "$SESSION_H13C")"
H13C_CHECK=$(node -e '
  const fs=require("fs");
  const line=(fs.readFileSync(process.argv[1],"utf8").split("\n")[0])||"";
  const m=line.match(/ tail=(".*?(?<!\\)") interrupted=/);
  if(!m){process.stdout.write("NOMATCH");process.exit()}
  const tail=JSON.parse(m[1]);
  process.stdout.write(tail.length+"|"+(tail.includes("HEAD-MARKER-AAA")?"HEAD":"nohead")+"|"+(tail.includes("END-MARKER-ZZZ")?"END":"noend"));
' "$WITNESS_H13C" 2>/dev/null)
if [ "${H13C_CHECK%%|*}" -le 200 ] 2>/dev/null \
   && printf '%s' "$H13C_CHECK" | grep -qF '|nohead|' \
   && printf '%s' "$H13C_CHECK" | grep -qF '|END'; then
  check "P12-H13c stdout>200 -> tail= is last-200 only (head dropped, length<=200, END retained)" PASS
else
  check "P12-H13c truncation (got '$H13C_CHECK')" FAIL
fi
rm -rf "$PROJECT_TMP_H13C"

PROJECT_TMP_H14="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H14="sess-h14-$$"
activate "$PROJECT_TMP_H14" "$SESSION_H14"
# Positive interrupted=true case (the hook's interrupted===true true-branch).
P_H14=$(make_payload "cmd-int" 0 "out" "$SESSION_H14" true)
printf '%s\n' "$P_H14" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H14" STATE_DIR="$PROJECT_TMP_H14/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H14="$(witness_file "$PROJECT_TMP_H14" "$SESSION_H14")"
H14_LINE="$(head -n1 "$WITNESS_H14" 2>/dev/null)"
if printf '%s' "$H14_LINE" | grep -qF 'cmd="cmd-int"' \
   && printf '%s' "$H14_LINE" | grep -qF 'interrupted=true'; then
  check "P12-H14 tool_response.interrupted=true -> witness records interrupted=true (true-branch)" PASS
else
  check "P12-H14 interrupted=true (line='${H14_LINE}')" FAIL
fi
rm -rf "$PROJECT_TMP_H14"

PROJECT_TMP_H15="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H15="sess-h15-$$"
activate "$PROJECT_TMP_H15" "$SESSION_H15"
# tail= round-trip when stdout itself contains literal double-quotes (H7 covers cmd= only).
QUOTE_STDOUT='he said "hi" and left'
P_H15=$(make_payload "cmd-q" 0 "$QUOTE_STDOUT" "$SESSION_H15")
printf '%s\n' "$P_H15" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H15" STATE_DIR="$PROJECT_TMP_H15/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H15="$(witness_file "$PROJECT_TMP_H15" "$SESSION_H15")"
EXTRACTED_TAIL=$(node -e '
  const fs=require("fs");
  const line=(fs.readFileSync(process.argv[1],"utf8").split("\n")[0])||"";
  const m=line.match(/ tail=(".*?(?<!\\)") interrupted=/);
  if(m) process.stdout.write(JSON.parse(m[1])); else process.stdout.write("UNPARSEABLE");
' "$WITNESS_H15" 2>/dev/null)
if [ "$EXTRACTED_TAIL" = "$QUOTE_STDOUT" ]; then
  check "P12-H15 tail= round-trips stdout containing literal double-quotes through JSON.parse" PASS
else
  check "P12-H15 tail round-trip (expected='$QUOTE_STDOUT' got='$EXTRACTED_TAIL')" FAIL
fi
rm -rf "$PROJECT_TMP_H15"

PROJECT_TMP_H16="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H16="sess-h16-$$"
activate "$PROJECT_TMP_H16" "$SESSION_H16"
STATE_H16="$PROJECT_TMP_H16/.zensu/state/tdd-phase-$(session_key "$SESSION_H16").json"
H16_BEFORE="$(node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$STATE_H16")"
BASE_H16="$(make_payload "principal-cmd" 0 "should-not-log" "$SESSION_H16")"
H16_OUTPUT=""
for H16_KIND in reviewer plm neutral partial; do
  P_H16="$(BASE="$BASE_H16" KIND="$H16_KIND" node -e '
    const p=JSON.parse(process.env.BASE);
    if(process.env.KIND==="reviewer")p.agent_type="zensu:code-reviewer";
    if(process.env.KIND==="plm")p.agent_type="zensu:zensu-plm";
    if(process.env.KIND==="neutral")p.agent_type="custom-agent";
    if(process.env.KIND==="partial")p.agent_id="child-only";
    process.stdout.write(JSON.stringify(p));
  ')"
  H16_OUTPUT="${H16_OUTPUT}$(printf '%s' "$P_H16" | ZENSU_FORCE_MAIN=1 ZENSU_TEST_WITNESS=off \
    CLAUDE_PROJECT_DIR="$PROJECT_TMP_H16" STATE_DIR="$PROJECT_TMP_H16/.zensu/state" bash "$HOOK" 2>/dev/null)"
done
H16_AFTER="$(node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$STATE_H16")"
if [ -z "$H16_OUTPUT" ] && [ "$H16_AFTER" = "$H16_BEFORE" ] \
  && [ ! -f "$(witness_file "$PROJECT_TMP_H16" "$SESSION_H16")" ]; then
  check "P12-H16 reviewer/PLM/neutral/partial principals cannot write witness or bypass state" PASS
else
  check "P12-H16 non-main principals are a byte-stable witness no-op" FAIL
fi
rm -rf "$PROJECT_TMP_H16"

# ── P12-A: the ATTEMPT half ─────────────────────────────────────────────────
#
# Claude Code fires no PostToolUse for a Bash call that did not complete
# successfully, so `post-bash-witness.sh` never runs for a failing command and
# the log carried no record of it at all. That is the HOST's behaviour, not this
# hook's: the checks above feed it `exit_code: 3` and it writes a line like any
# other, and P12-A0 re-states that as an executed control so nobody re-diagnoses
# the missing line as an early return here. `pre-bash-witness.sh` records the
# attempt from PreToolUse, which the host does fire unconditionally.
#
# Every check below carries its zero-exit control beside it, because the whole
# claim is a DIFFERENCE between two shapes: a command that completed leaves both
# lines, one that did not leaves only the attempt. A check that only asserted
# the attempt line exists would pass just as well if the result half had silently
# stopped writing, which is the failure it exists to detect.
PRE_HOOK="$PLUGIN_DIR/hooks/pre-bash-witness.sh"

if [ -f "$PRE_HOOK" ]; then
  check "P12-A0a hooks/pre-bash-witness.sh exists" PASS
else
  check "P12-A0a hooks/pre-bash-witness.sh exists" FAIL
fi
if bash -n "$PRE_HOOK" 2>/dev/null; then
  check "P12-A0b pre-bash-witness.sh bash -n syntax check passes" PASS
else
  check "P12-A0b pre-bash-witness.sh bash -n syntax check passes" FAIL
fi

# The registration is half the feature: an unregistered hook records nothing and
# every check below would still pass, because they invoke the file directly.
REG_PRE="$(node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const pre = (j.hooks && j.hooks.PreToolUse) || [];
  const bash = pre.filter((m) => m.matcher === "Bash");
  const names = bash.flatMap((m) => (m.hooks || []).map((h) => h.command || ""));
  process.stdout.write(String(names.filter((c) => c.includes("pre-bash-witness.sh")).length));
' "$PLUGIN_DIR/hooks/hooks.json" 2>/dev/null)"
if [ "$REG_PRE" = "1" ]; then
  check "P12-A1 pre-bash-witness.sh is registered exactly once on the PreToolUse Bash matcher" PASS
else
  check "P12-A1 pre-bash-witness.sh registered on PreToolUse Bash (found: $REG_PRE)" FAIL
fi

# count_lines <fixed-pattern> <file> -> a single-line count, 0 when absent.
# `grep -c` prints 0 and exits 1 on no match, so the `|| echo 0` idiom used by
# the checks above yields the two-line value "0\n0"; those checks only ever
# expect 1, so it never bit them. Every check below compares against 0.
count_lines() {
  local n
  n="$(grep -cF "$1" "$2" 2>/dev/null | head -n1)"
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

# make_pre_payload <cmd> <session> -> the PreToolUse dialect: no tool_response.
make_pre_payload() {
  local cmd="$1" session_id="$2" cmd_json session_json
  cmd_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$cmd")"
  session_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$session_id")"
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s},"session_id":%s}' \
    "$cmd_json" "$session_json"
}

# P12-A0: the CONTROL for the whole diagnosis — the result hook has no branch on
# the exit status. Feeding it a non-zero `exit_code` still writes its line, so a
# missing line in a live session is the host declining to fire the event.
PROJECT_TMP_A0="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_A0="sess-a0-$$"
activate "$PROJECT_TMP_A0" "$SESSION_A0"
echo "$(make_payload "probe-rc3" 3 "boom" "$SESSION_A0")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A0" bash "$HOOK" >/dev/null 2>&1
echo "$(make_payload "probe-rc0" 0 "ok" "$SESSION_A0")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A0" bash "$HOOK" >/dev/null 2>&1
W_A0="$(witness_file "$PROJECT_TMP_A0" "$SESSION_A0")"
A0_RC3="$(count_lines 'BASH cmd="probe-rc3" exit=3' "$W_A0")"
A0_RC0="$(count_lines 'BASH cmd="probe-rc0" exit=0' "$W_A0")"
if [ "$A0_RC3" = "1" ] && [ "$A0_RC0" = "1" ]; then
  check "P12-A0 the result hook records a non-zero exit exactly as it records a zero one (the gap is the host's)" PASS
else
  check "P12-A0 result hook exit-code neutrality (rc3=$A0_RC3 rc0=$A0_RC0)" FAIL
fi
rm -rf "$PROJECT_TMP_A0"

# P12-A2/A3: the matched pair. A completed call leaves an attempt AND a result
# line; a call the host never reports back leaves the attempt alone. Both run in
# one fixture so the difference is the only variable.
PROJECT_TMP_A2="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_A2="sess-a2-$$"
activate "$PROJECT_TMP_A2" "$SESSION_A2"
echo "$(make_pre_payload "green-suite" "$SESSION_A2")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A2" bash "$PRE_HOOK" >/dev/null 2>&1
echo "$(make_payload "green-suite" 0 "1 passed" "$SESSION_A2")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A2" bash "$HOOK" >/dev/null 2>&1
echo "$(make_pre_payload "red-suite" "$SESSION_A2")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A2" bash "$PRE_HOOK" >/dev/null 2>&1
W_A2="$(witness_file "$PROJECT_TMP_A2" "$SESSION_A2")"
A2_GREEN_ATTEMPT="$(count_lines 'BASH-ATTEMPT cmd="green-suite"' "$W_A2")"
A2_GREEN_RESULT="$(count_lines 'BASH cmd="green-suite"' "$W_A2")"
A2_RED_ATTEMPT="$(count_lines 'BASH-ATTEMPT cmd="red-suite"' "$W_A2")"
A2_RED_RESULT="$(count_lines 'BASH cmd="red-suite"' "$W_A2")"
if [ "$A2_GREEN_ATTEMPT" = "1" ] && [ "$A2_GREEN_RESULT" = "1" ]; then
  check "P12-A2 zero-exit control: a completed call leaves BOTH an attempt and a result line" PASS
else
  check "P12-A2 completed call leaves both lines (attempt=$A2_GREEN_ATTEMPT result=$A2_GREEN_RESULT)" FAIL
fi
if [ "$A2_RED_ATTEMPT" = "1" ] && [ "$A2_RED_RESULT" = "0" ]; then
  check "P12-A3 a call the host never reports back is still witnessed, as an attempt with no result" PASS
else
  check "P12-A3 attempt-only shape (attempt=$A2_RED_ATTEMPT result=$A2_RED_RESULT)" FAIL
fi
# The two markers must not match each other, or the completed count above is a
# lie: `grep -F 'BASH cmd='` must never find a `BASH-ATTEMPT cmd=` line.
if [ "$A2_RED_RESULT" = "0" ] && [ "$A2_RED_ATTEMPT" = "1" ] \
  && ! grep -qF 'BASH cmd="red-suite"' "$W_A2" 2>/dev/null; then
  check "P12-A4 the attempt marker is not a substring match for the result marker" PASS
else
  check "P12-A4 attempt and result markers are distinguishable" FAIL
fi
rm -rf "$PROJECT_TMP_A2"

# P12-A5: ADVISORY. stdout is the PreToolUse decision channel and a non-zero exit
# blocks the call, so a witness that emitted either would break every Bash call
# in the session. Checked on the activated path, where the hook does the most.
PROJECT_TMP_A5="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_A5="sess-a5-$$"
activate "$PROJECT_TMP_A5" "$SESSION_A5"
A5_OUT="$(echo "$(make_pre_payload "advisory-probe" "$SESSION_A5")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A5" bash "$PRE_HOOK" 2>/dev/null)"
A5_RC=$?
if [ -z "$A5_OUT" ] && [ "$A5_RC" = "0" ] \
  && grep -qF 'BASH-ATTEMPT cmd="advisory-probe"' "$(witness_file "$PROJECT_TMP_A5" "$SESSION_A5")" 2>/dev/null; then
  check "P12-A5 the attempt hook writes no stdout and exits 0 while still recording (advisory)" PASS
else
  check "P12-A5 attempt hook is advisory (out='$A5_OUT' rc=$A5_RC)" FAIL
fi
rm -rf "$PROJECT_TMP_A5"

# P12-A6/A7: the attempt half is scoped exactly like the result half. Recording
# attempts for an unarmed session would put lines in a log the result half never
# writes to, and every one would read as a run that did not finish.
PROJECT_TMP_A6="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_A6="sess-a6-$$"
baseline "$PROJECT_TMP_A6" "$SESSION_A6"
echo "$(make_pre_payload "unarmed" "$SESSION_A6")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A6" bash "$PRE_HOOK" >/dev/null 2>&1
if [ ! -f "$(witness_file "$PROJECT_TMP_A6" "$SESSION_A6")" ]; then
  check "P12-A6 session not activated -> the attempt hook writes no witness log" PASS
else
  check "P12-A6 session not activated -> attempt hook leaked a witness log" FAIL
fi
rm -rf "$PROJECT_TMP_A6"

PROJECT_TMP_A7="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_A7="sess-a7-$$"
activate "$PROJECT_TMP_A7" "$SESSION_A7"
echo "$(make_pre_payload "opted-out" "$SESSION_A7")" \
  | env ZENSU_TEST_WITNESS=off CLAUDE_PROJECT_DIR="$PROJECT_TMP_A7" bash "$PRE_HOOK" >/dev/null 2>&1
if [ ! -f "$(witness_file "$PROJECT_TMP_A7" "$SESSION_A7")" ]; then
  check "P12-A7 ZENSU_TEST_WITNESS=off silences the attempt half too" PASS
else
  check "P12-A7 ZENSU_TEST_WITNESS=off left the attempt half writing" FAIL
fi
# Positive control for A7: without the switch the same fixture DOES record, so
# A7 cannot pass because the hook is broken.
echo "$(make_pre_payload "opted-out" "$SESSION_A7")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A7" bash "$PRE_HOOK" >/dev/null 2>&1
if grep -qF 'BASH-ATTEMPT cmd="opted-out"' "$(witness_file "$PROJECT_TMP_A7" "$SESSION_A7")" 2>/dev/null; then
  check "P12-A7-control the same fixture records once the opt-out is removed" PASS
else
  check "P12-A7-control the same fixture records once the opt-out is removed" FAIL
fi
rm -rf "$PROJECT_TMP_A7"

# P12-A8: both writers redact `cmd` through the SAME function, so an attempt and
# its result agree byte-for-byte on a command naming an absolute path. They are
# matched by equality downstream; a divergence here is silent evidence loss.
PROJECT_TMP_A8="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_A8="sess-a8-$$"
activate "$PROJECT_TMP_A8" "$SESSION_A8"
A8_CMD="bash $PROJECT_TMP_A8/tests/run.sh"
echo "$(make_pre_payload "$A8_CMD" "$SESSION_A8")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A8" bash "$PRE_HOOK" >/dev/null 2>&1
echo "$(make_payload "$A8_CMD" 0 "ok" "$SESSION_A8")" \
  | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_A8" bash "$HOOK" >/dev/null 2>&1
W_A8="$(witness_file "$PROJECT_TMP_A8" "$SESSION_A8")"
A8_ATTEMPT_CMD="$(WFILE="$W_A8" node -e '
  const fs = require("fs");
  const x = require(process.env.XCHK);
  const entries = x.parseWitness(fs.readFileSync(process.env.WFILE, "utf8"), "/nope/run.log");
  const a = entries.find((e) => e.kind === "attempt");
  process.stdout.write(a ? a.cmd : "");
' 2>/dev/null)"
A8_RESULT_CMD="$(WFILE="$W_A8" node -e '
  const fs = require("fs");
  const x = require(process.env.XCHK);
  const entries = x.parseWitness(fs.readFileSync(process.env.WFILE, "utf8"), "/nope/run.log");
  const r = entries.find((e) => e.kind === "result");
  process.stdout.write(r ? r.cmd : "");
' 2>/dev/null)"
if [ -n "$A8_ATTEMPT_CMD" ] && [ "$A8_ATTEMPT_CMD" = "$A8_RESULT_CMD" ] \
  && [ "$A8_ATTEMPT_CMD" != "$A8_CMD" ]; then
  check "P12-A8 both writers redact cmd identically (attempt == result, and both were redacted)" PASS
else
  check "P12-A8 redaction symmetry (attempt='$A8_ATTEMPT_CMD' result='$A8_RESULT_CMD')" FAIL
fi
rm -rf "$PROJECT_TMP_A8"

echo "----"
echo "test-post-bash-witness: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
