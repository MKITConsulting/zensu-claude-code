---
paths:
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-stop-deadline.sh"
  - "hooks/lib/stop-idle-probe-v1.js"
  - "tests/structure/test-stop-enforcer-latency.sh"
---

# Stop Hook Latency (`zensu-stop-deadline.sh` + `stop-idle-probe-v1.js`)

**The measured cause.** On `af46577f` a main-thread Stop for a session with NO armed chain
spawned **111** `node` children. About thirty of them re-hash the whole plugin runtime tree
(`readContext` → `computeRuntimeDigest`, ~5 MB) through repeated `zensu_resolve_project_dir`
calls, and the path takes up to five lock round trips (Autopilot read, deferred-review
adoption, refusal-note clear, reconcile). Measured on a 16-core Mac: **579 s** at load ~900 and
**262 s** at load 200–600. Nothing bounded it: the Stop registration carried no `timeout`, so
the host default of 600 s applied, and base macOS has neither `timeout` nor `gtimeout`. The
same Stop on the early exit spawns **4** `node` children and took **9–10 s** at load ~800.
A slow Stop hook delays every queued background-task notification of its session.

**Early exit.** After the principal check, the bind and the project-root resolution, one
`node` child (`stop-idle-probe-v1.js`) reads the session's own workflow document and lists
`.zensu/state`. It answers `idle` only when ALL of these hold, and `busy` on anything else,
including every exception:

- the document exists and passes `workflowChainSnapshot`, with no Autopilot link fields;
- the chain is inactive, or active with `implComplete` and `chainDone` both true;
- no entry matches `PENDING_WORK_ENTRY` (`autopilot-active*`, `autopilot-run*`,
  `pending-review*`, `reviewer-spawn-denied-*`);
- `.zensu` and `state` are real directories and the `STORAGE_LEAVES` pass their type check.

`idle-bypasses` is `idle` with a non-empty `bypasses` array; the hook then releases only while
`hooks.chainEnforcer` is enabled (one more `node` child). `ZENSU_CHAIN=off` skips the early exit.

**Why each clause, and the sites it mirrors.** The predicate is a mirror of what the full path
ACTS ON for an otherwise idle session; a new state file the full path acts on must join it, or
the early exit releases past it.
- `PENDING_WORK_ENTRY` mirrors the hint globs in the hook, `zensu_pending_review_file` and
  `zensu_pending_review_claim_file` in `zensu-tdd-phase.sh`, and `reviewer_denial_note_path`
  plus the reaper glob in the hook. Any denial note — any session's — sends the Stop down the
  full path, which keeps the reaper running.
- `STORAGE_LEAVES` mirrors `_autopilot_storage_safe` in `zensu-autopilot-state.sh`, whose
  refusal makes the full path block as unsafe. `autopilot-active.json` is in the pattern.
- `workflowChainSnapshot` in `session-control-core-v1.js` is the ONE owner of the Stop
  snapshot shape. `tdd_chain_snapshot` and the probe both call it, so the early exit cannot
  release a document the full path rejects as corrupt.
- `ZENSU_CHAIN=off` records a bypass for an active chain, including a done one, so it keeps the
  full path. The disabled-enforcer branch renders the ledger line, and §"Bypass Ledger Read
  Contract" requires every release path above the routing branches to disclose: the early exit
  releases only where the full path would render nothing.
- Deliberate divergence: where the full path would BLOCK only because the adoption or reconcile
  machinery could not run (lease contention, storage preparation) while none of the files it
  looks for exist, the early exit releases.

**Deadline.** The hook re-runs itself as `--zensu-stop-worker` in its own process group
(`set -m`), with stdin, stdout and stderr in a private `mktemp -d` directory. The watchdog is a
second job in a process group of its own: at the deadline it marks the directory and sends
`SIGKILL` to the worker's group. A decision already written is forwarded and stands; otherwise
the Stop is RELEASED with a stderr notice. `SIGTERM`, `SIGINT` or `SIGHUP` to the supervisor
kills both groups at once.

- **Neither group is the host's, and that is what keeps the bound.** A hook shares the Claude
  Code CLI's process group, and the incident ended with the host reaping that group. When the
  supervisor dies that way, the watchdog outlives it, kills the worker at the deadline and
  removes the directory. Every kill names a job leader's own group (`kill -- -<leader>`) and
  falls back to the bare pid; nothing here may ever use `kill 0`, which from a shared group
  would kill the host.
- Worker output goes to files, never to the host's pipes, so a surviving grandchild cannot hold
  them open. A kill mid-lease is safe: `artifactIsStale` treats a dead owner as stale at once.

- **Release, not block, on expiry.** Blocking loops an overloaded session: each retry costs a
  turn plus another full deadline, and the stop-budget counter that bounds block loops lives in
  the path that did not finish. It also follows this hook's rule for "could not evaluate, no
  corruption seen": release, and say no completion was proven.
- **Bounds.** Default 45 s; `ZENSU_STOP_DEADLINE_SECONDS` clamps to 10–75 s; host `timeout` 90 s.
  `L19` pins host ≥ ceiling + 10 and ≤ 120. 45 s, not 30 s, because Windows CI runs the
  Stop-heavy `stop-enforcer-self-review-routing` suite 4.7× slower than ubuntu (1482 s against
  318 s), so an armed Windows Stop is estimated at 10–25 s — unmeasured per Stop — and a deadline
  inside that range would silently stop enforcing there. The floor keeps a lowered value above
  an ordinary macOS or Linux armed Stop.

**Known gaps.**
- A deadline release writes no bypass-ledger entry (the write needs the lease under the load
  that caused the deadline) and renders no ledger line. It is INDUCIBLE — by loading the machine,
  or by lowering `ZENSU_STOP_DEADLINE_SECONDS` in the Claude Code environment — the same class as
  the other inducible releases this hook records.
- The armed path still spawns 100+ `node` children; the deadline bounds it and does not make it
  fast. The durable fix is to resolve the project root and session key once per hook run and
  pass them down, which changes shared libraries every gate sources.
- The early exit's wall time is dominated by two runtime-digest computations (bind and resolve).
- Under extreme local load a suite that drives the full Stop path can now FAIL at the deadline
  where it used to pass slowly; the release notice in its stderr names the cause. Measured at
  load ~740: the `hooks.chainEnforcer=false` branch needed more than 45 s.
- On Git Bash the process-group kill is unverified; its fallback kills only the worker pid.

**Version: `patch`.** No schema field, no strict key set, no hook added, removed or renamed, no
matcher change, no `permissionDecision`; the knob is an environment variable, not a config key.
