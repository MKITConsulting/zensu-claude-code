#!/bin/bash
set -u

# Structure + functional test for hooks/lib/valid-diff-lines.js (inline-comment
# anchor validation). Doc pins (P3/P4) run BEFORE the node gate so they hold on
# node-less machines. Functional: synthetic unified diffs through the CLI mode
# pin the valid / remap / none verdicts on BOTH sides, new-file numbering
# across multi-hunk and multi-file input, omitted-count hunk headers with
# function-context trailers, nearest-line tie-breaking (following line wins),
# the 40-line remap distance cap incl. its exact boundary, rename resolution to
# the NEW path, quoted non-ASCII paths, mid-hunk no-newline markers, hunk-body
# lines starting with "--"/"++", CRLF input, spaces in paths, deleted/binary
# handling, the always-exit-0 contract, and fail-soft usage errors. The stdin
# 50MB-overflow branch is exercised with a /dev/zero pipe (P1ac). Structure:
# the lib's module exports and the pr-team-review publish integration
# (mandatory pre-publish validation in the rules AND the SKILL.md Phase D path,
# remap note, body-fold fallback, start_line collapse policy, demoted 422
# guidance, README row clause).

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$PLUGIN_DIR/hooks/lib/valid-diff-lines.js"
PUBLISH_MD="$PLUGIN_DIR/skills/pr-team-review/rules/github-publish.md"
WORKFLOW_MD="$PLUGIN_DIR/skills/pr-team-review/rules/workflow.md"
SKILL_MD="$PLUGIN_DIR/skills/pr-team-review/SKILL.md"
README="$PLUGIN_DIR/README.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$LIB" "$PUBLISH_MD" "$WORKFLOW_MD" "$SKILL_MD" "$README"; do
  if [ ! -f "$f" ]; then
    check "P0 required file exists: $f" FAIL
    echo "----"
    echo "test-valid-diff-lines: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "P0 all target files exist" PASS

# P3 — publish-phase integration pins (no node needed; run before the gate)
if grep -qF 'valid-diff-lines.js' "$PUBLISH_MD" && grep -qiE 'pre-publish anchor validation' "$PUBLISH_MD"; then
  check "P3a github-publish.md carries the mandatory validation section" PASS
else
  check "P3a github-publish.md carries the mandatory validation section" FAIL
fi
if grep -qF 'remap' "$PUBLISH_MD" && grep -qiF 'anchor remapped from line' "$PUBLISH_MD"; then
  check "P3b remap note wording pinned" PASS
else
  check "P3b remap note wording pinned" FAIL
fi
if grep -qiE 'fold.*(overall|review) body|into the (overall|review) body' "$PUBLISH_MD"; then
  check "P3c none-case folds the finding into the review body" PASS
else
  check "P3c none-case folds the finding into the review body" FAIL
fi
if grep -qiE 'should not occur|pre-validated' "$PUBLISH_MD"; then
  check "P3d 422 guidance demoted to last-resort" PASS
else
  check "P3d 422 guidance demoted to last-resort" FAIL
