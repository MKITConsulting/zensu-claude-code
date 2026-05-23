# TDD Plan: Test-Run Evidence — Anti-Hallucination Witness Log

## Context

Eliminate hallucinated test-run claims by providing an independent witness log of every Bash tool invocation during a tdd-manager subagent session. Cross-check agent's claimed test runs (`CHECKPOINT`/`AUDIT` log entries with `cmd="..."` fields) against the witness log via literal-string match.

Three architecture layers:
- Layer 1: Hook-witnessed Bash via NEW `hooks/post-bash-witness.sh` (PostToolUse Bash, scoped to `CLAUDE_AGENT_TYPE=zensu:tdd-manager`).
- Layer 2: Mandatory log contract in `agents/tdd-manager.md` Phase 5 + 6 prompts (`CHECKPOINT — cmd="X" exit=N result="..."` / `AUDIT — cmd="X" exit=N result="..."`).
- Layer 3: Phase 6 cross-check (`grep -F -q 'cmd="X"' witness.log`) → `EVIDENCE GAP — cmd="X" claimed but not in witness log` on mismatch.
- Non-Bash escape: `via=tool_name claim="..."` declares known-limit; not flagged.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + node + jq + promptfoo + markdown | **Coverage**: SKIPPED (bash hooks + markdown prompts; no coverage tool installed for this repo)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present | install (already) |
| jq | CLI | `command -v jq` | present | install (already) |
| bash | CLI | `command -v bash` | present | install (already) |
| promptfoo | CLI | `command -v promptfoo` | present | install (already) |
| claude | CLI | `command -v claude` | present | install (already) |
| gh | CLI | `command -v gh` | present | install (already) |

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Witness hook + 9-case structure test | tests/structure/test-post-bash-witness.sh | — | [ ] | 0 |
| S2 | Feature | Prompt edits (Phase 5+6 contract) + +3 structure cases | tests/structure/test-tdd-manager-patches.sh | S1 | [ ] | 0 |
| S3 | Feature | Wrapper witness block + +3 structure cases | tests/structure/test-claude-promptfoo-wrapper.sh | S1 | [ ] | 0 |
| S4 | Integration | Hook registration in hooks/hooks.json | hooks/hooks.json | S1 | [ ] | — |
| S5 | Integration | 3 new promptfoo scenarios | evals/tdd-manager-pretool/scenarios/witness-*.yaml | S1, S2, S3 | [ ] | — |
| S6 | Integration | Docs (README, docs/tdd-manager-workflow.md, CHANGELOG) | README.md, docs/tdd-manager-workflow.md, CHANGELOG.md | S1, S2, S3 | [ ] | — |
| S7 | Integration | Promptfoo eval run (full suite) | /tmp/v10.json | S4, S5 | [ ] | — |

### Step S1 — Hook + structure test (Feature)

- [ ] **RED**: 9-case structure test asserts hook syntax, CAT-scoped, opt-out, multi-write, JSON escape, missing tool_response, CLAUDE_PROJECT_DIR fallback, no pattern filter, no-CAT silent. FAIL initially because `hooks/post-bash-witness.sh` does not exist.
- [ ] **GREEN**: Create `hooks/post-bash-witness.sh` (~40 lines) per spec.

### Step S2 — Prompt edits (Feature)

- [ ] **RED**: +3 structure cases in test-tdd-manager-patches.sh assert Phase 5/6 contract substrings (CHECKPOINT cmd= / AUDIT cmd= / EVIDENCE GAP / via= / witness log / Test Evidence section). FAIL initially because agents/tdd-manager.md does not contain these strings.
- [ ] **GREEN**: Edit agents/tdd-manager.md Phase 5, Phase 6 step 1, Phase 6 step 9 schema + add via= escape clause.

### Step S3 — Wrapper extension (Feature)

- [ ] **RED**: +3 wrapper structure cases (P12-S1..S3) assert witness block append behavior. FAIL initially because scripts/claude-promptfoo-wrapper.sh does not contain witness-glob code.
- [ ] **GREEN**: Extend wrapper to append `===== witness: <file> =====` blocks for any `.zensu/logs/witness-*.log` files in isolated dir.

### Step S4 — Hook registration (Integration)

- [ ] **WIRE**: Append Bash matcher to PostToolUse array in hooks/hooks.json calling `${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-witness.sh`.

### Step S5 — Promptfoo scenarios (Integration)

- [ ] **WIRE**: Create 3 YAML scenarios under evals/tdd-manager-pretool/scenarios/ — witness-bash-runs.yaml, witness-evidence-gap.yaml, witness-non-bash-via.yaml. Register all 3 in promptfooconfig-pretool.yaml tests list.

### Step S6 — Docs (Integration)

- [ ] **WIRE**: README Hooks table + Environment Variables table (ZENSU_TEST_WITNESS); docs/tdd-manager-workflow.md section 10 rename to "Four-Channel Logging Contract" + add witness as fourth channel; CHANGELOG Unreleased Added entry.

### Step S7 — Full promptfoo suite (Integration)

- [ ] **WIRE**: Run the full v10 promptfoo eval suite in background; collect stats. Acceptance: ≥ 16/17 PASS (3 new + 13/14 baseline retained, TEST 12 over-match known issue).

**Checkpoint**: All 3 structure tests + full structure suite + v10 promptfoo stats reviewed.

## Final Verification

- [ ] All structure test files PASS
- [ ] All 3 new witness scenarios PASS in v10 promptfoo suite
- [ ] 13/14 baseline scenarios retained
- [ ] PR opened off latest origin/main
- [ ] Phase 5 CHECKPOINT + Phase 6 AUDIT log entries present in THIS task's log
- [ ] Coverage: SKIPPED (no tool installed for bash/markdown layer)
