#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
GATE="$PLUGIN_DIR/hooks/pre-reviewer-capability-gate.sh"
HOST_PATH="$PLUGIN_DIR/hooks/lib/zensu-host-path.sh"
CORE="$PLUGIN_DIR/hooks/lib/session-control-core-v1.js"

PASS=0
FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for artifact in "$GATE" "$HOST_PATH" "$CORE"; do
  if [ -f "$artifact" ]; then
    check "artifact exists: ${artifact#$PLUGIN_DIR/}" PASS
  else
    check "artifact exists: ${artifact#$PLUGIN_DIR/}" FAIL
  fi
done
if [ "$FAIL" -ne 0 ]; then
  printf '%s\n' "----" "test-vanished-session-cwd: $PASS PASS / $FAIL FAIL"
  exit 1
fi

RAW_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vanished-session-cwd-XXXXXX")" || exit 1
RAW_TMP="$(cd -P -- "$RAW_TMP" && pwd -P)" || exit 1
trap 'chmod -R u+w "$RAW_TMP" 2>/dev/null; rm -rf "$RAW_TMP"' EXIT
TMP="$(bash "$HOST_PATH" "$RAW_TMP")" || {
  printf '%s\n' 'vanished-session-cwd fixture could not render its native host path' >&2
  exit 1
}

PROJECT="$TMP/project"
PLUGIN_DATA="$TMP/plugin-data"
TAMPERED_DATA="$TMP/tampered-plugin-data"
CONFIG="$TMP/no-such-config.json"
NO_TEMP_ROOT="$TMP/no-such-temp-root"
SESSION_ID='vanished-cwd-test'
mkdir -p "$RAW_TMP/project/src" "$RAW_TMP/plugin-data" "$RAW_TMP/tampered-plugin-data"
printf 'hello\n' > "$RAW_TMP/project/README.md"
printf 'hello\n' > "$RAW_TMP/project/src/existing.txt"
GONE="$PROJECT/.claude/worktrees/removed-worktree"
FILE_CWD="$PROJECT/README.md"

PROBE="$RAW_TMP/probe.js"
cat > "$PROBE" <<'NODE'
'use strict';
const path = require('node:path');

const project = process.env.PROBE_PROJECT || '';
const TOOL_INPUT = {
  Read: { file_path: project + '/README.md' },
  Grep: { pattern: 'hello', path: project + '/src' },
  Glob: { pattern: '**/*', path: project + '/src' },
  Bash: { command: 'git status' },
  Write: { file_path: project + '/notes.txt', content: 'x' },
  Edit: { file_path: project + '/README.md', old_string: 'hello', new_string: 'hi' },
  MultiEdit: {
    file_path: project + '/README.md',
    edits: [{ old_string: 'hello', new_string: 'hi' }],
  },
  NotebookEdit: { notebook_path: project + '/notes.ipynb', new_source: 'x' },
  Agent: { subagent_type: 'general-purpose', prompt: 'x', description: 'x' },
  Task: { subagent_type: 'general-purpose', prompt: 'x', description: 'x' },
  ToolSearch: { query: 'select:Read' },
  TaskUpdate: { taskId: 'probe-1', status: 'completed' },
  'mcp__plugin_zensu_zensu-browser__browser_navigate': { url: 'http://127.0.0.1:9/' },
  'mcp__plugin_zensu_zensu-browser__browser_tabs': { action: 'list' },
};

function readStdin() {
  return new Promise((resolve) => {
    let raw = '';
    process.stdin.on('data', (chunk) => { raw += chunk; });
    process.stdin.on('end', () => resolve(raw));
  });
}

function decision(raw) {
  const text = raw.trim();
  if (!text) return 'allow';
  try {
    const parsed = JSON.parse(text.split('\n').pop());
    const output = parsed.hookSpecificOutput || {};
    return output.permissionDecision || parsed.permissionDecision || parsed.decision || 'other';
  } catch (_) {
    return 'unparsed';
  }
}

function reason(raw) {
  const text = raw.trim();
  if (!text) return '';
  try {
    const parsed = JSON.parse(text.split('\n').pop());
    const output = parsed.hookSpecificOutput || {};
    return String(output.permissionDecisionReason || parsed.reason || '');
  } catch (_) {
    return '';
  }
}

const [, , command, ...rest] = process.argv;

function buildPayload(tool, cwd, agentType) {
  const body = {
    hook_event_name: 'PreToolUse',
    session_id: process.env.PROBE_SESSION_ID,
    cwd,
    tool_name: tool,
    tool_input: TOOL_INPUT[tool] || {},
  };
  if (agentType) {
    body.agent_id = 'agent-probe';
    body.agent_type = agentType;
  }
  return JSON.stringify(body);
}

