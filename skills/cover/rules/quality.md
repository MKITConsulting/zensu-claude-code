# Quality — the test-quality gate

A test that never fails is worse than no test: it reports false safety and costs maintenance.
Every test `/zensu:cover` authors must pass this gate before Phase 3 review. The gate is
language-agnostic; apply it to whatever framework the probe found.

## The gate (all must hold)

1. **Faithfulness / mutation-sensitivity.** The test must fail if the behavior is broken.
   This is the single most important property — a test that stays green when the code is
   wrong is a liability.
2. **Determinism.** No flakiness sources: no `sleep`/wall-clock waits (wait on conditions, not
   time), no dependence on test execution order, no reliance on ambient network, locale,
   timezone, or random seeds left unfixed. Same input → same verdict, every run.
3. **Isolation.** Each test sets up and tears down its own state. No shared mutable fixtures
   that leak between tests, no order coupling, no writing to a real shared resource. A single
   test can run alone and pass.
4. **No over-mocking.** Do not mock the thing under test, and do not assert *on the mock* when
   you could assert on a real output. A `vi.fn()`/`when(...).thenReturn(...)` at the boundary
   certifies the wire only — for anything that crosses a boundary you own, assert at the real
   seam (DB row, response body, persisted file, returned struct), not at the caller's mock.
5. **Meaningful assertions.** Assert real values, state changes, and side effects — never mere
   existence ("function is defined"), never a tautology, never a snapshot with no semantic
   check behind it. Prefer one sharp assertion on the behavior over ten shallow ones.

## The mutation-sensitivity spot-check (Phase 2)

For each newly GREEN test, confirm it is not a tautology before keeping it:

- **Mentally (or actually) mutate** the code under test — flip a boolean, change a `+` to `-`,
  return a constant, drop the persisted field — and confirm the test would go **RED**.
- If the test would stay green under an obvious mutation, it is not exercising the behavior:
  strengthen the assertion (assert the actual output/side effect) and re-check.
- For high-value paths, if the stack has a mutation-testing tool already configured
  (Stryker, mutmut, PIT, `cargo-mutants`), a targeted run is the strongest form of this
  check — but never introduce such a tool unasked; the mental mutation is the default.

## Anti-patterns to reject

- Asserting a function exists / was constructed, with no behavior assertion.
- Asserting on a mock's return value that the test itself configured.
- `expect(x).toEqual(x)` / comparing a value to itself or to a re-computation of the same code.
- Snapshot tests over volatile output (timestamps, ordering, generated ids) with no
  normalization.
- `sleep(n)` to "wait for" async work instead of awaiting a condition.
- One giant test asserting ten unrelated behaviors — split so a failure localizes.
- A test that only passes when run after another test.

A test that trips any anti-pattern is rewritten, not shipped. If it cannot be made faithful at
the chosen level, drop down a level (or up, to where the behavior is observable) per
`levels.md` rather than keeping a hollow test.
