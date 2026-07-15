#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"

tdd_state_file() {
  local session_id="${1:-}"
  local sanitized="${session_id//[^A-Za-z0-9_-]/_}"
  if [ -z "$sanitized" ]; then
    if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/zensu-session.sh" ]; then
      source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
      sanitized="fallback_$(zensu_session_key)"
    else
      sanitized="fallback_${PPID}"
    fi
  fi
  local dir="${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  echo "${dir}/tdd-phase-${sanitized}.json"
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
  PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}" TEMP_ROOT="${TMPDIR:-/tmp}" HOME_ROOT="${HOME:-}" node -e '
      const fs = require("fs");
      const path = require("path");
      const within = (base, candidate) => {
        const rel = path.relative(base, candidate);
        return rel === "" || (rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
      };
      const trusted = [process.env.PROJECT_ROOT, process.env.TEMP_ROOT, process.env.HOME_ROOT]
        .filter(Boolean).map(value => path.resolve(value));
      const args = process.argv.slice(1);
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
    ' "$@" >/dev/null 2>&1
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
    "${state_file}.lock" regular-or-absent \
    "${state_file}.lockd" directory-or-absent
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
  local source_file="${1:-}" target_file="${2:-}"
  _tdd_paths_safe "$source_file" regular "$target_file" regular-or-absent || return 1
  SOURCE_FILE="$source_file" TARGET_FILE="$target_file" node -e '
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
  local ts="$6"

  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  STATE_FILE="$state_file" SID="$session_id" STEP="$step_id" PHASE="$phase" REASON="$reason" TS="$ts" \
    node -e '
      const fs = require("fs");
      const sf = process.env.STATE_FILE;
      let state = {};
      try {
        const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
        if (prev && typeof prev === "object" && !Array.isArray(prev)) state = prev;
      } catch (_) {}
      if (!state.session_id) state.session_id = process.env.SID;
      if (!Array.isArray(state.history)) state.history = [];
      const entry = { step: process.env.STEP, phase: process.env.PHASE };
      if (process.env.TS) entry.ts = process.env.TS;
      if (process.env.REASON) entry.reason = process.env.REASON;
      state.history.push(entry);
      state.step_id = process.env.STEP;
      state.phase = process.env.PHASE;
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

_tdd_locked_run() {
  local state_file="$1"
  shift

  local lock_file="${state_file}.lock"

  # Reject unsafe storage before creating either lock representation. The same
  # check runs again after acquisition so a path swap cannot reach the state
  # mutation hidden behind the mutex.
  _tdd_state_storage_safe "$state_file" || return 1

  if [ "${TDD_DISABLE_FLOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lock_file" 2>/dev/null || exit 1
      flock -x 9 2>/dev/null || exit 1
      _tdd_state_storage_safe "$state_file" || exit 1
      "$@"
    )
    return $?
  fi

  local lock_dir="${state_file}.lockd"
  local attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    local dead=0
    local mtime
    mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || stat -f %m "$lock_dir" 2>/dev/null || echo "")
    if [ -n "$mtime" ]; then
      local now
      now=$(date +%s 2>/dev/null || echo "")
      if [ -n "$now" ] && [ "$((now - mtime))" -gt 30 ]; then
        dead=1
      fi
    fi
    if [ "$dead" -eq 0 ] && [ -f "$lock_dir/owner" ]; then
      local owner_pid
      owner_pid=$(cat "$lock_dir/owner" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
        dead=1
      fi
    fi
    if [ "$dead" -eq 1 ]; then
      rm -rf "$lock_dir" 2>/dev/null
      continue
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 200 ]; then
      echo "[zensu-tdd-phase] lock acquisition failed for $state_file" >&2
      return 1
    fi
    sleep 0.01 2>/dev/null || sleep 1
  done
  echo "$$" > "$lock_dir/owner" 2>/dev/null || true
  if _tdd_state_storage_safe "$state_file"; then
    "$@"
  else
    false
  fi
  local rc=$?
  rm -rf "$lock_dir" 2>/dev/null || true
  return $rc
}

tdd_write_phase() {
  local session_id="${1:-unknown}"
  local step_id="${2:-}"
  local phase="${3:-}"
  local reason="${4:-}"

  local state_file
  state_file=$(tdd_state_file "$session_id")
  local state_dir
  state_dir=$(dirname "$state_file")
  _tdd_prepare_directory "$state_dir" || return 1

  local ts=""
  if [ "$(_zensu_log_style)" != "none" ]; then
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  command -v node >/dev/null 2>&1 || return 1

  _tdd_locked_run "$state_file" \
    _tdd_write_phase_critical "$state_file" "$session_id" "$step_id" "$phase" "$reason" "$ts"
}

# --- Chain-state flags (active / implComplete / chainDone) ----------------
# These live in the SAME per-session state file as the FSM phase. They drive
# main-thread hook activation (active), the Stop-hook review gate
# (implComplete), and chain termination (chainDone). All writes go through the
# shared mutex so a flag-write never clobbers a concurrent phase-write.

_tdd_write_flag_critical() {
  local state_file="$1"
  local session_id="$2"
  local key="$3"
  local val="$4"

  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  STATE_FILE="$state_file" SID="$session_id" KEY="$key" VAL="$val" \
    node -e '
      const fs = require("fs");
      const sf = process.env.STATE_FILE;
      let state = {};
      try {
        const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
        if (prev && typeof prev === "object" && !Array.isArray(prev)) state = prev;
      } catch (_) {}
      if (!state.session_id) state.session_id = process.env.SID;
      if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
      if (!Array.isArray(state.history)) state.history = [];
      state[process.env.KEY] = (process.env.VAL === "true");
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_set_flag() {
  local session_id="${1:-unknown}"
  local key="${2:-}"
  local val="${3:-true}"
  [ -z "$key" ] && return 1
  case "$val" in true|false) ;; *) val="true" ;; esac

  local state_file
  state_file=$(tdd_state_file "$session_id")
  _tdd_prepare_directory "$(dirname "$state_file")" || return 1
  command -v node >/dev/null 2>&1 || return 1

  _tdd_locked_run "$state_file" \
    _tdd_write_flag_critical "$state_file" "$session_id" "$key" "$val"
}

_tdd_write_clear_critical() {
  local state_file="$1"
  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi
  STATE_FILE="$state_file" node -e '
    const fs = require("fs");
    const sf = process.env.STATE_FILE;
    let s = {};
    try {
      const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
      if (prev && typeof prev === "object" && !Array.isArray(prev)) s = prev;
    } catch (_) {}
    s.active = false; s.implComplete = false; s.chainDone = false;
    s.codeReviewDone = false; s.selfReviewFixed = false; s.workflowActive = false;
    s.reviewTicket = ""; s.reviewTicketConsumed = true; s.reviewRound = 0;
    s.deferredReviewClaim = ""; s.stopBlockCount = 0;
    s.workflowTools = []; s.vanilla = false; s.bypasses = [];
    delete s.reviewRearm;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_clear_session() {
  local session_id="${1:-unknown}"
  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -f "$state_file" ] || return 0
  command -v node >/dev/null 2>&1 || return 1
  _tdd_locked_run "$state_file" _tdd_write_clear_critical "$state_file"
}

_tdd_clear_standalone_session_critical() {
  local state_file="$1" session_id="$2"
  STATE_FILE="$state_file" SID="$session_id" node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
      const linkKeys=[
        "autopilotRunId","autopilotAttempt","autopilotReturnStage","chainId","chainOutcome"
      ];
      const exact=s && typeof s==="object" && !Array.isArray(s)
        && s.session_id===process.env.SID
        && linkKeys.every(key=>!Object.prototype.hasOwnProperty.call(s,key));
      process.exit(exact?0:3);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null || return 1
  _tdd_write_clear_critical "$state_file"
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
  _tdd_locked_run "$state_file" _tdd_clear_standalone_session_critical \
    "$state_file" "$session_id"
}

