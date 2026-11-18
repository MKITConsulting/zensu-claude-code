#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
REGISTRY="${ZENSU_PLAYWRIGHT_CLI_REGISTRY:-https://registry.npmjs.org/@playwright%2fcli}"

die() {
  local code="$1"
  shift
  printf 'playwright-cli-drift: %s\n' "$*" >&2
  exit "$code"
}

command -v curl >/dev/null 2>&1 || die 2 'curl is not installed'
command -v node >/dev/null 2>&1 || die 2 'node is not installed'

work="$(mktemp -d "${TMPDIR:-/tmp}/playwright-cli-drift.XXXXXX")"
trap 'rm -rf "$work"' EXIT

curl -fsSL --max-time 60 -H 'Accept: application/vnd.npm.install-v1+json' -o "$work/metadata.json" "$REGISTRY" \
  || die 1 'cannot read the @playwright/cli registry metadata'

node - "$ROOT" "$work/metadata.json" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, metadataFile] = process.argv.slice(2);
const { PACKAGE_NAME, validVersion } = require(path.join(root, 'hooks', 'lib', 'playwright-cli-version-v1.js'));
const { PLAYWRIGHT_CLI_SOURCE_VERSION: measured } = require(path.join(root, 'hooks', 'lib', 'verify-consent-v1.js'));
const STABLE = /^([0-9]+)\.([0-9]+)\.([0-9]+)$/;
const fail = (message) => {
  process.stderr.write(`playwright-cli-drift: ${message}\n`);
  process.exit(1);
};
const isRecord = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const parts = (version) => STABLE.exec(version).slice(1).map(BigInt);
const compare = (a, b) => {
  const x = parts(a);
  const y = parts(b);
  for (let i = 0; i < 3; i += 1) {
    if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
};

if (typeof measured !== 'string' || !STABLE.test(measured)) fail('PLAYWRIGHT_CLI_SOURCE_VERSION is not a plain X.Y.Z version');
let metadata;
try {
  metadata = JSON.parse(fs.readFileSync(metadataFile, 'utf8'));
} catch {
  fail('the registry metadata do not parse as JSON');
}
if (!isRecord(metadata) || metadata.name !== PACKAGE_NAME) fail(`the registry metadata do not describe ${PACKAGE_NAME}`);
if (!isRecord(metadata.versions)) fail('the registry metadata list no versions');
const stable = [];
for (const [key, entry] of Object.entries(metadata.versions)) {
  if (!validVersion(key)) fail('the registry lists a version that is not a semantic version');
  if (!isRecord(entry) || entry.name !== PACKAGE_NAME || entry.version !== key) {
    fail(`the registry entry for ${key} does not describe ${PACKAGE_NAME} ${key}`);
  }
  if (STABLE.test(key)) stable.push(key);
}
if (!stable.includes(measured)) fail(`the registry does not list ${PACKAGE_NAME} ${measured}, the measured version`);
const newest = stable.reduce((a, b) => (compare(b, a) > 0 ? b : a));
if (compare(newest, measured) <= 0) process.exit(0);
process.stdout.write(`${[
  `<!-- zensu-playwright-cli-drift playwright-cli=${newest} -->`,
  'npm lists a stable `@playwright/cli` release newer than the one the browser consent gate was measured against:',
  '',
  `- \`@playwright/cli\` ${newest} (measured: ${measured}, \`PLAYWRIGHT_CLI_SOURCE_VERSION\` in \`hooks/lib/verify-consent-v1.js\`)`,
  '',
  'This check read registry metadata only and installed or ran no package. Until the gate is measured against the new release, the run-config helper refuses it and names the install command of the measured version, so a user who installs the newest release cannot start a browser verification run. The new release can also parse an argument shape the gate admits differently. Re-measure it on a machine of your own:',
  '',
  `1. Install it into a scratch directory outside the repository: \`npm install --prefix <dir> --ignore-scripts @playwright/cli@${newest}\``,
  '2. Re-record the golden fixture with that release\'s own parser: `node tests/structure/fixtures/record-playwright-cli-argv.js <dir>/node_modules/@playwright/cli tests/structure/fixtures/playwright-cli-argv.v1.json`',
  '3. Port every difference the new recording shows into `parseCliArgs` and its option sets in `hooks/lib/verify-consent-v1.js`, check the release for a new configuration channel or a renamed run-config fence, bump `PLAYWRIGHT_CLI_SOURCE_VERSION` with every copy `.claude/rules/browser-consent-gate.md` lists, and run `tests/structure/test-verify-consent.sh`, all in one pull request.',
].join('\n')}\n`);
NODE
