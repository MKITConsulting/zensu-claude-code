---
paths:
  - ".github/workflows/live-evals.yml"
  - ".github/scripts/live-evals.sh"
  - ".github/scripts/live-evals-ledger.js"
  - ".github/scripts/live-evals-install-claude-code.sh"
  - "scripts/eval-usage-ledger.js"
  - "scripts/claude-promptfoo-wrapper.sh"
  - "evals/zen-mode-reaction/provider.sh"
  - "tests/structure/test-live-evals.sh"
  - "tests/structure/test-promptfoo-local-only.sh"
---

# Live Evals (`.github/workflows/live-evals.yml` + `.github/scripts/live-evals.sh`)

**What it is.** An advisory nightly, at 03:17 UTC and on manual dispatch, that runs
`zen-mode-reaction` and `context-nudge-reaction` through the pinned Promptfoo against the newest
Claude Code release. It never gates a pull request or a release, and it is the one workflow that
runs Promptfoo or a model. The step contract and the owner's setup live in `tests/README.md`
§"Scheduled live evals".

**Newest release, no lockfile.** The canary installer asks `npm view` for the newest
`@anthropic-ai/claude-code` on every run, because the workflow exists to catch a break in a Claude
Code release the night after it ships, and a lockfile would hide it. The install discipline stands
in for the lockfile: `npm install --ignore-scripts`, Claude Code as the only package with an install
script, every non-root lock entry resolved from
`https://registry.npmjs.org/@anthropic-ai/claude-code`, then its own `install.cjs` and the
`--version` check, all before any package code runs. Only a `claude` symlink goes on `PATH`. H11 in
`test-session-hub-plugin.sh` pins this order and the single caller by substring
(`.claude/rules/session-hub-companion.md`), so rewording one of those literals fails H11.

**Two ledger scripts, split by who ships them.** `scripts/eval-usage-ledger.js` ships in the plugin
tree because the wrapper appends to it: it knows only `append` and exports the shared parser
(`SCHEMA`, `LIMIT_TEXT`, `SUITE_NAME`, `count`, `readEvents`, `digest`). The CI-only
`.github/scripts/live-evals-ledger.js` holds `probe`, `tally`, `summarize`, `results` and `stage`.
A verb added to the plugin's copy ships to every user.

**Run classification.** `probe` starts a run: it drops the ledger, notice and suite table an
earlier run left. Each suite is judged by the ledger bytes appended during its own Promptfoo run
(`tally` from a byte offset) and by its own results file, which the run deletes before Promptfoo
starts. An assertion that failed on an answer without usage-limit text fails the suite, even beside
a limit hit. Only the ledger's limit flag makes a suite inconclusive and stops the later suites; a
row whose text matches the limit pattern only keeps that row from counting as a failure, so a
genuine failure that mentions a limit is never masked without a real limit hit.

**Credentials never reach the artifact.** The credential is a secret of the `live-evals`
environment, whose deployment branches the owner limits to `main`. Only the `probe`, `run` and
`scrub` steps receive it, as step env. `scrub` stages a copy outside the results directory that
holds only regular files that contain no credential value of at least 8 characters; symbolic links
and other entries stay out. Each file is opened with `O_NOFOLLOW` and `O_NONBLOCK` and judged by its
descriptor, so a named pipe swapped in after the directory listing is left out instead of blocking
the step (L10 in `test-live-evals.sh`). A left-out file fails the step, an unreadable
entry withholds `scrubbed=true`, and the upload runs only on that output and reads only the staged
directory. Dependency install scripts stay off (`npm ci --ignore-scripts`) because the same runner
later holds the credential. Measured locally on an install whose dependency install scripts had not
run: Promptfoo still ran an eval.

**Coupled sites.**

- The eval knobs `EVAL_CLAUDE_MODEL`, `EVAL_USAGE_LEDGER` and `EVAL_SUITE` must survive the
  zen-mode provider's scrub of `ZENSU_*`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`,
  `CLAUDE_PROJECT_DIR` and `CLAUDE_ENV_FILE`: W6 in `test-live-evals.sh`.
- The model-name grammar exists twice, in the wrapper and in `model_ok` of `live-evals.sh`; W5 runs
  both over one table.
- The suite list is `SUITES` in `live-evals.sh` and the `suites` choice options of the workflow.
- The results directory (`$RUNNER_TEMP/live-evals`) and the upload directory
  (`$RUNNER_TEMP/live-evals-upload`) are defaults in `live-evals.sh` and a literal upload `path:` in
  the workflow.
- The workflow runs on Node 22, the engine floor `@anthropic-ai/claude-code` declares.
- `test-promptfoo-local-only.sh` reads the workflow by exact indentation: steps at 6 spaces, step
  keys at 8, step env at 10 and the job's `environment:` at 4. Re-indenting the YAML fails the shape
  check and its twelve planted weakenings.
- The installer step's `run:` line is counted twice, by that shape check and by H11.
- `test-live-evals.sh` is in `ciStructureTests` and skips every executed check on native Windows,
  with its `excluded` entry in `tests/profiles/windows-native-structure.v1.json`.
- `evals/session-control/run-self-check.sh`, an offline eval of every CI run, scans every workflow
  except `live-evals.yml` for Promptfoo, the two credentials and the Session Control evals, and
  `live-evals.yml` for the Session Control evals only. Renaming the workflow fails that scan.
- R1 in `test-live-evals.sh` pins what `cmd_run` exports for Promptfoo: the home
  `$OUT/promptfoo-home` and `PROMPTFOO_DISABLE_TELEMETRY` and `PROMPTFOO_DISABLE_UPDATE` set to `1`,
  over any value the caller set. Its stub cannot see whether Promptfoo still reads those names, so a
  Promptfoo bump checks them in `node_modules/promptfoo/dist`; 0.121.20 reads all three.

**Version: `patch`.** CI, tests and docs, plus wrapper knobs that are read only when set: no
schema, strict key set, hook, matcher or attestation moves.
