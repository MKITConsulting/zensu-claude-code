# TDD Plan: Auto-fix rounds counter — reset on fresh task boundary

## Context

The auto-fix review loop (`zensu:code-reviewer` -> `zensu:tdd-manager`) is guarded by a
"max rounds" counter keyed by the Claude Code session UUID
(`rounds-<session_id>.json`). The counter is incremented on every code-reviewer
completion and never reset except by the manual `/zensu:reset-review-limit` skill.
Consequence: a second task in the same session inherits the first task's round count and
can hit "max N rounds reached" early or on its first review.

Fix: reset the counter at every auto-fix chain start, detected at the single chokepoint
`hooks/post-tdd-review-delegate.sh` (fires on every tdd-manager completion). A tdd-manager
run whose prompt is a feature spec (NOT the `findings from code review` sentinel) is a
fresh task -> reset. Safe polarity: only reset when sentinel ABSENT and prompt non-empty;
sentinel present OR empty prompt -> do NOT reset (guard stays intact).

**Approach**: Strict Red/Green TDD | **Tech Stack**: Bash hooks + Node (JSON) + Markdown
**Coverage**: SKIPPED (shell/JSON/markdown — no line-coverage tool applies; eval suite is the gate)
**Test gate**: `evals/config-gate/run-eval.sh --self-check` (offline, authoritative for hooks)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present (v23.11.0) | use |
| expect | CLI | `command -v expect` | present | use (E2E skipped in self-check) |
| config-with-max-rounds.json | fixture | `[ -f evals/config-gate/fixtures/... ]` | present | use |

No missing preconditions — no escalation needed. Change set is shell+JSON+markdown (spec
confirms no TypeScript, so `tsc` does not apply).

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Reset logic in `post-tdd-review-delegate.sh` (5 cases) | `evals/config-gate/test-autofix-rounds-reset-on-fresh-tdd.sh` | — | [G] | 1 |
| S2 | Integration | Register new test in `run-eval.sh` | (run-eval self-check) | S1 | [W] | — |
| S3 | Integration | SKILL.md doc accuracy (When to Use narrowing) | (none — markdown) | — | [W] | — |
| S4 | Integration | Version bump plugin.json + marketplace.json + CHANGELOG | (JSON.parse validity) | S1,S2 | [W] | — |

### Step S1 — Reset logic in post-tdd-review-delegate.sh
- [ ] **RED**: New test `test-autofix-rounds-reset-on-fresh-tdd.sh` asserting 5 cases
  (fresh-prompt deletes counter; fix-round preserves; empty-prompt preserves;
  non-tdd-manager subagent preserves; symlink guard preserves + stderr warning;
  plus fresh-prompt stdout still emits the spawn-reviewer directive). FAILS because the
  hook does not yet parse the prompt or delete the counter (counter survives fresh run).
- [ ] **GREEN**: Insert prompt-parse + IS_FIX/PROMPT_EMPTY compute + session/state-dir
  resolution (mirroring `post-review-tdd-delegate.sh:37-62`) + symlink guards +
  `rm -f` of the counter file when fresh, all between the subagent check (line 32) and
  the heredoc directive (line 36). Directive emission unchanged on stdout.

**Checkpoint**: `bash evals/config-gate/test-autofix-rounds-reset-on-fresh-tdd.sh` passes.

### Step S2 — Register test in run-eval.sh
- [ ] **WIRE**: Add `run_test ".../test-autofix-rounds-reset-on-fresh-tdd.sh" "..."`
  after the `test-autofix-rounds-sanitize.sh` line in the Auto-fix block.

**Checkpoint**: `run-eval.sh --self-check` shows the new test PASS, no regressions.

### Step S3 — SKILL.md doc accuracy
- [ ] **WIRE**: Narrow `## When to Use` to reflect per-task auto-reset; soften
  between-tasks implication. Markdown only.

### Step S4 — Version bump + CHANGELOG
- [ ] **WIRE**: plugin.json 0.3.28 -> 0.3.29; marketplace.json plugins[0].version ->
  0.3.29; CHANGELOG new `## [0.3.29]` section. Validate both JSON files parse.

## Final Verification
- [x] `evals/config-gate/run-eval.sh --self-check` all PASS incl. new test (59/59)
- [x] `node -e JSON.parse` on plugin.json + marketplace.json (both valid, 0.3.29)
- [x] Manual hook simulation: fresh payload deletes counter, fix payload preserves
- [x] Convergence eval still hits max-rounds (guard preserved mid-chain)
- [x] mtime discipline: S1 test-first (test mtime < impl mtime)
- [x] Build: n/a (plugin repo — no build manifest; eval suite is the gate)
- [x] Coverage: SKIPPED (no line-coverage tool for shell/JSON/markdown)
- [!] Witness cross-check: NOT POSSIBLE — no witness log for this session (witness
      PostToolUse hook inactive in this execution context). AUDIT cmd claims recorded
      but cannot be machine-verified against a witness log; surfaced as known limitation.
