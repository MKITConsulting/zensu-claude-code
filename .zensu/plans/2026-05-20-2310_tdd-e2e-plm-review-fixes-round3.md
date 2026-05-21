# TDD Plan: E2E-PLM Code-Review Fixes (Round 3)

## Context

Three round-3 review findings on the e2e-plm harness:

1. **F1 — `tests/e2e-plm/expected/status-transition.pattern:9` probe 3 causes false positives.**
   Probe 3 (`!status[^)]*update_feature`) flags benign reversed-order Rule-3 disclaimers (e.g. `The status transition is not supported by update_feature. You should use the REST API endpoint instead.`) and adds zero discrimination beyond probes 1+2.
   Reproduced FP cases (verified by reviewer with `--offline`):
   - `The status transition is not supported by update_feature. You should use the REST API endpoint instead.` → FAILs (should pass).
   - `Status changes can't be made via update_feature. Use the Zensu REST API endpoint.` → FAILs (should pass).
   Adversarial fixtures from round-2 are already caught by probes 1+2: FN#1 multi-line `I will call update_feature with:` is caught by probe 2 (`!update_feature\s+with`); FN#2 reversed-order `update_feature(id=ZEN-001)` is caught by probe 1 (`!update_feature\s*\(`).
   Fix: **Option A** — remove probe 3 entirely; add a new test asserting both FP fixtures PASS the shipped pattern.

2. **F2 — `tests/e2e-plm/run.sh:56-61` empty-needle guard misses whitespace-only case.**
   After `needle="${line#!}"`, a pattern line like `! ` (bang + space) leaves `needle=" "`, fails `[ -z "$needle" ]`, and falls through to `grep -Eqi -- " "` which matches any non-empty captured line → silent FAIL with no WARN. The round-2 fix only handled bare `!`.
   Fix: POSIX-strip leading/trailing whitespace from `$needle` before the empty check, then extend `test_empty_negative_assert_warns_not_fails` to cover `! ` (bang+space) and `!  ` (bang+multi-space).

3. **F3 — `.gitignore:43` blocks `.zensu/plans/` and `.zensu/logs/` from being committed.**
   The user's global CLAUDE.md requires `.zensu/plans/` and `.zensu/logs/` to be staged AND committed. Round-1/round-2 deliverables are currently ignored; historic round-0 plans were tracked. Fix: carve out explicit `.gitignore` exceptions:
   ```
   !.zensu/plans/
   !.zensu/logs/
   ```
   Verify with `git check-ignore -v`. Do NOT run `git add` / `git commit` — only adjust `.gitignore` and append this round's plan + log to the TDD log. Document under "Followups".

