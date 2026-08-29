#!/bin/bash
set -u

_ZENSU_EXECUTED_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" \
  || { return 2 2>/dev/null || exit 2; }
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _ZENSU_DECLARED_PLUGIN_ROOT="$(cd -P -- "$CLAUDE_PLUGIN_ROOT" 2>/dev/null && pwd -P)" || {
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    return 2 2>/dev/null || exit 2
  }
  if [ "$_ZENSU_DECLARED_PLUGIN_ROOT" != "$_ZENSU_EXECUTED_PLUGIN_ROOT" ]; then
    echo "zensu: inherited CLAUDE_PLUGIN_ROOT does not match the executing plugin" >&2
    return 2 2>/dev/null || exit 2
  fi
fi
CLAUDE_PLUGIN_ROOT="$_ZENSU_EXECUTED_PLUGIN_ROOT"
unset _ZENSU_EXECUTED_PLUGIN_ROOT _ZENSU_DECLARED_PLUGIN_ROOT

# Keep CLAUDE_PLUGIN_ROOT in the executing shell's namespace for Bash path
# operations and rendered commands. Native Node code-load authority is derived
# only from this canonically verified executing root, never from ambient
# ZENSU_* bindings. Data paths are translated explicitly at each Node boundary.
_ZENSU_TDD_HOST_PATH="${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh"
_ZENSU_TDD_NATIVE_PLUGIN_ROOT="$(bash "$_ZENSU_TDD_HOST_PATH" "$CLAUDE_PLUGIN_ROOT")" \
  || { return 2 2>/dev/null || exit 2; }
_ZENSU_TDD_CONTROL_CORE="${_ZENSU_TDD_NATIVE_PLUGIN_ROOT}/hooks/lib/session-control-core-v1.js"
[ -f "$_ZENSU_TDD_CONTROL_CORE" ] && [ ! -L "$_ZENSU_TDD_CONTROL_CORE" ] \
  || { return 2 2>/dev/null || exit 2; }
_ZENSU_TDD_CHAIN_RECOVERY="${_ZENSU_TDD_NATIVE_PLUGIN_ROOT}/hooks/lib/chain-recovery-v1.js"

_tdd_chain_recovery_module_ok() {
  [ -f "$_ZENSU_TDD_CHAIN_RECOVERY" ] && [ ! -L "$_ZENSU_TDD_CHAIN_RECOVERY" ]
}

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

_tdd_winpid_from_ps() {
  local shell_pid="${1:-}"
  [ "$#" -eq 1 ] || return 1
  case "$shell_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$shell_pid" -gt 0 ] 2>/dev/null || return 1

  awk -v target="$shell_pid" '
    NR == 1 {
      header_has_status = ($1 == "S" || $1 == "STAT" || $1 == "STATUS") ? 1 : 0
      for (i = 1; i <= NF; i += 1) {
        if ($i == "PID" && !pid_column) pid_column = i
        if ($i == "WINPID") winpid_column = i
      }
      next
    }
    pid_column && winpid_column {
      data_has_status = ($1 ~ /^[SIO]$/) ? 1 : 0
      offset = data_has_status - header_has_status
      pid_value = $(pid_column + offset)
      winpid_value = $(winpid_column + offset)
      if (pid_value == target && winpid_value ~ /^[1-9][0-9]*$/) {
        print winpid_value
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  '
}

_tdd_is_msys_runtime() {
  case "${OSTYPE:-}" in
    msys*|cygwin*|mingw*|MSYS*|CYGWIN*|MINGW*) return 0 ;;
    *) return 1 ;;
  esac
}

# Convert one arbitrary path spelling for native Node without relying on
# MSYS' quote-sensitive argv/environment heuristics. The existing safety and
# immutable-binding checks remain authoritative; this function only transports
# their already-selected path into the native host namespace.
_tdd_native_path() {
  local input="${1:-}" native
  [ "$#" -eq 1 ] && [ -n "$input" ] || return 1
  case "$input" in *$'\r'*|*$'\n'*) return 1 ;; esac
  if _tdd_is_msys_runtime; then
    command -v cygpath >/dev/null 2>&1 || return 1
    native="$(cygpath -am "$input" 2>/dev/null)" || return 1
    case "$native" in ""|*$'\r'*|*$'\n'*) return 1 ;; esac
    case "$native" in [A-Za-z]:/*|//?*/*) ;; *) return 1 ;; esac
    printf '%s\n' "$native"
  else
    printf '%s\n' "$input"
  fi
}

_tdd_native_process_pid() {
  local shell_pid="${1:-}" native_pid ps_output
  [ "$#" -eq 1 ] || return 1
  case "$shell_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$shell_pid" -gt 0 ] 2>/dev/null || return 1

  if _tdd_is_msys_runtime; then
    command -v ps >/dev/null 2>&1 || return 1
    command -v awk >/dev/null 2>&1 || return 1
    # Capture the producer status before parsing. Without this separation a
    # failing ps could emit one plausible row and have its non-zero status
    # hidden by the successful final stage of a pipeline.
    ps_output="$(ps -p "$shell_pid" -l 2>/dev/null)" || return 1
    native_pid="$(printf '%s\n' "$ps_output" \
      | _tdd_winpid_from_ps "$shell_pid")" || return 1
    native_pid="${native_pid//[[:space:]]/}"
  else
    native_pid="$shell_pid"
  fi

  case "$native_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$native_pid" -gt 0 ] 2>/dev/null || return 1
  printf '%s\n' "$native_pid"
}

_tdd_context_binding() {
  local session_id="${1:-}" key record records
  key="$(zensu_resolve_session_id "$session_id")" || return 1
  if [ -n "${ZENSU_SESSION_CONTEXT:-}" ]; then
    record="$ZENSU_SESSION_CONTEXT"
    [ "$(basename "$record")" = "$key.json" ] || return 1
    records="$(dirname "$record")"
    printf '%s\n%s\n' claude "$records"
    return 0
  fi
  records="${HOME:-}/.zensu/session-control/codex/v3/records"
  [ -f "$records/$key.json" ] && [ ! -L "$records/$key.json" ] || return 1
  printf '%s\n%s\n' codex "$records"
}

tdd_activation_status() {
  local session_id="${1:-}" key binding state_file status active
  key="$(zensu_resolve_session_id "$session_id")" || { echo invalid; return 0; }
  binding="$(_tdd_context_binding "$key")" || { echo inactive; return 0; }
  state_file="$(tdd_state_file "$key")" || { echo invalid; return 0; }
  status="$(tdd_state_status "$state_file")"
  [ "$status" = "valid" ] || { echo invalid; return 0; }
  active="$(tdd_session_active "$state_file")"
  [ "$active" = "true" ] && echo active || echo inactive
}

tdd_state_file() {
  local session_id="${1:-}"
  local resolved project_root
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  resolved="$(zensu_resolve_session_id "$session_id")" || return 1
  project_root="$(zensu_resolve_project_dir)" || return 1
  echo "${project_root}/.zensu/state/tdd-phase-${resolved}.json"
}

_tdd_bound_project_root() {
  local state_file="${1:-}" session_id="${2:-}" expected project_root native_project_root
  [ -n "$state_file" ] && [ -n "$session_id" ] || return 1
  expected="$(tdd_state_file "$session_id")" || return 1
  [ "$state_file" = "$expected" ] || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || return 1
  [ "$expected" = "$project_root/.zensu/state/tdd-phase-$(zensu_resolve_session_id "$session_id").json" ] || return 1
  # Every caller passes this value to native Node as PROJECT_ROOT. The
  # immutable binding is already host-native and was identity-checked by
  # zensu_resolve_project_dir above. Returning the shell rendering here would
  # rely on heuristic MSYS conversion, which is not a stable transport for
  # shell-special paths.
  native_project_root="${ZENSU_PROJECT_ROOT:-}"
  [ -n "$native_project_root" ] || return 1
  printf '%s\n' "$native_project_root"
}

# Translate an already-selected project descendant by preserving its exact
# suffix beneath the immutable shell/native root pair. This is stronger than
# asking MSYS (or a mutable mount table) to reinterpret the full path.
_tdd_native_project_path() {
  local shell_path="${1:-}" shell_root native_root suffix
  [ "$#" -eq 1 ] && [ -n "$shell_path" ] || return 1
  case "$shell_path" in *$'\r'*|*$'\n'*) return 1 ;; esac
  # The suffix mapper is lexical so it can render not-yet-created state files.
  # Dot segments would therefore survive the mapping and could escape the
  # immutable native root; reject them before the namespace boundary.
  case "/$shell_path/" in */../*|*/./*) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  shell_root="$(zensu_resolve_project_dir)" || return 1
  native_root="${ZENSU_PROJECT_ROOT:-}"
  [ -n "$native_root" ] || return 1
  if [ "$shell_path" = "$shell_root" ]; then
    printf '%s\n' "$native_root"
    return 0
  fi
  case "$shell_path" in
    "$shell_root"/*) suffix="${shell_path#"$shell_root"}" ;;
    *) return 1 ;;
  esac
  [ -n "$suffix" ] || return 1
  printf '%s%s\n' "${native_root%/}" "$suffix"
}

# Validate every path component below a trusted project/temp anchor without
# following symlinks. The leaf contract is explicit so directories, FIFOs,
# devices, sockets, and hard-linked files cannot masquerade as JSON state.
#
# The project root and the OS temp root are trusted entry points: Claude hands
# us the former and test/runtime temp paths commonly use the latter (including
# macOS' /var -> /private/var alias). Every component *below* that anchor is
# checked with lstat. For an explicit state path outside both anchors, the
# nearest existing, non-symlink ancestor becomes the entry point.
_tdd_paths_safe() {
  [ "$#" -gt 0 ] && [ $(( $# % 2 )) -eq 0 ] || return 1
  local path_args=("$@") native_path_args=() index=0 target native_target mode
  local native_project_root="" native_temp_root="" native_home_root=""
  while [ "$index" -lt "${#path_args[@]}" ]; do
    target="${path_args[$index]}"
    mode="${path_args[$((index + 1))]}"
    case "$mode" in
      regular|regular-or-absent)
        [ ! -L "$target" ] || return 1
        if [ -e "$target" ] && [ ! -f "$target" ]; then return 1; fi
        ;;
      directory|directory-or-absent)
        [ ! -L "$target" ] || return 1
        if [ -e "$target" ] && [ ! -d "$target" ]; then return 1; fi
        ;;
      *) return 1 ;;
    esac
    native_target="$(_tdd_native_path "$target")" || return 1
    native_path_args+=("$native_target" "$mode")
    index=$((index + 2))
  done
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    native_project_root="$(_tdd_native_path "$CLAUDE_PROJECT_DIR")" || return 1
  fi
  native_temp_root="$(_tdd_native_path "${TMPDIR:-/tmp}")" || return 1
  if [ -n "${HOME:-}" ]; then
    native_home_root="$(_tdd_native_path "$HOME")" || return 1
  fi
  MSYS2_ARG_CONV_EXCL='*' node -e '
      const fs = require("fs");
      const path = require("path");
      const within = (base, candidate) => {
        const rel = path.relative(base, candidate);
        return rel === "" || (rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
      };
      const [projectRoot, tempRoot, homeRoot, ...args] = process.argv.slice(1);
      const trusted = [projectRoot, tempRoot, homeRoot]
        .filter(Boolean).map(value => path.resolve(value));
      const validModes = new Set(["regular", "regular-or-absent", "directory", "directory-or-absent"]);
      for (let pair = 0; pair < args.length; pair += 2) {
        const target = path.resolve(args[pair]);
        const mode = args[pair + 1];
        if (!validModes.has(mode)) process.exit(3);
        const candidates = trusted.filter(value => within(value, target)).sort((a, b) => b.length - a.length);
        let anchor = candidates[0] || "";
        if (!anchor) {
          let cursor = path.dirname(target);
          for (;;) {
            try {
              const st = fs.lstatSync(cursor);
              if (st.isDirectory() && !st.isSymbolicLink()) {
                anchor = cursor;
                break;
              }
            } catch (error) {
              if (error.code !== "ENOENT") process.exit(3);
            }
            const parent = path.dirname(cursor);
            if (parent === cursor) process.exit(3);
            cursor = parent;
          }
        }
        let physicalAnchor;
        try { physicalAnchor = fs.realpathSync(anchor); }
        catch (_) { process.exit(3); }
        const rel = path.relative(anchor, target);
        if (rel === ".." || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) process.exit(3);
        const parts = rel ? rel.split(path.sep).filter(Boolean) : [];
        let current = physicalAnchor;
        let missing = false;
        for (let i = 0; i < parts.length; i += 1) {
          current = path.join(current, parts[i]);
          const leaf = i === parts.length - 1;
          if (missing) continue;
          let st;
          try { st = fs.lstatSync(current); }
          catch (error) {
            if (error.code !== "ENOENT") process.exit(3);
            missing = true;
            continue;
          }
          if (st.isSymbolicLink()) process.exit(3);
          if (!leaf && !st.isDirectory()) process.exit(3);
          if (leaf) {
            if ((mode === "regular" || mode === "regular-or-absent")
                && (!st.isFile() || st.nlink !== 1)) process.exit(3);
            if ((mode === "directory" || mode === "directory-or-absent") && !st.isDirectory()) process.exit(3);
          }
        }
        if (missing && (mode === "regular" || mode === "directory")) process.exit(3);
      }
    ' "$native_project_root" "$native_temp_root" "$native_home_root" \
      "${native_path_args[@]}" >/dev/null 2>&1
}

_tdd_path_safe() {
  local target="${1:-}" mode="${2:-}"
  [ -n "$target" ] || return 1
  _tdd_paths_safe "$target" "$mode"
}

_tdd_state_storage_safe() {
  local state_file="${1:-}" state_dir
  [ -n "$state_file" ] || return 1
  state_dir="$(dirname "$state_file")"
  _tdd_paths_safe \
    "$state_dir" directory \
    "$state_file" regular-or-absent \
    "${state_file}.lock" regular-or-absent
}

_tdd_prepare_directory() {
  local directory="${1:-}"
  [ -n "$directory" ] || return 1
  _tdd_path_safe "$directory" directory-or-absent "$directory" || return 1
  mkdir -p "$directory" 2>/dev/null || return 1
  _tdd_path_safe "$directory" directory "$directory"
}

# `mv file existing-directory` silently moves the source *inside* the
# directory. rename(2) has the replacement semantics state writes require and
# rejects a directory leaf. Revalidate the leaf immediately before rename.
_tdd_atomic_replace_regular() {
  local source_file="${1:-}" target_file="${2:-}" native_source_file native_target_file
  _tdd_paths_safe "$source_file" regular "$target_file" regular-or-absent || return 1
  case "$(basename "$target_file")" in
    tdd-phase-scv1_*.json)
      local session_key project_root native_project_root expected_file
      session_key="$(basename "$target_file")"
      session_key="${session_key#tdd-phase-}"
      session_key="${session_key%.json}"
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      session_key="$(zensu_resolve_session_id "$session_key")" || return 1
      project_root="$(zensu_resolve_project_dir)" || return 1
      expected_file="${project_root}/.zensu/state/tdd-phase-${session_key}.json"
      [ "$target_file" = "$expected_file" ] || return 1
      native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
      native_source_file="$(_tdd_native_project_path "$source_file")" || return 1
      CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
        PROJECT_ROOT="$native_project_root" SID="$session_key" SOURCE_FILE="$native_source_file" \
        node -e '
          const fs = require("node:fs");
          const core = require(process.env.CONTROL_CORE);
          try {
            const draft = JSON.parse(fs.readFileSync(process.env.SOURCE_FILE, "utf8"));
            const previous = core.readWorkflowState({
              projectRoot: process.env.PROJECT_ROOT,
              sessionId: process.env.SID,
            });
            if (!Number.isSafeInteger(draft.revision) || draft.revision !== previous.revision) {
              process.exit(3);
            }
            core.mutateWorkflowState({
              projectRoot: process.env.PROJECT_ROOT,
              sessionId: process.env.SID,
              expectedRevision: previous.revision,
              workflowState: draft.workflow_state,
              event: "state-update",
            }, () => draft);
            fs.unlinkSync(process.env.SOURCE_FILE);
          } catch (_) { process.exit(3); }
        ' >/dev/null 2>&1
      return $?
      ;;
  esac
  native_source_file="$(_tdd_native_path "$source_file")" || return 1
  native_target_file="$(_tdd_native_path "$target_file")" || return 1
  SOURCE_FILE="$native_source_file" TARGET_FILE="$native_target_file" node -e '
    const fs = require("fs");
    const source = process.env.SOURCE_FILE;
    const target = process.env.TARGET_FILE;
    try {
      const before = fs.lstatSync(source);
      if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1) process.exit(3);
      try {
        const existing = fs.lstatSync(target);
        if (!existing.isFile() || existing.isSymbolicLink() || existing.nlink !== 1) process.exit(3);
      } catch (error) {
        if (error.code !== "ENOENT") process.exit(3);
      }
      fs.renameSync(source, target);
      const after = fs.lstatSync(target);
      if (!after.isFile() || after.isSymbolicLink() || after.nlink !== 1) process.exit(3);
    } catch (_) { process.exit(3); }
  ' >/dev/null 2>&1
}

tdd_is_test_path() {
  local path="${1:-}"
  [ -z "$path" ] && { echo "false"; return 0; }

  if [ -L "$path" ]; then
    echo "false"; return 0
  fi

  local lower
  lower=$(echo "$path" | tr '[:upper:]' '[:lower:]')

  case "$lower" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|*/specs/*)
      echo "true"; return 0 ;;
    test/*|tests/*|__tests__/*|spec/*|specs/*)
      echo "true"; return 0 ;;
  esac

  local base
  base=$(basename "$path")

  case "$base" in
    test_*|*_test.*|*_tests.*|*.test.*|*.tests.*|*.spec.*|*.specs.*|*_spec.*|*_specs.*)
      echo "true"; return 0 ;;
  esac

  local lower_base
  lower_base=$(echo "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower_base" in
    *_test.*|*_tests.*|*_spec.*|*_specs.*)
      echo "true"; return 0 ;;
  esac

  if [ -f "$path" ]; then
    local link_count
    link_count=$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path" 2>/dev/null || echo "1")
    if [ "${link_count:-1}" -gt 1 ] 2>/dev/null; then
      echo "false"; return 0
    fi
    local header
    header=$(head -n 20 "$path" 2>/dev/null | sed $'1s/^\xef\xbb\xbf//' 2>/dev/null || true)
    if printf '%s\n' "$header" | grep -Eq '^(func Test|describe\(|it\(|test\(|@Test|def test_)' 2>/dev/null; then
      echo "true"; return 0
    fi
    if printf '%s\n' "$header" | grep -Eq '^[[:space:]]*#\[test\]' 2>/dev/null; then
      echo "true"; return 0
    fi
    if printf '%s\n' "$header" | grep -Eq '^[[:space:]]*#\[cfg\(test\)\]' 2>/dev/null; then
      echo "true"; return 0
    fi
  fi

  echo "false"
}

_tdd_write_phase_critical() {
  local state_file="$1"
  local session_id="$2"
  local step_id="$3"
  local phase="$4"
  local reason="$5"
  [ "$phase" = CHAIN_RECOVERED ] && return 1
  [ "$phase" = RUNTIME_ADOPTED ] && return 1
  case "$reason" in "chain-recovered: "*) return 1 ;; esac
  case "$reason" in "runtime-adopted: "*) return 1 ;; esac
  local ts="$6"

  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" STEP="$step_id" PHASE="$phase" REASON="$reason" TS="$ts" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: process.env.PHASE.toLowerCase(),
        event: "phase-" + process.env.PHASE.toLowerCase(),
        updatedAt: process.env.TS || undefined,
      }, (state) => {
        if (!Array.isArray(state.history)) state.history = [];
        const entry = { step: process.env.STEP, phase: process.env.PHASE };
        if (process.env.TS) entry.ts = process.env.TS;
        if (process.env.REASON) entry.reason = process.env.REASON;
        state.history.push(entry);
        state.step_id = process.env.STEP;
        state.phase = process.env.PHASE;
        return state;
      });
    ' 2>/dev/null
}

_tdd_core_lock_keeper() {
  node -e '
    const fs = require("node:fs");
    const [corePath, lockDirectory, resourcePath] = process.argv.slice(1);
    let core = null;
    let lease = null;
    try {
      core = require(corePath);
      lease = core.acquireExternalProcessLock({
        lockDirectory,
        resourcePath,
        ownerPid: process.pid,
      });
      fs.writeSync(1, "READY\n");
      const command = fs.readFileSync(0, "utf8");
      if (command !== "RELEASE\n") throw new Error("lock keeper release protocol failed");
      core.releaseExternalProcessLock({
        lockDirectory,
        resourcePath,
        ownerPid: process.pid,
        token: lease.token,
      });
      lease = null;
      fs.writeSync(1, "RELEASED\n");
    } catch (error) {
      const detail = String(error && error.message ? error.message : "unknown lock keeper error")
        .replace(/[\r\n]+/g, " ").slice(0, 512);
      if (lease && core) {
        try {
          core.releaseExternalProcessLock({
            lockDirectory,
            resourcePath,
            ownerPid: process.pid,
            token: lease.token,
          });
        } catch (_) { /* the caller fails closed below */ }
      }
      try { fs.writeSync(1, `ERROR ${detail}\n`); } catch (_) { /* parent exited */ }
      process.exit(3);
    }
  ' -- "$1" "$2" "$3"
}