_tdd_clear_autopilot_session_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4" chain_id="$5"
  STATE_FILE="$state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" node -e '
      try {
        const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
        const exact=s && typeof s==="object" && !Array.isArray(s)
          && s.session_id===process.env.SID && typeof s.active==="boolean"
          && s.autopilotRunId===process.env.RUN_ID
          && s.autopilotAttempt===Number(process.env.ATTEMPT)
          && s.chainId===process.env.CHAIN_ID;
        process.exit(exact?0:3);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null || return 1
  _tdd_write_clear_critical "$state_file"
}

tdd_clear_autopilot_session() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}" state_file
  [ "$#" -eq 4 ] && [ -n "$session_id" ] || return 1
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _tdd_clear_autopilot_session_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id"
}

_tdd_write_chain_reset_critical() {
  local state_file="$1"
  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi
  STATE_FILE="$state_file" node -e '
    const fs = require("fs");
    const sf = process.env.STATE_FILE;
    let s = {};
    try {
      const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
      if (prev && typeof prev === "object" && !Array.isArray(prev)) s = prev;
    } catch (_) {}
    s.implComplete = false; s.chainDone = false;
    s.codeReviewDone = false; s.selfReviewFixed = false;
    s.reviewTicket = ""; s.reviewTicketConsumed = true; s.reviewRound = 0;
    s.deferredReviewClaim = ""; s.stopBlockCount = 0;
    delete s.reviewRearm;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

# Clear only the review-chain completion flags (implComplete/chainDone/
# codeReviewDone/selfReviewFixed) in one atomic write, preserving active,
# vanilla, workflow and FSM keys. Called by --tdd-begin so the Stop backstop
# and the self-review fix-round latch re-arm for every chain in a session, not
# just the first.
tdd_reset_chain_flags() {
  local session_id="${1:-unknown}"
  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -f "$state_file" ] || return 0
  command -v node >/dev/null 2>&1 || return 1
  _tdd_locked_run "$state_file" _tdd_write_chain_reset_critical "$state_file"
}

_tdd_begin_session_critical() {
  local state_file="$1" session_id="$2" vanilla="$3" impl_complete="$4"
  local require_deferred_eligible="$5" deferred_claim="$6"
  local counter_file="$7" rounds_state_dir="$8" stopblocks_file="$9" state_dir="${10}"
  local autopilot_run_id="${11:-}" autopilot_attempt="${12:-}"
  local autopilot_return_stage="${13:-}" chain_id="${14:-}" tmp
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$counter_file" regular-or-absent "$rounds_state_dir" || return 1
  _tdd_path_safe "$stopblocks_file" regular-or-absent "$state_dir" || return 1
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  if ! STATE_FILE="$state_file" SID="$session_id" VANILLA="$vanilla" \
      IMPL_COMPLETE="$impl_complete" REQUIRE_DEFERRED_ELIGIBLE="$require_deferred_eligible" \
      DEFERRED_CLAIM="$deferred_claim" AUTOPILOT_RUN_ID="$autopilot_run_id" \
      AUTOPILOT_ATTEMPT="$autopilot_attempt" AUTOPILOT_RETURN_STAGE="$autopilot_return_stage" \
      CHAIN_ID="$chain_id" node -e '
    const fs = require("fs");
    let s = {};
    try {
      const prev = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      if (prev && typeof prev === "object" && !Array.isArray(prev)) s = prev;
    } catch (_) {}
    if (process.env.REQUIRE_DEFERRED_ELIGIBLE === "true") {
      const eligible = s.active !== true
        || (s.active === true && s.implComplete === true && s.chainDone === true);
      if (!eligible) process.exit(3);
    }
    s.session_id = process.env.SID;
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
      const attempt = Number.parseInt(process.env.AUTOPILOT_ATTEMPT, 10);
      s.autopilotRunId = process.env.AUTOPILOT_RUN_ID;
      s.autopilotAttempt = attempt;
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
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }

  # Keep budget reset in the same session-state critical section as the new
  # generation and fail closed if either reset cannot be completed. A reviewer
  # completion that claimed the old ticket must finish its counter write before
  # this lock holder can reset it; later completions see the cleared ticket.
  if ! rm -f -- "$counter_file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    echo "zensu-log --tdd-begin: rounds counter reset failed — session NOT activated" >&2
    return 1
  fi
  if ! rm -f -- "$stopblocks_file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    echo "zensu-log --tdd-begin: stop-block budget reset failed — session NOT activated" >&2
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$state_dir" \
    || { rm -f "$tmp"; return 1; }
}

# Atomically starts a new chain generation. In particular, the old review
# ticket and completion flags disappear in the same locked write that marks the
# new chain active, so a late Agent completion linearizes either before or
# after the new chain — it can never observe a hybrid state.
tdd_begin_session() {
  local session_id="${1:-}" vanilla="${2:-false}" impl_complete="${3:-false}"
  local require_deferred_eligible="${4:-false}" deferred_claim="${5:-}"
  local autopilot_run_id="${6:-}" autopilot_attempt="${7:-}"
  local autopilot_return_stage="${8:-}" chain_id="${9:-}" state_file state_dir
  local rounds_state_dir counter_file stopblocks_file
  [ -n "$session_id" ] || return 1
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
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  rounds_state_dir="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  counter_file="${rounds_state_dir}/rounds-${session_id}.json"
  stopblocks_file="${state_file}.stopblocks"
  if ! _tdd_prepare_directory "$state_dir" || ! _tdd_prepare_directory "$rounds_state_dir"; then
    echo "zensu-log --tdd-begin: unsafe session state path — session NOT activated" >&2
    return 1
  fi
  if ! _tdd_state_storage_safe "$state_file" \
      || ! _tdd_path_safe "$counter_file" regular-or-absent "$rounds_state_dir" \
      || ! _tdd_path_safe "$stopblocks_file" regular-or-absent "$state_dir"; then
    echo "zensu-log --tdd-begin: unsafe session budget state — session NOT activated" >&2
    return 1
  fi
  _tdd_locked_run "$state_file" \
    _tdd_begin_session_critical "$state_file" "$session_id" "$vanilla" "$impl_complete" \
      "$require_deferred_eligible" "$deferred_claim" \
      "$counter_file" "$rounds_state_dir" "$stopblocks_file" "$state_dir" \
      "$autopilot_run_id" "$autopilot_attempt" "$autopilot_return_stage" "$chain_id"
}

