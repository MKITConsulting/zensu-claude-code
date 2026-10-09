---
paths:
  - "hooks/stop-chain-enforcer.sh"
  - "hooks/lib/zensu-stop-deadline.sh"
  - "hooks/lib/stop-idle-probe-v1.js"
  - "hooks/lib/zensu-session.sh"
  - "hooks/lib/session-control-core-v1.js"
  - "tests/structure/test-stop-enforcer-latency.sh"
  - "tests/structure/test-deferred-review-claim.sh"
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
  `L19` pins host ≥ ceiling + 10 and ≤ 120. 45 s, not 30 s, because an armed Stop is slow on
  Windows: the routing suite's single-Stop checks took 19.0–19.9 s each on the Windows runner
  (green run 36556263889, session setup included), and a deadline near that figure would
  silently stop enforcing there. The floor keeps a lowered value above an ordinary macOS or
  Linux armed Stop.

**One resolution per run (`zensu_memoize_project_dir` + the canonical-key shortcut).** Measured
on `dc9f0ff8` with a classifying `node` shim, an armed Stop spawned **96** `node` children: 28
project-root verifications (`zensu_resolve_project_dir`, each a record read plus a runtime
digest) and 18 `session-key` calls, 17 of them on a key that was already canonical. After this
change the same Stop spawns **50**: one verification and no `session-key` call. Other paths:
implementing 70 → 37, deferred-review adoption 170 → 87, `ZENSU_CHAIN=off` 88 → 37, idle 4 → 4.
Wall time for the armed Stop fell from about 11 s to about 6 s at load 19–30. On Linux with
bash 5.2 the same armed Stop spawns **38**, because the lock pairs cost fewer children there.

- **Session key.** `sessionKey` returns a value matching `^scv1_[a-f0-9]{64}$` unchanged, so
  `zensu_session_key_canonical` answers that one shape in shell and every other input still
  goes to the core. It is a pure-function shortcut, not a cache, and applies to every caller of
  `zensu_resolve_session_id`. The pattern lists the hex digits instead of using a range, so no
  collation can widen it. `SESSION_KEY_RE` in `session-control-core-v1.js` owns the shape;
  `L38` and `L42` hold the shell copy to it, so a drift between the two surfaces there as a
  spawn-count or output failure. The hook passes no raw id any more: the bind already derived
  the key from the same payload, so `zensu_resolve_session_id ""` returns the bound key.
- **One shell spelling of the key shape.** `zensu_session_key_canonical` is public and sits in
  the `export -f` list of the non-Windows arm, and `reviewer_denial_note_path` in the Stop hook
  calls it instead of keeping a test of its own. That test was the range form `scv1_*[!0-9a-f]*`
  plus 64 `?`. Measured on macOS `/bin/bash` 3.2.57 under `LC_ALL=en_US.UTF-8`: `[a-f]` matches
  `B` and `é`, so the range form accepted `scv1_` plus 63 hex digits plus `B`. The doctor's
  `^reviewer-spawn-denied-scv1_[a-f0-9]{64}\.json$` in `reviewerDenialRows` and the reaper's
  `NAME` never match such a name, which is the "doctor goes quiet with everything still green"
  failure the comment in that function names. The private `_zensu_session_key_canonical` was
  renamed, not wrapped: it never shipped in a release, and a wrapper would add a second name and
  nothing else. `L42b` runs the predicate under `LC_ALL=en_US.UTF-8` and requires a canonical
  control to pass and an upper-case and an accented last character to fail. It discriminates
  only in a shell whose bracket ranges collate under that locale: macOS `/bin/bash` 3.2.57 does,
  the local `bash:5` image (musl) does not, and the check's label says which case ran.
- **Every shell test of the shape calls it.** `grep -rn 'scv1_' hooks/` is the census
  (`.claude/rules/foreign-chain-row.md`). The receipt fallback in `zensu-edit-landing.sh` calls
  the predicate in a subshell (`.claude/rules/multi-repo-stage1.md` records why, together with
  the locale measurement of the range it replaced), and the session-pair guard in
  `zensu-doctor.sh` calls it in the subshell that already sources this file. The other hits in
  shell files are file-name prefix globs such as `tdd-phase-scv1_*.json` and JavaScript regexes
  inside `node` programs, and neither collates.
- **Project root.** `zensu_memoize_project_dir` renders the root (`cd -P && pwd -P`), runs the
  unchanged full verification once, and records `(ZENSU_PROJECT_ROOT, ZENSU_SESSION_CONTEXT,
  ZENSU_SESSION_KEY, rendered root)` in the shell ARRAY `_ZENSU_PROJECT_DIR_MEMO` only when the
  verified render is the path it rendered before. An ancestor swapped between the verification
  and its render is therefore never memoized (`L52`). A later `zensu_resolve_project_dir` still
  runs every shell-side check and skips only the `node` child, and only when all three inputs
  match as spelled and the root still renders to the recorded physical path. Any mismatch falls
  through to the full verification (`L43`–`L46`, `L50`); a record that vanished or became a
  link is refused before the memo is consulted (`L47`, `L48`).
- **One verification decides.** The Stop hook's first verification IS
  `zensu_memoize_project_dir`. When it fails, the hook takes its existing failure branch
  directly (`L51`), so a refusal costs one verification, as before the memo existed, and a Stop
  that proceeds always holds the memo.
- **Why an array.** An environment variable becomes a scalar, which fills index 0 only, and
  bash never exports an array. The memo is accepted only when index 3 is set, so no environment
  variable can stand in for it and no child process inherits it; `L33` and `L35` pin both. Both
  bind functions unset it (`L36`, `L49`). A variable or a file that a model-side Bash command
  could set is never a pre-verified binding; `CONTROL_BINDINGS` needs no new entry for that
  reason.
