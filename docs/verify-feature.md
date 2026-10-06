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
refuses to write a run config for any other. The gate itself never reads the installed version,
so a `playwright-cli` installed or put ahead on `PATH` after the helper ran goes unmeasured, and
so does a run whose run config of the right shape was written another way. The check reads the
version the package manifest declares, which vouches neither for what a wrapper script runs nor
for a function or alias named `playwright-cli` that the shell already has.
`brew install playwright-cli` is unpinned: it installs
whichever version Homebrew ships. It uses your installed Chrome. When Chrome is missing,
the skill asks before it runs `playwright-cli install-browser`, because that downloads a
browser. `/zensu:doctor` reports whether `playwright-cli` is on `PATH` and which version, read
from the `@playwright/cli` package manifest the binary resolves to, and warns when that version
is not the one the browser consent gate was measured against. A manifest that names another
package or cannot be judged is reported as such, and the binary is not run. Only when no
manifest exists at all does the doctor run `playwright-cli --version`, once, with stdin closed
and a five-second bound that kills it on every host; the version it prints is reported as
self-reported and is never taken as measured, so the run-config helper still refuses to start a
run on it.

In local mode the skill also needs a **runtime recipe** it can accept, or a repository the
bundled Zensu monorepo adapter recognizes, or an application you already run
(`--attach`). `/zensu:verify-feature --setup` writes the recipe with you. The authoritative
contracts stay in `skills/verify-feature/SKILL.md`, `skills/verify-feature/rules/setup.md`
and `skills/autopilot/rules/config.md` § `validate.navigationBroker`; this page does not
replace them.

## Inside a `/zensu:tdd` chain (`--chain`)

