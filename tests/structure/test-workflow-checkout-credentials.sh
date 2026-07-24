#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1));
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

OUT="$(node - "$ROOT" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const YAML = require('yaml');
const root = process.argv[2];
const workflowDir = path.join(root, '.github', 'workflows');
const files = fs.readdirSync(workflowDir).filter((name) => name.endsWith('.yml')).sort();
let checkouts = 0;
let safeCheckouts = 0;
const documents = new Map();
for (const name of files) {
  const document = YAML.parse(fs.readFileSync(path.join(workflowDir, name), 'utf8'));
  documents.set(name, document);
  for (const job of Object.values(document.jobs || {})) {
    for (const step of job.steps || []) {
      if (typeof step.uses === 'string' && step.uses.startsWith('actions/checkout@')) {
        checkouts += 1;
        if (step.with?.['persist-credentials'] === false) safeCheckouts += 1;
      }
    }
  }
}
const release = documents.get('release.yml');
const prepare = release?.jobs?.prepare?.steps || [];
const publish = release?.jobs?.publish?.steps || [];
const push = prepare.find((step) => step.name === 'Push release branch + print PR link');
const prepareGate = prepare.findIndex((step) => step.name === 'Session Control release gate (created commit SHA)');
const prepareEvidence = prepare.findIndex((step) => step.name === 'Upload created-commit release evidence');
const pushIndex = prepare.indexOf(push);
const publishGate = publish.findIndex((step) => step.name === 'Session Control publish gate (exact main SHA)');
const publishEvidence = publish.findIndex((step) => step.name === 'Upload exact-main-SHA publish evidence');
const publishMutation = publish.findIndex((step) => step.name === 'Draft, attach, publish, and verify immutable release');
const githubTokenSteps = [...prepare, ...publish].filter(
  (step) => step.env?.GH_TOKEN === '${{ secrets.GITHUB_TOKEN }}',
);
const result = {
  checkout_count: checkouts,
  safe_checkout_count: safeCheckouts,
  default_read: release?.permissions?.contents === 'read',
  push_scoped: push?.env?.GH_TOKEN === '${{ secrets.GITHUB_TOKEN }}'
    && String(push?.run || '').includes('gh auth setup-git'),
  mutation_token_steps: githubTokenSteps.map((step) => step.name),
  token_ordered: prepareGate >= 0 && prepareGate < prepareEvidence && prepareEvidence < pushIndex
    && publishGate >= 0 && publishGate < publishEvidence && publishEvidence < publishMutation,
};
process.stdout.write(JSON.stringify(result));
NODE
)"
RC=$?
if [ "$RC" -ne 0 ]; then
  check "workflow YAML parses for credential audit" FAIL
  printf '%s\n' '----' "test-workflow-checkout-credentials: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "workflow YAML parses for credential audit" PASS

CHECKOUT_COUNT="$(printf '%s' "$OUT" | jq -r .checkout_count)"
SAFE_COUNT="$(printf '%s' "$OUT" | jq -r .safe_checkout_count)"
if [ "$CHECKOUT_COUNT" -eq 6 ] && [ "$SAFE_COUNT" -eq "$CHECKOUT_COUNT" ]; then
  check "all six checkout steps disable persisted credentials" PASS
else
  check "all checkout steps disable persisted credentials (checkouts=$CHECKOUT_COUNT safe=$SAFE_COUNT)" FAIL
fi

[ "$(printf '%s' "$OUT" | jq -r .default_read)" = true ] \
  && check "release workflow defaults to contents: read" PASS \
  || check "release workflow defaults to contents: read" FAIL
[ "$(printf '%s' "$OUT" | jq -r .push_scoped)" = true ] \
  && check "release-branch push receives GH_TOKEN only in its dedicated authenticated step" PASS \
  || check "release-branch push receives GH_TOKEN only in its dedicated authenticated step" FAIL
[ "$(printf '%s' "$OUT" | jq -c .mutation_token_steps)" = '["Push release branch + print PR link","Draft, attach, publish, and verify immutable release"]' ] \
  && check "write-capable GitHub token is mapped only to the two final mutation steps" PASS \
  || check "write-capable GitHub token is mapped only to the two final mutation steps" FAIL
[ "$(printf '%s' "$OUT" | jq -r .token_ordered)" = true ] \
  && check "GitHub mutation tokens occur only after paid gates and evidence uploads" PASS \
  || check "GitHub mutation tokens occur only after paid gates and evidence uploads" FAIL

printf '%s\n' '----' "test-workflow-checkout-credentials: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
