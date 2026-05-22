# TDD Plan: Isolation-safe file-exists assertion + tightened drift regex

## Context

Two findings from code review:

1. **`assert-file-exists.js` is broken under APFS-clone isolation.** The wrapper
   isolates `working_dir` into a `mktemp -d` clone via `cp -cR`, executes Claude
   there, then `trap cleanup EXIT` removes the clone. Meanwhile the assertion
   resolves `expected_paths` from promptfoo's cwd, pointing at the original
   repo path that the wrapper isolates from. Scenarios 01/02/09 only pass on
   the current working tree because of stale untracked leftover files. On a
   clean checkout, all three happy-path scenarios will FAIL.

   Fix: switch `assert-file-exists.js` to transcript-grep. The stream-json
   transcript wrapper produces lines like
   `[tool_use: Write] input={"file_path":"…/reverseString.ts",…}`. The
   assertion now checks the transcript (the `output` string passed by
   promptfoo) for `[tool_use: Write]` OR `[tool_use: Edit]` markers whose
   subsequent `input=…` JSON includes the expected basename. Drops the
   `require('fs')` dependency entirely. Export signature stays
   `({ output, context }) => ({ pass, score, reason })` — scenario YAMLs do
   not change.

2. **Drift-audit regex over-matches.** `precondition-drift-audit.yaml`
   assertion #2 uses
   `no.*(implementation|implement|files modified|files changed)` — this
   matches "no implementation drift detected" (a false-negative summary).
   The third assertion's negative-guard does not catch that phrase either.

   Fix: anchor the "no implementation / no files modified" branches to an
   audit context (`audit found`, `audit reported`, or `no audit`) and extend
   the third assertion's negative-guard.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash + Node assertions (no test runner beyond ad-hoc `bash tests/structure/*.sh`) | **Coverage**: SKIPPED (no coverage tooling configured)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Rewrite `assert-file-exists.js` body — transcript-grep instead of `fs.existsSync`. Match logic: for each `expected_paths`, check transcript for `[tool_use: Write]` or `[tool_use: Edit]` whose `input=…` references the path basename. | `tests/structure/test-file-exists-replacement.sh` | — | [G] | 1 |
| S2 | Feature | Update `tests/structure/test-file-exists-replacement.sh` — drop `fs.existsSync`-existence check, add transcript-grep behavioral test (Write-marker with target path PASSES; Edit-marker with target path PASSES; non-matching transcript FAILS; missing `expected_paths` FAILS). | self | S1 | [G] | 1 |
| S3 | Bug Fix | Tighten assertion #2 regex in `precondition-drift-audit.yaml`. New regex requires audit-anchor for the "no implementation / no files modified" branches. | `tests/structure/test-drift-audit-regex.sh` | — | [G] | 1 |
| S4 | Bug Fix | Extend assertion #3 negative-guard regex in `precondition-drift-audit.yaml` to also catch `no [a-z ]*(implementation\|drift) (found\|detected\|reported\|present\|to.*report)`. | `tests/structure/test-drift-audit-regex.sh` | S3 | [G] | 1 |
| S5 | Feature | Add 3 new fixture-based cases to `tests/structure/test-drift-audit-regex.sh`. Fixture A: audit-anchored true positive → #2 PASS, #3 PASS. Fixture B: "no implementation drift detected" → #2 FAIL, #3 FAIL. Fixture C: "Phase 6 audit FAIL — drift detected on snorgleblorf" → #2 PASS, #3 PASS. | self | S3, S4 | [G] | 1 |

### Step S1 — Rewrite assert-file-exists.js to transcript-grep
- [G] **RED**: A new test in `test-file-exists-replacement.sh` (added later or via inline node -e probe) asserts that calling `m({ output: '[tool_use: Write] input={"file_path":"src/utils/reverseString.ts","content":"…"}', context: { vars: { expected_paths: ['…/reverseString.ts'] } } })` returns `{pass: true}`. The current `fs.existsSync`-based implementation will return `{pass: false}` because `…/reverseString.ts` does not exist on disk in our test setup. The current test's last behavioral block ALSO will fail once we update its expected behavior in S2.
- [G] **IMPL**: Replace assert-file-exists.js body. Remove `require('fs')`. Build the implementation around the `output` parameter: split into lines, look for lines beginning with `[tool_use: Write]` or `[tool_use: Edit]`, then for each expected path check whether ANY such line's tail contains the expected `path.basename`.
- [G] **GREEN**: New behavioral probe + updated test pass.