fi
WF_SECTION="$(awk '/Anchor validation \(mandatory/,/eliminates the 422/' "$WORKFLOW_MD")"
if grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT:' "$PUBLISH_MD" && printf '%s' "$WF_SECTION" | grep -qF 'valid-diff-lines.js' && \
   printf '%s' "$WF_SECTION" | grep -qF '${ZENSU_CLAUDE_PLUGIN_ROOT:' && \
   ! grep -qF '${CLAUDE_PLUGIN_ROOT' "$PUBLISH_MD" && ! printf '%s' "$WF_SECTION" | grep -qF '${CLAUDE_PLUGIN_ROOT'; then
  check "P3e both validation commands expand the exact session export" PASS
else
  check "P3e validation commands bypass or omit the exact session export" FAIL
fi
if grep -qF "'<path>'" "$PUBLISH_MD" && grep -qF 'single quotes exactly as shown' "$PUBLISH_MD" && grep -qF 'escape it as' "$PUBLISH_MD"; then
  check "P3f untrusted path is single-quoted with an escape instruction" PASS
else
  check "P3f untrusted path is single-quoted with an escape instruction" FAIL
fi
if grep -qF 'start_line' "$PUBLISH_MD" && grep -qiE 'collapse to a single-line comment' "$PUBLISH_MD" && grep -qiE 'EVERY integer in .?\[start_line, line\]' "$PUBLISH_MD"; then
  check "P3g range anchors require hunk contiguity else collapse" PASS
else
  check "P3g range anchors require hunk contiguity else collapse" FAIL
fi
if grep -qiE '\[RIGHT\|LEFT\]|LEFT.*against.*old-file|LEFT.*old-file lines' "$PUBLISH_MD"; then
  check "P3h validation is side-aware (LEFT validates old-file numbering)" PASS
else
  check "P3h validation is side-aware (LEFT validates old-file numbering)" FAIL
fi
if grep -qiF 'prints nothing or exits non-zero' "$PUBLISH_MD" && grep -qiF '(or no output)' "$WORKFLOW_MD"; then
  check "P3i empty validator output is defined as none" PASS
else
  check "P3i empty validator output is defined as none" FAIL
fi
if grep -qF 'Pre-Publish Anchor Validation' "$SKILL_MD" && grep -qF 'valid-diff-lines.js' "$SKILL_MD"; then
  check "P3j SKILL.md Phase D path anchors the mandatory gate" PASS
else
  check "P3j SKILL.md Phase D path anchors the mandatory gate" FAIL
fi
if grep -qiF 'body-only (fold ALL inline findings)' "$PUBLISH_MD" && grep -qiF 'never loop on further fetches' "$PUBLISH_MD"; then
  check "P3k empty-diff handling has a terminal state" PASS
else
  check "P3k empty-diff handling has a terminal state" FAIL
fi
FALLBACK_SECTION="$(awk '/## Fallback: Per-Comment Posting/,/## Verification After Post/' "$PUBLISH_MD")"
if grep -qF 'jq -n --arg' "$PUBLISH_MD" && ! printf '%s' "$FALLBACK_SECTION" | grep -qE -- '(-f|-F) ?(path|body)='; then
  check "P3l fallback posting builds JSON via jq (no raw interpolation)" PASS
else
  check "P3l fallback posting builds JSON via jq (no raw interpolation)" FAIL
fi

# P4 — README row clause (scoped to the pr-team-review row)
if grep -F '/zensu:pr-team-review' "$README" | grep -qF 'valid-diff-lines.js'; then
  check "P4 README pr-team-review row mentions anchor pre-validation" PASS
else
  check "P4 README pr-team-review row mentions anchor pre-validation" FAIL
fi

if ! command -v node >/dev/null 2>&1; then
  echo "  SKIP  node not on PATH — functional CLI/export checks skipped (doc pins above ran)"
  echo "----"
  echo "test-valid-diff-lines: $PASS PASS / $FAIL FAIL (node missing, functional checks skipped)"
  if [ "$FAIL" -gt 0 ]; then exit 1; fi
  exit 0
fi

DIFF_MAIN='diff --git a/src/x.js b/src/x.js
index 1111111..2222222 100644
--- a/src/x.js
+++ b/src/x.js
@@ -1,3 +1,4 @@
 line1
+added2
 line3
 line4
@@ -10,2 +11,3 @@
 ctx11
+added12
 ctx13
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-old1
-old2
diff --git a/fresh.txt b/fresh.txt
new file mode 100644
--- /dev/null
+++ b/fresh.txt
@@ -0,0 +1,2 @@
+n1
+n2
\ No newline at end of file
diff --git a/img.png b/img.png
index 3333333..4444444 100644
Binary files a/img.png and b/img.png differ
diff --git a/after.png.txt b/after.png.txt
--- a/after.png.txt
+++ b/after.png.txt
@@ -1 +1 @@ function afterBinary()
-was1
+solo1'

DIFF_RENAME='diff --git a/before.js b/after.js
similarity index 90%
rename from before.js
rename to after.js
--- a/before.js
+++ b/after.js
@@ -5,2 +5,3 @@
 keep5
+new6
 keep7'

DIFF_TIE='diff --git a/t.js b/t.js
--- a/t.js
+++ b/t.js
@@ -3,0 +4,1 @@
+only4
@@ -8,0 +10,1 @@
+only10'

DIFF_FAR='diff --git a/far.js b/far.js
--- a/far.js
+++ b/far.js
@@ -1,1 +1,1 @@
-was1
+top1'

DIFF_TRICKY='diff --git a/sql/q.sql b/sql/q.sql
--- a/sql/q.sql
+++ b/sql/q.sql
@@ -1,3 +1,3 @@
 keep
--- removed sql comment
+++ added plus line
 tail
diff --git a/noeol.txt b/noeol.txt
--- a/noeol.txt
+++ b/noeol.txt
@@ -1,2 +1,2 @@
 ctx
-old2
\ No newline at end of file
+new2
\ No newline at end of file
diff --git a/dir with space/f.txt b/dir with space/f.txt
--- a/dir with space/f.txt
+++ b/dir with space/f.txt
@@ -1 +1 @@
-was1
+spaced1
diff --git "a/quoted-\303\244.txt" "b/quoted-\303\244.txt"
--- "a/quoted-\303\244.txt"
+++ "b/quoted-\303\244.txt"
@@ -1 +1 @@
-was1
+umlaut1'

run_cli() {
  printf '%s' "$1" | node "$LIB" "$2" "$3" ${4+"$4"} 2>/dev/null
}

# P1 — functional verdicts (RIGHT side default)
V="$(run_cli "$DIFF_MAIN" src/x.js 2)"
[ "$V" = "valid" ] && check "P1a added line is a valid RIGHT anchor" PASS || check "P1a added line is a valid RIGHT anchor (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 3)"
[ "$V" = "valid" ] && check "P1b context line is a valid RIGHT anchor" PASS || check "P1b context line is a valid RIGHT anchor (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 12)"
[ "$V" = "valid" ] && check "P1c second hunk keeps new-file numbering" PASS || check "P1c second hunk keeps new-file numbering (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 7)"
[ "$V" = "remap 4" ] && check "P1d out-of-hunk remaps to nearest (min distance)" PASS || check "P1d out-of-hunk remaps to nearest (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 8)"
[ "$V" = "remap 11" ] && check "P1e nearest crosses to the closer hunk" PASS || check "P1e nearest crosses to the closer hunk (got: $V)" FAIL
V="$(run_cli "$DIFF_TIE" t.js 7)"
[ "$V" = "remap 10" ] && check "P1f distance tie prefers the following line" PASS || check "P1f distance tie prefers the following line (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" gone.txt 1)"
[ "$V" = "none" ] && check "P1g deleted file has no RIGHT anchors" PASS || check "P1g deleted file has no RIGHT anchors (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" fresh.txt 2)"
[ "$V" = "valid" ] && check "P1h new file lines valid; trailing no-newline ignored" PASS || check "P1h new file lines valid (got: $V)" FAIL
V="$(run_cli "$DIFF_RENAME" after.js 6)"
[ "$V" = "valid" ] && check "P1i renamed file resolves the NEW path" PASS || check "P1i renamed file resolves the NEW path (got: $V)" FAIL
V="$(run_cli "$DIFF_RENAME" before.js 6)"
[ "$V" = "none" ] && check "P1j renamed file old path yields none" PASS || check "P1j renamed file old path yields none (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" img.png 1)"
[ "$V" = "none" ] && check "P1k binary file yields none" PASS || check "P1k binary file yields none (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" nosuch.js 5)"
[ "$V" = "none" ] && check "P1l unknown path yields none" PASS || check "P1l unknown path yields none (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js abc)"
[ "$V" = "none" ] && check "P1m non-numeric line yields none (fail-soft)" PASS || check "P1m non-numeric line yields none (got: $V)" FAIL
V="$(printf '%s' 'not a diff at all' | node "$LIB" x.js 1 2>/dev/null)"
RC=$?
[ "$V" = "none" ] && check "P1n garbage stdin yields none (fail-soft)" PASS || check "P1n garbage stdin yields none (got: $V)" FAIL
[ "$RC" -eq 0 ] && check "P1o always-exit-0 contract holds on garbage stdin" PASS || check "P1o always-exit-0 contract holds (rc=$RC)" FAIL
V="$(run_cli "$DIFF_MAIN" after.png.txt 1)"
[ "$V" = "valid" ] && check "P1p omitted-count hunk + fn trailer after binary parses" PASS || check "P1p omitted-count hunk + fn trailer after binary (got: $V)" FAIL
V="$(run_cli "$DIFF_FAR" far.js 500)"
[ "$V" = "none" ] && check "P1q remap distance beyond cap yields none" PASS || check "P1q remap distance beyond cap yields none (got: $V)" FAIL
V="$(run_cli "$DIFF_FAR" far.js 30)"
[ "$V" = "remap 1" ] && check "P1r remap within cap still remaps" PASS || check "P1r remap within cap still remaps (got: $V)" FAIL
V="$(run_cli "$DIFF_FAR" far.js 41)"
[ "$V" = "remap 1" ] && check "P1r2 remap at exactly the 40-line boundary remaps" PASS || check "P1r2 remap at exactly the 40-line boundary (got: $V)" FAIL
V="$(run_cli "$DIFF_FAR" far.js 42)"
[ "$V" = "none" ] && check "P1r3 one past the boundary yields none" PASS || check "P1r3 one past the boundary yields none (got: $V)" FAIL

