# Drivers — author durable tests (assert-and-persist)

`/zensu:cover` reuses `/zensu:autopilot`'s driver catalog as its base — the taxonomy,
sub-modes, augments, and degrade rules in `../../autopilot/rules/drivers.md` apply
unchanged (`browser` / `api` / `cli` / `async` / `iac` / `custom`, plus `library`,
`artifact`, `email` sink, and the on-demand `mobile` / `desktop-native`). Read that file for
the catalog. This file describes the **single delta** that makes a driver an *authoring*
driver rather than a *validation* driver.

## The one delta: persist instead of discard

autopilot's drivers **exercise → assert → discard** — they observe an acceptance criterion
live and capture throwaway evidence (a screenshot, a status code) for the PR table. cover's
drivers **exercise → assert → persist**: the same action-and-assertion is written to a
**committed test file** in the project's harness, so it runs forever as a regression guard.

| Driver | autopilot (validate, throwaway) | cover (author, durable) |
|---|---|---|
| `browser` | Playwright actions → DOM assert + screenshot, discarded | a committed Playwright/Cypress spec: same actions → same DOM assertions |
| `api` | client call → status + body checked once | a committed integration/contract test hitting the endpoint |
| `cli` | run with args → stdout + exit code checked once | a committed CLI/golden test asserting stdout + exit code |
| `async` | publish → assert side-effect once | a committed test that publishes and asserts the downstream effect |
| `iac` | plan/apply to a disposable target, asserted once | a committed test asserting the planned/created resources (kind/localstack) |
| `custom` | project `exercise`+`assert` scripts run once | those scripts wired into the project's test target so they run in CI |

The driver is chosen per behavior from the level decided in `levels.md`: unit/component/
integration levels usually map to `api`/`library`/in-process drivers; an E2E level maps to
`browser` (UI flows) or `api` (backend-observable flows). Pick the cheapest driver that still
observes the behavior faithfully.

## `--from-acs` — the autopilot seam

When invoked as `/zensu:cover --from-acs` (from `/zensu:autopilot --cover`), emit **one durable
end-to-end test per numbered acceptance criterion**. Resolve the ACs in this order: (1) the AC
block handed in as the invocation payload — autopilot passes the same numbered ACs it authored
in its Phase-0 planning; (2) a named plan artifact (e.g. a `.zensu/plans/*.md` file) when one is
given; (3) the PR body's per-AC table. autopilot invokes cover at its Phase 1 step 6b, so it
supplies the ACs via (1) — it does not depend on the PR body being finalized first. For each:

- Each numbered AC → one test case, named for the AC, driven by the same driver autopilot used
  to validate it live.
- The AC's *exercise* step becomes the test's actions; its *observe* step becomes the test's
  assertions — the throwaway live check is transcribed into a permanent one.
- Authenticated flows load the session from autopilot's credential-blind login-script artifact
  **by path** (`storageState` / bearer-token file) — never inline a secret (see
  `../../autopilot/rules/auth.md`).

The result: the flows autopilot proved once are now committed tests in the same PR, so the
feature ships with its regression net attached.

## custom — why the catalog never dead-ends

Any target the base catalog does not name (browser extension, game/canvas, notebook, embedded,
hardware-in-the-loop) is a `custom` driver: the project supplies an `exercise`/`assert` pair
and cover wires it into the project's test target. An unknown stack is a `custom` test, never a
gap in coverage.
