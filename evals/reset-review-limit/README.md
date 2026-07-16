# evals/reset-review-limit

Promptfoo eval suite for the revision-secured `/zensu:reset-review-limit` skill
(3 scenarios, each repeated 3 times).

## What's here

| Path | Role |
|---|---|
| `promptfooconfig.yaml` | No-agent provider config; invokes the skill directly in an isolated clone and grades only the sealed provider attestation. |
| `provider.sh` | Binds the scenario id and enables the wrapper-owned evidence tap. |
| `lib/seed-state.js` | Generates a wrapper-owned UUID, synchronously seeds the exact canonical CAS document and scenario fixtures, and publishes the before snapshot before Claude starts. |
| `lib/stream-evidence.js` | Reads structured Claude stream events and proves one exact successful `Skill` tool call plus the absence of file-search/deletion tool commands. |
| `lib/sealed-attestation.js` | Independently reads back canonical state and sidecars after the run and emits one digest-sealed provider frame. |
| `assertions/sealed-attestation.js` | Recomputes the digest and validates scenario-specific before/after invariants without trusting assistant prose. |
| `verify-results.js` | Requires exactly nine passing rows and the exact `3 x 3` scenario-id multiset. |
| `scenarios/reset-cas-happy.yaml` | Seeds the current active session through trusted helpers and proves one atomic CAS revision zeros both counters and re-arms every convergence flag/latch. |
| `scenarios/reset-invalid-state.yaml` | Changes `reviewRound` to a string and proves Phase 1 fails closed without sanitizing or changing the evidence. |
| `scenarios/reset-sidecar-isolation.yaml` | Places an inert `.stopblocks` symlink and retired rounds file beside the canonical state, then proves neither file nor the symlink target is touched. |
| `test-projects/empty-host/` | Minimal cloneable fixture. Workflow state is created at runtime by the installed plugin using the current Session Control key. |

## Gating

Real `claude --print` runs require `promptfoo`, an authenticated Claude CLI, and
an explicit `ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1` acknowledgement because the
provider uses Claude's unrestricted non-interactive mode. The provider binds the
Zensu plugin directly from this checkout so `/zensu:reset-review-limit` cannot
resolve from a stale global installation. The structure
test `tests/structure/test-promptfoo-reset-review-limit.sh` validates the suite,
its assertion density, and its CAS/security coverage in plain CI.

## Running

```bash
cd evals/reset-review-limit
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 bash run-eval.sh
```

`evaluateOptions.repeat: 3` makes the three scenarios nine live runs.
`maxConcurrency: 2` limits API load. `run-eval.sh` always writes Promptfoo JSON
to a private temporary directory and passes it through `verify-results.js`, so a
missing, duplicated, or unexpected row cannot be hidden by the per-row grade.

## Scenario semantics

Every scenario is bound to `ZENSU_SESSION_KEY` and derives one canonical
`tdd-phase-scv1_<hash>.json` document. The happy and isolation scenarios seed
state only via `zensu-tdd-phase.sh` transactions and validate with
`session-control-core-v1.js`. The invalid-state scenario deliberately tampers a
test artifact, then hashes it before and after to prove fail-closed preservation.

The assistant's final text is diagnostic only and is never grading evidence.
The provider forces `--plugin-dir` to this physical checkout and the sealed
assertion recomputes its Claude runtime digest and plugin version. The wrapper
chooses the Claude `--session-id`, synchronously seeds and snapshots the exact
CAS document before starting Claude, observes the structured `Skill` tool event,
then independently reads the canonical document and inert sidecars after Claude
exits. Any model mutation before the skill changes the revision or bytes and
therefore fails the before/after invariant. The reserved
`[reset-review-limit-attestation]` frame carries a SHA-256 evidence digest; model
content using that prefix is escaped by the stream renderer. A successful reset
must independently prove revision delta `3`, while the invalid-state run must
prove byte-for-byte preservation.