**Approach**: Strict Red/Green TDD. Each fix starts with a failing test in `tests/e2e-plm/test-runner.sh` (where applicable — finding #3 is a `.gitignore` change verified via `git check-ignore -v` before/after).

**Tech Stack**: bash 3+, git 2.28+. No linter / type-checker. **Coverage**: SKIPPED (no bash coverage tool; existing TDD plans skip too).

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| F1S1 | Feature | status-transition.pattern accepts reversed-order benign disclaimer (FP) | tests/e2e-plm/test-runner.sh | — | [G] | 1 |
| F2S1 | Feature | match_pattern WARN on whitespace-only negative-assert needle | tests/e2e-plm/test-runner.sh | — | [G] | 1 |
| F3S1 | Integration | `.gitignore` carve-out for `.zensu/plans/` and `.zensu/logs/` | .gitignore | — | [W] | 1 |

### Step F1S1 — status-transition.pattern accepts reversed-order benign disclaimer

- [x] **RED**: Added `test_status_transition_pattern_accepts_reversed_order_disclaimer` to `test-runner.sh`. Capture fixtures (both must PASS the pattern):
  - `The status transition is not supported by update_feature. You should use the REST API endpoint instead.`
  - `Status changes can't be made via update_feature. Use the Zensu REST API endpoint.`
  With probe 3 still present, both FAILed the pattern (probe 3 matched `status...update_feature`) → assertion `PASS  status-transition` failed for both → test FAILed as expected. RED verified.
- [x] **GREEN**: Removed probe 3 from `expected/status-transition.pattern` (deleted line 9: `!status[^)]*update_feature`). Updated README.md `status-transition` row to reflect 2 probes (was "three same-line tool-call-shape negative asserts"). Updated "Known caveats" entry on cross-line asserts to match. Existing FN#1 (multi-line `update_feature with:`) still caught by probe 2 (`!update_feature\s+with`); FN#2 (reversed order `update_feature(id=...)`) still caught by probe 1 (`!update_feature\s*\(`); forward-order benign disclaimer still PASSes. 21/21 PASS.

**Checkpoint after F1S1**: `bash tests/e2e-plm/test-runner.sh` — F1S1 test PASSes, existing FN#1/FN#2/benign-disclaimer tests still GREEN.

### Step F2S1 — match_pattern WARN on whitespace-only needle

- [x] **RED**: Added sibling `test_whitespace_only_negative_assert_warns_not_fails` — pattern file contains `! ` and `!  ` lines plus positive line; captured file has matching positive. Assertion: PASS warntest AND at least 2 WARN diagnostics. With current code (whitespace-only falls through to `grep -E " "` → matches captured non-empty content → FAILs test), test FAILed (`warn_count=0`) → RED.
- [x] **GREEN**: Edited `run.sh:56-63` — after `needle="${line#!}"`, added POSIX leading+trailing whitespace strip:
  ```bash
  needle="${needle#"${needle%%[![:space:]]*}"}"
  needle="${needle%"${needle##*[![:space:]]}"}"
  ```
  Then `[ -z "$needle" ]` catches both bare-`!` AND whitespace-only forms. 21/21 PASS.

**Checkpoint after F2S1**: F2S1 test PASS, full `test-runner.sh` still 100%.

### Step F3S1 — `.gitignore` carve-out

- [x] **RED-via-precondition-check**: `git check-ignore -v` reported both `.zensu/plans/<round3>.md` AND `.zensu/logs/<round3>.log` matched by `.gitignore:43:.zensu/` (exit 0 = ignored).
- [x] **WIRED**: Edited `.gitignore` — changed bare `.zensu/` (line 43) to:
  ```
  .zensu/*
  !.zensu/plans/
  !.zensu/logs/
  !.zensu/logs/*.log
  ```
  The `.zensu/*` (not `.zensu/`) form keeps the parent dir visitable so the `!` negations can override. The extra `!.zensu/logs/*.log` line is required to override the global `*.log` rule on line 21 of the same file (otherwise log files inside the un-ignored `logs/` dir would still be excluded). Comment added explaining the CLAUDE.md constraint that drives the carve-out.
- [x] **GREEN-via-precondition-check**: `git ls-files --others --exclude-standard .zensu` now lists ALL six plans/*.md and logs/*.log (round1, round2, round3) as untracked-and-eligible. `git check-ignore -v -n` shows `::` (no-match) for plans/*.md and `!.zensu/logs/*.log` (negation-wins) for logs/*.log — both are trackable. Hypothetical `.zensu/cache/foo.txt` still matched by `.zensu/*` rule → still ignored.

**Checkpoint after F3S1**: Full `test-runner.sh` still 100%, both self-checks still exit 0, `git check-ignore -v` reports plan + log NOT IGNORED.

## Final Verification

- [x] `bash tests/e2e-plm/test-runner.sh` — 21/21 PASS / 0 FAIL (15 existing pre-round-2 + 4 round-2 + 2 new in round-3)
- [x] `bash tests/e2e-plm/run.sh --self-check` exit 0
- [x] `bash tests/e2e/run.sh --self-check` exit 0 (cross-suite no regression)
- [x] `.zensu/plans/<this-round>.md` reported NOT IGNORED by `git ls-files --others --exclude-standard`
- [x] No edits to `agents/zensu-plm.md` (isolation)
- [x] No edits to `tests/e2e/` (isolation)

## Followups

- **`.gitignore` carve-out** (F3S1): `!.zensu/plans/` and `!.zensu/logs/` are now explicit exceptions in `.gitignore`. Future rounds no longer need `git add -f` to commit plans + logs. The constraint from `~/.claude/CLAUDE.md` ("Always stage AND commit `.zensu/plans/` AND `.zensu/logs/` for the current task") is now honored by the ignore rules. Round-1 and round-2 deliverables are still untracked; the commit step is the user's call per the round-3 spec.

## Final Result

21/21 PASS (15 prior + 4 round-2 + 2 round-3 new). 3/3 GREEN (F1S1, F2S1 features + F3S1 integration). Build: – n/a (bash scripts only, no build manifest). Coverage: SKIPPED (no bash coverage tool). Cross-suite `--self-check` exit 0 for both `tests/e2e-plm/run.sh` and `tests/e2e/run.sh`. No edits to `agents/zensu-plm.md` or `tests/e2e/`.
