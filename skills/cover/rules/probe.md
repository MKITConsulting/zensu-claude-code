# Probe — detect the repo, mirror its conventions

`/zensu:cover` reuses `/zensu:autopilot`'s self-setup probe as its base — see
`../../autopilot/rules/probe.md` for boot/stack detection and the resolution ladder
(explicit flag → project config → auto-detect → confirm → persist). This file describes only
the **authoring-specific** delta: what cover detects so it can write tests that look like the
ones already in the repo.

## What cover adds on top of the base probe

For **each layer** the target touches, resolve three things:

### 1. Test runner (can it RED/GREEN?)

| Ecosystem | Signals | Typical runner |
|---|---|---|
| Node/TS | `package.json` scripts (`test`), `vitest.config.*`, `jest.config.*`, `.mocharc*` | vitest / jest / mocha |
| JVM | `build.gradle(.kts)` / `pom.xml`, `src/test/**` | JUnit (+ Spring Test / MockMvc) |
| Go | `go.mod`, `*_test.go` | `go test` |
| Python | `pyproject.toml` / `tox.ini` / `pytest.ini`, `tests/**` | pytest / unittest |
| Ruby | `Gemfile`, `spec/**` | RSpec / Minitest |
| Rust | `Cargo.toml`, `#[cfg(test)]`, `tests/**` | `cargo test` |

Distinguish a **test runner** (asserts, can go red/green) from a **static check** (type
checker, linter). Cover needs a runner. If a layer has none, do not invent one — mark that
layer degraded in the report.

### 2. Existing-test conventions (mirror these exactly)

Read 1–2 nearby existing tests per layer and capture:
- **Location** — colocated (`foo.test.ts` beside `foo.ts`) vs a mirror tree (`src/test/...`,
  `tests/`, `__tests__/`, `spec/`).
- **Naming** — `*.test.ts` / `*.spec.ts` / `Test*.java` / `*_test.go` / `test_*.py`.
- **Structure** — `describe/it` vs `test()` vs class-based; the assertion library in use.
- **Fixtures & helpers** — factories, builders, `beforeEach` setup, test-container helpers,
  the project's mocking approach.

The authored tests must be indistinguishable in style from what is already there.

### 3. E2E harness (if any)

Detect a browser/API E2E setup before proposing one: `playwright.config.*`, `cypress.config.*`,
a `e2e/` or `tests/e2e/` dir, WebDriver/Selenium config, Maestro flows, an existing API-level
integration harness (supertest, MockMvc, `httptest`, `pytest` + client, testcontainers). If a
harness exists, author into it; if none exists and the plan needs E2E, surface that as a
Phase 0.D question rather than scaffolding a framework unasked.

## Mirror, never impose

The probe's job is to make cover write tests the maintainers would have written. Never
introduce a new framework, assertion library, or directory layout when the repo already has
one. The one exception — a layer with **no** runner at all — is raised to the user, not
resolved by fiat.

## Degrade, never dead-end

If a layer's runner or E2E harness is missing or its toolchain is absent, degrade that layer
(cover the layers you can, write the reachable levels) and **state the gap in the report** —
same honesty rule as the base probe. A partial-but-truthful net beats a faked one.
