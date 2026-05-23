#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$PLUGIN_DIR/hooks/post-bash-witness.sh"

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

make_payload() {
  local cmd="$1" exit_code="$2" stdout="$3" session_id="$4"
  local cmd_json exit_json stdout_json session_json
  cmd_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$cmd")"
  stdout_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$stdout")"
  session_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$session_id")"
  if [ "$exit_code" = "null" ]; then exit_json="null"; else exit_json="$exit_code"; fi
  printf '{"tool_input":{"command":%s},"tool_response":{"exit_code":%s,"stdout":%s},"session_id":%s}' \
    "$cmd_json" "$exit_json" "$stdout_json" "$session_json"
}

PROJECT_TMP="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION="sess-h2-$$"
PAYLOAD1=$(make_payload "npm test" 0 "PASS root/test.js" "$SESSION")
PAYLOAD2=$(make_payload "pytest -v" 0 "1 passed" "$SESSION")
PAYLOAD3=$(make_payload "go test ./..." 0 "ok    pkg/foo" "$SESSION")
PAYLOAD4=$(make_payload "bash tests/structure/test-foo.sh" 0 "PASS" "$SESSION")
for P in "$PAYLOAD1" "$PAYLOAD2" "$PAYLOAD3" "$PAYLOAD4"; do
  echo "$P" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP" bash "$HOOK" >/dev/null 2>&1
done
WITNESS="$PROJECT_TMP/.zensu/logs/witness-${SESSION}.log"
COUNT_NPM=$(grep -cF 'cmd="npm test"' "$WITNESS" 2>/dev/null || echo 0)
COUNT_PYT=$(grep -cF 'cmd="pytest -v"' "$WITNESS" 2>/dev/null || echo 0)
COUNT_GO=$(grep -cF 'cmd="go test ./..."' "$WITNESS" 2>/dev/null || echo 0)
COUNT_BASH=$(grep -cF 'cmd="bash tests/structure/test-foo.sh"' "$WITNESS" 2>/dev/null || echo 0)
if [ "$COUNT_NPM" = "1" ] && [ "$COUNT_PYT" = "1" ] && [ "$COUNT_GO" = "1" ] && [ "$COUNT_BASH" = "1" ]; then
  check "P12-H2 zensu:tdd-manager + 4 distinct commands -> 4 witness entries (no pattern filter)" PASS
else
  check "P12-H2 4 entries (npm=$COUNT_NPM pyt=$COUNT_PYT go=$COUNT_GO bash=$COUNT_BASH)" FAIL
fi
rm -rf "$PROJECT_TMP"

PROJECT_TMP_H3="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H3="sess-h3-$$"
P_H3=$(make_payload "npm test" 0 "PASS" "$SESSION_H3")
echo "$P_H3" | env CLAUDE_AGENT_TYPE=zensu:code-reviewer CLAUDE_PROJECT_DIR="$PROJECT_TMP_H3" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$PROJECT_TMP_H3/.zensu/logs/witness-${SESSION_H3}.log" ]; then
  check "P12-H3 CLAUDE_AGENT_TYPE=zensu:code-reviewer -> no witness log written (scope guard)" PASS
else
  check "P12-H3 CLAUDE_AGENT_TYPE=zensu:code-reviewer -> no witness log (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H3"

PROJECT_TMP_H4="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H4="sess-h4-$$"
P_H4=$(make_payload "npm test" 0 "PASS" "$SESSION_H4")
echo "$P_H4" | env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$PROJECT_TMP_H4" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$PROJECT_TMP_H4/.zensu/logs/witness-${SESSION_H4}.log" ]; then
  check "P12-H4 CLAUDE_AGENT_TYPE empty -> no witness log written" PASS
else
  check "P12-H4 CLAUDE_AGENT_TYPE empty -> no witness log (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H4"

PROJECT_TMP_H5="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H5="sess-h5-$$"
P_H5=$(make_payload "npm test" 0 "PASS" "$SESSION_H5")
echo "$P_H5" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager ZENSU_TEST_WITNESS=off CLAUDE_PROJECT_DIR="$PROJECT_TMP_H5" bash "$HOOK" >/dev/null 2>&1
if [ ! -f "$PROJECT_TMP_H5/.zensu/logs/witness-${SESSION_H5}.log" ]; then
  check "P12-H5 ZENSU_TEST_WITNESS=off + correct CAT -> no witness log (opt-out)" PASS
else
  check "P12-H5 ZENSU_TEST_WITNESS=off -> no witness log (file exists, leaked)" FAIL
fi
rm -rf "$PROJECT_TMP_H5"

PROJECT_TMP_H6="$(mktemp -d -t "witness-proj-XXXXXX")"
SESSION_H6="sess-h6-$$"
P_H6A=$(make_payload "cmd1" 0 "out1" "$SESSION_H6")
P_H6B=$(make_payload "cmd2" 1 "out2" "$SESSION_H6")
P_H6C=$(make_payload "cmd3" 0 "out3" "$SESSION_H6")
for P in "$P_H6A" "$P_H6B" "$P_H6C"; do
  echo "$P" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP_H6" bash "$HOOK" >/dev/null 2>&1
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
TRICKY_CMD='echo "hello \"world\"" && printf "a\nb"'
P_H7=$(make_payload "$TRICKY_CMD" 0 "ok" "$SESSION_H7")
echo "$P_H7" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP_H7" bash "$HOOK" >/dev/null 2>&1
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
NO_RESPONSE_PAYLOAD=$(printf '{"tool_input":{"command":"echo hi"},"session_id":"%s"}' "$SESSION_H8")
echo "$NO_RESPONSE_PAYLOAD" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP_H8" bash "$HOOK" >/dev/null 2>&1
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
P_H9=$(make_payload "echo h9" 0 "ok" "$SESSION_H9")
echo "$P_H9" | env CLAUDE_AGENT_TYPE=zensu:tdd-manager CLAUDE_PROJECT_DIR="$PROJECT_TMP_H9" bash "$HOOK" >/dev/null 2>&1
H9_OVERRIDE=$([ -f "$PROJECT_TMP_H9/.zensu/logs/witness-${SESSION_H9}.log" ] && echo "yes" || echo "no")
cd "$(mktemp -d -t "witness-cwd-XXXXXX")"
SESSION_H9B="sess-h9b-$$"
P_H9B=$(make_payload "echo h9b" 0 "ok" "$SESSION_H9B")
echo "$P_H9B" | env -i PATH="$PATH" CLAUDE_AGENT_TYPE=zensu:tdd-manager bash "$HOOK" >/dev/null 2>&1
H9_FALLBACK=$([ -f "./.zensu/logs/witness-${SESSION_H9B}.log" ] && echo "yes" || echo "no")
cd "$ORIG_PWD"
if [ "$H9_OVERRIDE" = "yes" ] && [ "$H9_FALLBACK" = "yes" ]; then
  check "P12-H9 CLAUDE_PROJECT_DIR honored when set, falls back to '.' when unset" PASS
else
  check "P12-H9 path resolution (override=$H9_OVERRIDE fallback=$H9_FALLBACK)" FAIL
fi
rm -rf "$PROJECT_TMP_H9"

echo "----"
echo "test-post-bash-witness: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
