# tests/ — zensu plugin test suites

Two flavors:

- **Deterministic** — execute hooks/libs with crafted input and assert real state
  (exit code, emitted JSON, FSM/state files, witness logs). No API, fast, the
  primary "proof" that a hook does what it claims.
- **Live LLM** — drive real `claude --print` against the locally-loaded plugin and
  match the response with tolerant regex. Costs API credits; opt-in.

## Master runner

```bash
bash tests/run-all.sh              # deterministic only (no API)
bash tests/run-all.sh --self-check # deterministic + live-suite skeletons (no API)
bash tests/run-all.sh --live       # deterministic + live claude --print suites (API)
```

Exit 0 iff every selected suite passes. A timestamped report lands in `tests/results/`.

## Windows contract profiles

The versioned manifest at `tests/profiles/windows-ci.v1.json` divides the
Windows-specific deterministic contracts into four bounded profiles:

```bash
node tests/run-profile.js --validate
node tests/run-profile.js windows-reset-session
node tests/run-profile.js windows-leases-routing
node tests/run-profile.js windows-native-state
node tests/run-profile.js windows-installed-core
```

The runner validates the complete manifest and its audited command catalog
before starting any child process, binds every suite to its validated content
digest, streams suite output, and enforces both per-suite and 30-minute
per-profile deadlines. Every suite runs below a supervisor that remains alive
until the complete process tree has been terminated, including after a normal
suite exit. Child processes receive a disposable home/temp tree and a strict
operational environment allowlist; credentials, auth homes, interpreter preload
variables, and live/API modes are unavailable.

CI writes the atomic report below the private runner temp directory. A manual
run creates a random private report directory and prints its absolute path at
the end.

During the observation phase, CI runs all four profiles as non-blocking Windows
matrix jobs and uploads their provenance-bound timing reports. The existing full
Windows job continues to run as the parity baseline. A non-blocking summary job
downloads exactly those four reports plus the same-run legacy outcome, validates
SHA/run-attempt consistency plus the exact ordered suite inventory and complete
execution-contract digest, and publishes one aggregate JSON. That digest binds
the manifest, command catalog, runner, supervisor, Windows Job Object helper,
summarizer, complete CI workflow configuration, and every referenced suite file.
The Ubuntu deterministic and Promptfoo contracts are unchanged.

Cutover to blocking Windows shards requires all of the following:

- at least 14 days and 10 representative pull-request or `main` runs;
- 100% pass/fail parity between every shard run and the legacy Windows job;
- no missing suite, timeout, or incomplete timing report.

“Representative” means ten distinct Git revisions and run identities spanning
both pull-request and `main` push events, not reruns of one SHA. Before cutover,
collect the aggregate JSON artifacts into a schema-v2 ledger and run:

```bash
node tests/summarize-windows-observation.js audit-ledger /path/to/ledger.json
```

The command fails closed unless all quantitative criteria above are met.

After that evidence exists, a separate cutover change can make the four shards
blocking, expose the stable aggregate check name
`Deterministic suite (windows-latest)`, and move the full Windows suite to a
separate scheduled, read-only Windows safety workflow. Release and Session
Control Nightly remain on their existing Linux-only paid gates.

## Suites

| Path | Kind | Covers |
|---|---|---|
| `tests/structure/test-*.sh` | deterministic | hooks, libs, skill/agent wiring, version sync, witness, stop-enforcer, plan-approved, session-start, FSM gate |
| `evals/config-gate/run-eval.sh` | deterministic | pre-edit TDD gate matrix, auto-fix rounds/suggestions routing, config resolution, log-style (~60 offline tests) |
| `evals/verify-feature/run-eval.sh` | advisory live Promptfoo | `/zensu:verify-feature` local proof and remote URL-policy boundary; requires a disposable host and is intentionally excluded from `tests/run-all.sh --live` |
| `tests/e2e/` | live | `code-reviewer` agent anti-loop guardrails |
| `tests/e2e-plm/` | live | `zensu-plm` agent workflow + MCP tool sequencing |
| `tests/e2e-skills/` | live | `zensu-help` · `plan-review` · `self-review` skills + `review-aspect` agent |
| `tests/e2e-tdd/` | live | full `/zensu:tdd` cycle (RED→GREEN→review→self-review→done), real `node --test` |
| `tests/e2e-context-nudge/` | live | `user-prompt-context-nudge.sh` parsing a real `claude --print` session transcript (read→occupancy→threshold→`/compact` proposal) |
| `tests/structure/test-tdd-full-cycle.sh` | deterministic | the same full cycle driven through the hooks (no API) |

## Running individual suites

```bash
# Deterministic (no API)
for t in tests/structure/test-*.sh; do bash "$t"; done
bash evals/config-gate/run-eval.sh --self-check

# Live (API; build fixtures first where present)
bash tests/e2e/setup-fixtures.sh        && bash tests/e2e/run.sh
bash tests/e2e-plm/setup-fixtures.sh    && bash tests/e2e-plm/run.sh
bash tests/e2e-skills/setup-fixtures.sh && bash tests/e2e-skills/run.sh
# Re-match the newest captures without re-spending: append --offline
# Validate skeleton without spawning claude:           append --self-check

# Advisory Promptfoo eval; it has no --offline/--self-check mode and grants unrestricted host access.
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 evals/verify-feature/run-eval.sh
```

## Conventions

- Deterministic tests use a `check()` helper, print `PASS`/`FAIL` per assert, end with
  `<name>: N PASS / M FAIL`, and exit non-zero on any failure.
- Live pattern files (`expected/<name>.pattern`): positive regex per line, `!`-prefix =
  negative assert, `# ` = comment. Tolerant by design (LLM output is non-deterministic).
- Generated fixtures (`*/fixtures/`) and captures (`*/results/`, `tests/results/`) are
  git-ignored; build them with each suite's `setup-fixtures.sh`.
- Deterministic suites run in CI. Live/API suites remain explicitly opt-in.

## Live-suite notes

- **Output-style hermeticity:** the live runners prepend a *normal-mode* directive so a
  user's personal output-style plugin (e.g. `caveman`) cannot compress the section
  headings / tool names the patterns assert. Override the wording via
  `ZENSU_E2E_NORMAL_PREAMBLE`.
- **MCP auth (`e2e-plm`):** patterns are lower-bound — they assert the agent *names* the
  Zensu MCP tools it would call, which normal-mode output does even when the hosted
  `mcp.zensu.dev` server is unauthenticated. Real tool *execution* needs `ZENSU_API_KEY`
  (a headless `claude --print` cannot complete the OAuth browser flow).

## Known follow-up

The promptfoo/expect harnesses under `evals/tdd-manager/`, `evals/tdd-manager-pretool/`,
and `evals/tdd-review-chain/` still target the pre-0.4.0 `zensu:tdd-manager` subagent
(removed when TDD moved to the main thread). They are not part of the deterministic
suite or `run-all.sh`; rewriting them to the main-thread `/zensu:tdd` model is pending.
