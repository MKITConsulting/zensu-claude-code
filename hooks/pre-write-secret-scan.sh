#!/bin/bash
# pre-write-secret-scan.sh — PreToolUse secret gate for Edit|Write|MultiEdit,
# NotebookEdit, and Bash.
#
# The source-write gate protects WHICH files raw Bash may write; nothing
# inspected WHAT gets written. This hook closes that gap: it scans the payload
# about to land in a file — Write `content`, Edit `new_string`, MultiEdit
# `edits[].new_string`, NotebookEdit `new_source`, and (for Bash) the command
# text whenever a write channel is present (redirect / tee / sed -i / dd of= /
# heredoc, detected via the shared parser's detectChannels) — against the
# curated rule set in hooks/lib/secret-patterns.js (the single source of truth:
# provider tokens + a Shannon-entropy assignment heuristic, no naive catch-all).
# The decision logic lives in hooks/lib/secret-scan-decide.js (payload on
# stdin, matched rule names on stdout).
#
# Never denied (allowlist): file-tool targets under a test(s)/, __tests__/,
# spec(s)/, testdata/, evals/ or fixtures/ directory segment or *.example.*
# files (NOT applicable to the Bash channel — its targets are not resolved;
# use the marker or escape hatch there); lines carrying the zensu-secret-allow
# marker; obvious placeholder values (EXAMPLE, PLACEHOLDER, CHANGE_ME, YOUR_,
# XXXX, ..., <angle>, {{template}}, ${var}); Bash commands carrying an inline
# ZENSU_SECRET_SCAN=off prefix outside heredoc bodies (parity with the sibling
# gates). Parser or node errors FAIL OPEN — allow, with a note on stderr.
#
# Deliberately NOT a security boundary — bypass via ZENSU_SECRET_SCAN=off env,
# the inline prefix (Bash), or config hooks.secretScan:false. It is a
# discipline nudge that keeps real-looking credentials out of files.
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

command -v node >/dev/null 2>&1 || exit 0

{ INPUT="$(cat 2>/dev/null || true)"; } 2>/dev/null

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
ZENSU_SESSION_BOUND=true
zensu_bind_hook_session "$INPUT" || ZENSU_SESSION_BOUND=false
if [ "$ZENSU_SESSION_BOUND" != true ]; then
  # This hook matches Bash as well as Edit/Write, and it denied on the bind
  # BEFORE inspecting anything — so it blocked every Bash call, including
  # /zensu:doctor, and neither secretScan:false nor ZENSU_SECRET_SCAN=off could
  # reach far enough to release it. Relax the TWO states that leave no workflow
  # state to enforce — no record at all, and a record whose recorded project root
  # is gone — and then fall through to the ORDINARY decision below:
  # secret-scan-decide.js reads only the payload, so it needs no binding and
  # reaches exactly the verdict a bound session would. Deciding differently here
  # would either deny ordinary commands (its channel detector deliberately
  # over-detects, so any `>` in an argument would look like a write) or leave
  # Edit/Write content unscanned. The only thing skipped is the bypass ledger,
  # which is keyed by the binding that does not exist.
  #
  # Both must be relaxed HERE, not only in the sibling Bash gates: hooks.json
  # registers three PreToolUse hooks on the Bash matcher and a deny from ANY of
  # them wins, so leaving this one closed silently reinstated the exact deadlock
  # the relaxation exists to remove. stdout is the JSON decision channel, so the
  # orphaned probe's printed path is discarded.
  # The two recognized commands come FIRST, for the same reason they do in the
  # sibling Bash gates: they are reachable in every bind failure, not only in the
  # two relaxable states, and a deny from ANY hook on this matcher wins — so
  # leaving this one closed would silently reinstate the deadlock the allowance
  # removes. Both are closed whitelisted shapes (a fixed set of assignments, one
  # `bash <script in the executing installation>`, and at most `--confirm`), so
  # neither can carry secret-bearing content for this gate to scan. That the
  # second one WRITES is irrelevant here — this gate scans payloads, it does not
  # judge writes; see the header of hooks/lib/zensu-session-adopt.sh for the
  # justification that admits it.
  if zensu_doctor_allowed "$INPUT"; then
    exit 0
  fi
  if ! zensu_session_unregistered "$INPUT" \
    && ! zensu_session_orphaned_project_root "$INPUT" >/dev/null; then
    # Neither relaxable state. Before falling back to the generic wording, ask the
    # one remaining question that has a remedy working IN PLACE: is this the
    # declared-incompatible lineage? Without this the user reads "start a fresh
    # Claude Code session" from this gate while the Bash and Edit gates say the
    # session can be adopted — two denies contradicting each other on the remedy,
    # for the exact state this feature exists to repair. stdout is the JSON
    # decision channel, so the predicate output is captured, never leaked.
    if ZENSU_LINEAGE="$(zensu_session_incompatible_runtime "$INPUT")" \
      && [ -n "$ZENSU_LINEAGE" ]; then
      zensu_emit_hook_session_deny incompatible-runtime \
        "${ZENSU_LINEAGE%%$'\t'*}" "${ZENSU_LINEAGE##*$'\t'}"
      exit 0
    fi
    zensu_emit_hook_session_deny narrowed
    exit 0
  fi
  # The relaxation is for the interactive thread only. The all-tool capability
  # gate denies every other principal in this state, but this gate must not rely
  # on that single layer to keep a reviewer or neutral child out of a shell.
  ZENSU_AGENT_CONTEXT_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-agent-context.sh"
  if [ ! -r "$ZENSU_AGENT_CONTEXT_LIB" ]; then
    zensu_emit_hook_session_deny damaged-runtime
    exit 0
  fi
  # shellcheck disable=SC1090
  source "$ZENSU_AGENT_CONTEXT_LIB"
  if ! zensu_hook_is_main_principal "$INPUT" PreToolUse; then
    zensu_emit_hook_session_deny
    exit 0
  fi
