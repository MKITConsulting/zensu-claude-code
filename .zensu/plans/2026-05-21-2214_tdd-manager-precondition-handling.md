# TDD Plan: tdd-manager Precondition Handling + Claude-code Wrapper

## Context

Patch the `tdd-manager` agent to (1) generalize Phase 1 step 3b's coverage-tool precondition pattern into a new Phase 1.5 covering ALL spec-named dependencies (CLI, secret, endpoint, fixture); (2) ban silent self-substitution via Rationalization Counters and Hard Bans; (3) override "no questions" instructions for blocking-precondition escalation; (4) audit precondition drift in Phase 6; AND (5) introduce a `claude` CLI wrapper as a promptfoo `exec:` provider so verification scenarios no longer require third-party API keys.

Round 4 failure mode (referenced in `.zensu/plans/2026-05-21-1633_tdd-pretooluse-phase-gate.md`): the agent treated missing preconditions as a content problem ("write KNOWN-ISSUES.md and proceed") instead of an escalation. This round closes that gap by encoding precondition discovery as Phase 1.5, requiring AskUserQuestion regardless of "no questions" instructions, and providing a Phase 6 drift detector.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash 5+, YAML, Markdown (agent prompt) | **Coverage**: SKIPPED — no coverage tool installed for bash scripts in this repo (existing convention: bash test scripts at `evals/tdd-manager-pretool/test-*.sh`)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| claude CLI | CLI | `command -v claude` | present (2.1.146) | install (already present) |
| promptfoo CLI | CLI | `command -v promptfoo` | present (0.121.12) | install (already present) |
| jq CLI | CLI | `command -v jq` | present (1.7.1) | install (already present) |
| evals/tdd-manager-pretool/ | fixture | `[ -d evals/tdd-manager-pretool ]` | present | install (already present) |

No missing preconditions — Phase 1.5 escalation not required for this run.

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| P7-S1 | Feature | Wrapper script — happy path (DRY_RUN with agent+working_dir) | tests/structure/test-claude-promptfoo-wrapper.sh | — | [G] | 2 |
| P7-S2 | Feature | Wrapper script — raw passthrough (empty options) | tests/structure/test-claude-promptfoo-wrapper.sh | P7-S1 | [G] | 0 (regression-coverage, merged into P7-S1 IMPL) |
| P7-S3 | Feature | Wrapper script — defaults working_dir to "." | tests/structure/test-claude-promptfoo-wrapper.sh | P7-S1 | [G] | 0 (regression-coverage, merged into P7-S1 IMPL) |
| P7-S4 | Feature | Wrapper script — exit 127 on missing claude CLI | tests/structure/test-claude-promptfoo-wrapper.sh | P7-S1 | [G] | 1 |
| P7-S5 | Feature | Wrapper script — exit 2 on bad working_dir (real-run path) | tests/structure/test-claude-promptfoo-wrapper.sh | P7-S1 | [G] | 1 |
| P7-S6 | Feature | Wrapper script — `bash -n` clean (syntax check) | tests/structure/test-claude-promptfoo-wrapper.sh | P7-S1 | [G] | 0 (regression-coverage, file already valid) |
| P1-P6 | Feature | Agent prompt — Patches 1-6 applied verbatim | tests/structure/test-tdd-manager-patches.sh | — | [G] | 1 |
| P7-CFG | Integration | Update promptfooconfig-pretool.yaml to use wrapper exec provider | — | P7-S1..S6 | [W] | — |
| SC-1 | Integration | New scenario YAML — precondition-missing-cli.yaml | — | P1-P6, P7-CFG | [W] | — |
| SC-2 | Integration | New scenario YAML — precondition-missing-secret.yaml | — | P1-P6, P7-CFG | [W] | — |
| SC-3 | Integration | New scenario YAML — precondition-drift-audit.yaml + fixtures | — | P1-P6, P7-CFG | [W] | — |

### Step P7-S1 — Wrapper happy-path DRY_RUN
- [ ] **RED**: Test asserts `DRY_RUN=1` with `{"config":{"agent":"zensu:tdd-manager","working_dir":"/tmp"}}` produces stdout containing `claude --print --output-format json --dangerously-skip-permissions` AND `subagent_type='zensu:tdd-manager'`. Fails because script does not exist yet.
- [ ] **GREEN**: Create `scripts/claude-promptfoo-wrapper.sh` with happy-path code.

