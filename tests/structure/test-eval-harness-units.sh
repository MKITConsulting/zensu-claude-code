#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/lib-unit-registry.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

unit_check "owned process groups clean normal-exit and late-fork descendants" "$PLUGIN_DIR/tests/structure/owned-process.test.js"
unit_check "fixture watch events are classified once for both backends" "$PLUGIN_DIR/tests/structure/fixture-mutation-watch.test.js"
unit_check "P7-S12b stream renderer behavior enforces framing and resource limits" "$PLUGIN_DIR/tests/structure/claude-stream-render.test.js"
unit_check "deterministic transcript contract regressions pass" "$PLUGIN_DIR/tests/structure/verify-feature-transcript-check.test.js"
unit_check_done "every unit file the registry gives this suite was graded"

EVAL_DIR="$PLUGIN_DIR/evals/verify-feature"
CFG="$EVAL_DIR/promptfooconfig.yaml"
REMOTE_ACCEPTED="$EVAL_DIR/scenarios/remote-accepted-public.yaml"
REMOTE_NETWORK_ONLY="$EVAL_DIR/scenarios/remote-separate-api-origin.yaml"
ASSERTION="$EVAL_DIR/assertions/transcript-check.js"
RUNNER="$EVAL_DIR/run-eval.sh"
WRAPPER="$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh"
EVAL_REAL="$(cd "$EVAL_DIR" && pwd -P)"
FIXTURE_REAL="$(cd "$EVAL_DIR/test-projects/live-app" && pwd -P)"

resolve_against() {
  local base="$1" target="$2" parent
  parent="$(cd "$base" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
  if [ -d "$parent/$(basename "$target")" ]; then
    (cd "$parent/$(basename "$target")" && pwd -P)
  else
    printf '%s/%s\n' "$parent" "$(basename "$target")"
  fi
}
git_mode() {
  git -C "$PLUGIN_DIR" ls-files -s -- "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
}
assertions_resolve() {
  local scenario="$1" value count=0
  for value in $(sed -n 's/^    value: file:\/\/\(.*\)$/\1/p' "$scenario"); do
    count=$((count+1))
    [ -f "$(resolve_against "$EVAL_DIR" "$value")" ] || return 1
  done
  [ "$count" -gt 0 ]
}
scenario_provider_resolves() {
  local scenario="$1" provider="$2" exec_path work_dir
  exec_path="$(sed -n "s/^  id: 'exec: \(.*\)'$/\1/p" "$scenario")"
  work_dir="$(sed -n 's/^    working_dir: \(.*\)$/\1/p' "$scenario")"
  [ -n "$exec_path" ] && [ -n "$work_dir" ] \
    && [ "$(resolve_against "$(dirname "$scenario")" "$exec_path")" = "$EVAL_REAL/$provider" ] \
    && [ "$(git_mode "evals/verify-feature/$provider")" = 100755 ] \
    && [ "$(resolve_against "$(dirname "$scenario")" "$work_dir")" = "$FIXTURE_REAL" ] \
    && assertions_resolve "$scenario"
}
CONFIG_PROVIDER="$(sed -n "s/^  - id: 'exec: \(.*\)'$/\1/p" "$CFG")"
CONFIG_WORK_DIR="$(sed -n 's/^      working_dir: \(.*\)$/\1/p' "$CFG")"
if scenario_provider_resolves "$REMOTE_ACCEPTED" remote-provider.sh \
  && scenario_provider_resolves "$REMOTE_NETWORK_ONLY" remote-network-only-provider.sh \
  && [ ! -e "$(resolve_against "$EVAL_DIR/scenarios" ./remote-provider.sh)" ] \
  && [ ! -e "$(resolve_against "$EVAL_DIR/scenarios" assertions/transcript-check.js)" ] \
  && [ "$(resolve_against "$EVAL_DIR" "$CONFIG_PROVIDER")" = "$(cd "$PLUGIN_DIR/scripts" && pwd -P)/claude-promptfoo-wrapper.sh" ] \
  && [ "$(resolve_against "$EVAL_DIR" "$CONFIG_WORK_DIR")" = "$FIXTURE_REAL" ] \
  && grep -qF '"promptfoo": "0.121.20"' "$PLUGIN_DIR/package.json"; then
  check "each verify-feature exec provider and working_dir resolves against its own file's directory, where the pinned promptfoo 0.121.20 starts it, while file:// assertion values resolve against the config's directory" PASS
else
  check "each verify-feature exec provider and working_dir resolves against its own file's directory, where the pinned promptfoo 0.121.20 starts it, while file:// assertion values resolve against the config's directory" FAIL
fi

