# Plugin Guardrails E2E Test Harness

End-to-end tests for the anti-loop guardrails in `agents/code-reviewer.md` and
the main-thread `skills/tdd/SKILL.md` review chain. Fires the reviewer against fixture git-repos and
asserts the expected guardrail signals appear in its output.

## What it tests

| Fixture | Asserts |
|---------|---------|
| `clean-pr` | Reviewer produces a verdict and a build-verification section on a green PR |
| `stale-branch` | Drift warning ("Branch is N commits behind") appears when feature is behind main |
| `build-fails` | Reviewer runs `tsc` (deps pre-installed in fixture) and flags `Build Verification: ✗ failed` — guardrail must actually fire, no Verdict-fallback |
| `false-test-claim` | Reviewer reproduces tests and flags `Test count mismatch` against a fake `tdd-claim.txt` |
| `docs-only` | Reviewer correctly skips build-verification with reason instead of failing |

## Layout

```
tests/e2e/
├── run.sh                       # Test runner (this script)
├── setup-fixtures.sh            # Idempotent fixture-repo creator
├── test-runner.sh               # Unit tests for run.sh itself
├── README.md                    # This file
├── fixtures/                    # Created by setup-fixtures.sh, gitignored
│   ├── clean-pr/
│   ├── stale-branch/
│   ├── build-fails/
│   ├── false-test-claim/
│   └── docs-only/
├── expected/                    # Pattern files (one per fixture)
│   ├── clean-pr.pattern
│   ├── stale-branch.pattern
│   ├── build-fails.pattern
│   ├── false-test-claim.pattern
│   └── docs-only.pattern
└── results/                     # Run artifacts, gitignored
    └── report-<timestamp>.txt
```

## Run

```bash
# Setup fixtures (idempotent, ~1 second)
bash tests/e2e/setup-fixtures.sh

# Self-check unit tests for the runner itself (no claude spawn, ~2 seconds)
bash tests/e2e/test-runner.sh

# Run the full harness against all 5 fixtures (~5 claude --print invocations, several minutes)
bash tests/e2e/run.sh

# Offline mode — reuse the newest `results/<fixture>-<timestamp>.captured.txt` produced by a previous live run
bash tests/e2e/run.sh --offline

# Self-check — skip fixtures entirely, just validate runner structure
bash tests/e2e/run.sh --self-check
```

Only `--self-check`, `--offline`, an empty arg, or `full` are accepted modes.
Anything else (e.g. typos like `--bogus`) exits with code `2` and an `unknown mode`
error message — preventing accidental live-API spend on misspelled flags.

## Requires

- `bash` (POSIX-compatible shell)
- `git` 2.28+ (for `init -b main`)
- `npm` (for the `build-fails` fixture's hermetic TypeScript install; `setup-fixtures.sh` prints a WARNING and skips the install if `npm` is missing — the fixture is then non-hermetic and the build-verification guardrail cannot be exercised)
- `claude` CLI on `$PATH` (for full runs only — not needed for `--self-check` or `--offline`)

## Pattern File Conventions

One pattern file per fixture in `expected/<fixture-name>.pattern`. Each
non-blank line is treated as a regex — all lines must match somewhere in the
reviewer's captured output for the fixture to PASS. Lines that start with
`# ` (hash followed by a space) are harness-side comments and are skipped;
lines that start with `##` are NOT comments — they match Markdown headers
such as `## Build Verification:` in the reviewer's report.

Patterns should target **signal substrings**, not exact phrasing. LLM output
varies in wording; the assertion should survive paraphrasing. Examples:

```
# Good: tolerant of "is 3 commits behind" / "is one commit behind" / "Branch is N commits behind"
[Bb]ranch is [0-9]+ commits? behind

# Bad: brittle, breaks on capitalization or punctuation variation
Branch is 3 commits behind origin/main.
```

## Adding a new fixture

1. Add a `make_<name>()` function to `setup-fixtures.sh`. Use `git_init` for
   the deterministic baseline setup. Create the `main` branch first, then
   `git checkout -b feature` for the PR state.
2. Call your `make_<name>()` from `main()` at the bottom of `setup-fixtures.sh`.
3. Write `expected/<name>.pattern` with the regex(es) you expect to see in the
   reviewer's output.
4. Run `bash tests/e2e/setup-fixtures.sh` to materialize the fixture and check
   the topology with `git -C tests/e2e/fixtures/<name> log --all --oneline`.
5. Smoke the pattern matcher against a stub `.captured` file under
   `--offline` mode before paying for a full run.

## Known caveats

- **LLM non-determinism**. The reviewer's exact phrasing varies between runs.
  Patterns must use tolerant regexes.
- **API cost**. A full `run.sh` triggers ~5 `claude --print` invocations.
  Budget for several minutes and a non-trivial API spend per run.
- **No CI yet**. This harness is local-only as of this iteration. Wire to CI
  only after the fixtures and patterns prove stable across 3-5 manual runs.
- **`stale-branch` topology**. The drift fixture uses a self-referential remote
  (`git remote add origin .`) so `git fetch origin main` works in a hermetic
  test without internet. A real reviewer run against a real remote would behave
  the same way — only the source of `origin/main` differs.
- **`build-fails` hermeticity**. `setup-fixtures.sh` runs `npm install` inside
  this fixture so `./node_modules/.bin/tsc` exists and the build-verification
  guardrail can actually fire. The install adds ~23 MB of `node_modules/` and
  takes ~1 s. The fixture writes its own `.gitignore` for `node_modules/` to
  keep the fixture's own git history clean. TypeScript version is pinned to
  exact (`5.6.3`) for determinism. If `npm` is missing, the fixture falls back
  to non-hermetic mode with a WARNING — the build-verification guardrail can
  then no longer be asserted strictly and `expected/build-fails.pattern` will
  FAIL until a hermetic capture is produced.
- **Patterns are lower-bound**. A passing pattern proves the guardrail *fired*.
  It does not prove the guardrail's output was correct in every detail.
  Treat the harness as a regression smoke, not a correctness oracle.

## Cleanup

`tests/e2e/fixtures/` and `tests/e2e/results/` are gitignored. Re-running
`setup-fixtures.sh` is destructive — it removes each fixture directory before
recreating it, so manual edits inside `fixtures/` are not preserved.
