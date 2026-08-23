#!/bin/bash
# Structure and accessibility pin for the multi-repo design pages.
#
# These two pages are the first documentation HTML in `docs/`, are hand-written
# with no build step, and are never rendered in CI. Everything this file pins is
# a property a rendered check would catch and nothing else here can: a landmark
# that lets an assistive-technology user skip to content, a page title that
# identifies the document, keyboard reach into the scroll containers that hold
# the diagrams, a focus indicator that is actually visible, diagram names and
# long descriptions whose ARIA references RESOLVE, a diagram scale at which the
# smallest label is still legible, the absence of `var()` in any SVG
# presentation attribute — matched by attribute SHAPE rather than against a
# list of names, and self-tested by P11 against a synthetic page because both
# real pages are clean — the comment that explains why that absence matters,
# and a programmatically usable table.
#
# The `role="img"` half is the one worth explaining. `role="img"` makes an SVG a
# leaf node: its `<text>` children are presentational, so in browsers that
# implement that rule none of the diagram's own words reach assistive tech. An
# `aria-label` is then the ONLY thing a screen-reader user receives — and a
# one-sentence label is a gist, not an equivalent, for a diagram carrying a
# dozen labelled boxes. So the pin requires a real `<title>` referenced by
# `aria-labelledby` (one name source, not two competing ones) plus an
# `aria-describedby` target holding the content in restylable HTML.
#
# ARIA references are checked by RESOLUTION, not by counting. Counting the two
# ends separately passes a typo: `aria-labelledby="d1-titel"` against
# `<title id="d1-title">` leaves the diagram with no accessible name while every
# count still matches. That is the exact failure this pin exists to prevent, so
# every IDREF is resolved against the set of `id=` values the page declares.
#
# ACCEPTED LIMITS:
#   - This is a source check. It cannot confirm that a long description actually
#     DESCRIBES its diagram, only that one exists and resolves.
#   - Contrast lives in `test-multi-repo-doc-contrast.sh`; citations live in
#     `test-multi-repo-doc-citations.sh`. This file deliberately checks neither.
#   - Legibility is pinned as a scale floor, not as a rendered measurement.
#   - Elements are discovered by TAG NAME and then filtered on the parsed class
#     list, so neither attribute order nor an extra class hides one. A tag may
#     wrap across lines; the open tag is matched with `[^>]*`, which spans
#     newlines.
#   - P8 is scoped to `<svg>...</svg>` regions, so a page may document the
#     anti-pattern by example in prose or in a `<code>` sample without failing.
#     P11 pins both directions against synthetic pages.
#   - P13 forbids `stroke`/`fill`/`stop-color` as presentation attributes
#     inside an `<svg>` outright, literal values included. P8 rejects only a
#     `var()` value and the contrast suite reads CSS declarations, so a literal
#     `stroke="#eee"` was graded by nothing and reported by nothing. Both pages
#     paint through classes by their own stated rule, so the ban costs nothing.
#   - The page list comes from `tests/structure/fixtures/multi-repo-docs.txt`,
#     the one registry all four multi-repo doc suites read; this suite takes its
#     `.html` entries. P12's expected element counts are still per-page literals
#     and must be extended when a page is added or gains a diagram.
#   - P3 and P5 fail only on an EMPTY set, so P12 carries the census: an
#     element that stops being discovered shrinks the set rather than failing
#     the check that walks it.
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
PAGES=()
while IFS= read -r rel; do
  case "$rel" in *.html) PAGES+=("$PLUGIN_DIR/$rel") ;; esac
done < <(read_registry)
if [ "${#PAGES[@]}" -lt 2 ]; then
  echo "  FAIL  P0 the document registry could not be read: $DOC_REGISTRY"
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

for p in "${PAGES[@]}"; do
  if [ ! -f "$p" ]; then
    check "P0 both pages exist" FAIL
    echo "----"
    echo "test-multi-repo-doc-structure: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 both pages exist" PASS

