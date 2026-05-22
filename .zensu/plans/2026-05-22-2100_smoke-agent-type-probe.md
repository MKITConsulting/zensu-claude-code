# TDD Plan: Smoke-Test CLAUDE_AGENT_TYPE Propagation

## Context

Diagnostic probe to determine empirically whether `CLAUDE_AGENT_TYPE` env var is
set in the bash environment that `hooks/pre-edit-tdd-reminder.sh` runs in when
invoked as PreToolUse hook for an Edit tool call made by a `zensu:tdd-manager`
subagent (spawned via Agent tool from outer claude session in `--print` mode).

This is a NON-DESTRUCTIVE diagnostic. Net code change after smoke = 0 lines.
Plan + log artifacts under `.zensu/` are kept and committed.

Two candidate root causes for v6 promptfoo failures (drift+REFACTOR scenarios 2-7):
1. `CLAUDE_AGENT_TYPE` not propagated to hook env -> hook's guard at
   `hooks/pre-edit-tdd-reminder.sh:31-38` exits 0 -> gate never enforces ->
   Patch 8 mirror never fires.
2. Agent ignores `zensu-log.sh --phase` discipline -> state file empty ->
   Patch 9 enrichment yields nothing.

This smoke isolates root cause #1.

**Approach**: Strict Red/Green TDD on Step 1, W (wire+execute) on Steps 2-3.
**Tech Stack**: bash + node + jq + promptfoo.
**Coverage**: SKIPPED (ephemeral smoke probe; no coverage tool wired for bash tests).

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1   | Feature | Probe code lands in hook + wrapper (opt-in via env var) | tests/structure/test-agent-type-probe.sh | -    | [G]    | 1        |
| S2   | Integration | Wired smoke run via promptfoo (filter='Happy-Path FE') | -                                          | S1   | [W]    | 1        |
| S3   | Integration | Cleanup: revert probe, delete test, verify baseline restored | -                                          | S2   | [W]    | 1        |

### Step S1 -- Probe code lands

- [ ] **RED**: Test `tests/structure/test-agent-type-probe.sh` -- 3 cases:
  - C1: `bash -n` syntax check on `hooks/pre-edit-tdd-reminder.sh` and `scripts/claude-promptfoo-wrapper.sh` pass
  - C2: Without `CLAUDE_AGENT_TYPE_DIAG_LOG` env var, hook executes normally and writes no probe file
  - C3: With `CLAUDE_AGENT_TYPE_DIAG_LOG=/tmp/probe.log` + any PreToolUse payload, probe file contains 5 expected `[probe] ...` lines
  - Will FAIL until probe block exists in hook (C3 has nothing to assert against; will not produce the probe file).
- [ ] **GREEN**:
  - (a) Insert probe block into `hooks/pre-edit-tdd-reminder.sh` after line 6 (PAYLOAD="$(cat)"), before line 8 (node check).
  - (b) Add `CLAUDE_AGENT_TYPE_DIAG_LOG` export + concat block to `scripts/claude-promptfoo-wrapper.sh`.

**Checkpoint**: `bash tests/structure/test-agent-type-probe.sh` exits 0 with 3/3 PASS.

### Step S2 -- Wired smoke run

- [ ] **W**: Execute promptfoo eval filtered to `01-happy-frontend`, capture probe output.

```bash
cd evals/tdd-manager-pretool
rm -f /tmp/smoke-agent-type.json /tmp/smoke-agent-type.log
promptfoo eval -c promptfooconfig-pretool.yaml \
  --filter-pattern '01-happy-frontend' \
  --no-cache --no-progress-bar --repeat 1 \
  --output /tmp/smoke-agent-type.json > /tmp/smoke-agent-type.log 2>&1
jq -r '.results.results[0].response.output' /tmp/smoke-agent-type.json \
  | grep -A 30 'agent-type probe'
```

Record exact probe block in log + final report. Map outcome to decision table.

### Step S3 -- Cleanup, revert probe