_tdd_locked_run() {
  local state_file="$1"
  shift

  # Every caller uses the Core lease namespace. Selecting different mutexes via
  # PATH or environment would split mutual exclusion for the same resource.
  # Recheck storage after acquisition so a path swap cannot reach the mutation.
  _tdd_state_storage_safe "$state_file" || return 1

  # Bash 4+ gives us anonymous bidirectional coprocess pipes. Keep one Node
  # process alive for the entire critical section so its PID is both the lease
  # owner and the release authority. This avoids Git Bash native parent-wrapper
  # churn without a filesystem control channel. Bash 3.2 keeps the portable
  # capability fallback below; on POSIX its direct-child parent is stable.
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    local core_path lock_directory native_lock_directory native_state_file
    local coproc_name keeper_read_fd keeper_write_fd
    local keeper_pid keeper_status release_status callback_rc keeper_rc
    core_path="$_ZENSU_TDD_CONTROL_CORE"
    lock_directory="$(dirname "$state_file")"
    native_lock_directory="$(_tdd_native_path "$lock_directory")" || return 1
    native_state_file="$(_tdd_native_path "$state_file")" || return 1
    _ZENSU_TDD_COPROC_SEQ=$(( ${_ZENSU_TDD_COPROC_SEQ:-0} + 1 ))
    coproc_name="ZENSU_TDD_LOCK_${_ZENSU_TDD_COPROC_SEQ}"

    if ! eval "coproc $coproc_name { _tdd_core_lock_keeper \"\$core_path\" \"\$native_lock_directory\" \"\$native_state_file\"; }"; then
      echo "[zensu-tdd-phase] lock keeper launch failed for $state_file" >&2
      return 1
    fi
    eval "keeper_read_fd=\${${coproc_name}[0]}"
    eval "keeper_write_fd=\${${coproc_name}[1]}"
    eval "keeper_pid=\${${coproc_name}_PID}"
    case "$keeper_read_fd:$keeper_write_fd:$keeper_pid" in
      *[!0-9:]*|::*|:*:|:*::* )
        echo "[zensu-tdd-phase] lock keeper descriptors are invalid for $state_file" >&2
        return 1
        ;;
    esac

    keeper_status=""
    IFS= read -r keeper_status <&"$keeper_read_fd" || true
    if [ "$keeper_status" != "READY" ]; then
      eval "exec ${keeper_write_fd}>&-" 2>/dev/null || true
      eval "exec ${keeper_read_fd}<&-" 2>/dev/null || true
      if wait "$keeper_pid" 2>/dev/null; then keeper_rc=0; else keeper_rc=$?; fi
      eval "unset $coproc_name ${coproc_name}_PID" 2>/dev/null || true
      [ -z "$keeper_status" ] || echo "[zensu-tdd-phase] lock detail: ${keeper_status#ERROR }" >&2
      echo "[zensu-tdd-phase] lock acquisition failed for $state_file" >&2
      return 1
    fi

    if _tdd_state_storage_safe "$state_file" && "$@"; then
      callback_rc=0
    else
      callback_rc=$?
    fi
    if ! printf 'RELEASE\n' >&"$keeper_write_fd"; then
      callback_rc=1
    fi
    eval "exec ${keeper_write_fd}>&-" 2>/dev/null || true
    release_status=""
    IFS= read -r release_status <&"$keeper_read_fd" || true
    eval "exec ${keeper_read_fd}<&-" 2>/dev/null || true
    if wait "$keeper_pid" 2>/dev/null; then keeper_rc=0; else keeper_rc=$?; fi
    eval "unset $coproc_name ${coproc_name}_PID" 2>/dev/null || true
    if [ "$keeper_rc" -ne 0 ] || [ "$release_status" != "RELEASED" ]; then
      [ -z "$release_status" ] || echo "[zensu-tdd-phase] lock release detail: ${release_status#ERROR }" >&2
      echo "[zensu-tdd-phase] lock release failed for $state_file" >&2
      return 1
    fi
    return "$callback_rc"
  fi

  local lock_directory token_file native_lock_directory native_state_file native_token_file
  local token acquire_rc release_rc
  lock_directory="$(dirname "$state_file")"
  token_file="$(mktemp "${TMPDIR:-/tmp}/zensu-tdd-lock-token.XXXXXX" 2>/dev/null)" || {
    echo "[zensu-tdd-phase] lock token allocation failed for $state_file" >&2
    return 1
  }
  chmod 600 "$token_file" 2>/dev/null || {
    rm -f -- "$token_file" 2>/dev/null || true
    return 1
  }
  _tdd_path_safe "$token_file" regular || {
    rm -f -- "$token_file" 2>/dev/null || true
    return 1
  }
  native_lock_directory="$(_tdd_native_path "$lock_directory")" || {
    rm -f -- "$token_file" 2>/dev/null || true
    return 1
  }
  native_state_file="$(_tdd_native_path "$state_file")" || {
    rm -f -- "$token_file" 2>/dev/null || true
    return 1
  }
  native_token_file="$(_tdd_native_path "$token_file")" || {
    rm -f -- "$token_file" 2>/dev/null || true
    return 1
  }
  if node -e '
      const fs = require("node:fs");
      const [corePath, lockDirectory, resourcePath, tokenFile] = process.argv.slice(1);
      let core = null;
      const sameIdentity = (left, right) => {
        if (left.ino !== 0 && right.ino !== 0) return left.dev === right.dev && left.ino === right.ino;
        return left.birthtimeMs === right.birthtimeMs && left.mode === right.mode;
      };
      // Windows exposes O_NOFOLLOW in some Node builds but rejects it for this
      // open. The lstat/open/fstat identity bracket is the portable no-follow
      // equivalent there. Open without O_TRUNC so every mutation remains after
      // that identity proof; tokenSink performs the truncate only afterwards.
      const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
        ? fs.constants.O_NOFOLLOW : 0;
      let descriptor;
      let lease = null;
      try {
        core = require(corePath);
        const before = fs.lstatSync(tokenFile);
        if (before.isSymbolicLink() || !before.isFile() || before.nlink !== 1) throw new Error("unsafe token file");
        descriptor = fs.openSync(
          tokenFile,
          fs.constants.O_WRONLY | noFollow,
        );
        const opened = fs.fstatSync(descriptor);
        if (!opened.isFile() || opened.nlink !== 1 || !sameIdentity(before, opened)) {
          throw new Error("token file changed before open");
        }
        lease = core.acquireExternalProcessLock({
          lockDirectory,
          resourcePath,
          ownerPid: process.ppid,
          tokenSink: (token) => {
            fs.ftruncateSync(descriptor, 0);
            fs.writeSync(descriptor, token, 0, "utf8");
            fs.fsyncSync(descriptor);
          },
        });
        const afterDescriptor = fs.fstatSync(descriptor);
        const afterPath = fs.lstatSync(tokenFile);
        if (
          afterDescriptor.nlink !== 1
          || afterPath.isSymbolicLink()
          || !afterPath.isFile()
          || afterPath.nlink !== 1
          || !sameIdentity(afterDescriptor, afterPath)
        ) throw new Error("token file changed after publication");
        fs.closeSync(descriptor);
        descriptor = undefined;
      } catch (error) {
        const detail = String(error && error.message ? error.message : "unknown acquisition error")
          .replace(/[\r\n]+/g, " ").slice(0, 512);
        process.stderr.write(`[zensu-tdd-phase] lock detail: ${detail}\n`);
        if (descriptor !== undefined) {
          try { fs.closeSync(descriptor); } catch (_) { /* fail closed below */ }
        }
        if (lease && core) {
          try {
            core.releaseExternalProcessLockByToken({
              lockDirectory,
              resourcePath,
              token: lease.token,
            });
          } catch (_) { /* fail closed below */ }
        }
        process.exit(3);
      }
    ' -- "$_ZENSU_TDD_CONTROL_CORE" \
      "$native_lock_directory" "$native_state_file" "$native_token_file" >/dev/null; then
    acquire_rc=0
  else
    acquire_rc=$?
  fi
  if _tdd_path_safe "$token_file" regular; then
    token="$(tr -d '[:space:]' < "$token_file" 2>/dev/null)"
  else
    token=""
  fi
  rm -f -- "$token_file" 2>/dev/null || true
  if [ "$acquire_rc" -ne 0 ] || ! [[ "$token" =~ ^[a-f0-9]{48}$ ]]; then
    if [[ "$token" =~ ^[a-f0-9]{48}$ ]]; then
      LOCK_TOKEN="$token" node -e '
          const [corePath, lockDirectory, resourcePath] = process.argv.slice(1);
          const core = require(corePath);
          core.releaseExternalProcessLockByToken({
            lockDirectory,
            resourcePath,
            token: process.env.LOCK_TOKEN,
          });
        ' -- "$_ZENSU_TDD_CONTROL_CORE" \
          "$native_lock_directory" "$native_state_file" >/dev/null 2>&1 || true
    fi
    echo "[zensu-tdd-phase] lock acquisition failed for $state_file" >&2
    return 1
  fi
  if _tdd_state_storage_safe "$state_file"; then
    "$@"
  else
    false
  fi
  local rc=$?
  if LOCK_TOKEN="$token" node -e '
      const [corePath, lockDirectory, resourcePath] = process.argv.slice(1);
      try {
        const core = require(corePath);
        core.releaseExternalProcessLockByToken({
          lockDirectory,
          resourcePath,
          token: process.env.LOCK_TOKEN,
        });
      } catch (error) {
        const detail = String(error && error.message ? error.message : "unknown release error")
          .replace(/[\r\n]+/g, " ").slice(0, 512);
        process.stderr.write(`[zensu-tdd-phase] lock release detail: ${detail}\n`);
        process.exit(3);
      }
    ' -- "$_ZENSU_TDD_CONTROL_CORE" \
      "$native_lock_directory" "$native_state_file" >/dev/null; then
    release_rc=0
  else
    release_rc=$?
  fi
  if [ "$release_rc" -ne 0 ]; then
    echo "[zensu-tdd-phase] lock release failed for $state_file" >&2
    return 1
  fi
  return $rc
}

tdd_write_phase() {
  local supplied_session="${1:-}"
  local session_id
  local step_id="${2:-}"
  local phase="${3:-}"
  local reason="${4:-}"
  [ "$phase" = CHAIN_RECOVERED ] && return 1
  [ "$phase" = RUNTIME_ADOPTED ] && return 1
  case "$reason" in "chain-recovered: "*) return 1 ;; esac
  case "$reason" in "runtime-adopted: "*) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1

  local ts=""
  if [ "$(_zensu_log_style)" != "none" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_phase_critical "$state_file" "$session_id" "$step_id" "$phase" "$reason" "$ts"
}

# --- Chain-state flags (active / implComplete / chainDone) ----------------
# These live in the SAME per-session state file as the FSM phase. They drive
# main-thread hook activation (active), the Stop-hook review gate
# (implComplete), and chain termination (chainDone). All writes go through the
# shared Session Control CAS transaction so concurrent phase/flag writes cannot
# clobber each other or reset an invalid revision.

_tdd_write_flag_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  local val="$4"

  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" KEY="$key" VAL="$val" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const value = process.env.VAL === "true";
      const names = {
        vanilla: "configured",
        active: value ? "active" : "idle",
        implComplete: "implementation_complete",
        chainDone: "complete",
        codeReviewDone: "code_review_complete",
        selfReviewFixed: "self_review_fixed"
      };
      const event = "flag-" + process.env.KEY.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase() + "-" + String(value);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: names[process.env.KEY] || "control",
        event,
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state[process.env.KEY] = value;
        if (process.env.KEY === "active" && value) {
          state.reviewRound = 0;
          state.stopBlockCount = 0;
        }
        if (process.env.KEY === "codeReviewDone" && value) state.stopBlockCount = 0;
        return state;
      });
    ' 2>/dev/null
}

_tdd_increment_counter_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" KEY="$key" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const names = { reviewRound: "review_progress", stopBlockCount: "stop_guard" };
      if (!Object.prototype.hasOwnProperty.call(names, process.env.KEY)) process.exit(2);
      const next = core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: names[process.env.KEY],
        event: "counter-" + process.env.KEY.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase(),
      }, (state) => {
        if (state.active !== true) throw new Error("counter mutation requires an active workflow");
        const current = state[process.env.KEY] === undefined ? 0 : state[process.env.KEY];
        if (!Number.isSafeInteger(current) || current < 0 || current >= 1000000) {
          throw new Error("counter is invalid or exhausted");
        }
        state[process.env.KEY] = current + 1;
        if (process.env.KEY === "reviewRound") state.stopBlockCount = 0;
        return state;
      });
      process.stdout.write(String(next[process.env.KEY]));
    ' 2>/dev/null
}

tdd_increment_counter() {
  local supplied_session="${1:-}" key="${2:-}" session_id state_file
  case "$key" in reviewRound|stopBlockCount) ;; *) return 1 ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_increment_counter_critical "$state_file" "$session_id" "$key"
}

tdd_reset_review_budget() {
  local supplied_session="${1:-}" expected_revision="${2:-}" session_id state_file
  case "$expected_revision" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected_revision" -ge 1 ] 2>/dev/null || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" EXPECTED_REVISION="$expected_revision" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const state = core.resetReviewBudget({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        expectedRevision: Number(process.env.EXPECTED_REVISION),
      });
      process.stdout.write(JSON.stringify(state));
    ' 2>/dev/null
}

tdd_set_flag() {
  local supplied_session="${1:-}"
  local session_id
  local key="${2:-}"
  local val="${3:-true}"
  [ -z "$key" ] && return 1
  case "$val" in true|false) ;; *) val="true" ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_flag_critical "$state_file" "$session_id" "$key" "$val"
}

_tdd_write_clear_critical() {
  local state_file="$1"
  local session_id="$2"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "idle",
      event: "session-reset",
    }, (s) => {
      if (s.deferredReviewClaim !== "") throw new Error("cancel deferred-review claim first");
      s.active = false; s.implComplete = false; s.chainDone = false;
      s.codeReviewDone = false; s.selfReviewFixed = false; s.workflowActive = false;
      s.workflowTools = []; s.vanilla = false; s.bypasses = [];
      s.reviewRound = 0; s.stopBlockCount = 0;
      s.reviewTicket = ""; s.reviewTicketConsumed = true;
      s.deferredReviewClaim = ""; s.stopBlockCount = 0;
      delete s.reviewRearm;
      delete s.autopilotRunId; delete s.autopilotAttempt;
      delete s.autopilotReturnStage; delete s.chainId; delete s.chainOutcome;
      s.phase = "UNINITIALIZED"; s.step_id = ""; s.history = [];
      return s;
    });
  ' 2>/dev/null
}

tdd_clear_session() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_clear_critical "$state_file" "$session_id"
}

_tdd_clear_standalone_session_critical() {
  local state_file="$1" session_id="$2" expected_revision="${3:-}"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" \
    EXPECTED_REVISION="$expected_revision" node -e '
    const core=require(process.env.CONTROL_CORE);
    const linkKeys=["autopilotRunId","autopilotAttempt","autopilotReturnStage","chainId","chainOutcome"];
    const options={projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID,
      workflowState:"idle",event:"standalone-reset"};
    if(process.env.EXPECTED_REVISION)options.expectedRevision=Number(process.env.EXPECTED_REVISION);
    core.mutateWorkflowState(options,s=>{
      if(!linkKeys.every(key=>!Object.prototype.hasOwnProperty.call(s,key)))throw new Error("bound generation");
      if(s.deferredReviewClaim!=="")throw new Error("cancel deferred-review claim first");
      s.active=false;s.implComplete=false;s.chainDone=false;s.codeReviewDone=false;
      s.selfReviewFixed=false;s.workflowActive=false;s.workflowTools=[];s.vanilla=false;
      s.bypasses=[];s.reviewTicket="";s.reviewTicketConsumed=true;s.reviewRound=0;
      s.deferredReviewClaim="";s.stopBlockCount=0;delete s.reviewRearm;
      s.phase="UNINITIALIZED";s.step_id="";s.history=[];
      return s;
    });
  ' 2>/dev/null
}

