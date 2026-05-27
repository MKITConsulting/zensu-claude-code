# TDD Plan: Code Review Findings on resolve-session-id.js

## Context

Three code-review findings against `hooks/lib/resolve-session-id.js`:

1. **F1 — `sanitizeProjectDir` denylist regex (line 9).** Current regex
   `/[\/\\:.]/g` is a denylist of 4 chars. If Claude Code ships a CWD
   containing space, `~`, `#`, parens, or non-ASCII chars, the helper produces
   the wrong projects-subdir name and falls through to the broken PPID cache.
   Wrapper `hooks/lib/zensu-session.sh:29` already uses an allowlist on the
   helper's stdout; mirror that for the helper's input sanitization. Switch to
   `return String(p).replace(/[^A-Za-z0-9_-]/g, '-');`. Verify current
   worktree's CWD still resolves to subdir
   `-Users-marcelkarras-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-thirsty-elbakyan-eaba92`.

2. **F2 — `helperStartMs = Date.now()` widens Layer-1 cutoff window (line 71).**
   Captured at `main()` entry, after ~30-50ms node cold-start. Hot multi-session
   projects can have a concurrent session's `.jsonl` write slip into the cutoff
   window. Layer-2 (`ZENSU_OWN_CMD` tail-match) remains the deterministic safety
   net. NO source code change — repo bans comments. Plan/log carries the design
   rationale. Add a regression test that places 2 candidates within the cutoff
   window with distinct cmdlines and confirms Layer-2 picks the matching one.

3. **F3 — `parseCutoffMs` length guard (lines 40-49).** Accepts any all-digit
   string and divides by `1_000_000n` (ns→ms). A 10-13-digit millisecond-style
   value becomes a near-zero ms value (e.g. `1779715299` ms / 1e6 = 1779ms = ~1970)
   and filters EVERYTHING out, forcing fall-through to the broken PPID cache.
   Not exploitable today (caller passes empty string), but regression footgun.
   Fix: reject all-digit strings shorter than 18 chars and return null so helper
   self-inits via `Date.now()`. Add RED test passing a 13-digit ms-style value.

**Approach**: Strict Red/Green TDD | **Tech Stack**: Node.js helper + bash shell tests
| **Coverage**: SKIPPED — bash + node-as-shell tooling has no coverage runner wired

## Design rationale — Layer-1 + Layer-2 disambiguation (for finding F2)

The helper resolves a Claude Code session UUID by listing all `*.jsonl` files
under `~/.claude/projects/<subdir>` and picking the newest mtime that is
`<= cutoff_ms`.

**Layer-1 (cutoff filter — best effort).** `helperStartMs = Date.now()` is
captured at `main()` entry, AFTER node's ~30-50ms cold-start latency. This
widens the cutoff window versus an in-bash `date +%s%N` capture. In hot
multi-session projects we have observed real-world `.jsonl` write gaps of 2.9ms
and 28.4ms between sibling sessions — a concurrent session's write CAN slip
inside the widened Layer-1 window. Layer-1 alone is therefore NOT a sufficient
disambiguator; it is a best-effort coarse filter.

**Layer-2 (cmdline tail-match — deterministic).** When Layer-1 returns more
than one candidate AND the caller provided `ZENSU_OWN_CMD` (a unique substring
that identifies the bash command currently emitting the log line), the helper
scans the tail of each candidate's `.jsonl` and picks the one containing that
needle. This is the deterministic disambiguator — Claude Code writes each
tool-invocation's serialized command to the session's `.jsonl`, so an exact
match identifies the owning session unambiguously.

**Future maintainer note.** Do NOT "tighten" Layer-1 by removing Layer-2
thinking it is redundant. Even a Layer-1 that captured `Date.now()` BEFORE node
cold-start would not be fully race-free: filesystem mtime resolution is OS- and
fs-dependent (1ms on APFS, 1s on legacy filesystems), and any concurrent write
inside the same OS mtime tick collides regardless. Layer-2 is the safety net,
Layer-1 is the optimization.

Verification: structure suite contains S4 (cmdline tail-match wins over newest
mtime when ZENSU_OWN_CMD provided) and the new F2-R test placing 2 candidates
within the cutoff window with distinct cmdlines.

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI  | `command -v node` | present (v23.11.0) | — |
| bash | CLI  | `command -v bash` | present (5.3.9)    | — |
| `~/.claude/projects/<subdir>` for current worktree | fixture | `ls ~/.claude/projects/-Users-marcelkarras-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-thirsty-elbakyan-eaba92/` | present (contains `a01473c3-c9cb-45ed-8d12-e00a548866ca.jsonl`) | — |

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| F1-R-space | Feature | RED: path containing space breaks denylist | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F1-R-tilde | Feature | RED: path containing `~` breaks denylist | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F1-R-hash  | Feature | RED: path containing `#` breaks denylist | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F1-R-paren | Feature | RED: path containing `(` `)` breaks denylist | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F1-R-smoke | Feature | RED+GREEN smoke: current worktree CWD still resolves to known subdir | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F1-IMPL    | Feature | Switch `sanitizeProjectDir` to allowlist `/[^A-Za-z0-9_-]/g` | `hooks/lib/resolve-session-id.js` | F1-R-* | [G] | 1 |
| F2-R       | Feature | Regression test: 2 candidates within cutoff window, distinct cmdlines — Layer-2 picks the matching one | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F3-R       | Feature | RED: 13-digit ms-style argv[2] currently filters everything out | `tests/structure/test-resolve-session-id.sh` | — | [G] | 1 |
| F3-IMPL    | Feature | Add length guard `< 18` in `parseCutoffMs` → return null | `hooks/lib/resolve-session-id.js` | F3-R | [G] | 1 |