# P1s+ — tricky content and paths
V="$(run_cli "$DIFF_TRICKY" sql/q.sql 2)"
V2="$(run_cli "$DIFF_TRICKY" sql/q.sql 3)"
if [ "$V" = "valid" ] && [ "$V2" = "valid" ]; then
  check "P1s hunk-body ++/-- content lines do not desync" PASS
else
  check "P1s hunk-body ++/-- content lines do not desync (got: $V/$V2)" FAIL
fi
V="$(run_cli "$DIFF_TRICKY" noeol.txt 2)"
[ "$V" = "valid" ] && check "P1t mid-hunk no-newline marker keeps numbering" PASS || check "P1t mid-hunk no-newline marker keeps numbering (got: $V)" FAIL
V="$(run_cli "$DIFF_TRICKY" 'dir with space/f.txt' 1)"
[ "$V" = "valid" ] && check "P1u path with spaces validates" PASS || check "P1u path with spaces validates (got: $V)" FAIL
V="$(run_cli "$DIFF_TRICKY" "quoted-$(printf '\303\244').txt" 1)"
[ "$V" = "valid" ] && check "P1v quoted octal-escaped path is unquoted" PASS || check "P1v quoted octal-escaped path is unquoted (got: $V)" FAIL
CRLF_DIFF="$(printf '%s' "$DIFF_FAR" | sed $'s/$/\r/')"
V="$(run_cli "$CRLF_DIFF" far.js 1)"
[ "$V" = "valid" ] && check "P1w CRLF diff input parses" PASS || check "P1w CRLF diff input parses (got: $V)" FAIL