### Step P7-S2 — Wrapper raw passthrough
- [ ] **RED**: Test asserts `DRY_RUN=1` with `{}` produces stdout NOT containing `subagent_type=`. Fails until wrapper handles empty agent field.
- [ ] **GREEN**: Branch in wrapper: when agent absent, pass prompt raw without Agent-tool prefix.

### Step P7-S3 — Wrapper default working_dir
- [ ] **RED**: Test asserts `DRY_RUN=1` with `{"config":{"agent":"x"}}` (no `working_dir`) prints `cwd=.`. Fails until wrapper defaults to `.`.
- [ ] **GREEN**: `[ -z "$WORKDIR" ] && WORKDIR="."`.

### Step P7-S4 — Wrapper exit 127 on missing claude CLI
- [ ] **RED**: Test invokes `env -i PATH=/nonexistent bash scripts/claude-promptfoo-wrapper.sh "p" '{}'`. Asserts exit code 127 and diagnostic message. Fails because script does not exist.
- [ ] **GREEN**: `command -v claude >/dev/null 2>&1 || { echo ...; exit 127; }`.

### Step P7-S5 — Wrapper exit 2 on bad working_dir
- [ ] **RED**: Test stubs `claude` on PATH (so it gets past the 127 check) and runs with `working_dir=/no/such/path`. Asserts exit code 2 and "cannot cd" diagnostic. Fails until wrapper has `cd "$WORKDIR" || { ...; exit 2; }`.
- [ ] **GREEN**: Add the cd-or-exit block.

### Step P7-S6 — bash -n syntax check
- [ ] **RED**: Test runs `bash -n scripts/claude-promptfoo-wrapper.sh`. Fails because file does not exist (cycles satisfied by S1's creation).
- [ ] **GREEN**: Already satisfied by file creation in P7-S1 — but the assertion line must exist in the test suite.

### Step P1-P6 — Apply agent patches 1-6
- [ ] **RED**: Bash structural test grepping for the verbatim phrases each patch introduces (3 new Rationalization Counters, the new Hard Ban sentence, the Phase 1.5 header, the Preconditions table template, the Phase 4 self-check expansion, the Phase 6 drift-audit step). Fails until patches applied.
- [ ] **GREEN**: Apply patches 1-6 to `agents/tdd-manager.md`. Verify line count ≤ 320.

### Step P7-CFG — Wire promptfoo to wrapper
- Integration. Update `evals/tdd-manager-pretool/promptfooconfig-pretool.yaml` (and regression config) to use `exec:` provider pointing at the wrapper.

### Step SC-1 — Scenario: missing CLI
- Integration. Write new YAML scenario asserting AskUserQuestion fires for missing `snorgleblorf`, no hand-rolled replacement files, Preconditions table present.

### Step SC-2 — Scenario: missing secret
- Integration. Write new YAML scenario asserting AskUserQuestion fires for missing `SNORG_API_KEY`, no placeholder values, `[!]` marker appears.

### Step SC-3 — Scenario: drift audit
- Integration. Write new YAML scenario with pre-built plan+log fixture and assert `PRECONDITION DRIFT` log output.

**Checkpoint**: `bash tests/structure/test-claude-promptfoo-wrapper.sh && bash tests/structure/test-tdd-manager-patches.sh` pass. Agent line count ≤ 320.

## Final Verification
- [x] All wrapper tests PASS (8/8)
- [x] All patches structurally present in `agents/tdd-manager.md` (16/16)
- [x] Agent file line count ≤ 320 (304)
- [x] 3 new scenario YAMLs committed
- [x] promptfooconfig updated to wrapper provider (both pretool + regression)
- [x] Build verification (n/a — bash + markdown, no buildable artifact)
- [x] Coverage SKIPPED (no tool — bash/markdown plugin)
- [x] Precondition Drift Audit clean (all 4 declared preconditions appear in IMPL/WIRED log)
- [x] mtime audit: log-timeline shows 0/4 Feature steps test-after
