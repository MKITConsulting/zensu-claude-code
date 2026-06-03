#!/bin/bash
# Idempotent fixture for the live full /zensu:tdd cycle. A clean git repo with a
# runnable Node test command and an empty src — the agent writes the RED test and
# the implementation itself. Node's built-in runner means zero npm install.
set -eu

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"

d="$FIXTURES_DIR/add-feature"
rm -rf "$d"
mkdir -p "$d/src" "$d/test"
git -C "$d" init -q -b main
git -C "$d" config user.email "fixture@zensu.local"
git -C "$d" config user.name "Zensu Fixture"
git -C "$d" config commit.gpgsign false

cat > "$d/package.json" <<'EOF'
{
  "name": "add-feature",
  "version": "0.0.0",
  "private": true,
  "scripts": { "test": "node --test" }
}
EOF

cat > "$d/SPEC.md" <<'EOF'
# Feature: add(a, b)

Implement `add(a, b)` in `src/math.js` as a CommonJS module
(`module.exports = { add }`) returning `a + b`.

Test first with Node's built-in runner: `test/math.test.js` using `node:test` +
`node:assert`, run via `node --test`.
EOF

cat > "$d/.gitkeep" <<'EOF'
EOF

git -C "$d" add -A
git -C "$d" commit -q -m "baseline: empty add-feature project (test runner ready)"

echo "e2e-tdd fixture built: $d"
