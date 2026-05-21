# TDD Plan: PreToolUse Gate Scope Reduction + Hardening (Review Round 2)

## Context

This round closes 10 code-review findings on `hooks/pre-edit-tdd-reminder.sh`, `hooks/lib/zensu-tdd-phase.sh`, and `evals/tdd-manager-pretool/assertions/assert-no-bypass.sh`.

**Architectural shift**: removing `Bash` from the PreToolUse gate matcher. The gate now claims to cover only Edit/Write/MultiEdit; Bash-based file mutations remain the responsibility of (a) tdd-manager prompt discipline, (b) the PostToolUse code-reviewer chain with mtime audit, (c) the post-hoc `assert-no-shell-redirect-bypass.sh` warning. This is a deliberate scope reduction grounded in the Good-Faith trust model: the agent is drift-prone, not adversarial.

Findings to close:

1. Bash gate is fundamentally bypassable (14 reproducible bypasses). Remove Bash from gate matcher and from `pre-edit-tdd-reminder.sh`. Repurpose `test-pre-edit-bash-bypass.sh` to assert Bash is no-op for the gate.
2. Fail-closed default for missing `CLAUDE_AGENT_TYPE` blocks main-thread edits and the documented `>>` log-append. Combined with #1, change default to **gate-off** for unset/empty `CLAUDE_AGENT_TYPE`.
3. `*tdd-phase-*` substring match denies legitimate read-only ops. Deleted as part of #1.
4. mkdir-fallback mutex has no stale-lock recovery. Add PID + 30s-mtime stale detection + stderr diagnostic. Unit test stale lockdir → succeeds < 100ms.
5. `zensu-log.sh --phase` whitelist had argv-injection leak. Removed as part of #1.
6. Post-hoc bypass assertion shares same lexical blind spots. Rename to `assert-no-shell-redirect-bypass.sh` and document narrow scope. Update test file accordingly.
7. Symlink-reject doesn't cover hard links. Add `stat`-based link-count check. Unit test with `ln`.
8. Inline-header detection: BOM-prefixed test files miss + 200-byte window too small. Strip BOM, raise to 1024 bytes / 20 lines. Unit tests: BOM, banner, binary.
9. `test-pre-edit-allow-refactor.sh` misleading name (5/8 asserts are GREEN_PASS DENY, 3 REFACTOR ALLOW). Split into two files.
10. README stale; missing PreToolUse phase-gate row + `ZENSU_TDD_GATE` env-var entry. Update README + extend `test-readme-coverage.sh`.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash 3.x (macOS), Node.js (JSON parsing), pure-bash unit-test harness | **Coverage**: SKIPPED (offline bash test suite has no coverage tooling — pattern: per-test PASS/FAIL count)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| F4 | Feature | Stale-lock recovery in `tdd_write_phase` mkdir-fallback | `test-pre-edit-concurrent-write.sh` (extend) | — | [G] | 2 |
| F7 | Feature | Hard-link rejection in `tdd_is_test_path` | `test-pre-edit-symlink-reject.sh` (extend) | — | [G] | 1 |
| F8 | Feature | BOM + long-banner + binary handling in inline-header detection | `test-pre-edit-inline-header.sh` (extend) | — | [G] | 1 |
| F1 | Feature | Remove Bash branch from gate; Bash is no-op | `test-pre-edit-bash-bypass.sh` (repurpose) | — | [G] | 1 |
| F2 | Feature | Default to gate-off when CLAUDE_AGENT_TYPE empty | `test-pre-edit-agent-trust.sh` (update) | F1 | [G] (audit: test-after — merged into F1 IMPL) | 1 |
| F9 | Refactor | Split `test-pre-edit-allow-refactor.sh` into two files | new `test-pre-edit-deny-greenpass-production.sh` + existing | — | [RF] | — |
| F6 | Feature | Rename `assert-no-bypass.sh` → `assert-no-shell-redirect-bypass.sh`, add README, update test file | `test-assert-no-shell-redirect-bypass.sh` (rename) | — | [G] (mtime audit false-pos: mv preserves inode mtime; README created post-RED) | 1 |
| F10a | Feature | README documents PreToolUse phase-gate row + ZENSU_TDD_GATE env-var | `test-readme-coverage.sh` (extend) | F1, F2 | [G] | 1 |
| F10b | Feature | CHANGELOG documents scope reduction as nested bullet list | `test-changelog-coverage.sh` (extend) | F1, F2, F4, F6, F7, F8, F9 | [G] | 2 |
| W1 | Integration | Wire `run-eval.sh` to new test names from F6 + F9 + delete F1's stale subcmd test if defunct | — | F6, F9 | [W] | — |

