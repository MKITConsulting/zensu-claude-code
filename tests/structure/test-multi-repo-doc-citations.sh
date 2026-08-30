#!/bin/bash
# Citation pin for the multi-repo design documents.
#
# `docs/multi-repo-chains-spec.md` and its two HTML companions are evidence
# documents: nearly every "today" claim in them is backed by a `path:line`
# citation, and the same citation is restated in up to three files with no
# generator keeping them in step.
#
# BE PRECISE ABOUT WHAT THIS CATCHES, because the honest version is much
# narrower than "citations stay correct". A citation that comes to point at a
# DIFFERENT BUT SUBSTANTIVE line is invisible here — and that is the common
# case, since roughly 94% of lines in the cited files are substantive. Four
# citations in the specification land inside one 25-line region of
# `hooks/lib/zensu-log.sh`, so inserting a line above them re-points all four
# and this suite still passes. Closing that would mean carrying a content
# anchor beside every number and matching it within a window; it is not
# implemented, and until it is, a green run means the citations point at
# SOMETHING, not that they point at what the document says.
#
# ONE family of citations IS graded that way, and it is graded ELSEWHERE: `T36` in
# `tests/structure/test-session-trail-skill.sh` pairs every citation from these two
# documents into `skills/session-trail/` with a needle naming the cited CONTENT, across
# both carriers. It lives in that suite rather than here because the files that MOVE those
# targets are the skill's, not the docs'. The pointer is here so an editor working from
# the docs' side — who would naturally run this suite and read this header — finds it:
# a green run HERE does not mean those citations survived. They broke three times in one
# change to that skill while this suite stayed green, which is what prompted `T36`.
#
# The pin is deliberately generic rather than a hand-maintained table of
# expected symbols. A table would be a fourth copy of the citations, with the
# same drift problem one level up. Instead every citation must satisfy two
# mechanical properties:
#
#   1. the cited PATH exists in this repository — lexically inside the root,
#      and still inside it after `realpath`, because every read below follows
#      symlinks and `path.resolve` normalizes `..` textually only;
#   2. the cited LINE (or the first line of a cited range) carries substantive
#      content — it is not blank and not a lone block delimiter (`fi`, `esac`,
#      `done`, `else`, `then`, `do`, `{`, `}`, `)`, `;;`, a markdown table rule).
#
# Property 2 is what catches the two defects this test was written against:
# `skills/tdd/SKILL.md:193` was a blank line and
# `hooks/pre-edit-tdd-reminder.sh:161` was a bare `fi`. Neither is a wrong
# FILE — a path-existence check alone passes both — and both were cited as
# evidence for a claim the reader cannot then verify.
#
# TWO CITATION FORMS ARE EXTRACTED, and the second one is why this file has a
# node probe rather than a single grep. The documents cite in full form
# (`hooks/lib/zensu-log.sh:572`) and in CONTINUATION form — a bare `` `:69-93` ``
# meaning "the file named earlier in this sentence, another line". A grep that
# requires a filename before the colon misses every continuation citation; in
# the specification alone there are twelve, and one of them is the `:551` that
# §11 flags as needing re-verification. A continuation token is therefore
# anchored to the most recent fully-qualified path seen at or before its line.
# A THIRD spelling joins further lines of the same file with a comma
# (`skills/tdd/SKILL.md:181, :184`); its tail elements carry no backtick before
# the colon and are anchored the same way. C3 counts that population with a
# scanner independent of the extractor, so a regex that stops seeing the tail
# cannot agree with its own expectation at zero.
#
# ACCEPTED LIMITS, stated so a green run is not read as more than it is:
#   - It cannot tell whether the cited line SAYS what the document claims it
#     says, and it cannot tell that a citation has SHIFTED onto a neighbouring
#     line. Only a reader can. It catches one mechanical half: a citation that
#     points at nothing. See the paragraph above — this is the dominant
#     limitation, not a footnote.
#   - A comment line is deliberately SUBSTANTIVE. These documents cite comments
#     on purpose — §11 discloses that one claim rests on a comment beside a
#     command rather than on the command's implementation — so rejecting
#     comment lines would flag a legitimate citation.
#   - Shorthand citations that name only a basename (`trail.mjs:769`) are
#     resolved through the `BASENAME_PATH` map below, consumed by the `resolve`
#     closure. A basename this test does not know is a FAILURE, not a skip —
#     for a line citation AND for a bare backticked path, which re-anchors the
#     sentence — so the map cannot silently rot into a no-op.
#   - A continuation token that no preceding full citation can anchor is a
#     FAILURE, for the same reason.
#   - A range's interior is not checked, only its first line.
#   - C1's floors are per DOCUMENT and per FORM. A combined count cannot catch
#     a dead form: dropping the continuation alternative leaves the
#     specification above any total floor, and an unextracted citation emits no
#     failure line either.
#   - C3 pins the extractor against SYNTHETIC input, not against the corpus.
#     Exactly one comma-joined citation exists in the three documents, so a
#     corpus floor turned an author's rewording into a false report of a broken
#     scanner. The corpus population is reported by C4's label and floors
#     nothing.
#   - C4 validates every `BASENAME_PATH` target against the filesystem
#     independently of whether a document spells it, so a renamed target is
#     reported as a MAP defect rather than blamed on the document's line.
#   - The document list comes from `tests/structure/fixtures/multi-repo-docs.txt`,
#     the one registry all four multi-repo doc suites read. C1's per-document
#     floors are still literals here and must be extended for a new document.
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
DOCS=()
while IFS= read -r line; do DOCS+=("$line"); done < <(read_registry)
if [ "${#DOCS[@]}" -lt 3 ]; then
  echo "  FAIL  C0 the document registry could not be read: $DOC_REGISTRY"
  exit 1
