# TDD Plan: /zensu:self-review terminal review-chain stage

## Context
Add `/zensu:self-review` as the terminal stage of the post-implementation review chain
(ported from the user-level `/reflect` skill, translated to English). After the
code-reviewer chain converges (ANY terminus, incl. max-rounds), self-review runs as
the LAST instance; it may take EXACTLY ONE fix round under strict TDD WITHOUT respawning
the code-reviewer; then it renders the final report incl. a new `## Self-Review Summary`.
Hard hook-enforced via a new `codeReviewDone` flag + a `selfReviewFixed` latch.
`hooks.selfReview=false` reverts to today's behavior.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash hooks + markdown skills | **Coverage**: SKIPPED (no bash coverage tool) | **Test runner**: standalone tests/structure/*.sh (exit non-zero on fail)

## Discovery deltas (vs. original spec)
- `tdd_set_flag` already accepts arbitrary keys -> SETTING codeReviewDone/selfReviewFixed needs NO setter change.
- `zensu_hook_enabled` is generic -> `hooks.selfReview` toggle needs NO zensu-config.sh change (folded into hook tests).
- REAL change in zensu-tdd-phase.sh: `_tdd_write_phase_critical` only preserves active/implComplete/chainDone across phase writes; it MUST also preserve codeReviewDone/selfReviewFixed (else a self-review fix-round phase write clobbers them).
- Existing version-coupled tests already stale at 0.4.1 (pin 0.4.0). Bumping README badge->0.5.0 and Skills (8)->(9) forces re-green of test-reset-review-limit-skill.sh + test-zensu-help-skill.sh.
- test-smoke-main-thread-chain.sh section 4 encodes OLD max-rounds->chainDone; my change makes max-rounds->codeReviewDone+self-review. Must update section 4.

## Status Legend
[ ] Not started | [R] RED | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired

## Steps
| Step | Type | Description | Test File | Status |
|------|------|-------------|-----------|--------|
| S1 | Feature | tdd-phase.sh: codeReviewDone + selfReviewFixed accessors; preserve across phase write; clear on reset; export | tests/structure/test-self-review-flags.sh | [ ] |
| S2 | Feature | zensu-log.sh: --code-review-done + --self-review-fixed markers | tests/structure/test-self-review-markers.sh | [ ] |
| S3 | Feature | stop-chain-enforcer.sh: route codeReviewDone && !chainDone -> self-review (gated by selfReview) | tests/structure/test-stop-enforcer-self-review-routing.sh | [ ] |
| S4 | Feature | post-review-tdd-delegate.sh: PASS/suggestions + max-rounds -> --code-review-done + invoke self-review; selfReview off = legacy | tests/structure/test-post-review-self-review-handoff.sh | [ ] |
| S4b | Refactoring | update test-smoke-main-thread-chain.sh section 4 to new convergence semantics | (same smoke test) | [ ] |
| S5 | Feature | skills/self-review/SKILL.md (EN port) + register in plugin.json + bump 0.5.0 (plugin/marketplace/README/CHANGELOG) | tests/structure/test-self-review-skill.sh | [ ] |
| S6 | Feature | skills/tdd/SKILL.md Phase 6.10 wording: PASS -> --code-review-done + self-review owns terminus | tests/structure/test-tdd-skill-self-review-handoff.sh | [ ] |
| S7 | Wired | re-green collateral version-coupled tests (reset-review-limit, zensu-help -> 0.5.0 / Skills (9) / 2026-06-01) + docs/tdd-manager-workflow.md self-review stage | (those tests) | [ ] |

## Final Verification
- [ ] All new + touched tests/structure/*.sh exit 0
- [ ] plugin.json == marketplace.json == 0.5.0; both list ./skills/self-review
- [ ] English-only across changed files
- [ ] Backward-compat: hooks.selfReview=false -> chain ends at code-review convergence as today

## Outcome (2026-06-01)
- S1 [G] codeReviewDone + selfReviewFixed flags (accessors + phase-write preservation + reset-clear + export)
- S2 [G] --code-review-done + --self-review-fixed markers
- S3 [G] stop-chain-enforcer routes codeReviewDone && !chainDone -> /zensu:self-review (gated by selfReview)
- S4 [G] post-review hook: PASS/suggestions + max-rounds -> --code-review-done + invoke self-review; selfReview off = legacy
- S4b [W] smoke test section 4 updated to new convergence semantics
- S5 [G] skills/self-review/SKILL.md (EN) + registered + bumped 0.5.0 (plugin/marketplace/README/CHANGELOG)
- S6 [G] skills/tdd/SKILL.md Phase 6.10 handoff wording
- S7 [W] re-greened reset-review-limit + zensu-help version pins; MT4 repoint; docs/tdd-manager-workflow.md + README hook notes

Structure suite: 26/28 pass. The 2 failures (test-post-bash-witness.sh, test-pre-edit-hook-mirror.sh) are PRE-EXISTING 0.4.0-migration stragglers that hard-code the retired CLAUDE_AGENT_TYPE=zensu:tdd-manager activation; both also fail on pristine HEAD (verified via throwaway worktree) and are out of scope for this feature.
Build: n/a (Claude Code plugin — bash hooks + markdown skills + JSON manifests, no build step). Coverage: SKIPPED (no bash coverage tool).
