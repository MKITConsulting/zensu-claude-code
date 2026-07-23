#!/bin/bash
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$EVAL_DIR/../.." && pwd -P)"
PROMPTFOO="$ROOT/node_modules/.bin/promptfoo"
MODE="${1:-contract}"
shift || true

case "$MODE" in contract|upgrade|live|concurrency|adversarial|release) ;; *)
  echo "usage: $0 contract|upgrade|live|concurrency|adversarial|release" >&2; exit 2 ;;
esac

test -x "$PROMPTFOO" || { echo 'session-control eval: run npm ci first' >&2; exit 127; }
test "$(node -p 'require(process.argv[1]).devDependencies.promptfoo' "$ROOT/package.json")" = '0.121.18' \
  || { echo 'session-control eval: package pin must be exactly promptfoo 0.121.18' >&2; exit 1; }
test "$(node -p 'require(process.argv[1]).packages["node_modules/promptfoo"].version' "$ROOT/package-lock.json")" = '0.121.18' \
  || { echo 'session-control eval: lockfile does not resolve exact promptfoo 0.121.18' >&2; exit 1; }

if [ "$MODE" = contract ]; then
  export ZENSU_EXPECTED_PLUGIN_ROOT="${ZENSU_EXPECTED_PLUGIN_ROOT:-$ROOT}"
  export ZENSU_EXPECTED_SOURCE_REVISION="${ZENSU_EXPECTED_SOURCE_REVISION:-$(git -C "$ROOT" rev-parse HEAD)}"
  EXPECTED_SOURCE_ROOT="$ZENSU_EXPECTED_PLUGIN_ROOT"
else
  test -n "${ZENSU_EXPECTED_SOURCE_ROOT:-}" \
    || { echo 'session-control eval: ZENSU_EXPECTED_SOURCE_ROOT is mandatory for live and release profiles' >&2; exit 1; }
  test -n "${ZENSU_EXPECTED_SOURCE_REVISION:-}" \
    || { echo 'session-control eval: ZENSU_EXPECTED_SOURCE_REVISION is mandatory for live and release profiles' >&2; exit 1; }
  EXPECTED_SOURCE_ROOT="$ZENSU_EXPECTED_SOURCE_ROOT"
  export ZENSU_EXPECTED_SOURCE_ROOT ZENSU_EXPECTED_SOURCE_REVISION
fi
EXPECTED_ROOT="$(cd "$EXPECTED_SOURCE_ROOT" 2>/dev/null && pwd -P)" \
  || { echo 'session-control eval: expected source root is unavailable' >&2; exit 1; }
test "$EXPECTED_ROOT" = "$ROOT" \
  || { echo 'session-control eval: expected source root does not target this checkout' >&2; exit 1; }
test "$(git -C "$ROOT" rev-parse HEAD)" = "$ZENSU_EXPECTED_SOURCE_REVISION" \
  || { echo 'session-control eval: exact expected source revision does not match checkout' >&2; exit 1; }

if [ "$MODE" = release ]; then
  test "${ZENSU_UPGRADE_EXISTING_LOGIN:-0}" != 1 \
    || { echo 'session-control eval: release evidence forbids non-authoritative existing-login mode' >&2; exit 1; }
  bash "$EVAL_DIR/lib/release-preflight.sh" "$ROOT" "$ZENSU_EXPECTED_SOURCE_REVISION"
  bash "$EVAL_DIR/run-self-check.sh"
  bash "$EVAL_DIR/run-eval.sh" contract "$@"
  bash "$EVAL_DIR/run-eval.sh" upgrade "$@"
  bash "$EVAL_DIR/run-eval.sh" live "$@"
  bash "$EVAL_DIR/run-eval.sh" concurrency "$@"
  bash "$EVAL_DIR/run-eval.sh" adversarial "$@"
  bash "$EVAL_DIR/lib/release-preflight.sh" "$ROOT" "$ZENSU_EXPECTED_SOURCE_REVISION"
  exit 0
fi

if [ "$MODE" = upgrade ]; then
  test "${ZENSU_EXPECTED_CLAUDE_VERSION:-}" != '' \
    || { echo 'session-control eval: ZENSU_EXPECTED_CLAUDE_VERSION is mandatory for the upgrade profile' >&2; exit 1; }
  case "$ZENSU_EXPECTED_CLAUDE_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo 'session-control eval: expected Claude version is malformed' >&2; exit 1 ;;
  esac
  export ZENSU_EXPECTED_CLAUDE_VERSION
  if [ "${ZENSU_UPGRADE_EXISTING_LOGIN:-0}" = 1 ] \
    && [ -n "${ZENSU_SESSION_CONTROL_EVIDENCE_DIR:-}" ]; then
    echo 'session-control eval: existing-login upgrade mode is a local diagnostic and cannot publish evidence' >&2
    exit 1
  fi
fi

