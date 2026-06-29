#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
FIXTURE="$FIXTURES_DIR/project"

mkdir -p "$FIXTURE/src"
printf '# source-write-gate fixture\n\nGit project with a tracked source file. A live `claude --print` run here\nexercises the PreToolUse(Bash) source-write gate end to end. Generated, git-ignored.\n' > "$FIXTURE/README.md"
printf 'export const greeting = "hello";\n' > "$FIXTURE/src/sample.ts"

if [ ! -d "$FIXTURE/.git" ]; then
  ( cd "$FIXTURE" \
      && git init -q \
      && git add -A \
      && git -c user.email=e2e@zensu.dev -c user.name=e2e commit -qm "init source-write-gate fixture" ) >/dev/null 2>&1 || true
else
  # Keep the tracked file pristine across re-runs.
  ( cd "$FIXTURE" && git checkout -q -- src/sample.ts 2>/dev/null ) || true
fi

echo "source-write-gate fixture ready: $FIXTURE"
