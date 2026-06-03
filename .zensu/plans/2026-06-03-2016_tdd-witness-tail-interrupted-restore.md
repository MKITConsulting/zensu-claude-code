# TDD Plan: Witness — restore stdout `tail=` + `interrupted=`, fix the false exit-code contract

## Context
The TDD Bash witness (`hooks/post-bash-witness.sh`) records `exit=?` for EVERY command,
permanently. Ground truth (this machine's session transcript): Claude Code's Bash
`tool_response` keys are `stdout, stderr, interrupted, isImage, noOutputExpected` — there is
NO `exit_code` field. The hook reads `j.tool_response.exit_code`, so the `typeof === "number"`
test is always false → always `?`. Result: the Phase-6 cross-check has no result signal (greps
only `cmd="X"`), and `skills/tdd/SKILL.md` line ~297 falsely claims foreground runs capture a
real exit. `tool_response.stdout` and `.interrupted` DO exist, so capturing them gives a real
corroboration channel. Decision (user-approved): full — restore the data AND make the Phase-6
audit consume it. History: tail was logged once (dcbd80f), dropped in 0f9fc9a opportunistically
while fixing a real bash-3.2 field-split defect (old `IFS=$'\x01' read <<<` collapsed fields under
Apple bash 3.2.57). Re-adding tail on the NEW newline-delimited mechanism is safe: `JSON.stringify(tail)`
keeps the whole tail on one physical line (newlines escaped), so an extra field cannot desync the read.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash hooks + node one-liners; tests = `tests/structure/*.sh` custom PASS/FAIL harness + live `tests/e2e-tdd/run.sh` | **Coverage**: SKIPPED (no coverage tooling for bash)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present | (used by hook + tests) |
| claude CLI | CLI | `command -v claude` | present | live e2e verification (user authorized e2e) |
| e2e fixture | fixture | `tests/e2e-tdd/setup-fixtures.sh` | build on demand | build before live e2e |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Hook emits `tail=` + `interrupted=` (5-field newline-delimited, bash-3.2-safe) | tests/structure/test-post-bash-witness.sh + test-tdd-full-cycle.sh | — | [G] | 1 |
| S2 | Feature | SKILL.md Phase-6 audit consumes tail (EVIDENCE CONTRADICTION + corrected exit contract) | tests/structure/test-tdd-manager-patches.sh | S1 | [G] | 2 |
| S3 | Integration | e2e run.sh step-7: assert real-cycle witness line carries non-empty `tail=` | tests/e2e-tdd/run.sh (live) | S1 | [W] | 1 |
| S4 | Integration | docs/tdd-manager-workflow.md: format line + four-channel table add `interrupted`, note `exit=?` | — | S1 | [W] | 1 |
| S5 | Integration | Version bump 0.6.5 → 0.6.6 (plugin.json + marketplace.json + README badge + CHANGELOG) | tests/structure/test-zensu-help-skill.sh + test-reset-review-limit-skill.sh | — | [W] | 1 |

### Step S1 — Hook emits tail= + interrupted=
- [ ] **RED**: in test-post-bash-witness.sh — add `interrupted` to `make_payload`; FLIP H11 to assert `tail="PASS root/test.js"` + `interrupted=false`; new H12 (production-shaped payload, NO `exit_code`) asserts `exit=?` + `tail=`; new long-stdout case (>200 chars w/ newlines → tail = last 200, one line); H10 add `tail=` assert. In test-tdd-full-cycle.sh — extend W1 to assert `tail="ok"`; add W1b reality-shape (no exit_code → `exit=? tail=`). Run both → FAIL (hook emits no tail).
- [ ] **GREEN**: edit hooks/post-bash-witness.sh — node extractor emits `JSON.stringify(cmd)\nexit\nJSON.stringify(tail)\ninterrupted\nsession`; read 5 fields; printf `cmd=%s exit=%s tail=%s interrupted=%s`. Both harnesses PASS.

**Checkpoint**: `bash tests/structure/test-post-bash-witness.sh` + `/bin/sh …` + `bash tests/structure/test-tdd-full-cycle.sh` pass

### Step S2 — SKILL.md Phase-6 audit consumes tail
- [ ] **RED**: add assertion(s) to test-tdd-manager-patches.sh pinning `EVIDENCE CONTRADICTION` + tail-corroboration wording + corrected line-297 contract. Run → FAIL.
- [ ] **GREEN**: edit skills/tdd/SKILL.md lines ~297/302/305/312/370 per design. Run → PASS.

**Checkpoint**: `bash tests/structure/test-tdd-manager-patches.sh` passes

### Step S3 — e2e run.sh step-7 tail assert (Integration, live-verified)
- [ ] **WIRED**: keep `cmd=` grep, ADD non-empty `tail=` assert on the same real-cycle witness line. Verified by live e2e (Phase 6 step 5).

### Step S4 — docs/tdd-manager-workflow.md (Integration)
- [ ] **WIRED**: line ~307 format add `interrupted=<true|false>` + note `exit=?` in practice; line ~282 table add `interrupted`.

### Step S5 — Version bump 0.6.6 (Integration)
- [ ] **WIRED**: plugin.json `0.6.6`; marketplace.json `0.6.6`; README badge `version-0.6.6-green`; CHANGELOG new `## [0.6.6] - 2026-06-03`. Verified by version-derivation structure tests.

## Final Verification
- [G] All structure suites pass (incl. flipped H11, new H12/H13/H13b, full-cycle W1/W1b, SKILL.md R16-P1, version tests) under bash AND /bin/sh — 37/37 suites, witness 15/15 under bash 3.2
- [G] Live e2e `tests/e2e-tdd/run.sh` step 7 PASS — witness line `exit=? tail="<real stdout>" interrupted=false` (steps 3-6,8 failed on a transient API rate-limit, not the change)
- [G] `bash tests/run-all.sh` no regressions — 37/0
- [W] Coverage: SKIPPED (no coverage tooling for a bash plugin)
- [!] mtime heuristic flags S1/S2 test files as test-after (post-GREEN portability/literal refinements); RED-first proven by the log RED_FAIL entries + captured RED runs (H10-H13, R16-P1 failed before IMPL)
