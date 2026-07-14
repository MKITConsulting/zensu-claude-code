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
  navigationBroker:        # required by /zensu:verify-feature before any browser navigation
    contractVersion: 1
    policyEnv: ZENSU_VERIFY_NAVIGATION_POLICY_V1
  evidenceSafety:           # optional; required before protected DOM/visual evidence reaches AI
    contractVersion: 1      # required literal integer
    mode: declared-safe     # the only mode supported by contract v1
    routes: ["/exact/path"] # page-navigation paths only; no API/resource paths
    dataClassification: synthetic # synthetic | pre-classified-non-sensitive (declared-safe)
    containsPersonalData: false   # must be literal false (declared-safe)
    containsSecrets: false        # must be literal false (declared-safe)
```

### `validate.navigationBroker` — executable navigation boundary

`/zensu:verify-feature` accepts only contract version `1` with the literal parent-environment
key `ZENSU_VERIFY_NAVIGATION_POLICY_V1`. The environment value is JSON with exactly
`{"version":1,"mode":"local|remote","targets":[{"origin":"<exact-origin>","evidenceMode":"declared-safe","routes":["/exact/page-path"]}]}`
and is consumed by the
plugin's capability-filtering MCP broker before Playwright launches. It is never a command the
model may set during the run: child-process environment changes cannot reconfigure the already
started broker. Every selected application/authentication origin and every model-visible route
must be present exactly or navigation remains PARTIAL. A dynamically chosen origin cannot be
authorized from inside an already-running Claude session: launch the session with the exact
origin policy first, or use a separate discovery run and restart with that policy.

In `local` mode every origin must use a literal loopback IP with `http` or `https`; hostnames
such as `localhost` are rejected rather than trusted through mutable DNS/hosts resolution. In `remote`
mode every origin must be non-loopback HTTPS; the broker rejects any DNS answer that is not
globally routable and pins each hostname to an approved address for the browser process. The
broker checks every request before continuation, rejects unapproved origins, and reapplies the
credential/query/fragment rule to every navigation and redirect. Missing/invalid declarations,
mode mismatches, wildcard origins/routes, unsupported evidence modes, or unsupported policy
versions fail closed. Each target binds its own origin to its own page-navigation routes, so
routes are never combined across origins. Contract v1 supports only `declared-safe`; protected
or sensitive content that cannot satisfy that declaration remains PARTIAL before navigation.

### `validate.evidenceSafety` — fail-closed model-visible evidence contract

This block is a security boundary used by `/zensu:verify-feature`, not a descriptive label.
It is considered valid only after the selected committed recipe and every referenced path are
inspected. `contractVersion` must be the literal integer `1`. Missing fields, unknown
modes/classifications, string booleans, wildcard routes, or routes containing a query or
fragment reject the declaration; protected navigation remains PARTIAL.

- `routes` is a non-empty list of page-navigation pathnames, never API/resource request paths.
  Normalize the requested route with the
  already-validated application origin, remove dot segments, and compare the resulting
  pathname exactly. Every protected route in the matrix must have an exact entry. Entries do
  not inherit to child routes and percent-encoded segments are not decoded for broader matches.
- `mode: declared-safe` requires `dataClassification` to be exactly `synthetic` or
  `pre-classified-non-sensitive`, and both `containsPersonalData` and `containsSecrets` to be
  literal `false`. This is appropriate only when checked-in fixture/seed code proves that the
  covered route cannot render user, tenant, credential, or production-derived content.
An absent or invalid block never downgrades the privacy requirement. It only prevents protected
DOM/visual collection and forces a PARTIAL result; unauthenticated synthetic routes may still
be verified under the ordinary evidence rules.

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
- Collision-safe live verification may use `validate.baseUrlCommand` instead of `baseUrl`, but
  the command must print exactly one credential-free URL that was already allowlisted in the
  broker's immutable parent policy before the session began. It may confirm the runtime's URL
  after readiness; it may not select a new free port during the session. A discovery-first
  runtime requires a second, policy-configured session.
- `services[]` is ordered and each entry blocks on its `ready` check — model real
  dependencies (db before backend before frontend).
