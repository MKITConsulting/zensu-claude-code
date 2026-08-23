#!/bin/bash
# Durable, project-local outer state machine for /zensu:autopilot.
set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Reuse the hardened path, atomic-rename, and Core external-process lease used
# by the inner TDD state. Autopilot maps all mutations to one project sentinel.
# shellcheck source=hooks/lib/zensu-tdd-phase.sh
# shellcheck disable=SC1091
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-tdd-phase.sh"

# Render filesystem operands for native Node explicitly. When Session Control
# has already established an immutable project binding, project descendants
# are translated by preserving their suffix beneath that exact shell/native
# root pair. Pre-session public helpers retain their historical behavior, but
# still use cygpath explicitly instead of MSYS' quote-sensitive heuristics.
_autopilot_native_path() {
  local input="${1:-}" shell_root
  [ "$#" -eq 1 ] && [ -n "$input" ] || return 1
  if [ -z "${ZENSU_PROJECT_ROOT:-}" ] \
      && [ -z "${ZENSU_SESSION_KEY:-}" ] \
      && [ -z "${ZENSU_SESSION_CONTEXT:-}" ]; then
    _tdd_native_path "$input"
    return $?
  fi
  [ -n "${ZENSU_PROJECT_ROOT:-}" ] \
    && [ -n "${ZENSU_SESSION_KEY:-}" ] \
    && [ -n "${ZENSU_SESSION_CONTEXT:-}" ] || return 1
  # shellcheck source=hooks/lib/zensu-session.sh
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  shell_root="$(zensu_resolve_project_dir)" || return 1
  case "$input" in
    "$shell_root"|"$shell_root"/*) _tdd_native_project_path "$input" ;;
    *) _tdd_native_path "$input" ;;
  esac
}

# Project authority is stricter than generic file transport. Once a session is
# bound, an explicit project root (and every derived state operand) must be the
# bound root or one of its descendants; it may never fall back to a different
# path merely because cygpath can render it for native Node.
_autopilot_native_project_path() {
  local input="${1:-}" shell_root native_root suffix
  [ "$#" -eq 1 ] && [ -n "$input" ] || return 1
  if [ -z "${ZENSU_PROJECT_ROOT:-}" ] \
      && [ -z "${ZENSU_SESSION_KEY:-}" ] \
      && [ -z "${ZENSU_SESSION_CONTEXT:-}" ]; then
    _tdd_native_path "$input"
    return $?
  fi
  [ -n "${ZENSU_PROJECT_ROOT:-}" ] \
    && [ -n "${ZENSU_SESSION_KEY:-}" ] \
    && [ -n "${ZENSU_SESSION_CONTEXT:-}" ] || return 1
  # Reject traversal before selecting a namespace. The suffix mapper is
  # intentionally lexical so it can handle not-yet-created state files; dot
  # segments must therefore never reach either its shell or native branch.
  case "/$input/" in */../*|*/./*) return 1 ;; esac
  # Validate the private record before accepting either namespace. Public
  # helpers normally pass the shell spelling returned by pwd -P; accepting the
  # exact native spelling as well keeps internal callers namespace-stable.
  # shellcheck source=hooks/lib/zensu-session.sh
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  shell_root="$(zensu_resolve_project_dir)" || return 1
  native_root="${ZENSU_PROJECT_ROOT%/}"
  case "$input" in
    "$shell_root"|"$shell_root"/*) _tdd_native_project_path "$input" ;;
    "$native_root") printf '%s\n' "$native_root" ;;
    "$native_root"/*)
      suffix="${input#"$native_root"/}"
      [ -n "$suffix" ] || return 1
      case "$suffix" in *\\*|*$'\r'*|*$'\n'*) return 1 ;; esac
      printf '%s/%s\n' "$native_root" "$suffix"
      ;;
    *) return 1 ;;
  esac
}

_autopilot_native_project_root() {
  local input="${1:-}" shell_input shell_root
  [ "$#" -eq 1 ] && [ -n "$input" ] || return 1
  if [ -z "${ZENSU_PROJECT_ROOT:-}" ] \
      && [ -z "${ZENSU_SESSION_KEY:-}" ] \
      && [ -z "${ZENSU_SESSION_CONTEXT:-}" ]; then
    _tdd_native_path "$input"
    return $?
  fi
  [ -n "${ZENSU_PROJECT_ROOT:-}" ] \
    && [ -n "${ZENSU_SESSION_KEY:-}" ] \
    && [ -n "${ZENSU_SESSION_CONTEXT:-}" ] || return 1
  # shellcheck source=hooks/lib/zensu-session.sh
  # shellcheck disable=SC1091
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
  shell_root="$(zensu_resolve_project_dir)" || return 1
  shell_input="$(cd -P -- "$input" 2>/dev/null && pwd -P)" || return 1
  [ "$shell_input" = "$shell_root" ] || return 1
  _tdd_native_project_path "$shell_root"
}

_autopilot_msys_env_exclusions() {
  local additions="${1:-}" existing="${MSYS2_ENV_CONV_EXCL:-}"
  [ "$#" -eq 1 ] && [ -n "$additions" ] || return 1
  printf '%s%s%s\n' "$existing" "${existing:+;}" "$additions"
}

_autopilot_shell_path() {
  local value="${1:-}"
  [ "$#" -eq 1 ] && [ -n "$value" ] || return 2
  case "$value" in
    [A-Za-z]:[\\/]*|\\\\*)
      command -v cygpath >/dev/null 2>&1 || return 2
      cygpath -u "$value" 2>/dev/null
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

_autopilot_project_root() {
  local input="${1:-${CLAUDE_PROJECT_DIR:-.}}" root native_input env_exclusions
  native_input="$(_autopilot_native_project_root "$input")" || return 2
  env_exclusions="$(_autopilot_msys_env_exclusions ROOT_INPUT)" || return 2
  MSYS2_ENV_CONV_EXCL="$env_exclusions" ROOT_INPUT="$native_input" node -e '
    const fs = require("fs");
    const path = require("path");
    const logicalRoot = path.resolve(process.env.ROOT_INPUT || ".");
    if (/[\u0000-\u001f]/.test(logicalRoot)) process.exit(2);
    let root;
    try {
      if (!fs.statSync(logicalRoot).isDirectory()) process.exit(2);
      root = fs.realpathSync(logicalRoot);
    } catch (_) { process.exit(2); }
    if (/[\u0000-\u001f]/.test(root)) process.exit(2);
  ' >/dev/null 2>&1 || return 2
  root="$(cd -P -- "$input" 2>/dev/null && pwd -P)" || return 2
  [ -n "$root" ] || return 2
  printf '%s\n' "$root"
}

_autopilot_identifier_ok() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
  esac
  case "$1" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
  [ "${#1}" -ge 3 ] && [ "${#1}" -le 128 ]
}

# Hook session ids predate the durable Autopilot schema and may legitimately be
# shorter than its three-character identifiers (for example a test/runtime id
# such as "hx").  A reconciliation caller is used only to compare ownership;
# it is never persisted unless it already equals the schema-validated owner.
_autopilot_session_id_ok() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# The pointer is keyed by a digest of the owner session id rather than by the
# id itself: an owner may be 128 characters, and `autopilot-active-<id>.json`
# under a deep project root would cross Windows' legacy MAX_PATH exactly the
# way `_autopilot_mktemp_beside` documents for run files. A digest is a fixed
# 64 characters and cannot carry a path separator.
_autopilot_owner_key() {
  local owner="${1:-}" key
  _autopilot_session_id_ok "$owner" || return 3
  key="$(OWNER="$owner" node -e '
    const crypto = require("crypto");
    process.stdout.write(crypto.createHash("sha256").update(String(process.env.OWNER)).digest("hex"));
  ' 2>/dev/null </dev/null)" || return 3
  [ "${#key}" -eq 64 ] || return 3
  printf '%s\n' "$key"
}

# The pointer minted before owner scoping. It is never written any more; it is
# read as a fallback and only ever adopted by the session that owns the run it
# references. See the `read-active` worker mode.
_autopilot_legacy_active_path() {
  printf '%s\n' "${1%/}/autopilot-active.json"
}

# The owner is REQUIRED. An empty one used to fall back to the shared legacy
# pointer, which is the exact project-wide artifact this scoping removes; a
# caller that genuinely wants the pre-scoping spelling calls
# `_autopilot_legacy_active_path` by name.
_autopilot_active_path() {
  local state_dir="${1%/}" owner="${2:-}" key
  [ -n "$owner" ] || return 3
  key="$(_autopilot_owner_key "$owner")" || return 3
  printf '%s/autopilot-active-%s.json\n' "$state_dir" "$key"
}

autopilot_active_file() {
  local root
  root="$(_autopilot_project_root "${1:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_active_path "$root/.zensu/state" "${2:-}"
}

# The working tree a run drives. Callers hand in the directory the session is
# actually working in; git resolves it to the worktree root so two spellings of
# one tree compare equal, and a non-repository directory falls back to itself.
# The host-native rendering of an existing directory, or empty when it cannot be
# produced. Both the workspace key and anything compared against it go through
# this, so the two never end up in different namespaces on Windows.
_autopilot_rendered_dir() {
  local dir="${1:-}" rendered
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || return 1
  rendered="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-host-path.sh" "$dir" 2>/dev/null </dev/null)" \
    || return 1
  [ -n "$rendered" ] || return 1
  printf '%s\n' "$rendered"
}

# `fallback` is what a git failure resolves to, and only the GATE path supplies
# one: it passes the project root, so a missing git binary or a non-repository
# directory can never turn one session's key into the caller's cwd — the
# divergence that would make an occupancy gate miss the run it exists to see.
# A caller that DECLARES a workspace passes no fallback, because substituting
# the project root there would silently discard the declaration.
autopilot_workspace_root() {
  local input="${1:-${CLAUDE_PROJECT_DIR:-.}}" fallback="${2:-}" top rendered
  # Both children below run INSIDE the project lease on the gate path, and the
  # lease keeper is a bash coprocess whose control channel is a pipe. A child
  # that inherits those descriptors holds the write end open after the parent
  # closes it, so the keeper never sees EOF and the release hangs — the failure
  # surfaces minutes later as an unrelated suite that never returns. Redirect
  # stdin, not just the output.
  local git_bin
  git_bin="$(command -v git 2>/dev/null)" || git_bin=""
  if [ -n "$git_bin" ]; then
    top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CEILING_DIRECTORIES \
      -u GIT_OBJECT_DIRECTORY -u GIT_INDEX_FILE \
      "$git_bin" -C "$input" rev-parse --show-toplevel 2>/dev/null </dev/null)" || top=""
  else
    top=""
  fi
  if [ -z "$top" ]; then
    top="${fallback:-$input}"
  fi
  [ -d "$top" ] || return 2
  # The project root reaches the worker in the host-native spelling and is then
  # canonicalized there. The workspace must travel the same way or the two live
  # in different namespaces on Windows and `mayHoldWorkspace`'s containment test
  # compares across them.
  rendered="$(_autopilot_rendered_dir "$top")" || rendered=""
  if [ -n "$rendered" ]; then
    printf '%s\n' "$rendered"
    return 0
  fi
  (cd -P -- "$top" 2>/dev/null && pwd -P) || return 2
}

# The workspace this session is working in, resolved the SAME way for the run
# that records it and for every gate that later compares against it — a split
# between the two would let a gate silently miss the run it exists to see.
# A cwd outside the project root is not trusted to name a workspace: a hook
# invoked from an unrelated directory falls back to the project root rather
# than carving out a namespace nobody else will look in.
_autopilot_session_workspace() {
  local root="${1:-}" here
  [ -n "$root" ] || return 3
  here="$(pwd -P 2>/dev/null)" || here=""
  case "$here" in
    "$root"|"$root"/*) ;;
    *) here="$root" ;;
  esac
  autopilot_workspace_root "$here" "$root"
}

autopilot_run_file() {
  local run_id="${1:-}" root
  _autopilot_identifier_ok "$run_id" || return 2
  root="$(_autopilot_project_root "${2:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  printf '%s\n' "$root/.zensu/state/autopilot-run-${run_id}.json"
}

# A run id may be 128 characters, so autopilot-run-<id>.json already reaches ~256
# characters under a deep project root. Appending .XXXXXX to THAT name crosses the
# 260-character Windows MAX_PATH, mktemp fails, and the caller returns a bare
# rc=5 that reads like a refusal rather than a path-length ceiling. The temp keeps
# its own short name and stays in the target's directory, so it is still on the
# same filesystem and the atomic replace is unaffected. Callers whose target name
# is bounded (tdd-phase-<session key>.json) do not need this, and the review
# payload writer must keep its own ${target}.tmp.XXXXXXXX shape because its
# crash-recovery reasons about that alias.
_autopilot_mktemp_beside() {
  local target="${1:-}" dir
  [ -n "$target" ] || return 1
  dir="$(dirname -- "$target")" || return 1
  mktemp "${dir}/.apt-XXXXXX" 2>/dev/null
}

_autopilot_prepare_storage() {
  local root="$1" zensu_dir="$1/.zensu" state_dir="$1/.zensu/state"
  # Validate the fixed project-local ancestor as its own leaf before mkdir -p.
  # This prevents a missing state/ leaf behind a Windows junction from being
  # created before the deeper path check rejects the junction.
  CLAUDE_PROJECT_DIR="$root" _tdd_path_safe "$zensu_dir" directory-or-absent \
    || return 2
  CLAUDE_PROJECT_DIR="$root" _tdd_prepare_directory "$state_dir"
}

_autopilot_storage_safe() {
  local root="$1" run_id="${2:-}" state_dir="$1/.zensu/state"
  local active="$state_dir/autopilot-active.json"
  local sentinel="$state_dir/autopilot"
  local args=(
    "$state_dir" directory
    "$active" regular-or-absent
    "$sentinel" regular-or-absent
    "${sentinel}.lock" regular-or-absent
    "${sentinel}.lockd" directory-or-absent
  )
  if [ -n "$run_id" ]; then
    args+=("$state_dir/autopilot-run-${run_id}.json" regular-or-absent)
  fi
  CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe "${args[@]}"
}

_autopilot_read_storage_ready() {
  local root="$1" run_id="${2:-}" state_dir="$1/.zensu/state"
  if [ ! -d "$state_dir" ]; then
    CLAUDE_PROJECT_DIR="$root" _tdd_path_safe "$state_dir" directory-or-absent || return 2
    return 1
  fi
  _autopilot_storage_safe "$root" "$run_id" || return 2
}

_autopilot_locked_run() {
  local root="$1" run_id="$2"
  shift 2
  local sentinel="$root/.zensu/state/autopilot"
  CLAUDE_PROJECT_DIR="$root" \
    _tdd_locked_run "$sentinel" _autopilot_locked_dispatch "$root" "$run_id" "$@"
}

_autopilot_locked_dispatch() {
  local root="$1" run_id="$2"
  shift 2
  _autopilot_storage_safe "$root" "$run_id" || return 2
  "$@"
}

# All schema and transition decisions live in one worker so every caller uses
# the same closed vocabulary and canonical payload digest.
_autopilot_node() {
  # Every worker mode has a closed positional schema. Convert every filesystem
  # operand before native Node starts, then disable MSYS argv rewriting so
  # spaces, apostrophes, and path-list punctuation cannot influence transport.
  local mode="${1:-}" native index
  shift || return 3
  local args=("$@") path_indexes=()
  # The workspace root is deliberately NOT a member of any path_indexes list —
  # not because the worker never touches it (it does: `workspaceRootIndex` below
  # canonicalizes and lstats it), but because `_autopilot_native_project_path`
  # rejects any path outside the project root, and a git worktree may legitimately
  # live elsewhere. The value travels through three layers instead: git toplevel
  # (semantic) -> `zensu-host-path.sh` (namespace, so `path.resolve` is correct on
  # win32) -> `realpathSync.native` in `workspaceRootIndex` (canonical form).
  case "$mode" in
    read-active) path_indexes=(0 1 2 4) ;;
    read-workspace) path_indexes=(0 1) ;;
    read-run) path_indexes=(0 2) ;;
    begin) path_indexes=(0 1 2 3 6 10) ;;
    apply) path_indexes=(0 1 2 7) ;;
    release) path_indexes=(0 1 4 6) ;;
    team-review-receipt-meta) path_indexes=(0) ;;
    increment-budget|increment-budget-capped) path_indexes=(0 1 2 5) ;;
    *) return 3 ;;
  esac
  for index in "${path_indexes[@]}"; do
    [ "$index" -lt "${#args[@]}" ] || return 3
    native="$(_autopilot_native_project_path "${args[$index]}")" || return 2
    args[$index]="$native"
  done
  MSYS2_ARG_CONV_EXCL='*' node - "$mode" "${args[@]}" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const MAX_BYTES = 1024 * 1024;
const MAX_EVENTS = 512;
const args = process.argv.slice(2);
const mode = args.shift();

const fail = (code, message) => {
  if (message) process.stderr.write(`[zensu-autopilot-state] ${message}\n`);
  process.exit(code);
};
const projectRootIndex = Object.freeze({
  "read-active": 2,
  "read-workspace": 1,
  "read-run": 2,
  begin: 6,
  apply: 7,
  release: 4,
  "increment-budget": 5,
  "increment-budget-capped": 5,
})[mode];
if (projectRootIndex !== undefined) {
  const requestedProjectRoot = args[projectRootIndex];
  if (typeof requestedProjectRoot !== "string" || requestedProjectRoot.length === 0
      || /[\u0000-\u001f]/.test(requestedProjectRoot)) {
    fail(3, "invalid physical project root");
  }
  try {
    const canonicalProjectRoot = fs.realpathSync.native(path.resolve(requestedProjectRoot));
    const stat = fs.lstatSync(canonicalProjectRoot);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail(2, "unsafe physical project root");
    args[projectRootIndex] = canonicalProjectRoot;
  } catch (_) {
    fail(2, "physical project root is unavailable");
  }
}
const workspaceRootIndex = Object.freeze({
  begin: 9,
  "read-workspace": 2,
  release: 7,
})[mode];
if (workspaceRootIndex !== undefined) {
  const requested = args[workspaceRootIndex];
  if (typeof requested !== "string" || requested.length === 0
      || /[\u0000-\u001f]/.test(requested)) {
    fail(3, "invalid workspace root");
  }
  try {
    const canonical = fs.realpathSync.native(path.resolve(requested));
    const stat = fs.lstatSync(canonical);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail(2, "unsafe workspace root");
    args[workspaceRootIndex] = canonical;
  } catch (_) {
    fail(2, "workspace root is unavailable");
  }
}
const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
const exact = (value, keys) => isObject(value)
  && Object.keys(value).length === keys.length
  && keys.every(key => Object.prototype.hasOwnProperty.call(value, key));
const identifier = value => typeof value === "string"
  && value.length >= 3 && value.length <= 128 && /^[A-Za-z0-9][A-Za-z0-9_.:-]*$/.test(value);
const nullableIdentifier = value => value === null || identifier(value);
// Hook session ids predate the durable schema and may be shorter than an
// `identifier`; this mirrors `_autopilot_session_id_ok` in the shell half.
const sessionIdentifier = value => typeof value === "string"
  && value.length >= 1 && value.length <= 128 && /^[A-Za-z0-9_-]+$/.test(value);
const nonEmpty = (value, max = 512) => typeof value === "string" && value.length > 0 && value.length <= max
  && !/[\u0000-\u001f]/.test(value);
const sha = value => typeof value === "string" && /^[a-fA-F0-9]{7,64}$/.test(value);
const sha256 = value => typeof value === "string" && /^[a-fA-F0-9]{64}$/.test(value);
const natural = value => Number.isSafeInteger(value) && value >= 0;
const positive = value => Number.isSafeInteger(value) && value > 0;

const STAGES = new Set([
  "PLANNING", "AWAIT_TDD", "TDD_RUNNING", "GATES", "CONVERGE", "OPEN_PR",
  "TEAM_REVIEW", "FIX_FINDINGS", "VALIDATE", "COVER", "DELIVER", "BLOCKED",
  "DONE", "CANCELLED",
]);
const TERMINAL = new Set(["DONE", "CANCELLED"]);
const STOP_TERMINAL = new Set(["DONE", "BLOCKED", "CANCELLED"]);
// The run record predates workspace scoping, so the field is accepted in both
// shapes rather than added to one strict key set: a record minted by an older
// installation stays readable, and `readRunInventory` therefore cannot fail an
// entire project closed on the release that introduces it.
const STATE_KEYS = ["schemaVersion", "runId", "projectRoot", "ownerSessionId", "stage", "nextActionCode",
  "approvedPlanSha256", "options", "tdd", "effects", "evidence", "blocked", "bypasses", "stopBudget", "events"];
const STATE_KEYS_WORKSPACE = [...STATE_KEYS, "workspaceRoot"];
const workspaceOf = state => state.workspaceRoot;
// One tree CONTAINING the other makes them ONE resource: a worktree under the
// project root drives the same branch, history and pull request. The key is a
// git toplevel resolved from the CALLING process's cwd, and the writer and the
// gates are different processes, so an equality alone answers "free" in
// whichever direction the two spellings disagree — including the git-failure
// fallback, which yields the project root while a working resolve yields the
// repository toplevel above it.
// `path.relative`, not a `/` literal: both operands are canonicalized with
// `fs.realpathSync.native`, which spells win32 paths with backslashes, so a
// hardcoded separator would silently degrade this back to the equality it
// replaces on the one platform the namespace hazard lives on. Total over
// non-strings on purpose — `.startsWith` on a malformed record would throw,
// node would exit 1, and the standalone gate reads 1 as "no holder".
const contains = (outer, inner) => {
  if (!(typeof outer === "string" && typeof inner === "string")) return false;
  const rel = path.relative(outer, inner);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
};
// A record without the field held the whole PROJECT before this change, and the
// new keys are git toplevels — so comparing it against `projectRoot` would make
// it stop holding its own tree whenever the project root sits below the
// repository root. It therefore holds every workspace in its project until it
// is rewritten with the field.
// A record that cannot state its tree holds every tree, exactly as a record
// that never carried the field does. Failing closed here is what keeps a
// malformed value from reading as "the tree is free".
const mayHoldWorkspace = (state, workspaceRoot) =>
  !Object.prototype.hasOwnProperty.call(state, "workspaceRoot")
  || typeof workspaceOf(state) !== "string"
  || contains(workspaceOf(state), workspaceRoot)
  || contains(workspaceRoot, workspaceOf(state));
const RETURN_STAGES = new Set(["GATES", "CONVERGE", "FIX_FINDINGS", "VALIDATE", "COVER"]);
const HEAD_UPDATE_STAGES = new Set(["FIX_FINDINGS", "VALIDATE", "COVER"]);
const NEXT_ACTION = Object.freeze({
  PLANNING: "AWAIT_PLAN_APPROVAL",
  AWAIT_TDD: "START_TDD",
  TDD_RUNNING: "AWAIT_TDD_CHAIN",
  GATES: "RUN_GATES",
  CONVERGE: "RUN_CONVERGENCE",
  OPEN_PR: "RECONCILE_PR",
  TEAM_REVIEW: "RECONCILE_TEAM_REVIEW",
  FIX_FINDINGS: "FIX_REVIEW_FINDINGS",
  VALIDATE: "VALIDATE_FEATURE",
  COVER: "RUN_COVERAGE",
  DELIVER: "DELIVER_PR",
  BLOCKED: "AWAIT_RESUME",
  DONE: "NONE",
  CANCELLED: "NONE",
});
const EVENT_TYPES = new Set([
  "START", "PLAN_APPROVED", "TDD_STARTED", "TDD_CHAIN_DONE", "GATES_PASSED",
  "GATES_FAILED", "CONVERGENCE_PASSED", "CONVERGENCE_FAILED", "PR_OPEN_REQUESTED",
  "PR_OPENED", "TEAM_REVIEW_REQUESTED", "TEAM_REVIEW_PUBLISHED", "FIX_REQUIRED",
  "FINDINGS_CLEARED", "VALIDATION_FAILED", "VALIDATION_PASSED", "COVERAGE_FAILED",
  "COVERAGE_PASSED", "PR_HEAD_UPDATED", "DELIVERY_COMPLETE", "BLOCK", "RESUME", "CANCEL",
  "BYPASS_RECORDED",
]);

const canonical = value => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (isObject(value)) return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  return JSON.stringify(value);
};
const digest = payload => crypto.createHash("sha256").update(canonical(payload)).digest("hex");
const rawDigest = value => crypto.createHash("sha256").update(value).digest("hex");
const teamReviewOperationKey = (runId, headSha) =>
  `team-review:v1:${digest({ headSha: headSha.toLowerCase(), runId })}`;
const parseReviewMarker = marker => {
  if (typeof marker !== "string") return null;
  const match = /^<!-- zensu-review:v1:([a-f0-9]{64}):([a-f0-9]{64}):([a-f0-9]{7,64}):([1-9][0-9]{0,5}):part=1\/([1-9][0-9]{0,5}) -->$/.exec(marker);
  if (!match || match[4] !== match[5]) return null;
  return { opDigest: match[1], payloadDigest: match[2], headSha: match[3], partCount: Number(match[4]) };
};
const reviewMarkerMatches = (marker, operationKey, headSha, expectedPayloadDigest = null, expectedPartCount = null) => {
  const parsed = parseReviewMarker(marker);
  return parsed !== null && parsed.opDigest === rawDigest(operationKey)
    && sameSha(parsed.headSha, headSha) && Number.isSafeInteger(parsed.partCount)
    && (expectedPayloadDigest === null || parsed.payloadDigest === expectedPayloadDigest)
    && (expectedPartCount === null || parsed.partCount === expectedPartCount);
};

const regularFile = file => {
  let stat;
  try { stat = fs.lstatSync(file); }
  catch (error) {
    if (error.code === "ENOENT") return null;
    fail(2, `cannot inspect ${path.basename(file)}`);
  }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > MAX_BYTES) {
    fail(2, `unsafe state file ${path.basename(file)}`);
  }
  return stat;
};
const readJson = (file, absentCode = 1) => {
  if (!regularFile(file)) fail(absentCode, `state file absent: ${path.basename(file)}`);
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (_) { fail(2, `invalid JSON in ${path.basename(file)}`); }
};
const writeOutput = (file, value) => {
  const stat = regularFile(file);
  if (!stat) fail(5, "output file was not pre-created securely");
  const body = `${JSON.stringify(value, null, 2)}\n`;
  if (Buffer.byteLength(body) > MAX_BYTES) fail(2, "state exceeds 1 MiB");
  let fd;
  try {
    fs.writeFileSync(file, body, { encoding: "utf8", mode: 0o600 });
    fd = fs.openSync(file, "r+");
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
  } catch (_) {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
    fail(5, "failed to write state output");
  }
};

const payloadValid = (type, payload) => {
  if (!isObject(payload)) return false;
  switch (type) {
    case "START":
    case "CONVERGENCE_PASSED":
    case "RESUME":
    case "CANCEL":
      return exact(payload, []);
    case "PLAN_APPROVED":
      return exact(payload, ["approvedPlanSha256"]) && sha256(payload.approvedPlanSha256);
    case "TDD_STARTED":
      return exact(payload, ["attempt", "chainId", "sessionId"])
        && positive(payload.attempt) && identifier(payload.chainId) && identifier(payload.sessionId);
    case "TDD_CHAIN_DONE":
      return exact(payload, ["attempt", "chainId", "sessionId", "outcome"])
        && positive(payload.attempt) && identifier(payload.chainId) && identifier(payload.sessionId)
        && ["pass", "no-changes", "max-rounds"].includes(payload.outcome);
    case "GATES_PASSED":
    case "VALIDATION_PASSED":
    case "COVERAGE_PASSED":
    case "DELIVERY_COMPLETE":
      return exact(payload, ["headSha"]) && sha(payload.headSha);
    case "GATES_FAILED":
    case "VALIDATION_FAILED":
    case "COVERAGE_FAILED":
      return exact(payload, ["headSha", "reason"]) && sha(payload.headSha) && nonEmpty(payload.reason);
    case "CONVERGENCE_FAILED":
      return exact(payload, ["reason", "limitReached"])
        && nonEmpty(payload.reason) && typeof payload.limitReached === "boolean";
    case "PR_OPEN_REQUESTED":
      return exact(payload, ["operationKey"]) && nonEmpty(payload.operationKey, 256);
    case "TEAM_REVIEW_REQUESTED":
      return (exact(payload, ["operationKey"])
          || (exact(payload, ["operationKey", "provider"])
            && ["github", "gitlab"].includes(payload.provider)))
        && nonEmpty(payload.operationKey, 256);
    case "PR_OPENED":
      return exact(payload, ["operationKey", "pr"]) && nonEmpty(payload.operationKey, 256)
        && exact(payload.pr, ["number", "url", "headSha"]) && positive(payload.pr.number)
        && nonEmpty(payload.pr.url, 2048) && /^https:\/\//.test(payload.pr.url) && sha(payload.pr.headSha);
    case "TEAM_REVIEW_PUBLISHED":
      return (exact(payload, ["operationKey", "marker", "headSha"])
          || (exact(payload, ["operationKey", "marker", "headSha", "provider"])
            && ["github", "gitlab"].includes(payload.provider)))
        && nonEmpty(payload.operationKey, 256) && parseReviewMarker(payload.marker) !== null && sha(payload.headSha);
    case "FIX_REQUIRED":
      return exact(payload, ["headSha", "unresolvedCount"])
        && sha(payload.headSha) && positive(payload.unresolvedCount);
    case "FINDINGS_CLEARED":
      return exact(payload, ["headSha", "unresolvedCount"])
        && sha(payload.headSha) && payload.unresolvedCount === 0;
    case "PR_HEAD_UPDATED":
      return exact(payload, ["previousHeadSha", "headSha", "gatesPassed", "pushCompleted"])
        && sha(payload.previousHeadSha) && sha(payload.headSha)
        && payload.gatesPassed === true && payload.pushCompleted === true;
    case "BLOCK":
      return exact(payload, ["code"]) && identifier(payload.code);
    case "BYPASS_RECORDED":
      return exact(payload, ["gate"]) && identifier(payload.gate);
    default:
      return false;
  }
};

const effectValid = value => exact(value, ["status", "operationKey"])
  && ["none", "requested", "completed"].includes(value.status)
  && (value.operationKey === null || nonEmpty(value.operationKey, 256))
  && (value.status === "none" ? value.operationKey === null : value.operationKey !== null);
const teamReviewEffectValid = value => exact(value, ["status", "operationKey", "provider"])
  && ["none", "requested", "completed"].includes(value.status)
  && (value.operationKey === null || nonEmpty(value.operationKey, 256))
  && (value.provider === null || ["github", "gitlab"].includes(value.provider))
  && (value.status === "none"
    ? value.operationKey === null && value.provider === null
    : value.operationKey !== null);
const evidenceHead = (value, kind) => value === null || (exact(value, [kind, "headSha"])
  && value[kind] === true && sha(value.headSha));
const reviewEvidenceValid = value => {
  if (value === null) return true;
  if (!exact(value, ["published", "marker", "headSha", "payloadDigest", "partCount", "provider"])
      || value.published !== true || !sha(value.headSha) || !sha256(value.payloadDigest)
      || !positive(value.partCount) || value.partCount > 999999
      || !(value.provider === null || ["github", "gitlab"].includes(value.provider))) return false;
  const parsed = parseReviewMarker(value.marker);
  return parsed !== null && sameSha(parsed.headSha, value.headSha)
    && parsed.payloadDigest === value.payloadDigest && parsed.partCount === value.partCount;
};
const evidenceValid = evidence => exact(evidence, ["pr", "gates", "review", "findings", "validation", "coverage", "delivery"])
  && (evidence.pr === null || (exact(evidence.pr, ["number", "url", "headSha"])
    && positive(evidence.pr.number) && nonEmpty(evidence.pr.url, 2048)
    && /^https:\/\//.test(evidence.pr.url) && sha(evidence.pr.headSha)))
  && (evidence.gates === null || (exact(evidence.gates, ["passed", "headSha"])
    && typeof evidence.gates.passed === "boolean" && sha(evidence.gates.headSha)))
  && reviewEvidenceValid(evidence.review)
  && (evidence.findings === null || (exact(evidence.findings, ["cleared", "headSha", "unresolvedCount"])
    && typeof evidence.findings.cleared === "boolean" && sha(evidence.findings.headSha)
    && natural(evidence.findings.unresolvedCount)))
  && evidenceHead(evidence.validation, "passed")
  && evidenceHead(evidence.coverage, "passed")
  && evidenceHead(evidence.delivery, "completed");

const eventValid = event => exact(event, ["eventId", "eventType", "payloadDigest", "payload", "fromStage", "toStage"])
  && identifier(event.eventId) && EVENT_TYPES.has(event.eventType) && sha256(event.payloadDigest)
  && payloadValid(event.eventType, event.payload) && digest(event.payload) === event.payloadDigest
  && (event.fromStage === null || STAGES.has(event.fromStage)) && STAGES.has(event.toStage)
  && (event.eventType === "START" ? event.fromStage === null && event.toStage === "PLANNING" : event.fromStage !== null);

const sameSha = (left, right) => typeof left === "string" && typeof right === "string"
  && left.toLowerCase() === right.toLowerCase();
const originalPrHead = state => {
  const opened = state.events.find(event => event.eventType === "PR_OPENED");
  return opened && opened.payload && opened.payload.pr && opened.payload.pr.headSha;
};
const teamReviewOperationKeyForState = state => {
  const head = originalPrHead(state);
  return head ? teamReviewOperationKey(state.runId, head) : null;
};
const reviewBelongsToPrGeneration = state => {
  const prIndex = state.events.findIndex(event => event.eventType === "PR_OPENED");
  const reviewIndex = state.events.findIndex(event => event.eventType === "TEAM_REVIEW_PUBLISHED");
  if (prIndex < 0 || reviewIndex <= prIndex || !state.evidence.pr || !state.evidence.review) return false;
  const prEvent = state.events[prIndex];
  const reviewEvent = state.events[reviewIndex];
  const parsedReviewMarker = parseReviewMarker(reviewEvent.payload.marker);
  if (state.effects.prOpen.operationKey !== prEvent.payload.operationKey
    || state.effects.teamReview.operationKey !== reviewEvent.payload.operationKey
    || state.evidence.pr.number !== prEvent.payload.pr.number
    || state.evidence.pr.url !== prEvent.payload.pr.url
    || state.evidence.review.marker !== reviewEvent.payload.marker
    || !parsedReviewMarker
    || state.evidence.review.payloadDigest !== parsedReviewMarker.payloadDigest
    || state.evidence.review.partCount !== parsedReviewMarker.partCount
    || state.effects.teamReview.provider !== state.evidence.review.provider
    || state.evidence.review.provider !== (["github", "gitlab"].includes(reviewEvent.payload.provider)
      ? reviewEvent.payload.provider : null)
    || !sameSha(state.evidence.review.headSha, reviewEvent.payload.headSha)
    || !sameSha(reviewEvent.payload.headSha, prEvent.payload.pr.headSha)) return false;

  let currentHead = prEvent.payload.pr.headSha;
  for (const event of state.events.slice(prIndex + 1)) {
    if (event.eventType !== "PR_HEAD_UPDATED") continue;
    if (!sameSha(event.payload.previousHeadSha, currentHead)
      || sameSha(event.payload.headSha, currentHead)
      || event.payload.gatesPassed !== true || event.payload.pushCompleted !== true) return false;
    currentHead = event.payload.headSha;
  }
  return sameSha(state.evidence.pr.headSha, currentHead);
};

const deliveryInvariants = state => {
  const head = state.evidence.pr && state.evidence.pr.headSha;
  return Boolean(
    state.effects.prOpen.status === "completed"
    && state.effects.teamReview.status === "completed"
    && state.evidence.pr && state.evidence.gates && state.evidence.gates.passed
    && state.evidence.review && state.evidence.review.published
    && state.evidence.findings && state.evidence.findings.cleared
    && state.evidence.findings.unresolvedCount === 0
    && reviewBelongsToPrGeneration(state)
    && sameSha(state.evidence.gates.headSha, head)
    && sameSha(state.evidence.findings.headSha, head)
    && (!state.options.validate || (state.evidence.validation && state.evidence.validation.passed
      && sameSha(state.evidence.validation.headSha, head)))
    && (!state.options.cover || (state.evidence.coverage && state.evidence.coverage.passed
      && sameSha(state.evidence.coverage.headSha, head)))
    && ["pass", "no-changes"].includes(state.tdd.outcome)
  );
};

let semanticHistoryValid;
const stateValid = state => {
  if (!exact(state, STATE_KEYS) && !exact(state, STATE_KEYS_WORKSPACE)) return false;
  if (state.schemaVersion !== 1 || !identifier(state.runId) || !nonEmpty(state.projectRoot, 4096)
    || !identifier(state.ownerSessionId) || !STAGES.has(state.stage) || state.nextActionCode !== NEXT_ACTION[state.stage]) return false;
  if (Object.prototype.hasOwnProperty.call(state, "workspaceRoot") && !nonEmpty(state.workspaceRoot, 4096)) return false;
  if (!(state.approvedPlanSha256 === null || sha256(state.approvedPlanSha256))) return false;
  if (!exact(state.options, ["cover", "validate"]) || typeof state.options.cover !== "boolean"
    || typeof state.options.validate !== "boolean") return false;
  if (!exact(state.tdd, ["attempt", "chainId", "sessionId", "returnStage", "outcome", "headUpdateRequired"])
    || !natural(state.tdd.attempt) || !nullableIdentifier(state.tdd.chainId) || !nullableIdentifier(state.tdd.sessionId)
    || !(state.tdd.returnStage === null || RETURN_STAGES.has(state.tdd.returnStage))
    || !(state.tdd.outcome === null || ["pass", "no-changes", "max-rounds"].includes(state.tdd.outcome))
    || typeof state.tdd.headUpdateRequired !== "boolean") return false;
  if (!exact(state.effects, ["prOpen", "teamReview"]) || !effectValid(state.effects.prOpen)
    || !teamReviewEffectValid(state.effects.teamReview) || !evidenceValid(state.evidence)) return false;
  if (state.effects.teamReview.status !== "none") {
    if (!state.evidence.pr || state.effects.teamReview.operationKey !== teamReviewOperationKeyForState(state)) return false;
    if (state.effects.teamReview.status === "requested" && state.evidence.review !== null) return false;
    if (state.effects.teamReview.status === "completed"
      && (!state.evidence.review || !reviewMarkerMatches(state.evidence.review.marker,
        state.effects.teamReview.operationKey, state.evidence.review.headSha,
        state.evidence.review.payloadDigest, state.evidence.review.partCount)
        || state.evidence.review.provider !== state.effects.teamReview.provider)) return false;
  } else if (state.evidence.review !== null) return false;
  if (!exact(state.blocked, ["from", "code"])
    || !(state.blocked.from === null || STAGES.has(state.blocked.from))
    || !(state.blocked.code === null || identifier(state.blocked.code))) return false;
  if (state.stage === "BLOCKED" ? state.blocked.from === null || state.blocked.code === null
    : state.blocked.from !== null || state.blocked.code !== null) return false;
  if (state.tdd.headUpdateRequired) {
    const pendingStage = state.stage === "BLOCKED" ? state.blocked.from : state.stage;
    if (!HEAD_UPDATE_STAGES.has(pendingStage) || state.tdd.returnStage !== pendingStage
      || !["pass", "no-changes"].includes(state.tdd.outcome)) return false;
  }
  if (!Array.isArray(state.bypasses) || state.bypasses.length > 128
    || !state.bypasses.every(item => exact(item, ["gate", "stage"]) && identifier(item.gate) && STAGES.has(item.stage))) return false;
  if (!exact(state.stopBudget, ["stage", "count"]) || state.stopBudget.stage !== state.stage
    || !natural(state.stopBudget.count)) return false;
  if (!Array.isArray(state.events) || state.events.length < 1 || state.events.length > MAX_EVENTS
    || !state.events.every(eventValid)) return false;
  const ids = new Set();
  for (let index = 0; index < state.events.length; index += 1) {
    const event = state.events[index];
    if (ids.has(event.eventId)) return false;
    ids.add(event.eventId);
    if (index > 0 && event.fromStage !== state.events[index - 1].toStage) return false;
  }
  if (state.events[0].eventType !== "START" || state.events[state.events.length - 1].toStage !== state.stage) return false;
  if (!semanticHistoryValid(state)) return false;
  if (state.stage === "DONE" && (!state.evidence.delivery || !deliveryInvariants(state))) return false;
  return true;
};

const pointerValid = pointer => exact(pointer, ["schemaVersion", "runId"])
  && pointer.schemaVersion === 1 && identifier(pointer.runId);
const readState = (file, absentCode = 2) => {
  // A run referenced by an already-valid active pointer is not "no active
  // run" when its file disappears; it is a corrupt torn state. Direct
  // read-run lookups may opt back into rc=1 for a genuinely unknown id.
  const state = readJson(file, absentCode);
  // PR #174 wrote schemaVersion 1 review evidence with only
  // published/marker/headSha. Normalize that deployed shape (and the brief
  // five-field development shape) from its already-validated marker before
  // running the current exact-schema and semantic-history checks. Historical
  // events intentionally remain byte-identical, so their payload digests stay
  // valid and replay supplies provider=null for the legacy receipt.
  if (isObject(state.effects) && isObject(state.effects.teamReview)
      && exact(state.effects.teamReview, ["status", "operationKey"])) {
    const requestEvent = Array.isArray(state.events)
      ? state.events.find(event => event && event.eventType === "TEAM_REVIEW_REQUESTED") : null;
    const publishEvent = Array.isArray(state.events)
      ? state.events.find(event => event && event.eventType === "TEAM_REVIEW_PUBLISHED") : null;
    const provider = requestEvent && isObject(requestEvent.payload)
      && ["github", "gitlab"].includes(requestEvent.payload.provider)
      ? requestEvent.payload.provider
      : (publishEvent && isObject(publishEvent.payload)
        && ["github", "gitlab"].includes(publishEvent.payload.provider)
        ? publishEvent.payload.provider : null);
    state.effects.teamReview = { ...state.effects.teamReview, provider };
  }
  if (isObject(state.evidence) && isObject(state.evidence.review)) {
    const review = state.evidence.review;
    const legacyThree = exact(review, ["published", "marker", "headSha"]);
    const legacyFive = exact(review, ["published", "marker", "headSha", "payloadDigest", "partCount"]);
    if (legacyThree || legacyFive) {
      const parsed = parseReviewMarker(review.marker);
      if (parsed) {
        const receiptEvent = Array.isArray(state.events)
          ? [...state.events].reverse().find(event => event && event.eventType === "TEAM_REVIEW_PUBLISHED")
          : null;
        const provider = receiptEvent && isObject(receiptEvent.payload)
          && ["github", "gitlab"].includes(receiptEvent.payload.provider)
          ? receiptEvent.payload.provider : null;
        state.evidence.review = {
          published: review.published,
          marker: review.marker,
          headSha: review.headSha,
          payloadDigest: legacyFive ? review.payloadDigest : parsed.payloadDigest,
          partCount: legacyFive ? review.partCount : parsed.partCount,
          provider,
        };
      }
    }
  }
  if (!stateValid(state)) fail(2, `state schema invalid: ${path.basename(file)}`);
  return state;
};
// The owner-keyed pointer name, and the pre-scoping one. Both spellings live
// here so the worker can resolve a run's pointer from the run record alone.
const OWNER_POINTER_PREFIX = "autopilot-active-";
const LEGACY_POINTER_NAME = "autopilot-active.json";
const activePointerFor = (stateDir, ownerSessionId, runId) => {
  const ownerFile = path.join(stateDir, `${OWNER_POINTER_PREFIX}${rawDigest(ownerSessionId)}.json`);
  if (regularFile(ownerFile)) return readPointer(ownerFile);
  const legacyFile = path.join(stateDir, LEGACY_POINTER_NAME);
  if (!regularFile(legacyFile)) return null;
  const legacy = readPointer(legacyFile);
  return legacy.runId === runId ? legacy : null;
};
const readPointer = file => {
  const pointer = readJson(file);
  if (!pointerValid(pointer)) fail(2, "active pointer schema invalid");
  return pointer;
};
// The skip decision is taken on an attacker-writable file, so it routes through
// the SAME chokepoint every other read uses. Without this an oversized file is
// read whole, a symlink is followed off-tree, and a FIFO blocks the read while
// the project lease is held. `regularFile` fails closed on an unsafe file and
// returns null on a genuine ENOENT; either way the record stays unattributable
// and reaches the ordinary fail-closed path instead of being skipped.
const rawOwnerOf = file => {
  if (!regularFile(file)) return null;
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    return isObject(parsed) && typeof parsed.ownerSessionId === "string"
      ? parsed.ownerSessionId : null;
  } catch (_) { return null; }
};
const readRunInventory = (stateDir, expectedProjectRoot, ownerSessionId = "") => {
  let names;
  try { names = fs.readdirSync(stateDir, { encoding: "utf8" }); }
  catch (_) { fail(2, "cannot inspect Autopilot run inventory"); }

  const envelope = /^autopilot-run-(.*)\.json$/;
  return names.sort().flatMap(name => {
    const match = envelope.exec(name);
    if (!match) return [];
    if (!identifier(match[1])) fail(2, `invalid run inventory artifact: ${name}`);
    // A record this caller provably does not own is skipped before validation.
    // Anything unattributable still fails closed: we cannot prove it is not
    // ours, so it is judged as before.
    if (ownerSessionId) {
      const owner = rawOwnerOf(path.join(stateDir, name));
      if (owner !== null && owner !== ownerSessionId) return [];
    }
    const state = readState(path.join(stateDir, name));
    if (state.runId !== match[1] || state.projectRoot !== expectedProjectRoot) {
      fail(2, `run inventory identity mismatch: ${name}`);
    }
    return [state];
  });
};

const move = (state, stage) => {
  state.stage = stage;
  state.nextActionCode = NEXT_ACTION[stage];
  state.stopBudget = { stage, count: 0 };
};
const headMatchesPr = (state, headSha) => !state.evidence.pr || sameSha(state.evidence.pr.headSha, headSha);
const toAwaitTdd = (state, returnStage) => {
  state.tdd.returnStage = returnStage;
  state.tdd.chainId = null;
  state.tdd.sessionId = null;
  state.tdd.outcome = null;
  state.tdd.headUpdateRequired = false;
  move(state, "AWAIT_TDD");
};

const transition = (state, type, payload, reject = fail) => {
  const from = state.stage;
  if (type === "CANCEL") {
    if (TERMINAL.has(from)) reject(3, "terminal run cannot be cancelled again");
    state.tdd.headUpdateRequired = false;
    state.blocked = { from: null, code: null };
    move(state, "CANCELLED");
    return;
  }
  if (type === "BLOCK") {
    if (STOP_TERMINAL.has(from)) reject(3, "run cannot be blocked from this stage");
    state.blocked = { from, code: payload.code };
    move(state, "BLOCKED");
    return;
  }
  if (type === "RESUME") {
    if (from !== "BLOCKED") reject(3, "RESUME requires BLOCKED");
    const target = state.blocked.from;
    state.blocked = { from: null, code: null };
    move(state, target);
    return;
  }
  if (type === "BYPASS_RECORDED") {
    if (TERMINAL.has(from)) reject(3, "terminal run cannot record a bypass");
    state.bypasses.push({ gate: payload.gate, stage: from });
    return;
  }
  if (state.tdd.headUpdateRequired && type !== "PR_HEAD_UPDATED") {
    reject(4, "a successful fix must record the pushed, gated PR head before reusing phase evidence");
  }

  switch (`${from}:${type}`) {
    case "PLANNING:PLAN_APPROVED":
      state.approvedPlanSha256 = payload.approvedPlanSha256.toLowerCase();
      state.tdd.returnStage = "GATES";
      move(state, "AWAIT_TDD");
      return;
    case "AWAIT_TDD:TDD_STARTED":
      if (payload.attempt !== state.tdd.attempt + 1) reject(4, "TDD attempt is stale or skipped");
      if (!RETURN_STAGES.has(state.tdd.returnStage)) reject(2, "TDD return stage is missing");
      state.tdd.attempt = payload.attempt;
      state.tdd.chainId = payload.chainId;
      state.tdd.sessionId = payload.sessionId;
      state.tdd.outcome = null;
      state.tdd.headUpdateRequired = false;
      move(state, "TDD_RUNNING");
      return;
    case "TDD_RUNNING:TDD_CHAIN_DONE":
      if (payload.attempt !== state.tdd.attempt || payload.chainId !== state.tdd.chainId
        || payload.sessionId !== state.tdd.sessionId) reject(4, "TDD completion does not own the active attempt");
      state.tdd.outcome = payload.outcome;
      state.tdd.headUpdateRequired = false;
      if (payload.outcome === "max-rounds") {
        state.blocked = { from: "AWAIT_TDD", code: "TDD_MAX_ROUNDS" };
        move(state, "BLOCKED");
      } else {
        state.tdd.headUpdateRequired = HEAD_UPDATE_STAGES.has(state.tdd.returnStage);
        move(state, state.tdd.returnStage);
      }
      return;
    case "GATES:GATES_PASSED":
      state.evidence.gates = { passed: true, headSha: payload.headSha.toLowerCase() };
      move(state, "CONVERGE");
      return;
    case "GATES:GATES_FAILED":
      state.evidence.gates = { passed: false, headSha: payload.headSha.toLowerCase() };
      toAwaitTdd(state, "GATES");
      return;
    case "CONVERGE:CONVERGENCE_PASSED":
      move(state, "OPEN_PR");
      return;
    case "CONVERGE:CONVERGENCE_FAILED":
      if (payload.limitReached) {
        state.blocked = { from: "CONVERGE", code: "CONVERGENCE_LIMIT" };
        move(state, "BLOCKED");
      } else {
        toAwaitTdd(state, "CONVERGE");
      }
      return;
    case "OPEN_PR:PR_OPEN_REQUESTED":
      if (state.effects.prOpen.status !== "none") reject(4, "PR open operation already requested");
      state.effects.prOpen = { status: "requested", operationKey: payload.operationKey };
      return;
    case "OPEN_PR:PR_OPENED":
      if (state.effects.prOpen.status !== "requested"
        || state.effects.prOpen.operationKey !== payload.operationKey) reject(4, "PR open operation key mismatch");
      if (state.evidence.gates && state.evidence.gates.headSha !== payload.pr.headSha) reject(4, "PR head differs from gate evidence");
      state.effects.prOpen = { status: "completed", operationKey: payload.operationKey };
      state.evidence.pr = { number: payload.pr.number, url: payload.pr.url, headSha: payload.pr.headSha.toLowerCase() };
      move(state, "TEAM_REVIEW");
      return;
    case "TEAM_REVIEW:TEAM_REVIEW_REQUESTED":
      if (state.effects.teamReview.status !== "none") reject(4, "team review already requested");
      if (!state.evidence.pr
        || payload.operationKey !== teamReviewOperationKeyForState(state)) {
        reject(4, "team-review operation key is not bound to this run and PR head");
      }
      state.effects.teamReview = {
        status: "requested",
        operationKey: payload.operationKey,
        provider: ["github", "gitlab"].includes(payload.provider) ? payload.provider : null,
      };
      return;
    case "TEAM_REVIEW:TEAM_REVIEW_PUBLISHED":
      if (state.effects.teamReview.status !== "requested"
        || state.effects.teamReview.operationKey !== payload.operationKey) reject(4, "team-review operation key mismatch");
      const receiptProvider = ["github", "gitlab"].includes(payload.provider) ? payload.provider : null;
      // Completed legacy v1 history replays with null on both sides. An
      // in-flight legacy request cannot safely learn its forge from the
      // publication receipt: that would let the caller choose the count and
      // remote semantics after the durable capability was created.
      if (state.effects.teamReview.provider !== receiptProvider) {
        reject(4, "team-review provider does not match its durable request");
      }
      if (!headMatchesPr(state, payload.headSha)) reject(4, "team review targets a stale PR head");
      const parsedReviewMarker = parseReviewMarker(payload.marker);
      if (!parsedReviewMarker || !reviewMarkerMatches(payload.marker, payload.operationKey, payload.headSha,
          parsedReviewMarker.payloadDigest, parsedReviewMarker.partCount)) {
        reject(4, "team-review marker does not prove the operation, head, and first publication part");
      }
      state.effects.teamReview = {
        status: "completed",
        operationKey: payload.operationKey,
        provider: state.effects.teamReview.provider,
      };
      state.evidence.review = {
        published: true,
        marker: payload.marker,
        headSha: payload.headSha.toLowerCase(),
        payloadDigest: parsedReviewMarker.payloadDigest,
        partCount: parsedReviewMarker.partCount,
        provider: state.effects.teamReview.provider,
      };
      move(state, "FIX_FINDINGS");
      return;
    case "FIX_FINDINGS:FIX_REQUIRED":
      if (!headMatchesPr(state, payload.headSha)) reject(4, "findings target a stale PR head");
      state.evidence.findings = { cleared: false, headSha: payload.headSha.toLowerCase(), unresolvedCount: payload.unresolvedCount };
      toAwaitTdd(state, "FIX_FINDINGS");
      return;
    case "FIX_FINDINGS:FINDINGS_CLEARED": {
      if (state.effects.teamReview.status !== "completed" || !headMatchesPr(state, payload.headSha)) {
        reject(4, "findings cannot clear before review publication on the current head");
      }
      state.evidence.findings = { cleared: true, headSha: payload.headSha.toLowerCase(), unresolvedCount: 0 };
      move(state, state.options.validate ? "VALIDATE" : (state.options.cover ? "COVER" : "DELIVER"));
      return;
    }
    case "VALIDATE:VALIDATION_FAILED":
      if (!headMatchesPr(state, payload.headSha)) reject(4, "validation targets a stale PR head");
      state.evidence.validation = null;
      toAwaitTdd(state, "VALIDATE");
      return;
    case "VALIDATE:VALIDATION_PASSED":
      if (!headMatchesPr(state, payload.headSha)) reject(4, "validation targets a stale PR head");
      state.evidence.validation = { passed: true, headSha: payload.headSha.toLowerCase() };
      move(state, state.options.cover ? "COVER" : "DELIVER");
      return;
    case "COVER:COVERAGE_FAILED":
      if (!headMatchesPr(state, payload.headSha)) reject(4, "coverage targets a stale PR head");
      state.evidence.coverage = null;
      toAwaitTdd(state, "COVER");
      return;
    case "COVER:COVERAGE_PASSED":
      if (!headMatchesPr(state, payload.headSha)) reject(4, "coverage targets a stale PR head");
      state.evidence.coverage = { passed: true, headSha: payload.headSha.toLowerCase() };
      move(state, "DELIVER");
      return;
    case "FIX_FINDINGS:PR_HEAD_UPDATED":
    case "VALIDATE:PR_HEAD_UPDATED":
    case "COVER:PR_HEAD_UPDATED": {
      if (!state.tdd.headUpdateRequired || state.tdd.returnStage !== from
        || !state.evidence.pr || state.effects.prOpen.status !== "completed") {
        reject(4, "PR head update is not bound to the completed fix attempt");
      }
      const previousHead = payload.previousHeadSha.toLowerCase();
      const nextHead = payload.headSha.toLowerCase();
      if (!sameSha(state.evidence.pr.headSha, previousHead)) reject(4, "PR head update starts from a stale head");
      if (sameSha(previousHead, nextHead)) reject(4, "PR head update must prove a new commit");
      state.evidence.pr.headSha = nextHead;
      state.evidence.gates = { passed: true, headSha: nextHead };
      state.evidence.findings = null;
      state.evidence.validation = null;
      state.evidence.coverage = null;
      state.evidence.delivery = null;
      state.tdd.headUpdateRequired = false;
      move(state, "FIX_FINDINGS");
      return;
    }
    case "DELIVER:DELIVERY_COMPLETE":
      if (!headMatchesPr(state, payload.headSha) || !deliveryInvariants(state)) reject(4, "delivery invariants are incomplete");
      state.evidence.delivery = { completed: true, headSha: payload.headSha.toLowerCase() };
      move(state, "DONE");
      return;
    default:
      reject(3, `event ${type} is not allowed from ${from}`);
  }
};

// Validate the ledger as executable history, not merely as a chain of
// well-shaped from/to labels. Replaying through the same closed transition
// function catches impossible jumps and also proves that every derived state
// field still agrees with the accepted events. stopBudget.count is deliberately
// excluded: Stop increments it under the same lock, but those guard attempts are
// not semantic workflow events.
semanticHistoryValid = state => {
  const first = state.events[0];
  const replay = {
    schemaVersion: 1,
    runId: state.runId,
    projectRoot: state.projectRoot,
    ownerSessionId: state.ownerSessionId,
    stage: "PLANNING",
    nextActionCode: NEXT_ACTION.PLANNING,
    approvedPlanSha256: null,
    options: { cover: state.options.cover, validate: state.options.validate },
    tdd: { attempt: 0, chainId: null, sessionId: null, returnStage: null, outcome: null, headUpdateRequired: false },
    effects: {
      prOpen: { status: "none", operationKey: null },
      teamReview: { status: "none", operationKey: null, provider: null },
    },
    evidence: { pr: null, gates: null, review: null, findings: null, validation: null, coverage: null, delivery: null },
    blocked: { from: null, code: null },
    bypasses: [],
    stopBudget: { stage: "PLANNING", count: 0 },
    events: [first],
  };
  const rejectReplay = (_code, message) => { throw new Error(message || "invalid semantic history"); };
  try {
    for (const event of state.events.slice(1)) {
      if (event.fromStage !== replay.stage) return false;
      transition(replay, event.eventType, event.payload, rejectReplay);
      if (event.toStage !== replay.stage) return false;
      replay.events.push(event);
    }
  } catch (_) {
    return false;
  }
  const derived = value => ({
    stage: value.stage,
    nextActionCode: value.nextActionCode,
    approvedPlanSha256: value.approvedPlanSha256,
    tdd: value.tdd,
    effects: value.effects,
    evidence: value.evidence,
    blocked: value.blocked,
    bypasses: value.bypasses,
    stopBudgetStage: value.stopBudget.stage,
  });
  return canonical(derived(replay)) === canonical(derived(state));
};

if (mode === "read-active") {
  const [activeFile, stateDir, expectedProjectRoot, expectedOwnerSessionId, legacyActiveFile = ""] = args;
  if (!sessionIdentifier(expectedOwnerSessionId)) fail(3, "invalid owner session identity");
  const inventory = readRunInventory(stateDir, expectedProjectRoot, expectedOwnerSessionId);
  // Only this owner's runs are visible here. A nonterminal run owned by another
  // session is neither an orphan nor a hidden run from this caller's position —
  // it is simply not this session's business, which is what lets two sessions
  // hold concurrent runs in one project root.
  const owned = inventory.filter(candidate => candidate.ownerSessionId === expectedOwnerSessionId);
  let pointerFile = activeFile;
  let activeStat = regularFile(activeFile);
  // A pointer minted before owner scoping carries no owner in its name. It is
  // adopted only when the run it references belongs to THIS caller; a legacy
  // pointer owned by anyone else is ignored rather than obeyed, which is what
  // releases a project wedged by a session that no longer exists.
  if (!activeStat && legacyActiveFile) {
    const legacyStat = regularFile(legacyActiveFile);
    if (legacyStat) {
      const legacyPointer = readPointer(legacyActiveFile);
      const legacyRun = inventory.find(candidate => candidate.runId === legacyPointer.runId);
      if (legacyRun && legacyRun.ownerSessionId === expectedOwnerSessionId) {
        pointerFile = legacyActiveFile;
        activeStat = legacyStat;
      }
    }
  }
  if (!activeStat) {
    const orphan = owned.find(state => !TERMINAL.has(state.stage));
    if (orphan) fail(2, `active pointer absent while nonterminal run ${orphan.runId} remains`);
    fail(1, `state file absent: ${path.basename(activeFile)}`);
  }
  const pointer = readPointer(pointerFile);
  const state = inventory.find(candidate => candidate.runId === pointer.runId);
  if (!state) fail(2, "active pointer references a run that is absent or owned by another session");
  if (state.runId !== pointer.runId || state.projectRoot !== expectedProjectRoot) {
    fail(2, "active pointer, run, and physical project root disagree");
  }
  if (state.ownerSessionId !== expectedOwnerSessionId) {
    fail(2, "active pointer references a run owned by another session");
  }
  const hidden = owned.find(candidate => candidate.runId !== pointer.runId
    && !TERMINAL.has(candidate.stage));
  if (hidden) fail(2, `active pointer hides nonterminal run ${hidden.runId}`);
  process.stdout.write(`${JSON.stringify(state, null, 2)}\n`);
  process.exit(0);
}

// Occupancy is the owner-INDEPENDENT question: does any session hold a live run
// in this working tree? It is what the standalone-TDD gate, deferred-review
// adoption, and the contention probe ask — they must not be owner-scoped, or a
// standalone chain could start underneath another session's durable run.
if (mode === "read-workspace") {
  const [stateDir, expectedProjectRoot, workspaceRoot] = args;
  if (!nonEmpty(workspaceRoot, 4096)) fail(3, "invalid workspace root");
  const inventory = readRunInventory(stateDir, expectedProjectRoot);
  const holder = inventory.find(candidate => !TERMINAL.has(candidate.stage)
    && mayHoldWorkspace(candidate, workspaceRoot));
  if (!holder) fail(1, "no nonterminal run holds this workspace");
  process.stdout.write(`${JSON.stringify(holder, null, 2)}\n`);
  process.exit(0);
}

if (mode === "read-run") {
  const [runFile, expectedRunId, expectedProjectRoot] = args;
  const state = readState(runFile, 1);
  if (state.runId !== expectedRunId || state.projectRoot !== expectedProjectRoot) {
    fail(2, "run file identity or physical project root mismatch");
  }
  process.stdout.write(`${JSON.stringify(state, null, 2)}\n`);
  process.exit(0);
}

if (mode === "begin") {
  const [activeFile, runFile, runOutput, activeOutput, runId, ownerSessionId, projectRoot, coverRaw, validateRaw,
    workspaceRoot, legacyActiveFile = ""] = args;
  // `sessionIdentifier`, not `identifier`: the pointer-name derivation and
  // `read-active` both use that vocabulary, and an owner containing `.` or `:`
  // would otherwise be minted here and be unreadable forever after.
  if (!identifier(runId) || !sessionIdentifier(ownerSessionId) || !nonEmpty(projectRoot, 4096)
    || !nonEmpty(workspaceRoot, 4096)
    || !["true", "false"].includes(coverRaw) || !["true", "false"].includes(validateRaw)) fail(3, "invalid begin arguments");
  const options = { cover: coverRaw === "true", validate: validateRaw === "true" };
  const stateDir = path.dirname(activeFile);
  const inventory = readRunInventory(stateDir, projectRoot);
  const owned = inventory.filter(candidate => candidate.ownerSessionId === ownerSessionId);
  let pointerFile = activeFile;
  let activeStat = regularFile(activeFile);
  if (!activeStat && legacyActiveFile) {
    const legacyStat = regularFile(legacyActiveFile);
    if (legacyStat) {
      const legacyPointer = readPointer(legacyActiveFile);
      const legacyRun = inventory.find(candidate => candidate.runId === legacyPointer.runId);
      if (legacyRun && legacyRun.ownerSessionId === ownerSessionId) {
        pointerFile = legacyActiveFile;
        activeStat = legacyStat;
      }
    }
  }
  let pointer = null;
  let activeRun = null;
  if (activeStat) {
    pointer = readPointer(pointerFile);
    activeRun = inventory.find(candidate => candidate.runId === pointer.runId);
    if (!activeRun) fail(2, "active pointer references an absent run");
    if (activeRun.projectRoot !== projectRoot) fail(2, "active run belongs to another physical project root");
    if (activeRun.ownerSessionId !== ownerSessionId) fail(2, "active pointer references a run owned by another session");
  }

  // A torn begin can leave the newly written nonterminal run without its
  // pointer, or behind the prior terminal pointer. Only an identity- and
  // option-exact retry of that sole orphan may finish publication. Any other
  // begin must reject before writing either durable file. Scoped to this
  // owner: another session's live run is not this caller's orphan.
  const hiddenNonterminal = owned.filter(candidate => !TERMINAL.has(candidate.stage)
    && (!pointer || candidate.runId !== pointer.runId));
  if (hiddenNonterminal.length > 0) {
    const recoverable = hiddenNonterminal.length === 1
      && hiddenNonterminal[0].runId === runId
      && (!activeRun || TERMINAL.has(activeRun.stage));
    if (!recoverable) fail(4, `nonterminal orphan ${hiddenNonterminal[0].runId} requires exact recovery`);
  }
  if (pointer && pointer.runId !== runId && !TERMINAL.has(activeRun.stage)) {
    fail(4, `active run ${pointer.runId} is not terminal`);
  }
  // The working tree is the resource two runs would actually collide on —
  // same branch, same commits, same PR. This exclusion is owner-independent
  // and replaces the project-wide one; a foreign holder is nameable, so the
  // refusal points at the command that can release it.
  const workspaceHolder = inventory.find(candidate => candidate.runId !== runId
    && !TERMINAL.has(candidate.stage) && mayHoldWorkspace(candidate, workspaceRoot));
  if (workspaceHolder) {
    fail(4, `workspace held by nonterminal run ${workspaceHolder.runId} (stage ${workspaceHolder.stage}); `
      + `release it with: zensu-log.sh --autopilot-release --run ${workspaceHolder.runId} --confirm`);
  }

  const existing = inventory.find(candidate => candidate.runId === runId);
  if (existing) {
    if (existing.runId !== runId || existing.ownerSessionId !== ownerSessionId
      || existing.projectRoot !== projectRoot || !mayHoldWorkspace(existing, workspaceRoot)
      || canonical(existing.options) !== canonical(options)) fail(4, "run identity/options conflict");
    if (activeStat) {
      if (pointer.runId === runId) process.exit(10);
    }
    writeOutput(runOutput, existing);
    writeOutput(activeOutput, { schemaVersion: 1, runId });
    process.exit(0);
  }
  const startPayload = {};
  const state = {
    schemaVersion: 1,
    runId,
    projectRoot,
    workspaceRoot,
    ownerSessionId,
    stage: "PLANNING",
    nextActionCode: NEXT_ACTION.PLANNING,
    approvedPlanSha256: null,
    options,
    tdd: { attempt: 0, chainId: null, sessionId: null, returnStage: null, outcome: null, headUpdateRequired: false },
    effects: {
      prOpen: { status: "none", operationKey: null },
      teamReview: { status: "none", operationKey: null, provider: null },
    },
    evidence: { pr: null, gates: null, review: null, findings: null, validation: null, coverage: null, delivery: null },
    blocked: { from: null, code: null },
    bypasses: [],
    stopBudget: { stage: "PLANNING", count: 0 },
    events: [{
      eventId: "start",
      eventType: "START",
      payloadDigest: digest(startPayload),
      payload: startPayload,
      fromStage: null,
      toStage: "PLANNING",
    }],
  };
  if (!stateValid(state)) fail(2, "initial state failed internal validation");
  writeOutput(runOutput, state);
  writeOutput(activeOutput, { schemaVersion: 1, runId });
  process.exit(0);
}

if (mode === "apply") {
  const [stateDir, runFile, runOutput, runId, eventId, eventType, payloadJson, expectedProjectRoot,
    expectedOwnerSessionId = ""] = args;
  if (!identifier(runId) || !identifier(eventId) || !EVENT_TYPES.has(eventType) || eventType === "START") fail(3, "invalid event identity/type");
  let payload;
  try { payload = JSON.parse(payloadJson); } catch (_) { fail(3, "event payload is not JSON"); }
  if (!payloadValid(eventType, payload)) fail(3, `invalid payload for ${eventType}`);
  const state = readState(runFile);
  if (state.runId !== runId || state.projectRoot !== expectedProjectRoot) {
    fail(2, "run file identity or physical project root mismatch");
  }
  // The pointer that has to designate this run is its OWNER's, resolved from
  // the run record rather than from the caller: an event may legitimately be
  // applied by a hook that supplies no caller identity at all.
  const pointer = activePointerFor(stateDir, state.ownerSessionId, runId);
  if (!pointer || pointer.runId !== runId) fail(4, "event does not target the active run");
  if (expectedOwnerSessionId && state.ownerSessionId !== expectedOwnerSessionId) {
    fail(4, "event caller does not own the active run");
  }
  const payloadDigest = digest(payload);
  const prior = state.events.find(event => event.eventId === eventId);
  if (prior) {
    if (prior.eventType === eventType && prior.payloadDigest === payloadDigest) process.exit(10);
    fail(4, `eventId conflict: ${eventId}`);
  }
  // Legacy provider-less request/publication events remain readable and
  // exactly replayable for schemaVersion 1 history. Every genuinely new
  // request binds the provider before the remote effect, and publication must
  // repeat that provider for locked receipt attestation.
  if (["TEAM_REVIEW_REQUESTED", "TEAM_REVIEW_PUBLISHED"].includes(eventType)
      && !["github", "gitlab"].includes(payload.provider)) {
    fail(3, `${eventType} requires a provider-bound payload`);
  }
  if (TERMINAL.has(state.stage)) fail(3, "terminal run rejects new events");
  // Reserve two final audit slots: one for a fail-closed BLOCK and one for the
  // explicit CANCEL that can retire that blocked generation. At exhaustion a
  // RESUME is deliberately rejected because it would create a live run with no
  // remaining terminal slot.
  if (state.events.length >= MAX_EVENTS - 2 && !["BLOCK", "CANCEL"].includes(eventType)) {
    fail(4, "event ledger exhausted; only BLOCK followed by CANCEL may be recorded");
  }
  if (state.events.length >= MAX_EVENTS) fail(4, "event ledger exhausted");
  const fromStage = state.stage;
  transition(state, eventType, payload);
  state.events.push({ eventId, eventType, payloadDigest, payload, fromStage, toStage: state.stage });
  if (!stateValid(state)) fail(2, "transition produced invalid state");
  writeOutput(runOutput, state);
  process.exit(0);
}

// Release is the ONE path that cancels a run the caller does not own. It
// bypasses exactly one check — the ownership comparison — and nothing else:
// the transition, the ledger bound, the schema check and the atomic write are
// the ordinary ones. Provenance is the event id, which the writer prefixes
// `release-`; the CANCEL payload stays the empty object the ledger schema
// already accepts, so a released run remains readable by any runtime that can
// read an ordinary cancellation. No state field is added and no bypass-ledger
// entry is written: this escapes no gate, it terminates a run.
if (mode === "release") {
  const [runFile, runOutput, runId, eventId, expectedProjectRoot, callerSessionId,
    stateDir, callerWorkspace, ownerActivityTtlHours] = args;
  if (!identifier(runId) || !identifier(eventId) || !sessionIdentifier(callerSessionId)
    || !nonEmpty(stateDir, 4096) || !nonEmpty(callerWorkspace, 4096)) {
    fail(3, "invalid release arguments");
  }
  const state = readState(runFile);
  if (state.runId !== runId || state.projectRoot !== expectedProjectRoot) {
    fail(2, "run file identity or physical project root mismatch");
  }
  const payload = {};
  const payloadDigest = digest(payload);
  // Idempotency is decided before the terminal check so an interrupted
  // release that already landed reports success rather than "already
  // terminal", which reads like a refusal.
  const prior = state.events.find(event => event.eventId === eventId);
  if (prior) {
    if (prior.eventType === "CANCEL" && prior.payloadDigest === payloadDigest) process.exit(10);
    fail(4, `eventId conflict: ${eventId}`);
  }
  if (TERMINAL.has(state.stage)) fail(3, "terminal run cannot be released");
  // A run id is an ordinary filename in a listable directory, so "take the id
  // from a refusal" is not a scope control. The tree the caller stands in is:
  // the refusal that hands out the id is workspace-derived, so scoping here
  // costs the documented workflow nothing and removes enumerate-and-kill.
  if (!mayHoldWorkspace(state, callerWorkspace)) {
    fail(6, "run does not hold the caller's working tree; release it from the tree it holds");
  }
  if (state.ownerSessionId === callerSessionId) {
    // The ordinary CANCEL path resolves the owner pointer and refuses when none
    // designates the run, so refusing the owner here too leaves a torn `begin`
    // with no exit at all. Refuse only while that path can still work.
    const ownerPointer = activePointerFor(stateDir, state.ownerSessionId, runId);
    if (ownerPointer && ownerPointer.runId === runId) {
      fail(4, "caller owns this run; cancel it through the ordinary event path");
    }
  } else {
    // Liveness, from a signal this repository already keeps: the owner IS the
    // Session Control key, so its workflow document names the owning session and
    // its mtime says when that session last acted. No state field is added.
    const ttlHours = Number(ownerActivityTtlHours);
    if (Number.isFinite(ttlHours) && ttlHours > 0) {
      const ownerActivity = regularFile(path.join(stateDir, `tdd-phase-${state.ownerSessionId}.json`));
      if (ownerActivity) {
        // Bounded in BOTH directions: a future mtime yields a negative age that
        // never crosses the bound, which would make the run permanently
        // unreleasable — and the mtime is operator-settable.
        const ageMs = Date.now() - ownerActivity.mtimeMs;
        if (ageMs >= 0 && ageMs < ttlHours * 3600000) {
          fail(7, "the owning session is still active; ask it to cancel, or wait for it to go stale");
        }
      }
    }
  }
  if (state.events.length >= MAX_EVENTS) fail(4, "event ledger exhausted");
  const fromStage = state.stage;
  transition(state, "CANCEL", payload);
  state.events.push({ eventId, eventType: "CANCEL", payloadDigest, payload, fromStage, toStage: state.stage });
  if (!stateValid(state)) fail(2, "transition produced invalid state");
  writeOutput(runOutput, state);
  process.exit(0);
}

if (mode === "team-review-receipt-meta") {
  const [runFile, expectedRunId, eventId] = args;
  const state = readState(runFile);
  const event = state.events[state.events.length - 1];
  const review = state.evidence.review;
  if (state.runId !== expectedRunId || !event || event.eventId !== eventId
      || event.eventType !== "TEAM_REVIEW_PUBLISHED" || !review
      || event.payload.marker !== review.marker || event.payload.headSha.toLowerCase() !== review.headSha
      || event.payload.operationKey !== state.effects.teamReview.operationKey
      || !reviewMarkerMatches(review.marker, event.payload.operationKey, event.payload.headSha,
        review.payloadDigest, review.partCount)) fail(4, "candidate team-review receipt is inconsistent");
  process.stdout.write(JSON.stringify({
    operationKey: event.payload.operationKey,
    headSha: review.headSha,
    payloadDigest: review.payloadDigest,
    partCount: review.partCount,
    provider: review.provider,
  }));
  process.exit(0);
}

if (mode === "increment-budget") {
  const [stateDir, runFile, runOutput, runId, expectedStage, expectedProjectRoot,
    expectedOwnerSessionId = ""] = args;
  const state = readState(runFile);
  const pointer = activePointerFor(stateDir, state.ownerSessionId, runId);
  if (!pointer || pointer.runId !== runId) fail(4, "budget does not target the active run");
  if (state.runId !== runId || state.projectRoot !== expectedProjectRoot
    || state.stage !== expectedStage || STOP_TERMINAL.has(state.stage)) {
    fail(4, "stop budget stage is stale or terminal");
  }
  if (expectedOwnerSessionId && state.ownerSessionId !== expectedOwnerSessionId) {
    fail(4, "stop-budget caller does not own the active run");
  }
  state.stopBudget.count += 1;
  if (!stateValid(state)) fail(2, "budget increment produced invalid state");
  writeOutput(runOutput, state);
  process.stdout.write(String(state.stopBudget.count));
  process.exit(0);
}

if (mode === "increment-budget-capped") {
  const [stateDir, runFile, runOutput, runId, expectedStage, expectedProjectRoot,
    expectedOwnerSessionId, capRaw, blockCode] = args;
  const cap = Number(capRaw);
  if (!natural(cap) || !identifier(blockCode)) fail(3, "invalid capped-budget arguments");
  const state = readState(runFile);
  const pointer = activePointerFor(stateDir, state.ownerSessionId, runId);
  if (!pointer || pointer.runId !== runId) fail(4, "capped budget does not target the active run");
  if (state.runId !== runId || state.projectRoot !== expectedProjectRoot
    || state.stage !== expectedStage || STOP_TERMINAL.has(state.stage)) {
    fail(4, "capped stop budget stage is stale or terminal");
  }
  if (expectedOwnerSessionId && state.ownerSessionId !== expectedOwnerSessionId) {
    fail(4, "capped stop-budget caller does not own the active run");
  }
  const count = state.stopBudget.count + 1;
  state.stopBudget.count = count;
  let blocked = false;
  if (count > cap) {
    if (state.events.length >= MAX_EVENTS) fail(4, "event ledger exhausted before capped BLOCK");
    const payload = { code: blockCode };
    const fromStage = state.stage;
    const eventId = `outer-block-${crypto.createHash("sha256").update(canonical([
      runId, expectedStage, count, blockCode, state.events.length,
    ])).digest("hex")}`;
    transition(state, "BLOCK", payload);
    state.events.push({
      eventId,
      eventType: "BLOCK",
      payloadDigest: digest(payload),
      payload,
      fromStage,
      toStage: state.stage,
    });
    blocked = true;
  }
  if (!stateValid(state)) fail(2, "capped budget mutation produced invalid state");
  writeOutput(runOutput, state);
  process.stdout.write(JSON.stringify({ count, blocked }));
  process.exit(0);
}

fail(3, `unknown worker mode: ${mode || "(empty)"}`);
NODE
}

_autopilot_begin_critical() {
  local root="$1" run_id="$2" owner_session_id="$3" cover="$4" validate="$5"
  local workspace_root="${6:-}"
  [ -n "$workspace_root" ] || workspace_root="$(_autopilot_session_workspace "$root")" || return 2
  local state_dir="$root/.zensu/state"
  local run_file="$state_dir/autopilot-run-${run_id}.json"
  local active_file legacy_file
  active_file="$(_autopilot_active_path "$state_dir" "$owner_session_id")" || return 3
  legacy_file="$(_autopilot_legacy_active_path "$state_dir")" || return 3
  local run_tmp active_tmp rc
  # `_autopilot_storage_safe` covers the legacy pointer by name; the
  # owner-keyed one is validated here, at the only site that writes it.
  CLAUDE_PROJECT_DIR="$root" _tdd_path_safe "$active_file" regular-or-absent || return 2
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  active_tmp="$(_autopilot_mktemp_beside "$active_file")" || { rm -f "$run_tmp"; return 5; }
  _autopilot_node begin "$active_file" "$run_file" "$run_tmp" "$active_tmp" \
    "$run_id" "$owner_session_id" "$root" "$cover" "$validate" "$workspace_root" "$legacy_file"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    rm -f "$run_tmp" "$active_tmp"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp" "$active_tmp"
    return "$rc"
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp" "$active_tmp"; return 5; }
  _tdd_atomic_replace_regular "$active_tmp" "$active_file" || { rm -f "$active_tmp"; return 5; }
}

autopilot_begin_run() {
  local run_id="${1:-}" owner_session_id="${2:-}" root cover validate workspace_root session_workspace root_rendered
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$owner_session_id" || return 3
  root="$(_autopilot_project_root "${3:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  cover="${4:-false}"
  validate="${5:-true}"
  case "$cover:$validate" in
    true:true|true:false|false:true|false:false) ;;
    *) return 3 ;;
  esac
  # Default the workspace to the working tree the caller is standing in. A
  # session that begins from the project root therefore keeps exactly the
  # pre-change exclusion; a session working inside a worktree gets its own.
  workspace_root="${6:-}"
  if [ -n "$workspace_root" ]; then
    workspace_root="$(autopilot_workspace_root "$workspace_root")" || return 2
    # A declared workspace that names neither the session's own resolved tree
    # nor a directory under the project root would record a key nothing else
    # can claim while the run's commits still land elsewhere, which defeats the
    # only remaining collision guard. Accepted narrowing: a git worktree
    # OUTSIDE the project root can no longer be declared.
    session_workspace="$(_autopilot_session_workspace "$root")" || return 2
    # Both sides of the containment test must be in ONE namespace: the workspace
    # arrives host-rendered, so the project root is rendered by the same helper
    # rather than compared in its shell spelling.
    root_rendered="$(_autopilot_rendered_dir "$root")" || root_rendered="$root"
    if [ "$workspace_root" != "$session_workspace" ]; then
      case "$workspace_root" in
        "$root_rendered"|"$root_rendered"/*) ;;
        *) return 3 ;;
      esac
    fi
  else
    workspace_root="$(_autopilot_session_workspace "$root")" || return 2
  fi
  case "$workspace_root" in *[$'\n\r']*) return 3 ;; esac
  _autopilot_prepare_storage "$root" || return 2
  _autopilot_locked_run "$root" "$run_id" _autopilot_begin_critical \
    "$root" "$run_id" "$owner_session_id" "$cover" "$validate" "$workspace_root"
}

_autopilot_attest_team_review_publication_critical() {
  local root="$1" run_id="$2" run_tmp="$3" event_id="$4"
  local meta tuple operation_key head_sha expected_digest part_count provider snapshot actual_receipt
  meta="$(_autopilot_node team-review-receipt-meta "$run_tmp" "$run_id" "$event_id")" || return $?
  tuple="$(printf '%s' "$meta" | node -e '
    let value;try{value=JSON.parse(require("fs").readFileSync(0,"utf8"));}catch(_){process.exit(2);}
    if(!value||typeof value!=="object"||Array.isArray(value)
        ||!/^team-review:v1:[a-f0-9]{64}$/.test(value.operationKey||"")
        ||!/^[a-f0-9]{7,64}$/.test(value.headSha||"")
        ||!/^[a-f0-9]{64}$/.test(value.payloadDigest||"")
        ||!Number.isSafeInteger(value.partCount)||value.partCount<1||value.partCount>999999
        ||!["github","gitlab"].includes(value.provider))process.exit(2);
    process.stdout.write([value.operationKey,value.headSha,value.payloadDigest,String(value.partCount),value.provider].join("|"));
  ' 2>/dev/null)" || return 2
  IFS='|' read -r operation_key head_sha expected_digest part_count provider <<< "$tuple"
  [ -n "$operation_key" ] && [ -n "$head_sha" ] && [ -n "$expected_digest" ] \
    && [ -n "$part_count" ] && [ -n "$provider" ] || return 2
  snapshot="$(_autopilot_read_team_review_payload_critical \
    "$root" "$run_id" "$operation_key" "$head_sha" "$provider")" || return $?
  actual_receipt="$(_autopilot_team_review_payload_inspect \
    "$snapshot" "$head_sha" true receipt "$provider")" || return $?
  [ "$actual_receipt" = "$expected_digest|$part_count" ] || return 4
}

_autopilot_apply_critical() {
  local root="$1" run_id="$2" event_id="$3" event_type="$4" payload_json="$5"
  local caller_session_id="${6:-}"
  local state_dir="$root/.zensu/state"
  local run_file="$state_dir/autopilot-run-${run_id}.json"
  local run_tmp rc
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  _autopilot_node apply "$state_dir" "$run_file" "$run_tmp" "$run_id" "$event_id" "$event_type" "$payload_json" "$root" "$caller_session_id"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    rm -f "$run_tmp"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$rc"
  fi
  if [ "$event_type" = TEAM_REVIEW_PUBLISHED ]; then
    _autopilot_attest_team_review_publication_critical \
      "$root" "$run_id" "$run_tmp" "$event_id"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$run_tmp"
      return "$rc"
    fi
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp"; return 5; }
}

autopilot_apply_event() {
  local run_id="${1:-}" event_id="${2:-}" event_type="${3:-}" payload_json="${4:-}" root
  local caller_session_id="${6:-}"
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$event_id" || return 3
  if [ -n "$caller_session_id" ]; then
    _autopilot_identifier_ok "$caller_session_id" || return 3
  fi
  root="$(_autopilot_project_root "${5:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_apply_critical \
    "$root" "$run_id" "$event_id" "$event_type" "$payload_json" "$caller_session_id"
}

autopilot_read_run() {
  local run_id="${1:-}" root run_file
  _autopilot_identifier_ok "$run_id" || return 2
  root="$(_autopilot_project_root "${2:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  run_file="$root/.zensu/state/autopilot-run-${run_id}.json"
  _autopilot_node read-run "$run_file" "$run_id" "$root"
}

_autopilot_read_active_critical() {
  local root="$1" owner="$2" state_dir="$1/.zensu/state" active_file legacy_file
  active_file="$(_autopilot_active_path "$state_dir" "$owner")" || return 3
  legacy_file="$(_autopilot_legacy_active_path "$state_dir")" || return 3
  _autopilot_node read-active "$active_file" "$state_dir" "$root" "$owner" "$legacy_file"
}

_autopilot_read_workspace_critical() {
  local root="$1" workspace="$2" state_dir="$1/.zensu/state"
  _autopilot_node read-workspace "$state_dir" "$root" "$workspace"
}

autopilot_read_active() {
  local root owner="${2:-}"
  root="$(_autopilot_project_root "${1:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_session_id_ok "$owner" || return 3
  _autopilot_read_storage_ready "$root" || return $?
  # Read the pointer and full run inventory under the same project-wide lock
  # as begin. A healthy begin publishes run then pointer with two renames; a
  # concurrent hook must wait for both rather than diagnosing that brief,
  # intentional window as an orphan. If begin crashes, the lock is released
  # and the durable partial publication is then classified fail-closed.
  _autopilot_locked_run "$root" "" _autopilot_read_active_critical "$root" "$owner"
}

_autopilot_release_critical() {
  local root="$1" run_id="$2" event_id="$3" caller_session_id="$4"
  local caller_workspace="$5" ttl_hours="$6"
  local state_dir="$root/.zensu/state"
  local run_file="$state_dir/autopilot-run-${run_id}.json"
  local run_tmp rc
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  _autopilot_node release "$run_file" "$run_tmp" "$run_id" "$event_id" "$root" "$caller_session_id" \
    "$state_dir" "$caller_workspace" "$ttl_hours"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    rm -f "$run_tmp"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$rc"
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp"; return 5; }
}

# Cancel a nonterminal run owned by ANOTHER session. It runs under the same
# project lock as every other writer, so it cannot race a live owner mid-event;
# the owner's own pointer is left untouched and simply comes to designate a
# terminal run, which every reader already handles.
autopilot_release_run() {
  local run_id="${1:-}" event_id="${2:-}" root caller_session_id="${4:-}"
  local caller_workspace ttl_hours
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$event_id" || return 3
  _autopilot_session_id_ok "$caller_session_id" || return 3
  root="$(_autopilot_project_root "${3:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  caller_workspace="$(_autopilot_session_workspace "$root")" || return 2
  ttl_hours="$(zensu_pending_review_ttl_hours 2>/dev/null)" || ttl_hours=""
  case "$ttl_hours" in *[!0-9]*|'') ttl_hours=0 ;; esac
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_release_critical \
    "$root" "$run_id" "$event_id" "$caller_session_id" "$caller_workspace" "$ttl_hours"
}

# Chain ids share the 128-character durable identifier contract, while the
# event ids that carry them must also remain within that same bound. Preserve
# the readable legacy id for ordinary chains and switch only oversized
# composites to a deterministic digest.
autopilot_chain_event_id() {
  local kind="${1:-}" chain_id="${2:-}" prefix candidate digest
  _autopilot_identifier_ok "$chain_id" || return 3
  case "$kind" in
    start)  prefix="tdd-started" ;;
    done)   prefix="tdd-done" ;;
    rearm)  prefix="review-rearm-resume" ;;
    *) return 3 ;;
  esac
  candidate="${prefix}-${chain_id}"
  if [ "${#candidate}" -le 128 ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  digest="$(printf '%s' "$chain_id" | node -e '
    const crypto=require("crypto"),fs=require("fs");
    process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(0)).digest("hex"));
  ' 2>/dev/null)" || return 5
  [ "${#digest}" -eq 64 ] || return 5
  printf '%s-%s\n' "$prefix" "$digest"
}

# Produce the only TEAM_REVIEW_REQUESTED operation key accepted by the durable
# transition: a fixed-size digest of the run id plus the original lowercase PR
# head. Callers persist this write-ahead key before attempting remote publish.
autopilot_team_review_operation_key() {
  local run_id="${1:-}" head_sha="${2:-}"
  [ "$#" -eq 2 ] && _autopilot_identifier_ok "$run_id" || return 3
  RUN_ID="$run_id" HEAD_SHA="$head_sha" node -e '
    const crypto=require("crypto");
    const head=process.env.HEAD_SHA;
    if(!/^[a-fA-F0-9]{7,64}$/.test(head))process.exit(3);
    const canonical=value => value && typeof value === "object" && !Array.isArray(value)
      ? `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`
      : JSON.stringify(value);
    const seed={headSha:head.toLowerCase(),runId:process.env.RUN_ID};
    process.stdout.write(`team-review:v1:${crypto.createHash("sha256").update(canonical(seed)).digest("hex")}`);
  ' 2>/dev/null
}

# The delegated review body is a remote-write input, so a crash after the forge
# accepted it must not allow a retry to synthesize different bytes for the same
# operation key. Keep one private immutable snapshot per operation/head pair in
# the project-local durable state directory.
_autopilot_team_review_payload_target() {
  local root="${1:-}" operation_key="${2:-}" head_sha="${3:-}" operation_digest
  [ "$#" -eq 3 ] || return 3
  operation_digest="$(OPERATION_KEY="$operation_key" HEAD_SHA="$head_sha" node -e '
    const crypto = require("crypto");
    const operationKey = process.env.OPERATION_KEY;
    const head = String(process.env.HEAD_SHA || "").toLowerCase();
    if (!/^team-review:v1:[a-f0-9]{64}$/.test(operationKey)
        || !/^[a-f0-9]{7,64}$/.test(head)) process.exit(3);
    process.stdout.write(crypto.createHash("sha256").update(operationKey).digest("hex"));
  ' 2>/dev/null)" || return 3
  [ -n "$root" ] && [ "${#operation_digest}" -eq 64 ] || return 3
  # The operation key already binds the run plus original PR head. Persisting
  # its full 256-bit digest is therefore collision-resistant without spelling
  # the head a second time, and keeps security-critical state below Windows'
  # legacy MAX_PATH boundary for ordinary project roots.
  printf '%s/.zensu/state/autopilot-team-review-payload-%s.json\n' \
    "${root%/}" "$operation_digest"
}

_autopilot_team_review_payload_identity_critical() {
  local root="$1" run_id="$2" operation_key="$3" head_sha="$4" provider="$5"
  local state_dir="$root/.zensu/state" expected_key state owner
  case "$provider" in github|gitlab) ;; *) return 3 ;; esac
  expected_key="$(autopilot_team_review_operation_key "$run_id" "$head_sha")" || return $?
  [ "$operation_key" = "$expected_key" ] || return 4
  # The pointer that must still designate this run is its OWNER's, and the
  # owner is a property of the run rather than of whoever is attesting.
  owner="$(_autopilot_node read-run "$state_dir/autopilot-run-${run_id}.json" "$run_id" "$root" \
    | node -e '
      try { process.stdout.write(JSON.parse(require("fs").readFileSync(0,"utf8")).ownerSessionId); }
      catch (_) { process.exit(2); }
    ' 2>/dev/null)" || return 2
  [ -n "$owner" ] || return 2
  state="$(_autopilot_read_active_critical "$root" "$owner")" || return $?
  printf '%s' "$state" | RUN_ID="$run_id" OPERATION_KEY="$operation_key" \
    HEAD_SHA="$head_sha" PROVIDER="$provider" node -e '
      let state;
      try { state = JSON.parse(require("fs").readFileSync(0, "utf8")); }
      catch (_) { process.exit(2); }
      const head = String(process.env.HEAD_SHA || "").toLowerCase();
      const review = state && state.effects && state.effects.teamReview;
      const pr = state && state.evidence && state.evidence.pr;
      if (!state || state.runId !== process.env.RUN_ID || state.stage !== "TEAM_REVIEW"
          || !review || review.status !== "requested"
          || review.operationKey !== process.env.OPERATION_KEY
          || review.provider !== process.env.PROVIDER
          || !pr || typeof pr.headSha !== "string" || pr.headSha.toLowerCase() !== head
          || (state.evidence && state.evidence.review !== null)) process.exit(4);
    ' 2>/dev/null
}

# Securely inspect a payload. The target variant additionally requires private
# permissions. Reading through O_NOFOLLOW and comparing lstat/fstat identities
# closes the leaf-swap window and rejects hard-linked files.
_autopilot_team_review_payload_inspect() {
  local payload_file="${1:-}" head_sha="${2:-}" private="${3:-false}" digest_mode="${4:-raw}" provider="${5:-}"
  local native_payload_file env_exclusions
  [ "$#" -ge 3 ] && [ "$#" -le 5 ] || return 3
  case "$private" in true|false) ;; *) return 3 ;; esac
  case "$digest_mode" in raw|canonical) [ -z "$provider" ] || return 3 ;; receipt) case "$provider" in github|gitlab) ;; *) return 3 ;; esac ;; *) return 3 ;; esac
  native_payload_file="$(_autopilot_native_path "$payload_file")" || return 2
  env_exclusions="$(_autopilot_msys_env_exclusions PAYLOAD_FILE)" || return 2
  MSYS2_ENV_CONV_EXCL="$env_exclusions" PAYLOAD_FILE="$native_payload_file" HEAD_SHA="$head_sha" PRIVATE="$private" DIGEST_MODE="$digest_mode" \
    PROVIDER="$provider" node -e '
    const fs = require("fs");
    const crypto = require("crypto");
    const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
      ? fs.constants.O_NOFOLLOW : 0;
    const max = 8 * 1024 * 1024;
    const file = process.env.PAYLOAD_FILE;
    const head = String(process.env.HEAD_SHA || "").toLowerCase();
    const requirePrivate = process.env.PRIVATE === "true";
    const unsafe = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
    const fail = code => process.exit(code);
    const validate = data => {
      let payload;
      try { payload = JSON.parse(data.toString("utf8")); } catch (_) { fail(2); }
      if (!payload || Array.isArray(payload) || typeof payload !== "object") fail(2);
      const keys = Object.keys(payload).sort().join(",");
      if (keys !== "body,comments,commit_id,event") fail(2);
      if (typeof payload.body !== "string" || unsafe.test(payload.body)
          || payload.body.includes("zensu-review:v1")
          || !["COMMENT", "APPROVE", "REQUEST_CHANGES"].includes(payload.event)
          || typeof payload.commit_id !== "string"
          || payload.commit_id.toLowerCase() !== head
          || !Array.isArray(payload.comments) || payload.comments.length > 999998) fail(2);
      for (const comment of payload.comments) {
        if (!comment || Array.isArray(comment) || typeof comment !== "object"
            || !Object.keys(comment).every(key =>
              ["body", "path", "line", "side", "start_line", "start_side"].includes(key))
            || typeof comment.body !== "string" || unsafe.test(comment.body)
            || comment.body.includes("zensu-review:v1")
            || typeof comment.path !== "string" || !comment.path || unsafe.test(comment.path)
            || comment.path.includes("zensu-review:v1")) fail(2);
        if (comment.side != null && !["LEFT", "RIGHT"].includes(comment.side)) fail(2);
        if (comment.line != null && (!Number.isSafeInteger(comment.line) || comment.line < 1)) fail(2);
        const hasStartLine = comment.start_line != null;
        const hasStartSide = comment.start_side != null;
        if (hasStartLine !== hasStartSide) fail(2);
        if (hasStartLine && (!Number.isSafeInteger(comment.start_line) || comment.start_line < 1
            || !Number.isSafeInteger(comment.line) || comment.start_line > comment.line
            || !["LEFT", "RIGHT"].includes(comment.start_side)
            || comment.start_side !== comment.side)) fail(2);
      }
      return payload;
    };
    const canonical = value => {
      if (value === null || typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
      if (typeof value === "number") {
        if (!Number.isFinite(value)) fail(2);
        return JSON.stringify(value);
      }
      if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
      if (typeof value === "object") {
        return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
      }
      fail(2);
    };
    const privateMode = stat => process.platform === "win32" || (stat.mode & 0o777) === 0o600;
    let fd;
    try {
      const before = fs.lstatSync(file);
      if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1
          || before.size < 1 || before.size > max
          || (requirePrivate && !privateMode(before))) fail(2);
      fd = fs.openSync(file, fs.constants.O_RDONLY | noFollow);
      const opened = fs.fstatSync(fd);
      if (!opened.isFile() || opened.nlink !== 1 || opened.dev !== before.dev
          || opened.ino !== before.ino || opened.size !== before.size
          || (requirePrivate && !privateMode(opened))) fail(2);
      const data = fs.readFileSync(fd);
      const after = fs.fstatSync(fd);
      fs.closeSync(fd); fd = undefined;
      if (data.length !== opened.size || after.dev !== opened.dev || after.ino !== opened.ino
          || after.nlink !== 1 || after.size !== opened.size
          || after.mtimeMs !== opened.mtimeMs || after.ctimeMs !== opened.ctimeMs) fail(2);
      const payload = validate(data);
      const canonicalDigest = crypto.createHash("sha256").update(canonical(payload)).digest("hex");
      if (process.env.DIGEST_MODE === "receipt") {
        const count = process.env.PROVIDER === "github" ? 1 : payload.comments.length + 1;
        if (!Number.isSafeInteger(count) || count < 1 || count > 999999) fail(2);
        process.stdout.write(`${canonicalDigest}|${count}`);
      } else {
        const digestInput = process.env.DIGEST_MODE === "canonical" ? canonical(payload) : data;
        process.stdout.write(crypto.createHash("sha256").update(digestInput).digest("hex"));
      }
    } catch (_) {
      if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} }
      fail(2);
    }
  ' 2>/dev/null
}

# Recover the sole crash shape produced by the atomic no-replace publication:
# link(temp, target) succeeded, but the process died before unlink(temp). This
# runs only while the project-wide Autopilot lock is held. Exactly two links
# must exist and both must be the deterministic target plus one mktemp-shaped
# sibling pointing at the same private inode. Anything ambiguous stays
# fail-closed and untouched.
_autopilot_recover_team_review_payload_alias() {
  local target="${1:-}" native_target env_exclusions
  [ "$#" -eq 1 ] && [ -n "$target" ] || return 3
  native_target="$(_autopilot_native_project_path "$target")" || return 2
  env_exclusions="$(_autopilot_msys_env_exclusions TARGET_FILE)" || return 2
  MSYS2_ENV_CONV_EXCL="$env_exclusions" TARGET_FILE="$native_target" node -e '
    const fs = require("fs");
    const path = require("path");
    const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
      ? fs.constants.O_NOFOLLOW : 0;
    const target = process.env.TARGET_FILE;
    const directory = path.dirname(target);
    const basename = path.basename(target);
    const expectedTarget = /^autopilot-team-review-payload-[a-f0-9]{64}\.json$/;
    const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const expectedTemp = new RegExp(`^${escape(basename)}\\.tmp\\.[A-Za-z0-9]{8}$`);
    const privateMode = stat => process.platform === "win32" || (stat.mode & 0o777) === 0o600;
    const privateRegular = stat => stat.isFile() && !stat.isSymbolicLink() && privateMode(stat);
    let targetFd, tempFd, directoryFd;
    const close = fd => { if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} } };
    const fail = code => {
      close(targetFd); close(tempFd); close(directoryFd);
      process.exit(code);
    };
    if (!expectedTarget.test(basename)) fail(3);
    let targetBefore;
    try { targetBefore = fs.lstatSync(target); }
    catch (error) {
      if (error.code === "ENOENT") process.exit(0);
      fail(2);
    }
    if (!privateRegular(targetBefore)) fail(2);
    if (targetBefore.nlink === 1) process.exit(0);
    if (targetBefore.nlink !== 2) fail(2);

    let names, aliases;
    try {
      names = fs.readdirSync(directory).filter(name => expectedTemp.test(name));
      aliases = names.filter(name => {
        const stat = fs.lstatSync(path.join(directory, name));
        return stat.dev === targetBefore.dev && stat.ino === targetBefore.ino;
      });
    } catch (_) { fail(2); }
    // A pre-link crash can leave unrelated private temp files with the same
    // prefix. Ignore and preserve them; only same-inode aliases account for
    // targetBefore.nlink. nlink=2 plus one such alias is the sole healable case.
    if (aliases.length !== 1) fail(2);
    const temp = path.join(directory, aliases[0]);

    try {
      const tempBefore = fs.lstatSync(temp);
      if (!privateRegular(tempBefore) || tempBefore.nlink !== 2
          || tempBefore.dev !== targetBefore.dev || tempBefore.ino !== targetBefore.ino) fail(2);
      targetFd = fs.openSync(target, fs.constants.O_RDONLY | noFollow);
      tempFd = fs.openSync(temp, fs.constants.O_RDONLY | noFollow);
      const targetOpen = fs.fstatSync(targetFd);
      const tempOpen = fs.fstatSync(tempFd);
      if (!privateRegular(targetOpen) || !privateRegular(tempOpen)
          || targetOpen.nlink !== 2 || tempOpen.nlink !== 2
          || targetOpen.dev !== targetBefore.dev || targetOpen.ino !== targetBefore.ino
          || tempOpen.dev !== targetOpen.dev || tempOpen.ino !== targetOpen.ino) fail(2);

      // Re-account both names immediately before removal. nlink=2 plus these
      // two same-inode directory entries proves that no foreign link exists.
      const targetFinal = fs.lstatSync(target);
      const tempFinal = fs.lstatSync(temp);
      if (!privateRegular(targetFinal) || !privateRegular(tempFinal)
          || targetFinal.nlink !== 2 || tempFinal.nlink !== 2
          || targetFinal.dev !== targetOpen.dev || targetFinal.ino !== targetOpen.ino
          || tempFinal.dev !== targetOpen.dev || tempFinal.ino !== targetOpen.ino) fail(2);
      fs.unlinkSync(temp);

      const targetAfterOpen = fs.fstatSync(targetFd);
      const tempAfterOpen = fs.fstatSync(tempFd);
      const targetAfter = fs.lstatSync(target);
      if (!privateRegular(targetAfterOpen) || !privateRegular(tempAfterOpen)
          || !privateRegular(targetAfter) || targetAfterOpen.nlink !== 1
          || tempAfterOpen.nlink !== 1 || targetAfter.nlink !== 1
          || targetAfterOpen.dev !== targetOpen.dev || targetAfterOpen.ino !== targetOpen.ino
          || tempAfterOpen.dev !== targetOpen.dev || tempAfterOpen.ino !== targetOpen.ino
          || targetAfter.dev !== targetOpen.dev || targetAfter.ino !== targetOpen.ino) fail(2);
      close(targetFd); targetFd = undefined;
      close(tempFd); tempFd = undefined;

      // Windows does not support opening directories through fs.openSync.
      // The file/link publication is already durable there; directory fsync
      // is a POSIX-only strengthening step.
      if (process.platform !== "win32") {
        directoryFd = fs.openSync(directory, fs.constants.O_RDONLY);
        try { fs.fsyncSync(directoryFd); } catch (error) {
          if (!["EINVAL", "ENOTSUP", "EBADF"].includes(error.code)) throw error;
        }
        close(directoryFd); directoryFd = undefined;
      }
    } catch (_) { fail(2); }
  ' 2>/dev/null
}

_autopilot_read_team_review_payload_critical() {
  local root="$1" run_id="$2" operation_key="$3" head_sha="$4" provider="$5"
  local state_dir="$root/.zensu/state" target
  _autopilot_team_review_payload_identity_critical \
    "$root" "$run_id" "$operation_key" "$head_sha" "$provider" || return $?
  target="$(_autopilot_team_review_payload_target "$root" "$operation_key" "$head_sha")" \
    || return $?
  CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe "$state_dir" directory || return 2
  _autopilot_recover_team_review_payload_alias "$target" || return $?
  CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe \
    "$state_dir" directory "$target" regular-or-absent || return 2
  [ -e "$target" ] || return 1
  _autopilot_team_review_payload_inspect "$target" "$head_sha" true >/dev/null || return $?
  printf '%s\n' "$target"
}

autopilot_read_team_review_payload() {
  local run_id="${1:-}" operation_key="${2:-}" head_sha="${3:-}" provider="${4:-}" root
  [ "$#" -eq 5 ] && _autopilot_identifier_ok "$run_id" || return 3
  case "$provider" in github|gitlab) ;; *) return 3 ;; esac
  root="$(_autopilot_project_root "${5:-}")" || return 2
  _autopilot_team_review_payload_target "$root" "$operation_key" "$head_sha" \
    >/dev/null || return 3
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_read_team_review_payload_critical \
    "$root" "$run_id" "$operation_key" "$head_sha" "$provider"
}

_autopilot_store_team_review_payload_critical() {
  local root="$1" run_id="$2" operation_key="$3" head_sha="$4" source_file="$5" provider="$6"
  local state_dir="$root/.zensu/state" target tmp rc source_digest target_digest
  local native_source_file native_target native_tmp env_exclusions
  _autopilot_team_review_payload_identity_critical \
    "$root" "$run_id" "$operation_key" "$head_sha" "$provider" || return $?
  target="$(_autopilot_team_review_payload_target "$root" "$operation_key" "$head_sha")" \
    || return $?
  CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe "$state_dir" directory || return 2
  _autopilot_recover_team_review_payload_alias "$target" || return $?
  CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe \
    "$state_dir" directory "$source_file" regular "$target" regular-or-absent || return 2
  source_digest="$(_autopilot_team_review_payload_inspect \
    "$source_file" "$head_sha" false)" || return $?

  # Existing snapshots are immutable. A byte-identical replay is idempotent;
  # every other payload (including unsafe identity/mode changes) is a conflict.
  if [ -e "$target" ]; then
    target_digest="$(_autopilot_team_review_payload_inspect \
      "$target" "$head_sha" true)" || return $?
    [ "$source_digest" = "$target_digest" ] || return 4
    printf '%s\n' "$target"
    return 0
  fi

  tmp="$(mktemp "${target}.tmp.XXXXXXXX" 2>/dev/null)" || return 5
  CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe "$tmp" regular "$target" regular-or-absent \
    || { rm -f "$tmp"; return 2; }
  native_source_file="$(_autopilot_native_path "$source_file")" \
    || { rm -f "$tmp"; return 2; }
  native_target="$(_autopilot_native_project_path "$target")" \
    || { rm -f "$tmp"; return 2; }
  native_tmp="$(_autopilot_native_project_path "$tmp")" \
    || { rm -f "$tmp"; return 2; }
  env_exclusions="$(_autopilot_msys_env_exclusions 'SOURCE_FILE;TARGET_FILE;TEMP_FILE')" \
    || { rm -f "$tmp"; return 2; }
  MSYS2_ENV_CONV_EXCL="$env_exclusions" \
    SOURCE_FILE="$native_source_file" TARGET_FILE="$native_target" TEMP_FILE="$native_tmp" \
    EXPECTED_DIGEST="$source_digest" \
    node -e '
      const fs = require("fs");
      const crypto = require("crypto");
      const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)
        ? fs.constants.O_NOFOLLOW : 0;
      const source = process.env.SOURCE_FILE;
      const target = process.env.TARGET_FILE;
      const temp = process.env.TEMP_FILE;
      let sourceFd, tempFd;
      const close = fd => { if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} } };
      try {
        const sourceBefore = fs.lstatSync(source);
        if (!sourceBefore.isFile() || sourceBefore.isSymbolicLink() || sourceBefore.nlink !== 1) process.exit(2);
        sourceFd = fs.openSync(source, fs.constants.O_RDONLY | noFollow);
        const sourceOpen = fs.fstatSync(sourceFd);
        if (!sourceOpen.isFile() || sourceOpen.nlink !== 1 || sourceOpen.dev !== sourceBefore.dev
            || sourceOpen.ino !== sourceBefore.ino || sourceOpen.size !== sourceBefore.size) process.exit(2);
        const data = fs.readFileSync(sourceFd);
        const sourceAfter = fs.fstatSync(sourceFd);
        close(sourceFd); sourceFd = undefined;
        if (data.length !== sourceOpen.size || sourceAfter.size !== sourceOpen.size
            || sourceAfter.mtimeMs !== sourceOpen.mtimeMs || sourceAfter.ctimeMs !== sourceOpen.ctimeMs) process.exit(2);
        if (crypto.createHash("sha256").update(data).digest("hex") !== process.env.EXPECTED_DIGEST) process.exit(4);

        const tempBefore = fs.lstatSync(temp);
        if (!tempBefore.isFile() || tempBefore.isSymbolicLink() || tempBefore.nlink !== 1) process.exit(2);
        tempFd = fs.openSync(temp, fs.constants.O_WRONLY | noFollow);
        const tempOpen = fs.fstatSync(tempFd);
        if (!tempOpen.isFile() || tempOpen.nlink !== 1 || tempOpen.dev !== tempBefore.dev
            || tempOpen.ino !== tempBefore.ino) process.exit(2);
        fs.ftruncateSync(tempFd, 0);
        fs.fchmodSync(tempFd, 0o600);
        fs.writeFileSync(tempFd, data);
        fs.fsyncSync(tempFd);
        close(tempFd); tempFd = undefined;

        // link(2) is an atomic no-replace publication. EEXIST is never
        // overwritten; the shell revalidates any concurrently published file.
        fs.linkSync(temp, target);
        fs.unlinkSync(temp);
        if (process.platform !== "win32") {
          try {
            const directoryFd = fs.openSync(require("path").dirname(target), fs.constants.O_RDONLY);
            try { fs.fsyncSync(directoryFd); } catch (error) {
              if (!["EINVAL", "ENOTSUP", "EBADF"].includes(error.code)) throw error;
            }
            fs.closeSync(directoryFd);
          } catch (error) {
            if (!["EINVAL", "ENOTSUP", "EBADF"].includes(error.code)) throw error;
          }
        }
      } catch (error) {
        close(sourceFd); close(tempFd);
        if (error && error.code === "EEXIST") process.exit(4);
        process.exit(5);
      }
    ' 2>/dev/null
  rc=$?
  rm -f "$tmp"
  if [ "$rc" -eq 4 ]; then
    CLAUDE_PROJECT_DIR="$root" _tdd_paths_safe "$target" regular-or-absent || return 2
    [ -e "$target" ] || return 4
    target_digest="$(_autopilot_team_review_payload_inspect \
      "$target" "$head_sha" true)" || return $?
    [ "$source_digest" = "$target_digest" ] || return 4
  elif [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  target_digest="$(_autopilot_team_review_payload_inspect \
    "$target" "$head_sha" true)" || return $?
  [ "$source_digest" = "$target_digest" ] || return 4
  printf '%s\n' "$target"
}

autopilot_store_team_review_payload() {
  local run_id="${1:-}" operation_key="${2:-}" head_sha="${3:-}" source_file="${4:-}" \
    provider="${5:-}" root native_source_file env_exclusions
  [ "$#" -eq 6 ] && _autopilot_identifier_ok "$run_id" || return 3
  case "$provider" in github|gitlab) ;; *) return 3 ;; esac
  root="$(_autopilot_project_root "${6:-}")" || return 2
  _autopilot_team_review_payload_target "$root" "$operation_key" "$head_sha" \
    >/dev/null || return 3
  native_source_file="$(_autopilot_native_path "$source_file")" || return 3
  env_exclusions="$(_autopilot_msys_env_exclusions SOURCE_FILE)" || return 3
  MSYS2_ENV_CONV_EXCL="$env_exclusions" SOURCE_FILE="$native_source_file" node -e '
    const path = require("path");
    const source = process.env.SOURCE_FILE;
    const resolved = path.resolve(source || "");
    if (!source || /[\u0000-\u001f]/.test(source) || /[\u0000-\u001f]/.test(resolved)) process.exit(3);
  ' >/dev/null 2>&1 || return 3
  source_file="$(_autopilot_shell_path "$source_file")" || return 3
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_store_team_review_payload_critical \
    "$root" "$run_id" "$operation_key" "$head_sha" "$source_file" "$provider"
}

# Starting a standalone inner generation must serialize with every durable
# outer begin/start. The decision and inner write therefore share the canonical
# Outer -> Inner lock order. BLOCKED is resumable and still owns the WORKSPACE;
# only a workspace no nonterminal run holds permits this unbound generation.
# The question is owner-INDEPENDENT on purpose: a standalone chain must not
# start underneath another session's durable run in the same working tree.
# `read-workspace` already returns the holding record; rendering it here is the
# only way the run id reaches the user. `--autopilot-status` is owner-scoped and
# structurally cannot show a foreign run, and no verb lists holders — so a
# refusal that discards this record names a remedy nobody can carry out.
_autopilot_workspace_refusal() {
  local holder="${1:-}" env_exclusions
  [ -n "$holder" ] || return 1
  env_exclusions="$(_autopilot_msys_env_exclusions HOLDER_JSON)" || return 1
  MSYS2_ENV_CONV_EXCL="$env_exclusions" HOLDER_JSON="$holder" node -e '
    let value;
    try { value = JSON.parse(String(process.env.HOLDER_JSON || "")); } catch { process.exit(1); }
    if (!value || typeof value.runId !== "string" || typeof value.stage !== "string") process.exit(1);
    process.stdout.write(`workspace held by nonterminal run ${value.runId} (stage ${value.stage}); `
      + `release it with: zensu-log.sh --autopilot-release --run ${value.runId} --confirm\n`);
  ' 2>/dev/null </dev/null
}

_autopilot_begin_standalone_tdd_critical() {
  local root="$1" session_id="$2" vanilla="$3" workspace="${4:-}"
  local read_rc holder
  [ -n "$workspace" ] || workspace="$(_autopilot_session_workspace "$root")" || return 2
  if holder="$(_autopilot_read_workspace_critical "$root" "$workspace" 2>/dev/null)"; then
    read_rc=0
  else
    read_rc=$?
  fi
  case "$read_rc" in
    0)
      _autopilot_workspace_refusal "$holder" >&2 || true
      return 4
      ;;
    1) ;;
    *) return "$read_rc" ;;
  esac
  tdd_begin_session "$session_id" "$vanilla" false false ""
}

autopilot_begin_standalone_tdd() {
  local root session_id="${2:-}" vanilla="${3:-false}" workspace
  [ "$#" -eq 3 ] || return 3
  [ -n "$session_id" ] && [ "${#session_id}" -le 128 ] || return 3
  case "$session_id" in *[!A-Za-z0-9_-]*) return 3 ;; esac
  case "$vanilla" in true|false) ;; *) return 3 ;; esac
  root="$(_autopilot_project_root "${1:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  workspace="$(_autopilot_session_workspace "$root")" || return 2
  _autopilot_prepare_storage "$root" || return 2
  _autopilot_locked_run "$root" "" _autopilot_begin_standalone_tdd_critical \
    "$root" "$session_id" "$vanilla" "$workspace"
}

# Deferred-review adoption has the same ownership boundary as a standalone TDD
# begin, but its inner operation first claims the project-wide pending marker.
# Keep the complete lock order Outer project -> pending marker -> Inner session:
# a concurrent durable begin must publish both run and pointer before adoption
# decides, and adoption must finish its claim+seed before the Outer lock releases.
_autopilot_adopt_pending_review_critical() {
  local root="$1" session_id="$2" vanilla="$3" ttl_hours="$4" owner_pid="$5"
  local workspace="${6:-}" read_rc adopt_rc
  [ -n "$workspace" ] || workspace="$(_autopilot_session_workspace "$root")" || return 2
  if _autopilot_read_workspace_critical "$root" "$workspace" >/dev/null 2>&1; then
    read_rc=0
  else
    read_rc=$?
  fi
  case "$read_rc" in
    0) return 4 ;;
    1) ;;
    *) return "$read_rc" ;;
  esac
  if tdd_adopt_pending_review "$session_id" "$vanilla" "$ttl_hours" "$owner_pid"; then
    return 0
  else
    adopt_rc=$?
  fi
  # Keep Outer corruption/unsafe-storage rc=2 distinct from the Inner API's
  # legacy rc=2 meaning "no pending marker or recoverable claim".
  [ "$adopt_rc" -eq 2 ] && return 6
  # rc=1 from the Inner claim/seed operation is a permanent result for this
  # transaction (unsafe marker, storage failure, or Inner-lock failure). Keep
  # it distinct while the Outer lock is still held so the public helper does
  # not mistake it for Outer-lock contention and retry the whole transaction.
  [ "$adopt_rc" -eq 1 ] && return 7
  return "$adopt_rc"
}

# When the Outer lease is saturated, avoid sending every safely losing Stop a
# generic storage-error prompt. This is a read-only proof: check Outer, prove a
# stable foreign plain claim, then check Outer again as the TOCTOU fence. A run
# published after that final absent/terminal read linearizes after this Stop.
_autopilot_deferred_contention_result() {
  local root="$1" session_id="$2" ttl_hours="$3" workspace="${4:-}" read_rc
  [ -n "$workspace" ] || workspace="$(_autopilot_session_workspace "$root")" || return 2
  _autopilot_storage_safe "$root" "" || return 2
  if _autopilot_read_workspace_critical "$root" "$workspace" >/dev/null 2>&1; then
    read_rc=0
  else
    read_rc=$?
  fi
  case "$read_rc" in
    0) return 4 ;;
    1) ;;
    # This unlocked read may observe begin's durable run before its active
    # pointer is published. Storage safety was proven above, so this is
    # inconclusive and must return to the serialized retry path.
    2) return 8 ;;
    *) return "$read_rc" ;;
  esac

  tdd_pending_review_owned_by_other "$session_id" "$ttl_hours" || return 8

  _autopilot_storage_safe "$root" "" || return 2
  if _autopilot_read_workspace_critical "$root" "$workspace" >/dev/null 2>&1; then
    read_rc=0
  else
    read_rc=$?
  fi
  case "$read_rc" in
    0) return 4 ;;
    1) return 6 ;;
    # The final fence can see the same valid run->pointer publication window.
    # Without a conclusive absent/terminal/active result, retry under Outer.
    2) return 8 ;;
    *) return "$read_rc" ;;
  esac
}

autopilot_adopt_pending_review() {
  local root session_id="${2:-}" vanilla="${3:-false}" ttl_hours="${4:-0}"
  local owner_pid="${5:-$$}" lock_attempt=0 rc contention_rc workspace
  [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || return 3
  _autopilot_session_id_ok "$session_id" || return 3
  case "$vanilla" in true|false) ;; *) return 3 ;; esac
  case "$ttl_hours" in ''|*[!0-9]*) return 3 ;; esac
  case "$owner_pid" in ''|*[!0-9]*) return 3 ;; esac
  [ "$owner_pid" -gt 0 ] || return 3
  root="$(_autopilot_project_root "${1:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  workspace="$(_autopilot_session_workspace "$root")" || return 2
  _autopilot_prepare_storage "$root" || return 2
  # The Core lease has a deliberately bounded per-acquisition wait.
  # A burst of Stop hooks can legitimately queue many slow Outer->pending->Inner
  # composites behind one another, so retry that rc=1 transaction as a whole.
  # Claim/seed is idempotent and crash-recoverable; unsafe/corrupt/owned/no-work
  # results have distinct codes and are never retried here.
  while [ "$lock_attempt" -lt 5 ]; do
    if _autopilot_locked_run "$root" "" _autopilot_adopt_pending_review_critical \
        "$root" "$session_id" "$vanilla" "$ttl_hours" "$owner_pid" "$workspace"; then
      return 0
    else
      rc=$?
    fi
    # Preserve the public legacy rc=1 contract for Inner adoption failures,
    # but do not retry them as though the Outer project lock were contended.
    [ "$rc" -eq 7 ] && return 1
    [ "$rc" -eq 1 ] || return "$rc"
    _autopilot_deferred_contention_result "$root" "$session_id" "$ttl_hours" "$workspace"
    contention_rc=$?
    case "$contention_rc" in
      4|6) return "$contention_rc" ;;
      8) ;;
      *) return "$contention_rc" ;;
    esac
    lock_attempt=$((lock_attempt + 1))
  done
  return 1
}

_autopilot_increment_budget_critical() {
  local root="$1" run_id="$2" expected_stage="$3" caller_session_id="${4:-}"
  local state_dir="$root/.zensu/state"
  local run_file="$state_dir/autopilot-run-${run_id}.json"
  local run_tmp result rc
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  result="$(_autopilot_node increment-budget "$state_dir" "$run_file" "$run_tmp" "$run_id" "$expected_stage" "$root" "$caller_session_id")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$rc"
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp"; return 5; }
  printf '%s\n' "$result"
}

autopilot_increment_stop_budget() {
  local run_id="${1:-}" expected_stage="${2:-}" root caller_session_id="${4:-}"
  _autopilot_identifier_ok "$run_id" || return 3
  if [ -n "$caller_session_id" ]; then
    _autopilot_identifier_ok "$caller_session_id" || return 3
  fi
  root="$(_autopilot_project_root "${3:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_increment_budget_critical \
    "$root" "$run_id" "$expected_stage" "$caller_session_id"
}

_autopilot_increment_budget_capped_critical() {
  local root="$1" run_id="$2" expected_stage="$3" caller_session_id="$4"
  local cap="$5" block_code="$6" state_dir="$1/.zensu/state"
  local run_file="$state_dir/autopilot-run-${run_id}.json"
  local run_tmp result rc
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  result="$(_autopilot_node increment-budget-capped "$state_dir" "$run_file" "$run_tmp" \
    "$run_id" "$expected_stage" "$root" "$caller_session_id" "$cap" "$block_code")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$rc"
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp"; return 5; }
  printf '%s\n' "$result"
}

autopilot_increment_stop_budget_capped() {
  local run_id="${1:-}" expected_stage="${2:-}" root caller_session_id="${4:-}"
  local cap="${5:-}" block_code="${6:-}"
  [ "$#" -eq 6 ] || return 3
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$caller_session_id" \
    && _autopilot_identifier_ok "$block_code" || return 3
  case "$cap" in ''|*[!0-9]*) return 3 ;; esac
  root="$(_autopilot_project_root "${3:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_increment_budget_capped_critical \
    "$root" "$run_id" "$expected_stage" "$caller_session_id" "$cap" "$block_code"
}

# Caller already holds the project-wide Outer lock. Derive the BLOCK event id
# from the exact locked generation so crash retries are idempotent and no stale
# caller can choose a later stage accidentally.
_autopilot_apply_block_locked() {
  local root="$1" run_id="$2" block_code="$3" discriminator="$4"
  local run_file="$root/.zensu/state/autopilot-run-${run_id}.json"
  local state generation event_id payload
  state="$(_autopilot_node read-run "$run_file" "$run_id" "$root")" || return $?
  generation="$(printf '%s' "$state" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.stdout.write(`${s.stage}:${s.events.length}`);
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || return 2
  event_id="$(RUN_ID="$run_id" CODE="$block_code" DISC="$discriminator" \
    GENERATION="$generation" node -e '
      const crypto=require("crypto");
      process.stdout.write("outer-block-"+crypto.createHash("sha256").update(JSON.stringify([
        process.env.RUN_ID,process.env.CODE,process.env.DISC,process.env.GENERATION
      ])).digest("hex"));
    ' 2>/dev/null)" || return 5
  payload="$(CODE="$block_code" node -e '
    process.stdout.write(JSON.stringify({code:process.env.CODE}));
  ' 2>/dev/null)" || return 5
  _autopilot_apply_critical "$root" "$run_id" "$event_id" BLOCK "$payload" ""
}

_autopilot_reconcile_stop_inner_critical() {
  local root="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5"
  local return_stage="$6" state_file="$7" snapshot mode outcome payload event_id
  if snapshot="$(tdd_chain_snapshot "$state_file" "$session_id" 2>/dev/null)"; then
    mode="$(printf '%s' "$snapshot" | RUN_ID="$run_id" ATTEMPT="$attempt" \
      CHAIN_ID="$chain_id" RETURN_STAGE="$return_stage" node -e '
        try {
          const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
          const a=s.autopilot;
          const linked=a && a.runId===process.env.RUN_ID
            && String(a.attempt)===process.env.ATTEMPT
            && a.chainId===process.env.CHAIN_ID && a.returnStage===process.env.RETURN_STAGE
            && s.active===true;
          if(!linked)process.exit(3);
          if(s.chainDone===false && (a.outcome==="" || a.outcome==="max-rounds")){
            process.stdout.write("pending");process.exit(0);
          }
          if(s.chainDone===true && s.implComplete===true
              && ["pass","no-changes","max-rounds"].includes(a.outcome)){
            process.stdout.write(`done\t${a.outcome}`);process.exit(0);
          }
          process.exit(3);
        } catch (_) { process.exit(3); }
      ' 2>/dev/null)" || mode="invalid"
  else
    mode="invalid"
  fi

  case "$mode" in
    pending)
      _autopilot_node read-run "$root/.zensu/state/autopilot-run-${run_id}.json" "$run_id" "$root"
      ;;
    done$'\t'*)
      outcome="${mode#*$'\t'}"
      payload="$(ATTEMPT="$attempt" CHAIN_ID="$chain_id" SID="$session_id" \
        OUTCOME="$outcome" node -e '
          process.stdout.write(JSON.stringify({attempt:Number(process.env.ATTEMPT),
            chainId:process.env.CHAIN_ID,sessionId:process.env.SID,outcome:process.env.OUTCOME}));
        ' 2>/dev/null)" || return 5
      event_id="$(autopilot_chain_event_id "done" "$chain_id")" || return $?
      _autopilot_apply_critical "$root" "$run_id" "$event_id" \
        TDD_CHAIN_DONE "$payload" "$session_id" || return $?
      _autopilot_node read-run "$root/.zensu/state/autopilot-run-${run_id}.json" "$run_id" "$root"
      ;;
    *)
      _autopilot_apply_block_locked "$root" "$run_id" TDD_RECONCILIATION_INVALID \
        "reconcile-${attempt}-${chain_id}" || return $?
      _autopilot_node read-run "$root/.zensu/state/autopilot-run-${run_id}.json" "$run_id" "$root"
      ;;
  esac
}

_autopilot_reconcile_stop_critical() {
  local root="$1" caller_session_id="$2" state_dir="$1/.zensu/state"
  local state meta run_id owner stage attempt chain_id return_stage state_file
  state="$(_autopilot_read_active_critical "$root" "$caller_session_id")" || return $?
  meta="$(printf '%s' "$state" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.stdout.write([s.runId,s.ownerSessionId,s.stage,s.tdd.attempt,
        s.tdd.chainId||"",s.tdd.returnStage||""].join("\t"));
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || return 2
  IFS=$'\t' read -r run_id owner stage attempt chain_id return_stage <<<"$meta"
  if [ "$owner" != "$caller_session_id" ] || [ "$stage" != "TDD_RUNNING" ]; then
    printf '%s\n' "$state"
    return 0
  fi
  if ! _autopilot_identifier_ok "$chain_id"; then
    _autopilot_apply_block_locked "$root" "$run_id" TDD_RECONCILIATION_INVALID \
      "missing-chain-${attempt}" || return $?
    _autopilot_node read-run "$state_dir/autopilot-run-${run_id}.json" "$run_id" "$root"
    return $?
  fi
  state_file="$(tdd_state_file "$caller_session_id")"
  if _tdd_locked_run "$state_file" _autopilot_reconcile_stop_inner_critical \
      "$root" "$run_id" "$caller_session_id" "$attempt" "$chain_id" \
      "$return_stage" "$state_file"; then
    return 0
  fi
  _autopilot_apply_block_locked "$root" "$run_id" TDD_RECONCILIATION_INVALID \
    "inner-read-${attempt}-${chain_id}" || return $?
  _autopilot_node read-run "$state_dir/autopilot-run-${run_id}.json" "$run_id" "$root"
}

autopilot_reconcile_stop_active() {
  local root caller_session_id="${2:-}"
  [ "$#" -eq 2 ] || return 3
  _autopilot_session_id_ok "$caller_session_id" || return 3
  root="$(_autopilot_project_root "${1:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" || return $?
  _autopilot_locked_run "$root" "" _autopilot_reconcile_stop_critical \
    "$root" "$caller_session_id"
}

_autopilot_increment_inner_budget_critical() {
  local root="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5"
  local return_stage="$6" cap="$7" block_code="$8" state_file="$9"
  local _budget_file="${10}" result_file="${11}"
  local count blocked=false native_state_file env_exclusions
  _tdd_increment_stop_budget_critical "$state_file" "$session_id" "" \
    "$result_file" "$run_id" "$attempt" "$chain_id" "$return_stage" || return $?
  count="$(cat "$result_file" 2>/dev/null)" || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$count" -gt "$cap" ]; then
    native_state_file="$(_autopilot_native_project_path "$state_file")" || return 2
    env_exclusions="$(_autopilot_msys_env_exclusions STATE_FILE)" || return 2
    MSYS2_ENV_CONV_EXCL="$env_exclusions" STATE_FILE="$native_state_file" \
      SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
      CHAIN_ID="$chain_id" COUNT="$count" node -e '
        try {
          const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
          const exact=s.session_id_hash===`sha256:${process.env.SID.slice("scv1_".length)}`
            && s.active===true
            && s.implComplete===true && s.chainDone===false
            && s.autopilotRunId===process.env.RUN_ID
            && s.autopilotAttempt===Number(process.env.ATTEMPT)
            && s.chainId===process.env.CHAIN_ID
            && s.stopBlockCount===Number(process.env.COUNT);
          process.exit(exact?0:3);
        } catch (_) { process.exit(3); }
      ' 2>/dev/null || return 4
    _autopilot_apply_block_locked "$root" "$run_id" "$block_code" \
      "inner-cap-${attempt}-${chain_id}-${count}" || return $?
    blocked=true
  fi
  printf '{"count":%s,"blocked":%s}\n' "$count" "$blocked"
}

_autopilot_increment_inner_budget_outer_critical() {
  local root="$1" expected_run="$2" expected_stage="$3" expected_events="$4"
  local expected_attempt="$5" expected_return_stage="$6" expected_chain="$7"
  local session_id="$8" cap="$9" block_code="${10}" state_dir="$1/.zensu/state"
  local state meta run_id owner stage events attempt chain_id return_stage tdd_session
  local state_file state_dir_inner
  local result_file result rc
  state="$(_autopilot_read_active_critical "$root" "$session_id")" || return $?
  meta="$(printf '%s' "$state" | node -e '
    try {
      const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
      process.stdout.write([s.runId,s.ownerSessionId,s.stage,s.events.length,
        s.tdd.attempt,s.tdd.chainId||"",s.tdd.returnStage||"",s.tdd.sessionId||""].join("\t"));
    } catch (_) { process.exit(3); }
  ' 2>/dev/null)" || return 2
  IFS=$'\t' read -r run_id owner stage events attempt chain_id return_stage tdd_session <<<"$meta"
  [ "$run_id" = "$expected_run" ] && [ "$stage" = "$expected_stage" ] \
    && [ "$events" = "$expected_events" ] && [ "$owner" = "$session_id" ] \
    && [ "$attempt" = "$expected_attempt" ] && [ "$chain_id" = "$expected_chain" ] \
    && [ "$return_stage" = "$expected_return_stage" ] \
    && [ "$stage" = "TDD_RUNNING" ] && [ "$tdd_session" = "$session_id" ] \
    && _autopilot_identifier_ok "$chain_id" || return 4

  state_file="$(tdd_state_file "$session_id")"
  state_dir_inner="$(dirname "$state_file")"
  _tdd_path_safe "$state_file" regular "$state_dir_inner" || return 2
  result_file="$(mktemp "${state_file}.stop-count.XXXXXX" 2>/dev/null)" || return 5
  result="$(_tdd_locked_run "$state_file" _autopilot_increment_inner_budget_critical \
    "$root" "$run_id" "$session_id" "$expected_attempt" "$expected_chain" \
    "$expected_return_stage" "$cap" "$block_code" \
    "$state_file" "" "$result_file")"
  rc=$?
  rm -f "$result_file" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$result"
}

autopilot_increment_inner_stop_budget_capped() {
  local run_id="${1:-}" expected_stage="${2:-}" expected_events="${3:-}" root
  local expected_attempt="${4:-}" expected_return_stage="${5:-}" expected_chain="${6:-}"
  local session_id="${8:-}" cap="${9:-}" block_code="${10:-}"
  [ "$#" -eq 10 ] || return 3
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$session_id" \
    && _autopilot_identifier_ok "$expected_chain" \
    && _autopilot_identifier_ok "$block_code" || return 3
  case "$expected_events:$expected_attempt:$cap" in *[!0-9:]*) return 3 ;; esac
  [ -n "$expected_events" ] && [ -n "$cap" ] || return 3
  [ "$expected_attempt" -ge 1 ] && [ "$expected_attempt" -le 999 ] || return 3
  case "$expected_return_stage" in GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER) ;; *) return 3 ;; esac
  root="$(_autopilot_project_root "${7:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_increment_inner_budget_outer_critical \
    "$root" "$run_id" "$expected_stage" "$expected_events" "$expected_attempt" \
    "$expected_return_stage" "$expected_chain" "$session_id" "$cap" "$block_code"
}

_autopilot_verify_inner_binding_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4"
  local return_stage="$5" chain_id="$6" native_state_file env_exclusions
  native_state_file="$(_autopilot_native_project_path "$state_file")" || return 2
  env_exclusions="$(_autopilot_msys_env_exclusions STATE_FILE)" || return 2
  MSYS2_ENV_CONV_EXCL="$env_exclusions" STATE_FILE="$native_state_file" \
    SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    RETURN_STAGE="$return_stage" CHAIN_ID="$chain_id" node -e '
      const fs=require("fs");
      let s;
      try { s=JSON.parse(fs.readFileSync(process.env.STATE_FILE,"utf8")); }
      catch (_) { process.exit(3); }
      const ok=s && typeof s==="object" && !Array.isArray(s)
        && s.session_id_hash===`sha256:${process.env.SID.slice("scv1_".length)}`
        && s.active===true
        && s.autopilotRunId===process.env.RUN_ID
        && s.autopilotAttempt===Number(process.env.ATTEMPT)
        && s.autopilotReturnStage===process.env.RETURN_STAGE
        && s.chainId===process.env.CHAIN_ID
        && s.chainDone===false && s.chainOutcome==="";
      process.exit(ok?0:3);
    ' 2>/dev/null
}

_autopilot_verify_inner_binding() {
  local session_id="$1" run_id="$2" attempt="$3" return_stage="$4" chain_id="$5"
  local state_file
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 1
  _tdd_locked_run "$state_file" _autopilot_verify_inner_binding_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$return_stage" "$chain_id"
}

# Prepare the outer TDD_STARTED transition while holding the one project-wide
# Autopilot lock, create/reset the matching inner generation under its own lock,
# then publish the outer state. A concurrent contender therefore fails before
# touching the inner file. If a process dies after the inner write, retrying the
# exact event reconstructs the outer side; no conflicting chain may win later.
_autopilot_begin_tdd_critical() {
  local root="$1" run_id="$2" event_id="$3" session_id="$4" vanilla="$5"
  local attempt="$6" return_stage="$7" chain_id="$8"
  local state_dir="$root/.zensu/state" run_file run_tmp payload rc
  local native_run_tmp env_exclusions
  run_file="$state_dir/autopilot-run-${run_id}.json"
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  payload="$(ATTEMPT="$attempt" CHAIN_ID="$chain_id" SID="$session_id" node -e '
    process.stdout.write(JSON.stringify({attempt:Number(process.env.ATTEMPT),chainId:process.env.CHAIN_ID,sessionId:process.env.SID}));
  ')" || { rm -f "$run_tmp"; return 5; }
  _autopilot_node apply "$state_dir" "$run_file" "$run_tmp" "$run_id" "$event_id" \
    TDD_STARTED "$payload" "$root" "$session_id"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    rm -f "$run_tmp"
    _autopilot_verify_inner_binding "$session_id" "$run_id" "$attempt" "$return_stage" "$chain_id"
    return $?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$rc"
  fi
  native_run_tmp="$(_autopilot_native_project_path "$run_tmp")" \
    || { rm -f "$run_tmp"; return 2; }
  env_exclusions="$(_autopilot_msys_env_exclusions STATE_FILE)" \
    || { rm -f "$run_tmp"; return 2; }
  if ! MSYS2_ENV_CONV_EXCL="$env_exclusions" STATE_FILE="$native_run_tmp" \
      RUN_ID="$run_id" SID="$session_id" ATTEMPT="$attempt" \
      RETURN_STAGE="$return_stage" CHAIN_ID="$chain_id" node -e '
        try {
          const s=JSON.parse(require("fs").readFileSync(process.env.STATE_FILE,"utf8"));
          const ok=s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
            && s.stage==="TDD_RUNNING" && s.tdd
            && s.tdd.attempt===Number(process.env.ATTEMPT)
            && s.tdd.returnStage===process.env.RETURN_STAGE
            && s.tdd.chainId===process.env.CHAIN_ID
            && s.tdd.sessionId===process.env.SID;
          process.exit(ok?0:3);
        } catch (_) { process.exit(3); }
      ' 2>/dev/null; then
    rm -f "$run_tmp"
    return 4
  fi
  if ! tdd_begin_session "$session_id" "$vanilla" false false "" \
      "$run_id" "$attempt" "$return_stage" "$chain_id"; then
    rm -f "$run_tmp"
    return 5
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp"; return 5; }
}

autopilot_begin_tdd_attempt() {
  local run_id="${1:-}" event_id="${2:-}" root session_id="${4:-}" vanilla="${5:-}"
  local attempt="${6:-}" return_stage="${7:-}" chain_id="${8:-}"
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$event_id" \
    && _autopilot_identifier_ok "$session_id" && _autopilot_identifier_ok "$chain_id" || return 3
  case "$vanilla" in true|false) ;; *) return 3 ;; esac
  case "$attempt" in ''|*[!0-9]*) return 3 ;; esac
  [ "$attempt" -ge 1 ] && [ "$attempt" -le 999 ] || return 3
  case "$return_stage" in GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER) ;; *) return 3 ;; esac
  root="$(_autopilot_project_root "${3:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_begin_tdd_critical \
    "$root" "$run_id" "$event_id" "$session_id" "$vanilla" "$attempt" "$return_stage" "$chain_id"
}

# TDD_CHAIN_DONE uses the same lock ordering as start: outer project lock first,
# then the inner session lock. The inner helper commits chainOutcome+chainDone in
# one CAS write. Only after that succeeds is the prepared outer transition
# renamed into place. Both helpers accept an exact duplicate as a no-op, which
# makes the one unavoidable two-file crash window recoverable by retry.
_autopilot_finish_tdd_critical() {
  local root="$1" run_id="$2" event_id="$3" session_id="$4" attempt="$5"
  local chain_id="$6" outcome="$7" claimed_seen="$8" claimed_ticket="${9:-}"
  local state_dir="$root/.zensu/state" run_file run_tmp payload rc
  run_file="$state_dir/autopilot-run-${run_id}.json"
  run_tmp="$(_autopilot_mktemp_beside "$run_file")" || return 5
  payload="$(ATTEMPT="$attempt" CHAIN_ID="$chain_id" SID="$session_id" OUTCOME="$outcome" node -e '
    process.stdout.write(JSON.stringify({attempt:Number(process.env.ATTEMPT),chainId:process.env.CHAIN_ID,sessionId:process.env.SID,outcome:process.env.OUTCOME}));
  ')" || { rm -f "$run_tmp"; return 5; }
  _autopilot_node apply "$state_dir" "$run_file" "$run_tmp" "$run_id" "$event_id" \
    TDD_CHAIN_DONE "$payload" "$root" "$session_id"
  rc=$?
  if [ "$rc" -eq 10 ]; then
    # The durable outer event is the acknowledgement record. It was only ever
    # committed after the matching inner CAS succeeded, so a late exact retry
    # remains successful even when a newer inner generation now owns the
    # session file.
    rm -f "$run_tmp"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$rc"
  fi
  if [ "$claimed_seen" = "true" ]; then
    tdd_finish_autopilot_chain "$session_id" "$run_id" "$attempt" "$chain_id" "$outcome" "$claimed_ticket"
  else
    tdd_finish_autopilot_chain "$session_id" "$run_id" "$attempt" "$chain_id" "$outcome"
  fi
  local finish_rc=$?
  if [ "$finish_rc" -ne 0 ]; then
    rm -f "$run_tmp"
    return "$finish_rc"
  fi
  _tdd_atomic_replace_regular "$run_tmp" "$run_file" || { rm -f "$run_tmp"; return 5; }
}

autopilot_finish_tdd_attempt() {
  local run_id="${1:-}" event_id="${2:-}" root session_id="${4:-}" attempt="${5:-}"
  local chain_id="${6:-}" outcome="${7:-}" claimed_seen="${8:-false}" claimed_ticket="${9:-}"
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$event_id" \
    && _autopilot_identifier_ok "$session_id" && _autopilot_identifier_ok "$chain_id" || return 3
  case "$attempt" in ''|*[!0-9]*) return 3 ;; esac
  [ "$attempt" -ge 1 ] && [ "$attempt" -le 999 ] || return 3
  case "$outcome" in pass|no-changes|max-rounds) ;; *) return 3 ;; esac
  case "$claimed_seen" in true|false) ;; *) return 3 ;; esac
  if [ "$claimed_seen" = "true" ]; then
    _tdd_review_ticket_shape_ok "$claimed_ticket" || return 3
  elif [ -n "$claimed_ticket" ]; then
    return 3
  fi
  root="$(_autopilot_project_root "${3:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_finish_tdd_critical \
    "$root" "$run_id" "$event_id" "$session_id" "$attempt" "$chain_id" "$outcome" \
      "$claimed_seen" "$claimed_ticket"
}

# Rearm one exhausted inner review generation while holding the outer project
# lock first, then the inner session lock. This shares the exact lock ordering
# with TDD start/finish, so a concurrent TDD_CHAIN_DONE cannot turn the outer
# run BLOCKED between the rearm decision and the inner CAS.
_autopilot_rearm_review_critical() {
  local root="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5" ticket="$6"
  local state_dir="$root/.zensu/state" run_file state_file state mode retire=false
  local inner_ctx reconcile_fields outcome payload done_event_id rearm_event_id
  run_file="$state_dir/autopilot-run-${run_id}.json"
  state_file="$(tdd_state_file "$session_id")"
  state="$(_autopilot_node read-run "$run_file" "$run_id" "$root")" || return $?
  mode="$(printf '%s' "$state" | SID="$session_id" RUN_ID="$run_id" \
    ATTEMPT="$attempt" CHAIN_ID="$chain_id" node -e '
      try {
        const fs=require("fs"),s=JSON.parse(fs.readFileSync(0,"utf8"));
        const exact=s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
          && s.tdd && s.tdd.sessionId===process.env.SID
          && s.tdd.attempt===Number(process.env.ATTEMPT) && s.tdd.chainId===process.env.CHAIN_ID;
        if(!exact)process.exit(3);
        if(s.stage==="TDD_RUNNING")process.stdout.write("active");
        else if(s.stage==="BLOCKED" && s.blocked && s.blocked.code==="TDD_MAX_ROUNDS")process.stdout.write("retire-resume");
        else if(s.stage==="AWAIT_TDD")process.stdout.write("retire-retry");
        else process.exit(3);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null)" || return 3
  if [ "$mode" = "active" ]; then
    inner_ctx="$(tdd_autopilot_context "$state_file" "$session_id" 2>/dev/null)" || return 3
    reconcile_fields="$(AUTOPILOT_CTX="$inner_ctx" RUN_ID="$run_id" ATTEMPT="$attempt" \
      CHAIN_ID="$chain_id" node -e '
        try {
          const c=JSON.parse(process.env.AUTOPILOT_CTX);
          const exact=c.runId===process.env.RUN_ID && String(c.attempt)===process.env.ATTEMPT
            && c.chainId===process.env.CHAIN_ID && c.active===true && c.implComplete===true;
          if(!exact)process.exit(3);
          process.stdout.write(`${c.chainDone}\t${c.outcome}`);
        } catch (_) { process.exit(3); }
      ' 2>/dev/null)" || return 3
    IFS=$'\t' read -r inner_done outcome <<<"$reconcile_fields"
    if [ "$inner_done" = "true" ]; then
      case "$outcome" in pass|no-changes|max-rounds) ;; *) return 3 ;; esac
      payload="$(ATTEMPT="$attempt" CHAIN_ID="$chain_id" SID="$session_id" OUTCOME="$outcome" node -e '
        process.stdout.write(JSON.stringify({attempt:Number(process.env.ATTEMPT),chainId:process.env.CHAIN_ID,sessionId:process.env.SID,outcome:process.env.OUTCOME}));
      ')" || return 5
      done_event_id="$(autopilot_chain_event_id "done" "$chain_id")" || return $?
      _autopilot_apply_critical "$root" "$run_id" "$done_event_id" \
        TDD_CHAIN_DONE "$payload" "$session_id" || return $?
      # A pass/no-changes receipt has now advanced the outer run and is not a
      # resettable exhausted generation. max-rounds becomes BLOCKED and must be
      # retired before the same locked composite resumes a fresh attempt.
      [ "$outcome" = "max-rounds" ] || return 3
      mode="retire-resume"
    fi
  fi
  case "$mode" in active) retire=false ;; *) retire=true ;; esac
  tdd_rearm_autopilot_review "$session_id" "$run_id" "$attempt" "$chain_id" "$ticket" "$retire" \
    || return $?
  if [ "$mode" = "retire-resume" ]; then
    rearm_event_id="$(autopilot_chain_event_id rearm "$chain_id")" || return $?
    _autopilot_apply_critical "$root" "$run_id" "$rearm_event_id" \
      RESUME '{}' "$session_id" || return $?
  fi
}

autopilot_rearm_review() {
  local run_id="${1:-}" root session_id="${3:-}" attempt="${4:-}"
  local chain_id="${5:-}" ticket="${6:-}"
  [ "$#" -eq 6 ] || return 3
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$session_id" \
    && _autopilot_identifier_ok "$chain_id" || return 3
  case "$attempt" in ''|*[!0-9]*) return 3 ;; esac
  [ "$attempt" -ge 1 ] && [ "$attempt" -le 999 ] || return 3
  _tdd_review_ticket_shape_ok "$ticket" || return 3
  root="$(_autopilot_project_root "${2:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_rearm_review_critical \
    "$root" "$run_id" "$session_id" "$attempt" "$chain_id" "$ticket"
}

_autopilot_terminal_inner_matches_critical() {
  local state_file="$1" session_id="$2" run_id="$3" attempt="$4"
  local return_stage="$5" chain_id="$6" snapshot
  snapshot="$(tdd_chain_snapshot "$state_file" "$session_id" 2>/dev/null)" || return 4
  printf '%s' "$snapshot" | RUN_ID="$run_id" ATTEMPT="$attempt" \
    RETURN_STAGE="$return_stage" CHAIN_ID="$chain_id" node -e '
      try {
        const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
        const a=s.autopilot;
        const exact=s.active===true && s.implComplete===true && s.chainDone===false
          && a && a.runId===process.env.RUN_ID
          && String(a.attempt)===process.env.ATTEMPT
          && a.returnStage===process.env.RETURN_STAGE
          && a.chainId===process.env.CHAIN_ID;
        process.exit(exact?0:4);
      } catch (_) { process.exit(4); }
    ' 2>/dev/null
}

_autopilot_terminal_owns_inner_critical() {
  local root="$1" run_id="$2" session_id="$3" attempt="$4"
  local return_stage="$5" chain_id="$6" state_dir="$1/.zensu/state" state state_file
  state="$(_autopilot_read_active_critical "$root" "$session_id")" || return $?
  printf '%s' "$state" | RUN_ID="$run_id" SID="$session_id" ATTEMPT="$attempt" \
    RETURN_STAGE="$return_stage" CHAIN_ID="$chain_id" node -e '
      try {
        const s=JSON.parse(require("fs").readFileSync(0,"utf8"));
        const exact=["DONE","BLOCKED","CANCELLED"].includes(s.stage)
          && s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
          && s.tdd && String(s.tdd.attempt)===process.env.ATTEMPT
          && s.tdd.returnStage===process.env.RETURN_STAGE
          && s.tdd.chainId===process.env.CHAIN_ID
          && s.tdd.sessionId===process.env.SID;
        process.exit(exact?0:4);
      } catch (_) { process.exit(4); }
    ' 2>/dev/null || return 4
  state_file="$(tdd_state_file "$session_id")"
  _tdd_path_safe "$state_file" regular "$(dirname "$state_file")" || return 2
  _tdd_locked_run "$state_file" _autopilot_terminal_inner_matches_critical \
    "$state_file" "$session_id" "$run_id" "$attempt" "$return_stage" "$chain_id"
}

# Prove that the *current* project pointer and current Inner still form the
# same Stop-releasing generation. The project lock remains held while the
# Inner mutex is acquired, matching every composite Autopilot mutation.
autopilot_terminal_owns_inner_current() {
  local run_id="${1:-}" root session_id="${3:-}" attempt="${4:-}"
  local return_stage="${5:-}" chain_id="${6:-}"
  [ "$#" -eq 6 ] || return 3
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$chain_id" \
    && _autopilot_session_id_ok "$session_id" || return 3
  case "$attempt" in ''|*[!0-9]*) return 3 ;; esac
  [ "$attempt" -ge 1 ] && [ "$attempt" -le 999 ] || return 3
  case "$return_stage" in GATES|CONVERGE|FIX_FINDINGS|VALIDATE|COVER) ;; *) return 3 ;; esac
  root="$(_autopilot_project_root "${2:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_terminal_owns_inner_critical \
    "$root" "$run_id" "$session_id" "$attempt" "$return_stage" "$chain_id"
}

_autopilot_reset_inner_critical() {
  local root="$1" run_id="$2" session_id="$3" attempt="$4" chain_id="$5"
  local state_dir="$root/.zensu/state" state
  # Reset is also the terminal Stop release linearization point. Read the
  # current pointer while the project lock is held; a historical terminal run
  # file must never authorize clearing or releasing a newer active run.
  state="$(_autopilot_read_active_critical "$root" "$session_id")" || return $?
  printf '%s' "$state" | SID="$session_id" RUN_ID="$run_id" ATTEMPT="$attempt" \
    CHAIN_ID="$chain_id" node -e '
      try {
        const fs=require("fs"),s=JSON.parse(fs.readFileSync(0,"utf8"));
        const exact=["DONE","CANCELLED"].includes(s.stage)
          && s.runId===process.env.RUN_ID && s.ownerSessionId===process.env.SID
          && s.tdd && s.tdd.sessionId===process.env.SID
          && s.tdd.attempt===Number(process.env.ATTEMPT) && s.tdd.chainId===process.env.CHAIN_ID;
        process.exit(exact?0:3);
      } catch (_) { process.exit(3); }
    ' 2>/dev/null || return 3
  tdd_reset_pending_review_claim "$session_id" "$run_id" "$attempt" "$chain_id"
}

autopilot_reset_inner() {
  local run_id="${1:-}" root session_id="${3:-}" attempt="${4:-}" chain_id="${5:-}"
  [ "$#" -eq 5 ] || return 3
  _autopilot_identifier_ok "$run_id" && _autopilot_identifier_ok "$session_id" \
    && _autopilot_identifier_ok "$chain_id" || return 3
  case "$attempt" in ''|*[!0-9]*) return 3 ;; esac
  [ "$attempt" -ge 1 ] && [ "$attempt" -le 999 ] || return 3
  root="$(_autopilot_project_root "${2:-${CLAUDE_PROJECT_DIR:-.}}")" || return 2
  _autopilot_read_storage_ready "$root" "$run_id" || return $?
  _autopilot_locked_run "$root" "$run_id" _autopilot_reset_inner_critical \
    "$root" "$run_id" "$session_id" "$attempt" "$chain_id"
}
