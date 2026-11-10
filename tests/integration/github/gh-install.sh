#!/bin/bash
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

die() {
  local code="$1"
  shift
  printf 'gh-install: %s\n' "$*" >&2
  exit "$code"
}

[ $# -eq 2 ] || die 2 'usage: gh-install.sh <version> <dest-dir>'
version="$1"
dest="$2"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die 2 "invalid gh version '$version'"

case "$(uname -s)" in
  Linux) os=linux; asset_os=linux; ext=tar.gz ;;
  Darwin) os=darwin; asset_os=macOS; ext=zip ;;
  *) die 2 "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die 2 "unsupported architecture $(uname -m)" ;;
esac
platform="${os}_${arch}"

stem="gh_${version}_${asset_os}_${arch}"
asset="$stem.$ext"
expected="$(github_it_pin sha256 "$version" "$platform")"
[ -n "$expected" ] || die 2 "gh $version has no pinned sha256 for $platform in $ZENSU_GITHUB_IT_VERSIONS"

target="$dest/gh"
stamp="$dest/.gh-sha256"
if [ -x "$target" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$expected" ]; then
  printf '%s\n' "$target"
  exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/gh-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl -fsSL --max-time 600 -o "$work/$asset" "$ZENSU_GH_DOWNLOAD_BASE/v$version/$asset" \
  || die 1 "download failed: $ZENSU_GH_DOWNLOAD_BASE/v$version/$asset"
actual="$(F="$work/$asset" node -e '
  const hash = require("crypto").createHash("sha256");
  hash.update(require("fs").readFileSync(process.env.F));
  process.stdout.write(hash.digest("hex"));
')"
[ "$actual" = "$expected" ] || die 1 "sha256 mismatch for $asset: expected $expected, got $actual"

mkdir "$work/unpacked"
case "$ext" in
  tar.gz) tar -xzf "$work/$asset" -C "$work/unpacked" "$stem/bin/gh" >/dev/null 2>&1 || die 1 "$asset holds no $stem/bin/gh" ;;
  zip) unzip -q "$work/$asset" "$stem/bin/gh" -d "$work/unpacked" >/dev/null 2>&1 || die 1 "$asset holds no $stem/bin/gh" ;;
esac
[ -f "$work/unpacked/$stem/bin/gh" ] || die 1 "$asset holds no $stem/bin/gh"

mkdir -p "$dest"
rm -f "$stamp"
cp "$work/unpacked/$stem/bin/gh" "$target.partial"
chmod 755 "$target.partial"
mv -f "$target.partial" "$target"
mkdir "$work/config"
reported="$(GH_CONFIG_DIR="$work/config" GH_NO_UPDATE_NOTIFIER=1 "$target" --version 2>/dev/null || true)"
case "$reported" in
  "gh version $version "*) ;;
  *) die 1 "$target does not report version $version" ;;
esac
printf '%s\n' "$expected" > "$stamp"
printf '%s\n' "$target"
