#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CONFIG="$ROOT/evals/session-control/promptfooconfig-upgrade.yaml"
SCENARIOS="$ROOT/evals/session-control/scenarios/upgrade.yaml"
PROVIDER="$ROOT/evals/session-control/lib/upgrade-provider.js"
PROCESS="$ROOT/evals/session-control/lib/upgrade-process.js"
ENVIRONMENT="$ROOT/evals/session-control/lib/upgrade-environment.js"
HOOK_CONTRACT="$ROOT/evals/session-control/lib/upgrade-hook-contract.js"
MOCK="$ROOT/evals/session-control/lib/upgrade-anthropic-mock.js"
SANDBOX="$ROOT/evals/session-control/lib/upgrade-linux-sandbox.js"
ATTESTATION="$ROOT/evals/session-control/lib/upgrade-attestation.js"
VERIFIER="$ROOT/evals/session-control/lib/verify-upgrade-results.js"
INSTALLER="$ROOT/tests/structure/fixtures/install-claude-runtime-fixture.js"
RUNNER="$ROOT/evals/session-control/run-eval.sh"
SELFTEST="$ROOT/evals/session-control/tests/upgrade-provider-selftest.js"
COVERAGE="$ROOT/evals/session-control/tests/enforce-upgrade-coverage.js"
COVERAGE_PARSER_TEST="$ROOT/evals/session-control/tests/coverage-report.test.js"
RESULT_TEST="$ROOT/evals/session-control/tests/upgrade-results.test.js"
NIGHTLY="$ROOT/.github/workflows/session-control-nightly.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
CI="$ROOT/.github/workflows/ci.yml"
# The FD3 credential boundary is documented in docs/session-control.md, not in
# the README. It lived there until 84aab18 (#228) moved the deep session-control
# prose out verbatim; that commit followed the pin with twelve other structure
# tests and missed this one, so the check has been RED on main ever since —
# invisibly, because this suite is localStructureTests and CI never runs it.
SESSION_CONTROL_DOC="$ROOT/docs/session-control.md"
EVAL_README="$ROOT/evals/session-control/README.md"
CHANGELOG="$ROOT/CHANGELOG.md"
RELEASE_GATE_DOC="$ROOT/docs/session-control-release-gate.md"
SANDBOX_PREP="$ROOT/.github/scripts/prepare-claude-sandbox-linux.sh"
PASS=0
FAIL=0

check() {
  if [ "$2" = PASS ]; then
    printf '  PASS  %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"
    FAIL=$((FAIL + 1))
  fi
}

contains() {
  grep -Fq -- "$3" "$2" && check "$1" PASS || check "$1" FAIL
}

[ -f "$CONFIG" ] && check 'Dedicated Promptfoo upgrade profile exists' PASS \
  || check 'Dedicated Promptfoo upgrade profile exists' FAIL
[ -f "$SCENARIOS" ] && check 'Dedicated upgrade scenario catalog exists' PASS \
  || check 'Dedicated upgrade scenario catalog exists' FAIL
[ "$(grep -c '^- description:' "$SCENARIOS" 2>/dev/null)" = 1 ] \
  && check 'Upgrade profile has exactly one supported lifecycle row' PASS \
  || check 'Upgrade profile has exactly one supported lifecycle row' FAIL
contains 'Upgrade profile is serialized at maxConcurrency one' "$CONFIG" 'maxConcurrency: 1'
contains 'Upgrade profile uses the strict upgrade assertion' "$CONFIG" 'file://assertions/upgrade-attestation.js'
contains 'Provider resolves the actual historical tag locally' "$PROVIDER" "const OLD_REF = 'v0.16.1'"
contains 'Provider pins v0.16.1 to its exact release commit' "$PROVIDER" 'oldRevision !== OLD_RELEASE_REVISION'
contains 'Provider rejects a candidate at the historical commit' "$PROVIDER" "fail('candidate source does not advance beyond v0.16.1')"
contains 'Provider proves historical release ancestry' "$PROVIDER" "gitIsAncestor(sourceRoot, oldRevision, sourceRevision)"
contains 'Provider gives the installer only the isolated cache parent' \
  "$PROVIDER" \
  'INSTALLER, source, canonicalParent, version, revision'
contains 'Provider accepts only one unpredictable direct-child runtime root' \
  "$PROVIDER" \
  '!path.basename(installed).startsWith(`.zensu-runtime-v${version}-`)'
contains 'Provider uses the shared immutable runtime fixture installer' "$PROVIDER" 'install-claude-runtime-fixture.js'
contains 'Installer creates the final root at an unpredictable direct-child path' \
  "$INSTALLER" \
  'createUniqueChildDirectory('
contains 'Installer randomizes runtime roots with high-entropy bytes' \
  "$INSTALLER" \
  'crypto.randomBytes(24).toString('\''hex'\'')'
contains 'Installer populates the unpredictable directory as its final runtime root' \
  "$INSTALLER" \
  'runtime = runtimeIdentity.path'
contains 'Installer returns that same final runtime root after identity revalidation' \
  "$INSTALLER" \
  'return ready.canonical'
contains 'The evaluator registry is the runtime publication boundary' \
  "$PROVIDER" \
  'scope: '\''user'\'', installPath: root, version, gitCommitSha: revision'
contains 'Provider holds one stream process for three old-runtime turns' "$PROVIDER" 'oldProcess.waitForResult(3)'
contains 'Provider emits bounded multi-turn protocol counters on drift' "$PROVIDER" 'init_count=${initEvents(oldProcess.events).length}; result_count=${oldProcess.results.length}'
contains 'Provider keeps the old process open through the fresh candidate run' "$PROVIDER" "fail('old process did not remain open through the fresh candidate session')"
contains 'Provider requires one matching init per completed stream turn' "$PROVIDER" 'requireTurnInitEvents(oldProcess.events, oldSessionId, 3'
contains 'Provider freezes the evaluator-owned candidate hook contract once' \
  "$PROVIDER" \
  'const capturedCandidateHooks = candidateHookContract(candidateRoot)'
