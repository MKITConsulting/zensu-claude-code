# TDD Plan: tdd-manager compliance hardening + E2E coverage

## Context

Two related changes from the approved plan `schau-mal-hier-bitte-groovy-coral.md`:

### Change A — Tighten `agents/tdd-manager.md`
1. Bulk-merge clause (line 52): merging steps may NOT be used as a logging shortcut. Each merged step still requires its own RED/GREEN log entries.
2. New "Per-Step Logging Contract" under Principle 3: every Feature/Bug-Fix step must contain `{step_id} RED `, `{step_id} IMPL completed — files: `, and `{step_id} GREEN — PASS ` entries. Integration `[W]` steps log one `{step_id} WIRED — ` entry.
3. New Phase 6 Step 5 "mtime Discipline Audit": compare test file mtimes to impl mtimes. If test was written after impl → `[!]`. If >20% of feature steps violated → final log line "TDD DISCIPLINE VIOLATED ..."
4. Renumber Phase 6 steps 5→6, 6→7, 7→8, 8→9.

### Change B — E2E coverage
1. New `evals/tdd-review-chain/assert-tdd-log-compliance.sh` script with `--log` + optional `--impl-dir`.
2. Four fixture log files (good / missing-red / bulk-shortcut / test-after) + a fixture tree with seeded mtimes.
3. Extend `run-eval.sh` with offline T5 section + slow-lane T9.
4. New `test-tdd-compliance.exp` for T9 (slow lane).

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash shell scripts + markdown agent definition | **Coverage**: SKIPPED — no test runner for bash scripts in this repo; verification is via `evals/tdd-review-chain/run-eval.sh --self-check`

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Create good-fixture log + write compliance script that accepts it (basic RED→IMPL→GREEN per-step parser) | fixtures/tdd-log-good.log + run-eval T5.1 | — | [G] | 1 |
| S2 | Feature | Reject missing-RED fixture (GREEN without prior RED for same step_id) | fixtures/tdd-log-missing-red.log + run-eval T5.2 | S1 | [G] | 1 |
| S3 | Feature | Reject bulk-shortcut fixture (one collective RED for N steps, then per-step GREEN) | fixtures/tdd-log-bulk-shortcut.log + run-eval T5.3 | S1 | [G] | 1 |
| S4 | Feature | Reject test-after fixture via mtime check when --impl-dir given | fixtures/tdd-log-test-after.log + fixtures/test-after-tree/ + run-eval T5.4 | S1 | [G] | 1 |
| S5 | Feature | Agent edit 1 — tighten merge clause (line 52) | T5.1 fixture stays GREEN; manual grep check | — | [G] | 1 |
| S6 | Feature | Agent edit 2 — add "Per-Step Logging Contract" block under Principle 3 | T5.1 stays GREEN; grep "Per-Step Logging Contract" | — | [G] | 1 |
| S7 | Feature | Agent edit 3 — insert Phase 6 Step 5 "mtime Discipline Audit" + renumber 5→6...8→9 | grep "mtime Discipline Audit" + numbering check | — | [G] | 1 |
| S8 | Integration ([W]) | Create test-tdd-compliance.exp + T9 wiring in run-eval.sh (slow-lane, NOT in --self-check) | run-eval.sh --self-check still passes T5 | S1..S4 | [W] | 1 |

**Checkpoint**: `./evals/tdd-review-chain/run-eval.sh --self-check` shows all PASS including new T5.1–T5.4 and existing structural checks remain PASS.

## Final Verification
- [x] All T5.1–T5.4 PASS in `--self-check`
- [x] All pre-existing structural checks PASS (hooks.json, assert-config, assert-agent, assert-changelog, assert-severity-routing, T3.x, T6/T7/T8); NOTE: `assert-version.sh` FAILS because plugin.json is 0.3.14 (manifest bumped in upstream commits 1251c41 + later) while assert-version.sh still pins `0.3.11` — pre-existing, out of scope, additive change does not regress this.
- [x] `bash -n` clean on all new/modified `.sh` scripts
- [x] `chmod +x` set on new `.sh` and `.exp` files
- [x] Agent edits grep-verified
- [x] Phase 6 has 9 numbered steps
- [ ] Two clean conventional commits, no co-author/watermark (pending)
- [ ] `.zensu/plans/` + `.zensu/logs/` of this run committed in the second commit (pending)
