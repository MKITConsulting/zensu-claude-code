#!/bin/bash

ZENSU_GITLAB_IT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZENSU_GITLAB_IT_VERSIONS="${ZENSU_GITLAB_IT_VERSIONS:-$ZENSU_GITLAB_IT_HERE/versions.v1.json}"
ZENSU_GITLAB_IT_CACHE="${ZENSU_GITLAB_IT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/zensu-gitlab-it}"
ZENSU_GITLAB_IT_STATE="${ZENSU_GITLAB_IT_STATE:-$ZENSU_GITLAB_IT_CACHE/state}"
ZENSU_GITLAB_IT_CONTAINER="${ZENSU_GITLAB_IT_CONTAINER:-zensu-gitlab-it}"
ZENSU_GITLAB_IT_LABEL=dev.zensu.gitlab-it
ZENSU_GLAB_DOWNLOAD_BASE="${ZENSU_GLAB_DOWNLOAD_BASE:-https://gitlab.com/gitlab-org/cli/-/releases}"
export ZENSU_GITLAB_IT_VERSIONS ZENSU_GITLAB_IT_CACHE ZENSU_GITLAB_IT_STATE ZENSU_GITLAB_IT_CONTAINER

gitlab_it_pin() {
  PIN_KEY="$1" PIN_VERSION="${2:-}" PIN_PLATFORM="${3:-}" node -e '
    const manifest = JSON.parse(require("fs").readFileSync(process.env.ZENSU_GITLAB_IT_VERSIONS, "utf8"));
    const glab = Array.isArray(manifest.glab) ? manifest.glab : [];
    if (process.env.PIN_KEY === "image") {
      const g = manifest.gitlab || {};
      if (!/^sha256:[0-9a-f]{64}$/.test(g.digest || "") || !g.image || !g.tag) process.exit(1);
      process.stdout.write(`${g.image}:${g.tag}@${g.digest}`);
    } else if (process.env.PIN_KEY === "versions") {
      process.stdout.write(glab.map((item) => item.version).join(" "));
    } else if (process.env.PIN_KEY === "sha256") {
      const entry = glab.find((item) => item.version === process.env.PIN_VERSION);
      const sum = entry && entry.sha256 && entry.sha256[process.env.PIN_PLATFORM];
      if (typeof sum === "string" && /^[0-9a-f]{64}$/.test(sum)) process.stdout.write(sum);
    } else {
      process.exit(2);
    }
  '
}
