#!/bin/bash
# Cross-document consistency pin for the multi-repo design set.
#
# Three documents state one design and nothing generates any of them from any
# other. That is a deliberate choice — both HTML pages are self-contained by
# design — but it means every fact stated twice is a fact that can drift, and one
# already had before this pin existed: the specification headed its consumer
# roster "the four multi-repo consumers" while the overview headed the same
# roster "the five consumers".
#
# Most checks here are applied to ALL THREE documents with ONE pattern. An
# earlier revision used a different pattern per document and a different heading
# level per format, which left the exact spelling that motivated the pin
# undetectable in two of the three files. One rule, three files.
#
# TWO CHECKS ARE DELIBERATE EXCEPTIONS, named here rather than left to look like
# oversights: X2 grades the specification's consumer roster and X4 walks its
# fenced code blocks. Both are single-document lints on the specification —
# there is no roster and no fence in either HTML page — and neither has a home
# in the four-suite split, where citations covers all three documents and the
# contrast and structure suites each cover the two pages. They live here because
# this is the file that owns the specification's prose.
#
# ACCEPTED LIMITS:
#   - A count in a heading is checked by forbidding the count, not by comparing
#     two numbers. Forbidding it is the durable fix: a heading with no number
#     cannot disagree with anything. Prose outside a heading may still say
#     "four", because prose describing a four-box diagram legitimately does.
#   - Terminology is checked for ONE term, "satellite", because that is the one
#     that appeared in a title while being absent from the glossary. A general
#     glossary-coverage check would flag ordinary English.
#   - Navigation is checked as "a link exists", not as "the link resolves to a
#     served URL"; these are files opened from a checkout.
#   - The document list comes from `tests/structure/fixtures/multi-repo-docs.txt`,
#     the one registry all four multi-repo doc suites read. X2 and X4 take the
#     first `.md` entry; X6 and X8 take the first two `.html` entries.
#   - X7 pins VERBATIM status prose. It requires the literal
#     `stages 2 and 3 are BLOCKED` in all three documents, so rewording the
#     status is a deliberate three-file edit and not an accident — but a
#     paraphrase that keeps the meaning still fails, and that is the intended
#     cost. Its forbid-list ("non-negotiable" and the spellings beside it) can
#     only ever cover named spellings; a paraphrase of the retracted claim
#     passes. Its carrier conjunct's negator acquittal reads only the 20
#     characters before the FIRST occurrence of the phrase, which narrows but
#     does not close the channel in two ways: a negation inside that span
#     acquits the sentence whatever it actually governs, and a sentence
#     carrying the phrase twice is judged entirely on the first — a negated
#     first mention acquits an un-negated second one.
#     Its carrier conjunct is SENTENCE-scoped: rewrapping cannot evade
#     it, because the block is joined before matching, but a sentence
#     terminator placed between the two phrases can — and whole-block scoping
#     is NOT the fix, because it false-positives on the two passages that
#     legitimately discuss the field's shape and its release cost.
#     Its `Phase 6` trigger requires the correction in the SAME BLOCK,
#     not merely somewhere in the file.
#   - X8 compares only the SHARED token names between the two pages, and only
#     `#rrggbb` values. The overview's warn/ok family has no counterpart on the
#     principle page and is not compared; a token that moved to another colour
#     notation drops out of the comparison and is caught by the contrast suite
#     instead, which fails on any value it cannot compute.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# The document set is read from ONE registry rather than re-spelled here.
# Four suites carried four copies of this list, so a fourth companion document
# was graded by nothing until every copy was remembered.
DOC_REGISTRY="$PLUGIN_DIR/tests/structure/fixtures/multi-repo-docs.txt"
read_registry() {
  [ -f "$DOC_REGISTRY" ] || return 1
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$DOC_REGISTRY" | grep -v '^$'
}
ALL=(); PAGES=(); SPEC=""
while IFS= read -r rel; do
  ALL+=("$PLUGIN_DIR/$rel")
  case "$rel" in
    *.md)   [ -n "$SPEC" ] || SPEC="$PLUGIN_DIR/$rel" ;;
    *.html) PAGES+=("$PLUGIN_DIR/$rel") ;;
  esac
done < <(read_registry)
if [ "${#ALL[@]}" -lt 3 ] || [ -z "$SPEC" ] || [ "${#PAGES[@]}" -lt 2 ]; then
  echo "  FAIL  X0 the document registry could not be read: $DOC_REGISTRY"
  exit 1
