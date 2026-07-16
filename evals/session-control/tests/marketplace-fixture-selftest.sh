#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
GENERATOR="$EVAL_DIR/lib/create-local-marketplace-fixture.js"
TEMPORARY="$(mktemp -d -t zensu-marketplace-fixture-selftest-XXXXXX)"
trap 'rm -rf "$TEMPORARY"' EXIT

SOURCE="$TEMPORARY/source"
mkdir -p "$SOURCE/.claude-plugin" "$SOURCE/hooks" "$TEMPORARY/targets"
cat >"$SOURCE/.claude-plugin/plugin.json" <<'JSON'
{"name":"zensu","version":"9.8.7"}
JSON
cat >"$SOURCE/.claude-plugin/marketplace.json" <<'JSON'
{"name":"zensu","plugins":[{"name":"zensu","source":{"source":"github","repo":"MKITConsulting/zensu-claude-code","ref":"v9.8.7"},"version":"9.8.7"}]}
JSON
printf '#!/bin/bash\nexit 0\n' >"$SOURCE/hooks/example.sh"

git -C "$SOURCE" init -q -b main 2>/dev/null || {
  git -C "$SOURCE" init -q
  git -C "$SOURCE" symbolic-ref HEAD refs/heads/main
}
git -C "$SOURCE" config user.name 'Marketplace Fixture Selftest'
git -C "$SOURCE" config user.email 'marketplace-fixture@zensu.invalid'
git -C "$SOURCE" add .
git -C "$SOURCE" -c commit.gpgsign=false commit -qm 'test: exact marketplace source'
REVISION="$(git -C "$SOURCE" rev-parse HEAD)"

TARGET="$(cd "$TEMPORARY/targets" && pwd -P)/marketplace"
RESULT="$(node "$GENERATOR" "$SOURCE" "$TARGET" "$REVISION")"
[ "$RESULT" = "$TARGET" ]
[ "$(jq -r '.plugins[0].source' "$TARGET/.claude-plugin/marketplace.json")" = './plugin' ]
[ "$(jq -r '.plugins[0].source.source' "$TARGET/plugin/.claude-plugin/marketplace.json")" = github ]
[ "$(jq -r '.plugins[0].source.ref' "$TARGET/plugin/.claude-plugin/marketplace.json")" = v9.8.7 ]
[ "$(git -C "$TARGET/plugin" rev-parse HEAD)" = "$REVISION" ]
[ -z "$(git -C "$TARGET/plugin" status --porcelain=v1 --untracked-files=all)" ]
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$REVISION" ]
[ -z "$(git -C "$SOURCE" status --porcelain=v1 --untracked-files=all)" ]
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) printf '%s\n' 'marketplace fixture: SKIP POSIX 0700 assertion on Windows' ;;
  *) [ "$(stat -f '%Lp' "$TARGET" 2>/dev/null || stat -c '%a' "$TARGET")" = 700 ] ;;
esac

WRONG_TARGET="$TEMPORARY/targets/wrong-revision"
WRONG_REVISION="${REVISION%?}"
case "$REVISION" in *0) WRONG_REVISION="${WRONG_REVISION}1" ;; *) WRONG_REVISION="${WRONG_REVISION}0" ;; esac
if node "$GENERATOR" "$SOURCE" "$WRONG_TARGET" "$WRONG_REVISION" >/dev/null 2>&1; then
  echo 'fixture generator accepted the wrong source revision' >&2; exit 1
fi
[ ! -e "$WRONG_TARGET" ]

printf 'dirty\n' >"$SOURCE/untracked"
DIRTY_TARGET="$TEMPORARY/targets/dirty-source"
if node "$GENERATOR" "$SOURCE" "$DIRTY_TARGET" "$REVISION" >/dev/null 2>&1; then
  echo 'fixture generator accepted a dirty source checkout' >&2; exit 1
fi
[ ! -e "$DIRTY_TARGET" ]
rm -f "$SOURCE/untracked"

node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  value.plugins[0].source.ref = "main";
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`);
' "$SOURCE/.claude-plugin/marketplace.json"
git -C "$SOURCE" add .claude-plugin/marketplace.json
git -C "$SOURCE" -c commit.gpgsign=false commit -qm 'test: invalid mutable marketplace ref'
MUTABLE_REVISION="$(git -C "$SOURCE" rev-parse HEAD)"
MUTABLE_TARGET="$TEMPORARY/targets/mutable-ref"
if node "$GENERATOR" "$SOURCE" "$MUTABLE_TARGET" "$MUTABLE_REVISION" >/dev/null 2>&1; then
  echo 'fixture generator accepted a mutable production source ref' >&2; exit 1
fi
[ ! -e "$MUTABLE_TARGET" ]

printf 'marketplace-fixture-selftest.sh: PASS\n'
