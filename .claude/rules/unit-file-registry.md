---
paths:
  - "tests/profiles/unit-files.v1.json"
  - "tests/structure/lib-unit-registry.js"
  - "tests/structure/lib-unit-registry.sh"
  - "tests/structure/unit-registry.test.js"
  - "tests/structure/test-unit-registry.sh"
  - "tests/**/*.test.js"
  - "tests/session-control/run.sh"
  - "tests/run-all.sh"
  - "tests/SUITE-OVERVIEW.md"
---

# Unit-File Registry (`tests/profiles/unit-files.v1.json`)

**One file owns every `node --test` unit file's declared facts.** `tests/profiles/unit-files.v1.json`
holds one entry per `*.test.js` under `tests/` that git does not ignore: its exact `registered`
count, a per-host ceiling of skipped or todo cases (`skips`, keyed `darwin`, `linux`, `root` for
uid 0 and `win32`; an absent key means 0), the hosts no driver runs it on (`notRunOn`, each with
a one-line reason), the `guards` whose exact titles must PASS, every `(driver, mode)` pair in
`runs`, and a one-sentence `summary`. A host may not carry both a `notRunOn` reason and a skip
ceiling, and `notRunOn` may not name every host. `tests/SUITE-OVERVIEW.md` §4 and its §1 totals
are generated from it and from the suite manifest, never edited by hand.

**Three readers enforce it, at three moments.**

