#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

{ INPUT="$(cat 2>/dev/null || true)"; } 2>/dev/null
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-agent-context.sh"
zensu_hook_is_main_principal "$INPUT" PostToolUse || exit 0
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
zensu_bind_hook_session "$INPUT" || exit 0

# Resolved BEFORE the field extraction, not after it as this hook used to: the
# extraction now redacts absolute developer paths out of `cmd` (only — see the
# note further down for why the `tail` is left raw), and it needs the project
# root to do that. See that same note for
# why `cmd` is redacted and `tail` is not.
PROJECT_DIR="$(zensu_resolve_project_dir)" || exit 0

# Bypass ledger: the escape stays free, but while a TDD session is active the
# opt-out is recorded to chain state (fail-open, gate name only; per-gate dedup
# makes this once per session). The project-bound state pre-filter keeps the off-path
# free of node spawns when no session was ever armed.
if [ "${ZENSU_TEST_WITNESS:-}" = "off" ]; then
  _state_dir="$PROJECT_DIR/.zensu/state"
  ls "$_state_dir"/tdd-phase-*.json >/dev/null 2>&1 || exit 0
  command -v node >/dev/null 2>&1 || exit 0
  source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
  tdd_record_bypass_payload "$INPUT" ZENSU_TEST_WITNESS 2>/dev/null || true
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then exit 0; fi

# `cmd` is redacted for SYMMETRY, not for the witness's own publication safety.
# The witness is gitignored in THIS repository only; a consuming repo has to add
# `.zensu/state/` and `.zensu/logs/witness-*.log` itself, and until it does, this
# file publishes with the artifacts around it. So do not read what follows as
# "this file never ships" — that claim was retracted across this feature and must
# not come back here. It is redacted because the narrative log is:
# hooks/lib/zensu-evidence-crosscheck.js matches a CHECKPOINT/AUDIT claim
# against a witness entry by EQUALITY, so redacting one side only would turn
# every Phase-6 claim whose command names an absolute path into an EVIDENCE GAP
# and wedge the workflow. Both sides therefore run the same function.
#
# It runs on the RAW strings, before JSON.stringify — redacting the encoded form
# would have to reason about doubled backslashes in a Windows path. Failure is
# fail-OPEN: an unredacted witness line still records the command, while a
# missing one fails the cross-check closed.
#
# `cmd` ONLY. `tail` is deliberately left alone: nothing compares it — the
# cross-check matches on `cmd` equality — and the one thing that reads it is
# `failureMarker`, which scans for FAIL/failed/Error tokens. Redaction there is
# purely subtractive, so a failure token sitting inside an absolute path would
# vanish and an EVIDENCE CONTRADICTION would silently downgrade to `verified`.
# That is the WHOLE argument for leaving it raw, and it is a trade rather than a
# free choice: a consuming repo that has not added the two `.gitignore` lines
# publishes this file with `tail` intact. The evidence channel is judged the more
# valuable of the two, because a cross-check that silently reports `verified` for
# a failed command corrupts every later decision built on it. Do not re-derive
# this from a claim that the file never ships — that is false for a consuming
# repo, and it was retracted everywhere else in this feature.
#
# The module path is transported through mechanism 2 of the two this repo
# accepts (tests/structure/test-msys-special-plugin-module-boundaries.sh):
# zensu-host-path.sh renders the lib DIRECTORY natively, the file name is
# appended, and the guarded result travels in an environment variable. A raw
# MSYS spelling would make `require()` fail on a Git Bash root and the fail-open
# branch would then silently stop redacting.
ZENSU_REDACT_LIB_DIR="$(bash "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-host-path.sh" \
  "$CLAUDE_PLUGIN_ROOT/hooks/lib")" || ZENSU_REDACT_LIB_DIR=""
ZENSU_REDACT_LIB_PATH="$ZENSU_REDACT_LIB_DIR/zensu-artifact-redact-v1.js"
if [ -z "$ZENSU_REDACT_LIB_DIR" ] || [ ! -f "$ZENSU_REDACT_LIB_PATH" ] \
  || [ -L "$ZENSU_REDACT_LIB_PATH" ]; then
  ZENSU_REDACT_LIB_PATH=""