# Emit the exact outer-run linkage for this TDD generation as a compact JSON
# object. An empty object means the chain is standalone. Callers must treat an
# invalid/corrupt state as an error rather than guessing a run association.
tdd_autopilot_context() {
  local state_file="${1:-}"
  local expected_session="${2:-}"
  [ -n "$state_file" ] || return 1
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  STATE_FILE="$state_file" EXPECTED_SESSION="$expected_session" node -e '
    try {
      const s = JSON.parse(require("fs").readFileSync(process.env.STATE_FILE, "utf8"));
      if (!s || typeof s !== "object" || Array.isArray(s)) process.exit(3);
      const rootValid = typeof s.session_id === "string" && s.session_id.length > 0
        && typeof s.active === "boolean" && typeof s.implComplete === "boolean"
        && typeof s.chainDone === "boolean"
        && (!process.env.EXPECTED_SESSION || s.session_id === process.env.EXPECTED_SESSION);
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
        sessionId:s.session_id,
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
  _tdd_path_safe "$state_file" regular-or-absent "$(dirname "$state_file")" || return 2
  [ -e "$state_file" ] || return 1
  STATE_FILE="$state_file" EXPECTED_SESSION="$expected_session" node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
      const natural=v=>Number.isSafeInteger(v)&&v>=0;
      const linkId=v=>typeof v==="string"&&v.length>0&&v.length<=128&&/^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(v);
      const root=s&&typeof s==="object"&&!Array.isArray(s)
        &&s.session_id===process.env.EXPECTED_SESSION&&typeof s.phase==="string"
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
      process.stdout.write(JSON.stringify({sessionId:s.session_id,active:s.active,
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
  local tmp node_rc
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  STATE_FILE="$state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" node -e '
      const fs=require("fs");
      let s;
      try { s=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8")); }
      catch (_) { process.exit(3); }
      const exact=s && typeof s==="object" && !Array.isArray(s)
        && s.session_id===process.env.SID && s.active===true
        && typeof s.implComplete==="boolean" && s.chainDone===false && s.chainOutcome===""
        && s.autopilotRunId===process.env.RUN_ID
        && s.autopilotAttempt===Number(process.env.ATTEMPT)
        && s.chainId===process.env.CHAIN_ID;
      if(!exact)process.exit(3);
      if(s.implComplete===true)process.exit(10);
      s.implComplete=true;
      fs.writeFileSync(process.argv[1],JSON.stringify(s,null,2));
    ' "$tmp" 2>/dev/null
  node_rc=$?
  if [ "$node_rc" -eq 10 ]; then rm -f "$tmp" 2>/dev/null; return 0; fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp" 2>/dev/null; return 1; fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_mark_impl_complete_bound() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}" state_file
  [ "$#" -eq 4 ] && [ -n "$session_id" ] || return 1
  _tdd_autopilot_link_id_shape_ok "$run_id" || return 1
  _tdd_autopilot_attempt_shape_ok "$attempt" || return 1
  _tdd_autopilot_link_id_shape_ok "$chain_id" || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _tdd_mark_impl_complete_bound_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id"
}

# Standalone completion is also a generation CAS. A caller may have observed
# an unbound session immediately before Autopilot replaced the same Inner file;
# therefore linkage absence is proven again while holding the Inner mutex.
_tdd_mark_impl_complete_standalone_critical() {
  local state_file="$1" session_id="$2" tmp node_rc
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  STATE_FILE="$state_file" SID="$session_id" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const linkKeys = [
      "autopilotRunId", "autopilotAttempt", "autopilotReturnStage", "chainId", "chainOutcome"
    ];
    const standalone = s && typeof s === "object" && !Array.isArray(s)
      && linkKeys.every(key => !Object.prototype.hasOwnProperty.call(s, key));
    const exact = standalone && s.session_id === process.env.SID
      && s.active === true && typeof s.implComplete === "boolean"
      && s.chainDone === false;
    if (!exact) process.exit(3);
    if (s.implComplete === true) process.exit(10);
    s.implComplete = true;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null
  node_rc=$?
  if [ "$node_rc" -eq 10 ]; then rm -f "$tmp" 2>/dev/null; return 0; fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp" 2>/dev/null; return 1; fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_mark_impl_complete_standalone() {
  local session_id="${1:-}" state_file
  [ "$#" -eq 1 ] && [ -n "$session_id" ] || return 1
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _tdd_mark_impl_complete_standalone_critical \
    "$state_file" "$session_id"
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
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  STATE_FILE="$state_file" SID="$session_id" OUTCOME="$outcome" RUN_ID="$run_id" \
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
        && s.session_id === process.env.SID
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
    ' "$tmp" 2>/dev/null
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
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  STATE_FILE="$state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
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
        && s.session_id === process.env.SID
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
    ' "$tmp" 2>/dev/null
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
  local state_file="$1" session_id="$2" ticket="$3" tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1

  if ! STATE_FILE="$state_file" SID="$session_id" TICKET="$ticket" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const markerKeys = [
      "attempt", "chainId", "consumedTicketSha256", "retire", "runId", "schemaVersion", "status"
    ];
    const marker = s && s.reviewRearm;
    const markerValid = marker === undefined || (marker && typeof marker === "object"
      && !Array.isArray(marker)
      && Object.keys(marker).sort().length === markerKeys.length
      && Object.keys(marker).sort().every((key, index) => key === markerKeys[index])
      && marker.schemaVersion === 1 && marker.status === "pending"
      && typeof marker.runId === "string" && marker.runId === s.autopilotRunId
      && marker.attempt === s.autopilotAttempt
      && typeof marker.chainId === "string" && marker.chainId === s.chainId
      && typeof marker.consumedTicketSha256 === "string"
      && /^[a-f0-9]{64}$/.test(marker.consumedTicketSha256)
      && marker.retire === false);
    const valid = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id === process.env.SID
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
  ' "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

tdd_issue_review_ticket() {
  local session_id="${1:-}" state_file state_dir ticket
  [ -n "$session_id" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
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
  local state_file="$1" session_id="$2" ticket="$3" counter_file="$4"
  local state_dir counter_dir state_tmp counter_tmp next_file
  state_dir="$(dirname "$state_file")"
  counter_dir="$(dirname "$counter_file")"
  _tdd_paths_safe "$counter_dir" directory "$counter_file" regular-or-absent || return 1
  state_tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  counter_tmp="$(mktemp "${counter_file}.XXXXXX" 2>/dev/null)" || {
    rm -f "$state_tmp" 2>/dev/null
    return 1
  }
  next_file="$(mktemp "${state_file}.next.XXXXXX" 2>/dev/null)" || {
    rm -f "$state_tmp" "$counter_tmp" 2>/dev/null
    return 1
  }

  if ! STATE_FILE="$state_file" COUNTER_FILE="$counter_file" SID="$session_id" TICKET="$ticket" \
    LOG_STYLE="$(_zensu_log_style)" node -e '
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
      && s.session_id === process.env.SID
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

    // The ticket-bound chain state is authoritative. The public rounds file is
    // only a derived compatibility view, so a missing/corrupt/blocked counter
    // leaf can never reset the review budget to round 1.
    const next = s.reviewRound + 1;
    s.reviewTicketConsumed = true;
    s.reviewRound = next;
    const counter = {count: next};
    if (process.env.LOG_STYLE !== "none") counter.ts = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    fs.writeFileSync(process.argv[2], JSON.stringify(counter) + "\n");
    fs.writeFileSync(process.argv[3], JSON.stringify({next, autopilot}));
  ' "$state_tmp" "$counter_tmp" "$next_file" 2>/dev/null; then
    rm -f "$state_tmp" "$counter_tmp" "$next_file" 2>/dev/null
    return 1
  fi

  if [ ! -s "$state_tmp" ] || [ ! -s "$counter_tmp" ] || [ ! -s "$next_file" ]; then
    rm -f "$state_tmp" "$counter_tmp" "$next_file" 2>/dev/null
    return 1
  fi

  # Both renames happen while holding the per-session mutex. The state claim is
  # authoritative; the rounds file remains the public/resettable budget view.
  _tdd_atomic_replace_regular "$state_tmp" "$state_file" "$state_dir" || {
    rm -f "$state_tmp" "$counter_tmp" "$next_file" 2>/dev/null
    return 1
  }
  if ! _tdd_atomic_replace_regular "$counter_tmp" "$counter_file" "$counter_dir"; then
    rm -f "$counter_tmp" 2>/dev/null
    echo "zensu post-review hook: failed to persist counter for session ${session_id}" >&2
  fi
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
  [ -n "$counter_file" ] || return 1
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
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  STATE_FILE="$state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
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
        && s.session_id === process.env.SID
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
    ' "$tmp" 2>/dev/null
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
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1

  if ! STATE_FILE="$state_file" SID="$session_id" TICKET="$ticket" KEY="$key" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const key = process.env.KEY;
    const validKey = key === "codeReviewDone" || key === "chainDone" || key === "selfReviewFixed";
    const valid = validKey
      && s && typeof s === "object" && !Array.isArray(s)
      && s.session_id === process.env.SID
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
  ' "$tmp" 2>/dev/null; then
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
  local state_file="$1" session_id="$2" key="$3" tmp
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  if ! STATE_FILE="$state_file" SID="$session_id" KEY="$key" node -e '
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
      && s.session_id === process.env.SID
      && s.active === true && s.implComplete === true && s.chainDone === false
      && typeof s.codeReviewDone === "boolean" && typeof s.selfReviewFixed === "boolean"
      && s.reviewTicket === "" && s.reviewTicketConsumed === true && s.reviewRound === 0;
    if (!valid) process.exit(3);
    if (key === "codeReviewDone" && s.codeReviewDone !== false) process.exit(3);
    if (key === "selfReviewFixed" && (s.codeReviewDone !== true || s.selfReviewFixed !== false)) process.exit(3);
    s[key] = true;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null; then
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
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  if ! STATE_FILE="$state_file" SID="$session_id" CANDIDATE="$candidate" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const base = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id === process.env.SID && s.active === true && s.implComplete === true
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
  ' "$tmp" "$result_file" 2>/dev/null; then
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
  local state_file="$1" session_id="$2" budget_file="$3" result_file="$4"
  local expected_run="${5:-}" expected_attempt="${6:-}" expected_chain="${7:-}"
  local expected_return_stage="${8:-}"
  local state_dir budget_dir state_tmp budget_tmp
  state_dir="$(dirname "$state_file")"
  budget_dir="$(dirname "$budget_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$budget_file" regular-or-absent "$budget_dir" || return 1
  state_tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  budget_tmp="$(mktemp "${budget_file}.XXXXXX" 2>/dev/null)" || {
    rm -f "$state_tmp" 2>/dev/null
    return 1
  }
  if ! STATE_FILE="$state_file" BUDGET_FILE="$budget_file" SID="$session_id" \
      EXPECTED_RUN="$expected_run" EXPECTED_ATTEMPT="$expected_attempt" \
      EXPECTED_CHAIN="$expected_chain" EXPECTED_RETURN_STAGE="$expected_return_stage" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    if (!s || typeof s !== "object" || Array.isArray(s) || s.session_id !== process.env.SID
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
    let current = Number.isInteger(s.stopBlockCount) && s.stopBlockCount >= 0 ? s.stopBlockCount : 0;
    try {
      const bytes = fs.readFileSync(process.env.BUDGET_FILE);
      if (bytes.length > current) current = bytes.length;
    } catch (_) {}
    if (current > 10000) process.exit(3);
    const next = current + 1;
    s.stopBlockCount = next;
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    fs.writeFileSync(process.argv[2], "x".repeat(next));
    fs.writeFileSync(process.argv[3], String(next));
  ' "$state_tmp" "$budget_tmp" "$result_file" 2>/dev/null; then
    rm -f "$state_tmp" "$budget_tmp" "$result_file" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$state_tmp" "$state_file" "$state_dir" || {
    rm -f "$state_tmp" "$budget_tmp" "$result_file" 2>/dev/null
    return 1
  }
  if ! _tdd_atomic_replace_regular "$budget_tmp" "$budget_file" "$budget_dir"; then
    rm -f "$budget_tmp" 2>/dev/null
    echo "zensu chain-enforcer: failed to persist derived Stop budget for ${session_id}" >&2
  fi
}

tdd_increment_stop_budget() {
  local session_id="${1:-}" state_file state_dir budget_file result_file
  [ -n "$session_id" ] || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  budget_file="${state_file}.stopblocks"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_path_safe "$budget_file" regular-or-absent "$state_dir" || return 1
  result_file="$(mktemp "${state_file}.stop-count.XXXXXX" 2>/dev/null)" || return 1
  if _tdd_locked_run "$state_file" _tdd_increment_stop_budget_critical \
      "$state_file" "$session_id" "$budget_file" "$result_file"; then
    cat "$result_file"
    rm -f "$result_file" 2>/dev/null
    return 0
  fi
  rm -f "$result_file" 2>/dev/null
  return 1
}

_tdd_rearm_review_critical() {
  local state_file="$1" session_id="$2" ticket="$3" counter_file="$4" stopblocks_file="$5"
  local state_dir counter_dir tmp
  state_dir="$(dirname "$state_file")"
  counter_dir="$(dirname "$counter_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$counter_file" regular-or-absent "$counter_dir" || return 1
  _tdd_path_safe "$stopblocks_file" regular-or-absent "$state_dir" || return 1
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  if ! STATE_FILE="$state_file" SID="$session_id" TICKET="$ticket" node -e '
    const fs = require("fs");
    let s;
    try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
    catch (_) { process.exit(3); }
    const linkKeys = [
      "autopilotRunId", "autopilotAttempt", "autopilotReturnStage", "chainId", "chainOutcome"
    ];
    const fullyStandalone = s && linkKeys.every(key => !Object.prototype.hasOwnProperty.call(s, key));
    const valid = s && typeof s === "object" && !Array.isArray(s)
      && s.session_id === process.env.SID && s.active === true && s.implComplete === true
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
  ' "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  rm -f -- "$counter_file" "$stopblocks_file" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$state_dir" \
    || { rm -f "$tmp"; return 1; }
}

tdd_rearm_review() {
  local session_id="${1:-}" ticket="${2:-}" state_file state_dir rounds_dir counter_file stopblocks_file
  [ -n "$session_id" ] || return 1
  _tdd_review_ticket_shape_ok "$ticket" || return 1
  state_file="$(tdd_state_file "$session_id")"
  state_dir="$(dirname "$state_file")"
  rounds_dir="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  counter_file="${rounds_dir}/rounds-${session_id}.json"
  stopblocks_file="${state_file}.stopblocks"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_path_safe "$rounds_dir" directory "$rounds_dir" || return 1
  _tdd_path_safe "$counter_file" regular-or-absent "$rounds_dir" || return 1
  _tdd_path_safe "$stopblocks_file" regular-or-absent "$state_dir" || return 1
  _tdd_locked_run "$state_file" _tdd_rearm_review_critical \
    "$state_file" "$session_id" "$ticket" "$counter_file" "$stopblocks_file"
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
  local chain_id="$5" ticket="$6" retire="$7" counter_file="$8"
  local stopblocks_file="$9" state_dir counter_dir tmp node_rc
  state_dir="$(dirname "$state_file")"
  counter_dir="$(dirname "$counter_file")"
  _tdd_state_storage_safe "$state_file" || return 1
  _tdd_path_safe "$counter_file" regular-or-absent "$counter_dir" || return 1
  _tdd_path_safe "$stopblocks_file" regular-or-absent "$state_dir" || return 1
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1

  STATE_FILE="$state_file" SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" TICKET="$ticket" RETIRE="$retire" node -e '
      const fs = require("fs");
      const crypto = require("crypto");
      let s;
      try { s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8")); }
      catch (_) { process.exit(3); }

      const linkId = value => typeof value === "string" && value.length > 0 && value.length <= 128
        && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
      const returnStages = new Set(["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]);
      const markerKeys = [
        "attempt", "chainId", "consumedTicketSha256", "retire", "runId", "schemaVersion", "status"
      ];
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
        && s.session_id === process.env.SID
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
    ' "$tmp" 2>/dev/null
  node_rc=$?

  if [ "$node_rc" -eq 10 ]; then
    rm -f "$tmp" 2>/dev/null
    rm -f -- "$counter_file" "$stopblocks_file" 2>/dev/null || return 1
    return 0
  fi
  if [ "$node_rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  # Derived budgets are removed under the same per-session lock before the
  # receipt becomes the authoritative commit record. A crash before rename is
  # retried from the still-valid old ticket; a crash after rename follows the
  # exact receipt path above.
  rm -f -- "$counter_file" "$stopblocks_file" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$state_dir" \
    || { rm -f "$tmp"; return 1; }
}

tdd_rearm_autopilot_review() {
  local session_id="${1:-}" run_id="${2:-}" attempt="${3:-}" chain_id="${4:-}"
  local ticket="${5:-}" retire="${6:-false}" state_file state_dir rounds_dir
  local counter_file stopblocks_file
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
  rounds_dir="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  counter_file="${rounds_dir}/rounds-${session_id}.json"
  stopblocks_file="${state_file}.stopblocks"
  _tdd_path_safe "$state_file" regular "$state_dir" || return 1
  _tdd_path_safe "$rounds_dir" directory "$rounds_dir" || return 1
  _tdd_path_safe "$counter_file" regular-or-absent "$rounds_dir" || return 1
  _tdd_path_safe "$stopblocks_file" regular-or-absent "$state_dir" || return 1
  _tdd_locked_run "$state_file" _tdd_rearm_autopilot_review_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$chain_id" "$ticket" \
    "$retire" "$counter_file" "$stopblocks_file"
}

_tdd_write_workflow_begin_critical() {
  local state_file="$1"
  local session_id="$2"
  local tools="$3"

  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  STATE_FILE="$state_file" SID="$session_id" TOOLS="$tools" \
    node -e '
      const fs = require("fs");
      const sf = process.env.STATE_FILE;
      let state = {};
      try {
        const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
        if (prev && typeof prev === "object" && !Array.isArray(prev)) state = prev;
      } catch (_) {}
      if (!state.session_id) state.session_id = process.env.SID;
      if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
      if (!Array.isArray(state.history)) state.history = [];
      state.workflowActive = true;
      state.workflowTools = (process.env.TOOLS || "").split(",").map(s => s.trim()).filter(Boolean);
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_workflow_begin() {
  local session_id="${1:-unknown}"
  local tools="${2:-}"
  local state_file
  state_file=$(tdd_state_file "$session_id")
  _tdd_prepare_directory "$(dirname "$state_file")" || return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_locked_run "$state_file" \
    _tdd_write_workflow_begin_critical "$state_file" "$session_id" "$tools"
}

tdd_get_flag() {
  local state_file="${1:-}"
  local key="${2:-}"
  if [ -z "$state_file" ] || [ ! -f "$state_file" ] || [ -z "$key" ]; then
    echo "false"; return 0
  fi
  command -v node >/dev/null 2>&1 || { echo "false"; return 0; }
  local val
  val=$(KEY="$key" node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      console.log(j[process.env.KEY] === true ? "true" : "false");
    } catch (_) { console.log("false"); }
  ' "$state_file" 2>/dev/null)
  [ "$val" = "true" ] && echo "true" || echo "false"
}

tdd_session_active()    { tdd_get_flag "${1:-}" active; }
tdd_vanilla_mode()      { tdd_get_flag "${1:-}" vanilla; }
tdd_impl_complete()     { tdd_get_flag "${1:-}" implComplete; }
tdd_chain_done()        { tdd_get_flag "${1:-}" chainDone; }
tdd_code_review_done()  { tdd_get_flag "${1:-}" codeReviewDone; }
tdd_self_review_fixed() { tdd_get_flag "${1:-}" selfReviewFixed; }
zensu_workflow_active()  { tdd_get_flag "${1:-}" workflowActive; }

tdd_claimed_review_ticket() {
  local state_file="${1:-}"
  [ -n "$state_file" ] && _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" \
    || return 1
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
  ' "$state_file" 2>/dev/null
}

zensu_workflow_allows() {
  local sf="${1:-}" tool="${2:-}"
  [ -n "$tool" ] || { echo "false"; return 0; }
  [ "$(zensu_workflow_active "$sf")" = "true" ] || { echo "false"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "false"; return 0; }
  local verdict
  verdict=$(TOOL="$tool" node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const tools = Array.isArray(j.workflowTools) ? j.workflowTools : [];
      console.log(tools.indexOf(process.env.TOOL) >= 0 ? "true" : "false");
    } catch (_) { console.log("false"); }
  ' "$sf" 2>/dev/null)
  [ "$verdict" = "true" ] && echo "true" || echo "false"
}

tdd_phase() {
  local state_file="${1:-}"
  if [ -z "$state_file" ] || [ ! -f "$state_file" ]; then
    echo "UNINITIALIZED"
    return 0
  fi
  command -v node >/dev/null 2>&1 || { echo "UNINITIALIZED"; return 0; }
  local val
  val=$(node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      console.log(typeof j.phase === "string" && j.phase ? j.phase : "UNINITIALIZED");
    } catch (_) { console.log("UNINITIALIZED"); }
  ' "$state_file" 2>/dev/null)
  [ -z "$val" ] && val="UNINITIALIZED"
  echo "$val"
}

tdd_step() {
  local state_file="${1:-}"
  if [ -z "$state_file" ] || [ ! -f "$state_file" ]; then
    echo ""
    return 0
  fi
  command -v node >/dev/null 2>&1 || { echo ""; return 0; }
  local val
  val=$(node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      console.log(typeof j.step_id === "string" ? j.step_id : "");
    } catch (_) { console.log(""); }
  ' "$state_file" 2>/dev/null)
  echo "$val"
}

tdd_has_red_fail() {
  local state_file="${1:-}"
  local step="${2:-}"
  if [ -z "$state_file" ] || [ ! -f "$state_file" ] || [ -z "$step" ]; then
    echo "false"
    return 0
  fi
  command -v node >/dev/null 2>&1 || { echo "false"; return 0; }
  local val
  val=$(STEP_ARG="$step" node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const step = process.env.STEP_ARG;
      const hit = Array.isArray(j.history) && j.history.some(h => h && h.step === step && h.phase === "RED_FAIL");
      console.log(hit ? "true" : "false");
    } catch (_) { console.log("false"); }
  ' "$state_file" 2>/dev/null)
  [ -z "$val" ] && val="false"
  echo "$val"
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

ZENSU_BYPASS_GATE_ALLOWLIST="ZENSU_TDD_GATE ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE ZENSU_SECRET_SCAN ZENSU_CHAIN ZENSU_TEST_WITNESS"

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

  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  STATE_FILE="$state_file" SID="$session_id" GATE="$gate" ALLOWLIST="$ZENSU_BYPASS_GATE_ALLOWLIST" \
    node -e '
      const fs = require("fs");
      const sf = process.env.STATE_FILE;
      let state = {};
      try {
        const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
        if (prev && typeof prev === "object" && !Array.isArray(prev)) state = prev;
      } catch (_) {}
      if (!state.session_id) state.session_id = process.env.SID;
      if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
      if (!Array.isArray(state.history)) state.history = [];
      const allow = String(process.env.ALLOWLIST || "").split(" ").filter(Boolean);
      state.bypasses = (Array.isArray(state.bypasses) ? state.bypasses : [])
        .filter((x, i, a) => allow.indexOf(x) >= 0 && a.indexOf(x) === i);
      const gate = String(process.env.GATE || "").trim();
      if (allow.indexOf(gate) >= 0
          && state.bypasses.indexOf(gate) < 0) state.bypasses.push(gate);
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_add_bypass() {
  local session_id="${1:-unknown}"
  local gate="${2:-}"
  _tdd_bypass_shape_ok "$gate" || return 1

  local state_file
  state_file=$(tdd_state_file "$session_id")
  _tdd_prepare_directory "$(dirname "$state_file")" || return 1
  _tdd_path_safe "$state_file" regular-or-absent "$(dirname "$state_file")" || return 1
  case ", $(tdd_bypasses "$state_file")," in
    *", $gate,"*) return 0 ;;
  esac
  command -v node >/dev/null 2>&1 || return 1

  _tdd_locked_run "$state_file" \
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
  local fields sid tp
  fields="$(printf '%s' "$payload" | node -e '
    let s = "";
    process.stdin.on("data", c => s += c);
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s || "{}");
        const sid = typeof j.session_id === "string" ? j.session_id : "";
        const tp = typeof j.transcript_path === "string" ? j.transcript_path : "";
        process.stdout.write(sid + "\n" + tp);
      } catch (_) { process.stdout.write("\n"); }
    });
  ' 2>/dev/null)"
  sid="${fields%%$'\n'*}"
  tp="${fields#*$'\n'}"
  [ "$tp" = "$fields" ] && tp=""
  [ -n "$sid" ] && tp=""
  if [ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib/zensu-session.sh" ]; then
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
    sid="$(ZENSU_TRANSCRIPT_PATH="$tp" zensu_resolve_session_id "$sid")"
  fi
  tdd_record_bypass "$sid" "$gate"
}

tdd_clear_bypasses() {
  local session_id="${1:-unknown}"
  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -f "$state_file" ] || return 0
  [ -L "$state_file" ] && return 1
  [ -L "$(dirname "$state_file")" ] && return 1
  command -v node >/dev/null 2>&1 || return 1
  _tdd_locked_run "$state_file" _tdd_write_bypass_clear_critical "$state_file"
}

_tdd_write_bypass_clear_critical() {
  local state_file="$1"
  [ -f "$state_file" ] || return 0
  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi
  STATE_FILE="$state_file" node -e '
    const fs = require("fs");
    let s = {};
    try {
      const prev = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      if (prev && typeof prev === "object" && !Array.isArray(prev)) s = prev;
    } catch (_) {}
    s.bypasses = [];
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_bypasses() {
  local state_file="${1:-}"
  if [ -z "$state_file" ] || [ ! -f "$state_file" ]; then
    echo ""
    return 0
  fi
  command -v node >/dev/null 2>&1 || { echo ""; return 0; }
  local val
  val=$(ALLOWLIST="$ZENSU_BYPASS_GATE_ALLOWLIST" node -e '
    try {
      const allow = String(process.env.ALLOWLIST || "").split(" ").filter(Boolean);
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const b = Array.isArray(j.bypasses)
        ? j.bypasses.filter((x, i, a) => allow.indexOf(x) >= 0 && a.indexOf(x) === i)
        : [];
      console.log(b.join(", "));
    } catch (_) { console.log(""); }
  ' "$state_file" 2>/dev/null)
  echo "$val"
}

zensu_pending_review_file() {
  local dir="${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  echo "${dir}/pending-review.json"
}

_tdd_write_pending_review_critical() {
  local pf="$1"
  local files="$2"
  local summary="$3"
  local ts="$4"

  local tmp
  if ! tmp="$(mktemp "${pf}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  FILES="$files" SUMMARY="$summary" TS="$ts" \
    node -e '
      const fs = require("fs");
      const files = (process.env.FILES || "").split(",").map(s => s.trim()).filter(Boolean);
      const o = { files, summary: process.env.SUMMARY || "" };
      if (process.env.TS) o.ts = process.env.TS;
      fs.writeFileSync(process.argv[1], JSON.stringify(o, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$pf" "$(dirname "$pf")" \
    || { rm -f "$tmp"; return 1; }
  return 0
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
  _tdd_locked_run "$pf" _tdd_write_pending_review_critical "$pf" "$files" "$summary" "$ts"
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
  local file="${1:-}" ttl_hours="${2:-}"
  case "$ttl_hours" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ttl_hours" -gt 0 ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  TTL="$ttl_hours" node -e '
    try {
      const fs = require("fs");
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      let t = typeof j.ts === "string" ? Date.parse(j.ts) : NaN;
      if (!Number.isFinite(t)) t = fs.statSync(process.argv[1]).mtimeMs;
      const ttl = Number.parseInt(process.env.TTL, 10) * 3600 * 1000;
      process.exit(Number.isFinite(t) && Date.now() - t >= ttl ? 0 : 1);
    } catch (_) { process.exit(1); }
  ' "$file" >/dev/null 2>&1
}

_tdd_read_pending_claim_metadata() {
  local claim_file="${1:-}"
  [ -f "$claim_file" ] && [ ! -L "$claim_file" ] || return 1
  node -e '
    try {
      const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const id = j && j.claimId;
      const owner = j && j.ownerSessionId;
      const validId = typeof id === "string" && /^dc_[A-Za-z0-9_-]+$/.test(id) && id.length <= 96;
      const validOwner = typeof owner === "string" && /^[A-Za-z0-9_-]+$/.test(owner) && owner.length <= 160;
      if (!validId || !validOwner) process.exit(3);
      const ownerPid = Number.isInteger(j.ownerPid) && j.ownerPid > 0 ? j.ownerPid : 0;
      const emitted = j.handoffEmitted === true;
      process.stdout.write(`${id}\t${owner}\t${ownerPid}\t${emitted}`);
    } catch (_) { process.exit(3); }
  ' "$claim_file" 2>/dev/null
}

_tdd_assign_pending_claim_metadata() {
  local claim_file="$1" owner_session="$2" owner_pid="$3" dir tmp metadata_file
  dir="$(dirname "$claim_file")"
  _tdd_path_safe "$claim_file" regular "$dir" || return 1
  tmp="$(mktemp "${claim_file}.XXXXXX" 2>/dev/null)" || return 1
  metadata_file="$(mktemp "${claim_file}.metadata.XXXXXX" 2>/dev/null)" || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  if ! CLAIM_FILE="$claim_file" OWNER_SESSION="$owner_session" OWNER_PID="$owner_pid" \
      LOG_STYLE="$(_zensu_log_style)" node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    try {
      const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
      let id = j && j.claimId;
      if (typeof id !== "string" || !/^dc_[A-Za-z0-9_-]+$/.test(id) || id.length > 96) {
        id = `dc_${crypto.randomBytes(16).toString("hex")}`;
      }
      const owner = process.env.OWNER_SESSION;
      if (!/^[A-Za-z0-9_-]+$/.test(owner) || owner.length > 160) process.exit(3);
      const ownerPid = Number.parseInt(process.env.OWNER_PID, 10);
      if (!Number.isInteger(ownerPid) || ownerPid <= 0) process.exit(3);
      j.claimId = id;
      j.ownerSessionId = owner;
      j.ownerPid = ownerPid;
      j.handoffEmitted = false;
      // Claim assignment is also a lease renewal.  Timestamp-free logging must
      // remain timestamp-free: deleting a marker-era ts makes the freshly
      // replaced claim file mtime the authoritative lease clock instead.
      if (process.env.LOG_STYLE === "none") delete j.ts;
      else j.ts = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
      fs.writeFileSync(process.argv[1], JSON.stringify(j, null, 2));
      fs.writeFileSync(process.argv[2], `${id}\t${owner}\t${ownerPid}\tfalse`);
    } catch (_) { process.exit(3); }
  ' "$tmp" "$metadata_file" 2>/dev/null; then
    rm -f "$tmp" "$metadata_file" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$claim_file" "$dir" || {
    rm -f "$tmp" "$metadata_file" 2>/dev/null
    return 1
  }
  cat "$metadata_file"
  rm -f "$metadata_file" 2>/dev/null
}

_tdd_reconcile_seeded_pending_claim_critical() {
  local state_file="$1" owner_session="$2" current_session="$3" claim_id="$4" claim_file="$5"
  local owner_alive="$6" handoff_emitted="$7" claim_stale="$8"
  local claim_dir tmp status_file status
  claim_dir="$(dirname "$claim_file")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_path_safe "$claim_file" regular "$claim_dir" || return 1
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  status_file="$(mktemp "${state_file}.claim-status.XXXXXX" 2>/dev/null)" || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  if ! STATE_FILE="$state_file" CLAIM_ID="$claim_id" OWNER_SESSION="$owner_session" \
      CURRENT_SESSION="$current_session" OWNER_ALIVE="$owner_alive" \
      HANDOFF_EMITTED="$handoff_emitted" CLAIM_STALE="$claim_stale" node -e '
    const fs = require("fs");
    try {
      const s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      if (!s || s.deferredReviewClaim !== process.env.CLAIM_ID) {
        if (process.env.HANDOFF_EMITTED === "true") {
          fs.writeFileSync(process.argv[2], "cancelled");
          process.exit(0);
        }
        process.exit(3);
      }
      let status;
      if (s.chainDone === true) {
        status = "done";
      } else if (process.env.OWNER_SESSION === process.env.CURRENT_SESSION) {
        status = "current";
      } else if (process.env.OWNER_ALIVE === "true"
          || (process.env.HANDOFF_EMITTED === "true" && process.env.CLAIM_STALE !== "true")) {
        status = "owned";
      } else {
        // The project claim lock survived while the original process did not.
        // Retire that orphaned per-session generation before transferring the
        // same claim to the current interactive session.
        status = "transfer";
        s.active = false;
        s.implComplete = false;
        s.chainDone = false;
        s.codeReviewDone = false;
        s.selfReviewFixed = false;
        s.reviewTicket = "";
        s.reviewTicketConsumed = true;
        s.reviewRound = 0;
        s.stopBlockCount = 0;
        s.deferredReviewClaim = "";
        fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
      }
      fs.writeFileSync(process.argv[2], status);
    } catch (_) { process.exit(3); }
  ' "$tmp" "$status_file" >/dev/null 2>&1; then
    rm -f "$tmp" "$status_file" 2>/dev/null
    return 1
  fi
  status="$(cat "$status_file" 2>/dev/null)"
  rm -f "$status_file" 2>/dev/null
  case "$status" in
    transfer)
      _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
        || { rm -f "$tmp"; return 1; }
      ;;
    current|owned)
      rm -f "$tmp" 2>/dev/null
      ;;
    done|cancelled)
      rm -f "$tmp" 2>/dev/null
      rm -f -- "$claim_file" 2>/dev/null || return 1
      ;;
    *) rm -f "$tmp" 2>/dev/null; return 1 ;;
  esac
  printf '%s\n' "$status"
}

_tdd_reconcile_seeded_pending_claim() {
  local owner_session="$1" current_session="$2" claim_id="$3" claim_file="$4"
  local owner_pid="$5" handoff_emitted="$6" claim_stale="$7" state_file owner_alive=false
  if [ "$owner_pid" -gt 0 ] 2>/dev/null && kill -0 "$owner_pid" 2>/dev/null; then
    owner_alive=true
  fi
  state_file="$(tdd_state_file "$owner_session")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _tdd_reconcile_seeded_pending_claim_critical \
    "$state_file" "$owner_session" "$current_session" "$claim_id" "$claim_file" \
    "$owner_alive" "$handoff_emitted" "$claim_stale"
}

_tdd_adopt_pending_review_critical() {
  local pf="$1" claim_file="$2" session_id="$3" vanilla="$4" ttl_hours="$5"
  local dir source metadata claim_id owner_session owner_pid handoff_emitted claim_stale reconcile_status
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
    IFS=$'\t' read -r claim_id owner_session owner_pid handoff_emitted <<<"$metadata"
    claim_stale=false
    _tdd_pending_file_stale "$claim_file" "$ttl_hours" && claim_stale=true
    reconcile_status="$(_tdd_reconcile_seeded_pending_claim \
      "$owner_session" "$session_id" "$claim_id" "$claim_file" \
      "$owner_pid" "$handoff_emitted" "$claim_stale" 2>/dev/null)" || reconcile_status=""
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
      *)
        if _tdd_pending_file_stale "$claim_file" "$ttl_hours"; then
          rm -f -- "$claim_file" 2>/dev/null || return 1
          return 2
        fi
        ;;
    esac
  fi

  if [ -z "$metadata" ] && _tdd_pending_file_stale "$claim_file" "$ttl_hours"; then
    rm -f -- "$claim_file" 2>/dev/null || return 1
    return 2
  fi

  metadata="$(_tdd_assign_pending_claim_metadata "$claim_file" "$session_id" "$$")" || return 1
  IFS=$'\t' read -r claim_id owner_session owner_pid handoff_emitted <<<"$metadata"

  if tdd_seed_deferred_review "$session_id" "$vanilla" "$claim_id"; then
    # Keep the claim as a recovery/ownership record until the Stop hook has
    # emitted its block handoff and, ultimately, the chain reaches chainDone.
    return 0
  fi

  # Preserve retryability. If a newer marker arrived while the claim was being
  # processed, keep both records; the crash claim is retried first.
  if [ ! -e "$pf" ] && [ ! -L "$pf" ]; then
    _tdd_atomic_replace_regular "$claim_file" "$pf" "$dir" 2>/dev/null || true
  fi
  return 1
}

tdd_adopt_pending_review() {
  local session_id="${1:-}" vanilla="${2:-false}" ttl_hours="${3:-0}" pf dir claim_file
  [ -n "$session_id" ] || return 1
  case "$vanilla" in true|false) ;; *) return 1 ;; esac
  case "$ttl_hours" in ''|*[!0-9]*) ttl_hours=0 ;; esac
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="${pf}.claim"
  _tdd_prepare_directory "$dir" || return 1
  _tdd_path_safe "$pf" regular-or-absent "$dir" || return 1
  _tdd_path_safe "$claim_file" regular-or-absent "$dir" || return 1
  _tdd_locked_run "$pf" _tdd_adopt_pending_review_critical \
    "$pf" "$claim_file" "$session_id" "$vanilla" "$ttl_hours"
}

_tdd_mark_pending_handoff_state_critical() {
  local state_file="$1" claim_file="$2" session_id="$3" claim_id="$4"
  local owner_pid="$5" log_style="$6" dir tmp
  dir="$(dirname "$claim_file")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_path_safe "$claim_file" regular "$dir" || return 1
  STATE_FILE="$state_file" SID="$session_id" CLAIM_ID="$claim_id" node -e '
    try {
      const s = JSON.parse(require("fs").readFileSync(process.env.STATE_FILE, "utf8"));
      const valid = s && s.session_id === process.env.SID && s.active === true
        && s.implComplete === true && s.chainDone === false
        && s.deferredReviewClaim === process.env.CLAIM_ID;
      process.exit(valid ? 0 : 3);
    } catch (_) { process.exit(3); }
  ' >/dev/null 2>&1 || return 1
  tmp="$(mktemp "${claim_file}.XXXXXX" 2>/dev/null)" || return 1
  if ! CLAIM_FILE="$claim_file" SID="$session_id" CLAIM_ID="$claim_id" \
      OWNER_PID="$owner_pid" LOG_STYLE="$log_style" node -e '
    const fs = require("fs");
    try {
      const j = JSON.parse(fs.readFileSync(process.env.CLAIM_FILE, "utf8"));
      if (!j || j.ownerSessionId !== process.env.SID || j.claimId !== process.env.CLAIM_ID) process.exit(3);
      const ownerPid = Number.parseInt(process.env.OWNER_PID, 10);
      if (!Number.isInteger(ownerPid) || ownerPid <= 0) process.exit(3);
      j.ownerPid = ownerPid;
      j.handoffEmitted = true;
      // Re-acknowledging a seeded claim is also a lease renewal. This closes
      // the crash window where the state survived, the original hook process
      // died before output, and a retry in the SAME session has now emitted
      // the handoff. Timestamp-free logging uses the replacement mtime.
      if (process.env.LOG_STYLE === "none") delete j.ts;
      else j.ts = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
      fs.writeFileSync(process.argv[1], JSON.stringify(j, null, 2));
    } catch (_) { process.exit(3); }
  ' "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$claim_file" "$dir" \
    || { rm -f "$tmp"; return 1; }
}

_tdd_mark_pending_review_handoff_critical() {
  local pf="$1" claim_file="$2" session_id="$3" metadata claim_id owner_session _owner_pid _emitted
  [ -f "$claim_file" ] || return 1
  metadata="$(_tdd_read_pending_claim_metadata "$claim_file")" || return 1
  IFS=$'\t' read -r claim_id owner_session _owner_pid _emitted <<<"$metadata"
  [ "$owner_session" = "$session_id" ] || return 1
  local state_file
  state_file="$(tdd_state_file "$session_id")"
  _tdd_locked_run "$state_file" _tdd_mark_pending_handoff_state_critical \
    "$state_file" "$claim_file" "$session_id" "$claim_id" "$$" "$(_zensu_log_style)"
}

tdd_mark_pending_review_handoff() {
  local session_id="${1:-}" pf dir claim_file
  [ -n "$session_id" ] || return 1
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="${pf}.claim"
  _tdd_path_safe "$claim_file" regular "$dir" || return 1
  _tdd_locked_run "$pf" _tdd_mark_pending_review_handoff_critical \
    "$pf" "$claim_file" "$session_id"
}

_tdd_clear_deferred_claim_state_critical() {
  local state_file="$1" claim_id="$2" tmp
  [ -f "$state_file" ] || return 0
  tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)" || return 1
  if ! STATE_FILE="$state_file" CLAIM_ID="$claim_id" node -e '
    const fs = require("fs");
    try {
      const s = JSON.parse(fs.readFileSync(process.env.STATE_FILE, "utf8"));
      if (s && s.deferredReviewClaim === process.env.CLAIM_ID) s.deferredReviewClaim = "";
      fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
    } catch (_) { process.exit(3); }
  ' "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
}

_tdd_release_pending_review_claim_critical() {
  local pf="$1" claim_file="$2" session_id="$3" metadata claim_id owner_session _owner_pid _emitted state_file
  [ -f "$claim_file" ] || return 0
  metadata="$(_tdd_read_pending_claim_metadata "$claim_file")" || return 1
  IFS=$'\t' read -r claim_id owner_session _owner_pid _emitted <<<"$metadata"
  [ "$owner_session" = "$session_id" ] || return 0
  state_file="$(tdd_state_file "$session_id")"
  if [ -f "$state_file" ]; then
    _tdd_locked_run "$state_file" _tdd_clear_deferred_claim_state_critical \
      "$state_file" "$claim_id" || return 1
  fi
  rm -f -- "$claim_file" 2>/dev/null
}

tdd_release_pending_review_claim() {
  local session_id="${1:-}" pf dir claim_file
  [ -n "$session_id" ] || return 1
  pf="$(zensu_pending_review_file)"
  dir="$(dirname "$pf")"
  claim_file="${pf}.claim"
  _tdd_prepare_directory "$dir" || return 1
  _tdd_paths_safe "$pf" regular-or-absent "$claim_file" regular-or-absent || return 1
  _tdd_locked_run "$pf" _tdd_release_pending_review_claim_critical \
    "$pf" "$claim_file" "$session_id"
}

tdd_pending_review_stale() {
  local ttl_hours="${1:-}"
  case "$ttl_hours" in ''|*[!0-9]*) echo "false"; return 0 ;; esac
  [ "$ttl_hours" -le 0 ] && { echo "false"; return 0; }
  local pf
  pf="$(zensu_pending_review_file)"
  [ -f "$pf" ] || { echo "false"; return 0; }
  [ -L "$pf" ] && { echo "false"; return 0; }
  command -v node >/dev/null 2>&1 || { echo "false"; return 0; }
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
  ' "$pf" 2>/dev/null)
  [ "$verdict" = "true" ] && echo "true" || echo "false"
}

_tdd_write_seed_critical() {
  local state_file="$1"
  local session_id="$2"
  local vanilla="$3"

  local tmp
  if ! tmp="$(mktemp "${state_file}.XXXXXX" 2>/dev/null)"; then
    return 1
  fi

  STATE_FILE="$state_file" SID="$session_id" VANILLA="$vanilla" \
    node -e '
      const fs = require("fs");
      const sf = process.env.STATE_FILE;
      let state = {};
      try {
        const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
        if (prev && typeof prev === "object" && !Array.isArray(prev)) state = prev;
      } catch (_) {}
      if (!state.session_id) state.session_id = process.env.SID;
      if (typeof state.phase !== "string") state.phase = "UNINITIALIZED";
      if (!Array.isArray(state.history)) state.history = [];
      state.active = true;
      state.implComplete = true;
      state.vanilla = (process.env.VANILLA === "true");
      state.chainDone = false;
      state.codeReviewDone = false;
      state.selfReviewFixed = false;
      state.reviewTicket = "";
      state.reviewTicketConsumed = true;
      state.reviewRound = 0;
      state.bypasses = [];
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  _tdd_atomic_replace_regular "$tmp" "$state_file" "$(dirname "$state_file")" \
    || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_seed_deferred_review() {
  local session_id="${1:-unknown}"
  local vanilla="${2:-false}"
  local deferred_claim="${3:-}"
  case "$vanilla" in true|false) ;; *) vanilla="false" ;; esac
  # A deferred review is a fresh, already-implemented chain generation. Reuse
  # the atomic begin transaction so ticket/flags, round counter, and Stop budget
  # are reset together even when the previous generation already terminated.
  tdd_begin_session "$session_id" "$vanilla" true true "$deferred_claim"
}