fi

# Config-disabled gate has no decision point — nothing to bypass, nothing to
# ledger (kept ahead of the escape checks so all Bash gates share the order).
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled secretScan || exit 0

# Bypass ledger: escapes stay free, but while a TDD session is active the
# opt-out is recorded to chain state (fail-open, gate name only). The inline
# escape is reported by the decider itself (__bypass__ verdict) — the one code
# path that decides the bypass (heredoc-stripped, segment-leading env prefix,
# write-channel commands only) — so a heredoc body, a channel-less command, or
# an argument merely mentioning the escape never produces a ledger entry.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"

[ "${ZENSU_SECRET_SCAN:-}" = "off" ] && { tdd_record_bypass_payload "$INPUT" ZENSU_SECRET_SCAN 2>/dev/null || true; exit 0; }

[ -z "$INPUT" ] && exit 0

VERDICT="$(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
  printf '%s' "$INPUT" | node ./secret-scan-decide.js
)"
NODE_RC=$?
if [ "$NODE_RC" -ne 0 ]; then
  echo "zensu secret-scan: scanner error (rc=$NODE_RC), failing open" >&2
  exit 0
fi
if [ "$VERDICT" = "__bypass__:ZENSU_SECRET_SCAN" ]; then
  tdd_record_bypass_payload "$INPUT" ZENSU_SECRET_SCAN 2>/dev/null || true
  exit 0
fi
[ -z "$VERDICT" ] && exit 0

RULES="$VERDICT" node -e '
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason:
        "Blocked: the payload matches secret pattern(s): " + process.env.RULES + ". " +
        "Real-looking credentials must not land in files. Legitimate fixture options: " +
        "for the Write/Edit tools, place it under a test(s)/, __tests__/, spec(s)/, testdata/, " +
        "evals/ or fixtures/ path or an *.example.* file; on any channel, append the " +
        "zensu-secret-allow marker to that line or use an obvious placeholder (EXAMPLE, " +
        "YOUR_...). Prefer the surgical, auditable escape (the allow marker, visible in " +
        "the diff) over disabling the gate. A blanket opt-out exists but is documented in " +
        "docs/gates.md (§ Secret Scan) rather than inlined here, so turning the whole gate " +
        "off stays a deliberate, human choice."
    }
  }));
'
echo
exit 0
