# Verifying a feature live, standalone

`/zensu:verify-feature` proves an already-built feature in a real browser and reports what
it observed. Under `/zensu:autopilot` its preconditions are prepared for you. Run on its own,
it has two ways to authorize the browser:

- **Consent mode** (the default when nothing is configured): the first time the run's browser
  reaches each loopback origin, Claude Code's own permission prompt asks you, in the CLI and in
  the desktop app alike, with no environment variable and no restart. That promise holds for an
  interactive session: how the host resolves the prompt under bypass permissions, in auto mode
  or in a headless run is unverified, so such a run belongs in policy mode. It covers local
  targets only. Section 0 describes it.
- **Policy mode**: a **navigation policy** exported by the environment that launches Claude
  Code. It is the only channel a model cannot write, it is required for remote targets and
  for unattended runs — bypass permissions, auto mode, a headless run — and it was the only
  way to run the skill before consent mode existed. Sections 1 to 4 describe it.

The browser is driven by `playwright-cli`, which you install once:

```bash
npm install -g @playwright/cli@0.1.21
```

That is the version the browser consent gate was measured against, and the run-config helper
refuses to start a run on any other. `brew install playwright-cli` is unpinned: it installs
whichever version Homebrew ships. It uses your installed Chrome. When Chrome is missing,
the skill asks before it runs `playwright-cli install-browser`, because that downloads a
browser. `/zensu:doctor` reports whether `playwright-cli` is on `PATH` and which version, read
from the installed package without running the binary — only when that read yields no version
does it run `playwright-cli --version`, under a five-second watchdog where `timeout` or
`gtimeout` exists and with no time limit otherwise — and warns when that version is not the one
the browser consent gate was measured against.

In local mode the skill also needs a **runtime recipe** it can accept, or a repository the
bundled Zensu monorepo adapter recognizes, or an application you already run
(`--attach`). `/zensu:verify-feature --setup` writes the recipe with you. The authoritative
contracts stay in `skills/verify-feature/SKILL.md`, `skills/verify-feature/rules/setup.md`
and `skills/autopilot/rules/config.md` § `validate.navigationBroker`; this page does not
replace them.

## How the browser is fenced

Every run writes a **run config** into its own run directory with
`scripts/verify-browser-config.js` and opens the browser with it, under a session named
`zensu-verify-<run>`. The run config makes the browser isolated, restricts every request to the
run's origins (`network.allowedOrigins`), blocks service workers, and keeps screenshots and
snapshots inside the run directory. For a remote host it also pins the hostname to the public
address the helper resolved.

The **browser consent gate** — two hooks on the `Bash` matcher — judges every `playwright-cli`
call on a `zensu-verify` session before it runs, reaches no decision for a call on any other
session whose command text names no `zensu-verify-` session, and denies a command that merely
mentions both markers — a search, a commit message.
That is the accepted cost of a textual gate: search with the Grep tool and commit with a message
file. While the hook environment's `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session, a
call on any other session reaches no decision only as one plain call that names its session
once, spells that session and every argument literally, parses, and names no `PLAYWRIGHT_MCP_*`
or `PWTEST_*` variable; every other such command is denied. For a `zensu-verify` call:

- only the commands a verification needs are admitted: opening and closing the session,
  navigation, snapshots, screenshots, console and request listings, clicks and typing, and
  display emulation. `eval`, `run-code`, every cookie, storage and state command, file upload,
  request details, recording, tracing, `attach` and `close-all` are denied;
- `open` must name the run config, and the gate reads it itself before the browser starts;
- calls must come from the main thread, name their session and arguments literally, and run as
  exactly one plain `playwright-cli` command — no second command, pipe, subshell, substitution,
  wrapper, package launcher or nested shell, and a redirection only to a literal path, never to a
  variable, substitution, glob, brace, `~` or `=` target nor on a line of its own — so a denial
  names the rule rather than guessing. Outside single quotes every `$` counts as an expansion
  unless whitespace or the end of the command follows it;
- every target origin passes the navigation floor of section 2 and, without a policy, the
  consent prompt below.

## 0. Consent mode

When `ZENSU_VERIFY_NAVIGATION_POLICY_V1` is absent from the environment that launched Claude
Code, the gate runs in consent mode (`/zensu:doctor` reports this as
`verify-feature: consent mode ready`). Then:

- The first `playwright-cli` call of the run that reaches a new origin — opening the browser,
  `goto` or `tab-new` — opens a permission prompt naming the origin, the session, the routes the
  run declares synthetic-safe and the consequence: answering Yes lets the model open and read
  any page on that origin, screenshots included, for the rest of the session. The model cannot
  answer that prompt.
- Approved origins are remembered for the session in
  `.zensu/state/verify-consent-<session-key>.json`; every further route on an approved origin
  passes without a second prompt. The report's `Consent` block lists every record.
- The floor holds whatever you answer: literal loopback origins only (`127.0.0.1`, `[::1]`;
  never `localhost`), no credentials, no query or fragment in a navigation, and the browser
  requests nothing from an origin outside the run config.