fi
OV="${PAGES[0]}"
PR="${PAGES[1]}"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  case "$cond" in
    PASS) echo "  PASS  $label"; PASS=$((PASS+1)) ;;
    *)    echo "  FAIL  $label"; FAIL=$((FAIL+1)) ;;
  esac
}

for f in "${ALL[@]}"; do
  if [ ! -f "$f" ]; then
    check "X0 all three documents exist" FAIL
    echo "----"
    echo "test-multi-repo-doc-consistency: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "X0 all three documents exist" PASS

# X1 — no HEADING in any of the three documents states a roster count. One
# alternation, applied to markdown `##`+ and to <h1>/<h2>/<h3> alike, and to
# digits as well as words.
# The number must sit directly on the noun (at most one adjective between), or a
# section number such as "6.3 The consumers" matches its own digits.
COUNT_RE='(#{2,}|<(h[1-6]|title|caption|figcaption)[^>]*>).*((four|five|six|seven|eight)( [a-z-]+)? consumers|[0-9]+ consumers)'
x1=1
for f in "${ALL[@]}"; do
  if grep -qiE "$COUNT_RE" "$f"; then
    echo "  ---   ${f##*/} has a heading stating a consumer count"
    x1=0
  fi
done
[ "$x1" -eq 1 ] && check "X1 no heading in any document states a consumer count" PASS \
                || check "X1 no heading in any document states a consumer count" FAIL

# X2 — the roster is complete in the specification, which owns it.
missing=""
for c in "Edit-landing" "Review packet" "Write gate" "Terminus" "Capability confinement"; do
  grep -qF "$c" "$SPEC" || missing="$missing $c"
done
[ -z "$missing" ] && check "X2 the specification names every consumer in its roster" PASS \
                  || check "X2 the specification names every consumer in its roster (missing:$missing)" FAIL

# X3 — "satellite" is either defined in the glossary or used nowhere.
uses=0
for f in "${ALL[@]}"; do
  n="$(grep -oiE 'satellites?' "$f" | wc -l | tr -d ' ')"
  uses=$((uses + n))
done
defined=0
grep -qE '^\*\*Satellite\*\*' "$SPEC" && defined=1
if [ "$uses" -eq 0 ] || [ "$defined" -eq 1 ]; then
  check "X3 'satellite' is defined in the glossary or unused ($uses uses, defined=$defined)" PASS
else
  check "X3 'satellite' is defined in the glossary or unused ($uses uses, defined=$defined)" FAIL
fi

# X4 — walk the specification toggling an in-fence flag; every OPENING fence
# must carry a language tag. Counting fences cannot do this: a mistagged closer
# shifts the allowance, and a fence inside a tagged block breaks the arithmetic.
x4="$(awk '
  /^```/ {
    if (!inside) { inside=1; if ($0 == "```") bare++ ; opens++ }
    else { inside=0 }
    next
  }
  END { printf "%d %d %d\n", opens, bare, inside }
' "$SPEC")"
opens="${x4%% *}"; rest="${x4#* }"; bare="${rest%% *}"; unclosed="${rest##* }"
if [ "$unclosed" -ne 0 ]; then
  check "X4 every opening fence carries a language tag (unterminated fence)" FAIL
elif [ "$opens" -eq 0 ]; then
  check "X4 every opening fence carries a language tag (no fenced block present)" PASS
elif [ "$bare" -eq 0 ]; then
  check "X4 every opening fence carries a language tag ($opens block(s))" PASS
else
  check "X4 every opening fence carries a language tag ($bare of $opens bare)" FAIL
fi

# X5 — each document references the OTHER TWO. Two explicit assertions per file,
# never one alternation that either link alone can satisfy.
x5=1
grep -qF "multi-repo-chains-overview.html" "$SPEC"  || { echo "  ---   spec does not reference the overview page"; x5=0; }
grep -qF "multi-repo-chains-principle.html" "$SPEC" || { echo "  ---   spec does not reference the principle page"; x5=0; }
grep -qF 'href="multi-repo-chains-spec.md"' "$OV"        || { echo "  ---   overview does not link the specification"; x5=0; }
grep -qF 'href="multi-repo-chains-principle.html"' "$OV" || { echo "  ---   overview does not link the principle page"; x5=0; }
grep -qF 'href="multi-repo-chains-spec.md"' "$PR"       || { echo "  ---   principle does not link the specification"; x5=0; }
grep -qF 'href="multi-repo-chains-overview.html"' "$PR" || { echo "  ---   principle does not link the overview page"; x5=0; }
[ "$x5" -eq 1 ] && check "X5 each document links the other two" PASS \
                || check "X5 each document links the other two" FAIL

