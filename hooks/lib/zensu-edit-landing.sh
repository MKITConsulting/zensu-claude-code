#!/bin/bash
# zensu-edit-landing.sh — the Phase 6 step 5b Edit Landing Audit, as code.
#
# A mechanical or bulk replacement that matched nothing produces no diff. The
# file never enters the review chain's changed-file list, so no reviewer sees
# it, and the suite stays green because it was green before the edit. The
# failure mode is silent by construction.
#
# This used to be five dense lines of prose in skills/tdd/SKILL.md that every
# run re-implemented from scratch. Prose cannot be unit-tested and cannot be
# gated on; a library can be both. The skill now calls this and reacts to the
# verdict — the same move `--chain-done` already makes when it checks the
# working tree itself instead of asking the model to.
#
# Usage:
#   zensu-edit-landing.sh --log <run-log> [--project <dir>] [--baseline <sha>]
#                         [--session-epoch <n>] [--session <id>]
#                         [--dirty-before <file>] [--receipt <path>]
#
#   --log            the session run log holding the IMPL/WIRED claims (required)
#   --project        repository root to audit (default: CLAUDE_PROJECT_DIR or .)
#   --baseline       HEAD sha captured at Phase 0; keeps claims verifiable after
#                    a mid-run commit
#   --session-epoch  session start, for the non-git mtime fallback
#   --session        session id; with --receipt omitted, the receipt lands at
#                    <project>/.zensu/state/edit-landing-<session>.json
#   --dirty-before   file listing paths already dirty BEFORE this round; those
#                    cannot be certified by union membership alone
#   --receipt        explicit receipt path ('-' disables the receipt)
#
# Exit: 0 when every claim is landed or explicitly exempt; 1 when any claim is
# NOT LANDED, UNVERIFIED, or PENDING PREDICATE; 2 on a usage/environment error.
set -u

LOG_FILE=""
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
BASELINE_SHA=""
SESSION_EPOCH=""
SESSION_ID=""
DIRTY_BEFORE=""
RECEIPT_PATH=""
RECEIPT_EXPLICIT=0

