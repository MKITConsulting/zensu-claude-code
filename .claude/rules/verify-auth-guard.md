---
paths:
  - "hooks/lib/verify-auth-state-v1.js"
  - "hooks/lib/verify-auth-guard-v1.js"
  - "hooks/pre-verify-auth-guard.sh"
  - "scripts/verify-browser-config.js"
  - "tests/structure/verify-auth-state-v1.test.js"
  - "tests/structure/verify-auth-guard-v1.test.js"
  - "tests/structure/verify-auth-login-e2e.test.js"
  - "skills/verify-feature/rules/browser-verification.md"
---

# Signed-In Verify Runs (`verify-auth-state-v1.js` + `verify-auth-guard-v1.js` + `--login-recipe`)

`/zensu:verify-feature` can open a browser that is already signed in to a dedicated test account.
The decisions and the threat model are in `docs/verify-feature-auth-state-spec.md`; the operator
account is `docs/verify-feature.md` §6, `docs/gates.md` §"Browser Consent Gate" (Signed-in
sessions) and §"Verify-Auth Read Guard".

**One setter, one location.** The only way a run config restores state is
`browser.contextOptions.storageState` equal to `auth/storage-state.json` beside the config, in a
`<project>/.zensu/verify-feature-runs/<leaf>` directory (`runConfigShape`, `statePathFor`,
`runDirLayout`). `state-load` stays denied: a setter command with a free path argument would
need containment rules of its own and gains nothing over the config key. The layout is enforced
for the login and for the config alike, so the read guard's pattern always covers the auth
directory.

**The login lives in the run-config helper.** `--login-recipe` reads the recipe's `auth` block
with a strict reader (`readAuthBlock`: `key: scalar` lines only), runs `auth.loginScript` with
`bash -c` in the project root, detached in its own process group, stdin closed, stdout capped at
64 KiB, stderr discarded, 300 s timeout, and prints only a fixed failure class
(`LOGIN_FAILURES`). The artifact must sit physically beneath the fresh `auth/artifact/`, is
scoped to the run's origins and written owner-only with a `.gitignore` of `*`; the artifact
directory is removed whatever the outcome. The helper refuses `--login-recipe` unless
`authGuardRegistered` answers `registered`, so no state is written without the guard.

**The gate parses before the browser does.** V8's `JSON.parse` error echoes the first
characters of a non-JSON file and `playwright-cli` prints that error, so `open` is never the first
parser of a state file: `checkStateFile` validates file safety, size, shape and scope, and every
deny reason is a fixed string (`STATE_*` in `REASONS`). The state file is read twice more after
that, by the browser at launch and never by anything else.

**The session prefix decides the signed-in rules.** A state-restoring config opens only on a
`zensu-verify-auth-` session, and on such a session `console` and `requests` deny with the final
`AUTH_SIGNAL_DENIED`. The helper prefixes a plain run's session name that would start with `auth`
with `run-`, so a plain run never lands on the signed-in prefix.

**Consumed once, after recording.** `runPost` records first and deletes the state in a `finally`
(`consumeRestoredState`): the recording evaluates the same `open` again, and with the file gone
that evaluation would deny `STATE_CONSUMED` and drop the record. A failed `open` fires no
PostToolUse event, so the file then waits for the Phase 4 cleanup. Records gain the optional
`restoredState: true`; no `MEMORY_VERSION` bump, because older readers ignore the field and
deduplication keys on `(origin, route, restoredState)`.

**The read guard is textual and in-process.** `verify-auth-guard` in `DISPATCHED_CHECKS` runs no
body and fails open, except that a payload naming `verify-feature-runs` is refused when the
decision module is absent, a symlink or broken. Three copies of the marker test exist and must
agree: `marked` in the guard module, `authGuardMarked` in `hooks/lib/hook-dispatch-v1.js`, and the
no-`node` fallback of `hooks/pre-verify-auth-guard.sh`; each strips backticks, quotes and
backslashes and folds case. The unit file compares the first two; the fallback is held only by
its own wrapper case. The tool set has ONE owner, `AUTH_GUARD_TOOLS` in
`verify-auth-state-v1.js`: `GUARD_MATCHER` derives from it, the registry entry spells the same
string, and the guard's unit file compares them.