export -f tdd_state_file _tdd_paths_safe _tdd_path_safe _tdd_state_storage_safe _tdd_prepare_directory _tdd_atomic_replace_regular tdd_is_test_path _tdd_locked_run tdd_write_phase _tdd_write_phase_critical tdd_phase tdd_step tdd_has_red_fail _tdd_write_flag_critical tdd_set_flag _tdd_write_clear_critical tdd_clear_session _tdd_clear_standalone_session_critical tdd_clear_standalone_session _tdd_clear_autopilot_session_critical tdd_clear_autopilot_session _tdd_write_chain_reset_critical tdd_reset_chain_flags _tdd_begin_session_critical tdd_begin_session tdd_autopilot_context tdd_chain_snapshot _tdd_autopilot_link_id_shape_ok _tdd_autopilot_attempt_shape_ok _tdd_mark_impl_complete_bound_critical tdd_mark_impl_complete_bound _tdd_mark_impl_complete_standalone_critical tdd_mark_impl_complete_standalone _tdd_set_chain_outcome_critical tdd_set_chain_outcome _tdd_finish_autopilot_chain_critical tdd_finish_autopilot_chain _tdd_review_ticket_shape_ok _tdd_issue_review_ticket_critical tdd_issue_review_ticket _tdd_consume_review_ticket_critical tdd_consume_review_ticket_context tdd_consume_review_ticket _tdd_mark_autopilot_max_round_handoff_critical tdd_mark_autopilot_max_round_handoff _tdd_mark_review_converged_critical tdd_mark_review_converged _tdd_mark_unclaimed_review_critical tdd_mark_unclaimed_review tdd_claimed_review_ticket tdd_ensure_self_review_ticket tdd_increment_stop_budget tdd_rearm_review _tdd_rearm_autopilot_review_critical tdd_rearm_autopilot_review tdd_get_flag tdd_session_active tdd_vanilla_mode tdd_impl_complete tdd_chain_done tdd_code_review_done tdd_self_review_fixed zensu_workflow_active zensu_workflow_allows tdd_workflow_begin _tdd_write_workflow_begin_critical _tdd_bypass_shape_ok _tdd_write_bypass_critical tdd_add_bypass tdd_record_bypass tdd_record_bypass_payload tdd_bypasses _tdd_write_bypass_clear_critical tdd_clear_bypasses zensu_pending_review_file _tdd_write_pending_review_critical tdd_write_pending_review tdd_clear_pending_review tdd_adopt_pending_review tdd_mark_pending_review_handoff tdd_release_pending_review_claim tdd_pending_review_stale _tdd_write_seed_critical tdd_seed_deferred_review 2>/dev/null || true
