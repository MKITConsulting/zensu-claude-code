# TDD Plan: CHANGELOG `[Unreleased]` heading regex — review findings round (M2 subshell wrap, MUT_COPY reuse, plan-wording accuracy)

## Context

Code review identified three findings on the prior round-7 work (plan + test from
`2026-05-25-1635_tdd-changelog-unreleased-heading-re-single-source.md`):

1. **Plan wording inaccuracy** (plan line 113). The bullet claims the regex
   literal `'^## \[Unreleased\]$'` appears exactly ONCE in
   `tests/structure/test-changelog-unreleased-resolver-entries.sh`. Empirically
   it appears 3+ times: line 14 (production), line 76 (M1 sed fixture
   construction LHS), line 88 (M2 sed fixture construction LHS), and line 92
   (M2 loose mutation). The single-source-of-truth invariant for production
   code IS upheld (sed lines are fixture mutations, not parallel production
   sources). Wording must reflect actual count and locations post-refactor.

2. **M2 save/restore variable leakage** (test file lines 90-94). The pattern
   `M2_STRICT_SAVED="$HEADING_RE" ... HEADING_RE='^## \[Unreleased\]'
   ... HEADING_RE="$M2_STRICT_SAVED"` works under the current shell flags but
   is fragile to refactors that add downstream consumers between the loosen
   and the restore (any newly-added consumer would silently see the loose
   value). Replace with a subshell wrap that structurally guarantees the loose
   value cannot escape.

3. **Wasted I/O** (lines 86-88). The `MUT2_COPY` fixture is byte-identical to
   `MUT_COPY` built on lines 74-76 (same source, same sed). Drop the
   `MUT2_COPY` block and let M2 reuse `$MUT_COPY`.

**Approach**: Strict Red/Green TDD (test-tightening on a test file) |
**Tech Stack**: bash + awk + grep structure tests |
**Coverage**: SKIPPED (no coverage tool wired for bash structure tests)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | n/a |
| awk | CLI | `command -v awk` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |
| mktemp | CLI | `command -v mktemp` | present | n/a |
| sed | CLI | `command -v sed` | present | n/a |
| cp | CLI | `command -v cp` | present | n/a |
| `CHANGELOG.md` `## [Unreleased]` heading | fixture | `grep -qE '^## \[Unreleased\]$' CHANGELOG.md` | present | n/a |

No missing preconditions; no AskUserQuestion escalation required.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Add M3 outer-scope-integrity sub-test that proves HEADING_RE in OUTER shell is unchanged after the M2 block (structurally proves the subshell-wrap pattern) | tests/structure/test-changelog-unreleased-resolver-entries.sh | — | [G] | 1 |
| S2 | Refactoring | Replace M2 save/loosen/extract/restore with subshell-wrap; drop `MUT2_COPY`, reuse `$MUT_COPY` | tests/structure/test-changelog-unreleased-resolver-entries.sh | S1 | [RF] | 1 |
| S3 | Integration | Reword plan line 113 to reflect actual regex-literal count and locations post-refactor | .zensu/plans/2026-05-25-1635_tdd-changelog-unreleased-heading-re-single-source.md | S2 | [W] | 1 |

### Step S1 — Add M3 outer-scope-integrity sub-test (RED)

- [ ] **RED**: Add an `M3` assertion AFTER the existing M2 block that captures
  `HEADING_RE` in the OUTER shell and asserts it equals the original strict
  value `^## \[Unreleased\]$`. Against the CURRENT save/restore code this PASSES
  trivially (restore line resets it), so the meaningful RED comes from a
  HYPOTHETICAL broken refactor that forgets to subshell-wrap — that would FAIL
  because the loose value would leak. To make M3 RED-meaningful in the strict
  TDD sense, we use a deliberately-failing initial assertion: capture
  `HEADING_RE` BEFORE M2 runs, capture again AFTER, and assert equality. The
  RED step temporarily changes the comparison literal to a known-wrong value
  to force a FAIL, then GREEN restores correctness.

  Actually, simpler and more honest: the new M3 assertion proves a structural
  property (outer-scope `HEADING_RE` unchanged after the M2 block). The
  test-first RED step adds M3 with the assertion BEFORE refactoring M2. With
  the OLD save/restore code, M3 already PASSES — so M3 alone does not give a
  meaningful RED.

  To get a meaningful RED, the test cycle for S1 is:
  1. Write M3 assertion against a TEMPORARILY-BROKEN M2 block (delete the
     `HEADING_RE="$M2_STRICT_SAVED"` restore line). Run test. M3 FAILS
     because loose value leaks → captured-after value differs from
     captured-before value.
  2. Restore the M2 restore line. Run test. M3 PASSES.

  This proves M3 is a real assertion that catches leakage.

