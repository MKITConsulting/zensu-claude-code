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
#   zensu-edit-landing.sh --inventory --log <run-log> [--project <dir>]
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
#   --inventory      read-only: report the claimed-file count and the foreign
#                    roots the claims name, without a change set, a verdict or a
#                    receipt. Output is `claimed-files=<n>` plus one
#                    `foreign-root<TAB><root>` line per distinct non-anchor root,
#                    whose value domain is a PATH and never a diagnostic. The
#                    count is NOT the receipt's `claims`: this one counts NAMED
#                    FILES, while the receipt counts claim ENTRIES and therefore
#                    includes a bare `WIRED` one. It accepts no write-mode
#                    operand. Its consumers are
#                    `zensu-log.sh --tdd-complete` (which arms the receipt
#                    requirement on a claim rather than on a dirty tree) and the
#                    /zensu:doctor topology row; both need the claim grammar this
#                    file owns, and neither may write anything.
#
# Exit: 0 when every claim is landed or explicitly exempt; 1 when any claim is
# NOT LANDED, UNVERIFIED, or PENDING PREDICATE; 2 on a usage/environment error — and, under `--inventory`, on any state in which the claim inventory did not COMPLETE (the claim budget, an ancestor walk that gave up, a root this wire format cannot carry, a failed record or read-back, a kind this mode does not handle); a non-zero status there means 'did not complete', never 'no foreign roots' —
# which now includes every RECEIPT REFUSED path (no node, an unwritable or refused
# receipt destination, a session key that resolved empty). Exit 1 is a verdict about
# the CLAIMS and must stay one: a caller reads it as "an edit did not land", and a
# read-only state directory is not that. Grading is checked first, so a run with
# both an unlanded claim and a broken receipt exits 1.
set -u

LOG_FILE=""
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
BASELINE_SHA=""
SESSION_EPOCH=""
SESSION_ID=""
SESSION_SEEN=0
DIRTY_BEFORE=""
RECEIPT_PATH=""
RECEIPT_EXPLICIT=0
RECEIPT_FAILED=0
BASELINE_SEEN=0
EPOCH_SEEN=0
DIRTY_SEEN=0
INVENTORY=0
INV_ROOTS=""
# Per-run cap on the claims `--inventory` will classify. Each one costs an
# ancestor walk of up to CLAIM_ANCESTOR_BUDGET filesystem probes, and the bound
# above this child DIFFERS PER CONSUMER — state it conditionally, the way
# zensu-log.sh's own comment does, because an unconditional claim is false for
# one of the two. On the `--tdd-complete` path the only thing above it is a
# watchdog ladder whose last arm has no deadline on a host without
# `timeout`/`gtimeout`, which is base macOS; on the `/zensu:doctor` path
# `spawnSync` enforces its own 5 s bound regardless of PATH. The product of the
# two budgets is also NOT bounded — roughly 10^5 process spawns at the maximum —
# so on the unbounded consumer these cap the number of probes, never the wall
# clock. A shared total-probe counter is the durable fix and is not taken here. Exceeding the cap is a FAULT (exit 2), never
# a truncated clean answer: a short foreign-root list read as "no foreign roots"
# is precisely the silent green both consumers must never be handed.
INV_CLAIM_BUDGET=2000

die() { echo "zensu-edit-landing.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --log)           [ $# -ge 2 ] || die "--log requires a value"; LOG_FILE="$2"; shift 2 ;;
    --project)       [ $# -ge 2 ] || die "--project requires a value"; PROJECT_DIR="$2"; shift 2 ;;
    --baseline)      [ $# -ge 2 ] || die "--baseline requires a value"; BASELINE_SHA="$2"; BASELINE_SEEN=1; shift 2 ;;
    --session-epoch) [ $# -ge 2 ] || die "--session-epoch requires a value"; SESSION_EPOCH="$2"; EPOCH_SEEN=1; shift 2 ;;
    --session)       [ $# -ge 2 ] || die "--session requires a value"; SESSION_ID="$2"; SESSION_SEEN=1; shift 2 ;;
    --dirty-before)  [ $# -ge 2 ] || die "--dirty-before requires a value"; DIRTY_BEFORE="$2"; DIRTY_SEEN=1; shift 2 ;;
    --receipt)       [ $# -ge 2 ] || die "--receipt requires a value"; RECEIPT_PATH="$2"; RECEIPT_EXPLICIT=1; shift 2 ;;
    --inventory)     INVENTORY=1; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$LOG_FILE" ] || die "--log is required"
# `--inventory` reports; it grades nothing and writes nothing. A write-mode
# operand that parses and is then ignored is the shape `zensu-log.sh` refuses
# for its own verbs through `invalid_known_flag`: silently dropping an operand
# the caller supplied is worse than refusing it, because the caller believes it
# took effect. Refuse the whole set rather than the one that writes.
if [ "$INVENTORY" -eq 1 ]; then
  [ "$RECEIPT_EXPLICIT" -eq 0 ] || die "--inventory is read-only and does not accept --receipt"
  [ "$SESSION_SEEN" -eq 0 ] || die "--inventory is read-only and does not accept --session"
  # PRESENCE, never emptiness. `--inventory --baseline ""` parsed, was dropped and
  # exited 0 under the `-z` form — the exact shape the paragraph above forbids,
  # since the caller believes the operand took effect.
  [ "$BASELINE_SEEN" -eq 0 ] || die "--inventory grades nothing and does not accept --baseline"
  [ "$EPOCH_SEEN" -eq 0 ] || die "--inventory grades nothing and does not accept --session-epoch"
  [ "$DIRTY_SEEN" -eq 0 ] || die "--inventory grades nothing and does not accept --dirty-before"