# One accumulator, one trap, set before anything is created. A temp file
# created on the line before the trap that owns it leaks on an interruption,
# and re-spelling the full list at each new fixture is how one gets left out.
TMPFILES=()
trap 'rm -f ${TMPFILES[@]+"${TMPFILES[@]}"}' EXIT
# `mktmp <varname> <template>` assigns in the CALLER's scope. It must NOT be
# used as `$(mktmp …)`: a command substitution runs the function in a subshell,
# so `TMPFILES+=` would mutate a copy and the parent's array would still be
# empty when the EXIT trap expands it — `rm -f` with no operands, and every
# temp file leaks silently. That is exactly what the first version of this
# helper did.
mktmp() {
  local __var="$1" __t
  __t="$(mktemp -t "$2.XXXXXX")" || return 1
  TMPFILES+=("$__t")
  eval "$__var=\$__t"
}
mktmp PROBE zensu-structure-probe || { check "P0b probe temp file created" FAIL; exit 1; }
cat > "$PROBE" <<'NODE'
const fs = require("fs");
const file = process.argv[2];
const src = fs.readFileSync(file, "utf8");
const out = [];
const fail = (code, detail) => out.push("FAIL " + code + " " + detail);

const ids = new Set([...src.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
const attrs = (tag) => {
  const o = {};
  for (const m of tag.matchAll(/([a-zA-Z-]+)="([^"]*)"/g)) o[m[1]] = m[2];
  return o;
};
const tags = (re) => [...src.matchAll(re)].map((m) => m[0]);
// Discover by TAG NAME and then filter on the parsed class list. Matching
// `<svg class="diagram"` required the class attribute to come FIRST and to be
// the whole value, so `<svg role="img" class="diagram">` or
// `class="diagram wide"` was not seen at all — and the only guard below is an
// emptiness check, so three of four elements could vanish with the check still
// passing. `attrs()` is already order-independent; discovery was not.
const byClass = (tagName, cls) =>
  tags(new RegExp("<" + tagName + "\\b[^>]*>", "g"))
    .filter((t) => String(attrs(t).class || "").trim().split(/\s+/).includes(cls));

// --- diagrams: named by <title>, described, never by aria-label, IDREFs resolve
const diagrams = byClass("svg", "diagram");
if (!diagrams.length) fail("P5", "no <svg class=\"diagram\"> found");
for (const tag of diagrams) {
  const a = attrs(tag);
  if (a["aria-label"] !== undefined) fail("P5", "a diagram is named by aria-label instead of <title>");
  for (const rel of ["aria-labelledby", "aria-describedby"]) {
    const v = a[rel];
    if (v === undefined) { fail("P5", "a diagram has no " + rel); continue; }
    for (const ref of v.trim().split(/\s+/)) {
      if (!ids.has(ref)) fail("P5", rel + '="' + ref + '" resolves to no id on the page');
    }
  }
  const t = a["aria-labelledby"];
  if (t && !new RegExp("<title id=\"" + t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\"").test(src)) {
    fail("P5", 'aria-labelledby="' + t + '" does not name a <title> element');
  }
}
// every describedby target must be a disclosure carrying the long description
for (const tag of diagrams) {
  const v = attrs(tag)["aria-describedby"];
  if (!v) continue;
  if (!new RegExp("<details id=\"" + v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\"").test(src)
      && !new RegExp("<div id=\"" + v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\"").test(src)) {
    fail("P6", 'aria-describedby="' + v + '" names no <details> or <div> long description');
  }
}

// --- scroll wrappers: keyboard reachable, grouped, named, order-independent
const wrappers = [...byClass("div", "scroll"), ...byClass("div", "tablewrap")];
if (!wrappers.length) fail("P3", "no scroll wrapper found");
for (const tag of wrappers) {
  const a = attrs(tag);
  if (a.tabindex !== "0") fail("P3", "a scroll wrapper is not keyboard reachable (tabindex)");
  if (a.role !== "group") fail("P3", 'a scroll wrapper has no role="group"');
  const v = a["aria-labelledby"];
  if (!v) { fail("P3", "a scroll wrapper has no accessible name"); continue; }
  for (const ref of v.trim().split(/\s+/)) {
    if (!ids.has(ref)) fail("P3", 'a scroll wrapper aria-labelledby="' + ref + '" resolves to no id');
  }
}

// --- focus indicator: present AND not suppressed
const focusRules = [...src.matchAll(/[^{}]*:focus(?:-visible)?[^{}]*\{([^}]*)\}/g)];
if (!focusRules.length) fail("P4", "no :focus-visible rule");
let visible = false;
for (const r of focusRules) {
  const body = r[1];
  if (/outline\s*:\s*(none|0)\b/.test(body)) fail("P4", "a focus rule suppresses the outline");
  if (/outline\s*:\s*(?!none|0\b)[^;]+/.test(body) || /box-shadow\s*:/.test(body)) visible = true;
}
if (!visible) fail("P4", "no focus rule declares a visible outline or box-shadow");

// --- scale: the svg.diagram rule's own min-width, against the widest diagram
const rule = src.match(/svg\.diagram\s*\{([^}]*)\}/);
if (!rule) fail("P7", "no svg.diagram rule");
else {
  const mw = [...rule[1].matchAll(/min-width:\s*([0-9]+)px/g)].map((m) => parseInt(m[1], 10));
  if (!mw.length) fail("P7", "svg.diagram declares no min-width in px");
  else {
    const floor = Math.min(...mw);
    const widths = diagrams
      .map((t) => attrs(t).viewBox)
      .filter(Boolean)
      .map((v) => parseInt(v.trim().split(/\s+/)[2], 10))
      .filter((n) => Number.isFinite(n));
    const widest = widths.length ? Math.max(...widths) : 0;
    if (!widths.length) fail("P7", "no diagram viewBox width could be read");
    else if (floor < widest) fail("P7", "min-width " + floor + "px is below the widest viewBox " + widest);
  }
}