- **Opt-in, Stop hook only.** Only the Stop hook calls `zensu_memoize_project_dir`. Every other
  entry point verifies on every call, as before. `zensu-log.sh` is a candidate, not a caller. A
  future caller may memoize only after its last bind, and only in a process that runs no record
  writer.
- **What a reuse no longer re-checks.** The record file's content and the runtime digest are read
  once per hook run. A record or plugin tree changed WHILE one Stop runs is not seen again. The
  digest was never a defence there, because a changed tree includes the code that checks it.
  Two writers replace the record behind a session. Automatic adoption re-mints it around the
  same project root, so the memo stays right. A re-anchor (`performReanchor`) supersedes it at
  the same key and path with a NEW project root, and a Stop already running keeps answering the
  old root until it ends. What bounds that window is the re-anchor's own refusal while the
  workflow document holds open work or the session owns an open Autopilot run
  (`.claude/rules/session-reanchor.md`).
- **Coupled sites.** The suite's counting shim classifies a spawn by two literals: the inline
  `core.readContext({ recordsDir, sessionId: key })` in `zensu_resolve_project_dir` and the argv
  `session-control-core-v1.js session-key `. Rewording either turns the count checks of the
  latency suite red. Three in-code rationales assume every `zensu_resolve_project_dir` call
  spawns `node`: the optional argument of `zensu_pending_review_claim_file` in
  `zensu-tdd-phase.sh`, the `zensu_pending_review_file` note in `zensu-autopilot-state.sh`, and
  the `S7t` comment in `tests/structure/test-autopilot-stop-enforcer.sh`. They hold for every
  caller that does not memoize; on the Stop path the memo answers instead.
- **Port.** Host half only; `session-control-core-v1.js` is unchanged. `zensu-codex`,
  `zensu-kiro` and `zensu-antigravity` were NOT included. A port that adopts the memo must take
  the `_ZENSU_PROJECT_DIR_MEMO` unset in both bind functions with it, or a re-bind keeps a stale
  memo.
- **Rejected.** Priming the memo from the bind: `validateContext` canonicalizes the recorded
  root without comparing it, so the bind accepts a root reached through a symlinked ancestor
  that the resolver refuses. A cache file: poisonable. Memoizing `_tdd_paths_safe`: it is the
  per-operation symlink check and must see every swap.

**Known gaps.**
- A deadline release writes no bypass-ledger entry (the write needs the lease under the load
  that caused the deadline) and renders no ledger line. It is INDUCIBLE — by loading the machine,
  or by lowering `ZENSU_STOP_DEADLINE_SECONDS` in the Claude Code environment — the same class as
  the other inducible releases this hook records.
- The armed path still spawns 51 `node` children on macOS with bash 3.2 (`L30`, measured after
  the resume directive gained its `zensu_review_panel` read; the 38 on Linux with bash 5.2
  predates that read), so at a load in the high hundreds it can still reach the deadline. The
  largest remaining groups are `_tdd_paths_safe` (22), the lock acquire and release pairs (8 on
  bash 3.2) and the config reads (5).
- The memo and the shortcut were measured on macOS (bash 3.2.57) and on Linux (bash 5.2.15, in a
  container). Git Bash is unverified. The symlink checks `L43`, `L48`, `L50`, `L51` and `L52`
  make their links through Node, never with `ln -s`, which Git Bash satisfies with a copy.
  `L43`, `L50`, `L51` and `L52` link a directory with `make_directory_symlink`: a junction on
  win32, a directory symlink elsewhere. `L48` links the session record, a file, which a junction
  cannot do. It uses `make_file_symlink`, a native file symlink, which Windows creates only for
  an elevated token or in Developer Mode, so `L48` keeps its skip arm. Each of the five checks
  skips only when its helper fails, never on what `[ -L ]` reports: `L43` and `L51` read exit
  code 5 of the memo driver, and `L52` reads the `.unlinked` marker of `swap-after-root.sh`. The
  suite is excluded from the blocking Windows shards in
  `tests/profiles/windows-native-structure.v1.json` and runs in the weekly Windows Safety
  workflow through `ciStructureTests`. `L13` and `L17d` still link with `ln -s`; their
  behavior on Git Bash is unverified.
- The early exit's wall time is dominated by two runtime-digest computations (bind and resolve).
- Under extreme local load a suite that drives the full Stop path can now FAIL at the deadline
  where it used to pass slowly; the release notice in its stderr names the cause. Measured at
  load ~740: the `hooks.chainEnforcer=false` branch needed more than 45 s.
- `test-deferred-review-claim.sh` runs EVERY Stop through the worker directly
  (`--zensu-stop-worker`, in its `stop()` helper), because it tests the claim protocol, not the
  bound; the latency suite pins the bound. The deadline is per Stop, and this suite's Stops are
  the slowest the hook makes. C1 starts 20 Stops together and took 186 s on the Windows runner
  on `main`; under the default deadline all 20 were released before any adopted the queued
  review. C7's Stops preload the owner observer into every Node child. On a slow
  `windows-shard-1` one of them was released mid-transfer (run 36724193854): the claim's lease
  was renewed, and the block decision was never written. A release whose decision was never
  written reads as `allow`, which such a check cannot tell apart from a protocol defect.
- On Git Bash the process-group kill is unverified; its fallback kills only the worker pid.

**Version: `patch`.** No schema field, no strict key set, no hook added, removed or renamed, no
matcher change, no `permissionDecision`; the knob is an environment variable, not a config key.
The per-run memo and the canonical-key shortcut persist nothing and add no hook, matcher, knob
or config key. Routing the denial-note name through `zensu_session_key_canonical` changes no
persisted shape: a canonical key yields the same file name as before.
