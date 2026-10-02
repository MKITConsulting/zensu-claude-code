# TDD Plan: Zensu skills anchor their artifacts on the bound project root

## Context
Commit ccf55b9c added `/zensu:adopt-session --reanchor` (`hooks/lib/session-reanchor-v1.js`,
`hooks/lib/zensu-session-reanchor.sh`), which moves a session's Session Control `project_root` to
a sibling worktree of the same repository. It shipped with a known gap: `hooks/lib/zensu-log.sh`
binds the NEW root for its own verbs (it exports `CLAUDE_PROJECT_DIR` from the bound record), but
the skills build artifact paths from `"${CLAUDE_PROJECT_DIR:-.}"`. That variable is unset in the
Claude Code Bash tool, and the host returns the Bash tool to the session's start directory (the
OLD root), so `/zensu:tdd`'s `{log_file}`, `{plan_file}`, `BASELINE_SHA` and the edit-landing
audit's `--project` resolve against the old root while `--tdd-complete` looks for the plan, the
run log and the edit-landing receipt under the record root (read in `--tdd-complete`: the receipt
comes from `tdd_edit_landing_receipt`, the run log from `_tc_root/.zensu/logs/<stem>.log`, and
the explicit `--plan` must resolve inside `_tc_root/.zensu/plans/`).

Task: add a read-only `zensu-log.sh` verb that prints the bound project root; make `/zensu:tdd`
and every other skill that anchors a Zensu artifact on `${CLAUDE_PROJECT_DIR:-.}` derive those
paths from it; add an end-to-end case to `tests/structure/test-session-reanchor.sh` that, after a
`--reanchor --confirm`, runs `--tdd-begin`, the skill-rendered edit-landing audit and
`--tdd-complete --plan` in the new anchor from the start directory; remove the known-gap wording
from `.claude/rules/session-reanchor.md`, `docs/session-control.md`,
`skills/adopt-session/SKILL.md` and the report and outcome texts of `session-reanchor-v1.js`;
classify the version per `.claude/rules/runtime-lineage.md`.

Base: `origin/main` (704df189) merged with `claude/inspiring-clarke-be6d3e` (ccf55b9c), merge
commit 6aa2825e. The two merge conflicts were line-number citations in
`docs/multi-repo-chains-spec.md` and `docs/multi-repo-chains-overview.html`, re-pointed by
content against the merged files.

**Approach**: Vanilla implementation (strict TDD discipline not in effect for this chain) | **Tech Stack**: bash 3.2-portable shell, Node.js built-ins, Markdown skills | **Coverage**: SKIPPED — the change is shell, Markdown and render strings; `c8` is wired only for `skills/session-trail` and cannot instrument bash

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | `zensu-log.sh --project-root` prints the project root the session's Session Control record is bound to (the value the helper exports as `CLAUDE_PROJECT_DIR` for its verbs) and exits 0; it writes nothing, refuses any extra argument with exit 2, and prints nothing on stdout when the binding is unavailable | spec |
| AC-002 | After `/zensu:adopt-session --reanchor --confirm`, with the Bash working directory still the previous root and `CLAUDE_PROJECT_DIR` unset, the skill-rendered `/zensu:tdd` commands — the Phase 0 baseline, the Phase 2 log recipe, `--tdd-begin`, the Phase 6 step 5b edit-landing audit and `--tdd-complete --plan {plan_file}` — all land in the new anchor, and `--tdd-complete` accepts the chain; pinned end to end in `tests/structure/test-session-reanchor.sh` | spec |
| AC-003 | `/zensu:tdd` defines `{project_root}` from `zensu-log.sh --project-root` and derives `{log_file}`, `{plan_file}`, `BASELINE_SHA`, the edit-landing `--project`, the step 10.1 plan bound and the review steps' `TOP` from it; no path is built from `${CLAUDE_PROJECT_DIR:-.}` | spec |
| AC-004 | Every other skill that anchored a Zensu artifact on `${CLAUDE_PROJECT_DIR:-.}` (`converge`, `implement`, `self-review`) derives it from `zensu-log.sh --project-root`; no `skills/*/SKILL.md` contains that spelling, and a structure test pins its absence | spec |
| AC-005 | The known-gap wording that sends a new chain to a fresh session is removed from `.claude/rules/session-reanchor.md`, `docs/session-control.md`, `skills/adopt-session/SKILL.md` and the report and outcome texts of `hooks/lib/session-reanchor-v1.js`; the texts say that Zensu skills follow the bound root while other commands still start in the session's start directory, and the remaining bounded gap is named | spec |
| AC-006 | The `--tdd-complete` refusal remedies name the bound project root instead of `${CLAUDE_PROJECT_DIR:-.}`, `docs/tdd-manager-workflow.md` describes the new anchor, and every test that pinned the old spelling pins the new one and passes | derived |
| FR-001 | Version class is `patch` per `.claude/rules/runtime-lineage.md`: a new read-only CLI verb and text changes, with no record or workflow schema field, strict key set, hook, matcher or attestation change | spec |
| FR-002 | Line-number citations of `hooks/lib/zensu-log.sh` in `docs/multi-repo-chains-spec.md` and `docs/multi-repo-chains-overview.html` are re-pointed by content after the verb shifts the file | derived |

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present | none needed (present) |
| git | CLI | `command -v git` | present | none needed (present) |
| bash | CLI | `command -v bash` | present | none needed (present) |