contains 'Provider revalidates candidate hook identities after contract capture' \
  "$PROVIDER" \
  'verifyCandidateHookContract(candidateRoot, capturedCandidateHooks)'
contains 'Evaluator captures immutable hook file identity and digest evidence' \
  "$HOOK_CONTRACT" \
  'sha256: crypto.createHash('\''sha256'\'').update(stable.buffer).digest('\''hex'\'')'
contains 'Evaluator detects replace-and-restore hook tampering' \
  "$HOOK_CONTRACT" \
  "throw contractError('hook target changed after capture')"
contains 'Evaluator contract requires the Session Control bootstrap hook' \
  "$HOOK_CONTRACT" \
  "'session-start-session-control.sh'"
contains 'Evaluator contract requires the reviewer Read gate' \
  "$HOOK_CONTRACT" \
  "'pre-reviewer-capability-gate.sh'"
contains 'Provider executes a harmless fresh-candidate Bash probe' "$PROVIDER" 'ZENSU_UPGRADE_BASH_OK'
contains 'Live prompt makes the Read result causally necessary' "$PROVIDER" 'opaque token that is not present in this prompt'
contains 'Provider verifies the opaque token in the Read result' "$PROVIDER" "JSON.stringify(readResult.content ?? '').includes(token)"
contains 'Provider emits only bounded redacted terminal diagnostics' "$PROVIDER" 'terminal_sha256=${result.sha256}'
contains 'Provider diagnostics expose only allowlisted event-shape categories' "$PROVIDER" 'event_shape=${eventShape || '\''none'\''}'
contains 'Provider diagnostics expose only redacted assistant metadata' "$PROVIDER" 'assistant_sha256=${assistant.sha256}'
contains 'Provider diagnostics expose only allowlisted init-tool counts' "$PROVIDER" 'init_tools_read=${initToolCounts.Read}'
contains 'Provider hashes unexpected tool shapes instead of printing raw keys' "$PROVIDER" 'tool_shape_sha256=${hash(Buffer.from(JSON.stringify(shape)'
contains 'Provider hashes unexpected top-level errors before stderr' "$PROVIDER" 'session-control upgrade provider: unexpected failure'
contains 'Provider uses an unforgeable local safe-error registry' "$PROVIDER" 'safeErrorHas(SAFE_DIAGNOSTIC_ERRORS, error)'
contains 'Provider hashes candidate hook names in failure output' "$PROVIDER" 'hook_sha256=${hookHash}'
contains 'Provider hashes recursive canary labels in failure output' "$PROVIDER" 'cannot inspect existing-login host canary; entry_sha256='
if grep -Fq -- 'symlink: ${rel}' "$PROVIDER" || grep -Fq -- 'unsupported entry: ${rel}' "$PROVIDER"; then
  check 'Provider never prints raw runtime entry paths' FAIL
else
  check 'Provider never prints raw runtime entry paths' PASS
fi
contains 'Provider validates the captured Read and Bash hook multisets' \
  "$PROVIDER" \
  '...capturedCandidateHooks.observedExpectedHooks.PreToolUse.Bash'
contains 'Evaluator contract owns the complete Bash gate minimum' \
  "$HOOK_CONTRACT" \
  "'pre-write-secret-scan.sh'"
contains 'Captured candidate hook evidence is deeply immutable' \
  "$HOOK_CONTRACT" \
  'return deepFreeze({'
contains 'Real provider uses fail-closed dontAsk permission mode' "$PROVIDER" "'--permission-mode', 'dontAsk'"
contains 'Real provider supplies exact Claude allowedTools rules' "$PROVIDER" "'--allowedTools', ...readRules"
contains 'Real provider uses filesystem-absolute Claude Read rules' "$PROVIDER" 'return `Read(/${normalized})`'
contains 'Real provider preapproves the exact harmless Bash command' "$PROVIDER" 'Bash(${BASH_PROBE_COMMAND})'
contains 'Provider requires four distinct Read fixtures' "$PROVIDER" 'requires exactly four distinct Read fixtures'
if grep -Fq -- '--dangerously-skip-permissions' "$PROVIDER"; then
  check 'Real provider never bypasses Claude permissions' FAIL
else
  check 'Real provider never bypasses Claude permissions' PASS
fi
contains 'Harness owns an exact pre-execution Bash guard' "$PROVIDER" 'createBashGuard(control)'
contains 'Bash guard permits only bounded non-executable description metadata' "$PROVIDER" 'Buffer.byteLength(description)<=512'
contains 'Candidate validator rejects every other Bash input field' "$PROVIDER" 'const validBashInput = ('
contains 'Provider requires exactly one successful Bash guard result' "$PROVIDER" 'requireBashGuardTrace(bashGuard.trace)'
contains 'Real Bash sandbox fails closed when unavailable' "$PROVIDER" 'failIfUnavailable: true'
contains 'Real Bash sandbox forbids unsandboxed escape' "$PROVIDER" 'allowUnsandboxedCommands: false'
contains 'Evaluator contract requires the Stop enforcer' \
  "$HOOK_CONTRACT" \
  "'stop-chain-enforcer.sh'"
