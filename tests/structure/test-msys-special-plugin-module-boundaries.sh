#!/bin/bash
# Integration canary for native-Node module loading from a plugin root whose
# shell spelling contains both whitespace and an apostrophe.  Git Bash cannot
# safely be trusted to heuristically translate those absolute module paths, so
# a production launcher must use one of exactly TWO accepted mechanisms, and
# this test executes them rather than pinning their source text:
#
#   1. resolve the module from a validated working directory (cd -P into
#      hooks/lib, then a cwd-relative require).  Most launchers do this, and the
#      node shim below enforces it by rejecting the root in any argv token.
#   2. render the module DIRECTORY through hooks/lib/zensu-host-path.sh, append
#      the file name, and transport the result in an environment variable
#      (hooks/lib/zensu-tdd-phase.sh and hooks/plan-approved-delegate.sh).
#
# The shim cannot police mechanism 2 by scanning argv, and widening it to reject
# the root in ANY environment value would reject every invocation, because
# CLAUDE_PLUGIN_ROOT legitimately carries it.  Mechanism 2 is probed directly at
# the end of this file instead: the conversion plus the load must work from this
# special root.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

RAW_TMP="$(mktemp -d -t zensu-special-modules-XXXXXX)" || exit 1
trap 'rm -rf -- "$RAW_TMP"' EXIT

PLUGIN="$RAW_TMP/plugin root O'Brien"
PROJECT="$RAW_TMP/project root O'Brien"
PLUGIN_DATA="$RAW_TMP/plugin data O'Brien"
WORKSPACE="$RAW_TMP/review workspace O'Brien"
HOME_DIR="$RAW_TMP/home"
CONFIG="$RAW_TMP/config.json"
mkdir -p "$PLUGIN" "$PROJECT/src" "$PLUGIN_DATA" "$WORKSPACE" "$HOME_DIR"
chmod 700 "$WORKSPACE" 2>/dev/null || true

if cp -R "$ROOT/.claude-plugin" "$ROOT/hooks" "$ROOT/agents" "$ROOT/skills" \
    "$ROOT/scripts" "$ROOT/mcp-runtime" "$PLUGIN/" \
    && cp "$ROOT/.mcp.json" "$PLUGIN/.mcp.json"; then
  check "special plugin fixture copies the complete executable runtime" PASS
else
  check "special plugin fixture copies the complete executable runtime" FAIL
  printf '%s\n' '----' "test-msys-special-plugin-module-boundaries: $PASS PASS / $FAIL FAIL"
  exit 1
fi

PLUGIN="$(cd -P -- "$PLUGIN" && pwd -P)" || exit 1
PROJECT="$(cd -P -- "$PROJECT" && pwd -P)" || exit 1
PLUGIN_DATA="$(cd -P -- "$PLUGIN_DATA" && pwd -P)" || exit 1
WORKSPACE="$(cd -P -- "$WORKSPACE" && pwd -P)" || exit 1
HOST_PATH="$PLUGIN/hooks/lib/zensu-host-path.sh"
NATIVE_PROJECT="$(bash "$HOST_PATH" "$PROJECT")" || exit 1
NATIVE_WORKSPACE="$(bash "$HOST_PATH" "$WORKSPACE")" || exit 1

# Make the regression deterministic on POSIX too: emulate native Node's
# inability to consume the old transported absolute module argument.  The shim
# accepts `-e`, stdin programs, and cwd-relative modules, but rejects any argv
# token that leaks this special plugin root.  Data paths use distinct project,
# plugin-data, and workspace names, so the check is scoped to code loading.
REAL_NODE="$(command -v node)" || exit 1
NODE_SHIM_DIR="$RAW_TMP/native-node-shim"
mkdir -p "$NODE_SHIM_DIR"
cat > "$NODE_SHIM_DIR/node" <<'SHIM'
#!/bin/bash
for argument in "$@"; do
  case "$argument" in
    *"plugin root O'Brien"*)
      printf '%s\n' 'absolute special-plugin module transport rejected by native-node canary' >&2
      exit 97
      ;;
  esac
done
exec "${ZENSU_TEST_REAL_NODE:?}" "$@"
SHIM
chmod +x "$NODE_SHIM_DIR/node"
export ZENSU_TEST_REAL_NODE="$REAL_NODE"
export PATH="$NODE_SHIM_DIR:$PATH"

