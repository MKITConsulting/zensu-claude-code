#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SESSION="$ROOT/tests/structure/test-session-control-claude.sh"
REVIEWER="$ROOT/tests/structure/test-reviewer-capability-gate.sh"
CORRUPTION="$ROOT/tests/structure/test-tdd-state-corruption-fail-closed.sh"
MARKETPLACE="$ROOT/evals/session-control/tests/marketplace-fixture-selftest.sh"
RESET="$ROOT/evals/reset-review-limit/tests/sealed-evidence.test.js"
WORKFLOW="$ROOT/.github/workflows/ci.yml"
PHASE="$ROOT/hooks/lib/zensu-tdd-phase.sh"
SESSION_HOOK="$ROOT/hooks/session-start-session-control.sh"
CORE="$ROOT/hooks/lib/session-control-core-v1.js"
BINDER="$ROOT/hooks/lib/claude-hook-session-v1.js"
AUTOPILOT_STATE="$ROOT/hooks/lib/zensu-autopilot-state.sh"
VCS="$ROOT/hooks/lib/zensu-vcs.sh"
RESET_SNAPSHOT="$ROOT/evals/reset-review-limit/lib/state-snapshot.js"
AUTOPILOT_FULL="$ROOT/tests/structure/test-autopilot-full-cycle.sh"
ENRICHMENT="$ROOT/scripts/claude-enrichment-render.js"
PROMPTFOO_WRAPPER="$ROOT/scripts/claude-promptfoo-wrapper.sh"
PASS=0; FAIL=0
check() {
  if [ "$2" = PASS ]; then printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1));
  else printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

for file in "$SESSION" "$REVIEWER" "$CORRUPTION" "$MARKETPLACE"; do
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

if grep -qF 'name: Windows Core lease canary' "$WORKFLOW" \
  && grep -A2 -F 'name: Windows Core lease canary' "$WORKFLOW" | grep -qF "runner.os == 'Windows'" \
  && grep -A5 -F 'name: Windows Core lease canary' "$WORKFLOW" | grep -qF 'test-tdd-no-flock-external-lease.sh' \
  && grep -A5 -F 'name: Windows Core lease canary' "$WORKFLOW" | grep -qF 'tests/session-control/run.sh'; then
  check "Windows CI fails fast on the cross-process Core lease" PASS
else
  check "Windows CI fails fast on the cross-process Core lease" FAIL
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
