#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN_DIR/hooks/pre-edit-tdd-reminder.sh"
LIB="$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"
TDD_STATE_DIR="$(mktemp -d)"
export TDD_STATE_DIR
unset ZENSU_TDD_GATE
cleanup() { rm -rf "$TDD_STATE_DIR"; }
trap cleanup EXIT

source "$LIB"

# 0.4.0+: the gate activates on chain-state (active=true), set by /zensu:tdd
# --tdd-begin. Shim phase setup to also mark each session active (the legacy
# CLAUDE_AGENT_TYPE=zensu:tdd-manager activation was removed).
eval "$(declare -f tdd_write_phase | sed '1s/^tdd_write_phase/_zensu_orig_write_phase/')"
tdd_write_phase() { tdd_set_flag "$1" active true >/dev/null 2>&1; _zensu_orig_write_phase "$@"; }

SID="s-bash-1"
tdd_write_phase "$SID" "S1" "RED_FAIL" "x" >/dev/null

assert_bash_noop() {
  local cmd="$1" label="$2"
  local payload='{"tool_name":"Bash","tool_input":{"command":'"$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$cmd")"'},"session_id":"'$SID'"}'
  local out
  out=$(echo "$payload" | "$SCRIPT" 2>/dev/null)
  if [ -z "$out" ]; then
    check "$label: gate no-op (empty stdout)" PASS
  else
    check "$label: gate no-op (stdout: $out)" FAIL
  fi
}

assert_bash_noop "cat > src/foo.ts <<EOF
export const x = 1;
EOF" "Bash heredoc redirect to production file"

assert_bash_noop "echo hi > src/foo.ts" "Bash > redirect to production file"
assert_bash_noop "echo hi >> src/foo.ts" "Bash >> append to production file"
assert_bash_noop "sed -i \"s/x/y/g\" src/foo.ts" "Bash sed -i in-place edit"
assert_bash_noop "echo hi | tee src/foo.ts" "Bash tee to file"
assert_bash_noop "dd of=src/foo.ts if=/dev/zero count=1" "Bash dd of= file write"
assert_bash_noop "python -c \"open('src/foo.ts','w').write('x')\"" "Python -c file write"
assert_bash_noop "node -e 'require(\"fs\").writeFileSync(\"src/foo.ts\",\"x\")'" "Node -e file write"
assert_bash_noop "perl -pi -e 's/x/y/' src/foo.ts" "Perl -pi inplace"
assert_bash_noop "ruby -e \"File.open('src/foo.ts','w'){|f|f.puts 'x'}\"" "Ruby -e file write"
assert_bash_noop "cp /etc/passwd src/foo.ts" "cp overwrite production"
assert_bash_noop "mv /tmp/foo src/foo.ts" "mv overwrite production"
assert_bash_noop "install -m 644 /tmp/foo src/foo.ts" "install overwrite"
assert_bash_noop "rsync /etc/passwd src/foo.ts" "rsync overwrite"
assert_bash_noop "awk -i inplace 1 src/foo.ts" "awk inplace"
assert_bash_noop "patch -p1 < my.diff" "patch apply"
assert_bash_noop "git apply patch.diff" "git apply diff"
assert_bash_noop "dd  of=src/foo.ts if=/dev/zero" "dd with double-space (defeats *dd of=*)"
assert_bash_noop "sh -c \"echo hi>src/foo.ts\"" "quoted inner redirect"
assert_bash_noop "echo hi;echo hi>src/foo.ts" "no-space redirect"
assert_bash_noop "printf hi>src/foo.ts" "printf no-space redirect"
assert_bash_noop "ls -la src/" "ls read-only"
assert_bash_noop "npm test" "npm test"
assert_bash_noop "git status" "git status"
assert_bash_noop "cat .zensu/state/tdd-phase-abc.json" "cat tdd-phase state file"
assert_bash_noop "grep tdd-phase- somefile" "grep tdd-phase string"
assert_bash_noop "ls /tmp/my-tdd-phase-stats.txt" "ls path containing tdd-phase- substring"
assert_bash_noop "bash hooks/lib/zensu-log.sh --phase IMPL --step S1" "phase marker via official log helper"
assert_bash_noop "bash hooks/lib/zensu-log.sh --phase IMPL --step \"\$(cat /etc/passwd | base64)\"" "argv-injection attempt — gate no-op (Bash not gated)"
assert_bash_noop "echo hi >> .zensu/logs/foo.log" "documented log-append (Bash not gated)"

PAYLOAD_EDIT='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"},"session_id":"'$SID'"}'
OUT_EDIT=$(echo "$PAYLOAD_EDIT" | "$SCRIPT" 2>/dev/null)
DEC_EDIT=$(node -e '
  try { const j = JSON.parse(process.argv[1]); console.log(j.hookSpecificOutput?.permissionDecision || "allow"); }
  catch (_) { console.log("allow"); }
' "$OUT_EDIT" 2>/dev/null)
if [ "$DEC_EDIT" = "deny" ]; then
  check "Edit on src/foo.ts in RED_FAIL: still DENIED (gate active for Edit/Write/MultiEdit)" PASS
else
  check "Edit on src/foo.ts in RED_FAIL: still DENIED (got: $DEC_EDIT)" FAIL
fi

echo "----"
echo "test-pre-edit-bash-bypass: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
