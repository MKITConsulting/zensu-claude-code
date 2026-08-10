#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WORKFLOWS="$ROOT/.github/workflows"
RUNNER="$ROOT/tests/run-all.sh"
PACKAGE="$ROOT/package.json"
MANIFEST="$ROOT/tests/profiles/promptfoo-local-only.v1.json"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

workflow_matches() {
  local pattern="$1"
  grep -RniE --include='*.yml' --include='*.yaml' "$pattern" "$WORKFLOWS" 2>/dev/null || true
}

FORBIDDEN='promptfoo|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|CODEX_AUTH|OPENAI_API_KEY|GOOGLE_API_KEY|AZURE_OPENAI_API_KEY|session-control:(selfcheck|contract|upgrade|live|concurrency|adversarial|release)|evals/|npm[[:space:]]+(run|exec)|npx|pnpm|yarn'
MATCHES="$(workflow_matches "$FORBIDDEN")"
if [ -z "$MATCHES" ]; then
  check "GitHub Actions never invokes or configures Promptfoo/live-model evaluation" PASS
else
  check "GitHub Actions never invokes or configures Promptfoo/live-model evaluation" FAIL
  printf '%s\n' "$MATCHES" | sed 's/^/    /'
fi

if node - "$WORKFLOWS" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
let source = fs.readdirSync(root)
  .filter((name) => /\.ya?ml$/.test(name))
  .map((name) => fs.readFileSync(path.join(root, name), 'utf8'))
  .join('\n');
source = source.replace(
  /\$\{\{\s*secrets\.(?:GITHUB_TOKEN|IMMUTABLE_RELEASES_ADMIN_TOKEN)\s*\}\}/g,
  '',
);
process.exit(/\bsecrets\b/.test(source) ? 1 : 0);
NODE
then
  check "Actions secrets are limited to repository and immutable-release administration" PASS
else
  check "Actions secrets are limited to repository and immutable-release administration" FAIL
fi

if [ ! -e "$WORKFLOWS/session-control-nightly.yml" ] \
  && [ ! -e "$WORKFLOWS/pretool-eval-nightly.yml" ] \
  && [ ! -e "$WORKFLOWS/evals.yml" ]; then
  check "Dedicated Promptfoo Actions workflows are absent" PASS
else
  check "Dedicated Promptfoo Actions workflows are absent" FAIL
fi

if node - "$WORKFLOWS" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const root = process.argv[2];
for (const name of fs.readdirSync(root).filter((entry) => /\.ya?ml$/.test(entry))) {
  for (const line of fs.readFileSync(path.join(root, name), 'utf8').split(/\r?\n/)) {
    const invokesRunner = /tests\/run-all\.sh/.test(line)
      || /\bnpm\s+(?:test|run-script)\b/.test(line);
    // A trailing `--shard=I/N` is permitted and nothing else is: the point of this
    // check is that Actions never selects a Promptfoo mode, not that the command
    // takes no arguments. The shard value is quoted because it expands a shell
    // arithmetic expression containing spaces.
    if (invokesRunner
        && !/^(?:-\s*)?(?:run:\s*)?bash tests\/run-all\.sh --ci(?: "--shard=[^"]+")?$/.test(line.trim())) {
      process.exit(1);
    }
  }
}
NODE
then
  check "Every Actions full-suite invocation selects the non-Promptfoo CI mode" PASS
else
  check "Every Actions full-suite invocation selects the non-Promptfoo CI mode" FAIL
fi

if grep -Fq -- '--ci' "$RUNNER" \
  && grep -Fq 'Promptfoo suites are local-only' "$RUNNER" \
  && grep -Fq 'promptfoo-local-only.v1.json' "$RUNNER" \
  && grep -Fq 'promptfoo-local-only.v1.json' "$ROOT/tests/run-windows-safety-shard.js"; then
  check "The deterministic runner exposes an explicit local-only CI mode" PASS
else
  check "The deterministic runner exposes an explicit local-only CI mode" FAIL
