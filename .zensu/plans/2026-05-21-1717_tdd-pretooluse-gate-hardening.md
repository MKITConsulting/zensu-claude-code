# TDD Plan: PreToolUse TDD-Gate Security Hardening (9 review findings)

## Context

Code review identified 9 fixable findings (1 trivial + 5 critical + 3 likely-bug + 1 likely-bug related) in the PreToolUse TDD phase-gate stack. Each finding becomes its own atomic step; each step keeps strict RED -> IMPL -> GREEN discipline.

Findings recap:
1. Bash bypass: `tdd-manager` has `Bash` in tool whitelist but gate matcher only covers `Edit|Write|MultiEdit`. Agent can `cat > foo.ts <<EOF`, `sed -i`, `tee`, redirects — including overwriting `.zensu/state/tdd-phase-*` to forge `RED_FAIL`.
2. Race condition in `tdd_write_phase`: concurrent writes serialise through last-writer-wins on read-modify-write. 5 parallel calls -> only 1 history entry survives. Need `flock` around the critical section.
3. Loose inline-header regex misclassifies production files with `// describe(...)` JSDoc, `function it<T>`, `function test(name,fn)`, comments containing `describe(`. Anchor to BOL and exclude comment prefixes, OR drop inline detection.
4. FSM too permissive: `GREEN_PASS` and `REFACTOR` allow edits on ANY file forever after S1 -- defeats drift detection for S2..Sn. After `GREEN_PASS`, only test-path edits or explicit `REFACTOR` transition.
5. `tool_input.subagent_type` fallback is agent-controlled; forged payload bypass. Trust ONLY `CLAUDE_AGENT_TYPE` env.
6. Top-level `tests/foo.ts` (no leading slash) NOT detected as test path. Add anchored patterns for `test/*|tests/*|spec/*|specs/*|__tests__/*`.
7. Basename patterns false-positive: `AttestSpec.tsx`, `AccountsTests.tsx`, `RequestSpec.ts`. Need word boundary before `Test`/`Spec`.
8. Symlink follow: `innocent.ts -> real.test.ts` classified as test via `head -c 200`. Reject symlinks up front.
9. `assert-no-bypass.sh:14` always exits 0 even when bypass detected. Change exit code on `SUSPICIOUS != ""`.

**Approach**: Strict Red/Green TDD | **Tech Stack**: bash + node helpers, bash test harness | **Coverage**: bash-only (no JS coverage tooling for this gate) -- coverage assessment by passing/failing the bash assertion scripts. (`coverage_cmd=null`, threshold SKIPPED.)

## Status Legend
| [ ] Not started | [R] RED test | [I] Implemented | [G] GREEN | [RF] Refactored | [!] Blocked | [W] Wired |

## Steps

| Step | Type | Description | Test File | Depends On | Status | Attempts |
|------|------|-------------|-----------|------------|--------|----------|
| S1 | Feature | Top-level `tests/` etc. path detection | `evals/config-gate/test-pre-edit-toplevel-paths.sh` | – | [G] | 1 |
| S2 | Feature | Word-boundary basename matching | `evals/config-gate/test-pre-edit-basename-boundary.sh` | – | [G] | 1 |
| S3 | Feature | Symlink rejection in `tdd_is_test_path` | `evals/config-gate/test-pre-edit-symlink-reject.sh` | – | [G] | 1 |
| S4 | Feature | Inline-header regex anchored + comment-exclusion | `evals/config-gate/test-pre-edit-inline-header.sh` | S1,S2,S3 | [G] | 2 |
| S5 | Feature | `flock`-guarded concurrent write to state file | `evals/config-gate/test-pre-edit-concurrent-write.sh` | – | [G] | 1 |
| S6 | Feature | Drop `tool_input.subagent_type` fallback (CLAUDE_AGENT_TYPE only) | `evals/config-gate/test-pre-edit-agent-trust.sh` | – | [G] | 1 |
| S7 | Feature | Tight FSM: `GREEN_PASS` requires test-path target or explicit `REFACTOR` transition | `evals/config-gate/test-pre-edit-greenpass-tight.sh` + invert `test-pre-edit-allow-refactor.sh` | S6 | [G] | 1 |
| S8 | Feature | Bash matcher + state-file write guard | `evals/config-gate/test-pre-edit-bash-bypass.sh` | S7 | [G] | 2 |
| S9 | Feature | `assert-no-bypass.sh` exits 1 when suspicious is non-empty | `evals/tdd-manager-pretool/test-assert-no-bypass.sh` | – | [G] | 1 |
| S10 | [W] | Add new tests to `evals/config-gate/run-eval.sh` runner | n/a | S1-S9 | [W] | 1 |
| S11 | [W] | Wire bash matcher into `hooks/hooks.json` | n/a | S8 | [W] | 1 |

### Step S1 — Top-level `tests/` etc. path detection (#6)
- [G] **RED**: `tests/foo.ts` -> tdd_is_test_path = "true" (currently false). `test/foo.ts` -> true. `Tests/Foo.tsx` -> true (case-insensitive). `specs/foo.rb` -> true.
- [G] **GREEN**: extend `case "$lower"` to also match top-level `test/*|tests/*|spec/*|specs/*|__tests__/*`.

