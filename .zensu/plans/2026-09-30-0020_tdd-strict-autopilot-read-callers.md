# TDD Plan: Strict Autopilot active-run reads where a lease fault relaxes a guard

## Context
In the Zensu plugin repository (zensu-claude-code, English-only, no code comments), `autopilot_read_active` in hooks/lib/zensu-autopilot-state.sh ends in `_autopilot_locked_run`, and `_tdd_locked_run` (hooks/lib/zensu-tdd-phase.sh) returns 1 for a storage-safety failure, a failed lock acquisition and a failed release, which is the same status as the worker's own "no active run". Commit ccf55b9c on branch claude/inspiring-clarke-be6d3e added `autopilot_read_active_strict`, which runs the worker through `_autopilot_active_probe` and answers 0 run printed, 1 proven no run, 2 orphaned or inconsistent run, 3 refused call, 5 lease, storage or path fault — the same separation `autopilot_workspace_hold_report` already makes for the workspace question. Only hooks/lib/session-reanchor-v1.js uses it so far.

Task: go through every caller of `autopilot_read_active` (.claude/rules/autopilot-run-scope.md names the resume hook, plan-approved-delegate.sh, three stop-chain-enforcer.sh sites, two post-review-tdd-delegate.sh sites and zensu-log.sh --autopilot-status). For each, decide whether reading exit 1 as "no run" during lock contention relaxes a guard, for example letting a Stop through or taking the standalone path for an Autopilot-bound chain. Where it does, switch that caller to the strict verb and handle 5 fail-closed. Add a test per switched caller that holds the Autopilot lease; tests/structure/session-reanchor-v1.test.js shows how, using core.acquireExternalProcessLock with lockDirectory `<root>/.zensu/state` and resourcePath `<root>/.zensu/state/autopilot`. Record each decision in .claude/rules/autopilot-run-scope.md. Follow the repository's /zensu:tdd workflow and check .claude/rules/runtime-lineage.md for the version class.

Base: this branch stacks on `claude/inspiring-clarke-be6d3e` at 43b93f32 (origin/main 704df189 merged with ccf55b9c), because the strict verb exists only there.

**Approach**: Vanilla implementation (strict TDD discipline not in effect for this chain) | **Tech Stack**: bash hooks + Node.js helpers, bash structure suites | **Coverage**: SKIPPED (no coverage tool covers the bash hooks) @ n/a (default-90%)

### Per-caller decisions
| Caller | Exit 1 under a lease fault | Decision |
|--------|----------------------------|----------|
| `hooks/plan-approved-delegate.sh` | selects the standalone plan policy for a plan owned by a PLANNING/AWAIT_TDD run; PLAN_APPROVED is never recorded | strict; 5 emits `PLAN_GATE_BLOCKED code=ACTIVE_STATE_UNREADABLE` |
| `hooks/stop-chain-enforcer.sh` initial outer read | `OUTER_PRESENT=false`; an implementing standalone chain reaches `outer_finish`, whose reconcile also reads a lease fault as 1 and releases the Stop | strict; 5 blocks with its own reason |
| `hooks/stop-chain-enforcer.sh` `outer_finish` stale-generation re-read | returns without a decision, releasing the Stop for a run the reconcile just proved active | strict; 5 blocks through the existing `-ne 1` arm |
| `hooks/stop-chain-enforcer.sh` `outer_reload` | two call sites discard the status and block; the terminal-release race falls through to the bound-inner budget claim, which blocks on the emptied `OUTER_JSON` | keep `autopilot_read_active` |
| `hooks/post-review-tdd-delegate.sh` standalone preflight | permits the unbound ticket claim while this session owns a nonterminal run | strict; 5 exits before the claim |
| `hooks/post-review-tdd-delegate.sh` bound preflight | `|| exit 0` already ends the hook before the claim on every non-zero status | keep |
| `hooks/lib/zensu-log.sh --autopilot-status` | exit 1 is the documented "no active durable run" skills route on, and its stderr disclosure states "this session owns no durable Autopilot run" | strict; 5 exits 5 with its own stderr line |
| `hooks/session-start-autopilot-resume.sh` | advisory SessionStart context only; its silence releases, arms and approves nothing | keep |

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | `.claude/rules/autopilot-run-scope.md` records, for every production caller of `autopilot_read_active`, whether a lease fault read as exit 1 relaxes a guard and which verb the caller uses | spec |
| AC-002 | With the Autopilot project lease held, `plan-approved-delegate.sh` for a session owning a PLANNING run emits `PLAN_GATE_BLOCKED` with a lease/storage code, never the standalone policy, and leaves the run record byte-identical; after release the same approval is recorded | spec |
| AC-003 | With the lease held, the Stop hook for a session that owns a nonterminal run and has a standalone chain still implementing blocks with a reason that says the state could not be read, and leaves the run record byte-identical | spec |
| AC-004 | When the lease is taken between `outer_finish`'s budget CAS and its stale-generation re-read, the Stop blocks instead of releasing | spec |
| AC-005 | With the lease held, `post-review-tdd-delegate.sh` refuses the unbound claim of a standalone chain whose session owns a nonterminal run, emits nothing and leaves the review ticket unconsumed | spec |
| AC-006 | With the lease held, `zensu-log.sh --autopilot-status` exits 5, prints nothing on stdout, and its stderr says the state could not be read instead of claiming the session owns no run; without the lease it prints the run | spec |
| AC-007 | Callers whose exit 1 relaxes no guard keep `autopilot_read_active`: the resume hook, `outer_reload`, the bound post-review preflight | spec |
| AC-008 | Existing Stop-hook fixtures that stub the initial outer read keep driving the paths they were written for | derived |
| FR-001 | One sourced test helper holds the Autopilot lease through `core.acquireExternalProcessLock` (lockDirectory `<root>/.zensu/state`, resourcePath `<root>/.zensu/state/autopilot`), both around one command and in the background | spec |
| FR-002 | The version class is recorded against `.claude/rules/runtime-lineage.md` | spec |
| FR-003 | `docs/tdd-manager-workflow.md` states that `--autopilot-status` exits 5, not 1, when its own read fails | derived |

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | n/a (present) |
| node | CLI | `command -v node` | present | n/a (present) |
| git | CLI | `command -v git` | present | n/a (present) |
| session baseline fixture | fixture | `[ -f tests/session-control/initialize-baseline.sh ]` | present | n/a (present) |