# X6 — the two pages must AGREE on the class name for the open-anchor box, not
# merely both avoid one retired spelling. Compare the declared selectors.
ov_cls="$(grep -oE '\.[a-z-]*anchor-open' "$OV" | sort -u | head -1)"
pr_cls="$(grep -oE '\.[a-z-]*anchor-open' "$PR" | sort -u | head -1)"
if [ -z "$ov_cls" ] || [ -z "$pr_cls" ]; then
  check "X6 both pages declare an open-anchor box class (ov='${ov_cls:-none}' pr='${pr_cls:-none}')" FAIL
elif [ "$ov_cls" = "$pr_cls" ]; then
  check "X6 both pages use one name for the open-anchor box class ($ov_cls)" PASS
else
  check "X6 both pages use one name for the open-anchor box class (ov=$ov_cls pr=$pr_cls)" FAIL
fi

# X7 — the BLOCKED status, and the two claims the specification retracted.
#
# The specification's own status line says stages 2 and 3 are BLOCKED, and §8.1
# says plainly that the workflow document is the wrong carrier and that `vanilla`
# is not a valid precedent for it. A companion page that repeats the design
# WITHOUT the blocker hands a reader the capability grant with the objection
# removed — and the specification points readers at both pages, so a page is a
# likelier destination than the section that retracts it.
#
# Three assertions, each anchored on a phrase the retraction owns:
#   (a) every document carries the BLOCKED status;
#   (b) no document calls the two constraints "non-negotiable" — §8.1 states
#       that constraint 2 is not satisfied by the design as written;
#   (c) a document that raises "Phase 6 NOT complete" must also carry §7.4's
#       correction, which is that TWO edits are needed and that marking Phase 6
#       incomplete is not by itself what keeps the audit out of vanilla.
x7=1
for f in "${ALL[@]}"; do
  grep -qF 'stages 2 and 3 are BLOCKED' "$f" \
    || { echo "  ---   ${f##*/} does not carry the BLOCKED status of the specification"; x7=0; }
  # A forbid-list can only ever cover the spellings it names. The hyphenated
  # form alone left "nonnegotiable" and "not negotiable" free to restate the
  # retracted claim, so the alternation covers the forms an author would
  # plausibly write. It cannot cover a paraphrase.
  if grep -qiE 'non-?negotiable|not negotiable|not open to negotiation' "$f"; then
    echo "  ---   ${f##*/} calls the constraints non-negotiable; spec section 8.1 says constraint 2 is not satisfied"
    x7=0
  fi
  # The trigger was a case-sensitive fixed literal that, in this corpus, occurs
  # ONLY inside the correction sentence — so the guard could never fire on the
  # document it exists to catch. It matches the plausible rewordings now, and
  # the correction is required in the SAME BLOCK rather than anywhere in the
  # file, so a "two edits" a thousand lines away no longer satisfies it.
  #
  # Trigger and conjunct share ONE record scope. A `grep` trigger matches within
  # one physical line while the conjunct reads a paragraph, and all three
  # documents are hand-wrapped at ~95 characters — so splitting the trigger
  # phrase across a line break made the guard not fire at all, and X7 then
  # passed with the correction deleted from the whole file. Both halves now run
  # inside the same joined-record pass, where a line break is just a space.
  if ! awk -v RS='' '{
        s = tolower($0); gsub(/[ \t\n]+/, " ", s)
        if (s ~ /phase 6 (is )?(not) (marked )?complete|phase 6 incomplete|marks phase 6/) {
          if (s !~ /two edits/) bad = 1
        }
      } END { exit bad ? 1 : 0 }' "$f"; then
    echo "  ---   ${f##*/} raises the Phase 6 NOT complete claim in a block that does not carry section 7.4 correction (two edits)"
    x7=0
  fi
  # Section 8.1 rules the workflow document out as the carrier for the root
  # list. A page that names it anyway hands the reader the capability grant
  # with the objection removed, and the BLOCKED literal alone does not stop it.
  #
  # Scoped to a SENTENCE, reached by SPLITTING rather than by a character
  # window, and that choice fixes two defects a window had. `[^.!?]{0,120}`
  # treated every citation dot as a sentence end, so an assertion carrying
  # `zensu-log.sh:400` between its two phrases was missed entirely; and a
  # window matches on proximity alone, so prose that DENIES carriage — "must
  # not live in the workflow document" — was flagged as an assertion of it.
  # Splitting on a terminator FOLLOWED BY A SPACE leaves `.sh:400` and `6.1.1`
  # intact, because neither is followed by one. The negator list then acquits a
  # sentence that states the correct position. It also removes the regex
  # interval, whose support in the CI runner's awk was never verified.
  #
  # Markup is neutralized BEFORE the split, because in the two HTML pages a
  # sentence normally ends at a tag — `release.</strong>` — where the next
  # character is `<` and not a space. Without that, two of the three graded
  # documents got a scope close to the whole-block scope this check rejects.
  #
  # The negator is looked for in the 20 characters immediately PRECEDING the
  # phrase, not anywhere in the sentence. "must not live in the workflow
  # document" is acquitted; "is not optional, and the list is written in the
  # workflow document" is not, because its negation governs something else and
  # falls outside the span.
  #
  # Line scope is not an option: all three documents are hand-wrapped at ~95
  # characters, so the pairing rarely lands on one physical line. Whole-BLOCK
  # scope is not an option either: the overview's minor-release note
  # (multi-repo-chains-overview.html:635-640) holds "in the workflow document"
  # and "codeRoots[]" in ONE paragraph record while discussing release cost, not
  # carriage, so a block-scoped check would flag it.
  if awk -v RS='' '{
        s = tolower($0)
        gsub(/<[^>]*>/, " ", s)          # a sentence in HTML ends at a TAG, not a space
        gsub(/[ \t\n]+/, " ", s)
        n = split(s, sent, /[.!?] /)
        for (i = 1; i <= n; i++) {
          if (sent[i] ~ /coderoots/ && sent[i] ~ /in the workflow document/) {
            k = index(sent[i], "in the workflow document")
            pre = substr(sent[i], (k > 20 ? k - 20 : 1), (k > 20 ? 20 : k - 1))
            if (pre !~ /not |never |no |rules out|ruled out|wrong carrier|cannot|instead of/) hit = 1
          }
        }
      } END { exit hit ? 0 : 1 }' "$f"; then
    echo "  ---   ${f##*/} names the workflow document as the carrier for codeRoots; spec section 8.1 rules it out"
    x7=0
  fi
