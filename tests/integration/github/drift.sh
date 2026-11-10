#!/bin/bash
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
RELEASE="${ZENSU_GH_LATEST_RELEASE_URL:-https://api.github.com/repos/cli/cli/releases/latest}"

die() {
  local code="$1"
  shift
  printf 'github-drift: %s\n' "$*" >&2
  exit "$code"
}

command -v curl >/dev/null 2>&1 || die 2 'curl is not installed'
command -v node >/dev/null 2>&1 || die 2 'node is not installed'

work="$(mktemp -d "${TMPDIR:-/tmp}/github-drift.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fetch() {
  local url="$1" out="$2" token="${GH_TOKEN:-}"
  case "$url" in
    (https://api.github.com/*)
      if printf '%s' "$token" | grep -Eq '^[A-Za-z0-9_]+$'; then
        printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsSL --max-time 60 -K - -o "$out" "$url"
        return
      fi
      ;;
  esac
  curl -fsSL --max-time 60 -o "$out" "$url"
}

fetch "$RELEASE" "$work/release.json" || die 1 'cannot read the newest gh release'
version="$(node -e '
  let release = {};
  try {
    release = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")) || {};
  } catch {
    process.exit(1);
  }
  const tag = String(release.tag_name || "");
  if (release.draft === true || release.prerelease === true || !/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(tag)) process.exit(1);
  process.stdout.write(tag.slice(1));
' "$work/release.json")" || die 1 'the newest gh release carries no vX.Y.Z tag'
fetch "$ZENSU_GH_DOWNLOAD_BASE/v$version/gh_${version}_checksums.txt" "$work/checksums.txt" \
  || die 1 "cannot read gh_${version}_checksums.txt"

node - "$ZENSU_GITHUB_IT_VERSIONS" "$version" "$work/checksums.txt" <<'NODE'
const fs = require('fs');
const [pinsFile, upstream, sumsFile] = process.argv.slice(2);
const VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const SUM = /^[0-9a-f]{64}$/;
const ASSET = { linux: ['linux', 'tar.gz'], darwin: ['macOS', 'zip'] };
const fail = (message) => {
  process.stderr.write(`github-drift: ${message}\n`);
  process.exit(1);
};
const numbers = (value) => String(value).split('.').map(Number);
const compare = (a, b) => {
  const x = numbers(a);
  const y = numbers(b);
  for (let i = 0; i < 3; i += 1) {
    if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
};
const asset = (version, platform) => {
  const [os, arch] = platform.split('_');
  if (!ASSET[os] || !/^(amd64|arm64)$/.test(arch || '')) fail(`the pin names an unknown platform ${platform}`);
  return `gh_${version}_${ASSET[os][0]}_${arch}.${ASSET[os][1]}`;
};

let pins = {};
try {
  pins = JSON.parse(fs.readFileSync(pinsFile, 'utf8')) || {};
} catch {
  fail(`${pinsFile} does not parse`);
}
const gh = Array.isArray(pins.gh) ? pins.gh : [];
if (!gh.length || !gh.every((entry) => entry && VERSION.test(String(entry.version)))) fail(`${pinsFile} pins no valid gh version`);
const newest = gh.reduce((a, b) => (compare(b.version, a.version) > 0 ? b : a));
const platforms = Object.keys(newest.sha256 || {});
if (!platforms.length || !platforms.every((platform) => SUM.test(String(newest.sha256[platform])))) {
  fail(`gh ${newest.version} pins no sha256 per platform`);
}

const order = compare(upstream, newest.version);
if (order < 0) fail(`the newest gh release, ${upstream}, is older than the pin ${newest.version}`);
const sums = new Map();
for (const line of fs.readFileSync(sumsFile, 'utf8').split(/\r?\n/)) {
  const match = /^([0-9a-f]{64}) [ *]?(\S+)$/.exec(line);
  if (match) sums.set(match[2], match[1]);
}
const upstreamSums = {};
for (const platform of platforms) {
  const name = asset(upstream, platform);
  if (!sums.has(name)) fail(`gh_${upstream}_checksums.txt names no ${name}`);
  upstreamSums[platform] = sums.get(name);
  if (order === 0 && upstreamSums[platform] !== newest.sha256[platform]) {
    fail(`gh_${upstream}_checksums.txt no longer lists the pinned sha256 for ${platform}`);
  }
}
if (order === 0) process.exit(0);

const entry = { version: upstream, role: newest.role, sha256: upstreamSums };
process.stdout.write(`${[
  `<!-- zensu-github-drift gh=${upstream} -->`,
  'Upstream published a gh release that the pins in `tests/integration/github/versions.v1.json` do not cover:',
  '',
  `- gh ${upstream} (newest pin: ${newest.version})`,
  '',
  'This check read release metadata only and ran no build. Pin it in a pull request: it runs the live matrix against the new pin.',
  '',
  `Replace the gh ${newest.version} entry; the sums come from the release's \`gh_${upstream}_checksums.txt\`:`,
  '',
  '```json',
  JSON.stringify(entry, null, 2),
  '```',
].join('\n')}\n`);
NODE
