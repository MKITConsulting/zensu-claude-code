# TDD Plan: Verified Session Control re-anchor within one repository

<!--
Authoring rules — this file is written to be COMMITTED. Consuming repos keep
.zensu/plans/ as an audit trail and may later open-source the repository.
  * English only, whatever language the session is conducted in.
  * No absolute paths: name files by their repo-root-relative path.
-->

## Context
Feature: a verified Session Control re-anchor for a session that works in a sibling worktree of the SAME repository, plus deny texts that never point at a worktree other than the command's own target.

Problem (reproduced 2026-09-29 with a scratch script against this tree): a record pins `project_root` to its SessionStart cwd and never re-anchors it. A session recorded at worktree A that works in sibling worktree B of the same repository gets (1) `git add` in B denied by rule (C) of the Bash source-write gate, whose remedy says `git -C '<A>' add …` and would stage into the wrong worktree; (2) `zensu:review-aspect` reviewers confined to A, unable to read B's changed files; (3) `/zensu:adopt-session --confirm` answering ALREADY SERVED and keeping A; (4) the `ZENSU_BASH_WRITE_GATE=off` escape refused by the auto-mode classifier, so no sanctioned route exists. Observed in the field on 2026-09-23 on Zensu 0.21.1.

Design decisions settled before implementation:
- The user-facing spelling is `/zensu:adopt-session --reanchor`; the skill routes it to a SEPARATE entry script, `hooks/lib/zensu-session-reanchor.sh`, whose only argument is `--confirm`. The recognized adopt script, its header and the write-class carriers stay untouched. The move runs only in a BOUND session, so the bind-failure recognizer (`hooks/lib/zensu-doctor-invocation.js`) is NOT widened and admits the new script in no shape.
- The target is the top-level of the git worktree that contains the directory the command runs in. It is never an argument value. What bounds it is verification, not derivation: same git common directory as the recorded root, a registered non-prunable worktree, the recorded root must still EXIST (a deleted root cannot prove its repository — the refused cross-project escape stays closed), and no other live session claims it.
- Liveness evidence: the host's live-session registry (`<config dir>/sessions/*.json`, the same store `/zensu:session-trail` reads) must contain THIS session, else the check fails closed; a foreign live entry claims its cwd and its Zensu-recorded project root; a foreign live or unvalidatable worktree-keep anchor claims its worktree. Claims are mapped to registered worktrees, and a claim on the target OR on a worktree nested inside it refuses.
- The workflow document is not carried. The move refuses while a chain is armed and unfinished, a skill workflow is open, an Autopilot run is linked, a review rearm is pending or a deferred review is claimed: that evidence is bound to the old root. A fresh baseline document is created at the new root before the record swap.
- The record swap reuses the adoption's set-aside protocol, extracted into one core primitive instead of copied.
- Reviewer confinement follows by construction: the capability gate reads `project_root` from the record on every tool call. An end-to-end check pins it.
- Version class: `patch` (no record or workflow schema field, no strict key set, no hook added or re-matched, a new history VALUE and a new argv literal on an existing command, which the restore mode already classified as patch).

**Approach**: Vanilla implementation (strict TDD discipline not in effect for this chain) | **Tech Stack**: bash (3.2 and 5) plus Node.js CommonJS hook libraries; bash structure suites with `node:test` units | **Coverage**: `node_modules/.bin/c8 --reporter=text --include=hooks/lib/session-reanchor-v1.js node --test tests/structure/session-reanchor-v1.test.js` @ 90% lines (default-90%)