### Step S2 — Update test-file-exists-replacement.sh
- [G] **RED**: The existing behavioral block at lines 88-101 uses `expected_paths: ['$ASSERT_FILE_EXISTS']` and expects PASS via `fs.existsSync` on the assertion JS file itself. That semantics no longer applies. After my edit, the test calls the new assertion with a synthetic `output` transcript and tests Pass/Fail outcomes. Initial run after editing the JS in S1 (but BEFORE updating the test) shows the existing test FAILS at the behavioral probe.
- [G] **IMPL**: Replace the behavioral block with: synthetic transcript containing `[tool_use: Write] input={"file_path":"a/b/reverseString.ts",…}` and `[tool_use: Edit] input={"file_path":"a/b/foo.ts",…}` → assertion called with `expected_paths: ['…/reverseString.ts']` must PASS; with `expected_paths: ['nonexistent.ts']` must FAIL; with no `expected_paths` must FAIL. Also remove the `fs.existsSync` assertion-script structural check that no longer applies.
- [G] **GREEN**: `bash tests/structure/test-file-exists-replacement.sh` exits 0.

### Step S3 — Tighten assertion #2 regex
- [G] **RED**: Add fixture cases (or update the existing one) in `test-drift-audit-regex.sh` to require that "no implementation drift detected" FAILS assertion #2. Current regex matches this string → test must FAIL on initial run.
- [G] **IMPL**: Replace assertion #2 regex with:
      `/zero file changes|audit[- ]only|(audit (?:found |reported )?no|no audit) (?:implementation|files modified|files changed)|Phase 6 NOT complete|audit FAIL/i`
- [G] **GREEN**: Test passes.

### Step S4 — Extend assertion #3 negative-guard
- [G] **RED**: Add fixture asserting "no implementation drift detected" must trigger negative-guard FAIL (i.e. assertion #3's `pass = false`). Current regex does not match it → test will fail.
- [G] **IMPL**: Extend assertion #3 alternation to also include `no [a-z ]*(implementation|drift) (?:found|detected|reported|present|to.*report)`.
- [G] **GREEN**: Test passes.

### Step S5 — Add 3 fixture cases to drift-regex test
- [G] **RED**: Append 3 fixture blocks to `test-drift-audit-regex.sh`. Initial run after editing the test (but before S3/S4 patches are in place — actually S3/S4 come before, so this just consolidates by the time we get here) PASSES; but we'll write the fixture asserts to require S3+S4 behavior, so initial test addition without those patches would FAIL. Order in execution: S3 → S4 → S5 (per dependency graph).
- [G] **IMPL**: Append the 3 fixture cases in a single block, executing node -e with both regexes (parsed via the existing sed approach OR hardcoded against the spec to avoid regex-extraction brittleness). Use direct hardcoded regex constants for clarity and to decouple from sed extraction.
- [G] **GREEN**: `bash tests/structure/test-drift-audit-regex.sh` exits 0 with the new fixtures.

**Checkpoint**: `bash tests/structure/test-file-exists-replacement.sh && bash tests/structure/test-drift-audit-regex.sh && bash tests/structure/*.sh` all PASS.

## Final Verification
- [G] `tests/structure/test-file-exists-replacement.sh` PASS (19/19)
- [G] `tests/structure/test-drift-audit-regex.sh` PASS (5/5)
- [G] All other `tests/structure/*.sh` still PASS (no regression — 69/69 total)
- [G] `assert-file-exists.js` no longer contains `require('fs')` or `fs.existsSync`
- [G] `precondition-drift-audit.yaml` regex updates exactly match spec
- [G] Background promptfoo run (PID 88129) untouched — never read /tmp/full-suite3.json this session