contains 'Provider validates exact fresh record and baseline' "$PROVIDER" 'validateFreshState('
contains 'Diagnostic discovers only a direct child of isolated plugin data' "$PROVIDER" 'path.dirname(expectedPluginData) !== parent'
contains 'Installed-provider mode still requires the exact marketplace data id' "$PROVIDER" 'pluginDataPath(env.CLAUDE_CODE_PLUGIN_CACHE_DIR)'
contains 'Provider preserves old runtime bytes after candidate install' "$PROVIDER" 'candidate installation modified the old version root'
contains 'Provider reports only count and hash for changed runtime entries' "$PROVIDER" 'sha256=${hash(Buffer.from(JSON.stringify(changed)'
contains 'Provider diagnoses final old-root drift without file content' "$PROVIDER" 'changedTreeEntries(oldInventoryBefore, oldInventoryFinal)'
contains 'Provider diagnoses final candidate drift without file content' "$PROVIDER" 'changedTreeEntries(candidateInventoryBefore, candidateInventoryFinal)'
contains 'Provider excludes only Claude root lifecycle markers from byte snapshots' "$PROVIDER" "if (!relative && (name === '.in_use' || name === '.orphaned_at')) continue"
contains 'Hermetic mode binds the old active-root marker to the exact process' \
  "$PROVIDER" \
  'testMode ? oldProcess.child.pid : null'
contains 'Contained mode accepts only one PID-namespace-local active-root marker' \
  "$PROVIDER" \
  'actual.length !== 1'
contains 'Provider requires candidate active-root marker cleanup' \
  "$PROVIDER" \
  "requireInUseMarker(candidateRoot, null, false, 'fresh candidate process')"
contains 'Fake lifecycle host exercises real-shaped active-root markers' "$SELFTEST" "path.join(captured,'.in_use')"
contains 'Provider validates the old orphan marker in the candidate activation window' "$PROVIDER" "'old runtime after candidate activation'"
contains 'Provider keeps the old root marker-free before the version switch' "$PROVIDER" "'old runtime after old-process activation'"
contains 'Provider keeps the current candidate free of an orphan marker' "$PROVIDER" "requireOrphanMarker(candidateRoot, false"
contains 'Provider requires the old orphan marker to remain byte-stable' "$PROVIDER" 'oldOrphanMarkerFinal.fingerprint !== oldOrphanMarkerAfterCandidate.fingerprint'
contains 'Provider proves old in-use and orphan markers coexist' "$PROVIDER" "'old process during candidate activation'"
contains 'Fake lifecycle host exercises the real old-root orphan marker' "$SELFTEST" "path.join(oldState.root,'.orphaned_at')"
contains 'Fake selftest rejects a missing old-root orphan marker' "$SELFTEST" "'missing-old-orphan-marker'"
contains 'Fake selftest rejects a malformed old-root orphan marker' "$SELFTEST" "'malformed-old-orphan-marker'"
contains 'Fake selftest rejects a stale old-root orphan marker' "$SELFTEST" "'stale-old-orphan-marker'"
contains 'Fake selftest rejects a candidate-root orphan marker' "$SELFTEST" "'candidate-orphan-marker'"
contains 'Fake selftest rejects an old-root orphan marker rewrite' "$SELFTEST" "'rewrite-old-orphan-marker'"
contains 'Fake selftest rejects loss of the live old-root marker' "$SELFTEST" "'drop-old-in-use-on-candidate'"
contains 'Fake selftest injects secret-shaped child diagnostics' "$SELFTEST" "'diagnostic-secret-event'"
contains 'Fake selftest injects a secret-shaped runtime filename' "$SELFTEST" "'secret-filename-drift'"
contains 'Fake selftest rejects GitHub workflow-command leakage' "$SELFTEST" "'::error::'"
contains 'Fake selftest injects a secret-shaped hook basename' "$SELFTEST" "'diagnostic-secret-hook'"
contains 'Fake selftest cannot forge the safe-error registry' "$SELFTEST" "'forged-safe-error'"
contains 'Provider preserves source checkout identity and cleanliness' "$PROVIDER" "fail('upgrade evaluation changed the candidate source checkout')"
if grep -Fq -- 'rmSync(candidateRoot' "$PROVIDER" || grep -Fq -- 'cpSync(candidateRoot' "$PROVIDER"; then
  check 'Provider never replaces the candidate or old root in place' FAIL
else
  check 'Provider never replaces the candidate or old root in place' PASS
fi
contains 'Provider supports explicit local CLI pin' "$PROVIDER" 'ZENSU_EXPECTED_CLAUDE_VERSION'
contains 'Real candidate validation is Linux-only' \
  "$PROVIDER" \
  "if (!testMode && process.platform !== 'linux')"
contains 'Real candidate validation forbids existing-login execution' \
  "$PROVIDER" \
  'existing-login candidate execution is forbidden; use the plugin-free authenticated canary with an explicit credential'
contains 'Only deterministic tests may exercise a hermetic existing-login profile' \
  "$PROVIDER" \
  'deterministic existing-login mode requires its exact hermetic test HOME'
contains 'Provider disables prompt-history persistence' "$PROVIDER" "CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1'"
contains 'Provider uses exact Claude plugin-data id mapping' "$PROVIDER" "directory !== 'zensu-zensu'"
contains 'Provider isolates all conventional temporary-directory variables' "$PROVIDER" 'TEMP: isolatedTemp'
contains 'Provider isolates Claude internal temporary files' "$PROVIDER" 'CLAUDE_CODE_TMPDIR: isolatedTemp'
contains 'Provider records bounded existing-login host canaries' "$PROVIDER" 'existingLoginCanary(hostHome)'
contains 'Provider preserves the primary failure when a canary also changes' "$PROVIDER" 'primaryError.message += '\''; existing-login host config/cache canary also changed'\'''
contains 'Provider refuses Windows before starting Claude' \
  "$PROVIDER" \
  'Windows candidate containment is unsupported; no helper or Claude process was started'