### Step F4 — Stale-lock recovery in `tdd_write_phase`
- [ ] **RED**: Extend `test-pre-edit-concurrent-write.sh`. Create stale lockdir (`mkdir state.lockd`, write non-existent PID `99999` to `state.lockd/owner`, `touch -t 200001010000 state.lockd` to make mtime old). Call `tdd_write_phase` — RED asserts: (a) returns 0 in < 5s, (b) state file written with expected step. Currently `tdd_write_phase` blocks ~2s then fails when state.lockd persists → assert FAIL.
- [ ] **GREEN**: In `_tdd_write_phase mkdir-fallback`, on first mkdir failure: read `${lock_dir}/owner` PID; if PID empty OR `kill -0 PID` fails, OR `${lock_dir}` older than 30s, then `rm -rf "$lock_dir"` + retry. Emit stderr diagnostic when 200 attempts exhausted: `[zensu-tdd-phase] lock acquisition failed for $state_file`. Write `$$` to `${lock_dir}/owner` on successful mkdir.

**Checkpoint**: `bash evals/config-gate/test-pre-edit-concurrent-write.sh` pass.

### Step F7 — Hard-link rejection in `tdd_is_test_path`
- [ ] **RED**: Extend `test-pre-edit-symlink-reject.sh`. Create `real.test.ts` (test file). Create hard link `ln real.test.ts innocent_hardlink.ts`. Assert `tdd_is_test_path innocent_hardlink.ts == false`. Currently returns "true" because inline-header reads through inode → RED.
- [ ] **GREEN**: After `-L` check in `tdd_is_test_path`, add `link_count` probe via `stat -f %l` (BSD) || `stat -c %h` (GNU). If `link_count > 1` → echo false; return 0.

**Checkpoint**: `bash evals/config-gate/test-pre-edit-symlink-reject.sh` pass.