const CWD_SHAPES = {
  number: 42,
  newline: (process.env.PROBE_PROJECT || '') + '/\n',
};

if (command === 'payload') {
  const [tool, cwd, agentType] = rest;
  process.stdout.write(buildPayload(tool, cwd, agentType));
} else if (command === 'payload-shape') {
  const [tool, shape, agentType] = rest;
  if (!Object.prototype.hasOwnProperty.call(CWD_SHAPES, shape)) process.exit(4);
  process.stdout.write(buildPayload(tool, CWD_SHAPES[shape], agentType));
} else if (command === 'registrations') {
  const hooks = require(path.join(rest[0], 'hooks', 'hooks.json')).hooks || {};
  const rows = [];
  for (const matcher of hooks.PreToolUse || []) {
    const pattern = matcher.matcher === undefined ? '' : String(matcher.matcher);
    for (const entry of matcher.hooks || []) {
      const found = String(entry.command || '').match(/hooks\/([A-Za-z0-9._-]+\.sh)/);
      if (found) rows.push(pattern + '\t' + found[1]);
    }
  }
  process.stdout.write([...new Set(rows)].join('\n'));
} else if (command === 'match') {
  const pattern = rest[0] === undefined || rest[0] === '' ? '.*' : rest[0];
  let expression;
  try {
    expression = new RegExp('^(?:' + pattern + ')$');
  } catch (_) {
    process.exit(3);
  }
  process.stdout.write(Object.keys(TOOL_INPUT).filter((name) => expression.test(name)).join('\n'));
} else if (command === 'verdict') {
  readStdin().then((raw) => process.stdout.write(decision(raw)));
} else if (command === 'reason') {
  readStdin().then((raw) => process.stdout.write(reason(raw)));
} else if (command === 'tamper') {
  const fs = require('node:fs');
  const file = rest[0];
  const record = JSON.parse(fs.readFileSync(file, 'utf8'));
  record.runtime_digest = 'sha256:' + '0'.repeat(64);
  record.source_revision = record.runtime_digest;
  fs.writeFileSync(file, JSON.stringify(record) + '\n');
} else {
  process.exit(2);
}
NODE

mint_record() {
  PROBE_SESSION_ID="$SESSION_ID" PROBE_PROJECT="$PROJECT" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "SessionStart",
      source: "startup",
      session_id: process.env.PROBE_SESSION_ID,
      cwd: process.env.PROBE_PROJECT,
    }));
  ' | CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$1" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
    bash "$PLUGIN_DIR/hooks/session-start-session-control.sh" >/dev/null
}

mint_record "$PLUGIN_DATA" || { printf 'fixture: SessionStart failed\n' >&2; exit 1; }
mint_record "$TAMPERED_DATA" || { printf 'fixture: tampered SessionStart failed\n' >&2; exit 1; }
SESSION_KEY="$(node -e 'process.stdout.write(require(process.argv[1]).sessionKey(process.argv[2]))' \
  "$CORE" "$SESSION_ID")" || exit 1
node "$PROBE" tamper "$RAW_TMP/tampered-plugin-data/session-control/v1/records/${SESSION_KEY}.json" \
  || { printf 'fixture: could not tamper the record\n' >&2; exit 1; }

CLAUDE_PROJECT_DIR="$PROJECT" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SESSION_ID" bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" \
  --tdd-begin --session "$SESSION_ID" >/dev/null 2>&1 \
  || { printf 'fixture: --tdd-begin failed\n' >&2; exit 1; }
STATE_FILE="$RAW_TMP/project/.zensu/state/tdd-phase-${SESSION_KEY}.json"
[ -f "$STATE_FILE" ] || { printf 'fixture: armed CAS state is missing\n' >&2; exit 1; }

payload_for() {
  PROBE_SESSION_ID="$SESSION_ID" PROBE_PROJECT="$PROJECT" node "$PROBE" payload "$1" "$2" "${3:-}"
}

shape_payload_for() {
  PROBE_SESSION_ID="$SESSION_ID" PROBE_PROJECT="$PROJECT" node "$PROBE" payload-shape "$1" "$2" "${3:-}"
}

HOOK_STDOUT=''
HOOK_STATUS=0
run_hook() {
  local hook="$1" body="$2" data="${3:-$PLUGIN_DATA}"
  HOOK_STDOUT="$(printf '%s' "$body" | env \
    -u ZENSU_CLAUDE_PLUGIN_ROOT -u ZENSU_SESSION_KEY -u ZENSU_SESSION_CONTEXT \
    -u ZENSU_RUNTIME_DIGEST -u ZENSU_PROJECT_ROOT -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_AGENT_TYPE -u ZENSU_CHAIN -u ZENSU_BASH_WRITE_GATE -u ZENSU_MCP_GATE \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$data" CLAUDE_PROJECT_DIR="$PROJECT" \
    ZENSU_CONFIG="$CONFIG" ZENSU_BSWGATE_TEMP_DIRS="$NO_TEMP_ROOT" \
    bash "$hook" 2>/dev/null)"
  HOOK_STATUS=$?
}