fi

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  case "$cond" in
    PASS) echo "  PASS  $label"; PASS=$((PASS+1)) ;;
    *)    echo "  FAIL  $label"; FAIL=$((FAIL+1)) ;;
  esac
}

for d in "${DOCS[@]}"; do
  if [ ! -f "$PLUGIN_DIR/$d" ]; then
    check "C0 document exists: $d" FAIL
    echo "----"
    echo "test-multi-repo-doc-citations: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "C0 all three design documents exist" PASS

# One accumulator, one trap, set BEFORE anything is created — the same shape the
# other two suites carry. Creating the file on the line before the trap that
# owns it leaves a window in which an interruption leaks it, and `mktemp`'s exit
# status went unchecked. `mktmp` assigns in the CALLER's scope and must never be
# called as `$(mktmp …)`: a command substitution is a subshell, so the append
# would mutate a copy and the trap would expand an empty array.
TMPFILES=()
trap 'rm -f ${TMPFILES[@]+"${TMPFILES[@]}"}' EXIT
mktmp() {
  local __var="$1" __t
  __t="$(mktemp -t "$2.XXXXXX")" || return 1
  TMPFILES+=("$__t")
  eval "$__var=\$__t"
}
mktmp PROBE zensu-citation-probe || { check "C0b probe temp file created" FAIL; exit 1; }
cat > "$PROBE" <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const rest = process.argv.slice(3);
const SELFTEST = rest[0] === "--selftest";
const docs = SELFTEST ? [] : rest;

