# Verification drivers

A **driver** is how one matrix row exercises the running feature and observes the result.
`SKILL.md` Phase 0 resolves a driver for every row with this file; Phases 2 to 4 then load the
driver's own rule file. The orchestration, the boundaries and the verdict contract in `SKILL.md`
are the same for every driver. The vocabulary is shared with `/zensu:autopilot` and
`/zensu:cover` (`../../autopilot/rules/drivers.md`); `desktop-native`, an earlier spelling there,
is read as `desktop`.

## 1. Catalog

| Driver | Verifies | Rule file | Drives with | Remote |
|---|---|---|---|---|
| `browser` | web apps, PWAs, server-rendered pages | `rules/browser-verification.md` and the browser sections of `SKILL.md` | `playwright-cli` on a `zensu-verify` session behind the consent gate | yes, under the launch-time policy |
| `api` | REST, GraphQL, gRPC, WebSocket, SSE and webhook endpoints of a run-owned service | `rules/service-verification.md` | `curl`, `grpcurl`, a WebSocket client, or the project's own client | no |
| `cli` | commands, scripts, batch jobs, terminal UIs | `rules/cli-verification.md` | the built entry point; a TUI through `tmux` on a run socket, else `expect` | no |
| `library` | packages, SDKs, modules without an entry point | `rules/cli-verification.md` | a throwaway consumer in `$RUN_DIR` that depends on the worktree by path | no |
| `async` | queue and event consumers, workers, schedulers, cron jobs, data pipelines | `rules/service-verification.md` | the project's own producer, CLI or trigger | no |
| `iac` | Terraform, Helm, Kubernetes manifests, CDK and CloudFormation | `rules/service-verification.md` | validate, plan or render in `$RUN_DIR`; apply only to a run-named `kind` or localstack target | no |
| `mobile` | iOS, iPadOS, watchOS, tvOS and visionOS apps in a simulator; Android apps in an emulator; React Native, Flutter, .NET MAUI, Kotlin Multiplatform and Capacitor builds | `rules/mobile-verification.md` | `xcodebuild` + `xcrun simctl`, Gradle + `adb`; a host simulator tool, Maestro, a simulator accessibility CLI | no |
| `desktop` | macOS apps (SwiftUI, AppKit), Electron and Tauri apps, Windows and Linux desktop apps | `rules/desktop-verification.md` | a host computer-use tool, macOS System Events UI scripting, the platform's UI automation | no |
| `custom` | anything else: browser extensions, games and canvas engines, embedded firmware, hardware in the loop, notebooks, IDE extensions | this file, section 7 | the project's own `exercise` and `assert` scripts | no |

Remote mode stays browser-only. Every other driver verifies a build of the current worktree, so
`--mode=remote` with any of them stops with PARTIAL right after the step-0 URL check in
`SKILL.md`, naming the driver.

## 2. Selecting drivers

Resolve the driver per row, in this order:

1. `--driver=<id>` applies to every row of the run.
2. The recipe's `validate.driver` is the default for rows that exercise the recipe's application.
3. Otherwise detect it from the diff: the changed files and the surface they belong to.

| Signal in the changed files or the repository | Driver |
|---|---|
| UI components, pages, templates or styles of a web framework, a PWA manifest | `browser` |
| HTTP handlers and routers, OpenAPI, GraphQL or `.proto` definitions, WebSocket or SSE handlers, with no changed UI | `api` |
| a CLI entry point: `bin` in `package.json`, `[project.scripts]` in `pyproject.toml`, `cmd/*/main.go`, a Cargo `[[bin]]` or `src/main.rs`, a shell script, a TUI library | `cli` |
| a package or SDK with no entry point of its own | `library` |
| a queue or topic consumer, a job worker, a scheduler or cron entry, a stream or ETL pipeline | `async` |
| `*.tf`, `Chart.yaml`, Kubernetes manifests, `kustomization.yaml`, CDK or CloudFormation templates | `iac` |
| an Xcode project or workspace with an iOS, iPadOS, watchOS, tvOS or visionOS target; an Android application module (`com.android.application`); `pubspec.yaml`; a React Native, .NET MAUI, Kotlin Multiplatform or Capacitor mobile target | `mobile` |
| a macOS app target, an `electron` dependency, a `src-tauri/` directory, a WinUI, WPF or WinForms project, a GTK or Qt application | `desktop` |
| none of the above | `custom` |