# P1x — LEFT side via CLI side argument
V="$(run_cli "$DIFF_MAIN" gone.txt 1 LEFT)"
[ "$V" = "valid" ] && check "P1x deleted-file line is a valid LEFT anchor" PASS || check "P1x deleted-file line is a valid LEFT anchor (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 10 LEFT)"
[ "$V" = "valid" ] && check "P1y LEFT context numbering follows the old file" PASS || check "P1y LEFT context numbering follows the old file (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" fresh.txt 1 LEFT)"
[ "$V" = "none" ] && check "P1z new file has no LEFT anchors" PASS || check "P1z new file has no LEFT anchors (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 2 SIDEWAYS)"
[ "$V" = "none" ] && check "P1aa invalid side argument yields none" PASS || check "P1aa invalid side argument yields none (got: $V)" FAIL
V="$(run_cli "$DIFF_MAIN" src/x.js 12 '')"
[ "$V" = "valid" ] && check "P1ab empty side argument defaults to RIGHT" PASS || check "P1ab empty side argument defaults to RIGHT (got: $V)" FAIL
V="$(head -c 52500000 /dev/zero | tr '\0' 'a' | node "$LIB" x.js 1 2>/dev/null)"
[ "$V" = "none" ] && check "P1ac oversized stdin trips the cap and yields none" PASS || check "P1ac oversized stdin trips the cap (got: $V)" FAIL

# P2 — module exports
if node -e 'const m=require(process.argv[1]); process.exit(typeof m.parseDiff==="function"&&typeof m.isValidRight==="function"&&typeof m.nearestRight==="function"&&typeof m.isValidAnchor==="function"&&typeof m.nearestAnchor==="function"?0:1)' "$LIB" 2>/dev/null; then
  check "P2a lib exports parse + side-aware and RIGHT query helpers" PASS
else
  check "P2a lib exports parse + side-aware and RIGHT query helpers" FAIL
fi
if node -e 'const m=require(process.argv[1]); const p=m.parseDiff("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,1 @@\n-gone\n ctx\n"); process.exit(JSON.stringify(p.f.left)==="[1,2]"&&JSON.stringify(p.f.right)==="[1]"?0:1)' "$LIB" 2>/dev/null; then
  check "P2b LEFT side collects removed+context by old numbering" PASS
else
  check "P2b LEFT side collects removed+context by old numbering" FAIL
fi
if node -e 'const m=require(process.argv[1]); const p=m.parseDiff("diff --git a/g b/g\n--- a/g\n+++ b/g\n@@ -1,2 +1,2 @@\n-a1\n+b1\n ctx\n@@ -10,1 +10,1 @@\n-a10\n+b10\n"); process.exit(JSON.stringify(p.g.left)==="[1,2,10]"?0:1)' "$LIB" 2>/dev/null; then
  check "P2c LEFT numbering continues across hunks" PASS
else
  check "P2c LEFT numbering continues across hunks" FAIL
fi
if node -e 'const m=require(process.argv[1]); const p=m.parseDiff("diff --git a/__proto__ b/__proto__\n--- a/__proto__\n+++ b/__proto__\n@@ -1 +1 @@\n-x0\n+x\n"); process.exit(m.isValidRight(p,"__proto__",1)===true&&m.isValidRight(p,"constructor",1)===false?0:1)' "$LIB" 2>/dev/null; then
  check "P2d prototype-named paths parse and query cleanly" PASS
else
  check "P2d prototype-named paths parse and query cleanly" FAIL
fi

echo "----"
echo "test-valid-diff-lines: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
