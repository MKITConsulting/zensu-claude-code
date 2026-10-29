# Execution: the per-step contracts, Phase 4 and Phase 5

Read this before the first Phase 4 cycle. In vanilla mode Phase 4 is replaced as `references/modes.md` states; the contracts and Phase 5 still apply.

### Per-Step Logging Contract (MANDATORY)

For each Feature/Bug-Fix step, the log file MUST contain three entries with these EXACT prefixes:
  1. `{step_id} RED {test_name} — FAIL: {reason}` (after Phase 4 A)
  2. `{step_id} IMPL completed — files: {list}` (after Phase 4 B) — same typing as the `WIRED` form below: `{list}` is a comma-separated list of repo-root-relative paths, and any commentary goes after a ` | ` separator, never inline in the list
  3. `{step_id} GREEN — PASS ({attempts} attempts, {test_count} tests)` (after Phase 4 C)

Integration/`[W]` steps log ONE entry: `{step_id} WIRED — files: {list} | {description}`, where `{list}` is a comma-separated list of paths relative to the REPO ROOT (`git rev-parse --show-toplevel`), not to a nested project dir, and every path the step actually changed appears in it. When the step's contract was to VERIFY an existing wiring rather than change a file, log `{step_id} WIRED (verified, no change) — {file}: {what was verified}` instead, so the Phase 6 Edit Landing Audit can tell a deliberate verification from an edit that never landed.

When you merge multiple Feature steps (per Principle 2), each constituent step keeps its own RED + GREEN entries — only the IMPL entry may be combined. Missing entries are a TDD compliance violation that Phase 6 audit MUST flag.

### Per-Step Task Contract (MANDATORY)

Tasks are not optional decoration — they are the only channel the user watches in real time, so treat them with the same discipline as the log. Each Feature/Bug-Fix step has THREE tasks (`[test]`/`[impl]`/`[verify]`, created in Phase 3); each integration step has ONE (`[wire]`). As you execute a step, flip its tasks `in_progress` → `completed` in lockstep with the cycle phases (RED→[test], IMPL→[impl], GREEN→[verify]). Running a Phase 4 cycle with no corresponding `in_progress` task is a discipline violation of the same class as a missing log entry. If you reach Phase 4 and the step's tasks do not exist, STOP and create them (Phase 3) before editing.

## Phase 4: Execute TDD Cycles

Log `EXECUTION STARTED` before the first step. All log-append commands in this phase use the writer from Principle 3: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" append --log {log_file} --message "<message>" --start $SESSION_EPOCH`. Do not inline `[$(date +%H:%M:%S)]` — the user-configured `logging.timestampStyle` may suppress or reformat the prefix — and do not redirect into `{log_file}` yourself, which skips the path redaction that makes the artifact safe to commit.

### Feature Cycle (per step)

**Self-check**: Previous step done? RED test defined? **Precondition check**: does this step's IMPL plan reference any tool/secret/fixture from the Phase 2 `## Preconditions` table that is marked `missing` with decision `skip`? If yes — mark the step `[!]` in the plan, log `{step_id} BLOCKED — precondition {name} missing`, TaskUpdate `cancelled` for all three sub-tasks, and proceed to the next step. Do NOT substitute, do NOT write a partial test, do NOT commit a placeholder.

**A) RED** — Write the test file. The test MUST assert actual behavior (return values, state changes, side effects), not just function existence. Run it with the test command. Verify it FAILS.
  - **Phase marker (before writing the test)**: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase RED_WRITE --step {step_id}`
  - Write the test file.
  - **Phase marker (before running the test)**: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase RED_RUN --step {step_id}`
  - Run the test.
  - **Verify the failure reason**: Assertion mismatch or missing symbol = CORRECT RED. Syntax error, typo, missing import, wrong file path = WRONG RED → fix the test itself, don't proceed to IMPL.
  - **Phase marker (on confirmed failure)**: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase RED_FAIL --step {step_id} --reason "{reason}"`
  - Log: `{step} RED {test} — FAIL: {assertion or missing-symbol message}`. TaskUpdate [test] completed.
  - If test PASSES: delete it, rewrite to test something that requires the implementation. Log `REJECTED — test GREEN on creation`.

**B) IMPL** — Write the MINIMUM implementation code. Real, complete code for the test to pass — no stubs, no skeletons, no premature generalization. Do NOT run tests yet. Do NOT refactor unrelated code.
  - **Phase marker (before editing production files)**: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase IMPL --step {step_id}` — the PreToolUse gate verifies that step `{step_id}` is in `RED_FAIL` in history; a missing or mismatched marker blocks the Edit/Write call.
  - **Mechanical or bulk replacement — confirm by RE-READING the result, never by the test run.** After any non-surgical edit (`sed` / `perl -pi`, a codemod or migration script, an `Edit` with `replace_all`, a generated rewrite), the confirming evidence is a re-read of the target predicate: `grep -cF -- "$NEW" "$file"` MUST be > 0 and `grep -cF -- "$OLD" "$file"` MUST be 0 (fixed-string, `--`, double-quoted — a replacement pattern routinely carries regex metacharacters). A replacement that matched nothing produces no diff whatsoever — no reviewer sees it, no audit input contains it — and the suite stays green because it was already green before the edit. A green run is evidence that the command ran green, NEVER evidence that the replacement landed. The Phase 6 Edit Landing Audit (step 5b) is the backstop for this, not a substitute for checking it here.
  - Log: `{step} IMPL completed — files: {list}`. TaskUpdate [impl] completed.

