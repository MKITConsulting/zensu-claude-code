# TDD Plan: PreToolUse Phase-Gate for tdd-manager + Promptfoo Test-Suite

## Context

PreToolUse-Phase-Gate that blocks Edit/Write/MultiEdit calls when the tdd-manager subagent has not declared a valid TDD phase, preventing IMPL-before-RED drift in-the-moment instead of after-the-fact via the post-review hook. Sprach-agnostisch: the agent self-marks its phase via `zensu-log.sh --phase`. State persisted at `.zensu/state/tdd-phase-<session_id>.json`. Override via env `ZENSU_TDD_GATE=off`.

Hard backward-compatibility requirement — the existing log-format (`{step_id} RED|IMPL|GREEN ...`) is unchanged; the phase markers go to a SEPARATE state file. All existing eval suites must remain green.

**Approach**: Strict Red/Green TDD per Principle 1. Promptfoo scenarios + monorepo fixture authored as static artifacts (real-Claude execution gated on local promptfoo install — not run in this session per the spec's "promptfoo install unknown" risk note).
**Tech Stack**: Bash 5.x, Node.js (config parsing), jq (hook payload parsing) | promptfoo (out-of-band)
**Test Command**: `bash evals/config-gate/run-eval.sh --self-check`
**Single-script test**: `bash evals/config-gate/test-pre-edit-<name>.sh`
**Coverage**: SKIPPED (pure shell, no coverage tool installed — matches `tdd-review-chain` plan precedent)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | `zensu-tdd-phase.sh` lib — `tdd_state_file`, `tdd_is_test_path` | `test-pre-edit-lib-paths.sh` | — | [G] | 2 |
| S2 | Feature | `zensu-tdd-phase.sh` lib — `tdd_write_phase`, `tdd_phase`, `tdd_step`, `tdd_has_red_fail` (state read/write FSM) | `test-pre-edit-lib-state.sh` | S1 | [G] | 1 |
| S3 | Feature | `pre-edit-tdd-reminder.sh` — non-tdd-manager passthrough (isolation) | `test-pre-edit-isolation.sh` | S1 | [G] | 1 |
| S4 | Feature | `pre-edit-tdd-reminder.sh` — UNINITIALIZED blocks edit on production file | `test-pre-edit-deny-uninitialized.sh` | S2, S3 | [G] | 1 |
| S5 | Feature | `pre-edit-tdd-reminder.sh` — RED_WRITE allows edit on test file | `test-pre-edit-allow-red-write.sh` | S4 | [G] | 1 |
| S6 | Feature | `pre-edit-tdd-reminder.sh` — RED_FAIL only allows test files, blocks production | `test-pre-edit-allow-redfail-test-only.sh` | S4 | [G] | 1 |
| S7 | Feature | `pre-edit-tdd-reminder.sh` — IMPL after RED_FAIL allows production edit; IMPL without RED_FAIL blocks | `test-pre-edit-allow-impl-after-redfail.sh` | S4 | [G] | 1 |
| S8 | Feature | `pre-edit-tdd-reminder.sh` — GREEN_PASS and REFACTOR allow edits | `test-pre-edit-allow-refactor.sh` | S4 | [G] | 1 |
| S9 | Feature | `pre-edit-tdd-reminder.sh` — `ZENSU_TDD_GATE=off` override bypasses gate | `test-pre-edit-override-env.sh` | S4 | [G] | 1 |
| S10 | Feature | `zensu-log.sh --phase` subcommand writes state file | `test-pre-edit-log-phase-subcmd.sh` | S2 | [G] | 1 |
| S11 | W | Register PreToolUse hook entry in `hooks/hooks.json` | (structural in run-eval) | S3–S9 | [W] | 0 |
| S12 | W | Append Phase-transition guidance to `agents/tdd-manager.md` (additive, log-format unchanged) | (structural) | S10 | [W] | 0 |
| S13 | W | Wire new tests into `evals/config-gate/run-eval.sh` | (structural) | S3–S10 | [W] | 0 |
| S14 | W | Create `evals/tdd-manager-pretool/` directory with promptfooconfig + scenarios + monorepo fixture (static artifacts, not executed in this session) | — | S11, S12 | [W] | 0 |

### Step S1 — Library: path detection
- [ ] **RED**: Test `tdd_is_test_path` returns "true" for paths matching `*test*`, `*spec*`, `*__tests__*`, basename `test_*`/`*_test.*`/`*.test.*`/`*.spec.*`/`*Test.*`/`*Spec.*`, and inline-test-header detection (`func Test`, `describe(`, `#[test]`, `@Test`, `def test_`). Returns "false" for production files (e.g. `src/foo.ts`). Tests `tdd_state_file <sid>` returns expected path under `.zensu/state/`. Fails because lib doesn't exist.
- [ ] **IMPL**: Create `hooks/lib/zensu-tdd-phase.sh` with `tdd_state_file`, `tdd_is_test_path`. Path detection uses case-insensitive substring + extension + first-100-bytes header read.
- [ ] **GREEN**: Run `bash test-pre-edit-lib-paths.sh` — exit 0.

### Step S2 — Library: state read/write
- [ ] **RED**: Test `tdd_write_phase` creates a JSON file with `phase`, `step_id`, `session_id`, and `history` array. Test `tdd_phase`, `tdd_step` read back the latest values. Test `tdd_has_red_fail <state> <step>` returns "true" iff the history for that step contains a `RED_FAIL` entry. Fails — functions not defined.
- [ ] **IMPL**: Add `tdd_write_phase`, `tdd_phase`, `tdd_step`, `tdd_has_red_fail` to `hooks/lib/zensu-tdd-phase.sh`. Atomic write via `mktemp` + `mv`. Parsing via `node -e` for robustness (existing pattern).
- [ ] **GREEN**: Run `bash test-pre-edit-lib-state.sh` — exit 0.

### Step S3 — Hook: passthrough for non-tdd-manager agents
- [ ] **RED**: Test feeding a payload with `tool_input.subagent_type=zensu:code-reviewer` (or any agent ≠ `zensu:tdd-manager`) to `pre-edit-tdd-reminder.sh` produces empty stdout, exit 0. Same for `CLAUDE_AGENT_TYPE=zensu:zensu-plm`. Fails — hook script doesn't exist.
- [ ] **IMPL**: Create `hooks/pre-edit-tdd-reminder.sh`. Read payload, parse `tool_name` (only `Edit|Write|MultiEdit`), check agent context (`CLAUDE_AGENT_TYPE` env first, then `tool_input.subagent_type`), exit 0 silently for any non-`zensu:tdd-manager` context.
- [ ] **GREEN**: Run `bash test-pre-edit-isolation.sh` — exit 0.

### Step S4 — Hook: UNINITIALIZED denies production edit
- [ ] **RED**: Test that when no state file exists for the given session AND tool is `Edit` AND agent is `zensu:tdd-manager` AND file_path is `src/foo.ts` (not test), the hook outputs JSON with `hookSpecificOutput.permissionDecision="deny"` and the reason mentions `UNINITIALIZED` and `RED_WRITE`. Fails because hook either passes through or emits nothing yet.
- [ ] **IMPL**: Add state lookup + `decide_allow` logic in `pre-edit-tdd-reminder.sh`. UNINITIALIZED + non-test → emit deny JSON.
- [ ] **GREEN**: Run `bash test-pre-edit-deny-uninitialized.sh` — exit 0.

### Step S5 — Hook: RED_WRITE allows test file edit
- [ ] **RED**: Seed state file with `{phase:"RED_WRITE",step_id:"S1",...}`. Feed payload with `file_path` matching a test path. Expect empty stdout (allowed) + exit 0. Fails because the hook currently emits deny for any phase or has no logic.
- [ ] **IMPL**: In `decide_allow`, `RED_WRITE → allow`.
- [ ] **GREEN**: Run `bash test-pre-edit-allow-red-write.sh` — exit 0.

### Step S6 — Hook: RED_FAIL — test files only
- [ ] **RED**: Two sub-tests:
  - Seed `phase:"RED_FAIL"`, file_path=test → allow.
  - Seed `phase:"RED_FAIL"`, file_path=production → deny with reason mentioning RED_FAIL + test-only.
- [ ] **IMPL**: In `decide_allow`, `RED_FAIL → allow only if IS_TEST_PATH`.
- [ ] **GREEN**: Run `bash test-pre-edit-allow-redfail-test-only.sh` — exit 0.

### Step S7 — Hook: IMPL phase requires RED_FAIL in history
- [ ] **RED**: Three sub-tests:
  - State `{phase:"IMPL",step_id:"S3",history:[{step:"S3",phase:"RED_FAIL"}]}`, file_path=production → allow.
  - State `{phase:"IMPL",step_id:"S4",history:[{step:"S3",phase:"RED_FAIL"}]}` (RED_FAIL exists but for OTHER step), file_path=production → deny.
  - State `{phase:"IMPL",step_id:"S3",history:[{step:"S3",phase:"RED_WRITE"}]}` (no RED_FAIL for current step), file_path=production → deny.
- [ ] **IMPL**: In `decide_allow`, `IMPL → allow only if tdd_has_red_fail(state, step)`.
- [ ] **GREEN**: Run `bash test-pre-edit-allow-impl-after-redfail.sh` — exit 0.

### Step S8 — Hook: GREEN_PASS + REFACTOR allow edits
- [ ] **RED**: Two sub-tests:
  - State `{phase:"GREEN_PASS"}`, file_path=any → allow.
  - State `{phase:"REFACTOR"}`, file_path=any → allow.
- [ ] **IMPL**: In `decide_allow`, add `GREEN_PASS|REFACTOR → allow`.
- [ ] **GREEN**: Run `bash test-pre-edit-allow-refactor.sh` — exit 0.

### Step S9 — Hook: ZENSU_TDD_GATE=off bypass
- [ ] **RED**: With `ZENSU_TDD_GATE=off`, even UNINITIALIZED state + production file_path → empty stdout, exit 0. Fails because hook currently emits deny.
- [ ] **IMPL**: Add `[ "${ZENSU_TDD_GATE:-}" = "off" ] && exit 0` early in `pre-edit-tdd-reminder.sh`.
- [ ] **GREEN**: Run `bash test-pre-edit-override-env.sh` — exit 0.

### Step S10 — zensu-log.sh `--phase` subcommand
- [ ] **RED**: `bash hooks/lib/zensu-log.sh --phase RED_WRITE --step S1 --session sid123` writes a JSON state file at `.zensu/state/tdd-phase-sid123.json` with the expected schema. With `--reason "..."` for RED_FAIL the reason is recorded in history. Fails because the subcommand returns "unknown command".
- [ ] **IMPL**: Extend `hooks/lib/zensu-log.sh` with `--phase`/`--step`/`--session`/`--reason` argv parsing that sources `zensu-tdd-phase.sh` and calls `tdd_write_phase`. Existing `timestamp`/`style` subcommands unchanged (verified by run-eval after this step).
- [ ] **GREEN**: Run `bash test-pre-edit-log-phase-subcmd.sh` — exit 0.

### Step S11 — Wire PreToolUse hook into `hooks/hooks.json`
- [W] Append PreToolUse block: `matcher: "Edit|Write|MultiEdit"` → `${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-tdd-reminder.sh`. Existing PostToolUse and SessionStart entries unchanged. Verified by `run-eval.sh --self-check`'s `hooks.json is valid JSON` check + a new grep-style assertion in the new run-eval orchestrator.

### Step S12 — Add Phase-transition guidance to `agents/tdd-manager.md`
- [W] Additive text edit. Phase 4A/4B/4C/Refactor each gain a "Set phase: bash ... zensu-log.sh --phase ..." instruction. Existing log-output format (`{step_id} RED ...` etc.) preserved zeichenidentisch. The mtime audit + Per-Step contract are not touched.

### Step S13 — Register new tests in `evals/config-gate/run-eval.sh`
- [W] Append a "Pre-Edit TDD-Gate offline tests" section listing the new `test-pre-edit-*.sh` files. Existing sections untouched. Verified by running the suite — count rises by N where N = number of new tests.

### Step S14 — Static artifacts for promptfoo suite
- [W] Create `evals/tdd-manager-pretool/` with: `README.md` (gating note), `run-eval.sh` (orchestrator skeleton that runs the pre-existing eval suites + tries `promptfoo` if available), `promptfooconfig-pretool.yaml`, 10 `scenarios/*.yaml`, monorepo fixture under `test-projects/react-go-fullstack/`, assertion stubs. NOT executed in this session — promptfoo install is out-of-scope per spec's known-risk note.

**Checkpoint**: After S1–S10, run `bash evals/config-gate/run-eval.sh --self-check` and `bash evals/tdd-review-chain/run-eval.sh --self-check` — both green. After S11–S14, same suites + new orchestrator (self-check level) — all green.

## Final Verification
- [x] `bash evals/config-gate/run-eval.sh --self-check` exits 0 — **48/48 PASS** (was 38/38; +10 new pre-edit tests)
- [x] `bash evals/tdd-review-chain/run-eval.sh --self-check` — 30/31 PASS (1 pre-existing `assert-version.sh` FAIL, unrelated to this work)
- [x] `hooks.json` is valid JSON and contains the new PreToolUse block (matcher `Edit|Write|MultiEdit`)
- [x] `agents/tdd-manager.md` retains the verbatim Per-Step Logging Contract lines (`{step_id} RED ...`, `{step_id} IMPL completed — files: ...`, `{step_id} GREEN — PASS ...`) — confirmed zeichenidentisch
- [x] New `evals/tdd-manager-pretool/run-eval.sh --self-check` — **16/16 PASS**
- [ ] `.zensu/plans/` and `.zensu/logs/` for this session staged + committed (handled by parent agent / user)
