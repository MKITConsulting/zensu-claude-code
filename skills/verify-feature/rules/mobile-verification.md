# Mobile verification rules (`mobile`)

Loaded for rows whose driver is `mobile`. Simulators and emulators only: never a physical device,
and never a simulator or emulator the user already has. The run creates or starts its own device,
installs the worktree's build on it, and removes the device at teardown through the run-resource
helper (`rules/drivers.md` section 5). Replace `<absolute-plugin-root>` with the concrete `ROOT`
from `SKILL.md`.

## 1. iOS family: iPhone, iPad, Apple Watch, Apple TV, Apple Vision Pro

Needs macOS with Xcode, that is `xcrun` and `xcodebuild` on `PATH`; otherwise every iOS-family row
is PARTIAL and names the missing tool.

### Build facts

- **Scheme.** Each `.xcscheme` file in `<name>.xcodeproj/xcshareddata/xcschemes/`, or in the
  workspace's `xcshareddata/xcschemes/`, is one shared scheme. Take the one that builds the changed
  app target; ask one batched question only when two are equally plausible or none is shared.
- **No `xcodebuild` before the build.** Measured with Xcode 27.0: `xcodebuild -list` resolved the
  project's Swift packages first, fetched one over the network and rewrote the package state in
  the user's own DerivedData folder for that checkout. Treat `-showBuildSettings` the same way,
  because it opens the same project. Read the deployment target from
  `<name>.xcodeproj/project.pbxproj` instead (`IPHONEOS_DEPLOYMENT_TARGET` and its siblings).
- **Bundle identifier and executable** come from the built app's `Info.plist`:
  `/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleExecutable' <app>/Info.plist`.
- **Device type and runtime.** `xcrun simctl list devicetypes` and `xcrun simctl list runtimes`
  show what is installed. Pick the device family the target supports (an iPhone for iOS, an iPad
  when the change is iPad-specific, a watch for watchOS) and an installed runtime of the target's
  platform at or above its deployment target. `validate.mobile.deviceType` and
  `validate.mobile.runtime` in the recipe win. A missing runtime is a download: ask first.

### Device lifecycle

1. **Create** the run's device through the helper, which reads the UDID from stdout only (without
   a runtime, `simctl create` prints a notice on stderr that corrupts a `2>&1` capture):

   ```bash
   node "<absolute-plugin-root>/skills/verify-feature/scripts/verify-run-resources.js" create-simulator --run-dir "$RUN_DIR" --device-type "<device type id>" --runtime "<runtime id>"
   ```

   It prints `udid=<UDID>` and `name=zensu-verify-<run>`. Copy the UDID literally into every
   later call.
2. **Boot** it with `xcrun simctl boot <UDID>` and poll `xcrun simctl list devices --json` until its
   `state` reads `Booted`.
3. **Packages.** A project with Swift packages needs their checkouts in the run's own package
   directory, `$RUN_DIR/SourcePackages`; a fresh one is empty, and filling it from the network is a
   download, so ask first. When Xcode already resolved the packages for this project, clone that
   checkout instead: find the `~/Library/Developer/Xcode/DerivedData/<project>-*` folder whose
   `info.plist` `WorkspacePath` names this project, or the newest one for the same project name,
   then `cp -Rc <that folder>/SourcePackages "$RUN_DIR/SourcePackages"`. On APFS `-c` clones
   without copying the data. Never point the build at the user's own folder: the build writes into
   it.
4. **Build** the worktree for that exact device, out of tree:

   ```bash
   xcodebuild -scheme <scheme> -project <name>.xcodeproj -destination 'platform=iOS Simulator,id=<UDID>' -clonedSourcePackagesDirPath "$RUN_DIR/SourcePackages" -skipPackageUpdates -derivedDataPath "$RUN_DIR/DerivedData" -disableAutomaticPackageResolution build
   ```

   Use `-workspace` instead of `-project` for a workspace, and `watchOS Simulator`,
   `tvOS Simulator` or `visionOS Simulator` as the platform for those targets. Never put `name=`
   in a destination: a name can match one of the user's own simulators.
   `-disableAutomaticPackageResolution` keeps `Package.resolved` unchanged and
   `-skipPackageUpdates` keeps the build off the package remotes. Measured with Xcode 27.0 on a
   cloned checkout: the build resolved the graph from the clone and fetched nothing. When the
   build reports a missing package or one that does not match `Package.resolved`, resolving it is
   a download, so ask first. Find the `.app` under `$RUN_DIR/DerivedData/Build/Products/` by listing it, never by
   guessing the configuration directory: the measured app's scheme built `Release`.