contains 'Process helper refuses Windows before spawn' \
  "$PROCESS" \
  'Windows process-tree containment is unsupported; no child process was started'
contains 'Windows provider selftest verifies the explicit no-spawn boundary' \
  "$SELFTEST" \
  'upgrade-provider-selftest.js: PASS (Windows zero-launch fail-closed)'
contains 'Runner forbids real existing-login candidate execution' \
  "$RUNNER" \
  'existing-login candidate execution is unsupported; provide one explicit credential for the plugin-free auth canary'
contains 'Local operator command pins the Claude CLI version' "$RELEASE_GATE_DOC" 'ZENSU_EXPECTED_CLAUDE_VERSION=2.1.221'
contains 'Provider authenticates with a plugin-free isolated-HOME canary' \
  "$PROVIDER" \
  'async function runAuthenticatedCliCanary('
contains 'Authenticated canary starts Claude in safe mode' \
  "$PROVIDER" \
  "'--safe-mode'"
contains 'Authenticated canary disables every model tool' \
  "$PROVIDER" \
  "'--tools', ''"
contains 'Authenticated canary rejects inherited settings and MCP servers' \
  "$PROVIDER" \
  "'--setting-sources', ''"
contains 'Authenticated canary enters Bubblewrap with an FD3 argument payload' \
  "$PROVIDER" \
  'environmentArgumentFd: 3'
contains 'Authenticated canary forwards the Bubblewrap argument payload to the process helper' \
  "$PROVIDER" \
  'argumentInput: invocation.argumentInput'
CANARY_IMPLEMENTATION="$(sed -n '/^async function runAuthenticatedCliCanary(/,/^async function main()/p' "$PROVIDER")"
if printf '%s' "$CANARY_IMPLEMENTATION" | grep -Eq \
  'process\.env\.(ANTHROPIC_BASE_URL|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|SSL_CERT_FILE|SSL_CERT_DIR|NODE_EXTRA_CA_CERTS)'; then
  check 'Authenticated canary rejects caller base-URL, proxy, and trust overrides' FAIL
else
  check 'Authenticated canary rejects caller base-URL, proxy, and trust overrides' PASS
fi
for resolver_file in /etc/resolv.conf /etc/hosts /etc/nsswitch.conf; do
  contains "Shared-network sandbox mounts $resolver_file read-only" \
    "$ROOT/evals/session-control/lib/upgrade-linux-sandbox.js" \
    "'$resolver_file'"
done
contains 'The selected live credential crosses only the authenticated canary boundary' \
  "$PROVIDER" \
  'explicitCredential || {'
contains 'Candidate lifecycle uses the deterministic loopback model backend' \
  "$PROVIDER" \
  'if (!testMode) mockBackend = await startUpgradeAnthropicMock()'
contains 'Candidate lifecycle receives only the mock backend credential' \
  "$PROVIDER" \
  '? { apiKey: mockBackend.apiKey, baseUrl: mockBackend.url }'
contains 'Helper environments remove every Claude credential name' \
  "$ENVIRONMENT" \
  'for (const name of CLAUDE_CREDENTIAL_NAMES) delete environment[name]'
contains 'Loopback model backend binds only the IPv4 loopback address' \
  "$MOCK" \
  "host = '127.0.0.1'"
contains 'Loopback model backend bounds the number of candidate requests' \
  "$MOCK" \
  'const MAX_REQUESTS = 32'
contains 'Loopback model backend requires its evaluator-generated dummy key' \
  "$MOCK" \
  "request.headers['x-api-key'] !== apiKey"
contains 'Loopback model backend correlates exact tool-result IDs' \
  "$MOCK" \
  'block.tool_use_id === readUseId'
contains 'Real candidate Claude runs in an outer Bubblewrap PID namespace' \
  "$SANDBOX" \
  "'--unshare-pid'"
contains 'Outer Bubblewrap restricts every writable root to the disposable evaluator root' \
  "$SANDBOX" \
  "'writable root is outside the evaluator-owned disposable root'"
contains 'Provider declares its evaluator-owned disposable Bubblewrap root' \
  "$PROVIDER" \
  'disposableRoot: temporary'
contains 'Real candidate Claude runs with a clean evaluator-selected environment' \
  "$SANDBOX" \
  "const environmentArgs = ['--clearenv']"
contains 'Real candidate Claude enters the evaluator-selected working directory' \
  "$SANDBOX" \
  "sandboxArgs.push('--chdir', cwdIdentity.canonical)"
contains 'Real candidate hooks run in a nested networkless namespace' \
  "$PROVIDER" \
  '--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup'
contains 'Nested candidate hooks remount the active plugin root read-only' \
  "$PROVIDER" \
  '--ro-bind "$plugin_root" "$plugin_root"'
contains 'Nested candidate hooks cannot read the evaluator control directory' \
  "$PROVIDER" \
  '`--tmpfs ${shellQuote(control)}`'
contains 'Nested candidate hooks receive evaluator-bound plugin data' \
  "$PROVIDER" \
  '`--setenv CLAUDE_PLUGIN_DATA ${shellQuote(pluginData)}`'
contains 'Nested candidate hooks receive evaluator-bound project root' \
  "$PROVIDER" \
  '`--setenv CLAUDE_PROJECT_DIR ${shellQuote(projectRoot)}`'
contains 'Nested candidate hooks use only the private namespace-local tmpfs' \
  "$PROVIDER" \
  "'--setenv TMPDIR /tmp'"
contains 'Linux hook integration invokes the exported production boundary builder' \
  "$ROOT/tests/structure/test-session-control-sandbox-hook-integration.sh" \
  'const { createTraceBoundary } = require(provider);'
contains 'Provider is import-safe only for the production boundary integration' \
  "$PROVIDER" \
  'if (require.main === module)'
