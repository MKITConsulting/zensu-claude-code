# zensu-plm Agent E2E Harness

Behavioral-contract smoke test for the `zensu-plm` orchestrator agent
(`agents/zensu-plm.md`). Fires the agent against fixture prompts and asserts
that the right workflow / MCP tools / Important Rules appear in its text
output.

This complements `tests/e2e/` (which tests `code-reviewer` + `tdd-manager`
guardrails). It does **not** require a live Zensu MCP server in the default
mode — it asserts only that the agent *names* the correct tools and follows
the Decision Rules / Important Rules in its plan. A `--live` mode that talks
to a real Zensu backend is explicitly out of scope (Phase 2).

## Language convention

This is an **English only** repository. Prompts, pattern alternations,
fixture content, shim stubs, ideal captures, violating-capture corpus
entries, README examples, and commit messages must all be in English.
Historical `.zensu/plans/*.md` and `.zensu/logs/*.log` from prior rounds
are exempt — they are immutable TDD audit trail. Round-14 onward must
produce English-only output.

## What it tests

| Fixture | Asserts (signal kept tolerant — patterns use regex) |
|---------|-----------------------------------------------------|
| `bootstrap` | Vision → product workflow: `create_product`, `create_product_vision`, `bootstrap_from_vision` / `apply_bootstrap`, components + features |
| `implement` | KEY-N + code: `get_feature`, `analyze_feature_security` / `set_security_classification`, `link_test` / `link_source_files`, `create_revision`, `validate_feature_security`. Stresses Rule 4 (security classification before implementation) only — Rule 2 (`list_features` before guessing an ID) is intentionally NOT re-stressed here; see Known caveats. |
| `security-review` | Full security sequence: classify → analyze → suggest/add tests → STRIDE → `complete_security_review` |
| `ghost-scan` | `list_features` first (Rule 7), then `ghost_scan` with `enrich_existing`, candidates, batch review, apply |
| `pulse-session` | `pulse_start_session` or summary plus git HEAD / branch reference |
| `status-transition` | Agent points to REST API, **must NOT** call `update_feature(...)` with status / "update_feature with ..." narration (Rule 3, two same-line tool-call-shape negative asserts) |
| `feature-id-guard` | Agent calls `list_features` or asks back for the correct ID — **must NOT** invent ZEN-999 (Rule 2) |

## Layout

```
tests/e2e-plm/
├── run.sh                       # Test runner (this harness)
├── setup-fixtures.sh            # Idempotent fixture-repo creator
├── test-runner.sh               # Unit tests for run.sh + the shipped patterns
├── README.md                    # This file
├── prompts/                     # One .txt per scenario — fed verbatim to claude --print
│   ├── bootstrap.txt
│   ├── implement.txt
│   ├── security-review.txt
│   ├── ghost-scan.txt
│   ├── pulse-session.txt
│   ├── status-transition.txt
│   └── feature-id-guard.txt
├── expected/                    # One pattern file per scenario (regex per non-blank line)
│   ├── bootstrap.pattern
│   ├── implement.pattern
│   ├── security-review.pattern
│   ├── ghost-scan.pattern
│   ├── pulse-session.pattern
│   ├── status-transition.pattern
│   └── feature-id-guard.pattern
├── fixtures/                    # Created by setup-fixtures.sh, gitignored
└── results/                     # Run artifacts, gitignored
```

## Run

```bash
# Setup fixtures (idempotent, ~1 second — just plain git init repos, no npm)
bash tests/e2e-plm/setup-fixtures.sh

# Self-check unit tests for the runner + the shipped patterns (no claude spawn)
bash tests/e2e-plm/test-runner.sh

# Self-check the runner skeleton (skips fixtures entirely)
bash tests/e2e-plm/run.sh --self-check

# Offline replay — reuses the newest results/<fixture>-<timestamp>.captured.txt
bash tests/e2e-plm/run.sh --offline

# Full live run — 7 claude --print invocations, several minutes + API spend
bash tests/e2e-plm/run.sh
```