# Production standalone reset re-proves linkage absence under the Inner lock.
# The generic library clear remains available to trusted internal callers, but
# a stale `{}` preflight can never deactivate a newly bound Autopilot attempt.
tdd_clear_standalone_session() {
  local session_id="${1:-}" state_file
  [ "$#" -eq 1 ] && [ -n "$session_id" ] || return 1
  state_file="$(tdd_state_file "$session_id")"
  [ -f "$state_file" ] || return 0
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_clear_standalone_session_critical "$state_file" "$session_id"
}

_tdd_clear_autopilot_session_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4" chain_id="$5"
  local expected_revision="${6:-}"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" \
    RUN_ID="$run_id" ATTEMPT="$attempt" CHAIN_ID="$chain_id" \
    EXPECTED_REVISION="$expected_revision" node -e '
    const core=require(process.env.CONTROL_CORE);
    const options={projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID,
      workflowState:"idle",event:"autopilot-reset"};
    if(process.env.EXPECTED_REVISION)options.expectedRevision=Number(process.env.EXPECTED_REVISION);
    core.mutateWorkflowState(options,s=>{
      const exact=typeof s.active==="boolean"&&s.autopilotRunId===process.env.RUN_ID
        &&s.autopilotAttempt===Number(process.env.ATTEMPT)&&s.chainId===process.env.CHAIN_ID;
      if(!exact)throw new Error("stale autopilot generation");
      if(s.deferredReviewClaim!=="")throw new Error("cancel deferred-review claim first");
      s.active=false;s.implComplete=false;s.chainDone=false;s.codeReviewDone=false;
      s.selfReviewFixed=false;s.workflowActive=false;s.workflowTools=[];s.vanilla=false;
      s.bypasses=[];s.reviewTicket="";s.reviewTicketConsumed=true;s.reviewRound=0;
      s.deferredReviewClaim="";s.stopBlockCount=0;delete s.reviewRearm;
      delete s.autopilotRunId;delete s.autopilotAttempt;delete s.autopilotReturnStage;
      delete s.chainId;delete s.chainOutcome;s.phase="UNINITIALIZED";s.step_id="";s.history=[];
      return s;
    });
  ' 2>/dev/null
}

tdd_clear_autopilot_session() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}" state_file
  [ "$#" -eq 4 ] && [ -n "$session_id" ] || return 1
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_clear_autopilot_session_critical "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id"
}

_tdd_write_chain_reset_critical() {
  local state_file="$1"
  local session_id="$2"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "chain_reset",
      event: "chain-reset",
    }, (s) => {
      if (s.deferredReviewClaim !== "") throw new Error("cancel deferred-review claim first");
      s.implComplete = false; s.chainDone = false;
      s.codeReviewDone = false; s.selfReviewFixed = false;
      s.reviewTicket = ""; s.reviewTicketConsumed = true; s.reviewRound = 0;
      s.deferredReviewClaim = ""; s.stopBlockCount = 0;
      delete s.reviewRearm;
      return s;
    });
  ' 2>/dev/null
}

# Clear only the review-chain completion flags (implComplete/chainDone/
# codeReviewDone/selfReviewFixed) in one atomic write, preserving active,
# vanilla, workflow and FSM keys. Called by --tdd-begin so the Stop backstop
# and the self-review fix-round latch re-arm for every chain in a session, not
# just the first.
tdd_reset_chain_flags() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_chain_reset_critical "$state_file" "$session_id"
}

_tdd_begin_session_critical() {
  local state_file="$1" session_id="$2" vanilla="$3" impl_complete="$4"
  local require_deferred_eligible="$5" deferred_claim="$6"
  local autopilot_run_id="${7:-}" autopilot_attempt="${8:-}"
  local autopilot_return_stage="${9:-}" chain_id="${10:-}"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" \
    SID="$session_id" VANILLA="$vanilla" \
      IMPL_COMPLETE="$impl_complete" REQUIRE_DEFERRED_ELIGIBLE="$require_deferred_eligible" \
      DEFERRED_CLAIM="$deferred_claim" AUTOPILOT_RUN_ID="$autopilot_run_id" \
      AUTOPILOT_ATTEMPT="$autopilot_attempt" AUTOPILOT_RETURN_STAGE="$autopilot_return_stage" \
      CHAIN_ID="$chain_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    const deferred = process.env.REQUIRE_DEFERRED_ELIGIBLE === "true";
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: deferred ? "deferred_review" : "active",
      event: deferred ? "deferred-review-begin" : "tdd-begin",
    }, (s) => {
      if (deferred) {
        const eligible = s.active !== true
          || (s.active === true && s.implComplete === true && s.chainDone === true);
        if (!eligible) throw new Error("deferred review generation is not eligible");
        if (s.deferredReviewClaim !== ""
            && s.deferredReviewClaim !== process.env.DEFERRED_CLAIM) {
          throw new Error("another deferred-review claim is active");
        }
      } else if (s.deferredReviewClaim !== "") {
        throw new Error("cancel deferred-review claim before starting a new generation");
      }
      if (typeof s.phase !== "string") s.phase = "UNINITIALIZED";
      if (!Array.isArray(s.history)) s.history = [];
      s.active = true;
      s.vanilla = process.env.VANILLA === "true";
      s.implComplete = process.env.IMPL_COMPLETE === "true";
      s.chainDone = false;
      s.codeReviewDone = false;
      s.selfReviewFixed = false;
      s.reviewTicket = "";
      s.reviewTicketConsumed = true;
      s.reviewRound = 0;
      s.deferredReviewClaim = process.env.DEFERRED_CLAIM || "";
      s.stopBlockCount = 0;
      s.bypasses = [];
      delete s.reviewRearm;
      if (process.env.AUTOPILOT_RUN_ID) {
        s.autopilotRunId = process.env.AUTOPILOT_RUN_ID;
        s.autopilotAttempt = Number.parseInt(process.env.AUTOPILOT_ATTEMPT, 10);
        s.autopilotReturnStage = process.env.AUTOPILOT_RETURN_STAGE;
        s.chainId = process.env.CHAIN_ID;
        s.chainOutcome = "";
      } else {
        delete s.autopilotRunId;
        delete s.autopilotAttempt;
        delete s.autopilotReturnStage;
        delete s.chainId;
        delete s.chainOutcome;
      }
      return s;
    });
  ' 2>/dev/null
}

# Atomically starts a new chain generation. In particular, the old review
# ticket and completion flags disappear in the same locked write that marks the
# new chain active, so a late Agent completion linearizes either before or
# after the new chain — it can never observe a hybrid state.
tdd_begin_session() {
  local supplied_session="${1:-}" session_id vanilla="${2:-false}" impl_complete="${3:-false}"
  local require_deferred_eligible="${4:-false}" deferred_claim="${5:-}"
  local autopilot_run_id="${6:-}" autopilot_attempt="${7:-}"
  local autopilot_return_stage="${8:-}" chain_id="${9:-}" state_file
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  case "$vanilla" in true|false) ;; *) return 1 ;; esac
  case "$impl_complete" in true|false) ;; *) return 1 ;; esac
  case "$require_deferred_eligible" in true|false) ;; *) return 1 ;; esac
  if [ -n "$deferred_claim" ]; then
    case "$deferred_claim" in dc_*) ;; *) return 1 ;; esac
    case "$deferred_claim" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#deferred_claim}" -le 96 ] || return 1
  fi
  if [ -n "$autopilot_run_id$autopilot_attempt$autopilot_return_stage$chain_id" ]; then
    case "$autopilot_run_id" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
    case "$autopilot_run_id" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
    [ "${#autopilot_run_id}" -le 128 ] || return 1
    case "$autopilot_attempt" in ''|*[!0-9]*) return 1 ;; esac
    [ "$autopilot_attempt" -ge 1 ] && [ "$autopilot_attempt" -le 999 ] || return 1
    case "$autopilot_return_stage" in GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER) ;; *) return 1 ;; esac
    case "$chain_id" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
    case "$chain_id" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
    [ "${#chain_id}" -le 128 ] || return 1
  fi
  command -v node >/dev/null 2>&1 || return 1
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  _tdd_begin_session_critical "$state_file" "$session_id" "$vanilla" "$impl_complete" \
    "$require_deferred_eligible" "$deferred_claim" \
    "$autopilot_run_id" "$autopilot_attempt" "$autopilot_return_stage" "$chain_id"
}

# Emit the exact outer-run linkage for this TDD generation as a compact JSON
# object. An empty object means the chain is standalone. Callers must treat an
# invalid/corrupt state as an error rather than guessing a run association.
tdd_autopilot_context() {
  local state_file="${1:-}"
  local expected_session="${2:-}"
  [ -n "$state_file" ] || return 1
  [ -n "$expected_session" ] || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$expected_session")" \
    EXPECTED_SESSION="$expected_session" node -e '
    try {
      const core = require(process.env.CONTROL_CORE);
      const s = core.readWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.EXPECTED_SESSION,
      });
      const rootValid = typeof s.active === "boolean" && typeof s.implComplete === "boolean"
        && typeof s.chainDone === "boolean";
      if (!rootValid) process.exit(3);
      const present = [s.autopilotRunId, s.autopilotAttempt, s.autopilotReturnStage, s.chainId, s.chainOutcome]
        .some(v => v !== undefined);
      if (!present) { process.stdout.write("{}"); process.exit(0); }
      const linkId = v => typeof v === "string" && v.length > 0 && v.length <= 128
        && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(v);
      const valid = linkId(s.autopilotRunId)
        && Number.isInteger(s.autopilotAttempt) && s.autopilotAttempt >= 1 && s.autopilotAttempt <= 999
        && ["GATES","CONVERGE","FIX_FINDINGS","VALIDATE","COVER"].includes(s.autopilotReturnStage)
        && linkId(s.chainId)
        && (s.chainOutcome === "" || s.chainOutcome === "pass" || s.chainOutcome === "no-changes" || s.chainOutcome === "max-rounds");
      if (!valid) process.exit(3);
      process.stdout.write(JSON.stringify({
        sessionId:process.env.EXPECTED_SESSION,
        active:s.active,
        implComplete:s.implComplete,
        chainDone:s.chainDone,
        runId:s.autopilotRunId,
        attempt:s.autopilotAttempt,
        returnStage:s.autopilotReturnStage,
        chainId:s.chainId,
        outcome:s.chainOutcome
      }));
    } catch (_) { process.exit(3); }
  ' 2>/dev/null
}

# Return one strictly validated, self-consistent snapshot for Stop decisions.
# rc=1 means absent; any unsafe path, malformed JSON, partial linkage, or
# foreign session is rc>1 and must be treated fail-closed by callers.
tdd_chain_snapshot() {
  local state_file="${1:-}" expected_session="${2:-}"
  [ -n "$state_file" ] && [ -n "$expected_session" ] || return 2
  [ -e "$state_file" ] || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$expected_session")" \
    EXPECTED_SESSION="$expected_session" node -e '
    try {
      const core=require(process.env.CONTROL_CORE);
      const s=core.readWorkflowState({
        projectRoot:process.env.PROJECT_ROOT,
        sessionId:process.env.EXPECTED_SESSION,
      });
      const natural=v=>Number.isSafeInteger(v)&&v>=0;
      const linkId=v=>typeof v==="string"&&v.length>0&&v.length<=128&&/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(v);
      const root=s&&typeof s==="object"&&!Array.isArray(s)&&typeof s.phase==="string"
        &&Array.isArray(s.history)&&Array.isArray(s.bypasses)
        &&typeof s.active==="boolean"&&typeof s.vanilla==="boolean"
        &&typeof s.implComplete==="boolean"&&typeof s.chainDone==="boolean"
        &&typeof s.codeReviewDone==="boolean"&&typeof s.selfReviewFixed==="boolean"
        &&typeof s.reviewTicket==="string"&&typeof s.reviewTicketConsumed==="boolean"
        &&natural(s.reviewRound)&&natural(s.stopBlockCount);
      if(!root)process.exit(3);
      const values=[s.autopilotRunId,s.autopilotAttempt,s.autopilotReturnStage,s.chainId,s.chainOutcome];
      const count=values.filter(v=>v!==undefined).length;
      let autopilot=null;
      if(count!==0){
        const valid=count===values.length&&linkId(s.autopilotRunId)
          &&Number.isInteger(s.autopilotAttempt)&&s.autopilotAttempt>=1&&s.autopilotAttempt<=999
          &&["GATES","CONVERGE","FIX_FINDINGS","VALIDATE","COVER"].includes(s.autopilotReturnStage)
          &&linkId(s.chainId)&&["","pass","no-changes","max-rounds"].includes(s.chainOutcome);
        if(!valid)process.exit(3);
        autopilot={runId:s.autopilotRunId,attempt:s.autopilotAttempt,
          returnStage:s.autopilotReturnStage,chainId:s.chainId,outcome:s.chainOutcome};
      }
      process.stdout.write(JSON.stringify({sessionId:process.env.EXPECTED_SESSION,active:s.active,
        implComplete:s.implComplete,chainDone:s.chainDone,codeReviewDone:s.codeReviewDone,
        selfReviewFixed:s.selfReviewFixed,vanilla:s.vanilla,
        stopBlockCount:s.stopBlockCount,autopilot}));
    } catch (_) { process.exit(3); }
  ' 2>/dev/null
}

# Mark implementation complete only for one exact active Autopilot generation.
# This prevents a delayed attempt-N completion from arming attempt N+1 after a
# retry or recovery transition reused the same session file.
_tdd_mark_impl_complete_bound_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4" chain_id="$5"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" \
    SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" node -e '
      const core=require(process.env.CONTROL_CORE);
      const current=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID});
      const exact=current.active===true&&typeof current.implComplete==="boolean"
        &&current.chainDone===false&&current.chainOutcome===""
        &&current.autopilotRunId===process.env.RUN_ID
        &&current.autopilotAttempt===Number(process.env.ATTEMPT)&&current.chainId===process.env.CHAIN_ID;
      if(!exact)throw new Error("stale autopilot generation");
      if(current.implComplete===true)process.exit(0);
      core.mutateWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID,
        expectedRevision:current.revision,workflowState:"implementation_complete",event:"implementation-complete"},s=>{
        const stillExact=s.active===true&&s.implComplete===false&&s.chainDone===false&&s.chainOutcome===""
          &&s.autopilotRunId===process.env.RUN_ID&&s.autopilotAttempt===Number(process.env.ATTEMPT)
          &&s.chainId===process.env.CHAIN_ID;
        if(!stillExact)throw new Error("stale autopilot generation");
        s.implComplete=true;return s;
      });
    ' 2>/dev/null
}

tdd_mark_impl_complete_bound() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}" state_file
  [ "$#" -eq 4 ] && [ -n "$session_id" ] || return 1
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_mark_impl_complete_bound_critical "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id"
}

# Standalone completion is also a generation CAS. A caller may have observed
# an unbound session immediately before Autopilot replaced the same Inner file;
# therefore linkage absence is proven again while holding the Inner mutex.
_tdd_mark_impl_complete_standalone_critical() {
  local state_file="$1" session_id="$2"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core=require(process.env.CONTROL_CORE);
    const s=core.readWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID});
    const linkKeys = [
      "autopilotRunId", "autopilotAttempt", "autopilotReturnStage", "chainId", "chainOutcome"
    ];
    const standalone=linkKeys.every(key=>!Object.prototype.hasOwnProperty.call(s,key));
    const exact=standalone&&s.active===true&&typeof s.implComplete==="boolean"
      && s.chainDone === false;
    if(!exact)throw new Error("stale standalone generation");
    if(s.implComplete===true)process.exit(0);
    core.mutateWorkflowState({projectRoot:process.env.PROJECT_ROOT,sessionId:process.env.SID,
      expectedRevision:s.revision,workflowState:"implementation_complete",event:"implementation-complete"},draft=>{
      const stillStandalone=linkKeys.every(key=>!Object.prototype.hasOwnProperty.call(draft,key));
      if(!stillStandalone||draft.active!==true||draft.implComplete!==false||draft.chainDone!==false)
        throw new Error("stale standalone generation");
      draft.implComplete=true;return draft;
    });
  ' 2>/dev/null
}

tdd_mark_impl_complete_standalone() {
  local session_id="${1:-}" state_file
  [ "$#" -eq 1 ] && [ -n "$session_id" ] || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_mark_impl_complete_standalone_critical "$state_file" "$session_id"
}

_tdd_autopilot_link_id_shape_ok() {
  local value="${1:-}"
  [ -n "$value" ] && [ "${#value}" -le 128 ] || return 1
  case "$value" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
  case "$value" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
  return 0
}

_tdd_autopilot_attempt_shape_ok() {
  local attempt="${1:-}"
  case "$attempt" in ''|*[!0-9]*) return 1 ;; esac
  [ "$attempt" -ge 1 ] && [ "$attempt" -le 999 ]
}