**C) GREEN** — Run the TARGET test (single file/name, not the full suite). Verify it PASSES.
  - **Phase marker (before running the test)**: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase GREEN_RUN --step {step_id}`
  - Run the test.
  - **Phase marker (on PASS)**: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase GREEN_PASS --step {step_id}`
  - If PASS: Log `{step} GREEN — PASS ({N} attempts)`. TaskUpdate [verify] completed. Next step.
  - If FAIL: Log `RETRY({N}/3)`. Fix implementation (re-emit `--phase IMPL` per RETRY), back to C. After 3 attempts, standalone mode escalates to the user; delegated mode persists `BLOCK(tdd-retry-limit)`, reports the exhausted step, and stops without asking.
  - Scoped suites run at Phase 5 checkpoints (not per step, and except through the Phase 5 fallback); the full suite runs in the Phase 6 audit — avoids 20× overhead on large codebases.

### Refactoring Cycle

**R1)** Run existing tests for affected code. Verify ALL PASS. If coverage insufficient, write a behavior-preserving test first.
**R2)** Phase marker: `CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" --phase REFACTOR --step {step_id}`. Refactor the code. Do NOT change behavior.
**R3)** Run same tests. Verify ALL still PASS.
Log: `{step} RF — tests GREEN before+after`. Mark `[RF]`.

### Bug Fix Cycle

**B1)** Write test reproducing the bug. Run it. Verify FAIL.
**B2)** Fix the bug.
**B3)** Run test. Verify PASS.
Same logging as Feature cycle.

### Integration Steps

Implement directly (wiring, config, migrations). Log: `{step} WIRED — files: {list} | {description}` per the Per-Step Logging Contract (or the `WIRED (verified, no change) — {file}: …` form when the step verified an existing wiring instead of changing one). Mark `[W]`. Execute after dependent TDD steps are `[G]`.

## Phase 5: Checkpoint

After each logical phase: run `{scoped_test_cmd}` SCOPED to that phase's work — the suites whose own tests target the files it touched, plus any suite that imports or invokes those files (grep the test tree for each changed path) — and `{lint_cmd}`. Log the result, and name the scope in EVERY case so a too-narrow checkpoint is auditable rather than resting on self-assessment: `{step_or_phase} CHECKPOINT — {verdict} | cmd: {command} | scope: {N} suites over {files}` (repo-root-relative paths). Batch-update the plan's Steps-table `Status` column (the single completion tracker). **The FULL suite is NOT run here** unless the fallback in the next paragraph fires; the Phase 6 audit (step 1) runs it over the finished tree either way.

**Run each checkpoint command in the foreground, one tool call at a time** — its own output is the verdict you log, and nothing else records a scoped run. EITHER of two conditions alone fires the fallback, and you run the full suite here as well, through the evidence runner exactly as Phase 6 step 1 does: you cannot bound the phase's blast radius by reading (shared infrastructure, a config or build file), OR the resolved scope comes out EMPTY because no suite covers the touched files — an empty scope must never silently produce no CHECKPOINT line. Log the reason as `| scope: fallback-full — {reason}`, which REPLACES the `{N} suites over {files}` form on that line — one `| scope:` token per line, always. **Why the checkpoint is scoped and the audit is not:** the audit run is the one that must measure the FINISHED tree, and its record is what the chain terminus reads. Measured across this repository's own run logs, 4 of the 9 chains that ran the full suite in BOTH phases had no implementation work logged between the two runs, so the second run re-measured an identical tree at full cost. Scoping narrows WHICH tests run, never WHETHER one runs.
