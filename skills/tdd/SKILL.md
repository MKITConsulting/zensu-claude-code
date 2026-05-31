# /zensu:tdd

Execute a feature specification with strict Red/Green Test-Driven Development **in the main thread**. You write the tests, run them, implement, and verify yourself — the work is NOT delegated to a subagent (that lost too much implementation context). After implementation the auto-review chain runs `zensu:code-reviewer` — the only remaining subagent — and routes its findings back to you to fix in-thread.

## When to Use

- The plan-approval hook (`plan-approved-delegate.sh`) directs you here after the user approves a plan that adds executable code.
- `/zensu:implement` Step 3 hands you a feature specification built from the Zensu feature + security context.
- A user invokes `/zensu:tdd` directly with a feature spec.

Provide a FEATURE SPECIFICATION as the input. Describe WHAT needs to be built, not HOW.

## Main-thread model (read first)

- **You are the implementer.** Run Phases 0–6 below in this conversation. Do NOT spawn a `tdd-manager` subagent — that agent no longer exists.
- **The discipline hooks enforce YOU.** The PreToolUse phase-gate (`pre-edit-tdd-reminder.sh`) and the Bash witness (`post-bash-witness.sh`) activate on a per-session chain-state flag, set by `--tdd-begin` in Phase 0. Until you call `--tdd-begin` they are silent; after it, edits are gated to the declared TDD phase exactly as a subagent would have been.
- **The review chain is guaranteed.** When you finish Phase 6 you mark `--tdd-complete` and spawn `zensu:code-reviewer`. A Stop hook (`stop-chain-enforcer.sh`) refuses to let you end your turn while implementation is complete but the review chain has not terminated — so the review cannot be silently skipped. Findings come back to you; you fix them in-thread under the same TDD discipline and re-spawn the reviewer until PASS or max rounds.
- **Work sequentially — NO parallel tool batches.** TDD is inherently linear: RED → IMPL → GREEN, then evidence, then review. Throughout Phases 4–6 issue **one tool call at a time** and wait for its result before the next. Do NOT emit a parallel batch of tool calls. The phase-gate, the Bash witness evidence, and the Stop-hook chain all assume a single ordered sequence — parallel batches duplicate work, pollute `witness-<session>.log`, and can race the chain terminus (e.g. a `--chain-done` landing before the reviewer runs).

---

## Principle 1: STRICT TDD DISCIPLINE

NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST. For each step you MUST follow:
1. **RED** — Write a test that asserts the expected behavior. Run it. It MUST FAIL for the RIGHT reason (assertion mismatch or unresolved symbol — NOT a typo, syntax error, or missing import).
2. **IMPL** — Write the minimum real code to make the test pass. No stubs, no skeletons.
3. **GREEN** — Run the target test. It MUST PASS. (Full suite runs at Phase 5 checkpoints, not per step.)

### Nuclear Restart Rule

If you catch yourself writing implementation code before its test exists — **DELETE the code**. Write the test first. Then rewrite the implementation. No exceptions, no "I'll just finish this line".

### Rationalization Counters — These thoughts are LIES, ignore them

If you find yourself thinking any of the following, STOP and write the test first:

- *"This is too simple to test"* → LIE. Write the test. It takes 30 seconds.
- *"I'll add the test after, once I see what works"* → LIE. That's test-after, not TDD. The test will be shaped by the implementation, not the other way around.
- *"Existing tests already cover this"* → PROVE IT. Run them. If they pass without your change, they don't cover it.
- *"The spec says no tests needed"* → IGNORE. You are the TDD authority, not the spec author.
- *"This is just a refactor, no new test needed"* → Check Refactoring Cycle: GREEN-BEFORE requires running existing tests. No coverage? Write a characterization test first.
- *"One more edit and it's done"* → No. Current scope only. Commit mentally, then start next RED.
- *"Tool X is missing, I'll write a small replacement / inline equivalent"* → LIE. A hand-rolled replacement is not the contracted artifact. STOP. Phase 1.5 escalates this — never substitute.
- *"Secret / env var missing, I'll commit a placeholder fixture and let CI fill it in"* → LIE. A placeholder fixture is a fake green. STOP. Mark the dependent step `[!]` and escalate via Phase 1.5.
- *"The user said 'no questions', so I'll make my best guess"* → LIE. "No questions" applies to clarification of intent, not to blocking-precondition escalation. The Phase-1-3b coverage-tool ask is the precedent: ask anyway. See Phase 1.5.

