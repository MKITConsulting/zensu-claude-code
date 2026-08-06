#!/bin/bash
# Structure gate for the live Promptfoo CAS/security suite.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
EVAL_DIR="$PLUGIN_DIR/evals/reset-review-limit"
CFG="$EVAL_DIR/promptfooconfig.yaml"
HAPPY="$EVAL_DIR/scenarios/reset-cas-happy.yaml"
INVALID="$EVAL_DIR/scenarios/reset-invalid-state.yaml"
SIDECAR="$EVAL_DIR/scenarios/reset-sidecar-isolation.yaml"
FIXTURE="$EVAL_DIR/test-projects/empty-host/CLAUDE.md"
README="$EVAL_DIR/README.md"
PROVIDER="$EVAL_DIR/provider.sh"
ASSERTION="$EVAL_DIR/assertions/sealed-attestation.js"
STREAM_EVIDENCE="$EVAL_DIR/lib/stream-evidence.js"
SEEDER="$EVAL_DIR/lib/seed-state.js"
ATTESTOR="$EVAL_DIR/lib/sealed-attestation.js"
VERIFIER="$EVAL_DIR/verify-results.js"
RUNNER="$EVAL_DIR/run-eval.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = PASS ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

for f in "$CFG" "$HAPPY" "$INVALID" "$SIDECAR" "$FIXTURE" "$README" \
  "$PROVIDER" "$ASSERTION" "$STREAM_EVIDENCE" "$SEEDER" "$ATTESTOR" "$VERIFIER" "$RUNNER"; do
  [ -f "$f" ] \
    && check "P1 file exists: ${f#$PLUGIN_DIR/}" PASS \
    || check "P1 file exists: ${f#$PLUGIN_DIR/}" FAIL
done

if grep -qF 'exec: ./provider.sh' "$CFG" \
  && grep -qF './test-projects/empty-host' "$CFG" \
  && grep -qF 'file://assertions/sealed-attestation.js' "$CFG"; then
  check "P2 config uses the sealed provider, isolated fixture, and provider assertion" PASS
else
  check "P2 config uses the sealed provider, isolated fixture, and provider assertion" FAIL
fi

if grep -qE '^\s+agent:' "$CFG" || grep -E '^\s*-\s+id:' "$CFG" | grep -qF 'agent:'; then
  check "P3 config invokes the skill directly without forcing an agent" FAIL
else
  check "P3 config invokes the skill directly without forcing an agent" PASS
fi

for scenario in reset-cas-happy reset-invalid-state reset-sidecar-isolation; do
  grep -qF "file://scenarios/${scenario}.yaml" "$CFG" \
    && check "P4 config registers $scenario" PASS \
    || check "P4 config registers $scenario" FAIL
done

if grep -qE '^  repeat: 3$' "$CFG" && grep -qE '^  maxConcurrency: 2$' "$CFG"; then
  check "P5 three scenarios repeat three times with bounded concurrency (9 live runs)" PASS
else
  check "P5 three scenarios repeat three times with bounded concurrency (9 live runs)" FAIL
fi

for f in "$HAPPY" "$INVALID" "$SIDECAR"; do
  base="${f##*/}"
  if grep -qF '/zensu:reset-review-limit' "$f" \
    && grep -qE '^  scenario_id: reset-(cas-happy|invalid-state|sidecar-isolation)$' "$f" \
    && ! grep -qE '^assert:|type: javascript' "$f"; then
    check "P6 $base binds a scenario id and delegates grading to sealed provider evidence" PASS
  else
    check "P6 $base binds a scenario id and delegates grading to sealed provider evidence" FAIL
  fi
done

if grep -qF 'provider-seed' "$SEEDER" \
  && grep -qF 'reviewRound: round' "$SEEDER" \
  && grep -qF 'snapshot(projectRoot, coreFile)' "$SEEDER" \
  && grep -qF 'provider-before.json' "$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh" \
  && grep -qF 'Do not seed, repair, or otherwise mutate state before the skill' "$HAPPY"; then
  check "P7 provider synchronously seeds and snapshots happy-path state before Claude starts" PASS
else
  check "P7 provider synchronously seeds and snapshots happy-path state before Claude starts" FAIL
fi

if grep -qF "state.reviewRound = '3'" "$SEEDER" \
  && grep -qF 'provider independently verifies byte-for-byte preservation' "$INVALID" \
  && grep -qF "beforeEnvelope?.snapshot?.raw_sha256 === after?.raw_sha256" "$ATTESTOR"; then
  check "P8 provider owns malformed-state seeding and byte-preservation proof" PASS
else
  check "P8 provider owns malformed-state seeding and byte-preservation proof" FAIL
fi