contains 'Linux hook integration proves project, plugin-data, and hidden-control bindings' \
  "$ROOT/tests/structure/test-session-control-sandbox-hook-integration.sh" \
  'BOUNDARY_ENVIRONMENT_OK'
contains 'Hook evidence records trusted START and END boundaries' \
  "$PROVIDER" \
  "const record=mode==='start'?{type:'START',id,hook}:{type:'END',id,hook,status:Number(status)};"
contains 'Hook evidence rejects unmatched END records' \
  "$PROVIDER" \
  'hook trace END record is unmatched or malformed'
contains 'Upgrade attestation is held until all cleanup succeeds' \
  "$PROVIDER" \
  'let pendingAttestationLine = null'
contains 'Upgrade attestation is printed only after the cleanup boundary' \
  "$PROVIDER" \
  'process.stdout.write(`${pendingAttestationLine}\n`)'
contains 'Authoritative attestation names the split-auth execution mode' \
  "$ATTESTATION" \
  'authoritative-split-auth-canary-contained-candidate'
contains 'Authoritative attestation requires the live plugin-free canary' \
  "$ATTESTATION" \
  "authenticated_canary_status: 'passed-plugin-free-live'"
contains 'Authoritative attestation requires the loopback candidate backend' \
  "$ATTESTATION" \
  "candidate_model_backend: 'deterministic-loopback-anthropic-mock'"
contains 'Authoritative attestation requires outer and nested hook containment' \
  "$ATTESTATION" \
  "candidate_containment: 'linux-bwrap-pid-mount-with-nested-hook-net-v1'"
contains 'Lifecycle evidence names the credentialless candidate boundary' \
  "$ATTESTATION" \
  "'CandidateBackend:no-live-credential'"
contains 'Only split-auth contained evidence can be published' \
  "$VERIFIER" \
  'only split authenticated-canary and contained-candidate runs may publish upgrade evidence'
contains 'Provider selftest records every launch credential boundary centrally' \
  "$SELFTEST" \
  'ZENSU_UPGRADE_TEST_LAUNCH_LEDGER_FILE: credentialLedger'
contains 'Provider selftest proves the authenticated canary receives the selected credential' \
  "$SELFTEST" \
  "authenticated[0].credential_names_present, ['ANTHROPIC_API_KEY']"
contains 'Provider selftest proves candidate Claude receives only the dummy API-key shape' \
  "$SELFTEST" \
  "hasApi!=='zensu-upgrade-test-dummy-key'||hasOauth"
contains 'Provider selftest proves every evaluator helper is credential-free' \
  "$SELFTEST" \
  'record.credential_names_present.length === 0'
contains 'Fake Promptfoo selftest declares an E2E tamper matrix' "$SELFTEST" 'fake-provider E2E matrix'
contains 'Fake host derives its answer only from the fixture file' "$SELFTEST" "const token=fs.readFileSync(file,'utf8').trim()"
contains 'Fake selftest injects wrong-root drift after candidate completion' "$SELFTEST" "'wrong-turn3-root'"
contains 'Fake selftest injects a nonzero hook result' "$SELFTEST" "'nonzero-hook'"
contains 'Fake selftest injects missing authority state' "$SELFTEST" "'missing-record'"
contains 'Fake selftest injects an extra authority record' "$SELFTEST" "'extra-record'"
contains 'Fake selftest injects a missing Bash guard result' "$SELFTEST" "'missing-bash-guard'"
contains 'Fake selftest rejects an unsandboxed Bash override' "$SELFTEST" 'dangerouslyDisableSandbox:true'
contains 'Fake selftest exercises Claude 2.1.217 Bash description metadata' "$SELFTEST" 'Print the fixed harmless upgrade probe token'
contains 'Fake selftest requires fault-specific failure reasons' "$SELFTEST" 'fault failed for the wrong reason'
contains 'Fake selftest verifies the exact Promptfoo fault multiset' "$SELFTEST" 'Promptfoo did not execute the exact positive/negative fault multiset'
contains 'Fake selftest rejects retagged historical release identity' "$SELFTEST" 'maliciously retagged v0.16.1'
contains 'Fake selftest rejects unrelated candidate history' "$SELFTEST" 'provider accepted an unrelated candidate history'
contains 'Fake selftest injects process crash' "$SELFTEST" "'crash'"
contains 'Fake selftest injects old-root mutation' "$SELFTEST" "'mutate-old'"
contains 'Fake selftest causally rejects prose-only candidate success' "$SELFTEST" "'candidate-prose-only-terminal'"
contains 'Fake selftest causally rejects an errored candidate Read' "$SELFTEST" "'candidate-errored-read-result'"
contains 'Fake selftest causally rejects a missing candidate Bash result' "$SELFTEST" "'candidate-missing-bash-result'"
contains 'Fake selftest rejects corrupted candidate context authority' "$SELFTEST" "'corrupt-candidate-context-binding'"
contains 'Fake selftest rejects corrupted candidate workflow authority' "$SELFTEST" "'corrupt-candidate-workflow-baseline'"
contains 'Fake selftest rejects replace-and-restore candidate hook tampering' "$SELFTEST" "'replace-restore-candidate-hook'"
contains 'Fake selftest rejects replace-and-restore of an extra configured event hook' \
  "$SELFTEST" \
  "'replace-restore-additional-event-hook'"
contains 'Fake selftest rejects replace-and-restore of the candidate plugin root' \
  "$SELFTEST" \
  "'replace-restore-candidate-plugin-root'"
