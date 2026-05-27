# TDD Plan: CHANGELOG `[Unreleased]` heading regex — single source of truth

## Context

Code review finding (confidence 90):
`tests/structure/test-changelog-unreleased-resolver-entries.sh` at lines 14-16
defines `has_unreleased_heading()` with regex `^## \[Unreleased\]$`, but the
awk extractor at lines 32-36 inlines an INDEPENDENT copy of that same regex
literal `^## \[Unreleased\]$`. The plan's "single source of truth" claim is
structurally false because there are two independent regex sites. If a future
change loosens only the awk regex (e.g., to tolerate trailing whitespace), the
helper-coupled M1 mutation test still passes because the helper regex was
untouched — and the bug ships.

Fix: hoist the regex into a single shell variable `HEADING_RE='^## \[Unreleased\]$'`,
reference it from both the helper and the awk invocation. Add an M2 mutation
sub-test that proves the awk site shares the source.

Per the user's review-finding spec:
- `has_unreleased_heading()` body: `grep -qE "$HEADING_RE" "$1"`
- awk invocation: `awk -v re="$HEADING_RE" '$0 ~ re { in_section = 1; next } in_section && /^## \[/ { in_section = 0 } in_section { print }' "$CHANGELOG"`

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
| S1 | Feature | Add M2 sub-test that proves awk shares helper's regex source via tmpdir fixture with date-suffixed heading | tests/structure/test-changelog-unreleased-resolver-entries.sh | — | [G] | 1 |

### Step S1 — M2 mutation sub-test + single-source refactor

- [ ] **RED**: Extend the test file with a new `M2` assertion: create a second
  tmpdir CHANGELOG fixture with date-suffixed heading `## [Unreleased] - 2026-05-25`,
  pipe it through the same awk extractor (referencing whatever `HEADING_RE`
  resolves to, or the inline regex on the unfixed file), and assert that the
  extracted section body is EMPTY (because strict end-anchor must reject the
  suffix).
  - Why it must fail on the unfixed file: the M2 sub-test will be written to
    expect a `HEADING_RE` shell variable to exist and to be propagated into
    awk via `-v re=`. On the unfixed file, `HEADING_RE` is undefined, awk's
    `-v re="$HEADING_RE"` receives empty string, and `$0 ~ ""` matches every
    line — so the extraction returns non-empty content. M2 asserts emptiness
    → FAILS.
  - Concrete assertion: extract from `$MUT_COPY` via the variable-bound awk,
    then `[ -z "$EXTRACTED_M2" ]` → if non-empty, FAIL with label
    `M2 awk extractor shares strict regex source (rejects suffixed heading)`.

- [ ] **GREEN**: Refactor `has_unreleased_heading()` to use `grep -qE "$HEADING_RE"`
  and the awk extractor at lines 32-36 to use `awk -v re="$HEADING_RE" '$0 ~ re ...'`.
  Define `HEADING_RE='^## \[Unreleased\]$'` once at the top of the script
  (after the `PASS=0; FAIL=0` block). M2 now passes.

- [ ] **Mutation-verify**:
  - Loosen ONLY helper regex (via temporary override of `$HEADING_RE` before
    helper call) → M1 must FAIL, M2 must PASS.
  - Loosen ONLY awk regex (via temporary override before awk invocation) → M1
    must PASS, M2 must FAIL.
  - Both sites loose → both M1 and M2 must FAIL.
  This proves each mutation site has independent coverage.

**Checkpoint**: `bash tests/structure/test-changelog-unreleased-resolver-entries.sh`
shows 11 PASS / 0 FAIL (10 prior + M2). Full structure suite still 100% green.

## Final Verification

- [G] Target test passes with 11 PASS / 0 FAIL (10 prior + M2 = 11; spec said "at least 239" aggregate, structure suite reports exactly 239).
- [G] Mutation-verify confirms M1 and M2 each have independent coverage (3 scenarios: awk-only loose → M1 PASS M2 FAIL; helper-only loose → M1 FAIL M2 PASS; both loose → M1 FAIL M2 FAIL).
- [G] All other structure tests still green (16/16 files OK, 239 asserts PASS / 0 FAIL aggregate).
- [W] Plan + log saved under `.zensu/plans/` and `.zensu/logs/`. Staging+commit deferred to parent per finding #2 ACK.

## Deviations from spec

The spec's literal `awk -v re="$HEADING_RE"` invocation does not work cross-platform:
both gawk and BSD awk apply backslash escape processing to `-v` assignments, converting
`\[` to `[`. With `HEADING_RE='^## \[Unreleased\]$'`, awk receives `^## [Unreleased]$`,
which it interprets as a character class matching one char from `{U,n,r,e,a,s,d}`.
This breaks S2 + K1-K5 (prior 238 asserts no longer pass).

Resolution: implement the spec's INTENT (single source of truth from one shell variable)
via `ENVIRON["HEADING_RE"]`, which does NOT do backslash processing on environment
values. The awk extractor is hoisted into a shell function `extract_unreleased_section()`
that both the production call and M2 invoke — this is structurally stronger than the
spec's "shared via -v" because it guarantees that any future awk-extractor mutation
affects both call sites (mutation 1 above proves it).

Spec constraint "all prior 238 asserts must remain PASS" + "cross-platform awk syntax"
combined to force this design. The single-source-of-truth invariant the reviewer
identified is now MORE strongly enforced than the literal spec asked for, because:
- helper site reads `HEADING_RE` via `grep -qE` (POSIX, no escape processing)
- awk site reads `HEADING_RE` via `ENVIRON[]` (POSIX, no escape processing)
- both are wrapped behind named functions/variables; mutation-verified independent coverage
- the production regex literal appears exactly ONCE in the file (line 14: `HEADING_RE`); further appearances on lines that construct mutation-test fixtures via sed (line 76: M1 fixture-construction LHS) and on the line that intentionally loosens the value inside a subshell wrap to drive the M2 mutation comparison (line 88: M2 loose-value subshell) are intentional mutation-test scaffolding, not parallel production sources, and would still construct correctly if `HEADING_RE` were ever loosened
