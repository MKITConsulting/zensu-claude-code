# TDD Plan: One owner for each unit file's registered-case count

## Context
Test-infrastructure change in zensu-claude-code (English only, no code comments). A unit file's §4 "Blocks" cell in tests/SUITE-OVERVIEW.md and its driver's registered-case floor store one number twice. PR #382 raised the floor in tests/structure/test-workflow-dispatch-inputs.sh from 19 to 24 but left the cell at 19. The driver passed locally three times; CI then failed R13 in tests/structure/test-restore-project-root.sh with `FAIL R13 the suite overview count drift: workflow-dispatch-inputs.test.js(declared=19 registered=24)`, a line that names neither the overview nor the row. tests/SUITE-OVERVIEW.md claims only seven rows are graded, and says nothing machine-checks its numbers.

Requirements as stated: (1) tests/structure/lib-unit-summary.sh gains `unit_overview_declared <unit-basename>`, which reads that file's §4 row with the row regex R13 uses, and `unit_overview_check <unit-path>`, which compares that number with `grep -c '^test('` on the file and on mismatch prints `tests/SUITE-OVERVIEW.md:<line>: <file> declares N, registers M; edit that Blocks cell`. (2) Every driver that sources lib-unit-summary.sh and drives a unit file with a §4 row calls `unit_overview_check` next to its floor and takes the floor from `unit_overview_declared` instead of a literal, starting with test-workflow-dispatch-inputs.sh and test-full-suite-ci.sh. (3) R13 calls the same helper, so a CI failure names the file and the line. (4) tests/SUITE-OVERVIEW.md states that R13 grades every row's numeral and R13b the rowless-file numerals (keeping the numerals R13b parses), gains one sentence under the §4 heading naming R13 and the helper, and scopes the "Nothing machine-checks any of this" statement to the §1/§3 reconciliation. Run only the affected suites locally (never tests/run-all.sh), then open a PR.

Measured at the base commit 307329b5: every one of the 27 rows these drivers grade declares exactly what `grep -c '^test('` counts in its file. Five literal floors sit below their cells (owned-process 2 of 4, evidence-run 40 of 80, the doctor recognizer 26 of 27, the adoption report 56 of 59, automatic adoption 40 of 44), and the windows-ci-contract metadata and all floors (42, 65) sit one below the sums of their files' cells (43, 66).

**Approach**: Vanilla implementation (strict TDD discipline not in effect for this chain) | **Tech Stack**: bash structure suites driving `node --test` unit files | **Coverage**: SKIPPED (no coverage tool covers bash suites) @ n/a (default-90%)

### Scope decisions
| Driver | Unit files with a §4 row | Decision |
|--------|--------------------------|----------|
| `test-workflow-dispatch-inputs.sh` | workflow-dispatch-inputs | derived registered floor + overview check |
| `test-full-suite-ci.sh` | full-suite-ci-v1 | derived passing floor (C1a stays a meet floor: the file skips nothing) + overview check |
| `test-acceptance-gate.sh` | acceptance-verify-v1 | derived passing floor (A0c, no skips) + overview check |
| `test-evidence-run.sh` | evidence-run-v1 | derived floor graded as a REGISTERED total: three cases skip on win32, so a passing floor of 80 would fail there |
| `test-bash-source-write-gate.sh` | git-repo-escape | W3a total and pass floors both take the derived value, as they were both 45 |
| `test-stop-enforcer-self-review-routing.sh` | reviewer-spawn-denial-v1 | T26 total takes the derived value; the pass floor keeps its measured two-case allowance below it |
| `test-chain-recover.sh`, `test-finding-verification.sh`, `test-plan-payload-fallback.sh`, `test-promptfoo-verify-feature.sh`, `test-zensu-runtime-controller.sh` | one file each | derived registered floor + overview check |
| `test-claude-promptfoo-wrapper.sh` | owned-process, fixture-mutation-watch, claude-stream-render | derived floors at all four floor sites + one overview check per file |
| `test-versioned-plugin-upgrade.sh` | five files | derived floors + one overview check per file |
| `test-verify-consent.sh` | five files through `run_unit` | the floor argument and the row key go; `-overview` calls the helper instead of its own sed parse |
| `test-review-convergence.sh` | review-ledger-v1 | R1a floor derived; R1b calls the helper instead of its own sed parse |
| `test-windows-ci-contract.sh` | six files across three modes | each arm keeps its files inline (the windows-ci-contract.test.js pin) and binds them with `set --`; the floor is the sum of their cells; a drifted cell prints the helper's line on stderr and exits 1 |
| `test-restore-project-root.sh` | restore-root-render-cases (R0) | sources the library for R13, so R0 joins the rule too |
| `test-incremental-review-rounds.sh`, `test-session-control-core.sh` | none with a row | unchanged |
| `test-zen-mode.sh` Z78 | two zen rows | out of scope: it does not source the library |

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | `unit_overview_declared <unit-basename>` prints the Blocks numeral of that file's §4 row, read with the row regex R13 uses, and exits non-zero with no output when the file has no row | spec |
| AC-002 | `unit_overview_check <unit-path>` exits 0 silently when the row's numeral equals `grep -c '^test('` on the file; otherwise it prints exactly `tests/SUITE-OVERVIEW.md:<line>: <file> declares N, registers M; edit that Blocks cell` and exits non-zero | spec |
| AC-003 | Every driver that sources lib-unit-summary.sh and drives a unit file with a §4 row takes that file's floor from `unit_overview_declared`, keeps no literal registered-count floor, and calls `unit_overview_check` next to the floor | spec |
| AC-004 | R13 grades every §4 row whose file sits in tests/structure/ through `unit_overview_check`, and its FAIL line for a drifted row names tests/SUITE-OVERVIEW.md, the row's line number and the file | spec |
| AC-005 | tests/SUITE-OVERVIEW.md says R13 grades every row's numeral and R13b the rowless-file numerals, keeps the numerals R13b parses, carries one sentence under the §4 heading naming R13 and the helper, and scopes "Nothing machine-checks" to the §1/§3 reconciliation | spec |
| AC-006 | With a Blocks cell one below its file's registrations (the PR #382 shape), the file's own driver fails and its FAIL line names the overview line | derived |
| FR-001 | R13c still grades that the row regex R13 uses, now in the library, and the R13b row count share one character class | derived |
| FR-002 | A floor that is not a number, the shape of a missing row, fails the floor helpers closed without a shell error | derived |
| FR-003 | A derived floor that would exceed a host's passing count because of platform skips is graded as a registered total | derived |
| FR-004 | The test-windows-ci-contract.sh mode floors are the sums of the cells of the files each mode runs, with the files still spelled inside each case arm | derived |
| FR-005 | The coupling is recorded where R13 is documented: `.claude/rules/restore-vanished-project-root.md`, plus the stale "nothing compares them" claim in `.claude/rules/zen-mode-chain-anchor.md` | derived |

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | n/a (present) |
| node | CLI | `command -v node` | present | n/a (present) |
| git | CLI | `command -v git` | present | n/a (present) |
| gh | CLI | `command -v gh` | present | n/a (present) |
| npm devDependencies | fixture | `[ -d node_modules ]` | present | n/a (present) |
| acceptance driver (cli: the structure suites run under bash) | CLI | `command -v bash` | present | n/a (present) |

## Cross-Layer Value Flow Pairings
(Per Principle 2 — Cross-Layer Value Flow Pairing. Omit table body if no pairings; keep the heading so Phase 6 audit can detect absence vs zero rows.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |
|------|------|-------------|-----------|------------|--------|----------|--------|
| S1 | Feature | Library: row reader, `unit_overview_declared`, `unit_overview_check`, numeric floor guard | tests/structure/lib-unit-summary.sh | - | [I] | 1 | AC-001, AC-002, FR-002 |
| S2 | Feature | The two named drivers | tests/structure/test-workflow-dispatch-inputs.sh, tests/structure/test-full-suite-ci.sh | S1 | [I] | 1 | AC-003, AC-006 |
| S3 | Feature | The remaining single-mode drivers | tests/structure/test-*.sh (13 files) | S1 | [I] | 1 | AC-003, FR-003 |
| S4 | Feature | Windows contract dispatcher floors | tests/structure/test-windows-ci-contract.sh | S1 | [I] | 1 | AC-003, FR-004 |
| S5 | Feature | R0 and R13 through the helper, R13 controls, R13c over the library | tests/structure/test-restore-project-root.sh | S1 | [I] | 1 | AC-003, AC-004, FR-001 |
| S6 | Integration | Overview prose | tests/SUITE-OVERVIEW.md | S5 | [W] | 1 | AC-005 |
| S7 | Integration | Rule notes | .claude/rules/restore-vanished-project-root.md, .claude/rules/zen-mode-chain-anchor.md | S5 | [W] | 1 | FR-005 |

### Step S1 — Library helpers
- **Covers**: AC-001, AC-002, FR-002
- **Change**: the overview path is resolved once at source time from the library's own location; one row reader lists `line name count` for every row matching `^\| \`[a-z0-9._-]+\.test\.js\` \| [0-9]+ \|`; `unit_overview_declared` and `unit_overview_check` select from it; `unit_cases_meet_floor` and `unit_cases_registered_floor` return 2 for a floor that is not a number.

### Step S2 — Named drivers
- **Covers**: AC-003, AC-006
- **Change**: floor from `unit_overview_declared`, overview check beside it; proven against a copy of the tree whose workflow-dispatch-inputs cell reads 19.

### Step S3 — Remaining single-mode drivers
- **Covers**: AC-003, FR-003
- **Change**: per the scope table above.

### Step S4 — Windows contract dispatcher
- **Covers**: AC-003, FR-004
- **Change**: per the scope table above.

### Step S5 — R0 and R13
- **Covers**: AC-003, AC-004, FR-001
- **Change**: R0 floor from the cell plus its overview check; R13 enumerates rows through the library and prints one FAIL per drifted row with the helper's line; controls drive the helper's drift and no-row arms against synthetic files; R13c greps the library as well and requires it to carry the class.

### Step S6 — Overview prose
- **Covers**: AC-005

### Step S7 — Rule notes
- **Covers**: FR-005

**Checkpoint**: every edited driver plus every suite that sources the library or reads the overview (test-incremental-review-rounds.sh, test-session-control-core.sh, test-zen-mode.sh, test-autopilot-adopt-cli.sh, test-bash32-portability.sh), run from a detached worktree under /private/tmp; `bash -n` over every edited shell file

## Final Verification
- All affected suites pass; the full suite is deferred to the CI pull-request pipeline (session marker `ci`), so the evidence runner records the affected suites with `--scope scoped`
- Coverage: SKIPPED (no coverage tool covers bash suites)
- Every active `AC-###` criterion verified live on the final tree (`/zensu:verify-feature --chain`, one `--acceptance-record` per criterion); a dropped criterion keeps its row, marked `(deprecated) <text>`