- [ ] **W**: Revert probe blocks in hook + wrapper, delete test file, verify baseline.
  - (a) Revert `hooks/pre-edit-tdd-reminder.sh` -- remove probe block.
  - (b) Revert `scripts/claude-promptfoo-wrapper.sh` -- remove `CLAUDE_AGENT_TYPE_DIAG_LOG` export + concat block.
  - (c) Delete `tests/structure/test-agent-type-probe.sh`.
  - (d) Confirm `tests/structure/test-pre-edit-hook-mirror.sh` still 8/8 PASS, `tests/structure/test-claude-promptfoo-wrapper.sh` still 20/20 PASS.

**Checkpoint**: Net change to tracked files = baseline diffs only (Patch 8/9 mirror+enrichment). `git diff hooks/pre-edit-tdd-reminder.sh scripts/claude-promptfoo-wrapper.sh` matches the pre-smoke diff.

## Final Verification

- [x] Probe output captured verbatim in log + final report (the probe block was ABSENT from output -- verbatim "agent-type probe" markers count = 0)
- [x] Outcome mapped against decision table: "Probe block absent in output" -> "Hook never fired at all -- bigger problem"
- [x] Baseline tests restored (test-pre-edit-hook-mirror 8/8 PASS, test-claude-promptfoo-wrapper 20/20 PASS, full structure-test suite 83/83 PASS)
- [x] Probe test file deleted (`tests/structure/test-agent-type-probe.sh`)
- [x] Plan + log committed under `.zensu/`

## Outcome

**Empirical result:** the smoke could NOT determine `CLAUDE_AGENT_TYPE` propagation because the precondition (hook execution) was never met. The PreToolUse hook never ran during the promptfoo eval.

**Root cause (unexpected):** the globally installed zensu plugin (v0.3.14 at
`~/.claude/plugins/cache/zensu/zensu/0.3.14/hooks/hooks.json`) declares only
`PostToolUse` (`ExitPlanMode`, `Agent`) and `SessionStart` hooks. It has **no
PreToolUse matcher**, and indeed has no `pre-edit-tdd-reminder.sh` file at all.
The worktree on this branch DOES add both `hooks/pre-edit-tdd-reminder.sh` AND a
PreToolUse matcher to `hooks/hooks.json`, but the published plugin release the
inner `claude --print` process resolves to has not yet incorporated this branch.

**Implication for v6 promptfoo failures:** drift+REFACTOR scenarios 2-7 fail
NOT because `CLAUDE_AGENT_TYPE` is unset, NOR because the agent ignores
`zensu-log.sh --phase` discipline (root causes #1 and #2 in the plan context).
The failures are explained by a third root cause that supersedes both: **the
plugin release the eval harness invokes lacks the PreToolUse infrastructure
entirely**. Until a new plugin release is published containing the PreToolUse
matcher and the `pre-edit-tdd-reminder.sh` hook, no in-eval assertion that
depends on hook firing can pass.

## Recommended Next Action

**Neither Path B (wrapper-level export) nor Path D (rewrite assertions) is the
correct fix in isolation.** The actionable next step is:

1. **Publish a new zensu plugin release** that includes `hooks/pre-edit-tdd-reminder.sh`,
   `hooks/lib/zensu-tdd-phase.sh`, `hooks/lib/zensu-log.sh`, and the updated
   `hooks/hooks.json` declaring the PreToolUse `Edit|Write|MultiEdit` matcher.
   Without this, the eval-time PreToolUse hook is dark code.

2. **Re-run this smoke probe AFTER the release** to actually determine
   `CLAUDE_AGENT_TYPE` propagation. Only then will the decision between Path B
   (wrapper export) and the alternative (env propagation works as designed,
   investigate Patch 9 state-file discipline -- root cause #2) be answerable.

3. **Interim option for unblocking v6**: pin the eval harness to a worktree-local
   plugin install instead of the global cache, by adding a `settings.json` /
   `.claude-plugin/` directly inside `evals/tdd-manager-pretool/test-projects/react-go-fullstack/`
   that points at the in-tree `hooks/` directory. This would let the v6 eval
   exercise the unpublished hook without waiting on a release.