### Step F1-R-space — RED: space in path breaks denylist subdir lookup
- [ ] **RED**: Test asserts `CLAUDE_PROJECT_DIR="/users/spaces are/repo"` resolves to its known UUID via projects subdir whose name is `-users-spaces-are-repo` (allowlist). Test creates that subdir under `ZENSU_PROJECTS_DIR` and a fixture `.jsonl`. With denylist it produces subdir `-users-spaces are-repo` which doesn't exist on disk → empty stdout → FAIL.
- [ ] **GREEN**: passes once F1-IMPL replaces the regex.

### Step F1-R-tilde — RED: `~` in path breaks denylist
- [ ] **RED**: Same as F1-R-space but `/users/~home/repo` → allowlist `-users--home-repo`.
- [ ] **GREEN**: same as F1-IMPL.

### Step F1-R-hash — RED: `#` in path breaks denylist
- [ ] **RED**: `/users/#dev/repo` → allowlist `-users--dev-repo`.
- [ ] **GREEN**: same as F1-IMPL.

### Step F1-R-paren — RED: `(` `)` in path breaks denylist
- [ ] **RED**: `/users/(branch)/repo` → allowlist `-users--branch--repo`.
- [ ] **GREEN**: same as F1-IMPL.

### Step F1-R-smoke — Real worktree CWD still resolves
- [ ] **RED**: Test asserts `CLAUDE_PROJECT_DIR="/Users/marcelkarras/IdeaProjects/dev.zensu/zensu-claude-code/.claude/worktrees/thirsty-elbakyan-eaba92"` resolves to subdir `-Users-marcelkarras-IdeaProjects-dev-zensu-zensu-claude-code--claude-worktrees-thirsty-elbakyan-eaba92`. (Both denylist and allowlist already produce this; this is a regression smoke to lock in the behavior.) Initially FAILS because no fixture in temp `ZENSU_PROJECTS_DIR` — once fixture is created, both regexes produce same name.
- [ ] **GREEN**: assertion passes verbatim against both regexes; no implementation change needed beyond F1-IMPL.

### Step F1-IMPL — Switch regex to allowlist
- [ ] Replace line 9 with `return String(p).replace(/[^A-Za-z0-9_-]/g, '-');`.

### Step F2-R — Regression test: Layer-2 disambiguator wins in widened cutoff window
- [ ] **RED**: Create 2 sibling `.jsonl`s, both with mtimes WITHIN the cutoff window (both `<= cutoffMs`). One contains `ZENSU_OWN_CMD` needle, the other doesn't. Newest-mtime wins by mtime ordering, but Layer-2 tail-match should override and pick the needle-bearing one. Initially asserts behavior already implemented (covered by S4 from a different angle: in S4 the needle file is OLDER mtime so Layer-2 effect is visible; F2-R places both within window where the NON-needle file is newer, so a regression where Layer-2 was disabled would pick the non-needle file). This is a passing regression — confirms Layer-2 is still wired.
- [ ] **GREEN**: passes immediately (no implementation change needed for F2).

### Step F3-R — RED: 13-digit ms-style argv[2] currently silently filters all
- [ ] **RED**: Create 2 sibling `.jsonl`s with realistic mtimes (`nowMs - 60s` and `nowMs - 30s`). Pass argv[2]=`1779715299000` (13-digit ms value). Current code converts via `BigInt / 1_000_000n` to `1779`ms (~1970), filters BOTH files (mtime > 1779ms cutoff), returns empty. Test asserts helper returns the newer UUID (because length guard should make `parseCutoffMs` return null, causing `Date.now()` self-init). Initially FAILS — gets empty stdout.
- [ ] **GREEN**: passes once F3-IMPL adds the length guard.

### Step F3-IMPL — Length guard in parseCutoffMs
- [ ] Add `if (s.length < 18) return null;` after the digit-only check.

**Checkpoint**: `bash tests/structure/test-resolve-session-id.sh` 100% PASS; full structure suite 100% PASS.

## Final Verification

- [x] All 15 structure test files pass — **228 PASS / 0 FAIL** (was 221 before; +7 new assertions).
- [x] `node -e` smoke against this worktree's CWD returns `a01473c3-c9cb-45ed-8d12-e00a548866ca` (real live UUID, confirms allowlist resolves the actual `~/.claude/projects/<subdir>`).
- [x] mtime discipline: test mtime (15:51:58) precedes impl mtime (15:53:09) by 71 seconds — TDD discipline satisfied.
- [x] No precondition drift (no install/skip/substitute decisions taken).
- [x] Build: n/a (claude-code plugin repo, no build step).
- [x] Coverage SKIPPED — no coverage runner configured for bash+node shell scripts (Phase 1 step 3b finding).
- [ ] Plan + log committed — only committed when the user requests it.