done
[ "$x7" -eq 1 ] && check "X7 every document carries the BLOCKED status and neither retracted claim" PASS \
                || check "X7 every document carries the BLOCKED status and neither retracted claim" FAIL

# X8 — the two pages hand-duplicate one design-token palette, and the contrast
# suite grades each file independently, so a divergence that still clears 4.5:1
# is invisible there. Cross-page agreement is this file's charter, and X6
# already establishes that agreement on a CSS name is worth pinning; a token
# whose hex drifts between the pages is the same class of defect one level down.
# The overview declares a warn/ok family the principle page does not; only the
# SHARED token names are compared.
x8=1
tokens_of() { sed -n 's/^[[:space:]]*--\([a-z0-9-]*\):[[:space:]]*\(#[0-9a-fA-F]\{6\}\);.*/\1=\2/p' "$1" | tr 'A-F' 'a-f' | sort -u; }
ov_tok="$(tokens_of "$OV")"
pr_tok="$(tokens_of "$PR")"
shared="$(comm -12 <(printf '%s\n' "$ov_tok" | cut -d= -f1 | sort -u) \
                   <(printf '%s\n' "$pr_tok" | cut -d= -f1 | sort -u))"
if [ -z "$shared" ]; then
  echo "  ---   no shared design token could be parsed from the two pages"
  x8=0
else
  for t in $shared; do
    a="$(printf '%s\n' "$ov_tok" | grep "^$t=" | sort -u | tr '\n' ' ')"
    b="$(printf '%s\n' "$pr_tok" | grep "^$t=" | sort -u | tr '\n' ' ')"
    if [ "$a" != "$b" ]; then
      echo "  ---   token --$t differs between the pages (overview: $a| principle: $b)"
      x8=0
    fi
  done
fi
n_shared="$(printf '%s\n' "$shared" | grep -c . || true)"
if [ "${n_shared:-0}" -lt 10 ]; then
  echo "  ---   only ${n_shared:-0} shared tokens compared (expected >= 10); the parser may have stopped matching"
  x8=0
fi
if [ "$x8" -eq 1 ]; then
  check "X8 the two pages declare identical values for all $n_shared shared design tokens" PASS
else
  check "X8 the two pages declare identical values for all shared design tokens" FAIL
fi

echo "----"
echo "test-multi-repo-doc-consistency: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
