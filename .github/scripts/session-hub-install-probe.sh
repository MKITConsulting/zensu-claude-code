#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"

TOOL="${1:-}"
WANT="$(bash .github/scripts/session-hub-claude-code-pin.sh "$TOOL")" || {
  echo "::error::session-hub-install-probe.sh needs a Claude Code tool directory with an exact pin, got: ${TOOL:-<none>}"
  exit 1
}

PROBE="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/session-hub-probe-XXXXXX")"
PROBE="$(cd "$PROBE" && pwd -P)"
trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/home" "$PROBE/config" "$PROBE/market/.claude-plugin" "$PROBE/catalog/.claude-plugin"

isolated() {
  env -i PATH="$PATH" HOME="$PROBE/home" CLAUDE_CONFIG_DIR="$PROBE/config" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 TERM=dumb "$@" < /dev/null
}

FOUND="$(isolated claude --version)"
if [ "$FOUND" != "$WANT (Claude Code)" ]; then
  echo "::error::the install probe needs Claude Code $WANT, found: $FOUND"
  exit 1
fi
isolated claude plugin validate "$REPO_ROOT"
isolated claude plugin validate "$REPO_ROOT/plugins/session-hub"
jq '.name = "zensu-catalog-probe"' .claude-plugin/marketplace.json > "$PROBE/catalog/.claude-plugin/marketplace.json"
if ! isolated claude plugin marketplace add "$PROBE/catalog"; then
  echo "::error::Claude Code $WANT refuses the unfiltered marketplace catalog as a local marketplace"
  exit 1
fi

COMMIT="$(isolated git -C "$REPO_ROOT" rev-parse HEAD)"
VER="$(jq -r .version plugins/session-hub/.claude-plugin/plugin.json)"
TAG="session-hub--v$VER"
HUB_ENTRY='[.plugins[] | select(.name == "session-hub")] | select(length == 1) | .[0]'
if [ "$(jq -r "$HUB_ENTRY.source.ref" .claude-plugin/marketplace.json)" != "$TAG" ]; then
  echo "::error::the session-hub marketplace entry does not point at $TAG"
  exit 1
fi

isolated git clone --quiet --no-local --no-tags "$REPO_ROOT" "$PROBE/work"
isolated git -C "$PROBE/work" checkout --quiet --detach "$COMMIT"
isolated git -C "$PROBE/work" config user.name probe
isolated git -C "$PROBE/work" config user.email probe@localhost
(cd "$PROBE/work" && isolated claude plugin tag plugins/session-hub)
if [ "$(isolated git -C "$PROBE/work" cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" != tag ] \
  || [ "$(isolated git -C "$PROBE/work" rev-list -n 1 "refs/tags/$TAG")" != "$COMMIT" ]; then
  echo "::error::claude plugin tag plugins/session-hub did not create the annotated tag $TAG at $COMMIT"
  exit 1
fi
if [ "$(isolated git -C "$PROBE/work" cat-file tag "refs/tags/$TAG" | sed '1,/^$/d')" != "session-hub $VER" ]; then
  echo "::error::claude plugin tag plugins/session-hub wrote a tag message other than session-hub $VER, the message the publish job of release-session-hub.yml requires"
  exit 1
fi
isolated git clone --quiet --bare --no-local "$PROBE/work" "$PROBE/remote.git"
jq --arg url "file://$PROBE/remote.git" \
  '.name = "zensu-probe" | .plugins = [.plugins[] | select(.name == "session-hub") | .source.url = $url]' \
  .claude-plugin/marketplace.json > "$PROBE/market/.claude-plugin/marketplace.json"

isolated claude plugin marketplace add "$PROBE/market"
isolated claude plugin install session-hub@zensu-probe
INSTALLED="$PROBE/config/plugins/cache/zensu-probe/session-hub/$VER"
if [ ! -d "$INSTALLED" ]; then
  echo "::error::claude plugin install left no session-hub $VER under the probe's plugin cache"
  find "$PROBE/config/plugins" -maxdepth 4 -type d | sed "s|^$PROBE/||"
  exit 1
fi

(cd "$INSTALLED" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) > "$PROBE/installed-names.txt"
(cd "$INSTALLED" && tr '\n' '\0' < "$PROBE/installed-names.txt" \
  | xargs -0 env -i PATH="$PATH" HOME="$PROBE/home" GIT_CONFIG_NOSYSTEM=1 git hash-object --no-filters --) > "$PROBE/installed-ids.txt"
paste -d ' ' "$PROBE/installed-ids.txt" "$PROBE/installed-names.txt" > "$PROBE/installed.txt"
isolated git -C "$REPO_ROOT" ls-tree -r "$COMMIT" -- plugins/session-hub \
  | awk -F '\t' '{ split($1, f, " "); sub(/^plugins\/session-hub\//, "", $2); print f[3] " " $2 }' \
  | LC_ALL=C sort -k 2 > "$PROBE/tree.txt"
if ! diff -u "$PROBE/tree.txt" "$PROBE/installed.txt"; then
  echo "::error::the installed session-hub $VER differs from plugins/session-hub at $COMMIT"
  exit 1
fi

TOKEN="$(node -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')"
SESSION="$(node -e 'process.stdout.write(require("crypto").randomUUID())')"
PAYLOAD="$(jq -cn --arg s "$SESSION" --arg cwd "$PROBE/home" --arg p "/session-hub:session-trail takeover $SESSION --all --receipt $TOKEN" \
  '{session_id: $s, cwd: $cwd, hook_event_name: "UserPromptSubmit", prompt: $p}')"
HOOK_OUT="$(printf '%s' "$PAYLOAD" | env -i PATH="$PATH" HOME="$PROBE/home" CLAUDE_CONFIG_DIR="$PROBE/config" \
  CLAUDE_PLUGIN_ROOT="$INSTALLED" node "$INSTALLED/hooks/lib/session-hub-receipt-v1.mjs")"
RECEIPT="$PROBE/config/zensu/session-hub/v1/receipts/$TOKEN.json"
if [ -n "$HOOK_OUT" ] || [ ! -f "$RECEIPT" ]; then
  echo "::error::the installed receipt entry did not land exactly one silent receipt for the takeover command"
  exit 1
fi
MODE="$(node -e 'process.stdout.write((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$RECEIPT")"
if [ "$MODE" != "600" ] || [ "$(jq -r '"\(.token) \(.plugin)"' "$RECEIPT")" != "$TOKEN $VER" ]; then
  echo "::error::the receipt the installed entry landed is not a 0600 receipt for its token from session-hub $VER"
  exit 1
fi

isolated node "$INSTALLED/skills/session-trail/scripts/trail.mjs" list --json > "$PROBE/list.json"
jq -e . "$PROBE/list.json" > /dev/null

echo "Claude Code $WANT validated both catalogs, added the unfiltered one, tagged a clone through claude plugin tag and installed session-hub $VER from a git-subdir entry; the installed copy matches the committed tree by object id, lands a receipt and runs /session-hub:session-trail."
