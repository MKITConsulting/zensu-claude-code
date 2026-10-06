# Guided runtime setup

Entered through `/zensu:verify-feature --setup`, or from Phase 2 when no recipe resolved and
the user accepted the offer. Setup is a conversation over evidence, never a generator: every
value is proposed from a tracked file, every proposal names that file, and a value with no
evidence stays empty and is reported as such. Setup never edits project files other than the
recipe it writes, never starts the application, and never runs an install.

## 1. Detect the stack from tracked files only

Read only files `git ls-files` reports. Record one evidence line per proposal in the form
`<value> — from <repo-root-relative file>`:

| Signal | Evidence file(s) | What it yields |
|---|---|---|
| Node dev server | `package.json` `scripts.dev` / `scripts.start`, the lockfile name | `up` command, package manager |
| Vite | `vite.config.*` | `--host 127.0.0.1 --port $ZENSU_VERIFY_PORT --strictPort` |
| Angular | `angular.json` | `--host 127.0.0.1 --port $ZENSU_VERIFY_PORT` |
| Next.js | `next.config.*` | `next dev -H 127.0.0.1 -p $ZENSU_VERIFY_PORT` |
| Make | `Makefile` targets | candidate `up` / `ready` targets, named, never invented |
| Compose | `docker-compose*.yml`, `compose*.yml` | shared fixed ports and container names, reported as blockers |
| Go | `go.mod`, `cmd/*/main.go` | `go run ./cmd/<name>` with a port flag or env the code reads |
| JVM | `build.gradle*`, `pom.xml` | `./gradlew bootRun` / `mvn spring-boot:run` with a port property |
| Xcode app | `*.xcodeproj`, `*.xcworkspace` | `mobile` for an iOS, iPadOS, watchOS, tvOS or visionOS target, `desktop` for a macOS target; the scheme from the `.xcscheme` files under `xcshareddata/xcschemes/`, never from `xcodebuild -list`, which resolves Swift packages first |
| Android app | a Gradle module applying `com.android.application` | `mobile` with `platform: android` and the module's assemble task |
| Cross-platform mobile | `pubspec.yaml`, a `react-native` dependency, a .NET MAUI project, a Kotlin Multiplatform app module, `capacitor.config.*` | `mobile` as a list of blocks, one per platform the change touches |
| Electron or Tauri | an `electron` dependency, `src-tauri/tauri.conf.json` | `desktop` with the project's own start or build script |
| CLI | `bin` in `package.json`, `[project.scripts]` in `pyproject.toml`, `cmd/*/main.go`, a Cargo `[[bin]]` | `cli` with the build command and the built entry point |
| Library | a package manifest with no entry point | `library`, with an example or sample the repository ships |
| Infrastructure | `*.tf`, `Chart.yaml`, `kustomization.yaml`, `cdk.json` | `iac` and the disposable target, if the evidence names one |
| Worker | a queue or scheduler dependency with a worker or cron entry point | `async` with the producer or trigger the repository owns |
| Seed or fixture code | `**/seed*`, `**/fixtures/**`, `**/testdata/**` | whether `synthetic` can be claimed |

A port the application binds is proposed only when the evidence shows how to pass
`$ZENSU_VERIFY_PORT` in; an application that can bind only a fixed port is reported as
"fixed port, shared resource" and left for the user to decide, never rewritten by setup.

Flags must reach the dev server itself. npm needs a `--` before them and strips it
(`npm run dev -- --host …`). pnpm forwards a literal `--` to the script, and Vite ignores every
flag after it, so the pnpm form passes the flags directly (`pnpm dev --host …`).

## 2. Propose per service

For every service the evidence names, propose:

- `up`: the start command, bound to `127.0.0.1` and to `$ZENSU_VERIFY_PORT`, refusing to fall
  back to another port;
- `ready`: an HTTP probe on a path the code exposes (`/`, `/health`, `/api/health`), or a log
  line the start command prints; a sleep is never readiness;
- `down`: leave empty when the service runs as a foreground child the run supervises; name a
  scoped command only when the evidence names one (a Compose project name per run, a PID file
  the start command writes).

Propose the optional data-classification declaration for the whole application:
`dataClassification: synthetic` only when seed or fixture code proves the application renders
no user, tenant, credential, or production-derived content, and `pre-classified-non-sensitive`
only if the user confirms it; without either, leave the block out. Never propose a route list:
the evidence boundary is the approved origin, which covers every page on it, and `routes` is no
longer read.

