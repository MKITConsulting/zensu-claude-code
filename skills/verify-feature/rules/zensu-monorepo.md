# Zensu monorepo local runtime adapter

Use this adapter only when the current repository contains all four markers:

- `backend/cmd/zensu`
- `backend/Makefile`
- `frontend/package.json`
- `frontend/pnpm-lock.yaml`

The adapter is the checked-in lifecycle controller at
`<absolute-plugin-root>/skills/verify-feature/scripts/zensu-monorepo-runtime.sh`. The parent skill
must replace `<absolute-plugin-root>` with its already concretized native plugin root. Do not copy its
commands into separate Bash calls. The controller is the ownership boundary: it retains
generated secrets internally, persists only the exact container, ports, origin, and run ID,
and tears down only resources whose private lease can be revalidated. Backend and frontend run
under lease-authenticated supervisors that own their complete child process groups.

## Prerequisites and run boundary

The bundled local adapter requires macOS, Linux, or WSL because its ownership boundary uses
POSIX process-group signaling. Native Windows Git Bash remains supported by the plugin's hooks,
but is not a safe execution host for this adapter; report PARTIAL and use WSL, a deployed remote
target, or a checked-in platform-specific validation driver instead.

The controller validates `docker`, `go`, `pnpm`, `curl`, `lsof`, `cksum`, `openssl`, `git`,
`node`, and `make`. The parent skill must first create the non-symlink run directory beneath the
physical worktree at `$GIT_ROOT/.zensu/verify-feature-runs/<random>`.

Set these non-secret shell variables for the current report only:

```bash
ZENSU_RUNTIME_CONTROLLER="<absolute-plugin-root>/skills/verify-feature/scripts/zensu-monorepo-runtime.sh"
ZENSU_VERIFY_RUN_DIR="$RUN_DIR"
ZENSU_VERIFY_WORKTREE="$GIT_ROOT"
```

Register this exact standalone teardown command before `up`:

```bash
bash "$ZENSU_RUNTIME_CONTROLLER" down "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
```

Do not combine it with logging, pipes, conditionals, or other cleanup. Under `--chain`, the
`cd "<that root>" &&` prefix of the skill's Chain mode point 9 is the one exception.

## Navigation preflight, start, and readiness

Resolve the planned application origin before starting any resource, then require the
navigation preflight to accept it:

```bash
APP_ORIGIN="$(bash "$ZENSU_RUNTIME_CONTROLLER" planned-origin "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE")"
node "<absolute-plugin-root>/scripts/verify-browser-config.js" --check-policy local "$APP_ORIGIN" declared-safe
bash "$ZENSU_RUNTIME_CONTROLLER" up "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
bash "$ZENSU_RUNTIME_CONTROLLER" ready "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
```

Run every controller/preflight action as its own Bash invocation. If policy resolution or
preflight fails, do not start or navigate. Report PARTIAL with instructions to launch a new
Claude session with the exact origin policy. A child Bash command cannot
change the environment the browser consent gate reads.

Without a parent policy the gate runs in consent mode and the same three commands still
apply: `planned-origin` then picks a free literal-loopback port through
`<absolute-plugin-root>/scripts/verify-free-port.js`, records it once in the run directory
(`zensu-planned-origin`, mode `0600`) so `up` reuses the same origin, and `--check-policy`
prints `consent` with exit `0`. After `ready`, write the run config for `$APP_ORIGIN` as the
parent skill's "Browser session" step describes; the first `playwright-cli` call that reaches
that origin opens the host's permission prompt to the user, and a refused prompt ends the run
PARTIAL after `down`.

With a parent policy, before `up` that environment must authorize exactly one target containing a
literal `http://127.0.0.1:<port>` origin and `declared-safe` evidence mode; that target covers
every route on the origin, so no route list is needed.
`up` uses that exact frontend port, fails if it is occupied,
derives a collision-safe container name, selects free PostgreSQL/backend ports rooted at
`55432` and `8090`, creates per-run database/JWT secrets and a private runtime lease,
starts `pgvector/pgvector:pg17`, and launches the backend and Vite with `--strictPort` on
literal loopback. Secrets are stored mode `0600` beneath the run directory solely for later
controller actions; never read, print, or pass that file to another tool. The persistent JSON
state contains no secret values or killable PIDs.

## Keeping up with the monorepo

