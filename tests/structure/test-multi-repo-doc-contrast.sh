#!/bin/bash
# WCAG contrast pin for the multi-repo design pages.
#
# `docs/multi-repo-chains-overview.html` and
# `docs/multi-repo-chains-principle.html` are the first documentation HTML in
# `docs/`, so whatever palette they ship becomes the de-facto template for the
# next one. Both pages are hand-written, carry no build step, and are never
# rendered in CI — a contrast regression is invisible to every other check in
# this repository.
#
# The pin computes the WCAG 2.x relative-luminance ratio from the hex values the
# pages declare, for THREE palettes per page (the bare `:root` light set, the
# `prefers-color-scheme: dark` set, and the `[data-theme="dark"]` set), and
# requires:
#
#   - 4.5:1 for every foreground/background pair actually used for text;
#   - 3:1 for every stroke token a diagram paint class resolves to, because
#     arrows and box outlines are "parts of graphics required to understand the
#     content" (WCAG 1.4.11).
#
# The stroke half is a DENYLIST, not an allowlist. Every `.class { ... stroke:
# ... }` in the page is collected; `EXCLUDED` names the ones that paint nothing
# the reader would lose, and any remaining class whose stroke is not a gradable
# `var(--token)` is a FATAL rather than a silent skip. An allowlist of class
# names had to be hand-extended whenever a class appeared, so a new
# information-bearing class under any other name was ungraded with no output —
# the opposite of what this header used to claim.
#
# The token parser is self-tested by K3 against a synthetic page, because both
# real pages carry only hex values and the parser's failure modes are therefore
# unobservable against them. K3 pins the FAILURE COUNT, not the log line: an
# unparsed token only protects coverage because it increments `bad`, and a check
# that greps the message alone stays green when that increment is removed.
#
# ACCEPTED LIMITS:
#   - The text pair list IS hardcoded. It is the set of pairs that actually meet
#     in these two pages, established by reading them; a pair introduced later
#     and not added here is unchecked. Deriving it would mean resolving CSS
#     cascade and SVG nesting, which is not worth a shell test.
#   - The page list comes from `tests/structure/fixtures/multi-repo-docs.txt`,
#     the one registry all four multi-repo doc suites read; this suite takes its
#     `.html` entries. K1's floors are still literals and must be raised when a
#     page is added.
#   - Ratios are computed on opaque sRGB. Neither page uses alpha, filters, or
#     `color-scheme`, so there is nothing else to account for.
#   - Only `#rrggbb` is COMPUTED. Every other colour notation — `rgb()`,
#     `oklch()`, `color-mix()`, a bare keyword — is reported as UNPARSED and
#     fails the run rather than being skipped, so a palette that moves to one of
#     them is a loud failure and not a silent loss of coverage. The exclusion is
#     a comma-bearing value with NO parenthesis, which in these pages means a
#     font stack; testing on the comma alone silently dropped every legacy
#     `rgb(a, b, c)` and every `color-mix()`, which has no comma-free spelling.
#   - A class's own `fill` is a background and is graded as a text background,
#     never as a stroke. `.arrowhead`'s fill is the one exception: it paints a
#     mark, so it is graded at 3:1.
#   - The scan keys on the SELECTOR, so a descendant or compound rule
#     (`.diagram path { stroke: … }`) is seen, and at-rule preludes are
#     STRIPPED before the scan rather than skipped — skipping them swallowed
#     whichever rule sat FIRST inside an `@media` block, so the same override
#     was graded or not depending on its position.
#   - `EXCLUDED` is keyed per page — `<page>.<class>` — and matched against the
#     subject of EVERY comma group, where a group's subject is its own last
#     class. One page's decorative class therefore cannot excuse the same name
#     on another page, nor a rule that merely mentions it (`.rule .flow { … }`),
#     nor its co-selectors in a list (`.flow, .rule { … }`). A rule is skipped
#     only when every group is excluded.
#   - Three parser shapes the corpus cannot exercise are pinned by K4 against a
#     synthetic page instead: a stroke nested FIRST inside an at-rule block, a
#     rule following a braceless at-rule, and a block-final declaration with no
#     trailing semicolon. Each was a silent skip, and each is invisible against
#     the two real pages.
#   - Only CSS `stroke:` declarations are read. A literal paint PRESENTATION
#     ATTRIBUTE (`<path stroke="#eee">`) is invisible here; it is forbidden
#     outright by P13 in `test-multi-repo-doc-structure.sh`, which is where the
#     two pages' paint-through-classes rule is enforced.
#   - This says nothing about rendered appearance, font size, or layout.
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
  echo "  FAIL  K0 the document registry could not be read: $DOC_REGISTRY"
  exit 1
