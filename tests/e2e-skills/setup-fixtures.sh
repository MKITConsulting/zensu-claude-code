#!/bin/bash
# Idempotent fixture builder for tests/e2e-skills. Safe to re-run; each fixture is
# rebuilt from scratch. Git fixtures carry an UNCOMMITTED working-tree change so
# `git diff HEAD` surfaces the changeset that self-review / review-aspect inspect.
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

# ─── Fixture: zensu-help ──────────────────────────────────────────────
# Read-only Q&A — answers from the skill's embedded glossary. No git needed;
# just a CWD for `claude --print` to run in.
make_zensu_help() {
  local d="$FIXTURES_DIR/zensu-help"
  rm -rf "$d"; mkdir -p "$d"
  cat > "$d/CLAUDE.md" <<'EOF'
# Fixture project (zensu-help e2e)
Minimal project so /zensu:zensu-help has a working directory.
EOF
}

# ─── Fixture: plan-review ─────────────────────────────────────────────
# A small REAL codebase so the feasibility reviewer has something to verify.
# The plan (prompts/plan-review.txt) deliberately references a function that
# does not exist and omits tests, so the team should NOT return a clean "go".
make_plan_review() {
  local d="$FIXTURES_DIR/plan-review"
  git_init "$d"
  cat > "$d/CLAUDE.md" <<'EOF'
# Fixture project (plan-review e2e)
Language: JavaScript. Tests are required for every new function (test-first).
EOF
  cat > "$d/calc.js" <<'EOF'
function add(a, b) {
  return a + b;
}
module.exports = { add };
EOF
  commit_all "$d" "baseline: calc.add"
}

# ─── Fixture: self-review ─────────────────────────────────────────────
# Baseline committed; an UNCOMMITTED change adds a function with an obvious
# smell (no input validation, swallowed edge case) for the reflection to find.
make_self_review() {
  local d="$FIXTURES_DIR/self-review"
  git_init "$d"
  cat > "$d/calc.js" <<'EOF'
function add(a, b) {
  return a + b;
}
module.exports = { add };
EOF
  commit_all "$d" "baseline: calc.add"
  # Uncommitted working-tree change under review.
  cat > "$d/calc.js" <<'EOF'
function add(a, b) {
  return a + b;
}
function average(nums) {
  let sum = 0;
  for (const n of nums) sum += n;
  return sum / nums.length;
}
module.exports = { add, average };
EOF
}

# ─── Fixture: review-aspect ───────────────────────────────────────────
# Baseline has a SAFE divide (zero-guarded); the UNCOMMITTED change removes the
# guard and adds an off-by-one indexing bug. The `bugs` perspective must flag them.
make_review_aspect() {
  local d="$FIXTURES_DIR/review-aspect"
  git_init "$d"
  cat > "$d/calc.js" <<'EOF'
function divide(a, b) {
  if (b === 0) throw new Error("divide by zero");
  return a / b;
}
module.exports = { divide };
EOF
  commit_all "$d" "baseline: guarded divide"
  # Uncommitted working-tree change introducing two defects.
  cat > "$d/calc.js" <<'EOF'
function divide(a, b) {
  return a / b;
}
function lastItem(arr) {
  return arr[arr.length];
}
module.exports = { divide, lastItem };
EOF
}

mkdir -p "$FIXTURES_DIR"
make_zensu_help
make_plan_review
make_self_review
make_review_aspect

echo "e2e-skills fixtures built under: $FIXTURES_DIR"
ls -1 "$FIXTURES_DIR"
