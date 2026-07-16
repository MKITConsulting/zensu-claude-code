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
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
  echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
  exit 2
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null || true)"

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

VERDICT="$(printf '%s' "$INPUT" | node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/secret-scan-decide.js")"
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
        "the README (§ Secret Scan) rather than inlined here, so turning the whole gate " +
        "off stays a deliberate, human choice."
    }
  }));
'
echo
exit 0
