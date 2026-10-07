---
paths:
  - "skills/verify-feature/**"
  - "skills/autopilot/SKILL.md"
  - "skills/autopilot/rules/config.md"
  - "skills/autopilot/rules/drivers.md"
  - "skills/autopilot/rules/probe.md"
  - "skills/cover/rules/drivers.md"
  - "skills/doctor/SKILL.md"
  - "templates/autopilot-spec.md"
  - "scripts/process-supervisor.js"
  - "tests/structure/verify-run-resources.test.js"
  - "tests/structure/test-verify-feature-skill.sh"
  - "docs/verify-feature.md"
  - "docs/gates.md"
---

# Verification Drivers (`skills/verify-feature/rules/drivers.md` + `verify-run-resources.js`)

`/zensu:verify-feature` verifies any kind of application through nine drivers: `browser`, `api`,
`cli`, `library`, `async`, `iac`, `mobile`, `desktop` and `custom`. `rules/drivers.md` is the
catalog (detection, evidence planes, degrade ladder, run-owned resources, `custom`); each family
has its own rule file, loaded only when a matrix row uses it.

**The browser prose stays in `SKILL.md`, relabelled, never moved.** Two reasons, both
mechanical. `${CLAUDE_PLUGIN_ROOT}` is substituted natively only in `SKILL.md`; a rule file read
with `Read` carries the `<absolute-plugin-root>` placeholder instead, and the browser sections
call `scripts/verify-browser-config.js`. And `tests/structure/test-verify-feature-skill.sh` pins
most of those sentences with LINE-based `grep -qF`, so a reflow breaks a pin even when every word
survives. Add lines beside a pinned one; do not rewrap it. The awk anchors `^## Phase 4` and
`^## playwright-cli preflight` take no new `## ` heading inside their sections.

**`SKILL.md` may not grow, so the driver prose lives in `rules/drivers.md` section 8.** The body
sits on the shrink-only allowlist of `tests/structure/test-skill-text-budget.sh`
(`.claude/rules/skill-text-budget.md`). `SKILL.md` keeps only what must run before any rule file
is read or on every run: the `--driver` row, the in-memory remote refusal of step 0, step 6,
the matrix's `Driver` column, the Phase 4 teardown and the verdict rules. Everything a
non-`browser` row does in each phase is in section 8. Two browser blocks moved out for the same
budget, both free of `${CLAUDE_PLUGIN_ROOT}` and of line pins: attach mode to `rules/attach.md`
(`P10m`), and the consent-mode details to `rules/browser-verification.md` section 1, which a
consent-mode run reads before its first browser call (`P10n`). `SKILL.md` keeps the sentence that
the consent memory is never written.

**Only the `browser` driver is gated, and that is a decision.** The consent gate exists because a
browser session renders arbitrary origin content, cookies and storage into the model. The other
drivers run the worktree's own build on run-owned local resources, bounded by the skill's rules,
the host's Bash prompts and the per-app or per-device grants of host tools. A PreToolUse hook that
can ask or deny for them would be a `minor` release under §"Runtime Lineage" and would still be
textual; it is the named follow-up, not an omission.

**Remote mode stays browser-only.** Remote API verification needs a policy check that works
without `playwright-cli`: `checkReadiness` in `scripts/verify-browser-config.js` runs first in
`--check-policy` and refuses without the measured CLI and both consent hooks. Until a check exists
that does not require them, a non-browser row in remote mode is PARTIAL, and `--driver` other than
`browser` with `--mode=remote` stops in memory in step 0.

**The run-resource helper is the one fail-closed part, because teardown is where the new drivers
can destroy something that is not the run's**: a user's simulator or emulator, a cluster behind
the ambient kubectl context, a process whose PID was reused.
`skills/verify-feature/scripts/verify-run-resources.js` records every device, supervised process,
emulator serial, `tmux` socket, `kind` cluster and container that a driver rule file starts in
`<run dir>/resources.json`, and acts only on recorded entries, in reverse order. What it checks
before acting depends on the kind:

- a simulator is deleted by its UDID after `xcrun simctl list devices --json` shows it still
  carries the run's name. `create-simulator` records the name before `simctl create` runs and
  reads the UDID from STDOUT only, because (measured on Xcode with the iOS 26.5 runtime)
  `simctl create` prints its "No runtime specified" notice on stderr, and a `2>&1` capture hands
  that line to `delete` as the device;