- The `tests/run-all.sh` preflight runs `node tests/structure/lib-unit-registry.js census` and
  refuses every mode with exit 2 when the registry does not load, a unit file has no entry, an
  entry names a missing file, or an entry's `registered` differs from the file's column-0
  `test(` registrations. Inside a git work tree it lists unit files through `git ls-files`,
  tracked and untracked with ignored files excluded, so a gitignored fixture under `tests/` needs
  no entry; outside one it walks `tests/`. It runs git without the discovery variables
  (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE` and their kin, the list `work-order-v1.js`
  scrubs), so an exported `GIT_DIR`, which git hands its hooks, cannot point the listing at
  another repository. When git fails inside a work tree, or names another directory as the top
  level of a root that has its own `.git`, it walks too and says so beside any file it names,
  because the walk also finds files git ignores. A root nested in another repository without a
  `.git` of its own walks silently, as outside a work tree.
- The census also refuses a file whose source shows a case the static count cannot see: an
  indented `test(`; a `.test(` call that starts a line, optionally after `await`, `return` or
  `void`, on the context parameter a column-0 case declares in a one-parameter callback head that
  ends its own `test(` line (`(t) => {`, `t => {` or `function (t) {`); or a line-start call of
  `describe`, `it` or `suite` destructured from `node:test` by a `require` or `import` that
  starts its line. A registration it cannot see, such as a one-line loop, fails the driver's
  grade instead, and that message names the column-0 rule. A column-0 `test(` that registers
  nothing, in a comment, a string or a branch that did not run, fails the grade with a message
  that says so.
- Every driver grades each run through `tests/structure/lib-unit-registry.sh`. `unit_run`, or
  `unit_grade` for a run the driver spawned itself as `tests/session-control/run.sh` does,
  checks node's exact total from the TAP summary, refuses an emptied file even at
  `registered: 1`, applies the host's skip ceiling and the guards, and refuses a run on a host
  the entry's `notRunOn` names. `unit_registry_done` fails a driver that never ran a file the
  registry gives it on this host. A failing grade replays each `not ok` line on stderr with its
  YAML block and the last 40 diagnostic lines node printed since the case before it, counting
  any earlier ones it leaves out, or node's last 40 lines when no case reported `not ok`; a file
  that fails to load therefore shows its exception, which node prints last. Without
  `UNIT_RUN_OUTPUT`, `unit_run` creates its temp file only after node has exited, so an
  interrupted node run leaves none behind, and it refuses `UNIT_RUN_TEE` without a driver-owned
  `UNIT_RUN_OUTPUT`.
- `tests/structure/test-unit-registry.sh`, a `ciStructureTests` member, runs the census and the
  driver audit over `tests/structure/test-*.sh` and every registered driver. Each driver is
  reached by CI (it is a CI suite, or a CI suite runs it with `bash` or `sh`, by name, by
  absolute path or as `$BASH`, naming its path or a variable assigned that path), sources the
  library, names its files, calls the done check and has no line starting with `exit 0` before
  its first unit call. No scanned suite spawns `node --test` more often than a line of it starts
  with a `unit_grade` call. It also holds the generated overview regions against the renderer,
  carries mutation controls on a real entry, and runs both POSIX-only drivers through their
  native-Windows arm (U11).

**Adding a unit file** means adding its entry in the same commit, with skip counts measured on
every host class that runs it, and then running
`node tests/structure/lib-unit-registry.js render --write`. The driver that runs it adds a
`unit_run` or `unit_check` call and keeps its done check.

**Where the skip ceilings came from**, so the next measurement knows what it replaces: `darwin`
from a local macOS run; `linux` and `root` from `node:20-bookworm` (Node 20.20.2, the CI
version) as uid 1000 and as root; and `win32` from the green main CI run 38286044034 for the
files its blocking Windows shards run, and from the green main CI run 38575714149 for
`subagent-shell-guard-v1.test.js`, which joined the registry after it. For every other file
the `win32` value counts the cases whose code can skip on win32. Replace those from a green
Windows Safety run. `process-supervisor.test.js` and `work-order-v1.test.js` have no `win32`
ceiling: their drivers leave native Windows before grading, so both entries declare
`notRunOn.win32` instead.

**Decisions, recorded so they are not re-decided from scratch:**

- The count is node's EXACT total, never a floor: a floor admits a deletion and drifts below the
  real count. A count derived from the file under test agrees with whatever the file says, so
  the runtime grade compares node's total with the declared one; the census compares the static
  count only so the preflight can refuse before any suite runs.
- The census reads JavaScript as raw text, so comments and strings count. A JavaScript reader
  was considered and refused: regex literals such as the one in `clock-shift-v1.test.js` hold
  quotes and backticks, and a reader that misses one could hide real cases. Keep fixture text
  that spells `test(`, `describe(` or a `node:test` import off the start of a line.
- The driver audit reads each suite through `shellLines`, a small shell reader: quoted text,
  comments and heredoc bodies never count, while parameter expansions and command
  substitutions do. A heredoc ends on the word bash reads after quote removal, so `<<\EOF`,
  `<<'END-STUB'` and `<<EOF-1` close where bash closes them, and a here-string (`<<<`) or a
  shift inside `$(( ))` or `(( ))` opens none. A check label or a heredoc fixture that names
  `node --test` is therefore no spawn. Only `node`, by name or absolute path, or a `$NODE…`
  variable at a command position, with `--test` on the same line, counts as one. An `exit 0`
  that does not start its line, behind `||`, `&&` or `;` or in a one-line case arm, passes the
  drive-first rule. A broader early-exit pattern was measured and refused: it flagged the
  node-unavailable exits of four suites.
- A host on which a driver never runs a file is declared in `notRunOn`, never left as a ceiling
  no run can check. A driver that leaves such a host early sources the library first and calls
  its done check before it exits with the summary's status (`finish; exit`), so the done check
  passes there only while the registry declares the exclusion. `UNIT_REGISTRY_HOST` and
  `UNIT_REGISTRY_FILE` let a test grade as another host or against another registry.
- One node process per file per driver, because a summed multi-file run cannot attribute a
  count to a file. `test-windows-ci-contract.sh` keeps its pinned case arms and loops over them.
- Paths reach node as argv and never inside a file, because MSYS converts argv on Windows and
  leaves file contents alone. That is why `owned` takes the graded paths after `--`.
- `unit_not_run` prints `NOT RUN <path>: <reason>` and fails only when `CI` is set. It is for a
  run skipped by circumstance, such as a host that forbids loopback listeners, not for a host
  that never runs the file.

**Version: none.** Tests only: nothing under `hooks/`, `agents/`, `skills/`, `docs/`,
`templates/` or `scripts/` moves, so the runtime digest is unchanged and no release is owed.
