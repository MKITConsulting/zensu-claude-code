# evals/verify-feature

Live Promptfoo evaluation for `/zensu:verify-feature`. It runs the real Claude CLI with the
plugin from the current worktree and grades the resulting skill and `playwright-cli` transcript.

## Scenarios

| Scenario | Proof |
|---|---|
| `local-happy-path.yaml` | Starts an isolated loopback application on a parent-reserved exact port, verifies inventory loading through a gated `playwright-cli` session, requires DOM/data, screenshot, console, and network evidence, and pins exact teardown. |
| `remote-unsafe-url.yaml` | Supplies a synthetic query-bearing preview URL and requires a credential-blind PARTIAL stop before browser navigation or runtime startup. |
| `remote-accepted-public.yaml` | Uses a dedicated remote-policy provider to navigate the pre-classified public static `example.com` root, prove gated remote DOM/visual/runtime evidence, then require PARTIAL because no deployment identity ties it to the worktree. |
| `remote-separate-api-origin.yaml` | Uses a second remote-policy provider whose policy declares `https://example.org` as a network-only origin of the `example.com` target, and the recipe `.zensu/remote-network-only.yaml` that names it under `validate.networkOnly`. It requires a `--check-policy remote https://example.org network-only` preflight that prints `policy` before the run-config helper call, that helper call to pass `--network-only-origin https://example.org` and print it back, a session opened with the config that helper call wrote, with no later helper call rewriting it, that itself lands on the `example.com` root and succeeds at every required operation, no navigation command aimed anywhere but the `example.com` root, the same gated evidence as the accepted remote scenario, and the deployment-identity PARTIAL. The helper call is read in the spelling the skill documents, quoted paths and a `$RUN_DIR` variable included. The public page makes no request to the declared origin, so this scenario proves the workflow and the navigation boundary, not a cross-origin fetch. |

The fixture in `test-projects/live-app/` has no external dependencies. Its checked-in runtime
recipe owns one exact PID, binds only to `127.0.0.1`, and consumes the exact port held open by
the parent runner. After a token-authenticated handoff, the parent keeps that public listener
open and forwards it to the fixture's private loopback port, eliminating the close-before-bind
race. It keeps all state inside the wrapper's temporary clone. The wrapper initializes that
clone as a clean `main` Git repository because `/zensu:verify-feature` grounds its scope in Git.

## Browser grading

The grader accepts a browser call only as one plain Bash command of the form
`playwright-cli -s=zensu-verify-<slug> <command> [args] [flags]`, and it accepts an `open` only
with the session name and `--config` path that `scripts/verify-browser-config.js` printed for
the run. It reads the admitted command set from the browser consent gate module,
`hooks/lib/verify-consent-v1.js`, rather than keeping a copy of it. The grader fails a run that
calls `playwright-cli` outside a gated `zensu-verify` session, runs a command the gate denies,
uses any browser-looking tool, or drives a browser through any other Bash command. Screenshot
evidence is the image file a `screenshot` call printed, opened with the Read tool; a screenshot
file name alone is not evidence.

Two calls outside a session pass: `playwright-cli install-browser`, and a read-only availability
probe. The probe is one Bash command made only of `command -v playwright-cli`, `which
playwright-cli`, `playwright-cli --version`, `playwright-cli --help` and `echo` segments, joined by
`&&`, `||` or `;`, at least one of them a probe, with output redirected only to `/dev/null` or from
one descriptor to another. Outside single quotes a word holds only plain word characters and
blanks, and `$?` is the one expansion it may carry. A probe fails like every other call outside the
gate when a segment other than `echo` passes a session or a config or runs another program, or
when the command pipes, substitutes, expands anything but `$?` or redirects to a file. An `echo`
segment may print a message, but none of its words may name a session, a config, a run directory
or a CLI command: a word that carries the `zensu-verify-` session prefix, a `-s` or `--session`
option, `PLAYWRIGHT_CLI_SESSION`, `--config`, `PLAYWRIGHT_MCP_CONFIG`, the run config's file name
or `verify-feature-runs`, in any letter case, fails the probe. So does a word that names the CLI in
any spelling the consent gate recognizes, a path or a versioned package name included, when the
words after it, read with the gate's own option parser, make a command the gate allows, or `eval`,
`run-code` or a cookie, storage or state command. The model probed with such compound commands in
the live run of 2026-11-19, and the skill text sits at its size budget, so the grader judges what a
probe can do rather than how it is spelled.

