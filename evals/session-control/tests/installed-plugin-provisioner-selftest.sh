#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
PROVISIONER="$EVAL_DIR/lib/provision-installed-plugin.sh"
CONTRACT="$EVAL_DIR/lib/installed-plugin-contract.js"
TEMPORARY="$(mktemp -d -t zensu-installed-plugin-selftest-XXXXXX)"
trap 'rm -rf "$TEMPORARY"' EXIT

SOURCE="$TEMPORARY/source"
mkdir -p "$SOURCE/.claude-plugin" "$SOURCE/hooks/lib" "$TEMPORARY/bin"
SOURCE="$(cd "$SOURCE" && pwd -P)"
cp "$ROOT/hooks/lib/session-control-core-v1.js" "$SOURCE/hooks/lib/session-control-core-v1.js"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$SOURCE/hooks/fixture.sh"
cat >"$SOURCE/.claude-plugin/plugin.json" <<'JSON'
{"name":"zensu","version":"9.8.7","hooks":"./hooks"}
JSON
cat >"$SOURCE/.claude-plugin/marketplace.json" <<'JSON'
{"name":"zensu","plugins":[{"name":"zensu","source":{"source":"github","repo":"MKITConsulting/zensu-claude-code","ref":"v9.8.7"},"version":"9.8.7"}]}
JSON
git -C "$SOURCE" init -q -b main 2>/dev/null || {
  git -C "$SOURCE" init -q
  git -C "$SOURCE" symbolic-ref HEAD refs/heads/main
}
git -C "$SOURCE" config user.name 'Installed Plugin Selftest'
git -C "$SOURCE" config user.email 'installed-plugin@zensu.invalid'
git -C "$SOURCE" add .
git -C "$SOURCE" -c commit.gpgsign=false commit -qm 'test: installed plugin fixture'
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"

cat >"$TEMPORARY/bin/claude" <<'STUB'
#!/bin/bash
set -euo pipefail
[ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] \
  || { echo 'credential leaked to plugin CLI' >&2; exit 90; }
if [ "${1:-}" = '--version' ]; then
  printf '%s (Claude Code stub)\n' "${STUB_CLI_VERSION:-2.1.211}"
  exit 0
fi
if [ "${1:-}" = plugin ] && [ "${2:-}" = marketplace ] && [ "${3:-}" = add ]; then
  [ "$(jq -r '.plugins[] | select(.name == "zensu") | .source' "$4/.claude-plugin/marketplace.json")" = './plugin' ] \
    || { echo 'marketplace fixture did not use a local plugin source' >&2; exit 93; }
  [ -d "$4/plugin/.git" ] || { echo 'marketplace fixture plugin is not a Git clone' >&2; exit 94; }
  [ "$(git -C "$4/plugin" rev-parse HEAD)" = "${STUB_EXPECTED_REVISION:?}" ] \
    || { echo 'marketplace fixture clone has the wrong HEAD' >&2; exit 95; }
  [ -z "$(git -C "$4/plugin" status --porcelain=v1 --untracked-files=all)" ] \
    || { echo 'marketplace fixture clone is dirty' >&2; exit 96; }
  [ "$(cd "$4/plugin" && pwd -P)" != "${STUB_ORIGINAL_SOURCE_ROOT:?}" ] \
    || { echo 'marketplace fixture aliases the original checkout' >&2; exit 97; }
  printf '%s' "$4" >"$HOME/marketplace-root"
  exit 0
fi
if [ "${1:-}" = plugin ] && [ "${2:-}" = install ]; then
  [ "${STUB_INSTALL_FAIL:-0}" != 1 ] || exit 91
  marketplace="$(cat "$HOME/marketplace-root")"
  source="$(cd "$marketplace/plugin" && pwd -P)"
  version="$(jq -r .version "$source/.claude-plugin/plugin.json")"
  install="$HOME/.claude/plugins/cache/zensu/zensu/$version"
  mkdir -p "$install" "$HOME/.claude/plugins"
  cp -R "$source/." "$install/"
  rm -rf "$install/.git"
  if [ "${STUB_MUTATE_FIXTURE:-0}" = 1 ]; then printf 'mutated\n' >"$source/cli-mutated"; fi
  [ "${STUB_MISSING_RUNTIME:-0}" != 1 ] || rm -f "$install/hooks/fixture.sh"
  if [ "${STUB_EXTRA_RUNTIME:-0}" = 1 ]; then printf 'unexpected\n' >"$install/hooks/unexpected.sh"; fi
  revision="$(git -C "$source" rev-parse HEAD)"
  if [ "${STUB_WRONG_SHA:-0}" = 1 ]; then
    case "$revision" in *0) revision="${revision%?}1" ;; *) revision="${revision%?}0" ;; esac
  fi
  registry_path="$install"
  if [ "${STUB_REGISTRY_PATH_MISMATCH:-0}" = 1 ]; then
    registry_path="$HOME/.claude/plugins/cache/zensu/zensu/other"
    mkdir -p "$registry_path"
  fi
  cat >"$HOME/.claude/settings.json" <<JSON
{"enabledPlugins":{"zensu@zensu":true}}
JSON
  cat >"$HOME/.claude/plugins/installed_plugins.json" <<JSON
{"version":2,"plugins":{"zensu@zensu":[{"scope":"user","installPath":"$registry_path","version":"$version","gitCommitSha":"$revision"}]}}
JSON
  exit 0
