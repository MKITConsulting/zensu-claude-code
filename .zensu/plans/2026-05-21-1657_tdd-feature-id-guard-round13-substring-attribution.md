# TDD Plan: feature-id-guard Round-13 — VERBOSE_MATCH Substring Attribution + MCP-Boundary Mitigation Hedge

## Context

Code review on round-12 output flagged two important findings:

**Finding #1 (doc-only)** — `tests/e2e-plm/README.md:239-244` mitigation
paragraph asserts runtime MCP-server enforcement that cannot be verified inside
this repo. Source-of-truth `agents/zensu-plm.md:178` only states Rule 2 as an
agent directive ("Never guess feature IDs. Always use list_features or ask the
user") — no language about MCP server refusing unknown IDs. The MCP server
itself is not in this repo. Round-12's ceiling-acceptance justification rests
on this claim; if false, the smoke harness IS the only practical guard. Fix:
soften the claim with an explicit hedge ("verified out-of-repo, not by this
harness", "treat the smoke pattern as a lower-bound assertion").

**Finding #2 (executable behavior)** — `tests/e2e-plm/run.sh:73`
`VERBOSE_MATCH` diagnostic emits the WHOLE pattern line, not the specific
alternative that matched. For `feature-id-guard.pattern` (single 21-alt union
on one line), the MATCH output is the entire ~830-char union — useless for the
alt-attribution problem the diagnostic was designed to solve. The round-12
plan + commit `d0c59d3` overclaimed "per-alt attribution"; the actual
capability shipped was only "per-pattern-line attribution". Round-13 delivers
true substring-level attribution by switching from `printf` echo of the
pattern `$line` to `grep -Eoi` extraction of the matched substring.

## Round-12 diagnostic-scope correction

The round-12 plan + commit message labeled the VERBOSE_MATCH feature as
"per-alt attribution". With the implementation as-shipped (`printf '... <- %s'
"$line"`), that label was overclaim:

- For multi-line patterns with one alt per line (e.g. `status-transition.pattern`),
  each MATCH line corresponds to a single alt, so attribution is per-alt by accident.
- For single-line union patterns like `feature-id-guard.pattern` (21 alts on
  one line), the MATCH line is the entire union — same string for every match,
  no attribution at all.

Round-13 closes the gap by extracting only the substring that actually
matched via `grep -Eoi -- "$line" "$captured_file" | head -1`. After this
landing, the diagnostic is genuinely per-alt for the union case.

## Approach

Strict Red/Green TDD for Finding #2 (executable behavior). Finding #1 is
doc-only — verified via two `grep -q` checks specified in the constraints.

**Tech Stack**: Bash shell harness | **Coverage**: SKIPPED (no coverage tool
applicable to bash smoke tests).

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Refactoring (doc) | README mitigation hedge (Finding #1) | n/a (grep-q smoke) | – | [RF] | 1 |
| S2 | Feature | VERBOSE_MATCH substring extraction (Finding #2) | tests/e2e-plm/test-runner.sh::test_verbose_match_emits_matched_alt | – | [G] | 1 |
| S3 | Integration | Round-13 plan + log committed | n/a | S1, S2 | [W] | 1 |

### Step S1 — README mitigation hedge (Finding #1)

- [x] **CHANGE**: Replace lines 239-244 of `tests/e2e-plm/README.md` with the
      hedged paragraph specified by the reviewer (explicit "verified
      out-of-repo, not by this harness" language).
- [x] **VERIFY**: `grep -q "verified out-of-repo" tests/e2e-plm/README.md`
      succeeds; `! grep -q "refuses to call get_feature with unknown IDs at
      runtime" tests/e2e-plm/README.md` (old aspirational claim gone).

**Checkpoint**: `bash tests/e2e-plm/test-runner.sh` still 100% pass (no
behavior change), both `grep -q` checks pass.

### Step S2 — VERBOSE_MATCH substring extraction (Finding #2)

- [x] **RED**: Update existing test `test_verbose_match_emits_matched_alt`
      (line 1014) to use a 3-alt pattern `(foo|bar|expected signal)` with
      capture containing `the expected signal here`. Assert MATCH line emits
      `expected signal` (the matched substring), NOT `(foo|bar|expected
      signal)` (the whole pattern line). Current implementation emits whole
      pattern → test fails RED.
- [x] **IMPL**: Replace `run.sh:73` from `printf ... "$line"` to use
      `grep -Eoi -- "$line" "$captured_file" | head -1` to extract just the
      matched substring; fall back to `$line` if extraction yields nothing.
- [x] **GREEN**: target test passes; broader suite remains green.

**Checkpoint**:
- `bash tests/e2e-plm/test-runner.sh` 100% pass (35 tests)
- `bash tests/e2e-plm/run.sh --self-check` exit 0
- `bash tests/e2e-plm/run.sh --offline` 7/7 PASS
- `bash tests/e2e/run.sh --self-check` exit 0 (cross-suite, no regression)
- `VERBOSE_MATCH=1 bash tests/e2e-plm/run.sh --offline 2>&1 | grep feature-id-guard | grep MATCH | grep -v "(" | head -1`
  emits a substring without the union-opening `(`.

### Step S3 — Round-13 plan + log committed

- [x] **WIRE**: Stage and commit this plan + matching log under `.zensu/`.

## Final Verification

- [x] All test suites pass (`tests/e2e-plm/test-runner.sh`, `tests/e2e-plm/run.sh --self-check`, `tests/e2e-plm/run.sh --offline`, `tests/e2e/run.sh --self-check`)
- [x] Finding #1 grep-q checks both succeed
- [x] Finding #2 substring smoke check passes (MATCH line lacks the union-opening `(`)
- [x] Four focused commits land (README hedge, VERBOSE_MATCH substring, plan+log, audit-pass plan/log update)
- [x] Coverage: SKIPPED (no tool applicable to bash smoke harness)