# Persist an outcome before the final chain terminus (notably max-rounds before
# the self-review handoff). A non-empty outcome is immutable for this exact
# inner generation. Bound calls use:
#   session outcome run attempt chain [claimed-review-ticket]
# The legacy two-argument form can only confirm an already-persisted identical
# outcome; it may never initialize one because it cannot prove generation or
# ticket ownership.
_tdd_set_chain_outcome_critical() {
  local state_file="$1" session_id="$2" outcome="$3" run_id="$4"
  local attempt="$5" chain_id="$6" ticket="$7" binding_supplied="$8" tmp node_rc
  local native_state_file native_tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }
  STATE_FILE="$native_state_file" SID="$session_id" OUTCOME="$outcome" RUN_ID="$run_id" \
    ATTEMPT="$attempt" CHAIN_ID="$chain_id" TICKET="$ticket" \
    BINDING_SUPPLIED="$binding_supplied" node -e '
      const fs = require("fs");
      let s;
      try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
      catch (_) { process.exit(3); }
      const outcomes = new Set(["", "pass", "no-changes", "max-rounds"]);
      const returnStages = new Set(["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]);
      const linkId = value => typeof value === "string" && value.length > 0 && value.length <= 128
        && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
      const completeLink = s && typeof s === "object" && !Array.isArray(s)
        && linkId(s.autopilotRunId)
        && Number.isInteger(s.autopilotAttempt) && s.autopilotAttempt >= 1 && s.autopilotAttempt <= 999
        && returnStages.has(s.autopilotReturnStage)
        && linkId(s.chainId)
        && typeof s.chainOutcome === "string" && outcomes.has(s.chainOutcome);
      const base = completeLink
        && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
        && s.active === true && s.implComplete === true
        && typeof s.chainDone === "boolean"
        && typeof s.reviewTicket === "string"
        && typeof s.reviewTicketConsumed === "boolean"
        && Number.isInteger(s.reviewRound) && s.reviewRound >= 0;
      if (!base) process.exit(3);

      // An unbound caller may only observe an identical immutable outcome. It
      // cannot create one or choose the current generation by accident.
      if (process.env.BINDING_SUPPLIED !== "true") {
        process.exit(s.chainOutcome === process.env.OUTCOME ? 10 : 3);
      }
      const exactLink = s.autopilotRunId === process.env.RUN_ID
        && s.autopilotAttempt === Number(process.env.ATTEMPT)
        && s.chainId === process.env.CHAIN_ID;
      if (!exactLink) process.exit(3);
      const ticket = process.env.TICKET;
      const ticketOk = ticket
        ? s.reviewTicket === ticket && s.reviewTicketConsumed === true && s.reviewRound >= 1
        : s.reviewTicket === "" && s.reviewTicketConsumed === true && s.reviewRound === 0;
      if (!ticketOk) process.exit(3);
      if (s.chainOutcome === process.env.OUTCOME) process.exit(10);
      if (s.chainOutcome !== "" || s.chainDone !== false) process.exit(3);
      s.chainOutcome = process.env.OUTCOME;
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    ' "$native_tmp" 2>/dev/null
  node_rc=$?
  if [ "$node_rc" -eq 10 ]; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_set_chain_outcome() {
  local session_id="${1:-}" outcome="${2:-}" run_id="${3:-}" attempt="${4:-}"
  local chain_id="${5:-}" ticket="${6:-}" binding_supplied=false state_file
  [ "$#" -eq 2 ] || [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || return 1
  [ -n "$session_id" ] || return 1
  case "$outcome" in pass|no-changes|max-rounds) ;; *) return 1 ;; esac
  if [ "$#" -ge 5 ]; then
    _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
    _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
    _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
    if [ -n "$ticket" ]; then _tdd_review_ticket_shape_ok "$ticket" || return 1; fi
    binding_supplied=true
  fi
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _tdd_set_chain_outcome_critical \
    "$state_file" "$session_id" "$outcome" "$run_id" "$attempt" "$chain_id" \
    "$ticket" "$binding_supplied"
}

# Atomically seal one exact Autopilot-linked inner chain. The outcome and
# chainDone flag share the same locked write, eliminating the partial state
# where Stop can observe a completed chain with no durable outcome. Signature:
#   tdd_finish_autopilot_chain session run attempt chain outcome [claimed-ticket]
_tdd_finish_autopilot_chain_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4"
  local chain_id="$5" outcome="$6" ticket="$7" tmp node_rc
  local native_state_file native_tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }
  STATE_FILE="$native_state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" OUTCOME="$outcome" TICKET="$ticket" node -e '
      const fs = require("fs");
      let s;
      try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
      catch (_) { process.exit(3); }
      const outcomes = new Set(["", "pass", "no-changes", "max-rounds"]);
      const returnStages = new Set(["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]);
      const linkId = value => typeof value === "string" && value.length > 0 && value.length <= 128
        && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
      const completeLink = s && typeof s === "object" && !Array.isArray(s)
        && linkId(s.autopilotRunId)
        && Number.isInteger(s.autopilotAttempt) && s.autopilotAttempt >= 1 && s.autopilotAttempt <= 999
        && returnStages.has(s.autopilotReturnStage)
        && linkId(s.chainId)
        && typeof s.chainOutcome === "string" && outcomes.has(s.chainOutcome);
      const base = completeLink
        && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
        && typeof s.phase === "string" && Array.isArray(s.history) && Array.isArray(s.bypasses)
        && s.active === true && typeof s.vanilla === "boolean" && s.implComplete === true
        && typeof s.chainDone === "boolean"
        && typeof s.codeReviewDone === "boolean" && typeof s.selfReviewFixed === "boolean"
        && typeof s.reviewTicket === "string"
        && typeof s.reviewTicketConsumed === "boolean"
        && Number.isInteger(s.reviewRound) && s.reviewRound >= 0;
      const exactLink = base
        && s.autopilotRunId === process.env.RUN_ID
        && s.autopilotAttempt === Number(process.env.ATTEMPT)
        && s.chainId === process.env.CHAIN_ID;
      if (!exactLink) process.exit(3);
      const ticket = process.env.TICKET;
      const ticketOk = ticket
        ? s.reviewTicket === ticket && s.reviewTicketConsumed === true && s.reviewRound >= 1
        : s.reviewTicket === "" && s.reviewTicketConsumed === true && s.reviewRound === 0;
      if (!ticketOk) process.exit(3);

      // A completed exact retry is a true no-op. Any attempt to reinterpret
      // that generation with another outcome (or ticket, rejected above) is a
      // conflict. A pre-persisted matching max-rounds outcome may be sealed.
      if (s.chainDone === true) process.exit(s.chainOutcome === process.env.OUTCOME ? 10 : 3);
      if (s.chainDone !== false || (s.chainOutcome !== "" && s.chainOutcome !== process.env.OUTCOME)) {
        process.exit(3);
      }
      s.chainOutcome = process.env.OUTCOME;
      s.chainDone = true;
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    ' "$native_tmp" 2>/dev/null
  node_rc=$?
  if [ "$node_rc" -eq 10 ]; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_finish_autopilot_chain() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}"
  local outcome="${5:-}" ticket="${6:-}" state_file
  [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || return 1
  [ -n "$session_id" ] || return 1
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  case "$outcome" in pass|no-changes|max-rounds) ;; *) return 1 ;; esac
  if [ -n "$ticket" ]; then _tdd_review_ticket_shape_ok "$ticket" || return 1; fi
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _tdd_finish_autopilot_chain_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id" "$outcome" "$ticket"
}

# --- Consume-mode reviewer ticket -----------------------------------------
# Every thin code-reviewer spawn gets a fresh, random ticket. The completion
# hook must atomically claim that exact ticket before it may read or mutate the
# auto-fix counter. Re-arming a chain clears the ticket, issuing a new ticket
# invalidates the prior one, and duplicate/late Agent deliveries become no-ops.

_tdd_review_ticket_shape_ok() {
  local ticket="${1:-}"
  [ -n "$ticket" ] && [ "${#ticket}" -le 96 ] || return 1
  case "$ticket" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  return 0
}

_tdd_issue_review_ticket_critical() {
  local state_file="$1" session_id="$2" ticket="$3" tmp native_state_file native_tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }

  if ! STATE_FILE="$native_state_file" SID="$session_id" TICKET="$ticket" \
    CHAIN_RECOVERY="$_ZENSU_TDD_CHAIN_RECOVERY" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    let markerValid;
    try {
      markerValid = require(process.env.CHAIN_RECOVERY).rearmReceiptVerdict(s) !== "stale";
    } catch (_) { process.exit(3); }
    const valid = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
      && typeof s.phase === "string"
      && Array.isArray(s.history)
      && Array.isArray(s.bypasses)
      && typeof s.active === "boolean" && s.active === true
      && typeof s.vanilla === "boolean"
      && typeof s.implComplete === "boolean" && s.implComplete === true
      && typeof s.chainDone === "boolean" && s.chainDone === false
      && typeof s.codeReviewDone === "boolean" && s.codeReviewDone === false
      && typeof s.selfReviewFixed === "boolean"
      && typeof s.reviewTicket === "string"
      && typeof s.reviewTicketConsumed === "boolean"
      && Number.isInteger(s.reviewRound) && s.reviewRound >= 0
      && markerValid;
    if (!valid) process.exit(3);
    s.reviewTicket = process.env.TICKET;
    s.reviewTicketConsumed = false;
    // Issuing the first post-rearm ticket is forward progress. The old
    // crash-retry receipt must not survive into another exhausted budget.
    delete s.reviewRearm;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$native_tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_issue_review_ticket() {
  local supplied_session="${1:-}" session_id state_file state_dir ticket
  [ -n "$supplied_session" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  _tdd_chain_recovery_module_ok || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  ticket="$(node -e 'process.stdout.write("rt_" + require("crypto").randomBytes(16).toString("hex"))' 2>/dev/null)"
  _tdd_review_ticket_shape_ok "$ticket" || return 1

  if _tdd_locked_run "$state_file" \
    _tdd_issue_review_ticket_critical "$state_file" "$session_id" "$ticket"; then
    printf '%s\n' "$ticket"
    return 0
  fi
  return 1
}

_tdd_consume_review_ticket_critical() {
  local state_file="$1" session_id="$2" ticket="$3" _counter_file="${4:-}"
  local state_dir state_tmp next_file native_state_file native_state_tmp native_next_file
  state_dir="$(dirname "$state_file")"
  state_tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  next_file="$(mktemp "${state_file}.next.XXXXXX" 2>/dev/null)" || {
    rm -f "$state_tmp" 2>/dev/null
    return 1
  }
  native_state_file="$(_tdd_native_project_path "$state_file")" || {
    rm -f "$state_tmp" "$next_file" 2>/dev/null
    return 1
  }
  native_state_tmp="$(_tdd_native_project_path "$state_tmp")" || {
    rm -f "$state_tmp" "$next_file" 2>/dev/null
    return 1
  }
  native_next_file="$(_tdd_native_project_path "$next_file")" || {
    rm -f "$state_tmp" "$next_file" 2>/dev/null
    return 1
  }

  if ! STATE_FILE="$native_state_file" SID="$session_id" TICKET="$ticket" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const linkKeys = [
      "autopilotRunId", "autopilotAttempt", "autopilotReturnStage", "chainId", "chainOutcome"
    ];
    const hasOwn = key => Object.prototype.hasOwnProperty.call(s, key);
    const linkCount = s && typeof s === "object" && !Array.isArray(s)
      ? linkKeys.filter(hasOwn).length : 0;
    const linkId = value => typeof value === "string" && value.length > 0 && value.length <= 128
      && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
    let autopilot = null;
    if (linkCount !== 0) {
      const completeLink = linkCount === linkKeys.length
        && linkId(s.autopilotRunId)
        && Number.isInteger(s.autopilotAttempt)
        && s.autopilotAttempt >= 1 && s.autopilotAttempt <= 999
        && ["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]
          .includes(s.autopilotReturnStage)
        && linkId(s.chainId)
        && s.chainOutcome === "";
      if (!completeLink) process.exit(3);
      autopilot = {
        runId: s.autopilotRunId,
        attempt: s.autopilotAttempt,
        returnStage: s.autopilotReturnStage,
        chainId: s.chainId,
        outcome: s.chainOutcome
      };
    }
    const valid = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
      && typeof s.phase === "string"
      && Array.isArray(s.history)
      && Array.isArray(s.bypasses)
      && typeof s.active === "boolean" && s.active === true
      && typeof s.vanilla === "boolean"
      && typeof s.implComplete === "boolean" && s.implComplete === true
      && typeof s.chainDone === "boolean" && s.chainDone === false
      && typeof s.codeReviewDone === "boolean" && s.codeReviewDone === false
      && typeof s.selfReviewFixed === "boolean"
      && typeof s.reviewTicket === "string"
      && s.reviewTicket === process.env.TICKET
      && typeof s.reviewTicketConsumed === "boolean"
      && s.reviewTicketConsumed === false
      && Number.isSafeInteger(s.reviewRound) && s.reviewRound >= 0
      && s.reviewRound < Number.MAX_SAFE_INTEGER;
    if (!valid) process.exit(3);

    // The ticket-bound Session Control document is the sole review-budget
    // authority. No parallel rounds file is consulted or written.
    const next = s.reviewRound + 1;
    s.reviewTicketConsumed = true;
    s.reviewRound = next;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    fs.writeFileSync(process.argv[2], JSON.stringify({next, autopilot}));
  ' "$native_state_tmp" "$native_next_file" 2>/dev/null; then
    rm -f "$state_tmp" "$next_file" 2>/dev/null
    return 1
  fi

  if [ ! -s "$state_tmp" ] || [ ! -s "$next_file" ]; then
    rm -f "$state_tmp" "$next_file" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$state_tmp" "$state_file" "$state_dir" || {
    rm -f "$state_tmp" "$next_file" 2>/dev/null
    return 1
  }
  cat "$next_file"
  rm -f "$next_file" 2>/dev/null
}

# Return the review round and the exact fully-validated Autopilot binding from
# the same locked read that consumes the one-shot ticket. `autopilot:null`
# denotes a truly standalone chain; partial linkage is rejected pre-mutation.
tdd_consume_review_ticket_context() {
  local session_id="${1:-}" ticket="${2:-}" counter_file="${3:-}"
  local state_file
  [ -n "$session_id" ] || return 1
  _tdd_review_ticket_shape_ok "$ticket" || return 1
  command -v node >/dev/null 2>&1 || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_locked_run "$state_file" \
    _tdd_consume_review_ticket_critical "$state_file" "$session_id" "$ticket" "$counter_file"
}

# Compatibility view for existing library callers. The authoritative claim
# transaction above always returns the structured result; this wrapper exposes
# only its round number without performing a second state read or claim.
tdd_consume_review_ticket() {
  local claim
  claim="$(tdd_consume_review_ticket_context "$@")" || return 1
  CLAIM="$claim" node -e '
    try {
      const value = JSON.parse(process.env.CLAIM);
      if (!Number.isSafeInteger(value.next) || value.next < 1) process.exit(3);
      process.stdout.write(String(value.next));
    } catch (_) { process.exit(3); }
  ' 2>/dev/null
}

# Atomically persist the bound max-round self-review handoff. The exact
# postcondition is outcome=max-rounds + codeReviewDone=true while chainDone
# stays false. Only an exact retry of that complete postcondition is idempotent;
# every partial result, stale ticket, or changed generation fails closed.
_tdd_mark_autopilot_max_round_handoff_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4"
  local return_stage="$5" chain_id="$6" ticket="$7" tmp node_rc
  local native_state_file native_tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }
  STATE_FILE="$native_state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    RETURN_STAGE="$return_stage" CHAIN_ID="$chain_id" TICKET="$ticket" node -e '
      const fs = require("fs");
      let s;
      try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
      catch (_) { process.exit(3); }
      const linkId = value => typeof value === "string" && value.length > 0 && value.length <= 128
        && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
      const completeLink = s && typeof s === "object" && !Array.isArray(s)
        && linkId(s.autopilotRunId)
        && Number.isInteger(s.autopilotAttempt)
        && s.autopilotAttempt >= 1 && s.autopilotAttempt <= 999
        && ["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]
          .includes(s.autopilotReturnStage)
        && linkId(s.chainId)
        && ["", "pass", "no-changes", "max-rounds"].includes(s.chainOutcome);
      const exact = completeLink
        && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
        && typeof s.phase === "string" && Array.isArray(s.history) && Array.isArray(s.bypasses)
        && s.active === true && typeof s.vanilla === "boolean" && s.implComplete === true
        && typeof s.chainDone === "boolean"
        && typeof s.codeReviewDone === "boolean" && typeof s.selfReviewFixed === "boolean"
        && typeof s.reviewTicket === "string" && s.reviewTicket === process.env.TICKET
        && s.reviewTicketConsumed === true
        && Number.isSafeInteger(s.reviewRound) && s.reviewRound >= 1
        && s.autopilotRunId === process.env.RUN_ID
        && s.autopilotAttempt === Number(process.env.ATTEMPT)
        && s.autopilotReturnStage === process.env.RETURN_STAGE
        && s.chainId === process.env.CHAIN_ID;
      if (!exact) process.exit(3);
      const completeResult = s.chainOutcome === "max-rounds"
        && s.codeReviewDone === true && s.chainDone === false && s.selfReviewFixed === false;
      if (completeResult) process.exit(10);
      const fresh = s.chainOutcome === "" && s.codeReviewDone === false
        && s.chainDone === false && s.selfReviewFixed === false;
      if (!fresh) process.exit(3);
      s.chainOutcome = "max-rounds";
      s.codeReviewDone = true;
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    ' "$native_tmp" 2>/dev/null
  node_rc=$?
  if [ "$node_rc" -eq 10 ]; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_mark_autopilot_max_round_handoff() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}"
  local return_stage="${4:-}" chain_id="${5:-}" ticket="${6:-}" state_file state_dir
  [ "$#" -eq 6 ] && [ -n "$session_id" ] || return 1
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  case "$return_stage" in GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER) ;; *) return 1 ;; esac
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  _tdd_review_ticket_shape_ok "$ticket" || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_locked_run "$state_file" _tdd_mark_autopilot_max_round_handoff_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$return_stage" "$chain_id" "$ticket"
}

_tdd_mark_review_converged_critical() {
  local state_file="$1" session_id="$2" ticket="$3" key="$4" tmp
  local native_state_file native_tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }

  if ! STATE_FILE="$native_state_file" SID="$session_id" TICKET="$ticket" KEY="$key" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const key = process.env.KEY;
    const validKey = key === "codeReviewDone" || key === "chainDone" || key === "selfReviewFixed";
    const valid = validKey
      && s && typeof s === "object" && !Array.isArray(s)
      && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
      && typeof s.phase === "string"
      && Array.isArray(s.history)
      && Array.isArray(s.bypasses)
      && typeof s.active === "boolean" && s.active === true
      && typeof s.vanilla === "boolean"
      && typeof s.implComplete === "boolean" && s.implComplete === true
      && typeof s.chainDone === "boolean" && s.chainDone === false
      && typeof s.codeReviewDone === "boolean"
      && typeof s.selfReviewFixed === "boolean"
      && typeof s.reviewTicket === "string" && s.reviewTicket === process.env.TICKET
      && typeof s.reviewTicketConsumed === "boolean" && s.reviewTicketConsumed === true
      && Number.isInteger(s.reviewRound) && s.reviewRound >= 1;
    if (!valid) process.exit(3);
    if (key === "codeReviewDone" && s.codeReviewDone !== false) process.exit(3);
    if (key === "selfReviewFixed" && (s.codeReviewDone !== true || s.selfReviewFixed !== false)) process.exit(3);
    s[key] = true;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$native_tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

# Every reviewer/self-review terminus after the one-shot claim is bound to the
# same consumed ticket. A concurrent --tdd-begin therefore invalidates stale
# PASS, max-round, latch, and terminal writes as one generation boundary.
tdd_mark_review_converged() {
  local session_id="${1:-}" ticket="${2:-}" key="${3:-}" state_file state_dir
  _tdd_review_ticket_shape_ok "$ticket" || return 1
  case "$key" in codeReviewDone|chainDone|selfReviewFixed) ;; *) return 1 ;; esac
  command -v node >/dev/null 2>&1 || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_locked_run "$state_file" \
    _tdd_mark_review_converged_critical "$state_file" "$session_id" "$ticket" "$key"
}

