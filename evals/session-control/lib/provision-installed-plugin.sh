#!/bin/bash
set -euo pipefail

EXPECTED_CLI_VERSION='2.1.211'
PLUGIN_ID='zensu@zensu'
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CONTRACT="$SCRIPT_DIR/installed-plugin-contract.js"
FIXTURE_GENERATOR="$SCRIPT_DIR/create-local-marketplace-fixture.js"

die() {
  printf 'installed plugin provisioner: %s\n' "$1" >&2
  exit "${2:-1}"
}

[ "$#" -eq 3 ] || die 'usage: provision-installed-plugin.sh SOURCE_ROOT EMPTY_STATE_DIR EXPECTED_REVISION' 64
for cli in claude git jq node; do
  command -v "$cli" >/dev/null 2>&1 || die "required CLI '$cli' is unavailable" 127
done
[ -f "$CONTRACT" ] || die 'installed-plugin contract verifier is unavailable' 127
[ -f "$FIXTURE_GENERATOR" ] || die 'local marketplace fixture generator is unavailable' 127

SOURCE_INPUT="$1"
STATE_INPUT="$2"
EXPECTED_REVISION="$3"
[ -d "$SOURCE_INPUT" ] && [ ! -L "$SOURCE_INPUT" ] || die 'source root must be a real directory'
[ -d "$STATE_INPUT" ] && [ ! -L "$STATE_INPUT" ] || die 'state root must be a real directory'
SOURCE_ROOT="$(cd "$SOURCE_INPUT" && pwd -P)"
STATE_ROOT="$(cd "$STATE_INPUT" && pwd -P)"
case "$EXPECTED_REVISION" in
  ''|*[!0-9a-f]*) die 'expected source revision is malformed' ;;
esac
[ "${#EXPECTED_REVISION}" -ge 40 ] && [ "${#EXPECTED_REVISION}" -le 64 ] \
  || die 'expected source revision is malformed'
[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null)" = "$EXPECTED_REVISION" ] \
  || die 'source checkout HEAD does not match the exact expected revision'
[ -z "$(git -C "$SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" ] \
  || die 'source checkout must be clean before installed-plugin provisioning'
[ -z "$(find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ] \
  || die 'state root must be empty'

SUCCEEDED=0
cleanup_failure() {
  if [ "$SUCCEEDED" -ne 1 ]; then rm -rf "$STATE_ROOT"; fi
}
trap cleanup_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

ISOLATED_HOME="$STATE_ROOT/home"
XDG_CONFIG_HOME="$ISOLATED_HOME/.config"
XDG_CACHE_HOME="$ISOLATED_HOME/.cache"
XDG_DATA_HOME="$ISOLATED_HOME/.local/share"
mkdir -p "$ISOLATED_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
chmod 700 "$STATE_ROOT" "$ISOLATED_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

EXPECTED_MARKETPLACE_ROOT="$STATE_ROOT/marketplace-fixture"
MARKETPLACE_ROOT="$(node "$FIXTURE_GENERATOR" \
  "$SOURCE_ROOT" "$EXPECTED_MARKETPLACE_ROOT" "$EXPECTED_REVISION")" \
  || die 'exact-checkout local marketplace fixture creation failed'
[ -n "$MARKETPLACE_ROOT" ] || die 'local marketplace fixture resolved to an unexpected root'
case "$MARKETPLACE_ROOT" in
  *$'\r'*|*$'\n'*) die 'local marketplace fixture resolved to an unexpected root' ;;
esac
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) MARKETPLACE_ROOT="$(cygpath -u "$MARKETPLACE_ROOT")" ;;
esac
[ -d "$MARKETPLACE_ROOT" ] && [ ! -L "$MARKETPLACE_ROOT" ] \
  || die 'local marketplace fixture resolved to an unexpected root'
MARKETPLACE_ROOT="$(cd -P -- "$MARKETPLACE_ROOT" && pwd -P)" \
  || die 'local marketplace fixture resolved to an unexpected root'
EXPECTED_MARKETPLACE_ROOT="$(cd -P -- "$EXPECTED_MARKETPLACE_ROOT" && pwd -P)" \
  || die 'local marketplace fixture resolved to an unexpected root'
[ "$MARKETPLACE_ROOT" = "$EXPECTED_MARKETPLACE_ROOT" ] \
  || die 'local marketplace fixture resolved to an unexpected root'

LOG_FILE="$STATE_ROOT/claude-plugin-cli.log"
LIST_FILE="$STATE_ROOT/plugin-list.json"
MANIFEST_FILE="$STATE_ROOT/installed-plugin.json"
: >"$LOG_FILE"
chmod 600 "$LOG_FILE"

claude_isolated() {
  env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CONFIG_DIR \
    HOME="$ISOLATED_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude "$@"
}

RAW_VERSION="$(claude_isolated --version 2>>"$LOG_FILE")" \
  || die 'cannot resolve Claude CLI version'
CLI_VERSION="$(printf '%s\n' "$RAW_VERSION" | sed -nE '1s/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
[ "$CLI_VERSION" = "$EXPECTED_CLI_VERSION" ] \
  || die "Claude CLI must be exactly $EXPECTED_CLI_VERSION"

claude_isolated plugin marketplace add "$MARKETPLACE_ROOT" >>"$LOG_FILE" 2>&1 \
  || die 'Claude marketplace registration failed'
claude_isolated plugin install "$PLUGIN_ID" --scope user >>"$LOG_FILE" 2>&1 \
  || die 'Claude plugin installation failed'
claude_isolated plugin list --json >"$LIST_FILE" 2>>"$LOG_FILE" \
  || die 'Claude plugin list failed'
chmod 600 "$LIST_FILE"
[ "$(git -C "$MARKETPLACE_ROOT/plugin" rev-parse HEAD 2>/dev/null)" = "$EXPECTED_REVISION" ] \
  && [ -z "$(git -C "$MARKETPLACE_ROOT/plugin" status --porcelain=v1 --untracked-files=all)" ] \
  || die 'Claude plugin commands changed the exact-checkout marketplace fixture'
[ "$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null)" = "$EXPECTED_REVISION" ] \
  && [ -z "$(git -C "$SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)" ] \
  || die 'source checkout changed during installed-plugin provisioning'

node "$CONTRACT" resolve "$LIST_FILE" "$SOURCE_ROOT" "$ISOLATED_HOME" \
  "$EXPECTED_REVISION" "$CLI_VERSION" >"$MANIFEST_FILE" \
  || die 'installed plugin failed provenance or runtime verification'
chmod 400 "$MANIFEST_FILE"
rm -f "$LOG_FILE" "$LIST_FILE"

SUCCEEDED=1
trap - EXIT
printf '%s\n' "$MANIFEST_FILE"