A standalone `/zensu:tdd` chain runs this skill in `--chain` mode: at Phase 6 step 6d, before
the review, and again in `/zensu:self-review` when review rounds changed the tree. In that mode
the skill verifies every active `AC-###` criterion of the chain's plan on this worktree, with the
cheapest driver that can observe it: the browser for a UI criterion, a simulator for a mobile
app, and a shell check for an API, a CLI or a queue. A shell check runs through the plugin's
evidence runner, so the plugin records its real exit code; it reaches only an unauthenticated
loopback target and discards its own output, because the runner shows the tail of that output
to the model. The skill records one verdict per criterion, and the chain closes only when every
active criterion has a `pass` on the tree that ships
([Acceptance Verification Gate](gates.md#acceptance-verification-gate)). It verifies a criterion
that is missing, stale or partial, and never re-drives one that fails on this tree: that one needs
a code change first. Remote mode is refused there, because a deployed URL runs other code than
the tree the records bind to. The consent and policy rules below apply unchanged. In consent
mode the later pass boots on the same loopback origin, so the prompt is not asked twice. An
Autopilot-bound chain skips this stage: its VALIDATE stage verifies every criterion unless the
run was started with `--no-validate`, and the chain's terminus line says which.

## How the browser is fenced

Every run writes a **run config** into its own run directory with
`scripts/verify-browser-config.js` and opens the browser with it, under a session named
`zensu-verify-<run>`. The run config makes the browser isolated, restricts every HTTP(S) request
to the run's origins (`network.allowedOrigins`) — a WebSocket connection is not fenced by it,
which is an open gap — blocks service workers, and keeps screenshots and
snapshots inside the run directory. For a remote host it also pins the hostname to the public
address the helper resolved.

The **browser consent gate** — two hooks on the `Bash` matcher — is a textual gate: it judges a
`playwright-cli` call on a `zensu-verify` session before it runs only when the command text
names the CLI and that session, or names the CLI while the hook environment's
`PLAYWRIGHT_CLI_SESSION` names one. A CLI name assembled at run time — an expansion inside
`playwright-cli`, even one set or left empty in the same command, an ANSI-C escape inside the
name such as `$'playwright\x2dcli'`, a script file, an alias under another name — never reaches
it, so that call is not judged, and the literal-spelling and one-plain-call rules below never
apply to it; `$'playwright-cli'`, which holds the plain name, still names the CLI to it, so a
call on a `zensu-verify` session spelled that way is judged and denied as not one plain call. A
session name assembled at run time — a variable, a substitution, an ANSI-C escape or an
expansion inside the `zensu-verify-` prefix — hides the call the same way, unless the hook
environment's `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session: then a call that spells
`playwright-cli` literally is judged whatever its session, and a session that is not literal is
denied. A function or alias named
`playwright-cli` that the shell already has, such as one from a startup file, is judged as the
plain call its text shows, and the gate cannot see what it runs, so the denials below bind only
what the command text spells. While its
prefilter library loads, the gate reaches no decision for a call on any other session whose
command text names no `zensu-verify-` session, and denies a command that merely mentions both
markers — a search, a commit message.
That is the accepted cost of a textual gate: search with the Grep tool and commit with a message
file. While the hook environment's `PLAYWRIGHT_CLI_SESSION` names a `zensu-verify-` session, a
call on any other session reaches no decision only when the command meets every condition that
[Browser Consent Gate](gates.md#browser-consent-gate) lists for it, and every other command that
names the CLI, a mere mention included, is denied. A known wrapper, a package launcher, a CLI
path or an environment assignment is refused only on a `zensu-verify` session. For a
`zensu-verify` call:

- only the commands a verification needs are admitted: opening and closing the session,
  navigation, snapshots, screenshots, console and request listings, clicks and typing, and
  display emulation. `eval`, `run-code`, every cookie, storage and state command, file upload,
  request details, recording, tracing, `attach` and `close-all` are denied;
- `open` must name the run config, and the gate reads it itself before the browser starts;
- calls must come from the main thread, name their session and arguments literally, and run as
  exactly one plain `playwright-cli` command — no second command, pipe, subshell, substitution,
  wrapper, package launcher or nested shell, and a redirection only to a literal path, never to a
  variable, substitution, glob, brace, `~` or `=` target nor on a line of its own — so a denial
  names the rule rather than guessing. Outside single quotes a `$` counts as an expansion unless
  whitespace, the end of the command or a closing double quote follows it;
- every target origin passes the navigation floor of section 2 and, without a policy, the
  consent prompt below.

## 0. Consent mode

When `ZENSU_VERIFY_NAVIGATION_POLICY_V1` is absent from the environment that launched Claude
Code, the gate runs in consent mode (`/zensu:doctor` reports this as
`verify-feature: consent mode ready`). Then:

- The first `playwright-cli` call of the run that reaches a new origin — opening the browser,
  `goto` or `tab-new` — opens a permission prompt naming the origin, the session and the
  consequence: answering Yes lets the model open and read any page on that origin, screenshots
  included, for the rest of the session. The model cannot answer that prompt. The approval covers
  every page at any path, protected pages included once you log in yourself, so a route whose
  identifiers change on every run needs no declaration.
- Approved origins are remembered for the session in
  `.zensu/state/verify-consent-<session-key>.json`; every further route on an approved origin
  passes without a second prompt. The report's `Consent` block lists every record.
- The floor holds whatever you answer: loopback origins only (`127.0.0.1`, `[::1]` or the exact
  name `localhost`; never `app.localhost` or another hostname), no credentials, no query or
  fragment in a navigation, and the browser sends no HTTP(S) request to an origin outside the run
  config. A WebSocket connection is not fenced by the run config, which is an open gap.
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
it refuses every other HTTP(S) request there, so the skill checks the page URL after every navigation and
stops a scenario that left the approved set. With the policy present the gate asks nothing and
enforces the policy exactly as in the sections below.

### Guided setup and attach mode

`/zensu:verify-feature --setup` detects the stack from tracked files, proposes `up`,
`ready`, a port variable and, when seed or fixture code proves it, the application's data
classification, with the evidence file for each proposal, asks one confirmation question, and writes `.zensu/runtime.yaml`
(`.zensu/autopilot.yaml` keeps working as an alias and is tried second). It never invents a
value it has no evidence for, never edits other project files, and never commits unasked.
Add `--print-policy` to render the policy JSON for the recipe's origin, for CI or
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
ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:4173","evidenceMode":"declared-safe"}]}' claude
```

Changing the origin or the mode means exiting Claude Code and launching it again with the new
value.

### Policy shape (contract version 1)

| Key | Rule |
|---|---|
| `version` | the integer `1` |
| `mode` | `local` or `remote`; it must match the `--mode` the skill runs in |
| `targets` | 1 to 8 entries; each carries exactly `origin` and `evidenceMode` |
| `origin` | scheme, host, and port only: no path, credentials, query, or fragment; unique across targets; the host is an IP literal or a hostname of `a-z`, `0-9`, `.`, `-` and `_` only, so a wildcard such as `https://*.example.com` is refused |
| `evidenceMode` | the literal `declared-safe`; contract v1 supports no other mode |
| `networkOnlyOrigins` | optional; 1 to 8 origins the application's pages may request and no navigation command may open. Each follows the `origin` rule above, is unique, and is never also a target. A `remote` policy accepts non-loopback `https://` only; a `local` policy accepts a loopback origin or a non-loopback `https://` one with a public address, resolved and pinned like a target's |
| `routes` | not part of the contract; a list a policy written for the earlier contract still carries is checked for its shape — 1 to 64 page paths, each starting with `/`, carrying no `?`, `#`, or `*`, already normalized and unique — and then ignored, so it narrows nothing |

No other key is accepted at either level. A target approves its origin, and with it every page
on that origin at any path — `/teams/42/sprints/7` as much as `/` — so a route whose identifiers
change on every run needs no declaration. An approval never carries over to another origin: the
gate judges the origin of every navigation command it sees — opening the browser, `goto` and
`tab-new` — and the API and asset requests a page makes only have to hit an origin in the run
config.

### Network-only origins

A page that calls a REST API, an OIDC discovery document or a token endpoint on another origin
needs the browser to reach that origin, but declaring it as a target would make it navigable and
evidence-eligible. List it in `networkOnlyOrigins` instead, and in the recipe under
`validate.networkOnly`:

```bash
ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1,"mode":"remote","targets":[{"origin":"https://app.example.com","evidenceMode":"declared-safe"},{"origin":"https://login.example.net","evidenceMode":"declared-safe"}],"networkOnlyOrigins":["https://api.example.com","https://issuer.example.net"]}' claude
```

The skill passes each one to the run-config helper with `--network-only-origin`, and the run
config allows it beside the targets. The gate then lets the pages request it, while `open`,
`goto` and `tab-new` aimed at it are denied with their own reason, and no consent record is
written for it. These limits are stated rather than hidden:

- The browser knows one class of allowed origin, so a page can still navigate itself onto a
  network-only origin, by a link click, a form, a script or a server redirect, and the call that
  triggered it prints that page's URL and title. `go-back`, `go-forward`, `reload` and
  `tab-select` carry no URL, so the gate cannot judge where they land either. The skill reads the
  `Page URL` line after every navigating call and ends the scenario there, reading nothing else
  from that page.
- A click can open a new tab on a network-only origin. The skill reads `tab-list` before every
  `tab-select`, never selects such a tab, and closes it instead.
- A frame that a target page embeds from a network-only origin renders inside that page, so its
  content appears in that page's snapshot and screenshot, like data the page fetched.
- Page code on a target can send data to every network-only origin, including what the skill
  types into a form. The list is yours, declared in the launch environment the session cannot
  write, bounded at 8 exact origins, and in remote mode public `https://` only, pinned to an
  approved address, so no entry reaches a private, metadata or loopback address.
- The fence covers HTTP(S) only: page code can open a WebSocket connection to any origin, listed
  or not.

Consent mode has no network-only class: the helper refuses `--network-only-origin` without a
policy. A loopback API origin is then passed as an ordinary origin and covered by the consent
prompt, and an application that calls a non-loopback API needs a launch-time policy.
`policy contains unknown or missing keys` from an older installation means it predates the key:
it refuses such a policy rather than misreading it.

### Checking the policy before the run

The skill runs this preflight once for every origin the run navigates before its first browser
call:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy <local|remote> "<origin>" declared-safe
```

and, instead of it, this one for every network-only origin, because the `declared-safe` form
refuses a network-only origin as a navigation target:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy <local|remote> "<origin>" network-only
```

Each form judges its target as the gate judges that kind of origin, and starts no browser. Before it judges the target
it runs the readiness check of the run-config helper: both consent hooks must be registered on a
matcher that covers `Bash`, the `@playwright/cli` manifest of the `playwright-cli` on the `PATH`
of the caller must name the measured version, and no empty or relative `PATH` entry may come
before or hold that `playwright-cli`, so a run from a terminal judges the `PATH` of that
terminal. Section 5 lists those refusals and their fixes. It prints `policy` when a
policy approves the target, and the `declared-safe` form also prints `consent` when no policy is
set and the target is a loopback origin; both exit `0`. The `network-only` form has no consent
answer: without a policy it refuses. A refusal prints `zensu verify browser config: <reason>` on stderr
and exits `1`. Run it from a terminal with `${CLAUDE_PLUGIN_ROOT}` replaced by the installed
plugin directory, or let the skill run it, which reports a refusal as PARTIAL with that reason.
The messages you will meet:

| Message | Cause |
|---|---|
| `navigation policy mode does not match` | the policy's `mode` differs from the mode being checked |
| `remote-target-needs-parent-environment-policy: …` | a remote target with no policy in the launch environment |
| `local navigation policy accepts loopback origins only: 127.0.0.0/8, [::1] or localhost` | a local origin uses a hostname other than `localhost`, for example `app.localhost` or `localhost.` |
| `<origin>: origin is not a target of the navigation policy` | the origin is not listed; a different port is enough |
| `<origin>: origin is network-only in the navigation policy: …` | a network-only origin was checked with `declared-safe`, or passed to the helper as `--origin`; it is never a page to open |
| `<origin>: origin is not a network-only origin of the navigation policy` | the origin checked with `network-only` is not in `networkOnlyOrigins` |
| `a network-only origin needs the parent-environment navigation policy; …` | a network-only check or `--network-only-origin` without a policy; consent mode has no network-only class |
| `a network-only origin outside loopback requires HTTPS` | a local policy or check names a non-loopback network-only origin over `http://` |
| `policy origin must name its host exactly: …` | an origin in either list uses a wildcard or another pattern character in its host |
| `usage: verify-browser-config.js --check-policy <local\|remote> <origin> <declared-safe\|network-only>` | the call carries an operand the preflight does not take, such as the route the earlier contract checked; drop it |
| `the navigation policy in the launch environment is invalid: <rule>` | the policy breaks its contract; the rule names which part, for example `policy contains unknown or missing keys` |
| `the browser consent gate is not ready (…)`, or a reason that says `so no run config is written` | the readiness check failed before the target was judged; section 5 names each cause and its fix |

`/zensu:doctor` checks the policy's contract too and reports an invalid one as
`verify-feature: ZENSU_VERIFY_NAVIGATION_POLICY_V1 is set but invalid (…)`; the preflight above
is the only check of a particular origin.

## 2. Local mode

Local mode proves the code in the current worktree, so the application has to be started from
that worktree on an origin the policy already names.

- **A loopback origin.** The origin is `http://` or `https://` plus a loopback IP address
  (`127.0.0.1`, any other `127.0.0.0/8` address, or `[::1]`) or the exact name `localhost`, and
  the port. Use `localhost` when the app's CORS allow-list, cookies or auth callback name it;
  `localhost` and `127.0.0.1` are different origins, so pick the one the app expects and use it
  everywhere. Chrome resolves `localhost` itself, to `[::1]` and `127.0.0.1`, without asking DNS
  or `/etc/hosts`, so an app bound to either family is reached. Every other hostname is
  rejected — `app.localhost`, `localhost.` and `/etc/hosts` aliases included — because the gate
  refuses to trust DNS for a boundary decision.
- **An API on another origin goes into the recipe under `validate.networkOnly`.** The browser
  requests nothing over HTTP(S) from an origin outside `allowedOrigins`, so a frontend on
  `http://localhost:4200` that calls an API on `http://localhost:9090` needs both origins in the
  run config. List the API origin in the recipe's `validate.networkOnly.origins`. In consent mode
  the skill passes it as an ordinary origin, and one prompt covers both; under a policy that
  lists it in `networkOnlyOrigins`, the pages may request it and no navigation command may open
  it. `auth.baseUrl` stays the navigable authentication origin, for a login page you sign in on.
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
export ZENSU_VERIFY_NAVIGATION_POLICY_V1="{\"version\":1,\"mode\":\"local\",\"targets\":[{\"origin\":\"http://127.0.0.1:${VERIFY_PORT}\",\"evidenceMode\":\"declared-safe\"}]}"
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

The consent gate reads no recipe: its prompt names no route. `/zensu:doctor` resolves the
recipe in exactly one place, `resolveRecipeFile` in `hooks/lib/verify-consent-v1.js`, which
prefers `.zensu/runtime.yaml` over `.zensu/autopilot.yaml` and skips a symlinked candidate, to
tell `consent mode ready` from `consent mode ready, no runtime recipe`. `--config=<path>` steers
the SKILL and is not consulted there.

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

`evidenceSafety` is optional and gates nothing: `declared-safe` records the claim that
checked-in fixtures or seed data make the application synthetic or pre-classified
non-sensitive. Which pages may reach the model is decided by the origin alone — every page, at
any path, on an origin the policy names or you approved at the consent prompt. A `routes` list
left in the block by the earlier contract is ignored.

A complete working example is the eval fixture:
`evals/verify-feature/test-projects/live-app/.zensu/autopilot.yaml`, with
`scripts/fixture-runtime.sh` beside it. It starts one owned Node process on `127.0.0.1`, keeps
PID and lease files in a private state directory, and takes its exact port from a variable
the launching shell exported.

## 4. Remote mode

Remote mode proves code that is already deployed. It boots nothing and needs no runtime
recipe; it needs the policy and a validated base URL.

```bash
ZENSU_VERIFY_NAVIGATION_POLICY_V1='{"version":1,"mode":"remote","targets":[{"origin":"https://preview.example.com","evidenceMode":"declared-safe"}]}' claude
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
- Authentication is credential-blind: you log in yourself in the browser the skill opens, and
  every page of the policy's origin is then in scope, protected pages included, at any path.
  Without a login, authenticated scenarios are skipped and the run is PARTIAL. A configured
  `auth.appOrigin` must equal the validated base URL's origin exactly.
- An API, OIDC issuer or token endpoint on another origin is a network-only origin: list it in
  the policy's `networkOnlyOrigins` and in the recipe's `validate.networkOnly.origins`, whose
  `appOrigin` must equal the validated base URL's origin exactly, as `auth.appOrigin` must. Every
  such hostname is resolved and pinned like a target's. A hosted login page you sign in on is
  navigated, so it stays a target.
- Remote mode verifies what is deployed at that URL, not the files in your worktree. The skill
  says so before its first browser call, and the verdict stays PARTIAL unless a deployment
  identity ties that URL to the branch under test.

## 5. Where a run stops, and why

| Symptom | Cause | Fix |
|---|---|---|
| PARTIAL before any browser call; reason `navigation policy mode does not match` | a policy is exported but its `mode` disagrees with `--mode` | fix the policy's mode, or unset it to use consent mode for a local target |
| PARTIAL; reason starts `remote-target-needs-parent-environment-policy` | `--mode=remote` or a remote base URL without a launch-time policy | launch Claude Code with the remote policy of section 4 |
| the permission prompt was answered No | you declined the origin | re-run and answer Yes. Nothing in the recipe replaces that answer: consent is per origin, and there is no route list to declare |
| PARTIAL; `consent mode ready, no runtime recipe` in `/zensu:doctor` | nothing tells the skill how to start the app | run `/zensu:verify-feature --setup`, or pass `--attach=<loopback-origin>` |
| PARTIAL; reason names `loopback origins only` | local origin spelled with a hostname other than `localhost` | use `localhost`, `127.0.0.1` or `[::1]` consistently in the policy, the recipe, and the `baseUrlCommand` output |
| the page loads, but its API calls fail with `net::ERR_BLOCKED_BY_CLIENT` | the API runs on an origin the run config does not name | declare that origin in the recipe's `validate.networkOnly.origins` (and, under a policy, in its `networkOnlyOrigins`), or as the recipe's `auth.baseUrl` when it is a login origin you navigate, so the run config allows it next to the page's origin |
| PARTIAL; the `baseUrlCommand` output differs from the policy origin | the app bound another port, or the printed URL carries a path | bind the port strictly; print the bare origin |
| PARTIAL; the recipe was rejected | one of the acceptance rules above is not met | the report names the missing fact; fix the recipe |
| PARTIAL; `playwright-cli` not found | it is not installed or not on `PATH` | `npm install -g @playwright/cli@0.1.21` (`brew install playwright-cli` is unpinned), then run `/zensu:doctor` |
| PARTIAL before any browser call; reason starts `the browser consent gate is not ready (consent hook: …; consent recorder: …)` | the run-config helper checks readiness in the `--check-policy` preflight and again before it writes a run config: the hook's file is missing or `hooks/hooks.json` does not register it on a matcher that covers `Bash` (`unregistered`), or the helper could not determine its registration (`unknown`) | run `/zensu:doctor`, whose `verify-feature` row names the cause, and reinstall the plugin; do not start `/zensu:verify-feature` until that row clears |
| PARTIAL before any browser call; reason says `so no run config is written; install the measured version with …` | the `@playwright/cli` package manifest of the `playwright-cli` on `PATH` does not declare the measured version: it names another version or another package, the helper could not judge it, or there is no manifest at all. The manifest in the `node_modules/@playwright/cli` directory beside the `playwright-cli` found on `PATH` is read first, so a wrapper script in a directory that holds one naming the measured version is accepted. Any other wrapper script outside the package reads as no manifest, whose reason says the binary resolves to no such manifest — unless a `package.json` sits in the directory of its resolved path or one of the three above it, which then answers as another package or as one the helper cannot judge. A version the binary prints about itself is never accepted | run the install command the reason names; for a wrapper script, also put the directory npm installs `playwright-cli` into first on `PATH`, ahead of the wrapper — the reason says so only when the wrapper resolves to no manifest, and the `PATH` order has to change either way |
| PARTIAL before any browser call; reason names `an empty PATH entry` or `the relative PATH entry` | an empty `PATH` entry (a leading or trailing `:`, or `::`) or a relative one such as `node_modules/.bin` comes before, or holds, the `playwright-cli` found on `PATH`; the shell reads it against each call's working directory, so a gated call could run another binary than the one measured | remove that entry from `PATH`, or move it behind the directory that holds `playwright-cli` |
| the browser does not start because Chrome is missing | the run config uses the system Chrome channel | approve `playwright-cli install-browser` when the skill asks, or install Chrome yourself |
| a `playwright-cli` call is denied with `Zensu browser consent gate denied the playwright-cli call: …` | the call used a command, flag, session or shape the gate does not admit | the reason names the rule; a shape denial — one that objects only to how the call is spelled — is re-issued once as one plain call with single-quoted literal arguments, and any other denial leaves the affected scenario PARTIAL rather than worked around |
| a Bash call is denied with `Zensu browser consent gate denied the playwright-cli call:` and the reason `prefilter library unavailable`, `node unavailable`, `decision module absent or symlinked` or `decision module failed` | the consent hook cannot judge the call, because a part of the plugin is missing or broken or `node` is not on `PATH`. Without its prefilter library the hook denies every Bash call whose payload names `playwright` or `zensu-verify`, not only browser calls; in a project whose path names either word that is every Bash call except the recognized `/zensu:doctor` and adoption commands on a POSIX host with `node` | run `/zensu:doctor` and reinstall the plugin even when its `verify-feature` row reads ready: that row names a missing prefilter library and a missing, symlinked or unloadable decision module, but it tests the library for existence only, cannot see a module that loads and then fails, and looks for `node` on the `PATH` of its own shell, stopping before that row when it finds none; for `node unavailable`, put `node` on the `PATH` of the environment that launches Claude Code |
| PARTIAL; the scenario left the approved origins | the application redirected the browser to an origin outside the run config | fix the redirect, or add that origin to the run when it is part of the feature (in policy mode, to the policy too) |
| after updating the plugin, a `permissions` rule for the browser no longer applies | the plugin no longer ships a Playwright MCP server, so rules for `mcp__plugin_zensu_playwright__…` or `mcp__plugin_zensu_zensu-browser__…` match nothing | delete an `allow` rule written for them, which grants nothing now; re-spell a `deny` or `ask` rule for the Bash command, for example `Bash(playwright-cli:*)`, because until then it restricts nothing; the Browser Consent Gate section of [gates.md](gates.md) explains the change |
