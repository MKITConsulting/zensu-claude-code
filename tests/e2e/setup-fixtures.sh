#!/bin/bash
set -eu

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURES_DIR="${FIXTURES_DIR:-$EVAL_DIR/fixtures}"

git_init() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "fixture@zensu.local"
  git -C "$dir" config user.name "Zensu Fixture"
  git -C "$dir" config commit.gpgsign false
}

commit_all() {
  local dir="$1" msg="$2"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$msg"
}

# ─── Fixture: clean-pr ────────────────────────────────────────────────
make_clean_pr() {
  local d="$FIXTURES_DIR/clean-pr"
  git_init "$d"
  cat > "$d/sample.ts" <<'EOF'
export const noop = () => {};
EOF
  cat > "$d/package.json" <<'EOF'
{ "name": "clean-pr", "version": "0.0.0", "scripts": { "build": "echo build-ok" } }
EOF
  commit_all "$d" "main: baseline"

  git -C "$d" checkout -q -b feature
  cat > "$d/sample.ts" <<'EOF'
export const noop = () => {};
export function add(a: number, b: number): number {
  return a + b;
}
EOF
  cat > "$d/sample.test.ts" <<'EOF'
import { add } from "./sample";
if (add(2, 3) !== 5) { throw new Error("add broken"); }
EOF
  commit_all "$d" "feature: add() with test"
}

# ─── Fixture: stale-branch ────────────────────────────────────────────
make_stale_branch() {
  local d="$FIXTURES_DIR/stale-branch"
  git_init "$d"
  cat > "$d/sample.ts" <<'EOF'
export const x = 1;
EOF
  commit_all "$d" "main: baseline"

  git -C "$d" checkout -q -b feature
  echo "export const y = 2;" > "$d/feature-file.ts"
  commit_all "$d" "feature: add y"

  git -C "$d" checkout -q main
  for i in 1 2 3; do
    echo "// main change $i" >> "$d/sample.ts"
    commit_all "$d" "main: change $i"
  done

  git -C "$d" remote add origin "$d"
  git -C "$d" fetch -q origin

  git -C "$d" checkout -q feature
}

# ─── Fixture: build-fails ─────────────────────────────────────────────
make_build_fails() {
  local d="$FIXTURES_DIR/build-fails"
  git_init "$d"
  cat > "$d/package.json" <<'EOF'
{
  "name": "build-fails",
  "version": "0.0.0",
  "scripts": { "build": "tsc --noEmit" },
  "devDependencies": { "typescript": "5.6.3" }
}
EOF
  cat > "$d/tsconfig.json" <<'EOF'
{ "compilerOptions": { "strict": true, "noEmit": true, "target": "es2020", "module": "esnext", "moduleResolution": "node" }, "include": ["src/**/*.ts"] }
EOF
  cat > "$d/.gitignore" <<'EOF'
node_modules/
EOF
  mkdir -p "$d/src"
  cat > "$d/src/ok.ts" <<'EOF'
export const ok = 42;
EOF
  commit_all "$d" "main: baseline"

  git -C "$d" checkout -q -b feature
  cat > "$d/src/broken.ts" <<'EOF'
export const x: number = "this is not a number";
EOF
  commit_all "$d" "feature: deliberately-broken types"

  if command -v npm >/dev/null 2>&1; then
    (cd "$d" && npm install --silent --no-audit --no-fund --no-progress >/dev/null 2>&1) || {
      echo "WARNING: npm install failed in $d — tsc will not run hermetically" >&2
    }
  else
    echo "WARNING: npm not found on PATH — build-fails fixture will not have tsc installed" >&2
  fi
}

# ─── Fixture: false-test-claim ────────────────────────────────────────
make_false_test_claim() {
  local d="$FIXTURES_DIR/false-test-claim"
  git_init "$d"
  cat > "$d/package.json" <<'EOF'
{
  "name": "false-test-claim",
  "version": "0.0.0",
  "scripts": { "test": "echo no-tests-found && exit 0", "build": "echo build-ok" }
}
EOF
  mkdir -p "$d/src"
  cat > "$d/src/feature.ts" <<'EOF'
export function noop() {}
EOF
  commit_all "$d" "main: baseline"

  git -C "$d" checkout -q -b feature
  cat > "$d/src/feature.ts" <<'EOF'
export function noop() {}
export function multiply(a: number, b: number): number {
  return a * b;
}
EOF
  cat > "$d/tdd-claim.txt" <<'EOF'
tdd-manager reported: 100/100 PASS
Coverage: 100%
EOF
  commit_all "$d" "feature: multiply() and false tdd claim"
}

# ─── Fixture: docs-only ───────────────────────────────────────────────
make_docs_only() {
  local d="$FIXTURES_DIR/docs-only"
  git_init "$d"
  cat > "$d/README.md" <<'EOF'
# Docs-Only Fixture

Baseline documentation.
EOF
  commit_all "$d" "main: baseline docs"

  git -C "$d" checkout -q -b feature
  cat > "$d/README.md" <<'EOF'
# Docs-Only Fixture

Baseline documentation.

## New Section

This is a documentation-only change with no source-code impact.
EOF
  commit_all "$d" "feature: docs-only expansion"
}

main() {
  mkdir -p "$FIXTURES_DIR"
  make_clean_pr
  make_stale_branch
  make_build_fails
  make_false_test_claim
  make_docs_only
  echo "Fixtures created under $FIXTURES_DIR"
}

main "$@"