- A remote target is refused in consent mode, by the run-config helper and by the gate, because
  the browser's DNS pins are written before it starts. Remote verification needs the policy of
  section 4.
- The port does not have to be known before launch: the run reserves a free loopback port
  through `scripts/verify-free-port.js`, hands it to the recipe as `ZENSU_VERIFY_PORT`, and the
  prompt shows the resulting origin.

What consent mode does not do: it does not survive hooks switched off host-side. With the hooks
off, nothing in the plugin judges `playwright-cli` at all, and `/zensu:doctor` can report only
that the hooks are registered, not that they run. Nor is it verified without a person at the
prompt: how the host resolves a hook `ask` under bypass permissions, in auto mode or in a
headless run was never observed, so run an unattended or bypass session in policy mode, which
asks nothing. The consent memory is a file the session can
write, so it is a control, not a proof — the floor bounds what a forged record could reach to
other loopback services. And the browser follows a server redirect to another origin even though
it refuses every other request there, so the skill checks the page URL after every navigation and
stops a scenario that left the approved set. With the policy present the gate asks nothing and
enforces the policy exactly as in the sections below.

### Guided setup and attach mode

`/zensu:verify-feature --setup` detects the stack from tracked files, proposes `up`,
`ready`, a port variable and the synthetic-safe routes with the evidence file for each
proposal, asks one confirmation question, and writes `.zensu/runtime.yaml`
(`.zensu/autopilot.yaml` keeps working as an alias and is tried second). It never invents a
value it has no evidence for, never edits other project files, and never commits unasked.
Add `--print-policy` to render the policy JSON for the recipe's origin and routes, for CI or
for a host that keeps the policy in its launch environment.

`--attach=http://127.0.0.1:<port>` verifies an application you already run: nothing is
booted or torn down, and the report says whether the listening process could be proven to
serve this worktree (its working directory equals the worktree root) or not.

## 1. The navigation policy is read when Claude Code starts

The gate's hooks and the run-config helper read `ZENSU_VERIFY_NAVIGATION_POLICY_V1` from the
environment Claude Code was started with. A `Bash` call inside the session cannot change that
environment for the hooks, which is why the skill never tries to set the variable and stops with
PARTIAL instead.

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
| `origin` | scheme, host, and port only: no path, credentials, query, or fragment; unique across targets |
| `evidenceMode` | the literal `declared-safe`; contract v1 supports no other mode |
| `routes` | 1 to 64 page paths per target; each starts with `/`, carries no `?`, `#`, or `*`, is already normalized, and is unique |

No other key is accepted at either level. Routes are matched exactly on the pathname:
`/inventory` covers neither `/inventory/` nor `/inventory/42`, and the root page needs its own
`/` entry. Routes belong to the origin they sit under and are never combined across targets.
The gate applies the route rule to the navigation commands it sees — opening the browser,
`goto` and `tab-new`. It does not see a navigation the page itself makes, and the API and asset
requests a page makes only have to hit an origin in the run config.

### Checking the policy before the run

The skill runs this preflight for every route before its first browser call:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy <local|remote> "<origin>" "<route>" declared-safe
```

It judges the target exactly as the gate does and starts no browser. It prints `policy` when a
policy approves the target, `consent` when no policy is set and the target is a loopback origin,
and exits `0` in both cases; a refusal prints `zensu verify browser config: <reason>` on stderr
and exits `1`. Run it from a terminal with `${CLAUDE_PLUGIN_ROOT}` replaced by the installed
plugin directory, or let the skill run it, which reports a refusal as PARTIAL with that reason.
The messages you will meet:

| Message | Cause |
|---|---|
| `navigation policy mode does not match` | the policy's `mode` differs from the mode being checked |
| `remote-target-needs-parent-environment-policy: …` | a remote target with no policy in the launch environment |
| `local navigation policy accepts literal loopback-IP origins only` | a local origin uses `localhost` or another hostname |
| `<origin>: origin is not a target of the navigation policy` | the origin is not listed; a different port is enough |
| `<origin><route>: route is not approved for evidence by the navigation policy` | the route is not in that origin's `routes` |
| `route must be an absolute, normalized, query-free pathname` | the route being checked carries `?`, `#`, `*` or a dot segment, or does not start with `/` |
| `the navigation policy in the launch environment is invalid: <rule>` | the policy breaks its contract; the rule names which part, for example `policy contains unknown or missing keys` |

`/zensu:doctor` checks the policy's contract too and reports an invalid one as
`verify-feature: ZENSU_VERIFY_NAVIGATION_POLICY_V1 is set but invalid (…)`; the preflight above
is the only check of a particular origin and route.

## 2. Local mode

Local mode proves the code in the current worktree, so the application has to be started from
that worktree on an origin the policy already names.