fi
if [ "${1:-}" = plugin ] && [ "${2:-}" = list ] && [ "${3:-}" = '--json' ]; then
  if [ "${STUB_MISSING_LIST_ENTRY:-0}" = 1 ]; then printf '[]\n'; exit 0; fi
  marketplace="$(cat "$HOME/marketplace-root")"
  source="$(cd "$marketplace/plugin" && pwd -P)"
  version="$(jq -r .version "$source/.claude-plugin/plugin.json")"
  install="$HOME/.claude/plugins/cache/zensu/zensu/$version"
  if [ "${STUB_WRONG_LIST_PATH:-0}" = 1 ]; then
    install="$HOME/not-the-plugin-cache"
    mkdir -p "$install"
  fi
  entry="$(jq -cn --arg path "$install" --arg version "$version" \
    '{id:"zensu@zensu",version:$version,scope:"user",enabled:true,installPath:$path}')"
  if [ "${STUB_AMBIGUOUS_LIST:-0}" = 1 ]; then jq -cn --argjson entry "$entry" '[$entry,$entry]'; else jq -cn --argjson entry "$entry" '[$entry]'; fi
  exit 0
fi
exit 92
STUB
chmod +x "$TEMPORARY/bin/claude"

run_success() {
  local state="$TEMPORARY/state-success"
  local out="$TEMPORARY/success.out" err="$TEMPORARY/success.err"
  mkdir "$state"
  if ! ANTHROPIC_API_KEY='zensu-secret-allow-not-a-real-key' CLAUDE_CODE_OAUTH_TOKEN='zensu-secret-allow-not-a-real-token' \
    STUB_EXPECTED_REVISION="$REVISION" STUB_ORIGINAL_SOURCE_ROOT="$SOURCE" \
    PATH="$TEMPORARY/bin:$PATH" bash "$PROVISIONER" "$SOURCE" "$state" "$REVISION" >"$out" 2>"$err"; then
    cat "$err" >&2
    exit 1
  fi
  local manifest
  manifest="$(cat "$out")"
  [ -f "$manifest" ] && [ -d "$state/home" ]
  local installed home
  installed="$(jq -r .installed_plugin_root "$manifest")"
  home="$(jq -r .isolated_home "$manifest")"
  [ "$(jq -r .source_root "$manifest")" = "$SOURCE" ]
  [ "$(jq -r '.plugins[0].source' "$state/marketplace-fixture/.claude-plugin/marketplace.json")" = './plugin' ]
  [ "$(git -C "$state/marketplace-fixture/plugin" rev-parse HEAD)" = "$REVISION" ]
  [ -z "$(git -C "$state/marketplace-fixture/plugin" status --porcelain=v1 --untracked-files=all)" ]
  node "$CONTRACT" verify "$manifest" "$SOURCE" "$installed" "$home" "$REVISION" 2.1.211 >/dev/null
  ! grep -q 'not-a-real' "$out" "$err"
  rm -rf "$state"
  [ ! -e "$home" ]
}

run_failure() {
  local name="$1" variable="$2"
  local state="$TEMPORARY/state-$name"
  local out="$TEMPORARY/$name.out" err="$TEMPORARY/$name.err"
  mkdir "$state"
  if env PATH="$TEMPORARY/bin:$PATH" STUB_EXPECTED_REVISION="$REVISION" \
    STUB_ORIGINAL_SOURCE_ROOT="$SOURCE" "$variable"=1 \
    bash "$PROVISIONER" "$SOURCE" "$state" "$REVISION" >"$out" 2>"$err"; then
    echo "provisioner accepted negative case: $name" >&2
    exit 1
  fi
  [ ! -e "$state" ] || { echo "provisioner left isolated cache after failure: $name" >&2; exit 1; }
  ! grep -q 'not-a-real' "$out" "$err"
}

run_success
run_failure wrong-list-path STUB_WRONG_LIST_PATH
run_failure ambiguous-list STUB_AMBIGUOUS_LIST
run_failure missing-list-entry STUB_MISSING_LIST_ENTRY
run_failure registry-path-mismatch STUB_REGISTRY_PATH_MISMATCH
run_failure wrong-sha STUB_WRONG_SHA
run_failure missing-runtime STUB_MISSING_RUNTIME
run_failure extra-runtime STUB_EXTRA_RUNTIME
run_failure mutated-fixture STUB_MUTATE_FIXTURE
run_failure install-failure STUB_INSTALL_FAIL

printf 'dirty\n' >"$SOURCE/untracked-runtime"
DIRTY_STATE="$TEMPORARY/state-dirty-source"
mkdir "$DIRTY_STATE"
if PATH="$TEMPORARY/bin:$PATH" STUB_EXPECTED_REVISION="$REVISION" \
  STUB_ORIGINAL_SOURCE_ROOT="$SOURCE" \
  bash "$PROVISIONER" "$SOURCE" "$DIRTY_STATE" "$REVISION" >/dev/null 2>&1; then
  echo 'provisioner accepted a dirty source checkout' >&2; exit 1
fi
[ -d "$DIRTY_STATE" ] && [ -z "$(find "$DIRTY_STATE" -mindepth 1 -print -quit)" ]
rm -f "$SOURCE/untracked-runtime"
rm -rf "$DIRTY_STATE"

CLI_STATE="$TEMPORARY/state-wrong-cli"
mkdir "$CLI_STATE"
if PATH="$TEMPORARY/bin:$PATH" STUB_CLI_VERSION=2.1.212 \
  STUB_EXPECTED_REVISION="$REVISION" STUB_ORIGINAL_SOURCE_ROOT="$SOURCE" \
  bash "$PROVISIONER" "$SOURCE" "$CLI_STATE" "$REVISION" >/dev/null 2>&1; then
  echo 'provisioner accepted an unpinned Claude CLI' >&2; exit 1
fi
[ ! -e "$CLI_STATE" ]

printf 'installed-plugin-provisioner-selftest.sh: PASS\n'
