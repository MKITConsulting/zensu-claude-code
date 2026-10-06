# Guided runtime setup

Entered through `/zensu:verify-feature --setup`, or from Phase 2 when no recipe resolved and
the user accepted the offer. Setup is a conversation over evidence, never a generator: every
value is proposed from a tracked file, every proposal names that file, and a value with no
evidence stays empty and is reported as such. Setup never edits project files other than the
recipe it writes, never starts the application, and never runs an install.

## 1. Detect the stack from tracked files only

Read only files `git ls-files` reports. Record one evidence line per proposal in the form
`<value> — from <repo-root-relative file>`:

| Signal | Evidence file(s) | What it yields |
|---|---|---|
| Node dev server | `package.json` `scripts.dev` / `scripts.start`, the lockfile name | `up` command, package manager |
| Vite | `vite.config.*` | `--host 127.0.0.1 --port $ZENSU_VERIFY_PORT --strictPort` |
| Angular | `angular.json` | `--host 127.0.0.1 --port $ZENSU_VERIFY_PORT` |
| Next.js | `next.config.*` | `next dev -H 127.0.0.1 -p $ZENSU_VERIFY_PORT` |
| Make | `Makefile` targets | candidate `up` / `ready` targets, named, never invented |
| Compose | `docker-compose*.yml`, `compose*.yml` | shared fixed ports and container names, reported as blockers |
| Go | `go.mod`, `cmd/*/main.go` | `go run ./cmd/<name>` with a port flag or env the code reads |
| JVM | `build.gradle*`, `pom.xml` | `./gradlew bootRun` / `mvn spring-boot:run` with a port property |
| Seed or fixture code | `**/seed*`, `**/fixtures/**`, `**/testdata/**` | whether `synthetic` can be claimed |

A port the application binds is proposed only when the evidence shows how to pass
`$ZENSU_VERIFY_PORT` in; an application that can bind only a fixed port is reported as
"fixed port, shared resource" and left for the user to decide, never rewritten by setup.

Flags must reach the dev server itself. npm needs a `--` before them and strips it
(`npm run dev -- --host …`). pnpm forwards a literal `--` to the script, and Vite ignores every
flag after it, so the pnpm form passes the flags directly (`pnpm dev --host …`).

## 2. Propose per service

For every service the evidence names, propose:

- `up`: the start command, bound to `127.0.0.1` and to `$ZENSU_VERIFY_PORT`, refusing to fall
  back to another port;
- `ready`: an HTTP probe on a path the code exposes (`/`, `/health`, `/api/health`), or a log
  line the start command prints; a sleep is never readiness;
- `down`: leave empty when the service runs as a foreground child the run supervises; name a
  scoped command only when the evidence names one (a Compose project name per run, a PID file
  the start command writes).

Propose the optional data-classification declaration for the whole application:
`dataClassification: synthetic` only when seed or fixture code proves the application renders
no user, tenant, credential, or production-derived content, and `pre-classified-non-sensitive`
only if the user confirms it; without either, leave the block out. Never propose a route list:
the evidence boundary is the approved origin, which covers every page on it, and `routes` is no
longer read.

Propose `validate.networkOnly` only when a tracked file names another origin the application's
pages request — an API base URL, an OIDC authority or a token endpoint in a tracked environment
or configuration file — and only for the deployment the recipe selects. Never propose an origin
the pages navigate — the application origin, or the origin of a hosted login page even when its
token endpoint sits there too: that origin stays a target, and an authentication origin belongs in
`auth.baseUrl`. Each origin gets its own
evidence line, and an origin no tracked file names stays out: never propose one from a running
application, a browser's network log, a guess, or a file `git ls-files` does not report.
Propose it as the bare origin, with no path, and propose `appOrigin` only for a remote recipe,
where it must be the origin of the validated remote base URL.

## 3. One confirmation round

Ask exactly one `AskUserQuestion` whose options carry every proposal as a pre-filled answer the
user edits, plus "cancel". Never split the proposals over several questions and never write the
recipe before the answer arrives. A cancelled round writes nothing.

## 4. Write the recipe

Write `.zensu/runtime.yaml` at the physical worktree root with the Write tool, refuse to
overwrite an existing file without a second explicit confirmation, print the diff, and offer
to commit — never commit unasked. The schema is the verify-sufficient subset of
`../../autopilot/rules/config.md`:

```yaml
version: 1
services:
  - name: app
    up: "PORT=$ZENSU_VERIFY_PORT npm run dev -- --host 127.0.0.1 --port $ZENSU_VERIFY_PORT --strictPort"
    ready: "curl -fsS http://127.0.0.1:$ZENSU_VERIFY_PORT/"
validate:
  driver: browser
  evidenceSafety:
    contractVersion: 1
    mode: declared-safe
    dataClassification: synthetic
    containsPersonalData: false
    containsSecrets: false
```

`.zensu/autopilot.yaml` keeps working as an alias and is tried second. `/zensu:autopilot`
reads `.zensu/autopilot.yaml` only — it does NOT read `runtime.yaml` — so a project that wants one
recipe to serve both skills writes `autopilot.yaml` rather than `runtime.yaml`.
`validate.navigationBroker` declares policy mode; it is optional in consent mode and honoured
when present. `validate.networkOnly` takes `origins`, a list of exact origins, and in a remote
recipe `appOrigin`, as `../../autopilot/rules/config.md` describes.

## 5. `--print-policy`

With `--print-policy`, render the parent-environment policy for the recipe instead of
starting anything: `{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:<port>","evidenceMode":"declared-safe"}]}`,
with `<port>` taken from `--port=<n>` when given, else from
`node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-free-port.js" --from 5173`. Print it, then run
`ZENSU_VERIFY_NAVIGATION_POLICY_V1='<rendered JSON>' node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy local "<origin>" declared-safe`
once, with the rendered JSON assigned on that command only, and report its exit code: `policy`
on stdout with exit `0` means the rendered JSON approves that origin, and with it every route on
it. The policy carries no route list.
When the recipe declares `validate.networkOnly`, the rendered JSON also carries a top-level
`"networkOnlyOrigins"` list with every declared origin, and the preflight runs once more per
network-only origin, with the same rendered JSON assigned on that command only:
`ZENSU_VERIFY_NAVIGATION_POLICY_V1='<rendered JSON>' node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy local "<network-only origin>" network-only`.
`policy` with exit `0` means the rendered JSON lists that origin as network-only. A non-loopback
network-only origin in a local policy must be public HTTPS, and the preflight resolves it and
refuses a non-public answer.
For a remote recipe, render `"mode":"remote"` instead, with no port: one target for the origin of
the recipe's validated remote base URL (`--base-url` when given, else `validate.baseUrl`), one
more for the validated `auth.baseUrl` origin when it differs and the recipe associates it with
that deployment, each with `"evidenceMode":"declared-safe"`, and the `"networkOnlyOrigins"` list
when the recipe declares `validate.networkOnly` with that same application origin as its
`appOrigin`. Validate every origin with the remote rules of the skill's Phase 0 first, and render
nothing for an origin those rules reject. Prove each target with
`ZENSU_VERIFY_NAVIGATION_POLICY_V1='<rendered JSON>' node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-browser-config.js" --check-policy remote "<origin>" declared-safe`
and each network-only origin with the same command and the operand `network-only`, the rendered
JSON assigned on each command only. The remote preflight resolves every hostname and refuses a
non-public answer, so it needs network access.
Explain that the JSON belongs in the environment that launches Claude Code (a shell export, a CI
job's `env`, or the `env` block of `~/.claude/settings.json`) and that the project-level
settings files are not the place, because the session can write them.
