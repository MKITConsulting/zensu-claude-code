# TDD Plan: Operational Fixes Round (post-merge)

## Context

Precondition handling landed in commit `6d64366`. The first full promptfoo
pretool suite run was started at 09:53AM at `maxConcurrency: 1`. Two issues
were discovered during that run and the user wants them fixed before
restarting the suite at `maxConcurrency: 5`:

1. `file-exists` is NOT a native promptfoo assertion type. Four occurrences
   across three scenario YAMLs produce "Unknown assertion type: file-exists"
   errors and prevent those scenarios from executing. Replace with a
   `type: javascript` assertion using Node's `fs.existsSync`.
2. `evaluateOptions.maxConcurrency` is currently `1`. Bump to `5`. The user
   explicitly accepts the race risk on the shared
   `working_dir: ./test-projects/react-go-fullstack`.

Before the new run can start, the currently active background subprocesses
(promptfoo PID 37770 and the claude subprocess PID 59896 it spawned) MUST
be terminated.

**Out of scope:** the Patch 1-7 work from the earlier plan. That landed in
commit `6d64366` already.

**Approach**: Strict Red/Green TDD for the two YAML edits (S2, S3).
S1, S4, S5 are integration steps (process kill, background-run kickoff,
observability check).

**Tech Stack**: bash, YAML, Markdown (no compiled artifacts).
**Test Runner**: bash structure tests under `tests/structure/`.
**Coverage**: SKIPPED — bash structure tests are presence/absence checks on
text files; line-coverage instrumentation does not meaningfully apply.

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| `claude` CLI | tool | `command -v claude` -> v2.1.148 | OK | proceed |
| `promptfoo` CLI | tool | `command -v promptfoo` | OK | proceed |
| `jq` CLI | tool | `command -v jq` | OK | proceed |
| `evals/tdd-manager-pretool/` dir | path | `[ -d ... ]` | OK | proceed |
| Wrapper executable | path | `[ -x scripts/claude-promptfoo-wrapper.sh ]` | OK | proceed |
| `claude login` | auth | `claude --version` succeeds | OK | proceed |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | [W] | Cancel current promptfoo + claude subprocess; remove rc-files | (none) | (none) | [W] | 1 |
| S2 | [G] | Replace 4x `file-exists` -> javascript+fs.existsSync | tests/structure/test-file-exists-replacement.sh | S1 | [G] | 1 |
| S3 | [G] | Bump `maxConcurrency: 1` -> `5` in promptfooconfig-pretool.yaml | tests/structure/test-promptfoo-concurrency.sh | S1 | [G] | 1 |
| S4 | [W] | Kick off full suite at concurrency 5 in background | (none) | S2, S3 | [W] | 1 |
| S5 | [W] | Confirm test-project `.zensu/` is populated, surface counts | (none) | (none) | [W] | 1 |

### Step S1 — Cancel current run

Integration step. No RED/GREEN cycle.

- `pkill -f 'promptfoo eval -c promptfooconfig-pretool.yaml'`
- `pkill -f 'claude --print --output-format json'`
- `rm -f /tmp/full-suite.rc /tmp/full-suite.json /tmp/full-suite.log`
- Verify `ps aux | grep -E 'promptfoo eval|claude --print' | grep -v grep`
  returns empty.

### Step S2 — Replace `file-exists` assertions

- [G] **RED**: `tests/structure/test-file-exists-replacement.sh` greps the 3
  scenario files for `type: file-exists` (expects 0 after fix) and for
  `fs.existsSync` (expects 4 after fix). RED expected: 4 file-exists, 0 fs.existsSync
  -> FAIL. Confirmed: 4 PASS / 5 FAIL on initial run.
- [G] **IMPL**: Edited the three YAMLs. Replaced each `- type: file-exists\n  value: "<path>"`
  block with a `- type: javascript\n  value: |\n    const fs = require('fs');\n    const filePath = '<path>';\n    const pass = fs.existsSync(filePath);\n    return { pass, score: pass ? 1 : 0, reason: ... };`
  block. Indentation preserved. Path preserved verbatim (already relative to
  promptfoo's cwd).
- [G] **GREEN**: re-ran RED test -> 9/9 PASS (0 file-exists, 4 fs.existsSync).
  YAML parses OK across all 3 scenarios.

### Step S3 — Bump maxConcurrency

- [G] **RED**: `tests/structure/test-promptfoo-concurrency.sh` greps for
  `maxConcurrency: 5` in `promptfooconfig-pretool.yaml`. RED expected: line is
  `maxConcurrency: 1` -> FAIL. Confirmed: 2 PASS / 1 FAIL on initial run.
- [G] **IMPL**: Edited the line `maxConcurrency: 1` -> `maxConcurrency: 5`.
- [G] **GREEN**: re-ran RED -> 3/3 PASS.

### Step S4 — Kick off full suite

Integration. Background invocation:

```bash
cd evals/tdd-manager-pretool
rm -f /tmp/full-suite2.json /tmp/full-suite2.log /tmp/full-suite2.rc
(promptfoo eval -c promptfooconfig-pretool.yaml --no-cache --no-progress-bar --repeat 1 --output /tmp/full-suite2.json > /tmp/full-suite2.log 2>&1; echo $? > /tmp/full-suite2.rc) &
echo "Started PID $!"
```

Log the PID, exit. Caller monitors completion.

### Step S5 — Confirm test-project zensu logs

Integration / observability check. Surface counts:

```bash
ls -la evals/tdd-manager-pretool/test-projects/react-go-fullstack/.zensu/
ls evals/tdd-manager-pretool/test-projects/react-go-fullstack/.zensu/plans/ | wc -l
ls evals/tdd-manager-pretool/test-projects/react-go-fullstack/.zensu/logs/ | wc -l
```

**Checkpoint**: After S2 + S3, run the two new structure tests AND
`tests/structure/test-tdd-manager-patches.sh` to confirm no regression.

## Final Verification

- [x] S1: `ps aux | grep -E 'promptfoo eval|claude --print' | grep -v grep` empty
- [x] S2: structure test passes (0 file-exists, 4 fs.existsSync, YAML parses OK)
- [x] S3: structure test passes (`maxConcurrency: 5`)
- [x] S4: background PID 68766 logged; suite reports "Running 13 test cases (up to 5 at a time)"
- [x] S5: test-project `.zensu/` populated: 15 plans, 15 logs, state/ subdir
- [x] Existing structure tests still pass (no regression): 51/51 across all 5 test files
- [x] mtime discipline: 2/2 Feature steps PASS (test written before impl)

## Audit Summary

- **Build**: n/a (plugin repo, no compiled artifacts; bash + YAML + Markdown only)
- **Coverage**: SKIPPED (bash structure tests are presence/absence checks; line coverage not meaningful)
- **mtime discipline**: 0/2 violations
- **Full structure suite**: 51/51 PASS
