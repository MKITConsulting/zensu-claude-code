# TDD Plan: Round-3 Post-Review Auto-Fix Findings

## Context
Two findings from the round-3 code-review pass:

**F1** — `hooks/lib/zensu-tdd-phase.sh:132` / `evals/config-gate/test-pre-edit-concurrent-write.sh:65-67` — Stale-lock recovery test is a dead test on Linux/CI: it sets `TDD_DISABLE_FLOCK=1` to force the mkdir-fallback, but the hook code at line 132 never reads that env var. On macOS the test exercises mkdir-fallback only because flock is genuinely absent; on Linux with flock installed, the flock branch silently succeeds against the stale lockdir without exercising the F4 recovery code.
Fix: gate the flock branch on `[ "${TDD_DISABLE_FLOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1`. Add 2 asserts to `test-pre-edit-concurrent-write.sh` that prove the env var is honored.

**F2** — `hooks/pre-edit-tdd-reminder.sh:71` / `evals/config-gate/test-pre-edit-greenpass-tight.sh` — `decide_allow()` returns 0 for REFACTOR phase unconditionally, with no requirement that GREEN_PASS preceded it. Reviewer recommendation (option b): codify the trust-model boundary in the test suite. Add 2 documenting asserts (REFACTOR from UNINITIALIZED, REFACTOR from RED_FAIL) plus a banner echo line and a CHANGELOG bullet under round-3 Security.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash + Node.js helpers, no compile step | **Coverage**: SKIPPED (no native coverage tooling for bash hook scripts)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| F1 | Feature | `tdd_write_phase` honors `TDD_DISABLE_FLOCK=1` to force mkdir-fallback path | `evals/config-gate/test-pre-edit-concurrent-write.sh` | — | [G] | 1 |
| F2 | Feature | Test-suite codifies REFACTOR-phase trust gap (UNINITIALIZED + RED_FAIL transitions) | `evals/config-gate/test-pre-edit-greenpass-tight.sh` | — | [G] | 1 |
| F3 | Integration | CHANGELOG bullet under round-3 Security documenting REFACTOR trust gap | `CHANGELOG.md` | F2 | [W] | 1 |

### Step F1 — flock-availability guard honors `TDD_DISABLE_FLOCK=1`
- [G] **RED**: 2 asserts added to `test-pre-edit-concurrent-write.sh` (sentinel-file probe in stale lockdir). Verified via simulated-Linux fake-flock-on-PATH that the new asserts FAILED on pre-fix code (sentinel survived → env var not honored) and PASS on fixed code (sentinel removed by mkdir-fallback recovery).
- [G] **GREEN**: Line 132 of `hooks/lib/zensu-tdd-phase.sh` now reads `if [ "${TDD_DISABLE_FLOCK:-}" != "1" ] && command -v flock >/dev/null 2>&1; then`.

### Step F2 — REFACTOR trust-gap codified in test suite
- [G] **RED**: Inverted asserts (expects deny) added first; ran and saw both FAIL with `got: allow`, confirming `decide_allow()` returns 0 for REFACTOR unconditionally.
- [G] **GREEN**: Asserts flipped to expect allow with "known agent-trust gap" labels and a banner echo `[INFO] Documenting REFACTOR known-gap …`. Run → 8/8 PASS.

### Step F3 — CHANGELOG round-3 Security bullet
- [W] Round-3 Security section added under `## [Unreleased]` documenting both fixes (TDD_DISABLE_FLOCK env-var honoring + REFACTOR trust-gap codification) with rationale and assert counts.

**Checkpoint**: `bash evals/config-gate/run-eval.sh` returns 57/57 PASS (each modified test file gained +2 asserts internally). `bash evals/tdd-review-chain/run-eval.sh --self-check` 30/31 stable. `bash evals/tdd-manager-pretool/run-eval.sh --self-check` 25/25.

## Final Verification
- [G] config-gate suite green (57/57 file-level; +2 asserts each in F1 and F2 test files = +4 asserts total)
- [G] tdd-review-chain suite stable (30/31 — 1 pre-existing expected FAIL)
- [G] tdd-manager-pretool suite green (25/25)
- [G] F1 sanity check: simulated-Linux fake-flock-on-PATH verified env-var honored (sentinel-file probe in stale lockdir).
- [G] Coverage: N/A (bash scripts)
- [G] Build: N/A (no compile step; all manifest JSONs validate)
