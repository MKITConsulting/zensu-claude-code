#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/post-bash-witness.sh"
LOG="$PLUGIN_DIR/hooks/lib/zensu-log.sh"

ZENSU_CONFIG="$PLUGIN_DIR/.no-such-config-$$.json"; export ZENSU_CONFIG

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
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
  env CLAUDE_PROJECT_DIR="$1" TDD_STATE_DIR="$1/.zensu/state" \
    bash "$LOG" --tdd-begin --session "$2" >/dev/null 2>&1
}

make_payload() {
  local cmd="$1" exit_code="$2" stdout="$3" session_id="$4" interrupted="${5:-false}"
  local cmd_json exit_json stdout_json session_json
  cmd_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$cmd")"
  stdout_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$stdout")"
  session_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$session_id")"
  if [ "$exit_code" = "null" ]; then exit_json="null"; else exit_json="$exit_code"; fi
  printf '{"tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":%s,"interrupted":%s},"session_id":%s}' \
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
  echo "$P" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP" TDD_STATE_DIR="$PROJECT_TMP/.zensu/state" bash "$HOOK" >/dev/null 2>&1
done
WITNESS="$PROJECT_TMP/.zensu/logs/witness-${SESSION}.log"
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
P_H3=$(make_payload "npm test" 0 "PASS" "$SESSION_H3")
echo "$P_H3" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H3" TDD_STATE_DIR="$PROJECT_TMP_H3/.zensu/state" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$PROJECT_TMP_H3/.zensu/logs/witness-${SESSION_H3}.log" ]; then
  check "P12-H3 session not activated -> no witness log written (chain-state scope guard)" PASS
else
  check "P12-H3 session not activated -> no witness log (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H3"

PROJECT_TMP_H4="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H4="sess-h4-$$"
P_H4=$(make_payload "npm test" 0 "PASS" "$SESSION_H4")
echo "$P_H4" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP_H4" TDD_STATE_DIR="$PROJECT_TMP_H4/.zensu/state" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$PROJECT_TMP_H4/.zensu/logs/witness-${SESSION_H4}.log" ]; then
  check "P12-H4 CLAUDE_AGENT_TYPE set but session not activated -> no witness (legacy CAT no longer activates)" PASS
else
  check "P12-H4 CLAUDE_AGENT_TYPE set without activation -> no witness (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H4"

PROJECT_TMP_H5="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H5="sess-h5-$$"
activate "$PROJECT_TMP_H5" "$SESSION_H5"
P_H5=$(make_payload "npm test" 0 "PASS" "$SESSION_H5")
echo "$P_H5" | env ZENSU_TEST_WITNESS=off CLAUDE_PROJECT_DIR="$PROJECT_TMP_H5" TDD_STATE_DIR="$PROJECT_TMP_H5/.zensu/state" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$PROJECT_TMP_H5/.zensu/logs/witness-${SESSION_H5}.log" ]; then
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
  echo "$P" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H6" TDD_STATE_DIR="$PROJECT_TMP_H6/.zensu/state" bash "$HOOK" >/dev/null 2>&1