fi
# An empty --session yields no receipt path at all, and the refusal branch that
# would announce it suppresses its own message on an empty path — so the audit
# would exit 0 having written nothing, and `--tdd-complete` would then blame a
# missing receipt. Refuse the operand instead, the way --log is refused.
[ "$SESSION_SEEN" -eq 0 ] || [ -n "$SESSION_ID" ] || die "--session must not be empty"
[ -f "$LOG_FILE" ] || die "run log not found: $LOG_FILE"
[ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

# Resolve the project root before anything else. An unresolvable root must not
# silently degrade into auditing the current directory.
PROJECT_ABS="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || die "cannot resolve project dir: $PROJECT_DIR"

# Every `git` call in this script runs through `_el_git`, which unsets the
# discovery and config-injection variables that would otherwise override `-C`.
# `REPO_ROOT`/`REPO_CANON` decide which absolute claims `absolute_claim_verdict`
# calls FOREIGN, so an ambient `GIT_DIR` or `GIT_WORK_TREE` moves the anchor and
# silently empties the doctor's topology row. Config injection is the other half
# and it has TWO levers, not one — an earlier revision of this comment called
# `GIT_CONFIG_COUNT` "the single lever", and that sentence is why the second one
# went unlooked-for through a whole review round. `GIT_CONFIG_COUNT` gates the
# numbered `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` pairs, so unsetting it
# neutralizes that whole family without enumerating any of it. `GIT_CONFIG_PARAMETERS`
# is git's own SERIALIZED `-c` channel and is gated by nothing: it injects
# directly. Either one left set lets an inherited `core.excludesFile` make
# `check-ignore` succeed for every path, which grades every absent claim
# `EDIT LANDED (untracked-by-design)`. State the count as a PROPERTY — every
# channel by which config reaches git — never as a numeral: the list has been
# wrong at thirteen, at fourteen, and in both directions at once.
#
# AND AN ALLOWLIST BEATS THE DENYLIST FOR THE EXCLUDES LEVER, which is why
# `-c core.excludesFile=/dev/null` rides on every call rather than a sixteenth
# name joining the `unset`. Unsetting `GIT_CONFIG_GLOBAL` does not return git to
# a neutral state; it returns git to its DEFAULT lookups, and the default
# excludes path is `$XDG_CONFIG_HOME/git/ignore`, else `$HOME/.config/git/ignore`,
# consulted with NO `core.excludesFile` entry anywhere. Neither variable carries
# a `GIT_` prefix, so no enumeration of `GIT_*` names can reach that channel —
# a redirected `HOME` alone made `check-ignore` succeed for every path and graded
# every absent claim `EDIT LANDED (untracked-by-design)`.
#
# MEASURED in a throwaway repo with both variables redirected: the default path
# IS consulted (`check-ignore` rc=0); `GIT_CONFIG_GLOBAL=/dev/null` does NOT
# close it (rc=0); the `-c` override DOES (rc=1); and `--exclude-standard`
# honours the same file AND the same override. The last measurement decides the
# SCOPE. It belongs HERE, on every call, not on the `check-ignore` invocation
# alone: `ls-files --others --exclude-standard` builds the union and
# `check-ignore` backs `is_ignored`, so the two must agree about which files are
# ignored. Override only `is_ignored` and a globally-ignored file that genuinely
# landed is absent from the union AND no longer exempt — `EDIT NOT LANDED`, a
# completion-blocking false positive in the one verdict this file reserves for a
# claim that did not land.
#
# ACCEPTED, and priced rather than discovered later: a user's legitimate global
# excludes stop exempting files here, so such a claim now appears in the union
# and grades `EDIT LANDED` on membership rather than through `exempt_ignored` —
# the counters move, the verdict does not. The `is_ignored` exemption then fires
# only for in-repo `.gitignore` and `info/exclude`, which is the honest meaning
# of "untracked BY DESIGN". `.git/info/exclude` stays an in-repo channel this
# does not close: a session that can write the work tree can write it, and that
# is a stated residual rather than a gap nobody noticed.
#
# `zensu-log.sh --tdd-complete`'s `_tc_git` scrubs for its own change count. The
# two lists are MAINTAINED equal rather than shared — this file is spawned as a
# child and inherits the caller's environment, so it must scrub for itself, and a
# sourced third file is the only way to make one list serve both. State the
# relationship, never an equality the code does not carry: the count drifted once
# already, with both sides at thirteen names and neither set a subset of the
# other. `X10e` in tests/structure/test-edit-landing-audit.sh compares the two
# lists directly, so a one-sided addition fails loudly — but note what it CANNOT
# see: two lists that agree and are both short. `X10`/`X17` and their controls
# are what cover that, one behavioural probe per injection channel.
_el_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES \
        GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE GIT_PREFIX \
        GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
  git -c core.excludesFile=/dev/null "$@"
)

IN_GIT=0
REPO_ROOT="$PROJECT_ABS"
if _el_git -C "$PROJECT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT=1
  REPO_ROOT="$(_el_git -C "$PROJECT_ABS" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$PROJECT_ABS"
fi
REPO_CANON="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || REPO_CANON="$REPO_ROOT"
[ -n "$REPO_CANON" ] || REPO_CANON="$REPO_ROOT"

# ── The actual change set ────────────────────────────────────────────────────
# Anchored with -C so the current working directory cannot narrow it: `ls-files`
# is cwd-scoped and would silently drop everything outside a subdirectory.
UNION_FILE="$(mktemp)" || die "mktemp failed"
cleanup() { rm -f "${UNION_FILE:-}" "${CLAIMS_FILE:-}" "${tmp_receipt:-}" "${INV_ROOTS:-}" 2>/dev/null; return 0; }
# A bash trap handler that RETURNS resumes the script, so `trap cleanup ... TERM`
# made the caller's deadline unenforceable: `spawnSync`'s default killSignal is
# SIGTERM, and the doctor bounds this child at 5 s. Worse, `cleanup` unlinks
# CLAIMS_FILE mid-run and the log loop's next `>>` recreated it, so the inventory
# then counted only the claims logged after the signal. Terminate on a signal;
# keep the plain EXIT handler for the ordinary path.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# The four git appends deliberately TOLERATE their command's status — a `git`
# that answers nothing is an ordinary outcome here — and a shell redirect gives
# no status of its own to test, so `|| die` on these lines would refuse a
# healthy run while still saying nothing about a failed WRITE. The write is
# checked where a status exists to check: the sort below reads and rewrites the
# same file and fails on an I/O fault, and the file's own presence is asserted
# after it. That is the honest boundary, and it is stated rather than papered
# over with a check on the wrong object. What it buys: the union is what
# `in_union` answers from, so a partial one makes every absent claim grade
# `EDIT NOT LANDED` — loud — except for an `is_ignored` hit, which flips to
# `EDIT LANDED (untracked-by-design)`, the silent green this audit exists to
# remove.
if [ "$INVENTORY" -eq 0 ] && [ "$IN_GIT" -eq 1 ]; then
  if _el_git -C "$REPO_ROOT" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    _el_git -C "$REPO_ROOT" diff --name-only HEAD -- 2>/dev/null >> "$UNION_FILE"
    # A mid-run commit empties the worktree diff; the baseline range is what
    # keeps those claims verifiable.
    if [ -n "$BASELINE_SHA" ] && _el_git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASELINE_SHA" >/dev/null 2>&1; then
      _el_git -C "$REPO_ROOT" diff --name-only "$BASELINE_SHA"..HEAD -- 2>/dev/null >> "$UNION_FILE"
    fi
  else
    # Unborn HEAD: `diff HEAD` is fatal, so take the index instead.
    _el_git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -- 2>/dev/null >> "$UNION_FILE"
  fi
  _el_git -C "$REPO_ROOT" ls-files --others --exclude-standard -- 2>/dev/null >> "$UNION_FILE"