die() { echo "zensu-edit-landing.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --log)           [ $# -ge 2 ] || die "--log requires a value"; LOG_FILE="$2"; shift 2 ;;
    --project)       [ $# -ge 2 ] || die "--project requires a value"; PROJECT_DIR="$2"; shift 2 ;;
    --baseline)      [ $# -ge 2 ] || die "--baseline requires a value"; BASELINE_SHA="$2"; shift 2 ;;
    --session-epoch) [ $# -ge 2 ] || die "--session-epoch requires a value"; SESSION_EPOCH="$2"; shift 2 ;;
    --session)       [ $# -ge 2 ] || die "--session requires a value"; SESSION_ID="$2"; shift 2 ;;
    --dirty-before)  [ $# -ge 2 ] || die "--dirty-before requires a value"; DIRTY_BEFORE="$2"; shift 2 ;;
    --receipt)       [ $# -ge 2 ] || die "--receipt requires a value"; RECEIPT_PATH="$2"; RECEIPT_EXPLICIT=1; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$LOG_FILE" ] || die "--log is required"
[ -f "$LOG_FILE" ] || die "run log not found: $LOG_FILE"
[ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

# Resolve the project root before anything else. An unresolvable root must not
# silently degrade into auditing the current directory.
PROJECT_ABS="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || die "cannot resolve project dir: $PROJECT_DIR"

IN_GIT=0
REPO_ROOT="$PROJECT_ABS"
if git -C "$PROJECT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=1
  REPO_ROOT="$(git -C "$PROJECT_ABS" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$PROJECT_ABS"
fi

# ── The actual change set ────────────────────────────────────────────────────
# Anchored with -C so the current working directory cannot narrow it: `ls-files`
# is cwd-scoped and would silently drop everything outside a subdirectory.
UNION_FILE="$(mktemp)" || die "mktemp failed"
cleanup() { rm -f "${UNION_FILE:-}" "${CLAIMS_FILE:-}" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

if [ "$IN_GIT" -eq 1 ]; then
  if git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    git -C "$REPO_ROOT" diff --name-only HEAD -- 2>/dev/null >> "$UNION_FILE"
    # A mid-run commit empties the worktree diff; the baseline range is what
    # keeps those claims verifiable.
    if [ -n "$BASELINE_SHA" ] && git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASELINE_SHA" >/dev/null 2>&1; then
      git -C "$REPO_ROOT" diff --name-only "$BASELINE_SHA"..HEAD -- 2>/dev/null >> "$UNION_FILE"
    fi
  else
    # Unborn HEAD: `diff HEAD` is fatal, so take the index instead.
    git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -- 2>/dev/null >> "$UNION_FILE"
  fi
  git -C "$REPO_ROOT" ls-files --others --exclude-standard -- 2>/dev/null >> "$UNION_FILE"
fi
sort -u -o "$UNION_FILE" "$UNION_FILE" 2>/dev/null

in_union() { grep -qxF -- "$1" "$UNION_FILE" 2>/dev/null; }

was_dirty_before() {
  [ -n "$DIRTY_BEFORE" ] && [ -f "$DIRTY_BEFORE" ] || return 1
  grep -qxF -- "$1" "$DIRTY_BEFORE" 2>/dev/null
}

is_ignored() {
  [ "$IN_GIT" -eq 1 ] || return 1
  git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null
}

# ── Claim extraction ─────────────────────────────────────────────────────────
# Only the two contracted forms carry a gradeable file list. Anything else that
# says WIRED names nothing that can be checked and is reported UNVERIFIED — a
# legacy or malformed entry must never read as passing.
CLAIMS_FILE="$(mktemp)" || die "mktemp failed"

CLAIM_COUNT=0
LANDED=0
NOT_LANDED=0
UNVERIFIED=0
PENDING=0
EXEMPT_IGNORED=0
EXEMPT_VERIFIED=0

emit() { printf '%s\n' "$1"; }

# Normalize one claimed path to repo-root-relative. Echoes the resolved path, or
# nothing when it cannot be resolved unambiguously.
normalize_claim() {
  local raw="$1" p
  p="$raw"
  p="${p#"${p%%[![:space:]]*}"}"          # ltrim
  p="${p%"${p##*[![:space:]]}"}"          # rtrim
  [ -n "$p" ] || return 1
  case "$p" in
    "$REPO_ROOT"/*) p="${p#"$REPO_ROOT"/}" ;;
    /*) return 1 ;;                        # absolute but outside the repo
  esac
  p="${p#./}"
  # Exact hit, either in the change set or on disk.
  if in_union "$p" || [ -e "$REPO_ROOT/$p" ]; then
    printf '%s' "$p"; return 0
  fi
  # A bare basename resolves only when exactly one union entry ends in it.
  case "$p" in
    */*) printf '%s' "$p"; return 0 ;;
  esac
  local matches count
  matches="$(grep -E "(^|/)$(printf '%s' "$p" | sed 's/[][\.*^$+?(){}|/]/\\&/g')$" "$UNION_FILE" 2>/dev/null)"
  count="$(printf '%s' "$matches" | grep -c . 2>/dev/null || echo 0)"
  if [ "$count" = "1" ]; then
    printf '%s' "$matches"; return 0
  fi
  return 1
}

grade_claim() {
  local step="$1" raw="$2" resolved
  CLAIM_COUNT=$((CLAIM_COUNT + 1))
  if ! resolved="$(normalize_claim "$raw")" || [ -z "$resolved" ]; then
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED — ${step}: claimed \"${raw}\" could not be resolved to a repo-root-relative path"
    return
  fi
  if in_union "$resolved"; then
    # Membership is worktree-scoped: a file already dirty before this round
    # reads as landed even when THIS round's replacement matched nothing.
    if was_dirty_before "$resolved"; then
      PENDING=$((PENDING + 1))
      emit "PENDING PREDICATE — ${step}: ${resolved} was already dirty before this round; union membership is not evidence — re-read the target predicate"
      return
    fi
    LANDED=$((LANDED + 1))
    emit "EDIT LANDED — ${step}: ${resolved}"
    return
  fi
  # Absent. Exactly two absences are legitimate, and both must be proven.
  if is_ignored "$resolved"; then
    EXEMPT_IGNORED=$((EXEMPT_IGNORED + 1))
    LANDED=$((LANDED + 1))
    emit "EDIT LANDED (untracked-by-design) — ${resolved}"
    return
  fi
  if [ "$IN_GIT" -eq 0 ]; then
    # No git to ask. An mtime after session start is corroboration, never proof,
    # so it stays PENDING rather than reading as landed.
    if [ -n "$SESSION_EPOCH" ] && [ -e "$REPO_ROOT/$resolved" ]; then
      local mt
      mt="$(stat -f %m "$REPO_ROOT/$resolved" 2>/dev/null || stat -c %Y "$REPO_ROOT/$resolved" 2>/dev/null)"
      if [ -n "$mt" ] && [ "$mt" -ge "$SESSION_EPOCH" ] 2>/dev/null; then
        PENDING=$((PENDING + 1))
        emit "PENDING PREDICATE — ${step}: ${resolved} mtime is newer than session start, but this is not a git work tree — re-read the target predicate"
        return
      fi
    fi
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED — ${step}: ${resolved} cannot be checked outside a git work tree"
    return
  fi
  NOT_LANDED=$((NOT_LANDED + 1))
  emit "EDIT NOT LANDED — ${step}: claimed ${resolved}, git shows no change"
}

# Read the log. Claim lines carry a step id followed by one of the two forms.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *"WIRED (verified, no change)"*)
      # Contract: a step that verified an existing wiring instead of changing
      # one. Exempt, and counted so the receipt shows it was used.
      EXEMPT_VERIFIED=$((EXEMPT_VERIFIED + 1))
      continue
      ;;
    *"IMPL completed — files:"*)
      # The step id is the token immediately before the marker; everything to
      # its left is the configurable timestamp prefix.
      step="$(printf '%s' "${line%% IMPL completed*}" | awk '{print $NF}')"
      files="${line#*IMPL completed — files:}"
      ;;
    *"WIRED — files:"*)
      step="$(printf '%s' "${line%% WIRED — files:*}" | awk '{print $NF}')"
      files="${line#*WIRED — files:}"
      ;;
    *"WIRED"*)
      UNVERIFIED=$((UNVERIFIED + 1))
      CLAIM_COUNT=$((CLAIM_COUNT + 1))
      emit "UNVERIFIED — a WIRED entry names no files: list and cannot be graded: ${line}"
      continue
      ;;
    *) continue ;;
  esac
  # Commentary after ' | ' is not part of the file list.
  files="${files%%|*}"
  printf '%s\n' "$files" | tr ',' '\n' | while IFS= read -r one; do
    printf '%s\t%s\n' "$step" "$one"
  done >> "$CLAIMS_FILE"
