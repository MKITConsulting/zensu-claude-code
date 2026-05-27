# TDD Plan: CHANGELOG `[Unreleased]` entries for round-3 resolve-session-id work

## Context

Round-3 changes (new `hooks/lib/resolve-session-id.js` helper, allowlist regex
`/[^A-Za-z0-9_-]/g` in `sanitizeProjectDir`, length guard `s.length < 18` in
`parseCutoffMs`, Layer-1 + Layer-2 race-hardening doctrine) are not entered
under `[Unreleased]` in `CHANGELOG.md`, while the prior session-id resolver
work (0.3.20, 0.3.21) was extensively documented. Future maintainers reading
CHANGELOG will see the 3-tier story end at 0.3.21 with no mention of the
helper or new design. This is a docs-only fix.

**Approach**: Strict Red/Green TDD (soft form for docs) | **Tech Stack**:
bash structure tests + node helpers | **Coverage**: SKIPPED (no test coverage
tool wired for bash structure tests)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | n/a |
| node | CLI | `command -v node` | present | n/a |
| grep | CLI | `command -v grep` | present | n/a |
| awk  | CLI | `command -v awk`  | present | n/a |
| `CHANGELOG.md` `[Unreleased]` heading | fixture | `grep -q '## \[Unreleased\]' CHANGELOG.md` | present | n/a |

No external CLIs, secrets, endpoints, or fixtures missing.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | New structure test `test-changelog-unreleased-resolver-entries.sh` that asserts `[Unreleased]` section in `CHANGELOG.md` contains the round-3 keywords (`resolve-session-id.js`, `Layer-1`, `Layer-2`, `parseCutoffMs`, `sanitizeProjectDir`) | `tests/structure/test-changelog-unreleased-resolver-entries.sh` | – | [G] | 1 |
| S2 | Feature | Add `### Added` + `### Fixed` entries under `[Unreleased]` in `CHANGELOG.md` describing the new helper, allowlist regex hardening, length-guard, and Layer-1/Layer-2 doctrine | `tests/structure/test-changelog-unreleased-resolver-entries.sh` (re-run after edit) | S1 | [G] | 1 |
| S3 | Feature | Mutation verification: temporarily remove one of the required keywords from the new CHANGELOG block and confirm the structure test FAILS, then restore | `tests/structure/test-changelog-unreleased-resolver-entries.sh` (mutation cycle) | S2 | [RF] | 1 |

### Step S1 — RED: structure test that asserts CHANGELOG `[Unreleased]` contains the round-3 keywords

- [x] **RED**: New file `tests/structure/test-changelog-unreleased-resolver-entries.sh`. Asserts (a) `## [Unreleased]` heading exists, (b) within that section (until the next `## [`) the substrings `resolve-session-id.js`, `Layer-1`, `Layer-2`, `parseCutoffMs`, `sanitizeProjectDir` each appear at least once. Failed before the CHANGELOG edit (6 FAIL / 2 PASS — section empty + 5 keywords absent).
- [x] **GREEN**: Test exists, fails for the right reason (assertion-mismatch on 6 asserts).

### Step S2 — IMPL: add `### Added` + `### Fixed` entries under `[Unreleased]` in CHANGELOG.md

- [x] **GREEN**: Test from S1 passes after the CHANGELOG edit (8 PASS / 0 FAIL, 1 attempt).

Entries to add (under `## [Unreleased]`):

- `### Added` — new `hooks/lib/resolve-session-id.js` Node helper paragraph
  (includes Layer-1 BASH_START + Layer-2 ZENSU_OWN_CMD doctrine inline as a
  "Note:" so the design lives in the long-lived discoverable CHANGELOG and
  not only in the dated plan file).
- `### Fixed` — PPID-derived cache key fragmentation paragraph.
- `### Fixed` — `sanitizeProjectDir` allowlist `/[^A-Za-z0-9_-]/g` paragraph.
- `### Fixed` — `parseCutoffMs` `s.length < 18` length-guard paragraph.

### Step S3 — Mutation verification

- [x] **GREEN-BEFORE**: Test passes against the post-S2 CHANGELOG (8 PASS).
- [x] **MUTATE**: Replaced `parseCutoffMs` -> `__MUTATED__` globally in CHANGELOG.
- [x] **GREEN-AFTER (expected FAIL)**: Re-ran the test, observed `FAIL  K parseCutoffMs keyword present in [Unreleased] section` (1 FAIL / 7 PASS, exit 1). Test catches the regression.
- [x] **RESTORE**: `__MUTATED__` -> `parseCutoffMs`. `diff -q` against the pre-mutation backup confirms the file is byte-identical. Test reports 8 PASS / 0 FAIL.

**Checkpoint**: `bash tests/structure/test-changelog-unreleased-resolver-entries.sh` exits 0 with all asserts PASS.

## Final Verification

- [x] All structure-test suites still pass — 16/16 suites GREEN, 236 PASS / 0 FAIL.
- [x] CHANGELOG `[Unreleased]` section contains the Added + Fixed entries described above.
- [x] New CHANGELOG-shape regression test passes; mutation-verified to fail when `parseCutoffMs` is removed.
- [x] `.zensu/plans/2026-05-25-1604_tdd-changelog-unreleased-resolver-entries.md` and `.zensu/logs/2026-05-25-1604_tdd-changelog-unreleased-resolver-entries.log` ready for commit.
- [x] No version bump in `.claude-plugin/plugin.json` or `.claude-plugin/marketplace.json` (none performed).
