# Playwright MCP runtime integrity

Zensu executes the bundled Playwright MCP through `scripts/playwright-mcp.sh`.
The plugin's Session Control runtime digest binds the launcher, broker,
`mcp-runtime/package.json`, and `mcp-runtime/package-lock.json`. The lockfile pins
the complete npm graph with registry SRI values.

## Per-invocation runtime generation

Every server start creates a new per-invocation runtime generation in the OS
temporary directory, outside the plugin root. The launcher copies only the
digest-bound `package.json` and `package-lock.json` into that generation and
runs `npm ci --ignore-scripts --no-audit --no-fund` there. npm constructs a
private `node_modules` graph and verifies downloaded or cached artifacts against
the lockfile's SRI values.

No executable, dependency tree, or self-authored stamp from shared `mcp-runtime/node_modules`
is trusted, read, or rewritten. A modified shared binary therefore has no path
to execution. Concurrent MCP starts use
different generations, so one start can neither delete nor replace dependencies
that another running server still needs.

The broker or pinned CLI runs as a child with inherited stdin, stdout, and
stderr. The launcher waits for that exact child, forwards `HUP`, `INT`, and
`TERM`, and performs signal-safe generation cleanup through its `EXIT` trap.
At both the `npm ci` and MCP child boundaries it removes ambient API, SCM,
cloud, and package-registry credential variables; only the explicit navigation
policy and non-secret host environment remain available to the broker.
`SIGKILL` cannot be trapped; a generation left by `SIGKILL` carries no authority,
is never reused, and can be reclaimed by normal OS temporary-directory cleanup.

The command deliberately keeps the normal npm content cache enabled. It does not
use a cache-busting or forced-download option, so cache hits avoid unnecessary
package downloads while retaining npm's SRI verification. A cache miss can still
require network access.

## Command modes

- The normal MCP server start materializes a private generation and runs the
  checked-in capability/navigation broker against it. The broker starts in one of
  three modes, decided once at that moment: `policy` when
  `ZENSU_VERIFY_NAVIGATION_POLICY_V1` parses, `consent` when it is absent and the
  broker's own `hooks/hooks.json` registers `pre-browser-navigation-consent.sh` on the
  navigation matcher (loopback origins only, each approved by the user through the
  host's permission prompt — see [Browser Consent Gate](gates.md#browser-consent-gate)),
  and `deny` otherwise.
- `install-browser` uses the same isolated generation before delegating to the
  pinned CLI. Browser installation remains an explicit, approved operation;
  npm package scripts stay disabled.
- `--check-policy` executes only the checked-in broker's policy parser. It never
  loads the upstream npm graph and therefore needs no runtime generation. In
  consent mode it prints `consent` on stdout and exits `0` for a literal-loopback
  origin and route, and refuses a remote target with the reason that names the
  parent-environment policy.

The production launcher has no runtime-directory override or test passthrough.
Tests exercise an exact copied launcher inside a disposable fixture rather than
adding a production environment-variable bypass.

The launcher fails closed when Node.js, npm, regular pinned metadata, temporary
generation creation, the clean install, or the resulting executable is
unavailable. Normal exit and trappable signals remove the complete generation.
