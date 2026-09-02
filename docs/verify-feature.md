# Verifying a feature live, standalone

`/zensu:verify-feature` proves an already-built feature in a real browser and reports what
it observed. Under `/zensu:autopilot` its preconditions are prepared for you. Run on its own,
the skill fails closed with `VERIFY-FEATURE-VERDICT: PARTIAL` until two things exist
**before the session starts**:

1. a **navigation policy** in the environment that launches Claude Code, and
2. in local mode, a **runtime recipe** the skill can accept, or a repository the bundled
   Zensu monorepo adapter recognizes.

Neither can be created from inside the session. This page shows the launch command, the
local-mode rules, a minimal recipe for an ordinary project, and the remote-mode path. The
authoritative contracts stay in `skills/verify-feature/SKILL.md` and in
`skills/autopilot/rules/config.md` § `validate.navigationBroker`; this page does not replace
them.

## 1. The navigation policy is read when Claude Code starts

The plugin registers its Playwright MCP server in `.mcp.json`. Claude Code starts that server
once, at session start: `scripts/playwright-mcp.sh` materializes the pinned runtime and runs the
broker, `scripts/playwright-mcp-proxy.js`, which parses `ZENSU_VERIFY_NAVIGATION_POLICY_V1`
from its own environment at that moment. Every browser request is judged against that parsed
policy for the rest of the session. A `Bash` call inside the session is a child process and
cannot reach the already-running server, which is why the skill never tries to set the
variable and stops with PARTIAL instead.

So the variable has to be exported by the shell that launches Claude Code:

```bash
ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:4173","evidenceMode":"declared-safe","routes":["/","/inventory"]}]}' claude
```

Changing the origin, the mode, or the route list means exiting Claude Code and launching it
again with the new value.

### Policy shape (contract version 1)

| Key | Rule |
|---|---|
| `version` | the integer `1` |
| `mode` | `local` or `remote`; it must match the `--mode` the skill runs in |
| `targets` | 1 to 8 entries; each carries exactly `origin`, `evidenceMode`, and `routes` |
| `origin` | scheme, host, and port only: no path, credentials, query, fragment, or trailing slash; unique across targets |
| `evidenceMode` | the literal `declared-safe`; contract v1 supports no other mode |
| `routes` | 1 to 64 page paths per target; each starts with `/`, carries no `?`, `#`, or `*`, is already normalized, and is unique |

No other key is accepted at either level. Routes are matched exactly on the pathname:
`/inventory` covers neither `/inventory/` nor `/inventory/42`, and the root page needs its own
`/` entry. Routes belong to the origin they sit under and are never combined across targets.
The route rule applies to page navigations, redirects included; the API and asset requests a
page makes, and its WebSocket connections, only have to hit an approved origin.

### Checking the policy before the run

The skill runs this preflight for every route before its first browser call:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh" --check-policy <local|remote> "<origin>" "<route>" declared-safe
```

It parses the policy exactly as the server does and loads no browser runtime. Success is
silent with exit `0`; a refusal prints `zensu Playwright broker: <reason>` on stderr and exits
`1`. Run it from a terminal with `${CLAUDE_PLUGIN_ROOT}` replaced by the installed plugin
directory, or let the skill run it, which reports a refusal as PARTIAL with that reason.
The messages you will meet:

| Message | Cause |
|---|---|
| `navigation policy mode does not match` | the policy is **absent** from the environment (an unset policy parses as a deny-everything policy with no mode), or its `mode` differs from the mode being checked |
| `local navigation policy accepts literal loopback-IP origins only` | a local origin uses `localhost` or another hostname |
| `navigation policy target does not match` | the origin is not listed exactly; a trailing slash or a different port is enough |
| `navigation target route is not approved for evidence` | the route is not in that origin's `routes` |
| `evidence route must be an absolute query-free pathname` | a route carries `?`, `#`, or `*`, or does not start with `/` |
| `navigation policy contains unknown or missing keys` | a top-level key is missing, misspelled, or extra |

`/zensu:doctor` checks that the Playwright MCP server is declared and that its pinned runtime
is installable; it does not read the navigation policy. The preflight above is the only check
for that.

