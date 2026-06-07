#!/bin/bash
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
FIXTURE="$FIXTURES_DIR/planning"

mkdir -p "$FIXTURE"
printf '# planning fixture\n\nMinimal project for the intent-router E2E. A live `claude --print` run here\nexercises the UserPromptSubmit intent-router hook end to end. Generated, git-ignored.\n' > "$FIXTURE/README.md"

if [ ! -d "$FIXTURE/.git" ]; then
  ( cd "$FIXTURE" \
      && git init -q \
      && git add -A \
      && git -c user.email=e2e@zensu.dev -c user.name=e2e commit -qm "init planning fixture" ) >/dev/null 2>&1 || true
fi

echo "intent-router fixture ready: $FIXTURE"
