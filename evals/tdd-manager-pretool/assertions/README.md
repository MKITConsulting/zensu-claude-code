# tdd-manager-pretool Assertions

Reference for each post-hoc assertion script in this directory. Each script reads a transcript file and exits non-zero when its specific check fails. Scripts are intentionally narrow: they catch one class of issue and trust the rest of the test suite for the others.

## assert-no-shell-redirect-bypass.sh

**Catches** (lexical patterns in transcript text):

- shell stdout redirect: `>` and `>>` (surrounded by whitespace on at least one side)
- in-place edit: `sed -i`
- pipe-to-file: `tee `

**Whitelist**: lines matching `zensu-log.sh` are ignored — that is the documented helper path for writing phase markers.

**Does NOT catch** (intentional — out of scope):

- `python -c "open(...).write(...)"`
- `node -e 'require("fs").writeFileSync(...)'`
- `ruby -e 'File.open(...)'`
- `perl -e` / `perl -pi -e`
- `cp`, `mv`, `install`, `rsync`
- `awk -i inplace`
- `patch`, `git apply`
- `dd  of=` (with double space)
- quoted inner redirects (`sh -c "echo >foo"`) where the outer text does not contain the pattern
- no-space redirects (`echo hi;echo>foo.ts`)

This is a deliberate scope: post-hoc transcript scanning cannot enumerate every interpreter that writes files. The defense-in-depth for `tdd-manager` drift is the agent's prompt discipline (Principle 1 in `agents/tdd-manager.md`), the PreToolUse gate on `Edit|Write|MultiEdit` (`hooks/pre-edit-tdd-reminder.sh`), and the PostToolUse code-reviewer chain with mtime audit (Phase 6 step 5 of `agents/tdd-manager.md`). This script is a low-cost lexical canary that catches the most common drift pattern (`echo > file`, `>> file`, `sed -i`) — not a security boundary.

## assert-no-gate-fired.js

Asserts that no PreToolUse gate denial entries appear in the transcript. Used by scenarios that should never trip the gate (e.g. correct-FSM happy path).

## assert-gate-recovered.js

Asserts that after a gate denial, the next agent action is a corrective phase marker (RED_WRITE, RED_FAIL, etc.) and not retry-of-same-edit.

## assert-phase-sequence.js

Asserts the transcript shows a valid phase FSM transition pattern: `RED_WRITE → RED_RUN → RED_FAIL → IMPL → GREEN_RUN → GREEN_PASS` (or REFACTOR loop).

## assert-backward-compat.sh

Used by the regression suite to verify that the gate is silent for non-`zensu:tdd-manager` agent contexts (main thread, other subagents, plain-Edit no-context).
