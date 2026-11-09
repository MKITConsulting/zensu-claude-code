#!/bin/bash
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

die() {
  local code="$1"
  shift
  printf 'glab-install: %s\n' "$*" >&2
  exit "$code"
}

[ $# -eq 2 ] || die 2 'usage: glab-install.sh <version> <dest-dir>'
version="$1"
dest="$2"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die 2 "invalid glab version '$version'"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) die 2 "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die 2 "unsupported architecture $(uname -m)" ;;
esac
platform="${os}_${arch}"

asset="glab_${version}_${platform}.tar.gz"
release="$ZENSU_GLAB_DOWNLOAD_BASE/v$version/downloads"
expected="$(gitlab_it_pin sha256 "$version" "$platform")"
[ -n "$expected" ] || die 2 "glab $version has no pinned sha256 for $platform in $ZENSU_GITLAB_IT_VERSIONS"

target="$dest/glab"
stamp="$dest/.glab-sha256"
if [ -x "$target" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$expected" ]; then
  printf '%s\n' "$target"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/glab-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl -fsSL --max-time 600 -o "$work/$asset" "$release/$asset" || die 1 "download failed: $release/$asset"
actual="$(F="$work/$asset" node -e '
  const hash = require("crypto").createHash("sha256");
  hash.update(require("fs").readFileSync(process.env.F));
  process.stdout.write(hash.digest("hex"));
')"
[ "$actual" = "$expected" ] || die 1 "sha256 mismatch for $asset: expected $expected, got $actual"

mkdir "$work/unpacked"
tar -xzf "$work/$asset" -C "$work/unpacked" bin/glab || die 1 "$asset holds no bin/glab"
[ -f "$work/unpacked/bin/glab" ] || die 1 "$asset holds no bin/glab"

mkdir -p "$dest"
rm -f "$stamp"
cp "$work/unpacked/bin/glab" "$target.partial"
chmod 755 "$target.partial"
mv -f "$target.partial" "$target"
"$target" --version 2>/dev/null | grep -Fq "$version" || die 1 "$target does not report version $version"
printf '%s\n' "$expected" > "$stamp"
printf '%s\n' "$target"