Propose `validate.networkOnly` only when a tracked file names another origin the application's
pages request — an API base URL, an OIDC authority or a token endpoint in a tracked environment
or configuration file — and only for the deployment the recipe selects. Each origin gets its own
evidence line, and an origin no tracked file names stays out: never propose one from a running
application, a browser's network log, a guess, or a file `git ls-files` does not report.
Propose it as the bare origin, with no path, and propose `appOrigin` only for a remote recipe,
where it must be the origin of the validated remote base URL.

For a build driver, propose the `validate` block instead of, or beside, the services: the
`driver` and its block (`validate.cli`, `validate.library`, `validate.mobile` or
`validate.desktop`, schema in `../../autopilot/rules/config.md`) with the build command, the
artifact path, the app identifier and the device type the evidence names. Propose a desktop
app's `dataIsolation` switch only when its code shows one; setup never invents one.

## 3. One confirmation round

Ask exactly one `AskUserQuestion` whose options carry every proposal as a pre-filled answer the
user edits, plus "cancel". Never split the proposals over several questions and never write the
recipe before the answer arrives. A cancelled round writes nothing.

## 4. Write the recipe

Write `.zensu/runtime.yaml` at the physical worktree root with the Write tool, refuse to
overwrite an existing file without a second explicit confirmation, print the diff, and offer
to commit — never commit unasked. The schema is the verify-sufficient subset of
`../../autopilot/rules/config.md`:

```yaml
version: 1
services:
  - name: app
    up: "PORT=$ZENSU_VERIFY_PORT npm run dev -- --host 127.0.0.1 --port $ZENSU_VERIFY_PORT --strictPort"
    ready: "curl -fsS http://127.0.0.1:$ZENSU_VERIFY_PORT/"
validate:
  driver: browser
  evidenceSafety:
    contractVersion: 1
    mode: declared-safe
    dataClassification: synthetic
    containsPersonalData: false
    containsSecrets: false
```

`.zensu/autopilot.yaml` keeps working as an alias and is tried second. `/zensu:autopilot`
reads `.zensu/autopilot.yaml` only — it does NOT read `runtime.yaml` — so a project that wants one
recipe to serve both skills writes `autopilot.yaml` rather than `runtime.yaml`.
`validate.navigationBroker` declares policy mode; it is optional in consent mode and honoured
when present. `validate.networkOnly` takes `origins`, a list of exact origins, and in a remote
recipe `appOrigin`, as `../../autopilot/rules/config.md` describes.

A build driver needs no services. A native iOS app that talks to no backend:

```yaml
version: 1
validate:
  driver: mobile
  mobile:
    platform: ios
    project: App.xcodeproj
    scheme: App
    appId: com.example.app
    deviceType: com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

A cross-platform app whose change touches both platforms:

```yaml
version: 1
validate:
  driver: mobile
  mobile:
    - platform: ios
      project: ios/App.xcworkspace
      scheme: App
      appId: com.example.app
      deviceType: com.apple.CoreSimulator.SimDeviceType.iPhone-17
    - platform: android
      project: android/app
      appId: com.example.app
      systemImage: "system-images;android-35;google_apis;arm64-v8a"
```

A command-line tool:

```yaml
version: 1
validate:
  driver: cli
  cli:
    build: "go build -o ${ZENSU_VERIFY_RUN_DIR:?}/bin/tool ./cmd/tool"
    command: "${ZENSU_VERIFY_RUN_DIR:?}/bin/tool"
```

Inputs are written `${NAME:?}` so a skill that does not assign them fails the command instead of
expanding it to an empty path.

## 5. `--print-policy`

With `--print-policy`, render the parent-environment policy for the recipe instead of
starting anything: `{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:<port>","evidenceMode":"declared-safe"}]}`,
with `<port>` taken from `--port=<n>` when given, else from
`node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-free-port.js" --from 5173`. Print it, then run
`ZENSU_VERIFY_NAVIGATION_POLICY_V1='<rendered JSON>' node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy local "<origin>" declared-safe`
once, with the rendered JSON assigned on that command only, and report its exit code: `policy`
on stdout with exit `0` means the rendered JSON approves that origin, and with it every route on
it. The policy carries no route list.
When the recipe declares `validate.networkOnly`, the rendered JSON also carries a top-level
`"networkOnlyOrigins"` list with every declared origin, and the preflight runs once more per
network-only origin, with the same rendered JSON assigned on that command only:
`ZENSU_VERIFY_NAVIGATION_POLICY_V1='<rendered JSON>' node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy local "<network-only origin>" network-only`.
`policy` with exit `0` means the rendered JSON lists that origin as network-only. A non-loopback
network-only origin in a local policy must be public HTTPS, and the preflight resolves it and
refuses a non-public answer.
Explain that the JSON belongs in the environment that launches Claude Code (a shell export, a CI
job's `env`, or the `env` block of `~/.claude/settings.json`) and that the project-level
settings files are not the place, because the session can write them.
