#!/bin/bash

ZENSU_GITHUB_IT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZENSU_GITHUB_IT_VERSIONS="${ZENSU_GITHUB_IT_VERSIONS:-$ZENSU_GITHUB_IT_HERE/versions.v1.json}"
ZENSU_GITHUB_IT_CACHE="${ZENSU_GITHUB_IT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zensu-github-it}"
ZENSU_GITHUB_IT_STATE="${ZENSU_GITHUB_IT_STATE:-$ZENSU_GITHUB_IT_CACHE/state}"
ZENSU_GITHUB_IT_CONFIG="${ZENSU_GITHUB_IT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zensu-github-it}"
ZENSU_GITHUB_IT_API="${ZENSU_GITHUB_IT_API:-https://api.github.com}"
ZENSU_GH_DOWNLOAD_BASE="${ZENSU_GH_DOWNLOAD_BASE:-https://github.com/cli/cli/releases/download}"
export ZENSU_GITHUB_IT_VERSIONS ZENSU_GITHUB_IT_CACHE ZENSU_GITHUB_IT_STATE ZENSU_GITHUB_IT_CONFIG ZENSU_GITHUB_IT_API

github_it_pin() {
  PIN_KEY="$1" PIN_VERSION="${2:-}" PIN_PLATFORM="${3:-}" node -e '
    const manifest = JSON.parse(require("fs").readFileSync(process.env.ZENSU_GITHUB_IT_VERSIONS, "utf8"));
    const gh = Array.isArray(manifest.gh) ? manifest.gh : [];
    if (process.env.PIN_KEY === "versions") {
      process.stdout.write(gh.map((item) => item.version).join(" "));
    } else if (process.env.PIN_KEY === "sha256") {
      const entry = gh.find((item) => item.version === process.env.PIN_VERSION);
      const sum = entry && entry.sha256 && entry.sha256[process.env.PIN_PLATFORM];
      if (typeof sum === "string" && /^[0-9a-f]{64}$/.test(sum)) process.stdout.write(sum);
    } else {
      process.exit(2);
    }
  '
}