done
WITNESS_H6="$PROJECT_TMP_H6/.zensu/logs/witness-${SESSION_H6}.log"
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
printf '%s\n' "$P_H7" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H7" TDD_STATE_DIR="$PROJECT_TMP_H7/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H7="$PROJECT_TMP_H7/.zensu/logs/witness-${SESSION_H7}.log"
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
NO_RESPONSE_PAYLOAD=$(printf '{"tool_input":{"command":"echo hi"},"session_id":"%s"}' "$SESSION_H8")
echo "$NO_RESPONSE_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H8" TDD_STATE_DIR="$PROJECT_TMP_H8/.zensu/state" bash "$HOOK" >/dev/null 2>&1
RC_H8=$?
WITNESS_H8="$PROJECT_TMP_H8/.zensu/logs/witness-${SESSION_H8}.log"
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
echo "$P_H9" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H9" TDD_STATE_DIR="$PROJECT_TMP_H9/.zensu/state" bash "$HOOK" >/dev/null 2>&1
H9_OVERRIDE=$([ -f "$PROJECT_TMP_H9/.zensu/logs/witness-${SESSION_H9}.log" ] && echo "yes" || echo "no")
CWD_TMP="$(mktemp -d -t "witness-cwd-XXXXXX")"
cd "$CWD_TMP"
SESSION_H9B="sess-h9b-$$"
env CLAUDE_PROJECT_DIR="." bash "$LOG" --tdd-begin --session "$SESSION_H9B" >/dev/null 2>&1
P_H9B=$(make_payload "echo h9b" 0 "ok" "$SESSION_H9B")
echo "$P_H9B" | env -i PATH="$PATH" bash "$HOOK" >/dev/null 2>&1
H9_FALLBACK=$([ -f "./.zensu/logs/witness-${SESSION_H9B}.log" ] && echo "yes" || echo "no")
cd "$ORIG_PWD"
if [ "$H9_OVERRIDE" = "yes" ] && [ "$H9_FALLBACK" = "yes" ]; then
  check "P12-H9 CLAUDE_PROJECT_DIR honored when set, falls back to '.' when unset" PASS
else
  check "P12-H9 path resolution (override=$H9_OVERRIDE fallback=$H9_FALLBACK)" FAIL
fi
rm -rf "$PROJECT_TMP_H9" "$CWD_TMP"

PROJECT_TMP_H10="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H10="sess-h10-$$"
activate "$PROJECT_TMP_H10" "$SESSION_H10"
P_H10=$(make_payload "npm test" 0 "PASS root/test.js" "$SESSION_H10")
echo "$P_H10" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H10" TDD_STATE_DIR="$PROJECT_TMP_H10/.zensu/state" bash --posix "$HOOK" >/dev/null 2>&1
WITNESS_H10="$PROJECT_TMP_H10/.zensu/logs/witness-${SESSION_H10}.log"
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
echo "$P_H11" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H11" TDD_STATE_DIR="$PROJECT_TMP_H11/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H11="$PROJECT_TMP_H11/.zensu/logs/witness-${SESSION_H11}.log"
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
H12_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({tool_input:{command:"node --test"},tool_response:{stdout:"tests 1\npass 1\nfail 0",stderr:"",interrupted:false,isImage:false},session_id:process.argv[1]}))' "$SESSION_H12")
printf '%s\n' "$H12_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H12" TDD_STATE_DIR="$PROJECT_TMP_H12/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H12="$PROJECT_TMP_H12/.zensu/logs/witness-${SESSION_H12}.log"
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
printf '%s\n' "$H13_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H13" TDD_STATE_DIR="$PROJECT_TMP_H13/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H13="$PROJECT_TMP_H13/.zensu/logs/witness-${SESSION_H13}.log"
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
printf '%s\n' "$H13B_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H13B" TDD_STATE_DIR="$PROJECT_TMP_H13B/.zensu/state" bash --posix "$HOOK" >/dev/null 2>&1
WITNESS_H13B="$PROJECT_TMP_H13B/.zensu/logs/witness-${SESSION_H13B}.log"
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
printf '%s\n' "$H13C_PAYLOAD" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H13C" TDD_STATE_DIR="$PROJECT_TMP_H13C/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H13C="$PROJECT_TMP_H13C/.zensu/logs/witness-${SESSION_H13C}.log"
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
printf '%s\n' "$P_H14" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H14" TDD_STATE_DIR="$PROJECT_TMP_H14/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H14="$PROJECT_TMP_H14/.zensu/logs/witness-${SESSION_H14}.log"
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
printf '%s\n' "$P_H15" | env CLAUDE_PROJECT_DIR="$PROJECT_TMP_H15" TDD_STATE_DIR="$PROJECT_TMP_H15/.zensu/state" bash "$HOOK" >/dev/null 2>&1
WITNESS_H15="$PROJECT_TMP_H15/.zensu/logs/witness-${SESSION_H15}.log"
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

echo "----"
echo "test-post-bash-witness: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