## 2. Local mode

Local mode proves the code in the current worktree, so the application has to be started from
that worktree on an origin the policy already names.

- **Literal loopback IP.** The origin is `http://` or `https://` plus a loopback IP address
  (`127.0.0.1`, any other `127.0.0.0/8` address, or `[::1]`) and the port. `localhost` and
  every other hostname are rejected, because the broker refuses to trust DNS or `/etc/hosts`
  for a boundary decision.
- **The port is fixed before launch.** The policy carries it, so the application must bind
  exactly that port and fail rather than fall back to another one (Vite's `--strictPort`, or
  an explicit bind in your own script). A server that silently moves to a free port produces
  an origin the policy does not name, and the run ends PARTIAL before the browser opens.
- **A dynamically chosen port needs two sessions.** If your stack picks its own port, do one
  discovery run to learn it, then exit and launch Claude Code again with that exact origin in
  the policy. The recipe has to reproduce the same port on the second run; a port that changes
  on every start cannot be verified under this contract.
- **Per-run ports come from the launching shell.** The recipe may not hard-code a shared port,
  so export the port beside the policy and let the recipe's commands read it. They run through
  `Bash` inside the same session and inherit that environment. The plugin never reads that
  variable; only your scripts do.

```bash
export VERIFY_PORT=4173
export ZENSU_VERIFY_NAVIGATION_POLICY_V1="{\"version\":1,\"mode\":\"local\",\"targets\":[{\"origin\":\"http://127.0.0.1:${VERIFY_PORT}\",\"evidenceMode\":\"declared-safe\",\"routes\":[\"/\",\"/inventory\"]}]}"
claude
```

Then, inside the session:

```
/zensu:verify-feature <what to verify> --route=/inventory
```

The broker opens a visible Chromium window; keep the machine attended, because a login, when
one is needed, happens by you typing into that window.

## 3. The runtime recipe

For local mode the skill resolves the runtime in this order and stops with PARTIAL when
nothing fits:

1. `--config=<path>`, else `.zensu/autopilot.yaml`, inspected as a **candidate** against the
   rules below;
2. the bundled Zensu monorepo adapter (`skills/verify-feature/rules/zensu-monorepo.md`), when
   the repository carries `backend/cmd/zensu`, `backend/Makefile`, `frontend/package.json`,
   and `frontend/pnpm-lock.yaml`; it needs macOS, Linux, or WSL;
3. otherwise PARTIAL, listing the missing startup, readiness, base-URL, auth, fixture,
   isolation, and teardown facts. The skill never invents commands.

A candidate recipe is accepted only when all of this is explicit and consistent:

- every service has a startup command and a readiness command;
- every started resource has a scoped `down` command, or stays a foreground child whose exact
  PID the run owns;
- host ports and resource names are per-run inputs, not fixed shared values;
- application and authentication base URLs, fixture setup, and cleanup all refer to the same
  run-specific runtime;
- the browser base URL is a run-specific literal or the output of a checked-in
  `validate.baseUrlCommand`, run only after readiness, and it matches an origin in the policy
  byte for byte.

Rejected by rule: fixed-port Compose stacks, shared container or resource names, daemonized
services nobody owns, and recipes whose teardown scope is ambiguous. A rejected candidate is
never executed, not even partially; the report says why.

### Minimal recipe for an ordinary project

`skills/autopilot/rules/config.md` defines the file. This is the smallest shape the verifier
accepts for an unauthenticated single-service app. Autopilot-only keys such as `vcs` and
`gates` may be present but are not needed for a verification run:

```yaml
version: 1

services:
  - name: web
    up: "./scripts/verify-runtime.sh up"
    ready: "./scripts/verify-runtime.sh ready"
    down: "./scripts/verify-runtime.sh down"

auth:
  mode: none
  artifact: none

validate:
  driver: browser
  baseUrlCommand: "./scripts/verify-runtime.sh url"
  navigationBroker:
    contractVersion: 1
    policyEnv: ZENSU_VERIFY_NAVIGATION_POLICY_V1
  evidenceSafety:
    contractVersion: 1
    mode: declared-safe
    dataClassification: synthetic
    routes: ["/", "/inventory"]
    containsPersonalData: false
    containsSecrets: false
```

