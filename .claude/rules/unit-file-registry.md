---
paths:
  - "tests/profiles/unit-files.v1.json"
  - "tests/structure/lib-unit-registry.js"
  - "tests/structure/lib-unit-registry.sh"
  - "tests/structure/unit-registry.test.js"
  - "tests/structure/test-unit-registry.sh"
  - "tests/structure/*.test.js"
  - "tests/session-control/run.sh"
  - "tests/run-all.sh"
  - "tests/SUITE-OVERVIEW.md"
---

# Unit-File Registry (`tests/profiles/unit-files.v1.json`)

**One file owns every `node --test` unit file's declared facts.** `tests/profiles/unit-files.v1.json`
holds one entry per `*.test.js` under `tests/`: its exact `registered` count, a per-host ceiling
of skipped or todo cases (`skips`, keyed `darwin`, `linux`, `root` for uid 0 and `win32`; an
absent key means 0), the `guards` whose exact titles must PASS, every `(driver, mode)` pair in
`runs`, and a one-sentence `summary`. `tests/SUITE-OVERVIEW.md` §4 and its §1 totals are generated
from it and from the suite manifest, never edited by hand.

**Three readers enforce it, at three moments.**

- The `tests/run-all.sh` preflight runs `node tests/structure/lib-unit-registry.js census` and
  refuses every mode with exit 2 when the registry does not load, a unit file has no entry, an
  entry names a missing file, or an entry's `registered` differs from the file's column-0
  `test(` registrations. A case registered below column 0 is refused, because the static count
  cannot see it.
- Every driver grades each run through `tests/structure/lib-unit-registry.sh`. `unit_run`, or
  `unit_grade` for a run the driver spawned itself as `tests/session-control/run.sh` does,
  checks node's exact total from the TAP summary, refuses an emptied file even at
  `registered: 1`, and applies the host's skip ceiling and the guards. `unit_registry_done`
  fails a driver that never ran a file the registry gives it.
- `tests/structure/test-unit-registry.sh`, a `ciStructureTests` member, runs the census and the
  driver audit: every driver is reached by CI, sources the library, names its files, calls the
  done check and has no column-0 `exit 0` before its first unit call, and no suite spawns
  `node --test` outside `unit_grade`. It also holds the generated overview regions against the
  renderer and carries mutation controls on a real entry.

**Adding a unit file** means adding its entry in the same commit, with skip counts measured on
every host class that runs it, and then running
`node tests/structure/lib-unit-registry.js render --write`. The driver that runs it adds a
`unit_run` or `unit_check` call and keeps its done check.

**Where the skip ceilings came from**, so the next measurement knows what it replaces: `darwin`
from a local macOS run; `linux` and `root` from `node:20-bookworm` (Node 20.20.2, the CI
version) as uid 1000 and as root; and `win32` from the green main CI run 38286044034 for the
files its blocking Windows shards run. For every other file the `win32` value counts the cases
whose code can skip on win32. Replace those from a green Windows Safety run.

**Decisions, recorded so they are not re-decided from scratch:**

- The count is node's EXACT total, never a floor: a floor admits a deletion and drifts below the
  real count. A count derived from the file under test agrees with whatever the file says, so
  the runtime grade compares node's total with the declared one; the census compares the static
  count only so the preflight can refuse before any suite runs.
- One node process per file per driver, because a summed multi-file run cannot attribute a
  count to a file. `test-windows-ci-contract.sh` keeps its pinned case arms and loops over them.
- Paths reach node as argv and never inside a file, because MSYS converts argv on Windows and
  leaves file contents alone. That is why `owned` takes the graded paths after `--`.
- `unit_not_run` prints `NOT RUN <path>: <reason>` and fails only when `CI` is set.

**Version: none.** Tests only: nothing under `hooks/`, `agents/`, `skills/`, `docs/`,
`templates/` or `scripts/` moves, so the runtime digest is unchanged and no release is owed.