_tdd_mark_unclaimed_review_critical() {
  local state_file="$1" session_id="$2" key="$3" tmp native_state_file native_tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }
  if ! STATE_FILE="$native_state_file" SID="$session_id" KEY="$key" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const key = process.env.KEY;
    const validKey = key === "codeReviewDone" || key === "chainDone" || key === "selfReviewFixed";
    const linkKeys = [
      "autopilotRunId", "autopilotAttempt", "autopilotReturnStage", "chainId", "chainOutcome"
    ];
    const standalone = s && typeof s === "object" && !Array.isArray(s)
      && linkKeys.every(linkKey => !Object.prototype.hasOwnProperty.call(s, linkKey));
    const valid = validKey && standalone
      && !Object.prototype.hasOwnProperty.call(s, "reviewRearm")
      && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
      && s.active === true && s.implComplete === true && s.chainDone === false
      && typeof s.codeReviewDone === "boolean" && typeof s.selfReviewFixed === "boolean"
      && s.reviewTicket === "" && s.reviewTicketConsumed === true && s.reviewRound === 0;
    if (!valid) process.exit(3);
    if (key === "codeReviewDone" && s.codeReviewDone !== false) process.exit(3);
    if (key === "selfReviewFixed" && (s.codeReviewDone !== true || s.selfReviewFixed !== false)) process.exit(3);
    s[key] = true;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$native_tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

# Compatibility for zero-diff and pre-ticket legacy chains. Once a review
# ticket was issued/consumed, every terminus must carry that ticket; an
# unqualified stale command is then rejected instead of closing a new chain.
tdd_mark_unclaimed_review() {
  local session_id="${1:-}" key="${2:-}" state_file state_dir
  [ -n "$session_id" ] || return 1
  case "$key" in codeReviewDone|chainDone|selfReviewFixed) ;; *) return 1 ;; esac
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_locked_run "$state_file" _tdd_mark_unclaimed_review_critical \
    "$state_file" "$session_id" "$key"
}

_tdd_ensure_self_review_ticket_critical() {
  local state_file="$1" session_id="$2" candidate="$3" result_file="$4" tmp
  local native_state_file native_tmp native_result_file
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }
  native_result_file="$(_tdd_native_project_path "$result_file")" || { rm -f "$tmp"; return 1; }
  if ! STATE_FILE="$native_state_file" SID="$session_id" CANDIDATE="$candidate" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const base = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
      && s.active === true && s.implComplete === true
      && s.codeReviewDone === true && s.chainDone === false;
    if (!base) process.exit(3);
    let ticket = s.reviewTicket;
    const alreadyBound = typeof ticket === "string" && ticket.length > 0 && ticket.length <= 96
      && /^[A-Za-z0-9_-]+$/.test(ticket) && s.reviewTicketConsumed === true
      && Number.isInteger(s.reviewRound) && s.reviewRound >= 1;
    if (!alreadyBound) {
      const legacy = (ticket === "" || ticket == null)
        && (s.reviewTicketConsumed === true || s.reviewTicketConsumed == null)
        && (s.reviewRound === 0 || s.reviewRound == null);
      if (!legacy) process.exit(3);
      ticket = process.env.CANDIDATE;
      s.reviewTicket = ticket;
      s.reviewTicketConsumed = true;
      s.reviewRound = 1;
    }
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    fs.writeFileSync(process.argv[2], ticket);
  ' "$native_tmp" "$native_result_file" 2>/dev/null; then
    rm -f "$tmp" "$result_file" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp" "$result_file"; return 1; }
}

tdd_ensure_self_review_ticket() {
  local session_id="${1:-}" state_file state_dir candidate result_file
  [ -n "$session_id" ] || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  candidate="$(node -e 'process.stdout.write("rt_" + require("crypto").randomBytes(16).toString("hex"))' 2>/dev/null)"
  _tdd_review_ticket_shape_ok "$candidate" || return 1
  result_file="$(mktemp "${state_file}.self-review-ticket.XXXXXX" 2>/dev/null)" || return 1
  if _tdd_locked_run "$state_file" _tdd_ensure_self_review_ticket_critical \
      "$state_file" "$session_id" "$candidate" "$result_file"; then
    cat "$result_file"
    rm -f "$result_file" 2>/dev/null
    return 0
  fi
  rm -f "$result_file" 2>/dev/null
  return 1
}

_tdd_increment_stop_budget_critical() {
  local state_file="$1" session_id="$2" _budget_file="${3:-}" result_file="$4"
  local expected_run="${5:-}" expected_attempt="${6:-}" expected_chain="${7:-}"
  local expected_return_stage="${8:-}"
  local state_dir state_tmp native_state_file native_state_tmp native_result_file
  state_dir="$(dirname "$state_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  state_tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$state_tmp"; return 1; }
  native_state_tmp="$(_tdd_native_project_path "$state_tmp")" || { rm -f "$state_tmp"; return 1; }
  native_result_file="$(_tdd_native_project_path "$result_file")" || { rm -f "$state_tmp"; return 1; }
  if ! STATE_FILE="$native_state_file" SID="$session_id" \
      EXPECTED_RUN="$expected_run" EXPECTED_ATTEMPT="$expected_attempt" \
      EXPECTED_CHAIN="$expected_chain" EXPECTED_RETURN_STAGE="$expected_return_stage" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    if (!s || typeof s !== "object" || Array.isArray(s)
        || s.session_id_hash !== `sha256:${process.env.SID.slice("scv1_".length)}`
        || s.active !== true || s.implComplete !== true || s.chainDone !== false) process.exit(3);
    if (process.env.EXPECTED_RUN) {
      const normalOutcome = s.chainOutcome === "";
      const maxHandoff = s.chainOutcome === "max-rounds"
        && s.codeReviewDone === true
        && typeof s.selfReviewFixed === "boolean"
        && typeof s.reviewTicket === "string"
        && s.reviewTicket.length > 0 && s.reviewTicket.length <= 96
        && /^[A-Za-z0-9_-]+$/.test(s.reviewTicket)
        && s.reviewTicketConsumed === true
        && Number.isSafeInteger(s.reviewRound) && s.reviewRound >= 1;
      if (s.autopilotRunId !== process.env.EXPECTED_RUN
          || s.autopilotAttempt !== Number(process.env.EXPECTED_ATTEMPT)
          || s.chainId !== process.env.EXPECTED_CHAIN
          || s.autopilotReturnStage !== process.env.EXPECTED_RETURN_STAGE
          || !(normalOutcome || maxHandoff)) process.exit(3);
    }
    const current = Number.isInteger(s.stopBlockCount) && s.stopBlockCount >= 0
      ? s.stopBlockCount : 0;
    if (current > 10000) process.exit(3);
    const next = current + 1;
    s.stopBlockCount = next;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    fs.writeFileSync(process.argv[2], String(next));
  ' "$native_state_tmp" "$native_result_file" 2>/dev/null; then
    rm -f "$state_tmp" "$result_file" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$state_tmp" "$state_file" "$state_dir" || {
    rm -f "$state_tmp" "$result_file" 2>/dev/null
    return 1
  }
}

tdd_increment_stop_budget() {
  local session_id="${1:-}" state_file state_dir result_file
  [ -n "$session_id" ] || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  result_file="$(mktemp "${state_file}.stop-count.XXXXXX" 2>/dev/null)" || return 1
  if _tdd_locked_run "$state_file" _tdd_increment_stop_budget_critical \
      "$state_file" "$session_id" "" "$result_file"; then
    cat "$result_file"
    rm -f "$result_file" 2>/dev/null
    return 0
  fi
  rm -f "$result_file" 2>/dev/null
  return 1
}

_tdd_rearm_review_critical() {
  local state_file="$1" session_id="$2" ticket="$3" _counter_file="${4:-}" _stopblocks_file="${5:-}"
  local state_dir tmp native_state_file native_tmp
  state_dir="$(dirname "$state_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }
  if ! STATE_FILE="$native_state_file" SID="$session_id" TICKET="$ticket" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const linkKeys = [
      "autopilotRunId", "autopilotAttempt", "autopilotReturnStage", "chainId", "chainOutcome"
    ];
    const fullyStandalone = s && linkKeys.every(key => !Object.prototype.hasOwnProperty.call(s, key));
    const valid = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
      && s.active === true && s.implComplete === true
      && typeof s.chainDone === "boolean" && typeof s.codeReviewDone === "boolean"
      && typeof s.selfReviewFixed === "boolean"
      && (s.chainDone === true || s.codeReviewDone === true)
      && s.reviewTicket === process.env.TICKET && s.reviewTicketConsumed === true
      && Number.isInteger(s.reviewRound) && s.reviewRound >= 1
      && fullyStandalone;
    if (!valid) process.exit(3);
    s.chainDone = false;
    s.codeReviewDone = false;
    s.selfReviewFixed = false;
    s.reviewTicket = "";
    s.reviewTicketConsumed = true;
    s.reviewRound = 0;
    s.stopBlockCount = 0;
    delete s.chainOutcome;
    delete s.reviewRearm;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$native_tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$state_dir" \
    || { rm -f "$tmp"; return 1; }
}

tdd_rearm_review() {
  local session_id="${1:-}" ticket="${2:-}" state_file state_dir
  [ -n "$session_id" ] || return 1
  _tdd_review_ticket_shape_ok "$ticket" || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_locked_run "$state_file" _tdd_rearm_review_critical \
    "$state_file" "$session_id" "$ticket" "" ""
}

# Rearm one exact Autopilot-linked review generation. The consumed ticket is
# used as a capability but only its SHA-256 digest is retained in the receipt.
# Signature:
#   tdd_rearm_autopilot_review session run attempt chain consumed-ticket [retire]
#
# retire=false keeps the current Inner chain active (the TDD_RUNNING and
# self-review-handoff case). retire=true makes an already Outer-BLOCKED Inner
# chain inactive so RESUME must start a fresh bound TDD attempt.
_tdd_rearm_autopilot_review_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4"
  local chain_id="$5" ticket="$6" retire="$7" _counter_file="${8:-}"
  local _stopblocks_file="${9:-}" state_dir tmp node_rc native_state_file native_tmp
  state_dir="$(dirname "$state_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || { rm -f "$tmp"; return 1; }
  native_tmp="$(_tdd_native_project_path "$tmp")" || { rm -f "$tmp"; return 1; }

  _tdd_chain_recovery_module_ok || { rm -f "$tmp"; return 1; }
  STATE_FILE="$native_state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" TICKET="$ticket" RETIRE="$retire" \
    CHAIN_RECOVERY="$_ZENSU_TDD_CHAIN_RECOVERY" node -e '
      const fs = require("fs");
      const crypto = require("crypto");
      let s;
      try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
      catch (_) { process.exit(3); }

      let chainShapes;
      try { chainShapes = require(process.env.CHAIN_RECOVERY); }
      catch (_) { process.exit(3); }
      const linkId = chainShapes.isLinkId;
      const returnStages = new Set(chainShapes.RETURN_STAGES);
      const markerKeys = chainShapes.REARM_MARKER_KEYS;
      const strictMarker = marker => {
        if (!marker || typeof marker !== "object" || Array.isArray(marker)) return false;
        const keys = Object.keys(marker).sort();
        return keys.length === markerKeys.length
          && keys.every((key, index) => key === markerKeys[index])
          && marker.schemaVersion === 1
          && marker.status === "pending"
          && linkId(marker.runId)
          && Number.isInteger(marker.attempt) && marker.attempt >= 1 && marker.attempt <= 999
          && linkId(marker.chainId)
          && typeof marker.consumedTicketSha256 === "string"
          && /^[a-f0-9]{64}$/.test(marker.consumedTicketSha256)
          && typeof marker.retire === "boolean";
      };
      const digest = crypto.createHash("sha256").update(process.env.TICKET, "utf8").digest("hex");
      const requested = {
        schemaVersion: 1,
        status: "pending",
        runId: process.env.RUN_ID,
        attempt: Number(process.env.ATTEMPT),
        chainId: process.env.CHAIN_ID,
        consumedTicketSha256: digest,
        retire: process.env.RETIRE === "true"
      };
      const markerMatches = marker => strictMarker(marker)
        && marker.schemaVersion === requested.schemaVersion
        && marker.status === requested.status
        && marker.runId === requested.runId
        && marker.attempt === requested.attempt
        && marker.chainId === requested.chainId
        && marker.consumedTicketSha256 === requested.consumedTicketSha256
        && marker.retire === requested.retire;
      const rootShape = s && typeof s === "object" && !Array.isArray(s)
        && s.session_id_hash === `sha256:${process.env.SID.slice("scv1_".length)}`
        && typeof s.phase === "string" && Array.isArray(s.history) && Array.isArray(s.bypasses)
        && typeof s.active === "boolean" && typeof s.vanilla === "boolean"
        && typeof s.implComplete === "boolean" && typeof s.chainDone === "boolean"
        && typeof s.codeReviewDone === "boolean" && typeof s.selfReviewFixed === "boolean"
        && typeof s.reviewTicket === "string" && typeof s.reviewTicketConsumed === "boolean"
        && Number.isInteger(s.reviewRound) && s.reviewRound >= 0
        && Number.isInteger(s.stopBlockCount) && s.stopBlockCount >= 0
        && linkId(s.autopilotRunId)
        && Number.isInteger(s.autopilotAttempt) && s.autopilotAttempt >= 1 && s.autopilotAttempt <= 999
        && returnStages.has(s.autopilotReturnStage)
        && linkId(s.chainId)
        && typeof s.chainOutcome === "string";
      const exactLink = rootShape
        && s.autopilotRunId === requested.runId
        && s.autopilotAttempt === requested.attempt
        && s.chainId === requested.chainId;

      if (s && Object.prototype.hasOwnProperty.call(s, "reviewRearm")) {
        // A malformed receipt is corruption, never permission to guess or
        // overwrite. An exact receipt is retryable only while its committed
        // post-state is still unchanged.
        if (!strictMarker(s.reviewRearm)) process.exit(3);
        const postState = exactLink && markerMatches(s.reviewRearm)
          && s.active === !requested.retire
          && s.implComplete === !requested.retire
          && s.chainDone === false && s.codeReviewDone === false && s.selfReviewFixed === false
          && s.reviewTicket === "" && s.reviewTicketConsumed === true
          && s.reviewRound === 0 && s.stopBlockCount === 0 && s.chainOutcome === "";
        process.exit(postState ? 10 : 3);
      }

      const terminalShape = requested.retire
        ? s.chainDone === true
        : s.chainDone === false && s.codeReviewDone === true;
      const fresh = exactLink
        && s.active === true && s.implComplete === true
        && terminalShape
        && s.reviewTicket === process.env.TICKET && s.reviewTicketConsumed === true
        && s.reviewRound >= 1 && s.chainOutcome === "max-rounds";
      if (!fresh) process.exit(3);

      s.active = !requested.retire;
      s.implComplete = !requested.retire;
      s.chainDone = false;
      s.codeReviewDone = false;
      s.selfReviewFixed = false;
      s.reviewTicket = "";
      s.reviewTicketConsumed = true;
      s.reviewRound = 0;
      s.stopBlockCount = 0;
      s.chainOutcome = "";
      s.reviewRearm = requested;
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    ' "$native_tmp" 2>/dev/null
  node_rc=$?

  if [ "$node_rc" -eq 10 ]; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$state_file" "$state_dir" \
    || { rm -f "$tmp"; return 1; }
}

tdd_rearm_autopilot_review() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}"
  local ticket="${5:-}" retire="${6:-false}" state_file state_dir
  [ "$#" -eq 5 ] || [ "$#" -eq 6 ] || return 1
  [ -n "$session_id" ] || return 1
  [ "${#session_id}" -le 128 ] || return 1
  case "$session_id" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  _tdd_review_ticket_shape_ok "$ticket" || return 1
  case "$retire" in true|false) ;; *) return 1 ;; esac
  command -v node >/dev/null 2>&1 || return 1

  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_locked_run "$state_file" _tdd_rearm_autopilot_review_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id" "$ticket" \
    "$retire" "" ""
}

_tdd_chain_preflight() {
  local supplied_session="${1:-}" session_id state_file state_dir
  unset _TDD_CHAIN_SESSION _TDD_CHAIN_STATE_FILE _TDD_CHAIN_PROJECT_ROOT
  [ -n "$supplied_session" ] || return 2
  command -v node >/dev/null 2>&1 || return 2
  _tdd_chain_recovery_module_ok || return 2
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 2
  state_file="$(tdd_state_file "$session_id")" || return 2
  state_dir="$(dirname "$state_file")"
  [ -e "$state_file" ] || [ -L "$state_file" ] || return 1
  _tdd_path_safe "$state_file" regular "$state_dir" || return 2
  _tdd_state_storage_safe "$state_file" || return 2
  _TDD_CHAIN_SESSION="$session_id"
  _TDD_CHAIN_STATE_FILE="$state_file"
  _TDD_CHAIN_PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" || return 2
  return 0
}

tdd_chain_diagnostics() {
  local rc project_root session_id
  _tdd_chain_preflight "${1:-}"
  rc=$?
  project_root="${_TDD_CHAIN_PROJECT_ROOT:-}"
  session_id="${_TDD_CHAIN_SESSION:-}"
  unset _TDD_CHAIN_SESSION _TDD_CHAIN_STATE_FILE _TDD_CHAIN_PROJECT_ROOT
  [ "$rc" -eq 0 ] || return "$rc"
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" CHAIN_RECOVERY="$_ZENSU_TDD_CHAIN_RECOVERY" \
    PROJECT_ROOT="$project_root" SID="$session_id" node -e '
    try {
      const core = require(process.env.CONTROL_CORE);
      const chain = require(process.env.CHAIN_RECOVERY);
      process.stdout.write(JSON.stringify(chain.classifyChain(core.readWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
      }))));
    } catch (_) { process.exit(2); }
  ' 2>/dev/null
}