fi

TMP_FIELDS="$(mktemp 2>/dev/null)" || exit 0
printf '%s' "$INPUT" | \
  ZENSU_REDACT_LIB="$ZENSU_REDACT_LIB_PATH" \
  ZENSU_REDACT_PROJECT="$PROJECT_DIR" \
  node -e '
  const chunks = [];
  let redact = (v) => v;
  try {
    const mod = require(process.env.ZENSU_REDACT_LIB);
    // Both candidate roots, for the same reason `append` passes both: the two
    // writers derive the root from different authorities and must substitute
    // identically or the equality match reports an EVIDENCE GAP.
    const opts = {
      projectRoot: [
        process.env.ZENSU_REDACT_PROJECT || "",
        process.env.CLAUDE_PROJECT_DIR || "",
      ].filter(Boolean),
      // The module resolution, not a hand-copy: rule 2 is half of the
      // substitution the two writers must agree on, and zensu-log.sh append
      // calls mod.defaultHome(). A divergence here is an EVIDENCE GAP.
      home: mod.defaultHome(),
    };
    if (typeof mod.redact !== "function" || typeof mod.defaultHome !== "function") {
      throw new Error("redactor exports missing");
    }
    // The fallback must wrap the CALL, not just the load: a throw from redact
    // would otherwise reach the outer handler, which emits an empty session
    // field and drops the whole witness ENTRY — fail-CLOSED, and the opposite
    // of what the comment above promises.
    redact = (v) => { try { return mod.redact(v, opts); } catch (_) { return v; } };
  } catch (_) { /* fail open: an unredacted line beats a missing one */ }
  // Buffers, then one decode: a per-chunk decode corrupts a multi-byte character
  // that straddles a chunk boundary, and `cmd` is matched by EQUALITY.
  process.stdin.on("data", c => chunks.push(Buffer.from(c)));
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const cmd = (j.tool_input && typeof j.tool_input.command === "string") ? redact(j.tool_input.command) : "";
      const exit = (j.tool_response && typeof j.tool_response.exit_code === "number") ? String(j.tool_response.exit_code) : "?";
      const stdout = (j.tool_response && typeof j.tool_response.stdout === "string") ? j.tool_response.stdout : "";
      const tail = stdout.slice(-200);
      const interrupted = (j.tool_response && j.tool_response.interrupted === true) ? "true" : "false";
      const session = (typeof j.session_id === "string" && j.session_id) ? j.session_id : "";
      process.stdout.write(JSON.stringify(cmd) + "\n" + exit + "\n" + JSON.stringify(tail) + "\n" + interrupted + "\n" + session + "\n");
    } catch (_) { process.stdout.write("\"\"\n?\n\"\"\nfalse\n\n"); }
  });
' > "$TMP_FIELDS" 2>/dev/null

{ read -r CMD_JSON; read -r EXIT_CODE; read -r TAIL_JSON; read -r INTERRUPTED; read -r SESSION; } < "$TMP_FIELDS"
rm -f "$TMP_FIELDS"
SANITIZED_SESSION="$(zensu_resolve_session_id "$SESSION")" || exit 0

# Activation: record witness lines only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). Replaces
# the legacy CLAUDE_AGENT_TYPE=zensu:tdd-manager subagent scoping.
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"
if [ "$(tdd_session_active "$(tdd_state_file "$SANITIZED_SESSION")")" != "true" ]; then
  exit 0
fi

WITNESS_DIR="$PROJECT_DIR/.zensu/logs"
WITNESS_LOG="$WITNESS_DIR/witness-${SANITIZED_SESSION}.log"
mkdir -p "$WITNESS_DIR" 2>/dev/null || exit 0

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-config.sh"
TS_PREFIX=""
if [ "$(_zensu_log_style)" != "none" ]; then
  TS_PREFIX="[$(date +%H:%M:%S)] "
fi
printf '%sBASH cmd=%s exit=%s tail=%s interrupted=%s\n' "$TS_PREFIX" "$CMD_JSON" "$EXIT_CODE" "$TAIL_JSON" "$INTERRUPTED" >> "$WITNESS_LOG" 2>/dev/null || true

exit 0