- a process is stopped through `scripts/process-supervisor.js` and its lease; when the
  supervisor's endpoint is gone, its command line must still name this run's supervisor and
  ready file before any SIGTERM, and when a supervisor died without removing its ready file, its
  process group is probed before the entry counts as gone;
- an emulator serial is never killed: `emu kill` reaches whichever emulator holds that console
  port. `record` refuses a serial that `adb devices` already lists, or when `adb` cannot answer,
  and teardown stops the supervised emulator process, then keeps the entry while `adb devices`
  still lists the serial;
- containers, `tmux` sockets and `kind` clusters are removed by the `zensu-verify-<run key>` name
  that `record` accepted, with no second check at delete time: the name is the identity.
  `kind delete cluster` passes the run's own kubeconfig, so only that file's context changes.

The ledger is validated when it is written as well as when it is read (`validEntry`), and a
symlinked or non-physical run directory is refused. The lock file holds the holder's pid, so a
lock left by a killed call is named as stale instead of blocking silently. The helper is not a
boundary: a resource started outside it is outside its reach, and nothing stops a Bash call from
deleting a device directly. The services a recipe starts keep the recipe's `down`, and the
monorepo adapter keeps its lease; the helper never records them. It carries no platform check for
simulators, on purpose: a missing `xcrun` is the refusal, which keeps the unit file runnable on
Linux CI with stub binaries. `start` refuses on native Windows, which has no POSIX process groups,
and the mobile and desktop rule files turn that refusal into a named PARTIAL.

**Phase 4 keeps the run directory when teardown kept anything.** The ledger and the supervisor
lease are the only way to retry, so the directory is deleted only after `teardown=complete`, and
the report names its path and the retry command otherwise. The deletion is also the last cleanup
step, after every recipe `down`, because a `down` may read what its `up` left under
`ZENSU_VERIFY_RUN_DIR`; Autopilot's step 6 follows the same order.

**A criterion the user sees needs a UI driver.** Proving it only through `api`, `library`,
`async` or a log caps it at PARTIAL; this keeps the retired "curl instead of the UI" escape
closed for every driver. **Screens are evidence, raw logs follow the console rule**: a native
app's screenshots and accessibility tree are its DOM and visual planes (run-owned or synthetic
data; a deployed backend or a real account needs the user's yes first), while raw logs of an
authenticated session stay PARTIAL unless the data is proven synthetic.

**Electron and Tauri are `desktop`.** `playwright-cli` 0.1.21 has no command that launches an
Electron app, and the consent gate denies `attach` on a `zensu-verify` session.

**Never `xcodebuild` before the build, and never the user's DerivedData.** Measured with Xcode
27.0: `xcodebuild -list` resolved the project's Swift packages first, fetched one over the
network and rewrote the package state in the user's DerivedData folder for that checkout. So the
scheme comes from the `.xcscheme` files, and the build clones Xcode's existing `SourcePackages`
with `cp -Rc` into the run directory and passes `-clonedSourcePackagesDirPath` with
`-skipPackageUpdates`; a fresh package directory would otherwise be a download.

**Coupled sites that move together:**

- The nine driver ids ↔ the `rules/drivers.md` §1 catalog, §2 detection table, §3 evidence
  planes and the service/build split of §8 ↔ the `--driver` row of `SKILL.md` ↔ the
  `validate.driver` enum and the driver blocks in
  `skills/autopilot/rules/config.md` ↔ `skills/autopilot/rules/drivers.md`, `probe.md` and the
  `--driver` row and seams block of `skills/autopilot/SKILL.md` ↔ `skills/cover/rules/drivers.md`
  ↔ the `validate` row of `templates/autopilot-spec.md` ↔ the detection rows of
  `rules/setup.md` ↔ the "What it can verify" table in `docs/verify-feature.md`, which also says
  that a native or command-line build needs no runtime recipe ↔ the
  "Only the `browser` driver is gated" bullet in `docs/gates.md` ↔ `DRIVERS` in
  `hooks/lib/acceptance-verify-v1.js`, which chain mode passes to `--driver` ↔ the `P10` checks,
  which derive the set from the config enum. `desktop-native` survives as a read-alias sentence,
  as the spelling the acceptance recorder stores a `desktop` record under, and, with `artifact`,
  as an earlier spelling the recorder still accepts (`.claude/rules/acceptance-verification-gate.md`
  says why storing `desktop` itself waits for a `minor` release).