5. **Install and launch** on the run's device only: `xcrun simctl install <UDID> <path to .app>`,
   then `xcrun simctl launch <UDID> <bundle id>`. Launch arguments follow the bundle id, the
   environment goes in `SIMCTL_CHILD_<NAME>` variables on that command, and
   `--terminate-running-process` restarts the app between scenarios.
6. **Teardown** through the helper's `teardown`, which shuts down and deletes exactly this UDID
   after checking the device still carries the run's name.

### Scenario setup on the run's device

- Deep and universal links: `xcrun simctl openurl <UDID> <url>`.
- Permission states: `xcrun simctl privacy <UDID> grant|revoke|reset <service> <bundle id>`. Its
  own help warns that bypassing the prompt can mask bugs: never use it when the criterion is about
  the permission prompt itself.
- Appearance and accessibility: `xcrun simctl ui <UDID> appearance dark|light`,
  `content_size <category>` and `increase_contrast enabled|disabled`.
- Push notifications, simulated location and media: `xcrun simctl push`, `location` and
  `addmedia`; read `xcrun simctl help <subcommand>` for their arguments.
- A backend the app calls runs through the recipe (`SKILL.md` Phase 2). The simulator shares the
  Mac's network, so a loopback backend is reachable from the app; point the app at it through the
  launch argument, `SIMCTL_CHILD_` variable or build configuration the recipe names.
- A build configured for a deployed backend contacts it at launch. Measured: an in-app purchase
  SDK loaded its offerings before the first tap. Name that under Limitations. Signing in,
  registering or submitting a form against a deployed backend still needs the user's yes.

### Driving the UI: the ladder

1. **A host simulator tool**, when the session offers one that can tap, swipe, type and take
   screenshots. Pass the run's UDID on EVERY call: such a tool defaults to an attached or first
   booted simulator, which can be the user's own. Coordinates are device points: take a
   screenshot, read it, then tap. A `simctl io` screenshot is in pixels, so divide by the
   device's scale factor, its pixel width over its point width.
2. **Maestro**, when installed. Write flow files into `$RUN_DIR/flows/`, select the run's device
   with the device option `maestro --help` names, and run `maestro test <flow file>`. A flow is
   YAML:

   ```yaml
   appId: <bundle id>
   ---
   - launchApp
   - tapOn: "<visible label>"
   - assertVisible: "<expected text>"
   - takeScreenshot: "<row>-<step>"
   ```

   `maestro hierarchy` prints the accessibility hierarchy for the state plane.
3. **A simulator accessibility CLI** such as AXe or idb, when installed. Take its flags from its
   own `--help`, name the run's UDID on every call, and use it for the hierarchy and for input.
4. **Nothing interactive available**: launch-only evidence (screenshot, app log, data container)
   for the rows that need no interaction. Every interactive row is PARTIAL and names the missing
   tool.

### Evidence

- **Screenshot**: `xcrun simctl io <UDID> screenshot "$RUN_DIR/shots/<row>-<step>.png"`, or the
  host tool's screenshot. Open each image with the Read tool and describe what it shows.
- **Accessibility hierarchy** from Maestro or the accessibility CLI. Without one, the state plane
  is `visual-only`, backed by the data container or the app log.
- **App log**, filtered to the app's process and bounded:
  `xcrun simctl spawn <UDID> log show --last 5m --style compact --predicate 'process == "<executable>"'`.
  Report warning and error classes, never raw lines.
- **Crashes** leave an `.ips` report named after the executable in
  `~/Library/Logs/DiagnosticReports`. List the ones newer than the run's start and read only the
  exception type and the first frames of the crashed thread.
- **Stored data**: `xcrun simctl get_app_container <UDID> <bundle id> data` prints the data
  container. Read the files the criterion names without changing them, for example a preferences
  plist with `plutil -p` or a store with `sqlite3 -readonly`.