The two remote scenarios name no wording of the public page, because the live `example.com` page
dropped its heading in 2026: their criteria ask for explanatory text and a visible link, and the
grader requires a snapshot of `https://example.com/` that shows a paragraph, text or heading line
and a named link. `requests` lists a successful document, script or image only with `--static`
(playwright-core's request list hides successful requests that are not fetches), so the grader
takes the document load from the root `[GET] https://example.com/ => [200]` line or from a
`Note: N static requests not shown` line, with no failed request listed in either.

The runner exports `ZENSU_VERIFY_NAVIGATION_POLICY_V1` for the reserved fixture origin, and the
remote providers export it for `https://example.com`, the second one with `https://example.org` as a network-only origin, so the gate runs in policy mode: a
non-interactive Promptfoo run cannot answer the consent prompt that consent mode opens for a new
loopback origin. The runner also clears every `PLAYWRIGHT_MCP_*` and `PWTEST_*` variable and
`PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK` from its environment: the gate refuses to open a
browser while a `PLAYWRIGHT_MCP_*` variable or `PLAYWRIGHT_DISABLE_SERVICE_WORKER_NETWORK` is set,
and `PWTEST_CLI_GLOBAL_CONFIG` moves the global `playwright-cli` config that the gate judges.

## Run

The live eval requires macOS or Linux (including WSL). Its immutable-fixture boundary relies on

- `sandbox-exec` on macOS, or
- `bwrap` on Linux/WSL.

Native Windows Git Bash can run the deterministic structure suite, but it is not a supported
host for this unrestricted live eval.

On macOS the wrapper's profile (`scripts/claude-promptfoo-wrapper.sh`) denies by default and adds
what the fixture runtime and the browser need, each measured on macOS 26.7.2 on 2026-11-24:

- `(allow signal (target same-sandbox))` and `(allow signal (target children))`: the fixture
  runtime proves its own server with `kill -0`, and the Playwright daemon stops the browser it
  started outside the sandbox. A process outside the sandbox that the sandbox did not start stays
  out of reach; the children a sandboxed process starts outside it, the browser and `ps` included,
  do not.
- `(allow process-exec (literal "/bin/ps") (with no-sandbox))`: the fixture runtime reads its
  server's command line with `ps`, which is setuid and cannot run inside the sandbox.
- With `allow_unsandboxed_chrome: true`, which only this eval's three providers set and which the
  wrapper refuses unless the same provider config sets `require_disposable_environment: true`,
  `(allow process-exec (literal "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") (with no-sandbox))`.
  Google Chrome cannot run inside the profile: its single-instance lock needs the per-user temp
  directory, its startup registers Mach services, and its renderer sandbox cannot be applied
  inside another one. The main executable is the narrowest rule that works, because the helpers
  it starts inherit no sandbox from it.

What the Chrome rule gives up: the browser and its helpers run outside the read-only fixture
boundary, and any process inside the sandbox can start that executable outside it with arguments
of its choosing. The manifest and the mutation journal still catch a write into the fixture. The
grader fails a run whose Bash command text names a browser, a word check it also applies to the
command with its line continuations joined and its quotes, backslashes and backticks removed; a
name the shell assembles another
way, from a variable for example, passes it. The rule names the system Google
Chrome that the run config's Chrome channel launches; another Chromium build stays inside the
sandbox and fails to start there. On Linux `bwrap` the key changes nothing, and Chrome under
`bwrap` is unmeasured.

promptfoo 0.121.20, the version `package.json` pins and the runner starts, runs a scenario file's
own `exec:` provider in that file's directory. The two remote scenarios therefore name
`../remote-provider.sh` or `../remote-network-only-provider.sh` and
`working_dir: ../test-projects/live-app` relative to `scenarios/`, while the provider in
`promptfooconfig.yaml` resolves against this directory. A `file://` assertion value resolves
against this directory in every scenario, so `file://assertions/transcript-check.js` keeps no
`../`. `tests/structure/test-eval-harness-units.sh`, which CI runs, resolves all three that way.

```bash
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 evals/verify-feature/run-eval.sh
```

The runner requires authenticated `claude` and `playwright-cli` on `PATH` (the
run-config helper accepts only the measured version, `playwright-cli` 0.1.24, and the grader in
`assertions/transcript-check.js` parses its response lines) and the repository's own promptfoo:
`npm ci` installs the version `package.json` pins, and the runner starts that binary, never one it
finds on `PATH` (`VERIFY_FEATURE_PROMPTFOO` names another one by absolute path; the runner refuses
a relative one). On macOS it needs the system
Google Chrome at `/Applications/Google Chrome.app`, the one browser the fixture sandbox lets
start; on Linux, a Chrome or Chromium build that `playwright-cli` can drive. The runner never
installs a browser. It sets
`ZENSU_PLUGIN_DIR_OVERRIDE` to this checkout, uses a temporary writable `PROMPTFOO_CONFIG_DIR`,
and disables Promptfoo cache, sharing, and result writes plus telemetry. Snapshots and
screenshots land in the `browser/` folder of the run directory; the gate denies caller-supplied
`--filename` values. Pass normal Promptfoo filters after the script name, for example:

```bash
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 evals/verify-feature/run-eval.sh --filter-pattern "unsafe remote"
```

This suite is live and advisory because it requires Claude authentication, network access, and
a browser. The wrapper uses Claude's non-interactive permission mode but places the initialized
fixture behind an OS-enforced read-only filesystem boundary; only the hook log plus
`.zensu/{logs,state,verify-feature-runs}`, `.verify-runtime`, and `.verify-feature-runtime`
remain writable for run-owned evidence and lifecycle state. With `allow_unsandboxed_chrome` set,
the Chrome process tree, and whatever its arguments make it start, runs outside that boundary, so
for it detection is the only control. Symlinked fixture entries are
rejected before Claude starts so writes cannot escape through an external target, and those
run-owned paths must be absent from the source fixture before the wrapper creates them. It
also hashes Git control/source state and keeps a health-checked mutation journal alive through
the final digest. This is not a general host, process, or network sandbox: Claude can still read
host files, access the network, launch processes, and write outside the protected fixture where
the OS profile permits it. Run it only inside a disposable environment whose full host access
you accept; the required `ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1` value is an explicit acknowledgement,
not a sandbox control. `tests/structure/test-promptfoo-verify-feature.sh` validates the
configuration and fixture lifecycle offline and remains part of the deterministic default
repository suite. Claude may read relevant plugin and fixture files during the eval, so running
the live suite sends those contents to the configured Claude service. Use only a checkout whose
contents are approved for that external processing.
