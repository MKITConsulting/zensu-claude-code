#!/bin/bash
# zensu-plan-requirements.sh — is a TDD plan's `## Requirements` table usable?
#
# `/zensu:converge` anchors its whole flow-back audit on that table. Without it
# the skill takes its "legacy stop" and reports nothing, and in `/zensu:autopilot`
# the converge stage is machine-mandatory — `OPEN_PR` is reachable only through
# `CONVERGE:CONVERGENCE_PASSED` — so a plan that never filled the table turns a
# mandatory gate into a silent no-op. The failure mode is invisible from both
# ends: converge exits cleanly and the chain closes green.
#
# The table was required by prose only (`skills/tdd/SKILL.md` Phase 2 step 1b),
# and the sole check was the Phase 6 step 6c coverage cross-check, which is
# warning level and skips silently when the table is absent. Prose cannot be
# unit-tested and cannot be gated on; a library can be both. `--tdd-complete`
# calls this and refuses on a non-zero verdict — the same move that verb already
# makes for the edit-landing receipt.
#
# This is STRICTER than `/zensu:converge`, deliberately, and the two are NOT one
# rule. Converge's own check is its Phase 0 step 2 "legacy stop", which keys on
# the table being ABSENT; this library additionally refuses a table that is
# PRESENT but still holds the template's `{curly}` placeholders — the 1.4 % shape
# a presence-only check waves through. They also disagree about deprecated rows,
# in the opposite direction: they count as filled here (see below) while converge
# EXCLUDES them from its coverage checks. Say "stricter", never "identical": a
# plan this library passes is not automatically one converge can audit fully.
# The shape both read is the same — the heading, plus `AC-###`/`FR-###` rows —
# and a change to what counts as a row lands in both, held in step by hand.
#
# "Still a placeholder" is judged on what SURVIVES removing every `{...}` group,
# not on whether braces appear at all. A real requirement may legitimately quote
# one — "refuses when the cell still carries {placeholder} braces" is a filled
# row, and a brace-anywhere rule would reject the very requirement that describes
# this check.
#
# Deprecated rows still count. The never-recycle rule in `skills/tdd/SKILL.md`
# keeps a dropped requirement's row in place, and such a plan has a real
# requirements history for converge to audit against.
#
# Usage:
#   zensu-plan-requirements.sh --plan <path>
#
#   --plan  the TDD plan document to judge (required)
#
# Exit: 0 the table is present and filled; 2 usage error or unreadable plan;
# 3 no `## Requirements` section; 4 the section exists but is not usable — either
# no row carried a recognizable id, or every recognized row's Requirement column
# is still empty. Both are exit 4 because both mean the same thing to the caller
# (converge would audit nothing), but they print DIFFERENT messages: they are
# different edits, and "fill the table" is the wrong instruction for the first.
set -u

PLAN_FILE=""

die() { echo "zensu-plan-requirements.sh: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) [ $# -ge 2 ] || die "--plan requires a value"; PLAN_FILE="$2"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "$PLAN_FILE" ] || die "--plan is required"
# The plan is an ordinary file in the project tree, so the session can write it.
# These are BEST-EFFORT prechecks, NOT the atomic guarantee `plan-payload-v1.js`
# gives for the same artifact class: that module opens once with `O_NOFOLLOW`,
# re-checks dev/ino against the descriptor and refuses `nlink != 1`, while this
# is a `test -L` followed by separate opens for the size and the read, with no
# hard-link refusal. Say "precheck", not "parity". A symlink is refused rather
# than followed because the plan path can be derived from a receipt and following
# a link would let the read leave the project while the verdict still reads as a
# pass; the cap uses the same 4 MiB bound as that module's PLAN_FILE_MAX_BYTES.
# What a defeated precheck can leak is the verdict and the row counts, nothing
# more — which is why the weaker shape is accepted here rather than hidden.
[ ! -L "$PLAN_FILE" ] || die "plan is a symlink, refusing to follow it: $PLAN_FILE"
[ -f "$PLAN_FILE" ] || die "plan not found: $PLAN_FILE"
[ -r "$PLAN_FILE" ] || die "plan is not readable: $PLAN_FILE"
PLAN_BYTES="$(wc -c < "$PLAN_FILE" 2>/dev/null | tr -d '[:space:]')"
case "$PLAN_BYTES" in
  ''|*[!0-9]*) die "plan size is unreadable: $PLAN_FILE" ;;