contains 'Fake selftest rejects candidate runtime mutation' "$SELFTEST" "'mutate-candidate'"
contains 'Fake selftest rejects missing, foreign, and lingering candidate markers' "$SELFTEST" "'foreign-candidate-in-use'"
contains 'Fake selftest rejects a lingering old marker' "$SELFTEST" "'linger-old-in-use'"
contains 'Fake selftest exercises a non-synthetic release version' "$SELFTEST" "releaseManifest.version = '0.17.0'"
contains 'Fake selftest runs a hermetic existing-login Promptfoo matrix' "$SELFTEST" 'hermetic-existing-login'
contains 'Fake selftest proves diagnostic results cannot publish evidence' \
  "$SELFTEST" \
  'only split authenticated-canary and contained-candidate runs may publish upgrade evidence'
[ -f "$COVERAGE" ] && check 'Deterministic per-file upgrade coverage gate exists' PASS \
  || check 'Deterministic per-file upgrade coverage gate exists' FAIL
contains 'Selfcheck executes the per-file upgrade coverage gate' \
  "$ROOT/evals/session-control/run-self-check.sh" \
  'node "$EVAL_DIR/tests/enforce-upgrade-coverage.js"'
if grep -Fq 'session-control:selfcheck' "$CI"; then
  check 'PR CI excludes the local Promptfoo Session Control selfcheck' FAIL
else
  check 'PR CI excludes the local Promptfoo Session Control selfcheck' PASS
fi
contains 'PR CI names the real contained hook integration step' \
  "$CI" \
  'name: Contained Session Control hook integration'
contains 'PR CI executes the real contained hook integration contract' \
  "$CI" \
  'run: bash tests/structure/test-session-control-sandbox-hook-integration.sh'
contains 'Contained hook integration is opt-in outside its prepared CI job' \
  "$ROOT/tests/structure/test-session-control-sandbox-hook-integration.sh" \
  'ZENSU_RUN_LINUX_SANDBOX_HOOK_INTEGRATION:-0'
contains 'Every real contained hook invocation has a hard process timeout' \
  "$ROOT/tests/structure/test-session-control-sandbox-hook-integration.sh" \
  '/usr/bin/timeout --signal=TERM --kill-after=5s 30s'
contains 'Coverage gate includes the independent authority verifier' \
  "$COVERAGE" \
  'evals/session-control/lib/upgrade-independent-verifier.js'
contains 'Coverage gate executes the independent authority verifier tests' \
  "$COVERAGE" \
  'evals/session-control/tests/upgrade-independent-verifier.test.js'
contains 'Coverage gate measures the provider child-process harness' \
  "$COVERAGE" \
  'evals/session-control/lib/upgrade-provider.js'
contains 'Coverage gate executes the provider subprocess selftest' \
  "$COVERAGE" \
  'evals/session-control/tests/upgrade-provider-selftest.js'
contains 'Coverage gate measures the installer subprocess harness' \
  "$COVERAGE" \
  'tests/structure/fixtures/install-claude-runtime-fixture.js'
contains 'Coverage gate executes the installer subprocess policy tests' \
  "$COVERAGE" \
  'evals/session-control/tests/runtime-fixture-installer.test.js'
contains 'Coverage gate feature-detects Node coverage include support' \
  "$COVERAGE" \
  "process.allowedNodeEnvironmentFlags.has('--test-coverage-include')"
contains 'Coverage gate keeps a no-include fallback for Node 20' \
  "$COVERAGE" \
  'const coverageIncludeArgs = coverageIncludeSupported'
contains 'Coverage parser regression covers the Node 20 TAP marker' \
  "$COVERAGE_PARSER_TEST" \
  "'# evals"
contains 'Coverage parser regression covers the newer TAP marker' \
  "$COVERAGE_PARSER_TEST" \
  "'ℹ tests"
contains 'Coverage gate measures the canonical upgrade attestation' \
  "$COVERAGE" \
  'evals/session-control/lib/upgrade-attestation.js'
contains 'Coverage gate measures the upgrade receipt verifier' \
  "$COVERAGE" \
  'evals/session-control/lib/verify-upgrade-results.js'
contains 'Coverage gate executes the receipt boundary tests' \
  "$COVERAGE" \
  'evals/session-control/tests/upgrade-results.test.js'
contains 'Receipt tests require the exact schema-v2 field order and set' \
  "$RESULT_TEST" \
  'assert.deepEqual(Object.keys(receipt), RECEIPT_KEYS)'
contains 'Receipt tests independently reconstruct the evidence digest' \
  "$RESULT_TEST" \
  'digest(JSON.stringify(canonicalReceipt))'
contains 'Coverage gate audits the complete explicit production allowlist' \
  "$COVERAGE" \
  'const upgradeProductionAllowlist = ['
contains 'Coverage gate enforces ninety percent per exact file' \
  "$COVERAGE" \
  'const minimumLineCoverage = 90;'
contains 'Upgrade mode is part of the release aggregate' "$RUNNER" 'bash "$EVAL_DIR/run-eval.sh" upgrade "$@"'
[ ! -e "$NIGHTLY" ] \
  && check 'GitHub Actions has no Promptfoo nightly workflow' PASS \
  || check 'GitHub Actions has no Promptfoo nightly workflow' FAIL
[ -f "$SANDBOX_PREP" ] && check 'Linux sandbox prerequisite helper exists' PASS \
  || check 'Linux sandbox prerequisite helper exists' FAIL
contains 'Linux sandbox helper installs both required packages' "$SANDBOX_PREP" 'apt-get install -y --no-install-recommends bubblewrap socat'
contains 'Linux sandbox helper handles Ubuntu AppArmor user namespaces' "$SANDBOX_PREP" 'apparmor_restrict_unprivileged_userns'
contains 'Linux sandbox helper installs the documented bwrap profile' "$SANDBOX_PREP" 'profile bwrap /usr/bin/bwrap flags=(unconfined)'
contains 'Linux sandbox helper executes a network namespace probe' "$SANDBOX_PREP" '/usr/bin/bwrap --unshare-net --ro-bind / / /bin/true'
contains 'Linux sandbox helper executes the narrow resolver runtime smoke' \
  "$SANDBOX_PREP" \
  'linux-sandbox-runtime-smoke.js'
