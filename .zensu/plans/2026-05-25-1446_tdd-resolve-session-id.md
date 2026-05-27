# TDD Plan: Cross-platform multi-session-safe Claude session-id resolution

## Context

The zensu plugin's TDD-Manager subagent issues `bash zensu-log.sh --phase X --step Y`
calls to record TDD phase transitions. The `zensu-log.sh` script writes state to
`.zensu/state/tdd-phase-<sessionId>.json` and needs to know the current Claude
session UUID.

Current implementation in `hooks/lib/zensu-session.sh` uses a PPID-derived cache key.
This breaks because each subagent bash subprocess has a different PPID than the
SessionStart hook that wrote the cache, so the cache lookup never resolves and we
fragment into multiple `tdd-phase-fallback_*.json` files.

Approach: add a Node helper that reads `~/.claude/projects/<sanitized-cwd>/*.jsonl`
mtimes (newest-mtime heuristic), with two race-hardening layers: BASH_START
nanosecond cutoff and ZENSU_OWN_CMD cmdline match. Insert the helper as the new
priority-2 resolver in `zensu_resolve_session_id`. Preserve the PPID cache as
priority-3 fallback for environments without a projects dir.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + Node.js 23 |
**Coverage**: SKIPPED (no coverage tool in repo)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI  | `command -v node` | present (v23.11.0) | use as-is |
| bash | CLI  | `command -v bash` | present | use as-is |

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Single .jsonl → returns its UUID | tests/structure/test-resolve-session-id.sh | — | [G] | 1 |
| S2 | Feature | Multiple .jsonl, no BASH_START → newest by mtime | tests/structure/test-resolve-session-id.sh | S1 | [G] | 1 |
| S3 | Feature | BASH_START filters out files written after bash start | tests/structure/test-resolve-session-id.sh | S2 | [G] | 2 |
| S4 | Feature | Multiple candidates within window + cmdline match disambiguates | tests/structure/test-resolve-session-id.sh | S3 | [G] | 1 |
| S5 | Feature | Empty projects dir → empty output, exit 0 | tests/structure/test-resolve-session-id.sh | S1 | [G] | regression guard (covered by S1 IMPL) |
| S6 | Feature | Missing projects dir → empty output, exit 0 | tests/structure/test-resolve-session-id.sh | S5 | [G] | regression guard (covered by S1 IMPL) |
| S7 | Feature | Project-dir sanitization for nested path | tests/structure/test-resolve-session-id.sh | S1 | [G] | mutation-test verified |
| W1 | Integration | Wire helper into zensu_resolve_session_id as priority-2 path | hooks/lib/zensu-session.sh | S1..S7 | [G] | 1 |
| W2 | Integration | Export ZENSU_BASH_START + ZENSU_OWN_CMD from zensu-log.sh --phase | hooks/lib/zensu-log.sh | W1 | [G] | 2 sub-tests mutation-verified |

### Step S1 — Single .jsonl → returns its UUID
- [ ] **RED**: Test `S1 single .jsonl returns UUID` — fails because `hooks/lib/resolve-session-id.js` does not yet exist (Node "Cannot find module").
- [ ] **GREEN**: Create `hooks/lib/resolve-session-id.js` minimal implementation that lists .jsonl files in the sanitized projects dir and prints the first one's UUID.

### Step S2 — Multiple .jsonl, no BASH_START → newest by mtime
- [ ] **RED**: Test `S2 multiple .jsonl returns newest by mtime` — fails because the S1 minimal impl returns the first listed (alphabetical), not the newest by mtime.
- [ ] **GREEN**: Sort candidates by `mtimeMs` desc, return UUID of first.

### Step S3 — BASH_START filters out files written after bash start
- [ ] **RED**: Test `S3 BASH_START filters out future-mtime files` — fails because S2 impl does not consider `argv[2]` BASH_START at all.
- [ ] **GREEN**: When `argv[2]` provided (ns string), parse to ms (`/ 1_000_000n`) and filter candidates to `mtime_ms <= cutoff_ms` before sorting.

### Step S4 — Multiple candidates within window + cmdline match disambiguates
- [ ] **RED**: Test `S4 ZENSU_OWN_CMD tail-match wins over newest` — fails because S3 impl returns newest regardless of cmdline.
- [ ] **GREEN**: If filtered candidate list has > 1 entry AND `ZENSU_OWN_CMD` set, read last 4096 bytes of each (newest mtime first), return first whose tail contains the env value as substring.

### Step S5 — Empty projects dir → empty output, exit 0
- [ ] **RED**: Test `S5 empty projects dir prints empty exits 0` — fails because earlier impl may crash (`undefined.split(...)`) or exit nonzero when no .jsonl files match.
- [ ] **GREEN**: Defensive: if filtered candidate list is empty, print "" and exit 0.

### Step S6 — Missing projects dir → empty output, exit 0
- [ ] **RED**: Test `S6 missing projects dir prints empty exits 0` — fails because earlier impl will throw on `readdirSync` of non-existent path.
- [ ] **GREEN**: Wrap `readdirSync` in try/catch; on ENOENT return empty list.

### Step S7 — Project-dir sanitization for nested path
- [ ] **RED**: Test `S7 nested path is sanitized to dash form` — fails if helper does not derive `-Users-foo-repo` style key from `CLAUDE_PROJECT_DIR`.
- [ ] **GREEN**: Apply replacement: `'/Users/foo/repo' -> '-Users-foo-repo'` (`/`,`\`,`:` → `-`). Use that as the projects subdir.

**Checkpoint**: `bash tests/structure/test-resolve-session-id.sh` shows 7+ PASS / 0 FAIL.

### Step W1 — Wire helper into zensu_resolve_session_id
- [ ] Add `zensu_resolve_session_via_helper` function that calls the Node helper.
- [ ] Modify `zensu_resolve_session_id` to insert helper as priority-2 (between stdin-from-json and PPID-cache).

### Step W2 — Export ZENSU_BASH_START + ZENSU_OWN_CMD from zensu-log.sh
- [ ] In the `--phase` branch, before calling `zensu_resolve_session_id`, export the two env vars so the helper has Layer 1 + Layer 2 signals.

**Checkpoint**: existing `test-session-id-fallback.sh` still 14/14 PASS, and helper test 7+/7 PASS.

## Final Verification

- [ ] `bash tests/structure/test-resolve-session-id.sh` — 7+/7 PASS
- [ ] `bash tests/structure/test-session-id-fallback.sh` — 14/14 PASS (no regression)
- [ ] `bash tests/structure/test-post-bash-witness.sh` — no regression
- [ ] `bash tests/structure/test-pre-edit-hook-mirror.sh` — no regression
- [ ] `bash -n` clean on all modified bash scripts
- [ ] Manual smoke: invoke `bash hooks/lib/zensu-log.sh --phase RED_WRITE --step DEMO` twice in a row → stable state-file name.
