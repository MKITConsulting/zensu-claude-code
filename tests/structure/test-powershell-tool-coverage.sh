#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STRUCTURE="$PLUGIN_DIR/tests/structure"
HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
COVERAGE="$PLUGIN_DIR/hooks/lib/shell-tool-coverage-v1.js"
ANALYZER="$PLUGIN_DIR/hooks/lib/powershell-command-v1.js"
UNIT="$STRUCTURE/powershell-command-v1.test.js"

PASS=0; FAIL=0
check() {
  if [ "$2" = "PASS" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

for f in "$HOOKS_JSON" "$COVERAGE" "$ANALYZER" "$UNIT"; do
  if [ ! -f "$f" ]; then
    check "PC0 required file exists: $f" FAIL
    echo "----"
    echo "test-powershell-tool-coverage: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
done
check "PC0 the coverage module, the analyzer and its unit file exist" PASS

. "$(dirname "$0")/lib-unit-registry.sh"
unit_check "PC1 the analyzer unit file passes" "$UNIT"

ROSTER="$(node -e '
  const fs = require("fs");
  const coverage = require(process.argv[1]).shellCoverage(JSON.parse(fs.readFileSync(process.argv[2], "utf8")));
  if (!coverage) process.exit(2);
  for (const entry of coverage.hooks) process.stdout.write(entry.event + " " + entry.hook + " " + (entry.powershell === "registered" ? "covered" : "gap") + "\n");
' "$COVERAGE" "$HOOKS_JSON" 2>/dev/null)"
ROSTER_RC=$?
if [ "$ROSTER_RC" -eq 0 ] && [ -n "$ROSTER" ]; then
  check "PC2a the coverage module reads the shipped hooks.json ($(printf '%s\n' "$ROSTER" | wc -l | tr -d ' ') shell hooks)" PASS
else
  check "PC2a the coverage module reads the shipped hooks.json (rc=$ROSTER_RC)" FAIL
fi
GAPS="$(printf '%s\n' "$ROSTER" | awk '$3 != "covered" {print $1 " " $2}')"
if [ -n "$ROSTER" ] && [ -z "$GAPS" ]; then
  check "PC2 no hook fires for the Bash tool without also firing for the PowerShell tool" PASS
else
  check "PC2 no hook fires for the Bash tool without also firing for the PowerShell tool (gaps: $(printf '%s' "$GAPS" | tr '\n' ','))" FAIL
fi
CONTROL_GAPS="$(node -e '
  const coverage = require(process.argv[1]).shellCoverage({ hooks: { PreToolUse: [
    { matcher: "Bash", hooks: [{ type: "command", command: "${CLAUDE_PLUGIN_ROOT}/hooks/pre-probe.sh" }] },
    { matcher: "Bash|PowerShell", hooks: [{ type: "command", command: "${CLAUDE_PLUGIN_ROOT}/hooks/pre-covered.sh" }] },
  ] } });
  process.stdout.write(coverage.gaps.map((entry) => entry.hook).join(","));
' "$COVERAGE" 2>/dev/null)"
[ "$CONTROL_GAPS" = "pre-probe.sh" ] \
  && check "PC2b-control a Bash-only registration is reported as a gap and a Bash|PowerShell one is not" PASS \
  || check "PC2b-control a Bash-only registration is reported as a gap and a Bash|PowerShell one is not (got: ${CONTROL_GAPS:-<none>})" FAIL

read -r -d '' DISPOSITIONS <<'EOF'
PreToolUse	pre-bash-zensu-gate.sh	test-bash-zensu-gate.sh	psrun "B40a PowerShell read"
PreToolUse	pre-bash-source-write-gate.sh	test-bash-source-write-gate.sh	psrun "WP1 PowerShell rebind
PreToolUse	pre-write-secret-scan.sh	test-secret-scan-gate.sh	check "F8p PowerShell write
PreToolUse	pre-browser-navigation-consent.sh	test-verify-consent.sh	"V70 the real pre hook denies a PowerShell call
PostToolUse	post-browser-navigation-consent.sh	test-verify-consent.sh	"V70d the recorder writes no consent record for a PowerShell call
PostToolUse	post-artifact-redact.sh	test-artifact-redaction.sh	"hand-rolled PowerShell log write"
PreToolUse	pre-work-order-gate.sh	work-order-v1.test.js	payload('PowerShell', 'Get-ChildItem')
PostToolUse	post-work-order.sh	work-order-v1.test.js	postToolUpdate(context, { tool_name: 'PowerShell'
PreToolUse	pre-reviewer-capability-gate.sh	test-reviewer-capability-gate.sh	"PS1 a named neutral agent's PowerShell command
EOF
TABLE_KEYS="$(printf '%s\n' "$DISPOSITIONS" | awk -F'\t' '{print $1 " " $2}' | sort)"
ROSTER_KEYS="$(printf '%s\n' "$ROSTER" | awk '{print $1 " " $2}' | sort)"
MISSING="$(comm -23 <(printf '%s\n' "$ROSTER_KEYS") <(printf '%s\n' "$TABLE_KEYS"))"
STALE="$(comm -13 <(printf '%s\n' "$ROSTER_KEYS") <(printf '%s\n' "$TABLE_KEYS"))"
if [ -z "$MISSING" ]; then
  check "PC3 every hook that fires for the shell tools has a PowerShell disposition case in this driver" PASS
else
  check "PC3 these hooks fire for the PowerShell tool without a disposition case; judge PowerShell in each and add a row: $(printf '%s' "$MISSING" | tr '\n' ',')" FAIL
fi
if [ -z "$STALE" ]; then
  check "PC3b every disposition row names a hook that still fires for the shell tools" PASS
else
  check "PC3b these disposition rows name a hook that no longer fires for the shell tools: $(printf '%s' "$STALE" | tr '\n' ',')" FAIL
fi
while IFS="$(printf '\t')" read -r event hook suite marker; do
  [ -n "$hook" ] || continue
  if [ -f "$STRUCTURE/$suite" ] && grep -qF -- "$marker" "$STRUCTURE/$suite"; then
    check "PC4 $event $hook has its PowerShell case in $suite" PASS
  else
    check "PC4 $event $hook has its PowerShell case in $suite (marker not found: $marker)" FAIL
  fi
done <<EOF
$DISPOSITIONS
EOF

grep -qF 'require("./powershell-command-v1.js")' "$PLUGIN_DIR/hooks/lib/bash-source-write-parse.js" \
  && check "PC5a the source-write parser loads the analyzer from its own hooks/lib" PASS \
  || check "PC5a the source-write parser loads the analyzer from its own hooks/lib" FAIL
grep -qF 'ZPS=./powershell-command-v1.js' "$PLUGIN_DIR/hooks/pre-bash-zensu-gate.sh" \
  && check "PC5b the CLI gate loads the analyzer from its own hooks/lib" PASS \
  || check "PC5b the CLI gate loads the analyzer from its own hooks/lib" FAIL
grep -qF "require('./powershell-command-v1.js').spellings(" "$PLUGIN_DIR/hooks/lib/verify-consent-v1.js" \
  && check "PC5c the consent gate reads PowerShell spellings through the analyzer in its own hooks/lib" PASS \
  || check "PC5c the consent gate reads PowerShell spellings through the analyzer in its own hooks/lib" FAIL

unit_check_done "PC1z every unit file the registry gives this suite was graded"

echo "----"
echo "test-powershell-tool-coverage: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
