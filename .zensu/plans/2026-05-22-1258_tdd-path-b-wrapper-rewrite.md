# TDD Plan: Path B Hybrid — Wrapper Rewrite for Isolation + Stream-JSON

## Context

Path B from a 3-path evaluation: fix promptfoo eval suite race conditions and stream-mismatch in a wrapper-only change. Add APFS clone isolation, switch to `--output-format stream-json` with transcript concatenation, replace inline `fs.existsSync` JS with external `file://` assertion, loosen drift-audit regex for word variance.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + YAML + JS (Node) + promptfoo | **Coverage**: SKIPPED (no coverage tool wired in bash structure tests)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Preconditions

| Item | Verified | Status |
|---|---|---|
| claude CLI | `command -v claude` present | OK |
| promptfoo CLI | `command -v promptfoo` present | OK |
| jq CLI | `command -v jq` present | OK |
| macOS APFS | uname=Darwin, `cp -c` flag in usage | OK |
| evals dir | present | OK |
| wrapper script | present + executable | OK |
| stream-json claude flag | `--output-format stream-json` + `--include-partial-messages` documented in claude --help | OK |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Wrapper isolation logic (cp -cR/-R clone, KEEP_ISOLATED, trap cleanup) | tests/structure/test-claude-promptfoo-wrapper.sh | — | [G] | 2 |
| S2 | Feature | Wrapper stream-json output concatenation via jq | tests/structure/test-claude-promptfoo-wrapper.sh | S1 | [G] | 1 |
| S3 | Feature | External `assert-file-exists.js` + scenario refactor | tests/structure/test-file-exists-replacement.sh | — | [G] | 1 |
| S4 | Bug Fix | Drift-audit assertion #3 regex word variance | new tests/structure/test-drift-audit-regex.sh | — | [G] | 1 |
| S5 | Integration | Run all structure tests + manual wrapper smoke | — | S1,S2,S3,S4 | [W] | 1 |
| S6 | Integration | Kick off full promptfoo suite (background) | — | S5 | [W] | 1 |
| S7 | Integration | Surface status to parent session | — | S6 | [W] | 1 |

### Step S1 — Wrapper isolation logic

- [G] **RED**: Add case P7-S10 to `tests/structure/test-claude-promptfoo-wrapper.sh` — DRY_RUN preview shows cp clone + cd into `/tmp/claude-eval-*` (NOT the input WORKDIR). Test FAILS because current wrapper has no isolation.
- [G] **IMPL**: After preflight, derive `ISOLATED_DIR=$(mktemp -d -t "claude-eval-XXXXXX")`. Detect `cp -c` support, pick `cp -cR` or `cp -R`. Replace `cd "$WORKDIR"` with `cd "$ISOLATED_DIR"`. Add `KEEP_ISOLATED` env var hook with `trap`-based cleanup. DRY_RUN prints what would happen.

### Step S2 — Wrapper stream-json output concatenation

- [G] **RED**: Add case P7-S11 — PATH-shadow `claude` with a stub emitting 3 stream-json events (system + assistant + result). Wrapper should concat and emit assistant text + tool_use markers. Test FAILS because wrapper still uses `--output-format json`.
- [G] **IMPL**: Replace `claude --print --output-format json` invocation with `claude --print --output-format stream-json --include-partial-messages` piped through jq filter (slurp + filter + join).

### Step S3 — External assert-file-exists.js + scenario refactor

- [G] **RED**: Extend `tests/structure/test-file-exists-replacement.sh` with NEW assertions for the new state: assertion checks `assertions/assert-file-exists.js` exists + exports module.exports function; scenarios 01/02/09 contain `file://assertions/assert-file-exists.js` and `expected_paths` var; ZERO inline `fs.existsSync` blocks remain (current 4 → 0). Test FAILS because file is absent and scenarios are inline.
- [G] **IMPL**: Create `evals/tdd-manager-pretool/assertions/assert-file-exists.js`. Refactor 01-happy-frontend.yaml, 02-happy-backend.yaml, 09-cross-stack.yaml to use file:// assertion + add `expected_paths` to vars.

### Step S4 — Drift-audit regex word variance

- [G] **RED**: Create new `tests/structure/test-drift-audit-regex.sh` — exec a tiny node snippet that loads the regex from `precondition-drift-audit.yaml` (or applies it inline) against two fixture strings: "audit only" (space) and "no files implemented or changed". Both currently FAIL the regex.
- [G] **FIX**: Update assertion #3 regex in `precondition-drift-audit.yaml` to `/zero file changes|audit[- ]only|no.*(implementation|implement|files modified|files changed)|Phase 6 NOT complete|audit FAIL/i`.

### Step S5 — Integration verify

- [W] All structure tests PASS (wrapper, file-exists, patches, drift-audit-regex). Manual smoke against wrapper with `KEEP_ISOLATED=1` confirms isolated dir creation + content copy.

### Step S6 — Full promptfoo suite

- [W] Background launch with `--no-cache --no-progress-bar --repeat 1 --output /tmp/full-suite3.json`. Log PID + log path. DO NOT block on completion.

### Step S7 — Surface status

- [W] Report wrapper isolation status, KEEP_ISOLATED env var doc, test counts, background PID + log path.

**Checkpoint**: After S1+S2+S3+S4 — all structure tests PASS. After S5 — manual smoke OK. After S6 — background PID logged.

## Final Verification
- [W] All structure test suites pass (wrapper 14 + file-exists 16 + patches 21 + drift-audit-regex 3 + pretool-config 7 + concurrency 3 = 64 tests, 6 suites)
- [W] Wrapper isolation verified via manual smoke (KEEP_ISOLATED=1, content copied, dir survives)
- [W] Coverage: SKIPPED (no coverage tool wired for bash structure tests)
- [ ] Plan + log committed to `.zensu/plans/` and `.zensu/logs/` (final task, user decides commit)
