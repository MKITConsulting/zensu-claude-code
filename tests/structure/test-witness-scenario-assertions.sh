#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCEN_DIR="$PLUGIN_DIR/evals/tdd-manager-pretool/scenarios"
BASH_YAML="$SCEN_DIR/witness-bash-runs.yaml"
GAP_YAML="$SCEN_DIR/witness-evidence-gap.yaml"
VIA_YAML="$SCEN_DIR/witness-non-bash-via.yaml"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$BASH_YAML" "$GAP_YAML" "$VIA_YAML"; do
  if [ ! -f "$f" ]; then
    check "scenario file exists: $(basename "$f")" FAIL
    echo "----"
    echo "test-witness-scenario-assertions: $PASS PASS / $FAIL FAIL"
    exit 1
  fi
  check "scenario file exists: $(basename "$f")" PASS
done

GAP_TIGHTENED=$(grep -E 'EVIDENCE GAP\\s\*\[.*\]\\s\*cmd="' "$GAP_YAML" | head -1)
if [ -n "$GAP_TIGHTENED" ]; then
  check "S1-A witness-evidence-gap.yaml uses tightened /EVIDENCE GAP\\s*[—-]\\s*cmd=\"/i regex (NOT bare /EVIDENCE GAP/i)" PASS
else
  check "S1-A witness-evidence-gap.yaml uses tightened /EVIDENCE GAP\\s*[—-]\\s*cmd=\"/i regex (NOT bare /EVIDENCE GAP/i)" FAIL
fi

VIA_TIGHTENED=$(grep -E 'EVIDENCE GAP\\s\*\[.*\]\\s\*cmd="' "$VIA_YAML" | head -1)
if [ -n "$VIA_TIGHTENED" ]; then
  check "S1-B witness-non-bash-via.yaml uses tightened /EVIDENCE GAP\\s*[—-]\\s*cmd=\"/i regex (NOT bare /EVIDENCE GAP/i)" PASS
else
  check "S1-B witness-non-bash-via.yaml uses tightened /EVIDENCE GAP\\s*[—-]\\s*cmd=\"/i regex (NOT bare /EVIDENCE GAP/i)" FAIL
fi

GAP_TIGHT_FUNCTIONAL=$(GAP_YAML="$GAP_YAML" node -e '
  const fs = require("fs");
  const yaml = fs.readFileSync(process.env.GAP_YAML, "utf8");
  const m = yaml.match(/\/EVIDENCE GAP\\s\*\[[^\]]+\]\\s\*cmd="\/i/);
  if (!m) { console.log("NO_TIGHT_REGEX"); process.exit(0); }
  const rxBody = m[0].replace(/^\//, "").replace(/\/i$/, "");
  const rx = new RegExp(rxBody, "i");
  const narrative = "No EVIDENCE GAP found in the audit summary";
  const schema = "AUDIT — cmd=\"npm test\" exit=0\nEVIDENCE GAP — cmd=\"unknown\" claimed but not in witness log";
  console.log(JSON.stringify({ narrativeMatches: rx.test(narrative), schemaMatches: rx.test(schema) }));
' 2>&1)
EXPECTED_GAP_FUNCTIONAL='{"narrativeMatches":false,"schemaMatches":true}'
if [ "$GAP_TIGHT_FUNCTIONAL" = "$EXPECTED_GAP_FUNCTIONAL" ]; then
  check "S1-C tightened EVIDENCE GAP regex rejects narrative paraphrase + matches literal schema" PASS
else
  check "S1-C tightened EVIDENCE GAP regex (expected=$EXPECTED_GAP_FUNCTIONAL got=$GAP_TIGHT_FUNCTIONAL)" FAIL
fi

if grep -qF '**CRITICAL OUTPUT REQUIREMENTS**' "$BASH_YAML"; then
  check "S2-A witness-bash-runs.yaml spec_block contains **CRITICAL OUTPUT REQUIREMENTS** imperative" PASS
else
  check "S2-A witness-bash-runs.yaml spec_block contains **CRITICAL OUTPUT REQUIREMENTS** imperative" FAIL
fi

if grep -qF '**OUTPUT MUST CONTAIN**' "$GAP_YAML" && grep -qF '**OUTPUT MUST NOT CONTAIN**' "$GAP_YAML"; then
  check "S2-B witness-evidence-gap.yaml spec_block contains **OUTPUT MUST CONTAIN** and **OUTPUT MUST NOT CONTAIN** imperatives" PASS
else
  check "S2-B witness-evidence-gap.yaml spec_block contains **OUTPUT MUST CONTAIN** and **OUTPUT MUST NOT CONTAIN** imperatives" FAIL
fi

if grep -qF '**STEP 1 IS MANDATORY**' "$VIA_YAML" && grep -qF '**OUTPUT MUST CONTAIN**' "$VIA_YAML"; then
  check "S2-C witness-non-bash-via.yaml spec_block contains **STEP 1 IS MANDATORY** and **OUTPUT MUST CONTAIN** imperatives" PASS
else
  check "S2-C witness-non-bash-via.yaml spec_block contains **STEP 1 IS MANDATORY** and **OUTPUT MUST CONTAIN** imperatives" FAIL
fi

echo "----"
echo "test-witness-scenario-assertions: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
