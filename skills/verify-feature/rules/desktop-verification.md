# Desktop verification rules (`desktop`)

Loaded for rows whose driver is `desktop`: macOS apps (SwiftUI, AppKit, Mac Catalyst), Electron and
Tauri apps, Windows and Linux desktop apps. The run builds the worktree, launches that build under
the process supervisor, drives only its window, and stops it at teardown through the run-resource
helper (`rules/drivers.md` section 5). Replace `<absolute-plugin-root>` with the concrete `ROOT`
from `SKILL.md`.

## 1. Build and launch the worktree's build

- **Build out of tree where the tool allows it.** A macOS target builds with
  `xcodebuild -scheme <scheme> -destination 'platform=macOS' -clonedSourcePackagesDirPath "$RUN_DIR/SourcePackages" -skipPackageUpdates -derivedDataPath "$RUN_DIR/DerivedData" -disableAutomaticPackageResolution build`,
  after the scheme and package steps of `rules/mobile-verification.md` section 1, which apply
  unchanged; an Electron or Tauri app with the project's own build or dev script.
- **Launch the built executable itself, under the supervisor.** Never `open`, Finder, the Dock or
  another launcher: they hand the bundle identifier to the system, which can start the user's
  installed copy instead of the build. For a macOS bundle the executable is
  `<app>/Contents/MacOS/<CFBundleExecutable>`:

  ```bash
  node "<absolute-plugin-root>/skills/verify-feature/scripts/verify-run-resources.js" start --run-dir "$RUN_DIR" --name app --cwd "$RUN_DIR" -- "<app>/Contents/MacOS/<executable>"
  ```

  An Electron app runs through the project's own start script under `start`, which launches the
  worktree's main process; a Tauri app through its dev command or its built binary. On native
  Windows the helper's `start` refuses, because Windows has no POSIX process groups: every
  desktop row there is PARTIAL with that reason.
- **Teardown** stops the supervisor, which ends the app's whole process group. Never quit, kill or
  signal an app process the run did not start.

## 2. Data isolation decides whether the app may run

A desktop app keeps its data in a user-level location that any installed copy shares:
`~/Library/Containers/<bundle id>` for a sandboxed macOS app, `~/Library/Application Support/<name>`,
`~/Library/Preferences/<bundle id>.plist`, Electron's user-data directory, `%APPDATA%` on Windows,
`~/.config/<name>` on Linux. Its credentials live in the platform credential store: the login
Keychain on macOS, the Credential Manager on Windows, the Secret Service on Linux. A build of the
same app can read what the installed copy stored there and start signed in to a deployed backend.

- Before launching, find that location for this app from its bundle identifier, product name or
  code, and check the credential store for items under its service name or access group. An
  existing item counts as an existing location.
- **When it already exists and the recipe names no isolation switch, do not launch the app**:
  every row is PARTIAL, because the build would show and change the user's own data. The switch
  lives in `validate.desktop.dataIsolation`, and it must move the credentials too: a launch
  argument or environment variable that points both the app's data and its credential storage at
  `$RUN_DIR`, an in-memory or fixture store, or a verification build with its own bundle
  identifier and keychain access group.
- When it does not exist yet, the app may run. The location it creates lies outside the run
  directory, so the run leaves it in place and names it under Limitations.

## 3. Driving the window: the ladder

1. **A host computer-use tool**, when the session offers one. Ask access for the app under test
   only, and use its app-scoped screenshots, accessibility queries, clicks and typing. Its per-app
   grant is the user's answer, never given on their behalf.
2. **macOS UI scripting** with `osascript` and System Events, addressed by process id, never by
   name, because a name can match the installed copy:
   `tell application "System Events" to tell (first process whose unix id is <pid>)`. Read the UI
   tree with `entire contents of window 1`, click buttons, and type with `keystroke`. It needs the
   Accessibility permission for the app that runs the commands. That grant is the user's: never
   change privacy or security settings on their behalf. Without it the interactive rows are
   PARTIAL.
3. **Windows and Linux**: the platform's UI automation through a tool the project or the user
   already has (UI Automation on Windows, AT-SPI or `xdotool` on Linux), with commands taken from
   that tool's own help. This plugin has not measured these paths; the report says so.
4. **Nothing interactive available**: launch-only evidence (the app starts, its window appears
   in an app-window screenshot, its log stays clean). The interactive rows are PARTIAL and name
   the missing tool.

## 4. Evidence

- **App-window screenshots only, never the full screen**: other windows can show the user's
  private data. Use the computer-use tool's app-scoped screenshot, or on macOS
  `screencapture -x -o -l<window id>` with the id of a window the system window list shows as
  owned by the run's process id. Never capture a screen region: `-R` records whatever is drawn
  there, including notifications and other apps' windows. Without a window-scoped capture the
  visual plane is PARTIAL. Open each image with the Read tool and describe it.
- **Accessibility tree** from the computer-use tool or System Events. Without one the state plane
  is `visual-only`, backed by app data or the app log.
- **App log**: the supervisor log that `start` printed, and on macOS
  `log show --last 5m --style compact --predicate 'processIdentifier == <pid>'` with the `pid=`
  that `start` printed, never a process name, which also matches the installed copy. An app that
  starts helper processes is selected by `processImagePath BEGINSWITH "<physical path of its
  build output>/"` instead. Filter, bound and sanitize it; never copy raw lines into the report.
- **Crashes** on macOS leave an `.ips` report in `~/Library/Logs/DiagnosticReports`; read only the
  exception type and the first frames of the crashed thread of reports newer than the run's start.
- **Electron renderers**: this driver cannot read a renderer's DevTools console, and the `browser`
  driver cannot open an Electron app. Renderer console evidence is PARTIAL unless the app writes it
  to its own log.