## Requirements
| ID | Requirement | Source |
|----|-------------|--------|
| AC-001 | `/zensu:adopt-session --reanchor` (read-only) reports whether this session's anchor may move to the top-level of the git worktree containing the command's working directory, and writes nothing. | spec |
| AC-002 | `--reanchor --confirm` re-mints this session's record with the new `project_root` and nothing else changed (plugin root, version, digest, `created_at` carried), setting the previous record aside under a new name, never overwriting it. | spec |
| AC-003 | Refuses unless the record reads strictly, the executing runtime serves it, and `plugin_data` matches; a vanished recorded root refuses with a remedy naming `--restore-root`; a lineage break or pruned installation refuses with adopt-first. | spec |
| AC-004 | Refuses unless the recorded root exists inside a git worktree, the target is inside a git worktree, both share one git common directory, and the target top-level is a registered, non-prunable worktree of that repository. | spec |
| AC-005 | Refuses when the target top-level already equals the recorded root. | spec |
| AC-006 | Refuses when another live session claims the target worktree: a live registry entry of another session whose cwd or Zensu-recorded project root lies in it, or another session's live or unvalidatable worktree-keep anchor there. | spec |
| AC-007 | Fails closed when the live-session evidence is incomplete: registry unreadable, this session absent from it, an unparseable entry with a live pid, an unreadable anchor listing, or a live foreign session whose record cannot be read. | spec |
| AC-008 | Refuses while this session's workflow document at the recorded root is missing or unreadable, or shows an armed unfinished chain, an open skill workflow, an Autopilot linkage, a pending review rearm or a deferred-review claim, and while an Autopilot run this session owns under the recorded root is short of DONE or CANCELLED, whether or not a chain links it; Autopilot state that cannot be read cleanly refuses too, and so does an Autopilot lock the reader cannot take; that rung runs after every git and containment check. | spec, review R1-F1, R2-F1, R2-F8 |
| AC-009 | Refuses when a document for this session already exists at the target but is unsafe or unreadable. | spec |
| AC-010 | On confirm the verdict is re-derived under a per-repository re-anchor lock and the Session Control records lock, the written `project_root` must equal the verified worktree, and a missing target workflow document is created as a baseline before the record swap. | spec, review R1-F8, R1-F9 |
| AC-011 | Provenance is one `PROJECT_ROOT_REANCHORED` history entry in the new and in the old document; `zensu-log.sh --phase` and the phase library refuse to mint that phase or its reason prefix; no bypass-ledger entry. | spec |
| AC-012 | Review-evidence leases whose project root is not the new anchor are moved aside (never deleted) and counted. | spec |
| AC-013 | With worktree-keep enabled, this session's keep anchor is aged in the old worktree and written in the new one. | spec |
| AC-014 | After a re-anchor the source-write gate allows `git add` in the new worktree and denies it in the old one, and review-aspect reviewers can read the new worktree and cannot read the old one. | spec |
| AC-015 | The PreToolUse bind-failure recognizer does not admit `--reanchor`. | spec |
| AC-016 | Rule (B) and rule (C) deny texts never name a worktree other than the command's own target; a bound session's deny names `/zensu:adopt-session --reanchor`; the one-off escape sentence stays last; the W163 and W204 remedy properties stay. | spec |
| AC-017 | Operator docs and rule files state that the unbounded caller-named re-anchor stays refused and document the bounded same-repository re-anchor, its conditions and its known gaps. | spec |
| AC-018 | Refuses a target whose top-level contains the recorded root, or contains any other registered worktree of the repository. | review R1-F35 |
| AC-019 | On confirm this session's `tdd-mode`, `delivery-route` and `zen-mode` markers move to the new root; a marker that cannot move stays in place and is reported. | review R1-F7 |
| AC-020 | The session identity is read from `CLAUDE_CODE_SESSION_ID` only, and the read-only report lists the target's uncommitted paths, each inside double quotes and read without optional git locks. | review R1-F10, R1-F5, R2-F5, R2-F10 |

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| git (worktree list --porcelain -z, git >= 2.36) | CLI | `git --version` (2.51.0) | present | install |
| node | CLI | `command -v node` (v26.9.0) | present | install |
| c8 | CLI | `node_modules/.bin/c8 --version` | missing from the stale worktree install; declared in package.json | install (`npm ci`, per the recorded fresh-worktree rule) |

