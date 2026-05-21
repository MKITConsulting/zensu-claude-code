#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

tdd_state_file() {
  local session_id="${1:-unknown}"
  local sanitized="${session_id//[^A-Za-z0-9_-]/_}"
  [ -z "$sanitized" ] && sanitized="unknown"
  local dir="${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  echo "${dir}/tdd-phase-${sanitized}.json"
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
    link_count=$(stat -f %l "$path" 2>/dev/null || stat -c %h "$path" 2>/dev/null || echo "1")
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
      let state = { session_id: process.env.SID, step_id: process.env.STEP, phase: process.env.PHASE, history: [] };
      try {
        if (fs.existsSync(sf)) {
          const prev = JSON.parse(fs.readFileSync(sf, "utf8"));
          if (prev && typeof prev === "object") {
            state.history = Array.isArray(prev.history) ? prev.history : [];
            state.session_id = prev.session_id || state.session_id;
          }
        }
      } catch (_) {}
      const entry = { step: process.env.STEP, phase: process.env.PHASE, ts: process.env.TS };
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

  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
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
  mkdir -p "$state_dir" 2>/dev/null || true

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  command -v node >/dev/null 2>&1 || return 1

  local lock_file="${state_file}.lock"

  if [ "${TDD_DISABLE_FLOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lock_file" 2>/dev/null || exit 1
      flock -x 9 2>/dev/null || exit 1
      _tdd_write_phase_critical "$state_file" "$session_id" "$step_id" "$phase" "$reason" "$ts"
    )
    return $?
  fi

  local lock_dir="${state_file}.lockd"
  local attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    local dead=0
    local mtime
    mtime=$(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo "")
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
  _tdd_write_phase_critical "$state_file" "$session_id" "$step_id" "$phase" "$reason" "$ts"
  local rc=$?
  rm -rf "$lock_dir" 2>/dev/null || true
  return $rc
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

export -f tdd_state_file tdd_is_test_path tdd_write_phase _tdd_write_phase_critical tdd_phase tdd_step tdd_has_red_fail 2>/dev/null || true