_tdd_recover_chain_critical() {
  local project_root="$1" session_id="$2" node_rc
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CHAIN_RECOVERY="$_ZENSU_TDD_CHAIN_RECOVERY" \
    PROJECT_ROOT="$project_root" SID="$session_id" node -e '
    const fs = require("fs");
    const emit = (text, code) => { fs.writeSync(1, text); process.exit(code); };
    let core;
    let chain;
    try {
      core = require(process.env.CONTROL_CORE);
      chain = require(process.env.CHAIN_RECOVERY);
    } catch (_) { emit("op:module-unreadable", 2); }
    const binding = {
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
    };
    let before;
    try {
      before = chain.classifyChain(core.readWorkflowState(binding));
    } catch (_) { emit("op:unreadable", 2); }
    if (!before.recoverable) emit("refused:" + before.nextCommandId, 3);
    const REFUSED = "zensu-chain-recover-refused";
    const UNCLASSIFIABLE = "zensu-chain-recover-unclassifiable";
    const stamp = new Date().toISOString();
    let mutated = false;
    try {
      core.mutateWorkflowState({
        projectRoot: binding.projectRoot,
        sessionId: binding.sessionId,
        workflowState: "chain_recovered",
        event: "chain-recovered",
      }, (s) => {
        let fresh;
        try { fresh = chain.classifyChain(s); }
        catch (_) { throw new Error(UNCLASSIFIABLE); }
        if (!fresh.recoverable) throw new Error(REFUSED);
        delete s.reviewRearm;
        if (!Array.isArray(s.history)) s.history = [];
        const entry = {
          step: typeof s.step_id === "string" ? s.step_id : "",
          phase: chain.RECOVERY_HISTORY_PHASE,
          reason: chain.RECOVERY_HISTORY_REASON_PREFIX
            + "rearm receipt that disagreed with this document was dropped",
        };
        if (stamp) entry.ts = stamp;
        s.history.push(entry);
        mutated = true;
        return s;
      });
    } catch (error) {
      if (error && error.message === REFUSED) emit("refused:stale-generation", 3);
      if (error && error.message === UNCLASSIFIABLE) emit("refused:unclassifiable-generation", 3);
      if (!mutated) emit("op:write-failed", 2);
      let landed = false;
      try {
        landed = chain.rearmReceiptVerdict(core.readWorkflowState(binding)) === "none";
      } catch (_) { landed = false; }
      emit(landed ? "op:write-landed-unconfirmed" : "op:write-failed", 2);
    }
    emit("recovered:" + before.shape, 0);
  ' 2>/dev/null
  node_rc=$?
  return "$node_rc"
}

tdd_recover_chain() {
  local verdict rc state_file project_root session_id
  _tdd_chain_preflight "${1:-}"
  rc=$?
  state_file="${_TDD_CHAIN_STATE_FILE:-}"
  project_root="${_TDD_CHAIN_PROJECT_ROOT:-}"
  session_id="${_TDD_CHAIN_SESSION:-}"
  unset _TDD_CHAIN_SESSION _TDD_CHAIN_STATE_FILE _TDD_CHAIN_PROJECT_ROOT
  [ "$rc" -eq 0 ] || return "$rc"
  verdict="$(_tdd_locked_run "$state_file" _tdd_recover_chain_critical \
    "$project_root" "$session_id")"
  rc=$?
  case "$rc" in
    0|2|3) ;;
    *)
      case "$verdict" in
        recovered:*) verdict="op:write-landed-unconfirmed"; rc=2 ;;
        op:*) rc=2 ;;
        refused:*) rc=3 ;;
        *) verdict="op:lock-failed"; rc=2 ;;
      esac
      ;;
  esac
  printf '%s' "$verdict"
  return "$rc"
}

_tdd_write_workflow_begin_critical() {
  local state_file="$1"
  local session_id="$2"
  local tools="$3"

  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" TOOLS="$tools" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "workflow_active",
        event: "workflow-begin",
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state.workflowActive = true;
        state.workflowTools = (process.env.TOOLS || "").split(",").map(s => s.trim()).filter(Boolean);
        return state;
      });
    ' 2>/dev/null
}

tdd_workflow_begin() {
  local supplied_session="${1:-}"
  local session_id
  local tools="${2:-}"
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_workflow_begin_critical "$state_file" "$session_id" "$tools"
}

_tdd_read_validated_state() {
  local state_file="${1:-}"
  local mode="${2:-status}"
  local arg="${3:-}"
  local base key expected project_root native_project_root native_state_file lib_dir
  if [ -z "$state_file" ]; then
    echo "missing"; return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "invalid"; return 0
  fi

  base="$(basename "$state_file")"
  case "$base" in
    tdd-phase-scv1_*.json) key="${base#tdd-phase-}"; key="${key%.json}" ;;
    *) echo "invalid"; return 0 ;;
  esac
  expected="$(tdd_state_file "$key")" || { echo "invalid"; return 0; }
  [ "$state_file" = "$expected" ] || { echo "invalid"; return 0; }
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || { echo "invalid"; return 0; }
  native_project_root="$(_tdd_native_project_path "$project_root")" \
    || { echo "invalid"; return 0; }
  native_state_file="$(_tdd_native_project_path "$state_file")" \
    || { echo "invalid"; return 0; }
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" \
    || { echo "invalid"; return 0; }
  [ -f "$lib_dir/session-control-core-v1.js" ] \
    && [ ! -L "$lib_dir/session-control-core-v1.js" ] \
    || { echo "invalid"; return 0; }

  # Native Node receives the already-rendered host paths as an opaque NUL frame
  # over stdin. MSYS2 never interprets stdin, so an ambient conversion policy
  # cannot rewrite the project/state identity before validation. The trusted
  # Core module resolves relative to the canonically verified executing lib.
  printf '%s\0%s\0%s\0%s\0' \
    "$native_project_root" "$native_state_file" "$mode" "$arg" | (
    cd -P -- "$lib_dir" || exit 1
    node -e '
      const fs = require("node:fs");
      const path = require("node:path");
      const emit = (status, value) => {
        process.stdout.write(status);
        if (status === "valid" && value !== undefined) process.stdout.write("\n" + String(value));
      };
      const fields = fs.readFileSync(0).toString("utf8").split("\0");
      if (fields.length !== 5 || fields[4] !== "") {
        emit("invalid"); process.exit(0);
      }
      const [projectRoot, file, mode = "status", arg = ""] = fields;
      const match = /^tdd-phase-(scv1_[a-f0-9]{64})\.json$/.exec(path.basename(file));
      if (!match) { emit("invalid"); process.exit(0); }
      let stat;
      try { stat = fs.lstatSync(file); }
      catch (error) { emit(error && error.code === "ENOENT" ? "missing" : "invalid"); process.exit(0); }
      if (stat.isSymbolicLink() || !stat.isFile()) { emit("invalid"); process.exit(0); }
      let state;
      try {
        const core = require("./session-control-core-v1.js");
        state = core.readWorkflowState({ projectRoot, sessionId: match[1] });
      } catch (_) { emit("invalid"); process.exit(0); }

      if (mode === "status") emit("valid");
      else if (mode === "flag") emit("valid", state[arg] === true ? "true" : "false");
      else if (mode === "phase") emit("valid", state.phase === undefined ? "UNINITIALIZED" : state.phase);
      else if (mode === "step") emit("valid", state.step_id === undefined ? "" : state.step_id);
      else if (mode === "counter") {
        const value = state[arg] === undefined ? 0 : state[arg];
        if (!Number.isSafeInteger(value) || value < 0) emit("invalid");
        else emit("valid", value);
      }
      else if (mode === "red-fail") {
        const hit = Array.isArray(state.history)
          && state.history.some(entry => entry.step === arg && entry.phase === "RED_FAIL");
        emit("valid", hit ? "true" : "false");
      } else if (mode === "workflow-tool") {
        const hit = state.workflowActive === true
          && Array.isArray(state.workflowTools)
          && state.workflowTools.includes(arg);
        emit("valid", hit ? "true" : "false");
      } else if (mode === "bypasses") {
        const allow = String(arg).split(" ").filter(Boolean);
        const values = Array.isArray(state.bypasses)
          ? state.bypasses.filter((value, index, array) => allow.includes(value) && array.indexOf(value) === index)
          : [];
        emit("valid", values.join(", "));
      } else emit("invalid");
    '
  ) 2>/dev/null || echo "invalid"
}

tdd_state_status() {
  local result
  result="$(_tdd_read_validated_state "${1:-}" status)"
  case "$result" in valid|missing|invalid) echo "$result" ;; *) echo "invalid" ;; esac
}

tdd_get_flag() {
  local state_file="${1:-}"
  local key="${2:-}"
  if [ -z "$key" ]; then
    echo "false"; return 0
  fi
  case "$key" in
    active|vanilla|implComplete|chainDone|codeReviewDone|selfReviewFixed|workflowActive) ;;
    *) echo "invalid"; return 0 ;;
  esac
  local result status value
  result="$(_tdd_read_validated_state "$state_file" flag "$key")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "false"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "invalid"; return 0; }
  value="${result#*$'\n'}"
  case "$value" in true|false) echo "$value" ;; *) echo "invalid" ;; esac
}

tdd_session_active()    { tdd_get_flag "${1:-}" active; }
tdd_vanilla_mode()      { tdd_get_flag "${1:-}" vanilla; }
tdd_impl_complete()     { tdd_get_flag "${1:-}" implComplete; }
tdd_chain_done()        { tdd_get_flag "${1:-}" chainDone; }
tdd_code_review_done()  { tdd_get_flag "${1:-}" codeReviewDone; }
tdd_self_review_fixed() { tdd_get_flag "${1:-}" selfReviewFixed; }
zensu_workflow_active()  { tdd_get_flag "${1:-}" workflowActive; }

tdd_get_counter() {
  local state_file="${1:-}" key="${2:-}" result status value
  case "$key" in reviewRound|stopBlockCount) ;; *) echo "invalid"; return 0 ;; esac
  result="$(_tdd_read_validated_state "$state_file" counter "$key")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "0"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  value="${result#*$'\n'}"
  case "$value" in ''|*[!0-9]*) echo "invalid" ;; *) echo "$value" ;; esac
}

tdd_claimed_review_ticket() {
  local state_file="${1:-}" native_state_file
  [ -n "$state_file" ] && _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" \
    || return 1
  native_state_file="$(_tdd_native_project_path "$state_file")" || return 1
  node -e '
    try {
      const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const ticket = s && s.reviewTicket;
      const valid = typeof ticket === "string" && ticket.length > 0 && ticket.length <= 96
        && /^[A-Za-z0-9_-]+$/.test(ticket)
        && s.reviewTicketConsumed === true
        && Number.isInteger(s.reviewRound) && s.reviewRound >= 1;
      if (!valid) process.exit(3);
      process.stdout.write(ticket);
    } catch (_) { process.exit(3); }
  ' "$native_state_file" 2>/dev/null
}

zensu_workflow_allows() {
  local sf="${1:-}" tool="${2:-}"
  [ -n "$tool" ] || { echo "false"; return 0; }
  local result status value
  result="$(_tdd_read_validated_state "$sf" workflow-tool "$tool")"
  status="${result%%$'\n'*}"
  [ "$status" = "valid" ] || { echo "false"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "true" ] && echo "true" || echo "false"
}

tdd_phase() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" phase)"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "UNINITIALIZED"; return 0 ;;
    invalid) echo "INVALID_STATE"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "INVALID_STATE"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value="UNINITIALIZED"
  echo "$value"
}

tdd_step() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" step)"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo ""; return 0 ;;
    invalid) echo "INVALID_STATE"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "INVALID_STATE"; return 0; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value=""
  echo "$value"
}

tdd_has_red_fail() {
  local state_file="${1:-}"
  local step="${2:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" red-fail "$step")"
  status="${result%%$'\n'*}"
  case "$status" in
    missing) echo "false"; return 0 ;;
    invalid) echo "invalid"; return 0 ;;
  esac
  [ "$status" = "valid" ] || { echo "invalid"; return 0; }
  value="${result#*$'\n'}"
  case "$value" in true|false) echo "$value" ;; *) echo "invalid" ;; esac
}


# --- Bypass ledger (visible opt-outs) --------------------------------------
# Gate escapes (ZENSU_*=off) stay free but become visible: each gate records
# the env-var name it was bypassed through into the per-session state file
# while the session is active. Dedup per gate; consumers render the list at
# chain end. Writes are fail-open — a ledger failure never blocks a gate.
# Ledger hygiene: entries are validated against the closed gate allowlist at
# write AND read (pre-seeded junk is sanitized before the 32-entry cap so it
# can never exhaust the ledger) — a crafted value can neither smuggle
# directive text into the rendered surfaces nor bloat the state file every
# hook parses. New gates extend ZENSU_BYPASS_GATE_ALLOWLIST in ONE place.
# This ledger records ONLY gate escapes, so every entry rendered under "Gates
# bypassed" is true. Operator interventions that are not gate escapes — the
# --chain-recover repair — record their provenance as a workflow history entry
# inside their own transaction instead.
# tdd_bypasses is the ONE reader of the _tdd_read_validated_state family that
# signals through its EXIT STATUS rather than an echoed sentinel: 1 for a
# document that does not validate, 2 for one that is absent. Its value is
# rendered verbatim into a user-facing line, so a sentinel would be printed as
# if it were a gate name. ZENSU_BYPASS_UNREADABLE_TEXT and
# ZENSU_BYPASS_ABSENT_TEXT are the two user-facing sentences for those statuses
# and live HERE, beside the allowlist — never hand-copy either into a consumer.
# zensu_bypass_display owns the whole status ladder including a catch-all that
# fails CLOSED on an unknown status; every rendering site calls it rather than
# re-rolling the mapping. Its second argument decides only what an ABSENT
# document renders: `text` for a terminus that must disclose, the default
# `empty` for a clearing verb, where a clean ENOENT means nothing was recorded.

ZENSU_BYPASS_GATE_ALLOWLIST="ZENSU_TDD_GATE ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE ZENSU_SECRET_SCAN ZENSU_CHAIN ZENSU_TEST_WITNESS ZENSU_EDIT_LANDING_GATE ZENSU_REQUIREMENTS_GATE"
ZENSU_BYPASS_UNREADABLE_TEXT="UNREADABLE — workflow state could not be validated; this is NOT a clean ledger"
ZENSU_BYPASS_ABSENT_TEXT="UNREADABLE — no workflow document exists for this session; this is NOT a clean ledger"

_tdd_bypass_shape_ok() {
  case "${1:-}" in
    *[[:space:]]*|*$'\n'*|'') return 1 ;;
  esac
  case " $ZENSU_BYPASS_GATE_ALLOWLIST " in
    *" ${1:-} "*) return 0 ;;
  esac
  return 1
}

_tdd_write_bypass_critical() {
  local state_file="$1"
  local session_id="$2"
  local gate="$3"

  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" GATE="$gate" ALLOWLIST="$ZENSU_BYPASS_GATE_ALLOWLIST" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const allow = String(process.env.ALLOWLIST || "").split(" ").filter(Boolean);
      const gate = String(process.env.GATE || "").trim();
      core.mutateWorkflowState({
        projectRoot: process.env.PROJECT_ROOT,
        sessionId: process.env.SID,
        workflowState: "control",
        event: "bypass-recorded",
      }, (state) => {
        if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
        if (!Array.isArray(state.history)) state.history = [];
        state.bypasses = (Array.isArray(state.bypasses) ? state.bypasses : [])
          .filter((x, i, a) => allow.indexOf(x) >= 0 && a.indexOf(x) === i);
        if (allow.indexOf(gate) >= 0
            && state.bypasses.indexOf(gate) < 0) state.bypasses.push(gate);
        return state;
      });
    ' 2>/dev/null
}

tdd_add_bypass() {
  local supplied_session="${1:-}"
  local session_id
  local gate="${2:-}"
  _tdd_bypass_shape_ok "$gate" || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1

  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -L "$state_file" ] && return 1
  [ -L "$(dirname "$state_file")" ] && return 1
  case ", $(tdd_bypasses "$state_file")," in
    *", $gate,"*) return 0 ;;
  esac
  [ -f "$state_file" ] || return 1
  command -v node >/dev/null 2>&1 || return 1

  _tdd_write_bypass_critical "$state_file" "$session_id" "$gate"
}

tdd_record_bypass() {
  local session_id="${1:-}"
  local gate="${2:-}"
  [ -z "$session_id" ] && return 0
  if [ "$(tdd_session_active "$(tdd_state_file "$session_id")")" = "true" ]; then
    tdd_add_bypass "$session_id" "$gate" 2>/dev/null || true
  fi
  return 0
}

tdd_record_bypass_payload() {
  local payload="${1:-}"
  local gate="${2:-}"
  command -v node >/dev/null 2>&1 || return 0
  local sid
  sid="$(printf '%s' "$payload" | node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s || "{}");
        const sid = typeof j.session_id === "string" ? j.session_id : "";
        process.stdout.write(sid);
      } catch (_) { process.stdout.write(""); }
    });
  ' 2>/dev/null)"
  if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/zensu-session.sh" ]; then
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    sid="$(zensu_resolve_session_id "$sid")" || return 0
  fi
  tdd_record_bypass "$sid" "$gate"
}

tdd_clear_bypasses() {
  local supplied_session="${1:-}"
  local session_id
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")" || return 1
  [ -f "$state_file" ] || return 1
  [ -L "$state_file" ] && return 1
  [ -L "$(dirname "$state_file")" ] && return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_write_bypass_clear_critical "$state_file" "$session_id"
}

_tdd_write_bypass_clear_critical() {
  local state_file="$1"
  local session_id="$2"
  [ -f "$state_file" ] || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PROJECT_ROOT="$(_tdd_bound_project_root "$state_file" "$session_id")" SID="$session_id" node -e '
    const core = require(process.env.CONTROL_CORE);
    core.mutateWorkflowState({
      projectRoot: process.env.PROJECT_ROOT,
      sessionId: process.env.SID,
      workflowState: "control",
      event: "bypasses-cleared",
    }, (s) => { s.bypasses = []; return s; });
  ' 2>/dev/null
}

tdd_bypasses() {
  local state_file="${1:-}"
  local result status value
  result="$(_tdd_read_validated_state "$state_file" bypasses "$ZENSU_BYPASS_GATE_ALLOWLIST")"
  status="${result%%$'\n'*}"
  [ "$status" = "missing" ] && { echo ""; return 2; }
  [ "$status" = "valid" ] || { echo ""; return 1; }
  value="${result#*$'\n'}"
  [ "$value" = "$result" ] && value=""
  echo "$value"
}

zensu_bypass_display() {
  local state_file="${1:-}" absent_mode="${2:-empty}"
  local value rc=0
  value="$(tdd_bypasses "$state_file" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) printf '%s' "$value" ;;
    2) [ "$absent_mode" = "text" ] && printf '%s' "$ZENSU_BYPASS_ABSENT_TEXT" ;;
    *) printf '%s' "$ZENSU_BYPASS_UNREADABLE_TEXT" ;;
  esac
  return "$rc"
}

zensu_pending_review_file() {
  local project_root
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  project_root="$(zensu_resolve_project_dir)" || return 1
  echo "${project_root}/.zensu/state/pending-review.json"
}