fi
OVERVIEW="${PAGES[0]}"
PRINCIPLE="${PAGES[1]}"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  case "$cond" in
    PASS) echo "  PASS  $label"; PASS=$((PASS+1)) ;;
    *)    echo "  FAIL  $label"; FAIL=$((FAIL+1)) ;;
  esac
}

if [ ! -f "$OVERVIEW" ] || [ ! -f "$PRINCIPLE" ]; then
  check "K0 both HTML pages exist" FAIL
  echo "----"
  echo "test-multi-repo-doc-contrast: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "K0 both HTML pages exist" PASS

# One accumulator, one trap, set before anything is created. Creating a temp
# file on the line before the trap that owns it leaves a window in which an
# interruption leaks it, and re-spelling the full list at each new fixture is
# how a file eventually gets left out.
TMPFILES=()
TMPDIRS=()
trap 'rm -f ${TMPFILES[@]+"${TMPFILES[@]}"}; rm -rf ${TMPDIRS[@]+"${TMPDIRS[@]}"}' EXIT
# `mktmp <varname> <template>` assigns in the CALLER's scope. It must NOT be
# used as `$(mktmp …)`: a command substitution runs the function in a subshell,
# so `TMPFILES+=` would mutate a copy and the parent's array would still be
# empty when the EXIT trap expands it — `rm -f` with no operands, and every
# temp file leaks silently. That is exactly what the first version of this
# helper did.
# `mktmpdir <varname> <template>`, same caller-scope contract as `mktmp`.
mktmpdir() {
  local __var="$1" __d
  __d="$(mktemp -d -t "$2.XXXXXX")" || return 1
  TMPDIRS+=("$__d")
  eval "$__var=\$__d"
}
mktmp() {
  local __var="$1" __t
  __t="$(mktemp -t "$2.XXXXXX")" || return 1
  TMPFILES+=("$__t")
  eval "$__var=\$__t"
}

mktmp PROBE zensu-contrast-probe || { check "K0b probe temp file created" FAIL; exit 1; }
cat > "$PROBE" <<'NODE'
const fs = require("fs");

