# Config — `.zensu/autopilot.yaml`

The persisted recipe. **Committed, shared, secret-free.** Written by the skill after a
successful probe (`probe.md`); hand-editable but never required. Once it exists, every run
skips detection — the zero-touch path.

Rules:
- **No secret values, ever.** Commands and names only. Real secrets live in a gitignored
  `.env`, referenced by name (`PASSWORD_ENV: AUTOPILOT_TEST_PASSWORD`). See `auth.md`.
- The skill **proposes** the file + diff and lets the user commit it (never commits
  without permission).
- Ports may be offset for isolation; if so, the offsets are baked into the commands here
  so the recipe is reproducible.

## Schema

```yaml
version: 1

vcs:
  provider: github          # github | gitlab
  prBase: main
  commitStyle: conventional
  worktreeOnly: true

services:                   # ordered bring-up; each waits on `ready` before the next
  - name: db
    up:    "<shell>"
    ready: "<shell, exits 0 when ready>"
    env:   { KEY: value }   # NON-SECRET only; real secrets referenced by NAME, value in .env
  - name: backend
    up:    "<shell>"
    ready: "<shell>"
    down:  "<optional scoped shell; required when live verification cannot own a foreground PID>"
  # ports auto-offset for isolation if a dev stack already occupies them

gates:                      # all must pass before the PR opens and after every fix round
  - "<shell, non-zero = fail>"
coverageMinPerFile: 90      # optional per-file coverage floor

auth:
  mode:        login-script # login-script | none
  loginScript: "<shell that prints '<KEY>=<path|ok>' — never the secret>"
  artifact:    storageState # storageState | bearer-token-file | keychain | none
  baseUrl:     "<authentication/API origin for the selected runtime>"
  appOrigin:   "<exact browser application origin; browser driver only>"
  # orchestrator exports ZENSU_AUTH_ARTIFACT_DIR; script writes beneath it
  # orchestrator exports auth.baseUrl as ZENSU_AUTH_BASE_URL; script must use it
  # orchestrator exports auth.appOrigin as ZENSU_APP_ORIGIN for browser storage state
  # skill validates/reads only the artifact path/ok — never the credential value

validate:
  driver:  browser          # browser | api | cli | async | iac | custom  (see drivers.md)
  baseUrl: "<url>"          # browser / api
  baseUrlCommand: "<optional shell that confirms the parent-authorized URL after readiness>"
  assert:  "<shell>"        # cli / api / custom: exit 0 = pass, prints evidence
  # driver-specific keys: browser.viewport, api.protocol, cli.pty, iac plan target, ...
  sinks:                    # optional side-effect assertions (augments)
    - { type: email, at: "<url>" }
  navigationBroker:        # policy mode of /zensu:verify-feature; optional in consent mode
    contractVersion: 1
    policyEnv: ZENSU_VERIFY_NAVIGATION_POLICY_V1
  networkOnly:
    appOrigin: "<exact browser application origin these origins belong to; required in remote mode>"
    origins: ["<exact origin the pages request but never navigate, e.g. a REST API or OIDC issuer>"]
  evidenceSafety:           # optional; declares the application's data classification, gates nothing
    contractVersion: 1      # required literal integer
    mode: declared-safe     # the only mode supported by contract v1
    dataClassification: synthetic # synthetic | pre-classified-non-sensitive (declared-safe)
    containsPersonalData: false   # must be literal false (declared-safe)
    containsSecrets: false        # must be literal false (declared-safe)
```

### `validate.driver: browser` — needs a user-installed `playwright-cli`

The browser driver runs through `playwright-cli`, which the plugin no longer starts for you: the
user installs it once, with `npm install -g @playwright/cli@0.1.21` (the version the browser
consent gate was measured against; `brew install playwright-cli` is unpinned), and `/zensu:doctor` reports whether it is on `PATH` and which version. A recipe that sets
`driver: browser` still validates without it, but VALIDATE cannot drive the UI then. It degrades
the driver as `drivers.md` §"Choosing + degrading" states — a backend-observable AC falls back
to `api`, every other AC's live proof is skipped and named in the report, and its PR row carries
`🟡 unvalidated` — and it never records a browser AC as passed without the binary.

### `validate.navigationBroker` — parent-environment navigation policy