verdict_of() {
  if [ "$HOOK_STATUS" -ne 0 ]; then printf 'deny'; return; fi
  printf '%s' "$HOOK_STDOUT" | node "$PROBE" verdict
}

reason_of() {
  if [ "$HOOK_STATUS" -ne 0 ]; then printf 'hook exited %s' "$HOOK_STATUS"; return; fi
  printf '%s' "$HOOK_STDOUT" | node "$PROBE" reason
}

gate_verdict() {
  run_hook "$GATE" "$(payload_for "$1" "$2" "${3:-}")" "${4:-$PLUGIN_DATA}"
  verdict_of
}

gate_reason() {
  run_hook "$GATE" "$(payload_for "$1" "$2" "${3:-}")" "${4:-$PLUGIN_DATA}"
  reason_of
}

shape_verdict() {
  run_hook "$GATE" "$(shape_payload_for "$1" "$2" "${3:-}")"
  verdict_of
}

shape_reason() {
  run_hook "$GATE" "$(shape_payload_for "$1" "$2" "${3:-}")"
  reason_of
}

assert_verdict() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    check "$label" PASS
  else
    check "$label (expected $expected, got $actual)" FAIL
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    check "$label" PASS
  else
    check "$label (missing '$needle' in '${haystack:-<empty>}')" FAIL
  fi
}

assert_absent() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    check "$label (found '$needle' in '$haystack')" FAIL
  else
    check "$label" PASS
  fi
}

assert_verdict "V00 the harness allows a healthy main-thread call — later denies are not vacuous" \
  allow "$(gate_verdict Read "$PROJECT")"

assert_verdict "V01 main thread keeps Read when its working directory vanished" \
  allow "$(gate_verdict Read "$GONE")"
assert_verdict "V02 main thread keeps Bash when its working directory vanished" \
  allow "$(gate_verdict Bash "$GONE")"
assert_verdict "V03 main thread keeps ToolSearch when its working directory vanished" \
  allow "$(gate_verdict ToolSearch "$GONE")"
assert_verdict "V04 main thread keeps Write when its working directory vanished" \
  allow "$(gate_verdict Write "$GONE")"
assert_verdict "V05 main thread keeps Read when its working directory is a regular file" \
  allow "$(gate_verdict Read "$FILE_CWD")"

REVIEWER_REASON="$(gate_reason Read "$GONE" 'zensu:code-reviewer')"
assert_verdict "V10 a reviewer is denied when the working directory vanished" \
  deny "$(gate_verdict Read "$GONE" 'zensu:code-reviewer')"
assert_contains "V11 the reviewer deny names its profile" \
  'reviewer-readonly-v1' "$REVIEWER_REASON"
assert_contains "V12 the reviewer deny names the working directory" \
  "working directory" "$REVIEWER_REASON"
assert_absent "V13 the reviewer deny drops the generic revalidation wording" \
  'immutable context revalidation failed' "$REVIEWER_REASON"
assert_absent "V14 the reviewer deny offers no main-thread-only repair command" \
  '/zensu:adopt-session' "$REVIEWER_REASON"

PLM_REASON="$(gate_reason Read "$GONE" 'zensu:zensu-plm')"
assert_verdict "V15 a PLM subagent is denied when the working directory vanished" \
  deny "$(gate_verdict Read "$GONE" 'zensu:zensu-plm')"
assert_contains "V16 the PLM deny names its profile" 'zensu-plm-readonly-v1' "$PLM_REASON"
assert_contains "V17 the PLM deny names the working directory" "working directory" "$PLM_REASON"

NEUTRAL_REASON="$(gate_reason Read "$GONE" 'general-purpose')"
assert_verdict "V18 a neutral child is denied when the working directory vanished" \
  deny "$(gate_verdict Read "$GONE" 'general-purpose')"
assert_contains "V19 the neutral deny names its profile" 'host-profile-v1' "$NEUTRAL_REASON"
assert_contains "V1A the neutral deny names the working directory" \
  "working directory" "$NEUTRAL_REASON"
assert_verdict "V1B a neutral child is denied even for a tool that carries no path" \
  deny "$(gate_verdict TaskUpdate "$GONE" 'general-purpose')"

WORKER_HERE="$(gate_reason Read "$PROJECT" 'zensu:pr-review-worker')"
WORKER_GONE="$(gate_reason Read "$GONE" 'zensu:pr-review-worker')"
assert_verdict "V20 an evidence worker is denied with an existing working directory" \
  deny "$(gate_verdict Read "$PROJECT" 'zensu:pr-review-worker')"
