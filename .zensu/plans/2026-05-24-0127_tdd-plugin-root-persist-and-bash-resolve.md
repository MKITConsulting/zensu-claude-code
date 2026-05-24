# TDD Plan: Plugin-Root Persist Unconditional + Explicit Bash Resolve

## Context

Two Important findings from code review on the plugin-root resolution work
(round 15, plan `2026-05-24-0109_tdd-tdd-manager-plugin-root-resolution.md`):

**Finding 1 (`hooks/session-start-pulse.sh:7`)** — the
`zensu_hook_enabled pulseSession || exit 0` guard at line 7 fires BEFORE the
new plugin-root persist block (lines 14-18). Users who set
`{"hooks":{"pulseSession":false}}` in `~/.zensu/config.json` will never get
`~/.zensu/plugin-root` written, and every subsequent tdd-manager invocation
will trip the FATAL abort at Phase 0 step 1. The agent's recovery message
("run a fresh session to trigger SessionStart hook") does not mention "and
enable pulseSession", so the user is stuck in a loop. The persist is
meta-infrastructure (subagent helper resolution) orthogonal to pulse
telemetry.

Fix: Move the persist block ABOVE the `zensu_hook_enabled pulseSession ||
exit 0` line so it runs unconditionally whenever SessionStart fires,
regardless of the pulseSession setting. Place this immediately after the
existing `source` line and BEFORE the pulseSession gate, then remove the
duplicate block from below so persistence happens exactly once and
unconditionally.

**Finding 2 (`agents/tdd-manager.md:82`)** — the instruction "Read
`$HOME/.zensu/plugin-root` and store its contents as `{PLUGIN_ROOT}`" is
ambiguous about which tool to use. The Read tool returns `cat -n` formatted
output (line numbers prefixed), so naive use yields
`"     1\t/path/to/root"` as `{PLUGIN_ROOT}`, which then expands to
`bash      1<TAB>/path/to/root/hooks/lib/zensu-log.sh …` — a broken command.
Different LLM rollouts may interpret this differently, recreating the
LLM-improvisation problem this fix is meant to eliminate.

Fix: Replace the ambiguous instruction with an explicit Bash tool invocation.
Recommended exact text for Phase 0 Step 1:

> 1. **Resolve plugin root once.** Run `bash -c 'cat "$HOME/.zensu/plugin-root"'`
> via the Bash tool and store its trimmed output (no trailing newline) as
> `{PLUGIN_ROOT}` for the entire session. If the command exits non-zero or
> the output is empty, abort with: `FATAL: plugin root unresolvable — run a
> fresh session to trigger SessionStart hook AND ensure hooks.pulseSession is
> not set to false in ~/.zensu/config.json`. **Never search the filesystem.**

Both findings are Important (not Critical). Suggestions from the reviewer are
explicitly excluded from this fix round (no test for disabled-pulseSession
case, no concurrency-edge comment).

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + markdown structure tests | **Coverage**: SKIPPED (bash hooks + markdown prompts; no coverage tool installed for this repo layer — matches prior rounds' convention)

## Preconditions

| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| bash | CLI | `command -v bash` | present | install (already) |
| grep | CLI | `command -v grep` | present | install (already) |
| mktemp | CLI | `command -v mktemp` | present | install (already) |
| stat | CLI | `command -v stat` | present | install (already) |

## Status Legend

| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Bug Fix | Move plugin-root persist block above `pulseSession` gate, remove duplicate | tests/structure/test-session-start-plugin-root.sh | - | [G] | 1 |
| S2 | Feature | Phase 0 Step 1 uses explicit `bash -c 'cat …'` invocation + extended FATAL message | tests/structure/test-tdd-manager-patches.sh | - | [G] | 1 |

### Step S1 — Persist unconditionally before pulseSession gate (Bug Fix)

- [x] **RED**: Extend `tests/structure/test-session-start-plugin-root.sh` with cases:
  - `PR-S5 persist block appears BEFORE pulseSession gate` — assert that the line containing `zensu_hook_enabled pulseSession` appears AFTER the line containing `printf '%s\n' "$CLAUDE_PLUGIN_ROOT" > "$HOME/.zensu/plugin-root"` (order check via `grep -n` line numbers).
  - `PR-F4 functional: pulseSession=false still writes plugin-root` — invoke the hook with a stub `zensu_hook_enabled` that returns failure for `pulseSession`, verify `$HOME/.zensu/plugin-root` is still created with `CLAUDE_PLUGIN_ROOT` content.
  - These cases FAIL initially because the persist block currently sits BELOW the pulseSession gate.
- [x] **GREEN**: Edit `hooks/session-start-pulse.sh` — move the 5-line persist block (lines 14-18) above the `zensu_hook_enabled pulseSession || exit 0` line (line 7), place it immediately after the `source` line. Remove the duplicate block from its previous location.

### Step S2 — Phase 0 Step 1 explicit Bash invocation (Feature)

- [x] **RED**: Extend `tests/structure/test-tdd-manager-patches.sh` with cases:
  - `F1.a Phase 0 Step 1 uses bash -c 'cat ...'` — assert the agent file contains literal `bash -c 'cat "$HOME/.zensu/plugin-root"'`.
  - `F1.b Phase 0 Step 1 instructs trimmed-output handling` — assert the file contains `trimmed output` (covers the no-trailing-newline guidance).
  - `F1.c Phase 0 Step 1 FATAL message mentions pulseSession config` — assert the file contains `hooks.pulseSession is not set to false`.
  - `F1.d Phase 0 Step 1 no longer says "Read `$HOME"` — assert the file does NOT contain the legacy `Read \`$HOME/.zensu/plugin-root\` and store its contents` phrasing (negative check).
  - These cases FAIL initially because the agent file still uses the ambiguous "Read `$HOME/.zensu/plugin-root` and store its contents" wording.
- [x] **GREEN**: Edit `agents/tdd-manager.md` Phase 0 Step 1 — replace the ambiguous instruction with the recommended exact text quoted above.

**Checkpoint**: `bash tests/structure/test-session-start-plugin-root.sh` and `bash tests/structure/test-tdd-manager-patches.sh` both PASS; full structure suite remains GREEN; agent file line count <= 320.

## Final Verification

- [x] All structure test files PASS (11 files, 162 PASS / 0 FAIL)
- [x] `bash -n hooks/session-start-pulse.sh` clean
- [x] Coverage: SKIPPED (bash + markdown layer; no coverage tool installed)
- [x] Build: n/a (this repo has no build step)
- [x] mtime discipline: S1 and S2 both test-first
- [x] Precondition drift: none
