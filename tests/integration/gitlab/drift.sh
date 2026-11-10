#!/bin/bash
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
RELEASES="${ZENSU_GLAB_RELEASES_API:-https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases}"
TAGS="${ZENSU_GITLAB_IT_TAGS_URL:-https://hub.docker.com/v2/namespaces/gitlab/repositories/gitlab-ce/tags?page_size=100}"

die() {
  local code="$1"
  shift
  printf 'gitlab-drift: %s\n' "$*" >&2
  exit "$code"
}

command -v curl >/dev/null 2>&1 || die 2 'curl is not installed'
command -v node >/dev/null 2>&1 || die 2 'node is not installed'

work="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-drift.XXXXXX")"
trap 'rm -rf "$work"' EXIT

curl -fsSL --max-time 60 -o "$work/release.json" "$RELEASES/permalink/latest" || die 1 'cannot read the newest glab release'
version="$(node -e '
  let tag = "";
  try {
    tag = String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).tag_name || "");
  } catch {
    process.exit(1);
  }
  if (!/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(tag)) process.exit(1);
  process.stdout.write(tag.slice(1));
' "$work/release.json")" || die 1 'the newest glab release carries no vX.Y.Z tag'
curl -fsSL --max-time 60 -o "$work/checksums.txt" "$ZENSU_GLAB_DOWNLOAD_BASE/v$version/downloads/checksums.txt" \
  || die 1 "cannot read checksums.txt of glab $version"
curl -fsSL --max-time 60 -o "$work/tags.json" "$TAGS" || die 1 'cannot read the GitLab CE tag listing'

node - "$ZENSU_GITLAB_IT_VERSIONS" "$version" "$work/checksums.txt" "$work/tags.json" <<'NODE'
const fs = require('fs');
const [pinsFile, upstreamGlab, sumsFile, tagsFile] = process.argv.slice(2);
const VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const RELEASE_TAG = /^[0-9]+\.[0-9]+\.[0-9]+-ce\.0$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const SUM = /^[0-9a-f]{64}$/;
const fail = (message) => {
  process.stderr.write(`gitlab-drift: ${message}\n`);
  process.exit(1);
};
const readJson = (file) => {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
};
const numbers = (value) => String(value).split(/[.-]/).slice(0, 3).map(Number);
const compare = (a, b) => {
  const x = numbers(a);
  const y = numbers(b);
  for (let i = 0; i < 3; i += 1) {
    if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
  }
  return 0;
};

const pins = readJson(pinsFile) || {};
const glab = Array.isArray(pins.glab) ? pins.glab : [];
const image = pins.gitlab || {};
if (!glab.length || !glab.every((entry) => entry && VERSION.test(String(entry.version)))) {
  fail(`${pinsFile} pins no valid glab version`);
}
if (image.image !== 'gitlab/gitlab-ce' || !RELEASE_TAG.test(String(image.tag)) || !DIGEST.test(String(image.digest))) {
  fail(`${pinsFile} pins no gitlab/gitlab-ce release tag with a digest`);
}
const newest = glab.reduce((a, b) => (compare(b.version, a.version) > 0 ? b : a));
const platforms = Object.keys(newest.sha256 || {});
if (!platforms.length || !platforms.every((platform) => SUM.test(String(newest.sha256[platform])))) {
  fail(`glab ${newest.version} pins no sha256 per platform`);
}

const glabOrder = compare(upstreamGlab, newest.version);
if (glabOrder < 0) fail(`the newest glab release, ${upstreamGlab}, is older than the pin ${newest.version}`);
const sums = new Map();
for (const line of fs.readFileSync(sumsFile, 'utf8').split(/\r?\n/)) {
  const match = /^([0-9a-f]{64}) [ *]?(\S+)$/.exec(line);
  if (match) sums.set(match[2], match[1]);
}
const upstreamSums = {};
for (const platform of platforms) {
  const asset = `glab_${upstreamGlab}_${platform}.tar.gz`;
  if (!sums.has(asset)) fail(`checksums.txt of glab ${upstreamGlab} names no ${asset}`);
  upstreamSums[platform] = sums.get(asset);
  if (glabOrder === 0 && upstreamSums[platform] !== newest.sha256[platform]) {
    fail(`checksums.txt of glab ${upstreamGlab} no longer lists the pinned sha256 for ${platform}`);
  }
}
const glabEntry = glabOrder > 0 ? { version: upstreamGlab, role: newest.role, sha256: upstreamSums } : null;

const listing = readJson(tagsFile) || {};
const releases = (Array.isArray(listing.results) ? listing.results : [])
  .filter((entry) => entry && RELEASE_TAG.test(String(entry.name)));
if (!releases.length) fail('the GitLab CE tag listing names no X.Y.Z-ce.0 release');
const top = releases.reduce((a, b) => (compare(b.name, a.name) > 0 ? b : a));
if (!DIGEST.test(String(top.digest))) fail(`GitLab CE ${top.name} carries no sha256 digest`);
const tagOrder = compare(top.name, image.tag);
if (tagOrder < 0) {
  fail(`the newest GitLab CE release on the first page of the tag listing, ${top.name}, is older than the pin ${image.tag}`);
}
const gitlabEntry = tagOrder > 0 || top.digest !== image.digest
  ? { image: image.image, tag: top.name, digest: top.digest }
  : null;

if (!glabEntry && !gitlabEntry) process.exit(0);
const marker = ['<!-- zensu-gitlab-drift'];
const bullets = [];
const blocks = [];
if (glabEntry) {
  marker.push(`glab=${glabEntry.version}`);
  bullets.push(`- glab ${glabEntry.version} (newest pin: ${newest.version})`);
  blocks.push('', `Replace the glab ${newest.version} entry; the sums come from the release's \`checksums.txt\`:`, '',
    '```json', JSON.stringify(glabEntry, null, 2), '```');
}
if (gitlabEntry) {
  marker.push(`gitlab=${gitlabEntry.tag}@${gitlabEntry.digest}`);
  bullets.push(`- GitLab CE ${gitlabEntry.tag} at ${gitlabEntry.digest} (pin: ${image.tag} at ${image.digest})`);
  blocks.push('', 'Replace `gitlab`; the digest comes from the Docker Hub tag listing:', '',
    '```json', JSON.stringify(gitlabEntry, null, 2), '```');
}
marker.push('-->');
process.stdout.write(`${[
  marker.join(' '),
  'Upstream published releases that the pins in `tests/integration/gitlab/versions.v1.json` do not cover:',
  '',
  ...bullets,
  '',
  'This check read release metadata only and ran no build. Pin them in a pull request: it runs the live matrix against the new pins.',
  ...blocks,
].join('\n')}\n`);
NODE