esac
[ "$PLAN_BYTES" -le 4194304 ] || die "plan exceeds 4 MiB (${PLAN_BYTES} bytes): $PLAN_FILE"

# A single awk pass reports the three facts the verdict needs. `\r` is stripped
# per line so a CRLF checkout cannot hide the heading behind an unmatched `$`.
#
# The plan arrives on STDIN, never as an operand: awk consumes an operand of the
# form `name=value` as a variable assignment and then reads standard input
# instead, and a leading `-` parses as an option. Both are reachable through an
# explicit --plan. The program never uses FILENAME, so the redirect costs nothing.
SUMMARY="$(awk '
  { sub(/\r$/, "") }
  # A fenced code block is DATA, not structure. Without this a plan that merely
  # illustrates the table shape inside a ``` fence reads as having a real table,
  # and an H2 quoted inside a fence closes a real section. Both directions are
  # silent, and a plan documenting this very gate is the obvious trigger.
  #
  # The opener is REMEMBERED — its character and its run length — because a bare
  # toggle flips on any marker line and a plan may legitimately nest one fence
  # inside another (` ``` ` inside a `~~~` block, or a longer run wrapping a
  # shorter one). A toggle then leaves odd parity, the heading below is read as
  # fenced, and the run dies at exit 2 with "unterminated code fence" against a
  # complete table; even parity is worse, because a heading that really was
  # inside an example reads as a real section. CommonMark closes a fence only
  # with a run of the SAME character at least as long as the opener.
  /^[[:space:]]*(```|~~~)/ {
    fmark = $0
    sub(/^[[:space:]]*/, "", fmark)
    fc = substr(fmark, 1, 1)
    fn = 0
    while (substr(fmark, fn + 1, 1) == fc) fn++
    if (!fence) { fence = 1; fchar = fc; flen = fn }
    else if (fc == fchar && fn >= flen) { fence = 0 }
    next
  }
  !fence && /^##[[:space:]]+Requirements[[:space:]]*$/ { heading = 1; in_section = 1; next }
  # Any H1/H2 closes the section. `### Step ...` does not: its third character is
  # `#`, not a space, so a step subsection stays inside the table it belongs to.
  !fence && /^##?[[:space:]]/ { in_section = 0 }
  # The Requirement column is located from the header row rather than assumed to
  # be the second one: the repo-override contract in skills/tdd/SKILL.md pins that
  # an override keeps the section and its columns, never their ORDER, so a
  # positional read would report a compliant re-ordered table as empty. Split index
  # 3 — the second VISIBLE column, since a leading pipe makes index 1 empty — stays
  # the fallback for a table with no recognizable header.
  !fence && in_section && req_col == 0 && /^\|/ && tolower($0) ~ /\|[[:space:]]*requirement[[:space:]]*\|/ {
    n = split($0, head, "|")
    for (i = 2; i <= n; i++) {
      h = tolower(head[i])
      gsub(/[[:space:]]/, "", h)
      if (h == "requirement") { req_col = i; break }
    }
  }
  # A row is recognized by carrying a stable id in ANY cell, not only the first:
  # the same override freedom that moves the Requirement column can move the ID
  # column, and an anchor pinned to column 1 would report such a table as having
  # zero rows at all.
  #
  # The id cell is recognized after INLINE DECORATION is removed, not as a bare
  # literal. A cell spelled `| **AC-001** |`, `| AC-001a |`, `| AC-001, AC-002 |`
  # or `| [AC-001](#ac-001) |` is a real row in a real table, and a bare-literal
  # anchor scores every one of them as zero rows — then refuses a fully populated
  # plan with "the section holds 0 AC/FR row(s)". Emphasis, code spans, strike
  # marks and a link wrapper are all removed before the shape is tested; nothing
  # else about the cell is reinterpreted.
  !fence && in_section && /^\|/ {
    n = split($0, cell, "|")
    idcol = 0
    for (i = 2; i <= n; i++) {
      probe = cell[i]
      # Whitespace goes FIRST, before the link-target removal: that removal is
      # anchored on end-of-string, and a cell is written `| [AC-001](#a) |` with a
      # trailing space, so an unstripped cell never matches and the id is missed.
      gsub(/[[:space:]]/, "", probe)
      # `]` first and `[` last: inside a bracket expression that is the portable
      # way to mean the literal characters rather than open a nested range.
      gsub(/[]*_`~[]/, "", probe)
      sub(/\([^()]*\)$/, "", probe)
      if (probe ~ /^(AC|FR)-[0-9]+[a-z]?(,(AC|FR)-[0-9]+[a-z]?)*$/) { idcol = i; break }
    }
    if (idcol > 0) {
      rows++
      # The judged column is NEVER the id column. Split index 3 stays the
      # fallback for a table with no recognizable header, but an override that
      # moved the ID column can put the id AT index 3 — and an id is never empty
      # and carries no braces, so judging it scores every all-placeholder table
      # as filled. That is exactly the shape exit 4 exists to catch, so the
      # fallback steps aside to the other visible column instead of guessing.
      col = req_col
      if (col == 0 || col == idcol) col = (idcol == 3 ? 2 : 3)
      if (col != idcol && n >= col) {
        text = cell[col]
        # A cell counts as filled only if something remains once every `{...}`
        # group and all whitespace are removed. `[{]`/`[}]` rather than `\{`/`\}`:
        # a brace is an interval operator in POSIX ERE, and only the bracket form
        # is unambiguous across awk implementations.
        gsub(/[{][^{}]*[}]/, "", text)
        gsub(/[[:space:]]/, "", text)
        if (text != "") filled++
      }
    }
  }
  END { printf "%d %d %d %d", heading + 0, rows + 0, filled + 0, fence + 0 }
' < "$PLAN_FILE" 2>/dev/null)" || die "could not read plan: $PLAN_FILE"

[ -n "$SUMMARY" ] || die "plan summary is empty: $PLAN_FILE"
set -- $SUMMARY
HEADING="${1:-0}"
ROWS="${2:-0}"
FILLED="${3:-0}"
FENCE_OPEN="${4:-0}"
# An unparsed summary must not fall through to the OK verdict: a non-numeric value
# makes both `-eq` tests error, and the last branch is the pass.
case "${HEADING}${ROWS}${FILLED}${FENCE_OPEN}" in
  ''|*[!0-9]*) die "plan summary is unreadable: $PLAN_FILE" ;;
esac
# An unterminated fence swallows everything after it, INCLUDING the heading. That
# is a parse failure, not a verdict about the table: reporting it as "no section"
# would tell the author to fill a table that is already filled, and their only
# remaining move would be the escape hatch and an undeserved ledger entry.
[ "$FENCE_OPEN" -eq 0 ] || die "plan has an unterminated code fence, so the document could not be parsed: $PLAN_FILE"

if [ "$HEADING" -eq 0 ]; then
  echo "PLAN REQUIREMENTS MISSING — ${PLAN_FILE}: no \"## Requirements\" section"
  exit 3
fi
# The two exit-4 states are DIFFERENT edits and must not share one message. Zero
# recognized rows is a grammar problem — the author is looking at rows we did not
# read — while rows with nothing in the Requirement column is the placeholder
# verdict this exit was designed for. Telling the first author to "fill the table"
# points them at an edit they already made.
if [ "$ROWS" -eq 0 ]; then
  echo "PLAN REQUIREMENTS UNRECOGNIZED — ${PLAN_FILE}: the section holds no row with a recognizable AC-###/FR-### id. A row is recognized when one cell reduces to the id alone once **bold**, \`code\`, ~~strike~~ and [link](target) decoration is removed; a comma-separated list and a trailing letter (AC-001a) are accepted"
  exit 4
fi
if [ "$FILLED" -eq 0 ]; then
  echo "PLAN REQUIREMENTS EMPTY — ${PLAN_FILE}: the section holds ${ROWS} AC/FR row(s), none with a filled-in requirement"
  exit 4
fi
echo "PLAN REQUIREMENTS OK — ${PLAN_FILE}: ${FILLED}/${ROWS} AC/FR row(s) filled in"
exit 0
