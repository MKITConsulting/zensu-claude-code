#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
CONFIG="$ROOT/evals/session-control/promptfooconfig-upgrade.yaml"
SCENARIOS="$ROOT/evals/session-control/scenarios/upgrade.yaml"
PROVIDER="$ROOT/evals/session-control/lib/upgrade-provider.js"
RUNNER="$ROOT/evals/session-control/run-eval.sh"
SELFTEST="$ROOT/evals/session-control/tests/upgrade-provider-selftest.js"
NIGHTLY="$ROOT/.github/workflows/session-control-nightly.yml"
RELEASE="$ROOT/.github/workflows/release.yml"
CI="$ROOT/.github/workflows/ci.yml"
EVAL_README="$ROOT/evals/session-control/README.md"
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
contains 'Provider installs immutable create-once version roots' "$PROVIDER" "fail('immutable version destination already exists')"
contains 'Provider uses the shared immutable runtime fixture installer' "$PROVIDER" 'install-claude-runtime-fixture.js'
contains 'Provider holds one stream process for three old-runtime turns' "$PROVIDER" 'oldProcess.waitForResult(3)'
contains 'Provider emits bounded multi-turn protocol counters on drift' "$PROVIDER" 'init_count=${initEvents(oldProcess.events).length}; result_count=${oldProcess.results.length}'
contains 'Provider keeps the old process open through the fresh candidate run' "$PROVIDER" "fail('old process did not remain open through the fresh candidate session')"
contains 'Provider requires one matching init per completed stream turn' "$PROVIDER" 'requireTurnInitEvents(oldProcess.events, oldSessionId, 3'
contains 'Provider checks fresh candidate SessionStart' "$PROVIDER" "'session-start-session-control.sh', 1"
contains 'Provider checks fresh candidate Read gate' "$PROVIDER" "expectedPreToolHooks(candidateRoot, 'Read')"
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
contains 'Provider validates every configured Bash PreToolUse hook' "$PROVIDER" "expectedPreToolHooks(candidateRoot, 'Bash')"
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
contains 'Provider checks fresh candidate Stop hook' "$PROVIDER" "'stop-chain-enforcer.sh', 1, 'fresh candidate'"
contains 'Provider validates exact fresh record and baseline' "$PROVIDER" 'validateFreshState('
contains 'Diagnostic discovers only a direct child of isolated plugin data' "$PROVIDER" 'path.dirname(expectedPluginData) !== parent'
contains 'Installed-provider mode still requires the exact marketplace data id' "$PROVIDER" 'fresh candidate used the wrong installed-plugin data directory'
contains 'Provider preserves old runtime bytes after candidate install' "$PROVIDER" 'candidate installation modified the old version root'
contains 'Provider reports only count and hash for changed runtime entries' "$PROVIDER" 'sha256=${hash(Buffer.from(JSON.stringify(changed)'
contains 'Provider diagnoses final old-root drift without file content' "$PROVIDER" 'changedTreeEntries(oldInventoryBefore, oldInventoryFinal)'
contains 'Provider diagnoses final candidate drift without file content' "$PROVIDER" 'changedTreeEntries(candidateInventoryBefore, candidateInventoryFinal)'
contains 'Provider excludes only Claude root lifecycle markers from byte snapshots' "$PROVIDER" "if (!relative && (name === '.in_use' || name === '.orphaned_at')) continue"
contains 'Provider binds the old active-root marker to the exact process' "$PROVIDER" "requireInUseMarker(oldRoot, oldProcess.child.pid, true, 'old process')"
contains 'Provider requires candidate active-root marker cleanup' "$PROVIDER" "requireInUseMarker(candidateRoot, candidateProcess.child.pid, false, 'fresh candidate process')"
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
contains 'Real upgrade provider fails closed outside Unix hosts' "$PROVIDER" "process.platform !== 'darwin' && process.platform !== 'linux'"
contains 'Provider existing-login mode leaves config unset for Keychain auth' "$PROVIDER" 'if (!existingLogin) env.CLAUDE_CONFIG_DIR = configRoot'
contains 'Provider existing-login mode redirects plugin cache and data' "$PROVIDER" 'CLAUDE_CODE_PLUGIN_CACHE_DIR:'
contains 'Provider preflights existing-login auth without a model request' "$PROVIDER" "'auth', 'status', '--json'"
contains 'Provider forwards the non-secret macOS Keychain account selectors' "$PROVIDER" "'USER', 'LOGNAME'"
contains 'Provider pins diagnostic versions with session-local plugin roots' "$PROVIDER" 'existingLogin ? candidateRoot : null'
contains 'Provider diagnostic ignores user, project, and local settings' "$PROVIDER" "diagnosticRoot === null ? 'user' : ''"
contains 'Provider disables prompt-history persistence' "$PROVIDER" "CLAUDE_CODE_SKIP_PROMPT_HISTORY: '1'"
contains 'Provider uses exact Claude plugin-data id mapping' "$PROVIDER" "directory !== 'zensu-zensu'"
contains 'Provider isolates all conventional temporary-directory variables' "$PROVIDER" 'TEMP: isolatedTemp'
contains 'Provider isolates Claude internal temporary files' "$PROVIDER" 'CLAUDE_CODE_TMPDIR: isolatedTemp'
contains 'Provider records bounded existing-login host canaries' "$PROVIDER" 'existingLoginCanary(hostHome)'
contains 'Provider preserves the primary failure when a canary also changes' "$PROVIDER" 'primaryError.message += '\''; existing-login host config/cache canary also changed'\'''
contains 'Provider limits existing-login diagnostics to macOS' "$PROVIDER" 'existing-login upgrade diagnostics are supported only on macOS'
contains 'Runner forbids evidence publication from existing-login diagnostics' "$RUNNER" 'existing-login upgrade mode is a local diagnostic and cannot publish evidence'
contains 'Release operator command pins the Claude CLI version' "$RELEASE_GATE_DOC" 'ZENSU_EXPECTED_CLAUDE_VERSION=2.1.211'
contains 'Eval README provides the existing-login local diagnostic command' "$EVAL_README" 'ZENSU_UPGRADE_EXISTING_LOGIN=1'
contains 'Existing-login diagnostic derives the current local Claude version' "$EVAL_README" 'ZENSU_EXPECTED_CLAUDE_VERSION="$(claude --version'
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
contains 'Upgrade mode is part of the release aggregate' "$RUNNER" 'bash "$EVAL_DIR/run-eval.sh" upgrade "$@"'
contains 'Nightly runs the paid side-by-side profile' "$NIGHTLY" 'run: npm run session-control:upgrade'
contains 'Nightly fetches the historical tag' "$NIGHTLY" 'fetch-depth: 0'
[ -f "$SANDBOX_PREP" ] && check 'Linux sandbox prerequisite helper exists' PASS \
  || check 'Linux sandbox prerequisite helper exists' FAIL
