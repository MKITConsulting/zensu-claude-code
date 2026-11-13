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
(`LOGIN_FAILURES`, or `exit <n>`; `LOGIN_FAILURE_RE` matches every failure line it can print). A
`SIGTERM`, `SIGINT` or `SIGHUP` to the helper (`ABORT_SIGNALS`) kills the login's process group
and removes the artifact directory before the helper exits `128 + n`; the skill gives the helper
call a Bash timeout of 330000 ms, above the login's own bound, so the host's timeout does not
fire first. The auth origin must be one of the `--origin` values, and in remote mode the
recipe's `auth.baseUrl`, or `auth.appOrigin` without one. In local mode nothing binds the
loopback origins to the recipe, which is why the docs require a throwaway local account. The
artifact must sit physically beneath the fresh `auth/artifact/`, is scoped to the run's origins
and written owner-only with a `.gitignore` of `*`; the artifact directory is removed whatever
the outcome. The helper refuses `--login-recipe` unless `authGuardRegistered` answers
`registered`, so no state is written while `hooks/hooks.json` does not register the guard;
whether the host runs it is not observed.

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
that evaluation would deny `STATE_CONSUMED` and drop the record. A recorder that cannot bind a
session still consumes: it hands `runPost` an empty memory path, which records nothing and still
reaches the `finally`. A failed `open` fires no PostToolUse event, so the file then waits for
Phase 4, which runs the helper's `--discard-state --run-dir <run dir>` before teardown.
`discardAuthState` removes the run's `auth/` directory once `runDirLayout` accepts the run
directory and only when `auth` is a plain directory, so a run directory Phase 4 keeps after an
incomplete teardown no longer keeps the state. Records gain the optional
`restoredState: true`; no `MEMORY_VERSION` bump, because older readers ignore the field and
deduplication keys on `(origin, route, restoredState)`.

**The read guard is textual and in-process.** `verify-auth-guard` in `DISPATCHED_CHECKS` runs no
body and fails open, except that a payload naming `verify-feature-runs` is refused when the
decision module is absent, a symlink or broken. Three copies of the marker test exist and must
agree: `marked` in the guard module, `authGuardMarked` in `hooks/lib/hook-dispatch-v1.js`, and the
no-`node` fallback of `hooks/pre-verify-auth-guard.sh`; each strips backticks, quotes and
backslashes and folds case. The unit file compares the first two; the fallback is held only by
its own wrapper case. Beside the path rules the guard refuses a browser call that names a run
directory without naming a `zensu-verify` session (`REASONS.SESSION`), because the consent gate
judges only `zensu-verify` sessions and a signed-in run config opened on another session would
restore the state unjudged. That rule's markers derive from their owners: `CLI_WORDS` from
`BINARY_NAMES` and `PACKAGE_NAME` of `playwright-cli-version-v1.js`, `SESSION_MARKER` from
`AUTH_SESSION_PREFIX`. The tool set has ONE owner, `AUTH_GUARD_TOOLS` in
`verify-auth-state-v1.js`: `GUARD_MATCHER` derives from it, the registry entry spells the same
string, and the guard's unit file compares them.

**Below a run directory a path is read conservatively, never dialect by dialect.** The guard
translates no glob into a regular expression, because the shells disagree on nested classes, a
quoted or escaped `]`, an unmatched brace before a valid group and zsh groups, and a translation
that misreads one form lets that form reach `auth/`. `couldBeAuth` counts a plain name only when it is `auth` once
trailing dots and spaces are dropped, a glob of `*`, `?` and brackets unless its literal head or
tail rules `auth` out, and every other segment always. `shifts` names the segments that can stand
for `..`, `.` or no directory (a brace or group character, `$`, a backtick, a dot glob, an all-dot
name); after one every later segment is a candidate, and after `**` too once a `..` follows.
`shellWords` splits a command as a POSIX shell does (quotes and escapes removed, a quoted space or
`;` kept inside its word, `;&|<>` breaking words, a zsh `<n-m>` range kept whole), and every
spelling is read with its backslashes as escapes and again as separators. Only a space, a tab or
a newline separates Bash words, never JavaScript's `\s`: bash keeps a no-break space or a carriage
return inside a word, so splitting there would cut a run path before a `..`. PowerShell text
splits on every whitespace character, as PowerShell does. Do not reintroduce glob
translation to win back a false positive.

**It binds no session and never stands between a session and its repair commands.** The guard
judges only a payload that names a verify-feature run directory, so it allows `/zensu:doctor`
and the adoption command in every bind state and on every platform. That is why
`adopt_hook_expected` in `tests/structure/test-versioned-plugin-upgrade.sh` lists
`pre-verify-auth-guard.sh` among the Bash-matcher hooks that allow there even on win32, and why
O21a and O21c in `tests/structure/test-orphaned-project-root.sh`, which enumerate the Bash
matcher, need no entry for it.

