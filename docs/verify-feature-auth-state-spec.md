# Verify-Feature Test-Account Login (Opaque Browser State) — Specification

Status: approved 2026-11-06 (§9) and built. This file keeps the decisions and the threat model
as they were approved; the current behaviour is described in
[gates.md §Verify-Auth Read Guard](gates.md#verify-auth-read-guard), the signed-in paragraph of
[gates.md §Browser Consent Gate](gates.md#browser-consent-gate) and
[verify-feature.md §6](verify-feature.md#6-signing-in-with-a-test-account), which win where they
differ.

Every claim below about the code before the build was read from `b96cd011`; every claim about
`playwright-cli` behaviour was measured against the installed 0.1.21 unless it says otherwise.

## 1. Problem

`/zensu:verify-feature` is credential-blind by design. `SKILL.md` §Authentication forbids
`auth.loginScript`, refuses every `STORAGE_STATE`, and allows only a visible manual login; the
browser consent gate (`hooks/lib/verify-consent-v1.js`) admits an allowlist of commands that
contains no cookie, storage or state command. Every authenticated scenario therefore needs a human
to type a password into a headed browser on every run, or it ends PARTIAL. The user ran the skill
against `app.zensu.dev` and does not want to log in by hand each time.

`SKILL.md` already names the intended direction: "A future gate may re-enable opaque state only
when it admits a path-contained setter and hard-denies every getter/exporter."
`/zensu:autopilot` already has the login-script convention (`skills/autopilot/rules/auth.md`):
a project script holds the secret, writes a Playwright `storageState` file beneath
`ZENSU_AUTH_ARTIFACT_DIR`, and prints one line, `STORAGE_STATE=<path>`.

## 2. What it does

When the selected recipe declares a login script, the run-config helper runs it, hidden from the
model, turns its artifact into a validated state file inside the run directory, and writes the
run config so that `playwright-cli open` starts the isolated browser already signed in. The model
handles only the run config path, exactly as today. It never sees the password, the script's
output, or the state file's content, and every command that could print state stays denied.

```
model ── node verify-browser-config.js --run-dir R --mode M --origin O --login-recipe P
            │  reads P's auth block, runs auth.loginScript (stdout/stderr never shown),
            │  validates + scopes the artifact, writes R/auth/storage-state.json (0600),
            │  writes R/playwright-cli.json with contextOptions.storageState → that file
            └─ prints: session=zensu-verify-auth-… config=R/playwright-cli.json mode=… origin=… login=state-restored
model ── playwright-cli -s=zensu-verify-auth-… open --config=R/playwright-cli.json <url>
            gate: validates the state file, asks consent (signed-in wording), admits open
            browser: newContext({ storageState }) → signed in
            recorder: deletes R/auth/storage-state.json (consumed once)
model ── snapshot / screenshot / click … on authenticated pages (console and requests denied)
```

## 3. Who it is for

- A developer verifying a feature behind a login on a local stack the recipe boots, with a seeded
  throwaway account (the `scripts/autopilot-runtime.sh login` pattern of the monorepo).
- The same against a hosted test environment (staging, preview) with a dedicated test account
  whose password lives in the developer's environment or keychain.
- `--chain` runs of `/zensu:build`, whose browser rows are local and currently cap at PARTIAL for
  anything behind the login.

## 4. Who it is NOT for

- Anyone who wants the model to know or handle the password: the model never types it.
- Personal accounts. The login script signs in a dedicated test account; the docs forbid using
  the developer's own account (manual login stays available for that, as today).
- Apps whose login needs a second factor or a CAPTCHA a script cannot complete — they keep
  visible manual login.
- Non-browser drivers. `api`/`cli` rows keep their current rule (no secret in a command; a
  criterion needing a token file is PARTIAL).

## 5. Success criteria

1. A verify-feature run against a local stack whose recipe declares `auth.mode: login-script` and
   `auth.artifact: storageState` reaches an authenticated page with no manual login. Proven by an
   integration test with a fixture app, the real `playwright-cli` at its measured version and the
   real gate module.
2. Every command that could reveal state or credentials stays denied on every `zensu-verify`
   session, signed-in or not: `state-save`, `state-load`, every `cookie-*`, `localstorage-*`,
   `sessionstorage-*`, `eval`, `run-code`, `config-print`, `request`, `request-*`, `response-*`,
   `route`, `route-list`, `unroute`, `network-state-set`, `delete-data`, `upload`, `drop`, `pdf`,
   recording, tracing, video, `attach`, `detach`, `install*`, `close-all`, `kill-all`, and the
   flags `--filename`, `--persistent`, `--profile`. Proven by a table-driven test over the
   measured version's command list (`help.json`).
3. `console` and `requests` are denied on a signed-in session (new, enforced).
4. The state file never outlives the `open` that consumed it, and never leaves the run directory.
5. The skill docs describe the mode, its targets and its limits; the structure tests that pinned
   the old "never" wording pin the new contract instead.

## 6. Design

### 6.1 The setter: one run-config key, no new command

Measured: `playwright-cli` 0.1.21 passes the run config's `browser.contextOptions` to
`browser.newContext()` for an isolated browser, and Playwright reads a string `storageState` as a
file path. A probe opened a session with such a config and no URL, deleted the state file, then
navigated: the page received the cookie and the localStorage entry. So the context is created at
`open`, and the file is no longer needed afterwards.

- `runConfigShape` accepts `browser.contextOptions` with exactly `serviceWorkers: "block"`, or
  that plus `storageState`. `storageState` must be a string equal to
  `<realpath(dirname(config))>/auth/storage-state.json`. Inline state objects, relative paths and
  any other location are refused, so the run config, which the model reads, never carries state.
- `state-load` stays denied: a setter command with a free path argument would need its own
  containment rules and has no benefit over the config key.

### 6.2 The login step inside the run-config helper

`scripts/verify-browser-config.js` gains `--login-recipe <abs path>`. The caller names no login
origin: the login runs before any consent prompt, so the checked-in recipe is the only approval
of where credentials go. With `--login-recipe` it:

1. Reads the recipe's top-level `auth:` block with a strict reader: `key: scalar` lines only
   (plain, single- or double-quoted); a flow collection, block scalar, anchor, alias, tag or
   multi-line value refuses the whole block. It needs `mode: login-script`,
   `artifact: storageState` and a `loginScript`. The recipe must be a regular file inside the
   project root.
2. Binds the login origin. In remote mode it requires `auth.appOrigin` equal to the first
   `--origin` and `auth.environment` declared (§6.6); the login origin is `auth.baseUrl`,
   validated as an absolute origin and required to equal one of the run's origins, or
   `auth.appOrigin` when `baseUrl` is absent. In local mode the login origin is the run's own
   loopback app origin, the first `--origin`; the recipe's `baseUrl`/`appOrigin` are not
   compared, because a consent-mode local run picks its port per run. A login is never sent to an
   origin the recipe did not bind.
3. Creates `R/auth/` (0700, must not exist yet, or holds only a previous state this helper wrote)
   with a `.gitignore` of `*` — the monorepo does not ignore `.zensu/verify-feature-runs/`, so
   `git add -A` would otherwise stage it — and a fresh `R/auth/artifact/` (0700).
4. Runs `bash -c <loginScript>` in the project root, detached in its own process group, stdin
   closed, stdout captured in memory (64 KiB cap), stderr discarded, 300 s timeout. Environment:
   the parent's, plus the canonical `ZENSU_AUTH_ARTIFACT_DIR=R/auth/artifact`,
   `ZENSU_AUTH_BASE_URL=<login origin of step 2>`, `ZENSU_APP_ORIGIN=<first --origin>`.
5. Requires stdout to be exactly one non-empty line `STORAGE_STATE=<abs path>`, the path a
   regular, non-symlink, single-link file physically beneath `R/auth/artifact/`.
6. Parses it (1 MiB cap) as Playwright storage state, keeps only cookies whose domain
   domain-matches a host of the run's origins and only `origins[]` entries equal to a run origin,
   and fails when nothing remains. Writes the result atomically to `R/auth/storage-state.json`
   (0600) and removes `R/auth/artifact/` whatever the outcome.
7. Writes the run config with `storageState` and names the session `zensu-verify-auth-<slug>`.

Output on success adds one line, `login=state-restored`. On failure it exits 1, writes no run
config, and prints only a fixed class: `login failed: recipe`, `timeout`, `exit <code>`,
`contract`, `artifact-path`, `artifact-shape` or `artifact-scope` — never a byte of the script's
output. The skill then falls back to visible manual login or PARTIAL, and tells the user to run
the login script in their own terminal to debug it.

A fresh browser (scenario isolation) means running the helper again: a fresh login, a fresh state,
the same config content.

### 6.3 Gate changes (`hooks/lib/verify-consent-v1.js`)

- **`open` with state.** Allowed only on a session named `zensu-verify-auth-…`; the helper prints
  that name. The gate re-validates the state file before admitting `open`: regular file, not a
  symlink, one link, owner-only mode on POSIX, within 1 MiB, valid storage-state JSON, every entry
  inside the run config's origins. Measured: V8's `JSON.parse` error echoes the first characters
  of a non-JSON file (`"eyJhbGciOi"...` for a raw JWT), and `playwright-cli` prints that error, so
  `open` must never be the first parser of a bad file. Deny reasons are fixed strings.
- **Signed-in sessions.** On any `zensu-verify-auth-…` session `console` and `requests` are denied
  (final reason). Today's skill text already forbids them on authenticated targets; this makes it
  a gate rule for the sessions the gate can identify.
- **Other sessions.** A command that names `playwright-cli` is also judged when its text names a
  `.zensu/verify-feature-runs/` directory or passes a config (`--config`, or an inline
  `PLAYWRIGHT_MCP_CONFIG`), whatever its session name, one from `PLAYWRIGHT_CLI_SESSION`
  included. A gated `zensu-verify-…` call keeps the rules above, so a signed-in config is
  admitted only as one plain gated call on a `zensu-verify-auth-…` session with the canonical run
  config. Any other session's call is denied with a final reason when the command names a run
  directory, or when its config file carries `browser.contextOptions.storageState`. The gate reads
  that config as the CLI does, and refuses one it cannot read as JSON (missing, not a regular
  file, over 1 MiB, invalid JSON, an `.ini` path, which the CLI reads as INI) and a relative config
  path in a command that is not one plain unwrapped call. `state-load` stays denied. Measured in
  the specification session: a session outside the gate (`-s=zvprobe-state1`) that opened a
  `storageState` config came up signed in.
- **Getters and exporters.** No change to the allowlist: every command in §5.2 stays outside it
  for every session. New tests pin that.
- **Consumed once.** The PostToolUse recorder deletes `R/auth/storage-state.json` after every
  `open` on a state-restoring config that reached it, interrupted or not, after the same path
  checks. A refused prompt never reaches the recorder; the file then dies with the run directory
  in Phase 4.
- **Consent memory.** Records may carry `restoredState: true`. No version bump: the field is
  optional, older readers ignore it, and dedupe keys on `(origin, route, restoredState)`.

### 6.4 Consent and the origin boundary with a restored session

- **Same prompt, same call.** The state is applied by the `open` that raises the consent prompt
  for the run config's origins, so no origin is approved without the user being told the browser
  is signed in. The prompt adds: "The browser opens signed in: its state was restored from the
  recipe's login script, so the model can reach every page that account can reach on these
  origins."
- **Loopback:** a restored-state `open` is asked once per Claude Code session per origin. An
  earlier approval of the same origin without state does not cover it (`restoredState` record).
- **Remote:** asked at every `open`, as today.
- **Policy targets** (`ZENSU_VERIFY_NAVIGATION_POLICY_V1`): pass silently, as today. The recipe's
  login script and the credentials the user provisioned are the opt-in for unattended runs.
- **Scope stays with the run's hosts.** The state holds cookies whose domain is the host of a
  run-config origin or, written with a leading dot, a parent domain of one, and origin entries
  for the run config's origins only, and the browser refuses every HTTP(S) request outside those
  origins. Cookies are scoped by host, not by port, so every approved port of a host receives
  them, and a parent-domain cookie also reaches a sibling host a redirect lands on before the
  redirect rule stops that page.
- **Redirects** keep today's rule. A redirect to a login page or an identity provider on another
  origin means the state did not sign in: stop driving that page, report PARTIAL, optionally fall
  back to visible manual login in a fresh non-restored session.

### 6.5 Read guard for the auth directory

A new dispatched PreToolUse check on every tool (matcher `.*`), `verify-auth-guard` (decision
module `hooks/lib/verify-auth-guard-v1.js`, fail-closed only for payloads that name
`verify-feature-runs`): it denies `Read`, `Grep`, `Glob`, `NotebookEdit`, `Edit`, `Write` and
`MultiEdit` on a path inside any `.zensu/verify-feature-runs/<leaf>/auth/`, a `Bash` or
`PowerShell` command whose text names such a path, and any other tool, an MCP tool included,
whose payload names `verify-feature-runs` and whose input holds a string that reaches such a
path, read as shell text or as a path. The skill never names that directory in a command;
teardown removes the run directory by its own path. Together with the `.gitignore`
(ripgrep, which backs Grep, honours nested ignore files) this closes the accidental and the
injected "just read the state file" routes. It is a textual guard, not a sandbox: it judges only
a payload that names `verify-feature-runs`, so shell text that reaches `auth/` through a symlink
alias of a runs directory or, on Windows, an 8.3 short name such as `VERIFY~1` is not judged
(§6.7).

### 6.6 Targets

| Target | Mode | Rule |
|---|---|---|
| Local stack booted by the recipe | `local` | supported; loopback only (unchanged floor) |
| App the user runs (`--attach`) | `local` | supported when a recipe with an `auth` block is selected |
| Hosted test environment (staging, preview) | `remote` | supported when the checked-in recipe binds the origin (`auth.appOrigin`) and declares `auth.environment: test` |
| Production | `remote` | supported as an explicit opt-in: the checked-in recipe binds the origin and declares `auth.environment: production` (§9) |

`auth.environment` is a new optional recipe key, `test` or `production`, required in remote mode
and ignored in local mode. It is a reviewable declaration in a checked-in file; the plugin cannot
tell a production host from a test host by itself.

### 6.7 Threat model

| Channel | Mitigation | Residual |
|---|---|---|
| Password reaches the model | Script holds or derives it; recipe names an env var at most; helper never shows script output | The model's shell can read anything the user can (env, keychain, files). Docs recommend a keychain or password-manager lookup inside the script over a plain env var, because an `env` dump prints every variable |
| State via `playwright-cli` | Allowlist unchanged: every getter/exporter denied, `config-print` included | Textual gate: a program that spawns `playwright-cli` itself is not judged (existing residual) |
| State via file reads | Consumed at `open`; 0700/0600; `.gitignore`; read guard on every tool, MCP tools included; `auth/` discarded at cleanup | The guard is textual (a variable, `$(…)` or a glob in the runs directory's own name bypasses it; below a run directory a glob or expansion that could stand for `auth/` is denied); a recursive command at or above the run directory, shell text through a symlink alias of a runs directory, and a Windows 8.3 short name such as `VERIFY~1` are not judged; hooks switched off judge nothing; same OS user |
| Error reflection | Gate and helper parse the state before `open` | Swap between gate check and launch (same class as the run-config residual in the consent spec §12) |
| Snapshots / screenshots | Origin consent; test account with synthetic data; skill forbids driving credential pages (API keys, sessions, tokens) | What the app itself renders enters the context by design |
| `console` / `requests` | Denied on signed-in sessions | Runtime-signal plane stays PARTIAL for signed-in rows (as today) |
| Redirect / navigation exfiltration | `allowedOrigins`, no query/fragment/userinfo in navigation, redirect stop rule | Redirect followed before the check; WebSockets unfenced (D12) |
| State scope creep | Helper filters to run hosts and origins; gate rejects out-of-scope entries | Cookies are scoped by host, not port; a parent-domain cookie stays valid for a sibling host a redirect reaches |
| Credential destination | The caller names no login origin; the login runs before any consent prompt, so the recipe binds it: in remote mode its `baseUrl`, which must be one of the run's origins, or its `appOrigin` without one; in local mode the run's own loopback app origin | Local mode: the loopback app origin is still the caller's choice, so a local recipe signs in only a throwaway account the local app alone knows |
| Run-config tampering | Only the canonical path beside the config is accepted; no inline state | Same as the consent spec §12 swap residual |
| Session laundering | State only on `zensu-verify-auth-…`; signals denied by name; the consent gate judges a call on any session whose text names a run directory or passes a config, and denies one outside `zensu-verify-…` that names a run directory or whose config carries `storageState` or cannot be read as JSON; the read guard refuses a `playwright-cli` call that names a run directory without a `zensu-verify` session | A config the gate never sees (the working directory's default `.playwright/cli.config.json`, the global `~/.playwright/cli.config.json`, a path behind a variable, a file swapped after the gate read it, a program that spawns `playwright-cli`) still opens a signed-in browser outside the gate while the state file exists, that is, until the first gated `open` consumes it; manual login in a non-auth session keeps today's prose-only rule |
| Leftover state | Consumed once, also by a recorder that cannot bind the session; Phase 4 discards `auth/` with `--discard-state`, also when it keeps the run directory; a helper stopped by a signal kills the login and removes the artifact directory | A crash or `SIGKILL` before cleanup leaves a 0600 file in an ignored directory |

## 7. Build steps, decisions, defaults

1. **Shared validator** `hooks/lib/verify-auth-state-v1.js`: storage-state shape, scope,
   file-safety checks, canonical paths. Default caps: 1 MiB, 256 cookies, 64 origins.
2. **Gate**: §6.3. Decision: fail closed on any doubt about the state file; fixed reasons only.
3. **Run-config helper + login step**: §6.2. Decision: login lives in the helper, so one command
   yields a signed-in config and a fresh browser is one command again. Default timeout 300 s
   (a cold `go run` login target compiles first).
4. **Recorder**: consume-once deletion and `restoredState` records.
5. **Read guard**: §6.5, registered in `hook-registration-v1.js`, covered by `/zensu:doctor`'s
   registration check like its siblings.
6. **Docs**: `SKILL.md` (credential-blind bullet, Chain mode point 3, Phase 2 browser session,
   Authentication, Phase 3, Phase 4, Phase 5 consent line), `rules/browser-verification.md` §0
   and §4, `rules/attach.md`, `rules/setup.md` (offer to record a login script),
   `autopilot/rules/auth.md` and `config.md` (`auth.environment`, verify's consumer), and
   `docs/verify-feature.md`. This spec lands as `docs/verify-feature-auth-state-spec.md`.
7. **Tests**: unit tests for validator, gate, helper, recorder and guard; the table-driven
   getter/exporter denial over `help.json`; an integration test (fixture app + fixture recipe +
   fixture login script + real `playwright-cli`, skipped with a reason when it or Chrome is
   absent); updates to `tests/structure/test-verify-feature-skill.sh` P4a/P4b/P4e/P4g and the
   unit-file registry counts.

## 8. Out of scope (follow-ups)

- A trusted runtime-signal sanitizer (a plugin script that reads `requests`/`console` itself and
  prints method, path without query, status) so signed-in rows can reach PASS. Until then they
  stay PARTIAL on that plane, as manual-login rows are today.
- The monorepo side: `make -C backend e2e-session` writes its artifact under `$TMPDIR` and ignores
  `ZENSU_AUTH_ARTIFACT_DIR`, so the helper would reject it (`artifact-path`). The monorepo needs
  a small change to honour the canonical variables and an `auth` block in `.zensu/runtime.yaml`;
  a remote login script for a hosted test account is a further monorepo change.
- OS-level isolation of the state from the model's shell.

## 9. Decisions (answered by the user, 2026-11-06)

1. **Production test accounts: in scope, opt-in per recipe.** A remote recipe may declare
   `auth.environment: production` for its exact origin. Requirements stated in the docs: a
   dedicated test account in an isolated organization with synthetic data only, never the
   developer's own account; the password resolved inside the login script (keychain or password
   manager preferred over a plain environment variable); the consent prompt at every `open`.
   Rationale: a dedicated test account exposes less than the alternative, a manual login with the
   developer's own account. Cost accepted: a production session file exists on disk from login to
   `open` (seconds), and the model drives that account's pages.
2. **Read guard (§6.5): included.**
3. **Delivery route: the Zensu workflow (`/zensu:build`, vanilla implementation + review chain),**
   run from a session anchored in the `zensu-claude-code` worktree, because the chain audits of a
   session anchored elsewhere fail edits outside their root.
4. **Spec approved** with these answers, to be built on `claude/verify-test-account`.