contains 'Linux sandbox helper probes a detached TERM-ignoring grandchild' \
  "$SANDBOX_PREP" \
  'trap "" TERM HUP INT; sleep 4; echo escaped'
contains 'Linux sandbox helper proves the detached grandchild cannot escape' \
  "$SANDBOX_PREP" \
  'test ! -e "$ESCAPE_SENTINEL"'
contains 'Linux sandbox helper keeps the command outside the argument FD' \
  "$SANDBOX_PREP" \
  '-- /bin/sh -c \'
contains 'Linux sandbox helper transports sensitive environment arguments through FD3' \
  "$SANDBOX_PREP" \
  '  --args 3 \'
FD_PAYLOAD="$(
  sed -n '/3< <(/,/^[[:space:]]*) \&/p' "$SANDBOX_PREP"
)"
if grep -Fq -- '--clearenv' <<<"$FD_PAYLOAD" \
  && grep -Fq -- '--setenv ANTHROPIC_API_KEY "$ESCAPE_SECRET"' <<<"$FD_PAYLOAD" \
  && ! grep -Fq -- '--unshare-user' <<<"$FD_PAYLOAD" \
  && ! grep -Fq -- '/bin/sh -c' <<<"$FD_PAYLOAD"; then
  check 'Linux sandbox helper limits FD3 to sensitive environment options' PASS
else
  check 'Linux sandbox helper limits FD3 to sensitive environment options' FAIL
fi
ESCAPE_HOST="$(
  sed -n '/^\/usr\/bin\/bwrap \\/,/3< <(/p' "$SANDBOX_PREP"
)"
if grep -Fxq '  --dev /dev \' <<<"$ESCAPE_HOST"; then
  check 'Linux sandbox escape probe provides a writable private dev mount' PASS
else
  check 'Linux sandbox escape probe provides a writable private dev mount' FAIL
fi
contains 'Linux sandbox helper audits the host Bubblewrap command line' \
  "$SANDBOX_PREP" \
  '"/proc/$ESCAPE_BWRAP_PID/cmdline"'
contains 'Linux sandbox helper rejects credential leakage into host argv' \
  "$SANDBOX_PREP" \
  'grep -Fq -- "$ESCAPE_SECRET"'
if [ "$(grep -Fc -- '--unshare-pid' "$SANDBOX_PREP")" -ge 3 ] \
  && [ "$(grep -Fc -- '--die-with-parent' "$SANDBOX_PREP")" -ge 3 ] \
  && [ "$(grep -Fc -- '--new-session' "$SANDBOX_PREP")" -ge 3 ]; then
  check 'Linux sandbox helper exercises outer, detached, and nested process-tree boundaries' PASS
else
  check 'Linux sandbox helper exercises outer, detached, and nested process-tree boundaries' FAIL
fi
contains 'Linux sandbox helper executes a nested Bubblewrap probe' \
  "$SANDBOX_PREP" \
  '  /usr/bin/bwrap \'
NESTED_PROBE="$(
  sed -n '/^# Nested namespaces/,/    \/bin\/true/p' "$SANDBOX_PREP"
)"
if grep -Fxq '  --proc /proc \' <<<"$NESTED_PROBE"; then
  check 'Nested Bubblewrap probe gives the inner namespace a writable proc control mount' PASS
else
  check 'Nested Bubblewrap probe gives the inner namespace a writable proc control mount' FAIL
fi
contains 'Nested Bubblewrap probe removes network access' \
  "$SANDBOX_PREP" \
  '    --unshare-net \'
if [ "$(grep -Fc 'bash .github/scripts/prepare-claude-sandbox-linux.sh' "$CI")" = 1 ]; then
  check 'Deterministic PR CI prepares the mandatory sandbox once' PASS
else
  check 'Deterministic PR CI prepares the mandatory sandbox once' FAIL
fi
CI_HISTORY_CHECKOUT_AUDIT="$(
  node - "$CI" <<'NODE'
const fs = require('node:fs');
const YAML = require('yaml');
const ci = YAML.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expectedJobs = ['test', 'windows-shards'];
const safe = expectedJobs.every((jobId) => {
  const steps = ci?.jobs?.[jobId]?.steps || [];
  const checkouts = steps.filter(
    (step) => typeof step.uses === 'string' && step.uses.startsWith('actions/checkout@'),
  );
  return checkouts.length === 1
    && checkouts.every((checkout) => (
      checkout?.with?.['fetch-depth'] === 0
      && checkout?.with?.['persist-credentials'] === false
    ));
});
process.stdout.write(safe ? 'true' : 'false');
NODE
)"
if [ "$CI_HISTORY_CHECKOUT_AUDIT" = true ]; then
  check 'Every history-sensitive CI job safely fetches the pinned historical tag' PASS
else
  check 'Every history-sensitive CI job safely fetches the pinned historical tag' FAIL