## Cross-Layer Value Flow Pairings
(Per Principle 2 — Cross-Layer Value Flow Pairing. Omit table body if no pairings; keep the heading so Phase 6 audit can detect absence vs zero rows.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts | Covers |
|------|------|-------------|-----------|------------|--------|----------|--------|
| S1 | Refactoring | Core primitives: extract the adoption's set-aside swap into `supersedeContextRecord`, add `contextRecordLocation`, export `initializeWorkflowStateDetailed` | tests/session-control/session-control-core-v1.test.js | - | [RF] | 1 | AC-002, AC-010 |
| S2 | Feature | Lease sweep takes an optional project-root filter | tests/structure/session-reanchor-v1.test.js | - | [G] | 1 | AC-012 |
| S3 | Feature | `hooks/lib/session-reanchor-v1.js`: git identity, live-claim probe, workflow blocker, verdict, locked perform, renderers | tests/structure/session-reanchor-v1.test.js | S1, S2 | [G] | 1 | AC-001, AC-002, AC-003, AC-004, AC-005, AC-006, AC-007, AC-008, AC-009, AC-010, AC-011, AC-012, AC-013, AC-018, AC-019, AC-020 |
| S4 | Feature | Entry script `hooks/lib/zensu-session-reanchor.sh` and the module's `main()`: caller directory, `--confirm` only, module table, worktree-keep config | tests/structure/test-session-reanchor.sh | S3 | [G] | 2 | AC-001, AC-002, AC-013, AC-015 |
| S5 | Feature | Reserve `PROJECT_ROOT_REANCHORED` and its reason prefix in `zensu-log.sh --phase` and `_tdd_reserved_provenance` | tests/structure/test-session-reanchor.sh | - | [G] | 1 | AC-011 |
| S6 | Feature | Rule (B)/(C) remedy texts plus the bound-only `BSWG_REANCHOR` flag | tests/structure/test-bash-source-write-gate.sh | - | [G] | 2 | AC-016 |
| S7 | Feature | End-to-end suite `tests/structure/test-session-reanchor.sh` and its registration | tests/structure/test-session-reanchor.sh | S3, S4, S5 | [G] | 2 | AC-003, AC-004, AC-005, AC-006, AC-008, AC-011, AC-014, AC-015, AC-018, AC-019 |
| S8 | Integration | Skill, operator docs and rule files | - | S3, S4, S5, S6, S7 | [W] | 1 | AC-017 |

### Step S1 — Core primitives
- **Covers**: AC-002, AC-010
- **Change**: move the copy-aside-then-atomic-swap block of `adoptContext` into `supersedeContextRecord(file, supersededFile, next)` unchanged; `contextRecordLocation(options)` derives the records, locks and record paths once; `initializeWorkflowStateDetailed` is exported so a caller can tell a creation from a find.

### Step S2 — Lease sweep project-root filter
- **Covers**: AC-012
- **Change**: `discardSupersededLeases(pluginData, key, executingPluginRoot, projectRoot)`; with a fourth argument a lease is kept only when it is owned AND names that project root. Three-argument callers are unchanged.

### Step S3 — Re-anchor module
- **Covers**: AC-001 … AC-013
- **Change**: verdict ladder in this order — strict read (else orphan → `recorded-root-missing`, pruned → `not-served-by-executing-runtime`, else `record-unreadable`), plugin data, served, own document present and leavable, recorded-root repository, target repository, same common directory, registered worktree, not already anchored, target document usable, live claims. `performReanchor` re-derives the verdict under `withFileLock` on the records lock, creates a missing target baseline, swaps the record, then records provenance in both documents, sweeps leases and moves the worktree-keep anchor.

### Step S4 — Entry script and `main()`
- **Covers**: AC-001, AC-002, AC-013, AC-015
- **Change**: `hooks/lib/zensu-session-reanchor.sh` captures the caller's directory before its own `cd`, accepts `--confirm` at most once and nothing else, guards its nine modules and three shell siblings from one table, reads the worktree-keep flag and idle hours through `zensu-config.sh`, and runs `session-reanchor-v1.js` as a program; `main()` refuses a malformed session id and an unsafe record store with their own reasons before any read. Chosen over a `ZADOPT_MODE` route so the bind-failure-recognized adopt script and its header stay untouched.

### Step S5 — Reserved provenance phase
- **Covers**: AC-011

### Step S6 — Remedy texts
- **Covers**: AC-016
- **Change**: rule (C)'s repository and designation arms stop spelling `git -C '<recorded root>'`; a bound call (`BSWG_REANCHOR=1`) names `/zensu:adopt-session --reanchor`; rule (B) gains the same sentence; the unbound call site pins the flag empty. The new assignment sits after `PAYLOAD=`, because `test-secret-scan-gate.sh` P5b pins the literal `BSWG_MODE= PAYLOAD=`.

### Step S7 — End-to-end suite
- **Covers**: AC-003, AC-004, AC-005, AC-006, AC-008, AC-011, AC-014, AC-015
- **Change**: the field reproduction as a suite: two worktrees, a record anchored at the first, gates driven from the second before and after the move, refusals for a claimed, a foreign-repository, a non-registered and an in-progress target, and the recognizer refusal. Registered in `tests/profiles/promptfoo-local-only.v1.json` and `tests/SUITE-OVERVIEW.md`.

### Step S8 — Skill, docs, rules
- **Covers**: AC-017
- **Change**: `skills/adopt-session/SKILL.md`, `docs/session-control.md`, `docs/gates.md`, `docs/worktree-keep.md`, `skills/session-trail/SKILL.md` and the matching comment in `skills/session-trail/scripts/trail.mjs` (both said nothing re-anchors a session), `.claude/rules/session-adoption.md`, `.claude/rules/restore-vanished-project-root.md`, `.claude/rules/worktree-keep.md`, a new `.claude/rules/session-reanchor.md` and its `CLAUDE.md` index entry. `.claude/rules/git-mutation-tables.md` needed no change: the new rule file carries the remedy-text couplings.

**Checkpoint**: the scoped suites over each phase's changed files (`bash tests/structure/<suite>.sh`, `node --test tests/structure/<unit>.test.js`, `bash tests/session-control/run.sh`) plus `node --check` / `bash -n` on every changed script. The full suite (`bash tests/run-all.sh --ci`) is not run locally by this project's rule; `.zensu/config.json` sets `evidence.fullSuiteGate` to `advisory`, and CI is the gate.

## Final Verification
- All scoped suites pass; the full suite runs in CI (`evidence.fullSuiteGate: advisory`)
- Coverage report generated for the new module (threshold: 90% lines)