**It binds no session and never stands between a session and its repair commands.** The guard
judges only a payload that names a verify-feature run directory, so it allows `/zensu:doctor`
and the adoption command in every bind state and on every platform. That is why
`adopt_hook_expected` in `tests/structure/test-versioned-plugin-upgrade.sh` lists
`pre-verify-auth-guard.sh` among the Bash-matcher hooks that allow there even on win32, and why
O21a and O21c in `tests/structure/test-orphaned-project-root.sh`, which enumerate the Bash
matcher, need no entry for it.

**The doctor names the guard after the consent pair.** `safeVerifyReason` caps the
`verify-feature` reason at 200 characters, and three registration causes overflow it, so the
guard's registration is probed only once both consent hooks are registered (P1vl11 to P1vl13 in
`tests/structure/test-doctor.sh`).

**Coupled sites:** `AUTH_SESSION_PREFIX`, `AUTH_GUARD_HOOK_FILE`, `AUTH_GUARD_TOOLS`, the caps
and `FAULTS` in `verify-auth-state-v1.js`; `runConfigShape`, `judgeCall`, `evaluate`, `runPost`,
`authGuardRegistered` and the `STATE_*` and `AUTH_SIGNAL_DENIED` reasons in
`hooks/lib/verify-consent-v1.js`; `checkReadiness`, `signIn`, `sessionName` and `LOGIN_RESTORED`
in `scripts/verify-browser-config.js`; the `verify-auth-guard` registry entry and
`runAuthGuard`; the guard probe and its three file branches in `hooks/lib/zensu-doctor.sh`; the
recorded command list `tests/structure/fixtures/playwright-cli-commands.v1.json`, which moves with
`PLAYWRIGHT_CLI_SOURCE_VERSION` exactly as the argv fixture does; the PowerShell disposition row
in `tests/structure/test-powershell-tool-coverage.sh`; the hook lists of
`evals/session-control/tests/upgrade-hook-contract.test.js`; and the prose in
`skills/verify-feature/SKILL.md` §Authentication, `rules/browser-verification.md` §0, §3, §4 and §6,
`rules/attach.md`, `rules/setup.md`, `skills/autopilot/rules/auth.md` and `config.md`, the hook
row and counts in `docs/configuration.md` and the roster rows in `docs/session-control.md` and
`docs/architecture.md`.

**Version: `minor`.** Walked against §"Runtime Lineage": a hook that can return a
`permissionDecision` joined the file, search and shell matchers, the strict key set of the run
config widened (`browser.contextOptions` may carry `storageState`), and the consent gate denies
two commands it admitted on a signed-in session. The consent memory gains an optional field read
permissively, which on its own would be a `patch`.

**Known gaps, accepted and named:**

- The guard is textual: a path assembled at run time, a command run from inside the run
  directory that names `auth/` relatively, and a recursive search or copy started above the run
  directory are not judged; a recursive Grep from the project root relies on the `.gitignore`,
  which ripgrep honours only inside a git work tree. `**` at or above a run directory is denied
  even where it could not reach `auth/`.
- The state exists on disk from the login to `open`; a refused prompt, a failed `open` or a crash
  leaves it until cleanup. A file swapped between the gate's check and the browser's launch is
  followed, the class of the run-config swap.
- The model's shell runs as the same user as the browser, so the guard stops accidents and
  injected instructions, not a determined actor. What the app renders reaches the model by
  design, which is why the docs demand a dedicated test account with synthetic data.
- The runtime-signal plane of a signed-in row stays PARTIAL until a trusted sanitizer exists.
- The integration test drives a real browser only where `playwright-cli` 0.1.21 and Chrome are
  installed; on the Linux CI runners it skips with its reason.
- Windows is unverified end to end, and no port (`zensu-codex`, `zensu-kiro`,
  `zensu-antigravity`) was included.
