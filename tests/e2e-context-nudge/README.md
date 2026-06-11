# tests/e2e-context-nudge — live context-compaction-nudge E2E

Proves [`hooks/user-prompt-context-nudge.sh`](../../hooks/user-prompt-context-nudge.sh)
reads a **real** Claude Code session transcript correctly, end to end.

The deterministic structure test
([`tests/structure/test-context-nudge-hook.sh`](../structure/test-context-nudge-hook.sh))
exercises the hook against *synthetic* transcripts. This suite closes the gap that
only a real run can: it spends one live `claude --print` call to generate a genuine
session transcript (real `message.usage` nesting, real `cache_read`/`cache_creation`
token splits — the exact shape a synthetic fixture can drift from) and then invokes
the hook the way the `UserPromptSubmit` event does, asserting on the hook's own
deterministic output rather than on non-deterministic model prose.

## What it asserts

1. `claude --print` produced output (plugin loaded, the `UserPromptSubmit` hook was
   active and did not break the session).
2. A real session transcript was located and carries a parseable
   `message.usage.input_tokens` block (real format, real field nesting).
3. The hook runs against that real transcript **fail-open**: exit 0 with a
   valid-or-empty contract. (A trivial `claude --print` greeting records ~0
   occupancy, so this proves the real-format read + fail-open path — not a nudge.)
4. **Behavioral** (only when a real `occupied>0` session exists on disk — present on
   a dev machine, **skipped** in a barren CI): **tiny window** (`context.windowSize:1000`)
   → `/compact` proposal; **huge window** (`100000000`) → silent.

The occupancy *math* (silent at/below 200k unless windowSize is set; occupancy past 200k is proven 1M; threshold bands, zero-usage skip) is pinned
hermetically by [`tests/structure/test-context-nudge-hook.sh`](../structure/test-context-nudge-hook.sh);
this suite proves the read works against **real** Claude Code transcript structure —
which is exactly how it caught that real transcripts end with a trailing all-zero
`usage` record (the hook now skips those and reads the most recent non-zero block).

## Run

```bash
bash tests/e2e-context-nudge/setup-fixtures.sh   # build the greet/ fixture
bash tests/e2e-context-nudge/run.sh              # live (one API call)
bash tests/e2e-context-nudge/run.sh --offline    # re-assert last run's transcript (no API)
bash tests/e2e-context-nudge/run.sh --self-check  # skeleton only (no claude)
```

Also wired into `tests/run-all.sh --live` and `--self-check`.

`ZENSU_CTX_E2E_TIMEOUT` overrides the `claude --print` timeout (default 180s).
`fixtures/` and `results/` are generated and git-ignored.
