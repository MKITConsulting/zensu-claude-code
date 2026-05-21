# TDD Plan: Review-Fix Cycle (Round 3) — tdd-review-chain Isolation

## Context

Round-3 review on Phase-B feature branch `feat/project-local-config-and-suggestion-routing` (`/Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code`).

Round 1 found that test files invoking the new state-writing hook `hooks/post-review-tdd-delegate.sh` leak counter state into `~/.zensu/state/rounds-unknown.json`. Round 2 patched the single known instance in `evals/config-gate/test-no-pluginroot-env.sh`. Round 3 review caught two more siblings in the OTHER eval suite, `evals/tdd-review-chain/`:

1. `evals/tdd-review-chain/assert-severity-routing.sh` (lines 29, 37, 45) — three invocations of `$SCRIPT` (= `post-review-tdd-delegate.sh`) without `CLAUDE_PLUGIN_DATA` isolation.
2. `evals/tdd-review-chain/run-eval.sh` (line 122 + line 194) — two invocations of `$REVIEW_SCRIPT` (= `post-review-tdd-delegate.sh`) without `CLAUDE_PLUGIN_DATA` isolation.

Empirically reproduced (`bash evals/tdd-review-chain/assert-severity-routing.sh`): a clean state directory becomes `/Users/marcelkarras/.zensu/state/rounds-unknown.json` containing `{"count":1,"ts":"…"}`. Same effect from `bash evals/tdd-review-chain/run-eval.sh --self-check`. The file is NOT cleaned up.

Bug class: "test files invoking the new state-writing hook without isolating `CLAUDE_PLUGIN_DATA`". Fix uniform pattern: `export CLAUDE_PLUGIN_DATA="$(mktemp -d)"` + `trap cleanup EXIT`. Apply identically to both files.

Repo audit (all sites grep'd from `evals/`):
- `evals/config-gate/*` — 9 matches, ALL already have `CLAUDE_PLUGIN_DATA` isolation (round-2 work). No action.
- `evals/tdd-review-chain/run-eval.sh` — invokes new hook. NEEDS FIX (S2).
- `evals/tdd-review-chain/assert-changelog.sh` — only reads `CHANGELOG.md`, no hook invocation. No action.
- `evals/tdd-review-chain/assert-config.sh` — invokes the OLD `post-tdd-review-delegate.sh` which does NOT write state. No action.
- `evals/tdd-review-chain/assert-severity-routing.sh` — invokes new hook. NEEDS FIX (S1).

The `post-tdd-review-delegate.sh` (old, tdd-manager→reviewer) has been verified to NOT write state (grep `STATE_DIR|CLAUDE_PLUGIN_DATA|rounds-` returns nothing for that file). Only `post-review-tdd-delegate.sh` writes state.

Out of scope (deferred suggestion): `hooks/post-review-tdd-delegate.sh:77,83` plan-claim wording for fallback-write semantics — explicitly NOT addressed in this cycle.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash scripts | **Test runner**: shell exit codes (`bash <file>.sh` → 0 = PASS) | **Coverage**: SKIPPED (no coverage tooling for shell scripts; threshold source: not applicable)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Bug Fix | Retrofit `evals/tdd-review-chain/assert-severity-routing.sh` with `CLAUDE_PLUGIN_DATA` mktemp isolation + `trap cleanup EXIT`. | assert-severity-routing.sh (self-test) | — | [G] | 1 |
| S2 | Bug Fix | Retrofit `evals/tdd-review-chain/run-eval.sh` with `CLAUDE_PLUGIN_DATA` mktemp isolation + `trap cleanup EXIT` near the top (before the `REVIEW_OUT` invocation). | run-eval.sh --self-check | — | [G] | 1 |

**Checkpoint**: After both fixes, run BOTH eval suites + assert no leak:
- `bash evals/config-gate/run-eval.sh` — all green (unchanged from previous)
- `bash evals/tdd-review-chain/assert-severity-routing.sh` — all green
- `bash evals/tdd-review-chain/run-eval.sh --self-check` — green except pre-existing `assert-version.sh` failure (out-of-scope version mismatch)
- `ls /Users/marcelkarras/.zensu/state/ 2>/dev/null` empty (directory gone) after each run
- ShellCheck clean on both modified files

### Step S1 — Retrofit assert-severity-routing.sh

- [x] **RED-REPRO**: Ran `bash evals/tdd-review-chain/assert-severity-routing.sh` from a clean state. 17/17 PASS but `~/.zensu/state/rounds-unknown.json` (`{"count":1,"ts":"…"}`) appeared. Bug confirmed.
- [x] **FIX**: Inserted 3-line isolation block (`mktemp -d` + `cleanup()` + `trap cleanup EXIT`) directly after `set -u` (line 7→ now lines 9-11).
- [x] **GREEN**: Re-ran. 17/17 PASS, `~/.zensu/state/` remained gone after run.

### Step S2 — Retrofit run-eval.sh

- [x] **RED-REPRO**: Ran `bash evals/tdd-review-chain/run-eval.sh --self-check` from a clean state. 20/21 PASS (1 unrelated `assert-version.sh` failure) but `~/.zensu/state/rounds-unknown.json` appeared. Bug confirmed.
- [x] **FIX**: Inserted the same 3-line isolation block directly after `set -u` (line 23 → now lines 25-27). Trap is armed before any subshell echo to the hook.
- [x] **GREEN**: Re-ran. 20/21 PASS preserved (same out-of-scope `assert-version.sh` failure as the unmodified baseline), `~/.zensu/state/` remained gone after run.

## Final Verification

- [x] `bash evals/config-gate/run-eval.sh` — 38/38 PASS (regression preserved)
- [x] `bash evals/tdd-review-chain/assert-severity-routing.sh` — 17/17 PASS
- [x] `bash evals/tdd-review-chain/run-eval.sh --self-check` — 20/21 PASS (1 pre-existing FAIL on `assert-version.sh`, unrelated)
- [x] After ALL runs: `ls /Users/marcelkarras/.zensu/state/ 2>/dev/null` empty (directory gone)
- [x] `grep -rln "post-review-tdd-delegate" evals/` audit:
  - 9 config-gate sites — ALL already isolated (round-2 work).
  - `evals/tdd-review-chain/assert-changelog.sh` — only reads CHANGELOG.md, no hook invocation. Safe.
  - `evals/tdd-review-chain/assert-config.sh` — invokes the OLD `post-tdd-review-delegate.sh` (verified by `grep STATE_DIR\|CLAUDE_PLUGIN_DATA\|rounds-` returning empty for that script) which does NOT write state. Confirmed by isolated run: `~/.zensu/state/` remained gone. Safe.
  - `evals/tdd-review-chain/assert-severity-routing.sh` + `evals/tdd-review-chain/run-eval.sh` — FIXED this cycle.
- [x] ShellCheck on modified files: matches the round-2 baseline pattern (SC2155 informational on the `export CLAUDE_PLUGIN_DATA="$(mktemp -d)"` line is the established convention from `test-no-pluginroot-env.sh`; SC2164 on `run-eval.sh:64` is PRE-EXISTING in the unmodified `cd "$PLUGIN_DIR"` line, not introduced by this diff).
- [x] No commits — user reviews + commits manually (per Phase-B spec rule)