The controller hard-codes the start contract of two services it does not own, so a monorepo
change can break it without any change here. Both contracts are pinned by
`tests/structure/test-zensu-runtime-controller.sh`, whose stubs record the exact argv and
environment the controller hands each service.

- **Backend environment.** The backend refuses to boot when a required variable is missing
  (`validateConfigs` in `backend/cmd/zensu/main.go`); the controller then reports only that
  `ready` failed, and the cause is the `invalid config:` line in `backend.log`. Since monorepo
  PR #778 that includes `TRUSTED_PROXY_CIDRS`. The controller passes `none`
  (`middleware.TrustedProxiesNone`), the value for a backend that receives client connections
  directly: no forwarding header is trusted, so every request is attributed to its TCP peer,
  which in this single-user loopback run is the Vite dev server's proxy. The backend logs a
  `WARN` that the trust set is empty; that is expected here. When the monorepo makes another
  variable required, add it to the backend environment in the controller and to the expected
  environment in that suite in the same change.
- **Frontend flags.** The frontend starts as `pnpm dev --host 127.0.0.1 --port <port>
  --strictPort`. Never put a literal `--` between the script name and the flags: npm strips it,
  but pnpm forwards it, and Vite then ignores every flag after it. Vite falls back to
  `localhost`, which Node 26 resolves to `[::1]` only, and to its default port `5173`, so
  `ready` fails on `127.0.0.1` and a planned origin on `5173` matches only by accident.

`ready` authenticates both supervisors with the private lease, verifies the container's
lease-hash label, then checks PostgreSQL readiness, `/api/health`, and the frontend origin. A
sleep alone is never readiness evidence. The controller never uses the repository's
fixed-port Compose stack and never removes a pre-existing container.

## Runtime identity and fixture data

After readiness, confirm that the persistent runtime reports the same exact origin:

```bash
RUNTIME_ORIGIN="$(bash "$ZENSU_RUNTIME_CONTROLLER" origin "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE")"
```

If `RUNTIME_ORIGIN` differs byte-for-byte from `APP_ORIGIN`, tear down without navigating and
report PARTIAL.

Seed only when the matrix requires repository fixture data:

```bash
bash "$ZENSU_RUNTIME_CONTROLLER" seed "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
```

The controller invokes the repository-owned `make -C backend seed` path without exposing the
DSN or generated password. Use visible manual browser login. If no credential-blind path
exists, continue only with public scenarios and report authenticated coverage as PARTIAL.

## Teardown (always)

Execute the previously registered `down` command byte-for-byte on success, failure,
cancellation, or timeout. It authenticates to the fixed run-local supervisor endpoints with the
private lease, stops their complete child process groups, verifies the unique PostgreSQL
container name and lease-hash label, and then removes internal secret/state files. Mutable JSON
alone can never authorize a signal or container removal. The parent skill removes the unique run
directory. Never use `pkill`, kill by a broad command pattern, or remove another worktree's resource.

`down` is idempotent, and a rerun after a failed teardown converges:

- The supervisor waits until its process group is gone (`ESRCH`). While the group holds only
  exited processes that are not reaped yet, macOS answers `EPERM` instead, and right after
  `SIGTERM` that is the normal state of a group whose processes all exit at once. `EPERM`
  therefore never fails a stop: the wait goes on until the group is gone, and an `EPERM` that
  outlasts it means no process is left to signal, so the stop succeeds without `SIGKILL`.
- An endpoint file that no supervisor answers (the supervisor client exits `3`) is left by a
  supervisor that died. It counts as stopped only when nothing answers on that service's port,
  the same check that runs when the endpoint file is missing. A port that still answers fails
  the teardown and keeps the state for a later `down`.
- The Claude Code Bash sandbox allows signals and process inspection only within the same
  sandbox (`(allow signal (target same-sandbox))`, `(allow process-info* (target
  same-sandbox))`), so a later Bash call can neither signal a process an earlier call started
  nor list it with `lsof`. Teardown never signals from the calling shell: it stops services
  through the supervisor protocol, and its port check connects to `127.0.0.1:<port>` in
  addition to asking `lsof`. `up` uses the same port check for the ports it picks.

Residual: a supervisor that is killed while its service has not bound its port yet, for
example while `go run` still compiles, leaves a process that no check sees. A `down` in that
window reports stopped, and the process binds the port later.