The key keeps its name so existing recipes stay valid; it declares POLICY mode.
`/zensu:verify-feature` accepts only contract version `1` with the literal parent-environment
key `ZENSU_VERIFY_NAVIGATION_POLICY_V1`. The environment value is JSON with exactly
`{"version":1,"mode":"local|remote","targets":[{"origin":"<exact-origin>","evidenceMode":"declared-safe"}]}`,
optionally beside `"networkOnlyOrigins":["<exact-origin>", …]` (see `validate.networkOnly` below),
and is read from the environment Claude Code started with, by the browser consent gate (the
Bash-matcher hook pair that judges each `playwright-cli` call whose command text names the CLI
and a `zensu-verify` session, or names the CLI while the hook environment's
`PLAYWRIGHT_CLI_SESSION` names one) and
by `scripts/verify-browser-config.js`. It is never a command the model may set during the run: a
child-process export reaches neither the hooks nor the browser. Every selected
application/authentication origin must be present exactly or navigation remains PARTIAL; a
target covers every route on its origin, so no route list is declared. A policy written for an
earlier contract may still carry a `routes` list: it is accepted when well formed and then
ignored, so it narrows nothing. A dynamically chosen origin cannot be authorized from inside an
already-running Claude session: launch the session with the exact origin policy first, or use a
separate discovery run and restart with that policy. Without the variable
`/zensu:verify-feature` runs in consent mode, which admits loopback origins only and
asks the user once per new origin; the key is optional there and honoured when present.

In `local` mode every target must use `http` or `https` with a loopback IP or the exact name
`localhost`, which the browser resolves to loopback itself, and so must every network-only origin
except a pinned public HTTPS one (see `validate.networkOnly` below); every other hostname,
`app.localhost` and `localhost.` included, is rejected rather than trusted through mutable
DNS/hosts resolution.
`localhost` and `127.0.0.1` are different origins, so the recipe, the policy and `baseUrlCommand`
must spell the same one. In `remote`
mode every origin must be non-loopback HTTPS; the run-config helper rejects any DNS answer that
is not globally routable and pins each hostname to an approved address for the browser process,
and the gate refuses to open a run config whose remote hostname carries no pin. The browser
refuses every HTTP(S) request to an origin outside the run config — a WebSocket connection is
not fenced by it, which is an open gap — and the gate reapplies the
credential/query/fragment rule to every navigation command. A server
redirect is NOT filtered by the browser, so the verifier checks the reported page URL after
every navigation. Missing/invalid declarations, mode mismatches, unsupported evidence modes, or
unsupported policy versions fail closed, and so does a hostname that is not exact: every origin
in either list must name an IP literal or a hostname of `a-z`, `0-9`, `.`, `-` and `_` only,
because the browser turns each allowed origin into a URL glob and would read `*`, `{` or `,` as
a pattern. Each target approves its own origin only, so an approval never carries over to
another origin.
Contract v1 supports only `declared-safe`; content on an origin that is not approved remains
PARTIAL before navigation.

### `validate.networkOnly` — origins the pages request but never navigate

An application whose pages call a REST API, an OIDC discovery document or a token endpoint on
another origin needs the browser to reach that origin for subresource, fetch and XHR requests
only. Declaring it as a navigation target would make it navigable and evidence-eligible, so the
contract has a second, separate class: **network-only origins**.

- **Policy.** The parent-environment JSON names them in the optional top-level
  `networkOnlyOrigins` list of contract version `1`, 1 to 8 exact origins. A policy written
  before the key existed stays valid byte for byte unless a target host carries a pattern
  character, which the exact-hostname rule above refuses; an installation that predates the key refuses
  a policy carrying it (`policy contains unknown or missing keys`), so it fails closed rather than
  admitting the origins as targets. An entry carries no credentials, path, query or fragment, is
  unique after canonicalization, and is never also a target; a non-string entry, a duplicate, an
  empty list or an overlap invalidates the whole policy.
- **Floor.** In a `remote` policy every network-only origin is non-loopback HTTPS with a globally
  routable address and a resolver pin per hostname, exactly as a target. In a `local` policy it is
  either a loopback origin, as a local target, or a non-loopback HTTPS origin under that same
  remote floor with a pin, so a local application can reach a hosted API or identity provider.
- **Consent mode has no network-only class.** Without a policy the run-config helper refuses
  `--network-only-origin`, and a non-loopback origin stays refused. A loopback API origin is then
  passed as an ordinary `--origin` and consented to like any other loopback origin. Trade-off: a
  local application that calls a non-loopback API needs the launch-time policy and a restart;
  there is no prompt path for it.
- **Recipe.** `validate.networkOnly` associates the origins with the selected deployment, as
  `auth.baseUrl` is associated today. `origins` lists them exactly as the policy does. In remote
  mode `appOrigin` must equal the origin derived from the validated base URL, exactly as
  `auth.appOrigin` must, or the run stops PARTIAL before `open`. In local mode it may be omitted,
  because the application origin is the run's own loopback origin; when present it must equal
  that origin too.
- **What the gate does.** The run config stays one plain `network.allowedOrigins` list holding the
  targets and the network-only origins. At `open` the gate admits a run-config origin the policy
  declares network-only (with its pin for a remote host) and records no consent memory for it.
  `open <url>`, `goto` and `tab-new` aimed at a network-only origin are denied with their own
  reason. The redirect rule is unchanged: a `Page URL` on a network-only origin ends the scenario,
  and nothing on that page is read as evidence.