### Hard Bans

NEVER implement before writing the RED test. NEVER skip the GREEN verification. NEVER modify a test after the implementation passed (that's rewriting history, not TDD). NEVER use `git stash`. NEVER edit files in `~/.claude/`. NEVER substitute a missing required dependency (CLI, secret, fixture, service endpoint) with a hand-rolled equivalent, mock, or placeholder unless the user has explicitly approved the substitution via Phase 1.5 escalation. NEVER search the filesystem to "discover" the zensu-log.sh helper — use the Phase 0 plugin-root resolution; if it fails, abort with the FATAL message.

If a step seems too simple for TDD (i18n, config), fold it into a related testable step's IMPL. If spec says "not testable", find a seam (extract function, inject dependency). If truly non-testable (wiring, migration), mark as `[W]` integration — but the wiring must still be VERIFIED by running the caller's tests.

## Principle 2: WORK TYPES (per step)

Classify EACH step. A single task may mix types.

**Feature** (default): RED → IMPL → GREEN. Status: `[G]`
**Refactoring** (same behavior): GREEN-BEFORE → CHANGE → GREEN-AFTER. Status: `[RF]`. Verify tests cover the affected code first — if not, write a behavior-preserving test.
**Bug Fix**: RED-REPRO → FIX → GREEN. Status: `[G]`
**Integration** (wiring, config, migrations): Direct implementation, no test cycle. Status: `[W]`

Merge steps ONLY if (a) their test files share setup code that should only be written once, or (b) they are technically inseparable (same class, same method). NEVER as a logging shortcut. Each merged step still requires its own RED log entry with that step's specific failure reason. When merging N steps you log N RED entries + 1 IMPL entry + N GREEN entries.

## Principle 3: THREE-CHANNEL STATUS

After completing each cycle phase (RED, IMPL, GREEN):
1. **Log** — `printf '%s%s\n' "$(bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh timestamp $SESSION_EPOCH)" "..." >> {log_file}` — the helper resolves `~/.zensu/config.json`'s `logging.timestampStyle` to the inline prefix (`wall` default, `relative`, or `none`). Never inline `$()` for the timestamp itself; always call the helper.
2. **Tasks** — TaskUpdate: `in_progress` when starting, `completed` when done
3. **Plan doc** — batch-update at checkpoints and final report only
4. **Phase-marker** (FSM, enforced by PreToolUse gate) — before any Edit/Write/MultiEdit, declare the current TDD phase via:
   `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase <PHASE> --step <step_id> [--reason "..."]`
   Valid `<PHASE>` values: `RED_WRITE`, `RED_RUN`, `RED_FAIL`, `IMPL`, `GREEN_RUN`, `GREEN_PASS`, `REFACTOR`. The marker is written to `.zensu/state/tdd-phase-<session>.json`; the log-line format above is unchanged. The PreToolUse gate (`hooks/pre-edit-tdd-reminder.sh`) blocks edits that don't match the FSM: in particular `IMPL` requires a prior `RED_FAIL` for the same step. The gate is active because Phase 0 set the chain-state `active` flag for this session. Set `ZENSU_TDD_GATE=off` only for legitimate non-TDD edits explicitly authorized by the user.

### Per-Step Logging Contract (MANDATORY)

For each Feature/Bug-Fix step, the log file MUST contain three entries with these EXACT prefixes:
  1. `{step_id} RED {test_name} — FAIL: {reason}` (after Phase 4 A)
  2. `{step_id} IMPL completed — files: {file_list}` (after Phase 4 B)
  3. `{step_id} GREEN — PASS ({attempts} attempts, {test_count} tests)` (after Phase 4 C)

Integration/`[W]` steps log ONE entry: `{step_id} WIRED — {description}`.

When you merge multiple Feature steps (per Principle 2), each constituent step keeps its own RED + GREEN entries — only the IMPL entry may be combined. Missing entries are a TDD compliance violation that Phase 6 audit MUST flag.

---

## Phase 0: Pre-flight

1. **Resolve plugin root once.** Run `bash -c 'cat "$HOME/.zensu/plugin-root"'` via the Bash tool and store its trimmed output (no trailing newline) as `{PLUGIN_ROOT}` for the entire session. Use `{PLUGIN_ROOT}` in ALL subsequent helper invocations: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh …`. If the command exits non-zero or the output is empty, abort with: `FATAL: plugin root unresolvable — run a fresh session to trigger SessionStart hook AND ensure hooks.pulseSession is not set to false in ~/.zensu/config.json`. **Never search the filesystem** for the helper; the SessionStart hook (`hooks/session-start-pulse.sh`) is the single source of truth for the plugin-root path.
2. Run `date +%Y-%m-%d-%H%M` → store as `{SESSION_TS}` for all filenames. Additionally capture `SESSION_EPOCH=$(date +%s)` and keep it for the entire TDD session — the log helper consumes it for `relative` timestamp style.
3. **Activate the TDD session.** Run `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --tdd-begin`. This sets the per-session chain-state `active` flag, which turns on the PreToolUse phase-gate and the Bash witness for THIS main-thread session (they were silent until now). Without this call, your edits are NOT gated and the witness records nothing — so do it before any test/production edit.
4. **Load the task-tracking tools.** In the main thread `TaskCreate`/`TaskUpdate` are deferred — their schemas are NOT preloaded (the deleted subagent got them for free via its `tools:` frontmatter; a main-thread skill does not). Before the first `TaskCreate`, load them: call `ToolSearch` with query `select:TaskCreate,TaskUpdate`. If your harness already exposes them, this is a harmless no-op.
5. Create the first task with `TaskCreate(subject: "TDD: Analyzing spec and creating plan", description: "Parse the feature spec and produce the TDD plan", activeForm: "Analyzing specification")`, then set it `in_progress` with `TaskUpdate`. **Contract:** `TaskCreate` requires BOTH `subject` and `description` (a one-liner is fine) and accepts an optional `activeForm`; it has NO `status` field (new tasks are always `pending`) and NO `blockedBy` — set status via `TaskUpdate(status: ...)` and dependencies via `TaskUpdate(addBlockedBy: [...])`.

---

## Phase 1: Discover the Project

1. Read all CLAUDE.md files in project hierarchy
2. Discover tech stack and test frameworks
3. Extract test commands (full suite, single file, type check, lint). Distinguish **test runners** (assertions, can RED/GREEN) from **static checks** (type checkers, linters). TDD requires a test runner — if none exists, add a `[W]` step to install one first.
3b. Detect coverage tooling and threshold (MUST read config files, not just probe deps):
   - Step 1 — locate coverage config file(s):
     - Node: vitest config (`vitest.config.{ts,js,mjs}` or `vite.config.{ts,js,mjs}`), jest config (`jest.config.*` or `jest` key in package.json), `.nycrc*`
     - Python: `pyproject.toml`, `.coveragerc`, `setup.cfg`
     - Go: built-in `go test -cover` (no config file)
     - Rust: `Cargo.toml` for tarpaulin/llvm-cov metadata
   - Step 2 — READ each located config file (Read tool, not just `ls`). Extract numeric thresholds:
     - vitest: `test.coverage.thresholds.{lines,branches,functions,statements}`
     - jest: `coverageThreshold.global.{lines,branches,functions,statements}`
     - c8/nyc: `lines`, `branches`, `functions`, `statements`
     - pytest: `[tool.coverage.report] fail_under`
   - Step 3 — verify tool is INSTALLED (in devDeps or available on PATH). Record `{coverage_cmd}` capable of per-file output (e.g. `npm run coverage`, `npx vitest run --coverage`).
   - Step 4 — threshold resolution:
     - Numeric thresholds extracted from config → use those values verbatim. Set `{threshold_source}=project-config`.
     - No thresholds in config (even if tool installed) → default 90% lines. Set `{threshold_source}=default-90%`.
   - If a test runner exists but NO coverage tool installed → use AskUserQuestion to ask whether to install one (recommend matching tool: vitest→@vitest/coverage-v8, jest→built-in, pytest→pytest-cov). On accept: add a `[W]` step in the Phase 2 plan for install. On decline: set `{coverage_cmd}=null`, mark coverage SKIPPED in Phase 6.
4. Read 1-2 sample test files for patterns
5. Scan `.zensu/plans/*_tdd-*.md` for patterns
6. Parse spec into atomic steps, classify work type per step. Non-testable work folded into related IMPL.
7. Build dependency graph: `depends_on: [step_ids]`. Independent steps (different files, no type deps) can run sequentially without blocking.
8. Compile context: root path, tech stack, test commands, coverage_cmd, coverage_thresholds, threshold_source, rules, test utilities

---

## Phase 1.5: Spec Precondition Discovery

Generalizes the Phase 1 step 3b coverage-tool pattern to every external dependency the spec names.

1. From the parsed spec (Phase 1 step 6), extract every:
   - **External CLI/tool** named by name (e.g. `promptfoo`, `docker`, `terraform`, `ffmpeg`)
   - **Secret or env var** referenced (e.g. `OPENAI_API_KEY`, `AWS_SECRET_ACCESS_KEY`)
   - **Service endpoint** required at runtime (e.g. live LLM API, database, external HTTP service)
   - **Input fixture or asset** the spec assumes exists on disk (e.g. baseline JSON, recorded responses)
2. For each precondition, run the matching verification:
   - CLI: `command -v X >/dev/null 2>&1`
   - Env var: `[ -n "${VAR:-}" ]`
   - Endpoint: `curl -fsS --max-time 5 {url}` (only if the spec implies live use; otherwise skip)
   - Fixture: `[ -f {path} ]` or `[ -d {path} ]`
   Record `{precondition_name}`, `{verification_cmd}`, `{result: present|missing}`.
3. For every `missing` precondition: use AskUserQuestion to present three options — **(a) install/provide it now, (b) approve a named substitution** (the user names the substitute, agent does not propose one), or **(c) mark the dependent steps `[!]` and skip**. Record the user's answer verbatim in the plan's `## Preconditions` section (Phase 2).
4. **AskUserQuestion override**: if an earlier user instruction said "no questions" or similar terseness preference, that instruction is OVERRIDDEN here. Blocking-precondition escalation always asks. This mirrors the Phase 1 step 3b coverage-tool ask, which is also unconditional.
5. If the user picks (a) install: pause and wait for the user to install/provide the precondition. After the user confirms completion, re-run the verification command from step 2. If still missing, ask again (loop back to step 3). The workflow does NOT proactively run install commands (e.g. `npm install`, `brew install`) unless the user has explicitly authorized the specific install command in the same exchange.
6. If the user picks (b) substitution: the substitution MUST be named by the user, not proposed by the agent. Re-run the matching verification on the user-named substitute. If the substitute is also missing, ask again.
7. If the user picks (c) skip: every spec step that names the missing precondition gets `[!]` in Phase 2. Do not silently re-route the step's IMPL to a different tool.

---

## Phase 2: Create Plan + Log

MANDATORY — create BOTH files (plan + log are a pair).

> **Gate note (read before writing):** Phase 0's `--tdd-begin` armed the phase-gate, but you have NOT declared a TDD phase yet, so `phase = UNINITIALIZED` and the Edit/Write/MultiEdit tools are DENIED here. The plan and log are documentation artifacts — write BOTH via **Bash** (heredoc / `printf`), which is intentionally NOT gated. Do NOT use the Write/Edit tool for them (it will be blocked). And never use Bash to write *production code* to bypass the gate — production source goes through Edit/Write under a declared phase in Phase 4; Bash is only for these `.zensu/` docs.

1. Create the plan file via a Bash heredoc: `mkdir -p .zensu/plans && cat > .zensu/plans/{SESSION_TS}_tdd-{slug}.md <<'EOF'` … `EOF`, with this content:

```markdown
# TDD Plan: {Feature Title}

## Context
{Spec verbatim}
**Approach**: Strict Red/Green TDD | **Tech Stack**: {stack} | **Coverage**: {coverage_cmd or "SKIPPED"} @ {threshold} ({threshold_source})

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| {name} | CLI/secret/endpoint/fixture | `{verify_cmd}` | present/missing | install / substitute=`{user-named}` / skip |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|

### Step {id} — {Description}
- [ ] **RED**: Test `{name}` — {what}, {why fails}
- [ ] **GREEN**: {what to implement}

**Checkpoint**: {test_cmd} + {lint_cmd} pass

## Final Verification
- [ ] All test suites pass
- [ ] Coverage report generated for changed files (threshold: {threshold})
```

2. `mkdir -p .zensu/logs && printf '%s%s\n' "$(bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh timestamp $SESSION_EPOCH)" "TDD STARTED — {title} | steps: {N}" > .zensu/logs/{SESSION_TS}_tdd-{slug}.log`
3. Tell user: `tail -f .zensu/logs/{SESSION_TS}_tdd-{slug}.log`

---

## Phase 3: Create ALL Tasks

Create tasks for ALL steps BEFORE starting execution. This is the user's progress dashboard.

Per TDD step — 3 tasks:
- `{step_id} [test]` (activeForm: "Creating RED test for {step_id}")
- `{step_id} [impl]` (activeForm: "Implementing {step_id}")
- `{step_id} [verify]` (activeForm: "Verifying {step_id}")

Per integration step — 1 task:
- `{step_id} [wire]` (activeForm: "Wiring {step_id}")

Create each via `TaskCreate` with `subject` (the `{step_id} [test]` label), a one-line `description`, and the `activeForm` shown above. Set dependencies with `TaskUpdate(addBlockedBy: [...])` per the dependency graph (not on `TaskCreate`). Mark the Phase 0 "Analyzing" task `completed` with `TaskUpdate`.

---

## Phase 4: Execute TDD Cycles

Log `EXECUTION STARTED` before the first step. All log-append commands in this phase use the helper-prefix pattern from Principle 3: `printf '%s%s\n' "$(bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh timestamp $SESSION_EPOCH)" "<message>" >> {log_file}`. Do not inline `[$(date +%H:%M:%S)]` — the user-configured `logging.timestampStyle` may suppress or reformat the prefix.

### Feature Cycle (per step)

**Self-check**: Previous step done? RED test defined? **Precondition check**: does this step's IMPL plan reference any tool/secret/fixture from the Phase 2 `## Preconditions` table that is marked `missing` with decision `skip`? If yes — mark the step `[!]` in the plan, log `{step_id} BLOCKED — precondition {name} missing`, TaskUpdate `cancelled` for all three sub-tasks, and proceed to the next step. Do NOT substitute, do NOT write a partial test, do NOT commit a placeholder.

**A) RED** — Write the test file. The test MUST assert actual behavior (return values, state changes, side effects), not just function existence. Run it with the test command. Verify it FAILS.
  - **Phase marker (before writing the test)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_WRITE --step {step_id}`
  - Write the test file.
  - **Phase marker (before running the test)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_RUN --step {step_id}`
  - Run the test.
  - **Verify the failure reason**: Assertion mismatch or missing symbol = CORRECT RED. Syntax error, typo, missing import, wrong file path = WRONG RED → fix the test itself, don't proceed to IMPL.
  - **Phase marker (on confirmed failure)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase RED_FAIL --step {step_id} --reason "{reason}"`
  - Log: `{step} RED {test} — FAIL: {assertion or missing-symbol message}`. TaskUpdate [test] completed.
  - If test PASSES: delete it, rewrite to test something that requires the implementation. Log `REJECTED — test GREEN on creation`.

**B) IMPL** — Write the MINIMUM implementation code. Real, complete code for the test to pass — no stubs, no skeletons, no premature generalization. Do NOT run tests yet. Do NOT refactor unrelated code.
  - **Phase marker (before editing production files)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase IMPL --step {step_id}` — the PreToolUse gate verifies that step `{step_id}` is in `RED_FAIL` in history; a missing or mismatched marker blocks the Edit/Write call.
  - Log: `{step} IMPL completed — files: {list}`. TaskUpdate [impl] completed.

**C) GREEN** — Run the TARGET test (single file/name, not the full suite). Verify it PASSES.
  - **Phase marker (before running the test)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase GREEN_RUN --step {step_id}`
  - Run the test.
  - **Phase marker (on PASS)**: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase GREEN_PASS --step {step_id}`
  - If PASS: Log `{step} GREEN — PASS ({N} attempts)`. TaskUpdate [verify] completed. Next step.
  - If FAIL: Log `RETRY({N}/3)`. Fix implementation (re-emit `--phase IMPL` per RETRY), back to C. Max 3 attempts → escalate to user.
  - Full suite runs only at Phase 5 checkpoints (not per step) — avoids 20× overhead on large codebases.

### Refactoring Cycle

**R1)** Run existing tests for affected code. Verify ALL PASS. If coverage insufficient, write a behavior-preserving test first.
**R2)** Phase marker: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --phase REFACTOR --step {step_id}`. Refactor the code. Do NOT change behavior.
**R3)** Run same tests. Verify ALL still PASS.
Log: `{step} RF — tests GREEN before+after`. Mark `[RF]`.

### Bug Fix Cycle

**B1)** Write test reproducing the bug. Run it. Verify FAIL.
**B2)** Fix the bug.
**B3)** Run test. Verify PASS.
Same logging as Feature cycle.

### Integration Steps

Implement directly (wiring, config, migrations). Log: `{step} WIRED`. Mark `[W]`. Execute after dependent TDD steps are `[G]`.

---

## Phase 5: Checkpoint

After each logical phase: run full test suite + linter. Log result. Batch-update plan document statuses.

**Run every test / lint / build / coverage command in the FOREGROUND and one at a time — never `run_in_background`, never two at once.** The witness cross-check needs the real exit code; a backgrounded run records `exit=?` in `witness-<session>.log` and breaks the Phase 6 cross-check, while concurrent runs duplicate the suite and leave orphaned shells. Run the full suite once here (checkpoint) and once in Phase 6 (audit) plus the scoped coverage run — serially, not in parallel.

**MANDATORY** — every test/lint/build invocation logged from Phase 5 onward MUST use the structured-evidence schema so the witness log can cross-check the claim. For each run, append a line of the form:

```
{step_or_phase} CHECKPOINT — cmd="<exact bash command>" exit=<rc> result="<short verdict>"
```

The `cmd="..."` field MUST be the literal command string that was sent to the Bash tool — the witness hook (`hooks/post-bash-witness.sh`) records the same string verbatim, and Phase 6 step 1 will grep for `cmd="<X>"` in the witness log to verify the claim. Mismatched or paraphrased commands break the cross-check. The witness log lives at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<session>.log` and is written automatically by the PostToolUse Bash hook while this TDD session's chain-state `active` flag is set (Phase 0). Set `ZENSU_TEST_WITNESS=off` only when the user has authorized disabling the witness layer for a legitimate non-eval session.

---

## Phase 6: Audit & Final Report

1. Run full test suites + linters.
   - **MANDATORY structured-evidence form** — every test/lint/build run in Phase 6 MUST also be logged as `AUDIT — cmd="<exact bash command>" exit=<rc> result="<short verdict>"`. After all AUDIT entries are written, perform the **witness cross-check**: for each `cmd="X"` claim, run `grep -F -q 'cmd="X"' "${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/witness-<session>.log"`. If no match, append `EVIDENCE GAP — cmd="X" claimed but not in witness log` to the run log AND mark Phase 6 NOT complete (surface prominently in the final report).
   - **Non-Bash escape clause** — if a test was invoked via a non-Bash tool (rare; e.g. custom MCP test runner), declare in the AUDIT entry as `via=tool_name claim="..."` instead of `cmd="..."`. Audit treats `via=` entries as known-limitation (no witness cross-check possible) and surfaces them prominently in the final report.
2. **Build Verification.** Tests can be green while the artifact is broken (compile errors only the build catches, env vars frozen at build-time, broken imports the test harness shims out). Verify the project actually builds.
   - Determine the build command by reading the project's metadata: `README.md`, `CLAUDE.md`, `package.json` (`scripts.build`), `pom.xml`, `Cargo.toml`, `Makefile`, `go.mod`, `pyproject.toml`, etc. Pick the canonical command the docs name as "build".
   - Decide applicability. If the TDD spec is genuinely non-buildable (docs-only migration, pure data fixture, etc.) AND the project metadata confirms no build step is wired, record `Build: – n/a` with the reason and proceed to step 3.
   - If the project IS buildable, run the build. Capture exit code and the last ~30 lines of output.
   - **Build passed** (exit 0, no critical warnings): record `Build: ✓ passed`. Proceed to step 3.
   - **Build failed**: DO NOT mark Phase 6 complete. Treat the failure as a new requirement and return to Phase 2 to amend the plan with a new `[W]` integration step that fixes the build, then create a task for it (Phase 3 mechanics) and re-run Phase 4-6 after the fix. The Phase 6 "done" claim is only valid when the build is green.
   - If the build can't run for ambient reasons (dependencies not installed, network down, unknown toolchain), record `Build: – skipped (reason)` and continue — do not block the audit on environment problems the developer must resolve. Surface the skip prominently in the final report so the developer notices.
3. Coverage report (changed files only):
   - If `{coverage_cmd}` is null → log `COVERAGE SKIPPED — no tool` and skip to step 4.
   - Else:
     a) Collect list of files modified during session from `IMPL`/`WIRED` log entries (Phase 4 Cycle B logs `files: {list}`).
     b) Run coverage on full test suite, restricting report scope to changed files via the tool's include filter:
        - vitest: `--coverage --coverage.include={file1} --coverage.include={file2}`
        - jest: `--coverage --collectCoverageFrom={file}`
        - c8/nyc: `--include={file}`
        - pytest-cov: `--cov={module}`
        - go: `go test -coverprofile=cover.out ./... && go tool cover -func=cover.out` (filter manually)
     c) Parse per-file metrics: lines %, branches %, functions %.
     d) Compare each file against `{threshold}`.
     e) Build Coverage section for the final report (markdown table):

        ```
        ## Coverage (changed files)
        | File | Lines | Branches | Funcs | vs {threshold} |
        |------|-------|----------|-------|----------------|
        | ...  | ...   | ...      | ...   | PASS / FAIL    |

        Summary: {N}/{M} files PASS @ {threshold}
        Threshold source: {threshold_source}
        ```

   - If ≥1 file FAIL: log `COVERAGE BELOW THRESHOLD on {N} files: {file_list}` and ask user (in their language) whether to run an additional TDD cycle for uncovered branches. Do NOT auto-loop (avoids scope explosion).
4. Read plan and implementation files. Verify every step's description matches the actual code. For `[W]` steps, verify wired code is actually USED (not dead imports). If gaps → fix through another TDD cycle → re-verify.
5. **mtime Discipline Audit**. For every Feature step marked `[G]`:
   - Resolve the IMPL file list from the `{step_id} IMPL completed — files: {list}` log entry.
   - Resolve the test file from the step's `{step_id} RED {test_name}` log entry.
   - Capture mtimes: `test_mtime=$(stat -f %m {test_file})` (Linux: `stat -c %Y {test_file}`); `impl_min_mtime=$(stat -f %m {impl_files} | sort -n | head -1)`.
   - If `test_mtime > impl_min_mtime`: the step was Test-After. Mark the plan step `[!]` and append `DISCIPLINE VIOLATION: test-after detected ({test_file} mtime > {impl_file} mtime)` to the log.
   - Aggregate: if > 20% of Feature steps carry `[!]`, the final log line MUST read `TDD DISCIPLINE VIOLATED — {N}/{M} steps test-after, audit FAIL` and Phase 6 is NOT complete. Surface this prominently in the final user-facing report so the developer notices.
6. **Precondition Drift Audit**. Detect silent substitution.
   a) Read the `## Preconditions` table from the plan. Collect the names of every CLI/tool listed (column 1 of rows where Type=CLI).
   b) For each such CLI name `X` where the Decision was `install` or substitute=`{name}`: search the log file for any invocation of `X` (or the named substitute) in IMPL/WIRED entries using fixed-string word matching: `grep -F -w "$X" {log_file} || grep -F -w "$substitute" {log_file}`. If a CLI name contains regex metacharacters (`.+*?[]()|\`), DO NOT use `grep -E` with interpolation — always prefer `grep -F -w` for CLI-name searches.
   c) **Drift conditions**:
      - Decision was `install` but `X` never appears in an IMPL/WIRED log entry → DRIFT (silent skip).
      - Decision was `skip` but `X` appears in an IMPL/WIRED log entry → DRIFT (silent inclusion against user decision).
      - Decision was substitute=`Y` but neither `X` nor `Y` appears → DRIFT (neither contracted tool ran).
   d) If any drift: append `PRECONDITION DRIFT — {tool}: decision={d}, actual={observed}` to the log, mark Phase 6 NOT complete, and surface prominently in the final report. Do NOT auto-fix — drift is a discipline violation, same severity as mtime discipline failure (existing step 5).
7. Update plan: all steps `[G]`, `[W]`, or `[!]`. No `[ ]`/`[R]`/`[I]` remaining.
8. Log: `TDD COMPLETE — {N}/{M} GREEN | Integration: {N} WIRED | Build: {✓ passed | – n/a | – skipped} | Coverage: {N}/{M} files >= {threshold}` (omit Coverage segment if SKIPPED).
9. Output summary, in this order: (a) `## TL;DR` — exactly ONE sentence following the template `{component} {symptom} because {root_cause} — fixed via {mechanism}[, {N} TDD round(s)], {pass}/{total} tests green.` Cover root cause + fix mechanism + test verdict; no fluff, no hedging. Then (b) results, files modified, test counts, verification status, **Build status from step 2**, **Coverage table from step 3e**, **Test Evidence section** (every CHECKPOINT/AUDIT `cmd="..."` claim with its witness cross-check verdict — `verified` when matched in witness log, `EVIDENCE GAP` when missing, `via=tool_name` when declared non-Bash escape), plan path.
10. **Close implementation and trigger the review chain.** This replaces the old subagent auto-review hook — the chain is now driven from this main thread. Execute these steps STRICTLY ONE AT A TIME (single tool call per step, wait for each result), never as a parallel batch and never bundled with the Phase 6 audit writes above:
    1. Mark implementation complete: `bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --tdd-complete`. This arms the Stop-hook backstop (`stop-chain-enforcer.sh`): you will NOT be allowed to end your turn until the review chain terminates.
    2. Enumerate changed files: `git diff --name-only HEAD`.
    3. Spawn the reviewer: the Agent tool with `subagent_type='zensu:code-reviewer'`, passing a one-paragraph summary of what you implemented PLUS the changed-file list from step 2. Do NOT ask the user about review — spawning the reviewer IS the autonomous action.
    - **`--chain-done` is EXCLUSIVELY the chain-terminus marker.** Run it ONLY when (a) implementation produced ZERO file changes (every step blocked `[!]`) — then run it INSTEAD of spawning the reviewer and stop; or (b) the reviewer returned PASS / suggestions-only. **NEVER** issue `--chain-done` in the same turn or batch as `--tdd-complete`, the reviewer spawn, a plan write, or the audit — landing it early releases the Stop gate before review and silently defeats the guarantee.
    - The `post-review-tdd-delegate.sh` hook routes the reviewer's findings back to you. On Critical/Important findings: fix them in THIS thread under the same TDD discipline (re-enter Phase 4 cycles — the gate is still active), then spawn `zensu:code-reviewer` again to re-verify. On PASS / suggestions-only: run `--chain-done`, render the CHAIN-END SUMMARY, and stop. The loop ends at PASS or `autoFixMaxRounds`.
