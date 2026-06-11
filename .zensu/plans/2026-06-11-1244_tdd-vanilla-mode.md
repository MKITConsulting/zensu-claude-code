# TDD Plan: Vanilla Implementation Mode (`hooks.tddImplementation`)

## Context
New Zensu config key `hooks.tddImplementation` (default `true` = strict; `false` = vanilla mode) disables ONLY the RED→GREEN TDD implementation discipline while the rest of the workflow chain stays fully enforced (plan/log/tasks, Phase 5/6 audits incl. build/coverage/witness evidence, 5-aspect review fan-out → code-reviewer → auto-fix → self-review, stop-chain-enforcer). Mode is frozen per session at `--tdd-begin` into a `vanilla` state-file flag; the edit gate reads the state flag, never live config. `--tdd-begin` echoes the effective mode (`mode: strict` / `mode: vanilla`). Ask-hooks (plan-approval, per-turn reminder), post-review fix directive, and banner/primer get mode-aware wording. Full spec: /Users/marcelkarras/.claude/plans/clever-sparking-stearns.md

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash 3.2-compatible hooks + `node -e` JSON, bash structure-test harness (`tests/run-all.sh`) | **Coverage**: kcov (user-approved install) @ 90% lines (default-90%)

## Preconditions
| Name | Type | Verification | Status | Decision |
|------|------|--------------|--------|----------|
| node | CLI | `command -v node` | present (v23.11.0) | — |
| git | CLI | `command -v git` | present | — |
| kcov | CLI | `command -v kcov` | present (kcov 43, already installed) | install (user approved `brew install kcov` via coverage ask) |

## Cross-Layer Value Flow Pairings
(Per Principle 2 — no pairings: every consumer of the new `vanilla` flag — state lib, `--tdd-begin`, edit gate, post-review hook — has its own IMPL step with RED→GREEN coverage in THIS plan.)

| Feature Step | New Value | Unchanged Layer (file / module) | Characterization Step | Seam Asserted |
|--------------|-----------|---------------------------------|------------------------|----------------|

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps
| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| W0 | Integration | Install kcov via brew (user-approved) | — | — | [W] | 1 |
| S1 | Feature | State-lib `vanilla` flag plumbing: survives `_tdd_write_phase_critical` rebuilds, reset by `_tdd_write_clear_critical`, `tdd_vanilla_mode()` wrapper + export | tests/structure/test-tdd-vanilla-mode.sh | — | [G] | 1 |
| S2 | Feature | `--tdd-begin` persists vanilla flag per config (unconditionally, both directions) + echoes `mode: strict|vanilla`; reset hygiene across re-begin | tests/structure/test-tdd-vanilla-mode.sh | S1 | [G] | 1 |
| S3 | Feature | Gate bypass on state vanilla flag (frozen — no live config read); freeze across phase writes + config flips; witness + Stop-chain guarantee unchanged in vanilla | tests/structure/test-tdd-vanilla-mode.sh | S2 | [G] | 1 |
| S4 | Feature | Ask-hooks vanilla directive variants (plan-approved-delegate.sh, user-prompt-tdd-reminder.sh) | tests/structure/test-tdd-vanilla-mode.sh | — | [G] | 1 |
| S5 | Feature | post-review-tdd-delegate.sh mode-aware FIX_DISCIPLINE fragment (strict verbatim; vanilla: fix directly, keep evidence discipline; retain pinned literals) | tests/structure/test-tdd-vanilla-mode.sh | S1 | [G] | 1 |
| S6 | Feature | session-start-banner.sh + session-start-primer.sh conditional wording | tests/structure/test-tdd-vanilla-mode.sh | — | [G] | 1 |
| S7 | Feature | Content pins: skills/tdd/SKILL.md `## Vanilla Implementation Mode` section + Phase 0 mode-echo capture + intro pointer; config.example.json `tddImplementation: true`; cap bump SKIPPED (SKILL.md at 390 ≤ 400 — guard left unchanged) | tests/structure/test-tdd-vanilla-mode.sh | — | [G] | 1 |
| W1 | Integration | Docs: README opt-out row + activation sentence; docs/tdd-manager-workflow.md vanilla subsection + overview pointer; skills/zensu-help/SKILL.md flag row; skills/self-review/SKILL.md + skills/implement/SKILL.md one-line vanilla clauses | — | S7 | [W] | 1 |

### Step W0 — Install kcov
- [ ] **WIRE**: `brew install kcov`; verify `command -v kcov`.

