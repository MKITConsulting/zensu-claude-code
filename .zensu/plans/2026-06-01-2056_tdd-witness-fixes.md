# TDD Plan: Witness log — fix corruption, plan-bloat, verbosity

## Context
The TDD Bash-witness (`.zensu/logs/witness-<session>.log`) is the anti-hallucination
evidence trail Phase 6 cross-checks via `grep cmd="X"`. Three defects, observed in a
real downstream session, make it corrupt and bloated:

1. Field-split corruption under non-bash shells. `hooks/post-bash-witness.sh` parses
   node output with `IFS=$'\x01' read -r ... <<<` (bashisms). Reproduced: under
   `/bin/sh` all fields collapse into `cmd` → empty `exit=`/`tail=`, session-id bleeds
   into `cmd=`. Kills the exit code the cross-check relies on.
2. Whole plan-MD files embedded in `cmd=` (biggest bloat). The phase-gate denies Write
   while `phase=UNINITIALIZED`, so SKILL Phase 2 writes the plan via `cat > plan.md
   <<EOF`. The witness records every Bash `cmd=` verbatim → ~60-line plan in one entry.
3. Unused `tail=` field. Cross-check only greps `cmd=`; tail is pure verbosity.

Plus: this plugin gitignores `witness-*.log` but the timesheetly consumer repos do not.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + node hooks; bash structure
tests (`bash tests/structure/<f>.sh`) | **Coverage**: SKIPPED (no coverage tool for
shell; N/A)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present | — |
| bash | CLI | `command -v bash` | present | — |
| sh | CLI | `command -v sh` | present | — |
| dash | CLI | `command -v dash` | present | — |
No secrets/endpoints/fixtures required.

## Status Legend
| [ ] Not started | [R] RED | [I] Impl | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Bug Fix | post-bash-witness.sh: newline-delimited tempfile parse (Apple bash 3.2 breaks IFS=$'\x01' read <<<) | tests/structure/test-post-bash-witness.sh | — | [G] | 0 |
| S2 | Feature | post-bash-witness.sh: drop tail= segment from the witness line | tests/structure/test-post-bash-witness.sh | S1 | [G] | 0 |
| S3 | Feature | pre-edit-tdd-reminder.sh: allow Edit/Write to any */.zensu/* path regardless of phase | tests/structure/test-pre-edit-hook-mirror.sh | — | [G] | 0 |
| S4 | Feature | SKILL.md Phase 2: create plan via Write tool (not Bash heredoc); flip MT5 assertion | tests/structure/test-tdd-manager-patches.sh | S3 | [G] | 0 |
| S5 | Integration | version bump 0.6.0 -> 0.6.1 (plugin.json, marketplace.json, README badge, CHANGELOG) | (version-badge structure test) | S1,S2,S3,S4 | [W] | 0 |

### Step S1 — newline-delimited field parse (Apple bash 3.2 fix)
- [G] RED: invoke hook via `/bin/sh "$HOOK"` (= Apple bash 3.2) with active TDD state; assert witness line has `exit=0` AND does not contain the session id. Failed: bash 3.2 split collapses all fields into cmd, losing the session.
- [G] GREEN: node emits fields newline-delimited; bash reads them from a temp file with plain `read` (no `IFS=$'\x01'`, no `<<<`). Verified under bash 3.2, bash 5, and dash.
**Checkpoint**: bash tests/structure/test-post-bash-witness.sh

### Step S2 — drop tail field
- [ ] RED: assert the witness line has no ` tail=` segment. Fails today: format includes tail.
- [ ] GREEN: print `[%s] BASH cmd=%s exit=%s\n` (drop TAIL_JSON). Existing H7 cmd-extractor still round-trips (regex anchors on ` exit=`).
**Checkpoint**: bash tests/structure/test-post-bash-witness.sh

### Step S3 — gate allows .zensu/ paths
- [ ] RED: payload tool=Write file_path=.zensu/plans/x.md, phase=UNINITIALIZED, active session → assert ALLOWED (exit 0, no deny JSON). Fails today: UNINITIALIZED denies.
- [ ] GREEN: in pre-edit-tdd-reminder.sh after FILE_PATH parse, `case "$FILE_PATH" in */.zensu/*) exit 0 ;; esac`.
**Checkpoint**: bash tests/structure/test-pre-edit-hook-mirror.sh

### Step S4 — plan via Write tool + flip MT5
- [ ] RED: MT5 asserts SKILL creates the plan via the Write tool (not `cat > .zensu/plans`). Fails today: SKILL still uses heredoc.
- [ ] GREEN: rewrite SKILL.md Phase 2 gate-note + step 1 to use the Write tool (Write not witnessed); update MT5 assertion accordingly.
**Checkpoint**: bash tests/structure/test-tdd-manager-patches.sh

### Step S5 — version bump (WIRED)
- [ ] WIRED: 0.6.0 -> 0.6.1 in plugin.json + marketplace.json + README badge + CHANGELOG (CLAUDE.md release checklist). Verified by the version-badge structure test.

## Final Verification
- [ ] bash tests/structure/test-post-bash-witness.sh + test-pre-edit-hook-mirror.sh + test-tdd-manager-patches.sh green
- [ ] Full tests/structure/*.sh suite green
- [ ] Manual: `printf '<payload>' | sh hooks/post-bash-witness.sh` (active state) -> clean exit=0, no tail, no session leak
- [ ] Coverage: SKIPPED (no shell coverage tool)
- [ ] Follow-up (separate, outside this repo): witness-*.log in timesheetly .gitignore
