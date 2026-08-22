#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SESSION="$ROOT/tests/structure/test-session-control-claude.sh"
REVIEWER="$ROOT/tests/structure/test-reviewer-capability-gate.sh"
CORRUPTION="$ROOT/tests/structure/test-tdd-state-corruption-fail-closed.sh"
MARKETPLACE="$ROOT/evals/session-control/tests/marketplace-fixture-selftest.sh"
PROVISIONER="$ROOT/evals/session-control/lib/provision-installed-plugin.sh"
INSTALL_CONTRACT="$ROOT/evals/session-control/lib/installed-plugin-contract.js"
CLAUDE_WRAPPER="$ROOT/scripts/session-control-claude-wrapper.sh"
CLAUDE_WRAPPER_SELFTEST="$ROOT/evals/session-control/tests/wrapper-selftest.sh"
LIVE_EVIDENCE="$ROOT/evals/session-control/lib/live-evidence.js"
LIVE_EVIDENCE_NEGATIVE="$ROOT/evals/session-control/tests/live-evidence-negative.test.js"
CLAUDE_STUB_BLOCK="$(sed -n "/^cat >.*<<'STUB'$/,/^STUB$/p" "$CLAUDE_WRAPPER_SELFTEST")"
RESET="$ROOT/evals/reset-review-limit/tests/sealed-evidence.test.js"
WORKFLOW="$ROOT/.github/workflows/windows-safety.yml"
WINDOWS_CANARY="$ROOT/tests/profiles/windows-legacy-canary.v1.json"
WINDOWS_SAFETY_RUNNER="$ROOT/tests/run-windows-safety-shard.js"
PHASE="$ROOT/hooks/lib/zensu-tdd-phase.sh"
SESSION_HOOK="$ROOT/hooks/session-start-session-control.sh"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
BINDER="$ROOT/hooks/lib/claude-hook-session-v1.js"
AUTOPILOT_STATE="$ROOT/hooks/lib/zensu-autopilot-state.sh"
PLAN_PAYLOAD="$ROOT/hooks/lib/plan-payload-v1.js"
BEST_SOLUTION_HOOK="$ROOT/hooks/user-prompt-best-solution-first.sh"
EVIDENCE_DISCIPLINE_HOOK="$ROOT/hooks/session-start-evidence-discipline.sh"
AUTOPILOT_STATE_TEST="$ROOT/tests/structure/test-autopilot-state-machine.sh"
VCS="$ROOT/hooks/lib/zensu-vcs.sh"
RESET_SNAPSHOT="$ROOT/evals/reset-review-limit/lib/state-snapshot.js"
AUTOPILOT_FULL="$ROOT/tests/structure/test-autopilot-full-cycle.sh"
ENRICHMENT="$ROOT/scripts/claude-enrichment-render.js"
PROMPTFOO_WRAPPER="$ROOT/scripts/claude-promptfoo-wrapper.sh"
PLAYWRIGHT_MCP="$ROOT/scripts/playwright-mcp.sh"
PLAYWRIGHT_MCP_TEST="$ROOT/tests/structure/playwright-mcp-proxy.test.js"
CORE_SNAPSHOT_BLOCK="$(awk '
  /^function readRegularFileSnapshot\(/ { capture=1 }
  /^function readRegularFile\(/ { capture=0 }
  capture
' "$CORE")"
AUTOPILOT_STATE_CONCURRENCY_BLOCK="$(sed -n '/^CONCURRENT_OK=true$/,/^BEFORE_WRONG_BUDGET=/p' "$AUTOPILOT_STATE_TEST")"
# A suite file that ends up containing a spliced copy of its own prologue re-executes this
# line, resetting the counters — the summary then reports only the checks after the last reset
# and looks entirely plausible. That is not hypothetical: it happened during this change (a
# JS `$`-pattern replacement spliced ~485 lines of a suite into itself, and the file still
# reported its normal total). An expected-total pin would not have caught it; a re-entry guard
# does, and costs nothing per added check. It detects a splice that INCLUDES these lines, which
# is the whole-prologue shape; a splice starting strictly below them is not covered.
if [ -n "${ZENSU_SUITE_PROLOGUE_ENTERED:-}" ]; then
  printf 'prologue re-entered — this suite file is corrupt\n' >&2
  exit 1
fi
ZENSU_SUITE_PROLOGUE_ENTERED=1
PASS=0; FAIL=0
# Arity is checked because a label that word-splits is not a cosmetic defect: check() reads
# position 2 unconditionally, so an over-supplied call whose second word happens to read PASS
# scores a FAILING check as a success. That happened in this change — an unquoted expansion in
# a FAIL label — and was fixed at its call site. This makes the class unrepeatable instead of
# re-swept by hand.
check() {
  if [ "$#" -ne 2 ]; then
    printf '  FAIL  check() called with %s arguments, expected 2 — a label word-split: %s\n' "$#" "${1:-}"
    FAIL=$((FAIL + 1)); return 0
  fi
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1));
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for file in "$SESSION" "$REVIEWER" "$CORRUPTION" "$MARKETPLACE" "$PROVISIONER"; do
  if grep -qF 'MINGW*|MSYS*|CYGWIN*' "$file"; then
    check "Windows guard exists: ${file#$ROOT/}" PASS
  else
    check "Windows guard exists: ${file#$ROOT/}" FAIL
  fi
done

if grep -qF 'process.platform === '\''win32'\''' "$RESET" \
  && grep -qF "runScenario('reset-cas-happy', reset)" "$RESET" \
  && grep -qF "runScenario('reset-invalid-state', null)" "$RESET" \
  && grep -qF "runScenario('reset-sidecar-isolation', reset)" "$RESET"; then
  check "reset selftest skips only the symlink sidecar row on Windows" PASS
else
  check "reset selftest skips only the symlink sidecar row on Windows" FAIL
fi

if grep -qF 'POSIX 0600 record-mode assertion skipped only on Windows' "$SESSION" \
  && grep -qF 'symlinked CLAUDE_PLUGIN_DATA fails closed' "$SESSION" \
  && ! grep -Eq 'MINGW\*\|MSYS\*\|CYGWIN\*\).*exit 0' "$SESSION"; then
  check "Session Control keeps non-mode/non-symlink semantics unconditional" PASS
else
  check "Session Control keeps non-mode/non-symlink semantics unconditional" FAIL
fi

if grep -qF 'dangling symlink leaf' "$REVIEWER" \
  && grep -qF 'neutral apply_patch Move to external host path is allowed' "$REVIEWER" \
  && grep -qF 'neutral apply_patch Move to workflow state is denied' "$REVIEWER" \
  && grep -qF 'workflow-state symlink rejection skipped only on Windows' "$CORRUPTION" \
  && grep -qF 'SKIP POSIX 0700 assertion on Windows' "$MARKETPLACE"; then
  check "security cases remain present behind only their narrow portability guards" PASS
else
  check "security cases remain present behind only their narrow portability guards" FAIL
fi

WINDOWS_CANARY_COMMANDS="$(node -e '
  const fs=require("fs");
  const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  process.stdout.write(value.commands.join("\n"));
' "$WINDOWS_CANARY")"
if grep -qF '{ kind: canary, shard: 1, total: 4 }' "$WORKFLOW" \
  && grep -qF 'node tests/run-windows-safety-shard.js "${{ matrix.kind }}" "${{ matrix.shard }}" "${{ matrix.total }}"' "$WORKFLOW" \
  && grep -qF "windows-legacy-canary.v1.json" "$WINDOWS_SAFETY_RUNNER" \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash tests/structure/test-msys-runtime-boundaries.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | awk '
    /^bash tests\/structure\/test-msys-runtime-boundaries\.sh$/ { stage=1; next }
    stage == 1 && /^bash evals\/session-control\/tests\/marketplace-fixture-selftest\.sh$/ { stage=2; next }
    stage == 2 && /^bash evals\/session-control\/tests\/installed-plugin-provisioner-selftest\.sh$/ { stage=3; next }
    stage == 3 && /^bash evals\/session-control\/tests\/wrapper-selftest\.sh$/ { stage=4; next }
    stage == 4 && /^bash tests\/structure\/test-pre-edit-hook-mirror\.sh$/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash tests/structure/test-deferred-review-claim.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash tests/structure/test-session-id-v1.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash tests/structure/test-session-start-banner.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash tests/structure/test-tdd-no-flock-external-lease.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash tests/session-control/run.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash evals/session-control/tests/marketplace-fixture-selftest.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash evals/session-control/tests/installed-plugin-provisioner-selftest.sh' \
  && printf '%s\n' "$WINDOWS_CANARY_COMMANDS" | grep -qFx 'bash evals/session-control/tests/wrapper-selftest.sh'; then
  check "Windows safety CI preserves MSYS path transport, plugin provisioning, and Core lease coverage" PASS
else
  check "Windows safety CI preserves MSYS path transport, plugin provisioning, and Core lease coverage" FAIL
fi

if grep -qF 'MINGW*|MSYS*|CYGWIN*) MARKETPLACE_ROOT="$(cygpath -u "$MARKETPLACE_ROOT")"' "$PROVISIONER" \
  && grep -qF 'MARKETPLACE_ROOT="$(cd -P -- "$MARKETPLACE_ROOT" && pwd -P)"' "$PROVISIONER" \
  && grep -qF 'EXPECTED_MARKETPLACE_ROOT="$(cd -P -- "$EXPECTED_MARKETPLACE_ROOT" && pwd -P)"' "$PROVISIONER" \
  && grep -qF '[ "$MARKETPLACE_ROOT" = "$EXPECTED_MARKETPLACE_ROOT" ]' "$PROVISIONER"; then
  check "Installed-plugin provisioning canonicalizes native Windows paths before identity comparison" PASS
else
  check "Installed-plugin provisioning canonicalizes native Windows paths before identity comparison" FAIL
fi

if grep -qF 'return fs.realpathSync.native(input);' "$INSTALL_CONTRACT" \
  && ! grep -qF 'return fs.realpathSync(input);' "$INSTALL_CONTRACT"; then
  check "Installed-plugin contract uses native canonical paths across MSYS and Windows spellings" PASS
else
  check "Installed-plugin contract uses native canonical paths across MSYS and Windows spellings" FAIL
fi

if grep -qF 'MINGW*|MSYS*|CYGWIN*) CONTEXT_PLUGIN_ROOT="$(cygpath -u "$CONTEXT_PLUGIN_ROOT")"' "$CLAUDE_WRAPPER" \
  && grep -qF 'CONTEXT_PLUGIN_ROOT="$(cd -P -- "$CONTEXT_PLUGIN_ROOT" && pwd -P)"' "$CLAUDE_WRAPPER" \
  && grep -qF '[ "$CONTEXT_PLUGIN_ROOT" = "$PLUGIN_ROOT" ]' "$CLAUDE_WRAPPER" \
  && grep -qF '|| [ "$CONTEXT_PLUGIN_ROOT" -ef "$PLUGIN_ROOT" ]' "$CLAUDE_WRAPPER"; then
  check "Claude wrapper canonicalizes native Session Control roots before shell comparison" PASS
else
  check "Claude wrapper canonicalizes native Session Control roots before shell comparison" FAIL
fi

if grep -qF 'const [coreFileInput, pluginRootInput, pluginDataInput, projectRootInput, sessionId] = process.argv.slice(2);' "$CLAUDE_WRAPPER" \
  && grep -qF 'const coreFile = fs.realpathSync.native(coreFileInput);' "$CLAUDE_WRAPPER" \
  && grep -qF 'const pluginRoot = fs.realpathSync.native(pluginRootInput);' "$CLAUDE_WRAPPER" \
  && grep -qF 'const pluginData = fs.realpathSync.native(pluginDataInput);' "$CLAUDE_WRAPPER" \
  && grep -qF 'const projectRoot = fs.realpathSync.native(projectRootInput);' "$CLAUDE_WRAPPER"; then
  check "Dedicated-evidence bootstrap canonicalizes MSYS argv before Core comparisons" PASS
else
  check "Dedicated-evidence bootstrap canonicalizes MSYS argv before Core comparisons" FAIL
fi

if grep -qF 'DEDICATED_EXACT_HOST=' "$CLAUDE_WRAPPER" \
  && grep -qF 'DEDICATED_SAFE_ROOT_HOST=' "$CLAUDE_WRAPPER" \
  && grep -qF 'DEDICATED_NONLISTED_HOST=' "$CLAUDE_WRAPPER" \
  && grep -qF 'PROJECT_ROOT_HOST=' "$CLAUDE_WRAPPER" \
  && grep -qF 'const canonical = (input, type) =>' "$CLAUDE_WRAPPER" \
  && grep -qF 'const resolved = fs.realpathSync.native(input);' "$CLAUDE_WRAPPER" \
  && grep -qF 'json_quote() {' "$CLAUDE_WRAPPER" \
  && grep -qF 'printf '\''%s'\'' "$1" | jq -bRs .' "$CLAUDE_WRAPPER" \
  && [ "$(grep -oF 'json_quote "$DEDICATED_EXACT_HOST"' "$CLAUDE_WRAPPER" | wc -l | tr -d ' ')" -eq 2 ] \
  && [ "$(grep -oF 'json_quote "$DEDICATED_SAFE_ROOT_HOST"' "$CLAUDE_WRAPPER" | wc -l | tr -d ' ')" -eq 4 ] \
  && [ "$(grep -oF 'json_quote "$DEDICATED_NONLISTED_HOST"' "$CLAUDE_WRAPPER" | wc -l | tr -d ' ')" -eq 2 ] \
  && [ "$(grep -oF 'json_quote "$PROJECT_ROOT_HOST"' "$CLAUDE_WRAPPER" | wc -l | tr -d ' ')" -eq 2 ] \
  && grep -qF 'SELFTEST_DEDICATED_EXACT_HOST="$DEDICATED_EXACT_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_DEDICATED_SAFE_ROOT_HOST="$DEDICATED_SAFE_ROOT_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_DEDICATED_NONLISTED_HOST="$DEDICATED_NONLISTED_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_PROJECT_ROOT_HOST="$PROJECT_ROOT_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'MSYS2_ENV_CONV_EXCL="$SELFTEST_HOST_PATH_ENV_EXCLUSIONS"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_PROJECT_ROOT_HOST=;SELFTEST_ATTACK_FILE_HOST=;SELFTEST_DEDICATED_EXACT_HOST=;SELFTEST_DEDICATED_NONLISTED_HOST=;SELFTEST_DEDICATED_SAFE_ROOT_HOST=;SELFTEST_MUTATING_CONTROL_CANARY_URL=' "$CLAUDE_WRAPPER" \
  && [ "$(grep -cF '"$DEDICATED_NONLISTED_HOST" "$PROJECT_ROOT_HOST" "$DEDICATED_ROLES"' "$CLAUDE_WRAPPER")" -eq 2 ] \
  && grep -qF 'SELFTEST_DEDICATED_EXACT_FS="$SELFTEST_DEDICATED_EXACT_HOST"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'SELFTEST_DEDICATED_EXACT_FS="$(cygpath -u "$SELFTEST_DEDICATED_EXACT_FS")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && awk '
    /^if \[ "\$SELFTEST_SCENARIO" = '\''live-dedicated-evidence-worker'\'' \] \\/ { dedicated=1 }
    dedicated && /SELFTEST_DEDICATED_EXACT_FS="\$SELFTEST_DEDICATED_EXACT_HOST"/ { assigned=1 }
    dedicated && /SELFTEST_DEDICATED_EXACT_FS="\$\(cygpath -u/ { converted=1 }
    /^elif / { exit(assigned && converted ? 0 : 1) }
    END { if (!assigned || !converted) exit 1 }
  ' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF '[ -f "$SELFTEST_DEDICATED_EXACT_FS" ]' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF '>>"$SELFTEST_DEDICATED_SAFE_ROOT_FS/source.txt"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'inputs="$(MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn --arg exact "$SELFTEST_DEDICATED_EXACT_HOST"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'denied_inputs="$(MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn --arg nonlisted "$SELFTEST_DEDICATED_NONLISTED_HOST"' "$CLAUDE_WRAPPER_SELFTEST" \
  && [ "$(grep -cF 'MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn --arg parent "$parent"' "$CLAUDE_WRAPPER_SELFTEST")" -eq 2 ] \
  && [ "$(grep -cF 'tool_payload="$(MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn' "$CLAUDE_WRAPPER_SELFTEST")" -eq 2 ] \
  && [ "$(grep -cF -- '--arg cwd "$SELFTEST_PROJECT_ROOT_HOST"' "$CLAUDE_WRAPPER_SELFTEST")" -eq 2 ] \
  && [ "$(grep -cF 'fs.realpathSync.native(exactFileInput)' "$LIVE_EVIDENCE")" -eq 2 ] \
  && [ "$(grep -cF 'fs.realpathSync.native(safeRootInput)' "$LIVE_EVIDENCE")" -eq 2 ] \
  && [ "$(grep -cF 'fs.realpathSync.native(nonlistedFileInput)' "$LIVE_EVIDENCE")" -eq 2 ] \
  && [ "$(grep -cF 'fs.realpathSync.native(projectRootInput)' "$LIVE_EVIDENCE")" -eq 3 ]; then
  check "Dedicated evidence uses one exact native path spelling across prompt, stub, gate, and verifier" PASS
else
  check "Dedicated evidence uses one exact native path spelling across prompt, stub, gate, and verifier" FAIL
fi

if grep -qF 'const dedicatedProjectCanonical = fs.realpathSync.native(dedicatedProject);' "$LIVE_EVIDENCE_NEGATIVE" \
  && grep -qF 'const dedicatedSafeCanonical = fs.realpathSync.native(dedicatedSafeRoot);' "$LIVE_EVIDENCE_NEGATIVE" \
  && grep -qF 'const dedicatedExactCanonical = fs.realpathSync.native(dedicatedExact);' "$LIVE_EVIDENCE_NEGATIVE" \
  && grep -qF 'const dedicatedNonlistedCanonical = fs.realpathSync.native(dedicatedNonlisted);' "$LIVE_EVIDENCE_NEGATIVE" \
  && grep -qF 'const project = fs.realpathSync.native(temporary);' "$LIVE_EVIDENCE_NEGATIVE"; then
  check "Live evidence fixtures use the verifier's native Windows path spelling" PASS
else
  check "Live evidence fixtures use the verifier's native Windows path spelling" FAIL
fi

if grep -qF 'CONCURRENT_WORKERS="1 2 3 4 5 6 7 8"' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF 'if [ "$IS_WINDOWS" = true ]; then' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF 'CONCURRENT_WORKERS="1 2"' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF 'EXPECTED_CONCURRENT_BUDGET=4' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF 'EXPECTED_CONCURRENT_OUTPUTS="3 4"' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && [ "$(grep -cF 'for worker in $CONCURRENT_WORKERS; do' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK")" -eq 4 ] \
  && grep -qF '2>"$ROOT/budget-worker-$worker.err"' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF '[ ! -s "$ROOT/budget-worker-$worker.err" ] || CONCURRENT_OK=false' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF '[ "$CONCURRENT_OUTPUTS" = "$EXPECTED_CONCURRENT_OUTPUTS" ]' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF 'value.stopBudget.count === $EXPECTED_CONCURRENT_BUDGET' <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK" \
  && grep -qF "sed 's/^/    worker stderr: /'" <<<"$AUTOPILOT_STATE_CONCURRENCY_BLOCK"; then
  check "Windows Autopilot concurrency tests bounded success and preserves worker diagnostics" PASS
else
  check "Windows Autopilot concurrency tests bounded success and preserves worker diagnostics" FAIL
fi

if grep -qF 'PROJECT_HOST_PATHS="$(node - "$PROJECT_ROOT"' "$CLAUDE_WRAPPER" \
  && grep -qF 'project_root: projectRoot,' "$CLAUDE_WRAPPER" \
  && grep -qF "attack_file: path.join(projectRoot, 'ATTACK.txt')," "$CLAUDE_WRAPPER" \
  && grep -qF 'ATTACK_FILE_HOST="$(printf '\''%s'\'' "$PROJECT_HOST_PATHS" | jq -ebr '\''.attack_file'\'')"' "$CLAUDE_WRAPPER" \
  && grep -qF 'json_quote "$ATTACK_FILE_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_PROJECT_ROOT_HOST="$PROJECT_ROOT_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_ATTACK_FILE_HOST="$ATTACK_FILE_HOST"' "$CLAUDE_WRAPPER" \
  && grep -qF 'project_root_host: process.env.SELFTEST_PROJECT_ROOT_HOST || "",' "$CLAUDE_WRAPPER" \
  && grep -qF 'attack_file_host: process.env.SELFTEST_ATTACK_FILE_HOST || "",' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_PROJECT_ROOT_HOST="$(jq -br '\''.project_root_host'\'' "$selftest_control")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'SELFTEST_ATTACK_FILE_HOST="$(jq -br '\''.attack_file_host'\'' "$selftest_control")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'write) attack="$(MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn --arg file "$SELFTEST_ATTACK_FILE_HOST"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'const projectRoot = fs.realpathSync.native(projectRootInput);' "$LIVE_EVIDENCE"; then
  check "Reviewer write evidence preserves one native attack path from prompt through verifier" PASS
