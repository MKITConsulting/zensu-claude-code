#!/bin/bash
# pre-bash-source-write-gate.sh — PreToolUse(Bash) integrity gate for source files.
#
# The plugin gates Edit|Write|MultiEdit (pre-edit-tdd-reminder.sh) and the typed
# `zensu` CLI (pre-bash-zensu-gate.sh), but nothing inspected raw Bash commands
# that write to source files. A low-context agent can corrupt tracked source via
# `printf >> file.rs`, `cat > file.rs <<EOF`, `sed -i`, `tee`, `dd of=` — bypassing
# the Edit gate — and worse, can `cd` into a sibling/main checkout and clobber
# another session's working tree. This hook closes both holes.
#
# It DENIES a write through one of those channels to a source-extension file when
# either:
#   (A) the file already exists and is git-tracked inside the project (clobbering
#       real tracked source), or
#   (B) the resolved path escapes the session root (CLAUDE_PROJECT_DIR / cwd) into
#       a sibling or main checkout — the cross-session contamination vector.
# Relative targets resolve against a cwd that tracks `cd` across the command, so
# `cd ../main && printf ... >> src/x.rs` is caught by (B).
#
# Deliberately NOT a security boundary — an agent can still bypass via the escape
# hatch (inline `ZENSU_BASH_WRITE_GATE=off` / `ZENSU_MCP_GATE=off`, the process-env
# equivalents, or config `hooks.bashWriteGate:false`). It is a discipline nudge:
# route source edits through the Edit/Write tools (observable, gate-aware) and stay
# inside your own worktree. Carve-outs never denied: a NEW file inside the project,
# gitignored/untracked files, non-source extensions, and temp roots ($TMPDIR, /tmp,
# /private/tmp, /var/folders). mv/cp are out of scope.
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)" || exit 2
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$CLAUDE_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
  echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
  exit 2
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT

command -v node >/dev/null 2>&1 || exit 0

# Drain stdin before any early exit so an upstream writer never sees a broken
# pipe (mirrors pre-bash-zensu-gate.sh's ordering).
INPUT="$(cat 2>/dev/null || true)"

emit_deny() {
  REASON="$1" node -e '
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: process.env.REASON
      }
    }));
  '
  echo
}

# Session Control export rebinding is a trust-boundary violation, not a
# configurable source-write convention. Check it before config/escape hatches.
CONTROL_REASON="$(BSWG_MODE=control PAYLOAD="$INPUT" node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bash-source-write-parse.js" 2>/dev/null)"
if [ -n "$CONTROL_REASON" ]; then
  emit_deny "$CONTROL_REASON"
  exit 0
fi

# Config-disabled gate has no decision point — nothing to bypass, nothing to
# ledger (kept ahead of the escape checks so all Bash gates share the order).
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled bashWriteGate || exit 0

# Bypass ledger: escapes stay free, but while a TDD session is active the
# opt-out is recorded to chain state (fail-open, gate name only). Inline
# escapes are reported by the parser itself (__bypass__ markers) — the ONE
# code path that decides the bypass — so quoted spellings and mixed commands
# are covered and mere textual mentions are not.
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"

# Process-env escapes.
[ "${ZENSU_BASH_WRITE_GATE:-}" = "off" ] && { tdd_record_bypass_payload "$INPUT" ZENSU_BASH_WRITE_GATE 2>/dev/null || true; exit 0; }
[ "${ZENSU_MCP_GATE:-}" = "off" ] && { tdd_record_bypass_payload "$INPUT" ZENSU_MCP_GATE 2>/dev/null || true; exit 0; }

[ -z "$INPUT" ] && exit 0

REASON="$(BSWG_MODE= PAYLOAD="$INPUT" node "${CLAUDE_PLUGIN_ROOT}/hooks/lib/bash-source-write-parse.js" 2>/dev/null)"
case "$REASON" in
  __bypass__*)
    for gate in $(printf '%s\n' "$REASON" | awk -F'\t' '$1=="__bypass__"{print $2}'); do
      case "$gate" in
        ZENSU_BASH_WRITE_GATE|ZENSU_MCP_GATE)
          tdd_record_bypass_payload "$INPUT" "$gate" 2>/dev/null || true
          ;;
      esac
    done
    exit 0
    ;;
esac
[ -z "$REASON" ] && exit 0

emit_deny "$REASON"
exit 0
