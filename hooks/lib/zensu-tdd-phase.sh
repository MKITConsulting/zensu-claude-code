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

  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

_tdd_locked_run() {
  local state_file="$1"
  shift

  local lock_file="${state_file}.lock"

  if [ "${TDD_DISABLE_FLOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then
    (
      exec 9>>"$lock_file" 2>/dev/null || exit 1
      flock -x 9 2>/dev/null || exit 1
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
  "$@"
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
  mkdir -p "$state_dir" 2>/dev/null || true

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

  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
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
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
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
    s.workflowTools = []; s.vanilla = false; s.bypasses = [];
    fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
  ' "$tmp" 2>/dev/null
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
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

  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_workflow_begin() {
  local session_id="${1:-unknown}"
  local tools="${2:-}"
  local state_file
  state_file=$(tdd_state_file "$session_id")
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
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


# --- Reviewed-at-SHA marker (review chain terminus) -------------------------
# --chain-done records WHICH state the converged review chain covered:
# review-pass-<sid>, line 1 = HEAD SHA at chain end, `tree:` = digest of the
# reviewed WORKING TREE (via `git stash create`, HEAD^{tree} when clean) — so
# the follow-up commit that freezes exactly the reviewed state still matches,
# while a commit introducing new content does not. Consumed by the optional
# PR-create gate
# (hooks/pre-bash-pr-gate.sh, hooks.prGate default off). Never fails the
# caller; skipped with a stderr note outside a git checkout.

zensu_review_pass_file() {
  local session_id="${1:-}"
  local sanitized="${session_id//[^A-Za-z0-9_-]/_}"
  local dir="${TDD_STATE_DIR:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
  echo "${dir}/review-pass-${sanitized}"
}

tdd_write_review_pass() {
  local session_id="${1:-unknown}"
  local mf
  mf="$(zensu_review_pass_file "$session_id")"
  local dir
  dir="$(dirname "$mf")"
  [ -L "$mf" ] && { echo "zensu: refusing to write review-pass marker through symlink at $mf" >&2; return 1; }
  [ -L "$dir" ] && { echo "zensu: refusing to write review-pass marker under symlinked dir $dir" >&2; return 1; }
  mkdir -p "$dir" 2>/dev/null || true
  local repo=""
  if git rev-parse HEAD >/dev/null 2>&1; then
    repo="."
  elif git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse HEAD >/dev/null 2>&1; then
    repo="${CLAUDE_PROJECT_DIR:-.}"
  fi
  if [ -z "$repo" ]; then
    echo "zensu: no git checkout found — review-pass marker skipped" >&2
    return 0
  fi
  local sha tree tree_tracked stash tmpidx
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
  tree=""
  tmpidx="$(mktemp 2>/dev/null)"
  if [ -n "$tmpidx" ]; then
    if GIT_INDEX_FILE="$tmpidx" git -C "$repo" read-tree HEAD 2>/dev/null \
      && GIT_INDEX_FILE="$tmpidx" git -C "$repo" add -A 2>/dev/null; then
      tree="$(GIT_INDEX_FILE="$tmpidx" git -C "$repo" write-tree 2>/dev/null)"
    fi
    rm -f "$tmpidx"
  fi
  [ -z "$tree" ] && tree="$(git -C "$repo" rev-parse "HEAD^{tree}" 2>/dev/null)"
  tree_tracked=""
  stash="$(git -C "$repo" stash create 2>/dev/null)"
  if [ -n "$stash" ]; then
    tree_tracked="$(git -C "$repo" rev-parse "${stash}^{tree}" 2>/dev/null)"
  else
    tree_tracked="$(git -C "$repo" rev-parse "HEAD^{tree}" 2>/dev/null)"
  fi
  local tmp
  tmp="$(mktemp "${dir}/.review-pass-tmp.XXXXXX" 2>/dev/null)" || return 1
  {
    printf '%s\n' "$sha"
    printf 'tree: %s\n' "$tree"
    if [ -n "$tree_tracked" ] && [ "$tree_tracked" != "$tree" ]; then
      printf 'tree-tracked: %s\n' "$tree_tracked"
    fi
    if [ "$(_zensu_log_style)" != "none" ]; then
      printf 'reviewed-at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    printf 'session: %s\n' "$session_id"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$mf" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_clear_review_pass() {
  local session_id="${1:-unknown}"
  local mf
  mf="$(zensu_review_pass_file "$session_id")"
  [ -L "$mf" ] && return 1
  rm -f -- "$mf" 2>/dev/null || true
  return 0
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

ZENSU_BYPASS_GATE_ALLOWLIST="ZENSU_TDD_GATE ZENSU_BASH_WRITE_GATE ZENSU_MCP_GATE ZENSU_SECRET_SCAN ZENSU_CHAIN ZENSU_TEST_WITNESS ZENSU_PR_GATE"

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
          && state.bypasses.indexOf(gate) < 0
          && state.bypasses.length < 32) state.bypasses.push(gate);
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_add_bypass() {
  local session_id="${1:-unknown}"
  local gate="${2:-}"
  _tdd_bypass_shape_ok "$gate" || return 1

  local state_file
  state_file=$(tdd_state_file "$session_id")
  [ -L "$state_file" ] && return 1
  [ -L "$(dirname "$state_file")" ] && return 1
  case ", $(tdd_bypasses "$state_file")," in
    *", $gate,"*) return 0 ;;
  esac
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
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
  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
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
        ? j.bypasses.filter((x, i, a) => allow.indexOf(x) >= 0 && a.indexOf(x) === i).slice(0, 32)
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

  mv "$tmp" "$pf" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_write_pending_review() {
  local files="${1:-}"
  local summary="${2:-}"
  local pf
  pf="$(zensu_pending_review_file)"
  local dir
  dir="$(dirname "$pf")"
  [ -L "$pf" ] && return 1
  [ -L "$dir" ] && return 1
  mkdir -p "$dir" 2>/dev/null || true
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
  if [ -L "$pf" ]; then
    echo "zensu: refusing to clear pending-review marker through symlink at $pf" >&2
    return 1
  fi
  if [ -L "$dir" ]; then
    echo "zensu: refusing to clear pending-review marker under symlinked dir $dir" >&2
    return 1
  fi
  rm -f -- "$pf" 2>/dev/null || true
  return 0
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
      state.bypasses = [];
      fs.writeFileSync(process.argv[1], JSON.stringify(state, null, 2));
    ' "$tmp" 2>/dev/null

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi

  mv "$tmp" "$state_file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

tdd_seed_deferred_review() {
  local session_id="${1:-unknown}"
  local vanilla="${2:-false}"
  case "$vanilla" in true|false) ;; *) vanilla="false" ;; esac
  local state_file
  state_file=$(tdd_state_file "$session_id")
  mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
  command -v node >/dev/null 2>&1 || return 1
  _tdd_locked_run "$state_file" _tdd_write_seed_critical "$state_file" "$session_id" "$vanilla"
}

export -f tdd_state_file tdd_is_test_path _tdd_locked_run tdd_write_phase _tdd_write_phase_critical tdd_phase tdd_step tdd_has_red_fail _tdd_write_flag_critical tdd_set_flag _tdd_write_clear_critical tdd_clear_session tdd_get_flag tdd_session_active tdd_vanilla_mode tdd_impl_complete tdd_chain_done tdd_code_review_done tdd_self_review_fixed zensu_workflow_active zensu_workflow_allows tdd_workflow_begin _tdd_write_workflow_begin_critical _tdd_bypass_shape_ok _tdd_write_bypass_critical tdd_add_bypass tdd_record_bypass tdd_record_bypass_payload tdd_bypasses _tdd_write_bypass_clear_critical tdd_clear_bypasses zensu_pending_review_file _tdd_write_pending_review_critical tdd_write_pending_review tdd_clear_pending_review tdd_pending_review_stale _tdd_write_seed_critical tdd_seed_deferred_review 2>/dev/null || true