printf '%s\n' '# boundary fixture' > "$PROJECT/README.md"
printf '%s\n' 'const original = true;' > "$PROJECT/src/app.js"
git -C "$NATIVE_PROJECT" init -q \
  && git -C "$NATIVE_PROJECT" config user.email boundary@example.test \
  && git -C "$NATIVE_PROJECT" config user.name 'Boundary Test' \
  && git -C "$NATIVE_PROJECT" add README.md src/app.js \
  && git -C "$NATIVE_PROJECT" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -qm fixture \
  || exit 1

printf '%s\n' \
  '{"hooks":{"sessionBanner":true,"tddImplementation":false,"secretScan":true,"bashWriteGate":true}}' \
  > "$CONFIG"
printf '%s\n' 'boundary evidence' > "$WORKSPACE/EVIDENCE.md"
printf '%s\n' "$NATIVE_PROJECT/README.md" "$NATIVE_PROJECT/src/app.js" \
  > "$WORKSPACE/FILES.txt"
printf '%s\n' "$NATIVE_PROJECT/src" > "$WORKSPACE/ROOTS.txt"

SESSION='special-module-boundary-session'
AGENT_ID='special-module-worker'
AGENT_TYPE='zensu:plan-review-worker'

session_payload() {
  SESSION_VALUE="$SESSION" PROJECT_VALUE="$NATIVE_PROJECT" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "SessionStart", source: "startup",
      session_id: process.env.SESSION_VALUE, cwd: process.env.PROJECT_VALUE,
    }));
  '
}

worker_payload() {
  local event="$1" message="${2:-}"
  EVENT="$event" SESSION_VALUE="$SESSION" PROJECT_VALUE="$NATIVE_PROJECT" \
    AGENT_ID_VALUE="$AGENT_ID" AGENT_TYPE_VALUE="$AGENT_TYPE" MESSAGE="$message" node -e '
      const payload = {
        hook_event_name: process.env.EVENT,
        session_id: process.env.SESSION_VALUE,
        cwd: process.env.PROJECT_VALUE,
        agent_id: process.env.AGENT_ID_VALUE,
        agent_type: process.env.AGENT_TYPE_VALUE,
      };
      if (payload.hook_event_name === "SubagentStop") {
        payload.last_assistant_message = process.env.MESSAGE;
      }
      process.stdout.write(JSON.stringify(payload));
    '
}

read_payload() {
  SESSION_VALUE="$SESSION" PROJECT_VALUE="$NATIVE_PROJECT" \
    AGENT_ID_VALUE="$AGENT_ID" AGENT_TYPE_VALUE="$AGENT_TYPE" \
    FILE_VALUE="$NATIVE_PROJECT/README.md" node -e '
      process.stdout.write(JSON.stringify({
        hook_event_name: "PreToolUse",
        session_id: process.env.SESSION_VALUE,
        cwd: process.env.PROJECT_VALUE,
        agent_id: process.env.AGENT_ID_VALUE,
        agent_type: process.env.AGENT_TYPE_VALUE,
        tool_name: "Read",
        tool_input: { file_path: process.env.FILE_VALUE },
      }));
    '
}

SESSION_OUT="$(session_payload \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    env -u ZENSU_SOURCE_REVISION -u ZENSU_SOURCE_REVISION_AUTHORITY \
      bash "$PLUGIN/hooks/session-start-session-control.sh" \
      2>"$RAW_TMP/session-start.err")"
SESSION_RC=$?
if [ "$SESSION_RC" -eq 0 ] \
    && printf '%s' "$SESSION_OUT" | grep -qF '"hookEventName":"SessionStart"' \
    && printf '%s' "$SESSION_OUT" | grep -qF '"additionalContext"'; then
  check "SessionStart binds the special plugin, data, and project roots" PASS
else
  check "SessionStart binds the special plugin, data, and project roots" FAIL
fi

HELPER="$PLUGIN/hooks/lib/zensu-review-evidence.sh"
CREATE_OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SESSION" bash "$HELPER" create --kind plan-review \
    --files-manifest "$NATIVE_WORKSPACE/FILES.txt" \
    --safe-subtrees-manifest "$NATIVE_WORKSPACE/ROOTS.txt" \
    --required-file "$NATIVE_WORKSPACE/EVIDENCE.md" \
    --max-workers 1 --ttl-seconds 600 2>"$RAW_TMP/evidence-create.err")"
CREATE_RC=$?
case "$CREATE_OUT" in
  lease_id=rel1_????????????????????????????????)
    [ "$CREATE_RC" -eq 0 ] \
      && check "evidence helper loads its policy from the special plugin root" PASS \
      || check "evidence helper loads its policy from the special plugin root" FAIL
    ;;
  *)
    check "evidence helper loads its policy from the special plugin root" FAIL
    ;;
esac
LEASE_ID="${CREATE_OUT#lease_id=}"