# The claim sibling, exported so a consumer outside this module does not
# re-encode the suffix. A copy that drifts fails OPEN in the one place it
# matters: adoption RENAMES the marker onto the claim, so in the adopted state
# only the claim exists — and a reader looking for the wrong name would then see
# neither file and answer "no work" while another session's deferred review is
# live.
# The OPTIONAL argument is a pending-marker path the caller already holds.
# Without it this resolves the project root itself, which reaches
# `zensu_resolve_project_dir` and its own `node -e` -- a second full resolution
# for a value the caller almost always just computed. Every caller inside this
# module holds it, and so does the Autopilot fence, which runs this on a path
# reached at every turn end inside the project-wide lease.
#
# An EMPTY argument is not "omitted": it is a caller whose own resolution failed,
# and answering `.claim` for it would name a file in whatever directory the
# relative path resolved against. It refuses instead.
zensu_pending_review_claim_file() {
  local pending_file="${1:-}"
  if [ "$#" -ge 1 ]; then
    [ -n "$pending_file" ] || return 1
  else
    pending_file="$(zensu_pending_review_file)" || return 1
  fi
  echo "${pending_file}.claim"
}

_tdd_write_pending_review_critical() {
  local pf="$1"
  local files="$2"
  local summary="$3"
  local ts="$4"
  local native_pf
  native_pf="$(_tdd_native_project_path "$pf")" || return 1

  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" PENDING_FILE="$native_pf" FILES="$files" SUMMARY="$summary" TS="$ts" \
    node -e '
      const core = require(process.env.CONTROL_CORE);
      const files = (process.env.FILES || "").split(",").map(s => s.trim()).filter(Boolean);
      const o = { files, summary: process.env.SUMMARY || "" };
      if (process.env.TS) o.ts = process.env.TS;
      core.atomicWriteJson(process.env.PENDING_FILE, o);
    ' 2>/dev/null
}

tdd_write_pending_review() {
  local files="${1:-}"
  local summary="${2:-}"
  local pf
  pf="$(zensu_pending_review_file)"
  local dir
  dir="$(dirname "$pf")"
  _tdd_prepare_directory "$dir" || return 1
  _tdd_path_safe "$pf" regular-or-absent "$dir" || return 1
  command -v node >/dev/null 2>&1 || return 1
  local ts=""
  if [ "$(_zensu_log_style)" != "none" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  # Marker publication, adoption, queue cleanup, handoff acknowledgement, and
  # claim release share this one project-scoped mutex. A newer marker can queue
  # behind an adopted claim, but it can never race a rename or cleanup and be
  # mistaken for (or deleted as) the previous generation.
  _tdd_locked_run "$pf" _tdd_write_pending_review_critical \
    "$pf" "$files" "$summary" "$ts"
}

tdd_clear_pending_review() {
  local pf
  pf="$(zensu_pending_review_file)"
  local dir
  dir="$(dirname "$pf")"
  _tdd_prepare_directory "$dir" || return 1
  _tdd_path_safe "$pf" regular-or-absent "$dir" || return 1
  _tdd_locked_run "$pf" _tdd_clear_pending_review_critical "$pf"
}

_tdd_clear_pending_review_critical() {
  local pf="$1" dir
  dir="$(dirname "$pf")"
  _tdd_path_safe "$pf" regular-or-absent "$dir" || return 1
  # This command is intentionally queue-scoped.  Once a marker has been
  # adopted, only the owning session may release the retained claim via
  # tdd_release_pending_review_claim (reset, terminal reconciliation, or cap).
  rm -f -- "$pf" 2>/dev/null
}

_tdd_pending_file_stale() {
  local file="${1:-}" ttl_hours="${2:-}" native_file
  case "$ttl_hours" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ttl_hours" -gt 0 ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  native_file="$(_tdd_native_project_path "$file")" || return 1
  TTL="$ttl_hours" node -e '
    try {
      const fs = require("fs");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      let t = typeof j.ts === "string" ? Date.parse(j.ts) : NaN;
      if (!Number.isFinite(t)) t = fs.statSync(process.argv[1]).mtimeMs;
      const ttl = Number.parseInt(process.env.TTL, 10) * 3600 * 1000;
      process.exit(Number.isFinite(t) && Date.now() - t >= ttl ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' "$native_file" >/dev/null 2>&1
}

_tdd_read_pending_claim_metadata() {
  local claim_file="${1:-}" native_claim_file
  [ -f "$claim_file" ] && [ ! -L "$claim_file" ] || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const id = j && j.claimId;
      const owner = j && j.ownerSessionId;
      const validId = typeof id === "string" && /^dc_[A-Za-z0-9_-]+$/.test(id) && id.length <= 96;
      const validOwner = typeof owner === "string" && /^scv1_[a-f0-9]{64}$/.test(owner);
      if (!validId || !validOwner) process.exit(3);
      const ownerPid = Number.isInteger(j.ownerPid) && j.ownerPid > 0 ? j.ownerPid : 0;
      const identity = j.ownerProcessStartIdentity;
      if (identity !== null && (typeof identity !== "string" || !/^[a-z0-9._:-]{1,160}$/.test(identity))) process.exit(3);
      if (ownerPid === 0 || !("ownerProcessStartIdentity" in j)) process.exit(3);
      const emitted = j.handoffEmitted === true;
      process.stdout.write(`${id}\t${owner}\t${ownerPid}\t${emitted}`);
    } catch (_) { process.exit(3); }
  ' "$native_claim_file" 2>/dev/null
}

_tdd_assign_pending_claim_metadata() {
  local claim_file="$1" owner_session="$2" owner_pid="$3" claim_stale="${4:-false}" project_root
  local native_project_root native_claim_file
  project_root="$(zensu_resolve_project_dir)" || return 1
  native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CURRENT_CONTEXT="${ZENSU_SESSION_CONTEXT:-}" CURRENT_SESSION="$owner_session" \
    PROJECT_ROOT="$native_project_root" PLUGIN_ROOT="$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" \
    RUNTIME_DIGEST="${ZENSU_RUNTIME_DIGEST:-}" CLAIM_FILE="$native_claim_file" \
    OWNER_PID="$owner_pid" CLAIM_STALE="$claim_stale" LOG_STYLE="$(_zensu_log_style)" \
    node -e '
      try {
        const core = require(process.env.CONTROL_CORE);
        const claim = core.assignDeferredReviewClaim({
          currentContextFile: process.env.CURRENT_CONTEXT,
          currentSessionId: process.env.CURRENT_SESSION,
          projectRoot: process.env.PROJECT_ROOT,
          pluginRoot: process.env.PLUGIN_ROOT,
          runtimeDigest: process.env.RUNTIME_DIGEST,
          claimFile: process.env.CLAIM_FILE,
          ownerPid: Number(process.env.OWNER_PID),
          claimStale: process.env.CLAIM_STALE === "true",
          logStyle: process.env.LOG_STYLE,
        });
        process.stdout.write(`${claim.claimId}\t${claim.ownerSessionId}\t${claim.ownerPid}\tfalse`);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null
}

_tdd_reconcile_seeded_pending_claim() {
  local owner_session="$1" current_session="$2" claim_id="$3" claim_file="$4"
  local _owner_pid="$5" _handoff_emitted="$6" claim_stale="$7" project_root
  local native_project_root native_claim_file
  project_root="$(zensu_resolve_project_dir)" || return 1
  native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CURRENT_CONTEXT="${ZENSU_SESSION_CONTEXT:-}" CURRENT_SESSION="$current_session" \
    PROJECT_ROOT="$native_project_root" PLUGIN_ROOT="$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" \
    RUNTIME_DIGEST="${ZENSU_RUNTIME_DIGEST:-}" CLAIM_FILE="$native_claim_file" \
    CLAIM_ID="$claim_id" OWNER_SESSION="$owner_session" CLAIM_STALE="$claim_stale" \
    node -e '
      try {
        const core = require(process.env.CONTROL_CORE);
        const options = {
          currentContextFile: process.env.CURRENT_CONTEXT,
          currentSessionId: process.env.CURRENT_SESSION,
          projectRoot: process.env.PROJECT_ROOT,
          pluginRoot: process.env.PLUGIN_ROOT,
          runtimeDigest: process.env.RUNTIME_DIGEST,
          claimFile: process.env.CLAIM_FILE,
          claimStale: process.env.CLAIM_STALE === "true",
        };
        let inspection = core.inspectDeferredReviewOwner(options);
        if (
          inspection.claim.claimId !== process.env.CLAIM_ID
          || inspection.claim.ownerSessionId !== process.env.OWNER_SESSION
        ) throw new Error("claim changed during reconciliation");
        if (inspection.status === "transfer") {
          const prepared = core.prepareDeferredReviewTransfer(options);
          const expectedRevision = prepared.transfer.fromOwnerRevision;
          core.retireDeferredReviewOwner({ ...options, expectedRevision });
          core.markDeferredReviewOwnerRetired({ ...options, expectedRevision });
          inspection = core.inspectDeferredReviewOwner(options);
          if (inspection.status !== "owner-retired") throw new Error("transfer did not converge");
          process.stdout.write("transfer");
          process.exit(0);
        }
        if (inspection.status === "owner-retired") {
          // Recovery after the owner CAS but before the receipt acknowledgement:
          // advance the durable receipt before exposing the claim as assignable.
          if (inspection.claim.transfer.stage === "prepared") {
            const expectedRevision = inspection.claim.transfer.fromOwnerRevision;
            core.markDeferredReviewOwnerRetired({ ...options, expectedRevision });
            inspection = core.inspectDeferredReviewOwner(options);
            if (inspection.status !== "owner-retired"
                || inspection.claim.transfer.stage !== "owner-retired") {
              throw new Error("retired-owner receipt did not converge");
            }
          }
          process.stdout.write("transfer");
          process.exit(0);
        }
        if (inspection.status === "unseeded") {
          process.stdout.write("transfer");
          process.exit(0);
        }
        if (inspection.status === "cancelling") {
          const receipt = inspection.claim.cancellation;
          if (!receipt) throw new Error("cancelling claim has no receipt");
          core.cancelDeferredReviewClaim({
            ...options,
            mode: receipt.mode,
            resetBinding: receipt.resetBinding,
          });
          process.stdout.write("cancelled");
          process.exit(0);
        }
        if (inspection.status === "done" || inspection.status === "cancelled") {
          const terminal = core.clearTerminalDeferredReviewClaim(options);
          process.stdout.write(terminal.status);
          process.exit(0);
        }
        if (inspection.status === "current") {
          // Recovery after the target seed but before receipt finalization.
          // Finalization is idempotent and revalidates the exact active claim.
          if (inspection.claim.transfer) core.finalizeDeferredReviewTransfer(options);
          process.stdout.write("current");
          process.exit(0);
        }
        if (inspection.status === "owned") {
          process.stdout.write(inspection.status);
          process.exit(0);
        }
        throw new Error("unsupported reconciliation status");
      } catch (_) { process.exit(3); }
    ' 2>/dev/null
}

_tdd_adopt_pending_review_critical() {
  local pf="$1" claim_file="$2" session_id="$3" vanilla="$4" ttl_hours="$5" adopting_pid="$6"
  local dir source metadata claim_id owner_session prior_owner_pid handoff_emitted claim_stale reconcile_status
  claim_stale=false
  dir="$(dirname "$pf")"
  _tdd_path_safe "$pf" regular-or-absent "$dir" || return 1
  _tdd_path_safe "$claim_file" regular-or-absent "$dir" || return 1

  # A leftover claim is a crash-recovery record and takes precedence. A newer
  # pending marker remains queued for the following adoption.
  if [ -f "$claim_file" ]; then
    source="$claim_file"
  elif [ -f "$pf" ]; then
    source="$pf"
  else
    return 2
  fi

  if [ "$source" = "$pf" ] && _tdd_pending_file_stale "$source" "$ttl_hours"; then
    rm -f -- "$source" 2>/dev/null || return 1
    return 2
  fi

  if [ "$source" = "$pf" ]; then
    _tdd_atomic_replace_regular "$pf" "$claim_file" "$dir" || return 1
  fi

  metadata="$(_tdd_read_pending_claim_metadata "$claim_file" 2>/dev/null)" || metadata=""
  if [ -n "$metadata" ]; then
    IFS=$'\t' read -r claim_id owner_session prior_owner_pid handoff_emitted <<<"$metadata"
    claim_stale=false
    _tdd_pending_file_stale "$claim_file" "$ttl_hours" && claim_stale=true
    reconcile_status="$(_tdd_reconcile_seeded_pending_claim \
      "$owner_session" "$session_id" "$claim_id" "$claim_file" \
      "$prior_owner_pid" "$handoff_emitted" "$claim_stale" 2>/dev/null)" || return 1
    case "$reconcile_status" in
      current) return 0 ;;
      owned) return 2 ;;
      done|cancelled)
        # The completed ownership record is gone. If a newer marker queued
        # behind it, claim that marker in the same project-lock transaction so
        # this terminal Stop cannot silently release with work still pending.
        if [ -f "$pf" ]; then
          if _tdd_pending_file_stale "$pf" "$ttl_hours"; then
            rm -f -- "$pf" 2>/dev/null || return 1
            return 2
          fi
          _tdd_atomic_replace_regular "$pf" "$claim_file" "$dir" || return 1
          metadata=""
        else
          return 2
        fi
        ;;
      transfer) ;;
      *) return 1 ;;
    esac
  fi

  if [ -z "$metadata" ] && _tdd_pending_file_stale "$claim_file" "$ttl_hours"; then
    # A stale file with malformed or partial ownership metadata is evidence of
    # an interrupted or tampered generation, not permission to erase work.
    return 1
  fi

  metadata="$(_tdd_assign_pending_claim_metadata "$claim_file" "$session_id" "$adopting_pid" "$claim_stale")" || return 1
  IFS=$'\t' read -r claim_id owner_session prior_owner_pid handoff_emitted <<<"$metadata"

  if tdd_seed_deferred_review "$session_id" "$vanilla" "$claim_id" \
      && _tdd_finalize_pending_review_transfer "$claim_file" "$session_id"; then
    # Keep the claim as a recovery/ownership record until the Stop hook has
    # emitted its block handoff and, ultimately, the chain reaches chainDone.
    return 0
  fi

  # Assignment is already a durable ownership transition. Keep that record at
  # the claim path when the target seed/finalization fails: it may carry the
  # only owner-retirement receipt, and queue-scoped cleanup is deliberately
  # allowed to delete pending-review.json. The next Stop reconciles this claim
  # first; a concurrently queued marker remains independently retryable at pf.
  return 1
}

# Read-only contention probe used only after the durable Outer mutex could not
# be acquired. Core brackets both the foreign claim and owner state with stable
# descriptor-backed snapshots; this helper deliberately takes no pending or
# workflow lock and never repairs/transfers/cancels a claim.
tdd_pending_review_owned_by_other() {
  local supplied_session="${1:-}" ttl_hours="${2:-}" session_id pf dir claim_file
  local project_root native_project_root native_claim_file
  [ "$#" -eq 2 ] && [ -n "$supplied_session" ] || return 1
  case "$ttl_hours" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ttl_hours" -le 8760 ] 2>/dev/null || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  project_root="$(zensu_resolve_project_dir)" || return 1
  native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="$(zensu_pending_review_claim_file "$pf")" || return 1
  _tdd_path_safe "$claim_file" regular-or-absent "$dir" || return 1
  [ -f "$claim_file" ] && [ ! -L "$claim_file" ] || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CURRENT_CONTEXT="${ZENSU_SESSION_CONTEXT:-}" CURRENT_SESSION="$session_id" \
    PROJECT_ROOT="$native_project_root" PLUGIN_ROOT="$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" \
    RUNTIME_DIGEST="${ZENSU_RUNTIME_DIGEST:-}" CLAIM_FILE="$native_claim_file" \
    TTL_HOURS="$ttl_hours" node -e '
      try {
        const core = require(process.env.CONTROL_CORE);
        const owned = core.deferredReviewOwnedByOther({
          currentContextFile: process.env.CURRENT_CONTEXT,
          currentSessionId: process.env.CURRENT_SESSION,
          projectRoot: process.env.PROJECT_ROOT,
          pluginRoot: process.env.PLUGIN_ROOT,
          runtimeDigest: process.env.RUNTIME_DIGEST,
          claimFile: process.env.CLAIM_FILE,
          ttlHours: Number.parseInt(process.env.TTL_HOURS, 10),
        });
        process.exit(owned ? 0 : 1);
      } catch (_) { process.exit(3); }
    ' >/dev/null 2>&1
}

tdd_adopt_pending_review() {
  local supplied_session="${1:-}" session_id vanilla="${2:-false}" ttl_hours="${3:-0}" pf dir claim_file
  local owner_pid="${4:-$$}"
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] || return 1
  [ -n "$supplied_session" ] || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  case "$vanilla" in true|false) ;; *) return 1 ;; esac
  case "$ttl_hours" in ''|*[!0-9]*) ttl_hours=0 ;; esac
  owner_pid="$(_tdd_native_process_pid "$owner_pid")" || return 1
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="$(zensu_pending_review_claim_file "$pf")" || return 1
  _tdd_prepare_directory "$dir" || return 1
  _tdd_path_safe "$pf" regular-or-absent "$dir" || return 1
  _tdd_path_safe "$claim_file" regular-or-absent "$dir" || return 1
  _tdd_locked_run "$pf" _tdd_adopt_pending_review_critical \
    "$pf" "$claim_file" "$session_id" "$vanilla" "$ttl_hours" "$owner_pid"
}

_tdd_finalize_pending_review_transfer() {
  local claim_file="$1" current_session="$2" project_root native_project_root native_claim_file
  project_root="$(zensu_resolve_project_dir)" || return 1
  native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CURRENT_CONTEXT="${ZENSU_SESSION_CONTEXT:-}" CURRENT_SESSION="$current_session" \
    PROJECT_ROOT="$native_project_root" PLUGIN_ROOT="$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" \
    RUNTIME_DIGEST="${ZENSU_RUNTIME_DIGEST:-}" CLAIM_FILE="$native_claim_file" \
    node -e '
      try {
        const core = require(process.env.CONTROL_CORE);
        core.finalizeDeferredReviewTransfer({
          currentContextFile: process.env.CURRENT_CONTEXT,
          currentSessionId: process.env.CURRENT_SESSION,
          projectRoot: process.env.PROJECT_ROOT,
          pluginRoot: process.env.PLUGIN_ROOT,
          runtimeDigest: process.env.RUNTIME_DIGEST,
          claimFile: process.env.CLAIM_FILE,
        });
      } catch (_) { process.exit(3); }
    ' >/dev/null 2>&1
}