- **Literal loopback IP.** The origin is `http://` or `https://` plus a loopback IP address
  (`127.0.0.1`, any other `127.0.0.0/8` address, or `[::1]`) and the port. `localhost` and
  every other hostname are rejected, because the gate refuses to trust DNS or `/etc/hosts`
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

When a login is needed the skill opens a visible browser window; keep the machine attended,
because the login happens by you typing into that window.

## 3. The runtime recipe

For local mode the skill resolves the runtime in this order and stops with PARTIAL when
nothing fits:

1. `--config=<path>`, else `.zensu/runtime.yaml`, else `.zensu/autopilot.yaml`, inspected as a
   **candidate** against the rules below;
2. the bundled Zensu monorepo adapter (`skills/verify-feature/rules/zensu-monorepo.md`), when
   the repository carries `backend/cmd/zensu`, `backend/Makefile`, `frontend/package.json`,
   and `frontend/pnpm-lock.yaml`; it needs macOS, Linux, or WSL;
3. in an interactive session, the guided setup: ONE `AskUserQuestion` offering to write
   `.zensu/runtime.yaml` with the user, after which resolution restarts at step 1;
4. otherwise PARTIAL, listing the missing startup, readiness, base-URL, auth, fixture,
   isolation, and teardown facts. The skill never invents commands.

The design decisions behind consent mode, its residuals and the alternatives that were weighed
are recorded in [verify-feature-consent-spec.md](verify-feature-consent-spec.md).

Steps 1 and 2 read the recipe the CONSENT gate reads too, and the gate resolves it in exactly one
place: `resolveRecipeFile` in `hooks/lib/verify-consent-v1.js`, which prefers `.zensu/runtime.yaml`
over `.zensu/autopilot.yaml` and skips a symlinked candidate. `--config=<path>` steers the SKILL
and is not consulted by the gate, so a recipe passed that way declares no synthetic-safe routes to
the consent prompt.

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

`validate.navigationBroker` keeps its name so existing recipes stay valid; it declares the
policy of section 1 and is optional in consent mode.

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

- The origin must be non-loopback `https://`. The run-config helper resolves the hostname,
  rejects any answer that is not globally routable (RFC 1918, CGNAT, link-local, ULA, and the
  rest), rejects a mix of public and non-public answers, and pins the browser to the approved
  address so a later DNS change cannot redirect it. The gate refuses to open a run config whose
  remote hostname carries no pin.
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
| PARTIAL before any browser call; reason `navigation policy mode does not match` | a policy is exported but its `mode` disagrees with `--mode` | fix the policy's mode, or unset it to use consent mode for a local target |
| PARTIAL; reason starts `remote-target-needs-parent-environment-policy` | `--mode=remote` or a remote base URL without a launch-time policy | launch Claude Code with the remote policy of section 4 |
| the permission prompt was answered No | you declined the origin | re-run and answer Yes. Declaring routes in the recipe does NOT help: consent is per origin, and the recipe's declared routes are prompt context only |
| PARTIAL; `consent mode ready, no runtime recipe` in `/zensu:doctor` | nothing tells the skill how to start the app | run `/zensu:verify-feature --setup`, or pass `--attach=<loopback-origin>` |
| PARTIAL; reason names `loopback-IP origins only` | local origin spelled with `localhost` | use `127.0.0.1` in the policy, the recipe, and the `baseUrlCommand` output |
| PARTIAL; the `baseUrlCommand` output differs from the policy origin | the app bound another port, or the printed URL carries a path | bind the port strictly; print the bare origin |
| PARTIAL; the recipe was rejected | one of the acceptance rules above is not met | the report names the missing fact; fix the recipe |
| PARTIAL; `playwright-cli` not found | it is not installed or not on `PATH` | `npm install -g @playwright/cli@0.1.21` (`brew install playwright-cli` is unpinned), then run `/zensu:doctor` |
| the browser does not start because Chrome is missing | the run config uses the system Chrome channel | approve `playwright-cli install-browser` when the skill asks, or install Chrome yourself |
| a `playwright-cli` call is denied with `Zensu browser consent gate denied the playwright-cli call: …` | the call used a command, flag, session or shape the gate does not admit | the reason names the rule; a shape denial — one that objects only to how the call is spelled — is re-issued once as one plain call with single-quoted literal arguments, and any other denial leaves the affected scenario PARTIAL rather than worked around |
| PARTIAL; the scenario left the approved origins | the application redirected the browser to an origin outside the run config | fix the redirect, or add that origin to the run when it is part of the feature (in policy mode, to the policy too) |
| after updating the plugin, a `permissions` rule for the browser no longer applies | the plugin no longer ships a Playwright MCP server, so rules for `mcp__plugin_zensu_playwright__…` or `mcp__plugin_zensu_zensu-browser__…` match nothing | delete an `allow` rule written for them, which grants nothing now; re-spell a `deny` or `ask` rule for the Bash command, for example `Bash(playwright-cli:*)`, because until then it restricts nothing; the Browser Consent Gate section of [gates.md](gates.md) explains the change |