// --- regression: no var() in an SVG presentation attribute
// ANY attribute, not a named four. A custom property never resolves in a
// presentation attribute, so the shape renders unpainted whichever attribute
// carries it — `stop-color`, `fill-opacity` and `color` fail exactly as `fill`
// does. Matching the attribute NAME generically means an attribute nobody
// thought of is covered without editing this line.
// Scoped to <svg> regions: a file-wide scan would fire on a page that
// DOCUMENTS the anti-pattern by example (`<code>fill="var(--accent)"</code>`),
// which P9 all but invites by requiring the rationale prose. P11 pins both
// directions — inside an <svg> it must fire, outside it must not.
const svgRegions = [...src.matchAll(/<svg\b[\s\S]*?<\/svg>/g)].map((m) => m[0]);
for (const region of svgRegions) {
  const varAttr = region.match(/([a-z][a-z-]*)="var\(/);
  if (varAttr) {
    fail("P8", "a var() survives in the SVG presentation attribute '" + varAttr[1] + "'");
    break;
  }
}
// --- no PAINT presentation attribute at all, literal or otherwise.
// P8 rejects only a `var()` value, and the contrast suite reads CSS `stroke:`
// declarations, so `<path stroke="#eee">` was graded by nothing and reported by
// nothing — it passes P8 and is invisible to the WCAG floors. Both pages paint
// exclusively through classes and declare that rule in their own comments, so
// forbidding the attribute outright costs nothing and closes the gap here
// rather than teaching the contrast probe to parse SVG.
for (const region of svgRegions) {
  const paint = region.match(/\b(stroke|fill|stop-color)="[^"]*"/);
  if (paint) {
    fail("P13", "a paint presentation attribute survives in an <svg>: " + paint[0]
      + " — paint through a CSS class instead");
    break;
  }
}
if (!/custom properties do not resolve inside presentation/.test(src)) {
  fail("P9", "the paint-through-classes rationale is not documented");
}

// --- landmark and identifying title
if (!/<main[ >]/.test(src)) fail("P1", "no <main> landmark");
const title = src.match(/<title>([^<]*)<\/title>/);
if (!title || !/multi-repo/i.test(title[1])) fail("P2", "the page title does not identify the document");

// The element census travels alongside the verdict. P3/P5 only fail on an
// EMPTY set, so three of four wrappers could vanish with both still passing;
// the count is what makes a disappearance visible.
console.log("COUNT diagrams=" + diagrams.length + " wrappers=" + wrappers.length);
console.log(out.length ? out.join("\n") : "OK");
NODE

# P11 — a self-test of the P8 regression check, in BOTH directions.
#
# P8's job is the header's claim: no `var()` survives in an SVG presentation
# attribute, because a custom property never resolves there and the shape
# renders unpainted. It listed four attribute names, so a page that moved its
# paint to `stop-color`, `fill-opacity` or `color` passed while carrying the
# defect. It is matched by attribute SHAPE now — and scoped to `<svg>` regions,
# because a file-wide scan fires on a page that documents the anti-pattern by
# example, which P9's rationale requirement makes a natural thing to write.
#
# Both real pages are clean and carry no `var()` anywhere, so NEITHER property
# is observable against them: a file-wide and an SVG-scoped implementation are
# indistinguishable there. Two synthetic pages pin the two directions.
mktmp P8_IN zensu-structure-fixture-in   || { check "P11 fixture temp files created" FAIL; exit 1; }
mktmp P8_OUT zensu-structure-fixture-out || { check "P11 fixture temp files created" FAIL; exit 1; }
cat > "$P8_IN" <<'HTML'
<svg class="diagram" role="img"><stop stop-color="var(--accent)"/></svg>
HTML
cat > "$P8_OUT" <<'HTML'
<p>Never write <code>fill="var(--accent)"</code> in a presentation attribute.</p>
<svg class="diagram" role="img"><path class="flow" d="M0,0 L1,1"/></svg>
HTML
p11=1
node "$PROBE" "$P8_IN" | grep -q '^FAIL P8' \
  || { echo "  ---   P8 did not fire on stop-color=\"var(--accent)\" inside an <svg>"; p11=0; }
if node "$PROBE" "$P8_OUT" | grep -q '^FAIL P8'; then
  echo "  ---   P8 fired on a <code> sample outside any <svg>, so a page cannot document the rule"
  p11=0
fi
if [ "$p11" -eq 1 ]; then
  check "P11 a var() in any SVG presentation attribute is caught, and only inside an <svg>" PASS
else
  check "P11 a var() in any SVG presentation attribute is caught, and only inside an <svg>" FAIL
fi

# P14 — a self-test of P13, for the same reason P11 exists for P8. Neither real
# page carries a paint presentation attribute at all, so P13 never fires against
# the corpus: deleting its loop leaves the suite at full green. Two synthetic
# pages pin both directions — a LITERAL value inside an <svg> must fire (P8 only
# rejects a `var()` value, and the contrast suite reads CSS declarations, so
# nothing else would see it), and the same text in a <code> sample outside any
# <svg> must not.
mktmp P13_IN  zensu-structure-paint-in  || { check "P14 fixture temp files created" FAIL; exit 1; }
mktmp P13_OUT zensu-structure-paint-out || { check "P14 fixture temp files created" FAIL; exit 1; }
cat > "$P13_IN" <<'HTML'
<svg class="diagram" role="img"><path stroke="#eeeeee" d="M0,0 L1,1"/></svg>
HTML
cat > "$P13_OUT" <<'HTML'
<p>Never write <code>stroke="#eeeeee"</code> as a presentation attribute.</p>
<svg class="diagram" role="img"><path class="flow" d="M0,0 L1,1"/></svg>
HTML
p14=1
node "$PROBE" "$P13_IN" | grep -q '^FAIL P13' \
  || { echo "  ---   P13 did not fire on a literal stroke=\"#eeeeee\" inside an <svg>"; p14=0; }
if node "$PROBE" "$P13_OUT" | grep -q '^FAIL P13'; then
  echo "  ---   P13 fired on a <code> sample outside any <svg>, so a page cannot document the rule"
  p14=0
fi
if [ "$p14" -eq 1 ]; then
  check "P14 a literal paint presentation attribute is caught, and only inside an <svg>" PASS
else
  check "P14 a literal paint presentation attribute is caught, and only inside an <svg>" FAIL
fi

p12=1
for p in "${PAGES[@]}"; do
  short="${p##*/}"
  RAW="$(node "$PROBE" "$p")"
  # `head -1`, not `tail -1`. The probe prints COUNT FIRST and the failure
  # lines after it, so the authoritative census is the first match — the
  # opposite of the contrast suite, where SUMMARY is printed last. Two fail()
  # sites embed a raw attribute value, and `attrs()` captures with `([^"]*)`,
  # which matches a newline; taking the last match would let such a value win
  # the census.
  COUNTS="$(printf '%s\n' "$RAW" | sed -n 's/^COUNT //p' | head -1)"
  RESULT="$(printf '%s\n' "$RAW" | grep -v '^COUNT ')"
  if [ "$RESULT" = "OK" ]; then
    check "P1-P9 $short landmark, title, keyboard reach, focus, resolved ARIA, scale, paint" PASS
  else
    printf '%s\n' "$RESULT" | sed 's/^FAIL /  ---   /'
    check "P1-P9 $short landmark, title, keyboard reach, focus, resolved ARIA, scale, paint" FAIL
  fi
  nd="$(printf '%s\n' "$COUNTS" | sed -n 's/.*diagrams=\([0-9]*\).*/\1/p')"
  nw="$(printf '%s\n' "$COUNTS" | sed -n 's/.*wrappers=\([0-9]*\).*/\1/p')"
  # An unrecognized page is a FAILURE, not a weaker floor. Defaulting to 1/1
  # meant that renaming a page — with the registry updated in step, so nothing
  # else complains — silently dropped its census from 3/4 to 1/1, which is
  # exactly the disappearance P12 exists to make visible.
  case "$short" in
    multi-repo-chains-overview.html)  want_d=3; want_w=4 ;;
    multi-repo-chains-principle.html) want_d=1; want_w=1 ;;
    *)
      echo "  ---   $short has no expected element census; add one here when a page is added or renamed"
      p12=0; continue ;;
  esac
  [ "${nd:-0}" -ge "$want_d" ] || { echo "  ---   $short declares only ${nd:-0} diagrams (expected >= $want_d)"; p12=0; }
  [ "${nw:-0}" -ge "$want_w" ] || { echo "  ---   $short declares only ${nw:-0} scroll/tablewrap wrappers (expected >= $want_w)"; p12=0; }
done

# P12 — a per-page element census. P3 and P5 fail only on an EMPTY set, so an
# element that stops being discovered — a reordered attribute, an added class,
# a deleted figure — shrinks the set silently while both checks stay green.
if [ "$p12" -eq 1 ]; then
  check "P12 each page still declares its full complement of diagrams and scroll wrappers" PASS
else
  check "P12 each page still declares its full complement of diagrams and scroll wrappers" FAIL
fi

# P10 — the table that carries the consumer roster is programmatically usable.
OV="${PAGES[0]}"
if grep -q '<caption' "$OV" && grep -q 'scope="col"' "$OV" && grep -q '<th scope="row"' "$OV"; then
  check "P10 overview table has a caption, column scopes and row headers" PASS
else
  check "P10 overview table has a caption, column scopes and row headers" FAIL
fi

echo "----"
echo "test-multi-repo-doc-structure: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