_tdd_mark_pending_review_handoff_critical() {
  local _pf="$1" claim_file="$2" session_id="$3" owner_pid="$4" project_root
  local native_project_root native_claim_file
  project_root="$(zensu_resolve_project_dir)" || return 1
  native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  # The pending-review lock held by the caller is the outer lock. Core then
  # acquires the claim lock followed by the one canonical target-state lock,
  # atomically validating the generation, finalizing any durable receipt, and
  # renewing the handoff lease. A normal TDD generation returns a no-op here.
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CURRENT_CONTEXT="${ZENSU_SESSION_CONTEXT:-}" CURRENT_SESSION="$session_id" \
    PROJECT_ROOT="$native_project_root" PLUGIN_ROOT="$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" \
    RUNTIME_DIGEST="${ZENSU_RUNTIME_DIGEST:-}" CLAIM_FILE="$native_claim_file" \
    OWNER_PID="$owner_pid" LOG_STYLE="$(_zensu_log_style)" node -e '
      try {
        const core = require(process.env.CONTROL_CORE);
        core.acknowledgeDeferredReviewHandoff({
          currentContextFile: process.env.CURRENT_CONTEXT,
          currentSessionId: process.env.CURRENT_SESSION,
          projectRoot: process.env.PROJECT_ROOT,
          pluginRoot: process.env.PLUGIN_ROOT,
          runtimeDigest: process.env.RUNTIME_DIGEST,
          claimFile: process.env.CLAIM_FILE,
          ownerPid: Number.parseInt(process.env.OWNER_PID, 10),
          logStyle: process.env.LOG_STYLE,
        });
      } catch (_) { process.exit(3); }
    ' >/dev/null 2>&1
}

tdd_mark_pending_review_handoff() {
  local supplied_session="${1:-}" owner_pid="${2:-$$}" session_id pf dir claim_file
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || return 1
  [ -n "$supplied_session" ] || return 1
  owner_pid="$(_tdd_native_process_pid "$owner_pid")" || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="$(zensu_pending_review_claim_file "$pf")" || return 1
  _tdd_path_safe "$claim_file" regular-or-absent "$dir" || return 1
  _tdd_locked_run "$pf" _tdd_mark_pending_review_handoff_critical \
    "$pf" "$claim_file" "$session_id" "$owner_pid"
}

_tdd_cancel_pending_review_claim_core() {
  local claim_file="$1" session_id="$2" requested_mode="$3" reset_binding_json="$4" project_root
  local native_project_root native_claim_file
  project_root="$(zensu_resolve_project_dir)" || return 1
  native_project_root="$(_tdd_native_project_path "$project_root")" || return 1
  native_claim_file="$(_tdd_native_project_path "$claim_file")" || return 1
  CONTROL_CORE="$_ZENSU_TDD_CONTROL_CORE" \
    CURRENT_CONTEXT="${ZENSU_SESSION_CONTEXT:-}" CURRENT_SESSION="$session_id" \
    PROJECT_ROOT="$native_project_root" PLUGIN_ROOT="$_ZENSU_TDD_NATIVE_PLUGIN_ROOT" \
    RUNTIME_DIGEST="${ZENSU_RUNTIME_DIGEST:-}" CLAIM_FILE="$native_claim_file" \
    REQUESTED_MODE="$requested_mode" RESET_BINDING_JSON="$reset_binding_json" node -e '
      try {
        const fs = require("node:fs");
        const path = require("node:path");
        const core = require(process.env.CONTROL_CORE);
        const options = {
          currentContextFile: process.env.CURRENT_CONTEXT,
          currentSessionId: process.env.CURRENT_SESSION,
          projectRoot: process.env.PROJECT_ROOT,
          pluginRoot: process.env.PLUGIN_ROOT,
          runtimeDigest: process.env.RUNTIME_DIGEST,
          claimFile: process.env.CLAIM_FILE,
          claimStale: false,
        };
        const currentStateFile = path.join(
          options.projectRoot,
          ".zensu",
          "state",
          `tdd-phase-${options.currentSessionId}.json`,
        );
        const readCurrentStateOrNull = () => {
          try { fs.lstatSync(currentStateFile); }
          catch (error) {
            if (error.code === "ENOENT") return null;
            throw error;
          }
          return core.readWorkflowState({
            projectRoot: options.projectRoot,
            sessionId: options.currentSessionId,
          });
        };
        let claimExists = true;
        try { fs.lstatSync(options.claimFile); }
        catch (error) {
          if (error.code !== "ENOENT") throw error;
          claimExists = false;
        }
        if (!claimExists) {
          const currentState = readCurrentStateOrNull();
          if (!currentState) {
            process.stdout.write("absent\tnone\tcurrent\t0");
            process.exit(0);
          }
          if (currentState.deferredReviewClaim !== "") {
            throw new Error("current deferred-review state has no claim artifact");
          }
          process.stdout.write(`absent\tnone\tcurrent\t${currentState.revision}`);
          process.exit(0);
        }
        const currentState = readCurrentStateOrNull();
        const resetBinding = JSON.parse(process.env.RESET_BINDING_JSON || "null");
        const sameResetBinding = (left, right) => {
          if (left === null || right === null) return left === right;
          if (
            !left || typeof left !== "object" || Array.isArray(left)
            || !right || typeof right !== "object" || Array.isArray(right)
          ) return false;
          return left.runId === right.runId
            && left.attempt === right.attempt
            && left.chainId === right.chainId;
        };
        const receiptSatisfiesResetRequest = (receipt) => (
          process.env.REQUESTED_MODE === "reset"
          && receipt.mode === "reset"
          && sameResetBinding(receipt.resetBinding, resetBinding)
        );
        let inspection = core.inspectDeferredReviewOwner(options);
        let claim = inspection.claim;
        let relation = claim.ownerSessionId === options.currentSessionId ? "current" : "foreign";
        if (claim.cancellation) {
          const receiptMatchesRequest = receiptSatisfiesResetRequest(claim.cancellation);
          let linearizedRevision;
          let outcomeStatus;
          if (inspection.status === "cancelled") {
            core.clearTerminalDeferredReviewClaim(options);
            linearizedRevision = currentState ? currentState.revision : 0;
            outcomeStatus = "cancelled";
          } else if (inspection.status === "cancelling") {
            const cancelled = core.cancelDeferredReviewClaim({
              ...options,
              mode: claim.cancellation.mode,
              resetBinding: claim.cancellation.resetBinding,
            });
            outcomeStatus = cancelled.status;
            linearizedRevision = outcomeStatus === "superseded"
              ? (currentState ? currentState.revision : 0)
              : cancelled.clearedOwnerRevision;
          } else {
            throw new Error("cancellation receipt is not recoverable");
          }
          const expectedRevision = relation === "current"
            ? linearizedRevision
            : (currentState ? currentState.revision : 0);
          const actualMode = receiptMatchesRequest
            && ["cancelled", "superseded"].includes(outcomeStatus)
            ? "reset-applied"
            : claim.cancellation.mode;
          process.stdout.write(`${outcomeStatus}\t${actualMode}\t${relation}\t${expectedRevision}`);
          process.exit(0);
        }
        if (relation === "foreign") {
          if (currentState && currentState.deferredReviewClaim !== "") {
            throw new Error("foreign claim conflicts with current owner state");
          }
          process.stdout.write(`absent\tnone\tforeign\t${currentState ? currentState.revision : 0}`);
          process.exit(0);
        }
        if (claim.transfer) {
          const exactTarget = relation === "current"
            && claim.ownerSessionId === options.currentSessionId
            && claim.transfer.stage === "owner-retired"
            && claim.transfer.toOwnerSessionId === options.currentSessionId;
          if (inspection.status === "current" && exactTarget) {
            core.finalizeDeferredReviewTransfer(options);
            inspection = core.inspectDeferredReviewOwner(options);
            claim = inspection.claim;
            relation = claim.ownerSessionId === options.currentSessionId ? "current" : "foreign";
            if (inspection.status !== "current" || relation !== "current" || claim.transfer) {
              throw new Error("finalized transfer did not converge to current ownership");
            }
          } else if (!(
            process.env.REQUESTED_MODE === "reset"
            && inspection.status === "unseeded"
            && exactTarget
          )) {
            throw new Error("transfer must be finalized before cancellation");
          }
        }
        if (
          process.env.REQUESTED_MODE === "reset"
          && relation === "current"
          && ["current", "done", "unseeded"].includes(inspection.status)
        ) {
          const result = core.cancelDeferredReviewClaim({
            ...options,
            mode: "reset",
            resetBinding,
          });
          const actualMode = ["cancelled", "superseded"].includes(result.status)
            ? "reset-applied"
            : result.mode;
          process.stdout.write(`${result.status}\t${actualMode}\t${relation}\t${result.clearedOwnerRevision}`);
          process.exit(0);
        }
        if (["done", "cancelled"].includes(inspection.status)) {
          core.clearTerminalDeferredReviewClaim(options);
          const expectedRevision = currentState ? currentState.revision : 0;
          process.stdout.write(`cancelled\tterminal\t${relation}\t${expectedRevision}`);
          process.exit(0);
        }
        const result = core.cancelDeferredReviewClaim({
          ...options,
          mode: process.env.REQUESTED_MODE,
          resetBinding,
        });
        const expectedRevision = relation === "current"
          ? result.clearedOwnerRevision
          : (currentState ? currentState.revision : 0);
        const actualMode = process.env.REQUESTED_MODE === "reset"
          && relation === "current"
          && ["cancelled", "superseded"].includes(result.status)
          ? "reset-applied"
          : result.mode;
        process.stdout.write(`${result.status}\t${actualMode}\t${relation}\t${expectedRevision}`);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null
}

_tdd_release_pending_review_claim_critical() {
  local _pf="$1" claim_file="$2" session_id="$3" result
  result="$(_tdd_cancel_pending_review_claim_core \
    "$claim_file" "$session_id" release-only null)" || return 1
  case "$result" in
    absent$'\t'*|cancelled$'\t'*|superseded$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

tdd_release_pending_review_claim() {
  local supplied_session="${1:-}" session_id pf dir claim_file
  [ -n "$supplied_session" ] || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="$(zensu_pending_review_claim_file "$pf")" || return 1
  _tdd_prepare_directory "$dir" || return 1
  _tdd_paths_safe "$pf" regular-or-absent "$claim_file" regular-or-absent || return 1
  _tdd_locked_run "$pf" _tdd_release_pending_review_claim_critical \
    "$pf" "$claim_file" "$session_id"
}

_tdd_reset_pending_review_claim_critical() {
  local _pf="$1" claim_file="$2" session_id="$3" run_id="$4" attempt="$5" chain_id="$6"
  local reset_binding_json result status actual_mode relation expected_revision state_file
  if [ -n "$run_id" ]; then
    reset_binding_json="$(RUN_ID="$run_id" ATTEMPT="$attempt" CHAIN_ID="$chain_id" node -e '
      process.stdout.write(JSON.stringify({
        runId: process.env.RUN_ID,
        attempt: Number(process.env.ATTEMPT),
        chainId: process.env.CHAIN_ID,
      }));
    ')" || return 1
  else
    reset_binding_json=null
  fi
  result="$(_tdd_cancel_pending_review_claim_core \
    "$claim_file" "$session_id" reset "$reset_binding_json")" || return 1
  IFS=$'\t' read -r status actual_mode relation expected_revision <<<"$result"
  case "$status" in absent|cancelled|superseded) ;; *) return 1 ;; esac
  # Only an exact mode-and-binding reset result is an idempotency receipt for
  # this request. A recovered receipt for another generation merely removes
  # that old claim; the initial current revision still needs the generic CAS.
  if { [ "$status" = cancelled ] || [ "$status" = superseded ]; } \
    && [ "$actual_mode" = reset-applied ] \
    && [ "$relation" = current ]; then return 0; fi
  [ "$expected_revision" = 0 ] && return 0
  case "$expected_revision" in ''|*[!0-9]*) return 1 ;; esac
  state_file="$(tdd_state_file "$session_id")" || return 1
  if [ -n "$run_id" ]; then
    _tdd_clear_autopilot_session_critical \
      "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id" "$expected_revision"
  else
    _tdd_clear_standalone_session_critical "$state_file" "$session_id" "$expected_revision"
  fi
}

tdd_reset_pending_review_claim() {
  local supplied_session="${1:-}" session_id run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}"
  local pf dir claim_file
  [ "$#" -eq 1 ] || [ "$#" -eq 4 ] || return 1
  [ -n "$supplied_session" ] || return 1
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  if [ -n "$run_id" ]; then
    _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
    _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
    _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  fi
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="$(zensu_pending_review_claim_file "$pf")" || return 1
  _tdd_prepare_directory "$dir" || return 1
  _tdd_paths_safe "$pf" regular-or-absent "$claim_file" regular-or-absent || return 1
  _tdd_locked_run "$pf" _tdd_reset_pending_review_claim_critical \
    "$pf" "$claim_file" "$session_id" "$run_id" "$attempt" "$chain_id"
}

tdd_pending_review_stale() {
  local ttl_hours="${1:-}"
  case "$ttl_hours" in ''|*[!0-9]*) echo "false"; return 0 ;; esac
  [ "$ttl_hours" -le 0 ] && { echo "false"; return 0; }
  local pf native_pf
  pf="$(zensu_pending_review_file)"
  [ -f "$pf" ] || { echo "false"; return 0; }
  [ -L "$pf" ] && { echo "false"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "false"; return 0; }
  native_pf="$(_tdd_native_project_path "$pf")" || { echo "false"; return 0; }
  local verdict
  verdict=$(TTL="$ttl_hours" node -e '
    try {
      const fs = require("fs");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const ts = j && j.ts;
      let t = (typeof ts === "string" && ts) ? Date.parse(ts) : NaN;
      if (!Number.isFinite(t)) {
        try { t = fs.statSync(process.argv[1]).mtimeMs; } catch (_) { console.log("false"); process.exit(0); }
      }
      if (!Number.isFinite(t)) { console.log("false"); process.exit(0); }
      const ttlMs = parseInt(process.env.TTL, 10) * 3600 * 1000;
      console.log((Date.now() - t) >= ttlMs ? "true" : "false");
    } catch (_) { console.log("false"); }
  ' "$native_pf" 2>/dev/null)
  [ "$verdict" = "true" ] && echo "true" || echo "false"
}

tdd_seed_deferred_review() {
  local supplied_session="${1:-}"
  local session_id
  local vanilla="${2:-false}"
  local deferred_claim="${3:-}"
  case "$vanilla" in true|false) ;; *) vanilla="false" ;; esac
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  session_id="$(zensu_resolve_session_id "$supplied_session")" || return 1
  # A deferred review is a fresh, already-implemented chain generation. Reuse
  # the atomic begin transaction so ticket/flags, round counter, and Stop budget
  # are reset together even when the previous generation already terminated.
  tdd_begin_session "$session_id" "$vanilla" true true "$deferred_claim"
}

# Git Bash serializes exported functions into the Windows process environment.
# This library is large enough to exceed CreateProcess' environment limit, so
# Windows callers source it explicitly instead of inheriting its functions.
case "${OSTYPE:-}" in
  msys*|cygwin*|mingw*|win32*) ;;
  *)
    # Export the module paths only after they were derived from, and
    # identity-checked against, the executing library above. Exported helpers
    # must never fall back to an inherited ZENSU_* module path.
    export _ZENSU_TDD_CONTROL_CORE _ZENSU_TDD_NATIVE_PLUGIN_ROOT _ZENSU_TDD_CHAIN_RECOVERY
    export -f _tdd_core_lock_keeper 2>/dev/null || true
    export -f _tdd_winpid_from_ps _tdd_is_msys_runtime _tdd_native_path _tdd_native_process_pid _tdd_context_binding tdd_activation_status tdd_state_file _tdd_bound_project_root _tdd_native_project_path _tdd_paths_safe _tdd_path_safe _tdd_state_storage_safe _tdd_prepare_directory _tdd_atomic_replace_regular tdd_is_test_path _tdd_locked_run tdd_write_phase _tdd_write_phase_critical _tdd_read_validated_state tdd_state_status tdd_phase tdd_step tdd_has_red_fail _tdd_write_flag_critical tdd_set_flag _tdd_increment_counter_critical tdd_increment_counter tdd_reset_review_budget _tdd_write_clear_critical tdd_clear_session _tdd_clear_standalone_session_critical tdd_clear_standalone_session _tdd_clear_autopilot_session_critical tdd_clear_autopilot_session _tdd_write_chain_reset_critical tdd_reset_chain_flags _tdd_begin_session_critical tdd_begin_session tdd_autopilot_context tdd_chain_snapshot _tdd_autopilot_link_id_shape_ok _tdd_autopilot_attempt_shape_ok _tdd_mark_impl_complete_bound_critical tdd_mark_impl_complete_bound _tdd_mark_impl_complete_standalone_critical tdd_mark_impl_complete_standalone _tdd_set_chain_outcome_critical tdd_set_chain_outcome _tdd_finish_autopilot_chain_critical tdd_finish_autopilot_chain _tdd_review_ticket_shape_ok _tdd_issue_review_ticket_critical tdd_issue_review_ticket _tdd_consume_review_ticket_critical tdd_consume_review_ticket_context tdd_consume_review_ticket _tdd_mark_autopilot_max_round_handoff_critical tdd_mark_autopilot_max_round_handoff _tdd_mark_review_converged_critical tdd_mark_review_converged _tdd_mark_unclaimed_review_critical tdd_mark_unclaimed_review tdd_claimed_review_ticket tdd_ensure_self_review_ticket tdd_increment_stop_budget tdd_rearm_review _tdd_rearm_autopilot_review_critical tdd_rearm_autopilot_review tdd_get_flag tdd_get_counter tdd_session_active tdd_vanilla_mode tdd_impl_complete tdd_chain_done tdd_code_review_done tdd_self_review_fixed zensu_workflow_active zensu_workflow_allows tdd_workflow_begin _tdd_write_workflow_begin_critical _tdd_bypass_shape_ok _tdd_write_bypass_critical tdd_add_bypass tdd_record_bypass tdd_record_bypass_payload tdd_bypasses zensu_bypass_display _tdd_write_bypass_clear_critical tdd_clear_bypasses zensu_pending_review_file _tdd_write_pending_review_critical tdd_write_pending_review tdd_clear_pending_review tdd_pending_review_owned_by_other tdd_adopt_pending_review tdd_mark_pending_review_handoff tdd_release_pending_review_claim tdd_pending_review_stale tdd_seed_deferred_review _tdd_chain_recovery_module_ok _tdd_chain_preflight tdd_chain_diagnostics _tdd_recover_chain_critical tdd_recover_chain 2>/dev/null || true
    export -f _tdd_cancel_pending_review_claim_core tdd_reset_pending_review_claim 2>/dev/null || true
    ;;
esac
