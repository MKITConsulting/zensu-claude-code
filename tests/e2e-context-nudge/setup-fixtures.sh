#!/bin/bash
# Builds the live context-nudge E2E fixture: a minimal git project that a real
# `claude --print` run executes inside, producing a genuine session transcript
# the hook is then asserted against. Idempotent.
set -u

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"
FIXTURE="$FIXTURES_DIR/greet"

mkdir -p "$FIXTURE"
printf '# greet fixture\n\nMinimal project for the context-nudge E2E. A live `claude --print` run\nhere produces a real session transcript that user-prompt-context-nudge.sh is\nasserted against. Generated, git-ignored.\n' > "$FIXTURE/README.md"

if [ ! -d "$FIXTURE/.git" ]; then
  ( cd "$FIXTURE" \
      && git init -q \
      && git add -A \
      && git -c user.email=e2e@zensu.dev -c user.name=e2e commit -qm "init greet fixture" ) >/dev/null 2>&1 || true
fi

echo "context-nudge fixture ready: $FIXTURE"