else
  check "Reviewer write evidence preserves one native attack path from prompt through verifier" FAIL
fi

if awk '
  /git -C "\$PROJECT_ROOT" config core\.autocrlf false/ { configured = NR }
  /git -C "\$PROJECT_ROOT" add README\.md/ { added = NR }
  END { exit !(configured > 0 && added > configured) }
' "$CLAUDE_WRAPPER"; then
  check "Session Control fixture ignores ambient Windows CRLF conversion before its first git add" PASS
else
  check "Session Control fixture ignores ambient Windows CRLF conversion before its first git add" FAIL
fi

if grep -qF 'MUTATING_CONTROL_CANARY_URL="$(jq -ebr '\''.url'\'' "$CANARY_READY")"' "$CLAUDE_WRAPPER" \
  && grep -qF 'MUTATING_CONTROL_CANARY_ORIGIN="$(jq -ebr '\''.origin'\'' "$CANARY_READY")"' "$CLAUDE_WRAPPER" \
  && grep -qF 'MUTATING_CONTROL_CANARY_POLICY="$(MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn' "$CLAUDE_WRAPPER" \
  && grep -qF 'json_quote "$MUTATING_CONTROL_CANARY_URL"' "$CLAUDE_WRAPPER" \
  && grep -qF 'MSYS2_ENV_CONV_EXCL=ZENSU_VERIFY_NAVIGATION_POLICY_V1=' "$CLAUDE_WRAPPER" \
  && grep -qF 'MSYS2_ARG_CONV_EXCL='\''ZENSU_VERIFY_NAVIGATION_POLICY_V1='\'' \' "$CLAUDE_WRAPPER" \
  && grep -qF '"${CLAUDE_ENV[@]}" claude "${CLAUDE_ARGS[@]}" "$FULL_PROMPT"' "$CLAUDE_WRAPPER" \
  && grep -qF 'SELFTEST_MUTATING_CONTROL_CANARY_URL=' "$CLAUDE_WRAPPER" \
  && grep -qF 'attack="$(MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn --arg url "$SELFTEST_MUTATING_CONTROL_CANARY_URL"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'MSYS2_ARG_CONV_EXCL='\''*'\'' jq -cn --argjson block "$attack"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'MSYS2_ARG_CONV_EXCL='\''http://;https://'\'' node -e' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'MSYS2_ARG_CONV_EXCL='\''http://;https://'\'' node "$EVIDENCE" reviewer-attack' "$CLAUDE_WRAPPER" \
  && grep -qF '"MSYS2_ENV_CONV_EXCL=ZENSU_VERIFY_NAVIGATION_POLICY_V1="' "$PLAYWRIGHT_MCP" \
  && grep -qF 'local arg_conv_excl="$1"' "$PLAYWRIGHT_MCP" \
  && grep -qF 'env_args+=( "MSYS2_ARG_CONV_EXCL=$arg_conv_excl" )' "$PLAYWRIGHT_MCP" \
  && grep -qF 'POLICY_PROXY_HOST="$(cygpath -am "$PROXY")"' "$PLAYWRIGHT_MCP" \
  && grep -qF 'POLICY_RUNTIME_DIR_HOST="$(cygpath -am "$RUNTIME_DIR")"' "$PLAYWRIGHT_MCP" \
  && grep -qF "run_sanitized_child '*' node \"\$POLICY_PROXY_HOST\"" "$PLAYWRIGHT_MCP" \
  && grep -qF "test('launcher check-policy subprocess pins parent mode, origin, route, and evidence mode', () => {" "$PLAYWRIGHT_MCP_TEST"; then
  check "Mutating-control URL and policy survive jq plus both sanitized MSYS environment boundaries" PASS
else
  check "Mutating-control URL and policy survive jq plus both sanitized MSYS environment boundaries" FAIL
fi

if grep -qF "MSYS2_ARG_CONV_EXCL='*' node -e" "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'value="${value%$'\''\r'\''}"' <<<"$CLAUDE_STUB_BLOCK" \
  && grep -qF "done < <(jq -br '.flags | to_entries[] | [.key, (.value | tostring)] | @tsv' \"\$selftest_control\")" <<<"$CLAUDE_STUB_BLOCK" \
  && ! grep -Eq 'jq -(e)?r([[:space:]]|$)' <<<"$CLAUDE_STUB_BLOCK" \
  && grep -qF 'match = text.match(/^\[zensu-host-context\]' <<<"$CLAUDE_STUB_BLOCK" \
  && grep -qF 'match = text.match(/^\[zensu-reviewer-context\]' <<<"$CLAUDE_STUB_BLOCK" \
  && ! grep -qF 'core.renderReviewerContext' <<<"$CLAUDE_STUB_BLOCK" \
  && ! grep -qF 'core.renderHostContext' <<<"$CLAUDE_STUB_BLOCK" \
  && grep -qF 'marker_fs="$review_project/.session-control-eval/${review_digest#sha256:}/$review_principal/context.json"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'review_plugin_fs="$review_plugin"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'marker_fs="$(cygpath -u "$marker_fs")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'review_plugin_fs="$(cygpath -u "$review_plugin_fs")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'marker="$(cygpath -am "$marker_fs")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF '[ ! -f "$marker_fs" ] || review_content="$(cat "$marker_fs")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF -- '--arg root "$review_plugin_fs" --arg digest "$review_digest"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'marker_fs="$neutral_project/.session-control-eval/${neutral_digest#sha256:}/$neutral_principal/neutral-context.json"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF '[ ! -f "$marker_fs" ] || context_content="$(cat "$marker_fs")"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'generic_worktree_fs="$SELFTEST_GENERIC_WORKTREE"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'generic_marker_fs="$SELFTEST_GENERIC_MARKER"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'marker_fs="$generic_worktree_fs/.session-control-eval/${host_digest#sha256:}/$host_principal/neutral-context.json"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF '[ "$marker_fs" = "$generic_marker_fs" ] || exit 34' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF '[ ! -f "$marker_fs" ] || marker_content="$(cat "$marker_fs")"' "$CLAUDE_WRAPPER_SELFTEST"; then
  check "Claude wrapper selftest protects inline context parsing and separates native evidence from MSYS filesystem paths" PASS
else
  check "Claude wrapper selftest protects inline context parsing and separates native evidence from MSYS filesystem paths" FAIL
fi

if grep -qF 'TEMPORARY="$(mktemp -d -t zsc-XXXXXX)"' "$CLAUDE_WRAPPER" \
  && grep -qF 'PROJECT_ROOT="$TEMPORARY/p"' "$CLAUDE_WRAPPER" \
  && grep -qF 'PLUGIN_DATA="$TEMPORARY/d"' "$CLAUDE_WRAPPER" \
  && grep -qF 'CONTROL_EVIDENCE="$TEMPORARY/c"' "$CLAUDE_WRAPPER" \
  && grep -qF 'GENERIC_WORKTREE="$TEMPORARY/w"' "$CLAUDE_WRAPPER" \
  && grep -qF 'git -C "$PROJECT_ROOT" config core.longpaths true' "$CLAUDE_WRAPPER" \
  && ! grep -qF 'zensu-session-control-claude-XXXXXX' "$CLAUDE_WRAPPER" \
  && ! grep -qF 'external-review-worktree' "$CLAUDE_WRAPPER"; then
  check "Claude wrapper keeps digest-bound Windows fixture paths short and enables repo-local long paths" PASS
else
  check "Claude wrapper keeps digest-bound Windows fixture paths short and enables repo-local long paths" FAIL
fi

if grep -qF 'TEMPORARY="$(mktemp -d -t zsw-XXXXXX)"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'ISOLATED_HOME="$TEMPORARY/h"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'mkdir -p "$TEMPORARY/b"' "$CLAUDE_WRAPPER_SELFTEST" \
  && grep -qF 'selftest_control="$(dirname "$CLAUDE_PLUGIN_DATA")/c/stub-control.json"' "$CLAUDE_WRAPPER_SELFTEST" \
  && ! grep -qF 'zensu-session-wrapper-selftest-XXXXXX' "$CLAUDE_WRAPPER_SELFTEST" \
  && ! grep -qF '$TEMPORARY/isolated-home' "$CLAUDE_WRAPPER_SELFTEST" \
  && ! grep -qF '$TEMPORARY/bin' "$CLAUDE_WRAPPER_SELFTEST"; then
  check "Claude wrapper selftest keeps its installed-cache fixture below the Windows path budget" PASS
else
  check "Claude wrapper selftest keeps its installed-cache fixture below the Windows path budget" FAIL
fi

LOCKED_RUN_BODY="$(sed -n '/^_tdd_locked_run() {$/,/^}$/p' "$PHASE")"
LOCK_KEEPER_BODY="$(sed -n '/^_tdd_core_lock_keeper() {$/,/^}$/p' "$PHASE")"
if printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'coproc $coproc_name' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'BASH_VERSINFO[0]' \
  && printf '%s\n' "$LOCK_KEEPER_BODY" | grep -qF 'ownerPid: process.pid' \
  && printf '%s\n' "$LOCK_KEEPER_BODY" | grep -qF 'fs.readFileSync(0, "utf8")' \
  && printf '%s\n' "$LOCK_KEEPER_BODY" | grep -qF 'command !== "RELEASE\n"'; then
  check "Bash 4+ holds each Core lease in one live keeper process" PASS
else
  check "Bash 4+ holds each Core lease in one live keeper process" FAIL
fi

if printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'process.argv.slice(1)' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -Eq 'process\.env\.(CONTROL_CORE|LOCK_DIRECTORY|RESOURCE_PATH|TOKEN_FILE)' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'token: process.env.LOCK_TOKEN' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -q '"\$token" >/dev/null'; then
  check "Core lease paths use argv while its token stays off the command line" PASS
else
  check "Core lease paths use argv while its token stays off the command line" FAIL
fi

if printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF '[[ "$token" =~ ^[a-f0-9]{48}$ ]]' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'rm -f -- "$token_file"' \
  && grep -qF 'release_token_digest' "$CORE" \
  && grep -qF 'crypto.timingSafeEqual' "$CORE"; then
  check "Release capability is validated, hashed at rest, and its handoff is removed early" PASS
else
  check "Release capability is validated, hashed at rest, and its handoff is removed early" FAIL
fi

if printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'sameIdentity(before, opened)' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'opened.nlink !== 1' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'sameIdentity(afterDescriptor, afterPath)' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'fs.constants.O_TRUNC'; then
  check "Windows token open proves identity before truncate without unsupported O_NOFOLLOW" PASS
else
  check "Windows token open proves identity before truncate without unsupported O_NOFOLLOW" FAIL
fi

if printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF '[zensu-tdd-phase] lock detail:' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF '[zensu-tdd-phase] lock release detail:' \
  && printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF '.slice(0, 512)' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'zensu-tdd-lock-error' \
  && ! printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'lock_error="$(node'; then
  check "Lease diagnostics use bounded stderr without a pathname or subshell" PASS
else
  check "Lease diagnostics use bounded stderr without a pathname or subshell" FAIL
fi

if printf '%s\n' "$LOCKED_RUN_BODY" | grep -qF 'releaseExternalProcessLockByToken' \
  && grep -qF 'function releaseExternalProcessLockByToken(options)' "$CORE" \
  && grep -qF 'releaseExternalProcessLockByToken,' "$CORE"; then
  check "Cross-process lease release uses the token capability" PASS
else
  check "Cross-process lease release uses the token capability" FAIL
fi

if ! grep -Fq "require('\$ROOT/" "$ROOT/evals/session-control/run-self-check.sh" \
  && ! grep -Fq "require('\$ROOT/" "$ROOT/evals/session-control/run-eval.sh" \
  && grep -qF 'canonical_node_path' "$SESSION"; then
  check "Session Control evals and assertions pass filesystem paths through argv" PASS
else
  check "Session Control evals and assertions pass filesystem paths through argv" FAIL
fi

if grep -qF 'cd -P -- "$ROOT"' "$SESSION_HOOK" \
  && grep -qF 'exec node ./hooks/lib/claude-session-control-v1.js' "$SESSION_HOOK" \
  && grep -qF 'unset CLAUDE_PLUGIN_ROOT PLUGIN_ROOT ZENSU_PLUGIN_ROOT' "$SESSION_HOOK"; then
  check "SessionStart launches Node relatively after validating shell-side roots" PASS
else
  check "SessionStart launches Node relatively after validating shell-side roots" FAIL
fi

if grep -qF "process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)" "$CORE" \
  && grep -qF 'pathBefore && !sameFileIdentity(pathBefore, before)' "$CORE" \
  && [ "$(printf '%s\n' "$CORE_SNAPSHOT_BLOCK" \
    | grep -cF 'if (error.code === '\''ENOENT'\'') fail(`missing file: ${file}`);')" -eq 2 ] \
  && grep -qF "const context = core.readContext({ recordsDir, sessionId: payload.session_id, expectedHost: 'claude' });" "$BINDER" \
  && grep -qF 'recordStat.isSymbolicLink() || !recordStat.isFile() || recordStat.nlink !== 1' "$BINDER"; then
  check "Session Control brackets Windows opens with path and descriptor identity" PASS
else
  check "Session Control brackets Windows opens with path and descriptor identity" FAIL
fi

if [ "$(grep -cF 'const noFollow = process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' "$AUTOPILOT_STATE")" -eq 3 ] \
  && [ "$(grep -cF 'fs.openSync(file, fs.constants.O_RDONLY | noFollow)' "$AUTOPILOT_STATE")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(target, fs.constants.O_RDONLY | noFollow)' "$AUTOPILOT_STATE")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(temp, fs.constants.O_RDONLY | noFollow)' "$AUTOPILOT_STATE")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(source, fs.constants.O_RDONLY | noFollow)' "$AUTOPILOT_STATE")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(temp, fs.constants.O_WRONLY | noFollow)' "$AUTOPILOT_STATE")" -eq 1 ] \
  && ! grep -qF '| (fs.constants.O_NOFOLLOW || 0)' "$AUTOPILOT_STATE"; then
  check "Autopilot secure opens omit unsupported O_NOFOLLOW on Windows" PASS
else
  check "Autopilot secure opens omit unsupported O_NOFOLLOW on Windows" FAIL
fi

# The plan-payload reader is the same hardened-open pattern in a requireable
# module. It belongs in this inventory because every count pin above is
# per-file and therefore blind to a NEW file carrying a secure open.
# The flag is resolved in one place, and the seam that reaches the
# O_NOFOLLOW-unavailable branch must stay a MODE selector: were the second
# argument OR-ed into the open flags, a caller could widen the open on the very
# platform this pin exists for.
if [ "$(grep -cF 'process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' "$PLAN_PAYLOAD")" -eq 1 ] \
  && [ "$(grep -cF 'const noFollow = openMode === LSTAT_PRECHECK_MODE ? 0 : platformNoFollow();' "$PLAN_PAYLOAD")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(planPath, fs.constants.O_RDONLY | noFollow | nonBlock)' "$PLAN_PAYLOAD")" -eq 1 ] \
  && [ "$(grep -cF 'const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;' "$PLAN_PAYLOAD")" -eq 1 ] \
  && grep -qF 'before.dev !== stat.dev || before.ino !== stat.ino' "$PLAN_PAYLOAD" \
  && grep -qF 'stat.nlink !== 1' "$PLAN_PAYLOAD" \
  && ! grep -qF '| (fs.constants.O_NOFOLLOW || 0)' "$PLAN_PAYLOAD" \
  && ! grep -qE 'noFollow[^=]*= *openMode[^?]*$' "$PLAN_PAYLOAD"; then
  check "plan-payload reader omits unsupported O_NOFOLLOW on Windows" PASS
else
  check "plan-payload reader omits unsupported O_NOFOLLOW on Windows" FAIL
fi

# The best-solution-first rule reader is the third file carrying a hardened open,
# and it is enrolled here for the reason stated above: every count pin in this
# suite is per-file, so a NEW file carrying a secure open is invisible until it is
# named. It deliberately omits the reference's `nlink !== 1` clause — its path is
# fixed under the executing plugin root rather than payload-named, so a hard link
# is not a way to reach a file the symlink check refuses, and refusing one would
# silently disable the rule on any install that materializes files by hard link.
# That omission is pinned as a negative so it cannot be reintroduced by accident.
if [ "$(grep -cF 'process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' "$BEST_SOLUTION_HOOK")" -eq 1 ] \
  && [ "$(grep -cF 'const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;' "$BEST_SOLUTION_HOOK")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(rulePath, fs.constants.O_RDONLY | noFollow | nonBlock)' "$BEST_SOLUTION_HOOK")" -eq 1 ] \
  && grep -qF 'post.dev !== pre.dev || post.ino !== pre.ino' "$BEST_SOLUTION_HOOK" \
  && ! grep -qF '| (fs.constants.O_NOFOLLOW || 0)' "$BEST_SOLUTION_HOOK" \
  && ! grep -qF 'fs.constants.O_NOFOLLOW || 0' "$BEST_SOLUTION_HOOK" \
  && ! grep -v '^[[:space:]]*//' "$BEST_SOLUTION_HOOK" | grep -qF 'nlink'; then
  check "best-solution-first reader omits unsupported O_NOFOLLOW on Windows" PASS
else
  check "best-solution-first reader omits unsupported O_NOFOLLOW on Windows" FAIL
fi

# The evidence-discipline carrier is the fourth file carrying a hardened open. It read its
# rule file with a plain readFileSync behind the shell pre-check alone until the reader was
# backported from the sibling above; it is enrolled here for the same reason the sibling is,
# because every count pin in this suite is per-file and a NEW file carrying a secure open is
# invisible until it is named. The literals are deliberately IDENTICAL to the sibling's — the
# two readers are one reader in two carriers, and a divergence in either is a divergence in
# the pattern. It omits the reference's `nlink !== 1` clause for the same reason and that
# omission is pinned as a negative so it cannot be reintroduced by accident.
if [ "$(grep -cF 'process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' "$EVIDENCE_DISCIPLINE_HOOK")" -eq 1 ] \
  && [ "$(grep -cF 'const nonBlock = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;' "$EVIDENCE_DISCIPLINE_HOOK")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(rulePath, fs.constants.O_RDONLY | noFollow | nonBlock)' "$EVIDENCE_DISCIPLINE_HOOK")" -eq 1 ] \
  && grep -qF 'post.dev !== pre.dev || post.ino !== pre.ino' "$EVIDENCE_DISCIPLINE_HOOK" \
  && ! grep -qF '| (fs.constants.O_NOFOLLOW || 0)' "$EVIDENCE_DISCIPLINE_HOOK" \
  && ! grep -qF 'fs.constants.O_NOFOLLOW || 0' "$EVIDENCE_DISCIPLINE_HOOK" \
  && ! grep -v '^[[:space:]]*//' "$EVIDENCE_DISCIPLINE_HOOK" | grep -qF 'nlink'; then
  check "evidence-discipline reader omits unsupported O_NOFOLLOW on Windows" PASS
else
  check "evidence-discipline reader omits unsupported O_NOFOLLOW on Windows" FAIL
fi

# The pattern only holds if the two carriers keep the SAME reader. Comparing the extracted
# blocks catches a one-sided edit that leaves both per-file pins above green — each of them
# only asserts that its own file still satisfies the shape, never that the two agree.
# Starts one line BELOW `const rulePath = …`, which is the only line the two legitimately
# differ on — each names its own rule-file variable.
#
# MAX_FILE and MAX_BLOCK are compared SEPARATELY because both are declared above that start
# line, outside the extracted body, and every per-file structural pin greps `const MAX_FILE =`
# without its value. Without those comparisons one carrier's ceiling could be changed to any
# number with every check in the tree still green. The two bound different things: MAX_FILE the
# file, MAX_BLOCK the single line that is actually injected.
#
# The range ENDS on the enforcement rather than on the `finally` brace so the comparison covers
# the hardened reader, the marker-position parse AND the bound's use. It ended at the brace
# once, and a probe confirmed the cost: with the enforcement deleted from the evidence carrier
# this suite still reported 41 PASS / 0 FAIL. That gap was Windows-PR-shard only —
# `test-evidence-discipline.sh` is absent from tests/profiles/windows-ci.v1.json, so it never
# runs on the Windows PR shard, but it IS in `ciStructureTests` (pinned by M1 in that suite),
# which tests/run-windows-safety-shard.js maps into the weekly Windows Safety structure shards,
# and tests/profiles/windows-native-structure.v1.json records that as the reason for the PR-gate
# exclusion. On POSIX `tests/run-all.sh` globs every structure suite, so H4e caught it there.
#
# Where the range deliberately STOPS: everything below the enforcement — the directive text and
# the emission — legitimately differs per carrier and is covered behaviourally instead, by
# test-evidence-discipline.sh H5-H7 and test-best-solution-first.sh B3a/B3b (the directive
# text) plus B3c (the emitted object shape).
#
# TRADE, stated because it is easy to miss: comment stripping runs before range selection, so
# comment TEXT inside the range is no longer compared. Three in-range comment blocks used to be
# byte-identical across the carriers and a one-sided edit to any of them used to fail this
# check; it no longer does. The equality now DEPENDS on the strip — the two carriers' in-range
# comments are deliberately different lengths.
#
# The end address is a SUBSTRING match, so a trailing `// … block.length > MAX_BLOCK …` on a
# code line survives the full-line strip and truncates the range there. Added to BOTH carriers
# that keeps the bodies equal and satisfies a mere `grep` for the needle — a probe confirmed it:
# both enforcements deleted plus that comment gave 41 PASS / 0 FAIL again. The LAST-LINE
# assertions below are what close it: a truncated body ends on the comment line, not on the
# enforcement statement, so the equality can no longer stand in for coverage.
extract_reader() {
  grep -v '^[[:space:]]*//' "$1" \
    | sed -n '/const pre = fs.lstatSync(rulePath);/,/block.length > MAX_BLOCK/p'
}
extract_max_file() {
  grep -F 'const MAX_FILE =' "$1" | grep -v '^[[:space:]]*//' | head -1 | tr -d '[:space:]'
}
extract_max_block() {
  grep -F 'const MAX_BLOCK =' "$1" | grep -v '^[[:space:]]*//' | head -1 | tr -d '[:space:]'
}
# Uniqueness counts, because every extractor above is steerable. `head -1` takes the FIRST
# spelling and the sed range ends on the FIRST match of an unanchored substring, so a SECOND
# declaration or enforcement placed above the real one — in a `/* */` block the full-line `//`
# filter does not match, in dead code, or in a string — drives all three while the real code
# below is free to change. That includes the shadow zone between `const rulePath` and
# `const pre`, which is inside the hook's `try` and therefore a legal place to rebind the value
# the enforcement reads.
#
# What these counts do NOT cover, stated rather than implied: they match a declaration keyword
# followed by the name, so a rebinding spelled some other way still slips past, and they count
# per line. The residue is closed BEHAVIOURALLY, not here — test-evidence-discipline.sh H10d and
# test-best-solution-first.sh B7g drive each real hook against an oversized block. A probe
# confirmed the split: a `let MAX_BLOCK = 999999999;` shadow on both carriers left this suite at
# 42 PASS / 0 FAIL while H10d went red.
count_decl() { grep -v '^[[:space:]]*//' "$1" | grep -cE "(^|[^A-Za-z0-9_])(const|let|var)[[:space:]]+$2[[:space:]]*="; }
count_literal() { grep -v '^[[:space:]]*//' "$1" | grep -oF "$2" | grep -c .; }
strip_indent() { printf '%s' "${1#"${1%%[![:space:]]*}"}"; }
# Compared without indentation on purpose: an identical reindent of both embedded JS bodies is
# semantically empty and must not render as "the carriers diverged".
ENFORCE_STMT='if (!block || block.length > MAX_BLOCK) process.exit(0);'
BSF_READER="$(extract_reader "$BEST_SOLUTION_HOOK")"
EVD_READER="$(extract_reader "$EVIDENCE_DISCIPLINE_HOOK")"
BSF_MAX_FILE="$(extract_max_file "$BEST_SOLUTION_HOOK")"
EVD_MAX_FILE="$(extract_max_file "$EVIDENCE_DISCIPLINE_HOOK")"
BSF_MAX_BLOCK="$(extract_max_block "$BEST_SOLUTION_HOOK")"
EVD_MAX_BLOCK="$(extract_max_block "$EVIDENCE_DISCIPLINE_HOOK")"
BSF_LAST="$(strip_indent "$(printf '%s\n' "$BSF_READER" | tail -1)")"
EVD_LAST="$(strip_indent "$(printf '%s\n' "$EVD_READER" | tail -1)")"
BSF_ENF_N="$(count_literal "$BEST_SOLUTION_HOOK" 'block.length > MAX_BLOCK')"
EVD_ENF_N="$(count_literal "$EVIDENCE_DISCIPLINE_HOOK" 'block.length > MAX_BLOCK')"
BSF_BDECL_N="$(count_decl "$BEST_SOLUTION_HOOK" MAX_BLOCK)"
EVD_BDECL_N="$(count_decl "$EVIDENCE_DISCIPLINE_HOOK" MAX_BLOCK)"
BSF_FDECL_N="$(count_decl "$BEST_SOLUTION_HOOK" MAX_FILE)"
BSF_MAX_BLOCK_N="$(printf '%s' "$BSF_MAX_BLOCK" | sed -n 's/.*=\([0-9]*\);*$/\1/p')"
EVD_MAX_BLOCK_N="$(printf '%s' "$EVD_MAX_BLOCK" | sed -n 's/.*=\([0-9]*\);*$/\1/p')"
EVD_FDECL_N="$(count_decl "$EVIDENCE_DISCIPLINE_HOOK" MAX_FILE)"
# Named arms, not one conjunction: several of these can fail with the two carriers byte-identical,
# and "the carriers diverged" would then name a fault that did not occur. Absence is split from
# duplication throughout, because 0 and 2 have opposite causes and opposite remedies. The two
# range-end arms run BEFORE the guarded-close arm: a truncated range must be reported as a range
# fault, not as missing content that the truncation merely pushed out of scope.
if [ -z "$BSF_READER" ] || [ -z "$EVD_READER" ]; then
  check "a carrier's reader body could not be extracted (bsf=${#BSF_READER}B evd=${#EVD_READER}B) — the range start moved" FAIL
elif [ "$BSF_ENF_N" -eq 0 ] || [ "$EVD_ENF_N" -eq 0 ]; then
  check "the enforcement is absent from a carrier (bsf=$BSF_ENF_N evd=$EVD_ENF_N) — the bound is no longer applied" FAIL
elif [ "$BSF_ENF_N" -ne 1 ] || [ "$EVD_ENF_N" -ne 1 ]; then
  check "the enforcement literal is duplicated (bsf=$BSF_ENF_N evd=$EVD_ENF_N) — a second copy steers the extracted range" FAIL
elif [ "$BSF_BDECL_N" -ne 1 ] || [ "$EVD_BDECL_N" -ne 1 ]; then
  check "MAX_BLOCK is not declared exactly once (bsf=$BSF_BDECL_N evd=$EVD_BDECL_N) — 0 removes the bound, 2 shadows it past head -1" FAIL
elif [ "$BSF_FDECL_N" -ne 1 ] || [ "$EVD_FDECL_N" -ne 1 ]; then
  check "MAX_FILE is not declared exactly once (bsf=$BSF_FDECL_N evd=$EVD_FDECL_N) — 0 removes the bound, 2 shadows it past head -1" FAIL
elif [ "$BSF_LAST" != "$ENFORCE_STMT" ]; then
  check "the best-solution-first reader range no longer ends on the enforcement (ends on [${BSF_LAST}])" FAIL
elif [ "$EVD_LAST" != "$ENFORCE_STMT" ]; then
  check "the evidence-discipline reader range no longer ends on the enforcement (ends on [${EVD_LAST}])" FAIL
elif ! printf '%s\n' "$BSF_READER" | grep -qF 'fs.closeSync(fd)'; then
  check "the shared reader lost its guarded close" FAIL
elif [ "$BSF_READER" != "$EVD_READER" ]; then
  check "the two marker-block carriers' reader bodies differ (bsf=${#BSF_READER}B evd=${#EVD_READER}B)" FAIL
elif [ -z "$BSF_MAX_FILE" ] || [ "$BSF_MAX_FILE" != "$EVD_MAX_FILE" ]; then
  check "MAX_FILE differs between the carriers (bsf=${BSF_MAX_FILE:-none} evd=${EVD_MAX_FILE:-none})" FAIL
elif [ -z "$BSF_MAX_BLOCK" ] || [ "$BSF_MAX_BLOCK" != "$EVD_MAX_BLOCK" ]; then
  check "MAX_BLOCK differs between the carriers (bsf=${BSF_MAX_BLOCK:-none} evd=${EVD_MAX_BLOCK:-none})" FAIL
else
  check "both marker-block carriers share one hardened reader body" PASS
fi

# The review ceilings are the second thing the two carriers must keep in step. What must match is
# the intended HEADROOM, and it is compared as a DECLARED CONSTANT in each suite — deliberately
# NOT as ceiling-minus-live-block. That earlier shape reduced algebraically to a constraint on the
# two prose documents' length difference that no file states: a one-character edit to either rule
# text, well inside its own ceiling, turned this suite red while the owning suite correctly
# accepted it. Measured, not assumed — 88 against 89 on a single added character. A ceiling is a
# budget the block may grow into; pinning it to the block would make that budget unreachable.
suite_const() { sed -n "s/^$2=\([0-9]*\).*/\1/p" "$1" | head -1; }
suite_const_n() { grep -c "^$2=" "$1"; }
HDR_BSF_SUITE="$ROOT/tests/structure/test-best-solution-first.sh"
HDR_EVD_SUITE="$ROOT/tests/structure/test-evidence-discipline.sh"
HDR_BSF_H="$(suite_const "$HDR_BSF_SUITE" REVIEW_HEADROOM)"
HDR_EVD_H="$(suite_const "$HDR_EVD_SUITE" REVIEW_HEADROOM)"
HDR_BSF_C="$(suite_const "$HDR_BSF_SUITE" REVIEW_CEILING)"
HDR_EVD_C="$(suite_const "$HDR_EVD_SUITE" REVIEW_CEILING)"
HDR_N="$(( $(suite_const_n "$HDR_BSF_SUITE" REVIEW_HEADROOM) + $(suite_const_n "$HDR_EVD_SUITE" REVIEW_HEADROOM) + $(suite_const_n "$HDR_BSF_SUITE" REVIEW_CEILING) + $(suite_const_n "$HDR_EVD_SUITE" REVIEW_CEILING) ))"
if [ -z "$HDR_BSF_H" ] || [ -z "$HDR_EVD_H" ] || [ -z "$HDR_BSF_C" ] || [ -z "$HDR_EVD_C" ]; then
  check "a review-ceiling constant could not be resolved (headroom bsf=${HDR_BSF_H:-none} evd=${HDR_EVD_H:-none}; ceiling bsf=${HDR_BSF_C:-none} evd=${HDR_EVD_C:-none})" FAIL
elif [ "$HDR_N" -ne 4 ]; then
  check "the review-ceiling constants are not declared exactly once each (4 expected, $HDR_N found) — head -1 would read a decoy while the suite uses the last assignment" FAIL
elif [ "$HDR_BSF_H" != "$HDR_EVD_H" ]; then
  check "the declared review headroom differs (bsf=$HDR_BSF_H evd=$HDR_EVD_H) — the criterion is absolute headroom, identical on both carriers, not a ratio" FAIL
elif [ -z "$BSF_MAX_BLOCK_N" ] || [ -z "$EVD_MAX_BLOCK_N" ]; then
  check "a carrier's MAX_BLOCK value is not a bare integer (bsf=${BSF_MAX_BLOCK:-none} evd=${EVD_MAX_BLOCK:-none}) — the ceiling comparison cannot run, and an unguarded -ge would fall through to PASS" FAIL
elif [ "$HDR_BSF_C" -ge "$BSF_MAX_BLOCK_N" ] || [ "$HDR_EVD_C" -ge "$EVD_MAX_BLOCK_N" ]; then
  check "a review ceiling is not below its MAX_BLOCK fail-safe (bsf $HDR_BSF_C vs $BSF_MAX_BLOCK_N; evd $HDR_EVD_C vs $EVD_MAX_BLOCK_N) — the tripwire would be inert" FAIL
else
  check "both carriers declare the same review headroom ($HDR_BSF_H chars) below their MAX_BLOCK fail-safe" PASS
fi

if [ "$(grep -cF 'process.platform!=="win32"&&Number.isInteger(fs.constants.O_NOFOLLOW)?fs.constants.O_NOFOLLOW:0' "$VCS")" -eq 10 ] \
  && ! grep -qF 'O_RDONLY|(fs.constants.O_NOFOLLOW||0)' "$VCS" \
  && ! grep -qF 'O_WRONLY|(fs.constants.O_NOFOLLOW||0)' "$VCS" \
  && grep -qF 'opened.dev!==before.dev||opened.ino!==before.ino' "$VCS" \
  && grep -qF 'targetOpened.dev!==target.dev||targetOpened.ino!==target.ino' "$VCS"; then
  check "VCS secure opens keep identity brackets with a Windows-safe flag" PASS
else
  check "VCS secure opens keep identity brackets with a Windows-safe flag" FAIL
fi

if grep -qF "process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)" "$RESET_SNAPSHOT" \
  && grep -qF 'opened.dev !== before.dev' "$RESET_SNAPSHOT" \
  && grep -qF 'final.dev !== opened.dev' "$RESET_SNAPSHOT" \
  && grep -qF "throw new Error('file changed while reading')" "$RESET_SNAPSHOT"; then
  check "reset eval snapshots use a Windows-safe identity-bracketed read" PASS
else
  check "reset eval snapshots use a Windows-safe identity-bracketed read" FAIL
fi

if [ "$(grep -cF 'const noFollow=process.platform!=="win32"&&Number.isInteger(fs.constants.O_NOFOLLOW)?fs.constants.O_NOFOLLOW:0;' "$AUTOPILOT_FULL")" -eq 3 ] \
  && [ "$(grep -cF 'fs.constants.O_EXCL|noFollow' "$AUTOPILOT_FULL")" -eq 3 ] \
  && ! grep -qF 'fs.constants.O_EXCL|(fs.constants.O_NOFOLLOW||0)' "$AUTOPILOT_FULL"; then
  check "Autopilot full-cycle fixtures omit unsupported O_NOFOLLOW on Windows" PASS
else
  check "Autopilot full-cycle fixtures omit unsupported O_NOFOLLOW on Windows" FAIL
fi

if grep -qF "process.platform !== 'win32' && Number.isInteger(fs.constants.O_NOFOLLOW)" "$ENRICHMENT" \
  && grep -qF 'info.dev === opened.dev && info.ino === opened.ino' "$ENRICHMENT" \
  && ! grep -qF 'fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW' "$ENRICHMENT"; then
  check "Claude enrichment reads use a Windows-safe identity bracket" PASS
else
  check "Claude enrichment reads use a Windows-safe identity bracket" FAIL
fi

if grep -qF 'process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' "$PROMPTFOO_WRAPPER" \
  && grep -qF 'fs.constants.O_CREAT | fs.constants.O_EXCL | noFollow' "$PROMPTFOO_WRAPPER" \
  && grep -qF 'fs.ftruncateSync(fd, 0);' "$PROMPTFOO_WRAPPER" \
  && ! grep -qF 'fs.constants.O_TRUNC' "$PROMPTFOO_WRAPPER"; then
  check "Promptfoo hook log proves identity before truncating on Windows" PASS
else
  check "Promptfoo hook log proves identity before truncating on Windows" FAIL
fi

printf '%s\n' '----' "test-windows-portability-guards: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