- The helper's verbs (`VERB_NAMES`), `RECORD_KINDS`, `LEDGER_KINDS`, the `zensu-verify-` prefix,
  `RUN_ID_RE` and the ledger name ↔ `rules/drivers.md` §5 and §8 ↔ the mobile, desktop, CLI and
  service rule files ↔ `SKILL.md` Phase 4 ↔ `docs/gates.md` ↔
  `tests/structure/verify-run-resources.test.js`, which `test-verify-feature-skill.sh` runs with
  an exact case count that its `tests/SUITE-OVERVIEW.md` row must equal.
- `scripts/process-supervisor.js` (its lease variable, its ready-file JSON, `status`, `stop` and
  the arity of `start`) is consumed by the helper and by
  `skills/verify-feature/scripts/zensu-monorepo-runtime.sh`.
- The recipe inputs `ZENSU_VERIFY_RUN_DIR`, `ZENSU_VERIFY_PORT` and `ZENSU_VERIFY_DEVICE` ↔ the
  "Driver blocks and recipe inputs" subsection of `config.md` ↔ `rules/drivers.md` §2 ↔ the
  `${NAME:?}` spelling in the `rules/setup.md` examples ↔ the "Run-owned devices under autopilot"
  paragraph of `skills/autopilot/rules/drivers.md`, the only place where `/zensu:autopilot`
  assigns them.

**Known gaps, accepted and named:**

- Measured end to end on one real SwiftUI app with Xcode 27.0: helper `create-simulator`, boot,
  build against a cloned package checkout, install, launch, one tap through the host simulator
  tool on the run's UDID, `simctl io` screenshots, the filtered app log, and helper `teardown`,
  which left no `zensu-verify-*` device and the app's tree unchanged. Not measured: the Android
  emulator and the helper's emulator checks against a real `adb`, the macOS desktop launch,
  Windows and Linux desktop automation, Maestro, AXe, idb and `tmux`; the rules take their flags
  from each tool's own help at run time and say so.
- The supervised-start unit case accepts `removed` or `gone`. Before #349 the supervisor's
  `stop` could fail with `failed to probe owned process group: EPERM` while group members were
  still exiting (1 of 15 rounds under load on macOS), and the helper then found the supervisor
  and its group ended and reported `gone`. #349 reads that EPERM as an unsignalable group; the
  case keeps both answers rather than depend on that timing. The helper's own probe still reads
  EPERM as alive, so it keeps an entry it cannot prove ended.
- `runKeyFor` keeps a run directory name of at most 24 lowercase letters and digits joined by
  single dashes as the run key. Every other name `RUN_ID_RE` admits (up to 200 characters,
  including the `:` of an Autopilot run id) becomes a 14-character slug, `--` and the first 10
  hex digits of the name's SHA-256. So every owned name fits the 63-character bound without a
  hidden length limit for callers, and two names share a key only when they share a slug and 40
  bits of digest. Owned names are still not prefix-free: `zensu-verify-run-1-x--<digest>` is a
  suffixed name of run `run-1` and the bare prefix of a run whose slug is `run-1-x`. The skill's
  random run directory names make that unlikely; nothing checks it.
- Host tools default to the first booted simulator or the whole screen. The rules require the
  run's UDID on every call and app-scoped captures; that is prose, not a check.
- The desktop data-location and credential-store check is prose; nothing mechanical detects a
  shared data location.
- The evidence planes, the visible-criterion cap and the host-tool rules are model-judged. No
  promptfoo scenario covers a non-browser driver yet, so compliance is unobserved.

**Version: `patch`.** Walked against §"Runtime Lineage": no hook added, removed or renamed, no
matcher changed, no context-record or workflow-state schema field, no attestation change, and no
`permissionDecision`. The new recipe keys are read by the model permissively, and the new script
lives under `skills/`, which the Session Control digest already covers. `resources.json` v1 is a
new strict shape (`version`, `runKey`, and `validEntry` over `LEDGER_KINDS`): adding it changes no
shape an older installation reads, so it is not a breaking change. A later change to it is judged
as one, because a run directory kept after an incomplete teardown can be retried by a newer
installation of the same lineage. `process-supervisor.js start` now accepts a command without
arguments; that relaxes a refusal, and `zensu-monorepo-runtime.sh` always passes arguments.