## 2. Android: phone, tablet, Wear OS, Android TV, Automotive

Needs the Android SDK, that is `adb` and `emulator` on `PATH` (`platform-tools/` and `emulator/`
under the SDK root); otherwise every Android row is PARTIAL and names the missing tool.

- **Every `adb` call names `-s <serial>`.** A phone or the user's own emulator can be connected at
  the same time, and `adb devices` lists them all. Touch only the serial the run recorded.
- **Never `./gradlew installDebug`**, or any task that installs on every connected device: it would
  install on the user's phone too. Build with the module's assemble task (for example
  `./gradlew :<module>:assembleDebug`) and install the APK with `adb -s <serial> install -r <apk>`.
- **The emulator is the run's own.** Never start or use an AVD the user already has: its
  accounts, installed apps and app data come with it, and a read-only start does not keep them
  out of the evidence. Create a run-owned AVD beneath the run directory from the installed
  system image the recipe names in `validate.mobile.systemImage`; a missing image is a download,
  so ask first. Take the options from the installed `avdmanager` and `emulator -help`, and keep
  `ANDROID_AVD_HOME="$RUN_DIR/avd"` on every `avdmanager` and `emulator` call, so the AVD lives
  and dies with the run directory:

  ```bash
  ANDROID_AVD_HOME="$RUN_DIR/avd" avdmanager create avd -n <prefix> -k "<system image>" < /dev/null
  ```

  Pick an even console port that `adb devices` does not list; `record` refuses a serial that is
  already running. Record the serial, then start the emulator under the supervisor:

  ```bash
  node "<absolute-plugin-root>/skills/verify-feature/scripts/verify-run-resources.js" record --run-dir "$RUN_DIR" --kind android-emulator --id emulator-<port>
  node "<absolute-plugin-root>/skills/verify-feature/scripts/verify-run-resources.js" start --run-dir "$RUN_DIR" --name emulator --cwd "$RUN_DIR" -- env ANDROID_AVD_HOME="$RUN_DIR/avd" emulator -avd <prefix> -port <port> -no-snapshot
  ```

  Wait with `adb -s emulator-<port> wait-for-device`, then poll
  `adb -s emulator-<port> shell getprop sys.boot_completed` until it prints `1`. On native
  Windows the helper's `start` refuses, because Windows has no POSIX process groups: the
  emulator rows there are PARTIAL with that reason.
- **Launch** with `adb -s <serial> shell am start -n <application id>/<activity>`.
- **Driving the UI**: Maestro with the run's device selected, else
  `adb -s <serial> shell input tap <x> <y>`, `input text` and `input keyevent`, with coordinates
  read from the hierarchy.
- **Evidence.** Hierarchy: `adb -s <serial> shell uiautomator dump /sdcard/window.xml`, then
  `adb -s <serial> pull` it into `$RUN_DIR`. Screenshot:
  `adb -s <serial> exec-out screencap -p > "$RUN_DIR/shots/<row>-<step>.png"`. Log: `logcat -d`
  with `--pid` set to the app's process id from `adb -s <serial> shell pidof <application id>`.
  Crashes: `logcat -d -b crash`.
- **Teardown** through the helper: it stops the supervised emulator process group, then checks
  through `adb devices` that the recorded serial is gone. It never sends `emu kill`, which would
  reach whichever emulator holds that console port; a serial that stays listed is kept and
  named.

## 3. Cross-platform frameworks

- Build each platform's artifact with the framework's own documented command for a simulator or
  emulator target (Flutter, React Native, .NET MAUI, Kotlin Multiplatform, Capacitor or Ionic), then
  follow section 1 or 2 for the device, install, launch and evidence.
- A framework's `run` command that picks the first available device is forbidden: it can pick
  the user's phone. Name the run's device explicitly, or install the built artifact with `simctl`
  or `adb`.
- A JavaScript bundler or dev server the debug build needs (React Native's, for example) is a
  service: start it with the helper's `start` and wait for its readiness before launching the app.
- A hybrid app's web layer may additionally be verified with the `browser` driver for criteria
  that are web-observable; a criterion about the native shell still needs this driver.