fi
WORKFLOW_AUDIT="$(node - "$CI" "$RELEASE" <<'NODE'
const fs = require('node:fs');
const YAML = require('yaml');
const [ciPath, releasePath] = process.argv.slice(2);
const ci = YAML.parse(fs.readFileSync(ciPath, 'utf8'));
const release = YAML.parse(fs.readFileSync(releasePath, 'utf8'));
const sandboxJob = ci?.jobs?.['session-control-sandbox'];
const sandboxSteps = sandboxJob?.steps || [];
const sandboxStepIndex = (name) => sandboxSteps.findIndex((step) => step.name === name);
const sandboxPrepareIndex = sandboxStepIndex('Prepare verified Claude Bash sandbox');
const sandboxIntegrationIndex = sandboxStepIndex('Contained Session Control hook integration');
const sandboxIntegration = sandboxSteps[sandboxIntegrationIndex];
const serialized = JSON.stringify({ ci, release });
process.stdout.write(JSON.stringify({
  sandbox_runner: sandboxJob?.['runs-on'] || '',
  sandbox_checkout_safe: sandboxSteps.some((step) => (
    String(step.uses || '').startsWith('actions/checkout@')
      && step.with?.['persist-credentials'] === false
  )),
  sandbox_helper: sandboxSteps.some(
    (step) => step.run === 'bash .github/scripts/prepare-claude-sandbox-linux.sh',
  ),
  sandbox_timeout: sandboxJob?.['timeout-minutes'],
  sandbox_integration_ordered:
    sandboxPrepareIndex >= 0
    && sandboxIntegrationIndex > sandboxPrepareIndex,
  sandbox_integration_command:
    sandboxIntegration?.run
      === 'bash tests/structure/test-session-control-sandbox-hook-integration.sh',
  sandbox_integration_forced:
    sandboxIntegration?.env?.ZENSU_RUN_LINUX_SANDBOX_HOOK_INTEGRATION === '1',
  sandbox_has_npm: sandboxSteps.some((step) => /npm (?:ci|install)/.test(step.run || '')),
  promptfoo_absent: !/promptfoo|session-control:(?:selfcheck|contract|upgrade|live|concurrency|adversarial|release)/i.test(serialized),
  ai_credentials_absent: !/ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN/.test(serialized),
  // The intent is that the CI test job runs the deterministic non-Promptfoo
  // gate, not that it runs it as one unsharded process. Exact equality here
  // silently went false when the job was sharded, and nothing caught it: this
  // suite is promptfoo-local-only, so the --ci gate never runs it. Anchor the
  // invocation and allow only a --shard argument after it, so a future change
  // to the shard spec cannot break the assertion again while an unrelated
  // trailing command still fails it.
  // The shard argument is double-quoted in the workflow, but this node script
  // lives in a heredoc inside a double-quoted $(...) substitution, so a literal
  // double quote here unbalances the enclosing parse and the whole file stops
  // being valid bash. Match the quote as \x22 instead; backticks are barred for
  // the same reason.
  deterministic_ci: (ci?.jobs?.test?.steps || []).some(
    (step) => /^bash tests\/run-all\.sh --ci(?: \x22--shard=[^\x22]+\x22)?$/.test((step.run || '').trim()),
  ),
  deterministic_release: serialized.includes('Deterministic exact-main-SHA gate'),
}));
NODE
)"
if [ "$?" -eq 0 ]; then
  check 'PR-CI and release workflow YAML parse for local-only audit' PASS
else
  check 'PR-CI and release workflow YAML parse for local-only audit' FAIL
  WORKFLOW_AUDIT='{}'
fi
[ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_runner)" = 'ubuntu-24.04' ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_checkout_safe)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_helper)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_timeout)" = 15 ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_integration_ordered)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_integration_command)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_integration_forced)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .sandbox_has_npm)" = false ] \
  && check 'PR CI prepares then forces bounded contained hooks on pinned Ubuntu without npm setup' PASS \
  || check 'PR CI prepares then forces bounded contained hooks on pinned Ubuntu without npm setup' FAIL
[ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .promptfoo_absent)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .ai_credentials_absent)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .deterministic_ci)" = true ] \
  && [ "$(printf '%s' "$WORKFLOW_AUDIT" | jq -r .deterministic_release)" = true ] \
  && check 'GitHub Actions use only deterministic non-Promptfoo gates' PASS \
  || check 'GitHub Actions use only deterministic non-Promptfoo gates' FAIL

contains 'Session Control docs document the Bubblewrap FD3 credential boundary' \
  "$SESSION_CONTROL_DOC" \
  'through its `--args` file descriptor 3, never through the process'
contains 'Eval README documents the exact POSIX Promptfoo matrix' \
  "$EVAL_README" \
  'a 43-row POSIX synthetic-version lifecycle/tamper matrix and a three-row'
contains 'Release-gate docs document all 46 deterministic Promptfoo rows' \
  "$RELEASE_GATE_DOC" \
  '46 deterministic Promptfoo cases'
MATRIX_CARDINALITY_PIN="$(
  node - "$SELFTEST" <<'NODE'
const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2], 'utf8');
const exact = [
  /assert\.equal\(\s*faults\.length \+ 1,\s*43,/m,
  /assert\.equal\(\s*existingLoginFaults\.length \+ 1,\s*3,/m,
  /assert\.equal\(\s*\(faults\.length \+ 1\) \+ \(existingLoginFaults\.length \+ 1\),\s*46,/m,
];
process.stdout.write(exact.every((pattern) => pattern.test(source)) ? 'true' : 'false');
NODE
)"
[ "$MATRIX_CARDINALITY_PIN" = true ] \
  && check 'Provider selftest locks the documented 43 + 3 = 46 matrix cardinality' PASS \
  || check 'Provider selftest locks the documented 43 + 3 = 46 matrix cardinality' FAIL
if grep -Fq -- 'Reuse macOS Claude.ai authentication' "$CHANGELOG" \
  || grep -Fq -- 'immutable old/candidate roots per process with `--plugin-dir`' "$CHANGELOG"; then
  check 'Changelog no longer recommends the obsolete Keychain plugin-dir diagnostic' FAIL
else
  check 'Changelog no longer recommends the obsolete Keychain plugin-dir diagnostic' PASS
fi

printf '%s\n' '----' "test-promptfoo-session-upgrade: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