const lum = (hex) => {
  const c = [1, 3, 5].map((i) => parseInt(hex.substr(i, 2), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a, b) => {
  const [hi, lo] = [lum(a), lum(b)].sort((p, q) => q - p);
  return (hi + 0.05) / (lo + 0.05);
};

// A declaration value can legally span lines, and `[^;]+` matches a newline, so
// an embedded newline would otherwise travel verbatim into a log line and let a
// document forge this probe's own `SUMMARY` contract line. Everything that
// reaches stdout is collapsed to single spaces first.
const flat = (v) => String(v).replace(/\s+/g, " ").trim();

// Split the file into its three token declaration blocks and read each one's
// custom properties. Later blocks inherit anything they do not redeclare.
const unparsed = [];
function palettes(src, label) {
  const blocks = [];
  const re = /(:root(?:[^{]*))\{([^}]*)\}/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    const sel = flat(m[1]);
    const body = m[2];
    const tokens = {};
    const tre = /--([a-z0-9-]+)\s*:\s*([^;]+);/g;
    let t;
    while ((t = tre.exec(body)) !== null) {
      const raw = flat(t[2]);
      // A font stack is the only non-colour value these pages declare, and every
      // one of them lists comma-separated fallbacks with no parenthesis. A
      // comma-bearing value that DOES carry a parenthesis is a colour function
      // (`rgb(a, b, c)`, `color-mix(in srgb, a, b)`) and must be reported.
      if (/^#[0-9a-fA-F]{6}$/.test(raw)) tokens[t[1]] = raw.toLowerCase();
      else if (!raw.includes(",") || raw.includes("(")) {
        unparsed.push(label + " --" + t[1] + ": " + raw);
      }
    }
    if (Object.keys(tokens).length) blocks.push({ sel, tokens });
  }
  if (!blocks.length) return null;
  const light = blocks[0].tokens;
  const out = [{ name: "light", tokens: light }];
  for (const b of blocks.slice(1)) {
    out.push({ name: b.sel.includes("data-theme=\"dark\"") ? "data-theme-dark" : "media-dark",
               tokens: { ...light, ...b.tokens } });
  }
  return out;
}

// Values that paint nothing, so a class carrying one loses the reader nothing.
const NON_PAINT = new Set(["none", "transparent", "inherit", "currentcolor"]);
// Named exclusions, keyed PER PAGE. `.rule` is a decorative horizontal
// separator above a caption on the principle page; a future page introducing an
// information-bearing `.rule` must not inherit that judgement silently.
// Anything else that strokes must resolve to a gradable token.
const EXCLUDED = new Set(["docs/multi-repo-chains-principle.html.rule"]);

// Every custom property a diagram paint class resolves to for a stroke, plus
// the arrowhead's fill, which paints a mark rather than a background. Derived as
// a DENYLIST so a class added under a new name is graded, or fails loudly, but
// is never skipped in silence.
function strokeTokens(src, label, fatal) {
  const out = new Set();
  // Match the whole DECLARATION BLOCK and derive the class set from the entire
  // selector. Anchoring the class name directly against `{` could not see a
  // descendant or compound selector — `.diagram path { stroke: ... }` matched
  // nothing, so its stroke was neither graded nor reported. That is the silent
  // skip this denylist exists to remove, so the selector, not the class
  // adjacency, is what the scan keys on.
  // At-rule preludes are STRIPPED, not skipped. `([^}]*)` stops at the first
  // `}`, so an `@media (...) {` match swallowed the first rule nested inside it
  // and the `@` guard then discarded the pair whole — a dark-mode paint
  // override written FIRST in that block was neither graded nor reported, while
  // the same rule written second was graded normally. Removing the opener lets
  // every nested rule match on its own; the now-unbalanced closing brace
  // matches nothing and is inert.
  // Braceless at-rules (`@import url("x.css");`, `@layer a, b;`) are stripped
  // FIRST, and the block prelude may not cross a `;`. Without both, `[^{]*`
  // runs from the `@` through the NEXT RULE's opening brace and deletes that
  // rule's selector with it — its strokes are then neither graded nor reported,
  // which is the silent skip this whole scan exists to remove, reintroduced on
  // a different input.
  const flatSrc = src
    .replace(/@[a-zA-Z-]+[^{;]*;/g, " ")
    .replace(/@[a-zA-Z-]+[^{;]*\{/g, " ");
  const RULE = /([^{}]+)\{([^}]*)\}/g;
  let m;
  while ((m = RULE.exec(flatSrc)) !== null) {
    const sel = flat(m[1]);
    const classes = [...sel.matchAll(/\.([a-zA-Z][\w-]*)/g)].map((c) => c[1]);
    if (!classes.length) continue;                // element/:root rules are not paint classes
    // The exclusion is keyed on each comma group's own SUBJECT — the class on
    // its TRAILING simple selector — never on any class appearing anywhere in
    // the group. Three shapes each defeated a looser rule:
    //   `.rule .flow`  — keying on "some class in the group" excused it
    //   `.flow, .rule` — keying on the whole selector's last class excused the
    //                    list wholesale, silently dropping `.flow`
    //   `.rule path`   — keying on the group's last CLASS excused it even
    //                    though the subject is an element
    // A group whose subject carries no class yields a sentinel that can never
    // be an EXCLUDED key, so it makes the rule NOT excused rather than dropping
    // out of the vote. The rule is skipped only when EVERY group is excluded.
    const NO_SUBJECT = "\u0000";
    const groups = sel.split(",").map((g) => {
      const trailing = g.trim().split(/\s+/).pop() || "";
      const gc = [...trailing.matchAll(/\.([a-zA-Z][\w-]*)/g)].map((c) => c[1]);
      return gc.length ? gc[gc.length - 1] : NO_SUBJECT;
    });
    const allExcluded = groups.length > 0
      && groups.every((g) => EXCLUDED.has(label + "." + g));
    // The terminator is optional: a block-final `stroke: var(--x) }` with no
    // semicolon is legal CSS and a common hand-authoring shape, and requiring
    // the `;` made it match nothing — neither graded nor FATAL.
    for (const d of m[2].matchAll(/\bstroke:\s*([^;}]+)\s*(?:;|$)/g)) {
      const v = flat(d[1]);
      if (NON_PAINT.has(v.toLowerCase())) continue;
      if (allExcluded) continue;
      const tok = v.match(/^var\(--([a-z0-9-]+)\)$/);
      if (!tok) { fatal(label + " selector '" + sel + "' strokes with '" + v
        + "', which is not a var(--token) this probe can grade"); continue; }
      out.add(tok[1]);
    }
  }
  const head = flatSrc.match(/\.arrowhead\s*\{[^}]*fill:\s*var\(--([a-z0-9-]+)\)/);
  if (head) out.add(head[1]);
  return [...out];
}

// Foreground/background pairs that actually meet as TEXT in these pages.
const TEXT_PAIRS = [
  ["ink", "bg"], ["ink", "surface"], ["ink", "surface-2"], ["ink", "accent-soft"],
  ["ink-2", "bg"], ["ink-2", "surface"], ["ink-2", "surface-2"], ["ink-2", "accent-soft"],
  ["ink-3", "bg"], ["ink-3", "surface"], ["ink-3", "surface-2"], ["ink-3", "accent-soft"],
  ["accent", "bg"], ["accent", "surface"], ["accent", "accent-soft"],
  ["warn", "warn-soft"], ["ok", "ok-soft"],
];
const STROKE_BGS = ["surface", "surface-2"];

let bad = 0, text = 0, graph = 0, strokeTokenCount = 0;
for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, "utf8");
  const label = file.replace(/^.*\/docs\//, "docs/");
  const pals = palettes(src, label);
  if (!pals) { console.log("FATAL " + label + ": no token block parsed"); bad++; continue; }
  if (pals.length < 3) { console.log("FATAL " + label + ": expected 3 token blocks, parsed " + pals.length); bad++; }

  const st = strokeTokens(src, label, (msg) => { console.log("FATAL " + msg); bad++; });
  if (!st.length) {
    console.log("FATAL " + label + ": could not resolve any diagram stroke token");
    bad++;
  }
  strokeTokenCount += st.length;

  // A token declared in SOME palettes and missing from another was skipped for
  // that palette in silence: the half-declared check below compares against the
  // UNION, so a two-of-three token looks fully declared. Every token this page
  // actually grades must be present in EVERY palette.
  const used = new Set([...TEXT_PAIRS.flat(), ...st]);
  const declaredAnywhere = new Set(pals.flatMap((p) => Object.keys(p.tokens)));
  for (const tok of used) {
    if (!declaredAnywhere.has(tok)) continue;   // absent from this page entirely
    for (const p of pals) {
      if (!p.tokens[tok]) {
        console.log("DROP  " + label + " [" + p.name + "] --" + tok
          + " is declared elsewhere in this page but not here; its pairs are ungraded");
        bad++;
      }
    }
  }

  for (const [fg, bg] of TEXT_PAIRS) {
    const fgSeen = declaredAnywhere.has(fg), bgSeen = declaredAnywhere.has(bg);
    // A pair is optional only when NEITHER side is declared (the principle page
    // has no warn/ok family). One side present and the other missing is a rename
    // that would otherwise drop the pair from grading in silence.
    if (fgSeen !== bgSeen) {
      console.log("DROP  " + label + " pair --" + fg + " / --" + bg + " is half-declared; a rename would ungrade it");
      bad++;
    }
  }
  for (const p of pals) {
    for (const [fg, bg] of TEXT_PAIRS) {
      if (!p.tokens[fg] || !p.tokens[bg]) continue; // pair not present in this page
      text++;
      const r = ratio(p.tokens[fg], p.tokens[bg]);
      if (r < 4.5) {
        console.log("TEXT  " + label + " [" + p.name + "] --" + fg + " on --" + bg + " = " + r.toFixed(2) + " (needs 4.5)");
        bad++;
      }
    }
    for (const tok of st) {
      if (!tok || !p.tokens[tok]) continue;
      for (const bg of STROKE_BGS) {
        if (!p.tokens[bg]) continue;
        graph++;
        const r = ratio(p.tokens[tok], p.tokens[bg]);
        if (r < 3.0) {
          console.log("GRAPH " + label + " [" + p.name + "] --" + tok + " on --" + bg + " = " + r.toFixed(2) + " (needs 3.0)");
          bad++;
        }
      }
    }
  }
}
for (const u of unparsed) { console.log("UNPARSED token " + u + " — colour notation not understood, so it is graded by nothing"); bad++; }
console.log("SUMMARY text=" + text + " graph=" + graph + " strokeTokens=" + strokeTokenCount + " bad=" + bad);
NODE

# --- K3: a self-test of the token parser and of its FAILURE COUNT.
#
# The real pages carry only hex, so none of the parser's failure modes can be
# observed against them. Two synthetic pages differing in exactly one respect
# are used instead, and the assertion is on `bad`, not on the log line: an
# unparsed token protects coverage only because it increments the failure
# counter, and a check that greps the message alone stays green when that
# increment is deleted while a palette silently moves to `oklch()`.
# The two fixtures differ in ONE respect: the value of `--mid` (and, in the
# dirty one, a second colour-function token). `--mid` appears in no TEXT_PAIRS
# entry and in no paint class, so changing it cannot alter which pairs are
# gradable — the failure-count delta is attributable to the parser alone.
# Varying a token that IS in TEXT_PAIRS moved the count for an unrelated
# reason and made the comparison meaningless.
fixture() {
  local out="$1" midval="$2" extra="$3"
  cat > "$out" <<HTML
<style>
@import url("nothing.css");
:root {
  --sans: ui-sans-serif, -apple-system, "Segoe UI", sans-serif;
  --mid: $midval;
  $extra
  --bg: #f7f7f5;
  --ink: #1a1a1a;
  --surface: #ffffff;
  --surface-2: #f4f4f4;
  --line-strong: #8a867e;
}
@media (prefers-color-scheme: dark) {
  .flow-dark { stroke: var(--line-strong); }
  :root:not([data-theme="light"]) { --ink: #f0f0f0; }
}
:root[data-theme="dark"] { --ink: #f0f0f0; }
.flow { stroke: var(--line-strong); }
HTML
  printf '</style>\n' >> "$out"
}

mktmp F_CLEAN zensu-contrast-clean || { check "K3 fixture temp files created" FAIL; exit 1; }
mktmp F_DIRTY zensu-contrast-dirty || { check "K3 fixture temp files created" FAIL; exit 1; }
fixture "$F_CLEAN" "#cccccc" ""
fixture "$F_DIRTY" "white"   "--mid2: rgb(28, 27, 25);"
CLEAN_OUT="$(node "$PROBE" "$F_CLEAN" 2>&1)"
DIRTY_OUT="$(node "$PROBE" "$F_DIRTY" 2>&1)"
clean_bad="$(printf '%s\n' "$CLEAN_OUT" | sed -n 's/^SUMMARY .*[ ]bad=\([0-9]*\).*/\1/p' | tail -1)"
dirty_bad="$(printf '%s\n' "$DIRTY_OUT" | sed -n 's/^SUMMARY .*[ ]bad=\([0-9]*\).*/\1/p' | tail -1)"
k3=1
# EXACTLY two more failures: the keyword and the colour function. A `-gt`
# comparison would also be satisfied by an unrelated regression in the dirty
# fixture, so the delta is pinned to the number of tokens introduced.
if [ -z "${clean_bad:-}" ] || [ -z "${dirty_bad:-}" ]; then
  echo "  ---   the probe produced no parsable summary for a fixture"; k3=0
elif [ "$dirty_bad" -ne $(( clean_bad + 2 )) ]; then
  echo "  ---   a bare keyword and an rgb() value did not raise the failure count by exactly 2 (clean=$clean_bad dirty=$dirty_bad)"; k3=0
fi
printf '%s\n' "$DIRTY_OUT" | grep -q 'UNPARSED token .* --mid: white' \
  || { echo "  ---   the parser did not report a bare colour keyword (--mid: white)"; k3=0; }
printf '%s\n' "$DIRTY_OUT" | grep -q 'UNPARSED token .* --mid2: rgb(28, 27, 25)' \
  || { echo "  ---   the parser did not report a comma-bearing colour function (--mid2: rgb(...))"; k3=0; }
if printf '%s\n' "$DIRTY_OUT" | grep -q 'UNPARSED token .* --sans'; then
  echo "  ---   the parser reported a font stack (--sans) as an unparsed colour"
  k3=0
fi
if [ "$k3" -eq 1 ]; then
  check "K3 a keyword and a colour function each raise the failure count, a font stack does not" PASS
else
  check "K3 a keyword and a colour function each raise the failure count, a font stack does not" FAIL
fi

# --- K4: three parser shapes the CORPUS cannot exercise.
#
# Every one of these was a silent skip that left the suite green, and none is
# observable against the two real pages: both carry exactly one at-rule, whose
# only nested rule is a `:root` token block that the scan skips anyway, and
# every declaration in both ends with a semicolon. So the fix and the defect
# produce identical output on the corpus, and a revert would go unnoticed.
# The fixture puts a LITERAL stroke — one the probe must refuse to grade — in
# each of the three positions and requires a FATAL naming that selector.
#
#   1. first rule inside an at-rule block  (the body group stops at the first
#      `}`, so the at-rule match used to swallow this rule whole)
#   2. immediately after a braceless at-rule  (an unbounded prelude used to run
#      from the `@` through THIS rule's opening brace and delete its selector)
#   3. block-final, no trailing semicolon  (the declaration pattern used to
#      require the `;`)
mktmp F_SHAPES zensu-contrast-shapes || { check "K4 fixture temp file created" FAIL; exit 1; }
cat > "$F_SHAPES" <<'HTML'
<style>
:root { --bg: #f7f7f5; --ink: #1a1a1a; --surface: #ffffff; --surface-2: #f4f4f4; --line-strong: #8a867e; }
:root:not([data-theme="light"]) { --ink: #f0f0f0; }
:root[data-theme="dark"] { --ink: #f0f0f0; }
@media (prefers-color-scheme: dark) {
  .nested-first { stroke: #c1c1c1; }
  .other { stroke: var(--line-strong); }
}
@import url("nothing.css");
.after-braceless { stroke: #c2c2c2; }
.no-semicolon { stroke: #c3c3c3 }
</style>
HTML
SHAPES_OUT="$(node "$PROBE" "$F_SHAPES" 2>&1)"
k4=1
for want in nested-first after-braceless no-semicolon; do
  printf '%s\n' "$SHAPES_OUT" | grep -q "FATAL .*\.$want"     || { echo "  ---   a literal stroke on .$want was neither graded nor reported"; k4=0; }
done
if [ "$k4" -eq 1 ]; then
  check "K4 a stroke nested first in an at-rule, after a braceless at-rule, or without a semicolon is still seen" PASS
else
  check "K4 a stroke nested first in an at-rule, after a braceless at-rule, or without a semicolon is still seen" FAIL
fi

# --- K5: the exclusion's three defeated selector shapes.
#
# `EXCLUDED` is keyed `<page>.<class>`, and the page label is derived by
# stripping everything up to the last `/docs/`. A fixture written to a bare
# temp file therefore never matches an EXCLUDED key, so the exclusion is inert
# there and every shape would FATAL regardless of the rule — a check that
# proves nothing. The fixture is written into `<tmpdir>/docs/` under the real
# page's name instead, which makes its label exactly the EXCLUDED key and the
# shapes discriminating.
#
# `.rule` itself must be EXCUSED (the positive control, without which "nothing
# FATALs" would satisfy the check); the other three must FATAL.
mktmpdir K5_DIR zensu-contrast-excl || { check "K5 fixture temp dir created" FAIL; exit 1; }
mkdir -p "$K5_DIR/docs"
K5_PAGE="$K5_DIR/docs/multi-repo-chains-principle.html"
cat > "$K5_PAGE" <<'HTML'
<style>
:root { --bg: #f7f7f5; --ink: #1a1a1a; --surface: #ffffff; --surface-2: #f4f4f4; --line-strong: #8a867e; }
:root:not([data-theme="light"]) { --ink: #f0f0f0; }
:root[data-theme="dark"] { --ink: #f0f0f0; }
.rule { stroke: #c9c9c9; }
.rule, .list-sibling { stroke: #c4c4c4; }
.rule .descendant-class { stroke: #c5c5c5; }
.rule elem-subject { stroke: #c6c6c6; }
.keeps-tokens { stroke: var(--line-strong); }
</style>
HTML
K5_OUT="$(node "$PROBE" "$K5_PAGE" 2>&1)"
k5=1
printf '%s\n' "$K5_OUT" | grep -q "FATAL .*'\.rule'" \
  && { echo "  ---   the .rule exemption stopped applying to its own rule"; k5=0; }
for want in "\.rule, \.list-sibling" "\.rule \.descendant-class" "\.rule elem-subject"; do
  printf '%s\n' "$K5_OUT" | grep -q "FATAL .*$want" \
    || { echo "  ---   a literal stroke on selector '$want' was excused by the .rule exemption"; k5=0; }
done
if [ "$k5" -eq 1 ]; then
  check "K5 the exclusion covers its own class only, not a list sibling, a descendant or an element subject" PASS
else
  check "K5 the exclusion covers its own class only, not a list sibling, a descendant or an element subject" FAIL
fi

REPORT="$(node "$PROBE" "$OVERVIEW" "$PRINCIPLE")"

printf '%s\n' "$REPORT" | grep -vE '^SUMMARY' | sed 's/^/  ---   /' | grep -v '^  ---   $' || true
# `tail -1` on every scalar: a document that forged an extra SUMMARY line would
# otherwise widen these into multi-line values, and `[ "$x" -lt 100 ]` on a
# multi-line value errors out rather than failing the check.
field() { printf '%s\n' "$REPORT" | sed -n "s/^SUMMARY .*[ ]$1=\([0-9]*\).*/\1/p" | tail -1; }
TEXTN="$(printf '%s\n' "$REPORT" | sed -n 's/^SUMMARY text=\([0-9]*\).*/\1/p' | tail -1)"
GRAPHN="$(field graph)"
STOKENS="$(field strokeTokens)"
BAD="$(field bad)"
CHECKED=$(( ${TEXTN:-0} + ${GRAPHN:-0} ))

# K1 — floors per CATEGORY, not on the total. A single combined floor left room
# for the whole accent-stroke grading to disappear (24 checks) while the total
# stayed above it. `strokeTokens` is floored too, so a page that resolves only
# one stroke token fails rather than quietly grading half as much.
k1=1
[ -n "${TEXTN:-}" ] && [ -n "${GRAPHN:-}" ] && [ -n "${STOKENS:-}" ] \
  || { echo "  ---   the contrast probe produced no parsable summary"; k1=0; }
[ "${TEXTN:-0}" -ge 96 ]  || { echo "  ---   only ${TEXTN:-0} text pairs graded (expected >= 96)"; k1=0; }
[ "${GRAPHN:-0}" -ge 24 ] || { echo "  ---   only ${GRAPHN:-0} stroke pairs graded (expected >= 24)"; k1=0; }
[ "${STOKENS:-0}" -ge 4 ] || { echo "  ---   only ${STOKENS:-0} stroke tokens resolved across both pages (expected >= 4)"; k1=0; }
if [ "$k1" -eq 1 ]; then
  check "K1 $TEXTN text pairs and $GRAPHN stroke pairs graded from $STOKENS stroke tokens" PASS
else
  check "K1 the contrast probe graded a plausible number of pairs in each category" FAIL
fi

if [ "${BAD:-1}" -eq 0 ]; then
  check "K2 every text pair reaches 4.5:1 and every diagram stroke reaches 3:1" PASS
else
  check "K2 every text pair reaches 4.5:1 and every diagram stroke reaches 3:1 ($BAD failing)" FAIL
fi

echo "----"
echo "test-multi-repo-doc-contrast: $PASS PASS / $FAIL FAIL (${CHECKED:-0} pairs checked)"
[ "$FAIL" -eq 0 ]
