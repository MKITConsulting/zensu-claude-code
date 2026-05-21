#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN_DIR/hooks/lib/zensu-config.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$HELPER" ]; then
  check "helper file exists" FAIL
  echo "----"
  echo "test-helper-autofix-flags: $PASS PASS / $FAIL FAIL"
  exit 1
fi

TMP_CFG="/tmp/zensu-autofix-flags-$$.json"
cleanup() { rm -f "$TMP_CFG"; }
trap cleanup EXIT

source "$HELPER"

# --- zensu_autofix_include_suggestions ---

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true}}
EOF
export ZENSU_CONFIG="$TMP_CFG"

if zensu_autofix_include_suggestions; then
  check "include_suggestions: absent flag returns 1 (disabled, default off)" FAIL
else
  check "include_suggestions: absent flag returns 1 (disabled, default off)" PASS
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixIncludeSuggestions": true}}
EOF

if zensu_autofix_include_suggestions; then
  check "include_suggestions: explicit true returns 0 (enabled)" PASS
else
  check "include_suggestions: explicit true returns 0 (enabled)" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixIncludeSuggestions": false}}
EOF

if zensu_autofix_include_suggestions; then
  check "include_suggestions: explicit false returns 1 (disabled)" FAIL
else
  check "include_suggestions: explicit false returns 1 (disabled)" PASS
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixIncludeSuggestions": "true"}}
EOF

if zensu_autofix_include_suggestions; then
  check "include_suggestions: string 'true' returns 1 (strict ===)" FAIL
else
  check "include_suggestions: string 'true' returns 1 (strict ===)" PASS
fi

MISSING_CFG="/tmp/zensu-autofix-flags-missing-$$.json"
rm -f "$MISSING_CFG"
export ZENSU_CONFIG="$MISSING_CFG"
if zensu_autofix_include_suggestions; then
  check "include_suggestions: missing config returns 1 (disabled)" FAIL
else
  check "include_suggestions: missing config returns 1 (disabled)" PASS
fi

export ZENSU_CONFIG="$TMP_CFG"
cat > "$TMP_CFG" <<'EOF'
{this is not json
EOF
if zensu_autofix_include_suggestions; then
  check "include_suggestions: malformed JSON returns 1 (disabled)" FAIL
else
  check "include_suggestions: malformed JSON returns 1 (disabled)" PASS
fi

# --- zensu_autofix_max_rounds ---

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFix": true}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: absent flag echoes default 5" PASS
else
  check "max_rounds: absent flag echoes default 5 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": 3}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "3" ]; then
  check "max_rounds: explicit 3 echoes 3" PASS
else
  check "max_rounds: explicit 3 echoes 3 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": 1}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "1" ]; then
  check "max_rounds: explicit 1 (lower bound) echoes 1" PASS
else
  check "max_rounds: explicit 1 echoes 1 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": 99}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "99" ]; then
  check "max_rounds: explicit 99 (upper bound) echoes 99" PASS
else
  check "max_rounds: explicit 99 echoes 99 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": 0}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: 0 out of range, fallback to 5" PASS
else
  check "max_rounds: 0 out of range, fallback to 5 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": 100}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: 100 out of range, fallback to 5" PASS
else
  check "max_rounds: 100 out of range, fallback to 5 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": "five"}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: non-int 'five', fallback to 5" PASS
else
  check "max_rounds: non-int 'five', fallback to 5 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{"hooks": {"autoFixMaxRounds": 1.5}}
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: non-integer 1.5, fallback to 5" PASS
else
  check "max_rounds: non-integer 1.5, fallback to 5 (got '$val')" FAIL
fi

cat > "$TMP_CFG" <<'EOF'
{also broken
EOF
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: malformed JSON, fallback to 5" PASS
else
  check "max_rounds: malformed JSON, fallback to 5 (got '$val')" FAIL
fi

export ZENSU_CONFIG="$MISSING_CFG"
val=$(zensu_autofix_max_rounds)
if [ "$val" = "5" ]; then
  check "max_rounds: missing config, fallback to 5" PASS
else
  check "max_rounds: missing config, fallback to 5 (got '$val')" FAIL
fi

echo "----"
echo "test-helper-autofix-flags: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