assert_verdict "V21 an evidence worker is denied with a vanished working directory" \
  deny "$(gate_verdict Read "$GONE" 'zensu:pr-review-worker')"
if [ -n "$WORKER_HERE" ] && [ "$WORKER_HERE" = "$WORKER_GONE" ]; then
  check "V22 the evidence-worker verdict is decided by its lease, not by the working directory" PASS
else
  check "V22 evidence-worker reason differs by cwd (here='$WORKER_HERE' gone='$WORKER_GONE')" FAIL
fi

EMPTY_REASON="$(gate_reason Read '')"
assert_verdict "V23 an empty cwd still fails the payload shape check for the main thread" \
  deny "$(gate_verdict Read '')"
assert_contains "V24 the empty-cwd deny names the payload shape" \
  'tool cwd is unavailable or unsafe' "$EMPTY_REASON"

SHAPE_REVIEWER_REASON="$(shape_reason Read number 'zensu:code-reviewer')"
assert_verdict "V28 a non-string cwd still fails the payload shape check for a reviewer" \
  deny "$(shape_verdict Read number 'zensu:code-reviewer')"
assert_contains "V28a the non-string-cwd deny names the payload shape" \
  'tool cwd is unavailable or unsafe' "$SHAPE_REVIEWER_REASON"

SHAPE_MAIN_REASON="$(shape_reason Read newline)"
assert_verdict "V29 a control-character cwd still fails the payload shape check for the main thread" \
  deny "$(shape_verdict Read newline)"
assert_contains "V29a the control-character-cwd deny names the payload shape" \
  'tool cwd is unavailable or unsafe' "$SHAPE_MAIN_REASON"

assert_verdict "V25 a record that fails revalidation still denies the main thread with a vanished cwd" \
  deny "$(gate_verdict Read "$GONE" '' "$TAMPERED_DATA")"

REGISTRATIONS="$(node "$PROBE" registrations "$PLUGIN_DIR")"
if [ -z "$REGISTRATIONS" ]; then
  check "V30 the PreToolUse registration enumeration is non-empty" FAIL
else
  check "V30 the PreToolUse registration enumeration is non-empty" PASS
fi
STRICTER=''
UNCOVERED=''
COMPARED=0
AGREED_ALLOW=0
while IFS="$(printf '\t')" read -r pattern hook_name; do
  [ -n "$hook_name" ] || continue
  hook_path="$PLUGIN_DIR/hooks/$hook_name"
  if [ ! -f "$hook_path" ]; then
    UNCOVERED="$UNCOVERED $hook_name(missing)"
    continue
  fi
  tools="$(node "$PROBE" match "$pattern")"
  if [ -z "$tools" ]; then
    UNCOVERED="$UNCOVERED $hook_name($pattern)"
    continue
  fi
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    run_hook "$hook_path" "$(payload_for "$tool" "$PROJECT")"
    here="$(verdict_of)"
    run_hook "$hook_path" "$(payload_for "$tool" "$GONE")"
    gone="$(verdict_of)"
    COMPARED=$((COMPARED + 1))
    if [ "$here" = allow ] && [ "$gone" = allow ]; then
      AGREED_ALLOW=$((AGREED_ALLOW + 1))
    fi
    if [ "$here" != "$gone" ]; then
      STRICTER="$STRICTER $hook_name/$tool($here->$gone)"
    fi
  done <<EOF
$tools
EOF
done <<EOF
$REGISTRATIONS
EOF

if [ -z "$UNCOVERED" ]; then
  check "V31 every PreToolUse registration has a representative payload" PASS
else
  check "V31 registrations without a representative payload:$UNCOVERED" FAIL
fi
if [ "$COMPARED" -gt 0 ] && [ "$AGREED_ALLOW" -gt 0 ]; then
  check "V32 the cross-hook comparison ran and can observe an allow ($COMPARED pairs, $AGREED_ALLOW allowed)" PASS
else
  check "V32 cross-hook comparison is vacuous (compared=$COMPARED allowed=$AGREED_ALLOW)" FAIL
fi
if [ -z "$STRICTER" ]; then
  check "V33 no PreToolUse hook is stricter because the working directory vanished" PASS
else
  check "V33 these hooks change verdict when the working directory vanishes:$STRICTER" FAIL
fi

rm -f "$STATE_FILE"
BASELINE_REASON="$(gate_reason Read "$GONE")"
assert_verdict "V26 a missing workflow document still denies the main thread with a vanished cwd" \
  deny "$(gate_verdict Read "$GONE")"
assert_contains "V27 the missing-document deny keeps naming the document, not the cwd" \
  'workflow document' "$BASELINE_REASON"

printf '%s\n' "----" "test-vanished-session-cwd: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
