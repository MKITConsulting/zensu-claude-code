# TDD Plan: Parallel Review Fan-out (v1 — thin-spawn)

## Context
Replace the single sequential `zensu:code-reviewer` spawn in the `/zensu:tdd` Phase 6
review chain with a parallel fan-out of 5 read-only `zensu:review-aspect` subagents,
merged in-thread, then surfaced via ONE thin `zensu:code-reviewer` (consume mode) so the
existing hook chain (post-review-tdd-delegate.sh, stop-chain-enforcer.sh, round counter,
self-review) stays byte-for-byte unchanged. Aspect reviewers run ZERO build/test commands;
the single suite run stays in Phase 6 audit. Grounded facts: (1) subagents cannot spawn
subagents — fan-out is orchestrated by the MAIN thread; (2) post-review hook reads NO
findings content, only needs one code-reviewer completion event per round.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash hooks + Markdown agents/skills + JSON manifest; tests = bash structure scripts under tests/structure/*.sh | **Coverage**: SKIPPED (no coverage tooling; bash project, no package.json)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| jq | CLI | `command -v jq` | present | n/a |
| node | CLI | `command -v node` | present | n/a |
| git | CLI | `command -v git` | present | n/a |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | NEW agents/review-aspect.md + plugin.json registration | tests/structure/test-review-aspect-agent.sh | - | [G] | 1 |
| S2 | Feature | code-reviewer consume-mode marker + skill Phase 6.10 fan-out | tests/structure/test-tdd-skill-review-fanout.sh | - | [G] | 1 |
| S3 | Refactoring | Version bump 0.5.0 -> 0.6.0 across plugin.json, marketplace.json, README badge+Agents, CHANGELOG; update test-self-review pin | (existing version tests) | S1 | [RF] | 1 |

### Step S1 — review-aspect agent
- [x] **RED**: test-review-aspect-agent.sh asserts agents/review-aspect.md exists, registered in plugin.json agents[], frontmatter name=review-aspect/model=inherit, read-only tools, prose forbids build/test, English-only. Fails: file missing.
- [x] **GREEN**: create agents/review-aspect.md (read-only single-perspective reviewer) + add "./agents/review-aspect.md" to plugin.json agents[].
**Checkpoint**: bash tests/structure/test-review-aspect-agent.sh passes

### Step S2 — skill fan-out + code-reviewer consume mode
- [x] **RED**: test-tdd-skill-review-fanout.sh asserts skills/tdd/SKILL.md Phase 6.10 has 5-parallel review-aspect spawn + in-thread merge + consume-mode thin code-reviewer spawn + parallel-batch carve-out; agents/code-reviewer.md has "PRE-MERGED FINDINGS (fan-out)" marker + skip-Phases-1-4 instruction. Fails: strings absent.
- [x] **GREEN**: add consume-mode branch to code-reviewer.md; rewrite skill Phase 6.10 step 3 to fan-out -> merge -> thin spawn; add carve-out to line-18 rule.
**Checkpoint**: bash tests/structure/test-tdd-skill-review-fanout.sh passes

### Step S3 — version bump (Refactoring Cycle)
- [x] **GREEN-BEFORE**: version tests pass at 0.5.0.
- [x] **CHANGE**: plugin.json .version, marketplace.json plugins[0].version, README badge -> 0.6.0; README Agents (2)->(3)+review-aspect row + fix "only subagent" prose; CHANGELOG ## [0.6.0] - 2026-06-01; test-self-review-skill.sh EXPECTED_VERSION 0.5.0->0.6.0.
- [x] **GREEN-AFTER**: test-zensu-help, test-reset-review-limit, test-self-review pass at 0.6.0.
**Checkpoint**: version-consistency tests pass

## Final Verification
- [x] New tests green: test-review-aspect-agent.sh, test-tdd-skill-review-fanout.sh
- [x] Full structure suite: no NEW failures vs baseline (27 pass / 2 pre-existing fail: test-post-bash-witness.sh, test-pre-edit-hook-mirror.sh)
- [x] Coverage: SKIPPED (no tooling)
