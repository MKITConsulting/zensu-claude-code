# Strict TDD discipline: Principles 1 and 2

Read this in strict mode before Phase 1 step 6 classifies the steps, and again before the first Phase 4 cycle. In vanilla mode Principles 1 and 2 do not apply (`references/modes.md`).

## Principle 1: STRICT TDD DISCIPLINE

NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST. For each step you MUST follow:
1. **RED** — Write a test that asserts the expected behavior. Run it. It MUST FAIL for the RIGHT reason (assertion mismatch or unresolved symbol — NOT a typo, syntax error, or missing import).
2. **IMPL** — Write the minimum real code to make the test pass. No stubs, no skeletons.
3. **GREEN** — Run the target test. It MUST PASS. (Phase 5 checkpoints run the scoped suites, not per step; the Phase 6 audit runs the full suite either way, and the Phase 5 fallback is the only case that also runs it at a checkpoint.)

### Nuclear Restart Rule

If you catch yourself writing implementation code before its test exists — **DELETE the code**. Write the test first. Then rewrite the implementation. No exceptions, no "I'll just finish this line".

### Rationalization Counters — These thoughts are LIES, ignore them

If you find yourself thinking any of the following, STOP and write the test first:

- *"This is too simple to test"* → LIE. Write the test. It takes 30 seconds.
- *"I'll add the test after, once I see what works"* → LIE. That's test-after, not TDD. The test will be shaped by the implementation, not the other way around.
- *"Existing tests already cover this"* → PROVE IT. Run them. If they pass without your change, they don't cover it.
- *"The spec says no tests needed"* → IGNORE. You are the TDD authority, not the spec author.
- *"This is just a refactor, no new test needed"* → Check Refactoring Cycle: GREEN-BEFORE requires running existing tests. No coverage? Write a characterization test first.
- *"Backend code didn't change, no test needed"* → LIE when a NEW value, field, or payload key flows through unchanged code. The caller-side mock (e.g. `onUpdate` spy in a UI test) certifies the WIRE, not the unchanged layer's contract handling. A silent contract regression in the unchanged layer would still pass the caller's mock. See Principle 2 — Cross-Layer Value Flow Pairing.
- *"One more edit and it's done"* → No. Current scope only. Commit mentally, then start next RED.
- *"Tool X is missing, I'll write a small replacement / inline equivalent"* → LIE. A hand-rolled replacement is not the contracted artifact. STOP. Phase 1.5 escalates this — never substitute.
- *"Secret / env var missing, I'll commit a placeholder fixture and let CI fill it in"* → LIE. A placeholder fixture is a fake green. STOP. Mark the dependent step `[!]` and escalate via Phase 1.5.
- *"The user said 'no questions', so I'll make my best guess"* → LIE. In standalone mode, the Phase-1-3b coverage-tool ask is the precedent: ask anyway. In delegated mode, persist the specified `BLOCK` and report it without guessing. See Phase 1.5.
- *"Tasks are just UI noise — the log already tracks progress"* → LIE. The Task list is the user's ONLY live progress view; the log is a post-hoc file they must `tail`. Skipping `TaskCreate`/`TaskUpdate` leaves the user blind to where you are. Create the step tasks in Phase 3, flip their status in Phase 4 — same discipline as the log.

### Hard Bans

NEVER implement before writing the RED test. NEVER skip the GREEN verification. NEVER modify a test after the implementation passed (that's rewriting history, not TDD). NEVER use `git stash`. NEVER edit files in `~/.claude/`. NEVER substitute a missing required dependency (CLI, secret, fixture, service endpoint) with a hand-rolled equivalent, mock, or placeholder unless the user has explicitly approved the substitution via Phase 1.5 escalation. NEVER search the filesystem to "discover" the zensu-log.sh helper — use the native component root from Phase 0; if it fails, abort with the FATAL message.

If a step seems too simple for TDD (i18n, config), fold it into a related testable step's IMPL. If spec says "not testable", find a seam (extract function, inject dependency). If truly non-testable (wiring, migration), mark as `[W]` integration — but the wiring must still be VERIFIED by running the caller's tests.

## Principle 2: WORK TYPES (per step)

Classify EACH step. A single task may mix types.

**Feature** (default): RED → IMPL → GREEN. Status: `[G]`
**Refactoring** (same behavior): GREEN-BEFORE → CHANGE → GREEN-AFTER. Status: `[RF]`. Verify tests cover the affected code first — if not, write a behavior-preserving test.
**Bug Fix**: RED-REPRO → FIX → GREEN. Status: `[G]`
**Integration** (wiring, config, migrations): Direct implementation, no test cycle. Status: `[W]`

Merge steps ONLY if (a) their test files share setup code that should only be written once, or (b) they are technically inseparable (same class, same method). NEVER as a logging shortcut. Each merged step still requires its own RED log entry with that step's specific failure reason. When merging N steps you log N RED entries + 1 IMPL entry + N GREEN entries.

### Cross-Layer Value Flow Pairing (MANDATORY)

When a Feature/Bug-Fix step routes a NEW value, field, payload key, or query parameter through an UNCHANGED adjacent layer, you MUST add a paired **Characterization step** (`[G]`, Feature work type) in the unchanged layer that runs BEFORE the originating step. The Feature step's `depends_on` MUST list the Characterization step.

**Examples of the trigger:**
- Frontend dialog adds `project_id` to an update payload consumed by an existing Rust `update_appointment` command → pair with a Rust characterization that asserts `SELECT project_id FROM appointments WHERE id = ?` returns the new value after `update_appointment` runs.
- New column written by an existing repository call → pair with a repository test asserting the column round-trips.
- New query parameter read by an existing HTTP handler → pair with a handler test asserting the parameter changes the response.
- New gRPC field added to a request the existing server already deserializes generically → pair with a server-side test asserting the field is honored.

**Non-triggers (no pairing needed):**
- Pure UI change (label text, color, icon) — no value crosses a layer.
- Value never crosses a process / persistence / network boundary.
- Target layer already has an IMPL step in THIS plan (its own RED→GREEN covers the new value).
- An existing test in the target layer already asserts the new field round-trip. **Verify by reading the test, not by assumption** — `grep` for the field name in the target layer's test files; if no assertion exists, pairing is required.

**The characterization MUST assert at the unchanged layer's OWN seam** — DB row contents, returned struct, network response body, persisted file — NOT at the caller's mock. A `vi.fn()` / `mockReturnValue` at the caller boundary certifies the wire only; it cannot detect a silent contract drop in the unchanged consumer.

**Rationale:** Per-step RED→GREEN tests only code the agent writes. The Phase 6 audit's full-suite run catches regression of EXISTING assertions — if no test ever asserted the new value's round-trip, there is nothing to regress. Skipping this pairing produces silent fullstack-contract regressions invisible to both per-step RED→GREEN and that safety net. Note that the Phase 5 checkpoint is scoped and therefore weaker still here: a cross-layer regression lands in the UNCHANGED layer, which is exactly the code a scoped checkpoint does not run. The pairing is what makes it visible — do not treat the checkpoint as a substitute for it.

Detection happens in Phase 1 step 6 (planning) and is audited in Phase 6 step 6b.