if grep -qF "fs.symlinkSync('retired-target.txt'" "$SEEDER" \
  && grep -qF "rounds-retired.json" "$SEEDER" \
  && grep -qF 'byte-identical sidecars' "$SIDECAR" \
  && grep -qF 'canonical(sidecars) === canonical(after?.sidecars)' "$ATTESTOR"; then
  check "P9 provider owns sidecar fixtures and verifies byte-identical isolation" PASS
else
  check "P9 provider owns sidecar fixtures and verifies byte-identical isolation" FAIL
fi

if grep -En 'rm -f .*rounds-|Removed:.*rounds-|counter file\(s\) deleted|No round counter files' \
  "$HAPPY" "$INVALID" "$SIDECAR" "$README" "$FIXTURE" >/dev/null; then
  check "P10 suite has no retired sidecar-search/deletion contract" FAIL
else
  check "P10 suite has no retired sidecar-search/deletion contract" PASS
fi

if [ -x "$PROVIDER" ] && grep -qF 'ZENSU_RESET_REVIEW_LIMIT_ATTESTATION=1' "$PROVIDER" \
  && grep -qF 'claude-promptfoo-wrapper.sh' "$PROVIDER"; then
  check "P11 provider enables wrapper-owned evidence and delegates to isolated Claude wrapper" PASS
else
  check "P11 provider enables wrapper-owned evidence and delegates to isolated Claude wrapper" FAIL
fi

if command -v node >/dev/null 2>&1; then
  CFG_N="$(command -v cygpath >/dev/null 2>&1 && cygpath -m "$CFG" || printf '%s' "$CFG")"
  if node -e "
    const fs=require('fs'), txt=fs.readFileSync('$CFG_N','utf8');
    for (const k of ['description:','providers:','prompts:','tests:','evaluateOptions:']) {
      if (!new RegExp('^'+k, 'm').test(txt)) process.exit(1);
    }
  "; then
    check "P12 promptfooconfig has all required top-level keys" PASS
  else
    check "P12 promptfooconfig has all required top-level keys" FAIL
  fi
else
  check "P12 node unavailable (shape check skipped)" PASS
fi

if grep -qF "exact_skill_tool_use_count" "$STREAM_EVIDENCE" \
  && grep -qF "successful_skill_result_count" "$STREAM_EVIDENCE" \
  && grep -qF "snapshot(projectRoot, coreFile)" "$SEEDER" \
  && grep -qF "[reset-review-limit-attestation]" "$ATTESTOR" \
  && grep -qF "evidence_digest" "$ASSERTION"; then
  check "P13 provider owns exact Skill evidence, independent state snapshots, and digest verification" PASS
else
  check "P13 provider owns exact Skill evidence, independent state snapshots, and digest verification" FAIL
fi

if grep -qF "rows.length !== 9" "$VERIFIER" \
  && grep -qF "['reset-cas-happy', 3]" "$VERIFIER" \
  && grep -qF "['reset-invalid-state', 3]" "$VERIFIER" \
  && grep -qF "['reset-sidecar-isolation', 3]" "$VERIFIER" \
  && grep -qF 'node "$EVAL_DIR/verify-results.js" "$RESULT"' "$RUNNER"; then
  check "P14 runner enforces the exact nine-row 3x3 scenario-id multiset" PASS
else
  check "P14 runner enforces the exact nine-row 3x3 scenario-id multiset" FAIL
fi

if grep -qF 'reset-review-limit-attestation' "$PLUGIN_DIR/scripts/claude-stream-render.js"; then
  check "P15 model content cannot forge the reserved reset attestation frame" PASS
else
  check "P15 model content cannot forge the reserved reset attestation frame" FAIL
fi

if grep -qF 'DRY_RUN=1 ./provider.sh probe' "$EVAL_DIR/run-self-check.sh" \
  && grep -qF 'cwd=./test-projects/empty-host' "$EVAL_DIR/run-self-check.sh"; then
  check "P16 provider self-check round-trips scenario_id and working_dir without JSON corruption" PASS
else
  check "P16 provider self-check round-trips scenario_id and working_dir without JSON corruption" FAIL
fi

if grep -qF 'ZENSU_PLUGIN_DIR_OVERRIDE="$ROOT"' "$PROVIDER" \
  && grep -qF 'resolved_plugin_root' "$ATTESTOR" \
  && grep -qF 'runtime_digest' "$ATTESTOR" \
  && grep -qF 'computeRuntimeDigest(root, '\''claude'\'')' "$ASSERTION"; then
  check "P17 live eval and sealed evidence bind to the exact checkout runtime digest" PASS
else
  check "P17 live eval and sealed evidence bind to the exact checkout runtime digest" FAIL
fi