A feature that spans surfaces gets one driver per row: a SwiftUI screen and the endpoint it calls
become `mobile` rows and `api` rows. Pick the driver that observes the criterion where the user
observes it. Record each row's driver and the file and signal that chose it; the report repeats
them.

A recipe command runs with its inputs assigned on that command: `ZENSU_VERIFY_RUN_DIR` (the run
directory), `ZENSU_VERIFY_PORT` (a service's run-specific port in consent mode) and
`ZENSU_VERIFY_DEVICE` (the run's simulator UDID or emulator serial, for a `mobile` row). The
recipe schema, including each driver's block, is in `../../autopilot/rules/config.md`; without a
recipe, a build driver derives its facts from tracked files as its rule file describes.

## 3. Evidence planes

| Driver | State plane | Visual plane | Runtime signals |
|---|---|---|---|
| `browser` | DOM snapshot and data | screenshot | console and network, unauthenticated targets only |
| `api` | status code, response body, the persisted effect the criterion names | n/a | log of the run-owned service |
| `cli` | exit code, stdout and stderr, the files or rows the command changed | n/a; a TUI's captured screen is its state and visual plane | stderr |
| `library` | return values or printed output of the consumer | n/a | exceptions and warnings |
| `async` | the accepted input and the downstream effect: a row, a message, a file, a log line | n/a | worker log |
| `iac` | validation result, plan or rendered manifests, resource state after a disposable apply | n/a | tool diagnostics |
| `mobile` | accessibility hierarchy; without a hierarchy tool, the app's data container or its log, named `visual-only` | device screenshot | app log filtered to the app's process, crash reports |
| `desktop` | accessibility tree or app data | screenshot of the app window only | app log, crash reports |
| `custom` | the scripts' exit code and printed evidence | as the scripts provide | as the scripts provide |

- **A criterion the user sees needs a UI driver.** Text, layout, a control or a state change on
  screen is proven through `browser`, `mobile`, `desktop`, or `cli` for terminal output. Proving it
  only through `api`, `library`, `async` or a log caps that criterion at PARTIAL: backend evidence
  shows that the data exists, not that the user sees it.
- **Visual-only is allowed and named.** A `mobile` or `desktop` row without a hierarchy tool may
  pass on inspected screenshots together with app data or the app log; the report names its state
  plane `visual-only`.
- **Inspect every image.** Open each screenshot with the Read tool and write what it shows about
  layout, clipping, overlap, legibility and state. "Screenshot taken" is not an observation.
- **Screens are evidence; raw logs follow the console rule.** Screenshots and the accessibility
  tree of the app under test are its DOM and visual planes. Read them when the app runs on
  run-owned or synthetic data, and against a deployed backend or a real account only after the
  user's yes that section 8 asks for under Authentication. Raw logs of an authenticated session
  can carry tokens and personal data, like console output: read them only from a target proven
  synthetic, otherwise that plane is PARTIAL. Filter logs to the app's own process, bound them,
  and never copy raw log lines into the report.
- **Classify a log before judging it.** An app log is rarely empty. Measured on a first launch:
  Core Data logged several hundred error-level lines while it created its store, then reported
  its recovery attempt successful. Count the lines by level and by subsystem and category. The
  runtime signal is clean when there is no crash report, no fault-level line, and no error that
  comes from the app's own subsystem or from the path the criterion exercises and was not
  recovered. Name every other class with its count.

## 4. Toolchain preflight and degrading

Before Phase 2, check every tool the chosen driver needs with `command -v <tool>`. A missing tool
moves the row to the next rung of that driver's ladder in its rule file. When no rung is left, the
row is PARTIAL and the report names the missing tool. Never substitute a tool that cannot observe
the criterion.

- **Downloads need a yes.** Installing a tool (Maestro, a simulator accessibility CLI, an Android
  system image, `tmux`) or letting a build fetch dependencies (Swift packages, Gradle, CocoaPods,
  npm) downloads code. Ask once, name what and from where, and wait for the answer.
- **Host tools are rungs, and their prompts are the user's.** A host tool that drives a simulator,
  or a computer-use tool that drives app windows, is used when the session offers it. Its
  permission prompt is answered by the user, never on their behalf.
- **Never a host browser tool.** An in-app browser pane or a browser extension drives the user's
  own browser profile outside the consent gate. The `browser` driver is `playwright-cli` on a
  `zensu-verify` session and nothing else.

## 5. Run-owned resources

Every device, process, cluster, container and terminal server that a driver rule file starts goes
through the run-resource helper, and so does its teardown. The services a recipe starts keep the
recipe's own `down`, and the bundled monorepo adapter keeps its lease (`SKILL.md` Phase 4): the
helper neither records nor stops those. Replace `<absolute-plugin-root>` with the concrete `ROOT`
from `SKILL.md`:

```bash
node "<absolute-plugin-root>/skills/verify-feature/scripts/verify-run-resources.js" list --run-dir "$RUN_DIR"
```

| Verb | Use |
|---|---|
| `create-simulator --device-type <id> [--runtime <id>]` | creates the run's iOS-family simulator and prints `udid=` and `name=` |
| `start --name <name> --cwd <dir> -- <command> [args...]` | runs a long-lived command (an app, a dev server, an emulator) under the process supervisor, in its own process group, and prints `pid=` and `log=` |
| `record --kind <android-emulator\|tmux-socket\|kind-cluster\|container> --id <id>` | records a resource the run is about to create |
| `teardown` | stops or deletes every recorded resource after re-checking its identity |
| `list` | prints `prefix=zensu-verify-<run>` and every recorded resource |

- **Names carry the run prefix.** `list` prints `prefix=`. Every container, `tmux` socket and
  `kind` cluster is named that prefix or the prefix plus `-<lowercase suffix>`; `record` refuses
  any other name. An emulator serial is `emulator-<port>` with the port the run chose, and
  `record` refuses a serial that `adb devices` already lists, or when `adb` cannot answer.
- **Record before you create.** Record the name first, then create the resource, so a crash in
  between still leaves an entry that teardown can resolve.
- **Teardown is exact.** It acts only on recorded entries, in reverse order, and what it checks
  depends on the kind:
  - a simulator is deleted by its UDID, after its name is read again and still equals the run's
    name;
  - a supervised process is stopped through the supervisor's lease; when the supervisor's
    endpoint is gone, its command line must still name this run's supervisor before it is
    signalled;
  - an emulator is never killed by its serial: teardown stops the supervised emulator process,
    then reads `adb devices`, and a serial that is still listed is kept;
  - a container, a `tmux` socket and a `kind` cluster are removed by the run-prefixed name that
    `record` accepted, with no second check: the name is the identity. A cluster's context is
    removed from the run's own kubeconfig only.

  Exit `1` lists what it kept and why; the report names each kept resource under Limitations, and
  nothing else is deleted to make up for it. After `teardown=incomplete` keep the run directory:
  its ledger and the supervisor lease are the only way to retry. Name its path and the retry
  command under Limitations:
  `node "<absolute-plugin-root>/skills/verify-feature/scripts/verify-run-resources.js" teardown --run-dir "<that path>"`.
- **No bulk verbs.** Never `xcrun simctl delete all`, `delete unavailable`, `shutdown all` or
  `erase`, never `adb emu kill`, never a `docker rm` by pattern, never
  `kind delete clusters --all`, never `tmux kill-server` without `-L`, never `pkill` or `killall`.

## 6. Mixed features

- Start service drivers first: a backend the app calls must pass its readiness probe before the
  app is launched.
- Point a `mobile` or `desktop` app at the run-owned backend through a switch the recipe names in
  `validate.mobile.launchArgs` or `validate.desktop.launchArgs`: a launch argument, an
  environment variable (a `SIMCTL_CHILD_` variable for the iOS simulator), or a build
  configuration. When the app can only reach a fixed deployed backend, the rows that depend on it
  verify deployed code: mark them so, and never claim worktree identity for that backend.

## 7. `custom`

The project supplies `validate.exercise` and `validate.assert` (or one `assert` that does both).
Each runs from the worktree with `ZENSU_VERIFY_RUN_DIR` set, writes only beneath it, prints its
evidence, and exits `0` on pass. The skill reads the exit code and the output; it never edits the
scripts and never invents them. Without them, offer `--setup`; still without them, the rows are
PARTIAL with the missing scripts named.

## 8. Every other driver, phase by phase

`SKILL.md` runs one flow for every driver. This section holds what a row whose driver is not
`browser` does differently in each phase; read it once any row resolves to such a driver.

**Boundaries.** Every boundary in `SKILL.md` binds every driver, and three of them read as
follows here:

- **Real interfaces.** Exercise the product's own interface (the endpoint, the command, the
  app's own screen) through the driver's rule file, never a mock or stub of the product.
- **Credential-blind.** Use only a throwaway identity the repository's own fixtures create, or
  the user's own visible login typed by the user into the simulator, emulator or app window.
- **Run-owned devices only.** Simulators and emulators, never a physical device, and never a
  simulator, emulator, app window or terminal session the user already has. Every device,
  supervised process, cluster, container and terminal server that a driver rule file starts goes
  through the run-resource helper of section 5; a recipe's services keep its own `down`.

**Phase 0.** Record each row's driver with the file and the signal that chose it (section 2),
and run the toolchain preflight of section 4 for every driver chosen. For a build driver the
local target identity adds the build command and the artifact path once Phase 2 has built it.

**Phase 1.** The matrix columns map to the driver's evidence planes (section 3): `DOM/data` is
its state plane, `Visual` is `n/a` for a driver without a visual plane, and `Network` is its
runtime signal or side effect. Add the dimensions the row's driver rule file names: arguments
and exit codes, status codes, device appearance, orientation and permission states, window
states.

**Phase 2.** Build output, device data, logs and screenshots stay beneath the run's `$RUN_DIR`
where the tool allows it, and the run-resource helper is called with the physical run directory
path. Steps 1 to 5 of local mode prepare the services a row needs: every `api` and `async` row,
and a backend that a `mobile` or `desktop` app calls. A row whose driver builds an artifact and
needs no service (`cli`, `library`, `iac`, `mobile`, `desktop`, `custom`) skips them and runs an
artifact built from this worktree:

1. Load the row's driver rule file and walk its toolchain ladder. A missing tool makes the row
   PARTIAL, never a substitute that cannot observe the criterion.
2. When the build targets the run's device, create that device through the run-resource helper
   first: a simulator build names the run's UDID as its destination. Copy the UDID, serial or
   name the helper prints literally into every later call.
3. Build the worktree with the command the recipe's driver block names, else the command the
   repository documents or the rule file derives from tracked files. Build out of tree beneath
   `$RUN_DIR` where the tool allows it, and record the command and the artifact path: they are
   the local target identity. A build that must download dependencies asks first.
4. Start every long-lived process (the built app, a bundler, an emulator) through the helper's
   `start`, in the order the driver rule file gives.
5. Never run a build, install or launch command that targets any or all connected devices.

`--attach` applies to `browser` and `api` rows only (`rules/attach.md`); a build driver always
builds and launches its own copy.

**Authentication.** A `mobile` or `desktop` app logs in the same visible way as the browser: the
user types the credentials into the simulator, emulator or app window, and the run never types
them. When such an app runs against a deployed backend or a real account instead of run-owned
data, ask the user once before the first such row and name the backend, because its screens can
show personal data; without that yes those rows are PARTIAL. `api` rows authenticate only with a
throwaway identity the repository's own fixtures create (`rules/service-verification.md`).

**Phase 3.** Drive each row through its driver's rule file against the endpoint, command, device
or window it names, with the evidence planes of section 3. For `mobile`, `desktop` and
terminal-UI rows, take a screenshot or pane capture, and the accessibility hierarchy where a
tool provides one, after every meaningful interaction, and read both before choosing the next
action. A parallel lane with `mobile` rows also needs its own device.

**Phase 5.** The report adds these lines:

- **Target:** for every build driver, the build command and the artifact path.
- **Drivers:** each row's driver with the file and signal that chose it, and the tools that
  drove it; name every row a missing tool made PARTIAL.
- **Runtime signals:** stderr, service, device and app logs, crash reports. Report the class and
  a bounded, sanitized message, or `clean`; never copy raw log lines.
- **Visual:** device screenshots, app-window screenshots and terminal pane captures are
  described like browser screenshots; a driver without a visual plane reports `n/a`.
- **Resources:** the run-resource helper's teardown lines; every resource it kept is named.
- **Limitations:** every missing tool, beside the gaps `SKILL.md` names.

An `Evidence` cell names `output`, `hierarchy` or `log` where a browser row names a screenshot,
snapshot or request.