### Step S1 — State-lib vanilla flag plumbing
- [ ] **RED**: Test `L1/L2/L3` — set `vanilla` flag, emit `--phase` write, expect flag still `true` (fails: `_tdd_write_phase_critical` drops unknown flags); `--tdd-reset` clears it; `tdd_vanilla_mode` wrapper exists (fails: function missing).
- [ ] **GREEN**: carry `prev.vanilla` forward in `_tdd_write_phase_critical`; `s.vanilla = false` in `_tdd_write_clear_critical`; add `tdd_vanilla_mode()` + export.

### Step S2 — `--tdd-begin` mode persist + echo
- [ ] **RED**: Cases A (default config → echo `mode: strict`), B-begin (tddImplementation:false → echo `mode: vanilla`, state `vanilla:true`), G (vanilla begin → reset → strict re-begin same SID → `mode: strict`, state `vanilla:false`) — all fail: `--tdd-begin` echoes nothing, writes no vanilla flag.
- [ ] **GREEN**: zensu-log.sh `--tdd-begin` branch writes flag unconditionally per `zensu_hook_enabled tddImplementation`, echoes effective mode, stderr warning + strict fallback on flag-write failure; exit code stays active-write rc; rounds reset unconditional.

### Step S3 — Gate bypass + freeze + chain guarantee
- [ ] **RED**: Cases A-deny (strict: gate denies prod at UNINITIALIZED/RED_FAIL — already green, characterization), B-allow (vanilla session: gate allows prod+test edits, no phase markers — fails: gate has no vanilla check), B2 (after `--phase GREEN_PASS` in vanilla session gate still allows — fails), E (config flips after begin don't change gate behavior either direction — vanilla-half fails), C (witness records cmd=/tail= in vanilla session), D-stop (`--tdd-complete` → Stop blocks toward code-reviewer; `--code-review-done` → blocks toward self-review; `--chain-done` → allows).
- [ ] **GREEN**: pre-edit-tdd-reminder.sh exits 0 when state-file `vanilla` flag true (after `tdd_session_active` check).

### Step S4 — Ask-hook vanilla variants
- [ ] **RED**: Case F — with `tddImplementation:false` both hooks' additionalContext contains 'vanilla' + `skill='zensu:tdd'` + AskUserQuestion + docs-only fast-path and NOT 'strict TDD flow'; with default config contains 'strict TDD flow'. Fails: hooks emit strict heredoc only.
- [ ] **GREEN**: config branch with second vanilla heredoc in each hook (strict heredoc byte-identical).

### Step S5 — post-review mode-aware fix directive
- [ ] **RED**: Case D-postrev — vanilla session: additionalContext contains vanilla fix wording, NOT 'strict TDD discipline', retains `/zensu:tdd` + `subagent_type='zensu:code-reviewer'`; strict session keeps 'strict TDD discipline'. Fails: hook emits strict text always.
- [ ] **GREEN**: FIX_DISCIPLINE variable per state vanilla flag, interpolated in both MSG variants; CONV_MSG unchanged.

### Step S6 — Banner + primer wording
- [ ] **RED**: Case BNR — with `tddImplementation:false` banner stdout + primer additionalContext mention vanilla (and not RED→GREEN-strict phrasing); default keeps current wording. Fails: static text.
- [ ] **GREEN**: conditional wording on `zensu_hook_enabled tddImplementation` in both scripts.

### Step S7 — Content pins (SKILL.md + config.example.json)
- [ ] **RED**: Case H — SKILL.md contains `## Vanilla Implementation Mode`, `mode: vanilla`, `DISCIPLINE AUDIT SKIPPED — vanilla mode`; config.example.json `hooks.tddImplementation === true`. Fails: neither exists.
- [ ] **GREEN**: add SKILL.md delta section + Phase 0 step 3 echo-capture + intro pointer; add config key; bump cap 400→430 in test-tdd-manager-patches.sh.

### Step W1 — Docs wiring
- [ ] **WIRE**: README Hook Opt-Out row + TDD activation sentence; docs/tdd-manager-workflow.md subsection + overview pointer; zensu-help flag row; self-review Phase 4 + implement Step 3 one-liners.

**Checkpoint**: `bash tests/run-all.sh` + `bash -n` on all touched hooks pass

## Final Verification
- [ ] All test suites pass (`bash tests/run-all.sh` all-green)
- [ ] Coverage report generated for changed files (threshold: 90% lines, default-90%, tool: kcov)