if grep -qF 'PROMPTFOO="${VERIFY_FEATURE_PROMPTFOO:-$PLUGIN_DIR/node_modules/.bin/promptfoo}"' "$RUNNER" \
  && grep -qF 'if [ ! -x "$PROMPTFOO" ]; then' "$RUNNER" \
  && grep -qF 'VERIFY_FEATURE_PROMPTFOO must be an absolute path' "$RUNNER" \
  && grep -qF 'node "$OWNED_PROCESS" "$PROMPTFOO" eval' "$RUNNER" \
  && ! grep -qE 'for cli in [^;]*promptfoo' "$RUNNER" \
  && ! grep -qF 'node "$OWNED_PROCESS" promptfoo ' "$RUNNER"; then
  check "the verify-feature live runner starts the promptfoo package.json pins, never one it finds on PATH" PASS
else
  check "the verify-feature live runner starts the promptfoo package.json pins, never one it finds on PATH" FAIL
fi

CHROME_KEY_FILES="$(cd "$PLUGIN_DIR" && find evals \( -name '*.yaml' -o -name '*.yml' \) -type f -exec grep -lF 'allow_unsandboxed_chrome' {} + 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
if [ "$CHROME_KEY_FILES" = "evals/verify-feature/promptfooconfig.yaml evals/verify-feature/scenarios/remote-accepted-public.yaml evals/verify-feature/scenarios/remote-separate-api-origin.yaml " ] \
  && grep -qF '      allow_unsandboxed_chrome: true' "$CFG" \
  && grep -qF '      require_disposable_environment: true' "$CFG" \
  && grep -qF '    allow_unsandboxed_chrome: true' "$REMOTE_ACCEPTED" \
  && grep -qF '    require_disposable_environment: true' "$REMOTE_ACCEPTED" \
  && grep -qF '    allow_unsandboxed_chrome: true' "$REMOTE_NETWORK_ONLY" \
  && grep -qF '    require_disposable_environment: true' "$REMOTE_NETWORK_ONLY"; then
  check "only the three verify-feature providers, each on a disposable host, start Google Chrome outside the fixture sandbox" PASS
else
  check "only the three verify-feature providers, each on a disposable host, start Google Chrome outside the fixture sandbox (files: $CHROME_KEY_FILES)" FAIL
fi

if grep -qF "'(allow signal (target same-sandbox))'" "$WRAPPER" \
  && grep -qF "'(allow signal (target children))'" "$WRAPPER" \
  && grep -qF "'(allow process-exec (literal \"/bin/ps\") (with no-sandbox))'" "$WRAPPER" \
  && grep -qF 'CHROME_EXECUTABLE="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"' "$WRAPPER" \
  && grep -qF 'if .config.allow_unsandboxed_chrome == true then "true" else "false" end' "$WRAPPER" \
  && grep -qF 'if [ "$ALLOW_UNSANDBOXED_CHROME" = "true" ] && [ "$REQUIRE_DISPOSABLE" != "true" ]; then' "$WRAPPER" \
  && grep -qF 'if [ "$ALLOW_UNSANDBOXED_CHROME" = "true" ]; then' "$WRAPPER" \
  && grep -qF '(allow process-exec (literal "%s") (with no-sandbox))' "$WRAPPER" \
  && grep -qF '"$CHROME_EXECUTABLE" >>"$SANDBOX_PROFILE"' "$WRAPPER" \
  && [ "$(grep -cF 'with no-sandbox' "$WRAPPER")" = 2 ] \
  && ! grep -qF '(subpath "/Applications/Google Chrome.app")' "$WRAPPER"; then
  check "the macOS fixture sandbox admits signals inside it and to own children, runs /bin/ps outside it, and starts only the Chrome main executable outside it for a disposable provider that asks" PASS
else
  check "the macOS fixture sandbox admits signals inside it and to own children, runs /bin/ps outside it, and starts only the Chrome main executable outside it for a disposable provider that asks" FAIL
fi

if ! grep -qE 'Example Domain|Learn more' "$REMOTE_ACCEPTED" "$REMOTE_NETWORK_ONLY" "$ASSERTION" \
  && grep -qF '1. The page shows its explanatory text.' "$REMOTE_NETWORK_ONLY" \
  && grep -qF '4. The page loads without console errors or failed requests.' "$REMOTE_ACCEPTED" \
  && grep -qF '4. The page loads without console errors or failed requests.' "$REMOTE_NETWORK_ONLY" \
  && grep -qF 'const PAGE_TEXT = ' "$ASSERTION" \
  && grep -qF 'static requests? not shown' "$ASSERTION"; then
  check "verify-feature remote criteria and evidence name no wording of the third-party page and accept a document load the request log proves" PASS
else
  check "verify-feature remote criteria and evidence name no wording of the third-party page and accept a document load the request log proves" FAIL
fi

echo "----"
echo "test-eval-harness-units: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