START_OUT="$(worker_payload SubagentStart \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    bash "$PLUGIN/hooks/review-evidence-subagent-start.sh" \
      2>"$RAW_TMP/evidence-start.err")"
START_RC=$?
if [ "$START_RC" -eq 0 ] && printf '%s' "$START_OUT" | grep -qF 'evidence-worker-v1 bound'; then
  check "evidence SubagentStart loads its hook policy from the special plugin root" PASS
else
  check "evidence SubagentStart loads its hook policy from the special plugin root" FAIL
fi

CAPABILITY_OUT="$(read_payload \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    bash "$PLUGIN/hooks/pre-reviewer-capability-gate.sh" \
      2>"$RAW_TMP/capability.err")"
CAPABILITY_RC=$?
if [ "$CAPABILITY_RC" -eq 0 ] && [ -z "$CAPABILITY_OUT" ]; then
  check "reviewer capability policy allows the exact leased Read from the special plugin root" PASS
else
  check "reviewer capability policy allows the exact leased Read from the special plugin root" FAIL
fi

PLAN_RESULT="$(node -e '
  process.stdout.write(JSON.stringify({
    kind: "plan-review", role: "feasibility-soundness", verdict: "go",
    confidence: "high", summary: "The boundary evidence is coherent.",
    blockers: [], improvements: [], questions: [],
    strengths: ["The native module boundary executed."],
  }));
')"
STOP_OUT="$(worker_payload SubagentStop "$PLAN_RESULT" \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    bash "$PLUGIN/hooks/review-evidence-subagent-stop.sh" \
      2>"$RAW_TMP/evidence-stop.err")"
STOP_RC=$?
FINALIZE_OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SESSION" bash "$HELPER" finalize --lease-id "$LEASE_ID" \
    2>"$RAW_TMP/evidence-finalize.err")"
FINALIZE_RC=$?
CLOSE_OUT="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
  CLAUDE_CODE_SESSION_ID="$SESSION" bash "$HELPER" close --lease-id "$LEASE_ID" \
    2>"$RAW_TMP/evidence-close.err")"
CLOSE_RC=$?
if [ "$STOP_RC" -eq 0 ] && [ -z "$STOP_OUT" ] \
    && [ "$FINALIZE_RC" -eq 0 ] && [ "$FINALIZE_OUT" = "sealed=$LEASE_ID" ] \
    && [ "$CLOSE_RC" -eq 0 ] && [ "$CLOSE_OUT" = "closed=$LEASE_ID" ]; then
  check "evidence SubagentStop stores, seals, and closes through the special plugin root" PASS
else
  check "evidence SubagentStop stores, seals, and closes through the special plugin root" FAIL
fi

VERSION="$(node -e '
  const manifest = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
  process.stdout.write(manifest.version);
' < "$PLUGIN/.claude-plugin/plugin.json")" || exit 1
BANNER_OUT="$(session_payload \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" HOME="$HOME_DIR" ZENSU_CONFIG="$CONFIG" \
    bash "$PLUGIN/hooks/session-start-banner.sh" 2>"$RAW_TMP/banner.err")"
BANNER_RC=$?
if [ "$BANNER_RC" -eq 0 ] && printf '%s' "$BANNER_OUT" | grep -qF "Zensu PLM v$VERSION active"; then
  check "banner loads plugin.json from the special plugin root" PASS
else
  check "banner loads plugin.json from the special plugin root" FAIL
fi

DOCTOR_OUT="$(env -u ZDOC_PLAYWRIGHT \
  CLAUDE_PLUGIN_ROOT="$PLUGIN" HOME="$HOME_DIR" ZENSU_CONFIG="$CONFIG" \
  CLAUDE_PROJECT_DIR="$PROJECT" ZENSU_DOCTOR_PLUGIN_DIR="$PLUGIN" \
  ZDOC_ZENSU=absent ZDOC_NODE=vTEST ZDOC_FORGE_PROVIDER=github \
  ZDOC_FORGE_CLI=gh ZDOC_FORGE_STATE=missing ZDOC_PLAYWRIGHT_TOOLS=ready \
  bash "$PLUGIN/hooks/lib/zensu-doctor.sh" 2>"$RAW_TMP/doctor.err")"
DOCTOR_RC=$?
if [ "$DOCTOR_RC" -eq 0 ] \
    && printf '%s' "$DOCTOR_OUT" | grep -qF 'Zensu doctor' \
    && printf '%s' "$DOCTOR_OUT" | grep -qF 'Playwright MCP: loaded and ready'; then
  check "doctor loads its report, manifests, and proxy from the special plugin root" PASS