contains 'Linux sandbox helper installs both required packages' "$SANDBOX_PREP" 'apt-get install -y --no-install-recommends bubblewrap socat'
contains 'Linux sandbox helper handles Ubuntu AppArmor user namespaces' "$SANDBOX_PREP" 'apparmor_restrict_unprivileged_userns'
contains 'Linux sandbox helper installs the documented bwrap profile' "$SANDBOX_PREP" 'profile bwrap /usr/bin/bwrap flags=(unconfined)'
contains 'Linux sandbox helper executes a network namespace probe' "$SANDBOX_PREP" '/usr/bin/bwrap --unshare-net --ro-bind / / /bin/true'
if [ "$(grep -Fc 'bash .github/scripts/prepare-claude-sandbox-linux.sh' "$NIGHTLY")" = 1 ] \
  && [ "$(grep -Fc 'bash .github/scripts/prepare-claude-sandbox-linux.sh' "$RELEASE")" = 2 ]; then
  check 'Every paid Linux workflow prepares the mandatory sandbox' PASS
else
  check 'Every paid Linux workflow prepares the mandatory sandbox' FAIL
fi
if [ "$(grep -Fc 'runs-on: ubuntu-24.04' "$NIGHTLY")" = 1 ] \
  && [ "$(grep -Fc 'runs-on: ubuntu-24.04' "$RELEASE")" = 2 ]; then
  check 'Paid Linux workflows pin Ubuntu 24.04' PASS
else
  check 'Paid Linux workflows pin Ubuntu 24.04' FAIL
fi
if [ "$(grep -Fc 'fetch-depth: 0' "$CI")" = 2 ]; then
  check 'Both deterministic CI checkouts fetch the pinned historical tag' PASS
else
  check 'Both deterministic CI checkouts fetch the pinned historical tag' FAIL
fi
if [ "$(grep -Fc "ZENSU_EXPECTED_CLAUDE_VERSION: '2.1.211'" "$RELEASE")" = 2 ]; then
  check 'Both release gates explicitly pin the evaluated Claude version' PASS
else
  check 'Both release gates explicitly pin the evaluated Claude version' FAIL
fi
if [ "$(grep -Fc "ZENSU_UPGRADE_EXISTING_LOGIN: '0'" "$RELEASE")" = 2 ] \
  && grep -Fq "ZENSU_UPGRADE_EXISTING_LOGIN: '0'" "$NIGHTLY"; then
  check 'Paid upgrade gates explicitly forbid existing-login diagnostics' PASS
else
  check 'Paid upgrade gates explicitly forbid existing-login diagnostics' FAIL
fi

printf '%s\n' '----' "test-promptfoo-session-upgrade: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