fi
sort -u -o "$UNION_FILE" "$UNION_FILE" 2>/dev/null \
  || die "the change union could not be sorted"
[ -f "$UNION_FILE" ] || die "the change union file went missing while it was being built"

in_union() { grep -qxF -- "$1" "$UNION_FILE" 2>/dev/null; }

was_dirty_before() {
  [ -n "$DIRTY_BEFORE" ] && [ -f "$DIRTY_BEFORE" ] || return 1
  grep -qxF -- "$1" "$DIRTY_BEFORE" 2>/dev/null
}

is_ignored() {
  [ "$IN_GIT" -eq 1 ] || return 1
  _el_git -C "$REPO_ROOT" check-ignore -q -- "$1" 2>/dev/null
}

trim_claim() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  printf '%s' "$p"
}

# Screen a filesystem root before it reaches a verdict line. Both callers below
# are MODEL-READ channels: skills/tdd/SKILL.md step 5b b) instructs the model to
# copy every non-`EDIT LANDED` line verbatim into the run log, the final report
# and the CHAIN-END SUMMARY, and step 10.2c carries the close marker into the
# REVIEW PACKET. The value itself is a work-tree root discovered by walking up
# from a path a session-writable run log named, so it is attacker-influenced by
# this file's own account of that directory.
#
# The screen lives in hooks/lib/zensu-safe-render.sh and is SOURCED, not copied.
# It was two near-duplicates — this one and `_tc_render_stem` in zensu-log.sh —
# documented as carrying the same rules while already divergent on the
# empty-value arm, and both wrong in the same two ways. That library's header
# carries the rules, the escape/withhold split and the locale pin; do not
# restate them here, because a second statement of a rule is how the pair
# drifted in the first place.
#
# `render_claim_value` is the local NAME, and it is value-neutral on purpose:
# the retired `render_claim_root` described a filesystem root while the function
# screens step ids, repo-relative paths and a work-tree root across every emit.
_EL_SAFE_RENDER_LIB="$(dirname "$0")/zensu-safe-render.sh"
if [ -f "$_EL_SAFE_RENDER_LIB" ] && [ ! -L "$_EL_SAFE_RENDER_LIB" ] && [ -r "$_EL_SAFE_RENDER_LIB" ]; then
  # shellcheck source=hooks/lib/zensu-safe-render.sh
  . "$_EL_SAFE_RENDER_LIB"
fi
if ! command -v zensu_safe_render >/dev/null 2>&1; then
  # Fail CLOSED on a missing screen. Rendering raw would put an unscreened
  # author-written value into a verdict a model relays, which is the one
  # outcome the screen exists to prevent; a withheld value costs a name.
  zensu_safe_render() { printf '%s' "(withheld — the render screen could not be loaded)"; }
fi
render_claim_value() { zensu_safe_render "$1"; }

canon_claim() {
  local p="$1" d rest c
  d="$(dirname "$p")"; rest="$(basename "$p")"
  while [ "$d" != "/" ] && [ "$d" != "." ] && [ ! -d "$d" ]; do
    rest="$(basename "$d")/$rest"
    d="$(dirname "$d")"
  done
  c="$(cd "$d" 2>/dev/null && pwd -P)" || c=""
  [ -n "$c" ] || { printf '%s' "$p"; return 0; }
  case "$c" in
    /) printf '/%s' "$rest" ;;
    *) printf '%s/%s' "$c" "$rest" ;;
  esac
}

# Prints the work tree root above a claim, or NOTHING with status 1. Printing a
# sentence here was a real defect: the one caller captures this in a command
# substitution, so a diagnostic on stdout becomes the VALUE, travels into the
# `foreign-root<TAB><root>` wire format and is rendered by `/zensu:doctor` in
# backticks as a repository to run the chain in — naming a repository that does
# not exist. A failure says so through the status and stays silent on stdout.
# Both walks below are BUDGETED, and the budget is not a micro-optimization.
# `--inventory` runs them over every absolute claim in a session-writable run
# log, one `cd … && pwd -P` plus one `-e` probe per ancestor. The bound above it
# DIFFERS PER CONSUMER: on the `--tdd-complete` path it is `zensu_run_bounded`,
# whose third arm runs the child with NO deadline when the host provides neither
# `timeout` nor `gtimeout`, which is base macOS; on the `/zensu:doctor` path
# `spawnSync` enforces 5 s regardless of PATH. Saying "the only thing above" of
# both was false for one of them. The budget bounds the NUMBER of probes independently of that ladder.
# State what it does not do: a single stalled mount still blocks one `cd`, and no
# in-process cap can change that. 64 ancestors is far above any real repository
# layout.
#
# Exhaustion returns **2**, distinct from the 1 that means "walked to the top and
# found nothing". Collapsing the two was the defect: an earlier revision of this
# comment claimed giving up "reports the claim as unrooted, which is the fail-safe
# direction", and that was false at BOTH call sites. `nested_worktree_of`
# exhausting made `absolute_claim_verdict` fall through to `in-root`, which is
# fail OPEN — the claim is then graded against a repository it may not belong to.
# `claim_root_of` exhausting made the `--inventory` foreign-root list SHORTER
# while `INV_CLAIMS` still counted the claim, which is exactly the truncated
# clean answer `INV_CLAIM_BUDGET` was hardened to exit 2 over. `unrooted` is also
# the wrong word for the nested case on its own terms: that walk is reached only
# when the claim IS under `REPO_CANON`, so asserting no work tree above it
# contradicts what the caller just established. Both now answer `undetermined`.
CLAIM_ANCESTOR_BUDGET=64

claim_root_of() {
  local p="$1" probe steps=0
  probe="$(canon_claim "$(dirname "$p")")"
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
    [ "$steps" -lt "$CLAIM_ANCESTOR_BUDGET" ] || return 2
    steps=$((steps + 1))
    if [ -e "$probe/.git" ]; then printf '%s' "$probe"; return 0; fi
    probe="$(dirname "$probe")"
  done
  if [ -e "/.git" ]; then printf '/'; return 0; fi
  return 1
}