**The doctor names the guard after the consent pair.** `safeVerifyReason` caps the
`verify-feature` reason at 200 characters, and three registration causes overflow it, so the
guard's registration is probed only once both consent hooks are registered (P1vl14 to P1vl16 in
`tests/structure/test-doctor.sh`). The causes block different runs: a missing, symlinked or
unloadable guard module makes the dispatcher refuse every call that names a run directory, while
a missing entry point or an unregistered guard blocks only `--login-recipe`.
`skills/doctor/references/verify-auth-guard.md` says so per cause, and the doctor skill points
there instead of listing them, because its body sits on the shrink-only allowlist.

**Coupled sites:** `AUTH_SESSION_PREFIX`, `AUTH_GUARD_HOOK_FILE`, `AUTH_GUARD_TOOLS`, the caps,
`FAULTS` and `discardAuthState` in `verify-auth-state-v1.js`; `CLI_WORDS`, `SESSION_MARKER` and
`REASONS.SESSION` in the guard; `runConfigShape`, `judgeCall`, `evaluate`, `runPost`,
`authGuardRegistered` and the `STATE_*` and `AUTH_SIGNAL_DENIED` reasons in
`hooks/lib/verify-consent-v1.js`; `checkReadiness`, `signIn`, `sessionName`, `LOGIN_RESTORED`,
`LOGIN_FAILURE_RE`, `ABORT_SIGNALS`, `discardState` and `DISCARD_USAGE` in
`scripts/verify-browser-config.js`; the `verify-auth-guard` registry entry and
`runAuthGuard`; the guard probe and its three file branches in `hooks/lib/zensu-doctor.sh`, which
`skills/doctor/references/verify-auth-guard.md` must name cause by cause; the
recorded command list `tests/structure/fixtures/playwright-cli-commands.v1.json`, which moves with
`PLAYWRIGHT_CLI_SOURCE_VERSION` exactly as the argv fixture does; the PowerShell disposition row
in `tests/structure/test-powershell-tool-coverage.sh`; the hook lists of
`evals/session-control/tests/upgrade-hook-contract.test.js`; and the prose in
`skills/verify-feature/SKILL.md` §Authentication and its Phase 4 discard bullet, `rules/browser-verification.md` §0, §3, §4 and §6,
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
  directory that names `auth/` relatively, and a recursive command started at or above the run
  directory, such as a `grep -r`, `cp -r` or `tar` of the run directory itself, are not judged;
  a recursive Grep from the project root relies on the `.gitignore`, which ripgrep honours only
  inside a git work tree. A runs directory whose own name is a glob or an expansion
  (`.zensu/verify-*-runs`) is not recognized, because the dispatcher reads only payloads that name
  `verify-feature-runs`. The session rule reads the command text too, so a copy of a signed-in run
  config outside a run directory escapes it.
- The path rule over-denies on purpose: `**` at or above a run directory, a segment at the `auth`
  position that is neither a plain name nor a glob whose head or tail rules `auth` out
  (`{a,b}.png`, `$NAME`), and, in PowerShell's whitespace-free spelling, an argument written right
  after a file directly below a run directory.
- Only the nine tools are judged: an MCP server's file reader or an IDE's file tool reaches
  `auth/` unjudged. Hooks switched off host-side judge nothing.
- Local mode signs in on the run's loopback origins, which the caller chooses and nothing binds
  to the recipe, so a loopback listener the model started would receive the credentials. The
  docs require a throwaway account only the local app knows; binding a local recipe's origin is
  the standing fix.
- Cookies are scoped by host, not by port, and a parent-domain cookie (`.example.com`) is kept
  when a run origin's host lies below it, so the restored session reaches every approved port of
  a host and a sibling host a redirect lands on.
- The state exists on disk from the login to `open`; a refused prompt or a failed `open` leaves
  it until Phase 4 discards it, and a crash or `SIGKILL` before cleanup leaves it behind. A file swapped between the gate's check and the browser's launch is
  followed, the class of the run-config swap.
- The model's shell runs as the same user as the browser, so the guard stops accidents and
  injected instructions, not a determined actor. What the app renders reaches the model by
  design, which is why the docs demand a dedicated test account with synthetic data.
- The runtime-signal plane of a signed-in row stays PARTIAL until a trusted sanitizer exists.
- The integration test drives a real browser only where `playwright-cli` 0.1.21 and Chrome are
  installed; on the Linux CI runners it skips with its reason.
- Windows is unverified end to end, and no port (`zensu-codex`, `zensu-kiro`,
  `zensu-antigravity`) was included.