The script behind it is yours. The contract it has to meet:

- `up` starts the app bound to `127.0.0.1:$VERIFY_PORT`, refuses to start when that port is
  taken, records the PID it started, and returns;
- `ready` exits `0` only when the app answers on that origin; a `sleep` is not readiness
  evidence;
- `url` prints exactly `http://127.0.0.1:$VERIFY_PORT` and nothing else; the skill compares
  it with the policy again before navigating;
- `down` stops only the PID it recorded and removes only its own state. The skill runs it byte
  for byte as a standalone Bash call on success, failure, and cancellation, so it must also
  succeed when nothing is running any more.

`evidenceSafety.routes` lists the exact page paths whose DOM and screenshots may reach the
model, under the same origin the policy names. `declared-safe` is a claim that checked-in
fixtures or seed data make those pages synthetic or pre-classified non-sensitive. A route
missing from this block, or a block that fails validation, is skipped and reported PARTIAL
rather than captured.

A complete working example is the eval fixture:
`evals/verify-feature/test-projects/live-app/.zensu/autopilot.yaml`, with
`scripts/fixture-runtime.sh` beside it. It starts one owned Node process on `127.0.0.1`, keeps
PID and lease files in a private state directory, and takes its exact port from a variable
the launching shell exported.

## 4. Remote mode

Remote mode proves code that is already deployed. It boots nothing and needs no runtime
recipe; it needs the policy and a validated base URL.

```bash
ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1,"mode":"remote","targets":[{"origin":"https://preview.example.com","evidenceMode":"declared-safe","routes":["/","/inventory"]}]}' claude
```

```
/zensu:verify-feature <what to verify> --mode=remote --base-url=https://preview.example.com --route=/inventory
```

- The origin must be non-loopback `https://`. The broker resolves the hostname, rejects any
  answer that is not globally routable (RFC 1918, CGNAT, link-local, ULA, and the rest),
  rejects a mix of public and non-public answers, and pins the browser to the approved
  addresses so a later DNS change cannot redirect it.
- The base URL is validated in memory before anything else happens: absolute, `https://`, no
  userinfo, no query, no fragment. A signed or token-bearing preview link is rejected and
  never echoed; use a credential-free entry URL plus a visible login in the headed browser.
- Authentication is credential-blind. Protected routes need a recipe (`--config=<path>`)
  whose `validate.evidenceSafety` covers each of them exactly, and you log in yourself in the
  browser the skill opens. Without that, authenticated scenarios are skipped and the run is
  PARTIAL. A configured `auth.appOrigin` must equal the validated base URL's origin exactly.
- Remote mode verifies what is deployed at that URL, not the files in your worktree. The skill
  says so before its first browser call, and the verdict stays PARTIAL unless a deployment
  identity ties that URL to the branch under test.

## 5. Where a run stops, and why

| Symptom | Cause | Fix |
|---|---|---|
| PARTIAL before any browser call; reason `navigation policy mode does not match` | policy not exported by the launching shell, or its `mode` disagrees with `--mode` | exit Claude Code and launch it with the policy |
| PARTIAL; reason names `loopback-IP origins only` | local origin spelled with `localhost` | use `127.0.0.1` in the policy, the recipe, and the `baseUrlCommand` output |
| PARTIAL; the `baseUrlCommand` output differs from the policy origin | the app bound another port, or the printed URL carries a trailing slash or a path | bind the port strictly; print the bare origin |
| PARTIAL; the recipe was rejected | one of the acceptance rules above is not met | the report names the missing fact; fix the recipe |
| the skill reports that the plugin MCP server was not loaded | the Playwright tool set is absent from the session | check the plugin installation with `/zensu:doctor`, then restart Claude Code |
| the browser binary is missing | the pinned Chromium is not installed | approve `bash "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh" install-browser`, then restart Claude Code |

The runtime and integrity model behind the server (per-invocation generations, the SRI-pinned
lockfile, what `--check-policy` does and does not load) is described in
[Playwright MCP runtime integrity](playwright-mcp-runtime.md).