if [ "$MODE" != contract ]; then
  command -v claude >/dev/null 2>&1 || { echo 'session-control eval: claude CLI unavailable' >&2; exit 127; }
  test "${ZENSU_E2E_DISPOSABLE_ENVIRONMENT:-0}" = 1 \
    || { echo 'session-control eval: set ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 only on a disposable live-eval host' >&2; exit 64; }
  if [ "$MODE" != upgrade ] || [ "${ZENSU_UPGRADE_EXISTING_LOGIN:-0}" != 1 ]; then
    test -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" \
      || { echo 'session-control eval: explicit Claude credentials unavailable' >&2; exit 1; }
  fi
fi

STATE="$(mktemp -d -t zensu-session-promptfoo-XXXXXX)"
cleanup() { rm -rf "$STATE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
export PROMPTFOO_CONFIG_DIR="$STATE"
export PROMPTFOO_DISABLE_TELEMETRY=1
export PROMPTFOO_DISABLE_UPDATE=1
RESULT_ROOT="$ROOT"
if [ "$MODE" != contract ] && [ "$MODE" != upgrade ]; then
  INSTALL_STATE="$STATE/installed-plugin"
  mkdir -p "$INSTALL_STATE"
  chmod 700 "$INSTALL_STATE"
  INSTALL_MANIFEST="$(bash "$EVAL_DIR/lib/provision-installed-plugin.sh" \
    "$ROOT" "$INSTALL_STATE" "$ZENSU_EXPECTED_SOURCE_REVISION")" \
    || { echo 'session-control eval: isolated installed-plugin provisioning failed' >&2; exit 1; }
  test -f "$INSTALL_MANIFEST" && test ! -L "$INSTALL_MANIFEST" \
    || { echo 'session-control eval: installation manifest is unavailable' >&2; exit 1; }
  ZENSU_INSTALLED_PLUGIN_ROOT="$(jq -er '.installed_plugin_root' "$INSTALL_MANIFEST")" \
    || { echo 'session-control eval: installed plugin root is unavailable' >&2; exit 1; }
  ZENSU_CLAUDE_ISOLATED_HOME="$(jq -er '.isolated_home' "$INSTALL_MANIFEST")" \
    || { echo 'session-control eval: isolated Claude HOME is unavailable' >&2; exit 1; }
  ZENSU_EXPECTED_PLUGIN_ROOT="$ZENSU_INSTALLED_PLUGIN_ROOT"
  ZENSU_INSTALLATION_MANIFEST="$INSTALL_MANIFEST"
  export ZENSU_INSTALLED_PLUGIN_ROOT ZENSU_CLAUDE_ISOLATED_HOME
  export ZENSU_EXPECTED_PLUGIN_ROOT ZENSU_INSTALLATION_MANIFEST
  RESULT_ROOT="$ZENSU_INSTALLED_PLUGIN_ROOT"
fi
if [ "$MODE" = concurrency ]; then
  ZENSU_CONCURRENCY_CONTROL_DIR="$STATE/shared-concurrency-control"
  mkdir -p "$ZENSU_CONCURRENCY_CONTROL_DIR"
  chmod 700 "$ZENSU_CONCURRENCY_CONTROL_DIR"
  export ZENSU_CONCURRENCY_CONTROL_DIR
fi

cd "$EVAL_DIR"
RESULT_FILE="$STATE/${MODE}.json"
"$PROMPTFOO" eval \
  --config "promptfooconfig-${MODE}.yaml" \
  --no-cache --no-share --no-write --no-progress-bar --output "$RESULT_FILE" "$@"
if [ -n "${ZENSU_SESSION_CONTROL_EVIDENCE_DIR:-}" ]; then
  EVIDENCE_DIR="$ZENSU_SESSION_CONTROL_EVIDENCE_DIR"
  mkdir -p "$EVIDENCE_DIR"
  [ -d "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ] \
    || { echo 'session-control eval: evidence directory must be a real directory' >&2; exit 1; }
  EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd -P)"
  chmod 700 "$EVIDENCE_DIR"
  if [ "$MODE" = upgrade ]; then
    node "$EVAL_DIR/lib/verify-upgrade-results.js" "$RESULT_FILE" \
      "$ZENSU_EXPECTED_SOURCE_REVISION" "$EVIDENCE_DIR/${MODE}.json"
  else
    node "$EVAL_DIR/lib/verify-results.js" "$MODE" "$RESULT_FILE" "$RESULT_ROOT" \
      "$ZENSU_EXPECTED_SOURCE_REVISION" "$EVIDENCE_DIR/${MODE}.json"
  fi
else
  if [ "$MODE" = upgrade ]; then
    node "$EVAL_DIR/lib/verify-upgrade-results.js" "$RESULT_FILE" \
      "$ZENSU_EXPECTED_SOURCE_REVISION"
  else
    node "$EVAL_DIR/lib/verify-results.js" "$MODE" "$RESULT_FILE" "$RESULT_ROOT" \
      "$ZENSU_EXPECTED_SOURCE_REVISION"
  fi
fi