Only `--self-check`, `--offline`, an empty arg, or `full` are accepted modes.
Anything else (typos like `--bogus`) exits with code `2` and an `unknown mode`
error message.

## Requires

- `bash` (POSIX-compatible shell)
- `git` 2.28+ (for `init -b main`)
- `claude` CLI on `$PATH` (full runs only — not needed for `--self-check`,
  `--offline`, or the test-runner)

No `npm` required — the PLM fixtures are minimal git repos, not buildable
codebases.

## Pattern File Conventions

One pattern file per scenario in `expected/<scenario>.pattern`. Each
non-blank line is treated as a regex.

- **Positive assert** (default): the regex MUST match somewhere in the
  agent's captured output.
- **Negative assert** (line begins with `!`): the regex MUST NOT match. Used
  to enforce Important Rules — e.g. `status-transition.pattern` has
  `!update_feature.*status` because Rule 3 says status changes are NOT MCP.
- **Comment** (line begins with `# ` — hash + space): skipped by the matcher.
  Use for documenting which Decision Rule or Important Rule the assert is
  testing. Lines starting with `##` are NOT comments (they match Markdown
  headers if the agent's output contains any).

Patterns should target **signal substrings** with tolerant regex, not exact
phrasing. LLM output varies in wording.

```
# Good: tolerant of "I'll call create_product", "Calling create_product",
# "Use create_product first" etc.
create_product

# Brittle: breaks on capitalization or punctuation
Step 1: Call create_product.
```

## Adding a new scenario

1. Add a `make_<name>()` function to `setup-fixtures.sh` modeled on the
   others. Use `git_init` for a deterministic baseline.
2. Call `make_<name>()` from `main()` at the bottom of `setup-fixtures.sh`.
3. Add `tests/e2e-plm/prompts/<name>.txt` — the user-facing prompt.
4. Add `tests/e2e-plm/expected/<name>.pattern` with the regex(es).
5. Re-run `bash tests/e2e-plm/setup-fixtures.sh` and verify the directory
   exists with `ls tests/e2e-plm/fixtures/<name>`.
6. Update the `expected_fixtures` list in `test_setup_fixtures_idempotent`
   inside `test-runner.sh`.
7. Smoke-test by writing a hand-crafted `results/<name>-*.captured.txt` that
   simulates ideal agent output, then run `bash tests/e2e-plm/run.sh --offline`.
8. After three stable live runs, the scenario is regression-safe.

## Known caveats

- **No live Zensu MCP server required.** The default mode asserts only
  text-output behavior. If the agent's actual MCP tool calls fail because no
  Zensu server is reachable, the agent should still describe its plan in
  text — and that text is what the patterns match against.
- **LLM non-determinism.** The agent's exact phrasing varies between runs.
  Patterns must use tolerant regexes; otherwise they will flap.
- **Patterns are lower-bound.** A passing pattern proves the workflow signal
  *appeared*. It does not prove the agent's behavior was correct in every
  detail. Treat this as regression smoke, not a correctness oracle.
- **Status-transition is the only negative-assert in this harness.** It is
  the canonical example of an Important Rule that *forbids* a specific tool
  call. If you add more such rules, model the pattern on
  `status-transition.pattern`.
- **Rule 2 (`list_features` before `get_feature`) is enforced only in
  `feature-id-guard.pattern`.** The `implement` scenario assumes the ID is
  valid and does not re-stress Rule 2 — adding a `list_features` assert there
  would conflate two scenarios and weaken the discriminating power of
  `feature-id-guard`. The implement scenario stresses Rule 4 (security
  classification before implementation) only.
- **Negative-assert escape forms — three known shapes slip past the harness.**
  `match_pattern` greps per-line and the shipped `status-transition.pattern`
  targets only the two most common tool-call shapes
  (`update_feature\s*\(` and `update_feature\s+with`). Three classes of
  adversarial phrasings are known to PASS unflagged:
  1. **Cross-line splits.** An agent that mentions `update_feature` on line
     N and `status` on line N+M cannot be caught with a single per-line regex.
  2. **Same-line bare juxtaposition.** Tool name and parameter on one line
     with no `(` and no `with`. Example: `update_feature status=released`.
  3. **Same-line YAML-style serialization.** Multi-line YAML where the tool
     name appears on a `tool:` line and the parameter on a subsequent
     indented line, e.g.:
     ```
     tool: update_feature
       status: released
     ```
  Concrete adversarial phrasings observed in round 3 that all PASS the
  shipped 2-probe pattern:
  - YAML-style as shown above
  - `update_feature taking status=released`
  - `update_feature accepting parameter status=released`
  - `update_feature status=released` (bare juxtaposition)
  Reversed-order benign disclaimers (e.g. "the status transition is not
  supported by update_feature") also pass through, which is the *correct*
  behavior because they lack tool-call shape. Adding a third probe to chase
  the bare-juxtaposition / YAML forms was tested in round 3 and rejected for
  false-positive risk against legitimate prose. The harness deliberately
  stays conservative — budget for a periodic manual review of the captured
  outputs.
- **Empty negative-assert needles emit `WARN` instead of FAIL.** A bare `!`
  line — or a `!`-prefixed line with only whitespace after the bang (e.g.
  `! ` or `!  `) — in a pattern file is treated as a pattern-author typo:
  `match_pattern` strips leading/trailing whitespace from the needle, detects
  it is empty, prints a `WARN  empty negative-assert needle` diagnostic to
  stderr AND appends the same line to the canonical `report-<TIMESTAMP>.txt`
  via `tee`, then skips the line. The test does not fail because of the typo.
  This trades silent-failure debuggability for a visible nudge to fix the
  pattern file, and keeps postmortem readers of the report file informed.
- **Live runs cost real API tokens.** A full `run.sh` triggers 7 `claude --print`
  invocations. Each one is a full agent turn with tool access. Budget several
  minutes and meaningful API spend per run. Use `--offline` while iterating
  on pattern phrasing.

### feature-id-guard known caveats — line-based-grep ceiling

The `feature-id-guard.pattern` is a **LOWER-BOUND assertion**. It proves the
agent's output contains AT LEAST ONE Rule-2 ask-back signal somewhere. It
does NOT prove the agent followed Rule 2. Two structural bypass classes
remain open by design — and tightening per-line regexes further has been
empirically demonstrated to converge on diminishing returns (each round
closes a vocabulary variant and opens new ones).

**Bypass class 1 — Same-line walk-back.** The agent declares an ask-back
intent on one line, then walks it back later in the same line. The pattern
matches the prefix and the line PASSes.

Concrete reproductions (verbatim from reviewer):

- `Need to call list_features... oh actually get_feature ZEN-999`
- `First call list_features... actually skip it, calling get_feature ZEN-999.`
- `Will call list_features. Actually get_feature ZEN-999 directly.`
- `Let me call list_features eventually. Right now calling get_feature ZEN-999.`
- `Going to call list_features after lunch; meanwhile get_feature ZEN-999.`

**Bypass class 2 — Multi-line walk-back.** The agent emits a clean
ask-back on line N, then silently violates on line N+1. Per-line `grep -E`
evaluates each line independently and sees only the clean line.

Concrete reproductions (verbatim from reviewer):

- `list_features first.\nNow get_feature ZEN-999.`
- `User paste ZEN-999 metadata first.\nCalling get_feature ZEN-999 anyway.` (alt 14 walk-back)
- `Cannot call get_feature without product context.\nActually, calling get_feature ZEN-999 anyway.` (alt 16 walk-back)

**Architectural reason.** `grep -E` (and the underlying `match_pattern`
helper) evaluates each pattern line against each capture line
independently. Detecting "anchor satisfied on line N AND no walk-back on
line N+M" semantics requires either:

- `pcregrep -M` (multi-line PCRE) — non-portable across BSD/GNU userlands.
- `tr '\n' ' '` whole-file slurp — kills line-locality of negative asserts
  and bloats false-positive surface.
- A separate `awk`/`bash` stateful pass — re-implements a tiny parser
  inside a smoke-test harness.

All three are **deliberate non-goals** for this harness. The harness is a
regression smoke check, not a production-grade enforcer.

**Mitigation**: End-to-end pattern tests are smoke-level. The intended production guard is the
Zensu MCP server: when the agent calls `get_feature` with an unknown ID, the server should
return NOT_FOUND, and the agent should NOT retry. This behavior is enforced (a) by the agent
directive in `agents/zensu-plm.md:177` ("Never guess feature IDs. Always use list_features
or ask the user") and (b) ideally by the MCP server returning a clear error on unknown IDs —
verified out-of-repo, not by this harness. Treat the smoke pattern as a lower-bound assertion
that the agent EMITS Rule-2 signal; runtime correctness is owned elsewhere.

If you discover a REAL agent regression in production that the existing
pattern misses — and that regression survives the MCP-boundary check —
promote the capture into `tests/e2e-plm/fixtures/live-regressions/`. Do
NOT chase reviewer-synthesized adversarial phrasings down the per-line
regex hole; they are guaranteed to keep coming.

## Live regression corpus

`tests/e2e-plm/fixtures/live-regressions/` is the one subdirectory of
`tests/e2e-plm/fixtures/` that is **tracked** (the parent is otherwise
gitignored). Files there are curated, anonymized snapshots of live
`claude --print` captures that previously revealed a pattern defect —
their job is to make sure future pattern tightenings never silently
regress against the empirical evidence that motivated the original fix.

Layout:

```
tests/e2e-plm/fixtures/live-regressions/
└── feature-id-guard-caveman-200525.txt   # Caveman-mode terse ask-back (Rule-2 ask-back)
```

The test `test_live_regression_captures_pass_pattern` (in
`test-runner.sh`) iterates every `feature-id-guard-*.txt` in that
directory and asserts each one PASSes the shipped pattern. A failure
there means the most recent pattern tightening broke a previously-valid
agent ask-back shape — relax the offending alt before merging.

When promoting a live capture into the regression corpus:

1. Copy the file from `tests/e2e-plm/results/` into
   `tests/e2e-plm/fixtures/live-regressions/`.
2. Rename to a stable, identifier-free name (no per-capture timestamp, no
   agent version) describing the linguistic register. A stable date-of-
   corpus-entry suffix like `-200525` is fine — it identifies a
   capture-date class, not a specific session. Example:
   `feature-id-guard-terse-200525.txt`.
3. Manually strip any identifying header (agent version banner,
   timestamp footer, user-name reference) before committing.
4. Commit it as a fixture, not as a result.

## Commit hygiene

Round 11 and onward make focused, reviewable commits — one logical
change per commit — so `git bisect` lands on a meaningful diff and code
review stays tractable. Typical TDD-round commit shape:

- C1: pattern tightening (one or more `expected/*.pattern` edits)
- C2: corpus expansion + harness stubs (`test-runner.sh`)
- C3: harness safety guards (e.g. `printf %b` `\c` truncation guard)
- C4: live-regression fixtures (`fixtures/live-regressions/*.txt` +
  `.gitignore` un-ignore)
- C5: plan + log + README (`.zensu/plans/...`, `.zensu/logs/...`,
  `README.md`)

Avoid bundling unrelated changes into a single commit. If a TDD round
spans both a pattern fix and an unrelated harness improvement, split
them.

## Cleanup

`tests/e2e-plm/fixtures/` (except for `live-regressions/`) and
`tests/e2e-plm/results/` are gitignored. Re-running `setup-fixtures.sh`
is destructive — it removes each fixture directory before recreating
it, so manual edits inside `fixtures/` (other than `live-regressions/`)
are not preserved.
