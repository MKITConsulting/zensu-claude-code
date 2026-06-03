#!/bin/bash
set -u

# The session-id resolver round's changelog entries shipped in 0.4.0 (folded out
# of [Unreleased] when the 0.4.0 main-thread-TDD migration release was cut). This
# test pins those entries under the ## [0.4.0] section.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGELOG="${CHANGELOG_PATH:-$PLUGIN_DIR/CHANGELOG.md}"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

HEADING_RE='^## \[0\.4\.0\]'

has_release_heading() {
  grep -qE "$HEADING_RE" "$1"
}

extract_release_section() {
  HEADING_RE="$HEADING_RE" awk '
    $0 ~ ENVIRON["HEADING_RE"] { in_section = 1; next }
    in_section && /^## \[/ { in_section = 0 }
    in_section { print }
  ' "$1"
}

if [ ! -f "$CHANGELOG" ]; then
  check "CHANGELOG.md exists at $CHANGELOG" FAIL
  echo "----"
  echo "test-changelog-unreleased-resolver-entries: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "S0 CHANGELOG.md exists" PASS

if has_release_heading "$CHANGELOG"; then
  check "S1 ## [0.4.0] heading present" PASS
else
  check "S1 ## [0.4.0] heading present" FAIL
fi

RELEASE_SECTION="$(extract_release_section "$CHANGELOG")"

if [ -z "$RELEASE_SECTION" ]; then
  check "S2 [0.4.0] section has content" FAIL
else
  check "S2 [0.4.0] section has content" PASS
fi

KEYWORDS=(
  "resolve-session-id.js"
  "Layer-1"
  "Layer-2"
  "parseCutoffMs"
  "sanitizeProjectDir"
)

for kw in "${KEYWORDS[@]}"; do
  if printf '%s\n' "$RELEASE_SECTION" | grep -qF -- "$kw"; then
    check "K $kw keyword present in [0.4.0] section" PASS
  else
    check "K $kw keyword present in [0.4.0] section" FAIL
  fi
done

if type has_release_heading >/dev/null 2>&1; then
  check "M0 has_release_heading helper defined" PASS
else
  check "M0 has_release_heading helper defined" FAIL
fi

# M1 — the extractor bounds the section: it must NOT bleed into the next release
# heading (## [0.3.28]). That section's distinctive content must be absent.
if printf '%s\n' "$RELEASE_SECTION" | grep -qF 'ZENSU_MCP_URL'; then
  check "M1 extractor stops at next release heading (no 0.3.28 bleed)" FAIL
else
  check "M1 extractor stops at next release heading (no 0.3.28 bleed)" PASS
fi

# M2 — the awk extractor reads its regex from the shared HEADING_RE source; a
# non-matching override yields an empty section. Verify the indirection works.
HEADING_RE_BEFORE_M2="$HEADING_RE"
EXTRACTED_M2_STRICT="$(extract_release_section "$CHANGELOG")"
EXTRACTED_M2_NONE="$(HEADING_RE='^## \[9\.9\.9\]'; extract_release_section "$CHANGELOG")"
HEADING_RE_AFTER_M2="$HEADING_RE"

if [ -n "$EXTRACTED_M2_STRICT" ] && [ -z "$EXTRACTED_M2_NONE" ]; then
  check "M2 awk extractor reads regex from shared HEADING_RE source" PASS
else
  check "M2 awk extractor reads regex from shared HEADING_RE source" FAIL
fi

if [ "$HEADING_RE_BEFORE_M2" = "$HEADING_RE_AFTER_M2" ]; then
  check "M3 HEADING_RE outer-scope unchanged by M2 block (subshell wrap integrity)" PASS
else
  check "M3 HEADING_RE outer-scope unchanged by M2 block (subshell wrap integrity)" FAIL
fi

echo "----"
echo "test-changelog-unreleased-resolver-entries: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
