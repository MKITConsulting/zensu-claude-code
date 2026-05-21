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

make_bootstrap() {
  local d="$FIXTURES_DIR/bootstrap"
  git_init "$d"
  cat > "$d/README.md" <<'EOF'
# Solo Time

A new product. No existing components.
EOF
  commit_all "$d" "main: empty product baseline"
}

make_implement() {
  local d="$FIXTURES_DIR/implement"
  git_init "$d"
  mkdir -p "$d/src/auth" "$d/tests"
  cat > "$d/src/auth/login.ts" <<'EOF'
export function login(user: string, password: string): boolean {
  return user.length > 0 && password.length > 0;
}
EOF
  cat > "$d/tests/login.test.ts" <<'EOF'
import { login } from "../src/auth/login";
if (!login("a", "b")) throw new Error("login broken");
EOF
  commit_all "$d" "main: existing login feature (ZEN-042 target)"
}

make_security_review() {
  local d="$FIXTURES_DIR/security-review"
  git_init "$d"
  mkdir -p "$d/src/payment"
  cat > "$d/src/payment/charge.ts" <<'EOF'
export function charge(amount: number, card: string): void {
  console.log(`charging ${amount} to ${card}`);
}
EOF
  commit_all "$d" "main: payment module (ZEN-007 target)"
}

make_ghost_scan() {
  local d="$FIXTURES_DIR/ghost-scan"
  git_init "$d"
  mkdir -p "$d/src"
  cat > "$d/src/auth.ts" <<'EOF'
export function authenticate(token: string): boolean {
  return token.startsWith("Bearer ");
}
EOF
  cat > "$d/src/payment.ts" <<'EOF'
export function processPayment(amount: number): { id: string } {
  return { id: "pay_" + Date.now() };
}
EOF
  cat > "$d/src/notifications.ts" <<'EOF'
export function sendEmail(to: string, subject: string): void {
  console.log(`email to ${to}: ${subject}`);
}
EOF
  cat > "$d/README.md" <<'EOF'
# Repo with several plausible features waiting to be scanned.
EOF
  commit_all "$d" "main: features awaiting ghost-scan"
}

make_pulse_session() {
  local d="$FIXTURES_DIR/pulse-session"
  git_init "$d"
  cat > "$d/work.ts" <<'EOF'
export const inProgress = "yes";
EOF
  commit_all "$d" "main: initial work"
  echo "// later change" >> "$d/work.ts"
  commit_all "$d" "main: continuing work"
}

make_status_transition() {
  local d="$FIXTURES_DIR/status-transition"
  git_init "$d"
  cat > "$d/README.md" <<'EOF'
# ZEN-001 lives in the Zensu backend; this fixture is just the working dir.
EOF
  commit_all "$d" "main: status transition target"
}

make_feature_id_guard() {
  local d="$FIXTURES_DIR/feature-id-guard"
  git_init "$d"
  cat > "$d/README.md" <<'EOF'
# Working dir. ZEN-999 does NOT exist — agent must not invent it.
EOF
  commit_all "$d" "main: feature id guard"
}

main() {
  mkdir -p "$FIXTURES_DIR"
  make_bootstrap
  make_implement
  make_security_review
  make_ghost_scan
  make_pulse_session
  make_status_transition
  make_feature_id_guard
  echo "Fixtures created under $FIXTURES_DIR"
}

main "$@"
