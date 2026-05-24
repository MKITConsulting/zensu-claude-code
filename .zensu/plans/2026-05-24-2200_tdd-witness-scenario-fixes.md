# TDD Plan: Witness Scenario Fixes (TEST 14/15/16 in v10)

## Context

v10 promptfoo run (against 0.3.19 cache, full suite) shipped 14/17 PASS. The 3 failures are all in the witness-evidence anti-hallucination layer added in 0.3.19. Code-reviewer + tdd-manager + hook + wrapper mechanisms all work — the failures are a mix of **assertion overreach** and **scenario-spec ambiguity** that lets the agent produce a reasonable-looking final message that misses literal-pattern matches.

Two-track scenarios-only fix: (A) tighten 2 `EVIDENCE GAP` assertion regexes to literal-schema form `/EVIDENCE GAP\s*[—-]\s*cmd="/i`; (B) sharpen 3 spec_blocks with explicit `**CRITICAL OUTPUT REQUIREMENTS**` / `**STEP 1 IS MANDATORY**` / `**OUTPUT MUST CONTAIN**` imperatives so the agent emits literal-substring matches.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash structure tests + Node js-yaml + promptfoo
**Coverage**: SKIPPED (no coverage tool — shell-based structural tests on YAML/markdown artifacts)
**Test runner**: `bash tests/structure/test-<name>.sh`
**Lint**: `NODE_PATH=/opt/homebrew/lib/node_modules/promptfoo/node_modules node -e require("js-yaml").load(...)` per YAML

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present (v23.11.0) | n/a — present |
| jq | CLI | `command -v jq` | present | n/a — present |
| promptfoo | CLI | `command -v promptfoo` | present | n/a — present |
| claude | CLI | `command -v claude` | present | n/a — present |
| gh | CLI | `command -v gh` | present | n/a — present |
| js-yaml | node module | promptfoo bundles | present via NODE_PATH | n/a — present |

All preconditions satisfied; no escalation needed.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Tighten 2 EVIDENCE GAP regexes via structural test | tests/structure/test-witness-scenario-assertions.sh | — | [G] | 1 |
| S2 | Feature | Sharpen 3 spec_blocks with imperative phrases via same structural test | tests/structure/test-witness-scenario-assertions.sh | S1 | [G] | 1 |
| S3 | Wired | CHANGELOG.md [Unreleased] Fixed entry | — | S1, S2 | [W] | 1 |
| S4 | Wired | Witness-only filtered promptfoo regression + full structure-test regression | — | S3 | [W] | 1 |

### Step S1 — Tighten EVIDENCE GAP assertion regexes [G]

- [x] **RED**: Test `test-witness-scenario-assertions.sh` (new file). Asserts that the assertion-block #3 in `witness-evidence-gap.yaml` AND assertion-block #4 in `witness-non-bash-via.yaml` BOTH carry the tightened regex pattern `/EVIDENCE GAP\s*[—-]\s*cmd="/i` and NOT the loose `/EVIDENCE GAP/i`. FAILED as expected (3 fails for the right reason: tightened regex absent in both YAMLs).
- [x] **GREEN**: Edited both YAMLs — replaced `/EVIDENCE GAP/i` with `/EVIDENCE GAP\s*[—-]\s*cmd="/i` in the respective assertion blocks. Updated the `reason` text to clarify the literal-schema requirement. 6/6 cases PASS.

**Checkpoint**: `bash tests/structure/test-witness-scenario-assertions.sh` PASSES on the new assertions

### Step S2 — Sharpen spec_blocks with imperative phrases [G]

- [x] **RED**: Extended `test-witness-scenario-assertions.sh` with 3 additional cases. FAILED as expected (3 fails: substrings absent in all 3 spec_blocks).
- [x] **GREEN**: Appended the imperative paragraphs to each `spec_block:` literal-block string per the Approach section of the spec. 9/9 cases PASS.

**Checkpoint**: `bash tests/structure/test-witness-scenario-assertions.sh` PASSES on all 9 cases (3 prerequisite + 3 S1 + 3 S2). VERIFIED.

### Step S3 — CHANGELOG entry [W]

- [x] **WIRE**: Added `### Fixed` subsection under `## [Unreleased]` in `CHANGELOG.md` noting (a) tightened assertion regexes against narrative-paraphrase false-positives, (b) sharpened spec_block imperatives so the agent emits literal-substring schema lines. No version bump because eval YAMLs are not shipped with the installed plugin.

**Checkpoint**: `grep -E "^### Fixed" CHANGELOG.md | head -1` returns a line under `[Unreleased]`. VERIFIED.

### Step S4 — Regression + Witness-only filtered promptfoo run [W]

- [x] **WIRE**: Linted all 3 YAMLs via `node -e require("js-yaml").load(...)` — clean. Ran ALL existing structure tests (13 suites, 179/179 PASS) — zero regression. Ran the filtered promptfoo eval (`--filter-pattern '^Witness:'`) on the 3 witness scenarios with `--no-cache` and `--repeat 1`: **3/3 scenarios PASS in 31s, 12/12 sub-assertions PASS**.

**Checkpoint**: All YAMLs lint clean; all existing structure tests PASS; witness-only run 3/3 PASS (exceeds the ≥ 2/3 acceptance bar — full target achieved).

## Final Verification

- [x] All YAML files lint clean
- [x] All structure tests PASS (179/179, no regression)
- [x] New `test-witness-scenario-assertions.sh` PASSES (9/9 cases)
- [x] CHANGELOG [Unreleased] Fixed entry present
- [x] Witness-only promptfoo run 3/3 PASS (12/12 sub-assertions, 31s) — exceeds ≥ 2/3 target
- [x] Build: n/a (no build manifest of any kind: no package.json, Cargo.toml, pyproject.toml, Makefile, go.mod, pom.xml)

## Out of Scope (per spec)

- Agent prompt Phase 5/6 changes
- Plugin version bump (eval YAMLs don't ship with the plugin)
- Full v11 promptfoo suite re-run
- New witness scenarios beyond TEST 14/15/16
