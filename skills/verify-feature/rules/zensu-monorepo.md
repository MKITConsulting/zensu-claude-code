# Zensu monorepo local runtime adapter

Use this adapter only when the current repository contains all four markers:

- `backend/cmd/zensu`
- `backend/Makefile`
- `frontend/package.json`
- `frontend/pnpm-lock.yaml`

The adapter is the checked-in lifecycle controller at
`{PLUGIN_ROOT}/skills/verify-feature/scripts/zensu-monorepo-runtime.sh`. Do not copy its
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
ZENSU_RUNTIME_CONTROLLER="{PLUGIN_ROOT}/skills/verify-feature/scripts/zensu-monorepo-runtime.sh"
ZENSU_VERIFY_RUN_DIR="$RUN_DIR"
ZENSU_VERIFY_WORKTREE="$GIT_ROOT"
```

Register this exact standalone teardown command before `up`:

```bash
bash "$ZENSU_RUNTIME_CONTROLLER" down "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
```

Do not combine it with logging, pipes, conditionals, or other cleanup.

## Broker preflight, start, and readiness

Resolve the planned application origin from the immutable parent policy before starting any
resource, then require the already-running plugin MCP broker to accept it:

```bash
APP_ORIGIN="$(bash "$ZENSU_RUNTIME_CONTROLLER" planned-origin "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE")"
bash {PLUGIN_ROOT}/scripts/playwright-mcp.sh --check-policy local "$APP_ORIGIN" "/" declared-safe
bash "$ZENSU_RUNTIME_CONTROLLER" up "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
bash "$ZENSU_RUNTIME_CONTROLLER" ready "$ZENSU_VERIFY_RUN_DIR" "$ZENSU_VERIFY_WORKTREE"
```

Run every controller/preflight action as its own Bash invocation. If policy resolution or
preflight fails, do not start or navigate. Report PARTIAL with instructions to launch a new
Claude session with the exact origin and evidence-route policy. A child Bash command cannot
change the MCP server's parent environment.

Before `up`, the Claude parent environment must authorize exactly one target containing a
literal `http://127.0.0.1:<port>` origin, page route `/`, and `declared-safe` evidence mode.
`up` uses that exact frontend port, fails if it is occupied,
derives a collision-safe container name, selects free PostgreSQL/backend ports rooted at
`55432` and `8090`, creates per-run database/JWT secrets and a private runtime lease,
starts `pgvector/pgvector:pg17`, and launches the backend and Vite with `--strictPort` on
literal loopback. Secrets are stored mode `0600` beneath the run directory solely for later
controller actions; never read, print, or pass that file to another tool. The persistent JSON
state contains no secret values or killable PIDs.

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