done < "$LOG_FILE"

# The pipeline above runs in a subshell, so grade in the parent to keep counters.
while IFS="$(printf '\t')" read -r step raw; do
  [ -n "${raw// /}" ] || continue
  grade_claim "$step" "$raw"
done < "$CLAIMS_FILE"

CLEAN=1
[ "$NOT_LANDED" -gt 0 ] && CLEAN=0
[ "$UNVERIFIED" -gt 0 ] && CLEAN=0
[ "$PENDING" -gt 0 ] && CLEAN=0
if [ "$CLAIM_COUNT" -eq 0 ]; then
  CLEAN=0
  emit "UNVERIFIED (no claims logged) — the run log holds no IMPL/WIRED files: entry, so nothing could be audited"
fi

emit "EDIT LANDING AUDIT — claims=${CLAIM_COUNT} landed=${LANDED} not_landed=${NOT_LANDED} unverified=${UNVERIFIED} pending=${PENDING} exempt_ignored=${EXEMPT_IGNORED} exempt_verified=${EXEMPT_VERIFIED}"

# ── Receipt ──────────────────────────────────────────────────────────────────
if [ "$RECEIPT_EXPLICIT" -eq 1 ] && [ "$RECEIPT_PATH" = "-" ]; then
  :
else
  if [ -z "$RECEIPT_PATH" ] && [ -n "$SESSION_ID" ]; then
    # Canonicalize through the same helper the rest of the plugin uses, so the
    # receipt lands where `--tdd-complete` looks for it. A harness session id and
    # its on-disk state key are not the same string.
    _key=""
    if [ -f "$(dirname "$0")/session-control-core-v1.js" ] && command -v node >/dev/null 2>&1; then
      _key="$(node "$(dirname "$0")/session-control-core-v1.js" session-key "$SESSION_ID" 2>/dev/null)"
    fi
    [ -n "$_key" ] || _key="$SESSION_ID"
    RECEIPT_PATH="$PROJECT_ABS/.zensu/state/edit-landing-${_key}.json"
  fi
  # A receipt whose name ends in `-` means the session key resolved empty; a
  # RELATIVE path means the caller's cwd decides where it lands. Both have put
  # `edit-landing-.json` in a repository root. Refuse rather than write blind:
  # the receipt is state, and state belongs under the project's .zensu/state.
  case "$RECEIPT_PATH" in
    ""|*/edit-landing-.json|edit-landing-.json)
      [ -n "$RECEIPT_PATH" ] && emit "RECEIPT REFUSED — the session key resolved empty, so no receipt was written (would have been ${RECEIPT_PATH})"
      RECEIPT_PATH=""
      ;;
    /*) ;;
    *)
      emit "RECEIPT REFUSED — a relative --receipt path would land in the caller's cwd, not the project state dir (${RECEIPT_PATH})"
      RECEIPT_PATH=""
      ;;
  esac
  if [ -n "$RECEIPT_PATH" ]; then
    mkdir -p "$(dirname "$RECEIPT_PATH")" 2>/dev/null
    tmp_receipt="${RECEIPT_PATH}.tmp.$$"
    printf '{"schema":"edit-landing-v1","session":"%s","log":"%s","claims":%d,"landed":%d,"notLanded":%d,"unverified":%d,"pending":%d,"exemptIgnored":%d,"exemptVerified":%d,"clean":%s}\n' \
      "$SESSION_ID" "$LOG_FILE" "$CLAIM_COUNT" "$LANDED" "$NOT_LANDED" "$UNVERIFIED" "$PENDING" \
      "$EXEMPT_IGNORED" "$EXEMPT_VERIFIED" "$([ "$CLEAN" -eq 1 ] && echo true || echo false)" \
      > "$tmp_receipt" 2>/dev/null && mv -f "$tmp_receipt" "$RECEIPT_PATH" 2>/dev/null
    rm -f "$tmp_receipt" 2>/dev/null
  fi
fi

[ "$CLEAN" -eq 1 ]