# Prints the root of a work tree NESTED under the anchor, or nothing with status
# 1. Status 2 means the ancestor budget ran out before the question was settled —
# see CLAIM_ANCESTOR_BUDGET above for why that is not the same answer. The walk
# stops BELOW `$REPO_CANON`, so the anchor itself never matches.
nested_worktree_of() {
  local cp="$1" probe steps=0
  probe="$(dirname "$cp")"
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ] && [ "$probe" != "$REPO_CANON" ]; do
    [ "$steps" -lt "$CLAIM_ANCESTOR_BUDGET" ] || return 2
    steps=$((steps + 1))
    case "$probe" in
      "$REPO_CANON"/*) ;;
      *) return 1 ;;
    esac
    if [ -e "$probe/.git" ]; then printf '%s' "$probe"; return 0; fi
    probe="$(dirname "$probe")"
  done
  return 1
}

# FOUR kinds. The third exists because the second's value domain is a PATH, and
# the fourth because "the walk gave up" is not an answer to the question:
#   in-root<TAB><repo-relative path>
#   foreign<TAB><work tree root>
#   unrooted<TAB><claim directory>      — no work tree above the claim at all
#   undetermined<TAB><claim directory>  — the ancestor budget ran out first
# Every consumer must handle all four. `normalize_claim`'s dispatch below is a
# closed `foreign`/`unrooted`/`undetermined` ladder with a silent `else` that
# takes `${verdict#*\t}` as a repo-relative PATH, so an unhandled new kind does
# not fail — it grades a diagnostic string as a file. Add an arm before adding a
# kind.
# Classification is RESOLVE-then-classify, and it is resolve-ONLY: the claim is
# canonicalized first and the ONLY membership test is `"$REPO_CANON"/*`. A
# lexical `"$REPO_ROOT"/*` prefix is not the same question as "the anchor's git
# can see this path", and it was wrong in BOTH directions. A git worktree or
# submodule nested under the anchor sits inside that prefix while its change set
# belongs to another repository — this repository's own convention puts every
# session worktree under an ignored `.claude/worktrees/`, where the lexical test
# graded such a claim `EDIT LANDED (untracked-by-design)`. And a component
# INSIDE the anchor that is a symlink pointing OUT also matches that prefix,
# while its canonical form is in another repository entirely; `nested_worktree_of`
# cannot catch that one either, because its own `"$REPO_CANON"/*` guard fails on
# the first iteration once the claim has been resolved out of the tree.
# The lexical arm covered nothing the canonical one does not: `canon_claim` of an
# in-root path is under `REPO_CANON` by construction, which is what keeps the
# macOS `/var` versus `/private/var` spelling in-root. X5 covers the outside
# spelling that resolves inside; X11 covers the inside spelling that resolves out.
absolute_claim_verdict() {
  local p="$1" cp rel nested root
  cp="$(canon_claim "$p")"
  rel=""
  case "$cp" in
    "$REPO_CANON"/*) rel="${cp#"$REPO_CANON"/}" ;;
  esac
  if [ -n "$rel" ]; then
    nested="$(nested_worktree_of "$cp")"
    case "$?" in
      0)
        printf 'foreign\t%s' "$nested"
        return 0
        ;;
      2)
        # The budget ran out. Falling through to `in-root` here would grade the
        # claim against the anchor on the strength of a walk that never finished.
        printf 'undetermined\t%s' "$(canon_claim "$(dirname "$cp")")"
        return 0
        ;;
    esac
    printf 'in-root\t%s' "$rel"
    return 0
  fi
  # Both of these take the CANONICAL claim, never the raw one. `canon_claim`
  # resolves a path's PARENT and leaves the final component alone, so handing it
  # the raw claim leaves a symlinked leaf directory unfollowed: the walk then
  # finds the anchor's own `.git` above the link and names the ANCHOR as the
  # repository the work belongs to — the one answer that is certainly wrong here,
  # since `rel` being empty already proved the claim resolves out of it.
  root="$(claim_root_of "$cp")"
  case "$?" in
    0)
      printf 'foreign\t%s' "$root"
      return 0
      ;;
    2)
      printf 'undetermined\t%s' "$(canon_claim "$(dirname "$cp")")"
      return 0
      ;;
  esac
  printf 'unrooted\t%s' "$(canon_claim "$(dirname "$cp")")"
  return 0
}

# ── Claim extraction ─────────────────────────────────────────────────────────
# Only the two contracted forms carry a gradeable file list. Any other entry
# whose step id is followed by WIRED names nothing that can be checked and is
# reported UNVERIFIED — a legacy or malformed entry must never read as passing.
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
  local raw="$1" p verdict kind
  p="$(trim_claim "$raw")"
  [ -n "$p" ] || return 1
  # The run log is REDACTED on the way in. `zensu-log.sh append` routes every
  # line through `zensu-artifact-redact-v1.js`, whose FIRST rule rewrites the
  # project root to the literal `<project>` — so an author who spells a claim
  # absolutely inside the anchor gets `<project>/src/x.ts` in the log, which has
  # no leading `/`, never reaches `absolute_claim_verdict`, is in the union under
  # no spelling, and used to fall through the `*/*` arm verbatim: `EDIT NOT
  # LANDED` for an edit that DID land, `clean: false`, a refused `--tdd-complete`
  # and a step 5b b) remedy — land it at the path the claim names — that cannot
  # be performed. Stripping is sound HERE and only here: the placeholder denotes
  # the root this run was handed, so the remainder is repo-relative by
  # construction. Two bounds travel with it. The redactor's `projectRoot` accepts
  # an ARRAY and renders every member as the same `<project>`, so a log written
  # against two roots is ambiguous and this strip silently picks the audited one.
  # State that bound UNESTABLISHED rather than closed: an earlier revision said
  # `append` "forces the two authorities to agree through `expectedRoot`
  # whenever `CLAUDE_PROJECT_DIR` is set, which is the normal case", and
  # CLAUDE.md §"Artifact Path Redaction" records the opposite for this host —
  # the variable is absent from the model's Bash environment here, which is why
  # `{log_file}` is rendered from `${CLAUDE_PROJECT_DIR:-.}`. Whether `append`
  # can reach the multi-member array without it was not traced, so the honest
  # word is unverified. This is the one transform in the file that can turn
  # `EDIT NOT LANDED` into `EDIT LANDED`, which is why the bound is stated
  # rather than assumed. And the `~` half is
  # deliberately NOT stripped — `$HOME` names any home-rooted path, including a
  # genuine sibling repository, so guessing there would relabel foreign work as
  # in-anchor. That one stays a stated bound; X16/X16a pin it.
  _nc_stripped=0
  case "$p" in
    '<project>'|'<home>') return 1 ;;
    '<project>/'*) p="${p#<project>/}"; _nc_stripped=1 ;;
    # A literal backslash, written as an escaped character outside quotes: the
    # redactor's `rootSpellings` adds a backslash-separated form of every root,
    # so this is the second half of one rule rather than a second rule.
    '<project>'\\*) p="${p#<project>\\}"; _nc_stripped=1 ;;
    # `<home>` is the redactor's THIRD rule and is NOT stripped. It stands for a
    # residual `/Users/<seg>`, `/home/<seg>` or `/root`, which names no
    # particular root this run can resolve — the same reason `~` is not
    # stripped. Named here so the census is three rules rather than the two it
    # read as, and REFUSED rather than falling through to be graded relative.
    '<home>/'*|'<home>'\\*) return 1 ;;
  esac
  if [ "$_nc_stripped" -eq 1 ]; then
    [ -n "$p" ] || return 1
    # Re-checked, and ONLY for a stripped remainder — an ordinary absolute claim
    # is the next `case`'s business and must not be refused here. This is the
    # one non-absolute spelling that can leave the anchor: `<project>/../../x`
    # stays relative, so it never reaches `absolute_claim_verdict`, and the
    # `[ -e "$REPO_ROOT/$p" ]` test below resolves `..` through the filesystem
    # straight out of the tree. The test is ANCHORED, so a real file named
    # `..bak` inside the tree is inside it.
    case "$p" in
      /*|..|../*|*/../*|*/..) return 1 ;;
    esac
  fi
  case "$p" in
    /*)
      verdict="$(absolute_claim_verdict "$p")"
      kind="${verdict%%$'\t'*}"
      # A CLOSED case, not a ladder with a silent `else`. The retired shape
      # took `${verdict#*\t}` as a repo-relative PATH for anything it did not
      # recognise, so a kind added to the classifier without an arm here graded
      # a diagnostic string as a file. `in-root` is named explicitly and the
      # residual REFUSES.
      case "$kind" in
        foreign)
          printf '%s' "${verdict#*$'\t'}"
          return 3
          ;;
        unrooted)
          printf '%s' "${verdict#*$'\t'}"
          return 4
          ;;
        undetermined)
          printf '%s' "${verdict#*$'\t'}"
          return 5
          ;;
        in-root)
          p="${verdict#*$'\t'}"
          ;;
        *)
          return 1
          ;;
      esac
      ;;
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
  local step="$1" raw="$2" resolved rc
  CLAIM_COUNT=$((CLAIM_COUNT + 1))
  resolved="$(normalize_claim "$raw")"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED (foreign root) — $(render_claim_value "${step}"): claimed \"$(render_claim_value "$(trim_claim "$raw")")\" resolves outside the audited root $(render_claim_value "$REPO_ROOT") — it belongs to $(render_claim_value "$resolved"). One audit run grades ONE root: this run can neither see that repository's change set nor write a receipt for it, so the claim is reported rather than graded."
    return
  fi
  if [ "$rc" -eq 5 ]; then
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED (undetermined root) — $(render_claim_value "${step}"): claimed \"$(render_claim_value "$(trim_claim "$raw")")\" could not be placed: the ancestor walk from $(render_claim_value "${resolved}") gave up after ${CLAIM_ANCESTOR_BUDGET} levels without reaching a work tree or the top of the filesystem. Nothing here establishes which repository the claim belongs to, so it is reported rather than graded."
    return
  fi
  if [ "$rc" -eq 4 ]; then
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED (no work tree) — $(render_claim_value "${step}"): claimed \"$(render_claim_value "$(trim_claim "$raw")")\" resolves outside the audited root $(render_claim_value "$REPO_ROOT") and no git work tree was found above $(render_claim_value "$resolved"), so there is no repository to name and nothing to grade the claim against."
    return
  fi
  if [ "$rc" -ne 0 ] || [ -z "$resolved" ]; then
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED — $(render_claim_value "${step}"): claimed \"$(render_claim_value "$(trim_claim "$raw")")\" could not be resolved to a repo-root-relative path"
    return
  fi
  if in_union "$resolved"; then
    # Membership is worktree-scoped: a file already dirty before this round
    # reads as landed even when THIS round's replacement matched nothing.
    if was_dirty_before "$resolved"; then
      PENDING=$((PENDING + 1))
      emit "PENDING PREDICATE — $(render_claim_value "${step}"): $(render_claim_value "${resolved}") was already dirty before this round; union membership is not evidence — re-read the target predicate"
      return
    fi
    LANDED=$((LANDED + 1))
    emit "EDIT LANDED — $(render_claim_value "${step}"): $(render_claim_value "${resolved}")"
    return
  fi
  # Absent. Exactly two absences are legitimate, and both must be proven.
  if is_ignored "$resolved"; then
    EXEMPT_IGNORED=$((EXEMPT_IGNORED + 1))
    LANDED=$((LANDED + 1))
    emit "EDIT LANDED (untracked-by-design) — $(render_claim_value "${resolved}")"
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
        emit "PENDING PREDICATE — $(render_claim_value "${step}"): $(render_claim_value "${resolved}") mtime is newer than session start, but this is not a git work tree — re-read the target predicate"
        return
      fi
    fi
    UNVERIFIED=$((UNVERIFIED + 1))
    emit "UNVERIFIED — $(render_claim_value "${step}"): $(render_claim_value "${resolved}") cannot be checked outside a git work tree"
    return
  fi
  NOT_LANDED=$((NOT_LANDED + 1))
  emit "EDIT NOT LANDED — $(render_claim_value "${step}"): claimed $(render_claim_value "${resolved}"), git shows no change"
}

CLAIM_LABEL_TOKEN_BUDGET=5

claim_label() {
  local rest="$1" tok count=0
  CLAIM_LABEL=""
  case "$rest" in
    *[\'\"\|]*) return 1 ;;
  esac
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$rest" ] || return 0
    [ "$count" -lt "$CLAIM_LABEL_TOKEN_BUDGET" ] || return 1
    tok="${rest%%[[:space:]]*}"
    rest="${rest#"$tok"}"
    CLAIM_LABEL="${CLAIM_LABEL:+$CLAIM_LABEL }$tok"
    count=$((count + 1))
  done
}

# Read the log. A claim opens with a short step label directly followed by its marker.
LOG_LINE_NO=0
while IFS= read -r line || [ -n "$line" ]; do
  LOG_LINE_NO=$((LOG_LINE_NO + 1))
  entry="${line#"${line%%[![:space:]]*}"}"
  case "$entry" in
    \[*\]*) entry="${entry#*\]}"; entry="${entry#"${entry%%[![:space:]]*}"}" ;;
  esac
  case "$entry" in
    'EDIT LANDED '*|'EDIT NOT LANDED '*|'EDIT LANDING AUDIT '*|'PENDING PREDICATE '*|'UNVERIFIED '*|'RECEIPT REFUSED '*) continue ;;
  esac
  marker=""
  claim_lead=""
  for candidate in "IMPL completed — files:" "IMPL completed – files:" "IMPL completed - files:" \
                   "WIRED — files:" "WIRED – files:" "WIRED - files:" "WIRED (verified, no change)"; do
    case "$entry" in
      *"$candidate"*)
        lead="${entry%%"$candidate"*}"
        if [ -z "$marker" ] || [ "${#lead}" -lt "${#claim_lead}" ]; then
          marker="$candidate"
          claim_lead="$lead"
        fi
        ;;
    esac
  done
  if [ -n "$marker" ] && claim_label "$claim_lead"; then
    step="${CLAIM_LABEL:-(none)}"
  else
    step="${entry%%[[:space:]]*}"
    marker="${entry#"$step"}"
    marker="${marker#"${marker%%[![:space:]]*}"}"
    case "$marker" in
      WIRED*) marker="WIRED" ;;
      *) continue ;;
    esac
  fi
  case "$marker" in
    "WIRED (verified, no change)")
      # Contract: a step that verified an existing wiring instead of changing
      # one. Exempt, and counted so the receipt shows it was used.
      EXEMPT_VERIFIED=$((EXEMPT_VERIFIED + 1))
      continue
      ;;
    WIRED)
      [ "$INVENTORY" -eq 1 ] && continue
      UNVERIFIED=$((UNVERIFIED + 1))
      CLAIM_COUNT=$((CLAIM_COUNT + 1))
      # The LINE NUMBER, never the line. This value is wholly author-written and
      # shares a NAMESPACE with this file's own verdict vocabulary, so no
      # character screen closes it: a log line reading
      # `[ts] T05 WIRED EDIT LANDED — T01: src/x.ts` is a well-formed bare
      # claim and used to render a forged `EDIT LANDED` inside a
      # diagnostic that skills/tdd/SKILL.md step 5b b) tells the model to copy
      # verbatim into the run log, the report and the CHAIN-END SUMMARY — and a
      # spelling with no colon carries no forbidden character under any screen.
      # Screening characters was the wrong instrument for the wrong value. The
      # number identifies the entry precisely and carries zero author bytes.
      # The step id is kept and SCREENED. It is the one token in the line that
      # is bounded by the step-id split above, and dropping it would cost
      # the reader the only thing that says WHICH step is unverifiable — the
      # line number says where, the step id says what.
      emit "UNVERIFIED — a WIRED entry at run-log line ${LOG_LINE_NO} (step $(render_claim_value "${step}")) names no files: list and cannot be graded"
      continue
      ;;
    *" files:")
      files="${entry#*"$marker"}"
      ;;
    *) continue ;;
  esac
  # Commentary after ' | ' is not part of the file list.
  files="${files%%|*}"
  printf '%s\n' "$files" | tr ',' '\n' | while IFS= read -r one; do
    printf '%s\t%s\n' "$step" "$one"
  done >> "$CLAIMS_FILE" || die "a claim could not be recorded"
done < "$LOG_FILE"

if [ "$INVENTORY" -eq 1 ]; then
  INV_CLAIMS=0
  INV_FAULT=""
  INV_ROOTS="$(mktemp)" || die "mktemp failed"
  while IFS="$(printf '\t')" read -r step raw; do
    [ -n "${raw// /}" ] || continue
    if [ "$INV_CLAIMS" -ge "$INV_CLAIM_BUDGET" ]; then
      # FIRST fault wins, at every site. These are set inside a loop and no arm
      # breaks, so a later iteration used to overwrite the cause that fired
      # first. Every path still exits 2, so no verdict changed — only the named
      # cause, in a file whose comments repeatedly insist on naming the right one.
      [ -n "$INV_FAULT" ] || INV_FAULT="the run log names more than ${INV_CLAIM_BUDGET} claimed files"
      break
    fi
    INV_CLAIMS=$((INV_CLAIMS + 1))
    INV_PATH="$(trim_claim "$raw")"
    case "$INV_PATH" in
      /*)
        INV_VERDICT="$(absolute_claim_verdict "$INV_PATH")"
        case "${INV_VERDICT%%$'\t'*}" in
          # The append is CHECKED. An ENOSPC, a full tmpfs or a destination that
          # cannot be created silently dropped that root, and the caller then read
          # a short list as a complete one.
          foreign)
            # One root per line IS the wire format, so a root carrying a newline
            # would publish a SECOND `foreign-root` line naming a fragment. The
            # guard is LOAD-BEARING. An earlier revision called it defence in
            # depth over an unreachable path, on the ground that only a claim
            # whose own path contains the newline could derive such a root. That
            # is false: the root does not come from the claim, it comes from
            # `canon_claim`, whose `cd … && pwd -P` resolves a symlink to the
            # PHYSICAL name — so a newline-FREE claim through a link to a
            # newline-named directory synthesizes one, and creating that pair
            # needs only a shell inside the session. Do not delete this on an
            # unreachability argument; X27c drives exactly that shape.
            # `$'\n'` and NOT `"$(printf '\n')"`: command substitution strips
            # trailing newlines, so that spelling expands to the empty string and
            # the pattern degrades to `**`, which matches every root — the guard
            # then reported EVERY foreign root as a fault and emptied the list it
            # exists to protect.
            case "${INV_VERDICT#*$'\t'}" in
              *$'\n'*)
                [ -n "$INV_FAULT" ] || INV_FAULT="a foreign root contains a newline and cannot be carried on this wire format"
                ;;
              *)
                printf '%s\n' "${INV_VERDICT#*$'\t'}" >> "$INV_ROOTS" 2>/dev/null \
                  || { [ -n "$INV_FAULT" ] || INV_FAULT="a foreign root could not be recorded"; }
                ;;
            esac
            ;;
          # A claim whose ancestor walk gave up contributes no root while
          # INV_CLAIMS still counts it, so staying quiet here prints a SHORT
          # list and exits 0 — the truncated clean answer this mode exits 2
          # over everywhere else.
          undetermined)
            [ -n "$INV_FAULT" ] || INV_FAULT="a claim could not be placed: its ancestor walk gave up after ${CLAIM_ANCESTOR_BUDGET} levels"
            ;;
          # The known-silent kinds, ENUMERATED rather than left to a catch-all.
          # Both legitimately contribute no root, so folding them into the
          # refusal below would fault on nearly every ordinary claim and make
          # `--inventory` exit 2 on every normal chain.
          in-root|unrooted)
            ;;
          # Anything else is a kind this mode does not know. Silence here is the
          # same short-list-and-exit-0 the `undetermined` arm above exists to
          # prevent, so a new kind added to the classifier without an arm here
          # fails LOUDLY instead of quietly shortening the answer.
          *)
            [ -n "$INV_FAULT" ] || INV_FAULT="the claim classifier answered a kind this mode does not handle"
            ;;
        esac
        ;;
    esac
  done < "$CLAIMS_FILE"
  printf 'claimed-files=%s\n' "$INV_CLAIMS"
  # Sort into a variable rather than into a pipeline: a pipeline's status is the
  # LAST command's, so `sort | while` reported the loop's success and swallowed
  # the sort's failure.
  if [ -z "$INV_FAULT" ]; then
    INV_SORTED="$(sort -u "$INV_ROOTS" 2>/dev/null)" || INV_FAULT="the foreign-root list could not be read back"
  fi
  if [ -z "$INV_FAULT" ]; then
    printf '%s\n' "$INV_SORTED" | while IFS= read -r inv_root; do
      [ -n "$inv_root" ] && printf 'foreign-root\t%s\n' "$inv_root"
    done
  fi
  rm -f "$INV_ROOTS" 2>/dev/null
  # 2 is this file's reserved environment-error code, and both consumers already
  # treat a non-zero inventory as "did not complete": `--tdd-complete` sets
  # `_tc_log_state=inventory-failed` and discloses, and the doctor's topology row
  # renders a WARN. Exiting 0 here is what made a truncated answer read as clean.
  if [ -n "$INV_FAULT" ]; then
    echo "zensu-edit-landing.sh: --inventory did not complete — ${INV_FAULT}. The foreign-root list is incomplete; treat this as 'did not complete', never as 'no foreign roots'." >&2
    exit 2
  fi
  exit 0
fi

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
    # The fallback is the RAW --session operand, and it lands in a filesystem path
    # two lines down. Anything that is not the canonical key shape is refused: a
    # value like `../../tmp/x` yields an absolute path that passes every guard
    # below and would place session state outside .zensu/state entirely.
    if [ -z "$_key" ]; then
      # ANCHORED, not a `case` glob: in a glob `*` matches `/` and `.`, so
      # `scv1_a/../../tmp/x` would pass a `scv1_[0-9a-f]*` pattern and then pass
      # the prefix containment below as well, because the string does start with
      # the state directory. The canonical key is exactly 64 hex characters.
      if [[ "$SESSION_ID" =~ ^scv1_[0-9a-f]{64}$ ]]; then
        _key="$SESSION_ID"
      else
        _key=""
      fi
    fi
    RECEIPT_PATH="$PROJECT_ABS/.zensu/state/edit-landing-${_key}.json"
  fi
  # A receipt whose name ends in `-` means the session key resolved empty; a
  # RELATIVE path means the caller's cwd decides where it lands. Both have put
  # `edit-landing-.json` in a repository root. Refuse rather than write blind:
  # the receipt is state, and state belongs under the project's .zensu/state.
  # A DERIVED receipt path must still live under the audited project's own state
  # directory — that is what bounds the session-key fallback above. An EXPLICIT
  # `--receipt` is a caller-chosen destination and keeps its documented freedom;
  # the shape checks below still apply to it.
  if [ "$RECEIPT_EXPLICIT" -eq 0 ]; then
    case "$RECEIPT_PATH" in
      *"/../"*|*/..)
        emit "RECEIPT REFUSED — the derived receipt path contains a parent-directory segment ($(zensu_safe_render "${RECEIPT_PATH}"))"
        RECEIPT_PATH=""; RECEIPT_FAILED=1
        ;;
    esac
    case "$RECEIPT_PATH" in
      ""|"$PROJECT_ABS"/.zensu/state/*) ;;
      *)
        emit "RECEIPT REFUSED — the derived receipt path escapes $(zensu_safe_render "${PROJECT_ABS}")/.zensu/state ($(zensu_safe_render "${RECEIPT_PATH}"))"
        RECEIPT_PATH=""; RECEIPT_FAILED=1
        ;;
    esac
  fi
  case "$RECEIPT_PATH" in
    ""|*/edit-landing-.json|edit-landing-.json)
      # `RECEIPT_FAILED=1` only when a receipt was actually EXPECTED. An invocation
      # that asked for none (no `--session`, no `--receipt`) arrives here with an
      # empty path and must still exit 0; one whose key resolved empty asked for a
      # receipt and got none, and exiting 0 there is what makes `--tdd-complete`
      # blame a missing receipt instead of naming this cause. It is deliberately
      # NOT `CLEAN=0` — see the exit contract at the foot of this file: the claims
      # may all have landed perfectly, and saying otherwise names the wrong cause.
      [ -n "$RECEIPT_PATH" ] && { emit "RECEIPT REFUSED — the session key resolved empty, so no receipt was written (would have been $(zensu_safe_render "${RECEIPT_PATH}"))"; RECEIPT_FAILED=1; }
      RECEIPT_PATH=""
      ;;
    /*) ;;
    *)
      emit "RECEIPT REFUSED — a relative --receipt path would land in the caller's cwd, not the project state dir ($(zensu_safe_render "${RECEIPT_PATH}"))"
      RECEIPT_PATH=""; RECEIPT_FAILED=1
      ;;
  esac
  if [ -n "$RECEIPT_PATH" ]; then
    mkdir -p "$(dirname "$RECEIPT_PATH")" 2>/dev/null
    # `mktemp` in the destination directory rather than a predictable
    # "${RECEIPT_PATH}.tmp.$$": a plain `>` follows a symlink pre-planted at a
    # guessable path, and this file is now a gate input, not just a report.
    # No predictable fallback: reinstating "${RECEIPT_PATH}.tmp.$$" would restore
    # exactly the pre-planted-symlink hazard this replaced, and a check-then-open
    # on that name is a TOCTOU window rather than a fix. A failed acquisition is a
    # REFUSAL that announces itself — silently writing nothing would surface later
    # as `--tdd-complete` blaming a missing receipt, which is the wrong cause.
    tmp_receipt="$(mktemp "${RECEIPT_PATH}.tmp.XXXXXX" 2>/dev/null)" || tmp_receipt=""
    if [ -z "$tmp_receipt" ] || [ -L "$tmp_receipt" ]; then
      [ -n "$tmp_receipt" ] && rm -f "$tmp_receipt" 2>/dev/null
      emit "RECEIPT REFUSED — could not create a temp file beside $(zensu_safe_render "${RECEIPT_PATH}"); no receipt was written"
      tmp_receipt=""; RECEIPT_FAILED=1
    fi
    if [ -n "$tmp_receipt" ]; then
      # The two string fields are JSON-ENCODED, never interpolated: a session id or
      # a log path containing a quote or a backslash would otherwise emit a document
      # that does not parse — and the receipt now has a consumer that reads `log`
      # back (`--tdd-complete`'s requirements-table gate), where an unparseable
      # receipt degrades silently instead of loudly. `printf '%s'` was that hazard.
      # The `log` value is persisted PROJECT-ANCHORED, not as the caller spelled it:
      # it now has a cross-process consumer (`--tdd-complete`'s requirements-table
      # gate) that must re-derive a sibling path from it, and a relative or
      # differently-spelled value forces that consumer to guess a root.
      # `log` is persisted PROJECT-RELATIVE with `/` separators. It is read back by
      # `--tdd-complete`'s requirements gate, which resolves it against its own root,
      # and a project-relative suffix is the ONE spelling that needs no namespace
      # translation: an absolute value would be written in the shell namespace
      # (`/d/a/proj/...` on Git Bash) and resolved against a native root
      # (`D:/a/proj`), where win32 `path.resolve` reads the leading `/` as
      # drive-relative and splices the whole thing under the current drive. An
      # absolute path is kept only when it falls outside the project, where a
      # relative spelling would be meaningless.
      LOG_ABS="$LOG_FILE"
      # Canonicalized in BOTH branches, not only the relative one: `PROJECT_ABS` is a
      # `cd`+`pwd -P` result, so an absolute caller spelling that differs from it
      # (macOS /var vs /private/var) would never match the prefix below and the
      # value would be persisted absolute after all.
      LOG_ABS="$(cd "$(dirname "$LOG_FILE")" 2>/dev/null && pwd -P || printf '%s' "$(dirname "$LOG_FILE")")/$(basename "$LOG_FILE")"
      case "$LOG_ABS" in
        "$PROJECT_ABS"/*) LOG_ABS="${LOG_ABS#"$PROJECT_ABS"/}" ;;
      esac
      if command -v node >/dev/null 2>&1; then
        ZEL_SESSION="$SESSION_ID" ZEL_LOG="$LOG_ABS" ZEL_CLAIMS="$CLAIM_COUNT" \
        ZEL_LANDED="$LANDED" ZEL_NOT="$NOT_LANDED" ZEL_UNVERIFIED="$UNVERIFIED" \
        ZEL_PENDING="$PENDING" ZEL_EXI="$EXEMPT_IGNORED" ZEL_EXV="$EXEMPT_VERIFIED" \
        ZEL_CLEAN="$([ "$CLEAN" -eq 1 ] && echo true || echo false)" \
        node -e '
          const e = process.env;
          process.stdout.write(JSON.stringify({
            // `edit-landing-v2`, because the MEANING of `log` moved: v1 persisted the
            // raw `--log` spelling as the caller wrote it, v2 persists a
            // project-relative suffix. The
            // receipt is read back by a DIFFERENT process (`zensu-log.sh
            // --tdd-complete`) that may be a newer or older installation — the
            // runtime-lineage rule explicitly SERVES a same-minor upgrade landing
            // between the step 5b audit and completion — so the reader must be able
            // to tell the two domains apart. Holding the discriminator at v1 left it
            // guessing from a leading slash, and that guess rejected readable legacy
            // receipts on win32. The reader accepts BOTH and resolves each by
            // containment; this bump is what makes that branch explicit rather than
            // inferred. A shape change like this costs a `minor` release under the
            // lineage rule, and it costs one whether or not the name moves — the
            // name moving is what buys the reader something for the price.
            schema: "edit-landing-v2",
            session: e.ZEL_SESSION,
            log: e.ZEL_LOG,
            claims: Number(e.ZEL_CLAIMS),
            landed: Number(e.ZEL_LANDED),
            notLanded: Number(e.ZEL_NOT),
            unverified: Number(e.ZEL_UNVERIFIED),
            pending: Number(e.ZEL_PENDING),
            exemptIgnored: Number(e.ZEL_EXI),
            exemptVerified: Number(e.ZEL_EXV),
            clean: e.ZEL_CLEAN === "true",
          }) + "\n");
        ' > "$tmp_receipt" 2>/dev/null && mv -f "$tmp_receipt" "$RECEIPT_PATH" 2>/dev/null \
          || { emit "RECEIPT REFUSED — the receipt could not be written to $(zensu_safe_render "${RECEIPT_PATH}")"; RECEIPT_FAILED=1; }
      else
        # No node: the values would have to be interpolated into JSON unescaped, and
        # this file is now a gate input rather than a report. A quote in either value
        # breaks the document or injects a sibling key, so the fallback ANNOUNCES a
        # refusal instead of writing a document it cannot encode safely.
        emit "RECEIPT REFUSED — node is unavailable, so the receipt could not be encoded safely and none was written"
        RECEIPT_FAILED=1
      fi
      rm -f "$tmp_receipt" 2>/dev/null
    fi
  fi
fi

# Two DIFFERENT failures, two different exit codes, because the caller acts on them
# differently. `CLEAN` is the grading verdict over the claims; exit 1 means at least
# one claimed edit is NOT LANDED / UNVERIFIED / PENDING, and skills/tdd/SKILL.md
# step 5b tells the model to carry that into the report and the chain-end summary.
# A receipt-plumbing failure — no node, an unwritable state dir, a refused path — is
# an ENVIRONMENT error and exits 2, the code this file's header already reserved for
# one. Folding it into exit 1 made a run in which every claim landed report that a
# claimed edit had not: the wrong cause, and the slowest kind to diagnose.
# Grading is reported FIRST: a chain with a real unlanded edit and a broken receipt
# is a grading failure, not a plumbing one.
[ "$CLEAN" -eq 1 ] || exit 1
[ "$RECEIPT_FAILED" -eq 0 ] || exit 2
exit 0
