# Service verification rules (`api`, `async`, `iac`)

Loaded for rows whose driver is `api`, `async` or `iac`. The runtime comes from `SKILL.md` Phase 2:
an accepted recipe or the bundled monorepo adapter starts the services on a run-specific loopback
port, or `--attach` names a loopback origin the user already runs, with the same identity rule.
The recipe's `up` and `down`, or the adapter's lease, own the services they start; every other
resource the run creates goes through the run-resource helper (`rules/drivers.md` section 5).

## 1. `api`

The target is the run-owned service on a loopback origin (`127.0.0.1`, `[::1]` or `localhost`) and
the port the run chose. A deployed host is never a target: remote API verification is not
supported, so such rows are PARTIAL.

- **Clients.** `curl` for HTTP, GraphQL and SSE, `grpcurl` for gRPC, a WebSocket client for
  WebSocket, or the repository's own typed client or end-to-end target when it has one. Prefer the
  typed path over a hand-written raw payload.
- **Every `curl` call** carries `--max-redirs 0` and never `-L`, so a redirect off the loopback
  origin is observed instead of followed, and a `--max-time` bound. Write the body to a file in
  `$RUN_DIR` with `-o` and print only the status with `-w '%{http_code}\n'`, then read the file.
- **Headers stay out of the conversation.** Never print response headers (`-i`, `-v`, `-D -`):
  they carry cookies and tokens. When a criterion is about a header, write the headers to a file
  in `$RUN_DIR` with `-D` and read only that header's line.
- **Authentication.** Only a throwaway identity that the repository's own seed or fixture code
  creates for the run-owned service. A repository-owned script may write the credential into a
  file under `$RUN_DIR` and print only its path; pass it to the client by path (`curl -H @<file>`
  reads header lines from the file) and never read, print or copy that file. Without such a
  script the authenticated rows are PARTIAL. Never a real account and never a credential from the
  chat.
- **Assertions.** Status code AND body, and the persisted effect when the criterion names one,
  read back through the application's own read path or the repository's typed data tool. A `2xx`
  alone never proves a write.
- **Matrix dimensions**, only where the change touches them: success, validation errors,
  unauthenticated and forbidden, not found, conflict and idempotency, pagination and limits,
  content negotiation, streaming.
- **Streams.** For SSE read a bounded number of events (`curl -N` with `--max-time`); for WebSocket
  send the documented message and read a bounded number of replies.
- **Runtime signals.** The service's own log from this run (the supervisor log `start` printed, or
  the recipe's log), filtered to warnings and errors, bounded, sanitized like console output.

## 2. `async`

- **Trigger through the product's own path**: the project's producer, CLI, admin endpoint or test
  fixture. Never a hand-written raw message when the repository has a typed producer.
- **Run-owned broker only**: the recipe's broker, which its `up` starts under a run-specific name
  and its `down` removes, or a container or process the run starts itself: a container named
  with the `prefix=` that the helper's `list` prints and recorded before it is created, or a
  process under the helper's `start`. Never a shared or deployed broker.
- **Observe the downstream effect**: a row, a message on the output topic read by a run-owned
  consumer, a file, a log line. Poll with a stated interval and limit; a sleep is never evidence.
- **Schedulers and cron jobs**: run the job's entry point with the arguments the schedule would
  pass. A changed schedule expression is checked with the scheduler's own dry-run or next-run
  command when it has one, else read against its documented format and named as read-only
  evidence.
- **Failure paths**, when the change touches them: retries, the dead-letter path, idempotent
  re-delivery, poison messages.

## 3. `iac`

- **Never a real account, a remote backend or remote state.** Copy the smallest repository
  subtree that holds the changed module, chart or stack and every local path it references
  (`../modules`, a kustomize base, a `file://` chart dependency) into `$RUN_DIR/iac/`, keeping the
  relative layout, and run every command there, so no lock file, provider cache or rendered
  output lands in the worktree. Renderers that write nothing into the tree (`kubectl kustomize`,
  `helm lint`, `helm template` of a chart without dependencies) may run in place.
- **Terraform and OpenTofu.** With `TF_DATA_DIR` inside `$RUN_DIR`, run `init -backend=false`,
  then `validate` and `fmt -check`. A `plan` or `apply` runs only when all three hold:
  - the recipe names a disposable target and its `endpoint` (`validate.iac`), for example the
    run's localstack;
  - an override file in the copy forces a local backend and points every provider at that
    endpoint;
  - the ambient credential chain is cut off on those commands: for AWS
    `AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null`, no `AWS_PROFILE`, and the
    dummy keys the recipe declares; the matching variables for other providers.

  Otherwise the row stops at validation and rendering, and a criterion that needs a plan is
  PARTIAL. Never the user's cloud credentials.
- **Helm.** `helm lint` and `helm template` render locally; compare the rendered manifests with
  the criterion. `helm install` runs only into the run's `kind` cluster.
- **Kubernetes manifests.** `kubectl kustomize` renders locally; a server-side check
  (`kubectl apply --dry-run=server`) or an apply runs only against the run's `kind` cluster.
- **The run's `kind` cluster.** Record its name with the helper first, then
  `kind create cluster --name <prefix-or-prefix-suffix> --kubeconfig "$RUN_DIR/kubeconfig" --wait 120s`.
  EVERY `kubectl` and `helm` call passes `--kubeconfig "$RUN_DIR/kubeconfig"`: the ambient context
  can point at production.
- **localstack** runs as a container named with the helper's `prefix=` and recorded before it is
  created, on a run-chosen port, with the dummy credentials the recipe declares.
- **CDK and CloudFormation.** Synthesize the templates locally and lint them when a linter is
  installed. Never deploy.
- **Assertions.** The rendered or planned resource carries the field, count or name the
  criterion states; after a disposable apply, the resource exists in the run's target, read back
  with the run's kubeconfig.