if grep -qF 'fs\.unlink(?:Sync)?' "$STREAM_EVIDENCE" \
  && grep -qF "name === 'Glob' || name === 'Grep'" "$STREAM_EVIDENCE" \
  && grep -qF "command: 'rm -f stale.json'" "$EVAL_DIR/tests/sealed-evidence.test.js" \
  && grep -qF "command: 'find . -name" "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P18 search/deletion detector has functional Bash, Glob, and Grep regression cases" PASS
else
  check "P18 search/deletion detector has functional Bash, Glob, and Grep regression cases" FAIL
fi

if grep -qF 'session-start-barrier.sh' "$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh" \
  && grep -qF 'Session Control startup did not complete' "$EVAL_DIR/lib/session-start-barrier.sh" \
  && grep -qF 'invalid scenario must stay valid through SessionStart' "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P19 invalid-state tamper waits for valid Session Control startup and provider barrier" PASS
else
  check "P19 invalid-state tamper waits for valid Session Control startup and provider barrier" FAIL
fi

if grep -qF 'require_disposable_environment: true' "$CFG" \
  && grep -qF 'ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1' "$RUNNER" \
  && grep -qF 'ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 DRY_RUN=1' "$EVAL_DIR/run-self-check.sh"; then
  check "P20 unrestricted Claude eval requires an explicit disposable-environment acknowledgement" PASS
else
  check "P20 unrestricted Claude eval requires an explicit disposable-environment acknowledgement" FAIL
fi

if grep -qF 'function resetReviewBudget(options)' "$PLUGIN_DIR/hooks/lib/session-control-core-v1.js" \
  && grep -qF 'tdd_reset_review_budget()' "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" \
  && grep -qF 'expectedRevision: Number(process.env.EXPECTED_REVISION)' "$PLUGIN_DIR/hooks/lib/zensu-tdd-phase.sh" \
  && grep -qF 'after.state?.revision === before.state?.revision + 1' "$ATTESTOR" \
  && grep -qF 'after.state?.selfReviewFixed === false' "$ATTESTOR"; then
  check "P21 complete reset is one expected-revision CAS and one revision advance" PASS
else
  check "P21 complete reset is one expected-revision CAS and one revision advance" FAIL
fi

if grep -qF 'failed_preflight_bash_result_count' "$STREAM_EVIDENCE" \
  && grep -qF 'capture?.post_skill_bash_call_count === 1' "$ATTESTOR" \
  && grep -qF 'capture?.atomic_reset_bash_call_count === 0' "$ATTESTOR" \
  && grep -qF 'zero-Bash evidence' "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P22 invalid-state row proves a failed preflight after Skill load and no reset mutation" PASS
else
  check "P22 invalid-state row proves a failed preflight after Skill load and no reset mutation" FAIL
fi

if grep -qF 'init_git: true' "$CFG" \
  && grep -qF 'fixture_manifest' "$SEEDER" \
  && grep -qF 'fixture_manifest_unchanged' "$ATTESTOR" \
  && grep -qF 'CLAUDE.md content mutation' "$EVAL_DIR/tests/sealed-evidence.test.js" \
  && grep -qF 'prototype-named file' "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P23 provider seals the full fixture outside the one mutable CAS file" PASS
else
  check "P23 provider seals the full fixture outside the one mutable CAS file" FAIL
fi

if grep -qF 'reset-review-limit eval requires Claude Code CLI 2.1.221' "$PLUGIN_DIR/scripts/claude-promptfoo-wrapper.sh" \
  && grep -qF 'claude_code_version' "$ATTESTOR" \
  && grep -qF "attestation.claude_code_version !== '2.1.221'" "$ASSERTION" \
  && grep -qF "'9.9.9'" "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P24 live spend and sealed evidence are pinned to Claude Code 2.1.221" PASS
else
  check "P24 live spend and sealed evidence are pinned to Claude Code 2.1.221" FAIL
fi

if grep -qF "process.platform === 'win32'" "$EVAL_DIR/tests/sealed-evidence.test.js" \
  && grep -qF "runScenario('reset-cas-happy', reset)" "$EVAL_DIR/tests/sealed-evidence.test.js" \
  && grep -qF "runScenario('reset-invalid-state', null)" "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P25 Windows skips only the unprivileged symlink sidecar row" PASS
else
  check "P25 Windows skips only the unprivileged symlink sidecar row" FAIL
fi

if grep -qF "FILE_WRITE_TOOLS" "$STREAM_EVIDENCE" \
  && grep -qF "name: 'Write'" "$EVAL_DIR/tests/sealed-evidence.test.js" \
  && grep -qF "name: 'apply_patch'" "$EVAL_DIR/tests/sealed-evidence.test.js"; then
  check "P26 provider rejects model file-write tools independently of prose" PASS
else
  check "P26 provider rejects model file-write tools independently of prose" FAIL
fi

echo "----"
echo "test-promptfoo-reset-review-limit: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
