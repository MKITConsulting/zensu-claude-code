# TDD Plan: Review-Fix Cycle — Post-Review Delegate Hardening

## Context

Three review findings on `hooks/post-review-tdd-delegate.sh` (Phase-B feature, branch `feat/project-local-config-and-suggestion-routing`):

1. **Test pollution**: `evals/config-gate/test-no-pluginroot-env.sh` invokes the modified hook without isolating `CLAUDE_PLUGIN_DATA`. Result: counter state leaks into the real `$HOME/.zensu/state/rounds-unknown.json`. Falsifies the Phase-B claim "no mutation of real `~/.zensu/`".

2. **Unsanitized `SESSION_ID`** interpolated into filesystem paths (lines 53, 68). Session id containing `/` or `..` can escape `STATE_DIR`, and `mktemp` failures are swallowed silently — corrupted session_id silently disables the loop guard.

3. **Misleading comment** (line 12): says counter lives at `$CLAUDE_PLUGIN_DATA/...` but implementation falls back to `$HOME/.zensu/state` when `CLAUDE_PLUGIN_DATA` is unset.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash hooks + node-eval JSON | **Test runner**: shell scripts (`bash evals/config-gate/test-*.sh`) | **Coverage**: SKIPPED (no coverage tooling for shell scripts)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Bug Fix | Retrofit `test-no-pluginroot-env.sh` with `CLAUDE_PLUGIN_DATA` isolation (mktemp dir + trap EXIT cleanup). Delete the leaked `~/.zensu/state/rounds-unknown.json`. | evals/config-gate/test-no-pluginroot-env.sh (self-test) | — | [G] | 1 |
| S2 | Feature | Add `test-autofix-rounds-sanitize.sh`: feed malicious session_id `../../../tmp/escape` and assert counter lands inside isolated `CLAUDE_PLUGIN_DATA`, not outside. | evals/config-gate/test-autofix-rounds-sanitize.sh | S1 | [G] | 1 |
| S3 | Bug Fix | Sanitize `SESSION_ID` in `hooks/post-review-tdd-delegate.sh` via `${SESSION_ID//[^A-Za-z0-9_-]/_}`. Add explicit exit-code checks on `mktemp` and `mv`: on `mktemp` failure fall through to a safe path (write directly to `COUNTER_FILE` or skip increment with `>&2` warning). | evals/config-gate/test-autofix-rounds-sanitize.sh + existing test-autofix-rounds-*.sh | S2 | [G] | 1 |
| S4 | Refactor | Update file-header comment (line 12) to mirror implementation: `# Counter state lives at ${CLAUDE_PLUGIN_DATA:-$HOME/.zensu/state}/rounds-<session_id>.json`. | manual grep verification | S3 | [RF] | 1 |
| S5 | Wire | Register `test-autofix-rounds-sanitize.sh` in `run-eval.sh` under the Auto-fix flag section. | self-check exit code | S2 | [W] | 1 |

**Checkpoints**: Run `bash evals/config-gate/run-eval.sh`; expect all green at end. After run, `ls ~/.zensu/state/ 2>/dev/null` must return empty. ShellCheck on `hooks/post-review-tdd-delegate.sh` clean.

### Step S1 — Retrofit test-no-pluginroot-env.sh isolation
- [x] **RED-REPRO**: Run `test-no-pluginroot-env.sh`; verify it currently leaks `~/.zensu/state/rounds-unknown.json` (proof: the leaked file is the assertion target). Bug observed = test currently lacks `CLAUDE_PLUGIN_DATA` env.
- [x] **FIX**: Add `export CLAUDE_PLUGIN_DATA="$(mktemp -d)"` + `cleanup() { rm -rf "$CLAUDE_PLUGIN_DATA"; }` + `trap cleanup EXIT` matching the pattern in `test-gate-postreview.sh`. Delete the existing leaked file at `$HOME/.zensu/state/rounds-unknown.json`.
- [x] **GREEN**: Re-run `test-no-pluginroot-env.sh`; all 4 assertions still pass. Then verify `ls ~/.zensu/state/ 2>/dev/null` returns empty.

### Step S2 — RED test for session_id sanitization (test-autofix-rounds-sanitize.sh)
- [x] **RED**: Write `test-autofix-rounds-sanitize.sh`:
  - tmp `CLAUDE_PLUGIN_DATA` via `mktemp -d`
  - stdin fixture with `session_id="../../../tmp/escape-XYZ"`
  - invoke hook once
  - assert: `find "$CLAUDE_PLUGIN_DATA" -name 'rounds-*.json' -type f` returns exactly 1 file
  - assert: `find /tmp -name 'escape-XYZ*' -type f` returns 0 files (no escape outside isolation)
  - assert: hook exit code is 0
  - The test FAILS because the current hook would create a path like `$STATE_DIR/rounds-../../../tmp/escape-XYZ.json` which resolves outside `$CLAUDE_PLUGIN_DATA`.

### Step S3 — Sanitize SESSION_ID + harden mktemp/mv
- [x] **FIX**: After the `node -e` SESSION_ID parse, add `SESSION_ID="${SESSION_ID//[^A-Za-z0-9_-]/_}"`. Then add explicit error checks on `mktemp` and `mv`: if `mktemp` fails or `mv` fails, emit a `>&2` warning and skip the counter update (the loop guard degrades to "always allow" for this single invocation, which is the safer default than silently corrupting state).
- [x] **GREEN**: Re-run `test-autofix-rounds-sanitize.sh` (now passes), all existing `test-autofix-rounds-*.sh` still pass.

### Step S4 — Update misleading file-header comment
- [x] **RF (GREEN-BEFORE)**: Run full eval; all green.
- [x] **CHANGE**: Update line 12 to `# Counter state lives at ${CLAUDE_PLUGIN_DATA:-$HOME/.zensu/state}/rounds-<session_id>.json.`
- [x] **GREEN-AFTER**: Re-run full eval; all green still.

### Step S5 — Wire new test into run-eval.sh
- [x] **W**: Append `run_test "$EVAL_DIR/test-autofix-rounds-sanitize.sh" "test-autofix-rounds-sanitize.sh"` under the Auto-fix section in `run-eval.sh`.

## Final Verification
- [x] `bash evals/config-gate/run-eval.sh` all green (38/38 PASS, 0 FAIL)
- [x] `ls ~/.zensu/state/ 2>/dev/null` returns empty (directory does not exist)
- [x] ShellCheck on `hooks/post-review-tdd-delegate.sh` clean (status unchanged from HEAD baseline — pre-existing SC1091 info only)
- [x] No commits — user reviews + commits manually