else
  check "doctor loads its report, manifests, and proxy from the special plugin root" FAIL
fi

SECRET_PAYLOAD="$(SESSION_VALUE="$SESSION" PROJECT_VALUE="$NATIVE_PROJECT" \
  FILE_VALUE="$NATIVE_PROJECT/src/app.js" node -e '
    process.stdout.write(JSON.stringify({
      hook_event_name: "PreToolUse", session_id: process.env.SESSION_VALUE,
      cwd: process.env.PROJECT_VALUE, tool_name: "Write",
      tool_input: {
        file_path: process.env.FILE_VALUE,
        content: "const key = \\\"AKIAIOSFODNN7RGY4Q2B\\\";",
      },
    }));
  ')"
SECRET_OUT="$(printf '%s' "$SECRET_PAYLOAD" \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" HOME="$HOME_DIR" ZENSU_CONFIG="$CONFIG" \
    bash "$PLUGIN/hooks/pre-write-secret-scan.sh" 2>"$RAW_TMP/secret-scan.err")"
SECRET_RC=$?
if [ "$SECRET_RC" -eq 0 ] \
    && printf '%s' "$SECRET_OUT" | grep -qF '"permissionDecision":"deny"' \
    && printf '%s' "$SECRET_OUT" | grep -qF 'aws-access-key-id'; then
  check "secret scanner loads its decider from the special plugin root" PASS
else
  check "secret scanner loads its decider from the special plugin root" FAIL
fi

BASH_PAYLOAD="$(SESSION_VALUE="$SESSION" PROJECT_VALUE="$NATIVE_PROJECT" node -e '
  process.stdout.write(JSON.stringify({
    hook_event_name: "PreToolUse", session_id: process.env.SESSION_VALUE,
    cwd: process.env.PROJECT_VALUE, tool_name: "Bash",
    tool_input: { command: "printf changed > src/app.js" },
  }));
')"
# This canary validates module loading and tracked-source classification, not the
# configurable temp carveout. Disable that carveout so mktemp under /tmp on Linux
# behaves identically to macOS runners whose mktemp root is /var/folders.
BASH_OUT="$(printf '%s' "$BASH_PAYLOAD" \
  | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$PLUGIN_DATA" \
    CLAUDE_PROJECT_DIR="$PROJECT" HOME="$HOME_DIR" ZENSU_CONFIG="$CONFIG" \
    ZENSU_BSWGATE_TEMP_DIRS= \
    bash "$PLUGIN/hooks/pre-bash-source-write-gate.sh" 2>"$RAW_TMP/bash-parser.err")"
BASH_RC=$?
if [ "$BASH_RC" -eq 0 ] \
    && printf '%s' "$BASH_OUT" | grep -qF '"permissionDecision":"deny"' \
    && printf '%s' "$BASH_OUT" | grep -qF 'git-tracked source file'; then
  check "Bash source gate loads both parser passes from the special plugin root" PASS
else
  check "Bash source gate loads both parser passes from the special plugin root" FAIL
fi

# The plan gate uses the second accepted mechanism (see the header): the module
# path never enters argv, so the shim above cannot see it. What has to hold is
# that the DIRECTORY conversion survives a root carrying whitespace and an
# apostrophe and that the resulting spelling is loadable by native Node.
PLAN_LIB_DIR="$(bash "$PLUGIN/hooks/lib/zensu-host-path.sh" "$PLUGIN/hooks/lib" 2>/dev/null)"
PLAN_LIB="${PLAN_LIB_DIR:+$PLAN_LIB_DIR/plan-payload-v1.js}"
if [ -n "$PLAN_LIB" ] && [ -f "$PLAN_LIB" ] && [ -r "$PLAN_LIB" ] && [ ! -L "$PLAN_LIB" ] \
  && PLAN_PAYLOAD_LIB="$PLAN_LIB" node -e '
    const m=require(process.env.PLAN_PAYLOAD_LIB);
    process.exit(typeof m.resolveApprovedPlan==="function" && Array.isArray(m.SOURCES) ? 0 : 1);
  ' 2>/dev/null; then
  check "plan-gate module converts and loads from the special plugin root" PASS
else
  check "plan-gate module converts and loads from the special plugin root" FAIL
fi


if [ "$FAIL" -ne 0 ]; then
  for diagnostic in "$RAW_TMP"/*.err; do
    [ -s "$diagnostic" ] || continue
    sed "s|^|    $(basename "$diagnostic"): |" "$diagnostic" >&2
  done
fi

printf '%s\n' '----' "test-msys-special-plugin-module-boundaries: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