### Step F8 — BOM + long-banner + binary handling
- [ ] **RED**: Extend `test-pre-edit-inline-header.sh`. Three new asserts:
  - (a) BOM-prefixed test file: write `\xef\xbb\xbfdescribe('group', () => {...})`, assert `tdd_is_test_path == true`. Currently FAIL (head reads BOM bytes, grep anchor `^describe` doesn't match `\xef\xbb\xbfdescribe`).
  - (b) Long banner (300+ bytes of `// ----` ASCII art) before `describe(` on line 10, assert `== true`. Currently `head -c 200` cuts off before line 10 → FAIL.
  - (c) Binary file (random bytes, no ASCII test signature) assert `== false`. Must not false-positive after we widen window.
- [ ] **GREEN**: In `tdd_is_test_path` inline-header branch, replace `head -c 200` with `head -n 20`. Strip BOM via `sed '1s/^\xef\xbb\xbf//'`. Pipe through grep as before. Binary noise will not match the regex (no BOL `describe(`/`func Test`/etc.).

**Checkpoint**: `bash evals/config-gate/test-pre-edit-inline-header.sh` pass + symlink test still pass + isolation tests pass.

### Step F1 — Remove Bash branch from gate
- [ ] **RED**: Rewrite `test-pre-edit-bash-bypass.sh` to assert that ALL Bash payloads (the existing 14 bypasses + log-append commands + tdd-phase state writes) are NO-OP (script exits 0, empty stdout). Currently 13 of 14 assert `decision==deny`, so the rewritten test will FAIL until we remove the Bash branch.
- [ ] **GREEN**: 
  - In `hooks/hooks.json`: revert PreToolUse matcher to `Edit|Write|MultiEdit`.
  - In `pre-edit-tdd-reminder.sh`: 
    - remove `Bash` from `case "$TOOL_NAME"`,
    - delete entire `bash_command_is_mutating()` function,
    - delete `BASH_TOOL_COMMAND` parsing,
    - delete `if [ "$TOOL_NAME" = "Bash" ]; then ... ` branch in `decide_allow()`,
    - delete Bash-specific header branch in deny payload.

**Checkpoint**: `bash evals/config-gate/test-pre-edit-bash-bypass.sh` pass + all other pre-edit tests pass + structural `hooks.json` JSON-validity pass.

### Step F2 — Default to gate-off when CLAUDE_AGENT_TYPE empty
- [ ] **RED**: Rewrite `test-pre-edit-agent-trust.sh` second assertion (no env): expect ALLOW instead of DENY for `tool_name=Edit, no CLAUDE_AGENT_TYPE, payload-only subagent_type`. Currently shipped code defaults empty to `zensu:tdd-manager` → DENY. RED.
- [ ] **GREEN**: Change `pre-edit-tdd-reminder.sh` lines 31-34: drop the default-to-tdd-manager fallback. When `AGENT_CONTEXT` is empty → exit 0 (gate off). Keep forged-payload-`subagent_type` assert at PASS (still ALLOW because env is the only source of truth).

**Checkpoint**: `bash evals/config-gate/test-pre-edit-agent-trust.sh` pass + isolation tests pass + RED/IMPL/REFACTOR phases still gate when env IS set to `zensu:tdd-manager`.

### Step F9 — Split `test-pre-edit-allow-refactor.sh` into focused files
- [ ] **GREEN-BEFORE**: Verify existing `test-pre-edit-allow-refactor.sh` passes.
- [ ] **CHANGE**: 
  - Move 5 DENY asserts (GREEN_PASS + production file × 2, RED_RUN deny, GREEN_RUN deny) into new file `test-pre-edit-deny-greenpass-production.sh`.
  - Keep only the 3 REFACTOR-allow asserts in `test-pre-edit-allow-refactor.sh` (and the one GREEN_PASS + test-file allow that demonstrates GREEN_PASS gating distinguishes test-vs-prod — move that to the new deny file since it's a counter-example to the deny rule).
  - Wire new file into `evals/config-gate/run-eval.sh`.
- [ ] **GREEN-AFTER**: Both files pass; total assert count preserved (3 in refactor + 5 in greenpass deny + new file = same coverage).

**Checkpoint**: `bash evals/config-gate/run-eval.sh --self-check` reports +1 test file, all PASS.

### Step F6 — Rename bypass assertion + add README
- [ ] **RED**: Rename test file `evals/tdd-manager-pretool/test-assert-no-bypass.sh` → `test-assert-no-shell-redirect-bypass.sh`. Update it to point to renamed script `assertions/assert-no-shell-redirect-bypass.sh`. Run before rename → FAIL (script not found).
- [ ] **GREEN**: 
  - `git mv` (via Bash) `assertions/assert-no-bypass.sh` → `assertions/assert-no-shell-redirect-bypass.sh`.
  - Add `evals/tdd-manager-pretool/assertions/README.md` documenting (i) what the assertion catches: `>`/`>>`/`sed -i`/`tee`; (ii) what it does NOT catch: `python -c`, `node -e`, `ruby -e`, `perl -e`, `cp`, `mv`, `install`, `rsync`, `awk -i inplace`, `git apply`, `patch`, `dd`. Note: bypass classes are intentionally out of scope since the PreToolUse gate no longer covers Bash; defense relies on agent-prompt + reviewer-chain.
  - Update any references to old script name. Verify no `scenarios/*.yaml` references it (grep already confirmed only CHANGELOG.md + test file reference it).

**Checkpoint**: Renamed test passes; README.md exists.

### Step F10a — README documents phase-gate + ZENSU_TDD_GATE
- [ ] **RED**: Extend `test-readme-coverage.sh` with 3 new asserts: README contains "TDD Phase Gate" string AND "ZENSU_TDD_GATE" string AND "Edit/Write/MultiEdit" string (proves matcher is documented sans Bash). RED before README edits.
- [ ] **GREEN**: 
  - Add Hooks table row: `| TDD Phase Gate | PreToolUse Edit/Write/MultiEdit | Enforces RED→IMPL→GREEN FSM via `.zensu/state/tdd-phase-<sid>.json`. Bypass: `ZENSU_TDD_GATE=off`. |`
  - Add Environment Variables table row: `| ZENSU_TDD_GATE | — | Set to `off` to disable the TDD phase gate for legitimate non-TDD edits |`.

**Checkpoint**: `bash evals/config-gate/test-readme-coverage.sh` pass.

### Step F10b — CHANGELOG documents scope reduction
- [ ] **RED**: Extend `test-changelog-coverage.sh` with new asserts: CHANGELOG contains "Edit/Write/MultiEdit only" string AND "assert-no-shell-redirect-bypass" string AND "stale-lock" string (mentions F4 recovery work). RED before CHANGELOG edits.
- [ ] **GREEN**: 
  - Convert the existing 1200+-word Security paragraph (line 11) into a nested bullet list per Keep-a-Changelog convention.
  - Add new top bullet for the scope reduction documenting all 10 findings closed.

**Checkpoint**: `bash evals/config-gate/test-changelog-coverage.sh` pass.

### Step W1 — Wire `run-eval.sh` to new tests
- [ ] Add `run_test "$EVAL_DIR/test-pre-edit-deny-greenpass-production.sh" "test-pre-edit-deny-greenpass-production.sh"` to `evals/config-gate/run-eval.sh`.
- [ ] (test-pre-edit-log-phase-subcmd.sh stays — it still tests phase markers via the helper, the helper is unchanged.)

## Final Verification

- [x] `bash evals/config-gate/run-eval.sh --self-check` all PASS — **57/57 (0 FAIL)**.
- [x] `bash evals/tdd-review-chain/run-eval.sh --self-check` — **30/31 PASS (1 pre-existing assert-version.sh failure, baseline preserved)**.
- [x] `bash evals/tdd-manager-pretool/test-assert-no-shell-redirect-bypass.sh` — **6/6 PASS**.
- [x] `bash evals/tdd-manager-pretool/run-eval.sh --self-check` — **25/25 PASS** (includes new test-pre-edit-deny-greenpass-production.sh).
- [x] mtime discipline audit per `[G]` step (Phase 6 step 5) — 1/8 feature steps flagged test-after (F2, merged with F1 IMPL); 12.5% < 20% threshold ⇒ Phase 6 PASS. F6 mtime "violation" is mv-preserved-inode false-positive.
- [x] Build verification — `Build: – n/a` (pure-bash plugin, no build manifest at root).