fi

if node - "$ROOT" "$MANIFEST" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const [root, file] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, 'utf8'));
const actual = fs.readdirSync(path.join(root, 'tests', 'structure'))
  .filter((name) => /^test-.*\.sh$/.test(name)).sort();
const local = [
  'test-claude-promptfoo-wrapper.sh',
  'test-promptfoo-concurrency.sh',
  'test-promptfoo-context-nudge-reaction.sh',
  'test-promptfoo-reset-review-limit.sh',
  'test-promptfoo-session-upgrade.sh',
  'test-promptfoo-verify-feature.sh',
  'test-promptfoo-zen-mode.sh',
];
const classified = [...value.ciStructureTests, ...value.localStructureTests];
const offline = value.ciOfflineSuites.map(
  ({ path: suitePath, ciArgs, needsNodeDeps }) => [suitePath, ciArgs, needsNodeDeps],
);
const expectedOffline = [
  ['evals/config-gate/run-eval.sh', ['--self-check'], false],
  ['evals/session-control/run-self-check.sh', ['--ci'], true],
  ['evals/tdd-review-chain/run-self-check.sh', [], false],
  ['evals/reset-review-limit/run-self-check.sh', ['--ci'], true],
  ['evals/tdd-manager-pretool/run-eval.sh', ['--self-check'], false],
];
process.exit(value.schemaVersion === 1
  && JSON.stringify(value.localStructureTests) === JSON.stringify(local)
  && JSON.stringify([...new Set(classified)].sort()) === JSON.stringify(actual)
  && classified.length === new Set(classified).size
  && JSON.stringify(offline) === JSON.stringify(expectedOffline) ? 0 : 1);
NODE
then
  check "One canonical allowlist classifies every structure and offline suite" PASS
else
  check "One canonical allowlist classifies every structure and offline suite" FAIL
fi

if grep -Fq 'OFFLINE_LINES="$(offline_inventory)" || exit 2' "$RUNNER" \
  && grep -Fq 'done <<< "$OFFLINE_LINES"' "$RUNNER" \
  && grep -Fq 'if [ "$MODE" != "--ci" ]; then' "$ROOT/evals/session-control/run-self-check.sh" \
  && grep -Fq 'if [ "$MODE" != "--ci" ]; then' "$ROOT/evals/reset-review-limit/run-self-check.sh" \
  && grep -Fq 'enforce-upgrade-coverage.js" --ci' "$ROOT/evals/session-control/run-self-check.sh" \
  && grep -Fq "file !== 'evals/session-control/tests/upgrade-provider-selftest.js'" \
    "$ROOT/evals/session-control/tests/enforce-upgrade-coverage.js"; then
  check "CI retains deterministic eval coverage without launching Promptfoo" PASS
else
  check "CI retains deterministic eval coverage without launching Promptfoo" FAIL
fi

EVIDENCE_SHAPE='{schema:"zensu-deterministic-release-evidence-v1", gate:"passed", source_git_revision:$source_git_revision, runtime_digest:$runtime_digest, plugin_version:$plugin_version}'
if [ "$(grep -Fc "$EVIDENCE_SHAPE" "$WORKFLOWS/release.yml")" -eq 2 ]; then
  check "Prepare and publish emit the same deterministic release evidence schema" PASS
else
  check "Prepare and publish emit the same deterministic release evidence schema" FAIL
fi

if jq -e '.devDependencies.promptfoo | type == "string"' "$PACKAGE" >/dev/null 2>&1 \
  && [ -f "$ROOT/evals/session-control/run-eval.sh" ] \
  && [ -f "$ROOT/evals/session-control/promptfooconfig-live.yaml" ] \
  && grep -Fq 'session-control:release' "$PACKAGE"; then
  check "Promptfoo release and live suites remain available for local execution" PASS
else
  check "Promptfoo release and live suites remain available for local execution" FAIL
fi

printf '%s\n' '----' "test-promptfoo-local-only: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