// Basename -> repo-relative path, for citations written without a directory.
// Adding a new shorthand to a document requires adding it here; an unknown
// basename fails rather than being skipped. A null prototype, so a target
// spelled like an inherited property ("constructor", "toString") can never
// resolve through the prototype chain — today TOKEN's extension alternation
// makes that unreachable, but the guard must not depend on a regex fifty
// lines away.
const BASENAME_PATH = Object.assign(Object.create(null), {
  "zensu-log.sh": "hooks/lib/zensu-log.sh",
  "zensu-edit-landing.sh": "hooks/lib/zensu-edit-landing.sh",
  "zensu-tdd-phase.sh": "hooks/lib/zensu-tdd-phase.sh",
  "bash-source-write-parse.js": "hooks/lib/bash-source-write-parse.js",
  "reviewer-capability-v1.js": "hooks/lib/reviewer-capability-v1.js",
  "session-control-core-v1.js": "hooks/lib/session-control-core-v1.js",
  "chain-recovery-v1.js": "hooks/lib/chain-recovery-v1.js",
  "pre-bash-source-write-gate.sh": "hooks/pre-bash-source-write-gate.sh",
  "pre-edit-tdd-reminder.sh": "hooks/pre-edit-tdd-reminder.sh",
  "pre-bash-zensu-gate.sh": "hooks/pre-bash-zensu-gate.sh",
  "pre-write-secret-scan.sh": "hooks/pre-write-secret-scan.sh",
  "trail.mjs": "skills/session-trail/scripts/trail.mjs",
  "stop-chain-enforcer.sh": "hooks/stop-chain-enforcer.sh",
  "CLAUDE.md": "CLAUDE.md",
  "package.json": "package.json",
});

// A line is substantive unless it is empty or a lone block delimiter. Openers
// and continuations are as contentless as closers, so both are rejected.
const DELIMITERS = new Set([
  "fi", "esac", "done", "else", "then", "do", "elif",
  "{", "}", "(", ")", "[", "]", "};", ");", "];", "});", "})", ";;", "*/",
]);
const substantive = (line) => {
  const t = String(line).trim();
  if (!t) return false;
  if (DELIMITERS.has(t)) return false;
  if (/^\|[\s|:-]*\|$/.test(t)) return false; // markdown table rule
  return true;
};

// One combined pattern, so tokens are processed in the order they appear on the
// line rather than grouped by type. Order matters: a sentence may name file A
// with a line, then continuation-cite A, then name file B with a line — grouping
// by type would anchor A's continuation to B.
// A leading `../` is MATCHED on purpose rather than excluded: excluding it
// makes the token start after the traversal, so the citation resolves in-root
// and passes silently. Matching it lets the containment check below reject it.
//   group 1 = a path carrying a line or range   (sets the anchor AND is checked)
//   group 2 = a bare path with no line          (sets the anchor only)
//   group 3 = a continuation token              (checked against the anchor)
//     Terminated by a backtick OR a comma, so the HEAD of a backticked
//     comma-joined run (`` `:2, :3` ``) is graded. Requiring a closing
//     backtick left that head matching no alternative at all: group 3 wanted
//     the backtick and group 4 wanted a preceding comma, so it was extracted
//     by nothing.
//   group 4 = a comma-joined tail element       (checked against the anchor)
// Group 4 exists because the comma spelling `path.md:181, :184` writes its
// second and further elements with NO backtick before the colon, so group 3
// cannot see them. They were extracted by nothing while C2 claimed to cover
// every citation.
const TOKEN = new RegExp(
  "((?:\\.\\./)*[A-Za-z0-9_][A-Za-z0-9_./-]*\\.(?:sh|js|mjs|md|json):[0-9]+(?:-[0-9]+)?)"
  + "|`((?:\\.\\./)*[A-Za-z0-9_][A-Za-z0-9_./-]*\\.(?:sh|js|mjs|md|json))`"
  + "|`:([0-9]+)(?:-[0-9]+)?(?=[`,])"
  + "|,\\s*:([0-9]+)(?:-[0-9]+)?",
  "g",
);

