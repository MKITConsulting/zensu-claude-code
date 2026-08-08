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
# (C) closes the same contamination vector for git itself, which reaches it
# without naming a write target at all: a working-tree-mutating subcommand whose
# repository — from `git -C <path>`, `--work-tree`/`--git-dir`, an inline,
# `env`-wrapper or `export`/`declare -x` `GIT_DIR=`/`GIT_WORK_TREE=` assignment,
# or the same tracked cwd — resolves
# outside the session root is DENIED. The gated verbs are `GIT_MUTATIONS` in
# hooks/lib/bash-source-write-parse.js (the single source of truth; a structure
# test pins this file against it), read-only spellings such as `stash list` and
# `clean -n` are exempt via `GIT_READONLY_FORMS`, and `worktree` is gated for
# `remove`/`move` only. Reads and unknown subcommands pass, as does every
# mutation inside your own worktree. `worktree remove`/`move` is judged on the
# tree it destroys, not on the addressed repository. Rule (A)'s tracked-clobber
# test is never applied to the git subcommand itself — but a redirect or `tee`
# inside a git command is still a write channel and is still checked, so
# `git show HEAD:src/x.rs > src/x.rs` remains a rule (A) deny.
#
# Deliberately NOT a security boundary — an agent can still bypass via the escape
# hatch (inline `ZENSU_BASH_WRITE_GATE=off` / `ZENSU_MCP_GATE=off`, the process-env
# equivalents, or config `hooks.bashWriteGate:false`). It is a discipline nudge:
# route source edits through the Edit/Write tools (observable, gate-aware) and stay
# inside your own worktree.
#
# Carve-outs, by rule. (A) and (B) never deny a NEW file inside the project, a
# gitignored/untracked file, or a non-source extension; rule (C) applies neither
# filter, because it judges which repository is addressed, not which file is
# written. Temp roots ($TMPDIR, /tmp, /private/tmp, /var/folders) are exempt from
# all three. The standalone `mv`/`cp` commands are out of scope entirely
# (`git mv` is covered by rule (C) when it escapes the session root).
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
    BSWG_MODE=control PAYLOAD= node ./bash-source-write-parse.js 2>/dev/null <<<"$INPUT"
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
# ONLY that one state is relaxed — zensu_session_unregistered is false for a
# record that exists and disagrees, which keeps failing closed here as before.
# The Session Control rebind check above is unaffected: it runs before the bind
# and remains the real trust boundary.
if [ "$ZENSU_SESSION_BOUND" != true ]; then
  if ! zensu_session_unregistered "$INPUT"; then
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
  # Both escape channels stay reachable while unregistered — a user who
  # knowingly opts out must not need a bindable session to do it. Neither can be
  # ledgered here: the bypass ledger is keyed by the session binding that does
  # not exist, and zensu-tdd-phase.sh is not sourced until after this branch.
  [ "${ZENSU_BASH_WRITE_GATE:-}" = "off" ] && exit 0
  [ "${ZENSU_MCP_GATE:-}" = "off" ] && exit 0
  # No record can supply a project root, so pin Claude's own stable project env
  # explicitly. The payload cwd must never become that authority — the binder
  # states the same rule — so an absent CLAUDE_PROJECT_DIR denies rather than
  # letting the parser fall back to a model-influenced cwd, which would collapse
  # the escape-the-worktree rule for any file that does not already exist.
  UNBOUND_PROJECT_DIR="$(cd -P -- "${CLAUDE_PROJECT_DIR:-/nonexistent}" 2>/dev/null && pwd -P)" || UNBOUND_PROJECT_DIR=""
  if [ -z "$UNBOUND_PROJECT_DIR" ]; then
    emit_deny "Blocked: this session has no Session Control record (a session resumed across a plugin update never mints one) AND no usable CLAUDE_PROJECT_DIR, so a Bash write cannot be attributed to any project. Start a fresh Claude Code session; /zensu:doctor runs without a binding and names the cause."
    exit 0
  fi
  # An unparseable envelope is a different failure: with no readable command
  # there is nothing for the write rules to judge, so it keeps the original deny.
  # A parser that fails to RUN likewise denies — its exit status is honored here
  # exactly as the control check above honors its own, so a crashed parser can
  # never degrade into a blanket allow.
  if ! UNBOUND_REASON="$(
    cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
    BSWG_MODE= PAYLOAD= CLAUDE_PROJECT_DIR="$UNBOUND_PROJECT_DIR" \
      node ./bash-source-write-parse.js 2>/dev/null <<<"$INPUT"
  )"; then
    emit_deny "Blocked: the Bash source-write rules could not be evaluated for a session with no Session Control record, so this command is refused rather than allowed unchecked. Start a fresh Claude Code session; /zensu:doctor runs without a binding and names the cause."
    exit 0
  fi
  case "$UNBOUND_REASON" in
    ''|__bypass__*) exit 0 ;;
  esac
  emit_deny "${UNBOUND_REASON} This session additionally has no Session Control record — a session resumed across a plugin update never mints one — so the write cannot be attributed to a recorded project. Run /zensu:doctor: it works without a binding and names the exact cause."
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

# An empty recorded project root would let the parser fall back to the payload
# cwd (`CLAUDE_PROJECT_DIR || cwd0`), which makes a drifted checkout its own
# project root and inverts rules (B) and (C). The unbound branch above refuses
# exactly that promotion; match it rather than tolerating it with `:-`.
if [ -z "${ZENSU_PROJECT_ROOT:-}" ]; then
  emit_deny "Blocked: this session's recorded project root is empty, so a Bash write cannot be judged against any project and the worktree-escape rules would treat the current directory as the project. Start a fresh Claude Code session."
  exit 0
fi

# The other two parser calls in this file honor their exit status; this one used
# to discard it, so a crashed or killed parser allowed the command unchecked.
if ! REASON="$(
  cd -P -- "${CLAUDE_PLUGIN_ROOT}/hooks/lib" || exit 1
  BSWG_MODE= PAYLOAD= CLAUDE_PROJECT_DIR="$ZENSU_PROJECT_ROOT" \
    node ./bash-source-write-parse.js 2>/dev/null <<<"$INPUT"
)"; then
  emit_deny "Blocked: the Bash source-write rules could not be evaluated for this session, so the command is refused rather than allowed unchecked. Two remedies are decided BEFORE the parser runs and therefore still work: set hooks.bashWriteGate:false in ~/.zensu/config.json, or export ZENSU_BASH_WRITE_GATE=off into the environment Claude Code was started from. An INLINE ZENSU_BASH_WRITE_GATE=off prefix does not help here — that one is decided inside the parser that is failing."
  exit 0
fi
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