## Cross-Layer Value Flow Pairings
(Per Principle 2 — Cross-Layer Value Flow Pairing. Omit table body if no pairings; keep the heading so Phase 6 audit can detect absence vs zero rows.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |
|------|------|-------------|-----------|------------|--------|----------|--------|
| S1 | Integration | Shared lease helper `tests/structure/lib-autopilot-lease.sh` | tests/structure/lib-autopilot-lease.sh | - | [W] | 1 | FR-001 |
| S2 | Feature | Plan gate: strict read, `ACTIVE_STATE_UNREADABLE` cause, lease test P7e | tests/structure/test-autopilot-plan-delegate.sh | S1 | [I] | 1 | AC-002 |
| S3 | Feature | Stop initial read: strict verb, dedicated 5 block, lease test S16a | tests/structure/test-autopilot-stop-enforcer.sh | S1 | [I] | 1 | AC-003 |
| S4 | Feature | Stop `outer_finish` re-read: strict verb, mid-hook lease test S16b | tests/structure/test-autopilot-stop-enforcer.sh | S1 | [I] | 1 | AC-004 |
| S5 | Integration | Retarget the Stop fixtures that stub the initial read to the strict verb | tests/structure/test-autopilot-stop-enforcer.sh | S3 | [W] | 1 | AC-008 |
| S6 | Feature | Post-review standalone preflight: strict verb, lease test O2d | tests/structure/test-post-review-outer-ownership-root.sh | S1 | [I] | 1 | AC-005 |
| S7 | Feature | `--autopilot-status`: strict verb, rc 5 stderr line, lease test W33, docs | tests/structure/test-autopilot-state-machine.sh | S1 | [I] | 1 | AC-006, FR-003 |
| S8 | Integration | Rule file: per-caller decisions, kept callers, known gaps, version class | .claude/rules/autopilot-run-scope.md | S2, S3, S4, S6, S7 | [W] | 1 | AC-001, AC-007, FR-002 |

### Step S1 — Shared lease helper
- **Covers**: FR-001
- `with_autopilot_lease <root> <command...>` acquires the lease, runs the command with inherited stdio, releases, and returns the command's status. `autopilot_lease_hold_start <root> <dir>` starts a background holder that writes `<dir>/ready`, waits for `<dir>/release` (bounded), releases and writes `<dir>/done`.

### Step S2 — Plan gate
- **Covers**: AC-002

### Step S3 — Stop initial read
- **Covers**: AC-003

### Step S4 — Stop stale-generation re-read
- **Covers**: AC-004

### Step S5 — Stop fixture stubs
- **Covers**: AC-008
- S8g, S8h, S8k, S8i stub the initial read as absent; S9f, S9g, S9i wrap it to race a transition. They now name `autopilot_read_active_strict`.

### Step S6 — Post-review standalone preflight
- **Covers**: AC-005

### Step S7 — `--autopilot-status`
- **Covers**: AC-006, FR-003

### Step S8 — Rule file
- **Covers**: AC-001, AC-007, FR-002

**Checkpoint**: the touched suites (`bash tests/structure/test-<name>.sh`) run in a throwaway worktree at a canonical path, plus `bash -n` over every changed shell file. The repository forbids a local `tests/run-all.sh`; CI is the full-suite gate (`evidence.fullSuiteGate: advisory`).

## Final Verification
- Every touched suite passes in a throwaway worktree, and each new lease check fails against the unchanged hooks
- The full suite runs in CI on the pull request; it is not run locally by repository rule
- Coverage: SKIPPED — no coverage tool instruments the bash hooks