// An INDEPENDENT scanner for the comma-joined spelling, deliberately not
// derived from TOKEN: counting the population with the extractor itself would
// make the comparison vacuous. Its head anchor is an extension OR a backtick,
// because BOTH `path.md:181, :184` and `` `:181, :184` `` are comma-joined
// spellings — anchoring on the extension alone made the two scanners disagree
// by construction on the second form and reported "1 of 0 graded".
const COMMA_TAIL_SCAN =
  /(?:\.(?:sh|js|mjs|md|json)|`):[0-9]+(?:-[0-9]+)?((?:,\s*:[0-9]+(?:-[0-9]+)?)+)/g;
const commaTailPopulation = (line) => {
  let n = 0;
  for (const m of line.matchAll(COMMA_TAIL_SCAN)) {
    n += (m[1].match(/:[0-9]+/g) || []).length;
  }
  return n;
};

const cache = new Map();
const lineAt = (rel, n) => {
  if (!cache.has(rel)) {
    cache.set(rel, fs.readFileSync(path.join(root, rel), "utf8").split("\n"));
  }
  const lines = cache.get(rel);
  return n >= 1 && n <= lines.length ? lines[n - 1] : null;
};

let bad = 0, mapBad = 0;
let commaFound = 0;
const forms = { full: 0, cont: 0, comma: 0 };

// The map is validated against the filesystem BEFORE any document is read.
// Without this a renamed target is reported at the DOCUMENT's line as "cites a
// path that does not exist", blaming the document for a defect that belongs to
// the map — and an entry no document happens to spell is never exercised at all.
for (const [base, rel] of Object.entries(BASENAME_PATH)) {
  if (!fs.existsSync(path.join(root, rel))) {
    console.log("MAP " + base + " -> " + rel + " no longer exists");
    mapBad++;
  }
}

// A cited path must stay INSIDE the repository. The header promises "exists in
// this repository"; existence alone does not deliver that, and the character
// class can carry a traversal segment even without a leading one. The lexical
// check is followed by a CANONICAL one, because `path.resolve` normalizes `..`
// textually only and every read below follows symlinks.
const resolve = (target) => {
  const rel = target.includes("/") ? target : BASENAME_PATH[target];
  if (!rel) return null;
  const abs = path.resolve(root, rel);
  if (abs !== root && !abs.startsWith(root + path.sep)) return "ESCAPE";
  let real;
  try { real = fs.realpathSync(abs); } catch (e) { return rel; } // ENOENT: reported as missing below
  const realRoot = fs.realpathSync(root);
  if (real !== realRoot && !real.startsWith(realRoot + path.sep)) return "ESCAPE";
  return rel;
};

const walk = (lines, rel, report) => {
  let anchor = null;   // most recent fully-qualified path, cleared per block
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Clear the anchor at a block boundary. Without this a continuation whose
    // introducing sentence is later deleted silently re-anchors to a distant
    // unrelated file, which usually HAS a substantive line at that number —
    // the exact silent green this suite exists to prevent.
    if (!line.trim() || /^#{1,6}\s/.test(line) || /^\s*<h[1-6][ >]/.test(line)) anchor = null;
    const at = rel + ":" + (i + 1);
    commaFound += commaTailPopulation(line);
    const grade = (p, start, label) => {
      const content = lineAt(p, start);
      if (content === null || !substantive(content)) {
        report("BAD " + at + " " + label + " resolves to " + p + ":" + start
          + " which carries no substantive content: '"
          + (content === null ? "(out of range)" : content) + "'");
      }
    };
    for (const m of line.matchAll(TOKEN)) {
      if (m[1]) {
        const cut = m[1].lastIndexOf(":");
        const target = m[1].slice(0, cut);
        const start = parseInt(m[1].slice(cut + 1).split("-")[0], 10);
        const p = resolve(target);
        forms.full++;
        if (p === "ESCAPE") {
          report("BAD " + at + " citation escapes the repository root: " + m[1]);
          anchor = null; continue;
        }
        if (!p) {
          report("BAD " + at + " unknown basename '" + m[1] + "' — add it to BASENAME_PATH");
          anchor = null; continue;
        }
        if (!fs.existsSync(path.join(root, p))) {
          report("BAD " + at + " cites a path that does not exist: " + m[1]);
          anchor = null; continue;
        }
        anchor = p;
        grade(p, start, "citation " + m[1]);
      } else if (m[2]) {
        // A bare path with no line re-anchors the sentence. It is not itself a
        // line citation, so it is not counted as one — but every failing
        // outcome is reported and CLEARS the anchor. Falling through silently
        // left a stale anchor, so a following continuation was graded against
        // the previous file: the same silent green the block reset prevents.
        const p = resolve(m[2]);
        if (p === null) {
          report("BAD " + at + " unknown basename '" + m[2] + "' — add it to BASENAME_PATH");
          anchor = null; continue;
        }
        if (p === "ESCAPE") {
          report("BAD " + at + " bare citation escapes the repository root: " + m[2]);
          anchor = null; continue;
        }
        if (!fs.existsSync(path.join(root, p))) {
          report("BAD " + at + " bare citation names a path that does not exist: " + m[2]);
          anchor = null; continue;
        }
        anchor = p;
      } else if (m[3]) {
        forms.cont++;
        if (!anchor) {
          report("BAD " + at + " continuation citation '" + m[0]
            + "' has no preceding fully-qualified path to anchor it");
          continue;
        }
        grade(anchor, parseInt(m[3], 10), "continuation citation " + m[0]);
      } else if (m[4]) {
        forms.comma++;
        if (!anchor) {
          report("BAD " + at + " comma-joined citation element '" + m[0].trim()
            + "' has no preceding fully-qualified path to anchor it");
          continue;
        }
        grade(anchor, parseInt(m[4], 10), "comma-joined citation element " + m[0].trim());
      }
    }
  }
};

if (SELFTEST) {
  // The parser's own properties, exercised against synthetic input rather than
  // against the corpus. C3 used to assert that at least one comma-joined
  // citation exists in the documents — but exactly one does, so rewording that
  // single sentence reported "the scanner may have stopped matching" for a
  // scanner that was fine. The parser is pinned here; the corpus population is
  // reported as an informational number and floors nothing.
  const lines = [
    "head `hooks/lib/zensu-log.sh:1, :2, :3` tail",
    "head `hooks/lib/zensu-log.sh:1` then `:2, :3` tail",
    "head `hooks/lib/zensu-log.sh:1` and `:5` tail",
  ];
  walk(lines, "<selftest>", () => {});
  console.log("SELFTEST full=" + forms.full + " cont=" + forms.cont
    + " comma=" + forms.comma + " commaFound=" + commaFound);
  process.exit(0);
}

const perDoc = [];
for (const rel of docs) {
  const src = fs.readFileSync(path.join(root, rel), "utf8").split("\n");
  const before = { ...forms };
  walk(src, rel, (line) => { console.log(line); bad++; });
  perDoc.push(rel + "=" + (forms.full - before.full) + "/"
    + (forms.cont - before.cont) + "/" + (forms.comma - before.comma));
}
console.log("SUMMARY bad=" + bad + " mapBad=" + mapBad
  + " full=" + forms.full + " cont=" + forms.cont + " comma=" + forms.comma
  + " commaFound=" + commaFound + " " + perDoc.join(" "));
NODE

REPORT="$(node "$PROBE" "$PLUGIN_DIR" "${DOCS[@]}")"
SELF="$(node "$PROBE" "$PLUGIN_DIR" --selftest)"
printf '%s\n' "$REPORT" | grep -E '^(BAD|MAP) ' | sed 's/^/  ---   /' || true

sum_field() { printf '%s\n' "$REPORT" | sed -n "s/^SUMMARY .*[ ]$1=\([0-9]*\).*/\1/p" | tail -1; }
BAD="$(printf '%s\n' "$REPORT" | sed -n 's/^SUMMARY bad=\([0-9]*\) .*/\1/p' | tail -1)"
MAPBAD="$(sum_field mapBad)"
CFOUND="$(sum_field commaFound)"

# C1 — a per-document, per-FORM floor. A combined count cannot catch a dead
# form: deleting the continuation alternative drops the specification from 40
# tokens to 28, which still clears any floor set on the total, and an
# unextracted citation emits no BAD line either — so C2 cannot see it. Each
# form therefore carries its own floor, the same per-form discipline C3 applies
# to the comma spelling. The principle page cites no lines at all by design and
# is required to carry none.
c1=1
for d in "${DOCS[@]}"; do
  trip="$(printf '%s\n' "$REPORT" | sed -n "s|^SUMMARY .*[ ]$d=\([0-9]*/[0-9]*/[0-9]*\).*|\1|p" | tail -1)"
  full="${trip%%/*}"; rest="${trip#*/}"; cont="${rest%%/*}"
  case "$d" in
    *spec.md)
      [ "${full:-0}" -ge 25 ] || { echo "  ---   $d yielded only ${full:-0} full citations (expected >= 25)"; c1=0; }
      [ "${cont:-0}" -ge 10 ] || { echo "  ---   $d yielded only ${cont:-0} continuation citations (expected >= 10)"; c1=0; }
      ;;
    *overview.html)
      [ "${full:-0}" -ge 12 ] || { echo "  ---   $d yielded only ${full:-0} full citations (expected >= 12)"; c1=0; }
      ;;
    *) : ;;
  esac
done
if [ "$c1" -eq 1 ]; then
  check "C1 each citing document yields a plausible count of EACH citation form" PASS
else
  check "C1 each citing document yields a plausible count of EACH citation form" FAIL
fi

if [ "${BAD:-1}" -eq 0 ]; then
  check "C2 every citation — full, bare, continuation and comma-joined — resolves to a substantive line" PASS
else
  check "C2 every citation — full, bare, continuation and comma-joined — resolves to a substantive line ($BAD bad)" FAIL
fi

# C3 — a self-test of the extractor, run against synthetic input.
#
# The comma-joined spelling `path.md:181, :184` writes its second and further
# elements with no backtick before the colon, so the continuation alternative
# cannot see them. Pinning that against the CORPUS was wrong: exactly one such
# citation exists in the three documents, so rewording that single sentence
# reported "the scanner may have stopped matching" for a scanner that was fine.
# The synthetic line carries a known element count instead, the way K3 and P11
# do for their own parsers. The corpus population is reported below as an
# informational number and floors nothing.
sf_comma="$(printf '%s\n' "$SELF" | sed -n 's/^SELFTEST .*[ ]comma=\([0-9]*\).*/\1/p' | tail -1)"
sf_cont="$(printf '%s\n' "$SELF" | sed -n 's/^SELFTEST .*[ ]cont=\([0-9]*\).*/\1/p' | tail -1)"
sf_found="$(printf '%s\n' "$SELF" | sed -n 's/^SELFTEST .*[ ]commaFound=\([0-9]*\).*/\1/p' | tail -1)"
# Three synthetic lines, covering every alternative the corpus exercises:
#   1. `path:1, :2, :3`          -> 1 full + 2 comma tails
#   2. `path:1` + `` `:2, :3` `` -> 1 full + 1 continuation head + 1 comma tail
#   3. `path:1` + `` `:5` ``     -> 1 full + 1 continuation
# so comma=3, cont=2, and the independent scanner finds the same 3 tails.
if [ "${sf_comma:-0}" -eq 3 ] && [ "${sf_cont:-0}" -eq 2 ] && [ "${sf_found:-0}" -eq 3 ]; then
  check "C3 the extractor and the independent scanner agree on synthetic input (comma=3 cont=2 found=3)" PASS
else
  check "C3 the extractor and the independent scanner agree on synthetic input (got comma=${sf_comma:-none} cont=${sf_cont:-none} found=${sf_found:-none}, expected 3/2/3)" FAIL
fi

# C4 — the basename map is validated against the filesystem, independently of
# whether any document happens to spell a given shorthand. Without this an
# entry whose target is renamed is reported at the DOCUMENT's line as "cites a
# path that does not exist", blaming the document for a map defect, and an
# entry no document uses is never exercised at all.
if [ "${MAPBAD:-1}" -eq 0 ]; then
  check "C4 every BASENAME_PATH target still exists (corpus comma citations: ${CFOUND:-0})" PASS
else
  check "C4 every BASENAME_PATH target still exists ($MAPBAD stale)" FAIL
fi

echo "----"
echo "test-multi-repo-doc-citations: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
