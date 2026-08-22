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
ARTIFACT_REDACT="$ROOT/hooks/lib/zensu-artifact-redact-v1.js"
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
PASS=0; FAIL=0
check() {
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

# The artifact redactor is the third requireable module carrying a hardened
# open, and it is enrolled here for the same reason the plan-payload reader is:
# every count pin in this file is per-file, so a NEW file with a secure open is
# invisible to all of them. It carries THREE descriptor-judged opens of the
# artifact — the read in redactFile, the append in writeArtifactLine, and the
# read that validates the target before replaceArtifactFile publishes by rename —
# and all three fstat the DESCRIPTOR, which is what makes the symlink and
# hard-link refusals unraceable. The third arrived when `replace` stopped
# truncating in place: an ftruncate commits the destroy before the new bytes
# exist, so that mode now writes an O_EXCL temp and renames, and the counts below
# moved with it. The absent O_TRUNC is still part of the contract: truncating at
# open would run BEFORE the nlink check could refuse a hard link. The dev/ino
# comparison and the pre-rename re-stat are pinned here for
# the same reason the opens are: its REJECT direction is a race no behavioral
# suite can stage, so the structural pin is the only place it can be held.
#
# `fs.fstatSync(fd)` is FOUR, not three: writeArtifactLine fstats a second time
# AFTER its write, because a rename landing between the checks and the write
# sends the line to an orphaned inode and the old spelling reported that as
# success. That call site is asserted separately below, so raising the count
# alone cannot satisfy this check.
if [ "$(grep -cF 'process.platform !== "win32" && Number.isInteger(fs.constants.O_NOFOLLOW)' "$ARTIFACT_REDACT")" -eq 1 ] \
  && [ "$(grep -cF 'const NON_BLOCK = Number.isInteger(fs.constants.O_NONBLOCK) ? fs.constants.O_NONBLOCK : 0;' "$ARTIFACT_REDACT")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(target.path, fs.constants.O_RDONLY | noFollow | NON_BLOCK)' "$ARTIFACT_REDACT")" -eq 1 ] \
  && [ "$(grep -cF 'fs.openSync(target.path, fs.constants.O_RDONLY | platformNoFollow() | NON_BLOCK)' "$ARTIFACT_REDACT")" -eq 1 ] \
  && [ "$(grep -cF '| platformNoFollow() | NON_BLOCK' "$ARTIFACT_REDACT")" -eq 2 ] \
  && [ "$(grep -cF 'fs.fstatSync(fd)' "$ARTIFACT_REDACT")" -eq 4 ] \
  && [ "$(grep -cF '!sameInode(fs.fstatSync(fd), target)' "$ARTIFACT_REDACT")" -eq 1 ] \
  && [ "$(grep -cF 'stat.nlink !== 1' "$ARTIFACT_REDACT")" -eq 3 ] \
  && [ "$(grep -cF '!sameInode(stat, target)' "$ARTIFACT_REDACT")" -eq 3 ] \
  && [ "$(grep -cF 'fs.fsyncSync(out)' "$ARTIFACT_REDACT")" -eq 2 ] \
  && grep -qF 'expected.dev === stat.dev && expected.ino === stat.ino' "$ARTIFACT_REDACT" \
  && grep -qF "err.code === 'ELOOP' || err.code === 'EMLINK'" "$ARTIFACT_REDACT" \
  && grep -qF 'now.size !== stat.size || now.mtimeMs !== stat.mtimeMs' "$ARTIFACT_REDACT" \
  && grep -qF "reason: 'concurrent-write'" "$ARTIFACT_REDACT" \
  && ! grep -qF 'fs.constants.O_TRUNC' "$ARTIFACT_REDACT" \
  && ! grep -qF '| (fs.constants.O_NOFOLLOW || 0)' "$ARTIFACT_REDACT"; then
  check "artifact redactor omits unsupported O_NOFOLLOW on Windows and judges the descriptor" PASS
else
  check "artifact redactor omits unsupported O_NOFOLLOW on Windows and judges the descriptor" FAIL
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
