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

_ZENSU_MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:-}"
case ";${_ZENSU_MSYS2_ENV_CONV_EXCL};" in
  *';CLAUDE_ENV_FILE;'*) ;;
  *) _ZENSU_MSYS2_ENV_CONV_EXCL="${_ZENSU_MSYS2_ENV_CONV_EXCL:+${_ZENSU_MSYS2_ENV_CONV_EXCL};}CLAUDE_ENV_FILE" ;;
esac

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
if ! CONTROL_REASON="$(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
  MSYS2_ENV_CONV_EXCL="$_ZENSU_MSYS2_ENV_CONV_EXCL" \
    BSWG_MODE=control PAYLOAD="$INPUT" node ./bash-source-write-parse.js 2>/dev/null
)"; then
  emit_deny "Zensu could not validate protected Session Control bindings; retry in a fresh session."
  exit 0
fi
if [ -n "$CONTROL_REASON" ]; then
  emit_deny "$CONTROL_REASON"
  exit 0
fi

# Config-disabled gate has no decision point — nothing to bypass, nothing to
# ledger (kept ahead of the escape checks so all Bash gates share the order).
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled bashWriteGate || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
ZENSU_SESSION_BOUND=true
zensu_bind_hook_session "$INPUT" || ZENSU_SESSION_BOUND=false

# A session Session Control never registered used to lose EVERY Bash call, which
# deadlocked /zensu:doctor behind the very defect it exists to report: the
# diagnostic runs through Bash, so the one command that names the cause was
# denied by the cause. Keep the write rules and let every other command through.
#
# A session whose recorded project root was deleted (a recycled worktree) is the
# same deadlock with a different cause, so it is relaxed the same way and for
# the same reason. Both are relaxed for the DIAGNOSTIC, not for work: neither
# state can anchor a write to a project, so the Edit/Write gates keep denying
# and the rules below still apply to every Bash write.
#
# ONLY those two states are relaxed. Both predicates are false for a record that
# exists and disagrees about anything else — including a root that still exists
# but no longer matches — which keeps failing closed here as before, and a
# second disagreement is never relaxed alongside the first. stdout of the
# orphaned probe is discarded because stdout here is the hook's JSON decision
# channel. The Session Control rebind check above is unaffected: it runs before
# the bind and remains the real trust boundary.
if [ "$ZENSU_SESSION_BOUND" != true ]; then
  if ! zensu_session_unregistered "$INPUT" \
    && ! zensu_session_orphaned_project_root "$INPUT" >/dev/null; then
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
  # Both escape channels stay reachable in either relaxed state — a user who
  # knowingly opts out must not need a bindable session to do it. Neither can be
  # ledgered here: the bypass ledger is keyed by the session binding that does
  # not exist, and zensu-tdd-phase.sh is not sourced until after this branch.
  [ "${ZENSU_BASH_WRITE_GATE:-}" = "off" ] && exit 0
  [ "${ZENSU_MCP_GATE:-}" = "off" ] && exit 0
  # Neither relaxed state can supply a project root — one has no record, the
  # other has a record pointing at a directory that is gone — so pin Claude's
  # own stable project env explicitly. The payload cwd must never become that
  # authority — the binder states the same rule — so an absent
  # CLAUDE_PROJECT_DIR denies rather than letting the parser fall back to a
  # model-influenced cwd, which would collapse the escape-the-worktree rule for
  # any file that does not already exist.
  UNBOUND_PROJECT_DIR="$(cd -P -- "${CLAUDE_PROJECT_DIR:-/nonexistent}" 2>/dev/null && pwd -P)" || UNBOUND_PROJECT_DIR=""
  if [ -z "$UNBOUND_PROJECT_DIR" ]; then
    # No anchor to judge a write against. Deny WRITES — but only writes: this
    # branch used to deny every Bash command unconditionally, which put the
    # diagnostic back behind the defect it reports. In the orphaned state
    # CLAUDE_PROJECT_DIR is, by construction, the directory that is gone (the
    # record's project_root was minted from the SessionStart cwd), and in the
    # no-record state it may simply be unset — so this branch is the NORMAL
    # case for both relaxed states, not an edge case.
    #
    # Channel detection needs no project root: it answers "does this command
    # write at all", and a command with no write channel cannot violate a rule
    # that only governs writes. A parser that fails to run still denies, so a
    # crash cannot degrade into a blanket allow.
    if ! UNBOUND_CHANNELS="$(
      cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
      BSWG_MODE=detect PAYLOAD="$INPUT" node ./bash-source-write-parse.js 2>/dev/null
    )"; then
      emit_deny "Blocked: the Bash write-channel check could not be evaluated for a session with no usable Session Control project root, so this command is refused rather than allowed unchecked. Start a fresh Claude Code session; /zensu:doctor runs without a binding and names the cause."
      exit 0
    fi
    [ -z "$UNBOUND_CHANNELS" ] && exit 0
    emit_deny "Blocked: this session has no usable Session Control project root — either no record at all (a session resumed across a plugin update never mints one) or a record whose recorded project root no longer exists (a deleted or recycled worktree) — AND no usable CLAUDE_PROJECT_DIR, so a Bash write cannot be attributed to any project. Read-only commands still run, /zensu:doctor included: run it to see which of the two states this is, or start a fresh Claude Code session."
    exit 0
  fi
  # An unparseable envelope is a different failure: with no readable command
  # there is nothing for the write rules to judge, so it keeps the original deny.
  # A parser that fails to RUN likewise denies — its exit status is honored here
  # exactly as the control check above honors its own, so a crashed parser can
  # never degrade into a blanket allow.
  if ! UNBOUND_REASON="$(
    cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
    BSWG_MODE= PAYLOAD="$INPUT" CLAUDE_PROJECT_DIR="$UNBOUND_PROJECT_DIR" \
      node ./bash-source-write-parse.js 2>/dev/null
  )"; then
    emit_deny "Blocked: the Bash source-write rules could not be evaluated for a session with no usable Session Control project root, so this command is refused rather than allowed unchecked. Start a fresh Claude Code session; /zensu:doctor runs without a binding and names the cause."
    exit 0
  fi
  case "$UNBOUND_REASON" in
    ''|__bypass__*) exit 0 ;;
  esac
  emit_deny "${UNBOUND_REASON} This session additionally has no usable Session Control project root — either no record at all (a session resumed across a plugin update never mints one) or a record whose recorded project root no longer exists (a deleted or recycled worktree) — so the write cannot be attributed to a recorded project. Run /zensu:doctor: it works without a binding and names the exact cause."
  exit 0
fi

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

REASON="$(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
  BSWG_MODE= PAYLOAD="$INPUT" CLAUDE_PROJECT_DIR="$ZENSU_PROJECT_ROOT" \
    node ./bash-source-write-parse.js 2>/dev/null
)"
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
