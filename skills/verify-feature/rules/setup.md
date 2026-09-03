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

## 2. Propose per service

For every service the evidence names, propose:

- `up`: the start command, bound to `127.0.0.1` and to `$ZENSU_VERIFY_PORT`, refusing to fall
  back to another port;
- `ready`: an HTTP probe on a path the code exposes (`/`, `/health`, `/api/health`), or a log
  line the start command prints; a sleep is never readiness;
- `down`: leave empty when the service runs as a foreground child the run supervises; name a
  scoped command only when the evidence names one (a Compose project name per run, a PID file
  the start command writes).

Propose the evidence declaration: the page routes the changed code exposes (from the router,
never guessed), and `dataClassification: synthetic` only when seed or fixture code proves the
routes render no user, tenant, credential, or production-derived content. Without that proof,
propose `pre-classified-non-sensitive` only if the user confirms it, otherwise leave the route
list empty and say the routes will stay PARTIAL until declared.

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
  portEnv: ZENSU_VERIFY_PORT
  evidenceSafety:
    contractVersion: 1
    mode: declared-safe
    routes: ["/", "/login"]
    dataClassification: synthetic
    containsPersonalData: false
    containsSecrets: false
```

`.zensu/autopilot.yaml` keeps working as an alias and is tried second; autopilot reads
`runtime.yaml` first as well, so one recipe serves both skills. `validate.navigationBroker` is
optional in consent mode and honoured when present.

## 5. `--print-policy`

With `--print-policy`, render the parent-environment policy for the recipe instead of
starting anything: `{"version":1,"mode":"local","targets":[{"origin":"http://127.0.0.1:<port>","evidenceMode":"declared-safe","routes":[<declared routes>]}]}`,
with `<port>` taken from `--port=<n>` when given, else from
`node "${CLAUDE_PLUGIN_ROOT}/scripts/verify-free-port.js" --from 5173`. Print it, then run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/playwright-mcp.sh" --check-policy local "<origin>" "<route>" declared-safe`
for every declared route with the rendered JSON exported as `ZENSU_VERIFY_NAVIGATION_POLICY_V1`
on that command only, and report each exit code. Explain that the JSON belongs in the
environment that launches Claude Code (a shell export, a CI job's `env`, or the `env` block of
`~/.claude/settings.json`) and that the project-level settings files are not the place, because
the session can write them.