## Cross-Layer Value Flow Pairings
(Vanilla mode: no pairing rows.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |
|------|------|-------------|-----------|------------|--------|----------|--------|
| S1 | Feature | `zensu-log.sh --project-root` verb | tests/structure/test-session-reanchor.sh | — | [I] | 1 | AC-001, FR-001 |
| S2 | Integration | Re-point the `zensu-log.sh` line citations in the two multi-repo documents | tests/structure/test-multi-repo-doc-citations.sh | S1 | [W] | 1 | FR-002 |
| S3 | Feature | `/zensu:tdd` derives every artifact path and `TOP` from `{project_root}` | tests/structure/test-tdd-log-path-anchor.sh | S1 | [I] | 1 | AC-003 |
| S4 | Feature | `self-review`, `converge` and `implement` derive their paths from the verb | tests/structure/test-tdd-log-path-anchor.sh | S1 | [I] | 1 | AC-004 |
| S5 | Feature | `--tdd-complete` refusal remedies name the bound root | tests/structure/test-tdd-complete-receipt-gate.sh | S1 | [I] | 1 | AC-006 |
| S6 | Feature | Tests that pinned the old spelling pin the new one; absence pin across skills | tests/structure/test-tdd-log-path-anchor.sh | S3, S4 | [I] | 1 | AC-004, AC-006 |
| S7 | Feature | End-to-end chain in the new anchor, driven from the start directory | tests/structure/test-session-reanchor.sh | S1, S3 | [I] | 1 | AC-001, AC-002 |
| S8 | Feature | Remove the known-gap wording and pin the new report and outcome texts | tests/structure/session-reanchor-v1.test.js | S3, S4 | [I] | 1 | AC-005 |
| S9 | Integration | `docs/tdd-manager-workflow.md` and the stale recipe remarks in `zensu-log.sh` and its tests | tests/structure/test-artifact-redaction.sh | S3 | [W] | 1 | AC-006 |
| S10 | Integration | Version class recorded as `patch` in the rule file | — | S1–S9 | [W] | 1 | FR-001 |

### Step S1 — `zensu-log.sh --project-root`
- **Covers**: AC-001, FR-001
- An arm beside `--session-key` prints the `CLAUDE_PROJECT_DIR` the binding case exported and exits 0; any extra argument exits 2. The binding case already fails with exit 2 and no stdout when the record cannot be bound.

### Step S2 — Citation re-point
- **Covers**: FR-002
- Shift every `zensu-log.sh` citation behind the insertion point by the inserted line count, then verify each cited line's content against the pre-change file.

### Step S3 — `/zensu:tdd`
- **Covers**: AC-003
- In-line edits only (the file is capped at 433 lines): Principle 3 defines `{log_file}` and `{plan_file}` from `{project_root}`; Phase 0 step 2 reads `{project_root}` and captures `BASELINE_SHA` from it; Phase 1 step 5, Phase 2 steps 1-2, Phase 6 step 5b a), step 10.1, step 10.2 (`TOP`) and step 2b follow. Phase 2's `--truncate` carries `CLAUDE_PROJECT_DIR="{project_root}"` so the destructive write binds to the bound root rather than to the working directory.

### Step S4 — Other skills
- **Covers**: AC-004
- `self-review` Phase 1 `TOP` and its ledger `--root`, `converge` Phase 0 plan discovery, `implement`'s artifact note.

### Step S5 — Refusal remedies
- **Covers**: AC-006
- The three `--tdd-complete` remedies that render `--project "${CLAUDE_PROJECT_DIR:-.}"` name the bound project root through the verb instead.

### Step S6 — Pins
- **Covers**: AC-004, AC-006
- `test-tdd-log-path-anchor.sh` L1/L2 and a new absence check, `test-edit-landing-audit.sh` P1, `test-artifact-redaction.sh` R54 (runs the recipe from a foreign working directory).

### Step S7 — End-to-end case
- **Covers**: AC-001, AC-002
- A new section in `tests/structure/test-session-reanchor.sh`: move the anchor, then run the verb, `--tdd-begin`, the skill-extracted baseline, log recipe, edit-landing audit and `--tdd-complete --plan` from the start directory with `CLAUDE_PROJECT_DIR` unset.

### Step S8 — Known-gap wording
- **Covers**: AC-005
- `session-reanchor-v1.js` report and outcome texts, their unit pins, `.claude/rules/session-reanchor.md`, `docs/session-control.md`, `skills/adopt-session/SKILL.md`.

### Step S9 — Operator account
- **Covers**: AC-006
- `docs/tdd-manager-workflow.md` artifact table, the append example and the `--truncate` paragraph; stale remarks about the old recipe.

### Step S10 — Version class
- **Covers**: FR-001
- Walk the change against `.claude/rules/runtime-lineage.md` and record `patch` in `.claude/rules/session-reanchor.md`.

**Checkpoint**: the directly affected structure suites (`bash tests/structure/test-<name>.sh`, `node --test tests/structure/<name>.test.js`) plus `bash -n` / `node --check` over the changed scripts, run from a detached worktree so no live session state reaches them (the full suite runs in CI; this repository commits `evidence.fullSuiteGate: advisory` and never runs `tests/run-all.sh` locally)

## Final Verification
- The affected structure suites pass on the final tree; the full suite is CI's gate for this repository (`evidence.fullSuiteGate: advisory`)
- Coverage SKIPPED (no coverage tooling for the changed shell and Markdown)
- Every active `AC-###` criterion verified live on the final tree (`/zensu:verify-feature --chain`, one `--acceptance-record` per criterion)
