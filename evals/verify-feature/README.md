# evals/verify-feature

Live Promptfoo evaluation for `/zensu:verify-feature`. It runs the real Claude CLI with the
plugin from the current worktree and grades the resulting skill and `playwright-cli` transcript.

## Scenarios

| Scenario | Proof |
|---|---|
| `local-happy-path.yaml` | Starts an isolated loopback application on a parent-reserved exact port, verifies inventory loading through a gated `playwright-cli` session, requires DOM/data, screenshot, console, and network evidence, and pins exact teardown. |
| `remote-unsafe-url.yaml` | Supplies a synthetic query-bearing preview URL and requires a credential-blind PARTIAL stop before browser navigation or runtime startup. |
| `remote-accepted-public.yaml` | Uses a dedicated remote-policy provider to navigate the pre-classified public static `example.com` root, prove gated remote DOM/visual/runtime evidence, then require PARTIAL because no deployment identity ties it to the worktree. |

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

The runner exports `ZENSU_VERIFY_NAVIGATION_POLICY_V1` for the reserved fixture origin, and the
remote provider exports it for `https://example.com`, so the gate runs in policy mode: a
non-interactive Promptfoo run cannot answer the consent prompt that consent mode opens for a new
loopback origin. The runner also clears every `PLAYWRIGHT_MCP_*` and `PWTEST_*` variable from its
environment: the gate refuses to open a browser while a `PLAYWRIGHT_MCP_*` variable is set, and
`PWTEST_CLI_GLOBAL_CONFIG` moves the global `playwright-cli` config that the gate judges.

## Run

The live eval requires macOS or Linux (including WSL). Its immutable-fixture boundary relies on

- `sandbox-exec` on macOS, or
- `bwrap` on Linux/WSL.

Native Windows Git Bash can run the deterministic structure suite, but it is not a supported
host for this unrestricted live eval.

```bash
ZENSU_E2E_DISPOSABLE_ENVIRONMENT=1 evals/verify-feature/run-eval.sh
```

The runner requires authenticated `claude`, `promptfoo`, and `playwright-cli` on `PATH` (the
grader was written against `playwright-cli` 0.1.21), plus a Chrome or Chromium build that
`playwright-cli` can drive. The runner never installs a browser. It sets
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
remain writable for run-owned evidence and lifecycle state. Symlinked fixture entries are
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
