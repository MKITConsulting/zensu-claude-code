#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGELOG="${CHANGELOG_PATH:-$PLUGIN_DIR/CHANGELOG.md}"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

HEADING_RE='^## \[Unreleased\]$'

has_unreleased_heading() {
  grep -qE "$HEADING_RE" "$1"
}

extract_unreleased_section() {
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

if has_unreleased_heading "$CHANGELOG"; then
  check "S1 ## [Unreleased] heading present" PASS
else
  check "S1 ## [Unreleased] heading present" FAIL
fi

UNRELEASED_SECTION="$(extract_unreleased_section "$CHANGELOG")"

if [ -z "$UNRELEASED_SECTION" ]; then
  check "S2 [Unreleased] section has content" FAIL
else
  check "S2 [Unreleased] section has content" PASS
fi

KEYWORDS=(
  "resolve-session-id.js"
  "Layer-1"
  "Layer-2"
  "parseCutoffMs"
  "sanitizeProjectDir"
)

for kw in "${KEYWORDS[@]}"; do
  if printf '%s\n' "$UNRELEASED_SECTION" | grep -qF -- "$kw"; then
    check "K $kw keyword present in [Unreleased] section" PASS
  else
    check "K $kw keyword present in [Unreleased] section" FAIL
  fi
done

if type has_unreleased_heading >/dev/null 2>&1; then
  check "M0 has_unreleased_heading helper defined" PASS
else
  check "M0 has_unreleased_heading helper defined" FAIL
fi

MUT_TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t changelog-anchor)"
trap 'rm -rf "$MUT_TMPDIR"' EXIT
MUT_COPY="$MUT_TMPDIR/CHANGELOG-suffixed.md"
cp "$CHANGELOG" "$MUT_COPY"
sed 's/^## \[Unreleased\]$/## [Unreleased] - 2026-05-25/' "$MUT_COPY" > "$MUT_COPY.tmp" && mv "$MUT_COPY.tmp" "$MUT_COPY"

if type has_unreleased_heading >/dev/null 2>&1 && has_unreleased_heading "$MUT_COPY"; then
  check "M1 has_unreleased_heading rejects suffixed heading '## [Unreleased] - YYYY-MM-DD'" FAIL
elif type has_unreleased_heading >/dev/null 2>&1; then
  check "M1 has_unreleased_heading rejects suffixed heading '## [Unreleased] - YYYY-MM-DD'" PASS
else
  check "M1 has_unreleased_heading rejects suffixed heading '## [Unreleased] - YYYY-MM-DD'" FAIL
fi

HEADING_RE_BEFORE_M2="$HEADING_RE"
EXTRACTED_M2_STRICT="$(extract_unreleased_section "$MUT_COPY")"
EXTRACTED_M2_LOOSE="$(HEADING_RE='^## \[Unreleased\]'; extract_unreleased_section "$MUT_COPY")"
HEADING_RE_AFTER_M2="$HEADING_RE"

if [ -z "$EXTRACTED_M2_STRICT" ] && [ -n "$EXTRACTED_M2_LOOSE" ]; then
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