### Step S2 — Word-boundary basename matching (#7)
- [G] **RED**: `fooTest.ts` -> true; `FooTest.java` -> true; `user_spec.rb` -> true; `AttestSpec.tsx` -> false; `Tests.tsx` -> false; `Spec.ts` -> false; `RequestSpec.ts` -> false (no lower->upper boundary). Existing `Test.java`/`FooTest.java` must remain true.
- [G] **GREEN**: replace `case "$base" in *Test.* ...` with a bash regex that requires a `[a-z0-9_]` to `[A-Z]/_` boundary OR an explicit `_test`/`_spec` infix.

### Step S3 — Symlink rejection (#8)
- [G] **RED**: create `innocent.ts` -> `real.test.ts`; assert `tdd_is_test_path innocent.ts` = "false".
- [G] **GREEN**: top of `tdd_is_test_path` -> `if [ -L "$path" ]; then echo "false"; return 0; fi`.

### Step S4 — Inline-header regex tightened (#3)
- [G] **RED**: production file containing `// describe("legacy", ...)` JSDoc; production file with `function it<T>(item: T)` generic; production file with leading `/* describe( */`. All must classify as false. (Existing positive inline cases must remain true.)
- [G] **GREEN**: rewrite the regex to anchor at line-start AND exclude comment prefixes. Also require either an explicit path pattern OR a strict filename hint (`_test|.test|.spec|Test\b`) -- header alone insufficient (defense in depth).

### Step S5 — `flock` concurrent-write resolution (#2)
- [G] **RED**: spawn 5 parallel `tdd_write_phase` for the same session/different steps; assert history length == 5. Currently fails (last-writer-wins).
- [G] **GREEN**: wrap read-modify-write in `flock -x 9` on `${state_file}.lock` (with `mkdir`-based fallback if `flock` unavailable). Atomic mv preserved.

### Step S6 — Drop subagent_type fallback (#5)
- [G] **RED**: payload with `subagent_type=zensu:code-reviewer` and NO `CLAUDE_AGENT_TYPE` -> gate must still be active (deny prod edit in UNINITIALIZED state). Currently passes through.
- [G] **GREEN**: remove the `AGENT_CONTEXT=$(parse_field tool_input.subagent_type)` fallback. Trust only env. Default-fail-closed: if env empty/unset, treat as `zensu:tdd-manager` (gate active).

### Step S7 — Tight FSM around `GREEN_PASS`/`REFACTOR` (#4)
- [G] **RED**: after `GREEN_PASS` for S1, payload editing `src/bar.ts` for "next step" should be denied unless explicit `REFACTOR` marker exists. Invert assertion in `test-pre-edit-allow-refactor.sh`.
- [G] **GREEN**: in `decide_allow`, `GREEN_PASS` -> allow only test paths; `REFACTOR` -> allow any path (covered by explicit marker). `RED_WRITE` for next step still works via explicit phase transition.

### Step S8 — Bash bypass guard (#1, option b)
- [G] **RED**: PreToolUse payload with `tool_name=Bash, tool_input.command="cat > src/foo.ts <<EOF"` -> deny. Same for `sed -i`, `tee`, `>>`, `dd of=`. Bash writes into `.zensu/state/tdd-phase-*` must deny regardless of phase. Innocent commands (`ls`, `npm test`) must pass through.
- [G] **GREEN**: gate matcher in `hooks.json` extended to `Edit|Write|MultiEdit|Bash`. Hook detects `tool_name=Bash` and parses `tool_input.command`; if it matches file-mutating patterns OR touches `.zensu/state/tdd-phase-*`, emit `deny`.

### Step S9 — `assert-no-bypass.sh` real exit code (#9)
- [G] **RED**: feed it a transcript containing `cat > foo` -> script must exit 1.
- [G] **GREEN**: change `exit 0` to `exit 1` when `SUSPICIOUS` non-empty.

### Step S10 — Wire new tests into runner ([W])
- Add the 6 new test files to `evals/config-gate/run-eval.sh`.

### Step S11 — Wire Bash matcher into hooks.json ([W])
- Change matcher `Edit|Write|MultiEdit` -> `Edit|Write|MultiEdit|Bash`.

**Checkpoint**: `bash evals/config-gate/run-eval.sh --self-check` -> 54/54 PASS (48 existing + 6 new). `bash evals/tdd-review-chain/run-eval.sh --self-check` stays at 30/31.

## Final Verification
- [G] All 48 existing config-gate tests still green (verified — 48/48 in pre-S10 run).
- [G] 8 new unit tests added & green (S10 wired all into runner: 56/56 PASS).
- [G] `tdd-review-chain` self-check remains 30/31 (pre-existing single FAIL unrelated).
- [G] `hooks.json` matcher updated to `Edit|Write|MultiEdit|Bash`.
- [G] `agents/tdd-manager.md` tool whitelist intact (Option b chosen — Bash kept; guard added at hook level).
- [G] `CHANGELOG.md` Security section added documenting all 9 fixes.
- [G] mtime discipline audit: 9/9 Feature steps test-before-impl.
