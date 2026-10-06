# Planning: Phases 1 to 3

Read this when Phase 0 is done. It ends with every step's tasks created, before the first Phase 4 cycle.

## Phase 1: Discover the Project

1. Read all CLAUDE.md files in project hierarchy
2. Discover tech stack and test frameworks
3. Extract test commands and NAME them, because the plan template and Phases 5-6 refer to them by name: `{full_test_cmd}` (the whole suite), `{scoped_test_cmd}` (the runner's selector form, the one that accepts a path or pattern), `{lint_cmd}`. Distinguish **test runners** (assertions, can RED/GREEN) from **static checks** (type checkers, linters) — the type checker is named nowhere below, so it needs no placeholder. TDD requires a test runner — if none exists, add a `[W]` step to install one first. Run these commands, and every other project command this skill prescribes (the Phase 4 test runs, the build, `{coverage_cmd}` and the step 5 `stat`), as `cd "{project_root}" && <command>`: the Bash tool returns to the session's start directory, which after `/zensu:adopt-session --reanchor` is not `{project_root}`. `--evidence-run` needs no prefix: it runs in `{project_root}` whenever the working directory is outside that work tree.
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
   - If a test runner exists but NO coverage tool is installed, standalone mode uses AskUserQuestion to ask whether to install one (recommend matching tool: vitest→@vitest/coverage-v8, jest→built-in, pytest→pytest-cov). On accept: add a `[W]` step in the Phase 2 plan for install. On decline: set `{coverage_cmd}=null`, mark coverage SKIPPED in Phase 6. Delegated mode instead persists `BLOCK(coverage-tool-decision-required)`, reports it, and stops without asking.
4. Read 1-2 sample test files for patterns
5. Scan `"{project_root}"/.zensu/plans/*_tdd-*.md` for patterns
6. Parse spec into atomic steps, classify work type per step. Non-testable work folded into related IMPL. **Cross-layer detection (Principle 2):** for each Feature/Bug-Fix step, trace the call graph from changed code to the persistence/transport boundary. If the path crosses unchanged code that consumes a NEW value/field/payload-key/query-param, add a paired Characterization step (`[G]`, Feature work type) in that unchanged layer. The originating step's `depends_on` MUST list the characterization step. Record the pairing in the Phase 2 plan's `## Cross-Layer Value Flow Pairings` table.
7. Build dependency graph: `depends_on: [step_ids]`. Independent steps (different files, no type deps) can run sequentially without blocking.
8. Compile context: root path, tech stack, test commands, coverage_cmd, coverage_thresholds, threshold_source, rules, test utilities

## Phase 1.5: Spec Precondition Discovery

Generalizes the Phase 1 step 3b coverage-tool pattern to every external dependency the spec names.

1. From the parsed spec (Phase 1 step 6), extract every:
   - **External CLI/tool** named by name (e.g. `promptfoo`, `docker`, `terraform`, `ffmpeg`)
   - **Secret or env var** referenced (e.g. `OPENAI_API_KEY`, `AWS_SECRET_ACCESS_KEY`)
   - **Service endpoint** required at runtime (e.g. live LLM API, database, external HTTP service)
   - **Input fixture or asset** the spec assumes exists on disk (e.g. baseline JSON, recorded responses)
   - **Acceptance driver** each `AC-###` needs, judged as the ability to boot and drive, never as a state only the build produces: a runtime recipe or `--attach` origin plus `playwright-cli` for `browser`, an installed simulator or emulator for `mobile`, a start command for `api` or `cli` (the driver names of `skills/autopilot/rules/drivers.md`). Phase 6 step 6d verifies EVERY active criterion on the finished tree, so a driver that cannot run leaves its criterion `partial` and blocks the chain's close. An Autopilot-bound chain skips this item, as it skips step 6d
2. For each precondition, run the matching verification:
   - Acceptance driver: `command -v playwright-cli`, `xcrun simctl list devices available` or `emulator -list-avds`, or the recipe file or start command the driver needs
   - CLI: `command -v X >/dev/null 2>&1`
   - Env var: `[ -n "${VAR:-}" ]`
   - Endpoint: `curl -fsS --max-time 5 {url}` (only if the spec implies live use; otherwise skip)
   - Fixture: `[ -f {path} ]` or `[ -d {path} ]`
   Record `{precondition_name}`, `{verification_cmd}`, `{result: present|missing}`.
3. In delegated mode, any `missing` precondition persists `BLOCK(precondition-decision-required)` with the precondition named in the report, then stops without asking or substituting.
4. In standalone mode, for every `missing` precondition use AskUserQuestion to present three options — **(a) install/provide it now, (b) approve a named substitution** (the user names the substitute, agent does not propose one), or **(c) mark the dependent steps `[!]` and skip**. Record the user's answer verbatim in the plan's `## Preconditions` section (Phase 2).
5. **Standalone AskUserQuestion override**: if an earlier user instruction said "no questions" or a similar terseness preference, standalone blocking-precondition escalation always asks. This mirrors the standalone Phase 1 step 3b coverage-tool ask.
6. In standalone mode, if the user picks (a) install, pause and wait for the user to install/provide the precondition. After confirmation, re-run the verification command from step 2. If it is still missing, ask again (loop back to step 4). The workflow does NOT proactively run install commands (e.g. `npm install`, `brew install`) unless the user explicitly authorized the specific install command in the same exchange.
7. In standalone mode, if the user picks (b) substitution, the substitution MUST be named by the user, not proposed by the agent. Re-run the matching verification on the user-named substitute. If the substitute is also missing, ask again.
8. In standalone mode, if the user picks (c) skip, every spec step that names the missing precondition gets `[!]` in Phase 2. Do not silently re-route the step's IMPL to a different tool.

## Phase 2: Create Plan + Log

MANDATORY — create BOTH files (plan + log are a pair).

> **Gate note (read before writing):** Phase 0's `--tdd-begin` armed the phase-gate. Paths under `.zensu/` (the plan + log artifacts) are exempt from the gate, so write the **plan** with the **Write tool** — its full body must NOT go through Bash, where a heredoc would carry the entire plan as one command string. The **log** is an append-only trace: write and grow it with the **`append` verb** (Principle 3), never the Write tool (which would overwrite it) and never a hand-rolled `printf >>` (which skips the path redaction). Never use Bash to write *production code* to bypass the gate — production source goes through Edit/Write under a declared phase in Phase 4. **Both artifacts are written to be COMMITTED, so author them accordingly.** Consuming repos keep `.zensu/plans/` and `.zensu/logs/` as an audit trail and may later open-source the repository. Two rules follow, and they are not style preferences: (a) **English only** — every line of the plan and the log, whatever language this conversation is in; (b) **no absolute paths, no personal data** — refer to files by their repo-root-relative path. The `append` verb and `hooks/post-artifact-redact.sh` rewrite the paths they can recognize (`<project>`, `~`, `<home>`), but that is a textual net under a habit, not a substitute for one: nothing rewrites a customer name, an internal hostname, or a German sentence.

1. **Resolve the plan template** (repo override wins): use `$(git -C "{project_root}" rev-parse --show-toplevel)/.zensu/templates/tdd-plan.md` when that file exists, else the plugin default `{plugin_root}/templates/tdd-plan.md`. Read the resolved template, fill every `{curly}` placeholder from the Phase 1 context, and create the plan file with the **Write tool** at `{plan_file}` — the cwd-independent spelling defined in Principle 3, so the path this step WRITES and the path Phase 6 step 10.1 passes to `--tdd-complete --plan` are one spelling (the `.zensu/` path bypasses the phase-gate). A repo override replaces the default wholesale but MUST keep the mandatory sections (`## Requirements` with ID/Covers, `## Preconditions`, `## Cross-Layer Value Flow Pairings`, Status Legend, Steps table with Status+Covers, `## Final Verification`) — the Phase 5/6 audits and `/zensu:converge` anchor on them.
1b. **Requirement-ID allocation rule (stable IDs, never recycled).** The `## Requirements` table is MANDATORY, and it is now MACHINE-ENFORCED: Phase 6 step 10.1's `--tdd-complete` refuses a chain whose plan carries no `## Requirements` section, or whose rows are all still the template's `{curly}` placeholders — `/zensu:converge` anchors on that table, so a plan without one makes the flow-back audit report nothing while closing clean. Check your own plan any time with `bash "{plugin_root}/hooks/lib/zensu-plan-requirements.sh" --plan {plan_file}` (exit 0 usable, 3 no section, 4 placeholders only). Assign `AC-###` to each acceptance criterion and `FR-###` to each functional requirement parsed from the spec. **If the incoming spec already carries AC-###/FR-### IDs (e.g. from `/zensu:autopilot`), adopt them verbatim — never re-allocate; allocate new IDs monotonically above the highest ID seen.** IDs are allocated monotonically and are NEVER reused — a dropped requirement keeps its ID and is marked deprecated in the Requirement column, spelled `(deprecated) <text>` because that is the marker step 6d and the acceptance gate read; never delete a row or renumber. Every Steps-table row names the IDs it implements in its `Covers` cell (the step detail repeats them on a `- **Covers**:` line), so spec → plan → step → test stays traceable end to end. Phase 6 step 6c cross-checks this mapping at warning level.
2. `mkdir -p "{project_root}/.zensu/logs" && CLAUDE_PROJECT_DIR="{project_root}" CLAUDE_PLUGIN_DATA="{plugin_data}" bash "{plugin_root}/hooks/lib/zensu-log.sh" append --truncate --log {log_file} --message "TDD STARTED — {title} | steps: {N}" --start $SESSION_EPOCH`
3. Tell user: `tail -f {log_file}`

## Phase 3: Create ALL Tasks

Create tasks for ALL steps BEFORE starting execution — **MANDATORY**. This is the user's live progress dashboard and the one channel they watch in real time. Do NOT enter Phase 4 until every step has its tasks.

Per TDD step — 3 tasks:
- `{step_id} [test]` (activeForm: "Creating RED test for {step_id}")
- `{step_id} [impl]` (activeForm: "Implementing {step_id}")
- `{step_id} [verify]` (activeForm: "Verifying {step_id}")

Per integration step — 1 task:
- `{step_id} [wire]` (activeForm: "Wiring {step_id}")

Create each via `TaskCreate` with `subject` (the `{step_id} [test]` label), a one-line `description`, and the `activeForm` shown above. Set dependencies with `TaskUpdate(addBlockedBy: [...])` per the dependency graph (not on `TaskCreate`). Mark the Phase 0 "Analyzing" task `completed` with `TaskUpdate`.