What the class adds is an exfiltration surface: page code on a navigable origin can send data —
including text the verifier types into a form — to every declared network-only origin. That is
accepted because the list is declared by a human in the parent environment, which the model
cannot write, it is bounded at 8 exact origins with no pattern, and in remote mode every entry is
public HTTPS pinned to an approved address, so no entry reaches a private, metadata or loopback
address. `docs/verify-feature-consent-spec.md` holds the full analysis.

### `validate.evidenceSafety` — optional data-classification declaration

The evidence boundary of `/zensu:verify-feature` is the ORIGIN, never the route: an origin the
user approved through the consent prompt, or that the parent-environment policy names with
`evidenceMode: declared-safe`, covers every page on it, at any path. This block therefore gates
no navigation. It records the recipe's claim about the application's data, and it is optional.
When present it is read as follows; `contractVersion` must be the literal integer `1`.

- `mode: declared-safe` requires `dataClassification` to be exactly `synthetic` or
  `pre-classified-non-sensitive`, and both `containsPersonalData` and `containsSecrets` to be
  literal `false`. Claim it only when checked-in fixture/seed code proves that the application
  cannot render user, tenant, credential, or production-derived content.
- `routes` is no longer part of the contract. A recipe written for an earlier contract may still
  carry it; it is ignored and restricts nothing.

## Concrete instance — the zensu-monorepo (verified values)

This is the autopilot recipe the probe resolves for the Zensu monorepo, using real values from
that repo's `backend/Makefile`, `backend/internal/config/config.go`, and
`frontend/vite.config.ts`. It is an autopilot example, not a `/zensu:verify-feature`-compatible
live recipe: the verifier uses its bundled collision-safe, lease-owned adapter instead.

```yaml
version: 1
vcs: { provider: github, prBase: main, commitStyle: conventional, worktreeOnly: true }

services:
  - name: db
    up:    "make -C backend db-up"            # docker compose postgres :5432
    ready: "pg_isready -h localhost -p 5432"
  - name: backend
    up:    "make -C backend migrate && make -C backend dev"   # air hot-reload, :8080
    ready: "curl -fs http://localhost:8080/<health>"          # exact path resolved by probe
    env:   { EMAIL_PROVIDER: noop, NOTIFICATION_PROVIDER: noop }
  - name: frontend
    up:    "pnpm -C frontend dev"             # vite :5173, proxies /api → :8080
    ready: "curl -fs http://localhost:5173"

gates:
  - "make -C backend check"                   # fmt + vet + lint + test + migrations-integration
  - "pnpm -C frontend exec vitest run --coverage"
coverageMinPerFile: 90                        # repo rule 16

auth:
  mode:        login-script
  loginScript: "make -C backend e2e-session"  # NEW small target — see prerequisite below
  artifact:    storageState
  baseUrl:     "http://localhost:5173" # same-origin /api proxy
  appOrigin:   "http://localhost:5173" # exact browser/storage-state origin

validate:
  driver:  browser
  baseUrl: "http://localhost:5173"
  # an `api` profile is also viable for backend-only ACs:
  #   driver: api, assert: "make -C backend test-e2e", artifact: bearer-token-file
```

## Login-script prerequisite a project supplies

For the monorepo this is the only thing autopilot needs that does not exist yet: a small
`make e2e-session` target (the consumer-side login script) that

1. runs the existing seed (the monorepo's `backend/cmd/seed/main.go` already creates an
   email-confirmed `admin@zensu.dev` owner user, idempotent + RLS-safe),
2. logs that user in against `ZENSU_AUTH_BASE_URL` (`POST /api/auth/login`),
3. writes `storageState.json` for `ZENSU_APP_ORIGIN` (cookies/localStorage) beneath the supplied
   `ZENSU_AUTH_ARTIFACT_DIR`,
4. prints exactly `STORAGE_STATE=<path>` and nothing else.

The credentials stay **inside that target**. The skill runs it and reads only the
`STORAGE_STATE=` line — it never sees the password. This is the login-script convention
from `auth.md` applied to one concrete repo; any project provides the equivalent for its
own stack (an API-login script, a headless-form script, or a seed+login target), and the
orchestration is identical.

## Notes

- A project with **no auth** sets `auth.mode: none` and omits `loginScript`; the validate
  step runs unauthenticated.
- A project with **no UI** sets `validate.driver: api` (or `cli`/`custom`) and provides an
  `assert` command instead of a `baseUrl`.
- Collision-safe live verification may use `validate.baseUrlCommand` instead of `baseUrl`. The
  command must print exactly one credential-free URL. In policy mode that URL must already be
  allowlisted in the immutable parent-environment policy before the session began: the command
  may confirm the runtime's URL after readiness, it may not select a new free port during the
  session, and a discovery-first runtime requires a second, policy-configured session. In
  consent mode a run-specific loopback port is expected, and the first navigation to it asks the
  user.
- `services[]` is ordered and each entry blocks on its `ready` check — model real
  dependencies (db before backend before frontend).
