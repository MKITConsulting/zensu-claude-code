# TDD Plan: Harden witness tail corroboration + close coverage gaps

## Context
Follow-up to the v0.6.6 witness tail/interrupted restore (same worktree, uncommitted). Code-review
surfaced 3 cheap in-scope items + 2 optional extras, none critical/important. Hook already emits
`[TS] BASH cmd=<json> exit=<rc|?> tail=<json-stdout-last200> interrupted=<true|false>`.
**Approach**: Strict Red/Green TDD | **Tech Stack**: bash hooks + node one-liners; tests = `tests/structure/*.sh` | **Coverage**: SKIPPED (no tooling)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present | used by hook + tests |

## Status Legend
| [ ] Not started | [R] RED | [I] Implemented | [G] GREEN | [RF] Refactored/characterization | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Field-scope Phase-6 corroboration marker scan to the isolated `tail=` value | tests/structure/test-tdd-manager-patches.sh | — | [G] | 1 |
| S2 | Characterization | Lock v0.6.6 behavior: 200-char truncation + positive `interrupted=true` + `tail=` quote round-trip | tests/structure/test-post-bash-witness.sh | — | [RF] | 1 |
| S3 | Integration | docs note: witness tail is stdout-only (stderr failure summaries → empty tail) | — | — | [W] | 1 |

### Step S1 — Field-scope the corroboration marker scan (Feature)
- [ ] **RED**: add R16-P2 to test-tdd-manager-patches.sh pinning an explicit tail-extraction recipe phrase (e.g. `up to ` + `interrupted=`). Run → FAIL (SKILL.md has no recipe).
- [ ] **GREEN**: edit skills/tdd/SKILL.md:312 — scan ONLY the `tail=` value (substring after ` tail=` up to ` interrupted=`), not the whole line.

### Step S2 — Coverage characterization (existing v0.6.6 behavior)
- [ ] H13c: stdout >200 chars with HEAD-MARKER + END-MARKER → JSON-decode witness `tail=`, assert length<=200 AND head-marker ABSENT AND END-MARKER present (proves slice(-200)).
- [ ] H14: `make_payload ... true` → assert `interrupted=true` (true-branch).
- [ ] H15: stdout with literal `"` → JSON-decode witness `tail=` equals original (round-trip).
- Expected GREEN on creation (locks behavior); a failure reveals a real bug.

### Step S3 — docs stdout-only note (Integration)
- [ ] WIRED: one line in docs/tdd-manager-workflow.md that the tail is stdout-only.

## Out of Scope
- stderr capture in the hook; secret redaction (bounded by gitignore + local + ZENSU_TEST_WITNESS=off).

## Final Verification
- [G] test-post-bash-witness.sh green under bash AND /bin/sh (18/18 incl H13c/H14/H15)
- [G] test-tdd-manager-patches.sh R16-P2 green (50/0)
- [G] tests/run-all.sh 37/37 — no regressions
- [G] No version bump (stays 0.6.6); no live e2e (no hook behavior change — F1 prose, F2 tests, F3 doc)