- [ ] **GREEN**: After S1 RED proves M3 catches leakage, leave the OLD M2
  save/restore pattern in place (S2 will replace it). M3 still passes against
  the OLD pattern. Then S2 replaces the OLD pattern with subshell-wrap, and
  M3 continues to pass (structurally guaranteed).

**Checkpoint after S1**: `bash tests/structure/test-changelog-unreleased-resolver-entries.sh`
shows 12 PASS / 0 FAIL (11 prior + M3).

### Step S2 — Subshell wrap M2 + reuse `$MUT_COPY` (Refactoring)

- [ ] **R1 (GREEN-BEFORE)**: Run the test file; verify 12 PASS / 0 FAIL.
- [ ] **R2 (CHANGE)**: Replace lines 86-94 with:
  ```bash
  EXTRACTED_M2_STRICT="$(extract_unreleased_section "$MUT_COPY")"
  EXTRACTED_M2_LOOSE="$(HEADING_RE='^## \[Unreleased\]'; extract_unreleased_section "$MUT_COPY")"
  ```
  Drop `MUT2_COPY` setup (3 lines). Drop `M2_STRICT_SAVED`. The
  subshell-wrap idiom `$( ... ; ... )` ensures `HEADING_RE='...'` mutation
  is local to the command substitution.
- [ ] **R3 (GREEN-AFTER)**: Run the test file; verify 12 PASS / 0 FAIL still.
  M2 still passes (cmp `EXTRACTED_M2_STRICT` empty vs `EXTRACTED_M2_LOOSE`
  non-empty). M3 still passes (HEADING_RE unchanged in outer scope, now
  structurally guaranteed by subshell isolation).
- [ ] **Mutation-revalidate** all three round-6 scenarios:
  - Loosen ONLY helper regex → M1 FAIL, M2 PASS.
  - Loosen ONLY awk regex → M1 PASS, M2 FAIL.
  - Loosen shared `HEADING_RE` → both FAIL.

**Checkpoint after S2**: same test file 12 PASS / 0 FAIL + full structure
suite 240 PASS / 0 FAIL aggregate.

### Step S3 — Reword plan line 113 (Integration)

- [ ] **WIRE**: Update
  `.zensu/plans/2026-05-25-1635_tdd-changelog-unreleased-heading-re-single-source.md`
  line 113 to reflect actual post-refactor regex-literal occurrences:
  - line 14 (production `HEADING_RE`)
  - line 76 (M1 sed fixture-construction LHS)
  After the S2 refactor, lines 88 and 92 no longer contain the literal (the
  MUT2_COPY block is gone and the loose value is inside a subshell). New
  reworded text per finding #1 fix instruction.

**Checkpoint after S3**: plan file diff visible; no test impact.

## Final Verification

- [G] All structure tests green (16 files, 240 asserts PASS / 0 FAIL).
- [G] M3 outer-scope-integrity sub-test passes structurally (subshell wrap).
- [G] 3-scenario mutation revalidation still holds post-refactor:
  - helper-only loose: M1 FAIL M2 PASS M3 PASS
  - awk-only loose: M1 PASS M2 FAIL M3 PASS
  - shared HEADING_RE loose: M1 FAIL M2 FAIL M3 PASS
- [G] Plan + log artifacts saved under `.zensu/plans/` and `.zensu/logs/`.
- [G] Plan line 113 reworded to reflect actual count + locations.
